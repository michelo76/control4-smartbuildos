-- Logic Pack DRIVER under the shim with a scripted Agent: licence
-- registration, every programming command and the events/variables it
-- produces, conditionals with Director's VALUE/LOGIC params, slot-to-variable
-- mapping, Print State, persistence across a reload (late timers), licence
-- enforcement making the pack read-only, and reset scopes.
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
local base = 1800000000
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
LOGIC_PACK_NOW = function()
  return base + clock.now / 1000
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

-- ── fake Director ───────────────────────────────────────────────────────────
local AGENT_ID = 50
local SELF_ID = 12345
local sent = {}
local fired = {}
local vars = {}
local props = {}
C4.GetDevices = function()
  return {
    [AGENT_ID] = { deviceName = "SmartBuildOS Agent", driverFileName = "smartbuildos.c4z" },
    [SELF_ID] = { deviceName = "Logic Pack", driverFileName = "smartbuildos-logic-pack.c4z" },
  }
end
C4.GetDeviceID = function()
  return SELF_ID
end
C4.GetDriverConfigInfo = function(_, key)
  if key == "minimum_os_version" then
    return "3.3.2"
  elseif key == "model" then
    return "Logic Pack"
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

Properties = {}
do
  local f = assert(io.open("drivers/smartbuildos-logic-pack/driver.xml"))
  local xml = f:read("*a")
  f:close()
  for block in xml:gmatch("<property>(.-)</property>") do
    local name = block:match("<name>(.-)</name>")
    local default = block:match("<default>(.-)</default>") or ""
    Properties[name] = default
  end
end

dofile("drivers/smartbuildos-logic-pack/driver.lua")

local function prop(name)
  return props[name] or Properties[name]
end
local function firedCount(id)
  local n = 0
  for _, f in ipairs(fired) do
    if f == id then
      n = n + 1
    end
  end
  return n
end
local function lastSent(command)
  local out
  for _, s in ipairs(sent) do
    if s.command == command then
      out = s
    end
  end
  return out
end

print("[1] start: online, licence registered with the Agent under the pack SKU")
OnDriverInit()
OnDriverLateInit("DIT_ADDING")
check("online", props["Driver Status"] == "Online")
check("pack active", prop("Pack Status") == "active" and vars["PACK_STATUS"] == "active")
check(
  "licence registration sent to the Agent",
  lastSent("SBOS_REGISTER_DRIVER") ~= nil
    and lastSent("SBOS_REGISTER_DRIVER").device == AGENT_ID
    and lastSent("SBOS_REGISTER_DRIVER").params.sku == "SBOS_LOGIC_PACK"
)
EC.SBOS_ENTITLEMENT({
  sku = "SBOS_LOGIC_PACK",
  status = "AUTHORIZED_SUBSCRIPTION",
  license_type = "subscription",
  registered = "true",
  subscription_tier = "Professional",
  company_name = "Skynet AV",
})
check("licence painted", prop("License Status"):find("Licensed") ~= nil and prop("Subscription Tier") == "Professional")
check("PACK_ACTIVE conditional true", TC.PACK_ACTIVE() == true)

print("[2] counters and slot mapping")
Properties["Counter Slot 1 Key"] = "Front Door Opens"
OnPropertyChanged("Counter Slot 1 Key")
EC.INCREMENT_COUNTER({ KEY = "front door opens" })
EC.INCREMENT_COUNTER({ KEY = "Front Door Opens", BY = "2" })
check("slot variable follows the mapped key", vars["COUNTER_1"] == 3, vars["COUNTER_1"])
check("last counter variables", vars["LAST_COUNTER_KEY"] == "front_door_opens" and vars["LAST_COUNTER_VALUE"] == 3)
check("Counter Changed fired twice", firedCount(6) == 2)
EC.DECREMENT_COUNTER({ KEY = "front door opens" })
EC.SET_COUNTER({ KEY = "visits", VALUE = "10" })
check("unmapped counter does not touch slots", vars["COUNTER_1"] == 2 and vars["COUNTER_2"] == 0)
check(
  "conditional on slot 1 with Director params",
  TestCondition("COUNTER_SLOT_1", { VALUE = "2", LOGIC = "GREATER_THAN_OR_EQUAL" }) == true
    and TestCondition("COUNTER_SLOT_1", { VALUE = "5", LOGIC = "GREATER_THAN" }) == false
)
check("unmapped slot compares as 0", TestCondition("COUNTER_SLOT_2", { VALUE = "0", LOGIC = "EQUAL" }) == true)
EC.INCREMENT_COUNTER({ KEY = "visits", BY = "x" })
check(
  "bad BY refused and named",
  prop("Last Refusal"):find("Increment Counter: BY must be an integer") ~= nil,
  prop("Last Refusal")
)
EC.RESET_COUNTER({ KEY = "visits" })
check("reset to zero", vars["LAST_COUNTER_VALUE"] == 0)
Properties["Counter Slot 2 Key"] = "visits"
OnPropertyChanged("Counter Slot 2 Key")
check("remapping a slot repaints it from the engine", vars["COUNTER_2"] == 0)
EC.SET_COUNTER({ KEY = "visits", VALUE = "4" })
check("slot 2 follows", vars["COUNTER_2"] == 4)

