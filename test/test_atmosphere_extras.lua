-- Tests for the Atmosphere extras: gridcalc (duration-weighted grid-layer
-- math), trend (observation ring buffer + barometric trend), moon phase,
-- recommendations, and the engine's extraFlags transition gate.
--
-- Invariants under test:
--   * A window no grid sample touches returns nil, never 0.
--   * Partial interval overlap contributes proportionally (accumulation
--     layers state a total for their interval).
--   * Trend is nil under 2 samples or under a 90-minute span — "not enough
--     evidence" is never "STEADY"; the 3-hour window excludes older samples.
--   * Moon phase names hit known dates (mean-cycle tolerance: name-level).
--   * Recommendations: nil inputs can never trigger a clause.
--   * extraFlags diff through the engine with first-sight-is-baseline; a
--     tick without extraFlags carries the previous set and fires nothing.
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

local function near(a, b, eps)
  return a ~= nil and b ~= nil and math.abs(a - b) <= (eps or 0.01)
end

local gridcalc = require("atmosphere.gridcalc")
local trend = require("atmosphere.trend")
local solar = require("atmosphere.solar")
local recommend = require("atmosphere.recommend")
local thresholds = require("atmosphere.thresholds")
local engine = require("atmosphere.engine")

local NOW = 1767225600 -- 2026-01-01T00:00:00Z

-- ─── gridcalc: sums ───────────────────────────────────────────────────────────

local twoHours = {
  { start = 0, duration = 3600, value = 10 },
  { start = 3600, duration = 3600, value = 20 },
}
check("sumOver full containment", near(gridcalc.sumOver(twoHours, 0, 7200), 30))
check("sumOver partial overlap is proportional", near(gridcalc.sumOver(twoHours, 1800, 5400), 15))
check("sumOver leading partial only", near(gridcalc.sumOver(twoHours, 0, 1800), 5))
check("sumOver disjoint window is nil, never 0", gridcalc.sumOver(twoHours, 10000, 20000) == nil)
check("sumOver empty samples is nil", gridcalc.sumOver({}, 0, 100) == nil)
check("sumOver nil samples is nil", gridcalc.sumOver(nil, 0, 100) == nil)
check("sumOver inverted window is nil", gridcalc.sumOver(twoHours, 100, 100) == nil)

local pointSample = { { start = 100, duration = 0, value = 5 } }
check("sumOver point sample counts fully inside", near(gridcalc.sumOver(pointSample, 0, 200), 5))
check("sumOver point sample outside is nil", gridcalc.sumOver(pointSample, 200, 300) == nil)

check("sumOver skips malformed samples", near(gridcalc.sumOver({ { start = 0 }, twoHours[1] }, 0, 3600), 10))

-- ─── gridcalc: max ────────────────────────────────────────────────────────────

check("maxOver across both intervals", gridcalc.maxOver(twoHours, 0, 7200) == 20)
check("maxOver excludes non-overlapping interval", gridcalc.maxOver(twoHours, 0, 3600) == 10)
check("maxOver disjoint window is nil", gridcalc.maxOver(twoHours, 7200, 9000) == nil)
check("maxOver point sample", gridcalc.maxOver(pointSample, 0, 200) == 5)

-- ─── gridcalc: unit helpers ───────────────────────────────────────────────────

local snowLayer = { { start = NOW, duration = 6 * 3600, value = 25.4 } }
check("snowfallNext24In converts mm to inches", near(gridcalc.snowfallNext24In(snowLayer, NOW), 1.0))
local qpfSpanning = { { start = NOW + 23 * 3600, duration = 2 * 3600, value = 10 } }
check("rainNext24In weights the 24h boundary", near(gridcalc.rainNext24In(qpfSpanning, NOW), 5 / 25.4, 0.001))
check("rainNext24In no data is nil", gridcalc.rainNext24In({}, NOW) == nil)
local thunderLayer = {
  { start = NOW, duration = 6 * 3600, value = 10 },
  { start = NOW + 6 * 3600, duration = 6 * 3600, value = 55 },
  { start = NOW + 13 * 3600, duration = 6 * 3600, value = 80 },
}
check("peakThunderPct12h stops at 12h", gridcalc.peakThunderPct12h(thunderLayer, NOW) == 55)
check("helpers nil-safe on now", gridcalc.snowfallNext24In(snowLayer, nil) == nil)

-- ─── trend: pressure ──────────────────────────────────────────────────────────

check("trend nil on empty history", trend.pressureTrend({}, NOW) == nil)
check("trend nil on one sample", trend.pressureTrend({ { t = NOW, pressureInHg = 29.9 } }, NOW) == nil)
check(
  "trend nil under 90min span",
  trend.pressureTrend({ { t = NOW - 3600, pressureInHg = 29.8 }, { t = NOW, pressureInHg = 30.2 } }, NOW) == nil
)
check(
  "trend RISING at +0.10 over window",
  trend.pressureTrend({ { t = NOW - 10000, pressureInHg = 29.90 }, { t = NOW, pressureInHg = 30.00 } }, NOW) == "RISING"
)
local fallName, fallDelta =
  trend.pressureTrend({ { t = NOW - 10000, pressureInHg = 30.02 }, { t = NOW, pressureInHg = 29.90 } }, NOW)
