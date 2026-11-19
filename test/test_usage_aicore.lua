-- Usage Analytics reports to AI Core (sbos.aireport, ATTACH mode: the
-- driver's own module client carries the reports; brief D7a).
--
-- The real driver.lua under the shim (set up as test_usage_driver.lua
-- does), the REAL Agent registry and bus and a fake AI Core answering
-- through AI Core's REAL validator (test/aicore_reporter_harness.lua); the
-- shared lifecycle checks are test/aicore_rollout_checks.lua.
-- Driver-specific: ONE registration (the driver's own), describe, the
-- meter's health and coverage (never the hours or presses), the degraded /
-- restored diagnostics, the driver's own client unregisters on destroy.
-- Run from the driver root: make test

C4 = C4 or {}
require("c4_shim")
JSON = require("JSON")
local R = require("aicore_rollout_checks")
local H = require("aicore_reporter_harness")
local check = R.check

-- ── timers (a manual clock, as the driver's own test) ───────────────────────
local clock = { now = 0, timers = {} }
package.preload["drivers-common-public.global.timer"] = function()
  ONE_SECOND = 1000
  ONE_MINUTE = 60000
  ONE_HOUR = 3600000
  function SetTimer(id, ms, cb, repeating)
    clock.timers[id] = { at = clock.now + ms, cb = cb, every = repeating and ms or nil }
  end
  function CancelTimer(id)
    if type(id) == "string" then
      clock.timers[id] = nil
    end
  end
  function KillAllTimers()
    clock.timers = {}
  end
  return true
end
local function advance(ms)
  local target = clock.now + ms
  while true do
    local bestId, bestAt
    for id, t in pairs(clock.timers) do
      if
        t.at <= target and (bestAt == nil or t.at < bestAt or (t.at == bestAt and tostring(id) < tostring(bestId)))
      then
        bestId, bestAt = id, t.at
      end
    end
    if not bestId then
      break
    end
    clock.now = bestAt
    local t = clock.timers[bestId]
    if t.every then
      t.at = clock.now + t.every
    else
      clock.timers[bestId] = nil
    end
    t.cb()
  end
  clock.now = target
end
local realTime = os.time
local base = 1800000000
os.time = function(t)
  if t then
    return realTime(t)
  end
  return base + math.floor(clock.now / 1000)
end
package.preload["drivers-common-public.global.url"] = function()
  return true
end
package.preload["cloud-client-byte"] = function()
  return true
end
local persisted = {}
package.preload["lib.persist"] = function()
  local P = {}
  local EMPTY = {}
  function P:get(key, default)
    if default == nil then
      default = EMPTY
    end
    if persisted[key] == nil then
      return default
    end
    return persisted[key]
  end
  function P:set(key, value)
    persisted[key] = value
  end
  function P:delete(key)
    persisted[key] = nil
  end
  function P:reset() end
  return P
end

local SELF = 12345
C4.GetDeviceID = function()
  return SELF
end
C4.FireEventByID = function() end
C4.FireEvent = function() end
C4.SetVariable = function() end
C4.AddVariable = function() end
C4.AddEvent = function() end
C4.GetVersionInfo = function()
  return { version = "4.2.0.0" }
end
C4.UpdateProperty = function() end

package.preload["tracer.catalog_data"] = function()
  return { ["keypad.c4z"] = { [1] = "Top Button Pushed" } }
end
local devices = {
  [3] = { deviceName = "Kitchen", driverFileName = "roomdevice.c4i", roomId = 3, roomName = "Kitchen" },
  [12] = { deviceName = "Kitchen Pendants", driverFileName = "light_v2.c4i", roomId = 3, roomName = "Kitchen" },
  [40] = { deviceName = "Hall Keypad", driverFileName = "keypad.c4z", roomId = 3, roomName = "Kitchen" },
  [SELF] = {
    deviceName = "Usage Analytics",
    driverFileName = "smartbuildos-usage-analytics.c4z",
    roomId = 3,
    roomName = "Kitchen",
  },
}
local variables = {
  [3] = {
    ["1000"] = { name = "CURRENT_SELECTED_DEVICE", value = "0" },
    ["1005"] = { name = "POWER_STATE", value = "False" },
  },
  [12] = { ["1001"] = { name = "LIGHT_LEVEL", value = "0" }, ["1002"] = { name = "LIGHT_STATE", value = "False" } },
}
C4.GetDevices = function()
  return devices
end
C4.GetDeviceVariables = function(_, id)
  return variables[tonumber(id)]
end
C4.GetDeviceDisplayName = function(_, id)
  local d = devices[tonumber(id)]
  return d and d.deviceName or nil
end
C4.GetDriverConfigInfo = function(_, key)
  if key == "minimum_os_version" then
    return "3.3.2"
  elseif key == "name" then
    return "SmartBuildOS Usage Analytics"
  end
  return "20261118.000001"
end
C4.RegisterVariableListener = function() end
C4.UnregisterVariableListener = function() end
C4.RegisterDeviceEvent = function() end
C4.UnregisterDeviceEvent = function() end

R.loadProperties("smartbuildos-usage-analytics")
R.watchPaints()
H.install({ selfId = SELF, file = "smartbuildos-usage-analytics.c4z" })
dofile("drivers/smartbuildos-usage-analytics/driver.lua")

R.lifecycle({
  H = H,
  moduleId = "usage_analytics",
  file = "smartbuildos-usage-analytics.c4z",
  sku = "SBOS_USAGE_ANALYTICS",
  mode = "attach",
  activity = function()
    OnWatchedVariableChanged(12, 1002, "True")
    advance(30 * 60000)
    OnWatchedVariableChanged(12, 1002, "False")
    OnDeviceEvent(40, 1)
    advance(61000)
  end,
  describe = function(d)
    check(
      "ONE registration: the driver's own client",
      H.count("SBOS_MODULE_REGISTER") == 1,
      H.count("SBOS_MODULE_REGISTER")
    )
    check(
      "describe: the usage meter (class other)",
      #d.controls == 1 and d.controls[1].id == "usage_meter" and d.controls[1].class == "other"
    )
    check("describe: no query declared", #d.queries == 0)
  end,
  state = function(facts)
    check(
      "state: measuring, coverage counts",
      type(facts.measuring_status) == "string"
        and facts.lights_watched == 1
        and facts.keypads_watched == 1
        and type(facts.rooms_watched) == "number"
        and facts.listeners >= 2
        and type(facts.days_recorded) == "number",
      JSON:encode(facts)
    )
    check("state: no hours or presses", facts.media_hours == nil and facts.light_hours == nil and facts.presses == nil)
  end,
  forbid = { "Kitchen", "Pendants", "Hall Keypad", " h, ", "press(es)" }, -- " h, ": the Today line
})

print("[5] the degraded / restored diagnostics")
OnDriverInit()
OnDriverLateInit()
H.aiRegister()
H.pushDirectory()
EC.SBOS_ENTITLEMENT({
  sku = "SBOS_USAGE_ANALYTICS",
  status = "NOT_ENTITLED",
  registered = "true",
  enforcement = "enforce",
})
local dg = H.reports("diagnostic")
local last = dg[#dg] and dg[#dg].args
check(
  "unlicensed: meter.degraded (warning), as the driver's own Measuring Degraded",
  last ~= nil and last.code == "meter.degraded" and last.severity == "warning",
  last and JSON:encode(last)
)
check("every report valid for AI Core", H.allValid(), select(2, H.allValid()))

R.finish()
