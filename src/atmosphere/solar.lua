--[[==========================================================================
  Atmosphere — sunrise/sunset (NOAA solar equations)

  DriverWorks exposes NO sunrise/sunset getter (verified against the full API
  docs 2026-08-31: C4:GetGeoSettings returns only country; Director's solar
  knowledge is reachable solely as Scheduler *entries*, not readable values).
  So Atmosphere computes it: the standard NOAA solar position algorithm from
  the site's latitude/longitude. Offline, deterministic, timezone-agnostic —
  all results are UTC epochs; the display layer localizes.

  Accuracy is the NOAA published bound (~1 minute for |lat| <= 72).
============================================================================]]

local M = {}

local rad = math.rad
local deg = math.deg

--- Julian day from a UTC epoch (whole-day resolution).
local function julianDay(epoch)
  return math.floor(epoch / 86400) + 2440587.5
end

--- Core NOAA computation for one civil day. Returns sunrise/sunset as UTC
--- epochs, or nil for polar day/night (sun never crosses the horizon).
--- dayEpoch is any epoch within the target UTC day.
function M.sunTimes(lat, lon, dayEpoch)
  lat = tonumber(lat)
  lon = tonumber(lon)
  dayEpoch = tonumber(dayEpoch)
  if lat == nil or lon == nil or dayEpoch == nil then
    return nil
  end
  local dayStart = math.floor(dayEpoch / 86400) * 86400
  local jd = julianDay(dayStart)
  -- Julian century from J2000, evaluated at solar noon guess.
  local t = (jd + 0.5 - 2451545) / 36525

  local geomMeanLong = (280.46646 + t * (36000.76983 + t * 0.0003032)) % 360
  local geomMeanAnom = 357.52911 + t * (35999.05029 - 0.0001537 * t)
  local eccent = 0.016708634 - t * (0.000042037 + 0.0000001267 * t)
  local sunEqCtr = math.sin(rad(geomMeanAnom)) * (1.914602 - t * (0.004817 + 0.000014 * t))
    + math.sin(rad(2 * geomMeanAnom)) * (0.019993 - 0.000101 * t)
    + math.sin(rad(3 * geomMeanAnom)) * 0.000289
  local sunTrueLong = geomMeanLong + sunEqCtr
  local sunAppLong = sunTrueLong - 0.00569 - 0.00478 * math.sin(rad(125.04 - 1934.136 * t))
  local meanObliq = 23 + (26 + (21.448 - t * (46.815 + t * (0.00059 - t * 0.001813))) / 60) / 60
  local obliqCorr = meanObliq + 0.00256 * math.cos(rad(125.04 - 1934.136 * t))
  local declin = deg(math.asin(math.sin(rad(obliqCorr)) * math.sin(rad(sunAppLong))))

  local y = math.tan(rad(obliqCorr / 2)) ^ 2
  local eqOfTime = 4
    * deg(
      y * math.sin(2 * rad(geomMeanLong))
        - 2 * eccent * math.sin(rad(geomMeanAnom))
        + 4 * eccent * y * math.sin(rad(geomMeanAnom)) * math.cos(2 * rad(geomMeanLong))
        - 0.5 * y * y * math.sin(4 * rad(geomMeanLong))
        - 1.25 * eccent * eccent * math.sin(2 * rad(geomMeanAnom))
    )

  -- Hour angle for official sunrise (zenith 90.833 deg: refraction + disc).
  local cosHa = (
    math.cos(rad(90.833)) / (math.cos(rad(lat)) * math.cos(rad(declin))) - math.tan(rad(lat)) * math.tan(rad(declin))
  )
  if cosHa > 1 or cosHa < -1 then
    return nil -- polar night (>1) or midnight sun (<-1)
  end
  local haSunrise = deg(math.acos(cosHa))

  -- Minutes from UTC midnight.
  local solarNoonMin = 720 - 4 * lon - eqOfTime
  local sunriseMin = solarNoonMin - haSunrise * 4
  local sunsetMin = solarNoonMin + haSunrise * 4

  return {
    sunrise = dayStart + math.floor(sunriseMin * 60 + 0.5),
    sunset = dayStart + math.floor(sunsetMin * 60 + 0.5),
    solarNoon = dayStart + math.floor(solarNoonMin * 60 + 0.5),
  }
