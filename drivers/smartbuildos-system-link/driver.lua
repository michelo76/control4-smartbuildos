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
local schema = require("systemlink.schema")
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
    local v = persist:get(key, nil)
    if v == nil then
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
    -- Companion control requests land here (stage 7+). Until a companion
    -- driver registers a handler, every command is refused explicitly.
    if type(OnSystemLinkCommand) == "function" then
      return OnSystemLinkCommand(body, id)
    end
    return false, "no companion handler on this project"
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
  local blob = persist:get(CREDENTIAL_KEY, nil, true)
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

local function requestProvision()
  local agent = findAgent()
  if not agent then
    updateStatus("Link Authorization", "No SmartBuildOS Agent found — add the free Connector first")
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
  end
  updateStatus("Link Authorization", "Asking the Agent for this system's link…")
  return ok
end

local startSync, doorbellConnect, doorbellStop

function EC.SBOS_LINK_PROVISION(tParams)
  tParams = tParams or {}
  local pending = gPendingProvision
  if not pending or os.time() > pending.expires or tostring(tParams.request_id or "") ~= pending.id then
    return
  end
  gPendingProvision = nil
  if tParams.error and tParams.error ~= "" then
    updateStatus("Link Authorization", tostring(tParams.error))
    updateStatus("Last Error", tostring(tParams.error))
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
    updateStatus("Last Error", "Agent returned an unusable link provision")
    return
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

local function paintStatus()
  if not gEngine then
    return
  end
  for name, value in pairs(gEngine:statusProperties()) do
    updateStatus(name, value)
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

local function paintItemList()
  if not gEngine then
    return
  end
  local names = { "-" }
  for _, def in ipairs(schema.registryItems(gEngine.registry)) do
    names[#names + 1] = gEngine:variableNameFor(def)
  end
  pcall(function()
    C4:UpdatePropertyList("Selected Item", table.concat(names, ","), Properties["Selected Item"] or "-")
  end)
  local def = selectedItem()
  if def then
    local v = gEngine.values[def.id]
    updateStatus(
      "Selected Item Details",
      string.format(
        "%s · %s · %s · rev %s · %s%s",
        def.mirror and "mirror (read-only)" or "owned",
        def.type,
        v and v.tv.s or "unknown",
        tostring(v and v.rev or 0),
        def.group and (def.group .. " · ") or "",
        def.description or ""
      )
    )
  else
    updateStatus("Selected Item Details", "Select an item")
  end
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
    updateStatus("Last Error", "Link is not provisioned yet")
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
    updateStatus("Last Error", "Create: " .. tostring(err))
    log:warn("Create Shared Item refused: %s", tostring(err))
    return
  end
  UpdateProperty("New Item Name", "")
  UpdateProperty("New Item Initial Value", "")
  UpdateProperty("Selected Item", gEngine:variableNameFor(created))
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
    updateStatus("Last Error", "Mirrors are deleted by their owner; unshare it on the other system")
    return
  end
  local ok, err = gEngine:deleteItem(def.id)
  if not ok then
    updateStatus("Last Error", "Delete: " .. tostring(err))
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
    updateStatus("Last Error", "Rename: " .. tostring(err))
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
    updateStatus("Last Error", "Filter: " .. tostring(err))
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

-- ─── Composer: link controls ─────────────────────────────────────────────────

function EC.REFRESH_LINK()
  gEngine.needSnapshot = true
  gEngine.helloDone = false
  SetTimer(SYNC_TIMER, 100, doSync)
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
    updateStatus("Last Error", "Set " .. name .. ": " .. tostring(err))
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
    updateStatus("Last Error", "Event: " .. tostring(err))
    return
  end
  SetTimer(SYNC_TIMER, 100, doSync)
end

function EC.Send_Remote_Request(tParams)
  tParams = tParams or {}
  local entry, err =
    gEngine:sendRequest(tostring(tParams.ROUTINE or ""), tostring(tParams.PAYLOAD or ""), tonumber(tParams.DEADLINE))
  if not entry then
    updateStatus("Last Error", "Request: " .. tostring(err))
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
    updateStatus("Last Error", "Report: " .. tostring(err))
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
