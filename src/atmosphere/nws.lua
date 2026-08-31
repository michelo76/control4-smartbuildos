--[[==========================================================================
  Atmosphere — api.weather.gov client

  Thin, honest transport: every call resolves to (data, err) via lib.http's
  deferred promises; JSON decode is pcall'd; nothing here interprets weather.
  Policy facts honored (official docs, 2026-08-31):
    - Identifying User-Agent is REQUIRED; an API key is announced for the
      future -> a key slot exists now so the fleet survives that day.
    - Rate limiting: docs promise only "an error... typically retryable
      within 5 seconds" (429 NOT documented) -> callers back off on ANY
      failure, never key on a status code.
    - GeoJSON responses; the payload of interest is .properties (points,
      observations, alerts features[i].properties) or .properties.periods.
============================================================================]]

local http = require("lib.http")
local log = require("lib.logging")

local M = {}

M.BASE = "https://api.weather.gov"
M.TIMEOUT_SECONDS = 20

local userAgentValue = "SmartBuildOS Atmosphere (smartbuildos.io, support@smartbuildos.io)"
local apiKey = nil -- reserved: NWS has announced a future API key scheme

function M.setUserAgent(ua)
	if type(ua) == "string" and ua ~= "" then
		userAgentValue = ua
	end
end

function M.setApiKey(key)
	apiKey = (type(key) == "string" and key ~= "") and key or nil
end

local function headers()
	local h = {
		["User-Agent"] = userAgentValue,
		["Accept"] = "application/geo+json",
	}
	if apiKey ~= nil then
		h["X-Api-Key"] = apiKey
	end
	return h
end

--- GET url -> onDone(decodedTable, nil) or onDone(nil, errTable).
--- errTable = { code = httpCodeOrNil, error = string }.
local function getJson(url, onDone)
	http:get(url, headers(), { timeout = M.TIMEOUT_SECONDS }):next(function(response)
		local ok, decoded = pcall(function()
			return JSON:decode(response.body)
		end)
		if not ok or type(decoded) ~= "table" then
			onDone(nil, { code = response.code, error = "undecodable response body" })
			return
		end
		onDone(decoded, nil)
	end, function(err)
		err = type(err) == "table" and err or { error = tostring(err) }
		log:debug("NWS request failed: %s (%s)", tostring(err.error), tostring(err.code))
		onDone(nil, { code = err.code, error = tostring(err.error or "request failed") })
	end)
end

--- /points/{lat},{lon}. Coordinates are rounded to 4 decimals — the API
--- redirects requests with more precision, and 4dp (~11 m) is beyond any
--- forecast resolution anyway.
function M.points(lat, lon, onDone)
	local url = string.format("%s/points/%.4f,%.4f", M.BASE, tonumber(lat), tonumber(lon))
	getJson(url, function(data, err)
		if data == nil then
			onDone(nil, err)
			return
		end
		onDone(data.properties, nil)
	end)
end

--- Station list for a gridpoint (follows the stations URL from /points).
--- Returns an ordered array of station ids (observed nearest-first).
function M.stations(stationsUrl, onDone)
	getJson(stationsUrl, function(data, err)
		if data == nil then
			onDone(nil, err)
			return
		end
		local ids = {}
		for _, f in ipairs(data.features or {}) do
			local id = type(f) == "table" and type(f.properties) == "table" and f.properties.stationIdentifier
			if id ~= nil then
				ids[#ids + 1] = tostring(id)
			end
		end
		onDone(ids, nil)
	end)
end

--- Latest observation for a station id. Returns raw .properties.
function M.latestObservation(stationId, onDone)
	local url = string.format("%s/stations/%s/observations/latest", M.BASE, stationId)
	getJson(url, function(data, err)
		if data == nil then
			onDone(nil, err)
			return
		end
		onDone(data.properties, nil)
	end)
end

--- Forecast periods from a forecast URL (daily or hourly variant).
function M.forecast(forecastUrl, onDone)
	getJson(forecastUrl, function(data, err)
		if data == nil then
			onDone(nil, err)
			return
		end
		local props = data.properties
		if type(props) ~= "table" or type(props.periods) ~= "table" then
			onDone(nil, { code = nil, error = "no periods in forecast response" })
			return
		end
		onDone(props, nil)
	end)
end

--- Raw gridpoint layers (forecastGridData URL). Returns .properties.
function M.gridData(gridUrl, onDone)
	getJson(gridUrl, function(data, err)
		if data == nil then
			onDone(nil, err)
			return
		end
		onDone(data.properties, nil)
	end)
end

--- Active alerts. Prefers the forecast ZONE (catches zone-scoped products a
--- point query can miss); falls back to point when no zone is known.
--- Returns an array of raw feature .properties tables.
function M.activeAlerts(opts, onDone)
	local url
	if opts.zone ~= nil then
		url = string.format("%s/alerts/active?zone=%s", M.BASE, opts.zone)
	elseif opts.lat ~= nil and opts.lon ~= nil then
		url = string.format("%s/alerts/active?point=%.4f,%.4f", M.BASE, tonumber(opts.lat), tonumber(opts.lon))
	else
		onDone(nil, { error = "no zone or point configured" })
		return
	end
	getJson(url, function(data, err)
		if data == nil then
			onDone(nil, err)
			return
		end
		local out = {}
		for _, f in ipairs(data.features or {}) do
			if type(f) == "table" and type(f.properties) == "table" then
				out[#out + 1] = f.properties
			end
		end
		onDone(out, nil)
	end)
end

return M
