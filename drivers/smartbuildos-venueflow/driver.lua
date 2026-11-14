--[[==========================================================================
  SmartBuildOS VenueFlow
  A commercial AV control surface on top of an existing Control4 project:
  bars, restaurants, offices, conference rooms. Staff see their venue,
  pick displays, pick what to watch, and the driver asks Control4 to do it.

  Two pages ship in this c4z and are served from one LAN relay:
    /app      the operator page: Visual Floor Plan, Command Center,
              Simplified Room Control, Manager Overview (the UI Button tile)
    /studio   Installer Studio: wizard, device mapping, layout designer,
              visual programming, staff profiles, diagnostics, publish

  This file is the thin Control4 edge: lifecycle, the socket, properties,
  Composer programming, licensing. Every rule lives in src/venueflow (pure,
  tested on the simulator): core.lua wires them; adapter_c4.lua is the only
  module that commands Control4 devices.

  Licensing: SKU SBOS_VENUEFLOW through the SmartBuildOS Agent (sbos.license).
  A definitive denial with enforcement stops scenes, schedules and publishing.
  It never stops manual control and never switches anything off.

  Control Mode starts as Simulation: nothing is sent to Control4 until the
  installer chooses Live.
============================================================================]]

--#ifdef DRIVERCENTRAL
DC_PID = 0
DC_X = nil
DC_FILENAME = "smartbuildos-venueflow.c4z"
--#else
DRIVER_GITHUB_REPO = "michelo76/control4-smartbuildos"
DRIVER_FILENAMES = { "smartbuildos-venueflow.c4z" }
--#endif

-- Every require at module scope: the build discovers modules by loading this
-- file under the shim, where OnDriverLateInit stops early, so a require in a
-- function would be left out of the .c4z.
require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")
JSON = require("JSON")

local log = require("lib.logging")
local persist = require("lib.persist")
local license = require("sbos.license")
local RelayHost = require("lib.relayhost")
local Core = require("venueflow.core")
local Relay = require("venueflow.relay")
local AdapterC4 = require("venueflow.adapter_c4")
local pageApp = require("venueflow.page_app")
local pageStudio = require("venueflow.page_studio")

gInitialized = false

local SKU = "SBOS_VENUEFLOW"
local C4Z_NAME = "smartbuildos-venueflow"
local FLIGHT_RECORDER_C4Z = "smartbuildos-flight-recorder.c4z"
local P_RELAY_TOKEN = "vf_relay_token_v1"
local P_SEED = "vf_seed_v1"
local WEBVIEW_BINDING = 5001
local UI_RELAY_PORT = 47861
local UI_RELAY_ID = "venueflow-ui-relay"
local MAX_REQUEST_BYTES = Relay.MAX_BODY + 16 * 1024
local STATUS_TIMER = "VfStatusPaint"
local REPUBLISH_TIMER = "VfRepublish"

local EVENTS = {
  scene_activated = 1,
  notification = 2,
  alert = 3,
  published = 4,
  venue_open = 5,
  venue_closed = 6,
  license_restricted = 7,
  license_restored = 8,
}

local gCore = nil
local gHost = nil
local gRelayPort = nil
local gRelayToken = nil
local gRelayBuffers = {}
local gRecorderId = nil
local gRecorderAsked = nil
local gLastError = "none"
local gSeed = nil
local gRandomCounter = 0

-- ─── Small helpers ──────────────────────────────────────────────────────────

local function trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function hmac(key, data)
  local ok, hex = pcall(function()
    return C4:HMAC("SHA256", tostring(key), tostring(data), { return_encoding = "HEX" })
  end)
  if ok and type(hex) == "string" and #hex >= 32 then
    return hex:lower()
  end
  error("C4:HMAC is not available")
end

