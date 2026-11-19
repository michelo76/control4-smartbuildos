-- Commissioning Matrix reports to AI Core (sbos.aireport, START mode;
-- brief D7a).
--
-- The real driver.lua under the shim (set up as test_commissioning_driver.lua
-- does), the REAL Agent registry and bus and a fake AI Core answering
-- through AI Core's REAL validator (test/aicore_reporter_harness.lua); the
-- shared lifecycle checks are test/aicore_rollout_checks.lua.
-- Driver-specific: describe and the run counts (never item or room names,
-- notes or the technician).
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

local devVars = {
  [10] = { [1] = { name = "Brightness Percent", value = "20" } },
  [11] = { [1] = { name = "Level", value = "100" } },
}
C4.GetDevices = function()
  return {
    [SELF] = { deviceName = "Commissioning", driverFileName = "smartbuildos-commissioning.c4z" },
    [10] = { deviceName = "Pendant", roomName = "Kitchen", driverFileName = "light_v2.c4z" },
    [11] = { deviceName = "Roller", roomName = "Den", driverFileName = "blind.c4z" },
  }
end
C4.GetDeviceVariables = function(_, id)
  return devVars[id] or {}
end
C4.RegisterVariableListener = function() end
C4.UnregisterVariableListener = function() end
C4.GetDriverConfigInfo = function(_, key)
  if key == "minimum_os_version" then
    return "3.3.2"
  elseif key == "name" then
    return "SmartBuildOS Commissioning Matrix"
  end
  return "20261118.000001"
end
C4.UpdatePropertyList = function(_, name, _, current)
  Properties[name] = current
end
C4.FileSetDir = function() end
C4.FileExists = function()
  return false
end
C4.CreateServer = function()
  return true
end
C4.ServerSend = function() end
C4.ServerCloseClient = function() end
C4.DestroyServer = function() end
require("lib.relayhost").get = function(_, done)
  done(false)
end

R.loadProperties("smartbuildos-commissioning")
Properties["Settle Seconds"] = "1"
Properties["App Relay Address"] = "10.9.9.9"
R.watchPaints()
H.install({ selfId = SELF, file = "smartbuildos-commissioning.c4z" })
dofile("drivers/smartbuildos-commissioning/driver.lua")

R.lifecycle({
  H = H,
  moduleId = "commissioning",
  file = "smartbuildos-commissioning.c4z",
  sku = "SBOS_COMMISSIONING",
  mode = "start",
  activity = function()
    EC.REBUILD_LIST_ACTION()
    EC.START_RUN({ TECHNICIAN = "Ana Ruiz" })
    advance(61000)
  end,
  describe = function(d)
    check(
      "describe: the commissioning run (class other)",
      #d.controls == 1 and d.controls[1].id == "commissioning_run" and d.controls[1].class == "other"
    )
    check("describe: no query declared", #d.queries == 0)
  end,
  state = function(facts)
    check(
      "state: run status and counts",
      type(facts.run_status) == "string"
        and facts.read_only == false
        and facts.items == 2
        and facts.rooms == 2
        and facts.passed == 0
        and facts.failed == 0
        and type(facts.open) == "number",
      JSON:encode(facts)
    )
  end,
  forbid = { "Ana", "Pendant", "Roller", "Kitchen" },
})

R.finish()
