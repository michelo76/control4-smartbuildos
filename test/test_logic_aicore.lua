-- Logic Pack reports to AI Core (sbos.aireport, START mode; brief D7a).
--
-- The real driver.lua under the shim (set up as test_logic_driver.lua does),
-- the REAL Agent registry and bus and a fake AI Core answering through AI
-- Core's REAL validator (test/aicore_reporter_harness.lua); the shared
-- lifecycle checks are test/aicore_rollout_checks.lua. Driver-specific:
-- describe, counts-only state (no key names), the read-only diagnostic.
-- Run from the driver root: make test

C4 = C4 or {}
require("c4_shim")
JSON = require("JSON")
local R = require("aicore_rollout_checks")
local H = require("aicore_reporter_harness")
local check = R.check

-- ── timers (manual clock, as test_logic_driver.lua) ─────────────────────────
local clock = { now = 0, timers = {} }
package.preload["drivers-common-public.global.timer"] = function()
  ONE_SECOND = 1000
  ONE_MINUTE = 60000
  ONE_HOUR = 3600000
  function SetTimer(id, ms, cb, repeating)
    clock.timers[id] = { at = clock.now + ms, cb = cb, every = repeating and ms or nil }
  end
  function CancelTimer(id)
    clock.timers[id] = nil
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
      if t.at <= target and (bestAt == nil or t.at < bestAt or (t.at == bestAt and id < bestId)) then
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
local base = 1800000000
LOGIC_PACK_NOW = function()
  return base + clock.now / 1000
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
  return P
end

local SELF = 12345
C4.GetDeviceID = function()
  return SELF
end
C4.GetDriverConfigInfo = function(_, key)
  if key == "minimum_os_version" then
    return "3.3.2"
  elseif key == "name" then
    return "SmartBuildOS Logic Pack"
  end
  return "20261118.000001"
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

R.loadProperties("smartbuildos-logic-pack")
R.watchPaints()
H.install({ selfId = SELF, file = "smartbuildos-logic-pack.c4z" })
dofile("drivers/smartbuildos-logic-pack/driver.lua")

R.lifecycle({
  H = H,
  moduleId = "logic_pack",
  file = "smartbuildos-logic-pack.c4z",
  sku = "SBOS_LOGIC_PACK",
  mode = "start",
  activity = function()
    EC.INCREMENT_COUNTER({ KEY = "Maria door opens" })
    EC.SET_FLAG({ KEY = "Maria home" })
    EC.START_TIMER({ KEY = "Maria nap", SECONDS = "600" })
    advance(61000)
  end,
  describe = function(d)
    local ids = {}
    for _, c in ipairs(d.controls) do
      ids[#ids + 1] = c.id .. "=" .. c.class
    end
    check(
      "describe: the pack's four primitives, class other",
      table.concat(ids, ",") == "counters=other,flags=other,house_state=other,timers=other",
      table.concat(ids, ",")
    )
    check("describe: no query declared", #d.queries == 0)
  end,
  state = function(facts)
    check(
      "state: pack status and counts",
      facts.pack_status == "active"
        and facts.read_only == false
        and facts.counters == 1
        and facts.flags == 1
        and facts.timers_running == 1,
      JSON:encode(facts)
    )
  end,
  -- key names are free text typed by the programmer: never reported
  forbid = { "Maria", "maria" },
})

print("[5] the read-only diagnostic")
OnDriverInit()
OnDriverLateInit()
H.aiRegister()
H.pushDirectory()
EC.SBOS_ENTITLEMENT({ sku = "SBOS_LOGIC_PACK", status = "NOT_ENTITLED", registered = "true", enforcement = "enforce" })
local dg = H.reports("diagnostic")
local last = dg[#dg] and dg[#dg].args
check(
  "licence enforced: pack.read_only (warning), as the driver's own Read-only event",
  last ~= nil and last.code == "pack.read_only" and last.severity == "warning",
  last and JSON:encode(last)
)
check("every report valid for AI Core", H.allValid(), select(2, H.allValid()))

R.finish()
