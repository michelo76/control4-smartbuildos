--[[==========================================================================
  SmartBuildOS PIN Lock
  PIN-gated actions and keypad sequences.

  A guarded action is a named gate. When a valid code asks for it, the driver
  fires a Composer event the dealer attaches programming to, and can also
  command one lock or relay itself. Codes (name, role, allowed actions,
  weekly hours, dates, use limit) are managed on a WebView page or by
  programming commands. Codes are stored as salted digests; a PIN is never
  logged, shown or sent anywhere.

  HONEST LIMIT: this driver gates only what passes THROUGH it. It cannot hide
  a room or a device in the native Navigator. A lock that is also visible in
  Navigator stays operable there until the dealer hides it.

  Licensing: the SmartBuildOS Agent is the authority (SKU SBOS_PIN_LOCK
  through sbos.license). A definitive denial with enforcement on RESTRICTS
  the gate rather than stopping it: owner-role codes keep working (the owner
  is never locked out of their own gates), every other code is refused, and
  nothing that adds access can be created. Removing access always works.

  Pure rules: src/pinlock/engine.lua, src/pinlock/relay.lua (tested without
  a controller).
============================================================================]]

--#ifdef DRIVERCENTRAL
DC_PID = 0
DC_X = nil
DC_FILENAME = "smartbuildos-pin-lock.c4z"
--#else
DRIVER_GITHUB_REPO = "michelo76/control4-smartbuildos"
DRIVER_FILENAMES = { "smartbuildos-pin-lock.c4z" }
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
local persist = require("lib.persist")
local license = require("sbos.license")
local appfile = require("lib.appfile")
local pagedata = require("pinlock.page")
local RelayHost = require("lib.relayhost")
local Engine = require("pinlock.engine")
local relay = require("pinlock.relay")
local _unused = { require("guestmode.pin"), require("atmosphere.uirelay") } -- transitive, pinned for the squish step

gInitialized = false

local SKU = "SBOS_PIN_LOCK"
local C4Z_NAME = "smartbuildos-pin-lock"
local SLOTS = Engine.SLOTS
local WEBVIEW_BINDING = 5001
local UI_RELAY_PORT = 47831
local UI_RELAY_ID = "pinlock-ui-relay"
local P_RELAY_TOKEN = "pl_relay_token_v1"
local STATE_KEY = "pl_state_v2"
local RECORDER_FILE = "smartbuildos-flight-recorder.c4z"
local PERSIST_TIMER = "PlPersist"
local STATUS_TIMER = "PlStatusPaint"
local PRUNE_TIMER = "PlPrune"
local URL_TIMER = "PlUrlRepublish"
local RELOCK_TIMER = "PlRelock"

local EVENT_GRANTED, EVENT_DENIED, EVENT_LOCKED, EVENT_RESTRICTED, EVENT_RESTORED = 1, 2, 3, 4, 5
local EVENT_SLOT_BASE = 10

-- A PIN or keypad sequence is a secret. These commands carry one, so
-- Director's generic handler must not print their parameters.
EC.suppressDebug.ADD_TEMPORARY_CODE = true
EC.suppressDebug.KEYPAD_PRESS = true

local gEngine = nil
local gRestricted = false
local gRelayPort = nil
local gRelayBuffers = {}
local gRelayToken = nil
local gAppHtml = nil
local gAppHtmlReported = 0
local gAppHtmlWhy = ""
local gHost = nil
local gLastAccess = "none yet"
local gRecorderId = nil
local gRecorderCheckedAt = nil
local publishWebViewUrl = nil -- forward: needs gHost, which needs it back

--- Seconds. A test pins the clock by defining PIN_LOCK_NOW first.
local function now()
  if type(PIN_LOCK_NOW) == "function" then
    return PIN_LOCK_NOW()
  end
  return os.time()
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

local function stamp(text)
  gLastAccess = string.format("%s (%s)", text, os.date("%H:%M:%S", now()))
  UpdateProperty("Last Access", gLastAccess)
end

-- ─── Persistence ────────────────────────────────────────────────────────────

local function save()
  if gEngine == nil then
    return
  end
  -- Digests and lockouts only; encrypted in the controller's store.
  persist:set(STATE_KEY, gEngine:serialize(), true)
end

