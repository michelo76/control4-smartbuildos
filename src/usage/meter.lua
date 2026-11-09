--- Usage Analytics — the meter (pure, injected clock).
---
--- Turns three kinds of observations into daily usage figures a dealer can
--- act on at a service visit:
---
---   • MEDIA: a room is "in use" while its POWER_STATE is on; the source is
---     CURRENT_SELECTED_DEVICE. Seconds accumulate per room and per source.
---   • LIGHTS: a light is "on" while LIGHT_STATE is true or its level is > 0.
---     Seconds and on-cycles accumulate per light.
---   • KEYPADS: every press event is counted per keypad and per button.
---
--- Rules a technician relies on:
---   • TIME IS ATTRIBUTED WHEN IT IS KNOWN. Running intervals are flushed into
---     the current day on every change and on every tick (the driver ticks
---     once a minute), so a midnight crossing misattributes at most one tick.
---   • UNKNOWN IS NOT OFF. A room or light whose state was never read is not
---     counted until its first known value (`seed` reads it at apply time).
---   • DAYS ROLL BY THE LOCAL CALENDAR. `dayOf(t)` is injected; a finished day
---     is reported once by tick() and kept for `retention_days`.
---   • VALUES OTHER THAN THE TYPED ONES ABOVE ARE NEVER STORED. Source ids are
---     resolved to labels through an injected lookup; nothing else is kept.
---   • BOUNDED. Per-day tables are capped per kind (`limits`), and the daily
---     payload is cut to top lists so it fits the envelope (≤ 4 KB, ≤ 40
---     keys per table, depth ≤ 4).

local M = {}

M.LIMITS = {
  retention_days = 30,
  rooms = 64,
  lights = 200,
  keypads = 100,
  payload_rooms = 15,
  payload_lights = 10,
  payload_keypads = 15,
  payload_names = 15,
}

local Meter = {}
Meter.__index = Meter

local function truthy(raw)
  if raw == nil then
    return nil
  end
  if type(raw) == "boolean" then
    return raw
  end
  local s = tostring(raw):lower()
  if s == "true" or s == "1" or s == "on" then
    return true
  end
  if s == "false" or s == "0" or s == "off" or s == "" then
    return false
  end
  local n = tonumber(s)
  if n ~= nil then
    return n ~= 0
  end
  return nil
end

--- @param deps table { now = fun():number, dayOf = fun(t):string, deviceLabel = fun(id):string|nil }
function M.new(deps)
  local self = setmetatable({}, Meter)
  self.deps = deps
  self.now = deps.now
  self.dayOf = deps.dayOf or function(t)
    return os.date("%Y-%m-%d", math.floor(t))
  end
  self.rooms = {} -- roomId -> { label, power = bool|nil, source = number|nil, source_label, since }
  self.lights = {} -- deviceId -> { label, room, on = bool|nil, since }
  self.keypads = {} -- deviceId -> { label, room }
  self.days = {} -- day -> bucket
  self.currentDay = self.dayOf(self.now())
  self.counters = { media_changes = 0, light_changes = 0, presses = 0, days_closed = 0, pruned = 0 }
  return self
end

local function newBucket(day)
  return { day = day, media = {}, lights = {}, keypads = {}, first_at = nil, last_at = nil }
end

function Meter:_bucket(day)
  local b = self.days[day]
  if b == nil then
    b = newBucket(day)
    self.days[day] = b
  end
  return b
end

function Meter:_touch(b, t)
  if b.first_at == nil or t < b.first_at then
    b.first_at = t
  end
  if b.last_at == nil or t > b.last_at then
    b.last_at = t
  end
end

local function count(t)
  local n = 0
  for _ in pairs(t) do
    n = n + 1
  end
  return n
end

-- ── Registration of what is measured ───────────────────────────────────────

function Meter:addRoom(roomId, label)
  if self.rooms[roomId] == nil then
    if count(self.rooms) >= M.LIMITS.rooms then
      return false
    end
    self.rooms[roomId] = { label = label or ("Room " .. tostring(roomId)) }
  else
    self.rooms[roomId].label = label or self.rooms[roomId].label
  end
  return true
end

