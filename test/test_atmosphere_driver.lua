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
  ["App Relay Address"] = "Auto",
  ["App Data Relay"] = "Starting",
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
  -- No SmartBuildOS Agent; one controller device for relay-host discovery.
  return { [7] = { deviceName = "EA-5", driverFileName = "control4_ea5.c4z" } }
end
-- The controller answers the FLAT api with nothing and the nested-shape api
-- with the addr buried two levels deep — the field-measured worst case.
function C4:GetNetworkBindingsByDevice()
  return {}
end
function C4:GetBindingsByDevice()
  return {
    bindings = { { bindingid = 5001, boundconsumers = {}, info = { addr = "192.168.7.20", status = "online" } } },
  }
end
local serverCreated = nil
local serverSent = {}
function C4:CreateServer(port, _, _, identifier)
  serverCreated = { port = port, identifier = identifier }
  return true
end
function C4:ServerSend(handle, data)
  serverSent[#serverSent + 1] = { handle = handle, data = data }
end
function C4:ServerCloseClient() end
function C4:DestroyServer() end
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

--- Gridpoint layers: QPF totals 12.7 mm (0.5 in) inside 24 h; snowfall
--- 25.4 mm (1 in) inside 24 h plus a sample beyond the window that must NOT
--- count; probabilityOfThunder peaks at 80 only after the 12 h window (the
--- third interval starts at +13 h so a second-boundary tick during the test
--- cannot drag it into range).
local function isoInterval(startDelta, durationIso)
  return isoNow(startDelta) .. "/" .. durationIso
end

local gridBody = {
  properties = {
    snowfallAmount = {
      uom = "wmoUnit:mm",
      values = {
        { validTime = isoInterval(0, "PT6H"), value = 25.4 },
        { validTime = isoInterval(30 * 3600, "PT6H"), value = 50.8 },
      },
    },
    quantitativePrecipitation = {
      uom = "wmoUnit:mm",
      values = {
        { validTime = isoInterval(0, "PT6H"), value = 5.08 },
        { validTime = isoInterval(6 * 3600, "PT6H"), value = 7.62 },
      },
    },
    probabilityOfThunder = {
      uom = "wmoUnit:percent",
      values = {
        { validTime = isoInterval(0, "PT6H"), value = 10 },
        { validTime = isoInterval(6 * 3600, "PT6H"), value = 55 },
        { validTime = isoInterval(13 * 3600, "PT6H"), value = 80 },
      },
    },
    apparentTemperature = {
      uom = "wmoUnit:degC",
      values = { { validTime = isoInterval(0, "PT6H"), value = 35 } },
    },
  },
}

-- Route patterns share prefixes (the bare gridpoint URL is a substring of
-- the forecast/stations URLs) — the fake's longest-match rule needs each
-- pattern spelled long enough to win on its own URL.
routes["/points/26.1224,-80.1373"] = pointsBody
routes["gridpoints/MFL/110,50/stations"] = stationsBody
routes["stations/KFLL/observations/latest"] = observationBody
routes["gridpoints/MFL/110,50/forecast/hourly"] = hourlyBody
routes["gridpoints/MFL/110,50/forecast"] = dailyBody
routes["gridpoints/MFL/110,50"] = gridBody
routes["alerts/active?zone=FLZ173"] = alertBody

-- Seed 24h observation history so the barometric trend has a real window on
-- first start: two samples inside the 3-hour window, rising toward the
-- fixture observation's 101800 Pa (30.06 inHg) -> delta +0.16 = RISING.
persistStore["atmos_history"] = {
  { t = os.time() - 170 * 60, tempF = 80.0, pressureInHg = 29.90 },
  { t = os.time() - 95 * 60, tempF = 81.0, pressureInHg = 29.95 },
}

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

-- ─── Grid layers, trend, moon, recommendations ────────────────────────────────

check("snowfall next 24h from grid (in)", variables["SNOWFALL_NEXT_24H_IN"] == "1", variables["SNOWFALL_NEXT_24H_IN"])
check(
  "rain total next 24h from grid (in)",
  variables["RAIN_TOTAL_NEXT_24H_IN"] == "0.5",
  variables["RAIN_TOTAL_NEXT_24H_IN"]
)
check(
  "thunder peak next 12h from grid",
  variables["THUNDER_PROBABILITY_12H"] == "55",
  variables["THUNDER_PROBABILITY_12H"]
)
check("pressure trend RISING from history", variables["PRESSURE_TREND"] == "RISING", variables["PRESSURE_TREND"])
local moonNames = {
  ["New Moon"] = true,
  ["Waxing Crescent"] = true,
  ["First Quarter"] = true,
  ["Waxing Gibbous"] = true,
  ["Full Moon"] = true,
  ["Waning Gibbous"] = true,
  ["Last Quarter"] = true,
  ["Waning Crescent"] = true,
}
check("moon phase variable is a phase name", moonNames[variables["MOON_PHASE"]] == true, variables["MOON_PHASE"])
check("irrigation skip recommended (rain expected)", variables["IRRIGATION_SKIP_RECOMMENDED"] == "true")
check("irrigation skip fired as a transition event", firedEvent("Irrigation Skip Recommended"))
check("shade protect stays false in light wind", variables["SHADE_PROTECT_RECOMMENDED"] == "false")
check("history persisted with the new sample", #persistStore.atmos_history == 3)

check("svr warning event fired", firedEvent("Severe Thunderstorm Warning"))
check("generic warning event fired", firedEvent("New Weather Warning"))
check("no rain-started on baseline", not firedEvent("Rain Started"))

check("conditional alert active", conditionals["ATMOSPHERE_ALERT_ACTIVE"] == true)
check("conditional not raining", conditionals["ATMOSPHERE_RAINING"] == false)

local tempSend = lastProxySend(100, "VALUE_CHANGED")
check("temperature VALUE_CHANGED published", tempSend ~= nil and tempSend.params.FAHRENHEIT == "86.0")
local humSend = lastProxySend(101, "VALUE_CHANGED")
check("humidity VALUE_CHANGED published", humSend ~= nil and tostring(humSend.params.VALUE) == "70")
-- The relay chain: server created, host discovered through the NESTED
-- bindings shape via the second API, URL carries relay + token.
check("relay server created on 47815", serverCreated ~= nil and serverCreated.port == 47815)
local urlSend = lastProxySend(5001, "URL_CHANGED")
check(
  "webview URL carries relay host from nested bindings",
  urlSend ~= nil and urlSend.params.url:find("relay=http%3A%2F%2F192.168.7.20%3A47815", 1, true) ~= nil,
  urlSend ~= nil and urlSend.params.url or "no URL_CHANGED"
)
check("webview URL carries a token", urlSend ~= nil and urlSend.params.url:find("&k=%w+") ~= nil)
check("relay status property painted", Properties["App Data Relay"]:find("192.168.7.20", 1, true) ~= nil)
local relayToken = urlSend ~= nil and urlSend.params.url:match("&k=(%w+)") or ""
serverSent = {}
OnServerDataIn(11, "GET /state?k=" .. relayToken .. " HTTP/1.1\r\n\r\n", nil, nil, "atmosphere-ui-relay")
check("relay serves state over LAN", #serverSent == 1 and serverSent[1].data:find('"mode"', 1, true) ~= nil)
check("relay state carries current temp", #serverSent == 1 and serverSent[1].data:find("86", 1, true) ~= nil)
serverSent = {}
OnServerDataIn(12, "GET /state?k=wrongtoken HTTP/1.1\r\n\r\n", nil, nil, "atmosphere-ui-relay")
check("relay refuses bad token", #serverSent == 1 and serverSent[1].data:find("403 Forbidden", 1, true) ~= nil)

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
  check(
    "ui history present and bounded",
    type(uiDoc.history) == "table" and #uiDoc.history >= 3 and #uiDoc.history <= 48,
    type(uiDoc.history) == "table" and #uiDoc.history or "missing"
  )
  check(
    "ui history entries carry t/temp/pressure",
    type(uiDoc.history) == "table"
      and #uiDoc.history > 0
      and uiDoc.history[#uiDoc.history].t ~= nil
      and uiDoc.history[#uiDoc.history].temp == 86
      and uiDoc.history[#uiDoc.history].pressure == 30.06
  )
  check("ui pressure trend in trends block", uiDoc.trends ~= nil and uiDoc.trends.pressure == "RISING")
  check(
    "ui moon rides the solar block",
    uiDoc.solar ~= nil
      and type(uiDoc.solar.moon) == "table"
      and type(uiDoc.solar.moon.name) == "string"
      and uiDoc.solar.moon.illumination >= 0
      and uiDoc.solar.moon.illumination <= 100
  )
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
