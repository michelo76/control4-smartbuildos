-- Tests for the Atmosphere pure core: units, intervals, normalize, solar.
--
-- Invariants under test:
--   * nil in, nil out — a missing reading NEVER becomes 0 anywhere.
--   * ISO8601 parsing is host-timezone-independent (own civil-day math).
--   * MADIS qualityControl X/Q/B values are dropped, V/Z pass through.
--   * A healthy observation with six nulls (the live-measured norm)
--     normalizes without error and without fabricated values.
--   * Forecast period unit traps: bare-F temperature, degC dewpoint object,
--     human wind strings ("5 to 10 mph").
--   * Solar math: equinox day length, polar refusal, day/night flag.
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

local units = require("atmosphere.units")
local intervals = require("atmosphere.intervals")
local normalize = require("atmosphere.normalize")
local solar = require("atmosphere.solar")

-- ─── units ────────────────────────────────────────────────────────────────────

check("cToF converts", near(units.cToF(20), 68))
check("cToF nil-safe", units.cToF(nil) == nil)
check("fToC converts", near(units.fToC(32), 0))
check("kmhToMph converts", near(units.kmhToMph(100), 62.1371))
check("paToInHg converts", near(units.paToInHg(101325), 29.92, 0.02))
check("paToHpa converts", near(units.paToHpa(101325), 1013.25))
check("metersToMiles converts", near(units.metersToMiles(16093.44), 10))
check("mmToInches converts", near(units.mmToInches(25.4), 1))
check("degToCompass north", units.degToCompass(0) == "N")
check("degToCompass 225 is SW", units.degToCompass(225) == "SW")
check("degToCompass wraps 359", units.degToCompass(359) == "N")
check("degToCompass nil-safe", units.degToCompass(nil) == nil)
check("round decimals", units.round(3.14159, 2) == 3.14)
check("one formats", units.one(72.26) == "72.3")
check("one nil fallback", units.one(nil) == "-")

-- ─── intervals ────────────────────────────────────────────────────────────────

check("parseTimestamp epoch anchor", intervals.parseTimestamp("2026-01-01T00:00:00+00:00") == 1767225600)
check("parseTimestamp Z suffix", intervals.parseTimestamp("2026-01-01T00:00:00Z") == 1767225600)
check("parseTimestamp negative offset", intervals.parseTimestamp("2025-12-31T19:00:00-05:00") == 1767225600)
check("parseTimestamp positive offset", intervals.parseTimestamp("2026-01-01T01:00:00+01:00") == 1767225600)
check("parseTimestamp fractional seconds", intervals.parseTimestamp("2026-01-01T00:00:00.123Z") == 1767225600)
check("parseTimestamp garbage is nil", intervals.parseTimestamp("yesterday") == nil)
check("parseTimestamp nil-safe", intervals.parseTimestamp(nil) == nil)

check("parseDuration hours", intervals.parseDuration("PT6H") == 21600)
check("parseDuration mixed", intervals.parseDuration("P1DT12H30M") == 131400)
check("parseDuration seconds", intervals.parseDuration("PT30S") == 30)
check("parseDuration refuses months", intervals.parseDuration("P1M") == nil)
check("parseDuration garbage is nil", intervals.parseDuration("6 hours") == nil)

local iv = intervals.parseInterval("2026-01-01T00:00:00+00:00/PT6H")
check("parseInterval start", iv ~= nil and iv.start == 1767225600)
check("parseInterval duration", iv ~= nil and iv.duration == 21600)
check("contains inside", intervals.contains(iv, 1767225600 + 100))
check("contains end-exclusive", not intervals.contains(iv, 1767225600 + 21600))
local bare = intervals.parseInterval("2026-01-01T00:00:00+00:00")
check("parseInterval bare timestamp", bare ~= nil and bare.duration == 0)

-- ─── normalize: quantities + QC ───────────────────────────────────────────────

check("quantity extracts value", normalize.quantity({ value = 21.5, unitCode = "wmoUnit:degC" }) == 21.5)
check("quantity null value is nil", normalize.quantity({ value = nil, qualityControl = "Z" }) == nil)
check("quantity rejects QC X", normalize.quantity({ value = 5, qualityControl = "X" }) == nil)
check("quantity rejects QC Q", normalize.quantity({ value = 5, qualityControl = "Q" }) == nil)
check("quantity rejects QC B", normalize.quantity({ value = 5, qualityControl = "B" }) == nil)
check("quantity passes QC V", normalize.quantity({ value = 5, qualityControl = "V" }) == 5)
check("quantity non-table is nil", normalize.quantity("21") == nil)

check("windRange single", select(1, normalize.windRange("5 mph")) == 5)
local lo, hi = normalize.windRange("5 to 10 mph")
check("windRange range lo", lo == 5)
check("windRange range hi", hi == 10)
check("windRange garbage is nil", normalize.windRange("breezy") == nil)

