--- VenueFlow: a simulated Control4 project (pure).
---
--- Implements the same adapter interface as adapter_c4.lua, against rooms
--- and devices held in memory. It is what the automated tests, the browser
--- tests and the driver's Simulation mode run on. It is NOT evidence that a
--- real controller behaves the same way: every hardware-dependent claim is
--- listed in docs/smartbuildos-venueflow/HARDWARE_VALIDATION.md.
---
--- Faults that can be injected (per Control4 room or device id):
---   offline  the command is refused at dispatch ("offline")
---   silent   the command is accepted and nothing ever changes
---   wrong    the room switches, but to another device than the one asked
---   slow     feedback arrives after `slowMs` instead of `latencyMs`

local U = require("venueflow.util")

local M = {}

M.STEP_MS = 100

local Sim = {}
Sim.__index = Sim

--- deps = { timers = { set, cancel }, latencyMs = 400 }
function M.new(deps)
  local self = setmetatable({}, Sim)
  self.timers = deps.timers
  self.latencyMs = deps.latencyMs or 400
  self.slowMs = deps.slowMs or 20000
  self.rooms = {} -- id -> { name, power, volume, muted, videoDevice, audioDevice }
  self.devices = {} -- id -> { name, room, roomId, driverFile, category, online, power, level }
  self.faults = {} -- id -> "offline" | "silent" | "wrong" | "slow"
  self.calls = {} -- every command received, in order
  self.pending = {}
  self.armed = false
  self.onRoomChanged = nil
  self.variables = {} -- deviceId -> { NAME = value }
  return self
end

function Sim:addRoom(id, name)
  self.rooms[id] = self.rooms[id]
    or {
      name = name or ("Room " .. id),
      power = false,
      volume = 30,
      muted = false,
      videoDevice = 0,
      audioDevice = 0,
    }
  if name then
    self.rooms[id].name = name
  end
  return self.rooms[id]
end

function Sim:addDevice(id, info)
  local d = self.devices[id] or { online = true, power = false }
  for k, v in pairs(info or {}) do
    d[k] = v
  end
  self.devices[id] = d
  return d
end

--- Builds rooms and devices for everything a configuration maps.
function M.fromConfig(config, deps)
  local sim = M.new(deps)
  sim:populate(config)
  return sim
end

--- Carries device state over from the simulator this one replaces. A publish
--- rebuilds the simulator; a real project's rooms keep what they were doing
--- when VenueFlow's configuration changes, so the simulated ones do too.
--- Only rooms and devices that exist in both are carried.
function Sim:inherit(previous)
  if type(previous) ~= "table" then
    return
  end
  for id, room in pairs(self.rooms) do
    local old = previous.rooms and previous.rooms[id]
    if old then
      room.power, room.volume, room.muted = old.power, old.volume, old.muted
      room.videoDevice, room.audioDevice = old.videoDevice, old.audioDevice
    end
  end
  for id, device in pairs(self.devices) do
    local old = previous.devices and previous.devices[id]
    if old then
      device.online, device.power, device.level = old.online, old.power, old.level
    end
  end
  for id, fault in pairs(previous.faults or {}) do
    if self.rooms[id] or self.devices[id] then
      self.faults[id] = fault
    end
  end
  for id, vars in pairs(previous.variables or {}) do
    if self.devices[id] then
      self.variables[id] = U.copy(vars)
    end
  end
end

function Sim:populate(config)
  for _, s in ipairs(config.sources or {}) do
    if s.c4DeviceId then
      self:addDevice(
        s.c4DeviceId,
        { name = s.name, category = "source", driverFile = "sim_source.c4z", room = "Equipment Rack" }
      )
    end
  end
  for _, d in ipairs(config.displays or {}) do
    if d.c4RoomId then
      self:addRoom(d.c4RoomId, d.name)
    end
    if type(d.route) == "table" and type(d.route.command) == "table" and d.route.command.deviceId then
      self:addDevice(d.route.command.deviceId, {
        name = "Video processor",
        category = "video_switch",
        driverFile = "sim_matrix.c4z",
        room = "Equipment Rack",
      })
    end
    if d.c4DeviceId then
      self:addDevice(
        d.c4DeviceId,
        { name = d.name, category = "display", driverFile = "sim_tv.c4z", room = d.name, roomId = d.c4RoomId }
      )
    end
  end
  for _, z in ipairs(config.audioZones or {}) do
    if z.c4RoomId then
      self:addRoom(z.c4RoomId, z.name)
    end
  end
  for _, l in ipairs(config.lighting or {}) do
    for _, p in ipairs(l.presets or {}) do
      if p.deviceId then
        self:addDevice(p.deviceId, { name = l.name, category = "light", driverFile = "sim_light.c4z" })
      end
    end
  end
  for _, s in ipairs(config.shades or {}) do
    if s.deviceId then
      self:addDevice(s.deviceId, { name = s.name, category = "shade", driverFile = "sim_shade.c4z" })
    end
  end
