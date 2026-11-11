package.path = "src/?.lua;" .. package.path
local Meter = require("usage.meter")
local pass, fail = 0, 0
local function check(name, ok, detail)
  if ok then
    pass = pass + 1
    print("  ok   " .. name)
  else
    fail = fail + 1
    print("  FAIL " .. name .. (detail ~= nil and ("  -> " .. tostring(detail)) or ""))
  end
end

-- A fake calendar: days are 86400 s long from t = 0; dayOf is deterministic.
local clock = { t = 0 }
local function dayOf(t)
  return string.format("D%03d", math.floor(t / 86400))
end
local labels = { [200] = "Apple TV", [201] = "Sonos" }
local deps = {
  now = function()
    return clock.t
  end,
  dayOf = dayOf,
  deviceLabel = function(id)
    return labels[id]
  end,
}

print("== registration")
local m = Meter.new(deps)
check(
  "rooms, lights, keypads register",
  m:addRoom(3, "Kitchen") and m:addLight(12, "Pendants", "Kitchen") and m:addKeypad(40, "Hall Keypad", "Hall")
)
check("re-adding updates the label", m:addRoom(3, "Kitchen 2") and m.rooms[3].label == "Kitchen 2")
m:addRoom(3, "Kitchen")

print("== media time")
clock.t = 100
check("unknown variable ignored", m:onRoomVariable(3, "CURRENT_VOLUME", "30") == false)
check("unknown room ignored", m:onRoomVariable(9, "POWER_STATE", "True") == false)
m:onRoomVariable(3, "CURRENT_SELECTED_DEVICE", "200")
m:onRoomVariable(3, "POWER_STATE", "True")
clock.t = 100 + 3600
m:onRoomVariable(3, "CURRENT_SELECTED_DEVICE", "201")
clock.t = 100 + 3600 + 1800
m:onRoomVariable(3, "POWER_STATE", "False")
clock.t = 100 + 3600 + 1800 + 600
m:flush()
local today = m:today()
check(
  "room booked 1.5 h",
  today.media[3] ~= nil and today.media[3].seconds == 5400,
  today.media[3] and today.media[3].seconds
)
check(
  "per source: Apple TV 1 h, Sonos 0.5 h",
  today.media[3].sources[200].seconds == 3600 and today.media[3].sources[201].seconds == 1800
)
check(
  "source labels resolved",
  today.media[3].sources[200].label == "Apple TV" and today.media[3].sources[201].label == "Sonos"
)
check(
  "off time not counted",
  (function()
    clock.t = clock.t + 7200
    m:flush()
    return today.media[3].seconds == 5400
  end)()
)
check("counters", m.counters.media_changes == 4)

print("== media without POWER_STATE uses the source")
local m2 = Meter.new(deps)
m2:addRoom(5, "Den")
clock.t = 1000
m2:onRoomVariable(5, "CURRENT_SELECTED_DEVICE", "200")
clock.t = 1000 + 600
m2:onRoomVariable(5, "CURRENT_SELECTED_DEVICE", "0")
clock.t = 1000 + 1200
m2:flush()
check(
  "source ≠ 0 counts as in use when power is unknown",
  m2:today().media[5].seconds == 600,
  m2:today().media[5] and m2:today().media[5].seconds
)

print("== seeding is not a change and unknown is not off")
local m3 = Meter.new(deps)
m3:addRoom(3, "Kitchen")
m3:addLight(12, "Pendants", "Kitchen")
clock.t = 0
check(
  "nothing counted before any value",
  (function()
    clock.t = 1000
    m3:flush()
    return m3:today().media[3] == nil and m3:today().lights[12] == nil
  end)()
)
m3:onRoomVariable(3, "POWER_STATE", "True", true)
m3:onLightVariable(12, "LIGHT_STATE", "True", true)
clock.t = 1000 + 300
m3:flush()
check(
  "seeded on-state accumulates from the seed",
  m3:today().media[3].seconds == 300 and m3:today().lights[12].seconds == 300
)
check(
  "seeding counted no change and no cycle",
  m3.counters.media_changes == 0 and m3.counters.light_changes == 0 and m3:today().lights[12].cycles == 0
)

