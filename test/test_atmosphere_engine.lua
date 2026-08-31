-- Tests for the Atmosphere intelligence engine: thresholds (hysteresis),
-- predictions, mode/severity, alert lifecycle, and transition-only events.
--
-- Invariants under test:
--   * Hysteresis: no bounce inside the enter/exit band; nil readings never
--     change a state.
--   * First sight is baseline — a restart with rain falling fires nothing.
--   * The same alert polled twice produces zero events; Updates supersede
--     via references[]; a failed poll retains alerts (never "all clear").
--   * Stale forecast disables forecast-driven predictions (no fabrication)
--     while alert-driven intelligence keeps working.
--   * Simulation runs the identical event path, flagged.
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

local thresholds = require("atmosphere.thresholds")
local predict = require("atmosphere.predict")
local wstate = require("atmosphere.state")
local walerts = require("atmosphere.alerts")
local engine = require("atmosphere.engine")

local T = thresholds.effective({})
local NOW = 1767225600 -- 2026-01-01T00:00:00Z

local function has(events, name)
  for _, e in ipairs(events) do
    if e == name then
      return true
    end
  end
  return false
end

local function obsWith(over)
  local o = {
    timestamp = NOW,
    tempC = 20,
    tempF = 68,
    feelsLikeF = 68,
    windMph = 5,
    gustMph = nil,
    visibilityMi = 10,
    humidity = 50,
    cloudCover = 10,
    flags = { rain = false, snow = false, thunder = false, fog = false, ice = false, clear = true, cloudy = false },
  }
  for k, v in pairs(over or {}) do
    o[k] = v
  end
  return o
end

-- ─── thresholds: hysteresis ───────────────────────────────────────────────────

check("hysteresis asserts at enter", thresholds.hysteresis(false, 25, 25, 22, false) == true)
check("hysteresis holds in band", thresholds.hysteresis(true, 23, 25, 22, false) == true)
check("hysteresis clears at exit", thresholds.hysteresis(true, 22, 25, 22, false) == false)
check("hysteresis stays off below enter", thresholds.hysteresis(false, 24, 25, 22, false) == false)
check("hysteresis nil keeps state", thresholds.hysteresis(true, nil, 25, 22, false) == true)
check("hysteresis low-side asserts", thresholds.hysteresis(false, 32, 32, 34, true) == true)
check("hysteresis low-side holds in band", thresholds.hysteresis(true, 33, 32, 34, true) == true)
check("hysteresis low-side clears", thresholds.hysteresis(true, 34, 32, 34, true) == false)

local s1 = thresholds.evaluate({}, obsWith({ windMph = 26 }), T)
check("evaluate high wind asserts", s1.is_high_wind == true)
local s2 = thresholds.evaluate(s1, obsWith({ windMph = 23 }), T)
check("evaluate high wind holds at 23", s2.is_high_wind == true)
local s3 = thresholds.evaluate(s2, obsWith({ windMph = 21 }), T)
check("evaluate high wind clears at 21", s3.is_high_wind == false)
local nilWindObs = obsWith({})
nilWindObs.windMph = nil -- pairs() never sees nil overrides; set explicitly
local s4 = thresholds.evaluate(s1, nilWindObs, T)
check("evaluate nil wind keeps state", s4.is_high_wind == true)
check("evaluate freeze low-side", thresholds.evaluate({}, obsWith({ tempF = 30 }), T).is_freezing == true)
check(
  "evaluate heat uses feels-like",
  thresholds.evaluate({}, obsWith({ tempF = 85, feelsLikeF = 92 }), T).is_hot == true
)
check("evaluate nil obs is inert", thresholds.evaluate(s1, nil, T).is_high_wind == true)

