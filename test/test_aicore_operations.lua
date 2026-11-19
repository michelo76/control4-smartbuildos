-- aicore.operations (pure): the six restricted operations' arguments are a
-- closed set — nothing that names a device command, Lua or a URL can pass —
-- plus bounds on results and event detail.
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

local O = require("aicore.operations")
local V = require("aicore.vocab")

print("[1] each operation with valid arguments")
check("apply_config", O.parse("apply_config", { config = {}, version = 3 }).version == 3)
check("refresh_status", O.parse("refresh_status", {}).kind == "refresh_status")
local d = O.parse(
  "deliver_result",
  { response_id = "r-1", request_id = "aic-1", job_id = 7, text = "hello", kind = "report", pending_approvals = 2 }
)
check(
  "deliver_result",
  d and d.response_id == "r-1" and d.job_id == "7" and d.kind_of == "report" and d.pending_approvals == 2
)
local r = O.parse("raise_event", { event = "pattern_detected", detail = "kitchen lights at 03:00 on 4 of 7 nights" })
check("raise_event maps to the Composer event id", r and r.event_id == 2)
check("set_learning", O.parse("set_learning", { active = false, reason = "privacy" }).active == false)
check(
  "set_learning carries the configuration version it previews",
  O.parse("set_learning", { active = false, config_version = 7 }).config_version == 7
    and O.parse("set_learning", { active = true }).config_version == nil
)
check("run_diagnostic by device", O.parse("run_diagnostic", { device_id = 12 }).device_id == 12)
check("run_diagnostic by room", O.parse("run_diagnostic", { room_id = 3 }).room_id == 3)

print("[2] closed argument sets")
local function refused(cmd, args)
  local op, why = O.parse(cmd, args)
  return op == nil and type(why) == "string"
end
check("unknown operation", refused("send_to_device", { device_id = 30, command = "UNLOCK" }))
check("unknown operation (lua)", refused("execute_lua", { code = "x" }))
for _, cmd in ipairs(V.OPERATIONS) do
  check(
    cmd .. ": an extra `command` argument refuses it",
    refused(cmd, {
      command = "UNLOCK",
      event = "pattern_detected",
      active = true,
      response_id = "r",
      text = "t",
      device_id = 1,
      config = {},
      version = 1,
    })
  )
end
check("args not an object", refused("refresh_status", "x"))
check("apply_config without config", refused("apply_config", { version = 1 }))
check("apply_config without version", refused("apply_config", { config = {} }))
check("deliver_result without response_id", refused("deliver_result", { text = "x" }))
check("deliver_result with a malformed response_id", refused("deliver_result", { response_id = "../x", text = "x" }))
check("deliver_result text over 4000", refused("deliver_result", { response_id = "r", text = string.rep("x", 4001) }))
check("deliver_result unknown kind", refused("deliver_result", { response_id = "r", text = "x", kind = "command" }))
check("count out of range", refused("deliver_result", { response_id = "r", text = "x", pending_approvals = -1 }))
check("set_learning active not boolean", refused("set_learning", { active = "on" }))
check("set_learning config_version negative", refused("set_learning", { active = true, config_version = -1 }))
check("set_learning config_version fractional", refused("set_learning", { active = true, config_version = 1.5 }))
check("set_learning config_version as text", refused("set_learning", { active = true, config_version = "3" }))
check("run_diagnostic both", refused("run_diagnostic", { device_id = 1, room_id = 2 }))
check("run_diagnostic neither", refused("run_diagnostic", {}))
check("run_diagnostic bad id", refused("run_diagnostic", { device_id = "x" }))

print("[3] raise_event: exactly the closed list")
local n = 0
for name in pairs(V.RAISABLE) do
  n = n + 1
  check("raisable: " .. name, O.parse("raise_event", { event = name }) ~= nil)
end
check("nine raisable events", n == 9)
for _, bad in ipairs({ "agent_disconnected", "Agent Disconnected", "AI Response Ready", "ON", "", "fire_all" }) do
  check("refused: '" .. bad .. "'", refused("raise_event", { event = bad }))
