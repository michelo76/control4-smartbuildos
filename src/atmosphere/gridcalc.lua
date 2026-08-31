--[[==========================================================================
  Atmosphere — gridpoint layer math

  NWS forecastGridData layers arrive as { start, duration, value } samples
  (normalize.gridLayer output). Accumulation layers (snowfallAmount,
  quantitativePrecipitation) state a TOTAL for their interval, so a window
  that covers half an interval earns half its value — sums here are
  duration-weighted by interval overlap. Instant/point samples (duration 0)
  count fully when their instant falls inside the window.

  Nil discipline: a window that no sample touches returns nil, never 0 —
  "no data" and "no precipitation" are different facts. Pure module.

  Unit note: NWS serves both accumulation layers in wmoUnit:mm (measured
  live 2026-08-31); the *In helpers convert mm -> inches.
============================================================================]]

local units = require("atmosphere.units")

local M = {}

local function validSample(s)
  return type(s) == "table" and tonumber(s.start) ~= nil and tonumber(s.duration) ~= nil and tonumber(s.value) ~= nil
end

--- Duration-weighted sum of an accumulation layer over [fromEpoch, toEpoch).
--- Partial interval overlap contributes proportionally. Returns nil when no
--- sample overlaps the window (missing data must never read as zero).
function M.sumOver(samples, fromEpoch, toEpoch)
  fromEpoch = tonumber(fromEpoch)
  toEpoch = tonumber(toEpoch)
  if fromEpoch == nil or toEpoch == nil or toEpoch <= fromEpoch then
    return nil
  end
  local total = 0
  local any = false
  for _, s in ipairs(samples or {}) do
    if validSample(s) then
      if s.duration > 0 then
        local lo = math.max(s.start, fromEpoch)
        local hi = math.min(s.start + s.duration, toEpoch)
        if hi > lo then
          total = total + s.value * (hi - lo) / s.duration
          any = true
        end
      elseif s.start >= fromEpoch and s.start < toEpoch then
        total = total + s.value
        any = true
      end
    end
  end
  if not any then
    return nil
  end
  return total
end

--- Maximum sample value over [fromEpoch, toEpoch). A sample counts when any
--- part of its interval overlaps the window. Returns nil when none do.
function M.maxOver(samples, fromEpoch, toEpoch)
  fromEpoch = tonumber(fromEpoch)
  toEpoch = tonumber(toEpoch)
  if fromEpoch == nil or toEpoch == nil or toEpoch <= fromEpoch then
    return nil
  end
  local worst = nil
  for _, s in ipairs(samples or {}) do
    if validSample(s) then
      local overlaps
      if s.duration > 0 then
        overlaps = s.start < toEpoch and (s.start + s.duration) > fromEpoch
      else
        overlaps = s.start >= fromEpoch and s.start < toEpoch
      end
      if overlaps and (worst == nil or s.value > worst) then
        worst = s.value
      end
    end
  end
  return worst
end

--- Total snowfall (inches) over the next 24 hours from a snowfallAmount
--- layer in mm. nil when the layer carries no data for the window.
function M.snowfallNext24In(samples, now)
  now = tonumber(now)
  if now == nil then
    return nil
  end
  return units.mmToInches(M.sumOver(samples, now, now + 24 * 3600))
end

--- Total quantitative precipitation (inches) over the next 24 hours from a
--- quantitativePrecipitation layer in mm. nil when no data covers the window.
function M.rainNext24In(samples, now)
  now = tonumber(now)
  if now == nil then
    return nil
  end
  return units.mmToInches(M.sumOver(samples, now, now + 24 * 3600))
end

--- Peak probabilityOfThunder (percent) over the next 12 hours. nil when no
--- data covers the window.
function M.peakThunderPct12h(samples, now)
  now = tonumber(now)
  if now == nil then
    return nil
  end
  return M.maxOver(samples, now, now + 12 * 3600)
end

return M
