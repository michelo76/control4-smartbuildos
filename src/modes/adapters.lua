--- Device adapters: the capability layer between mode configuration and
--- Control4 proxies.
---
--- Every adapter DECLARES what it can do (`caps`) and the engine believes
--- the declaration, never an assumption — a device whose adapter cannot
--- read state is reported `unsupported` for capture/restore instead of
--- silently pretending (spec §8, §45, §108). Adapters build command lists
--- and read variable tables; they never call C4 themselves, so the whole
--- layer runs under the shim.
---
--- Classification order matters and is field-derived:
---   1. proxy name when the driver can supply it (GetProjectItems proxies) —
---      the most reliable signal;
---   2. variable signature — the Agent's measured patterns, including the
---      four documented impostors (weather-as-thermostat, T4-panel-as-light);
---   3. GENERIC — visible, honest, uncontrollable.
---
--- Command vocabularies come from docs/control4-capabilities.md; entries
--- marked there VERIFIED_BY_DOCS-only stay flagged in `caps.docs_only` so
--- test-mode results can hint when a vocabulary mismatch is the suspect.

local M = {}

--- Action result vocabulary (spec §109). SENT = fired without confirmation;
--- SUCCESS is reserved for verified state.
M.RESULTS = {
  SUCCESS = true,
  SENT = true,
  SKIPPED = true,
  WARNING = true,
  FAILED = true,
  UNSUPPORTED = true,
  TIMEOUT = true,
}

local function clamp(n, lo, hi)
  n = tonumber(n)
  if n == nil then
    return nil
  end
  return math.max(lo, math.min(hi, n))
end

local function hasVar(vars, name)
  return vars ~= nil and vars[name] ~= nil
end

--- Setpoint safety band, °F (same rationale as the Agent's clamp: a typo'd
--- 7°F setpoint must not freeze a house).
local SETPOINT_MIN_F, SETPOINT_MAX_F = 50, 90

-- ─── Adapter definitions ─────────────────────────────────────────────────────

M.ADAPTERS = {}

M.ADAPTERS.LIGHT = {
  class = "LIGHT",
  label = "Lighting",
  caps = { canReadState = true, canSetState = true, canRestoreState = true, supportsLevel = true, supportsRamp = true },
  proxyNames = { light_v2 = true, light = true, dimmer = true, switch = true, outlet_light = true },
  classify = function(info)
    local vars = info.vars or {}
    -- The T4 impostor: a touchpanel carries bare BRIGHTNESS (its screen)
    -- plus SCREENSAVER_* — a stronger identity that refuses membership.
    if hasVar(vars, "SCREENSAVER_MODE") or hasVar(vars, "PROXIMITY_SENSOR_ENABLED") then
      return false
    end
    return hasVar(vars, "Brightness Percent") or hasVar(vars, "LIGHT_STATE")
  end,
  read = function(vars)
    local level = tonumber(vars["Brightness Percent"]) or tonumber(vars["LIGHT_LEVEL"])
    local state = vars["LIGHT_STATE"]
    local on
    if state ~= nil then
      on = tostring(state) == "1" or tostring(state):lower() == "true"
    elseif level ~= nil then
      on = level > 0
    else
      return nil
    end
    return { on = on, level = level or (on and 100 or 0) }
  end,
  validate = function(state)
    if state.level ~= nil and clamp(state.level, 0, 100) == nil then
      return false, "level must be 0-100"
    end
    return true
  end,
  plan = function(state)
    local level = state.on == false and 0 or clamp(state.level, 0, 100)
    if level == nil then
      level = state.on and 100 or 0
    end
    local ramp = tonumber(state.ramp_ms) or 0
    if ramp > 0 then
      return { { command = "RAMP_TO_LEVEL", params = { LEVEL = level, TIME = ramp } } }
    end
    if level == 0 then
      return { { command = "OFF", params = {} } }
    end
    if level >= 100 then
      return { { command = "ON", params = {} } }
    end
    return { { command = "RAMP_TO_LEVEL", params = { LEVEL = level, TIME = 0 } } }
  end,
  describe = function(state)
    local level = state.on == false and 0 or state.level or 100
    if level == 0 then
      return "Off"
    end
    local s = level >= 100 and "On" or string.format("%d%%", level)
    if tonumber(state.ramp_ms) and state.ramp_ms > 0 then
      s = s .. string.format(" over %.0fs", state.ramp_ms / 1000)
    end
    return s
  end,
}