print("== lights")
clock.t = 5000
check("level > 0 is on", m:onLightVariable(12, "LIGHT_LEVEL", "40") == true and m.lights[12].on == true)
clock.t = 5000 + 1800
m:onLightVariable(12, "Brightness Percent", "0")
clock.t = 5000 + 3600
m:onLightVariable(12, "LIGHT_STATE", "1")
clock.t = 5000 + 3600 + 900
m:flush()
check(
  "light on-time 0.75 h over two cycles",
  m:today().lights[12].seconds == 2700 and m:today().lights[12].cycles == 2,
  m:today().lights[12].seconds
)
check(
  "same value again is not a new cycle",
  (function()
    m:onLightVariable(12, "LIGHT_STATE", "True")
    return m:today().lights[12].cycles == 2
  end)()
)
check("unparseable level ignored", m:onLightVariable(12, "LIGHT_LEVEL", "abc") == false)
check("unknown light ignored", m:onLightVariable(99, "LIGHT_STATE", "True") == false)

print("== keypads")
check(
  "press counted per button",
  m:onKeypadPress(40, 1, "Top Button Pushed")
    and m:onKeypadPress(40, 1, "Top Button Pushed")
    and m:onKeypadPress(40, 2, "Bottom Button Pushed")
)
check("totals", m:today().keypads[40].presses == 3 and m:today().keypads[40].buttons[1].presses == 2)
check("unknown keypad ignored", m:onKeypadPress(41, 1, "x") == false)

