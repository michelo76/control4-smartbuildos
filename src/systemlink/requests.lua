--- Named remote routines with correlated results, and one-time events.
---
--- Pure module. A *request* is "please run routine R and tell me how it
--- went"; the dealer's Composer programming decides what completion means
--- and reports it explicitly. A *slot* is the bounded Composer context: the
--- driver exposes N request slots as variables so programming can read the
--- id, routine and status of the request it is reacting to without a single
--- global "last result" misattributing outcomes between concurrent requests.
---
--- Status machine (spec §18):
---   accepted → delivered → running → completed | failed
---   any non-final → expired    (deadline passed without a final report)
---   expired + late final report → recorded as `late`, status stays expired
---   unknown: a final outcome the originator can never learn (peer crashed
---   after running, link revoked mid-flight). It is never upgraded by guess.

local M = {}

M.STATUS = {
  ACCEPTED = "accepted",
  DELIVERED = "delivered",
  RUNNING = "running",
  COMPLETED = "completed",
  FAILED = "failed",
  EXPIRED = "expired",
  UNKNOWN = "unknown",
}

local FINAL = { completed = true, failed = true, expired = true, unknown = true }
M.FINAL = FINAL

local NEXT = {
  accepted = { delivered = true, running = true, completed = true, failed = true, expired = true, unknown = true },
  delivered = { running = true, completed = true, failed = true, expired = true, unknown = true },
  running = { completed = true, failed = true, expired = true, unknown = true },
}

M.DEFAULT_SLOTS = 8
M.MAX_SLOTS = 32
M.DEFAULT_DEADLINE_S = 120
M.MAX_DEADLINE_S = 3600
M.HISTORY = 50

--- @param slots number of concurrent in-flight requests this side can hold
function M.newRegistry(slots)
  slots = math.max(1, math.min(M.MAX_SLOTS, slots or M.DEFAULT_SLOTS))
  local r = { slots = {}, by_id = {}, history = {}, slot_count = slots }
  for i = 1, slots do
    r.slots[i] = false
  end
  return r
end

local function freeSlot(reg)
  for i = 1, reg.slot_count do
    if reg.slots[i] == false then
      return i
    end
  end
  return nil
end

--- Opens a request on the ORIGINATING side (outbound) or records one received
--- from the peer (inbound). Both occupy a slot: outbound so programming can
--- react to the result, inbound so programming can report it.
--- @param reg table
--- @param req { id, routine, direction = "out"|"in", payload, deadline_ms, origin_ep }
--- @param nowMs number local monotonic-ish clock
--- @return table|nil request, string|nil err
function M.open(reg, req, nowMs)
  if type(req.id) ~= "string" or req.id == "" or type(req.routine) ~= "string" or req.routine == "" then
    return nil, "invalid request"
  end
  if reg.by_id[req.id] then
    return nil, "duplicate request id"
  end
  local slot = freeSlot(reg)
  if not slot then
    return nil, "no free request slot"
  end
  local deadline = req.deadline_ms
  if deadline == nil then
    deadline = nowMs + M.DEFAULT_DEADLINE_S * 1000
  end
  local entry = {
    id = req.id,
    routine = req.routine,
    direction = req.direction or "out",
    payload = req.payload,
    origin_ep = req.origin_ep,
    status = M.STATUS.ACCEPTED,
    opened_at = nowMs,
    deadline_at = deadline,
    updated_at = nowMs,
    slot = slot,
    result = nil,
    late = false,
  }
  reg.slots[slot] = entry
  reg.by_id[entry.id] = entry
  return entry
end

local function close(reg, entry, nowMs)
  if entry.slot and reg.slots[entry.slot] == entry then
    reg.slots[entry.slot] = false
  end
  entry.closed_at = nowMs
  table.insert(reg.history, 1, entry)
  while #reg.history > M.HISTORY do
    table.remove(reg.history)
  end
end

