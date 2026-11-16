--[[==========================================================================
  SmartBuildOS MQTT Motion
  One motion or occupancy sensor fed by one topic of an MQTT broker, as a
  native Control4 motion sensor on the `motionsensor` proxy. Add it next to a
  SmartBuildOS MQTT Broker; this driver chooses the topic, the JSON field
  (dotted paths work) and how its values map to motion and no motion.

  Licensing: runs under the Broker's licence (suite convention).
  Hardware validation: none yet - see the documentation tab.
============================================================================]]

--#ifdef DRIVERCENTRAL
DC_PID = 0
DC_X = nil
DC_FILENAME = "smartbuildos-mqtt-motion.c4z"
--#else
DRIVER_GITHUB_REPO = "michelo76/control4-smartbuildos"
DRIVER_FILENAMES = { "smartbuildos-mqtt-motion.c4z" }
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
local EVENT_MOTION, EVENT_CLEAR = base.FIRST_KIND_EVENT, base.FIRST_KIND_EVENT + 1

-- Proxy vocabulary: unverified on a controller (see the documentation tab).
local NOTIFY_MOTION, NOTIFY_CLEAR = "MOTION", "NO_MOTION"

local gMotion = nil

local function reportToProxy()
  if gMotion ~= nil then
    SendToProxy(PROXY, gMotion and NOTIFY_MOTION or NOTIFY_CLEAR, {}, "NOTIFY")
  end
end

base.install({
  kind = "motion",
  logName = "MqttMotion",
  events = {
    { EVENT_MOTION, "Motion Detected", "The sensor reported motion or occupancy" },
    { EVENT_CLEAR, "Motion Cleared", "The sensor reported no motion" },
  },
  topics = function()
    return base.prop("State Topic"), base.prop("Availability Topic")
  end,
  onState = function(payload)
    local field = base.prop("State Field")
    local value = Payload.extract(payload, field)
    if value == nil then
      return false,
        field ~= "" and ("no '" .. field .. "' in this message") or "payload is not a single value; set State Field"
    end
    local active = Payload.toActive(value, {
      active = Payload.parseValueList(Properties["Active Values"]),
      inactive = Payload.parseValueList(Properties["Inactive Values"]),
      invert = base.flag("Invert"),
    })
    if active == nil then
      return false, "'" .. tostring(value) .. "' is not a value I can map; fill in Active Values and Inactive Values"
    end
    local changed = gMotion ~= nil and gMotion ~= active
    gMotion = active
    reportToProxy()
    if changed then
      pcall(function()
        C4:FireEventByID(active and EVENT_MOTION or EVENT_CLEAR)
      end)
    end
    return true
  end,
  describe = function()
    if gMotion == nil then
      return "unknown"
    end
    return gMotion and "Motion" or "No motion"
  end,
})

TC.MOTION_ACTIVE = function()
  return gMotion == true
end

function RFP.GET_STATE(idBinding)
  if idBinding == PROXY then
    reportToProxy()
  end
end
