--[[==========================================================================
  SmartBuildOS Home Guide
  A personalised user manual generated from the project.

  The homeowner opens one tile in Navigator and reads THEIR house: every
  room, the devices in it grouped by what they are, a plain paragraph on how
  each kind is used, the dealer's contact block, the dealer's notes per room,
  and what to do when something looks wrong. Nothing is typed twice: the
  manual is rebuilt from Director's device list on start, every hour, on
  the Refresh action and on the REBUILD_MANUAL programming command.

  Surface: a uibutton proxy whose web view is the page shipped in this c4z,
  served same-origin from a LAN relay on port 47821 (Atmosphere's proven
  pattern), with a minted token in the URL for the data routes. Licensing:
  SKU SBOS_USER_MANUAL through the SmartBuildOS Agent (sbos.license); a
  definitive denial with enforcement stops the relay and says so.

  Pure rules: src/usermanual/{manual,relay}.lua — tested without a controller.
============================================================================]]

--#ifdef DRIVERCENTRAL
DC_PID = 0
DC_X = nil
DC_FILENAME = "smartbuildos-user-manual.c4z"
--#else
DRIVER_GITHUB_REPO = "michelo76/control4-smartbuildos"
DRIVER_FILENAMES = { "smartbuildos-user-manual.c4z" }
--#endif

require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")
JSON = require("JSON")

-- Every src require at module scope: the build discovers modules by loading
-- this file under the shim, where nothing past CheckMinimumVersion runs.
local log = require("lib.logging")
local persist = require("lib.persist")
local license = require("sbos.license")
local RelayHost = require("lib.relayhost")
local gHost = nil -- the relay address resolver, built once publishWebViewUrl exists
local Manual = require("usermanual.manual")
local Relay = require("usermanual.relay")

gInitialized = false

local SKU = "SBOS_USER_MANUAL"
local C4Z_NAME = "smartbuildos-user-manual"
local WEBVIEW_BINDING = 5001
local UI_RELAY_PORT = 47821
local UI_RELAY_ID = "home-guide-ui-relay"
local P_RELAY_TOKEN = "hg_relay_token_v1"
local REBUILD_TIMER = "HgRebuild"
local STATUS_TIMER = "HgStatusPaint"
local REPUBLISH_TIMER = "HgRepublish"
local REBUILD_SECONDS = 3600
local MAX_REQUEST_BYTES = 64 * 1024

local EVENT_REBUILT, EVENT_UNAVAILABLE, EVENT_RESTORED = 1, 2, 3

local gManual = nil -- the current document (table)
local gRebuiltAt = nil
local gManualJson = nil -- its JSON, encoded once per rebuild
local gRelayPort = nil
local gRelayToken = nil
local gRelayBuffers = {}
local gAppHtml = nil
local gPublishedUrl = nil
local gLicenceHalted = false
local gLastServing = nil
local gLastError = "none"

local function nowIso()
  return os.date("!%Y-%m-%dT%H:%M:%SZ")
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

-- ─── The manual ─────────────────────────────────────────────────────────────

local function devices()
  local ok, list = pcall(function()
    return C4:GetDevices({})
  end)
  if ok and type(list) == "table" then
    return list
  end
  return {}
end

local function roomNotes()
  local notes = {}
  for i = 1, 6 do
    notes[#notes + 1] = tostring(Properties["Room Note " .. i] or "")
  end
  return notes
end

local function rebuildManual(reason)
  local ok, err = pcall(function()
    gManual = Manual.build({
      devices = devices(),
      dealer = {
        name = Properties["Dealer Name"],
        phone = Properties["Dealer Phone"],
        email = Properties["Dealer Email"],
        hours = Properties["Support Hours"],
        emergency = Properties["Emergency Note"],
      },
      notes = roomNotes(),
      home_name = Properties["Home Name"],
      generated_at = nowIso(),
      driver_version = tostring(C4:GetDriverConfigInfo("version")),
    })
    gManualJson = JSON:encode(gManual)
  end)
  if not ok then
    gLastError = "rebuild failed: " .. tostring(err)
    log:error("%s", gLastError)
    return false
  end
  gLastError = "none"
  gRebuiltAt = os.time()
  log:info(
    "Home Guide rebuilt (%s): %d rooms, %d devices",
    tostring(reason),
    gManual.counts.rooms,
    gManual.counts.devices
  )
  fire(EVENT_REBUILT)
  return true
end

-- ─── Relay ──────────────────────────────────────────────────────────────────

--- The controller's LAN address, from lib.relayhost: the App Relay Address
--- property, else an address this relay has answered on. An address read
--- off another device's binding is never published on trust.
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
    return C4:HMAC("SHA256", seed, "home-guide-relay", { return_encoding = "HEX" })
  end)
  local token = ok and type(hex) == "string" and #hex >= 16 and hex:sub(1, 32)
    or (tostring(os.time()) .. tostring(math.floor(os.clock() * 1000000)))
  gRelayToken = token
  persist:set(P_RELAY_TOKEN, token, true)
  return token
