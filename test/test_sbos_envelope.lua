-- Event envelope v1: build, validate, redact, bound, ownership.
package.path = "src/?.lua;" .. package.path
local E = require("sbos.envelope")

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

local ctx = {
  module_id = "flight_recorder",
  instance_id = "77",
  observed_at = "2026-10-22T01:02:03Z",
  boot_id = "b1",
  sequence = 5,
}

print("[1] build stamps identity and ordering facts")
local env, why = E.build({
  event_type = "observation.change",
  evidence_source = "observed",
  device_id = "12",
  room_id = 3,
  payload = { previous = "0", value = "100" },
}, ctx)
check("built", env ~= nil, why)
check("event_id is module:instance:boot:seq", env.event_id == "flight_recorder:77:b1:5", env.event_id)
check("schema v1", env.schema_version == 1)
check("device/room numeric", env.device_id == 12 and env.room_id == 3)
check("defaults info/confirmed", env.severity == "info" and env.quality == "confirmed")
check("installation_id left for the Agent", env.installation_id == nil)
check("validate accepts it", E.validate(env) == true)
check("ownership enforced", select(2, E.validate(env, "guardian")) == "module_mismatch")

print("[2] refusals")
check("bad event type", select(2, E.build({ event_type = "nodot", evidence_source = "observed" }, ctx)) == "event_type")
check(
  "unknown evidence",
  select(2, E.build({ event_type = "a.b", evidence_source = "guess" }, ctx)) == "evidence_source"
)
check(
  "unknown severity",
  select(2, E.build({ event_type = "a.b", evidence_source = "observed", severity = "loud" }, ctx)) == "severity"
)
local big = string.rep("word ", 1000)
local okBig, whyBig = E.build({
  event_type = "observation.change",
  evidence_source = "observed",
  payload = { a = big, b = big, c = big, d = big, e = big, f = big, g = big, h = big, i = big },
}, ctx)
check("oversized payload refused (after bounding strings)", okBig == nil and whyBig == "payload_too_large", whyBig)
check("prefix ownership: flight_recorder cannot emit health.*", select(
  2,
  E.validate({
    schema_version = 1,
    event_id = "x",
    event_type = "health.x",
    module_id = "flight_recorder",
    observed_at = "t",
    sequence = 1,
    severity = "info",
    evidence_source = "observed",
    quality = "confirmed",
  })
) == "event_type_not_owned")

print("[3] redaction")
local r = E.redact({
  ["User Code"] = "1234",
  pin = "9999",
  level = "50",
  nested = { token = "abc", ok = "fine" },
  jwt = "aaaaaaaaaaaaaaaaaaaaaaaa.bbbbbbbbbbbbbbbbbbbbbbbbbb.cccccccccccccccccccccccccc",
})
check("user code redacted", r["User Code"] == E.REDACTED)
check("pin redacted", r.pin == E.REDACTED)
check("level kept", r.level == "50")
check("nested token redacted", r.nested.token == E.REDACTED and r.nested.ok == "fine")
check("jwt-looking value redacted", r.jwt == E.REDACTED)
check("4-digit value under a plain key is kept", E.redact({ brightness = "1234" }).brightness == "1234")
local cyc = {}
cyc.self = cyc
check("cycle-safe", E.redact(cyc).self == E.REDACTED)

print("[4] bounding marks partial")
local long = E.build(
  { event_type = "trace.step", evidence_source = "instrumented", payload = { message = string.rep("m ", 500) } },
  ctx
)
check("string truncated", #long.payload.message == E.LIMITS.text)
check("quality partial", long.quality == "partial")

print("[5] priority")
check("initial lowest", E.priority("observation.initial") == 0)
check("change middle", E.priority("observation.change") == 1)
check("trace highest", E.priority("trace.start") == 2)

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
