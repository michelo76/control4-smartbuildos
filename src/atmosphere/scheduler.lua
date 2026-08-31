--[[==========================================================================
  Atmosphere — polling cadence + failure backoff (pure decisions)

  Responsible-citizen polling of a keyless public API (spec):
    observations 5 min · forecast 15 min · alerts 60 s ·
    /points only on location change + a slow 24 h re-check (the office/grid
    mapping for a fixed coordinate CAN change — official docs).

  Failure backoff ladder per endpoint class: 1 → 2 → 5 → 10 → 15 minutes,
  held at the top until recovery. Backoff keys on ANY failure — NWS docs do
  not promise a 429, only "an error… typically retryable within 5 seconds".
  Jitter spreads a fleet so thousands of controllers never align on the
  same second.
============================================================================]]

local M = {}

--- Base cadences in seconds.
M.CADENCE = {
	observations = 5 * 60,
	forecast = 15 * 60,
	alerts = 60,
	points = 24 * 60 * 60,
}

--- Backoff ladder in seconds (spec: 1, 2, 5, 10, 15 minutes).
M.BACKOFF = { 60, 120, 300, 600, 900 }

--- Next delay for an endpoint class given consecutive failures (0 = healthy).
--- Healthy -> cadence; failing -> ladder rung, clamped at the top. The alerts
--- floor is its own cadence — backoff never polls alerts FASTER than healthy.
function M.nextDelay(class, failures)
	local base = M.CADENCE[class] or 300
	failures = tonumber(failures) or 0
	if failures <= 0 then
		return base
	end
	local rung = M.BACKOFF[math.min(failures, #M.BACKOFF)]
	return math.max(rung, math.min(base, rung))
end

--- Deterministic per-site jitter in [0, spread) seconds, derived from a seed
--- string (controller identity) so it is stable across restarts but different
--- across the fleet.
function M.jitter(seed, spread)
	spread = tonumber(spread) or 30
	local hash = 5381
	for i = 1, #tostring(seed or "") do
		hash = (hash * 33 + tostring(seed):byte(i)) % 2147483647
	end
	return hash % spread
end

return M