M.ADAPTERS.SHADE = {
  class = "SHADE",
  label = "Shades",
  -- Blind proxy convention: LEVEL_TARGET 0 = closed, 100 = open.
  caps = { canReadState = true, canSetState = true, canRestoreState = true, supportsPosition = true, docs_only = true },
  proxyNames = { blind = true, shade = true, uidriver_blind = true },
  classify = function(info)
    local vars = info.vars or {}
    return hasVar(vars, "Level Target") or hasVar(vars, "LEVEL_TARGET") or hasVar(vars, "Blind Level")
  end,
  read = function(vars)
    local level = tonumber(vars["Level Target"]) or tonumber(vars["LEVEL_TARGET"]) or tonumber(vars["Blind Level"])
    if level == nil then
      return nil
    end
    return { level = level }
  end,
  validate = function(state)
    if state.position == nil and state.level == nil then
      return false, "set position OPEN/CLOSED or level 0-100"
    end
    return true
  end,
  plan = function(state)
    local level = state.level
    if state.position == "CLOSED" then
      level = 0
    elseif state.position == "OPEN" then
      level = 100
    end
    level = clamp(level, 0, 100) or 0
    return { { command = "SET_LEVEL_TARGET", params = { LEVEL_TARGET = level } } }
  end,
  describe = function(state)
    if state.position then
      return state.position == "CLOSED" and "Closed" or "Open"
    end
    return string.format("%d%%", clamp(state.level, 0, 100) or 0)
  end,
}

M.ADAPTERS.THERMOSTAT = {
  class = "THERMOSTAT",
  label = "Climate",
  caps = { canReadState = true, canSetState = true, canRestoreState = true, supportsSetpoints = true, docs_only = true },
  proxyNames = { thermostat = true, thermostatV2 = true, thermostatv2 = true },
  classify = function(info)
    local vars = info.vars or {}
    -- The weather impostor answers the thermostat proxy with WARN modes.
    local modes = tostring(vars["HVAC_MODES_LIST"] or "")
    if modes:upper():find("WARN", 1, true) then
      return false
    end
    return hasVar(vars, "HVAC_MODE") and (hasVar(vars, "TEMPERATURE_F") or hasVar(vars, "TEMPERATURE_C"))
  end,
  read = function(vars)
    if not hasVar(vars, "HVAC_MODE") then
      return nil
    end
    return {
      hvac_mode = vars["HVAC_MODE"],
      heat_setpoint_f = tonumber(vars["HEAT_SETPOINT_F"]) or tonumber(vars["DISPLAY_HEATSETPOINT"]),
      cool_setpoint_f = tonumber(vars["COOL_SETPOINT_F"]),
      fan_mode = vars["FAN_MODE"],
    }
  end,
  validate = function(state)
    for _, key in ipairs({ "heat_setpoint_f", "cool_setpoint_f", "single_setpoint_f" }) do
      if state[key] ~= nil and clamp(state[key], SETPOINT_MIN_F, SETPOINT_MAX_F) ~= tonumber(state[key]) then
        return false, string.format("%s must be %d-%d°F", key, SETPOINT_MIN_F, SETPOINT_MAX_F)
      end
    end
    return true
  end,
  plan = function(state)
    local cmds = {}
    if state.hvac_mode then
      table.insert(cmds, { command = "SET_MODE_HVAC", params = { MODE = state.hvac_mode } })
    end
    if state.heat_setpoint_f then
      table.insert(cmds, {
        command = "SET_SETPOINT_HEAT",
        params = { FAHRENHEIT = clamp(state.heat_setpoint_f, SETPOINT_MIN_F, SETPOINT_MAX_F) },
      })
    end
    if state.cool_setpoint_f then
      table.insert(cmds, {
        command = "SET_SETPOINT_COOL",
        params = { FAHRENHEIT = clamp(state.cool_setpoint_f, SETPOINT_MIN_F, SETPOINT_MAX_F) },
      })
    end
    if state.single_setpoint_f then
      table.insert(cmds, {
        command = "SET_SETPOINT_SINGLE",
        params = { FAHRENHEIT = clamp(state.single_setpoint_f, SETPOINT_MIN_F, SETPOINT_MAX_F) },
      })
    end
    if state.fan_mode then
      table.insert(cmds, { command = "SET_MODE_FAN", params = { MODE = state.fan_mode } })
    end
    return cmds
  end,
  describe = function(state)
    local parts = {}
    if state.hvac_mode then
      table.insert(parts, tostring(state.hvac_mode))
    end
    if state.cool_setpoint_f then
      table.insert(parts, string.format("Cool %d°", state.cool_setpoint_f))
    end
    if state.heat_setpoint_f then
      table.insert(parts, string.format("Heat %d°", state.heat_setpoint_f))
    end
    if state.fan_mode then
      table.insert(parts, "Fan " .. tostring(state.fan_mode))
    end
    return #parts > 0 and table.concat(parts, ", ") or "No change"
  end,
}

