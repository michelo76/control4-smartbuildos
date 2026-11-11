-- Module registration contract v1: registry rules.
package.path = "src/?.lua;" .. package.path
local Mod = require("sbos.modules")

local pass, fail = 0, 0
local function check(name, ok, detail)
  if ok then
    pass = pass + 1
    print("  ok   " .. name)
  else
    fail = fail + 1
    print("  FAIL " .. name .. (detail ~= nil and ("  -> " .. tostring(detail)) or ""))
  end
end

local clock = { t = 100 }
local tokens = 0
local function newR()
  return Mod.Registry.new({
    now = function()
      return clock.t
    end,
    newToken = function()
      tokens = tokens + 1
      return "tok" .. tokens
    end,
  })
end
local function reg(over)
  local p = {
    module_id = "flight_recorder",
    instance_id = "501",
    driver_version = "1",
    protocol_min = "1",
    protocol_max = "1",
    capabilities = "recording,traces",
    entitlements = "SBOS_FLIGHT_RECORDER",
    commands = "apply_config,pause",
    event_types = "observation.,trace.",
    singleton = "true",
  }
  for k, v in pairs(over or {}) do
    p[k] = v
  end
  return p
end

print("[1] register and authenticate")
local r = newR()
local ok, reply, entry = r:register(reg())
check("registered", ok and reply.ok == "true" and reply.token == "tok1" and reply.protocol == "1")
check("entry parsed csv", #entry.capabilities == 2 and entry.entitlements[1] == "SBOS_FLIGHT_RECORDER")
check("auth with token", r:authenticate({ module_id = "flight_recorder", instance_id = "501", token = "tok1" }) ~= nil)
check(
  "auth refused without token",
  select(2, r:authenticate({ module_id = "flight_recorder", instance_id = "501" })) == "bad_token"
)
check(
  "auth refused for unknown instance",
  select(2, r:authenticate({ module_id = "flight_recorder", instance_id = "9", token = "tok1" })) == "unknown_module"
)

print("[2] re-registration replaces the token, keeps the row")
clock.t = 200
local ok2, reply2 = r:register(reg())
check("new token", ok2 and reply2.token == "tok2")
check(
  "old token dead",
  select(2, r:authenticate({ module_id = "flight_recorder", instance_id = "501", token = "tok1" })) == "bad_token"
)
check(
  "one entry, registrations=2, registered_at kept",
  #r.entries == 1 and r.entries[1].registrations == 2 and r.entries[1].registered_at == 100
)

print("[3] singleton duplicates refused until the first goes stale")
local okDup, replyDup = r:register(reg({ instance_id = "502" }))
check(
  "duplicate refused",
  okDup == false and replyDup.reason == "duplicate_instance" and replyDup.other_instance_id == "501"
)
clock.t = 200 + Mod.LIMITS.stale_seconds + 1
local okLate, replyLate = r:register(reg({ instance_id = "502" }))
check("accepted once the other is stale", okLate and replyLate.ok == "true")
check("stale pruned", #r:prune() == 1 and r:count() == 1)

print("[4] validation")
check("bad module id", select(2, newR():register(reg({ module_id = "Flight-Recorder" }))).reason == "invalid_module_id")
check("bad instance", select(2, newR():register(reg({ instance_id = "abc" }))).reason == "invalid_instance_id")
local okP, replyP = newR():register(reg({ protocol_min = "2", protocol_max = "3" }))
check(
  "incompatible protocol tells the Agent's range",
  okP == false and replyP.reason == "incompatible_protocol" and replyP.agent_protocol_max == "1"
)
check(
  "overlap negotiates the highest common",
  select(2, newR():register(reg({ protocol_min = "1", protocol_max = "5" }))).protocol == "1"
)

print("[5] display status")
local agent = {
  paired = true,
  connected = true,
  licence = function()
    return "AUTHORIZED_SUBSCRIPTION"
  end,
  enforce = function()
    return false
  end,
}
local rr = newR()
local _, _, e = rr:register(reg())
check("ready", Mod.displayStatus(e, agent, false) == "ready")
check("unpaired", Mod.displayStatus(e, { paired = false }, false) == "unpaired")
check("degraded when Agent offline", Mod.displayStatus(e, { paired = true, connected = false }, false) == "degraded")
check("degraded when stale", Mod.displayStatus(e, agent, true) == "degraded")
check("unlicensed only when denied AND enforced", Mod.displayStatus(e, {
  paired = true,
  connected = true,
  licence = function()
    return "NOT_ENTITLED"
  end,
  enforce = function()
    return true
  end,
}, false) == "unlicensed")
check("denied but observe → not unlicensed", Mod.displayStatus(e, {
  paired = true,
  connected = true,
  licence = function()
    return "NOT_ENTITLED"
  end,
  enforce = function()
    return false
  end,
}, false) == "ready")
check("no entry → waiting", Mod.displayStatus(nil, agent) == "waiting_for_agent")

print("[6] serialize / restore / heartbeat block without tokens")
local doc = rr:serialize()
local back = Mod.Registry.restore(doc, {
  now = function()
    return clock.t
  end,
  newToken = function()
    return "t"
  end,
})
check("restored", #back.entries == 1 and back.entries[1].token == e.token)
local hb = back:heartbeatBlock(agent)
check(
  "heartbeat block has no token",
  hb[1].token == nil and hb[1].module_id == "flight_recorder" and hb[1].display_status == "ready"
)
check("garbage restore → empty", #Mod.Registry.restore("junk", {
  now = function()
    return 0
  end,
  newToken = function()
    return "t"
  end,
}).entries == 0)

print("[7] touch updates status and config state")
rr:touch(e, { status = "degraded", detail = "x", applied_config_version = "4", config_error = "bad budget" })
check("touched", e.status == "degraded" and e.applied_config_version == "4" and e.config_error == "bad budget")

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
