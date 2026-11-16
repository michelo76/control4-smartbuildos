package.path = "src/?.lua;" .. package.path
local E = require("logic.engine")
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

-- ── simulated clock, timers, calendar ───────────────────────────────────────
local clock = { t = 1000000 }
local timers = {}
local emitted = {}
local DAY = 86400
local deps = {
  now = function()
    return clock.t
  end,
  schedule = function(id, ms, fn)
    timers[id] = { at = clock.t + ms / 1000, fn = fn }
  end,
  cancel = function(id)
    timers[id] = nil
  end,
  emit = function(kind, fields)
    emitted[#emitted + 1] = { kind = kind, fields = fields }
  end,
  -- Local day = floor(t / DAY) with a 5-hour offset, so "midnight" is not
  -- a multiple of 86400 in UTC and the roll is a real local roll.
  localDay = function(t)
    return "day-" .. tostring(math.floor((t - 5 * 3600) / DAY))
  end,
}
local function advance(seconds)
  local target = clock.t + seconds
  while true do
    local bestId, bestAt
    for id, t in pairs(timers) do
      if t.at <= target and (bestAt == nil or t.at < bestAt or (t.at == bestAt and id < bestId)) then
        bestId, bestAt = id, t.at
      end
    end
    if not bestId then
      break
    end
    clock.t = bestAt
    local t = timers[bestId]
    timers[bestId] = nil
    t.fn()
  end
  clock.t = target
end
local function ofKind(kind)
  local out = {}
  for _, e in ipairs(emitted) do
    if e.kind == kind then
      out[#out + 1] = e.fields
    end
  end
  return out
end
local function reset()
  emitted = {}
end

print("== keys")
check("trim, lower, punctuation → underscore", E.key("  Good Night! ") == "good_night")
check("collapses runs and strips edges", E.key("__a--b__") == "a_b")
check("empty → nil", E.key("   ") == nil and E.key(nil) == nil)
check("bounded to 40", #E.key(string.rep("k", 80)) == 40)

print("== compare (Director LOGIC vocabulary)")
check("EQUAL/NOT_EQUAL on strings", E.compare("EQUAL", "a", "a") and E.compare("NOT_EQUAL", "a", "b"))
check(
  "numeric comparisons",
  E.compare("GREATER_THAN_OR_EQUAL", 5, 5) and E.compare("LESS_THAN", 4, 5) and not E.compare("GREATER_THAN", 4, 5)
)
check("numeric logic on non-numbers is false", E.compare("LESS_THAN", "x", 5) == false)
check("unknown logic is false", E.compare("WHATEVER", 1, 1) == false)
check("nil logic defaults to EQUAL", E.compare(nil, 3, 3) == true)

print("== counters")
local e = E.new(deps)
check("increment default by 1", select(2, e:increment("Visits")) == 1 and e:counter("visits") == 1)
check("increment by 5", select(2, e:increment("visits", "5")) == 6)
check("decrement", select(2, e:decrement("visits")) == 5)
check("set", select(2, e:setCounter("visits", 42)) == 42)
check("reset", select(2, e:resetCounter("visits")) == 0 and e:counter("visits") == 0)
check("unknown counter reads 0", e:counter("nothing") == 0)
check("counter events carry key and value", #ofKind("counter") == 5 and ofKind("counter")[4].value == 42)
check("non-integer BY refused", e:increment("visits", "1.5") == false and e.counts.refused == 1)
check("empty key refused", e:increment("  ") == false)
check("clamped at the bound", select(2, e:setCounter("big", 5e9)) == E.LIMITS.counter_abs)
check(
  "setting the same value is not a change",
  (function()
    reset()
    e:setCounter("visits", 0)
    return #ofKind("counter") == 0
  end)()
)
reset()
for i = 1, E.LIMITS.keys_per_kind + 5 do
  e:increment("k" .. i)
end
local n = 0
for _ in pairs(e.counters) do
  n = n + 1
end
check("key cap per kind", n == E.LIMITS.keys_per_kind and e.counts.refused >= 5, n)
e = E.new(deps)
reset()

print("== flags")
check("set", e:setFlag("Guest Present") and e:flag("guest_present") == true)
check(
  "set again is not a change",
  (function()
    reset()
    e:setFlag("guest present")
    return #ofKind("flag") == 0
  end)()
)
check("toggle clears", select(2, e:toggleFlag("guest present")) == false and e:flag("guest present") == false)
check("toggle of an unknown flag sets it", select(2, e:toggleFlag("new")) == true)
check("clear", e:clearFlag("new") and e:flag("new") == false)
check(
  "clear of an unknown flag is fine and silent",
  (function()
    reset()
    return e:clearFlag("ghost") and #ofKind("flag") == 0
  end)()
)

print("== state")
reset()
check("first state", select(2, e:setState("Evening")) == true and e:stateIs("Evening"))
check("same state again is not a change", select(2, e:setState("Evening")) == false and #ofKind("state") == 1)
check("new state records previous", select(2, e:setState("Night")) == true and e.previousState == "Evening")
check(
  "event carries state and previous",
  ofKind("state")[2].state == "Night" and ofKind("state")[2].previous == "Evening"
)
check("stateIs trims", e:stateIs("  Night "))
check("empty state refused", e:setState("") == false)
check(
  "transitions newest first and bounded",
  (function()
    for i = 1, 15 do
      e:setState("s" .. i)
    end
    return #e.transitions == E.LIMITS.transitions and e.transitions[1].to == "s15"
  end)()
)

print("== debounce")
reset()
e:debounce("motion", 2000)
e:debounce("motion", 2000)
advance(1.5)
e:debounce("motion", 2000)
advance(1.5)
check("not yet fired: each call restarted the quiet timer", #ofKind("debounced") == 0)
advance(1)
check("fires once after quiet", #ofKind("debounced") == 1 and ofKind("debounced")[1].key == "motion")
check("counts", e.counts.debounce_calls == 3 and e.counts.debounce_fired == 1)
reset()
e:debounce("motion", 0)
check("ms 0 fires immediately", #ofKind("debounced") == 1)
check("negative ms refused", e:debounce("motion", -5) == false)
check(
  "ms is capped",
  (function()
    e:debounce("slow", 1e12)
    return timers["lp:d:slow"].at - clock.t <= E.LIMITS.ms_max / 1000
  end)()
)
e:cancelTimer("x")
timers = {}

print("== throttle")
reset()
check("first call fires", select(2, e:throttle("door", 60000)) == true)
check(
  "second within window suppressed",
  select(2, e:throttle("door", 60000)) == false and e.counts.throttle_suppressed == 1
)
advance(59)
check("still suppressed at 59 s", select(2, e:throttle("door", 60000)) == false)
advance(2)
check("fires again after the window", select(2, e:throttle("door", 60000)) == true and #ofKind("throttled") == 2)
check("window 0 always fires", select(2, e:throttle("door", 0)) == true)

print("== once per day (local midnight roll)")
reset()
clock.t = 5 * 3600 + 10 * DAY + 23 * 3600 + 59 * 60 -- 23:59 local on day 10
check("first pass today", select(2, e:oncePerDay("Greeting")) == true and e:onceDoneToday("greeting"))
check("second pass refused", select(2, e:oncePerDay("greeting")) == false and e.counts.once_refused == 1)
advance(120) -- 00:01 local, day 11
check("passes again after local midnight (not 24 h)", select(2, e:oncePerDay("greeting")) == true)
check("event carries the day", ofKind("once_per_day")[2].day == "day-11")
e:oncePerDay("other")
e.once["other"] = "day-3"
e:pruneOnce()
check("prune drops old days, keeps today", e.once["other"] == nil and e.once["greeting"] == "day-11")

print("== timers")
reset()
check("start", e:startTimer("Bath Fan", 600) and e:timerRunning("bath fan"))
check("remaining", math.abs(e:timerRemaining("bath_fan") - 600) < 0.001)
advance(300)
check(
  "restart re-arms from now",
  e:startTimer("bath fan", 600) and math.abs(e:timerRemaining("bath_fan") - 600) < 0.001
)
advance(599)
check("not yet expired", #ofKind("timer_expired") == 0)
advance(2)
check(
  "expired once",
  #ofKind("timer_expired") == 1
    and ofKind("timer_expired")[1].key == "bath_fan"
    and ofKind("timer_expired")[1].late == false
)
check("not running after expiry", e:timerRunning("bath fan") == false and e:timerRemaining("bath fan") == nil)
e:startTimer("porch", 30)
check("cancel → true, stops it", select(2, e:cancelTimer("porch")) == true and e:timerRunning("porch") == false)
check("cancel of nothing → false, not an error", select(2, e:cancelTimer("porch")) == false)
advance(60)
check("cancelled timer never fires", #ofKind("timer_expired") == 1)
check("zero or negative seconds refused", e:startTimer("x", 0) == false and e:startTimer("x", -3) == false)
check(
  "seconds capped",
  (function()
    e:startTimer("long", 1e9)
    return e.timers["long"].seconds == E.LIMITS.timer_seconds_max
  end)()
)
e:cancelTimer("long")

print("== read-only")
e:setFlag("armed")
reset()
e:setReadOnly(true)
check(
  "mutations refused",
  e:increment("visits") == false
    and e:setFlag("x") == false
    and e:setState("y") == false
    and e:startTimer("t", 5) == false
    and e:oncePerDay("o") == false
    and e:debounce("d", 10) == false
    and e:throttle("th", 10) == false
    and e:resetAll() == false
)
check("nothing emitted", #emitted == 0)
check("reads still answer", e:flag("armed") == true and e:stateIs("s15"))
e:setReadOnly(false)

print("== persistence")
reset()
e:resetAll("everything")
e:setCounter("visits", 7)
e:setFlag("armed")
e:setState("Away")
e:oncePerDay("greeting")
e:throttle("door", 1000)
e:startTimer("soon", 100)
e:startTimer("later", 1000)
local doc = e:serialize()
check(
  "document shape",
  doc.v == 1
    and doc.counters.visits == 7
    and doc.flags.armed == true
    and doc.state == "Away"
    and doc.timers.soon.seconds == 100
)
-- A restart 200 s later: "soon" is overdue, "later" has 800 s left.
timers = {}
local e2 = E.new(deps)
clock.t = clock.t + 200
reset()
check("restore ok", e2:restore(doc) == true)
check(
  "counters/flags/state/once/throttle restored",
  e2:counter("visits") == 7
    and e2:flag("armed")
    and e2:stateIs("Away")
    and e2:onceDoneToday("greeting")
    and e2.throttleLast.door ~= nil
)
advance(0)
check(
  "overdue timer fired at once, marked late",
  #ofKind("timer_expired") == 1 and ofKind("timer_expired")[1].key == "soon" and ofKind("timer_expired")[1].late == true
)
check("future timer re-armed with remaining time", math.abs(e2:timerRemaining("later") - 800) < 0.001)
advance(801)
check("and fires on time", #ofKind("timer_expired") == 2 and ofKind("timer_expired")[2].late == false)
check("corrupt document → false, engine empty", E.new(deps):restore("junk") == false)
local e3 = E.new(deps)
e3:restore({ counters = { ["Bad Key!"] = 3, ok = "x" }, flags = { f = "yes", g = true }, state = 42 })
check(
  "restore normalises keys and drops bad values",
  e3:counter("bad_key") == 3 and e3:counter("ok") == 0 and e3:flag("g") and not e3:flag("f") and e3.state == ""
)

print("== resetAll scopes")
reset()
e2:resetAll("counters")
check("counters reset to zero with events", e2:counter("visits") == 0 and #ofKind("counter") == 1 and e2:flag("armed"))
e2:resetAll("flags")
check("flags cleared", e2:flag("armed") == false)
e2:startTimer("t1", 50)
e2:resetAll("timers")
check("timers cancelled", e2:timerRunning("t1") == false)
e2:resetAll("everything")
check("everything: state cleared with an event", e2.state == "" and ofKind("state")[#ofKind("state")].state == "")

print("== snapshot")
e2:setCounter("b", 2)
e2:setCounter("a", 1)
e2:setFlag("z")
e2:startTimer("m", 10)
local snap = e2:snapshot()
check("sorted counters", snap.counters[1].key == "a" and snap.counters[2].key == "b")
check(
  "flags, timers, counts present",
  snap.flags[1] == "z" and snap.timers[1].key == "m" and type(snap.counts.refused) == "number"
)
e2:stop()
check("stop cancels timers", timers["lp:t:m"] == nil)

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
