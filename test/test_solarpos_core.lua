package.path = "src/?.lua;" .. package.path
local P = require("solarpos.position")
local E = require("solarpos.engine")
local Solar = require("atmosphere.solar")
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
local function near(a, b, tol)
  return a ~= nil and b ~= nil and math.abs(a - b) <= tol
end
-- UTC epoch for a civil date/time, computed without os.time (whose table
-- form is local-time and DST-dependent): days-from-civil, proleptic Gregorian.
local function utc(y, m, d, hh, mm)
  if m <= 2 then
    y = y - 1
    m = m + 12
  end
  local era = math.floor(y / 400)
  local yoe = y - era * 400
  local doy = math.floor((153 * (m - 3) + 2) / 5) + d - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  local days = era * 146097 + doe - 719468
  return days * 86400 + (hh or 12) * 3600 + (mm or 0) * 60
end

print("== angles")
check("norm360", P.norm360(-10) == 350 and P.norm360(370) == 10)
check("angleDiff wraps", P.angleDiff(350, 10) == -20 and P.angleDiff(10, 350) == 20 and P.angleDiff(180, 0) == 180)
check("refraction near horizon ~0.57 deg", near(P.refraction(0), 1735 / 3600, 0.01))
check("refraction zero high up", P.refraction(89) == 0)
check("refraction at 10 deg ~0.09", near(P.refraction(10), 0.0905, 0.005), P.refraction(10))

print("== NOAA identities at solar noon (the sun's noon elevation is 90 - |lat - declination|)")
local sites = {
  { name = "Greenwich", lat = 51.4779, lon = -0.0015 },
  { name = "Miami", lat = 25.7617, lon = -80.1918 },
  { name = "Sydney", lat = -33.8688, lon = 151.2093 },
}
local dates = {
  { 2026, 3, 20, "equinox" },
  { 2026, 6, 21, "june solstice" },
  { 2026, 12, 21, "december solstice" },
}
for _, s in ipairs(sites) do
  for _, d in ipairs(dates) do
    local noon = Solar.sunTimes(s.lat, s.lon, utc(d[1], d[2], d[3], 12)).solarNoon
    local pos = P.position(s.lat, s.lon, noon)
    local expected = 90 - math.abs(s.lat - pos.declination)
    check(
      string.format("%s %s: noon elevation matches declination identity", s.name, d[4]),
      near(pos.geometric_elevation, expected, 0.15),
      string.format("%.2f vs %.2f", pos.geometric_elevation, expected)
    )
    local wantAz = s.lat >= pos.declination and 180 or 0
    check(
      string.format("%s %s: noon azimuth is %d", s.name, d[4], wantAz),
      near(pos.azimuth, wantAz, 1.0) or near(math.abs(pos.azimuth - wantAz), 360, 1.0),
      pos.azimuth
    )
  end
end
local decl = P.position(0, 0, utc(2026, 6, 21, 12)).declination
check("june solstice declination ~ +23.44", near(decl, 23.44, 0.05), decl)
decl = P.position(0, 0, utc(2026, 12, 21, 12)).declination
check("december solstice declination ~ -23.44", near(decl, -23.44, 0.05), decl)
decl = P.position(0, 0, utc(2026, 3, 20, 14, 46)).declination
check("march equinox declination ~ 0", near(decl, 0, 0.1), decl)

print("== sunrise / sunset consistency with atmosphere.solar")
for _, s in ipairs(sites) do
  local day = Solar.sunTimes(s.lat, s.lon, utc(2026, 6, 21, 12))
  local rise = P.position(s.lat, s.lon, day.sunrise)
  local set = P.position(s.lat, s.lon, day.sunset)
  check(
    s.name .. ": geometric elevation at sunrise is the official -0.833",
    near(rise.geometric_elevation, -0.833, 0.3),
    rise.geometric_elevation
  )
  check(
    s.name .. ": geometric elevation at sunset is the official -0.833",
    near(set.geometric_elevation, -0.833, 0.3),
    set.geometric_elevation
  )
  check(
    s.name .. ": sunrise in the east half, sunset in the west half",
    rise.azimuth < 180 and set.azimuth > 180,
    rise.azimuth .. "/" .. set.azimuth
  )
  check(s.name .. ": sunrise and sunset azimuths mirror about south", near(rise.azimuth, 360 - set.azimuth, 1.5))
