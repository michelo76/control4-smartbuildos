-- AI Core: the report hub (ai_core.report v1) and the driver operations
-- run_driver_query / invoke_driver_action. SIMULATION ONLY: src/aicore/
-- reports.lua directly, then the real driver under the scripted Agent of
-- test/aicore_harness.lua. The end-to-end run through the real Agent and two
-- reporters built on the real helper is test/emulator/ai_core_reports.lua.
--
--   [1] validation: closed kinds, version, keys, sizes, the platform's item
--       shapes; text cleaned, identifiers refused, `at` in epoch seconds
--   [2] the hub: answers, need_describe, per-kind rates, coalescing, the
--       ring and the instance bound, an unlicensed AI Core
--   [3] batching: <= 64 items, <= 16 KB, <= 3 a minute, settle outcomes,
--       the `dropped` key
--   [4] the driver: manifest, debug suppression, identity from the Agent's
--       stamp, answers, batches within the budget, restart → need_describe
--   [5] run_driver_query: the real answer relayed, refusals, 16 KB bound
--   [6] invoke_driver_action: completed only on the driver's ok; refusal,
--       declaration_changed, unverified target, timeout, duplicate, licence
--   [7] the operations' argument rules
--
-- Run from the driver root: make test

local H = require("aicore_harness")
require("drivers-common-public.global.lib") -- the encoder needs tostring_return_period
local Reports = require("aicore.reports")
local Operations = require("aicore.operations")

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

local HASH = "0123456789abcdef"
local EPOCH = 1800000000

local function describe(over)
  local d = {
    v = 1,
    kind = "describe",
    driver = {
      name = "SmartBuildOS Atmosphere",
      version = "20261118.1",
      sku = "SBOS_ATMOSPHERE",
      file = "smartbuildos-atmosphere.c4z",
    },
    summary = "Weather for the home.",
    controls = { { id = "forecast", label = "Forecast", class = "weather" } },
    vocabulary = { "forecast" },
    queries = {
      {
        id = "current_conditions",
        description = "Current weather.",
        params = { { name = "units", type = "enum", values = { "f", "c" }, required = false } },
      },
    },
    actions = {
      {
        id = "refresh_now",
        title = "Refresh now",
        description = "Fetches fresh data.",
        params = { { name = "level", type = "integer", min = 0, max = 100, required = true } },
        risk = "low",
      },
    },
    hash = HASH,
  }
  for k, v in pairs(over or {}) do
    d[k] = v
  end
  return d
end
local function state(facts)
  return { v = 1, kind = "state", facts = facts or { temperature_f = 71 } }
end
local function event(over)
  local e =
    { v = 1, kind = "event", type = "weather.alert", text = "Wind advisory", data = { level = "advisory" }, at = EPOCH }
  for k, v in pairs(over or {}) do
    e[k] = v
  end
  return e
end
local function diagnostic(over)
  local e = { v = 1, kind = "diagnostic", severity = "warning", code = "feed.stale", text = "No forecast", at = EPOCH }
  for k, v in pairs(over or {}) do
    e[k] = v
  end
  return e
end

