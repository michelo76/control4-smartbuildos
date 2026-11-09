--- Owner-side publication filters: debounce/stability, numeric change
--- threshold, minimum publication interval and maximum silence.
---
--- Pure module. The driver feeds it every local change plus a clock; it
--- answers whether to publish now, later, or not at all. The *source* value
--- and the *published* value are kept apart so Studio can show both and so
--- filter-induced delay is reported separately from transport latency.
---
--- Filters apply to STATE only. Events and requests never pass through here.
--- With no filter configured every ordinary change publishes immediately.

local schema = require("systemlink.schema")

local M = {}

--- @return table state  per-item filter state, JSON-safe
function M.newState()
  return {
    source = nil, -- latest typed value seen locally
    source_at = nil, -- ms when it was seen
    published = nil, -- last value handed to the transport
    published_at = nil,
    pending = nil, -- value waiting on debounce/min_interval
    pending_since = nil, -- ms when the pending value first arrived
    stable_since = nil, -- ms since the source stopped changing
  }
end

local function numericDelta(a, b)
  if type(a) ~= "table" or type(b) ~= "table" then
    return math.huge
  end
  if a.s ~= schema.STATES.CURRENT or b.s ~= schema.STATES.CURRENT then
    return math.huge -- a state change always counts as a change
  end
  if type(a.v) ~= "number" or type(b.v) ~= "number" then
    return math.huge
  end
  return math.abs(a.v - b.v)
end

--- Records a new source value. Returns a decision:
---   { publish = true, value = tv, filter_delay_ms = n }   publish now
---   { publish = false, due_at = ms }                      publish later; call M.flush at due_at
---   { publish = false }                                   suppressed (threshold not met)
function M.offer(state, def, tv, nowMs)
  local f = (def and def.filter) or {}
  local changed = not schema.equal(state.source, tv)
  state.source = tv
  state.source_at = nowMs
  if changed then
    state.stable_since = nowMs
  end

  -- Threshold: compare against what was last PUBLISHED, not the last source
  -- value, or a slow drift would never cross it.
  if f.threshold and f.threshold > 0 and state.published ~= nil then
    if numericDelta(state.published, tv) < f.threshold then
      -- Keep max_silence alive so a refresh still goes out.
      state.pending = nil
      state.pending_since = nil
      return { publish = false, reason = "threshold" }
    end
  end

  if state.pending == nil then
    state.pending_since = nowMs
  end
  state.pending = tv

  return M.flush(state, def, nowMs)
end

--- Decides whether the pending value may go out at `nowMs`.
function M.flush(state, def, nowMs)
  local f = (def and def.filter) or {}
  if state.pending == nil then
    -- Nothing pending: only max_silence can force a refresh publish.
    if f.max_silence_s and f.max_silence_s > 0 and state.published ~= nil and state.published_at then
      local due = state.published_at + f.max_silence_s * 1000
      if nowMs >= due then
        state.published_at = nowMs
        return { publish = true, value = state.published, filter_delay_ms = 0, refresh = true }
      end
      return { publish = false, due_at = due }
    end
    return { publish = false }
  end

  local dueAt = nowMs
  if f.debounce_s and f.debounce_s > 0 then
    dueAt = math.max(dueAt, (state.stable_since or nowMs) + f.debounce_s * 1000)
  end
  if f.min_interval_s and f.min_interval_s > 0 and state.published_at then
    dueAt = math.max(dueAt, state.published_at + f.min_interval_s * 1000)
  end
  if nowMs < dueAt then
    return { publish = false, due_at = dueAt }
  end

  local value = state.pending
  local delay = nowMs - (state.pending_since or nowMs)
  state.pending = nil
  state.pending_since = nil
  if schema.equal(state.published, value) then
    -- Coalesced back to the published value: nothing to send, but the
    -- confirmation still counts for freshness, which the caller reports.
    return { publish = false, reason = "unchanged", confirmed = true }
  end
  state.published = value
  state.published_at = nowMs
  return { publish = true, value = value, filter_delay_ms = delay }
end

--- Next moment the driver should call `flush` for this item, or nil.
function M.nextDue(state, def, nowMs)
  local d = M.peek(state, def, nowMs)
  return d.due_at
end

--- Like flush but without side effects.
function M.peek(state, def, nowMs)
  local copy = {}
  for k, v in pairs(state) do
    copy[k] = v
  end
  return M.flush(copy, def, nowMs)
end

return M
