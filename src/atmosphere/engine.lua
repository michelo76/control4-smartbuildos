--[[==========================================================================
  Atmosphere — the intelligence engine

  The one place raw inputs become automation truth. Pure and deterministic:

      engine.step(prev, inputs) -> snapshot, events

  prev      previous snapshot (nil on first run; persisted across restarts)
  inputs    { obs, hourly, alertsResult, thresholds, now, localOffset,
              obsFetchedAt, forecastFetchedAt, alertsFetchedAt, apiOk,
              simulation }

  Events fire on MEANINGFUL TRANSITIONS only. First sight is baseline
  (bond-weather rule): a restart with rain already falling announces
  nothing — but because snapshots persist, a real transition across a
  restart still fires. Simulation runs through this exact function; the
  snapshot just carries simulation=true so no consumer can confuse it.
============================================================================]]

local thresholds = require("atmosphere.thresholds")
local predict = require("atmosphere.predict")
local wstate = require("atmosphere.state")
local walerts = require("atmosphere.alerts")

local M = {}

--- Composer events: { id, name, description }. IDS ARE FROZEN FOREVER once
--- shipped (Composer programming binds them). Append only.
M.EVENTS = {
	{ 1, "Rain Started", "Rain began at the property." },
	{ 2, "Rain Stopped", "Rain ended at the property." },
	{ 3, "Rain Expected Soon", "Rain is expected within the configured lookahead." },
	{ 4, "Rain Expected Within 1 Hour", "Hourly forecast shows rain within 1 hour." },
	{ 5, "Rain Expected Within 3 Hours", "Hourly forecast shows rain within 3 hours." },
	{ 6, "Heavy Rain Expected", "High rain probability within the lookahead." },
	{ 7, "Snow Started", "Snow began at the property." },
	{ 8, "Snow Stopped", "Snow ended at the property." },
	{ 9, "Snow Expected", "Snow appears in the forecast lookahead." },
	{ 10, "High Wind Started", "Sustained wind crossed the high-wind threshold." },
	{ 11, "High Wind Ended", "Sustained wind fell below the high-wind exit threshold." },
	{ 12, "Dangerous Wind Started", "Sustained wind crossed the dangerous-wind threshold." },
	{ 13, "Dangerous Wind Ended", "Sustained wind fell below the dangerous-wind exit threshold." },
	{ 14, "High Gust Detected", "A wind gust crossed the gust threshold." },
	{ 15, "High Wind Expected", "High wind appears in the forecast lookahead." },
	{ 16, "Freeze Conditions Started", "Temperature at or below the freeze threshold." },
	{ 17, "Freeze Conditions Ended", "Temperature recovered above the freeze exit threshold." },
	{ 18, "Freeze Expected", "Freezing temperatures expected tonight." },
	{ 19, "Extreme Heat Started", "Feels-like crossed the extreme-heat threshold." },
	{ 20, "Extreme Heat Ended", "Feels-like recovered below the extreme-heat exit threshold." },
	{ 21, "Extreme Heat Expected", "Extreme heat expected within 24 hours." },
	{ 22, "Thunderstorm Started", "A thunderstorm is occurring at the property." },
	{ 23, "Thunderstorm Ended", "The thunderstorm ended." },
	{ 24, "Thunderstorm Expected", "Thunderstorms appear in the forecast lookahead." },
	{ 25, "Severe Weather Detected", "Severity reached WARNING or EMERGENCY." },
	{ 26, "Severe Weather Ended", "Severity returned below WARNING." },
	{ 27, "New Weather Advisory", "A weather advisory was issued for this location." },
	{ 28, "New Weather Watch", "A weather watch was issued for this location." },
	{ 29, "New Weather Warning", "A weather warning was issued for this location." },
	{ 30, "Alert Escalated", "An active alert escalated in level or severity." },
	{ 31, "Alert Cleared", "An active alert was cleared or expired." },
	{ 32, "Tornado Watch", "A tornado watch is in effect." },
	{ 33, "Tornado Warning", "A TORNADO WARNING is in effect." },
	{ 34, "Severe Thunderstorm Watch", "A severe thunderstorm watch is in effect." },
	{ 35, "Severe Thunderstorm Warning", "A severe thunderstorm warning is in effect." },
	{ 36, "Flood Watch", "A flood watch is in effect." },
	{ 37, "Flood Warning", "A flood warning is in effect." },
	{ 38, "Flash Flood Warning", "A FLASH FLOOD WARNING is in effect." },
	{ 39, "Hurricane Watch", "A hurricane watch is in effect." },
	{ 40, "Hurricane Warning", "A HURRICANE WARNING is in effect." },
	{ 41, "Tropical Storm Watch", "A tropical storm watch is in effect." },
	{ 42, "Tropical Storm Warning", "A tropical storm warning is in effect." },
	{ 43, "Winter Storm Watch", "A winter storm watch is in effect." },
	{ 44, "Winter Storm Warning", "A winter storm warning is in effect." },
	{ 45, "Freeze Warning", "A freeze/frost warning is in effect." },
	{ 46, "Extreme Heat Warning", "An extreme heat warning is in effect." },
	{ 47, "High Wind Warning", "A high wind warning is in effect." },
	{ 48, "Weather Data Stale", "Weather data exceeded its freshness threshold." },
	{ 49, "Weather Data Restored", "Fresh weather data is flowing again." },
	{ 50, "Weather API Unavailable", "The weather service stopped answering." },
	{ 51, "Weather API Recovered", "The weather service recovered." },
	{ 52, "Fog Started", "Fog/low visibility set in." },
	{ 53, "Fog Cleared", "Fog/low visibility cleared." },
	{ 54, "Ice Conditions Started", "Freezing precipitation / ice conditions began." },
	{ 55, "Ice Conditions Ended", "Ice conditions ended." },
	{ 56, "Rain Expected Within 6 Hours", "Hourly forecast shows rain within 6 hours." },
	{ 57, "Simulation Started", "Simulation mode engaged — events are simulated." },
	{ 58, "Simulation Ended", "Simulation mode ended — live data resumed." },
}

