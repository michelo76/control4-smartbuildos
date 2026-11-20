--- SmartBuildOS AI Core — Composer programming commands (pure).
---
--- Turns what Composer programming hands the driver (string params, keyed
--- by upper-case name) into a validated, bounded command:
---
---   build(name, params, ctx)   → cmd | nil, refusal
---   envelope(cmd, requestId)   → fields for the ai_core.command (or
---                                ai_core.record) envelope
---   body(cmd, requestId)       → the cloud op's JSON body
---   interpret(answer)          → what the cloud's quick answer means
---
--- Every input is validated against a closed list or a length bound and
--- REFUSED when it does not fit (a question cut in half is a different
--- question). Nothing here runs anything on the house: the result of a
--- command is an event for the Agent's durable queue and, for ten of the
--- eleven, one call of a cloud op from MODULE_CLOUD_OPS.ai_core. AI_RECORD_EVENT
--- has no cloud op; it is recorded through the durable event path.
---
--- AI_RUN_HOUSEHOLD_ANALYSIS ("Run Household Analysis") asks the cloud to run
--- the household analysis (op analyze_household). It is not AI_ANALYZE_SYSTEM
--- (an AI health review whose text comes back as deliver_result): the cloud
--- answers it once (interpretHousehold) and never delivers a result for it.

local V = require("aicore.vocab")

local M = {}

local L = V.LIMITS

local function text(max, required)
  return { kind = "text", max = max, required = required }
end
local function enum(list, required, default, as)
  return { kind = "enum", list = list, required = required, default = default, as = as }
end

--- The eleven commands (driver.xml <commands> carries the same names/params).
M.SPECS = {
  AI_ASK = {
    op = "ask",
    feature = "BASE",
    params = { QUESTION = text(L.question, true), ROOM = { kind = "room" } },
    order = { "QUESTION", "ROOM" },
  },
  AI_ANALYZE_ROOM = {
    op = "analyze_room",
    feature = "BASE",
    params = { ROOM = { kind = "room", required = true } },
    order = { "ROOM" },
  },
  AI_ANALYZE_SYSTEM = { op = "analyze_system", feature = "BASE", params = {}, order = {} },
  AI_RECORD_EVENT = {
    op = nil, -- recorded through the durable event path; no cloud op exists for it
    feature = "BASE",
    params = {
      NAME = text(L.name, true),
      DETAIL = text(L.detail, false),
      ROOM = { kind = "room" },
      CATEGORY = enum(V.CATEGORIES, false, "general"),
    },
    order = { "NAME", "DETAIL", "ROOM", "CATEGORY" },
  },
  AI_SET_CONTEXT = {
    op = "set_context",
    feature = "BASE",
    params = { KEY = enum(V.CONTEXT_KEYS, true, nil, "context_key"), VALUE = text(L.value, true) },
    order = { "KEY", "VALUE" },
  },
  AI_LEARN_PREFERENCE = {
    op = "learn_preference",
    feature = "AI_LEARNING",
    needs_learning = true,
    params = { STATEMENT = text(L.statement, true), ROOM = { kind = "room" } },
    order = { "STATEMENT", "ROOM" },
  },
  AI_SUGGEST_SCENE = {
    op = "suggest_scene",
    feature = "BASE",
    params = { ROOM = { kind = "room", required = true }, OCCASION = text(L.occasion, true) },
    order = { "ROOM", "OCCASION" },
  },
  AI_GENERATE_REPORT = {
    op = "generate_report",
    feature = "BASE",
    params = { TYPE = enum(V.REPORT_TYPES, true), PERIOD = enum(V.REPORT_PERIODS, true) },
    order = { "TYPE", "PERIOD" },
  },
  AI_START_DIAGNOSTIC = {
    op = "start_diagnostic",
    feature = "BASE",
    params = { DEVICE = { kind = "device" }, ROOM = { kind = "room" } },
    one_of = { "DEVICE", "ROOM" },
    order = { "DEVICE", "ROOM" },
  },
  AI_RUN_HOUSEHOLD_ANALYSIS = {
    op = "analyze_household",
    feature = "AI_LEARNING",
    -- Whether learning is allowed is the cloud's to say (learning_not_allowed):
    -- its settings are the source of truth and the controller's copy can lag.
    household = true,
    params = {},
    order = {},
  },
  AI_SEND_NOTIFICATION = {
    op = "send_notification",
    feature = "BASE",
    params = {
      TITLE = text(L.title, true),
      MESSAGE = text(L.message, true),
      AUDIENCE = enum(V.AUDIENCES, false, "homeowner"),
    },
    order = { "TITLE", "MESSAGE", "AUDIENCE" },
  },
}

