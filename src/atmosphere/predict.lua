--[[==========================================================================
  Atmosphere — predictive weather intelligence

  Lookahead flags computed from the hourly forecast + active alerts. The
  honesty rule (spec + data reality): NWS hourly data is 1-hour resolution —
  nothing here claims sub-hour precision, and there is deliberately NO
  "rain expected within 30 minutes" (the data cannot support it; the gap is
  documented, not faked).

  Pure module: (hourly periods, active alerts, thresholds, now) -> flags.
============================================================================]]

local M = {}

--- Scans hourly periods within `hours` of `now` for a predicate hit.
--- Returns the first matching period, or nil.
local function firstWithin(hourly, now, hours, pred)
  local horizon = now + hours * 3600
  for _, p in ipairs(hourly or {}) do
    if p.endT > now and p.startT < horizon then
      if pred(p) then
        return p
      end
    end
  end
  return nil
end

--- Tonight = from now until the next 08:00 local. localOffset seconds east
--- of UTC. A freeze check at 9pm should cover the pre-dawn low, not stop at
--- midnight.
local function endOfTonight(now, localOffset)
  localOffset = localOffset or 0
  local localNow = now + localOffset
  local dayStart = math.floor(localNow / 86400) * 86400
  local eightAm = dayStart + 8 * 3600
  if localNow >= eightAm then
    eightAm = eightAm + 86400
  end
  return eightAm - localOffset
end

--- Evaluates predictions.
--- hourly: normalized hourly periods (may be empty/stale — flags then stay
--- false EXCEPT alert-driven ones; prediction from stale data is fabrication)
--- active: active admitted alert set { [id] = alert }
--- t: effective thresholds
--- now: epoch; localOffset: seconds east of UTC
function M.evaluate(hourly, active, t, now, localOffset)
  local flags = {
    rain_expected_1h = false,
    rain_expected_3h = false,
    rain_expected_6h = false,
    rain_soon = false,
    heavy_rain_expected = false,
    storm_expected = false,
    snow_expected = false,
    high_wind_expected = false,
    freeze_expected_tonight = false,
    extreme_heat_expected = false,
    dangerous_weather_approaching = false,
    severe_alert_active = false,
  }

  local function rainy(p)
    return (p.pop ~= nil and p.pop >= t.rain_probability_pct) or p.flags.rain
  end

  flags.rain_expected_1h = firstWithin(hourly, now, 1, rainy) ~= nil
  flags.rain_expected_3h = firstWithin(hourly, now, 3, rainy) ~= nil
  flags.rain_expected_6h = firstWithin(hourly, now, 6, rainy) ~= nil
  flags.rain_soon = firstWithin(hourly, now, t.rain_soon_hours, rainy) ~= nil
  flags.heavy_rain_expected = firstWithin(hourly, now, t.rain_soon_hours, function(p)
    return p.pop ~= nil and p.pop >= t.heavy_rain_pop_pct
  end) ~= nil
  flags.storm_expected = firstWithin(hourly, now, t.storm_soon_hours, function(p)
    return p.flags.thunder
  end) ~= nil
  flags.snow_expected = firstWithin(hourly, now, t.storm_soon_hours, function(p)
    return p.flags.snow
  end) ~= nil
  flags.high_wind_expected = firstWithin(hourly, now, t.wind_lookahead_hours, function(p)
    return p.windMphHi ~= nil and p.windMphHi >= t.high_wind_enter_mph
  end) ~= nil
  flags.extreme_heat_expected = firstWithin(hourly, now, 24, function(p)
    return p.tempF ~= nil and p.tempF >= t.extreme_heat_enter_f
  end) ~= nil

  local tonightEnd = endOfTonight(now, localOffset)
  local tonightHours = math.max(1, math.ceil((tonightEnd - now) / 3600))
  local freezeHours = math.min(tonightHours, t.freeze_lookahead_hours)
  flags.freeze_expected_tonight = firstWithin(hourly, now, freezeHours, function(p)
    return p.tempF ~= nil and p.tempF <= t.freeze_enter_f
  end) ~= nil

  -- Alert-driven intelligence (works even when forecast data is stale).
  for _, a in pairs(active or {}) do
    if (a.severityRank or 0) >= 3 then
      flags.severe_alert_active = true
    end
    if a.levelName == "WARNING" and (a.severityRank or 0) >= 3 then
      flags.dangerous_weather_approaching = true
    end
    local class = a.class
    if class == "FREEZE" and a.levelName ~= "STATEMENT" then
      flags.freeze_expected_tonight = true
    end
    if class == "EXTREME_HEAT" and a.levelName ~= "STATEMENT" then
      flags.extreme_heat_expected = true
    end
    if (class == "HIGH_WIND" or class == "HURRICANE" or class == "TROPICAL_STORM") and a.levelName ~= "STATEMENT" then
      flags.high_wind_expected = true
    end
    if class == "SEVERE_THUNDERSTORM" then
      flags.storm_expected = true
    end
    if class == "WINTER" then
      flags.snow_expected = true
    end
  end
  if flags.storm_expected and firstWithin(hourly, now, 2, function(p)
    return p.flags.thunder
  end) ~= nil then
    flags.dangerous_weather_approaching = true
  end

  return flags
end

return M