--- (class, level) -> specific alert event name. Everything else falls back
--- to the generic New Weather Advisory/Watch/Warning by level.
local SPECIFIC_ALERT_EVENTS = {
	TORNADO = { WATCH = "Tornado Watch", WARNING = "Tornado Warning" },
	SEVERE_THUNDERSTORM = { WATCH = "Severe Thunderstorm Watch", WARNING = "Severe Thunderstorm Warning" },
	FLOOD = { WATCH = "Flood Watch", WARNING = "Flood Warning" },
	FLASH_FLOOD = { WATCH = "Flood Watch", WARNING = "Flash Flood Warning" },
	HURRICANE = { WATCH = "Hurricane Watch", WARNING = "Hurricane Warning" },
	TROPICAL_STORM = { WATCH = "Tropical Storm Watch", WARNING = "Tropical Storm Warning" },
	WINTER = { WATCH = "Winter Storm Watch", WARNING = "Winter Storm Warning" },
	FREEZE = { WARNING = "Freeze Warning" },
	EXTREME_HEAT = { WARNING = "Extreme Heat Warning" },
	HIGH_WIND = { WARNING = "High Wind Warning" },
}

--- Boolean-flag transition events: key -> { asserted, cleared }. A `false`
--- in place of a name means the transition is silent in that direction.
local FLAG_EVENTS = {
	is_raining = { "Rain Started", "Rain Stopped" },
	is_snowing = { "Snow Started", "Snow Stopped" },
	is_storming = { "Thunderstorm Started", "Thunderstorm Ended" },
	is_foggy = { "Fog Started", "Fog Cleared" },
	is_icy = { "Ice Conditions Started", "Ice Conditions Ended" },
	is_freezing = { "Freeze Conditions Started", "Freeze Conditions Ended" },
	is_extreme_heat = { "Extreme Heat Started", "Extreme Heat Ended" },
	is_high_wind = { "High Wind Started", "High Wind Ended" },
	is_dangerous_wind = { "Dangerous Wind Started", "Dangerous Wind Ended" },
	is_high_gust = { "High Gust Detected", false },
}

local PREDICT_EVENTS = {
	rain_soon = "Rain Expected Soon",
	rain_expected_1h = "Rain Expected Within 1 Hour",
	rain_expected_3h = "Rain Expected Within 3 Hours",
	rain_expected_6h = "Rain Expected Within 6 Hours",
	heavy_rain_expected = "Heavy Rain Expected",
	storm_expected = "Thunderstorm Expected",
	snow_expected = "Snow Expected",
	high_wind_expected = "High Wind Expected",
	freeze_expected_tonight = "Freeze Expected",
	extreme_heat_expected = "Extreme Heat Expected",
}