M.ADAPTERS.FAN = {
  class = "FAN",
  label = "Fans",
  caps = { canReadState = true, canSetState = true, canRestoreState = true, supportsSpeed = true, docs_only = true },
  proxyNames = { fan = true },
  classify = function(info)
    return hasVar(info.vars or {}, "FAN_SPEED") or hasVar(info.vars or {}, "CURRENT_SPEED")
  end,
  read = function(vars)
    local speed = tonumber(vars["FAN_SPEED"]) or tonumber(vars["CURRENT_SPEED"])
    if speed == nil then
      return nil
    end
    return { speed = speed, on = speed > 0 }
  end,
  validate = function()
    return true
  end,
  plan = function(state)
    if state.on == false or state.speed == 0 then
      return { { command = "OFF", params = {} } }
    end
    if state.speed then
      return { { command = "SET_SPEED", params = { SPEED = clamp(state.speed, 0, 10) } } }
    end
    return { { command = "ON", params = {} } }
  end,
  describe = function(state)
    if state.on == false or state.speed == 0 then
      return "Off"
    end
    return state.speed and ("Speed " .. state.speed) or "On"
  end,
}

M.ADAPTERS.LOCK = {
  class = "LOCK",
  label = "Locks",
  -- UNLOCK is a sensitive action (spec §106): plan() refuses it unless the
  -- entry carries the explicit dealer acknowledgement flag.
  caps = {
    canReadState = true,
    canSetState = true,
    canRestoreState = false,
    supportsLock = true,
    sensitiveActions = { UNLOCK = true },
  },
  proxyNames = { lock = true },
  classify = function(info)
    local vars = info.vars or {}
    return hasVar(vars, "LOCK_STATUS")
      or hasVar(vars, "LOCK STATUS")
      or hasVar(vars, "LOCKED")
      or hasVar(vars, "LOCK_STATE")
      or hasVar(vars, "LOCKSTATE")
  end,
  read = function(vars)
    local raw = vars["LOCK_STATUS"] or vars["LOCK STATUS"] or vars["LOCKED"] or vars["LOCK_STATE"] or vars["LOCKSTATE"]
    if raw == nil then
      return nil
    end
    local s = tostring(raw):lower()
    return { locked = s == "locked" or s == "1" or s == "true" }
  end,
  validate = function(state)
    if state.locked == nil then
      return false, "set locked true/false"
    end
    return true
  end,
  plan = function(state)
    if state.locked then
      return { { command = "LOCK", params = {} } }
    end
    if not state.allow_sensitive then
      return nil, "UNLOCK requires the explicit Allow Sensitive Action flag on this device entry"
    end
    return { { command = "UNLOCK", params = {} } }
  end,
  describe = function(state)
    return state.locked and "Locked" or "Unlocked"
  end,
}