end
-- NOAA published: Boulder CO 2010-06-21 sunrise 05:31 MDT, sunset 20:32 MDT (NOAA solar calculator example).
local boulder = Solar.sunTimes(40.0150, -105.2705, utc(2010, 6, 21, 18))
local riseLocal = os.date("!%H:%M", boulder.sunrise - 6 * 3600)
local setLocal = os.date("!%H:%M", boulder.sunset - 6 * 3600)
check(
  "Boulder 2010-06-21 sunrise 05:31 MDT (NOAA)",
  riseLocal == "05:31" or riseLocal == "05:32" or riseLocal == "05:30",
  riseLocal
)
check(
  "Boulder 2010-06-21 sunset 20:32 MDT (NOAA)",
  setLocal == "20:32" or setLocal == "20:31" or setLocal == "20:33",
  setLocal
)
local bNoon = P.position(40.0150, -105.2705, boulder.solarNoon)
check("Boulder noon elevation 73.4 (NOAA)", near(bNoon.elevation, 73.4, 0.3), bNoon.elevation)
local midnight = P.position(25.7617, -80.1918, utc(2026, 6, 21, 5)) -- 01:00 EDT
check("Miami 1 am: deep night", midnight.elevation < -20)
check(
  "east of the meridian before noon: hour angle negative",
  P.position(25.76, -80.19, utc(2026, 6, 21, 13)).hour_angle < 0
)
check("nil-safe", P.position(nil, 1, 2) == nil and P.position(1, 2, "x") == nil)

print("== phases")
check("day", E.phaseOf(30, true) == "day")
check("golden morning", E.phaseOf(3, true) == "golden_morning")
check("golden evening", E.phaseOf(3, false) == "golden_evening")
check("dawn", E.phaseOf(-3, true) == "dawn")
check("dusk", E.phaseOf(-3, false) == "dusk")
check("night", E.phaseOf(-10, true) == "night")
check("boundary -0.833 is golden", E.phaseOf(-0.833, true) == "golden_morning")
check("boundary 6 is day", E.phaseOf(6, false) == "day")

print("== facades")
local clean, refusals = E.validateFacades({
  { name = "South", azimuth = 180, width = 90, min_elevation = 5 },
  { name = "", azimuth = 90 },
  { name = "Odd", azimuth = "x" },
  { name = " West ", azimuth = -90, width = 500, min_elevation = 99 },
})
check(
  "unnamed and invalid dropped, refusal named",
  clean[2] == nil and clean[3] == nil and #refusals == 1 and refusals[1].index == 3
)
check(
  "azimuth normalised, width and elevation clamped, name trimmed",
  clean[4].azimuth == 270 and clean[4].width == 180 and clean[4].min_elevation == 60 and clean[4].name == "West"
)
local south = clean[1]
check("lit inside the arc above min", E.facadeLit(south, 30, 200, false) == true)
check("not lit below min elevation", E.facadeLit(south, 4.9, 180, false) == false)
check("not lit outside half width", E.facadeLit(south, 30, 225.5, false) == false)
check("hysteresis keeps it lit half a degree past the edge", E.facadeLit(south, 30, 225.5, true) == true)
check("hysteresis keeps it lit half a degree under min", E.facadeLit(south, 4.5, 180, true) == true)
check("a full degree past the edge turns it off", E.facadeLit(south, 30, 226.1, true) == false)
check("a full degree under min turns it off", E.facadeLit(south, 3.9, 180, true) == false)
check("no ceiling unless one is set", south.max_elevation == 90 and E.facadeLit(south, 89, 180, false) == true)
local capped, capRefusals = E.validateFacades({
  { name = "Overhang", azimuth = 180, width = 90, min_elevation = 5, max_elevation = 60 },
  { name = "Upside down", azimuth = 180, min_elevation = 20, max_elevation = 20 },
  { name = "Too much", azimuth = 180, max_elevation = 400 },
})
local overhang = capped[1]
check("lit under the ceiling", E.facadeLit(overhang, 59.9, 180, false) == true)
check("not lit above the ceiling", E.facadeLit(overhang, 60.1, 180, false) == false)
check("hysteresis keeps it lit half a degree above the ceiling", E.facadeLit(overhang, 60.5, 180, true) == true)
check("a full degree above the ceiling turns it off", E.facadeLit(overhang, 61.1, 180, true) == false)
check(
  "a ceiling at or under the floor is refused by name, not kept as a facade that never lights",
  capped[2] == nil
    and #capRefusals == 1
    and capRefusals[1].index == 2
    and capRefusals[1].reason:find("max elevation") ~= nil,
  capRefusals[1] and capRefusals[1].reason
)
check("a ceiling above 90 is clamped", capped[3].max_elevation == 90)
check("shade reason: lit has none", E.shadeReason(overhang, 30, 180, true) == nil)
check("shade reason: sun too high", E.shadeReason(overhang, 70, 180, false) == "high")
check("shade reason: sun too low", E.shadeReason(overhang, 2, 180, false) == "low")
check("shade reason: sun off to the side wins over height", E.shadeReason(overhang, 70, 300, false) == "aside")
local north = E.validateFacades({ { name = "N", azimuth = 0, width = 60 } })[1]
check(
  "wrap-around arc across north",
  E.facadeLit(north, 10, 350, false) and E.facadeLit(north, 10, 25, false) and not E.facadeLit(north, 10, 40, false)
)

