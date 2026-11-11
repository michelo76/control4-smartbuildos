--- Solar Position — the engine (pure, no Director surface).
---
--- Turns a location and a clock into the things Composer programming can
--- use: the day phase, whether it is daylight, next sunrise/sunset, and for
--- up to four building facades whether the sun is shining on them. It
--- remembers the previous tick so every transition is reported ONCE:
---
---   • PHASES (by GEOMETRIC elevation, the way NOAA defines sunrise and civil
---     twilight; morning/evening split at solar noon):
---       night  < -6  <= dawn / dusk  < -0.833  <= golden_morning / golden_evening  < 6  <= day
---     Civil twilight is -6 degrees; -0.833 is the official sunrise/sunset
---     elevation (refraction plus the disc); 6 degrees is the usual golden
---     hour ceiling.
---   • EVENTS, one at every boundary of the day, in the order they happen:
---       civil_dawn            night → dawn (the sun passes -6 going up)
---       sunrise               the sun passes the horizon going up
---       golden_morning_ended  golden_morning → day (the sun passes 6 going up)
---       golden_evening        entering golden_evening (6 going down)
---       sunset                the sun passes the horizon going down
---       night                 entering night (-6 going down: twilight over)
---     and the two older names kept for programming that already uses them:
---     golden_hour (entering either golden phase, so it fires with sunrise
---     and with golden_evening) and civil_dusk (entering dusk, so it fires
---     with sunset).
---   • FACADES: a facade is lit when the sun's APPARENT elevation (what the
---     eye and the window see) is at least its minimum, at most its maximum
---     (90 = no ceiling; lower it for an overhang or a high summer sun that
---     never enters the glass) and the azimuth is within half its width of
---     its heading. ONE DEGREE OF HYSTERESIS on every edge: once lit, it
---     stays lit until the sun is a degree below the minimum, a degree above
---     the maximum or a degree past the side, so a sun grazing an edge never
---     flaps the shades. With a maximum a facade can be lit twice in a day
---     (before and after the high sun), and says so with two pairs of events.
---   • A location or facade change resets the remembered state, so the
---     first tick after it re-announces nothing (initial states are not
---     transitions).

local Position = require("solarpos.position")
local Solar = require("atmosphere.solar")

local M = {}

M.LIMITS = { facades = 4, width_min = 10, width_max = 180, min_elevation_max = 60, max_elevation_max = 90 }
M.HYSTERESIS = 1
M.CIVIL = -6
M.HORIZON = -0.833
M.GOLDEN = 6

M.PHASES = { "night", "dawn", "golden_morning", "day", "golden_evening", "dusk" }