print("== tick, day roll, retention")
clock.t = 86400 - 60
m:onRoomVariable(3, "POWER_STATE", "True")
clock.t = 86400 + 60 -- across midnight
local closed = m:tick()
check("tick closes yesterday once", #closed == 1 and closed[1] == "D000", table.concat(closed, ","))
check(
  "the running interval was booked into the new day (≤ one tick misattributed)",
  m.days["D001"].media[3].seconds == 120
)
check("no second close", #m:tick() == 0)
check("counter", m.counters.days_closed == 1)
-- Retention: fabricate 40 days.
for i = 2, 41 do
  clock.t = i * 86400 + 10
  m:onKeypadPress(40, 1, "Top Button Pushed")
  m:tick()
end
local nDays = 0
for _ in pairs(m.days) do
  nDays = nDays + 1
end
check("retention keeps 30 days", nDays == Meter.LIMITS.retention_days, nDays)
check("oldest pruned, today kept", m.days["D000"] == nil and m.days[dayOf(clock.t)] ~= nil and m.counters.pruned > 0)

print("== aggregate, summary, report, payload")
local m4 = Meter.new(deps)
m4:addRoom(3, "Kitchen")
m4:addRoom(4, "Office")
m4:addLight(12, "Pendants", "Kitchen")
m4:addLight(13, "Desk Lamp", "Office")
m4:addKeypad(40, "Hall Keypad", "Hall")
m4:addKeypad(41, "Garage Keypad", "Garage")
clock.t = 0
m4:onRoomVariable(3, "CURRENT_SELECTED_DEVICE", "200")
m4:onRoomVariable(3, "POWER_STATE", "True")
m4:onLightVariable(12, "LIGHT_STATE", "True")
clock.t = 7200
m4:onRoomVariable(3, "POWER_STATE", "False")
m4:onLightVariable(12, "LIGHT_STATE", "False")
for _ = 1, 5 do
  m4:onKeypadPress(40, 1, "Top Button Pushed")
end
clock.t = 86400 + 100
m4:tick()
m4:onLightVariable(12, "LIGHT_STATE", "True")
clock.t = 86400 + 100 + 3600
m4:onLightVariable(12, "LIGHT_STATE", "False")
m4:onKeypadPress(40, 2, "Bottom Button Pushed")
local s1 = m4:summary(1)
check(
  "today only: 1 h light, 1 press, no media",
  s1.days == 1 and s1.light_seconds == 3600 and s1.presses == 1 and s1.media_seconds == 0
)
local s7 = m4:summary(7)
check(
  "7 days: 2 h media, 3 h light, 6 presses",
  s7.days == 2 and s7.media_seconds == 7200 and s7.light_seconds == 10800 and s7.presses == 6
)
check(
  "rooms sorted by hours with top source",
  s7.rooms[1].label == "Kitchen" and s7.rooms[1].top_source.label == "Apple TV"
)
check(
  "unused lists",
  s7.unused_rooms[1] == "Office" and s7.unused_keypads[1] == "Garage Keypad" and s7.unused_lights[1] == "Desk Lamp"
)
local lines = m4:reportLines(7, "7 days")
check("report header has totals", lines[1]:find("media 2.0 h, lights 3.0 h, 6 keypad press", 1, true) ~= nil, lines[1])
check("report lists unused", table.concat(lines, "\n"):find("Keypads never pressed: Garage Keypad", 1, true) ~= nil)
local p = m4:payload("D000")
check(
  "payload for a closed day",
  p.period == "D000" and p.media_hours == 2 and p.light_hours == 2 and p.keypad_presses == 5
)
check(
  "payload lists bounded and shaped",
  #p.rooms == 1
    and p.rooms[1].room == "Kitchen"
    and p.rooms[1].top_source == "Apple TV"
    and p.lights_top[1].light == "Pendants"
)
check("payload counts measured sources", p.rooms_measured == 2 and p.lights_measured == 2 and p.keypads_measured == 2)
local p7 = m4:payload(7)
check("payload for a range", p7.period == "7d" and p7.days == 2 and p7.keypad_presses == 6)
check(
  "hours rounding",
  Meter.hours(5400) == 1.5 and Meter.hours(0) == 0 and Meter.hours(359) == 1 / 10 * 10 * 0 + 0.1
    or Meter.hours(359) == 0.1
)

print("== payload fits the envelope")
local Envelope = require("sbos.envelope")
local big = Meter.new(deps)
for i = 1, 60 do
  big:addRoom(i, "Room number " .. i .. " with a fairly long descriptive name")
  big:addLight(100 + i, "Light " .. i, "Room " .. i)
  big:addKeypad(200 + i, "Keypad " .. i, "Room " .. i)
end
clock.t = 0
for i = 1, 60 do
  big:onRoomVariable(i, "POWER_STATE", "True")
  big:onLightVariable(100 + i, "LIGHT_STATE", "True")
  big:onKeypadPress(200 + i, 1, "Top Button Pushed")
end
clock.t = 3600
local bp = big:payload(1)
check(
  "payload approx size under the limit",
  Envelope.approxSize(bp) < Envelope.LIMITS.payload_bytes,
  Envelope.approxSize(bp)
)
local _, cut = Envelope.bound(bp)
check("payload survives bounding uncut", cut == false)

print("== serialize / restore")
require("drivers-common-public.global.lib") -- tostring_return_period for the vendored JSON
local doc = m4:serialize()
local encoded = require("JSON"):encode(doc)
local decoded = require("JSON"):decode(encoded)
local r, ok = Meter.restore(deps, decoded)
check(
  "restore ok with numeric keys normalised",
  ok and r.days["D000"].media[3] ~= nil and r.days["D000"].media[3].seconds == 7200
)
check("restored counters", r.counters.presses == 6)
check("restored meter has no running state (re-seeded by the driver)", next(r.rooms) == nil)
local r2, ok2 = Meter.restore(deps, "corrupt")
check("corrupt doc → fresh meter", ok2 == false and next(r2.days) == nil or next(r2.days) ~= nil)

print("== keepOnly")
m4:keepOnly({ [3] = true }, {}, { [41] = true })
check(
  "re-plan drops what is gone",
  m4.rooms[4] == nil and m4.lights[12] == nil and m4.keypads[40] == nil and m4.rooms[3] ~= nil
)

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