end

--- Sunrise/sunset bracketing `now`: today's times plus the NEXT sunrise and
--- sunset after `now` (which may be tomorrow's). Also reports isDaytime.
--- localOffset (seconds east of UTC, optional) makes "today" the site's civil
--- day, not the UTC day.
---
--- sunTimes works on a calendar date and returns that date's sunrise and
--- sunset AT THE GIVEN LONGITUDE, which for a western site fall on the next
--- UTC day and for an eastern site on the previous one. So the date asked for
--- has to be the site's own date: `now + localOffset` read as a UTC date.
--- Asking for the UTC date of `now` instead answers with tomorrow's sun in a
--- western evening (the countdown to sunset reads a day too long and daytime
--- reads false hours before dusk) and with yesterday's in an eastern morning.
---
--- The next sunrise and sunset are searched over the days around today, so
--- they are right even when the offset given is not the site's (a driver
--- pointed at coordinates far from its controller).
function M.solarState(lat, lon, now, localOffset)
  now = tonumber(now)
  if now == nil then
    return nil
  end
  localOffset = tonumber(localOffset) or 0
  local localDay = now + localOffset
  local today = M.sunTimes(lat, lon, localDay)
  if today == nil then
    return nil
  end
  local isDaytime = false
  local nextSunrise, nextSunset
  for n = -1, 2 do
    local d = n == 0 and today or M.sunTimes(lat, lon, localDay + n * 86400)
    if d ~= nil then
      if now >= d.sunrise and now < d.sunset then
        isDaytime = true
      end
      if nextSunrise == nil and d.sunrise > now then
        nextSunrise = d.sunrise
      end
      if nextSunset == nil and d.sunset > now then
        nextSunset = d.sunset
      end
    end
  end
  local state = {
    sunrise = today.sunrise,
    sunset = today.sunset,
    solarNoon = today.solarNoon,
    isDaytime = isDaytime,
    nextSunrise = nextSunrise,
    nextSunset = nextSunset,
  }
  state.minutesToSunrise = nextSunrise ~= nil and math.floor((nextSunrise - now) / 60) or nil
  state.minutesToSunset = nextSunset ~= nil and math.floor((nextSunset - now) / 60) or nil
  return state
end

-- ─── Moon ─────────────────────────────────────────────────────────────────────

--- Mean synodic month (days) and a reference new moon: 2000-01-06 18:14 UTC.
--- The mean-cycle approximation drifts under ±1 day from true lunations —
--- fine for a phase display, useless for eclipse math (and labeled so).
local SYNODIC_DAYS = 29.530588853
local NEW_MOON_EPOCH = 947182440

local MOON_NAMES = {
  "New Moon",
  "Waxing Crescent",
  "First Quarter",
  "Waxing Gibbous",
  "Full Moon",
  "Waning Gibbous",
  "Last Quarter",
  "Waning Crescent",
}

--- Moon phase at a UTC epoch. Returns { phase = 0..1 (0 = new, 0.5 = full),
--- name = one of the eight common names, illumination = 0..100 percent } or
--- nil for a non-numeric epoch.
function M.moonPhase(epoch)
  epoch = tonumber(epoch)
  if epoch == nil then
    return nil
  end
  local phase = ((epoch - NEW_MOON_EPOCH) / (SYNODIC_DAYS * 86400)) % 1
  local idx = math.floor(phase * 8 + 0.5) % 8
  local illumination = (1 - math.cos(2 * math.pi * phase)) / 2 * 100
  return {
    phase = phase,
    name = MOON_NAMES[idx + 1],
    illumination = math.floor(illumination + 0.5),
  }
end

return M
