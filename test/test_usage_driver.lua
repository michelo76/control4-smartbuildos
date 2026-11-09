-- Usage Analytics DRIVER under the shim with a scripted Agent: zero-config
-- plan from a fake project, seeding, registration + licence under the SKU,
-- a simulated day producing one `usage.daily` with the right numbers, the
-- report action, Measuring Off/On, licence enforcement, a project change,
-- Studio commands, persistence across a reload, reset.
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
-- Start the scenario at 01:00 LOCAL time so a day of activity stays inside
-- one calendar day whatever the machine's timezone.
local base = 1800000000
local realDateProbe = os.date
while realDateProbe("%H:%M", base) ~= "01:00" do
  base = base + 60
end
os.time = function(t)
  if t then
    return realTime(t)
  end
  return base + math.floor(clock.now / 1000)
end
local realDate = os.date
os.date = function(fmt, t)
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

-- ── a small built-in catalogue instead of the generated one ─────────────────
package.preload["tracer.catalog_data"] = function()
  return {
    ["keypad.c4z"] = { [1] = "Top Button Pushed", [2] = "Bottom Button Pushed", [3] = "Top Button Released" },
    ["contact.c4i"] = { [1] = "Opened", [2] = "Closed" },
    ["smartbuildos.c4z"] = { [1] = "Connected", [2] = "Disconnected" },
  }
end

-- ── fake Director ───────────────────────────────────────────────────────────
local AGENT_ID = 50
local SELF_ID = 12345
local agentPresent = false
local sent = {}
local fired = {}
local listeners = {}
local subscriptions = {}
local props = {}
local vars = {}
local devices = {
  [12] = { deviceName = "Kitchen Pendants", driverFileName = "light_v2.c4i", roomId = 3, roomName = "Kitchen" },
  [13] = { deviceName = "Office Lamp", driverFileName = "light_v2.c4i", roomId = 4, roomName = "Office" },
  [20] = { deviceName = "Garage Door", driverFileName = "contact.c4i", roomId = 7, roomName = "Garage" },
  [40] = { deviceName = "Hall Keypad", driverFileName = "keypad.c4z", roomId = 3, roomName = "Kitchen" },
  [200] = { deviceName = "Apple TV", driverFileName = "appletv.c4z", roomId = 3, roomName = "Kitchen" },
  [SELF_ID] = {
    deviceName = "Usage Analytics",
    driverFileName = "smartbuildos-usage-analytics.c4z",
    roomId = 3,
    roomName = "Kitchen",
  },
}
local variables = {
  [3] = {
    ["1000"] = { name = "CURRENT_SELECTED_DEVICE", value = "0" },
    ["1005"] = { name = "POWER_STATE", value = "False" },
    ["1006"] = { name = "CURRENT_VOLUME", value = "10" },
  },
  [4] = {
    ["1000"] = { name = "CURRENT_SELECTED_DEVICE", value = "0" },
    ["1005"] = { name = "POWER_STATE", value = "False" },
  },
  [7] = { ["1009"] = { name = "ROOM_NAME", value = "Garage" } },
  [12] = { ["1001"] = { name = "LIGHT_LEVEL", value = "0" }, ["1002"] = { name = "LIGHT_STATE", value = "False" } },
  [13] = { ["1001"] = { name = "Brightness Percent", value = "50" } },
  [20] = { ["2001"] = { name = "ContactState", value = "Closed" } },
}
C4.GetDevices = function()
  local d = {}
  for k, v in pairs(devices) do
    d[k] = v
  end
  if agentPresent then
    d[AGENT_ID] = { deviceName = "SmartBuildOS Agent", driverFileName = "smartbuildos.c4z" }
  end
  return d
end
C4.GetDeviceVariables = function(_, id)
  return variables[tonumber(id)]
end
C4.GetDeviceDisplayName = function(_, id)
  local d = C4.GetDevices()[tonumber(id)]
  return d and d.deviceName or nil
end
C4.GetDeviceID = function()
  return SELF_ID
