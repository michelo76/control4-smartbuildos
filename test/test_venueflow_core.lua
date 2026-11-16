-- VenueFlow core, on the SIMULATOR: the two reference venues, All Off and
-- other disruptive actions (confirmation), alerts, installer test actions,
-- device discovery, Composer programming commands, control-mode change, and
-- the diagnostic log (bounded, redacted).
--
-- Run from the driver root: make test

local H = require("venueflow_harness")
local Schema = require("venueflow.schema")
local Diag = require("venueflow.diag")
local Discovery = require("venueflow.discovery")
local T = H.checker()
local check, eq = T.check, T.eq

-- ── the reference venues ────────────────────────────────────────────────────
print("reference sports bar")
local bar = H.Templates.sportsBar(function(pin)
  return "salt", H.hmac("salt", "vf-pin:" .. pin)
end)
eq("24 displays", #bar.displays, 24)
eq("8 video sources and audio", #bar.sources, 8)
eq("4 audio zones", #bar.audioZones, 4)
check("several display groups", #bar.groups >= 4, #bar.groups)
check("several scenes", #bar.scenes >= 4, #bar.scenes)
eq("three staff profiles", #bar.profiles, 3)
local errors, warnings = 0, 0
for _, i in ipairs(Schema.validate(bar)) do
  if i.severity == "error" then
    errors = errors + 1
  else
    warnings = warnings + 1
  end
end
eq("valid: no errors", errors, 0)
eq("one warning (the custom route it deliberately includes)", warnings, 1)
local ids = {}
for _, d in ipairs(bar.displays) do
  check("display id " .. d.id .. " is unique and well formed", ids[d.id] == nil and d.id:match("^tv%-%d%d$") ~= nil)
  ids[d.id] = true
  check(
    d.id .. " has a place on the floor",
    type(d.layout) == "table" and d.layout.x >= 0 and d.layout.x + d.layout.w <= 1200 and d.layout.y + d.layout.h <= 800
  )
end

print("reference conference centre")
local conf = H.Templates.conferenceCenter(function(pin)
  return "salt", H.hmac("salt", "vf-pin:" .. pin)
end)
eq("two floors", #conf.floors, 2)
eq("eight displays", #conf.displays, 8)
eq("lighting and shades present", #conf.lighting + #conf.shades, 2)
eq("a room panel with four buttons", #conf.rooms[1].buttons, 4)
errors = 0
for _, i in ipairs(Schema.validate(conf)) do
  if i.severity == "error" then
    errors = errors + 1
  end
end
eq("valid: no errors", errors, 0)

-- ── the conference room panel, as its own restricted profile ────────────────
print("room panel profile")
local c = H.new()
c.publishSample("conference_center")
local hello = c.send("HELLO", {}, { tile = true })
eq("the meeting-room panel is the tile's profile", hello.data.profile.id, "meeting-room")
eq("it sees its room only", #hello.data.config.rooms, 1)
eq("...with its four buttons", #hello.data.config.rooms[1].buttons, 4)
eq("...and only that room's displays", #hello.data.config.displays, 2)
eq("its only interface is Room Control", hello.data.profile.interfaces[1], "room")
local r = c.send("SCENE_ACTIVATE", { sceneId = "a-present", areaId = "boardroom-a" }, { tile = true })
check("Present Laptop accepted", r.ok)
c.settle(6000)
eq("laptop on the main display", c.cell("display", "a-main", "source").value, "laptop-a")
eq("laptop on the side display", c.cell("display", "a-side", "source").value, "laptop-a")
eq("room audio on the laptop", c.cell("zone", "audio-a", "source").value, "laptop-a")
eq("presentation lighting commanded", c.cell("lighting", "lights-a", "preset").value, "presentation")
eq("shades commanded closed", c.cell("shade", "shades-a", "position").value, "closed")
eq("the other boardroom is untouched", c.cell("display", "b-main", "source").value, nil)
eq(
  "a scene of another room is refused",
  c.send("SCENE_ACTIVATE", { sceneId = "closing", confirm = true }, { tile = true }).errorCode,
  "VF_FORBIDDEN"
)
r = c.send("SCENE_ACTIVATE", { sceneId = "a-off" }, { tile = true })
c.settle(6000)
eq("Room Off: displays off", c.cell("display", "a-main", "power").value, "off")
eq("Room Off: audio off", c.cell("zone", "audio-a", "power").value, "off")

-- ── All Off and other disruptive actions ────────────────────────────────────
print("disruptive actions need confirmation")
local env = H.new()
local studio = env.publishSample("sports_bar")
local S = { session = studio }
local m = env.login("manager", "2580")
local M = { session = m }
env.send("VENUE_STATUS", { status = "open" }, M)
env.send("SCENE_ACTIVATE", { sceneId = "game-day" }, M)
env.settle(9000)

local calls = env.sim():callCount()
r = env.send("ALL_OFF", {}, M)
eq("All Off without confirm", r.errorCode, "VF_CONFIRM_REQUIRED")
eq("...sends nothing", env.sim():callCount(), calls)
r = env.send("ALL_OFF_PREVIEW", {}, M)
eq("the preview counts the displays", r.data.displays, 24)
eq("...and the zones", r.data.zones, 4)
eq("...and names the active scene", r.data.activeScene, "Game Day")
eq("the preview sends nothing", env.sim():callCount(), calls)
r = env.send("ALL_OFF", { confirm = true }, M)
check("All Off accepted", r.ok)
eq("28 targets", #r.results, 28)
env.settle(8000)
local on = 0
for _, d in ipairs(env.core.config.displays) do
  if env.cell("display", d.id, "power").value == "on" then
    on = on + 1
  end
end
eq("no display is left on", on, 0)
eq("zones are off", env.cell("zone", "zone-bar", "power").value, "off")
eq("the active scene is cleared", env.core.runtime.activeScene, nil)

r = env.send("SCENE_ACTIVATE", { sceneId = "closing" }, M)
eq("a scene marked 'confirm' asks first", r.errorCode, "VF_CONFIRM_REQUIRED")
eq("...and shows what it would do", #r.data.preview.steps, 7)
eq("...as a plan", r.data.preview.steps[1].status, "planned")
eq("the venue is still open", env.core.runtime.venueStatus, "open")
r = env.send("SCENE_ACTIVATE", { sceneId = "closing", confirm = true }, M)
check("confirmed: it runs", r.ok)
env.settle(8000)
eq("the venue is closed", env.core.runtime.venueStatus, "closed")
check(
  "Composer events for open and close fired",
  table.concat(env.events, ","):find("venue_open", 1, true)
    and table.concat(env.events, ","):find("venue_closed", 1, true)
)
eq("Composer variable VENUE_STATUS", env.variables.VENUE_STATUS, "closed")

-- ── alerts ──────────────────────────────────────────────────────────────────
print("alerts")
env.send("VENUE_STATUS", { status = "open" }, M)
env.sim():setFault(1109, "silent")
env.send("ROUTE_VIDEO", { sourceId = "sports-1", displayIds = { "tv-09" } }, M)
env.settle(7000)
local state = env.send("GET_STATE", {}, M).data.state
local alert
for _, a in ipairs(state.alerts) do
  if a.id == "cell:tv-09:source" then
    alert = a
  end
end
check("a display that did not confirm is an alert", alert ~= nil)
eq("...in plain words", alert.title, "TV 09: source change not confirmed")
eq("...with a way to resolve it", alert.action.type, "query")
check("attention count includes it", state.counts.displays.attention >= 1)
env.sim():setFault(1109, nil)
env.send("QUERY_STATUS", { displayIds = alert.action.displayIds }, M)
state = env.send("GET_STATE", {}, M).data.state
local still = false
for _, a in ipairs(state.alerts) do
  if a.id == "cell:tv-09:source" then
    still = true
  end
end
check("Resolve clears it once Control4 reports a real state", not still)

env.sim():setFault(2110, "offline")
env.core:_checkOnline()
state = env.send("GET_STATE", {}, M).data.state
eq("an offline display is reported offline", state.displays["tv-10"].online, false)
eq("offline count", state.counts.displays.offline, 1)
local offline = false
for _, a in ipairs(state.alerts) do
  if a.id == "offline:tv-10" then
    offline = true
  end
end
check("...and alerted", offline)
env.sim():setFault(2110, nil)
env.core:_checkOnline()
eq("back online", env.send("GET_STATE", {}, M).data.state.displays["tv-10"].online, true)

env.send(
  "PROGRAM_EXECUTE",
  { confirm = true, program = { steps = { { type = "notify", message = "Keg change needed", level = "warning" } } } },
  S
)
state = env.send("GET_STATE", {}, M).data.state
local note
for _, a in ipairs(state.alerts) do
  if a.title == "Keg change needed" then
    note = a
  end
end
check("a notification is an alert the manager can dismiss", note ~= nil and note.dismissable == true)
check("dismissed", env.send("ALERT_DISMISS", { alertId = note.id }, M).ok)
eq(
  "a derived alert cannot be dismissed (it clears with its cause)",
  env.send("ALERT_DISMISS", { alertId = "offline:tv-10" }, M).errorCode,
  "VF_NOT_FOUND"
)

-- ── installer test actions (act on the DRAFT mapping) ───────────────────────
print("installer test actions")
r = env.send("TEST_DEVICE", { test = "status", displayId = "tv-01" }, S)
check("status needs no confirmation and reads the room", r.ok and r.data.readable == true and r.data.roomId == 1101)
eq("status reports link state", r.data.online, true)
calls = env.sim():callCount()
r = env.send("TEST_DEVICE", { test = "route", displayId = "tv-01", sourceId = "sports-2" }, S)
eq("a route test asks first", r.errorCode, "VF_CONFIRM_REQUIRED")
eq("...and sends nothing", env.sim():callCount(), calls)
r = env.send("TEST_DEVICE", { test = "route", displayId = "tv-01", sourceId = "sports-2", confirm = true }, S)
check("confirmed: sent", r.ok and r.status == "accepted")
eq("waiting for read-back", env.send("TEST_RESULT", { testId = r.data.testId }, S).data.status, "waiting")
env.settle(5000)
local result = env.send("TEST_RESULT", { testId = r.data.testId }, S).data
eq("read-back confirms", result.status, "confirmed")
eq("...with the room values", result.room.videoDevice, 3002)

env.sim():setFault(1102, "silent")
r = env.send("TEST_DEVICE", { test = "route", displayId = "tv-02", sourceId = "sports-2", confirm = true }, S)
env.settle(5000)
eq(
  "a test on a silent display is NOT reported as passed",
  env.send("TEST_RESULT", { testId = r.data.testId }, S).data.status,
  "not_confirmed"
)
env.sim():setFault(1102, nil)

r = env.send("TEST_DEVICE", { test = "power_off", displayId = "tv-01", confirm = true }, S)
env.settle(5000)
eq("power test read-back", env.send("TEST_RESULT", { testId = r.data.testId }, S).data.status, "confirmed")
r = env.send("TEST_DEVICE", { test = "route", displayId = "tv-24", sourceId = "sports-1", confirm = true }, S)
eq("a custom-command route cannot be read back, and says so", r.data.status, "sent_no_feedback")
r = env.send("TEST_DEVICE", { test = "source", zoneId = "zone-bar", sourceId = "music", confirm = true }, S)
env.settle(5000)
eq("zone source test", env.send("TEST_RESULT", { testId = r.data.testId }, S).data.status, "confirmed")
eq("nothing chosen", env.send("TEST_DEVICE", { test = "status" }, S).errorCode, "VF_NOT_FOUND")
eq(
  "a test on a display mapped only in the draft works before publishing",
  (function()
    local draft = env.send("DRAFT_GET", {}, S).data.draft
    draft.config.displays[#draft.config.displays + 1] =
      { id = "tv-new", name = "New TV", floorId = "main-floor", c4RoomId = 1101, route = { strategy = "room" } }
    env.send("DRAFT_SAVE", { config = draft.config, baseRevision = draft.revision }, S)
    return env.send("TEST_DEVICE", { test = "status", displayId = "tv-new" }, S).data.readable
  end)(),
  true
)
eq(
  "tests are in diagnostics",
  (function()
    for _, e in ipairs(env.core.diag:list({ limit = 80, category = "mapping" })) do
      if e.message:find("Test route on TV 02: not_confirmed", 1, true) then
        return true
      end
    end
    return false
  end)(),
  true
)

-- A test on a room already in the requested state says it changes nothing.
r = env.send("TEST_DEVICE", { test = "route", displayId = "tv-01", sourceId = "sports-2", confirm = true }, S)
env.settle(5000)
r = env.send("TEST_DEVICE", { test = "route", displayId = "tv-01", sourceId = "sports-2", confirm = true }, S)
env.settle(5000)
result = env.send("TEST_RESULT", { testId = r.data.testId }, S).data
eq("a test that changes nothing says so", result.changes, false)
check("...and carries what the room said before", type(result.before) == "table" and result.before.videoDevice == 3002)

-- ── discovery ───────────────────────────────────────────────────────────────
print("device discovery")
r = env.send("DISCOVER", {}, S)
check("discovery lists the simulated project", r.ok and #r.data.devices > 40, #r.data.devices)
eq("rooms are recognised", r.data.counts.room, 27) -- 23 display rooms + 4 zone rooms
eq("displays are recognised", r.data.counts.display, 24)
eq("sources are recognised", r.data.counts.source, 8)
check(
  "a room records what its variables show",
  r.data.rooms[1].capabilities.readable == true and r.data.rooms[1].capabilities.volume == true
)
-- classification on what a real GetDevices answer could look like
local function classify(d)
  return (Discovery.classify(d))
end
eq("by proxy: tv", classify({ proxies = { "tv" }, driverFile = "anything.c4z" }), "display")
eq("by proxy: avswitch", classify({ proxies = { "avswitch" } }), "video_switch")
eq("by proxy: blind", classify({ proxies = { "blind" } }), "shade")
eq("by proxy: light_v2", classify({ proxies = { "light_v2" } }), "light")
eq("by file name: room", classify({ driverFile = "roomdevice.c4i" }), "room")
eq("by file name: matrix", classify({ driverFile = "hdmi_matrix_8x8.c4z" }), "video_switch")
eq("by file name: AV over IP", classify({ driverFile = "control4_moip_tx.c4z" }), "av_over_ip")
eq("by file name: amplifier", classify({ driverFile = "triad_amplifier.c4z" }), "amplifier")
eq("unknown stays 'other', never guessed", classify({ driverFile = "mystery.c4z" }), "other")
eq("the basis is reported", select(2, Discovery.classify({ driverFile = "mystery.c4z" })), "none")
eq(
  "a broken adapter is an error, not a crash",
  Discovery.scan({
    listDevices = function()
      error("x")
    end,
  }).error,
  "device list unavailable"
)

-- Before anything is published, Simulation offers a made-up project to map.
do
  local fresh = H.new()
  local fs = { session = fresh.studio() }
  local scan = fresh.send("DISCOVER", {}, fs)
  check(
    "an unpublished venue in Simulation still has devices to discover",
    scan.ok and scan.data.counts.room == 10 and scan.data.counts.display == 8 and scan.data.counts.source == 4
  )
  fresh.send("TEMPLATE_APPLY", { venueType = "restaurant", name = "Rehearsal" }, fs)
  local draft = fresh.send("DRAFT_GET", {}, fs).data.draft
  draft.config.displays[1] = { id = "d1", name = "D1", floorId = "main-floor", c4RoomId = 1101, c4DeviceId = 2101 }
  draft.config.sources[1] = { id = "s1", name = "S1", c4DeviceId = 3001 }
  fresh.send("DRAFT_SAVE", { config = draft.config, baseRevision = draft.revision }, fs)
  eq(
    "a draft mapping can be read back before publishing",
    fresh.send("TEST_DEVICE", { test = "status", displayId = "d1" }, fs).data.readable,
    true
  )
  local t = fresh.send("TEST_DEVICE", { test = "route", displayId = "d1", sourceId = "s1", confirm = true }, fs)
  fresh.settle(5000)
  eq("...and test-routed", fresh.send("TEST_RESULT", { testId = t.data.testId }, fs).data.status, "confirmed")
  fresh.send("SIM_FAULT", { targetId = 1101, fault = "silent" }, fs)
  eq(
    "the Studio can read the simulator's current faults",
    fresh.send("DIAG_GET", {}, fs).data.simFaults["1101"] or fresh.send("DIAG_GET", {}, fs).data.simFaults[1101],
    "silent"
  )
end

-- ── Composer programming ────────────────────────────────────────────────────
print("Composer commands")
local ok, msg = env.core:composer("ACTIVATE_SCENE", { SCENE = "game day" })
check("scene by name, case-blind", ok, msg)
env.settle(8000)
eq("it ran", env.core.runtime.activeScene.id, "game-day")
eq("scene by id", env.core:composer("ACTIVATE_SCENE", { SCENE = "happy-hour" }), true)
env.settle(6000)
eq("unknown scene", env.core:composer("ACTIVATE_SCENE", { SCENE = "Brunch" }), false)
eq("venue status", env.core:composer("SET_VENUE_STATUS", { STATUS = "Closed" }), true)
eq("...applied", env.core.runtime.venueStatus, "closed")
eq(
  "a scene whose condition is not met reports refusal",
  env.core:composer("ACTIVATE_SCENE", { SCENE = "Game Day" }),
  false
)
eq("route to a group", env.core:composer("ROUTE_SOURCE", { SOURCE = "Cable News", TARGET = "Dining Wall" }), true)
env.settle(5000)
eq("...routed", env.cell("display", "tv-12", "source").value, "news")
eq("route to one display", env.core:composer("ROUTE_SOURCE", { SOURCE = "sports-4", TARGET = "TV 12" }), true)
eq("route to nothing known", env.core:composer("ROUTE_SOURCE", { SOURCE = "sports-4", TARGET = "Roof" }), false)
eq("All Off", env.core:composer("ALL_OFF", {}), true)
eq("unknown command", env.core:composer("SELF_DESTRUCT", {}), false)
env.settle(8000)

-- ── summary for the property page ───────────────────────────────────────────
-- What the pages need to know about the published version and running scenes.
do
  local st = env.send("GET_STATE", {}, S).data.state
  check(
    "the state names the published version",
    type(st.configVersion) == "string" and st.configVersion == env.core.publishedMeta.versionId
  )
  local hello = env.send("HELLO", {}, S).data
  eq("an installer session gets a full profile shape", #hello.profile.interfaces, 4)
  check("...with every permission", hello.profile.can.allOff == true and hello.profile.system == true)
  local d = env.send("DRAFT_GET", {}, S).data.draft
  eq("the draft says whether it equals what is published", type(d.matchesPublished), "boolean")
end

local summary = env.core:summary()
eq("summary names the venue", summary.venue, "Riverside Sports Bar")
check("summary names the version and counts", summary.configuration:find("24 displays", 1, true) ~= nil)
eq("summary names the mode", summary.mode, "Simulation")

-- ── control mode ────────────────────────────────────────────────────────────
print("control mode")
local live = { calls = {} }
local liveEnv = H.new({
  liveAdapter = function()
    return {
      simulation = false,
      selectVideo = function(room, dev)
        live.calls[#live.calls + 1] = { "SELECT_VIDEO_DEVICE", room, dev }
        return true
      end,
      selectAudio = function()
        return true
      end,
      roomOff = function()
        return true
      end,
      setVolume = function()
        return true
      end,
      setMute = function()
        return true
      end,
      devicePower = function()
        return true
      end,
      deviceCommand = function()
        return true
      end,
      readRoom = function()
        return nil
      end,
      watchRooms = function(rooms)
        live.watched = #rooms
      end,
      deviceOnline = function()
        return nil
      end,
      readVariable = function()
        return nil
      end,
      watchVariable = function()
        return false, "variable not found"
      end,
      unwatchVariables = function() end,
      listDevices = function()
        return {}
      end,
      timeZone = function()
        return "America/New_York"
      end,
    }
  end,
})
local st = liveEnv.publishSample("sports_bar")
eq("in Simulation nothing reaches the live adapter", #live.calls, 0)
liveEnv.send("ROUTE_VIDEO", { sourceId = "sports-1", displayIds = { "tv-01" } }, { session = st })
liveEnv.settle(1000)
eq("still nothing", #live.calls, 0)
liveEnv.mode = "live"
liveEnv.core:modeChanged()
eq("a sample venue (invented Control4 ids) is not run in Live mode", liveEnv.core.config, nil)
eq("...and nothing was sent", #live.calls, 0)
eq(
  "...the operator page says the venue is not set up",
  liveEnv.send("GET_STATE", {}, { session = st }).errorCode,
  "VF_NO_PUBLISHED_CONFIG"
)
check("...and the property summary says why", liveEnv.core:summary().configuration:find("Sample venue", 1, true) ~= nil)
-- The installer builds the real venue: same shape here, no longer marked a sample.
do
  local draft = liveEnv.send("DRAFT_GET", {}, { session = st }).data.draft
  draft.config.venue.sample = nil
  check(
    "real venue saved",
    liveEnv.send("DRAFT_SAVE", { config = draft.config, baseRevision = draft.revision }, { session = st }).ok
  )
  local acks = {}
  for _, i in ipairs(liveEnv.send("DRAFT_GET", {}, { session = st }).data.draft.issues) do
    acks[#acks + 1] = i.id
  end
  check("real venue published in Live", liveEnv.send("PUBLISH", { acknowledged = acks }, { session = st }).ok)
end
eq("Live: the mapped rooms are watched", live.watched, 27)
eq(
  "Live: state starts unknown (the fake Control4 cannot be read)",
  liveEnv.cell("display", "tv-01", "source").status,
  "unknown"
)
liveEnv.send("ROUTE_VIDEO", { sourceId = "sports-1", displayIds = { "tv-01" } }, { session = st })
liveEnv.settle(500)
eq(
  "Live: the command goes to the Control4 adapter",
  live.calls[1][1] .. " " .. live.calls[1][2] .. " " .. live.calls[1][3],
  "SELECT_VIDEO_DEVICE 1101 3001"
)
liveEnv.settle(7000)
eq(
  "Live with no readable feedback: unknown, never assumed",
  liveEnv.cell("display", "tv-01", "source").status,
  "unknown"
)
eq("...with what was asked kept", liveEnv.cell("display", "tv-01", "source").requested, "sports-1")
eq(
  "sample venues are refused in Live",
  liveEnv.send("TEMPLATE_APPLY", { venueType = "sports_bar", sample = true, confirm = true }, { session = st }).errorCode,
  "VF_SIMULATION_ONLY"
)
eq(
  "simulator faults are refused in Live",
  liveEnv.send("SIM_FAULT", { targetId = 1101, fault = "offline" }, { session = st }).errorCode,
  "VF_SIMULATION_ONLY"
)
eq(
  "the Studio shows the controller's time zone",
  liveEnv.send("STUDIO_BOOTSTRAP", {}, { session = st }).data.controller.timeZone,
  "America/New_York"
)

-- ── the diagnostic log ──────────────────────────────────────────────────────
print("diagnostic log")
local d = Diag.new({
  now = function()
    return 1
  end,
  max = 50,
})
for i = 1, 500 do
  d:add("info", "command", nil, "entry " .. i)
end
eq("the log is bounded", d:size(), 50)
eq("the oldest entries are dropped", d:list({ limit = 50 })[50].message, "entry 451")
eq("newest first", d:list({ limit = 1 })[1].message, "entry 500")
eq("counts keep the total", d.counts.info, 500)
d:add("error", "auth", "VF_BAD_PIN", "sign-in", {
  pin = "2580",
  PIN = "2580",
  passcode = "install-123",
  session = "abcdef",
  sessionToken = "abcdef",
  apiKey = "k",
  pinHash = "h",
  nested = { password = "p", ok = "visible" },
  client = "10.0.0.5",
  dataUrl = "data:image/png;base64," .. string.rep("A", 5000),
})
local entry = d:list({ limit = 1 })[1]
local text = H.JSON:encode(entry)
check(
  "secret-named values are hidden",
  not text:find("2580", 1, true) and not text:find("install-123", 1, true) and not text:find("abcdef", 1, true)
)
eq("...replaced, not dropped", entry.data.pin, "<hidden>")
eq("nested secrets too", entry.data.nested.password, "<hidden>")
eq("ordinary values are kept", entry.data.nested.ok .. "/" .. entry.data.client, "visible/10.0.0.5")
check("long values are cut", #entry.data.dataUrl < 100)
eq("filter by level", #d:list({ level = "error" }), 1)
eq("filter by category", #d:list({ category = "auth" }), 1)
eq(
  "a long message is cut to one line",
  #d:add("info", "driver", nil, string.rep("x", 900) .. "\nsecond line").message,
  300
)
eq("an unknown level becomes info", d:add("shout", "driver", nil, "x").level, "info")

-- nothing secret in the live log after everything above
local dump = H.JSON:encode(env.core.diag:list({ limit = 400 }))
check("no PIN in the driver log", not dump:find("2580", 1, true))
check("no passcode in the driver log", not dump:find(env.passcode, 1, true))
check("no session token in the driver log", not dump:find(m, 1, true) and not dump:find(studio, 1, true))
r = env.send("DIAG_GET", { limit = 5, level = "warning" }, S)
check("DIAG_GET filters", #r.data.entries <= 5 and r.data.max == 400)
check("DIAG_CLEAR", env.send("DIAG_CLEAR", {}, S).ok and env.core.diag:size() == 1)

-- ── a publish in Simulation keeps what the simulated devices were doing ─────
-- (Found on the bench, 14 November 2026: every display went back to Off after
-- a publish while the Active Scene label stayed.)
print("publish keeps simulated device state")
do
  local e = H.new()
  local st = e.publishSample("sports_bar")
  local mgr = e.login("manager", "2580")
  check(
    "route two displays",
    e.send("ROUTE_VIDEO", { sourceId = "sports-1", displayIds = { "tv-01", "tv-02" } }, { session = mgr }).ok
  )
  check("set a zone's volume", e.send("AUDIO_VOLUME", { zoneId = "zone-bar", level = 42 }, { session = mgr }).ok)
  e.settle(3000)
  eq("before: the display shows the source", e.cell("display", "tv-01", "source").value, "sports-1")
  eq("before: the zone is at 42", e.cell("zone", "zone-bar", "volume").value, 42)
  local oldSim = e.sim()
  local draft = e.send("DRAFT_GET", {}, { session = st }).data.draft
  draft.config.venue.name = "Renamed"
  local saved = e.send("DRAFT_SAVE", { baseRevision = draft.revision, config = draft.config }, { session = st })
  check("a draft change saves", saved.ok, saved.errorCode)
  local acks = {}
  for _, i in ipairs(saved.data.issues or {}) do
    acks[#acks + 1] = i.id
  end
  check("...and publishes", e.send("PUBLISH", { acknowledged = acks }, { session = st }).ok)
  e.settle(1000)
  check("the simulator was rebuilt", e.sim() ~= oldSim)
  eq("after: the display still shows the source", e.cell("display", "tv-01", "source").value, "sports-1")
  eq("after: ...and is still on", e.cell("display", "tv-01", "power").value, "on")
  eq("after: the zone is still at 42", e.cell("zone", "zone-bar", "volume").value, 42)
  eq("after: an untouched display is still off", e.cell("display", "tv-09", "power").value, "off")
end

T.done()
