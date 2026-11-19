-- Guest Mode reports to AI Core (sbos.aireport, START mode; brief D7a).
--
-- The real driver.lua under the shim (set up as test_guestmode_driver.lua
-- does), the REAL Agent registry and bus and a fake AI Core answering
-- through AI Core's REAL validator (test/aicore_reporter_harness.lua); the
-- shared lifecycle checks are test/aicore_rollout_checks.lua.
-- Driver-specific: HEALTH AND COUNTS ONLY. With a guest checked in and a
-- per-stay PIN and Wi-Fi password set, no report carries the guest status,
-- name, dates, PIN, password or calendar address; the calendar diagnostics.
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

GUEST_MODE_NOW = function()
  return base + clock.now / 1000
end
local routes = {}
package.preload["lib.http"] = function()
  return {
    get = function(_, url)
      local body = routes[url]
      return {
        next = function(_, onOk, onErr)
          if body ~= nil and body ~= "FAIL" then
            onOk({ url = url, code = 200, headers = {}, body = body })
          else
            onErr({ url = url, code = 503, error = "service unavailable" })
          end
          return { next = function() end }
        end,
      }
    end,
  }
end
-- A stay that is in progress at the test clock (2027-01-15).
local FEED = table.concat({
  "BEGIN:VCALENDAR",
  "VERSION:2.0",
  "BEGIN:VEVENT",
  "UID:b@airbnb",
  "SUMMARY:Jane Doe",
  "DTSTART;VALUE=DATE:20270113",
  "DTEND;VALUE=DATE:20270118",
  "END:VEVENT",
  "END:VCALENDAR",
}, "\r\n")
local CAL = "https://cal.example/airbnb.ics?s=private-token-77"
routes[CAL] = FEED
local vars = {}
C4.SetVariable = function(_, name, value)
  vars[name] = value
end
C4.GetDevices = function()
  return {}
end
C4.GetDriverConfigInfo = function(_, key)
  if key == "minimum_os_version" then
    return "3.3.2"
  elseif key == "name" then
    return "SmartBuildOS Guest Mode"
  end
  return "20261118.000001"
end

R.loadProperties("smartbuildos-guest-mode")
Properties["Calendar URL 1"] = CAL
Properties["Guest PIN"] = "Per Stay"
R.watchPaints()
H.install({ selfId = SELF, file = "smartbuildos-guest-mode.c4z" })
dofile("drivers/smartbuildos-guest-mode/driver.lua")

R.lifecycle({
  H = H,
  moduleId = "guest_mode",
  file = "smartbuildos-guest-mode.c4z",
  sku = "SBOS_GUEST_MODE",
  mode = "start",
  activity = function()
    EC.SET_GUEST_WIFI_PASSWORD({ PASSWORD = "sunny-beach-2027" })
    advance(10000)
    EC.CHECK_IN_NOW({ NAME = "Jane Doe" })
    advance(61000)
  end,
  describe = function(d)
    check(
      "describe: guest stays (class other)",
      #d.controls == 1 and d.controls[1].id == "guest_stays" and d.controls[1].class == "other"
    )
    check("describe: no query declared", #d.queries == 0)
  end,
  state = function(facts)
    check(
      "state: calendar health only",
      facts.calendars == 1
        and facts.calendars_loaded == 1
        and facts.calendars_failing == 0
        and facts.halted_by_licence == false,
      JSON:encode(facts)
    )
    local keys = {}
    for k in pairs(facts) do
      keys[#keys + 1] = k
    end
    table.sort(keys)
    check(
      "state: nothing else (no guest status, presence, names, dates, stays)",
      table.concat(keys, ",") == "calendars,calendars_failing,calendars_loaded,driver_status,halted_by_licence,license",
      table.concat(keys, ",")
    )
  end,
  forbid = { "Jane", "cal.example", "private-token", "sunny-beach", "occupied", "vacant", "2027-01" },
})
check(
  "a guest really was in (the driver's own variables)",
  vars["GUEST_STATUS"] ~= "vacant" and vars["GUEST_STATUS"] ~= nil,
  vars["GUEST_STATUS"]
)
check(
  "…and the per-stay PIN never reached a report",
  type(vars["GUEST_PIN"]) == "string"
    and #vars["GUEST_PIN"] >= 4
    and JSON:encode(H.reports()):find(vars["GUEST_PIN"], 1, true) == nil,
  vars["GUEST_PIN"]
)

print("[5] the calendar diagnostics")
OnDriverInit()
OnDriverLateInit()
H.aiRegister()
H.pushDirectory()
routes[CAL] = "FAIL"
EC.POLL_NOW()
local dg = H.reports("diagnostic")
local last = dg[#dg] and dg[#dg].args
check(
  "every calendar failing: calendars.unavailable (warning)",
  last ~= nil and last.code == "calendars.unavailable" and last.severity == "warning",
  last and JSON:encode(last)
)
routes[CAL] = FEED
EC.POLL_NOW()
dg = H.reports("diagnostic")
last = dg[#dg] and dg[#dg].args
check(
  "loading again: calendars.restored (info)",
  last ~= nil and last.code == "calendars.restored" and last.severity == "info"
)
check("no calendar address in any report", JSON:encode(H.reports()):find("cal.example", 1, true) == nil)
check("every report valid for AI Core", H.allValid(), select(2, H.allValid()))

R.finish()
