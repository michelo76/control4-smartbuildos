-- flightrecorder.localquery: the Flight Recorder's ring served over module
-- contract v2 (pure). Argument validation, the four capabilities, paging
-- with cursors, the 24 KB result cap, honest retention (`oldest_available`,
-- `truncated`), envelope event ids (and the honest absence of one), the
-- empty ring, and a cursor from before Clear Local History.
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

require("drivers-common-public.global.lib") -- the vendored JSON's number formatting
JSON = require("JSON")
local Ring = require("tracer.ring")
local Q = require("flightrecorder.localquery")

local T0 = 1800000000
local function ringWith(n, capacity)
  local ring = Ring.new(capacity or 500)
  for i = 1, n do
    local kind = (i % 3 == 0) and "change" or "event"
    local e = {
      t = T0 + i,
      kind = kind,
      device_id = (i % 2 == 0) and 12 or 20,
      device_label = (i % 2 == 0) and "Kitchen Pendants" or "Garage Door",
      room_id = (i % 2 == 0) and 3 or 7,
      room_label = (i % 2 == 0) and "Kitchen" or "Garage",
    }
    if kind == "event" then
      e.event_id = 4 -- the Composer event number
      e.event_name = "Pressed"
      e.known = true
      e.envelope_id = "flight_recorder:12345:nb:" .. i
    else
      e.variable = "LIGHT_LEVEL"
      e.value = i
      e.envelope_id = "flight_recorder:12345:nb:" .. i
    end
    ring:push(e)
  end
  return ring
end
local function ctx(ring, gen)
  return { ring = ring, generation = gen or 0, now = T0 + 10000, recording_status = "recording" }
end

print("[1] argument validation (closed, strict)")
local ring = ringWith(10)
local s, r, code = Q.answer("events.query", { bogus = 1 }, ctx(ring))
check("unknown argument → invalid_args", s == "error" and code == "invalid_args", code)
s, r, code = Q.answer("events.query", { limit = 0 }, ctx(ring))
check("limit 0 → invalid_args", code == "invalid_args")
s, r, code = Q.answer("events.query", { limit = 201 }, ctx(ring))
check("limit 201 → invalid_args", code == "invalid_args")
s, r, code = Q.answer("events.query", { kinds = { "event", "rm -rf" } }, ctx(ring))
check("unknown kind → invalid_args", code == "invalid_args")
s, r, code = Q.answer("events.device_history", {}, ctx(ring))
check("device_history without device_id → invalid_args", code == "invalid_args")
s, r, code = Q.answer("events.room_activity", { room_id = "kitchen" }, ctx(ring))
check("room_activity with a non-numeric room → invalid_args", code == "invalid_args")
s, r, code = Q.answer("events.timeline", { from = T0 + 100, to = T0 + 1 }, ctx(ring))
check("to before from → invalid_args", code == "invalid_args")
s, r, code = Q.answer("events.correlate", {}, ctx(ring))
check("a capability it does not serve → capability_not_found", code == "capability_not_found")
s, r, code = Q.answer("events.query", { cursor = "x" }, ctx(ring))
check("malformed cursor → invalid_args", code == "invalid_args")

print("[2] events.query: newest first, each with its envelope event id")
s, r = Q.answer("events.query", { limit = 3 }, ctx(ring))
check("ok", s == "ok")
check("three newest, descending", r.count == 3 and r.events[1].seq == 10 and r.events[3].seq == 8)
check("envelope event_id carried", r.events[1].event_id == "flight_recorder:12345:nb:10")
check(
  "Composer event number is device_event_id, not event_id",
  r.events[1].device_event_id == 4 and r.events[1].event_id ~= "4"
)
check("ISO time", r.events[1].at == os.date("!%Y-%m-%dT%H:%M:%SZ", T0 + 10))
check("has_more", r.has_more == true)
check("retention states capacity, held, oldest", r.retention.capacity == 500 and r.retention.held == 10)
check("oldest_available = seq 1", r.retention.oldest_available.seq == 1)
check("nothing evicted → not truncated", r.truncated == false)
check("retention policy is said in words", r.retention.policy:find("size%-bounded") ~= nil)
check("recording status carried", r.retention.recording_status == "recording")

