--[[==========================================================================
  UniFi Protect Viewport — child driver

  One instance per Protect Viewport (viewer). Its whole vocabulary is live
  views: set one, step through them, and — the beloved one — show a view
  TEMPORARILY and restore whatever was up before. The Gateway resolves live
  view names to ids and holds the key; this driver holds the restore state.
============================================================================]]

--#ifdef DRIVERCENTRAL
DC_PID = 0
DC_X = nil
DC_FILENAME = "unifi-protect-viewport.c4z"
--#else
DRIVER_GITHUB_REPO = "michelo76/control4-smartbuildos"
DRIVER_FILENAMES = { "unifi-protect-viewport.c4z" }
--#endif

require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")

JSON = require("JSON")

local log = require("lib.logging")
local persist = require("lib.persist")

local GATEWAY_BINDING = 1
local IDENTITY_PERSIST = "viewer_identity"
local AUTONAME_PERSIST = "auto_name_last"
local DEFAULT_NAME_PREFIX = "UniFi Protect Viewport"
local RESTORE_TIMER = "ProtectViewportRestore"

local EVENTS = {
  { 1, "View Changed", "The viewport's live view changed." },
  { 2, "Viewport Online", "The viewport reconnected to the console." },
  { 3, "Viewport Offline", "The viewport disconnected from the console." },
}

local VARIABLES = {
  { "CURRENT_LIVE_VIEW", "", "STRING" },
}

gInitialized = false
gIdentity = nil
gDeviceState = "UNKNOWN"
gGatewayDeviceId = nil
--- Live views as told by the Gateway: array of { id, name }, order stable.
gLiveviews = {}
--- Current live view id, per the console.
gCurrentLiveview = ""
--- The view to restore after Show View Temporarily, or nil.
gRestoreTo = nil

local function fireEvent(name)
  pcall(function()
    C4:FireEvent(name)
  end)
end

local function setVariable(name, value)
  pcall(function()
    C4:SetVariable(name, tostring(value))
  end)
end

local function findGatewayDeviceId()
  if gGatewayDeviceId ~= nil then
    return gGatewayDeviceId
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
    if id ~= nil and (file == "unifi-protect.c4z" or file == "unifi-protect.c4i") then
      gGatewayDeviceId = id
      return id
    end
  end
  return nil
end

local function askGateway(command, params)
  SendToProxy(GATEWAY_BINDING, command, params)
  local gatewayId = findGatewayDeviceId()
  if gatewayId ~= nil then
    params = params or {}
    params.requester = tostring(C4:GetDeviceID())
    SendToDevice(gatewayId, command, params)
  end
end

local function requestIdentity()
  UpdateProperty("Gateway Link", "Asked gateway at " .. os.date("%H:%M:%S") .. " - waiting for a reply")
  askGateway("PROTECT_GET_DEVICE", {})
end

local IDENTITY_RETRY_TIMER = "ProtectViewportIdentityRetry"
local function armIdentityRetry()
  CancelTimer(IDENTITY_RETRY_TIMER)
  SetTimer(IDENTITY_RETRY_TIMER, 60 * ONE_SECOND, function()
    if gIdentity == nil then
      requestIdentity()
    end
  end, true)
end

