--[[==========================================================================
  SmartBuildOS Dealer Settings

  The settings a dealer tweaks on every service call — motion timeouts,
  dim levels, delays, modes — kept as twelve named, typed values that
  Composer programming reads as variables, and edited from a Navigator
  web view behind a Dealer PIN instead of a Composer Pro session.

  One truth: the Composer properties `Setting N Value`. A web write lands
  in the property; the model is rebuilt from the properties; variables,
  events and the page all follow. Licensing is the SmartBuildOS Agent's
  (SKU SBOS_DEALER_PANEL): a definitive denial with enforcement on makes
  the panel read-only, uncertainty never does.

  Pure rules: src/dealerpanel/{settings,relay}.lua (tested without a
  controller). Web view and LAN relay follow Atmosphere's proven path.
============================================================================]]

--#ifdef DRIVERCENTRAL
DC_PID = 0
DC_X = nil
DC_FILENAME = "smartbuildos-dealer-panel.c4z"
--#else
DRIVER_GITHUB_REPO = "michelo76/control4-smartbuildos"
DRIVER_FILENAMES = { "smartbuildos-dealer-panel.c4z" }
--#endif

require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")
JSON = require("JSON")

-- Every src require at module scope: the build discovers modules by loading
-- this file under the shim, where a require inside a function is never seen.
local log = require("lib.logging")
local persist = require("lib.persist")
local license = require("sbos.license")
local Settings = require("dealerpanel.settings")
local Relay = require("dealerpanel.relay")

gInitialized = false

local SKU = "SBOS_DEALER_PANEL"
local C4Z_NAME = "smartbuildos-dealer-panel"
local WEBVIEW_BINDING = 5001
local UI_RELAY_PORT = 47822
local UI_RELAY_ID = "dealerpanel-ui-relay"
local P_RELAY_TOKEN = "dealerpanel_relay_token_v1"
local STATUS_TIMER = "DpStatusPaint"
local HEAL_TIMER = "DpUrlHeal"

local EVENT_CHANGED, EVENT_REFUSED, EVENT_LOCKED = 1, 2, 3

local gModel = Settings.build({})
local gGate = nil
local gReadOnlyReason = nil -- "unlicensed" when enforcement halts writes
local gRelayPort = nil
local gRelayToken = nil
local gRelayBuffers = {}
local gPublishedUrl = nil
local gAppHtml = nil
local gLastChange = "none yet"
local gLastStatus = nil

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

-- ─── Model ──────────────────────────────────────────────────────────────────

local function rebuildModel()
  gModel = Settings.build(Properties)
end

local function paintSlots()
  for n = 1, Settings.SLOTS do
    local e = gModel.slots[n]
    local def = e.def
    local usable = def.enabled and def.refusal == nil
    setVar("SETTING_" .. n .. "_NAME", def.enabled and def.name or "")
    setVar("SETTING_" .. n, usable and Settings.text(def, e.value) or "")
    setVar("SETTING_" .. n .. "_NUMBER", usable and Settings.numeric(def, e.value) or 0)
  end
  setVar("SETTINGS_CONFIGURED", gModel.configured)
end

local function pinConfigured()
  return tostring(Properties["Dealer PIN"] or "") ~= ""
end

local function writable()
  return gReadOnlyReason == nil and pinConfigured() and not (gGate ~= nil and gGate:isLocked())
end

local function panelStatus()
  if gReadOnlyReason ~= nil then
    return gReadOnlyReason
  end
  if not pinConfigured() then
    return "read-only (set a Dealer PIN to allow edits)"
  end
  if gGate ~= nil and gGate:isLocked() then
    return string.format("locked for %ds after wrong PINs", gGate:secondsLeft())
  end
  return string.format("%d setting(s) configured, writable", gModel.configured)
end

