-- Atmosphere as an AI Core reference driver (sbos.aireport, START mode).
--
-- The real driver.lua under the shim, the REAL Agent registry and bus, and a
-- fake AI Core that runs every report through AI Core's REAL validator
-- (test/aicore_reporter_harness.lua). Covered:
--   [1] AI Core absent: registered, discovered, zero report frames, no error,
--       "Not installed"; remote settings (EC.SBOS_DRIVER_CONFIG, sbos.mirror)
--       still apply after the helper set its module client up
--   [2] AI Core appears: describe accepted (controls, vocabulary, queries,
--       no actions), weather facts in state, no location in any report
--   [3] events and diagnostics from the engine's own transitions (and none
--       while a dealer simulation runs)
--   [4] the two queries through the real bus (weather_source, forecast) and
--       their param validation
--   [5] AI Core goes away and comes back: the property follows
--   [6] REINITIALIZE (KillAllTimers) restarts the helper
-- Run from the driver root: make test

local pass, fail = 0, 0
local function check(name, ok, detail)
  if ok then
    pass = pass + 1
    print("  ok   " .. name)
  else
    fail = fail + 1
    print("  FAIL " .. name .. (detail ~= nil and ("  -> " .. tostring(detail)) or ""))
  end
end

local JSON = require("JSON")
local H = require("aicore_reporter_harness")