--- Compares booleans with first-sight-is-baseline; appends transition events.
local function diffFlags(prevFlags, nextFlags, eventMap, events)
	for key, pair in pairs(eventMap) do
		local prev = prevFlags and prevFlags[key]
		local next_ = nextFlags[key] == true
		if prev ~= nil and prev ~= next_ then
			local name = next_ and pair[1] or pair[2]
			if type(name) == "string" then
				events[#events + 1] = name
			end
		end
	end
end

function M.step(prev, inputs)
	local now = inputs.now
	local t = inputs.thresholds
	local events = {}

	-- Threshold + observed booleans.
	local prevStates = prev ~= nil and prev.states or nil
	local nextStates = thresholds.evaluate(prevStates, inputs.obs, t)

	-- Staleness (per component, minutes -> seconds).
	local function staleAfter(fetchedAt, minutes)
		if fetchedAt == nil then
			return true
		end
		return (now - fetchedAt) > minutes * 60
	end
	local obsStale = staleAfter(inputs.obsFetchedAt, t.stale_observation_minutes)
	local forecastStale = staleAfter(inputs.forecastFetchedAt, t.stale_forecast_minutes)
	local alertsStale = staleAfter(inputs.alertsFetchedAt, t.stale_alerts_minutes)
	local dataStale = obsStale or alertsStale

	-- Alerts (already reconciled by the caller so poll cadence is decoupled).
	local ar = inputs.alertsResult
		or {
			active = prev ~= nil and prev.active or {},
			new = {},
			updated = {},
			canceled = {},
			expired = {},
			escalated = {},
		}
	local active = ar.active or {}

	-- Predictions. Stale forecast -> hourly treated as absent (fabrication
	-- guard); alert-driven flags still work.
	local hourly = (not forecastStale) and inputs.hourly or {}
	local predictions = predict.evaluate(hourly, active, t, now, inputs.localOffset)

	-- Mode + severity.
	local mode = wstate.mode(inputs.obs, nextStates, active)
	local severity = wstate.severity(nextStates, active)

	local snapshot = {
		obs = inputs.obs,
		states = nextStates,
		predictions = predictions,
		active = active,
		mode = mode,
		severity = severity,
		obsStale = obsStale,
		forecastStale = forecastStale,
		alertsStale = alertsStale,
		dataStale = dataStale,
		apiOk = inputs.apiOk ~= false,
		simulation = inputs.simulation == true,
		now = now,
		highestAlertSeverity = walerts.highestSeverity(active),
		topAlert = walerts.mostImportant(active),
		activeAlertCount = (function()
			local n = 0
			for _ in pairs(active) do
				n = n + 1
			end
			return n
		end)(),
	}

	-- ── Transition events ──────────────────────────────────────────────────
	diffFlags(prev ~= nil and prev.states or nil, nextStates, FLAG_EVENTS, events)

	local prevPred = prev ~= nil and prev.predictions or nil
	for key, name in pairs(PREDICT_EVENTS) do
		local was = prevPred and prevPred[key]
		if was ~= nil and was == false and predictions[key] == true then
			events[#events + 1] = name
		end
	end

	-- Alert events (new + escalations + clears). Weather automation is always
	-- on (retired toggle, 2026-08-31): events are the product.
	do
		for _, a in ipairs(ar.new or {}) do
			local specific = SPECIFIC_ALERT_EVENTS[a.class]
			local name = specific ~= nil and specific[a.levelName] or nil
			if name ~= nil then
				events[#events + 1] = name
			end
			if a.levelName == "WARNING" then
				events[#events + 1] = "New Weather Warning"
			elseif a.levelName == "WATCH" then
				events[#events + 1] = "New Weather Watch"
			elseif a.levelName == "ADVISORY" then
				events[#events + 1] = "New Weather Advisory"
			end
		end
		for _ in ipairs(ar.escalated or {}) do
			events[#events + 1] = "Alert Escalated"
		end
		if (#(ar.canceled or {}) + #(ar.expired or {})) > 0 then
			events[#events + 1] = "Alert Cleared"
		end
	end

	-- Severity transitions.
	local sevRank = { NORMAL = 0, INFORMATIONAL = 1, ADVISORY = 2, WATCH = 3, WARNING = 4, EMERGENCY = 5 }
	if prev ~= nil then
		local wasSevere = sevRank[prev.severity or "NORMAL"] >= 4
		local isSevere = sevRank[severity] >= 4
		if isSevere and not wasSevere then
			events[#events + 1] = "Severe Weather Detected"
		elseif wasSevere and not isSevere then
			events[#events + 1] = "Severe Weather Ended"
		end
	end

	-- Data-health transitions (always fire — they ARE the health signal).
	if prev ~= nil then
		if dataStale and not prev.dataStale then
			events[#events + 1] = "Weather Data Stale"
		elseif not dataStale and prev.dataStale then
			events[#events + 1] = "Weather Data Restored"
		end
		if prev.apiOk and not snapshot.apiOk then
			events[#events + 1] = "Weather API Unavailable"
		elseif not prev.apiOk and snapshot.apiOk then
			events[#events + 1] = "Weather API Recovered"
		end
		if snapshot.simulation and not prev.simulation then
			events[#events + 1] = "Simulation Started"
		elseif not snapshot.simulation and prev.simulation then
			events[#events + 1] = "Simulation Ended"
		end
	end

	return snapshot, events
end

return M
