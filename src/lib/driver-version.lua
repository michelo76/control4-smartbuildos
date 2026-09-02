--- Version parsing and comparison for SmartBuildOS driver releases.
---
--- Current releases are YYYYMMDD.N: the calendar date, then the build number
--- within that day starting at 1. There is no bare form -- the first build of
--- a day is .1, not YYYYMMDD -- because a bare date is ambiguous against the
--- legacy scheme and buys nothing.
---
--- Older builds used YYYYMMDD.HHMMSS (or .HHMM). Both schemes therefore open
--- with the same eight digits, and they are told apart by the width of the
--- suffix: a build number is 1-3 digits, a timestamp is 4 or 6. That cap is
--- load-bearing. Without it "20260830.122926" reads as a perfectly valid date
--- plus revision 122926, and every legacy stamp would be silently promoted to
--- a current one -- which inverts ordering against real current builds, since
--- .122926 outranks any honest .N.

local M = {}

local function clean(value)
  local text = tostring(value or ""):match("^%s*(.-)%s*$")
  return text:gsub("^[vV]", "")
end

local function leapYear(year)
  return year % 400 == 0 or (year % 4 == 0 and year % 100 ~= 0)
end

local function validDate(month, day, year)
  if year < 1 or month < 1 or month > 12 or day < 1 then
    return false
  end
  local days = { 31, leapYear(year) and 29 or 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
  return day <= days[month]
end

local function currentDate(text)
  -- 1-3 digits, anchored. Four digits must fall through to legacy HHMM and six
  -- to legacy HHMMSS; see the note at the top of the file.
  local date, revision = text:match("^(%d%d%d%d%d%d%d%d)%.(%d%d?%d?)$")
  if date == nil or revision:match("^0") ~= nil then
    return nil
  end
  local year = tonumber(date:sub(1, 4))
  local month = tonumber(date:sub(5, 6))
  local day = tonumber(date:sub(7, 8))
  if not validDate(month, day, year) then
    return nil
  end
  return {
    kind = "current",
    date = tonumber(date),
    revision = tonumber(revision),
    text = text,
  }
end

local function legacyTimestamp(text)
  local date, time = text:match("^(%d%d%d%d%d%d%d%d)%.(%d+)$")
  if date == nil or (#time ~= 4 and #time ~= 6) then
    return nil
  end
  local year = tonumber(date:sub(1, 4))
  local month = tonumber(date:sub(5, 6))
  local day = tonumber(date:sub(7, 8))
  local hour = tonumber(time:sub(1, 2))
  local minute = tonumber(time:sub(3, 4))
  local second = #time == 6 and tonumber(time:sub(5, 6)) or 0
  if not validDate(month, day, year) or hour > 23 or minute > 59 or second > 59 then
    return nil
  end
  -- ⚠ NORMALISE HHMM TO SECONDS BEFORE COMPARING. As raw numbers 1234 (12:34)
  -- sorts BELOW 020000 (02:00), so a four-digit stamp from the afternoon read
  -- as older than a six-digit one from before dawn — an inversion inside the
  -- legacy scheme itself, which the updater would turn into refusing a newer
  -- build. Four digits are HHMM, so they scale by 100.
  local seconds = #time == 4 and tonumber(time) * 100 or tonumber(time)
  return { kind = "legacy", date = tonumber(date), time = seconds, text = text }
end

--- Parse a supported driver version.
--- @param value any
--- @return table|nil parsed
--- @return string|nil err
function M.parse(value)
  local text = clean(value)
  local dated = currentDate(text)
  if dated ~= nil then
    return dated
  end

  local legacy = legacyTimestamp(text)
  if legacy ~= nil then
    return legacy
  end

  return nil, string.format("unsupported driver version '%s'", text)
end

--- Compare two supported versions.
--- @return integer|nil result -1, 0, or 1
--- @return string|nil err
function M.compare(a, b)
  local left, leftErr = M.parse(a)
  if left == nil then
    return nil, leftErr
  end
  local right, rightErr = M.parse(b)
  if right == nil then
    return nil, rightErr
  end

  if left.kind ~= right.kind then
    -- Cross-scheme: both schemes encode a real calendar date, so compare BY
    -- DATE. A kind-based rank made every dated bench stamp outrank every store
    -- release forever, which bricked store updates on any controller that had
    -- ever seen a bench build (field-measured 2026-08-31: installed 08302026.2
    -- refused 20260831.133204). On a date tie the current scheme wins, so a
    -- same-day cutover is an upgrade rather than a downgrade -- and since
    -- current builds are only ever cut from today forward, every one of them
    -- outranks every legacy build in practice. The fleet migrates once.
    if left.date ~= right.date then
      return left.date < right.date and -1 or 1
    end
    return left.kind == "current" and 1 or -1
  end

  if left.date ~= right.date then
    return left.date < right.date and -1 or 1
  end

  local leftSecond = left.kind == "current" and left.revision or left.time
  local rightSecond = right.kind == "current" and right.revision or right.time
  if leftSecond == rightSecond then
    return 0
  end
  return leftSecond < rightSecond and -1 or 1
end

function M.isNewer(candidate, installed)
  local result, err = M.compare(candidate, installed)
  if result == nil then
    return false, err
  end
  return result > 0
end

return M
