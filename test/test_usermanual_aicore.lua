-- Home Guide (User Manual) reports to AI Core (sbos.aireport, START mode;
-- brief D7a).
--
-- The real driver.lua under the shim (set up as test_usermanual_driver.lua
-- does), the REAL Agent registry and bus and a fake AI Core answering
-- through AI Core's REAL validator (test/aicore_reporter_harness.lua); the
-- shared lifecycle checks are test/aicore_rollout_checks.lua.
-- Driver-specific: describe, counts-only state (never the home name, the
-- dealer's contact block or device names), the guide-unavailable
-- diagnostic.
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

local devices = {
  [12] = { deviceName = "Kitchen Pendants", driverFileName = "light_v2.c4i", roomId = 3, roomName = "Kitchen" },
  [20] = { deviceName = "Front Door", driverFileName = "lock_yale_zwave.c4z", roomId = 1, roomName = "Entry" },
  [30] = { deviceName = "Apple TV", driverFileName = "appleTV.c4z", roomId = 5, roomName = "Living" },
  [SELF] = {
    deviceName = "Home Guide",
    driverFileName = "smartbuildos-user-manual.c4z",
    roomId = 9,
    roomName = "Equipment Room",
  },
}
C4.GetDevices = function()
  return devices
end
C4.GetNetworkBindingsByDevice = function()
  return {}
end
C4.GetBindingsByDevice = function()
  return {}
end
C4.GetDriverConfigInfo = function(_, key)
  if key == "minimum_os_version" then
    return "3.3.2"
  elseif key == "name" then
    return "SmartBuildOS Home Guide"
  end
  return "20261118.000001"
end
C4.SendToProxy = function() end
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
C4.HMAC = function()
  return string.rep("ab", 32)
end

R.loadProperties("smartbuildos-user-manual")
Properties["Home Name"] = "The Whitfield Residence"
Properties["Dealer Name"] = "Skynet AV"
Properties["Dealer Phone"] = "555-0100"
Properties["Dealer Email"] = "help@skynet.example"
R.watchPaints()
H.install({ selfId = SELF, file = "smartbuildos-user-manual.c4z" })
dofile("drivers/smartbuildos-user-manual/driver.lua")

R.lifecycle({
  H = H,
  moduleId = "user_manual",
  file = "smartbuildos-user-manual.c4z",
  sku = "SBOS_USER_MANUAL",
  mode = "start",
  activity = function()
    EC.REBUILD_MANUAL()
    advance(61000)
  end,
  describe = function(d)
    check(
      "describe: the Home Guide tile (class other)",
      #d.controls == 1 and d.controls[1].id == "home_guide" and d.controls[1].class == "other"
    )
    check("describe: no query declared", #d.queries == 0)
  end,
  state = function(facts)
    check(
      "state: guide status and counts",
      facts.manual_status == "serving" and facts.rooms == 3 and facts.devices == 3,
      JSON:encode(facts)
    )
  end,
  forbid = { "Whitfield", "Skynet", "555-0100", "skynet.example", "Front Door", "Kitchen" },
})

print("[5] the guide-unavailable diagnostic")
OnDriverInit()
OnDriverLateInit()
H.aiRegister()
H.pushDirectory()
local before = #H.reports("diagnostic")
-- The relay stops (licence enforced): the driver's own Guide Unavailable.
EC.SBOS_ENTITLEMENT({ sku = "SBOS_USER_MANUAL", status = "NOT_ENTITLED", registered = "true", enforcement = "enforce" })
local dg = H.reports("diagnostic")
local last = dg[#dg] and dg[#dg].args
check(
  "guide stopped serving: guide.unavailable (warning)",
  #dg > before and last.code == "guide.unavailable" and last.severity == "warning",
  last and JSON:encode(last)
)
check(
  "…and the state follows (unlicensed)",
  H.reports("state")[#H.reports("state")].args.facts.manual_status == "unlicensed"
)
check("every report valid for AI Core", H.allValid(), select(2, H.allValid()))

R.finish()
