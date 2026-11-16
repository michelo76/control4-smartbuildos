--- VenueFlow: the Control4 adapter. The ONLY module that commands or reads
--- Control4 devices; everything above it is pure and runs on the simulator.
---
--- What each call rests on (docs/smartbuildos-venueflow/SDK_RESEARCH.md):
---   C4:SendToDevice(id, command, params)           official API (1.6.0+)
---   room SELECT_VIDEO_DEVICE / SELECT_AUDIO_DEVICE {deviceid}, ROOM_OFF
---        not in the official documentation; used in Control4's own published
---        driver code, and SELECT_AUDIO_DEVICE + SET_VOLUME_LEVEL were seen
---        leaving this repository's Daypart driver on a bench controller
---   room SET_VOLUME_LEVEL {LEVEL}                  same standing
---   room MUTE_ON / MUTE_OFF                        NOT confirmed anywhere: hardware verification
---   room variables 1001/1002/1010/1011/1018        ids from Control4's published lib.lua
---   C4:GetDeviceVariables / RegisterVariableListener   official API
---
--- Every call is wrapped: an adapter function returns ok, err and never throws.

local M = {}

--- Room variable ids (Control4 drivers-common-public, ROOM_VARS).
M.ROOM_VARS = {
  CURRENT_AUDIO_DEVICE = 1001,
  CURRENT_VIDEO_DEVICE = 1002,
  POWER_STATE = 1010,
  CURRENT_VOLUME = 1011,
  IS_MUTED = 1018,
}

local WATCHED = { "CURRENT_AUDIO_DEVICE", "CURRENT_VIDEO_DEVICE", "POWER_STATE", "CURRENT_VOLUME", "IS_MUTED" }

local function truthy(value)
  if value == nil then
    return nil
  end
  local v = tostring(value):upper()
  if v == "1" or v == "ON" or v == "TRUE" then
    return true
  end
  if v == "0" or v == "OFF" or v == "FALSE" or v == "" then
    return false
  end
  return nil
end
M.truthy = truthy

