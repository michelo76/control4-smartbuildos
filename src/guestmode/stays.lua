--- Guest Mode — the stay engine (pure, injected clock).
---
--- Turns calendar events into STAYS with wall-clock check-in and check-out
--- instants, and turns the passing of time into a small, honest state:
---
---   vacant          no guest, nothing due today
---   arriving_today  a stay checks in later today
---   occupied        a stay is in progress
---   departing_today the stay in progress checks out today
---   turnover        a stay checked out within the turnover window (or a
---                   same-day arrival follows) and nobody is in yet
---
--- Rules a host relies on:
---   • All-day bookings use the property's check-in / check-out TIMES; a
---     DTEND date is the check-out day (exclusive, as the platforms mean it).
---   • Timed bookings are taken as written; a Z time is converted to local
---     through the injected offset. A TZID is not interpreted (documented).
---   • Owner blocks ("Not available", "Blocked", …) are not guests. The
---     policy says whether they count as occupied or are ignored.
---   • Overlapping or back-to-back stays never produce a double check-in:
---     the engine tracks WHICH stay is current by uid; a new uid while
---     occupied is a check-out followed by a check-in at the same tick.
---   • Manual check-in creates an open-ended stay until manual check-out or
---     the next calendar stay; manual check-out ends the current calendar
---     stay at that instant (an early departure stays departed, and the
---     turnover follows as after any check-out).
---   • Transitions are computed only by comparing the previous state with
---     the new one, so a restart replays nothing: the persisted state is
---     restored and only genuine changes fire.

local Ical = require("guestmode.ical")

local M = {}

M.STATUSES = { vacant = true, arriving_today = true, occupied = true, departing_today = true, turnover = true }

local function hm(text, default)
  local h, m = tostring(text or ""):match("^%s*(%d%d?):(%d%d)%s*$")
  if h == nil then
    return default
  end
  h, m = tonumber(h), tonumber(m)
  if h > 23 or m > 59 then
    return default
  end
  return h * 60 + m
end
M.parseClock = hm

--- Default local-offset: seconds to ADD to a UTC wall-clock reading to get
--- the same instant expressed as local wall clock (so epoch = mktime(local)).
local function defaultUtcOffset(epoch)
  local lt = os.time(os.date("*t", epoch))
  local ut = os.time(os.date("!*t", epoch))
  return lt - ut
end

--- Epoch for a structured date at a given minute-of-day (for all-day).
local function toEpoch(d, minuteOfDay, deps)
  local mktime = deps.mktime or os.time
  if d.allDay then
    return mktime({
      year = d.y,
      month = d.m,
      day = d.d,
      hour = math.floor(minuteOfDay / 60),
      min = minuteOfDay % 60,
      sec = 0,
    })
  end
  local e = mktime({ year = d.y, month = d.m, day = d.d, hour = d.hh, min = d.mi, sec = d.ss })
  if d.utc then
    local off = (deps.utcOffset or defaultUtcOffset)(e)
    e = e + off
  end
  return e
end

--- @param events table from guestmode.ical (several feeds may be concatenated)
--- @param opts table { checkinMinutes, checkoutMinutes, blocksAre = "ignore"|"occupied", source = string }
--- @param deps table { mktime?, utcOffset? }
--- @return table stays sorted by start: { uid, name, start, finish, allDay, block, source, tzid }
function M.build(events, opts, deps)
  opts = opts or {}
  deps = deps or {}
  local ci = opts.checkinMinutes or 15 * 60
  local co = opts.checkoutMinutes or 11 * 60
  local stays = {}
  for _, ev in ipairs(events or {}) do
    if ev.start ~= nil and not ev.cancelled then
      local block = Ical.isBlock(ev.summary)
      if not block or opts.blocksAre == "occupied" then
        local start = toEpoch(ev.start, ci, deps)
        local finish
        if ev.finish ~= nil and ev.finish.duration ~= nil then
          if ev.start.allDay then
            -- Duration in whole days: check-out time on the last day.
            local days = math.max(1, math.floor(ev.finish.duration / 86400))
            local endDate = { y = ev.start.y, m = ev.start.m, d = ev.start.d + days, allDay = true }
            finish = toEpoch(endDate, co, deps)
          else
            finish = start + ev.finish.duration
          end
        elseif ev.finish ~= nil then
          finish = toEpoch(ev.finish, co, deps)
        else
          finish = start + 86400
        end
        if finish > start then
          stays[#stays + 1] = {
            uid = tostring(ev.uid or ""),
            name = block and "Blocked" or Ical.guestName(ev),
            start = start,
            finish = finish,
            allDay = ev.start.allDay == true,
            block = block,
            source = opts.source,
            tzid = ev.start.tzid,
          }
        end
      end
    end
  end
  table.sort(stays, function(a, b)
    if a.start == b.start then
      return a.uid < b.uid
    end
    return a.start < b.start
  end)
  return stays
