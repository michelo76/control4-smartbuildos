-- aicore.collector (pure): the D7 split (what AI Core collects itself
-- depending on the Flight Recorder), admission (pause, exclusions, budget,
-- dedup) before anything is recorded, consuming published envelopes, and
-- the system-event names it reads.
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

local Collector = require("aicore.collector")
local Config = require("aicore.config")

print("[1] the collection plan (no double capture)")
local cfg = Config.default()
check(
  "default: every collection source off",
  not cfg.collection.system_events and not cfg.collection.flight_recorder_topics and not cfg.collection.agent_events
)
local d = Collector.plan("present", cfg, true)
check(
  "default document, even active: nothing subscribed or registered",
  not d.subscribe and not d.system_events and not d.agent_events and not d.variables
)
d = Collector.plan("absent", cfg, true)
check("default document, FR absent: no own collection either", not d.system_events and not d.agent_events)
cfg.collection.system_events = true
cfg.collection.flight_recorder_topics = true
cfg.collection.agent_events = true
cfg.collection.variables = { { device_id = 12, variable = "LIGHT_STATE" } }
local p = Collector.plan("present", cfg, true)
check("FR present: subscribe to its topics", p.subscribe)
check("FR present: no own variable listeners", not p.variables)
check("FR present: Agent events left to FR", not p.agent_events)
check("FR present: Director system events still own (FR does not capture them)", p.system_events)
p = Collector.plan("absent", cfg, true)
check("FR absent: nothing to subscribe to", not p.subscribe)
check("FR absent: own variables (configured)", p.variables)
check("FR absent: own Agent events", p.agent_events)
p = Collector.plan("present_v1", cfg, true)
check(
  "an old FR still captures its classes: no own duplicates",
  not p.variables and not p.agent_events and not p.subscribe
)
p = Collector.plan("unknown", cfg, true)
check("unknown (cannot discover): conservative, no own duplicates", not p.variables and not p.agent_events)
p = Collector.plan("absent", cfg, false)
check(
  "inactive (paused/unlicensed): nothing at all",
  not p.subscribe and not p.variables and not p.agent_events and not p.system_events
)
local none = Config.default()
none.collection.system_events = true
check("FR absent but no variables configured: none listened", not Collector.plan("absent", none, true).variables)
none.collection.system_events = false
check("system events can be switched off by config", not Collector.plan("absent", none, true).system_events)
check(
  "topics are exactly what the policy grants",
  table.concat(Collector.FR_TOPICS, ",") == "capture.,observation.,trace."
)

print("[2] admission")
local t = 0
local c = Collector.new({
  now = function()
    return t
  end,
})
check("a new collector admits nothing until a policy is applied", select(2, c:admit({ category = "x" })) == "paused")
c:setPolicy({
  active = true,
  excludedRooms = { [9] = true },
  excludedCategories = { security = true },
  maxPerMinute = 3,
})
check("admitted", c:admit({ id = "a", room_id = 3, category = "lighting" }) == true)
check("duplicate id", select(2, c:admit({ id = "a", category = "lighting" })) == "duplicate")
check("excluded room", select(2, c:admit({ room_id = 9, category = "lighting" })) == "excluded_room")
check("excluded category", select(2, c:admit({ category = "security" })) == "excluded_category")
c:admit({ category = "x" })
c:admit({ category = "x" })
check("over the per-minute budget", select(2, c:admit({ category = "x" })) == "over_budget")
t = 61
check("budget window rolls", c:admit({ category = "x" }) == true)
c:setPolicy({ active = false })
check("paused before anything else", select(2, c:admit({ id = "new", category = "lighting" })) == "paused")
check(
  "counters",
  c.counters.paused == 2 and c.counters.excluded_room == 1 and c.counters.duplicate == 1 and c.counters.over_budget == 1
)

print("[3] consuming Flight Recorder envelopes")
local c2 = Collector.new({
  now = function()
    return 0
  end,
})
c2:setPolicy({ active = true, excludedRooms = { [9] = true }, maxPerMinute = 1 })
local events = {
  { event_id = "fr:1", event_type = "capture.event", room_id = 3, payload = {} },
  { event_id = "fr:2", event_type = "observation.change", room_id = 9, payload = { category = "lighting" } },
  { event_id = "fr:1", event_type = "capture.event", room_id = 3, payload = {} },
  { event_id = "fr:3", event_type = "trace.step", payload = {} },
  { event_type = "capture.event" },
}
local admitted = c2:consume(events, 5)
check("dedup + exclusion applied; budget not re-applied (FR budgets)", #admitted == 2, #admitted)
check("drops the Agent reported are counted", c2.counters.consumed_dropped_by_agent == 5)
check("category from the recorder's config", Collector.categoryOf(events[2]) == "lighting")
check("trace → programming", Collector.categoryOf(events[4]) == "programming")
check("a device event's category is unknown, not guessed", Collector.categoryOf(events[1]) == "unknown")

print("[4] system-event names")
check("name attribute", Collector.systemEventName('<event name="OnDeviceOffline" id="49">') == "OnDeviceOffline")
check("<name> element", Collector.systemEventName("<x><name>OnDeviceOnline</name></x>") == "OnDeviceOnline")
check("bare name", Collector.systemEventName("OnDirectorIPAddressChanged") == "OnDirectorIPAddressChanged")
check(
  "unreadable → nil, never guessed",
  Collector.systemEventName("<x/>") == nil and Collector.systemEventName(nil) == nil
)
local ids = {}
for _, e in ipairs(Collector.SYSTEM_EVENTS) do
  ids[#ids + 1] = e.id
end
check("only API-reference-documented ids", table.concat(ids, ",") == "17,18,19,20,48,49,90")
check("device offline is critical", Collector.SYSTEM_BY_NAME.OnDeviceOffline.severity == "warning")

print("[marker] AI_RECORD_EVENT: admitMarker ignores learning, honours exclusions")
local m = Collector.new({
  now = function()
    return 0
  end,
})
m:setPolicy({
  active = false,
  excludedRooms = { [3] = true },
  excludedCategories = { security = true },
  maxPerMinute = 1,
})
check("learning off: admit refuses (paused)", select(2, m:admit({ category = "general" })) == "paused")
check("learning off: admitMarker admits", m:admitMarker({ category = "general" }) == true)
check("excluded room refused", select(2, m:admitMarker({ room_id = 3, category = "general" })) == "excluded_room")
check("excluded category refused", select(2, m:admitMarker({ category = "security" })) == "excluded_category")
check(
  "not budgeted, not deduplicated: the same marker twice beyond the budget",
  m:admitMarker({ category = "general" }) and m:admitMarker({ category = "general" })
)

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