local function autoNameDevices(name)
  name = tostring(name or "")
  if name == "" then
    return
  end
  local lastAuto = persist:get(AUTONAME_PERSIST, "")
  local id = C4:GetDeviceID()
  local current = tostring(C4:GetDeviceData(id, "name") or "")
  local isDefault = current:sub(1, #DEFAULT_NAME_PREFIX) == DEFAULT_NAME_PREFIX
  if current ~= name and (isDefault or (lastAuto ~= "" and current == lastAuto)) then
    pcall(function()
      C4:RenameDevice(id, name)
    end)
    persist:set(AUTONAME_PERSIST, name)
  end
end

local function liveviewName(liveviewId)
  for _, lv in ipairs(gLiveviews) do
    if lv.id == liveviewId then
      return lv.name
    end
  end
  return liveviewId
end

--- Applies liveview list + current from a state push or identity reply.
local function applyViewerState(tParams)
  if tParams.liveviews ~= nil then
    gLiveviews = {}
    for pair in tostring(tParams.liveviews):gmatch("[^;]+") do
      local id, name = pair:match("^([^=]+)=(.*)$")
      if id ~= nil then
        table.insert(gLiveviews, { id = id, name = name })
      end
    end
    local names = {}
    for _, lv in ipairs(gLiveviews) do
      table.insert(names, lv.name)
    end
    UpdateProperty("Available Views", #names > 0 and table.concat(names, ", ") or "-")
  end
  if tParams.liveview ~= nil then
    local liveviewId = tostring(tParams.liveview)
    if liveviewId ~= gCurrentLiveview and gCurrentLiveview ~= "" then
      fireEvent("View Changed")
    end
    gCurrentLiveview = liveviewId
    local label = liveviewName(liveviewId)
    setVariable("CURRENT_LIVE_VIEW", label)
    UpdateProperty("Current View", label ~= "" and label or "-")
  end
end

local function updateStatusProperties()
  UpdateProperty("Viewport", gIdentity ~= nil and gIdentity.name or "Not bound")
  UpdateProperty("Viewport State", gDeviceState)
end

function OnDriverInit()
  --#ifdef DRIVERCENTRAL
  require("cloud-client-byte")
  C4:AllowExecute(false)
  --#else
  C4:AllowExecute(true)
  --#endif
  gInitialized = false
  log:setLogName(C4:GetDeviceData(C4:GetDeviceID(), "name"))
  log:setLogLevel(Properties["Log Level"])
  log:setLogMode(Properties["Log Mode"])
end

function OnDriverLateInit()
  if not CheckMinimumVersion("Driver Status") then
    return
  end
  local cached = persist:get(IDENTITY_PERSIST)
  if type(cached) == "table" and cached.id ~= nil then
    gIdentity = cached
  end
  for _, e in ipairs(EVENTS) do
    pcall(function()
      C4:AddEvent(e[1], e[2], e[3])
    end)
  end
  for _, v in ipairs(VARIABLES) do
    pcall(function()
      C4:AddVariable(v[1], v[2], v[3], true)
    end)
  end
  for p, _ in pairs(Properties) do
    pcall(OnPropertyChanged, p)
  end
  gInitialized = true
  UpdateProperty("Driver Status", "Online")
  pcall(function()
    UpdateProperty("Driver Version", tostring(C4:GetDriverConfigInfo("version")))
  end)
  updateStatusProperties()
  requestIdentity()
  armIdentityRetry()
end

function OnDriverDestroyed()
  CancelTimer(IDENTITY_RETRY_TIMER)
  CancelTimer(RESTORE_TIMER)
end

OBC[GATEWAY_BINDING] = function(_, _, bIsBound)
  if bIsBound then
    requestIdentity()
  else
    gDeviceState = "UNKNOWN"
    updateStatusProperties()
  end
end

function RFP.PROTECT_DEVICE(_, _, tParams)
  tParams = tParams or {}
  gIdentity = { id = tostring(tParams.id or ""), name = tostring(tParams.name or "Viewport") }
  gDeviceState = tostring(tParams.state or "UNKNOWN")
  persist:set(IDENTITY_PERSIST, gIdentity)
  UpdateProperty("Gateway Link", string.format("OK - identified as '%s' at %s", gIdentity.name, os.date("%H:%M:%S")))
  updateStatusProperties()
  autoNameDevices(gIdentity.name)
  applyViewerState(tParams)
end

function RFP.PROTECT_STATE(_, _, tParams)
  tParams = tParams or {}
  if gIdentity == nil then
    requestIdentity()
  end
  local newState = tostring(tParams.state or "UNKNOWN")
  if newState ~= gDeviceState then
    local previous = gDeviceState
    gDeviceState = newState
    if previous ~= "UNKNOWN" then
      fireEvent(newState == "CONNECTED" and "Viewport Online" or "Viewport Offline")
    end
  end
  updateStatusProperties()
  applyViewerState(tParams)
end

function RFP.PROTECT_CONTROL_RESULT(_, _, tParams)
  tParams = tParams or {}
  local op = tostring(tParams.op or "")
  if tostring(tParams.ok or "") == "true" then
    UpdateProperty("Last Control", op .. ": ok " .. os.date("%H:%M:%S"))
  else
    log:warn("Control %s failed: %s", op, tostring(tParams.reason or "unknown"))
    UpdateProperty("Last Control", op .. ": FAILED - " .. tostring(tParams.reason or "unknown"))
  end
end

EC.PROTECT_DEVICE = function(tParams)
  RFP.PROTECT_DEVICE(nil, nil, tParams)
end
EC.PROTECT_STATE = function(tParams)
  RFP.PROTECT_STATE(nil, nil, tParams)
end
EC.PROTECT_CONTROL_RESULT = function(tParams)
  RFP.PROTECT_CONTROL_RESULT(nil, nil, tParams)
end

function TC.VIEWPORT_ONLINE()
  return gDeviceState == "CONNECTED"
end

local function setView(nameOrId)
  UpdateProperty("Last Control", "viewer_liveview: sent " .. os.date("%H:%M:%S"))
  askGateway("PROTECT_CONTROL", { op = "viewer_liveview", liveview = tostring(nameOrId or "") })
end

function EC.SET_LIVE_VIEW(tParams)
  local wanted = tostring((tParams or {}).View or "")
  if wanted == "" then
    log:warn("Set Live View: View required (see Available Views)")
    return
  end
  CancelTimer(RESTORE_TIMER)
  gRestoreTo = nil
  setView(wanted)
end

--- Steps through the live view list relative to the current one.
local function stepView(direction)
  if #gLiveviews == 0 then
    log:warn("No live views known yet - is the viewport bound and the Gateway synced?")
    return
  end
  local index = 1
  for i, lv in ipairs(gLiveviews) do
    if lv.id == gCurrentLiveview then
      index = i
      break
    end
  end
  index = index + direction
  if index < 1 then
    index = #gLiveviews
  elseif index > #gLiveviews then
    index = 1
  end
  CancelTimer(RESTORE_TIMER)
  gRestoreTo = nil
  setView(gLiveviews[index].id)
end

function EC.NEXT_LIVE_VIEW()
  stepView(1)
end

function EC.PREVIOUS_LIVE_VIEW()
  stepView(-1)
end

--- The doorbell move: show VIEW for SECONDS, then put back whatever was up.
--- The restore target is captured ONCE — a second temporary show during the
--- window keeps the original restore target, so overlapping doorbell rings
--- cannot leave the TV stuck on a doorbell view.
function EC.SHOW_VIEW_TEMPORARILY(tParams)
  tParams = tParams or {}
  local wanted = tostring(tParams.View or "")
  if wanted == "" then
    log:warn("Show View Temporarily: View required")
    return
  end
  local seconds = tonumber(tParams.Seconds) or 20
  if gRestoreTo == nil and gCurrentLiveview ~= "" then
    gRestoreTo = gCurrentLiveview
  end
  setView(wanted)
  CancelTimer(RESTORE_TIMER)
  SetTimer(RESTORE_TIMER, seconds * ONE_SECOND, function()
    if gRestoreTo ~= nil then
      log:info("Restoring live view %s", liveviewName(gRestoreTo))
      setView(gRestoreTo)
      gRestoreTo = nil
    end
  end)
end

EC.Set_Live_View = EC.SET_LIVE_VIEW
EC.Next_Live_View = EC.NEXT_LIVE_VIEW
EC.Previous_Live_View = EC.PREVIOUS_LIVE_VIEW
EC.Show_View_Temporarily = EC.SHOW_VIEW_TEMPORARILY

function EC.REFRESH_VIEWPORT_INFO()
  requestIdentity()
end

function EC.PRINT_DIAGNOSTICS()
  log:print("== UniFi Protect Viewport (SBOS) diagnostics ==")
  log:print("  gateway device: %s", tostring(findGatewayDeviceId() or "NOT FOUND"))
  log:print("  identity: %s", gIdentity ~= nil and string.format("'%s' (%s)", gIdentity.name, gIdentity.id) or "none")
  log:print("  state: %s | current view: %s", gDeviceState, liveviewName(gCurrentLiveview))
  for _, lv in ipairs(gLiveviews) do
    log:print("  view: %s (%s)", lv.name, lv.id)
  end
end

function EC.FORGET_VIEWPORT()
  gIdentity = nil
  gDeviceState = "UNKNOWN"
  gLiveviews = {}
  gCurrentLiveview = ""
  gRestoreTo = nil
  CancelTimer(RESTORE_TIMER)
  persist:delete(IDENTITY_PERSIST)
  persist:delete(AUTONAME_PERSIST)
  updateStatusProperties()
  requestIdentity()
end

function OPC.Log_Mode(propertyValue)
  log:setLogMode(propertyValue)
end

function OPC.Log_Level(propertyValue)
  log:setLogLevel(propertyValue)
end
