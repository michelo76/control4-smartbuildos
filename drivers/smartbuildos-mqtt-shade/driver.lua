--[[==========================================================================
  SmartBuildOS MQTT Shade
  One MQTT shade, blind or cover as a native Control4 blind. Position comes
  from one topic of the broker (a percentage, 100 = open); open, close, stop
  and "go to" publish payloads to the Set Topic. The proxy shows only what
  the shade reports on its state topic.

  Licensing: runs under the Broker's licence (suite convention).
  Hardware validation: none yet - see the documentation tab.
============================================================================]]

--#ifdef DRIVERCENTRAL
DC_PID = 0
DC_X = nil
DC_FILENAME = "smartbuildos-mqtt-shade.c4z"
--#else
DRIVER_GITHUB_REPO = "michelo76/control4-smartbuildos"
DRIVER_FILENAMES = { "smartbuildos-mqtt-shade.c4z" }
--#endif

require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")
JSON = require("JSON")
local Payload = require("mqtt.payload")
local base = require("mqtt.childdriver")

gInitialized = false

-- The blind proxy vocabulary (SET_LEVEL_TARGET / OPEN / CLOSE / STOP in,
-- STOPPED with LEVEL out) is the one the System Link shade and the Bond shade
-- drivers use.
local PROXY = 5001
local EVENT_OPEN, EVENT_CLOSED = base.FIRST_KIND_EVENT, base.FIRST_KIND_EVENT + 1

local gLevel = nil

local function invert()
  return base.flag("Invert Position")
end

base.install({
  kind = "shade",
  logName = "MqttShade",
  events = {
    { EVENT_OPEN, "Shade Fully Open", "The shade reported 100 percent open" },
    { EVENT_CLOSED, "Shade Fully Closed", "The shade reported 0 percent open" },
  },
  topics = function()
    return base.prop("State Topic"), base.prop("Availability Topic")
  end,
  onLateInit = function()
    SendToProxy(PROXY, "SET_HAS_LEVEL", { HAS_LEVEL = "true", LEVEL_OPEN = 100, LEVEL_CLOSED = 0 }, "NOTIFY")
    SendToProxy(PROXY, "SET_CAN_STOP", { CAN_STOP = "true" }, "NOTIFY")
  end,
  onState = function(payload)
    local field = base.prop("Position Field")
    local level = Payload.toPercent(Payload.extract(payload, field), 0, 100, invert())
    if level == nil then
      return false, "no number in '" .. field .. "' in this message"
    end
    local was = gLevel
    gLevel = level
    SendToProxy(PROXY, "STOPPED", { LEVEL = level }, "NOTIFY")
    if was ~= level then
      if level == 100 then
        pcall(function()
          C4:FireEventByID(EVENT_OPEN)
        end)
      elseif level == 0 then
        pcall(function()
          C4:FireEventByID(EVENT_CLOSED)
        end)
      end
    end
    return true
  end,
  describe = function()
    if gLevel == nil then
      return "unknown"
    end
    return gLevel .. "% open"
  end,
})

local function setTopic()
  return base.prop("Set Topic")
end

local function sendLevel(level)
  level = math.max(0, math.min(100, tonumber(level) or 0))
  local text = Payload.render(Properties["Position Payload"], {
    position = Payload.fromPercent(level, 0, 100, invert()),
    percent = level,
  })
  return base.publish(setTopic(), text)
end

function RFP.SET_LEVEL_TARGET(idBinding, _, tParams)
  if idBinding ~= PROXY then
    return
  end
  local level = tonumber((tParams or {}).LEVEL_TARGET or (tParams or {}).LEVEL)
  if level then
    sendLevel(level)
  end
end
function RFP.SET_LEVEL(idBinding, _, tParams)
  return RFP.SET_LEVEL_TARGET(idBinding, nil, tParams)
end
function RFP.OPEN(idBinding)
  if idBinding == PROXY then
    base.publish(setTopic(), Properties["Open Payload"])
  end
end
function RFP.CLOSE(idBinding)
  if idBinding == PROXY then
    base.publish(setTopic(), Properties["Close Payload"])
  end
end
function RFP.STOP(idBinding)
  if idBinding == PROXY then
    base.publish(setTopic(), Properties["Stop Payload"])
  end
end
function RFP.TOGGLE(idBinding)
  if idBinding == PROXY then
    if (gLevel or 0) > 50 then
      RFP.CLOSE(idBinding)
    else
      RFP.OPEN(idBinding)
    end
  end
end

-- Bench actions: one click each, the same path the proxy uses.
function EC.TEST_OPEN()
  RFP.OPEN(PROXY)
end
function EC.TEST_CLOSE()
  RFP.CLOSE(PROXY)
end
function EC.TEST_STOP()
  RFP.STOP(PROXY)
end
function EC.TEST_HALF()
  sendLevel(50)
end

TC.SHADE_OPEN = function()
  return (gLevel or 0) > 0
end
