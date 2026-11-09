package.path = "src/?.lua;" .. package.path
local T = require("tracer.tracer")
local Catalog = require("tracer.catalog")
local Ring = require("tracer.ring")
local pass, fail = 0, 0
local function check(name, ok, detail)
  if ok then
    pass = pass + 1
    print("  ok   " .. name)
  else
    fail = fail + 1
    print("  FAIL " .. name .. (detail ~= nil and ("  -> " .. tostring(detail)) or ""))
  end
end
local function count(t)
  local n = 0
  for _ in pairs(t) do
    n = n + 1
  end
  return n
end
local function types(list)
  local out = {}
  for _, e in ipairs(list) do
    out[#out + 1] = e.event_type
  end
  return table.concat(out, " ")
end

-- ── a fake Director ─────────────────────────────────────────────────────────
local clock = { t = 1000 }
local registered = {}
local regCalls, unregCalls = 0, 0
local failRegisterFor = {} -- "dev:ev" -> true
local emitted = {}
local learnedSaves = 0
local devices = {
  [12] = { deviceName = "Kitchen Pendants", driverFileName = "light.c4z", roomId = 3, roomName = "Kitchen" },
  [20] = { deviceName = "Garage Door", driverFileName = "contact.c4z", roomId = 7, roomName = "Garage" },
  [30] = { deviceName = "Mystery Box", driverFileName = "mystery.c4z", roomId = 1, roomName = "Entry" },
  [50] = { deviceName = "SmartBuildOS Agent", driverFileName = "smartbuildos.c4z" },
  [999] = { deviceName = "Event Tracer", driverFileName = "smartbuildos-event-tracer.c4z" },
}
local builtin = {
  ["light.c4z"] = { [1] = "Top Button Pushed", [2] = "Bottom Button Pushed", [3] = "Toggle" },
  ["contact.c4z"] = { [1] = "Opened", [2] = "Closed" },
  ["smartbuildos.c4z"] = { [1] = "Connected", [2] = "Disconnected" },
}
local projectXml = nil
local catalog = Catalog.new({ builtin = builtin })
local deps = {
  now = function()
    return clock.t
  end,
  register = function(d, e)
    regCalls = regCalls + 1
    if failRegisterFor[d .. ":" .. e] then
      error("Director refused")
    end
    registered[d .. ":" .. e] = true
    return true
  end,
  unregister = function(d, e)
    unregCalls = unregCalls + 1
    registered[d .. ":" .. e] = nil
  end,
  devices = function()
    return devices
  end,
  catalog = catalog,
  emit = function(f)
    emitted[#emitted + 1] = f
  end,
  selfDeviceId = 999,
  projectXml = function()
    return projectXml
  end,
  onLearned = function()
    learnedSaves = learnedSaves + 1
  end,
}
local function reset()
  emitted = {}
end
local function emittedOf(eventType)
  local out = {}
  for _, e in ipairs(emitted) do
    if e.event_type == eventType then
      out[#out + 1] = e
    end
  end
  return out
end

print("== policy validation")
local p, refusals = T.validatePolicy({})
check("empty policy → defaults, no refusals", p.enabled == true and #refusals == 0 and p.storm_threshold == 30)
p, refusals =
  T.validatePolicy({ storm_threshold = "abc", events_per_minute = 99999, probe_range = 10, probe_unknown = "On" })
check(
  "bad fields fall back and are listed",
  p.storm_threshold == 30 and p.events_per_minute == 300 and #refusals == 2,
  #refusals
)
check("good fields kept; Composer On/Off accepted", p.probe_range == 10 and p.probe_unknown == true)
p = T.validatePolicy({ exclude_device_ids = "12, 20;x", exclude_driver_files = { "a.c4z", " b.c4z " } })
check("csv ids parsed", #p.exclude_device_ids == 2 and p.exclude_device_ids[2] == 20)
check("driver file list trimmed", p.exclude_driver_files[2] == "b.c4z")
local nilP, r0 = T.validatePolicy("nope")
check("non-table refused", nilP == nil and r0[1].path == "policy")

print("== apply: zero-config coverage")
local tr = T.new(deps)
local summary = tr:apply(T.defaultPolicy())
check("subscriptions: 3 + 2 + 2 (self and unknown skipped)", summary.subscriptions == 7, summary.subscriptions)
check("self excluded", summary.devices_excluded == 1 and registered["999:1"] == nil)
check("unknown driver counted, not subscribed", summary.devices_unknown == 1 and registered["30:1"] == nil)
check("covered devices", summary.devices_covered == 3)
check("all builtin tier", summary.by_tier.builtin == 7 and summary.by_tier.probe == 0)
check("register called once per subscription", regCalls == 7)
check(
  "tracer.applied emitted with summary",
  #emittedOf("tracer.applied") == 1 and emittedOf("tracer.applied")[1].payload.subscriptions == 7
)
check("status capturing", tr:status() == "capturing")
local cov = tr:coverageList()
check(
  "coverage list sorted by device id, includes the unknown device",
  #cov == 4 and cov[1].device_id == 12 and cov[3].tier == nil
)

print("== identical re-apply touches nothing")
reset()
regCalls, unregCalls = 0, 0
tr:apply(T.defaultPolicy())
check("no register/unregister on identical re-apply", regCalls == 0 and unregCalls == 0)
check("summary added/removed are zero", tr.summary.added == 0 and tr.summary.removed == 0)

print("== capture")
reset()
check("event we subscribed to → true", tr:onDeviceEvent(12, 1) == true)
check("ring holds it", tr:latest().event_name == "Top Button Pushed" and tr:latest().device_label == "Kitchen Pendants")
local cap = emittedOf("capture.event")
check("capture.event emitted", #cap == 1)
check(
  "envelope fields",
  cap[1].device_id == 12
    and cap[1].room_id == 3
    and cap[1].evidence_source == "observed"
    and cap[1].quality == "confirmed"
)
check("label device: event", cap[1].label == "Kitchen Pendants: Top Button Pushed", cap[1].label)
check(
  "payload carries driver, ids, tier",
  cap[1].payload.driver == "light.c4z" and cap[1].payload.event_id == 1 and cap[1].payload.tier == "builtin"
)
check("unexpected event → false and counted", tr:onDeviceEvent(30, 1) == false and tr.counters.unexpected == 1)
check("counters", tr.counters.captured == 1 and tr.counters.emitted >= 1)

print("== marks")
reset()
check("mark recorded", tr:mark("  Good Night started ", "from keypad", 12) == true)
check("empty mark refused", tr:mark("   ") == false)
local marks = emittedOf("capture.mark")
check(
  "capture.mark emitted, instrumented, trimmed",
  #marks == 1 and marks[1].evidence_source == "instrumented" and marks[1].label == "Good Night started"
)
check("ring has the mark", tr:latest().kind == "mark" and tr.counters.marks == 1)
check("formatEntry for a mark", T.formatEntry(tr:latest()):find("MARK") ~= nil)
check(
  "formatEntry for an event",
  T.formatEntry(tr:recent(2)[1]):find("Kitchen / Kitchen Pendants: Top Button Pushed", 1, true) ~= nil,
  T.formatEntry(tr:recent(2)[1])
)

print("== storm")
reset()
local before = tr.counters.captured
for _ = 1, 45 do
  tr:onDeviceEvent(20, 1)
end
check("one tracer.storm at the threshold", #emittedOf("tracer.storm") == 1)
check(
  "the threshold event itself is recorded, the rest suppressed",
  tr.counters.captured == before + 30,
  tr.counters.captured - before
)
check("suppressed counted", tr.counters.storm_suppressed == 15, tr.counters.storm_suppressed)
check("capture.event count matches recorded", #emittedOf("capture.event") == 30)
local storms = tr:activeStorms()
check("activeStorms lists it", #storms == 1 and storms[1].device_label == "Garage Door" and storms[1].count == 45)
check("other keys unaffected", tr:onDeviceEvent(20, 2) == true and tr.counters.storm_suppressed == 15)
reset()
clock.t = clock.t + 61
tr:tick()
check(
  "tick closes the storm after the minute",
  #emittedOf("tracer.storm_ended") == 1 and emittedOf("tracer.storm_ended")[1].payload.suppressed == 15
)
check("storm bookkeeping forgotten", #tr:activeStorms() == 0)
reset()
for _ = 1, 31 do
  tr:onDeviceEvent(20, 1)
end
clock.t = clock.t + 61
tr:onDeviceEvent(20, 1)
check(
  "storm also ends on the next event after the window",
  #emittedOf("tracer.storm_ended") == 1 and #emittedOf("tracer.storm") == 1
)
reset()
local noStorm = T.validatePolicy({ storm_threshold = 0 })
tr:apply(noStorm)
for _ = 1, 40 do
  tr:onDeviceEvent(12, 2)
end
check("threshold 0 disables storms", #emittedOf("tracer.storm") == 0 and #emittedOf("capture.event") == 40)
tr:apply(T.defaultPolicy())

print("== budget")
reset()
clock.t = clock.t + 61
local tight = T.validatePolicy({ events_per_minute = 5, storm_threshold = 0 })
tr:apply(tight) -- the applied event itself goes straight to emit (not budgeted)
reset()
local ringBefore = tr.ring:count()
for i = 1, 8 do
  tr:onDeviceEvent(12, (i % 3) + 1)
end
check("5 capture.events uploaded, 3 dropped", #emittedOf("capture.event") == 5 and tr.counters.dropped_budget == 3)
check("one budget warning", #emittedOf("tracer.budget_exceeded") == 1)
check("ring still got all 8 (local history is not budgeted)", tr.ring:count() == ringBefore + 8)
clock.t = clock.t + 61
reset()
tr:onDeviceEvent(12, 1)
check("budget resets with the minute", #emittedOf("capture.event") == 1)
tr:apply(T.defaultPolicy())

print("== probe + learn")
reset()
regCalls = 0
local probe = T.validatePolicy({ probe_unknown = true, probe_range = 8 })
summary = tr:apply(probe)
check("unknown device probed with 8 ids", summary.by_tier.probe == 8 and registered["30:8"] and not registered["30:9"])
check("devices_unknown now 0", summary.devices_unknown == 0 and summary.devices_covered == 4)
check("only the probe ids were newly registered", regCalls == 8)
reset()
check("probe event captured", tr:onDeviceEvent(30, 3) == true)
check(
  "learned once, persisted once",
  tr.counters.learned == 1 and learnedSaves == 1 and #emittedOf("tracer.learned") == 1
)
check(
  "unknown name flagged in the capture",
  emittedOf("capture.event")[1].quality == "unknown" and emittedOf("capture.event")[1].payload.name_known == false
)
tr:onDeviceEvent(30, 3)
check("second occurrence learns nothing", tr.counters.learned == 1 and learnedSaves == 1)
reset()
regCalls, unregCalls = 0, 0
summary = tr:apply(T.defaultPolicy())
check(
  "probe off: learned id survives as a learned-tier subscription",
  summary.by_tier.learned == 1 and summary.by_tier.probe == 0 and registered["30:3"]
)
check("the other 7 probe ids were unregistered", unregCalls == 7, unregCalls)

print("== project XML tier")
reset()
projectXml = [[<item><id>1</id><itemdata/><subitems>
<item><id>30</id><name>Mystery Box</name><type>6</type><itemdata><driver>mystery.c4z</driver><events><event><id>3</id><name>Boom</name></event><event><id>4</id><name>Bang</name></event></events></itemdata></item>
</subitems></item>]]
summary = tr:apply(T.defaultPolicy())
check("project tier used for the mystery device", summary.by_tier.project == 2 and registered["30:4"])
tr:onDeviceEvent(30, 3)
check(
  "learned id now has its project name",
  emittedOf("capture.event")[1].payload.event_name == "Boom" and emittedOf("capture.event")[1].quality == "confirmed"
)
projectXml = nil
tr:apply(T.defaultPolicy())

print("== exclusions and cap")
reset()
summary = tr:apply(T.validatePolicy({ exclude_device_ids = { 12 }, exclude_driver_files = { "smartbuildos.c4z" } }))
check(
  "excluded device and driver file dropped",
  summary.devices_excluded == 3 and registered["12:1"] == nil and registered["50:1"] == nil
)
check("remaining: contact 2 + learned mystery 1", summary.subscriptions == 3, summary.subscriptions)
summary = tr:apply(T.validatePolicy({ max_subscriptions = 4 }))
check(
  "cap: ascending device order, 4 of 8 subscribed",
  summary.subscriptions == 4 and registered["12:3"] and registered["20:1"] and not registered["20:2"]
)
-- Left out: 20:2, the learned 30:3, 50:1, 50:2 → 4 events on 3 devices.
check(
  "unsubscribed events counted per device",
  summary.unsubscribed_events == 4 and summary.devices_partial == 3 and tr:coverageList()[2].unsubscribed == 1,
  tostring(summary.unsubscribed_events) .. "/" .. tostring(summary.devices_partial)
)
check("a device with every event cut is not counted as covered", summary.devices_covered == 2)

print("== register failure")
reset()
tr:apply(T.validatePolicy({ exclude_device_ids = { 12, 20, 30, 50 } }))
failRegisterFor["12:2"] = true
summary = tr:apply(T.defaultPolicy())
check(
  "a refused registration is counted and not kept",
  summary.register_failures == 1 and tr.subs["12:2"] == nil and tr.counters.subscriptions == summary.subscriptions - 1
)
failRegisterFor = {}
tr:apply(T.defaultPolicy())

print("== project change")
reset()
devices[40] = { deviceName = "New Lock", driverFileName = "contact.c4z", roomId = 1, roomName = "Entry" }
summary = tr:onProjectChanged()
check("new device picked up", summary.added == 2 and registered["40:1"])
devices[40] = nil
summary = tr:onProjectChanged()
check("removed device unsubscribed", summary.removed == 2 and registered["40:1"] == nil)

print("== pause / resume / stop")
reset()
check("pause releases everything", tr:pause("test") == true and count(registered) == 0 and tr:status() == "paused")
check("pause twice → false", tr:pause("again") == false)
check(
  "events while paused are not ours (nothing is subscribed)",
  tr:onDeviceEvent(12, 1) == false and #emittedOf("capture.event") == 0
)
check("onProjectChanged while paused does nothing", tr:onProjectChanged() == nil)
check(
  "resume re-applies",
  tr:resume("test") == true and count(registered) == tr.counters.subscriptions and tr:status() == "capturing"
)
check("resume twice → false", tr:resume("x") == false)
check("paused/resumed events", #emittedOf("tracer.paused") == 1 and #emittedOf("tracer.resumed") == 1)
tr:apply(T.validatePolicy({ enabled = false }))
check("disabled policy releases and reports", count(registered) == 0 and tr:status() == "disabled")
tr:apply(T.defaultPolicy())
tr:stop()
check("stop releases everything", count(registered) == 0 and tr:subscriptionCount() == 0)

print("== restored ring")
local doc = tr.ring:serialize()
local restored = Ring.restore(doc)
local tr2 = T.new({
  now = deps.now,
  register = deps.register,
  unregister = deps.unregister,
  devices = deps.devices,
  catalog = catalog,
  emit = deps.emit,
  selfDeviceId = 999,
  ring = restored,
})
check("a restored ring continues the sequence", tr2.ring.seq == tr.ring.seq and tr2:latest() ~= nil)
tr2:apply(T.validatePolicy({ ring_size = 60 }))
check("apply resizes the ring to the policy", tr2.ring.capacity == 60)

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