function Meter:addLight(deviceId, label, room)
  if self.lights[deviceId] == nil then
    if count(self.lights) >= M.LIMITS.lights then
      return false
    end
    self.lights[deviceId] = { label = label or ("Light " .. tostring(deviceId)), room = room }
  else
    self.lights[deviceId].label = label or self.lights[deviceId].label
    self.lights[deviceId].room = room or self.lights[deviceId].room
  end
  return true
end

function Meter:addKeypad(deviceId, label, room)
  if self.keypads[deviceId] == nil then
    if count(self.keypads) >= M.LIMITS.keypads then
      return false
    end
    self.keypads[deviceId] = { label = label or ("Keypad " .. tostring(deviceId)), room = room }
  else
    self.keypads[deviceId].label = label or self.keypads[deviceId].label
    self.keypads[deviceId].room = room or self.keypads[deviceId].room
  end
  return true
end

--- Drops everything not in the given sets (a re-plan removed a device).
function Meter:keepOnly(roomIds, lightIds, keypadIds)
  local t = self.now()
  self:flush(t)
  for id in pairs(self.rooms) do
    if not roomIds[id] then
      self.rooms[id] = nil
    end
  end
  for id in pairs(self.lights) do
    if not lightIds[id] then
      self.lights[id] = nil
    end
  end
  for id in pairs(self.keypads) do
    if not keypadIds[id] then
      self.keypads[id] = nil
    end
  end
end

-- ── Accumulation ───────────────────────────────────────────────────────────

local function roomOn(r)
  if r.power ~= nil then
    return r.power
  end
  return r.source ~= nil and r.source ~= 0
end

function Meter:_addMedia(b, roomId, r, seconds, t)
  if seconds <= 0 then
    return
  end
  local m = b.media[roomId]
  if m == nil then
    m = { label = r.label, seconds = 0, sources = {} }
    b.media[roomId] = m
  end
  m.label = r.label
  m.seconds = m.seconds + seconds
  local sid = r.source or 0
  local s = m.sources[sid]
  if s == nil then
    s = { label = r.source_label or (sid == 0 and "(no source)" or ("Device " .. tostring(sid))), seconds = 0 }
    m.sources[sid] = s
  end
  s.seconds = s.seconds + seconds
  self:_touch(b, t)
end

function Meter:_addLight(b, id, l, seconds, t)
  if seconds <= 0 then
    return
  end
  local e = b.lights[id]
  if e == nil then
    e = { label = l.label, room = l.room, seconds = 0, cycles = 0 }
    b.lights[id] = e
  end
  e.seconds = e.seconds + seconds
  self:_touch(b, t)
end

--- Books every running interval into the day of `t` and restarts it at `t`.
function Meter:flush(t)
  t = t or self.now()
  local b = self:_bucket(self.dayOf(t))
  for roomId, r in pairs(self.rooms) do
    if r.since ~= nil and roomOn(r) then
      self:_addMedia(b, roomId, r, t - r.since, t)
    end
    if r.since ~= nil then
      r.since = t
    end
  end
  for id, l in pairs(self.lights) do
    if l.since ~= nil and l.on then
      self:_addLight(b, id, l, t - l.since, t)
    end
    if l.since ~= nil then
      l.since = t
    end
  end
end

--- A room variable changed (or was seeded). Unknown names are ignored.
function Meter:onRoomVariable(roomId, name, value, seeding)
  local r = self.rooms[roomId]
  if r == nil then
    return false
  end
  local t = self.now()
  self:flush(t)
  if name == "POWER_STATE" then
    local on = truthy(value)
    if on ~= nil then
      r.power = on
    end
  elseif name == "CURRENT_SELECTED_DEVICE" then
    local sid = tonumber(value) or 0
    if sid ~= r.source then
      r.source = sid
      r.source_label = sid ~= 0 and self.deps.deviceLabel and self.deps.deviceLabel(sid) or nil
    end
  else
    return false
  end
  r.since = t
  if not seeding then
    self.counters.media_changes = self.counters.media_changes + 1
  end
  return true
end

