--[[==========================================================================
  Atmosphere — automation recommendations

  Two curated booleans for programming, computed from facts the driver
  already holds. Thresholds live in DEFAULTS so a later settings round can
  make them installer-tunable without touching the logic (they are NOT wired
  to settingsstore yet — overrides arrive via the second argument).

  Nil discipline: a nil input simply cannot trigger its clause — missing
  data never argues for OR against a recommendation. Pure module.
============================================================================]]

local M = {}

M.DEFAULTS = {
  irrigation_rain_next24_in = 0.25, -- expected rain that makes watering redundant
  irrigation_pop_max_pct = 60, -- peak PoP that makes watering a waste bet
  shade_wind_mph = 25, -- sustained wind that endangers extended shades
  shade_gust_mph = 30, -- gust that endangers extended shades
}

local function effective(overrides)
  local t = {}
  for k, v in pairs(M.DEFAULTS) do
    t[k] = v
  end
  for k, v in pairs(overrides or {}) do
    if M.DEFAULTS[k] ~= nil and tonumber(v) ~= nil then
      t[k] = tonumber(v)
    end
  end
  return t
end

--- Skip irrigation when meaningful rain is already falling, expected, or
--- likely. inputs = { rainNext24In, popMax24h, isRaining }.
function M.irrigationSkip(inputs, overrides)
  inputs = inputs or {}
  local t = effective(overrides)
  if inputs.isRaining == true then
    return true
  end
  local rain = tonumber(inputs.rainNext24In)
  if rain ~= nil and rain >= t.irrigation_rain_next24_in then
    return true
  end
  local pop = tonumber(inputs.popMax24h)
  if pop ~= nil and pop >= t.irrigation_pop_max_pct then
    return true
  end
  return false
end

--- Retract/protect exterior shades when wind endangers them.
--- inputs = { windMph, gustMph, highWindExpected }.
function M.shadeProtect(inputs, overrides)
  inputs = inputs or {}
  local t = effective(overrides)
  if inputs.highWindExpected == true then
    return true
  end
  local gust = tonumber(inputs.gustMph)
  if gust ~= nil and gust >= t.shade_gust_mph then
    return true
  end
  local wind = tonumber(inputs.windMph)
  if wind ~= nil and wind >= t.shade_wind_mph then
    return true
  end
  return false
end

return M