M.NAMES = {
  "AI_ASK",
  "AI_ANALYZE_ROOM",
  "AI_ANALYZE_SYSTEM",
  "AI_RECORD_EVENT",
  "AI_SET_CONTEXT",
  "AI_LEARN_PREFERENCE",
  "AI_SUGGEST_SCENE",
  "AI_GENERATE_REPORT",
  "AI_START_DIAGNOSTIC",
  "AI_SEND_NOTIFICATION",
  "AI_RUN_HOUSEHOLD_ANALYSIS",
}

--- Composer LIST labels ("Last 7 days") and wire codes ("last_7_days") both
--- normalise to the code.
function M.normaliseEnum(s)
  return (tostring(s or ""):lower():gsub("[^%w]+", "_"):gsub("^_+", ""):gsub("_+$", ""))
end

-- ─── Text the cloud accepts ────────────────────────────────────────────────
--
-- The platform (rpc/ops.ts validateOpBody) trims every text field with JS
-- String.prototype.trim, refuses it when it contains a character of
-- UNPRINTABLE (U+0000–U+0008, U+000B–U+001F, U+007F–U+009F, U+2028, U+2029)
-- and when it is longer than its bound counted in CODE POINTS ([...t].length),
-- and one bad field refuses the whole request (invalid_args). So every text
-- the driver sends goes through sanitise(): each code point the platform
-- refuses — and every other C0 control (TAB, LF) as well — becomes a space,
-- a byte that is not well-formed UTF-8 is dropped (the JSON body must be
-- valid UTF-8), the ends are trimmed with the platform's whitespace set, and
-- `max` is a count of code points cut between two characters, never inside a
-- multi-byte sequence.

