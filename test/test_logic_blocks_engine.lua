-- Logic Blocks RUNTIME (src/logic/blocks.lua + blockdefs.lua), no controller.
--
-- The invariants a dealer and a programmer rely on, each pinned here:
--   * every block type's rule, at its boundaries;
--   * an unchanged value fires nothing; a refused input changes nothing;
--   * an input that cannot be read is UNKNOWN, never false or zero;
--   * opening values and restored state fire nothing;
--   * a slot's variables are written before its event fires;
--   * inputs that arrive during an event are queued, in order;
--   * a runaway block is isolated and the others keep working;
--   * identity survives a rename, a retired slot is not reused;
--   * a stored document is never silently reset.
--
-- Run from the driver root: make test

package.path = "src/?.lua;test/?.lua;" .. package.path
local H = require("logic_blocks_harness")
local Blocks = require("logic.blocks")
local Defs = require("logic.blockdefs")

local c = H.checker()
local check = c.check

local function new(opts)
  local w = H.world(opts)
  return Blocks.new(w.deps), w
end

-- ── Definitions ─────────────────────────────────────────────────────────────

do
  check("duration: 10m", Defs.parseDuration("10m") == 600000)
  check("duration: 1h30m", Defs.parseDuration("1h30m") == 5400000)
  check("duration: 500ms", Defs.parseDuration("500ms") == 500)
  check("duration: 2 min", Defs.parseDuration("2 min") == 120000)
  check("duration: bare number is seconds", Defs.parseDuration("45") == 45000)
  check("duration: junk refused", Defs.parseDuration("soon") == nil)
  check("duration: empty refused", Defs.parseDuration("") == nil)
  check("duration: negative refused", Defs.parseDuration("-5") == nil)
  for _, ms in ipairs({ 500, 1000, 90000, 600000, 5400000, 86400000 }) do
    check("durationText round trip " .. ms, Defs.parseDuration(Defs.durationText(ms)) == ms, Defs.durationText(ms))
  end
  check("number: nan refused", Defs.number("nan") == nil and Defs.number(0 / 0) == nil)
  check("number: inf refused", Defs.number("inf") == nil and Defs.number(math.huge) == nil)
  check("number: words refused", Defs.number("warm") == nil)
  check("number: decimals", Defs.number("77.9") == 77.9)
  check("boolean: plain words", Defs.boolean("On") == true and Defs.boolean("no") == false)
  check("boolean: unexpected value is not a boolean", Defs.boolean("closed") == nil)
  check("boolean: true-when list", Defs.boolean("Closed", Defs.wordList("closed,1")) == true)
  check("boolean: true-when list, other value is false", Defs.boolean("open", Defs.wordList("closed,1")) == false)

  local seen = {}
  local unique = true
  for slot = 1, 32 do
    for k = 1, #Defs.EVENTS do
      local id = Defs.eventId(slot, k)
      unique = unique and not seen["e" .. id] and id > 9
      seen["e" .. id] = true
    end
    for k = 1, #Defs.VARIABLES do
      local id = Defs.variableId(slot, k)
      unique = unique and not seen["v" .. id] and (id < 3000 or id > 3020)
      seen["v" .. id] = true
    end
    for k = 1, #Defs.CONDITIONALS do
      local id = Defs.conditionalId(slot, k)
      unique = unique and not seen["c" .. id] and id > 13
      seen["c" .. id] = true
    end
  end
  check("slot ids are unique and clear of the legacy ids, out to 32 slots", unique)
  check("slot ids do not depend on capacity", Defs.eventId(3, "passed") == 1031 and Defs.variableId(3, 1) == 4031)
  check("parseSlot: label", Defs.parseSlot("Block 03") == 3)
  check("parseSlot: number then a name", Defs.parseSlot("07 · Anything, renamed") == 7)
  check("parseSlot: out of range", Defs.parseSlot("Block 17") == nil and Defs.parseSlot("Block 0") == nil)
  check("parseSlot: nothing", Defs.parseSlot("") == nil and Defs.parseSlot(nil) == nil)

  local function bad(raw, needle)
    local def, problems = Defs.normalize(raw)
    local text = table.concat(problems or {}, " | ")
    return def == nil and text:lower():find(needle, 1, true) ~= nil, text
  end
  check("validate: unknown type", bad({ type = "magic", name = "x" }, "block type"))
  check("validate: empty name", bad({ type = "flag", name = "  " }, "name is empty"))
  check("validate: bad duration", bad({ type = "cooldown", name = "x", duration = "later" }, "duration"))
  check("validate: duration too long", bad({ type = "cooldown", name = "x", duration = "8d" }, "at most"))
  check(
    "validate: inverted thresholds",
    bad({ type = "threshold", name = "x", upper = "70", lower = "80", inputs = { { used = true, label = "t" } } }, "above upper")
  )
  check(
    "validate: equal thresholds are allowed",
    Defs.normalize({ type = "threshold", name = "x", upper = "70", lower = "70", inputs = { { used = true, label = "t" } } }) ~= nil
  )
  check(
    "validate: non-numeric threshold",
    bad({ type = "threshold", name = "x", upper = "hot", lower = "1", inputs = { { used = true, label = "t" } } }, "must be a number")
  )
  check("validate: threshold needs an input", bad({ type = "threshold", name = "x", upper = "2", lower = "1" }, "at least one input"))
  check("validate: selector needs two states", bad({ type = "selector", name = "x", states = "Home" }, "at least two"))
  check("validate: selector duplicate state", bad({ type = "selector", name = "x", states = "Home, home" }, "twice"))
  check(
    "validate: selector transition to an unknown state",
    bad({ type = "selector", name = "x", states = "A, B", transitions = "A > C" }, "not one of the states")
  )
  check(
    "validate: selector initial not in list",
    bad({ type = "selector", name = "x", states = "A, B", initial_state = "Z" }, "initial state")
  )
  check(
    "validate: device without variable",
    bad({ type = "stable", name = "x", duration = "5s", inputs = { { used = true, label = "m", device_id = 5 } } }, "both a device")
  )
  check(
    "validate: counter threshold must be whole",
    bad({ type = "counter", name = "x", counter_threshold = "2.5" }, "whole number")
  )
  check(
    "validate: every problem is reported at once",
    select(2, Defs.normalize({ type = "timer", name = "", duration = "x", repeat_start = "sometimes" })) ~= nil
      and #select(2, Defs.normalize({ type = "timer", name = "", duration = "x", repeat_start = "sometimes" })) == 3
  )
end

-- ── A. Cooldown ─────────────────────────────────────────────────────────────