end

local Engine = {}
Engine.__index = Engine

--- @param deps table { now = fun():number, date = fun(fmt, t):table|string (os.date), turnoverSeconds = number }
function M.new(deps)
  local self = setmetatable({}, Engine)
  self.deps = deps or {}
  self.stays = {}
  self.manual = nil -- { uid, name, start, finish = nil }
  self.cutoffs = {} -- uid -> epoch (manually checked out early: the stay ends there)
  self.lastCheckout = nil -- { uid, name, at }
  self.state = { status = "vacant", stayUid = nil, name = "" }
  self.turnoverSeconds = (deps and deps.turnoverSeconds) or 4 * 3600
  return self
end

function Engine:setStays(stays)
  self.stays = stays or {}
  -- A manual check-in ends when a calendar stay starts.
  if self.manual ~= nil and self.manual.finish == nil then
    for _, s in ipairs(self.stays) do
      if s.start > self.manual.start then
        self.manual.finish = s.start
        break
      end
    end
  end
end

--- Restores persisted state (status, stayUid, name, manual, hidden, lastCheckout).
function Engine:restore(doc)
  if type(doc) ~= "table" then
    return
  end
  if type(doc.state) == "table" and M.STATUSES[doc.state.status] then
    self.state = { status = doc.state.status, stayUid = doc.state.stayUid, name = doc.state.name or "" }
  end
  if type(doc.manual) == "table" and tonumber(doc.manual.start) then
    self.manual =
      { uid = tostring(doc.manual.uid), name = doc.manual.name, start = doc.manual.start, finish = doc.manual.finish }
  end
  self.cutoffs = {}
  for k, v in pairs(type(doc.cutoffs) == "table" and doc.cutoffs or {}) do
    if tonumber(v) then
      self.cutoffs[tostring(k)] = tonumber(v)
    end
  end
  if type(doc.lastCheckout) == "table" and tonumber(doc.lastCheckout.at) then
    self.lastCheckout = { uid = doc.lastCheckout.uid, name = doc.lastCheckout.name, at = doc.lastCheckout.at }
  end
end

function Engine:serialize()
  return { state = self.state, manual = self.manual, cutoffs = self.cutoffs, lastCheckout = self.lastCheckout }
end

local function sameLocalDay(deps, a, b)
  local date = deps.date or os.date
  return date("%Y-%m-%d", a) == date("%Y-%m-%d", b)
end