end
C4.GetDriverConfigInfo = function(_, key)
  if key == "minimum_os_version" then
    return "3.3.2"
  elseif key == "model" then
    return "Usage Analytics"
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
C4.RegisterVariableListener = function(_, d, v)
  listeners[d .. ":" .. v] = true
end
C4.UnregisterVariableListener = function(_, d, v)
  listeners[d .. ":" .. v] = nil
end
C4.RegisterDeviceEvent = function(_, d, e)
  subscriptions[d .. ":" .. e] = true
end
C4.UnregisterDeviceEvent = function(_, d, e)
  subscriptions[d .. ":" .. e] = nil
end
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

Properties = {}
do
  local f = assert(io.open("drivers/smartbuildos-usage-analytics/driver.xml"))
  local xml = f:read("*a")
  f:close()
  for block in xml:gmatch("<property>(.-)</property>") do
    local name = block:match("<name>(.-)</name>")
    local default = block:match("<default>(.-)</default>") or ""
    Properties[name] = default
  end
end

dofile("drivers/smartbuildos-usage-analytics/driver.lua")

local function prop(name)
  return props[name] or Properties[name]
end
local function sentOf(command)
  local out = {}
  for _, s in ipairs(sent) do
    if s.command == command then
      out[#out + 1] = s
    end
  end
  return out
end
local function lastSent(command)
  local list = sentOf(command)
  return list[#list]
end
-- Unique by event_id: an unacknowledged frame is resent by the client, and a
-- resend is the same event, not a second one.
local function eventsSent()
  local out, seen = {}, {}
  for _, s in ipairs(sent) do
    if s.command == "SBOS_MODULE_EVENTS" then
      for _, e in ipairs(JSON:decode(s.params.events)) do
        if not seen[e.event_id] then
          seen[e.event_id] = true
          out[#out + 1] = e
        end
      end
    end
  end
  return out
end
local function eventsOfType(tp)
  local out = {}
  for _, e in ipairs(eventsSent()) do
    if e.event_type == tp then
      out[#out + 1] = e
    end
  end
  return out
end
local function hasFired(id)
  for _, f in ipairs(fired) do
    if f == id then
      return true
    end
  end
  return false
end
local function count(t)
  local n = 0
  for _ in pairs(t) do
    n = n + 1
  end
  return n
end
local TOKEN = "tok-ua"
local function agentRegisters(ok, extra)
  local reply = {
    module_id = "usage_analytics",
    instance_id = tostring(SELF_ID),
    ok = ok and "true" or "false",
    token = TOKEN,
    protocol = "1",
    paired = "true",
    connected = "true",
    installation_id = "sys-1",
    boot_id = "boot-1",
    agent_version = "20261109.1",
  }
  for k, v in pairs(extra or {}) do
    reply[k] = v
  end
  EC.SBOS_MODULE_REGISTERED(reply)
end
local function ackAllFrames()
  local again = true
  while again do
    again = false
    for _, s in ipairs(sent) do
      if s.command == "SBOS_MODULE_EVENTS" and not s.acked then
        s.acked = true
        again = true
        EC.SBOS_MODULE_EVENTS_ACK({
          batch_id = s.params.batch_id,
          accepted = tostring(#JSON:decode(s.params.events)),
          queue = JSON:encode({ depth = 1, dropped = 0 }),
        })
      end
    end
  end
end
local function advanceToNextDay()
  local today = os.date("%Y-%m-%d")
  local target = os.time()
  while os.date("%Y-%m-%d", target) == today do
    target = target + 60
  end
  advance((target - os.time()) * 1000 + 90 * 1000)
end

print("[1] starts without an Agent: zero-config plan, seeding, measuring locally")
OnDriverInit()
OnDriverLateInit("DIT_ADDING")
check("online", props["Driver Status"] == "Online")
check(
  "room listeners: Kitchen + Office × 2 vars; light listeners: 12 × 2, 13 × 1",
  count(listeners) == 7,
  count(listeners)
)
check(
  "keypad subscriptions: the two press events, not Released",
  count(subscriptions) == 2 and subscriptions["40:1"] and subscriptions["40:2"] and not subscriptions["40:3"]
)
check(
  "Sources line",
  prop("Sources"):find("2 room%(s%), 2 light%(s%), 1 keypad%(s%)") ~= nil
    and prop("Sources"):find("1 room%(s%) without media variables") ~= nil,
  prop("Sources")
)
check("status measuring locally", prop("Measuring Status"):find("^measuring_local") ~= nil, prop("Measuring Status"))
check("conditional MEASURING_ACTIVE", TC.MEASURING_ACTIVE() == true and TC.AGENT_READY() == false)
check("licence shows no Agent", prop("License Status") == "No SmartBuildOS Agent Found")

print("[2] seeded values count from the seed, not from the next change")
advance(30 * 60 * 1000)
check(
  "Office Lamp seeded on (Brightness 50) → 0.5 h after 30 min",
  vars["LIGHT_HOURS_TODAY"] == "0.5",
  vars["LIGHT_HOURS_TODAY"]
)
check("no media yet, no presses", vars["MEDIA_HOURS_TODAY"] == "0" and vars["KEYPAD_PRESSES_TODAY"] == 0)
check("Today line", prop("Today"):find("lights 0.5 h", 1, true) ~= nil, prop("Today"))

print("[3] the Agent appears: registration + licence under the SKU")
agentPresent = true
advance(301 * 1000) -- the retry backoff has reached its 300 s cap by now
local reg = lastSent("SBOS_MODULE_REGISTER")
check(
  "register frame carries the contract",
  reg ~= nil
    and reg.params.module_id == "usage_analytics"
    and reg.params.entitlements == "SBOS_USAGE_ANALYTICS"
    and reg.params.event_types == "usage."
    and reg.params.commands:find("send_summary") ~= nil,
  reg and reg.params.event_types
)
agentRegisters(true)
check(
  "registered + ready, Agent Connected fired",
  props["Agent Connection"] == "ready" and hasFired(4) and TC.AGENT_READY()
)
check("licence registered under the SKU", lastSent("SBOS_REGISTER_DRIVER").params.sku == "SBOS_USAGE_ANALYTICS")
EC.SBOS_ENTITLEMENT({
  sku = "SBOS_USAGE_ANALYTICS",
  status = "AUTHORIZED_SUBSCRIPTION",
  license_type = "subscription",
  registered = "true",
  subscription_tier = "Professional",
  company_name = "Skynet AV",
})
check("licence painted", prop("License Status"):find("Licensed") ~= nil and prop("Subscription Tier") == "Professional")
advance(6000)
check("re-plan after registration changes nothing", count(listeners) == 7 and count(subscriptions) == 2)
advance(2500)
check("plan_applied envelopes uploaded", #eventsOfType("usage.plan_applied") >= 1)
ackAllFrames()
check("Last Upload stamped", prop("Last Upload") ~= "never")

print("[4] a day of activity → one usage.daily with the right numbers")
sent = {}
fired = {}
-- Kitchen: Apple TV for 2 hours.
OnWatchedVariableChanged(3, 1000, "200")
OnWatchedVariableChanged(3, 1005, "True")
-- Pendants on for 1 hour.
OnWatchedVariableChanged(12, 1002, "True")
for _ = 1, 5 do
  OnDeviceEvent(40, 1)
end
advance(60 * 60 * 1000)
OnWatchedVariableChanged(12, 1002, "False")
OnDeviceEvent(40, 2)
advance(60 * 60 * 1000)
OnWatchedVariableChanged(3, 1005, "False")
check(
  "unsubscribed event ignored",
  (function()
    OnDeviceEvent(20, 1)
    return vars["KEYPAD_PRESSES_TODAY"] == 6
  end)()
)
check(
  "live variables after two hours",
  vars["MEDIA_HOURS_TODAY"] == "2" and vars["KEYPAD_PRESSES_TODAY"] == 6,
  vars["MEDIA_HOURS_TODAY"]
)
local lightBefore = tonumber(vars["LIGHT_HOURS_TODAY"])
advanceToNextDay()
local daily = eventsOfType("usage.daily")
check("exactly one usage.daily after midnight", #daily == 1, #daily)
local p = daily[1] and daily[1].payload or {}
check(
  "daily: 2 h media, 6 presses",
  p.media_hours == 2 and p.keypad_presses == 6,
  tostring(p.media_hours) .. "/" .. tostring(p.keypad_presses)
)
check(
  "daily: Kitchen with Apple TV as top source",
  p.rooms
    and p.rooms[1]
    and p.rooms[1].room == "Kitchen"
    and p.rooms[1].top_source == "Apple TV"
    and p.rooms[1].hours == 2
)
check(
  "daily: Office Lamp burned longest (seeded on all day), Pendants 1 h",
  p.lights_top
    and p.lights_top[1].light == "Office Lamp"
    and p.lights_top[2].light == "Kitchen Pendants"
    and p.lights_top[2].hours == 1
    and p.lights_top[2].cycles == 1
)
check("daily: Office never used for media", p.unused_rooms and p.unused_rooms[1] == "Office")
check("daily: light hours at least what was live before midnight", p.light_hours >= lightBefore)
check(
  "envelope identity and correlation",
  daily[1].module_id == "usage_analytics"
    and daily[1].correlation_id:find("^usage%-daily%-") ~= nil
    and daily[1].evidence_source == "derived"
)
check("Daily Summary Sent fired, property stamped", hasFired(3) and prop("Last Daily Summary") ~= "none")
check("today starts fresh: media 0, presses 0", vars["MEDIA_HOURS_TODAY"] == "0" and vars["KEYPAD_PRESSES_TODAY"] == 0)
check("Days Recorded 2", prop("Days Recorded") == "2", prop("Days Recorded"))
ackAllFrames()

print("[5] report and summary actions")
local okP = pcall(function()
  Properties["Report Range"] = "30 days"
  EC.PRINT_REPORT()
  EC.PRINT_SOURCES()
end)
check("print actions run", okP)
sent = {}
Properties["Report Range"] = "7 days"
EC.SEND_SUMMARY()
advance(2500)
local summary = eventsOfType("usage.summary")
check(
  "usage.summary for 7 days with yesterday's media",
  #summary == 1 and summary[1].payload.period == "7d" and summary[1].payload.media_hours == 2
)
sent = {}
EC.SEND_USAGE_SUMMARY({ DAYS = "30" })
advance(2500)
check("programming command sends a 30-day summary", eventsOfType("usage.summary")[1].payload.period == "30d")
ackAllFrames()

print("[6] Measuring Off / On")
Properties["Measuring"] = "Off"
OnPropertyChanged("Measuring")
check(
  "off releases everything, status disabled, days kept",
  count(listeners) == 0
    and count(subscriptions) == 0
    and prop("Measuring Status") == "disabled"
    and prop("Days Recorded") == "2"
)
check("Measuring Degraded not fired for a deliberate off", true)
Properties["Measuring"] = "On"
OnPropertyChanged("Measuring")
check(
  "on re-plans and re-seeds",
  count(listeners) == 7 and count(subscriptions) == 2 and prop("Measuring Status") == "measuring"
)

print("[7] licence enforcement halts measuring; uncertainty never does")
fired = {}
EC.SBOS_ENTITLEMENT({
  sku = "SBOS_USAGE_ANALYTICS",
  status = "CLOUD_VALIDATION_REQUIRED",
  registered = "true",
  enforcement = "enforce",
})
check("uncertain status changes nothing", count(listeners) == 7 and prop("Measuring Status") == "measuring")
EC.SBOS_ENTITLEMENT({
  sku = "SBOS_USAGE_ANALYTICS",
  status = "NOT_ENTITLED",
  registered = "true",
  enforcement = "enforce",
})
check(
  "definitive denial + enforce releases and paints unlicensed",
  count(listeners) == 0 and count(subscriptions) == 0 and prop("Measuring Status") == "unlicensed"
)
check("Measuring Degraded fired", hasFired(1))
EC.SBOS_ENTITLEMENT({
  sku = "SBOS_USAGE_ANALYTICS",
  status = "NOT_ENTITLED",
  registered = "true",
  enforcement = "observe",
})
check("observe mode resumes", count(listeners) == 7 and prop("Measuring Status") == "measuring" and hasFired(2))
EC.SBOS_ENTITLEMENT({ sku = "SBOS_USAGE_ANALYTICS", status = "AUTHORIZED_SUBSCRIPTION", registered = "true" })

print("[8] project change re-plans after a quiet period; exclusions")
devices[14] = { deviceName = "Porch Light", driverFileName = "light_v2.c4i", roomId = 7, roomName = "Garage" }
variables[14] = { ["1002"] = { name = "LIGHT_STATE", value = "False" } }
EC.SBOS_MODULE_AGENT_EVENT({ name = "project_changed", detail = "{}" })
check("not yet (debounced)", listeners["14:1002"] == nil)
advance(5500)
check("new light measured", listeners["14:1002"] == true and count(listeners) == 8)
Properties["Exclude Device IDs"] = "14, 4"
OnPropertyChanged("Exclude Device IDs")
check(
  "excluded light and room released",
  listeners["14:1002"] == nil
    and listeners["4:1005"] == nil
    and count(listeners) == 5
    and prop("Sources"):find("2 excluded") ~= nil,
  prop("Sources")
)
Properties["Exclude Device IDs"] = ""
OnPropertyChanged("Exclude Device IDs")
devices[14] = nil
variables[14] = nil
EC.SBOS_MODULE_AGENT_EVENT({ name = "project_changed", detail = "{}" })
advance(5500)
check("removed light released", listeners["14:1002"] == nil and count(listeners) == 7)

print("[9] Studio commands through the Agent")
sent = {}
EC.SBOS_MODULE_COMMAND({ token = "wrong", request_id = "r0", command = "send_summary", args = "{}" })
check("wrong token ignored", #sentOf("SBOS_MODULE_COMMAND_RESULT") == 0)
EC.SBOS_MODULE_COMMAND({ token = TOKEN, request_id = "r1", command = "send_summary", args = JSON:encode({ days = 7 }) })
local results = sentOf("SBOS_MODULE_COMMAND_RESULT")
check(
  "send_summary: Accepted → Executing → Completed",
  #results == 3 and results[3].params.state == "Completed",
  results[3] and results[3].params.state
)
EC.SBOS_MODULE_COMMAND({ token = TOKEN, request_id = "r2", command = "nope", args = "{}" })
check("unknown command fails by name", lastSent("SBOS_MODULE_COMMAND_RESULT").params.state == "Failed")
EC.SBOS_MODULE_COMMAND({ token = TOKEN, request_id = "r3", command = "reapply", args = "{}" })
check(
  "reapply completes with the sources line",
  lastSent("SBOS_MODULE_COMMAND_RESULT").params.state == "Completed"
    and lastSent("SBOS_MODULE_COMMAND_RESULT").params.detail:find("room") ~= nil
)

print("[10] persistence across a reload")
OnDeviceEvent(40, 1)
advance(6 * 60 * 1000) -- past the 5-minute checkpoint interval, dirty
check("meter checkpointed", persisted["ua_meter_v1"] ~= nil and persisted["ua_meter_v1"].days ~= nil)
OnDriverDestroyed()
check(
  "destroy released everything and unregistered",
  count(listeners) == 0 and count(subscriptions) == 0 and lastSent("SBOS_MODULE_UNREGISTER") ~= nil
)
sent = {}
OnDriverInit()
OnDriverLateInit("DIT_UPDATING")
agentRegisters(true, { token = "tok-2" })
check("days survived the reload", prop("Days Recorded") == "2", prop("Days Recorded"))
check("today's presses survived", vars["KEYPAD_PRESSES_TODAY"] == 1, vars["KEYPAD_PRESSES_TODAY"])
check("listeners rebuilt", count(listeners) == 7 and count(subscriptions) == 2)

print("[11] reset")
EC.RESET_STATISTICS()
check(
  "reset keeps today only, empty",
  prop("Days Recorded") == "1" and vars["KEYPAD_PRESSES_TODAY"] == 0 and count(listeners) == 7
)

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
