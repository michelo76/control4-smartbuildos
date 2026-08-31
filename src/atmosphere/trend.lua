--[[==========================================================================
  Atmosphere — observation history + barometric trend

  The driver keeps a ring buffer of { t, tempF, pressureInHg } samples, one
  per observation poll, bounded by count AND age. This module owns the
  buffer discipline (append/prune/downsample) and the one derived fact:
  the 3-hour barometric pressure trend — the classic rising/falling/steady
  barometer read (>= 0.06 inHg over 3 h is a trend; NWS calls >= ~0.06/h a
  rapid change, so the driver's "falling rapidly" gate of 0.10/3h is
  conservative and is applied by the caller from the returned delta).

  Nil discipline: under 2 usable samples, or a span under 90 minutes, the
  trend is nil — "not enough evidence" is never "STEADY". Pure module.
============================================================================]]

local M = {}

M.MAX_ENTRIES = 300
M.MAX_AGE_SECONDS = 24 * 3600
M.WINDOW_SECONDS = 3 * 3600
M.MIN_SPAN_SECONDS = 90 * 60
M.TREND_DELTA_INHG = 0.06
M.RAPID_FALL_INHG = 0.10

--- Appends one sample and prunes: entries older than 24 h drop, and the
--- buffer never exceeds MAX_ENTRIES (oldest evicted first). Returns a NEW
--- list; the input is not mutated (persist-safe).
function M.append(samples, entry, now)
  now = tonumber(now)
  local out = {}
  for _, s in ipairs(samples or {}) do
    local t = type(s) == "table" and tonumber(s.t) or nil
    if t ~= nil and (now == nil or (now - t) <= M.MAX_AGE_SECONDS) then
      out[#out + 1] = s
    end
  end
  if type(entry) == "table" and tonumber(entry.t) ~= nil then
    out[#out + 1] = entry
  end
  while #out > M.MAX_ENTRIES do
    table.remove(out, 1)
  end
  return out
end

--- Evenly downsamples to at most maxPoints entries, always keeping the
--- first and last. Returns a new list.
function M.downsample(samples, maxPoints)
  samples = samples or {}
  maxPoints = tonumber(maxPoints) or #samples
  local n = #samples
  local out = {}
  if n <= maxPoints then
    for i = 1, n do
      out[i] = samples[i]
    end
    return out
  end
  if maxPoints < 2 then
    if maxPoints == 1 and n > 0 then
      out[1] = samples[n]
    end
    return out
  end
  for i = 1, maxPoints do
    local idx = math.floor((i - 1) * (n - 1) / (maxPoints - 1) + 0.5) + 1
    out[i] = samples[idx]
  end
  return out
end

--- 3-hour barometric trend from history samples.
--- Returns "RISING" | "FALLING" | "STEADY" plus the raw 3-h delta (inHg),
--- or nil when the window holds fewer than 2 pressure samples or spans
--- under 90 minutes (insufficient evidence, not steadiness).
function M.pressureTrend(samples, now)
  now = tonumber(now)
  if now == nil then
    return nil
  end
  local first, last = nil, nil
  local count = 0
  for _, s in ipairs(samples or {}) do
    local t = type(s) == "table" and tonumber(s.t) or nil
    local p = type(s) == "table" and tonumber(s.pressureInHg) or nil
    if t ~= nil and p ~= nil and t <= now and (now - t) <= M.WINDOW_SECONDS then
      count = count + 1
      if first == nil or t < first.t then
        first = { t = t, p = p }
      end
      if last == nil or t > last.t then
        last = { t = t, p = p }
      end
    end
  end
  if count < 2 or (last.t - first.t) < M.MIN_SPAN_SECONDS then
    return nil
  end
  local delta = last.p - first.p
  if delta >= M.TREND_DELTA_INHG then
    return "RISING", delta
  end
  if delta <= -M.TREND_DELTA_INHG then
    return "FALLING", delta
  end
  return "STEADY", delta
end

return M
