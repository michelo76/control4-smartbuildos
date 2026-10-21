-- Exports model: definitions, gates, variable resolution, value mapping,
-- schedules (DST-agnostic, overnight, untrusted clock) and command
-- validation. Run from the driver root: make test

local pass, fail = 0, 0
local function check(name, ok, detail)
  if ok then
    pass = pass + 1
    print(string.format("  ok   %s", name))
  else
    fail = fail + 1
    print(string.format("  FAIL %s%s", name, detail and ("  -> " .. tostring(detail)) or ""))
  end
end

package.path = "./src/?.lua;./src/?/init.lua;./vendor/?.lua;" .. package.path
local exports = require("systemlink.exports")

local FEATURES = { BASE = true, LIGHT = true, RELAY = true, SENSOR = true }

print("\n[1] definitions and gates")
local light, err =
  exports.define({ id = "x1", name = "Porch_Light", kind = "light", device_id = 41, control = true }, FEATURES)
check("light export defined with all ops", light and #light.ops == 3, err)
check(
  "thermostat refused without the THERMOSTAT feature",
  select(2, exports.define({ id = "x2", name = "Hall", kind = "thermostat", device_id = 5, control = true }, FEATURES)):match(
    "THERMOSTAT"
  )
)
check(
  "thermostat allowed when gated feature present",
  exports.define(
    { id = "x2", name = "Hall", kind = "thermostat", device_id = 5, control = true },
    { THERMOSTAT = true }
  ) ~= nil
)
check(
  "unknown op refused",
  select(
    2,
    exports.define(
      { id = "x3", name = "R", kind = "relay", device_id = 7, control = true, ops = { "unlock" } },
      FEATURES
    )
  ):match("not available")
)
local viewOnly =
  exports.define({ id = "x4", name = "Front_Door", kind = "contact", device_id = 9, control = true }, FEATURES)
check("contact is never controllable", viewOnly.control == false and #viewOnly.ops == 0)
check(
  "bad name refused",
  exports.define({ id = "x5", name = "bad name", kind = "light", device_id = 1 }, FEATURES) == nil
)
local described = exports.describe(light)
check("description carries no local device id", described.device_id == nil and described.name == "Porch_Light")
local defs = exports.itemDefinitions(light, "ep-a")
check(
  "light contributes On and Level items",
  #defs == 2 and defs[1].name == "Porch_Light_On" and defs[2].companion.field == "Level"
)

print("\n[2] variable resolution and mapping")
local vars =
  { ["1000"] = { name = "LIGHT_STATE" }, ["1001"] = { name = "Brightness Percent" }, ["1005"] = { name = "Something" } }
local resolved = exports.resolveVariables(light, vars)
check("measured light names resolve", resolved.On.id == 1000 and resolved.Level.id == 1001)
check(
  "missing variable leaves the field unresolved",
  exports.resolveVariables(light, { ["5"] = { name = "X" } }).Level == nil
)
check("bool/int mapping", exports.mapValue(light, "On", "1") == true and exports.mapValue(light, "Level", "73.4") == 73)
check("unparseable → nil (unavailable)", exports.mapValue(light, "Level", "n/a") == nil)
local relay = exports.define(
  { id = "r", name = "Gate_Relay", kind = "relay", device_id = 3, control = true, ops = { "trigger" } },
  FEATURES
)
check(
  "relay closed/opened mapping",
  exports.mapValue(relay, "Closed", "CLOSED") == true and exports.mapValue(relay, "Closed", "OPENED") == false
)

local media = exports.define({ id = "m", name = "Kitchen", kind = "media", device_id = 7, control = true }, FEATURES)
check(
  "a media export is view-only even when control is asked for",
  media ~= nil and media.control == false,
  media and media.control
)
check(
  "a room's measured variables resolve the media fields",
  (function()
    local r = exports.resolveVariables(media, {
      ["1"] = { name = "POWER_STATE" },
      ["2"] = { name = "CURRENT_SELECTED_DEVICE" },
      ["3"] = { name = "CURRENT_VOLUME" },
      ["4"] = { name = "CURRENT MEDIA INFO" },
    })
    return r.Powered.id == 1 and r.Source.id == 2 and r.Volume.id == 3 and r.Media.id == 4
  end)()
)
check(
  "media mapping: power words, text trimmed and bounded, blank source is unavailable",
  exports.mapValue(media, "Powered", "ON") == true
    and exports.mapValue(media, "Powered", "OFF") == false
    and exports.mapValue(media, "Media", "  Now   Playing  ") == "Now Playing"
    and exports.mapValue(media, "Source", "") == nil
    and #exports.mapValue(media, "Media", string.rep("x", 400)) == 256
    and exports.fieldMap(media, "Source") == "device_name"
)

local scene = exports.define({ id = "s", name = "Welcome", kind = "scene", control = true }, FEATURES)
check("a scene export needs no device and is runnable", scene ~= nil and scene.device_id == 0 and scene.control == true, scene and scene.device_id)
check("scene routines round-trip", exports.sceneRoutine("Welcome") == "scene:Welcome" and exports.sceneFromRoutine("scene:Welcome") == "Welcome" and exports.sceneFromRoutine("Prepare_Home") == nil and exports.sceneFromRoutine("scene:9x") == nil)
check("its two fields are text with no device variables", #exports.itemDefinitions(scene, "ep")  == 2 and exports.itemDefinitions(scene, "ep")[1].name == "Welcome_Last_Run")

print("\n[3] schedules")
local sched = {
  tz = "America/Los_Angeles",
  windows = {
    { days = { 2, 3, 4, 5, 6 }, from = "08:00", to = "18:00" },
    { days = { 7 }, from = "22:00", to = "02:00" },
  },
}
check("schedule validates", exports.validateSchedule(sched))
check("weekday 09:00 allowed", exports.scheduleAllows(sched, { year = 2026, wday = 3, hour = 9, min = 0 }))
check(
  "weekday 18:00 refused (exclusive end)",
  not exports.scheduleAllows(sched, { year = 2026, wday = 3, hour = 18, min = 0 })
)
check("sunday refused", not exports.scheduleAllows(sched, { year = 2026, wday = 1, hour = 9, min = 0 }))
check(
  "saturday 23:00 inside overnight window",
  exports.scheduleAllows(sched, { year = 2026, wday = 7, hour = 23, min = 0 })
)
check(
  "sunday 01:00 inside overnight window from saturday",
  exports.scheduleAllows(sched, { year = 2026, wday = 1, hour = 1, min = 0 })
)
check("sunday 03:00 outside", not exports.scheduleAllows(sched, { year = 2026, wday = 1, hour = 3, min = 0 }))
check("untrusted clock fails closed", not exports.scheduleAllows(sched, { year = 1970, wday = 3, hour = 9, min = 0 }))
check("no schedule allows", exports.scheduleAllows(nil, nil))
check(
  "bad window refused",
  not exports.validateSchedule({ tz = "x", windows = { { days = { 9 }, from = "1", to = "2" } } })
)

print("\n[4] command validation")
local ctx = { features = FEATURES, commandsPermitted = true, localTime = { year = 2026, wday = 3, hour = 9, min = 0 } }
local cmds, why =
  exports.validateCommand(light, { routine = "light.set_level", params = { level = 40, time_ms = 1000 } }, ctx)
check(
  "set_level → RAMP_TO_LEVEL",
  cmds and cmds[1].name == "RAMP_TO_LEVEL" and cmds[1].params.LEVEL == 40 and cmds[1].params.TIME == 1000,
  why
)
check(
  "level out of range refused",
  select(2, exports.validateCommand(light, { routine = "light.set_level", params = { level = 140 } }, ctx)):match(
    "0..100"
  )
)
check("wrong kind refused", select(2, exports.validateCommand(light, { routine = "relay.trigger" }, ctx)):match("kind"))
check("view-only refused", select(2, exports.validateCommand(viewOnly, { routine = "contact.open" }, ctx)) ~= nil)
check(
  "op not in allowlist refused",
  select(2, exports.validateCommand(relay, { routine = "relay.open" }, ctx)):match("not permitted")
)
check(
  "trigger permitted, one command, terminates locally",
  (function()
    local c = exports.validateCommand(relay, { routine = "relay.trigger" }, ctx)
    return c and #c == 1 and c[1].name == "TRIGGER"
  end)()
)
check(
  "suspended commands refused",
  select(
    2,
    exports.validateCommand(
      light,
      { routine = "light.on" },
      { features = FEATURES, commandsPermitted = false, localTime = ctx.localTime }
    )
  ):match("suspended")
)
light.schedule = sched
check(
  "outside schedule refused",
  select(
    2,
    exports.validateCommand(
      light,
      { routine = "light.on" },
      { features = FEATURES, commandsPermitted = true, localTime = { year = 2026, wday = 1, hour = 9, min = 0 } }
    )
  ):match("schedule")
)
check(
  "unlicensed feature refused at command time",
  select(
    2,
    exports.validateCommand(
      light,
      { routine = "light.on" },
      { features = { BASE = true }, commandsPermitted = true, localTime = ctx.localTime }
    )
  ):match("not licensed")
)
check(
  "non-idempotent set",
  exports.NON_IDEMPOTENT.trigger and exports.NON_IDEMPOTENT.toggle and not exports.NON_IDEMPOTENT.set_level
)

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
