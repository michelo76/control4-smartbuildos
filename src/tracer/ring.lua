--- Flight Recorder local history — bounded ring of entries (pure): the
--- device events the capture engine sees and the notes the driver adds.
---
--- The local answer to "what happened just before?" when the controller has
--- no uplink and the dealer has no Composer session: the newest `capacity`
--- entries, O(1) push, oldest evicted first, with a monotonic sequence so a
--- reader can ask for "everything since seq N". Checkpointed to persist by
--- the driver (one key, rate-limited) and restored at start, so a Director
--- restart keeps the recent past; the loss window is the checkpoint interval.

local M = {}

M.LIMITS = { capacity_min = 50, capacity_max = 2000, capacity_default = 500 }

local Ring = {}
Ring.__index = Ring

local function clampCapacity(n)
  n = tonumber(n) or M.LIMITS.capacity_default
  n = math.floor(n)
  if n < M.LIMITS.capacity_min then
    return M.LIMITS.capacity_min
  end
  if n > M.LIMITS.capacity_max then
    return M.LIMITS.capacity_max
  end
  return n
end

function M.new(capacity)
  local self = setmetatable({}, Ring)
  self.capacity = clampCapacity(capacity)
  self.items = {}
  self.head = 0 -- index of the newest item (1..capacity), 0 when empty
  self.size = 0
  self.seq = 0
  self.evicted = 0
  return self
end

--- Appends an entry, stamping `seq`. Returns the sequence number.
function Ring:push(entry)
  self.seq = self.seq + 1
  entry.seq = self.seq
  self.head = (self.head % self.capacity) + 1
  if self.size == self.capacity then
    self.evicted = self.evicted + 1
  else
    self.size = self.size + 1
  end
  self.items[self.head] = entry
  return self.seq
end

--- Iterates newest → oldest.
local function newestFirst(self)
  local i = 0
  return function()
    i = i + 1
    if i > self.size then
      return nil
    end
    local idx = self.head - (i - 1)
    if idx < 1 then
      idx = idx + self.capacity
    end
    return self.items[idx]
  end
end

--- The newest `n` entries in chronological order (oldest first).
function Ring:recent(n)
  n = math.min(tonumber(n) or self.size, self.size)
  local out = {}
  for e in newestFirst(self) do
    if #out >= n then
      break
    end
    out[#out + 1] = e
  end
  local rev = {}
  for i = #out, 1, -1 do
    rev[#rev + 1] = out[i]
  end
  return rev
end

--- The newest `n` entries matching `pred`, chronological.
function Ring:filter(pred, n)
  n = tonumber(n) or self.size
  local out = {}
  for e in newestFirst(self) do
    if #out >= n then
      break
    end
    if pred(e) then
      out[#out + 1] = e
    end
  end
  local rev = {}
  for i = #out, 1, -1 do
    rev[#rev + 1] = out[i]
  end
  return rev
end

function Ring:forDevice(deviceId, n)
  local id = tonumber(deviceId)
  return self:filter(function(e)
    return e.device_id == id
  end, n)
end

--- Entries with seq > `seq`, chronological (bounded by what is still held).
function Ring:since(seq)
  seq = tonumber(seq) or 0
  return self:filter(function(e)
    return e.seq > seq
  end)
end

--- Entries whose time is within `seconds` before (and including) `t`.
function Ring:window(t, seconds)
  local from = (tonumber(t) or 0) - (tonumber(seconds) or 0)
  return self:filter(function(e)
    return e.t ~= nil and e.t >= from and e.t <= t
  end)
end

function Ring:count()
  return self.size
end

function Ring:latest()
  if self.size == 0 then
    return nil
  end
  return self.items[self.head]
end

--- Changes capacity, keeping the newest entries.
function Ring:resize(capacity)
  capacity = clampCapacity(capacity)
  if capacity == self.capacity then
    return
  end
  local keep = self:recent(math.min(self.size, capacity))
  self.capacity = capacity
  self.items = {}
  self.head = 0
  self.size = 0
  for _, e in ipairs(keep) do
    self.head = (self.head % self.capacity) + 1
    self.size = self.size + 1
    self.items[self.head] = e
  end
end

--- Persistable document (oldest first) and restoration.
function Ring:serialize()
  return { v = 1, capacity = self.capacity, seq = self.seq, evicted = self.evicted, entries = self:recent(self.size) }
end

function M.restore(doc, capacity)
  local ring = M.new(capacity or (type(doc) == "table" and doc.capacity) or nil)
  if type(doc) ~= "table" or type(doc.entries) ~= "table" then
    return ring, false
  end
  local maxSeq = 0
  for _, e in ipairs(doc.entries) do
    if type(e) == "table" then
      ring.head = (ring.head % ring.capacity) + 1
      if ring.size == ring.capacity then
        ring.evicted = ring.evicted + 1
      else
        ring.size = ring.size + 1
      end
      ring.items[ring.head] = e
      if tonumber(e.seq) and e.seq > maxSeq then
        maxSeq = e.seq
      end
    end
  end
  ring.seq = math.max(maxSeq, tonumber(doc.seq) or 0)
  ring.evicted = ring.evicted + (tonumber(doc.evicted) or 0)
  return ring, true
end

return M