print("[3] flags")
EC.SET_FLAG({ KEY = "Guest Present" })
check(
  "flag set: variables + event",
  vars["LAST_FLAG_KEY"] == "guest_present" and vars["LAST_FLAG_VALUE"] == "True" and firedCount(7) == 1
)
check("FLAG_SET = key true", TestCondition("FLAG_SET", { VALUE = "guest present", LOGIC = "EQUAL" }) == true)
check("FLAG_SET != key false", TestCondition("FLAG_SET", { VALUE = "guest present", LOGIC = "NOT_EQUAL" }) == false)
check(
  "FLAG_SET on an unknown key",
  TestCondition("FLAG_SET", { VALUE = "nobody", LOGIC = "EQUAL" }) == false
    and TestCondition("FLAG_SET", { VALUE = "nobody", LOGIC = "NOT_EQUAL" }) == true
)
EC.SET_FLAG({ KEY = "guest present" })
check("setting a set flag fires nothing", firedCount(7) == 1)
EC.TOGGLE_FLAG({ KEY = "guest present" })
check("toggle clears", vars["LAST_FLAG_VALUE"] == "False" and firedCount(7) == 2)
EC.CLEAR_FLAG({ KEY = "" })
check("empty key refused", prop("Last Refusal"):find("Clear Flag: empty key") ~= nil)

print("[4] state machine")
EC.SET_STATE({ STATE = "Evening" })
EC.SET_STATE({ STATE = "Evening" })
EC.SET_STATE({ STATE = "Night" })
check("variables", vars["CURRENT_STATE"] == "Night" and vars["PREVIOUS_STATE"] == "Evening")
check("State Changed fired twice (same state ignored)", firedCount(5) == 2)
check(
  "STATE_IS",
  TestCondition("STATE_IS", { VALUE = "Night", LOGIC = "EQUAL" }) == true
    and TestCondition("STATE_IS", { VALUE = "Night", LOGIC = "NOT_EQUAL" }) == false
)
check(
  "Last Trigger shows the state",
  prop("Last Trigger"):find("state → Night", 1, true) ~= nil,
  prop("Last Trigger")
)

print("[5] debounce")
EC.DEBOUNCE({ KEY = "hall motion", MILLISECONDS = "2000" })
advance(1500)
EC.DEBOUNCE({ KEY = "hall motion", MILLISECONDS = "2000" })
advance(1500)
check("not yet", firedCount(1) == 0)
advance(600)
check("Debounced Trigger once, key in variable", firedCount(1) == 1 and vars["LAST_TRIGGER_KEY"] == "hall_motion")

print("[6] throttle")
EC.THROTTLE({ KEY = "doorbell", MILLISECONDS = "60000" })
EC.THROTTLE({ KEY = "doorbell", MILLISECONDS = "60000" })
check("fires once within the window", firedCount(2) == 1 and vars["LAST_TRIGGER_KEY"] == "doorbell")
advance(61000)
EC.THROTTLE({ KEY = "doorbell", MILLISECONDS = "60000" })
check("fires again after the window", firedCount(2) == 2)

print("[7] once per day (local calendar day)")
EC.ONCE_PER_DAY({ KEY = "Morning Greeting" })
EC.ONCE_PER_DAY({ KEY = "Morning Greeting" })
check("passed once today", firedCount(3) == 1 and vars["ONCE_KEY"] == "morning_greeting")
check(
  "ONCE_TODAY_DONE = key",
  TestCondition("ONCE_TODAY_DONE", { VALUE = "morning greeting", LOGIC = "EQUAL" }) == true
)
advance(24 * 3600 * 1000)
EC.ONCE_PER_DAY({ KEY = "morning greeting" })
check("passes again the next day", firedCount(3) == 2)

print("[8] timers")
EC.START_TIMER({ KEY = "Bath Fan", SECONDS = "600" })
check("TIMER_RUNNING = key", TestCondition("TIMER_RUNNING", { VALUE = "bath fan", LOGIC = "EQUAL" }) == true)
advance(599000)
check("not yet expired", firedCount(4) == 0)
advance(2000)
check(
  "Timer Expired, key, not late",
  firedCount(4) == 1 and vars["LAST_TIMER_KEY"] == "bath_fan" and vars["LAST_TIMER_LATE"] == "False"
)
check("no longer running", TestCondition("TIMER_RUNNING", { VALUE = "bath fan", LOGIC = "EQUAL" }) == false)
EC.START_TIMER({ KEY = "porch", SECONDS = "30" })
EC.CANCEL_TIMER({ KEY = "porch" })
advance(60000)
check("cancelled timer never fires", firedCount(4) == 1)
EC.START_TIMER({ KEY = "porch", SECONDS = "0" })
check("zero seconds refused", prop("Last Refusal"):find("Start Timer: SECONDS must be more than 0") ~= nil)