end

--- The page, read once from our own c4z. A failed read is survivable: the
--- URL falls back to controller:// serving with the relay in the query.
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
  manual = function()
    if gManualJson == nil then
      rebuildManual("first request")
    end
    return gManualJson
  end,
  refresh = function()
    rebuildManual("page refresh")
  end,
}

function OnServerDataIn(handle, data, _, _, identifier)
  if identifier ~= nil and identifier ~= UI_RELAY_ID then
    return
  end
  gRelayBuffers[handle] = (gRelayBuffers[handle] or "") .. tostring(data or "")
  if #gRelayBuffers[handle] > MAX_REQUEST_BYTES then
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

local function startRelay()
  if gRelayPort ~= nil then
    return
  end
  local ok = pcall(function()
    C4:CreateServer(UI_RELAY_PORT, "", false, UI_RELAY_ID)
  end)
  if ok then
    gRelayPort = UI_RELAY_PORT
    log:info("Home Guide relay listening on port %d", UI_RELAY_PORT)
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

--- Same-origin from the relay when the host is known and the page loads
--- from the c4z; otherwise controller:// with the relay in the query.
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

local function paintRelay()
  local line
  if gLicenceHalted then
    line = "Stopped - " .. tostring(license.statusLabel())
  elseif gRelayPort == nil then
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
  gPublishedUrl = url
  paintRelay()
  log:debug("Home Guide URL published (%s): %s", tostring(reason), (url:gsub("k=[%w]+", "k=[token]")))
end

gHost = RelayHost.new({
  port = UI_RELAY_PORT,
  service = "home-guide",
  configured = function()
    return Properties["App Relay Address"]
  end,
  onChange = function()
    if gInitialized then
      publishWebViewUrl("address confirmed")
    end
  end,
})

-- ─── Status ─────────────────────────────────────────────────────────────────

local function manualStatus()
  if gLicenceHalted then
    return "unlicensed"
  end
  if gManual == nil then
    return "building"
  end
  if gRelayPort == nil then
    return "built (relay not listening)"
  end
  return "serving"
end

local function paint()
  local status = manualStatus()
  UpdateProperty("Manual Status", status)
  if gManual ~= nil then
    UpdateProperty(
      "Devices In Manual",
      string.format(
        "%d device(s) in %d room(s); %d not shown",
        gManual.counts.devices,
        gManual.counts.rooms,
        gManual.counts.excluded
      )
    )
    -- When it was rebuilt, not when this was painted: painted with the clock,
    -- it moved every minute and read as a rebuild a minute.
    UpdateProperty("Last Rebuilt", gRebuiltAt and os.date("%Y-%m-%d %H:%M:%S", gRebuiltAt) or "not yet")
    setVar("MANUAL_ROOMS", gManual.counts.rooms)
    setVar("MANUAL_DEVICES", gManual.counts.devices)
    setVar("LAST_REBUILT", gManual.generated_at)
  end
  setVar("MANUAL_STATUS", status)
  paintRelay()
  local serving = status == "serving"
  if gLastServing ~= nil and gLastServing ~= serving then
    fire(serving and EVENT_RESTORED or EVENT_UNAVAILABLE)
  end
  gLastServing = serving
end

-- ─── Licence ────────────────────────────────────────────────────────────────

