--- Flight Recorder: the local history served over module contract v2 (pure).
---
--- Another SmartBuildOS module (today only AI Core, by the Agent's
--- MODULE_REQUEST_POLICY) asks the Flight Recorder what its local ring holds:
---
---   events.query           filtered list (kinds, device, room, time, text)
---   events.timeline        everything in a time window, oldest first
---   events.device_history  one device's entries
---   events.room_activity   one room's entries
---
--- What this module will NOT do: correlate, analyse incidents or compare
--- periods (those are cloud-side), or answer for anything outside the ring.
--- Every answer says how far back the ring reaches (`retention`) and whether
--- the requested range reached past what is still held (`truncated`). An
--- entry carries the event id of the envelope it was uploaded as
--- (`event_id`); an entry that never became an envelope (a device event over
--- the per-minute upload budget, or one recorded before ids were kept) says
--- so in `no_event_id` instead of being given an invented one.
---
--- Paging: at most `limit` entries (1..200) and at most ~20 KB per answer
--- (the contract allows 24 KB); the rest is reached with the returned
--- cursor, which carries the history generation so a cursor from before
--- Clear Local History is refused rather than silently misread.
---
--- Pure: the ring (tracer.ring), the clock and the encoder are injected.

local Envelope = require("sbos.envelope")
JSON = JSON or require("JSON")

local M = {}

M.CAPABILITIES = { "events.query", "events.timeline", "events.device_history", "events.room_activity" }

M.LIMITS = {
  limit_default = 50,
  limit_max = 200,
  result_bytes = 20 * 1024, -- page budget (contract cap is 24 KB)
  hard_result_bytes = 24 * 1024 - 256,
  text = 64,
  kinds = 6,
  timeline_default_seconds = 15 * 60,
  window_max_seconds = 31 * 86400,
}

M.KINDS = { event = true, change = true, trace = true, mark = true, system = true, note = true }

--- The words a reader gets about what this history is.
M.POLICY_TEXT = "size-bounded ring of the newest entries on this controller (Local History Size);"
  .. " no age limit; the newest entries since the last checkpoint (up to 30 s) are lost on a power cut;"
  .. " device events over the upload budget are held here but were never uploaded"

local ALLOWED_ARGS = {
  ["events.query"] = {
    limit = true,
    cursor = true,
    order = true,
    from = true,
    to = true,
    since_seq = true,
    kinds = true,
    device_id = true,
    room_id = true,
    text = true,
  },
  ["events.timeline"] = { limit = true, cursor = true, from = true, to = true, kinds = true },
  ["events.device_history"] = { limit = true, cursor = true, order = true, from = true, to = true, device_id = true },
  ["events.room_activity"] = { limit = true, cursor = true, order = true, from = true, to = true, room_id = true },
}

local function isoAt(t)
  if type(t) ~= "number" then
    return nil
  end
  return os.date("!%Y-%m-%dT%H:%M:%SZ", math.floor(t))
end

local function int(v)
  local n = tonumber(v)
  if n == nil or n ~= math.floor(n) then
    return nil
  end
  return n
end

--- Cursor: "h<generation>.<a|d>.<seq>" — the last entry already returned.
function M.encodeCursor(generation, order, seq)
  return string.format("h%d.%s.%d", generation, order == "asc" and "a" or "d", seq)
end

function M.decodeCursor(s)
  if type(s) ~= "string" or #s > 64 then
    return nil
  end
  local gen, dir, seq = s:match("^h(%d+)%.([ad])%.(%d+)$")
  if gen == nil then
    return nil
  end
  return { generation = tonumber(gen), order = dir == "a" and "asc" or "desc", seq = tonumber(seq) }
end