M.ADAPTERS.SECURITY = {
  class = "SECURITY",
  label = "Security",
  -- Arm needs dealer-configured ArmType; DISARM is sensitive and never part
  -- of a template. UserCode is injected by the driver from encrypted persist
  --- at plan time — it is never stored in mode config.
  caps = {
    canReadState = true,
    canSetState = true,
    canRestoreState = false,
    supportsArm = true,
    sensitiveActions = { DISARM = true },
  },
  proxyNames = { securitypanel = true, security = true },
  classify = function(info)
    return hasVar(info.vars or {}, "PARTITION_STATE")
  end,
  read = function(vars)
    if not hasVar(vars, "PARTITION_STATE") then
      return nil
    end
    return { partition_state = vars["PARTITION_STATE"], armed_type = vars["ARMED_TYPE"] }
  end,
  validate = function(state)
    if state.arm == nil then
      return false, "set arm to an ArmType (e.g. Away, Home) or DISARM"
    end
    return true
  end,
  plan = function(state, opts)
    opts = opts or {}
    if state.arm == "DISARM" then
      if not state.allow_sensitive then
        return nil, "DISARM requires the explicit Allow Sensitive Action flag on this device entry"
      end
      if not opts.user_code or opts.user_code == "" then
        return nil, "DISARM requires a user code (set via the Security User Code property)"
      end
      return {
        {
          command = "PARTITION_DISARM",
          params = { UserCode = opts.user_code, InterfaceID = "SmartBuildOS Mode Composer" },
          redact = { "UserCode" },
        },
      }
    end
    local params = { ArmType = state.arm, InterfaceID = "SmartBuildOS Mode Composer" }
    local redact = nil
    if opts.user_code and opts.user_code ~= "" then
      params.UserCode = opts.user_code
      redact = { "UserCode" }
    end
    return { { command = "PARTITION_ARM", params = params, redact = redact } }
  end,
  describe = function(state)
    return state.arm == "DISARM" and "Disarm" or ("Arm " .. tostring(state.arm))
  end,
}

M.ADAPTERS.ROOM = {
  class = "ROOM",
  label = "Media",
  -- Target is the ROOM device id. Power-off is the reliable, verified
  -- vocabulary; source selection is best-effort.
  caps = {
    canReadState = true,
    canSetState = true,
    canRestoreState = false,
    supportsPower = true,
    supportsSource = true,
    supportsVolume = true,
  },
  proxyNames = { roomdevice = true, room = true },
  classify = function(info)
    return info.isRoom == true
  end,
  read = function(vars)
    local power = vars["POWER_STATE"]
    if power == nil then
      return nil
    end
    return {
      power = tostring(power),
      source = vars["CURRENT_SELECTED_DEVICE"],
      volume = tonumber(vars["CURRENT_VOLUME"]),
    }
  end,
  validate = function()
    return true
  end,
  plan = function(state)
    local cmds = {}
    if state.power == "OFF" or state.power == false then
      return { { command = "ROOM_OFF", params = {} } }
    end
    if state.source_audio then
      table.insert(cmds, { command = "SELECT_AUDIO_DEVICE", params = { deviceid = state.source_audio } })
    end
    if state.source_video then
      table.insert(cmds, { command = "SELECT_VIDEO_DEVICE", params = { deviceid = state.source_video } })
    end
    if state.volume then
      table.insert(cmds, { command = "SET_VOLUME_LEVEL", params = { LEVEL = clamp(state.volume, 0, 100) } })
    end
    return cmds
  end,
  describe = function(state)
    if state.power == "OFF" or state.power == false then
      return "Off"
    end
    local parts = {}
    if state.source_audio or state.source_video then
      table.insert(parts, "Source set")
    end
    if state.volume then
      table.insert(parts, string.format("Volume %d%%", state.volume))
    end
    return #parts > 0 and table.concat(parts, ", ") or "No change"
  end,
}

