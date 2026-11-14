-- VenueFlow schedules (pure): fire once per day and time on the controller's
-- local clock, survive midnight, catch up the hour skipped when clocks go
-- forward, do not fire twice in the hour repeated when clocks go back, and do
-- not run late after the driver was stopped.
--
-- The daylight-saving cases use a scripted localtime(): they prove the
-- arithmetic, not a controller's clock. A real change is in the hardware plan.
--
-- Run from the driver root: make test

local H = require("venueflow_harness")
local Scheduler = require("venueflow.scheduler")
local T = H.checker()
local check, eq = T.check, T.eq

--- A scheduler over a scripted wall clock. `wall(epoch)` returns
--- { year, month, day, hour, min, wday }.
local function make(rules, wall, lastFired)
  local t = { now = 0, fired = {}, missed = {}, saves = 0 }
  t.s = Scheduler.new({
    now = function()
      return t.now
    end,
    localtime = wall,
    rules = function()
      return rules
    end,
    lastFired = lastFired or {},
    fire = function(rule, stamp)
      t.fired[#t.fired + 1] = rule.id .. "@" .. stamp
    end,
    missed = function(rule, stamp)
      t.missed[#t.missed + 1] = rule.id .. "@" .. stamp
    end,
    save = function()
      t.saves = t.saves + 1
    end,
  })
  function t.at(epoch)
    t.now = epoch
    return t.s:tick()
  end
  return t
end

--- Plain wall clock: epoch seconds counted from Monday 2026-11-09 00:00.
local function plain(epoch)
  local day = math.floor(epoch / 86400)
  local rem = epoch - day * 86400
  return {
    year = 2026,
    month = 11,
    day = 9 + day,
    hour = math.floor(rem / 3600),
    min = math.floor(rem % 3600 / 60),
    wday = ((1 + day) % 7) + 1, -- day 0 is Monday = wday 2
  }
end
local function hm(day, h, m, s)
  return day * 86400 + h * 3600 + m * 60 + (s or 0)
end

local function rule(id, days, time, enabled)
  return { id = id, name = id, enabled = enabled, trigger = { type = "schedule", days = days, time = time } }
end

-- ── ordinary firing ─────────────────────────────────────────────────────────
print("ordinary schedules")
local rules = {
  rule("open", { 1, 2, 3, 4, 5 }, "11:00"),
  rule("happy", { 1, 2, 3, 4, 5 }, "16:00"),
  rule("weekend", { 6, 7 }, "10:00"),
  rule("off", { 1 }, "11:00", false),
  { id = "manual", name = "manual", trigger = { type = "manual" } },
}
local t = make(rules, plain)
eq("the first tick only takes its bearings", t.at(hm(0, 10, 59, 40)), 0)
eq("not due yet", t.at(hm(0, 10, 59, 59)), 0)
eq("due at 11:00", t.at(hm(0, 11, 0, 19)), 1)
eq("fired with its stamp", t.fired[1], "open@2026-11-09 11:00")
eq("not again in the same minute", t.at(hm(0, 11, 0, 39)), 0)
eq("not again in the next minute", t.at(hm(0, 11, 1, 0)), 0)
eq("a disabled rule never fires", #t.fired, 1)
for s = hm(0, 11, 1, 20), hm(0, 16, 0, 20), 20 do
  t.at(s)
end
eq("the afternoon schedule fired once", t.fired[2], "happy@2026-11-09 16:00")
eq("two firings so far", #t.fired, 2)
check("firing is persisted", t.saves >= 2)

-- across midnight into Tuesday
for s = hm(0, 16, 0, 40), hm(1, 11, 0, 20), 20 do
  t.at(s)
end
eq("fires again the next weekday", t.fired[3], "open@2026-11-10 11:00")

-- the weekend rule only on Saturday (day 5) and Sunday (day 6)
local w = make({ rule("weekend", { 6, 7 }, "10:00") }, plain)
for s = hm(4, 9, 59, 0), hm(4, 10, 1, 0), 20 do
  w.at(s)
end
eq("Friday: the weekend rule stays quiet", #w.fired, 0)
for s = hm(5, 9, 59, 0), hm(5, 10, 1, 0), 20 do
  w.at(s)
end
eq("Saturday: it fires", w.fired[1], "weekend@2026-11-14 10:00")

-- a schedule exactly at midnight, with ticks either side of it
local m = make({ rule("midnight", { 2 }, "00:00") }, plain)
m.at(hm(0, 23, 59, 50))
eq("midnight schedule fires on the new day", m.at(hm(1, 0, 0, 10)), 1)
eq("stamped with the new date", m.fired[1], "midnight@2026-11-10 00:00")

-- two schedules in one tick fire in time order
local o = make({ rule("b", { 1 }, "09:01"), rule("a", { 1 }, "09:00") }, plain)
o.at(hm(0, 8, 59, 50))
o.at(hm(0, 9, 1, 30))
eq("earlier time first", o.fired[1] .. " " .. o.fired[2], "a@2026-11-09 09:00 b@2026-11-09 09:01")

-- ── a restart must not fire again, and must not run late ────────────────────
print("restart and downtime")
local remembered = { open = "2026-11-09 11:00" }
local r = make({ rule("open", { 1 }, "11:00") }, plain, remembered)
r.at(hm(0, 10, 59, 50))
eq("already fired before the restart: not fired again", r.at(hm(0, 11, 0, 20)), 0)

local d = make({ rule("open", { 1 }, "11:00") }, plain)
d.at(hm(0, 8, 0, 0))
eq("three hours of downtime: the schedule is not run late", d.at(hm(0, 11, 30, 0)), 0)
eq("...it is reported as missed", d.missed[1], "open@2026-11-09 11:00")
eq("...and not reported twice", (d.at(hm(0, 11, 30, 20)) == 0) and #d.missed, 1)

local short = make({ rule("open", { 1 }, "11:00") }, plain)
short.at(hm(0, 10, 58, 0))
eq("a gap of a few minutes is caught up", short.at(hm(0, 11, 2, 0)), 1)

-- ── clocks go FORWARD: 02:00 becomes 03:00 ──────────────────────────────────
print("daylight saving: clocks forward")
local function springForward(epoch)
  -- Real seconds from 00:00. After 2 h of real time the wall clock jumps an hour.
  local wallSeconds = epoch
  if epoch >= 2 * 3600 then
    wallSeconds = epoch + 3600
  end
  return {
    year = 2027,
    month = 3,
    day = 14,
    hour = math.floor(wallSeconds / 3600),
    min = math.floor(wallSeconds % 3600 / 60),
    wday = 1, -- Sunday
  }
end
local f = make(
  { rule("skipped", { 7 }, "02:30"), rule("after", { 7 }, "03:15"), rule("before", { 7 }, "01:30") },
  springForward
)
for s = 3600, 2 * 3600 - 20, 20 do -- 01:00 .. 01:59:40
  f.at(s)
end
eq("before the change: fires normally", f.fired[1], "before@2027-03-14 01:30")
eq("the tick across the jump fires the skipped schedule", f.at(2 * 3600), 1)
eq("...once, stamped with its own time", f.fired[2], "skipped@2027-03-14 02:30")
for s = 2 * 3600 + 20, 2 * 3600 + 20 * 60, 20 do
  f.at(s)
end
eq("the schedule after the jump fires at its time", f.fired[3], "after@2027-03-14 03:15")
eq("three firings in all", #f.fired, 3)

-- ── clocks go BACK: 02:00 becomes 01:00 ─────────────────────────────────────
print("daylight saving: clocks back")
local function fallBack(epoch)
  local wallSeconds = epoch
  if epoch >= 2 * 3600 then
    wallSeconds = epoch - 3600
  end
  return {
    year = 2026,
    month = 11,
    day = 1,
    hour = math.floor(wallSeconds / 3600),
    min = math.floor(wallSeconds % 3600 / 60),
    wday = 1,
  }
end
local b = make({ rule("repeated", { 7 }, "01:30"), rule("later", { 7 }, "02:10") }, fallBack)
for s = 3600, 4 * 3600, 20 do -- wall 01:00 .. 01:59, then 01:00 .. 02:59
  b.at(s)
end
local count = 0
for _, stamp in ipairs(b.fired) do
  if stamp == "repeated@2026-11-01 01:30" then
    count = count + 1
  end
end
eq("a schedule in the repeated hour fires once", count, 1)
eq("the schedule after the repeated hour fires", b.fired[#b.fired], "later@2026-11-01 02:10")
eq("two firings in all", #b.fired, 2)

-- a clock set back by hand does not fire anything twice either
local h = make({ rule("x", { 1 }, "09:00") }, plain)
h.at(hm(0, 8, 59, 50))
h.at(hm(0, 9, 0, 10))
h.now = hm(0, 8, 0, 0)
eq("clock set back: nothing fires", h.s:tick(), 0)
for s = hm(0, 8, 0, 20), hm(0, 9, 1, 0), 20 do
  h.at(s)
end
eq("...and the same day's schedule does not fire a second time", #h.fired, 1)

-- ── upcoming ────────────────────────────────────────────────────────────────
print("upcoming")
local u = make({ rule("open", { 1, 2, 3, 4, 5 }, "11:00"), rule("weekend", { 6, 7 }, "10:00") }, plain)
u.now = hm(0, 12, 0, 0) -- Monday noon
local up = u.s:upcoming(5)
eq("next weekday opening is tomorrow", up[1].ruleId .. "+" .. up[1].inDays, "open+1")
eq("the weekend rule is five days out", up[2].ruleId .. "+" .. up[2].inDays, "weekend+5")

-- ── in the core: a schedule runs its rule, and a restricted licence pauses it ─
print("in the core")
local clock = H.clock(H.MONDAY_NOON - 3600 - 90) -- Monday 10:58:30 UTC
local env = H.new({ clock = clock })
env.publishSample("sports_bar")
eq("venue closed before the schedule", env.core.runtime.venueStatus, "closed")
env.settle(4 * 60 * 1000)
eq("the 11:00 weekday schedule ran Opening", env.core.runtime.venueStatus, "open")
env.settle(8000)
eq("its scene's routes happened", env.cell("display", "tv-01", "source").value, "news")
check("the firing is remembered across restarts", env.kv.get("vf_runtime_v1").lastFired["open-weekdays"] ~= nil)

local env2 = H.new({ clock = H.clock(H.MONDAY_NOON - 3600 - 90) })
env2.publishSample("sports_bar")
env2.license.label = "Not Licensed"
env2.license.enforce = true
env2.core:licenseChanged()
env2.settle(4 * 60 * 1000)
eq("a restricted licence pauses schedules", env2.core.runtime.venueStatus, "closed")

T.done()