--- A light variable changed (or was seeded).
function Meter:onLightVariable(deviceId, name, value, seeding)
  local l = self.lights[deviceId]
  if l == nil then
    return false
  end
  local on
  if name == "LIGHT_STATE" then
    on = truthy(value)
  elseif name == "LIGHT_LEVEL" or name == "Brightness Percent" then
    local n = tonumber(value)
    if n == nil then
      return false
    end
    on = n > 0
  else
    return false
  end
  if on == nil then
    return false
  end
  local t = self.now()
  self:flush(t)
  if on and l.on ~= true and not seeding then
    local b = self:_bucket(self.dayOf(t))
    local e = b.lights[deviceId]
    if e == nil then
      e = { label = l.label, room = l.room, seconds = 0, cycles = 0 }
      b.lights[deviceId] = e
    end
    e.cycles = e.cycles + 1
    self:_touch(b, t)
  end
  l.on = on
  l.since = t
  if not seeding then
    self.counters.light_changes = self.counters.light_changes + 1
  end
  return true
end

--- A keypad fired a press event.
function Meter:onKeypadPress(deviceId, eventId, eventName)
  local k = self.keypads[deviceId]
  if k == nil then
    return false
  end
  local t = self.now()
  local b = self:_bucket(self.dayOf(t))
  local e = b.keypads[deviceId]
  if e == nil then
    e = { label = k.label, room = k.room, presses = 0, buttons = {} }
    b.keypads[deviceId] = e
  end
  e.presses = e.presses + 1
  local btn = e.buttons[eventId]
  if btn == nil then
    btn = { name = eventName or ("Event " .. tostring(eventId)), presses = 0 }
    e.buttons[eventId] = btn
  end
  btn.presses = btn.presses + 1
  self:_touch(b, t)
  self.counters.presses = self.counters.presses + 1
  return true
end