local function saveSoon()
  SetTimer(PERSIST_TIMER, 2 * ONE_SECOND, save)
end

-- ─── Flight Recorder (optional, quiet when absent) ──────────────────────────

local function recorderId()
  local t = now()
  if gRecorderCheckedAt ~= nil and t - gRecorderCheckedAt < 300 then
    return gRecorderId
  end
  gRecorderCheckedAt = t
  gRecorderId = nil
  local ok, devices = pcall(function()
    return C4:GetDevices({})
  end)
  if ok and type(devices) == "table" then
    local best
    for rawId, d in pairs(devices) do
      local id = tonumber(rawId)
      if id ~= nil and type(d) == "table" and tostring(d.driverFileName or "") == RECORDER_FILE then
        if best == nil or id < best then
          best = id
        end
      end
    end
    gRecorderId = best
  end
  UpdateProperty("Flight Recorder", gRecorderId and ("recording to device " .. gRecorderId) or "not installed")
  return gRecorderId
end

--- One marker per attempt: code NAME, action, entry point, reason. Never the
--- secret that was typed. The recorder is the only long-term record.
local function record(name, detail)
  local id = recorderId()
  if id == nil then
    return
  end
  pcall(function()
    C4:SendToDevice(id, "RECORD_EVENT", { NAME = name:sub(1, 120), DETAIL = detail:sub(1, 400) })
  end)
end

-- ─── Guarded targets ────────────────────────────────────────────────────────

local TARGET_COMMANDS = {
  Unlock = "UNLOCK",
  Lock = "LOCK",
  Open = "OPEN",
  Close = "CLOSE",
  Toggle = "TOGGLE",
  Trigger = "TRIGGER",
}

local function slotName(n)
  return Properties["Guarded " .. n .. " Name"]
end

local function sendTarget(n, command)
  local id = Engine.targetId(Properties["Guarded " .. n .. " Target"])
  if id == nil or command == nil then
    return
  end
  pcall(function()
    C4:SendToDevice(id, command, {})
  end)
end

local function commandTarget(n)
  local command = TARGET_COMMANDS[tostring(Properties["Guarded " .. n .. " Target Action"] or "")]
  if command == nil then
    return
  end
  sendTarget(n, command)
  local relock = tonumber(Properties["Re-lock After Seconds"]) or 0
  if command == "UNLOCK" and relock > 0 then
    SetTimer(RELOCK_TIMER .. n, relock * ONE_SECOND, function()
      sendTarget(n, "LOCK")
    end)
  end
end

