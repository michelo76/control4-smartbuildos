package.path = "src/?.lua;" .. package.path
local R = require("flightrecorder.recorder")
local C = require("flightrecorder.config")
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

-- A fake Director: variables per device, listener bookkeeping, scheduled timers.
local clock = { t = 1000 }
local timers = {}
local registered = {}
local regCalls, unregCalls = 0, 0
local emitted = {}
local vars = {
  [12] = {
    ["1001"] = { name = "LIGHT_LEVEL", value = "40" },
    ["1002"] = { name = "LIGHT_STATE", value = "True" },
    ["1003"] = { name = "SCENE_NAME", value = "Evening" },
  },
  [20] = { ["2001"] = { name = "ContactState", value = "Closed" } },
}
local deps = {
  now = function()
    return clock.t
  end,
  schedule = function(key, ms, fn)
    timers[key] = { at = clock.t + ms / 1000, fn = fn }
  end,
  cancel = function(key)
    timers[key] = nil
  end,
  register = function(d, v)
    regCalls = regCalls + 1
    registered[d .. ":" .. v] = true
    return true
  end,
  unregister = function(d, v)
    unregCalls = unregCalls + 1
    registered[d .. ":" .. v] = nil
  end,
  readVariables = function(d)
    return vars[d]
  end,
  emit = function(f)
    emitted[#emitted + 1] = f
  end,
  selfDeviceId = 999,
  deviceLabel = function(d)
    return "Device " .. d
  end,
  roomOf = function(d)
    return { id = 3, name = "Kitchen" }
  end,
}
local function advance(seconds)
  local target = clock.t + seconds
  while true do
    local bestK, bestT
    for k, t in pairs(timers) do
      if t.at <= target and (bestT == nil or t.at < bestT) then
        bestK, bestT = k, t.at
      end
    end
    if not bestK then
      break
    end
    clock.t = bestT
    local t = timers[bestK]
    timers[bestK] = nil
    t.fn()
  end
  clock.t = target
end
local function ofType(tp)
  local out = {}
  for _, e in ipairs(emitted) do
    if e.event_type == tp then
      out[#out + 1] = e
    end
  end
  return out
end
local function last()
  return emitted[#emitted]
end
local function cfg(sources, extra)
  local raw = { version = 1, sources = sources }
  for k, v in pairs(extra or {}) do
    raw[k] = v
  end
  local c, ref = C.validate(raw)
  assert(c, ref and ref[1] and (ref[1].path .. " " .. ref[1].reason))
  return c
end

print("[1] apply: initial observations, not changes; unknown previous stays unknown")
local r = R.new(deps)
r:apply(cfg({
  { kind = "device_variable", device_id = 12, variable = "LIGHT_LEVEL", label = "Kitchen lights" },
  { kind = "device_variable", device_id = 20, variable = "ContactState" },
}))
local init = ofType("observation.initial")
check("two initial observations", #init == 2)
check(
  "initial carries the value, previous_known=false, typed",
  init[1].payload.previous_known == false and (init[1].payload.value == 40 or init[1].payload.value == "Closed")
)
check("config_applied emitted", last().event_type == "recorder.config_applied" and last().payload.listeners == 2)
check("two listeners registered", regCalls == 2 and r:listenerCount() == 2)
check("labels + room attached", init[1].room_id == 3 and init[1].payload.device_label:find("Device") ~= nil)
r:onChange(12, 1001, "60")
local ch = ofType("observation.change")
check(
  "first change after initial read knows its previous",
  #ch == 1 and ch[1].payload.previous == 40 and ch[1].payload.previous_known == true and ch[1].payload.value == 60
)

print("[2] re-apply the same config registers nothing twice")
regCalls, unregCalls = 0, 0
r:apply(cfg({
  { kind = "device_variable", device_id = 12, variable = "LIGHT_LEVEL", label = "Kitchen lights" },
  { kind = "device_variable", device_id = 20, variable = "ContactState" },
}))
check("no register/unregister", regCalls == 0 and unregCalls == 0 and r:listenerCount() == 2)
check("no new initial observations", #ofType("observation.initial") == 2)

print("[3] reconcile removes dropped sources and adds new ones")
r:apply(cfg({ { kind = "device_variable", device_id = 12, variable = "LIGHT_STATE" } }))
check("one removed... two removed, one added", unregCalls == 2 and regCalls == 1 and r:listenerCount() == 1)
check("removed source no longer ours", r:onChange(12, 1001, "70") == false)

print("[4] debounce: last value wins, one event")
emitted = {}
r = R.new(deps)
r:apply(cfg({ { kind = "device_variable", device_id = 12, variable = "LIGHT_LEVEL", debounce_ms = 1500 } }))
r:onChange(12, 1001, "10")
r:onChange(12, 1001, "20")
r:onChange(12, 1001, "30")
check("nothing yet", #ofType("observation.change") == 0)
advance(2)
local d = ofType("observation.change")
check("one event with the last value", #d == 1 and d[1].payload.value == 30 and d[1].payload.previous == 40)

print("[5] min_change against the last emitted value")
emitted = {}
r = R.new(deps)
r:apply(cfg({ { kind = "device_variable", device_id = 12, variable = "LIGHT_LEVEL", min_change = 5 } }))
r:onChange(12, 1001, "42")
r:onChange(12, 1001, "44")
check("small steps ignored", #ofType("observation.change") == 0 and r.counters.below_min_change == 2)
r:onChange(12, 1001, "46")
check(
  "drift surfaces once it adds up (40→46)",
  #ofType("observation.change") == 1 and ofType("observation.change")[1].payload.previous == 40
)

print("[6] coalesce: a burst becomes first event + one coalesced event")
emitted = {}
r = R.new(deps)
r:apply(cfg({ { kind = "device_variable", device_id = 12, variable = "LIGHT_LEVEL", coalesce_ms = 3000 } }))
r:onChange(12, 1001, "50")
check("first change immediate", #ofType("observation.change") == 1)
r:onChange(12, 1001, "60")
r:onChange(12, 1001, "70")
r:onChange(12, 1001, "80")
check("burst held", #ofType("observation.change") == 1)
advance(4)
local co = ofType("observation.change")
check(
  "one coalesced event: 50→80 ×3",
  #co == 2 and co[2].payload.coalesced == 3 and co[2].payload.previous == 50 and co[2].payload.value == 80
)
r:onChange(12, 1001, "90")
check("after the window, immediate again", #ofType("observation.change") == 3)

print("[7] unchanged re-announcements are not changes")
r:onChange(12, 1001, "90")
check("ignored", #ofType("observation.change") == 3)

print("[8] budget: dropped and counted, one warning per minute")
emitted = {}
r = R.new(deps)
r:apply(
  cfg(
    { { kind = "device_variable", device_id = 12, variable = "LIGHT_LEVEL" } },
    { budgets = { events_per_minute = 5 } }
  )
)
for i = 1, 20 do
  r:onChange(12, 1001, tostring(i))
end
check("budget respected", #ofType("observation.change") <= 5)
check("dropped counted", r.counters.dropped_budget > 0)
check("one budget warning", #ofType("recorder.budget_exceeded") == 1)
advance(61)
r:onChange(12, 1001, "100")
check("new minute records again", ofType("observation.change")[#ofType("observation.change")].payload.value == 100)

print("[9] string values: flagged, or excluded by policy; fixed exclusions never register")
emitted = {}
r = R.new(deps)
r:apply(cfg({ { kind = "device_variable", device_id = 12, variable = "SCENE_NAME" } }))
check("initial string flagged unreviewed_text", ofType("observation.initial")[1].quality == "unreviewed_text")
r:onChange(12, 1003, "Night")
check("change flagged", ofType("observation.change")[1].quality == "unreviewed_text")
emitted = {}
r = R.new(deps)
r:apply(
  cfg(
    { { kind = "device_variable", device_id = 12, variable = "SCENE_NAME" } },
    { privacy = { string_values = "exclude" } }
  )
)
r:onChange(12, 1003, "Party")
check(
  "excluded strings never emitted",
  #ofType("observation.initial") == 0 and #ofType("observation.change") == 0 and r.counters.dropped_string == 2
)
emitted = {}
r = R.new(deps)
r:apply(cfg({
  { kind = "device_variable", device_id = 12, variable = "LIGHT_LEVEL" },
  { kind = "device_variable", device_id = 12, variable = "SCENE_NAME" },
}, { exclusions = { variable_patterns = { "SCENE_*" } } }))
check("pattern exclusion keeps the listener off", r:listenerCount() == 1 and r.counters.excluded == 1)

print("[10] self is never a source")
emitted = {}
r = R.new(deps)
vars[999] = { ["1"] = { name = "BUFFERED_EVENTS", value = "3" } }
r:apply(cfg({ { kind = "device_variable", device_id = 999, variable = "BUFFERED_EVENTS" } }))
check("self excluded", r:listenerCount() == 0 and r.counters.excluded == 1)

print("[11] pause / resume / stop clean up and re-read")
emitted = {}
timers = {}
r = R.new(deps)
r:apply(cfg({ { kind = "device_variable", device_id = 12, variable = "LIGHT_LEVEL", debounce_ms = 1000 } }))
r:onChange(12, 1001, "1")
check("debounce timer armed", next(timers) ~= nil)
unregCalls = 0
r:pause("tech")
check(
  "paused: listener and timer gone, event emitted",
  r:listenerCount() == 0 and next(timers) == nil and unregCalls == 1 and last().event_type == "recorder.paused"
)
check("changes while paused are not recorded", r:onChange(12, 1001, "2") == false)
r:resume("tech")
check("resumed re-reads as initial", ofType("observation.initial")[2] ~= nil and r:listenerCount() == 1)
unregCalls = 0
r:stop()
check("stop unregisters everything", unregCalls == 1 and r:listenerCount() == 0)

print("[12] stale and unsupported mappings are reported")
emitted = {}
r = R.new(deps)
local s = r:apply(cfg({
  { kind = "device_variable", device_id = 77, variable = "X" },
  { kind = "device_variable", device_id = 12, variable = "NOPE" },
}))
check("reported", s.stale == 1 and s.unsupported == 1 and s.listeners == 0)

print("[13] sbos events are recorded only when selected")
emitted = {}
r = R.new(deps)
r:apply(cfg({ { kind = "sbos_event", event = "director_reloaded" } }))
check("unselected ignored", r:onSbosEvent("clock_drift", {}) == false)
check(
  "selected recorded",
  r:onSbosEvent("director_reloaded", { kind = "reload" }) == true
    and last().event_type == "observation.system"
    and last().evidence_source == "system"
)

print("[14] observations snapshot")
local obs = r:observations()
check("empty for event-only config", #obs == 0)

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
