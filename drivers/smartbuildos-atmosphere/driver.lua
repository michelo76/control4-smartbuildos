--[[==========================================================================
  SmartBuildOS Atmosphere — Weather Intelligence for Control4

  Layer map (docs/atmosphere-architecture.md):
    src/atmosphere/nws.lua        api.weather.gov transport
    src/atmosphere/normalize.lua  raw JSON -> normalized weather objects
    src/atmosphere/engine.lua     the intelligence engine (pure)
    src/atmosphere/*              thresholds, predict, alerts, solar, sim...
    this file                     composition: timers, persistence, Control4
                                  surface (variables/events/conditionals/
                                  connections), the WebView data plane,
                                  licensing, diagnostics.

  Independence rule: everything weather works with NO SmartBuildOS pairing
  and NO platform reachability. Licensing rides the Agent when present;
  uncertainty fails open (sbos.license); weather safety logic is never
  gated on the license server.

  Failure model: last-good state is retained and marked stale with its age;
  missing values stay nil end-to-end (never 0); an API outage never
  fabricates events and never means "no alerts".
============================================================================]]

--#ifdef DRIVERCENTRAL
DC_PID = 0
DC_X = nil
DC_FILENAME = "smartbuildos-atmosphere.c4z"
--#else
DRIVER_GITHUB_REPO = "michelo76/control4-smartbuildos"
DRIVER_FILENAMES = { "smartbuildos-atmosphere.c4z" }
--#endif

require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")
require("drivers-common-public.global.url")

JSON = require("JSON")

local log = require("lib.logging")
local persist = require("lib.persist")
local license = require("sbos.license")

local nws = require("atmosphere.nws")
local normalize = require("atmosphere.normalize")
local engine = require("atmosphere.engine")
local walerts = require("atmosphere.alerts")
local solar = require("atmosphere.solar")
local scheduler = require("atmosphere.scheduler")
local simulator = require("atmosphere.simulator")
local settingsstore = require("atmosphere.settingsstore")
local uistate = require("atmosphere.uistate")
local units = require("atmosphere.units")

local uirelay = require("atmosphere.uirelay")

local WEBVIEW_BINDING = 5001
local TEMPERATURE_BINDING = 100
local HUMIDITY_BINDING = 101
local UI_RELAY_PORT = 47815
local UI_RELAY_ID = "atmosphere-ui-relay"
local P_RELAY_TOKEN = "atmos_relay_token"
local P_CLOUD_VIEW = "atmos_cloud_view"

-- Persist keys (plain; nothing here is a secret).
local P_POINTS = "atmos_points"
local P_STATION = "atmos_station"
local P_SETTINGS = "atmos_settings"
local P_SNAPSHOT = "atmos_snapshot"
local P_DAILY = "atmos_daily"
local P_HOURLY = "atmos_hourly"
local P_ALERTS = "atmos_alerts"
local P_FETCHED = "atmos_fetched"
local P_LOCATION = "atmos_location"

-- Timer ids.
local OBS_TIMER = "atmos-obs"
local FORECAST_TIMER = "atmos-forecast"
local ALERTS_TIMER = "atmos-alerts"
local ENGINE_TIMER = "atmos-engine"
local POINTS_TIMER = "atmos-points"
local SIM_TIMER = "atmos-sim"
local STARTUP_NOTIFY_MS = 60000 -- Control4 WebView Sample value; see insights

-- Variables: name, default, type. ORDER IS FROZEN — Composer binds computed
-- ids by add order. Append only.
local VARIABLES = {
  { "CURRENT_TEMPERATURE_F", "", "STRING" },
  { "CURRENT_TEMPERATURE_C", "", "STRING" },
  { "FEELS_LIKE_F", "", "STRING" },
  { "HUMIDITY_PERCENT", "", "STRING" },
  { "DEW_POINT_F", "", "STRING" },
  { "WIND_SPEED_MPH", "", "STRING" },
  { "WIND_GUST_MPH", "", "STRING" },
  { "WIND_DIRECTION", "", "STRING" },
  { "PRESSURE_INHG", "", "STRING" },
  { "VISIBILITY_MILES", "", "STRING" },
  { "CLOUD_COVER_PERCENT", "", "STRING" },
  { "CURRENT_CONDITION", "", "STRING" },
  { "WEATHER_MODE", "UNKNOWN", "STRING" },
  { "WEATHER_SEVERITY", "NORMAL", "STRING" },
  { "RAIN_PROBABILITY", "", "STRING" },
  { "FORECAST_HIGH_F", "", "STRING" },
  { "FORECAST_LOW_F", "", "STRING" },
  { "FORECAST_CONDITION", "", "STRING" },
  { "IS_RAINING", "false", "BOOL" },
  { "IS_SNOWING", "false", "BOOL" },
  { "IS_STORMING", "false", "BOOL" },
  { "IS_FREEZING", "false", "BOOL" },
  { "IS_HOT", "false", "BOOL" },
  { "IS_HIGH_WIND", "false", "BOOL" },
  { "IS_FOGGY", "false", "BOOL" },
  { "IS_DAYTIME", "false", "BOOL" },
  { "RAIN_EXPECTED_SOON", "false", "BOOL" },
  { "FREEZE_EXPECTED", "false", "BOOL" },
  { "STORM_EXPECTED", "false", "BOOL" },
  { "ACTIVE_ALERT_COUNT", "0", "NUMBER" },
  { "HIGHEST_ALERT_SEVERITY", "None", "STRING" },
  { "LATEST_ALERT_NAME", "", "STRING" },
  { "LATEST_ALERT_HEADLINE", "", "STRING" },
  { "SUNRISE", "", "STRING" },
  { "SUNSET", "", "STRING" },
  { "MINUTES_TO_SUNRISE", "", "STRING" },
  { "MINUTES_TO_SUNSET", "", "STRING" },
  { "LAST_WEATHER_UPDATE", "", "STRING" },
  { "DATA_AGE_SECONDS", "", "STRING" },
  { "DATA_STALE", "false", "BOOL" },
  { "API_STATUS", "Unknown", "STRING" },
  { "LICENSE_STATUS", "", "STRING" },
  { "SIMULATION_ACTIVE", "false", "BOOL" },
}

-- ─── State ────────────────────────────────────────────────────────────────────

gInitialized = false
gPoints = nil -- normalized /points discovery record
gStations = {} -- ordered candidate station ids
gStation = nil -- chosen station id
gLocation = nil -- { lat, lon, source, label }
gSettings = settingsstore.defaults()
gSnapshot = nil -- last engine snapshot (persisted)
gObs = nil -- last normalized observation
gDaily = {} -- normalized daily periods
gHourly = {} -- normalized hourly periods
gAlertSet = {} -- active raw set { [id] = alert } (post-reconcile)
gFetched = { obs = nil, forecast = nil, alerts = nil, points = nil }
gFailures = { observations = 0, forecast = 0, alerts = 0, points = 0 }
gSim = nil -- { scenario, startedAt, data = { obs, alerts } }
gDiag = {
  lastSuccess = {},
  lastFailure = {},
  lastHttpCode = {},
  lastError = {},
  lastLatencyMs = {},
}
gUiSubscribed = false
gNavigateHint = nil -- { screen, at } — a one-shot hint for an open app
gRelayPort = nil -- LAN state relay: listening port, or nil when stopped
gRelayToken = nil -- minted once, persisted; rides the web_view_url query
gRelayBuffers = {} -- per-connection request accumulation (chunked POSTs)
gPublishedUrl = nil -- last URL_CHANGED value, so the tick can heal it
gCloudView = nil -- { url, handle } from the Agent's cloud-mirror ack
gCloudLastAsk = 0 -- throttle for asking the Agent to mirror state

-- ─── Small helpers ────────────────────────────────────────────────────────────

local function fireEvent(name)
  pcall(function()
    C4:FireEvent(name)
  end)
end

local function setVariable(name, value)
  pcall(function()
    C4:SetVariable(name, tostring(value))
  end)
end

local function setConditional(name, value)
  pcall(function()
    C4:SetConditionalState(name, value == true)
  end)
end

--- os.time() IS the UTC epoch; os.date() without "!" localizes it. The only
--- derived quantity we need is the site's UTC offset (seconds east), which
--- falls out of interpreting a UTC broken-down table as local time.
local function nowUtc()
  return os.time()
end

local function localOffset()
  return os.time() - os.time(os.date("!*t"))
end

local function fmtLocalTime(epoch)
  if epoch == nil then
    return ""
  end
  return os.date("%H:%M", epoch)
end

local function orDash(v)
  if v == nil or v == "" then
    return "-"
  end
  return tostring(v)
end

local function diagOk(class, latencyMs)
  gDiag.lastSuccess[class] = nowUtc()
  gDiag.lastHttpCode[class] = 200
  gDiag.lastError[class] = nil
  gDiag.lastLatencyMs[class] = latencyMs
end

local function diagFail(class, err)
  gDiag.lastFailure[class] = nowUtc()
  gDiag.lastHttpCode[class] = err ~= nil and err.code or nil
  gDiag.lastError[class] = err ~= nil and tostring(err.error) or "unknown"
end

-- ─── Settings ─────────────────────────────────────────────────────────────────

local function loadSettings()
  gSettings = settingsstore.load(persist:get(P_SETTINGS))
end

local function saveSettings()
  persist:set(P_SETTINGS, gSettings)
end

--- Applies a validated settings patch (from the WebView app or SmartBuildOS
--- remote settings). Returns refusals for the caller to report.
local function applySettingsPatch(patch, source)
  local clean, refused = settingsstore.validate(patch)
  gSettings = settingsstore.merge(gSettings, clean)
  saveSettings()
  if #refused > 0 then
    for _, r in ipairs(refused) do
      log:warn("Settings refusal (%s): %s - %s", tostring(source), tostring(r.path), tostring(r.reason))
    end
  end
  runEngine("settings")
  return refused
end

-- ─── Location resolution ──────────────────────────────────────────────────────

--- Resolves site coordinates by the configured chain. Returns nil when no
--- source yields coordinates (driver states "location unresolved" honestly).
local function resolveLocation()
  local source = tostring(Properties["Location Source"] or "Control4 Project")
  if source == "Manual Coordinates" then
    local lat = tonumber(Properties["Latitude"])
    local lon = tonumber(Properties["Longitude"])
    if lat ~= nil and lon ~= nil and lat >= -90 and lat <= 90 and lon >= -180 and lon <= 180 then
      return { lat = lat, lon = lon, source = "manual", label = string.format("%.4f, %.4f", lat, lon) }
    end
    return nil
  end
  -- Control4 Project: Director's own location (GetProjectItems — safe here,
  -- this is only ever called at/after LateInit). Parsed directly with a
  -- tolerant pattern: the vendored GetLocationInfo captures lat/long with an
  -- XMLCapture("latitude>") quirk whose pattern only matches one exact XML
  -- shape — attributes or shape drift silently yield nil. TEST_PLAN carries
  -- the verify-on-hardware item for the real Director XML.
  local okProj, proj = pcall(function()
    return XMLDecode(C4:GetProjectItems("LOCATIONS", "LIMIT_DEVICE_DATA", "NO_ROOT_TAGS"))
  end)
  if okProj and type(proj) == "string" then
    local function grab(tag)
      return proj:match("<" .. tag .. "[^>]*>%s*([^<]-)%s*</" .. tag .. ">")
    end
    local lat = tonumber(grab("latitude"))
    local lon = tonumber(grab("longitude"))
    if lat ~= nil and lon ~= nil and not (lat == 0 and lon == 0) then
      local city = grab("city_name")
      local zip = grab("zipcode")
      local label = tostring(city or "")
      if label == "" then
        label = string.format("%.4f, %.4f", lat, lon)
      end
      return { lat = lat, lon = lon, source = "project", label = label, zip = zip, city = city }
    end
  end
  return nil
end

-- ─── Fetch pipeline ───────────────────────────────────────────────────────────

local scheduleFetch -- fwd decl
runEngine = nil -- global fwd decl (assigned below; engine tick calls it)

local function chooseStation(index)
  index = index or 1
  local candidate = gStations[index]
  if candidate == nil then
    log:warn("No reporting observation station found (%d tried)", index - 1)
    return
  end
  nws.latestObservation(candidate, function(props, err)
    if props == nil then
      diagFail("observations", err)
      chooseStation(index + 1)
      return
    end
    local obs = normalize.observation(props)
    -- A station whose latest observation is over 90 minutes old is not
    -- reporting; fall down the (nearest-first) list, max 4 candidates.
    if obs == nil or (nowUtc() - obs.timestamp) > 90 * 60 then
      if index < 4 then
        chooseStation(index + 1)
        return
      end
    end
    if obs ~= nil then
      gStation = candidate
      persist:set(P_STATION, candidate)
      UpdateProperty("Observation Station", candidate)
      gObs = obs
      gFetched.obs = nowUtc()
      diagOk("observations")
      gFailures.observations = 0
      runEngine("observation")
    end
  end)
end

local function fetchObservations()
  if gStation == nil then
    if #gStations > 0 then
      chooseStation(1)
    end
    scheduleFetch("observations")
    return
  end
  local started = os.clock()
  nws.latestObservation(gStation, function(props, err)
    if props == nil then
      diagFail("observations", err)
      gFailures.observations = gFailures.observations + 1
      -- The station may have gone quiet; re-run selection on repeat failure.
      if gFailures.observations >= 3 and #gStations > 0 then
        gStation = nil
      end
      runEngine("observation-failure")
    else
      local obs = normalize.observation(props)
      if obs ~= nil then
        gObs = obs
        gFetched.obs = nowUtc()
        diagOk("observations", math.floor((os.clock() - started) * 1000))
        gFailures.observations = 0
        runEngine("observation")
      else
        diagFail("observations", { error = "unparseable observation" })
        gFailures.observations = gFailures.observations + 1
      end
    end
    scheduleFetch("observations")
  end)
end

local function fetchForecast()
  if gPoints == nil then
    scheduleFetch("forecast")
    return
  end
  local pending = 2
  local anyFailure = false
  local function done()
    pending = pending - 1
    if pending > 0 then
      return
    end
    if anyFailure then
      gFailures.forecast = gFailures.forecast + 1
    else
      gFailures.forecast = 0
      gFetched.forecast = nowUtc()
      diagOk("forecast")
    end
    runEngine("forecast")
    scheduleFetch("forecast")
  end
  nws.forecast(gPoints.forecastUrl, function(props, err)
    if props == nil then
      anyFailure = true
      diagFail("forecast", err)
    else
      gDaily = normalize.periods(props.periods)
      persist:set(P_DAILY, gDaily)
    end
    done()
  end)
  nws.forecast(gPoints.forecastHourlyUrl, function(props, err)
    if props == nil then
      anyFailure = true
      diagFail("forecast", err)
    else
      gHourly = normalize.periods(props.periods)
      persist:set(P_HOURLY, gHourly)
    end
    done()
  end)
end

local function fetchAlerts()
  local opts = {}
  if gPoints ~= nil and gPoints.forecastZone ~= nil then
    opts.zone = gPoints.forecastZone
  elseif gLocation ~= nil then
    opts.lat = gLocation.lat
    opts.lon = gLocation.lon
  else
    scheduleFetch("alerts")
    return
  end
  nws.activeAlerts(opts, function(list, err)
    local fetched = nil
    if list == nil then
      diagFail("alerts", err)
      gFailures.alerts = gFailures.alerts + 1
    else
      fetched = {}
      local filter = settingsstore.alertSettings(gSettings)
      for _, raw in ipairs(list) do
        local a = walerts.normalize(raw)
        if a ~= nil and walerts.admitted(a, filter) then
          fetched[#fetched + 1] = a
        end
      end
      gFailures.alerts = 0
      gFetched.alerts = nowUtc()
      diagOk("alerts")
    end
    local result = walerts.reconcile(gAlertSet, fetched, nowUtc())
    gAlertSet = result.active
    persist:set(P_ALERTS, gAlertSet)
    runEngine("alerts", result)
    scheduleFetch("alerts")
  end)
end

local function discoverPoints(reason)
  if gLocation == nil then
    UpdateProperty("Resolved Location", "Not resolved - set the project location or manual coordinates")
    UpdateProperty("Weather Status", "No location configured")
    return
  end
  log:info("Discovering NWS endpoints for %.4f, %.4f (%s)", gLocation.lat, gLocation.lon, tostring(reason))
  nws.points(gLocation.lat, gLocation.lon, function(props, err)
    if props == nil then
      diagFail("points", err)
      gFailures.points = gFailures.points + 1
      -- Cached discovery keeps working; retry on the backoff ladder.
      CancelTimer(POINTS_TIMER)
      SetTimer(POINTS_TIMER, scheduler.nextDelay("points", gFailures.points) * ONE_SECOND, function()
        discoverPoints("retry")
      end, false)
      if gPoints == nil then
        UpdateProperty("Weather Status", "Location discovery failed - will retry")
      end
      return
    end
    local pts = normalize.points(props)
    if pts == nil then
      -- A /points answer with no grid = outside NWS coverage (non-US).
      diagFail("points", { error = "no NWS coverage for this location" })
      UpdateProperty("Weather Status", "Location is outside NWS coverage (US only)")
      UpdateProperty("Resolved Location", gLocation.label .. " (unsupported)")
      return
    end
    gPoints = pts
    gFailures.points = 0
    gFetched.points = nowUtc()
    diagOk("points")
    persist:set(P_POINTS, pts)
    UpdateProperty("Forecast Office", string.format("%s grid %d,%d", pts.office, pts.gridX, pts.gridY))
    UpdateProperty("Resolved Location", string.format("%s (%.4f, %.4f)", gLocation.label, gLocation.lat, gLocation.lon))
    nws.stations(pts.observationStationsUrl, function(ids)
      if ids ~= nil and #ids > 0 then
        gStations = ids
        if gStation == nil then
          chooseStation(1)
        end
      end
    end)
    fetchForecast()
    fetchAlerts()
    -- Slow periodic re-check: the office/grid mapping for a fixed coordinate
    -- CAN change (official docs) — re-resolve daily.
    CancelTimer(POINTS_TIMER)
    SetTimer(POINTS_TIMER, scheduler.CADENCE.points * ONE_SECOND, function()
      discoverPoints("periodic")
    end, false)
  end)
end

scheduleFetch = function(class)
  local delay
  if class == "observations" then
    delay = scheduler.nextDelay("observations", gFailures.observations)
    CancelTimer(OBS_TIMER)
    SetTimer(OBS_TIMER, delay * ONE_SECOND, fetchObservations, false)
  elseif class == "forecast" then
    delay = scheduler.nextDelay("forecast", gFailures.forecast)
    CancelTimer(FORECAST_TIMER)
    SetTimer(FORECAST_TIMER, delay * ONE_SECOND, fetchForecast, false)
  elseif class == "alerts" then
    delay = scheduler.nextDelay("alerts", gFailures.alerts)
    CancelTimer(ALERTS_TIMER)
    SetTimer(ALERTS_TIMER, delay * ONE_SECOND, fetchAlerts, false)
  end
end

-- ─── Publishing (variables / properties / connections / UI) ──────────────────

local function publishValueConnections(snapshot)
  local obs = snapshot.obs
  if obs == nil or snapshot.obsStale then
    -- A thermostat holding a stale outdoor reading is worse than one showing
    -- none (bond-weather rule).
    SendToProxy(TEMPERATURE_BINDING, "VALUE_UNAVAILABLE", { STATUS = "offline" }, "NOTIFY")
    SendToProxy(HUMIDITY_BINDING, "VALUE_UNAVAILABLE", { STATUS = "offline" }, "NOTIFY")
    return
  end
  if obs.tempC ~= nil then
    SendToProxy(TEMPERATURE_BINDING, "VALUE_CHANGED", {
      CELSIUS = units.one(obs.tempC),
      FAHRENHEIT = units.one(obs.tempF),
      TIMESTAMP = obs.timestamp,
    }, "NOTIFY")
  end
  if obs.humidity ~= nil then
    SendToProxy(HUMIDITY_BINDING, "VALUE_CHANGED", {
      VALUE = units.round(obs.humidity),
      TIMESTAMP = obs.timestamp,
    }, "NOTIFY")
  end
end

--- Today's high/low from the daily periods (first daytime / first night).
local function todayHighLow()
  local high, low, condition = nil, nil, nil
  for _, p in ipairs(gDaily) do
    if p.isDaytime and high == nil then
      high = p.tempF
      condition = p.shortForecast
    elseif not p.isDaytime and low == nil then
      low = p.tempF
    end
    if high ~= nil and low ~= nil then
      break
    end
  end
  return high, low, condition
end

local function currentSolar()
  if gLocation == nil then
    return nil
  end
  return solar.solarState(gLocation.lat, gLocation.lon, nowUtc(), localOffset())
end

local function publishVariables(snapshot)
  local obs = snapshot.obs
  local s = snapshot.states or {}
  local p = snapshot.predictions or {}
  setVariable("CURRENT_TEMPERATURE_F", obs ~= nil and units.one(obs.tempF, "") or "")
  setVariable("CURRENT_TEMPERATURE_C", obs ~= nil and units.one(obs.tempC, "") or "")
  setVariable("FEELS_LIKE_F", obs ~= nil and units.one(obs.feelsLikeF, "") or "")
  setVariable("HUMIDITY_PERCENT", obs ~= nil and tostring(units.round(obs.humidity) or "") or "")
  setVariable("DEW_POINT_F", obs ~= nil and units.one(obs.dewpointF, "") or "")
  setVariable("WIND_SPEED_MPH", obs ~= nil and units.one(obs.windMph, "") or "")
  setVariable("WIND_GUST_MPH", obs ~= nil and units.one(obs.gustMph, "") or "")
  setVariable("WIND_DIRECTION", obs ~= nil and (obs.windCompass or "") or "")
  setVariable("PRESSURE_INHG", obs ~= nil and units.one(obs.pressureInHg, "") or "")
  setVariable("VISIBILITY_MILES", obs ~= nil and units.one(obs.visibilityMi, "") or "")
  setVariable("CLOUD_COVER_PERCENT", obs ~= nil and tostring(obs.cloudCover or "") or "")
  setVariable("CURRENT_CONDITION", obs ~= nil and obs.textDescription or "")
  setVariable("WEATHER_MODE", snapshot.mode)
  setVariable("WEATHER_SEVERITY", snapshot.severity)

  local high, low, condition = todayHighLow()
  setVariable("FORECAST_HIGH_F", high ~= nil and tostring(units.round(high)) or "")
  setVariable("FORECAST_LOW_F", low ~= nil and tostring(units.round(low)) or "")
  setVariable("FORECAST_CONDITION", condition or "")
  local pop = nil
  for _, hp in ipairs(gHourly) do
    if hp.pop ~= nil then
      pop = hp.pop
      break
    end
  end
  setVariable("RAIN_PROBABILITY", pop ~= nil and tostring(pop) or "")

  setVariable("IS_RAINING", s.is_raining and "true" or "false")
  setVariable("IS_SNOWING", s.is_snowing and "true" or "false")
  setVariable("IS_STORMING", s.is_storming and "true" or "false")
  setVariable("IS_FREEZING", s.is_freezing and "true" or "false")
  setVariable("IS_HOT", s.is_hot and "true" or "false")
  setVariable("IS_HIGH_WIND", s.is_high_wind and "true" or "false")
  setVariable("IS_FOGGY", s.is_foggy and "true" or "false")
  setVariable("RAIN_EXPECTED_SOON", p.rain_soon and "true" or "false")
  setVariable("FREEZE_EXPECTED", p.freeze_expected_tonight and "true" or "false")
  setVariable("STORM_EXPECTED", p.storm_expected and "true" or "false")

  setVariable("ACTIVE_ALERT_COUNT", snapshot.activeAlertCount or 0)
  setVariable("HIGHEST_ALERT_SEVERITY", snapshot.highestAlertSeverity or "None")
  setVariable("LATEST_ALERT_NAME", snapshot.topAlert ~= nil and snapshot.topAlert.event or "")
  setVariable("LATEST_ALERT_HEADLINE", snapshot.topAlert ~= nil and (snapshot.topAlert.headline or "") or "")

  local sol = currentSolar()
  if sol ~= nil then
    setVariable("SUNRISE", fmtLocalTime(sol.sunrise))
    setVariable("SUNSET", fmtLocalTime(sol.sunset))
    setVariable("MINUTES_TO_SUNRISE", sol.minutesToSunrise or "")
    setVariable("MINUTES_TO_SUNSET", sol.minutesToSunset or "")
    setVariable("IS_DAYTIME", sol.isDaytime and "true" or "false")
    setConditional("ATMOSPHERE_DAYTIME", sol.isDaytime)
  end

  setVariable("LAST_WEATHER_UPDATE", gFetched.obs ~= nil and os.date("%Y-%m-%d %H:%M:%S", gFetched.obs) or "")
  setVariable("DATA_AGE_SECONDS", gFetched.obs ~= nil and (nowUtc() - gFetched.obs) or "")
  setVariable("DATA_STALE", snapshot.dataStale and "true" or "false")
  setVariable("API_STATUS", snapshot.apiOk and "Online" or "Unavailable")
  setVariable("LICENSE_STATUS", license.status())
  setVariable("SIMULATION_ACTIVE", snapshot.simulation and "true" or "false")

  setConditional("ATMOSPHERE_RAINING", s.is_raining)
  setConditional("ATMOSPHERE_SNOWING", s.is_snowing)
  setConditional("ATMOSPHERE_STORMING", s.is_storming)
  setConditional("ATMOSPHERE_FREEZING", s.is_freezing)
  setConditional("ATMOSPHERE_HIGH_WIND", s.is_high_wind)
  setConditional("ATMOSPHERE_ALERT_ACTIVE", (snapshot.activeAlertCount or 0) > 0)
  setConditional("ATMOSPHERE_DATA_STALE", snapshot.dataStale)
  setConditional("ATMOSPHERE_SIMULATION", snapshot.simulation)
end

local function publishProperties(snapshot)
  local obs = snapshot.obs
  local line
  if obs ~= nil and obs.tempF ~= nil then
    line = string.format("%s°F %s", units.one(obs.tempF), orDash(obs.textDescription))
  else
    line = "No observation yet"
  end
  if snapshot.simulation then
    line = "SIMULATION: " .. line
  end
  if snapshot.dataStale then
    line = line .. " (STALE)"
  end
  UpdateProperty("Weather Status", line)
  local age = gFetched.obs ~= nil and (nowUtc() - gFetched.obs) or nil
  UpdateProperty(
    "Data Freshness",
    age ~= nil and string.format("obs %dm ago%s", math.floor(age / 60), snapshot.dataStale and " - STALE" or "") or "-"
  )
  local alertLine = "None"
  if (snapshot.activeAlertCount or 0) > 0 then
    alertLine = string.format(
      "%d active - highest: %s (%s)",
      snapshot.activeAlertCount,
      orDash(snapshot.topAlert ~= nil and snapshot.topAlert.event or nil),
      snapshot.highestAlertSeverity
    )
  end
  UpdateProperty("Active Alerts", alertLine)
  UpdateProperty("Simulation", gSim ~= nil and ("Running: " .. gSim.scenario) or "Off")
end

-- ─── WebView data plane ───────────────────────────────────────────────────────

local function buildDiagnostics()
  return {
    api = {
      observations = {
        last_success = gDiag.lastSuccess.observations,
        last_failure = gDiag.lastFailure.observations,
        http_code = gDiag.lastHttpCode.observations,
        error = gDiag.lastError.observations,
        failures = gFailures.observations,
      },
      forecast = {
        last_success = gDiag.lastSuccess.forecast,
        last_failure = gDiag.lastFailure.forecast,
        http_code = gDiag.lastHttpCode.forecast,
        error = gDiag.lastError.forecast,
        failures = gFailures.forecast,
      },
      alerts = {
        last_success = gDiag.lastSuccess.alerts,
        last_failure = gDiag.lastFailure.alerts,
        http_code = gDiag.lastHttpCode.alerts,
        error = gDiag.lastError.alerts,
        failures = gFailures.alerts,
      },
      points = {
        last_success = gDiag.lastSuccess.points,
        last_failure = gDiag.lastFailure.points,
        error = gDiag.lastError.points,
      },
    },
    office = gPoints ~= nil and gPoints.office or nil,
    grid = gPoints ~= nil and string.format("%d,%d", gPoints.gridX, gPoints.gridY) or nil,
    station = gStation,
    zone = gPoints ~= nil and gPoints.forecastZone or nil,
    radar_station = gPoints ~= nil and gPoints.radarStation or nil,
    time_zone = gPoints ~= nil and gPoints.timeZone or nil,
    polling = {
      observations = scheduler.nextDelay("observations", gFailures.observations),
      forecast = scheduler.nextDelay("forecast", gFailures.forecast),
      alerts = scheduler.nextDelay("alerts", gFailures.alerts),
    },
    driver_version = tostring(C4:GetDriverConfigInfo("version")),
    agent = license.describe(),
  }
end

local function buildUiState()
  return uistate.build({
    snapshot = gSnapshot or {},
    daily = gDaily,
    hourly = gHourly,
    settings = gSettings,
    solar = currentSolar(),
    location = {
      label = gLocation ~= nil and gLocation.label or nil,
      lat = gLocation ~= nil and gLocation.lat or nil,
      lon = gLocation ~= nil and gLocation.lon or nil,
      source = gLocation ~= nil and gLocation.source or nil,
      radar_station = gPoints ~= nil and gPoints.radarStation or nil,
      office = gPoints ~= nil and gPoints.office or nil,
      time_zone = gPoints ~= nil and gPoints.timeZone or nil,
    },
    diagnostics = buildDiagnostics(),
    license = {
      status = license.status(),
      label = license.statusLabel(),
      operational = license.isOperational(),
    },
    navigate = gNavigateHint,
    now = nowUtc(),
  })
end

--- Pushes state at the page. C4:SendDataToUI existence is checked at call
--- time (UNCONFIRMED on all OS builds). Field-measured 2026-08-31: the JS
--- API reply channel can deliver NOTHING on real Navigators, so this push
--- is best-effort and the LAN relay below is the contract. Ungated — a
--- page we never heard from still deserves the push attempt.
local function pushUiState()
  local ok, encoded = pcall(function()
    return JSON:encode(buildUiState())
  end)
  if not ok then
    return
  end
  pcall(function()
    if C4.SendDataToUI ~= nil then
      C4:SendDataToUI(encoded)
    end
  end)
end

-- ─── Agent health forwarding ─────────────────────────────────────────────────

--- Data-health transitions are dealer-operations signals, so they ride the
--- SmartBuildOS Agent's generic event path into the platform when an Agent
--- is present (weather events themselves stay local — a rain shower is not
--- a service incident). No Agent, no-op.
local HEALTH_EVENT_DETAIL = {
  ["Weather Data Stale"] = "Atmosphere weather data exceeded its freshness threshold",
  ["Weather Data Restored"] = "Atmosphere weather data is fresh again",
  ["Weather API Unavailable"] = "api.weather.gov stopped answering from this controller",
  ["Weather API Recovered"] = "api.weather.gov recovered",
}

local function findAgentId()
  for rawId, device in pairs(C4:GetDevices({}) or {}) do
    local file = tostring((type(device) == "table" and device.driverFileName) or "")
    -- Exact match, never substring (smartbuildos-insights.c4z is the near-miss).
    if file == "smartbuildos.c4z" or file == "smartbuildos.c4i" then
      return tonumber(rawId)
    end
  end
  return nil
end

function forwardHealthEvents(events)
  local agentId = nil
  for _, name in ipairs(events) do
    local detail = HEALTH_EVENT_DETAIL[name]
    if detail ~= nil then
      agentId = agentId or findAgentId()
      if agentId == nil then
        return
      end
      pcall(function()
        C4:SendToDevice(agentId, "SEND_EVENT", { NAME = "Atmosphere: " .. name, DETAIL = detail })
      end)
    end
  end
end

-- ─── The engine tick ──────────────────────────────────────────────────────────

--- Runs the intelligence engine over current inputs and publishes everything.
--- `alertsResult` is passed only from the alerts poll; other callers leave
--- the active set as-is.
function runEngine(reason, alertsResult)
  if not gInitialized then
    return
  end
  local simActive = gSim ~= nil
  local obs = gObs
  local obsAt = gFetched.obs
  local ar = alertsResult
  if ar == nil and not simActive then
    -- Always hand the engine the REAL active set — otherwise a snapshot taken
    -- during simulation would leak simulated alerts into post-sim state.
    ar = { active = gAlertSet, new = {}, updated = {}, canceled = {}, expired = {}, escalated = {} }
  end
  if simActive then
    if gSim.data.obs ~= nil then
      obs = gSim.data.obs
      obsAt = nowUtc()
    end
    -- Simulated alerts run through the same reconcile machinery.
    if gSim.pendingAlerts ~= nil then
      ar = walerts.reconcile(gSim.lastActive or {}, gSim.pendingAlerts, nowUtc())
      gSim.lastActive = ar.active
      gSim.pendingAlerts = nil
    elseif gSim.lastActive ~= nil then
      ar = { active = gSim.lastActive, new = {}, updated = {}, canceled = {}, expired = {}, escalated = {} }
    end
  end

  local inputs = {
    obs = obs,
    hourly = gHourly,
    alertsResult = ar,
    thresholds = settingsstore.effectiveThresholds(gSettings),
    now = nowUtc(),
    localOffset = localOffset(),
    obsFetchedAt = simActive and obsAt or gFetched.obs,
    forecastFetchedAt = gFetched.forecast,
    alertsFetchedAt = simActive and nowUtc() or gFetched.alerts,
    apiOk = gFailures.observations < 3 and gFailures.alerts < 3,
    simulation = simActive,
  }
  local snapshot, events = engine.step(gSnapshot, inputs)
  gSnapshot = snapshot
  persist:set(P_SNAPSHOT, {
    states = snapshot.states,
    predictions = snapshot.predictions,
    mode = snapshot.mode,
    severity = snapshot.severity,
    dataStale = snapshot.dataStale,
    apiOk = snapshot.apiOk,
    simulation = snapshot.simulation,
  })
  for _, name in ipairs(events) do
    log:info("Event: %s%s", name, snapshot.simulation and " [SIMULATION]" or "")
    fireEvent(name)
  end
  if not snapshot.simulation then
    forwardHealthEvents(events)
  end
  -- Cloud state mirror: ask the Agent to republish our state (it fetches
  -- from our relay on localhost and POSTs with its bearer auth).
  -- askCloudMirror is a GLOBAL assigned in the relay section below —
  -- defined by the time any engine run happens (LateInit onward).
  if askCloudMirror ~= nil then
    askCloudMirror(#events > 0)
  end
  publishVariables(snapshot)
  publishProperties(snapshot)
  publishValueConnections(snapshot)
  pushUiState()
  log:trace(
    "Engine ran (%s): mode=%s severity=%s events=%d",
    tostring(reason),
    snapshot.mode,
    snapshot.severity,
    #events
  )
end

-- ─── Simulation control ───────────────────────────────────────────────────────

local function startSimulation(scenario)
  local data = simulator.build(scenario, nowUtc())
  if data == nil then
    log:warn("Unknown simulation scenario: %s", tostring(scenario))
    return false
  end
  gSim = {
    scenario = tostring(scenario),
    startedAt = nowUtc(),
    data = data,
    pendingAlerts = data.alerts or {},
    lastActive = {},
  }
  log:print(
    "SIMULATION started: %s (auto-stops in %d minutes)",
    tostring(scenario),
    gSettings.simulation.timeout_minutes
  )
  CancelTimer(SIM_TIMER)
  SetTimer(SIM_TIMER, gSettings.simulation.timeout_minutes * 60 * ONE_SECOND, function()
    stopSimulation("timeout")
  end, false)
  runEngine("simulation-start")
  return true
end

function stopSimulation(reason)
  if gSim == nil then
    return
  end
  log:print("SIMULATION stopped (%s): %s", tostring(reason), gSim.scenario)
  gSim = nil
  CancelTimer(SIM_TIMER)
  runEngine("simulation-stop")
end

-- ─── WebView command surface (JS API + proxy + Composer) ─────────────────────

--- GET_STATE returns the full UI document; SET_SETTINGS applies a patch.
--- Registered in UIR (Navigator JS API), RFP (proxy path) and EC (Composer/
--- programming) — belt and braces, same dispatch (repo pattern).
local function uiGetState()
  gUiSubscribed = true
  local ok, encoded = pcall(function()
    return JSON:encode(buildUiState())
  end)
  return ok and encoded or "{}"
end

local function uiSetSettings(tParams)
  local raw = tParams ~= nil and tParams.SETTINGS or nil
  if raw == nil then
    return '{"ok":false,"error":"no SETTINGS param"}'
  end
  local ok, patch = pcall(function()
    return JSON:decode(tostring(raw))
  end)
  if not ok or type(patch) ~= "table" then
    return '{"ok":false,"error":"SETTINGS is not valid JSON"}'
  end
  local refused = applySettingsPatch(patch, "webview")
  local okEnc, encoded = pcall(function()
    return JSON:encode({ ok = true, refused = refused })
  end)
  return okEnc and encoded or '{"ok":true}'
end

local function uiCommand(cmd, tParams)
  if cmd == "ATMOS_GET_STATE" then
    return uiGetState()
  elseif cmd == "ATMOS_SET_SETTINGS" then
    return uiSetSettings(tParams)
  elseif cmd == "ATMOS_REFRESH" then
    fetchObservations()
    fetchForecast()
    fetchAlerts()
    return '{"ok":true}'
  elseif cmd == "ATMOS_SIMULATE" then
    local scenario = tParams ~= nil and tParams.SCENARIO or nil
    if scenario == nil or scenario == "" then
      stopSimulation("webview")
      return '{"ok":true,"stopped":true}'
    end
    return startSimulation(scenario) and '{"ok":true}' or '{"ok":false,"error":"unknown scenario"}'
  end
  return nil
end

for _, cmd in ipairs({ "ATMOS_GET_STATE", "ATMOS_SET_SETTINGS", "ATMOS_REFRESH", "ATMOS_SIMULATE" }) do
  UIR[cmd] = function(tParams)
    return uiCommand(cmd, tParams)
  end
  RFP[cmd] = function(_, _, tParams)
    return uiCommand(cmd, tParams)
  end
  EC[cmd] = function(tParams)
    return uiCommand(cmd, tParams)
  end
end
UIR.suppressDebug = { ATMOS_GET_STATE = true }

-- ─── LAN state relay ─────────────────────────────────────────────────────────
--
-- Field-measured (Doerr touchscreen, 2026-08-31): the app renders but the
-- JS API delivers no state. The Protect-proven answer: the driver listens on
-- a controller port; the page fetches plain LAN HTTP. The relay address and
-- token ride the web_view_url query — the one channel that provably reaches
-- the page. src/atmosphere/uirelay.lua owns parsing/routing (pure, tested).

--- Finds the first non-loopback IPv4 anywhere in a Director bindings
--- answer. Director's shape VARIES BY PROJECT/OS (field-measured: sometimes
--- flat `networkbindings`, sometimes nested under a `bindings` array) — so
--- this walks the whole structure, depth-bounded and cycle-guarded, instead
--- of trusting any one documented layout.
local function findAddrDeep(node, depth, seen)
  if type(node) ~= "table" or depth > 6 or seen[node] then
    return nil
  end
  seen[node] = true
  local addr = tostring(node.addr or "")
  if addr:match("^%d+%.%d+%.%d+%.%d+$") ~= nil and addr:find("^127%.") == nil then
    return addr
  end
  for _, child in pairs(node) do
    if type(child) == "table" then
      local found = findAddrDeep(child, depth + 1, seen)
      if found ~= nil then
        return found
      end
    end
  end
  return nil
end

--- The controller's LAN address. Order: the App Relay Address property
--- (dealer override, Protect-proven escape hatch), then discovery — every
--- control4_* device's bindings via BOTH APIs, deep-walked.
local function relayHost()
  local configured = tostring(Properties["App Relay Address"] or ""):gsub("%s+", "")
  if configured ~= "" and configured:lower() ~= "auto" then
    return configured
  end
  local ok, devices = pcall(function()
    return C4:GetDevices({})
  end)
  if not ok or type(devices) ~= "table" then
    return ""
  end
  for rawId, device in pairs(devices) do
    local id = tonumber(rawId)
    local file = tostring((type(device) == "table" and device.driverFileName) or "")
    if id ~= nil and file:find("^control4_") ~= nil then
      for _, api in ipairs({ "GetNetworkBindingsByDevice", "GetBindingsByDevice" }) do
        local okB, raw = pcall(function()
          return C4[api](C4, id)
        end)
        if okB and type(raw) == "table" then
          local found = findAddrDeep(raw, 0, {})
          if found ~= nil then
            return found
          end
        end
      end
    end
  end
  return ""
end

local function relayToken()
  if gRelayToken ~= nil then
    return gRelayToken
  end
  local stored = persist:get(P_RELAY_TOKEN, nil, true)
  if type(stored) == "string" and #stored >= 16 then
    gRelayToken = stored
    return stored
  end
  -- Minted from non-secret-but-unguessable local entropy; the token's job is
  -- keeping casual LAN clients out of settings writes, same posture as the
  -- Protect webhook token.
  local seed = string.format("%d|%d|%d|%s", os.time(), os.clock() * 1000000, C4:GetDeviceID(), tostring({}))
  local ok, hex = pcall(function()
    return C4:HMAC("SHA256", seed, "atmosphere-relay", { return_encoding = "HEX" })
  end)
  local token = ok and type(hex) == "string" and hex:sub(1, 32) or tostring(os.time()) .. tostring(os.clock())
  gRelayToken = token
  persist:set(P_RELAY_TOKEN, token, true)
  return token
end

local relayProvider = {
  state = function()
    return JSON:encode(buildUiState())
  end,
  applySettings = function(bodyText)
    local ok, doc = pcall(function()
      return JSON:decode(tostring(bodyText))
    end)
    if not ok or type(doc) ~= "table" then
      return nil
    end
    local patch = type(doc.settings) == "table" and doc.settings or doc
    return applySettingsPatch(patch, "webview-relay")
  end,
  refresh = function()
    fetchObservations()
    fetchForecast()
    fetchAlerts()
  end,
  simulate = function(scenario)
    if scenario == nil or scenario == "" then
      stopSimulation("webview-relay")
      return true
    end
    return startSimulation(scenario)
  end,
  encode = function(t)
    return JSON:encode(t)
  end,
  decode = function(s)
    return JSON:decode(tostring(s))
  end,
}

function OnServerDataIn(handle, data, _, _, identifier)
  if identifier ~= nil and identifier ~= UI_RELAY_ID then
    return
  end
  gRelayBuffers[handle] = (gRelayBuffers[handle] or "") .. tostring(data or "")
  -- 64KB cap: nothing legitimate is bigger; a flood must not grow memory.
  if #gRelayBuffers[handle] > 64 * 1024 then
    gRelayBuffers[handle] = nil
    pcall(function()
      C4:ServerCloseClient(handle)
    end)
    return
  end
  local req = uirelay.parse(gRelayBuffers[handle])
  if req == nil then
    return -- more chunks coming
  end
  gRelayBuffers[handle] = nil
  local result = uirelay.route(req, relayToken(), relayProvider)
  pcall(function()
    C4:ServerSend(handle, uirelay.render(result))
  end)
  pcall(function()
    C4:ServerCloseClient(handle)
  end)
end

local function startUiRelay()
  if gRelayPort ~= nil then
    return
  end
  local ok = pcall(function()
    C4:CreateServer(UI_RELAY_PORT, "", false, UI_RELAY_ID)
  end)
  if ok then
    gRelayPort = UI_RELAY_PORT
    log:info("UI relay listening on port %d", UI_RELAY_PORT)
  else
    log:warn("UI relay could not listen on port %d - app falls back to JS API only", UI_RELAY_PORT)
  end
end

local function stopUiRelay()
  if gRelayPort ~= nil then
    pcall(function()
      C4:DestroyServer(gRelayPort)
    end)
    gRelayPort = nil
  end
  gRelayBuffers = {}
end

--- Percent-encodes a URL for safe transport inside a query value.
local function encodeParam(s)
  return tostring(s):gsub("[^%w%-%._~]", function(ch)
    return string.format("%%%02X", ch:byte())
  end)
end

--- The app URL, carrying every data-plane pointer the page can use:
--- ?relay= (LAN endpoint), &cloud= + &cid= (off-LAN mirror), &k= (token,
--- shared by both). The page reads location.search; with no params it
--- stays on the JS API channels alone.
local function desiredWebViewUrl()
  local base = "controller://driver/smartbuildos-atmosphere/app/index.html"
  local parts = {}
  if gRelayPort ~= nil then
    local host = relayHost()
    if host ~= "" then
      parts[#parts + 1] = "relay=" .. encodeParam(string.format("http://%s:%d", host, gRelayPort))
    end
  end
  if gCloudView ~= nil and gCloudView.url ~= nil and gCloudView.url ~= "" then
    parts[#parts + 1] = "cloud=" .. encodeParam(gCloudView.url)
    parts[#parts + 1] = "cid=" .. encodeParam(gCloudView.handle or "")
  end
  if #parts == 0 then
    return base
  end
  parts[#parts + 1] = "k=" .. relayToken()
  return base .. "?" .. table.concat(parts, "&")
end

--- Asks the Agent to mirror our UI state to the SmartBuildOS cloud so the
--- app works off-LAN. Throttled to 60s; a transition (events fired) goes
--- immediately so the remote app never shows a stale warning picture.
--- Global on purpose: called from runEngine, which is defined earlier in
--- the file than this section's locals.
function askCloudMirror(urgent)
  if gRelayPort == nil then
    return
  end
  if not urgent and (nowUtc() - gCloudLastAsk) < 60 then
    return
  end
  local agentId = findAgentId()
  if agentId == nil then
    return
  end
  gCloudLastAsk = nowUtc()
  pcall(function()
    C4:SendToDevice(agentId, "SBOS_ATMOSPHERE_STATE", {
      port = tostring(gRelayPort),
      app_token = relayToken(),
      requester = tostring(C4:GetDeviceID()),
      urgent = urgent and "true" or "false",
    })
  end)
end

--- Paints the App Data Relay status property so a dealer can see the data
--- plane's health without the Lua window.
local function paintRelayStatus()
  local line
  if gRelayPort == nil then
    line = string.format("Not listening - port %d unavailable", UI_RELAY_PORT)
  else
    local host = relayHost()
    if host == "" then
      line = string.format("Listening :%d - controller address UNKNOWN, set App Relay Address", gRelayPort)
    else
      line = string.format("Listening :%d - serving http://%s:%d to the app", gRelayPort, host, gRelayPort)
    end
  end
  UpdateProperty("App Data Relay", line)
end

local function publishWebViewUrl(reason)
  local url = desiredWebViewUrl()
  C4:SendToProxy(WEBVIEW_BINDING, "URL_CHANGED", { url = url })
  gPublishedUrl = url
  paintRelayStatus()
  log:debug("WebView URL published (%s): %s", tostring(reason), url:gsub("k=[%w]+", "k=[token]"))
end

--- The Agent's answer to askCloudMirror: where the mirrored state can be
--- read. A change republishes the app URL so the page learns its cloud
--- pointer. (Defined AFTER publishWebViewUrl on purpose — an EC body that
--- referenced it earlier would compile as a nil global lookup.)
function EC.SBOS_ATMOSPHERE_STATE_ACK(tParams)
  tParams = tParams or {}
  local url = tostring(tParams.view_url or "")
  if url == "" or url:find("^https://") == nil then
    return
  end
  local handle = tostring(tParams.view_handle or "")
  local changed = gCloudView == nil or gCloudView.url ~= url or gCloudView.handle ~= handle
  gCloudView = { url = url, handle = handle }
  persist:set(P_CLOUD_VIEW, gCloudView)
  if changed then
    log:info("Cloud state mirror ready (handle %s)", handle)
    publishWebViewUrl("cloud-ready")
  end
end

-- ─── Actions ──────────────────────────────────────────────────────────────────

function EC.REFRESH_WEATHER()
  fetchObservations()
end

function EC.REFRESH_FORECAST()
  fetchForecast()
end

function EC.REFRESH_ALERTS()
  fetchAlerts()
end

function EC.REFRESH_ALL()
  fetchObservations()
  fetchForecast()
  fetchAlerts()
end

function EC.REDISCOVER_LOCATION()
  gLocation = resolveLocation()
  persist:set(P_LOCATION, gLocation)
  discoverPoints("manual")
end

function EC.TEST_WEATHER_API()
  if gLocation == nil then
    log:print("Weather API test: NO LOCATION configured")
    return
  end
  nws.points(gLocation.lat, gLocation.lon, function(props, err)
    if props ~= nil then
      log:print("Weather API test: OK (office %s)", tostring(props.gridId or props.cwa))
    else
      log:print("Weather API test: FAILED - %s (HTTP %s)", tostring(err.error), tostring(err.code))
    end
  end)
end

function EC.TEST_ALERTS_API()
  local opts = gPoints ~= nil and { zone = gPoints.forecastZone }
    or (gLocation ~= nil and { lat = gLocation.lat, lon = gLocation.lon } or {})
  nws.activeAlerts(opts, function(list, err)
    if list ~= nil then
      log:print("Alerts API test: OK (%d alerts for this location)", #list)
    else
      log:print("Alerts API test: FAILED - %s (HTTP %s)", tostring(err.error), tostring(err.code))
    end
  end)
end

function EC.TEST_LICENSING()
  license.register()
  license.check()
  log:print("Licensing: %s", license.describe())
end

function EC.REFRESH_LICENSE()
  license.register()
  license.check()
end

function EC.SBOS_ENTITLEMENT(tParams)
  license.onEntitlement(tParams)
  if gSnapshot ~= nil then
    setVariable("LICENSE_STATUS", license.status())
  end
end

--- SmartBuildOS remote settings: the Agent forwards a validated-by-schema
--- settings patch. Same validator as every other path; refusals are logged
--- AND returned so the Agent can report the ack upstream.
function EC.SBOS_ATMOSPHERE_CONFIG(tParams)
  local raw = tParams ~= nil and tParams.settings or nil
  if raw == nil then
    return
  end
  local ok, patch = pcall(function()
    return JSON:decode(tostring(raw))
  end)
  if not ok or type(patch) ~= "table" then
    log:warn("Remote settings: undecodable payload refused")
    return
  end
  local refused = applySettingsPatch(patch, "smartbuildos")
  local requester = tonumber(tParams.requester)
  if requester ~= nil then
    pcall(function()
      C4:SendToDevice(requester, "SBOS_ATMOSPHERE_CONFIG_ACK", {
        applied = tostring(#refused == 0),
        refused = tostring(#refused),
        settings_version = tostring(settingsstore.VERSION),
      })
    end)
  end
end

function EC.CLEAR_CACHE()
  persist:delete(P_POINTS)
  persist:delete(P_STATION)
  persist:delete(P_SNAPSHOT)
  persist:delete(P_DAILY)
  persist:delete(P_HOURLY)
  persist:delete(P_ALERTS)
  gPoints = nil
  gStation = nil
  gStations = {}
  gObs = nil
  gDaily = {}
  gHourly = {}
  gAlertSet = {}
  gSnapshot = nil
  gFetched = { obs = nil, forecast = nil, alerts = nil, points = nil }
  log:print("Cached weather cleared")
  discoverPoints("cache-cleared")
end

function EC.REINITIALIZE()
  KillAllTimers()
  gLocation = resolveLocation()
  persist:set(P_LOCATION, gLocation)
  discoverPoints("reinitialize")
  scheduleFetch("observations")
  scheduleFetch("forecast")
  scheduleFetch("alerts")
  SetTimer(ENGINE_TIMER, ONE_MINUTE, function()
    runEngine("tick")
  end, true)
end

function EC.STOP_SIMULATION()
  stopSimulation("action")
end

--- "Open <screen>" actions: a driver cannot force Navigator to open a page,
--- so these set the app's default screen (persisted) and push a navigate
--- hint an ALREADY-OPEN app follows on its next state update. Honest
--- semantics, documented in docs/atmosphere/WEBVIEW.md.
local function openScreen(screen)
  gSettings = settingsstore.merge(gSettings, { display = { default_screen = screen } })
  saveSettings()
  gNavigateHint = { screen = screen, at = nowUtc() }
  publishWebViewUrl("open-" .. screen)
  pushUiState()
  log:info("Weather app screen set to %s", screen)
end

function EC.OPEN_WEATHER_APP()
  openScreen(gSettings.display.default_screen or "now")
end
function EC.OPEN_CURRENT_WEATHER()
  openScreen("now")
end
function EC.OPEN_FORECAST()
  openScreen("forecast")
end
function EC.OPEN_RADAR()
  openScreen("radar")
end
function EC.OPEN_ALERTS()
  openScreen("alerts")
end
function EC.OPEN_SETTINGS()
  openScreen("settings")
end
function EC.OPEN_DIAGNOSTICS()
  openScreen("settings")
end

EC["Start Simulation"] = function(tParams)
  startSimulation(tParams ~= nil and tParams.SCENARIO or nil)
end

function EC.PRINT_DIAGNOSTICS()
  log:print("== SmartBuildOS Atmosphere diagnostics ==")
  log:print(
    "  app relay: %s | published URL: %s",
    gRelayPort ~= nil and string.format("listening :%d host '%s'", gRelayPort, relayHost()) or "NOT LISTENING",
    tostring(gPublishedUrl):gsub("k=[%w]+", "k=[token]")
  )
  log:print(
    "  location: %s",
    gLocation ~= nil
        and string.format("%s (%.4f, %.4f) via %s", gLocation.label, gLocation.lat, gLocation.lon, gLocation.source)
      or "UNRESOLVED"
  )
  log:print(
    "  office/grid: %s",
    gPoints ~= nil
        and string.format(
          "%s %d,%d zone %s",
          gPoints.office,
          gPoints.gridX,
          gPoints.gridY,
          tostring(gPoints.forecastZone)
        )
      or "-"
  )
  log:print("  station: %s (%d candidates)", tostring(gStation), #gStations)
  log:print(
    "  radar: %s | tz: %s",
    gPoints ~= nil and tostring(gPoints.radarStation) or "-",
    gPoints ~= nil and tostring(gPoints.timeZone) or "-"
  )
  local function ageLine(class)
    local okAt = gDiag.lastSuccess[class]
    local failAt = gDiag.lastFailure[class]
    return string.format(
      "  %s: ok %s | fail %s (%s, HTTP %s) | consecutive failures %d",
      class,
      okAt ~= nil and os.date("%H:%M:%S", okAt) or "never",
      failAt ~= nil and os.date("%H:%M:%S", failAt) or "never",
      tostring(gDiag.lastError[class]),
      tostring(gDiag.lastHttpCode[class]),
      gFailures[class] or 0
    )
  end
  log:print(ageLine("observations"))
  log:print(ageLine("forecast"))
  log:print(ageLine("alerts"))
  log:print(
    "  mode: %s | severity: %s | alerts: %d | stale: %s",
    gSnapshot ~= nil and gSnapshot.mode or "-",
    gSnapshot ~= nil and gSnapshot.severity or "-",
    gSnapshot ~= nil and (gSnapshot.activeAlertCount or 0) or 0,
    tostring(gSnapshot ~= nil and gSnapshot.dataStale)
  )
  log:print("  simulation: %s", gSim ~= nil and gSim.scenario or "off")
  log:print("  license: %s", license.describe())
  log:print("  settings version: %d", settingsstore.VERSION)
end

-- ─── Properties ───────────────────────────────────────────────────────────────

function OPC.Location_Source()
  if not gInitialized then
    return
  end
  EC.REDISCOVER_LOCATION()
end

function OPC.Latitude()
  if gInitialized and tostring(Properties["Location Source"]) == "Manual Coordinates" then
    EC.REDISCOVER_LOCATION()
  end
end

function OPC.Longitude()
  if gInitialized and tostring(Properties["Location Source"]) == "Manual Coordinates" then
    EC.REDISCOVER_LOCATION()
  end
end

function OPC.App_Relay_Address()
  if gInitialized then
    publishWebViewUrl("relay-address-changed")
  end
end

function OPC.Log_Mode(propertyValue)
  log:setLogMode(propertyValue)
end

function OPC.Log_Level(propertyValue)
  log:setLogLevel(propertyValue)
end

-- ─── System events: Director location changes re-resolve everything ──────────

for _, sysEvent in ipairs({ 52, 53, 54 }) do -- Zipcode/Latitude/Longitude changed
  OSE[sysEvent] = function()
    if gInitialized and tostring(Properties["Location Source"]) == "Control4 Project" then
      log:info("Project location changed - re-resolving")
      EC.REDISCOVER_LOCATION()
    end
  end
end

-- ─── Lifecycle ────────────────────────────────────────────────────────────────

function OnDriverInit()
  --#ifdef DRIVERCENTRAL
  require("cloud-client-byte")
  C4:AllowExecute(false)
  --#else
  C4:AllowExecute(true)
  --#endif
  gInitialized = false
  log:setLogName(C4:GetDeviceData(C4:GetDeviceID(), "name"))
  log:setLogLevel(Properties["Log Level"])
  log:setLogMode(Properties["Log Mode"])
  -- Variables are added in OnDriverInit (official guidance: programming
  -- attached to later-added variables may not survive a Director restart).
  for _, v in ipairs(VARIABLES) do
    pcall(function()
      C4:AddVariable(v[1], v[2], v[3], true)
    end)
  end
end

function OnDriverLateInit()
  if not CheckMinimumVersion("Driver Status") then
    return
  end
  for _, e in ipairs(engine.EVENTS) do
    pcall(function()
      C4:AddEvent(e[1], e[2], e[3])
    end)
  end

  loadSettings()

  -- Restore last-good weather so a restart is not amnesia.
  gPoints = persist:get(P_POINTS)
  if type(gPoints) ~= "table" or gPoints.office == nil then
    gPoints = nil
  end
  local storedStation = persist:get(P_STATION)
  gStation = type(storedStation) == "string" and storedStation or nil
  -- persist:get with no default returns a shared EMPTY SENTINEL table, not
  -- nil (measured; see control4-driver-development notes) — never adopt a
  -- read table directly, copy element-wise into a fresh one.
  local function freshList(key)
    local stored = persist:get(key)
    local out = {}
    if type(stored) == "table" then
      for _, v in ipairs(stored) do
        out[#out + 1] = v
      end
    end
    return out
  end
  gDaily = freshList(P_DAILY)
  gHourly = freshList(P_HOURLY)
  gAlertSet = {}
  local storedAlerts = persist:get(P_ALERTS)
  if type(storedAlerts) == "table" then
    for id, a in pairs(storedAlerts) do
      if type(a) == "table" and a.id ~= nil then
        gAlertSet[id] = a
      end
    end
  end
  local storedSnapshot = persist:get(P_SNAPSHOT)
  if type(storedSnapshot) == "table" and storedSnapshot.states ~= nil then
    gSnapshot = storedSnapshot
    gSnapshot.active = gAlertSet
  end
  local storedLocation = persist:get(P_LOCATION)
  gLocation = type(storedLocation) == "table" and storedLocation.lat ~= nil and storedLocation or nil
  local storedCloud = persist:get(P_CLOUD_VIEW)
  if
    type(storedCloud) == "table"
    and type(storedCloud.url) == "string"
    and storedCloud.url:find("^https://") ~= nil
  then
    gCloudView = { url = storedCloud.url, handle = tostring(storedCloud.handle or "") }
  end

  for p, _ in pairs(Properties) do
    pcall(OnPropertyChanged, p)
  end

  license.setup({ sku = "SBOS_ATMOSPHERE" })
  license.register()
  license.check()

  gInitialized = true
  UpdateProperty("Driver Status", "Online")
  pcall(function()
    local version = tostring(C4:GetDriverConfigInfo("version"))
    UpdateProperty("Driver Version", version)
    -- Identify the exact build to NWS (their policy asks for a UA unique
    -- to the application; the version makes fleet issues traceable).
    nws.setUserAgent(string.format("SmartBuildOS Atmosphere/%s (smartbuildos.io, support@smartbuildos.io)", version))
  end)

  -- Location: prefer a fresh resolution; fall back to the stored one.
  local resolved = resolveLocation()
  if resolved ~= nil then
    gLocation = resolved
    persist:set(P_LOCATION, gLocation)
  end
  discoverPoints("startup")

  -- Poll timers (jittered so a fleet never aligns).
  local seed = tostring(C4:GetDeviceID())
  SetTimer(OBS_TIMER, (5 + scheduler.jitter(seed, 30)) * ONE_SECOND, fetchObservations, false)
  SetTimer(FORECAST_TIMER, (10 + scheduler.jitter(seed .. "f", 60)) * ONE_SECOND, fetchForecast, false)
  SetTimer(ALERTS_TIMER, (15 + scheduler.jitter(seed .. "a", 30)) * ONE_SECOND, fetchAlerts, false)
  SetTimer(ENGINE_TIMER, ONE_MINUTE, function()
    runEngine("tick")
    -- Heal the app URL: the relay host can become discoverable after
    -- startup (bindings settle late on big projects), and the page only
    -- learns the relay address through the URL.
    if gPublishedUrl ~= desiredWebViewUrl() then
      publishWebViewUrl("heal")
    end
  end, true)

  -- The LAN state relay must exist before the URL that advertises it.
  startUiRelay()

  -- WebView URL: publish now and re-publish after project start (a notify
  -- sent before the project finishes starting is silently lost — measured).
  publishWebViewUrl("late-init")
  SetTimer("atmos-webview-startup", STARTUP_NOTIFY_MS, function()
    publishWebViewUrl("startup")
  end, false)

  runEngine("startup")
end

function OnDriverDestroyed()
  stopUiRelay()
  KillAllTimers()
end
