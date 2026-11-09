--[[==========================================================================
  SmartBuildOS Variable Inspector

  Composer Pro's variable view, on a phone, without a Pro session: every
  device in the project, the variables of the one you tap (live while it
  is open), a persisted watch list with a short history per variable, and
  a Dealer-PIN-guarded Set.

  Licensing: the SmartBuildOS Agent (SKU SBOS_VARIABLE_INSPECTOR, through
  sbos.license). A definitive denial with enforcement on makes the page and
  the programming commands read-only; reading never stops.

  Pure rules: src/varinspector/{model,relay}.lua (tested without a
  controller). Transport: Atmosphere's LAN relay pattern — the driver
  listens on port 47823, the page fetches plain LAN HTTP, the token rides
  the web_view_url query.
============================================================================]]

--#ifdef DRIVERCENTRAL
DC_PID = 0
DC_X = nil
DC_FILENAME = "smartbuildos-variable-inspector.c4z"
--#else
DRIVER_GITHUB_REPO = "michelo76/control4-smartbuildos"
DRIVER_FILENAMES = { "smartbuildos-variable-inspector.c4z" }
--#endif

-- Every require at module scope: the build discovers modules by loading
-- this file under the shim, and a require inside a function is never seen.
require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")
JSON = require("JSON")

local log = require("lib.logging")
local persist = require("lib.persist")
local license = require("sbos.license")
local Ring = require("tracer.ring")
local Config = require("flightrecorder.config")
local Model = require("varinspector.model")
local relay = require("varinspector.relay")
local _unused = { Ring, Config } -- transitive dependencies of the model, pinned for the squish step

gInitialized = false

local SKU = "SBOS_VARIABLE_INSPECTOR"
local C4Z_NAME = "smartbuildos-variable-inspector"
local WEBVIEW_BINDING = 5001
local UI_RELAY_PORT = 47823
local UI_RELAY_ID = "varinspector-ui-relay"
local P_RELAY_TOKEN = "vi_relay_token_v1"
local WATCH_KEY = "vi_watches_v1"
local STATUS_TIMER = "ViStatusPaint"
local SOON_TIMER = "ViPaintSoon"
local URL_TIMER = "ViUrlRepublish"
local PRINT_DEFAULT = 20

local EVENT_CHANGED, EVENT_SET, EVENT_REFUSED = 1, 2, 3

local gInspector = nil
local gRelayPort = nil
local gRelayBuffers = {}
local gRelayToken = nil
local gAppHtml = nil
local gPublishedUrl = nil
local gLastError = "none"
local gLicenceHalted = false

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

-- ─── Mode ───────────────────────────────────────────────────────────────────

local function dealerPinConfigured()
  return tostring(Properties["Dealer PIN"] or "") ~= ""
end

local function pinMatches(pin)
  local configured = tostring(Properties["Dealer PIN"] or "")
  return configured ~= "" and tostring(pin or "") == configured
end

--- Read-only when the licence is enforced against us or no Dealer PIN is
--- set (an unguarded Set is worse than none).
local function reconcileMode()
  if gInspector == nil then
    return
  end
  gLicenceHalted = license.enforces()
  gInspector:setReadOnly(gLicenceHalted or not dealerPinConfigured())
end

local function modeLine()
  if gInspector == nil then
    return "starting"
  end
  if gLicenceHalted then
    return "read-only (licence: " .. tostring(license.statusLabel()) .. ")"
  end
  if not dealerPinConfigured() then
    return "read-only (set a Dealer PIN to allow writes)"
  end
  return "writable with Dealer PIN"
end

-- ─── Painting ───────────────────────────────────────────────────────────────

local function paintRecent()
  if gInspector == nil then
    return
  end
  local st = gInspector:status()
  UpdateProperty("Watched", string.format("%d of %d", st.watched, st.max_watches))
  setVar("WATCHED_COUNT", st.watched)
  if st.last ~= nil then
    local text = string.format("%s: %s = %s", tostring(st.last.device_label), st.last.name, tostring(st.last.value))
    UpdateProperty("Last Change", string.format("%s  (%s)", text, os.date("%H:%M:%S", math.floor(st.last.t or 0))))
    setVar("LAST_CHANGE", text)
    setVar("LAST_CHANGE_DEVICE", st.last.device_id or 0)
    setVar("LAST_CHANGE_VARIABLE", st.last.name)
    setVar("LAST_CHANGE_VALUE", tostring(st.last.value))
  end
end