--- The bound of each text field of a cloud-op body, by its wire name (the
--- platform's OP_BODIES bound for the same field: rpc/ops.ts). Names Director
--- supplies (room_name, device_name) are cut to it; free text a programmer
--- typed is REFUSED over it by build() (a question cut in half is a
--- different question) and only cut here as a last guard.
M.BODY_TEXT_MAX = {
  question = L.question,
  statement = L.statement,
  value = L.value,
  occasion = L.occasion,
  title = L.title,
  message = L.message,
  room_name = L.room,
  device_name = L.device_name,
}

--- What JS String.prototype.trim removes (WhiteSpace + LineTerminator).
local JS_SPACE = {
  [0x09] = true,
  [0x0A] = true,
  [0x0B] = true,
  [0x0C] = true,
  [0x0D] = true,
  [0x20] = true,
  [0xA0] = true,
  [0x1680] = true,
  [0x2028] = true,
  [0x2029] = true,
  [0x202F] = true,
  [0x205F] = true,
  [0x3000] = true,
  [0xFEFF] = true,
}
for cp = 0x2000, 0x200A do
  JS_SPACE[cp] = true
end

--- True for a code point the driver never sends: every C0 control, DEL,
--- every C1 control, U+2028 LINE SEPARATOR, U+2029 PARAGRAPH SEPARATOR.
function M.refusedCodePoint(cp)
  return cp < 0x20 or (cp >= 0x7F and cp <= 0x9F) or cp == 0x2028 or cp == 0x2029
end

--- Well-formed UTF-8 → list of { code point, bytes }; a byte that does not
--- start a well-formed sequence (stray continuation, overlong form,
--- surrogate, > U+10FFFF, truncated sequence) is dropped.
local function decode(s)
  local out = {}
  local i, n = 1, #s
  while i <= n do
    local b = s:byte(i)
    local len, cp, min
    if b < 0x80 then
      len, cp, min = 1, b, 0
    elseif b >= 0xC2 and b <= 0xDF then
      len, cp, min = 2, b - 0xC0, 0x80
    elseif b >= 0xE0 and b <= 0xEF then
      len, cp, min = 3, b - 0xE0, 0x800
    elseif b >= 0xF0 and b <= 0xF4 then
      len, cp, min = 4, b - 0xF0, 0x10000
    end
    local ok = len ~= nil and i + len - 1 <= n
    if ok then
      for k = 1, len - 1 do
        local c = s:byte(i + k)
        if c < 0x80 or c > 0xBF then
          ok = false
          break
        end
        cp = cp * 64 + (c - 0x80)
      end
    end
    if ok and (cp < min or cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF)) then
      ok = false
    end
    if ok then
      out[#out + 1] = { cp, s:sub(i, i + len - 1) }
      i = i + len
    else
      i = i + 1
    end
  end
  return out
end

--- Length in code points (what the platform's bounds count).
function M.length(s)
  return #decode(tostring(s or ""))
end

--- Text the platform accepts: refused characters → space, malformed bytes
--- dropped, ends trimmed, at most `max` code points (cut on a character
--- boundary, then trimmed again). Never longer than its input.
function M.sanitise(s, max)
  if s == nil then
    return ""
  end
  local chars = decode(tostring(s))
  for _, c in ipairs(chars) do
    if M.refusedCodePoint(c[1]) then
      c[1], c[2] = 0x20, " "
    end
  end
  local first, last = 1, #chars
  while first <= last and JS_SPACE[chars[first][1]] do
    first = first + 1
  end
  while last >= first and JS_SPACE[chars[last][1]] do
    last = last - 1
  end
  if max ~= nil and last - first + 1 > max then
    last = first + max - 1
    while last >= first and JS_SPACE[chars[last][1]] do
      last = last - 1
    end
  end
  local parts = {}
  for k = first, last do
    parts[#parts + 1] = chars[k][2]
  end
  return table.concat(parts)
end

--- At most `maxBytes` bytes of UTF-8 text, cut between two characters.
function M.cutBytes(s, maxBytes)
  s = tostring(s or "")
  if #s <= maxBytes then
    return s
  end
  local cut = maxBytes
  -- back off while the byte after the cut continues a character
  while cut > 0 and (s:byte(cut + 1) or 0) >= 0x80 and s:byte(cut + 1) < 0xC0 do
    cut = cut - 1
  end
  return s:sub(1, cut)
end

--- The shared envelope's bounds (sbos/envelope.lua LIMITS): text 512 and
--- label 120, both in BYTES. envelope.lua cuts over-long strings with
--- string.sub, which can split a multi-byte UTF-8 character; the Agent then
--- cannot decode the frame that carries it (docs/ai-core/KNOWN-ISSUES.md
--- KI-1). AI Core therefore cuts every payload string and its label HERE,
--- between two characters, before sbos.envelope ever sees them.
M.ENVELOPE_TEXT_BYTES = 512
M.ENVELOPE_LABEL_BYTES = 120

--- Copy of `value` with every string cut to `maxBytes` (default 512)
--- between UTF-8 characters, keys included; tables walked to depth 6
--- (deeper is left to the envelope, which replaces it). Returns copy, cut.
function M.boundPayloadText(value, maxBytes, depth)
  maxBytes = maxBytes or M.ENVELOPE_TEXT_BYTES
  depth = depth or 0
  if type(value) == "string" then
    if #value > maxBytes then
      return M.cutBytes(value, maxBytes), true
    end
    return value, false
  end
  if type(value) ~= "table" or depth > 6 then
    return value, false
  end
  local out, cut = {}, false
  for k, v in pairs(value) do
    local bv, c = M.boundPayloadText(v, maxBytes, depth + 1)
    out[k] = bv
    cut = cut or c
  end
  return out, cut
end

--- A typed parameter, cleaned (no bound: build() refuses over-long text).
function M.clean(s)
  return M.sanitise(s)
end

--- A name Director supplies, cut to the platform's bound; nil when nothing
--- printable is left (the field is then not sent).
local function boundName(s, max)
  if s == nil then
    return nil
  end
  local v = M.sanitise(s, max)
  return v ~= "" and v or nil
end

local function refusal(name, message)
  return { code = "invalid_args", message = name .. ": " .. message }
end

--- Resolves a Composer room (an id, or a room name) against the project.
--- ctx.rooms() → { [id] = name }.
local function resolveRoom(raw, ctx)
  local s = M.clean(raw)
  if s == "" then
    return nil, nil
  end
  if M.length(s) > L.room then
    return nil, "longer than " .. L.room .. " characters (use the room id)"
  end
  local rooms = (ctx and ctx.rooms and ctx.rooms()) or {}
  local id = tonumber(s)
  if id ~= nil then
    if rooms[id] == nil then
      return nil, "no room " .. s .. " in this project"
    end
    return { id = id, name = boundName(rooms[id], L.room) }
  end
  local wanted = s:lower()
  for rid, name in pairs(rooms) do
    if M.clean(name):lower() == wanted then
      return { id = rid, name = boundName(name, L.room) }
    end
  end
  return nil, "no room named '" .. s .. "' in this project"
end

local function resolveDevice(raw, ctx)
  local s = M.clean(raw)
  if s == "" or s == "0" then
    return nil, nil
  end
  local id = tonumber(s)
  if id == nil or id ~= math.floor(id) or id <= 0 then
    return nil, "not a device id"
  end
  local devices = (ctx and ctx.devices and ctx.devices()) or {}
  local d = devices[id]
  if d == nil then
    return nil, "no device " .. s .. " in this project"
  end
  return {
    id = id,
    name = boundName(d.name, L.device_name),
    room_id = d.room_id,
    room_name = boundName(d.room_name, L.room),
  }
end

--- @param name string Composer command name
--- @param params table|nil tParams (string values)
--- @param ctx table { rooms = fn, devices = fn, excludedRooms = set|nil, learningActive = bool }
--- @return table|nil cmd, table|nil refusal { code, message }
function M.build(name, params, ctx)
  local spec = M.SPECS[name]
  if spec == nil then
    return nil, { code = "invalid_args", message = "unknown command " .. tostring(name) }
  end
  params = type(params) == "table" and params or {}
  ctx = ctx or {}
  local cmd = { name = name, op = spec.op, feature = spec.feature, args = {}, free_text = false }
  for _, key in ipairs(spec.order) do
    local p = spec.params[key]
    local raw = params[key]
    if p.kind == "text" then
      local v = M.clean(raw)
      if v == "" then
        if p.required then
          return nil, refusal(key, "is required")
        end
      elseif M.length(v) > p.max then
        return nil, refusal(key, "longer than " .. p.max .. " characters")
      else
        cmd.args[key:lower()] = v
        cmd.free_text = true
      end
    elseif p.kind == "enum" then
      local v = M.normaliseEnum(raw)
      if v == "" then
        if p.required then
          return nil, refusal(key, "is required")
        end
        v = p.default
      elseif not p.list[v] then
        return nil, refusal(key, "'" .. tostring(raw) .. "' is not one of the allowed values")
      end
      -- (`key` would be redacted as a credential by the envelope rules)
      cmd.args[p.as or key:lower()] = v
    elseif p.kind == "room" then
      local room, why = resolveRoom(raw, ctx)
      if why ~= nil then
        return nil, refusal(key, why)
      end
      if room == nil and p.required then
        return nil, refusal(key, "is required")
      end
      if room ~= nil then
        cmd.args.room_id = room.id
        cmd.args.room_name = room.name
      end
    elseif p.kind == "device" then
      local device, why = resolveDevice(raw, ctx)
      if why ~= nil then
        return nil, refusal(key, why)
      end
      if device ~= nil then
        cmd.args.device_id = device.id
        cmd.args.device_name = device.name
        cmd.device_room_id = tonumber(device.room_id)
      end
    end
  end
  if spec.one_of then
    local any = cmd.args.device_id ~= nil or cmd.args.room_id ~= nil
    if not any then
      return nil, refusal(table.concat(spec.one_of, "/"), "one of them is required")
    end
    if cmd.args.device_id ~= nil and cmd.args.room_id ~= nil then
      return nil, refusal(table.concat(spec.one_of, "/"), "give one, not both")
    end
  end
  local excluded = ctx.excludedRooms or {}
  local roomId = cmd.args.room_id or cmd.device_room_id
  if roomId ~= nil and excluded[roomId] and name ~= "AI_ASK" and name ~= "AI_SEND_NOTIFICATION" then
    return nil,
      {
        code = "not_permitted",
        message = name
          .. ": room "
          .. tostring(cmd.args.room_name or roomId)
          .. " is excluded by the AI Core configuration",
      }
  end
  if spec.needs_learning and not ctx.learningActive then
    return nil, { code = "not_permitted", message = name .. ": learning is paused for this home" }
  end
  return cmd
end

local SAFETY = { safety = true, security = true }

--- Envelope fields. AI_RECORD_EVENT → ai_core.record (an instrumented
--- marker); every other command → ai_core.command (a REQUEST, never a
--- result: the answer comes later from the platform).
function M.envelope(cmd, requestId)
  local args = {}
  for k, v in pairs(cmd.args) do
    args[k] = v
  end
  if cmd.name == "AI_RECORD_EVENT" then
    return {
      event_type = "ai_core.record",
      evidence_source = "instrumented",
      quality = "unreviewed_text",
      severity = SAFETY[args.category] and "warning" or "info",
      label = M.cutBytes(args.name, 120), -- the envelope's label bound is bytes
      room_id = args.room_id,
      correlation_id = requestId,
      payload = {
        request_id = requestId,
        name = args.name,
        detail = args.detail,
        category = args.category,
        room_id = args.room_id,
        room_name = args.room_name,
        note = "recorded by Composer programming; it says what the programming reports, not an observed result",
      },
    }
  end
  return {
    event_type = "ai_core.command",
    evidence_source = "requested",
    quality = cmd.free_text and "unreviewed_text" or "confirmed",
    severity = "info",
    label = cmd.name,
    room_id = args.room_id,
    device_id = args.device_id,
    correlation_id = requestId,
    payload = { command = cmd.name, op = cmd.op, request_id = requestId, args = args },
  }
end

--- Argument names that differ on the wire. The envelope must not carry a
--- key named `key` (it is redacted as a credential), so the context key is
--- `context_key` locally; the cloud body is not an envelope, and the
--- platform's OP_BODIES.set_context (rpc/ops.ts) names it `key`.
M.BODY_NAMES = { context_key = "key" }

--- The cloud op's body (the Agent adds who sent it; the platform derives
--- tenant and property from the Agent's pairing token, never from here).
function M.body(cmd, requestId, extra)
  local body = { command = cmd.name, request_id = requestId }
  for k, v in pairs(cmd.args) do
    body[M.BODY_NAMES[k] or k] = v
  end
  for k, v in pairs(extra or {}) do
    body[k] = v
  end
  -- Last guard: every bounded text field satisfies the platform's rule for
  -- that field, whatever built it (an empty one is not sent at all).
  for k, max in pairs(M.BODY_TEXT_MAX) do
    if type(body[k]) == "string" then
      local v = M.sanitise(body[k], max)
      body[k] = v ~= "" and v or nil
    end
  end
  return body
end

--- What a CLOUD_RESPONSE answer means. outcome:
---   accepted    the platform took it AS A JOB (a job_id); the result arrives
---               later as deliver_result
---   completed   the platform took it and finished it now ({accepted: true}
---               with job_id null or absent: set_context, send_notification);
---               nothing will be delivered later, so nothing may wait for it
---   refused     the platform (or the relay) said no, with a code; not retried
---               by the driver (rate_limited included: the module client has
---               already retried it, and it is an answer, not silence)
---   unreachable the cloud or the Agent could not be reached after retries
---   unavailable this Agent cannot relay at all (v1 Agent)
function M.interpret(answer)
  answer = answer or {}
  if answer.status == "ok" then
    local r = type(answer.result) == "table" and answer.result or {}
    if r.accepted == true then
      -- Only a real id is a job: JSON null decodes to nil, and anything that
      -- is not a non-empty string or a number (a null sentinel, a table)
      -- names nothing that a deliver_result could ever match.
      local job = r.job_id
      if (type(job) == "string" and job ~= "") or type(job) == "number" then
        return { outcome = "accepted", job_id = M.cutBytes(job, 128), code = "ok" }
      end
      return { outcome = "completed", code = "ok" }
    end
    return {
      outcome = "refused",
      code = "cloud_refused",
      message = "the platform answered without accepting the request",
    }
  end
  local code = tostring(answer.error_code or "internal_error")
  if code == "incompatible_protocol" then
    return { outcome = "unavailable", code = code, message = "the SmartBuildOS Agent must be updated (protocol 2)" }
  end
  if code == "cloud_unreachable" or code == "deadline_exceeded" or code == "target_unavailable" then
    return { outcome = "unreachable", code = code, message = "no answer from SmartBuildOS (" .. code .. ")" }
  end
  if code == "rate_limited" then
    -- The platform's per-system limits (send_notification, test_provider)
    -- and the Agent's own bucket both answer this: an answer, not silence.
    return {
      outcome = "refused",
      code = code,
      message = "rate limited by SmartBuildOS (rate_limited); try again later",
    }
  end
  return { outcome = "refused", code = code, message = "refused by SmartBuildOS: " .. code }
end

--- What the cloud's answer to analyze_household (AI_RUN_HOUSEHOLD_ANALYSIS)
--- means. The cloud never sends deliver_result for it, so nothing ever
--- waits. outcome:
---   queued      {accepted: true, state: "queued"}: the cloud took it; the run
---               happens after the answer and the driver is never told when
---               it finishes (the result appears in System Studio)
---   completed   {accepted: true, state: "completed"}
---   accepted    {accepted: true} with no or an unknown state — never shown
---               as completed
---   refused     the cloud's typed reason travels in result.reason
---               (rate_limited, learning_not_allowed, not_licensed,
---               already_running, not_permitted, invalid_args, or one added
---               later — shown as it is); without a reason, error_code is
---               shown. not_permitted WITHOUT a reason is the Agent itself
---               refusing an op it does not relay (agent_outdated): the cloud
---               always names its own reason for this op.
---   unreachable / unavailable   as interpret()
function M.interpretHousehold(answer)
  answer = answer or {}
  local r = type(answer.result) == "table" and answer.result or {}
  if answer.status == "ok" then
    if r.accepted ~= true then
      return {
        outcome = "refused",
        code = "cloud_refused",
        message = "the platform answered without accepting the request",
      }
    end
    if r.state == "queued" then
      return { outcome = "queued", code = "ok", text = "accepted (queued)" }
    elseif r.state == "completed" then
      return { outcome = "completed", code = "ok", text = "completed" }
    end
    return { outcome = "accepted", code = "ok", text = "accepted" }
  end
  local base = M.interpret(answer)
  if base.outcome == "unreachable" or base.outcome == "unavailable" then
    return base
  end
  local code = tostring(answer.error_code or "internal_error")
  local reason = r.reason
  if type(reason) == "string" and #reason <= 48 and reason:match("^[a-z][a-z0-9_]*$") then
    local wait = tonumber(r.retry_after_seconds)
    local after = ""
    if wait ~= nil and wait > 0 then
      after = string.format("; SmartBuildOS allows the next run in about %d minute(s)", math.ceil(wait / 60))
    end
    return {
      outcome = "refused",
      code = reason,
      message = "refused by SmartBuildOS (" .. reason .. ")" .. after,
    }
  end
  if code == "not_permitted" then
    return {
      outcome = "refused",
      code = code,
      agent_outdated = true,
      message = "the SmartBuildOS Agent refused it (not_permitted): update the SmartBuildOS Agent"
        .. " to a build that relays analyze_household",
    }
  end
  return { outcome = "refused", code = code, message = base.message }
end

--- A token bucket over Composer commands: programming in a loop must not
--- turn into a stream of cloud calls. Returns take() → bool.
function M.newBucket(perMinute, now)
  local bucket = { tokens = perMinute, at = now(), per = perMinute }
  function bucket.take()
    local t = now()
    bucket.tokens = math.min(bucket.per, bucket.tokens + (t - bucket.at) * bucket.per / 60)
    bucket.at = t
    if bucket.tokens < 1 then
      return false
    end
    bucket.tokens = bucket.tokens - 1
    return true
  end
  return bucket
end

return M
