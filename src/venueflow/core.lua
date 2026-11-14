--- VenueFlow: the core. One control engine and one device registry behind
--- every screen (the four operator interfaces, Installer Studio, Composer
--- programming, schedules).
---
--- Everything here is pure over injected dependencies, so the same code runs
--- in the driver (real controller persistence, timers and adapter) and under
--- test or the development host (tables, a fake clock, the simulator).
---
--- TRUST: `handle(request, transport)` is the only way a page reaches the
--- engines. The identity behind a request comes from the session token the
--- driver minted, or from the tile token the driver put in the web view URL.
--- Nothing a page says about itself (a profile id, a role, a flag) is used.

local U = require("venueflow.util")
local Errors = require("venueflow.errors")
local Schema = require("venueflow.schema")
local Protocol = require("venueflow.protocol")
local Store = require("venueflow.store")
local State = require("venueflow.state")
local Queue = require("venueflow.queue")
local Tracker = require("venueflow.tracker")
local Routing = require("venueflow.routing")
local Audio = require("venueflow.audio")
local Rules = require("venueflow.rules")
local Scheduler = require("venueflow.scheduler")
local Access = require("venueflow.access")
local Auth = require("venueflow.auth")
local Diag = require("venueflow.diag")
local Discovery = require("venueflow.discovery")
local Sim = require("venueflow.sim")
local Templates = require("venueflow.templates")

local M = {}

M.RUNTIME_KEY = "vf_runtime_v1"
M.TICK_TIMER = "VfTick"
M.SAVE_TIMER = "VfSaveRuntime"
M.ONLINE_EVERY = 60
M.TRIGGER_COOLDOWN = 2
M.MAX_ALERTS = 30
M.MAX_DRAFT_BYTES = 600 * 1024

local Core = {}
Core.__index = Core

local fail = Errors.fail

--- deps = {
---   kv = { get, set, delete }      persistence
---   now(), localtime(epoch)        clock
---   timers = { set(id, ms, fn, repeating), cancel(id) }
---   json = { encode, decode }
---   hmac(key, data) -> hex, random() -> hex
---   liveAdapter() -> adapter       the Control4 adapter (driver only)
---   mode() -> "live" | "simulation"
---   license = { enforces(), label(), describe(), refresh() }
---   passcode() -> Installer Passcode
---   record(name, detail)?, fireEvent(key)?, setVariable(name, value)?, log?
---   info()? -> table shown on the Studio overview (relay address ...)
---   version?, queueSpacingMs?, confirmMs?, simLatencyMs?
--- }
function M.new(deps)
  local self = setmetatable({}, Core)
  self.deps = deps
  self.diag = Diag.new({
    now = deps.now,
    sink = function(entry)
      if deps.log and (entry.level == "error" or entry.level == "warning") then
        pcall(function()
          deps.log:warn(
            "VenueFlow %s %s: %s",
            tostring(entry.category),
            tostring(entry.code or ""),
            tostring(entry.message)
          )
        end)
      end
    end,
  })
  self.store = Store.new({
    kv = deps.kv,
    now = deps.now,
    hash = function(text)
      return deps.hmac("vf-image", text)
    end,
  })
  self.auth = Auth.new({ now = deps.now, hmac = deps.hmac, random = deps.random, passcode = deps.passcode }, {
    onLocked = function(kind)
      self.diag:add(
        "warning",
        "auth",
        "VF_LOCKED",
        "Too many wrong " .. kind .. " sign-in attempts; locked for a minute"
      )
    end,
  })
  self.state = State.new({ now = deps.now })
  self.queue = Queue.new({ timers = deps.timers, spacingMs = deps.queueSpacingMs or 120 })
  self.tracker = Tracker.new({
    timers = deps.timers,
    now = deps.now,
    state = self.state,
    queue = self.queue,
    confirmMs = deps.confirmMs,
    adapter = function()
      return self.adapter
    end,
    onSettled = function(op)
      self:_operationSettled(op)
    end,
    onTarget = function(op, target)
      self:_targetOutcome(op, target)
    end,
  })
  local engineDeps = {
    config = function()
      return self.config
    end,
    index = function()
      return self.ix
    end,
    state = self.state,
    tracker = self.tracker,
    adapter = function()
      return self.adapter
    end,
    sourceForDevice = function(deviceId)
      return self.deviceSource[deviceId or 0]
    end,
  }
  self.routing = Routing.new(engineDeps)
  self.audio = Audio.new(engineDeps)
  self.runner = Rules.newRunner({
    ops = self:_ops(),
    env = function(context)
      return self:_env(context)
    end,
    config = function()
      return self.config
    end,
    index = function()
      return self.ix
    end,
    timers = deps.timers,
    now = deps.now,
    onUpdate = function(exec)
      self:_executionUpdated(exec)
    end,
    onSceneRun = function(scene, exec)
      self:_fireRules(function(rule)
        return rule.trigger.type == "scene_activated" and rule.trigger.sceneId == scene.id
      end, "scene:" .. scene.id, exec.context)
    end,
  })
  self.runtime = {
    venueStatus = "closed",
    variables = {},
    lastFired = {},
    lastRun = {},
    lastSuccess = {},
    alerts = {},
    ruleLast = {},
  }
  self.scheduler = nil
  self.config = nil
  self.ix = nil
  self.deviceSource = {}
  self.online = {}
  self.tests = {}
  self.testSeq = 0
  self.alertSeq = 0
  self.restricted = false
  self.started = false
  self.state.onChange = function(kind, id, field, cell, previous)
    self:_stateChanged(kind, id, field, cell, previous)
  end
  return self
end

-- ─── Small helpers ──────────────────────────────────────────────────────────

function Core:_hook(name, ...)
  local fn = self.deps[name]
  if type(fn) == "function" then
    pcall(fn, ...)
  end
end

function Core:simulation()
  return self.deps.mode() == "simulation"
end

function Core:_saveRuntimeSoon()
  self.runtimeDirty = true
  self.deps.timers.set(M.SAVE_TIMER, 3000, function()
    self:saveRuntime()
  end)
end

function Core:saveRuntime()
  self.runtimeDirty = false
  local r = self.runtime
  pcall(self.deps.kv.set, M.RUNTIME_KEY, {
    venueStatus = r.venueStatus,
    variables = U.copy(r.variables),
    lastFired = U.copy(r.lastFired),
    lastRun = U.copy(r.lastRun),
    lastSuccess = U.copy(r.lastSuccess),
    activeScene = U.copy(r.activeScene),
  })
end

