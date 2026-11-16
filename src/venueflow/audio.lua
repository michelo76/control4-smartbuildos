--- VenueFlow: audio zones, lighting presets and shades (pure).
---
--- Audio is its own subsystem. Nothing in routing.lua ever calls into this
--- module: a video route changes an audio zone only when the request names
--- one ("Listen in Bar"), or when the installer mapped a display and a zone to
--- the same Control4 room (flagged at validation as AUDIO_COUPLED, because
--- there Control4 itself moves the sound with the picture).
---
--- A zone is a Control4 room. Whether a given installation can really play
--- one source in the bar and another on the patio depends on its audio
--- hardware; VenueFlow sends the room commands and reports what the rooms say.

local U = require("venueflow.util")
local Errors = require("venueflow.errors")
local Routing = require("venueflow.routing")

local M = {}

local Audio = {}
Audio.__index = Audio

--- deps = { config(), index(), state, tracker, adapter(), sourceForDevice(deviceId) }
function M.new(deps)
  local self = setmetatable({}, Audio)
  self.deps = deps
  return self
end

local function requestFail(code, detail)
  local out = Errors.fail(code, detail)
  out.status = "failed"
  out.results = {}
  return out
end

--- Common checks for one zone. Returns zone, or nil + failed reply.
function Audio:_zone(zoneId, capability, opts)
  local ix = self.deps.index()
  local access = opts.access
  if not access:flag("audio") then
    return nil, requestFail("VF_FORBIDDEN", "profile may not control audio")
  end
  local zone = ix.zones[zoneId or ""]
  if zone == nil then
    return nil, requestFail("VF_NOT_FOUND", "unknown audio zone " .. tostring(zoneId))
  end
  if not access:zone(zone) then
    return nil, requestFail("VF_FORBIDDEN", "profile may not control this zone")
  end
  if capability ~= nil and zone.can[capability] == false then
    return nil, requestFail("VF_UNSUPPORTED", "zone does not support " .. capability)
  end
  if zone.c4RoomId == nil then
    return nil, requestFail("VF_DEVICE_UNMAPPED", "zone has no Control4 room")
  end
  return zone
end

function Audio:_single(zone, kind, label, field, desired, opts, action, extra)
  local deps = self.deps
  if opts.dry then
    local out = Routing.reply(nil, { { id = zone.id, name = zone.name, status = "planned" } }, true)
    for k, v in pairs(extra or {}) do
      out[k] = v
    end
    return out
  end
  local op = deps.tracker:begin(kind, label, { origin = opts.origin, executionId = opts.executionId })
  action.kind, action.id, action.name, action.field, action.desired = "zone", zone.id, zone.name, field, desired
  deps.tracker:submit(op, action)
  deps.tracker:close(op)
  local out = Routing.reply(op, { { id = zone.id, name = zone.name, status = "pending" } }, false)
  for k, v in pairs(extra or {}) do
    out[k] = v
  end
  return out
end

function Audio:setSource(zoneId, sourceId, opts)
  local deps = self.deps
  local zone, failed = self:_zone(zoneId, "source", opts)
  if zone == nil then
    return failed
  end
  local source = deps.index().sources[sourceId or ""]
  if source == nil then
    return requestFail("VF_NOT_FOUND", "unknown source " .. tostring(sourceId))
  end
  if not opts.access:source(source) then
    return requestFail("VF_FORBIDDEN", "profile may not use this source")
  end
  if source.enabled == false or source.audio == false then
    return requestFail("VF_SOURCE_UNAVAILABLE", "source is disabled or carries no audio")
  end
  if source.c4DeviceId == nil then
    return requestFail("VF_DEVICE_UNMAPPED", "source has no Control4 device")
  end
  if zone.sources ~= "all" and not U.contains(U.list(zone.sources), source.id) then
    return requestFail("VF_SOURCE_NOT_ALLOWED", "source is not in the zone's list")
  end
  local action = {
    dispatch = function(adapter)
      return adapter.selectAudio(zone.c4RoomId, source.c4DeviceId)
    end,
  }
  if zone.feedback == "room" then
    action.confirm = {
      roomId = zone.c4RoomId,
      want = source.c4DeviceId,
      matches = function(room)
        return room.audioDevice == source.c4DeviceId
      end,
      describe = function(room)
        return "audio device " .. tostring(room.audioDevice)
      end,
      actual = function(room)
        return deps.sourceForDevice(room.audioDevice)
      end,
    }
  end
  return self:_single(
    zone,
    "route_audio",
    string.format("%s in %s", tostring(source.name), tostring(zone.name)),
    "source",
    source.id,
    opts,
    action
  )
