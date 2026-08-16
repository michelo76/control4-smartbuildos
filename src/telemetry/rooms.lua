--- Turns a stream of room variable changes into current state and activity spans.
---
--- ── WHY THIS AGGREGATES ON THE CONTROLLER ───────────────────────────────────
---
--- A busy house emits thousands of variable changes a day — volume alone moves
--- constantly. Shipping them raw would be traffic nobody reads and storage
--- nobody queries. What a report actually needs is spans: "Living Room, Apple
--- TV, 20:14 to 22:47". So the controller keeps the running state and emits a
--- session only when one ENDS.
---
--- ── WHAT COUNTS AS A SESSION ────────────────────────────────────────────────
---
--- A room being on. It starts when the room powers on, ends when it powers off,
--- and a SOURCE CHANGE closes one and opens another — otherwise an evening of
--- "Apple TV then Netflix then Spotify" collapses into a single undifferentiated
--- block and the "what you watched" breakdown has nothing to work with.
---
--- Pure: no C4 calls, no globals, injected clock. Every rule here decides a
--- number a client will eventually be shown in a report, and a quiet mistake
--- produces a plausible wrong figure rather than a visible failure.

local Rooms = {}
Rooms.__index = Rooms

--- Variables this tracker understands. Anything else is recorded into state
--- but never starts or ends a session — an installer can monitor extra
--- variables without silently changing what a session means.
local POWER = "POWER_STATE"
local SOURCE = "CURRENT_SELECTED_DEVICE"
local VIDEO_SOURCE = "CURRENT_VIDEO_DEVICE"
local MEDIA = "CURRENT_MEDIA"
local MEDIA_INFO = "CURRENT MEDIA INFO"
--- Nests a whole <mediainfo> inside <wallmediainfo>; useful when the room
--- variable is empty but the media wall knows what is playing.
local MEDIA_WALL = "MEDIA WALL INFO"
local VOLUME = "CURRENT_VOLUME"
local MUTED = "IS_MUTED"
local NAVIGATION = "IN_NAVIGATION"

--- Control4 writes booleans three ways across one room's variables.
local function truthy(value)
  local v = tostring(value or ""):lower()
  return v == "1" or v == "true" or v == "on" or v == "yes"
end

local function number(value)
  return tonumber(value)
end

--- A device id of 0 means "nothing selected", not device zero.
local function deviceId(value)
  local n = tonumber(value)
  if n == nil or n == 0 then
    return nil
  end
  return n
end

--- @param now fun(): number Monotonic milliseconds.
--- @param wallClock fun(): string ISO timestamp, for what gets stored.
function Rooms.new(now, wallClock)
  return setmetatable({
    now = now,
    wallClock = wallClock,
    rooms = {},
    completed = {},
    --- Bounded: a controller that cannot reach the platform for a day must not
    --- accumulate sessions until it runs out of memory. Oldest are dropped and
    --- the loss is counted, because silently thinning history is worse than
    --- saying so.
    maxCompleted = 500,
    dropped = 0,
  }, Rooms)
end

--- @return table state The mutable record for a room.
function Rooms:room(roomId, roomName)
  local r = self.rooms[roomId]
  if r == nil then
    r = {
      room_id = roomId,
      room_name = roomName,
      powered = false,
      source_device_id = nil,
      source_name = nil,
      media_title = nil,
      media_artist = nil,
      media_album = nil,
      media_type = nil,
      volume = nil,
      muted = false,
      in_navigation = false,
      temperature = nil,
      changed_at = self.wallClock(),
      -- Open session, if any.
      session = nil,
    }
    self.rooms[roomId] = r
  end
  if roomName and r.room_name == nil then
    r.room_name = roomName
  end
  return r
end

function Rooms:openSession(r)
  if r.session ~= nil then
    return
  end
  r.session = {
    room_id = r.room_id,
    room_name = r.room_name,
    source_device_id = r.source_device_id,
    source_name = r.source_name,
    media_type = r.media_type,
    media_title = r.media_title,
    media_artist = r.media_artist,
    started_at = self.wallClock(),
    startedTick = self.now(),
  }
end

