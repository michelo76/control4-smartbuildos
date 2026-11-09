--- Guest Mode — iCalendar parser (pure).
---
--- Reads the booking feeds short-let platforms publish (Airbnb, Booking.com,
--- VRBO and anything else that speaks RFC 5545) and returns the VEVENTs as
--- plain tables. Only what a stay engine needs is kept: UID, SUMMARY,
--- DESCRIPTION, DTSTART, DTEND (or DURATION), STATUS. Everything is
--- tolerant: a feed that is half garbage still yields the events it can.
---
--- Dates come back STRUCTURED, never as epochs: the caller decides what an
--- all-day booking means in wall-clock terms (check-in 15:00, check-out
--- 11:00) and in which timezone. Shapes:
---   { y, m, d, allDay = true }                          VALUE=DATE
---   { y, m, d, hh, mi, ss, utc = true|false }           DATE-TIME (Z → utc)
--- A TZID parameter is recorded (`tzid`) but not interpreted: a floating or
--- zoned time is treated as controller-local, and the engine says so.

local M = {}

M.LIMITS = { events = 2000, text = 200 }

--- Joins folded lines (CRLF followed by one space or tab) and normalises
--- line endings.
function M.unfold(text)
  text = tostring(text or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
  text = text:gsub("\n[ \t]", "")
  return text
end

--- Unescapes TEXT values (\n \, \; \\).
local function unescape(s)
  return (tostring(s or ""):gsub("\\n", "\n"):gsub("\\N", "\n"):gsub("\\,", ","):gsub("\\;", ";"):gsub("\\\\", "\\"))
end

--- Parses a DATE or DATE-TIME value with its parameters.
--- @return table|nil
function M.parseDate(value, params)
  value = tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
  params = params or {}
  local y, m, d = value:match("^(%d%d%d%d)(%d%d)(%d%d)$")
  if y ~= nil then
    local out = { y = tonumber(y), m = tonumber(m), d = tonumber(d), allDay = true }
    if out.m < 1 or out.m > 12 or out.d < 1 or out.d > 31 then
      return nil
    end
    return out
  end
  local hh, mi, ss, z
  y, m, d, hh, mi, ss, z = value:match("^(%d%d%d%d)(%d%d)(%d%d)T(%d%d)(%d%d)(%d%d)(Z?)$")
  if y == nil then
    return nil
  end
  local out = {
    y = tonumber(y),
    m = tonumber(m),
    d = tonumber(d),
    hh = tonumber(hh),
    mi = tonumber(mi),
    ss = tonumber(ss),
    utc = z == "Z",
    allDay = false,
  }
  if params.TZID ~= nil then
    out.tzid = params.TZID
  end
  if out.m < 1 or out.m > 12 or out.d < 1 or out.d > 31 or out.hh > 23 or out.mi > 59 or out.ss > 60 then
    return nil
  end
  return out
end

--- Parses an RFC 5545 DURATION ("P2D", "PT3H", "P1DT12H") to seconds.
function M.parseDuration(value)
  value = tostring(value or "")
  local sign, body = value:match("^([%+%-]?)P(.*)$")
  if body == nil then
    return nil
  end
  local total = 0
  local weeks = body:match("^(%d+)W$")
  if weeks then
    total = tonumber(weeks) * 7 * 86400
  else
    local datePart, timePart = body:match("^([^T]*)T?(.*)$")
    local days = datePart:match("(%d+)D")
    if days then
      total = total + tonumber(days) * 86400
    end
    local h = timePart:match("(%d+)H")
    local mi = timePart:match("(%d+)M")
    local s = timePart:match("(%d+)S")
    total = total + (tonumber(h or 0) * 3600) + (tonumber(mi or 0) * 60) + tonumber(s or 0)
  end
  if sign == "-" then
    total = -total
  end
  return total
end

--- Splits "NAME;PARAM=VALUE;P2=V2:value" into name, params, value.
local function splitLine(line)
  local head, value = line:match("^([^:]+):(.*)$")
  if head == nil then
    return nil
  end
  local parts = {}
  for part in head:gmatch("[^;]+") do
    parts[#parts + 1] = part
  end
  local name = (parts[1] or ""):upper()
  local params = {}
  for i = 2, #parts do
    local k, v = parts[i]:match("^([^=]+)=(.*)$")
    if k then
      params[k:upper()] = v:gsub('^"(.*)"$', "%1")
    end
  end
  return name, params, value
end

--- Parses a whole calendar. Returns the events (bounded) and a summary of
--- what was skipped, never raising on bad input.
--- @return table events, table report { total, cancelled, skipped, calendarName }
function M.parse(text)
  local events, report = {}, { total = 0, cancelled = 0, skipped = 0, calendarName = nil }
  if type(text) ~= "string" or text == "" then
    return events, report
  end
  local unfolded = M.unfold(text)
  local current = nil
  for line in unfolded:gmatch("[^\n]+") do
    local name, params, value = splitLine(line)
    if name ~= nil then
      if name == "BEGIN" and value:upper() == "VEVENT" then
        current = {}
      elseif name == "END" and value:upper() == "VEVENT" then
        if current ~= nil then
          report.total = report.total + 1
          if current.cancelled then
            report.cancelled = report.cancelled + 1
          elseif current.start == nil then
            report.skipped = report.skipped + 1
          else
            if current.finish == nil then
              if current.durationSeconds ~= nil then
                current.finish = { duration = current.durationSeconds }
              elseif current.start.allDay then
                -- An all-day event with no DTEND lasts one day (RFC 5545 §3.6.1).
                current.finish = { duration = 86400 }
              else
                current.finish = { duration = 0 }
              end
            end
            current.uid = current.uid or string.format("noid-%d", report.total)
            if #events < M.LIMITS.events then
              events[#events + 1] = current
            else
              report.skipped = report.skipped + 1
            end
          end
          current = nil
        end
      elseif name == "X-WR-CALNAME" and current == nil then
        report.calendarName = unescape(value):sub(1, M.LIMITS.text)
      elseif current ~= nil then
        if name == "UID" then
          current.uid = value:sub(1, M.LIMITS.text)
        elseif name == "SUMMARY" then
          current.summary = unescape(value):sub(1, M.LIMITS.text)
        elseif name == "DESCRIPTION" then
          current.description = unescape(value):sub(1, 1000)
        elseif name == "DTSTART" then
          current.start = M.parseDate(value, params)
        elseif name == "DTEND" then
          current.finish = M.parseDate(value, params)
        elseif name == "DURATION" then
          current.durationSeconds = M.parseDuration(value)
        elseif name == "STATUS" then
          current.cancelled = value:upper():find("CANCELLED", 1, true) ~= nil
        end
      end
    end
  end
  return events, report
end

--- Platform feeds mark owner blocks and unavailable dates as events too.
--- Those are not guests. Matched case-insensitively on the summary.
local BLOCK_WORDS = { "not available", "blocked", "unavailable", "closed", "owner", "maintenance" }

function M.isBlock(summary)
  local s = tostring(summary or ""):lower()
  for _, w in ipairs(BLOCK_WORDS) do
    if s:find(w, 1, true) then
      return true
    end
  end
  return false
end

--- A displayable guest name from what the platform gives: Airbnb says
--- "Reserved"; Booking.com and VRBO usually carry the guest's name.
function M.guestName(event)
  local s = tostring(event and event.summary or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if s == "" or s:lower() == "reserved" or s:lower():find("^airbnb") then
    return "Guest"
  end
  return s:sub(1, 80)
end

return M
