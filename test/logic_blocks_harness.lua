-- Shared stand-ins for the Logic Blocks suites: a simulated clock, timers,
-- calendar and a recording sink, so the pure runtime runs with no controller.
local H = {}

function H.checker()
  local c = { pass = 0, fail = 0 }
  function c.check(name, ok, detail)
    if ok then
      c.pass = c.pass + 1
      print("  ok   " .. name)
    else
      c.fail = c.fail + 1
      print("  FAIL " .. name .. (detail ~= nil and ("  -> " .. tostring(detail)) or ""))
    end
  end
  function c.finish()
    print(string.format("\n%d passed, %d failed", c.pass, c.fail))
    if c.fail > 0 then
      os.exit(1)
    end
  end
  return c
end

--- A world: clock, timers, what was fired, what was written.
--- opts.localDay overrides the calendar; opts.watch decides listeners.
function H.world(opts)
  opts = opts or {}
  local w = {
    t = opts.start or 1800000000,
    timers = {},
    order = 0,
    fired = {}, -- "slot:kind" in order
    events = {}, -- { slot, kind, out = outputs at the moment it fired, entry }
    outs = {}, -- slot -> last outputs written
    writes = 0,
    changed = 0,
    refused = {},
    watched = {},
    unwatched = {},
    ids = 0,
    variables = opts.variables or {}, -- "dev:var" -> true when it exists
  }
  w.deps = {
    origin = opts.origin or "live",
    now = function()
      return w.t
    end,
    schedule = function(id, ms, fn)
      w.order = w.order + 1
      w.timers[id] = { at = w.t + ms / 1000, fn = fn, order = w.order }
    end,
    cancel = function(id)
      w.timers[id] = nil
    end,
    localDay = opts.localDay or function(t)
      return os.date("!%Y-%m-%d", math.floor(t))
    end,
    emit = function(slot, kind, entry)
      w.fired[#w.fired + 1] = slot .. ":" .. kind
      w.events[#w.events + 1] = { slot = slot, kind = kind, out = w.outs[slot], entry = entry }
      if w.onEmit ~= nil then
        w.onEmit(slot, kind, entry)
      end
    end,
    outputs = function(slot, out)
      w.writes = w.writes + 1
      w.outs[slot] = { active = out.active, valid = out.valid, value = out.value, state = out.state }
    end,
    watch = function(dev, var)
      local k = dev .. ":" .. var
      if opts.variables ~= nil and not w.variables[k] then
        return false, "variable " .. var .. " is not on device " .. dev
      end
      w.watched[#w.watched + 1] = k
      return true
    end,
    unwatch = function(dev, var)
      w.unwatched[#w.unwatched + 1] = dev .. ":" .. var
    end,
    newId = function()
      w.ids = w.ids + 1
      return "id" .. w.ids
    end,
    changed = function()
      w.changed = w.changed + 1
    end,
    refused = function(slot, what, why)
      w.refused[#w.refused + 1] = { slot = slot, what = what, why = why }
    end,
    selfDevice = opts.selfDevice,
  }
  --- Runs the timers that fall due in the next `seconds`, in order.
  function w.advance(seconds)
    local target = w.t + seconds
    while true do
      local bestId, best
      for id, timer in pairs(w.timers) do
        if
          timer.at <= target
          and (best == nil or timer.at < best.at or (timer.at == best.at and timer.order < best.order))
        then
          bestId, best = id, timer
        end
      end
      if bestId == nil then
        break
      end
      w.t = math.max(w.t, best.at)
      w.timers[bestId] = nil
      best.fn()
    end
    w.t = target
  end
  function w.count(pattern)
    local n = 0
    for _, f in ipairs(w.fired) do
      if f == pattern then
        n = n + 1
      end
    end
    return n
  end
  function w.clear()
    w.fired, w.events, w.refused = {}, {}, {}
  end
  function w.firedText()
    return table.concat(w.fired, " ")
  end
  function w.timerCount()
    local n = 0
    for _ in pairs(w.timers) do
      n = n + 1
    end
    return n
  end
  return w
end

--- Normalizes raw text and creates the block; fails loudly when invalid.
function H.make(blocks, raw)
  local Defs = require("logic.blockdefs")
  local def, problems = Defs.normalize(raw)
  if def == nil then
    error("invalid block: " .. table.concat(problems, "; "), 2)
  end
  local slot, why = blocks:create(def)
  if slot == nil then
    error("not created: " .. tostring(why), 2)
  end
  return slot
end

function H.last(blocks)
  return blocks.history[#blocks.history]
end

return H