function Rooms:closeSession(r)
  local s = r.session
  if s == nil then
    return
  end
  r.session = nil

  -- Duration from the MONOTONIC clock, not the wall clock: a controller whose
  -- time is corrected mid-session would otherwise record a negative or wildly
  -- long span.
  local seconds = math.floor((self.now() - s.startedTick) / 1000 + 0.5)
  if seconds < 0 then
    seconds = 0
  end

  -- A sub-second flicker is a state bounce, not something a person did. Storing
  -- it would pad the session count with noise.
  if seconds < 1 then
    return
  end

  s.ended_at = self.wallClock()
  s.duration_seconds = seconds
  s.startedTick = nil

  self.completed[#self.completed + 1] = s
  if #self.completed > self.maxCompleted then
    table.remove(self.completed, 1)
    self.dropped = self.dropped + 1
  end
end

--- Applies one variable change.
---
--- @param roomId number
--- @param roomName string|nil
--- @param name string Variable name, e.g. POWER_STATE.
--- @param value any
function Rooms:apply(roomId, roomName, name, value)
  local r = self:room(roomId, roomName)
  local changed = false

  if name == POWER then
    local powered = truthy(value)
    if powered ~= r.powered then
      r.powered = powered
      changed = true
      if powered then
        self:openSession(r)
      else
        self:closeSession(r)
        -- A room that is off is not playing anything. Leaving stale media on
        -- the record makes the client app claim a dark room is playing music.
        r.source_device_id, r.source_name = nil, nil
        r.media_title, r.media_artist, r.media_album, r.media_type = nil, nil, nil, nil
      end
    end
  elseif name == SOURCE or name == VIDEO_SOURCE then
    local id = deviceId(value)
    if id ~= r.source_device_id then
      r.source_device_id = id
      r.media_type = (name == VIDEO_SOURCE and id ~= nil) and "video" or r.media_type
      changed = true
      -- A source change inside an active session splits it, so "Apple TV then
      -- Netflix" is two spans rather than one undifferentiated block.
      if r.powered then
        self:closeSession(r)
        self:openSession(r)
      end
    end
  elseif name == MEDIA or name == MEDIA_INFO or name == MEDIA_WALL then
    local title, artist, mediaType, album = self.parseMedia(value)
    -- An empty payload must not wipe what another media variable just set:
    -- CURRENT_MEDIA reports an empty shell while CURRENT MEDIA INFO carries the
    -- real record, and they arrive as separate changes.
    if title == nil and artist == nil and album == nil then
      return false
    end
    if title ~= r.media_title or artist ~= r.media_artist or album ~= r.media_album then
      r.media_title, r.media_artist, r.media_album = title, artist, album
      r.media_type = mediaType or r.media_type
      changed = true
      -- Deliberately does NOT split the session: a new track is not a new
      -- viewing. The session carries what was playing when it started, and the
      -- current track lives in state.
      if r.session then
        r.session.media_title = r.session.media_title or title
        r.session.media_artist = r.session.media_artist or artist
      end
    end
  elseif name == VOLUME then
    local v = number(value)
    if v ~= r.volume then
      r.volume = v
      changed = true
    end
  elseif name == MUTED then
    local m = truthy(value)
    if m ~= r.muted then
      r.muted = m
      changed = true
    end
  elseif name == NAVIGATION then
    local n = truthy(value)
    if n ~= r.in_navigation then
      r.in_navigation = n
      changed = true
    end
  end

  if changed then
    r.changed_at = self.wallClock()
  end
  return changed
end

--- Parses what a room reports as "what is playing".
---
--- ── THE FORMAT IS XML, MEASURED NOT ASSUMED ─────────────────────────────────
---
--- The first version of this split on " - ", which was a guess. A real system
--- reports:
---
---   <mediainfo><roomId>16</roomId><mediatype>SONG</mediatype>
---     <artist>Joseph Zenny Jr</artist><album>Mpap Pale - Single</album>...
---
--- Note the album contains " - ". The hyphen heuristic would have taken "Mpap
--- Pale" as an artist — precisely the silent mislabelling it was meant to avoid.
---
--- Tags are extracted by name rather than by position, so a field we have not
--- seen yet is simply ignored instead of shifting everything after it. The
--- non-XML path is kept because MEDIA WALL INFO and other sources may not use
--- this shape, and a plain string should still show something useful.
---
--- @return string|nil title, string|nil artist, string|nil mediaType, string|nil album
function Rooms.parseMedia(value)
  local s = tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if s == "" then
    return nil, nil, nil, nil
  end

  if s:find("<", 1, true) then
    --- @param name string
    --- @return string|nil
    local function tag(name)
      -- Non-greedy, and only the first occurrence: MEDIA WALL INFO nests a
      -- whole <mediainfo> inside <wallmediainfo>, so a greedy match would span
      -- from the outer open tag to the inner close.
      local v = s:match("<" .. name .. ">(.-)</" .. name .. ">")
      if v == nil then
        return nil
      end
      v = v:gsub("^%s+", ""):gsub("%s+$", "")
      return v ~= "" and v or nil
    end

    -- `title` is the expected tag but has not been confirmed on hardware yet,
    -- so several plausible names are tried before giving up. Anything unknown
    -- falls through to nil rather than to a wrong field.
    local title = tag("title") or tag("name") or tag("song") or tag("track")
    local artist = tag("artist") or tag("albumartist")
    local album = tag("album")
    local mediaType = tag("mediatype")
    if mediaType then
      mediaType = mediaType:lower()
    end

    -- An empty shell — CURRENT_MEDIA reports <mediainfo><mediaid>0</mediaid>
    -- <mediatype/></mediainfo> even while a song is playing — carries nothing.
    if title == nil and artist == nil and album == nil and mediaType == nil then
      return nil, nil, nil, nil
    end
    return title, artist, mediaType, album
  end

  -- Plain text. Only a SPACED hyphen separates, so "Spider-Man" stays whole.
  local artist, title = s:match("^(.-)%s+%-%s+(.+)$")
  if artist and title and #artist > 0 and #title > 0 then
    return title, artist, nil, nil
  end
  return s, nil, nil, nil
end

--- Sets climate on a room, sampled rather than watched — temperature moves
--- constantly and every change is not worth an event.
function Rooms:setClimate(roomId, temperature, heat, cool, mode)
  local r = self:room(roomId, nil)
  r.temperature = number(temperature)
  r.setpoint_heat = number(heat)
  r.setpoint_cool = number(cool)
  r.hvac_mode = mode
end

--- Current state for every known room, shaped for the platform.
function Rooms:snapshot()
  local out = {}
  for _, r in pairs(self.rooms) do
    out[#out + 1] = {
      room_id = r.room_id,
      room_name = r.room_name,
      powered = r.powered,
      source_device_id = r.source_device_id,
      source_name = r.source_name,
      media_title = r.media_title,
      media_artist = r.media_artist,
      media_album = r.media_album,
      media_type = r.media_type,
      volume = r.volume,
      muted = r.muted,
      in_navigation = r.in_navigation,
      temperature = r.temperature,
      setpoint_heat = r.setpoint_heat,
      setpoint_cool = r.setpoint_cool,
      hvac_mode = r.hvac_mode,
      changed_at = r.changed_at,
    }
  end
  return out
end

--- Removes and returns completed sessions.
---
--- Taken rather than read, so an upload that succeeds cannot send the same span
--- twice. If the upload fails the caller must put them back — which is why this
--- returns them rather than clearing silently.
function Rooms:takeSessions()
  local out = self.completed
  self.completed = {}
  return out
end

--- Returns sessions to the queue after a failed upload, preserving order.
function Rooms:returnSessions(sessions)
  for i = #sessions, 1, -1 do
    table.insert(self.completed, 1, sessions[i])
  end
  while #self.completed > self.maxCompleted do
    table.remove(self.completed, 1)
    self.dropped = self.dropped + 1
  end
end

--- Closes every open session. Used on driver shutdown so an evening's viewing
--- is not lost because the driver reloaded at 11pm.
function Rooms:closeAll()
  for _, r in pairs(self.rooms) do
    self:closeSession(r)
  end
end

return Rooms
