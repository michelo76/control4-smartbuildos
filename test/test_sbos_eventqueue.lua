-- Durable acknowledged event queue: ack semantics, partial rejection,
-- eviction with recorded ranges, journal checkpoints, corruption recovery.
package.path = "src/?.lua;" .. package.path
local Q = require("sbos.eventqueue")
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

local clock = { t = 1000 }
local saved = {}
local function newQ(over)
  local opts = {
    now = function()
      return clock.t
    end,
    random = function()
      return 0.5
    end,
    saveJournal = function(j)
      saved[#saved + 1] = j
    end,
  }
  for k, v in pairs(over or {}) do
    opts[k] = v
  end
  return Q.new(opts)
end
local seq = 0
local function ev(eventType, over)
  seq = seq + 1
  local fields = { event_type = eventType or "observation.change", evidence_source = "observed", payload = { v = seq } }
  for k, v in pairs(over or {}) do
    fields[k] = v
  end
  return (
    E.build(
      fields,
      { module_id = "flight_recorder", instance_id = "7", observed_at = "t", boot_id = "b", sequence = seq }
    )
  )
end

print("[1] take → ack removes only what the server accepted")
local q = newQ()
local a, b, c = ev(), ev(), ev()
q:push(a)
q:push(b)
q:push(c)
local batch = q:takeBatch()
check("three in flight", #batch == 3 and q:depth() == 3)
check("cannot take while in flight", select(2, q:takeBatch()) == "inflight")
q:ack({ accepted = { a.event_id }, rejected = { { event_id = b.event_id, reason = "malformed", permanent = true } } })
check("a gone, b dropped permanently, c retried", q:depth() == 1 and q.items[1].env.event_id == c.event_id)
check(
  "permanent rejection counted with reason",
  q.stats.rejected_permanent == 1 and q.stats.dropped_ranges[1].reason == "rejected:malformed"
)
check("acked counter", q.stats.acked == 1 and q.stats.last_ack_at == 1000)

print("[2] nack returns the batch to the front and backs off with jitter")
q = newQ()
local x, y = ev(), ev()
q:push(x)
q:push(y)
q:takeBatch()
q:nack("unreachable")
check("depth restored in order", q:depth() == 2 and q.items[1].env.event_id == x.event_id)
check("backoff 30 s + jitter(0 at 0.5)", q.backoffUntil == 1030, q.backoffUntil)
check("blocked by backoff", select(2, q:takeBatch()) == "backoff")
clock.t = 1031
check("sends again after backoff", q:takeBatch() ~= nil)
q:nack("again")
check("doubled", q.backoffUntil == 1031 + 60, q.backoffUntil)
q:resume(10)
check("resume staggers inside the window", q.backoffUntil == 1031 + 5)

print("[3] in-flight timeout is a failure")
q = newQ({ inflightTimeout = 90 })
q:push(ev())
q:takeBatch()
clock.t = clock.t + 91
check("expired", q:expireInflight() == true and q.inflight == nil and q.stats.upload_failures == 1)

print("[4] eviction prefers initial observations, records ranges")
q = newQ({ maxItems = 3 })
local t1 = ev("trace.start")
local i1 = ev("observation.initial")
local c1 = ev("observation.change")
q:push(t1)
q:push(i1)
q:push(c1)
local c2 = ev("observation.change")
q:push(c2)
check(
  "initial evicted first",
  q:depth() == 3 and q.items[1].env.event_id == t1.event_id and q.items[2].env.event_id == c1.event_id
)
check("dropped counted", q.stats.dropped == 1 and q.stats.dropped_ranges[1].from_seq == i1.sequence)
local c3 = ev("observation.change")
q:push(c3)
check("then the oldest change", q.items[1].env.event_id == t1.event_id and q.stats.dropped == 2)
check(
  "health reports near_limit (and the drop count)",
  q:health().limit_status == "near_limit" and q:health().dropped == 2
)
check(
  "contiguous drops merge into one range",
  (function()
    local qq = newQ({ maxItems = 1 })
    local e1, e2, e3 = ev("observation.initial"), ev("observation.initial"), ev("observation.initial")
    qq:push(e1)
    qq:push(e2)
    qq:push(e3)
    return #qq.stats.dropped_ranges == 1 and qq.stats.dropped_ranges[1].count == 2
  end)()
)

print("[5] priority ordering in a batch")
q = newQ({ maxBatch = 2 })
local o1, tr, o2 = ev("observation.change"), ev("trace.step"), ev("observation.change")
q:push(o1)
q:push(tr)
q:push(o2)
local bt = q:takeBatch()
check("trace first, then oldest observation", bt[1].event_id == tr.event_id and bt[2].event_id == o1.event_id)

print("[6] journal checkpoints are rate-limited and restore")
saved = {}
clock.t = 5000
q = newQ({ checkpointEvery = 3, checkpointSeconds = 30 })
q:push(ev())
check("no save after one push", q:checkpoint() == false and #saved == 0)
q:push(ev())
q:push(ev())
check("saved after 3 pushes", q:checkpoint() == true and #saved == 1)
q:push(ev())
clock.t = 5031
check("saved after 30 s", q:checkpoint() == true and #saved == 2)
local restored = Q.restore(saved[2], {
  now = function()
    return clock.t
  end,
})
check("restored depth", restored:depth() == 4, restored:depth())
check("restored stats", restored.stats.pushed == 4)
local corrupt = Q.restore({ v = 99 }, {
  now = function()
    return clock.t
  end,
})
check("corrupt journal → empty + flagged", corrupt:depth() == 0 and corrupt.stats.journal_recovered == true)
local half = Q.restore({ v = 1, items = { saved[2].items[1], { not_an = "event" } } }, {
  now = function()
    return clock.t
  end,
})
check(
  "partially corrupt journal keeps the valid events and counts the rest",
  half:depth() == 1 and half.stats.dropped == 1 and half.stats.journal_recovered
)
check(
  "in-flight events are journaled",
  (function()
    local qq = newQ()
    qq:push(ev())
    qq:takeBatch()
    return #qq:journal().items == 1
  end)()
)

print("[7] refusals never evict")
q = newQ({ maxItems = 1 })
q:push(ev())
local okBad, whyBad = q:push("junk")
check("invalid refused", okBad == false and whyBad == "malformed" and q:depth() == 1)

print("[8] budgets lower only, within floors")
q = newQ()
q:applyBudget({ max_items = 10, max_bytes = 1, max_batch = 1000 })
check("items lowered to the floor", q.maxItems == 50)
check("bytes floored", q.maxBytes == 16 * 1024)
check("batch capped at ceiling", q.maxBatch == 100)

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
