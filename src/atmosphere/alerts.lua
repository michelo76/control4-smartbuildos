--[[==========================================================================
  Atmosphere — NWS alert engine (normalization + lifecycle)

  CAP facts this module is built around (live-verified 2026-08-31):
    - `id` is the CAP URN — the dedupe key.
    - messageType Alert/Update/Cancel; an Update carries `references[]` to the
      alerts it supersedes and does NOT retire them for you.
    - `ends` = when the EVENT ends (may be null on long products);
      `expires` = when the MESSAGE goes stale. UI/state expiry keys on both:
      an alert is over at ends when present, else expires.
    - The event vocabulary is ~111 strings (live /alerts/types endpoint);
      unmapped ones still classify by severity — never dropped on the floor.

  reconcile() is the lifecycle heart: pure state machine, old set + fresh
  fetch in, new set + transition events out. Polling the same warning twice
  produces zero events (spec: never re-fire the same warning per poll).
============================================================================]]

local intervals = require("atmosphere.intervals")

local M = {}

M.SEVERITY_RANK = { Unknown = 0, Minor = 1, Moderate = 2, Severe = 3, Extreme = 4 }

--- Alert classes for filter settings. Every NWS event string maps to one.
local CLASS_PATTERNS = {
	{ "tornado", "TORNADO" },
	{ "severe thunderstorm", "SEVERE_THUNDERSTORM" },
	{ "hurricane", "HURRICANE" },
	{ "typhoon", "HURRICANE" },
	{ "tropical", "TROPICAL_STORM" },
	{ "storm surge", "COASTAL" },
	{ "flash flood", "FLASH_FLOOD" },
	{ "flood", "FLOOD" },
	{ "winter", "WINTER" },
	{ "blizzard", "WINTER" },
	{ "snow", "WINTER" },
	{ "ice storm", "WINTER" },
	{ "freezing", "WINTER" },
	{ "frost", "FREEZE" },
	{ "freeze", "FREEZE" },
	{ "cold", "FREEZE" },
	{ "wind chill", "FREEZE" },
	{ "heat", "EXTREME_HEAT" },
	{ "high wind", "HIGH_WIND" },
	{ "wind", "HIGH_WIND" },
	{ "gale", "HIGH_WIND" },
	{ "fog", "DENSE_FOG" },
	{ "smoke", "DENSE_FOG" },
	{ "fire", "FIRE_WEATHER" },
	{ "red flag", "FIRE_WEATHER" },
	{ "coastal", "COASTAL" },
	{ "beach", "COASTAL" },
	{ "surf", "COASTAL" },
	{ "rip current", "COASTAL" },
	{ "tsunami", "COASTAL" },
	{ "marine", "COASTAL" },
	{ "air quality", "AIR_QUALITY" },
	{ "air stagnation", "AIR_QUALITY" },
	{ "dust", "OTHER" },
}

--- Classifies an NWS event string ("Tornado Warning") into a filter class.
function M.classify(event)
	local e = tostring(event or ""):lower()
	for _, entry in ipairs(CLASS_PATTERNS) do
		if e:find(entry[1], 1, true) then
			return entry[2]
		end
	end
	return "OTHER"
end

--- Alert level from the event NAME suffix (the NWS convention), falling back
--- to CAP severity. Returns "WARNING" | "WATCH" | "ADVISORY" | "STATEMENT".
function M.level(event, severity)
	local e = tostring(event or ""):lower()
	if e:find("warning", 1, true) then
		return "WARNING"
	end
	if e:find("watch", 1, true) then
		return "WATCH"
	end
	if e:find("advisory", 1, true) then
		return "ADVISORY"
	end
	if e:find("statement", 1, true) or e:find("outlook", 1, true) or e:find("message", 1, true) then
		return "STATEMENT"
	end
	local rank = M.SEVERITY_RANK[tostring(severity or "")] or 0
	if rank >= 3 then
		return "WARNING"
	elseif rank == 2 then
		return "WATCH"
	end
	return "ADVISORY"
end

