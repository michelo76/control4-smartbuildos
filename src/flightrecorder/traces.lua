--- Flight Recorder programming traces (pure).
---
--- ── THE CONCURRENCY MODEL, HONESTLY ──────────────────────────────────────
--- Composer programming cannot capture a value a driver command returns, so
--- there is no "handle" a routine could carry from Start Trace to Complete
--- Trace. The supported pattern is a CHANNEL: every trace command takes a
--- channel string the programmer types (default `main`). A routine that may
--- overlap with another uses its own channel ("good_night", "garage_check").
---
--- Rules per channel:
---   • Start on an idle channel opens a trace. Start on an ACTIVE channel
---     ends the earlier trace as `interrupted` (reason superseded) and opens
---     a new one — two executions of the same routine on one channel are
---     never merged into one trace.
---   • Step / Decision / Expected on an idle channel are recorded as ORPHAN
---     steps (event `trace.orphan_step`, no correlation): visible, never
---     attached to a guessed trace.
---   • Complete / Fail on an idle channel records `trace.duplicate_completion`
---     (warning) and changes nothing.
---   • A trace older than `timeoutSeconds` ends as `abandoned`.
---   • At most `maxActive` traces at once; a Start beyond that is refused
---     and recorded (`trace.refused`).
---   • A driver reload ends every active trace as `interrupted` (reload).
---
--- Every emitted event carries correlation_id = trace_id and the channel in
--- the payload; the server materialises trace rows from these events and
--- tolerates steps arriving before their start.

local M = {}

M.LIMITS = { channel = 48, name = 120, message = 400, maxActive = 16, timeoutSeconds = 600 }

local Traces = {}
Traces.__index = Traces

--- @param opts table { now = fun():number, emit = fun(fields), newId = fun(channel):string, maxActive?, timeoutSeconds? }
function M.new(opts)
  local self = setmetatable({}, Traces)
  self.now = opts.now
  self.emit = opts.emit
  self.newId = opts.newId
  self.maxActive = opts.maxActive or M.LIMITS.maxActive
  self.timeoutSeconds = opts.timeoutSeconds or M.LIMITS.timeoutSeconds
  self.active = {} -- channel -> trace
  self.counters =
    { started = 0, completed = 0, failed = 0, interrupted = 0, abandoned = 0, orphans = 0, duplicates = 0, refused = 0 }
  return self
end

local function channelOf(value)
  local c = tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if c == "" then
    c = "main"
  end
  return c:sub(1, M.LIMITS.channel)
end
M.channelOf = channelOf

local function text(value, limit)
  return tostring(value or ""):sub(1, limit)
end

function Traces:activeCount()
  local n = 0
  for _ in pairs(self.active) do
    n = n + 1
  end
  return n
end

