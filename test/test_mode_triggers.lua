-- Triggers/conditions, schedule, history, and LED engine tests.
-- The acceptance-critical scenario is §131: front door + disarm + motion
-- activate Home; any single signal does not; chatter does not re-fire; and
-- loop protection holds. Run from the driver root: make test

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

local triggerslib = require("modes.triggers")
local schedule = require("modes.schedule")
local historylib = require("modes.history")
local led = require("modes.led")

-- ── Triggers ────────────────────────────────────────────────────────────────
local now = 1000000
local active = { PRESENCE = "m_away", LIFESTYLE = nil }
local DEVICES = {
  door = { name = "Front Door", vars = { ["ContactState"] = "closed" } },
  panel = { name = "Panel", vars = { ["PARTITION_STATE"] = "ARMED" } },
}
local fired, warnings = {}, {}
local trig = triggerslib.new({
  now = function()
    return now
  end,
  activeModes = function()
    return active
  end,
  resolve = function(key)
    return DEVICES[key]
  end,
  localtime = function(t)
    return os.date("*t", t)
  end,
  fire = function(rule, detail)
    table.insert(fired, { rule = rule, detail = detail })
  end,
  warn = function(msg)
    table.insert(warnings, msg)
  end,
})

trig:setRules({
  {
    id = "r_home",
    mode_id = "m_home",
    enabled = true,
    signals = {
      { type = "CONTACT_OPENED", device_key = "door" },
      { type = "SECURITY_DISARMED", device_key = "panel" },
      { type = "MOTION", device_key = "hall" },
    },
    conditions = { { type = "PRESENCE_IS", mode_id = "m_away" } },
    window_s = 120,
    cooldown_s = 60,
    debounce_s = 2,
  },
})

