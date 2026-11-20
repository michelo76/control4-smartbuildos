--- SmartBuildOS AI Core — the driver's state machine (pure).
---
--- Inputs are facts the driver holds; the output is ONE code plus the
--- texts the Composer properties and the AI_STATUS variable show. The
--- order of the checks is the precedence (the first that applies wins):
---
---   no_agent               no smartbuildos.c4z in the project
---   agent_update_required  the Agent speaks only protocol 1 (AI Core needs 2)
---   agent_lost             registered, but the Agent stopped answering (liveness)
---   registering            Agent found, registration not (yet) accepted
---   agent_unpaired         the Agent is not paired to SmartBuildOS
---   cloud_unreachable      the Agent reports no cloud, or the last cloud call
---                          could not reach SmartBuildOS
---   unlicensed             a DEFINITIVE licence denial with enforcement on
---   ready                  everything above is fine
---
--- `working` is ready with jobs waiting for results. Uncertain licence
--- states (no answer yet, cloud validation required) never produce
--- `unlicensed`: uncertainty fails open, as everywhere in SmartBuildOS.

local M = {}

M.CODES = {
  "no_agent",
  "agent_update_required",
  "agent_lost",
  "registering",
  "agent_unpaired",
  "cloud_unreachable",
  "unlicensed",
  "ready",
}

M.CONNECTION_TEXT = {
  no_agent = "No SmartBuildOS Agent in this project",
  agent_update_required = "SmartBuildOS Agent update required (module contract v2)",
  agent_lost = "SmartBuildOS Agent not responding",
  registering = "Registering with the SmartBuildOS Agent",
  agent_unpaired = "SmartBuildOS Agent not paired",
  cloud_unreachable = "SmartBuildOS cloud unreachable",
  unlicensed = "Connected (not licensed)",
  ready = "Connected",
}

--- @param f table {
---   agentFound, registered, agentUpdateRequired, agentLost,
---   paired, connected, cloudUnreachable, licenceHalted, pendingJobs }
--- @return string code
function M.code(f)
  if not f.agentFound then
    return "no_agent"
  end
  if f.agentUpdateRequired then
    return "agent_update_required"
  end
  if f.agentLost then
    return "agent_lost"
  end
  if not f.registered then
    return "registering"
  end
  if not f.paired then
    return "agent_unpaired"
  end
  if not f.connected or f.cloudUnreachable then
    return "cloud_unreachable"
  end
  if f.licenceHalted then
    return "unlicensed"
  end
  return "ready"
end

--- AI_STATUS (variable): the code, or `working` when ready with jobs pending.
function M.variable(code, f)
  if code == "ready" and (f.pendingJobs or 0) > 0 then
    return "working"
  end
  return code
end

--- AI Status (property): one human line, with the last refusal said
--- truthfully when there is one.
function M.aiStatusText(code, f)
  local base
  if code == "ready" then
    if (f.pendingJobs or 0) > 0 then
      base = string.format("Working: %d request(s) waiting for a result", f.pendingJobs)
    else
      base = "Ready"
    end
    if f.learningActive == false then
      base = base .. " (learning paused)"
    end
  elseif code == "unlicensed" then
    base = "Unavailable: " .. tostring(f.licenceLabel or "not licensed")
  else
    base = "Degraded: " .. M.CONNECTION_TEXT[code]
  end
  if f.lastRefusal ~= nil and f.lastRefusal ~= "" then
    base = base .. " — last request " .. f.lastRefusal
  end
  return base
end

--- Agent Pairing Status (property).
function M.pairingText(f)
  if not f.agentFound then
    return "No SmartBuildOS Agent"
  end
  if f.agentUpdateRequired then
    return "Agent update required"
  end
  if not f.registered then
    return "Unknown (not registered with the Agent yet)"
  end
  return f.paired and "Paired" or "Not paired"
end

--- Whether AGENT_CONNECTED is true: registered and answering.
function M.agentConnected(f)
  return f.agentFound and f.registered and not f.agentLost and true or false
end

return M
