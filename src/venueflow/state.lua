--- VenueFlow: the runtime state of every controlled thing (pure).
---
--- One CELL per fact (a display's source, a zone's volume ...):
---
---   { value, status, at, errorCode?, requested?, operationId? }
---
--- status is what the driver actually KNOWS:
---   confirmed  Control4 reported this value back
---   pending    a command was sent and feedback is awaited
---   commanded  a command was sent to a device that gives no feedback
---   unknown    never read, or a command went out and nothing could be read back
---   failed     the command could not be sent, or the device reported another value
---
--- A cell is never "confirmed" because a command was dispatched.

local U = require("venueflow.util")

local M = {}

M.STATUSES = { confirmed = true, pending = true, commanded = true, unknown = true, failed = true }

M.FIELDS = {
  display = { "power", "source" },
  zone = { "power", "source", "volume", "mute" },
  lighting = { "preset" },
  shade = { "position" },
}

local State = {}
State.__index = State

function M.new(deps)
  local self = setmetatable({}, State)
  self.now = deps and deps.now or os.time
  self.version = 1
  self.display = {}
  self.zone = {}
  self.lighting = {}
  self.shade = {}
  --- displayId -> the last source it was confirmed (or commanded) to show.
  --- "Power on" brings a display back to this, not to its default.
  self.lastSource = {}
  --- kind -> id -> the hardware mapping its cells were observed on (see reset).
  self.mapping = { display = {}, zone = {}, lighting = {}, shade = {} }
  return self
end

--- What a thing's readings were taken FROM: the Control4 room and devices it
--- is mapped to and how its feedback is read. Two publishes with the same
--- signature describe the same hardware; a different one means what was
--- known was known about something else.
local function mappingOf(kind, item)
  local parts = { tostring(item.c4RoomId), tostring(item.c4DeviceId), tostring(item.deviceId), tostring(item.feedback) }
  if kind == "display" then
    local route = type(item.route) == "table" and item.route or {}
    local command = type(route.command) == "table" and route.command or {}
    parts[#parts + 1] = tostring(item.power)
    parts[#parts + 1] = tostring(route.strategy)
    parts[#parts + 1] = tostring(command.deviceId)
  elseif kind == "lighting" then
    for _, preset in ipairs(type(item.presets) == "table" and item.presets or {}) do
      if type(preset) == "table" then
        parts[#parts + 1] = tostring(preset.id) .. "=" .. tostring(preset.deviceId)
      end
    end
  end
  return table.concat(parts, "|")
end
M.mappingOf = mappingOf

local function blankCell()
  return { status = "unknown" }
end

local function blank(kind)
  local out = {}
  for _, field in ipairs(M.FIELDS[kind]) do
    out[field] = blankCell()
  end
  return out
end

function State:touch()
  self.version = self.version + 1
  return self.version
end

--- Rebuilds the tables for a (new) published configuration. Cells of ids that
--- still exist AND are still mapped to the same hardware are kept; removed
--- ids are dropped; an id whose mapping changed starts again as unknown. A
--- reading confirmed on the old room or device says nothing about the new
--- one, and if the new one cannot be read it would otherwise stay on screen
--- as confirmed for as long as the driver runs.
function State:reset(config)
  local function rebuild(kind, list)
    local old, oldMapping = self[kind], self.mapping[kind] or {}
    local fresh, freshMapping = {}, {}
    for _, item in ipairs(list or {}) do
      local mapping = mappingOf(kind, item)
      if old[item.id] ~= nil and oldMapping[item.id] == mapping then
        fresh[item.id] = old[item.id]
      else
        fresh[item.id] = blank(kind)
        if kind == "display" then
          self.lastSource[item.id] = nil
        end
      end
      freshMapping[item.id] = mapping
    end
    self[kind] = fresh
    self.mapping[kind] = freshMapping
  end
  rebuild("display", config.displays)
  rebuild("zone", config.audioZones)
  rebuild("lighting", config.lighting)
  rebuild("shade", config.shades)
  self:touch()
end

--- Forgets everything known (the control mode changed: what the simulator
--- reported must never be shown as a real device's confirmed state).
function State:clear()
  self.display, self.zone, self.lighting, self.shade = {}, {}, {}, {}
  self.mapping = { display = {}, zone = {}, lighting = {}, shade = {} }
  self.lastSource = {}
  self:touch()
end

function State:cell(kind, id, field)
  local entity = self[kind] and self[kind][id]
  return entity and entity[field] or nil
end

--- Sets a cell. `extra` may carry errorCode, requested, operationId.
--- Returns true when anything changed.
function State:set(kind, id, field, value, status, extra)
  local entity = self[kind] and self[kind][id]
  if entity == nil or entity[field] == nil then
    return false
  end
  assert(M.STATUSES[status], "unknown state status " .. tostring(status))
  local cell = entity[field]
  extra = extra or {}
  if
    cell.value == value
    and cell.status == status
    and cell.errorCode == extra.errorCode
    and cell.requested == extra.requested
    and cell.operationId == extra.operationId
  then
    return false
  end
  entity[field] = {
    value = value,
    status = status,
    at = self.now(),
    errorCode = extra.errorCode,
    requested = extra.requested,
    operationId = extra.operationId,
  }
  if kind == "display" and field == "source" and value ~= nil and (status == "confirmed" or status == "commanded") then
    self.lastSource[id] = value
  end
  self:touch()
  if self.onChange then
    pcall(self.onChange, kind, id, field, entity[field], cell)
  end
  return true
end

--- Puts a cell back to an earlier copy of itself: a queued command was
--- withdrawn before it was sent. Nothing changed on the device, so this is
--- not a change: the change hook (which fires device-state rules) is NOT
--- called. A copy that was itself "pending" comes back as unknown.
function State:restore(kind, id, field, earlier)
  local entity = self[kind] and self[kind][id]
  if entity == nil or entity[field] == nil then
    return false
  end
  local cell = type(earlier) == "table" and U.copy(earlier) or blankCell()
  if cell.status == "pending" or not M.STATUSES[cell.status] then
    cell.status = "unknown"
  end
  entity[field] = cell
  self:touch()
  return true
end

function State:snapshot(kind)
  return U.copy(self[kind])
end

return M
