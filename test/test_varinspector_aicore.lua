-- Variable Inspector reports to AI Core (sbos.aireport, START mode; brief
-- D7a).
--
-- The real driver.lua under the shim (set up as test_varinspector_driver.lua
-- does), the REAL Agent registry and bus and a fake AI Core answering
-- through AI Core's REAL validator (test/aicore_reporter_harness.lua); the
-- shared lifecycle checks are test/aicore_rollout_checks.lua.
-- Driver-specific: describe and a counts-only state: a watched lock's
-- variables (including a user code) never reach a report.
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

local devices = {
  [12] = { deviceName = "Kitchen Pendants", driverFileName = "light.c4z", roomId = 3, roomName = "Kitchen" },
  [20] = { deviceName = "Front Lock", driverFileName = "lock.c4z", roomId = 1, roomName = "Entry" },
  [SELF] = { deviceName = "Variable Inspector", driverFileName = "smartbuildos-variable-inspector.c4z" },
}
local variables = {
  [12] = { ["1001"] = { name = "LIGHT_LEVEL", value = "75" } },
  [20] = { ["2001"] = { name = "LockStatus", value = "Locked" }, ["2002"] = { name = "USER_CODE_1", value = "8642" } },
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
    return "SmartBuildOS Variable Inspector"
  end
  return "20261118.000001"
end
C4.SendToProxy = function() end
C4.RegisterVariableListener = function() end
C4.UnregisterVariableListener = function() end
C4.SetDeviceVariable = function() end
C4.GetNetworkBindingsByDevice = function()
  return {}
end
C4.GetBindingsByDevice = function()
  return { bindings = { { bindingid = 6001, info = { addr = "192.168.7.20" } } } }
end
C4.CreateServer = function()
  return true
end
C4.ServerSend = function() end
C4.ServerCloseClient = function() end
C4.DestroyServer = function() end
C4.FileSetDir = function() end
C4.FileExists = function()
  return false
end
require("lib.relayhost").get = function(url, done)
  done(url:match("^http://192%.168%.7%.20:") ~= nil, '{"ok":true}')
end

R.loadProperties("smartbuildos-variable-inspector")
Properties["Dealer PIN"] = "4321"
R.watchPaints()
H.install({ selfId = SELF, file = "smartbuildos-variable-inspector.c4z" })
dofile("drivers/smartbuildos-variable-inspector/driver.lua")

R.lifecycle({
  H = H,
  moduleId = "variable_inspector",
  file = "smartbuildos-variable-inspector.c4z",
  sku = "SBOS_VARIABLE_INSPECTOR",
  mode = "start",
  activity = function()
    EC.WATCH_VARIABLE({ DEVICE = "20", VARIABLE = "USER_CODE_1" }) -- refused by the model (a code)
    EC.WATCH_VARIABLE({ DEVICE = "20", VARIABLE = "LockStatus" })
    OnWatchedVariableChanged(20, 2001, "Unlocked")
    advance(61000)
  end,
  describe = function(d)
    check(
      "describe: the inspector (class other)",
      #d.controls == 1 and d.controls[1].id == "variable_inspector" and d.controls[1].class == "other"
    )
    check("describe: no query declared", #d.queries == 0)
  end,
  state = function(facts)
    check(
      "state: watched count, limit, writable, relay",
      facts.watched == 1 and facts.watch_limit > 0 and facts.read_only == false and facts.relay_listening == true,
      JSON:encode(facts)
    )
  end,
  -- what the variables say is household activity, and one is a user code
  forbid = { "8642", "USER_CODE", "LockStatus", "Unlocked", "Front Lock", "4321" },
})

R.finish()