-- ── [1] ─────────────────────────────────────────────────────────────────────
print("[1] validation")
do
  local V = Reports.validate
  for _, r in ipairs({ describe(), state(), event(), diagnostic() }) do
    local item, why = V("atmosphere", "321", r)
    check("a valid " .. r.kind .. " is accepted", item ~= nil, why)
  end
  local item = V("atmosphere", "321", event())
  check(
    "the item carries the STAMPED sender, v, kind and the kind's keys",
    item.from_module_id == "atmosphere" and item.from_instance_id == "321" and item.v == 1 and item.at == EPOCH
  )
  local _, why = V("atmosphere", "321", { v = 1, kind = "telemetry", facts = {} })
  check("an unknown kind is refused (invalid)", why == "invalid")
  _, why = V("atmosphere", "321", { v = 2, kind = "state", facts = {} })
  check("v = 2 → unsupported_version", why == "unsupported_version")
  _, why = V("atmosphere", "321", { kind = "state", facts = {} })
  check("no v → invalid", why == "invalid")
  local named = state()
  named.from_module_id = "pin_lock"
  _, why = V("atmosphere", "321", named)
  check("a report that names its own sender (from_module_id) is refused: unknown key", why == "invalid")
  local inst = event()
  inst.from_instance_id = "1"
  check("…from_instance_id too", select(2, V("atmosphere", "321", inst)) == "invalid")
  check("a sender id the Agent did not stamp validly is refused", select(2, V("", "321", state())) == "invalid")
  check("a non-numeric instance id is refused", select(2, V("atmosphere", "abc", state())) == "invalid")
  _, why = V("atmosphere", "321", describe({ summary = string.rep("x", 9000) }))
  check("a describe over 8 KB → too_large", why == "too_large", why)
  local vocab = {}
  for i = 1, 24 do
    vocab[i] = string.rep("w", 40)
  end
  check("24 vocabulary words of 40 are within bounds", V("atmosphere", "321", describe({ vocabulary = vocab })) ~= nil)
  local facts = {}
  for i = 1, 32 do
    facts["k" .. i] = string.rep("v", 120)
  end
  check("a state within its bounds is not too_large", V("atmosphere", "321", state(facts)) ~= nil)
  facts.k33 = 1
  check("33 facts → invalid", select(2, V("atmosphere", "321", state(facts))) == "invalid")
  check(
    "a missing required key → invalid",
    select(2, V("atmosphere", "321", { v = 1, kind = "event", type = "a.b", text = "x", at = EPOCH })) == "invalid"
  )
  check(
    "`at` as ISO text → invalid (epoch seconds only)",
    select(2, V("atmosphere", "321", event({ at = "2027-01-01T00:00:00Z" }))) == "invalid"
  )
  check("`at` fractional → invalid", select(2, V("atmosphere", "321", event({ at = EPOCH + 0.5 }))) == "invalid")
  check("event type pattern", select(2, V("atmosphere", "321", event({ type = "Bad Type" }))) == "invalid")
  check(
    "diagnostic severity closed",
    select(2, V("atmosphere", "321", diagnostic({ severity = "critical" }))) == "invalid"
  )
  check(
    "hash must be 16 lower-case hex",
    select(2, V("atmosphere", "321", describe({ hash = string.rep("a", 64) }))) == "invalid"
  )
  check(
    "…upper case refused",
    select(2, V("atmosphere", "321", describe({ hash = "0123456789ABCDEF" }))) == "invalid"
  )
  -- text is data: cleaned, never refused for it
  local dirty = V("atmosphere", "321", event({ text = "line1\nline2\t\226\128\174rtl\226\128\168end\1" }))
  check(
    "free text: newline/tab/controls → space, bidi removed, U+2028 → space",
    dirty ~= nil and dirty.text == "line1 line2 rtl end",
    dirty and dirty.text
  )
  local long = V("atmosphere", "321", event({ text = string.rep("\195\169", 300) }))
  check(
    "free text cut to 240 code points between characters",
    long and Reports._encode(long.text) and #long.text == 480
  )
  -- identifiers are refused, not repaired
  local d = describe()
  d.controls[1].id = "fore\ncast"
  check("a control id with a control character is refused", select(2, V("atmosphere", "321", d)) == "invalid")
  d = describe()
  d.queries[1].params[1].values = { "f", "c\1" }
  check("an enum value with a control character is refused", select(2, V("atmosphere", "321", d)) == "invalid")
  -- the platform's shapes (wire.ts): what it would refuse is refused here
  check(
    "empty summary refused (the platform requires text)",
    select(2, V("atmosphere", "321", describe({ summary = "" }))) == "invalid"
  )
  d = describe()
  d.queries[1].description = ""
  check("empty query description refused (platform requires it)", select(2, V("atmosphere", "321", d)) == "invalid")
  d = describe()
  d.actions[1].params[1].required = nil
  check("a param without `required` refused", select(2, V("atmosphere", "321", d)) == "invalid")
  d = describe()
  d.actions[1].params[1].max_len = 10
  check("max_len on an integer param refused", select(2, V("atmosphere", "321", d)) == "invalid")
  d = describe()
  d.actions[2] = d.actions[1]
  check("duplicate action ids refused", select(2, V("atmosphere", "321", d)) == "invalid")
  d = describe()
  d.actions[1].risk = "critical"
  check("risk closed (low|medium|high)", select(2, V("atmosphere", "321", d)) == "invalid")
  check(
    "sku may be empty",
    V("atmosphere", "321", describe({ driver = { name = "n", version = "1", sku = "", file = "f.c4z" } })) ~= nil
  )
  local s = V("atmosphere", "321", state({}))
  check(
    "an empty facts object encodes as {} (not [])",
    s and Reports._encode(s.facts) == "{}",
    s and Reports._encode(s.facts)
  )
end

-- ── [2] ─────────────────────────────────────────────────────────────────────
print("[2] the hub")
local clock = EPOCH
local function now()
  return clock
