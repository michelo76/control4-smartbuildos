--[[==========================================================================
  SmartBuildOS System Link — Light companion
  Presents ONE light export of the linked project as a native Control4
  light_v2 light. State arrives from the System Link bridge on this controller;
  control requests go back through it to the owner, who executes them on
  the real device. The proxy only ever shows CONFIRMED state from the owner;
  a request is shown separately as Requested State until feedback arrives.
  Licensing: inherits the bridge's pair licence (suite convention).
  Hardware validation: none yet — see the documentation tab.
============================================================================]]

--#ifdef DRIVERCENTRAL
DC_PID = 0
DC_X = nil
DC_FILENAME = "smartbuildos-system-link-light.c4z"
--#else
DRIVER_GITHUB_REPO = "michelo76/control4-smartbuildos"
DRIVER_FILENAMES = { "smartbuildos-system-link-light.c4z" }
--#endif

require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")
JSON = require("JSON")
local base = require("systemlink.companiondriver")

gInitialized = false

local PROXY = 5001
local gOn, gLevel = nil, nil

base.install({
  kind = "light",
  logName = "SystemLinkLight",
  applyState = function(fields, fresh)
    local on = fields.On
    local level = fields.Level
    if on == JSON.null then
      on = nil
    end
    if level == JSON.null then
      level = nil
    end
    if fresh ~= "current" then
      SendToProxy(PROXY, "ONLINE_CHANGED", { STATE = "FALSE" }, "NOTIFY")
      return
    end
    SendToProxy(PROXY, "ONLINE_CHANGED", { STATE = "TRUE" }, "NOTIFY")
    if on ~= nil and gOn ~= nil and gOn ~= on then
      pcall(function()
        C4:FireEventByID(on and 4 or 5)
      end)
    end
    if on ~= nil then
      gOn = on
    end
    if level ~= nil then
      gLevel = tonumber(level)
    end
    local shown = (gOn == false) and 0 or (gLevel or (gOn and 100 or 0))
    -- LIGHT_BRIGHTNESS_CHANGED is the documented Light V2 notify for dimmers
    -- (3.3.0 guidance); LIGHT_LEVEL is what Control4's own hook sends. Both
    -- are sent so either proxy generation renders the confirmed level.
    SendToProxy(PROXY, "LIGHT_BRIGHTNESS_CHANGED", { LIGHT_BRIGHTNESS_CURRENT = shown }, "NOTIFY")
    SendToProxy(PROXY, "LIGHT_LEVEL", { LEVEL = shown }, "NOTIFY")
  end,
  describeState = function(fields)
    local on, level = fields.On, fields.Level
    if on == JSON.null then
      on = nil
    end
    if level == JSON.null then
      level = nil
    end
    if on == nil and level == nil then
      return "unavailable"
    end
    return (on and "On" or "Off") .. (level ~= nil and (" " .. tostring(level) .. "%") or "")
  end,
})

local function setLevel(level, time)
  level = tonumber(level) or 0
  if level <= 0 then
    base.control("off", {}, "Off")
  else
    base.control("set_level", { level = math.min(level, 100), time_ms = tonumber(time) or 0 }, tostring(level) .. "%")
  end
end

function RFP.SET_BRIGHTNESS_TARGET(idBinding, _, tParams)
  if idBinding ~= PROXY then
    return
  end
  tParams = tParams or {}
  setLevel(tParams.LIGHT_BRIGHTNESS_TARGET or tParams.LEVEL, tParams.RATE or tParams.TIME)
end
function RFP.RAMP_TO_LEVEL(idBinding, _, tParams)
  return RFP.SET_BRIGHTNESS_TARGET(idBinding, nil, tParams)
end
function RFP.SET_LEVEL(idBinding, _, tParams)
  return RFP.SET_BRIGHTNESS_TARGET(idBinding, nil, tParams)
end
function RFP.ON(idBinding)
  if idBinding == PROXY then
    base.control("on", {}, "On")
  end
end
function RFP.OFF(idBinding)
  if idBinding == PROXY then
    base.control("off", {}, "Off")
  end
end
function RFP.TOGGLE(idBinding)
  if idBinding == PROXY then
    if gOn then
      base.control("off", {}, "Off")
    else
      base.control("on", {}, "On")
    end
  end
end
function RFP.GET_CONNECTED_STATE(idBinding)
  if idBinding == PROXY then
    SendToProxy(PROXY, "ONLINE_CHANGED", { STATE = base.isCurrent() and "TRUE" or "FALSE" }, "NOTIFY")
  end
end
function RFP.DO_PUSH() end
function RFP.DO_RELEASE() end
function RFP.DO_CLICK(idBinding)
  if idBinding == PROXY then
    RFP.TOGGLE(idBinding)
  end
end
