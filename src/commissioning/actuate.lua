--[[==========================================================================
  Commissioning Matrix - the actuation layer.

  One small adapter per kind of item. An adapter never calls Control4 itself:
  it says WHAT to send (`steps`), how to read a device's variables back
  (`read`), and whether what the device reports agrees with what was asked
  (`check`). The driver supplies the two real operations through
  `M.new{ send, vars }`, and a test supplies fakes.

  Command vocabularies are the ones the Mode Composer already uses on the
  bench for lights and shades (RAMP_TO_LEVEL, SET_LEVEL_TARGET). The AV
  commands (SELECT_AUDIO_DEVICE, SET_VOLUME_LEVEL, ROOM_OFF) and the sensor
  variable names are documented Control4 names that have NOT been measured
  here; the manual lists them as unverified.

  `check` answers one of:
    "match"       the device reports what was asked
    "mismatch"    the device reports something else
    "unreported"  the device reports nothing this adapter can read
============================================================================]]

local M = {}

local function num(v)
  return tonumber(v)
end

--- The first variable of `vars` (name -> value) among `names`.
local function firstVar(vars, names)
  for _, name in ipairs(names) do
    if vars[name] ~= nil and tostring(vars[name]) ~= "" then
      return vars[name], name
    end
  end
  return nil, nil
end

M.SENSOR_VARS = {
  "ContactState",
  "CONTACT_STATE",
  "Contact State",
  "STATE",
  "MotionState",
  "MOTION_STATE",
  "Motion",
  "MOTION",
  "OccupancyState",
  "OCCUPANCY_STATE",
  "Occupancy",
  "OCCUPANCY",
}

M.LIGHT_VARS = { "Brightness Percent", "LIGHT_LEVEL" }
M.SHADE_VARS = { "Level", "Blind Level", "Level Target", "LEVEL_TARGET", "Blind Level Target" }
M.AV_SOURCE_VARS = { "CURRENT_SELECTED_DEVICE", "SELECTED_DEVICE" }
M.AV_VOLUME_VARS = { "CURRENT_VOLUME", "VOLUME_LEVEL" }
M.AV_POWER_VARS = { "IS_ROOM_ON", "ROOM_ON", "POWER_STATE" }

local function truthy(v)
  v = tostring(v):lower()
  return v == "1" or v == "true" or v == "on"
end

-- ─── adapters ───────────────────────────────────────────────────────────────

local ADAPTERS = {}

ADAPTERS.light = {
  prompt = "The light ramps to full, then back to where it was. Did the lamp do that?",
  baseline = function(vars)
    return { level = num((firstVar(vars, M.LIGHT_VARS))) }
  end,
  steps = function(_, phase, baseline)
    if phase == "act" then
      return { { command = "RAMP_TO_LEVEL", params = { LEVEL = 100, TIME = 1000 } } }
    end
    return { { command = "RAMP_TO_LEVEL", params = { LEVEL = baseline.level or 0, TIME = 1000 } } }
  end,
  read = function(vars)
    return { level = num((firstVar(vars, M.LIGHT_VARS))) }
  end,
  check = function(phase, read, baseline)
    if read.level == nil then
      return "unreported", "the light did not report a level"
    end
    if phase == "act" then
      if read.level >= 95 then
        return "match", string.format("reported %d%% after a ramp to 100%%", read.level)
      end
      return "mismatch", string.format("asked for 100%%, device reports %d%%", read.level)
    end
    local want = baseline.level or 0
    if math.abs(read.level - want) <= 2 then
      return "match", string.format("back at %d%%", read.level)
    end
    return "mismatch", string.format("asked to return to %d%%, device reports %d%%", want, read.level)
  end,
}

