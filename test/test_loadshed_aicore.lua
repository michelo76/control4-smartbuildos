-- Load Shedding reports to AI Core (sbos.aireport, START mode; brief D7a).
--
-- The real driver.lua under the shim (set up as test_loadshed_driver.lua
-- does), the REAL Agent registry and bus and a fake AI Core answering
-- through AI Core's REAL validator (test/aicore_reporter_harness.lua); the
-- shared lifecycle checks are test/aicore_rollout_checks.lua.
-- Driver-specific: describe (class power), the shed state during an
-- outage, the load-command diagnostic.
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
      if t.at <= target and (bestAt == nil or t.at < bestAt or (t.at == bestAt and tostring(id) < tostring(bestId))) then
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

local devVars = {
  [101] = { [10] = { name = "STATE", value = "1" } }, -- relay, closed
}
C4.GetDevices = function()
  return {
    [SELF] = { deviceName = "Load Shedding", driverFileName = "smartbuildos-load-shedding.c4z" },
    [101] = { deviceName = "Pool Pump", roomName = "Yard", driverFileName = "x.c4z" },
  }
end
C4.GetDeviceVariables = function(_, id)
  return devVars[id] or {}
end
C4.GetDriverConfigInfo = function(_, key)
  if key == "minimum_os_version" then
    return "3.3.2"
  elseif key == "name" then
    return "SmartBuildOS Load Shedding"
  end
  return "20261118.000001"
end
C4.UpdatePropertyList = function() end
C4.RegisterVariableListener = function() end
C4.UnregisterVariableListener = function() end

R.loadProperties("smartbuildos-load-shedding")
Properties["Load 1 Device"] = "Pool Pump (Yard) · 101"
Properties["Load 1 Kind"] = "Relay"
Properties["Load 1 Tier"] = "1"
R.watchPaints()
H.install({ selfId = SELF, file = "smartbuildos-load-shedding.c4z" })
-- A load command can be made to fail (the engine's send is pcall'd).
local failLoad = false
local harnessSend = C4.SendToDevice
C4.SendToDevice = function(self, id, command, params)
  if tonumber(id) == 101 then
    if failLoad then
      error("device gone")
    end
    if command == "OPEN" then
      devVars[101][10].value = "0"
    elseif command == "CLOSE" then
      devVars[101][10].value = "1"
    end
    return
  end
  return harnessSend(self, id, command, params)
end
dofile("drivers/smartbuildos-load-shedding/driver.lua")

R.lifecycle({
  H = H,
  moduleId = "load_shedding",
  file = "smartbuildos-load-shedding.c4z",
  sku = "SBOS_LOAD_SHEDDING",
  mode = "start",
  activity = function()
    EC.SET_BATTERY({ PERCENT = "90" })
    EC.SET_OUTAGE({ STATE = "On" })
    advance(61000)
  end,
  describe = function(d)
    local classes = {}
    for _, c in ipairs(d.controls) do
      classes[#classes + 1] = c.id .. "=" .. c.class
    end
    check("describe: load shedding and battery (class power)", table.concat(classes, ",") == "load_shedding=power,battery=power")
    check("describe: no query declared", #d.queries == 0)
  end,
  state = function(facts)
    check(
      "state: the outage, the tier and the load shed, the battery",
      facts.outage_active == true
        and facts.highest_tier_shed == 1
        and facts.loads_shed == 1
        and facts.battery_percent == 90
        and facts.read_only == false
        and type(facts.shed_status) == "string",
      JSON:encode(facts)
    )
  end,
  forbid = { "Pool Pump", "Yard" },
})

print("[5] the load-command diagnostic")
OnDriverInit()
OnDriverLateInit()
EC.SET_OUTAGE({ STATE = "Off" })
advance(3600 * 1000)
H.aiRegister()
H.pushDirectory()
failLoad = true
EC.SET_OUTAGE({ STATE = "On" })
local dg = H.reports("diagnostic")
local last = dg[#dg] and dg[#dg].args
check(
  "a load command that could not be sent: load.command_failed (warning), as the driver's own Load Failed",
  last ~= nil and last.code == "load.command_failed" and last.severity == "warning",
  last and JSON:encode(last) or #dg
)
check("every report valid for AI Core", H.allValid(), select(2, H.allValid()))

R.finish()
