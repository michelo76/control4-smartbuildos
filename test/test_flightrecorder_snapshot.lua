package.path = "src/?.lua;" .. package.path
local S = require("flightrecorder.snapshot")
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

print("[1] document shape, redaction, warnings")
local doc = S.build({
  job_id = "j1",
  request_id = "r1",
  requested_by = "tech",
  now_iso = "2026-10-22T00:00:00Z",
  agent = { version = "1", token = "SHOULD_NOT_APPEAR" },
  module = { version = "2" },
  config = {
    version = 7,
    enabled = true,
    budgets = { max_sources = 10 },
    exclusions = {},
    privacy = { string_values = "flag" },
    sources = { { id = "a", kind = "device_variable", device_id = 1, variable = "X", label = "X", enabled = true } },
  },
  observations = {
    { source_id = "a", value = 1 },
    { source_id = "b", value = "User Code 1234", ["user code"] = "1234" },
  },
  recent = {},
  warnings = { "one" },
})
check("kind + not a backup", doc.kind == "flight_recorder_snapshot" and doc.not_a_backup == true)
check("agent token redacted", doc.agent.token == E.REDACTED)
check("observation sensitive key redacted", doc.observations[2]["user code"] == E.REDACTED)
check(
  "queue warning added when absent",
  doc.warnings[2] ~= nil and doc.warnings[2]:find("queue health unavailable") ~= nil
)
check("configuration sources copied", #doc.configuration.sources == 1 and doc.configuration.version == 7)

print("[2] size bound trims recent then observations and says so")
local recent, obs = {}, {}
for i = 1, 100 do
  recent[i] = { i = i, text = string.rep("r ", 300) }
end
for i = 1, 200 do
  obs[i] = { i = i, text = string.rep("o ", 300) }
end
local big =
  S.build({ job_id = "j2", now_iso = "t", config = { sources = {} }, observations = obs, recent = recent, queue = {} })
check("under the limit", E.approxSize(big, 0, 1e9) <= S.LIMITS.max_bytes)
check("recent trimmed first", big.truncation.recent_events > 0)
check("truncation warning present", big.warnings[#big.warnings]:find("truncated") ~= nil)
check("limit counts beyond caps are reported", S.build({
  job_id = "j3",
  now_iso = "t",
  config = { sources = {} },
  observations = {},
  recent = (function()
    local r = {}
    for i = 1, 150 do
      r[i] = { i = i }
    end
    return r
  end)(),
  queue = {},
}).truncation.recent_events >= 50)

print("[3] job lifecycle")
local job = S.newJob("j1", "r1", "tech", 100)
check("queued", job.status == "queued")
check("running", S.transition(job, "running", 101) and job.status == "running")
check("bad status refused", S.transition(job, "weird", 102) == false)
check("failed keeps reason", S.transition(job, "failed", 103, "boom") and job.error == "boom")

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