function Traces:activeList()
  local out = {}
  for channel, t in pairs(self.active) do
    out[#out + 1] = { channel = channel, trace_id = t.id, name = t.name, started_at = t.started_at, steps = t.steps }
  end
  table.sort(out, function(a, b)
    return a.started_at < b.started_at
  end)
  return out
end

function Traces:_end(channel, t, status, reason, note)
  self.active[channel] = nil
  self.emit({
    event_type = "trace.end",
    evidence_source = "instrumented",
    severity = (status == "completed") and "info" or "warning",
    correlation_id = t.id,
    label = t.name,
    payload = {
      channel = channel,
      trace_id = t.id,
      name = t.name,
      status = status,
      reason = reason,
      note = note,
      steps = t.steps,
      duration_seconds = self.now() - t.started_at,
    },
  })
  self.counters[status] = (self.counters[status] or 0) + 1
end

--- @return string|nil traceId, string|nil reason
function Traces:start(channelValue, name, meta)
  local channel = channelOf(channelValue)
  local existing = self.active[channel]
  if existing ~= nil then
    self:_end(channel, existing, "interrupted", "superseded by a new Start Trace on channel " .. channel)
  elseif self:activeCount() >= self.maxActive then
    self.counters.refused = self.counters.refused + 1
    self.emit({
      event_type = "trace.refused",
      evidence_source = "derived",
      severity = "warning",
      label = text(name, M.LIMITS.name),
      payload = { channel = channel, reason = "too many active traces", max_active = self.maxActive },
    })
    return nil, "too_many_active"
  end
  local t = {
    id = self.newId(channel),
    name = text(name ~= nil and name ~= "" and name or channel, M.LIMITS.name),
    started_at = self.now(),
    steps = 0,
  }
  self.active[channel] = t
  self.counters.started = self.counters.started + 1
  self.emit({
    event_type = "trace.start",
    evidence_source = "instrumented",
    correlation_id = t.id,
    label = t.name,
    payload = { channel = channel, trace_id = t.id, name = t.name, meta = type(meta) == "table" and meta or nil },
  })
  return t.id
end

local function orphan(self, channel, kind, payload, label)
  self.counters.orphans = self.counters.orphans + 1
  payload.channel = channel
  payload.kind = kind
  self.emit({
    event_type = "trace.orphan_step",
    evidence_source = "instrumented",
    severity = "notice",
    quality = "unreviewed_text",
    label = label,
    payload = payload,
  })
end

local function record(self, channelValue, kind, payload, label, deviceId)
  local channel = channelOf(channelValue)
  local t = self.active[channel]
  if t == nil then
    orphan(self, channel, kind, payload, label)
    return nil
  end
  t.steps = t.steps + 1
  payload.channel = channel
  payload.trace_id = t.id
  payload.step = t.steps
  payload.kind = kind
  self.emit({
    event_type = "trace." .. kind,
    evidence_source = kind == "expected" and "requested" or "instrumented",
    quality = "unreviewed_text",
    correlation_id = t.id,
    label = label,
    device_id = deviceId,
    payload = payload,
  })
  return t.id
end

--- Record Trace Step: a programmer-supplied message. The message is free
--- text (quality unreviewed_text) and bounded.
function Traces:step(channel, message, deviceId)
  return record(
    self,
    channel,
    "step",
    { message = text(message, M.LIMITS.message) },
    text(message, 60),
    tonumber(deviceId)
  )
end

--- Record Trace Decision: a condition and the branch taken.
function Traces:decision(channel, condition, outcome)
  return record(
    self,
    channel,
    "decision",
    { condition = text(condition, M.LIMITS.message), outcome = text(outcome, 60) },
    text(condition, 60)
  )
end

--- Record Expected Result: what the programmer expects to observe next
--- (e.g. "Kitchen lights at 0%" on device 12). The recorder NEVER checks it;
--- Studio shows observed evidence next to it and lets a human judge.
function Traces:expected(channel, description, deviceId)
  return record(
    self,
    channel,
    "expected",
    { description = text(description, M.LIMITS.message) },
    text(description, 60),
    tonumber(deviceId)
  )
end

local function finish(self, channelValue, status, note)
  local channel = channelOf(channelValue)
  local t = self.active[channel]
  if t == nil then
    self.counters.duplicates = self.counters.duplicates + 1
    self.emit({
      event_type = "trace.duplicate_completion",
      evidence_source = "derived",
      severity = "warning",
      label = channel,
      payload = { channel = channel, attempted = status, note = text(note, M.LIMITS.message) },
    })
    return false
  end
  self:_end(channel, t, status, nil, text(note, M.LIMITS.message))
  return true
end

function Traces:complete(channel, note)
  return finish(self, channel, "completed", note)
end

function Traces:fail(channel, reason)
  return finish(self, channel, "failed", reason)
end

--- Periodic: abandons traces past the timeout. Returns how many.
function Traces:tick()
  local n = 0
  for channel, t in pairs(self.active) do
    if self.now() - t.started_at > self.timeoutSeconds then
      self:_end(channel, t, "abandoned", "no Complete/Fail Trace within " .. self.timeoutSeconds .. " s")
      n = n + 1
    end
  end
  return n
end

--- Driver reload / removal / pause: nothing stays silently open.
function Traces:interruptAll(reason)
  for channel, t in pairs(self.active) do
    self:_end(channel, t, "interrupted", reason or "recorder stopped")
  end
end

return M
