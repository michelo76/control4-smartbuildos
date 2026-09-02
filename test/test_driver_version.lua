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

check("later calendar day is newer", comparison("20260831.1", "20260830.99") == 1)
check("the day's second build is newer than its first", comparison("20260830.2", "20260830.1") == 1)
check("multi-digit update numbers compare numerically", comparison("20260830.10", "20260830.9") == 1)
check("v-prefixed date is accepted", comparison("v20260830.5", "20260830.5") == 0)
check("dated releases supersede legacy timestamps", comparison("20260830.1", "20260830.235959") == 1)
check("legacy timestamps still compare internally", comparison("20260830.123457", "20260830.123456") == 1)

-- The suffix-width cap. Under YYYYMMDD a legacy stamp is a syntactically
-- perfect date-plus-revision, so only the digit count keeps the two schemes
-- apart. If these regress, every legacy build is promoted to a current one and
-- outranks real .N releases forever.
local parsed, err = version.parse("20260830.122926")
check("six-digit suffix stays a legacy timestamp", parsed ~= nil and parsed.kind == "legacy", err)
parsed, err = version.parse("20260830.1229")
check("four-digit suffix stays a legacy HHMM timestamp", parsed ~= nil and parsed.kind == "legacy", err)
parsed, err = version.parse("20260830.999")
check("three-digit suffix is a current build number", parsed ~= nil and parsed.kind == "current", err)
check("a current build outranks a same-day legacy stamp", version.isNewer("20260830.1", "20260830.122926"))

parsed, err = version.parse("20260830")
check("the bare date form is rejected", parsed == nil and err ~= nil, err)
parsed, err = version.parse("20260230.1")
check("invalid calendar dates are rejected", parsed == nil and err ~= nil, err)
parsed, err = version.parse("20260830.01")
check("zero-padded update suffixes are rejected", parsed == nil and err ~= nil, err)
parsed, err = version.parse("20260830.0")
check("zero update suffix is rejected", parsed == nil and err ~= nil, err)
parsed, err = version.parse("1.0")
check("the retired X.Y scheme is no longer parsed", parsed == nil and err ~= nil, err)
parsed, err = version.parse("banana")
check("invalid versions are rejected", parsed == nil and err ~= nil, err)

-- Field regression 2026-08-31: an earlier dated build must never outrank a
-- LATER-dated release — the kind-rank rule bricked store updates on any
-- controller that had ever seen a bench build.
check("later legacy beats earlier dated build", version.isNewer("20260831.133204", "20260830.2"))
check("earlier dated build does not beat later legacy", not version.isNewer("20260830.2", "20260831.133204"))
check("same-day scheme flip is an upgrade", version.isNewer("20260831.1", "20260831.235959"))

print("\n[9] HHMM and HHMMSS are the SAME clock and must compare as one")
-- As raw numbers 1234 (12:34) sorts below 020000 (02:00), so an afternoon
-- four-digit stamp read as OLDER than a pre-dawn six-digit one. Both the
-- driver and the platform comparator had this; found 2026-09-01 in review.
check("12:34 is later than 02:00", comparison("20260820.1234", "20260820.020000") == 1)
check("and not the other way round", comparison("20260820.020000", "20260820.1234") == -1)
check("the same minute written both ways is EQUAL", comparison("20260820.0234", "20260820.023400") == 0)
check("ordinary same-width case still holds", comparison("20260820.1235", "20260820.1234") == 1)

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
