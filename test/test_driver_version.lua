local pass, fail = 0, 0
local function check(name, cond, detail)
  if cond then
    pass = pass + 1
    print(string.format("  ok   %s", name))
  else
    fail = fail + 1
    print(string.format("  FAIL %s%s", name, detail and ("  -> " .. tostring(detail)) or ""))
  end
end

local version = require("lib.driver-version")
local function comparison(a, b)
  local result, err = version.compare(a, b)
  check(a .. " compares with " .. b, err == nil, err)
  return result
end

check("later calendar day is newer", comparison("08312026", "08302026.99") == 1)
check("first same-day update is newer than the base", comparison("08302026.1", "08302026") == 1)
check("multi-digit update numbers compare numerically", comparison("08302026.10", "08302026.9") == 1)
check("v-prefixed date is accepted", comparison("v08302026.5", "08302026.5") == 0)
check("dated releases supersede the brief X.Y scheme", comparison("08302026", "1.0") == 1)
check("X.Y releases still supersede legacy timestamps", comparison("1.0", "20260830.123456") == 1)
check("three-digit legacy majors remain readable", comparison("123.4", "99.9") == 1)
check("dated releases supersede legacy timestamps", comparison("08302026", "20260830.235959") == 1)
check("legacy timestamps still compare internally", comparison("20260830.123457", "20260830.123456") == 1)
local parsed, err = version.parse("02302026")
check("invalid calendar dates are rejected", parsed == nil and err ~= nil, err)
parsed, err = version.parse("08302026.01")
check("zero-padded update suffixes are rejected", parsed == nil and err ~= nil, err)
parsed, err = version.parse("08302026.0")
check("zero update suffix is rejected", parsed == nil and err ~= nil, err)
parsed, err = version.parse("banana")
check("invalid versions are rejected", parsed == nil and err ~= nil, err)

-- Field regression 2026-08-31: a bench MMDDYYYY stamp must never outrank a
-- LATER-dated store release — the kind-rank rule bricked store updates on
-- any controller that ever saw a bench build.
check("later legacy beats earlier bench stamp", version.isNewer("20260831.133204", "08302026.2"))
check("earlier bench does not beat later legacy", not version.isNewer("08302026.2", "20260831.133204"))
check("same-day scheme flip is an upgrade", version.isNewer("08312026.1", "20260831.235959"))

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