do
  local b, w = new()
  local s = H.make(b, { type = "cooldown", name = "Driveway Welcome", duration = "10m" })
  b:input(s, "trigger")
  check("cooldown: first trigger passes", w.firedText() == s .. ":passed")
  w.advance(180)
  b:input(s, "trigger")
  check("cooldown: repeat is suppressed, nothing fires", w.count(s .. ":passed") == 1)
  local reason = H.last(b).reason
  check(
    "cooldown: the suppression says when it is eligible again",
    reason:find("passed 3 minutes ago") and reason:find("cooldown is 10 minutes") and reason:find("again in 7 minutes"),
    reason
  )
  b:input(s, "trigger")
  check("cooldown: suppression is counted", b:view(s).suppressed == 2 and b:outputs(s).value == 2)
  check("cooldown: next eligible time is reported", math.abs(b:view(s).deadline.at - (w.t - 180 + 600)) < 0.001)
  w.advance(419.999)
  b:input(s, "trigger")
  check("cooldown: one millisecond before the end is still suppressed", w.count(s .. ":passed") == 1)
  w.advance(0.001)
  check("cooldown: no trailing pass when the interval ends", w.count(s .. ":passed") == 1)
  check("cooldown: ready when the interval ends", b:outputs(s).state == "ready" and b:outputs(s).active == false)
  b:input(s, "trigger")
  check("cooldown: passes at exactly the interval", w.count(s .. ":passed") == 2)
  check("cooldown: suppression count restarts with a pass", b:view(s).suppressed == 0)
  b:input(s, "reset")
  b:input(s, "trigger")
  check("cooldown: reset clears the window", w.count(s .. ":passed") == 3)
  w.t = w.t - 3600 -- the controller clock is set back an hour
  b:input(s, "trigger")
  check("cooldown: a clock set backwards does not pass early", w.count(s .. ":passed") == 3)
  w.advance(600)
  b:input(s, "trigger")
  check("cooldown: a clock set backwards holds it for one interval at most", w.count(s .. ":passed") == 4)
  local long = H.make(b, { type = "cooldown", name = "Long", duration = "2h" })
  b:input(long, "trigger")
  w.advance(3601)
  b:input(long, "trigger")
  check("cooldown: an interval over the classic 1-hour ceiling is honoured", w.count(long .. ":passed") == 1)
  w.advance(3600)
  b:input(long, "trigger")
  check("cooldown: and passes once it has elapsed", w.count(long .. ":passed") == 2)
end

-- ── B. Quiet period ─────────────────────────────────────────────────────────