check("trend FALLING at -0.12", fallName == "FALLING")
check("trend returns the raw delta", near(fallDelta, -0.12, 0.0001))
check("trend delta clears the rapid-fall gate", fallDelta ~= nil and fallDelta <= -trend.RAPID_FALL_INHG)
check(
  "trend STEADY inside the band",
  trend.pressureTrend({ { t = NOW - 10000, pressureInHg = 29.90 }, { t = NOW, pressureInHg = 29.92 } }, NOW) == "STEADY"
)
check("trend ignores samples outside the 3h window", trend.pressureTrend({
  { t = NOW - 4 * 3600, pressureInHg = 10.0 },
  { t = NOW - 7200, pressureInHg = 29.90 },
  { t = NOW, pressureInHg = 29.91 },
}, NOW) == "STEADY")
check(
  "trend skips nil pressures (one usable sample -> nil)",
  trend.pressureTrend({ { t = NOW - 7200, pressureInHg = nil }, { t = NOW, pressureInHg = 29.9 } }, NOW) == nil
)
check("trend nil-safe on now", trend.pressureTrend({ { t = NOW, pressureInHg = 29.9 } }, nil) == nil)

-- ─── trend: ring buffer ───────────────────────────────────────────────────────

local buf = {}
for i = 1, 305 do
  buf = trend.append(buf, { t = NOW + i, tempF = 70, pressureInHg = 29.9 }, NOW + i)
