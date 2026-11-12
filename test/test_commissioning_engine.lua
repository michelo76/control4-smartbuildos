-- Commissioning Matrix engine and actuation adapters, without a controller:
-- classification, test-list building (rooms, manual merge, label parsing),
-- the run state machine (act, readback, verdict, sensor, room/run roll-up,
-- sign-off, abort), the record, persistence, and the adapters' checks.
--
-- Run from the driver root: make test

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

C4 = C4 or {}
require("c4_shim")
JSON = require("JSON")
tostring_return_period = tostring_return_period or tostring
local Engine = require("commissioning.engine")
local Actuate = require("commissioning.actuate")

print("[1] classification")
check("light_v2 is a light", Engine.classify("light_v2.c4z") == "light")
check("blind is a shade", Engine.classify("blind.c4i") == "shade")
check("a light sensor is a sensor, not a light", Engine.classify("lightsensor.c4z") == "sensor")
check("contact is a sensor", Engine.classify("contactsingle_v2.c4z") == "sensor")
check("room device is an AV zone", Engine.classify("roomdevice.c4z") == "av")
check("a flight recorder is not a light", Engine.classify("smartbuildos-flight-recorder.c4z") == nil)
check("a thermostat is not testable", Engine.classify("thermostatV2.c4z") == nil)
check("nil is not testable", Engine.classify(nil) == nil)

print("[2] list labels and parsing")
local label = Engine.listLabel("Pendant, big", "Kitchen", 42)
check("commas are taken out and the shape is Name (Room) · id", label == "Pendant  big (Kitchen) · 42", label)
local p = Engine.parseListEntry("Pendant (Kitchen) · 42")
check("parse name/room/id", p and p.id == 42 and p.name == "Pendant" and p.room == "Kitchen")
p = Engine.parseListEntry("Lamp (left) (Den) · 7")
check("parentheses in the name survive", p and p.name == "Lamp (left)" and p.room == "Den" and p.id == 7)
p = Engine.parseListEntry("Floating Lamp · 9")
check("no room", p and p.id == 9 and p.room == "")
check("dash and junk are not entries", Engine.parseListEntry("-") == nil and Engine.parseListEntry("nonsense") == nil)
check("kind choices", Engine.kindFromChoice("AV zone") == "av" and Engine.kindFromChoice("Auto-detect") == nil)