local function relayLine()
  if gRelayPort == nil then
    return string.format("Not listening - port %d unavailable", UI_RELAY_PORT)
  end
  return string.format("Listening :%d", gRelayPort)
end

local function paint()
  reconcileMode()
  UpdateProperty("Inspector Mode", modeLine())
  UpdateProperty("App Data Relay", relayLine())
  UpdateProperty("Last Error", gLastError)
  setVar("RELAY_STATUS", gRelayPort and "listening" or "not_listening")
  paintRecent()
end

local function paintSoon()
  SetTimer(SOON_TIMER, 2 * ONE_SECOND, paintRecent)
end

-- ─── Persistence ────────────────────────────────────────────────────────────

local function persistWatches()
  if gInspector then
    persist:set(WATCH_KEY, gInspector:watchDoc())
  end
end

-- ─── Relay (Atmosphere's pattern) ───────────────────────────────────────────

local function findAddrDeep(node, depth, seen)
  if type(node) ~= "table" or depth > 6 or seen[node] then
    return nil
  end
  seen[node] = true
  local addr = tostring(node.addr or "")
  if addr:match("^%d+%.%d+%.%d+%.%d+$") ~= nil and addr:find("^127%.") == nil then
    return addr
  end
  for _, child in pairs(node) do
    if type(child) == "table" then
      local found = findAddrDeep(child, depth + 1, seen)
      if found ~= nil then
        return found
      end
    end
  end
  return nil
end

local function relayHost()
  local configured = tostring(Properties["App Relay Address"] or ""):gsub("%s+", "")
  if configured ~= "" and configured:lower() ~= "auto" then
    return configured
  end
  local ok, devices = pcall(function()
    return C4:GetDevices({})
  end)
  if not ok or type(devices) ~= "table" then
    return ""
  end
  for rawId, device in pairs(devices) do
    local id = tonumber(rawId)
    local file = tostring((type(device) == "table" and device.driverFileName) or "")
    if id ~= nil and file:find("^control4_") ~= nil then
      for _, api in ipairs({ "GetNetworkBindingsByDevice", "GetBindingsByDevice" }) do
        local okB, raw = pcall(function()
          return C4[api](C4, id)
        end)
        if okB and type(raw) == "table" then
          local found = findAddrDeep(raw, 0, {})
          if found ~= nil then
            return found
          end
        end
      end
    end
  end
  return ""
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
    return C4:HMAC("SHA256", seed, "varinspector-relay", { return_encoding = "HEX" })
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
  local ok, html = pcall(function()
    C4:FileSetDir("C4Z_ROOT", C4Z_NAME)
    return FileRead("www/app/index.html")
  end)
  if ok and type(html) == "string" and #html > 512 then
    gAppHtml = html
  end
  return gAppHtml
end

local relayProvider = {
  appHtml = appHtml,
  devices = function(filter)
    return gInspector:devices(filter)
  end,
  openDevice = function(id)
    return gInspector:openDevice(id)
  end,
  closeDevice = function()
    return gInspector:closeDevice()
  end,
  state = function()
    local st = gInspector:status()
    st.mode = modeLine()
    st.open_variables = gInspector:openSnapshot()
    st.watches = gInspector:watchList(10)
    st.pin_required = dealerPinConfigured()
    return st
  end,
  watch = function(deviceId, varId)
    local ok, why = gInspector:watch(deviceId, varId)
    if ok then
      persistWatches()
      paintSoon()
    end
    return ok, why
  end,
  unwatch = function(deviceId, varId)
    local ok, why = gInspector:unwatch(deviceId, varId)
    if ok then
      persistWatches()
      paintSoon()
    end
    return ok, why
  end,
  set = function(deviceId, varId, value, pin)
    return gInspector:setValue(deviceId, varId, value, pinMatches(pin))
  end,
  clear = function()
    gInspector:clearHistory()
    paintSoon()
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
  if gInspector == nil then
    pcall(function()
      C4:ServerSend(
        handle,
        relay.render({
          status = "503 Service Unavailable",
          contentType = "application/json",
          body = '{"ok":false,"error":"starting"}',
        })
      )
    end)
  else
    local result = relay.route(req, relayToken(), relayProvider)
    pcall(function()
      C4:ServerSend(handle, relay.render(result))
    end)
  end
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
    gLastError = "relay port " .. UI_RELAY_PORT .. " unavailable; the page cannot load data"
    log:warn("%s", gLastError)
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

--- Same-origin from the relay when the controller address is known (page and
--- its data ride one transport); else the c4z page with the relay pointer.
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

local function publishWebViewUrl(reason)
  local url = desiredWebViewUrl()
  pcall(function()
    C4:SendToProxy(WEBVIEW_BINDING, "URL_CHANGED", { url = url })
  end)
  gPublishedUrl = url
  log:debug("WebView URL published (%s): %s", tostring(reason), (url:gsub("k=[%w]+", "k=[token]")))
end

-- ─── Lifecycle ──────────────────────────────────────────────────────────────

local function registerComposerSurface()
  for _, v in ipairs({
    { "WATCHED_COUNT", 0, "NUMBER" },
    { "LAST_CHANGE", "", "STRING" },
    { "LAST_CHANGE_DEVICE", 0, "NUMBER" },
    { "LAST_CHANGE_VARIABLE", "", "STRING" },
    { "LAST_CHANGE_VALUE", "", "STRING" },
    { "RELAY_STATUS", "starting", "STRING" },
  }) do
    pcall(function()
      C4:AddVariable(v[1], v[2], v[3], true)
    end)
  end
  for _, e in ipairs({
    { 1, "Watched Variable Changed", "A variable on the watch list changed" },
    { 2, "Value Set From Page", "A value was written through the inspector page" },
    { 3, "Set Refused", "A write was refused" },
  }) do
    pcall(function()
      C4:AddEvent(e[1], e[2], e[3])
    end)
  end
end

local function buildInspector()
  return Model.new({
    now = os.time,
    register = function(deviceId, varId)
      return pcall(function()
        C4:RegisterVariableListener(deviceId, varId)
      end)
    end,
    unregister = function(deviceId, varId)
      pcall(function()
        C4:UnregisterVariableListener(deviceId, varId)
      end)
    end,
    readVariables = function(deviceId)
      local ok, vars = pcall(function()
        return C4:GetDeviceVariables(deviceId)
      end)
      if ok and type(vars) == "table" then
        return vars
      end
      return nil
    end,
    devices = function()
      local ok, list = pcall(function()
        return C4:GetDevices({})
      end)
      if ok and type(list) == "table" then
        return list
      end
      return {}
    end,
    setVariable = function(deviceId, varId, value)
      -- PROBE: documented (DriverWorks API, Variable section), unmeasured on
      -- this bench. Director's own refusal (if any) surfaces as an error.
      C4:SetDeviceVariable(deviceId, varId, value)
      return true
    end,
    emit = function(kind, detail)
      if kind == "change" then
        fire(EVENT_CHANGED)
        paintSoon()
      elseif kind == "set" then
        fire(EVENT_SET)
        log:info(
          "Set from page: device %s variable %s = %s",
          tostring(detail.device_id),
          tostring(detail.name),
          tostring(detail.value)
        )
      elseif kind == "refused" then
        fire(EVENT_REFUSED)
        gLastError = "set refused: " .. tostring(detail.reason)
        paintSoon()
      end
    end,
    selfDeviceId = C4:GetDeviceID(),
    historySize = tonumber(Properties["History Size"]),
  })
end

function OnDriverInit()
  --#ifdef DRIVERCENTRAL
  require("cloud-client-byte")
  C4:AllowExecute(false)
  --#else
  C4:AllowExecute(true)
  --#endif
  gInitialized = false
  log:setLogName("VariableInspector")
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

  gInspector = buildInspector()
  local restored = gInspector:restoreWatches(persist:get(WATCH_KEY, false) or nil)
  if restored > 0 then
    log:info("Restored %d watched variable(s)", restored)
  end

  license.setup({ sku = SKU })
  EC.SBOS_ENTITLEMENT = function(tParams)
    license.onEntitlement(tParams)
    paint()
  end

  gInitialized = true
  UpdateProperty("Driver Status", "Online")
  pcall(function()
    UpdateProperty("Driver Version", tostring(C4:GetDriverConfigInfo("version")))
  end)

  startUiRelay()
  publishWebViewUrl("late-init")
  -- A notify sent before project start is lost: republish once later.
  SetTimer(URL_TIMER, 60 * ONE_SECOND, function()
    publishWebViewUrl("late-init+60s")
  end)
  SetTimer(STATUS_TIMER, 60 * ONE_SECOND, paint, true)
  paint()
end

function OnDriverDestroyed()
  if gInspector then
    persistWatches()
    gInspector:stop()
  end
  stopUiRelay()
  CancelTimer(STATUS_TIMER)
  CancelTimer(SOON_TIMER)
  CancelTimer(URL_TIMER)
end

--- Director's callback for every registered variable (open device + watches).
function OnWatchedVariableChanged(idDevice, idVariable, strValue)
  if gInspector == nil then
    return
  end
  pcall(function()
    gInspector:onChange(tointeger(idDevice), tointeger(idVariable), strValue)
  end)
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

function OPC.Dealer_PIN()
  if gInitialized then
    paint()
  end
end

function OPC.App_Relay_Address()
  if gInitialized then
    publishWebViewUrl("relay address changed")
    paint()
  end
end

function OPC.History_Size(value)
  if gInitialized and gInspector then
    gInspector.historySize = math.max(
      Model.LIMITS.history_min,
      math.min(Model.LIMITS.history_max, tonumber(value) or Model.LIMITS.history_default)
    )
  end
end

-- ─── Actions ────────────────────────────────────────────────────────────────

function EC.REGISTER_NOW()
  license.register()
end

function EC.REFRESH_STATUS()
  paint()
end

function EC.REPUBLISH_URL()
  publishWebViewUrl("Composer action")
  paint()
end

function EC.CLEAR_HISTORY()
  if gInspector then
    gInspector:clearHistory()
    UpdateProperty("Last Change", "none yet (history cleared)")
    paintRecent()
  end
end

function EC.PRINT_DEVICE()
  if gInspector == nil then
    return
  end
  local id = tonumber(Properties["Inspect Device ID"])
  if id == nil then
    log:print("Set Inspect Device ID to a Director device id first")
    return
  end
  local info = gInspector:deviceInfo(id)
  local vars = gInspector.deps.readVariables(id)
  local snap = Model.snapshot(vars)
  log:print("== Variables of device %d (%s) ==", id, info and info.name or "not in the project")
  if #snap == 0 then
    log:print("  no readable variables")
  end
  for _, v in ipairs(snap) do
    log:print("  %6d  %-32s = %s%s", v.id, v.name, tostring(v.value), v.readonly and "  (read-only)" or "")
  end
end

function EC.PRINT_WATCHES()
  if gInspector == nil then
    return
  end
  local list = gInspector:watchList(PRINT_DEFAULT)
  log:print("== Watch list: %d variable(s), mode: %s ==", #list, modeLine())
  for _, w in ipairs(list) do
    log:print(
      "  %s / %s (device %d, variable %d) = %s",
      tostring(w.device_label),
      w.name,
      w.device_id,
      w.variable_id,
      tostring(w.value)
    )
    for _, h in ipairs(w.history) do
      log:print("      %s", Model.formatHistory(w.name, h))
    end
  end
end

-- ─── Composer programming commands ─────────────────────────────────────────

local function variableIdByName(deviceId, name)
  local vars = gInspector.deps.readVariables(deviceId)
  for rawId, v in pairs(vars or {}) do
    if type(v) == "table" and tostring(v.name):lower() == tostring(name):lower() then
      return tonumber(rawId), v.name
    end
  end
  return nil
end

function EC.WATCH_VARIABLE(tParams)
  tParams = tParams or {}
  if gInspector == nil then
    return
  end
  local deviceId = tonumber(tParams.DEVICE)
  local varId, name = variableIdByName(deviceId, tParams.VARIABLE)
  if varId == nil then
    gLastError = "WATCH_VARIABLE: no variable named "
      .. tostring(tParams.VARIABLE)
      .. " on device "
      .. tostring(deviceId)
    log:warn("%s", gLastError)
    paint()
    return
  end
  local ok, why = gInspector:watch(deviceId, varId, name)
  if ok then
    persistWatches()
  else
    gLastError = "WATCH_VARIABLE refused: " .. tostring(why)
  end
  paint()
end

function EC.UNWATCH_VARIABLE(tParams)
  tParams = tParams or {}
  if gInspector == nil then
    return
  end
  local deviceId = tonumber(tParams.DEVICE)
  local varId = variableIdByName(deviceId, tParams.VARIABLE)
  if varId == nil then
    for _, w in ipairs(gInspector:watchList(0)) do
      if w.device_id == deviceId and tostring(w.name):lower() == tostring(tParams.VARIABLE or ""):lower() then
        varId = w.variable_id
      end
    end
  end
  if varId ~= nil and gInspector:unwatch(deviceId, varId) then
    persistWatches()
  end
  paint()
end

-- ─── Conditionals ───────────────────────────────────────────────────────────

function TC.INSPECTOR_READ_ONLY()
  return gInspector == nil or gInspector.readOnly == true
end