--- Validates args for one capability. Returns the normalised query or
--- nil + a reason (answered as invalid_args).
function M.parse(capability, args, now)
  local allowed = ALLOWED_ARGS[capability]
  if allowed == nil then
    return nil, "capability"
  end
  if type(args) ~= "table" then
    return nil, "args must be an object"
  end
  for k in pairs(args) do
    if not allowed[k] then
      return nil, "unknown argument " .. tostring(k)
    end
  end
  local q = { capability = capability }
  if args.limit ~= nil then
    q.limit = int(args.limit)
    if q.limit == nil or q.limit < 1 or q.limit > M.LIMITS.limit_max then
      return nil, "limit must be 1.." .. M.LIMITS.limit_max
    end
  else
    q.limit = M.LIMITS.limit_default
  end
  q.order = capability == "events.timeline" and "asc" or "desc"
  if args.order ~= nil then
    if args.order ~= "asc" and args.order ~= "desc" then
      return nil, "order must be asc or desc"
    end
    q.order = args.order
  end
  for _, key in ipairs({ "from", "to" }) do
    if args[key] ~= nil then
      local v = tonumber(args[key])
      if v == nil or v < 0 then
        return nil, key .. " must be epoch seconds"
      end
      q[key] = v
    end
  end
  if capability == "events.timeline" then
    q.to = q.to or now
    q.from = q.from or (q.to - M.LIMITS.timeline_default_seconds)
  end
  if q.from ~= nil and q.to ~= nil then
    if q.to < q.from then
      return nil, "to is before from"
    end
    if q.to - q.from > M.LIMITS.window_max_seconds then
      return nil, "window longer than " .. M.LIMITS.window_max_seconds .. " s"
    end
  end
  if args.since_seq ~= nil then
    q.since_seq = int(args.since_seq)
    if q.since_seq == nil or q.since_seq < 0 then
      return nil, "since_seq must be a non-negative integer"
    end
  end
  if args.kinds ~= nil then
    if type(args.kinds) ~= "table" or #args.kinds == 0 or #args.kinds > M.LIMITS.kinds then
      return nil, "kinds must be a list of 1.." .. M.LIMITS.kinds
    end
    q.kinds = {}
    for _, k in ipairs(args.kinds) do
      if not M.KINDS[k] then
        return nil, "unknown kind " .. tostring(k)
      end
      q.kinds[k] = true
    end
  end
  if args.device_id ~= nil or capability == "events.device_history" then
    q.device_id = int(args.device_id)
    if q.device_id == nil or q.device_id <= 0 then
      return nil, "device_id must be a Director device id"
    end
  end
  if args.room_id ~= nil or capability == "events.room_activity" then
    q.room_id = int(args.room_id)
    if q.room_id == nil or q.room_id <= 0 then
      return nil, "room_id must be a Director room id"
    end
  end
  if args.text ~= nil then
    if type(args.text) ~= "string" or args.text == "" or #args.text > M.LIMITS.text then
      return nil, "text must be 1.." .. M.LIMITS.text .. " characters"
    end
    q.text = args.text:lower()
  end
  if args.cursor ~= nil then
    q.cursor = M.decodeCursor(args.cursor)
    if q.cursor == nil then
      return nil, "cursor malformed"
    end
    if q.cursor.order ~= q.order then
      return nil, "cursor belongs to the other order"
    end
  end
  return q
end

local function textOf(e)
  return table
    .concat({
      tostring(e.event_name or ""),
      tostring(e.text or ""),
      tostring(e.detail or ""),
      tostring(e.variable or ""),
      tostring(e.device_label or ""),
      tostring(e.name or ""),
    }, " ")
    :lower()
end

local function matches(e, q)
  if q.kinds and not q.kinds[e.kind] then
    return false
  end
  if q.device_id and tonumber(e.device_id) ~= q.device_id then
    return false
  end
  if q.room_id and tonumber(e.room_id) ~= q.room_id then
    return false
  end
  if q.from and (type(e.t) ~= "number" or e.t < q.from) then
    return false
  end
  if q.to and (type(e.t) ~= "number" or e.t > q.to) then
    return false
  end
  if q.since_seq and (e.seq or 0) <= q.since_seq then
    return false
  end
  if q.text and not textOf(e):find(q.text, 1, true) then
    return false
  end
  return true
end

--- One ring entry as a reader sees it. Field `event_id` is the ENVELOPE id
--- (what the platform stores); a device event's Composer event number is
--- `device_event_id`.
function M.serialize(e)
  local out = {
    seq = e.seq,
    at = isoAt(e.t),
    t = type(e.t) == "number" and math.floor(e.t * 1000) / 1000 or nil,
    kind = e.kind,
    event_type = e.event_type or (e.kind == "event" and "capture.event" or nil),
    device_id = tonumber(e.device_id),
    device_label = e.device_label,
    room_id = tonumber(e.room_id),
    room_label = e.room_label,
  }
  if type(e.envelope_id) == "string" and e.envelope_id ~= "" then
    out.event_id = e.envelope_id
  else
    out.no_event_id = e.kind == "event" and e.uploaded == false and "over_upload_budget" or "not_recorded"
  end
  if e.kind == "event" then
    out.event_name = e.event_name
    out.device_event_id = tonumber(e.event_id)
    out.name_known = e.known == true
  elseif e.kind == "change" then
    out.variable = e.variable
    out.value = e.value
    out.initial = e.initial == true
    out.previous_known = e.previous_known == true
    if e.previous_known then
      out.previous = e.previous -- the recorder's own last reading, not Director's
    end
    out.coalesced = tonumber(e.coalesced)
  elseif e.kind == "trace" then
    out.channel = e.channel
    out.trace_id = e.trace_id
    out.step = e.step
    out.name = e.name
    out.text = e.text
    out.status = e.status
  elseif e.kind == "mark" then
    out.event_name = e.event_name
    out.detail = e.detail
    out.trace_id = e.trace_id
  else
    out.text = e.text
  end
  return out
