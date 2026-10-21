--[[==========================================================================
  SmartBuildOS System Link — Fan companion
  Presents ONE fan export of the linked project as variables, events and
  a conditional on this controller (no proxy in this release). Every value
  shown is the owner's CONFIRMED state. Control requests go to the owner,
  who refuses them unless the pair licence carries the FAN feature
  (SL-07): nothing unverified can actuate.
  Licensing: inherits the bridge's pair licence (suite convention).
  Hardware validation: none yet — see the documentation tab.
============================================================================]]

--#ifdef DRIVERCENTRAL
DC_PID = 0
DC_X = nil
DC_FILENAME = "smartbuildos-system-link-fan.c4z"
--#else
DRIVER_GITHUB_REPO = "michelo76/control4-smartbuildos"
DRIVER_FILENAMES = { "smartbuildos-system-link-fan.c4z" }
--#endif

require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")
JSON = require("JSON")
local base = require("systemlink.companiondriver")

gInitialized = false

local EVENT_ON, EVENT_OFF = 4, 5
local VARS = { { "Speed", "NUMBER", "0" }, { "On", "BOOL", "0" } }
local gOn = nil

local function clean(v)
  if v == JSON.null then
    return nil
  end
  return v
end

base.install({
  kind = "fan",
  logName = "SystemLinkFan",
  onLateInit = function()
    for _, v in ipairs(VARS) do
      pcall(function()
        C4:AddVariable(v[1], v[3], v[2], true, false)
      end)
    end
  end,
  applyState = function(fields, fresh)
    local speed = clean(fields.Speed)
    pcall(function()
      C4:SetVariable("Speed", tostring(speed or 0))
      C4:SetVariable("On", (speed or 0) > 0 and "1" or "0")
    end)
    if fresh ~= "current" or speed == nil then
      return
    end
    local on = speed > 0
    if gOn ~= nil and gOn ~= on then
      pcall(function()
        C4:FireEventByID(on and EVENT_ON or EVENT_OFF)
      end)
    end
    gOn = on
  end,
  describeState = function(fields)
    local v = clean(fields.Speed)
    if v == nil then
      return "unavailable"
    end
    return v > 0 and ("Speed " .. tostring(v)) or "Off"
  end,
})

TC.FAN_ON = function()
  return gOn == true
end

-- Bench actions: one click each, the same control path programming uses.
function EC.TEST_ON()
  base.control("on", {}, "On")
end
function EC.TEST_OFF()
  base.control("off", {}, "Off")
end
function EC.TEST_SPEED_5()
  base.control("set_speed", { speed = 5 }, "speed 5")
end
