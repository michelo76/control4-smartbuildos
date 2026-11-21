--- Logic Blocks — the block type catalogue (pure: no Control4 globals).
---
--- A BLOCK is a named, typed rule in one of M.SLOTS slots. This module owns
--- everything about a block that is not behaviour: the ten types, their
--- settings and bounds, turning what a dealer typed into a validated
--- definition (or a list of readable problems), and the wording the app and
--- Composer show. logic/blocks.lua runs definitions; it never parses text.
---
--- Rules a dealer relies on:
---   • A definition is validated WHOLE. normalize() returns either a
---     complete definition or a list of problems, never a half-applied one.
---   • A duration is written the way people say it: "10m", "90s", "1h30m",
---     "500ms", "2 min". A bare number is SECONDS.
---   • The stable Composer ids are a function of the slot only (eventId,
---     variableId, conditionalId below). They never depend on the name, the
---     type or how many blocks exist, so renaming or adding a block cannot
---     re-point programming. The id space is laid out for 32 slots, so the
---     capacity constant can change without moving an id.

local M = {}

--- Capacity. The Composer surface in driver.xml is generated from this
--- (tools/logic-blocks-xml.lua); the bench check in BENCH.md decides whether
--- 16 stays the supported number.
M.SLOTS = 16
M.MAX_INPUTS = 4

M.LIMITS = {
  name = 40,
  tag = 24,
  notes = 240,
  label = 32,
  units = 12,
  states = 12,
  state_name = 24,
  transitions = 48,
  true_when = 120,
  duration_ms_min = 100,
  duration_ms_max = 7 * 86400 * 1000,
  feedback_s_max = 600,
  number_abs = 1e12,
}

--- Per-slot events, in id order. The id of event k for slot n is
--- 1000 + n * 10 + k.
M.EVENTS = { "passed", "started", "expired", "cancelled", "value_changed", "became_true", "became_false", "faulted" }
M.EVENT_LABELS = {
  passed = "Passed",
  started = "Started",
  expired = "Expired",
  cancelled = "Cancelled",
  value_changed = "Value Changed",
  became_true = "Became True",
  became_false = "Became False",
  faulted = "Faulted",
}
M.EVENT_INDEX = {}
for i, name in ipairs(M.EVENTS) do
  M.EVENT_INDEX[name] = i
end

--- Per-slot variables, in id order: 4000 + n * 10 + k.
M.VARIABLES = {
  { key = "active", suffix = "ACTIVE", type = "BOOL", default = "0" },
  { key = "valid", suffix = "VALID", type = "BOOL", default = "0" },
  { key = "value", suffix = "VALUE", type = "NUMBER", default = "0" },
  { key = "state", suffix = "STATE", type = "STRING", default = "empty" },
}

--- Per-slot conditionals, in id order: 100 + n * 10 + k.
M.CONDITIONALS = {
  { key = "active", suffix = "IS_ACTIVE", type = "BOOL" },
  { key = "value", suffix = "VALUE", type = "NUMBER" },
  { key = "state", suffix = "STATE", type = "STRING" },
}

function M.slotLabel(slot)
  return string.format("Block %02d", slot)
end

function M.eventId(slot, kind)
  local k = type(kind) == "number" and kind or M.EVENT_INDEX[kind]
  if k == nil then
    return nil
  end
  return 1000 + slot * 10 + k
end

function M.eventName(slot, kind)
  return M.slotLabel(slot) .. " " .. tostring(M.EVENT_LABELS[kind] or kind)
end

function M.variableId(slot, k)
  return 4000 + slot * 10 + k
end

function M.variableName(slot, suffix)
  return string.format("BLOCK_%02d_%s", slot, suffix)
end

function M.conditionalId(slot, k)
  return 100 + slot * 10 + k
end

function M.conditionalName(slot, suffix)
  return string.format("BLOCK_%02d_%s", slot, suffix)
end

--- "Block 03", "block 3", "3", "03 · Driveway Welcome" → 3. nil when it
--- names no slot. A command stores the label it was programmed with, so this
--- reads the NUMBER and ignores whatever name followed it.
function M.parseSlot(text)
  local s = tostring(text or "")
  local n = s:match("^%s*[Bb]lock%s*(%d+)") or s:match("^%s*(%d+)")
  n = tonumber(n)
  if n == nil or n < 1 or n > M.SLOTS or n ~= math.floor(n) then
    return nil
  end
  return n
end

-- ── Types ───────────────────────────────────────────────────────────────────