print("[3] paging with the cursor")
local _, _, _, cursor = Q.answer("events.query", { limit = 3 }, ctx(ring))
check("a cursor is returned when more remain", cursor == "h0.d.8", cursor)
s, r = Q.answer("events.query", { limit = 3, cursor = cursor }, ctx(ring))
check("next page continues below it", r.events[1].seq == 7 and r.events[3].seq == 5)
local seen, c, pages = {}, nil, 0
repeat
  local _, page, _, nextCursor = Q.answer("events.query", { limit = 4, cursor = c }, ctx(ring))
  for _, e in ipairs(page.events) do
    seen[#seen + 1] = e.seq
  end
  c = nextCursor
  pages = pages + 1
until c == nil or pages > 10
check("walking every page returns all 10, once each", #seen == 10 and seen[1] == 10 and seen[10] == 1)
s, r, code = Q.answer("events.query", { limit = 3, cursor = "h0.a.8" }, ctx(ring))
check("a cursor of the other order → invalid_args", code == "invalid_args")
s, r, code = Q.answer("events.query", { cursor = "h0.d.8" }, ctx(ring, 1))
check("a cursor from before Clear Local History → invalid_args", code == "invalid_args")

print("[4] filters")
s, r = Q.answer("events.device_history", { device_id = 12 }, ctx(ring))
local only12 = true
for _, e in ipairs(r.events) do
  only12 = only12 and e.device_id == 12
end
check("device_history: only that device", r.count == 5 and only12, r.count)
s, r = Q.answer("events.room_activity", { room_id = 7 }, ctx(ring))
local only7 = true
for _, e in ipairs(r.events) do
  only7 = only7 and e.room_id == 7
end
check("room_activity: only that room", r.count == 5 and only7)
s, r = Q.answer("events.query", { kinds = { "change" } }, ctx(ring))
check("kinds filter", r.count == 3 and r.events[1].kind == "change" and r.events[1].variable == "LIGHT_LEVEL")
s, r = Q.answer("events.query", { since_seq = 7, order = "asc" }, ctx(ring))
check("since_seq ascending", r.count == 3 and r.events[1].seq == 8)
s, r = Q.answer("events.query", { text = "garage" }, ctx(ring))
check("text filter (case-insensitive)", r.count == 5)
s, r = Q.answer("events.timeline", { from = T0 + 3, to = T0 + 6 }, ctx(ring))
check("timeline: window, oldest first", r.count == 4 and r.events[1].seq == 3 and r.events[4].seq == 6)
check("timeline names its window", r.window.from == os.date("!%Y-%m-%dT%H:%M:%SZ", T0 + 3))

print("[5] retention after eviction: truncated is said, never papered over")
local small = ringWith(80, 50) -- 30 evicted
s, r = Q.answer("events.query", { limit = 200 }, ctx(small))
check("held 50 of 80", r.retention.held == 50 and r.retention.evicted_total == 30)
check("oldest_available is seq 31", r.retention.oldest_available.seq == 31)
check("reading to the oldest held → truncated", r.truncated == true)
s, r = Q.answer("events.query", { since_seq = 5, order = "asc" }, ctx(small))
check("since_seq older than what is held → truncated", r.truncated == true and r.events[1].seq == 31)
s, r = Q.answer("events.query", { since_seq = 60, order = "asc" }, ctx(small))
check("since_seq inside what is held → not truncated", r.truncated == false)
s, r = Q.answer("events.timeline", { from = T0 + 1, to = T0 + 40 }, ctx(small))
check("timeline starting before the oldest entry → truncated", r.truncated == true and r.events[1].seq == 31)
s, r = Q.answer("events.query", { limit = 5 }, ctx(small))
check("only the newest five asked → not truncated", r.truncated == false)
local fewEvents = 0
for _, e in ipairs(r.events) do
  if e.seq < 31 then
    fewEvents = fewEvents + 1
  end
end
check("never an entry outside the ring", fewEvents == 0)

print("[6] the empty ring")
local empty = Ring.new(500)
s, r = Q.answer("events.query", {}, ctx(empty))
check("ok with no events", s == "ok" and r.count == 0 and #r.events == 0)
check("no oldest_available", r.retention.oldest_available == nil and r.retention.held == 0)
check("not truncated (nothing was ever evicted)", r.truncated == false)
s, r = Q.answer("events.device_history", { device_id = 99 }, ctx(ring))
check("a device with no entries → ok, empty", s == "ok" and r.count == 0)

print("[7] no event id is invented")
local ring2 = Ring.new(100)
ring2:push({ t = T0, kind = "event", device_id = 1, event_id = 7, event_name = "X", uploaded = false })
ring2:push({ t = T0 + 1, kind = "note", text = "restored from before ids were kept" })
s, r = Q.answer("events.query", { order = "asc" }, ctx(ring2))
check(
  "over the upload budget → no event_id, said so",
  r.events[1].event_id == nil and r.events[1].no_event_id == "over_upload_budget"
)
check("unknown provenance → not_recorded", r.events[2].event_id == nil and r.events[2].no_event_id == "not_recorded")

print("[8] the 24 KB result cap")
local big = Ring.new(2000)
for i = 1, 300 do
  big:push({
    t = T0 + i,
    kind = "mark",
    event_name = string.rep("n", 120),
    detail = string.rep('"', 160), -- escapes double on the wire
    envelope_id = "flight_recorder:12345:nb:" .. i,
  })
end
local encoded
s, r, code, cursor = Q.answer("events.query", { limit = 200 }, ctx(big))
encoded = JSON:encode(r)
check("page fits under 24 KB once encoded", #encoded <= 24 * 1024, #encoded)
check("fewer than asked, with a cursor to the rest", r.count < 200 and r.has_more and cursor ~= nil, r.count)
local total, cc = r.count, cursor
for _ = 1, 40 do
  if cc == nil then
    break
  end
  local _, pr, _, nc = Q.answer("events.query", { limit = 200, cursor = cc }, ctx(big))
  check("every page under 24 KB", #JSON:encode(pr) <= 24 * 1024)
  total = total + pr.count
  cc = nc
end
check("all 300 reachable through cursors", total == 300, total)

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