end

local function retention(ring, ctx)
  local oldest = ring:oldest()
  local r = {
    source = "flight_recorder_local_ring",
    policy = M.POLICY_TEXT,
    capacity = ring.capacity,
    held = ring:count(),
    newest_seq = ring.seq,
    evicted_total = ring.evicted or 0,
    history_generation = ctx.generation or 0,
    recording_status = ctx.recording_status,
  }
  if oldest ~= nil then
    r.oldest_available = { seq = oldest.seq, at = isoAt(oldest.t) }
  end
  return r
end

--- Answers one request. Returns status ("ok"|"error"), result, error_code,
--- cursor — the four arguments of moduleclient's respond().
--- @param ctx table { ring, generation, now, recording_status, encode? }
function M.answer(capability, args, ctx)
  local q, why = M.parse(capability, args, ctx.now)
  if q == nil then
    return "error", nil, why == "capability" and "capability_not_found" or "invalid_args", nil
  end
  local ring = ctx.ring
  local generation = ctx.generation or 0
  if q.cursor ~= nil and q.cursor.generation ~= generation then
    -- The history was cleared since this cursor was handed out.
    return "error", nil, "invalid_args", nil
  end
  local encode = ctx.encode or function(v)
    return JSON:encode(v)
  end
  local entries = ring:recent(ring:count()) -- chronological copy
  local oldest = entries[1]
  local evicted = (ring.evicted or 0) > 0
  local n = #entries
  local i, step, last = 1, 1, n
  if q.order == "desc" then
    i, step, last = n, -1, 1
  end
  local page, budget = {}, 64
  local more = false
  local lastSeq = nil
  local reachedOldest = n == 0
  while n > 0 and ((step == 1 and i <= last) or (step == -1 and i >= last)) do
    local e = entries[i]
    local inCursor = q.cursor == nil
      or (q.order == "asc" and e.seq > q.cursor.seq)
      or (q.order == "desc" and e.seq < q.cursor.seq)
    if inCursor and matches(e, q) then
      if #page >= q.limit then
        more = true
        break
      end
      local item = M.serialize(e)
      local size = Envelope.approxSize(item, 0, M.LIMITS.result_bytes) + 2
      if budget + size > M.LIMITS.result_bytes and #page > 0 then
        more = true
        break
      end
      page[#page + 1] = item
      budget = budget + size
      lastSeq = e.seq
    end
    if q.order == "desc" and i == 1 then
      reachedOldest = true
    end
    i = i + step
  end
  if q.order == "asc" then
    reachedOldest = true -- an ascending read always starts from the oldest held
  end

  -- truncated: older matching entries may have existed but are no longer
  -- held. Only meaningful once something has been evicted.
  local truncated = false
  if evicted and oldest ~= nil then
    local lowerT = q.from
    local lowerSeq = q.since_seq
    if q.order == "asc" and q.cursor ~= nil then
      lowerSeq = q.cursor.seq
    end
    if lowerSeq ~= nil then
      truncated = lowerSeq < oldest.seq - 1
    elseif lowerT ~= nil then
      truncated = type(oldest.t) == "number" and lowerT < oldest.t
    else
      truncated = reachedOldest and not more
    end
  elseif evicted and oldest == nil then
    truncated = true
  end

  local result = {
    capability = capability,
    events = page,
    count = #page,
    has_more = more,
    order = q.order,
    truncated = truncated,
    retention = retention(ring, ctx),
  }
  if capability == "events.timeline" then
    result.window = { from = isoAt(q.from), to = isoAt(q.to) }
  end
  local cursor = more and lastSeq ~= nil and M.encodeCursor(generation, q.order, lastSeq) or nil
  -- Measure what will really be sent; shed entries from the end until it
  -- fits under the contract's 24 KB (escaping can exceed the estimate).
  local raw = encode(result)
  while #raw > M.LIMITS.hard_result_bytes and #page > 1 do
    table.remove(page)
    result.count = #page
    result.has_more = true
    cursor = M.encodeCursor(generation, q.order, page[#page].seq)
    raw = encode(result)
  end
  return "ok", result, nil, cursor
end

return M
