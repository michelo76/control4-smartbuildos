-- Daypart Scheduler engine: block validation, overlaps, which block is active
-- (weekly, holiday, today-only, midnight crossing), reconcile/restart/clock/DST
-- behaviour, volume ramp and command plans. No controller, an injected clock.
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

local E = require("daypart.engine")

-- ── a controllable wall clock ───────────────────────────────────────────────
-- The "epoch" here is wall-clock seconds (as if the zone were UTC), which is
-- all the engine looks at. A test that needs DST swaps in its own localtime.
local function at(date, hhmm)
  local y, m, d = date:match("^(%d+)-(%d+)-(%d+)$")
  local h, mi = hhmm:match("^(%d+):(%d+)$")
  return E.daysFromCivil(tonumber(y), tonumber(m), tonumber(d)) * 86400 + tonumber(h) * 3600 + tonumber(mi) * 60
end
local function wallLocaltime(epoch)
  local days = math.floor(epoch / 86400)
  local rem = epoch - days * 86400
  local y, m, d = E.civilFromDays(days)
  return {
    year = y,
    month = m,
    day = d,
    hour = math.floor(rem / 3600),
    min = math.floor(rem % 3600 / 60),
    sec = rem % 60,
  }
end

local MON = "2026-11-09" -- a Monday
local TUE, WED, THU, FRI, SAT, SUN, NEXTMON =
  "2026-11-10", "2026-11-11", "2026-11-12", "2026-11-13", "2026-11-14", "2026-11-15", "2026-11-16"

local ZONE = {
  slot = 1,
  name = "Dining",
  room = 100,
  sources = { { id = 200, label = "Morning playlist" }, { id = 201, label = "Radio" } },
  displays = { { id = 300, label = "Bar TV" } },
  min = 10,
  max = 50,
}

local clock = { t = at(MON, "06:00") }
local function newEngine(zones)
  local e = E.new({
    now = function()
      return clock.t
    end,
    localtime = wallLocaltime,
  })
  e:setZones(zones or { [1] = ZONE })
  return e
end

local function block(name, days, from, to, extra)
  local b = { name = name, days = days, from = from, to = to, source = 200, volume = 30 }
  for k, v in pairs(extra or {}) do
    b[k] = v
  end
  return b
end
local WEEKDAYS = { 1, 2, 3, 4, 5 }

print("[1] calendar arithmetic")
check("2026-11-09 is Monday", E.isoWeekday(E.daysFromCivil(2026, 11, 9)) == 1)
check("2024-02-29 is Thursday", E.isoWeekday(E.daysFromCivil(2024, 2, 29)) == 4)
local rt = true
for z = -800, 800, 37 do
  local y, m, d = E.civilFromDays(z * 40)
  rt = rt and E.daysFromCivil(y, m, d) == z * 40
end
check("civil date round-trips", rt)
check("parseDate rejects 30 February", E.parseDate("2026-02-30") == nil and E.parseDate("2026-02-28") ~= nil)
check("parseDate rejects junk", E.parseDate("11/09/2026") == nil and E.parseDate("") == nil)
check(
  "parseTime",
  E.parseTime("07:05") == 425
    and E.parseTime("7:05") == 425
    and E.parseTime("24:00") == nil
    and E.parseTime("24:00", true) == 1440
)
check("parseTime rejects 25:00 and 10:75", E.parseTime("25:00", true) == nil and E.parseTime("10:75") == nil)
check(
  "describeDays",
  E.describeDays({ 1, 2, 3, 4, 5 }) == "Mon-Fri"
    and E.describeDays({ 6, 7 }) == "Sat, Sun"
    and E.describeDays({ 1, 3, 5 }) == "Mon, Wed, Fri"
    and E.describeDays({ 1, 2, 3, 4, 5, 6, 7 }) == "every day"
)

