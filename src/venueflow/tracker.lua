--- VenueFlow: operations and their confirmation (pure).
---
--- An OPERATION is one request ("route Sports 1 to six displays") with one
--- TARGET per device. Each target ends in exactly one outcome:
---
---   confirmed   Control4 reported the requested value
---   commanded   sent to a device that gives no feedback (cannot be confirmed)
---   failed      refused before sending, could not be sent, or reported another value
---   unknown     sent, and nothing could be read back
---   superseded  replaced by a newer request before it finished
---
--- The operation is "done" when every target has an outcome. Nothing here
--- ever turns "the command was dispatched" into "confirmed".

local U = require("venueflow.util")
local Errors = require("venueflow.errors")

local M = {}

M.CONFIRM_MS = 8000
M.KEEP = 60
M.SWEEP_TIMER = "VfConfirmSweep"

local Tracker = {}
Tracker.__index = Tracker

--- deps = {
---   timers, now, state, queue,
---   adapter()            -> the current Control4 adapter
---   onSettled(op)        called once per operation when it is done
---   onTarget(op, target) called for every target outcome (diagnostics)
---   confirmMs
--- }
function M.new(deps)
  local self = setmetatable({}, Tracker)
  self.deps = deps
  self.seq = 0
  self.ops = {} -- newest first
  self.active = {} -- "kind:id:field" -> action awaiting dispatch or confirmation
  self.waiting = {} -- roomId -> { action, ... } awaiting feedback
  self.confirmMs = deps.confirmMs or M.CONFIRM_MS
  return self
end

function Tracker:begin(kind, label, meta)
  self.seq = self.seq + 1
  local op = {
    id = string.format("op%d", self.seq),
    kind = kind,
    label = label,
    origin = meta and meta.origin or "unknown",
    executionId = meta and meta.executionId or nil,
    startedAt = self.deps.now(),
    targets = {},
    pending = 0,
    closed = false,
    done = false,
  }
  table.insert(self.ops, 1, op)
  while #self.ops > M.KEEP do
    local dropped = table.remove(self.ops)
    if not dropped.done then
      -- Never forget an unfinished operation: keep it at the tail.
      table.insert(self.ops, dropped)
      break
    end
  end
  return op
end

