--- Freshness and the aggregate Remote System State.
---
--- Pure module. Freshness is about *confirmation*, not change: an item whose
--- value has not moved for hours is still current while the owner keeps
--- confirming it (every snapshot, every heartbeat-carried digest). A value
--- only becomes stale when nothing has confirmed it within its policy.

local schema = require("systemlink.schema")

local M = {}

M.DEFAULT_MAX_AGE_S = 900 -- 15 minutes without any confirmation → stale

--- Per-item freshness record (JSON-safe):
---   { last_source_update = ms, last_confirmation = ms, state = ... }
function M.newRecord()
  return { last_source_update = nil, last_confirmation = nil }
end

--- A live update from the owner: both timestamps move.
function M.onUpdate(rec, nowMs)
  rec.last_source_update = nowMs
  rec.last_confirmation = nowMs
end

--- A confirmation that the value is still what we hold (snapshot/digest).
function M.onConfirm(rec, nowMs)
  rec.last_confirmation = nowMs
end

--- Evaluates one item.
--- @return table { state = current|stale|unknown|unavailable, age_ms = n|nil }
function M.evaluate(rec, def, tv, nowMs, linkSynced)
  if type(tv) ~= "table" or tv.s == schema.STATES.UNKNOWN or rec.last_confirmation == nil then
    return { state = schema.STATES.UNKNOWN }
  end
  if tv.s == schema.STATES.UNAVAILABLE then
    return { state = schema.STATES.UNAVAILABLE, age_ms = nowMs - rec.last_confirmation }
  end
  local maxAge = ((def and def.freshness and def.freshness.max_age_s) or M.DEFAULT_MAX_AGE_S) * 1000
  local age = nowMs - rec.last_confirmation
  if not linkSynced or age > maxAge then
    return { state = schema.STATES.STALE, age_ms = age }
  end
  return { state = schema.STATES.CURRENT, age_ms = age }
end

-- ── Aggregate Remote System State ───────────────────────────────────────────

M.REMOTE = {
  LICENSE_ATTENTION = "License Attention",
  PAUSED = "Paused",
  OFFLINE = "Offline",
  SYNCHRONIZING = "Synchronizing",
  STALE = "Stale",
  READY = "Ready",
}

--- Precedence, highest first. The aggregate is the first that applies, so
--- it is predictable: a paused link is Paused even while offline, and a
--- licence problem outranks everything because it is the one the dealer
--- must act on.
M.PRECEDENCE = { "LICENSE_ATTENTION", "PAUSED", "OFFLINE", "SYNCHRONIZING", "STALE", "READY" }

--- Inputs are the separate underlying states the driver also exposes:
---   license   = "ok" | "attention"
---   paused    = boolean (whole link paused; command-only pause is NOT this)
---   transport = "connected" | "connecting" | "disconnected"
---   peer      = "online" | "stale" | "offline"   (from heartbeats)
---   sync      = "complete" | "in_progress" | "not_started"
---   stale_items = number of mirrored items currently stale
--- @return string state, string reason
function M.aggregate(i)
  if i.license == "attention" then
    return M.REMOTE.LICENSE_ATTENTION, i.license_reason or "licence requires attention"
  end
  if i.paused then
    return M.REMOTE.PAUSED, i.paused_reason or "link paused by dealer"
  end
  if i.transport ~= "connected" or i.peer == "offline" then
    if i.transport ~= "connected" then
      return M.REMOTE.OFFLINE, "relay " .. tostring(i.transport or "disconnected")
    end
    return M.REMOTE.OFFLINE, "peer heartbeat missing"
  end
  if i.sync ~= "complete" then
    return M.REMOTE.SYNCHRONIZING, i.sync == "in_progress" and "snapshot in progress" or "waiting for snapshot"
  end
  if i.peer == "stale" or (i.stale_items or 0) > 0 then
    if i.peer == "stale" then
      return M.REMOTE.STALE, "peer heartbeat late"
    end
    return M.REMOTE.STALE, tostring(i.stale_items) .. " item(s) not confirmed within policy"
  end
  return M.REMOTE.READY, "synchronized"
end

--- Peer presence from heartbeat timing. A heartbeat proves the peer DRIVER is
--- present; it says nothing about physical devices behind it.
--- @param lastHeartbeatMs number|nil
--- @param intervalMs number the agreed heartbeat interval
function M.peerState(lastHeartbeatMs, intervalMs, nowMs)
  if lastHeartbeatMs == nil then
    return "offline"
  end
  local age = nowMs - lastHeartbeatMs
  if age <= intervalMs * 2 then
    return "online"
  end
  if age <= intervalMs * 5 then
    return "stale"
  end
  return "offline"
end

return M