--- order: the LIST order in Composer. inputs: how many typed inputs the type
--- reads (0 = it is driven only by commands). commands: the block commands
--- it accepts. events: the per-slot events it can fire.
M.TYPES = {
  cooldown = {
    order = 1,
    label = "Cooldown",
    summary = "Pass the first trigger, then suppress repeats for a while",
    inputs = 0,
    commands = { "trigger", "reset" },
    events = { "passed", "faulted" },
  },
  quiet = {
    order = 2,
    label = "Quiet-Period Trigger",
    summary = "Pass once after triggers have stopped for a while",
    inputs = 0,
    commands = { "trigger", "cancel", "reset" },
    events = { "started", "passed", "cancelled", "faulted" },
  },
  timer = {
    order = 3,
    label = "Restartable Timer",
    summary = "A countdown that programming can start, restart and cancel",
    inputs = 0,
    commands = { "start", "restart", "cancel", "trigger", "reset" },
    events = { "started", "expired", "cancelled", "faulted" },
  },
  once = {
    order = 4,
    label = "Once Per Day",
    summary = "Pass the first trigger of each calendar day",
    inputs = 0,
    commands = { "trigger", "reset" },
    events = { "passed", "faulted" },
  },
  flag = {
    order = 5,
    label = "Flag / Latch",
    summary = "An on/off value that stays where programming put it",
    inputs = 0,
    commands = { "set", "clear", "toggle", "reset" },
    events = { "became_true", "became_false", "faulted" },
  },
  counter = {
    order = 6,
    label = "Counter",
    summary = "A whole number with an optional threshold",
    inputs = 0,
    commands = { "increment", "decrement", "set", "reset", "clear" },
    events = { "value_changed", "became_true", "became_false", "faulted" },
  },
  conditions = {
    order = 7,
    label = "All / Any Conditions",
    summary = "Combine up to four true/false inputs",
    inputs = M.MAX_INPUTS,
    commands = { "input", "input_unavailable", "trigger" },
    events = { "passed", "became_true", "became_false", "faulted" },
  },
  threshold = {
    order = 8,
    label = "Threshold With Deadband",
    summary = "On above an upper limit, off below a lower one",
    inputs = 1,
    commands = { "input", "input_unavailable", "set" },
    events = { "became_true", "became_false", "faulted" },
  },
  stable = {
    order = 9,
    label = "Stable-State Filter",
    summary = "Follow a source only after it has held its new state",
    inputs = 1,
    commands = { "input", "input_unavailable", "cancel" },
    events = { "value_changed", "became_true", "became_false", "cancelled", "faulted" },
  },
  selector = {
    order = 10,
    label = "State Selector",
    summary = "A named state with allowed transitions",
    inputs = 0,
    commands = { "set", "reset" },
    events = { "value_changed", "faulted" },
  },
}

M.TYPE_ORDER = {}
for id, t in pairs(M.TYPES) do
  t.id = id
  M.TYPE_ORDER[t.order] = id
end

