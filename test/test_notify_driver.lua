-- Notification Router DRIVER under the shim: licensing registration with a
-- scripted Agent, Notify / Notify All producing the exact HTTP calls against
-- a fake lib.http, failure → retry with backoff → Delivery Failed, a 4xx
-- failing fast, quiet hours and rate limit events, dedupe, test actions,
-- Print Delivery Log, licence enforcement halting sends and resuming.
--
-- Run from the driver root: make test

local pass, fail = 0, 0
local function check(name, ok, detail)
  if ok then
    pass = pass + 1
    print(string.format("  ok   %s", name))
  else
    fail = fail + 1
    print(string.format("  FAIL %s%s", name, detail and ("  -> " .. tostring(detail)) or ""))
  end
end

C4 = C4 or {}
require("c4_shim")
JSON = require("JSON")

-- ── timers ──────────────────────────────────────────────────────────────────
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
local realTime = os.time
local base = 1800000000 -- 2027-01-15 03:00 UTC
os.time = function(t)
  if t then
    return realTime(t)
  end
  return base + math.floor(clock.now / 1000)
end
local realDate = os.date
local fakeMinute = 12 * 60 -- local time the driver believes it is
os.date = function(fmt, t)
  if fmt == "*t" and t == nil then
    local tt = realDate("*t", os.time())
    tt.hour = math.floor(fakeMinute / 60)
    tt.min = fakeMinute % 60
    return tt
  end
  return realDate(fmt, t or os.time())
end
package.preload["drivers-common-public.global.url"] = function()
  return true
end
package.preload["cloud-client-byte"] = function()
  return true
end

-- ── persist (in memory) ─────────────────────────────────────────────────────
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

-- ── fake lib.http: records requests, answers per a script ──────────────────
local requests = {}
local httpScript = {} -- fifo of { ok = bool, code = n }; default ok 200
local function nextAnswer()
  if #httpScript > 0 then
    return table.remove(httpScript, 1)
  end
  return { ok = true, code = 200 }