print("[9] Print State does not throw and summary paints")
EC.REFRESH_STATUS()
check(
  "summary line",
  prop("Summary"):find("counter%(s%)") ~= nil and prop("Summary"):find("state: Night") ~= nil,
  prop("Summary")
)
check("print state runs", pcall(EC.PRINT_STATE))

print("[10] persistence across a reload: counters, flags, state, a future timer and a late one")
EC.SET_FLAG({ KEY = "armed" })
EC.START_TIMER({ KEY = "soon", SECONDS = "100" })
EC.START_TIMER({ KEY = "later", SECONDS = "1000" })
advance(2500) -- persist timer
check(
  "state persisted",
  persisted["lp_state_v1"] ~= nil
    and persisted["lp_state_v1"].flags.armed == true
    and persisted["lp_state_v1"].timers.soon ~= nil
)
OnDriverDestroyed()
clock.timers = {}
fired = {}
vars = {}
clock.now = clock.now + 200000 -- 200 s of downtime
OnDriverInit()
OnDriverLateInit("DIT_UPDATING")
check("restored: state variables repainted", vars["CURRENT_STATE"] == "Night" and vars["PREVIOUS_STATE"] == "Evening")
check("restored: counters back on their slots", vars["COUNTER_2"] == 4 and vars["COUNTER_1"] == 2)
check("restored: flag", TestCondition("FLAG_SET", { VALUE = "armed", LOGIC = "EQUAL" }) == true)
advance(0)
check(
  "overdue timer fired at once and is marked late",
  firedCount(4) == 1 and vars["LAST_TIMER_KEY"] == "soon" and vars["LAST_TIMER_LATE"] == "True"
)
check("future timer still running", TestCondition("TIMER_RUNNING", { VALUE = "later", LOGIC = "EQUAL" }) == true)
advance(801000)
check("and fires with its remaining time", firedCount(4) == 2 and vars["LAST_TIMER_LATE"] == "False")

print("[11] licence enforcement: read-only, then restored")
fired = {}
EC.SBOS_ENTITLEMENT({
  sku = "SBOS_LOGIC_PACK",
  status = "CLOUD_VALIDATION_REQUIRED",
  registered = "true",
  enforcement = "enforce",
})
check("uncertain status changes nothing", prop("Pack Status") == "active" and firedCount(8) == 0)
EC.SBOS_ENTITLEMENT({ sku = "SBOS_LOGIC_PACK", status = "NOT_ENTITLED", registered = "true", enforcement = "enforce" })
check(
  "definitive denial + enforce → read-only, event 8",
  prop("Pack Status") == "read-only (licence)" and firedCount(8) == 1 and TC.PACK_ACTIVE() == false
)
EC.INCREMENT_COUNTER({ KEY = "visits" })
check(
  "commands refused and named",
  vars["COUNTER_2"] == 4 and prop("Last Refusal"):find("read%-only") ~= nil,
  prop("Last Refusal")
)
check("reads still answer", TestCondition("STATE_IS", { VALUE = "Night", LOGIC = "EQUAL" }) == true)
EC.SBOS_ENTITLEMENT({ sku = "SBOS_LOGIC_PACK", status = "NOT_ENTITLED", registered = "true", enforcement = "observe" })
check("observe mode restores, event 9", prop("Pack Status") == "active" and firedCount(9) == 1)
EC.INCREMENT_COUNTER({ KEY = "visits" })
check("commands work again", vars["COUNTER_2"] == 5)

print("[12] reset scopes")
fired = {}
EC.RESET_ALL({ WHAT = "Counters" })
check("counters reset with events", vars["COUNTER_2"] == 0 and vars["COUNTER_1"] == 0 and firedCount(6) >= 2)
check("flags untouched by a counter reset", TestCondition("FLAG_SET", { VALUE = "armed", LOGIC = "EQUAL" }) == true)
EC.RESET_FLAGS_ACTION()
check("flags cleared", TestCondition("FLAG_SET", { VALUE = "armed", LOGIC = "EQUAL" }) == false)
EC.RESET_EVERYTHING_ACTION()
check("state cleared with an event", vars["CURRENT_STATE"] == "" and firedCount(5) >= 1)
check("unknown WHAT falls back to everything safely", pcall(EC.RESET_ALL, { WHAT = "Nonsense" }))

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
