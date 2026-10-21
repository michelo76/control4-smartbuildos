--[[==========================================================================
  SmartBuildOS System Link — bridge driver

  One instance per project. Links THIS project to exactly one other project
  through SmartBuildOS: each side creates and owns its shared variables, the
  other side sees read-only mirrors; named events, request/result routines
  and (feature-gated) native companions cross the link.

  Division of labour:
    src/systemlink/*        pure logic, tested without a controller
    this file               Control4 glue: variables, events, properties,
                            actions, commands, conditionals, the Agent
                            handshake, the relay round trip and the doorbell

  The driver never holds the controller bearer: the SmartBuildOS Agent
  provisions a narrow endpoint credential (sbosl1.…) on request.
============================================================================]]

--#ifdef DRIVERCENTRAL
DC_PID = 0
DC_X = nil
DC_FILENAME = "smartbuildos-system-link.c4z"
--#else
DRIVER_GITHUB_REPO = "michelo76/control4-smartbuildos"
DRIVER_FILENAMES = { "smartbuildos-system-link.c4z" }
--#endif

require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")
require("drivers-common-public.global.url")
JSON = require("JSON")

local log = require("lib.logging")
local persist = require("lib.persist")
local http = require("lib.http")
local license = require("sbos.license")
local Engine = require("systemlink.engine")
local requests = require("systemlink.requests")
local schema = require("systemlink.schema")
local exportsModel = require("systemlink.exports")
local RealtimeClient = require("telemetry.realtime")
local WebSocket = require("drivers-common-public.module.websocket")

-- ─── Constants ───────────────────────────────────────────────────────────────

local SKU = "SBOS_SYSTEM_LINK"
local AGENT_FILES = { ["smartbuildos.c4z"] = true, ["smartbuildos.c4i"] = true }
local CREDENTIAL_KEY = "sl_credential" -- encrypted persist
local BACKUP_PROPERTY = "Link Credential Backup" -- hidden password mirror
local TICK_TIMER = "SlTick"
local SYNC_TIMER = "SlSyncNow"
local PROVISION_TIMER = "SlProvision"
local DOORBELL_HB_TIMER = "SlDoorbellHb"
local DOORBELL_RECONNECT_TIMER = "SlDoorbellReconnect"
local REQUEST_TIMEOUT = 20
local PROVISION_RETRY_S = 60

-- Static events (ids pinned forever; see Engine.EVENTS for the keys).
local EVENTS = {
  { 1, "Link Connected", "The relay accepted this bridge's credential." },
  { 2, "Link Disconnected", "The relay became unreachable or refused the link." },
  { 3, "Peer Online", "The linked project's bridge is heartbeating." },
  { 4, "Peer Offline", "The linked project's bridge has not been heard from." },
  { 5, "Peer Stale", "The linked project's heartbeat is late." },
  { 6, "Initial Sync Complete", "Definitions and the current snapshot are applied; live updates begin." },
  { 7, "Remote Variable Changed Live", "A mirrored variable changed after initial sync (not restore, not snapshot)." },
  { 8, "Remote State Current", "The aggregate Remote System State became Ready." },
  { 9, "Remote State Stale", "The aggregate Remote System State left Ready." },
  { 10, "Named Event Received", "The linked project emitted a named event (see Last_Event_* variables)." },
  { 11, "Request Received", "The linked project asked this project to run a routine (see Request_N_* variables)." },
  { 12, "Request Completed", "A request this project sent was reported successful." },
  { 13, "Request Failed", "A request this project sent was reported failed or refused." },
  { 14, "Request Expired", "A request this project sent reached its deadline without a confirmed outcome." },
  { 15, "Request Outcome Unknown", "A request's outcome can no longer be learned (link revoked, peer replaced)." },
  { 16, "Schema Attention", "The linked project's definitions changed in a way that needs review." },
  { 17, "License Changed", "The pair license state changed." },
  { 18, "Commands Paused", "Remote commands and requests are suspended; state keeps flowing." },
  { 19, "Commands Resumed", "Remote commands and requests resumed." },
  { 20, "Loop Suspended", "An item's traffic was suspended by the burst/loop guard." },
  { 21, "Link Paused", "The whole link is paused." },
  { 22, "Link Resumed", "The link resumed." },
}
local EVENT_ID = {}
for _, e in ipairs(EVENTS) do
  EVENT_ID[e[2]:upper():gsub("%s+", "_")] = e[1]
end

-- ─── State ───────────────────────────────────────────────────────────────────

gEngine = nil
gInitialized = false
local gAgentId = nil
local gPendingProvision = nil -- { id, expires }
local gSyncInFlight = false
local gSyncWanted = false
local gDoorbell = { ws = nil, client = nil, up = false, backoff = 15 }
local gLastStatus = {}
local EXPORTS_KEY = "sl_exports" -- { [id] = export }   local device ids never leave the controller
local COMPANIONS_KEY = "sl_companions" -- { [exportName] = deviceId }  peer-side companion mapping
local COMPANION_FILES = {
  light = "smartbuildos-system-link-light.c4z",
  relay = "smartbuildos-system-link-relay.c4z",
  contact = "smartbuildos-system-link-contact.c4z",
  temperature = "smartbuildos-system-link-temperature.c4z",
  thermostat = "smartbuildos-system-link-thermostat.c4z",
  shade = "smartbuildos-system-link-shade.c4z",
}
gExports = nil
gCompanionMap = nil
local gCompanionSubscribers = {} -- [exportName] = { [deviceId] = true }
local gAddCompanionInFlight = nil

-- ─── Time helpers ────────────────────────────────────────────────────────────

local function nowMs()
  if C4.GetTime then
    local ok, t = pcall(function()
      return C4:GetTime()
    end)
    if ok and type(t) == "number" and t > 0 then
      return t
    end
  end
  return os.time() * 1000
end

local function utcOffsetSeconds()
  local t = os.time()
  local utc = os.date("!*t", t)
  utc.isdst = os.date("*t", t).isdst
  return os.difftime(t, os.time(utc))
end

local function isoNow()
  return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

local function parseIso(s)
  local y, mo, d, h, mi, se = tostring(s):match("^(%d+)%-(%d+)%-(%d+)T(%d+):(%d+):(%d+)")
  if not y then
    return nowMs()
  end
  local t = os.time({
    year = tonumber(y),
    month = tonumber(mo),
    day = tonumber(d),
    hour = tonumber(h),
    min = tonumber(mi),
    sec = tonumber(se),
  })
  return (t + utcOffsetSeconds()) * 1000
end

local function formatTime(ms)
  return os.date("%Y-%m-%d %H:%M:%S", math.floor(ms / 1000))
end

local function timezone()
  if C4.GetTimeZone then
    local ok, tz = pcall(function()
      return C4:GetTimeZone()
    end)
    if ok and type(tz) == "string" then
      return tz
    end
  end
  return ""
end

local function uuid()
  local ok, v = pcall(function()
    return tostring(C4:UUID("Random"))
  end)
  if ok and v ~= "" then
    return v
  end
  return string.format(
    "%08x-%04x-4%03x-8%03x-%012x",
    math.random(0, 0xffffffff),
    math.random(0, 0xffff),
    math.random(0, 0xfff),
    math.random(0, 0xfff),
    math.random(0, 0xffffffffffff)
  )
end

-- ─── Agent discovery (exact filename, never substring) ───────────────────────

local function findAgent()
  if gAgentId then
    return gAgentId
  end
  local ok, devices = pcall(function()
    return C4:GetDevices({})
  end)
  if not ok or type(devices) ~= "table" then
    return nil
  end
  for rawId, device in pairs(devices) do
    local id = tonumber(rawId)
    local file = tostring((type(device) == "table" and device.driverFileName) or "")
    if id and AGENT_FILES[file] then
      gAgentId = id
      return id
    end
  end
  return nil
end

-- ─── Engine io ───────────────────────────────────────────────────────────────

local function updateStatus(name, value)
  value = tostring(value or "")
  if gLastStatus[name] ~= value then
    gLastStatus[name] = value
    UpdateProperty(name, value)
  end
end

-- A refusal the dealer must read (bad export name, mirror write, missing
-- device…). It goes to Last Error AND the Lua tab, and the engine's status
-- repaint keeps it (gEngine.lastError) instead of blanking it a second later
-- (bench 2026-10-20: an export was refused and nothing said why).
gDealerError = gDealerError or nil
local function reportError(message)
  message = tostring(message or "")
  gDealerError = message ~= "" and message or nil
  updateStatus("Last Error", message)
  if gEngine then
    gEngine.lastError = message
  end
  if message ~= "" then
    log:print("System Link: %s", message)
  end
end

local function buildIo()
  local io = {}
  io.now = nowMs
  io.isoNow = isoNow
  io.parseIso = parseIso
  io.formatTime = formatTime
  io.timezone = timezone
  io.uuid = uuid
  io.driverVersion = function()
    return tostring(C4:GetDriverConfigInfo("version") or "")
  end
  io.load = function(key)
    -- lib.persist answers a missing key with its internal EMPTY table when
    -- the default is nil, never with nil. Ask with `false` and map it back,
    -- or a fresh install loads `{}` as its registry, link and requests.
    local v = persist:get(key, false)
    if v == false or v == nil then
      return nil
    end
    return v
  end
  io.save = function(key, value)
    persist:set(key, value)
  end
  io.addVariable = function(name, default, c4type, readOnly, hidden)
    pcall(function()
      C4:AddVariable(name, tostring(default or ""), c4type, readOnly == true, hidden == true)
    end)
  end
  io.setVariable = function(name, value)
    pcall(function()
      C4:SetVariable(name, tostring(value == nil and "" or value))
    end)
  end
  io.addEvent = function(id, name, description)
    pcall(function()
      C4:AddEvent(id, name, description)
    end)
  end
  io.fireEvent = function(key)
    local id = EVENT_ID[key]
    if id then
      pcall(function()
        C4:FireEventByID(id)
      end)
    end
  end
  io.fireItemEvent = function(itemId)
    local id = gEngine and gEngine.itemEvents[itemId]
    if id then
      pcall(function()
        C4:FireEventByID(id)
      end)
    end
  end
  io.property = updateStatus
  io.encode = function(t)
    return JSON:encode(t)
  end
  io.log = log
  io.slots = tonumber(Properties["Request Slots"]) or 4
  io.onCommand = function(body, id)
    return OnSystemLinkCommand(body, id)
  end
  io.onMirrorApplied = function(def, tv, kind)
    OnSystemLinkMirrorApplied(def, tv, kind)
  end
  io.onCommandResult = function(id, cmd, status, reason)
    OnSystemLinkCommandResult(id, cmd, status, reason)
  end
  return io
end

-- ─── Credential storage (encrypted persist + hidden backup property) ─────────

local function storeCredential(info)
  local blob = JSON:encode(info)
  persist:set(CREDENTIAL_KEY, blob, true)
  pcall(function()
    C4:UpdateProperty(BACKUP_PROPERTY, blob)
  end)
end

local function loadCredential()
  local blob = persist:get(CREDENTIAL_KEY, false, true)
  if type(blob) ~= "string" or blob == "" then
    blob = Properties[BACKUP_PROPERTY] or ""
  end
  if blob == "" then
    return nil
  end
  local ok, info = pcall(function()
    return JSON:decode(blob)
  end)
  if ok and type(info) == "table" and info.credential then
    return info
  end
  return nil
end

local function clearCredential()
  persist:delete(CREDENTIAL_KEY)
  pcall(function()
    C4:UpdateProperty(BACKUP_PROPERTY, "")
  end)
end

-- ─── Provisioning handshake with the Agent ───────────────────────────────────

-- What the dealer reads under "Link Authorization" while there is no link:
-- the Agent's last answer (or its silence), not the engine's generic
-- "Not provisioned", which paintStatus would otherwise repaint every second
-- over the one message that says why.
gProvisionMessage = gProvisionMessage or nil

local function setProvisionMessage(message)
  gProvisionMessage = message
  updateStatus("Link Authorization", message)
  if gEngine then
    gEngine.lastError = message
  end
end

local function requestProvision()
  local agent = findAgent()
  if not agent then
    setProvisionMessage("No SmartBuildOS Agent found — add the free Connector first")
    return false
  end
  if gPendingProvision and os.time() <= gPendingProvision.expires then
    return false
  end
  local requestId = uuid()
  gPendingProvision = { id = requestId, expires = os.time() + 60 }
  local ok = pcall(function()
    C4:SendToDevice(agent, "SBOS_LINK_PROVISION_REQUEST", {
      requester = tostring(C4:GetDeviceID()),
      request_id = requestId,
      driver_version = tostring(C4:GetDriverConfigInfo("version") or ""),
      protocol_min = "1",
      protocol_max = "1",
      timezone = timezone(),
    })
  end)
  if not ok then
    gPendingProvision = nil
    setProvisionMessage("Could not reach the SmartBuildOS Agent (SendToDevice failed)")
    return false
  end
  gProvisionMessage = "Asking the Agent for this system's link…"
  updateStatus("Link Authorization", gProvisionMessage)
  return ok
end

local startSync, doorbellConnect, doorbellStop, paintSelectedValue, paintPendingExports, paintItemList

function EC.SBOS_LINK_PROVISION(tParams)
  tParams = tParams or {}
  local pending = gPendingProvision
  if not pending or os.time() > pending.expires or tostring(tParams.request_id or "") ~= pending.id then
    return
  end
  gPendingProvision = nil
  if tParams.error and tParams.error ~= "" then
    setProvisionMessage("Agent: " .. tostring(tParams.error))
    SetTimer(PROVISION_TIMER, PROVISION_RETRY_S * ONE_SECOND, requestProvision)
    return
  end
  local ok, info = pcall(function()
    return JSON:decode(tostring(tParams.info or ""))
  end)
  if
    not ok
    or type(info) ~= "table"
    or tostring(info.credential or ""):find("^sbosl1%.") == nil
    or tostring(info.relay_url or ""):find("^https://") == nil
  then
    setProvisionMessage("Agent returned an unusable link provision")
    SetTimer(PROVISION_TIMER, PROVISION_RETRY_S * ONE_SECOND, requestProvision)
    return
  end
  gProvisionMessage = nil
  if gEngine then
    gEngine.lastError = nil
  end
  storeCredential(info)
  gEngine:onProvisioned(info)
  gEngine:ensureRequestSlotVariables()
  updateStatus("Link Authorization", tostring(info.link_state or "approved"))
  log:info(
    "System Link provisioned: endpoint %s gen %s (peer %s)",
    tostring(info.endpoint_id),
    tostring(info.generation),
    tostring(info.peer and info.peer.alias)
  )
  startSync()
  doorbellConnect(info.realtime)
end

-- ─── Relay round trip ────────────────────────────────────────────────────────

local function licenseAllowsTraffic()
  -- Uncertain states fail open (charter); only a definitive deny stops
  -- outbound traffic. Mirrors keep their last-known values and go stale.
  return not license.enforces()
end

local function doSync()
  if not gEngine or not gEngine.link or gSyncInFlight then
    gSyncWanted = gSyncInFlight
    return
  end
  if not licenseAllowsTraffic() then
    gEngine:setLicense(license.status(), false, license.enforcementReason())
    gEngine:updateRemoteState()
    return
  end
  local body = gEngine:buildSync()
  if not body then
    return
  end
  gSyncInFlight = true
  http
    :post(
      gEngine.link.relay_url,
      body,
      { Authorization = "Bearer " .. tostring(gEngine.link.credential) },
      { timeout = REQUEST_TIMEOUT }
    )
    :next(function(response)
      gSyncInFlight = false
      local decoded = response.body
      local raw = type(decoded) == "string" and decoded or nil
      if type(decoded) == "string" then
        local okDecode, parsed = pcall(function()
          return JSON:decode(decoded)
        end)
        decoded = okDecode and parsed or nil
      end
      gEngine:onSyncResponse(decoded, raw and #raw or nil)
      if gEngine.needReprovision then
        gEngine.needReprovision = nil
        requestProvision()
      end
      if gSyncWanted then
        gSyncWanted = false
        SetTimer(SYNC_TIMER, 200, doSync)
      end
    end, function(err)
      gSyncInFlight = false
      local code = tonumber(err and err.code) or 0
      if code == 401 then
        -- Credential superseded (reinstall, replacement, revoke): ask again.
        gEngine:onSyncFailed("credential refused (401)")
        SetTimer(PROVISION_TIMER, 5 * ONE_SECOND, requestProvision)
      elseif code == 409 then
        gEngine:onSyncFailed("relay refused: " .. tostring(err and err.body or "409"))
      else
        gEngine:onSyncFailed(code == 0 and "unreachable" or ("HTTP " .. tostring(code)))
      end
    end)
end

-- Link Health: the transport facts a dealer needs when "it is slow" —
-- all from state the engine and the doorbell glue already keep.
local function paintLinkHealth()
  if not gEngine then
    return
  end
  local e = gEngine
  local doorbell
  if not gDoorbell.up then
    doorbell = "not joined" .. (e.lastDoorbellAt and (" · last rang " .. formatTime(e.lastDoorbellAt)) or "")
  elseif e.lastDoorbellAt then
    doorbell = (e:doorbellLive() and "joined · last rang " or "joined · silent since ") .. formatTime(e.lastDoorbellAt)
  else
    doorbell = "joined · never rang — polling"
  end
  updateStatus("Doorbell", doorbell)
  updateStatus(
    "Poll Interval",
    e:doorbellLive() and string.format("doorbell-driven (poll every %d s as backstop)", Engine.POLL_FALLBACK_MS / 1000)
      or string.format("%d s", Engine.POLL_FALLBACK_MS / 1000)
  )
  local r = e.lastRefusal
  updateStatus("Last Relay Refusal", r and string.format("%s: %s · %s", tostring(r.what), tostring(r.reason), formatTime(r.at)) or "none")
  updateStatus(
    "Relay Latency",
    e.latency and e.latency.p95_ms and string.format("p95 %d ms (%d samples)", e.latency.p95_ms, #e.latency.samples) or "no samples"
  )
  updateStatus("Pending", string.format("%d updates · %d requests", #e.pending, requests.inFlight(e.requests)))
end

local function paintStatus()
  if not gEngine then
    return
  end
  for name, value in pairs(gEngine:statusProperties()) do
    updateStatus(name, value)
  end
  if gDealerError then
    -- The engine blanks its own lastError on every good sync; a dealer's
    -- refusal stays until the next dealer action replaces or clears it.
    updateStatus("Last Error", gDealerError)
  end
  paintSelectedValue()
  paintLinkHealth()
  -- Inbound schema changes (the peer exported a device) arrive on a sync,
  -- not on a dealer action: the lists are repainted here, deduped.
  if paintItemList then
    paintItemList()
  end
  if paintPendingExports then
    paintPendingExports()
  end
  if not gEngine.link then
    -- An unanswered request means the Agent has no SBOS_LINK_PROVISION_REQUEST
    -- handler (older build) or never got the message: say so and ask again,
    -- instead of waiting silently for a reply that cannot come.
    if gPendingProvision and os.time() > gPendingProvision.expires then
      gPendingProvision = nil
      setProvisionMessage(
        "The SmartBuildOS Agent did not answer the link request — update the Agent to a build with System Link support"
      )
      SetTimer(PROVISION_TIMER, PROVISION_RETRY_S * ONE_SECOND, requestProvision)
    end
    if gProvisionMessage then
      updateStatus("Link Authorization", gProvisionMessage)
      -- Painted every tick: updateStatus (deduped), never reportError (prints).
      updateStatus(
        "Last Error",
        gProvisionMessage == "Asking the Agent for this system's link…" and "" or gProvisionMessage
      )
    end
  end
  updateStatus("License State", license.statusLabel())
  updateStatus("Installed Version", tostring(C4:GetDriverConfigInfo("version") or ""))
end

local function tick()
  if not gEngine then
    return
  end
  local due = gEngine:tick(gDoorbell.up)
  if due then
    doSync()
  end
  paintStatus()
end

startSync = function()
  CancelTimer(TICK_TIMER)
  SetTimer(TICK_TIMER, ONE_SECOND, tick, true)
  SetTimer(SYNC_TIMER, 100, doSync)
end

-- ─── Doorbell (contentless Realtime socket; see telemetry.realtime) ──────────

doorbellStop = function()
  CancelTimer(DOORBELL_HB_TIMER)
  CancelTimer(DOORBELL_RECONNECT_TIMER)
  if gDoorbell.ws then
    pcall(function()
      gDoorbell.ws:delete()
    end)
  end
  gDoorbell.ws, gDoorbell.client, gDoorbell.up = nil, nil, false
end

doorbellConnect = function(cfg)
  doorbellStop()
  if type(cfg) ~= "table" or not cfg.url or not cfg.key or not cfg.channel then
    return
  end
  local url = RealtimeClient.socketUrl(cfg.url, cfg.key)
  if not url then
    return
  end
  local client = RealtimeClient.new({
    encode = function(t)
      return JSON:encode(t)
    end,
    decode = function(raw)
      return JSON:decode(raw)
    end,
  })
  local ws = WebSocket:new(url)
  local function retry()
    SetTimer(DOORBELL_RECONNECT_TIMER, gDoorbell.backoff * ONE_SECOND, function()
      doorbellConnect(cfg)
    end)
    gDoorbell.backoff = math.min(gDoorbell.backoff * 2, 300)
  end
  if not ws then
    retry()
    return
  end
  gDoorbell.ws, gDoorbell.client = ws, client
  ws:SetEstablishedFunction(function()
    ws:Send(client:joinFrame(cfg.channel))
    SetTimer(DOORBELL_HB_TIMER, 30 * ONE_SECOND, function()
      if gDoorbell.ws and gDoorbell.client then
        pcall(function()
          gDoorbell.ws:Send(gDoorbell.client:heartbeatFrame())
        end)
      end
    end, true)
  end)
  ws:SetProcessMessageFunction(function(_, data)
    local event = client:handleFrame(data)
    if event.type == "joined" then
      gDoorbell.up = true
      gDoorbell.backoff = 15
      log:info("System Link doorbell connected (%s)", tostring(cfg.channel))
    elseif event.type == "ping" then
      -- The relay says "there is a new sequence". The reaction is the same
      -- authenticated sync; nothing on the socket is ever acted upon.
      if gEngine then
        gEngine:onDoorbell()
      end
      SetTimer(SYNC_TIMER, 100, doSync)
    elseif event.type == "closed" then
      gDoorbell.up = false
      retry()
    end
  end)
  ws:SetClosedByRemoteFunction(function()
    gDoorbell.up = false
    retry()
  end)
  ws:Start()
end

-- ─── Licensing ───────────────────────────────────────────────────────────────

function EC.SBOS_ENTITLEMENT(tParams)
  license.onEntitlement(tParams)
  if gEngine then
    local ok = not license.enforces()
    gEngine:setLicense(license.status(), ok, ok and nil or license.enforcementReason())
    gEngine:updateRemoteState()
  end
  paintStatus()
end

function EC.REFRESH_LICENSE()
  license.register()
  license.check()
end

-- ─── Composer: item workflow (properties as the form, actions as the buttons)

local function selectedItem()
  local name = tostring(Properties["Selected Item"] or "")
  if name == "" or name == "-" then
    return nil
  end
  return gEngine and gEngine:findByName(name) or nil
end

-- Composer's own "variable = value" programming writes the driver's variable
-- directly and tells the driver through OnVariableChanged; without a handler
-- the write stays local and never publishes (bench, 2026-10-20: a dealer's
-- first instinct). Owned items get a handler that publishes like the Set
-- Local commands do; mirrors are read-only natives and get none. The echo
-- of the driver's own write is the same value and publishes nothing.
local function registerNativeWrites()
  if not gEngine or type(OVC) ~= "table" then
    return
  end
  local me = gEngine:selfEndpoint()
  for _, def in ipairs(schema.registryItems(gEngine.registry)) do
    local name = gEngine:variableNameFor(def)
    if not def.mirror and (def.owner == nil or def.owner == me) then
      OVC[name] = function(value)
        if not gEngine then
          return
        end
        local ok, err = gEngine:setLocal(def.id, value)
        if not ok then
          reportError(tostring(err))
          gEngine.lastError = tostring(err)
        end
      end
    else
      OVC[name] = nil
    end
  end
end

-- The selected item's actual value, as the link holds it right now: the
-- value, its freshness state, revision and when it was committed. Repainted
-- every tick so a dealer can watch a change land without leaving Composer.
paintSelectedValue = function()
  local def = gEngine and selectedItem()
  if not def then
    updateStatus("Selected Item Value", "—")
    return
  end
  local v = gEngine.values[def.id]
  if not v or not v.tv then
    updateStatus("Selected Item Value", "unknown · rev 0")
    return
  end
  local shown = v.tv.s == "current" and tostring(v.tv.v) or v.tv.s
  if v.tv.s ~= "current" and v.tv.v ~= nil then
    shown = string.format("%s (last %s)", v.tv.s, tostring(v.tv.v))
  end
  updateStatus(
    "Selected Item Value",
    string.format("%s · rev %s · %s", shown, tostring(v.rev or 0), v.src_at and formatTime(v.src_at) or "never")
  )
end

paintItemList = function()
  if not gEngine then
    return
  end
  registerNativeWrites()
  local names = { "-" }
  for _, def in ipairs(schema.registryItems(gEngine.registry)) do
    names[#names + 1] = gEngine:variableNameFor(def)
  end
  local joined = table.concat(names, ",")
  if gLastStatus["Selected Item__list"] ~= joined then
    gLastStatus["Selected Item__list"] = joined
    pcall(function()
      C4:UpdatePropertyList("Selected Item", joined, Properties["Selected Item"] or "-")
    end)
  end
  local def = selectedItem()
  if def then
    updateStatus(
      "Selected Item Details",
      string.format(
        "%s · %s · %s%s",
        def.mirror and "mirror (read-only)" or "owned",
        def.type,
        def.group and (def.group .. " · ") or "",
        def.description or ""
      )
    )
  else
    updateStatus("Selected Item Details", "Select an item")
  end
  paintSelectedValue()
end

local function readFilterForm()
  local f = {}
  local function num(name)
    local n = tonumber(Properties[name])
    if n and n > 0 then
      return n
    end
    return nil
  end
  f.debounce_s = num("Filter Debounce Seconds")
  f.threshold = num("Filter Change Threshold")
  f.min_interval_s = num("Filter Minimum Interval Seconds")
  f.max_silence_s = num("Filter Maximum Silence Seconds")
  if next(f) == nil then
    return nil
  end
  return f
end

function EC.CREATE_SHARED_ITEM()
  if not gEngine or not gEngine.link then
    reportError("Link is not provisioned yet")
    return
  end
  local def = {
    name = tostring(Properties["New Item Name"] or ""),
    type = tostring(Properties["New Item Type"] or "BOOLEAN"),
    description = tostring(Properties["New Item Description"] or ""),
    group = tostring(Properties["New Item Group"] or ""),
    export_enabled = tostring(Properties["New Item Export"] or "Yes") == "Yes",
  }
  if def.description == "" then
    def.description = nil
  end
  if def.group == "" then
    def.group = nil
  end
  if def.type == "CHOICE" then
    local raw = tostring(Properties["New Item Allowed Values"] or "")
    def.allowed_values = {}
    for v in raw:gmatch("[^,]+") do
      v = v:gsub("^%s+", ""):gsub("%s+$", "")
      if v ~= "" then
        def.allowed_values[#def.allowed_values + 1] = v
      end
    end
  end
  local created, err = gEngine:createItem(def, Properties["New Item Initial Value"])
  if not created then
    reportError("Create: " .. tostring(err))
    log:warn("Create Shared Item refused: %s", tostring(err))
    return
  end
  UpdateProperty("New Item Name", "")
  UpdateProperty("New Item Initial Value", "")
  UpdateProperty("Selected Item", gEngine:variableNameFor(created))
  reportError("")
  paintItemList()
  SetTimer(SYNC_TIMER, 100, doSync)
  log:info("Created shared item %s (%s)", gEngine:variableNameFor(created), created.type)
end

function EC.DELETE_SELECTED_ITEM()
  local def = selectedItem()
  if not def then
    return
  end
  if def.mirror then
    reportError("Mirrors are deleted by their owner; unshare it on the other system")
    return
  end
  local ok, err = gEngine:deleteItem(def.id)
  if not ok then
    reportError("Delete: " .. tostring(err))
    return
  end
  UpdateProperty("Selected Item", "-")
  paintItemList()
  SetTimer(SYNC_TIMER, 100, doSync)
  log:info(
    "Deleted %s; its Composer variable is kept hidden so existing programming still resolves",
    gEngine:variableNameFor(def)
  )
end

function EC.RENAME_SELECTED_ITEM()
  local def = selectedItem()
  local newName = tostring(Properties["New Item Name"] or "")
  if not def or newName == "" then
    return
  end
  local preview = gEngine:renamePreview(def.id, newName)
  if preview then
    log:print(
      "Rename effect: %s → %s. The variable id stays the same; programming keeps pointing at it under the new name.",
      preview.from,
      preview.to
    )
  end
  local ok, err = gEngine:renameItem(def.id, newName)
  if not ok then
    reportError("Rename: " .. tostring(err))
    return
  end
  UpdateProperty("New Item Name", "")
  UpdateProperty("Selected Item", gEngine:variableNameFor(def))
  paintItemList()
  SetTimer(SYNC_TIMER, 100, doSync)
end

function EC.APPLY_FILTER_TO_SELECTED_ITEM()
  local def = selectedItem()
  if not def then
    return
  end
  local ok, err = gEngine:updateItem(def.id, { filter = readFilterForm() })
  if not ok then
    reportError("Filter: " .. tostring(err))
    return
  end
  log:info("Filter applied to %s", gEngine:variableNameFor(def))
  SetTimer(SYNC_TIMER, 100, doSync)
end

function EC.PRINT_SHARED_ITEMS()
  if not gEngine then
    return
  end
  for _, def in ipairs(schema.registryItems(gEngine.registry)) do
    local v = gEngine.values[def.id]
    print(
      string.format(
        "%-40s %-8s %-7s %-12s rev=%s",
        gEngine:variableNameFor(def),
        def.type,
        def.mirror and "mirror" or "owned",
        v and v.tv.s or "unknown",
        tostring(v and v.rev or 0)
      )
    )
  end
end

-- ─── Source-device exports (owner side) ─────────────────────────────────────

local function licenseFeatures()
  -- Light, relay and sensor ship on every pair licence (and on a LEGACY
  -- Agent that cannot say). THERMOSTAT and SHADE are hardware-validation
  -- gates (SL-07): they open only when the entitlement names them
  -- explicitly — never through the licence SDK's fail-open LEGACY answer,
  -- because the gate is about unverified behaviour, not about billing.
  local set = { BASE = true, LIGHT = true, RELAY = true, SENSOR = true }
  if license.status() ~= "LEGACY" then
    for _, f in ipairs({ "THERMOSTAT", "SHADE" }) do
      if license.hasFeature(f) then
        set[f] = true
      end
    end
  end
  return set
end

local function loadExports()
  if gExports == nil then
    gExports = persist:get(EXPORTS_KEY, {}) or {}
  end
  return gExports
end

local function saveExports()
  persist:set(EXPORTS_KEY, gExports)
end

local function findExport(ref)
  ref = tostring(ref or "")
  for id, exp in pairs(loadExports()) do
    if id == ref or exp.name == ref then
      return exp
    end
  end
  return nil
end

local function exportItemFor(exp, suffix)
  local f = exp.fields and exp.fields[suffix]
  return f and f.item_id and gEngine.registry.items[f.item_id] or nil
end

--- A watched source variable changed: map it and publish the field. This is
--- the ONLY path that writes an export field — never a command.
local function onSourceVariable(exp, suffix, value)
  local def = exportItemFor(exp, suffix)
  if not def then
    return
  end
  local mapped = exportsModel.mapValue(exp, suffix, value)
  if mapped == nil then
    local cur = gEngine.values[def.id]
    if not cur or cur.tv.s ~= schema.STATES.UNAVAILABLE then
      gEngine.values[def.id] =
        { tv = schema.unavailable(), gen = gEngine.link.gen, rev = (cur and cur.rev or 0), src_at = nowMs() }
      gEngine:writeNative(def)
      gEngine:queueState(def, schema.unavailable())
      gEngine:persistAll()
    end
    return
  end
  gEngine:setLocal(def.id, mapped)
  SetTimer(SYNC_TIMER, 100, doSync)
end

local function watchExport(exp)
  local okV, vars = pcall(function()
    return C4:GetDeviceVariables(exp.device_id)
  end)
  if not okV or type(vars) ~= "table" then
    log:warn("Export %s: cannot read variables of device %s", exp.name, tostring(exp.device_id))
    return
  end
  local resolved = exportsModel.resolveVariables(exp, vars)
  for suffix, field in pairs(exp.fields or {}) do
    local r = resolved[suffix]
    if r then
      field.var_id, field.var_name = r.id, r.name
      pcall(function()
        C4:RegisterVariableListener(exp.device_id, r.id)
      end)
      OWVC[exp.device_id] = OWVC[exp.device_id] or {}
      -- handlers.lua calls the watcher as (idDevice, idVariable, strValue).
      OWVC[exp.device_id][r.id] = function(_, _, value)
        onSourceVariable(exp, suffix, value)
      end
      local initial = type(vars[tostring(r.id)]) == "table" and vars[tostring(r.id)].value
        or (type(vars[r.id]) == "table" and vars[r.id].value)
        or nil
      if initial ~= nil then
        onSourceVariable(exp, suffix, initial)
      end
    else
      -- No candidate variable on this device: the field is unavailable, and
      -- it says so instead of pretending.
      onSourceVariable(exp, suffix, nil)
    end
  end
end

local function unwatchExport(exp)
  for _, field in pairs(exp.fields or {}) do
    if field.var_id then
      pcall(function()
        C4:UnregisterVariableListener(exp.device_id, field.var_id)
      end)
      if OWVC[exp.device_id] then
        OWVC[exp.device_id][field.var_id] = nil
      end
    end
  end
end

local function restoreExports()
  for _, exp in pairs(loadExports()) do
    watchExport(exp)
  end
end

-- ─── Device Exports (Properties block) ───────────────────────────────────────
--
-- Composer's device picker on the Export Device command showed an empty tree
-- on the bench (2026-10-20), so the bridge lists the project's devices
-- itself: every device the Director reports, the kind's likely proxies
-- first, as "Name · id". The action below is the Export Device command with
-- the properties as its parameters.

local EXPORT_KIND_HINTS = {
  light = { "light" },
  relay = { "relay" },
  contact = { "contact" },
  temperature = { "temperature", "thermostat" },
  thermostat = { "thermostat" },
  shade = { "blind", "shade" },
}

local function exportDeviceEntries()
  local ok, devices = pcall(function()
    return C4:GetDevices({})
  end)
  if not ok or type(devices) ~= "table" then
    return {}
  end
  local me = C4:GetDeviceID()
  local kind = tostring(Properties["Export Kind"] or "light"):lower()
  local hints = EXPORT_KIND_HINTS[kind] or {}
  -- A device fits when it carries at least one variable the kind's fields
  -- read. A light's physical driver and the light itself share a name in
  -- most projects; only the latter has LIGHT_STATE (bench 2026-10-20: the
  -- wrong one was exported and every field came out "unavailable").
  local function fits(id)
    local okV, vars = pcall(function()
      return C4:GetDeviceVariables(id)
    end)
    if not okV or type(vars) ~= "table" then
      return false
    end
    return next(exportsModel.resolveVariables({ kind = kind }, vars)) ~= nil
  end
  local likely, others = {}, {}
  for rawId, device in pairs(devices) do
    local id = tonumber(rawId)
    local file = tostring((type(device) == "table" and device.driverFileName) or ""):lower()
    if id and id ~= me and not AGENT_FILES[file] and not file:find("smartbuildos%-system%-link") then
      local okName, name = pcall(function()
        return C4:GetDeviceData(id, "name")
      end)
      name = okName and tostring(name or "") or ""
      if name == "" and type(device) == "table" and device.name then
        name = tostring(device.name)
      end
      if name == "" then
        name = "device"
      end
      local room = type(device) == "table" and device.roomName or nil
      if type(room) ~= "string" or room == "" then
        local okR, r = pcall(function()
          return C4:GetDeviceData(id, "roomName")
        end)
        room = okR and type(r) == "string" and r or ""
      end
      local clean = (name:gsub(",", " "))
      if room ~= "" then
        clean = clean .. " (" .. (room:gsub(",", " ")) .. ")"
      end
      local fit = fits(id)
      local hinted = false
      for _, hint in ipairs(hints) do
        if file:find(hint, 1, true) then
          hinted = true
          break
        end
      end
      local entry = {
        id = id,
        fit = fit,
        label = fit and string.format("%s · %d", clean, id)
          or string.format("%s · %d (no %s variables)", clean, id, kind),
      }
      if fit or hinted then
        likely[#likely + 1] = entry
      else
        others[#others + 1] = entry
      end
    end
  end
  local byLabel = function(a, b)
    return a.label < b.label
  end
  table.sort(likely, byLabel)
  table.sort(others, byLabel)
  -- Default filter: only devices that fit. A dealer who wants the flagged
  -- ones (or whose devices report no variables at all) picks All devices.
  local onlyFit = tostring(Properties["Export Device Filter"] or "Devices that fit the kind") ~= "All devices"
  local out = {}
  for _, e in ipairs(likely) do
    if not onlyFit or e.fit then
      out[#out + 1] = e
    end
  end
  if not onlyFit then
    for _, e in ipairs(others) do
      out[#out + 1] = e
    end
  end
  return out
end

--- "MBR Baseboard (Master) · 41" → "MBR_Baseboard": the device name under the
--- export-name rule (letters, digits, underscores; starts with a letter; ≤40).
local function exportNameFromLabel(label)
  local name = tostring(label or ""):gsub("%s*·%s*%d+.*$", ""):gsub("%s*%b()%s*$", "")
  name = name:gsub("[^%w]+", "_"):gsub("^_+", ""):gsub("_+$", ""):gsub("^[^%a]+", "")
  return name:sub(1, 40)
end

local function paintExportList()
  local names = {}
  for _, exp in pairs(loadExports()) do
    names[#names + 1] = exp.name
  end
  table.sort(names)
  table.insert(names, 1, "-")
  pcall(function()
    C4:UpdatePropertyList("Selected Export", table.concat(names, ","), Properties["Selected Export"] or "-")
  end)
end

local function paintExportDeviceList()
  local labels = { "-" }
  for _, e in ipairs(exportDeviceEntries()) do
    labels[#labels + 1] = e.label
  end
  local current = Properties["Export Device"] or "-"
  pcall(function()
    C4:UpdatePropertyList("Export Device", table.concat(labels, ","), current)
  end)
end

function OPC.Export_Kind()
  paintExportDeviceList()
end

function OPC.Export_Device_Filter()
  paintExportDeviceList()
end

-- Picking a device fills an empty Export Name from the device's name; a
-- name the dealer typed is never overwritten.
function OPC.Export_Device(value)
  local current = tostring(Properties["Export Name"] or "")
  if current ~= "" or tostring(value or "-") == "-" then
    return
  end
  local derived = exportNameFromLabel(value)
  if derived ~= "" then
    UpdateProperty("Export Name", derived)
  end
end

function EC.REFRESH_EXPORT_DEVICE_LIST()
  paintExportDeviceList()
end

--- Programming command: Export Device DEVICE as NAME (KIND, CONTROL, OPS).
function EC.Export_Device(tParams)
  tParams = tParams or {}
  if not gEngine or not gEngine.link then
    reportError("Export: link is not provisioned")
    return
  end
  local deviceId = tonumber(tostring(tParams.DEVICE or ""):match("(%d+)"))
  local kind = tostring(tParams.KIND or "light"):lower()
  local ops
  if tParams.OPS and tostring(tParams.OPS) ~= "" then
    ops = {}
    for op in tostring(tParams.OPS):gmatch("[^,%s]+") do
      ops[#ops + 1] = op:lower()
    end
  end
  local okName, deviceName = pcall(function()
    return C4:GetDeviceData(deviceId, "name")
  end)
  local exp, err = exportsModel.define({
    id = uuid(),
    name = tostring(tParams.NAME or ""),
    kind = kind,
    device_id = deviceId,
    device_name = okName and deviceName or nil,
    control = tostring(tParams.CONTROL or "View only") == "Control allowed",
    ops = ops,
  }, licenseFeatures())
  if not exp then
    reportError("Export: " .. tostring(err))
    log:warn("Export Device refused: %s", tostring(err))
    return
  end
  if findExport(exp.name) then
    reportError("Export: name already used")
    return
  end
  do
    local okV, vars = pcall(function()
      return C4:GetDeviceVariables(deviceId)
    end)
    local resolved = okV and type(vars) == "table" and exportsModel.resolveVariables(exp, vars) or {}
    if next(resolved) == nil then
      local wanted, found = {}, {}
      for _, f in ipairs(exportsModel.FIELDS[kind] or {}) do
        for _, cand in ipairs(f.vars) do
          wanted[#wanted + 1] = cand
        end
      end
      for _, v in pairs(okV and type(vars) == "table" and vars or {}) do
        if type(v) == "table" and v.name then
          found[#found + 1] = tostring(v.name)
        end
      end
      table.sort(found)
      reportError(
        string.format(
          "Export: %s (device %d) has none of the variables a %s export reads (%s). Pick the %s itself, not its protocol driver. It has: %s",
          tostring(exp.device_name or "device"),
          deviceId,
          kind,
          table.concat(wanted, ", "),
          kind,
          #found > 0 and table.concat(found, ", ") or "no variables"
        )
      )
      return
    end
  end
  for _, def in ipairs(exportsModel.itemDefinitions(exp, gEngine.link.endpoint)) do
    local created, cerr = gEngine:createItem(def, nil)
    if not created then
      reportError("Export: " .. tostring(cerr))
      return
    end
    exp.fields[def.companion.field] = { item_id = created.id }
  end
  loadExports()[exp.id] = exp
  saveExports()
  watchExport(exp)
  paintExportList()
  SetTimer(SYNC_TIMER, 100, doSync)
  reportError("")
  log:print(
    "Exported %s (%s) as %s — %s",
    tostring(exp.device_name or deviceId),
    kind,
    exp.name,
    exp.control and ("control: " .. table.concat(exp.ops, ", ")) or "view only"
  )
end

--- Action: the Export Device command fed from the Device Exports properties.
function EC.EXPORT_SELECTED_DEVICE()
  local selection = tostring(Properties["Export Device"] or "-")
  local id = selection:match("· (%d+)")
  if not id then
    reportError("Export: pick a device in Export Device first (Refresh Export Device List if it is empty)")
    return
  end
  local name = tostring(Properties["Export Name"] or "")
  if name == "" then
    reportError("Export: fill in Export Name first")
    return
  end
  EC.Export_Device({
    DEVICE = id,
    NAME = name,
    KIND = Properties["Export Kind"] or "light",
    CONTROL = Properties["Export Control"] or "View only",
    OPS = Properties["Export Operations"] or "",
  })
end

function EC.Remove_Export(tParams)
  local exp = findExport((tParams or {}).NAME)
  if not exp then
    reportError("Remove Export: no such export")
    return
  end
  unwatchExport(exp)
  for _, field in pairs(exp.fields or {}) do
    if field.item_id then
      gEngine:deleteItem(field.item_id)
    end
  end
  loadExports()[exp.id] = nil
  saveExports()
  paintExportList()
  SetTimer(SYNC_TIMER, 100, doSync)
end

--- Properties-block twins of Remove Export / a rename. Both print the effect
--- first, like Rename Selected Item does; a rename keeps every variable id
--- (the old names become hidden tombstones, the new names get new ids) and
--- the companion on the linked project must be re-linked to the new name.
function EC.REMOVE_SELECTED_EXPORT()
  local exp = findExport(Properties["Selected Export"])
  if not exp then
    reportError("Remove: pick an export in Selected Export first")
    return
  end
  local vars = {}
  for suffix, f in pairs(exp.fields or {}) do
    local def = f.item_id and gEngine and gEngine.registry.items[f.item_id]
    vars[#vars + 1] = def and gEngine:variableNameFor(def) or (exp.name .. "_" .. suffix)
  end
  table.sort(vars)
  log:print(
    "Remove effect: %s stops being shared; %s become hidden and are never reused; the linked project's companion for %s goes unavailable.",
    exp.name,
    table.concat(vars, ", "),
    exp.name
  )
  EC.Remove_Export({ NAME = exp.name })
  UpdateProperty("Selected Export", "-")
  reportError("")
end

function EC.RENAME_SELECTED_EXPORT()
  local exp = findExport(Properties["Selected Export"])
  local newName = tostring(Properties["Export Name"] or "")
  if not exp then
    reportError("Rename: pick an export in Selected Export first")
    return
  end
  if newName == "" then
    reportError("Rename: fill in Export Name with the new name first")
    return
  end
  if not newName:match("^[A-Za-z][A-Za-z0-9_]*$") or #newName > 40 then
    reportError("Rename: export name must be letters, digits and underscores (max 40)")
    return
  end
  if newName == exp.name then
    reportError("Rename: that is already the export's name")
    return
  end
  if findExport(newName) then
    reportError("Rename: name already used")
    return
  end
  local effects = {}
  for suffix, f in pairs(exp.fields or {}) do
    local preview = f.item_id and gEngine and gEngine:renamePreview(f.item_id, newName .. "_" .. suffix)
    if preview then
      effects[#effects + 1] = preview.from .. " → " .. preview.to
    end
  end
  table.sort(effects)
  log:print(
    "Rename effect: %s → %s. %s. Variable ids stay the same; the old names become hidden. Re-link the companion on the linked project to %s.",
    exp.name,
    newName,
    table.concat(effects, "; "),
    newName
  )
  for suffix, f in pairs(exp.fields or {}) do
    if f.item_id then
      local ok, err = gEngine:renameItem(f.item_id, newName .. "_" .. suffix)
      if not ok then
        reportError("Rename: " .. tostring(err))
        return
      end
      local def = gEngine.registry.items[f.item_id]
      if def then
        def.group = newName
        if type(def.companion) == "table" then
          def.companion.name = newName
        end
      end
    end
  end
  exp.name = newName
  saveExports()
  gEngine:queueSchema()
  gEngine:persistAll()
  UpdateProperty("Export Name", "")
  UpdateProperty("Selected Export", newName)
  paintExportList()
  SetTimer(SYNC_TIMER, 100, doSync)
  reportError("")
end

function EC.Set_Export_Schedule(tParams)
  tParams = tParams or {}
  local exp = findExport(tParams.NAME)
  if not exp then
    reportError("Schedule: no such export")
    return
  end
  local days = {}
  for d in tostring(tParams.DAYS or "1,2,3,4,5,6,7"):gmatch("%d") do
    days[#days + 1] = tonumber(d)
  end
  local schedule = {
    tz = timezone() ~= "" and timezone() or "controller-local",
    windows = { { days = days, from = tostring(tParams.FROM or "00:00"), to = tostring(tParams.TO or "23:59") } },
  }
  local ok, err = exportsModel.validateSchedule(schedule)
  if not ok then
    reportError("Schedule: " .. tostring(err))
    return
  end
  exp.schedule = schedule
  saveExports()
end

function EC.Clear_Export_Schedule(tParams)
  local exp = findExport((tParams or {}).NAME)
  if exp then
    exp.schedule = nil
    saveExports()
  end
end

function EC.PRINT_EXPORTS()
  for _, exp in pairs(loadExports()) do
    local fields = {}
    for suffix, f in pairs(exp.fields or {}) do
      fields[#fields + 1] = suffix .. "=" .. tostring(f.var_name or "unavailable")
    end
    print(
      string.format(
        "%-24s %-12s device %-6s %s  [%s]%s",
        exp.name,
        exp.kind,
        tostring(exp.device_id),
        exp.control and ("control: " .. table.concat(exp.ops, ",")) or "view only",
        table.concat(fields, " "),
        exp.schedule and " scheduled" or ""
      )
    )
  end
end

--- Inbound remote command (from the peer's companion). Validates the
--- export, permission, schedule and licence, then sends the device command.
--- Acceptance is reported as "delivered"; physical feedback arrives through
--- the variable listener and is published like any other change.
function OnSystemLinkCommand(body, id)
  local exp = findExport(body.target)
  local commands, why = exportsModel.validateCommand(exp, body, {
    features = licenseFeatures(),
    commandsPermitted = gEngine:commandsPermitted(),
    localTime = os.date("*t"),
  })
  if not commands then
    log:info("Remote command %s refused: %s", tostring(body.routine), tostring(why))
    return false, why
  end
  for _, c in ipairs(commands) do
    local ok, err = pcall(function()
      C4:SendToDevice(exp.device_id, c.name, c.params)
    end)
    if not ok then
      return false, "device command failed: " .. tostring(err)
    end
  end
  log:info("Remote command %s executed on %s (%s)", tostring(body.routine), exp.name, tostring(id))
  return true
end

-- ─── Companions (peer side) ─────────────────────────────────────────────────

local function loadCompanionMap()
  if gCompanionMap == nil then
    gCompanionMap = persist:get(COMPANIONS_KEY, {}) or {}
  end
  return gCompanionMap
end

--- Mirrored exports, grouped by companion kind, from the peer's definitions.
local function mirroredExports(kind)
  local byName = {}
  for _, def in ipairs(schema.registryItems(gEngine.registry)) do
    local c = def.mirror and type(def.companion) == "table" and def.companion or nil
    if c and (kind == nil or kind == "" or c.kind == kind) then
      local entry = byName[c.name]
      if not entry then
        entry = { id = c.id, name = c.name, kind = c.kind, control = c.control == true, ops = c.ops or {}, fields = {} }
        byName[c.name] = entry
      end
      entry.fields[c.field] = def.id
    end
  end
  local list = {}
  for _, e in pairs(byName) do
    list[#list + 1] = e
  end
  table.sort(list, function(a, b)
    return a.name < b.name
  end)
  return list
end

local function companionState(entry)
  local fields = {}
  local worst = "current"
  for suffix, itemId in pairs(entry.fields) do
    local v = gEngine.values[itemId]
    local def = gEngine.registry.items[itemId]
    if v and v.tv.s == schema.STATES.CURRENT then
      fields[suffix] = v.tv.v
    else
      fields[suffix] = JSON.null
    end
    local f = gEngine:itemCurrent(def and gEngine:variableNameFor(def) or "") and "current"
      or (v and v.tv.s ~= schema.STATES.CURRENT and v.tv.s or "stale")
    if f ~= "current" then
      worst = f
    end
  end
  return fields, worst
end

local function pushCompanionState(entry, deviceId)
  local fields, fresh = companionState(entry)
  pcall(function()
    C4:SendToDevice(deviceId, "SBOS_LINK_COMPANION_STATE", {
      export = entry.name,
      fields = JSON:encode(fields),
      fresh = fresh,
      state = tostring(gEngine.remoteState or "Offline"),
      control = entry.control and gEngine:commandsPermitted() and "true" or "false",
    })
  end)
end

function EC.SBOS_LINK_COMPANION_HELLO(tParams)
  tParams = tParams or {}
  local requester = tonumber(tParams.requester)
  if not requester or not gEngine then
    return
  end
  local list = mirroredExports(tostring(tParams.kind or ""))
  local described = {}
  for _, e in ipairs(list) do
    described[#described + 1] = { id = e.id, name = e.name, kind = e.kind, control = e.control, ops = e.ops }
  end
  pcall(function()
    C4:SendToDevice(requester, "SBOS_LINK_COMPANION_EXPORTS", { exports = JSON:encode(described) })
  end)
  local wanted = tostring(tParams.export or "")
  if wanted ~= "" then
    for _, e in ipairs(list) do
      if e.name == wanted then
        gCompanionSubscribers[e.name] = gCompanionSubscribers[e.name] or {}
        gCompanionSubscribers[e.name][requester] = true
        pushCompanionState(e, requester)
      end
    end
  end
end

function EC.SBOS_LINK_COMPANION_CONTROL(tParams)
  tParams = tParams or {}
  local requester = tonumber(tParams.requester)
  local name = tostring(tParams.export or "")
  local op = tostring(tParams.op or "")
  if not requester or name == "" or op == "" or not gEngine then
    return
  end
  local entry
  for _, e in ipairs(mirroredExports(nil)) do
    if e.name == name then
      entry = e
    end
  end
  local function result(status, reason)
    pcall(function()
      C4:SendToDevice(
        requester,
        "SBOS_LINK_COMPANION_RESULT",
        { export = name, op = op, status = status, reason = reason or "" }
      )
    end)
  end
  if not entry then
    return result("failed", "unknown export")
  end
  if not entry.control then
    return result("failed", "export is view-only")
  end
  local okParams, params = pcall(function()
    return JSON:decode(tostring(tParams.params or "{}"))
  end)
  local id, err = gEngine:sendCommand(entry.kind .. "." .. op, entry.id, okParams and params or {}, 30)
  if not id then
    return result("failed", err)
  end
  gEngine.commands[id].companion = requester
  gEngine.commands[id].export = name
  gEngine.commands[id].op = op
  gEngine.lastRemoteCommand =
    { at = nowMs(), origin = "companion " .. tostring(requester), routine = entry.kind .. "." .. op }
  SetTimer(SYNC_TIMER, 100, doSync)
  result("accepted", "")
end

function OnSystemLinkCommandResult(_, cmd, status, reason)
  if cmd.companion then
    pcall(function()
      C4:SendToDevice(
        cmd.companion,
        "SBOS_LINK_COMPANION_RESULT",
        { export = cmd.export, op = cmd.op, status = status, reason = reason or "" }
      )
    end)
  end
end

function OnSystemLinkMirrorApplied(def)
  local c = type(def.companion) == "table" and def.companion or nil
  if not c or not gCompanionSubscribers[c.name] then
    return
  end
  for _, e in ipairs(mirroredExports(c.kind)) do
    if e.name == c.name then
      for deviceId in pairs(gCompanionSubscribers[c.name]) do
        pushCompanionState(e, deviceId)
      end
    end
  end
end

--- Dealer-initiated companion provisioning for the selected mirrored export.
--- One instance per export; a second request for the same export is refused
--- while the first instance is still in the project.
local function addCompanionFor(c)
  local file = COMPANION_FILES[c.kind]
  if not file then
    reportError("No companion driver for kind " .. tostring(c.kind))
    return
  end
  local map = loadCompanionMap()
  local existing = tonumber(map[c.name])
  if existing then
    local okD, devices = pcall(function()
      return C4:GetDevices({})
    end)
    if okD and type(devices) == "table" and (devices[existing] or devices[tostring(existing)]) then
      reportError("A companion for " .. c.name .. " already exists (device " .. tostring(existing) .. ")")
      return
    end
    map[c.name] = nil
  end
  if gAddCompanionInFlight then
    reportError("A companion is still being added")
    return
  end
  gAddCompanionInFlight = { name = c.name, kind = c.kind }
  local ok, err = pcall(function()
    C4:AddDevice(file, OnSystemLinkCompanionAdded)
  end)
  if not ok then
    gAddCompanionInFlight = nil
    reportError(
      "AddDevice failed: "
        .. tostring(err)
        .. " — upload "
        .. file
        .. " to the controller once via Driver > Add or Update Driver"
    )
  end
end

function EC.ADD_COMPANION_FOR_SELECTED_ITEM()
  local def = selectedItem()
  local c = def and type(def.companion) == "table" and def.companion or nil
  if not def or not def.mirror or not c then
    reportError("Select a mirrored export field first (e.g. Porch_Light_Level)")
    return
  end
  addCompanionFor(c)
end

--- The peer's exports that have no companion device in this project (no map
--- entry, or the mapped device is gone). "Name (kind)", sorted.
local function pendingExports()
  local map = loadCompanionMap()
  local okD, devices = pcall(function()
    return C4:GetDevices({})
  end)
  devices = okD and type(devices) == "table" and devices or {}
  local out = {}
  for _, e in ipairs(mirroredExports(nil)) do
    local existing = tonumber(map[e.name])
    local present = existing and (devices[existing] or devices[tostring(existing)]) and true or false
    if not present then
      out[#out + 1] = e
    end
  end
  table.sort(out, function(a, b)
    return a.name < b.name
  end)
  return out
end

paintPendingExports = function()
  if not gEngine then
    return
  end
  local labels, names = {}, { "-" }
  for _, e in ipairs(pendingExports()) do
    labels[#labels + 1] = string.format("%s (%s)", e.name, e.kind)
    names[#names + 1] = e.name
  end
  updateStatus("Pending Exports", #labels > 0 and table.concat(labels, ", ") or "none")
  local joined = table.concat(names, ",")
  if gLastStatus["Pending Export__list"] ~= joined then
    gLastStatus["Pending Export__list"] = joined
    pcall(function()
      C4:UpdatePropertyList("Pending Export", joined, Properties["Pending Export"] or "-")
    end)
  end
end

function EC.ADD_COMPANION_FOR_PENDING_EXPORT()
  local want = tostring(Properties["Pending Export"] or "-")
  if want == "-" or want == "" then
    reportError("Pick an export in Pending Export first (Pending Exports lists what the linked project shares)")
    return
  end
  for _, e in ipairs(pendingExports()) do
    if e.name == want then
      addCompanionFor({ id = e.id, name = e.name, kind = e.kind, control = e.control, ops = e.ops })
      return
    end
  end
  reportError("No pending export named " .. want .. " — it may already have a companion")
end

function OnSystemLinkCompanionAdded(deviceId)
  local pending = gAddCompanionInFlight
  gAddCompanionInFlight = nil
  deviceId = tonumber(deviceId) or 0
  if not pending then
    return
  end
  if deviceId == 0 then
    log:print(
      "Add companion: FAILED for %s — upload %s once via Driver > Add or Update Driver, then rerun",
      pending.name,
      COMPANION_FILES[pending.kind]
    )
    return
  end
  loadCompanionMap()[pending.name] = deviceId
  persist:set(COMPANIONS_KEY, gCompanionMap)
  paintPendingExports()
  pcall(function()
    C4:SendToDevice(deviceId, "SBOS_LINK_COMPANION_ASSIGN", { export = pending.name })
  end)
  log:print("Added %s companion for %s (device %d)", pending.kind, pending.name, deviceId)
end

-- ─── Composer: link controls ─────────────────────────────────────────────────

function EC.REFRESH_LINK()
  gEngine.needSnapshot = true
  gEngine.helloDone = false
  SetTimer(SYNC_TIMER, 100, doSync)
  paintItemList()
  paintPendingExports()
end

function EC.RUN_LINK_TEST()
  if not gEngine or not gEngine.link then
    print("Link test: not provisioned")
    return
  end
  local started = nowMs()
  local marker = gEngine:createItem(
    { name = "Link_Test_" .. tostring(math.random(1000, 9999)), type = "INTEGER", export_enabled = false },
    "1"
  )
  if marker then
    gEngine:deleteItem(marker.id)
  end
  gEngine.needSnapshot = true
  doSync()
  SetTimer("SlLinkTestReport", 5 * ONE_SECOND, function()
    local st = gEngine:statusProperties()
    print(
      string.format(
        "Link test: relay=%s peer=%s sync=%s remote=%s latency=%s elapsed=%dms",
        st["Relay Connection"],
        st["Peer Status"],
        st["Sync Status"],
        st["Remote System State"],
        st["Measured Latency"],
        nowMs() - started
      )
    )
  end)
end

function EC.PAUSE_COMMANDS()
  gEngine:pauseCommandsLocal(tonumber(Properties["Pause Minutes"]) or 60, "paused in Composer")
  paintStatus()
end

function EC.RESUME_COMMANDS()
  gEngine:resumeCommandsLocal()
  paintStatus()
end

function EC.GENERATE_DIAGNOSTICS()
  if not gEngine then
    return
  end
  local diag = gEngine:diagnostics()
  diag.driver_version = tostring(C4:GetDriverConfigInfo("version") or "")
  diag.license = license.describe and license.describe() or license.status()
  diag.generated_at = isoNow()
  print(JSON:encode(diag))
  local agent = findAgent()
  if agent then
    pcall(function()
      C4:SendToDevice(agent, "SEND_EVENT", {
        NAME = "SYSTEM_LINK_DIAGNOSTICS",
        DETAIL = JSON:encode({
          remote_state = diag.remote_state,
          transport = diag.transport,
          pending = diag.pending,
          latency_p95_ms = diag.latency_p95_ms,
          items = #diag.items,
        }),
      })
    end)
  end
end

function EC.RE_PROVISION_LINK()
  gPendingProvision = nil
  requestProvision()
end

function EC.FORGET_LINK()
  doorbellStop()
  CancelTimer(TICK_TIMER)
  clearCredential()
  if gEngine then
    gEngine.link = nil
    gEngine:persistAll()
  end
  updateStatus("Link Authorization", "Forgotten — definitions and last values are kept; re-provision to resume")
end

-- ─── Composer: programming commands (Programming tab) ────────────────────────

local function setLocalFromCommand(tParams, coerceValue)
  local name = tostring(tParams.ITEM or "")
  local ok, err = gEngine:setLocal(name, coerceValue(tParams.VALUE))
  if not ok then
    reportError("Set " .. name .. ": " .. tostring(err))
    log:warn("Set %s refused: %s", name, tostring(err))
    return
  end
  SetTimer(SYNC_TIMER, 100, doSync)
end

function EC.Set_Local_Boolean(tParams)
  setLocalFromCommand(tParams or {}, function(v)
    return tostring(v or "") == "True"
  end)
end
function EC.Set_Local_Integer(tParams)
  setLocalFromCommand(tParams or {}, function(v)
    return v
  end)
end
function EC.Set_Local_Decimal(tParams)
  setLocalFromCommand(tParams or {}, function(v)
    return v
  end)
end
function EC.Set_Local_String(tParams)
  setLocalFromCommand(tParams or {}, function(v)
    return tostring(v or "")
  end)
end
function EC.Set_Local_Choice(tParams)
  setLocalFromCommand(tParams or {}, function(v)
    return tostring(v or "")
  end)
end

function EC.Emit_Named_Event(tParams)
  tParams = tParams or {}
  local ok, err =
    gEngine:emitEvent(tostring(tParams.EVENT or ""), tostring(tParams.PAYLOAD or ""), tonumber(tParams.TTL))
  if not ok then
    reportError("Event: " .. tostring(err))
    return
  end
  SetTimer(SYNC_TIMER, 100, doSync)
end

function EC.Send_Remote_Request(tParams)
  tParams = tParams or {}
  local entry, err =
    gEngine:sendRequest(tostring(tParams.ROUTINE or ""), tostring(tParams.PAYLOAD or ""), tonumber(tParams.DEADLINE))
  if not entry then
    reportError("Request: " .. tostring(err))
    return
  end
  SetTimer(SYNC_TIMER, 100, doSync)
end

local function report(tParams, status)
  tParams = tParams or {}
  local slot = tonumber(tParams.SLOT) or 1
  local ok, err = gEngine:reportRequest(
    slot,
    status,
    tParams.RESULT and tParams.RESULT ~= "" and { text = tostring(tParams.RESULT) } or nil
  )
  if not ok then
    reportError("Report: " .. tostring(err))
    return
  end
  SetTimer(SYNC_TIMER, 100, doSync)
end
function EC.Report_Request_Progress(tParams)
  report(tParams, "running")
end
function EC.Report_Request_Success(tParams)
  report(tParams, "completed")
end
function EC.Report_Request_Failure(tParams)
  report(tParams, "failed")
end
function EC.Pause_Remote_Commands(tParams)
  gEngine:pauseCommandsLocal(tonumber((tParams or {}).MINUTES) or 60, "paused by programming")
end
function EC.Resume_Remote_Commands()
  gEngine:resumeCommandsLocal()
end

-- ─── Conditionals ────────────────────────────────────────────────────────────

local function logicApply(tParams, equal)
  local logic = tostring((tParams and tParams.LOGIC) or "EQUAL")
  if logic == "NOT_EQUAL" then
    return not equal
  end
  return equal
end

TC.REMOTE_READY = function()
  return gEngine ~= nil and gEngine:isRemoteReady()
end
TC.LINK_SYNCED = function()
  return gEngine ~= nil and gEngine:isSynced()
end
TC.COMMANDS_PERMITTED = function()
  return gEngine ~= nil and gEngine:commandsPermitted()
end
TC.ITEM_CURRENT = function(_, tParams)
  if not gEngine then
    return false
  end
  return logicApply(tParams, gEngine:itemCurrent(tostring((tParams and (tParams.VALUE or tParams.STRING)) or "")))
end
TC.REQUEST_STATUS = function(_, tParams)
  if not gEngine then
    return false
  end
  local spec = tostring((tParams and (tParams.VALUE or tParams.STRING)) or "")
  local slot, want = spec:match("^%s*(%d+)%s+(%a+)")
  if not slot then
    return false
  end
  return logicApply(tParams, gEngine:requestSlotStatus(tonumber(slot)):lower() == want:lower())
end

-- ─── Properties ──────────────────────────────────────────────────────────────

function OPC.Log_Level(value)
  log:setLogLevel(value)
end
function OPC.Log_Mode(value)
  log:setLogMode(value)
end
function OPC.Selected_Item()
  paintItemList()
end
function OPC.Evaluate_State_After_Initial_Sync(value)
  if gEngine then
    gEngine.evaluateAfterSync = tostring(value) == "Yes"
  end
end
function OPC.Request_Slots(value)
  -- Takes effect at the next Director restart; slots are variables and
  -- variables are added in order at init.
  log:info("Request Slots will be %s after the next restart", tostring(value))
end
OPC.suppressDebug = OPC.suppressDebug or {}
OPC.suppressDebug[BACKUP_PROPERTY] = true

-- ─── Lifecycle ───────────────────────────────────────────────────────────────

function OnDriverInit()
  --#ifdef DRIVERCENTRAL
  require("cloud-client-byte")
  C4:AllowExecute(false)
  --#else
  C4:AllowExecute(true)
  --#endif
  gInitialized = false
  log:setLogName("SystemLink")
  log:setLogLevel(Properties["Log Level"])
  log:setLogMode(Properties["Log Mode"])
  math.randomseed(os.time() + (C4:GetDeviceID() or 0))

  gEngine = Engine.new(buildIo())
  local info = loadCredential()
  if info then
    gEngine.link = gEngine.link or nil
    if not gEngine.link or gEngine.link.endpoint ~= info.endpoint_id then
      gEngine:onProvisioned(info)
    else
      gEngine.link.credential = info.credential
      gEngine.link.relay_url = info.relay_url
      gEngine.link.realtime = info.realtime
    end
  end
  -- Variables must exist before Composer restores programming (DriverWorks:
  -- add them in OnDriverInit, in the same order every time).
  gEngine:restoreVariables()
  gEngine:ensureRequestSlotVariables()
end

function OnDriverLateInit()
  if not CheckMinimumVersion("Driver Status") then
    return
  end
  for _, e in ipairs(EVENTS) do
    pcall(function()
      C4:AddEvent(e[1], e[2], e[3])
    end)
  end
  for itemId, id in pairs(gEngine.itemEvents) do
    local def = gEngine.registry.items[itemId]
    if def then
      pcall(function()
        C4:AddEvent(
          id,
          gEngine:variableNameFor(def) .. " changed (live)",
          "The remote value changed after initial sync."
        )
      end)
    end
  end
  for p, _ in pairs(Properties) do
    pcall(OnPropertyChanged, p)
  end
  license.setup({ sku = SKU })
  paintItemList()
  paintExportDeviceList()
  restoreExports()
  paintExportList()
  -- Reconcile phase 1–2 happened in Engine.new/onProvisioned; the network
  -- phases start when the relay answers.
  if gEngine.link then
    updateStatus("Link Authorization", tostring(gEngine.link.link_state or "stored"))
    startSync()
    doorbellConnect(gEngine.link.realtime)
    -- A fresh credential on every start: a replaced controller or a revoked
    -- link must be learned now, not at the first 401.
    SetTimer(PROVISION_TIMER, 3 * ONE_SECOND, requestProvision)
  else
    updateStatus("Link Authorization", "Not provisioned — approve the link in System Studio")
    SetTimer(PROVISION_TIMER, 3 * ONE_SECOND, requestProvision)
    SetTimer(TICK_TIMER, ONE_SECOND, tick, true)
  end
  gInitialized = true
  updateStatus("Driver Version", tostring(C4:GetDriverConfigInfo("version") or ""))
  updateStatus("Installed Version", tostring(C4:GetDriverConfigInfo("version") or ""))
  updateStatus("Driver Status", "Online")
  paintStatus()
end

function OnDriverDestroyed()
  doorbellStop()
  KillAllTimers()
  if gEngine then
    gEngine:persistAll()
  end
end
