--[[==========================================================================
  Atmosphere — NWS response normalization

  Raw api.weather.gov JSON in, normalized weather objects out. Measured facts
  this module is built around (live-verified 2026-08-31):

    - Every observation quantity is {value, unitCode, qualityControl} and any
      of them can be null in an otherwise healthy response. Six nulls in one
      good observation is NORMAL. Every field is independently nil-guarded.
    - MADIS qualityControl: values flagged X (rejected), Q (questionable) or
      B (subjected & failed) are dropped rather than displayed.
    - Forecast periods mix conventions: temperature is a BARE number in the
      unit named by temperatureUnit, dewpoint is an OBJECT in degC, windSpeed
      is a HUMAN STRING ("5 mph", "5 to 10 mph").
    - Hourly period `name` is an empty string; probabilityOfPrecipitation
      .value can be null.

  Nothing here converts a missing value into zero. Pure module.
============================================================================]]

local units = require("atmosphere.units")
local intervals = require("atmosphere.intervals")

local M = {}

--- MADIS flags that mean "do not use this value".
local QC_REJECT = { X = true, Q = true, B = true }

--- Extracts the numeric value from an NWS {value, unitCode, qualityControl}
--- quantity. nil when absent, null, or QC-rejected.
function M.quantity(q)
	if type(q) ~= "table" then
		return nil
	end
	if q.qualityControl ~= nil and QC_REJECT[tostring(q.qualityControl)] then
		return nil
	end
	return tonumber(q.value)
end

--- Parses NWS human wind strings: "5 mph" -> 5,5; "5 to 10 mph" -> 5,10.
--- Returns min, max (numbers) or nil.
function M.windRange(s)
	if type(s) ~= "string" then
		return nil
	end
	local lo, hi = s:match("^(%d+%.?%d*)%s+to%s+(%d+%.?%d*)%s+mph$")
	if lo ~= nil then
		return tonumber(lo), tonumber(hi)
	end
	local only = s:match("^(%d+%.?%d*)%s+mph$")
	if only ~= nil then
		return tonumber(only), tonumber(only)
	end
	return nil
end

--- METAR cloud-layer amount -> approximate cover percent (midpoint of the
--- METAR okta band). CLR/SKC 0, FEW 19, SCT 44, BKN 75, OVC 100, VV 100.
local CLOUD_PCT = { CLR = 0, SKC = 0, FEW = 19, SCT = 44, BKN = 75, OVC = 100, VV = 100 }

function M.cloudCover(layers)
	if type(layers) ~= "table" then
		return nil
	end
	local worst = nil
	for _, layer in ipairs(layers) do
		local pct = CLOUD_PCT[tostring(type(layer) == "table" and layer.amount or "")]
		if pct ~= nil and (worst == nil or pct > worst) then
			worst = pct
		end
	end
	return worst
end

--- Keyword classification of a textual condition into precipitation/sky
--- flags. Input is a shortForecast or textDescription; case-insensitive.
--- Used for boolean states only — the mode engine weighs more signals.
function M.conditionFlags(text)
	local t = tostring(text or ""):lower()
	local flags = {
		rain = false,
		snow = false,
		thunder = false,
		fog = false,
		ice = false,
		clear = false,
		cloudy = false,
	}
	if t:find("thunder") or t:find("t%-storm") or t:find("tstm") then
		flags.thunder = true
	end
	if
		t:find("rain")
		or t:find("shower")
		or t:find("drizzle")
		or (t:find("storm") and not t:find("dust") and not t:find("snow"))
	then
		flags.rain = true
	end
	if t:find("snow") or t:find("flurr") or t:find("blizzard") then
		flags.snow = true
	end
	if t:find("sleet") or t:find("freezing rain") or t:find("freezing drizzle") or t:find("ice") then
		flags.ice = true
	end
	if t:find("fog") or t:find("mist") or t:find("haze") or t:find("smoke") then
		flags.fog = true
	end
	if t:find("clear") or t:find("sunny") or t:find("fair") then
		flags.clear = true
	end
	if t:find("cloud") or t:find("overcast") then
		flags.cloudy = true
	end
	return flags
end