end
check("event must be a string", refused("raise_event", { event = 1 }))
local long = O.parse("raise_event", { event = "action_failed", detail = string.rep("x", 600) })
check("detail bounded to 512 and flagged", #long.detail == 512 and long.detail_truncated == true)
check(
  "control characters in detail neutralised",
  O.parse("raise_event", { event = "action_failed", detail = "a\0b\7c" }).detail == "ab c"
)

print("[3b] raise_event correlation_id: optional, bounded, the only added key")
-- src/lib/ai-core/actions/service.ts raiseEvent() sends it with every
-- approval/action event; refusing it ended each of them Failed.
local withCorr = O.parse("raise_event", { event = "approval_required", detail = "x", correlation_id = "act-7f3a" })
check("accepted, carried as op.correlation_id", withCorr ~= nil and withCorr.correlation_id == "act-7f3a")
local uuid = "0d6f9a2e-5b1c-4c8e-9f00-123456789abc"
check(
  "a platform action uuid is accepted unchanged",
  (O.parse("raise_event", { event = "action_completed", correlation_id = uuid }) or {}).correlation_id == uuid
)
check("absent → no correlation_id", O.parse("raise_event", { event = "pattern_detected" }).correlation_id == nil)
check(
  "96 characters accepted (the envelope bound)",
  O.parse("raise_event", { event = "action_failed", correlation_id = string.rep("c", 96) }) ~= nil
)
check("97 refused", refused("raise_event", { event = "action_failed", correlation_id = string.rep("c", 97) }))
check("empty refused", refused("raise_event", { event = "action_failed", correlation_id = "" }))
check("not text refused", refused("raise_event", { event = "action_failed", correlation_id = 7 }))
check("a control character refused", refused("raise_event", { event = "action_failed", correlation_id = "a\nb" }))
check("DEL refused", refused("raise_event", { event = "action_failed", correlation_id = "a\127b" }))
check(
  "every OTHER unknown key is still refused, with correlation_id present",
  refused("raise_event", { event = "action_failed", correlation_id = "c-1", action_id = "x" })
)
check(
  "correlation_id is accepted by raise_event only",
  refused("deliver_result", { response_id = "r", text = "t", correlation_id = "c-1" })
    and refused("set_learning", { active = true, correlation_id = "c-1" })
)
local keys = table.concat(O.argKeys("raise_event"), ",")
check(
  "argKeys(raise_event) = correlation_id,detail,event,pending_approvals,recommendation_count",
  keys == "correlation_id,detail,event,pending_approvals,recommendation_count",
  keys
)

print("[4] AI_LAST_RESPONSE bound")
local short, cut = O.boundResponse("ok")
check("short text kept", short == "ok" and cut == false)
local b, c2 = O.boundResponse(string.rep("x", 2000))
check("cut to 1024 with a marker", #b == 1024 and c2 == true and b:sub(-3) == "...")
local u = O.boundResponse(string.rep("€", 400)) -- 3-byte characters
check("never splits a UTF-8 character", #u <= 1024 and (u:sub(1, -4):len() % 3) == 0)
local det = O.parse("raise_event", { event = "pattern_detected", detail = "a" .. string.rep("€", 200) })
check(
  "raise_event detail: bounded to 512 bytes, cut between characters",
  #det.detail <= 512 and det.detail == "a" .. string.rep("€", 170) and det.detail_truncated == true,
  #det.detail
)
-- AI_LAST_RESPONSE is bounded in BYTES (1024, the 3-byte "..." included)
check(
  "exactly 1024 bytes of 2-byte characters: kept whole",
  O.boundResponse(string.rep("é", 512)) == string.rep("é", 512)
)
local at1025, cutAt = O.boundResponse("x" .. string.rep("é", 512)) -- 1025 bytes
check(
  "1025 bytes: cut to 1021 bytes of whole characters + '...'",
  cutAt == true and at1025 == "x" .. string.rep("é", 510) .. "..." and #at1025 == 1024,
  #at1025
)
for offset = 0, 3 do
  -- 4-byte characters shifted so the 1021-byte cut lands on each byte of one
  local t = string.rep("a", offset) .. string.rep("😀", 300)
  local r = O.boundResponse(t)
  local body = r:sub(1, -4)
  check(
    "4-byte characters, offset " .. offset .. ": no partial sequence before the marker",
    #r <= 1024
      and #body >= 1017
      and (#body - offset) % 4 == 0
      and body:sub(offset + 1) == string.rep("😀", (#body - offset) / 4),
    #body
  )
end

print("[5] read_device_state: closed keys, every value checked")
do
  local REF = "0d6f9a2e-5b1c-4c8e-9f00-123456789abc"
  local function rds(over, drop)
    local a = { state_ref = REF, device_id = 120, scope = "system" }
    for k, v in pairs(over or {}) do
      a[k] = v
    end
    if drop then
      a[drop] = nil
    end
    return O.parse("read_device_state", a)
  end
  local op = rds()
  check(
    "valid: state_ref, device_id, scope; variables absent = every variable",
    op ~= nil
      and op.kind == "read_device_state"
      and op.state_ref == REF
      and op.device_id == 120
      and op.scope == "system"
      and #op.variables == 0
  )
  local full = rds({ scope = "full", variables = { "TEMPERATURE_F", "Battery Level", "LQI.raw-1" } })
  check("scope full with three narrowing names", full ~= nil and full.scope == "full" and #full.variables == 3)
  check("variables: an empty array is accepted (= every variable)", rds({ variables = {} }) ~= nil)
  local twelve = {}
  for i = 1, 12 do
    twelve[i] = "VAR_" .. i
  end
  check("variables: 12 names accepted", rds({ variables = twelve }) ~= nil)
  check("device_id 2147483647 accepted", rds({ device_id = 2147483647 }) ~= nil)
  local thirteen = { "X" }
  for i = 1, 12 do
    thirteen[#thirteen + 1] = twelve[i]
  end
  for _, c in ipairs({
    { "an unknown key (command)", { command = "UNLOCK" } },
    { "an unknown key (value)", { value = "1" } },
    { "an unknown key (variable_id)", { variable_id = 1000 } },
    { "state_ref missing", nil, "state_ref" },
    { "state_ref upper-case", { state_ref = REF:upper() } },
    { "state_ref not a uuid", { state_ref = "abc" } },
    { "device_id missing", nil, "device_id" },
    { "device_id 0", { device_id = 0 } },
    { "device_id negative", { device_id = -4 } },
    { "device_id 2147483648", { device_id = 2147483648 } },
    { "device_id fractional", { device_id = 12.5 } },
    { "device_id a string", { device_id = "120" } },
    { "scope missing", nil, "scope" },
    { "scope household", { scope = "household" } },
    { "scope SYSTEM", { scope = "SYSTEM" } },
    { "variables not an array (object)", { variables = { a = "TEMPERATURE_F" } } },
    { "variables a string", { variables = "TEMPERATURE_F" } },
    { "variables 13 names", { variables = thirteen } },
    { "variables a name twice", { variables = { "LQI", "LQI" } } },
    { "variables an empty name", { variables = { "" } } },
    { "variables a 49-byte name", { variables = { string.rep("A", 49) } } },
    { "variables a name with a quote", { variables = { 'A"B' } } },
    { "variables a name with a slash", { variables = { "A/B" } } },
    { "variables a name with a newline", { variables = { "A\nB" } } },
    { "variables a number", { variables = { 12 } } },
  }) do
    check("refused: " .. c[1], rds(c[2], c[3]) == nil)
  end
  check(
    "argKeys(read_device_state) = device_id, scope, state_ref, variables",
    table.concat(O.argKeys("read_device_state"), ",") == "device_id,scope,state_ref,variables"
  )
end

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