check("cloudCover worst layer wins", normalize.cloudCover({ { amount = "FEW" }, { amount = "BKN" } }) == 75)
check("cloudCover clear", normalize.cloudCover({ { amount = "CLR" } }) == 0)
check("cloudCover empty is nil", normalize.cloudCover({}) == nil)

local flags = normalize.conditionFlags("Chance Rain Showers And Thunderstorms")
check("conditionFlags rain", flags.rain == true)
check("conditionFlags thunder", flags.thunder == true)
check("conditionFlags fog on haze", normalize.conditionFlags("Haze").fog == true)
check("conditionFlags snow", normalize.conditionFlags("Heavy Snow").snow == true)
check("conditionFlags ice on freezing rain", normalize.conditionFlags("Freezing Rain").ice == true)
check("conditionFlags clear", normalize.conditionFlags("Sunny").clear == true)

-- ─── normalize: observation (the six-nulls-is-normal case) ────────────────────

local obs = normalize.observation({
	timestamp = "2026-08-31T14:52:00+00:00",
	station = "https://api.weather.gov/stations/KDCA",
	textDescription = "Clear",
	temperature = { value = 24.4, unitCode = "wmoUnit:degC", qualityControl = "V" },
	dewpoint = { value = 10.0, qualityControl = "V" },
	windSpeed = { value = 11.16, unitCode = "wmoUnit:km_h-1", qualityControl = "V" },
	windDirection = { value = 180, qualityControl = "V" },
	barometricPressure = { value = 101690, unitCode = "wmoUnit:Pa", qualityControl = "V" },
	visibility = { value = 16090, unitCode = "wmoUnit:m", qualityControl = "C" },
	relativeHumidity = { value = 40.5, qualityControl = "V" },
	-- The six nulls, exactly as measured live:
	windGust = { value = nil, qualityControl = "Z" },
	seaLevelPressure = { value = nil, qualityControl = "Z" },
	maxTemperatureLast24Hours = { value = nil },
	minTemperatureLast24Hours = { value = nil },
	precipitationLast3Hours = { value = nil, qualityControl = "Z" },
	windChill = { value = nil, qualityControl = "Z" },
	heatIndex = { value = nil, qualityControl = "V" },
	cloudLayers = { { base = { value = nil }, amount = "CLR" } },
	presentWeather = {},
})
check("observation parses", obs ~= nil)
check("observation tempC", obs ~= nil and near(obs.tempC, 24.4))
check("observation tempF derived", obs ~= nil and near(obs.tempF, 75.92))
check("observation windMph from kmh", obs ~= nil and near(obs.windMph, 6.93, 0.05))
check("observation gust stays nil (never 0)", obs ~= nil and obs.gustMph == nil)
check("observation windChill stays nil", obs ~= nil and obs.windChillF == nil)
check("observation pressure inHg", obs ~= nil and near(obs.pressureInHg, 30.03, 0.02))
check("observation visibility miles", obs ~= nil and near(obs.visibilityMi, 10, 0.01))
check("observation compass", obs ~= nil and obs.windCompass == "S")
check("observation cloud cover 0", obs ~= nil and obs.cloudCover == 0)
check("observation feels-like falls back to temp", obs ~= nil and near(obs.feelsLikeF, obs.tempF))
check("observation no timestamp is nil", normalize.observation({ textDescription = "Clear" }) == nil)
check("observation non-table is nil", normalize.observation("garbage") == nil)

local hotObs = normalize.observation({
	timestamp = "2026-08-31T14:52:00+00:00",
	temperature = { value = 35 },
	heatIndex = { value = 41 },
})
check("observation feels-like prefers heat index", hotObs ~= nil and near(hotObs.feelsLikeC, 41))

-- ─── normalize: forecast periods ──────────────────────────────────────────────