M.ADAPTERS.GARAGE = {
  class = "GARAGE",
  label = "Garage",
  caps = { canReadState = true, canSetState = true, canRestoreState = false, sensitiveActions = { OPEN = true } },
  proxyNames = { garagedoor = true, relaycontact = true },
  classify = function(info)
    local name = tostring(info.proxy or ""):lower()
    return name:find("garage", 1, true) ~= nil
  end,
  read = function(vars)
    local raw = vars["GARAGE_DOOR_STATE"] or vars["STATE"] or vars["RELAY_STATE"]
    if raw == nil then
      return nil
    end
    local s = tostring(raw):lower()
    return { open = s == "open" or s == "opened" or s == "1" }
  end,
  validate = function(state)
    if state.open == nil then
      return false, "set open true/false"
    end
    return true
  end,
  plan = function(state)
    if state.open then
      if not state.allow_sensitive then
        return nil, "Opening a garage requires the explicit Allow Sensitive Action flag on this device entry"
      end
      return { { command = "OPEN", params = {} } }
    end
    return { { command = "CLOSE", params = {} } }
  end,
  describe = function(state)
    return state.open and "Open" or "Closed"
  end,
}

M.ADAPTERS.RELAY = {
  class = "RELAY",
  label = "Relays",
  caps = { canReadState = false, canSetState = true, canRestoreState = false },
  proxyNames = { relay = true, relaysingle = true },
  classify = function()
    return false -- relays are opted in by proxy name / dealer selection only
  end,
  read = function()
    return nil
  end,
  validate = function(state)
    if state.closed == nil then
      return false, "set closed true/false"
    end
    return true
  end,
  plan = function(state)
    return { { command = state.closed and "CLOSE" or "OPEN", params = {} } }
  end,
  describe = function(state)
    return state.closed and "Closed" or "Open"
  end,
}

M.ADAPTERS.GENERIC = {
  class = "GENERIC",
  label = "Other",
  caps = { canReadState = false, canSetState = false, canRestoreState = false },
  classify = function()
    return true
  end,
  read = function()
    return nil
  end,
  validate = function()
    return false, "this device type is not supported by Mode Composer — use Composer programming on the mode's events"
  end,
  plan = function()
    return nil, "unsupported device"
  end,
  describe = function()
    return "Unsupported"
  end,
}

--- Classification order: specific before generic; GENERIC is the honest
--- fallback and must stay last.
M.CLASSIFY_ORDER = { "SECURITY", "THERMOSTAT", "LOCK", "SHADE", "FAN", "LIGHT", "GARAGE", "ROOM", "RELAY", "GENERIC" }

--- Classify one device.
--- @param info table {proxy?, vars?, deviceName?, driverFileName?, isRoom?}
--- @return table adapter
function M.classify(info)
  -- Pass 1: proxy name, the strongest signal, when the caller has it.
  local proxy = tostring(info.proxy or ""):lower()
  if proxy ~= "" then
    for _, class in ipairs(M.CLASSIFY_ORDER) do
      local adapter = M.ADAPTERS[class]
      if adapter.proxyNames and adapter.proxyNames[proxy] then
        return adapter
      end
    end
  end
  -- Pass 2: variable signatures.
  for _, class in ipairs(M.CLASSIFY_ORDER) do
    local adapter = M.ADAPTERS[class]
    if adapter.classify(info) then
      return adapter
    end
  end
  return M.ADAPTERS.GENERIC
end

--- Support level for the dealer UI (spec §45).
function M.supportLabel(adapter)
  if adapter.class == "GENERIC" then
    return "Unsupported"
  end
  if adapter.caps.canReadState and adapter.caps.canSetState then
    return "Supported"
  end
  return "Partially Supported"
end

return M
