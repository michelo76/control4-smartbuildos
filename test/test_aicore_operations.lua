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
    refused(
      cmd,
      {
        command = "UNLOCK",
        event = "pattern_detected",
        active = true,
        response_id = "r",
        text = "t",
        device_id = 1,
        config = {},
        version = 1,
      }
    )
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

print("[4] AI_LAST_RESPONSE bound")
local short, cut = O.boundResponse("ok")
check("short text kept", short == "ok" and cut == false)
local b, c2 = O.boundResponse(string.rep("x", 2000))
check("cut to 1024 with a marker", #b == 1024 and c2 == true and b:sub(-3) == "...")
local u = O.boundResponse(string.rep("€", 400)) -- 3-byte characters
check("never splits a UTF-8 character", #u <= 1024 and (u:sub(1, -4):len() % 3) == 0)

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
