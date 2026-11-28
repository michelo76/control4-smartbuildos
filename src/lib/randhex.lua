--- Random hex strings that work on the controller's Lua 5.1.
---
--- Lua 5.1's math.random(m, n) converts both bounds to a C int and computes
--- n - m + 1 in int. So math.random(0, 0x7fffffff) overflows and returns
--- negative numbers (formatted with %08x they came out as zeros: a module
--- token of 32 zeros), and any bound above 0x7fffffff, such as 0xffffffff,
--- fails with "interval is empty". LuaJIT, which the test suite used to run
--- on alone, handles both, so nothing showed until the suite ran on Lua 5.1
--- (28 Nov 2026). This builds the string 16 bits at a time instead.
---
--- Use it only as the fallback when C4:UUID("RANDOM") is not available: it is
--- only as good as math.random, which is not a secure generator.
local M = {}

--- `digits` lowercase hex characters from math.random.
--- @param digits number
--- @return string
function M.hex(digits)
  local parts = {}
  local n = 0
  while n < digits do
    parts[#parts + 1] = string.format("%04x", math.random(0, 0xffff))
    n = n + 4
  end
  return table.concat(parts):sub(1, digits)
end

--- A version 4 UUID string (8-4-4-4-12) built from M.hex.
--- @return string
function M.uuid4()
  local variant = ({ "8", "9", "a", "b" })[math.random(1, 4)]
  return string.format("%s-%s-4%s-%s%s-%s", M.hex(8), M.hex(4), M.hex(3), variant, M.hex(3), M.hex(12))
end

return M
