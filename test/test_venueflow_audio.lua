-- VenueFlow audio zones, lighting presets and shades, on the SIMULATOR.
-- Independence of audio from video, volume limits, mute, zone power, source
-- restrictions, coupling detection, and the "commanded, never confirmed"
-- outcome of lighting and shades.
--
-- Simulation-verified only: whether a real installation can play different
-- sources in different zones depends on its audio hardware.
--
-- Run from the driver root: make test

local H = require("venueflow_harness")
local Schema = require("venueflow.schema")
local T = H.checker()
local check, eq = T.check, T.eq

local env = H.new()
env.publishSample("sports_bar")
local manager = env.login("manager", "2580")
local M = { session = manager }

local function zone(id, field)
  return env.cell("zone", id, field)
end

-- ── the owner's example ─────────────────────────────────────────────────────
-- Televisions show different games. The bartender puts Sports 1 audio in the
-- bar. Dining keeps its background music. Patio stays on another source.
print("audio is independent of video")
env.send("AUDIO_SOURCE", { zoneId = "zone-dining", sourceId = "music" }, M)
env.send("AUDIO_SOURCE", { zoneId = "zone-patio", sourceId = "streaming" }, M)
env.send("AUDIO_VOLUME", { zoneId = "zone-dining", level = 35 }, M)
env.settle(2500)
eq("dining plays music", zone("zone-dining", "source").value, "music")
eq("patio plays streaming", zone("zone-patio", "source").value, "streaming")

