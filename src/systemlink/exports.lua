--- Source-device exports and remote commands: the owner-side model.
---
--- Pure module. An EXPORT is the owner's explicit decision to present one
--- local device to the linked project: which device, under what name, as
--- which companion kind, view-only or controllable, which operations, and
--- an optional control schedule. Each export becomes a handful of ordinary
--- shared items (the fields below) that the peer mirrors; a companion
--- driver on the peer presents those fields natively and sends commands
--- back, which this module validates before the driver touches the device.
---
--- Evidence for every command/variable name is cited in
--- docs/system-link/CAPABILITY-MATRIX.md (SmartBuildOS repo). Names marked
--- CANDIDATE are measured-in-the-field variable names (the Agent's lights
--- and climate signatures), not documented ones, and the driver reports a
--- field as `unavailable` when none of the candidates exists on the device.

local M = {}

--- Companion kinds. `gate` is the licence feature that must be present in
--- the pair entitlement before the kind can be exported (SL-07).
M.KINDS = {
  light = { gate = "LIGHT", control = true },
  relay = { gate = "RELAY", control = true },
  contact = { gate = "SENSOR", control = false },
  temperature = { gate = "SENSOR", control = false },
  thermostat = { gate = "THERMOSTAT", control = true },
  shade = { gate = "SHADE", control = true },
  -- A room's media state, read-only: what's playing, volume, on/off. The
  -- variable names are the ones Mode Composer reads from rooms in the field
  -- (POWER_STATE, CURRENT_SELECTED_DEVICE, CURRENT_VOLUME) and the ones the
  -- Agent observes for media info; a room that lacks them reports the field
  -- unavailable. No control verb exists for a remote room in this release.
  media = { gate = "BASE", control = false },
  -- A scene: no device, no state of its own. The owner names it; the other
  -- side runs it through a request (routine "scene:<name>") and the owner's
  -- programming reports the result, which lands in the two fields below.
  scene = { gate = "BASE", control = true, virtual = true },
  -- Batch 4 (SL-07): each of these actuates something unverified on a real
  -- controller, so its CONTROL is behind its own licence feature, off by
  -- default. Status (lock, gate, fan) travels on BASE; the gate name is what
  -- validateCommand checks before any op runs, and what define() checks
  -- before a controllable export can even be created.
  lock = { gate = "LOCK", control = true, status_gate = "BASE" },
  gate = { gate = "GATE", control = true, status_gate = "BASE" },
  fan = { gate = "FAN", control = true, status_gate = "BASE" },
  -- A button is pure control (it fires the owner's programming): gated whole.
  button = { gate = "BUTTON", control = true, virtual = true },
}

--- Shared-item fields per kind: name suffix, type, schema, and the device
--- variable candidates the owner watches for it.
M.FIELDS = {
  light = {
    { suffix = "On", type = "BOOLEAN", vars = { "LIGHT_STATE" }, map = "bool" },
    {
      suffix = "Level",
      type = "INTEGER",
      min = 0,
      max = 100,
      vars = { "Brightness Percent", "LIGHT_LEVEL", "Current Light Level" },
      map = "int",
    },
  },
  relay = {
    { suffix = "Closed", type = "BOOLEAN", vars = { "STATE", "RELAY_STATE", "Closed" }, map = "relay" },
  },
  contact = {
    { suffix = "Open", type = "BOOLEAN", vars = { "STATE", "CONTACT_STATE", "Opened" }, map = "contact" },
  },
  scene = {
    { suffix = "Last_Run", type = "STRING", vars = {}, map = "str" },
    { suffix = "Last_Result", type = "STRING", vars = {}, map = "str" },
  },
  -- Variable candidates: the names Mode Composer's adapters read in the
  -- field for locks, garage doors and fans (src/modes/adapters.lua).
  lock = {
    {
      suffix = "Locked",
      type = "BOOLEAN",
      vars = { "LOCK_STATUS", "LOCK STATUS", "LOCKED", "LOCK_STATE", "LOCKSTATE" },
      map = "lock",
    },
  },
  gate = {
    { suffix = "Open", type = "BOOLEAN", vars = { "GARAGE_DOOR_STATE", "STATE", "RELAY_STATE" }, map = "garage" },
  },
  fan = {
    { suffix = "Speed", type = "INTEGER", min = 0, max = 10, vars = { "FAN_SPEED", "CURRENT_SPEED" }, map = "int" },
  },
  button = {
    { suffix = "Last_Pressed", type = "STRING", vars = {}, map = "str" },
  },
  media = {
    { suffix = "Powered", type = "BOOLEAN", vars = { "POWER_STATE" }, map = "bool" },
    { suffix = "Source", type = "STRING", vars = { "CURRENT_SELECTED_DEVICE" }, map = "device_name" },
    {
      suffix = "Volume",
      type = "INTEGER",
      min = 0,
      max = 100,
      vars = { "CURRENT_VOLUME", "VOLUME_LEVEL" },
      map = "int",
    },
    {
      suffix = "Media",
      type = "STRING",
      vars = { "CURRENT MEDIA INFO", "CURRENT_MEDIA", "MEDIA WALL INFO" },
      map = "str",
    },
  },
  temperature = {
    {
      suffix = "Fahrenheit",
      type = "DECIMAL",
      precision = 1,
      vars = { "TEMPERATURE_F", "TEMPERATURE", "Temperature" },
      map = "num",
    },
    { suffix = "Celsius", type = "DECIMAL", precision = 1, vars = { "TEMPERATURE_C" }, map = "num" },
  },
  thermostat = {
    {
      suffix = "Temperature",
      type = "DECIMAL",
      precision = 1,
      vars = { "TEMPERATURE_F", "TEMPERATURE_C", "V1 TEMPERATURE" },
      map = "num",
    },
    {
      suffix = "Heat_Setpoint",
      type = "DECIMAL",
      precision = 1,
      vars = { "HEAT_SETPOINT_F", "DISPLAY_HEATSETPOINT", "HEAT_SETPOINT_C", "V1 HEAT_SETPOINT" },
      map = "num",
    },
    {
      suffix = "Cool_Setpoint",
      type = "DECIMAL",
      precision = 1,
      vars = { "COOL_SETPOINT_F", "DISPLAY_COOLSETPOINT", "COOL_SETPOINT_C", "V1 COOL_SETPOINT" },
      map = "num",
    },
    { suffix = "HVAC_Mode", type = "STRING", vars = { "HVAC_MODE", "ANA_HVACMODE" }, map = "str" },
    { suffix = "HVAC_State", type = "STRING", vars = { "HVAC_STATE" }, map = "str" },
    { suffix = "Fan_Mode", type = "STRING", vars = { "FAN_MODE" }, map = "str" },
    { suffix = "Scale", type = "STRING", vars = { "SCALE" }, map = "str" },
  },
  shade = {
    { suffix = "Level", type = "INTEGER", min = 0, max = 100, vars = { "LEVEL", "Level", "POSITION" }, map = "int" },
    { suffix = "Moving", type = "BOOLEAN", vars = { "MOVING", "IS_MOVING" }, map = "bool" },
  },
}

--- Operations a controllable export may permit, and the device commands
--- each one becomes on the owner. Evidence: Light V2 RAMP_TO_LEVEL is the
--- SendToDevice example in the API doc; ON/OFF/SET_LEVEL are Control4's own
--- c4hook_light_v2; relay OPEN/CLOSE/TOGGLE/TRIGGER are c4hook_relay;
--- thermostat SET_SETPOINT_HEAT/COOL/SET_MODE_HVAC are the Agent's measured
--- runner plus Bond heater; blind OPEN/CLOSE/STOP/SET_LEVEL_TARGET are the
--- Bond shade and C4-Z2IO blind hook. None is hardware-validated here.
M.OPS = {
  light = {
    on = function()
      return { { "ON", {} } }
    end,
    off = function()
      return { { "OFF", {} } }
    end,
    set_level = function(p)
      local level = tonumber(p.level)
      if level == nil or level < 0 or level > 100 then
        return nil, "level must be 0..100"
      end
      local time = tonumber(p.time_ms) or 0
      if time < 0 or time > 60000 then
        return nil, "time_ms must be 0..60000"
      end
      return { { "RAMP_TO_LEVEL", { LEVEL = math.floor(level + 0.5), TIME = math.floor(time) } } }
    end,
  },
  relay = {
    open = function()
      return { { "OPEN", {} } }
    end,
    close = function()
      return { { "CLOSE", {} } }
    end,
    toggle = function()
      return { { "TOGGLE", {} } }
    end,
    -- A pulse is ONE command; the device terminates it locally. Never a
    -- second internet message to release it (spec §25).
    trigger = function()
      return { { "TRIGGER", {} } }
    end,
  },
  thermostat = {
    set_heat = function(p)
      local v = tonumber(p.setpoint)
      if v == nil then
        return nil, "setpoint required"
      end
      return { { "SET_SETPOINT_HEAT", { FAHRENHEIT = v } } }
    end,
    set_cool = function(p)
      local v = tonumber(p.setpoint)
      if v == nil then
        return nil, "setpoint required"
      end
      return { { "SET_SETPOINT_COOL", { FAHRENHEIT = v } } }
    end,
    set_mode = function(p)
      local m = tostring(p.mode or "")
      if m == "" then
        return nil, "mode required"
      end
      return { { "SET_MODE_HVAC", { MODE = m } } }
    end,
    set_fan = function(p)
      local m = tostring(p.mode or "")
      if m == "" then
        return nil, "mode required"
      end
      return { { "SET_MODE_FAN", { MODE = m } } }
    end,
  },
  lock = {
    lock = function()
      return { { "LOCK", {} } }
    end,
    -- unlock is validated in validateCommand: it also needs the export's
    -- explicit allow_unlock, set on purpose by the owner's dealer.
    unlock = function()
      return { { "UNLOCK", {} } }
    end,
  },
  gate = {
    -- The owner picks the relay that drives the door (Control4's own
    -- garagedoor_relay_control pattern): a pulse, or open/close where the
    -- relay driver distinguishes them. Acceptance is not position.
    trigger = function()
      return { { "TRIGGER", {} } }
    end,
    open = function()
      return { { "OPEN", {} } }
    end,
    close = function()
      return { { "CLOSE", {} } }
    end,
  },
  fan = {
    on = function()
      return { { "ON", {} } }
    end,
    off = function()
      return { { "OFF", {} } }
    end,
    set_speed = function(p)
      local speed = tonumber(p.speed)
      if speed == nil or speed < 0 or speed > 10 then
        return nil, "speed must be 0..10"
      end
      return { { "SET_SPEED", { SPEED = math.floor(speed + 0.5) } } }
    end,
  },
  shade = {
    open = function()
      return { { "OPEN", {} } }
    end,
    close = function()
      return { { "CLOSE", {} } }
    end,
    stop = function()
      return { { "STOP", {} } }
    end,
    set_level = function(p)
      local level = tonumber(p.level)
      if level == nil or level < 0 or level > 100 then
        return nil, "level must be 0..100"
      end
      return { { "SET_LEVEL_TARGET", { LEVEL_TARGET = math.floor(level + 0.5) } } }
    end,
  },
}

--- The routine a request carries to run a scene export on its owner, and
--- the export name it names (nil when the routine is not a scene).
M.SCENE_ROUTINE_PREFIX = "scene:"
function M.sceneRoutine(name)
  return M.SCENE_ROUTINE_PREFIX .. tostring(name)
end
function M.sceneFromRoutine(routine)
  return tostring(routine or ""):match("^scene:([A-Za-z][A-Za-z0-9_]*)$")
end

--- Non-idempotent operations: never retried, never replayed (spec §29).
M.NON_IDEMPOTENT = { toggle = true, trigger = true, stop = true, unlock = true }

--- The routine a button press carries ("button:<Name>"), as a named event.
M.BUTTON_EVENT_PREFIX = "button:"
function M.buttonEvent(name)
  return M.BUTTON_EVENT_PREFIX .. tostring(name)
end
function M.buttonFromEvent(def)
  return tostring(def or ""):match("^button:([A-Za-z][A-Za-z0-9_]*)$")
end

--- Creates an export definition. Returns def or nil, reason.
--- opts = { id, name, kind, device_id, control, ops (list|nil), schedule, device_name }
function M.define(opts, features)
  local kind = M.KINDS[opts.kind]
  if not kind then
    return nil, "unknown companion kind " .. tostring(opts.kind)
  end
  local wantsControl = opts.control == true and kind.control
  if features and not features[kind.gate] then
    if not (kind.status_gate and features[kind.status_gate] and not wantsControl) then
      return nil,
        "companion kind "
          .. opts.kind
          .. " requires the "
          .. kind.gate
          .. " feature on the pair license"
          .. (kind.status_gate and " (status only works without it: export with Control = View only)" or "")
    end
  end
  if type(opts.name) ~= "string" or not opts.name:match("^[A-Za-z][A-Za-z0-9_]*$") or #opts.name > 40 then
    return nil, "export name must be letters, digits and underscores (max 40)"
  end
  local deviceId = tonumber(opts.device_id)
  if kind.virtual then
    deviceId = 0
  elseif not deviceId or deviceId <= 0 then
    return nil, "a source device is required"
  end
  local control = opts.control == true and kind.control
  local ops = {}
  if control then
    local allowed = M.OPS[opts.kind] or {}
    if type(opts.ops) == "table" and #opts.ops > 0 then
      for _, op in ipairs(opts.ops) do
        if not allowed[op] then
          return nil, "operation " .. tostring(op) .. " is not available for " .. opts.kind
        end
        ops[#ops + 1] = op
      end
    else
      for op in pairs(allowed) do
        ops[#ops + 1] = op
      end
      table.sort(ops)
    end
  end
  if opts.schedule ~= nil then
    local ok, err = M.validateSchedule(opts.schedule)
    if not ok then
      return nil, err
    end
  end
  return {
    id = opts.id,
    name = opts.name,
    kind = opts.kind,
    device_id = deviceId, -- LOCAL id: never leaves this controller
    device_name = opts.device_name,
    control = control,
    ops = ops,
    schedule = opts.schedule,
    allow_unlock = opts.allow_unlock == true,
    fields = {}, -- [suffix] = { item_id, var_id, var_name }
  }
end

--- What the peer is told about an export (no local ids).
function M.describe(exp)
  return {
    id = exp.id,
    name = exp.name,
    kind = exp.kind,
    control = exp.control,
    ops = exp.ops,
    schedule_tz = exp.schedule and exp.schedule.tz or nil,
    -- The windows travel too (no secrets in them) so the companion can show
    -- the control window instead of a bare refusal.
    schedule = exp.schedule,
  }
end

local DAY_NAMES = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }

--- "Mon–Fri 07:00–22:00; Sat,Sun 09:00–20:00 (America/New_York)" or nil.
function M.scheduleText(schedule)
  if type(schedule) ~= "table" or type(schedule.windows) ~= "table" then
    return nil
  end
  local parts = {}
  for _, w in ipairs(schedule.windows) do
    local days = {}
    for _, d in ipairs(w.days or {}) do
      days[#days + 1] = DAY_NAMES[d] or tostring(d)
    end
    local dayText
    if #days == 7 then
      dayText = "every day"
    elseif #days == 5 and table.concat(days, ",") == "Mon,Tue,Wed,Thu,Fri" then
      dayText = "Mon–Fri"
    else
      dayText = table.concat(days, ",")
    end
    parts[#parts + 1] = string.format("%s %s–%s", dayText, tostring(w.from), tostring(w.to))
  end
  return table.concat(parts, "; ") .. (schedule.tz and (" (" .. tostring(schedule.tz) .. ")") or "")
end

--- The shared-item definitions an export contributes.
function M.itemDefinitions(exp, ownerEndpoint)
  local out = {}
  for _, f in ipairs(M.FIELDS[exp.kind] or {}) do
    local def = {
      name = exp.name .. "_" .. f.suffix,
      type = f.type,
      owner = ownerEndpoint,
      group = exp.name,
      min = f.min,
      max = f.max,
      precision = f.precision,
      companion = M.describe(exp),
      export_enabled = true,
    }
    def.companion.field = f.suffix
    out[#out + 1] = def
  end
  return out
end

--- Picks, from a device's variable list ({ [id] = { name = … } }), the
--- variable ids to watch per field. Returns { [suffix] = { id, name } }.
function M.resolveVariables(exp, vars)
  local byName = {}
  for varId, v in pairs(vars or {}) do
    local id = tonumber(varId)
    local name = type(v) == "table" and v.name or nil
    if id and type(name) == "string" then
      byName[name] = id
      byName[name:upper()] = byName[name:upper()] or id
    end
  end
  local out = {}
  for _, f in ipairs(M.FIELDS[exp.kind] or {}) do
    for _, cand in ipairs(f.vars) do
      local id = byName[cand] or byName[cand:upper()]
      if id then
        out[f.suffix] = { id = id, name = cand }
        break
      end
    end
  end
  return out
end

--- Converts a raw variable value into the field's typed value (or nil for
--- unavailable).
--- The map kind of a field ("bool", "int", "device_name", …) or nil.
function M.fieldMap(exp, suffix)
  for _, f in ipairs(M.FIELDS[exp.kind] or {}) do
    if f.suffix == suffix then
      return f.map
    end
  end
  return nil
end

function M.mapValue(exp, suffix, raw)
  local field
  for _, f in ipairs(M.FIELDS[exp.kind] or {}) do
    if f.suffix == suffix then
      field = f
      break
    end
  end
  if not field then
    return nil
  end
  local s = tostring(raw == nil and "" or raw)
  if field.map == "bool" then
    local l = s:lower()
    if l == "1" or l == "true" or l == "on" then
      return true
    elseif l == "0" or l == "false" or l == "off" then
      return false
    end
    return nil
  elseif field.map == "int" then
    local n = tonumber(s)
    return n and math.floor(n + 0.5) or nil
  elseif field.map == "num" then
    return tonumber(s)
  elseif field.map == "lock" then
    -- Mode Composer's lock adapter: "locked" / 1 / true mean locked.
    local l = s:lower()
    if l == "locked" or l == "1" or l == "true" then
      return true
    elseif l == "unlocked" or l == "0" or l == "false" then
      return false
    end
    return nil
  elseif field.map == "garage" then
    -- Mode Composer's garage adapter: "open" / "opened" / 1 mean open.
    local l = s:lower()
    if l == "open" or l == "opened" or l == "1" or l == "true" then
      return true
    elseif l == "closed" or l == "close" or l == "0" or l == "false" then
      return false
    end
    return nil
  elseif field.map == "str" or field.map == "device_name" then
    -- device_name: the driver resolves the id to a name before mapping;
    -- an unresolved id still travels as text rather than as "unavailable".
    s = s:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
    if s == "" then
      return nil
    end
    return #s > 256 and s:sub(1, 256) or s
  elseif field.map == "relay" then
    -- Relay STATE: Control4's relay hook reports CLOSED when energised.
    local l = s:lower()
    if l == "closed" or l == "1" or l == "true" then
      return true
    elseif l == "opened" or l == "open" or l == "0" or l == "false" then
      return false
    end
    return nil
  elseif field.map == "contact" then
    local l = s:lower()
    if l == "opened" or l == "open" or l == "1" or l == "true" then
      return true
    elseif l == "closed" or l == "0" or l == "false" then
      return false
    end
    return nil
  end
  return s
end

-- ── Schedules ───────────────────────────────────────────────────────────────

--- schedule = { tz = "America/Los_Angeles", windows = { { days = {1..7}, from = "HH:MM", to = "HH:MM" } } }
--- Days use 1 = Sunday … 7 = Saturday (os.date wday). The timezone is the
--- OWNER's declared zone: the owner evaluates with its own local clock.
function M.validateSchedule(s)
  if type(s) ~= "table" then
    return false, "schedule must be a table"
  end
  if type(s.tz) ~= "string" or s.tz == "" then
    return false, "schedule.tz is required"
  end
  if type(s.windows) ~= "table" or #s.windows == 0 then
    return false, "schedule needs at least one window"
  end
  for _, w in ipairs(s.windows) do
    if type(w.days) ~= "table" or #w.days == 0 then
      return false, "window.days required"
    end
    for _, d in ipairs(w.days) do
      if type(d) ~= "number" or d < 1 or d > 7 then
        return false, "window.days are 1..7"
      end
    end
    for _, k in ipairs({ "from", "to" }) do
      if type(w[k]) ~= "string" or not w[k]:match("^%d%d:%d%d$") then
        return false, "window." .. k .. " must be HH:MM"
      end
    end
  end
  return true
end

--- Whether the owner's local time (an os.date("*t") table) falls inside a
--- window. Returns permitted, reason. An untrusted clock (year < 2020)
--- fails CLOSED. Overnight windows (from > to) are supported. DST is the
--- OS's business: os.date already applies the controller's zone rules.
function M.scheduleAllows(schedule, localTime)
  if schedule == nil then
    return true, "no schedule"
  end
  if type(localTime) ~= "table" or not localTime.year or localTime.year < 2020 then
    return false, "controller clock not trustworthy; restricted actions fail closed"
  end
  local minutes = localTime.hour * 60 + localTime.min
  for _, w in ipairs(schedule.windows) do
    local fh, fm = w.from:match("^(%d%d):(%d%d)$")
    local th, tm = w.to:match("^(%d%d):(%d%d)$")
    local from = tonumber(fh) * 60 + tonumber(fm)
    local to = tonumber(th) * 60 + tonumber(tm)
    local today, yesterday = false, false
    for _, d in ipairs(w.days) do
      if d == localTime.wday then
        today = true
      end
      if d == (localTime.wday == 1 and 7 or localTime.wday - 1) then
        yesterday = true
      end
    end
    if from <= to then
      if today and minutes >= from and minutes < to then
        return true, "inside window"
      end
    else
      -- overnight: from today until to tomorrow
      if (today and minutes >= from) or (yesterday and minutes < to) then
        return true, "inside overnight window"
      end
    end
  end
  return false, "outside the permitted schedule"
end

-- ── Command validation (owner side) ─────────────────────────────────────────

--- body = { routine = "<kind>.<op>", target = exportId, params = {...} }
--- ctx = { features = set, commandsPermitted = bool, localTime = os.date("*t") }
--- Returns commands (list of { name, params }) or nil, reason.
function M.validateCommand(exp, body, ctx)
  if not exp then
    return nil, "unknown export"
  end
  local kind, op = tostring(body.routine or ""):match("^(%a+)%.(%a[%w_]*)$")
  if not kind or kind ~= exp.kind then
    return nil, "routine does not match the export kind"
  end
  if not exp.control then
    return nil, "export is view-only"
  end
  local permitted = false
  for _, o in ipairs(exp.ops) do
    if o == op then
      permitted = true
    end
  end
  if not permitted then
    return nil, "operation " .. op .. " is not permitted on this export"
  end
  if ctx and ctx.features and not ctx.features[M.KINDS[kind].gate] then
    return nil, "feature " .. M.KINDS[kind].gate .. " is not licensed"
  end
  if kind == "lock" and op == "unlock" and exp.allow_unlock ~= true then
    return nil, "unlock requires Allow Unlock on this export, set on purpose by the owner"
  end
  if ctx and ctx.commandsPermitted == false then
    return nil, "commands are suspended"
  end
  local allowed, why = M.scheduleAllows(exp.schedule, ctx and ctx.localTime)
  if not allowed then
    return nil, why
  end
  local builder = M.OPS[kind][op]
  local commands, err = builder(body.params or {})
  if not commands then
    return nil, err
  end
  local out = {}
  for _, c in ipairs(commands) do
    out[#out + 1] = { name = c[1], params = c[2] }
  end
  return out
end

return M