ADAPTERS.shade = {
  prompt = "The shade moves to the other end, then back. Did it move?",
  settle_factor = 4, -- shades are slow
  baseline = function(vars)
    return { level = num((firstVar(vars, M.SHADE_VARS))) }
  end,
  steps = function(_, phase, baseline)
    if phase == "act" then
      -- Move to the end it is NOT at. Unknown position: open fully.
      local level = (baseline.level ~= nil and baseline.level >= 50) and 0 or 100
      return { { command = "SET_LEVEL_TARGET", params = { LEVEL_TARGET = level } } }
    end
    return { { command = "SET_LEVEL_TARGET", params = { LEVEL_TARGET = baseline.level or 0 } } }
  end,
  read = function(vars)
    return { level = num((firstVar(vars, M.SHADE_VARS))) }
  end,
  check = function(phase, read, baseline)
    if read.level == nil then
      return "unreported", "the shade did not report a position"
    end
    local want
    if phase == "act" then
      want = (baseline.level ~= nil and baseline.level >= 50) and 0 or 100
    else
      want = baseline.level or 0
    end
    if math.abs(read.level - want) <= 5 then
      return "match", string.format("reported %d%% (asked %d%%)", read.level, want)
    end
    return "mismatch", string.format("asked for %d%%, device reports %d%%", want, read.level)
  end,
}

ADAPTERS.av = {
  prompt = "The source plays in this room at a low volume, then the room returns. Did you hear it?",
  settle_factor = 2,
  validate = function(item)
    if num(item.source) == nil then
      return false, "no AV test source is set (property AV Test Source)"
    end
    return true
  end,
  baseline = function(vars)
    local power = firstVar(vars, M.AV_POWER_VARS)
    return {
      source = num((firstVar(vars, M.AV_SOURCE_VARS))),
      volume = num((firstVar(vars, M.AV_VOLUME_VARS))),
      on = power ~= nil and truthy(power) or nil,
    }
  end,
  steps = function(item, phase, baseline, options)
    local level = num(options and options.av_volume) or 15
    if phase == "act" then
      return {
        { command = "SELECT_AUDIO_DEVICE", params = { deviceid = num(item.source) } },
        { command = "SET_VOLUME_LEVEL", params = { LEVEL = level } },
      }
    end
    if baseline.on == false or baseline.source == nil then
      return { { command = "ROOM_OFF", params = {} } }
    end
    local steps = { { command = "SELECT_AUDIO_DEVICE", params = { deviceid = baseline.source } } }
    if baseline.volume ~= nil then
      steps[#steps + 1] = { command = "SET_VOLUME_LEVEL", params = { LEVEL = baseline.volume } }
    end
    return steps
  end,
  read = function(vars)
    local power = firstVar(vars, M.AV_POWER_VARS)
    return {
      source = num((firstVar(vars, M.AV_SOURCE_VARS))),
      volume = num((firstVar(vars, M.AV_VOLUME_VARS))),
      on = power ~= nil and truthy(power) or nil,
    }
  end,
  check = function(phase, read, baseline, item)
    if phase == "act" then
      if read.source == nil then
        return "unreported", "the room did not report its selected source"
      end
      if read.source == num(item.source) then
        return "match", "the room reports the test source selected"
      end
      return "mismatch", string.format("asked for source %s, room reports %s", tostring(item.source), tostring(read.source))
    end
    if baseline.on == false and read.on == true then
      return "mismatch", "the room should be off again but reports on"
    end
    return "match", "room returned"
  end,
}

ADAPTERS.sensor = {
  prompt = "Trigger the sensor now (open the door, walk past). It passes by itself when it reports a change.",
}

--- @param kind string
--- @return table|nil adapter
function M.adapterFor(kind)
  return ADAPTERS[kind]
end

--- The state variable worth watching on a sensor.
--- @param vars table name -> value
--- @return string|nil name, any value
function M.sensorVariable(vars)
  local value, name = firstVar(vars or {}, M.SENSOR_VARS)
  return name, value
end

--- The actuator the engine is given.
--- @param io table { send = fun(deviceId, command, params), vars = fun(deviceId):table name->value }
function M.new(io)
  local self = {}
  function self.adapter(kind)
    return ADAPTERS[kind]
  end
  --- AV rooms are commanded and read on the room device itself.
  function self.send(item, steps)
    for _, s in ipairs(steps or {}) do
      pcall(io.send, item.device_id, s.command, s.params or {})
    end
  end
  function self.read(item)
    local ok, vars = pcall(io.vars, item.device_id)
    return ok and type(vars) == "table" and vars or {}
  end
  return self
end

return M
