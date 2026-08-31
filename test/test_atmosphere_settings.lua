-- Tests for Atmosphere settings (validate/merge/load), the UI payload
-- builder, the polling scheduler, and simulation scenarios.
--
-- Invariants:
--   * Settings validation is field-by-field: one bad field never discards
--     nine good ones, and every refusal carries a path + reason.
--   * load() migrates + fills defaults; unknown/garbage input yields a
--     complete, usable document.
--   * uistate converts units driver-side and never leaks unknown fields as
--     zeros.
--   * scheduler backs off on failures and never polls alerts faster than
--     its healthy cadence.
--   * every advertised simulation scenario builds.
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

local settingsstore = require("atmosphere.settingsstore")
local uistate = require("atmosphere.uistate")
local scheduler = require("atmosphere.scheduler")
local simulator = require("atmosphere.simulator")

-- ─── settings validation ──────────────────────────────────────────────────────

local clean, refused = settingsstore.validate({
	units = { temperature = "c", wind = "WARP" },
	thresholds = { high_wind_enter_mph = 30, freeze_enter_f = -500 },
	alerts = { sensitivity = "WARNINGS_ONLY", classes = { TORNADO = false, BOGUS = true } },
	display = { theme = "OLED", animation = "sideways" },
	junk_key = 1,
})
check("valid unit accepted (case-folded)", clean.units.temperature == "C")
check("invalid unit refused", clean.units.wind == nil)
check("valid threshold accepted", clean.thresholds.high_wind_enter_mph == 30)
check("out-of-bounds threshold refused", clean.thresholds.freeze_enter_f == nil)
check("sensitivity accepted", clean.alerts.sensitivity == "WARNINGS_ONLY")
check("class toggle accepted", clean.alerts.classes.TORNADO == false)
check("unknown class refused", clean.alerts.classes.BOGUS == nil)
check("theme accepted", clean.display.theme == "OLED")
check("bad animation refused", clean.display.animation == nil)
check("refusals carry paths", #refused == 5, tostring(#refused))
check(
	"each refusal has path and reason",
	(function()
		for _, r in ipairs(refused) do
			if type(r.path) ~= "string" or type(r.reason) ~= "string" then
				return false
			end
		end
		return true
	end)()
)
check(
	"non-table patch refused whole",
	(function()
		local c, r = settingsstore.validate("garbage")
		return next(c) == nil and #r == 1
	end)()
)

-- merge keeps unrelated branches
local doc = settingsstore.merge(settingsstore.defaults(), clean)
check("merge applies patch", doc.units.temperature == "C")
check("merge keeps untouched defaults", doc.units.pressure == "INHG")
check("merge keeps default radar", doc.radar.default_view == "station")
check("merge stamps version", doc.version == settingsstore.VERSION)

-- load: garbage, partial, and future documents
check("load nil yields defaults", settingsstore.load(nil).units.temperature == "F")
check("load garbage yields defaults", settingsstore.load("junk").display.theme == "AUTOMATIC")
local restored = settingsstore.load({ version = 1, units = { temperature = "C" } })
check("load restores stored values", restored.units.temperature == "C")
check("load fills gaps from defaults", restored.alerts.sensitivity == "ALL")
local future = settingsstore.load({ version = 99, units = { temperature = "C" }, from_the_future = true })
check("future doc keeps known fields, drops unknown", future.units.temperature == "C" and future.from_the_future == nil)

check("alertSettings shape", settingsstore.alertSettings(doc).sensitivity == "WARNINGS_ONLY")
check("effectiveThresholds applies override", settingsstore.effectiveThresholds(doc).high_wind_enter_mph == 30)

-- ─── uistate ──────────────────────────────────────────────────────────────────

local snap = {
	mode = "RAIN",
	severity = "ADVISORY",
	simulation = false,
	dataStale = false,
	obsStale = false,
	forecastStale = false,
	alertsStale = false,
	apiOk = true,
	activeAlertCount = 1,
	obs = {
		tempF = 68,
		feelsLikeF = 66.2,
		dewpointF = 60,
		humidity = 77.4,
		windMph = 10,
		gustMph = nil,
		windCompass = "NE",
		windDeg = 45,
		pressureInHg = 29.92,
		visibilityMi = 5,
		cloudCover = 90,
		textDescription = "Rain",
		station = "KFLL",
		timestamp = 1767225600,
	},
	states = { is_raining = true },
	predictions = { rain_soon = true },
	active = {
		a1 = {
			id = "a1",
			event = "Flood Advisory",
			severity = "Minor",
			severityRank = 1,
			levelName = "ADVISORY",
			class = "FLOOD",
		},
		a2 = {
			id = "a2",
			event = "Flood Warning",
			severity = "Severe",
			severityRank = 3,
			levelName = "WARNING",
			class = "FLOOD",
		},
	},
}
local metricSettings = settingsstore.merge(settingsstore.defaults(), {
	units = { temperature = "C", wind = "KMH", pressure = "HPA", distance = "KM" },
})
local ui = uistate.build({
	snapshot = snap,
	daily = {},
	hourly = {},
	settings = metricSettings,
	solar = { isDaytime = true },
	location = { label = "Test", radar_station = "KAMX" },
	diagnostics = {},
	license = { status = "LEGACY" },
	now = 1767225600,
})
check("ui temp converted to C", ui.current.temp == 20)
check("ui wind converted to KMH", ui.current.wind == 16.1)
check("ui pressure converted to hPa", ui.current.pressure == 1013.2)
check("ui visibility converted to KM", ui.current.visibility == 8)
check("ui gust stays nil", ui.current.gust == nil)
check("ui alerts sorted severe-first", ui.alerts[1].id == "a2")
check("ui alert count", ui.alert_count == 1)
check("ui mode passthrough", ui.mode == "RAIN")
check("ui units block says what numbers are", ui.units.temperature == "C")

-- ─── scheduler ────────────────────────────────────────────────────────────────

check("healthy obs cadence", scheduler.nextDelay("observations", 0) == 300)
check("healthy alerts cadence", scheduler.nextDelay("alerts", 0) == 60)
check("first failure backs off 1m", scheduler.nextDelay("forecast", 1) == 60)
check("ladder climbs", scheduler.nextDelay("forecast", 3) == 300)
check("ladder clamps at top", scheduler.nextDelay("forecast", 99) == 900)
check("alerts backoff never faster than healthy", scheduler.nextDelay("alerts", 1) >= 60)
check("jitter deterministic", scheduler.jitter("abc", 30) == scheduler.jitter("abc", 30))
check("jitter within spread", scheduler.jitter("controller-7", 30) < 30)
check("jitter varies by seed", scheduler.jitter("a", 1000) ~= scheduler.jitter("b", 1000))

-- ─── simulator ────────────────────────────────────────────────────────────────

for _, name in ipairs(simulator.NAMES) do
	local built = simulator.build(name, 1767225600)
	check("scenario builds: " .. name, built ~= nil and (built.obs ~= nil or #(built.alerts or {}) > 0))
end
local tor = simulator.build("tornado_warning", 1767225600)
check(
	"simulated tornado is a real normalized alert",
	tor.alerts[1].class == "TORNADO" and tor.alerts[1].levelName == "WARNING"
)
check("simulated alerts marked simulated in text", tor.alerts[1].headline:find("SIMULATED", 1, true) ~= nil)
check("unknown scenario is nil", simulator.build("sharknado", 0) == nil)
check("scenario name normalization", simulator.build("Tornado Warning", 1767225600) ~= nil)

-- ─── result ───────────────────────────────────────────────────────────────────

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
	os.exit(1)
end
