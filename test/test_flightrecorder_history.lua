-- flightrecorder.history: what a recorded event looks like in the local
-- history. Pure: an envelope in, a short entry (or nothing) out.
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

local H = require("flightrecorder.history")
local T = require("tracer.tracer")

local function line(entry)
  entry.seq, entry.t = 1, 1000
  return (T.formatEntry(entry, 1000):gsub("^%S+%s+#%d+%s+", ""))
end
local labels = {
  device = function(id)
    return id == 12 and "Hall Light" or nil
  end,
}

print("[1] variable changes")
local change = H.entryFor({
  event_type = "observation.change",
  device_id = 12,
  label = "Hall light level",
  payload = {
    variable = "LIGHT_LEVEL",
    device_label = "Hall Light",
    room_label = "Hall",
    value = 0,
    previous = 75,
    previous_known = true,
    coalesced = 3,
  },
})
check(
  "a change keeps the device, the variable and both values",
  line(change) == "Hall / Hall Light: LIGHT_LEVEL 75 → 0 (3 changes)",
  line(change)
)
check("numbers stay numbers", type(change.value) == "number" and change.device_id == 12)
local unknown = H.entryFor({
  event_type = "observation.change",
  device_id = 12,
  payload = { variable = "LIGHT_LEVEL", device_label = "Hall Light", value = 0, previous_known = false },
})
check("an unknown previous value stays unknown", unknown.previous_known == false and unknown.previous == nil)
local initial = H.entryFor({
  event_type = "observation.initial",
  device_id = 12,
  payload = { variable = "LIGHT_LEVEL", device_label = "Hall Light", value = 75, previous_known = false },
})
check(
  "a first read is marked as one",
  initial.initial == true and line(initial):find("first read, not a change", 1, true) ~= nil
)
local falsy = H.entryFor({
  event_type = "observation.change",
  payload = { variable = "OPEN", device_label = "Door", value = false, previous = true, previous_known = true },
})
check("false is a value", falsy.value == false and line(falsy) == "Door: OPEN true → false", line(falsy))
local text = H.entryFor({
  event_type = "observation.change",
  payload = { variable = "TITLE", device_label = "Player", value = string.rep("word ", 200), previous_known = false },
})
check("a long text value is cut before it is stored", #text.value == H.LIMITS.value)
local nameless = H.entryFor(
  { event_type = "observation.change", device_id = 12, payload = { variable = "LIGHT_LEVEL", value = 1 } },
  labels
)
check("a device the envelope does not name is looked up", nameless.device_label == "Hall Light")
local unnamed =
  H.entryFor({ event_type = "observation.change", device_id = 99, payload = { variable = "X", value = 1 } }, labels)
check(
  "and one that cannot be named falls back to its id",
  unnamed.device_label == nil and line(unnamed):find("^99: X") ~= nil,
  line(unnamed)
)

local coded = H.entryFor({
  event_type = "observation.change",
  payload = {
    variable = "USER_CODE",
    device_label = "Front Lock",
    value = "4711",
    previous = "1234",
    previous_known = true,
  },
})
check(
  "a variable named like a code never shows its values, before or after",
  line(coded) == "Front Lock: USER_CODE [redacted] → [redacted]" and line(coded):find("4711", 1, true) == nil,
  line(coded)
)
local blob = H.entryFor({
  event_type = "observation.change",
  payload = { variable = "STATE", device_label = "Bridge", value = string.rep("a1B2", 12), previous_known = false },
})
check(
  "a value that looks like a credential is hidden whatever its variable is called",
  blob.value == "[redacted]",
  tostring(blob.value)
)
local level = H.entryFor({
  event_type = "observation.change",
  payload = { variable = "LIGHT_LEVEL", device_label = "Hall Light", value = "1234", previous_known = false },
})
check("an ordinary number in text is not mistaken for one", level.value == "1234")

print("[2] programming: markers and traces")
local mark = H.entryFor({
  event_type = "observation.programmed",
  device_id = 12,
  label = "Good Night",
  payload = { name = "Good Night", detail = "from the hall keypad" },
})
check(
  "RECORD_EVENT is a marker",
  mark.kind == "mark" and line(mark) == "MARK  Good Night  — from the hall keypad",
  line(mark)
)
local start = H.entryFor({
  event_type = "trace.start",
  correlation_id = "t-1",
  label = "Good Night",
  payload = { channel = "night", trace_id = "t-1", name = "Good Night" },
})
check("a trace start", line(start) == "TRACE night  start  Good Night" and start.trace_id == "t-1", line(start))
local step = H.entryFor({
  event_type = "trace.step",
  correlation_id = "t-1",
  label = "Hall light off",
  device_id = 12,
  payload = { channel = "night", trace_id = "t-1", step = 1, kind = "step" },
}, labels)
check(
  "a step carries its number and the device it names",
  line(step) == "TRACE night  step 1  Hall light off  [Hall Light]",
  line(step)
)
local decision = H.entryFor({
  event_type = "trace.decision",
  label = "Front door closed",
  payload = { channel = "night", trace_id = "t-1", step = 2, condition = "Front door closed", outcome = "yes" },
})
check(
  "a decision reads condition → outcome",
  line(decision) == "TRACE night  decision 2  Front door closed → yes",
  line(decision)
)
local expects = H.entryFor({
  event_type = "trace.expected",
  label = "Hall light at 0",
  payload = { channel = "night", trace_id = "t-1", step = 3 },
})
check(
  "an expected result is worded as an expectation, not a fact",
  line(expects) == "TRACE night  expects 3  Hall light at 0",
  line(expects)
)
local done = H.entryFor({
  event_type = "trace.end",
  label = "Good Night",
  payload = {
    channel = "night",
    trace_id = "t-1",
    status = "completed",
    note = "all off",
    steps = 3,
    duration_seconds = 12,
  },
})
check(
  "the end says how it ended, why, and how long it took",
  line(done) == "TRACE night  end  completed; all off; 3 step(s), 12 s" and done.status == "completed",
  line(done)
)
local failed = H.entryFor({
  event_type = "trace.end",
  label = "Morning",
  payload = {
    channel = "day",
    trace_id = "t-2",
    status = "failed",
    reason = "shade offline",
    note = "ignored",
    steps = 1,
    duration_seconds = 0,
  },
})
check(
  "a failure gives its reason before any note",
  line(failed) == "TRACE day  end  failed; shade offline; 1 step(s), 0 s",
  line(failed)
)
local orphan =
  H.entryFor({ event_type = "trace.orphan_step", label = "Shades up", payload = { channel = "day", kind = "step" } })
check("a step with no trace open is shown as one", line(orphan) == "TRACE day  no trace open  Shades up", line(orphan))

check("a marker outside a trace belongs to none", mark.trace_id == nil)
local inTrace = H.entryFor({
  event_type = "observation.programmed",
  correlation_id = "t-1",
  label = "Doors checked",
  payload = { name = "Doors checked", channel = "night" },
})
check("a marker recorded while a trace is open carries that trace's id", inTrace.trace_id == "t-1")
check("the start and the end keep the trace's name", start.name == "Good Night" and done.name == "Good Night")
check("a step does not carry it", step.name == nil)

print("[3] system notices, storms and the recorder's own notes")
local system = H.entryFor({
  event_type = "observation.system",
  label = "Controller restarts",
  payload = { event = "unexpected_restart" },
})
check("a SmartBuildOS event", line(system) == "SYSTEM  unexpected_restart", line(system))
local storm =
  H.entryFor({ event_type = "tracer.storm", device_id = 20, label = "Event storm: Front Door: Opened", payload = {} })
check(
  "a storm explains why the list goes quiet",
  storm.kind == "note" and storm.device_id == 20 and line(storm):find("counted, not listed", 1, true) ~= nil,
  line(storm)
)
local ended = H.entryFor({
  event_type = "tracer.storm_ended",
  label = "Storm ended: Front Door: Opened",
  payload = { count = 50, suppressed = 20 },
})
check(
  "and its end gives the totals",
  line(ended) == "NOTE  Storm ended: Front Door: Opened (50 in the minute, 20 not listed)",
  line(ended)
)
for _, t in ipairs({
  "recorder.paused",
  "recorder.resumed",
  "recorder.config_applied",
  "recorder.config_refused",
  "snapshot.requested",
}) do
  local e = H.entryFor({ event_type = t, label = "Label of " .. t, payload = {} })
  check(t .. " is a note with its label", e ~= nil and e.kind == "note" and e.text == "Label of " .. t)
end

print("[4] what stays out")
check(
  "a device event is not converted: the capture engine already holds it",
  H.entryFor({ event_type = "capture.event", payload = {} }) == nil
)
check("nor a capture marker", H.entryFor({ event_type = "capture.mark", payload = {} }) == nil)
check("nor the capture summary", H.entryFor({ event_type = "tracer.applied", payload = {} }) == nil)
check("an unknown type is left out, not guessed", H.entryFor({ event_type = "something.else", payload = {} }) == nil)
check(
  "something that is not an envelope is nothing",
  H.entryFor(nil) == nil and H.entryFor("x") == nil and H.entryFor({}) == nil
)
check("an envelope without a payload does not throw", pcall(H.entryFor, { event_type = "observation.change" }))

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
