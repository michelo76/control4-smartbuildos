--- Flight Recorder — the recorder (pure, injected Director surface).
---
--- Turns a validated configuration into a reconciled listener set, and
--- listener callbacks into observation events. Rules that decide what a
--- technician later sees:
---
---   • INITIAL READS ARE NOT CHANGES. Applying a configuration reads each
---     resolved source once and emits `observation.initial` (evidence
---     `initial`). The previous value of a source is UNKNOWN until the first
---     change after that read, and an unknown previous value stays unknown
---     (`previous_known = false`) — it is never guessed from the initial read
---     of a different source or from history.
---   • RECONCILIATION, NOT RE-REGISTRATION. apply() computes the desired
---     (device, variable) set and adds/removes only the difference, so an
---     identical re-apply registers nothing twice and removes nothing.
---   • DEBOUNCE: a change on a debounced source restarts its timer; the LAST
---     value wins when the timer fires (one event per quiet period).
---   • MIN_CHANGE: numeric changes smaller than the threshold, measured
---     against the last EMITTED value, are not events (so a slow drift still
---     surfaces once it adds up).
---   • COALESCE: after an event, further changes within the window are
---     gathered into ONE event at the window's end carrying `coalesced = n`
---     (previous = the value before the window, value = the latest).
---   • BUDGET: more than `events_per_minute` emissions in a minute are
---     dropped and COUNTED; one `recorder.budget_exceeded` per minute says so.
---   • PRIVACY: fixed exclusions never register; pattern exclusions never
---     register; string values are flagged `unreviewed_text` or excluded per
---     `privacy.string_values`. The recorder's own counters are never a
---     source (no feedback loop: the driver's own device id is refused).
---
--- No callback does blocking work: a change is at most a table write and a
--- timer (re)schedule; emission is a function call into the module client's
--- staging buffer.

local Config = require("flightrecorder.config")

local M = {}

local Recorder = {}
Recorder.__index = Recorder

--- @param deps table { now = fun():number (seconds), schedule = fun(key, ms, fn), cancel = fun(key),
---   register = fun(deviceId, varId):boolean, unregister = fun(deviceId, varId),
---   readVariables = fun(deviceId):table|nil, emit = fun(fields), selfDeviceId = number|nil,
---   deviceLabel = fun(deviceId):string|nil, roomOf = fun(deviceId):table|nil }
function M.new(deps)
  local self = setmetatable({}, Recorder)
  self.deps = deps
  self.config = Config.default()
  self.plan = nil
  self.listeners = {} -- "dev:var" -> listener
  self.eventSources = {} -- event name -> source
  self.paused = false
  self.counters = {
    events = 0,
    initial = 0,
    changes = 0,
    coalesced = 0,
    debounced = 0,
    below_min_change = 0,
    dropped_budget = 0,
    dropped_string = 0,
    excluded = 0,
    stale = 0,
    unsupported = 0,
    listeners = 0,
    system_events = 0,
  }
  self.minute = { start = deps.now(), count = 0, warned = false }
  return self
end

local function lkey(deviceId, varId)
  return tostring(deviceId) .. ":" .. tostring(varId)
end

--- Typed view of a raw variable value. Control4 hands strings; "True"/"False"
--- and numbers are recognised, everything else stays text.
function M.typedValue(raw)
  if raw == nil then
    return nil, "unknown"
  end
  if type(raw) == "boolean" then
    return raw, "boolean"
  end
  if type(raw) == "number" then
    return raw, "number"
  end
  local s = tostring(raw)
  local lower = s:lower()
  if lower == "true" then
    return true, "boolean"
  elseif lower == "false" then
    return false, "boolean"
  end
  local n = tonumber(s)
  if n ~= nil then
    return n, "number"
  end
  return s, "string"
end

function Recorder:_budgetAllows()
  local now = self.deps.now()
  if now - self.minute.start >= 60 then
    self.minute = { start = now, count = 0, warned = false }
  end
  if self.minute.count >= self.config.budgets.events_per_minute then
    self.counters.dropped_budget = self.counters.dropped_budget + 1
    if not self.minute.warned then
      self.minute.warned = true
      self.deps.emit({
        event_type = "recorder.budget_exceeded",
        evidence_source = "derived",
        severity = "warning",
        label = "Recording budget exceeded",
        payload = {
          events_per_minute = self.config.budgets.events_per_minute,
          dropped_so_far = self.counters.dropped_budget,
          note = "observations beyond the per-minute budget were dropped and counted; this minute is incomplete",
        },
      })
    end
    return false
  end
  self.minute.count = self.minute.count + 1
  return true
end

function Recorder:_emit(fields)
  if not self:_budgetAllows() then
    return false
  end
  self.counters.events = self.counters.events + 1
  self.deps.emit(fields)
  return true
end

local function sourcePayload(l, extra)
  local p = {
    source_id = l.source.id,
    kind = l.source.kind,
    variable = l.variable_name,
    variable_id = l.variable_id,
    category = l.source.category,
    device_label = l.device_label,
    room_label = l.room_label,
  }
  for k, v in pairs(extra or {}) do
    p[k] = v
  end
  return p
end

function Recorder:_emitInitial(l)
  local value, vtype = M.typedValue(l.raw)
  if vtype == "string" and self.config.privacy.string_values == "exclude" then
    self.counters.dropped_string = self.counters.dropped_string + 1
    l.value, l.vtype = nil, "excluded"
    return
  end
  l.value, l.vtype = value, vtype
  l.observed_at = self.deps.now()
  self.counters.initial = self.counters.initial + 1
  self:_emit({
    event_type = "observation.initial",
    evidence_source = "initial",
    quality = vtype == "string" and "unreviewed_text" or "confirmed",
    device_id = l.device_id,
    room_id = l.room_id,
    label = l.source.label,
    payload = sourcePayload(
      l,
      { value = value, value_type = vtype, previous_known = false, note = "initial read after apply; not a change" }
    ),
  })
end

--- Emits one change (or one coalesced change) for a listener.
function Recorder:_emitChange(l, value, vtype, previous, previousKnown, coalesced)
  self.counters.changes = self.counters.changes + 1
  local ok = self:_emit({
    event_type = "observation.change",
    evidence_source = "observed",
    quality = vtype == "string" and "unreviewed_text" or "confirmed",
    device_id = l.device_id,
    room_id = l.room_id,
    label = l.source.label,
    payload = sourcePayload(l, {
      value = value,
      value_type = vtype,
      previous = previousKnown and previous or nil,
      previous_known = previousKnown,
      coalesced = coalesced,
    }),
  })
  l.value, l.vtype, l.observed_at = value, vtype, self.deps.now()
  l.known = true
  return ok
end

function Recorder:_deliver(l, value, vtype)
  local src = l.source
  local previousKnown = l.known == true or (l.vtype ~= nil and l.vtype ~= "unknown" and l.vtype ~= "excluded")
  if src.min_change and src.min_change > 0 and vtype == "number" and type(l.value) == "number" then
    if math.abs(value - l.value) < src.min_change then
      self.counters.below_min_change = self.counters.below_min_change + 1
      return
    end
  end
  if value == l.value and previousKnown then
    -- Director can re-announce an unchanged value; a change that is not a
    -- change is not recorded.
    return
  end
  local now = self.deps.now()
  if src.coalesce_ms and src.coalesce_ms > 0 then
    if l.window ~= nil and now < l.window.until_at then
      l.window.count = l.window.count + 1
      l.window.latest, l.window.vtype = value, vtype
      self.counters.coalesced = self.counters.coalesced + 1
      local key = "fr:c:" .. l.key
      self.deps.schedule(key, math.max(1, math.floor((l.window.until_at - now) * 1000)), function()
        local w = l.window
        l.window = nil
        if w ~= nil then
          self:_emitChange(l, w.latest, w.vtype, w.previous, w.previousKnown, w.count)
        end
      end)
      return
    end
    -- First change after quiet: emit now, open the window.
    local prev, prevKnown = l.value, previousKnown
    self:_emitChange(l, value, vtype, prev, prevKnown, nil)
    l.window = {
      until_at = now + src.coalesce_ms / 1000,
      count = 0,
      latest = value,
      vtype = vtype,
      previous = value,
      previousKnown = true,
    }
    return
  end
  self:_emitChange(l, value, vtype, l.value, previousKnown, nil)
end

--- Director's callback for a watched variable. Returns true if it was ours.
function Recorder:onChange(deviceId, varId, raw)
  local l = self.listeners[lkey(deviceId, varId)]
  if l == nil then
    return false
  end
  if self.paused then
    return true
  end
  local value, vtype = M.typedValue(raw)
  if vtype == "string" and self.config.privacy.string_values == "exclude" then
    self.counters.dropped_string = self.counters.dropped_string + 1
    return true
  end
  local src = l.source
  if src.debounce_ms and src.debounce_ms > 0 then
    self.counters.debounced = self.counters.debounced + 1
    l.pending = { value = value, vtype = vtype }
    self.deps.schedule("fr:d:" .. l.key, src.debounce_ms, function()
      local p = l.pending
      l.pending = nil
      if p ~= nil then
        self:_deliver(l, p.value, p.vtype)
      end
    end)
    return true
  end
  self:_deliver(l, value, vtype)
  return true
end

--- An Agent-classified SmartBuildOS event (the Agent forwards these to
--- registered modules). Recorded only when selected as a source.
function Recorder:onSbosEvent(name, detail)
  local src = self.eventSources[tostring(name)]
  if src == nil or self.paused then
    return false
  end
  self.counters.system_events = self.counters.system_events + 1
  self:_emit({
    event_type = "observation.system",
    evidence_source = "system",
    severity = (name == "unexpected_restart" or name == "clock_drift" or name == "device_offline") and "warning"
      or "info",
    label = src.label,
    payload = {
      source_id = src.id,
      kind = "sbos_event",
      event = name,
      detail = type(detail) == "table" and detail or { text = tostring(detail or "") },
      category = src.category,
    },
  })
  return true
end

function Recorder:_removeListener(key)
  local l = self.listeners[key]
  if l == nil then
    return
  end
  self.deps.cancel("fr:d:" .. key)
  self.deps.cancel("fr:c:" .. key)
  pcall(self.deps.unregister, l.device_id, l.variable_id)
  self.listeners[key] = nil
end

--- Applies a validated configuration: resolves it, reconciles listeners,
--- emits initial observations for NEW listeners only. Returns the summary.
function Recorder:apply(config)
  self.config = config
  local plan = Config.resolve(config, self.deps.readVariables)
  self.plan = plan
  local desired = {}
  for _, item in ipairs(plan.listeners) do
    if self.deps.selfDeviceId ~= nil and item.device_id == self.deps.selfDeviceId then
      -- Never record ourselves: a counter that records its own change is a
      -- feedback loop.
      plan.excluded[#plan.excluded + 1] = { source = item.source, reason = "self" }
    else
      desired[lkey(item.device_id, item.variable_id)] = item
    end
  end
  -- Remove what is no longer wanted.
  local removed = 0
  for key in pairs(self.listeners) do
    if desired[key] == nil then
      self:_removeListener(key)
      removed = removed + 1
    end
  end
  -- Add what is new; refresh settings on what stays.
  local added = 0
  for key, item in pairs(desired) do
    local existing = self.listeners[key]
    if existing ~= nil then
      existing.source = item.source
      existing.variable_name = item.variable_name
    else
      local ok = pcall(self.deps.register, item.device_id, item.variable_id)
      local room = self.deps.roomOf and self.deps.roomOf(item.device_id) or nil
      local l = {
        key = key,
        source = item.source,
        device_id = item.device_id,
        variable_id = item.variable_id,
        variable_name = item.variable_name,
        device_label = item.source.device_label
          or (self.deps.deviceLabel and self.deps.deviceLabel(item.device_id))
          or nil,
        room_id = item.source.room_id or (room and room.id) or nil,
        room_label = item.source.room_label or (room and room.name) or nil,
        raw = item.value,
        value = nil,
        vtype = "unknown",
        known = false,
        registered = ok == true,
      }
      self.listeners[key] = l
      added = added + 1
      if not self.paused then
        self:_emitInitial(l)
      end
    end
  end
  self.eventSources = {}
  for _, src in ipairs(plan.events) do
    self.eventSources[src.event] = src
  end
  local count = 0
  for _ in pairs(self.listeners) do
    count = count + 1
  end
  self.counters.listeners = count
  self.counters.stale = #plan.stale
  self.counters.unsupported = #plan.unsupported
  self.counters.excluded = #plan.excluded
  local summary = Config.summary(config, plan)
  summary.added = added
  summary.removed = removed
  self.deps.emit({
    event_type = "recorder.config_applied",
    evidence_source = "derived",
    label = "Recording configuration v" .. tostring(config.version) .. " applied",
    payload = summary,
  })
  return summary
end

function Recorder:pause(reason)
  if self.paused then
    return false
  end
  self.paused = true
  for key in pairs(self.listeners) do
    self:_removeListener(key)
  end
  self.counters.listeners = 0
  self.deps.emit({
    event_type = "recorder.paused",
    evidence_source = "derived",
    severity = "notice",
    label = "Recording paused",
    payload = { reason = tostring(reason or "") },
  })
  return true
end

function Recorder:resume(reason)
  if not self.paused then
    return false
  end
  self.paused = false
  self.deps.emit({
    event_type = "recorder.resumed",
    evidence_source = "derived",
    severity = "notice",
    label = "Recording resumed",
    payload = { reason = tostring(reason or ""), note = "sources are re-read; what happened while paused is not known" },
  })
  self:apply(self.config)
  return true
end

--- Removal / reload: every listener and timer goes.
function Recorder:stop()
  for key in pairs(self.listeners) do
    self:_removeListener(key)
  end
  self.counters.listeners = 0
end

--- Current values of selected sources (for snapshots and Studio).
function Recorder:observations()
  local out = {}
  for _, l in pairs(self.listeners) do
    out[#out + 1] = {
      source_id = l.source.id,
      label = l.source.label,
      device_id = l.device_id,
      device_label = l.device_label,
      room_id = l.room_id,
      room_label = l.room_label,
      variable = l.variable_name,
      value = l.value,
      value_type = l.vtype,
      known = l.known == true or (l.vtype ~= "unknown" and l.vtype ~= "excluded"),
      observed_at = l.observed_at,
    }
  end
  table.sort(out, function(a, b)
    return a.source_id < b.source_id
  end)
  return out
end

function Recorder:listenerCount()
  local n = 0
  for _ in pairs(self.listeners) do
    n = n + 1
  end
  return n
end

return M