--- Normalizes /stations/{id}/observations/latest properties. Returns a table
--- of nil-able fields — the caller must treat every one as optional — or nil
--- if the payload has no usable identity (no timestamp).
function M.observation(props)
	if type(props) ~= "table" then
		return nil
	end
	local ts = intervals.parseTimestamp(props.timestamp)
	if ts == nil then
		return nil
	end
	local tempC = M.quantity(props.temperature)
	local dewC = M.quantity(props.dewpoint)
	local heatC = M.quantity(props.heatIndex)
	local chillC = M.quantity(props.windChill)
	local obs = {
		timestamp = ts,
		station = tostring(props.station or ""),
		textDescription = tostring(props.textDescription or ""),
		tempC = tempC,
		tempF = units.cToF(tempC),
		dewpointC = dewC,
		dewpointF = units.cToF(dewC),
		heatIndexC = heatC,
		heatIndexF = units.cToF(heatC),
		windChillC = chillC,
		windChillF = units.cToF(chillC),
		humidity = M.quantity(props.relativeHumidity),
		windMph = units.kmhToMph(M.quantity(props.windSpeed)),
		gustMph = units.kmhToMph(M.quantity(props.windGust)),
		windDeg = M.quantity(props.windDirection),
		pressurePa = M.quantity(props.barometricPressure),
		visibilityM = M.quantity(props.visibility),
		precipLast3hMm = M.quantity(props.precipitationLast3Hours),
		cloudCover = M.cloudCover(props.cloudLayers),
	}
	obs.windCompass = units.degToCompass(obs.windDeg)
	obs.pressureInHg = units.paToInHg(obs.pressurePa)
	obs.visibilityMi = units.metersToMiles(obs.visibilityM)
	obs.flags = M.conditionFlags(obs.textDescription)
	-- presentWeather is authoritative for "is it precipitating right now" when
	-- populated; the text description is the fallback.
	if type(props.presentWeather) == "table" then
		for _, w in ipairs(props.presentWeather) do
			local kind = tostring(type(w) == "table" and (w.weather or "") or ""):lower()
			if kind:find("rain") or kind:find("drizzle") or kind:find("shower") then
				obs.flags.rain = true
			end
			if kind:find("snow") then
				obs.flags.snow = true
			end
			if kind:find("thunder") then
				obs.flags.thunder = true
			end
			if kind:find("fog") or kind:find("mist") then
				obs.flags.fog = true
			end
			if kind:find("freezing") or kind:find("ice") or kind:find("sleet") then
				obs.flags.ice = true
			end
		end
	end
	-- Feels-like: heat index when hot, wind chill when cold, else air temp.
	obs.feelsLikeF = obs.heatIndexF or obs.windChillF or obs.tempF
	obs.feelsLikeC = obs.heatIndexC or obs.windChillC or obs.tempC
	return obs
end

--- Normalizes one forecast period (daily or hourly). Returns nil if the
--- period has no valid time bounds.
function M.period(p)
	if type(p) ~= "table" then
		return nil
	end
	local startT = intervals.parseTimestamp(p.startTime)
	local endT = intervals.parseTimestamp(p.endTime)
	if startT == nil or endT == nil then
		return nil
	end
	local tempF = nil
	local temp = tonumber(p.temperature)
	if temp ~= nil then
		if tostring(p.temperatureUnit or "F") == "C" then
			tempF = units.cToF(temp)
		else
			tempF = temp
		end
	end
	local pop = nil
	if type(p.probabilityOfPrecipitation) == "table" then
		pop = tonumber(p.probabilityOfPrecipitation.value)
	end
	local windLo, windHi = M.windRange(p.windSpeed)
	local out = {
		startT = startT,
		endT = endT,
		name = tostring(p.name or ""),
		isDaytime = p.isDaytime == true,
		tempF = tempF,
		tempC = units.fToC(tempF),
		pop = pop,
		windMphLo = windLo,
		windMphHi = windHi,
		windDir = p.windDirection ~= nil and tostring(p.windDirection) or nil,
		shortForecast = tostring(p.shortForecast or ""),
		detailedForecast = tostring(p.detailedForecast or ""),
		icon = p.icon ~= nil and tostring(p.icon) or nil,
		dewpointC = type(p.dewpoint) == "table" and tonumber(p.dewpoint.value) or nil,
		humidity = type(p.relativeHumidity) == "table" and tonumber(p.relativeHumidity.value) or nil,
	}
	out.flags = M.conditionFlags(out.shortForecast)
	return out
end

--- Normalizes a periods array (from /forecast or /forecast/hourly),
--- dropping unparseable entries rather than failing the batch.
function M.periods(list)
	local out = {}
	if type(list) ~= "table" then
		return out
	end
	for _, p in ipairs(list) do
		local n = M.period(p)
		if n ~= nil then
			out[#out + 1] = n
		end
	end
	return out
end

--- Normalizes a gridpoint layer ({uom, values=[{validTime, value}]}) into
--- expanded { {start, duration, value} } samples, skipping null values and
--- unparseable intervals.
function M.gridLayer(layer)
	local out = {}
	if type(layer) ~= "table" or type(layer.values) ~= "table" then
		return out
	end
	for _, v in ipairs(layer.values) do
		if type(v) == "table" and v.value ~= nil then
			local iv = intervals.parseInterval(v.validTime)
			local n = tonumber(v.value)
			if iv ~= nil and n ~= nil then
				out[#out + 1] = { start = iv.start, duration = iv.duration, value = n }
			end
		end
	end
	return out
end

--- Normalizes a /points response into the discovery record the driver caches.
--- Returns nil unless the essentials (grid + forecast URLs) are present.
function M.points(props)
	if type(props) ~= "table" then
		return nil
	end
	local gridId = props.gridId or props.cwa
	if gridId == nil or props.gridX == nil or props.gridY == nil then
		return nil
	end
	local function zoneId(url)
		if type(url) ~= "string" then
			return nil
		end
		return url:match("/([%w]+)$")
	end
	return {
		office = tostring(gridId),
		gridX = tonumber(props.gridX),
		gridY = tonumber(props.gridY),
		forecastUrl = props.forecast,
		forecastHourlyUrl = props.forecastHourly,
		forecastGridDataUrl = props.forecastGridData,
		observationStationsUrl = props.observationStations,
		forecastZone = zoneId(props.forecastZone),
		county = zoneId(props.county),
		fireWeatherZone = zoneId(props.fireWeatherZone),
		timeZone = props.timeZone ~= nil and tostring(props.timeZone) or nil,
		radarStation = props.radarStation ~= nil and tostring(props.radarStation) or nil,
	}
end

return M
