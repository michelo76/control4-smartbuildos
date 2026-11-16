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

print("[2b] the local history and the state of event capture")
local function historyOf(n)
  local h = {}
  for i = 1, n do
    h[i] = {
      seq = i,
      at = "2026-11-11T03:00:00Z",
      kind = "event",
      device_id = 20,
      line = "03:00:00  #" .. i .. "  Entry / Front Door: Opened",
    }
  end
  return h
end
local withHistory = S.build({
  job_id = "j-h",
  now_iso = "2026-11-11T03:00:05Z",
  config = { sources = {} },
  observations = {},
  recent = {},
  queue = {},
  history = historyOf(12),
  storms = { { device_id = 20, device_label = "Front Door", event_name = "Opened", count = 50, suppressed = 20 } },
  event_capture = { status = "capturing", subscriptions = 7, coverage = "7 subscriptions on 3 of 5 devices" },
})
check("history carried whole when it fits", #withHistory.history == 12 and withHistory.truncation.history == 0)
check("oldest first", withHistory.history[1].seq == 1 and withHistory.history[12].seq == 12)
check(
  "active storms and capture state carried",
  #withHistory.storms == 1 and withHistory.event_capture.subscriptions == 7
)
check(
  "the document says it covers them",
  (function()
    local n = 0
    for _, c in ipairs(withHistory.coverage) do
      if c:find("local history", 1, true) or c:find("event capture", 1, true) then
        n = n + 1
      end
    end
    return n == 2
  end)()
)
local long = S.build({
  job_id = "j-l",
  now_iso = "2026-11-11T03:00:05Z",
  config = { sources = {} },
  observations = {},
  recent = {},
  queue = {},
  history = historyOf(S.LIMITS.history + 40),
})
check(
  "beyond the limit the NEWEST entries are kept and the cut is counted",
  #long.history <= S.LIMITS.history
    and long.history[#long.history].seq == S.LIMITS.history + 40
    and long.truncation.history >= 40,
  long.truncation.history
)
check(
  "and the warning names it",
  long.warnings[#long.warnings]:find("older history entr", 1, true) ~= nil,
  long.warnings[#long.warnings]
)
local none =
  S.build({ job_id = "j-n", now_iso = "x", config = { sources = {} }, observations = {}, recent = {}, queue = {} })
check(
  "a snapshot with no history (an older caller) is still a document",
  #none.history == 0 and none.truncation.history == 0 and none.event_capture == nil and #none.storms == 0
)
local heavy = {}
for i = 1, 150 do
  heavy[i] = { seq = i, kind = "event", line = string.rep("x ", 350) }
end
local squeezed = S.build({
  job_id = "j-s",
  now_iso = "x",
  config = { sources = {} },
  observations = {},
  recent = { { event_type = "trace.end", label = "Good Night" } },
  queue = {},
  history = heavy,
})
check(
  "when the document is too large the oldest history goes first and the recent events stay",
  squeezed.truncation.history > 0
    and #squeezed.recent_events == 1
    and (#squeezed.history == 0 or squeezed.history[#squeezed.history].seq == 150),
  squeezed.truncation.history
)

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
