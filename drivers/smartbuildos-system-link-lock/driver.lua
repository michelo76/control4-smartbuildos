--[[==========================================================================
  SmartBuildOS System Link — Lock companion
  Presents ONE lock export of the linked project as variables, events and
  a conditional on this controller (no proxy in this release). Every value
  shown is the owner's CONFIRMED state. Control requests go to the owner,
  who refuses them unless the pair licence carries the LOCK feature
  (SL-07): nothing unverified can actuate.
  Licensing: inherits the bridge's pair licence (suite convention).
  Hardware validation: none yet — see the documentation tab.
============================================================================]]

--#ifdef DRIVERCENTRAL
DC_PID = 0
DC_X = nil
DC_FILENAME = "smartbuildos-system-link-lock.c4z"
--#else
DRIVER_GITHUB_REPO = "michelo76/control4-smartbuildos"
DRIVER_FILENAMES = { "smartbuildos-system-link-lock.c4z" }
--#endif

require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")
JSON = require("JSON")
local base = require("systemlink.companiondriver")

gInitialized = false

local EVENT_ON, EVENT_OFF = 4, 5
local VARS = { { "Locked", "BOOL", "0" } }
local gOn = nil

local function clean(v)
  if v == JSON.null then
    return nil
  end
  return v
end

base.install({
  kind = "lock",
  logName = "SystemLinkLock",
  onLateInit = function()
    for _, v in ipairs(VARS) do
      pcall(function()
        C4:AddVariable(v[1], v[3], v[2], true, false)
      end)
    end
  end,
  applyState = function(fields, fresh)
    local v = clean(fields.Locked)
    pcall(function()
      C4:SetVariable("Locked", v and "1" or "0")
    end)
    if fresh ~= "current" or v == nil then
      return
    end
    if gOn ~= nil and gOn ~= v then
      pcall(function()
        C4:FireEventByID(v and EVENT_ON or EVENT_OFF)
      end)
    end
    gOn = v
  end,
  describeState = function(fields)
    local v = clean(fields.Locked)
    if v == nil then
      return "unavailable"
    end
    return v and "Locked" or "Unlocked"
  end,
})

TC.LOCK_LOCKED = function()
  return gOn == true
end

-- Bench actions: one click each, the same control path programming uses.
function EC.TEST_LOCK()
  base.control("lock", {}, "Lock")
end
function EC.TEST_UNLOCK()
  base.control("unlock", {}, "Unlock")
end