print("\n[1] One signal alone never fires (§131)")
trig:onSignal({ type = "CONTACT_OPENED", device_key = "door" })
check("door alone: nothing", #fired == 0, #fired)
now = now + 5
trig:onSignal({ type = "SECURITY_DISARMED", device_key = "panel" })
check("door+disarm: still nothing", #fired == 0, #fired)

print("\n[2] The full sequence inside the window fires exactly once")
now = now + 5
trig:onSignal({ type = "MOTION", device_key = "hall" })
check("fired", #fired == 1, #fired)
check("for the right mode", fired[1].rule.mode_id == "m_home")

print("\n[3] Chatter: debounce + consumed signals + cooldown hold the line")
now = now + 1
trig:onSignal({ type = "CONTACT_OPENED", device_key = "door" })
trig:onSignal({ type = "MOTION", device_key = "hall" })
trig:onSignal({ type = "SECURITY_DISARMED", device_key = "panel" })
check("immediate replay inside cooldown: no re-fire", #fired == 1, #fired)
now = now + 200 -- past cooldown AND past the 120s window: the replayed marks are stale
trig:onSignal({ type = "MOTION", device_key = "hall" })
check("a lone motion later: nothing (the full sequence must recur)", #fired == 1, #fired)

print("\n[4] Condition gate: rule dead when presence is not Away")
now = now + 300
active.PRESENCE = "m_vacation"
trig:onSignal({ type = "CONTACT_OPENED", device_key = "door" })
now = now + 2
trig:onSignal({ type = "SECURITY_DISARMED", device_key = "panel" })
now = now + 2
trig:onSignal({ type = "MOTION", device_key = "hall" })
check("no fire under Vacation (§131 protection)", #fired == 1, #fired)
active.PRESENCE = "m_away"

print("\n[5] Signals outside the window expire")
now = now + 600
trig:onSignal({ type = "CONTACT_OPENED", device_key = "door" })
now = now + 121 -- window is 120
trig:onSignal({ type = "SECURITY_DISARMED", device_key = "panel" })
now = now + 1
trig:onSignal({ type = "MOTION", device_key = "hall" })
check("stale door signal: no fire", #fired == 1, #fired)

print("\n[6] Loop protection: the global budget suppresses runaway rules")
trig:setRules({
  {
    id = "r_loop",
    mode_id = "m_home",
    enabled = true,
    signals = { { type = "MOTION", device_key = "hall" } },
    cooldown_s = 0,
    debounce_s = 0,
  },
})
fired = {}
for i = 1, 10 do
  now = now + 1
  trig:onSignal({ type = "MOTION", device_key = "hall" })
end
check("capped at the per-minute budget", #fired == triggerslib.GLOBAL_FIRES_PER_MINUTE, #fired)
check("suppression warned loudly", #warnings > 0, #warnings)

print("\n[7] Conditions: time range spans midnight; day-of-week; unknown type fails closed")
local t22 = os.time({ year = 2026, month = 8, day = 29, hour = 22, min = 30 })
local t03 = os.time({ year = 2026, month = 8, day = 30, hour = 3, min = 0 })
local t12 = os.time({ year = 2026, month = 8, day = 29, hour = 12, min = 0 })
check(
  "22:30 inside 21:00-06:00",
  trig:evaluateCondition({ type = "TIME_RANGE", from = "21:00", to = "06:00" }, t22) == true
)
check(
  "03:00 inside 21:00-06:00",
  trig:evaluateCondition({ type = "TIME_RANGE", from = "21:00", to = "06:00" }, t03) == true
)
check(
  "12:00 outside 21:00-06:00",
  trig:evaluateCondition({ type = "TIME_RANGE", from = "21:00", to = "06:00" }, t12) == false
)
local saturday = os.time({ year = 2026, month = 8, day = 29, hour = 12 }) -- 2026-08-29 is a Saturday (wday 7)
check("day-of-week matches", trig:evaluateCondition({ type = "DAY_OF_WEEK", days = { 7 } }, saturday) == true)
check("day-of-week rejects", trig:evaluateCondition({ type = "DAY_OF_WEEK", days = { 2, 3 } }, saturday) == false)
check("unknown condition type fails CLOSED", trig:evaluateCondition({ type = "FANCY_NEW_THING" }) == false)
check("sensor closed reads vars", trig:evaluateCondition({ type = "SENSOR_CLOSED", device_key = "door" }) == true)
check(
  "security state condition",
  trig:evaluateCondition({ type = "SECURITY_STATE", device_key = "panel", state = "ARMED" }) == true
)
check("missing device fails closed", trig:evaluateCondition({ type = "SENSOR_CLOSED", device_key = "ghost" }) == false)

print("\n[8] Occupancy tri-state comes from the mode's own field")
local cfgModes = {
  m_away = { id = "m_away", occupancy = "UNOCCUPIED" },
  m_home = { id = "m_home", occupancy = "OCCUPIED" },
  m_custom = { id = "m_custom" },
}
active.PRESENCE = "m_away"
check("away => UNOCCUPIED", trig:occupancy(cfgModes).state == "UNOCCUPIED")
active.PRESENCE = "m_custom"
check("no occupancy field => UNKNOWN", trig:occupancy(cfgModes).state == "UNKNOWN")
active.PRESENCE = nil
check("no presence => UNKNOWN", trig:occupancy(cfgModes).state == "UNKNOWN")

-- ── Schedule ────────────────────────────────────────────────────────────────
print("\n[9] Schedules fire when crossed, once, with guards")
local scfg = {
  modes = {
    m_sleep = {
      id = "m_sleep",
      enabled = true,
      schedules = { { id = "s1", time = "23:30", days = nil, require_presence = "m_home", enabled = true } },
    },
  },
}
local deps = {
  localtime = function(t)
    return os.date("*t", t)
  end,
  activePresence = function()
    return "m_home"
  end,
}
local before = os.time({ year = 2026, month = 8, day = 29, hour = 23, min = 29 })
local after = os.time({ year = 2026, month = 8, day = 29, hour = 23, min = 31 })
local due = schedule.tick(scfg, before, after, deps)
check("fires when the tick crosses 23:30", #due == 1 and due[1].mode_id == "m_sleep", #due)
due = schedule.tick(scfg, after, after + 60, deps)
check("does not fire again next tick", #due == 0, #due)
due = schedule.tick(scfg, 0, after, deps)
check("first-ever tick (last=0) fires nothing", #due == 0, #due)
deps.activePresence = function()
  return "m_away"
end
due = schedule.tick(scfg, before, after, deps)
check("presence guard blocks", #due == 0, #due)
deps.activePresence = function()
  return "m_home"
end
scfg.modes.m_sleep.schedules[1].days = { 1 } -- Sundays only; the 29th is Saturday
due = schedule.tick(scfg, before, after, deps)
check("day filter blocks Saturday", #due == 0, #due)
scfg.modes.m_sleep.schedules[1].days = { 7 }
due = schedule.tick(scfg, before, after, deps)
check("day filter passes Saturday", #due == 1, #due)
-- Catch-up straddling a restart: last is 2 hours ago, occurrence in between.
due = schedule.tick(scfg, after - 2 * 3600 - 120, after, deps)
check("restart catch-up fires once", #due == 1, #due)
check("ancient last is capped", #schedule.tick(scfg, after - 90 * 24 * 3600, after, deps) <= 1)

-- ── History ─────────────────────────────────────────────────────────────────
print("\n[10] History: bounded ring, persistence, rendering")
local persisted = {}
local hPersist = {
  get = function(key, default)
    if persisted[key] == nil then
      return default
    end
    return persisted[key]
  end,
  set = function(key, value)
    persisted[key] = value
  end,
}
local hist = historylib.new({ limit = 5, persist = hPersist })
for i = 1, 8 do
  hist:add({
    mode_id = "m_away",
    activation_id = "a" .. i,
    source = "KEYPAD",
    time = i,
    result = "SUCCESS",
    actions = 3,
    succeeded = 3,
    failures = {},
  })
end
check("bounded at 5", #hist:list() == 5, #hist:list())
check("newest first", hist:list()[1].activation_id == "a8")
local hist2 = historylib.new({ limit = 5, persist = hPersist })
check("reload from persist", #hist2:list() == 5)
local line = historylib.renderLine(
  {
    mode_id = "m",
    time = 1,
    result = "SUCCESS_WITH_WARNINGS",
    source = "KEYPAD",
    meta = { slot_name = "Kitchen 5", gesture = "hold", hold_s = 3.2 },
    failures = { { device = "Shade", detail = "offline" } },
  },
  function()
    return "Away"
  end
)
check("line carries source+gesture", line:find("Kitchen 5", 1, true) ~= nil and line:find("hold", 1, true) ~= nil, line)
local detail = historylib.renderDetail(
  {
    mode_id = "m",
    activation_id = "abc",
    time = 1,
    result = "SUCCESS_WITH_WARNINGS",
    source = "KEYPAD",
    actions = 73,
    succeeded = 72,
    failures = { { device = "Pool House Shade", detail = "Device unavailable" } },
  },
  function()
    return "Away"
  end
)
check("detail names the failed device (§40)", detail:find("Pool House Shade", 1, true) ~= nil, detail)

-- ── LED ─────────────────────────────────────────────────────────────────────
print("\n[11] LED engine: follow modes, inheritance, dedupe, pulse bounds")
local modes = {
  m_home = { id = "m_home", category = "PRESENCE", color = "22aa44" },
  m_away = { id = "m_away", category = "PRESENCE", color = "2266dd" },
  m_movie = { id = "m_movie", category = "LIFESTYLE", color = "223399" },
}
local ctx = { modes = modes, active = { PRESENCE = "m_home" } }
local houseSlot = { led = { follow = "GLOBAL" } }
local d = led.compute(houseSlot, ctx, "s_house")
check("house button shows home green, lit", d.on_color == "22aa44" and d.state == 1, d.on_color)
ctx.active.PRESENCE = "m_away"
d = led.compute(houseSlot, ctx, "s_house")
check("presence change recolors the house button", d.on_color == "2266dd")

local awaySlot = { led = { follow = "MODE", mode_id = "m_away" } }
d = led.compute(awaySlot, ctx, "s_away")
check("mode slot lit when its mode is active", d.state == 1)
ctx.active.PRESENCE = "m_home"
d = led.compute(awaySlot, ctx, "s_away")
check("and dark when not", d.state == 0)
check("inherited color updates with the mode (§128)", d.on_color == "2266dd")
modes.m_away.color = "8800ff"
d = led.compute(awaySlot, ctx, "s_away")
check("recoloring Away repaints inheriting slots", d.on_color == "8800ff")
awaySlot.led.inherit = false
awaySlot.led.color = "ffffff"
d = led.compute(awaySlot, ctx, "s_away")
check("explicit color wins over inheritance", d.on_color == "ffffff")

ctx.transitioning_id = "m_away"
awaySlot.led = { follow = "MODE", mode_id = "m_away" }
d = led.compute(awaySlot, ctx, "s_away")
check("transitioning mode pulses", d.pulse == true and d.state == 1)
ctx.transitioning_id = nil
ctx.holding_slot = "s_away"
d = led.compute(awaySlot, ctx, "s_away")
check("hold-confirm pulses on the held slot", d.pulse == true)
ctx.holding_slot = nil

d = led.compute(awaySlot, { modes = modes, active = {}, override = { kind = "failure" } }, "s_away")
check("failure override goes red", d.on_color == led.RED and d.pulse == true)

check(
  "unmanaged slot returns nil (leave the keypad alone)",
  led.compute({ led = { follow = "NONE" } }, ctx, "x") == nil
)

local diff, cache = led.diff(nil, { on_color = "22aa44", off_color = "051105", state = 1 })
check("first sync sends everything", diff.colors and diff.state)
diff = led.diff(cache, { on_color = "22aa44", off_color = "051105", state = 1 })
check("unchanged state sends NOTHING (§17)", diff.colors == false and diff.state == false)
diff = led.diff(cache, { on_color = "22aa44", off_color = "051105", state = 0 })
check("state flip sends state only", diff.colors == false and diff.state == true)

check("dim() scales", led.dim("ff0000", 0.5) == "800000", led.dim("ff0000", 0.5))

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
