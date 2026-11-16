package.path = "src/?.lua;" .. package.path
local Ring = require("tracer.ring")
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
local function seqs(list)
  local out = {}
  for _, e in ipairs(list) do
    out[#out + 1] = e.seq
  end
  return table.concat(out, ",")
end

print("== capacity")
check("default capacity", Ring.new().capacity == Ring.LIMITS.capacity_default)
check("below minimum clamps", Ring.new(1).capacity == Ring.LIMITS.capacity_min)
check("above maximum clamps", Ring.new(1e9).capacity == Ring.LIMITS.capacity_max)
check("garbage clamps to default", Ring.new("x").capacity == Ring.LIMITS.capacity_default)

print("== push / recent")
local r = Ring.new(50)
check("empty latest nil", r:latest() == nil and r:count() == 0)
for i = 1, 60 do
  r:push({ t = 1000 + i, device_id = (i % 3) + 1, event_name = "e" .. i })
end
check("size capped at capacity", r:count() == 50, r:count())
check("seq keeps counting past capacity", r.seq == 60)
check("evicted counted", r.evicted == 10, r.evicted)
check("latest is newest", r:latest().seq == 60)
check("recent(3) chronological", seqs(r:recent(3)) == "58,59,60", seqs(r:recent(3)))
check("recent(all) starts at the oldest kept", r:recent(50)[1].seq == 11)
check("recent(more than held) is bounded", #r:recent(500) == 50)
check("recent(0) empty", #r:recent(0) == 0)

print("== filters")
local dev1 = r:forDevice(1, 5)
check("forDevice newest 5 of device 1", #dev1 == 5 and dev1[#dev1].device_id == 1)
local since = r:since(57)
check("since(57) → 58,59,60", seqs(since) == "58,59,60", seqs(since))
check("since beyond newest → empty", #r:since(60) == 0)
local win = r:window(1060, 2)
check("window(t, 2s) → the last three timestamps", seqs(win) == "58,59,60", seqs(win))

print("== resize")
-- Capacities stay within the clamp range (50..2000) so the arithmetic is real.
local g = Ring.new(60)
for i = 1, 70 do
  g:push({ t = 5000 + i })
end
g:resize(50)
check("shrink keeps the newest 50", g:count() == 50 and g.capacity == 50 and g:recent(50)[1].seq == 21)
g:push({ t = 6000 })
check("push after shrink evicts the oldest", g:recent(50)[1].seq == 22 and g.seq == 71 and g:count() == 50)
g:resize(100)
check("grow keeps everything", g:count() == 50 and g.capacity == 100)
g:push({ t = 6001 })
check("push after grow adds without eviction", g:count() == 51 and g:latest().seq == 72)
check(
  "resize to the same capacity is a no-op",
  (function()
    g:resize(100)
    return g:count() == 51 and g:latest().seq == 72
  end)()
)

print("== serialize / restore")
local doc = g:serialize()
check("doc has entries oldest first", #doc.entries == 51 and doc.entries[1].seq == 22 and doc.entries[51].seq == 72)
local r2, ok = Ring.restore(doc)
check("restore ok", ok == true and r2:count() == 51 and r2.capacity == 100)
check("restore resumes the sequence", r2.seq == 72)
r2:push({ t = 7000 })
check("next seq after restore is 73", r2:latest().seq == 73)
check("restore carries eviction count", r2.evicted == g.evicted)
local r3, ok3 = Ring.restore(doc, 50)
check(
  "restore with a smaller capacity keeps newest",
  ok3 and r3:count() == 50 and r3:recent(1)[1].seq == 72 and r3:recent(50)[1].seq == 23
)
local r4, ok4 = Ring.restore("corrupt")
check("corrupt doc → empty ring, not ok", ok4 == false and r4:count() == 0)
local r5, ok5 = Ring.restore({ entries = { "junk", { seq = 5 }, 7 } })
check("partly corrupt doc keeps the valid entries", ok5 and r5:count() == 1 and r5.seq == 5)

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