-- Settings validation.
local eff, refused = thresholds.effective({ high_wind_enter_mph = 35, hot_enter_f = 999, bogus_key = 5 })
check("effective applies valid override", eff.high_wind_enter_mph == 35)
check("effective keeps default for refused", eff.hot_enter_f == thresholds.DEFAULTS.hot_enter_f)
check("effective refuses out-of-bounds + unknown", #refused == 2)

-- ─── alerts: lifecycle ────────────────────────────────────────────────────────

local function capAlert(over)
  local a = {
    id = "urn:oid:2.49.0.1.840.0.abc.001.1",
    event = "Severe Thunderstorm Warning",
    severity = "Severe",
    certainty = "Observed",
    urgency = "Immediate",
    status = "Actual",
    messageType = "Alert",
    effective = "2026-01-01T00:00:00+00:00",
    onset = "2026-01-01T00:00:00+00:00",
    expires = "2026-01-01T03:00:00+00:00",
    ends = "2026-01-01T03:00:00+00:00",
    senderName = "NWS Miami FL",
    areaDesc = "Broward County",
    description = "A severe thunderstorm was located...",
    instruction = "Move to an interior room...",
    response = "Shelter",
  }
  for k, v in pairs(over or {}) do
    a[k] = v
  end
  return normalize_alert(a)
end

function normalize_alert(raw)
  return walerts.normalize(raw)
end

check("classify tornado", walerts.classify("Tornado Warning") == "TORNADO")
check("classify svr", walerts.classify("Severe Thunderstorm Watch") == "SEVERE_THUNDERSTORM")
check("classify flash flood", walerts.classify("Flash Flood Warning") == "FLASH_FLOOD")
check("classify winter", walerts.classify("Winter Storm Warning") == "WINTER")
check("classify heat", walerts.classify("Extreme Heat Warning") == "EXTREME_HEAT")
check("classify unknown falls to OTHER", walerts.classify("911 Telephone Outage") == "OTHER")
check("level from name", walerts.level("Flood Watch", "Severe") == "WATCH")
check("level falls back to severity", walerts.level("Special Weather Statement", "Unknown") == "STATEMENT")

local a1 = capAlert({})
check("normalize alert parses", a1 ~= nil and a1.class == "SEVERE_THUNDERSTORM" and a1.levelName == "WARNING")
check("normalize alert times", a1 ~= nil and a1.ends == 1767225600 + 3 * 3600)

local r1 = walerts.reconcile({}, { a1 }, NOW)
check("reconcile new alert", #r1.new == 1 and r1.active[a1.id] ~= nil)
local r2 = walerts.reconcile(r1.active, { a1 }, NOW + 60)
check("reconcile same alert repolled: no events", #r2.new == 0 and #r2.updated == 0 and #r2.canceled == 0)

local a2 = capAlert({
  id = "urn:oid:2.49.0.1.840.0.def.002.1",
  event = "Tornado Warning",
  severity = "Extreme",
  messageType = "Update",
  references = { { ["@id"] = a1.id } },
})
local r3 = walerts.reconcile(r2.active, { a2 }, NOW + 120)
check("reconcile update supersedes", r3.active[a1.id] == nil and r3.active[a2.id] ~= nil)
check("reconcile update not counted new", #r3.new == 0 and #r3.updated == 1)
check("reconcile escalation detected", #r3.escalated == 1)
check("reconcile supersede is silent (no cancel)", #r3.canceled == 0)

local r4 = walerts.reconcile(r3.active, nil, NOW + 180)
check("reconcile failed poll retains alert", r4.active[a2.id] ~= nil and #r4.canceled == 0)

local r5 = walerts.reconcile(r3.active, {}, NOW + 240)
check("reconcile absent alert cancels", #r5.canceled == 1 and r5.active[a2.id] == nil)

local r6 = walerts.reconcile(r3.active, nil, NOW + 4 * 3600)
check("reconcile failed poll still expires by clock", #r6.expired == 1 and r6.active[a2.id] == nil)

check("admitted default", walerts.admitted(a1, {}) == true)
check(
  "admitted sensitivity excludes watch",
  walerts.admitted(capAlert({ event = "Flood Watch" }), { sensitivity = "WARNINGS_ONLY" }) == false
)
check("admitted class disable", walerts.admitted(a1, { classes = { SEVERE_THUNDERSTORM = false } }) == false)
check(
  "admitted unknown class defaults on",
  walerts.admitted(capAlert({ event = "Dust Storm Warning" }), { classes = {} }) == true
)
check("admitted rejects Test status", walerts.admitted(capAlert({ status = "Test" }), {}) == false)
check("admitted OFF admits nothing", walerts.admitted(a1, { sensitivity = "OFF" }) == false)

check("highestSeverity", walerts.highestSeverity(r3.active) == "Extreme")
check("mostImportant picks tornado", walerts.mostImportant(r3.active).id == a2.id)

-- ─── predictions ──────────────────────────────────────────────────────────────

local function hourlyAt(offsetH, over)
  local p = {
    startT = NOW + offsetH * 3600,
    endT = NOW + (offsetH + 1) * 3600,
    isDaytime = true,
    tempF = 60,
    pop = 10,
    windMphLo = 5,
    windMphHi = 8,
    flags = { rain = false, snow = false, thunder = false, fog = false, ice = false, clear = true, cloudy = false },
  }
  for k, v in pairs(over or {}) do
    p[k] = v
  end
  return p
end

local hourlyRain2h =
  { hourlyAt(0), hourlyAt(1), hourlyAt(2, { pop = 60, flags = { rain = true } }), hourlyAt(8, { pop = 80 }) }
local pr = predict.evaluate(hourlyRain2h, {}, T, NOW, 0)
check("predict rain in 3h window", pr.rain_expected_3h == true)
check("predict rain NOT in 1h window", pr.rain_expected_1h == false)
check("predict rain in 6h window", pr.rain_expected_6h == true)
check("predict rain_soon at default 3h", pr.rain_soon == true)
check("predict heavy rain outside lookahead", pr.heavy_rain_expected == false)

local prFreeze = predict.evaluate({ hourlyAt(3, { tempF = 28 }) }, {}, T, NOW, 0)
check("predict freeze tonight", prFreeze.freeze_expected_tonight == true)
local prWind = predict.evaluate({ hourlyAt(2, { windMphHi = 30 }) }, {}, T, NOW, 0)
check("predict high wind expected", prWind.high_wind_expected == true)

local tornadoActive = { [a2.id] = a2 }
local prAlert = predict.evaluate({}, tornadoActive, T, NOW, 0)
check("predict severe alert active", prAlert.severe_alert_active == true)
check("predict dangerous weather from warning", prAlert.dangerous_weather_approaching == true)
local freezeWatch = capAlert({ id = "x1", event = "Freeze Watch", severity = "Moderate" })
check(
  "predict freeze from alert with no forecast",
  predict.evaluate({}, { x1 = freezeWatch }, T, NOW, 0).freeze_expected_tonight == true
)

-- ─── mode + severity ──────────────────────────────────────────────────────────

check("mode clear", wstate.mode(obsWith({}), {}, {}) == "CLEAR")
check("mode cloudy from cover", wstate.mode(obsWith({ cloudCover = 80 }), {}, {}) == "CLOUDY")
check("mode partly cloudy", wstate.mode(obsWith({ cloudCover = 40 }), {}, {}) == "PARTLY_CLOUDY")
check("mode rain", wstate.mode(obsWith({ flags = { rain = true } }), {}, {}) == "RAIN")
check(
  "mode thunderstorm beats rain",
  wstate.mode(obsWith({ flags = { rain = true, thunder = true } }), {}, {}) == "THUNDERSTORM"
)
check(
  "mode ice from freezing rain",
  wstate.mode(obsWith({ flags = { rain = true } }), { is_freezing = true }, {}) == "ICE"
)
check("mode snow", wstate.mode(obsWith({ flags = { snow = true } }), {}, {}) == "SNOW")
check("mode high wind", wstate.mode(obsWith({}), { is_high_wind = true }, {}) == "HIGH_WIND")
check("mode unknown without obs", wstate.mode(nil, {}, {}) == "UNKNOWN")
check(
  "mode hurricane forced by warning",
  wstate.mode(obsWith({}), {}, { [1] = capAlert({ event = "Hurricane Warning", severity = "Extreme" }) }) == "HURRICANE"
)
check("mode severe storm on tornado warning", wstate.mode(obsWith({}), {}, { [1] = a2 }) == "SEVERE_STORM")

check("severity normal", wstate.severity({}, {}) == "NORMAL")
check("severity emergency on extreme warning", wstate.severity({}, tornadoActive) == "EMERGENCY")
check("severity warning on severe warning", wstate.severity({}, { [a1.id] = a1 }) == "WARNING")
check(
  "severity watch",
  wstate.severity({}, { w = capAlert({ event = "Flood Watch", severity = "Moderate" }) }) == "WATCH"
)
check("severity informational on local extreme", wstate.severity({ is_extreme_heat = true }, {}) == "INFORMATIONAL")

-- ─── engine: transition-only events ───────────────────────────────────────────

local function step(prev, over)
  local inputs = {
    obs = obsWith({}),
    hourly = {},
    alertsResult = nil,
    thresholds = T,
    now = NOW,
    localOffset = 0,
    obsFetchedAt = NOW,
    forecastFetchedAt = NOW,
    alertsFetchedAt = NOW,
    apiOk = true,
  }
  for k, v in pairs(over or {}) do
    inputs[k] = v
  end
  return engine.step(prev, inputs)
end

-- First sight is baseline: raining at first step fires nothing.
local snap1, ev1 = step(nil, { obs = obsWith({ flags = { rain = true } }) })
check("engine first step baselines rain silently", #ev1 == 0, table.concat(ev1, ","))
check("engine snapshot raining", snap1.states.is_raining == true)
check("engine mode rain", snap1.mode == "RAIN")

local snap2, ev2 = step(snap1, { obs = obsWith({ flags = { rain = false, clear = true } }) })
check("engine rain stopped fires", has(ev2, "Rain Stopped"))
local _, ev2b = step(snap2, { obs = obsWith({ flags = { rain = false, clear = true } }) })
check("engine no repeat on steady state", #ev2b == 0, table.concat(ev2b, ","))

-- Wind hysteresis through the engine.
local snapW1 = select(1, step(nil, { obs = obsWith({ windMph = 10 }) }))
local snapW2, evW2 = step(snapW1, { obs = obsWith({ windMph = 26 }) })
check("engine high wind started", has(evW2, "High Wind Started"))
local snapW3, evW3 = step(snapW2, { obs = obsWith({ windMph = 23 }) })
check("engine no bounce in band", not has(evW3, "High Wind Ended"))
local _, evW4 = step(snapW3, { obs = obsWith({ windMph = 20 }) })
check("engine high wind ended", has(evW4, "High Wind Ended"))

-- Predictions transition through the engine.
local snapP1 = select(1, step(nil, {}))
local _, evP2 = step(snapP1, { hourly = hourlyRain2h })
check(
  "engine rain-expected events fire on rise",
  has(evP2, "Rain Expected Within 3 Hours") and has(evP2, "Rain Expected Soon")
)

-- Stale forecast suppresses forecast predictions.
local snapS1, evS1 = step(snapP1, { hourly = hourlyRain2h, forecastFetchedAt = NOW - 10 * 3600 })
check("engine stale forecast: no rain prediction", snapS1.predictions.rain_expected_3h == false)
check("engine stale forecast: forecastStale set", snapS1.forecastStale == true)
check("engine partial staleness not global", snapS1.dataStale == false)
local _ = evS1

-- Alerts through the engine.
local ar = walerts.reconcile({}, { a2 }, NOW)
local snapA1, evA1 = step(snapP1, { alertsResult = ar })
check("engine tornado warning event", has(evA1, "Tornado Warning"))
check("engine generic warning event", has(evA1, "New Weather Warning"))
check("engine severe weather detected", has(evA1, "Severe Weather Detected"))
check("engine severity emergency", snapA1.severity == "EMERGENCY")
check("engine top alert exposed", snapA1.topAlert ~= nil and snapA1.topAlert.id == a2.id)
check("engine alert count", snapA1.activeAlertCount == 1)

local arClear = walerts.reconcile(snapA1.active, {}, NOW + 60)
local snapA2, evA2 = step(snapA1, { alertsResult = arClear, now = NOW + 60 })
check("engine alert cleared event", has(evA2, "Alert Cleared"))
check("engine severe weather ended", has(evA2, "Severe Weather Ended"))
check("engine severity back to normal", snapA2.severity == "NORMAL")

-- Data health transitions.
local snapD1, _ = step(nil, {})
local snapD2, evD2 = step(snapD1, { obsFetchedAt = NOW - 3600, now = NOW })
check("engine data stale fires", has(evD2, "Weather Data Stale"))
check("engine dataStale flag", snapD2.dataStale == true)
local _, evD3 = step(snapD2, { obsFetchedAt = NOW })
check("engine data restored fires", has(evD3, "Weather Data Restored"))
local snapD4, evD4 = step(snapD1, { apiOk = false })
check("engine api unavailable fires", has(evD4, "Weather API Unavailable"))
local _, evD5 = step(snapD4, { apiOk = true })
check("engine api recovered fires", has(evD5, "Weather API Recovered"))

-- Simulation transitions.
local snapSim, evSim = step(snapD1, { simulation = true, obs = obsWith({ flags = { thunder = true, rain = true } }) })
check("engine simulation started fires", has(evSim, "Simulation Started"))
check("engine simulated storm fires real event", has(evSim, "Thunderstorm Started"))
check("engine snapshot flagged simulation", snapSim.simulation == true)
local _, evSim2 = step(snapSim, {})
check("engine simulation ended fires", has(evSim2, "Simulation Ended"))

-- Event table sanity: unique ids, unique names.
local ids, names, dup = {}, {}, false
for _, e in ipairs(engine.EVENTS) do
  if ids[e[1]] or names[e[2]] then
    dup = true
  end
  ids[e[1]] = true
  names[e[2]] = true
end
check("engine event ids and names unique", not dup)
check(
  "engine event map names all registered",
  (function()
    for _, e in ipairs({ "Rain Started", "Tornado Warning", "Weather Data Stale", "Simulation Started" }) do
      if not names[e] then
        return false
      end
    end
    return true
  end)()
)

-- ─── result ───────────────────────────────────────────────────────────────────

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
