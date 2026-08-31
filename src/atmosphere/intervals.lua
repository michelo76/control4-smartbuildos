--[[==========================================================================
  Atmosphere — ISO8601 time parsing

  NWS timestamps carry explicit UTC offsets ("2026-08-31T14:52:00+00:00");
  gridpoint layers use interval-with-duration form
  ("2026-08-31T00:00:00+00:00/PT6H") that must be expanded by the caller.

  Epochs are computed with our own days-from-civil math — os.time() applies
  the HOST timezone to a broken-down table, which would silently skew every
  parse by the controller's UTC offset. Pure module, no os.* dependency.
============================================================================]]

local M = {}

--- Days since 1970-01-01 for a civil date (Howard Hinnant's algorithm).
local function daysFromCivil(y, m, d)
	if m <= 2 then
		y = y - 1
	end
	local era = math.floor(y / 400)
	local yoe = y - era * 400
	local mp = (m + 9) % 12
	local doy = math.floor((153 * mp + 2) / 5) + d - 1
	local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
	return era * 146097 + doe - 719468
end

--- Parses an ISO8601 timestamp with offset (or Z) to a UTC epoch. Returns nil
--- on anything unparseable — never a guess.
function M.parseTimestamp(s)
	if type(s) ~= "string" then
		return nil
	end
	local y, mo, d, h, mi, sec, rest = s:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)%.?%d*(.*)$")
	if y == nil then
		return nil
	end
	local offset = 0
	if rest ~= "" and rest ~= "Z" then
		local sign, oh, om = rest:match("^([%+%-])(%d%d):?(%d%d)$")
		if sign == nil then
			return nil
		end
		offset = (tonumber(oh) * 3600 + tonumber(om) * 60) * (sign == "-" and -1 or 1)
	end
	local days = daysFromCivil(tonumber(y), tonumber(mo), tonumber(d))
	return days * 86400 + tonumber(h) * 3600 + tonumber(mi) * 60 + tonumber(sec) - offset
end

--- Parses an ISO8601 duration ("PT6H", "P1DT12H30M", "PT30S") to seconds.
--- Weeks/months/years are not produced by NWS grid data and are refused (a
--- month has no fixed length; guessing one would corrupt interval expansion).
function M.parseDuration(s)
	if type(s) ~= "string" then
		return nil
	end
	local datePart, timePart = s:match("^P([^T]*)T?(.*)$")
	if datePart == nil then
		return nil
	end
	if datePart:find("[YMW]") then
		return nil
	end
	local total = 0
	local d = datePart:match("^(%d+)D$")
	if d ~= nil then
		total = total + tonumber(d) * 86400
	elseif datePart ~= "" then
		return nil
	end
	if timePart ~= "" then
		local matched = false
		for n, unit in timePart:gmatch("(%d+%.?%d*)([HMS])") do
			matched = true
			if unit == "H" then
				total = total + tonumber(n) * 3600
			elseif unit == "M" then
				total = total + tonumber(n) * 60
			else
				total = total + tonumber(n)
			end
		end
		if not matched then
			return nil
		end
	end
	return total
end

--- Parses "timestamp/duration" (NWS validTime) into { start = epoch,
--- duration = seconds }. A bare timestamp gets duration 0.
function M.parseInterval(s)
	if type(s) ~= "string" then
		return nil
	end
	local ts, dur = s:match("^([^/]+)/(.+)$")
	if ts == nil then
		local start = M.parseTimestamp(s)
		if start == nil then
			return nil
		end
		return { start = start, duration = 0 }
	end
	local start = M.parseTimestamp(ts)
	local seconds = M.parseDuration(dur)
	if start == nil or seconds == nil then
		return nil
	end
	return { start = start, duration = seconds }
end

--- Whether epoch t falls inside interval iv (start inclusive, end exclusive).
function M.contains(iv, t)
	if iv == nil or t == nil then
		return false
	end
	return t >= iv.start and t < iv.start + iv.duration
end

return M