end

--- The level is clamped to the zone's limits; the reply says so.
function Audio:setVolume(zoneId, level, opts)
  local zone, failed = self:_zone(zoneId, "volume", opts)
  if zone == nil then
    return failed
  end
  if type(level) ~= "number" then
    return requestFail("VF_INVALID_PAYLOAD", "volume must be a number")
  end
  local wanted = U.round(level)
  local applied = U.clamp(wanted, zone.minVolume or 0, zone.maxVolume or 100)
  local action = {
    dispatch = function(adapter)
      return adapter.setVolume(zone.c4RoomId, applied)
    end,
  }
  if zone.feedback == "room" then
    action.confirm = {
      roomId = zone.c4RoomId,
      want = applied,
      matches = function(room)
        return room.volume ~= nil and math.abs(room.volume - applied) <= 1
      end,
      describe = function(room)
        return "volume " .. tostring(room.volume)
      end,
      actual = function(room)
        return room.volume
      end,
    }
  end
  return self:_single(
    zone,
    "volume",
    string.format("%s volume %d%%", tostring(zone.name), applied),
    "volume",
    applied,
    opts,
    action,
    { level = applied, clamped = applied ~= wanted }
  )
end

function Audio:setMute(zoneId, muted, opts)
  local zone, failed = self:_zone(zoneId, "mute", opts)
  if zone == nil then
    return failed
  end
  if type(muted) ~= "boolean" then
    return requestFail("VF_INVALID_PAYLOAD", "muted must be true or false")
  end
  local action = {
    dispatch = function(adapter)
      return adapter.setMute(zone.c4RoomId, muted)
    end,
  }
  if zone.feedback == "room" then
    action.confirm = {
      roomId = zone.c4RoomId,
      want = muted,
      matches = function(room)
        return room.muted == muted
      end,
      describe = function(room)
        return "muted " .. tostring(room.muted)
      end,
      actual = function(room)
        return room.muted
      end,
    }
  end
  return self:_single(
    zone,
    "mute",
    string.format("%s %s", muted and "Mute" or "Unmute", tostring(zone.name)),
    "mute",
    muted,
    opts,
    action
  )
end

--- A zone is switched OFF here; it starts by being given a source.
function Audio:power(zoneId, power, opts)
  local zone, failed = self:_zone(zoneId, "power", opts)
  if zone == nil then
    return failed
  end
  if power ~= "off" then
    return requestFail("VF_INVALID_PAYLOAD", "a zone can only be switched off; choose a source to start it")
  end
  local action = {
    dispatch = function(adapter)
      return adapter.roomOff(zone.c4RoomId)
    end,
  }
  if zone.feedback == "room" then
    action.confirm = {
      roomId = zone.c4RoomId,
      want = "off",
      matches = function(room)
        return room.power == false
      end,
      describe = function(room)
        return "power " .. tostring(room.power)
      end,
      actual = function(room)
        if room.power == nil then
          return nil
        end
        return room.power and "on" or "off"
      end,
    }
  end
  return self:_single(
    zone,
    "zone_power",
    string.format("Turn off %s", tostring(zone.name)),
    "power",
    "off",
    opts,
    action
  )
end

