--- Logic Blocks — the draft (pure).
---
--- Composer properties are edited one at a time, and a rule that is half
--- changed must never run. So nothing a dealer types reaches a live block.
--- It lands in ONE draft; Validate Draft checks the whole of it and says
--- what applying it would do to anything running; Apply Draft swaps the
--- block's definition in one step, or does nothing.
---
--- A draft is either NEW (it will create a block) or an EDIT of one slot.
--- Loading a block into the draft copies its settings; a template fills a
--- new draft and never maps a device.
---
--- deps = { legacy = { describe = fn(key) -> { counter = n|nil, flag = bool|nil } | nil } }

local Defs = require("logic.blockdefs")

local M = {}

local Draft = {}
Draft.__index = Draft

--- The text fields a draft holds, in the order Composer shows them.
M.FIELDS = {
  "name",
  "tag",
  "notes",
  "duration",
  "repeat_start",
  "recovery",
  "mode",
  "evaluation",
  "upper",
  "lower",
  "units",
  "counter_threshold",
  "counter_comparison",
  "states",
  "initial_state",
  "transitions",
  "adopt_legacy",
}

--- Which fields each type uses (name, tag and notes always apply).
M.USES = {
  cooldown = { duration = true },
  quiet = { duration = true },
  timer = { duration = true, repeat_start = true, recovery = true },
  once = {},
  flag = { adopt_legacy = true },
  counter = { counter_threshold = true, counter_comparison = true, adopt_legacy = true },
  conditions = { mode = true, evaluation = true },
  threshold = { upper = true, lower = true, units = true },
  stable = { duration = true },
  selector = { states = true, initial_state = true, transitions = true },
}

function M.new(blocks, deps)
  local self = setmetatable({}, Draft)
  self.blocks = blocks
  self.deps = deps or {}
  self:discard()
  return self
end

function Draft:discard()
  self.raw = nil
  self.target = nil
  self.checked = nil
  self.template = nil
end

function Draft:active()
  return self.raw ~= nil
end

local function emptyRaw(typeId)
  return { type = typeId, inputs = {}, feedback = {} }
end

--- Begins a draft for a NEW block.
function Draft:start(typeText, name)
  local typeId = Defs.typeOf(typeText)
  if typeId == nil then
    return false, "pick a Block Type first"
  end
  self:discard()
  self.raw = emptyRaw(typeId)
  self.raw.name = Defs.clean(name, Defs.LIMITS.name)
  return true
end

--- Fills a new draft from a recipe. Devices are never part of a recipe.
function Draft:fromTemplate(idOrName)
  local template = Defs.template(idOrName)
  if template == nil then
    return false, "pick a Template first"
  end
  self:discard()
  local raw = emptyRaw(Defs.typeOf(template.raw.type))
  for field, value in pairs(template.raw) do
    if field == "inputs" then
      for i, input in ipairs(value) do
        raw.inputs[i] = { used = true, label = input.label }
      end
    elseif field ~= "type" then
      raw[field] = value
    end
  end
  self.raw = raw
  self.template = template.id
  return true, template
end