end
package.preload["lib.http"] = function()
  local H = {}
  function H:request(method, url, data, headers, options)
    local a = nextAnswer()
    requests[#requests + 1] =
      { method = method, url = url, data = data, headers = headers, options = options, answer = a }
    return {
      next = function(_, onOk, onErr)
        if a.ok then
          onOk({ url = url, code = a.code, headers = {}, body = "{}" })
        else
          onErr({ url = url, code = a.code, headers = {}, body = "", error = "HTTP failed" })
        end
      end,
    }
  end
  function H:post(url, data, headers, options)
    return self:request("POST", url, data, headers, options)
  end
  function H:get(url, headers, options)
    return self:request("GET", url, nil, headers, options)
  end
  return H
end

-- ── fake Director ───────────────────────────────────────────────────────────
local AGENT_ID = 50
local SELF_ID = 12345
local agentPresent = false
local sent = {}
local fired = {}
local props = {}
local vars = {}
C4.GetDevices = function()
  local d = { [12] = { deviceName = "Hall Keypad", driverFileName = "keypad.c4z", roomId = 3, roomName = "Hall" } }
  if agentPresent then
    d[AGENT_ID] = { deviceName = "SmartBuildOS Agent", driverFileName = "smartbuildos.c4z" }
  end
  return d
end
C4.GetDeviceID = function()
  return SELF_ID
end
C4.GetDriverConfigInfo = function(_, key)
  if key == "minimum_os_version" then
    return "3.3.2"
  elseif key == "model" then
    return "Notification Router"
  end
  return "20261109.000000"
end
C4.SendToDevice = function(_, device, command, params)
  sent[#sent + 1] = { device = device, command = command, params = params }
end
C4.FireEventByID = function(_, id)
  fired[#fired + 1] = id
end
C4.FireEvent = function() end
C4.SetVariable = function(_, name, value)
  vars[name] = value
end
C4.AddVariable = function() end
C4.AddEvent = function() end
C4.UpdateProperty = function(_, name, value)
  props[name] = value
  Properties[name] = value
end
C4.GetVersionInfo = function()
  return { version = "4.2.0.0" }
end
C4.Base64Encode = function(_, s)
  return "B64(" .. s .. ")"
end

Properties = {}
do
  local f = assert(io.open("drivers/smartbuildos-notification-router/driver.xml"))
  local xml = f:read("*a")
  f:close()
  for block in xml:gmatch("<property>(.-)</property>") do
    local name = block:match("<name>(.-)</name>")
    local default = block:match("<default>(.-)</default>") or ""
    Properties[name] = default
  end
end

dofile("drivers/smartbuildos-notification-router/driver.lua")

local function prop(name)
  return props[name] or Properties[name]
end
local function lastSent(command)
  for i = #sent, 1, -1 do
    if sent[i].command == command then
      return sent[i]
    end
  end
  return nil
end
local function countFired(id)
  local n = 0
  for _, f in ipairs(fired) do
    if f == id then
      n = n + 1
    end
  end
  return n
end
local function urlsOf(list)
  local out = {}
  for _, r in ipairs(list) do
    out[#out + 1] = r.url:gsub("^https://", ""):gsub("/.*$", "")
  end
  return table.concat(out, " ")
end

print("[1] starts: no Agent, no targets → not ready, licence loud")
OnDriverInit()
OnDriverLateInit("DIT_ADDING")
check("online", props["Driver Status"] == "Online")
check(
  "no targets ready",
  prop("Router Status") == "no_targets" and prop("Targets Ready") == "none",
  prop("Router Status")
)
check("licence says no Agent", prop("License Status") == "No SmartBuildOS Agent Found")
check("conditional ROUTER_READY false", TC.ROUTER_READY() == false)
EC.NOTIFY({ CHANNEL = "All", PRIORITY = "normal", TITLE = "Hello", MESSAGE = "nobody home" })
check("a notify with no targets sends nothing", #requests == 0)

print("[2] configure targets; Notify All sends to the three that are on")
Properties["Telegram"] = "On"
Properties["Telegram Bot Token"] = "123:ABC"
Properties["Telegram Chat ID"] = "-100"
Properties["Pushover"] = "On"
Properties["Pushover App Token"] = "pt"
Properties["Pushover User Key"] = "pu"
Properties["Pushover Minimum Priority"] = "high"
Properties["Twilio SMS"] = "On"
Properties["Twilio Account SID"] = "AC1"
Properties["Twilio Auth Token"] = "tok"
Properties["Twilio From Number"] = "+15550001"
Properties["Twilio To Number"] = "+15559876"
Properties["Twilio Minimum Priority"] = "low"
Properties["Webhook"] = "On" -- on but no URL: not ready
OnPropertyChanged("Telegram")
check(
  "targets ready names the configured ones only",
  prop("Targets Ready") == "Telegram, Pushover, Twilio SMS",
  prop("Targets Ready")
)
check("status ready", prop("Router Status") == "ready" and TC.ROUTER_READY() == true)
requests = {}
fired = {}
EC.NOTIFY_ALL({ PRIORITY = "normal", TITLE = "Garage", MESSAGE = "Door left open" })
check(
  "two HTTP calls: telegram + twilio (pushover below priority, webhook unconfigured)",
  #requests == 2 and urlsOf(requests) == "api.telegram.org api.twilio.com",
  urlsOf(requests)
)
check(
  "telegram request shape",
  requests[1].url == "https://api.telegram.org/bot123:ABC/sendMessage"
    and requests[1].data.chat_id == "-100"
    and requests[1].data.text == "Garage\nDoor left open"
)
check(
  "twilio request shape",
  requests[2].headers["Authorization"] == "Basic B64(AC1:tok)" and requests[2].data:find("To=%%2B15559876") ~= nil
)
check("Notification Sent fired twice", countFired(1) == 2)
check(
  "Sent Today 2, Last Notification painted",
  prop("Sent Today") == "2" and prop("Last Notification"):find("Garage %(normal%)") ~= nil,
  prop("Last Notification")
)
check(
  "the unconfigured webhook is a failed delivery with the reason",
  countFired(2) == 1 and prop("Last Router Error"):find("Webhook needs") ~= nil,
  prop("Last Router Error")
)
check("variables", vars["SENT_TODAY"] == 2 and vars["FAILED_TODAY"] == 1 and vars["LAST_FAILED_TARGET"] == "Webhook")

print("[3] dedupe and channel selection")
requests = {}
EC.NOTIFY_ALL({ PRIORITY = "normal", TITLE = "Garage", MESSAGE = "Door left open" })
check("identical message within the window sends nothing", #requests == 0)
EC.NOTIFY({ CHANNEL = "Pushover", PRIORITY = "high", TITLE = "Alarm", MESSAGE = "Zone 3" })
check(
  "channel + priority: one pushover call",
  #requests == 1 and requests[1].url:find("pushover") ~= nil and requests[1].data.priority == 1
)
EC.NOTIFY({ CHANNEL = "Generic Webhook", PRIORITY = "high", TITLE = "x", MESSAGE = "y" })
check("a target that is Off is skipped, logged as disabled", #requests == 1)
EC.NOTIFY({ CHANNEL = "All", PRIORITY = "normal", TITLE = "", MESSAGE = "" })
check("empty notification refused and named", prop("Last Router Error"):find("needs a TITLE") ~= nil)

print("[4] a failing target: retry 5 s, 30 s, then Delivery Failed")
Properties["Dedupe Window"] = "0"
requests = {}
fired = {}
httpScript = { { ok = false, code = 503 }, { ok = false, code = 503 }, { ok = false, code = 503 } }
EC.NOTIFY({ CHANNEL = "Telegram", PRIORITY = "high", TITLE = "Flaky", MESSAGE = "1" })
check(
  "first attempt made, Target Unreachable fired, nothing failed yet",
  #requests == 1 and countFired(3) == 1 and countFired(2) == 0
)
check("status sending while pending", prop("Router Status") == "sending" and vars["PENDING_DELIVERIES"] == 1)
advance(4999)
check("no retry before 5 s", #requests == 1)
advance(1)
check("second attempt at 5 s", #requests == 2)
advance(30000)
check("third attempt at +30 s", #requests == 3)
check(
  "after three attempts: Delivery Failed once, Failed Today counted",
  countFired(2) == 1 and vars["LAST_FAILED_TARGET"] == "Telegram" and prop("Router Status") == "ready"
)
advance(60000)
check("no fourth attempt", #requests == 3)

print("[5] a 4xx fails fast; a retry that succeeds counts as sent")
requests = {}
fired = {}
httpScript = { { ok = false, code = 401 } }
EC.NOTIFY({ CHANNEL = "Telegram", PRIORITY = "high", TITLE = "Bad token", MESSAGE = "x" })
check("401 → immediate Delivery Failed, no retry", countFired(2) == 1 and countFired(3) == 0 and #requests == 1)
check(
  "error says to check settings",
  prop("Last Router Error"):find("check the target") ~= nil,
  prop("Last Router Error")
)
httpScript = { { ok = false, code = 500 }, { ok = true, code = 200 } }
requests = {}
fired = {}
EC.NOTIFY({ CHANNEL = "Telegram", PRIORITY = "high", TITLE = "Recovers", MESSAGE = "x" })
advance(5000)
check(
  "second attempt succeeded → Notification Sent, no Delivery Failed",
  #requests == 2 and countFired(1) == 1 and countFired(2) == 0
)

print("[6] quiet hours and rate limit raise their events")
Properties["Telegram Quiet Start"] = "22:00"
Properties["Telegram Quiet End"] = "07:00"
fakeMinute = 23 * 60
requests = {}
fired = {}
EC.NOTIFY({ CHANNEL = "Telegram", PRIORITY = "high", TITLE = "Night", MESSAGE = "x" })
check("quiet hours: nothing sent, event 4", #requests == 0 and countFired(4) == 1)
EC.NOTIFY({ CHANNEL = "Telegram", PRIORITY = "critical", TITLE = "Fire", MESSAGE = "x" })
check("critical bypasses quiet hours", #requests == 1)
check("QUIET_HOURS_ACTIVE false while other targets are not quiet", TC.QUIET_HOURS_ACTIVE() == false)
fakeMinute = 12 * 60
Properties["Rate Limit Per Hour"] = "2"
requests = {}
fired = {}
for i = 1, 3 do
  EC.NOTIFY({ CHANNEL = "Twilio SMS", PRIORITY = "high", TITLE = "Burst " .. i, MESSAGE = "x" })
end
-- Twilio already sent once this rolling hour (section 2), so one slot is left.
check(
  "rate limit: one more sent, two dropped with event 5",
  #requests == 1 and countFired(5) == 2,
  #requests .. "/" .. countFired(5)
)

print("[7] the Agent appears: licence registration under the router SKU")
agentPresent = true
EC.REGISTER_NOW()
check(
  "registered with the Agent",
  lastSent("SBOS_REGISTER_DRIVER") ~= nil and lastSent("SBOS_REGISTER_DRIVER").params.sku == "SBOS_NOTIFICATION_ROUTER"
)
EC.SBOS_ENTITLEMENT({
  sku = "SBOS_NOTIFICATION_ROUTER",
  status = "AUTHORIZED_SUBSCRIPTION",
  license_type = "subscription",
  registered = "true",
  subscription_tier = "Professional",
  company_name = "Skynet AV",
})
check("licence painted", prop("License Status"):find("Licensed") ~= nil and prop("SmartBuildOS Company") == "Skynet AV")

print("[8] enforcement halts sending; observe mode resumes")
Properties["Rate Limit Per Hour"] = "60"
fired = {}
EC.SBOS_ENTITLEMENT({
  sku = "SBOS_NOTIFICATION_ROUTER",
  status = "CLOUD_VALIDATION_REQUIRED",
  registered = "true",
  enforcement = "enforce",
})
check("uncertain status changes nothing", prop("Router Status") == "ready")
EC.SBOS_ENTITLEMENT({
  sku = "SBOS_NOTIFICATION_ROUTER",
  status = "NOT_ENTITLED",
  registered = "true",
  enforcement = "enforce",
})
check(
  "definitive denial + enforce → unlicensed, Router Degraded",
  prop("Router Status") == "unlicensed" and countFired(6) == 1 and TC.ROUTER_READY() == false
)
requests = {}
EC.NOTIFY({ CHANNEL = "Telegram", PRIORITY = "critical", TITLE = "Blocked", MESSAGE = "x" })
check("nothing is sent while halted", #requests == 0)
EC.SBOS_ENTITLEMENT({
  sku = "SBOS_NOTIFICATION_ROUTER",
  status = "NOT_ENTITLED",
  registered = "true",
  enforcement = "observe",
})
check("observe mode resumes: Router Restored", prop("Router Status") == "ready" and countFired(7) == 1)
EC.SBOS_ENTITLEMENT({ sku = "SBOS_NOTIFICATION_ROUTER", status = "AUTHORIZED_SUBSCRIPTION", registered = "true" })

print("[9] test actions, log, persistence")
requests = {}
EC.TEST_PUSHOVER()
check(
  "Send Test To Pushover sends regardless of minimum priority? no: test is normal priority and pushover min is high → nothing",
  #requests == 0
)
Properties["Pushover Minimum Priority"] = "low"
EC.TEST_PUSHOVER()
EC.TEST_PUSHOVER()
check("test sends twice (bypasses dedupe)", #requests == 2 and requests[1].data.title == "Control4 test")
EC.TEST_GENERIC()
check(
  "test to an Off target is refused and named",
  prop("Last Router Error"):find("Generic Webhook is Off") ~= nil,
  prop("Last Router Error")
)
local okP = pcall(function()
  EC.PRINT_STATUS()
  EC.PRINT_LOG()
end)
check("print actions run", okP)
advance(6000)
check(
  "log persisted with entries, no token in it",
  persisted["nr_log_v1"] ~= nil
    and #persisted["nr_log_v1"].log > 5
    and not JSON:encode(persisted["nr_log_v1"]):find("123:ABC", 1, true)
)
check(
  "log entries say where they went without secrets",
  (function()
    for _, e in ipairs(persisted["nr_log_v1"].log) do
      if e.detail and e.detail:find("telegram chat %-100") then
        return true
      end
    end
    return false
  end)()
)
local logBefore = #persisted["nr_log_v1"].log
OnDriverDestroyed()
OnDriverInit()
OnDriverLateInit("DIT_UPDATING")
check("log and today's counts survive a reload", #persisted["nr_log_v1"].log == logBefore and prop("Sent Today") ~= "0")
EC.CLEAR_LOG()
check("clear log", #persisted["nr_log_v1"].log == 0)

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