local function summarize(op)
  local s = { total = #op.targets, confirmed = 0, commanded = 0, failed = 0, unknown = 0, superseded = 0, pending = 0 }
  for _, t in ipairs(op.targets) do
    s[t.status] = (s[t.status] or 0) + 1
  end
  s.good = s.confirmed + s.commanded
  s.bad = s.failed + s.unknown + s.superseded
  return s
end
M.summarize = summarize

function Tracker:_maybeDone(op)
  if op.done or not op.closed or op.pending > 0 then
    return
  end
  op.done = true
  op.finishedAt = self.deps.now()
  op.summary = summarize(op)
  self.deps.state:touch()
  if self.deps.onSettled then
    pcall(self.deps.onSettled, op)
  end
end

--- No more targets will be added.
function Tracker:close(op)
  op.closed = true
  self:_maybeDone(op)
end

--- A target refused before anything was sent. State is not touched.
function Tracker:reject(op, target, code, detail)
  local t = {
    kind = target.kind,
    id = target.id,
    name = target.name,
    field = target.field,
    status = "failed",
    errorCode = code,
    message = Errors.operatorText(code),
    detail = detail,
    sent = false,
  }
  op.targets[#op.targets + 1] = t
  if self.deps.onTarget then
    pcall(self.deps.onTarget, op, t)
  end
  return t
end

local function activeKey(action)
  return action.kind .. ":" .. action.id .. ":" .. action.field
end

function Tracker:_unwait(action)
  local roomId = action.confirm and action.confirm.roomId
  local list = roomId and self.waiting[roomId]
  if list then
    for i, a in ipairs(list) do
      if a == action then
        table.remove(list, i)
        break
      end
    end
    if #list == 0 then
      self.waiting[roomId] = nil
    end
  end
end

function Tracker:_settle(action, outcome, code, detail, actual)
  if action.settled then
    return
  end
  action.settled = true
  self:_unwait(action)
  local key = activeKey(action)
  if self.active[key] == action then
    self.active[key] = nil
  end
  local t = action.target
  t.status = outcome
  t.errorCode = code
  t.message = code and Errors.operatorText(code) or nil
  t.detail = detail
  local state = self.deps.state
  local extra = { operationId = action.op.id }
  if outcome == "confirmed" then
    state:set(action.kind, action.id, action.field, action.desired, "confirmed", extra)
  elseif outcome == "commanded" then
    state:set(action.kind, action.id, action.field, action.desired, "commanded", extra)
  elseif outcome == "unknown" then
    extra.errorCode = code
    extra.requested = action.desired
    state:set(action.kind, action.id, action.field, action.desired, "unknown", extra)
  elseif outcome == "failed" then
    extra.errorCode = code
    extra.requested = action.desired
    local value = actual
    if value == nil then
      value = action.previous and action.previous.value
    end
    state:set(action.kind, action.id, action.field, value, "failed", extra)
  end
  -- superseded: the newer action already owns the cell.
  if self.deps.onTarget then
    pcall(self.deps.onTarget, action.op, t)
  end
  action.op.pending = action.op.pending - 1
  self:_maybeDone(action.op)
  -- Older requests for the SAME value were folded into this one: they end
  -- the way it ended (their own operations report it; the cell is this
  -- action's alone).
  local followers = action.followers
  action.followers = nil
  for _, f in ipairs(followers or {}) do
    self:_settleFollower(f, outcome, code, detail)
  end
end

--- Ends a folded request without touching state.
function Tracker:_settleFollower(action, outcome, code, detail)
  if action.settled then
    return
  end
  action.settled = true
  local t = action.target
  t.status = outcome
  t.errorCode = code
  t.message = code and Errors.operatorText(code) or nil
  t.detail = detail
  if self.deps.onTarget then
    pcall(self.deps.onTarget, action.op, t)
  end
  action.op.pending = action.op.pending - 1
  self:_maybeDone(action.op)
  for _, f in ipairs(action.followers or {}) do
    self:_settleFollower(f, outcome, code, detail)
  end
  action.followers = nil
end

function Tracker:_checkNow(action, final)
  local adapter = self.deps.adapter()
  local ok, room = pcall(adapter.readRoom, action.confirm.roomId)
  if not ok or type(room) ~= "table" then
    if final then
      self:_settle(action, "unknown", "VF_NOT_CONFIRMED", "the room could not be read back")
    end
    return
  end
  if action.confirm.matches(room) then
    self:_settle(action, "confirmed")
  elseif final then
    local actual = action.confirm.actual and action.confirm.actual(room) or nil
    self:_settle(
      action,
      "failed",
      "VF_NOT_CONFIRMED",
      "requested " .. tostring(action.confirm.want) .. ", Control4 reports " .. tostring(action.confirm.describe(room)),
      actual
    )
  end
end

--- ONE timer watches every action awaiting feedback (a 24-display scene must
--- not create 24 timers: how many a driver may hold is not documented).
function Tracker:_armSweep()
  if self.sweeping then
    return
  end
  self.sweeping = true
  self.deps.timers.set(M.SWEEP_TIMER, 1000, function()
    self.sweeping = false
    self:_sweep()
  end)
end

function Tracker:_sweep()
  local now = self.deps.now()
  local due, remaining = {}, false
  for _, list in pairs(self.waiting) do
    for _, action in ipairs(list) do
      if action.deadline ~= nil and now >= action.deadline then
        due[#due + 1] = action
      else
        remaining = true
      end
    end
  end
  table.sort(due, function(a, b)
    return a.seq < b.seq
  end)
  for _, action in ipairs(due) do
    self:_checkNow(action, true)
  end
  if remaining then
    self:_armSweep()
  end
end

function Tracker:_dispatch(action)
  if action.settled then
    return
  end
  local adapter = self.deps.adapter()
  local okCall, ok, err = pcall(action.dispatch, adapter)
  if not okCall then
    self:_settle(action, "failed", "VF_DISPATCH_FAILED", tostring(ok))
    return
  end
  if not ok then
    local code = err == "offline" and "VF_DEVICE_OFFLINE" or "VF_DISPATCH_FAILED"
    self:_settle(action, "failed", code, tostring(err or "the adapter refused the command"))
    return
  end
  action.target.sent = true
  if action.confirm == nil then
    self:_settle(action, "commanded")
    return
  end
  local roomId = action.confirm.roomId
  self.waiting[roomId] = self.waiting[roomId] or {}
  table.insert(self.waiting[roomId], action)
  action.deadline = self.deps.now() + math.ceil(self.confirmMs / 1000)
  self:_armSweep()
  -- A room already in the requested state confirms at once.
  self:_checkNow(action, false)
end

--- action = {
---   kind, id, name, field, desired,
---   dispatch = function(adapter) -> ok, err,
---   confirm  = nil | { roomId, want, matches(room) -> bool, describe(room) -> text, actual(room) -> state value }
--- }
function Tracker:submit(op, action)
  local state = self.deps.state
  action.op = op
  self.seq = self.seq + 1
  action.seq = self.seq
  local key = activeKey(action)
  local older = self.active[key]
  if older ~= nil then
    if older.desired == action.desired then
      -- The same value asked for again (a scene and the rule it triggered
      -- both route signage to one display): not a conflict. The older
      -- request follows this one and ends the way this one ends.
      self:_unwait(older)
      older.following = true
      action.followers = older.followers or {}
      older.followers = nil
      action.followers[#action.followers + 1] = older
    else
      self:_settle(older, "superseded", "VF_SUPERSEDED", "replaced by " .. op.id)
    end
  end
  local cell = state:cell(action.kind, action.id, action.field)
  action.previous = cell and U.copy(cell) or nil
  local t = {
    kind = action.kind,
    id = action.id,
    name = action.name,
    field = action.field,
    status = "pending",
    sent = false,
  }
  action.target = t
  op.targets[#op.targets + 1] = t
  op.pending = op.pending + 1
  self.active[key] = action
  state:set(action.kind, action.id, action.field, action.desired, "pending", { operationId = op.id })
  self.deps.queue:enqueue({
    key = key,
    run = function()
      if not action.following then
        self:_dispatch(action)
      end
    end,
    superseded = function()
      if not action.following then
        self:_settle(action, "superseded", "VF_SUPERSEDED", "replaced before it was sent")
      end
    end,
    failed = function(err)
      self:_settle(action, "failed", "VF_INTERNAL", tostring(err))
    end,
  })
  return t
end

--- Whether a cell is owned by an unfinished action (feedback for it must not
--- be applied as passive state).
function Tracker:isActive(kind, id, field)
  return self.active[kind .. ":" .. id .. ":" .. field] ~= nil
end

--- Control4 reported a change in a room: confirm anything waiting on it.
function Tracker:roomChanged(roomId)
  local list = self.waiting[roomId]
  if list == nil then
    return
  end
  for _, action in ipairs({ unpack(list) }) do
    self:_checkNow(action, false)
  end
end

--- Abandons everything in flight (configuration replaced, driver stopping).
function Tracker:cancelAll(code)
  for _, key in ipairs(U.sortedKeys(self.active)) do
    local action = self.active[key]
    if action ~= nil then
      self:_settle(action, "superseded", code or "VF_CANCELLED", "cancelled")
    end
  end
end

function M.publicOp(op, includeDetail)
  local out = {
    id = op.id,
    kind = op.kind,
    label = op.label,
    origin = op.origin,
    startedAt = op.startedAt,
    finishedAt = op.finishedAt,
    done = op.done,
    summary = op.summary or summarize(op),
    targets = {},
  }
  for i, t in ipairs(op.targets) do
    out.targets[i] = {
      kind = t.kind,
      id = t.id,
      name = t.name,
      field = t.field,
      status = t.status,
      errorCode = t.errorCode,
      message = t.message,
      detail = includeDetail and t.detail or nil,
    }
  end
  return out
end

function Tracker:find(id)
  for _, op in ipairs(self.ops) do
    if op.id == id then
      return op
    end
  end
  return nil
end

function Tracker:recent(limit, includeDetail)
  local out = {}
  for i = 1, math.min(limit or 12, #self.ops) do
    out[i] = M.publicOp(self.ops[i], includeDetail)
  end
  return out
end

return M