local function targetCsv(selected)
  local ok, devices = pcall(function()
    return C4:GetDevices({})
  end)
  local list = Engine.targetList(ok and devices or {}, C4:GetDeviceID(), Properties["Target List Filter"])
  local labels, seen = { "-" }, { ["-"] = true }
  for _, item in ipairs(list) do
    labels[#labels + 1] = item.label
    seen[item.label] = true
  end
  if selected ~= nil and selected ~= "" and not seen[selected] then
    labels[#labels + 1] = selected -- keep a choice the filter would hide
  end
  return table.concat(labels, ",")
end

local function refreshTargets()
  for n = 1, SLOTS do
    local name = "Guarded " .. n .. " Target"
    pcall(function()
      C4:UpdatePropertyList(name, targetCsv(Properties[name]), Properties[name] or "-")
    end)
  end
end

local function syncSlots()
  if gEngine == nil then
    return
  end
  local names = {}
  for n = 1, SLOTS do
    names[n] = slotName(n)
  end
  gEngine:setSlots(names)
end

local function syncSettings()
  if gEngine == nil then
    return
  end
  gEngine:configure({
    maxFails = Properties["Max Wrong Attempts"],
    lockSeconds = (tonumber(Properties["Lockout Minutes"]) or 5) * 60,
    seqLength = Properties["Sequence Length"],
    seqWindow = Properties["Sequence Window Seconds"],
  })
end

-- ─── Status ─────────────────────────────────────────────────────────────────

local function gateStatus()
  if gEngine == nil then
    return "starting"
  end
  if gRestricted then
    return "licence-restricted (owner codes only)"
  end
  if not gEngine:hasOwner() then
    return "setup needed (no owner code yet)"
  end
  return "active"
end

local function entryLine()
  local parts = {}
  for _, entry in ipairs({ "page", "keypad", "admin" }) do
    local locked, left = gEngine:lockState(entry)
    parts[#parts + 1] = locked and string.format("%s LOCKED %ds", entry, left) or (entry .. " open")
  end
  return table.concat(parts, ", ")
end

local function relayLine()
  if gRelayPort == nil then
    return "not listening"
  end
  return gHost ~= nil and gHost:statusLine() or string.format("Listening :%d", gRelayPort)
end

local function paint()
  if gEngine == nil then
    return
  end
  local status = gateStatus()
  UpdateProperty("Gate Status", status)
  UpdateProperty("Codes", string.format("%d code(s), %d active", #gEngine.codes, gEngine:activeCount()))
  UpdateProperty("Entry Points", entryLine())
  UpdateProperty("Last Access", gLastAccess)
  UpdateProperty("App Data Relay", relayLine())
  setVar("GATE_STATUS", status)
  setVar("ACTIVE_CODES", gEngine:activeCount())
end

local function refused(what, why)
  UpdateProperty("Last Refusal", string.format("%s: %s (%s)", what, tostring(why), os.date("%H:%M:%S", now())))
  log:warn("%s refused: %s", what, tostring(why))
end

-- ─── Engine events -> Composer ──────────────────────────────────────────────

local function onEngineEvent(kind, f)
  if kind == "changed" then
    saveSoon()
  elseif kind == "granted" then
    setVar("LAST_CODE_NAME", f.code)
    setVar("LAST_ACTION", f.action or "")
    setVar("LAST_ACTION_NUMBER", f.slot or 0)
    setVar("LAST_ENTRY_POINT", f.entry)
    setVar("LAST_DENIAL_REASON", "")
    stamp(string.format("granted: %s -> %s via %s", f.code, f.action or "?", f.entry))
    log:info("granted: code %s action %s via %s", f.code, tostring(f.action), f.entry)
    record("PIN Lock granted: " .. tostring(f.action), string.format("code=%s entry=%s", f.code, f.entry))
    if f.slot then
      commandTarget(f.slot)
    end
    fire(EVENT_GRANTED)
    if f.slot then
      fire(EVENT_SLOT_BASE + f.slot)
    end
  elseif kind == "denied" then
    -- Refused attempts during a lockout are recorded but do not re-fire the
    -- event: the lockout event already said so.
    record(
      "PIN Lock denied: " .. tostring(f.action or f.entry),
      string.format("reason=%s code=%s entry=%s", tostring(f.reason), tostring(f.code or "-"), tostring(f.entry))
    )
    if f.reason ~= "locked_out" then
      setVar("LAST_CODE_NAME", f.code or "")
      setVar("LAST_ACTION", f.action or "")
      setVar("LAST_ACTION_NUMBER", f.slot or 0)
      setVar("LAST_ENTRY_POINT", f.entry)
      setVar("LAST_DENIAL_REASON", tostring(f.reason))
      stamp(string.format("denied via %s (%s)", f.entry, tostring(f.reason)))
      log:info("denied via %s: %s", tostring(f.entry), tostring(f.reason))
      fire(EVENT_DENIED)
    end
  elseif kind == "locked_out" then
    setVar("LAST_LOCKED_ENTRY", f.entry)
    stamp(string.format("%s locked out for %ds", f.entry, f.seconds))
    log:warn("entry point %s locked out for %d seconds", f.entry, f.seconds)
    record("PIN Lock locked out: " .. f.entry, string.format("for %d seconds after repeated wrong attempts", f.seconds))
    fire(EVENT_LOCKED)
  elseif kind == "granted_admin" then
    record("PIN Lock admin sign-in", "code=" .. tostring(f.code))
  end
  paint()
end

-- ─── Licence ────────────────────────────────────────────────────────────────

local function reconcileLicence()
  if gEngine == nil then
    return
  end
  local halt = license.enforces()
  if halt and not gRestricted then
    gRestricted = true
    gEngine:setRestricted(true)
    log:warn("SmartBuildOS licence: %s - gate restricted to owner codes", tostring(license.statusLabel()))
    fire(EVENT_RESTRICTED)
  elseif not halt and gRestricted then
    gRestricted = false
    gEngine:setRestricted(false)
    fire(EVENT_RESTORED)
  end
  paint()
end

-- ─── Relay ──────────────────────────────────────────────────────────────────

local function relayHost()
  if gHost == nil then
    return ""
  end
  return (gHost:host())
end

local function relayToken()
  if gRelayToken ~= nil then
    return gRelayToken
  end
  local stored = persist:get(P_RELAY_TOKEN, nil, true)
  if type(stored) == "string" and #stored >= 16 then
    gRelayToken = stored
    return stored
  end
  local seed = string.format("%d|%d|%d|%s", os.time(), os.clock() * 1000000, C4:GetDeviceID(), tostring({}))
  local ok, hex = pcall(function()
    return C4:HMAC("SHA256", seed, "pinlock-relay", { return_encoding = "HEX" })
  end)
  local token = ok and type(hex) == "string" and hex:sub(1, 32) or tostring(os.time()) .. tostring(os.clock())
  gRelayToken = token
  persist:set(P_RELAY_TOKEN, token, true)
  return token
end

local function appHtml()
  if gAppHtml ~= nil then
    return gAppHtml
  end
  -- The page is compiled into the driver (tools/embed-pages.lua): OS 4.3
  -- refuses a driver read access to its own c4z files.
  if type(pagedata) == "string" and #pagedata >= 512 then
    gAppHtml = pagedata
    gAppHtmlWhy = "embedded in the driver"
    return gAppHtml
  end
  local html, report = appfile.read(C4Z_NAME, "app/index.html", C4, 512)
  gAppHtmlWhy = report or ""
  if html ~= nil then
    gAppHtml = html
  end
  if html == nil then
    -- The page cannot be served: say so (at most once a minute) and say why.
    local now = os.time()
    if now - gAppHtmlReported >= 60 then
      gAppHtmlReported = now
      log:warn("Page file not found: %s", report)
    end
  elseif gAppHtmlReported >= 0 then
    gAppHtmlReported = -1
    log:info("Page file: %s", report)
  end
  return gAppHtml
end

local function lockedReply(res)
  return 429, { ok = false, locked = true, retry_in = res.retry_in }
end

local function sessionRefused()
  return 401, { ok = false, error = "sign in again" }
end

local function savedOk(ok, why)
  if ok then
    paint()
    return 200, { ok = true }
  end
  return 422, { ok = false, error = tostring(why) }
end

--- The page's calls. A reply never carries a code name, a reason or any
--- secret to the keypad user: they learn "done", "not allowed" or "locked".
local relayProvider = {
  appHtml = appHtml,
  appWhy = function()
    return gAppHtmlWhy
  end,
  config = function()
    return {
      actions = gEngine:slotList(),
      setup_needed = not gEngine:hasOwner(),
      locks = gEngine:lockSummary(),
      restricted = gRestricted,
    }
  end,
  unlock = function(body)
    local res = gEngine:tryPin("page", body.action, body.pin)
    if res.ok then
      return 200, { ok = true, message = res.action }
    elseif res.locked then
      return lockedReply(res)
    end
    return 401, { ok = false, error = "not allowed" }
  end,
  login = function(body)
    local res = gEngine:login(body.pin)
    if res.ok then
      return 200, { ok = true, session = res.session }
    elseif res.locked then
      return lockedReply(res)
    end
    return 401, { ok = false, error = "not allowed" }
  end,
  setup = function(body)
    local ok, why = gEngine:setup(body.name, body.pin)
    if not ok then
      return 422, { ok = false, error = tostring(why) }
    end
    local res = gEngine:login(body.pin)
    paint()
    return 200, { ok = true, session = res.ok and res.session or nil }
  end,
  state = function(body)
    if not gEngine:sessionValid(body.session) then
      return sessionRefused()
    end
    return 200,
      {
        ok = true,
        codes = gEngine:publicCodes(),
        recent = gEngine.recent,
        locks = gEngine:lockSummary(),
        actions = gEngine:slotList(),
        sequence_length = gEngine.settings.seqLength,
        restricted = gRestricted,
      }
  end,
  save = function(body)
    if not gEngine:sessionValid(body.session) then
      return sessionRefused()
    end
    local spec, why = Engine.specFromPage(body)
    if spec == nil then
      return 422, { ok = false, error = why }
    end
    if body.id ~= nil and body.id ~= "" then
      return savedOk(gEngine:updateCode(body.id, spec))
    end
    local id, e = gEngine:addCode(spec)
    return savedOk(id ~= false, e)
  end,
  enable = function(body)
    if not gEngine:sessionValid(body.session) then
      return sessionRefused()
    end
    return savedOk(gEngine:setEnabled(body.id, true))
  end,
  disable = function(body)
    if not gEngine:sessionValid(body.session) then
      return sessionRefused()
    end
    return savedOk(gEngine:setEnabled(body.id, false))
  end,
  revoke = function(body)
    if not gEngine:sessionValid(body.session) then
      return sessionRefused()
    end
    return savedOk(gEngine:revoke(body.id))
  end,
  clear = function(body)
    if not gEngine:sessionValid(body.session) then
      return sessionRefused()
    end
    gEngine:clearLockouts()
    paint()
    return 200, { ok = true }
  end,
  logout = function(body)
    gEngine:endSession(body.session)
    return 200, { ok = true }
  end,
  encode = function(t)
    return JSON:encode(t)
  end,
  decode = function(s)
    return JSON:decode(tostring(s))
  end,
}

function OnServerDataIn(handle, data, _, _, identifier)
  if identifier ~= nil and identifier ~= UI_RELAY_ID then
    return
  end
  gRelayBuffers[handle] = (gRelayBuffers[handle] or "") .. tostring(data or "")
  if #gRelayBuffers[handle] > 64 * 1024 then
    gRelayBuffers[handle] = nil
    pcall(function()
      C4:ServerCloseClient(handle)
    end)
    return
  end
  local req = relay.parse(gRelayBuffers[handle])
  if req == nil then
    return
  end
  gRelayBuffers[handle] = nil
  local result
  if gEngine == nil then
    result =
      { status = "503 Service Unavailable", contentType = "application/json", body = '{"ok":false,"error":"starting"}' }
  else
    result = relay.route(req, relayToken(), relayProvider)
  end
  pcall(function()
    C4:ServerSend(handle, relay.render(result))
  end)
  pcall(function()
    C4:ServerCloseClient(handle)
  end)
end

local function startUiRelay()
  if gRelayPort ~= nil then
    return
  end
  local ok = pcall(function()
    C4:CreateServer(UI_RELAY_PORT, "", false, UI_RELAY_ID)
  end)
  if ok then
    gRelayPort = UI_RELAY_PORT
    log:info("UI relay listening on port %d", UI_RELAY_PORT)
  else
    log:warn("relay port %d unavailable; the page cannot load", UI_RELAY_PORT)
  end
end

local function stopUiRelay()
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
  if host ~= "" and appHtml() ~= nil then
    return string.format("http://%s:%d/app?k=%s", host, gRelayPort, relayToken())
  end
  local base = "controller://driver/" .. C4Z_NAME .. "/app/index.html"
  if host == "" then
    return base
  end
  return base .. "?relay=" .. encodeParam(string.format("http://%s:%d", host, gRelayPort)) .. "&k=" .. relayToken()
end

publishWebViewUrl = function(reason)
  local url = desiredWebViewUrl()
  pcall(function()
    C4:SendToProxy(WEBVIEW_BINDING, "URL_CHANGED", { url = url })
  end)
  log:debug("WebView URL published (%s): %s", tostring(reason), (url:gsub("k=[%w]+", "k=[token]")))
end

gHost = RelayHost.new({
  port = UI_RELAY_PORT,
  service = "pin-lock",
  configured = function()
    return Properties["App Relay Address"]
  end,
  onChange = function()
    if gInitialized then
      publishWebViewUrl("address confirmed")
    end
  end,
})

-- ─── Lifecycle ──────────────────────────────────────────────────────────────

local function registerComposerSurface()
  for _, v in ipairs({
    { "LAST_CODE_NAME", "", "STRING" },
    { "LAST_ACTION", "", "STRING" },
    { "LAST_ACTION_NUMBER", 0, "NUMBER" },
    { "LAST_ENTRY_POINT", "", "STRING" },
    { "LAST_DENIAL_REASON", "", "STRING" },
    { "LAST_LOCKED_ENTRY", "", "STRING" },
    { "ACTIVE_CODES", 0, "NUMBER" },
    { "GATE_STATUS", "starting", "STRING" },
  }) do
    pcall(function()
      C4:AddVariable(v[1], v[2], v[3], true)
    end)
  end
  local events = {
    { EVENT_GRANTED, "Access Granted", "A code was accepted for a guarded action" },
    { EVENT_DENIED, "Access Denied", "A PIN or keypad sequence was refused" },
    { EVENT_LOCKED, "Entry Point Locked Out", "Too many wrong attempts locked an entry point" },
    { EVENT_RESTRICTED, "Licence Restricted", "The licence restricted the gate to owner codes" },
    { EVENT_RESTORED, "Licence Restored", "The gate is back to normal" },
  }
  for n = 1, SLOTS do
    events[#events + 1] =
      { EVENT_SLOT_BASE + n, "Guarded " .. n .. " Granted", "A code was accepted for guarded action " .. n }
  end
  for _, e in ipairs(events) do
    pcall(function()
      C4:AddEvent(e[1], e[2], e[3])
    end)
  end
end

--- C4:HMAC is the controller's own SHA-256 HMAC. There is deliberately no
--- weaker fallback: if it fails the attempt errors out instead.
local function hmac(key, data)
  return C4:HMAC("SHA256", key, data, { return_encoding = "HEX" })
end

function OnDriverInit()
  --#ifdef DRIVERCENTRAL
  require("cloud-client-byte")
  C4:AllowExecute(false)
  --#else
  C4:AllowExecute(true)
  --#endif
  gInitialized = false
  log:setLogName("PinLock")
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
  pcall(function()
    math.randomseed(os.time() + math.floor(os.clock() * 1000000))
  end)

  gEngine = Engine.new({ now = now, hmac = hmac, emit = onEngineEvent })
  syncSlots()
  syncSettings()
  local stored = persist:get(STATE_KEY, false, true)
  if type(stored) == "table" then
    local ok, err = pcall(function()
      gEngine:restore(stored)
    end)
    if not ok then
      log:error("Persisted state unreadable (%s); starting with no codes", tostring(err))
    end
  end

  license.setup({ sku = SKU })
  EC.SBOS_ENTITLEMENT = function(tParams)
    license.onEntitlement(tParams)
    reconcileLicence()
  end

  gInitialized = true
  UpdateProperty("Driver Status", "Online")
  pcall(function()
    UpdateProperty("Driver Version", tostring(C4:GetDriverConfigInfo("version")))
  end)

  refreshTargets()
  startUiRelay()
  gHost:check()
  publishWebViewUrl("late-init")
  SetTimer(URL_TIMER, 60 * ONE_SECOND, function()
    publishWebViewUrl("late-init+60s")
  end)
  SetTimer(STATUS_TIMER, 60 * ONE_SECOND, function()
    if gRelayPort ~= nil then
      gHost:checkIfDue()
    end
    paint()
  end, true)
  SetTimer(PRUNE_TIMER, 10 * ONE_MINUTE, function()
    if gEngine then
      gEngine:prune()
    end
  end, true)
  paint()
end

function OnDriverDestroyed()
  pcall(license.stop) -- the licence retry timer
  if gEngine then
    save()
  end
  stopUiRelay()
  CancelTimer(PERSIST_TIMER)
  CancelTimer(STATUS_TIMER)
  CancelTimer(PRUNE_TIMER)
  CancelTimer(URL_TIMER)
  for n = 1, SLOTS do
    CancelTimer(RELOCK_TIMER .. n)
  end
end

-- ─── Properties ─────────────────────────────────────────────────────────────

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
    paint()
  end
end

local function settingChanged()
  if gInitialized then
    syncSettings()
    paint()
  end
end
OPC.Max_Wrong_Attempts = settingChanged
OPC.Lockout_Minutes = settingChanged
OPC.Sequence_Length = settingChanged
OPC.Sequence_Window_Seconds = settingChanged

function OPC.Target_List_Filter()
  if gInitialized then
    refreshTargets()
  end
end

for n = 1, SLOTS do
  OPC["Guarded_" .. n .. "_Name"] = function()
    if gInitialized then
      syncSlots()
      paint()
    end
  end
end

-- ─── Actions ────────────────────────────────────────────────────────────────

function EC.REGISTER_NOW()
  license.register()
end

function EC.PRINT_PAGE_LINK()
  -- Printed, not logged: the dealer asked for it, and the link carries the access token.
  log:print("Page link: %s", desiredWebViewUrl())
end

function EC.REFRESH_STATUS()
  gRecorderCheckedAt = nil
  recorderId()
  paint()
end

function EC.REFRESH_TARGETS()
  refreshTargets()
end

function EC.REPUBLISH_URL()
  publishWebViewUrl("Composer action")
  paint()
end

function EC.REMOVE_ALL_CODES()
  if gEngine == nil then
    return
  end
  gEngine:removeAllCodes()
  save()
  log:warn("all codes removed from Composer")
  paint()
end

function EC.PRINT_STATE()
  if gEngine == nil then
    return
  end
  log:print("== PIN Lock ==")
  log:print("  status: %s", gateStatus())
  log:print("  licence: %s", license.describe())
  log:print("  entry points: %s", entryLine())
  for _, a in ipairs(gEngine:slotList()) do
    log:print("  guarded %d: %s", a.n, a.name)
  end
  for _, c in ipairs(gEngine:publicCodes()) do
    log:print(
      "  code %-24s %-6s %-9s uses %d%s%s%s",
      c.name,
      c.role,
      c.state,
      c.uses,
      c.max_uses and ("/" .. c.max_uses) or "",
      c.has_pin and "  PIN" or "",
      c.has_seq and "  sequence" or ""
    )
  end
  for _, r in ipairs(gEngine.recent) do
    log:print(
      "  %s  %-7s %s %s [%s%s]",
      os.date("%H:%M:%S", math.floor(r.t)),
      r.result,
      r.code or "-",
      r.action or "",
      r.entry or "",
      r.reason and (", " .. r.reason) or ""
    )
  end
end

-- ─── Composer programming commands ─────────────────────────────────────────

function EC.ENABLE_CODE(t)
  t = t or {}
  if gEngine == nil then
    return
  end
  local ok, why = gEngine:setEnabled(t.NAME, true)
  if not ok then
    refused("Enable Code", why)
  end
  paint()
end

function EC.DISABLE_CODE(t)
  t = t or {}
  if gEngine == nil then
    return
  end
  local ok, why = gEngine:setEnabled(t.NAME, false)
  if not ok then
    refused("Disable Code", why)
  end
  paint()
end

function EC.REVOKE_CODE(t)
  t = t or {}
  if gEngine == nil then
    return
  end
  local ok, why = gEngine:revoke(t.NAME)
  if not ok then
    refused("Revoke Code", why)
  end
  paint()
end

function EC.ADD_TEMPORARY_CODE(t)
  t = t or {}
  if gEngine == nil then
    return
  end
  local actions = gEngine:parseActions(t.ACTIONS)
  if #actions == 0 then
    refused("Add Temporary Code", "no valid guarded actions in ACTIONS")
    return
  end
  local id, why = gEngine:addTemporary({
    name = t.NAME,
    pin = t.PIN,
    actions = actions,
    hours = t.HOURS,
    max_uses = tonumber(t.MAX_USES),
  })
  if not id then
    refused("Add Temporary Code", why)
  end
  paint()
end

function EC.KEYPAD_PRESS(t)
  t = t or {}
  if gEngine == nil then
    return
  end
  gEngine:keypadPress(t.KEYPAD, t.BUTTON)
end

function EC.CLEAR_LOCKOUTS()
  if gEngine == nil then
    return
  end
  gEngine:clearLockouts()
  paint()
end

-- ─── Conditionals (TestCondition name, tParams{VALUE, LOGIC}) ──────────────

--- "= value" is true when the thing holds; "!= value" when it does not.
local function keyedTruth(tParams, holds)
  tParams = tParams or {}
  local answer = gEngine ~= nil and holds(tParams.VALUE) == true
  if tostring(tParams.LOGIC or "EQUAL"):upper() == "NOT_EQUAL" then
    return not answer
  end
  return answer
end

function TC.CODE_ACTIVE(_, tParams)
  return keyedTruth(tParams, function(name)
    return gEngine:isActive(name)
  end)
end

function TC.ENTRY_LOCKED(_, tParams)
  return keyedTruth(tParams, function(entry)
    local locked = gEngine:lockState(tostring(entry or ""):lower():gsub("^%s+", ""):gsub("%s+$", ""))
    return locked
  end)
end
