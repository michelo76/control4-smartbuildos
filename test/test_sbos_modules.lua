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
local okP, replyP = newR():register(reg({ protocol_min = "3", protocol_max = "4" }))
check(
  "incompatible protocol tells the Agent's range",
  okP == false and replyP.reason == "incompatible_protocol" and replyP.agent_protocol_max == "2"
)
check(
  "overlap negotiates the highest common",
  select(2, newR():register(reg({ protocol_min = "1", protocol_max = "5" }))).protocol == "2"
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

print("[8] registry cap: 48 live registrations, the 49th refused registry_full")
do
  local cr = newR()
  local okAll = true
  for i = 1, 48 do
    local okI = cr:register(reg({ module_id = "mod_" .. i, instance_id = tostring(1000 + i), singleton = "false" }))
    okAll = okAll and okI
  end
  check("cap is 48", Mod.LIMITS.modules == 48)
  check("48 distinct modules register", okAll and #cr.entries == 48)
  local ok49, r49 = cr:register(reg({ module_id = "mod_49", instance_id = "1049", singleton = "false" }))
  check("the 49th is refused registry_full", not ok49 and r49.reason == "registry_full", r49.reason)
  local okRe = cr:register(reg({ module_id = "mod_1", instance_id = "1001", singleton = "false" }))
  check("a full registry still re-registers an existing instance", okRe and #cr.entries == 48)
end

print("[9] identity binding: reserved module ids bound to their .c4z")
do
  local files =
    { ["smartbuildos-pin-lock.c4z"] = { [900] = "PIN Lock" }, ["smartbuildos-ai-core.c4z"] = { [601] = "AI" } }
  local asked = {}
  local mode = "answer"
  local function newBound()
    return Mod.Registry.new({
      now = function()
        return clock.t
      end,
      newToken = function()
        tokens = tokens + 1
        return "tok" .. tokens
      end,
      devicesForFile = function(file)
        asked[#asked + 1] = file
        if mode == "nil" then
          return nil
        elseif mode == "throw" then
          error("no such API")
        end
        return files[file] or {}
      end,
    })
  end
  local br = newBound()
  local okS, rS = br:register(reg({ module_id = "pin_lock", instance_id = "777" }))
  check(
    "squatting pin_lock from a device that is not smartbuildos-pin-lock.c4z → refused not_permitted",
    not okS and rS.reason == "not_permitted" and br:find("pin_lock", "777") == nil,
    rS.reason
  )
  check("the resolver was asked for the PIN Lock file", asked[#asked] == "smartbuildos-pin-lock.c4z")
  local okP, _, eP = br:register(reg({ module_id = "pin_lock", instance_id = "900" }))
  check("pin_lock from the PIN Lock device → registered, verified", okP and eP.verified == true)
  local okA, _, eA = br:register(reg({ module_id = "ai_core", instance_id = "601" }))
  check("ai_core from the AI Core device → verified", okA and eA.verified == true)
  local okSq = br:register(reg({ module_id = "ai_core", instance_id = "900" }))
  check("ai_core claimed from the PIN Lock device → refused", not okSq)
  -- (every root driver's id is reserved now; this one belongs to no driver)
  local okN, _, eN = br:register(reg({ module_id = "atmosphere_test", instance_id = "333" }))
  check("a non-reserved id registers as before, verified = false", okN and eN.verified == false)
  mode = "nil"
  local okU, _, eU = newBound():register(reg({ module_id = "pin_lock", instance_id = "777" }))
  check("resolver answers nil (Director gave no table) → registered, verified = false", okU and eU.verified == false)
  mode = "throw"
  local okT, _, eT = newBound():register(reg({ module_id = "pin_lock", instance_id = "777" }))
  check("resolver throws → registered, verified = false", okT and eT.verified == false)
  mode = "answer"
  -- A squatter persisted before binding existed loses the id when it
  -- next registers.
  local old = newBound()
  old.entries[1] = { module_id = "pin_lock", instance_id = "777", token = "old", last_seen = clock.t }
  local okO, _, _, removed = old:register(reg({ module_id = "pin_lock", instance_id = "777" }))
  check(
    "an earlier squatter entry is removed on refusal (and returned)",
    not okO and removed ~= nil and removed.token == "old" and old:find("pin_lock", "777") == nil
  )
  local rows = br:heartbeatBlock({ paired = true, connected = true })
  local pinRow
  for _, row in ipairs(rows) do
    if row.module_id == "pin_lock" then
      pinRow = row
    end
  end
  check("heartbeat block carries verified; never the token", pinRow and pinRow.verified == true and pinRow.token == nil)
  local okNo, _, eNo = newR():register(reg({ module_id = "pin_lock", instance_id = "777" }))
  check("no resolver injected → nothing bound (pure v1 behaviour), unverified", okNo and eNo.verified == false)
end

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
