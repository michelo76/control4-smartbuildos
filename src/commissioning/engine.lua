--[[==========================================================================
  Commissioning Matrix - pure rules (no controller needed).

  Three jobs:
    1. Build the test list: classify project devices into light / shade /
       AV zone / sensor, group them by room, merge the dealer's manual items.
    2. Run a guided pass: a run holds one result per item; an item is acted
       on, read back, then judged by a person (Pass / Fail / Skip). Sensors
       run the other way round: armed, and passed when their variable moves.
    3. Produce the as-built record (a plain table; the driver encodes it as
       JSON) and keep a few past runs.

  Honest by construction: what is stored under `readback` is what the DEVICE
  REPORTED. `reported` says whether that agreed with what was asked
  (match / mismatch / unreported). The Pass tap is the technician's word that
  the lamp lit or the shade moved; the engine never turns a readback into a
  pass by itself, except for a sensor whose variable changed.

  Everything outside the engine is injected (`deps`): the actuation layer
  (src/commissioning/actuate.lua), the clock, timers, event sink.
============================================================================]]

local M = {}

M.SCHEMA = "commissioning.run.v1"
M.CHANNEL = "commissioning"
M.HISTORY_KEEP = 5
M.NOTE_MAX = 300

M.KIND_ORDER = { light = 1, shade = 2, av = 3, sensor = 4 }
M.KIND_LABEL = { light = "Light", shade = "Shade", av = "AV zone", sensor = "Sensor" }

local FINAL = { passed = true, failed = true, skipped = true }
--- Not yet judged (the run is not complete while any item is in one of these).
local OPEN = { pending = true, testing = true, awaiting = true, armed = true }
M.FINAL = FINAL

local function trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function isoUtc(t)
  return os.date("!%Y-%m-%dT%H:%M:%SZ", math.floor(t))
end

-- ─── Test list ──────────────────────────────────────────────────────────────

--- What a project device is, from its driver file name. nil = not testable.
--- Sensors first: a "lightsensor" or a "contact" must not become a light.
--- @param driverFile string|nil
--- @return string|nil kind light|shade|av|sensor
function M.classify(driverFile)
  local f = tostring(driverFile or ""):lower():gsub("%.c4[iz]$", "")
  if f == "" then
    return nil
  end
  for _, word in ipairs({ "sensor", "contact", "motion", "occupancy" }) do
    if f:find(word, 1, true) then
      return "sensor"
    end
  end
  for _, word in ipairs({ "blind", "shade", "drape" }) do
    if f:find(word, 1, true) then
      return "shade"
    end
  end
  -- Boundary match: "flight" (the Flight Recorder) must not become a light.
  if ("_" .. f):find("[^%a]light") or ("_" .. f):find("[^%a]dimmer") then
    return "light"
  end
  if f == "roomdevice" or f:find("^control4_room") or f:find("^room") then
    return "av"
  end
  return nil
end

M.UNASSIGNED = "Unassigned"

function M.itemKey(kind, id)
  return tostring(kind) .. ":" .. tostring(id)
end

--- The text a DYNAMIC_LIST shows for a device: `Name (Room) · id`.
--- Commas are the list separator, so they are taken out of the label.
function M.listLabel(name, room, id)
  local n = trim(tostring(name or ""):gsub(",", " "))
  local r = trim(tostring(room or ""):gsub(",", " "))
  if r == "" then
    return string.format("%s · %s", n, tostring(id))
  end
  return string.format("%s (%s) · %s", n, r, tostring(id))
end

--- Reads a list label back. Returns { id, name, room } or nil.
function M.parseListEntry(text)
  text = trim(text)
  if text == "" or text == "-" then
    return nil
  end
  local name, room, id = text:match("^(.*)%s+%(([^()]*)%)%s+·%s+(%d+)$")
  if name == nil then
    name, id = text:match("^(.-)%s+·%s+(%d+)$")
    room = ""
  end
  if id == nil then
    return nil
  end
  return { id = tonumber(id), name = trim(name), room = trim(room) }
end