--- Validates a facade list. Returns the clean list (invalid or unnamed
--- facades dropped) and refusals by index.
function M.validateFacades(raw)
  local out, refusals = {}, {}
  for i = 1, M.LIMITS.facades do
    local f = type(raw) == "table" and raw[i] or nil
    if type(f) == "table" and tostring(f.name or ""):gsub("^%s+", ""):gsub("%s+$", "") ~= "" then
      local az = tonumber(f.azimuth)
      local width = tonumber(f.width) or 90
      local minEl = tonumber(f.min_elevation) or 5
      local maxEl = tonumber(f.max_elevation) or M.LIMITS.max_elevation_max
      if maxEl > M.LIMITS.max_elevation_max then
        maxEl = M.LIMITS.max_elevation_max
      end
      if az == nil then
        refusals[#refusals + 1] = { index = i, reason = "azimuth must be a number" }
      elseif maxEl <= math.max(0, math.min(minEl, M.LIMITS.min_elevation_max)) then
        -- A ceiling at or under the floor leaves no sun that counts: say so
        -- rather than keep a facade that can never be lit.
        refusals[#refusals + 1] = { index = i, reason = "max elevation must be above min elevation" }
      else
        if width < M.LIMITS.width_min then
          width = M.LIMITS.width_min
        elseif width > M.LIMITS.width_max then
          width = M.LIMITS.width_max
        end
        if minEl < 0 then
          minEl = 0
        elseif minEl > M.LIMITS.min_elevation_max then
          minEl = M.LIMITS.min_elevation_max
        end
        out[i] = {
          index = i,
          name = tostring(f.name):gsub("^%s+", ""):gsub("%s+$", ""):sub(1, 40),
          azimuth = Position.norm360(az),
          width = width,
          min_elevation = minEl,
          max_elevation = maxEl,
        }
      end
    end
  end
  return out, refusals
end

--- Is the sun on this facade now, given whether it was before (hysteresis)?
function M.facadeLit(facade, elevation, azimuth, wasLit)
  local half = facade.width / 2
  local off = math.abs(Position.angleDiff(azimuth, facade.azimuth))
  local ceiling = facade.max_elevation or M.LIMITS.max_elevation_max
  if wasLit then
    return elevation >= facade.min_elevation - M.HYSTERESIS
      and elevation <= ceiling + M.HYSTERESIS
      and off <= half + M.HYSTERESIS
  end
  return elevation >= facade.min_elevation and elevation <= ceiling and off <= half
end

--- Why a facade is in shade, for the status line: "high" when the sun is in
--- front of it but above its ceiling, "low" when in front but under its
--- floor, "aside" when the sun is not in front of it at all. Nil when lit.
function M.shadeReason(facade, elevation, azimuth, lit)
  if lit then
    return nil
  end
  local off = math.abs(Position.angleDiff(azimuth, facade.azimuth))
  if off > facade.width / 2 then
    return "aside"
  end
  if elevation > (facade.max_elevation or M.LIMITS.max_elevation_max) then
    return "high"
  end
  return "low"
end

--- Phase from elevation and the morning/evening side.
function M.phaseOf(elevation, morning)
  if elevation >= M.GOLDEN then
    return "day"
  elseif elevation >= M.HORIZON then
    return morning and "golden_morning" or "golden_evening"
  elseif elevation >= M.CIVIL then
    return morning and "dawn" or "dusk"
  end
  return "night"
end

local Engine = {}
Engine.__index = Engine

function M.new()
  local self = setmetatable({}, Engine)
  self.facades = {}
  self.lit = {}
  self.phase = nil
  self.daylight = nil
  self.location = nil
  self.last = nil
  return self
end

--- Sets the facades; a change forgets the lit states (no false transitions).
function Engine:setFacades(list)
  local clean, refusals = M.validateFacades(list)
  local changed = false
  for i = 1, M.LIMITS.facades do
    local a, b = self.facades[i], clean[i]
    if (a == nil) ~= (b == nil) then
      changed = true
    elseif
      a ~= nil
      and (
        a.azimuth ~= b.azimuth
        or a.width ~= b.width
        or a.min_elevation ~= b.min_elevation
        or a.max_elevation ~= b.max_elevation
      )
    then
      changed = true
    end
  end
  self.facades = clean
  if changed then
    self.lit = {}
  end
  return clean, refusals
end

--- Sets the location; a change forgets phase and lit states.
function Engine:setLocation(lat, lon)
  lat, lon = tonumber(lat), tonumber(lon)
  if lat == nil or lon == nil then
    self.location = nil
    self.phase, self.daylight, self.lit, self.last = nil, nil, {}, nil
    return false
  end
  if self.location == nil or self.location.lat ~= lat or self.location.lon ~= lon then
    self.location = { lat = lat, lon = lon }
    self.phase, self.daylight, self.lit, self.last = nil, nil, {}, nil
  end
  return true
end

--- One tick. `now` is a UTC epoch; `localOffset` seconds east of UTC (for the
--- civil day used by sunrise/sunset). Returns nil without a location, else
--- { position, phase, is_daylight, morning, solar = solarState, facades =
---   { [i] = { lit, name, shade } }, events = { "civil_dawn" | "sunrise" |
---   "golden_morning_ended" | "golden_evening" | "sunset" | "night" |
---   "golden_hour" | "civil_dusk" | "facade_hit:<i>" | "facade_left:<i>" ... } }.
function Engine:tick(now, localOffset)
  if self.location == nil then
    return nil
  end
  now = tonumber(now)
  local pos = Position.position(self.location.lat, self.location.lon, now)
  local solar = Solar.solarState(self.location.lat, self.location.lon, now, localOffset or 0)
  -- Morning = before LOCAL solar noon, which is exactly a negative hour
  -- angle; no civil-day or timezone arithmetic can get that wrong.
  local morning = pos.hour_angle < 0
  local phase = M.phaseOf(pos.geometric_elevation, morning)
  local daylight = pos.geometric_elevation >= M.HORIZON
  local events = {}
  -- The horizon is judged on its own, not from the phase names, so a tick
  -- that arrives late (a busy controller) still reports the crossing.
  if self.daylight ~= nil and daylight ~= self.daylight then
    events[#events + 1] = daylight and "sunrise" or "sunset"
  end
  if self.phase ~= nil and phase ~= self.phase then
    if phase == "dawn" and self.phase == "night" then
      events[#events + 1] = "civil_dawn"
    elseif phase == "golden_morning" or phase == "golden_evening" then
      events[#events + 1] = "golden_hour"
      if phase == "golden_evening" then
        events[#events + 1] = "golden_evening"
      end
    elseif phase == "dusk" and (self.phase == "golden_evening" or self.phase == "day") then
      events[#events + 1] = "civil_dusk"
    elseif phase == "day" and self.phase == "golden_morning" then
      events[#events + 1] = "golden_morning_ended"
    elseif phase == "night" then
      events[#events + 1] = "night"
    end
  end
  self.phase = phase
  self.daylight = daylight
  local facades = {}
  for i = 1, M.LIMITS.facades do
    local f = self.facades[i]
    if f ~= nil then
      local was = self.lit[i]
      local lit = M.facadeLit(f, pos.elevation, pos.azimuth, was == true)
      if was ~= nil and lit ~= was then
        events[#events + 1] = (lit and "facade_hit:" or "facade_left:") .. i
      end
      self.lit[i] = lit
      facades[i] = { lit = lit, name = f.name, shade = M.shadeReason(f, pos.elevation, pos.azimuth, lit) }
    end
  end
  local result = {
    now = now,
    position = pos,
    phase = phase,
    morning = morning,
    is_daylight = daylight,
    solar = solar,
    facades = facades,
    events = events,
  }
  self.last = result
  return result
end

return M
