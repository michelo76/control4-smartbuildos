--- Reading and writing MQTT payloads for the child drivers (pure).
---
--- Incoming: pick one field out of a JSON payload by a dotted path
--- (`a.b.c`, array items by 0-based index `a.0.b` or `a[0].b`), or take the
--- whole payload when the path is empty (`ON`, `true`, `23.5` as plain text
--- work too), then map the value to active/inactive, to a percentage or to a
--- number.
---
--- Outgoing: fill `{value}`-style placeholders in a payload template.
---
--- Pure: JSON is the only dependency and is required lazily.

local M = {}

local function json()
  JSON = JSON or require("JSON")
  return JSON
end

--- JSON null (the library's sentinel, or nothing) counts as "no value".
local function isNull(v)
  return v == nil or (JSON ~= nil and v == JSON.null)
end

-- ─── Paths ─────────────────────────────────────────────────────────────────

--- "a.b[2].c" → { "a", "b", "2", "c" }
function M.parsePath(path)
  local tokens = {}
  path = tostring(path or ""):gsub("^%s+", ""):gsub("%s+$", "")
  path = path:gsub("%[(%d+)%]", ".%1")
  for token in path:gmatch("[^%.]+") do
    tokens[#tokens + 1] = token
  end
  return tokens
end

--- Walks `value` along `path`. Returns the item or nil. A numeric step first
--- tries the key as a string (objects with keys like "1"), then the 0-based
--- array position.
function M.get(value, path)
  for _, token in ipairs(M.parsePath(path)) do
    if type(value) ~= "table" then
      return nil
    end
    local nextValue = value[token]
    if nextValue == nil then
      local n = tonumber(token)
      if n ~= nil and n >= 0 and n == math.floor(n) then
        nextValue = value[n + 1]
      end
    end
    value = nextValue
    if isNull(value) then
      return nil
    end
  end
  return value
end

--- Decodes a payload to a Lua value when it is JSON, otherwise returns the
--- trimmed text. A payload that is plain text never raises.
function M.decode(payload)
  payload = tostring(payload or "")
  local text = payload:gsub("^%s+", ""):gsub("%s+$", "")
  if text == "" then
    return nil, text
  end
  local first = text:sub(1, 1)
  if
    first == "{"
    or first == "["
    or first == '"'
    or text == "true"
    or text == "false"
    or text == "null"
    or tonumber(text) ~= nil
  then
    local ok, value = pcall(function()
      return json():decode(text)
    end)
    if ok then
      return value, text
    end
  end
  return text, text
end

--- The value a field setting names. An empty field takes the whole payload.
--- @return any value  nil when the payload has no such field
function M.extract(payload, field)
  local value, text = M.decode(payload)
  field = tostring(field or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if field == "" then
    if type(value) == "table" then
      return nil -- a whole JSON object is not a scalar; name the field
    end
    return isNull(value) and nil or value
  end
  if type(value) ~= "table" then
    return nil
  end
  local item = M.get(value, field)
  if type(item) == "table" then
    return nil
  end
  return item
end

-- ─── Value maps ────────────────────────────────────────────────────────────

local ACTIVE = {
  ["true"] = true,
  ["on"] = true,
  ["1"] = true,
  ["yes"] = true,
  ["detected"] = true,
  ["open"] = true,
  ["opened"] = true,
  ["active"] = true,
  ["occupied"] = true,
  ["motion"] = true,
  ["presence"] = true,
  ["pressed"] = true,
  ["wet"] = true,
  ["leak"] = true,
  ["alarm"] = true,
  ["triggered"] = true,
  ["tampered"] = true,
}
local INACTIVE = {
  ["false"] = true,
  ["off"] = true,
  ["0"] = true,
  ["no"] = true,
  ["clear"] = true,
  ["closed"] = true,
  ["close"] = true,
  ["inactive"] = true,
  ["unoccupied"] = true,
  ["none"] = true,
  ["dry"] = true,
  ["released"] = true,
  ["normal"] = true,
  ["no_motion"] = true,
  ["idle"] = true,
}

local function norm(v)
  return (tostring(v):lower():gsub("^%s+", ""):gsub("%s+$", ""))
end

--- "ON, detected" → { on = true, detected = true } (lowercase set).
function M.parseValueList(csv)
  local set, any = {}, false
  for item in tostring(csv or ""):gmatch("[^,]+") do
    local v = norm(item)
    if v ~= "" then
      set[v] = true
      any = true
    end
  end
  return any and set or nil
end

--- Maps a scalar to active (true), inactive (false) or unknown (nil).
--- @param opts table|nil { active = set, inactive = set, invert = bool }
---        With custom sets, ONLY those values count (and numbers are tested
---        as text); with none, the built-in words and numbers apply.
function M.toActive(value, opts)
  opts = opts or {}
  if isNull(value) or type(value) == "table" then
    return nil
  end
  local result
  if opts.active or opts.inactive then
    local key = norm(value)
    if opts.active and opts.active[key] then
      result = true
    elseif opts.inactive and opts.inactive[key] then
      result = false
    elseif opts.active and not opts.inactive then
      result = false -- only "active" values were listed: anything else is inactive
    end
  elseif type(value) == "boolean" then
    result = value
  elseif type(value) == "number" then
    result = value ~= 0
  else
    local key = norm(value)
    if ACTIVE[key] then
      result = true
    elseif INACTIVE[key] then
      result = false
    elseif tonumber(key) ~= nil then
      result = tonumber(key) ~= 0
    end
  end
  if result ~= nil and opts.invert then
    result = not result
  end
  return result
end

--- Scales a payload number in [min, max] to a whole percentage 0..100.
--- invert flips the percentage (a shade reporting 0 = open).
--- @return number|nil
function M.toPercent(value, min, max, invert)
  if isNull(value) or type(value) == "table" or type(value) == "boolean" then
    return nil
  end
  local n = tonumber(value)
  if n == nil then
    return nil
  end
  min, max = tonumber(min) or 0, tonumber(max) or 100
  if max == min then
    return nil
  end
  local pct = (n - min) / (max - min) * 100
  pct = math.max(0, math.min(100, pct))
  pct = math.floor(pct + 0.5)
  if invert then
    pct = 100 - pct
  end
  return pct
end

--- The reverse: a percentage to the payload's own range.
function M.fromPercent(pct, min, max, invert)
  pct = math.max(0, math.min(100, tonumber(pct) or 0))
  if invert then
    pct = 100 - pct
  end
  min, max = tonumber(min) or 0, tonumber(max) or 100
  return math.floor(min + (max - min) * pct / 100 + 0.5)
end

--- Availability payloads: Zigbee2MQTT `online`/`offline` as text or as
--- {"state":"online"}. Returns true, false, or nil when not recognisable.
function M.availability(payload, field)
  local value = M.decode(payload)
  if type(value) == "table" then
    value = M.get(value, (field and field ~= "") and field or "state")
  end
  if value == nil then
    return nil
  end
  local key = norm(value)
  if key == "online" or key == "true" or key == "1" or key == "available" then
    return true
  elseif key == "offline" or key == "false" or key == "0" or key == "unavailable" then
    return false
  end
  return nil
end

-- ─── Templates ─────────────────────────────────────────────────────────────

--- Replaces `{name}` with vars[name]; unknown placeholders stay as typed so
--- a typo is visible in the published payload rather than silently empty.
function M.render(template, vars)
  vars = vars or {}
  return (
    tostring(template or ""):gsub("{([%w_]+)}", function(name)
      local v = vars[name]
      if v == nil then
        return nil
      end
      return tostring(v)
    end)
  )
end

return M
