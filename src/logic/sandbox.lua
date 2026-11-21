--- Logic Blocks — the test sandbox (pure, and deliberately blind).
---
--- A sandbox is a SECOND block runtime holding a copy of one block's
--- settings, with its own clock, its own timers and its own event sink. It
--- is built from plain data: it is never handed the live runtime, the
--- driver's event or variable functions, a listener or the persist store.
--- That is the isolation, and it is structural: there is nothing in here
--- that could fire a Composer event, send a device command, change live
--- state or write to storage, whatever the page or a caller does.
---
--- Time is simulated and deterministic: advance(seconds) runs the timers
--- that fall due, in order, and nothing else moves the clock. The same
--- steps always give the same timeline; replay() proves it.
---
--- opts = {
---   def      = a COPY of the block definition (settings only, no state)
---   slot     = the slot number, kept so labels match the live block
---   now      = seconds: where the simulated clock starts
---   localDay = fn(seconds): "YYYY-MM-DD" (a pure function of the time)
---   sources  = { [index] = value } opening values for mapped inputs
--- }

local Blocks = require("logic.blocks")
local Defs = require("logic.blockdefs")

local M = {}

M.LIMITS = {
  advance_s = 7 * 86400, -- one advance
  timers_per_advance = 2000,
  steps = 200, -- remembered steps (and the longest replay)
  timeline = 400,
}

local Sandbox = {}
Sandbox.__index = Sandbox

local function build(self)
  local opts = self.opts
  self.clock = opts.now
  self.timers = {}
  self.timeline = {}
  self.order = 0
  self.out = nil
  local ids = 0
  local rt = Blocks.new({
    origin = "sim",
    now = function()
      return self.clock
    end,
    schedule = function(id, ms, fn)
      self.order = self.order + 1
      self.timers[id] = { at = self.clock + ms / 1000, fn = fn, order = self.order }
    end,
    cancel = function(id)
      self.timers[id] = nil
    end,
    localDay = opts.localDay,
    emit = function(slot, kind, record)
      self.timeline[#self.timeline + 1] = {
        at = self.clock,
        offset = self.clock - opts.now,
        kind = "event",
        event = Defs.eventName(slot, kind),
        event_kind = kind,
        seq = record.seq,
      }
    end,
    outputs = function(_, out)
      self.out = out
    end,
    -- Nothing is ever watched: a mapped input is fed by source() only.
    watch = function()
      return true
    end,
    unwatch = function() end,
    newId = function()
      ids = ids + 1
      return "sim-" .. ids
    end,
    changed = function() end,
    refused = function() end,
  })
  local def = Blocks.copy(opts.def)
  def.id = def.id or "sim-block"
  def.enabled = true
  rt:restore({
    schema = Blocks.SCHEMA,
    v = Blocks.VERSION,
    blocks = { [Blocks.key(opts.slot)] = def },
    rt = {},
  })
  self.rt = rt
  self.seen = #rt.history
  for index, value in pairs(opts.sources or {}) do
    local input
    for _, candidate in ipairs(def.inputs or {}) do
      if candidate.index == index then
        input = candidate
      end
    end
    if input ~= nil and input.device_id ~= nil then
      rt:variable(input.device_id, input.variable_id, value)
    end
  end
  self:_collect("open")
end

--- Opens a sandbox. Returns sandbox, or nil and why.
function M.open(opts)
  if type(opts) ~= "table" or type(opts.def) ~= "table" then
    return nil, "no block to copy"
  end
  local ok, why = Defs.wellFormed(opts.def)
  if not ok then
    return nil, "the block's settings cannot be read: " .. tostring(why)
  end
  local self = setmetatable({}, Sandbox)
  self.opts = {
    def = Blocks.copy(opts.def),
    slot = tonumber(opts.slot) or 1,
    now = math.floor(tonumber(opts.now) or 0),
    localDay = opts.localDay,
    sources = Blocks.copy(opts.sources or {}),
  }
  self.steps = {}
  build(self)
  return self
end

--- Moves decisions made since the last step into the timeline.
function Sandbox:_collect(step)
  local history = self.rt.history
  for i = self.seen + 1, #history do
    local e = history[i]
    self.timeline[#self.timeline + 1] = {
      at = e.at,
      offset = e.at - self.opts.now,
      kind = "decision",
      step = step,
      input = e.input,
      decision = e.decision,
      reason = e.reason,
      events = e.events,
      seq = e.seq,
    }
  end
  self.seen = #history
  table.sort(self.timeline, function(a, b)
    if a.seq ~= b.seq then
      return (a.seq or 0) < (b.seq or 0)
    end
    return a.kind == "decision" and b.kind ~= "decision"
  end)
  while #self.timeline > M.LIMITS.timeline do
    table.remove(self.timeline, 1)
  end
