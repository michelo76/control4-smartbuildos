-- Daypart Scheduler reports to AI Core (sbos.aireport, START mode; brief
-- D7a).
--
-- The real driver.lua under the shim (set up as test_daypart_driver.lua
-- does), the REAL Agent registry and bus and a fake AI Core answering
-- through AI Core's REAL validator (test/aicore_reporter_harness.lua); the
-- shared lifecycle checks are test/aicore_rollout_checks.lua.
-- Driver-specific: describe (class media) and the schedule state; pausing
-- is reflected; the Manager PIN never reaches a report.
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

DAYPART_NOW = function()
  return base + clock.now / 1000
end
local ROOM, PLAYLIST = 100, 200
C4.GetDevices = function()
  return {
    [SELF] = { deviceName = "Daypart", driverFileName = "smartbuildos-daypart.c4z" },
    [ROOM] = { deviceName = "Main Dining", driverFileName = "roomdevice.c4i", roomId = ROOM, roomName = "Main Dining" },
    [PLAYLIST] = { deviceName = "Digital Music", driverFileName = "streamer.c4z", roomId = ROOM, roomName = "Main Dining" },
  }
end
C4.GetDeviceVariables = function()
  return {}
end
C4.GetDriverConfigInfo = function(_, key)
  if key == "minimum_os_version" then
    return "3.3.2"
  elseif key == "name" then
    return "SmartBuildOS Daypart Scheduler"
  end
  return "20261118.000001"
end
C4.UpdatePropertyList = function() end
C4.SendToProxy = function() end
C4.CreateServer = function() end
C4.DestroyServer = function() end
C4.ServerSend = function() end
C4.ServerCloseClient = function() end
C4.FileSetDir = function() end
C4.FileExists = function()
  return false
end
require("lib.relayhost").get = function(_, done)
  done(false)
end

R.loadProperties("smartbuildos-daypart")
Properties["App Relay Address"] = "192.0.2.10"
Properties["Zone 1 Name"] = "Dining"
Properties["Zone 1 Room"] = "Main Dining · 100"
Properties["Zone 1 Source 1"] = "Digital Music (Main Dining) · 200"
Properties["Manager PIN"] = "2468"
R.watchPaints()
H.install({ selfId = SELF, file = "smartbuildos-daypart.c4z" })
dofile("drivers/smartbuildos-daypart/driver.lua")

R.lifecycle({
  H = H,
  moduleId = "daypart",
  file = "smartbuildos-daypart.c4z",
  sku = "SBOS_DAYPART",
  mode = "start",
  activity = function()
    EC.PAUSE_SCHEDULE()
    EC.RESUME_SCHEDULE()
    advance(61000)
  end,
  describe = function(d)
    local classes = {}
    for _, c in ipairs(d.controls) do
      classes[#classes + 1] = c.class
    end
    check("describe: the music and display schedules (class media)", table.concat(classes, ",") == "media,media")
    check("describe: no query declared", #d.queries == 0)
  end,
  state = function(facts)
    check(
      "state: running, one zone, not paused",
      facts.schedule_status == "running" and facts.zones == 1 and facts.zones_in_block == 0 and facts.paused == false,
      JSON:encode(facts)
    )
  end,
  forbid = { "2468" },
})

print("[5] pausing shows in the state")
OnDriverInit()
OnDriverLateInit()
H.aiRegister()
H.pushDirectory()
EC.PAUSE_SCHEDULE()
local facts = H.reports("state")[#H.reports("state")].args.facts
check("paused: schedule_status paused, paused true", facts.schedule_status == "paused" and facts.paused == true, JSON:encode(facts))
EC.RESUME_SCHEDULE()
check("every report valid for AI Core", H.allValid(), select(2, H.allValid()))

R.finish()