print("== engine: a Miami June day, one-minute ticks")
local eng = E.new()
check("no location → nil tick", eng:tick(utc(2026, 6, 21, 12), 0) == nil)
eng:setLocation(25.7617, -80.1918)
eng:setFacades({
  { name = "East", azimuth = 90, width = 90, min_elevation = 5 },
  { name = "South", azimuth = 180, width = 90, min_elevation = 5 },
  { name = "West", azimuth = 270, width = 90, min_elevation = 5 },
})
local offset = -4 * 3600 -- EDT
local start = utc(2026, 6, 21, 4) -- 00:00 EDT
local counts, order = {}, {}
local phases = {}
local lastPhase = nil
for i = 0, 1439 do
  local r = eng:tick(start + i * 60, offset)
  for _, e in ipairs(r.events) do
    counts[e] = (counts[e] or 0) + 1
    order[#order + 1] = e
  end
  if r.phase ~= lastPhase then
    phases[#phases + 1] = r.phase
    lastPhase = r.phase
  end
end
check(
  "phase sequence over the day",
  table.concat(phases, ">") == "night>dawn>golden_morning>day>golden_evening>dusk>night",
  table.concat(phases, ">")
)
check("civil dawn once", counts.civil_dawn == 1, counts.civil_dawn)
check("golden hour twice (morning and evening)", counts.golden_hour == 2, counts.golden_hour)
check("civil dusk once", counts.civil_dusk == 1, counts.civil_dusk)
check("east facade hit once, left once", counts["facade_hit:1"] == 1 and counts["facade_left:1"] == 1)
check("south facade hit once, left once", counts["facade_hit:2"] == 1 and counts["facade_left:2"] == 1)
check("west facade hit once, left once", counts["facade_hit:3"] == 1 and counts["facade_left:3"] == 1)
check(
  "east lit before south, south before west",
  (function()
    local pos = {}
    for i, e in ipairs(order) do
      pos[e] = pos[e] or i
    end
    return pos["facade_hit:1"] < pos["facade_hit:2"] and pos["facade_hit:2"] < pos["facade_hit:3"]
  end)()
)
for _, e in ipairs({ "sunrise", "golden_morning_ended", "golden_evening", "sunset", "night" }) do
  check(e .. " once", counts[e] == 1, counts[e])
end
check("one event per boundary, in the order the day runs", (function()
  local seen = {}
  for _, e in ipairs(order) do
    if not e:find("^facade") and e ~= "golden_hour" and e ~= "civil_dusk" then
      seen[#seen + 1] = e
    end
  end
  return table.concat(seen, ">")
end)() == "civil_dawn>sunrise>golden_morning_ended>golden_evening>sunset>night", table.concat(order, ">"))
check(
  "the older names still fire, in the same tick as the new ones they overlap",
  (function()
    local pos = {}
    for i, e in ipairs(order) do
      pos[e] = pos[e] or i
    end
    return pos.sunrise ~= nil
      and pos.sunset ~= nil
      and pos.golden_hour == pos.sunrise + 1
      and pos.civil_dusk == pos.sunset + 1
  end)(),
  table.concat(order, ">")
)
check(
  "no facade event in the first tick (initial state is not a transition)",
  (function()
    local e2 = E.new()
    e2:setLocation(51.4779, -0.0015) -- Greenwich: the June sun is due south at 12:00 UTC
    e2:setFacades({ { name = "South", azimuth = 180 } })
    local r = e2:tick(utc(2026, 6, 21, 12), 3600)
    return #r.events == 0 and r.facades[1].lit == true
  end)()
)
local last = eng.last
check(
  "tick result carries solar state and daylight flag",
  last.solar ~= nil and last.is_daylight == false and last.solar.nextSunrise ~= nil
)
check(
  "minutes to sunset positive and under a day",
  last.solar.minutesToSunset > 0 and last.solar.minutesToSunset < 1440
)

print("== engine: a ceiling splits the day (26N, September, south glass under an overhang)")
do
  local e3 = E.new()
  e3:setLocation(26, -80)
  e3:setFacades({ { name = "South", azimuth = 180, width = 90, min_elevation = 5, max_elevation = 60 } })
  local day = utc(2026, 9, 22, 4) -- 00:00 EDT
  local hits, lefts, highMinutes, litAbove = 0, 0, 0, false
  for i = 0, 1439 do
    local r = e3:tick(day + i * 60, -4 * 3600)
    for _, ev in ipairs(r.events) do
      if ev == "facade_hit:1" then
        hits = hits + 1
      elseif ev == "facade_left:1" then
        lefts = lefts + 1
      end
    end
    if r.facades[1].shade == "high" then
      highMinutes = highMinutes + 1
    end
    if r.facades[1].lit and r.position.elevation > 61 then
      litAbove = true
    end
  end
  check("lit before and after the high sun: two hits, two leaves", hits == 2 and lefts == 2, hits .. "/" .. lefts)
  check("in between it is in shade because the sun is too high", highMinutes > 30, highMinutes)
  check("never lit more than the hysteresis above the ceiling", litAbove == false)
  e3:setFacades({ { name = "South", azimuth = 180, width = 90, min_elevation = 5, max_elevation = 70 } })
  check("a new ceiling forgets the lit states", next(e3.lit) == nil)
end

print("== engine: a late tick still reports the horizon and the night")
do
  local e4 = E.new()
  e4:setLocation(25.7617, -80.1918)
  local r1 = e4:tick(utc(2026, 6, 21, 22), -4 * 3600) -- 18:00 EDT, day
  local r2 = e4:tick(utc(2026, 6, 22, 3), -4 * 3600) -- 23:00 EDT, night: five hours with no tick
  local got = {}
  for _, ev in ipairs(r2.events) do
    got[ev] = true
  end
  check("day then night in one step", r1.phase == "day" and r2.phase == "night")
  check("sunset and night both reported once", got.sunset == true and got.night == true and #r2.events == 2)
  local r3 = e4:tick(utc(2026, 6, 22, 3, 1), -4 * 3600)
  check("and not again a minute later", #r3.events == 0)
end

print("== engine: changes reset state")
eng:setLocation(51.4779, -0.0015)
eng:tick(utc(2026, 6, 21, 12), 3600)
local before = eng.lit[2]
eng:setFacades({
  { name = "East", azimuth = 90, width = 90, min_elevation = 5 },
  { name = "South", azimuth = 181, width = 90, min_elevation = 5 },
  { name = "West", azimuth = 270, width = 90, min_elevation = 5 },
})
check("facade change forgets lit states", before == true and next(eng.lit) == nil)
local r = eng:tick(utc(2026, 6, 21, 12, 1), 3600)
check("first tick after a change announces nothing", #r.events == 0 and r.facades[2].lit == true)
eng:setLocation(25.7617, -80.1918)
check("location change forgets the phase", eng.phase == nil)
eng:setLocation(51.4779, -0.0015)
check(
  "same location again keeps state",
  (function()
    eng:tick(utc(2026, 6, 21, 12), 3600)
    local p = eng.phase
    eng:setLocation(51.4779, -0.0015)
    return eng.phase == p
  end)()
)
check("bad location clears", eng:setLocation("x", 1) == false and eng.location == nil)

print("== polar edge: no solar noon still ticks")
local polar = E.new()
polar:setLocation(78.2232, 15.6267) -- Longyearbyen, midnight sun in June
local pr = polar:tick(utc(2026, 6, 21, 0), 7200)
check(
  "midnight sun: a phase and a daylight flag without sunrise/sunset",
  pr ~= nil and pr.is_daylight == true and pr.solar == nil
)

print("== the day is the site's day, not the UTC day")
do
  local SolarState = require("atmosphere.solar").solarState
  local function hm(epoch, offsetHours)
    return os.date("!%d %H:%M", epoch + offsetHours * 3600)
  end
  -- Los Angeles, 21 June, 17:30 PDT: already 00:30 UTC on the 22nd. Sunset is
  -- still two and a half hours away, today.
  local la = SolarState(34, -118, utc(2026, 6, 22, 0, 30), -7 * 3600)
  check("western evening: today's sunset, not tomorrow's", hm(la.sunset, -7) == "21 20:06", hm(la.sunset, -7))
  check("western evening: the countdown is hours, not a day", la.minutesToSunset == 156, la.minutesToSunset)
  check("western evening: it is still daytime", la.isDaytime == true)
  check(
    "western evening: next sunrise is tomorrow morning",
    hm(la.nextSunrise, -7) == "22 05:41",
    hm(la.nextSunrise, -7)
  )
  -- Florida, 21 June, 20:05 EDT (00:05 UTC): nine minutes to sunset.
  local fl = SolarState(26, -80, utc(2026, 6, 22, 0, 5), -4 * 3600)
  check("nine minutes before a sunset that falls after 00:00 UTC", fl.minutesToSunset == 9, fl.minutesToSunset)
  -- Tokyo, 11 November, 07:00 JST: still 22:00 UTC on the 10th. The sun rose
  -- 47 minutes ago, today.
  local tk = SolarState(35.68, 139.69, utc(2026, 11, 10, 22, 0), 9 * 3600)
  check("eastern morning: today's sunrise, not yesterday's", hm(tk.sunrise, 9) == "11 06:13", hm(tk.sunrise, 9))
  check("eastern morning: daytime after sunrise", tk.isDaytime == true)
  check(
    "eastern morning: the next sunrise is in the future",
    tk.minutesToSunrise > 0 and hm(tk.nextSunrise, 9) == "12 06:14",
    hm(tk.nextSunrise, 9)
  )
  -- Before dawn there, the next sunrise is this morning's.
  local dawn = SolarState(35.68, 139.69, utc(2026, 11, 10, 20, 0), 9 * 3600)
  check(
    "eastern night: next sunrise is this morning",
    dawn.minutesToSunrise == 73 and dawn.isDaytime == false,
    dawn.minutesToSunrise
  )
  -- A driver pointed at coordinates far from its controller passes the
  -- controller's offset. The next sunset must still be the next one.
  local far = SolarState(34, -118, utc(2026, 6, 22, 0, 30), 9 * 3600)
  check(
    "a wrong offset still finds the next sunset",
    far.minutesToSunset == 156 and far.isDaytime == true,
    far.minutesToSunset
  )
  -- Every minute of a day, at three sites: the countdown never jumps up
  -- except across the sunset itself, and is never negative.
  local worst = nil
  for _, site in ipairs({ { 34, -118, -7 }, { 26, -80, -4 }, { 35.68, 139.69, 9 }, { -33.87, 151.21, 11 } }) do
    local last
    for m = 0, 1439 do
      local st = SolarState(site[1], site[2], utc(2026, 6, 21, 0, 0) + m * 60, site[3] * 3600)
      if st.minutesToSunset < 0 or st.minutesToSunrise < 0 then
        worst = "negative at minute " .. m
      end
      if last ~= nil and st.minutesToSunset > last and last > 1 then
        worst = string.format("jump from %d to %d at minute %d (lon %s)", last, st.minutesToSunset, m, site[2])
      end
      last = st.minutesToSunset
    end
  end
  check("the countdown only jumps at the sunset, at any site and hour", worst == nil, worst)
end

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
