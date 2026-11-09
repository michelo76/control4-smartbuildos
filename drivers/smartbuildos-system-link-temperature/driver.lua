--[[==========================================================================
  SmartBuildOS System Link — Temperature companion
  Presents ONE temperature export of the linked project as a native Control4
  TEMPERATURE_VALUE connection. State arrives from the System Link bridge on this controller;
  control requests go back through it to the owner, who executes them on
  the real device. The proxy only ever shows CONFIRMED state from the owner;
  a request is shown separately as Requested State until feedback arrives.
  Licensing: inherits the bridge's pair licence (suite convention).
  Hardware validation: none yet — see the documentation tab.
============================================================================]]

--#ifdef DRIVERCENTRAL
DC_PID = 0
DC_X = nil
DC_FILENAME = "smartbuildos-system-link-temperature.c4z"
--#else
DRIVER_GITHUB_REPO = "michelo76/control4-smartbuildos"
DRIVER_FILENAMES = { "smartbuildos-system-link-temperature.c4z" }
--#endif

require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")
JSON = require("JSON")
local base = require("systemlink.companiondriver")

gInitialized = false

local TEMP_BINDING = 100

base.install({
  kind = "temperature",
  logName = "SystemLinkTemperature",
  applyState = function(fields, fresh)
    local f = fields.Fahrenheit
    local c = fields.Celsius
    if f == JSON.null then
      f = nil
    end
    if c == JSON.null then
      c = nil
    end
    f, c = tonumber(f), tonumber(c)
    if fresh ~= "current" or (f == nil and c == nil) then
      -- Bond weather vocabulary: VALUE_UNAVAILABLE when there is no reading.
      SendToProxy(TEMP_BINDING, "VALUE_UNAVAILABLE", { STATUS = fresh }, "NOTIFY")
      return
    end
    if f == nil then
      f = c * 9 / 5 + 32
    end
    if c == nil then
      c = (f - 32) * 5 / 9
    end
    -- c4hook_temperature_sensor vocabulary.
    SendToProxy(
      TEMP_BINDING,
      "VALUE_CHANGED",
      { CELSIUS = string.format("%.1f", c), FAHRENHEIT = string.format("%.1f", f), TIMESTAMP = os.time() },
      "NOTIFY"
    )
  end,
  describeState = function(fields)
    local f = fields.Fahrenheit
    if f == JSON.null or f == nil then
      local c = fields.Celsius
      if c == JSON.null or c == nil then
        return "unavailable"
      end
      return string.format("%.1f °C", tonumber(c))
    end
    return string.format("%.1f °F", tonumber(f))
  end,
})
