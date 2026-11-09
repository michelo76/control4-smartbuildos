--- Home Guide — the manual model (pure).
---
--- Turns the project as Director describes it (`C4:GetDevices({})` shape:
--- `{ [id] = { deviceName, driverFileName, roomId, roomName } }`) into a
--- document a homeowner can read: one section per room, devices grouped by
--- what they are (lights, shades, locks, climate, keypads, media, cameras,
--- garage and gates, security, sensors), each group with a plain-language
--- "how to" paragraph, plus the dealer's contact block, per-room notes the
--- dealer typed, and a short "what to do if" list.
---
--- Rules a dealer relies on:
---   • CLASSIFICATION IS BY DRIVER FILE NAME, then by device name. The table
---     below is the whole rule; a device nothing matches lands in "Other
---     equipment" rather than disappearing.
---   • UTILITY DRIVERS ARE NOT IN THE MANUAL: SmartBuildOS drivers, agents,
---     the Director itself, relays named "Utility", and anything with no room
---     are infrastructure, not something the homeowner operates.
---   • DETERMINISTIC: rooms and devices sort by name, so two rebuilds of the
---     same project produce the same document.
---   • NO VALUES: the manual lists what exists, never its state.

local M = {}

M.SCHEMA_VERSION = 1

--- Category table: key, title, the paragraph the homeowner reads, and the
--- order sections appear in inside a room.
M.CATEGORIES = {
  {
    key = "lighting",
    title = "Lights",
    order = 10,
    howto = "Tap a light to switch it on or off, or hold and drag to dim. Lighting scenes on your keypads and in the app set several lights at once; a double-tap on a keypad's top button usually takes the room to full.",
  },
  {
    key = "keypads",
    title = "Keypads",
    order = 20,
    howto = "Each engraved button runs a scene. A single tap starts it; many scenes toggle off on a second tap. If a button's light stays on, the scene it controls is still active somewhere in the house.",
  },
  {
    key = "shades",
    title = "Shades and blinds",
    order = 30,
    howto = "Open, close or stop shades from the room screen, or drag the slider to a position. Shades can also follow the sun or a schedule; ask your dealer to adjust the times if they move when you do not expect it.",
  },
  {
    key = "climate",
    title = "Heating and cooling",
    order = 40,
    howto = "Set the temperature from the thermostat screen in the app. Changing the mode between heat, cool and auto is on the same screen. A schedule runs underneath; a manual change holds until the next scheduled time.",
  },
  {
    key = "locks",
    title = "Door locks",
    order = 50,
    howto = "Lock and unlock from the app or with a code on the lock itself. Each household member can have their own code. If a lock reports a low battery, replace the batteries soon; the key still works.",
  },
  {
    key = "media",
    title = "TV and music",
    order = 60,
    howto = "Choose Watch or Listen in a room, then pick a source. The remote follows what is on screen. Room Off turns everything in that room off together; the house-wide Off button turns off every room.",
  },
  {
    key = "cameras",
    title = "Cameras and doorbells",
    order = 70,
    howto = "Live views are under Cameras. A doorbell press rings the touch screens and the app and shows the door camera; answering lets you speak to the visitor.",
  },
  {
    key = "access",
    title = "Garage, gates and doors",
    order = 80,
    howto = "Open and close from the room screen or the Security section. A door left open can send a reminder; your dealer sets how long before it reminds you.",
  },
  {
    key = "security",
    title = "Security system",
    order = 90,
    howto = "Arm and disarm from the Security screen with your code. Away arms every sensor; Stay leaves the inside motion sensors off so you can move around.",
  },
  {
    key = "sensors",
    title = "Sensors",
    order = 100,
    howto = "Door, window and motion sensors feed the automation and the security system. They need no attention beyond a battery change when the system reports one.",
  },
  {
    key = "other",
    title = "Other equipment",
    order = 200,
    howto = "Equipment your dealer set up for this room. Ask your dealer if you are unsure what it does.",
  },
}

local CATEGORY_BY_KEY = {}
for _, c in ipairs(M.CATEGORIES) do
  CATEGORY_BY_KEY[c.key] = c
end
M.CATEGORY_BY_KEY = CATEGORY_BY_KEY

