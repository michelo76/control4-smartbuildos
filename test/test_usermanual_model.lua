package.path = "src/?.lua;" .. package.path
local Manual = require("usermanual.manual")
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

print("== classify")
check("keypad by file", Manual.classify("control4_lux_configurable_keypad.c4i", "Hall Keypad") == "keypads")
check(
  "keypad dimmer is a keypad (keypad rule first)",
  Manual.classify("control4_lux_keypad_dimmer_switch.c4i", "x") == "keypads"
)
check("light by file", Manual.classify("light_v2.c4i", "Pendants") == "lighting")
check("lux dimmer", Manual.classify("control4_lux_universal_dimmer.c4i", "x") == "lighting")
check("lock", Manual.classify("lock_schlage_zwave.c4z", "Front Door") == "locks")
check("shade", Manual.classify("bond-shade.c4z", "x") == "shades")
check("thermostat", Manual.classify("control4_thermostat_ecobee_thermostat.c4z", "x") == "climate")
check("camera", Manual.classify("unifi-protect-camera.c4z", "x") == "cameras")
check("door station", Manual.classify("control4_doorstation_ds2.c4i", "x") == "cameras")
check("garage", Manual.classify("garagedoor_relay_control.c4i", "x") == "access")
check("security panel", Manual.classify("securitypanel_hsim_honeywell.c4z", "x") == "security")
check("motion sensor", Manual.classify("MotionSensor_zb_nyce_3041.c4i", "x") == "sensors")
check("apple tv", Manual.classify("appleTV.c4z", "x") == "media")
check("receiver", Manual.classify("receiver_Anthem_MRX_740.c4z", "x") == "media")
check("sonos", Manual.classify("sonos.c4z", "x") == "media")
check("name fallback: lamp", Manual.classify("mystery.c4z", "Reading Lamp") == "lighting")
check("name fallback: tv", Manual.classify("mystery.c4z", "Bedroom TV") == "media")
check("nothing matches → other", Manual.classify("mystery.c4z", "Thing") == "other")
check("nil safe", Manual.classify(nil, nil) == "other")

print("== isHomeownerDevice")
check(
  "ordinary light in a room",
  Manual.isHomeownerDevice({ deviceName = "Pendants", driverFileName = "light_v2.c4i", roomName = "Kitchen" }) == true
)
local ok, why =
  Manual.isHomeownerDevice({ deviceName = "Agent", driverFileName = "smartbuildos.c4z", roomName = "Equipment Room" })
check("SmartBuildOS drivers excluded", ok == false and why == "infrastructure driver", why)
ok, why = Manual.isHomeownerDevice({
  deviceName = "Event Tracer",
  driverFileName = "smartbuildos-event-tracer.c4z",
  roomName = "SmartBuildOS",
})
check("sibling drivers excluded", ok == false)
ok, why = Manual.isHomeownerDevice({ deviceName = "Light", driverFileName = "light_v2.c4i", roomName = "" })
check("no room excluded", ok == false and why == "no room")
ok, why = Manual.isHomeownerDevice({ deviceName = "UIDevice 2", driverFileName = "uidevice.c4i", roomName = "Living" })
check("UIDevice excluded", ok == false and why == "infrastructure device")
ok = Manual.isHomeownerDevice({
  deviceName = "Rack",
  driverFileName = "wattbox_wb700ipv12.c4z",
  roomName = "Equipment Room",
})
check("WattBox excluded", ok == false)
check("not a table", Manual.isHomeownerDevice(nil) == false)