--- All stays the engine considers, calendar plus manual, hidden removed.
function Engine:_effective()
  local out = {}
  for _, s in ipairs(self.stays) do
    local cut = self.cutoffs[s.uid]
    if cut == nil then
      out[#out + 1] = s
    elseif cut > s.start then
      local copy = {}
      for k, v in pairs(s) do
        copy[k] = v
      end
      copy.finish = math.min(s.finish, cut)
      copy.cutShort = true
      out[#out + 1] = copy
    end
  end
  if self.manual ~= nil then
    out[#out + 1] = {
      uid = self.manual.uid,
      name = self.manual.name,
      start = self.manual.start,
      finish = self.manual.finish or math.huge,
      allDay = false,
      block = false,
      manual = true,
    }
  end
  table.sort(out, function(a, b)
    return a.start < b.start
  end)
  return out
end

--- The situation at `now`, without changing anything.
function Engine:evaluate(now)
  local current, nextStay, lastEnded = nil, nil, nil
  for _, s in ipairs(self:_effective()) do
    if now >= s.start and now < s.finish then
      if current == nil or s.manual then
        current = s
      end
    elseif s.start > now then
      if nextStay == nil or s.start < nextStay.start then
        nextStay = s
      end
    elseif s.finish <= now then
      if lastEnded == nil or s.finish > lastEnded.finish then
        lastEnded = s
      end
    end
  end
  local status
  if current ~= nil then
    status = (current.finish ~= math.huge and sameLocalDay(self.deps, now, current.finish)) and "departing_today"
      or "occupied"
  elseif nextStay ~= nil and sameLocalDay(self.deps, now, nextStay.start) then
    -- A same-day arrival after a check-out is a turnover first.
    if
      lastEnded ~= nil
      and sameLocalDay(self.deps, now, lastEnded.finish)
      and now - lastEnded.finish < self.turnoverSeconds
    then
      status = "turnover"
    else
      status = "arriving_today"
    end
  elseif lastEnded ~= nil and now - lastEnded.finish < self.turnoverSeconds then
    status = "turnover"
  else
    status = "vacant"
  end
  local in30 = 0
  for _, s in ipairs(self:_effective()) do
    if s.start >= now and s.start < now + 30 * 86400 and not s.block then
      in30 = in30 + 1
    end
  end
  return {
    status = status,
    current = current,
    nextStay = nextStay,
    lastEnded = lastEnded,
    staysNext30 = in30,
  }
end

--- Advances to `now`; returns the list of transitions, in order, among:
--- "arriving_today", "checked_in", "checked_out", "turnover_due", "vacant".
--- Also returns the evaluation.
function Engine:tick(now)
  local ev = self:evaluate(now)
  local prev = self.state
  local out = {}
  local currentUid = ev.current and ev.current.uid or nil
  local wasOccupied = prev.status == "occupied" or prev.status == "departing_today"
  local isOccupied = ev.status == "occupied" or ev.status == "departing_today"
  if wasOccupied and (not isOccupied or currentUid ~= prev.stayUid) then
    out[#out + 1] = { kind = "checked_out", uid = prev.stayUid, name = prev.name }
    self.lastCheckout = { uid = prev.stayUid, name = prev.name, at = now }
  end
  if isOccupied and (not wasOccupied or currentUid ~= prev.stayUid) then
    out[#out + 1] = { kind = "checked_in", uid = currentUid, name = ev.current.name, stay = ev.current }
  end
  if ev.status == "arriving_today" and prev.status ~= "arriving_today" then
    out[#out + 1] = { kind = "arriving_today", uid = ev.nextStay.uid, name = ev.nextStay.name, stay = ev.nextStay }
  end
  if ev.status == "turnover" and prev.status ~= "turnover" then
    out[#out + 1] = { kind = "turnover_due", uid = ev.lastEnded and ev.lastEnded.uid or nil }
  end
  if ev.status == "vacant" and prev.status ~= "vacant" then
    out[#out + 1] = { kind = "vacant" }
  end
  self.state = {
    status = ev.status,
    stayUid = currentUid,
    name = ev.current and ev.current.name or "",
  }
  return out, ev
end

--- Manual check-in at `now` with an optional name; a calendar stay already
--- in progress is simply adopted (no duplicate stay).
function Engine:checkIn(now, name)
  local ev = self:evaluate(now)
  if ev.current ~= nil then
    return false, "already occupied"
  end
  local trimmed = tostring(name or ""):gsub("^%s+", ""):gsub("%s+$", "")
  self.manual = {
    uid = "manual-" .. tostring(math.floor(now)),
    name = trimmed ~= "" and trimmed:sub(1, 80) or "Guest",
    start = now,
    finish = nil,
  }
  for _, s in ipairs(self.stays) do
    if s.start > now then
      self.manual.finish = s.start
      break
    end
  end
  return true
end

--- Manual check-out at `now`: ends the current stay; a calendar stay is
--- hidden until it is over so it does not re-check-in on the next tick.
function Engine:checkOut(now)
  local ev = self:evaluate(now)
  if ev.current == nil then
    return false, "nobody is checked in"
  end
  if ev.current.manual then
    self.manual.finish = now
  else
    -- The stay ENDS now (not hidden): turnover follows as after any check-out,
    -- and the stay cannot re-check-in because now >= its finish.
    self.cutoffs[ev.current.uid] = now
  end
  return true
end

--- Forgets manual overrides (used by the dealer's Clear Manual Override).
function Engine:clearOverrides()
  self.manual = nil
  self.cutoffs = {}
end

--- Drops hidden uids and manual stays that are over (bounded memory).
function Engine:prune(now)
  local known = {}
  for _, s in ipairs(self.stays) do
    known[s.uid] = s
  end
  for uid in pairs(self.cutoffs) do
    local s = known[uid]
    if s == nil or s.finish <= now then
      self.cutoffs[uid] = nil
    end
  end
  if self.manual ~= nil and self.manual.finish ~= nil and self.manual.finish <= now - 86400 then
    self.manual = nil
  end
end

return M
