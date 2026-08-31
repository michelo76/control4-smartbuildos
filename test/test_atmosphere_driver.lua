-- Integration test: loads drivers/smartbuildos-atmosphere/driver.lua under
-- the C4 shim with a fake lib.http and drives the full startup chain:
--
--   LateInit -> project-location resolve -> /points discovery -> station
--   selection -> observation -> forecast -> alerts -> engine -> variables,
--   events, conditionals, VALUE connections, WebView JSON.
--
-- Also: settings patches (accept + refuse), simulation parity (a simulated
-- tornado fires the real event), stop simulation, license-absent behavior,
-- API failure handling (no fabricated values, stale marking).
--
-- Run from the driver root: make test

local pass, fail = 0, 0
local function check(name, ok, detail)
	if ok then
		pass = pass + 1
		print(string.format("  ok   %s", name))
	else
		fail = fail + 1
		print(string.format("  FAIL %s%s", name, detail and ("  -> " .. tostring(detail)) or ""))
	end
end

-- ─── Fakes: transport ─────────────────────────────────────────────────────────

local JSON = require("JSON")

--- URL substring -> response body table (JSON-encoded on the way out).
--- Set an entry to the string "FAIL" to reject that request.
local routes = {}
local requestLog = {}

local function fakeResponse(body)
	return { code = 200, headers = {}, body = JSON:encode(body) }
end

