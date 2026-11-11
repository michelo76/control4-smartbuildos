--- Usage Analytics — what to measure, from the project (pure).
---
--- Classifies the project by VARIABLE SIGNATURE and EVENT NAMES, never by
--- device name (the Agent's rule: four measured impostors):
---
---   • ROOMS: the distinct `roomId`s GetDevices reports, each read with
---     GetDeviceVariables(roomId) for POWER_STATE and CURRENT_SELECTED_DEVICE
---     (the room variables the Agent already listens to).
---   • LIGHTS: devices exposing LIGHT_STATE, LIGHT_LEVEL or Brightness Percent.
---   • KEYPADS: devices whose catalogued events (tracer.catalog) are named
---     like a press — Pushed / Pressed / Clicked / Tapped / Double Tap /
---     Triple Tap — but not Released.
---
--- Bounded (M.LIMITS) and ordered by device id so a cap always cuts the same
--- devices; what did not fit is counted, never silently skipped.

local M = {}

M.LIMITS = { rooms = 64, lights = 200, keypads = 100, listeners = 600 }

M.ROOM_VARS = { POWER_STATE = true, CURRENT_SELECTED_DEVICE = true }
M.LIGHT_VARS = { LIGHT_STATE = true, LIGHT_LEVEL = true, ["Brightness Percent"] = true }

local PRESS_WORDS = { "push", "press", "click", "tap" }

function M.isPressEvent(name)
  local n = tostring(name or ""):lower()
  if n:find("release", 1, true) then
    return false
  end
  for _, w in ipairs(PRESS_WORDS) do
    if n:find(w, 1, true) then
      return true
    end
  end
  return false
end

local function sortedIds(t)
  local ids = {}
  for rawId, v in pairs(t or {}) do
    local id = tonumber(rawId)
    if id ~= nil and type(v) == "table" then
      ids[#ids + 1] = id
    end
  end
  table.sort(ids)
  return ids
end

--- @param deps table {
---   devices = table (GetDevices shape), readVariables = fun(id):table|nil,
---   catalog = tracer.catalog instance|nil, excluded = { [id] = true },
---   selfDeviceId = number|nil }
--- @return table plan { rooms = { [id] = { label, vars = { [varId] = name } } },
---   lights = { [id] = { label, room, vars } }, keypads = { [id] = { label, room, events = { [eid] = name } } },
---   summary = {...} }
function M.plan(deps)
  local devices = deps.devices or {}
  local excluded = deps.excluded or {}
  local plan = { rooms = {}, lights = {}, keypads = {}, summary = {} }
  local summary = {
    devices = 0,
    rooms = 0,
    rooms_without_vars = 0,
    lights = 0,
    keypads = 0,
    listeners = 0,
    subscriptions = 0,
    excluded = 0,
    over_cap = 0,
  }
  local listeners = 0

  -- Rooms from the roomId field, in id order.
  local roomNames = {}
  for _, id in ipairs(sortedIds(devices)) do
    local d = devices[id] or devices[tostring(id)]
    local rid = tonumber(d.roomId)
    if rid ~= nil and roomNames[rid] == nil then
      roomNames[rid] = tostring(d.roomName or ("Room " .. rid))
    end
  end
  local roomIds = {}
  for rid in pairs(roomNames) do
    roomIds[#roomIds + 1] = rid
  end
  table.sort(roomIds)
  for _, rid in ipairs(roomIds) do
    if excluded[rid] then
      summary.excluded = summary.excluded + 1
    elseif summary.rooms >= M.LIMITS.rooms then
      summary.over_cap = summary.over_cap + 1
    else
      local vars = deps.readVariables and deps.readVariables(rid) or nil
      local wanted = {}
      local n = 0
      if type(vars) == "table" then
        for varId, v in pairs(vars) do
          local vid = tonumber(varId)
          local name = type(v) == "table" and v.name or nil
          if vid ~= nil and name ~= nil and M.ROOM_VARS[name] then
            wanted[vid] = name
            n = n + 1
          end
        end
      end
      if n > 0 and listeners + n <= M.LIMITS.listeners then
        plan.rooms[rid] = { label = roomNames[rid], vars = wanted }
        summary.rooms = summary.rooms + 1
        listeners = listeners + n
      else
        summary.rooms_without_vars = summary.rooms_without_vars + 1
      end
    end
  end

  -- Lights and keypads from the device list.
  for _, id in ipairs(sortedIds(devices)) do
    local d = devices[id] or devices[tostring(id)]
    summary.devices = summary.devices + 1
    local driver = tostring(d.driverFileName or "")
    if id == deps.selfDeviceId or excluded[id] then
      if excluded[id] then
        summary.excluded = summary.excluded + 1
      end
    elseif roomNames[id] == nil then
      local label = tostring(d.deviceName or ("Device " .. id))
      local room = d.roomName
      -- Light?
      local vars = deps.readVariables and deps.readVariables(id) or nil
      local lightVars, n = {}, 0
      if type(vars) == "table" then
        for varId, v in pairs(vars) do
          local vid = tonumber(varId)
          local name = type(v) == "table" and v.name or nil
          if vid ~= nil and name ~= nil and M.LIGHT_VARS[name] then
            lightVars[vid] = name
            n = n + 1
          end
        end
      end
      if n > 0 then
        if summary.lights >= M.LIMITS.lights or listeners + n > M.LIMITS.listeners then
          summary.over_cap = summary.over_cap + 1
        else
          plan.lights[id] = { label = label, room = room, vars = lightVars }
          summary.lights = summary.lights + 1
          listeners = listeners + n
        end
      end
      -- Keypad? (a device can be both; e.g. a dimmer keypad)
      if deps.catalog ~= nil then
        local events = deps.catalog:eventsFor(id, driver)
        local presses, m = {}, 0
        for eid, e in pairs(events) do
          if e.known and M.isPressEvent(e.name) then
            presses[eid] = e.name
            m = m + 1
          end
        end
        if m > 0 then
          if summary.keypads >= M.LIMITS.keypads then
            summary.over_cap = summary.over_cap + 1
          else
            plan.keypads[id] = { label = label, room = room, events = presses }
            summary.keypads = summary.keypads + 1
            summary.subscriptions = summary.subscriptions + m
          end
        end
      end
    end
  end
  summary.listeners = listeners
  plan.summary = summary
  return plan
end

--- One line for the Sources property.
function M.describe(summary)
  if summary == nil then
    return "not planned yet"
  end
  local parts = {
    string.format(
      "%d room(s), %d light(s), %d keypad(s)",
      summary.rooms or 0,
      summary.lights or 0,
      summary.keypads or 0
    ),
    string.format("%d listener(s), %d event subscription(s)", summary.listeners or 0, summary.subscriptions or 0),
  }
  if (summary.rooms_without_vars or 0) > 0 then
    parts[#parts + 1] = summary.rooms_without_vars .. " room(s) without media variables"
  end
  if (summary.excluded or 0) > 0 then
    parts[#parts + 1] = summary.excluded .. " excluded"
  end
  if (summary.over_cap or 0) > 0 then
    parts[#parts + 1] = summary.over_cap .. " over the cap"
  end
  return table.concat(parts, "; ")
end

return M