end

function Sandbox:_remember(step)
  self.steps[#self.steps + 1] = step
  while #self.steps > M.LIMITS.steps do
    table.remove(self.steps, 1)
  end
end

local function run(self, step)
  if step.op == "input" then
    local args = { VALUE = step.value, BY = step.by, INPUT = step.input }
    local ok, info = self.rt:input(self.opts.slot, tostring(step.command or ""), args)
    self:_collect("input")
    return ok, info
  elseif step.op == "source" then
    local index = tonumber(step.index) or 1
    local input
    for _, candidate in ipairs(self.opts.def.inputs or {}) do
      if candidate.index == index then
        input = candidate
      end
    end
    if input == nil then
      return false, "that input is not configured"
    end
    if input.device_id ~= nil then
      if step.unavailable then
        self.rt:variableLost(input.device_id, input.variable_id, "simulated: the variable is gone")
      else
        self.rt:variable(input.device_id, input.variable_id, step.value)
      end
    elseif step.unavailable then
      self.rt:input(self.opts.slot, "input_unavailable", { INPUT = tostring(index) })
    else
      self.rt:input(self.opts.slot, "input", { INPUT = tostring(index), VALUE = step.value })
    end
    self:_collect("source")
    return true
  elseif step.op == "advance" then
    local seconds = tonumber(step.seconds)
    if seconds == nil or seconds < 0 or seconds ~= seconds then
      return false, "seconds must be 0 or more"
    end
    seconds = math.min(seconds, M.LIMITS.advance_s)
    local target = self.clock + seconds
    local ran = 0
    while ran < M.LIMITS.timers_per_advance do
      local bestId, best
      for id, t in pairs(self.timers) do
        if t.at <= target and (best == nil or t.at < best.at or (t.at == best.at and t.order < best.order)) then
          bestId, best = id, t
        end
      end
      if bestId == nil then
        break
      end
      self.clock = math.max(self.clock, best.at)
      self.timers[bestId] = nil
      best.fn()
      ran = ran + 1
    end
    self.clock = target
    self.rt:tick(nil)
    self:_collect("advance")
    return true, ran
  end
  return false, "unknown step"
end

--- Sends a block command (trigger, start, set, …) to the simulated block.
function Sandbox:input(command, args)
  args = args or {}
  local step = { op = "input", command = command, value = args.VALUE, by = args.BY, input = args.INPUT }
  self:_remember(step)
  return run(self, step)
end

--- Feeds input `index` a value (or marks it unreadable).
function Sandbox:source(index, value, unavailable)
  local step = { op = "source", index = index, value = value, unavailable = unavailable == true }
  self:_remember(step)
  return run(self, step)
end

--- Moves simulated time forward; timers that fall due run in order.
function Sandbox:advance(seconds)
  local step = { op = "advance", seconds = seconds }
  self:_remember(step)
  return run(self, step)
end

--- Back to the moment the sandbox was opened. The steps are forgotten.
function Sandbox:reset()
  self.steps = {}
  build(self)
  return true
end

--- Resets and runs a list of steps. With no list it runs the steps taken
--- so far again, which must give the same timeline.
function Sandbox:replay(steps)
  local list = {}
  for i, step in ipairs(type(steps) == "table" and steps or self.steps) do
    if i > M.LIMITS.steps then
      break
    end
    if type(step) == "table" then
      list[#list + 1] = Blocks.copy(step)
    end
  end
  build(self)
  self.steps = {}
  for _, step in ipairs(list) do
    self:_remember(step)
    run(self, step)
  end
  return true, #list
end

--- Everything the page shows. Plain data.
function Sandbox:state()
  local slot = self.opts.slot
  local pending = {}
  for id, t in pairs(self.timers) do
    if id ~= "lb:drain" then
      pending[#pending + 1] = { at = t.at, in_seconds = math.max(0, t.at - self.clock) }
    end
  end
  table.sort(pending, function(a, b)
    return a.at < b.at
  end)
  return {
    simulated = true,
    slot = slot,
    started_at = self.opts.now,
    clock = self.clock,
    elapsed = self.clock - self.opts.now,
    day = self.opts.localDay and self.opts.localDay(self.clock) or nil,
    view = self.rt:view(slot),
    timeline = self.timeline,
    steps = self.steps,
    pending_timers = pending,
    notice = "Simulated. Nothing here fires a Composer event, sends a command or changes the live block.",
  }
end

return M
