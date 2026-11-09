--- Event Tracer — the capture engine (pure, injected Director surface).
---
--- Subscribes to EVERY Composer event of EVERY device in the project that
--- the catalogue knows (tracer.catalog), and turns Director's
--- `OnDeviceEvent(firingDeviceId, eventId)` into timeline entries: a local
--- ring (what happened just before, with no uplink and no Composer) and
--- `capture.event` envelopes for the SmartBuildOS pipeline.
---
--- Rules a technician relies on:
---
---   • ZERO CONFIGURATION. The policy says what NOT to capture (excluded
---     devices or driver files) and the resource bounds; everything else in
---     the project is captured as soon as the driver is added.
---   • RECONCILIATION. apply() computes the desired (device, event) set and
---     registers/unregisters only the difference; an identical re-apply
---     touches nothing. A project change re-applies.
---   • ATTRIBUTION IS NOT CLAIMED. Director does not tell a driver which
---     programming ran. An entry says WHICH device fired WHICH event WHEN;
---     the "why" is the sequence of entries around it, which is what the
---     timeline shows. Nothing here guesses a cause.
---   • STORMS. The same event from the same device `storm_threshold` times
---     within a minute is a storm: one `tracer.storm` warning, then that key
---     is SUPPRESSED (counted, not recorded) until the minute rolls, when a
---     `tracer.storm_ended` carries the totals. A chattering contact cannot
---     flood the ring or the uplink, and the storm itself IS the finding.
---   • BUDGET. Envelopes beyond `events_per_minute` are dropped and counted,
---     with one `tracer.budget_exceeded` per minute. The local ring is NOT
---     budgeted (it is bounded by size instead), so Print Recent Events can
---     show what the uplink did not get.
---   • SUBSCRIPTION CAP. Devices are covered in ascending id order until
---     `max_subscriptions`; what did not fit is counted per device and
---     reported, never silently skipped.
---   • LEARNING. An event that arrives on a probe subscription (an id the
---     catalogue did not list) is learned and persisted by the driver, so
---     the next apply subscribes to it by name "Event <id>" without probing.
---   • SELF. The tracer's own device is never subscribed (its "Storm
---     Detected" Composer event would record itself).
---
--- No callback does blocking work: a device event is a few table writes, a
--- ring push and a function call into the module client's staging buffer.

local Ring = require("tracer.ring")

local M = {}

M.LIMITS = {
  subscriptions_ceiling = 2500,
  subscriptions_default = 1000,
  events_per_minute_ceiling = 1200,
  events_per_minute_default = 300,
  storm_threshold_ceiling = 600,
  storm_threshold_default = 30,
  probe_range_ceiling = 64,
  probe_range_default = 32,
  exclusions = 200,
  ring_default = Ring.LIMITS.capacity_default,
}

M.WINDOW_SECONDS = 60

function M.defaultPolicy()
  return {
    enabled = true,
    exclude_device_ids = {},
    exclude_driver_files = {},
    probe_unknown = false,
    probe_range = M.LIMITS.probe_range_default,
    max_subscriptions = M.LIMITS.subscriptions_default,
    events_per_minute = M.LIMITS.events_per_minute_default,
    storm_threshold = M.LIMITS.storm_threshold_default,
    ring_size = M.LIMITS.ring_default,
  }
end

local function refusal(path, reason)
  return { path = path, reason = reason }
end

