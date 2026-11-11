--- Guest Mode — per-stay PIN generator (pure, injected randomness).
---
--- Produces a numeric code of 4..8 digits that a dealer would accept on a
--- keypad lock: no single repeated digit (1111), no straight run up or
--- down (1234, 8765), no all-even/all-odd pairs pattern like 1212, and
--- never equal to the previous code. The driver only EXPOSES the code as a
--- variable; it never programs a lock (lock user-code commands are not in
--- the documentation we hold).

local M = {}

M.MIN = 4
M.MAX = 8

local function isRun(s)
  local up, down = true, true
  for i = 2, #s do
    local a, b = tonumber(s:sub(i - 1, i - 1)), tonumber(s:sub(i, i))
    if b ~= (a + 1) % 10 then
      up = false
    end
    if b ~= (a - 1 + 10) % 10 then
      down = false
    end
  end
  return up or down
end

local function isRepeat(s)
  -- (Lua patterns cannot quantify a back-reference, so count by hand.)
  for i = 2, #s do
    if s:sub(i, i) ~= s:sub(1, 1) then
      return false
    end
  end
  return #s > 0
end

local function isAlternating(s)
  if #s < 4 then
    return false
  end
  local a, b = s:sub(1, 1), s:sub(2, 2)
  if a == b then
    return false
  end
  for i = 1, #s do
    local want = (i % 2 == 1) and a or b
    if s:sub(i, i) ~= want then
      return false
    end
  end
  return true
end

--- True when the code is acceptable.
function M.isAcceptable(code, previous)
  code = tostring(code or "")
  if not code:match("^%d+$") or #code < M.MIN or #code > M.MAX then
    return false
  end
  if isRepeat(code) or isRun(code) or isAlternating(code) then
    return false
  end
  if previous ~= nil and code == tostring(previous) then
    return false
  end
  return true
end

--- @param length number 4..8
--- @param random fun(min, max):number  injected (math.random by default)
--- @param previous string|nil
function M.generate(length, random, previous)
  length = math.max(M.MIN, math.min(M.MAX, tonumber(length) or 6))
  random = random or math.random
  for _ = 1, 200 do
    local digits = {}
    for i = 1, length do
      digits[i] = tostring(random(0, 9))
    end
    local code = table.concat(digits)
    if M.isAcceptable(code, previous) then
      return code
    end
  end
  -- A hostile random source: fall back to a deterministic acceptable code.
  local fallback = ("2580" .. "3691"):sub(1, length)
  if fallback == tostring(previous) then
    fallback = ("1470" .. "2583"):sub(1, length)
  end
  return fallback
end

return M
