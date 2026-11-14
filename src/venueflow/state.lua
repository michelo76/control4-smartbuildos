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
  return self
end

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
--- still exist are kept; removed ids are dropped.
function State:reset(config)
  local function rebuild(kind, list)
    local old = self[kind]
    local fresh = {}
    for _, item in ipairs(list or {}) do
      fresh[item.id] = old[item.id] or blank(kind)
    end
    self[kind] = fresh
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

function State:snapshot(kind)
  return U.copy(self[kind])
end

return M
