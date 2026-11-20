-- aicore.state (pure): precedence of the degraded states, the texts shown,
-- and that uncertainty never reads as unlicensed.
--
-- Run from the driver root: make test

local pass, fail = 0, 0
local function check(name, ok, detail)
  if ok then
    pass = pass + 1
    print(string.format("  ok   %s", name))
  else
    fail = fail + 1
    print(string.format("  FAIL %s%s", name, detail and ("  -> " .. tostring(detail)) or ""))
  end
end

local S = require("aicore.state")

local function f(over)
  local base = {
    agentFound = true,
    registered = true,
    agentUpdateRequired = false,
    agentLost = false,
    paired = true,
    connected = true,
    cloudUnreachable = false,
    licenceHalted = false,
    pendingJobs = 0,
    learningActive = true,
  }
  for k, v in pairs(over or {}) do
    base[k] = v
  end
  return base
end

print("[1] each state")
check("ready", S.code(f()) == "ready")
check("no_agent", S.code(f({ agentFound = false, registered = false })) == "no_agent")
check("agent_update_required (v1-only Agent)", S.code(f({ agentUpdateRequired = true })) == "agent_update_required")
check("agent_lost", S.code(f({ agentLost = true })) == "agent_lost")
check("registering", S.code(f({ registered = false })) == "registering")
check("agent_unpaired", S.code(f({ paired = false })) == "agent_unpaired")
check("cloud_unreachable (Agent says so)", S.code(f({ connected = false })) == "cloud_unreachable")
check("cloud_unreachable (last call)", S.code(f({ cloudUnreachable = true })) == "cloud_unreachable")
check("unlicensed", S.code(f({ licenceHalted = true })) == "unlicensed")

print("[2] precedence")
check(
  "no Agent beats everything",
  S.code(f({ agentFound = false, licenceHalted = true, paired = false })) == "no_agent"
)
check(
  "update required beats lost/unpaired",
  S.code(f({ agentUpdateRequired = true, paired = false, agentLost = true })) == "agent_update_required"
)
check("unpaired beats unlicensed", S.code(f({ paired = false, licenceHalted = true })) == "agent_unpaired")

print("[3] texts and variables")
for _, code in ipairs(S.CODES) do
  check("connection text for " .. code, type(S.CONNECTION_TEXT[code]) == "string")
end
check("working when jobs pending", S.variable("ready", f({ pendingJobs = 2 })) == "working")
check("AI Status says working", S.aiStatusText("ready", f({ pendingJobs = 2 })):find("Working: 2") ~= nil)
check(
  "AI Status says learning paused",
  S.aiStatusText("ready", f({ learningActive = false })):find("learning paused") ~= nil
)
check(
  "AI Status carries the last refusal",
  S.aiStatusText("ready", f({ lastRefusal = "refused (not_permitted)" })):find("refused %(not_permitted%)") ~= nil
)
check("degraded text", S.aiStatusText("agent_lost", f()):find("^Degraded") ~= nil)
check(
  "pairing texts",
  S.pairingText(f()) == "Paired"
    and S.pairingText(f({ paired = false })) == "Not paired"
    and S.pairingText(f({ agentFound = false })) == "No SmartBuildOS Agent"
)
check(
  "AGENT_CONNECTED needs registered and answering",
  S.agentConnected(f())
    and not S.agentConnected(f({ agentLost = true }))
    and not S.agentConnected(f({ registered = false }))
)

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