package.preload["lib.http"] = function()
	return {
		get = function(_, url, headers, _)
			requestLog[#requestLog + 1] = { url = url, headers = headers }
			-- Longest matching pattern wins (an observation URL also contains
			-- "/stations"; pairs order must not decide).
			local matched, failMode, bestLen = nil, false, -1
			for pattern, body in pairs(routes) do
				if url:find(pattern, 1, true) and #pattern > bestLen then
					bestLen = #pattern
					if body == "FAIL" then
						failMode, matched = true, nil
					else
						failMode, matched = false, body
					end
				end
			end
			return {
				next = function(_, onOk, onErr)
					if failMode then
						onErr({ url = url, code = 503, error = "service unavailable" })
					elseif matched ~= nil then
						onOk(fakeResponse(matched))
					else
						onErr({ url = url, code = 404, error = "no fixture for " .. url })
					end
					return { next = function() end }
				end,
			}
		end,
		post = function()
			return { next = function() end }
		end,
	}
end

-- Raw source carries both --#ifdef DRIVERCENTRAL branches; OnDriverInit
-- requires the DC stub (repo-wide test trap).
package.preload["cloud-client-byte"] = function()
	return {}
end

-- ─── Fakes: persistence ───────────────────────────────────────────────────────

local persistStore = {}
package.preload["lib.persist"] = function()
	return {
		get = function(_, key, default)
			if persistStore[key] ~= nil then
				return persistStore[key]
			end
			return default
		end,
		set = function(_, key, value)
			persistStore[key] = value
		end,
		delete = function(_, key)
			persistStore[key] = nil
		end,
	}
end

-- ─── Fakes: C4 surface the driver asserts on ──────────────────────────────────

Properties = {
	["Status"] = "Status",
	["Driver Status"] = "Starting",
	["Driver Version"] = "unknown",
	["Weather Status"] = "Waiting for first update",
	["Data Freshness"] = "-",
	["Active Alerts"] = "-",
	["Simulation"] = "Off",
	["Location"] = "Location",
	["Location Source"] = "Control4 Project",
	["Latitude"] = "",
	["Longitude"] = "",
	["Resolved Location"] = "Not resolved",
	["Forecast Office"] = "-",
	["Observation Station"] = "-",
	["Licensing"] = "Licensing",
	["License Status"] = "No SmartBuildOS Agent Found",
	["License Source"] = "-",
	["Subscription Tier"] = "-",
	["SmartBuildOS Company"] = "-",
	["Logging"] = "Logging",
	["Log Level"] = "3 - Info",
	["Log Mode"] = "Off",
}

local variables = {}
local events = {}
local conditionals = {}
local proxySends = {}

function C4:GetVersionInfo()
	return { version = "4.0.0" }
end
function C4:GetDriverConfigInfo(key)
	if key == "version" then
		return "20260831.1"
	end
	return "test"
end
function C4:UpdateProperty(name, value)
	Properties[name] = tostring(value)
end
function C4:AddVariable(name, default, varType)
	if variables[name] == nil then
		variables[name] = tostring(default)
	end
	return true
end
function C4:SetVariable(name, value)
	variables[name] = tostring(value)
end
function C4:AddEvent()
	return true
end
function C4:FireEvent(name)
	events[#events + 1] = tostring(name)
end
function C4:SetConditionalState(name, value)
	conditionals[name] = value == true
end
function C4:GetDevices()
	return {} -- no SmartBuildOS Agent in this project
end
function C4:GetProjectItems()
	return [[<locations><location><latitude>26.1224</latitude><longitude>-80.1373</longitude><country_code>US</country_code><zipcode>33301</zipcode><city_name>Fort Lauderdale</city_name><timezone>America/New_York</timezone></location></locations>]]
end
function C4:SendToProxy(binding, command, params)
	proxySends[#proxySends + 1] = { binding = binding, command = command, params = params }
end
function C4:AllowExecute() end
function C4:GetDeviceID()
	return 42
end

local function firedEvent(name)
	for _, e in ipairs(events) do
		if e == name then
			return true
		end
	end
	return false
end

local function lastProxySend(binding, command)
	for i = #proxySends, 1, -1 do
		local s = proxySends[i]
		if s.binding == binding and s.command == command then
			return s
		end
	end
	return nil
end

-- ─── Fixtures ─────────────────────────────────────────────────────────────────

local pointsBody = {
	properties = {
		gridId = "MFL",
		gridX = 110,
		gridY = 50,
		forecast = "https://api.weather.gov/gridpoints/MFL/110,50/forecast",
		forecastHourly = "https://api.weather.gov/gridpoints/MFL/110,50/forecast/hourly",
		forecastGridData = "https://api.weather.gov/gridpoints/MFL/110,50",
		observationStations = "https://api.weather.gov/gridpoints/MFL/110,50/stations",
		forecastZone = "https://api.weather.gov/zones/forecast/FLZ173",
		county = "https://api.weather.gov/zones/county/FLC011",
		fireWeatherZone = "https://api.weather.gov/zones/fire/FLZ173",
		timeZone = "America/New_York",
		radarStation = "KAMX",
	},
}

local stationsBody = {
	features = {
		{ properties = { stationIdentifier = "KFLL" } },
		{ properties = { stationIdentifier = "KFXE" } },
	},
}

local function isoNow(deltaSeconds)
	return os.date("!%Y-%m-%dT%H:%M:%S+00:00", os.time() + (deltaSeconds or 0))
end

local observationBody = {
	properties = {
		timestamp = isoNow(-300),
		station = "https://api.weather.gov/stations/KFLL",
		textDescription = "Partly Cloudy",
		temperature = { value = 30.0, unitCode = "wmoUnit:degC", qualityControl = "V" },
		dewpoint = { value = 24.0, qualityControl = "V" },
		windSpeed = { value = 14.8, unitCode = "wmoUnit:km_h-1", qualityControl = "V" },
		windDirection = { value = 90, qualityControl = "V" },
		barometricPressure = { value = 101800, qualityControl = "V" },
		visibility = { value = 16090, qualityControl = "C" },
		relativeHumidity = { value = 70, qualityControl = "V" },
		windGust = { value = nil, qualityControl = "Z" },
		heatIndex = { value = 35.5, qualityControl = "V" },
		cloudLayers = { { amount = "SCT" } },
		presentWeather = {},
	},
}

local dailyBody = {
	properties = {
		periods = {
			{
				name = "Today",
				startTime = isoNow(-3600),
				endTime = isoNow(8 * 3600),
				isDaytime = true,
				temperature = 92,
				temperatureUnit = "F",
				probabilityOfPrecipitation = { value = 60 },
				windSpeed = "10 to 15 mph",
				windDirection = "E",
				shortForecast = "Scattered Showers And Thunderstorms",
				detailedForecast = "Scattered showers and thunderstorms after 2pm.",
			},
			{
				name = "Tonight",
				startTime = isoNow(8 * 3600),
				endTime = isoNow(20 * 3600),
				isDaytime = false,
				temperature = 78,
				temperatureUnit = "F",
				probabilityOfPrecipitation = { value = 30 },
				windSpeed = "8 mph",
				windDirection = "SE",
				shortForecast = "Partly Cloudy",
				detailedForecast = "Partly cloudy with a low around 78.",
			},
		},
	},
}

local hourlyPeriods = {}
for i = 0, 11 do
	hourlyPeriods[#hourlyPeriods + 1] = {
		name = "",
		startTime = isoNow(i * 3600),
		endTime = isoNow((i + 1) * 3600),
		isDaytime = true,
		temperature = 88,
		temperatureUnit = "F",
		probabilityOfPrecipitation = { value = i == 2 and 65 or 15 },
		windSpeed = "10 mph",
		windDirection = "E",
		shortForecast = i == 2 and "Showers And Thunderstorms" or "Partly Sunny",
	}
end
local hourlyBody = { properties = { periods = hourlyPeriods } }

local alertBody = {
	features = {
		{
			properties = {
				id = "urn:oid:2.49.0.1.840.0.test.svr.1",
				event = "Severe Thunderstorm Warning",
				headline = "Severe Thunderstorm Warning until 5PM",
				severity = "Severe",
				certainty = "Observed",
				urgency = "Immediate",
				status = "Actual",
				messageType = "Alert",
				effective = isoNow(-600),
				onset = isoNow(-600),
				expires = isoNow(2 * 3600),
				ends = isoNow(2 * 3600),
				senderName = "NWS Miami FL",
				areaDesc = "Broward County",
				description = "A severe thunderstorm was located near the property.",
				instruction = "Move indoors.",
				response = "Shelter",
			},
		},
	},
}

routes["/points/26.1224,-80.1373"] = pointsBody
routes["/stations"] = stationsBody
routes["stations/KFLL/observations/latest"] = observationBody
routes["forecast/hourly"] = hourlyBody
routes["110,50/forecast"] = dailyBody
routes["alerts/active?zone=FLZ173"] = alertBody

-- ─── Load the driver ──────────────────────────────────────────────────────────

local chunk, loadErr = loadfile("drivers/smartbuildos-atmosphere/driver.lua")
check("driver.lua compiles", chunk ~= nil, loadErr)
if chunk == nil then
	print(string.format("\n%d passed, %d failed", pass, fail))
	os.exit(1)
end
local ok, runErr = pcall(chunk)
check("driver.lua loads", ok, runErr)

local okInit, initErr = pcall(OnDriverInit)
check("OnDriverInit runs", okInit, initErr)
local okLate, lateErr = pcall(OnDriverLateInit)
check("OnDriverLateInit runs", okLate, lateErr)

-- ─── Startup chain assertions ─────────────────────────────────────────────────

check("driver reports Online", Properties["Driver Status"] == "Online")
check("driver version painted", Properties["Driver Version"] == "20260831.1")
check(
	"points discovery hit rounded coords",
	(function()
		for _, r in ipairs(requestLog) do
			if r.url:find("/points/26.1224,-80.1373", 1, true) then
				return true
			end
		end
		return false
	end)()
)
check(
	"User-Agent identifies the product",
	requestLog[1] ~= nil and tostring(requestLog[1].headers["User-Agent"]):find("Atmosphere", 1, true) ~= nil
)
check("forecast office painted", Properties["Forecast Office"]:find("MFL", 1, true) ~= nil)
check("station chosen", Properties["Observation Station"] == "KFLL")
check("resolved location painted", Properties["Resolved Location"]:find("Fort Lauderdale", 1, true) ~= nil)

check("temperature variable set", variables["CURRENT_TEMPERATURE_F"] == "86.0")
check("temperature C variable set", variables["CURRENT_TEMPERATURE_C"] == "30.0")
check("feels-like from heat index", variables["FEELS_LIKE_F"] == "95.9")
check("humidity variable", variables["HUMIDITY_PERCENT"] == "70")
check("wind variable from km/h", variables["WIND_SPEED_MPH"] == "9.2")
check("gust stays empty, never 0", variables["WIND_GUST_MPH"] == "")
check("condition variable", variables["CURRENT_CONDITION"] == "Partly Cloudy")
check("mode is partly cloudy", variables["WEATHER_MODE"] == "PARTLY_CLOUDY")
check("forecast high", variables["FORECAST_HIGH_F"] == "92")
check("forecast low", variables["FORECAST_LOW_F"] == "78")
check("alert count", variables["ACTIVE_ALERT_COUNT"] == "1")
check("highest severity", variables["HIGHEST_ALERT_SEVERITY"] == "Severe")
check("latest alert name", variables["LATEST_ALERT_NAME"] == "Severe Thunderstorm Warning")
check("severity variable", variables["WEATHER_SEVERITY"] == "WARNING")
check("license status variable LEGACY", variables["LICENSE_STATUS"] == "LEGACY")
check("license property shows no agent", Properties["License Status"] == "No SmartBuildOS Agent Found")
check("data not stale", variables["DATA_STALE"] == "false")
check("api online", variables["API_STATUS"] == "Online")
check("sunrise variable set", variables["SUNRISE"] ~= nil and variables["SUNRISE"]:find(":") ~= nil)

check("svr warning event fired", firedEvent("Severe Thunderstorm Warning"))
check("generic warning event fired", firedEvent("New Weather Warning"))
check("no rain-started on baseline", not firedEvent("Rain Started"))

check("conditional alert active", conditionals["ATMOSPHERE_ALERT_ACTIVE"] == true)
check("conditional not raining", conditionals["ATMOSPHERE_RAINING"] == false)

local tempSend = lastProxySend(100, "VALUE_CHANGED")
check("temperature VALUE_CHANGED published", tempSend ~= nil and tempSend.params.FAHRENHEIT == "86.0")
local humSend = lastProxySend(101, "VALUE_CHANGED")
check("humidity VALUE_CHANGED published", humSend ~= nil and tostring(humSend.params.VALUE) == "70")
local urlSend = lastProxySend(5001, "URL_CHANGED")
check(
	"webview URL published",
	urlSend ~= nil and urlSend.params.url == "controller://driver/smartbuildos-atmosphere/app/index.html"
)

check("Active Alerts property", Properties["Active Alerts"]:find("Severe Thunderstorm Warning", 1, true) ~= nil)
check("Weather Status shows temp", Properties["Weather Status"]:find("86.0", 1, true) ~= nil)

-- ─── WebView JSON contract ────────────────────────────────────────────────────

local stateJson = UIR.ATMOS_GET_STATE({})
local okDecode, uiDoc = pcall(function()
	return JSON:decode(stateJson)
end)
check("GET_STATE returns JSON", okDecode and type(uiDoc) == "table")
if okDecode and type(uiDoc) == "table" then
	check("ui current temp", uiDoc.current ~= nil and uiDoc.current.temp == 86)
	check("ui mode", uiDoc.mode == "PARTLY_CLOUDY")
	check("ui alerts present", type(uiDoc.alerts) == "table" and #uiDoc.alerts == 1)
	check("ui alert escaping is data-only", uiDoc.alerts[1].event == "Severe Thunderstorm Warning")
	check("ui hourly capped", #uiDoc.hourly <= 48 and #uiDoc.hourly > 0)
	check("ui daily present", #uiDoc.daily == 2)
	check("ui radar station rides location", uiDoc.location ~= nil and uiDoc.location.radar_station == "KAMX")
	check("ui settings present", uiDoc.settings ~= nil and uiDoc.settings.units.temperature == "F")
	check("ui license present", uiDoc.license ~= nil and uiDoc.license.status == "LEGACY")
	check("ui not simulation", uiDoc.simulation == false)
	check("ui no secrets: no token keys", stateJson:find("token") == nil and stateJson:find("secret") == nil)
end

-- ─── Settings patches ─────────────────────────────────────────────────────────

local resp = UIR.ATMOS_SET_SETTINGS({
	SETTINGS = JSON:encode({ units = { temperature = "C" }, thresholds = { high_wind_enter_mph = 30 } }),
})
local respDoc = JSON:decode(resp)
check("settings patch accepted", respDoc.ok == true and (respDoc.refused == nil or #respDoc.refused == 0))
local state2 = JSON:decode(UIR.ATMOS_GET_STATE({}))
check("settings unit applied to UI", state2.current ~= nil and state2.current.temp == 30)
check("settings persisted", persistStore.atmos_settings ~= nil and persistStore.atmos_settings.units.temperature == "C")

local badResp = JSON:decode(
	UIR.ATMOS_SET_SETTINGS({ SETTINGS = JSON:encode({ thresholds = { high_wind_enter_mph = 9999 }, junk = true }) })
)
check("bad settings refused with reasons", badResp.ok == true and badResp.refused ~= nil and #badResp.refused == 2)
check("bad threshold not applied", persistStore.atmos_settings.thresholds.high_wind_enter_mph == 30)

-- ─── Simulation parity ────────────────────────────────────────────────────────

events = {}
EC["Start Simulation"]({ SCENARIO = "tornado_warning" })
check("simulation started event", firedEvent("Simulation Started"))
check("simulated tornado warning fires REAL event", firedEvent("Tornado Warning"))
check("simulation variable", variables["SIMULATION_ACTIVE"] == "true")
check("simulation conditional", conditionals["ATMOSPHERE_SIMULATION"] == true)
check("simulation property", Properties["Simulation"]:find("tornado_warning", 1, true) ~= nil)
check("weather status flags simulation", Properties["Weather Status"]:find("SIMULATION", 1, true) ~= nil)
local simState = JSON:decode(UIR.ATMOS_GET_STATE({}))
check("ui flags simulation", simState.simulation == true)

events = {}
EC.STOP_SIMULATION()
check("simulation ended event", firedEvent("Simulation Ended"))
check("simulation cleared", variables["SIMULATION_ACTIVE"] == "false")
check("real alert restored after sim", variables["LATEST_ALERT_NAME"] == "Severe Thunderstorm Warning")

-- ─── API failure: no fabrication ──────────────────────────────────────────────

routes["stations/KFLL/observations/latest"] = "FAIL"
local tempBefore = variables["CURRENT_TEMPERATURE_F"]
events = {}
EC.REFRESH_WEATHER()
check("failed obs keeps last temperature", variables["CURRENT_TEMPERATURE_F"] == tempBefore)
check("failed obs fires no weather events", #events == 0, table.concat(events, ","))

routes["alerts/active?zone=FLZ173"] = "FAIL"
EC.REFRESH_ALERTS()
check("failed alert poll keeps active alert", variables["ACTIVE_ALERT_COUNT"] == "1")
check("failed alert poll does not clear", not firedEvent("Alert Cleared"))

-- ─── result ───────────────────────────────────────────────────────────────────

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
	os.exit(1)
end
