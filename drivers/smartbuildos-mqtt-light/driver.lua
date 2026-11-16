--[[==========================================================================
  SmartBuildOS MQTT Light
  One MQTT light as a native Control4 light_v2 light. State comes from one
  topic of the broker (JSON fields for on/off and brightness); a tap in
  Navigator or a line of programming publishes a payload to the Set Topic.
  The proxy shows only what the light reports on its state topic: a command
  is a request, the state topic is the answer.

  Licensing: runs under the Broker's licence (suite convention).
  Hardware validation: none yet - see the documentation tab.
============================================================================]]

--#ifdef DRIVERCENTRAL
DC_PID = 0
DC_X = nil
DC_FILENAME = "smartbuildos-mqtt-light.c4z"
--#else
DRIVER_GITHUB_REPO = "michelo76/control4-smartbuildos"
DRIVER_FILENAMES = { "smartbuildos-mqtt-light.c4z" }
--#endif

require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")
JSON = require("JSON")
local Payload = require("mqtt.payload")
local base = require("mqtt.childdriver")

gInitialized = false

local PROXY = 5001
local EVENT_ON, EVENT_OFF = base.FIRST_KIND_EVENT, base.FIRST_KIND_EVENT + 1

local gOn, gLevel = nil, nil
local reportBrightness

local function levelRange()
  local min = tonumber(base.prop("Level Min")) or 0
  local max = tonumber(base.prop("Level Max")) or 254
  if max == min then
    max = min + 1
  end
  return min, max
end

--- The CONFIRMED level as the proxy should show it (off = 0).
local function shownLevel()
  return (gOn == false) and 0 or (gLevel or (gOn and 100 or 0))
end

-- The proxy vocabulary is the one the System Link light and the first-party
-- Philips Hue driver use: ONLINE_CHANGED with a boolean STATE,
-- LIGHT_BRIGHTNESS_CHANGED and LIGHT_LEVEL.
reportBrightness = function()
  local shown = shownLevel()
  SendToProxy(PROXY, "LIGHT_BRIGHTNESS_CHANGED", { LIGHT_BRIGHTNESS_CURRENT = shown }, "NOTIFY")
  SendToProxy(PROXY, "LIGHT_LEVEL", { LEVEL = shown }, "NOTIFY")
end

local function reportOnline(online)
  SendToProxy(PROXY, "ONLINE_CHANGED", { STATE = online and true or false }, "NOTIFY")
end

base.install({
  kind = "light",
  logName = "MqttLight",
  events = {
    { EVENT_ON, "Light On", "The light reported on" },
    { EVENT_OFF, "Light Off", "The light reported off" },
  },
  topics = function()
    return base.prop("State Topic"), base.prop("Availability Topic")
  end,
  onOnline = function(online)
    reportOnline(online)
    if online then
      reportBrightness()
    end
  end,
  onState = function(payload)
    local stateField, levelField = base.prop("State Field"), base.prop("Level Field")
    local on = Payload.toActive(Payload.extract(payload, stateField))
    local min, max = levelRange()
    local level = levelField ~= "" and Payload.toPercent(Payload.extract(payload, levelField), min, max) or nil
    if on == nil and level == nil then
      return false, "this message has neither '" .. stateField .. "' nor '" .. levelField .. "'"
    end
    if on == nil then
      on = level > 0
    end
    if level ~= nil and level > 0 then
      gLevel = level
    elseif on and gLevel == nil then
      gLevel = 100
    end
    local changed = gOn ~= nil and gOn ~= on
    gOn = on
    reportOnline(base.online())
    reportBrightness()
    if changed then
      pcall(function()
        C4:FireEventByID(on and EVENT_ON or EVENT_OFF)
      end)
    end
    return true
  end,
  describe = function()
    if gOn == nil then
      return "unknown"
    end
    return (gOn and "On" or "Off") .. (gOn and gLevel and (" " .. gLevel .. "%") or "")
  end,
})

-- ─── Commands out ───────────────────────────────────────────────────────────

local function setTopic()
  return base.prop("Set Topic")
end

local function sendOn()
  return base.publish(setTopic(), Properties["On Payload"])
end

local function sendOff()
  return base.publish(setTopic(), Properties["Off Payload"])
end

--- A level request: 0 is off, anything else renders the Level Payload with
--- {level} in the device's own range, {percent} 0..100 and {seconds}.
local function sendLevel(percent, rateMs)
  percent = math.max(0, math.min(100, tonumber(percent) or 0))
  if percent <= 0 then
    return sendOff()
  end
  local min, max = levelRange()
  local text = Payload.render(Properties["Level Payload"], {
    level = Payload.fromPercent(percent, min, max),
    percent = percent,
    seconds = math.floor((tonumber(rateMs) or 0) / 1000),
  })
  return base.publish(setTopic(), text)
end

function RFP.SET_BRIGHTNESS_TARGET(idBinding, _, tParams)
  if idBinding ~= PROXY then
    return
  end
  tParams = tParams or {}
  sendLevel(tParams.LIGHT_BRIGHTNESS_TARGET or tParams.LEVEL, tParams.RATE or tParams.TIME)
end
function RFP.RAMP_TO_LEVEL(idBinding, _, tParams)
  return RFP.SET_BRIGHTNESS_TARGET(idBinding, nil, tParams)
end
function RFP.SET_LEVEL(idBinding, _, tParams)
  return RFP.SET_BRIGHTNESS_TARGET(idBinding, nil, tParams)
end
function RFP.ON(idBinding)
  if idBinding == PROXY then
    sendOn()
  end
end
function RFP.OFF(idBinding)
  if idBinding == PROXY then
    sendOff()
  end
end
function RFP.TOGGLE(idBinding)
  if idBinding == PROXY then
    if gOn then
      sendOff()
    else
      sendOn()
    end
  end
end
function RFP.GET_CONNECTED_STATE(idBinding)
  if idBinding == PROXY then
    reportOnline(base.online())
  end
end
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
-- BUTTON_ID 0 top = on, 1 bottom = off, 2 = toggle).
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
-- Preset / on-mode edits from the proxy have no meaning here: accepted silently.
function RFP.UPDATE_BRIGHTNESS_PRESET() end
function RFP.UPDATE_BRIGHTNESS_ON_MODE() end
function RFP.UPDATE_COLOR_PRESET() end
function RFP.UPDATE_COLOR_ON_MODE() end

-- Bench actions: one click each, the same path the proxy uses.
function EC.TEST_ON()
  sendOn()
end
function EC.TEST_OFF()
  sendOff()
end
function EC.TEST_HALF()
  sendLevel(50, 0)
end

TC.LIGHT_ON = function()
  return gOn == true
end
