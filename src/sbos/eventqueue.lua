--- The Agent's shared, durable, bounded, ACKNOWLEDGED event queue (pure).
---
--- This is the pipeline every optional SmartBuildOS module uploads through.
--- It differs from telemetry.queue (which still carries the legacy telemetry
--- categories) in one semantic that matters: an event leaves this queue only
--- when the SERVER has durably accepted it. takeBatch marks events in flight;
--- ack() removes the accepted ones and the permanently rejected ones; nack()
--- (transport failure or no answer in time) returns them to the front and
--- backs off. A batch that lands late and is resent is deduplicated by the
--- server on event_id — the failure mode is a wasted request, never a lost
--- or doubled event.
---
--- ── BOUNDS (defaults; the platform may lower them per installation) ──────
---   maxItems   2000 events       maxBytes 512 KB (approx JSON)
---   maxBatch    100 per upload   inflightTimeout 90 s
---   backoff     30 s × 2^failures, capped 15 min, ±25 % jitter
---
--- ── EVICTION ───────────────────────────────────────────────────────────────
--- When a push would exceed a bound, the LOWEST-priority, OLDEST event is
--- evicted first (priority: 2 traces/commands/snapshots/recorder status,
--- 1 observation changes, 0 initial observations). Every eviction is counted
--- and recorded as a contiguous (module, instance, boot, from_seq..to_seq)
--- range so Studio can draw the gap instead of a quiet evening. Ranges are
--- themselves bounded (LOSS_RANGES); beyond that only the count grows and the
--- `ranges_truncated` flag is set — the history is never claimed complete.
---
--- ── DURABILITY ─────────────────────────────────────────────────────────────
--- The journal is ONE persist key, written through the injected saveJournal
--- at most every `checkpointSeconds` (30) or every `checkpointEvery` (50)
--- pushes, whichever first, plus on explicit flush (driver destroy). Director
--- persistence is a flash write; one write per high-frequency event would
--- wear it and stall the callback. So: up to 50 events or 30 s of events can
--- be lost on a hard power cut. That window is documented, counted after a
--- restart when the journal's `pushed` counter is behind the per-module
--- sequence the modules report, and surfaced as a gap. A journal that does
--- not decode starts the queue empty and records `journal_recovered`.
---
--- Pure: injected clock, random and persistence; no C4 calls.

local Envelope = require("sbos.envelope")

local Queue = {}
Queue.__index = Queue

local LOSS_RANGES = 64
local JOURNAL_VERSION = 1

local function defaultRandom()
  return math.random()
end

--- @param opts table { now, random?, maxItems?, maxBytes?, maxBatch?, inflightTimeout?,
---   backoffBase?, backoffMax?, checkpointEvery?, checkpointSeconds?, saveJournal?(table) }
function Queue.new(opts)
  local self = setmetatable({}, Queue)
  self.now = opts.now
  self.random = opts.random or defaultRandom
  self.maxItems = opts.maxItems or 2000
  self.maxBytes = opts.maxBytes or 512 * 1024
  self.maxBatch = opts.maxBatch or 100
  self.inflightTimeout = opts.inflightTimeout or 90
  self.backoffBase = opts.backoffBase or 30
  self.backoffMax = opts.backoffMax or 900
  self.checkpointEvery = opts.checkpointEvery or 50
  self.checkpointSeconds = opts.checkpointSeconds or 30
  self.saveJournal = opts.saveJournal or function() end
  self.items = {}
  self.bytes = 0
  self.inflight = nil
  self.failures = 0
  self.backoffUntil = 0
  self.stats = {
    pushed = 0,
    acked = 0,
    dropped = 0,
    dropped_ranges = {},
    ranges_truncated = false,
    rejected_permanent = 0,
    rejected_retryable = 0,
    upload_failures = 0,
    last_ack_at = nil,
    last_error = nil,
    journal_recovered = false,
    journal_saves = 0,
  }
  self._dirty = 0
  self._lastSave = self.now()
  return self
end

