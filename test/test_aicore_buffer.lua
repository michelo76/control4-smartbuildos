-- aicore.buffer (pure): critical-only, bounded, persisted, dedup by event
-- id, least-severe-oldest eviction with counted drops, ordered drain.
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

local Buffer = require("aicore.buffer")

local store = {}
local io = {
  load = function()
    return store.doc
  end,
  save = function(doc)
    store.doc = doc
    store.saves = (store.saves or 0) + 1
  end,
}
local seq = 0
local function env(severity)
  seq = seq + 1
  return { event_id = "ai_core:1:nb:" .. seq, severity = severity, sequence = seq }
end

print("[1] critical only")
local b = Buffer.new(io, 5)
check("info is not held", b:push(env("info")) == "not_critical" and b:depth() == 0)
check("notice is not held", b:push(env("notice")) == "not_critical")
check("warning is held", b:push(env("warning")) == "held")
check("error is held", b:push(env("error")) == "held")
check("persisted on every change", store.doc and #store.doc.items == 2)

print("[2] dedup by event id")
local again = { event_id = store.doc.items[1].event_id, severity = "warning" }
check("the same id twice → duplicate", b:push(again) == "duplicate" and b:depth() == 2)

print("[3] bounded: least severe, oldest first; counted")
b:push(env("critical"))
b:push(env("warning"))
b:push(env("error")) -- full: 5
check("five held", b:depth() == 5)
local r = b:push(env("critical"))
check("a critical newcomer evicts the oldest warning", r == "held" and b:counters().dropped == 1)
local hasFirstWarning = false
for _, e in ipairs(b.items) do
  if e.sequence == 3 then
    hasFirstWarning = true
  end
end
check("the evicted one was the OLDEST warning", not hasFirstWarning)
local full = Buffer.new({}, 2)
full:push(env("error"))
full:push(env("error"))
check(
  "a newcomer less severe than everything held is the one dropped",
  full:push(env("warning")) == "dropped_new" and full:counters().dropped == 1 and full:depth() == 2
)

print("[4] survives a restart")
local again2 = Buffer.new(io, 5)
check("same items reloaded", again2:depth() == 5)
check("dropped count reloaded", again2:counters().dropped == 1)
check(
  "reloaded ids still dedup",
  again2:push({ event_id = again2.items[1].event_id, severity = "error" }) == "duplicate"
)

print("[5] drained oldest first")
local out = {}
local n = again2:drain(function(e)
  out[#out + 1] = e.sequence
end)
check("all handed over", n == 5 and again2:depth() == 0)
local ordered = true
for i = 2, #out do
  ordered = ordered and out[i] > out[i - 1]
end
check("in the order they were held (oldest first)", ordered)
check("flushed counted and persisted", again2:counters().flushed == 5 and #store.doc.items == 0)
local failing = Buffer.new({}, 3)
failing:push(env("error"))
failing:drain(function()
  error("send failed")
end)
check("a failed hand-over is counted as dropped", failing:counters().dropped == 1)
check("isCritical", Buffer.isCritical({ severity = "warning" }) and not Buffer.isCritical({ severity = "info" }))

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
