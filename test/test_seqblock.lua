-- sbos.seqblock: persisted event sequence numbers must never repeat across
-- reloads, because the platform drops a repeated event id as a duplicate.
package.path = "src/?.lua;" .. package.path
local SeqBlock = require("sbos.seqblock")

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

local function newStore(initial)
  local data = { k = initial }
  return {
    data = data,
    writes = 0,
    get = function(self, key, default)
      local v = data[key]
      if v == nil then
        return default
      end
      return v
    end,
    set = function(self, key, value)
      self.writes = self.writes + 1
      data[key] = value
    end,
  }
end

-- The scheme seqblock replaced, kept here to show the failure it had.
local function oldScheme(store, key)
  local seq = 0
  return function()
    if seq == 0 then
      seq = tonumber(store:get(key, 0)) or 0
    end
    seq = seq + 1
    if seq % 25 == 1 then
      store:set(key, seq + 25)
    end
    return seq
  end
end

-- Runs `sessions` driver loads emitting `perSession[i]` events each and
-- reports whether any number was handed out twice.
local function run(factory, store, perSession)
  local seen, repeats, all = {}, 0, {}
  for _, n in ipairs(perSession) do
    local nextSeq = factory(store, "k")
    for _ = 1, n do
      local s = nextSeq()
      if seen[s] then
        repeats = repeats + 1
      end
      seen[s] = true
      all[#all + 1] = s
    end
  end
  return repeats, all
end

print("[1] the old scheme repeats numbers after two short reloads (the bench failure)")
do
  -- Sessions of 1, 50, 15, 5 and 5 events: the bench's Flight Recorder
  -- stored 1, then 27..76, then 102..116, and every reload after began at 102.
  local repeats, all = run(oldScheme, newStore(nil), { 1, 50, 15, 5, 5 })
  check("old scheme repeats", repeats > 0, repeats)
  check(
    "old scheme restarts at 102 each reload",
    all[52] == 102 and all[67] == 102 and all[72] == 102,
    tostring(all[52]) .. "," .. tostring(all[67])
  )
end

print("[2] seqblock never repeats, however short the sessions")
do
  for _, pattern in ipairs({
    { 1, 1, 1, 1, 1, 1 },
    { 3, 24, 25, 26, 1, 50, 2 },
    { 100, 7, 0, 7, 0, 30 },
  }) do
    local repeats, all = run(SeqBlock.new, newStore(nil), pattern)
    local mono = true
    for i = 2, #all do
      if all[i] <= all[i - 1] then
        mono = false
      end
    end
    check("no repeats for " .. table.concat(pattern, ","), repeats == 0, repeats)
    check("strictly increasing for " .. table.concat(pattern, ","), mono)
  end
end

print("[3] the stored mark always covers every number handed out")
do
  local store = newStore(nil)
  local nextSeq = SeqBlock.new(store, "k")
  local ok = true
  for _ = 1, 200 do
    local s = nextSeq()
    if store.data.k < s then
      ok = false
    end
  end
  check("mark >= last number", ok)
  check("writes are batched (about one per 26 events)", store.writes <= 9, store.writes)
end

print("[4] upgrading from a mark the old scheme wrote skips past its unrecorded numbers")
do
  -- The bench: the old scheme stored 101 and then handed out up to 116
  -- (and could have reached 125) without moving the mark.
  local store = newStore(101)
  local first = SeqBlock.new(store, "k")()
  check("first number after upgrade is above 125", first > 125, first)
  local store2 = newStore(26) -- Usage Analytics: stored 26, used up to 32
  check("usage analytics mark 26 -> above 50", SeqBlock.new(store2, "k")() > 50)
end

print("[5] a fresh install starts at 1")
do
  check("starts at 1", SeqBlock.new(newStore(nil), "k")() == 1)
end

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