--- Driver-file fragments (lower-cased, matched in order; first hit wins).
local FILE_RULES = {
  { "keypad", "keypads" },
  { "lock_", "locks" },
  { "lock.", "locks" },
  { "yale", "locks" },
  { "schlage", "locks" },
  { "kwikset", "locks" },
  { "blind", "shades" },
  { "shade", "shades" },
  { "somfy", "shades" },
  { "lutron_leap_venetian", "shades" },
  { "thermostat", "climate" },
  { "tstat", "climate" },
  { "ecobee", "climate" },
  { "nest_sdm", "climate" },
  { "hvac", "climate" },
  { "camera", "cameras" },
  { "doorstation", "cameras" },
  { "doorbell", "cameras" },
  { "protect_", "cameras" },
  { "garage", "access" },
  { "gate_", "access" },
  { "gdo", "access" },
  { "door_relay", "access" },
  { "security", "security" },
  { "securitypanel", "security" },
  { "alarm", "security" },
  { "hsim", "security" },
  { "motion", "sensors" },
  { "contact", "sensors" },
  { "doorwindow", "sensors" },
  { "hingesensor", "sensors" },
  { "sensor", "sensors" },
  { "light", "lighting" },
  { "dimmer", "lighting" },
  { "switch", "lighting" },
  { "lux_", "lighting" },
  { "hue", "lighting" },
  { "bulb", "lighting" },
  { "ketra", "lighting" },
  { "lumaris", "lighting" },
  { "tv_", "media" },
  { "_tv", "media" },
  { "appletv", "media" },
  { "apple_tv", "media" },
  { "roku", "media" },
  { "shield", "media" },
  { "receiver", "media" },
  { "amplifier", "media" },
  { "amp", "media" },
  { "sonos", "media" },
  { "spotify", "media" },
  { "pandora", "media" },
  { "tidal", "media" },
  { "deezer", "media" },
  { "qobuz", "media" },
  { "tunein", "media" },
  { "siriusxm", "media" },
  { "music", "media" },
  { "dvd", "media" },
  { "bluray", "media" },
  { "cable", "media" },
  { "tivo", "media" },
  { "avswitch", "media" },
  { "matrix", "media" },
  { "hdmi", "media" },
  { "uibutton_", "media" },
  { "media", "media" },
  { "triad", "media" },
  { "episode", "media" },
  { "fan", "other" },
  { "fireplace", "other" },
}

--- Device-name fragments, consulted when the file name decided nothing.
local NAME_RULES = {
  { "keypad", "keypads" },
  { "lock", "locks" },
  { "shade", "shades" },
  { "blind", "shades" },
  { "thermostat", "climate" },
  { "camera", "cameras" },
  { "doorbell", "cameras" },
  { "garage", "access" },
  { "gate", "access" },
  { "alarm", "security" },
  { "motion", "sensors" },
  { "sensor", "sensors" },
  { "light", "lighting" },
  { "lamp", "lighting" },
  { "tv", "media" },
  { "speaker", "media" },
  { "sonos", "media" },
  { "receiver", "media" },
}

--- Infrastructure the homeowner never operates. Exact-prefix rules on the
--- driver file plus a few device names Composer adds on its own.
local EXCLUDED_FILE_PREFIXES =
  { "smartbuildos", "control4_agent", "agent_", "agent-", "unifi-protect.c4z", "unifi_gateway" }
local EXCLUDED_FILE_FRAGMENTS = {
  "roomdevice",
  "director",
  "controller",
  "wattbox",
  "timer_",
  "snapshot",
  "occupancy_simulation",
  "scenario",
  "experience_scenario",
  "webview",
  "c4_av-",
  "av-path",
  "security-light",
  "luminalogic-probe",
  "bond-bridge",
  "driverworks_bond_bridge",
  "lutron_leap_processor",
  "lutron_leap_ra3_processor",
  "nest_sdm_master",
  "control4_thermostat_ecobee_network",
}
local EXCLUDED_NAME_FRAGMENTS =
  { "uidevice", "director", "controller", "navigator", "touch screen", "touchscreen", "ea-", "core" }

local function lower(s)
  return tostring(s or ""):lower()
