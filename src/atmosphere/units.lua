--[[==========================================================================
  Atmosphere — unit conversions

  NWS observations are strict SI regardless of locale (measured live):
  degC, km/h, Pa (not hPa), metres. Forecast periods mix conventions
  (bare Fahrenheit numbers next to degC objects). Everything here is
  nil-safe: nil in, nil out — a missing reading must never become 0.
============================================================================]]

local M = {}

local function num(v)
	if v == nil then
		return nil
	end
	return tonumber(v)
end

function M.cToF(c)
	c = num(c)
	if c == nil then
		return nil
	end
	return c * 9 / 5 + 32
end

function M.fToC(f)
	f = num(f)
	if f == nil then
		return nil
	end
	return (f - 32) * 5 / 9
end

function M.kmhToMph(kmh)
	kmh = num(kmh)
	if kmh == nil then
		return nil
	end
	return kmh * 0.621371
end

function M.msToMph(ms)
	ms = num(ms)
	if ms == nil then
		return nil
	end
	return ms * 2.236936
end

function M.mphToKmh(mph)
	mph = num(mph)
	if mph == nil then
		return nil
	end
	return mph / 0.621371
end

function M.mphToKnots(mph)
	mph = num(mph)
	if mph == nil then
		return nil
	end
	return mph * 0.868976
end

function M.paToInHg(pa)
	pa = num(pa)
	if pa == nil then
		return nil
	end
	return pa * 0.0002953
end

function M.paToHpa(pa)
	pa = num(pa)
	if pa == nil then
		return nil
	end
	return pa / 100
end

function M.metersToMiles(m)
	m = num(m)
	if m == nil then
		return nil
	end
	return m / 1609.344
end

function M.metersToKm(m)
	m = num(m)
	if m == nil then
		return nil
	end
	return m / 1000
end

function M.mmToInches(mm)
	mm = num(mm)
	if mm == nil then
		return nil
	end
	return mm / 25.4
end

--- 16-point compass name for a bearing in degrees, nil-safe.
function M.degToCompass(deg)
	deg = num(deg)
	if deg == nil then
		return nil
	end
	local names = {
		"N",
		"NNE",
		"NE",
		"ENE",
		"E",
		"ESE",
		"SE",
		"SSE",
		"S",
		"SSW",
		"SW",
		"WSW",
		"W",
		"WNW",
		"NW",
		"NNW",
	}
	local idx = math.floor((deg % 360) / 22.5 + 0.5) % 16
	return names[idx + 1]
end

--- Rounds to n decimals (default 0), nil-safe.
function M.round(v, decimals)
	v = num(v)
	if v == nil then
		return nil
	end
	local mult = 10 ^ (decimals or 0)
	return math.floor(v * mult + 0.5) / mult
end

--- Formats a number with one decimal as a string, or returns fallback (default
--- "-") for nil. Display-side only; variables carry raw numbers.
function M.one(v, fallback)
	v = num(v)
	if v == nil then
		return fallback or "-"
	end
	return string.format("%.1f", v)
end

return M