end
check("append caps at 300 entries", #buf == 300)
check("append keeps the newest entries", buf[#buf].t == NOW + 305 and buf[1].t == NOW + 6)

local aged = trend.append(
  { { t = NOW - 25 * 3600, pressureInHg = 29.5 }, { t = NOW - 3600, pressureInHg = 29.9 } },
  { t = NOW, pressureInHg = 30.0 },
  NOW
)
check("append prunes entries older than 24h", #aged == 2 and aged[1].t == NOW - 3600)

local big = {}
for i = 1, 100 do
  big[i] = { t = i }
end
local ds = trend.downsample(big, 48)
check("downsample to 48 points", #ds == 48)
check("downsample keeps first and last", ds[1].t == 1 and ds[48].t == 100)
check("downsample passes small lists through", #trend.downsample({ { t = 1 }, { t = 2 } }, 48) == 2)

-- ─── moon phase ───────────────────────────────────────────────────────────────

local ref = solar.moonPhase(947182440) -- 2000-01-06 18:14 UTC, the reference new moon
check("moon reference epoch is New Moon", ref ~= nil and ref.name == "New Moon", ref and ref.name)
check("moon reference illumination ~0", ref ~= nil and ref.illumination <= 1, ref and ref.illumination)
local full = solar.moonPhase(1767441600) -- 2026-01-03 12:00 UTC (known full moon)
check("moon 2026-01-03 is Full Moon", full ~= nil and full.name == "Full Moon", full and full.name)
check("moon full illumination >= 95", full ~= nil and full.illumination >= 95, full and full.illumination)
check("moon phase in [0,1)", full ~= nil and full.phase >= 0 and full.phase < 1)
local newMoon = solar.moonPhase(1768737600) -- 2026-01-18 12:00 UTC (known new moon)
check("moon 2026-01-18 is New Moon", newMoon ~= nil and newMoon.name == "New Moon", newMoon and newMoon.name)
local crescent = solar.moonPhase(1768996800) -- 2026-01-21 12:00 UTC
check(
  "moon 2026-01-21 is Waxing Crescent",
  crescent ~= nil and crescent.name == "Waxing Crescent",
  crescent and crescent.name
)
check("moon nil-safe", solar.moonPhase(nil) == nil)

-- ─── recommendations ──────────────────────────────────────────────────────────

check("irrigation: all nil is false", recommend.irrigationSkip({}) == false)
check("irrigation: raining now", recommend.irrigationSkip({ isRaining = true }) == true)
check("irrigation: rain at threshold", recommend.irrigationSkip({ rainNext24In = 0.25 }) == true)
check("irrigation: rain below threshold", recommend.irrigationSkip({ rainNext24In = 0.24 }) == false)
check("irrigation: pop at threshold", recommend.irrigationSkip({ popMax24h = 60 }) == true)
check("irrigation: pop below threshold", recommend.irrigationSkip({ popMax24h = 59 }) == false)
check(
  "irrigation: override raises the rain bar",
  recommend.irrigationSkip({ rainNext24In = 0.3 }, { irrigation_rain_next24_in = 0.5 }) == false
)
check("shade: all nil is false", recommend.shadeProtect({}) == false)
check("shade: gust at threshold", recommend.shadeProtect({ gustMph = 30 }) == true)
check("shade: gust below threshold", recommend.shadeProtect({ gustMph = 29.9 }) == false)
check("shade: sustained wind at threshold", recommend.shadeProtect({ windMph = 25 }) == true)
check("shade: forecast high wind", recommend.shadeProtect({ highWindExpected = true }) == true)
check("shade: override raises the wind bar", recommend.shadeProtect({ windMph = 30 }, { shade_wind_mph = 40 }) == false)

-- ─── engine: extraFlags transition gate ───────────────────────────────────────

local T = thresholds.effective({})
local emptyAlerts = { active = {}, new = {}, updated = {}, canceled = {}, expired = {}, escalated = {} }
local function step(prev, extra)
  return engine.step(prev, {
    obs = nil,
    hourly = {},
    alertsResult = emptyAlerts,
    thresholds = T,
    now = NOW,
    localOffset = 0,
    obsFetchedAt = NOW,
    forecastFetchedAt = NOW,
    alertsFetchedAt = NOW,
    apiOk = true,
    extraFlags = extra,
  })
end
local function has(events, name)
  for _, e in ipairs(events) do
    if e == name then
      return true
    end
  end
  return false
end

local s1, e1 = step(nil, {
  irrigation_skip = true,
  shade_protect = false,
  sunset_soon = false,
  sunrise_soon = false,
  barometer_falling_fast = false,
})
check("extraFlags first sight is baseline (no events)", #e1 == 0, table.concat(e1, ","))
check("extraFlags stored on the snapshot", s1.extraFlags ~= nil and s1.extraFlags.irrigation_skip == true)

local s2, e2 = step(s1, {
  irrigation_skip = true,
  shade_protect = false,
  sunset_soon = false,
  sunrise_soon = false,
  barometer_falling_fast = false,
})
check("extraFlags unchanged fires nothing", #e2 == 0, table.concat(e2, ","))

local s3, e3 = step(s2, {
  irrigation_skip = false,
  shade_protect = false,
  sunset_soon = false,
  sunrise_soon = false,
  barometer_falling_fast = false,
})
check("irrigation clear fires Irrigation Skip Cleared", has(e3, "Irrigation Skip Cleared") and #e3 == 1)

local s4, e4 = step(s3, {
  irrigation_skip = true,
  shade_protect = false,
  sunset_soon = false,
  sunrise_soon = false,
  barometer_falling_fast = false,
})
check("irrigation assert fires Irrigation Skip Recommended", has(e4, "Irrigation Skip Recommended"))

local s5, e5 = step(s4, nil)
check("nil extraFlags carries the previous set forward", s5.extraFlags ~= nil and s5.extraFlags.irrigation_skip == true)
check("nil extraFlags fires nothing", #e5 == 0, table.concat(e5, ","))

local s6, e6 = step(s5, {
  irrigation_skip = true,
  shade_protect = true,
  sunset_soon = false,
  sunrise_soon = false,
  barometer_falling_fast = false,
})
check("shade assert fires Shade Protection Recommended", has(e6, "Shade Protection Recommended") and #e6 == 1)
local s7, e7 = step(s6, {
  irrigation_skip = true,
  shade_protect = false,
  sunset_soon = false,
  sunrise_soon = false,
  barometer_falling_fast = false,
})
check("shade clear is silent", #e7 == 0, table.concat(e7, ","))

local _, e8 = step(s7, {
  irrigation_skip = true,
  shade_protect = false,
  sunset_soon = true,
  sunrise_soon = true,
  barometer_falling_fast = true,
})
check(
  "solar + barometer flags fire their events",
  has(e8, "Sunset Approaching") and has(e8, "Sunrise Approaching") and has(e8, "Barometer Falling Rapidly"),
  table.concat(e8, ",")
)

-- Frozen-id discipline: the new events append after 58 with the agreed ids.
local byId = {}
for _, e in ipairs(engine.EVENTS) do
  byId[e[1]] = e[2]
end
check("event 59 is Sunset Approaching", byId[59] == "Sunset Approaching")
check("event 60 is Sunrise Approaching", byId[60] == "Sunrise Approaching")
check("event 61 is Barometer Falling Rapidly", byId[61] == "Barometer Falling Rapidly")
check("event 62 is Irrigation Skip Recommended", byId[62] == "Irrigation Skip Recommended")
check("event 63 is Irrigation Skip Cleared", byId[63] == "Irrigation Skip Cleared")
check("event 64 is Shade Protection Recommended", byId[64] == "Shade Protection Recommended")
check("no event id beyond 64 yet", byId[65] == nil and #engine.EVENTS == 64)

-- ─── result ───────────────────────────────────────────────────────────────────

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