--- Periodic: flushes, closes finished days (returned, oldest first) and
--- prunes beyond retention.
function Meter:tick()
  local t = self.now()
  self:flush(t)
  local today = self.dayOf(t)
  local closed = {}
  if today ~= self.currentDay then
    local days = {}
    for day in pairs(self.days) do
      if day < today then
        days[#days + 1] = day
      end
    end
    table.sort(days)
    for _, day in ipairs(days) do
      if not self.days[day].closed then
        self.days[day].closed = true
        closed[#closed + 1] = day
        self.counters.days_closed = self.counters.days_closed + 1
      end
    end
    self.currentDay = today
    self:_bucket(today)
  end
  self:prune(today)
  return closed
end

function Meter:prune(today)
  local keys = {}
  for day in pairs(self.days) do
    keys[#keys + 1] = day
  end
  table.sort(keys)
  local keep = M.LIMITS.retention_days
  while #keys > keep do
    local day = table.remove(keys, 1)
    if day ~= today then
      self.days[day] = nil
      self.counters.pruned = self.counters.pruned + 1
    end
  end
end

-- ── Views ──────────────────────────────────────────────────────────────────

function Meter:today()
  return self:_bucket(self.dayOf(self.now()))
end

local function sortedDays(self)
  local keys = {}
  for day in pairs(self.days) do
    keys[#keys + 1] = day
  end
  table.sort(keys)
  return keys
end

--- Aggregates the last `n` days (today included) into one bucket-like table,
--- or exactly one named day when `onlyDay` is given (a closed day: no flush).
function Meter:aggregate(n, onlyDay)
  local days
  if onlyDay ~= nil then
    days = self.days[onlyDay] ~= nil and { onlyDay } or {}
  else
    self:flush(self.now())
    days = sortedDays(self)
  end
  local from = onlyDay ~= nil and 1 or math.max(1, #days - n + 1)
  local agg = { days = 0, media = {}, lights = {}, keypads = {} }
  for i = from, #days do
    local b = self.days[days[i]]
    agg.days = agg.days + 1
    for roomId, m in pairs(b.media) do
      local a = agg.media[roomId]
      if a == nil then
        a = { label = m.label, seconds = 0, sources = {} }
        agg.media[roomId] = a
      end
      a.label = m.label
      a.seconds = a.seconds + m.seconds
      for sid, s in pairs(m.sources) do
        local as = a.sources[sid]
        if as == nil then
          as = { label = s.label, seconds = 0 }
          a.sources[sid] = as
        end
        as.seconds = as.seconds + s.seconds
      end
    end
    for id, l in pairs(b.lights) do
      local a = agg.lights[id]
      if a == nil then
        a = { label = l.label, room = l.room, seconds = 0, cycles = 0 }
        agg.lights[id] = a
      end
      a.seconds = a.seconds + l.seconds
      a.cycles = a.cycles + l.cycles
    end
    for id, k in pairs(b.keypads) do
      local a = agg.keypads[id]
      if a == nil then
        a = { label = k.label, room = k.room, presses = 0, buttons = {} }
        agg.keypads[id] = a
      end
      a.presses = a.presses + k.presses
      for eid, btn in pairs(k.buttons) do
        local ab = a.buttons[eid]
        if ab == nil then
          ab = { name = btn.name, presses = 0 }
          a.buttons[eid] = ab
        end
        ab.presses = ab.presses + btn.presses
      end
    end
  end
  return agg
end

local function hours(seconds)
  return math.floor((seconds or 0) / 360 + 0.5) / 10
end
M.hours = hours

local function sortedList(map, field, desc)
  local out = {}
  for id, v in pairs(map) do
    local e = {}
    for k, x in pairs(v) do
      e[k] = x
    end
    e.id = id
    out[#out + 1] = e
  end
  table.sort(out, function(a, b)
    if a[field] == b[field] then
      return tostring(a.label) < tostring(b.label)
    end
    if desc then
      return a[field] > b[field]
    end
    return a[field] < b[field]
  end)
  return out
end

--- Totals and the lists a report or payload is built from.
function Meter:summary(n, onlyDay)
  local agg = self:aggregate(n, onlyDay)
  local s = {
    days = agg.days,
    media_seconds = 0,
    light_seconds = 0,
    presses = 0,
    rooms = sortedList(agg.media, "seconds", true),
    lights = sortedList(agg.lights, "seconds", true),
    keypads = sortedList(agg.keypads, "presses", true),
    unused_rooms = {},
    unused_keypads = {},
    unused_lights = {},
  }
  for _, r in ipairs(s.rooms) do
    s.media_seconds = s.media_seconds + r.seconds
    local best = nil
    for sid, src in pairs(r.sources) do
      if best == nil or src.seconds > best.seconds then
        best = { id = sid, label = src.label, seconds = src.seconds }
      end
    end
    r.top_source = best
  end
  for _, l in ipairs(s.lights) do
    s.light_seconds = s.light_seconds + l.seconds
  end
  for _, k in ipairs(s.keypads) do
    s.presses = s.presses + k.presses
  end
  for roomId, r in pairs(self.rooms) do
    if agg.media[roomId] == nil or agg.media[roomId].seconds == 0 then
      s.unused_rooms[#s.unused_rooms + 1] = r.label
    end
  end
  for id, k in pairs(self.keypads) do
    if agg.keypads[id] == nil then
      s.unused_keypads[#s.unused_keypads + 1] = k.label
    end
  end
  for id, l in pairs(self.lights) do
    if agg.lights[id] == nil or agg.lights[id].seconds == 0 then
      s.unused_lights[#s.unused_lights + 1] = l.label
    end
  end
  table.sort(s.unused_rooms)
  table.sort(s.unused_keypads)
  table.sort(s.unused_lights)
  return s
end

--- Lines for Director's log.
function Meter:reportLines(n, title)
  local s = self:summary(n)
  local lines = {}
  lines[#lines + 1] = string.format(
    "== Usage %s (%d day(s)): media %.1f h, lights %.1f h, %d keypad press(es) ==",
    title or (n .. "d"),
    s.days,
    hours(s.media_seconds),
    hours(s.light_seconds),
    s.presses
  )
  lines[#lines + 1] = "-- Rooms by media hours"
  for i = 1, math.min(#s.rooms, 25) do
    local r = s.rooms[i]
    lines[#lines + 1] = string.format(
      "  %-28s %6.1f h%s",
      tostring(r.label):sub(1, 28),
      hours(r.seconds),
      r.top_source and string.format("  top: %s (%.1f h)", tostring(r.top_source.label), hours(r.top_source.seconds))
        or ""
    )
  end
  lines[#lines + 1] = "-- Lights by on-hours"
  for i = 1, math.min(#s.lights, 25) do
    local l = s.lights[i]
    lines[#lines + 1] = string.format(
      "  %-28s %6.1f h  %3d cycle(s)%s",
      tostring(l.label):sub(1, 28),
      hours(l.seconds),
      l.cycles,
      l.room and ("  " .. tostring(l.room)) or ""
    )
  end
  lines[#lines + 1] = "-- Keypads by presses"
  for i = 1, math.min(#s.keypads, 25) do
    local k = s.keypads[i]
    local buttons = sortedList(k.buttons, "presses", true)
    local parts = {}
    for j = 1, math.min(#buttons, 4) do
      parts[#parts + 1] = string.format("%s %d", tostring(buttons[j].name), buttons[j].presses)
    end
    lines[#lines + 1] =
      string.format("  %-28s %5d  %s", tostring(k.label):sub(1, 28), k.presses, table.concat(parts, ", "))
  end
  if #s.unused_rooms > 0 then
    lines[#lines + 1] = "-- Rooms with no media use: " .. table.concat(s.unused_rooms, ", ")
  end
  if #s.unused_keypads > 0 then
    lines[#lines + 1] = "-- Keypads never pressed: " .. table.concat(s.unused_keypads, ", ")
  end
  if #s.unused_lights > 0 then
    lines[#lines + 1] = "-- Lights never on: " .. table.concat(s.unused_lights, ", ")
  end
  return lines
end

local function cap(list, n, map)
  local out = {}
  for i = 1, math.min(#list, n) do
    out[#out + 1] = map(list[i])
  end
  return out
end

--- The `usage.daily` / `usage.summary` payload: bounded to the envelope's
--- limits (top lists only; names cut to 60 characters).
function Meter:payload(dayOrDays)
  local s
  local label
  if type(dayOrDays) == "string" and self.days[dayOrDays] ~= nil then
    -- One specific (closed) day.
    s = self:summary(1, dayOrDays)
    label = dayOrDays
  else
    s = self:summary(tonumber(dayOrDays) or 1)
    label = tostring(dayOrDays or 1) .. "d"
  end
  local function short(x)
    return tostring(x or ""):sub(1, 60)
  end
  return {
    period = label,
    days = s.days,
    media_hours = hours(s.media_seconds),
    light_hours = hours(s.light_seconds),
    keypad_presses = s.presses,
    rooms_measured = count(self.rooms),
    lights_measured = count(self.lights),
    keypads_measured = count(self.keypads),
    rooms = cap(s.rooms, M.LIMITS.payload_rooms, function(r)
      return {
        room = short(r.label),
        hours = hours(r.seconds),
        top_source = r.top_source and short(r.top_source.label) or nil,
      }
    end),
    lights_top = cap(s.lights, M.LIMITS.payload_lights, function(l)
      return { light = short(l.label), hours = hours(l.seconds), cycles = l.cycles }
    end),
    keypads = cap(s.keypads, M.LIMITS.payload_keypads, function(k)
      return { keypad = short(k.label), presses = k.presses }
    end),
    unused_rooms = cap(s.unused_rooms, M.LIMITS.payload_names, short),
    unused_keypads = cap(s.unused_keypads, M.LIMITS.payload_names, short),
    unused_lights_count = #s.unused_lights,
  }
end

-- ── Persistence ────────────────────────────────────────────────────────────

--- Days only. Running states are re-seeded by the driver at apply.
function Meter:serialize()
  self:flush(self.now())
  return { v = 1, days = self.days, counters = self.counters }
end

function M.restore(deps, doc)
  local m = M.new(deps)
  if type(doc) ~= "table" or type(doc.days) ~= "table" then
    return m, false
  end
  local n = 0
  for day, b in pairs(doc.days) do
    if type(day) == "string" and type(b) == "table" and type(b.media) == "table" then
      b.lights = type(b.lights) == "table" and b.lights or {}
      b.keypads = type(b.keypads) == "table" and b.keypads or {}
      -- JSON round trips turn numeric keys into strings; normalise.
      for _, kind in ipairs({ "media", "lights", "keypads" }) do
        local fixed = {}
        for k, v in pairs(b[kind]) do
          fixed[tonumber(k) or k] = v
        end
        b[kind] = fixed
      end
      m.days[day] = b
      n = n + 1
    end
  end
  if type(doc.counters) == "table" then
    for k, v in pairs(doc.counters) do
      if m.counters[k] ~= nil and type(v) == "number" then
        m.counters[k] = v
      end
    end
  end
  return m, n > 0
end

return M
