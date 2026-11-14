--- VenueFlow: the video routing engine and display power (pure).
---
--- A route is validated per destination and reported per destination. The
--- steps, in the order they run:
---
---   1. permission      the profile may route video, may use the source, may see the display
---   2. source          exists, is enabled, carries video, is mapped to a Control4 device
---   3. destinations    every id resolves to a display; duplicates are dropped
---   4. path            the display can be routed at all, accepts this source, is mapped, is not offline
---   5. conflicts       a newer request for a display replaces an unfinished older one
---   6. execute         through the adapter, serialised by the queue
---   7. feedback        Control4's room variables confirm (or contradict) the route
---   8. results         one outcome per display; never "all good" when one failed
---
--- No matrix is assumed. How a source reaches a display is the display's own
--- `route.strategy`:
---   room     Control4 room selection (the project's AV bindings decide the path:
---            HDMI matrix, AV-over-IP, direct). Feedback from the room.
---   command  one installer-defined device command (for a switcher or video-wall
---            processor Control4 does not route by itself). No feedback is assumed.
---   none     the display cannot be routed.

local U = require("venueflow.util")
local Errors = require("venueflow.errors")
local Tracker = require("venueflow.tracker")

local M = {}

local Routing = {}
Routing.__index = Routing

--- deps = { config(), index(), state, tracker, adapter(), sourceForDevice(deviceId) }
function M.new(deps)
  local self = setmetatable({}, Routing)
  self.deps = deps
  return self
end

local function requestFail(code, detail)
  local out = Errors.fail(code, detail)
  out.status = "failed"
  out.results = {}
  return out
end

