--- Mode scheduling (spec §31): fixed time + days-of-week + an optional
--- presence guard. Tick-driven and catch-up safe: the driver calls tick()
--- periodically with the last-checked epoch, and a schedule fires when its
--- occurrence falls inside (last, now] — a Director restart that straddles
--- 23:30 still fires Sleep once, and never twice.
---
--- Sunrise/sunset offsets are a documented V1 limitation (no confirmed
--- official API) and belong to the V2 backlog.
---
--- Schedule shape, stored on the mode:
---   mode.schedules = { { id, time = "HH:MM", days = {1..7, 1=Sunday},
---                        require_presence = modeId?, enabled }, ... }

local M = {}

--- Parse "HH:MM" → minutes past midnight, nil on garbage.
function M.parseTime(hhmm)
  local h, m = tostring(hhmm):match("^(%d%d?):(%d%d)$")
  if not h then
    return nil
  end
  h, m = tonumber(h), tonumber(m)
  if h > 23 or m > 59 then
    return nil
  end
  return h * 60 + m
end

--- Compute which schedules fire in the window (last, now].
--- @param cfg table config envelope
--- @param last number epoch of the previous tick (0 on first run: nothing
---        fires — a fresh install must not replay the whole day)
--- @param now number epoch
--- @param deps table {localtime = fn(epoch)->{year,month,day,hour,min,wday},
---                    activePresence = fn() -> modeId?}
--- @return table due { {mode_id, schedule_id}, ... }
function M.tick(cfg, last, now, deps)
  local due = {}
  if last == nil or last <= 0 or now <= last then
    return due
  end
  -- Cap the catch-up window at 24h + 1min so an ancient `last` (clock jump,
  -- long power-off) fires each schedule at most once.
  if now - last > 24 * 3600 + 60 then
    last = now - (24 * 3600 + 60)
  end

  for _, mode in pairs(cfg.modes or {}) do
    if mode.enabled ~= false then
      for _, sched in ipairs(mode.schedules or {}) do
        if sched.enabled ~= false then
          local minutes = M.parseTime(sched.time)
          if minutes then
            local fireAt = M._occurrenceIn(last, now, minutes, sched.days, deps.localtime)
            if fireAt then
              local guard = sched.require_presence
              if guard == nil or deps.activePresence() == guard then
                table.insert(due, { mode_id = mode.id, schedule_id = sched.id, fire_at = fireAt })
              end
            end
          end
        end
      end
    end
  end
  return due
end

--- Find the newest occurrence of (minutes-past-midnight on allowed days)
--- inside (last, now], or nil. Walks the at-most-two calendar days the
--- window can touch after capping.
function M._occurrenceIn(last, now, minutes, days, localtime)
  local allowed = nil
  if days and #days > 0 then
    allowed = {}
    for _, d in ipairs(days) do
      allowed[d] = true
    end
  end
  -- Candidate days: the day of `now` and the day before.
  for back = 0, 1 do
    local probeEpoch = now - back * 24 * 3600
    local lt = localtime(probeEpoch)
    -- Epoch of that day's occurrence: shift probeEpoch to the target time.
    local occurrence = probeEpoch - (lt.hour * 3600 + lt.min * 60 + (lt.sec or 0)) + minutes * 60
    if occurrence > last and occurrence <= now then
      local olt = localtime(occurrence)
      if allowed == nil or allowed[olt.wday] then
        return occurrence
      end
    end
  end
  return nil
end

return M
