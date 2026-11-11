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
local responders = {} -- { match = "<text in the url>", answer = fun(url) → { ok, code, body } } — first match wins
local function nextAnswer(url)
  for _, r in ipairs(responders) do
    if url:find(r.match, 1, true) then
      return r.answer(url)
    end
  end
  if #httpScript > 0 then
    return table.remove(httpScript, 1)
  end
  return { ok = true, code = 200 }
end
package.preload["lib.http"] = function()
  local H = {}
  function H:request(method, url, data, headers, options)
    local a = nextAnswer(url)
    requests[#requests + 1] =
      { method = method, url = url, data = data, headers = headers, options = options, answer = a }
    return {
      next = function(_, onOk, onErr)
        if a.ok then
          onOk({ url = url, code = a.code, headers = {}, body = a.body or "{}" })
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
local varSets = {} -- every SetVariable, in order: { name, value }
C4.SetVariable = function(_, name, value)
  vars[name] = value
  varSets[#varSets + 1] = { name, value }
  -- Director keeps the Variables table current for the driver.
  Variables = Variables or {}
  Variables[name] = value
end
local addedVariables = {} -- name -> readOnly, as registered
C4.AddVariable = function(_, name, _, _, readOnly)
  addedVariables[name] = readOnly
end
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

print("[10] message variables: picked in the command, sent as values")
local deviceVars = {
  [231] = {
    ["1000"] = { name = "STATE", value = "1" },
    ["1001"] = { name = "LAST_USER_CODE", value = "4321" },
    ["1002"] = { name = "Opened By", value = "Remote" },
  },
  [100001] = { ["7"] = { name = "Pool Temp", value = "81.46" } },
}
C4.GetDeviceVariables = function(_, id)
  return deviceVars[tonumber(id)]
end
local baseDevices = C4.GetDevices
C4.GetDevices = function(...)
  local d = baseDevices(...)
  d[231] = { deviceName = "Garage Door", roomName = "Garage", driverFileName = "relay.c4z" }
  return d
end
for _, name in ipairs({ "Pushover", "Webhook", "Generic Webhook", "Twilio SMS" }) do
  Properties[name] = "Off"
end
Properties["Telegram"] = "On"
Properties["Telegram Bot Token"] = "123:ABC"
Properties["Telegram Chat ID"] = "-100"
Properties["Telegram Minimum Priority"] = "low"
Properties["Telegram Quiet Start"] = ""
Properties["Telegram Quiet End"] = ""
Properties["Rate Limit Per Hour"] = "600"
Properties["Dedupe Window"] = "300"
OnPropertyChanged("Telegram")

requests = {}
fired = {}
-- What Composer hands the driver: "deviceId,variableId" for a picked
-- VARIABLE parameter, "" for one left empty (bench 2026-11-10).
local garage = {
  CHANNEL = "Telegram",
  PRIORITY = "high",
  TITLE = "Garage ${1|open|closed}",
  MESSAGE = "Pool ${2|.1}°F, door ${Garage->Garage Door::STATE|open|closed}, by ${231::Opened By}",
  ["VARIABLE 1"] = "231,1000",
  ["VARIABLE 2"] = "100001,7",
  ["VARIABLE 3"] = "",
  ["VARIABLE 4"] = "",
}
EC.NOTIFY(garage)
check(
  "title and message go out with values, never names",
  #requests == 1 and requests[1].data.text == "Garage open\nPool 81.5°F, door open, by Remote",
  requests[1] and requests[1].data.text
)
check(
  "Last Notification shows the filled title",
  prop("Last Notification") == "Garage open (high)",
  prop("Last Notification")
)
check("nothing missing: no Message Variable Missing event", countFired(8) == 0)
EC.NOTIFY(garage)
check("the same values again inside the window are a duplicate", #requests == 1)
deviceVars[231]["1000"].value = "0"
EC.NOTIFY(garage)
check(
  "a changed value is a different message and is sent",
  #requests == 2 and requests[2].data.text == "Garage closed\nPool 81.5°F, door closed, by Remote",
  requests[2] and requests[2].data.text
)
requests = {}
EC.NOTIFY({
  CHANNEL = "Telegram",
  PRIORITY = "normal",
  TITLE = "Pool",
  MESSAGE = "Temperature now:",
  ["VARIABLE 1"] = "100001,7",
})
check(
  "a variable picked but not written into the text is added at the end",
  #requests == 1 and requests[1].data.text == "Pool\nTemperature now: 81.46",
  requests[1] and requests[1].data.text
)
requests = {}
EC.NOTIFY_ALL({ PRIORITY = "normal", TITLE = "All ${1|open|closed}", MESSAGE = "", ["VARIABLE 1"] = "231,1000" })
check(
  "Notify All takes the same VARIABLE parameters",
  #requests == 1 and requests[1].data.text == "All closed",
  requests[1] and requests[1].data.text
)

print("[11] message variables: what cannot be read never blocks the send")
requests = {}
fired = {}
EC.NOTIFY({
  CHANNEL = "Telegram",
  PRIORITY = "normal",
  TITLE = "Alarm ${3}",
  MESSAGE = 'x ${Nowhere::STATE} code ${1} {"json": 1} ${hello} {1}',
  ["VARIABLE 1"] = "231,1001",
  ["VARIABLE 3"] = "",
})
check(
  "sent with ? and [hidden]; everything that is not a token untouched",
  #requests == 1 and requests[1].data.text == 'Alarm ?\nx ? code [hidden] {"json": 1} ${hello} {1}',
  requests[1] and requests[1].data.text
)
check("Message Variable Missing fired once for the notification", countFired(8) == 1, countFired(8))
check(
  "Last Router Error names the first variable and why",
  prop("Last Router Error"):find("variable ${3}: variable 3: nothing picked in VARIABLE 3", 1, true) ~= nil,
  prop("Last Router Error")
)
advance(6000)
check(
  "the delivery log lists each one",
  (function()
    local n = 0
    for _, e in ipairs(persisted["nr_log_v1"].log) do
      if e.status == "variable" then
        n = n + 1
      end
    end
    return n == 3
  end)()
)
check(
  "the credential's value is nowhere: not in a request, not in the log",
  not JSON:encode(persisted["nr_log_v1"]):find("4321", 1, true)
    and not tostring(requests[1].data.text):find("4321", 1, true)
)
deviceVars[231] = nil
requests = {}
EC.NOTIFY({
  CHANNEL = "Telegram",
  PRIORITY = "normal",
  TITLE = "Door ${1}",
  MESSAGE = "still sends",
  ["VARIABLE 1"] = "231,1000",
})
check(
  "a device that does not answer: the notification still goes out",
  #requests == 1 and requests[1].data.text == "Door ?\nstill sends",
  requests[1] and requests[1].data.text
)
requests = {}
EC.NOTIFY({ CHANNEL = "Telegram", PRIORITY = "normal", TITLE = "Plain", MESSAGE = "no variables here" })
check(
  "a notification written before this change (no VARIABLE parameters) is sent as written",
  #requests == 1 and requests[1].data.text == "Plain\nno variables here"
)

print("[12] the command declares Composer's variable picker")
do
  local f = assert(io.open("drivers/smartbuildos-notification-router/driver.xml"))
  local xml = f:read("*a")
  f:close()
  local pickers = 0
  for _ in
    xml:gmatch("<param><name>VARIABLE %d</name><type>VARIABLE_SELECTOR</type><variabletype>all</variabletype></param>")
  do
    pickers = pickers + 1
  end
  check("four pickers each on Notify, Notify All and Reply", pickers == 12, pickers)
  check("no variable slots left in the properties", not xml:find("<property><name>Variable ", 1, true))
  -- Read top to bottom the way the message reads: text, variable, text.
  local order = {}
  local notify = xml:match("<name>NOTIFY</name>(.-)</command>")
  for name in notify:gmatch("<param><name>([^<]+)</name>") do
    order[#order + 1] = name
  end
  check(
    "Notify reads MESSAGE, VARIABLE 1, MESSAGE 2 … VARIABLE 4, MESSAGE 5",
    table.concat(order, "|")
      == "CHANNEL|PRIORITY|TITLE|SEPARATOR|MESSAGE|VARIABLE 1|MESSAGE 2|VARIABLE 2|MESSAGE 3|VARIABLE 3|MESSAGE 4|VARIABLE 4|MESSAGE 5",
    table.concat(order, "|")
  )
  check("MESSAGE keeps its name, so programming written before still sends its text", order[5] == "MESSAGE")
  check(
    "SEPARATOR sits above the first text, Space first so a new line is one sentence unless chosen otherwise",
    notify:find(
      "<name>SEPARATOR</name><type>LIST</type><items><item>Space</item><item>New Line</item><item>Comma</item>",
      1,
      true
    ) ~= nil
  )
  check(
    "the script line shows the title and the pieces, not the separator's name",
    xml:find("<description>Notify PARAM1 (PARAM2): PARAM3 PARAM5 ", 1, true) ~= nil
  )
  local seps = 0
  for _ in xml:gmatch("<param><name>SEPARATOR</name>") do
    seps = seps + 1
  end
  check("Notify, Notify All and Reply each have it", seps == 3, seps)
  check(
    "MESSAGE_RECEIVED is declared, and programming may set it",
    xml:find("<name>MESSAGE_RECEIVED</name><type>STRING</type><default></default><readonly>false</readonly>", 1, true)
      ~= nil
  )
end

print("[13] two-way: nothing is asked while inbound is off")
local function countUrl(part)
  local n = 0
  for _, r in ipairs(requests) do
    if r.url:find(part, 1, true) then
      n = n + 1
    end
  end
  return n
end
local function lastUrl(part)
  for i = #requests, 1, -1 do
    if requests[i].url:find(part, 1, true) then
      return requests[i]
    end
  end
  return nil
end
local updates = {} -- what Telegram has waiting
local tgAnswer = nil -- set to force an answer (an error)
responders[#responders + 1] = {
  match = "/getUpdates",
  answer = function()
    if tgAnswer then
      return tgAnswer
    end
    local body = { ok = true, result = updates }
    updates = {}
    return { ok = true, code = 200, body = body }
  end,
}
local updateId = 499
local function telegramSays(text, fields)
  updateId = updateId + 1
  local m =
    { date = os.time(), text = text, chat = { id = -100 }, from = { id = 777, username = "Owner", is_bot = false } }
  for k, v in pairs(fields or {}) do
    m[k] = v
  end
  updates[#updates + 1] = { update_id = updateId, message = m }
  return updateId
end
deviceVars[231] = { ["1000"] = { name = "STATE", value = "1" } }
requests = {}
fired = {}
advance(20000)
check(
  "inbound off: no request to Telegram or Twilio",
  countUrl("/getUpdates") == 0 and countUrl("Messages.json?To=") == 0
)
check("status says off", prop("Inbound Status") == "off", prop("Inbound Status"))
EC.REPLY({ MESSAGE = "hello" })
check(
  "Reply before any message is refused and says why",
  #requests == 0 and prop("Last Router Error") == "Reply: no message has been received yet",
  prop("Last Router Error")
)

print("[14] two-way: a Telegram message becomes variables, then events")
Properties["Keyword 1"] = "Goodnight"
Properties["Keyword 2"] = "gate"
Properties["Telegram Inbound"] = "On"
OnPropertyChanged("Telegram Inbound")
check(
  "turning it on asks at once, with no offset",
  countUrl("/getUpdates") == 1 and not lastUrl("/getUpdates").url:find("offset", 1, true)
)
check("status: listening", prop("Inbound Status") == "Telegram: listening", prop("Inbound Status"))
telegramSays("good  night")
telegramSays("Goodnight")
fired = {}
advance(5000)
check(
  "the message is in LAST_MESSAGE and the Telegram variable",
  vars["LAST_MESSAGE"] == "Goodnight"
    and vars["TELEGRAM_LAST_MESSAGE"] == "Goodnight"
    and vars["SMS_LAST_MESSAGE"] == nil,
  vars["LAST_MESSAGE"]
)
check(
  "channel, sender, keyword and counters",
  vars["LAST_MESSAGE_CHANNEL"] == "Telegram"
    and vars["LAST_MESSAGE_SENDER"] == "Owner"
    and vars["LAST_KEYWORD"] == "goodnight"
    and vars["LAST_MESSAGE_ARGUMENT"] == ""
    and vars["MESSAGE_COUNTER"] == 2
    and vars["MESSAGES_RECEIVED_TODAY"] == 2,
  vars["MESSAGE_COUNTER"]
)
check(
  "Message Received and Telegram Message Received once per message; Keyword 1 for the one that matched",
  countFired(9) == 2 and countFired(10) == 2 and countFired(21) == 1 and countFired(11) == 0,
  countFired(9)
)
check("painted", prop("Last Message") == "Telegram: Goodnight" and prop("Received Today") == "2", prop("Last Message"))
advance(5000)
check(
  "the next ask starts after what was handled",
  lastUrl("/getUpdates").url:find("&offset=502", 1, true) ~= nil,
  lastUrl("/getUpdates").url
)
fired = {}
updates =
  { { update_id = 501, message = { date = os.time(), text = "Goodnight", chat = { id = -100 }, from = { id = 777 } } } }
advance(5000)
check("the same message served again is handled once", countFired(9) == 0 and vars["MESSAGE_COUNTER"] == 2)
telegramSays("Goodnight")
advance(5000)
check(
  "the same words in a new message fire again; the counter moves",
  countFired(9) == 1 and countFired(21) == 1 and vars["MESSAGE_COUNTER"] == 3
)

print("[15] two-way: who is not taken")
fired = {}
telegramSays("open the garage", { chat = { id = 999 }, from = { id = 999 } })
advance(5000)
check(
  "a stranger: Message Rejected, nothing else, variables untouched",
  countFired(12) == 1 and countFired(9) == 0 and vars["LAST_MESSAGE"] == "Goodnight"
)
check(
  "the error says why without the text",
  prop("Last Router Error") == "Telegram message refused: sender is not on the allow-list",
  prop("Last Router Error")
)
fired = {}
telegramSays("gate open", { date = os.time() - 500 })
advance(5000)
check("an old message is ignored silently", #fired == 0 and vars["LAST_MESSAGE"] == "Goodnight")
telegramSays("beep", { from = { id = 1, is_bot = true } })
telegramSays("   ")
advance(5000)
check("a bot and an empty message are ignored", #fired == 0)
Properties["Telegram Allowed Senders"] = "555, @owner"
telegramSays("gate 30", { chat = { id = 555 }, from = { id = 555 } })
telegramSays("gate 40", { from = { id = 888, username = "guest" } })
advance(5000)
check(
  "a listed person's private chat is taken; an unlisted member of the group is not",
  vars["LAST_MESSAGE"] == "gate 30"
    and vars["LAST_MESSAGE_ARGUMENT"] == "30"
    and countFired(22) == 1
    and countFired(12) == 1,
  vars["LAST_MESSAGE"]
)
Properties["Telegram Allowed Senders"] = ""

print("[16] two-way: the PIN")
Properties["Inbound PIN"] = "4471"
fired = {}
telegramSays("gate open")
telegramSays("4471 Gate Open Now")
advance(5000)
check(
  "without the PIN refused; with it the PIN never reaches a variable",
  countFired(12) == 1
    and vars["LAST_MESSAGE"] == "Gate Open Now"
    and vars["LAST_MESSAGE_ARGUMENT"] == "Open Now"
    and countFired(22) == 1,
  vars["LAST_MESSAGE"]
)
Properties["Inbound PIN"] = ""

print("[17] two-way: Reply")
requests = {}
EC.REPLY({ MESSAGE = "Gate is ${1|open|closed}", ["VARIABLE 1"] = "231,1000" })
local sendReq = lastUrl("/sendMessage")
check(
  "the reply goes to the chat the message came from, with live values",
  sendReq ~= nil and sendReq.data.chat_id == "-100" and sendReq.data.text == "Gate is open",
  sendReq and sendReq.data.text
)
telegramSays("gate", { chat = { id = 555 }, from = { id = 555 } })
Properties["Telegram Allowed Senders"] = "555"
advance(5000)
requests = {}
EC.REPLY({ MESSAGE = "Done" })
check(
  "a private sender is answered privately",
  lastUrl("/sendMessage") ~= nil and lastUrl("/sendMessage").data.chat_id == "555",
  lastUrl("/sendMessage") and lastUrl("/sendMessage").data.chat_id
)
Properties["Telegram Allowed Senders"] = ""
Properties["Telegram Quiet Start"] = "11:00"
Properties["Telegram Quiet End"] = "13:00"
Properties["Telegram Minimum Priority"] = "critical"
requests = {}
EC.NOTIFY({ CHANNEL = "Telegram", PRIORITY = "normal", TITLE = "Quiet", MESSAGE = "held back" })
check("a notification is held back by quiet hours and the priority gate", countUrl("/sendMessage") == 0)
EC.REPLY({ MESSAGE = "Still answered" })
check("a reply is not", countUrl("/sendMessage") == 1 and lastUrl("/sendMessage").data.text == "Still answered")
EC.REPLY({ MESSAGE = "" })
check(
  "a reply needs a MESSAGE",
  prop("Last Router Error") == "Reply: a reply needs a MESSAGE",
  prop("Last Router Error")
)
Properties["Telegram Quiet Start"] = ""
Properties["Telegram Quiet End"] = ""
Properties["Telegram Minimum Priority"] = "low"

print("[18] two-way: a text message")
local texts = {}
responders[#responders + 1] = {
  match = "Messages.json?To=",
  answer = function()
    return { ok = true, code = 200, body = { messages = texts } }
  end,
}
local function stamp(t)
  return realDate("!%a, %d %b %Y %H:%M:%S +0000", t)
end
Properties["Twilio Account SID"] = "AC1"
Properties["Twilio Auth Token"] = "tok"
Properties["Twilio From Number"] = "+15550001"
Properties["Twilio To Number"] = "+15559876"
Properties["Twilio Inbound"] = "On"
OnPropertyChanged("Twilio Inbound")
check(
  "the list is asked for the router's own number, with Basic auth",
  lastUrl("Messages.json?To=%2B15550001&DateSent%3E=") ~= nil
    and lastUrl("Messages.json?To=").headers["Authorization"] == "Basic B64(AC1:tok)",
  lastUrl("Messages.json?To=") and lastUrl("Messages.json?To=").url
)
check(
  "status names both channels",
  prop("Inbound Status") == "Telegram: listening · Twilio SMS: listening",
  prop("Inbound Status")
)
texts = {
  { sid = "SM9", direction = "inbound", from = "+15550000", body = "open the garage", date_sent = stamp(os.time()) },
  { sid = "SM8", direction = "outbound-api", from = "+15550001", body = "ours", date_sent = stamp(os.time()) },
  { sid = "SM7", direction = "inbound", from = "+1 (555) 9876", body = "Gate status", date_sent = stamp(os.time()) },
}
fired = {}
advance(5000)
check(
  "the text is in LAST_MESSAGE and the SMS variable; the Telegram one keeps its own",
  vars["LAST_MESSAGE"] == "Gate status"
    and vars["SMS_LAST_MESSAGE"] == "Gate status"
    and vars["TELEGRAM_LAST_MESSAGE"] == "gate",
  vars["TELEGRAM_LAST_MESSAGE"]
)
check(
  "SMS Message Received, Keyword 2, and the stranger's text rejected",
  countFired(11) == 1
    and countFired(10) == 0
    and countFired(22) == 1
    and countFired(12) == 1
    and vars["LAST_MESSAGE_CHANNEL"] == "Twilio SMS"
)
advance(15000)
check("listed again on every ask, handled once", countFired(11) == 1 and countFired(12) == 1)
requests = {}
EC.REPLY({ MESSAGE = "Gate is ${1|open|closed}", ["VARIABLE 1"] = "231,1000" })
local smsReq = nil
for _, r in ipairs(requests) do
  if r.method == "POST" and r.url:find("/Messages.json", 1, true) then
    smsReq = r
  end
end
check(
  "the reply is texted back to the sender",
  smsReq ~= nil
    and smsReq.data:find("To=%%2B15559876", 1) ~= nil
    and smsReq.data:find("Body=Gate%%20is%%20open", 1) ~= nil,
  smsReq and smsReq.data
)

print("[19] two-way: a failing ask backs off and says why")
tgAnswer = { ok = false, code = 409 }
requests = {}
advance(5000)
check(
  "the status names the cause",
  prop("Inbound Status"):find("Telegram: HTTP 409: another program or a webhook is reading this bot", 1, true) ~= nil,
  prop("Inbound Status")
)
local asked = countUrl("/getUpdates")
advance(5000)
check("it is not asked again on the next tick", countUrl("/getUpdates") == asked, countUrl("/getUpdates"))
tgAnswer = nil
advance(15000)
check(
  "after the back-off it asks again and recovers",
  countUrl("/getUpdates") > asked and prop("Inbound Status"):find("Telegram: listening", 1, true) ~= nil,
  prop("Inbound Status")
)

print("[20] two-way: nothing replays after a restart; refused text is never stored")
advance(6000)
check(
  "the log has the received messages and no refused text",
  (function()
    local blob = JSON:encode(persisted["nr_log_v1"])
    return blob:find("Gate status", 1, true) ~= nil
      and blob:find("open the garage", 1, true) == nil
      and blob:find("4471", 1, true) == nil
  end)()
)
check(
  "the log masks the texting number",
  (function()
    for _, e in ipairs(persisted["nr_log_v1"].log) do
      if e.status == "received" and e.target == "Twilio SMS" then
        return e.detail:find("+1555****", 1, true) ~= nil and not e.detail:find("9876", 1, true)
      end
    end
    return false
  end)()
)
local counterBefore = vars["MESSAGE_COUNTER"]
OnDriverDestroyed()
check(
  "the offset and the handled ids are stored",
  type(persisted["nr_inbound_v1"]) == "table"
    and persisted["nr_inbound_v1"].telegram_offset ~= nil
    and #persisted["nr_inbound_v1"].seen > 5
)
requests = {}
fired = {}
OnDriverInit()
OnDriverLateInit("DIT_UPDATING")
check(
  "after the restart the first ask carries the offset",
  lastUrl("/getUpdates") ~= nil and lastUrl("/getUpdates").url:find("&offset=", 1, true) ~= nil
)
advance(5000)
check(
  "the texts still listed by Twilio are not handled again",
  countFired(11) == 0 and countFired(9) == 0,
  countFired(9)
)
requests = {}
EC.REPLY({ MESSAGE = "After restart" })
check("Reply still knows who wrote last", #requests == 1 and requests[1].url:find("/Messages.json", 1, true) ~= nil)
telegramSays("gate")
advance(5000)
check(
  "a new message is taken and the counter carries on",
  vars["MESSAGE_COUNTER"] == counterBefore + 1,
  vars["MESSAGE_COUNTER"]
)
Properties["Telegram Inbound"] = "Off"
Properties["Twilio Inbound"] = "Off"
OnPropertyChanged("Telegram Inbound")
requests = {}
advance(20000)
check("turned off: nothing is asked", #requests == 0 and prop("Inbound Status") == "off", #requests)

print("[21] a message written in pieces: MESSAGE, VARIABLE 1, MESSAGE 2 …")
-- The owner's line, 10 Nov 2026: "This system rebooted" + a variable holding
-- 3 arrived as "This system rebooted 3", with nowhere to write "times".
deviceVars[100001]["467"] = { name = "Test", value = "3" }
deviceVars[100001]["8"] = { name = "Pool Now", value = "81.5" }
requests = {}
EC.NOTIFY({
  CHANNEL = "Telegram",
  PRIORITY = "high",
  TITLE = "Testing Variables",
  MESSAGE = "This system rebooted",
  ["VARIABLE 1"] = "100001,467",
  ["MESSAGE 2"] = "times",
})
check(
  "the value sits between the two texts",
  #requests == 1 and requests[1].data.text == "Testing Variables\nThis system rebooted 3 times",
  requests[1] and requests[1].data.text
)
requests = {}
EC.NOTIFY({
  CHANNEL = "Telegram",
  PRIORITY = "high",
  TITLE = "Pieces",
  MESSAGE = "Rebooted",
  ["VARIABLE 1"] = "100001,467",
  ["MESSAGE 2"] = "times, door",
  ["VARIABLE 2"] = "231,1000",
  ["MESSAGE 3"] = ".",
  ["VARIABLE 3"] = "",
  ["MESSAGE 4"] = "Pool",
  ["VARIABLE 4"] = "100001,8",
  ["MESSAGE 5"] = "°F",
})
check(
  "four variables and five texts, in the order they are written",
  #requests == 1 and requests[1].data.text == "Pieces\nRebooted 3 times, door 1. Pool 81.5°F",
  requests[1] and requests[1].data.text
)
requests = {}
EC.NOTIFY({
  CHANNEL = "Telegram",
  PRIORITY = "high",
  TITLE = "Old line",
  MESSAGE = "written before this change",
  ["VARIABLE 1"] = "100001,467",
})
check(
  "a line written before, with no MESSAGE 2, sends what it sent",
  #requests == 1 and requests[1].data.text == "Old line\nwritten before this change 3",
  requests[1] and requests[1].data.text
)
requests = {}
EC.NOTIFY_ALL({
  PRIORITY = "high",
  TITLE = "All",
  MESSAGE = "Rebooted",
  ["VARIABLE 1"] = "100001,467",
  ["MESSAGE 2"] = "times",
})
check(
  "Notify All reads the same pieces",
  #requests >= 1 and requests[1].data.text == "All\nRebooted 3 times",
  requests[1] and requests[1].data.text
)

print("[21b] SEPARATOR: what goes between one message and the next")
-- The owner's line, 10 Nov 2026 evening. It arrived as "Home is currently
-- Occupied The security is currently Armed Away": two statements run together.
deviceVars[100001]["469"] = { name = "Home_Status", value = "Occupied" }
deviceVars[100001]["470"] = { name = "Security", value = "Armed Away" }
-- Each call has its own title, so the dedupe window never swallows a send
-- and a comparison can never pass on two empty answers. Returns the body.
local homeCalls = 0
local function homeStatus(separator, more)
  requests = {}
  homeCalls = homeCalls + 1
  local params = {
    CHANNEL = "Telegram",
    PRIORITY = "normal",
    TITLE = "Home Status " .. homeCalls,
    SEPARATOR = separator,
    MESSAGE = "Home is currently",
    ["VARIABLE 1"] = "100001,469",
    ["MESSAGE 2"] = "The security is currently",
    ["VARIABLE 2"] = "100001,470",
  }
  for k, v in pairs(more or {}) do
    params[k] = v
  end
  EC.NOTIFY(params)
  local text = requests[1] and requests[1].data.text or "(nothing sent)"
  return (text:gsub("^Home Status %d+\n", ""))
end
check(
  "New Line: each message on its own line",
  homeStatus("New Line") == "Home is currently Occupied\nThe security is currently Armed Away",
  homeStatus("New Line")
)
check(
  "Period",
  homeStatus("Period") == "Home is currently Occupied. The security is currently Armed Away",
  homeStatus("Period")
)
check(
  "Comma, Dash, Semicolon, Vertical Bar",
  homeStatus("Comma"):find("Occupied, The security", 1, true) ~= nil
    and homeStatus("Dash"):find("Occupied - The security", 1, true) ~= nil
    and homeStatus("Semicolon"):find("Occupied; The security", 1, true) ~= nil
    and homeStatus("Vertical Bar"):find("Occupied | The security", 1, true) ~= nil
)
check(
  "Space, and a line written before the parameter existed: one sentence, as it was",
  homeStatus("Space") == "Home is currently Occupied The security is currently Armed Away"
    and homeStatus(nil) == homeStatus("Space")
    and homeStatus("") == homeStatus("Space")
    and homeStatus("Something Else") == homeStatus("Space"),
  homeStatus(nil)
)
check(
  "an empty message leaves no stray separator",
  homeStatus("New Line", { ["MESSAGE 3"] = "", ["MESSAGE 5"] = "Have a good day" })
    == "Home is currently Occupied\nThe security is currently Armed Away\nHave a good day",
  homeStatus("New Line", { ["MESSAGE 5"] = "Have a good day" })
)
check(
  "a message that already ends its sentence gets no second mark",
  homeStatus("Period", { ["VARIABLE 1"] = "", MESSAGE = "All is well." })
    == "All is well. The security is currently Armed Away",
  homeStatus("Period", { ["VARIABLE 1"] = "", MESSAGE = "All is well." })
)
requests = {}
EC.NOTIFY_ALL({
  PRIORITY = "normal",
  TITLE = "All",
  SEPARATOR = "New Line",
  MESSAGE = "Home is",
  ["VARIABLE 1"] = "100001,469",
  ["MESSAGE 2"] = "Security is",
  ["VARIABLE 2"] = "100001,470",
})
check(
  "Notify All takes the separator too",
  requests[1] ~= nil and requests[1].data.text == "All\nHome is Occupied\nSecurity is Armed Away",
  requests[1] and requests[1].data.text
)

print("[22] MESSAGE_RECEIVED: a variable programming can test, and set")
check("registered so that programming may set it", addedVariables["MESSAGE_RECEIVED"] == false)
check(
  "every other variable stays read-only",
  addedVariables["LAST_MESSAGE"] == true and addedVariables["MESSAGE_COUNTER"] == true
)
local function receivedSets()
  local out = {}
  for _, set in ipairs(varSets) do
    if set[1] == "MESSAGE_RECEIVED" then
      out[#out + 1] = "[" .. tostring(set[2]) .. "]"
    end
  end
  return table.concat(out, " ")
end
Properties["Telegram Inbound"] = "On"
OnPropertyChanged("Telegram Inbound")
varSets = {}
fired = {}
telegramSays("Open the gate")
advance(5000)
check("it holds the message, as sent", vars["MESSAGE_RECEIVED"] == "Open the gate", vars["MESSAGE_RECEIVED"])
check("one change for a new text", receivedSets() == "[Open the gate]", receivedSets())
check(
  "set after the other variables and before the events",
  (function()
    local at, lastOther = nil, 0
    for i, set in ipairs(varSets) do
      if set[1] == "MESSAGE_RECEIVED" then
        at = i
      elseif set[1] == "LAST_MESSAGE" or set[1] == "LAST_MESSAGE_SENDER" or set[1] == "MESSAGE_COUNTER" then
        lastOther = i
      end
    end
    return at ~= nil and at > lastOther and countFired(9) == 1
  end)()
)
varSets = {}
telegramSays("Open the gate")
advance(5000)
check(
  "the same text again is still a change: emptied, then set",
  receivedSets() == "[] [Open the gate]",
  receivedSets()
)
-- Programming clears it once handled.
C4:SetVariable("MESSAGE_RECEIVED", "")
varSets = {}
telegramSays("Open the gate")
advance(5000)
check("after programming cleared it, one change is enough", receivedSets() == "[Open the gate]", receivedSets())
telegramSays("wrong pin attempt", { from = { id = 999, username = "Stranger", is_bot = false }, chat = { id = 555 } })
varSets = {}
advance(5000)
check(
  "a refused message never reaches it",
  receivedSets() == "" and vars["MESSAGE_RECEIVED"] == "Open the gate",
  receivedSets()
)
Properties["Message Received As"] = "Lower Case"
varSets = {}
telegramSays("Gate OPEN")
advance(5000)
check(
  "Lower Case: a phone's capital letter does not make a different text",
  vars["MESSAGE_RECEIVED"] == "gate open" and vars["LAST_MESSAGE"] == "Gate OPEN",
  vars["MESSAGE_RECEIVED"]
)
Properties["Message Received As"] = "As Sent"
Properties["Telegram Inbound"] = "Off"
OnPropertyChanged("Telegram Inbound")

print("[23] Find Telegram Chat ID")
-- Setting a bot up: the dealer has the token and not yet the chat id.
Properties["Telegram Chat ID"] = ""
requests = {}
updates = {}
telegramSays(
  "hello",
  { chat = { id = 4455, type = "private", first_name = "Sam" }, from = { id = 4455, first_name = "Sam" } }
)
telegramSays(
  "hi all",
  { chat = { id = -100777, type = "group", title = "Family" }, from = { id = 4455, first_name = "Sam" } }
)
EC.FIND_CHAT_ID()
advance(100)
check(
  "not listening: one look, and no offset sent back (nothing is taken)",
  countUrl("/getUpdates") == 1 and not lastUrl("/getUpdates").url:find("offset", 1, true)
)
check(
  "the chats that wrote are listed with their ids, newest first",
  prop("Telegram Chats Seen"):find("Family (group): -100777 · Sam (private): 4455", 1, true) == 1,
  prop("Telegram Chats Seen")
)
check("no message was handled by looking", vars["LAST_MESSAGE"] ~= "hello" and vars["LAST_MESSAGE"] ~= "hi all")
updates = {}
EC.FIND_CHAT_ID()
advance(100)
check(
  "what was seen stays listed when nothing new came",
  prop("Telegram Chats Seen"):find("Sam (private): 4455", 1, true) ~= nil
)
local savedToken = Properties["Telegram Bot Token"]
Properties["Telegram Bot Token"] = ""
EC.FIND_CHAT_ID()
check("no token: says so and asks nothing more", prop("Telegram Chats Seen") == "paste the Telegram Bot Token first")
Properties["Telegram Bot Token"] = savedToken
Properties["Telegram Chat ID"] = "-100"

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