local function boundedInt(value, path, min, max, refusals, default)
  if value == nil or value == "" then
    return default
  end
  local n = tonumber(value)
  if n == nil or n ~= math.floor(n) or n < min or n > max then
    refusals[#refusals + 1] = refusal(path, string.format("must be an integer %d..%d", min, max))
    return default
  end
  return n
end

local function boolean(value, path, refusals, default)
  if value == nil or value == "" then
    return default
  end
  if type(value) == "boolean" then
    return value
  end
  local s = tostring(value):lower()
  if s == "true" or s == "on" or s == "yes" or s == "1" then
    return true
  elseif s == "false" or s == "off" or s == "no" or s == "0" then
    return false
  end
  refusals[#refusals + 1] = refusal(path, "must be a boolean")
  return default
end

--- A list from a Lua array or a comma/semicolon/newline separated string.
local function list(value)
  local out = {}
  if type(value) == "table" then
    for _, v in ipairs(value) do
      local s = tostring(v):gsub("^%s+", ""):gsub("%s+$", "")
      if s ~= "" then
        out[#out + 1] = s
      end
    end
  elseif type(value) == "string" then
    for s in value:gmatch("[^,;\n]+") do
      s = s:gsub("^%s+", ""):gsub("%s+$", "")
      if s ~= "" then
        out[#out + 1] = s
      end
    end
  end
  return out
end

--- Validates a policy. Invalid FIELDS fall back to their defaults and are
--- listed; only a non-table document is refused outright (nil). The policy
--- is driven by Composer properties, where a typo must not stop capture.
--- @return table|nil policy, table refusals
function M.validatePolicy(raw)
  local refusals = {}
  if type(raw) ~= "table" then
    return nil, { refusal("policy", "must be an object") }
  end
  local out = M.defaultPolicy()
  out.enabled = boolean(raw.enabled, "enabled", refusals, true)
  out.probe_unknown = boolean(raw.probe_unknown, "probe_unknown", refusals, false)
  out.probe_range =
    boundedInt(raw.probe_range, "probe_range", 1, M.LIMITS.probe_range_ceiling, refusals, out.probe_range)
  out.max_subscriptions = boundedInt(
    raw.max_subscriptions,
    "max_subscriptions",
    1,
    M.LIMITS.subscriptions_ceiling,
    refusals,
    out.max_subscriptions
  )
  out.events_per_minute = boundedInt(
    raw.events_per_minute,
    "events_per_minute",
    1,
    M.LIMITS.events_per_minute_ceiling,
    refusals,
    out.events_per_minute
  )
  out.storm_threshold = boundedInt(
    raw.storm_threshold,
    "storm_threshold",
    0,
    M.LIMITS.storm_threshold_ceiling,
    refusals,
    out.storm_threshold
  )
  out.ring_size =
    boundedInt(raw.ring_size, "ring_size", Ring.LIMITS.capacity_min, Ring.LIMITS.capacity_max, refusals, out.ring_size)
  local ids = {}
  for _, s in ipairs(list(raw.exclude_device_ids)) do
    local n = tonumber(s)
    if n == nil then
      refusals[#refusals + 1] = refusal("exclude_device_ids", "not a device id: " .. s)
    elseif #ids < M.LIMITS.exclusions then
      ids[#ids + 1] = n
    end
  end
  out.exclude_device_ids = ids
  local files = {}
  for _, s in ipairs(list(raw.exclude_driver_files)) do
    if #files < M.LIMITS.exclusions then
      files[#files + 1] = s
    end
  end
  out.exclude_driver_files = files
  return out, refusals
end

--- The policy as a `tracer.applied` event reports it, so System Studio can
--- show what is running without a second channel. Bounded for the envelope:
--- exclusion lists are cut to REPORT_EXCLUSIONS entries and the totals say
--- how many there really are (Studio then leaves a cut list alone).
M.REPORT_EXCLUSIONS = 30

function M.policyReport(policy)
  local function head(list, n, map)
    local out = {}
    for i = 1, math.min(#list, n) do
      out[i] = map(list[i])
    end
    return out
  end
  return {
    enabled = policy.enabled,
    probe_unknown = policy.probe_unknown,
    probe_range = policy.probe_range,
    max_subscriptions = policy.max_subscriptions,
    events_per_minute = policy.events_per_minute,
    storm_threshold = policy.storm_threshold,
    ring_size = policy.ring_size,
    exclude_device_ids = head(policy.exclude_device_ids, M.REPORT_EXCLUSIONS, function(v)
      return v
    end),
    exclude_device_ids_total = #policy.exclude_device_ids,
    exclude_driver_files = head(policy.exclude_driver_files, M.REPORT_EXCLUSIONS, function(v)
      return tostring(v):sub(1, 60)
    end),
    exclude_driver_files_total = #policy.exclude_driver_files,
  }
end

local Tracer = {}
Tracer.__index = Tracer

local function skey(deviceId, eventId)
  return tostring(deviceId) .. ":" .. tostring(eventId)
end

--- @param deps table {
---   now = fun():number (seconds, fractions allowed),
---   register = fun(deviceId, eventId):boolean, unregister = fun(deviceId, eventId),
---   devices = fun():table  -- C4:GetDevices shape: { [id] = { deviceName, driverFileName, roomId, roomName } }
---   catalog = tracer.catalog instance,
---   emit = fun(fields),
---   selfDeviceId = number|nil,
---   projectXml = fun():string|nil  -- optional PROBE: the unlimited GetProjectItems
---   ring = Ring|nil  -- a restored ring, else a fresh one of policy.ring_size
---   onLearned = fun()  -- optional: the catalogue's learned tier changed (persist it)
--- }
function M.new(deps)
  local self = setmetatable({}, Tracer)
  self.deps = deps
  self.policy = M.defaultPolicy()
  self.subs = {} -- "dev:ev" -> subscription
  self.coverage = {} -- device_id -> { label, driver, tier, events, unsubscribed }
  self.storms = {} -- "dev:ev" -> { start, count, storming, suppressed }
  self.ring = deps.ring or Ring.new(self.policy.ring_size)
  self.paused = false
  self.summary = nil
  self.counters = {
    captured = 0,
    emitted = 0,
    dropped_budget = 0,
    storms = 0,
    storm_suppressed = 0,
    learned = 0,
    marks = 0,
    unexpected = 0,
    subscriptions = 0,
    register_failures = 0,
    devices_covered = 0,
    devices_unknown = 0,
  }
  self.minute = { start = deps.now(), count = 0, warned = false }
  return self
end

-- ── Emission ─────────────────────────────────────────────────────────────────

function Tracer:_budgetAllows()
  local now = self.deps.now()
  if now - self.minute.start >= M.WINDOW_SECONDS then
    self.minute = { start = now, count = 0, warned = false }
  end
  if self.minute.count >= self.policy.events_per_minute then
    self.counters.dropped_budget = self.counters.dropped_budget + 1
    if not self.minute.warned then
      self.minute.warned = true
      self.deps.emit({
        event_type = "tracer.budget_exceeded",
        evidence_source = "derived",
        severity = "warning",
        label = "Capture upload budget exceeded",
        payload = {
          events_per_minute = self.policy.events_per_minute,
          dropped_so_far = self.counters.dropped_budget,
          note = "events beyond the per-minute budget were not uploaded; the local ring still holds them",
        },
      })
    end
    return false
  end
  self.minute.count = self.minute.count + 1
  return true
end

function Tracer:_emit(fields)
  if not self:_budgetAllows() then
    return false
  end
  self.counters.emitted = self.counters.emitted + 1
  self.deps.emit(fields)
  return true
end

-- ── Storms ───────────────────────────────────────────────────────────────────

function Tracer:_stormEnded(key, s)
  local sub = self.subs[key]
  self.deps.emit({
    event_type = "tracer.storm_ended",
    evidence_source = "derived",
    severity = "notice",
    device_id = sub and sub.device_id or nil,
    room_id = sub and sub.room_id or nil,
    label = string.format("Storm ended: %s", sub and (sub.device_label .. ": " .. sub.name) or key),
    payload = {
      device_label = sub and sub.device_label or nil,
      event_id = sub and sub.event_id or nil,
      event_name = sub and sub.name or nil,
      count = s.count,
      suppressed = s.suppressed,
      window_seconds = M.WINDOW_SECONDS,
    },
  })
end

--- @return "ok"|"start"|"suppress"
function Tracer:_storm(key, now)
  local threshold = self.policy.storm_threshold
  if threshold <= 0 then
    return "ok"
  end
  local s = self.storms[key]
  if s == nil then
    s = { start = now, count = 0, storming = false, suppressed = 0 }
    self.storms[key] = s
  elseif now - s.start >= M.WINDOW_SECONDS then
    if s.storming then
      self:_stormEnded(key, s)
    end
    s.start, s.count, s.storming, s.suppressed = now, 0, false, 0
  end
  s.count = s.count + 1
  if s.storming then
    s.suppressed = s.suppressed + 1
    return "suppress"
  end
  if s.count >= threshold then
    s.storming = true
    self.counters.storms = self.counters.storms + 1
    return "start"
  end
  return "ok"
end

--- Periodic: closes storms whose minute has passed with no further event
--- (otherwise the end is only noticed on the next event), and forgets idle
--- storm bookkeeping.
function Tracer:tick()
  local now = self.deps.now()
  for key, s in pairs(self.storms) do
    if now - s.start >= M.WINDOW_SECONDS then
      if s.storming then
        self:_stormEnded(key, s)
      end
      self.storms[key] = nil
    end
  end
end

-- ── Capture ──────────────────────────────────────────────────────────────────

--- Director's callback. Returns true when the event was one we subscribed to.
function Tracer:onDeviceEvent(deviceId, eventId)
  local key = skey(deviceId, eventId)
  local sub = self.subs[key]
  if sub == nil then
    self.counters.unexpected = self.counters.unexpected + 1
    return false
  end
  if self.paused then
    return true
  end
  local now = self.deps.now()
  if not sub.known and (sub.tier == "probe" or sub.tier == "learned") then
    if self.deps.catalog:learn(sub.driver, sub.event_id) then
      self.counters.learned = self.counters.learned + 1
      sub.tier = "learned"
      if self.deps.onLearned then
        pcall(self.deps.onLearned)
      end
      self:_emit({
        event_type = "tracer.learned",
        evidence_source = "derived",
        severity = "info",
        device_id = sub.device_id,
        label = string.format("Learned event %d of %s", sub.event_id, tostring(sub.driver)),
        payload = { driver = sub.driver, event_id = sub.event_id, device_label = sub.device_label },
      })
    end
  end
  local storm = self:_storm(key, now)
  if storm == "suppress" then
    self.counters.storm_suppressed = self.counters.storm_suppressed + 1
    return true
  end
  local entry = {
    t = now,
    kind = "event",
    device_id = sub.device_id,
    device_label = sub.device_label,
    room_id = sub.room_id,
    room_label = sub.room_label,
    driver = sub.driver,
    event_id = sub.event_id,
    event_name = sub.name,
    known = sub.known,
  }
  local seq = self.ring:push(entry)
  self.counters.captured = self.counters.captured + 1
  if storm == "start" then
    self:_emit({
      event_type = "tracer.storm",
      evidence_source = "derived",
      severity = "warning",
      device_id = sub.device_id,
      room_id = sub.room_id,
      label = string.format("Event storm: %s: %s", sub.device_label, sub.name),
      payload = {
        device_label = sub.device_label,
        room_label = sub.room_label,
        driver = sub.driver,
        event_id = sub.event_id,
        event_name = sub.name,
        threshold = self.policy.storm_threshold,
        window_seconds = M.WINDOW_SECONDS,
        note = "further occurrences this minute are counted, not recorded",
      },
    })
  end
  self:_emit({
    event_type = "capture.event",
    evidence_source = "observed",
    quality = sub.known and "confirmed" or "unknown",
    severity = "info",
    device_id = sub.device_id,
    room_id = sub.room_id,
    label = (sub.device_label .. ": " .. sub.name):sub(1, 120),
    payload = {
      seq = seq,
      device_label = sub.device_label,
      room_label = sub.room_label,
      driver = sub.driver,
      event_id = sub.event_id,
      event_name = sub.name,
      name_known = sub.known,
      tier = sub.tier,
    },
  })
  return true
end

--- A marker from Composer programming: a labelled point in the timeline.
function Tracer:mark(name, detail, deviceId)
  name = tostring(name or ""):gsub("^%s+", ""):gsub("%s+$", ""):sub(1, 120)
  if name == "" then
    return false
  end
  local now = self.deps.now()
  local entry = {
    t = now,
    kind = "mark",
    device_id = tonumber(deviceId),
    event_name = name,
    detail = tostring(detail or ""):sub(1, 400),
    known = true,
  }
  local seq = self.ring:push(entry)
  self.counters.marks = self.counters.marks + 1
  self:_emit({
    event_type = "capture.mark",
    evidence_source = "instrumented",
    quality = "unreviewed_text",
    severity = "notice",
    device_id = tonumber(deviceId),
    label = name,
    payload = { seq = seq, name = name, detail = entry.detail, note = "placed by Composer programming" },
  })
  return true
end

-- ── Subscriptions ────────────────────────────────────────────────────────────

function Tracer:_unsubscribe(key)
  local sub = self.subs[key]
  if sub == nil then
    return
  end
  pcall(self.deps.unregister, sub.device_id, sub.event_id)
  self.subs[key] = nil
  self.storms[key] = nil
end

local function sortedIds(devices)
  local ids = {}
  for rawId, d in pairs(devices or {}) do
    local id = tonumber(rawId)
    if id ~= nil and type(d) == "table" then
      ids[#ids + 1] = id
    end
  end
  table.sort(ids)
  return ids
end

--- Computes the desired subscription set for a policy and the current
--- project. Pure given the device list and catalogue.
function Tracer:_plan(policy)
  local devices = self.deps.devices() or {}
  local excludedIds, excludedFiles = {}, {}
  for _, id in ipairs(policy.exclude_device_ids) do
    excludedIds[id] = true
  end
  for _, f in ipairs(policy.exclude_driver_files) do
    excludedFiles[f] = true
  end
  if self.deps.projectXml ~= nil then
    -- Re-read on every plan so a stale project tier never outlives the
    -- project it described; nil clears it and the other tiers take over.
    local ok, xml = pcall(self.deps.projectXml)
    self.deps.catalog:loadProjectXml(ok and type(xml) == "string" and xml or nil)
  end
  local desired, coverage = {}, {}
  local summary = {
    devices_total = 0,
    devices_covered = 0,
    devices_unknown = 0,
    devices_excluded = 0,
    devices_partial = 0,
    subscriptions = 0,
    unsubscribed_events = 0,
    by_tier = { project = 0, builtin = 0, learned = 0, probe = 0 },
    probe_unknown = policy.probe_unknown,
    probe_range = policy.probe_range,
    max_subscriptions = policy.max_subscriptions,
  }
  local count = 0
  for _, id in ipairs(sortedIds(devices)) do
    local d = devices[id] or devices[tostring(id)]
    local driver = tostring(d.driverFileName or "")
    summary.devices_total = summary.devices_total + 1
    if id == self.deps.selfDeviceId or excludedIds[id] or excludedFiles[driver] then
      summary.devices_excluded = summary.devices_excluded + 1
    else
      local events, tier = self.deps.catalog:eventsFor(id, driver)
      if next(events) == nil and policy.probe_unknown then
        tier = "probe"
        for eid = 1, policy.probe_range do
          events[eid] = { name = "Event " .. eid, known = false }
        end
      end
      if next(events) == nil then
        summary.devices_unknown = summary.devices_unknown + 1
        coverage[id] = { label = d.deviceName, driver = driver, tier = nil, events = 0, unsubscribed = 0 }
      else
        local cov = { label = d.deviceName, driver = driver, tier = tier, events = 0, unsubscribed = 0 }
        local eids = {}
        for eid in pairs(events) do
          eids[#eids + 1] = eid
        end
        table.sort(eids)
        for _, eid in ipairs(eids) do
          if count < policy.max_subscriptions then
            count = count + 1
            cov.events = cov.events + 1
            summary.by_tier[tier] = (summary.by_tier[tier] or 0) + 1
            desired[skey(id, eid)] = {
              device_id = id,
              event_id = eid,
              name = events[eid].name,
              known = events[eid].known,
              tier = tier,
              driver = driver,
              device_label = tostring(d.deviceName or ("Device " .. id)),
              room_id = tonumber(d.roomId),
              room_label = d.roomName,
            }
          else
            cov.unsubscribed = cov.unsubscribed + 1
            summary.unsubscribed_events = summary.unsubscribed_events + 1
          end
        end
        if cov.events > 0 then
          summary.devices_covered = summary.devices_covered + 1
        end
        if cov.unsubscribed > 0 then
          summary.devices_partial = summary.devices_partial + 1
        end
        coverage[id] = cov
      end
    end
  end
  summary.subscriptions = count
  return desired, coverage, summary
end

--- Applies a validated policy: reconciles subscriptions against the current
--- project and reports the coverage. Returns the summary.
function Tracer:apply(policy)
  self.policy = policy
  if self.ring.capacity ~= policy.ring_size then
    self.ring:resize(policy.ring_size)
  end
  local desired, coverage, summary = {}, {}, nil
  if policy.enabled and not self.paused then
    desired, coverage, summary = self:_plan(policy)
  else
    summary =
      { devices_total = 0, subscriptions = 0, by_tier = {}, disabled = not policy.enabled, paused = self.paused }
  end
  local removed = 0
  for key in pairs(self.subs) do
    if desired[key] == nil then
      self:_unsubscribe(key)
      removed = removed + 1
    end
  end
  local added, failures = 0, 0
  for key, want in pairs(desired) do
    local existing = self.subs[key]
    if existing ~= nil then
      existing.name, existing.known, existing.tier = want.name, want.known, want.tier
      existing.device_label, existing.room_id, existing.room_label = want.device_label, want.room_id, want.room_label
    else
      local ok, result = pcall(self.deps.register, want.device_id, want.event_id)
      if ok and result ~= false then
        self.subs[key] = want
        added = added + 1
      else
        failures = failures + 1
      end
    end
  end
  self.coverage = coverage
  local n = 0
  for _ in pairs(self.subs) do
    n = n + 1
  end
  self.counters.subscriptions = n
  self.counters.register_failures = self.counters.register_failures + failures
  self.counters.devices_covered = summary.devices_covered or 0
  self.counters.devices_unknown = summary.devices_unknown or 0
  summary.added, summary.removed, summary.register_failures = added, removed, failures
  summary.catalog = self.deps.catalog:counts()
  summary.policy = M.policyReport(self.policy)
  self.summary = summary
  self.deps.emit({
    event_type = "tracer.applied",
    evidence_source = "derived",
    severity = "info",
    label = string.format("Capture applied: %d subscriptions on %d devices", n, summary.devices_covered or 0),
    payload = summary,
  })
  return summary
end

--- A project change (device added/removed/renamed): same policy, new plan.
function Tracer:onProjectChanged()
  if self.paused or not self.policy.enabled then
    return nil
  end
  return self:apply(self.policy)
end

function Tracer:pause(reason)
  if self.paused then
    return false
  end
  self.paused = true
  for key in pairs(self.subs) do
    self:_unsubscribe(key)
  end
  self.counters.subscriptions = 0
  self.deps.emit({
    event_type = "tracer.paused",
    evidence_source = "derived",
    severity = "notice",
    label = "Capture paused",
    payload = { reason = tostring(reason or "") },
  })
  return true
end

function Tracer:resume(reason)
  if not self.paused then
    return false
  end
  self.paused = false
  self.deps.emit({
    event_type = "tracer.resumed",
    evidence_source = "derived",
    severity = "notice",
    label = "Capture resumed",
    payload = { reason = tostring(reason or ""), note = "what fired while paused is not known" },
  })
  self:apply(self.policy)
  return true
end

--- Removal / reload: every subscription goes.
function Tracer:stop()
  for key in pairs(self.subs) do
    self:_unsubscribe(key)
  end
  self.counters.subscriptions = 0
end

-- ── Views ────────────────────────────────────────────────────────────────────

function Tracer:status()
  if self.paused then
    return "paused"
  end
  if not self.policy.enabled then
    return "disabled"
  end
  if self.counters.subscriptions > 0 then
    return "capturing"
  end
  return "idle"
end

function Tracer:subscriptionCount()
  return self.counters.subscriptions
end

function Tracer:recent(n)
  return self.ring:recent(n)
end

function Tracer:forDevice(deviceId, n)
  return self.ring:forDevice(deviceId, n)
end

function Tracer:latest()
  return self.ring:latest()
end

--- Per-device coverage, sorted by device id.
function Tracer:coverageList()
  local out = {}
  for id, c in pairs(self.coverage) do
    out[#out + 1] = {
      device_id = id,
      label = c.label,
      driver = c.driver,
      tier = c.tier,
      events = c.events,
      unsubscribed = c.unsubscribed,
    }
  end
  table.sort(out, function(a, b)
    return a.device_id < b.device_id
  end)
  return out
end

--- Active storms right now (for Print Status and snapshots).
function Tracer:activeStorms()
  local out = {}
  for key, s in pairs(self.storms) do
    if s.storming then
      local sub = self.subs[key]
      out[#out + 1] = {
        device_id = sub and sub.device_id or nil,
        device_label = sub and sub.device_label or nil,
        event_name = sub and sub.name or key,
        count = s.count,
        suppressed = s.suppressed,
      }
    end
  end
  table.sort(out, function(a, b)
    return (a.count or 0) > (b.count or 0)
  end)
  return out
end

--- One line per entry for Director's log.
function M.formatEntry(e)
  local when = e.t and os.date("%H:%M:%S", math.floor(e.t)) or "--:--:--"
  if e.kind == "mark" then
    return string.format(
      "%s  #%d  MARK  %s%s",
      when,
      e.seq or 0,
      e.event_name,
      e.detail ~= "" and ("  — " .. e.detail) or ""
    )
  end
  return string.format(
    "%s  #%d  %s%s: %s%s",
    when,
    e.seq or 0,
    e.room_label and (e.room_label .. " / ") or "",
    tostring(e.device_label or e.device_id),
    tostring(e.event_name),
    e.known and "" or " (unnamed)"
  )
end

return M
