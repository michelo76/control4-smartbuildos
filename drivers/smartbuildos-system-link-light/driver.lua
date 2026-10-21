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
local reportBrightness

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
    -- The proxy vocabulary below is what the first-party Philips Hue driver
    -- and the hardware-tested LuminaLogic light send: ONLINE_CHANGED with a
    -- boolean STATE, LIGHT_LEVEL, LIGHT_BRIGHTNESS_CHANGED (and _CHANGING
    -- while a target is pending). Bench 2026-10-21: with string STATEs and
    -- no BUTTON_ACTION/GET_LIGHT_LEVEL, Navigator showed no slider and
    -- ignored taps.
    if fresh ~= "current" then
      SendToProxy(PROXY, "ONLINE_CHANGED", { STATE = false }, "NOTIFY")
      return
    end
    SendToProxy(PROXY, "ONLINE_CHANGED", { STATE = true }, "NOTIFY")
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
    reportBrightness()
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

--- The CONFIRMED level as the proxy should show it (off = 0).
local function shownLevel()
  return (gOn == false) and 0 or (gLevel or (gOn and 100 or 0))
end

--- Confirmed state to the proxy: the level, and the legacy LIGHT_LEVEL too
--- (the first-party Hue driver sends both).
reportBrightness = function()
  local shown = shownLevel()
  SendToProxy(PROXY, "LIGHT_BRIGHTNESS_CHANGED", { LIGHT_BRIGHTNESS_CURRENT = shown }, "NOTIFY")
  SendToProxy(PROXY, "LIGHT_LEVEL", { LEVEL = shown }, "NOTIFY")
end

--- A requested target, while the owner has not confirmed it: the proxy
--- animates toward it (LIGHT_BRIGHTNESS_CHANGING carries both); the
--- confirmed level still only moves on feedback.
local function reportChanging(target, rateMs)
  SendToProxy(
    PROXY,
    "LIGHT_BRIGHTNESS_CHANGING",
    { LIGHT_BRIGHTNESS_CURRENT = shownLevel(), LIGHT_BRIGHTNESS_TARGET = target, RATE = tonumber(rateMs) or 0 },
    "NOTIFY"
  )
end

local function setLevel(level, time)
  level = tonumber(level) or 0
  reportChanging(math.max(0, math.min(level, 100)), time)
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
    reportChanging(100, 0)
    base.control("on", {}, "On")
  end
end
function RFP.OFF(idBinding)
  if idBinding == PROXY then
    reportChanging(0, 0)
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
    SendToProxy(PROXY, "ONLINE_CHANGED", { STATE = base.isCurrent() }, "NOTIFY")
  end
end
-- The proxy asks for the level at (re)load: answer with the confirmed one.
function RFP.GET_LIGHT_LEVEL(idBinding)
  if idBinding == PROXY then
    reportBrightness()
  end
end
function RFP.DO_PUSH() end
function RFP.DO_RELEASE() end
function RFP.DO_CLICK(idBinding)
  if idBinding == PROXY then
    RFP.TOGGLE(idBinding)
  end
end
-- A Navigator tap arrives as BUTTON_ACTION on OS 3 (ACTION 2 = click;
-- BUTTON_ID 0 top = on, 1 bottom = off, 2 = toggle), the three virtual
-- buttons of a light. Same mapping as the LuminaLogic light and Hue.
function RFP.BUTTON_ACTION(idBinding, _, tParams)
  if idBinding ~= PROXY then
    return
  end
  tParams = tParams or {}
  local button, action = tonumber(tParams.BUTTON_ID), tonumber(tParams.ACTION)
  SendToProxy(PROXY, "BUTTON_ACTION", { BUTTON_ID = button, ACTION = action }, "NOTIFY")
  if action ~= 2 then
    return
  end
  if button == 0 then
    RFP.ON(idBinding)
  elseif button == 1 then
    RFP.OFF(idBinding)
  else
    RFP.TOGGLE(idBinding)
  end
end
-- Preset / on-mode edits from the proxy have no remote meaning: accepted silently.
function RFP.UPDATE_BRIGHTNESS_PRESET() end
function RFP.UPDATE_BRIGHTNESS_ON_MODE() end
function RFP.UPDATE_COLOR_PRESET() end
function RFP.UPDATE_COLOR_ON_MODE() end

-- ─── Bench actions: one click each, the same control path the proxy uses ───
-- (Composer's Actions tab, so a dealer can prove the link controls the
-- remote device without wiring programming first; bench 2026-10-20).
function EC.TEST_ON()
  base.control("on", {}, "On")
end
function EC.TEST_OFF()
  base.control("off", {}, "Off")
end
function EC.TEST_HALF()
  base.control("set_level", { level = 50, time_ms = 0 }, "50%")
end