local before = env.sim():callCount()
local ids = {}
for n = 1, 19 do
  ids[#ids + 1] = string.format("tv-%02d", n)
end
local r = env.send("ROUTE_VIDEO", { sourceId = "sports-1", displayIds = ids }, M)
eq("nineteen displays accepted", r.summary.accepted, 19)
env.settle(6000)
for i = before + 1, env.sim():callCount() do
  local c = env.sim().calls[i]
  check("video route sends only video selections (" .. c.command .. ")", c.command == "SELECT_VIDEO_DEVICE")
  check("video route never targets an audio zone's room", c.target < 1200 or c.target > 1299, c.target)
end
eq("dining still plays music after the video route", zone("zone-dining", "source").value, "music")
eq("dining volume untouched", zone("zone-dining", "volume").value, 35)
eq("patio still plays streaming", zone("zone-patio", "source").value, "streaming")
eq("bar zone was not started by a video route", zone("zone-bar", "source").value, nil)

r = env.send("AUDIO_SOURCE", { zoneId = "zone-bar", sourceId = "sports-1" }, M)
eq("bar audio accepted", r.status, "accepted")
env.settle(1500)
eq(
  "bar plays sports-1",
  zone("zone-bar", "source").value .. "/" .. zone("zone-bar", "source").status,
  "sports-1/confirmed"
)
eq("dining still music", zone("zone-dining", "source").value, "music")
eq("displays keep their picture when audio changes", env.cell("display", "tv-10", "source").value, "sports-1")

-- Audio follows video ONLY when the request names a zone.
before = env.sim():callCount()
r = env.send("ROUTE_VIDEO", { sourceId = "sports-2", displayIds = { "tv-01" }, audioZoneId = "zone-bar" }, M)
check("route + listen: video accepted", r.ok)
check(
  "route + listen: the audio outcome is reported separately",
  r.data.audio.ok == true and r.data.audio.operationId ~= nil
)
env.settle(2000)
eq("the named zone follows", zone("zone-bar", "source").value, "sports-2")
eq("an unnamed zone does not", zone("zone-dining", "source").value, "music")

r = env.send("ROUTE_VIDEO", { sourceId = "signage", displayIds = { "tv-02" }, audioZoneId = "zone-bar" }, M)
check("a source without audio: video still routed", r.ok)
eq("a source without audio: audio refused, and said so", r.data.audio.errorCode, "VF_SOURCE_UNAVAILABLE")
env.settle(1500)
eq("the zone keeps what it had", zone("zone-bar", "source").value, "sports-2")

-- ── volume ──────────────────────────────────────────────────────────────────
print("volume limits")
r = env.send("AUDIO_VOLUME", { zoneId = "zone-bar", level = 65 }, M)
eq("in range: not clamped", r.data.clamped, false)
env.settle(1500)
eq("volume confirmed", zone("zone-bar", "volume").value .. "/" .. zone("zone-bar", "volume").status, "65/confirmed")

r = env.send("AUDIO_VOLUME", { zoneId = "zone-bar", level = 100 }, M)
eq("above the zone maximum: clamped", r.data.clamped, true)
eq("...to the maximum", r.data.level, 85)
env.settle(1500)
eq("the room was sent the clamped level", env.sim().rooms[1201].volume, 85)

r = env.send("AUDIO_VOLUME", { zoneId = "zone-dining", level = 61 }, M)
eq("dining maximum is its own", r.data.level, 60)
r = env.send("AUDIO_VOLUME", { zoneId = "zone-bar", level = -20 }, M)
eq("below the minimum: clamped up", r.data.level, 0)
r = env.send("AUDIO_VOLUME", { zoneId = "zone-bar", level = 44.6 }, M)
eq("levels are whole numbers", r.data.level, 45)
env.settle(2000)

r = env.send("AUDIO_PRESET", { zoneId = "zone-bar", presetId = "game" }, M)
eq("preset sets its level", r.data.level, 70)
r = env.send("AUDIO_PRESET", { zoneId = "zone-bar", presetId = "nope" }, M)
eq("unknown preset", r.errorCode, "VF_NOT_FOUND")
env.settle(1500)

-- ── mute and power ──────────────────────────────────────────────────────────
print("mute and power")
r = env.send("AUDIO_MUTE", { zoneId = "zone-patio", muted = true }, M)
env.settle(1500)
eq("muted confirmed", zone("zone-patio", "mute").value, true)
local state = env.send("GET_STATE", {}, M).data.state
local sawMuteAlert = false
for _, a in ipairs(state.alerts) do
  if a.id == "muted:zone-patio" and a.action.type == "unmute" then
    sawMuteAlert = true
  end
end
check("a muted zone is shown to the manager with an unmute action", sawMuteAlert)
eq("muted count", state.counts.zones.muted, 1)
env.send("AUDIO_MUTE", { zoneId = "zone-patio", muted = false }, M)
env.settle(1500)
eq("unmuted confirmed", zone("zone-patio", "mute").value, false)

r = env.send("AUDIO_POWER", { zoneId = "zone-patio", power = "off" }, M)
env.settle(1500)
eq("zone off confirmed", zone("zone-patio", "power").value, "off")
eq("an off zone has no source", zone("zone-patio", "source").value, nil)
eq("other zones keep playing", zone("zone-dining", "power").value, "on")
r = env.send("AUDIO_POWER", { zoneId = "zone-patio", power = "on" }, M)
eq("a zone starts by being given a source, not by 'on'", r.errorCode, "VF_INVALID_PAYLOAD")

-- ── refusals ────────────────────────────────────────────────────────────────
print("refusals")
eq("unknown zone", env.send("AUDIO_VOLUME", { zoneId = "zone-x", level = 10 }, M).errorCode, "VF_NOT_FOUND")
eq("unknown source", env.send("AUDIO_SOURCE", { zoneId = "zone-bar", sourceId = "x" }, M).errorCode, "VF_NOT_FOUND")

-- A silent amplifier: the change is never confirmed, and is reported as such.
env.sim():setFault(1204, "silent")
env.send("AUDIO_VOLUME", { zoneId = "zone-lounge", level = 50 }, M)
env.settle(7000)
eq("silent zone: failed, not assumed", zone("zone-lounge", "volume").status, "failed")
eq("silent zone: code", zone("zone-lounge", "volume").errorCode, "VF_NOT_CONFIRMED")
env.sim():setFault(1204, nil)

-- ── lighting and shades: commanded, never confirmed ─────────────────────────
print("lighting presets")
r = env.send("LIGHTING_PRESET", { lightingId = "house-lights", presetId = "evening" }, M)
eq("lighting accepted", r.status, "accepted")
env.settle(800)
local cell = env.cell("lighting", "house-lights", "preset")
eq("lighting: commanded", cell.status, "commanded")
eq("lighting: which preset", cell.value, "evening")
local call = env.sim().calls[#env.sim().calls]
eq("lighting: the preset's command", call.command, "ACTIVATE_SCENE")
eq("lighting: the preset's parameter", call.params.SCENE_ID, 12)
eq(
  "unknown preset",
  env.send("LIGHTING_PRESET", { lightingId = "house-lights", presetId = "x" }, M).errorCode,
  "VF_NOT_FOUND"
)

-- ── coupling and shared rooms are caught at validation ──────────────────────
print("validation of shared Control4 rooms")
local c = H.Templates.sportsBar()
c.audioZones[1].c4RoomId = c.displays[1].c4RoomId
local codes = {}
for _, i in ipairs(Schema.validate(c)) do
  codes[i.code] = i.severity
end
eq("a display and a zone in one Control4 room: flagged", codes.AUDIO_COUPLED, "warning")
c = H.Templates.sportsBar()
c.audioZones[2].c4RoomId = c.audioZones[1].c4RoomId
codes = {}
for _, i in ipairs(Schema.validate(c)) do
  codes[i.code] = i.severity
end
eq("two zones in one Control4 room: refused", codes.ZONE_ROOM_SHARED, "error")
c = H.Templates.sportsBar()
c.audioZones[1].minVolume, c.audioZones[1].maxVolume = 70, 30
codes = {}
for _, i in ipairs(Schema.validate(c)) do
  codes[i.code] = i.severity
end
eq("inverted volume limits: refused", codes.RANGE, "error")

-- ── shades (conference centre) ──────────────────────────────────────────────
print("shades")
local conf = H.new()
conf.publishSample("conference_center")
local fm = conf.login("facilities", "2580")
r = conf.send("SHADE", { shadeId = "shades-a", action = "close" }, { session = fm })
eq("shade accepted", r.status, "accepted")
conf.settle(800)
eq("shade: commanded", conf.cell("shade", "shades-a", "position").status, "commanded")
eq("shade: closed", conf.cell("shade", "shades-a", "position").value, "closed")
call = conf.sim().calls[#conf.sim().calls]
eq("shade command", call.command, "SET_LEVEL_TARGET")
eq("shade closed level", call.params.LEVEL_TARGET, 0)
eq(
  "bad shade action",
  conf.send("SHADE", { shadeId = "shades-a", action = "tilt" }, { session = fm }).errorCode,
  "VF_INVALID_PAYLOAD"
)

T.done()
