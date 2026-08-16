-- Room activity tracking.
--
-- Every rule in this module decides a number a client will eventually be shown
-- in a report. A mistake here does not crash — it produces a plausible, wrong
-- figure that nobody can trace back to a bug. So the boundaries are tested
-- against a clock the test drives by hand rather than against wall time.
--
-- Run from the driver root:
--   make test

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

package.path = "./src/?.lua;./src/?/init.lua;" .. package.path
local Rooms = require("telemetry.rooms")

--- Monotonic and wall clocks the test advances explicitly, so a duration
--- assertion is exact rather than dependent on how fast the machine runs.
local function tracker()
  local clock = { ms = 0 }
  local t = Rooms.new(function()
    return clock.ms
  end, function()
    return string.format(
      "2026-08-16T%02d:%02d:%02dZ",
      math.floor(clock.ms / 3600000) % 24,
      math.floor(clock.ms / 60000) % 60,
      math.floor(clock.ms / 1000) % 60
    )
  end)
  return t, clock
end

print("\n[1] A session is a room being on")

local t, clock = tracker()
t:apply(16, "Living Room", "POWER_STATE", "1")
check("no session is complete while the room is still on", #t.completed == 0)
clock.ms = 30 * 60 * 1000
t:apply(16, nil, "POWER_STATE", "0")
check("powering off completes one session", #t.completed == 1, #t.completed)
check("its duration is measured, not guessed", t.completed[1].duration_seconds == 1800, t.completed[1].duration_seconds)
check("it carries the room name", t.completed[1].room_name == "Living Room")

print("\n[2] A source change splits the session")

-- Otherwise an evening of "Apple TV then Netflix" is one undifferentiated block
-- and the "what you watched" breakdown has nothing to work with.
t, clock = tracker()
t:apply(16, "Living Room", "POWER_STATE", "1")
t:apply(16, nil, "CURRENT_SELECTED_DEVICE", "100")
clock.ms = 60 * 60 * 1000
t:apply(16, nil, "CURRENT_SELECTED_DEVICE", "200")
check("changing source closes the first span", #t.completed == 1, #t.completed)
check(
  "the first span records the first source",
  t.completed[1].source_device_id == 100,
  t.completed[1].source_device_id
)
clock.ms = clock.ms + 30 * 60 * 1000
t:apply(16, nil, "POWER_STATE", "0")
check("the second span closes on power off", #t.completed == 2, #t.completed)
check("and records the second source", t.completed[2].source_device_id == 200)
check("with its own duration", t.completed[2].duration_seconds == 1800, t.completed[2].duration_seconds)

print("\n[3] A track change does not split the session")

-- A new song is not a new viewing. The session keeps what was playing when it
-- began; the current track lives in state.
t, clock = tracker()
t:apply(16, "Living Room", "POWER_STATE", "1")
t:apply(16, nil, "CURRENT MEDIA INFO", "Celine Dion - All By Myself")
clock.ms = 10 * 60 * 1000
t:apply(16, nil, "CURRENT MEDIA INFO", "Fleetwood Mac - Dreams")
check("still one open session", #t.completed == 0, #t.completed)
local state = t:snapshot()[1]
check("state shows the CURRENT track", state.media_title == "Dreams", state.media_title)
check("and the current artist", state.media_artist == "Fleetwood Mac", state.media_artist)

print("\n[4a] The real XML format, measured on hardware")

-- Verbatim shape from a live system. The album contains " - ", which the old
-- hyphen heuristic would have read as an artist separator — the exact silent
-- mislabelling it was written to avoid.
local XML = "<mediainfo><roomId>16</roomId><mediatype>SONG</mediatype>"
  .. "<artist>Joseph Zenny Jr</artist><album>Mpap Pale - Single</album>"
  .. "<title>Mpap Pale</title></mediainfo>"

local xTitle, xArtist, xType, xAlbum = Rooms.parseMedia(XML)
check("artist comes from its own tag", xArtist == "Joseph Zenny Jr", xArtist)
check("title comes from its own tag", xTitle == "Mpap Pale", xTitle)
check("the album is kept whole despite containing ' - '", xAlbum == "Mpap Pale - Single", xAlbum)
check("media type is normalised", xType == "song", xType)

-- Verbatim from the live system: <img> is a BASE64 artwork URL and <deviceid>
-- names the source, which matters because CURRENT_SELECTED_DEVICE reads 0 for a
-- room playing music.
local REAL = "<mediainfo><roomId>16</roomId><mediatype>SONG</mediatype><artist>Gabel</artist>"
  .. "<album>BeNi</album><title>Beni</title>"
  .. "<img>aHR0cDovLzE5Mi4xNjguMS4xMDM6MTQwMC9nZXRhYT9zPTE=</img>"
  .. "<deviceid>83</deviceid></mediainfo>"
local rTitle, rArtist, rType, rAlbum, rImage, rDevice = Rooms.parseMedia(REAL)
check("title from a real record", rTitle == "Beni", rTitle)
check("artist from a real record", rArtist == "Gabel", rArtist)
check("album from a real record", rAlbum == "BeNi", rAlbum)
check("artwork is decoded from base64, not stored encoded", rImage == "http://192.168.1.103:1400/getaa?s=1", rImage)
check("the source device comes from the record", rDevice == 83, rDevice)

-- Not every <img> will be base64; keeping the original beats emitting mojibake.
check(
  "a non-base64 image value is kept as-is",
  select(5, Rooms.parseMedia("<mediainfo><title>x</title><img>http://plain/url.jpg</img></mediainfo>"))
    == "http://plain/url.jpg"
)

-- CURRENT_MEDIA reports this WHILE a song is playing. It must not be mistaken
-- for real metadata, or it wipes what CURRENT MEDIA INFO just set.
local eTitle, eArtist = Rooms.parseMedia("<mediainfo><mediaid>0</mediaid><mediatype/></mediainfo>")
check("an empty shell yields nothing", eTitle == nil and eArtist == nil, tostring(eTitle))

-- MEDIA WALL INFO nests a whole mediainfo inside wallmediainfo. A greedy match
-- would span from the outer tag to the inner close and capture rubbish.
local wTitle, wArtist = Rooms.parseMedia(
  "<wallmediainfo><notifyDevId>83</notifyDevId><mediainfo><roomId>16</roomId>"
    .. "<mediatype>SONG</mediatype><artist>Joseph Zenny Jr</artist></mediainfo></wallmediainfo>"
)
check("nested media wall info still yields the artist", wArtist == "Joseph Zenny Jr", wArtist)

check("an empty wall record yields nothing", (Rooms.parseMedia("<wallmediainfo/>")) == nil)

print("\n[4] Plain-text media is still parsed conservatively")

-- These are not a schema we control: different sources write different things.
-- Guessing a split wrongly mislabels an artist, which is worse than not
-- splitting at all.
local title, artist = Rooms.parseMedia("Celine Dion - All By Myself")
check(
  "a spaced hyphen splits artist and title",
  title == "All By Myself" and artist == "Celine Dion",
  tostring(artist) .. " / " .. tostring(title)
)

title, artist = Rooms.parseMedia("Spider-Man")
check("an unspaced hyphen is not a separator", title == "Spider-Man" and artist == nil, tostring(title))

title, artist = Rooms.parseMedia("The Bear")
check("a plain title stays whole", title == "The Bear" and artist == nil)

title, artist = Rooms.parseMedia("")
check("an empty string yields nothing", title == nil and artist == nil)

title, artist = Rooms.parseMedia(nil)
check("nil yields nothing", title == nil and artist == nil)

print("\n[5] A room that is off is not playing anything")

-- Leaving stale media on the record makes the client app claim a dark room is
-- playing music.
t, clock = tracker()
t:apply(16, "Living Room", "POWER_STATE", "1")
t:apply(16, nil, "CURRENT MEDIA INFO", "Celine Dion - All By Myself")
t:apply(16, nil, "CURRENT_SELECTED_DEVICE", "100")
clock.ms = 60000
t:apply(16, nil, "POWER_STATE", "0")
state = t:snapshot()[1]
check("media is cleared on power off", state.media_title == nil, state.media_title)
check("source is cleared on power off", state.source_device_id == nil)
check("and the room reads as off", state.powered == false)

print("\n[6] A flicker is not an activity")

-- A sub-second bounce would otherwise pad the session count with noise.
t, clock = tracker()
t:apply(16, "Living Room", "POWER_STATE", "1")
clock.ms = 300
t:apply(16, nil, "POWER_STATE", "0")
check("a 300ms bounce records no session", #t.completed == 0, #t.completed)

print("\n[7] All three spellings of boolean")

t = tracker()
t:apply(16, "R", "POWER_STATE", "true")
check("'true' powers a room on", t:snapshot()[1].powered == true)
t:apply(17, "R2", "POWER_STATE", "1")
check("'1' powers a room on", t.rooms[17].powered == true)
t:apply(18, "R3", "POWER_STATE", "0")
check("'0' leaves it off", t.rooms[18].powered == false)

print("\n[8] Device id 0 means nothing selected")

t = tracker()
t:apply(16, "R", "POWER_STATE", "1")
t:apply(16, nil, "CURRENT_SELECTED_DEVICE", "0")
check("source 0 is treated as no source", t:snapshot()[1].source_device_id == nil)

print("\n[9] Rooms are independent")

t, clock = tracker()
t:apply(16, "Living Room", "POWER_STATE", "1")
t:apply(222, "Kitchen", "POWER_STATE", "1")
clock.ms = 60000
t:apply(16, nil, "POWER_STATE", "0")
check("closing one room does not close the other", #t.completed == 1, #t.completed)
check("the other room is still on", t.rooms[222].powered == true)

print("\n[10] Sessions are taken, not read")

-- An upload that succeeded must not be able to send the same span twice.
t, clock = tracker()
t:apply(16, "R", "POWER_STATE", "1")
clock.ms = 60000
t:apply(16, nil, "POWER_STATE", "0")
local taken = t:takeSessions()
check("taking returns the queued spans", #taken == 1)
check("and empties the queue", #t:takeSessions() == 0)

t:returnSessions(taken)
check("a failed upload can put them back", #t.completed == 1)

print("\n[11] The queue is bounded")

-- A controller that cannot reach the platform for a day must not accumulate
-- until it runs out of memory.
t, clock = tracker()
t.maxCompleted = 3
for i = 1, 6 do
  clock.ms = i * 100000
  t:apply(16, "R", "POWER_STATE", "1")
  clock.ms = clock.ms + 60000
  t:apply(16, nil, "POWER_STATE", "0")
end
check("never grows past the cap", #t.completed == 3, #t.completed)
check("and counts what was dropped rather than hiding it", t.dropped == 3, t.dropped)

print("\n[12] Shutdown closes open sessions")

-- Otherwise an evening's viewing is lost because the driver reloaded at 11pm.
t, clock = tracker()
t:apply(16, "R", "POWER_STATE", "1")
clock.ms = 45 * 60 * 1000
t:closeAll()
check("an open session is closed and kept", #t.completed == 1, #t.completed)
check("with the duration up to that moment", t.completed[1].duration_seconds == 2700)

print("\n[12a] An empty media payload does not wipe what another variable set")

-- CURRENT_MEDIA and CURRENT MEDIA INFO arrive as separate changes, and the
-- former is an empty shell while the latter carries the record.
t = tracker()
t:apply(16, "R", "POWER_STATE", "1")
t:apply(
  16,
  nil,
  "CURRENT MEDIA INFO",
  "<mediainfo><mediatype>SONG</mediatype><artist>Joseph Zenny Jr</artist><title>Mpap Pale</title></mediainfo>"
)
t:apply(16, nil, "CURRENT_MEDIA", "<mediainfo><mediaid>0</mediaid><mediatype/></mediainfo>")
state = t:snapshot()[1]
check("the real record survives the empty one", state.media_artist == "Joseph Zenny Jr", state.media_artist)
check("and so does the title", state.media_title == "Mpap Pale", state.media_title)

print("\n[12b] The media record supplies the source when the room variable does not")

t = tracker()
t:apply(16, "R", "POWER_STATE", "1")
t:apply(16, nil, "CURRENT_SELECTED_DEVICE", "0")
t:apply(
  16,
  nil,
  "CURRENT MEDIA INFO",
  "<mediainfo><mediatype>SONG</mediatype><artist>Gabel</artist><title>Beni</title><deviceid>83</deviceid></mediainfo>"
)
state = t:snapshot()[1]
check("source is taken from the media record", state.source_device_id == 83, state.source_device_id)

print("\n[13] Climate rides alongside activity")

t = tracker()
t:setClimate(94, "78", "70", "74", "Heat")
state = nil
for _, r in ipairs(t:snapshot()) do
  if r.room_id == 94 then
    state = r
  end
end
check("temperature is recorded for the room", state and state.temperature == 78, state and state.temperature)
check("setpoints too", state and state.setpoint_heat == 70 and state.setpoint_cool == 74)

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