local function dedupe(ids)
  local seen, out = {}, {}
  for _, id in ipairs(U.list(ids)) do
    if type(id) == "string" and not seen[id] then
      seen[id] = true
      out[#out + 1] = id
    end
  end
  return out
end

--- Turns per-target entries into the reply every engine returns.
local function reply(op, entries, dry)
  local accepted, rejected = 0, 0
  for _, e in ipairs(entries) do
    if e.status == "failed" then
      rejected = rejected + 1
    else
      accepted = accepted + 1
    end
  end
  local status
  if accepted == 0 then
    status = "failed"
  elseif rejected == 0 then
    status = dry and "planned" or "accepted"
  else
    status = "partial"
  end
  -- A room already in the requested state confirms during dispatch: the
  -- operation can be finished before this reply is built. Say so, with the
  -- final outcome, so a caller never waits for a settlement that already came.
  local settled = op ~= nil and op.done == true
  return {
    ok = accepted > 0,
    status = status,
    operationId = op and op.id or nil,
    settled = settled or nil,
    final = settled and { summary = op.summary, targets = Tracker.publicOp(op, true).targets } or nil,
    results = entries,
    summary = { requested = #entries, accepted = accepted, rejected = rejected },
    errorCode = accepted == 0 and (entries[1] and entries[1].errorCode or "VF_INVALID_PAYLOAD") or nil,
    message = accepted == 0 and (entries[1] and entries[1].message or Errors.operatorText("VF_INVALID_PAYLOAD")) or nil,
  }
end
M.reply = reply

local function entryFail(target, code, detail)
  return {
    id = target.id,
    name = target.name,
    status = "failed",
    errorCode = code,
    message = Errors.operatorText(code),
    detail = detail,
  }
end

--- Why a source cannot be shown on a display, or nil when it can.
function Routing:pathProblem(display, source)
  local route = display.route or {}
  if route.strategy == "none" then
    return "VF_ROUTE_UNSUPPORTED", "this display has no route strategy"
  end
  if display.sources ~= "all" and not U.contains(U.list(display.sources), source.id) then
    return "VF_SOURCE_NOT_ALLOWED", "source is not in the display's supported list"
  end
  if route.strategy == "room" then
    if display.c4RoomId == nil then
      return "VF_DEVICE_UNMAPPED", "display has no Control4 room"
    end
  elseif route.strategy == "command" then
    if type(route.command) ~= "table" or route.command.deviceId == nil then
      return "VF_DEVICE_UNMAPPED", "custom route has no device"
    end
  end
  if display.c4DeviceId ~= nil then
    local ok, online = pcall(self.deps.adapter().deviceOnline, display.c4DeviceId)
    if ok and online == false then
      return "VF_DEVICE_OFFLINE", "Control4 reports the display offline"
    end
  end
  return nil
end

local function substitute(params, source)
  local out = {}
  for k, v in pairs(params or {}) do
    if v == "${source}" then
      out[k] = source.c4DeviceId
    elseif v == "${sourceName}" then
      out[k] = source.name
    else
      out[k] = v
    end
  end
  return out
end

--- opts = { access, dry, origin, executionId }
function Routing:routeVideo(sourceId, displayIds, opts)
  local deps = self.deps
  local ix = deps.index()
  local access = opts.access
  -- 1. permission (request level)
  if not access:flag("routeVideo") then
    return requestFail("VF_FORBIDDEN", "profile may not route video")
  end
  -- 2. source
  local source = ix.sources[sourceId or ""]
  if source == nil then
    return requestFail("VF_NOT_FOUND", "unknown source " .. tostring(sourceId))
  end
  if not access:source(source) then
    return requestFail("VF_FORBIDDEN", "profile may not use this source")
  end
  if source.enabled == false then
    return requestFail("VF_SOURCE_UNAVAILABLE", "source is disabled")
  end
  if source.video == false then
    return requestFail("VF_SOURCE_UNAVAILABLE", "source carries no video")
  end
  if source.c4DeviceId == nil then
    return requestFail("VF_DEVICE_UNMAPPED", "source has no Control4 device")
  end
  -- 3. destinations
  local ids = dedupe(displayIds)
  if #ids == 0 then
    return requestFail("VF_INVALID_PAYLOAD", "no displays selected")
  end
  local op = nil
  if not opts.dry then
    op = deps.tracker:begin(
      "route_video",
      string.format("%s to %d display%s", tostring(source.name), #ids, #ids == 1 and "" or "s"),
      { origin = opts.origin, executionId = opts.executionId }
    )
  end
  local entries = {}
  for _, id in ipairs(ids) do
    local display = ix.displays[id]
    local target = { kind = "display", id = id, name = display and display.name or id, field = "source" }
    local code, detail
    if display == nil then
      code, detail = "VF_NOT_FOUND", "unknown display"
    elseif not access:display(display) then
      code, detail = "VF_FORBIDDEN", "profile may not control this display"
    else
      -- 4. path
      code, detail = self:pathProblem(display, source)
    end
    if code ~= nil then
      if op then
        deps.tracker:reject(op, target, code, detail)
      end
      entries[#entries + 1] = entryFail(target, code, detail)
    elseif opts.dry then
      entries[#entries + 1] = { id = id, name = display.name, status = "planned" }
    else
      -- 5 + 6 + 7: the tracker supersedes, queues, dispatches and confirms.
      local route = display.route
      local action = {
        kind = "display",
        id = id,
        name = display.name,
        field = "source",
        desired = source.id,
      }
      if route.strategy == "room" then
        action.dispatch = function(adapter)
          return adapter.selectVideo(display.c4RoomId, source.c4DeviceId)
        end
      else
        action.dispatch = function(adapter)
          return adapter.deviceCommand(
            route.command.deviceId,
            route.command.name,
            substitute(route.command.params, source)
          )
        end
      end
      if display.feedback == "room" and display.c4RoomId ~= nil and route.strategy == "room" then
        action.confirm = {
          roomId = display.c4RoomId,
          want = source.c4DeviceId,
          matches = function(room)
            return room.videoDevice == source.c4DeviceId
          end,
          describe = function(room)
            return "video device " .. tostring(room.videoDevice)
          end,
          actual = function(room)
            return deps.sourceForDevice(room.videoDevice)
          end,
        }
      end
      deps.tracker:submit(op, action)
      entries[#entries + 1] = { id = id, name = display.name, status = "pending" }
    end
  end
  if op then
    deps.tracker:close(op)
  end
  return reply(op, entries, opts.dry)
end

--- power = "on" | "off"
function Routing:displayPower(displayIds, power, opts)
  local deps = self.deps
  local ix = deps.index()
  local access = opts.access
  if power ~= "on" and power ~= "off" then
    return requestFail("VF_INVALID_PAYLOAD", "power must be on or off")
  end
  if not access:flag("power") then
    return requestFail("VF_FORBIDDEN", "profile may not switch displays")
  end
  local ids = dedupe(displayIds)
  if #ids == 0 then
    return requestFail("VF_INVALID_PAYLOAD", "no displays selected")
  end
  local on = power == "on"
  local op = nil
  if not opts.dry then
    op = deps.tracker:begin(
      "display_power",
      string.format("Power %s %d display%s", power, #ids, #ids == 1 and "" or "s"),
      { origin = opts.origin, executionId = opts.executionId }
    )
  end
  local entries = {}
  for _, id in ipairs(ids) do
    local display = ix.displays[id]
    local target = { kind = "display", id = id, name = display and display.name or id, field = "power" }
    local code, detail, action
    if display == nil then
      code, detail = "VF_NOT_FOUND", "unknown display"
    elseif not access:display(display) then
      code, detail = "VF_FORBIDDEN", "profile may not control this display"
    elseif display.power == "none" then
      code, detail = "VF_UNSUPPORTED", "this display has no power control"
    elseif display.power == "device" then
      if display.c4DeviceId == nil then
        code, detail = "VF_DEVICE_UNMAPPED", "display has no Control4 device"
      else
        action = {
          dispatch = function(adapter)
            return adapter.devicePower(display.c4DeviceId, on)
          end,
        }
      end
    else -- room
      if display.c4RoomId == nil then
        code, detail = "VF_DEVICE_UNMAPPED", "display has no Control4 room"
      elseif on then
        -- A Control4 room powers its display by selecting a source.
        local cell = deps.state:cell("display", id, "source")
        local sourceId = (cell and cell.value) or deps.state.lastSource[id] or display.defaultSourceId
        if sourceId ~= nil and ix.sources[sourceId] == nil then
          sourceId = display.defaultSourceId -- the remembered source was deleted
        end
        local source = sourceId and ix.sources[sourceId] or nil
        if source == nil or source.c4DeviceId == nil or source.enabled == false then
          code, detail = "VF_NO_SOURCE_FOR_POWER_ON", "no last or default source to select"
        else
          action = {
            dispatch = function(adapter)
              return adapter.selectVideo(display.c4RoomId, source.c4DeviceId)
            end,
          }
        end
      else
        action = {
          dispatch = function(adapter)
            return adapter.roomOff(display.c4RoomId)
          end,
        }
      end
      if action ~= nil and display.feedback == "room" then
        action.confirm = {
          roomId = display.c4RoomId,
          want = on and "on" or "off",
          matches = function(room)
            return room.power == on
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
    end
    if code == nil and display.c4DeviceId ~= nil and display.power ~= "none" then
      local ok, online = pcall(deps.adapter().deviceOnline, display.c4DeviceId)
      if ok and online == false then
        code, detail, action = "VF_DEVICE_OFFLINE", "Control4 reports the display offline", nil
      end
    end
    if code ~= nil then
      if op then
        deps.tracker:reject(op, target, code, detail)
      end
      entries[#entries + 1] = entryFail(target, code, detail)
    elseif opts.dry then
      entries[#entries + 1] = { id = id, name = display.name, status = "planned" }
    else
      action.kind, action.id, action.name, action.field, action.desired = "display", id, display.name, "power", power
      deps.tracker:submit(op, action)
      entries[#entries + 1] = { id = id, name = display.name, status = "pending" }
    end
  end
  if op then
    deps.tracker:close(op)
  end
  return reply(op, entries, opts.dry)
end

return M
