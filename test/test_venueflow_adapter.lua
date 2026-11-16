-- VenueFlow's Control4 adapter: variable listeners.
--
-- The house wrapper RegisterVariableListener (drivers-common-public handlers)
-- keeps ONE callback per device/variable pair; registering again replaces it.
-- The fake below behaves the same way, so this suite proves that the adapter
-- shares one listener between everything that wants a pair: several rules on
-- one variable, and a rule on a variable of a room whose feedback is watched.
--
-- The API documentation also says a listener is called with the current value
-- as soon as it is set. The fake can do that too (`announce`), to show that
-- every watcher gets that first call, not only the first on its variable.
--
-- Not a controller: the fake stands in for Director. Whether a real variable
-- change reaches each subscriber on hardware is in the hardware plan.
--
-- Run from the driver root: make test

local H = require("venueflow_harness")
local Adapter = require("venueflow.adapter_c4")
local T = H.checker()
local check, eq = T.check, T.eq

--- A stand-in for the house wrappers: one callback per pair, last one wins.
local function fakeDirector(variablesByDevice, announce)
  local d = { callbacks = {}, registers = 0, unregisters = 0 }
  local function key(deviceId, variableId)
    return tostring(deviceId) .. ":" .. tostring(variableId)
  end
  d.c4 = {
    GetDeviceVariables = function(_, deviceId)
      return variablesByDevice[deviceId]
    end,
  }
  function d.register(deviceId, variableId, callback)
    d.registers = d.registers + 1
    d.callbacks[key(deviceId, variableId)] = callback
    if announce then
      local v = (variablesByDevice[deviceId] or {})[tostring(variableId)]
      callback(deviceId, variableId, v and v.value or nil)
    end
  end
  function d.unregister(deviceId, variableId)
    d.unregisters = d.unregisters + 1
    d.callbacks[key(deviceId, variableId)] = nil
  end
  --- Director reports a change: the one registered callback is called.
  function d.change(deviceId, variableId, value)
    local cb = d.callbacks[key(deviceId, variableId)]
    if cb ~= nil then
      cb(deviceId, variableId, value)
    end
    return cb ~= nil
  end
  function d.listening()
    local n = 0
    for _ in pairs(d.callbacks) do
      n = n + 1
    end
    return n
  end
  return d
end

local ROOM = 1101
local roomVars = {
  ["1001"] = { name = "CURRENT_AUDIO_DEVICE", value = "0" },
  ["1002"] = { name = "CURRENT_VIDEO_DEVICE", value = "0" },
  ["1010"] = { name = "POWER_STATE", value = "0" },
  ["1011"] = { name = "CURRENT_VOLUME", value = "0" },
  ["1018"] = { name = "IS_MUTED", value = "0" },
}

print("two rules on one variable")
do
  local d = fakeDirector({ [500] = { ["2000"] = { name = "DOOR", value = "0" } } })
  local a = Adapter.new({ c4 = d.c4, register = d.register, unregister = d.unregister })
  local got = {}
  local function rule(tag)
    return function(deviceId, name, value)
      got[#got + 1] = tag .. ":" .. tostring(deviceId) .. ":" .. tostring(name) .. ":" .. tostring(value)
    end
  end
  check("the first rule watches", a.watchVariable(500, "DOOR", rule("a")))
  check("the second rule watches the same variable", a.watchVariable(500, "DOOR", rule("b")))
  eq("one listener is held for the pair, not two", d.listening(), 1)
  d.change(500, 2000, "1")
  eq("both rules hear the change", table.concat(got, " "), "a:500:DOOR:1 b:500:DOOR:1")
  local ok, why = a.watchVariable(500, "NOPE", rule("c"))
  eq("an unknown variable is still refused", tostring(ok) .. " " .. tostring(why), "false variable not found")
  a.unwatchVariables()
  eq("ending the rule watches releases the listener", d.listening(), 0)
  got = {}
  d.change(500, 2000, "0")
  eq("...and nothing fires afterwards", #got, 0)
end

print("a rule on a mapped room's variable")
do
  local d = fakeDirector({ [ROOM] = roomVars })
  local a = Adapter.new({ c4 = d.c4, register = d.register, unregister = d.unregister })
  local feedback, fired = {}, {}
  a.watchRooms({ ROOM }, function(roomId)
    feedback[#feedback + 1] = roomId
  end)
  eq("room feedback listens to the five room variables", d.listening(), 5)
  check(
    "a rule watches the room's power variable",
    a.watchVariable(ROOM, "POWER_STATE", function(_, _, value)
      fired[#fired + 1] = value
    end)
  )
  eq("...on the pair the room already listens to", d.listening(), 5)
  d.change(ROOM, 1010, "1")
  eq("the rule fires", fired[1], "1")
  eq("...and the room's feedback still arrives", feedback[1], ROOM)
  -- A republish: Core ends the rule watches, then watches rooms and rules again.
  a.unwatchVariables()
  eq("ending the rule watches leaves the room's listeners alone", d.listening(), 5)
  feedback, fired = {}, {}
  d.change(ROOM, 1010, "0")
  eq("feedback survives the end of the rule watch", feedback[1], ROOM)
  eq("...and the ended rule is silent", #fired, 0)
  a.watchRooms({ ROOM }, function(roomId)
    feedback[#feedback + 1] = "again:" .. roomId
  end)
  a.watchVariable(ROOM, "POWER_STATE", function(_, _, value)
    fired[#fired + 1] = "again:" .. value
  end)
  feedback, fired = {}, {}
  d.change(ROOM, 1010, "1")
  eq("after a republish the room hears once, through the new callback", table.concat(feedback, " "), "again:" .. ROOM)
  eq("...and so does the rule", table.concat(fired, " "), "again:1")
  -- The room is unmapped while a rule still watches its variable.
  a.watchRooms({}, function() end)
  eq("an unmapped room keeps only the pair a rule still needs", d.listening(), 1)
  feedback, fired = {}, {}
  d.change(ROOM, 1010, "0")
  eq("the rule still fires", fired[1], "again:0")
  eq("...with no room feedback", #feedback, 0)
  a.unwatchVariables()
  eq("nothing is left listening", d.listening(), 0)
end

print("the first call on registration")
do
  local d = fakeDirector({ [500] = { ["2000"] = { name = "DOOR", value = "open" } } }, true)
  local a = Adapter.new({ c4 = d.c4, register = d.register, unregister = d.unregister })
  local first, second = {}, {}
  a.watchVariable(500, "DOOR", function(_, _, value)
    first[#first + 1] = value
  end)
  eq("the first rule hears the current value when it starts watching", first[1], "open")
  a.watchVariable(500, "DOOR", function(_, _, value)
    second[#second + 1] = value
  end)
  eq("the second rule on the same variable hears it too", second[1], "open")
  d.change(500, 2000, "closed")
  eq("a later change reaches the first rule", first[#first], "closed")
  eq("...and the second", second[#second], "closed")
end

print("a subscriber that fails")
do
  local d = fakeDirector({ [500] = { ["2000"] = { name = "DOOR", value = "0" } } })
  local a = Adapter.new({ c4 = d.c4, register = d.register, unregister = d.unregister })
  local heard = 0
  a.watchVariable(500, "DOOR", function()
    error("boom")
  end)
  a.watchVariable(500, "DOOR", function()
    heard = heard + 1
  end)
  local ok = pcall(d.change, 500, 2000, "1")
  check("one failing rule does not throw into Director's callback", ok)
  eq("...or stop the next rule", heard, 1)
end

T.done()
