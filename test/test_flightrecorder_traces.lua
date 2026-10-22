package.path = "src/?.lua;" .. package.path
local T = require("flightrecorder.traces")
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
local clock = { t = 1000 }
local emitted = {}
local ids = 0
local function newT(over)
  emitted = {}
  local opts = {
    now = function()
      return clock.t
    end,
    emit = function(f)
      emitted[#emitted + 1] = f
    end,
    newId = function(ch)
      ids = ids + 1
      return ch .. "-" .. ids
    end,
  }
  for k, v in pairs(over or {}) do
    opts[k] = v
  end
  return T.new(opts)
end
local function last()
  return emitted[#emitted]
end

print("[1] a complete trace on the default channel")
local t = newT()
local id = t:start("", "Good Night")
check("started on main", id == "main-1" and last().event_type == "trace.start" and last().payload.channel == "main")
t:step("", "Lights off requested", 12)
check(
  "step carries correlation + step index + device",
  last().event_type == "trace.step"
    and last().correlation_id == id
    and last().payload.step == 1
    and last().device_id == 12
)
t:decision("", "garage open?", "no")
check("decision", last().event_type == "trace.decision" and last().payload.outcome == "no" and last().payload.step == 2)
t:expected("", "Kitchen at 0%", 12)
check(
  "expected result is evidence_source=requested",
  last().event_type == "trace.expected" and last().evidence_source == "requested"
)
clock.t = 1010
check(
  "complete",
  t:complete("", "done") == true
    and last().event_type == "trace.end"
    and last().payload.status == "completed"
    and last().payload.duration_seconds == 10
    and last().payload.steps == 3
)
check("nothing active", t:activeCount() == 0)

print("[2] duplicate completion is recorded, not applied")
check(
  "duplicate",
  t:complete("", "again") == false
    and last().event_type == "trace.duplicate_completion"
    and last().severity == "warning"
)
check("counted", t.counters.duplicates == 1)

print("[3] orphan steps are visible and unattached")
t:step("garage", "checked")
check(
  "orphan",
  last().event_type == "trace.orphan_step" and last().correlation_id == nil and last().payload.channel == "garage"
)

print("[4] overlapping executions on one channel: the earlier is interrupted, never merged")
t = newT()
local a = t:start("good_night", "Good Night")
t:step("good_night", "first run")
local b = t:start("good_night", "Good Night")
check("distinct ids", a ~= b)
check(
  "earlier interrupted",
  emitted[3].event_type == "trace.end" and emitted[3].payload.status == "interrupted" and emitted[3].correlation_id == a
)
t:step("good_night", "second run")
check("new step attaches to b", last().correlation_id == b and last().payload.step == 1)

print("[5] two channels run concurrently and stay distinct")
t = newT()
local gn = t:start("good_night", "Good Night")
local gc = t:start("garage", "Garage check")
t:step("garage", "contact read")
t:step("good_night", "lights")
check("steps routed by channel", emitted[3].correlation_id == gc and emitted[4].correlation_id == gn)
check("two active", t:activeCount() == 2 and #t:activeList() == 2)
t:fail("garage", "contact unreadable")
check("fail", last().payload.status == "failed" and last().correlation_id == gc and t:activeCount() == 1)

print("[6] bounded active count")
t = newT({ maxActive = 2 })
t:start("a", "A")
t:start("b", "B")
local refused, why = t:start("c", "C")
check("refused", refused == nil and why == "too_many_active" and last().event_type == "trace.refused")

print("[7] timeout → abandoned; reload → interrupted")
t = newT({ timeoutSeconds = 100 })
clock.t = 2000
t:start("x", "X")
clock.t = 2050
check("not yet", t:tick() == 0)
clock.t = 2101
check("abandoned", t:tick() == 1 and last().payload.status == "abandoned")
t:start("y", "Y")
t:interruptAll("driver reload")
check(
  "interrupted on reload",
  last().payload.status == "interrupted" and last().payload.reason == "driver reload" and t:activeCount() == 0
)

print("[8] bounds")
t = newT()
t:start(string.rep("c", 100), string.rep("n", 200))
check("channel and name bounded", #last().payload.channel == T.LIMITS.channel and #last().payload.name == T.LIMITS.name)
t:step(string.rep("c", 100), string.rep("m", 1000))
check("message bounded", #last().payload.message == T.LIMITS.message)

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