do
  local b, w = new()
  local s = H.make(b, { type = "quiet", name = "Hallway", duration = "20s" })
  b:input(s, "trigger")
  check("quiet: the first trigger of a burst fires Started", w.firedText() == s .. ":started")
  w.advance(10)
  b:input(s, "trigger")
  w.advance(19)
  b:input(s, "trigger")
  check("quiet: later triggers restart the countdown and fire nothing", w.firedText() == s .. ":started")
  check("quiet: the burst is counted", b:outputs(s).value == 3 and b:outputs(s).state == "waiting")
  w.advance(19.9)
  check("quiet: nothing passes before the quiet period", w.count(s .. ":passed") == 0)
  w.advance(0.1)
  check("quiet: passes once when triggers stop", w.count(s .. ":passed") == 1)
  w.advance(600)
  check("quiet: and only once", w.count(s .. ":passed") == 1 and b:outputs(s).state == "idle")
  b:input(s, "trigger")
  b:input(s, "cancel")
  check("quiet: cancel fires Cancelled", w.count(s .. ":cancelled") == 1)
  w.advance(600)
  check("quiet: a cancelled countdown never passes", w.count(s .. ":passed") == 1)
  w.clear()
  b:input(s, "cancel")
  check("quiet: cancelling nothing fires nothing", #w.fired == 0 and H.last(b).decision == "unchanged")
end

-- ── C. Restartable timer ────────────────────────────────────────────────────

do
  local b, w = new()
  local s = H.make(b, { type = "timer", name = "Bath", duration = "15m" })
  b:input(s, "start")
  check("timer: start fires Started", w.firedText() == s .. ":started")
  check("timer: running with a deadline", b:outputs(s).active and math.abs(b:view(s).deadline.at - (w.t + 900)) < 0.001)
  w.advance(600)
  b:input(s, "start")
  check("timer: a repeated start restarts and does not fire Started again", w.count(s .. ":started") == 1)
  w.advance(899)
  check("timer: the restarted countdown has not expired", w.count(s .. ":expired") == 0)
  w.advance(1)
  check("timer: expires once", w.count(s .. ":expired") == 1 and b:outputs(s).state == "idle")
  b:input(s, "start")
  b:input(s, "cancel")
  check("timer: cancel fires Cancelled", w.count(s .. ":cancelled") == 1)
  w.advance(2000)
  check("timer: a cancelled timer never expires", w.count(s .. ":expired") == 1)
  w.clear()
  b:input(s, "cancel")
  check("timer: cancelling nothing fires nothing", #w.fired == 0)
  b:input(s, "trigger")
  check("timer: BLOCK_TRIGGER starts it too", w.count(s .. ":started") == 1)

  local keep = H.make(b, { type = "timer", name = "Ignore", duration = "60s", repeat_start = "Ignore while running" })
  b:input(keep, "start")
  w.advance(40)
  b:input(keep, "start")
  check("timer (ignore): a start while running is suppressed with the reason", H.last(b).decision == "suppressed")
  w.advance(20)
  check("timer (ignore): the original deadline stands", w.count(keep .. ":expired") == 1)
  b:input(keep, "start")
  w.advance(40)
  b:input(keep, "restart")
  w.advance(59)
  check("timer (ignore): BLOCK_RESTART always restarts", w.count(keep .. ":expired") == 1)
  w.advance(1)
  check("timer (ignore): and expires from the restart", w.count(keep .. ":expired") == 2)
end

-- ── D. Once per day ─────────────────────────────────────────────────────────

do
  -- A zone that is UTC-5 until an instant, then UTC-4 (spring forward), so a
  -- local day is 23 hours long once. The calendar, not 24 hours, decides.
  local start = 1800000000
  local shiftAt = start + 3 * 86400
  local function localDay(t)
    local offset = t >= shiftAt and -4 * 3600 or -5 * 3600
    return os.date("!%Y-%m-%d", math.floor(t + offset))
  end
  local function nextMidnight(t)
    local day = localDay(t)
    local x = math.floor(t)
    while localDay(x) == day do
      x = x + 60
    end
    while localDay(x - 1) ~= day do
      x = x - 1
    end
    return x
  end
  local b, w = new({ start = start, localDay = localDay })
  local s = H.make(b, { type = "once", name = "Greeting" })
  b:input(s, "trigger")
  check("once: first trigger of the day passes", w.count(s .. ":passed") == 1)
  b:input(s, "trigger")
  check("once: the second is suppressed", w.count(s .. ":passed") == 1 and b:outputs(s).value == 1)
  check("once: active means done today", b:outputs(s).active == true and b:outputs(s).state == "done_today")
  local midnight = nextMidnight(w.t)
  w.t = midnight - 1
  b:input(s, "trigger")
  check("once: one second before local midnight is still today", w.count(s .. ":passed") == 1)
  w.t = midnight
  b:input(s, "trigger")
  check("once: passes again at local midnight, not 24 hours later", w.count(s .. ":passed") == 2)
  w.t = midnight + 60
  b:input(s, "trigger")
  check("once: and only once that day", w.count(s .. ":passed") == 2)
  -- Across the 23-hour day.
  local passes = w.count(s .. ":passed")
  for _ = 1, 4 do
    w.t = nextMidnight(w.t) + 30
    b:input(s, "trigger")
    b:input(s, "trigger")
    passes = passes + 1
  end
  check("once: exactly one pass per local day across a DST change", w.count(s .. ":passed") == passes)
  local today = localDay(w.t)
  w.t = w.t - 2 * 86400 -- the clock is set two days back
  b:input(s, "trigger")
  check("once: a clock set back to an earlier day does not pass again", w.count(s .. ":passed") == passes)
  check("once: and says why", H.last(b).reason:find(today, 1, true) ~= nil, H.last(b).reason)
  b:input(s, "reset")
  b:input(s, "trigger")
  check("once: reset forgets the pass", w.count(s .. ":passed") == passes + 1)
  b:tick(nil)
  check("once: the day basis is shown", b:view(s).day == localDay(w.t))
end

-- ── E. Flag ─────────────────────────────────────────────────────────────────

do
  local b, w = new()
  local s = H.make(b, { type = "flag", name = "Guest Override" })
  b:input(s, "set")
  check("flag: set fires Became True", w.firedText() == s .. ":became_true" and b:outputs(s).active)
  b:input(s, "set")
  check("flag: setting a set flag fires nothing", #w.fired == 1 and H.last(b).decision == "unchanged")
  b:input(s, "clear")
  check("flag: clear fires Became False", w.fired[2] == s .. ":became_false")
  b:input(s, "clear")
  check("flag: clearing a clear flag fires nothing", #w.fired == 2)
  b:input(s, "toggle")
  b:input(s, "toggle")
  check("flag: toggle flips both ways", w.fired[3] == s .. ":became_true" and w.fired[4] == s .. ":became_false")
  b:input(s, "set", { VALUE = "off" })
  check("flag: SET with a false value is a no-op when already off", #w.fired == 4)
  b:input(s, "set", { VALUE = "yes" })
  check("flag: SET with a true word turns it on", #w.fired == 5 and b:outputs(s).value == 1)
  b:input(s, "set", { VALUE = "maybe" })
  check("flag: an invalid value is refused and changes nothing", #w.refused == 1 and b:outputs(s).active == true)
  check("flag: a refused input is in the history with its reason", H.last(b).decision == "refused")
end

-- ── F. Counter ──────────────────────────────────────────────────────────────

do
  local b, w = new()
  local s = H.make(b, { type = "counter", name = "Visitors", counter_threshold = "3", counter_comparison = ">=" })
  b:input(s, "increment")
  b:input(s, "increment", { BY = "1" })
  check("counter: increments fire Value Changed", w.count(s .. ":value_changed") == 2 and b:outputs(s).value == 2)
  check("counter: below the threshold is not active", b:outputs(s).active == false)
  b:input(s, "increment")
  check("counter: reaching the threshold fires Became True once", w.count(s .. ":became_true") == 1)
  b:input(s, "increment", { BY = "5" })
  check("counter: staying over the threshold does not fire it again", w.count(s .. ":became_true") == 1)
  b:input(s, "set", { VALUE = "8" })
  check("counter: setting its own value fires nothing", w.count(s .. ":value_changed") == 4 and H.last(b).decision == "unchanged")
  b:input(s, "decrement", { BY = "6" })
  check("counter: leaving the threshold fires Became False", w.count(s .. ":became_false") == 1 and b:outputs(s).value == 2)
  b:input(s, "reset")
  check("counter: reset returns to zero", b:outputs(s).value == 0)
  b:input(s, "reset")
  check("counter: resetting zero fires nothing", H.last(b).decision == "unchanged")
  local before = #w.fired
  b:input(s, "increment", { BY = "1.5" })
  b:input(s, "set", { VALUE = "many" })
  check("counter: non-integers are refused", #w.refused == 2 and #w.fired == before and b:outputs(s).value == 0)
  b:input(s, "set", { VALUE = "5000000000" })
  check("counter: a value past the classic engine's bound is clamped to it", b:outputs(s).value == 1000000000)
  local changes = w.count(s .. ":value_changed")
  b:input(s, "increment", { BY = "10" })
  check("counter: and an increment at the bound is not a change", b:outputs(s).value == 1000000000 and w.count(s .. ":value_changed") == changes)
  b:input(s, "set", { VALUE = "-5000000000" })
  check("counter: the lower bound clamps too", b:outputs(s).value == -1000000000)
  local plain = H.make(b, { type = "counter", name = "Plain" })
  b:input(plain, "decrement")
  check("counter: goes negative; no threshold means never active", b:outputs(plain).value == -1 and not b:outputs(plain).active)
end

-- ── G. All / Any conditions ─────────────────────────────────────────────────

do
  local b, w = new()
  local all = H.make(b, {
    type = "conditions",
    name = "All",
    mode = "All",
    inputs = { { used = true, label = "A" }, { used = true, label = "B" } },
  })
  check("conditions: nothing read yet is unknown, not false", b:outputs(all).valid == false and b:outputs(all).state == "unknown")
  b:input(all, "input", { INPUT = "Input 1", VALUE = "true" })
  check("conditions ALL: true and unknown is unknown", b:outputs(all).valid == false and #w.fired == 0)
  b:input(all, "input", { INPUT = "Input 2", VALUE = "true" })
  check("conditions ALL: true and true fires Became True", w.firedText() == all .. ":became_true")
  b:input(all, "input", { INPUT = "2", VALUE = "true" })
  check("conditions: an unchanged result fires nothing", #w.fired == 1)
  b:input(all, "input_unavailable", { INPUT = "Input 2" })
  check("conditions ALL: true and unknown fires Faulted, not Became False", w.fired[2] == all .. ":faulted" and #w.fired == 2)
  check("conditions: unknown is reported as not valid", b:outputs(all).valid == false and b:outputs(all).active == false)
  b:input(all, "input_unavailable", { INPUT = "Input 2" })
  check("conditions: Faulted fires once, not on every unknown", #w.fired == 2)
  b:input(all, "input", { INPUT = "2", VALUE = "true" })
  check("conditions: readable again with the same result fires nothing", #w.fired == 2 and b:outputs(all).valid)
  b:input(all, "input", { INPUT = "1", VALUE = "false" })
  check("conditions ALL: false and true fires Became False", w.fired[3] == all .. ":became_false")
  b:input(all, "input_unavailable", { INPUT = "Input 2" })
  check("conditions ALL: false and unknown is FALSE (one false decides)", b:outputs(all).valid and #w.fired == 3)
  b:input(all, "trigger")
  check("conditions: a continuous block refuses BLOCK_TRIGGER", w.refused[#w.refused].why:find("continuous") ~= nil)
  b:input(all, "input", { INPUT = "3", VALUE = "true" })
  check("conditions: an input that is not configured is refused", w.refused[#w.refused].why:find("not configured") ~= nil)
  b:input(all, "input", { INPUT = "1", VALUE = "closed" })
  check("conditions: a value that is not true/false is refused", w.refused[#w.refused].why:find("not true/false") ~= nil)

  local any = H.make(b, {
    type = "conditions",
    name = "Any",
    mode = "Any",
    inputs = { { used = true, label = "A" }, { used = true, label = "B", true_when = "closed,locked" } },
  })
  w.clear()
  b:input(any, "input", { INPUT = "1", VALUE = "false" })
  check("conditions ANY: false or unknown is unknown", b:outputs(any).valid == false)
  b:input(any, "input", { INPUT = "2", VALUE = "Closed" })
  check("conditions ANY: a custom true-when value counts as true", w.firedText() == any .. ":became_true")
  b:input(any, "input_unavailable", { INPUT = "1" })
  check("conditions ANY: unknown or true is TRUE (one true decides)", b:outputs(any).valid and b:outputs(any).active and #w.fired == 1)
  b:input(any, "input", { INPUT = "2", VALUE = "open" })
  check("conditions ANY: unknown or false is unknown", w.fired[2] == any .. ":faulted")

  local gate = H.make(b, {
    type = "conditions",
    name = "Gate",
    mode = "All",
    evaluation = "Gate a trigger",
    inputs = { { used = true, label = "Night" }, { used = true, label = "Armed" } },
  })
  w.clear()
  b:input(gate, "trigger")
  check("gate: a trigger against unknown conditions does not pass", w.count(gate .. ":passed") == 0)
  check("gate: and fires Faulted so programming can react", w.count(gate .. ":faulted") == 1)
  b:input(gate, "input", { INPUT = "1", VALUE = "true" })
  b:input(gate, "input", { INPUT = "2", VALUE = "false" })
  check("gate: inputs alone fire nothing", w.count(gate .. ":became_true") == 0 and w.count(gate .. ":became_false") == 0)
  b:input(gate, "trigger")
  check("gate: a trigger while the conditions are false is suppressed", w.count(gate .. ":passed") == 0)
  check("gate: the suppression names the false input", H.last(b).reason:find("Armed") ~= nil, H.last(b).reason)
  b:input(gate, "input", { INPUT = "2", VALUE = "true" })
  b:input(gate, "trigger")
  check("gate: a trigger while the conditions hold passes", w.count(gate .. ":passed") == 1)
  check("gate: wiring lists Passed and not Became True", (function()
    local names = {}
    for _, o in ipairs(b:view(gate).wiring.outputs) do
      names[#names + 1] = o.event
    end
    local text = table.concat(names, ",")
    return text:find("Passed") ~= nil and text:find("Became True") == nil
  end)())
end

-- ── H. Threshold with deadband ──────────────────────────────────────────────

do
  local b, w = new()
  local s = H.make(b, { type = "threshold", name = "Rack", upper = "85", lower = "78", units = "F", inputs = { { used = true, label = "Temp" } } })
  check("threshold: no reading yet is unknown", b:outputs(s).valid == false)
  b:input(s, "input", { VALUE = "80" })
  check("threshold: a first reading inside the band is clear and fires nothing", b:outputs(s).valid and not b:outputs(s).active and #w.fired == 0)
  b:input(s, "input", { VALUE = "85" })
  check("threshold: exactly on the upper limit changes nothing", #w.fired == 0)
  b:input(s, "input", { VALUE = "85.1" })
  check("threshold: above the upper limit fires Became True", w.firedText() == s .. ":became_true")
  b:input(s, "input", { VALUE = "80" })
  check("threshold: back inside the band it stays active", b:outputs(s).active and #w.fired == 1)
  b:input(s, "input", { VALUE = "78" })
  check("threshold: exactly on the lower limit changes nothing", b:outputs(s).active and #w.fired == 1)
  b:input(s, "input", { VALUE = "77.9" })
  check("threshold: below the lower limit fires Became False", w.fired[2] == s .. ":became_false")
  b:input(s, "set", { VALUE = "90" })
  check("threshold: BLOCK_SET is the same input", w.fired[3] == s .. ":became_true" and b:outputs(s).value == 90)
  b:input(s, "input", { VALUE = "warm" })
  check("threshold: a non-number is refused; the last reading stands", #w.refused == 1 and b:outputs(s).active and b:outputs(s).value == 90)
  b:input(s, "input_unavailable")
  check("threshold: an unreadable source fires Faulted, not Became False", w.fired[4] == s .. ":faulted" and b:outputs(s).valid == false)
  b:input(s, "input", { VALUE = "91" })
  check("threshold: readable again and still above: nothing fires", #w.fired == 4 and b:outputs(s).active)
  b:input(s, "input_unavailable")
  b:input(s, "input", { VALUE = "70" })
  check("threshold: readable again and now below fires Became False", w.fired[#w.fired] == s .. ":became_false")

  local first = H.make(b, { type = "threshold", name = "First", upper = "10", lower = "5", inputs = { { used = true, label = "x" } } })
  w.clear()
  b:input(first, "input", { VALUE = "12" })
  check("threshold: a first reading above the limit sent by programming fires Became True", w.firedText() == first .. ":became_true")
end

-- ── I. Stable-state filter ──────────────────────────────────────────────────

do
  local b, w = new()
  local s = H.make(b, { type = "stable", name = "Occupied", duration = "30s", inputs = { { used = true, label = "Motion", true_when = "1" } } })
  b:input(s, "input", { VALUE = "0" })
  check("stable: the first value is taken as it is and fires nothing", #w.fired == 0 and b:outputs(s).state == "0" and b:outputs(s).valid)
  b:input(s, "input", { VALUE = "1" })
  check("stable: a change does not reach the output at once", b:outputs(s).state == "0" and #w.fired == 0)
  w.advance(20)
  b:input(s, "input", { VALUE = "1" })
  w.advance(9.9)
  check("stable: the same new value again does not restart the wait", #w.fired == 0)
  w.advance(0.1)
  check("stable: after holding, Value Changed and Became True fire", w.firedText() == s .. ":value_changed " .. s .. ":became_true")
  check("stable: the output is the held value", b:outputs(s).state == "1" and b:outputs(s).active)
  b:input(s, "input", { VALUE = "0" })
  w.advance(29)
  b:input(s, "input", { VALUE = "1" })
  w.advance(600)
  check("stable: a source that goes back in time drops the pending change", #w.fired == 2 and b:outputs(s).state == "1")
  b:input(s, "input", { VALUE = "0" })
  w.advance(10)
  b:input(s, "cancel")
  check("stable: BLOCK_CANCEL drops a pending change and fires Cancelled", w.fired[3] == s .. ":cancelled")
  w.advance(600)
  check("stable: a cancelled change never lands", b:outputs(s).state == "1" and #w.fired == 3)
  b:input(s, "input", { VALUE = "0" })
  w.advance(5)
  b:input(s, "input_unavailable")
  check("stable: an unreadable source drops the pending change and fires Faulted", w.fired[4] == s .. ":faulted")
  w.advance(600)
  check("stable: nothing lands while it cannot be read", #w.fired == 4 and b:outputs(s).valid == false)
  b:input(s, "input", { VALUE = "1" })
  check("stable: readable again with the held value: nothing fires", #w.fired == 4 and b:outputs(s).valid)
  b:input(s, "input", { VALUE = "" })
  check("stable: an empty value is refused", w.refused[#w.refused].why:find("empty") ~= nil)
end

-- ── J. State selector ───────────────────────────────────────────────────────

do
  local b, w = new()
  local s = H.make(b, {
    type = "selector",
    name = "House Mode",
    states = "Home, Away, Night",
    initial_state = "Home",
    transitions = "Home > Away, Home > Night, * > Home",
  })
  check("selector: starts in the initial state", b:outputs(s).state == "Home" and b:outputs(s).value == 1 and not b:outputs(s).active)
  b:input(s, "set", { VALUE = "night" })
  check("selector: an allowed transition fires Value Changed", w.firedText() == s .. ":value_changed" and b:outputs(s).state == "Night")
  check("selector: the state index is the value", b:outputs(s).value == 3)
  b:input(s, "set", { VALUE = "Away" })
  check("selector: a transition that is not allowed is refused", #w.refused == 1 and b:outputs(s).state == "Night")
  check("selector: and the refusal is readable", w.refused[1].why:find("Night → Away is not an allowed transition") ~= nil, w.refused[1].why)
  b:input(s, "set", { VALUE = "Vacation" })
  check("selector: an unknown state is refused and lists the states", w.refused[2].why:find("Home, Away, Night") ~= nil)
  b:input(s, "set", { VALUE = "Night" })
  check("selector: the same state is not a change", #w.fired == 1)
  b:input(s, "set", { VALUE = "Home" })
  check("selector: a wildcard source is allowed", #w.fired == 2 and b:outputs(s).state == "Home")
  b:input(s, "set", { VALUE = "Away" })
  b:input(s, "reset")
  check("selector: reset returns to the initial state", b:outputs(s).state == "Home" and #w.fired == 4)
  local second = H.make(b, { type = "selector", name = "Pool Mode", states = "Off, Heat" })
  b:input(second, "set", { VALUE = "Heat" })
  check("selector: every selector is its own machine", b:outputs(second).state == "Heat" and b:outputs(s).state == "Home")
end

-- ── Identity, slots, configuration ──────────────────────────────────────────

do
  local b, w = new()
  local a = H.make(b, { type = "timer", name = "Good Night", duration = "10m" })
  local other = H.make(b, { type = "timer", name = "Good-Night", duration = "10m" })
  b:input(a, "start")
  check("blocks with similar names are independent", b:outputs(a).active and not b:outputs(other).active)
  local id = b.blocks[a].id
  local def = Defs.normalize({ type = "timer", name = "Bedtime", duration = "10m" })
  check("rename: impact says programming is unaffected", table.concat(b:impact(a, def), " "):find("keep their ids") ~= nil)
  check("rename: applies", b:apply(a, def) == true)
  check("rename: keeps the identity and the slot", b.blocks[a].id == id and b.blocks[a].slot == a and b.blocks[a].name == "Bedtime")
  check("rename: does not disturb a running countdown", b:outputs(a).active)
  w.advance(600)
  check("rename: the countdown still expires on its slot's event", w.count(a .. ":expired") == 1)

  b:input(a, "start")
  w.advance(60)
  local changed = Defs.normalize({ type = "timer", name = "Bedtime", duration = "5m" })
  local impact = table.concat(b:impact(a, changed), " ")
  check("settings change: impact names the running countdown", impact:find("9 minutes left") ~= nil and impact:find("CANCELLED") ~= nil, impact)
  local fired = #w.fired
  b:apply(a, changed)
  check("settings change: the countdown is cancelled without firing", not b:outputs(a).active and #w.fired == fired)
  w.advance(3600)
  check("settings change: and never fires later", #w.fired == fired)
  check("a block's type cannot change", b:apply(a, Defs.normalize({ type = "flag", name = "Bedtime" })) == false)
  check("a duplicate name is refused", select(2, b:create(Defs.normalize({ type = "flag", name = "bedtime" }))):find("already named") ~= nil)

  b:input(other, "start")
  fired = #w.fired
  b:setEnabled(other, false)
  check("disable: cancels the countdown without a final event", #w.fired == fired and b:outputs(other).state == "disabled")
  w.advance(3600)
  check("disable: nothing fires afterwards", #w.fired == fired)
  b:input(other, "start")
  check("disable: inputs are refused and say why", w.refused[#w.refused].why == "the block is disabled")
  b:setEnabled(other, true)
  b:input(other, "start")
  check("enable: works again", b:outputs(other).active)

  local retiredId = b.blocks[other].id
  check("retire: impact explains the slot is kept out of use", table.concat(b:stopImpact(other, true), " "):find("kept out of use") ~= nil)
  fired = #w.fired
  b:retire(other)
  check("retire: nothing fires", #w.fired == fired and b:outputs(other).state == "retired")
  b:input(other, "start")
  check("retire: programming still pointing at the slot is refused by name", w.refused[#w.refused].why:find("Good%-Night") ~= nil)
  local third = H.make(b, { type = "flag", name = "Third" })
  check("a retired slot is not reused for a new block", third ~= other and third == 3)
  check("retired identity is remembered", b.retired[other].id == retiredId)
  b:releaseRetired(other)
  local fourth = H.make(b, { type = "flag", name = "Fourth" })
  check("an explicitly released slot can be used again", fourth == other)
  local copySlot = b:copyBlock(a, "Bedtime Two")
  check("copy: a new identity in a new slot", b.blocks[copySlot].id ~= b.blocks[a].id and copySlot ~= a)
  check("copy: no state carried over", not b:outputs(copySlot).active)

  for i = 1, Defs.SLOTS do
    if b:freeSlot() ~= nil then
      H.make(b, { type = "flag", name = "Filler " .. i })
    end
  end
  local slot, why = b:create(Defs.normalize({ type = "flag", name = "One Too Many" }))
  check("capacity: the 17th block is refused", slot == nil and why:find("in use") ~= nil, why)
  check("capacity: every slot holds a block", b:counts().used == Defs.SLOTS)

  b:input(17, "trigger")
  b:input(nil, "trigger")
  b:input("x", "trigger")
  check("an invalid slot is refused, not guessed", w.refused[#w.refused].why == "BLOCK names no slot")
  b:input(a, "increment")
  check("a command the type does not take is refused", w.refused[#w.refused].why:find("has no Increment command") ~= nil)
end

-- ── Variables first, reentrancy, back-to-back ───────────────────────────────

do
  local b, w = new()
  local counter = H.make(b, { type = "counter", name = "Count" })
  local flag = H.make(b, { type = "flag", name = "Flag" })
  b:input(counter, "increment")
  b:input(counter, "increment")
  b:input(counter, "increment")
  check("variables are written before the event fires", (function()
    for i, e in ipairs(w.events) do
      if e.out == nil or e.out.value ~= i then
        return false
      end
    end
    return #w.events == 3
  end)())
  check("back-to-back events each carry their own value", w.events[1].out.value == 1 and w.events[3].out.value == 3)

  -- Programming on an event sends another command (to the same block and to
  -- another one) while the first is still being handled.
  w.clear()
  local seen = {}
  w.onEmit = function(slot, kind)
    seen[#seen + 1] = slot .. ":" .. kind .. "@" .. tostring(b:outputs(counter).value)
    if slot == counter and b:outputs(counter).value == 4 then
      b:input(counter, "increment")
      b:input(flag, "set")
    end
  end
  local ok, info = b:input(counter, "increment")
  check("a reentrant input is accepted", ok == true and info ~= "queued")
  check(
    "reentrant inputs run after the one in progress, in arrival order",
    w.firedText() == counter .. ":value_changed " .. counter .. ":value_changed " .. flag .. ":became_true",
    w.firedText()
  )
  check("each event saw its own value, not a later one", seen[1]:find("@4$") ~= nil and seen[2]:find("@5$") ~= nil, table.concat(seen, " "))
  w.onEmit = nil
  check("the queue is empty afterwards", #b.queue == 0 and b.depth == 0)

  -- A block that feeds itself from its own event: a programming loop.
  local loop = H.make(b, { type = "counter", name = "Loop" })
  w.clear()
  w.onEmit = function(slot)
    if slot == loop then
      b:input(loop, "increment")
    end
  end
  b:input(loop, "increment")
  w.advance(5)
  check("a self-feeding block is isolated instead of running forever", b:view(loop).isolated ~= nil)
  check("isolation fires Faulted once", w.count(loop .. ":faulted") == 1)
  check("the count stopped", b:outputs(loop).state == "isolated")
  w.onEmit = nil
  b:input(flag, "clear")
  check("other blocks keep working while one is isolated", w.fired[#w.fired] == flag .. ":became_false")
  b:input(loop, "increment")
  check("an isolated block refuses inputs and says why", w.refused[#w.refused].why:find("isolated") ~= nil)
  check("resume puts it back to work", b:resume(loop) == true and b:view(loop).isolated == nil)
  w.advance(11)
  b:input(loop, "increment")
  check("and it accepts inputs again", H.last(b).decision == "changed")
end

do
  -- Runaway by rate, with no reentrancy: far more than a house produces.
  local b, w = new()
  local s = H.make(b, { type = "flag", name = "Hammered" })
  local quiet = H.make(b, { type = "flag", name = "Quiet" })
  for _ = 1, Blocks.LIMITS.inputs_per_window do
    b:input(s, "toggle")
  end
  check("ordinary bursts up to the limit are all handled, none dropped", w.count(s .. ":became_true") + w.count(s .. ":became_false") == Blocks.LIMITS.inputs_per_window)
  b:input(s, "toggle")
  check("the input over the limit isolates the block", b:view(s).isolated ~= nil and w.count(s .. ":faulted") == 1)
  b:input(quiet, "set")
  check("the limit is per block", w.count(quiet .. ":became_true") == 1)
  check("isolation is counted in the diagnostics", b.stats.isolations == 1)
end

do
  -- A flood of reentrant inputs to ANOTHER block fills the queue.
  local b, w = new()
  local src = H.make(b, { type = "flag", name = "Source" })
  local target = H.make(b, { type = "counter", name = "Target" })
  w.onEmit = function(slot)
    if slot == src then
      for _ = 1, Blocks.LIMITS.queue + 5 do
        b:input(target, "increment")
      end
    end
  end
  b:input(src, "set")
  w.onEmit = nil
  w.advance(1)
  check("a full input queue isolates the block being flooded", b:view(target).isolated ~= nil)
  check("the queue never grows past its bound", b.stats.queued_max <= Blocks.LIMITS.queue)
  check("the source block is unaffected", b:outputs(src).active == true)
end

-- ── Variable-mapped inputs: opening values, shared listeners, loss ──────────

do
  local b, w = new({ variables = { ["82:1000"] = true, ["60:1"] = true }, selfDevice = 500 })
  w.variables["500:4011"] = true
  local raw = {
    type = "threshold",
    name = "Rack",
    upper = "85",
    lower = "78",
    inputs = { { used = true, label = "Temp", device_id = 82, variable_id = 1000, device_name = "Rack Sensor", variable_name = "TEMPERATURE" } },
  }
  local s = H.make(b, raw)
  check("a mapped input starts a listener", w.watched[1] == "82:1000")
  check("before the first value it is waiting, not zero", b:view(s).sources[1].status == "awaiting" and b:outputs(s).valid == false)
  b:variable(82, 1000, "90")
  check("the opening value sets the state and fires nothing", #w.fired == 0 and b:outputs(s).active == true and b:outputs(s).valid)
  check("the opening value is recorded as a starting value", H.last(b).decision == "baseline")
  b:variable(82, 1000, "70")
  check("a later change fires", w.firedText() == s .. ":became_false")
  check("the source shows the device, the value and when", (function()
    local row = b:view(s).sources[1]
    return row.device_id == 82 and row.variable_id == 1000 and row.value == "70" and row.observed_at == w.t and row.status == "ok"
  end)())
  w.advance(86400 * 3)
  check("an unchanged valid source is never called stale", b:view(s).sources[1].status == "ok" and b:outputs(s).valid)
  b:input(s, "input", { VALUE = "99" })
  check("a mapped input does not take commands", w.refused[#w.refused].why:find("does not take commands") ~= nil and b:outputs(s).value == 70)

  raw.name = "Rack Two"
  local second = H.make(b, raw)
  check("two blocks on one variable share one listener", #w.watched == 1)
  check("the second block takes the last value as its opening value", b:outputs(second).valid and #w.fired == 1)
  b:variable(82, 1000, "95")
  check("one change reaches both", w.count(s .. ":became_true") == 1 and w.count(second .. ":became_true") == 1)
  b:retire(second)
  check("the listener stays while a block still needs it", #w.unwatched == 0)

  b:variableLost(82, 1000, "variable 1000 is not on device 82")
  check("a source that goes away fires Faulted, not Became False", w.fired[#w.fired] == s .. ":faulted")
  check("and is reported as a missing mapping", #b:missingMappings() == 1 and b:missingMappings()[1].why:find("1000") ~= nil)
  check("the value is unknown, not zero", b:outputs(s).valid == false and b:view(s).sources[1].value == nil)
  local fired = #w.fired
  b:checkWatches(function()
    return true
  end)
  b:variable(82, 1000, "60")
  check("when it comes back its first value is taken silently", #w.fired == fired and b:outputs(s).valid and not b:outputs(s).active)
  b:variable(82, 1000, "96")
  check("and later changes fire again", w.fired[#w.fired] == s .. ":became_true")
  b:variable(82, 1000, "hot")
  check("a mapped value that is not a number makes the result unknown", b:outputs(s).valid == false and b:view(s).sources[1].status == "invalid")

  local missing = H.make(b, {
    type = "stable",
    name = "Gone",
    duration = "5s",
    inputs = { { used = true, label = "Lost", device_id = 7, variable_id = 7 } },
  })
  check("a mapping to a variable that does not exist is unavailable from the start", b:view(missing).sources[1].status == "unavailable")
  check("and never reads as a value", b:outputs(missing).valid == false)

  local reader = H.make(b, {
    type = "conditions",
    name = "Reader",
    inputs = { { used = true, label = "Block one active", device_id = 500, variable_id = 4011, true_when = "1" } },
  })
  check("an input that reads another block's variable is a known relationship", b:view(reader).sources[1].reads_block == 1)
  b:retire(s)
  check("the last block to leave releases the listener", w.unwatched[#w.unwatched] == "82:1000")
end

-- ── Equipment feedback ──────────────────────────────────────────────────────

do
  local b, w = new({ variables = { ["90:1"] = true } })
  local s = H.make(b, {
    type = "cooldown",
    name = "Fan",
    duration = "1m",
    feedback = { device_id = 90, variable_id = 1, expect = "1,on", within = "10s" },
  })
  b:variable(90, 1, "0")
  b:input(s, "trigger")
  check("feedback: an emitted event is not a confirmation", H.last(b).confirmed == "pending")
  local passEntry = H.last(b)
  w.advance(4)
  b:variable(90, 1, "1")
  check("feedback: confirmed only when the equipment reports the expected value", passEntry.confirmed == "confirmed")
  check("feedback: the confirmation is its own record", H.last(b).decision == "feedback" and H.last(b).reason:find("confirmed") ~= nil)
  w.advance(120)
  b:input(s, "trigger")
  check("feedback: equipment already in the expected state is not credited", H.last(b).decision == "feedback" and b.history[#b.history - 1].confirmed == "already")
  b:variable(90, 1, "0")
  w.advance(120)
  b:input(s, "trigger")
  local third = H.last(b)
  w.advance(10)
  check("feedback: silence within the window is reported as not confirmed", third.confirmed == "not_confirmed")
  check("feedback: no event fires for feedback itself", w.count(s .. ":passed") == 3 and #w.fired == 3)
  local plain = H.make(b, { type = "flag", name = "Plain" })
  b:input(plain, "set")
  check("feedback: with none mapped the record says not monitored", H.last(b).confirmed == "not_monitored")
end

-- ── Licence: read-only ──────────────────────────────────────────────────────

do
  local b, w = new()
  local late = H.make(b, { type = "timer", name = "Late", duration = "60s", recovery = "Fire late" })
  local cancel = H.make(b, { type = "timer", name = "Cancel", duration = "60s" })
  local resume = H.make(b, { type = "timer", name = "Resume", duration = "60s", recovery = "Resume remaining" })
  local quiet = H.make(b, { type = "quiet", name = "Quiet", duration = "30s" })
  local flag = H.make(b, { type = "flag", name = "Flag" })
  b:input(flag, "set")
  for _, s in ipairs({ late, cancel, resume, quiet }) do
    b:input(s, "trigger")
  end
  w.advance(20)
  w.clear()
  b:setReadOnly(true)
  check("read-only: nothing fires when the pack is halted", #w.fired == 0)
  check("read-only: countdowns are held", b:outputs(late).state == "held" and b:outputs(resume).state == "held")
  b:input(flag, "clear")
  b:input(late, "start")
  check("read-only: inputs are refused with read-only", w.refused[1].why == "read-only" and w.refused[2].why == "read-only")
  check("read-only: reads still answer", b:outputs(flag).active == true)
  check("read-only: configuration is refused", select(2, b:setEnabled(flag, false)) == "read-only")
  w.advance(100)
  check("read-only: held countdowns do not fire while halted", #w.fired == 0)
  b:setReadOnly(false)
  w.advance(1)
  check("restored: Fire late expires now", w.count(late .. ":expired") == 1)
  check("restored: Cancel if missed is cancelled and does not fire", w.count(cancel .. ":expired") == 0 and b:outputs(cancel).state == "idle")
  check("restored: Resume remaining carries on with what was left", w.count(resume .. ":expired") == 0 and b:outputs(resume).active)
  w.advance(38)
  check("restored: Resume remaining has not expired early", w.count(resume .. ":expired") == 0)
  w.advance(2)
  check("restored: Resume remaining expires after the 40 seconds it had left", w.count(resume .. ":expired") == 1)
  check("restored: a quiet countdown that was pending never passes", w.count(quiet .. ":passed") == 0)
  b:input(flag, "clear")
  check("restored: inputs work again", w.fired[#w.fired] == flag .. ":became_false")

  b:input(cancel, "start")
  b:setReadOnly(true)
  w.advance(10)
  b:setReadOnly(false)
  w.advance(49)
  check("a countdown that outlives a short halt carries on", w.count(cancel .. ":expired") == 0 and b:outputs(cancel).active)
  w.advance(1)
  check("and expires at its original deadline", w.count(cancel .. ":expired") == 1)
end

-- ── Persistence and recovery ────────────────────────────────────────────────

local function reload(b, w, downSeconds)
  local doc = b:serialize()
  b:stop()
  w.timers = {}
  w.t = w.t + (downSeconds or 0)
  w.clear()
  local fresh = Blocks.new(w.deps)
  local report = fresh:restore(doc)
  return fresh, report, doc
end

do
  local b, w = new()
  local flag = H.make(b, { type = "flag", name = "Flag" })
  local counter = H.make(b, { type = "counter", name = "Counter", counter_threshold = "2" })
  local selector = H.make(b, { type = "selector", name = "Mode", states = "A, B, C" })
  local cooldown = H.make(b, { type = "cooldown", name = "Cool", duration = "10m" })
  local once = H.make(b, { type = "once", name = "Once" })
  local conditions = H.make(b, { type = "conditions", name = "Cond", inputs = { { used = true, label = "A" } } })
  b:input(flag, "set")
  b:input(counter, "set", { VALUE = "5" })
  b:input(selector, "set", { VALUE = "C" })
  b:input(cooldown, "trigger")
  b:input(once, "trigger")
  b:input(conditions, "input", { VALUE = "true" })
  b:setEnabled(once, false)
  local id = b.blocks[flag].id
  local revision = b.revision
  local b2, report = reload(b, w, 120)
  check("restore: reports success", report.ok and report.loaded == 6 and report.unreadable == 0)
  check("restore: fires nothing", #w.fired == 0)
  check("restore: flag kept", b2:outputs(flag).active)
  check("restore: counter and its threshold state kept", b2:outputs(counter).value == 5 and b2:outputs(counter).active)
  check("restore: selector state kept", b2:outputs(selector).state == "C")
  check("restore: cooldown window kept", b2:outputs(cooldown).state == "cooling")
  check("restore: disabled stays disabled", b2:outputs(once).state == "disabled")
  check("restore: identity, slot and revision kept", b2.blocks[flag].id == id and b2.revision == revision)
  check("restore: a value programming sent is kept and marked", b2:view(conditions).sources[1].via == "restored" and b2:outputs(conditions).active)
  check("restore: history from before is marked as restored", b2.history[1].origin == "restored")
  b2:input(counter, "decrement", { BY = "4" })
  check("restore: transitions carry on from the restored state", w.firedText() == counter .. ":value_changed " .. counter .. ":became_false")
  b2:input(cooldown, "trigger")
  check("restore: the cooldown still suppresses", w.count(cooldown .. ":passed") == 0)
  w.advance(480)
  b2:input(cooldown, "trigger")
  check("restore: and ends when it should have", w.count(cooldown .. ":passed") == 1)
end

do
  -- Timers across a restart: three policies, deadline before and after.
  for _, case in ipairs({
    { policy = "Cancel if missed", down = 30, fires = 0, runs = true, text = "carried on" },
    { policy = "Cancel if missed", down = 120, fires = 0, runs = false, text = "did NOT fire" },
    { policy = "Fire late", down = 30, fires = 0, runs = true, text = "carried on" },
    { policy = "Fire late", down = 120, fires = 1, runs = false, text = "expires now" },
    { policy = "Resume remaining", down = 120, fires = 0, runs = true, text = "resumed" },
  }) do
    local b, w = new()
    local s = H.make(b, { type = "timer", name = "T", duration = "60s", recovery = case.policy })
    b:input(s, "start")
    w.advance(20)
    local b2, report = reload(b, w, case.down)
    w.advance(0.01)
    local label = string.format("timer restart (%s, down %ds): ", case.policy, case.down)
    check(label .. "Expired fired " .. case.fires .. " time(s)", w.count(s .. ":expired") == case.fires, w.firedText())
    check(label .. (case.runs and "still running" or "not running"), b2:outputs(s).active == case.runs)
    check(label .. "the recovery report says so", table.concat(report.notes, " "):find(case.text, 1, true) ~= nil, table.concat(report.notes, " "))
    if case.policy == "Fire late" and case.fires == 1 then
      check(label .. "the expiry is marked late", H.last(b2).decision == "expired_late")
    end
    if case.policy == "Resume remaining" then
      w.advance(39)
      check(label .. "has the 40 seconds it had left", w.count(s .. ":expired") == 0)
      w.advance(1)
      check(label .. "then expires", w.count(s .. ":expired") == 1)
    end
    if case.policy == "Cancel if missed" and case.down == 30 then
      w.advance(10)
      check(label .. "expires at its original deadline", w.count(s .. ":expired") == 1)
    end
  end
end

do
  local b, w = new({ variables = { ["82:1000"] = true } })
  local quiet = H.make(b, { type = "quiet", name = "Quiet", duration = "30s" })
  local stable = H.make(b, { type = "stable", name = "Stable", duration = "30s", inputs = { { used = true, label = "s" } } })
  local mapped = H.make(b, {
    type = "threshold",
    name = "Mapped",
    upper = "10",
    lower = "5",
    inputs = { { used = true, label = "t", device_id = 82, variable_id = 1000 } },
  })
  b:variable(82, 1000, "20")
  b:input(quiet, "trigger")
  b:input(stable, "input", { VALUE = "a" })
  b:input(stable, "input", { VALUE = "b" })
  local b2, report = reload(b, w, 600)
  w.advance(60)
  check("restart: a pending quiet countdown is dropped and reported", w.count(quiet .. ":passed") == 0 and table.concat(report.notes, " "):find("did NOT pass") ~= nil)
  check("restart: a pending stable change never fires", #w.fired == 0)
  check("restart: the source's last value is the new starting state, set silently", b2:outputs(stable).state == "b")
  check("restart: and the report says the pending change was dropped", table.concat(report.notes, " "):find("waiting to hold") ~= nil)
  check("restart: a mapped input is read again, not restored", b2:view(mapped).sources[1].status == "awaiting" and b2:outputs(mapped).valid == false)
  b2:variable(82, 1000, "3")
  check("restart: its opening value fires nothing even though it changed while down", #w.fired == 0 and not b2:outputs(mapped).active)
  check("restart: the silent change is in the history", H.last(b2).decision == "baseline")
  b2:variable(82, 1000, "30")
  check("restart: later changes fire normally", w.firedText() == mapped .. ":became_true")
end

do
  -- A stored document that cannot be used is never reset.
  local function attempt(doc)
    local b, w = new()
    local report = b:restore(doc)
    return b, w, report
  end
  local b, w, report = attempt("garbage")
  check("corrupt: a non-table document fails loudly", report.failed and b.restoreFailed ~= nil)
  check("corrupt: nothing is created in its place", b:counts().used == 0)
  check("corrupt: inputs are refused and say why", b:input(1, "trigger") == false and w.refused[1].why:find("could not be read") ~= nil)
  check("corrupt: configuration is refused", b:create(Defs.normalize({ type = "flag", name = "x" })) == nil)
  check("corrupt: nothing asks to be saved over the stored copy", w.changed == 0)
  b:acknowledgeRestoreFailure()
  check("corrupt: after the dealer acknowledges, it starts empty and can save", H.make(b, { type = "flag", name = "x" }) == 1 and w.changed > 0)

  check("corrupt: another driver's document is refused", attempt({ schema = "something_else", v = 1, blocks = {} }) and select(3, attempt({ schema = "something_else", v = 1, blocks = {} })).failed)
  local _, _, newer = attempt({ schema = Blocks.SCHEMA, v = Blocks.VERSION + 1, blocks = {} })
  check("corrupt: a document from a newer driver is refused, not downgraded", newer.failed and newer.why:find("newer driver") ~= nil)
  check("corrupt: no version is refused", select(3, attempt({ schema = Blocks.SCHEMA, blocks = {} })).failed)
  check("corrupt: no blocks table is refused", select(3, attempt({ schema = Blocks.SCHEMA, v = Blocks.VERSION })).failed)
  check("an absent document is simply empty", select(3, attempt(nil)).ok)

  local good, gw = new()
  local keep = H.make(good, { type = "flag", name = "Keep" })
  local broken = H.make(good, { type = "timer", name = "Broken", duration = "10s" })
  good:input(keep, "set")
  local doc = good:serialize()
  doc.blocks[Blocks.key(broken)].settings = "not a table"
  local rawBroken = doc.blocks[Blocks.key(broken)]
  gw.clear()
  local partial = Blocks.new(gw.deps)
  local partialReport = partial:restore(doc)
  check("one unreadable block does not take the others with it", partialReport.ok and partialReport.loaded == 1 and partialReport.unreadable == 1)
  check("the readable block works", partial:outputs(keep).active)
  check("the unreadable block does nothing and says so", partial:outputs(broken).state == "unreadable" and partial:view(broken).kind == "unreadable")
  check("its slot is not handed to a new block", partial:freeSlot() == 3)
  partial:input(broken, "start")
  check("commands to it are refused with the reason", gw.refused[#gw.refused].why:find("could not be read") ~= nil)
  check(
    "it is written back exactly as it was found",
    Blocks.fingerprint(partial:serialize().blocks[Blocks.key(broken)]) == Blocks.fingerprint(rawBroken)
  )

  local migrated, why = Blocks.migrate({ v = 0, old_field = 1 }, {
    [0] = function(d)
      d.middle = true
      return d
    end,
    [1] = function(d)
      d.new_field = d.old_field
      return d
    end,
  }, 2)
  check("migration: walks every step to the current version", migrated ~= nil and migrated.v == 2 and migrated.middle and migrated.new_field == 1, why)
  check("migration: a missing step fails instead of guessing", Blocks.migrate({ v = 0 }, {}, 1) == nil)
  check("migration: a step that throws fails", Blocks.migrate({ v = 0 }, { [0] = function() error("x") end }, 1) == nil)
end

-- ── Housekeeping and bounds ─────────────────────────────────────────────────

do
  local b, w = new()
  local s = H.make(b, { type = "cooldown", name = "Cool", duration = "10m" })
  b:tick(nil)
  w.advance(60)
  b:tick(60)
  check("tick: a steady clock is not a jump", b.stats.clock_jumps == 0)
  b:input(s, "trigger")
  w.t = w.t - 7200
  b:tick(60)
  check("tick: a clock that moved is noticed and reported", b.stats.clock_jumps == 1 and b.lastJump.seconds < -7000)
  check("tick: a cooldown is not left counting from the future", b.eng:throttleLastAt(Blocks.key(s)) <= w.t)
  for _ = 1, Blocks.LIMITS.history + 50 do
    b:input(s, "trigger")
    w.advance(11)
  end
  check("history is bounded", #b.history == Blocks.LIMITS.history)
  check("the saved history is bounded", #b:serialize().history == Blocks.LIMITS.history_saved)
  local big = H.make(b, { type = "stable", name = "Big", duration = "1s", inputs = { { used = true, label = "x" } } })
  b:input(big, "input", { VALUE = string.rep("v", 5000) })
  check("a source value is bounded", #b:view(big).sources[1].value <= Blocks.LIMITS.raw)
  local timers = 0
  for _ in pairs(w.timers) do
    timers = timers + 1
  end
  check("timers stay within a few per block", timers <= 3 * Defs.SLOTS)
  b:stop()
  check("stop cancels every block timer", w.timerCount() == 0)
end

c.finish()