--- The labels in LIST order ("Cooldown", "Quiet-Period Trigger", …).
function M.typeLabels()
  local out = {}
  for _, id in ipairs(M.TYPE_ORDER) do
    out[#out + 1] = M.TYPES[id].label
  end
  return out
end

--- A type id from its id or its Composer label. nil when unknown.
function M.typeOf(text)
  local s = tostring(text or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
  if M.TYPES[s] ~= nil then
    return s
  end
  for id, t in pairs(M.TYPES) do
    if t.label:lower() == s then
      return id
    end
  end
  return nil
end

function M.accepts(typeId, command)
  local t = M.TYPES[typeId]
  if t == nil then
    return false
  end
  for _, c in ipairs(t.commands) do
    if c == command then
      return true
    end
  end
  return false
end

-- ── Text helpers ────────────────────────────────────────────────────────────

local function trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end
M.trim = trim

--- Printable, single-line, bounded. Control characters become spaces so a
--- name can never break a property line, a log line or the page.
function M.clean(s, max)
  local out = trim(tostring(s or ""):gsub("[%c]+", " "):gsub("%s+", " "))
  if max ~= nil and #out > max then
    out = trim(out:sub(1, max))
  end
  return out
end

local UNIT_MS = {
  ms = 1,
  msec = 1,
  millisecond = 1,
  milliseconds = 1,
  s = 1000,
  sec = 1000,
  secs = 1000,
  second = 1000,
  seconds = 1000,
  m = 60000,
  min = 60000,
  mins = 60000,
  minute = 60000,
  minutes = 60000,
  h = 3600000,
  hr = 3600000,
  hrs = 3600000,
  hour = 3600000,
  hours = 3600000,
  d = 86400000,
  day = 86400000,
  days = 86400000,
}

--- "10m", "90s", "1h30m", "500ms", "2 min", "45" (seconds) → milliseconds.
--- nil, reason when it is not a duration.
function M.parseDuration(text)
  local s = trim(text):lower()
  if s == "" then
    return nil, "is empty"
  end
  local bare = tonumber(s)
  if bare ~= nil then
    if bare ~= bare or bare < 0 or bare == math.huge then
      return nil, "is not a usable number"
    end
    return math.floor(bare * 1000 + 0.5)
  end
  local total, rest = 0, s
  local parts = 0
  while rest ~= "" do
    local num, unit, tail = rest:match("^([%d%.]+)%s*(%a+)%s*(.*)$")
    local n = tonumber(num)
    local scale = unit and UNIT_MS[unit]
    if n == nil or scale == nil then
      return nil, 'is not a duration (write it like "10m", "90s" or "1h30m")'
    end
    total = total + n * scale
    parts = parts + 1
    rest = tail
    if parts > 4 then
      return nil, "has too many parts"
    end
  end
  return math.floor(total + 0.5)
end

--- Milliseconds → "10 minutes", "1 hour 30 minutes", "500 ms", "2.5 seconds".
function M.duration(ms)
  ms = tonumber(ms) or 0
  if ms < 1000 then
    return string.format("%d ms", ms)
  end
  if ms < 60000 and ms % 1000 ~= 0 then
    return (string.format("%.1f seconds", ms / 1000):gsub("%.0 ", " "))
  end
  local s = math.floor(ms / 1000 + 0.5)
  local parts = {}
  local function take(unit, size)
    local n = math.floor(s / size)
    if n > 0 then
      parts[#parts + 1] = string.format("%d %s%s", n, unit, n == 1 and "" or "s")
      s = s - n * size
    end
  end
  take("day", 86400)
  take("hour", 3600)
  take("minute", 60)
  take("second", 1)
  if #parts == 0 then
    return "0 seconds"
  end
  return table.concat(parts, " ", 1, math.min(#parts, 2))
end

--- Milliseconds → the short form parseDuration reads back: "10m", "1h30m",
--- "90s", "500ms". What a Draft Duration property shows for a stored value.
function M.durationText(ms)
  ms = tonumber(ms) or 0
  if ms % 1000 ~= 0 then
    return string.format("%dms", ms)
  end
  local s = ms / 1000
  local out = ""
  for _, unit in ipairs({ { "d", 86400 }, { "h", 3600 }, { "m", 60 }, { "s", 1 } }) do
    local n = math.floor(s / unit[2])
    if n > 0 then
      out = out .. n .. unit[1]
      s = s - n * unit[2]
    end
  end
  return out ~= "" and out or "0s"
end

--- Seconds remaining → "7 minutes", "45 seconds", "now".
function M.remaining(seconds)
  seconds = tonumber(seconds) or 0
  if seconds <= 0 then
    return "now"
  end
  if seconds < 1 then
    return "less than a second"
  end
  return M.duration(math.ceil(seconds) * 1000)
end

--- A finite number from text, or nil. "nan", "inf", "" and words are nil.
function M.number(text)
  if type(text) == "number" then
    if text ~= text or text == math.huge or text == -math.huge then
      return nil
    end
    return text
  end
  local s = trim(text)
  if s == "" or not s:match("^[%+%-]?%d*%.?%d+[eE]?[%+%-]?%d*$") then
    return nil
  end
  local n = tonumber(s)
  if n == nil or n ~= n or n == math.huge or n == -math.huge or math.abs(n) > M.LIMITS.number_abs then
    return nil
  end
  return n
end

local TRUE_WORDS = { ["1"] = true, ["true"] = true, on = true, yes = true }
local FALSE_WORDS = { ["0"] = true, ["false"] = true, off = true, no = true }

--- A comma list → lower-cased set + ordered list. "" → nil.
function M.wordList(text)
  local list, set = {}, {}
  for word in tostring(text or ""):gmatch("[^,]+") do
    local w = trim(word):lower()
    if w ~= "" and not set[w] then
      set[w] = true
      list[#list + 1] = w
    end
  end
  if #list == 0 then
    return nil
  end
  return { list = list, set = set }
end

--- A raw value → true / false / nil (nil = not a boolean this input
--- understands). With a `trueWhen` word set the value is true when it is in
--- the set and false otherwise; without one only the plain words count, so
--- an unexpected value is INVALID rather than quietly false.
function M.boolean(raw, trueWhen)
  if raw == nil then
    return nil
  end
  if type(raw) == "boolean" then
    return raw
  end
  local s = trim(raw):lower()
  if s == "" then
    return nil
  end
  if trueWhen ~= nil then
    return trueWhen.set[s] == true
  end
  if TRUE_WORDS[s] then
    return true
  end
  if FALSE_WORDS[s] then
    return false
  end
  return nil
end

local COMPARISONS = {
  [">="] = "at least",
  [">"] = "more than",
  ["="] = "exactly",
  ["<="] = "at most",
  ["<"] = "less than",
  ["!="] = "anything but",
}
M.COMPARISONS = { ">=", ">", "=", "<=", "<", "!=" }

function M.compare(op, a, b)
  if op == ">=" then
    return a >= b
  elseif op == ">" then
    return a > b
  elseif op == "=" then
    return a == b
  elseif op == "<=" then
    return a <= b
  elseif op == "<" then
    return a < b
  elseif op == "!=" then
    return a ~= b
  end
  return false
end

M.REPEAT_START = { restart = "Restart the countdown", ignore = "Ignore while running" }
M.RECOVERY = {
  cancel_if_missed = "Cancel if missed",
  fire_late = "Fire late",
  resume = "Resume remaining",
}

local function pick(map, text, fallback)
  local s = trim(text):lower()
  if s == "" then
    return fallback
  end
  for id, label in pairs(map) do
    if id == s or label:lower() == s then
      return id
    end
  end
  return nil
end

-- ── Normalisation: what was typed → a definition ────────────────────────────

local function normaliseInputs(raw, typeId, problems)
  local want = M.TYPES[typeId].inputs
  local out = {}
  if want == 0 then
    return out
  end
  local given = type(raw.inputs) == "table" and raw.inputs or {}
  for i = 1, M.MAX_INPUTS do
    local r = given[i]
    if type(r) == "table" and (r.used == true or r.device_id ~= nil or trim(r.label) ~= "") then
      if i > want then
        problems[#problems + 1] = string.format("Input %d is not used by a %s block", i, M.TYPES[typeId].label)
      else
        local input = { index = i, label = M.clean(r.label, M.LIMITS.label) }
        if input.label == "" then
          input.label = "Input " .. i
        end
        local device, variable = tonumber(r.device_id), tonumber(r.variable_id)
        if device ~= nil or variable ~= nil then
          if device == nil or variable == nil or device < 1 or variable < 0 then
            problems[#problems + 1] =
              string.format("Input %d: pick both a device and one of its variables, or neither", i)
          else
            input.device_id = math.floor(device)
            input.variable_id = math.floor(variable)
            input.device_name = M.clean(r.device_name, 60)
            input.variable_name = M.clean(r.variable_name, 60)
          end
        end
        local words = trim(r.true_when)
        if #words > M.LIMITS.true_when then
          problems[#problems + 1] = string.format("Input %d: True When is too long", i)
        elseif words ~= "" then
          local list = M.wordList(words)
          if list ~= nil then
            input.true_when = table.concat(list.list, ",")
          end
        end
        out[#out + 1] = input
      end
    end
  end
  return out
end

local function normaliseFeedback(raw, problems)
  local f = raw.feedback
  if type(f) ~= "table" or (f.device_id == nil and f.variable_id == nil) then
    return nil
  end
  local device, variable = tonumber(f.device_id), tonumber(f.variable_id)
  if device == nil or variable == nil then
    problems[#problems + 1] = "Feedback: pick both a device and one of its variables, or neither"
    return nil
  end
  local within = M.parseDuration(trim(f.within) == "" and "10s" or f.within)
  if within == nil or within < 1000 or within > M.LIMITS.feedback_s_max * 1000 then
    problems[#problems + 1] =
      string.format("Feedback Within must be between 1 second and %d seconds", M.LIMITS.feedback_s_max)
    return nil
  end
  local expect = M.wordList(f.expect)
  if expect == nil then
    problems[#problems + 1] = "Feedback Expect is empty: list the values that mean the equipment responded"
    return nil
  end
  return {
    device_id = math.floor(device),
    variable_id = math.floor(variable),
    device_name = M.clean(f.device_name, 60),
    variable_name = M.clean(f.variable_name, 60),
    expect = table.concat(expect.list, ","),
    within_ms = within,
  }
end

local function durationField(raw, field, label, problems, min)
  local ms, why = M.parseDuration(raw[field])
  if ms == nil then
    problems[#problems + 1] = string.format("%s %s", label, why)
    return nil
  end
  min = min or M.LIMITS.duration_ms_min
  if ms < min then
    problems[#problems + 1] = string.format("%s must be at least %s", label, M.duration(min))
    return nil
  end
  if ms > M.LIMITS.duration_ms_max then
    problems[#problems + 1] = string.format("%s must be at most %s", label, M.duration(M.LIMITS.duration_ms_max))
    return nil
  end
  return ms
end

local NORMALISE = {}

function NORMALISE.cooldown(raw, problems)
  return { interval_ms = durationField(raw, "duration", "Duration", problems) }
end

function NORMALISE.quiet(raw, problems)
  return { quiet_ms = durationField(raw, "duration", "Duration", problems) }
end

function NORMALISE.timer(raw, problems)
  local settings = { duration_ms = durationField(raw, "duration", "Duration", problems, 1000) }
  settings.repeat_start = pick(M.REPEAT_START, raw.repeat_start, "restart")
  if settings.repeat_start == nil then
    problems[#problems + 1] = "Repeated Start must be Restart the countdown or Ignore while running"
  end
  settings.recovery = pick(M.RECOVERY, raw.recovery, "cancel_if_missed")
  if settings.recovery == nil then
    problems[#problems + 1] = "After Restart must be Cancel if missed, Fire late or Resume remaining"
  end
  return settings
end

function NORMALISE.once()
  return {}
end

function NORMALISE.flag()
  return {}
end

function NORMALISE.counter(raw, problems)
  local settings = {}
  local text = trim(raw.counter_threshold)
  if text ~= "" then
    local n = M.number(text)
    if n == nil or n ~= math.floor(n) or math.abs(n) > 1000000000 then
      problems[#problems + 1] = "Counter Threshold must be a whole number between -1000000000 and 1000000000"
    else
      settings.threshold = n
    end
    local op = trim(raw.counter_comparison)
    if op == "" then
      op = ">="
    end
    if COMPARISONS[op] == nil then
      problems[#problems + 1] = "Counter Comparison must be one of >= > = <= < !="
    else
      settings.comparison = op
    end
  end
  return settings
end

function NORMALISE.conditions(raw, problems)
  local settings = {}
  local mode = trim(raw.mode):lower()
  if mode == "" or mode == "all" or mode:find("^all") then
    settings.mode = "all"
  elseif mode == "any" or mode:find("^any") then
    settings.mode = "any"
  else
    problems[#problems + 1] = "Mode must be All or Any"
  end
  local evaluation = trim(raw.evaluation):lower()
  if evaluation == "" or evaluation:find("^continuous") then
    settings.evaluation = "continuous"
  elseif evaluation:find("^gate") then
    settings.evaluation = "gate"
  else
    problems[#problems + 1] = "Evaluation must be Continuous output or Gate a trigger"
  end
  return settings
end

function NORMALISE.threshold(raw, problems)
  local settings = { units = M.clean(raw.units, M.LIMITS.units) }
  local upper, lower = M.number(raw.upper), M.number(raw.lower)
  if upper == nil then
    problems[#problems + 1] = "Upper Threshold must be a number"
  end
  if lower == nil then
    problems[#problems + 1] = "Lower Threshold must be a number"
  end
  if upper ~= nil and lower ~= nil then
    if lower > upper then
      problems[#problems + 1] = string.format(
        "Lower Threshold (%s) is above Upper Threshold (%s): the block could never turn off and on again",
        tostring(lower),
        tostring(upper)
      )
    else
      settings.upper, settings.lower = upper, lower
    end
  end
  return settings
end

function NORMALISE.stable(raw, problems)
  return { stable_ms = durationField(raw, "duration", "Duration", problems) }
end

function NORMALISE.selector(raw, problems)
  local settings = { states = {}, transitions = {} }
  local seen = {}
  for word in tostring(raw.states or ""):gmatch("[^,]+") do
    local name = M.clean(word, M.LIMITS.state_name)
    if name ~= "" then
      local id = name:lower()
      if seen[id] then
        problems[#problems + 1] = string.format('State "%s" is listed twice', name)
      else
        seen[id] = name
        settings.states[#settings.states + 1] = name
      end
    end
  end
  if #settings.states < 2 then
    problems[#problems + 1] = "States needs at least two names, separated by commas"
  elseif #settings.states > M.LIMITS.states then
    problems[#problems + 1] = string.format("States allows at most %d names", M.LIMITS.states)
  end
  local initial = M.clean(raw.initial_state, M.LIMITS.state_name)
  if initial == "" then
    settings.initial = settings.states[1]
  elseif seen[initial:lower()] == nil then
    problems[#problems + 1] = string.format('Initial State "%s" is not one of the States', initial)
  else
    settings.initial = seen[initial:lower()]
  end
  local count = 0
  for word in tostring(raw.transitions or ""):gmatch("[^,]+") do
    local from, to = trim(word):match("^(.-)%s*>%s*(.-)$")
    if from == nil or trim(from) == "" or trim(to) == "" then
      if trim(word) ~= "" then
        problems[#problems + 1] =
          string.format('Transition "%s" is not written as From > To (use * for any state)', trim(word))
      end
    else
      from, to = trim(from), trim(to)
      local f = from == "*" and "*" or seen[from:lower()]
      local t = to == "*" and "*" or seen[to:lower()]
      if f == nil then
        problems[#problems + 1] = string.format('Transition "%s": "%s" is not one of the States', trim(word), from)
      elseif t == nil then
        problems[#problems + 1] = string.format('Transition "%s": "%s" is not one of the States', trim(word), to)
      else
        count = count + 1
        settings.transitions[#settings.transitions + 1] = { from = f, to = t }
      end
    end
  end
  if count > M.LIMITS.transitions then
    problems[#problems + 1] = string.format("Transitions allows at most %d entries", M.LIMITS.transitions)
  end
  return settings
end

--- Turns what a dealer typed (`raw`, every field optional text) into a
--- definition. Returns def, nil when it is whole and valid; nil, problems
--- (a list of readable sentences) otherwise.
---
--- raw = { type, name, tag, notes, duration, repeat_start, recovery, mode,
---         evaluation, upper, lower, units, counter_threshold,
---         counter_comparison, states, initial_state, transitions,
---         inputs = { [i] = { used, label, device_id, variable_id,
---                            device_name, variable_name, true_when } },
---         feedback = { device_id, variable_id, device_name,
---                      variable_name, expect, within } }
function M.normalize(raw)
  raw = type(raw) == "table" and raw or {}
  local problems = {}
  local typeId = M.typeOf(raw.type)
  if typeId == nil then
    return nil, { "Block Type is not one of the ten block types" }
  end
  local name = M.clean(raw.name, M.LIMITS.name)
  if name == "" then
    problems[#problems + 1] = "Name is empty"
  end
  local settings = NORMALISE[typeId](raw, problems)
  local inputs = normaliseInputs(raw, typeId, problems)
  local t = M.TYPES[typeId]
  if t.inputs > 0 and #inputs == 0 then
    problems[#problems + 1] = string.format(
      "A %s block needs at least one input: name it in Input 1 Label (fed by the BLOCK_INPUT command) or pick a device variable",
      t.label
    )
  end
  if typeId == "conditions" then
    local seen = {}
    for _, input in ipairs(inputs) do
      if seen[input.index] then
        problems[#problems + 1] = "An input is listed twice"
      end
      seen[input.index] = true
    end
  end
  local feedback = normaliseFeedback(raw, problems)
  if #problems > 0 then
    return nil, problems
  end
  return {
    type = typeId,
    name = name,
    tag = M.clean(raw.tag, M.LIMITS.tag),
    notes = M.clean(raw.notes, M.LIMITS.notes),
    settings = settings,
    inputs = inputs,
    feedback = feedback,
  }
end

--- Is a STORED definition well-formed enough to run? Returns true, or
--- false and why. Used on restore: a definition that fails here is kept
--- verbatim and shown as unreadable, never repaired by guessing.
function M.wellFormed(def)
  if type(def) ~= "table" then
    return false, "not a table"
  end
  if M.TYPES[def.type] == nil then
    return false, "unknown block type " .. tostring(def.type)
  end
  if type(def.name) ~= "string" or def.name == "" then
    return false, "no name"
  end
  if type(def.id) ~= "string" or def.id == "" then
    return false, "no identity"
  end
  local s = def.settings
  if type(s) ~= "table" then
    return false, "no settings"
  end
  local function positive(field)
    return type(s[field]) == "number" and s[field] > 0 and s[field] == s[field]
  end
  if def.type == "cooldown" and not positive("interval_ms") then
    return false, "no cooldown interval"
  elseif def.type == "quiet" and not positive("quiet_ms") then
    return false, "no quiet period"
  elseif def.type == "timer" then
    if not positive("duration_ms") then
      return false, "no timer duration"
    end
    if M.REPEAT_START[s.repeat_start] == nil or M.RECOVERY[s.recovery] == nil then
      return false, "unknown timer policy"
    end
  elseif def.type == "counter" then
    if s.threshold ~= nil and (type(s.threshold) ~= "number" or COMPARISONS[s.comparison] == nil) then
      return false, "unreadable counter threshold"
    end
  elseif def.type == "conditions" then
    if (s.mode ~= "all" and s.mode ~= "any") or (s.evaluation ~= "continuous" and s.evaluation ~= "gate") then
      return false, "unknown conditions mode"
    end
  elseif def.type == "threshold" then
    if type(s.upper) ~= "number" or type(s.lower) ~= "number" or s.lower > s.upper then
      return false, "unreadable thresholds"
    end
  elseif def.type == "stable" and not positive("stable_ms") then
    return false, "no stable interval"
  elseif def.type == "selector" then
    if type(s.states) ~= "table" or #s.states < 2 or type(s.initial) ~= "string" then
      return false, "unreadable states"
    end
    if type(s.transitions) ~= "table" then
      return false, "unreadable transitions"
    end
  end
  if def.inputs ~= nil and type(def.inputs) ~= "table" then
    return false, "unreadable inputs"
  end
  for _, input in ipairs(def.inputs or {}) do
    if type(input) ~= "table" or type(input.index) ~= "number" then
      return false, "unreadable input"
    end
  end
  return true
end

-- ── Wording ─────────────────────────────────────────────────────────────────

local function inputPhrase(input)
  if input.device_id ~= nil then
    return string.format(
      "%s (%s › %s)",
      input.label,
      input.device_name ~= "" and input.device_name or ("device " .. input.device_id),
      input.variable_name ~= "" and input.variable_name or ("variable " .. input.variable_id)
    )
  end
  return input.label .. " (sent by programming)"
end

--- One or two plain sentences saying what the block does.
function M.explain(def)
  local s = def.settings or {}
  if def.type == "cooldown" then
    return string.format(
      "Passes the first trigger, then suppresses every repeat for %s. Nothing passes when the cooldown ends; the next trigger after it does.",
      M.duration(s.interval_ms)
    )
  elseif def.type == "quiet" then
    return string.format(
      "Each trigger restarts a %s countdown. It passes once, when triggers have stopped for that long.",
      M.duration(s.quiet_ms)
    )
  elseif def.type == "timer" then
    local again = s.repeat_start == "ignore" and "A start while it is running is ignored."
      or "A start while it is running begins the countdown again."
    local recovery = s.recovery == "fire_late"
        and "After a controller restart, a countdown that ended while it was down expires at once, marked late."
      or s.recovery == "resume" and "After a controller restart, the time that was left carries on counting."
      or "After a controller restart, a countdown that ended while it was down is cancelled and reported; one still in the future carries on."
    return string.format("Counts down %s, then expires. %s %s", M.duration(s.duration_ms), again, recovery)
  elseif def.type == "once" then
    return "Passes the first trigger of each calendar day on the controller's clock, and suppresses the rest until midnight. It is not a 24-hour interval."
  elseif def.type == "flag" then
    return "An on/off value that programming sets, clears or toggles. It keeps its value across restarts and fires only when it actually changes."
  elseif def.type == "counter" then
    if s.threshold ~= nil then
      return string.format(
        "A whole number that programming raises, lowers, sets or resets. It is active while the count is %s %d.",
        COMPARISONS[s.comparison],
        s.threshold
      )
    end
    return "A whole number that programming raises, lowers, sets or resets. It keeps its value across restarts."
  elseif def.type == "conditions" then
    local names = {}
    for _, input in ipairs(def.inputs or {}) do
      names[#names + 1] = inputPhrase(input)
    end
    local join = s.mode == "any" and " or " or " and "
    local rule = (s.mode == "any" and "True when any of: " or "True when all of: ") .. table.concat(names, join) .. "."
    if s.evaluation == "gate" then
      return rule
        .. " It does nothing by itself: a trigger passes only while that is true. An input it cannot read blocks the trigger rather than counting as false."
    end
    return rule .. " An input it cannot read makes the result unknown, not false."
  elseif def.type == "threshold" then
    local units = s.units ~= "" and (" " .. s.units) or ""
    return string.format(
      "Turns on when the reading goes above %s%s and off when it drops below %s%s. Between the two it keeps its last state; a reading exactly on a limit changes nothing.",
      tostring(s.upper),
      units,
      tostring(s.lower),
      units
    )
  elseif def.type == "stable" then
    return string.format(
      "Follows its source only after the source has held a new state for %s. If the source changes again first, the pending change is dropped.",
      M.duration(s.stable_ms)
    )
  elseif def.type == "selector" then
    local rule = #(s.transitions or {}) == 0 and "Any state may follow any other."
      or "Only the listed transitions are allowed; anything else is refused with the reason."
    return string.format(
      "One of the states %s; starts in %s. %s",
      table.concat(s.states or {}, ", "),
      tostring(s.initial),
      rule
    )
  end
  return ""
end

--- The settings as label/value rows for the app and Print Blocks.
function M.settingsRows(def)
  local s = def.settings or {}
  local rows = {}
  local function row(label, value)
    rows[#rows + 1] = { label = label, value = tostring(value) }
  end
  if def.type == "cooldown" then
    row("Cooldown", M.duration(s.interval_ms))
  elseif def.type == "quiet" then
    row("Quiet period", M.duration(s.quiet_ms))
  elseif def.type == "timer" then
    row("Duration", M.duration(s.duration_ms))
    row("Repeated start", M.REPEAT_START[s.repeat_start] or s.repeat_start)
    row("After restart", M.RECOVERY[s.recovery] or s.recovery)
  elseif def.type == "counter" then
    row("Threshold", s.threshold ~= nil and (s.comparison .. " " .. s.threshold) or "none")
  elseif def.type == "conditions" then
    row("Mode", s.mode == "any" and "Any" or "All")
    row("Evaluation", s.evaluation == "gate" and "Gate a trigger" or "Continuous output")
  elseif def.type == "threshold" then
    row("Upper threshold", tostring(s.upper) .. (s.units ~= "" and (" " .. s.units) or ""))
    row("Lower threshold", tostring(s.lower) .. (s.units ~= "" and (" " .. s.units) or ""))
  elseif def.type == "stable" then
    row("Stable for", M.duration(s.stable_ms))
  elseif def.type == "selector" then
    row("States", table.concat(s.states or {}, ", "))
    row("Initial state", s.initial)
    local list = {}
    for _, t in ipairs(s.transitions or {}) do
      list[#list + 1] = t.from .. " > " .. t.to
    end
    row("Allowed transitions", #list > 0 and table.concat(list, ", ") or "any")
  end
  for _, input in ipairs(def.inputs or {}) do
    row("Input " .. input.index, inputPhrase(input) .. (input.true_when and (" — true when " .. input.true_when) or ""))
  end
  if def.feedback ~= nil then
    row(
      "Equipment feedback",
      string.format(
        "%s › %s is one of %s within %s",
        def.feedback.device_name ~= "" and def.feedback.device_name or ("device " .. def.feedback.device_id),
        def.feedback.variable_name ~= "" and def.feedback.variable_name or ("variable " .. def.feedback.variable_id),
        def.feedback.expect,
        M.duration(def.feedback.within_ms)
      )
    )
  end
  return rows
end

local COMMAND_TEXT = {
  trigger = { "BLOCK_TRIGGER", "run the rule" },
  start = { "BLOCK_START", "start the countdown (follows Repeated Start)" },
  restart = { "BLOCK_RESTART", "start the countdown again from now" },
  cancel = { "BLOCK_CANCEL", "cancel what is pending" },
  set = { "BLOCK_SET", "set the value" },
  clear = { "BLOCK_CLEAR", "turn it off / back to zero" },
  toggle = { "BLOCK_TOGGLE", "flip it" },
  increment = { "BLOCK_INCREMENT", "add to the count" },
  decrement = { "BLOCK_DECREMENT", "subtract from the count" },
  reset = { "BLOCK_RESET", "forget its history and start fresh" },
  input = { "BLOCK_INPUT", "send an input value" },
  input_unavailable = { "BLOCK_INPUT_UNAVAILABLE", "say an input cannot be read" },
}

local EVENT_WHEN = {
  cooldown = { passed = "a trigger was let through" },
  quiet = {
    started = "the first trigger of a burst arrived",
    passed = "triggers stopped for the quiet period",
    cancelled = "BLOCK_CANCEL stopped a pending countdown",
  },
  timer = {
    started = "the countdown began",
    expired = "the countdown ended",
    cancelled = "BLOCK_CANCEL stopped a running countdown",
  },
  once = { passed = "the first trigger of the day arrived" },
  flag = { became_true = "the flag turned on", became_false = "the flag turned off" },
  counter = {
    value_changed = "the count changed",
    became_true = "the count reached the threshold",
    became_false = "the count left the threshold",
  },
  conditions = {
    passed = "a trigger arrived while the conditions held (Gate a trigger)",
    became_true = "the conditions became true (Continuous output)",
    became_false = "the conditions became false (Continuous output)",
  },
  threshold = {
    became_true = "the reading went above the upper threshold",
    became_false = "the reading dropped below the lower threshold",
  },
  stable = {
    value_changed = "the source held a new state long enough",
    became_true = "the held state is a true one",
    became_false = "the held state is a false one",
    cancelled = "BLOCK_CANCEL dropped a pending change",
  },
  selector = { value_changed = "the state changed" },
}

--- What a dealer wires in Composer for this block: the commands that feed
--- it and the events it raises. The driver cannot see programming, so this
--- is an instruction, never a report of what is wired.
function M.wiring(def, slot)
  local label = M.slotLabel(slot)
  local t = M.TYPES[def.type]
  local inputs, outputs = {}, {}
  -- A value input that is read from a device variable takes no command.
  local commandFed = false
  for _, input in ipairs(def.inputs or {}) do
    if input.device_id == nil then
      commandFed = true
    end
  end
  for _, command in ipairs(t.commands) do
    local text = COMMAND_TEXT[command]
    local skip = command == "trigger" and def.type == "conditions" and def.settings.evaluation ~= "gate"
    if t.inputs > 0 and not commandFed then
      skip = skip or command == "input" or command == "input_unavailable" or (command == "set" and def.type == "threshold")
    end
    if not skip then
      inputs[#inputs + 1] = { command = text[1], block = label, does = text[2] }
    end
  end
  for _, kind in ipairs(M.EVENTS) do
    local when = EVENT_WHEN[def.type][kind]
    if kind == "faulted" then
      when = "the block cannot give a result (an input it cannot read, or it was isolated)"
    end
    if when ~= nil then
      local skip = def.type == "conditions"
        and (
          (kind == "passed" and def.settings.evaluation ~= "gate")
          or ((kind == "became_true" or kind == "became_false") and def.settings.evaluation == "gate")
        )
      if not skip then
        outputs[#outputs + 1] = { event = M.eventName(slot, kind), id = M.eventId(slot, kind), when = when }
      end
    end
  end
  return { inputs = inputs, outputs = outputs }
end

-- ── Templates ───────────────────────────────────────────────────────────────

--- Recipes. A template fills a DRAFT only: it never creates a block and
--- never maps a device (the dealer picks devices). `wiring` is the exact
--- Composer programming to add, with BLOCK standing for the slot the block
--- lands in.
M.TEMPLATES = {
  {
    id = "driveway_cooldown",
    name = "Driveway welcome (cooldown)",
    summary = "Run the welcome scene on driveway motion, but not again for 10 minutes.",
    raw = { type = "cooldown", name = "Driveway Welcome", tag = "Driveway", duration = "10m" },
    wiring = {
      "When Driveway Motion senses motion → Logic Pack: BLOCK_TRIGGER (BLOCK)",
      "When Logic Pack: BLOCK Passed → run the Welcome lighting scene",
    },
    needs = {},
  },
  {
    id = "bathroom_vacancy",
    name = "Bathroom vacancy (restartable timer)",
    summary = "Turn the fan and light off 15 minutes after the last motion.",
    raw = {
      type = "timer",
      name = "Bathroom Vacancy",
      tag = "Bathroom",
      duration = "15m",
      repeat_start = "restart",
      recovery = "cancel_if_missed",
    },
    wiring = {
      "When Bathroom Motion senses motion → Logic Pack: BLOCK_START (BLOCK)",
      "When Logic Pack: BLOCK Expired → turn the bathroom light and fan off",
      "Optional: when the light is switched off by hand → Logic Pack: BLOCK_CANCEL (BLOCK)",
    },
    needs = {},
  },
  {
    id = "guest_override",
    name = "Guest override (flag)",
    summary = "A switch that stays on until someone turns it off, even through a restart.",
    raw = { type = "flag", name = "Guest Override", tag = "House" },
    wiring = {
      "When the Guest keypad button is pressed → Logic Pack: BLOCK_TOGGLE (BLOCK)",
      "In any automation: If Logic Pack: BLOCK is active → Stop",
      "When Logic Pack: BLOCK Became True / Became False → set the keypad LED",
    },
    needs = {},
  },
  {
    id = "daily_greeting",
    name = "Daily greeting (once per day)",
    summary = "Announce a greeting the first time the kitchen is entered each day.",
    raw = { type = "once", name = "Daily Greeting", tag = "Kitchen" },
    wiring = {
      "When Kitchen Motion senses motion → Logic Pack: BLOCK_TRIGGER (BLOCK)",
      "When Logic Pack: BLOCK Passed → play the greeting announcement",
    },
    needs = {},
  },
  {
    id = "rack_temperature",
    name = "Rack temperature (threshold with deadband)",
    summary = "Run the rack fan above 85°F and stop it only once the rack is back under 78°F.",
    raw = {
      type = "threshold",
      name = "Rack Temperature",
      tag = "Rack",
      upper = "85",
      lower = "78",
      units = "°F",
      inputs = { { used = true, label = "Rack temperature" } },
    },
    wiring = {
      "Pick the rack sensor's temperature variable in Draft Input 1 Device / Variable, or send it with Logic Pack: BLOCK_INPUT (BLOCK, Input 1, value)",
      "When Logic Pack: BLOCK Became True → turn the rack fan on",
      "When Logic Pack: BLOCK Became False → turn the rack fan off",
      "When Logic Pack: BLOCK Faulted → notify the dealer: the sensor is not reporting",
    },
    needs = { "Input 1: the temperature sensor's variable" },
  },
}

function M.template(idOrName)
  local s = trim(idOrName):lower()
  for _, t in ipairs(M.TEMPLATES) do
    if t.id == s or t.name:lower() == s then
      return t
    end
  end
  return nil
end

function M.templateNames()
  local out = {}
  for _, t in ipairs(M.TEMPLATES) do
    out[#out + 1] = t.name
  end
  return out
end

return M
