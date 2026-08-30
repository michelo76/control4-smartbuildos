--- Sensor triggers and the condition engine.
---
--- The dangerous failure mode here is over-eagerness: one bouncing contact
--- flipping the house to Home ten times (spec §22, §76). Defences, in order:
---   * per-signal debounce (a repeat of the same raw event inside
---     debounce_s is ignored);
---   * multi-signal rules — a rule fires only when ALL its signals have been
---     seen inside its window (front door + disarm + motion, §23);
---   * conditions evaluated at fire time against live state;
---   * per-rule cooldown after firing;
---   * a global fire budget per minute as the last-ditch loop breaker (§77)
---     — automation that trips it is broken, and suppressing loudly beats
---     looping quietly.
---
--- The module never activates anything itself: it calls the injected `fire`
--- and the engine applies its own priority/cooldown ladder on top.

local M = {}

M.DEFAULT_DEBOUNCE_S = 2
M.DEFAULT_WINDOW_S = 120
M.DEFAULT_COOLDOWN_S = 60
M.GLOBAL_FIRES_PER_MINUTE = 6

local Triggers = {}
Triggers.__index = Triggers

--- @param deps table {
---   now = fn() -> epoch seconds,
---   activeModes = fn() -> {PRESENCE=id?, LIFESTYLE=id?},
---   resolve = fn(device_key) -> {vars, name, online} | nil,
---   localtime = fn(epoch) -> {hour, min, wday(1=Sun), ...},
---   fire = fn(rule, detail),        -- ask the engine to activate rule.mode_id
---   warn = fn(message) or nil,      -- loop-budget trips etc.
--- }
function M.new(deps)
  local self = setmetatable({}, Triggers)
  self.deps = deps
  self.rules = {}
  self.signalSeen = {} -- ruleId -> {signalIndex -> epoch}
  self.lastRaw = {} -- dedupe key -> epoch (debounce)
  self.lastFired = {} -- ruleId -> epoch (cooldown)
  self.fireLog = {} -- ring of recent fire epochs (global budget)
  return self
end

--- Load rules from config. Rule shape:
--- { id, mode_id, enabled,
---   signals = { {type="CONTACT_OPENED"|"CONTACT_CLOSED"|"MOTION"|"SECURITY_DISARMED"
---                    |"SECURITY_ARMED"|"LOCK_UNLOCKED"|"VARIABLE", device_key, variable?, value?}, ... },
---   conditions = { ... },  -- see evaluateCondition
---   window_s?, cooldown_s?, debounce_s? }
function Triggers:setRules(rules)
  self.rules = rules or {}
  self.signalSeen = {}
end

--- Feed a raw signal in. The driver translates hardware events
--- (ReceivedFromProxy OPENED, OnWatchedVariableChanged, …) into
--- {type, device_key, variable?, value?} and calls this.
function Triggers:onSignal(signal)
  local now = self.deps.now()
  for _, rule in ipairs(self.rules) do
    if rule.enabled ~= false then
      for index, want in ipairs(rule.signals or {}) do
        if self:_matches(want, signal) then
          local debounce = tonumber(rule.debounce_s) or M.DEFAULT_DEBOUNCE_S
          local rawKey = tostring(rule.id) .. "\0" .. index
          local last = self.lastRaw[rawKey]
          if last == nil or (now - last) >= debounce then
            self.lastRaw[rawKey] = now
            self.signalSeen[rule.id] = self.signalSeen[rule.id] or {}
            self.signalSeen[rule.id][index] = now
            self:_maybeFire(rule, now)
          end
        end
      end
    end
  end
end

function Triggers:_matches(want, signal)
  if want.type ~= signal.type then
    return false
  end
  if want.device_key and tostring(want.device_key) ~= tostring(signal.device_key) then
    return false
  end
  if want.type == "VARIABLE" then
    if want.variable ~= signal.variable then
      return false
    end
    if want.value ~= nil and tostring(want.value) ~= tostring(signal.value) then
      return false
    end
  end
  return true
end

