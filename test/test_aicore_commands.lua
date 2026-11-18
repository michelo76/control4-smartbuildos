-- aicore.commands (pure): Composer command validation and bounds, closed
-- lists, room/device resolution, exclusions and the learning gate, the
-- envelope and body each command produces, the meaning of the cloud's quick
-- answer, and the local command budget.
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

local C = require("aicore.commands")
local V = require("aicore.vocab")

local ctx = {
  rooms = function()
    return { [3] = "Kitchen", [7] = "Garage", [9] = "Spare Room" }
  end,
  devices = function()
    return { [12] = { name = "Kitchen Pendants", room_id = 3, room_name = "Kitchen" } }
  end,
  excludedRooms = { [9] = true },
  learningActive = true,
}

print("[1] every command builds with valid input")
local valid = {
  AI_ASK = { QUESTION = "Why is it cold?", ROOM = "kitchen" },
  AI_ANALYZE_ROOM = { ROOM = "7" },
  AI_ANALYZE_SYSTEM = {},
  AI_RECORD_EVENT = { NAME = "Dinner", CATEGORY = "Lighting" },
  AI_SET_CONTEXT = { KEY = "Quiet Hours", VALUE = "22:00-07:00" },
  AI_LEARN_PREFERENCE = { STATEMENT = "dim after 10" },
  AI_SUGGEST_SCENE = { ROOM = "Kitchen", OCCASION = "breakfast" },
  AI_GENERATE_REPORT = { TYPE = "Energy", PERIOD = "Today" },
  AI_START_DIAGNOSTIC = { DEVICE = "12" },
  AI_SEND_NOTIFICATION = { TITLE = "Hi", MESSAGE = "There" },
}
for _, name in ipairs(C.NAMES) do
  local cmd, why = C.build(name, valid[name], ctx)
  check(name .. " builds", cmd ~= nil, why and why.message)
