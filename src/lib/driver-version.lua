--- Version parsing and comparison for SmartBuildOS driver releases.
---
--- Current releases use MMDDYYYY for the first package of a day, then append
--- .N for later updates that day. Older builds used YYYYMMDD.HHMMSS, with a
--- brief MAJOR.MINOR scheme in between. Current dated releases intentionally
--- sort after both older schemes so returning to dates cannot be a downgrade.

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
  local date, revision = text:match("^(%d%d%d%d%d%d%d%d)%.(%d+)$")
  local suffixed = date ~= nil
  if date == nil then
    date = text:match("^(%d%d%d%d%d%d%d%d)$")
    revision = "0"
  end
  if date == nil or (suffixed and (revision == "0" or revision:match("^0") ~= nil)) then
    return nil
  end
  local month = tonumber(date:sub(1, 2))
  local day = tonumber(date:sub(3, 4))
  local year = tonumber(date:sub(5, 8))
  if not validDate(month, day, year) then
    return nil
  end
  return {
    kind = "current",
    date = year * 10000 + month * 100 + day,
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
  return { kind = "legacy", date = tonumber(date), time = tonumber(time), text = text }
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

  local major, minor = text:match("^(%d+)%.(%d)$")
  if major ~= nil and #major <= 3 then
    return { kind = "semantic", major = tonumber(major), minor = tonumber(minor), text = text }
  end

  local legacy = legacyTimestamp(text)
  if legacy ~= nil then
    return legacy
  end

  return nil, string.format("unsupported driver version '%s'", text)
end

--- The YYYYMMDD calendar date a parsed dated version encodes ("current"
--- already normalizes to it; "legacy" carries it directly).
local function normalizedDate(parsed)
  return parsed.date
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
    -- Cross-scheme: both dated schemes encode a real calendar date, so
    -- compare BY DATE — a kind-based rank made every MMDDYYYY bench stamp
    -- outrank every store release forever, which bricked store updates on
    -- any controller that ever saw a bench build (field-measured
    -- 2026-08-31: installed 08302026.2 refused 20260831.133204). On a
    -- date tie the current scheme wins, so the planned same-day scheme
    -- flip still is not a downgrade. Semantic keeps the old rank rule.
    local leftDate = left.kind ~= "semantic" and normalizedDate(left) or nil
    local rightDate = right.kind ~= "semantic" and normalizedDate(right) or nil
    if leftDate ~= nil and rightDate ~= nil then
      if leftDate ~= rightDate then
        return leftDate < rightDate and -1 or 1
      end
      return left.kind == "current" and 1 or -1
    end
    local rank = { legacy = 1, semantic = 2, current = 3 }
    return rank[left.kind] < rank[right.kind] and -1 or 1
  end

  local leftFirst = left.kind == "semantic" and left.major or left.date
  local rightFirst = right.kind == "semantic" and right.major or right.date
  if leftFirst ~= rightFirst then
    return leftFirst < rightFirst and -1 or 1
  end

  local leftSecond
  local rightSecond
  if left.kind == "current" then
    leftSecond = left.revision
    rightSecond = right.revision
  elseif left.kind == "semantic" then
    leftSecond = left.minor
    rightSecond = right.minor
  else
    leftSecond = left.time
    rightSecond = right.time
  end
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