end
local CTX = { state = "ready", version = "20261118.000000" }
do
  local hub = Reports.new({ now = now })
  local a = hub:receive("atmosphere", "321", state(), CTX)
  check(
    "answer shape: accepted, ai_core{state, version}",
    a.accepted == true and a.ai_core.state == "ready" and a.ai_core.version == CTX.version
  )
  check("need_describe while no describe is held", a.need_describe == true)
  a = hub:receive("atmosphere", "321", describe(), CTX)
  check("describe accepted; need_describe no longer", a.accepted == true and a.need_describe == nil)
  a = hub:receive("atmosphere", "321", state({ temperature_f = 72 }), CTX)
  check("…and not on the next state", a.accepted and a.need_describe == nil)
  a = hub:receive("atmosphere", "321", describe(), CTX)
  check("the same describe within 10 min → rate_limited", a.accepted == false and a.reason == "rate_limited")
  a = hub:receive("atmosphere", "321", describe({ hash = "fedcba9876543210" }), CTX)
  check("a changed describe (new hash) is accepted at once", a.accepted == true)
  clock = clock + 601
  check(
    "the same hash after 10 min is accepted",
    hub:receive("atmosphere", "321", describe({ hash = "fedcba9876543210" }), CTX).accepted
  )
  local p = hub:picture("atmosphere", "321")
  check(
    "picture: hash, driver, declared ids, latest facts",
    p.describe_hash == "fedcba9876543210"
      and p.driver.file == "smartbuildos-atmosphere.c4z"
      and p.query_ids[1] == "current_conditions"
      and p.action_ids[1] == "refresh_now"
      and p.facts.temperature_f == 72
  )
  check("the picture keeps no describe text after upload (only pending)", p.pendingDescribe ~= nil)
  -- rates per instance
  clock = clock + 120
  local okN = 0
  for i = 1, 8 do
    if hub:receive("atmosphere", "321", state({ temperature_f = i }), CTX).accepted then
      okN = okN + 1
    end
  end
  check("state: 6 a minute per instance", okN == 6, okN)
  check("…coalesced: only the latest waits", hub:picture("atmosphere", "321").pendingState.facts.temperature_f == 6)
  okN = 0
  for _ = 1, 12 do
    if hub:receive("atmosphere", "321", event(), CTX).accepted then
      okN = okN + 1
    end
  end
  check("event: 10 a minute", okN == 10, okN)
  okN = 0
  for _ = 1, 8 do
    if hub:receive("atmosphere", "321", diagnostic(), CTX).accepted then
      okN = okN + 1
    end
  end
  check("diagnostic: 6 a minute", okN == 6, okN)
  check("another instance has its own window", hub:receive("atmosphere", "322", event(), CTX).accepted)
  local r = hub:receive("atmosphere", "321", { v = 1, kind = "bogus" }, CTX)
  check("unknown kind → accepted=false reason invalid", r.accepted == false and r.reason == "invalid")
  check("refusals are counted as dropped for the next batch (1 + 2 + 2 + 2 + 1)", hub.dropped == 8, hub.dropped)
  -- unlicensed
  local u = hub:receive("pin_lock", "400", state(), { state = "unlicensed", version = CTX.version })
  check(
    "unlicensed AI Core: answers accepted=false, state unlicensed, nothing kept",
    u.accepted == false
      and u.ai_core.state == "unlicensed"
      and hub:picture("pin_lock", "400") == nil
      and u.need_describe == nil
  )
  -- the ring
  local ring = Reports.new({ now = now })
  for i = 1, 25 do
    for _ = 1, 10 do
      ring:receive("m" .. string.format("%02d", i) .. "x", tostring(100 + i), event(), CTX)
    end
  end
  check("ring bounded at 200, oldest dropped and counted", #ring.ring == 200 and ring.counters.ring_dropped == 50)
  -- the instance bound
  local many = Reports.new({ now = now })
  for i = 1, 49 do
    clock = clock + 1
    many:receive("mod_" .. i, tostring(i), state(), CTX)
  end
  check(
    "48 instances held; the least recently heard is evicted (counted)",
    many.count == 48 and many.counters.evicted == 1 and many:picture("mod_1", "1") == nil
  )
  check(
    "an evicted module is asked for its describe again",
    many:receive("mod_1", "1", state(), CTX).need_describe == true
  )
end

-- ── [3] ─────────────────────────────────────────────────────────────────────
print("[3] batching")
do
  clock = EPOCH + 10000
  local hub = Reports.new({ now = now })
  hub:receive("atmosphere", "321", describe(), CTX)
  hub:receive("atmosphere", "321", state(), CTX)
  for i = 1, 10 do
    hub:receive("atmosphere", "321", event({ text = "e" .. i }), CTX)
  end
  local b = hub:takeBatch("aic-1")
  check(
    "one batch: describe, state, then events oldest first",
    b
      and #b.reports == 12
      and b.reports[1].kind == "describe"
      and b.reports[2].kind == "state"
      and b.reports[3].text == "e1"
  )
  check("no `dropped` key when nothing was dropped", b.dropped == nil)
  check("body = {request_id, reports}", b.request_id == "aic-1")
  check("one in flight at a time", hub:takeBatch("aic-2") == nil)
  hub:settle("delivered")
  check("nothing pending after delivery", hub:pendingCount() == 0 and hub:takeBatch("aic-3") == nil)
  -- budget: 3 a rolling minute
  clock = clock + 61
  local sent = 0
  for i = 1, 10 do
    clock = clock + 5
    hub:receive("mod_" .. i, tostring(i), state(), CTX)
    local x = hub:takeBatch("aic-b" .. i)
    if x then
      sent = sent + 1
      hub:settle("delivered")
    end
  end
  check("at most 3 batches in any minute", sent == 3, sent)
  clock = clock + 61
  check("the window refills", hub:takeBatch("aic-later") ~= nil)
  hub:settle("retry")
  check("retry: the items wait again", hub:pendingCount() >= 7)
  -- 64 items / 16 KB
  local big = Reports.new({ now = now })
  for i = 1, 30 do
    big:receive("mod_" .. i, tostring(i), state(), CTX)
    for _ = 1, 3 do
      big:receive("mod_" .. i, tostring(i), event({ text = string.rep("t", 200) }), CTX)
    end
  end
  local bb = big:takeBatch("aic-big")
  local raw = Reports._encode(bb)
  check("a batch holds at most 64 items", #bb.reports <= 64, #bb.reports)
  check("…and fits the 16 KB cloud body", #raw <= 16 * 1024, #raw)
  local before = big:pendingCount()
  local states, others = 0, 0
  for _, it in ipairs(bb.reports) do
    if it.kind == "state" then
      states = states + 1
    else
      others = others + 1
    end
  end
  big:settle("refused")
  check(
    "refused: events are dropped and counted; states wait again (ruling 23)",
    states > 0
      and others > 0
      and big.counters.items_dropped == others
      and big.dropped == others
      and big:pendingCount() == before + states,
    big.dropped
  )
  clock = clock + 61
  local nb = big:takeBatch("aic-next")
  check(
    "the next batch says how many were dropped since the last delivered one",
    nb and nb.dropped == others,
    nb and nb.dropped
  )
  big:settle("delivered")
  check("…and a delivered batch settles it", big.dropped == 0)
  check("cloud answers: ok → delivered", Reports.outcome({ status = "ok" }) == "delivered")
  check(
    "cloud_unreachable / rate_limited → retry",
    Reports.outcome({ status = "error", error_code = "cloud_unreachable" }) == "retry"
      and Reports.outcome({ status = "error", error_code = "rate_limited" }) == "retry"
  )
  check(
    "unsupported / invalid_args → refused",
    Reports.outcome({ status = "error", error_code = "unsupported" }) == "refused"
      and Reports.outcome({ status = "error", error_code = "invalid_args" }) == "refused"
  )
end

-- ── [3a] ────────────────────────────────────────────────────────────────────
print("[3a] a describe is uploaded only when the cloud accepted it (KI-51); backoff")
do
  clock = EPOCH + 50000
  local hub = Reports.new({ now = now })
  hub:receive("atmosphere", "321", describe(), CTX)
  hub:receive("atmosphere", "321", state(), CTX)
  hub:receive("atmosphere", "321", event({ text = "one" }), CTX)
  local b = hub:takeBatch("aic-r1")
  check("(the batch carries describe, state and an event)", b and #b.reports == 3 and b.reports[1].kind == "describe")
  hub:settle("refused")
  local m = hub:picture("atmosphere", "321")
  check(
    "refused: the describe and the state wait again (ruling 23); the event is dropped and counted",
    m.pendingDescribe ~= nil
      and m.pendingState ~= nil
      and #hub.ring == 0
      and hub.dropped == 1
      and hub.counters.items_dropped == 1,
    hub.dropped
  )
  check("…and pendingCount says so", hub:pendingCount() == 2)
  check("refused: no batch before the backoff (60 s)", hub:takeBatch("aic-r2") == nil)
  clock = clock + 59
  check("…still none at 59 s", hub:takeBatch("aic-r2") == nil)
  clock = clock + 1
  local again = hub:takeBatch("aic-r2")
  check(
    "at 60 s the next batch carries the same describe and state again, and the drop count",
    again
      and again.reports[1].kind == "describe"
      and again.reports[1].hash == HASH
      and again.reports[2].kind == "state"
      and again.dropped == 1,
    again and #again.reports
  )
  hub:settle("retry")
  check("a timeout or unreachable cloud keeps it too", m.pendingDescribe ~= nil)
  clock = clock + 119
  check("the second failure in a row waits 120 s", hub:takeBatch("aic-r3") == nil)
  clock = clock + 1
  check("…then goes", hub:takeBatch("aic-r3") ~= nil)
  -- a newer describe arrives while one is in flight: the newer one wins
  clock = clock + 601
  hub:receive("atmosphere", "321", describe({ hash = "fedcba9876543210", summary = "Newer." }), CTX)
  hub:settle("refused")
  check(
    "a newer describe that arrived meanwhile is kept, not the refused older one",
    m.pendingDescribe ~= nil and m.pendingDescribe.hash == "fedcba9876543210"
  )
  -- the same for state: a newer state that arrived while one was in flight wins
  clock = clock + 600
  hub:takeBatch("aic-r3s")
  hub:receive("atmosphere", "321", state({ temperature_f = 99 }), CTX)
  hub:settle("refused")
  check(
    "a newer state that arrived meanwhile is kept, not the refused older one (latest per instance)",
    m.pendingState ~= nil and m.pendingState.facts.temperature_f == 99
  )
  check(
    "AI Core still holds the describe hash (no need_describe while it waits)",
    hub:receive("atmosphere", "321", state(), CTX).need_describe == nil
  )
  clock = clock + 600
  hub:takeBatch("aic-r4")
  hub:settle("delivered")
  check(
    "delivered: nothing waits, the drop count is settled",
    hub:pendingCount() == 0 and m.pendingDescribe == nil and hub.dropped == 0
  )
  hub:receive("atmosphere", "321", event({ text = "two" }), CTX)
  check("delivered resets the backoff: the next batch may go at once", hub:takeBatch("aic-r5") ~= nil)
  hub:settle("delivered")

  -- Steady state against a cloud that refuses every batch (today's platform
  -- answers driver_reports `unsupported`), with the driver's 20 s timer.
  clock = EPOCH + 100000
  local refuser = Reports.new({ now = now })
  refuser:receive("atmosphere", "321", describe(), CTX)
  local times, withDescribe = {}, 0
  local start = clock
  for _ = 1, 3 * 180 do -- three hours of 20 s ticks
    clock = clock + 20
    local x = refuser:takeBatch("aic-s" .. #times)
    if x then
      times[#times + 1] = clock - start
      if x.reports[1] and x.reports[1].kind == "describe" then
        withDescribe = withDescribe + 1
      end
      refuser:receive("atmosphere", "321", event({ text = "tick" }), CTX)
      refuser:settle(Reports.outcome({ status = "error", error_code = "unsupported" }))
    end
  end
  local lastHour = 0
  for _, t in ipairs(times) do
    if t > 2 * 3600 then
      lastHour = lastHour + 1
    end
  end
  local gaps = {}
  for i = 2, math.min(#times, 8) do
    gaps[#gaps + 1] = times[i] - times[i - 1]
  end
  check(
    "a refusing cloud: gaps 60, 120, 240, 480, then every 600 s",
    table.concat(gaps, ",") == "60,120,240,480,600,600,600",
    table.concat(gaps, ",")
  )
  check("…6 batches an hour in the steady state", lastHour == 6, lastHour)
  check("…every one of them still carries the describe", withDescribe == #times, withDescribe .. "/" .. #times)
  check("…and the describe is never lost", refuser:picture("atmosphere", "321").pendingDescribe ~= nil)
end

-- ── [4] the driver ──────────────────────────────────────────────────────────
print("[4] the driver: manifest, identity, answers, batches, restart")
local A = H.agent
local batchTimes = {}
A.cloud = function(op)
  if op == "driver_reports" then
    batchTimes[#batchTimes + 1] = H.clock.now
  end
  return { status = "ok", http_status = "200", error_code = "ok", result = { accepted = true } }
end
H.agentPresent = true
H.load("DIT_ADDING")
H.advance(31000)
H.entitlement({ status = "AUTHORIZED_SUBSCRIPTION", enforcement = "enforce", features = "BASE,AI_ACTIONS" })
local reg = H.lastSent("SBOS_MODULE_REGISTER")
local manifest = JSON:decode(reg.params.manifest)
local advertises = false
for _, c in ipairs(manifest.capabilities or {}) do
  advertises = advertises or (c.id == "ai_core.report" and c.version == 1 and c.kind == "request")
end
check("the manifest advertises ai_core.report v1 (request)", advertises, reg.params.manifest)
check(
  "registers run_driver_query and invoke_driver_action",
  tostring(reg.params.commands):find("run_driver_query", 1, true)
    and tostring(reg.params.commands):find("invoke_driver_action", 1, true)
)
local sup = EC.suppressDebug or {}
check(
  "EC.suppressDebug covers the SBOS_MODULE_* frames AI Core receives",
  sup.SBOS_MODULE_REQUEST
    and sup.SBOS_MODULE_RESPONSE
    and sup.SBOS_MODULE_COMMAND
    and sup.SBOS_MODULE_CLOUD_RESPONSE
    and sup.SBOS_MODULE_DIRECTORY
)

local r = H.request("atmosphere", 321, "ai_core.report", state())
check("a report is answered ok", r and r.status == "ok", r and r.error_code)
local ans = r and r.result or {}
check("accepted, state ready", ans.accepted == true and ans.ai_core and ans.ai_core.state == "ready")
check(
  "ai_core.version = the driver_version AI Core registered with",
  ans.ai_core and ans.ai_core.version == reg.params.driver_version,
  ans.ai_core and ans.ai_core.version
)
check("need_describe: AI Core holds no describe for this module", ans.need_describe == true)
r = H.request("atmosphere", 321, "ai_core.report", describe())
check("the describe is accepted; need_describe gone", r.result.accepted == true and r.result.need_describe == nil)
r = H.request("atmosphere", 321, "ai_core.report", { v = 1, kind = "telemetry" })
check("unknown kind refused (invalid)", r.result.accepted == false and r.result.reason == "invalid")
r = H.request(
  "atmosphere",
  321,
  "ai_core.report",
  describe({ summary = string.rep("x", 9000), hash = "1111111111111111" })
)
check("oversize describe refused (too_large)", r.result.accepted == false and r.result.reason == "too_large")
local spoof = event()
spoof.from_module_id = "pin_lock"
r = H.request("atmosphere", 321, "ai_core.report", spoof)
check("a report naming another sender is refused", r.result.accepted == false and r.result.reason == "invalid")
H.request("mode_composer", 322, "ai_core.report", describe({ hash = "2222222222222222" }))
for i = 1, 5 do
  H.request("atmosphere", 321, "ai_core.report", event({ text = "a" .. i }))
  H.request("mode_composer", 322, "ai_core.report", diagnostic({ text = "m" .. i }))
end
H.advance(25000)
local batches = H.cloudOps("driver_reports")
check("a driver_reports batch went to the cloud", #batches >= 1, #batches)
local items = {}
for _, b in ipairs(batches) do
  for _, it in ipairs(b.body.reports or {}) do
    items[#items + 1] = it
  end
end
local bySender, spoofed = {}, false
for _, it in ipairs(items) do
  bySender[it.from_module_id .. "@" .. it.from_instance_id] = (
    bySender[it.from_module_id .. "@" .. it.from_instance_id] or 0
  ) + 1
  spoofed = spoofed or it.from_module_id == "pin_lock"
end
check(
  "items carry the Agent's stamp (atmosphere@321, mode_composer@322)",
  bySender["atmosphere@321"] and bySender["mode_composer@322"]
)
check("no item under a sender a report named", not spoofed)
check("every accepted report is in a batch (2 describes, 1 state, 5 events, 5 diagnostics)", #items == 13, #items)
check("the batch body says what was dropped (3 refused reports)", batches[1].body.dropped == 3, batches[1].body.dropped)
check(
  "the body keys are request_id, reports, dropped only",
  (function()
    for k in pairs(batches[1].body) do
      if k ~= "request_id" and k ~= "reports" and k ~= "dropped" then
        return false
      end
    end
    return true
  end)()
)
-- the budget, over five minutes of steady reporting from two modules
batchTimes = {}
for _ = 1, 30 do
  H.request("atmosphere", 321, "ai_core.report", event())
  H.request("mode_composer", 322, "ai_core.report", diagnostic())
  H.advance(10000)
end
local worst = 0
for i = 1, #batchTimes do
  local n = 0
  for j = i, #batchTimes do
    if batchTimes[j] - batchTimes[i] < 60000 then
      n = n + 1
    end
  end
  worst = math.max(worst, n)
end
check(
  "at most 3 driver_reports batches in any 60 s (budget)",
  worst <= 3 and #batchTimes >= 10,
  worst .. " in a minute, " .. #batchTimes .. " batches"
)
-- AI Core restart: nothing persisted → need_describe
H.load("DIT_UPDATING")
H.advance(31000)
r = H.request("atmosphere", 321, "ai_core.report", state({ temperature_f = 90 }))
check(
  "after an AI Core restart: need_describe on the next report",
  r.result.accepted == true and r.result.need_describe == true
)
check(
  "no describe was persisted",
  (function()
    for k in pairs(H.persisted) do
      if tostring(k):find("report") then
        return false
      end
    end
    return true
  end)()
)

-- ── [5] run_driver_query ────────────────────────────────────────────────────
print("[5] run_driver_query")
local QREF = "0d6f9a2e-5b1c-4c8e-9f00-123456789abc"
local AID = "1d6f9a2e-5b1c-4c8e-9f00-123456789abc"
local ROW = {
  module_id = "atmosphere",
  instance_id = "321",
  driver = "sbos.atmosphere",
  protocol = 2,
  status = "ready",
  stale = false,
  verified = true,
  capabilities = {
    { id = "ai.query", version = 1, kind = "request" },
    { id = "ai.action", version = 1, kind = "request" },
  },
}
A.modules = { ROW }
local asked = {}
local nextAnswer
A.busAnswer = function(to, capability, args, p)
  asked[#asked + 1] =
    { to = to, capability = capability, args = args, to_instance = p.to_instance, key = p.idempotency_key }
  return nextAnswer(capability, args)
end
local function lastOp(op)
  local l = H.cloudOps(op)
  return l[#l] and l[#l].body
end
nextAnswer = function()
  return "ok", { ok = true, data = { temperature = 71, condition = "Clear" } }
end
local states = H.operation("run_driver_query", {
  query_ref = QREF,
  module_id = "atmosphere",
  instance_id = "321",
  query_id = "current_conditions",
  params = { units = "f" },
})
check(
  "Executing, then Completed on the driver's answer",
  #states >= 2 and states[#states - 1].state == "Executing" and H.finalState(states) == "Completed",
  (function()
    local t = {}
    for _, x in ipairs(states) do
      t[#t + 1] = x.state
    end
    return table.concat(t, ",")
  end)()
)
check(
  "ai.query sent to the named instance with {query_id, params}",
  asked[#asked].capability == "ai.query"
    and asked[#asked].to == "atmosphere"
    and asked[#asked].to_instance == "321"
    and asked[#asked].args.query_id == "current_conditions"
    and asked[#asked].args.params.units == "f"
)
local qb = lastOp("driver_query_result")
check(
  "driver_query_result {query_ref, status completed, data}",
  qb and qb.query_ref == QREF and qb.status == "completed" and qb.data.temperature == 71 and qb.error_code == nil
)
check(
  "…its keys: request_id, query_ref, status, data",
  (function()
    for k in pairs(qb) do
      if k ~= "request_id" and k ~= "query_ref" and k ~= "status" and k ~= "data" then
        return false
      end
    end
    return true
  end)()
)
nextAnswer = function()
  return "ok", { ok = false, reason = "feed_down" }
end
states = H.operation(
  "run_driver_query",
  { query_ref = QREF, module_id = "atmosphere", instance_id = "321", query_id = "current_conditions", params = {} }
)
qb = lastOp("driver_query_result")
check(
  "the driver could not answer → failed internal_error, no data",
  H.finalState(states) == "Failed" and qb.status == "failed" and qb.error_code == "internal_error" and qb.data == nil
)
nextAnswer = function()
  return "error", { ok = false, reason = "unknown_query" }, "invalid_args"
end
H.operation(
  "run_driver_query",
  { query_ref = QREF, module_id = "atmosphere", instance_id = "321", query_id = "nope", params = {} }
)
qb = lastOp("driver_query_result")
check("the helper's refusal code is relayed (invalid_args)", qb.status == "failed" and qb.error_code == "invalid_args")
nextAnswer = function()
  return "ok", { ok = true, data = { blob = string.rep("x", 20000) } }
end
H.operation(
  "run_driver_query",
  { query_ref = QREF, module_id = "atmosphere", instance_id = "321", query_id = "current_conditions", params = {} }
)
qb = lastOp("driver_query_result")
check(
  "a 20 KB answer (bus ok, cloud body 16 KB) → failed payload_too_large, never cut",
  qb.status == "failed" and qb.error_code == "payload_too_large" and qb.data == nil
)
local n0 = #asked
H.operation(
  "run_driver_query",
  { query_ref = QREF, module_id = "usage_analytics", instance_id = "999", query_id = "x", params = {} }
)
qb = lastOp("driver_query_result")
check(
  "a module not in the directory → failed unknown_target, nothing asked",
  qb.error_code == "unknown_target" and #asked == n0
)

-- ── [6] invoke_driver_action ────────────────────────────────────────────────
print("[6] invoke_driver_action")
local ran = 0
nextAnswer = function(_, args)
  ran = ran + 1
  if args.declaration_hash ~= HASH then
    return "error", { ok = false, reason = "declaration_changed" }, "not_permitted"
  end
  return "ok", { ok = true, result_text = "Refresh started" }
end
local function invoke(over)
  local args = {
    ai_action_id = AID,
    module_id = "atmosphere",
    instance_id = "321",
    action_id = "refresh_now",
    params = { level = 5 },
    declaration_hash = HASH,
  }
  for k, v in pairs(over or {}) do
    args[k] = v
  end
  return H.operation("invoke_driver_action", args)
end
states = invoke()
local ab = lastOp("driver_action_result")
check("Completed only after the driver said ok", H.finalState(states) == "Completed" and ran == 1)
check(
  "ai.action sent with {action_id, params, ai_action_id, declaration_hash}",
  asked[#asked].capability == "ai.action"
    and asked[#asked].args.action_id == "refresh_now"
    and asked[#asked].args.params.level == 5
    and asked[#asked].args.ai_action_id == AID
    and asked[#asked].args.declaration_hash == HASH
)
check("…idempotency key = ai_action_id", asked[#asked].key == AID)
check(
  "driver_action_result completed with the driver's result_text",
  ab.ai_action_id == AID and ab.status == "completed" and ab.result_text == "Refresh started" and ab.error_code == nil
)
local nOps = #H.cloudOps("driver_action_result")
states = invoke()
check(
  "the same ai_action_id is never run twice (duplicate_request)",
  H.finalState(states) == "Failed" and ran == 1 and lastOp("driver_action_result").error_code == "duplicate_request"
)
check("…and its refusal is reported too", #H.cloudOps("driver_action_result") == nOps + 1)
states = invoke({ ai_action_id = "2d6f9a2e-5b1c-4c8e-9f00-123456789abc", declaration_hash = "ffffffffffffffff" })
ab = lastOp("driver_action_result")
check(
  "a changed declaration: failed not_permitted, result_text declaration_changed",
  H.finalState(states) == "Failed"
    and ab.status == "failed"
    and ab.error_code == "not_permitted"
    and ab.result_text == "declaration_changed"
)
nextAnswer = function()
  ran = ran + 1
  return "ok", { ok = false, result_text = "Provider refused the refresh" }
end
states = invoke({ ai_action_id = "3d6f9a2e-5b1c-4c8e-9f00-123456789abc" })
ab = lastOp("driver_action_result")
check(
  "the driver's refusal: failed, its words as result_text",
  H.finalState(states) == "Failed"
    and ab.status == "failed"
    and ab.error_code == "internal_error"
    and ab.result_text == "Provider refused the refresh"
)
-- Ruling 23: a handler that began work finishing later answers in_progress.
nextAnswer = function()
  ran = ran + 1
  return "ok", { ok = true, in_progress = true, result_text = "Activation started" }
end
states = invoke({ ai_action_id = "8d6f9a2e-5b1c-4c8e-9f00-123456789abc" })
ab = lastOp("driver_action_result")
check(
  "an in-progress answer: driver_action_result status started (never completed), its words, no error_code",
  ab.ai_action_id == "8d6f9a2e-5b1c-4c8e-9f00-123456789abc"
    and ab.status == "started"
    and ab.result_text == "Activation started"
    and ab.error_code == nil
)
check("…the command itself is done (Completed), its text says started", H.finalState(states) == "Completed")
check(
  "pure: actionResultBody in_progress → started; plain ok → completed",
  Reports.actionResultBody("r", AID, { status = "ok", result = { ok = true, in_progress = true } }).status == "started"
    and Reports.actionResultBody("r", AID, { status = "ok", result = { ok = true } }).status == "completed"
)
nextAnswer = function()
  ran = ran + 1
  return false -- never answers
end
states = invoke({ ai_action_id = "4d6f9a2e-5b1c-4c8e-9f00-123456789abc" })
check(
  "while the driver has not answered: Executing, nothing reported",
  H.finalState(states) == "Executing"
    and lastOp("driver_action_result").ai_action_id ~= "4d6f9a2e-5b1c-4c8e-9f00-123456789abc"
)
H.advance(21000)
ab = lastOp("driver_action_result")
check(
  "no answer: failed deadline_exceeded, 'outcome is unknown' — never completed",
  ab.ai_action_id == "4d6f9a2e-5b1c-4c8e-9f00-123456789abc"
    and ab.status == "failed"
    and ab.error_code == "deadline_exceeded"
    and ab.result_text:find("unknown") ~= nil
)
local ranBefore, askedBefore = ran, #asked
ROW.verified = false
states = invoke({ ai_action_id = "5d6f9a2e-5b1c-4c8e-9f00-123456789abc" })
ab = lastOp("driver_action_result")
check(
  "an unverified module: refused before anything is sent (not_permitted, target_unverified)",
  H.finalState(states) == "Failed"
    and ab.error_code == "not_permitted"
    and ab.result_text == "target_unverified"
    and #asked == askedBefore
    and ran == ranBefore
)
ROW.verified = true
ROW.stale = true
invoke({ ai_action_id = "6d6f9a2e-5b1c-4c8e-9f00-123456789abc" })
check(
  "a stale module: target_unavailable, nothing sent",
  lastOp("driver_action_result").error_code == "target_unavailable" and #asked == askedBefore
)
ROW.stale = false
H.entitlement({ status = "AUTHORIZED_SUBSCRIPTION", enforcement = "enforce", features = "BASE" })
states = invoke({ ai_action_id = "7d6f9a2e-5b1c-4c8e-9f00-123456789abc" })
ab = lastOp("driver_action_result")
check(
  "licence without AI_ACTIONS (enforced): refused, nothing sent",
  H.finalState(states) == "Failed"
    and ab.error_code == "not_permitted"
    and ab.result_text == "not_licensed"
    and #asked == askedBefore
)
H.entitlement({ status = "ENTITLEMENT_EXPIRED", enforcement = "enforce", features = "" })
r = H.request("atmosphere", 321, "ai_core.report", state({ temperature_f = 1 }))
check(
  "an unlicensed AI Core still answers: accepted=false, state unlicensed",
  r.result.accepted == false and r.result.ai_core.state == "unlicensed"
)
H.operation(
  "run_driver_query",
  { query_ref = QREF, module_id = "atmosphere", instance_id = "321", query_id = "current_conditions", params = {} }
)
check(
  "an unlicensed AI Core refuses queries (BASE), nothing sent",
  lastOp("driver_query_result").error_code == "not_permitted" and #asked == askedBefore
)
local nb0 = #H.cloudOps("driver_reports")
H.advance(70000)
check("…and uploads no batch while unlicensed", #H.cloudOps("driver_reports") == nb0)

-- ── [7] argument rules ──────────────────────────────────────────────────────
print("[7] the operations' argument rules")
do
  local P = Operations.parse
  local q = { query_ref = QREF, module_id = "atmosphere", instance_id = "321", query_id = "a", params = {} }
  check("run_driver_query parses", P("run_driver_query", q) ~= nil)
  local function with(base, k, v)
    local c = {}
    for x, y in pairs(base) do
      c[x] = y
    end
    c[k] = v
    return c
  end
  check("an unknown key refuses it", P("run_driver_query", with(q, "command", "x")) == nil)
  check("module_id ai_core refused", P("run_driver_query", with(q, "module_id", "ai_core")) == nil)
  check("query_ref must be a lower-case uuid", P("run_driver_query", with(q, "query_ref", QREF:upper())) == nil)
  check("instance_id digits only", P("run_driver_query", with(q, "instance_id", "12a")) == nil)
  check(
    "params: 7 keys refused",
    P("run_driver_query", with(q, "params", { a = 1, b = 1, c = 1, d = 1, e = 1, f = 1, g = 1 })) == nil
  )
  check("params: a nested table refused", P("run_driver_query", with(q, "params", { a = { 1 } })) == nil)
  check(
    "params: a string with a control character refused",
    P("run_driver_query", with(q, "params", { a = "x\n" })) == nil
  )
  check(
    "params: a string over 64 characters refused",
    P("run_driver_query", with(q, "params", { a = string.rep("x", 65) })) == nil
  )
  check("params absent → {}", next(P("run_driver_query", with(q, "params", nil)).params) == nil)
  local a = {
    ai_action_id = AID,
    module_id = "atmosphere",
    instance_id = "321",
    action_id = "a",
    params = {},
    declaration_hash = HASH,
  }
  check("invoke_driver_action parses", P("invoke_driver_action", a) ~= nil)
  check(
    "declaration_hash: 64 hex refused (16, the helper's fingerprint)",
    P("invoke_driver_action", with(a, "declaration_hash", string.rep("a", 64))) == nil
  )
  check("action_id pattern", P("invoke_driver_action", with(a, "action_id", "Refresh")) == nil)
  check(
    "no shell, no Lua, no device id: an extra key refuses it",
    P("invoke_driver_action", with(a, "device_id", 12)) == nil
  )
end

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
