--- A bounded, batching queue for general telemetry (Phase 2, T-2.1/T-2.2).
---
--- ── WHY BOUNDED, AND BOUNDED HOW ────────────────────────────────────────────
---
--- Internet outages are exactly when telemetry matters and exactly when it
--- cannot be shipped, so events queue locally — but Director runs the house,
--- and an unbounded queue is a slow-motion crash on somebody's wall. Three
--- caps, all from the plan's stated driver budget (§P):
---
---   maxItems  500   drop-OLDEST beyond it. The newest events describe the
---                   house as it is now; when something must go, it is the
---                   stalest view of the past.
---   maxAge    24h   an event older than a day is history, and history is the
---                   platform's job. Pruned on add and on take.
---   maxBatch  200   per upload, so a fat backlog drains in bites the ingest
---                   cap (500) always accepts.
---
--- Drops are COUNTED, never silent: `dropped()` feeds the heartbeat's
--- diagnostics, because a queue that sheds data invisibly is how a gap in a
--- report becomes "the system was quiet" instead of "the queue overflowed".
---
--- ── IDEMPOTENCY ─────────────────────────────────────────────────────────────
---
--- Every event carries `idempotency_key = "<prefix>:<seq>"`. The seq survives
--- driver reloads via the injected persist functions — a reload that reset it
--- to 1 would mint keys the platform has already seen and silently swallow the
--- first N real events after every update.
---
--- Pure: no C4 calls, no globals, injected clocks and persistence. Same
--- discipline as rooms.lua, for the same reason — every rule here decides
--- whether a number a client sees is real.

local Queue = {}
Queue.__index = Queue

--- @param opts table:
---   now        fun(): number   epoch seconds
---   wallClock  fun(): string   ISO timestamp for occurred_at
---   keyPrefix  string          stable per pairing (e.g. token prefix)
---   loadSeq    fun(): number|nil     persisted sequence, if any
---   saveSeq    fun(seq: number)      persist the sequence
---   maxItems   number|nil      default 500
---   maxAgeSeconds number|nil   default 86400
---   maxBatch   number|nil      default 200
function Queue.new(opts)
  local self = setmetatable({}, Queue)
  self.now = opts.now
  self.wallClock = opts.wallClock
  self.keyPrefix = tostring(opts.keyPrefix or "c4")
  self.saveSeq = opts.saveSeq or function() end
  self.seq = tonumber(opts.loadSeq and opts.loadSeq() or nil) or 0
  self.maxItems = opts.maxItems or 500
  self.maxAgeSeconds = opts.maxAgeSeconds or 24 * 60 * 60
  self.maxBatch = opts.maxBatch or 200
  self.items = {}
  self._dropped = 0
  return self
end

--- Removes items older than maxAge. Internal; runs on add and take.
function Queue:_prune()
  local cutoff = self.now() - self.maxAgeSeconds
  local kept = {}
  for _, item in ipairs(self.items) do
    if item._at >= cutoff then
      kept[#kept + 1] = item
    else
      self._dropped = self._dropped + 1
    end
  end
  self.items = kept
end

--- Queues one event. `fields` is the platform shape minus the stamps this
--- adds (occurred_at, idempotency_key). Category is REQUIRED — the ingest
--- drops unknown categories rather than laundering them, so an event without
--- one would travel just to be discarded.
--- @return boolean queued
function Queue:add(category, fields)
  if type(category) ~= "string" or category == "" then
    return false
  end
  self:_prune()

  self.seq = self.seq + 1
  self.saveSeq(self.seq)

  local event = {}
  for k, v in pairs(fields or {}) do
    event[k] = v
  end
  event.category = category
  event.occurred_at = self.wallClock()
  event.idempotency_key = self.keyPrefix .. ":" .. self.seq
  event._at = self.now()

  self.items[#self.items + 1] = event

  -- Drop-oldest: the queue holds the freshest maxItems view of the house.
  while #self.items > self.maxItems do
    table.remove(self.items, 1)
    self._dropped = self._dropped + 1
  end
  return true
end

--- Takes up to maxBatch events for upload, REMOVING them — a successful send
--- must not be able to send them twice. The transport-private `_at` stamp is
--- stripped here so it never leaks into a payload.
--- @return table[] batch Shaped for the wire, oldest first.
function Queue:takeBatch()
  self:_prune()
  local batch = {}
  local n = math.min(self.maxBatch, #self.items)
  for _ = 1, n do
    local item = table.remove(self.items, 1)
    item._at = nil
    batch[#batch + 1] = item
  end
  return batch
end

--- Returns a failed batch to the FRONT, preserving order — the same contract
--- as rooms.lua's takeSessions: an upload failure must not delete an evening.
--- Items pushed back count against the cap; if the queue refilled meanwhile,
--- the OLDEST of the returned items give way first, same policy as add.
function Queue:putBack(batch)
  if type(batch) ~= "table" or #batch == 0 then
    return
  end
  local merged = {}
  for _, item in ipairs(batch) do
    if item._at == nil then
      item._at = self.now()
    end
    merged[#merged + 1] = item
  end
  for _, item in ipairs(self.items) do
    merged[#merged + 1] = item
  end
  self.items = merged
  while #self.items > self.maxItems do
    table.remove(self.items, 1)
    self._dropped = self._dropped + 1
  end
end

--- @return number queued Current depth, for the heartbeat.
function Queue:depth()
  return #self.items
end

--- @return number dropped Events shed since load, for diagnostics.
function Queue:dropped()
  return self._dropped
end

return Queue
