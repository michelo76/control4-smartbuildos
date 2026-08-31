--[[==========================================================================
  Atmosphere — versioned settings (validate, migrate, apply)

  One settings document, one schema version, one validator — shared by the
  WebView settings app, Composer actions, and SmartBuildOS remote settings.
  Invalid input is refused field-by-field with reasons (never silently
  applied, never all-or-nothing: a typo in one field must not discard nine
  good ones — each refusal is reported).

  Migrations: MIGRATIONS[n] upgrades version n -> n+1. Renaming or adding a
  field NEVER loses installed settings (spec).
============================================================================]]

local thresholds = require("atmosphere.thresholds")
local walerts = require("atmosphere.alerts")

local M = {}

M.VERSION = 1

local UNIT_CHOICES = {
	temperature = { F = true, C = true },
	wind = { MPH = true, KMH = true, KNOTS = true },
	pressure = { INHG = true, HPA = true },
	precipitation = { IN = true, MM = true },
	distance = { MI = true, KM = true },
}

local THEME_CHOICES = { AUTOMATIC = true, LIGHT = true, DARK = true, OLED = true, CONTROL4 = true, AMBIENT = true }
local ANIMATION_CHOICES = { OFF = true, SUBTLE = true, NORMAL = true, CINEMATIC = true }
local SENSITIVITY_CHOICES = {
	OFF = true,
	WARNINGS_ONLY = true,
	WATCHES_WARNINGS = true,
	ADVISORIES_WATCHES_WARNINGS = true,
	ALL = true,
}

M.ALERT_CLASSES = {
	"TORNADO",
	"SEVERE_THUNDERSTORM",
	"HURRICANE",
	"TROPICAL_STORM",
	"FLOOD",
	"FLASH_FLOOD",
	"WINTER",
	"FREEZE",
	"EXTREME_HEAT",
	"HIGH_WIND",
	"DENSE_FOG",
	"FIRE_WEATHER",
	"COASTAL",
	"AIR_QUALITY",
	"OTHER",
}

--- The default document. Every field the UI can edit exists here.
function M.defaults()
	local d = {
		version = M.VERSION,
		display_name = "",
		units = { temperature = "F", wind = "MPH", pressure = "INHG", precipitation = "IN", distance = "MI" },
		thresholds = {}, -- overrides only; effective set = thresholds.effective()
		alerts = { sensitivity = "ALL", classes = {} }, -- absent class = enabled
		automation = { enabled = true },
		radar = {
			default_view = "station", -- station | conus
			animate = true,
			overlay_alerts = true,
		},
		display = { theme = "AUTOMATIC", animation = "NORMAL", default_screen = "now" },
		notifications = { push_alerts = true },
		simulation = { timeout_minutes = 30 },
	}
	return d
end

local function isBool(v)
	return v == true or v == false
end