print("[2] block validation: allowed sources only, clamped volume")
local e = newEngine()
local r, err = e:addBlock(1, "week", block("Morning", WEEKDAYS, "07:00", "11:00"))
check("a good block is saved", r ~= nil and r.block.id ~= nil, err)
check(
  "saved block shape",
  r.block.name == "Morning"
    and r.block.from == "07:00"
    and r.block.to == "11:00"
    and r.block.source == 200
    and r.block.volume == 30
)
r, err = e:addBlock(1, "week", block("Bad", WEEKDAYS, "12:00", "13:00", { source = 999 }))
check("a source the dealer did not allow is refused", r == nil and err:find("not allowed"), err)
r, err = e:addBlock(1, "week", block("Loud", WEEKDAYS, "12:00", "13:00", { volume = 90 }))
check(
  "volume above the range is clamped, with a warning",
  r ~= nil and r.block.volume == 50 and #r.warnings == 1 and r.warnings[1]:find("set to 50"),
  err
)
r = e:addBlock(1, "week", block("Quiet", WEEKDAYS, "13:00", "14:00", { volume = 0 }))
check("volume below the range is clamped up", r ~= nil and r.block.volume == 10)
r, err = e:addBlock(1, "week", block("", WEEKDAYS, "15:00", "16:00"))
check("name required", r == nil and err:find("name"), err)
r, err = e:addBlock(1, "week", block("NoDays", {}, "15:00", "16:00"))
check("at least one day", r == nil and err:find("day"), err)
r, err = e:addBlock(1, "week", block("Zero", WEEKDAYS, "15:00", "15:00"))
check("same start and end refused", r == nil and err:find("same time"), err)
r, err = e:addBlock(1, "week", block("BadTime", WEEKDAYS, "25:00", "16:00"))
check("invalid time refused", r == nil and err:find("start time"), err)
r, err = e:addBlock(1, "week", block("Disp", WEEKDAYS, "15:00", "16:00", { displays = "on" }))
check("displays on a zone with a display", r ~= nil and r.block.displays == "on", err)
local bare = newEngine({
  [1] = { slot = 1, name = "Lobby", room = 100, sources = ZONE.sources, displays = {}, min = 0, max = 100 },
})
r, err = bare:addBlock(1, "week", block("Disp", WEEKDAYS, "15:00", "16:00", { displays = "on" }))
check("displays refused where the zone has none", r == nil and err:find("no displays"), err)
r = e:addBlock(1, "week", block("Silent", { 6 }, "09:00", "10:00", { source = "off", volume = 30 }))
check("Music off needs no volume", r ~= nil and r.block.source == "off" and r.block.volume == nil)
r, err = e:addBlock(2, "week", block("Ghost", WEEKDAYS, "09:00", "10:00"))
check("an unconfigured zone refuses edits", r == nil and err:find("not set up"), err)
r, err = e:addBlock(1, "weekly", block("X", WEEKDAYS, "09:00", "10:00"))
check("unknown schedule scope refused", r == nil)
r = e:addBlock(1, "week", block("  Evening   mix | x ", { 7 }, "18:00", "24:00"))
check(
  "name is cleaned and 24:00 is a valid end",
  r ~= nil and r.block.name == "Evening mix x" and r.block.to == "24:00"
)

print("[3] overlaps are refused at edit time with a clear message")
e = newEngine()
e:addBlock(1, "week", block("Lunch", WEEKDAYS, "11:00", "14:00"))
r, err = e:addBlock(1, "week", block("Clash", { 3 }, "13:00", "15:00"))
check(
  "overlap refused and named",
  r == nil and err:find('Overlaps "Lunch"') and err:find("11:00%-14:00") and err:find("Wednesday"),
  err
)
r = e:addBlock(1, "week", block("Adjacent", WEEKDAYS, "14:00", "16:00"))
check("blocks that touch do not overlap", r ~= nil)
r = e:addBlock(1, "week", block("Weekend", { 6, 7 }, "11:00", "14:00"))
check("same hours on other days are fine", r ~= nil)
r = e:addBlock(1, "week", block("Late", { 5 }, "22:00", "02:00"))
check("a midnight-crossing block is accepted", r ~= nil)
r, err = e:addBlock(1, "week", block("SatEarly", { 6 }, "01:00", "03:00"))
check("it collides with the Saturday small hours", r == nil and err:find('"Late"') and err:find("Saturday"), err)
r = e:addBlock(1, "week", block("SatLater", { 6 }, "02:00", "03:00"))
check("but not once it has ended", r ~= nil)
r, err = e:addBlock(1, "week", block("SunWrap", { 7 }, "23:00", "08:00"))
check("Sunday into Monday wraps the week", r ~= nil, err)
r, err = e:addBlock(1, "week", block("MonEarly", { 1 }, "06:00", "07:30"))
check("and is seen from Monday morning", r == nil and err:find('"SunWrap"') and err:find("Monday"), err)
-- editing a block does not collide with itself
local lunchId
for _, b in ipairs(e.doc.zones[1].week) do
  if b.name == "Lunch" then
    lunchId = b.id
  end