-- ─── Fakes: transport (NWS) ──────────────────────────────────────────────────
local routes = {}
package.preload["lib.http"] = function()
  return {
    get = function(_, url)
      local matched, bestLen = nil, -1
      for pattern, body in pairs(routes) do
        if url:find(pattern, 1, true) and #pattern > bestLen then
          bestLen, matched = #pattern, body
        end
      end
      return {
        next = function(_, onOk, onErr)
          if matched == nil or matched == "FAIL" then
            onErr({ url = url, code = 503, error = "service unavailable" })
          else
            onOk({ code = 200, headers = {}, body = JSON:encode(matched) })
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
package.preload["cloud-client-byte"] = function()
  return {}
end
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

Properties = {
  ["Driver Status"] = "Starting",
  ["Driver Version"] = "unknown",
  ["Weather Status"] = "Waiting for first update",
  ["Data Freshness"] = "-",
  ["Active Alerts"] = "-",
  ["Simulation"] = "Off",
  ["App Relay Address"] = "Auto",
  ["App Data Relay"] = "Starting",
  ["Location Source"] = "Control4 Project",
  ["Latitude"] = "",
  ["Longitude"] = "",
  ["Resolved Location"] = "Not resolved",
  ["Forecast Office"] = "-",
  ["Observation Station"] = "-",
  ["License Status"] = "No SmartBuildOS Agent Found",
  ["AI Core"] = "Searching…",
  ["Log Level"] = "3 - Info",
  ["Log Mode"] = "Off",
}
local everPainted = {}
function C4:UpdateProperty(name, value)
  Properties[name] = tostring(value)
  if name == "AI Core" then
    everPainted[#everPainted + 1] = tostring(value)
  end
end
function C4:GetVersionInfo()
  return { version = "4.0.0" }
end
function C4:GetDriverConfigInfo(key)
  if key == "version" then
    return "20261118.1"
  elseif key == "name" then
    return "SmartBuildOS Atmosphere"
  end
  return "test"
end
local events = {}
function C4:AddVariable()
  return true
end
function C4:SetVariable() end
function C4:AddEvent()
  return true
end
function C4:FireEvent(name)
  events[#events + 1] = tostring(name)
end
function C4:SetConditionalState() end
function C4:GetDevices()
  return { [7] = { deviceName = "EA-5", driverFileName = "control4_ea5.c4z" } }
end
function C4:GetNetworkBindingsByDevice()
  return {}
end
function C4:GetBindingsByDevice()
  return { bindings = { { bindingid = 5001, boundconsumers = {}, info = { addr = "192.168.7.20" } } } }
end
function C4:FileExists()
  return false
end
function C4:CreateServer()
  return true
end
function C4:ServerSend() end
function C4:ServerCloseClient() end
function C4:DestroyServer() end
function C4:GetProjectItems()
  return [[<locations><location><latitude>26.1224</latitude><longitude>-80.1373</longitude><country_code>US</country_code><city_name>Fort Lauderdale</city_name></location></locations>]]
end
function C4:SendToProxy() end
function C4:AllowExecute() end
function C4:GetDeviceID()
  return 42
end

local function isoNow(d)
  return os.date("!%Y-%m-%dT%H:%M:%S+00:00", os.time() + (d or 0))
end
routes["/points/26.1224,-80.1373"] = {
  properties = {
    gridId = "MFL",
    gridX = 110,
    gridY = 50,
    forecast = "https://api.weather.gov/gridpoints/MFL/110,50/forecast",
    forecastHourly = "https://api.weather.gov/gridpoints/MFL/110,50/forecast/hourly",
    forecastGridData = "https://api.weather.gov/gridpoints/MFL/110,50",
    observationStations = "https://api.weather.gov/gridpoints/MFL/110,50/stations",
    forecastZone = "https://api.weather.gov/zones/forecast/FLZ173",
    timeZone = "America/New_York",
    radarStation = "KAMX",
  },
}
routes["gridpoints/MFL/110,50/stations"] = { features = { { properties = { stationIdentifier = "KFLL" } } } }
local observationBody = {
  properties = {
    timestamp = isoNow(-300),
    textDescription = "Partly Cloudy",
    temperature = { value = 30.0, unitCode = "wmoUnit:degC" },
    dewpoint = { value = 24.0 },
    windSpeed = { value = 14.8, unitCode = "wmoUnit:km_h-1" },
    windDirection = { value = 90 },
    barometricPressure = { value = 101800 },
    visibility = { value = 16090 },
    relativeHumidity = { value = 70 },
    windGust = { value = nil },
    heatIndex = { value = 35.5 },
    presentWeather = {},
  },
}
routes["stations/KFLL/observations/latest"] = observationBody
local dailyPeriods = {}
for i = 0, 9 do
  dailyPeriods[#dailyPeriods + 1] = {
    name = (i % 2 == 0) and ("Day " .. i) or ("Night " .. i),
    startTime = isoNow(i * 12 * 3600 - 3600),
    endTime = isoNow((i + 1) * 12 * 3600 - 3600),
    isDaytime = i % 2 == 0,
    temperature = i % 2 == 0 and 92 or 78,
    temperatureUnit = "F",
    probabilityOfPrecipitation = { value = 30 + i },
    windSpeed = "10 mph",
    shortForecast = "Partly Sunny",
  }
end
routes["gridpoints/MFL/110,50/forecast"] = { properties = { periods = dailyPeriods } }
routes["gridpoints/MFL/110,50/forecast/hourly"] = { properties = { periods = {} } }
routes["gridpoints/MFL/110,50"] = { properties = {} }
local alertFeature = {
  properties = {
    id = "urn:oid:test.svr.1",
    event = "Severe Thunderstorm Warning",
    headline = "Severe Thunderstorm Warning until 5PM",
    severity = "Severe",
    certainty = "Observed",
    urgency = "Immediate",
    status = "Actual",
    messageType = "Alert",
    effective = isoNow(-600),
    onset = isoNow(-600),
    expires = isoNow(7200),
    ends = isoNow(7200),
    senderName = "NWS Miami FL",
    areaDesc = "Broward County",
  },
}
routes["alerts/active?zone=FLZ173"] = { features = {} }

-- ─── Load the driver with the Agent present and AI Core absent ──────────────
H.install({ selfId = 42, file = "smartbuildos-atmosphere.c4z" })
local chunk, loadErr = loadfile("drivers/smartbuildos-atmosphere/driver.lua")
check("driver.lua compiles", chunk ~= nil, loadErr)
if chunk == nil then
  os.exit(1)
end
local okRun, runErr = pcall(chunk)
check("driver.lua loads", okRun, runErr)
H.takeTimers()
local aireport = require("sbos.aireport")

print("[1] AI Core absent")
check("OnDriverInit runs", pcall(OnDriverInit))
local okLate, lateErr = pcall(OnDriverLateInit)
check("OnDriverLateInit runs", okLate, lateErr)
H.fire("atmos-obs") -- the first observation poll
check("helper in start mode", aireport.mode() == "start", aireport.mode())
check("registered with the Agent as atmosphere", H.registry:find("atmosphere", "42") ~= nil)
check("the Agent verified it (identity binding)", H.registry:find("atmosphere", "42").verified == true)
check("it looked for AI Core", H.count("SBOS_MODULE_DISCOVER") >= 1)
check("no report frame while AI Core is absent", H.reportFrames() == 0, H.reportFrames())
check("property: Not installed", Properties["AI Core"] == "Not installed", Properties["AI Core"])
local before = H.reportFrames()
EC.REFRESH_ALL()
H.fire("atmos-engine")
check(
  "weather keeps flowing, still no report frame",
  Properties["Weather Status"]:find("86", 1, true) ~= nil and H.reportFrames() == before,
  Properties["Weather Status"]
)

-- Remote settings: the helper must leave EC.SBOS_DRIVER_CONFIG to sbos.mirror.
local acks = {}
local realSend = C4.SendToDevice
function C4:SendToDevice(id, command, params)
  if command == "SBOS_DRIVER_CONFIG_ACK" then
    acks[#acks + 1] = params
  end
  return realSend(self, id, command, params)
end
ExecuteCommand("SBOS_DRIVER_CONFIG", {
  sku = "SBOS_ATMOSPHERE",
  settings = JSON:encode({ display = { default_screen = "forecast" } }),
  settings_version = "7",
  requester = "99",
})
check(
  "remote settings still apply through sbos.mirror (patch applied, acked by the mirror)",
  gSettings.display.default_screen == "forecast"
    and #acks == 1
    and acks[1].applied == "true"
    and acks[1].sku == "SBOS_ATMOSPHERE",
  JSON:encode(acks)
)
check(
  "…EC.SBOS_DRIVER_CONFIG is not the module client's handler",
  EC.SBOS_DRIVER_CONFIG ~= require("sbos.moduleclient").onConfig
)
C4.SendToDevice = realSend

print("[2] AI Core appears: describe and state")
H.aiRegister()
H.pushDirectory()
local describes = H.reports("describe")
check("a describe arrived", #describes >= 1)
local d = describes[#describes]
check("AI Core accepted every report so far (its own validator)", H.allValid())
check(
  "describe: what the driver is",
  d.args.driver.file == "smartbuildos-atmosphere.c4z"
    and d.args.driver.sku == "SBOS_ATMOSPHERE"
    and d.args.summary:find("National Weather Service", 1, true) ~= nil,
  JSON:encode(d.args.driver)
)
local controls = {}
for _, c in ipairs(d.args.controls) do
  controls[c.id] = c.class
end
check(
  "controls: weather and sensors",
  controls.current_conditions == "weather"
    and controls.weather_alerts == "weather"
    and controls.outdoor_temperature == "sensor"
)
local vocab = table.concat(d.args.vocabulary, "|")
check(
  "vocabulary: homeowner words",
  vocab:find("forecast", 1, true) and vocab:find("rain", 1, true) and vocab:find("weather alert", 1, true)
)
local qids = {}
for _, q in ipairs(d.args.queries) do
  qids[#qids + 1] = q.id
end
check(
  "queries: forecast, weather_source",
  table.concat(qids, ",") == "forecast,weather_source",
  table.concat(qids, ",")
)
check("no declared action", #d.args.actions == 0)
check(
  "property: Found — reporting (v…)",
  Properties["AI Core"] == "Found — reporting (v20261118.2)",
  Properties["AI Core"]
)
local states = H.reports("state")
local facts = states[#states] and states[#states].args.facts or {}
check(
  "state: the weather facts",
  facts.condition == "Partly Cloudy"
    and facts.temperature_f == 86
    and facts.humidity_percent == 70
    and facts.forecast_high_f == 92
    and facts.simulation == false,
  JSON:encode(facts)
)
check("state: the helper's baseline (driver status, licence)", facts.driver_status == "Online" and facts.license ~= nil)
local everything = JSON:encode(H.reports())
check(
  "no location in any report (no coordinates, no city)",
  everything:find("26.12", 1, true) == nil
    and everything:find("Fort Lauderdale", 1, true) == nil
    and everything:find("-80.13", 1, true) == nil
)

print("[3] events and diagnostics")
routes["alerts/active?zone=FLZ173"] = { features = { alertFeature } }
local evBefore = #H.reports("event")
EC.REFRESH_ALERTS()
local evs = H.reports("event")
local types = {}
for i = evBefore + 1, #evs do
  types[evs[i].args.type] = evs[i].args
end
check(
  "a new warning is an event (weather.new_weather_warning)",
  types["weather.new_weather_warning"] ~= nil,
  JSON:encode(types)
)
check(
  "…the named warning too, with severity and alert count",
  types["weather.severe_thunderstorm_warning"] ~= nil
    and types["weather.severe_thunderstorm_warning"].data.active_alerts == 1
)
check(
  "state: the active alert",
  H.reports("state")[#H.reports("state")].args.facts.top_alert == "Severe Thunderstorm Warning"
)
local nEvents = #H.reports("event")
H.fire("atmos-engine")
H.fire("atmos-engine")
check("no transition, no event (not a firehose)", #H.reports("event") == nEvents)
-- The data-health transitions are diagnostics.
routes["stations/KFLL/observations/latest"] = "FAIL"
routes["alerts/active?zone=FLZ173"] = "FAIL"
local dBefore = #H.reports("diagnostic")
for _ = 1, 3 do
  EC.REFRESH_WEATHER()
  EC.REFRESH_ALERTS()
end
local diags = H.reports("diagnostic")
local codes = {}
for i = dBefore + 1, #diags do
  codes[diags[i].args.code] = diags[i].args.severity
end
check(
  "the weather service going down is a warning diagnostic",
  codes["weather.service_unavailable"] == "warning",
  JSON:encode(codes)
)
check("every report is still valid for AI Core", H.allValid())
-- Simulation: never reported as real weather.
routes["stations/KFLL/observations/latest"] = observationBody
routes["alerts/active?zone=FLZ173"] = { features = { alertFeature } }
EC.REFRESH_ALL() -- service back (station re-chosen)
local eBefore = #H.reports("event")
EC["Start Simulation"]({ SCENARIO = "thunderstorm" })
local simFacts = H.reports("state")[#H.reports("state")].args.facts
check(
  "while simulating: state says simulation and carries no weather value",
  (simFacts.simulation == true and simFacts.temperature_f == nil),
  JSON:encode(simFacts)
)
check("while simulating: no event is reported", #H.reports("event") == eBefore)
check("(a simulation ran)", gSim ~= nil)
EC.STOP_SIMULATION()

print("[4] queries through the bus")
local r = H.aiAsk("atmosphere", "ai.query", { query_id = "weather_source", params = {} })
check(
  "weather_source: provider, office, station, last update",
  r
    and r.status == "ok"
    and r.result.ok == true
    and r.result.data.provider:find("National Weather Service", 1, true)
    and r.result.data.forecast_office == "MFL"
    and r.result.data.observation_station == "KFLL"
    and type(r.result.data.last_forecast_at) == "number",
  r and JSON:encode(r)
)
r = H.aiAsk("atmosphere", "ai.query", { query_id = "forecast", params = { days = 2 } })
check(
  "forecast: 2 days = 4 periods, with alerts",
  r and r.status == "ok" and #r.result.data.periods == 4 and r.result.data.periods[1].temperature_f == 92,
  r and JSON:encode(r)
)
r = H.aiAsk("atmosphere", "ai.query", { query_id = "forecast", params = { days = 8 } })
check(
  "forecast: days out of range refused (invalid_args)",
  r and r.status == "error" and r.error_code == "invalid_args"
)
r = H.aiAsk("atmosphere", "ai.query", { query_id = "forecast", params = { days = "two" } })
check("forecast: wrong type refused", r and r.error_code == "invalid_args")
r = H.aiAsk("atmosphere", "ai.action", {
  action_id = "refresh_now",
  params = {},
  ai_action_id = "a1",
  declaration_hash = aireport.declarationHash(),
})
check("no action is served (none declared; the bus refuses it)", r == nil or r.status == "error")

print("[5] AI Core goes away and comes back")
H.aiRemove()
H.pushDirectory()
check("property: Not installed", Properties["AI Core"] == "Not installed", Properties["AI Core"])
local frames = H.reportFrames()
routes["alerts/active?zone=FLZ173"] = { features = {} }
EC.REFRESH_ALL()
H.fire("atmos-engine")
check("no report frame while it is gone", H.reportFrames() == frames)
H.aiRegister()
H.pushDirectory()
check("back: Found — reporting", Properties["AI Core"] == "Found — reporting (v20261118.2)", Properties["AI Core"])
check("…describe sent again", #H.reports("describe") > #describes)

print("[6] REINITIALIZE restarts the helper")
local regs = H.count("SBOS_MODULE_REGISTER")
EC.REINITIALIZE()
H.pushDirectory()
check("re-registered", H.count("SBOS_MODULE_REGISTER") > regs)
check(
  "still reporting after REINITIALIZE",
  Properties["AI Core"] == "Found — reporting (v20261118.2)",
  Properties["AI Core"]
)
check("the helper's module timers are armed again", H.timers.SbosModuleStatus ~= nil)
check("every report AI Core ever got was valid", H.allValid())
local outside = {}
for _, v in ipairs(everPainted) do
  if not aireport.isValue(v) then
    outside[#outside + 1] = v
  end
end
check("only closed values were painted", #outside == 0, table.concat(outside, " | "))

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
