--[[==========================================================================
  Atmosphere — WebView payload builder (pure)

  Builds the JSON-able document the Navigator app renders. One shape, one
  place: the app NEVER sees raw NWS JSON, tokens, or anything the driver
  would not print in a log. All strings are data (the app renders text
  nodes, never HTML) — but the contract starts here: nothing in this
  document is markup.

  Units are converted server-side (driver-side) so the page stays dumb:
  the `units` block says what the numbers already are.
============================================================================]]

local units = require("atmosphere.units")

local M = {}

local function convTemp(f, unit)
  if f == nil then
    return nil
  end
  if unit == "C" then
    return units.round(units.fToC(f), 1)
  end
  return units.round(f, 1)
end

local function convWind(mph, unit)
  if mph == nil then
    return nil
  end
  if unit == "KMH" then
    return units.round(units.mphToKmh(mph), 1)
  elseif unit == "KNOTS" then
    return units.round(units.mphToKnots(mph), 1)
  end
  return units.round(mph, 1)
end

local function convPressure(inHg, unit)
  if inHg == nil then
    return nil
  end
  if unit == "HPA" then
    return units.round(inHg * 33.8639, 1)
  end
  return units.round(inHg, 2)
end

local function convDistance(mi, unit)
  if mi == nil then
    return nil
  end
  if unit == "KM" then
    return units.round(mi * 1.609344, 1)
  end
  return units.round(mi, 1)
end

--- Builds the full UI document.
--- ctx = { snapshot, daily, hourly, settings, location, solar, diagnostics,
---         license, now, history, trends }
--- history: driver-downsampled observation samples { t, tempF, pressureInHg }
--- trends: { pressure = "RISING"|"FALLING"|"STEADY" } (absent keys = no data)
function M.build(ctx)
  local snap = ctx.snapshot or {}
  local settings = ctx.settings
  local u = settings.units
  local obs = snap.obs

  local current = nil
  if obs ~= nil then
    current = {
      temp = convTemp(obs.tempF, u.temperature),
      feels_like = convTemp(obs.feelsLikeF, u.temperature),
      dewpoint = convTemp(obs.dewpointF, u.temperature),
      humidity = obs.humidity ~= nil and units.round(obs.humidity) or nil,
      wind = convWind(obs.windMph, u.wind),
      gust = convWind(obs.gustMph, u.wind),
      wind_dir = obs.windCompass,
      wind_deg = obs.windDeg,
      pressure = convPressure(obs.pressureInHg, u.pressure),
      visibility = convDistance(obs.visibilityMi, u.distance),
      cloud_cover = obs.cloudCover,
      condition = obs.textDescription,
      station = obs.station,
      observed_at = obs.timestamp,
    }
  end

  local function periodOut(p, includeDetail)
    return {
      start = p.startT,
      ["end"] = p.endT,
      name = p.name ~= "" and p.name or nil,
      is_day = p.isDaytime,
      temp = convTemp(p.tempF, u.temperature),
      pop = p.pop,
      wind_lo = convWind(p.windMphLo, u.wind),
      wind_hi = convWind(p.windMphHi, u.wind),
      wind_dir = p.windDir,
      short = p.shortForecast,
      detail = includeDetail and p.detailedForecast or nil,
      flags = p.flags,
    }
  end

  local hourly = {}
  for i, p in ipairs(ctx.hourly or {}) do
    if i > 48 then
      break
    end
    hourly[#hourly + 1] = periodOut(p, false)
  end
  local daily = {}
  for i, p in ipairs(ctx.daily or {}) do
    if i > 14 then
      break
    end
    daily[#daily + 1] = periodOut(p, true)
  end

  local alertsOut = {}
  for _, a in pairs(snap.active or {}) do
    alertsOut[#alertsOut + 1] = {
      id = a.id,
      event = a.event,
      headline = a.headline,
      severity = a.severity,
      urgency = a.urgency,
      certainty = a.certainty,
      level = a.levelName,
      class = a.class,
      onset = a.onset,
      ends = a.ends,
      expires = a.expires,
      area = a.areaDesc,
      description = a.description,
      instruction = a.instruction,
      sender = a.sender,
      rank = a.severityRank,
    }
  end
  -- Observation history for sparklines: unit-converted like everything
  -- else so the page stays dumb; nil readings stay nil.
  local historyOut = {}
  for _, h in ipairs(ctx.history or {}) do
    historyOut[#historyOut + 1] = {
      t = h.t,
      temp = convTemp(h.tempF, u.temperature),
      pressure = convPressure(h.pressureInHg, u.pressure),
    }
  end

  table.sort(alertsOut, function(x, y)
    if (x.rank or 0) ~= (y.rank or 0) then
      return (x.rank or 0) > (y.rank or 0)
    end
    return tostring(x.id) < tostring(y.id)
  end)

  return {
    v = 1,
    now = ctx.now,
    mode = snap.mode or "UNKNOWN",
    severity = snap.severity or "NORMAL",
    simulation = snap.simulation == true,
    stale = {
      any = snap.dataStale == true,
      observations = snap.obsStale == true,
      forecast = snap.forecastStale == true,
      alerts = snap.alertsStale == true,
      api_ok = snap.apiOk ~= false,
    },
    current = current,
    states = snap.states,
    predictions = snap.predictions,
    hourly = hourly,
    daily = daily,
    alerts = alertsOut,
    alert_count = snap.activeAlertCount or #alertsOut,
    history = historyOut,
    trends = ctx.trends,
    solar = ctx.solar,
    location = ctx.location,
    settings = settings,
    units = u,
    diagnostics = ctx.diagnostics,
    license = ctx.license,
    navigate = ctx.navigate,
  }
end

return M