-- ─── Relay (Atmosphere's pattern) ───────────────────────────────────────────

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
    return C4:HMAC("SHA256", seed, "dealerpanel-relay", { return_encoding = "HEX" })
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
  if ok and type(html) == "string" and #html > 1024 then
    gAppHtml = html
  end
  return gAppHtml
end

--- First non-loopback IPv4 anywhere in a Director bindings answer (its
--- shape varies by project/OS; Atmosphere's deep walk).
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

local function snapshot()
  return Settings.snapshot(gModel, {
    pin_configured = pinConfigured(),
    writable = writable(),
    status = panelStatus(),
    read_only_reason = gReadOnlyReason,
    locked_seconds = gGate and gGate:secondsLeft() or 0,
    licence = license.statusLabel(),
    driver_version = tostring(C4:GetDriverConfigInfo("version")),
  })
end

local function paint()
  UpdateProperty("Panel Status", panelStatus())
  UpdateProperty("Last Change", gLastChange)
  setVar("PANEL_STATUS", panelStatus())
  paintSlots()
  local healthy = gReadOnlyReason == nil
  if gLastStatus ~= nil and gLastStatus ~= healthy then
    log:info("Panel %s", healthy and "writable again" or "read-only: " .. tostring(gReadOnlyReason))
  end
  gLastStatus = healthy
end

--- Applies a write from any source. Returns a result table for the page.
local function applyWrite(nameOrSlot, raw, source)
  if gReadOnlyReason ~= nil then
    fire(EVENT_REFUSED)
    return { ok = false, reason = gReadOnlyReason }
  end
  local e, value, why, changed = Settings.propose(gModel, nameOrSlot, raw)
  if e == nil then
    fire(EVENT_REFUSED)
    return { ok = false, reason = "invalid", detail = why }
  end
  local text = Settings.text(e.def, value)
  if changed then
    -- The property IS the truth: write it, then rebuild from the properties.
    UpdateProperty("Setting " .. e.def.slot .. " Value", text)
    Properties["Setting " .. e.def.slot .. " Value"] = text
    rebuildModel()
    gLastChange = string.format("%s = %s (%s, %s)", e.def.name, text, tostring(source), os.date("%H:%M:%S"))
    setVar("CHANGED_SETTING", e.def.name)
    setVar("CHANGED_VALUE", text)
    paint()
    fire(EVENT_CHANGED)
    log:info("Setting %s = %s (%s)", e.def.name, text, tostring(source))
  end
  return { ok = true, changed = changed == true, setting = { slot = e.def.slot, name = e.def.name, text = text } }
end

local relayProvider = {
  appHtml = appHtml,
  state = function()
    return JSON:encode(snapshot())
  end,
  verify = function(pin)
    return gGate:check(Properties["Dealer PIN"], pin)
  end,
  set = function(nameOrSlot, value, pin)
    local ok, reason = gGate:check(Properties["Dealer PIN"], pin)
    if not ok then
      fire(EVENT_REFUSED)
      return { ok = false, reason = reason, locked_seconds = gGate:secondsLeft() }
    end
    return applyWrite(nameOrSlot, value, "web view")
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
  local req = Relay.parse(gRelayBuffers[handle])
  if req == nil then
    return
  end
  gRelayBuffers[handle] = nil
  local result = Relay.route(req, relayToken(), relayProvider)
  pcall(function()
    C4:ServerSend(handle, Relay.render(result))
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
    log:warn("UI relay could not listen on port %d - page falls back to the JS API", UI_RELAY_PORT)
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
  if host ~= "" then
    return base .. "?relay=" .. encodeParam(string.format("http://%s:%d", host, gRelayPort)) .. "&k=" .. relayToken()
  end
  return base
end

local function paintRelayStatus()
  local line
  if gRelayPort == nil then
    line = string.format("Not listening - port %d unavailable", UI_RELAY_PORT)
  else
    local host = relayHost()
    if host == "" then
      line = string.format("Listening :%d - controller address UNKNOWN, set App Relay Address", gRelayPort)
    else
      line = string.format("Listening :%d - serving http://%s:%d to the app", gRelayPort, host, gRelayPort)
    end
  end
  UpdateProperty("App Data Relay", line)
end

local function publishWebViewUrl(reason)
  local url = desiredWebViewUrl()
  C4:SendToProxy(WEBVIEW_BINDING, "URL_CHANGED", { url = url })
  gPublishedUrl = url
  paintRelayStatus()
  log:debug("WebView URL published (%s)", tostring(reason))
end

-- ─── JS API channel (secondary: the page tries the relay first) ─────────────

local function uiCommand(cmd, tParams)
  tParams = tParams or {}
  if cmd == "DEALER_GET_STATE" then
    return JSON:encode(snapshot())
  elseif cmd == "DEALER_SET" then
    return JSON:encode(relayProvider.set(tParams.NAME or tParams.SLOT, tParams.VALUE, tParams.PIN))
  elseif cmd == "DEALER_VERIFY" then
    local ok, reason = relayProvider.verify(tParams.PIN)
    return JSON:encode({ ok = ok == true, reason = reason })
  end
  return nil
end

for _, cmd in ipairs({ "DEALER_GET_STATE", "DEALER_SET", "DEALER_VERIFY" }) do
  UIR[cmd] = function(tParams)
    return uiCommand(cmd, tParams)
  end
  RFP[cmd] = function(_, _, tParams)
    return uiCommand(cmd, tParams)
  end
end
UIR.suppressDebug = { DEALER_GET_STATE = true }

-- ─── Licence ────────────────────────────────────────────────────────────────

local function reconcileLicence()
  if license.enforces() then
    if gReadOnlyReason ~= "unlicensed" then
      gReadOnlyReason = "unlicensed"
      log:warn("SmartBuildOS licence: %s - panel is read-only", tostring(license.statusLabel()))
    end
  elseif gReadOnlyReason == "unlicensed" then
    gReadOnlyReason = nil
  end
  paint()
end

-- ─── Lifecycle ──────────────────────────────────────────────────────────────

local function registerComposerSurface()
  local vars = {
    { "PANEL_STATUS", "starting", "STRING" },
    { "SETTINGS_CONFIGURED", 0, "NUMBER" },
    { "CHANGED_SETTING", "", "STRING" },
    { "CHANGED_VALUE", "", "STRING" },
  }
  for n = 1, Settings.SLOTS do
    vars[#vars + 1] = { "SETTING_" .. n, "", "STRING" }
    vars[#vars + 1] = { "SETTING_" .. n .. "_NUMBER", 0, "NUMBER" }
    vars[#vars + 1] = { "SETTING_" .. n .. "_NAME", "", "STRING" }
  end
  for _, v in ipairs(vars) do
    pcall(function()
      C4:AddVariable(v[1], v[2], v[3], true)
    end)
  end
  for _, e in ipairs({
    { 1, "Setting Changed", "A dealer setting changed (see CHANGED_SETTING and CHANGED_VALUE)" },
    { 2, "Setting Change Refused", "A write was refused" },
    { 3, "Panel Locked", "Too many wrong PINs" },
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
  log:setLogName("DealerSettings")
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
  gGate = Relay.newGate({
    now = os.time,
    onLocked = function()
      fire(EVENT_LOCKED)
      paint()
    end,
  })
  rebuildModel()

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
  startUiRelay()
  publishWebViewUrl("late-init")
  paint()
  SetTimer(STATUS_TIMER, 60 * ONE_SECOND, function()
    paint()
    -- Heal the URL if the address or relay state moved underneath us.
    if desiredWebViewUrl() ~= gPublishedUrl then
      publishWebViewUrl("heal")
    end
  end, true)
end

function OnDriverDestroyed()
  stopUiRelay()
  CancelTimer(STATUS_TIMER)
  CancelTimer(HEAL_TIMER)
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
    publishWebViewUrl("relay-address-changed")
  end
end

function OPC.Dealer_PIN()
  if gInitialized then
    if gGate then
      gGate:reset()
    end
    paint()
  end
end

--- Any `Setting N …` property: rebuild from the properties (one truth) and
--- report what changed to programming.
local function settingProperty(strProperty)
  if not gInitialized then
    return
  end
  local before = {}
  for n = 1, Settings.SLOTS do
    local e = gModel.slots[n]
    before[n] =
      { name = e.def.name, text = Settings.text(e.def, e.value), usable = e.def.enabled and e.def.refusal == nil }
  end
  rebuildModel()
  for n = 1, Settings.SLOTS do
    local e = gModel.slots[n]
    local usable = e.def.enabled and e.def.refusal == nil
    local text = Settings.text(e.def, e.value)
    if usable and (not before[n].usable or before[n].text ~= text or before[n].name ~= e.def.name) then
      gLastChange = string.format("%s = %s (Composer, %s)", e.def.name, text, os.date("%H:%M:%S"))
      setVar("CHANGED_SETTING", e.def.name)
      setVar("CHANGED_VALUE", text)
      fire(EVENT_CHANGED)
    end
  end
  for _, r in ipairs(gModel.refusals) do
    log:warn("Setting %d (%s): %s", r.slot, r.name, r.reason)
  end
  paint()
end

for n = 1, Settings.SLOTS do
  for _, suffix in ipairs({ "Name", "Type", "Value", "Options" }) do
    OPC["Setting_" .. n .. "_" .. suffix] = settingProperty
  end
end

-- ─── Actions ────────────────────────────────────────────────────────────────

function EC.REGISTER_NOW()
  license.register()
end

function EC.REFRESH_STATUS()
  rebuildModel()
  paint()
end

function EC.RELOAD_URL()
  gAppHtml = nil
  publishWebViewUrl("action")
end

function EC.RESET_LOCK()
  if gGate then
    gGate:reset()
  end
  paint()
end

function EC.PRINT_SETTINGS()
  log:print("== Dealer Settings ==")
  log:print("  status: %s", panelStatus())
  log:print("  licence: %s", license.describe())
  log:print("  relay: %s", tostring(Properties["App Data Relay"]))
  for n = 1, Settings.SLOTS do
    local e = gModel.slots[n]
    if e.def.enabled then
      log:print(
        "  %2d  %-24s %-7s %-20s %s",
        n,
        e.def.name,
        e.def.type,
        Settings.text(e.def, e.value),
        e.refusal and ("REFUSED: " .. e.refusal) or ""
      )
    end
  end
end

-- ─── Programming commands ───────────────────────────────────────────────────

function EC.SET_SETTING(tParams)
  tParams = tParams or {}
  local result = applyWrite(tParams.NAME, tParams.VALUE, "programming")
  if not result.ok then
    log:warn(
      "Set Setting %s refused: %s %s",
      tostring(tParams.NAME),
      tostring(result.reason),
      tostring(result.detail or "")
    )
  end
end

function EC.TOGGLE_SETTING(tParams)
  tParams = tParams or {}
  local e = Settings.find(gModel, tParams.NAME)
  if e == nil or e.def.type ~= "Toggle" then
    fire(EVENT_REFUSED)
    log:warn("Toggle Setting %s refused: not a Toggle setting", tostring(tParams.NAME))
    return
  end
  applyWrite(e.def.slot, e.value and "Off" or "On", "programming")
end

-- ─── Conditionals ───────────────────────────────────────────────────────────

local function logicEquals(tParams)
  local logic = tostring((tParams or {}).LOGIC or "EQUAL"):upper()
  return not (logic == "NOT_EQUAL" or logic == "!=" or logic == "NOTEQUAL")
end

for n = 1, Settings.SLOTS do
  TC["SETTING_" .. n .. "_IS"] = function(_, tParams)
    tParams = tParams or {}
    local e = gModel.slots[n]
    local usable = e ~= nil and e.def.enabled and e.def.refusal == nil
    local equal = usable and Settings.equalsText(e, tParams.STRING or tParams.VALUE or "") or false
    if logicEquals(tParams) then
      return equal
    end
    return not equal
  end
end

function TC.PANEL_WRITABLE()
  return writable()
end
