--- Logic Pack — the primitives engine (pure, injected clock and timers).
---
--- Composer programming lacks the small things every other automation
--- language has: a counter, a flag, a state name, "only once per day",
--- "wait until it has been quiet for 2 s", "at most once a minute", a
--- cancellable timer. This module is those, keyed by a short name the
--- programmer types (the Flight Recorder's channel idea): one driver
--- instance, any number of independent keys, all persisted.
---
--- Rules a programmer relies on:
---   • KEYS are normalised (trimmed, lower-cased, non-alphanumerics → "_",
---     ≤ 40 chars) so "Good Night" and "good_night" are the same key. An
---     empty key is refused, never silently mapped to a default.
---   • COUNTERS are integers bounded to ±1,000,000,000; increments by zero or
---     non-numbers are refused. A change reports the new value.
---   • FLAGS are booleans; toggling an unset flag sets it.
---   • STATE is one string (≤ 60 chars); setting the same state again is not
---     a change and fires nothing.
---   • DEBOUNCE(key, ms) restarts the key's quiet timer; the trigger fires
---     once when the key has been quiet for ms. ms = 0 fires at once.
---   • THROTTLE(key, ms) fires at once if the key has not fired within ms,
---     otherwise it is suppressed and counted. No trailing call.
---   • ONCE_PER_DAY(key) passes the first time per LOCAL calendar day
---     (the injected localDay function decides the day); later calls that
---     day are refused and counted. The day rolls at local midnight, not
---     24 h after the last pass.
---   • TIMERS: start(key, seconds) (re)arms; cancel stops silently; an
---     expired timer fires exactly once. On restore, a timer whose expiry
---     passed while the driver was down fires immediately, marked late; a
---     timer still in the future is re-armed with its remaining time.
---   • READ-ONLY: when the licence halts the pack, every mutating call is
---     refused with "read-only" and nothing changes; reads still answer.
---   • BOUNDS: at most 200 keys per kind; beyond that a new key is refused.
---
--- deps = { now = fn():seconds, schedule = fn(id, ms, fn), cancel = fn(id),
---          emit = fn(kind, fields), localDay = fn(seconds):string "YYYY-MM-DD" }

local M = {}

M.LIMITS = {
  key = 40,
  state = 60,
  keys_per_kind = 200,
  counter_abs = 1000000000,
  ms_max = 3600000,
  timer_seconds_max = 7 * 86400,
  transitions = 10,
}

--- Normalises a programmer-typed key. nil when empty.
function M.key(raw)
  local s = tostring(raw or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
  s = s:gsub("[^%w]+", "_"):gsub("^_+", ""):gsub("_+$", "")
  if s == "" then
    return nil
  end
  return s:sub(1, M.LIMITS.key)
end

--- Director's LOGIC vocabulary for NUMBER/STRING conditionals.
function M.compare(logic, actual, expected)
  logic = tostring(logic or "EQUAL"):upper()
  if logic == "EQUAL" then
    return actual == expected
  elseif logic == "NOT_EQUAL" then
    return actual ~= expected
  end
  local a, b = tonumber(actual), tonumber(expected)
  if a == nil or b == nil then
    return false
  end
  if logic == "LESS_THAN" then
    return a < b
  elseif logic == "LESS_THAN_OR_EQUAL" then
    return a <= b
  elseif logic == "GREATER_THAN" then
    return a > b
  elseif logic == "GREATER_THAN_OR_EQUAL" then
    return a >= b
  end
  return false
end

local Engine = {}
Engine.__index = Engine

function M.new(deps)
  local self = setmetatable({}, Engine)
  self.deps = deps
  self.readOnly = false
  self.counters = {}
  self.flags = {}
  self.state = ""
  self.previousState = ""
  self.transitions = {}
  self.once = {} -- key -> "YYYY-MM-DD"
  self.throttleLast = {} -- key -> seconds
  self.debouncePending = {} -- key -> true
  self.timers = {} -- key -> { expires_at = seconds, seconds = n }
  self.counts = {
    counter_changes = 0,
    flag_changes = 0,
    state_changes = 0,
    debounce_calls = 0,
    debounce_fired = 0,
    throttle_fired = 0,
    throttle_suppressed = 0,
    once_passed = 0,
    once_refused = 0,
    timers_started = 0,
    timers_expired = 0,
    timers_cancelled = 0,
    refused = 0,
  }
  return self
end

local function countKeys(t)
  local n = 0
  for _ in pairs(t) do
    n = n + 1
  end
  return n
end

function Engine:_refuse(reason)
  self.counts.refused = self.counts.refused + 1
  return false, reason
end

function Engine:_guard(raw, kind)
  if self.readOnly then
    return nil, "read-only"
  end
  local key = M.key(raw)
  if key == nil then
    return nil, "empty key"
  end
  if kind ~= nil and kind[key] == nil and countKeys(kind) >= M.LIMITS.keys_per_kind then
    return nil, "too many keys"
  end
  return key
end

function Engine:setReadOnly(flag)
  self.readOnly = flag == true
end

-- ── Counters ────────────────────────────────────────────────────────────────

function Engine:_setCounter(key, value)
  if value > M.LIMITS.counter_abs then
    value = M.LIMITS.counter_abs
  elseif value < -M.LIMITS.counter_abs then
    value = -M.LIMITS.counter_abs
  end
  if self.counters[key] == value then
    return true, value
  end
  self.counters[key] = value
  self.counts.counter_changes = self.counts.counter_changes + 1
  self.deps.emit("counter", { key = key, value = value })
  return true, value
end

function Engine:increment(raw, by)
  local key, why = self:_guard(raw, self.counters)
  if key == nil then
    return self:_refuse(why)
  end
  local n = tonumber(by)
  if by == nil or by == "" then
    n = 1
  end
  if n == nil or n ~= math.floor(n) then
    return self:_refuse("BY must be an integer")
  end
  return self:_setCounter(key, (self.counters[key] or 0) + n)
end

function Engine:decrement(raw, by)
  local n = tonumber(by)
  if by == nil or by == "" then
    n = 1
  end
  if n == nil then
    return self:_refuse("BY must be an integer")
  end
  return self:increment(raw, -n)
end

function Engine:setCounter(raw, value)
  local key, why = self:_guard(raw, self.counters)
  if key == nil then
    return self:_refuse(why)
  end
  local n = tonumber(value)
  if n == nil or n ~= math.floor(n) then
    return self:_refuse("VALUE must be an integer")
  end
  return self:_setCounter(key, n)
end

function Engine:resetCounter(raw)
  return self:setCounter(raw, 0)
end

function Engine:counter(raw)
  local key = M.key(raw)
  return key and self.counters[key] or 0
end

-- ── Flags ───────────────────────────────────────────────────────────────────

function Engine:_setFlag(key, value)
  if (self.flags[key] == true) == value then
    return true, value
  end
  if value then
    self.flags[key] = true
  else
    self.flags[key] = nil
  end
  self.counts.flag_changes = self.counts.flag_changes + 1
  self.deps.emit("flag", { key = key, value = value })
  return true, value
end

function Engine:setFlag(raw)
  local key, why = self:_guard(raw, self.flags)
  if key == nil then
    return self:_refuse(why)
  end
  return self:_setFlag(key, true)
end

function Engine:clearFlag(raw)
  local key, why = self:_guard(raw)
  if key == nil then
    return self:_refuse(why)
  end
  return self:_setFlag(key, false)
end

function Engine:toggleFlag(raw)
  local key, why = self:_guard(raw, self.flags)
  if key == nil then
    return self:_refuse(why)
  end
  return self:_setFlag(key, not (self.flags[key] == true))
end

function Engine:flag(raw)
  local key = M.key(raw)
  return key ~= nil and self.flags[key] == true
end

-- ── State machine ───────────────────────────────────────────────────────────

function Engine:setState(raw)
  if self.readOnly then
    return self:_refuse("read-only")
  end
  local name = tostring(raw or ""):gsub("^%s+", ""):gsub("%s+$", ""):sub(1, M.LIMITS.state)
  if name == "" then
    return self:_refuse("empty state")
  end
  if name == self.state then
    return true, false
  end
  self.previousState = self.state
  self.state = name
  self.counts.state_changes = self.counts.state_changes + 1
  table.insert(self.transitions, 1, { at = self.deps.now(), from = self.previousState, to = name })
  while #self.transitions > M.LIMITS.transitions do
    table.remove(self.transitions)
  end
  self.deps.emit("state", { state = name, previous = self.previousState })
  return true, true
end

function Engine:stateIs(raw)
  return self.state == tostring(raw or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

-- ── Debounce / throttle ─────────────────────────────────────────────────────

local function boundedMs(ms)
  local n = tonumber(ms)
  if n == nil or n < 0 then
    return nil
  end
  return math.min(math.floor(n), M.LIMITS.ms_max)
end

function Engine:debounce(raw, ms)
  local key, why = self:_guard(raw, self.debouncePending)
  if key == nil then
    return self:_refuse(why)
  end
  local delay = boundedMs(ms)
  if delay == nil then
    return self:_refuse("MILLISECONDS must be 0 or more")
  end
  self.counts.debounce_calls = self.counts.debounce_calls + 1
  local fire = function()
    self.debouncePending[key] = nil
    self.counts.debounce_fired = self.counts.debounce_fired + 1
    self.deps.emit("debounced", { key = key })
  end
  if delay == 0 then
    self.deps.cancel("lp:d:" .. key)
    fire()
    return true
  end
  self.debouncePending[key] = true
  self.deps.schedule("lp:d:" .. key, delay, fire)
  return true
end

function Engine:throttle(raw, ms)
  local key, why = self:_guard(raw, self.throttleLast)
  if key == nil then
    return self:_refuse(why)
  end
  local window = boundedMs(ms)
  if window == nil then
    return self:_refuse("MILLISECONDS must be 0 or more")
  end
  local now = self.deps.now()
  local last = self.throttleLast[key]
  if last ~= nil and (now - last) * 1000 < window then
    self.counts.throttle_suppressed = self.counts.throttle_suppressed + 1
    return true, false
  end
  self.throttleLast[key] = now
  self.counts.throttle_fired = self.counts.throttle_fired + 1
  self.deps.emit("throttled", { key = key })
  return true, true
end

-- ── Once per day ────────────────────────────────────────────────────────────

function Engine:oncePerDay(raw)
  local key, why = self:_guard(raw, self.once)
  if key == nil then
    return self:_refuse(why)
  end
  local today = self.deps.localDay(self.deps.now())
  if self.once[key] == today then
    self.counts.once_refused = self.counts.once_refused + 1
    return true, false
  end
  self.once[key] = today
  self.counts.once_passed = self.counts.once_passed + 1
  self.deps.emit("once_per_day", { key = key, day = today })
  return true, true
end

function Engine:onceDoneToday(raw)
  local key = M.key(raw)
  return key ~= nil and self.once[key] == self.deps.localDay(self.deps.now())
end

--- Forgets passes from earlier days (keeps the table small).
function Engine:pruneOnce()
  local today = self.deps.localDay(self.deps.now())
  for key, day in pairs(self.once) do
    if day ~= today then
      self.once[key] = nil
    end
  end
end

-- ── Timers ──────────────────────────────────────────────────────────────────

function Engine:_armTimer(key, remainingSeconds, late)
  self.deps.schedule("lp:t:" .. key, math.max(0, math.floor(remainingSeconds * 1000)), function()
    local t = self.timers[key]
    self.timers[key] = nil
    if t ~= nil then
      self.counts.timers_expired = self.counts.timers_expired + 1
      self.deps.emit("timer_expired", { key = key, seconds = t.seconds, late = late == true })
    end
  end)
end

function Engine:startTimer(raw, seconds)
  local key, why = self:_guard(raw, self.timers)
  if key == nil then
    return self:_refuse(why)
  end
  local n = tonumber(seconds)
  if n == nil or n <= 0 then
    return self:_refuse("SECONDS must be more than 0")
  end
  n = math.min(n, M.LIMITS.timer_seconds_max)
  self.timers[key] = { expires_at = self.deps.now() + n, seconds = n }
  self.counts.timers_started = self.counts.timers_started + 1
  self:_armTimer(key, n, false)
  return true
end

function Engine:cancelTimer(raw)
  local key, why = self:_guard(raw)
  if key == nil then
    return self:_refuse(why)
  end
  if self.timers[key] == nil then
    return true, false
  end
  self.timers[key] = nil
  self.deps.cancel("lp:t:" .. key)
  self.counts.timers_cancelled = self.counts.timers_cancelled + 1
  return true, true
end

function Engine:timerRunning(raw)
  local key = M.key(raw)
  return key ~= nil and self.timers[key] ~= nil
end

function Engine:timerRemaining(raw)
  local key = M.key(raw)
  local t = key and self.timers[key]
  if t == nil then
    return nil
  end
  return math.max(0, t.expires_at - self.deps.now())
end

-- ── Reset / persistence ─────────────────────────────────────────────────────

function Engine:resetAll(what)
  if self.readOnly then
    return self:_refuse("read-only")
  end
  what = what or "everything"
  if what == "counters" or what == "everything" then
    for key in pairs(self.counters) do
      self:_setCounter(key, 0)
    end
    self.counters = {}
  end
  if what == "flags" or what == "everything" then
    for key in pairs(self.flags) do
      self:_setFlag(key, false)
    end
  end
  if what == "timers" or what == "everything" then
    for key in pairs(self.timers) do
      self.deps.cancel("lp:t:" .. key)
      self.counts.timers_cancelled = self.counts.timers_cancelled + 1
    end
    self.timers = {}
    for key in pairs(self.debouncePending) do
      self.deps.cancel("lp:d:" .. key)
    end
    self.debouncePending = {}
  end
  if what == "everything" then
    self.once = {}
    self.throttleLast = {}
    if self.state ~= "" then
      self.previousState = self.state
      self.state = ""
      self.deps.emit("state", { state = "", previous = self.previousState })
    end
  end
  return true
end

function Engine:serialize()
  local timers = {}
  for key, t in pairs(self.timers) do
    timers[key] = { expires_at = t.expires_at, seconds = t.seconds }
  end
  return {
    v = 1,
    counters = self.counters,
    flags = self.flags,
    state = self.state,
    previous_state = self.previousState,
    once = self.once,
    throttle_last = self.throttleLast,
    timers = timers,
  }
end

--- Restores a persisted document. Timers past due fire at once (late);
--- the rest are re-armed. Debounces are not restored (a quiet period that
--- spanned a restart has, by definition, passed).
function Engine:restore(doc)
  if type(doc) ~= "table" then
    return false
  end
  local function copyStrKeyed(t, valueOk)
    local out = {}
    for k, v in pairs(type(t) == "table" and t or {}) do
      local key = M.key(k)
      if key ~= nil and valueOk(v) then
        out[key] = v
      end
    end
    return out
  end
  self.counters = copyStrKeyed(doc.counters, function(v)
    return type(v) == "number"
  end)
  self.flags = copyStrKeyed(doc.flags, function(v)
    return v == true
  end)
  self.once = copyStrKeyed(doc.once, function(v)
    return type(v) == "string"
  end)
  self.throttleLast = copyStrKeyed(doc.throttle_last, function(v)
    return type(v) == "number"
  end)
  self.state = type(doc.state) == "string" and doc.state:sub(1, M.LIMITS.state) or ""
  self.previousState = type(doc.previous_state) == "string" and doc.previous_state or ""
  self.timers = {}
  local now = self.deps.now()
  for k, t in pairs(type(doc.timers) == "table" and doc.timers or {}) do
    local key = M.key(k)
    if key ~= nil and type(t) == "table" and tonumber(t.expires_at) then
      self.timers[key] = { expires_at = tonumber(t.expires_at), seconds = tonumber(t.seconds) or 0 }
      local remaining = tonumber(t.expires_at) - now
      self:_armTimer(key, remaining > 0 and remaining or 0, remaining <= 0)
    end
  end
  return true
end

function Engine:stop()
  for key in pairs(self.timers) do
    self.deps.cancel("lp:t:" .. key)
  end
  for key in pairs(self.debouncePending) do
    self.deps.cancel("lp:d:" .. key)
  end
end

--- Sorted views for Print State.
function Engine:snapshot()
  local function sortedKeys(t)
    local keys = {}
    for k in pairs(t) do
      keys[#keys + 1] = k
    end
    table.sort(keys)
    return keys
  end
  local counters, flags, timers = {}, {}, {}
  for _, k in ipairs(sortedKeys(self.counters)) do
    counters[#counters + 1] = { key = k, value = self.counters[k] }
  end
  for _, k in ipairs(sortedKeys(self.flags)) do
    flags[#flags + 1] = k
  end
  for _, k in ipairs(sortedKeys(self.timers)) do
    timers[#timers + 1] = { key = k, remaining = self:timerRemaining(k), seconds = self.timers[k].seconds }
  end
  local once = {}
  for _, k in ipairs(sortedKeys(self.once)) do
    once[#once + 1] = { key = k, day = self.once[k] }
  end
  return {
    state = self.state,
    previous_state = self.previousState,
    transitions = self.transitions,
    counters = counters,
    flags = flags,
    timers = timers,
    once = once,
    counts = self.counts,
    read_only = self.readOnly,
  }
end

return M