--- Applies a status update (from the peer, or from local programming via
--- the Report Request Progress/Success/Failure actions).
--- @return table|nil entry, string|nil err, boolean|nil final  (final=true when the slot was released)
function M.transition(reg, id, status, result, nowMs)
  local entry = reg.by_id[id]
  if not entry then
    -- Unknown id: either never ours, or already aged out of history. A
    -- late result for a forgotten request must not open anything.
    return nil, "unknown request"
  end
  if FINAL[entry.status] then
    if entry.status == M.STATUS.EXPIRED and (status == M.STATUS.COMPLETED or status == M.STATUS.FAILED) then
      entry.late = true
      entry.late_status = status
      entry.late_result = result
      entry.updated_at = nowMs
      return entry, nil, false
    end
    return nil, "request already final"
  end
  local allowed = NEXT[entry.status]
  if not allowed or not allowed[status] then
    return nil, "illegal transition " .. tostring(entry.status) .. " -> " .. tostring(status)
  end
  entry.status = status
  entry.updated_at = nowMs
  if result ~= nil then
    entry.result = result
  end
  if FINAL[status] then
    close(reg, entry, nowMs)
    return entry, nil, true
  end
  return entry, nil, false
end

--- Expires every non-final request whose deadline has passed. Returns them.
--- A timeout means completion was not confirmed; nothing here guesses that
--- the remote work stopped.
function M.expire(reg, nowMs)
  local expired = {}
  for id, entry in pairs(reg.by_id) do
    if not FINAL[entry.status] and nowMs >= entry.deadline_at then
      entry.status = M.STATUS.EXPIRED
      entry.updated_at = nowMs
      close(reg, entry, nowMs)
      expired[#expired + 1] = entry
    end
  end
  return expired
end

--- Marks every non-final request UNKNOWN (link revoked, generation fenced,
--- peer replaced). Returns them.
function M.abandonAll(reg, nowMs, reason)
  local out = {}
  for _, entry in pairs(reg.by_id) do
    if not FINAL[entry.status] then
      entry.status = M.STATUS.UNKNOWN
      entry.result = { reason = reason }
      entry.updated_at = nowMs
      close(reg, entry, nowMs)
      out[#out + 1] = entry
    end
  end
  return out
end

--- Forgets closed requests older than `ageMs` so ids cannot be replayed
--- forever and the registry stays bounded.
function M.prune(reg, nowMs, ageMs)
  local keep = {}
  for _, entry in ipairs(reg.history) do
    if entry.closed_at and nowMs - entry.closed_at <= ageMs then
      keep[#keep + 1] = entry
    else
      reg.by_id[entry.id] = nil
    end
  end
  reg.history = keep
end

function M.get(reg, id)
  return reg.by_id[id]
end

function M.inFlight(reg)
  local n = 0
  for i = 1, reg.slot_count do
    if reg.slots[i] then
      n = n + 1
    end
  end
  return n
end

-- ── One-time events ─────────────────────────────────────────────────────────

--- Occurrences are separate from variables: repeated presses are repeated
--- occurrences, each with its own id, origin and expiry. Expired occurrences
--- are never replayed. Delivery while the peer is unavailable fails clearly
--- unless the definition opted into bounded queueing.

M.EVENT_DEFAULT_TTL_S = 30
M.EVENT_MAX_TTL_S = 600
M.EVENT_QUEUE_MAX = 20

--- @return table occurrence
function M.newOccurrence(defId, occId, originEp, nowMs, ttlS, payload)
  ttlS = math.max(1, math.min(M.EVENT_MAX_TTL_S, ttlS or M.EVENT_DEFAULT_TTL_S))
  return {
    def = defId,
    id = occId,
    origin = originEp,
    created_at = nowMs,
    ttl_s = ttlS,
    payload = payload,
    delivery = "pending",
  }
end

--- Outbound queue policy. `queueable` comes from the event definition.
--- @return "send" | "queue" | "fail"
function M.outboundPolicy(peerOnline, queueable, queueLen)
  if peerOnline then
    return "send"
  end
  if queueable and queueLen < M.EVENT_QUEUE_MAX then
    return "queue"
  end
  return "fail"
end

--- Inbound classification against relay-stamped expiry and the dedup ring.
--- @return "deliver" | "expired" | "duplicate"
function M.inboundPolicy(env, relayNowMs, dedup, protocol)
  if protocol.isExpired(env, relayNowMs) then
    return "expired"
  end
  if not dedup:accept(env.id) then
    return "duplicate"
  end
  return "deliver"
end

return M
