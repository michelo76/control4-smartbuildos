--[[==========================================================================
  Atmosphere — threshold engine with hysteresis

  Installer thresholds -> boolean weather states, with enter/exit bands so a
  reading hovering at a threshold never bounces automation (spec). Enter and
  exit are asymmetric: a state asserts at >= enter and clears only at
  <= exit (or the mirror for low-side states like freeze).

  Pure module. State lives in the table the caller passes back in; a nil
  reading NEVER changes a state (missing data is not evidence of anything).
============================================================================]]

local M = {}

--- Default thresholds. All temperatures Fahrenheit, speeds mph, visibility
--- miles, probabilities percent, lookaheads hours. Exit bands default to a
--- sane gap below/above enter; settings may override each individually.
M.DEFAULTS = {
  freeze_enter_f = 32,
  freeze_exit_f = 34,
  cold_enter_f = 40,
  cold_exit_f = 43,
  hot_enter_f = 90,
  hot_exit_f = 87,
  extreme_heat_enter_f = 100,
  extreme_heat_exit_f = 96,
  high_wind_enter_mph = 25,
  high_wind_exit_mph = 22,
  dangerous_wind_enter_mph = 40,
  dangerous_wind_exit_mph = 35,
  high_gust_enter_mph = 35,
  high_gust_exit_mph = 30,
  rain_probability_pct = 50,
  heavy_rain_pop_pct = 70,
  poor_visibility_enter_mi = 1,
  poor_visibility_exit_mi = 1.5,
  rain_soon_hours = 3,
  storm_soon_hours = 6,
  freeze_lookahead_hours = 12,
  wind_lookahead_hours = 6,
  stale_observation_minutes = 30,
  stale_forecast_minutes = 180,
  stale_alerts_minutes = 5,
}

--- Bounds for settings validation: { min, max } per key. Anything outside is
--- refused (remote settings must not brick a site with a typo'd 3200).
M.BOUNDS = {
  freeze_enter_f = { -40, 60 },
  freeze_exit_f = { -40, 70 },
  cold_enter_f = { -40, 70 },
  cold_exit_f = { -40, 80 },
  hot_enter_f = { 50, 130 },
  hot_exit_f = { 50, 130 },
  extreme_heat_enter_f = { 60, 140 },
  extreme_heat_exit_f = { 60, 140 },
  high_wind_enter_mph = { 5, 100 },
  high_wind_exit_mph = { 3, 100 },
  dangerous_wind_enter_mph = { 10, 150 },
  dangerous_wind_exit_mph = { 8, 150 },
  high_gust_enter_mph = { 5, 150 },
  high_gust_exit_mph = { 3, 150 },
  rain_probability_pct = { 5, 100 },
  heavy_rain_pop_pct = { 10, 100 },
  poor_visibility_enter_mi = { 0.1, 10 },
  poor_visibility_exit_mi = { 0.1, 12 },
  rain_soon_hours = { 1, 24 },
  storm_soon_hours = { 1, 24 },
  freeze_lookahead_hours = { 1, 48 },
  wind_lookahead_hours = { 1, 24 },
  stale_observation_minutes = { 10, 240 },
  stale_forecast_minutes = { 30, 1440 },
  stale_alerts_minutes = { 2, 60 },
}

--- Merges saved settings over defaults, dropping out-of-bounds or
--- non-numeric values (each refusal reported in the second return).
function M.effective(overrides)
  local out = {}
  local refused = {}
  for k, v in pairs(M.DEFAULTS) do
    out[k] = v
  end
  for k, v in pairs(overrides or {}) do
    local bounds = M.BOUNDS[k]
    local n = tonumber(v)
    if bounds == nil then
      refused[#refused + 1] = { key = k, reason = "unknown" }
    elseif n == nil or n < bounds[1] or n > bounds[2] then
      refused[#refused + 1] = { key = k, reason = "out_of_bounds", value = v }
    else
      out[k] = n
    end
  end
  return out, refused
end

--- One hysteresis evaluation. `current` is the prior boolean (nil = never
--- evaluated), `value` the reading (nil = keep current), enter/exit the band,
--- `low` true for states asserted when the value goes DOWN through enter
--- (freeze, visibility).
function M.hysteresis(current, value, enter, exit, low)
  if value == nil then
    return current == true
  end
  local active = current == true
  if low then
    if not active and value <= enter then
      return true
    end
    if active and value >= exit then
      return false
    end
  else
    if not active and value >= enter then
      return true
    end
    if active and value <= exit then
      return false
    end
  end
  return active
end

--- Evaluates every threshold state from an observation. `states` is the
--- prior state table (mutated copy returned); `t` the effective thresholds.
--- Uses feels-like for heat, air temp for freeze (surface frost forms at air
--- temperature; a heat-index freeze would be nonsense).
function M.evaluate(states, obs, t)
  local out = {}
  for k, v in pairs(states or {}) do
    out[k] = v
  end
  if obs == nil then
    return out
  end
  out.is_freezing = M.hysteresis(out.is_freezing, obs.tempF, t.freeze_enter_f, t.freeze_exit_f, true)
  out.is_cold = M.hysteresis(out.is_cold, obs.tempF, t.cold_enter_f, t.cold_exit_f, true)
  out.is_hot = M.hysteresis(out.is_hot, obs.feelsLikeF or obs.tempF, t.hot_enter_f, t.hot_exit_f, false)
  out.is_extreme_heat =
    M.hysteresis(out.is_extreme_heat, obs.feelsLikeF or obs.tempF, t.extreme_heat_enter_f, t.extreme_heat_exit_f, false)
  out.is_high_wind = M.hysteresis(out.is_high_wind, obs.windMph, t.high_wind_enter_mph, t.high_wind_exit_mph, false)
  out.is_dangerous_wind =
    M.hysteresis(out.is_dangerous_wind, obs.windMph, t.dangerous_wind_enter_mph, t.dangerous_wind_exit_mph, false)
  out.is_high_gust = M.hysteresis(out.is_high_gust, obs.gustMph, t.high_gust_enter_mph, t.high_gust_exit_mph, false)
  out.is_poor_visibility =
    M.hysteresis(out.is_poor_visibility, obs.visibilityMi, t.poor_visibility_enter_mi, t.poor_visibility_exit_mi, true)
  -- Precipitation booleans come straight from observed flags (no hysteresis:
  -- the flags are already discrete), but only when an observation is present.
  out.is_raining = obs.flags.rain == true
  out.is_snowing = obs.flags.snow == true
  out.is_storming = obs.flags.thunder == true
  out.is_foggy = obs.flags.fog == true
  out.is_icy = obs.flags.ice == true
  return out
end

return M
