package.path = "src/?.lua;" .. package.path
local Ical = require("guestmode.ical")
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

print("== unfold")
check("CRLF + space continuation joined", Ical.unfold("SUMMARY:Hel\r\n lo\r\nX:1") == "SUMMARY:Hello\nX:1")
check("tab continuation joined", Ical.unfold("A:b\n\tc") == "A:bc")
check("bare CR normalised", Ical.unfold("A:1\rB:2") == "A:1\nB:2")

print("== parseDate")
local d = Ical.parseDate("20261110", { VALUE = "DATE" })
check("DATE", d.allDay == true and d.y == 2026 and d.m == 11 and d.d == 10)
d = Ical.parseDate("20261110T150000Z")
check("DATE-TIME Z", d.allDay == false and d.utc == true and d.hh == 15 and d.ss == 0)
d = Ical.parseDate("20261110T090000", { TZID = "Europe/Paris" })
check("floating with TZID recorded, not utc", d.utc == false and d.tzid == "Europe/Paris")
check("garbage → nil", Ical.parseDate("tomorrow") == nil and Ical.parseDate("20261399") == nil)
check("out-of-range time → nil", Ical.parseDate("20261110T250000Z") == nil)

print("== parseDuration")
check("P2D", Ical.parseDuration("P2D") == 172800)
check("PT3H", Ical.parseDuration("PT3H") == 10800)
check("P1DT12H30M", Ical.parseDuration("P1DT12H30M") == 86400 + 12 * 3600 + 1800)
check("P1W", Ical.parseDuration("P1W") == 7 * 86400)
check("negative", Ical.parseDuration("-PT1H") == -3600)
check("garbage → nil", Ical.parseDuration("2 days") == nil)

print("== parse an Airbnb-style feed")
local airbnb = table.concat({
  "BEGIN:VCALENDAR",
  "PRODID;X-RICAL-TZSOURCE=TZINFO:-//Airbnb Inc//Hosting Calendar 0.8.8//EN",
  "CALSCALE:GREGORIAN",
  "VERSION:2.0",
  "X-WR-CALNAME:Beach Flat",
  "BEGIN:VEVENT",
  "DTEND;VALUE=DATE:20261113",
  "DTSTART;VALUE=DATE:20261110",
  "UID:1a2b3c@airbnb.com",
  "DESCRIPTION:Reservation URL: https://www.airbnb.com/hosting/reservations/de",
  " tails/HMABC123\\nPhone Number (Last 4 Digits): 1234",
  "SUMMARY:Reserved",
  "END:VEVENT",
  "BEGIN:VEVENT",
  "DTEND;VALUE=DATE:20261120",
  "DTSTART;VALUE=DATE:20261118",
  "UID:block1@airbnb.com",
  "SUMMARY:Airbnb (Not available)",
  "END:VEVENT",
  "BEGIN:VEVENT",
  "DTSTART:20261201T140000Z",
  "DTEND:20261203T100000Z",
  "UID:timed@example.com",
  "SUMMARY:Jane Doe",
  "STATUS:CANCELLED",
  "END:VEVENT",
  "BEGIN:VEVENT",
  "DTSTART;VALUE=DATE:20261224",
  "UID:oneday@example.com",
  "SUMMARY:Alex Smith",
  "END:VEVENT",
  "BEGIN:VEVENT",
  "DTSTART:20261228T160000Z",
  "DURATION:P2DT18H",
  "UID:dur@example.com",
  "SUMMARY:Kim Lee\\, family",
  "END:VEVENT",
  "BEGIN:VEVENT",
  "UID:nodate@example.com",
  "SUMMARY:Broken",
  "END:VEVENT",
  "END:VCALENDAR",
}, "\r\n")
local events, report = Ical.parse(airbnb)
check("calendar name read", report.calendarName == "Beach Flat", report.calendarName)
check("six VEVENTs seen", report.total == 6, report.total)
check("one cancelled, one skipped (no DTSTART)", report.cancelled == 1 and report.skipped == 1)
check("four events kept", #events == 4, #events)
local e1 = events[1]
check(
  "all-day stay dates",
  e1.start.allDay and e1.start.d == 10 and e1.finish.d == 13 and e1.uid == "1a2b3c@airbnb.com"
)
check(
  "folded DESCRIPTION joined and \\n unescaped",
  e1.description:find("details/HMABC123\nPhone", 1, true) ~= nil,
  e1.description
)
check("block detected", Ical.isBlock(events[2].summary) == true and Ical.isBlock(e1.summary) == false)
check("guest name: Reserved → Guest", Ical.guestName(e1) == "Guest")
check("one-day event without DTEND lasts a day", events[3].finish.duration == 86400)
check("DURATION kept in seconds", events[4].finish.duration == 2 * 86400 + 18 * 3600)
check("escaped comma in SUMMARY", events[4].summary == "Kim Lee, family", events[4].summary)
check("guest name from summary", Ical.guestName(events[4]) == "Kim Lee, family")

print("== robustness")
local e0, r0 = Ical.parse(nil)
check("nil → nothing", #e0 == 0 and r0.total == 0)
local e2 = Ical.parse("BEGIN:VEVENT\nDTSTART;VALUE=DATE:20261110\nEND:VEVENT")
check("no VCALENDAR wrapper still parses", #e2 == 1 and e2[1].uid:find("noid") ~= nil)
local e3 = Ical.parse("BEGIN:VEVENT\nDTSTART;VALUE=DATE:20261110\nSUMMARY:open")
check("unterminated event dropped", #e3 == 0)
local big = {}
for i = 1, Ical.LIMITS.events + 5 do
  big[#big + 1] = "BEGIN:VEVENT\nUID:u" .. i .. "\nDTSTART;VALUE=DATE:20261110\nEND:VEVENT"
end
local eb, rb = Ical.parse(table.concat(big, "\n"))
check("event count bounded", #eb == Ical.LIMITS.events and rb.skipped == 5)
check(
  "block words: closed / owner / maintenance",
  Ical.isBlock("CLOSED - Not available") and Ical.isBlock("Owner stay") and Ical.isBlock("Maintenance")
)
check("guest name trimmed to 80", #Ical.guestName({ summary = string.rep("x", 200) }) == 80)

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
