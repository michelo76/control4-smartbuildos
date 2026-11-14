--[[==========================================================================
  SmartBuildOS MQTT Bridge — Broker driver
  Connects to ONE local MQTT broker (Zigbee2MQTT, Home Assistant's Mosquitto,
  plain Mosquitto) and serves the child drivers (contact, motion, light,
  shade) added next to it: it subscribes to their topics, hands each message
  to the child that wants it, publishes the child's commands, and keeps
  health (when each device last spoke, whether the broker link is up) where
  programming and the SmartBuildOS Agent can read it.

  Scope: MQTT 3.1.1 over plain TCP. No TLS, no MQTT 5, no QoS 2.

  Licensing: the SmartBuildOS Agent is the authority (SKU SBOS_MQTT_BROKER
  through sbos.license). A definitive denial with enforcement on makes the
  bridge READ-ONLY: messages still flow to the children, but nothing is
  published. The children run under the broker's licence.

  Pure rules: src/mqtt/*.lua (tested without a controller).
============================================================================]]

--#ifdef DRIVERCENTRAL
DC_PID = 0
DC_X = nil
DC_FILENAME = "smartbuildos-mqtt-broker.c4z"
--#else
DRIVER_GITHUB_REPO = "michelo76/control4-smartbuildos"
DRIVER_FILENAMES = { "smartbuildos-mqtt-broker.c4z" }
--#endif

-- Every require at module scope: the build's squish step discovers modules
-- by loading this file under the test shim, where OnDriverLateInit stops
-- early, so a require inside a function would be left out of the .c4z.
require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")
JSON = require("JSON")

local log = require("lib.logging")
local license = require("sbos.license")
local agentClient = require("sbos.moduleclient")
local Client = require("mqtt.client")
local Topics = require("mqtt.topics")
local Payload = require("mqtt.payload")
local Router = require("mqtt.router")
local Backoff = require("mqtt.backoff")
local Link = require("mqtt.link")

gInitialized = false

local SKU = "SBOS_MQTT_BROKER"
local MODULE_ID = "mqtt_broker"

local TICK_TIMER = "MqttTick"
local RECONNECT_TIMER = "MqttReconnect"
local STABLE_TIMER = "MqttStableLink"
local STABLE_LINK_SECONDS = 60
local RECONFIGURE_TIMER = "MqttReconfigure"
local PAINT_TIMER = "MqttPaint"
local HEALTH_TIMER = "MqttHealth"
local CHILD_HELLO_TIMER = "MqttChildHello"

local EVENT_MESSAGE, EVENT_CONNECTED, EVENT_DISCONNECTED = 1, 2, 3
local EVENT_STALE, EVENT_RECOVERED, EVENT_READONLY = 4, 5, 6

local MAX_FORWARD_BYTES = 16 * 1024 -- larger payloads are not handed to children
local MAX_VARIABLE_CHARS = 1000
local EVENT_BURST, EVENT_WINDOW = 20, 10 -- at most 20 Message Received events per 10 s
local HEALTH_EVENT_ENTRIES = 20
local HEALTH_EVENT_EVERY = 30 * 60

local gRouter = nil
local gClient = nil
local gBackoff = nil
local gSocket = nil
local gGen = 0
local gConnected = false
local gReconnectPending = false
local gHalted = false
local gConnectionText = "Not configured: enter the Broker Host"
local gLastError = "none"
local gLastPublish = "none"
local gOut = 0
local gIn = 0
local gStaleSet = {}
local gEventStamps = {}
local gEventsSuppressed = 0
local gOversize = 0
local gLastHealthEvent = 0
local gLastHealthKey = ""
local gConnectedAt = nil

local function now()
  return os.time()
end

local function trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function fire(id)
  pcall(function()
    C4:FireEventByID(id)
  end)
end

local function setVar(name, value)
  pcall(function()
    C4:SetVariable(name, value)
  end)
end

local function capText(s, n)
  s = tostring(s or "")
  if #s > n then
    return s:sub(1, n)
  end
  return s
end

-- ─── Child drivers ──────────────────────────────────────────────────────────

--- Sends to a child. Payloads are device data, not credentials, but they
--- can be large and frequent, so the call is never logged.
local function toChild(id, command, params)
  pcall(function()
    C4:SendToDevice(tonumber(id), command, params, true, false)
  end)
end

local function licenceText()
  return gHalted and "read-only" or "ok"
end

local function entityState()
  if gClient ~= nil and gClient:isConnected() then
    return "connected"
  end
  return "disconnected"
end

local function tellChild(id, rejectedText)
  toChild(id, Link.CMD.ENTITY, {
    state = entityState(),
    detail = gConnectionText,
    licence = licenceText(),
    rejected = rejectedText or "",
  })
end

local function tellChildren()
  if gRouter == nil then
    return
  end
  for id in pairs(gRouter.entities) do
    tellChild(id)
  end
end

local function sayHelloToChildren()
  local ok, devices = pcall(function()
    return C4:GetDevices({})
  end)
  if not ok then
    return
  end
  for _, id in ipairs(Link.findDevices(devices, Link.CHILD_FILES)) do
    toChild(id, Link.CMD.BROKER_HELLO, {})
  end
end

--- Forgets children that were deleted from the project.
local function pruneEntities()
  if gRouter == nil then
    return
  end
  local ok, devices = pcall(function()
    return C4:GetDevices({})
  end)
  if not ok or type(devices) ~= "table" then
    return
  end
  local present = {}
  for _, id in ipairs(Link.findDevices(devices, Link.CHILD_FILES)) do
    present[tostring(id)] = true
  end
  local removed = false
  for id in pairs(gRouter.entities) do
    if not present[tostring(id)] then
      gRouter:removeEntity(id)
      removed = true
    end
  end
  return removed
end

-- ─── Flight Recorder and the Agent ──────────────────────────────────────────

--- A marker in the common history. Quiet when no Flight Recorder exists.
local function recordMarker(name, detail)
  pcall(function()
    local devices = C4:GetDevices({})
    local ids = Link.findDevices(devices, Link.FLIGHT_RECORDER_FILES)
    if ids[1] then
      C4:SendToDevice(ids[1], "RECORD_EVENT", { NAME = name, DETAIL = detail or "", CHANNEL = "mqtt" })
    end
  end)
end

local function isoNow()
  return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

--- An event for the Agent's upload pipeline (see docs/smartbuildos-mqtt/DESIGN.md).
local function agentEvent(eventType, severity, label, payload)
  pcall(function()
    local env = agentClient.event({
      event_type = eventType,
      severity = severity,
      evidence_source = "observed",
      quality = "confirmed",
      label = label,
      payload = payload,
      observed_at = isoNow(),
    })
    if env ~= nil then
      agentClient.sendEvents({ env })
    end
  end)
end

-- ─── Health ─────────────────────────────────────────────────────────────────

local function staleAfterSeconds()
  return (tonumber(Properties["Stale After Minutes"]) or 0) * 60
end

local function healthEntries(health)
  local list = {}
  for _, e in ipairs(health.entries) do
    list[#list + 1] = {
      id = tonumber(e.id) or e.id,
      name = capText(e.name, 60),
      kind = e.kind,
      state = e.state,
      age_s = e.age,
      msgs = e.messages,
    }
  end
  return list
end

local function healthJson(health)
  local list = healthEntries(health)
  local text = JSON:encode(list)
  -- Variables are small: drop the quiet, healthy entries first when it is long.
  while #text > 3000 and #list > 1 do
    table.remove(list)
    text = JSON:encode(list)
  end
  return text
end

local function paintConnection()
  UpdateProperty("Connection", gConnectionText)
  UpdateProperty("Last Error", gLastError)
  setVar("BROKER_STATE", gClient ~= nil and gClient:isConnected() and "connected" or "disconnected")
end

local function paint()
  paintConnection()
  if gRouter ~= nil then
    UpdateProperty("Topics Seen", string.format("%d (keeps the newest %d)", gRouter.seenCount, gRouter.seenCap))
    local health = gRouter:health(staleAfterSeconds())
    UpdateProperty("Devices", string.format("%d linked, %d stale or offline", health.count, health.stale))
  end
  UpdateProperty("Messages", string.format("%d in, %d out", gIn, gOut))
  UpdateProperty("Last Publish", gLastPublish)
  UpdateProperty(
    "Bridge Status",
    gHalted and "read-only (licence)" or (gClient and gClient:isConnected() and "active" or "waiting for the broker")
  )
end

--- Once a minute: stale scan, variables, events, Agent report.
local function healthScan()
  if gRouter == nil then
    return
  end
  pruneEntities() -- the caller re-syncs subscriptions afterwards
  local health = gRouter:health(staleAfterSeconds())
  local nowStale, keyParts = {}, {}
  for _, e in ipairs(health.entries) do
    if e.state == "stale" or e.state == "offline" then
      nowStale[e.id] = e
    end
    keyParts[#keyParts + 1] = e.id .. ":" .. e.state
  end
  for id, e in pairs(nowStale) do
    if not gStaleSet[id] then
      setVar("LAST_STALE_DEVICE", e.name)
      fire(EVENT_STALE)
    end
  end
  for id, e in pairs(gStaleSet) do
    if not nowStale[id] then
      setVar("LAST_STALE_DEVICE", e.name)
      fire(EVENT_RECOVERED)
    end
  end
  gStaleSet = nowStale
  setVar("DEVICE_COUNT", health.count)
  setVar("STALE_DEVICE_COUNT", health.stale)
  setVar("DEVICE_HEALTH", healthJson(health))

  local key = table.concat(keyParts, ",")
  if
    (key ~= gLastHealthKey and health.count > 0)
    or (now() - gLastHealthEvent >= HEALTH_EVENT_EVERY and health.count > 0)
  then
    gLastHealthKey = key
    gLastHealthEvent = now()
    local worst = healthEntries(health)
    table.sort(worst, function(a, b)
      local ra = (a.state == "ok") and 1 or 0
      local rb = (b.state == "ok") and 1 or 0
      if ra ~= rb then
        return ra < rb
      end
      return (a.age_s or 0) > (b.age_s or 0)
    end)
    while #worst > HEALTH_EVENT_ENTRIES do
      table.remove(worst)
    end
    agentEvent(
      "mqtt.entity_health",
      health.stale > 0 and "warning" or "info",
      string.format("%d MQTT device(s), %d stale or offline", health.count, health.stale),
      {
        devices = worst,
        count = health.count,
        stale = health.stale,
        broker = gClient and gClient:isConnected() and "connected" or "disconnected",
      }
    )
  end
  paint()
end

-- ─── Subscriptions ──────────────────────────────────────────────────────────

--- The filter that feeds the Topics Seen list: <base>/# unless the dealer
--- typed a filter of their own.
local function discoveryFilter()
  local base = trim(Properties["Base Topic"])
  if base == "" then
    return nil
  end
  if base:find("[#+]") then
    return base
  end
  return (base:gsub("/+$", "")) .. "/#"
end

local function eventFilters()
  local out = {}
  for item in tostring(Properties["Event Topics"] or ""):gmatch("[^,\n]+") do
    item = trim(item)
    if item ~= "" and #out < 5 then
      out[#out + 1] = item
    end
  end
  return out
end

local function syncSubscriptions()
  if gClient == nil or gRouter == nil then
    return
  end
  local set, list = {}, {}
  local function add(f)
    if f and not set[f] then
      set[f] = true
      list[#list + 1] = f
    end
  end
  for _, f in ipairs(gRouter:filters()) do
    add(f)
  end
  add(discoveryFilter())
  for _, f in ipairs(eventFilters()) do
    add(f)
  end
  local rejected = gClient:setSubscriptions(list)
  for _, r in ipairs(rejected) do
    log:warn("Not subscribing to '%s': %s", r.filter, r.why)
  end
  if #rejected > 0 then
    gLastError = "ignored an invalid topic filter: " .. rejected[1].filter .. " (" .. rejected[1].why .. ")"
  end
end

-- ─── Messages ───────────────────────────────────────────────────────────────

local function eventAllowed()
  local t = now()
  local fresh = {}
  for _, stamp in ipairs(gEventStamps) do
    if t - stamp < EVENT_WINDOW then
      fresh[#fresh + 1] = stamp
    end
  end
  gEventStamps = fresh
  if #gEventStamps >= EVENT_BURST then
    gEventsSuppressed = gEventsSuppressed + 1
    return false
  end
  gEventStamps[#gEventStamps + 1] = t
  return true
end

local function onMessage(topic, payload, info)
  gIn = gIn + 1
  gRouter:noteTopic(topic)
  for _, hit in ipairs(gRouter:route(topic)) do
    if hit.role == "availability" then
      local entity = gRouter:entity(hit.id)
      local available = Payload.availability(payload, entity and entity.availability_field or nil)
      if available ~= nil then
        gRouter:setAvailable(hit.id, available)
      end
    end
    if #payload > MAX_FORWARD_BYTES then
      gOversize = gOversize + 1
    else
      toChild(hit.id, Link.CMD.MESSAGE, {
        topic = topic,
        payload = payload,
        retain = info.retain and "true" or "false",
        role = hit.role,
      })
    end
  end
  for _, filter in ipairs(eventFilters()) do
    if Topics.matches(filter, topic) then
      if eventAllowed() then
        setVar("LAST_TOPIC", capText(topic, 300))
        setVar("LAST_PAYLOAD", capText(payload, MAX_VARIABLE_CHARS))
        fire(EVENT_MESSAGE)
      end
      break
    end
  end
end

-- ─── Connection ─────────────────────────────────────────────────────────────

local function closeSocket()
  gGen = gGen + 1 -- callbacks of the old socket now ignore themselves
  local s = gSocket
  gSocket = nil
  if s ~= nil then
    pcall(function()
      s:Close()
    end)
  end
end

local connect

local function scheduleReconnect(permanent)
  if gReconnectPending then
    return
  end
  if trim(Properties["Broker Host"]) == "" then
    gConnectionText = "Not configured: enter the Broker Host"
    paintConnection()
    return
  end
  gReconnectPending = true
  local delay = gBackoff:next(permanent)
  gConnectionText = string.format("Waiting %d s before trying again (%s)", math.floor(delay), capText(gLastError, 120))
  SetTimer(RECONNECT_TIMER, math.floor(delay * 1000), function()
    gReconnectPending = false
    connect()
  end)
  paintConnection()
end

local function onClientState(state, detail, info)
  if state == "connecting" then
    gConnectionText = "Logging in to the broker..."
  elseif state == "connected" then
    gConnected = true
    gConnectedAt = now()
    -- The backoff resets only once the link has stayed up STABLE_LINK_SECONDS;
    -- a broker that accepts the login then drops us must not reset it.
    SetTimer(STABLE_TIMER, STABLE_LINK_SECONDS * ONE_SECOND, function()
      if gClient ~= nil and gClient.state == "connected" then
        gBackoff:reset()
      end
    end)
    gLastError = "none"
    gConnectionText = "Connected"
    syncSubscriptions()
    recordMarker("MQTT broker connected", "")
    agentEvent("mqtt.broker_state", "info", "MQTT broker connected", { state = "connected" })
    fire(EVENT_CONNECTED)
    tellChildren()
  else
    -- closed | failed | refused
    local wasConnected = gConnected
    gConnected = false
    CancelTimer(STABLE_TIMER)
    if state ~= "closed" then
      gLastError = capText(detail, 200)
    elseif gLastError == "none" then
      gLastError = capText(detail, 200)
    end
    if wasConnected then
      recordMarker("MQTT broker disconnected", capText(detail, 200))
      agentEvent(
        "mqtt.broker_state",
        "warning",
        "MQTT broker disconnected",
        { state = "disconnected", reason = capText(detail, 200) }
      )
      fire(EVENT_DISCONNECTED)
    end
    tellChildren()
    scheduleReconnect(info and info.permanent)
  end
  paintConnection()
end

local function onSocketGone(reason)
  closeSocket()
  if gClient ~= nil and gClient.state ~= "idle" and gClient.state ~= "closed" then
    gClient:closed(reason)
  else
    -- Never got as far as a login (the TCP connect itself failed).
    if not gConnected then
      gLastError = capText(reason, 200)
      scheduleReconnect(false)
      paintConnection()
    end
  end
end

connect = function()
  if gClient == nil then
    return
  end
  closeSocket()
  gClient.state = "idle"
  local host = trim(Properties["Broker Host"])
  local port = tonumber(Properties["Broker Port"]) or 1883
  if host == "" then
    gConnectionText = "Not configured: enter the Broker Host"
    paintConnection()
    return
  end
  local opts = gClient.opts
  opts.username = trim(Properties["Username"])
  opts.password = nil -- read at the moment the socket is up, see OnConnect
  opts.keepalive = tonumber(Properties["Keep Alive Seconds"]) or 60
  local clientId = trim(Properties["Client Id"])
  if clientId == "" then
    clientId = "sbos-c4-" .. tostring(C4:GetDeviceID())
  end
  opts.client_id = clientId
  gConnectionText = string.format("Connecting to %s:%d...", host, port)
  paintConnection()
  local gen = gGen
  gSocket = C4:CreateTCPClient()
    :OnConnect(function(sock)
      if gen ~= gGen then
        return
      end
      opts.password = Properties["Password"]
      gClient:open()
      opts.password = nil -- the CONNECT packet is written; keep no copy
      sock:ReadUpTo(4096)
    end)
    :OnRead(function(sock, data)
      if gen ~= gGen then
        return
      end
      gClient:receive(data)
      if gen == gGen then
        sock:ReadUpTo(4096)
      end
    end)
    :OnDisconnect(function()
      if gen ~= gGen then
        return
      end
      onSocketGone("the broker closed the connection")
    end)
    :OnError(function(_, code, message)
      if gen ~= gGen then
        return
      end
      onSocketGone(string.format("socket error %s: %s", tostring(code), tostring(message)))
    end)
  gSocket:Connect(host, port)
end

local function reconnectNow()
  CancelTimer(RECONNECT_TIMER)
  gReconnectPending = false
  if gClient ~= nil and gClient.state == "connected" then
    gClient:disconnect()
  end
  if gConnected then
    gConnected = false
    fire(EVENT_DISCONNECTED)
  end
  gBackoff:reset()
  connect()
end

--- Property edits settle for two seconds before the connection restarts.
local function reconfigureSoon()
  if not gInitialized then
    return
  end
  SetTimer(RECONFIGURE_TIMER, 2 * ONE_SECOND, reconnectNow)
end

-- ─── Licence ────────────────────────────────────────────────────────────────

local function reconcileLicence()
  local halt = license.enforces()
  if halt and not gHalted then
    gHalted = true
    log:warn("SmartBuildOS licence: %s — the MQTT bridge is read-only", tostring(license.statusLabel()))
    fire(EVENT_READONLY)
    tellChildren()
  elseif not halt and gHalted then
    gHalted = false
    tellChildren()
  end
  paint()
end

-- ─── Lifecycle ──────────────────────────────────────────────────────────────

local function registerComposerSurface()
  for _, v in ipairs({
    { "BROKER_STATE", "disconnected", "STRING" },
    { "LAST_TOPIC", "", "STRING" },
    { "LAST_PAYLOAD", "", "STRING" },
    { "LAST_STALE_DEVICE", "", "STRING" },
    { "DEVICE_COUNT", 0, "NUMBER" },
    { "STALE_DEVICE_COUNT", 0, "NUMBER" },
    { "DEVICE_HEALTH", "[]", "STRING" },
  }) do
    pcall(function()
      C4:AddVariable(v[1], v[2], v[3], true)
    end)
  end
  for _, e in ipairs({
    { EVENT_MESSAGE, "Message Received", "A message arrived on one of the Event Topics (LAST_TOPIC and LAST_PAYLOAD)" },
    { EVENT_CONNECTED, "Broker Connected", "The MQTT broker accepted the login" },
    { EVENT_DISCONNECTED, "Broker Disconnected", "The MQTT broker connection was lost" },
    {
      EVENT_STALE,
      "Device Went Stale",
      "A linked device has been silent too long or reported offline (LAST_STALE_DEVICE)",
    },
    { EVENT_RECOVERED, "Device Recovered", "A stale or offline device spoke again (LAST_STALE_DEVICE)" },
    { EVENT_READONLY, "Bridge Read-Only", "The SmartBuildOS licence made the bridge read-only" },
  }) do
    pcall(function()
      C4:AddEvent(e[1], e[2], e[3])
    end)
  end
end

function OnDriverInit()
  --#ifdef DRIVERCENTRAL
  require("cloud-client-byte")
  C4:AllowExecute(false)
  --#else
  C4:AllowExecute(true)
  --#endif
  gInitialized = false
  log:setLogName("MqttBroker")
  log:setLogLevel(Properties["Log Level"])
  log:setLogMode(Properties["Log Mode"])
end

function OnDriverLateInit(reason)
  if not CheckMinimumVersion("Driver Status") then
    return
  end
  registerComposerSurface()
  for p, _ in pairs(Properties) do
    pcall(OnPropertyChanged, p)
  end

  gRouter = Router.new({ now = now })
  gBackoff = Backoff.new({ base = 2, max = 120 })
  gClient = Client.new({
    client_id = "",
    now = now,
    write = function(bytes)
      if gSocket == nil then
        return false
      end
      local ok, result = pcall(function()
        return gSocket:Write(bytes)
      end)
      return ok and result ~= false
    end,
    close = function(reason)
      closeSocket()
    end,
    onMessage = onMessage,
    onState = onClientState,
    onSubscribed = function(filter, granted)
      if granted == nil then
        log:warn("The broker refused the subscription to '%s'", filter)
        gLastError = "the broker refused the subscription to " .. capText(filter, 100)
      end
    end,
    onError = function(text)
      log:warn("%s", text)
    end,
  })

  license.setup({ sku = SKU })
  EC.SBOS_ENTITLEMENT = function(tParams)
    license.onEntitlement(tParams)
    reconcileLicence()
  end

  agentClient.setup({
    module_id = MODULE_ID,
    driver_version = tostring(C4:GetDriverConfigInfo("version")),
    capabilities = { "mqtt_bridge", "entity_health" },
    entitlements = { SKU },
    commands = {},
    event_types = { "mqtt." },
    singleton = false,
    status = function()
      local health = gRouter and gRouter:health(staleAfterSeconds()) or { count = 0, stale = 0 }
      local status = (gClient and gClient:isConnected()) and "ready" or "degraded"
      return status,
        capText(gConnectionText, 150),
        {
          devices = health.count,
          stale = health.stale,
          messages_in = gIn,
          messages_out = gOut,
          reconnects = gClient and gClient.stats.reconnects or 0,
        }
    end,
    onRegistered = function() end,
    onAgentState = function() end,
  })

  gInitialized = true
  UpdateProperty("Driver Status", "Online")
  pcall(function()
    UpdateProperty("Driver Version", tostring(C4:GetDriverConfigInfo("version")))
  end)
  syncSubscriptions()
  paint()
  pcall(agentClient.register)
  SetTimer(TICK_TIMER, ONE_SECOND, function()
    if gClient then
      gClient:tick()
    end
  end, true)
  SetTimer(PAINT_TIMER, 5 * ONE_SECOND, paint, true)
  SetTimer(HEALTH_TIMER, ONE_MINUTE, function()
    healthScan()
    syncSubscriptions()
  end, true)
  -- Children that loaded first are still waiting for a broker; tell them.
  SetTimer(CHILD_HELLO_TIMER, 3 * ONE_SECOND, sayHelloToChildren)
  connect()
end

function OnDriverDestroyed()
  pcall(license.stop)
  CancelTimer(TICK_TIMER)
  CancelTimer(RECONNECT_TIMER)
  CancelTimer(STABLE_TIMER)
  CancelTimer(RECONFIGURE_TIMER)
  CancelTimer(PAINT_TIMER)
  CancelTimer(HEALTH_TIMER)
  CancelTimer(CHILD_HELLO_TIMER)
  if gClient ~= nil then
    gClient:disconnect()
  end
  closeSocket()
end

-- ─── Properties ─────────────────────────────────────────────────────────────

-- The password must never reach the debug log: Handlers print a property's
-- value on change unless suppressDebug names it, and it is consulted BEFORE
-- the name is sanitised, so both spellings are listed.
OPC.suppressDebug = OPC.suppressDebug or {}
OPC.suppressDebug["Password"] = true
OPC.suppressDebug["Username"] = true
-- A message flood is not worth a debug line per message either.
EC.suppressDebug = EC.suppressDebug or {}
EC.suppressDebug["SBOS_MQTT_PUBLISH"] = true
EC.suppressDebug["SBOS_MQTT_HELLO"] = true
EC.suppressDebug["PUBLISH_MESSAGE"] = true

function OPC.Log_Level(value)
  log:setLogLevel(value)
  DEBUGPRINT = tostring(value):match("^5") ~= nil
end

function OPC.Log_Mode(value)
  log:setLogMode(value)
end

function OPC.Driver_Status()
  if not gInitialized then
    UpdateProperty("Driver Status", "Initializing", false)
  end
end

for _, name in ipairs({ "Broker_Host", "Broker_Port", "Username", "Password", "Client_Id", "Keep_Alive_Seconds" }) do
  OPC[name] = function()
    reconfigureSoon()
  end
end

function OPC.Base_Topic()
  if gInitialized then
    syncSubscriptions()
  end
end

function OPC.Event_Topics()
  if gInitialized then
    syncSubscriptions()
  end
end

function OPC.Stale_After_Minutes()
  if gInitialized then
    healthScan()
  end
end

-- ─── Actions ────────────────────────────────────────────────────────────────

function EC.REGISTER_NOW()
  license.register()
  pcall(agentClient.register)
end

function EC.REFRESH_STATUS()
  healthScan()
end

function EC.RECONNECT_NOW()
  reconnectNow()
end

function EC.CLEAR_TOPICS_SEEN()
  if gRouter then
    gRouter:clearSeen()
  end
  paint()
end

function EC.PRINT_TOPICS()
  if gRouter == nil then
    return
  end
  local list = gRouter:seenList()
  log:print("== MQTT topics seen (%d, newest first; payloads are not kept) ==", #list)
  if discoveryFilter() == nil then
    log:print("  Base Topic is empty: only topics the linked devices use are listed")
  else
    log:print("  discovery filter: %s", discoveryFilter())
  end
  for _, s in ipairs(list) do
    log:print("  %-60s %6d msg   last %s", s.topic, s.count, os.date("%H:%M:%S", s.last))
  end
  if gRouter.dropped > 0 then
    log:print("  (%d older topic(s) were dropped to stay within the cap of %d)", gRouter.dropped, gRouter.seenCap)
  end
end

function EC.PRINT_DEVICES()
  if gRouter == nil then
    return
  end
  local health = gRouter:health(staleAfterSeconds())
  log:print("== MQTT devices (%d, %d stale or offline) ==", health.count, health.stale)
  log:print("  broker: %s", gConnectionText)
  log:print("  licence: %s", license.describe())
  for _, e in ipairs(health.entries) do
    local entity = gRouter:entity(e.id)
    log:print(
      "  [%s] %-8s %-28s %-8s last heard %s ago, %d msg%s",
      e.id,
      tostring(e.kind),
      capText(e.name, 28),
      e.state,
      e.age and (tostring(math.floor(e.age)) .. " s") or "never",
      e.messages or 0,
      entity and (" topics: " .. table.concat(entity.filters, ", ")) or ""
    )
  end
end

-- ─── Programming commands ──────────────────────────────────────────────────

local function publish(topic, payload, retain, qos)
  topic = trim(topic)
  if gHalted then
    gLastPublish = string.format("refused: licence makes the bridge read-only (%s)", os.date("%H:%M:%S"))
    fire(EVENT_READONLY)
    return false, "the SmartBuildOS licence has made the bridge read-only"
  end
  local ok, why = gClient:publish(topic, payload, { retain = retain, qos = qos })
  if ok then
    gOut = gOut + 1
    gLastPublish = string.format("%s (%s)", capText(topic, 100), os.date("%H:%M:%S"))
  else
    gLastPublish = string.format("failed: %s (%s)", tostring(why), os.date("%H:%M:%S"))
  end
  return ok, why
end

function EC.PUBLISH_MESSAGE(tParams)
  tParams = tParams or {}
  if gClient == nil then
    return
  end
  local ok, why = publish(
    tParams.TOPIC,
    tParams.PAYLOAD,
    tostring(tParams.RETAIN or ""):lower() == "yes",
    tonumber(tParams.QOS) == 1 and 1 or 0
  )
  if not ok then
    log:warn("Publish Message failed: %s", tostring(why))
  end
  UpdateProperty("Last Publish", gLastPublish)
end

-- ─── Child driver commands ──────────────────────────────────────────────────

function EC.SBOS_MQTT_HELLO(tParams)
  tParams = tParams or {}
  local id = tonumber(tParams.requester)
  if id == nil or gRouter == nil then
    return
  end
  local entity, rejected = gRouter:setEntity(id, {
    kind = tostring(tParams.kind or "device"),
    name = tostring(tParams.name or ""),
    filters = Link.decodeFilters(tParams.filters),
    availability = tParams.availability ~= "" and tParams.availability or nil,
  })
  if entity == nil then
    tellChild(id, rejected[1] and rejected[1].why or "refused")
    return
  end
  entity.availability_field = tostring(tParams.availability_field or "")
  local text = ""
  if #rejected > 0 then
    text = string.format("ignored topic '%s': %s", rejected[1].filter, rejected[1].why)
  end
  syncSubscriptions()
  tellChild(id, text)
  paint()
end

function EC.SBOS_MQTT_PUBLISH(tParams)
  tParams = tParams or {}
  local id = tonumber(tParams.requester)
  if gClient == nil or id == nil then
    return
  end
  local ok, why =
    publish(tParams.topic, tParams.payload, tostring(tParams.retain) == "true", tonumber(tParams.qos) == 1 and 1 or 0)
  toChild(id, Link.CMD.RESULT, { status = ok and "sent" or "failed", reason = ok and "" or tostring(why) })
end

-- ─── Conditionals ───────────────────────────────────────────────────────────

function TC.BROKER_CONNECTED()
  return gClient ~= nil and gClient:isConnected()
end