end
r, err = e:updateBlock(1, "week", lunchId, block("Lunch", WEEKDAYS, "11:30", "14:00"))
check("editing a block ignores itself", r ~= nil, err)
r, err = e:updateBlock(1, "week", lunchId, block("Lunch", WEEKDAYS, "11:30", "14:30"))
check("editing into a neighbour is refused", r == nil and err:find("Overlaps"), err)
r, err = e:updateBlock(1, "week", "nope", block("X", WEEKDAYS, "01:00", "02:00"))
check("editing a vanished block says so", r == nil and err:find("no longer exists"), err)
-- holiday template is one circular day
local h = newEngine()
h:addBlock(1, "holiday", block("Brunch", {}, "22:00", "02:00"))
r, err = h:addBlock(1, "holiday", block("EarlyBird", {}, "01:00", "03:00"))
check("holiday template: crossing block collides with the small hours", r == nil and err:find("Overlaps"), err)
r = h:addBlock(1, "holiday", block("Noon", {}, "12:00", "13:00"))
check("holiday template: separate hours fine", r ~= nil)
-- today-only is linear for one date
local t = newEngine()
t:addBlock(1, "today", block("Event", {}, "20:00", "02:00"))
r, err = t:addBlock(1, "today", block("Late", {}, "23:00", "23:30"))
check("today only: a block inside the crossing one is refused", r == nil and err:find('"Event"'), err)
r = t:addBlock(1, "today", block("Early", {}, "01:00", "03:00"))
check("today only: the same hours at the start of the date are a different time", r ~= nil)
r = t:addBlock(1, "today", block("Morning", {}, "08:00", "09:00"))
check("today only: before the crossing block is fine", r ~= nil)

print("[4] which block is active")
e = newEngine()
e:addBlock(1, "week", block("Morning", WEEKDAYS, "07:00", "11:00"))
e:addBlock(1, "week", block("Late", { 5 }, "22:00", "02:00"))
e:addBlock(1, "week", block("Overnight", { 7 }, "23:00", "06:30"))
local function active(date, hhmm, eng)
  eng = eng or e
  local a = eng:resolve(1, eng:moment(at(date, hhmm)))
  return a and a.block.name or nil
end
check("before the block", active(MON, "06:59") == nil)
check("at the start minute", active(MON, "07:00") == "Morning")
check("last minute inside", active(MON, "10:59") == "Morning")
check("end is exclusive", active(MON, "11:00") == nil)
check("not on a day it is not set for", active(SAT, "08:00") == nil)
check("Friday 23:00 is in Late", active(FRI, "23:00") == "Late")
check("Saturday 01:59 is still in Friday's Late", active(SAT, "01:59") == "Late")
check("Saturday 02:00 it is over", active(SAT, "02:00") == nil)
check("Friday 21:59 not yet", active(FRI, "21:59") == nil)
check("Sunday 23:30 in Overnight", active(SUN, "23:30") == "Overnight")
check("Monday 00:30 still Sunday's Overnight", active(NEXTMON, "00:30") == "Overnight")
check("Monday 06:45 after Overnight ended: nothing", active(NEXTMON, "06:45") == nil)
check("Monday 07:30: Morning", active(NEXTMON, "07:30") == "Morning")
-- A block spilling past midnight and the next day's own first block (a
-- different template, so the edit-time check cannot see it): the later start wins.
do
  local x = newEngine()
  x:addBlock(1, "week", block("Overnight", { 7 }, "23:00", "08:00"))
  x:addBlock(1, "holiday", block("Holiday opening", {}, "07:00", "12:00"))
  x:setHolidays({ NEXTMON })
  check(
    "spill vs next day's block: the one that started later wins",
    active(NEXTMON, "07:30", x) == "Holiday opening" and active(NEXTMON, "06:30", x) == "Overnight"
  )
