-- Guard: code the controller's Lua 5.1 cannot run, which LuaJIT (the
-- suite's usual interpreter) accepts without complaint. CI also runs the whole
-- suite on Lua 5.1; this guard names the line, and covers fallback branches no
-- test reaches.
--
-- Found when the suite first ran on Lua 5.1 (28 Nov 2026):
--   * math.random(0, 0x7fffffff) overflows Lua 5.1's int arithmetic and
--     returns negative numbers: the Agent's fallback module token was 32
--     zeros. A bound above 0x7fffffff (0xffffffff) fails with "interval is
--     empty": System Link's fallback UUID would have thrown. Use lib.randhex.
--   * goto and ::labels:: are Lua 5.2 syntax (a test used them).
--
-- Checks every .lua file under drivers/, src/ and test/ (vendor/ is
-- Control4's own and runs on their controllers as shipped).
--
-- Run from the driver root: make test

package.path = "src/?.lua;" .. package.path
local RandHex = require("lib.randhex")

local pass, fail = 0, 0
local function check(name, ok, detail)
  if ok then
    pass = pass + 1
    print("  ok   " .. name)
  else
    fail = fail + 1
    print("  FAIL " .. name .. (detail and ("  -> " .. tostring(detail)) or ""))
  end
end

print("[1] lib.randhex")
do
  math.randomseed(42)
  local seen = {}
  local allHex, allLen = true, true
  for _ = 1, 50 do
    local h = RandHex.hex(32)
    allLen = allLen and #h == 32
    allHex = allHex and h:match("^[0-9a-f]+$") ~= nil
    seen[h] = true
  end
  local distinct = 0
  for _ in pairs(seen) do
    distinct = distinct + 1
  end
  check("32 characters each time", allLen)
  check("lowercase hex only", allHex)
  check("not a constant (50 draws, 50 values)", distinct == 50, distinct)
  check("a zero token is not what comes out", not seen[string.rep("0", 32)])
  check("odd lengths are exact", #RandHex.hex(3) == 3 and #RandHex.hex(12) == 12)
  local u = RandHex.uuid4()
  check(
    "uuid4 has the v4 shape",
    u:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-4%x%x%x%-[89ab]%x%x%x%-%x+$") ~= nil and #u == 36,
    u
  )
end

print("[2] no Lua 5.2+ syntax or out-of-range math.random in drivers/, src/, test/")
local files = {}
local p = io.popen("find drivers src test -name '*.lua' -not -path '*/www/*' 2>/dev/null | sort")
for line in p:lines() do
  files[#files + 1] = line
end
p:close()
check("found Lua files", #files > 50, #files)

local LIMIT = 0x7ffffffe -- n - m + 1 must stay within a C int
local randomOffenders, gotoOffenders = {}, {}
for _, path in ipairs(files) do
  if path ~= "test/test_lua51_guard.lua" then
    local f = assert(io.open(path, "r"))
    local n = 0
    for line in f:lines() do
      n = n + 1
      local code = line:gsub("%-%-.*$", "")
      for args in code:gmatch("math%.random%(([^%)]*)%)") do
        local a, b = args:match("^%s*([^,]+)%s*,%s*([^,]+)%s*$")
        local lo, hi = tonumber(a or ""), tonumber(b or "")
        if lo and hi and (hi - lo) > LIMIT then
          randomOffenders[#randomOffenders + 1] = string.format("%s:%d math.random(%s)", path, n, args)
        end
      end
      if
        code:match("^%s*goto%s+[%a_]")
        or code:match("[;%s]goto%s+[%a_][%w_]*%s*$")
        or code:match("::[%a_][%w_]*::")
      then
        gotoOffenders[#gotoOffenders + 1] = string.format("%s:%d", path, n)
      end
    end
    f:close()
  end
end
check("math.random ranges fit Lua 5.1 (use lib.randhex)", #randomOffenders == 0, table.concat(randomOffenders, "; "))
check("no goto or ::labels::", #gotoOffenders == 0, table.concat(gotoOffenders, "; "))

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