end

--- A small made-up project, so discovery and mapping can be rehearsed in
--- Simulation before anything is mapped: eight display rooms with a TV each,
--- four sources, a video matrix, two audio rooms, a lighting-scene agent and
--- a shade. Ids do not collide with what a configuration already maps.
function Sim:demo()
  for n = 1, 8 do
    if self.rooms[1100 + n] == nil then
      self:addRoom(1100 + n, string.format("Demo TV %02d", n))
    end
    if self.devices[2100 + n] == nil then
      self:addDevice(2100 + n, {
        name = string.format("Demo TV %02d", n),
        category = "display",
        driverFile = "sim_tv.c4z",
        room = string.format("Demo TV %02d", n),
        roomId = 1100 + n,
      })
    end
  end
  for n, name in ipairs({ "Demo Satellite 1", "Demo Satellite 2", "Demo Cable", "Demo Signage Player" }) do
    if self.devices[3000 + n] == nil then
      self:addDevice(
        3000 + n,
        { name = name, category = "source", driverFile = "sim_source.c4z", room = "Equipment Rack" }
      )
    end
  end
  if self.devices[2900] == nil then
    self:addDevice(2900, {
      name = "Demo Video Matrix",
      category = "video_switch",
      driverFile = "sim_matrix.c4z",
      room = "Equipment Rack",
    })
  end
  for n, name in ipairs({ "Demo Bar Audio", "Demo Dining Audio" }) do
    if self.rooms[1200 + n] == nil then
      self:addRoom(1200 + n, name)
    end
  end
  if self.devices[4001] == nil then
    self:addDevice(4001, { name = "Demo Lighting Scenes", category = "lighting_scene", driverFile = "sim_light.c4z" })
  end
  if self.devices[7101] == nil then
    self:addDevice(7101, { name = "Demo Shade", category = "shade", driverFile = "sim_shade.c4z" })
  end
end

function Sim:setFault(id, fault)
  self.faults[id] = fault
end

function Sim:clearFaults()
  self.faults = {}
end

