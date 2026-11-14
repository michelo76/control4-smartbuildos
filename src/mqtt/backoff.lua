--- Reconnect backoff (pure). Doubles from `base` to `max` seconds with a small
--- jitter so a broker that restarts does not see every controller at once.
--- `rand` is injected (returns 0..1) so tests are exact.

local Backoff = {}
Backoff.__index = Backoff

local M = {}

--- @param opts table|nil { base = 2, max = 120, jitter = 0.2, rand = fn }
function M.new(opts)
  opts = opts or {}
  return setmetatable({
    base = opts.base or 2,
    max = opts.max or 120,
    jitter = opts.jitter == nil and 0.2 or opts.jitter,
    rand = opts.rand or math.random,
    attempts = 0,
  }, Backoff)
end

--- Seconds to wait before the next try. `permanent` (the broker refused our
--- credentials) jumps straight to the ceiling: hammering a login that is
--- wrong only fills the broker's log.
function Backoff:next(permanent)
  self.attempts = self.attempts + 1
  local delay = permanent and self.max or math.min(self.max, self.base * 2 ^ (self.attempts - 1))
  if self.jitter > 0 then
    delay = delay * (1 + self.jitter * self.rand())
  end
  return math.floor(delay * 10 + 0.5) / 10
end

function Backoff:reset()
  self.attempts = 0
end

return M