end

--- The category key for a device, by driver file first, then by name.
--- @param driverFile string|nil
--- @param deviceName string|nil
--- @return string key
function M.classify(driverFile, deviceName)
  local file = lower(driverFile)
  for _, rule in ipairs(FILE_RULES) do
    if file:find(rule[1], 1, true) then
      return rule[2]
    end
  end
  local name = lower(deviceName)
  for _, rule in ipairs(NAME_RULES) do
    if name:find(rule[1], 1, true) then
      return rule[2]
    end
  end
  return "other"
end

--- Whether a device belongs in a homeowner's manual at all.
--- @return boolean included, string|nil reason
function M.isHomeownerDevice(device)
  if type(device) ~= "table" then
    return false, "not a device"
  end
  local file = lower(device.driverFileName)
  local name = lower(device.deviceName)
  local room = tostring(device.roomName or "")
  if room == "" then
    return false, "no room"
  end
  for _, prefix in ipairs(EXCLUDED_FILE_PREFIXES) do
    if file:sub(1, #prefix) == prefix then
      return false, "infrastructure driver"
    end
  end
  for _, frag in ipairs(EXCLUDED_FILE_FRAGMENTS) do
    if file:find(frag, 1, true) then
      return false, "infrastructure driver"
    end
  end
  for _, frag in ipairs(EXCLUDED_NAME_FRAGMENTS) do
    if name:find(frag, 1, true) then
      return false, "infrastructure device"
    end
  end
  return true
end

--- Parses the dealer's room notes, one property each, written as
--- "Room name: text". Lines without a colon are ignored; room names match
--- case-insensitively after trimming.
--- @param lines string[]
--- @return table<string,string> notesByRoomLower, table refusals
function M.parseNotes(lines)
  local notes, refusals = {}, {}
  for i, raw in ipairs(lines or {}) do
    local text = tostring(raw or "")
    if text:match("%S") then
      local room, body = text:match("^%s*([^:]-)%s*:%s*(.-)%s*$")
      if room == nil or room == "" or body == nil or body == "" then
        refusals[#refusals + 1] = { index = i, reason = "expected 'Room name: note'" }
      else
        local key = room:lower()
        notes[key] = notes[key] and (notes[key] .. " " .. body) or body
      end
    end
  end
  return notes, refusals
end

--- The "what to do if" list every manual carries.
M.TROUBLESHOOTING = {
  {
    title = "A touch screen or the app shows nothing or is slow",
    text = "Wait two minutes: the system may be restarting after a power blip. If it stays blank, switch the main controller off at its power supply for ten seconds and back on, then allow five minutes.",
  },
  {
    title = "A remote does not respond",
    text = "Replace its batteries first. Then press any button and wait ten seconds; it reconnects on its own.",
  },
  {
    title = "Music or TV plays in the wrong room",
    text = "Open that room in the app and press Room Off, then start again from the room you want.",
  },
  {
    title = "Wi-Fi works but the app says it cannot connect",
    text = "The app reaches the house through the internet connection. Restart the internet router, wait five minutes, and try again.",
  },
  {
    title = "A light, shade or lock stops responding",
    text = "Note which device and when, then contact your dealer. Most devices recover after a power cycle of the controller, which your dealer can do remotely.",
  },
}

local function sortByName(list)
  table.sort(list, function(a, b)
    if a.name == b.name then
      return (a.id or 0) < (b.id or 0)
    end
    return tostring(a.name) < tostring(b.name)
  end)
  return list
end

--- Builds the manual document.
--- @param input table {
---   devices = GetDevices-shaped table,
---   dealer = { name, phone, email, hours, emergency },
---   notes = string[] ("Room: text"),
---   home_name = string|nil, generated_at = string (ISO), driver_version = string|nil }
--- @return table doc
function M.build(input)
  input = input or {}
  local roomsById = {}
  local excluded = { count = 0, by_reason = {} }
  for rawId, d in pairs(input.devices or {}) do
    local id = tonumber(rawId)
    if id ~= nil and type(d) == "table" then
      local ok, reason = M.isHomeownerDevice(d)
      if ok then
        local roomId = tonumber(d.roomId) or 0
        local roomName = tostring(d.roomName)
        local key = roomId ~= 0 and ("id:" .. roomId) or ("name:" .. roomName:lower())
        local room = roomsById[key]
        if room == nil then
          room = { id = roomId ~= 0 and roomId or nil, name = roomName, groups = {}, device_count = 0 }
          roomsById[key] = room
        end
        local category = M.classify(d.driverFileName, d.deviceName)
        room.groups[category] = room.groups[category] or {}
        local g = room.groups[category]
        g[#g + 1] =
          { id = id, name = tostring(d.deviceName or ("Device " .. id)), driver = tostring(d.driverFileName or "") }
        room.device_count = room.device_count + 1
      else
        excluded.count = excluded.count + 1
        excluded.by_reason[reason] = (excluded.by_reason[reason] or 0) + 1
      end
    end
  end
  local notes = M.parseNotes(input.notes)
  local rooms = {}
  local present = {}
  local deviceTotal = 0
  for _, room in pairs(roomsById) do
    local groups = {}
    for category, devices in pairs(room.groups) do
      local c = CATEGORY_BY_KEY[category] or CATEGORY_BY_KEY.other
      groups[#groups + 1] = {
        category = c.key,
        title = c.title,
        howto = c.howto,
        order = c.order,
        devices = sortByName(devices),
      }
      present[c.key] = true
    end
    table.sort(groups, function(a, b)
      if a.order == b.order then
        return a.title < b.title
      end
      return a.order < b.order
    end)
    for _, g in ipairs(groups) do
      g.order = nil
    end
    deviceTotal = deviceTotal + room.device_count
    rooms[#rooms + 1] = {
      id = room.id,
      name = room.name,
      device_count = room.device_count,
      note = notes[room.name:lower()],
      groups = groups,
    }
  end
  sortByName(rooms)
  local categories = {}
  for _, c in ipairs(M.CATEGORIES) do
    if present[c.key] then
      categories[#categories + 1] = { key = c.key, title = c.title }
    end
  end
  local dealer = input.dealer or {}
  local function clean(v)
    v = tostring(v or ""):gsub("^%s+", ""):gsub("%s+$", "")
    return v ~= "" and v or nil
  end
  return {
    schema_version = M.SCHEMA_VERSION,
    generated_at = tostring(input.generated_at or ""),
    driver_version = input.driver_version,
    home_name = clean(input.home_name) or "Your home",
    dealer = {
      name = clean(dealer.name),
      phone = clean(dealer.phone),
      email = clean(dealer.email),
      hours = clean(dealer.hours),
      emergency = clean(dealer.emergency),
    },
    rooms = rooms,
    categories = categories,
    troubleshooting = M.TROUBLESHOOTING,
    counts = { rooms = #rooms, devices = deviceTotal, excluded = excluded.count },
    excluded_by_reason = excluded.by_reason,
  }
end

--- A plain-text outline for Director's log.
--- @return string[] lines
function M.outline(doc)
  local lines = {}
  lines[#lines + 1] = string.format(
    "%s — %d room(s), %d device(s), generated %s",
    tostring(doc.home_name),
    doc.counts.rooms,
    doc.counts.devices,
    tostring(doc.generated_at)
  )
  if doc.dealer.name then
    lines[#lines + 1] =
      string.format("Dealer: %s %s %s", doc.dealer.name, doc.dealer.phone or "", doc.dealer.email or "")
  end
  for _, room in ipairs(doc.rooms) do
    lines[#lines + 1] = string.format("%s (%d)%s", room.name, room.device_count, room.note and "  — note" or "")
    for _, g in ipairs(room.groups) do
      local names = {}
      for _, d in ipairs(g.devices) do
        names[#names + 1] = d.name
      end
      lines[#lines + 1] = string.format("  %s: %s", g.title, table.concat(names, ", "))
    end
  end
  if doc.counts.excluded > 0 then
    local parts = {}
    for reason, n in pairs(doc.excluded_by_reason) do
      parts[#parts + 1] = n .. " " .. reason
    end
    table.sort(parts)
    lines[#lines + 1] = "Not in the manual: " .. table.concat(parts, "; ")
  end
  return lines
end

return M
