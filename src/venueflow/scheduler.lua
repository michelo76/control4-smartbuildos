--- VenueFlow: schedules (pure).
---
--- Schedules run on the CONTROLLER'S LOCAL TIME, which is the venue's time
--- zone as set in Composer (Project Settings > Time Zone). The driver reads
--- wall-clock fields through an injected localtime(), the same source the
--- repository's Daypart driver was watched using on a bench controller.
---
--- Each tick compares "now" with the previous tick, in local wall time:
---   * a schedule whose time lies in (previous, now] fires, once;
---   * what was fired is remembered per rule as "YYYY-MM-DD HH:MM", so the
---     repeated hour when clocks go BACK cannot fire a schedule twice;
---   * when clocks go FORWARD the skipped hour lies inside (previous, now],
---     so its schedules fire once, right after the jump, instead of never;
---   * a long gap in REAL time (driver stopped, controller off) is not caught
---     up: opening a venue's AV three hours late is worse than not at all.
---     Those schedules are reported as missed.

local U = require("venueflow.util")

local M = {}

M.TICK_SECONDS = 20
M.CATCH_UP_SECONDS = 300

local Scheduler = {}
Scheduler.__index = Scheduler

--- deps = { now(), localtime(epoch) -> {year, month, day, hour, min, wday}, rules() -> list,
---          fire(rule, stamp), missed(rule, stamp), lastFired = {} (persisted table), save() }
function M.new(deps)
  local self = setmetatable({}, Scheduler)
  self.deps = deps
  self.lastFired = deps.lastFired or {}
  self.prev = nil -- { epoch, date, minute }
  return self
end

local function moment(deps, epoch)
  local lt = deps.localtime(epoch)
  return {
    epoch = epoch,
    date = string.format("%04d-%02d-%02d", lt.year, lt.month, lt.day),
    minute = lt.hour * 60 + lt.min,
    weekday = U.isoWeekday(lt.wday),
  }
end
M.moment = moment

--- Rules due between two local moments on the same date: time in (from, to].
local function dueBetween(rules, fromMinute, toMinute, weekday)
  local out = {}
  for _, rule in ipairs(rules) do
    local trigger = rule.trigger
    if rule.enabled ~= false and type(trigger) == "table" and trigger.type == "schedule" then
      local at = U.parseTime(trigger.time)
      if at ~= nil and at > fromMinute and at <= toMinute and U.contains(U.list(trigger.days), weekday) then
        out[#out + 1] = { rule = rule, at = at }
      end
    end
  end
  table.sort(out, function(a, b)
    if a.at ~= b.at then
      return a.at < b.at
    end
    return tostring(a.rule.id) < tostring(b.rule.id)
  end)
  return out
end

function Scheduler:tick()
  local deps = self.deps
  local now = moment(deps, deps.now())
  local prev = self.prev
  self.prev = now
  if prev == nil then
    return 0
  end
  local elapsed = now.epoch - prev.epoch
  if elapsed < 0 then
    return 0 -- the clock was set back by hand: wait for it to pass again
  end
  local windows = {}
  if now.date == prev.date then
    if now.minute < prev.minute then
      return 0 -- clocks went back: this stretch of wall time already ran
    end
    windows[1] = { date = now.date, weekday = now.weekday, from = prev.minute, to = now.minute }
  else
    -- Midnight passed between two ticks.
    windows[1] = { date = prev.date, weekday = prev.weekday, from = prev.minute, to = 24 * 60 }
    windows[2] = { date = now.date, weekday = now.weekday, from = -1, to = now.minute }
  end
  local tooLate = elapsed > M.CATCH_UP_SECONDS
  local fired = 0
  local rules = deps.rules()
  for _, w in ipairs(windows) do
    for _, due in ipairs(dueBetween(rules, w.from, w.to, w.weekday)) do
      local stamp = w.date .. " " .. U.formatTime(due.at)
      if self.lastFired[due.rule.id] ~= stamp then
        self.lastFired[due.rule.id] = stamp
        if tooLate then
          pcall(deps.missed, due.rule, stamp)
        else
          fired = fired + 1
          pcall(deps.fire, due.rule, stamp)
        end
      end
    end
  end
  if fired > 0 or tooLate then
    pcall(deps.save)
  end
  return fired
end

--- The next time each schedule runs, for the Studio ("Next: Fri 16:00").
function Scheduler:upcoming(limit)
  local deps = self.deps
  local now = moment(deps, deps.now())
  local out = {}
  for _, rule in ipairs(deps.rules()) do
    local trigger = rule.trigger
    if rule.enabled ~= false and type(trigger) == "table" and trigger.type == "schedule" then
      local at = U.parseTime(trigger.time)
      if at ~= nil and U.isList(trigger.days) then
        for offset = 0, 7 do
          local weekday = ((now.weekday - 1 + offset) % 7) + 1
          if U.contains(trigger.days, weekday) and (offset > 0 or at > now.minute) then
            out[#out + 1] = {
              ruleId = rule.id,
              name = rule.name,
              inDays = offset,
              weekday = weekday,
              time = trigger.time,
            }
            break
          end
        end
      end
    end
  end
  table.sort(out, function(a, b)
    if a.inDays ~= b.inDays then
      return a.inDays < b.inDays
    end
    return a.time < b.time
  end)
  while limit and #out > limit do
    table.remove(out)
  end
  return out
end

return M
