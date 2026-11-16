--- Solar Position — sun elevation and azimuth at an instant (pure).
---
--- `atmosphere.solar` gives the day's sunrise/sunset/solar noon (NOAA
--- equations, whole-day resolution). This module adds what a shading or
--- lighting rule needs minute by minute: the apparent elevation (refraction
--- corrected, NOAA's own formula) and the azimuth (degrees clockwise from
--- true north) of the sun for a latitude/longitude at a UTC epoch.
---
--- Offline, deterministic, timezone-agnostic: epochs in, degrees out.
--- Accuracy is the NOAA published bound (about 0.01 degree in the equations,
--- a few tenths after refraction near the horizon), which is far inside the
--- one-degree hysteresis the engine applies to every edge.

local M = {}

local rad = math.rad
local deg = math.deg

--- Normalises an angle to [0, 360).
function M.norm360(a)
  a = a % 360
  if a < 0 then
    a = a + 360
  end
  return a
end

--- Smallest signed difference a - b in degrees, in (-180, 180].
function M.angleDiff(a, b)
  local d = (a - b) % 360
  if d > 180 then
    d = d - 360
  end
  return d
end

--- NOAA atmospheric refraction correction, degrees to ADD to the geometric
--- elevation. Zero above 85 degrees; the published piecewise fit elsewhere.
function M.refraction(elevation)
  if elevation > 85 then
    return 0
  end
  local te = math.tan(rad(elevation))
  local arcsec
  if elevation > 5 then
    arcsec = 58.1 / te - 0.07 / (te ^ 3) + 0.000086 / (te ^ 5)
  elseif elevation > -0.575 then
    arcsec = 1735 + elevation * (-518.2 + elevation * (103.4 + elevation * (-12.79 + elevation * 0.711)))
  else
    arcsec = -20.772 / te
  end
  return arcsec / 3600
end

--- The sun's position at `epoch` (UTC seconds) seen from lat/lon (degrees).
--- @return table|nil { elevation, geometric_elevation, azimuth, declination, zenith, equation_of_time, hour_angle }
function M.position(lat, lon, epoch)
  lat, lon, epoch = tonumber(lat), tonumber(lon), tonumber(epoch)
  if lat == nil or lon == nil or epoch == nil then
    return nil
  end
  local jd = epoch / 86400 + 2440587.5
  local t = (jd - 2451545) / 36525

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

  -- True solar time in minutes, then the hour angle (negative before noon).
  local minutesUtc = (epoch % 86400) / 60
  local trueSolarTime = (minutesUtc + eqOfTime + 4 * lon) % 1440
  local hourAngle = trueSolarTime / 4 - 180

  local cosZenith = math.sin(rad(lat)) * math.sin(rad(declin))
    + math.cos(rad(lat)) * math.cos(rad(declin)) * math.cos(rad(hourAngle))
  if cosZenith > 1 then
    cosZenith = 1
  elseif cosZenith < -1 then
    cosZenith = -1
  end
  local zenith = deg(math.acos(cosZenith))
  local geometric = 90 - zenith
  local elevation = geometric + M.refraction(geometric)

  local azimuth
  local denom = math.cos(rad(lat)) * math.sin(rad(zenith))
  if math.abs(denom) < 1e-9 then
    -- Sun at the zenith or an observer at a pole: azimuth is undefined;
    -- report south/north by hemisphere so callers get a number.
    azimuth = lat >= 0 and 180 or 0
  else
    local cosAz = (math.sin(rad(lat)) * math.cos(rad(zenith)) - math.sin(rad(declin))) / denom
    if cosAz > 1 then
      cosAz = 1
    elseif cosAz < -1 then
      cosAz = -1
    end
    local az = deg(math.acos(cosAz))
    if hourAngle > 0 then
      azimuth = M.norm360(az + 180)
    else
      azimuth = M.norm360(540 - az)
    end
  end

  return {
    elevation = elevation,
    geometric_elevation = geometric,
    azimuth = azimuth,
    declination = declin,
    zenith = zenith,
    equation_of_time = eqOfTime,
    hour_angle = hourAngle,
  }
end

return M
