-- Notification Router reports to AI Core (sbos.aireport, START mode; brief
-- D7a).
--
-- The real driver.lua under the shim (set up as test_notify_driver.lua
-- does), the REAL Agent registry and bus and a fake AI Core answering
-- through AI Core's REAL validator (test/aicore_reporter_harness.lua); the
-- shared lifecycle checks are test/aicore_rollout_checks.lua.
-- Driver-specific: HEALTH AND COUNTS ONLY. After real notifications, no
-- report carries a title, message, token, chat id or phone number; the
-- degraded / restored diagnostics.
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

package.preload["lib.http"] = function()
  local Http = {}
  function Http:request(_, url)
    return {
      next = function(_, onOk)
        onOk({ url = url, code = 200, headers = {}, body = "{}" })
      end,
    }
  end
  function Http:post(url)
    return self:request("POST", url)
  end
  function Http:get(url)
    return self:request("GET", url)
  end
  return Http
end
C4.GetDevices = function()
  return {}
end
C4.GetDriverConfigInfo = function(_, key)
  if key == "minimum_os_version" then
    return "3.3.2"
  elseif key == "name" then
    return "SmartBuildOS Notification Router"
  end
  return "20261118.000001"
end
C4.Base64Encode = function(_, s)
  return s
end

R.loadProperties("smartbuildos-notification-router")
Properties["Telegram"] = "On"
Properties["Telegram Bot Token"] = "123:SECRETBOT"
Properties["Telegram Chat ID"] = "-100777"
Properties["Twilio SMS"] = "On"
Properties["Twilio Account SID"] = "AC1"
Properties["Twilio Auth Token"] = "twiliotok"
Properties["Twilio From Number"] = "+15550001"
Properties["Twilio To Number"] = "+15559876"
Properties["Twilio Minimum Priority"] = "low"
R.watchPaints()
H.install({ selfId = SELF, file = "smartbuildos-notification-router.c4z" })
dofile("drivers/smartbuildos-notification-router/driver.lua")

R.lifecycle({
  H = H,
  moduleId = "notification_router",
  file = "smartbuildos-notification-router.c4z",
  sku = "SBOS_NOTIFICATION_ROUTER",
  mode = "start",
  activity = function()
    EC.NOTIFY_ALL({ PRIORITY = "normal", TITLE = "Garage", MESSAGE = "Door left open at Maria's" })
    advance(61000)
  end,
  describe = function(d)
    check(
      "describe: notifications (class other)",
      #d.controls == 1 and d.controls[1].id == "notifications" and d.controls[1].class == "other"
    )
    check("describe: no query declared", #d.queries == 0)
  end,
  state = function(facts)
    check(
      "state: ready, two targets, counts",
      facts.router_status == "ready"
        and facts.targets_ready == 2
        and facts.sent_today >= 2
        and facts.failed_today == 0
        and facts.pending == 0
        and type(facts.received_today) == "number",
      JSON:encode(facts)
    )
  end,
  forbid = { "Garage", "Door left open", "Maria", "SECRETBOT", "100777", "twiliotok", "5559876", "5550001" },
})

print("[5] the degraded / restored diagnostics")
OnDriverInit()
OnDriverLateInit()
H.aiRegister()
H.pushDirectory()
Properties["Telegram"] = "Off"
Properties["Twilio SMS"] = "Off"
OnPropertyChanged("Telegram")
EC.REFRESH_STATUS()
local dg = H.reports("diagnostic")
local last = dg[#dg] and dg[#dg].args
check(
  "no target left: router.degraded (warning), as the driver's own Router Degraded",
  last ~= nil and last.code == "router.degraded" and last.severity == "warning",
  last and JSON:encode(last)
)
Properties["Telegram"] = "On"
OnPropertyChanged("Telegram")
EC.REFRESH_STATUS()
dg = H.reports("diagnostic")
last = dg[#dg] and dg[#dg].args
check(
  "a target again: router.restored (info)",
  last ~= nil and last.code == "router.restored" and last.severity == "info"
)
check("every report valid for AI Core", H.allValid(), select(2, H.allValid()))

R.finish()