--- A value nobody outside the driver can predict: an HMAC, keyed by a seed
--- kept in encrypted persistence, over a counter, the clocks and a fresh
--- table address.
local function seed()
  if gSeed ~= nil then
    return gSeed
  end
  local stored = persist:get(P_SEED, false, true)
  if type(stored) == "string" and #stored >= 32 then
    gSeed = stored
    return gSeed
  end
  local parts = { tostring(os.time()), tostring(os.clock()), tostring(C4:GetDeviceID()), tostring({}), tostring(log) }
  pcall(function()
    parts[#parts + 1] = tostring(C4:UUID("Random"))
  end)
  pcall(function()
    parts[#parts + 1] = tostring(C4:GetTime())
  end)
  gSeed = hmac("venueflow-seed", table.concat(parts, "|"))
  persist:set(P_SEED, gSeed, true)
  return gSeed
end

local function random()
  gRandomCounter = gRandomCounter + 1
  local parts = { tostring(gRandomCounter), tostring(os.time()), tostring(os.clock()), tostring({}) }
  pcall(function()
    parts[#parts + 1] = tostring(C4:GetTime())
  end)
  return hmac(seed(), table.concat(parts, "|"))
end

local function controlMode()
  return tostring(Properties["Control Mode"] or "Simulation") == "Live" and "live" or "simulation"
end

local function passcode()
  return trim(Properties["Installer Passcode"])
end

-- ─── Flight Recorder (quiet when absent) ────────────────────────────────────

local function recorderId()
  if gRecorderId ~= nil then
    return gRecorderId
  end
  local t = os.time()
  if gRecorderAsked ~= nil and t - gRecorderAsked < 60 then
    return nil
  end
  gRecorderAsked = t
  local ok, found = pcall(function()
    return C4:GetDevicesByC4iName(FLIGHT_RECORDER_C4Z)
  end)
  if ok and type(found) == "table" then
    for rawId in pairs(found) do
      local id = tonumber(rawId)
      if id ~= nil then
        gRecorderId = id
        return id
      end
    end
  end
  return nil
end

--- One marker in the project's common history. Never throws, never blocks.
local function record(name, detail)
  local id = recorderId()
  if id == nil then
    return
  end
  pcall(function()
    C4:SendToDevice(
      id,
      "RECORD_EVENT",
      { NAME = "VenueFlow: " .. tostring(name), DETAIL = tostring(detail or ""), CHANNEL = "venueflow" }
    )
  end)
end

-- ─── Status on the property page ────────────────────────────────────────────

local function relayHost()
  if gHost == nil then
    return ""
  end
  return (gHost:host())
end

local function paint()
  if gCore == nil then
    return
  end
  local ok, s = pcall(function()
    return gCore:summary()
  end)
  if not ok or type(s) ~= "table" then
    return
  end
  UpdateProperty("Venue", s.venue)
  UpdateProperty("Configuration", s.configuration .. (s.mode == "Simulation" and " [SIMULATION]" or ""))
  UpdateProperty("Draft", s.draft)
  UpdateProperty("Venue Status", s.status)
  UpdateProperty("Active Scene", s.scene)
  UpdateProperty("Alerts", tostring(s.alerts))
  UpdateProperty("Last Error", gLastError)
  local studio
  if #passcode() < 6 then
    studio = "Off - set an Installer Passcode (6+ characters)"
  elseif gRelayPort == nil or relayHost() == "" then
    studio = "On - address unknown (see App Data Relay)"
  else
    studio = string.format("http://%s:%d/studio", relayHost(), gRelayPort)
  end
  UpdateProperty("Installer Studio", studio)
end

-- ─── Relay (the pattern of Daypart, PIN Lock and Commissioning) ─────────────

local function relayToken()
  if gRelayToken ~= nil then
    return gRelayToken
  end
  local stored = persist:get(P_RELAY_TOKEN, false, true)
  if type(stored) == "string" and #stored >= 16 then
    gRelayToken = stored
    return stored
  end
  gRelayToken = random():sub(1, 32)
  persist:set(P_RELAY_TOKEN, gRelayToken, true)
  return gRelayToken
end

--- The pages are compiled into the driver (tools/embed-pages.lua): on OS 4.3 a
--- driver may not read its own c4z files.
local function page(name)
  local html = name == "studio" and pageStudio or pageApp
  if type(html) == "string" and #html >= 512 then
    return html
  end
  return nil
end

local function relayDeps(client)
  return {
    tileToken = relayToken(),
    handle = function(request, transport)
      return gCore:handle(request, transport)
    end,
    encode = function(t)
      return JSON:encode(t)
    end,
    decode = function(s)
      return JSON:decode(s)
    end,
    upload = function(session, dataUrl, transport)
      return gCore:upload(session, dataUrl, transport)
    end,
    page = page,
    client = client,
  }
end

function OnServerDataIn(handle, data, address, _, identifier)
  if identifier ~= nil and identifier ~= UI_RELAY_ID then
    return
  end
  local entry = gRelayBuffers[handle]
  if entry == nil then
    entry = { rx = Relay.receiver(), address = address }
    gRelayBuffers[handle] = entry
  end
  local req = Relay.feed(entry.rx, data)
  if req == nil then
    -- Still arriving. (An oversize or malformed request is answered by the router below.)
    if entry.rx.size > MAX_REQUEST_BYTES then
      req = { method = "TOO_LARGE" }
    else
      return
    end
  end
  gRelayBuffers[handle] = nil
  local result
  if gCore == nil then
    result = { status = "503 Service Unavailable", contentType = "application/json", body = '{"ok":false}' }
  else
    local ok, routed = pcall(Relay.route, req, relayDeps(type(entry.address) == "string" and entry.address or nil))
    if ok then
      result = routed
    else
      gLastError = "relay: " .. tostring(routed):sub(1, 120)
      log:error("VenueFlow relay failed: %s", tostring(routed))
      result = { status = "500 Internal Server Error", contentType = "application/json", body = '{"ok":false}' }
    end
  end
  pcall(function()
    C4:ServerSend(handle, Relay.render(result))
  end)
  pcall(function()
    C4:ServerCloseClient(handle)
  end)
end

--- A client that goes away before finishing a request must not leave its
--- buffer behind.
function OnServerConnectionStatusChanged(handle, _, status)
  if tostring(status):upper() ~= "ONLINE" then
    gRelayBuffers[handle] = nil
  end
end

local function startRelay()
  if gRelayPort ~= nil then
    return
  end
  local ok = pcall(function()
    C4:CreateServer(UI_RELAY_PORT, "", false, UI_RELAY_ID)
  end)
  if ok then
    gRelayPort = UI_RELAY_PORT
    log:info("VenueFlow relay listening on port %d", UI_RELAY_PORT)
  else
    gLastError = "relay could not listen on port " .. UI_RELAY_PORT
    log:warn("%s", gLastError)
  end
end

local function stopRelay()
  if gRelayPort ~= nil then
    pcall(function()
      C4:DestroyServer(gRelayPort)
    end)
    gRelayPort = nil
  end
  gRelayBuffers = {}
end

local function encodeParam(s)
  return (tostring(s):gsub("[^%w%-%._~]", function(ch)
    return string.format("%%%02X", ch:byte())
  end))
end

local function desiredWebViewUrl()
  local host = gRelayPort ~= nil and relayHost() or ""
  if host ~= "" and page("app") ~= nil then
    return string.format("http://%s:%d/app?k=%s", host, gRelayPort, relayToken())
  end
  local base = "controller://driver/" .. C4Z_NAME .. "/app/index.html"
  if host == "" then
    return base
  end
  return base .. "?relay=" .. encodeParam(string.format("http://%s:%d", host, gRelayPort)) .. "&k=" .. relayToken()
end

local function paintRelay()
  local line
  if gRelayPort == nil then
    line = string.format("Not listening - port %d unavailable", UI_RELAY_PORT)
  else
    line = gHost:statusLine()
  end
  UpdateProperty("App Data Relay", line)
end

local function publishWebViewUrl(reason)
  local url = desiredWebViewUrl()
  pcall(function()
    C4:SendToProxy(WEBVIEW_BINDING, "URL_CHANGED", { url = url })
  end)
  paintRelay()
  paint()
  log:debug("VenueFlow URL published (%s): %s", tostring(reason), (url:gsub("k=[%w]+", "k=[token]")))
end

gHost = RelayHost.new({
  port = UI_RELAY_PORT,
  service = "venueflow",
  configured = function()
    return Properties["App Relay Address"]
  end,
  onChange = function()
    if gInitialized then
      publishWebViewUrl("address confirmed")
    end
  end,
})

-- ─── Navigator bridge (documented WebView JavaScript API) ───────────────────
-- The page calls C4.sendCommand("VF_COMMAND", '{"ENVELOPE":"<json>"}', true, true),
-- which arrives here; the reply goes back through C4:SendDataToUI and the
-- page's onDataToUi. Only a Navigator showing this driver's own page can call
-- it, so it is treated like the tile. The relay is the primary transport: a
-- field finding in this repository is that this reply channel can deliver
-- nothing on a touch screen.

-- The envelope can carry a PIN or a session token: never in the debug log.
EC.suppressDebug = EC.suppressDebug or {}
EC.suppressDebug.VF_COMMAND = true

function EC.VF_COMMAND(tParams)
  tParams = tParams or {}
  if gCore == nil then
    return
  end
  local ok, request = pcall(function()
    return JSON:decode(tostring(tParams.ENVELOPE or ""))
  end)
  if not ok or type(request) ~= "table" then
    return
  end
  local reply = gCore:handle(request, { tile = true, via = "bridge" })
  pcall(function()
    if C4.SendDataToUI ~= nil then
      C4:SendDataToUI("VF_REPLY", { ENVELOPE = JSON:encode(reply) })
    end
  end)
end

-- ─── Core wiring ────────────────────────────────────────────────────────────

local function fire(key)
  local id = EVENTS[key]
  if id ~= nil then
    pcall(function()
      C4:FireEventByID(id)
    end)
  end
end

local function setVar(name, value)
  pcall(function()
    C4:SetVariable(name, tostring(value))
  end)
end

local function buildCore()
  local liveAdapter = nil
  return Core.new({
    kv = {
      get = function(key)
        -- lib.persist answers a missing key with its default; `false` here so
        -- a missing key is nil to the core, not an empty table.
        local value = persist:get(key, false)
        if value == false then
          return nil
        end
        return value
      end,
      set = function(key, value)
        persist:set(key, value)
      end,
      delete = function(key)
        persist:delete(key)
      end,
    },
    now = os.time,
    localtime = function(epoch)
      return os.date("*t", math.floor(epoch))
    end,
    timers = {
      set = function(id, ms, fn, repeating)
        SetTimer(id, ms, fn, repeating == true)
      end,
      cancel = function(id)
        CancelTimer(id)
      end,
    },
    json = {
      encode = function(t)
        return JSON:encode(t)
      end,
      decode = function(s)
        return JSON:decode(s)
      end,
    },
    hmac = hmac,
    random = random,
    liveAdapter = function()
      if liveAdapter == nil then
        liveAdapter = AdapterC4.new({
          c4 = C4,
          log = log,
          register = RegisterVariableListener,
          unregister = UnregisterVariableListener,
        })
      end
      return liveAdapter
    end,
    mode = controlMode,
    license = {
      enforces = license.enforces,
      label = license.statusLabel,
      describe = function()
        return {
          status = license.status(),
          source = license.licenseSource(),
          tier = license.subscriptionTier(),
          company = license.companyName(),
          enforcement = license.enforcementMode(),
          sku = SKU,
        }
      end,
      refresh = function()
        license.check()
      end,
    },
    passcode = passcode,
    record = record,
    fireEvent = function(key)
      fire(key)
      -- Every event marks a change the property page should show at once.
      pcall(paint)
    end,
    setVariable = setVar,
    log = log,
    info = function()
      return {
        host = relayHost(),
        port = gRelayPort,
        relay = tostring(Properties["App Data Relay"] or ""),
        sku = SKU,
      }
    end,
    version = tostring(Properties["Driver Version"] or ""),
  })
end

-- ─── Lifecycle ──────────────────────────────────────────────────────────────

local function registerComposerSurface()
  for _, v in ipairs({
    { "VENUE_STATUS", "closed", "STRING" },
    { "ACTIVE_SCENE", "", "STRING" },
    { "NOTIFICATION_TEXT", "", "STRING" },
    { "ALERT_COUNT", "0", "NUMBER" },
  }) do
    pcall(function()
      C4:AddVariable(v[1], v[2], v[3], true)
    end)
  end
  for _, e in ipairs({
    { 1, "Scene Activated", "A VenueFlow scene started (ACTIVE_SCENE says which)" },
    { 2, "Notification", "A scene or rule sent a notification (NOTIFICATION_TEXT holds it)" },
    { 3, "Alert Raised", "VenueFlow raised an alert for the manager" },
    { 4, "Configuration Published", "The installer published a new venue configuration" },
    { 5, "Venue Opened", "The venue was marked open" },
    { 6, "Venue Closed", "The venue was marked closed" },
    { 7, "Licence Restricted", "Scenes, schedules and publishing are off; manual control continues" },
    { 8, "Licence Restored", "Scenes, schedules and publishing work again" },
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
  log:setLogName("VenueFlow")
  log:setLogLevel(Properties["Log Level"])
  log:setLogMode(Properties["Log Mode"])
end

function OnDriverLateInit()
  if not CheckMinimumVersion("Driver Status") then
    return
  end
  registerComposerSurface()
  for p, _ in pairs(Properties) do
    pcall(OnPropertyChanged, p)
  end
  pcall(function()
    UpdateProperty("Driver Version", tostring(C4:GetDriverConfigInfo("version")))
  end)

  license.setup({ sku = SKU })
  EC.SBOS_ENTITLEMENT = function(tParams)
    license.onEntitlement(tParams)
    if gCore ~= nil then
      gCore:licenseChanged()
      paint()
    end
  end

  local ok, err = pcall(function()
    gCore = buildCore()
    gCore:start()
  end)
  if not ok then
    gCore = nil
    gLastError = "core failed to start: " .. tostring(err):sub(1, 160)
    log:error("%s", gLastError)
    UpdateProperty("Driver Status", "Error - see Last Error")
    UpdateProperty("Last Error", gLastError)
    return
  end

  gInitialized = true
  UpdateProperty("Driver Status", controlMode() == "live" and "Online" or "Online - Simulation")
  startRelay()
  gHost:check()
  publishWebViewUrl("late init")
  SetTimer(REPUBLISH_TIMER, 60 * ONE_SECOND, function()
    publishWebViewUrl("60s republish")
  end)
  SetTimer(STATUS_TIMER, 30 * ONE_SECOND, function()
    if gRelayPort ~= nil then
      gHost:checkIfDue()
    end
    paintRelay()
    paint()
  end, true)
  paint()
  record("driver started", controlMode())
end

function OnDriverDestroyed()
  pcall(license.stop)
  stopRelay()
  if gCore ~= nil then
    pcall(function()
      gCore:stop()
    end)
  end
  CancelTimer(STATUS_TIMER)
  CancelTimer(REPUBLISH_TIMER)
end

-- ─── Properties ─────────────────────────────────────────────────────────────

-- The Installer Passcode must never reach the debug log: Handlers print a
-- property's value on change unless suppressDebug names it (both spellings:
-- the name is consulted before sanitising).
OPC.suppressDebug = OPC.suppressDebug or {}
OPC.suppressDebug["Installer Passcode"] = true
OPC.suppressDebug["Installer_Passcode"] = true

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

function OPC.App_Relay_Address()
  if gInitialized then
    gHost:check()
    publishWebViewUrl("relay address changed")
  end
end

function OPC.Control_Mode()
  if gInitialized and gCore ~= nil then
    gCore:modeChanged()
    UpdateProperty("Driver Status", controlMode() == "live" and "Online" or "Online - Simulation")
    record("control mode", controlMode())
    paint()
  end
end

--- A changed passcode ends every Installer Studio session and clears locks.
function OPC.Installer_Passcode()
  if gInitialized and gCore ~= nil then
    gCore.auth:revoke("installer")
    gCore.auth:resetGates()
    paint()
  end
end

-- ─── Actions ────────────────────────────────────────────────────────────────

function EC.REGISTER_NOW()
  license.register()
end

function EC.PRINT_STUDIO_LINK()
  if #passcode() < 6 then
    log:print("Installer Studio is off: set the Installer Passcode property (6 or more characters).")
    return
  end
  if gRelayPort == nil or relayHost() == "" then
    log:print("Installer Studio: the controller address is not known yet. See the App Data Relay property.")
    return
  end
  log:print("Installer Studio: http://%s:%d/studio  (sign in with the Installer Passcode)", relayHost(), gRelayPort)
end

function EC.PRINT_PAGE_LINK()
  -- Printed, not logged: the dealer asked for it, and the link carries the tile token.
  log:print("Operator page link: %s", desiredWebViewUrl())
end

function EC.REFRESH_STATUS()
  if gCore ~= nil then
    gCore:refreshAll()
  end
  paint()
end

function EC.RELOAD()
  if gCore == nil then
    return
  end
  gCore:load("Composer reload")
  gHost:check()
  publishWebViewUrl("reload")
  record("reloaded", "Composer")
end

function EC.END_STAFF_SESSIONS()
  if gCore ~= nil then
    local n = gCore.auth:revoke("profile")
    log:print("VenueFlow: %d staff session(s) ended.", n)
  end
end

function EC.RESET_SIGNIN_LOCKS()
  if gCore ~= nil then
    gCore.auth:resetGates()
    log:print("VenueFlow: sign-in locks cleared.")
  end
end

function EC.PRINT_STATUS()
  if gCore == nil then
    log:print("VenueFlow core is not running: %s", gLastError)
    return
  end
  local s = gCore:summary()
  log:print("== VenueFlow ==")
  log:print("  venue: %s", s.venue)
  log:print("  configuration: %s", s.configuration)
  log:print("  draft: %s", s.draft)
  log:print("  control mode: %s", s.mode)
  log:print("  venue status: %s, active scene: %s, alerts: %s", s.status, s.scene, tostring(s.alerts))
  log:print("  licence: %s", license.describe())
  log:print("  relay: %s", tostring(Properties["App Data Relay"]))
  log:print("  installer studio: %s", tostring(Properties["Installer Studio"]))
  for _, e in ipairs(gCore.diag:list({ limit = 15, level = "warning" })) do
    log:print("  [%s] %s %s: %s", e.level, tostring(e.category), tostring(e.code or ""), tostring(e.message))
  end
  if gLastError ~= "none" then
    log:print("  last error: %s", gLastError)
  end
end

-- ─── Composer programming ───────────────────────────────────────────────────

local function composer(command, tParams)
  if gCore == nil then
    return
  end
  local ok, done, message = pcall(function()
    return gCore:composer(command, tParams or {})
  end)
  if not ok then
    gLastError = command .. ": " .. tostring(done):sub(1, 140)
    log:error("%s", gLastError)
  elseif not done then
    gLastError = command .. " refused: " .. tostring(message)
    log:warn("%s", gLastError)
  end
  paint()
end

function EC.ACTIVATE_SCENE(tParams)
  composer("ACTIVATE_SCENE", tParams)
end

function EC.TRIGGER_EVENT(tParams)
  composer("TRIGGER_EVENT", tParams)
end

function EC.ROUTE_SOURCE(tParams)
  composer("ROUTE_SOURCE", tParams)
end

function EC.SET_VENUE_STATUS(tParams)
  composer("SET_VENUE_STATUS", tParams)
end

function EC.ALL_OFF()
  composer("ALL_OFF", {})
end

-- ─── Conditionals (TestCondition name, tParams{VALUE, LOGIC}) ──────────────

function TC.VENUE_OPEN()
  return gCore ~= nil and gCore.runtime.venueStatus == "open"
end

function TC.HAS_ALERTS()
  if gCore == nil then
    return false
  end
  local ok, s = pcall(function()
    return gCore:summary()
  end)
  return ok and (tonumber(s.alerts) or 0) > 0
end

--- "= name" is true when that scene is the active one; "!= name" when not.
function TC.SCENE_ACTIVE(_, tParams)
  tParams = tParams or {}
  local wanted = trim(tParams.VALUE):lower()
  local active = gCore ~= nil and gCore.runtime.activeScene or nil
  local answer = active ~= nil and (tostring(active.name):lower() == wanted or tostring(active.id) == wanted)
  if tostring(tParams.LOGIC or "EQUAL"):upper() == "NOT_EQUAL" then
    return not answer
  end
  return answer
end