--- deps = { c4 = C4, log, register(deviceId, variableId, callback), unregister(deviceId, variableId) }
--- `register` / `unregister` are the house wrappers around
--- C4:RegisterVariableListener (drivers-common-public handlers).
function M.new(deps)
  local c4 = deps.c4
  local log = deps.log
  local A = { simulation = false }
  local watchedRooms = {}

  -- One callback per device/variable pair, however many things here want to
  -- hear it. The house wrapper (and Director behind it) keeps a single
  -- callback per pair, so a second registration REPLACES the first: two rules
  -- on one variable would leave only the last one firing, and a rule on a
  -- mapped room's variable would silence that room's feedback. Each pair has
  -- one slot: the room-feedback subscriber (at most one) and the rule
  -- subscribers, all called from the slot's single registered callback.
  --
  -- The pair is still registered once per subscriber, as it always was, with
  -- that same callback: the API documentation says a listener is called with
  -- the current value as soon as it is set, and a rule that starts watching
  -- should get that call whether it is the first on its variable or not.
  -- (Earlier subscribers hear it again; the rule cool-down absorbs that.)
  local slots = {} -- [deviceId][variableId] = { room = fn | nil, rules = { fn, ... }, dispatch = fn }

  local function slotFor(deviceId, variableId)
    slots[deviceId] = slots[deviceId] or {}
    local slot = slots[deviceId][variableId]
    if slot == nil then
      slot = { rules = {} }
      slot.dispatch = function(_, _, value)
        if slot.room ~= nil then
          pcall(slot.room)
        end
        -- A copy: a rule's action may republish and change the list mid-walk.
        local rules = {}
        for i, fn in ipairs(slot.rules) do
          rules[i] = fn
        end
        for _, fn in ipairs(rules) do
          pcall(fn, value)
        end
      end
      slots[deviceId][variableId] = slot
    end
    return slot
  end

  --- (Re)registers the pair with its slot's callback. Call AFTER adding the
  --- subscriber, so a call made during registration reaches it.
  local function listen(deviceId, variableId)
    pcall(deps.register, deviceId, variableId, slotFor(deviceId, variableId).dispatch)
  end

  --- Drops the Control4 listener once nothing here listens to the pair.
  local function releaseIfIdle(deviceId, variableId)
    local slot = slots[deviceId] and slots[deviceId][variableId]
    if slot ~= nil and slot.room == nil and #slot.rules == 0 then
      pcall(deps.unregister, deviceId, variableId)
      slots[deviceId][variableId] = nil
      if next(slots[deviceId]) == nil then
        slots[deviceId] = nil
      end
    end
  end

  local function send(deviceId, command, params)
    if type(deviceId) ~= "number" then
      return false, "no Control4 device"
    end
    local ok, err = pcall(function()
      c4:SendToDevice(deviceId, command, params or {})
    end)
    if log then
      log:info(
        "VenueFlow -> %s on %s%s",
        tostring(command),
        tostring(deviceId),
        ok and "" or (" FAILED: " .. tostring(err))
      )
    end
    if not ok then
      return false, tostring(err)
    end
    return true
  end

  local function variables(deviceId)
    local ok, raw = pcall(function()
      return c4:GetDeviceVariables(deviceId)
    end)
    if not ok or type(raw) ~= "table" then
      return nil
    end
    local byName = {}
    local any = false
    for id, v in pairs(raw) do
      if type(v) == "table" and v.name ~= nil then
        byName[tostring(v.name)] = { value = v.value, id = tonumber(id) or tonumber(v.id) }
        any = true
      end
    end
    return any and byName or nil
  end

  function A.selectVideo(roomId, deviceId)
    return send(roomId, "SELECT_VIDEO_DEVICE", { deviceid = deviceId })
  end

  function A.selectAudio(roomId, deviceId)
    return send(roomId, "SELECT_AUDIO_DEVICE", { deviceid = deviceId })
  end

  function A.roomOff(roomId)
    return send(roomId, "ROOM_OFF", {})
  end

  function A.setVolume(roomId, level)
    return send(roomId, "SET_VOLUME_LEVEL", { LEVEL = level })
  end

  function A.setMute(roomId, muted)
    return send(roomId, muted and "MUTE_ON" or "MUTE_OFF", {})
  end

  function A.devicePower(deviceId, on)
    return send(deviceId, on and "ON" or "OFF", {})
  end

  function A.deviceCommand(deviceId, command, params)
    return send(deviceId, command, params)
  end

  function A.readRoom(roomId)
    local vars = variables(roomId)
    if vars == nil then
      return nil
    end
    local function value(name)
      return vars[name] and vars[name].value or nil
    end
    return {
      power = truthy(value("POWER_STATE")),
      volume = tonumber(value("CURRENT_VOLUME")),
      muted = truthy(value("IS_MUTED")),
      videoDevice = tonumber(value("CURRENT_VIDEO_DEVICE")),
      audioDevice = tonumber(value("CURRENT_AUDIO_DEVICE")),
    }
  end

  --- Listens to the mapped rooms. `callback(roomId)` is called on any change.
  function A.watchRooms(roomIds, callback)
    for roomId in pairs(watchedRooms) do
      for _, name in ipairs(WATCHED) do
        local slot = slots[roomId] and slots[roomId][M.ROOM_VARS[name]]
        if slot ~= nil then
          slot.room = nil
          releaseIfIdle(roomId, M.ROOM_VARS[name])
        end
      end
    end
    watchedRooms = {}
    for _, roomId in ipairs(roomIds or {}) do
      if type(roomId) == "number" and not watchedRooms[roomId] then
        watchedRooms[roomId] = true
        for _, name in ipairs(WATCHED) do
          slotFor(roomId, M.ROOM_VARS[name]).room = function()
            pcall(callback, roomId)
          end
          listen(roomId, M.ROOM_VARS[name])
        end
      end
    end
  end

  --- true / false / nil (Director has no link state for this device).
  function A.deviceOnline(deviceId)
    local ok, raw = pcall(function()
      return c4:GetBindingsByDevice(deviceId)
    end)
    if not ok or type(raw) ~= "table" then
      return nil
    end
    local found
    local function walk(node, depth)
      if type(node) ~= "table" or depth > 6 or found ~= nil then
        return
      end
      if node.status ~= nil and node.addr ~= nil and tostring(node.addr) ~= "" then
        found = tostring(node.status):lower() == "online"
        return
      end
      for _, child in pairs(node) do
        walk(child, depth + 1)
      end
    end
    walk(raw, 0)
    return found
  end

  function A.readVariable(deviceId, name)
    local vars = variables(deviceId)
    return vars and vars[name] and vars[name].value or nil
  end

  function A.watchVariable(deviceId, name, callback)
    local vars = variables(deviceId)
    local entry = vars and vars[name]
    if entry == nil or entry.id == nil then
      return false, "variable not found"
    end
    local rules = slotFor(deviceId, entry.id).rules
    rules[#rules + 1] = function(value)
      pcall(callback, deviceId, name, value)
    end
    listen(deviceId, entry.id)
    return true
  end

  --- Ends every rule's watch. Room feedback on the same pairs keeps listening.
  function A.unwatchVariables()
    local pairsToCheck = {}
    for deviceId, byVariable in pairs(slots) do
      for variableId, slot in pairs(byVariable) do
        if #slot.rules > 0 then
          slot.rules = {}
          pairsToCheck[#pairsToCheck + 1] = { deviceId, variableId }
        end
      end
    end
    for _, pair in ipairs(pairsToCheck) do
      releaseIfIdle(pair[1], pair[2])
    end
  end

  --- Every project device as { id, name, room, roomId, driverFile, proxies }.
  function A.listDevices()
    local ok, devices = pcall(function()
      return c4:GetDevices({})
    end)
    if not ok or type(devices) ~= "table" then
      return {}
    end
    local out = {}
    for rawId, d in pairs(devices) do
      local id = tonumber(rawId)
      if id ~= nil and type(d) == "table" then
        local proxies = {}
        if type(d.proxies) == "table" then
          for _, p in pairs(d.proxies) do
            if type(p) == "table" and p.proxy ~= nil then
              proxies[#proxies + 1] = tostring(p.proxy)
            elseif type(p) == "string" then
              proxies[#proxies + 1] = p
            end
          end
        end
        out[#out + 1] = {
          id = id,
          name = tostring(d.deviceName or d.name or ""),
          room = tostring(d.roomName or ""),
          roomId = tonumber(d.roomId or d.roomID),
          driverFile = tostring(d.driverFileName or ""),
          proxies = proxies,
        }
      end
    end
    table.sort(out, function(a, b)
      return a.id < b.id
    end)
    return out
  end

  function A.timeZone()
    local ok, tz = pcall(function()
      return c4:GetTimeZone()
    end)
    return ok and type(tz) == "string" and tz or ""
  end

  return A
end

return M
