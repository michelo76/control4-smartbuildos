package.path = "src/?.lua;" .. package.path
local Ical = require("guestmode.ical")
local Stays = require("guestmode.stays")
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

-- A fixed "UTC-like" clock: mktime/date are implemented over a flat day
-- count so the tests do not depend on the machine's timezone or DST.
local function days(y, m, d)
  -- days since 1970-01-01 (proleptic Gregorian, valid for 1970..2099)
  local a = math.floor((14 - m) / 12)
  local yy = y + 4800 - a
  local mm = m + 12 * a - 3
  local jdn = d
    + math.floor((153 * mm + 2) / 5)
    + 365 * yy
    + math.floor(yy / 4)
    - math.floor(yy / 100)
    + math.floor(yy / 400)
    - 32045
  return jdn - 2440588
end
local function mktime(t)
  return days(t.year, t.month, t.day) * 86400 + (t.hour or 0) * 3600 + (t.min or 0) * 60 + (t.sec or 0)
end
local function date(fmt, t)
  local dayNo = math.floor(t / 86400)
  return string.format("D%d", dayNo) -- only %Y-%m-%d equality matters to the engine
end
local deps = {
  mktime = mktime,
  utcOffset = function()
    return -3600
  end,
} -- "local" = UTC-1 for the Z test
local function at(y, m, d, hh, mi)
  return mktime({ year = y, month = m, day = d, hour = hh or 0, min = mi or 0 })
end

print("== parseClock")
check("15:00 → 900", Stays.parseClock("15:00", 0) == 900 and Stays.parseClock(" 9:30 ", 0) == 570)
check("bad → default", Stays.parseClock("25:00", 660) == 660 and Stays.parseClock("", 660) == 660)

