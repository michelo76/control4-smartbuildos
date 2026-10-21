--[[==========================================================================
  SmartBuildOS System Link — Shade companion
  Presents ONE shade export of the linked project as a native Control4
  blind shade. State arrives from the System Link bridge on this controller;
  control requests go back through it to the owner, who executes them on
  the real device. The proxy only ever shows CONFIRMED state from the owner;
  a request is shown separately as Requested State until feedback arrives.
  Licensing: inherits the bridge's pair licence (suite convention).
  Hardware validation: none yet — see the documentation tab.
============================================================================]]

--#ifdef DRIVERCENTRAL
DC_PID = 0
DC_X = nil
DC_FILENAME = "smartbuildos-system-link-shade.c4z"
--#else
DRIVER_GITHUB_REPO = "michelo76/control4-smartbuildos"
DRIVER_FILENAMES = { "smartbuildos-system-link-shade.c4z" }
--#endif

require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")
JSON = require("JSON")
local base = require("systemlink.companiondriver")

gInitialized = false

-- FEATURE-GATED (SL-07): the blind proxy vocabulary below comes from the
-- Bond shade driver and Control4's C4-Z2IO blind hook (MOVING/STOPPED,
-- SET_LEVEL_TARGET/OPEN/CLOSE/STOP), not from a cached proxy document. The
-- bridge refuses to export a shade unless the pair licence carries SHADE.
local PROXY = 5001
local gLevel, gMoving = nil, nil

base.install({
  kind = "shade",
  logName = "SystemLinkShade",
  applyState = function(fields, fresh)
    local level = fields.Level
    local moving = fields.Moving
    if level == JSON.null then
      level = nil
    end
    if moving == JSON.null then
      moving = nil
    end
    if fresh ~= "current" then
      return
    end
    level = tonumber(level)
    if level ~= nil then
      gLevel = level
    end
    if moving == true then
      gMoving = true
      SendToProxy(PROXY, "MOVING", { LEVEL_TARGET = gLevel or -1, RAMP_RATE = 0, LEVEL = gLevel or -1 }, "NOTIFY")
    elseif gLevel ~= nil then
      gMoving = false
      -- Requested versus actual: STOPPED carries the owner's confirmed level.
      SendToProxy(PROXY, "STOPPED", { LEVEL = gLevel }, "NOTIFY")
    end
  end,
  describeState = function(fields)
    local level = fields.Level
    if level == JSON.null or level == nil then
      return "unavailable"
    end
    return tostring(level) .. "% open" .. ((fields.Moving == true) and " (moving)" or "")
  end,
  onLateInit = function()
    SendToProxy(PROXY, "SET_HAS_LEVEL", { HAS_LEVEL = "true", LEVEL_OPEN = 100, LEVEL_CLOSED = 0 }, "NOTIFY")
    SendToProxy(PROXY, "SET_CAN_STOP", { CAN_STOP = "true" }, "NOTIFY")
  end,
})

function RFP.SET_LEVEL_TARGET(idBinding, _, tParams)
  if idBinding ~= PROXY then
    return
  end
  local level = tonumber((tParams or {}).LEVEL_TARGET or (tParams or {}).LEVEL)
  if level then
    base.control("set_level", { level = level }, tostring(level) .. "%")
  end
end
function RFP.SET_LEVEL(idBinding, _, tParams)
  return RFP.SET_LEVEL_TARGET(idBinding, nil, tParams)
end
function RFP.OPEN(idBinding)
  if idBinding == PROXY then
    base.control("open", {}, "Open")
  end
end
function RFP.CLOSE(idBinding)
  if idBinding == PROXY then
    base.control("close", {}, "Close")
  end
end
function RFP.STOP(idBinding)
  if idBinding == PROXY then
    base.control("stop", {}, "Stop")
  end
end
function RFP.TOGGLE(idBinding)
  if idBinding == PROXY then
    if (gLevel or 0) > 50 then
      base.control("close", {}, "Close")
    else
      base.control("open", {}, "Open")
    end
  end
end

-- ─── Bench actions: one click each, the same control path the proxy uses ───
-- (Composer's Actions tab, so a dealer can prove the link controls the
-- remote device without wiring programming first; bench 2026-10-20).
function EC.TEST_OPEN()
  base.control("open", {}, "Open")
end
function EC.TEST_CLOSE()
  base.control("close", {}, "Close")
end
function EC.TEST_STOP()
  base.control("stop", {}, "Stop")
end
function EC.TEST_HALF()
  base.control("set_level", { level = 50 }, "50%")
end
