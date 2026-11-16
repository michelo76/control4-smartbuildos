--[[==========================================================================
  SmartBuildOS MQTT Contact
  One contact sensor (door, window, water leak, anything that is "active" or
  not) fed by one topic of an MQTT broker, as a native Control4 contact
  sensor on the `contactsingle` proxy. Add it next to a SmartBuildOS MQTT
  Broker; the broker connects, this driver chooses the topic and the JSON
  field (dotted paths work) and how its values map to open and closed.

  Licensing: runs under the Broker's licence (suite convention).
  Hardware validation: none yet - see the documentation tab.
============================================================================]]

--#ifdef DRIVERCENTRAL
DC_PID = 0
DC_X = nil
DC_FILENAME = "smartbuildos-mqtt-contact.c4z"
--#else
DRIVER_GITHUB_REPO = "michelo76/control4-smartbuildos"
DRIVER_FILENAMES = { "smartbuildos-mqtt-contact.c4z" }
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
local EVENT_OPENED, EVENT_CLOSED = base.FIRST_KIND_EVENT, base.FIRST_KIND_EVENT + 1

local gOpen = nil

local function reportToProxy()
  if gOpen ~= nil then
    SendToProxy(PROXY, gOpen and "OPENED" or "CLOSED", {}, "NOTIFY")
  end
end

base.install({
  kind = "contact",
  logName = "MqttContact",
  events = {
    { EVENT_OPENED, "Contact Opened", "The sensor reported open" },
    { EVENT_CLOSED, "Contact Closed", "The sensor reported closed" },
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
    -- "Active" reports as Opened or Closed, whichever the property says.
    local open = active
    if base.prop("Report Active As") == "Closed" then
      open = not active
    end
    local changed = gOpen ~= nil and gOpen ~= open
    gOpen = open
    reportToProxy()
    if changed then
      pcall(function()
        C4:FireEventByID(open and EVENT_OPENED or EVENT_CLOSED)
      end)
    end
    return true
  end,
  describe = function()
    if gOpen == nil then
      return "unknown"
    end
    return gOpen and "Open" or "Closed"
  end,
})

TC.CONTACT_OPEN = function()
  return gOpen == true
end

function RFP.GET_STATE(idBinding)
  if idBinding == PROXY and gOpen ~= nil then
    SendToProxy(PROXY, gOpen and "STATE_OPENED" or "STATE_CLOSED", {}, "NOTIFY")
  end
end