print("== build")
local feed = table.concat({
  "BEGIN:VEVENT\nUID:a\nSUMMARY:Reserved\nDTSTART;VALUE=DATE:20261110\nDTEND;VALUE=DATE:20261113\nEND:VEVENT",
  "BEGIN:VEVENT\nUID:b\nSUMMARY:Jane Doe\nDTSTART;VALUE=DATE:20261113\nDTEND;VALUE=DATE:20261115\nEND:VEVENT",
  "BEGIN:VEVENT\nUID:blk\nSUMMARY:Airbnb (Not available)\nDTSTART;VALUE=DATE:20261120\nDTEND;VALUE=DATE:20261122\nEND:VEVENT",
  "BEGIN:VEVENT\nUID:z\nSUMMARY:Timed Z\nDTSTART:20261201T140000Z\nDTEND:20261203T100000Z\nEND:VEVENT",
  "BEGIN:VEVENT\nUID:dur\nSUMMARY:Dur\nDTSTART;VALUE=DATE:20261210\nDURATION:P2D\nEND:VEVENT",
  "BEGIN:VEVENT\nUID:bad\nSUMMARY:Ends before start\nDTSTART;VALUE=DATE:20261220\nDTEND;VALUE=DATE:20261219\nEND:VEVENT",
}, "\n")
local events = Ical.parse(feed)
local opts = { checkinMinutes = 15 * 60, checkoutMinutes = 11 * 60, blocksAre = "ignore", source = "airbnb" }
local stays = Stays.build(events, opts, deps)
check("blocks ignored, inverted stay dropped → 4 stays", #stays == 4, #stays)
check("all-day: check-in 15:00 on DTSTART", stays[1].start == at(2026, 11, 10, 15, 0))
check("all-day: check-out 11:00 on DTEND day (exclusive date)", stays[1].finish == at(2026, 11, 13, 11, 0))
check("names", stays[1].name == "Guest" and stays[2].name == "Jane Doe")
check(
  "Z time shifted by the local offset",
  stays[3].start == at(2026, 12, 1, 14, 0) - 3600 and stays[3].finish == at(2026, 12, 3, 10, 0) - 3600
)
check("DURATION P2D → check-out 11:00 two days later", stays[4].finish == at(2026, 12, 12, 11, 0), stays[4].finish)
check("source carried", stays[1].source == "airbnb")
local withBlocks = Stays.build(events, { checkinMinutes = 900, checkoutMinutes = 660, blocksAre = "occupied" }, deps)
check(
  "blocks as occupied → 5 stays, named Blocked",
  #withBlocks == 5 and withBlocks[3].block and withBlocks[3].name == "Blocked"
)

print("== engine: a stay across a week")
local kinds = function(list)
  local out = {}
  for _, t in ipairs(list) do
    out[#out + 1] = t.kind
  end
  return table.concat(out, ",")
end
local eng = Stays.new({ date = date, turnoverSeconds = 4 * 3600 })
eng:setStays(stays)
local t, ev
t, ev = eng:tick(at(2026, 11, 9, 12, 0))
check("day before: vacant, no transition from the initial state", ev.status == "vacant" and #t == 0)
check("stays in next 30 days counted (a, b, z; dur is day 31)", ev.staysNext30 == 3, ev.staysNext30)
t, ev = eng:tick(at(2026, 11, 10, 8, 0))
check("check-in day, morning: arriving_today", ev.status == "arriving_today" and kinds(t) == "arriving_today")
t, ev = eng:tick(at(2026, 11, 10, 9, 0))
check("still arriving: no repeat", #t == 0)
t, ev = eng:tick(at(2026, 11, 10, 15, 0))
check("15:00: checked_in", ev.status == "occupied" and kinds(t) == "checked_in" and t[1].uid == "a")
t, ev = eng:tick(at(2026, 11, 12, 20, 0))
check("mid-stay quiet", #t == 0 and ev.status == "occupied")
t, ev = eng:tick(at(2026, 11, 13, 7, 0))
check("check-out day: departing_today, no transition kind for it", ev.status == "departing_today" and #t == 0)
t, ev = eng:tick(at(2026, 11, 13, 11, 0))
check(
  "11:00 back-to-back: checked_out a, then the turnover (b arrives today)",
  kinds(t) == "checked_out,turnover_due" and ev.status == "turnover",
  kinds(t) .. " " .. ev.status
)
t, ev = eng:tick(at(2026, 11, 13, 15, 0))
check(
  "15:00: b checks in (turnover → occupied)",
  kinds(t) == "checked_in" and t[1].uid == "b" and ev.status == "occupied"
)
t, ev = eng:tick(at(2026, 11, 15, 11, 0))
check("b checks out → turnover (window 4 h)", kinds(t) == "checked_out,turnover_due" and ev.status == "turnover")
t, ev = eng:tick(at(2026, 11, 15, 16, 0))
check("after the window: vacant", kinds(t) == "vacant" and ev.status == "vacant")
check("lastCheckout remembered", eng.lastCheckout.uid == "b")

print("== engine: overlapping stays never double check-in")
local overlap = Stays.build(
  Ical.parse(table.concat({
    "BEGIN:VEVENT\nUID:o1\nSUMMARY:One\nDTSTART;VALUE=DATE:20270105\nDTEND;VALUE=DATE:20270108\nEND:VEVENT",
    "BEGIN:VEVENT\nUID:o2\nSUMMARY:Two\nDTSTART;VALUE=DATE:20270107\nDTEND;VALUE=DATE:20270110\nEND:VEVENT",
  }, "\n")),
  opts,
  deps
)
local e2 = Stays.new({ date = date })
e2:setStays(overlap)
e2:tick(at(2027, 1, 4))
t = e2:tick(at(2027, 1, 5, 16))
check("first checks in", kinds(t) == "checked_in" and t[1].uid == "o1")
t = e2:tick(at(2027, 1, 7, 16))
check("overlap: current stays o1 (no double check-in)", #t == 0 and e2.state.stayUid == "o1")
t = e2:tick(at(2027, 1, 8, 11))
check(
  "o1 ends while o2 runs: checked_out then checked_in in one tick",
  kinds(t) == "checked_out,checked_in" and t[2].uid == "o2"
)

print("== engine: manual check-in / check-out")
local e3 = Stays.new({ date = date, turnoverSeconds = 3600 })
e3:setStays(stays)
e3:tick(at(2026, 11, 1))
check("check-in now", e3:checkIn(at(2026, 11, 1, 18), "  Walk-in  ") == true)
t, ev = e3:tick(at(2026, 11, 1, 18))
check(
  "manual stay occupied with the name",
  kinds(t) == "checked_in" and ev.current.name == "Walk-in" and ev.current.manual
)
check("second check-in refused", select(2, e3:checkIn(at(2026, 11, 2), "x")) == "already occupied")
t, ev = e3:tick(at(2026, 11, 9))
check("manual stay is open-ended until the next calendar stay", ev.status == "occupied")
t, ev = e3:tick(at(2026, 11, 10, 15))
check(
  "calendar stay a takes over: checked_out manual, checked_in a",
  kinds(t) == "checked_out,checked_in" and t[2].uid == "a"
)
check("early check-out", e3:checkOut(at(2026, 11, 11, 9)) == true)
t, ev = e3:tick(at(2026, 11, 11, 9))
check("after early check-out: checked_out then turnover", kinds(t) == "checked_out,turnover_due")
t, ev = e3:tick(at(2026, 11, 12, 9))
check("cut-short stay does not re-check-in", ev.status == "vacant" and e3.state.stayUid == nil)
check("check-out with nobody in refused", e3:checkOut(at(2026, 11, 12, 10)) == false)
e3:prune(at(2026, 11, 14))
check("prune drops the cutoff once the stay is over", next(e3.cutoffs) == nil)
t, ev = e3:tick(at(2026, 11, 13, 16))
check("next calendar stay still checks in", kinds(t) == "checked_in" and t[1].uid == "b")

print("== persistence")
local doc = e3:serialize()
local e4 = Stays.new({ date = date, turnoverSeconds = 3600 })
e4:restore(doc)
e4:setStays(stays)
t, ev = e4:tick(at(2026, 11, 13, 17))
check("restored engine replays nothing", #t == 0 and ev.status == "occupied" and e4.state.stayUid == "b")
local e5 = Stays.new({ date = date })
e5:restore("junk")
check("garbage restore ignored", e5.state.status == "vacant")
e4:clearOverrides()
check("clearOverrides forgets manual + cutoffs", e4.manual == nil and next(e4.cutoffs) == nil)

print("== engine: empty calendar")
local e6 = Stays.new({ date = date })
e6:setStays({})
t, ev = e6:tick(at(2026, 11, 1))
check("vacant forever, nothing fires", ev.status == "vacant" and #t == 0 and ev.staysNext30 == 0)

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
