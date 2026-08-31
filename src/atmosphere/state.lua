--[[==========================================================================
  Atmosphere — weather mode + severity normalization

  One normalized WEATHER_MODE and WEATHER_SEVERITY from everything the
  engine knows. Modes are ordered by precedence: the most automation-relevant
  condition wins (a thunderstorm with fog is a THUNDERSTORM). UNKNOWN is an
  honest answer, never a default painted over missing data.
============================================================================]]

local M = {}

M.MODES = {
	"CLEAR",
	"PARTLY_CLOUDY",
	"CLOUDY",
	"FOG",
	"RAIN",
	"HEAVY_RAIN",
	"THUNDERSTORM",
	"SEVERE_STORM",
	"SNOW",
	"ICE",
	"HIGH_WIND",
	"FREEZE",
	"EXTREME_HEAT",
	"TROPICAL",
	"HURRICANE",
	"UNKNOWN",
}

M.SEVERITIES = { "NORMAL", "INFORMATIONAL", "ADVISORY", "WATCH", "WARNING", "EMERGENCY" }

--- Active-alert classes that force a mode regardless of observations.
local ALERT_MODE = {
	HURRICANE = "HURRICANE",
	TROPICAL_STORM = "TROPICAL",
}

--- Computes WEATHER_MODE.
--- obs: normalized observation or nil; states: threshold booleans;
--- active: active admitted alerts.
function M.mode(obs, states, active)
	states = states or {}
	-- Alert-forced modes first (a hurricane warning IS the weather).
	local severeStorm = false
	for _, a in pairs(active or {}) do
		local forced = ALERT_MODE[a.class]
		if forced ~= nil and a.levelName == "WARNING" then
			return forced
		end
		if a.class == "TORNADO" and a.levelName == "WARNING" then
			return "SEVERE_STORM"
		end
		if a.class == "SEVERE_THUNDERSTORM" and a.levelName == "WARNING" then
			severeStorm = true
		end
	end
	if obs == nil then
		return "UNKNOWN"
	end
	local f = obs.flags or {}
	if f.thunder then
		return severeStorm and "SEVERE_STORM" or "THUNDERSTORM"
	end
	if severeStorm and (f.rain or states.is_high_wind) then
		return "SEVERE_STORM"
	end
	if f.ice or (f.rain and states.is_freezing) then
		return "ICE"
	end
	if f.snow then
		return "SNOW"
	end
	if f.rain then
		if obs.pop ~= nil and obs.pop >= 70 or states.is_high_gust then
			return "HEAVY_RAIN"
		end
		return "RAIN"
	end
	if states.is_dangerous_wind or states.is_high_wind then
		return "HIGH_WIND"
	end
	if f.fog then
		return "FOG"
	end
	if states.is_extreme_heat then
		return "EXTREME_HEAT"
	end
	if states.is_freezing then
		return "FREEZE"
	end
	if obs.cloudCover ~= nil then
		if obs.cloudCover >= 70 then
			return "CLOUDY"
		elseif obs.cloudCover >= 30 then
			return "PARTLY_CLOUDY"
		end
		return "CLEAR"
	end
	if f.cloudy then
		return "CLOUDY"
	end
	if f.clear then
		return "CLEAR"
	end
	return "UNKNOWN"
end

--- Computes WEATHER_SEVERITY from the active admitted alert set plus local
--- conditions. EMERGENCY = Extreme warning (tornado/hurricane class);
--- WARNING/WATCH/ADVISORY track the highest active alert level;
--- INFORMATIONAL = notable local state with no alert (dangerous wind,
--- extreme heat); NORMAL otherwise.
function M.severity(states, active)
	states = states or {}
	local best = "NORMAL"
	local rank = { NORMAL = 0, INFORMATIONAL = 1, ADVISORY = 2, WATCH = 3, WARNING = 4, EMERGENCY = 5 }
	local function raise(v)
		if rank[v] > rank[best] then
			best = v
		end
	end
	for _, a in pairs(active or {}) do
		if a.levelName == "WARNING" then
			if (a.severityRank or 0) >= 4 then
				raise("EMERGENCY")
			else
				raise("WARNING")
			end
		elseif a.levelName == "WATCH" then
			raise("WATCH")
		elseif a.levelName == "ADVISORY" then
			raise("ADVISORY")
		else
			raise("INFORMATIONAL")
		end
	end
	if states.is_dangerous_wind or states.is_extreme_heat then
		raise("INFORMATIONAL")
	end
	return best
end

return M