print("[3] building the list")
local devices = {
  [10] = { deviceName = "Pendant", roomName = "Kitchen", driverFileName = "light_v2.c4z" },
  [11] = { deviceName = "Island", roomName = "Kitchen", driverFileName = "light_v2.c4z" },
  [12] = { deviceName = "Roller", roomName = "Den", driverFileName = "blind.c4z" },
  [13] = { deviceName = "Door", roomName = "Den", driverFileName = "contactsingle_v2.c4z" },
  [14] = { deviceName = "Den", roomName = "Den", driverFileName = "roomdevice.c4z" },
  [15] = { deviceName = "Thermostat", roomName = "Den", driverFileName = "thermostatV2.c4z" },
  [16] = { deviceName = "Orphan", roomName = "", driverFileName = "light_v2.c4z" },
}
local items = Engine.buildList(devices, { av_source = 99 })
check("only testable kinds", #items == 6, #items)
local order = {}
for _, it in ipairs(items) do
  order[#order + 1] = it.room .. ":" .. it.kind .. ":" .. it.name
end
check(
  "order is room, kind, name",
  table.concat(order, "|")
    == "Den:shade:Roller|Den:av:Den|Den:sensor:Door|Kitchen:light:Island|Kitchen:light:Pendant|Unassigned:light:Orphan",
  table.concat(order, "|")
)
check("a device with no room is Unassigned", items[6].room == "Unassigned")
check("AV items carry the test source", items[2].source == 99)
local noAv = Engine.buildList(devices, {})
check("without an AV test source there are no AV items", #noAv == 5)
local merged = Engine.buildList(devices, { manual = { { id = 15, name = "Fan", room = "Den", kind = "light" }, { id = 10, name = "Pendant Lamp", room = "Kitchen", kind = "light" } } })
local byKey = {}
for _, it in ipairs(merged) do
  byKey[it.key] = it
end
check("a manual item is added", byKey["light:15"] and byKey["light:15"].origin == "manual")
check("a manual entry refines an automatic one, no duplicate", byKey["light:10"].name == "Pendant Lamp" and #merged == 6, #merged)
check("a manual item of unknown kind is dropped", #Engine.buildList({}, { manual = { { id = 5, name = "x" } } }) == 0)

print("[4] a run, with a fake actuator")
local clock = { ms = 1800000000 * 1000, timers = {} }
local function nowSeconds()
  return math.floor(clock.ms / 1000)
end
--- Moves time on in 100 ms steps so a timer scheduled by a timer fires when due.
local function advance(ms)
  local target = clock.ms + ms
  while clock.ms < target do
    clock.ms = math.min(clock.ms + 100, target)
    local due = {}
    for i = #clock.timers, 1, -1 do
      if clock.timers[i].at <= clock.ms then
        due[#due + 1] = table.remove(clock.timers, i)
      end
    end
    table.sort(due, function(a, b)
      return a.at < b.at
    end)
    for _, tm in ipairs(due) do
      tm.fn()
    end
  end
end
local sentCmds = {}
local devVars = {
  [10] = { ["Brightness Percent"] = 30 },
  [11] = { ["Brightness Percent"] = 0 },
  [12] = { ["Level"] = 100 },
}
local io = {
  send = function(deviceId, command, params)
    sentCmds[#sentCmds + 1] = { deviceId, command, params }
    -- The "devices" follow their commands, except light 11 which is stuck.
    if command == "RAMP_TO_LEVEL" and deviceId ~= 11 then
      devVars[deviceId]["Brightness Percent"] = params.LEVEL
    elseif command == "SET_LEVEL_TARGET" then
      devVars[deviceId]["Level"] = params.LEVEL_TARGET
    end
  end,
  vars = function(deviceId)
    return devVars[deviceId] or {}
  end,
}
local events = {}
local watched = {}
local engine = Engine.new({
  now = nowSeconds,
  schedule = function(ms, fn)
    clock.timers[#clock.timers + 1] = { at = clock.ms + ms, fn = fn }
  end,
  emit = function(kind, f)
    events[#events + 1] = { kind = kind, f = f }
  end,
  watch = function(item)
    watched[item.device_id] = true
    return { id = 5, name = "ContactState", value = "0" }
  end,
  unwatch = function(item)
    watched[item.device_id] = nil
  end,
  settle_ms = 1000,
  options = { av_volume = 12 },
  actuator = Actuate.new(io),
})
local function count(kind)
  local n = 0
  for _, e in ipairs(events) do
    if e.kind == kind then
      n = n + 1
    end
  end
  return n
end
local kitchen = Engine.buildList({
  [10] = devices[10],
  [11] = devices[11],
  [12] = { deviceName = "Roller", roomName = "Den", driverFileName = "blind.c4z" },
  [13] = devices[13],
}, {})
engine:setItems(kitchen)
check("rooms listed", #engine:rooms() == 2 and engine:rooms()[1].name == "Den")
check("no run: idle, no failures", engine:status() == "idle" and not engine:hasFailures())
check("test refused without a run", engine:test("light:10") == false)
local ok, why = engine:startRun({ scope = "Nowhere" })
check("unknown room refused", ok == false and why:find("Nowhere"), why)
ok = engine:startRun({ scope = "Kitchen", technician = "Sam" })
check("scoped run starts on that room", ok and engine.run.scope == "Kitchen" and #engine.run.results == 2 and engine:currentRoom() == "Kitchen")
check("a second run is refused", engine:startRun({}) == false)
check("run_started emitted", count("run_started") == 1)

ok = engine:test("light:10")
check("light test begins", ok and engine.run.results[2].status == "testing")
check("the ramp to full was sent", sentCmds[1][1] == 10 and sentCmds[1][2] == "RAMP_TO_LEVEL" and sentCmds[1][3].LEVEL == 100)
check("a second test while testing is refused", engine:test("light:10") == false)
advance(1000)
check("the restore ramp goes to the level it had", sentCmds[2][3].LEVEL == 30)
advance(1000)
local r = engine.run.results[2]
check("after both reads the light waits for a verdict", r.status == "awaiting", r.status)
check("readback records what the device reported", r.readback.act.level == 100 and r.readback.restore.level == 30)
check("reported agrees", r.reported == "match")
check("item_ready emitted", count("item_ready") == 1)
check("a pass needs a test (pending item refused)", engine:mark("light:11", "pass") == false)
ok = engine:mark("light:10", "pass", "  lamp lit, no flicker  ")
check("technician pass recorded with its note", ok and r.status == "passed" and r.note == "lamp lit, no flicker")
check("judged timestamp set", r.judged_at == nowSeconds())

-- the stuck light: device reports 0 after being asked for 100
ok = engine:test("light:11")
advance(2000)
local stuck = engine.run.results[1]
check("a stuck light reads back a mismatch", stuck.reported == "mismatch" and stuck.detail:find("asked for 100"), stuck.detail)
ok = engine:mark("light:11", "pass")
check("pass despite mismatch is allowed but flagged", ok and stuck.passed_despite_mismatch == true)
check("room passed fired once when the last open item resolved", count("room_passed") == 1)
check("scoped run is complete once everything is judged", engine:status() == "complete")
check("item_judged emitted per verdict", count("item_judged") == 2)

print("[5] retest, fail, skip, roll-up")
engine:test("light:11")
check("a retest reopens a complete run", engine:status() == "running" and stuck.attempts == 2)
check("a retest clears the old readback", stuck.readback == nil and stuck.passed_despite_mismatch == nil)
ok = engine:mark("light:11", "fail", "does not respond")
check("fail while testing is accepted", ok and stuck.status == "failed")
check("item_failed emitted", count("item_failed") == 1)
advance(5000)
check("a stale timer from the failed attempt changes nothing", stuck.status == "failed")
check("failure shows in counts and conditional", engine:counts().failed == 1 and engine:hasFailures())
check("the failed list names the item", #engine:failures() == 1 and engine:failures()[1].name == "Island")
ok = engine:signOff("Sam")
check("a failed item is judged, so the run signs off (the failure is on the record)", ok == true)
check("run_completed emitted with the record", count("run_completed") == 1)
check("signed off run is no longer active", not engine:active() and engine:status() == "signed_off")
local rec = engine.last_signed
check("record schema and who", rec.schema == "commissioning.run.v1" and rec.signed_off_by == "Sam" and rec.technician == "Sam")
check("record counts", rec.counts.passed == 1 and rec.counts.failed == 1 and rec.counts.total == 2)
check("record groups by room with a room result", #rec.rooms == 1 and rec.rooms[1].name == "Kitchen" and rec.rooms[1].result == "failed")
check("record timestamps are ISO UTC", rec.started_at:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$") ~= nil)
check("record carries the honest-limits sentence", rec.honest_limits:find("not measured") ~= nil)
local encoded = JSON:encode(rec)
check("record encodes to JSON and back", JSON:decode(encoded).run_id == rec.run_id)
check("history keeps the run", #engine.history == 1)

print("[6] shade, sensor, skip, whole-project run")
engine:setItems(kitchen)
ok = engine:startRun({ technician = "Ana" })
check("whole-project run has no current room until one is picked", ok and engine:currentRoom() == nil)
ok = engine:selectRoom("den")
check("select a room (case-insensitive)", ok and engine:currentRoom() == "Den")
check("selecting an unknown room fails", engine:selectRoom("Moon") == false)
sentCmds = {}
engine:test("shade:12")
check("shade moves to the end it is not at", sentCmds[1][2] == "SET_LEVEL_TARGET" and sentCmds[1][3].LEVEL_TARGET == 0)
advance(1000)
check("a shade settles slower than a light", engine.run.results[1] ~= nil and engine:_result("shade:12").status == "testing")
advance(3000)
check("a shade is read after the longer wait", engine:_result("shade:12").readback ~= nil)
advance(4000)
check("the shade waits for a verdict", engine:_result("shade:12").status == "awaiting" and engine:_result("shade:12").reported == "match")
engine:mark("shade:12", "pass")

engine:test("sensor:13")
local sr = engine:_result("sensor:13")
check("a sensor is armed, not acted on", sr.status == "armed" and watched[13] == true)
check("a sensor cannot be passed by a tap", engine:mark("sensor:13", "pass") == false)
check("an unchanged value does not pass it", engine:sensorChanged(13, "ContactState", "0") == false and sr.status == "armed")
check("another variable does not pass it", engine:sensorChanged(13, "Other", "1") == false)
check("a change passes it by itself", engine:sensorChanged(13, "ContactState", "1") == true and sr.status == "passed" and sr.auto == true)
check("the change is the readback", sr.readback.before == "0" and sr.readback.after == "1")
check("unwatched after passing", watched[13] == nil)
check("room Den passed event fired", count("room_passed") >= 2)

check("whole run is not complete while Kitchen is untouched", engine:status() == "running")
check("sign-off refused with open items", select(2, engine:signOff("Ana")):find("still need a verdict") ~= nil)
engine:mark("light:10", "skip", "owner away")
engine:mark("light:11", "skip")
check("run complete after skips", engine:status() == "complete")
check("sign-off needs a name", (function()
  engine.run.technician = ""
  local ok2, why2 = engine:signOff("")
  engine.run.technician = "Ana"
  return ok2 == false and why2:find("who") ~= nil
end)())
ok = engine:signOff("")
check("blank name falls back to the run's technician", ok == true and engine.last_signed.signed_off_by == "Ana")
check("history keeps both runs, newest first", #engine.history == 2 and engine.history[1].signed_off_by == "Ana")

print("[7] abort, restore")
engine:setItems(kitchen)
engine:startRun({ scope = "Den", technician = "Zed" })
engine:test("sensor:13")
ok = engine:abort()
check("abort closes the run", ok and engine:status() == "aborted" and not engine:active())
check("an armed sensor is unwatched and pending again", watched[13] == nil and engine:_result("sensor:13").status == "pending")
check("run_aborted emitted", count("run_aborted") == 1)
check("abort with nothing running is refused", engine:abort() == false)
engine:startRun({ scope = "Den", technician = "Zed" })
engine:test("shade:12")
local snapshot = JSON:decode(JSON:encode(engine:serialize()))
local again = Engine.new({ now = nowSeconds, schedule = function() end, actuator = Actuate.new(io) })
again:setItems(kitchen)
again:restore(snapshot)
check("restore brings back the run", again:status() == "running" and again.run.technician == "Zed")
check("anything mid-flight is pending after a restart", again:_result("shade:12").status == "pending")
check("restore brings back history and the signed record", #again.history == #engine.history and again.last_signed.signed_off_by == "Ana")
again:restore("garbage")
check("restore tolerates garbage", again:status() == "running")

print("[8] adapters")
local light = Actuate.adapterFor("light")
check("light check: not full", select(1, light.check("act", { level = 60 }, { level = 0 })) == "mismatch")
check("light check: no level", select(1, light.check("act", {}, { level = 0 })) == "unreported")
check("light restore within 2%", select(1, light.check("restore", { level = 31 }, { level = 30 })) == "match")
local steps = light.steps({}, "restore", { level = nil })
check("an unknown baseline restores to 0", steps[1].params.LEVEL == 0)
local shade = Actuate.adapterFor("shade")
check("a closed shade is opened", shade.steps({}, "act", { level = 0 })[1].params.LEVEL_TARGET == 100)
check("an unknown shade position is opened", shade.steps({}, "act", {})[1].params.LEVEL_TARGET == 100)
local av = Actuate.adapterFor("av")
check("AV needs a source", av.validate({ source = nil }) == false and av.validate({ source = 5 }) == true)
local avSteps = av.steps({ source = 5 }, "act", {}, { av_volume = 12 })
check(
  "AV routes the source then sets a low volume",
  avSteps[1].command == "SELECT_AUDIO_DEVICE" and avSteps[1].params.deviceid == 5 and avSteps[2].params.LEVEL == 12
)
check("AV from off returns with ROOM_OFF", av.steps({ source = 5 }, "restore", { on = false })[1].command == "ROOM_OFF")
check("AV restores the previous source and volume", #av.steps({ source = 5 }, "restore", { on = true, source = 3, volume = 20 }) == 2)
check("AV check: unreported without a variable", select(1, av.check("act", {}, {}, { source = 5 })) == "unreported")
check("AV check: match", select(1, av.check("act", { source = 5 }, {}, { source = 5 })) == "match")
check("AV check: mismatch", select(1, av.check("act", { source = 3 }, {}, { source = 5 })) == "mismatch")
check("sensor variable chosen from known names", Actuate.sensorVariable({ ContactState = "0", Other = "x" }) == "ContactState")
check("no recognisable sensor variable", Actuate.sensorVariable({ Foo = "1" }) == nil)
local brokenIo = Actuate.new({ send = function() error("boom") end, vars = function() error("boom") end })
check("a failing send or read does not throw", pcall(brokenIo.send, { device_id = 1 }, { { command = "X" } }) and next(brokenIo.read({ device_id = 1 })) == nil)

print("[9] text rendering")
local lines = Engine.textLines(engine.last_signed)
check("text lines name the run and items", lines[1]:find("run ") and #lines > 3)
check("no run text", Engine.textLines(nil)[1] == "no run yet")

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
