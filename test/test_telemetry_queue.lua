--- The telemetry queue's contracts: bounded, ordered, idempotent, honest.
---
--- Run: lua test/test_telemetry_queue.lua  (or via make test)

package.path = "src/?.lua;" .. package.path

local Queue = require("telemetry.queue")

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

--- A clock the tests can move.
local clock = { t = 1000000 }
local savedSeq = nil
local function newQueue(over)
  local opts = {
    now = function()
      return clock.t
    end,
    wallClock = function()
      return "iso:" .. clock.t
    end,
    keyPrefix = "ab12",
    loadSeq = function()
      return savedSeq
    end,
    saveSeq = function(s)
      savedSeq = s
    end,
  }
  for k, v in pairs(over or {}) do
    opts[k] = v
  end
  return Queue.new(opts)
end

print("[1] Events are stamped and keyed")
savedSeq = nil
local q = newQueue()
q:add("MEDIA", { subcategory = "Streaming", room_id = 5 })
q:add("CLIMATE", { value_numeric = 72 })
local batch = q:takeBatch()
check("both events taken", #batch == 2, #batch)
check("oldest first", batch[1].category == "MEDIA")
check("idempotency keys are prefix:seq", batch[1].idempotency_key == "ab12:1" and batch[2].idempotency_key == "ab12:2")
check("occurred_at is stamped", batch[1].occurred_at == "iso:1000000")
check("the transport-private timestamp is stripped", batch[1]._at == nil)
check("fields pass through", batch[1].room_id == 5 and batch[2].value_numeric == 72)

print("[2] The sequence survives a reload — keys must never repeat")
local q2 = newQueue() -- loadSeq returns savedSeq (currently 2)
q2:add("SYSTEM", {})
local b2 = q2:takeBatch()
check("a reloaded queue continues the sequence", b2[1].idempotency_key == "ab12:3", b2[1].idempotency_key)

print("[3] An event without a category is refused, not laundered")
local q3 = newQueue()
check("nil category refused", q3:add(nil, {}) == false)
check("empty category refused", q3:add("", {}) == false)
check("nothing queued", q3:depth() == 0)

print("[4] Drop-oldest at the cap, counted")
savedSeq = nil
local q4 = newQueue({ maxItems = 5 })
for i = 1, 8 do
  q4:add("DEVICE", { value_numeric = i })
end
check("depth holds at the cap", q4:depth() == 5, q4:depth())
check("drops are counted", q4:dropped() == 3, q4:dropped())
local b4 = q4:takeBatch()
check("the OLDEST were dropped — 4..8 remain", b4[1].value_numeric == 4 and b4[5].value_numeric == 8)

print("[5] Age pruning: a day-old event is history, not payload")
savedSeq = nil
local q5 = newQueue({ maxAgeSeconds = 100 })
q5:add("DEVICE", { value_numeric = 1 })
clock.t = clock.t + 200
q5:add("DEVICE", { value_numeric = 2 })
local b5 = q5:takeBatch()
check("stale event pruned", #b5 == 1 and b5[1].value_numeric == 2, #b5)
check("prune counts as a drop", q5:dropped() == 1)

print("[6] Batch size is capped; the rest waits")
savedSeq = nil
local q6 = newQueue({ maxBatch = 3 })
for i = 1, 7 do
  q6:add("ROOM", { value_numeric = i })
end
local b6 = q6:takeBatch()
check("batch holds maxBatch", #b6 == 3)
check("remainder stays queued", q6:depth() == 4)

print("[7] A failed upload puts the batch back, in order, in front")
savedSeq = nil
local q7 = newQueue({ maxBatch = 2 })
for i = 1, 4 do
  q7:add("ROOM", { value_numeric = i })
end
local b7 = q7:takeBatch() -- takes 1,2 ; leaves 3,4
q7:putBack(b7)
local b7b = q7:takeBatch()
check("returned batch leads the queue again", b7b[1].value_numeric == 1 and b7b[2].value_numeric == 2)
check("nothing lost across the round trip", q7:depth() == 2)

print("[8] putBack over a refilled queue drops the returned items' oldest first")
savedSeq = nil
local q8 = newQueue({ maxItems = 3, maxBatch = 2 })
q8:add("ROOM", { value_numeric = 1 })
q8:add("ROOM", { value_numeric = 2 })
local b8 = q8:takeBatch() -- queue empty, holding 1,2
q8:add("ROOM", { value_numeric = 3 })
q8:add("ROOM", { value_numeric = 4 })
q8:add("ROOM", { value_numeric = 5 }) -- queue full at 3,4,5
q8:putBack(b8) -- 1,2,3,4,5 -> cap 3 -> keep 3,4,5
check("cap holds after putBack", q8:depth() == 3, q8:depth())
local b8b = q8:takeBatch()
check("oldest gave way", b8b[1].value_numeric == 3 and b8b[2].value_numeric == 4)

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