--- Loads an existing block for editing.
function Draft:load(slot)
  local block = self.blocks.blocks[slot]
  if block == nil then
    return false, "that slot holds no block to edit"
  end
  self:discard()
  local s = block.settings
  local raw = emptyRaw(block.type)
  raw.name, raw.tag, raw.notes = block.name, block.tag, block.notes
  if block.type == "cooldown" then
    raw.duration = Defs.durationText(s.interval_ms)
  elseif block.type == "quiet" then
    raw.duration = Defs.durationText(s.quiet_ms)
  elseif block.type == "timer" then
    raw.duration = Defs.durationText(s.duration_ms)
    raw.repeat_start = Defs.REPEAT_START[s.repeat_start]
    raw.recovery = Defs.RECOVERY[s.recovery]
  elseif block.type == "counter" then
    raw.counter_threshold = s.threshold ~= nil and tostring(s.threshold) or ""
    raw.counter_comparison = s.comparison or ">="
  elseif block.type == "conditions" then
    raw.mode = s.mode == "any" and "Any" or "All"
    raw.evaluation = s.evaluation == "gate" and "Gate a trigger" or "Continuous output"
  elseif block.type == "threshold" then
    raw.upper, raw.lower, raw.units = tostring(s.upper), tostring(s.lower), s.units
  elseif block.type == "stable" then
    raw.duration = Defs.durationText(s.stable_ms)
  elseif block.type == "selector" then
    raw.states = table.concat(s.states, ", ")
    raw.initial_state = s.initial
    local list = {}
    for _, t in ipairs(s.transitions) do
      list[#list + 1] = t.from .. " > " .. t.to
    end
    raw.transitions = table.concat(list, ", ")
  end
  for _, input in ipairs(block.inputs or {}) do
    raw.inputs[input.index] = {
      used = true,
      label = input.label,
      device_id = input.device_id,
      variable_id = input.variable_id,
      device_name = input.device_name,
      variable_name = input.variable_name,
      true_when = input.true_when,
    }
  end
  if block.feedback ~= nil then
    raw.feedback = {
      device_id = block.feedback.device_id,
      variable_id = block.feedback.variable_id,
      device_name = block.feedback.device_name,
      variable_name = block.feedback.variable_name,
      expect = block.feedback.expect,
      within = Defs.durationText(block.feedback.within_ms),
    }
  end
  self.raw = raw
  self.target = slot
  return true
end

--- Sets one text field. Returns false when there is no draft.
function Draft:set(field, value)
  if self.raw == nil then
    return false
  end
  if self.raw[field] ~= value then
    self.raw[field] = value
    self.checked = nil
  end
  return true
end

--- Sets one field of input `index` (label, true_when, device_id,
--- variable_id, device_name, variable_name).
function Draft:setInput(index, field, value)
  if self.raw == nil then
    return false
  end
  local input = self.raw.inputs[index] or {}
  self.raw.inputs[index] = input
  if value == "" then
    value = nil
  end
  if input[field] ~= value then
    input[field] = value
    self.checked = nil
  end
  input.used = (input.label ~= nil and Defs.trim(input.label) ~= "") or input.device_id ~= nil
  return true
end

function Draft:setFeedback(field, value)
  if self.raw == nil then
    return false
  end
  if value == "" then
    value = nil
  end
  if self.raw.feedback[field] ~= value then
    self.raw.feedback[field] = value
    self.checked = nil
  end
  return true
end

function Draft:typeId()
  return self.raw and self.raw.type or nil
end

--- Checks the whole draft. Returns ok, lines: when ok, `lines` is what
--- applying it would do (and any warnings); otherwise the problems.
function Draft:validate()
  if self.raw == nil then
    return false, { "There is no draft. Start one with New Draft, Edit Selected Block or Load Template Into Draft." }
  end
  local def, problems = Defs.normalize(self.raw)
  if def == nil then
    self.checked = nil
    return false, problems
  end
  local blocks = self.blocks
  problems = {}
  local taken = blocks:nameTaken(def.name, self.target)
  if taken ~= nil then
    problems[#problems + 1] = string.format('%s is already named "%s"', Defs.slotLabel(taken), def.name)
  end
  local lines = {}
  local slot = self.target
  if slot ~= nil then
    local block = blocks.blocks[slot]
    if block == nil then
      problems[#problems + 1] = "The block this draft was editing no longer exists. Discard the draft."
    elseif block.type ~= def.type then
      problems[#problems + 1] = "A block's type cannot change. Retire it and create a new block."
    end
  else
    slot = blocks:freeSlot()
    if slot == nil then
      local c = blocks:counts()
      problems[#problems + 1] = c.retired > 0
          and string.format(
            "All %d slots have been used; %d hold retired blocks. Release one with Release Retired Slot first.",
            Defs.SLOTS,
            c.retired
          )
        or string.format("All %d slots are in use.", Defs.SLOTS)
    end
  end
  local adopt = Defs.trim(self.raw.adopt_legacy)
  local seed
  if adopt ~= "" then
    if self.target ~= nil then
      problems[#problems + 1] = "Adopt Legacy Key applies only when a block is created."
    elseif def.type ~= "flag" and def.type ~= "counter" then
      problems[#problems + 1] = "Adopt Legacy Key applies only to a Flag or a Counter block."
    else
      local found = self.deps.legacy and self.deps.legacy.describe(adopt) or nil
      local value = found and found[def.type]
      if value == nil then
        problems[#problems + 1] = string.format('There is no free-form %s named "%s" to adopt.', def.type, adopt)
      else
        seed = { key = adopt, value = value }
      end
    end
  end
  if #problems > 0 then
    self.checked = nil
    return false, problems
  end
  for _, line in ipairs(blocks:impact(slot, def)) do
    lines[#lines + 1] = line
  end
  if seed ~= nil then
    lines[#lines + 1] = string.format(
      'Copies the free-form %s "%s" (%s) into the new block ONCE. The free-form key is not deleted, and programming that uses %s with that key keeps changing the key, not the block.',
      def.type,
      seed.key,
      tostring(seed.value),
      def.type == "flag" and "SET_FLAG / CLEAR_FLAG" or "INCREMENT_COUNTER"
    )
  elseif self.target == nil and self.deps.legacy ~= nil then
    local found = self.deps.legacy.describe(def.name)
    if found ~= nil and (found.counter ~= nil or found.flag ~= nil or found.timer or found.once) then
      lines[#lines + 1] = string.format(
        "Note: a free-form key with this name already exists. The block is separate from it and adopts nothing%s.",
        (def.type == "flag" or def.type == "counter") and " (use Draft Adopt Legacy Key to copy its value in)" or ""
      )
    end
  end
  for _, input in ipairs(def.inputs) do
    if input.device_id == nil then
      lines[#lines + 1] = string.format(
        "%s is not mapped to a device: feed it with BLOCK_INPUT (%s, Input %d).",
        input.label,
        Defs.slotLabel(slot),
        input.index
      )
    end
  end
  self.checked = { def = def, slot = slot, seed = seed, new = self.target == nil }
  return true, lines
end

--- Applies a validated draft in one step. Validates first when the draft
--- changed since the last check. Returns ok, slot | problems.
function Draft:apply()
  local ok, lines = self:validate()
  if not ok then
    return false, lines
  end
  local checked = self.checked
  local blocks = self.blocks
  if checked.new then
    local slot, why = blocks:create(checked.def)
    if slot == nil then
      return false, { tostring(why) }
    end
    if checked.seed ~= nil then
      blocks:seed(slot, checked.seed.value)
    end
    self:discard()
    return true, slot
  end
  local applied, why = blocks:apply(checked.slot, checked.def)
  if not applied then
    return false, { tostring(why) }
  end
  local slot = checked.slot
  self:discard()
  return true, slot
end

--- One line for the Draft property.
function Draft:describe()
  if self.raw == nil then
    return "No draft"
  end
  local label = Defs.TYPES[self.raw.type].label
  local what
  if self.target ~= nil then
    local block = self.blocks.blocks[self.target]
    what = string.format('Editing %s "%s" (%s)', Defs.slotLabel(self.target), block and block.name or "?", label)
  else
    what = string.format("New %s block", label)
  end
  return what .. (self.checked ~= nil and " - checked, ready to apply" or " - not checked")
end

--- What to remember across a restart: only what the draft is FOR. The text
--- lives in Composer's own properties.
function Draft:serialize()
  if self.raw == nil then
    return nil
  end
  return { type = self.raw.type, target = self.target, template = self.template }
end

return M