function Core:_alert(alert)
  self.alertSeq = self.alertSeq + 1
  alert.id = "a" .. self.alertSeq
  alert.at = self.deps.now()
  alert.stored = true
  table.insert(self.runtime.alerts, 1, alert)
  while #self.runtime.alerts > M.MAX_ALERTS do
    table.remove(self.runtime.alerts)
  end
  self.state:touch()
  self:_hook("setVariable", "ALERT_COUNT", #self.runtime.alerts)
  self:_hook("fireEvent", "alert")
  return alert
end

-- ─── Loading the published configuration ────────────────────────────────────

function Core:_mappedRooms()
  local seen, out = {}, {}
  local function add(id)
    if type(id) == "number" and not seen[id] then
      seen[id] = true
      out[#out + 1] = id
    end
  end
  for _, d in ipairs(self.config.displays) do
    add(d.c4RoomId)
  end
  for _, z in ipairs(self.config.audioZones) do
    add(z.c4RoomId)
  end
  return out
end

--- (Re)builds the registry, state and adapter from the published version.
function Core:load(reason)
  local deps = self.deps
  local previousSim = self.sim -- its device state is carried into the next one
  self.tracker:cancelAll("VF_CANCELLED")
  self.queue:clear()
  self.runner:cancelAll("VF_CANCELLED", "configuration changed")
  if self.adapter and self.adapter.unwatchVariables then
    pcall(self.adapter.unwatchVariables)
  end
  local published = self.store:published()
  if published == nil then
    self.config, self.ix, self.publishedMeta = nil, nil, nil
    if self:simulation() then
      -- Nothing published yet: a made-up project, plus whatever the draft
      -- already maps, so discovery and mapping can be rehearsed.
      self.sim = Sim.new({ timers = deps.timers, latencyMs = deps.simLatencyMs })
      local draft = self.store:draft()
      if draft ~= nil then
        self.sim:populate(draft.config)
      end
      self.sim:demo()
      self.sim:inherit(previousSim)
      self.adapter = self.sim:adapter()
    else
      self.sim = nil
      self.adapter = deps.liveAdapter()
    end
    self.diag:add("info", "config", nil, "No published configuration yet (" .. tostring(reason) .. ")")
    self.state:touch()
    return false
  end
  local migrated, why = Schema.migrate(published.config)
  if migrated == nil then
    self.config, self.ix = nil, nil
    self.diag:add("error", "config", "VF_VALIDATION_FAILED", "Published configuration unreadable: " .. tostring(why))
    return false
  end
  -- The reference venues use invented Control4 ids. In Live mode those ids
  -- could belong to real devices, so a sample is never run live.
  if not self:simulation() and type(migrated.venue) == "table" and migrated.venue.sample == true then
    self.config, self.ix, self.publishedMeta = nil, nil, nil
    self.adapter = deps.liveAdapter()
    self.sampleBlocked = true
    self.diag:add(
      "error",
      "config",
      "VF_SIMULATION_ONLY",
      "The published configuration is a sample venue with invented Control4 ids. It cannot run in Live mode: build the real venue, or return to Simulation."
    )
    self.state:touch()
    return false
  end
  self.sampleBlocked = false
  self.config = Schema.normalize(migrated)
  self.ix = Schema.index(self.config)
  self.publishedMeta = { versionId = published.versionId, publishedAt = published.publishedAt, note = published.note }
  self.deviceSource = {}
  for _, s in ipairs(self.config.sources) do
    if s.c4DeviceId ~= nil and self.deviceSource[s.c4DeviceId] == nil then
      self.deviceSource[s.c4DeviceId] = s.id
    end
  end
  self.state:reset(self.config)
  if self:simulation() then
    self.sim = Sim.fromConfig(self.config, { timers = deps.timers, latencyMs = deps.simLatencyMs })
    self.sim:inherit(previousSim)
    self.adapter = self.sim:adapter()
  else
    self.sim = nil
    self.adapter = deps.liveAdapter()
  end
  -- Internal variables: keep values of those that still exist.
  local vars = {}
  for _, v in ipairs(self.config.variables) do
    local current = self.runtime.variables[v.id]
    if current == nil then
      current = v.initial
      if current == nil then
        current = v.type == "bool" and false or (v.type == "number" and 0 or "")
      end
    end
    vars[v.id] = current
  end
  self.runtime.variables = vars
  pcall(self.adapter.watchRooms, self:_mappedRooms(), function(roomId)
    self:_roomChanged(roomId)
  end)
  for _, rule in ipairs(self.config.rules) do
    local t = rule.trigger
    if rule.enabled ~= false and t.type == "c4_variable" then
      local ok, watched, err = pcall(self.adapter.watchVariable, t.deviceId, t.variable, function(_, _, value)
        self:_fireRules(function(r)
          return r.id == rule.id
        end, "c4_variable", { value = value }, true)
      end)
      if not ok or not watched then
        self.diag:add(
          "warning",
          "config",
          "VF_NOT_FOUND",
          "Rule '" .. tostring(rule.name) .. "' cannot watch its Control4 variable",
          { reason = tostring(err or watched) }
        )
      end
    end
  end
  self.scheduler = Scheduler.new({
    now = deps.now,
    localtime = deps.localtime,
    rules = function()
      return self.config and self.config.rules or {}
    end,
    lastFired = self.runtime.lastFired,
    fire = function(rule, stamp)
      self.diag:add("info", "scene", nil, "Schedule due: " .. tostring(rule.name) .. " (" .. stamp .. ")")
      self:_runRule(rule, "schedule")
    end,
    missed = function(rule, stamp)
      self.diag:add(
        "warning",
        "scene",
        "VF_CANCELLED",
        "Schedule missed while the driver was not running: " .. tostring(rule.name) .. " (" .. stamp .. ")"
      )
      self:_alert({
        level = "warning",
        title = "Missed schedule: " .. tostring(rule.name),
        detail = "Was due " .. stamp .. "; not run late.",
      })
    end,
    save = function()
      self:_saveRuntimeSoon()
    end,
  })
  self:refreshAll()
  self:_checkOnline()
  self.diag:add(
    "info",
    "config",
    nil,
    string.format(
      "Loaded %s (%s): %d displays, %d sources, %d zones, %d scenes [%s]",
      tostring(published.versionId),
      tostring(reason),
      #self.config.displays,
      #self.config.sources,
      #self.config.audioZones,
      #self.config.scenes,
      self:simulation() and "SIMULATION" or "live"
    )
  )
  self:_paintSurface()
  return true
end

function Core:_paintSurface()
  self:_hook("setVariable", "VENUE_STATUS", self.runtime.venueStatus)
  self:_hook("setVariable", "ACTIVE_SCENE", self.runtime.activeScene and self.runtime.activeScene.name or "")
end

function Core:start()
  local deps = self.deps
  local ok, stored = pcall(deps.kv.get, M.RUNTIME_KEY)
  if ok and type(stored) == "table" then
    self.runtime.venueStatus = stored.venueStatus == "open" and "open" or "closed"
    self.runtime.variables = type(stored.variables) == "table" and stored.variables or {}
    for _, key in ipairs({ "lastFired", "lastRun", "lastSuccess" }) do
      if type(stored[key]) == "table" then
        self.runtime[key] = stored[key]
      end
    end
    self.runtime.activeScene = type(stored.activeScene) == "table" and stored.activeScene or nil
  end
  self.diag:add("info", "driver", nil, "Core started, version " .. tostring(deps.version or "?"))
  self:load("start")
  self:licenseChanged()
  self.tickCount = 0
  deps.timers.set(M.TICK_TIMER, Scheduler.TICK_SECONDS * 1000, function()
    self:tick()
  end, true)
  self.started = true
end

function Core:stop()
  self.deps.timers.cancel(M.TICK_TIMER)
  self.deps.timers.cancel(M.SAVE_TIMER)
  self.runner:cancelAll("VF_CANCELLED", "driver stopping")
  self.tracker:cancelAll("VF_CANCELLED")
  self.queue:stop()
  self:saveRuntime()
  self.started = false
end

function Core:tick()
  self.tickCount = (self.tickCount or 0) + 1
  if self.scheduler and self.config and not self.restricted then
    local ok, err = pcall(function()
      self.scheduler:tick()
    end)
    if not ok then
      self.diag:add("error", "scene", "VF_INTERNAL", "Scheduler failed: " .. tostring(err))
    end
  elseif self.scheduler then
    self.scheduler.prev = nil -- no catch-up when schedules resume
  end
  if self.config and self.tickCount % math.max(1, math.floor(M.ONLINE_EVERY / Scheduler.TICK_SECONDS)) == 0 then
    self:_checkOnline()
  end
end

--- Simulation <-> Live changed in the driver's properties.
function Core:modeChanged()
  self.diag:add("info", "driver", nil, "Control mode is now " .. self.deps.mode())
  self.state:clear()
  self.online = {}
  self:load("mode changed")
end

-- ─── Feedback from Control4 ─────────────────────────────────────────────────

function Core:_applyRoom(roomId)
  local ok, room = pcall(self.adapter.readRoom, roomId)
  if not ok or type(room) ~= "table" then
    return false
  end
  local state, tracker = self.state, self.tracker
  for _, d in ipairs(self.config.displays) do
    if d.c4RoomId == roomId and d.feedback == "room" then
      if room.power ~= nil and not tracker:isActive("display", d.id, "power") then
        state:set("display", d.id, "power", room.power and "on" or "off", "confirmed")
      end
      if room.videoDevice ~= nil and not tracker:isActive("display", d.id, "source") then
        local sourceId = room.power ~= false and self.deviceSource[room.videoDevice] or nil
        state:set("display", d.id, "source", sourceId, "confirmed")
      end
    end
  end
  for _, z in ipairs(self.config.audioZones) do
    if z.c4RoomId == roomId and z.feedback == "room" then
      if room.power ~= nil and not tracker:isActive("zone", z.id, "power") then
        state:set("zone", z.id, "power", room.power and "on" or "off", "confirmed")
      end
      if room.audioDevice ~= nil and not tracker:isActive("zone", z.id, "source") then
        local sourceId = room.power ~= false and self.deviceSource[room.audioDevice] or nil
        state:set("zone", z.id, "source", sourceId, "confirmed")
      end
      if room.volume ~= nil and not tracker:isActive("zone", z.id, "volume") then
        state:set("zone", z.id, "volume", room.volume, "confirmed")
      end
      if room.muted ~= nil and not tracker:isActive("zone", z.id, "mute") then
        state:set("zone", z.id, "mute", room.muted, "confirmed")
      end
    end
  end
  return true
end

function Core:_roomChanged(roomId)
  if self.config == nil then
    return
  end
  self.tracker:roomChanged(roomId)
  self:_applyRoom(roomId)
end

--- Reads every mapped room once (start, publish, "Query Status").
function Core:refreshAll()
  if self.config == nil then
    return 0
  end
  local read = 0
  for _, roomId in ipairs(self:_mappedRooms()) do
    if self:_applyRoom(roomId) then
      read = read + 1
    end
  end
  return read
end

function Core:_checkOnline()
  if self.config == nil then
    return
  end
  local changed = false
  for _, d in ipairs(self.config.displays) do
    local value = nil
    if d.c4DeviceId ~= nil then
      local ok, online = pcall(self.adapter.deviceOnline, d.c4DeviceId)
      if ok then
        value = online
      end
    end
    if self.online[d.id] ~= value then
      if value == false then
        self.diag:add(
          "warning",
          "feedback",
          "VF_DEVICE_OFFLINE",
          "Display '" .. tostring(d.name) .. "' is reported offline"
        )
      elseif self.online[d.id] == false then
        self.diag:add("info", "feedback", nil, "Display '" .. tostring(d.name) .. "' is back online")
      end
      self.online[d.id] = value
      changed = true
    end
  end
  if changed then
    self.state:touch()
  end
end

function Core:_stateChanged(kind, id, field, cell, previous)
  if self.config == nil or (cell.status ~= "confirmed" and cell.status ~= "commanded") then
    return
  end
  if
    previous ~= nil
    and previous.value == cell.value
    and (previous.status == "confirmed" or previous.status == "commanded")
  then
    return
  end
  local entity = kind == "display" and "display" or (kind == "zone" and "zone" or nil)
  if entity == nil then
    return
  end
  local triggerField = field == "mute" and "muted" or field
  local value = cell.value
  self:_fireRules(function(rule)
    local t = rule.trigger
    if t.type ~= "device_state" or t.entity ~= entity or t.id ~= id or t.field ~= triggerField then
      return false
    end
    if t.equals == nil then
      return true
    end
    if triggerField == "muted" then
      return (value == true) == (t.equals == true or t.equals == "true")
    end
    return tostring(value) == tostring(t.equals)
  end, "device_state", nil, true)
end

function Core:_targetOutcome(op, target)
  if target.status == "failed" or target.status == "unknown" then
    local category = (op.kind == "route_video" or op.kind == "display_power") and "routing"
      or ((op.kind == "lighting" or op.kind == "shade") and "command" or "audio")
    self.diag:add(
      "warning",
      category,
      target.errorCode,
      string.format("%s: %s (%s)", tostring(op.label), tostring(target.name), tostring(target.status)),
      { operation = op.id, target = target.id, field = target.field, detail = target.detail, origin = op.origin }
    )
  end
end

function Core:_operationSettled(op)
  local s = op.summary
  self.diag:add(
    s.bad > 0 and "warning" or "info",
    "command",
    s.bad > 0 and "VF_NOT_CONFIRMED" or nil,
    string.format(
      "%s finished: %d confirmed, %d commanded, %d failed, %d unknown, %d superseded",
      tostring(op.label),
      s.confirmed,
      s.commanded,
      s.failed,
      s.unknown,
      s.superseded
    ),
    { operation = op.id, origin = op.origin }
  )
  self.runner:operationSettled(op.id, s, Tracker.publicOp(op, true).targets)
end

-- ─── Scenes, rules and the programming engine ───────────────────────────────

function Core:_ops()
  local core = self
  local function sys(opts)
    return {
      access = Access.system("program"),
      dry = opts.dry,
      origin = opts.origin,
      executionId = opts.executionId,
    }
  end
  local ops = {}
  function ops.displayPower(ids, power, opts)
    return core.routing:displayPower(ids, power, sys(opts))
  end
  function ops.routeVideo(sourceId, ids, opts)
    return core.routing:routeVideo(sourceId, ids, sys(opts))
  end
  function ops.routeAudio(zoneId, sourceId, opts)
    return core.audio:setSource(zoneId, sourceId, sys(opts))
  end
  function ops.volume(zoneId, level, opts)
    return core.audio:setVolume(zoneId, level, sys(opts))
  end
  function ops.mute(zoneId, muted, opts)
    return core.audio:setMute(zoneId, muted, sys(opts))
  end
  function ops.zonePower(zoneId, power, opts)
    return core.audio:power(zoneId, power, sys(opts))
  end
  function ops.lighting(lightingId, presetId, opts)
    return core.audio:lighting(lightingId, presetId, sys(opts))
  end
  function ops.shade(shadeId, action, opts)
    return core.audio:shade(shadeId, action, sys(opts))
  end
  function ops.setVariable(variableId, value, opts)
    local def = core.ix.variables[variableId]
    if def == nil then
      return fail("VF_NOT_FOUND", "unknown variable")
    end
    if opts.dry then
      return { ok = true, status = "planned" }
    end
    if def.type == "bool" then
      value = value == true or value == "true" or value == 1
    elseif def.type == "number" then
      value = tonumber(value) or 0
    else
      value = tostring(value)
    end
    core.runtime.variables[variableId] = value
    core.state:touch()
    core:_saveRuntimeSoon()
    return { ok = true, status = "ok" }
  end
  function ops.setVenueStatus(status, opts)
    if opts.dry then
      return { ok = true, status = "planned" }
    end
    core:setVenueStatus(status, opts.origin or "program")
    return { ok = true, status = "ok" }
  end
  function ops.notify(message, level, opts)
    if opts.dry then
      return { ok = true, status = "planned" }
    end
    core:_alert({
      level = level == "warning" and "warning" or "info",
      title = U.oneLine(message, 200),
      source = "scene",
    })
    core:_hook("setVariable", "NOTIFICATION_TEXT", U.oneLine(message, 200))
    core:_hook("fireEvent", "notification")
    core:_hook("record", "notification", U.oneLine(message, 200))
    return { ok = true, status = "ok" }
  end
  return ops
end

function Core:_env(context)
  local core = self
  return {
    context = context,
    venueStatus = function()
      return core.runtime.venueStatus
    end,
    localtime = function()
      return core.deps.localtime(core.deps.now())
    end,
    displayState = function(id)
      local e = core.state.display[id or ""]
      if e == nil then
        return nil
      end
      return { power = e.power.value, source = e.source.value }
    end,
    zoneState = function(id)
      local e = core.state.zone[id or ""]
      if e == nil then
        return nil
      end
      return { power = e.power.value, source = e.source.value, muted = e.mute.value }
    end,
    sourceAvailable = function(id)
      local s = core.ix.sources[id or ""]
      if s == nil or s.enabled == false or s.c4DeviceId == nil then
        return false
      end
      local ok, online = pcall(core.adapter.deviceOnline, s.c4DeviceId)
      return not (ok and online == false)
    end,
    variable = function(id)
      return core.runtime.variables[id or ""]
    end,
    c4Variable = function(deviceId, name)
      local ok, value = pcall(core.adapter.readVariable, deviceId, name)
      return ok and value or nil
    end,
  }
end

--- A newer run that changes the same devices stops the older one, and says so.
function Core:_stopOverlapping(touches, name)
  for _, exec in ipairs(self.runner:overlapping(touches)) do
    self.diag:add(
      "warning",
      "scene",
      "VF_SUPERSEDED",
      string.format("'%s' was stopped: '%s' started and changes the same devices", tostring(exec.name), tostring(name)),
      { execution = exec.id }
    )
    self:_alert({
      level = "warning",
      title = tostring(exec.name) .. " was interrupted",
      detail = "Stopped because " .. tostring(name) .. " started and changes the same devices.",
    })
    self.runner:cancel(exec.id, "VF_SUPERSEDED", name)
  end
end

function Core:_start(spec)
  if not spec.dryRun then
    spec.touches = Rules.touches(spec.program.steps, self.config, self.ix)
    self:_stopOverlapping(spec.touches, spec.name)
  end
  return self.runner:start(spec)
end

function Core:_runScene(scene, origin, context, dryRun)
  local exec = self:_start({
    kind = "scene",
    refId = scene.id,
    name = scene.name,
    program = scene.program,
    condition = scene.condition,
    origin = origin,
    context = context,
    dryRun = dryRun,
  })
  if not dryRun and exec.status ~= "skipped" then
    self.runtime.activeScene = { id = scene.id, name = scene.name, at = self.deps.now() }
    self:_saveRuntimeSoon()
    self.state:touch()
    self:_hook("setVariable", "ACTIVE_SCENE", scene.name)
    self:_hook("fireEvent", "scene_activated")
    self:_hook("record", "scene activated", tostring(scene.name) .. " (" .. tostring(origin) .. ")")
    self:_fireRules(function(rule)
      return rule.trigger.type == "scene_activated" and rule.trigger.sceneId == scene.id
    end, "scene:" .. scene.id, context)
  end
  return exec
end

function Core:_runRule(rule, origin, context)
  if self.restricted then
    self.diag:add(
      "warning",
      "license",
      "VF_LICENSE_RESTRICTED",
      "Rule '" .. tostring(rule.name) .. "' not run: licence restricted"
    )
    return nil
  end
  local exec = self:_start({
    kind = "rule",
    refId = rule.id,
    name = rule.name,
    program = rule.program,
    condition = rule.condition,
    origin = origin,
    context = context,
  })
  self.runtime.ruleLast[rule.id] = self.deps.now()
  return exec
end

--- Runs every enabled rule the predicate accepts. `cooled` applies a short
--- per-rule cooldown (state and variable triggers can chatter).
function Core:_fireRules(predicate, origin, context, cooled)
  if self.config == nil then
    return 0
  end
  local n = 0
  for _, rule in ipairs(self.config.rules) do
    if rule.enabled ~= false and type(rule.trigger) == "table" and predicate(rule) then
      local last = self.runtime.ruleLast[rule.id]
      if not cooled or last == nil or self.deps.now() - last >= M.TRIGGER_COOLDOWN then
        n = n + 1
        local ok, err = pcall(function()
          self:_runRule(rule, origin, context)
        end)
        if not ok then
          self.diag:add(
            "error",
            "scene",
            "VF_INTERNAL",
            "Rule '" .. tostring(rule.name) .. "' failed to start: " .. tostring(err)
          )
        end
      end
    end
  end
  return n
end

local function execCode(exec)
  if exec.status == "ok" then
    return nil
  end
  if exec.cancelReason ~= nil then
    return exec.cancelReason
  end
  return exec.status == "skipped" and "VF_CONDITION_FALSE" or "VF_NOT_CONFIRMED"
end

function Core:_executionUpdated(exec)
  if exec.status == "running" or exec.status == "settling" then
    self.state:touch()
    return
  end
  if exec.dryRun then
    return
  end
  -- Last run and last SUCCESSFUL run, per scene and per rule ("scene:<id>",
  -- "rule:<id>"). An unnamed test program is in the log only.
  if exec.refId ~= nil and (exec.kind == "scene" or exec.kind == "rule") then
    local ref = exec.kind .. ":" .. exec.refId
    self.runtime.lastRun[ref] = { at = exec.finishedAt, status = exec.status }
    if exec.status == "ok" then
      self.runtime.lastSuccess[ref] = exec.finishedAt
    end
  end
  local failed = {}
  for _, s in ipairs(exec.steps) do
    if s.status == "failed" or s.status == "partial" or s.status == "incomplete" then
      failed[#failed + 1] =
        string.format("%s %s [%s]", tostring(s.path), tostring(s.label), tostring(s.errorCode or s.status))
    end
  end
  self.diag:add(
    (exec.status == "ok" or exec.status == "skipped") and "info" or "warning",
    "scene",
    execCode(exec),
    string.format("%s '%s' finished: %s", exec.kind, tostring(exec.name), exec.status),
    { execution = exec.id, origin = exec.origin, problems = #failed > 0 and failed or nil }
  )
  self:_hook("record", exec.kind .. " finished", string.format("%s: %s", tostring(exec.name), exec.status))
  self:_saveRuntimeSoon()
  self.state:touch()
end

function Core:setVenueStatus(status, origin)
  if status ~= "open" and status ~= "closed" then
    return false
  end
  if self.runtime.venueStatus == status then
    return true
  end
  self.runtime.venueStatus = status
  self:_saveRuntimeSoon()
  self.state:touch()
  self.diag:add("info", "driver", nil, "Venue marked " .. status .. " (" .. tostring(origin) .. ")")
  self:_hook("setVariable", "VENUE_STATUS", status)
  self:_hook("fireEvent", status == "open" and "venue_open" or "venue_closed")
  self:_hook("record", "venue " .. status, tostring(origin))
  self:_fireRules(function(rule)
    return rule.trigger.type == "venue_status" and rule.trigger.status == status
  end, "venue_status")
  return true
end

--- Everything off: displays, audio zones, running scenes. System access; the
--- caller has already checked the profile's allOff permission.
function Core:allOff(origin, dry)
  local ids = {}
  for _, d in ipairs(self.config.displays) do
    if d.power ~= "none" then
      ids[#ids + 1] = d.id
    end
  end
  local opts = { access = Access.system("all-off"), origin = origin, dry = dry }
  local results = {}
  if not dry then
    self.runner:cancelAll("VF_CANCELLED", "All Off")
  end
  if #ids > 0 then
    local r = self.routing:displayPower(ids, "off", opts)
    for _, e in ipairs(r.results or {}) do
      e.kind = "display"
      results[#results + 1] = e
    end
  end
  for _, z in ipairs(self.config.audioZones) do
    if z.can.power ~= false then
      local r = self.audio:power(z.id, "off", opts)
      local e = (r.results and r.results[1])
        or { id = z.id, name = z.name, status = "failed", errorCode = r.errorCode, message = r.message }
      e.kind = "zone"
      results[#results + 1] = e
    end
  end
  local accepted, rejected = 0, 0
  for _, e in ipairs(results) do
    if e.status == "failed" then
      rejected = rejected + 1
    else
      accepted = accepted + 1
    end
  end
  if not dry then
    self.runtime.activeScene = nil
    self:_saveRuntimeSoon()
    self:_hook("setVariable", "ACTIVE_SCENE", "")
    self:_hook("record", "all off", tostring(origin))
    self.diag:add(
      "info",
      "command",
      nil,
      string.format("All Off (%s): %d accepted, %d refused", tostring(origin), accepted, rejected)
    )
    self.state:touch()
  end
  return {
    ok = accepted > 0 or #results == 0,
    status = rejected == 0 and (dry and "planned" or "accepted") or (accepted > 0 and "partial" or "failed"),
    results = results,
    summary = { requested = #results, accepted = accepted, rejected = rejected },
  }
end

-- ─── Licence ────────────────────────────────────────────────────────────────

--- The licence gates CONVENIENCE and CONFIGURATION, never control:
---   always works   every manual command (route, power, volume, mute, lighting,
---                  shades, All Off, venue status), reading state, backup export
---   needs a licence   scenes, rules, schedules, publishing, rollback
--- Nothing is ever switched off because a licence changed, and only a
--- definitive denial with server enforcement restricts anything: no Agent,
--- an outage and the grace period all leave the venue fully working.
function Core:licenseChanged()
  local restricted = false
  local ok, enforces = pcall(self.deps.license.enforces)
  if ok and enforces == true then
    restricted = true
  end
  if restricted ~= self.restricted then
    self.restricted = restricted
    local label = ""
    pcall(function()
      label = tostring(self.deps.license.label())
    end)
    if restricted then
      self.diag:add(
        "warning",
        "license",
        "VF_LICENSE_RESTRICTED",
        "Licence restricted (" .. label .. "): scenes, schedules and publishing are off; manual control continues"
      )
      self:_hook("fireEvent", "license_restricted")
    else
      self.diag:add("info", "license", nil, "Licence restored (" .. label .. ")")
      self:_hook("fireEvent", "license_restored")
    end
    self.state:touch()
  end
end

function Core:_licenseInfo()
  local info = { restricted = self.restricted, label = "" }
  pcall(function()
    info.label = tostring(self.deps.license.label())
  end)
  return info
end

-- ─── The state document a page receives ─────────────────────────────────────

local function publicCell(cell)
  return {
    value = cell.value,
    status = cell.status,
    at = cell.at,
    errorCode = cell.errorCode,
    requested = cell.requested,
  }
end

function Core:_derivedAlerts(access)
  local out = {}
  if self.restricted then
    out[#out + 1] = {
      id = "license",
      level = "warning",
      title = "SmartBuildOS licence required",
      detail = "Scenes and schedules are paused. Manual control keeps working.",
    }
  end
  for _, d in ipairs(self.config.displays) do
    if access:display(d) then
      local e = self.state.display[d.id]
      if self.online[d.id] == false then
        out[#out + 1] = {
          id = "offline:" .. d.id,
          level = "warning",
          title = tostring(d.name) .. " is offline",
          detail = "Control4 reports this display as not responding. Check its power and network.",
          entity = { kind = "display", id = d.id },
          action = { type = "query", displayIds = { d.id } },
        }
      else
        for _, field in ipairs({ "source", "power" }) do
          local cell = e[field]
          if cell.status == "failed" or (cell.status == "unknown" and cell.errorCode ~= nil) then
            out[#out + 1] = {
              id = "cell:" .. d.id .. ":" .. field,
              level = "warning",
              title = string.format(
                "%s: %s",
                tostring(d.name),
                field == "source" and "source change not confirmed" or "power change not confirmed"
              ),
              detail = Errors.operatorText(cell.errorCode or "VF_NOT_CONFIRMED"),
              entity = { kind = "display", id = d.id },
              action = { type = "query", displayIds = { d.id } },
            }
            break
          end
        end
      end
    end
  end
  for _, z in ipairs(self.config.audioZones) do
    if access:zone(z) then
      local e = self.state.zone[z.id]
      if e.mute.value == true and e.mute.status ~= "failed" then
        out[#out + 1] = {
          id = "muted:" .. z.id,
          level = "info",
          title = tostring(z.name) .. " audio muted",
          detail = tostring(z.name) .. " zone is currently muted (no audio).",
          entity = { kind = "zone", id = z.id },
          action = { type = "unmute", zoneId = z.id },
        }
      end
      for _, field in ipairs({ "source", "volume", "power", "mute" }) do
        local cell = e[field]
        if cell.status == "failed" then
          out[#out + 1] = {
            id = "cell:" .. z.id .. ":" .. field,
            level = "warning",
            title = tostring(z.name) .. " audio: change not confirmed",
            detail = Errors.operatorText(cell.errorCode or "VF_NOT_CONFIRMED"),
            entity = { kind = "zone", id = z.id },
          }
          break
        end
      end
    end
  end
  for _, a in ipairs(self.runtime.alerts) do
    out[#out + 1] = { id = a.id, level = a.level, title = a.title, detail = a.detail, at = a.at, dismissable = true }
  end
  return out
end

function Core:operatorState(access)
  local config = self.config
  local doc = {
    version = self.state.version,
    time = self.deps.now(),
    venueStatus = self.runtime.venueStatus,
    simulation = self:simulation(),
    configVersion = self.publishedMeta and self.publishedMeta.versionId or nil,
    license = self:_licenseInfo(),
    displays = {},
    zones = {},
    lighting = {},
    shades = {},
    activeScene = self.runtime.activeScene and U.copy(self.runtime.activeScene) or nil,
    running = {},
    operations = {},
    counts = {
      displays = { total = 0, on = 0, off = 0, unknown = 0, attention = 0, offline = 0 },
      zones = { total = 0, on = 0, muted = 0 },
    },
  }
  local visible = {}
  for _, d in ipairs(config.displays) do
    if access:display(d) then
      local e = self.state.display[d.id]
      visible["display:" .. d.id] = true
      doc.displays[d.id] = { power = publicCell(e.power), source = publicCell(e.source), online = self.online[d.id] }
      local c = doc.counts.displays
      c.total = c.total + 1
      if self.online[d.id] == false then
        c.offline = c.offline + 1
      end
      if e.power.status == "failed" or e.source.status == "failed" or self.online[d.id] == false then
        c.attention = c.attention + 1
      end
      if e.power.value == "on" and e.power.status ~= "unknown" then
        c.on = c.on + 1
      elseif e.power.value == "off" and e.power.status ~= "unknown" then
        c.off = c.off + 1
      else
        c.unknown = c.unknown + 1
      end
    end
  end
  for _, z in ipairs(config.audioZones) do
    if access:zone(z) then
      local e = self.state.zone[z.id]
      visible["zone:" .. z.id] = true
      doc.zones[z.id] = {
        power = publicCell(e.power),
        source = publicCell(e.source),
        volume = publicCell(e.volume),
        mute = publicCell(e.mute),
      }
      local c = doc.counts.zones
      c.total = c.total + 1
      if e.power.value == "on" then
        c.on = c.on + 1
      end
      if e.mute.value == true then
        c.muted = c.muted + 1
      end
    end
  end
  for _, l in ipairs(config.lighting) do
    if access:lightingControl(l) then
      visible["lighting:" .. l.id] = true
      doc.lighting[l.id] = { preset = publicCell(self.state.lighting[l.id].preset) }
    end
  end
  for _, s in ipairs(config.shades) do
    if access:shade(s) then
      visible["shade:" .. s.id] = true
      doc.shades[s.id] = { position = publicCell(self.state.shade[s.id].position) }
    end
  end
  for _, id in ipairs(U.sortedKeys(self.runner.running)) do
    local exec = self.runner.running[id]
    if not exec.dryRun then
      doc.running[#doc.running + 1] = {
        id = exec.id,
        refId = exec.refId,
        name = exec.name,
        kind = exec.kind,
        status = exec.status,
        startedAt = exec.startedAt,
      }
    end
  end
  for _, op in ipairs(self.tracker.ops) do
    if #doc.operations >= 8 then
      break
    end
    local pub = Tracker.publicOp(op, false)
    local targets = {}
    for _, t in ipairs(pub.targets) do
      if visible[t.kind .. ":" .. t.id] then
        targets[#targets + 1] = t
      end
    end
    if #targets > 0 then
      pub.targets = targets
      doc.operations[#doc.operations + 1] = pub
    end
  end
  if access:flag("viewAlerts") then
    doc.alerts = self:_derivedAlerts(access)
  end
  return doc
end

-- ─── Identity ───────────────────────────────────────────────────────────────

--- transport = { tile = bool (valid tile token or the Navigator bridge), client = address?, via = "relay"|"bridge" }
function Core:_context(req, transport)
  transport = transport or {}
  local ctx = { client = transport.client, via = transport.via, tile = transport.tile == true }
  local session = self.auth:resolve(req.session)
  if session ~= nil then
    if session.kind == "installer" then
      ctx.installer = true
      ctx.access = Access.system("installer")
      ctx.who = "installer"
      return ctx
    end
    local profile = self.ix and self.ix.profiles[session.profileId] or nil
    if profile ~= nil then
      ctx.access = Access.forProfile(profile)
      ctx.who = "profile:" .. profile.id
      ctx.signedIn = true
      return ctx
    end
    self.auth:logout(req.session) -- the profile no longer exists
  end
  if ctx.tile and self.config ~= nil then
    -- A station (a fixed screen known by its LAN address) opens as its own
    -- profile; every other tile opens as the default profile. Either way only
    -- a profile WITHOUT a PIN can be opened this way.
    local profileId, station = self.config.defaultProfileId, nil
    if ctx.client ~= nil then
      for _, st in ipairs(self.config.stations or {}) do
        if st.address == ctx.client then
          profileId, station = st.profileId, st
        end
      end
    end
    local profile = profileId ~= nil and self.ix.profiles[profileId] or nil
    if profile ~= nil and (profile.pinHash == nil or profile.pinHash == "") then
      ctx.access = Access.forProfile(profile)
      ctx.who = (station and ("station:" .. station.id .. ":") or "tile:") .. profile.id
      ctx.station = station
    end
  end
  return ctx
end

-- ─── Draft helpers ──────────────────────────────────────────────────────────

--- PIN salts and hashes never go to a browser. The Studio sees `hasPin`.
local function stripPins(config)
  local c = U.copy(config)
  for _, p in ipairs(c.profiles or {}) do
    p.hasPin = type(p.pinHash) == "string" and p.pinHash ~= ""
    p.pinHash, p.pinSalt = nil, nil
  end
  return c
end

--- ...and what the Studio sends back gets them re-attached from the stored draft.
local function mergePins(incoming, stored)
  local known = {}
  for _, p in ipairs(stored and stored.profiles or {}) do
    known[p.id] = p
  end
  for _, p in ipairs(type(incoming.profiles) == "table" and incoming.profiles or {}) do
    if type(p) == "table" then
      local old = known[p.id]
      p.pinHash, p.pinSalt = old and old.pinHash or nil, old and old.pinSalt or nil
      p.hasPin = nil
    end
  end
  return incoming
end

function Core:_draftData()
  local draft = self.store:draft()
  if draft == nil then
    return nil
  end
  local issues = Schema.validate(draft.config)
  local published = self.store:published()
  return {
    -- Exactly equal to what is published (after the same normalisation)?
    matchesPublished = published ~= nil and U.equal(draft.config, Schema.normalize(published.config)) or false,
    config = stripPins(draft.config),
    revision = draft.revision,
    savedAt = draft.savedAt,
    basedOn = draft.basedOn,
    issues = issues,
    summary = Schema.summarize(issues),
  }
end

function Core:_schemaInfo()
  local venueTypes = {}
  for _, key in ipairs(Schema.VENUE_TYPES) do
    local t = Templates.VENUE_TEMPLATES[key]
    venueTypes[#venueTypes + 1] =
      { id = key, label = t.label, areas = t.areas, scenes = t.scenes, profiles = t.profiles }
  end
  local sceneTemplates = {}
  for _, key in ipairs(Templates.SCENE_ORDER) do
    sceneTemplates[#sceneTemplates + 1] = Templates.scene(key)
  end
  local profileTemplates = {}
  for _, role in ipairs(Schema.ROLES) do
    profileTemplates[#profileTemplates + 1] = Templates.profile(role)
  end
  local codes = {}
  for _, code in ipairs(U.sortedKeys(Errors.CODES)) do
    codes[#codes + 1] = { code = code, message = Errors.CODES[code].operator }
  end
  return {
    version = Schema.SCHEMA_VERSION,
    protocol = Protocol.VERSION,
    venueTypes = venueTypes,
    interfaces = Schema.INTERFACES,
    sourceKinds = Schema.SOURCE_KINDS,
    displayKinds = Schema.DISPLAY_KINDS,
    routeStrategies = Schema.ROUTE_STRATEGIES,
    powerStrategies = Schema.POWER_STRATEGIES,
    roles = Schema.ROLES,
    variableTypes = Schema.VARIABLE_TYPES,
    permissionFlags = Schema.PERMISSION_FLAGS,
    limits = Schema.LIMITS,
    requestBytes = Protocol.MAX_REQUEST_BYTES,
    imageBytes = Store.IMAGE_MAX_BYTES,
    roomButtonsMax = Schema.ROOM_BUTTONS_MAX,
    stepTypes = Rules.STEP_TYPES,
    conditionOps = Rules.CONDITION_OPS,
    triggerTypes = Rules.TRIGGER_TYPES,
    comparators = Rules.COMPARATORS,
    maxWaitSeconds = Rules.MAX_WAIT_SECONDS,
    sceneTemplates = sceneTemplates,
    profileTemplates = profileTemplates,
    errorCodes = codes,
    diagCategories = Diag.CATEGORIES,
  }
end

-- ─── Command handlers ───────────────────────────────────────────────────────

local H = {}

function H.PING(core)
  return {
    ok = true,
    status = "ok",
    data = { service = "venueflow", protocol = Protocol.VERSION, simulation = core:simulation() },
  }
end

function H.HELLO(core, _, ctx)
  local data = {
    driver = { version = core.deps.version, simulation = core:simulation(), protocol = Protocol.VERSION },
    published = core.config ~= nil,
    sampleBlocked = core.sampleBlocked == true or nil,
    studioEnabled = core.auth:studioEnabled(),
    installer = ctx.installer == true,
    license = core:_licenseInfo(),
    profiles = {},
  }
  if core.config ~= nil then
    data.venueName = core.config.venue.name
    for _, p in ipairs(core.config.profiles) do
      if type(p.pinHash) == "string" and p.pinHash ~= "" then
        data.profiles[#data.profiles + 1] = { id = p.id, name = p.name, role = p.role }
      end
    end
    if ctx.access ~= nil then
      data.profile = ctx.access:describe()
      data.station = ctx.station and { id = ctx.station.id, name = ctx.station.name } or nil
      data.signedIn = ctx.signedIn == true or ctx.installer == true
      data.config = ctx.access:view(core.config)
      data.state = core:operatorState(ctx.access)
    else
      data.needsSignIn = true
    end
  end
  return { ok = true, status = "ok", data = data }
end

function H.PROFILE_LOGIN(core, p, ctx)
  if core.config == nil then
    return fail("VF_NO_PUBLISHED_CONFIG")
  end
  local profile = core.ix.profiles[p.profileId]
  if profile == nil then
    return fail("VF_BAD_PIN", "unknown profile")
  end
  local token, code = core.auth:profileLogin(profile, p.pin, ctx.client)
  if token == nil then
    core.diag:add("warning", "auth", code, "Profile sign-in refused", { profile = profile.id, client = ctx.client })
    return fail(code, nil, { data = { retryIn = core.auth:lockedFor("profile", ctx.client) } })
  end
  core.diag:add("info", "auth", nil, "Profile signed in: " .. tostring(profile.name), { client = ctx.client })
  local access = Access.forProfile(profile)
  return {
    ok = true,
    status = "ok",
    data = {
      session = token,
      profile = access:describe(),
      config = access:view(core.config),
      state = core:operatorState(access),
    },
  }
end

function H.STUDIO_LOGIN(core, p, ctx)
  local token, code = core.auth:installerLogin(p.passcode, ctx.client)
  if token == nil then
    core.diag:add("warning", "auth", code, "Installer Studio sign-in refused", { client = ctx.client })
    return fail(code, nil, { data = { retryIn = core.auth:lockedFor("installer", ctx.client) } })
  end
  core.diag:add("info", "auth", nil, "Installer Studio signed in", { client = ctx.client })
  return { ok = true, status = "ok", data = { session = token } }
end

function H.LOGOUT(core, _, _, req)
  core.auth:logout(req.session)
  return { ok = true, status = "ok" }
end

function H.GET_STATE(core, _, ctx)
  return { ok = true, status = "ok", data = { state = core:operatorState(ctx.access) } }
end

function H.ROUTE_VIDEO(core, p, ctx)
  local opts = { access = ctx.access, origin = ctx.who }
  local result = core.routing:routeVideo(p.sourceId, p.displayIds, opts)
  if p.audioZoneId ~= nil then
    local audio
    if result.ok then
      audio = core.audio:setSource(p.audioZoneId, p.sourceId, opts)
    else
      audio = fail("VF_CANCELLED", "video route failed; audio left alone")
    end
    result.data = {
      audio = {
        ok = audio.ok,
        status = audio.status,
        errorCode = audio.errorCode,
        message = audio.message,
        operationId = audio.operationId,
      },
    }
  end
  return result
end

function H.DISPLAY_POWER(core, p, ctx)
  return core.routing:displayPower(p.displayIds, p.power, { access = ctx.access, origin = ctx.who })
end

function H.AUDIO_SOURCE(core, p, ctx)
  return core.audio:setSource(p.zoneId, p.sourceId, { access = ctx.access, origin = ctx.who })
end

function H.AUDIO_VOLUME(core, p, ctx)
  local r = core.audio:setVolume(p.zoneId, p.level, { access = ctx.access, origin = ctx.who })
  if r.level ~= nil then
    r.data = { level = r.level, clamped = r.clamped }
  end
  return r
end

function H.AUDIO_MUTE(core, p, ctx)
  return core.audio:setMute(p.zoneId, p.muted, { access = ctx.access, origin = ctx.who })
end

function H.AUDIO_POWER(core, p, ctx)
  return core.audio:power(p.zoneId, p.power, { access = ctx.access, origin = ctx.who })
end

function H.AUDIO_PRESET(core, p, ctx)
  local r = core.audio:preset(p.zoneId, p.presetId, { access = ctx.access, origin = ctx.who })
  if r.level ~= nil then
    r.data = { level = r.level, clamped = r.clamped }
  end
  return r
end

function H.LIGHTING_PRESET(core, p, ctx)
  return core.audio:lighting(p.lightingId, p.presetId, { access = ctx.access, origin = ctx.who })
end

function H.SHADE(core, p, ctx)
  return core.audio:shade(p.shadeId, p.action, { access = ctx.access, origin = ctx.who })
end

local function sceneFor(core, sceneId, ctx)
  local scene = core.ix.scenes[sceneId]
  if scene == nil then
    return nil, fail("VF_NOT_FOUND", "unknown scene")
  end
  if not ctx.access:scene(scene) then
    return nil, fail("VF_FORBIDDEN", "profile may not run this scene")
  end
  return scene
end

function H.SCENE_PREVIEW(core, p, ctx)
  local scene, failed = sceneFor(core, p.sceneId, ctx)
  if scene == nil then
    return failed
  end
  local exec = core:_runScene(scene, ctx.who, nil, true)
  return { ok = true, status = "planned", data = { execution = Rules.publicExecution(exec, ctx.installer) } }
end

function H.SCENE_ACTIVATE(core, p, ctx)
  local scene, failed = sceneFor(core, p.sceneId, ctx)
  if scene == nil then
    return failed
  end
  if core.restricted then
    return fail("VF_LICENSE_RESTRICTED", "scenes need a licence")
  end
  if scene.confirm == true and p.confirm ~= true then
    local preview = core:_runScene(scene, ctx.who, nil, true)
    return fail("VF_CONFIRM_REQUIRED", nil, { data = { preview = Rules.publicExecution(preview, ctx.installer) } })
  end
  local context = p.areaId and { areaId = p.areaId } or nil
  local exec = core:_runScene(scene, ctx.who, context, false)
  local public = Rules.publicExecution(exec, ctx.installer)
  if exec.status == "skipped" then
    return fail("VF_CONDITION_FALSE", nil, { data = { execution = public } })
  end
  if exec.status == "failed" then
    return fail("VF_DISPATCH_FAILED", "no step of the scene could run", { data = { execution = public } })
  end
  return {
    ok = true,
    status = (exec.status == "ok") and "ok" or (exec.status == "partial" and "partial" or "accepted"),
    data = { execution = public },
  }
end

function H.ALL_OFF_PREVIEW(core, _, ctx)
  if not ctx.access:flag("allOff") then
    return fail("VF_FORBIDDEN", "profile may not run All Off")
  end
  local plan = core:allOff(ctx.who, true)
  local displays, zones = 0, 0
  for _, e in ipairs(plan.results) do
    if e.status ~= "failed" then
      if e.kind == "display" then
        displays = displays + 1
      else
        zones = zones + 1
      end
    end
  end
  return {
    ok = true,
    status = "planned",
    results = plan.results,
    data = {
      displays = displays,
      zones = zones,
      activeScene = core.runtime.activeScene and core.runtime.activeScene.name or nil,
    },
  }
end

function H.ALL_OFF(core, p, ctx)
  if not ctx.access:flag("allOff") then
    return fail("VF_FORBIDDEN", "profile may not run All Off")
  end
  if p.confirm ~= true then
    return fail("VF_CONFIRM_REQUIRED")
  end
  return core:allOff(ctx.who, false)
end

function H.VENUE_STATUS(core, p, ctx)
  if not ctx.access:flag("venueStatus") then
    return fail("VF_FORBIDDEN", "profile may not change the venue status")
  end
  core:setVenueStatus(p.status, ctx.who)
  return { ok = true, status = "ok", data = { venueStatus = core.runtime.venueStatus } }
end

function H.QUERY_STATUS(core, p, ctx)
  local results = {}
  local wanted = nil
  if p.displayIds ~= nil then
    wanted = {}
    for _, id in ipairs(p.displayIds) do
      wanted[id] = true
    end
  end
  for _, d in ipairs(core.config.displays) do
    if (wanted == nil or wanted[d.id]) and ctx.access:display(d) then
      local entry = { id = d.id, name = d.name }
      if d.c4RoomId ~= nil and d.feedback == "room" then
        local ok, room = pcall(core.adapter.readRoom, d.c4RoomId)
        if ok and type(room) == "table" then
          -- A fresh reading replaces a stale failure.
          if not core.tracker:isActive("display", d.id, "power") and room.power ~= nil then
            core.state:set("display", d.id, "power", room.power and "on" or "off", "confirmed")
          end
          if not core.tracker:isActive("display", d.id, "source") and room.videoDevice ~= nil then
            core.state:set(
              "display",
              d.id,
              "source",
              room.power ~= false and core.deviceSource[room.videoDevice] or nil,
              "confirmed"
            )
          end
          entry.status = "read"
        else
          entry.status = "failed"
          entry.errorCode = "VF_DEVICE_OFFLINE"
          entry.message = Errors.operatorText("VF_DEVICE_OFFLINE")
        end
      else
        entry.status = "failed"
        entry.errorCode = "VF_UNSUPPORTED"
        entry.message = "This display gives no feedback to read."
      end
      results[#results + 1] = entry
    end
  end
  core:_checkOnline()
  return { ok = true, status = "ok", results = results }
end

function H.ALERT_DISMISS(core, p, ctx)
  if not ctx.access:flag("viewAlerts") then
    return fail("VF_FORBIDDEN", "profile may not manage alerts")
  end
  for i, a in ipairs(core.runtime.alerts) do
    if a.id == p.alertId then
      table.remove(core.runtime.alerts, i)
      core.state:touch()
      core:_hook("setVariable", "ALERT_COUNT", #core.runtime.alerts)
      return { ok = true, status = "ok" }
    end
  end
  return fail("VF_NOT_FOUND", "that alert cannot be dismissed (it clears when its cause does)")
end

function H.IMAGE_GET(core, p, ctx)
  local allowed = ctx.installer == true
  if not allowed and core.config ~= nil then
    for _, f in ipairs(core.config.floors) do
      if type(f.image) == "table" and f.image.key == p.key and ctx.access:floor(f.id) then
        allowed = true
      end
    end
  end
  if not allowed then
    return fail("VF_NOT_FOUND", "no visible floor uses that image")
  end
  local data = core.store:getImage(p.key)
  if data == nil then
    return fail("VF_NOT_FOUND", "image not stored")
  end
  return { ok = true, status = "ok", data = { key = p.key, dataUrl = data } }
end

function H.OPERATION_GET(core, p, ctx)
  local op = core.tracker:find(p.operationId)
  if op == nil then
    return fail("VF_NOT_FOUND", "unknown operation")
  end
  return { ok = true, status = "ok", data = { operation = Tracker.publicOp(op, ctx.installer) } }
end

-- installer -------------------------------------------------------------------

function H.STUDIO_BOOTSTRAP(core)
  local info = {}
  if type(core.deps.info) == "function" then
    local ok, t = pcall(core.deps.info)
    if ok and type(t) == "table" then
      info = t
    end
  end
  local tz = ""
  pcall(function()
    tz = core.adapter.timeZone() or ""
  end)
  local lt = core.deps.localtime(core.deps.now())
  return {
    ok = true,
    status = "ok",
    data = {
      driver = { version = core.deps.version, simulation = core:simulation(), mode = core.deps.mode() },
      info = info,
      controller = {
        timeZone = tz,
        localTime = string.format("%04d-%02d-%02d %02d:%02d", lt.year, lt.month, lt.day, lt.hour, lt.min),
      },
      draft = core:_draftData(),
      published = core.publishedMeta,
      history = core.store:history(),
      license = core:_licenseDetail(),
      schema = core:_schemaInfo(),
      venueStatus = core.runtime.venueStatus,
    },
  }
end

function Core:_licenseDetail()
  local out = self:_licenseInfo()
  local ok, detail = pcall(self.deps.license.describe)
  if ok and type(detail) == "table" then
    for k, v in pairs(detail) do
      out[k] = v
    end
  end
  out.policy = {
    always = "Manual control (routing, power, audio, lighting, shades, All Off), state and backup export.",
    licensed = "Scenes, rules, schedules, publishing and rollback.",
    note = "Only a definitive denial with enforcement restricts anything. No Agent, an outage or the grace period never do.",
  }
  return out
end

function H.DRAFT_GET(core)
  return { ok = true, status = "ok", data = { draft = core:_draftData() } }
end

function H.DRAFT_SAVE(core, p)
  local ok, encoded = pcall(core.deps.json.encode, p.config)
  if ok and type(encoded) == "string" and #encoded > M.MAX_DRAFT_BYTES then
    return fail("VF_TOO_LARGE", "the configuration is larger than the controller should store")
  end
  local stored = core.store:draft()
  local config = mergePins(U.copy(p.config), stored and stored.config)
  local revision, why, detail = core.store:saveDraft(config, p.baseRevision)
  if revision == nil then
    if why == "stale" then
      return fail("VF_STALE_DRAFT", detail)
    elseif why == "invalid" then
      return fail("VF_VALIDATION_FAILED", detail)
    end
    return fail("VF_STORAGE_FAILED", detail)
  end
  core.diag:add("info", "config", nil, "Draft saved, revision " .. revision)
  local data = core:_draftData()
  return { ok = true, status = "ok", data = { revision = revision, issues = data.issues, summary = data.summary } }
end

function H.DRAFT_VALIDATE(core)
  local data = core:_draftData()
  if data == nil then
    return fail("VF_NOT_FOUND", "there is no draft")
  end
  return {
    ok = true,
    status = "ok",
    data = { issues = data.issues, summary = data.summary, revision = data.revision },
  }
end

function H.DRAFT_DISCARD(core, p)
  if p.confirm ~= true then
    return fail("VF_CONFIRM_REQUIRED")
  end
  core.store:discardDraft()
  local published = core.store:published()
  if published ~= nil then
    core.store:saveDraft(published.config, nil, { force = true, basedOn = published.versionId })
  end
  core.diag:add("info", "config", nil, "Draft discarded")
  return { ok = true, status = "ok", data = { draft = core:_draftData() } }
end

function H.TEMPLATE_APPLY(core, p)
  if not U.contains(Schema.VENUE_TYPES, p.venueType) then
    return fail("VF_INVALID_PAYLOAD", "unknown venue type")
  end
  if core.store:draft() ~= nil and p.confirm ~= true then
    return fail("VF_CONFIRM_REQUIRED", "a draft already exists")
  end
  local config
  if p.sample == true then
    if not core:simulation() then
      return fail("VF_SIMULATION_ONLY", "sample venues use invented Control4 ids")
    end
    local function hashPin(pin)
      local salt = core.auth:newSalt()
      return salt, core.auth:hashPin(pin, salt)
    end
    if p.venueType == "sports_bar" then
      config = Templates.sportsBar(hashPin)
    elseif p.venueType == "conference_center" then
      config = Templates.conferenceCenter(hashPin)
    else
      return fail("VF_INVALID_PAYLOAD", "samples exist for sports_bar and conference_center")
    end
  else
    config = Templates.venue(p.venueType, p.name)
  end
  local revision, why, detail = core.store:saveDraft(config, nil, { force = true })
  if revision == nil then
    return fail(why == "invalid" and "VF_VALIDATION_FAILED" or "VF_STORAGE_FAILED", detail)
  end
  core.diag:add("info", "config", nil, "Draft replaced from " .. (p.sample and "sample " or "template ") .. p.venueType)
  return { ok = true, status = "ok", data = { draft = core:_draftData() } }
end

function H.PROFILE_PIN_SET(core, p)
  local draft = core.store:draft()
  if draft == nil then
    return fail("VF_NOT_FOUND", "there is no draft")
  end
  local profile
  for _, candidate in ipairs(draft.config.profiles) do
    if candidate.id == p.profileId then
      profile = candidate
    end
  end
  if profile == nil then
    return fail("VF_NOT_FOUND", "unknown profile")
  end
  if p.pin == nil or p.pin == "" then
    profile.pinHash, profile.pinSalt = nil, nil
  else
    if not Auth.validPin(p.pin) then
      return fail("VF_INVALID_PAYLOAD", "a PIN is 4 to 8 digits")
    end
    profile.pinSalt = core.auth:newSalt()
    profile.pinHash = core.auth:hashPin(p.pin, profile.pinSalt)
  end
  local revision, why, detail = core.store:saveDraft(draft.config, p.baseRevision, { force = p.baseRevision == nil })
  if revision == nil then
    return fail(why == "stale" and "VF_STALE_DRAFT" or "VF_STORAGE_FAILED", detail)
  end
  core.diag:add(
    "info",
    "config",
    nil,
    "Profile PIN " .. ((p.pin == nil or p.pin == "") and "removed" or "set"),
    { profile = profile.id }
  )
  return { ok = true, status = "ok", data = { revision = revision, hasPin = profile.pinHash ~= nil } }
end

function H.IMAGE_PUT(core, p)
  local key, why = core.store:putImage(p.dataUrl)
  if key == nil then
    if why == "too_large" then
      return fail(
        "VF_TOO_LARGE",
        "the picture is over " .. math.floor(Store.IMAGE_MAX_BYTES / 1024) .. " kB once encoded"
      )
    elseif why == "too_many" then
      return fail("VF_TOO_LARGE", "too many stored pictures; publish to release unused ones")
    elseif why == "invalid" then
      return fail("VF_INVALID_PAYLOAD", "a floor plan is a PNG, JPEG or WebP picture")
    end
    return fail("VF_STORAGE_FAILED", why)
  end
  return { ok = true, status = "ok", data = { key = key } }
end

function H.PUBLISH(core, p, ctx)
  if core.restricted then
    return fail("VF_LICENSE_RESTRICTED", "publishing needs a licence")
  end
  local draft = core.store:draft()
  if draft == nil then
    return fail("VF_NOT_FOUND", "there is no draft to publish")
  end
  local issues = Schema.validate(draft.config)
  local ok, blocking = Schema.publishable(issues, p.acknowledged)
  if not ok then
    return fail(
      "VF_VALIDATION_FAILED",
      #blocking .. " issue(s) must be fixed or acknowledged",
      { data = { blocking = blocking } }
    )
  end
  local before = core.config
  local versionId, err = core.store:publish(p.note, ctx.who)
  if versionId == nil then
    return fail("VF_STORAGE_FAILED", err)
  end
  -- Sessions of profiles that were removed or whose PIN changed end now.
  local newProfiles = U.indexById(draft.config.profiles)
  for _, old in ipairs(before and before.profiles or {}) do
    local now = newProfiles[old.id]
    if now == nil or now.pinHash ~= old.pinHash then
      core.auth:revoke("profile", old.id)
    end
  end
  core:load("published " .. versionId)
  core.diag:add(
    "info",
    "config",
    nil,
    "Published " .. versionId,
    { acknowledged = #(p.acknowledged or {}), note = p.note }
  )
  core:_hook("fireEvent", "published")
  core:_hook("record", "configuration published", versionId)
  return {
    ok = true,
    status = "ok",
    data = { versionId = versionId, published = core.publishedMeta, history = core.store:history() },
  }
end

function H.VERSIONS(core)
  return { ok = true, status = "ok", data = { published = core.publishedMeta, history = core.store:history() } }
end

function H.ROLLBACK(core, p, ctx)
  if core.restricted then
    return fail("VF_LICENSE_RESTRICTED", "rollback needs a licence")
  end
  if p.confirm ~= true then
    return fail("VF_CONFIRM_REQUIRED")
  end
  local versionId, err = core.store:rollback(p.versionId, ctx.who)
  if versionId == nil then
    return fail("VF_NOT_FOUND", err)
  end
  core.auth:revoke("profile")
  core:load("rollback to " .. p.versionId)
  core.diag:add("warning", "config", nil, "Rolled back to " .. p.versionId .. " as " .. versionId)
  core:_hook("record", "configuration rolled back", p.versionId)
  return {
    ok = true,
    status = "ok",
    data = { versionId = versionId, published = core.publishedMeta, history = core.store:history() },
  }
end

function H.BACKUP_EXPORT(core)
  core.diag:add("info", "config", nil, "Backup exported")
  return { ok = true, status = "ok", data = { backup = core.store:exportBackup() } }
end

function H.BACKUP_RESTORE(core, p)
  if core.store:draft() ~= nil and p.confirm ~= true then
    return fail("VF_CONFIRM_REQUIRED", "the current draft would be replaced")
  end
  local revision, why, detail = core.store:restoreBackup(p.backup, p.which)
  if revision == nil then
    return fail(why == "invalid" and "VF_VALIDATION_FAILED" or "VF_STORAGE_FAILED", detail)
  end
  core.diag:add("warning", "config", nil, "Backup restored into the draft, revision " .. revision)
  return { ok = true, status = "ok", data = { draft = core:_draftData() } }
end

--- In Simulation the made-up project also holds whatever the DRAFT maps, so a
--- mapping can be rehearsed before it is published.
local function simKnowsDraft(core)
  if core:simulation() and core.sim ~= nil then
    local draft = core.store:draft()
    if draft ~= nil then
      core.sim:populate(draft.config)
    end
    if core.config == nil then
      core.sim:demo()
    end
  end
end

function H.DISCOVER(core)
  simKnowsDraft(core)
  local scan = Discovery.scan(core.adapter)
  core.diag:add(
    "info",
    "mapping",
    scan.error and "VF_INTERNAL" or nil,
    "Device discovery: " .. #scan.devices .. " devices"
  )
  return {
    ok = scan.error == nil,
    status = scan.error and "failed" or "ok",
    errorCode = scan.error and "VF_INTERNAL" or nil,
    detail = scan.error,
    data = scan,
  }
end

local function findIn(list, id)
  for _, item in ipairs(list or {}) do
    if item.id == id then
      return item
    end
  end
  return nil
end

--- Tests act on the DRAFT's mapping (so a mapping can be proven before it is
--- published) and talk to the adapter directly. They can interrupt a venue,
--- so everything but "status" needs confirm = true.
function H.TEST_DEVICE(core, p)
  local draft = core.store:draft()
  local config = draft and draft.config or core.config
  if config == nil then
    return fail("VF_NOT_FOUND", "nothing to test yet")
  end
  local display = p.displayId and findIn(config.displays, p.displayId) or nil
  local zone = p.zoneId and findIn(config.audioZones, p.zoneId) or nil
  local source = p.sourceId and findIn(config.sources, p.sourceId) or nil
  if display == nil and zone == nil then
    return fail("VF_NOT_FOUND", "choose a display or an audio zone to test")
  end
  simKnowsDraft(core)
  local adapter = core.adapter
  local roomId = display and display.c4RoomId or (zone and zone.c4RoomId)
  if p.test == "status" then
    local data = { roomId = roomId }
    if roomId ~= nil then
      local ok, room = pcall(adapter.readRoom, roomId)
      data.room = ok and room or nil
      data.readable = ok and type(room) == "table"
    end
    if display and display.c4DeviceId ~= nil then
      local ok, online = pcall(adapter.deviceOnline, display.c4DeviceId)
      data.online = ok and online or nil
    end
    return { ok = true, status = "ok", data = data }
  end
  if p.confirm ~= true then
    return fail("VF_CONFIRM_REQUIRED", "a test can interrupt what the venue is showing")
  end
  local before = nil
  if roomId ~= nil then
    local okBefore, room = pcall(adapter.readRoom, roomId)
    if okBefore and type(room) == "table" then
      before = room
    end
  end
  local ok, err, expect
  if p.test == "power_on" or p.test == "power_off" then
    if display == nil then
      return fail("VF_INVALID_PAYLOAD", "power tests need a display")
    end
    local on = p.test == "power_on"
    if display.power == "none" then
      return fail("VF_UNSUPPORTED", "this display has no power control")
    elseif display.power == "device" then
      if display.c4DeviceId == nil then
        return fail("VF_DEVICE_UNMAPPED")
      end
      ok, err = adapter.devicePower(display.c4DeviceId, on)
    else
      if roomId == nil then
        return fail("VF_DEVICE_UNMAPPED")
      end
      if on then
        source = source or (display.defaultSourceId and findIn(config.sources, display.defaultSourceId)) or nil
        if source == nil or source.c4DeviceId == nil then
          return fail("VF_NO_SOURCE_FOR_POWER_ON", "pick a source for the test")
        end
        ok, err = adapter.selectVideo(roomId, source.c4DeviceId)
      else
        ok, err = adapter.roomOff(roomId)
      end
      expect = { field = "power", value = on }
    end
  else -- source | route
    if source == nil or source.c4DeviceId == nil then
      return fail("VF_DEVICE_UNMAPPED", "the source needs a Control4 device")
    end
    if display ~= nil then
      local route = display.route or {}
      if route.strategy == "none" then
        return fail("VF_ROUTE_UNSUPPORTED")
      elseif route.strategy == "command" then
        local params = {}
        for k, v in pairs(route.command.params or {}) do
          params[k] = v == "${source}" and source.c4DeviceId or (v == "${sourceName}" and source.name or v)
        end
        ok, err = adapter.deviceCommand(route.command.deviceId, route.command.name, params)
      else
        if roomId == nil then
          return fail("VF_DEVICE_UNMAPPED")
        end
        ok, err = adapter.selectVideo(roomId, source.c4DeviceId)
        expect = { field = "videoDevice", value = source.c4DeviceId }
      end
    else
      if roomId == nil then
        return fail("VF_DEVICE_UNMAPPED")
      end
      ok, err = adapter.selectAudio(roomId, source.c4DeviceId)
      expect = { field = "audioDevice", value = source.c4DeviceId }
    end
  end
  local name = display and display.name or zone.name
  core.diag:add(
    ok and "info" or "warning",
    "mapping",
    (not ok) and "VF_DISPATCH_FAILED" or nil,
    string.format("Test %s on %s: %s", p.test, tostring(name), ok and "sent" or tostring(err))
  )
  if not ok then
    return fail(err == "offline" and "VF_DEVICE_OFFLINE" or "VF_DISPATCH_FAILED", tostring(err))
  end
  core.testSeq = core.testSeq + 1
  local testId = "t" .. core.testSeq
  local test = { id = testId, test = p.test, name = name, status = "waiting", dispatched = true, before = before }
  if expect ~= nil and before ~= nil then
    -- false: the room was already in the requested state, so "confirmed"
    -- will not prove the command did anything.
    test.changes = before[expect.field] ~= expect.value
  end
  core.tests[testId] = test
  if expect ~= nil and roomId ~= nil then
    core.deps.timers.set("VfTest_" .. testId, 4000, function()
      local okRead, room = pcall(adapter.readRoom, roomId)
      if not okRead or type(room) ~= "table" then
        test.status, test.matched = "unreadable", nil
      else
        test.room = room
        test.matched = room[expect.field] == expect.value
        test.status = test.matched and "confirmed" or "not_confirmed"
      end
      core.diag:add(
        test.matched and "info" or "warning",
        "mapping",
        (not test.matched) and "VF_NOT_CONFIRMED" or nil,
        string.format("Test %s on %s: %s", p.test, tostring(name), test.status)
      )
    end)
  else
    test.status = "sent_no_feedback"
  end
  -- Keep the table small.
  local n = 0
  for id in pairs(core.tests) do
    n = n + 1
    if n > 40 and id ~= testId then
      core.tests[id] = nil
    end
  end
  return { ok = true, status = "accepted", data = { testId = testId, status = test.status } }
end

function H.TEST_RESULT(core, p)
  local test = core.tests[p.testId]
  if test == nil then
    return fail("VF_NOT_FOUND", "unknown test")
  end
  return { ok = true, status = "ok", data = U.copy(test) }
end

function H.PROGRAM_VALIDATE(core, p)
  local draft = core.store:draft()
  local config = draft and draft.config or core.config
  if config == nil then
    return fail("VF_NOT_FOUND", "there is no configuration to validate against")
  end
  local ix = Schema.index(config)
  local issues = {}
  if p.trigger ~= nil then
    Rules.validateTrigger(p.trigger, ix, "trigger", issues)
  end
  if p.condition ~= nil then
    Rules.validateCondition(p.condition, ix, "condition", issues)
  end
  Rules.validateProgram(p.program, ix, "program", issues)
  local summary = Schema.summarize(issues)
  return {
    ok = summary.errors == 0,
    status = summary.errors == 0 and "ok" or "failed",
    errorCode = summary.errors > 0 and "VF_VALIDATION_FAILED" or nil,
    data = { issues = issues, summary = summary },
  }
end

--- Inline programs run against the PUBLISHED configuration: that is what the
--- venue's devices are. A program that names something unpublished is refused.
local function inlineProgram(core, p)
  if core.config == nil then
    return nil, fail("VF_NO_PUBLISHED_CONFIG", "publish before testing a program")
  end
  local issues = {}
  if p.condition ~= nil then
    Rules.validateCondition(p.condition, core.ix, "condition", issues)
  end
  Rules.validateProgram(p.program, core.ix, "program", issues)
  for _, i in ipairs(issues) do
    if i.severity == "error" then
      return nil,
        fail(
          "VF_VALIDATION_FAILED",
          "the program does not match the published configuration: " .. i.message,
          { data = { issues = issues } }
        )
    end
  end
  return { kind = "adhoc", name = p.name or "Test program", program = p.program, condition = p.condition }
end

function H.PROGRAM_DRY_RUN(core, p)
  local spec, failed = inlineProgram(core, p)
  if spec == nil then
    return failed
  end
  spec.dryRun = true
  spec.origin = "studio dry run"
  local exec = core:_start(spec)
  return { ok = true, status = "planned", data = { execution = Rules.publicExecution(exec, true) } }
end

function H.PROGRAM_EXECUTE(core, p)
  if core.restricted then
    return fail("VF_LICENSE_RESTRICTED", "running programs needs a licence")
  end
  if p.confirm ~= true then
    return fail("VF_CONFIRM_REQUIRED", "this sends live commands to the venue")
  end
  local spec, failed = inlineProgram(core, p)
  if spec == nil then
    return failed
  end
  spec.origin = "studio test"
  -- A test of a saved scene or rule is recorded as that item's run. It does
  -- not make the scene "active" and does not fire the rules that wait for it.
  if p.refKind ~= nil and p.refId ~= nil then
    spec.kind, spec.refId = p.refKind, p.refId
  end
  local exec = core:_start(spec)
  return {
    ok = exec.status ~= "failed",
    status = exec.status == "ok" and "ok" or "accepted",
    data = { execution = Rules.publicExecution(exec, true) },
  }
end

function H.EXECUTION_CANCEL(core, p)
  if core.runner:cancel(p.executionId, "VF_CANCELLED", "installer") then
    return { ok = true, status = "ok" }
  end
  return fail("VF_NOT_FOUND", "that run is not active")
end

function H.EXECUTIONS(core)
  return {
    ok = true,
    status = "ok",
    data = {
      executions = core.runner:list(true),
      lastRun = U.copy(core.runtime.lastRun),
      lastSuccess = U.copy(core.runtime.lastSuccess),
      upcoming = core.scheduler and core.scheduler:upcoming(12) or {},
      controller = (function()
        local lt = core.deps.localtime(core.deps.now())
        local tz = ""
        pcall(function()
          tz = core.adapter.timeZone() or ""
        end)
        return {
          timeZone = tz,
          localTime = string.format("%04d-%02d-%02d %02d:%02d", lt.year, lt.month, lt.day, lt.hour, lt.min),
        }
      end)(),
      operations = core.tracker:recent(20, true),
      variables = U.copy(core.runtime.variables),
    },
  }
end

function H.DIAG_GET(core, p)
  return {
    ok = true,
    status = "ok",
    data = {
      entries = core.diag:list(p),
      counts = U.copy(core.diag.counts),
      size = core.diag:size(),
      max = core.diag.max,
      sessions = { installer = core.auth:count("installer"), profile = core.auth:count("profile") },
      queue = core.queue:size(),
      simFaults = (core:simulation() and core.sim ~= nil) and U.copy(core.sim.faults) or nil,
    },
  }
end

function H.DIAG_CLEAR(core)
  core.diag:clear()
  core.diag:add("info", "driver", nil, "Diagnostic log cleared from Installer Studio")
  return { ok = true, status = "ok" }
end

function H.LICENSE_GET(core)
  return { ok = true, status = "ok", data = { license = core:_licenseDetail() } }
end

function H.LICENSE_REFRESH(core)
  pcall(core.deps.license.refresh)
  core:licenseChanged()
  return { ok = true, status = "ok", data = { license = core:_licenseDetail() } }
end

function H.SESSIONS_REVOKE(core)
  local n = core.auth:revoke("profile")
  core.diag:add("warning", "auth", nil, "All staff sessions ended from Installer Studio (" .. n .. ")")
  return { ok = true, status = "ok", data = { revoked = n } }
end

function H.SIM_FAULT(core, p)
  if not core:simulation() or core.sim == nil then
    return fail("VF_SIMULATION_ONLY")
  end
  local allowed = { offline = true, silent = true, wrong = true, slow = true }
  if p.fault ~= nil and p.fault ~= "" and not allowed[p.fault] then
    return fail("VF_INVALID_PAYLOAD", "unknown fault")
  end
  core.sim:setFault(p.targetId, (p.fault ~= nil and p.fault ~= "") and p.fault or nil)
  core.diag:add("info", "driver", nil, "Simulator fault on " .. p.targetId .. ": " .. tostring(p.fault or "cleared"))
  core:_checkOnline()
  return { ok = true, status = "ok" }
end

function H.SIM_EXTERNAL(core, p)
  if not core:simulation() or core.sim == nil then
    return fail("VF_SIMULATION_ONLY")
  end
  local changes = {}
  for _, k in ipairs({ "power", "volume", "muted", "videoDevice", "audioDevice" }) do
    if p.changes[k] ~= nil then
      changes[k] = p.changes[k]
    end
  end
  core.sim:external(p.roomId, changes)
  return { ok = true, status = "ok" }
end

M.HANDLERS = H

--- Commands that need no published configuration.
local NO_CONFIG_NEEDED = { PING = true, HELLO = true, STUDIO_LOGIN = true, LOGOUT = true, PROFILE_LOGIN = true }

local function stripDetail(reply)
  reply.detail = nil
  for _, r in ipairs(type(reply.results) == "table" and reply.results or {}) do
    if type(r) == "table" then
      r.detail = nil
    end
  end
end

--- The single entry point for every page. Always returns a reply envelope.
function Core:handle(request, transport)
  local now = self.deps.now()
  local req, failure = Protocol.validate(request)
  if req == nil then
    self.diag:add("warning", "webview", failure.errorCode, "Request refused: " .. tostring(failure.detail), {
      via = transport and transport.via,
      client = transport and transport.client,
    })
    local reply = Protocol.reply(request, failure, { stateVersion = self.state.version, ts = now })
    reply.requestId = type(request) == "table" and type(request.requestId) == "string" and request.requestId:sub(1, 64)
      or nil
    stripDetail(reply)
    return reply
  end
  local ctx = self:_context(req, transport)
  local result
  if req.scope == "installer" and not ctx.installer then
    result =
      fail(self.auth:studioEnabled() and "VF_UNAUTHENTICATED" or "VF_STUDIO_DISABLED", "installer session required")
  elseif req.scope == "operator" and self.config == nil and not (ctx.installer and req.command == "IMAGE_GET") then
    -- (The Layout Designer shows a draft floor's picture before anything is published.)
    result = fail("VF_NO_PUBLISHED_CONFIG")
  elseif req.scope == "operator" and ctx.access == nil then
    result = fail("VF_UNAUTHENTICATED", "sign in with a staff profile")
  else
    local ok, out = pcall(H[req.command], self, req.payload, ctx, req)
    if ok and type(out) == "table" then
      result = out
    else
      self.diag:add("error", "driver", "VF_INTERNAL", "Handler " .. req.command .. " failed: " .. tostring(out))
      result = fail("VF_INTERNAL", tostring(out))
    end
  end
  if result.ok ~= true and (result.errorCode == "VF_FORBIDDEN" or result.errorCode == "VF_UNAUTHENTICATED") then
    self.diag:add(
      "warning",
      "auth",
      result.errorCode,
      "Refused " .. req.command,
      { who = ctx.who, client = ctx.client, detail = result.detail }
    )
  end
  local reply = Protocol.reply(req, result, { stateVersion = self.state.version, ts = now })
  if not ctx.installer then
    stripDetail(reply)
  end
  if
    req.since ~= nil
    and ctx.access ~= nil
    and self.config ~= nil
    and not NO_CONFIG_NEEDED[req.command]
    and req.command ~= "GET_STATE"
  then
    if req.since ~= self.state.version then
      reply.state = self:operatorState(ctx.access)
    end
  end
  if req.command == "GET_STATE" and reply.ok and req.since == self.state.version then
    reply.data = { unchanged = true }
  end
  reply.stateVersion = self.state.version
  return reply
end

--- A floor-plan picture arriving on the relay's /image route: the body is
--- the data: URL itself (never JSON). Needs an Installer Studio session.
--- Returns a reply envelope.
function Core:upload(sessionToken, dataUrl, transport)
  local now = self.deps.now()
  local session = self.auth:resolve(sessionToken)
  local result
  if session == nil or session.kind ~= "installer" then
    result =
      fail(self.auth:studioEnabled() and "VF_UNAUTHENTICATED" or "VF_STUDIO_DISABLED", "installer session required")
    self.diag:add(
      "warning",
      "auth",
      result.errorCode,
      "Picture upload refused",
      { client = transport and transport.client }
    )
  elseif type(dataUrl) ~= "string" or dataUrl == "" then
    result = fail("VF_INVALID_PAYLOAD", "the body must be the picture's data URL")
  else
    local ok, out = pcall(H.IMAGE_PUT, self, { dataUrl = dataUrl })
    if ok and type(out) == "table" then
      result = out
    else
      self.diag:add("error", "driver", "VF_INTERNAL", "Picture upload failed: " .. tostring(out))
      result = fail("VF_INTERNAL", tostring(out))
    end
  end
  local reply = Protocol.reply(
    { requestId = "upload", command = "IMAGE_PUT" },
    result,
    { stateVersion = self.state.version, ts = now }
  )
  if session == nil or session.kind ~= "installer" then
    stripDetail(reply) -- detail is for installer sessions only
  end
  return reply
end

-- ─── Composer programming and driver actions ────────────────────────────────

local function byNameOrId(list, text)
  text = U.trim(text)
  if text == "" then
    return nil
  end
  local lower = text:lower()
  for _, item in ipairs(list or {}) do
    if item.id == text or tostring(item.name):lower() == lower then
      return item
    end
  end
  return nil
end

--- Commands a dealer places in Composer programming. They run with system
--- access: whoever programs the controller already controls it.
--- Returns ok, message.
function Core:composer(command, params)
  params = params or {}
  if self.config == nil then
    return false, "VenueFlow has no published configuration"
  end
  if command == "ACTIVATE_SCENE" then
    local scene = byNameOrId(self.config.scenes, params.SCENE)
    if scene == nil then
      return false, "unknown scene " .. U.oneLine(params.SCENE, 60)
    end
    if self.restricted then
      return false, "licence restricted"
    end
    local exec = self:_runScene(scene, "composer", nil, false)
    return exec.status ~= "failed" and exec.status ~= "skipped", exec.status
  elseif command == "TRIGGER_EVENT" then
    local name = U.trim(params.NAME)
    local n = self:_fireRules(function(rule)
      local t = rule.trigger
      return (t.type == "c4_event" or t.type == "external") and tostring(t.name):lower() == name:lower()
    end, "composer event " .. name)
    return n > 0, n .. " rule(s) run"
  elseif command == "SET_VENUE_STATUS" then
    local status = U.trim(params.STATUS):lower()
    return self:setVenueStatus(status, "composer"), status
  elseif command == "ALL_OFF" then
    local r = self:allOff("composer", false)
    return r.ok, r.status
  elseif command == "ROUTE_SOURCE" then
    local source = byNameOrId(self.config.sources, params.SOURCE)
    if source == nil then
      return false, "unknown source"
    end
    local target = U.trim(params.TARGET)
    local ids
    if target:lower() == "all" then
      ids = Rules.resolveTarget({ all = true }, self.config, self.ix)
    else
      local group = byNameOrId(self.config.groups, target)
      local display = byNameOrId(self.config.displays, target)
      if group ~= nil then
        ids = group.displayIds
      elseif display ~= nil then
        ids = { display.id }
      else
        return false, "unknown display or group"
      end
    end
    local r = self.routing:routeVideo(source.id, ids, { access = Access.system("composer"), origin = "composer" })
    return r.ok, r.status
  end
  return false, "unknown command"
end

--- One-line summaries for the driver's property page.
function Core:summary()
  local s = {
    configuration = "Not published",
    venue = "-",
    status = self.runtime.venueStatus,
    scene = self.runtime.activeScene and self.runtime.activeScene.name or "none",
    alerts = 0,
    mode = self:simulation() and "Simulation" or "Live",
  }
  if self.config ~= nil then
    s.venue = self.config.venue.name
    s.configuration = string.format(
      "%s: %d displays, %d sources, %d zones, %d scenes",
      tostring(self.publishedMeta.versionId),
      #self.config.displays,
      #self.config.sources,
      #self.config.audioZones,
      #self.config.scenes
    )
    s.alerts = #self:_derivedAlerts(Access.system("summary"))
  end
  local draft = self.store:draft()
  s.draft = draft and ("revision " .. draft.revision) or "none"
  if self.sampleBlocked then
    s.configuration = "Sample venue - not run in Live mode"
  end
  return s
end

return M