--- Normalizes one CAP feature's properties. Returns nil without an id.
function M.normalize(props)
	if type(props) ~= "table" or props.id == nil then
		return nil
	end
	local a = {
		id = tostring(props.id),
		event = tostring(props.event or "Unknown"),
		headline = props.headline ~= nil and tostring(props.headline) or nil,
		severity = tostring(props.severity or "Unknown"),
		certainty = tostring(props.certainty or "Unknown"),
		urgency = tostring(props.urgency or "Unknown"),
		status = tostring(props.status or "Actual"),
		messageType = tostring(props.messageType or "Alert"),
		effective = intervals.parseTimestamp(props.effective),
		onset = intervals.parseTimestamp(props.onset),
		expires = intervals.parseTimestamp(props.expires),
		ends = intervals.parseTimestamp(props.ends),
		sender = tostring(props.senderName or props.sender or ""),
		areaDesc = tostring(props.areaDesc or ""),
		description = props.description ~= nil and tostring(props.description) or nil,
		instruction = props.instruction ~= nil and tostring(props.instruction) or nil,
		response = props.response ~= nil and tostring(props.response) or nil,
		references = {},
	}
	if type(props.references) == "table" then
		for _, ref in ipairs(props.references) do
			local rid = type(ref) == "table" and (ref["@id"] or ref.identifier) or nil
			if rid ~= nil then
				a.references[#a.references + 1] = tostring(rid)
			end
		end
	end
	a.class = M.classify(a.event)
	a.levelName = M.level(a.event, a.severity)
	a.severityRank = M.SEVERITY_RANK[a.severity] or 0
	return a
end

--- Effective end time for state purposes: `ends` when present else `expires`.
function M.endsAt(a)
	return a.ends or a.expires
end

--- Sensitivity modes -> minimum level admitted.
local SENSITIVITY_ADMITS = {
	["OFF"] = {},
	["WARNINGS_ONLY"] = { WARNING = true },
	["WATCHES_WARNINGS"] = { WARNING = true, WATCH = true },
	["ADVISORIES_WATCHES_WARNINGS"] = { WARNING = true, WATCH = true, ADVISORY = true },
	["ALL"] = { WARNING = true, WATCH = true, ADVISORY = true, STATEMENT = true },
}

--- Whether settings admit this alert. settings = { sensitivity = mode,
--- classes = { TORNADO = false, ... } } — an absent class entry means ON
--- (fail-open: new alert categories are admitted until someone disables them).
function M.admitted(a, settings)
	settings = settings or {}
	-- Test/Exercise/Draft alerts never reach automation.
	if a.status ~= "Actual" then
		return false
	end
	local admits = SENSITIVITY_ADMITS[tostring(settings.sensitivity or "ALL")] or SENSITIVITY_ADMITS.ALL
	if admits[a.levelName] == nil then
		return false
	end
	local classes = settings.classes or {}
	if classes[a.class] == false then
		return false
	end
	return true
end

--- The lifecycle state machine.
---
--- previous: { [id] = alert } (the retained set)
--- fetched:  array of normalized alerts from the latest poll (nil = poll
---           failed — expiry still runs, nothing is marked canceled)
--- now:      epoch
---
--- Returns next set plus transitions:
---   { active = {[id]=alert}, new = {...}, updated = {...}, canceled = {...},
---     expired = {...}, escalated = {...} }
--- "escalated" = an update whose severityRank rose or level moved toward
--- WARNING (spec: Alert Escalated event).
local LEVEL_RANK = { STATEMENT = 0, ADVISORY = 1, WATCH = 2, WARNING = 3 }

function M.reconcile(previous, fetched, now)
	previous = previous or {}
	local result = {
		active = {},
		new = {},
		updated = {},
		canceled = {},
		expired = {},
		escalated = {},
		pollOk = fetched ~= nil,
	}

	local seen = {}
	local superseded = {}
	if fetched ~= nil then
		-- First pass: collect every id superseded by an Update/Cancel in this batch.
		for _, a in ipairs(fetched) do
			for _, ref in ipairs(a.references or {}) do
				superseded[ref] = true
			end
		end
		for _, a in ipairs(fetched) do
			if not superseded[a.id] then
				seen[a.id] = a
				local endT = M.endsAt(a)
				local over = endT ~= nil and endT <= now
				if a.messageType == "Cancel" then
					-- A Cancel names the event it kills via references (handled above);
					-- the Cancel product itself is not an active alert.
					superseded[a.id] = true
					seen[a.id] = nil
				elseif not over then
					result.active[a.id] = a
					local prev = previous[a.id]
					if prev == nil then
						-- Genuinely new, or an Update replacing a superseded predecessor.
						local replacesKnown = false
						for _, ref in ipairs(a.references or {}) do
							if previous[ref] ~= nil then
								replacesKnown = true
							end
						end
						if replacesKnown then
							result.updated[#result.updated + 1] = a
							for _, ref in ipairs(a.references or {}) do
								local old = previous[ref]
								if
									old ~= nil
									and (
										(a.severityRank or 0) > (old.severityRank or 0)
										or (LEVEL_RANK[a.levelName] or 0) > (LEVEL_RANK[old.levelName] or 0)
									)
								then
									result.escalated[#result.escalated + 1] = a
									break
								end
							end
						else
							result.new[#result.new + 1] = a
						end
					end
					-- Same id seen again: no event (dedupe by CAP id, the spec's rule).
				end
			end
		end
	end

	-- Second pass over the previous set: expiry and cancellation.
	for id, prev in pairs(previous) do
		if result.active[id] == nil then
			local endT = M.endsAt(prev)
			if superseded[id] then
				-- Replaced by an Update already accounted for above; drop silently.
				local _ = id
			elseif endT ~= nil and endT <= now then
				result.expired[#result.expired + 1] = prev
			elseif fetched ~= nil then
				-- The API answered and no longer lists it: canceled/cleared early.
				result.canceled[#result.canceled + 1] = prev
			else
				-- Poll failed: retain (spec: API failure must not fabricate "all
				-- clear"), unless the alert has aged out by its own clock above.
				result.active[id] = prev
			end
		end
	end

	return result
end

--- Highest severity name among active admitted alerts ("None" when empty).
function M.highestSeverity(active)
	local best, bestRank = "None", -1
	for _, a in pairs(active or {}) do
		if (a.severityRank or 0) > bestRank then
			bestRank = a.severityRank or 0
			best = a.severity
		end
	end
	return best
end

--- The most important active alert (highest severity, then most recent
--- effective time). nil when none.
function M.mostImportant(active)
	local best = nil
	for _, a in pairs(active or {}) do
		if
			best == nil
			or (a.severityRank or 0) > (best.severityRank or 0)
			or ((a.severityRank or 0) == (best.severityRank or 0) and (a.effective or 0) > (best.effective or 0))
		then
			best = a
		end
	end
	return best
end

return M
