--- Dealer Settings — the settings model (pure).
---
--- Twelve dealer-defined settings, each described by a property quartet in
--- Composer (`Setting N Name`, `Setting N Type`, `Setting N Value`,
--- `Setting N Options`) and exposed to programming as variables. The
--- Composer properties are the ONE truth: a web-view write lands in the
--- `Setting N Value` property and the model is rebuilt from the properties,
--- so a dealer reading Composer and a dealer reading the panel see the same.
---
--- Rules a technician relies on:
---   • A slot with an empty Name is unused: no variable value, not shown.
---   • Types: Number (range from Options "min..max", default 0..100),
---     Toggle (On/Off), Text (≤ 200 chars), Choice (Options is the list).
---   • A value that does not fit its type is REFUSED with a reason and the
---     previous value stays; nothing is silently clamped or truncated.
---   • Choice values are matched case-insensitively and stored canonically.
---   • Number values are compared numerically ("50" == "50.0") so the
---     programming conditional does not depend on how a number was typed.

local M = {}

M.SLOTS = 12
M.TYPES = { Number = true, Toggle = true, Text = true, Choice = true }
M.LIMITS = { name = 40, text = 200, options = 400, choices = 24 }

local function trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end
M.trim = trim

--- Options text for a type → parsed options or a refusal reason.
--- Number: "min..max", "min-max" (first dash after a digit) or "min,max";
--- empty → 0..100. Choice: comma, semicolon or pipe separated, ≤ 24.
function M.parseOptions(kind, text)
  text = trim(text):sub(1, M.LIMITS.options)
  if kind == "Number" then
    if text == "" then
      return { min = 0, max = 100 }
    end
    local a, b = text:match("^(%-?%d+%.?%d*)%s*%.%.%s*(%-?%d+%.?%d*)$")
    if a == nil then
      a, b = text:match("^(%-?%d+%.?%d*)%s*[,;]%s*(%-?%d+%.?%d*)$")
    end
    if a == nil then
      a, b = text:match("^(%-?%d+%.?%d*)%s*%-%s*(%-?%d+%.?%d*)$")
    end
    local min, max = tonumber(a), tonumber(b)
    if min == nil or max == nil then
      return nil, "Options must be a range like 0..100"
    end
    if min > max then
      min, max = max, min
    end
    return { min = min, max = max }
  elseif kind == "Choice" then
    local list, seen = {}, {}
    for item in text:gmatch("[^,;|]+") do
      item = trim(item)
      if item ~= "" and not seen[item:lower()] and #list < M.LIMITS.choices then
        list[#list + 1] = item
        seen[item:lower()] = true
      end
    end
    if #list == 0 then
      return nil, "Options must list the choices, separated by commas"
    end
    return { choices = list }
  end
  return {}
end

--- Coerces a raw (string) value for a definition. Returns value or nil + reason.
function M.coerce(def, raw)
  local s = trim(raw)
  if def.type == "Number" then
    local n = tonumber(s)
    if n == nil then
      return nil, "not a number"
    end
    if n < def.options.min or n > def.options.max then
      return nil, string.format("outside %s..%s", tostring(def.options.min), tostring(def.options.max))
    end
    return n
  elseif def.type == "Toggle" then
    local l = s:lower()
    if l == "on" or l == "true" or l == "yes" or l == "1" then
      return true
    elseif l == "off" or l == "false" or l == "no" or l == "0" or l == "" then
      return false
    end
    return nil, "must be On or Off"
  elseif def.type == "Text" then
    if #s > M.LIMITS.text then
      return nil, "longer than " .. M.LIMITS.text .. " characters"
    end
    return s
  elseif def.type == "Choice" then
    for _, choice in ipairs(def.options.choices) do
      if choice:lower() == s:lower() then
        return choice
      end
    end
    return nil, "not one of: " .. table.concat(def.options.choices, ", ")
  end
  return nil, "unknown type"
end

--- The default value of a type (what an empty Value property means).
function M.default(def)
  if def.type == "Number" then
    local z = 0
    if z < def.options.min or z > def.options.max then
      z = def.options.min
    end
    return z
  elseif def.type == "Toggle" then
    return false
  elseif def.type == "Choice" then
    return def.options.choices[1]
  end
  return ""
end

--- The property/variable text form of a value.
function M.text(def, value)
  if def == nil or value == nil then
    return ""
  end
  if def.type == "Toggle" then
    return value and "On" or "Off"
  elseif def.type == "Number" then
    if value == math.floor(value) then
      return tostring(math.floor(value))
    end
    return tostring(value)
  end
  return tostring(value)
end

--- The NUMBER-variable form: the number itself, 1/0 for a toggle, 0 otherwise.
function M.numeric(def, value)
  if def == nil or value == nil then
    return 0
  end
  if def.type == "Number" then
    return value
  elseif def.type == "Toggle" then
    return value and 1 or 0
  end
  local n = tonumber(value)
  return n or 0
end

--- One slot's definition from its four properties. `refusal` is set when
--- the slot is named but unusable (bad type or options); it is then shown
--- but has no value.
function M.define(slot, name, kind, options)
  local def = { slot = slot, name = trim(name):sub(1, M.LIMITS.name), type = trim(kind), options = {}, refusal = nil }
  def.enabled = def.name ~= ""
  if not def.enabled then
    return def
  end
  if not M.TYPES[def.type] then
    def.refusal = "Type must be Number, Toggle, Text or Choice"
    return def
  end
  local parsed, why = M.parseOptions(def.type, options)
  if parsed == nil then
    def.refusal = why
    return def
  end
  def.options = parsed
  return def
end

--- Builds the model from a Properties-like table (string values).
--- @return table model { slots = { [n] = { def, value, raw, refusal } }, configured = n, refusals = {...} }
function M.build(props)
  props = props or {}
  local model = { slots = {}, configured = 0, refusals = {} }
  for n = 1, M.SLOTS do
    local def = M.define(
      n,
      props["Setting " .. n .. " Name"],
      props["Setting " .. n .. " Type"],
      props["Setting " .. n .. " Options"]
    )
    local entry = { def = def, value = nil, raw = trim(props["Setting " .. n .. " Value"]), refusal = def.refusal }
    if def.enabled and def.refusal == nil then
      model.configured = model.configured + 1
      if entry.raw == "" then
        entry.value = M.default(def)
      else
        local value, why = M.coerce(def, entry.raw)
        if value == nil then
          entry.value = M.default(def)
          entry.refusal = "Value " .. why .. "; default in force"
        else
          entry.value = value
        end
      end
    end
    if entry.refusal ~= nil and def.enabled then
      model.refusals[#model.refusals + 1] = { slot = n, name = def.name, reason = entry.refusal }
    end
    model.slots[n] = entry
  end
  return model
end

--- Finds a configured slot by name (case-insensitive) or by number.
function M.find(model, nameOrSlot)
  local n = tonumber(nameOrSlot)
  if n ~= nil and model.slots[n] ~= nil then
    local e = model.slots[n]
    if e.def.enabled and e.def.refusal == nil then
      return e
    end
    return nil
  end
  local wanted = trim(nameOrSlot):lower()
  if wanted == "" then
    return nil
  end
  for _, e in ipairs(model.slots) do
    if e.def.enabled and e.def.refusal == nil and e.def.name:lower() == wanted then
      return e
    end
  end
  return nil
end

--- Whether two values of a definition are the same setting.
function M.same(def, a, b)
  if def.type == "Number" then
    return tonumber(a) == tonumber(b)
  elseif def.type == "Choice" then
    return tostring(a):lower() == tostring(b):lower()
  end
  return a == b
end

--- A proposed write: returns the coerced value and whether it changes the
--- slot, or nil + reason. Pure; the caller writes the property.
function M.propose(model, nameOrSlot, raw)
  local e = M.find(model, nameOrSlot)
  if e == nil then
    return nil, nil, "no setting named " .. tostring(nameOrSlot)
  end
  local value, why = M.coerce(e.def, raw)
  if value == nil then
    return nil, nil, why
  end
  return e, value, nil, not M.same(e.def, e.value, value)
end

--- Compares a slot's value with a Composer-typed string the way the
--- STRING conditional does (numbers numerically, choices by name).
function M.equalsText(e, text)
  if e == nil or e.value == nil then
    return false
  end
  local def = e.def
  if def.type == "Number" then
    return tonumber(trim(text)) == e.value
  elseif def.type == "Toggle" then
    local v = M.coerce(def, text)
    return v ~= nil and v == e.value
  end
  return M.same(def, e.value, trim(text))
end

--- The JSON-able document the page renders.
function M.snapshot(model, extra)
  local settings = {}
  for _, e in ipairs(model.slots) do
    if e.def.enabled then
      settings[#settings + 1] = {
        slot = e.def.slot,
        name = e.def.name,
        type = e.def.type,
        value = e.value,
        text = M.text(e.def, e.value),
        min = e.def.options.min,
        max = e.def.options.max,
        choices = e.def.options.choices,
        refusal = e.refusal,
      }
    end
  end
  local doc = { settings = settings, configured = model.configured }
  for k, v in pairs(extra or {}) do
    doc[k] = v
  end
  return doc
end

return M
