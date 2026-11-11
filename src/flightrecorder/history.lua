--- Flight Recorder: one local history (pure).
---
--- The recorder emits envelopes of several kinds for upload: variable
--- changes, trace steps, system notices. The event-capture engine keeps a
--- ring of the device events it sees. A dealer on site wants ONE list in the
--- order things happened: the motion sensor fired, the routine started, the
--- light went from 75 to 0. This module turns an envelope the driver has
--- already built into the short entry that goes into that ring
--- (tracer.tracer `note`), or nil when the envelope does not belong there.
---
--- What goes in is exactly what was about to be uploaded, after the
--- envelope's own redaction, so the local history never holds a value the
--- configuration excluded.

local Envelope = require("sbos.envelope")

local M = {}

M.LIMITS = { text = 160, value = 120 }

local function clip(value, n)
  if value == nil then
    return nil
  end
  local text = tostring(value)
  if #text > n then
    return text:sub(1, n)
  end
  return text
end

--- A value kept as it is when it is a number or a boolean, cut when text.
--- The history is printed to the Lua tab and carried in snapshots as plain
--- lines, where the envelope's key-by-key redaction no longer applies. So a
--- value is hidden HERE when its variable is named like a code or a
--- credential, or when the value itself looks like one. The recorder's
--- configuration already refuses to listen to such variables; this is the
--- second lock.
local function kept(value, variableName)
  if value == nil then
    return nil
  end
  if variableName ~= nil and Envelope.isSensitiveKey(variableName) then
    return Envelope.REDACTED
  end
  if type(value) == "number" or type(value) == "boolean" then
    return value
  end
  if Envelope.looksLikeSecret(value) then
    return Envelope.REDACTED
  end
  return clip(value, M.LIMITS.value)
end

local TRACE_STEP = {
  ["trace.start"] = "start",
  ["trace.step"] = "step",
  ["trace.decision"] = "decision",
  ["trace.expected"] = "expects",
  ["trace.end"] = "end",
  ["trace.orphan_step"] = "no trace open",
  ["trace.refused"] = "refused",
  ["trace.duplicate_completion"] = "already ended",
}

local function traceText(env, p)
  local t = env.event_type
  if t == "trace.start" then
    return p.name or env.label
  elseif t == "trace.end" then
    local parts = { tostring(p.status or "ended") }
    if p.reason ~= nil and tostring(p.reason) ~= "" then
      parts[#parts + 1] = tostring(p.reason)
    elseif p.note ~= nil and tostring(p.note) ~= "" then
      parts[#parts + 1] = tostring(p.note)
    end
    parts[#parts + 1] = string.format("%d step(s), %d s", tonumber(p.steps) or 0, tonumber(p.duration_seconds) or 0)
    return table.concat(parts, "; ")
  elseif t == "trace.decision" then
    return tostring(p.condition or env.label or "") .. " → " .. tostring(p.outcome or "?")
  end
  return env.label or p.message or p.expected or p.reason
end

--- @param env table an envelope as sbos.envelope built it
--- @param labels table|nil { device = fun(id):string|nil } to name a device the envelope only has an id for
--- @return table|nil entry for tracer `note`
function M.entryFor(env, labels)
  if type(env) ~= "table" or type(env.event_type) ~= "string" then
    return nil
  end
  local t = env.event_type
  local p = type(env.payload) == "table" and env.payload or {}
  local deviceId = tonumber(env.device_id)
  local function deviceLabel()
    if p.device_label ~= nil then
      return clip(p.device_label, 80)
    end
    if deviceId ~= nil and labels and labels.device then
      local ok, name = pcall(labels.device, deviceId)
      if ok and type(name) == "string" and name ~= "" then
        return clip(name, 80)
      end
    end
    return nil
  end

  if t == "observation.change" or t == "observation.initial" then
    return {
      kind = "change",
      device_id = deviceId,
      device_label = deviceLabel(),
      room_label = clip(p.room_label, 80),
      variable = clip(p.variable, 80),
      value = kept(p.value, p.variable),
      previous = kept(p.previous, p.variable),
      previous_known = p.previous_known == true,
      initial = t == "observation.initial",
      coalesced = tonumber(p.coalesced),
    }
  elseif t == "observation.programmed" then
    return {
      kind = "mark",
      device_id = deviceId,
      -- A marker recorded while a trace is open on its channel belongs to
      -- that trace (the driver sets the correlation id).
      trace_id = clip(env.correlation_id, 96),
      event_name = clip(p.name or env.label or "", 120),
      detail = clip(p.detail or "", M.LIMITS.text),
      known = true,
    }
  elseif t == "observation.system" then
    return { kind = "system", text = clip(p.event or env.label or "", M.LIMITS.text) }
  elseif TRACE_STEP[t] ~= nil then
    local step = TRACE_STEP[t]
    if (t == "trace.step" or t == "trace.decision" or t == "trace.expected") and tonumber(p.step) then
      step = step .. " " .. tostring(p.step)
    end
    return {
      kind = "trace",
      channel = clip(p.channel or "main", 40),
      trace_id = clip(p.trace_id or env.correlation_id, 96),
      step = step,
      name = (t == "trace.start" or t == "trace.end") and clip(p.name or env.label, 80) or nil,
      text = clip(traceText(env, p) or "", M.LIMITS.text),
      status = t == "trace.end" and clip(p.status, 24) or nil,
      device_id = deviceId,
      device_label = deviceId ~= nil and deviceLabel() or nil,
    }
  elseif t == "tracer.storm" or t == "tracer.storm_ended" then
    return {
      kind = "note",
      device_id = deviceId,
      text = clip(
        (env.label or t)
          .. (
            t == "tracer.storm" and "; further occurrences this minute are counted, not listed"
            or string.format(" (%d in the minute, %d not listed)", tonumber(p.count) or 0, tonumber(p.suppressed) or 0)
          ),
        M.LIMITS.text
      ),
    }
  elseif
    t == "recorder.paused"
    or t == "recorder.resumed"
    or t == "recorder.config_applied"
    or t == "recorder.config_refused"
    or t == "recorder.budget_exceeded"
    or t == "tracer.budget_exceeded"
    or t == "snapshot.requested"
  then
    return { kind = "note", text = clip(env.label or t, M.LIMITS.text) }
  end
  -- capture.* is already in the ring (the engine put it there); the rest
  -- (tracer.applied, tracer.learned, tracer.paused/resumed) is bookkeeping.
  return nil
end

return M
