--- SmartBuildOS AI Core — the local diagnostic envelope (pure).
---
--- AI_START_DIAGNOSTIC and the restricted operation run_diagnostic attach
--- the most recent events the Flight Recorder holds LOCALLY for the target
--- (asked over module contract v2: events.device_history or
--- events.room_activity) to one `ai_core.diagnostic` envelope. When the
--- Flight Recorder is absent, cannot be asked, or answers with an error,
--- the envelope says exactly that — it never fails silently and never
--- invents an event. The envelope payload is bounded (4 KB): events are
--- summarised (id, time, kind, short text) and cut from the oldest end,
--- with the cut counted.

local Envelope = require("sbos.envelope")
local Commands = require("aicore.commands")

local M = {}

M.LIMITS = { events = 25, payload_budget = 3300, line = 80 }

--- A scalar the summary may carry (string ≤ 128 or number), else nil: a
--- malformed answer never puts a table where an id or a time belongs.
local function scalar(v)
  if type(v) == "number" then
    return v
  end
  if type(v) == "string" and #v <= 128 then
    return v
  end
  return nil
end

-- A dense list of NAMES, read one by one: a list of the values themselves has
-- holes wherever a field is absent (a variable change has no event_name), and
-- ipairs stops at the first hole, dropping everything after it.
local LINE_FIELDS = { "device_label", "event_name", "variable", "value", "text", "step" }

local function line(e)
  local parts = {}
  for _, k in ipairs(LINE_FIELDS) do
    local v = e[k]
    if (type(v) == "string" or type(v) == "number") and tostring(v) ~= "" then
      parts[#parts + 1] = tostring(v)
    end
  end
  return Commands.cutBytes(table.concat(parts, " · "), M.LIMITS.line) -- never half a character
end

--- @param target table { device_id?, room_id?, device_name?, room_name? }
--- @param fr table { state = "present"|"present_v1"|"absent"|"unknown", answer = request answer|nil }
--- @return table envelope fields
function M.fields(target, fr, requestId, source)
  local recorder
  local answer = fr.answer
  if fr.state == "absent" then
    recorder = { available = false, reason = "flight_recorder_not_installed" }
  elseif fr.state == "present_v1" then
    recorder = { available = false, reason = "flight_recorder_has_no_local_history_service" }
  elseif fr.state ~= "present" then
    recorder = { available = false, reason = "flight_recorder_unknown_agent_cannot_discover" }
  elseif answer == nil then
    recorder = { available = false, reason = "not_asked" }
  elseif answer.status ~= "ok" then
    recorder = { available = false, reason = "request_failed", error_code = tostring(answer.error_code) }
  else
    local r = type(answer.result) == "table" and answer.result or {}
    local ret = type(r.retention) == "table" and r.retention or {}
    recorder = {
      available = true,
      capability = type(r.capability) == "string" and scalar(r.capability) or nil,
      truncated = r.truncated == true,
      held = scalar(ret.held),
      capacity = scalar(ret.capacity),
      oldest_available = type(ret.oldest_available) == "table" and {
        seq = scalar(ret.oldest_available.seq),
        at = scalar(ret.oldest_available.at),
      } or nil,
      events = {},
      omitted = 0,
    }
    local events = type(r.events) == "table" and r.events or {}
    local malformed = 0
    for i = 1, math.min(#events, M.LIMITS.events) do
      local e = events[i]
      if type(e) == "table" then
        recorder.events[#recorder.events + 1] = {
          event_id = type(e.event_id) == "string" and scalar(e.event_id) or nil,
          no_event_id = type(e.no_event_id) == "string" and scalar(e.no_event_id) or nil,
          at = scalar(e.at),
          kind = type(e.kind) == "string" and scalar(e.kind) or nil,
          line = line(e),
        }
      else
        malformed = malformed + 1 -- not an event: counted, never indexed
      end
    end
    recorder.omitted = math.max(0, #events - #recorder.events)
    if malformed > 0 then
      recorder.malformed = malformed
    end
    -- Fit the payload budget: drop the OLDEST summaries first (the answer is
    -- newest first), counted.
    local function size()
      return Envelope.approxSize({ target = target, flight_recorder = recorder })
    end
    while #recorder.events > 0 and size() > M.LIMITS.payload_budget do
      table.remove(recorder.events)
      recorder.omitted = recorder.omitted + 1
    end
  end
  return {
    event_type = "ai_core.diagnostic",
    evidence_source = "derived",
    quality = recorder.available and "confirmed" or "partial",
    severity = "info",
    -- the envelope cuts a label at 120 BYTES; cut it here first, between characters
    label = Commands.cutBytes(
      "Local diagnostic: "
        .. tostring(target.device_name or target.room_name or target.device_id or target.room_id or "?"),
      Envelope.LIMITS.label
    ),
    device_id = target.device_id,
    room_id = target.room_id,
    correlation_id = requestId,
    payload = {
      request_id = requestId,
      source = source,
      target = target,
      flight_recorder = recorder,
      note = "local Flight Recorder history only; causes are not inferred on the controller",
    },
  }
end

--- The event ids cited by a diagnostic (for the cloud op body).
function M.eventIds(fields)
  local out = {}
  local fr = fields.payload.flight_recorder
  for _, e in ipairs(fr.events or {}) do
    if e.event_id then
      out[#out + 1] = e.event_id
    end
  end
  return out
end

return M
