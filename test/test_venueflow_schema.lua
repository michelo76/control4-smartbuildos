-- VenueFlow configuration schema (pure): defaults, stable identifiers, every
-- class of validation issue, publishability, and mapping integrity (a layout
-- change can never alter a Control4 mapping).
--
-- Run from the driver root: make test

local H = require("venueflow_harness")
local Schema = require("venueflow.schema")
local U = require("venueflow.util")
local T = H.checker()
local check, eq = T.check, T.eq

local function codes(config)
  local out = {}
  for _, i in ipairs(Schema.validate(Schema.normalize(config))) do
    out[i.code] = i.severity
  end
  return out
end
local function with(mutate)
  local c = H.Templates.sportsBar()
  mutate(c)
  return codes(c)
end

-- ── defaults and normalisation ──────────────────────────────────────────────
print("defaults")
local empty = Schema.normalize({})
eq("schema version", empty.schema, Schema.SCHEMA_VERSION)
eq("every list exists", #Schema.LIST_FIELDS, 14)
for _, field in ipairs(Schema.LIST_FIELDS) do
  check(field .. " defaults to a list", type(empty[field]) == "table")
end
check("layout extras exist", type(empty.layout.labels) == "table" and type(empty.layout.sceneButtons) == "table")
local d = Schema.normalize({
  displays = { { id = "a", name = "A" } },
  audioZones = { { id = "z", name = "Z" } },
  profiles = { { id = "p", name = "P" } },
})
eq("display route defaults to room", d.displays[1].route.strategy, "room")
eq("display accepts all sources by default", d.displays[1].sources, "all")
eq("display power defaults to room", d.displays[1].power, "room")
eq("zone limits default", d.audioZones[1].minVolume .. "-" .. d.audioZones[1].maxVolume, "0-100")
eq("a new profile can do nothing until granted", d.profiles[1].permissions.allOff, false)
eq("...and routes nothing", d.profiles[1].permissions.routeVideo, false)
local once = Schema.normalize(H.Templates.sportsBar())
check("normalising twice changes nothing", U.equal(once, Schema.normalize(once)))
local keep = Schema.normalize({
  venue = { name = "x", futureField = 7 },
  displays = { { id = "a", name = "A", vendorNote = "kept" } },
})
check(
  "unknown fields are kept (a newer Studio's data survives)",
  keep.venue.futureField == 7 and keep.displays[1].vendorNote == "kept"
)
local input = { displays = { { id = "a", name = "A" } } }
Schema.normalize(input)
eq("normalise does not modify its input", input.displays[1].route, nil)

-- ── identifiers ─────────────────────────────────────────────────────────────
print("identifiers")
for _, good in ipairs({ "tv-01", "a", "zone_bar", "0", "x-1_2" }) do
  check("id " .. good .. " accepted", U.isId(good))
end
for _, bad in ipairs({ "", "TV-01", "tv 01", "-tv", "tv.01", "é", string.rep("a", 49) }) do
  check("id '" .. bad:sub(1, 12) .. "' refused", not U.isId(bad))
end
eq("slug", U.slug("Bar TV #01!"), "bar-tv-01")
eq("fresh id avoids taken ones", U.freshId("Bar TV", { ["bar-tv"] = true, ["bar-tv-2"] = true }), "bar-tv-3")
eq(
  "duplicate ids",
  with(function(c)
    c.displays[2].id = c.displays[1].id
  end).ID_DUPLICATE,
  "error"
)
eq(
  "malformed id",
  with(function(c)
    c.sources[1].id = "Sports 1"
  end).ID_INVALID,
  "error"
)
eq(
  "missing name",
  with(function(c)
    c.displays[1].name = "  "
  end).NAME_MISSING,
  "error"
)
eq(
  "overlong name",
  with(function(c)
    c.displays[1].name = string.rep("n", 81)
  end).NAME_TOO_LONG,
  "error"
)
-- A rename never changes an id, and every reference still resolves.
local renamed = H.Templates.sportsBar()
renamed.displays[1].name = "The Big One"
renamed.sources[1].name = "Main Event"
renamed.groups[1].name = "Front Row"
local errors = 0
for _, i in ipairs(Schema.validate(renamed)) do
  if i.severity == "error" then
    errors = errors + 1
  end
end
eq("renaming entities breaks nothing", errors, 0)
eq("ids unchanged by a rename", renamed.displays[1].id .. "/" .. renamed.sources[1].id, "tv-01/sports-1")

-- ── structural errors ───────────────────────────────────────────────────────
print("errors that block publishing")
eq(
  "no floor",
  codes({ venue = { name = "v" }, profiles = { { id = "p", name = "P", interfaces = { "room" } } } }).NO_FLOOR,
  "error"
)
eq("no profile", codes({ venue = { name = "v" }, floors = { { id = "f", name = "F" } } }).NO_PROFILE, "error")
eq("no venue name", codes({ floors = { { id = "f", name = "F" } } }).NAME_MISSING, "error")
eq(
  "unknown venue type",
  with(function(c)
    c.venue.type = "casino"
  end).ENUM,
  "error"
)
eq(
  "a list that is not a list",
  with(function(c)
    c.displays = { a = 1 }
  end).NOT_A_LIST,
  "error"
)
eq(
  "too many displays",
  with(function(c)
    for i = 1, 201 do
      c.displays[i] = { id = "d" .. i, name = "D", floorId = "main-floor" }
    end
  end).TOO_MANY,
  "error"
)
eq(
  "a display on an unknown floor",
  with(function(c)
    c.displays[1].floorId = "roof"
  end).REF_UNKNOWN,
  "error"
)
eq(
  "a display with no floor",
  with(function(c)
    c.displays[1].floorId = nil
  end).REF_MISSING,
  "error"
)
eq(
  "a display whose area is on another floor",
  with(function(c)
    c.floors[2] = { id = "upstairs", name = "Upstairs" }
    c.areas[1].floorId = "upstairs"
  end).AREA_FLOOR_MISMATCH,
  "error"
)
eq(
  "a group naming a missing display",
  with(function(c)
    c.groups[1].displayIds[1] = "tv-99"
  end).REF_UNKNOWN,
  "error"
)
eq(
  "a Control4 id that is not a number",
  with(function(c)
    c.displays[1].c4RoomId = "1101"
  end).C4_ID_INVALID,
  "error"
)
eq(
  "a Control4 id that is not whole",
  with(function(c)
    c.sources[1].c4DeviceId = 30.5
  end).C4_ID_INVALID,
  "error"
)
eq(
  "two displays in one Control4 room",
  with(function(c)
    c.displays[2].c4RoomId = c.displays[1].c4RoomId
  end).DISPLAY_ROOM_SHARED,
  "error"
)
eq(
  "a source with neither video nor audio",
  with(function(c)
    c.sources[1].video, c.sources[1].audio = false, false
  end).SOURCE_NO_MEDIA,
  "error"
)
eq(
  "a custom route without a command",
  with(function(c)
    c.displays[1].route = { strategy = "command" }
  end).ROUTE_COMMAND_INVALID,
  "error"
)
eq(
  "an unknown route strategy",
  with(function(c)
    c.displays[1].route = { strategy = "magic" }
  end).ENUM,
  "error"
)
eq(
  "floor size out of range",
  with(function(c)
    c.floors[1].width = 5
  end).RANGE,
  "error"
)
eq(
  "a layout that is not numbers",
  with(function(c)
    c.displays[1].layout.x = "left"
  end).LAYOUT_INVALID,
  "error"
)
eq(
  "a profile with no interface",
  with(function(c)
    c.profiles[1].interfaces = {}
  end).PROFILE_NO_INTERFACE,
  "error"
)
eq(
  "a default interface the profile may not use",
  with(function(c)
    c.profiles[1].defaultInterface = "room"
  end).PROFILE_DEFAULT_INTERFACE,
  "error"
)
eq(
  "a permission that is not a boolean",
  with(function(c)
    c.profiles[1].permissions.allOff = "yes"
  end).PERMISSION_INVALID,
  "error"
)
eq(
  "a permission scope naming a missing area",
  with(function(c)
    c.profiles[2].permissions.areas = { "cellar" }
  end).REF_UNKNOWN,
  "error"
)
eq(
  "a default profile that needs a PIN",
  with(function(c)
    c.profiles[2].pinHash, c.profiles[2].pinSalt = "h", "s"
  end).DEFAULT_PROFILE_HAS_PIN,
  "error"
)
eq(
  "a default profile that does not exist",
  with(function(c)
    c.defaultProfileId = "ghost"
  end).REF_UNKNOWN,
  "error"
)
eq(
  "a room button without a scene",
  with(function(c)
    c.rooms[1].buttons[1].sceneId = "ghost"
  end).REF_UNKNOWN,
  "error"
)
eq(
  "a scene button for a missing scene",
  with(function(c)
    c.layout.sceneButtons[1].sceneId = "ghost"
  end).REF_UNKNOWN,
  "error"
)
eq(
  "a label that is too long",
  with(function(c)
    c.layout.labels[1].text = string.rep("x", 121)
  end).LABEL_TEXT,
  "error"
)
eq(
  "a lighting preset with bad parameters",
  with(function(c)
    c.lighting[1].presets[1].params = "SCENE_ID=11"
  end).PARAMS_INVALID,
  "error"
)
eq(
  "a variable of unknown type",
  with(function(c)
    c.variables[1].type = "date"
  end).ENUM,
  "error"
)
eq("not an object at all", Schema.validate("hello")[1].code, "NOT_AN_OBJECT")

eq(
  "a room panel with more than six buttons",
  with(function(c)
    for i = 1, 7 do
      c.rooms[1].buttons[i] = { id = "b" .. i, label = "B", sceneId = "opening" }
    end
  end).ROOM_TOO_MANY_BUTTONS,
  "error"
)
-- Issues use machine kinds, and name the other entity involved.
do
  local c = H.Templates.sportsBar()
  c.displays[1].name = ""
  c.audioZones[1].c4RoomId = c.displays[2].c4RoomId
  local byCode = {}
  for _, i in ipairs(Schema.validate(Schema.normalize(c))) do
    byCode[i.code] = i
  end
  eq("a name issue carries the machine kind", byCode.NAME_MISSING.entity.kind, "display")
  eq("a coupling issue is on the display", byCode.AUDIO_COUPLED.entity.id, "tv-02")
  eq(
    "...and names the zone as related",
    byCode.AUDIO_COUPLED.related.kind .. ":" .. byCode.AUDIO_COUPLED.related.id,
    "audioZone:zone-bar"
  )
end

-- ── warnings that need resolving or acknowledging ───────────────────────────
print("warnings")
eq(
  "an unmapped display",
  with(function(c)
    c.displays[1].c4RoomId = nil
  end).DISPLAY_UNMAPPED,
  "warning"
)
eq(
  "an unmapped source",
  with(function(c)
    c.sources[1].c4DeviceId = nil
  end).SOURCE_UNMAPPED,
  "warning"
)
eq(
  "an unmapped zone",
  with(function(c)
    c.audioZones[1].c4RoomId = nil
  end).ZONE_UNMAPPED,
  "warning"
)
eq(
  "device power with no device",
  with(function(c)
    c.displays[1].power, c.displays[1].c4DeviceId = "device", nil
  end).DISPLAY_POWER_UNMAPPED,
  "warning"
)
eq(
  "two sources on one Control4 device",
  with(function(c)
    c.sources[2].c4DeviceId = c.sources[1].c4DeviceId
  end).SOURCE_DEVICE_SHARED,
  "warning"
)
eq("a custom route is flagged as unverifiable", with(function() end).ROUTE_COMMAND_UNVERIFIED, "warning")
eq("a manager without a PIN", with(function() end).PROFILE_NO_PIN, "warning")
eq(
  "a lighting preset with no device",
  with(function(c)
    c.lighting[1].presets[1].deviceId = nil
  end).LIGHTING_UNMAPPED,
  "warning"
)

-- ── publishability ──────────────────────────────────────────────────────────
print("publishing rules")
local issues = Schema.validate(H.Templates.sportsBar())
local ok, blocking = Schema.publishable(issues, {})
check("unacknowledged warnings block", not ok and #blocking == #issues)
local acks = {}
for _, i in ipairs(issues) do
  acks[#acks + 1] = i.id
end
check("acknowledged warnings pass", (Schema.publishable(issues, acks)))
local broken = H.Templates.sportsBar()
broken.displays[1].floorId = "roof"
issues = Schema.validate(broken)
acks = {}
for _, i in ipairs(issues) do
  acks[#acks + 1] = i.id
end
check("an error cannot be acknowledged away", not (Schema.publishable(issues, acks)))
eq("issue ids are stable (code and path)", Schema.validate(broken)[1].id, issues[1].id)
local summary = Schema.summarize(issues)
check("summary counts", summary.errors >= 1 and summary.warnings >= 1)

-- ── mapping integrity ───────────────────────────────────────────────────────
print("layout never touches a mapping")
local env = H.new()
local studio = env.publishSample("sports_bar")
local S = { session = studio }
local before = env.send("DRAFT_GET", {}, S).data.draft
local mapping = {}
for _, disp in ipairs(before.config.displays) do
  mapping[disp.id] = {
    disp.c4RoomId,
    disp.c4DeviceId,
    H.JSON:encode(disp.route),
    H.JSON:encode(disp.sources),
    disp.power,
    disp.feedback,
  }
end
-- Move, resize, rotate, hide and lock every icon; take one off the plan.
for i, disp in ipairs(before.config.displays) do
  disp.layout = { x = 10 + i, y = 700 - i, w = 120, h = 30, rot = 270, locked = true, hidden = i % 2 == 0 }
end
before.config.displays[5].layout = nil
before.config.areas[1].layout = { x = 0, y = 0, w = 10, h = 10 }
before.config.layout.labels = {}
before.config.layout.sceneButtons = {}
local r = env.send("DRAFT_SAVE", { config = before.config, baseRevision = before.revision }, S)
check("layout changes save", r.ok and r.data.summary.errors == 0)
check("published", env.send("PUBLISH", { acknowledged = { r.data.issues[1].id } }, S).ok)
local same = true
for _, disp in ipairs(env.core.config.displays) do
  local m = mapping[disp.id]
  if
    disp.c4RoomId ~= m[1]
    or disp.c4DeviceId ~= m[2]
    or H.JSON:encode(disp.route) ~= m[3]
    or H.JSON:encode(disp.sources) ~= m[4]
    or disp.power ~= m[5]
    or disp.feedback ~= m[6]
  then
    same = false
  end
end
check("every display's Control4 mapping is exactly as before", same)
eq("the display taken off the plan still exists", env.core.ix.displays["tv-05"].name, "TV 05")
local route = env.send("ROUTE_VIDEO", { sourceId = "sports-1", displayIds = { "tv-05" } }, S)
eq("...and is still controllable", route.status, "accepted")
env.settle(1500)
eq("...through the same Control4 room", env.sim().calls[#env.sim().calls].target, 1105)
-- Deleting a display from the configuration deletes nothing in "Control4".
local draft = env.send("DRAFT_GET", {}, S).data.draft
table.remove(draft.config.displays, 5)
draft.config.groups[1].displayIds = { "tv-01", "tv-02", "tv-03", "tv-04", "tv-06", "tv-07", "tv-08" }
draft.config.scenes[2].program.steps[2].target.displayIds = { "tv-01", "tv-02", "tv-03", "tv-04", "tv-06" }
draft.config.scenes[3].program.steps[1].target.displayIds = { "tv-04", "tv-13" }
r = env.send("DRAFT_SAVE", { config = draft.config, baseRevision = draft.revision }, S)
eq("a display can be deleted once its references are cleared", r.data.summary.errors, 0)
env.send("PUBLISH", { acknowledged = { r.data.issues[1].id } }, S)
-- (Publishing rebuilds the simulated project; its command log starts empty.)
eq("publishing the deletion sends no command to Control4", env.sim():callCount(), 0)
check("the venue no longer lists it", env.core.ix.displays["tv-05"] == nil)

-- ── the tune step (a source put on a channel by a scene, rule or schedule) ─
print("tune step validation")
do
  -- Issues raised on the tune step at the end of Game Day, after `mutate`.
  local function tuneIssues(step, mutate)
    local c = H.Templates.sportsBar()
    local steps = c.scenes[2].program.steps
    assert(c.scenes[2].id == "game-day")
    steps[#steps + 1] = step
    if mutate then
      mutate(c)
    end
    local at = string.format("scenes[2].program.steps[%d]", #steps)
    local out = {}
    for _, i in ipairs(Schema.validate(Schema.normalize(c))) do
      if i.path == at or i.path:sub(1, #at + 1) == at .. "." then
        out[#out + 1] = i
      end
    end
    return out
  end
  local function one(list)
    return #list == 1 and list[1] or { code = "(" .. #list .. " issues)", message = "" }
  end
  eq(
    "a favourite of a source with a keypad is valid",
    #tuneIssues({ type = "tune", sourceId = "sports-1", favoriteId = "sports-a" }),
    0
  )
  eq("a typed channel is valid", #tuneIssues({ type = "tune", sourceId = "sports-1", channel = "5-1" }), 0)
  eq("...with a dot too", #tuneIssues({ type = "tune", sourceId = "news", channel = "12.3" }), 0)

  local i = one(tuneIssues({ type = "tune", channel = "206" }))
  eq("no source: not set up yet", i.code .. "/" .. tostring(i.severity), "STEP_INCOMPLETE/warning")
  eq("...in words", i.message, "Source is not chosen yet.")
  i = one(tuneIssues({ type = "tune", sourceId = "ghost", channel = "206" }))
  eq("an unknown source", i.code .. "/" .. tostring(i.severity), "REF_UNKNOWN/error")
  eq("...in words", i.message, "Source refers to a source that does not exist.")
  i = one(tuneIssues({ type = "tune", sourceId = "sports-1", channel = "206" }, function(c)
    c.sources[1].enabled = false
  end))
  eq("a disabled source", i.code .. "/" .. tostring(i.severity), "STEP_INVALID/error")
  eq(
    "...in words, naming the scene",
    i.message,
    "Scene 'Game Day' tunes Sports 1, which is switched off (not enabled); switch it on or remove the step."
  )
  i = one(tuneIssues({ type = "tune", sourceId = "streaming", channel = "206" }))
  eq(
    "a source without the number keypad can never be tuned",
    i.code .. "/" .. tostring(i.severity),
    "STEP_INVALID/error"
  )
  eq(
    "...in words",
    i.message,
    "Scene 'Game Day' tunes Streaming, which has no number keypad, so the step can never dial a channel. "
      .. "Give the source the number keypad (Sources > Basic controls) or remove the step."
  )
  local noPad = tuneIssues({ type = "tune", sourceId = "sports-1", favoriteId = "sports-a" }, function(c)
    c.sources[1].controls = { "channel" }
  end)
  eq("...also when the installer later removes the keypad", one(noPad).code, "STEP_INVALID")

  i = one(tuneIssues({ type = "tune", sourceId = "sports-1", favoriteId = "hbo" }))
  eq("an unknown favourite", i.code .. "/" .. tostring(i.severity), "REF_UNKNOWN/error")
  eq(
    "...in words, naming the scene",
    i.message,
    "Scene 'Game Day' tunes Sports 1 to a favourite channel that no longer exists (hbo). "
      .. "Choose another favourite or type the channel number in the step."
  )
  eq(
    "a favourite of another source is unknown here",
    one(tuneIssues({ type = "tune", sourceId = "sports-2", favoriteId = "sports-a" })).code,
    "REF_UNKNOWN"
  )

  for _, bad in ipairs({ "ESPN", "5--1", "-5", "123456789", "2 6", "5;1" }) do
    i = one(tuneIssues({ type = "tune", sourceId = "sports-1", channel = bad }))
    eq("channel '" .. bad .. "' is refused", i.code .. "/" .. tostring(i.severity), "STEP_INVALID/error")
  end
  eq("...in words", i.message, "A channel is digits, with at most one dash or dot (206, 5-1).")
  eq(
    "a channel number (not text) is refused",
    one(tuneIssues({ type = "tune", sourceId = "sports-1", channel = 206 })).code,
    "STEP_INVALID"
  )
  i = one(tuneIssues({ type = "tune", sourceId = "sports-1", favoriteId = "sports-a", channel = "206" }))
  eq("a favourite AND a channel", i.code .. "/" .. tostring(i.severity), "STEP_INVALID/error")
  eq("...in words", i.message, "Choose a favourite channel or type a channel number, not both.")
  i = one(tuneIssues({ type = "tune", sourceId = "sports-1" }))
  eq("neither: not set up yet", i.code .. "/" .. tostring(i.severity), "STEP_INCOMPLETE/warning")
  eq("...in words", i.message, "Channel is not chosen yet: pick a favourite or type a channel number.")
  eq(
    "an empty channel counts as not chosen",
    one(tuneIssues({ type = "tune", sourceId = "sports-1", channel = "" })).code,
    "STEP_INCOMPLETE"
  )

  -- A favourite removed later: the publish is refused, naming who uses it.
  local c = H.Templates.sportsBar()
  table.insert(c.scenes[2].program.steps, { type = "tune", sourceId = "sports-1", favoriteId = "local" })
  c.rules[#c.rules + 1] = {
    id = "lobby-news",
    name = "Lobby news",
    enabled = true,
    trigger = { type = "schedule", days = { 1, 2, 3, 4, 5 }, time = "07:00" },
    program = {
      steps = {
        {
          type = "if",
          condition = { op = "bool", value = true },
          ["then"] = {
            { type = "tune", sourceId = "sports-1", favoriteId = "local" },
          },
        },
      },
    },
  }
  local n = Schema.normalize(c)
  local all = {}
  for _, x in ipairs(Schema.validate(n)) do
    all[#all + 1] = x.id
  end
  check("with the favourite in place it publishes", (Schema.publishable(Schema.validate(n), all)))
  table.remove(c.sources[1].favorites, 3) -- "Local 5"
  local issues = Schema.validate(Schema.normalize(c))
  local ok, blocking = Schema.publishable(issues, all)
  check("removing it: the publish is refused", not ok)
  local names = {}
  for _, b in ipairs(blocking) do
    if b.code == "REF_UNKNOWN" then
      names[#names + 1] = b.message:match("^(%a+ '[^']+')")
    end
  end
  table.sort(names)
  eq(
    "...naming the scene and the schedule that use it",
    table.concat(names, ", "),
    "Scene 'Game Day', Schedule 'Lobby news'"
  )
end

-- ── shade levels (sent to Control4 as SET_LEVEL_TARGET) ─────────────────────
print("shade levels")
do
  local function shadeIssues(open, closed)
    local c = H.Templates.sportsBar()
    c.shades = { { id = "blind", name = "Blind", deviceId = 7101, openLevel = open, closedLevel = closed } }
    local out = {}
    for _, i in ipairs(Schema.validate(Schema.normalize(c))) do
      if i.path:find("^shades%[1%]") then
        out[#out + 1] = i
      end
    end
    return out
  end
  eq("no levels: the defaults (open 100, closed 0) apply, no issue", #shadeIssues(nil, nil), 0)
  eq("both bounds are valid", #shadeIssues(100, 0), 0)
  eq("a level in between is valid", #shadeIssues(80, 15.5), 0)
  for _, case in ipairs({
    { 101, nil, "openLevel", "Open level must be between 0 and 100." },
    { -1, nil, "openLevel", "Open level must be between 0 and 100." },
    { "100", nil, "openLevel", "Open level must be between 0 and 100." },
    { nil, -0.5, "closedLevel", "Closed level must be between 0 and 100." },
    { nil, 100.5, "closedLevel", "Closed level must be between 0 and 100." },
    { nil, true, "closedLevel", "Closed level must be between 0 and 100." },
  }) do
    local list = shadeIssues(case[1], case[2])
    local i = list[1] or {}
    eq(
      tostring(case[1] or case[2]) .. " as " .. case[3] .. " is refused",
      #list .. " " .. tostring(i.code) .. "/" .. tostring(i.severity) .. " " .. tostring(i.path),
      "1 RANGE/error shades[1]." .. case[3]
    )
    eq("...in words", i.message, case[4])
  end
  for _, name in ipairs({ "sportsBar", "conferenceCenter" }) do
    local errors = 0
    for _, i in ipairs(Schema.validate(Schema.normalize(H.Templates[name]()))) do
      if i.severity == "error" then
        errors = errors + 1
      end
    end
    eq("the " .. name .. " sample stays valid", errors, 0)
  end
end

T.done()
