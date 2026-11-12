--- Daypart Scheduler: the pure rules (no Control4 globals, no os clock).
---
--- A weekly time-block schedule of music source, volume and display power,
--- per zone, that on-site staff edit without Composer. This module owns:
---
---   * the block model and its validation (allowed sources only, volume
---     clamped to the dealer's range, overlaps refused with a clear message)
---   * which block is active at a given wall-clock moment: weekly blocks,
---     the holiday template, a "today only" override, blocks that cross
---     midnight
---   * reconciling "what should be running" with "what is running" into a
---     list of actions the driver carries out (end X, start Y)
---   * the volume ramp and the command plans for a block start or end
---
--- Time is WALL-CLOCK, never an elapsed-seconds count. A block is active when
--- the local date and minute-of-day say so, and a block run is identified by
--- its calendar date and block id. That one choice makes daylight-saving
--- changes, manual clock changes and controller restarts the same problem:
--- recompute, compare with what is running, act on the difference. The clock
--- is injected (deps.now / deps.localtime) so every case is a test.
---
--- Days are ISO numbers: 1 = Monday ... 7 = Sunday.

local M = {}

M.MAX_ZONES = 4
M.MAX_BLOCKS = 40 -- per template list (week, holiday, today)
M.MAX_HOLIDAYS = 60
M.MAX_NAME = 40
M.SCOPES = { week = true, holiday = true, today = true }
M.END_BEHAVIOURS = { hold = true, fade = true, off = true }
M.DAY_NAMES = { "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" }
M.DAY_LONG = { "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday" }

-- ─── Calendar arithmetic (civil dates, no os.time, no time zones) ───────────

--- Days since 1970-01-01 for a civil date.
function M.daysFromCivil(y, m, d)
  if m <= 2 then
    y = y - 1
  end
  local era = math.floor(y / 400)
  local yoe = y - era * 400
  local mp = (m + 9) % 12
  local doy = math.floor((153 * mp + 2) / 5) + d - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  return era * 146097 + doe - 719468
end

--- The civil date of a day number: year, month, day.
function M.civilFromDays(z)
  z = z + 719468
  local era = math.floor(z / 146097)
  local doe = z - era * 146097
  local yoe = math.floor((doe - math.floor(doe / 1460) + math.floor(doe / 36524) - math.floor(doe / 146096)) / 365)
  local y = yoe + era * 400
  local doy = doe - (365 * yoe + math.floor(yoe / 4) - math.floor(yoe / 100))
  local mp = math.floor((5 * doy + 2) / 153)
  local d = doy - math.floor((153 * mp + 2) / 5) + 1
  local m = mp < 10 and mp + 3 or mp - 9
  if m <= 2 then
    y = y + 1
  end
  return y, m, d
end

--- 1 = Monday ... 7 = Sunday for a day number.
function M.isoWeekday(dayNum)
  return (dayNum + 3) % 7 + 1
end

function M.dateString(dayNum)
  local y, m, d = M.civilFromDays(dayNum)
  return string.format("%04d-%02d-%02d", y, m, d)
end

--- "YYYY-MM-DD" -> day number, or nil when it is not a real calendar date.
function M.parseDate(s)
  local y, m, d = tostring(s or ""):match("^(%d%d%d%d)-(%d%d)-(%d%d)$")
  y, m, d = tonumber(y), tonumber(m), tonumber(d)
  if y == nil or m < 1 or m > 12 or d < 1 or d > 31 then
    return nil
  end
  local n = M.daysFromCivil(y, m, d)
  local ry, rm, rd = M.civilFromDays(n)
  if ry ~= y or rm ~= m or rd ~= d then
    return nil
  end
  return n
end

--- "HH:MM" -> minutes past midnight. "24:00" is accepted only as an end time.
function M.parseTime(s, allow24)
  local h, m = tostring(s or ""):match("^(%d%d?):(%d%d)$")
  h, m = tonumber(h), tonumber(m)
  if h == nil or m > 59 then
    return nil
  end
  if h == 24 and m == 0 and allow24 then
    return 1440
  end
  if h > 23 then
    return nil
  end
  return h * 60 + m
end

function M.formatTime(minutes)
  minutes = math.floor(minutes)
  return string.format("%02d:%02d", math.floor(minutes / 60) % 25, minutes % 60)
end

--- Wall-clock fields from a localtime() table (os.date("*t") shape).
--- @return table { day = dayNumber, minute = 0..1439, date = "YYYY-MM-DD" }
function M.moment(lt)
  local day = M.daysFromCivil(lt.year, lt.month, lt.day)
  return { day = day, minute = (lt.hour or 0) * 60 + (lt.min or 0), date = M.dateString(day), second = lt.sec or 0 }
end

--- "Mon-Fri", "Sat, Sun", "Mon, Wed, Fri" for a days list.
function M.describeDays(days)
  local set, list = {}, {}
  for _, d in ipairs(days or {}) do
    set[d] = true
  end
  for d = 1, 7 do
    if set[d] then
      list[#list + 1] = d
    end
  end
  if #list == 7 then
    return "every day"
  end
  local parts, i = {}, 1
  while i <= #list do
    local j = i
    while list[j + 1] == list[j] + 1 do
      j = j + 1
    end
    if j - i >= 2 then
      parts[#parts + 1] = M.DAY_NAMES[list[i]] .. "-" .. M.DAY_NAMES[list[j]]
    else
      for k = i, j do
        parts[#parts + 1] = M.DAY_NAMES[list[k]]
      end
    end
    i = j + 1
  end
  return table.concat(parts, ", ")
end

--- One line for a block, for messages and the history.
function M.describeBlock(b)
  local when = b.days and (M.describeDays(b.days) .. " ") or ""
  return string.format('"%s" %s%s-%s', tostring(b.name), when, tostring(b.from), tostring(b.to))
end

-- ─── Block model ────────────────────────────────────────────────────────────

local function clampInt(v, lo, hi)
  v = math.floor(v + 0.5)
  if v < lo then
    return lo
  end
  if v > hi then
    return hi
  end
  return v
end

local function copy(v)
  if type(v) ~= "table" then
    return v
  end
  local out = {}
  for k, x in pairs(v) do
    out[k] = copy(x)
  end
  return out
end
M.copy = copy

local function trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function cleanName(s)
  local n = trim((tostring(s or ""):gsub("[%c|]", " ")))
  n = n:gsub("%s+", " ")
  return n
end

--- A comparable signature of what a block DOES (not what it is called).
function M.signature(b)
  return table.concat({
    tostring(b.source),
    tostring(b.volume),
    tostring(b.displays or "keep"),
  }, "/")
end

local function zoneAllowsSource(zone, id)
  for _, s in ipairs(zone and zone.sources or {}) do
    if s.id == id then
      return true
    end
  end
  return false
end

--- Validates and normalises a block spec against a zone's dealer limits.
--- @param spec table { name, days?, from, to, source?, volume?, displays? }
--- @param zone table the zone config (sources, min, max, displays)
--- @param scope string week | holiday | today
--- @return table|nil block, string|table errOrWarnings
function M.normalizeBlock(spec, zone, scope)
  if type(spec) ~= "table" then
    return nil, "Nothing to save."
  end
  local warnings = {}
  local name = cleanName(spec.name)
  if name == "" then
    return nil, "Give the block a name."
  end
  if #name > M.MAX_NAME then
    return nil, "The block name is too long (" .. M.MAX_NAME .. " characters at most)."
  end
  local from = M.parseTime(spec.from)
  local to = M.parseTime(spec.to, true)
  if from == nil then
    return nil, "The start time is not a valid time (use HH:MM)."
  end
  if to == nil then
    return nil, "The end time is not a valid time (use HH:MM)."
  end
  if from == to then
    return nil, "A block cannot start and end at the same time."
  end
  local b = { id = spec.id, name = name, from = M.formatTime(from), to = M.formatTime(to) }
  if to == 1440 then
    b.to = "24:00"
  end
  if scope == "week" then
    local seen, days = {}, {}
    for _, d in ipairs(type(spec.days) == "table" and spec.days or {}) do
      d = tonumber(d)
      if d ~= nil and d >= 1 and d <= 7 and d == math.floor(d) and not seen[d] then
        seen[d] = true
        days[#days + 1] = d
      end
    end
    if #days == 0 then
      return nil, "Pick at least one day."
    end
    table.sort(days)
    b.days = days
  end
  -- Source: only what the dealer allowed for this zone.
  local source = spec.source
  if source == nil or source == "" or source == "keep" then
    b.source = nil
  elseif source == "off" then
    b.source = "off"
  else
    source = tonumber(source)
    if source == nil or not zoneAllowsSource(zone, source) then
      return nil, "That source is not allowed in this zone. Pick one from the list."
    end
    b.source = source
  end
  -- Volume: clamped into the dealer's range.
  if b.source ~= "off" and spec.volume ~= nil and spec.volume ~= "" then
    local v = tonumber(spec.volume)
    if v == nil then
      return nil, "The volume must be a number."
    end
    local lo, hi = zone.min or 0, zone.max or 100
    local c = clampInt(v, lo, hi)
    if c ~= math.floor(v + 0.5) then
      warnings[#warnings + 1] =
        string.format("Volume %d is outside this zone's range, set to %d.", math.floor(v + 0.5), c)
    end
    b.volume = c
  end
  -- Displays.
  local displays = spec.displays
  if displays == nil or displays == "" then
    displays = "keep"
  end
  if displays ~= "on" and displays ~= "off" and displays ~= "keep" then
    return nil, "Displays must be on, off or left alone."
  end
  if displays ~= "keep" and #(zone.displays or {}) == 0 then
    return nil, "This zone has no displays set up."
  end
  b.displays = displays
  return b, warnings
end

--- The pieces of the timeline a block occupies, for overlap checks.
local function segments(b, scope)
  local f, t = M.parseTime(b.from), M.parseTime(b.to, true)
  local crossing = f > t
  local out = {}
  if scope == "week" then
    for _, d in ipairs(b.days or {}) do
      local base = (d - 1) * 1440
      if not crossing then
        out[#out + 1] = { s = base + f, e = base + t, day = d }
      else
        out[#out + 1] = { s = base + f, e = base + 1440, day = d }
        if t > 0 then
          local nextBase = (base + 1440) % 10080
          out[#out + 1] = { s = nextBase, e = nextBase + t, day = d }
        end
      end
    end
  elseif scope == "holiday" then
    -- A holiday template repeats for every holiday: one circular day.
    if not crossing then
      out[#out + 1] = { s = f, e = t }
    else
      out[#out + 1] = { s = f, e = 1440 }
      if t > 0 then
        out[#out + 1] = { s = 0, e = t }
      end
    end
  else
    -- Today only: one date, running on into the small hours of the next.
    out[#out + 1] = { s = f, e = crossing and (1440 + t) or t }
  end
  return out
end

--- The first block in `list` that overlaps `candidate`, with the weekday it
--- collides on (week scope), or nil. `ignoreId` skips the block being edited.
function M.findOverlap(list, candidate, scope, ignoreId)
  local mine = segments(candidate, scope)
  for _, other in ipairs(list or {}) do
    if other.id ~= ignoreId then
      for _, a in ipairs(mine) do
        for _, b in ipairs(segments(other, scope)) do
          if a.s < b.e and b.s < a.e then
            local day = scope == "week" and M.DAY_LONG[math.floor(math.max(a.s, b.s) / 1440) + 1] or nil
            return other, day
          end
        end
      end
    end
  end
  return nil
end

local function overlapMessage(other, day)
  return string.format(
    'Overlaps "%s" (%s-%s)%s. Change the times or the days.',
    other.name,
    other.from,
    other.to,
    day and (" on " .. day) or ""
  )
end

-- ─── Volume ramp and command plans ──────────────────────────────────────────

--- Steps that take the volume from `from` to `to` over `seconds`.
--- Whole volume points only, never closer than minStep seconds apart, the
--- last one exactly on target at exactly `seconds`. The caller has already
--- set (or read) the starting level, so step 0 is not included.
--- @return table steps { { at = seconds, level = n }, ... }
function M.rampPlan(from, to, seconds, minStep)
  to = clampInt(to, 0, 100)
  from = clampInt(from or to, 0, 100)
  seconds = math.max(0, math.floor(tonumber(seconds) or 0))
  minStep = minStep or 2
  if seconds == 0 or from == to then
    return { { at = 0, level = to } }
  end
  local diff = math.abs(to - from)
  local steps = math.min(diff, math.max(1, math.floor(seconds / minStep)))
  local out = {}
  for i = 1, steps do
    out[#out + 1] = {
      at = math.floor(seconds * i / steps + 0.5),
      level = i == steps and to or math.floor(from + (to - from) * i / steps + 0.5),
    }
  end
  return out
end

local function displayCommands(zone, mode, at)
  local out = {}
  if mode ~= "on" and mode ~= "off" then
    return out
  end
  for _, d in ipairs(zone.displays or {}) do
    out[#out + 1] =
      { at = at or 0, device = d.id, command = mode == "on" and "ON" or "OFF", params = {}, what = "display" }
  end
  return out
end

--- Commands to carry out a block start.
--- @param zone table zone config
--- @param block table
--- @param ctx table { roomOn?, currentVolume?, rampSeconds }
--- @return table steps { { at, device, command, params, what } ... } in time order
function M.planStart(zone, block, ctx)
  ctx = ctx or {}
  local steps = {}
  local room = zone.room
  if room == nil then
    return steps
  end
  if block.source == "off" then
    steps[#steps + 1] = { at = 0, device = room, command = "ROOM_OFF", params = {}, what = "room" }
  else
    if block.source ~= nil then
      steps[#steps + 1] = {
        at = 0,
        device = room,
        command = "SELECT_AUDIO_DEVICE",
        params = { deviceid = block.source },
        what = "source",
      }
    end
    if block.volume == nil and block.source ~= nil and ctx.roomOn == false then
      -- No level asked for, room was off: bring it up quietly, not at its last level.
      steps[#steps + 1] =
        { at = 0, device = room, command = "SET_VOLUME_LEVEL", params = { LEVEL = zone.min or 0 }, what = "volume" }
    end
    if block.volume ~= nil then
      local target = clampInt(block.volume, zone.min or 0, zone.max or 100)
      local from = ctx.currentVolume
      -- A room that was off, or whose level we cannot read, is brought up
      -- from the bottom of the dealer's range: never from whatever it last
      -- played at.
      if ctx.roomOn == false or from == nil then
        from = zone.min or 0
      end
      local ramp = M.rampPlan(from, target, ctx.rampSeconds or 0)
      -- Start level first when the level will climb or fall over time, or
      -- when the source change may have brought the room up: never leave the
      -- room at whatever it last played at.
      local gradual = #ramp > 1 or ramp[1].at > 0
      if gradual and (block.source ~= nil or ctx.roomOn == false or ctx.currentVolume == nil) then
        steps[#steps + 1] =
          { at = 0, device = room, command = "SET_VOLUME_LEVEL", params = { LEVEL = from }, what = "volume" }
      end
      for _, r in ipairs(ramp) do
        steps[#steps + 1] =
          { at = r.at, device = room, command = "SET_VOLUME_LEVEL", params = { LEVEL = r.level }, what = "volume" }
      end
    end
  end
  for _, s in ipairs(displayCommands(zone, block.displays, 0)) do
    steps[#steps + 1] = s
  end
  return steps
end

--- Commands for the gap after a block, per the dealer's end behaviour.
--- @param ctx table { currentVolume?, fadeSeconds }
function M.planEnd(zone, behaviour, ctx)
  ctx = ctx or {}
  local steps = {}
  if zone.room == nil or behaviour == "hold" or behaviour == nil then
    return steps
  end
  if behaviour == "off" then
    steps[#steps + 1] = { at = 0, device = zone.room, command = "ROOM_OFF", params = {}, what = "room" }
    for _, s in ipairs(displayCommands(zone, "off", 0)) do
      steps[#steps + 1] = s
    end
    return steps
  end
  -- fade: down to silence, then off.
  local from = ctx.currentVolume
  local fade = math.max(0, math.floor(tonumber(ctx.fadeSeconds) or 0))
  local last = 0
  if from ~= nil and from > 0 then
    for _, r in ipairs(M.rampPlan(from, 0, fade)) do
      steps[#steps + 1] =
        { at = r.at, device = zone.room, command = "SET_VOLUME_LEVEL", params = { LEVEL = r.level }, what = "volume" }
      last = r.at
    end
  end
  steps[#steps + 1] = { at = last + 1, device = zone.room, command = "ROOM_OFF", params = {}, what = "room" }
  for _, s in ipairs(displayCommands(zone, "off", last + 1)) do
    steps[#steps + 1] = s
  end
  return steps
end

-- ─── The engine ─────────────────────────────────────────────────────────────

local Engine = {}
Engine.__index = Engine
M.Engine = Engine

local function emptyZone()
  return { week = {}, holiday = {}, today = { date = "", blocks = {} } }
end

local function emptyDoc()
  local doc = { v = 1, zones = {}, holidays = {}, nextId = 1 }
  for slot = 1, M.MAX_ZONES do
    doc.zones[slot] = emptyZone()
  end
  return doc
end

--- @param deps table { now = fun():number, localtime = fun(epoch):table }
function M.new(deps)
  deps = deps or {}
  local self = setmetatable({}, Engine)
  self.now = deps.now or os.time
  self.localtime = deps.localtime or function(t)
    return os.date("*t", math.floor(t))
  end
  self.doc = emptyDoc()
  self.zones = {} -- slot -> zone config (the dealer's)
  self.run = {} -- slot -> what is running
  self.skips = {} -- slot -> { [instanceKey] = true }
  self.fresh = {} -- slot -> true until reconciled once (restart / pause)
  self.readOnly = false
  self.manualSeq = 0
  self.holidaySet = {}
  return self
end

function Engine:setReadOnly(flag)
  self.readOnly = flag == true
end

--- The dealer's zones. Absent slots are unconfigured.
--- @param zones table slot -> { slot, name, room, sources, min, max, displays }
function Engine:setZones(zones)
  self.zones = zones or {}
  for slot in pairs(self.run) do
    if self.zones[slot] == nil then
      self.run[slot] = nil
    end
  end
end

function Engine:zone(slot)
  return self.zones[slot]
end

function Engine:moment(epoch)
  return M.moment(self.localtime(epoch or self.now()))
end

local function rebuildHolidaySet(self)
  self.holidaySet = {}
  for _, d in ipairs(self.doc.holidays) do
    self.holidaySet[d] = true
  end
end

--- Marks every zone as needing a fresh look (after a pause, a restart, a
--- clock jump): an interrupted ramp is resumed, a running block is not restarted.
function Engine:invalidateRuntime()
  for slot = 1, M.MAX_ZONES do
    self.fresh[slot] = true
  end
end

-- Block lists for a date -------------------------------------------------

--- The blocks that apply on a date and where they came from.
--- @return table blocks, string source week | holiday | today
function Engine:blocksFor(slot, dayNum)
  local zs = self.doc.zones[slot]
  local ds = M.dateString(dayNum)
  if zs.today.date == ds then
    return zs.today.blocks, "today"
  end
  if self.holidaySet[ds] then
    return zs.holiday, "holiday"
  end
  local wd = M.isoWeekday(dayNum)
  local out = {}
  for _, b in ipairs(zs.week) do
    for _, d in ipairs(b.days) do
      if d == wd then
        out[#out + 1] = b
        break
      end
    end
  end
  return out, "week"
end

local function instanceKey(ds, id)
  return ds .. "|" .. tostring(id)
end

local function isSkipped(self, slot, key)
  return self.skips[slot] ~= nil and self.skips[slot][key] == true
end

--- Which block is active in a zone at a moment. Midnight-crossing blocks
--- belong to the day they START on; when two candidates are live (a block
--- spilling past midnight and the next day's first block), the one that
--- started later wins.
--- @return table|nil { block, date, key, startDay, startMin, source, minutesIn }
function Engine:resolve(slot, mo)
  local best
  for back = 0, 1 do
    local dayNum = mo.day - back
    local blocks, source = self:blocksFor(slot, dayNum)
    for _, b in ipairs(blocks) do
      local f, t = M.parseTime(b.from), M.parseTime(b.to, true)
      local live
      if back == 0 then
        live = (f < t) and (mo.minute >= f and mo.minute < t) or (f > t and mo.minute >= f)
      else
        live = f > t and mo.minute < t
      end
      local ds = M.dateString(dayNum)
      local key = instanceKey(ds, b.id)
      if live and not isSkipped(self, slot, key) then
        if best == nil or dayNum > best.startDay or (dayNum == best.startDay and f > best.startMin) then
          best = {
            block = b,
            date = ds,
            key = key,
            startDay = dayNum,
            startMin = f,
            source = source,
            minutesIn = (mo.day - dayNum) * 1440 + mo.minute - f,
          }
        end
      end
    end
  end
  return best
end

--- The next block that will start in a zone (skipped ones excluded).
--- @return table|nil { block, date, key, from, in_days, source }
function Engine:nextBlock(slot, mo)
  local best
  for off = 0, 8 do
    local dayNum = mo.day + off
    local blocks, source = self:blocksFor(slot, dayNum)
    for _, b in ipairs(blocks) do
      local f = M.parseTime(b.from)
      local key = instanceKey(M.dateString(dayNum), b.id)
      if (off > 0 or f > mo.minute) and not isSkipped(self, slot, key) then
        if best == nil or off < best.in_days or (off == best.in_days and f < best.startMin) then
          best = {
            block = b,
            date = M.dateString(dayNum),
            key = key,
            from = b.from,
            startMin = f,
            in_days = off,
            source = source,
          }
        end
      end
    end
    if best ~= nil and best.in_days == off then
      break
    end
  end
  return best
end

-- Reconcile --------------------------------------------------------------

--- Compares what should be running with what is running and returns the
--- actions that close the gap. Pure state: it updates the run records and
--- returns the list; the driver carries the actions out.
--- @return table actions { {kind="end", slot, run, gap}, {kind="start", slot, block, key, ...} }
function Engine:reconcile(epoch)
  local mo = self:moment(epoch)
  local actions = {}
  self:prune(mo)
  for slot = 1, M.MAX_ZONES do
    if self.zones[slot] ~= nil then
      local active = self:resolve(slot, mo)
      local run = self.run[slot]
      local hold = false
      if run ~= nil and run.manual then
        -- A manual run holds until the schedule moves on from what it was
        -- running when the manual block was started.
        if (active and active.key or "") == run.base then
          hold = true
        else
          actions[#actions + 1] = { kind = "end", slot = slot, run = copy(run), gap = active == nil, manual = true }
          self.run[slot] = nil
          run = nil
        end
      end
      if not hold then
        if run ~= nil and (active == nil or active.key ~= run.key) then
          actions[#actions + 1] = { kind = "end", slot = slot, run = copy(run), gap = active == nil }
          self.run[slot] = nil
          run = nil
        end
        if active ~= nil then
          local sig = M.signature(active.block)
          if run == nil then
            self.run[slot] = {
              key = active.key,
              block_id = active.block.id,
              name = active.block.name,
              date = active.date,
              sig = sig,
              volume = active.block.volume,
              state = "ramping",
            }
            actions[#actions + 1] = {
              kind = "start",
              slot = slot,
              block = copy(active.block),
              key = active.key,
              minutes_in = active.minutesIn,
              scope = active.source,
            }
          elseif run.sig ~= sig then
            run.sig, run.volume, run.state = sig, active.block.volume, "ramping"
            run.name = active.block.name
            actions[#actions + 1] = {
              kind = "start",
              slot = slot,
              block = copy(active.block),
              key = active.key,
              update = true,
              scope = active.source,
            }
          elseif self.fresh[slot] and run.state == "ramping" then
            actions[#actions + 1] = {
              kind = "start",
              slot = slot,
              block = copy(active.block),
              key = active.key,
              resume = true,
              scope = active.source,
            }
          end
          if self.run[slot] ~= nil then
            self.run[slot].name = active.block.name
          end
        end
      end
      self.fresh[slot] = false
    end
  end
  return actions
end

--- The driver reports a block's ramp is done.
function Engine:markSteady(slot)
  if self.run[slot] ~= nil then
    self.run[slot].state = "steady"
  end
end

--- Starts a block by hand (Run Block Now). It holds until the schedule
--- moves on from what it was running when the manual block began.
--- @return table|nil run, string|nil err
function Engine:startManual(slot, blockId, scope)
  local zs = self.doc.zones[slot]
  if zs == nil or self.zones[slot] == nil then
    return nil, "That zone is not set up."
  end
  local list = scope == "holiday" and zs.holiday or (scope == "today" and zs.today.blocks or zs.week)
  local block
  for _, b in ipairs(list) do
    if b.id == blockId then
      block = b
    end
  end
  if block == nil then
    return nil, "No such block."
  end
  local mo = self:moment()
  local active = self:resolve(slot, mo)
  self.manualSeq = self.manualSeq + 1
  self.run[slot] = {
    key = "manual|" .. tostring(self.manualSeq),
    manual = true,
    base = active and active.key or "",
    block_id = block.id,
    name = block.name,
    sig = M.signature(block),
    volume = block.volume,
    state = "ramping",
  }
  return copy(block)
end

--- Finds a block by name (case-insensitive). Today's override wins, then
--- the holiday template on a holiday, then the weekly list.
--- @return string|nil id, string|nil scope
function Engine:findBlockByName(slot, name, epoch)
  local zs = self.doc.zones[slot]
  if zs == nil then
    return nil
  end
  local mo = self:moment(epoch)
  local wanted = cleanName(name):lower()
  local order = {}
  if zs.today.date == mo.date then
    order[#order + 1] = { "today", zs.today.blocks }
  end
  if self.holidaySet[mo.date] then
    order[#order + 1] = { "holiday", zs.holiday }
  end
  order[#order + 1] = { "week", zs.week }
  order[#order + 1] = { "holiday", zs.holiday }
  for _, entry in ipairs(order) do
    for _, b in ipairs(entry[2]) do
      if b.name:lower() == wanted then
        return b.id, entry[1]
      end
    end
  end
  return nil
end

--- Skips the next block in a zone (or every zone when slot is nil).
--- @return table skipped list of "Zone: block date from"
function Engine:skipNext(slot)
  local mo = self:moment()
  local out = {}
  for s = 1, M.MAX_ZONES do
    if (slot == nil or slot == s) and self.zones[s] ~= nil then
      local nxt = self:nextBlock(s, mo)
      if nxt ~= nil then
        self.skips[s] = self.skips[s] or {}
        self.skips[s][nxt.key] = true
        out[#out + 1] = { slot = s, name = nxt.block.name, date = nxt.date, from = nxt.from }
      end
    end
  end
  return out
end

--- Drops what can no longer matter: a past "today only" override, old
--- holiday dates, old skips.
function Engine:prune(mo)
  for slot = 1, M.MAX_ZONES do
    local zs = self.doc.zones[slot]
    if zs.today.date ~= "" and zs.today.date < M.dateString(mo.day - 1) then
      zs.today = { date = "", blocks = {} }
    end
    for key in pairs(self.skips[slot] or {}) do
      if key:sub(1, 10) < M.dateString(mo.day - 1) then
        self.skips[slot][key] = nil
      end
    end
  end
  local keep, changed = {}, false
  for _, d in ipairs(self.doc.holidays) do
    if d >= M.dateString(mo.day - 1) then
      keep[#keep + 1] = d
    else
      changed = true
    end
  end
  if changed then
    self.doc.holidays = keep
    rebuildHolidaySet(self)
  end
end

-- Editing ----------------------------------------------------------------

local function listFor(self, slot, scope, mo)
  local zs = self.doc.zones[slot]
  if scope == "week" then
    return zs.week
  elseif scope == "holiday" then
    return zs.holiday
  end
  if zs.today.date ~= mo.date then
    zs.today = { date = mo.date, blocks = {} }
  end
  return zs.today.blocks
end

local function checkEdit(self, slot, scope)
  if self.readOnly then
    return "The schedule is read-only right now (SmartBuildOS licence). Nothing was changed."
  end
  if self.zones[slot] == nil then
    return "That zone is not set up."
  end
  if not M.SCOPES[scope] then
    return "Unknown schedule."
  end
  return nil
end

--- Adds a block. @return table|nil result { block, warnings, summary }, string|nil err
function Engine:addBlock(slot, scope, spec)
  local err = checkEdit(self, slot, scope)
  if err then
    return nil, err
  end
  local block, warnings = M.normalizeBlock(spec, self.zones[slot], scope)
  if block == nil then
    return nil, warnings
  end
  local list = listFor(self, slot, scope, self:moment())
  if #list >= M.MAX_BLOCKS then
    return nil, "This schedule is full (" .. M.MAX_BLOCKS .. " blocks). Remove one first."
  end
  local other, day = M.findOverlap(list, block, scope, nil)
  if other ~= nil then
    return nil, overlapMessage(other, day)
  end
  block.id = "b" .. tostring(self.doc.nextId)
  self.doc.nextId = self.doc.nextId + 1
  list[#list + 1] = block
  return {
    block = copy(block),
    warnings = warnings,
    summary = "added " .. M.describeBlock(block) .. " (" .. scope .. ")",
  }
end

function Engine:updateBlock(slot, scope, id, spec)
  local err = checkEdit(self, slot, scope)
  if err then
    return nil, err
  end
  local list = listFor(self, slot, scope, self:moment())
  local index
  for i, b in ipairs(list) do
    if b.id == id then
      index = i
    end
  end
  if index == nil then
    return nil, "That block no longer exists. Refresh the page."
  end
  spec = copy(spec or {})
  spec.id = id
  local block, warnings = M.normalizeBlock(spec, self.zones[slot], scope)
  if block == nil then
    return nil, warnings
  end
  local other, day = M.findOverlap(list, block, scope, id)
  if other ~= nil then
    return nil, overlapMessage(other, day)
  end
  local before = list[index]
  list[index] = block
  return {
    block = copy(block),
    warnings = warnings,
    summary = "changed " .. M.describeBlock(before) .. " to " .. M.describeBlock(block) .. " (" .. scope .. ")",
  }
end

function Engine:deleteBlock(slot, scope, id)
  local err = checkEdit(self, slot, scope)
  if err then
    return nil, err
  end
  local list = listFor(self, slot, scope, self:moment())
  for i, b in ipairs(list) do
    if b.id == id then
      table.remove(list, i)
      if scope == "today" and #list == 0 then
        self.doc.zones[slot].today = { date = "", blocks = {} }
      end
      return { summary = "removed " .. M.describeBlock(b) .. " (" .. scope .. ")" }
    end
  end
  return nil, "That block no longer exists. Refresh the page."
end

--- Removes the whole "today only" override of a zone.
function Engine:clearToday(slot)
  local err = checkEdit(self, slot, "today")
  if err then
    return nil, err
  end
  self.doc.zones[slot].today = { date = "", blocks = {} }
  return { summary = "cleared today's override" }
end

--- Replaces the holiday date list.
function Engine:setHolidays(dates)
  if self.readOnly then
    return nil, "The schedule is read-only right now (SmartBuildOS licence). Nothing was changed."
  end
  if type(dates) ~= "table" then
    return nil, "Holidays must be a list of dates."
  end
  local seen, list = {}, {}
  for _, d in ipairs(dates) do
    d = trim(d)
    if M.parseDate(d) == nil then
      return nil, string.format('"%s" is not a valid date (use YYYY-MM-DD).', d)
    end
    if not seen[d] then
      seen[d] = true
      list[#list + 1] = d
    end
  end
  if #list > M.MAX_HOLIDAYS then
    return nil, "Too many holiday dates (" .. M.MAX_HOLIDAYS .. " at most)."
  end
  table.sort(list)
  self.doc.holidays = list
  rebuildHolidaySet(self)
  return { summary = "holidays now " .. (#list > 0 and table.concat(list, ", ") or "none") }
end

-- Persistence ------------------------------------------------------------

function Engine:serialize()
  return { v = 1, schedule = copy(self.doc), run = copy(self.run), skips = copy(self.skips), manualSeq = self.manualSeq }
end

--- The schedule alone, for a backup or a hand-over.
function Engine:exportSchedule()
  return copy(self.doc)
end

--- Rebuilds a block list leniently (shape only): a stored block that no
--- longer parses is dropped, never repaired into something else.
local function sanitizeList(list, scope)
  local out, dropped = {}, 0
  for _, b in ipairs(type(list) == "table" and list or {}) do
    local ok = type(b) == "table"
      and type(b.id) == "string"
      and cleanName(b.name) ~= ""
      and M.parseTime(b.from) ~= nil
      and M.parseTime(b.to, true) ~= nil
      and M.parseTime(b.from) ~= M.parseTime(b.to, true)
    if ok and scope == "week" then
      ok = type(b.days) == "table" and #b.days > 0
    end
    if ok and #out < M.MAX_BLOCKS then
      out[#out + 1] = copy(b)
    else
      dropped = dropped + 1
    end
  end
  return out, dropped
end

--- @return number dropped how many stored blocks could not be read
function Engine:restore(stored)
  local dropped = 0
  if type(stored) ~= "table" or type(stored.schedule) ~= "table" then
    return 0
  end
  local doc = emptyDoc()
  local src = stored.schedule
  doc.nextId = tonumber(src.nextId) or 1
  for slot = 1, M.MAX_ZONES do
    local z = type(src.zones) == "table" and (src.zones[slot] or src.zones[tostring(slot)]) or nil
    if type(z) == "table" then
      local n
      doc.zones[slot].week, n = sanitizeList(z.week, "week")
      dropped = dropped + n
      doc.zones[slot].holiday, n = sanitizeList(z.holiday, "holiday")
      dropped = dropped + n
      if type(z.today) == "table" and M.parseDate(z.today.date) ~= nil then
        doc.zones[slot].today.date = z.today.date
        doc.zones[slot].today.blocks, n = sanitizeList(z.today.blocks, "today")
        dropped = dropped + n
      end
    end
  end
  for _, d in ipairs(type(src.holidays) == "table" and src.holidays or {}) do
    if M.parseDate(d) ~= nil and #doc.holidays < M.MAX_HOLIDAYS then
      doc.holidays[#doc.holidays + 1] = d
    end
  end
  self.doc = doc
  rebuildHolidaySet(self)
  self.run, self.skips = {}, {}
  for slot = 1, M.MAX_ZONES do
    local r = type(stored.run) == "table" and (stored.run[slot] or stored.run[tostring(slot)]) or nil
    if type(r) == "table" and type(r.key) == "string" then
      self.run[slot] = copy(r)
    end
    local s = type(stored.skips) == "table" and (stored.skips[slot] or stored.skips[tostring(slot)]) or nil
    if type(s) == "table" then
      self.skips[slot] = copy(s)
    end
  end
  self.manualSeq = tonumber(stored.manualSeq) or 0
  self:invalidateRuntime()
  return dropped
end

-- View -------------------------------------------------------------------

--- Everything the schedule page shows, as plain tables.
function Engine:view(epoch)
  local mo = self:moment(epoch)
  local zones = {}
  for slot = 1, M.MAX_ZONES do
    local z = self.zones[slot]
    if z ~= nil then
      local zs = self.doc.zones[slot]
      local active = self:resolve(slot, mo)
      local nxt = self:nextBlock(slot, mo)
      local labels = {}
      for _, d in ipairs(z.displays or {}) do
        labels[#labels + 1] = d.label
      end
      zones[#zones + 1] = {
        slot = slot,
        name = z.name,
        sources = copy(z.sources or {}),
        min = z.min,
        max = z.max,
        displays = labels,
        week = copy(zs.week),
        holiday = copy(zs.holiday),
        today = {
          date = zs.today.date == mo.date and zs.today.date or "",
          blocks = zs.today.date == mo.date and copy(zs.today.blocks) or {},
        },
        current = active and {
          name = active.block.name,
          from = active.block.from,
          to = active.block.to,
          from_scope = active.source,
        } or nil,
        next = nxt and { name = nxt.block.name, date = nxt.date, from = nxt.from, in_days = nxt.in_days } or nil,
      }
    end
  end
  return {
    today = mo.date,
    minute = mo.minute,
    weekday = M.isoWeekday(mo.day),
    holidays = copy(self.doc.holidays),
    zones = zones,
  }
end

--- Is today a holiday date?
function Engine:isHoliday(epoch)
  return self.holidaySet[self:moment(epoch).date] == true
end

return M