--- Enforcement is the charter's read-only consequence: a DEFINITIVE denial
--- with enforcement on stops the relay (the tile then shows only the
--- unavailable page); uncertainty never does.
local function reconcileLicence()
  local halt = license.enforces()
  if halt and not gLicenceHalted then
    gLicenceHalted = true
    stopRelay()
    gLastError = "SmartBuildOS licence: " .. tostring(license.statusLabel())
    log:warn("%s — Home Guide stopped", gLastError)
    publishWebViewUrl("licence halted")
  elseif not halt and gLicenceHalted then
    gLicenceHalted = false
    gLastError = "none"
    startRelay()
    publishWebViewUrl("licence restored")
  end
end

-- ─── Lifecycle ──────────────────────────────────────────────────────────────

local function registerComposerSurface()
  for _, v in ipairs({
    { "MANUAL_STATUS", "starting", "STRING" },
    { "MANUAL_ROOMS", 0, "NUMBER" },
    { "MANUAL_DEVICES", 0, "NUMBER" },
    { "LAST_REBUILT", "", "STRING" },
  }) do
    pcall(function()
      C4:AddVariable(v[1], v[2], v[3], true)
    end)
  end
  for _, e in ipairs({
    { 1, "Manual Rebuilt", "The Home Guide was rebuilt from the project" },
    { 2, "Guide Unavailable", "The guide stopped serving" },
    { 3, "Guide Restored", "The guide is serving again" },
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
  log:setLogName("HomeGuide")
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

  license.setup({ sku = SKU })
  EC.SBOS_ENTITLEMENT = function(tParams)
    license.onEntitlement(tParams)
    reconcileLicence()
    paint()
  end

  gInitialized = true
  UpdateProperty("Driver Status", "Online")
  pcall(function()
    UpdateProperty("Driver Version", tostring(C4:GetDriverConfigInfo("version")))
  end)

  rebuildManual(tostring(reason))
  startRelay()
  gHost:check()
  publishWebViewUrl("late init")
  -- A notify sent before Navigator is ready can be lost: republish once more.
  SetTimer(REPUBLISH_TIMER, 60 * ONE_SECOND, function()
    publishWebViewUrl("60s republish")
  end)
  SetTimer(REBUILD_TIMER, REBUILD_SECONDS * ONE_SECOND, function()
    rebuildManual("hourly")
    paint()
  end, true)
  SetTimer(STATUS_TIMER, 60 * ONE_SECOND, function()
    if gRelayPort ~= nil then
      gHost:checkIfDue()
    end
    paint()
  end, true)
  paint()
end

function OnDriverDestroyed()
  pcall(license.stop) -- the licence retry timer
  stopRelay()
  CancelTimer(REBUILD_TIMER)
  CancelTimer(STATUS_TIMER)
  CancelTimer(REPUBLISH_TIMER)
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

local function contentProperty()
  if gInitialized then
    rebuildManual("property change")
    paint()
  end
end
OPC.Home_Name = contentProperty
OPC.Dealer_Name = contentProperty
OPC.Dealer_Phone = contentProperty
OPC.Dealer_Email = contentProperty
OPC.Support_Hours = contentProperty
OPC.Emergency_Note = contentProperty
for i = 1, 6 do
  OPC["Room_Note_" .. i] = contentProperty
end

function OPC.App_Relay_Address()
  if gInitialized then
    gHost:check()
    publishWebViewUrl("relay address changed")
  end
end

-- ─── Actions and commands ───────────────────────────────────────────────────

function EC.REFRESH_MANUAL()
  rebuildManual("Composer action")
  paint()
end

function EC.REBUILD_MANUAL()
  rebuildManual("programming")
  paint()
end

function EC.REPUBLISH_URL()
  publishWebViewUrl("Composer action")
end

function EC.REGISTER_NOW()
  license.register()
end

function EC.REFRESH_STATUS()
  paint()
end

function EC.PRINT_OUTLINE()
  if gManual == nil then
    rebuildManual("print")
  end
  log:print("== Home Guide ==")
  log:print("  status: %s", manualStatus())
  log:print("  licence: %s", license.describe())
  log:print("  relay: %s", tostring(Properties["App Data Relay"]))
  if gManual ~= nil then
    for _, line in ipairs(Manual.outline(gManual)) do
      log:print("  %s", line)
    end
  end
  if gLastError ~= "none" then
    log:print("  last error: %s", gLastError)
  end
end