print("== parseNotes")
local notes, refusals = Manual.parseNotes({
  "Kitchen: The pendants dim from the keypad by the fridge.",
  "  Living : Soundbar needs the TV on first ",
  "garbage line",
  "",
  "Kitchen: Second note.",
})
check("room keyed lower-case, trimmed", notes["kitchen"] ~= nil and notes["living"] == "Soundbar needs the TV on first")
check(
  "two notes for one room join",
  notes["kitchen"] == "The pendants dim from the keypad by the fridge. Second note.",
  notes["kitchen"]
)
check("a line without a colon is refused by index", #refusals == 1 and refusals[1].index == 3)
check(
  "nil input",
  (function()
    local n, r = Manual.parseNotes(nil)
    return next(n) == nil and #r == 0
  end)()
)

print("== build")
local devices = {
  [12] = { deviceName = "Kitchen Pendants", driverFileName = "light_v2.c4i", roomId = 3, roomName = "Kitchen" },
  [13] = {
    deviceName = "Island Lights",
    driverFileName = "control4_lux_universal_dimmer.c4i",
    roomId = 3,
    roomName = "Kitchen",
  },
  [14] = {
    deviceName = "Fridge Keypad",
    driverFileName = "control4_lux_configurable_keypad.c4i",
    roomId = 3,
    roomName = "Kitchen",
  },
  [20] = { deviceName = "Front Door", driverFileName = "lock_yale_zwave.c4z", roomId = 1, roomName = "Entry" },
  [21] = {
    deviceName = "Door Station",
    driverFileName = "control4_doorstation_ds2.c4i",
    roomId = 1,
    roomName = "Entry",
  },
  [30] = { deviceName = "Apple TV", driverFileName = "appleTV.c4z", roomId = 5, roomName = "Living" },
  [31] = { deviceName = "Living TV", driverFileName = "lg_tv_OLED77C5PUA.c4z", roomId = 5, roomName = "Living" },
  [32] = { deviceName = "Sonos", driverFileName = "sonos.c4z", roomId = 5, roomName = "Living" },
  [33] = { deviceName = "Mystery Gadget", driverFileName = "gadget.c4z", roomId = 5, roomName = "Living" },
  [50] = {
    deviceName = "SmartBuildOS Agent",
    driverFileName = "smartbuildos.c4z",
    roomId = 9,
    roomName = "Equipment Room",
  },
  [51] = {
    deviceName = "Rack Power",
    driverFileName = "wattbox_wb700ipv12.c4z",
    roomId = 9,
    roomName = "Equipment Room",
  },
  [52] = { deviceName = "UIDevice 2", driverFileName = "uidevice.c4i", roomId = 5, roomName = "Living" },
  [60] = { deviceName = "Orphan", driverFileName = "light_v2.c4i" },
}
local doc = Manual.build({
  devices = devices,
  dealer = {
    name = "Skynet AV",
    phone = " 555-0100 ",
    email = "",
    hours = "Mon–Fri 9–5",
    emergency = "After hours: text the number",
  },
  notes = { "kitchen: Pendants dim from the fridge keypad." },
  home_name = "Beta Site 2",
  generated_at = "2026-11-09T05:00:00Z",
  driver_version = "1",
})
check("three rooms (Equipment Room has nothing homeowner-facing)", doc.counts.rooms == 3, doc.counts.rooms)
check(
  "rooms sorted by name",
  doc.rooms[1].name == "Entry" and doc.rooms[2].name == "Kitchen" and doc.rooms[3].name == "Living"
)
check(
  "nine devices counted, five excluded",
  doc.counts.devices == 9 and doc.counts.excluded == 4,
  doc.counts.devices .. "/" .. doc.counts.excluded
)
check(
  "excluded reasons tallied",
  doc.excluded_by_reason["infrastructure driver"] == 2
    and doc.excluded_by_reason["infrastructure device"] == 1
    and doc.excluded_by_reason["no room"] == 1
)
local kitchen = doc.rooms[2]
check(
  "kitchen groups ordered lights then keypads",
  kitchen.groups[1].category == "lighting" and kitchen.groups[2].category == "keypads"
)
check(
  "devices within a group sorted by name",
  kitchen.groups[1].devices[1].name == "Island Lights" and kitchen.groups[1].devices[2].name == "Kitchen Pendants"
)
check("group carries the how-to paragraph", kitchen.groups[1].howto:find("dim", 1, true) ~= nil)
check("kitchen note attached case-insensitively", kitchen.note == "Pendants dim from the fridge keypad.")
check("room without a note has nil", doc.rooms[1].note == nil)
local living = doc.rooms[3]
check(
  "living: media group holds three, other holds the gadget",
  living.groups[1].category == "media" and #living.groups[1].devices == 3 and living.groups[2].category == "other"
)
check(
  "dealer block trimmed, empties dropped",
  doc.dealer.name == "Skynet AV" and doc.dealer.phone == "555-0100" and doc.dealer.email == nil
)
check("home name and timestamp", doc.home_name == "Beta Site 2" and doc.generated_at == "2026-11-09T05:00:00Z")
check(
  "categories present listed in table order",
  doc.categories[1].key == "lighting" and doc.categories[#doc.categories].key == "other"
)
check("troubleshooting present", #doc.troubleshooting == #Manual.TROUBLESHOOTING)
local again = Manual.build({ devices = devices, generated_at = "x" })
check("default home name", again.home_name == "Your home" and again.dealer.name == nil)
check("deterministic order across builds", again.rooms[2].groups[1].devices[1].name == "Island Lights")
local empty = Manual.build({})
check(
  "empty project builds an empty manual",
  empty.counts.rooms == 0 and empty.counts.devices == 0 and #empty.rooms == 0
)

print("== outline")
local lines = Manual.outline(doc)
check("header line", lines[1]:find("Beta Site 2 — 3 room%(s%), 9 device%(s%)") ~= nil, lines[1])
check("dealer line", lines[2]:find("Skynet AV", 1, true) ~= nil)
check(
  "room line marks a note",
  (function()
    for _, l in ipairs(lines) do
      if l:find("^Kitchen %(3%)  — note") then
        return true
      end
    end
    return false
  end)()
)
check("exclusions line last", lines[#lines]:find("^Not in the manual:") ~= nil, lines[#lines])

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