end
local a = e:resolve(1, e:moment(at(SAT, "01:00")))
check("the instance belongs to the day it started", a.date == FRI and a.minutesIn == 180, a and a.date)

print("[5] holidays pick an alternate template; today-only overrides both")
e = newEngine()
e:addBlock(1, "week", block("Weekday", WEEKDAYS, "07:00", "17:00"))
e:addBlock(1, "holiday", block("Holiday brunch", {}, "10:00", "15:00"))
local okH, errH = e:setHolidays({ WED, "2026-12-25" })
check("holiday dates saved sorted", okH ~= nil and e.doc.holidays[1] == WED, errH)
check("a holiday runs the holiday template", active(WED, "10:30") == "Holiday brunch" and active(WED, "07:30") == nil)
check("the weekday template runs the next day", active(THU, "07:30") == "Weekday")
check("isHoliday", e:isHoliday(at(WED, "12:00")) and not e:isHoliday(at(THU, "12:00")))
local empty = newEngine()
empty:addBlock(1, "week", block("Weekday", WEEKDAYS, "07:00", "17:00"))
empty:setHolidays({ WED })
check("a holiday with no holiday blocks is quiet", active(WED, "10:00", empty) == nil)
r, err = e:setHolidays({ "2026-13-40" })
check("bad holiday date refused", r == nil and err:find("not a valid date"), err)
clock.t = at(WED, "09:00")
r = e:addBlock(1, "today", block("Private event", {}, "09:00", "12:00"))
check("today-only block saved against today", r ~= nil and e.doc.zones[1].today.date == WED)
check("today-only beats the holiday template", active(WED, "10:30") == "Private event")
check("only for its date", active(THU, "10:30") == "Weekday")
local v = e:view(at(WED, "10:00"))
check(
  "view carries the override for today",
  v.zones[1].today.date == WED and #v.zones[1].today.blocks == 1 and v.zones[1].current.name == "Private event"
)
e:reconcile(at(THU, "08:00"))
check(
  "yesterday's override is kept one day (a block may spill past midnight) but no longer shown as today's",
  e.doc.zones[1].today.date == WED and e:view(at(THU, "08:00")).zones[1].today.date == ""
)
check("yesterday's holiday is kept too", #e.doc.holidays == 2)
e:reconcile(at(FRI, "08:00"))
check("a past override is dropped", e.doc.zones[1].today.date == "")
e:reconcile(at("2026-11-20", "08:00"))
check("old holiday dates are pruned", #e.doc.holidays == 1 and e.doc.holidays[1] == "2026-12-25")
clock.t = at(MON, "06:00")
r = e:addBlock(1, "today", block("One", {}, "08:00", "09:00"))
e:clearToday(1)
check("clear today's override", e.doc.zones[1].today.date == "")
r = e:addBlock(1, "today", block("One", {}, "08:00", "09:00"))
local id1 = r.block.id
e:deleteBlock(1, "today", id1)
check("deleting the last override block drops the override", e.doc.zones[1].today.date == "")

print("[6] reconcile: starts, ends, gaps, adjacent blocks")
e = newEngine()
e:addBlock(1, "week", block("Morning", WEEKDAYS, "07:00", "11:00", { volume = 30 }))
e:addBlock(1, "week", block("Midday", WEEKDAYS, "11:00", "14:00", { volume = 40 }))
local acts = e:reconcile(at(MON, "06:59"))
check("nothing before the first block", #acts == 0)
acts = e:reconcile(at(MON, "07:00"))
check(
  "block start",
  #acts == 1 and acts[1].kind == "start" and acts[1].block.name == "Morning" and acts[1].minutes_in == 0
)
acts = e:reconcile(at(MON, "07:01"))
check("no repeat while it runs", #acts == 0)
e:markSteady(1)
acts = e:reconcile(at(MON, "11:00"))
check(
  "adjacent blocks: end then start, not a gap",
  #acts == 2
    and acts[1].kind == "end"
    and acts[1].gap == false
    and acts[2].kind == "start"
    and acts[2].block.name == "Midday"
)
acts = e:reconcile(at(MON, "14:00"))
check(
  "last block: end into a gap",
  #acts == 1 and acts[1].kind == "end" and acts[1].gap == true and acts[1].run.name == "Midday"
)
acts = e:reconcile(at(MON, "14:05"))
check("quiet after", #acts == 0)

print("[7] editing the running block applies it; deleting it ends it")
e = newEngine()
r = e:addBlock(1, "week", block("Morning", WEEKDAYS, "07:00", "11:00", { volume = 30 }))
e:reconcile(at(MON, "08:00"))
e:markSteady(1)
e:updateBlock(1, "week", r.block.id, block("Morning", WEEKDAYS, "07:00", "11:00", { volume = 20 }))
acts = e:reconcile(at(MON, "08:00"))
check(
  "a changed level re-applies, without a new Block Started",
  #acts == 1 and acts[1].kind == "start" and acts[1].update == true and acts[1].block.volume == 20
)
e:updateBlock(1, "week", r.block.id, block("Morning (renamed)", WEEKDAYS, "07:00", "11:00", { volume = 20 }))
acts = e:reconcile(at(MON, "08:00"))
check("a rename alone changes nothing on the air", #acts == 0 and e.run[1].name == "Morning (renamed)")
e:deleteBlock(1, "week", r.block.id)
acts = e:reconcile(at(MON, "08:01"))
check("deleting the running block ends it", #acts == 1 and acts[1].kind == "end" and acts[1].gap == true)

print("[8] controller restart mid-block: resume the right block, do not restart it")
e = newEngine()
e:addBlock(1, "week", block("Morning", WEEKDAYS, "07:00", "11:00", { volume = 30 }))
e:addBlock(1, "week", block("Midday", WEEKDAYS, "11:00", "14:00", { volume = 40 }))
e:reconcile(at(MON, "07:00"))
e:markSteady(1)
local saved = e:serialize()
local e2 = newEngine()
e2:restore(saved)
acts = e2:reconcile(at(MON, "09:00"))
check(
  "restart inside a finished block: nothing re-announced, nothing re-sent",
  #acts == 0 and e2.run[1] ~= nil and e2.run[1].name == "Morning"
)
-- restart while the ramp was still running
e = newEngine()
e:addBlock(1, "week", block("Morning", WEEKDAYS, "07:00", "11:00", { volume = 30 }))
e:reconcile(at(MON, "07:00")) -- ramping, never marked steady
e2 = newEngine()
e2:restore(e:serialize())
acts = e2:reconcile(at(MON, "07:00"))
check(
  "restart mid-ramp: the ramp is resumed (not a new start)",
  #acts == 1 and acts[1].kind == "start" and acts[1].resume == true
)
acts = e2:reconcile(at(MON, "07:00"))
check("the resume is offered once", #acts == 0)
-- the block ended while the controller was down
e2 = newEngine()
e2:restore(saved)
acts = e2:reconcile(at(MON, "11:30"))
check(
  "block moved on during the outage: old ends, new starts late",
  #acts == 2
    and acts[1].kind == "end"
    and acts[2].kind == "start"
    and acts[2].block.name == "Midday"
    and acts[2].minutes_in == 30
)
e2 = newEngine()
e2:restore(saved)
acts = e2:reconcile(at(MON, "15:00"))
check(
  "the day finished during the outage: it ends into a gap",
  #acts == 1 and acts[1].kind == "end" and acts[1].gap == true
)
local blank = newEngine()
blank:restore(saved)
check(
  "the schedule survives the round trip",
  #blank.doc.zones[1].week == 2 and blank.doc.nextId == saved.schedule.nextId
)
local none = newEngine()
check(
  "restoring junk is harmless",
  none:restore("junk") == 0 and none:restore({}) == 0 and none:restore({ schedule = { zones = "x" } }) == 0
)
local dirty = newEngine()
local dropped = dirty:restore({
  schedule = {
    nextId = 5,
    zones = {
      [1] = {
        week = {
          { id = "b1", name = "Ok", days = { 1 }, from = "07:00", to = "08:00" },
          { id = "b2", name = "Bad", days = { 1 }, from = "xx", to = "08:00" },
          "junk",
        },
      },
    },
    holidays = { WED, "nonsense" },
  },
})
check(
  "unreadable stored blocks are dropped, readable ones kept",
  dropped == 2 and #dirty.doc.zones[1].week == 1 and #dirty.doc.holidays == 1
)
-- string keys (a JSON round trip) restore too
local viaJson = newEngine()
viaJson:restore({
  schedule = {
    nextId = 3,
    zones = { ["1"] = { week = { { id = "b1", name = "Ok", days = { 1 }, from = "07:00", to = "08:00" } } } },
  },
})
check("zones keyed by string restore", #viaJson.doc.zones[1].week == 1)

print("[9] clock changes and daylight saving")
-- Manual clock moved back mid-block, then forward again.
e = newEngine()
e:addBlock(1, "week", block("Morning", WEEKDAYS, "07:00", "11:00"))
e:reconcile(at(MON, "08:00"))
e:markSteady(1)
acts = e:reconcile(at(MON, "06:00"))
check("clock set back before the block: it ends", #acts == 1 and acts[1].kind == "end")
acts = e:reconcile(at(MON, "09:00"))
check(
  "clock set forward into it: it starts again",
  #acts == 1 and acts[1].kind == "start" and acts[1].minutes_in == 120
)
-- Spring forward: wall clock goes 01:59 -> 03:00; 02:xx never exists.
local springDay = "2026-03-08" -- a Sunday
local function springLocaltime(epoch)
  local lt = wallLocaltime(epoch)
  if lt.hour >= 2 and lt.day == 8 and lt.month == 3 then
    lt.hour = lt.hour + 1 -- everything from "02:00" on is shown an hour later
  end
  return lt
end
e = E.new({
  now = function()
    return clock.t
  end,
  localtime = springLocaltime,
})
e:setZones({ [1] = ZONE })
e:addBlock(1, "week", block("Sunday early", { 7 }, "01:00", "02:00"))
e:addBlock(1, "week", block("Sunday small hours", { 7 }, "02:30", "04:00"))
acts = e:reconcile(at(springDay, "01:30"))
check("DST spring forward: 01:30 block running", #acts == 1 and acts[1].block.name == "Sunday early")
-- the next wall reading is 03:00 (epoch 02:00 shows as 03:00)
acts = e:reconcile(at(springDay, "02:00"))
check(
  "DST spring forward: 01:00-02:00 ends, and 02:30-04:00 starts although 02:30 never occurred",
  #acts == 2 and acts[1].kind == "end" and acts[2].kind == "start" and acts[2].block.name == "Sunday small hours",
  #acts
)
-- Fall back: wall clock reads 01:30 twice.
local readings = { "01:30", "01:50", "01:10", "01:30", "02:05" } -- the repeated hour
e = newEngine()
e:addBlock(1, "week", block("One to two", { 7 }, "01:00", "02:00"))
local seen = {}
for _, hhmm in ipairs(readings) do
  for _, a2 in ipairs(e:reconcile(at("2026-11-01", hhmm))) do
    seen[#seen + 1] = a2.kind
  end
end
check(
  "DST fall back: the repeated hour starts the block once and ends it once",
  table.concat(seen, ",") == "start,end",
  table.concat(seen, ",")
)

print("[10] Run Block Now holds until the schedule moves on; Skip Next Block")
e = newEngine()
r = e:addBlock(1, "week", block("Morning", WEEKDAYS, "07:00", "11:00", { volume = 30 }))
local party = e:addBlock(1, "week", block("Party", WEEKDAYS, "20:00", "23:00", { volume = 45 }))
e:reconcile(at(MON, "08:00"))
clock.t = at(MON, "08:00")
local manual = e:startManual(1, party.block.id, "week")
check("manual run starts", manual ~= nil and manual.name == "Party" and e.run[1].manual == true)
acts = e:reconcile(at(MON, "09:00"))
check("it holds while the schedule has not moved", #acts == 0)
acts = e:reconcile(at(MON, "11:00"))
check(
  "it ends when the block it replaced would have ended",
  #acts == 1 and acts[1].kind == "end" and acts[1].manual == true and acts[1].gap == true
)
check("name lookup is case-insensitive", e:findBlockByName(1, "party", at(MON, "08:00")) == party.block.id)
check("unknown name", e:findBlockByName(1, "nope", at(MON, "08:00")) == nil)
e = newEngine()
e:addBlock(1, "week", block("Morning", WEEKDAYS, "07:00", "11:00"))
clock.t = at(MON, "06:00")
local nx = e:nextBlock(1, e:moment(at(MON, "06:00")))
check("next block", nx.block.name == "Morning" and nx.in_days == 0 and nx.from == "07:00")
local skipped = e:skipNext(1)
check("skip next block", #skipped == 1 and skipped[1].name == "Morning")
acts = e:reconcile(at(MON, "07:30"))
check("the skipped instance never starts", #acts == 0)
nx = e:nextBlock(1, e:moment(at(MON, "07:30")))
check("the next one is tomorrow's", nx.date == TUE and nx.in_days == 1)
acts = e:reconcile(at(TUE, "07:00"))
check("tomorrow's block is not skipped", #acts == 1 and acts[1].kind == "start")
nx = e:nextBlock(1, e:moment(at(FRI, "12:00")))
check("next block looks across the weekend", nx.date == NEXTMON and nx.in_days == 3)

print("[11] read-only (licence) refuses edits, keeps reads")
e = newEngine()
e:addBlock(1, "week", block("Morning", WEEKDAYS, "07:00", "11:00"))
e:setReadOnly(true)
r, err = e:addBlock(1, "week", block("Another", WEEKDAYS, "12:00", "13:00"))
check("add refused", r == nil and err:find("read%-only"), err)
r, err = e:setHolidays({ WED })
check("holidays refused", r == nil and err:find("read%-only"), err)
check("view still answers", #e:view(at(MON, "08:00")).zones[1].week == 1)
e:setReadOnly(false)
check("edits work again after", e:addBlock(1, "week", block("Another", WEEKDAYS, "12:00", "13:00")) ~= nil)

print("[12] volume ramp")
local plan = E.rampPlan(10, 40, 20)
check("ramp ends on target at exactly the duration", plan[#plan].level == 40 and plan[#plan].at == 20)
local mono, spaced = true, true
for i = 2, #plan do
  mono = mono and plan[i].level >= plan[i - 1].level
  spaced = spaced and plan[i].at - plan[i - 1].at >= 1
end
check("ramp is monotonic and never closer than a second", mono and spaced)
check(
  "ramp is whole points, never over the target",
  (function()
    for _, s in ipairs(plan) do
      if s.level ~= math.floor(s.level) or s.level > 40 then
        return false
      end
    end
    return true
  end)()
)
check(
  "a zero-second ramp is one immediate step",
  #E.rampPlan(10, 40, 0) == 1 and E.rampPlan(10, 40, 0)[1].at == 0 and E.rampPlan(10, 40, 0)[1].level == 40
)
check("no ramp needed when already there", #E.rampPlan(30, 30, 20) == 1 and E.rampPlan(30, 30, 20)[1].level == 30)
plan = E.rampPlan(50, 20, 30)
check("a ramp down", plan[1].level < 50 and plan[#plan].level == 20 and plan[#plan].at == 30)
check("at most one step per point of volume", #E.rampPlan(10, 13, 60) == 3)
check("steps are at least two seconds apart", #E.rampPlan(0, 100, 10) <= 5)
check("levels clamp to 0..100", E.rampPlan(-5, 140, 4)[#E.rampPlan(-5, 140, 4)].level == 100)

print("[13] command plans")
local function cmds(steps)
  local out = {}
  for _, s in ipairs(steps) do
    out[#out + 1] = string.format("%d:%s:%s:%s", s.at, s.device, s.command, s.params.LEVEL or s.params.deviceid or "")
  end
  return table.concat(out, " ")
end
local pStart = E.planStart(
  ZONE,
  { name = "M", source = 200, volume = 30, displays = "on" },
  { roomOn = false, currentVolume = 70, rampSeconds = 10 }
)
check(
  "a room that was off comes up from the bottom of the range, never from its last level",
  pStart[1].command == "SELECT_AUDIO_DEVICE"
    and pStart[1].params.deviceid == 200
    and pStart[2].command == "SET_VOLUME_LEVEL"
    and pStart[2].params.LEVEL == 10,
  cmds(pStart)
)
check(
  "then ramps to the block level",
  pStart[#pStart - 1].params.LEVEL == 30 and pStart[#pStart - 1].at == 10,
  cmds(pStart)
)
check("displays switch on", pStart[#pStart].command == "ON" and pStart[#pStart].device == 300)
pStart = E.planStart(
  ZONE,
  { name = "M", source = 200, volume = 40, displays = "keep" },
  { roomOn = true, currentVolume = 25, rampSeconds = 10 }
)
check(
  "a room already playing ramps from where it is",
  pStart[2].params.LEVEL == 25 and pStart[#pStart].params.LEVEL == 40,
  cmds(pStart)
)
pStart = E.planStart(
  ZONE,
  { name = "M", volume = 40, displays = "keep" },
  { roomOn = true, currentVolume = 25, rampSeconds = 10 }
)
check(
  "volume-only block sends no source command",
  (function()
    for _, s in ipairs(pStart) do
      if s.command == "SELECT_AUDIO_DEVICE" then
        return false
      end
    end
    return true
  end)()
)
pStart = E.planStart(
  ZONE,
  { name = "M", source = 200, volume = 99 },
  { roomOn = true, currentVolume = 20, rampSeconds = 0 }
)
check("volume is clamped to the dealer's range at run time too", pStart[#pStart].params.LEVEL == 50, cmds(pStart))
pStart = E.planStart(ZONE, { name = "M", source = "off", displays = "off" }, { roomOn = true, currentVolume = 20 })
check(
  "Music off: room off, displays off",
  pStart[1].command == "ROOM_OFF" and pStart[2].command == "OFF" and #pStart == 2,
  cmds(pStart)
)
pStart = E.planStart(ZONE, { name = "M", source = 200 }, { roomOn = false })
check(
  "a source with no level and a room that was off still comes up quietly",
  pStart[2].params.LEVEL == 10,
  cmds(pStart)
)
pStart = E.planStart(
  ZONE,
  { name = "M", source = 200, volume = 30 },
  { roomOn = nil, currentVolume = nil, rampSeconds = 4 }
)
check("unknown room state starts from the bottom of the range", pStart[2].params.LEVEL == 10, cmds(pStart))
check("no room, no commands", #E.planStart({ room = nil }, { name = "x" }, {}) == 0)
check("hold does nothing", #E.planEnd(ZONE, "hold", { currentVolume = 30 }) == 0)
local pEnd = E.planEnd(ZONE, "off", {})
check(
  "off: room and displays off at once",
  pEnd[1].command == "ROOM_OFF" and pEnd[1].at == 0 and pEnd[2].command == "OFF"
)
pEnd = E.planEnd(ZONE, "fade", { currentVolume = 30, fadeSeconds = 20 })
check(
  "fade ends at zero then turns the room off",
  pEnd[#pEnd - 1].command == "ROOM_OFF" and pEnd[#pEnd - 2].params.LEVEL == 0,
  cmds(pEnd)
)
check(
  "fade waits for the ramp before turning off",
  pEnd[#pEnd - 1].at == 21 and pEnd[#pEnd].command == "OFF" and pEnd[#pEnd].at == 21,
  cmds(pEnd)
)
pEnd = E.planEnd(ZONE, "fade", { currentVolume = nil, fadeSeconds = 20 })
check("fade with an unknown level just turns off", pEnd[1].command == "ROOM_OFF", cmds(pEnd))

print("[14] limits")
e = newEngine()
local over
for i = 1, E.MAX_BLOCKS + 1 do
  local hour = (i - 1) % 24
  over = e:addBlock(1, "today", block("B" .. i, {}, string.format("%02d:00", hour), string.format("%02d:30", hour)))
end
check("a schedule list is capped", over == nil)

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
