--- Loop prevention: transport echo suppression is the protocol's job
--- (origin + revision + dedup); this module catches *programming* loops —
--- two projects whose Composer programming bounce an item back and forth —
--- with causal metadata where available and burst limits always.
---
--- Pure module.
---
--- Causal metadata: every owner publication may carry `cause`, the id of
--- the inbound message that the local programming reacted to (the driver
--- records the message id of the last live update that fired programming
--- within a short window). A publication whose cause chain returns to this
--- endpoint within `max_hops` is a confirmed loop. Independent updates that
--- merely happen to be frequent are NOT loops: the burst limiter counts
--- only, and reports "burst", never "loop".

local M = {}

M.DEFAULT_BURST = { max = 30, window_s = 10 } -- per item
M.MAX_HOPS = 4
M.SUSPEND_S = 60

function M.newState()
  return { items = {}, suspended = {} }
end

local function window(state, itemId)
  local w = state.items[itemId]
  if not w then
    w = { times = {} }
    state.items[itemId] = w
  end
  return w
end

--- Records an outbound publication and decides whether it may go.
--- @param state table
--- @param itemId string
--- @param nowMs number
--- @param opts { hops = number|nil (causal hop count carried in), burst = {max, window_s} }
--- @return boolean allowed, string|nil reason ("burst" | "loop" | "suspended")
function M.offer(state, itemId, nowMs, opts)
  opts = opts or {}
  local susp = state.suspended[itemId]
  if susp and nowMs < susp.until_ms then
    return false, "suspended"
  elseif susp then
    state.suspended[itemId] = nil
  end

  if opts.hops and opts.hops >= M.MAX_HOPS then
    state.suspended[itemId] = { until_ms = nowMs + M.SUSPEND_S * 1000, reason = "loop", at = nowMs }
    return false, "loop"
  end

  local b = opts.burst or M.DEFAULT_BURST
  local w = window(state, itemId)
  local cutoff = nowMs - b.window_s * 1000
  local kept = {}
  for _, t in ipairs(w.times) do
    if t > cutoff then
      kept[#kept + 1] = t
    end
  end
  kept[#kept + 1] = nowMs
  w.times = kept
  if #kept > b.max then
    state.suspended[itemId] = { until_ms = nowMs + M.SUSPEND_S * 1000, reason = "burst", at = nowMs }
    return false, "burst"
  end
  return true
end

--- Hop count to stamp on an outbound publication caused by an inbound one.
function M.nextHops(inboundHops)
  return (tonumber(inboundHops) or 0) + 1
end

--- Dealer-authorised recovery: clears a suspension early.
function M.recover(state, itemId)
  state.suspended[itemId] = nil
end

function M.suspensions(state, nowMs)
  local out = {}
  for id, s in pairs(state.suspended) do
    if nowMs < s.until_ms then
      out[#out + 1] = { item = id, reason = s.reason, until_ms = s.until_ms }
    end
  end
  table.sort(out, function(a, b)
    return a.item < b.item
  end)
  return out
end

return M
