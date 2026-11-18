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
local JSON = require("JSON")

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
  "context key travels as context_key in the envelope (never `key`)",
  C.build("AI_SET_CONTEXT", valid.AI_SET_CONTEXT, ctx).args.context_key == "quiet_hours"
    and C.envelope(C.build("AI_SET_CONTEXT", valid.AI_SET_CONTEXT, ctx), "aic-1").payload.args.context_key
      == "quiet_hours"
)
local ctxBody = C.body(C.build("AI_SET_CONTEXT", valid.AI_SET_CONTEXT, ctx), "aic-1")
check(
  "…and as `key` in the cloud body (rpc/ops.ts OP_BODIES.set_context: key, value)",
  ctxBody.key == "quiet_hours" and ctxBody.context_key == nil and ctxBody.value ~= nil
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
r = C.interpret({ status = "ok", result = { accepted = true, job_id = 42 } })
check("accepted + numeric job id", r.outcome == "accepted" and r.job_id == "42")
-- set_context / send_notification: {accepted: true, job_id: null} (JSON null
-- decodes to nil) — done now, nothing will be delivered later.
r = C.interpret({ status = "ok", result = { accepted = true, applied = true, key = "vacation" } })
check("accepted with job_id null/absent → completed, no job", r.outcome == "completed" and r.job_id == nil)
r = C.interpret({ status = "ok", result = JSON:decode('{"accepted":true,"job_id":null,"sent":{}}') })
check("the platform's literal {accepted:true, job_id:null} → completed", r.outcome == "completed" and r.job_id == nil)
for _, odd in ipairs({ "", {}, true }) do
  r = C.interpret({ status = "ok", result = { accepted = true, job_id = odd } })
  check("job_id " .. type(odd) .. " (" .. tostring(odd) .. ") names no job → completed", r.outcome == "completed")
end
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
for _, code in ipairs({ "cloud_unreachable", "deadline_exceeded", "target_unavailable" }) do
  check(code .. " → unreachable", C.interpret({ status = "error", error_code = code }).outcome == "unreachable")
end
-- send_notification / test_provider answer rate_limited per system: that is
-- SmartBuildOS answering, not silence.
r = C.interpret({ status = "error", error_code = "rate_limited" })
check(
  "rate_limited → refused (an answer), says rate limited, not 'no answer'",
  r.outcome == "refused"
    and r.code == "rate_limited"
    and r.message:find("rate limited") ~= nil
    and r.message:find("no answer") == nil
)
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

print("[6] text sent to the cloud satisfies the platform's rule, field by field")
-- The platform's rule for a text field (rpc/ops.ts validateOpBody, kind
-- "text"), written out here independently of commands.lua: JS trim, not
-- empty, at most `max` CODE POINTS, no character of UNPRINTABLE
-- (U+0000-0008, U+000B-001F, U+007F-009F, U+2028, U+2029). The body must also
-- be well-formed UTF-8 (it is JSON).
local function codePoints(s)
  local out, joined = {}, {}
  for ch in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    joined[#joined + 1] = ch
    local b1, n = ch:byte(1), #ch
    local cp
    if n == 1 and b1 < 0x80 then
      cp = b1
    elseif n == 2 and b1 >= 0xC2 and b1 <= 0xDF then
      cp = (b1 - 0xC0) * 64 + (ch:byte(2) - 0x80)
    elseif n == 3 and b1 >= 0xE0 and b1 <= 0xEF then
      cp = ((b1 - 0xE0) * 64 + (ch:byte(2) - 0x80)) * 64 + (ch:byte(3) - 0x80)
      if cp < 0x800 or (cp >= 0xD800 and cp <= 0xDFFF) then
        return nil
      end
    elseif n == 4 and b1 >= 0xF0 and b1 <= 0xF4 then
      cp = (((b1 - 0xF0) * 64 + (ch:byte(2) - 0x80)) * 64 + (ch:byte(3) - 0x80)) * 64 + (ch:byte(4) - 0x80)
      if cp < 0x10000 or cp > 0x10FFFF then
        return nil
      end
    else
      return nil
    end
    out[#out + 1] = cp
  end
  if table.concat(joined) ~= s then
    return nil -- a byte no character claimed: not well-formed UTF-8
  end
  return out
end
local function unprintable(cp)
  return (cp <= 0x08) or (cp >= 0x0B and cp <= 0x1F) or (cp >= 0x7F and cp <= 0x9F) or cp == 0x2028 or cp == 0x2029
end
local JS_TRIM = { [0x09] = 1, [0x0A] = 1, [0x0B] = 1, [0x0C] = 1, [0x0D] = 1, [0x20] = 1, [0xA0] = 1 }
for _, cp in ipairs({ 0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF }) do
  JS_TRIM[cp] = 1
end
for cp = 0x2000, 0x200A do
  JS_TRIM[cp] = 1
end
local function platformAccepts(s, max)
  if type(s) ~= "string" then
    return false, "not a string"
  end
  local cps = codePoints(s)
  if cps == nil then
    return false, "not well-formed UTF-8"
  end
  local i, j = 1, #cps
  while i <= j and JS_TRIM[cps[i]] do
    i = i + 1
  end
  while j >= i and JS_TRIM[cps[j]] do
    j = j - 1
  end
  if j < i then
    return false, "empty after trim"
  end
  if j - i + 1 > max then
    return false, (j - i + 1) .. " code points > " .. max
  end
  for k = i, j do
    if unprintable(cps[k]) then
      return false, string.format("U+%04X refused", cps[k])
    end
  end
  return true
end
local function cpLen(s)
  return #(codePoints(s) or {})
end

check(
  "the platform's bounds: room_name 64, device_name 120",
  C.BODY_TEXT_MAX.room_name == 64 and C.BODY_TEXT_MAX.device_name == 120
)
-- multi-byte names exactly at, one under and one over the bound
local E2, E3, E4 = "\195\169", "\226\130\172", "\240\159\152\128" -- é (2 bytes), € (3), 😀 (4)
for _, case in ipairs({
  { "room_name", 64, E2 },
  { "room_name", 64, E3 },
  { "device_name", 120, E4 },
  { "device_name", 120, E2 },
}) do
  local field, max, ch = case[1], case[2], case[3]
  for _, n in ipairs({ max - 1, max, max + 1 }) do
    local name = string.rep(ch, n)
    local roomName = field == "room_name" and name or "Kitchen"
    local devName = field == "device_name" and name or "Pendants"
    local c = {
      rooms = function()
        return { [3] = roomName }
      end,
      devices = function()
        return { [12] = { name = devName, room_id = 3, room_name = roomName } }
      end,
    }
    local cmd = field == "room_name" and C.build("AI_ANALYZE_ROOM", { ROOM = "3" }, c)
      or C.build("AI_START_DIAGNOSTIC", { DEVICE = "12" }, c)
    check(
      string.format("%s of %d %d-byte characters: bounded where it is resolved (envelope args too)", field, n, #ch),
      cmd.args[field] == string.rep(ch, math.min(n, max))
    )
    local body = C.body(cmd, "aic-1")
    local v = body[field]
    local ok, why = platformAccepts(v, max)
    check(string.format("%s of %d %d-byte characters: the platform accepts it", field, n, #ch), ok, why)
    check(
      string.format(
        "%s of %d %d-byte characters: %d characters kept, cut between characters",
        field,
        n,
        #ch,
        math.min(n, max)
      ),
      v == string.rep(ch, math.min(n, max)),
      #tostring(v) .. " bytes"
    )
  end
end
-- each refused character class inside a name
local CLASSES = {
  { "C0 U+0001", "\1" },
  { "C0 TAB", "\t" },
  { "C0 LF", "\n" },
  { "C0 U+001F", "\31" },
  { "DEL U+007F", "\127" },
  { "C1 U+0080", "\194\128" },
  { "C1 U+0085 (NEL)", "\194\133" },
  { "C1 U+009F", "\194\159" },
  { "U+2028 LINE SEPARATOR", "\226\128\168" },
  { "U+2029 PARAGRAPH SEPARATOR", "\226\128\169" },
}
for _, cls in ipairs(CLASSES) do
  local raw = "Kitchen" .. cls[2] .. "Island"
  local c = {
    rooms = function()
      return { [3] = raw }
    end,
    devices = function()
      return { [12] = { name = "Lamp" .. cls[2] .. "One", room_id = 3, room_name = raw } }
    end,
  }
  local room = C.body(C.build("AI_ANALYZE_ROOM", { ROOM = "3" }, c), "aic-1")
  local dev = C.body(C.build("AI_START_DIAGNOSTIC", { DEVICE = "12" }, c), "aic-1")
  local okR, whyR = platformAccepts(room.room_name, 64)
  local okD, whyD = platformAccepts(dev.device_name, 120)
  check(
    "room_name with " .. cls[1] .. ": replaced by a space, accepted",
    okR and room.room_name == "Kitchen Island",
    whyR
  )
  check("device_name with " .. cls[1] .. ": replaced by a space, accepted", okD and dev.device_name == "Lamp One", whyD)
  local q = C.build("AI_ASK", { QUESTION = "Why" .. cls[2] .. "now?" }, ctx)
  check("free text with " .. cls[1] .. ": accepted", platformAccepts(C.body(q, "aic-1").question, 500))
end
-- malformed UTF-8 and the platform's whitespace
local MALFORMED = {
  { "a byte 0xFF", "\255" },
  { "a stray continuation byte", "\128" },
  { "an overlong '/'", "\192\175" },
  { "a surrogate", "\237\160\128" },
  { "a truncated sequence", "\226\130" },
}
for _, m in ipairs(MALFORMED) do
  local v = C.sanitise("Ga" .. m[2] .. "rage")
  check("a name with " .. m[1] .. ": the byte is dropped", v == "Garage" and platformAccepts(v, 64), v)
end
check("a name ending in a truncated sequence: dropped, never half a character", C.sanitise("Garage\195") == "Garage")
check(
  "the platform's trim set (U+3000, U+00A0, U+FEFF) at the ends",
  C.sanitise("\227\128\128\239\187\191Kitchen\194\160") == "Kitchen"
)
local blank = {
  rooms = function()
    return { [3] = "\226\128\168\t" }
  end,
}
local blankBody = C.body(C.build("AI_ANALYZE_ROOM", { ROOM = "3" }, blank), "aic-1")
check(
  "a room name with nothing printable is not sent (an empty text is refused)",
  blankBody.room_name == nil and blankBody.room_id == 3
)
check("a cut never leaves trailing whitespace", C.sanitise(string.rep("a", 63) .. " b", 64) == string.rep("a", 63))
-- free text counts characters, like the platform
check(
  "500 two-byte characters (1000 bytes) is a 500-character question: accepted",
  C.build("AI_ASK", { QUESTION = string.rep(E2, 500) }, ctx) ~= nil
)
local over = refusal("AI_ASK", { QUESTION = string.rep(E2, 501) })
check("501 characters refused (not cut)", over and over.message:find("longer than 500") ~= nil)
check(
  "statement / title / message / value / occasion / detail count characters",
  C.build("AI_LEARN_PREFERENCE", { STATEMENT = string.rep(E3, 300) }, ctx) ~= nil
    and refusal("AI_LEARN_PREFERENCE", { STATEMENT = string.rep(E3, 301) }) ~= nil
    and C.build("AI_SEND_NOTIFICATION", { TITLE = string.rep(E4, 80), MESSAGE = string.rep(E2, 400) }, ctx) ~= nil
    and refusal("AI_SEND_NOTIFICATION", { TITLE = string.rep(E4, 81), MESSAGE = "m" }) ~= nil
    and refusal("AI_SEND_NOTIFICATION", { TITLE = "t", MESSAGE = string.rep(E2, 401) }) ~= nil
    and C.build("AI_SET_CONTEXT", { KEY = "vacation", VALUE = string.rep(E2, 120) }, ctx) ~= nil
    and refusal("AI_SET_CONTEXT", { KEY = "vacation", VALUE = string.rep(E2, 121) }) ~= nil
    and C.build("AI_SUGGEST_SCENE", { ROOM = "3", OCCASION = string.rep(E3, 120) }, ctx) ~= nil
    and refusal("AI_SUGGEST_SCENE", { ROOM = "3", OCCASION = string.rep(E3, 121) }) ~= nil
    and C.build("AI_RECORD_EVENT", { NAME = "n", DETAIL = string.rep(E2, 400) }, ctx) ~= nil
    and refusal("AI_RECORD_EVENT", { NAME = "n", DETAIL = string.rep(E2, 401) }) ~= nil
)
check(
  "a typed ROOM longer than 64 characters is refused, pointing at the id",
  (refusal("AI_ANALYZE_ROOM", { ROOM = string.rep(E2, 65) }) or {}).message:find("use the room id") ~= nil
)
-- the body's last guard: whatever built it
local guarded = C.body({
  name = "AI_ASK",
  args = { question = "q\226\128\168" .. string.rep(E2, 600), room_id = 3, room_name = string.rep(E4, 90) },
}, "aic-1")
check(
  "body(): every bounded text field is cut to the platform's bound and cleaned",
  platformAccepts(guarded.question, 500) and cpLen(guarded.question) == 500 and platformAccepts(guarded.room_name, 64)
)
-- every body every command can build, with hostile names everywhere
local hostile = {
  rooms = function()
    return { [3] = "\226\128\168" .. string.rep(E3, 80) .. "\194\133" }
  end,
  devices = function()
    return { [12] = { name = string.rep(E4, 130) .. "\127", room_id = 3, room_name = string.rep(E2, 70) } }
  end,
  learningActive = true,
}
local params = {
  QUESTION = string.rep(E2, 500),
  ROOM = "3",
  KEY = "vacation",
  VALUE = string.rep(E3, 120),
  STATEMENT = string.rep(E4, 300),
  OCCASION = string.rep(E2, 120),
  TYPE = "usage",
  PERIOD = "today",
  TITLE = string.rep(E3, 80),
  MESSAGE = string.rep(E2, 400) .. "\226\128\169",
}
local bad = {}
for _, name in ipairs(C.NAMES) do
  local spec = C.SPECS[name]
  if spec.op then
    local p = {}
    for key in pairs(spec.params) do
      p[key] = params[key]
    end
    if spec.one_of then
      p.ROOM, p.DEVICE = nil, "12"
    end
    local cmd, why = C.build(name, p, hostile)
    if cmd == nil then
      bad[#bad + 1] = name .. " (" .. why.message .. ")"
    else
      for field, v in pairs(C.body(cmd, "aic-1")) do
        local max = C.BODY_TEXT_MAX[field]
        if max ~= nil then
          local ok, why2 = platformAccepts(v, max)
          if not ok then
            bad[#bad + 1] = name .. "." .. field .. ": " .. why2
          end
        end
      end
    end
  end
end
check("every text field of every cloud body passes the platform's rule", #bad == 0, table.concat(bad, "; "))
check(
  "cutBytes cuts between characters (AI_RECORD_EVENT label)",
  C.cutBytes(string.rep(E2, 10), 5) == string.rep(E2, 2) and C.cutBytes("abc", 5) == "abc"
)
local recEnv = C.envelope(C.build("AI_RECORD_EVENT", { NAME = string.rep(E3, 120) }, ctx), "aic-1")
check("record label ≤ 120 bytes on a character boundary", #recEnv.label <= 120 and codePoints(recEnv.label) ~= nil)

print("[7] AI_GENERATE_REPORT: TYPE and PERIOD are both required")
local rt = refusal("AI_GENERATE_REPORT", { PERIOD = "Today" })
check("no TYPE → refused, TYPE: is required", rt and rt.message:find("TYPE: is required", 1, true) ~= nil)
local rp = refusal("AI_GENERATE_REPORT", { TYPE = "Usage" })
check("no PERIOD → refused, PERIOD: is required", rp and rp.message:find("PERIOD: is required", 1, true) ~= nil)
check("neither → refused", refusal("AI_GENERATE_REPORT", {}) ~= nil)
check(
  "the spec says so (what DRIVER.md documents)",
  C.SPECS.AI_GENERATE_REPORT.params.TYPE.required == true and C.SPECS.AI_GENERATE_REPORT.params.PERIOD.required == true
)

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
