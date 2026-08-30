-- Gesture engine test matrix (spec §82). The FSM is pure + scheduler-injected,
-- so these tests drive a fake clock and assert exact emissions — the
-- determinism rules are the product here:
--   * no premature single-tap while double is still possible,
--   * hold tiers resolve to the highest crossed,
--   * fire-at-crossing only when nothing else can match,
--   * runaway presses cancel instead of firing.
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

local gesture = require("modes.gesture")

-- Deterministic fake scheduler: timers fire in timestamp order on advance().
local function newClock()
  local clock = { now = 0, timers = {}, nextId = 1 }
  function clock.set(ms, cb)
    local id = clock.nextId
    clock.nextId = id + 1
    clock.timers[id] = { at = clock.now + ms, cb = cb }
    return id
  end
  function clock.cancel(id)
    if id then
      clock.timers[id] = nil
    end
  end
  function clock.advance(ms)
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
      local cb = clock.timers[bestId].cb
      clock.timers[bestId] = nil
      cb()
    end
    clock.now = target
  end
  return clock
end

local function rig(assigned, timing)
  local clock = newClock()
  local emitted, progress = {}, {}
  local fsm = gesture.new({
    assigned = assigned,
    timing = timing,
    timer = { set = clock.set, cancel = clock.cancel },
    emit = function(g, detail)
      table.insert(emitted, { g = g, detail = detail })
    end,
    progress = function(kind, detail)
      table.insert(progress, { kind = kind, detail = detail })
    end,
  })
  return fsm, clock, emitted, progress
end

