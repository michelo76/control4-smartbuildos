--- Startup reconciliation and the "initial state versus live change"
--- distinction.
---
--- Pure module. The driver runs the phases in order on every start:
---   1 restored      local last-known state is back in the native variables
---   2 stale_marked  every mirror is marked stale (not unknown: the value is
---                   still the best we have, it is just unconfirmed)
---   3 authenticated the relay accepted our endpoint credential
---   4 schema        definitions and endpoint generations reconciled
---   5 revisions     owner revisions reconciled (pending vs committed)
---   6 snapshot      the peer's current snapshot applied
---   7 synced        Initial Sync Complete fires; live updates begin
---
--- Only phase-7-onwards changes are *live*. Everything applied before that
--- is restoration or snapshot and fires the Initial Sync Complete event, not
--- Remote Variable Changed Live.

local protocol = require("systemlink.protocol")

local M = {}

M.PHASES = { "restored", "stale_marked", "authenticated", "schema", "revisions", "snapshot", "synced" }
local INDEX = {}
for i, p in ipairs(M.PHASES) do
  INDEX[p] = i
end

function M.newState()
  return { phase = nil, started_at = nil, synced_at = nil, generation_fenced = false }
end

--- Advances the phase; refuses to skip.
function M.advance(st, phase, nowMs)
  local want = INDEX[phase]
  if not want then
    return false, "unknown phase"
  end
  local have = st.phase and INDEX[st.phase] or 0
  if want ~= have + 1 then
    return false, "cannot go from " .. tostring(st.phase) .. " to " .. phase
  end
  st.phase = phase
  if phase == "restored" then
    st.started_at = nowMs
  elseif phase == "synced" then
    st.synced_at = nowMs
  end
  return true
end

--- Drops back to the beginning of the network part (keeps local restore).
function M.disconnected(st)
  if st.phase and INDEX[st.phase] >= INDEX.authenticated then
    st.phase = "stale_marked"
    st.synced_at = nil
  end
end

function M.isSynced(st)
  return st.phase == "synced"
end

--- Classifies a change that the driver is about to apply to a mirror.
--- @return "restore" | "snapshot" | "live" | "admin"
function M.classify(st, source)
  if source == "admin" then
    return "admin"
  end
  if not st.phase or INDEX[st.phase] < INDEX.authenticated then
    return "restore"
  end
  if st.phase ~= "synced" then
    return "snapshot"
  end
  return "live"
end

-- ── Owner revision reconciliation ───────────────────────────────────────────

--- Compares what this endpoint holds for its OWN items against what the
--- relay has committed, after a restart. Decisions per item:
---   republish   local rev > committed rev   (pending update never sent)
---   adopt       committed rev > local rev   (we restored an older backup;
---               the committed value is newer and wins — but it is reported,
---               never silent)
---   confirmed   equal
---   fresh       relay has nothing (first publication)
--- The owner generation is the first key: if our generation is newer than
--- the relay's record (controller replaced), every local value republishes
--- at the new generation and the old generation is fenced.
--- @param localItems { [id] = { gen, rev, value } }
--- @param committed  { [id] = { gen, rev, value } } from the relay
--- @param selfGen number this endpoint's current generation
--- @return table decisions { [id] = { action = ..., value = ... } }, table notices
function M.reconcileOwner(localItems, committed, selfGen)
  local decisions, notices = {}, {}
  for id, loc in pairs(localItems) do
    local com = committed[id]
    if not com then
      decisions[id] = { action = "fresh", value = loc.value, rev = loc.rev or 0 }
    elseif (com.gen or 0) < selfGen then
      decisions[id] = { action = "republish", value = loc.value, rev = loc.rev or 0, reason = "new generation" }
    else
      local c = protocol.compareRev(loc.gen or selfGen, loc.rev or 0, com.gen or 0, com.rev or 0)
      if c > 0 then
        decisions[id] = { action = "republish", value = loc.value, rev = loc.rev }
      elseif c < 0 then
        decisions[id] = { action = "adopt", value = com.value, rev = com.rev, gen = com.gen }
        notices[#notices + 1] = {
          item = id,
          kind = "stale_backup",
          detail = string.format(
            "local rev %s is older than committed rev %s; committed value adopted",
            tostring(loc.rev),
            tostring(com.rev)
          ),
        }
      else
        decisions[id] = { action = "confirmed", value = loc.value, rev = loc.rev }
      end
    end
  end
  return decisions, notices
end

--- Persistence health: decides what to do when the stored state fails to
--- load. Corrupt persistence never silently becomes "defaults": the driver
--- restores from the relay snapshot and reports it.
--- @return "use" | "rebuild_from_relay" | "defaults"
function M.persistencePolicy(loaded, relayReachable)
  if loaded then
    return "use"
  end
  if relayReachable then
    return "rebuild_from_relay"
  end
  return "defaults"
end

return M