local period = normalize.period({
	number = 1,
	name = "Today",
	startTime = "2026-08-31T06:00:00-04:00",
	endTime = "2026-08-31T18:00:00-04:00",
	isDaytime = true,
	temperature = 90,
	temperatureUnit = "F",
	probabilityOfPrecipitation = { value = 40 },
	dewpoint = { value = 18.3, unitCode = "wmoUnit:degC" },
	relativeHumidity = { value = 65 },
	windSpeed = "5 to 10 mph",
	windDirection = "SW",
	shortForecast = "Chance Showers And Thunderstorms",
	detailedForecast = "A chance of showers and thunderstorms after noon.",
})
check("period parses", period ~= nil)
check("period tempF bare number", period ~= nil and period.tempF == 90)
check("period tempC derived", period ~= nil and near(period.tempC, 32.22, 0.01))
check("period pop", period ~= nil and period.pop == 40)
check("period wind range", period ~= nil and period.windMphLo == 5 and period.windMphHi == 10)
check("period thunder flag", period ~= nil and period.flags.thunder == true)
check("period null pop stays nil", normalize.period({
	startTime = "2026-08-31T06:00:00-04:00",
	endTime = "2026-08-31T18:00:00-04:00",
	probabilityOfPrecipitation = { value = nil },
}).pop == nil)
check(
	"period celsius unit honored",
	near(
		normalize.period({
			startTime = "2026-08-31T06:00:00-04:00",
			endTime = "2026-08-31T18:00:00-04:00",
			temperature = 30,
			temperatureUnit = "C",
		}).tempF,
		86
	)
)
check("periods drops garbage entries", #normalize.periods({
	{ startTime = "bad" },
	{
		startTime = "2026-08-31T06:00:00-04:00",
		endTime = "2026-08-31T18:00:00-04:00",
	},
}) == 1)
check("periods non-table is empty", #normalize.periods(nil) == 0)

-- ─── normalize: grid layers + points ──────────────────────────────────────────

local layer = normalize.gridLayer({
	uom = "wmoUnit:percent",
	values = {
		{ validTime = "2026-08-31T00:00:00+00:00/PT6H", value = 20 },
		{ validTime = "2026-08-31T06:00:00+00:00/PT1H", value = nil },
		{ validTime = "garbage", value = 50 },
	},
})
check("gridLayer expands valid entries only", #layer == 1)
check("gridLayer duration", layer[1] ~= nil and layer[1].duration == 21600)

local pts = normalize.points({
	gridId = "LWX",
	gridX = 97,
	gridY = 71,
	forecast = "https://api.weather.gov/gridpoints/LWX/97,71/forecast",
	forecastHourly = "https://api.weather.gov/gridpoints/LWX/97,71/forecast/hourly",
	forecastGridData = "https://api.weather.gov/gridpoints/LWX/97,71",
	observationStations = "https://api.weather.gov/gridpoints/LWX/97,71/stations",
	forecastZone = "https://api.weather.gov/zones/forecast/DCZ001",
	county = "https://api.weather.gov/zones/county/DCC001",
	fireWeatherZone = "https://api.weather.gov/zones/fire/DCZ001",
	timeZone = "America/New_York",
	radarStation = "KLWX",
})
check("points parses", pts ~= nil)
check("points office", pts ~= nil and pts.office == "LWX")
check("points zone id extracted", pts ~= nil and pts.forecastZone == "DCZ001")
check("points county id extracted", pts ~= nil and pts.county == "DCC001")
check("points radar station", pts ~= nil and pts.radarStation == "KLWX")
check("points missing grid is nil", normalize.points({ forecast = "x" }) == nil)

-- ─── solar ────────────────────────────────────────────────────────────────────

-- Washington DC, 2026-03-20 (equinox): day length ~12h08m, sunrise mid-morning UTC.
local equinoxNoonUtc = 1767225600 + 78 * 86400 + 43200
local dc = solar.sunTimes(38.8895, -77.0353, equinoxNoonUtc)
check("solar equinox parses", dc ~= nil)
if dc ~= nil then
	local dayLen = (dc.sunset - dc.sunrise) / 3600
	check("solar equinox day length ~12h", dayLen > 11.9 and dayLen < 12.4, string.format("%.2f h", dayLen))
	check("solar ordering", dc.sunrise < dc.solarNoon and dc.solarNoon < dc.sunset)
	check(
		"solar equinox sunrise plausible (10-12 UTC)",
		dc.sunrise % 86400 > 10 * 3600 and dc.sunrise % 86400 < 12 * 3600
	)
end

-- Midsummer above the arctic circle: no sunrise/sunset.
local juneNoon = 1767225600 + 171 * 86400 + 43200
check("solar polar midnight sun is nil", solar.sunTimes(69.65, 18.96, juneNoon) == nil)
check("solar nil-safe", solar.sunTimes(nil, -77, equinoxNoonUtc) == nil)

local stateAtNoonLocal = solar.solarState(38.8895, -77.0353, equinoxNoonUtc + 5 * 3600, -4 * 3600)
check("solarState daytime at local afternoon", stateAtNoonLocal ~= nil and stateAtNoonLocal.isDaytime == true)
local stateAtMidnight = solar.solarState(38.8895, -77.0353, equinoxNoonUtc - 8 * 3600, -4 * 3600)
check("solarState night before dawn", stateAtMidnight ~= nil and stateAtMidnight.isDaytime == false)
check(
	"solarState minutesToSunrise positive at night",
	stateAtMidnight ~= nil and (stateAtMidnight.minutesToSunrise or -1) > 0
)
if stateAtNoonLocal ~= nil then
	check(
		"solarState next sunrise is tomorrow after dawn",
		stateAtNoonLocal.nextSunrise ~= nil and stateAtNoonLocal.nextSunrise > stateAtNoonLocal.sunrise
	)
end

-- ─── result ───────────────────────────────────────────────────────────────────

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
	os.exit(1)
end
