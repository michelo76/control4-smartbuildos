--- VenueFlow: command serialisation (pure).
---
--- Every command to Control4 goes through one queue:
---   * commands leave one at a time, `spacingMs` apart, so a 24-display scene
---     does not hand Director 24 commands in one instant;
---   * a command still WAITING is replaced by a newer one with the same key
---     (the same display and field): the older one is told it was superseded
---     and is never sent. Two people pressing different sources for one TV
---     end with one command, not a race.

local M = {}

local Queue = {}
Queue.__index = Queue

--- deps = { timers = { set(id, ms, fn), cancel(id) }, spacingMs = 120, name = "VfQueue" }
function M.new(deps)
  local self = setmetatable({}, Queue)
  self.timers = deps.timers
  self.spacingMs = deps.spacingMs or 120
  self.timerId = deps.name or "VfQueue"
  self.waiting = {} -- ordered jobs
  self.cooling = false
  return self
end

function Queue:size()
  return #self.waiting
end

local function run(job)
  local ok, err = pcall(job.run)
  if not ok and job.failed then
    pcall(job.failed, err)
  end
end

function Queue:_arm()
  if self.spacingMs <= 0 then
    return
  end
  self.cooling = true
  self.timers.set(self.timerId, self.spacingMs, function()
    self.cooling = false
    self:_pump()
  end)
end

function Queue:_pump()
  while not self.cooling and #self.waiting > 0 do
    local job = table.remove(self.waiting, 1)
    self:_arm()
    run(job)
  end
end

--- job = { key, run = fn, superseded = fn?, failed = fn(err)? }
function Queue:enqueue(job)
  if job.key ~= nil then
    for i, other in ipairs(self.waiting) do
      if other.key == job.key then
        table.remove(self.waiting, i)
        if other.superseded then
          pcall(other.superseded)
        end
        break
      end
    end
  end
  self.waiting[#self.waiting + 1] = job
  self:_pump()
end

--- Drops everything still waiting (used when a configuration is replaced).
function Queue:clear()
  local dropped = self.waiting
  self.waiting = {}
  for _, job in ipairs(dropped) do
    if job.superseded then
      pcall(job.superseded)
    end
  end
  return #dropped
end

function Queue:stop()
  self:clear()
  pcall(self.timers.cancel, self.timerId)
  self.cooling = false
end

return M