print("\n[1] Single tap with nothing higher assigned fires IMMEDIATELY")
local fsm, clock, emitted = rig({ tap = true })
fsm:click()
check("tap fired without waiting", #emitted == 1 and emitted[1].g == "tap", emitted[1] and emitted[1].g)

print("\n[2] With double assigned, the first tap WAITS out the window")
fsm, clock, emitted = rig({ tap = true, double_tap = true })
fsm:click()
check("nothing yet", #emitted == 0, #emitted)
clock.advance(499)
check("still nothing inside the window", #emitted == 0, #emitted)
clock.advance(2)
check("tap after window expiry", #emitted == 1 and emitted[1].g == "tap", emitted[1] and emitted[1].g)

print("\n[3] Double tap resolves on the second tap (triple not assigned)")
fsm, clock, emitted = rig({ tap = true, double_tap = true })
fsm:click()
clock.advance(200)
fsm:click()
check(
  "double fired immediately on 2nd tap",
  #emitted == 1 and emitted[1].g == "double_tap",
  emitted[1] and emitted[1].g
)
clock.advance(1000)
check("and nothing else afterwards", #emitted == 1, #emitted)

print("\n[4] Triple tap via PUSH/RELEASE pairs")
fsm, clock, emitted = rig({ tap = true, double_tap = true, triple_tap = true })
for _ = 1, 3 do
  fsm:push()
  clock.advance(80)
  fsm:release()
  clock.advance(150)
end
check("triple fired", #emitted == 1 and emitted[1].g == "triple_tap", emitted[1] and emitted[1].g)

print("\n[5] Rapid four taps: triple fires once, the leftover degrades to tap")
fsm, clock, emitted = rig({ tap = true, double_tap = true, triple_tap = true })
for _ = 1, 4 do
  fsm:click()
  clock.advance(100)
end
clock.advance(600)
check("exactly two emissions", #emitted == 2, #emitted)
check("first is triple", emitted[1] and emitted[1].g == "triple_tap", emitted[1] and emitted[1].g)
check("second is tap", emitted[2] and emitted[2].g == "tap", emitted[2] and emitted[2].g)

print("\n[6] Two taps on a tap-only slot degrade to ONE tap (fires on first)")
fsm, clock, emitted = rig({ tap = true })
fsm:click()
fsm:click()
clock.advance(600)
check("two taps, two immediate tap fires", #emitted == 2 and emitted[1].g == "tap" and emitted[2].g == "tap", #emitted)

print("\n[7] Single hold tier fires AT the crossing (hold-to-confirm)")
local progress
fsm, clock, emitted, progress = rig({ hold = true }, { hold_ms = 1000 })
fsm:push()
check("hold_start progress emitted", progress[1] and progress[1].kind == "hold_start")
clock.advance(999)
check("not yet at 999ms", #emitted == 0, #emitted)
clock.advance(1)
check("hold fired at crossing", #emitted == 1 and emitted[1].g == "hold", emitted[1] and emitted[1].g)
check("fired with at_crossing", emitted[1].detail.at_crossing == true)
fsm:release()
clock.advance(2000)
check("the release is swallowed, nothing extra", #emitted == 1, #emitted)

print("\n[8] Multi-tier hold resolves on RELEASE to the highest tier crossed")
fsm, clock, emitted = rig(
  { hold = true, long_hold = true, very_long_hold = true },
  { hold_ms = 1000, long_hold_ms = 3000, very_long_hold_ms = 5000 }
)
fsm:push()
clock.advance(3500)
check("nothing fires while held", #emitted == 0, #emitted)
fsm:release()
check("long_hold on release", #emitted == 1 and emitted[1].g == "long_hold", emitted[1] and emitted[1].g)

print("\n[9] Release BEFORE the first tier with tap assigned becomes a tap")
fsm, clock, emitted, progress = rig({ tap = true, hold = true }, { hold_ms = 1000 })
fsm:push()
clock.advance(400)
fsm:release()
check("tap fired", #emitted == 1 and emitted[1].g == "tap", emitted[1] and emitted[1].g)
local sawCancel = false
for _, p in ipairs(progress) do
  if p.kind == "hold_cancel" then
    sawCancel = true
  end
end
check("hold_cancel progress for LED", sawCancel)

print("\n[10] Release before threshold with ONLY hold assigned fires nothing")
fsm, clock, emitted = rig({ hold = true }, { hold_ms = 1000 })
fsm:push()
clock.advance(400)
fsm:release()
clock.advance(2000)
check("no emission", #emitted == 0, #emitted)

print("\n[11] Runaway press after a pending tap: cancels, discards the tap")
-- A pending tap disables fire-at-crossing, so this press resolves on
-- release — which never comes. The runaway guard must fire NOTHING and
-- clear the half-typed sequence.
fsm, clock, emitted, progress = rig(
  { tap = true, double_tap = true, hold = true },
  { hold_ms = 1000, runaway_ms = 30000 }
)
fsm:click() -- tap #1, waiting on the double window
fsm:push() -- press #2 sticks
clock.advance(31000)
local runawayCancel = false
for _, p in ipairs(progress) do
  if p.kind == "hold_cancel" and p.detail.reason == "runaway" then
    runawayCancel = true
  end
end
check("runaway cancel emitted", runawayCancel)
local nonTap = 0
for _, e in ipairs(emitted) do
  if e.g ~= "tap" then
    nonTap = nonTap + 1
  end
end
check("no hold ever fired from the stuck press", nonTap == 0, nonTap)
fsm:release()
local before = #emitted
fsm:push()
clock.advance(1000)
fsm:release()
check(
  "slot recovered: hold works after runaway",
  #emitted == before + 1 and emitted[#emitted].g == "hold",
  #emitted - before
)

print("\n[12] Runaway with multi-tier: nothing ever fires")
fsm, clock, emitted = rig(
  { hold = true, long_hold = true },
  { hold_ms = 1000, long_hold_ms = 3000, runaway_ms = 30000 }
)
fsm:push()
clock.advance(31000)
check("no emission from a stuck button", #emitted == 0, #emitted)
fsm:release()
clock.advance(1000)
check("late release fires nothing either", #emitted == 0, #emitted)
fsm:push()
clock.advance(1100)
fsm:release()
check("next press works (hold)", #emitted == 1 and emitted[1].g == "hold", emitted[1] and emitted[1].g)

print("\n[13] DO_CLICK arriving during a tracked press is redundant, not a tap")
fsm, clock, emitted = rig({ tap = true, double_tap = true })
fsm:push()
fsm:click() -- keypad sends both
clock.advance(50)
fsm:release()
clock.advance(600)
check("exactly one tap", #emitted == 1 and emitted[1].g == "tap", #emitted)

print("\n[14] reset() mid-gesture abandons cleanly (driver restart / config edit)")
fsm, clock, emitted = rig({ tap = true, double_tap = true })
fsm:click()
fsm:reset()
clock.advance(1000)
check("abandoned tap never fires", #emitted == 0, #emitted)

print("\n[15] Tap followed by hold: both gestures, both fire")
fsm, clock, emitted = rig({ tap = true, hold = true }, { hold_ms = 1000 })
fsm:click()
check("tap fired first", #emitted == 1 and emitted[1].g == "tap")
fsm:push()
clock.advance(1000)
check("then the hold", #emitted == 2 and emitted[2].g == "hold", emitted[2] and emitted[2].g)

print("\n[16] Duplicate PUSH without RELEASE keeps the original press timing")
fsm, clock, emitted = rig({ hold = true }, { hold_ms = 1000 })
fsm:push()
clock.advance(600)
fsm:push() -- noisy duplicate
clock.advance(400)
check("hold fired at 1000ms from the FIRST push", #emitted == 1 and emitted[1].g == "hold", #emitted)

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