--- A kind a dealer typed, or nil for "auto-detect".
function M.kindFromChoice(choice)
  local c = trim(choice):lower()
  if c == "light" then
    return "light"
  elseif c == "shade" then
    return "shade"
  elseif c:find("^av") then
    return "av"
  elseif c == "sensor" then
    return "sensor"
  end
  return nil
end

--- Builds the test list.
--- @param devices table id -> { deviceName, roomName, driverFileName }
--- @param opts table { manual = { {id,name,room,kind,source} }, av_source = number|nil }
--- @return table[] items sorted by room, kind, name
function M.buildList(devices, opts)
  opts = opts or {}
  local byKey, items = {}, {}
  local function add(item)
    if byKey[item.key] == nil then
      byKey[item.key] = item
      items[#items + 1] = item
    else
      -- A manual entry refines an automatic one (a better room or name).
      for k, v in pairs(item) do
        if v ~= nil and v ~= "" then
          byKey[item.key][k] = v
        end
      end
    end
  end
  for rawId, d in pairs(devices or {}) do
    local id = tonumber(rawId)
    local kind = id and type(d) == "table" and M.classify(d.driverFileName) or nil
    if kind ~= nil and not (kind == "av" and opts.av_source == nil) then
      local room = trim(d.roomName)
      add({
        key = M.itemKey(kind, id),
        device_id = id,
        name = trim(d.deviceName) ~= "" and trim(d.deviceName) or ("Device " .. id),
        room = room ~= "" and room or M.UNASSIGNED,
        kind = kind,
        source = kind == "av" and opts.av_source or nil,
        origin = "auto",
      })
    end
  end
  for _, m in ipairs(opts.manual or {}) do
    local id = tonumber(m.id)
    local kind = m.kind
    if kind == nil and devices and devices[id] then
      kind = M.classify(devices[id].driverFileName)
    end
    if id ~= nil and kind ~= nil and M.KIND_ORDER[kind] then
      local room = trim(m.room)
      if room == "" and devices and devices[id] then
        room = trim(devices[id].roomName)
      end
      add({
        key = M.itemKey(kind, id),
        device_id = id,
        name = trim(m.name) ~= "" and trim(m.name) or ("Device " .. id),
        room = room ~= "" and room or M.UNASSIGNED,
        kind = kind,
        source = kind == "av" and (tonumber(m.source) or opts.av_source) or nil,
        origin = "manual",
      })
    end
  end
  table.sort(items, function(a, b)
    if a.room ~= b.room then
      return a.room:lower() < b.room:lower()
    end
    if a.kind ~= b.kind then
      return M.KIND_ORDER[a.kind] < M.KIND_ORDER[b.kind]
    end
    if a.name:lower() ~= b.name:lower() then
      return a.name:lower() < b.name:lower()
    end
    return a.device_id < b.device_id
  end)
  return items
end

-- ─── Run state machine ──────────────────────────────────────────────────────

local Engine = {}
Engine.__index = Engine

--- @param deps table {
---   now = fun():number
---   schedule = fun(ms, fn)            -- one-shot timer (a test pins it)
---   actuator = table                  -- see src/commissioning/actuate.lua
---   emit = fun(kind, fields)|nil      -- run_started item_failed room_passed run_completed run_aborted
---   settle_ms = number|nil            -- wait between acting and reading back (default 4000)
---   watch = fun(item):table|nil       -- sensors: { id, name, value } of the state variable
---   unwatch = fun(item)|nil
--- }
function M.new(deps)
  local self = setmetatable({}, Engine)
  self.deps = deps or {}
  self.items = {}
  self.run = nil
  self.history = {}
  self.last_signed = nil
  self.seq = 0
  return self
end

function Engine:_now()
  return (self.deps.now or os.time)()
end

function Engine:_emit(kind, fields)
  if self.deps.emit ~= nil then
    pcall(self.deps.emit, kind, fields or {})
  end
end

function Engine:setItems(items)
  self.items = items or {}
end

--- Rooms of the list in order, with how many items each holds.
function Engine:rooms()
  local out, seen = {}, {}
  for _, it in ipairs(self.items) do
    if seen[it.room] == nil then
      seen[it.room] = { name = it.room, count = 0 }
      out[#out + 1] = seen[it.room]
    end
    seen[it.room].count = seen[it.room].count + 1
  end
  return out
end

function Engine:active()
  return self.run ~= nil and (self.run.status == "running" or self.run.status == "complete")
end

function Engine:status()
  return self.run and self.run.status or "idle"
end

local function newResult(item)
  return {
    key = item.key,
    device_id = item.device_id,
    name = item.name,
    room = item.room,
    kind = item.kind,
    source = item.source,
    status = "pending",
    attempts = 0,
  }
end

--- Starts a run over the whole list, or over one room.
--- @param opts table { scope = room name|nil, technician = string|nil }
--- @return boolean ok, string|nil why
function Engine:startRun(opts)
  opts = opts or {}
  if self:active() then
    return false, "a run is already in progress (abort it or sign it off first)"
  end
  local scope = opts.scope ~= nil and trim(opts.scope) or nil
  if scope == "" then
    scope = nil
  end
  local results, rooms, seen = {}, {}, {}
  for _, it in ipairs(self.items) do
    if scope == nil or it.room:lower() == scope:lower() then
      results[#results + 1] = newResult(it)
      if not seen[it.room] then
        seen[it.room] = true
        rooms[#rooms + 1] = it.room
      end
    end
  end
  if #results == 0 then
    if scope ~= nil then
      return false, "no test items in room '" .. scope .. "'"
    end
    return false, "the test list is empty (add devices or items first)"
  end
  self.seq = self.seq + 1
  local t = self:_now()
  self.run = {
    id = string.format("run-%d-%d", math.floor(t), self.seq),
    status = "running",
    started = t,
    technician = trim(opts.technician),
    scope = scope or "all",
    rooms = rooms,
    current_room = (scope ~= nil) and rooms[1] or nil,
    results = results,
    room_passed = {},
  }
  self:_emit("run_started", { run_id = self.run.id, scope = self.run.scope })
  return true
end

--- Makes a room the one being worked on. Starts a run scoped to that room
--- when none is in progress.
function Engine:selectRoom(room)
  room = trim(room)
  if room == "" then
    return false, "no room named"
  end
  if not self:active() then
    local ok, why = self:startRun({ scope = room })
    if not ok then
      return false, why
    end
  end
  for _, r in ipairs(self.run.rooms) do
    if r:lower() == room:lower() then
      self.run.current_room = r
      return true
    end
  end
  return false, "room '" .. room .. "' is not part of this run"
end

function Engine:_result(key)
  if self.run == nil then
    return nil
  end
  for _, r in ipairs(self.run.results) do
    if r.key == key then
      return r
    end
  end
  return nil
end

function Engine:_item(key)
  for _, it in ipairs(self.items) do
    if it.key == key then
      return it
    end
  end
  return nil
end

local function stamp(self, r, field)
  r[field] = self:_now()
end

--- Acts on one item and reads it back; the item then waits for a verdict.
--- A sensor is armed instead: it passes when its variable changes.
--- @return boolean ok, string|nil why
function Engine:test(key)
  if not self:active() then
    return false, "no run in progress"
  end
  local r = self:_result(key)
  local item = self:_item(key)
  if r == nil or item == nil then
    return false, "unknown item"
  end
  if r.status == "testing" then
    return false, "already being tested"
  end
  local adapter = self.deps.actuator and self.deps.actuator.adapter(item.kind)
  if adapter == nil then
    return false, "nothing can test a " .. tostring(item.kind)
  end
  if adapter.validate then
    local ok, why = adapter.validate(item)
    if not ok then
      return false, why
    end
  end
  -- A retest starts clean but remembers it was retried.
  r.attempts = r.attempts + 1
  r.readback, r.reported, r.detail, r.note = nil, nil, nil, r.note
  r.tested_at, r.judged_at, r.auto = nil, nil, nil
  r.passed_despite_mismatch = nil
  stamp(self, r, "started_at")
  if self.run.status == "complete" then
    self.run.status = "running"
  end

  if item.kind == "sensor" then
    local watch = self.deps.watch and self.deps.watch(item) or nil
    if watch ~= nil then
      r.status = "armed"
      r.baseline = { variable = watch.name, value = watch.value, var_id = watch.id }
      r.prompt = adapter.prompt
    else
      r.status = "awaiting"
      r.reported = "unreported"
      r.detail = "this sensor exposes no state variable the driver recognises; judge it by hand"
      r.prompt = adapter.prompt
    end
    return true
  end

  local vars = self.deps.actuator.read(item)
  r.baseline = adapter.baseline(vars or {})
  r.status = "testing"
  r.prompt = adapter.prompt
  local attempt = r.attempts
  local settle = (tonumber(self.deps.settle_ms) or 4000) * (adapter.settle_factor or 1)
  local function stale()
    return r.attempts ~= attempt or r.status ~= "testing" or self.run == nil
  end
  self.deps.actuator.send(item, adapter.steps(item, "act", r.baseline, self.deps.options))
  self.deps.schedule(settle, function()
    if stale() then
      return
    end
    local act = adapter.read(self.deps.actuator.read(item) or {})
    local reported, detail = adapter.check("act", act, r.baseline, item)
    r.readback = { act = act }
    r.reported, r.detail = reported, detail
    self.deps.actuator.send(item, adapter.steps(item, "restore", r.baseline, self.deps.options))
    self.deps.schedule(settle, function()
      if stale() then
        return
      end
      local back = adapter.read(self.deps.actuator.read(item) or {})
      r.readback.restore = back
      local rr, rd = adapter.check("restore", back, r.baseline, item)
      if rr == "mismatch" then
        r.reported = "mismatch"
        r.detail = (r.detail and (r.detail .. "; ") or "") .. rd
      end
      stamp(self, r, "tested_at")
      r.status = "awaiting"
      self:_emit("item_ready", { key = r.key, reported = r.reported })
    end)
  end)
  return true
end

--- Rolls up after any change: room passed? run complete?
function Engine:_settle(r)
  local run = self.run
  local roomOpen, roomFailed, roomPassed = false, false, 0
  local anyOpen = false
  for _, x in ipairs(run.results) do
    if OPEN[x.status] then
      anyOpen = true
    end
    if x.room == r.room then
      if OPEN[x.status] then
        roomOpen = true
      elseif x.status == "failed" then
        roomFailed = true
      elseif x.status == "passed" then
        roomPassed = roomPassed + 1
      end
    end
  end
  if not roomOpen and not roomFailed and roomPassed > 0 and not run.room_passed[r.room] then
    run.room_passed[r.room] = true
    self:_emit("room_passed", { room = r.room, run_id = run.id })
  elseif roomFailed or roomOpen then
    run.room_passed[r.room] = nil
  end
  if not anyOpen and run.status == "running" then
    run.status = "complete"
  end
end

local function finish(self, r, status, note, auto)
  if self.deps.unwatch and r.status == "armed" then
    local item = self:_item(r.key)
    if item then
      pcall(self.deps.unwatch, item)
    end
  end
  r.status = status
  stamp(self, r, "judged_at")
  r.auto = auto or nil
  if note ~= nil then
    r.note = trim(note):sub(1, M.NOTE_MAX)
    if r.note == "" then
      r.note = nil
    end
  end
  self:_emit("item_judged", { key = r.key, name = r.name, room = r.room, status = status, note = r.note, auto = auto })
  if status == "failed" then
    self:_emit("item_failed", { key = r.key, name = r.name, room = r.room, note = r.note })
  end
  self:_settle(r)
end

--- The technician's verdict.
--- @param verdict string pass | fail | skip
function Engine:mark(key, verdict, note)
  if self.run == nil or (self.run.status ~= "running" and self.run.status ~= "complete") then
    return false, "no run in progress"
  end
  local r = self:_result(key)
  if r == nil then
    return false, "unknown item"
  end
  verdict = trim(verdict):lower()
  if verdict == "pass" then
    if r.status ~= "awaiting" then
      return false, "test the item first (a pass needs a test to judge)"
    end
    if r.reported == "mismatch" then
      r.passed_despite_mismatch = true
    end
    finish(self, r, "passed", note)
  elseif verdict == "fail" then
    if r.status == "failed" then
      return false, "already failed"
    end
    finish(self, r, "failed", note)
  elseif verdict == "skip" then
    finish(self, r, "skipped", note)
  else
    return false, "verdict must be pass, fail or skip"
  end
  if self.run.status == "complete" and self:_hasOpen() then
    self.run.status = "running"
  end
  return true
end

function Engine:_hasOpen()
  for _, x in ipairs(self.run.results) do
    if OPEN[x.status] then
      return true
    end
  end
  return false
end

--- A watched sensor variable changed. Returns true when it passed an item.
function Engine:sensorChanged(deviceId, varName, value)
  if self.run == nil or self.run.status ~= "running" then
    return false
  end
  deviceId = tonumber(deviceId)
  for _, r in ipairs(self.run.results) do
    if r.status == "armed" and r.kind == "sensor" and r.device_id == deviceId then
      local before = r.baseline and r.baseline.value
      if tostring(value) ~= tostring(before) and (varName == nil or varName == r.baseline.variable) then
        r.readback = { before = before, after = value, variable = r.baseline.variable }
        r.reported = "match"
        r.detail = "the sensor's state variable changed"
        stamp(self, r, "tested_at")
        finish(self, r, "passed", nil, true)
        return true
      end
    end
  end
  return false
end

--- Gives up on the run; keeps it in the history as aborted.
function Engine:abort()
  if self.run == nil or not self:active() then
    return false, "no run in progress"
  end
  for _, r in ipairs(self.run.results) do
    if r.status == "armed" and self.deps.unwatch then
      local item = self:_item(r.key)
      if item then
        pcall(self.deps.unwatch, item)
      end
    end
    if r.status == "testing" or r.status == "armed" then
      r.status = "pending"
    end
  end
  self.run.status = "aborted"
  self.run.finished = self:_now()
  self:_remember(self:record())
  self:_emit("run_aborted", { run_id = self.run.id })
  return true
end

function Engine:_remember(record)
  table.insert(self.history, 1, record)
  while #self.history > M.HISTORY_KEEP do
    table.remove(self.history)
  end
end

--- Signs the finished run off. Everything must be judged first.
function Engine:signOff(who)
  if self.run == nil or self.run.status ~= "complete" then
    local open = 0
    if self.run then
      for _, r in ipairs(self.run.results) do
        if OPEN[r.status] then
          open = open + 1
        end
      end
    end
    if self.run ~= nil and open > 0 then
      return false, string.format("%d item(s) still need a verdict", open)
    end
    return false, "no finished run to sign off"
  end
  who = trim(who)
  if who == "" then
    who = self.run.technician
  end
  if who == "" then
    return false, "say who is signing off"
  end
  self.run.status = "signed_off"
  self.run.finished = self:_now()
  self.run.signed_by = who
  local rec = self:record()
  self.last_signed = rec
  self:_remember(rec)
  self:_emit("run_completed", { run_id = self.run.id, record = rec })
  return true, rec
end

function Engine:counts()
  local c = { passed = 0, failed = 0, skipped = 0, pending = 0, total = 0 }
  if self.run == nil then
    return c
  end
  for _, r in ipairs(self.run.results) do
    c.total = c.total + 1
    if r.status == "passed" then
      c.passed = c.passed + 1
    elseif r.status == "failed" then
      c.failed = c.failed + 1
    elseif r.status == "skipped" then
      c.skipped = c.skipped + 1
    else
      c.pending = c.pending + 1
    end
  end
  return c
end

function Engine:hasFailures()
  return self:counts().failed > 0
end

function Engine:currentRoom()
  return self.run and self.run.current_room or nil
end

--- The failed results of the current run, for the programming surface.
function Engine:failures()
  local out = {}
  for _, r in ipairs(self.run and self.run.results or {}) do
    if r.status == "failed" then
      out[#out + 1] = r
    end
  end
  return out
end

--- The as-built record of the current (or last) run, a plain table.
--- @param run table|nil defaults to the current run
function Engine:record(run)
  run = run or self.run
  if run == nil then
    return nil
  end
  local counts = { passed = 0, failed = 0, skipped = 0, pending = 0, total = 0 }
  local rooms, byRoom = {}, {}
  for _, r in ipairs(run.results) do
    counts.total = counts.total + 1
    if r.status == "passed" or r.status == "failed" or r.status == "skipped" then
      counts[r.status] = counts[r.status] + 1
    else
      counts.pending = counts.pending + 1
    end
    local room = byRoom[r.room]
    if room == nil then
      room = { name = r.room, items = {} }
      byRoom[r.room] = room
      rooms[#rooms + 1] = room
    end
    room.items[#room.items + 1] = {
      key = r.key,
      device_id = r.device_id,
      name = r.name,
      kind = r.kind,
      status = r.status,
      attempts = r.attempts,
      tested_at = r.tested_at and isoUtc(r.tested_at) or nil,
      judged_at = r.judged_at and isoUtc(r.judged_at) or nil,
      readback = r.readback,
      reported = r.reported,
      detail = r.detail,
      auto = r.auto,
      passed_despite_mismatch = r.passed_despite_mismatch,
      note = r.note,
    }
  end
  for _, room in ipairs(rooms) do
    local failed, open, passed = false, false, 0
    for _, it in ipairs(room.items) do
      if it.status == "failed" then
        failed = true
      elseif it.status == "passed" then
        passed = passed + 1
      elseif not FINAL[it.status] then
        open = true
      end
    end
    room.result = failed and "failed" or (open and "incomplete" or (passed > 0 and "passed" or "skipped"))
  end
  return {
    schema = M.SCHEMA,
    run_id = run.id,
    status = run.status,
    scope = run.scope,
    started_at = isoUtc(run.started),
    finished_at = run.finished and isoUtc(run.finished) or nil,
    technician = run.technician ~= "" and run.technician or nil,
    signed_off_by = run.signed_by,
    counts = counts,
    rooms = rooms,
    honest_limits = "readback is what each device reported; a pass is the technician's confirmation; "
      .. "radio signal health is not measured",
  }
end

--- A text rendering of a record for the Lua output window.
function M.textLines(record)
  local out = {}
  if record == nil then
    return { "no run yet" }
  end
  out[#out + 1] = string.format(
    "run %s  %s  scope: %s  (%d passed, %d failed, %d skipped, %d open)",
    record.run_id,
    record.status,
    record.scope,
    record.counts.passed,
    record.counts.failed,
    record.counts.skipped,
    record.counts.pending
  )
  if record.signed_off_by then
    out[#out + 1] = "signed off by " .. record.signed_off_by .. " at " .. tostring(record.finished_at)
  end
  for _, room in ipairs(record.rooms) do
    out[#out + 1] = string.format("  %s: %s", room.name, room.result)
    for _, it in ipairs(room.items) do
      local extra = it.note and ("  note: " .. it.note) or ""
      if it.reported == "mismatch" then
        extra = extra .. "  [device reported something else]"
      end
      out[#out + 1] = string.format("    %-8s %-30s %s%s", it.status, it.name, M.KIND_LABEL[it.kind] or it.kind, extra)
    end
  end
  return out
end

-- ─── Persistence ────────────────────────────────────────────────────────────

--- A plain table for lib.persist.
function Engine:serialize()
  return {
    v = 1,
    seq = self.seq,
    run = self.run,
    history = self.history,
    last_signed = self.last_signed,
  }
end

--- Restores a serialized state. Anything mid-flight when the controller went
--- down (testing, armed) goes back to pending: its timers are gone.
function Engine:restore(state)
  if type(state) ~= "table" then
    return
  end
  self.seq = tonumber(state.seq) or 0
  self.history = type(state.history) == "table" and state.history or {}
  self.last_signed = type(state.last_signed) == "table" and state.last_signed or nil
  local run = state.run
  if type(run) == "table" and type(run.results) == "table" then
    for _, r in ipairs(run.results) do
      if r.status == "testing" or r.status == "armed" then
        r.status = "pending"
      end
    end
    run.room_passed = type(run.room_passed) == "table" and run.room_passed or {}
    self.run = run
  end
end

return M