function Audio:preset(zoneId, presetId, opts)
  local ix = self.deps.index()
  local zone = ix.zones[zoneId or ""]
  if zone == nil then
    return requestFail("VF_NOT_FOUND", "unknown audio zone " .. tostring(zoneId))
  end
  for _, p in ipairs(U.list(zone.presets)) do
    if p.id == presetId then
      return self:setVolume(zoneId, p.level, opts)
    end
  end
  return requestFail("VF_NOT_FOUND", "unknown volume preset " .. tostring(presetId))
end

-- ─── Lighting presets and shades ────────────────────────────────────────────
-- One documented device command each; no feedback is assumed, so the outcome
-- is "commanded", never "confirmed".

function Audio:lighting(lightingId, presetId, opts)
  local deps = self.deps
  local item = deps.index().lighting[lightingId or ""]
  if item == nil then
    return requestFail("VF_NOT_FOUND", "unknown lighting control " .. tostring(lightingId))
  end
  if not opts.access:lightingControl(item) then
    return requestFail("VF_FORBIDDEN", "profile may not control lighting here")
  end
  local preset
  for _, p in ipairs(U.list(item.presets)) do
    if p.id == presetId then
      preset = p
    end
  end
  if preset == nil then
    return requestFail("VF_NOT_FOUND", "unknown lighting preset " .. tostring(presetId))
  end
  if type(preset.deviceId) ~= "number" or type(preset.command) ~= "string" or preset.command == "" then
    return requestFail("VF_DEVICE_UNMAPPED", "lighting preset has no Control4 device or command")
  end
  if opts.dry then
    return Routing.reply(nil, { { id = item.id, name = item.name, status = "planned" } }, true)
  end
  local op = deps.tracker:begin(
    "lighting",
    string.format("%s: %s", tostring(item.name), tostring(preset.name)),
    { origin = opts.origin, executionId = opts.executionId }
  )
  deps.tracker:submit(op, {
    kind = "lighting",
    id = item.id,
    name = item.name,
    field = "preset",
    desired = preset.id,
    dispatch = function(adapter)
      return adapter.deviceCommand(preset.deviceId, preset.command, U.copy(preset.params or {}))
    end,
  })
  deps.tracker:close(op)
  return Routing.reply(op, { { id = item.id, name = item.name, status = "pending" } }, false)
end

function Audio:shade(shadeId, action, opts)
  local deps = self.deps
  local item = deps.index().shades[shadeId or ""]
  if item == nil then
    return requestFail("VF_NOT_FOUND", "unknown shade " .. tostring(shadeId))
  end
  if not opts.access:shade(item) then
    return requestFail("VF_FORBIDDEN", "profile may not control shades here")
  end
  if action ~= "open" and action ~= "close" then
    return requestFail("VF_INVALID_PAYLOAD", "shade action must be open or close")
  end
  if type(item.deviceId) ~= "number" then
    return requestFail("VF_DEVICE_UNMAPPED", "shade has no Control4 device")
  end
  if opts.dry then
    return Routing.reply(nil, { { id = item.id, name = item.name, status = "planned" } }, true)
  end
  local level = action == "open" and (tonumber(item.openLevel) or 100) or (tonumber(item.closedLevel) or 0)
  local op = deps.tracker:begin(
    "shade",
    string.format("%s %s", action == "open" and "Open" or "Close", tostring(item.name)),
    { origin = opts.origin, executionId = opts.executionId }
  )
  deps.tracker:submit(op, {
    kind = "shade",
    id = item.id,
    name = item.name,
    field = "position",
    desired = action == "open" and "open" or "closed",
    dispatch = function(adapter)
      return adapter.deviceCommand(item.deviceId, "SET_LEVEL_TARGET", { LEVEL_TARGET = level })
    end,
  })
  deps.tracker:close(op)
  return Routing.reply(op, { { id = item.id, name = item.name, status = "pending" } }, false)
end

return M