--- Validates a PARTIAL settings patch against the schema. Returns
--- (cleanPatch, refusals) — cleanPatch contains only accepted fields, each
--- refusal is { path, reason }. Unknown top-level keys are refused loudly.
function M.validate(patch)
	local clean = {}
	local refused = {}
	local function refuse(path, reason)
		refused[#refused + 1] = { path = path, reason = reason }
	end
	if type(patch) ~= "table" then
		return {}, { { path = "$", reason = "not a table" } }
	end

	for key, value in pairs(patch) do
		if key == "version" then
			-- ignored on input; the store stamps it
			local _ = value
		elseif key == "display_name" then
			if type(value) == "string" and #value <= 80 then
				clean.display_name = value
			else
				refuse("display_name", "string up to 80 chars")
			end
		elseif key == "units" and type(value) == "table" then
			clean.units = {}
			for uk, uv in pairs(value) do
				local choices = UNIT_CHOICES[uk]
				if choices ~= nil and choices[tostring(uv):upper()] then
					clean.units[uk] = tostring(uv):upper()
				else
					refuse("units." .. tostring(uk), "unknown unit")
				end
			end
		elseif key == "thresholds" and type(value) == "table" then
			local _, thrRefused = thresholds.effective(value)
			clean.thresholds = {}
			local badKeys = {}
			for _, r in ipairs(thrRefused) do
				badKeys[r.key] = true
				refuse("thresholds." .. tostring(r.key), r.reason)
			end
			for tk, tv in pairs(value) do
				if not badKeys[tk] then
					clean.thresholds[tk] = tonumber(tv)
				end
			end
		elseif key == "alerts" and type(value) == "table" then
			clean.alerts = {}
			if value.sensitivity ~= nil then
				local s = tostring(value.sensitivity):upper()
				if SENSITIVITY_CHOICES[s] then
					clean.alerts.sensitivity = s
				else
					refuse("alerts.sensitivity", "unknown mode")
				end
			end
			if type(value.classes) == "table" then
				clean.alerts.classes = {}
				local known = {}
				for _, c in ipairs(M.ALERT_CLASSES) do
					known[c] = true
				end
				for ck, cv in pairs(value.classes) do
					if known[tostring(ck):upper()] and isBool(cv) then
						clean.alerts.classes[tostring(ck):upper()] = cv
					else
						refuse("alerts.classes." .. tostring(ck), "unknown class or non-boolean")
					end
				end
			end
		elseif key == "automation" and type(value) == "table" then
			clean.automation = {}
			if value.enabled ~= nil then
				if isBool(value.enabled) then
					clean.automation.enabled = value.enabled
				else
					refuse("automation.enabled", "boolean required")
				end
			end
		elseif key == "radar" and type(value) == "table" then
			clean.radar = {}
			if value.default_view ~= nil then
				local v = tostring(value.default_view):lower()
				if v == "station" or v == "conus" then
					clean.radar.default_view = v
				else
					refuse("radar.default_view", "station or conus")
				end
			end
			for _, bk in ipairs({ "animate", "overlay_alerts" }) do
				if value[bk] ~= nil then
					if isBool(value[bk]) then
						clean.radar[bk] = value[bk]
					else
						refuse("radar." .. bk, "boolean required")
					end
				end
			end
		elseif key == "display" and type(value) == "table" then
			clean.display = {}
			if value.theme ~= nil then
				local v = tostring(value.theme):upper()
				if THEME_CHOICES[v] then
					clean.display.theme = v
				else
					refuse("display.theme", "unknown theme")
				end
			end
			if value.animation ~= nil then
				local v = tostring(value.animation):upper()
				if ANIMATION_CHOICES[v] then
					clean.display.animation = v
				else
					refuse("display.animation", "unknown animation level")
				end
			end
			if value.default_screen ~= nil then
				local v = tostring(value.default_screen):lower()
				local screens = {
					now = true,
					hourly = true,
					forecast = true,
					radar = true,
					alerts = true,
					details = true,
					settings = true,
				}
				if screens[v] then
					clean.display.default_screen = v
				else
					refuse("display.default_screen", "unknown screen")
				end
			end
		elseif key == "notifications" and type(value) == "table" then
			clean.notifications = {}
			if value.push_alerts ~= nil then
				if isBool(value.push_alerts) then
					clean.notifications.push_alerts = value.push_alerts
				else
					refuse("notifications.push_alerts", "boolean required")
				end
			end
		elseif key == "simulation" and type(value) == "table" then
			clean.simulation = {}
			if value.timeout_minutes ~= nil then
				local n = tonumber(value.timeout_minutes)
				if n ~= nil and n >= 1 and n <= 480 then
					clean.simulation.timeout_minutes = n
				else
					refuse("simulation.timeout_minutes", "1-480")
				end
			end
		else
			refuse(tostring(key), "unknown setting")
		end
	end
	return clean, refused
end

--- Deep-merges an accepted patch into a document (patch wins, tables merge
--- one level deep — the document is two levels max by construction).
function M.merge(doc, patch)
	local out = {}
	for k, v in pairs(doc) do
		out[k] = v
	end
	for k, v in pairs(patch) do
		if type(v) == "table" and type(out[k]) == "table" then
			local merged = {}
			for k2, v2 in pairs(out[k]) do
				merged[k2] = v2
			end
			for k2, v2 in pairs(v) do
				if type(v2) == "table" and type(merged[k2]) == "table" then
					local m2 = {}
					for k3, v3 in pairs(merged[k2]) do
						m2[k3] = v3
					end
					for k3, v3 in pairs(v2) do
						m2[k3] = v3
					end
					merged[k2] = m2
				else
					merged[k2] = v2
				end
			end
			out[k] = merged
		else
			out[k] = v
		end
	end
	out.version = M.VERSION
	return out
end

--- MIGRATIONS[n] upgrades a version-n document to n+1. None yet — the table
--- exists so the first schema change is a one-line addition, not a design.
M.MIGRATIONS = {}

--- Loads a stored document: migrates forward, fills missing fields from
--- defaults, stamps the current version. A document from the FUTURE (a
--- downgrade) keeps only fields the current schema understands.
function M.load(stored)
	local doc = M.defaults()
	if type(stored) ~= "table" then
		return doc
	end
	local v = tonumber(stored.version) or 1
	local work = stored
	while v < M.VERSION do
		local migrate = M.MIGRATIONS[v]
		if migrate == nil then
			break
		end
		work = migrate(work)
		v = v + 1
	end
	local clean = select(1, M.validate(work))
	return M.merge(doc, clean)
end

--- Settings for the alert admission filter (walerts.admitted shape).
function M.alertSettings(doc)
	return { sensitivity = doc.alerts.sensitivity, classes = doc.alerts.classes }
end

--- Effective thresholds for the engine.
function M.effectiveThresholds(doc)
	return select(1, thresholds.effective(doc.thresholds))
end

-- Referenced so the dependency is explicit: settings admission uses the same
-- class list the alert engine classifies into.
M._classify = walerts.classify

return M
