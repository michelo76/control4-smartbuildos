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
--- command is an event for the Agent's durable queue and, for nine of the
--- ten, one call of a cloud op from MODULE_CLOUD_OPS.ai_core. AI_RECORD_EVENT
--- has no cloud op; it is recorded through the durable event path.

local V = require("aicore.vocab")

local M = {}

local L = V.LIMITS

local function text(max, required)
  return { kind = "text", max = max, required = required }
end
local function enum(list, required, default, as)
  return { kind = "enum", list = list, required = required, default = default, as = as }
end

--- The ten commands (driver.xml <commands> carries the same names/params).
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
}

--- Composer LIST labels ("Last 7 days") and wire codes ("last_7_days") both
--- normalise to the code.
function M.normaliseEnum(s)
  return (tostring(s or ""):lower():gsub("[^%w]+", "_"):gsub("^_+", ""):gsub("_+$", ""))
end

--- Control characters out, whitespace collapsed at the ends.
function M.clean(s)
  if s == nil then
    return ""
  end
  local out = tostring(s):gsub("[%c]", " ")
  return (out:gsub("^%s+", ""):gsub("%s+$", ""))
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
  if #s > L.room then
    return nil, "longer than " .. L.room .. " characters"
  end
  local rooms = (ctx and ctx.rooms and ctx.rooms()) or {}
  local id = tonumber(s)
  if id ~= nil then
    if rooms[id] == nil then
      return nil, "no room " .. s .. " in this project"
    end
    return { id = id, name = rooms[id] }
  end
  local wanted = s:lower()
  for rid, name in pairs(rooms) do
    if tostring(name):lower() == wanted then
      return { id = rid, name = name }
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
  return { id = id, name = d.name, room_id = d.room_id, room_name = d.room_name }
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
      elseif #v > p.max then
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
      label = tostring(args.name or ""):sub(1, 120),
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

--- The cloud op's body (the Agent adds who sent it; the platform derives
--- tenant and property from the Agent's pairing token, never from here).
function M.body(cmd, requestId, extra)
  local body = { command = cmd.name, request_id = requestId }
  for k, v in pairs(cmd.args) do
    body[k] = v
  end
  for k, v in pairs(extra or {}) do
    body[k] = v
  end
  return body
end

--- What a CLOUD_RESPONSE answer means. outcome:
---   accepted   the platform took it; the result arrives later (deliver_result)
---   refused    the platform (or the relay) said no, with a code; not retried
---   unreachable the cloud or the Agent could not be reached after retries
---   unavailable this Agent cannot relay at all (v1 Agent)
function M.interpret(answer)
  answer = answer or {}
  if answer.status == "ok" then
    local r = type(answer.result) == "table" and answer.result or {}
    if r.accepted == true then
      return { outcome = "accepted", job_id = r.job_id ~= nil and tostring(r.job_id):sub(1, 128) or nil, code = "ok" }
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
  if
    code == "cloud_unreachable"
    or code == "deadline_exceeded"
    or code == "target_unavailable"
    or code == "rate_limited"
  then
    return { outcome = "unreachable", code = code, message = "no answer from SmartBuildOS (" .. code .. ")" }
  end
  return { outcome = "refused", code = code, message = "refused by SmartBuildOS: " .. code }
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