function Sim:_log(name, target, params)
  self.calls[#self.calls + 1] = { command = name, target = target, params = params }
end

function Sim:callCount()
  return #self.calls
end

function Sim:_changed(roomId)
  if self.onRoomChanged then
    pcall(self.onRoomChanged, roomId)
  end
end

--- Applies `mutate(room)` after the simulated latency, then reports the change.
function Sim:_later(roomId, mutate)
  local fault = self.faults[roomId]
  if fault == "silent" then
    return
  end
  local delay = fault == "slow" and self.slowMs or self.latencyMs
  local apply = function()
    local room = self.rooms[roomId]
    if room ~= nil then
      mutate(room, fault)
      self:_changed(roomId)
    end
  end
  if delay <= 0 then
    apply()
  else
    self:_schedule(delay, apply)
  end
end

--- One timer drives every pending simulated change (a 24-display scene must
--- not hold 24 timers on a controller in Simulation mode).
function Sim:_schedule(delayMs, fn)
  self.pending[#self.pending + 1] = { left = math.max(1, math.ceil(delayMs / M.STEP_MS)), fn = fn }
  self:_arm()
end

function Sim:_arm()
  if self.armed then
    return
  end
  self.armed = true
  self.timers.set("VfSimWheel", M.STEP_MS, function()
    self.armed = false
    local keep, due = {}, {}
    for _, p in ipairs(self.pending) do
      p.left = p.left - 1
      if p.left <= 0 then
        due[#due + 1] = p
      else
        keep[#keep + 1] = p
      end
    end
    self.pending = keep
    for _, p in ipairs(due) do
      pcall(p.fn)
    end
    if #self.pending > 0 then
      self:_arm()
    end
  end)
end

function Sim:_room(roomId)
  local room = self.rooms[roomId]
  if room == nil then
    return nil, "no such room"
  end
  if self.faults[roomId] == "offline" then
    return nil, "offline"
  end
  return room
end

-- ── the adapter interface ───────────────────────────────────────────────────

function Sim:adapter()
  local sim = self
  local A = { simulation = true }

  function A.selectVideo(roomId, deviceId)
    sim:_log("SELECT_VIDEO_DEVICE", roomId, { deviceid = deviceId })
    local room, err = sim:_room(roomId)
    if room == nil then
      return false, err
    end
    if sim.faults[deviceId] == "offline" then
      return false, "offline"
    end
    sim:_later(roomId, function(r, fault)
      r.power = true
      r.videoDevice = fault == "wrong" and 999999 or deviceId
      -- In a Control4 room, selecting video also brings that source's audio.
      r.audioDevice = r.videoDevice
    end)
    return true
  end

  function A.selectAudio(roomId, deviceId)
    sim:_log("SELECT_AUDIO_DEVICE", roomId, { deviceid = deviceId })
    local room, err = sim:_room(roomId)
    if room == nil then
      return false, err
    end
    if sim.faults[deviceId] == "offline" then
      return false, "offline"
    end
    sim:_later(roomId, function(r, fault)
      r.power = true
      r.audioDevice = fault == "wrong" and 999999 or deviceId
    end)
    return true
  end

  function A.roomOff(roomId)
    sim:_log("ROOM_OFF", roomId, {})
    local room, err = sim:_room(roomId)
    if room == nil then
      return false, err
    end
    sim:_later(roomId, function(r)
      r.power = false
      r.videoDevice = 0
      r.audioDevice = 0
    end)
    return true
  end

  function A.setVolume(roomId, level)
    sim:_log("SET_VOLUME_LEVEL", roomId, { LEVEL = level })
    local room, err = sim:_room(roomId)
    if room == nil then
      return false, err
    end
    sim:_later(roomId, function(r)
      r.volume = level
    end)
    return true
  end

  function A.setMute(roomId, muted)
    sim:_log(muted and "MUTE_ON" or "MUTE_OFF", roomId, {})
    local room, err = sim:_room(roomId)
    if room == nil then
      return false, err
    end
    sim:_later(roomId, function(r)
      r.muted = muted
    end)
    return true
  end

  function A.devicePower(deviceId, on)
    sim:_log(on and "ON" or "OFF", deviceId, {})
    local dev = sim.devices[deviceId]
    if dev == nil then
      return false, "no such device"
    end
    if sim.faults[deviceId] == "offline" or dev.online == false then
      return false, "offline"
    end
    if sim.faults[deviceId] ~= "silent" then
      dev.power = on
    end
    return true
  end

  function A.deviceCommand(deviceId, command, params)
    sim:_log(command, deviceId, U.copy(params or {}))
    local dev = sim.devices[deviceId]
    if dev == nil then
      return false, "no such device"
    end
    if sim.faults[deviceId] == "offline" or dev.online == false then
      return false, "offline"
    end
    dev.lastCommand = { command = command, params = U.copy(params or {}) }
    return true
  end

  function A.readRoom(roomId)
    local room = sim.rooms[roomId]
    if room == nil or sim.faults[roomId] == "offline" then
      return nil
    end
    return {
      power = room.power,
      volume = room.volume,
      muted = room.muted,
      videoDevice = room.videoDevice,
      audioDevice = room.audioDevice,
    }
  end

  function A.watchRooms(roomIds, callback)
    sim.onRoomChanged = callback
    sim.watched = U.copy(roomIds)
  end

  function A.deviceOnline(deviceId)
    local dev = sim.devices[deviceId]
    if dev == nil then
      return nil
    end
    if sim.faults[deviceId] == "offline" then
      return false
    end
    return dev.online ~= false
  end

  function A.readVariable(deviceId, name)
    local vars = sim.variables[deviceId]
    return vars and vars[name] or nil
  end

  function A.watchVariable(deviceId, name, callback)
    sim.variableWatchers = sim.variableWatchers or {}
    sim.variableWatchers[deviceId .. ":" .. name] = callback
    return true
  end

  function A.unwatchVariables()
    sim.variableWatchers = {}
  end

  function A.listDevices()
    local out = {}
    for id, room in pairs(sim.rooms) do
      out[#out + 1] = {
        id = id,
        name = room.name,
        room = room.name,
        roomId = id,
        driverFile = "roomdevice.c4i",
        category = "room",
      }
    end
    for id, dev in pairs(sim.devices) do
      out[#out + 1] = {
        id = id,
        name = dev.name or ("Device " .. id),
        room = dev.room or "",
        roomId = dev.roomId,
        driverFile = dev.driverFile or "sim.c4z",
        category = dev.category,
      }
    end
    table.sort(out, function(a, b)
      return a.id < b.id
    end)
    return out
  end

  function A.timeZone()
    return "Simulated/Venue"
  end

  return A
end

--- Sets a simulated Control4 variable and tells any watcher.
function Sim:setVariable(deviceId, name, value)
  self.variables[deviceId] = self.variables[deviceId] or {}
  self.variables[deviceId][name] = value
  local cb = self.variableWatchers and self.variableWatchers[deviceId .. ":" .. name]
  if cb then
    pcall(cb, deviceId, name, value)
  end
end

--- Changes a room behind VenueFlow's back (someone used a Control4 remote).
function Sim:external(roomId, changes)
  local room = self.rooms[roomId]
  if room == nil then
    return
  end
  for k, v in pairs(changes) do
    room[k] = v
  end
  self:_changed(roomId)
end

return M