end
check("ten commands", #C.NAMES == 10)
local ask = C.build("AI_ASK", valid.AI_ASK, ctx)
check("room by name, case-insensitive → id + name", ask.args.room_id == 3 and ask.args.room_name == "Kitchen")
check("room by id", C.build("AI_ANALYZE_ROOM", { ROOM = "7" }, ctx).args.room_id == 7)
local diag = C.build("AI_START_DIAGNOSTIC", { DEVICE = "12" }, ctx)
check("device resolved with its room", diag.args.device_id == 12 and diag.device_room_id == 3)
check(
  "LIST label normalised",
  C.build("AI_GENERATE_REPORT", { TYPE = "Device Reliability", PERIOD = "Last 30 Days" }, ctx).args.type
    == "device_reliability"
)
check(
  "codes accepted as is",
  C.build("AI_GENERATE_REPORT", { TYPE = "usage", PERIOD = "last_24_hours" }, ctx).args.period == "last_24_hours"
)
check(
  "defaults: audience homeowner, category general",
  C.build("AI_SEND_NOTIFICATION", { TITLE = "a", MESSAGE = "b" }, ctx).args.audience == "homeowner"
    and C.build("AI_RECORD_EVENT", { NAME = "x" }, ctx).args.category == "general"
)
check(
  "context key travels as context_key (never `key`)",
  C.build("AI_SET_CONTEXT", valid.AI_SET_CONTEXT, ctx).args.context_key == "quiet_hours"
)

print("[2] refusals")
local function refusal(name, params, c)
  local cmd, why = C.build(name, params, c or ctx)
  return cmd == nil and why or nil
end
check("unknown command", refusal("AI_DO_ANYTHING", {}) ~= nil)
check("required text", refusal("AI_ASK", {}).message:find("QUESTION: is required") ~= nil)
check("whitespace-only is empty", refusal("AI_ASK", { QUESTION = " \t " }) ~= nil)
check(
  "question over 500 refused (not cut)",
  refusal("AI_ASK", { QUESTION = string.rep("a", 501) }).message:find("500") ~= nil
)
check("exactly 500 accepted", C.build("AI_ASK", { QUESTION = string.rep("a", 500) }, ctx) ~= nil)
check("control characters stripped", C.build("AI_ASK", { QUESTION = "a\0b\nc" }, ctx).args.question == "a b c")
check("unknown room name", refusal("AI_ASK", { QUESTION = "q", ROOM = "Attic" }).message:find("no room named") ~= nil)
check("unknown room id", refusal("AI_ANALYZE_ROOM", { ROOM = "99" }).message:find("no room 99") ~= nil)
check("closed list: report type", refusal("AI_GENERATE_REPORT", { TYPE = "passwords", PERIOD = "Today" }) ~= nil)
check("closed list: context key", refusal("AI_SET_CONTEXT", { KEY = "alarm_code", VALUE = "1" }) ~= nil)
check("closed list: category", refusal("AI_RECORD_EVENT", { NAME = "n", CATEGORY = "lua" }) ~= nil)
check(
  "closed list: audience",
  refusal("AI_SEND_NOTIFICATION", { TITLE = "t", MESSAGE = "m", AUDIENCE = "everyone@x" }) ~= nil
)
check("diagnostic: neither", refusal("AI_START_DIAGNOSTIC", {}) ~= nil)
check("diagnostic: both", refusal("AI_START_DIAGNOSTIC", { DEVICE = "12", ROOM = "Kitchen" }) ~= nil)
check(
  "diagnostic: device 0 (Composer's empty selector) counts as none",
  refusal("AI_START_DIAGNOSTIC", { DEVICE = "0" }) ~= nil
)
check("diagnostic: not a device", refusal("AI_START_DIAGNOSTIC", { DEVICE = "lamp" }) ~= nil)
local ex = refusal("AI_ANALYZE_ROOM", { ROOM = "Spare Room" })
check("excluded room → not_permitted", ex and ex.code == "not_permitted" and ex.message:find("excluded") ~= nil)
check(
  "AI_ASK about an excluded room is still allowed (the cloud decides)",
  C.build("AI_ASK", { QUESTION = "q", ROOM = "9" }, ctx) ~= nil
)
local paused = { rooms = ctx.rooms, devices = ctx.devices, learningActive = false }
local lp = refusal("AI_LEARN_PREFERENCE", { STATEMENT = "x" }, paused)
check("learning paused → AI_LEARN_PREFERENCE not_permitted", lp and lp.code == "not_permitted")
check("learning paused does not block AI_ASK", C.build("AI_ASK", { QUESTION = "q" }, paused) ~= nil)
check("AI_LEARN_PREFERENCE needs the AI_LEARNING feature", C.SPECS.AI_LEARN_PREFERENCE.feature == "AI_LEARNING")

print("[3] envelopes and bodies")
local env = C.envelope(ask, "aic-1")
check(
  "ai_core.command, requested, unreviewed text",
  env.event_type == "ai_core.command" and env.evidence_source == "requested" and env.quality == "unreviewed_text"
)
check("correlation = request id", env.correlation_id == "aic-1" and env.payload.request_id == "aic-1")
check("room on the envelope", env.room_id == 3)
local sys = C.envelope(C.build("AI_ANALYZE_SYSTEM", {}, ctx), "aic-2")
check("no free text → confirmed", sys.quality == "confirmed")
local rec = C.envelope(C.build("AI_RECORD_EVENT", { NAME = "Door forced", CATEGORY = "Security" }, ctx), "aic-3")
check(
  "AI_RECORD_EVENT → ai_core.record, instrumented",
  rec.event_type == "ai_core.record" and rec.evidence_source == "instrumented"
)
check("security/safety records are critical (warning)", rec.severity == "warning")
check("it says it is not an observed result", rec.payload.note:find("not an observed result") ~= nil)
local body = C.body(ask, "aic-1", { extra = 1 })
check(
  "body: command, request id, args, extra",
  body.command == "AI_ASK" and body.request_id == "aic-1" and body.question == "Why is it cold?" and body.extra == 1
)
check(
  "every op is a contract cloud op",
  (function()
    for _, n in ipairs(C.NAMES) do
      local op = C.SPECS[n].op
      if op ~= nil and not V.CLOUD_OPS[op] then
        return false
      end
    end
    return true
  end)()
)

print("[4] what the cloud's quick answer means")
local r = C.interpret({ status = "ok", result = { accepted = true, job_id = "j1" } })
check("accepted + job id", r.outcome == "accepted" and r.job_id == "j1")
r = C.interpret({ status = "ok", result = { accepted = false } })
check("ok without accepted is NOT success", r.outcome == "refused" and r.code == "cloud_refused")
r = C.interpret({ status = "ok", result = "garbage" })
check("garbage result is not success", r.outcome == "refused")
for _, code in ipairs({
  "not_permitted",
  "unsupported",
  "invalid_args",
  "cloud_refused",
  "agent_not_paired",
  "payload_too_large",
}) do
  r = C.interpret({ status = "error", error_code = code })
  check(
    code .. " → refused with that code",
    r.outcome == "refused" and r.code == code and r.message:find(code) ~= nil
  )
end
for _, code in ipairs({ "cloud_unreachable", "deadline_exceeded", "target_unavailable", "rate_limited" }) do
  check(code .. " → unreachable", C.interpret({ status = "error", error_code = code }).outcome == "unreachable")
end
check(
  "incompatible_protocol → unavailable",
  C.interpret({ status = "error", error_code = "incompatible_protocol" }).outcome == "unavailable"
)

print("[5] the local command budget")
local t = 0
local b = C.newBucket(10, function()
  return t
end)
local taken = 0
for _ = 1, 15 do
  if b.take() then
    taken = taken + 1
  end
end
check("10 in a burst, then refused", taken == 10)
t = 6
check("refills over time (1 per 6 s)", b.take() == true and b.take() == false)

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
