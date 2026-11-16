package.path = "src/?.lua;" .. package.path
local Pin = require("guestmode.pin")
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

print("== acceptability")
check("repeat refused", Pin.isAcceptable("1111") == false and Pin.isAcceptable("777777") == false)
check(
  "runs refused",
  Pin.isAcceptable("1234") == false and Pin.isAcceptable("8765") == false and Pin.isAcceptable("9012") == false
)
check("alternating refused", Pin.isAcceptable("1212") == false and Pin.isAcceptable("383838") == false)
check("ordinary accepted", Pin.isAcceptable("2580") == true and Pin.isAcceptable("40713") == true)
check("length bounds", Pin.isAcceptable("123") == false and Pin.isAcceptable("250814736") == false)
check("non-digits refused", Pin.isAcceptable("12a4") == false)
check("same as previous refused", Pin.isAcceptable("2580", "2580") == false)

print("== generate")
local seq = { 1, 1, 1, 1, 1, 2, 3, 4, 2, 5, 8, 0 }
local i = 0
local function scripted(min, max)
  i = i + 1
  return seq[i] or 7
end
local code = Pin.generate(4, scripted)
check("skips 1111 and 1234, returns 2580", code == "2580", code)
check("length clamps 4..8", #Pin.generate(2, math.random) == 4 and #Pin.generate(12, math.random) == 8)
local ok = true
for _ = 1, 200 do
  local c = Pin.generate(6, math.random)
  if not Pin.isAcceptable(c) then
    ok = false
  end
end
check("200 random codes all acceptable", ok)
local hostile = Pin.generate(4, function()
  return 1
end)
check("hostile random source → deterministic acceptable fallback", Pin.isAcceptable(hostile) and hostile == "2580")
local hostile2 = Pin.generate(4, function()
  return 1
end, "2580")
check("fallback never equals previous", hostile2 ~= "2580" and Pin.isAcceptable(hostile2, "2580"))
check("previous avoided by generator", Pin.generate(4, function(a, b)
  local c = (i % 2 == 0) and 2 or 5
  i = i + 1
  return c
end, "2525") ~= "2525")

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
