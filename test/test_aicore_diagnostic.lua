-- aicore.diagnostic (pure): the ai_core.diagnostic envelope with the
-- Flight Recorder's local events, or the honest reason there are none;
-- bounded to the envelope payload limit; a real envelope can be built.
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

local D = require("aicore.diagnostic")
local Envelope = require("sbos.envelope")

local target = { device_id = 12, device_name = "Kitchen Pendants" }
local function answer(n)
  local events = {}
  for i = n, 1, -1 do
    events[#events + 1] = {
      seq = i,
      event_id = (i % 4 ~= 0) and ("flight_recorder:9001:nb:" .. i) or nil,
      no_event_id = (i % 4 == 0) and "over_upload_budget" or nil,
      at = "2027-01-15T07:00:00Z",
      kind = "event",
      device_label = "Kitchen Pendants",
      event_name = string.rep("Pressed ", 8),
    }
  end
  return {
    status = "ok",
    result = {
      capability = "events.device_history",
      events = events,
      truncated = true,
      retention = { held = n, capacity = 500, oldest_available = { seq = 1, at = "2027-01-15T06:00:00Z" } },
    },
  }
end

print("[1] with the recorder's events")
local f = D.fields(target, { state = "present", answer = answer(3) }, "aic-1", "AI_START_DIAGNOSTIC")
local fr = f.payload.flight_recorder
check("ai_core.diagnostic, derived", f.event_type == "ai_core.diagnostic" and f.evidence_source == "derived")
check(
  "available with three events, newest first",
  fr.available and #fr.events == 3 and fr.events[1].event_id == "flight_recorder:9001:nb:3"
)
check(
  "retention carried (truncated, held, oldest)",
  fr.truncated == true and fr.held == 3 and fr.oldest_available.seq == 1
)
check("ids cited for the cloud", #D.eventIds(f) == 3)
check("it states no cause is inferred", f.payload.note:find("not inferred") ~= nil)
local env, why = Envelope.build(f, { module_id = "ai_core", instance_id = "1", observed_at = "x", sequence = 1 })
check("a valid envelope (ai_core owns ai_core.)", env ~= nil and Envelope.validate(env, "ai_core"), why)

print("[2] bounded")
local big = D.fields(target, { state = "present", answer = answer(60) }, "aic-2", "x")
local bfr = big.payload.flight_recorder
check("at most 25 summaries", #bfr.events <= 25)
check("fits the payload budget", Envelope.approxSize(big.payload) <= 4096, Envelope.approxSize(big.payload))
check("the cut is counted", bfr.omitted == 60 - #bfr.events)
check(
  "the newest are the ones kept",
  bfr.events[1].no_event_id ~= nil and bfr.events[2].event_id == "flight_recorder:9001:nb:59"
)
local benv = Envelope.build(big, { module_id = "ai_core", instance_id = "1", observed_at = "x", sequence = 2 })
check("still a valid envelope", benv ~= nil)
check(
  "an entry without an event id says why",
  (function()
    for _, e in ipairs(bfr.events) do
      if e.event_id == nil and e.no_event_id == "over_upload_budget" then
        return true
      end
    end
    return false
  end)()
)

print("[3] honest absence")
local cases = {
  { "absent", nil, "flight_recorder_not_installed" },
  { "present_v1", nil, "flight_recorder_has_no_local_history_service" },
  { "unknown", nil, "flight_recorder_unknown_agent_cannot_discover" },
  { "present", { status = "error", error_code = "deadline_exceeded" }, "request_failed" },
}
for _, c in ipairs(cases) do
  local x = D.fields({ room_id = 3, room_name = "Kitchen" }, { state = c[1], answer = c[2] }, "aic-3", "run_diagnostic")
  local r = x.payload.flight_recorder
  check(
    c[1] .. " → available=false, reason " .. c[3],
    r.available == false and r.reason == c[3] and x.quality == "partial"
  )
  check("  no events invented", r.events == nil and #D.eventIds(x) == 0)
end
local e2 =
  D.fields(target, { state = "present", answer = { status = "error", error_code = "deadline_exceeded" } }, "a", "b")
check("the failing error code is carried", e2.payload.flight_recorder.error_code == "deadline_exceeded")
local empty = D.fields(
  target,
  { state = "present", answer = { status = "ok", result = { events = {}, retention = { held = 0 } } } },
  "a",
  "b"
)
check(
  "an empty ring: available, zero events (not an error)",
  empty.payload.flight_recorder.available and #empty.payload.flight_recorder.events == 0
)

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