--- Rebuilds a queue from a persisted journal. Anything that does not decode
--- as a v1 journal yields an empty queue with journal_recovered = true.
function Queue.restore(journal, opts)
  local q = Queue.new(opts)
  if type(journal) ~= "table" or journal.v ~= JOURNAL_VERSION or type(journal.items) ~= "table" then
    if journal ~= nil then
      q.stats.journal_recovered = true
      q.stats.last_error = "journal unreadable; started empty"
    end
    return q
  end
  for _, item in ipairs(journal.items) do
    if Envelope.validate(item) then
      q.items[#q.items + 1] =
        { env = item, size = Envelope.approxSize(item), at = q.now(), prio = Envelope.priority(item.event_type) }
      q.bytes = q.bytes + q.items[#q.items].size
    else
      q.stats.dropped = q.stats.dropped + 1
      q.stats.journal_recovered = true
    end
  end
  if type(journal.stats) == "table" then
    for _, key in ipairs({ "pushed", "acked", "dropped", "rejected_permanent", "upload_failures" }) do
      q.stats[key] = tonumber(journal.stats[key]) or q.stats[key]
    end
    if type(journal.stats.dropped_ranges) == "table" then
      q.stats.dropped_ranges = journal.stats.dropped_ranges
    end
    q.stats.ranges_truncated = journal.stats.ranges_truncated == true
    q.stats.last_ack_at = journal.stats.last_ack_at
  end
  return q
end

--- The journal document to persist.
function Queue:journal()
  local items = {}
  -- In-flight events are journaled too: a restart mid-upload resends them and
  -- the server dedupes; losing them would be the worse mistake.
  if self.inflight ~= nil then
    for _, it in ipairs(self.inflight.items) do
      items[#items + 1] = it.env
    end
  end
  for _, it in ipairs(self.items) do
    items[#items + 1] = it.env
  end
  return {
    v = JOURNAL_VERSION,
    saved_at = self.now(),
    items = items,
    stats = {
      pushed = self.stats.pushed,
      acked = self.stats.acked,
      dropped = self.stats.dropped,
      dropped_ranges = self.stats.dropped_ranges,
      ranges_truncated = self.stats.ranges_truncated,
      rejected_permanent = self.stats.rejected_permanent,
      upload_failures = self.stats.upload_failures,
      last_ack_at = self.stats.last_ack_at,
    },
  }
end

--- Writes the journal if due (or forced). Returns true when it saved.
function Queue:checkpoint(force)
  if not force then
    if self._dirty == 0 then
      return false
    end
    if self._dirty < self.checkpointEvery and (self.now() - self._lastSave) < self.checkpointSeconds then
      return false
    end
  end
  self.saveJournal(self:journal())
  self._dirty = 0
  self._lastSave = self.now()
  self.stats.journal_saves = self.stats.journal_saves + 1
  return true
end

local function rangeKey(env)
  return tostring(env.module_id)
    .. "|"
    .. tostring(env.source_driver_instance_id)
    .. "|"
    .. tostring(env.boot_id or "nb")
end

--- Records one evicted event as part of a contiguous loss range.
function Queue:_recordLoss(env, reason)
  self.stats.dropped = self.stats.dropped + 1
  local key = rangeKey(env)
  local ranges = self.stats.dropped_ranges
  local last = ranges[#ranges]
  if last ~= nil and last.key == key and last.reason == reason and last.to_seq + 1 == env.sequence then
    last.to_seq = env.sequence
    last.count = last.count + 1
    return
  end
  if #ranges >= LOSS_RANGES then
    self.stats.ranges_truncated = true
    return
  end
  ranges[#ranges + 1] = {
    key = key,
    module_id = env.module_id,
    instance_id = env.source_driver_instance_id,
    boot_id = env.boot_id,
    from_seq = env.sequence,
    to_seq = env.sequence,
    count = 1,
    reason = reason,
    at = self.now(),
  }
end

--- Evicts the lowest-priority, oldest item. Returns false if nothing can go.
function Queue:_evictOne(reason)
  local victim, victimIndex = nil, nil
  for i, it in ipairs(self.items) do
    if victim == nil or it.prio < victim.prio then
      victim, victimIndex = it, i
      if it.prio == 0 then
        break
      end
    end
  end
  if victim == nil then
    return false
  end
  table.remove(self.items, victimIndex)
  self.bytes = self.bytes - victim.size
  self:_recordLoss(victim.env, reason)
  return true
end

--- Queues a validated envelope. Returns true, or false + reason when the
--- event itself is unacceptable (an oversized/invalid event is refused, never
--- evicts others to make room).
function Queue:push(env)
  local ok, reason = Envelope.validate(env)
  if not ok then
    return false, reason
  end
  local size = Envelope.approxSize(env)
  if size > Envelope.LIMITS.frame_bytes then
    return false, "oversized"
  end
  while #self.items + 1 > self.maxItems do
    if not self:_evictOne("capacity_items") then
      break
    end
  end
  while self.bytes + size > self.maxBytes and #self.items > 0 do
    if not self:_evictOne("capacity_bytes") then
      break
    end
  end
  self.items[#self.items + 1] = { env = env, size = size, at = self.now(), prio = Envelope.priority(env.event_type) }
  self.bytes = self.bytes + size
  self.stats.pushed = self.stats.pushed + 1
  self._dirty = self._dirty + 1
  return true
end

--- Whether an upload may start now.
function Queue:canSend()
  if self.inflight ~= nil then
    return false, "inflight"
  end
  if self.now() < self.backoffUntil then
    return false, "backoff"
  end
  if #self.items == 0 then
    return false, "empty"
  end
  return true
end

--- Takes up to maxBatch events (highest priority first, then oldest) and
--- marks them in flight. Returns the envelopes for the wire, or nil + reason.
function Queue:takeBatch()
  local can, why = self:canSend()
  if not can then
    return nil, why
  end
  -- Stable selection: sort a copy of indexes by (prio desc, insertion asc).
  local order = {}
  for i = 1, #self.items do
    order[i] = i
  end
  table.sort(order, function(a, b)
    local ia, ib = self.items[a], self.items[b]
    if ia.prio ~= ib.prio then
      return ia.prio > ib.prio
    end
    return a < b
  end)
  local n = math.min(self.maxBatch, #order)
  local chosen = {}
  for i = 1, n do
    chosen[order[i]] = true
  end
  -- The batch travels in priority order (what the selection chose), the
  -- remainder keeps insertion order.
  local taken, kept, batch = {}, {}, {}
  for i = 1, n do
    local it = self.items[order[i]]
    taken[#taken + 1] = it
    batch[#batch + 1] = it.env
    self.bytes = self.bytes - it.size
  end
  for i, it in ipairs(self.items) do
    if not chosen[i] then
      kept[#kept + 1] = it
    end
  end
  self.items = kept
  self.inflight = { items = taken, at = self.now() }
  return batch
end

--- Returns the in-flight items to the FRONT in their original order.
function Queue:_returnInflight()
  if self.inflight == nil then
    return
  end
  local merged = {}
  for _, it in ipairs(self.inflight.items) do
    merged[#merged + 1] = it
    self.bytes = self.bytes + it.size
  end
  for _, it in ipairs(self.items) do
    merged[#merged + 1] = it
  end
  self.items = merged
  self.inflight = nil
  -- The cap still holds after a return; the oldest low-priority gives way.
  while #self.items > self.maxItems do
    if not self:_evictOne("capacity_items") then
      break
    end
  end
end

--- The server's structured acknowledgment.
--- @param result table { accepted = {event_id...}, rejected = { {event_id, reason, permanent=bool} ... } }
function Queue:ack(result)
  if self.inflight == nil then
    return false, "nothing_inflight"
  end
  result = type(result) == "table" and result or {}
  local accepted = {}
  for _, id in ipairs(result.accepted or {}) do
    accepted[tostring(id)] = true
  end
  local rejected = {}
  for _, r in ipairs(result.rejected or {}) do
    if type(r) == "table" and r.event_id ~= nil then
      rejected[tostring(r.event_id)] = r
    end
  end
  local retry = {}
  for _, it in ipairs(self.inflight.items) do
    local id = it.env.event_id
    if accepted[id] then
      self.stats.acked = self.stats.acked + 1
    elseif rejected[id] ~= nil then
      if rejected[id].permanent == true then
        -- Malformed or policy-rejected: dropping it is the only way the
        -- queue does not wedge on it. Counted and recorded with its reason.
        self.stats.rejected_permanent = self.stats.rejected_permanent + 1
        self:_recordLoss(it.env, "rejected:" .. tostring(rejected[id].reason or "unknown"))
      else
        self.stats.rejected_retryable = self.stats.rejected_retryable + 1
        retry[#retry + 1] = it
      end
    else
      -- Neither accepted nor rejected: an ack that does not mention an event
      -- is not an acceptance. Retry it.
      retry[#retry + 1] = it
    end
  end
  self.inflight = { items = retry, at = self.now() }
  self:_returnInflight()
  self.stats.last_ack_at = self.now()
  self.failures = 0
  self.backoffUntil = 0
  self.stats.last_error = nil
  self._dirty = self._dirty + 1
  return true
end

--- Transport failure / timeout: everything in flight goes back, backoff grows.
function Queue:nack(reason)
  if self.inflight == nil then
    return false
  end
  self:_returnInflight()
  self.failures = self.failures + 1
  self.stats.upload_failures = self.stats.upload_failures + 1
  self.stats.last_error = tostring(reason or "upload failed")
  local delay = math.min(self.backoffBase * (2 ^ (self.failures - 1)), self.backoffMax)
  local jitter = (self.random() * 0.5 - 0.25) * delay
  self.backoffUntil = self.now() + delay + jitter
  return true
end

--- Call from the periodic tick: an in-flight batch older than the timeout is
--- treated as failed (send() is asynchronous and reports nothing on timeout).
function Queue:expireInflight()
  if self.inflight ~= nil and (self.now() - self.inflight.at) > self.inflightTimeout then
    self:nack("ack timeout")
    return true
  end
  return false
end

--- Staggered recovery after a reconnect: clears backoff with a random delay
--- (0..maxStagger s) so a fleet does not hit the server in one wave.
function Queue:resume(maxStagger)
  self.failures = 0
  self.backoffUntil = self.now() + self.random() * (maxStagger or 30)
end

function Queue:depth()
  return #self.items + (self.inflight and #self.inflight.items or 0)
end

function Queue:sizeBytes()
  return self.bytes
    + (function()
      local n = 0
      if self.inflight then
        for _, it in ipairs(self.inflight.items) do
          n = n + it.size
        end
      end
      return n
    end)()
end

--- Age in seconds of the oldest queued event, or 0 when empty.
function Queue:oldestAge()
  local oldest = nil
  if self.inflight then
    for _, it in ipairs(self.inflight.items) do
      if oldest == nil or it.at < oldest then
        oldest = it.at
      end
    end
  end
  for _, it in ipairs(self.items) do
    if oldest == nil or it.at < oldest then
      oldest = it.at
    end
  end
  return oldest and (self.now() - oldest) or 0
end

--- Observability block for the heartbeat.
function Queue:health()
  return {
    depth = self:depth(),
    bytes = self:sizeBytes(),
    oldest_age_seconds = self:oldestAge(),
    inflight = self.inflight and #self.inflight.items or 0,
    pushed = self.stats.pushed,
    acked = self.stats.acked,
    dropped = self.stats.dropped,
    dropped_ranges = self.stats.dropped_ranges,
    ranges_truncated = self.stats.ranges_truncated,
    rejected_permanent = self.stats.rejected_permanent,
    upload_failures = self.stats.upload_failures,
    consecutive_failures = self.failures,
    backoff_seconds = math.max(0, math.floor(self.backoffUntil - self.now())),
    last_ack_at = self.stats.last_ack_at,
    last_error = self.stats.last_error,
    journal_recovered = self.stats.journal_recovered,
    journal_saves = self.stats.journal_saves,
    limits = { max_items = self.maxItems, max_bytes = self.maxBytes, max_batch = self.maxBatch },
    -- Resource-limit status: a one-word verdict Studio can show.
    limit_status = (#self.items >= self.maxItems * 0.9 or self.bytes >= self.maxBytes * 0.9) and "near_limit"
      or (self.stats.dropped > 0 and "lossy" or "ok"),
  }
end

--- Applies platform-set budgets (lower only reduces; raising above the
--- compiled ceiling is refused so a config cannot grow the queue past what
--- the controller was sized for).
function Queue:applyBudget(budget, ceiling)
  budget = type(budget) == "table" and budget or {}
  ceiling = ceiling or { max_items = 2000, max_bytes = 512 * 1024, max_batch = 100 }
  local function pick(value, hard, floor)
    value = tonumber(value)
    if value == nil then
      return nil
    end
    return math.max(floor, math.min(value, hard))
  end
  self.maxItems = pick(budget.max_items, ceiling.max_items, 50) or self.maxItems
  self.maxBytes = pick(budget.max_bytes, ceiling.max_bytes, 16 * 1024) or self.maxBytes
  self.maxBatch = pick(budget.max_batch, ceiling.max_batch, 5) or self.maxBatch
  while #self.items > self.maxItems do
    if not self:_evictOne("budget_lowered") then
      break
    end
  end
end

return Queue