function Triggers:_maybeFire(rule, now)
  local window = tonumber(rule.window_s) or M.DEFAULT_WINDOW_S
  local seen = self.signalSeen[rule.id] or {}
  for index = 1, #(rule.signals or {}) do
    local t = seen[index]
    if t == nil or (now - t) > window then
      return -- not all signals inside the window yet
    end
  end

  local cooldown = tonumber(rule.cooldown_s) or M.DEFAULT_COOLDOWN_S
  local last = self.lastFired[rule.id]
  if last and (now - last) < cooldown then
    return
  end

  for _, cond in ipairs(rule.conditions or {}) do
    local ok = self:evaluateCondition(cond, now)
    if not ok then
      return
    end
  end

  -- Global budget: the loop breaker of last resort.
  local windowStart = now - 60
  local recent = {}
  for _, t in ipairs(self.fireLog) do
    if t > windowStart then
      table.insert(recent, t)
    end
  end
  self.fireLog = recent
  if #recent >= M.GLOBAL_FIRES_PER_MINUTE then
    if self.deps.warn then
      self.deps.warn(
        string.format(
          "automation loop protection: rule %s suppressed (%d fires in the last minute)",
          tostring(rule.id),
          #recent
        )
      )
    end
    return
  end
  table.insert(self.fireLog, now)

  self.lastFired[rule.id] = now
  self.signalSeen[rule.id] = {} -- consumed: the sequence must happen again
  self.deps.fire(rule, { fired_at = now })
end

--- Evaluate one condition against live state.
--- Types: PRESENCE_IS {mode_id}, LIFESTYLE_IS {mode_id|false for none},
--- SECURITY_STATE {device_key, state}, SENSOR_CLOSED/SENSOR_OPEN {device_key},
--- TIME_RANGE {from="HH:MM", to="HH:MM"} (spans midnight when from > to),
--- DAY_OF_WEEK {days={1..7, 1=Sunday}}, VARIABLE_EQUALS {device_key, variable, value}.
--- Unknown types are FALSE — an unevaluable guard must not wave things through.
function Triggers:evaluateCondition(cond, now)
  now = now or self.deps.now()
  local t = cond.type
  if t == "PRESENCE_IS" then
    return self.deps.activeModes().PRESENCE == cond.mode_id
  elseif t == "LIFESTYLE_IS" then
    local active = self.deps.activeModes().LIFESTYLE
    if cond.mode_id == false or cond.mode_id == nil then
      return active == nil
    end
    return active == cond.mode_id
  elseif t == "SECURITY_STATE" then
    local device = self.deps.resolve(cond.device_key)
    if not device then
      return false
    end
    return tostring((device.vars or {})["PARTITION_STATE"]) == tostring(cond.state)
  elseif t == "SENSOR_CLOSED" or t == "SENSOR_OPEN" then
    local device = self.deps.resolve(cond.device_key)
    if not device then
      return false
    end
    local raw = (device.vars or {})["ContactState"]
      or (device.vars or {})["CONTACT_STATE"]
      or (device.vars or {})["STATE"]
    if raw == nil then
      return false
    end
    local s = tostring(raw):lower()
    local closed = s == "closed" or s == "0" or s == "false"
    return (t == "SENSOR_CLOSED") == closed
  elseif t == "TIME_RANGE" then
    local lt = self.deps.localtime(now)
    local minutes = lt.hour * 60 + lt.min
    local function parse(hhmm)
      local h, m = tostring(hhmm):match("^(%d+):(%d+)$")
      if not h then
        return nil
      end
      return tonumber(h) * 60 + tonumber(m)
    end
    local from, to = parse(cond.from), parse(cond.to)
    if not from or not to then
      return false
    end
    if from <= to then
      return minutes >= from and minutes <= to
    end
    return minutes >= from or minutes <= to -- spans midnight
  elseif t == "DAY_OF_WEEK" then
    local lt = self.deps.localtime(now)
    for _, d in ipairs(cond.days or {}) do
      if d == lt.wday then
        return true
      end
    end
    return false
  elseif t == "VARIABLE_EQUALS" then
    local device = self.deps.resolve(cond.device_key)
    if not device then
      return false
    end
    return tostring((device.vars or {})[cond.variable]) == tostring(cond.value)
  end
  return false
end

--- Occupancy (spec §24): a deliberate V1 tri-state read from the active
--- presence mode's own `occupancy` field (a per-mode setting the templates
--- seed — HOME says OCCUPIED, AWAY/VACATION say UNOCCUPIED — and the dealer
--- can edit). Branching on the mode's KIND here would be the hard-coded-
--- English-names trap §5 forbids. The confidence-score model is reserved
--- for V2.
function Triggers:occupancy(cfgModes)
  local active = self.deps.activeModes()
  local presence = active.PRESENCE and cfgModes[active.PRESENCE]
  if not presence or not presence.occupancy then
    return { state = "UNKNOWN" }
  end
  return { state = presence.occupancy }
end

return M
