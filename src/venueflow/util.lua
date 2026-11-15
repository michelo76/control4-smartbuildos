--- VenueFlow: small pure helpers shared by every module.

local M = {}

function M.trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

function M.clamp(n, lo, hi)
  if n < lo then
    return lo
  elseif n > hi then
    return hi
  end
  return n
end

function M.round(n)
  return math.floor(n + 0.5)
end

--- Deep copy of plain data (no metatables, cycle-guarded).
function M.copy(value, seen)
  if type(value) ~= "table" then
    return value
  end
  seen = seen or {}
  if seen[value] then
    return seen[value]
  end
  local out = {}
  seen[value] = out
  for k, v in pairs(value) do
    out[M.copy(k, seen)] = M.copy(v, seen)
  end
  return out
end

--- Structural equality of plain data.
function M.equal(a, b)
  if type(a) ~= type(b) then
    return false
  end
  if type(a) ~= "table" then
    return a == b
  end
  for k, v in pairs(a) do
    if not M.equal(v, b[k]) then
      return false
    end
  end
  for k in pairs(b) do
    if a[k] == nil then
      return false
    end
  end
  return true
end

--- A list in the JSON sense: a table whose keys are exactly 1..n (or empty).
function M.isList(t)
  if type(t) ~= "table" then
    return false
  end
  local n = 0
  for _ in pairs(t) do
    n = n + 1
  end
  for i = 1, n do
    if t[i] == nil then
      return false
    end
  end
  return true
end

function M.list(t)
  if type(t) ~= "table" then
    return {}
  end
  return t
end

function M.contains(list, value)
  for _, v in ipairs(list or {}) do
    if v == value then
      return true
    end
  end
  return false
end

function M.indexById(list)
  local out = {}
  for _, item in ipairs(list or {}) do
    if type(item) == "table" and item.id ~= nil then
      out[item.id] = item
    end
  end
  return out
end

function M.sortedKeys(t)
  local keys = {}
  for k in pairs(t or {}) do
    keys[#keys + 1] = k
  end
  table.sort(keys, function(a, b)
    return tostring(a) < tostring(b)
  end)
  return keys
end

function M.count(t)
  local n = 0
  for _ in pairs(t or {}) do
    n = n + 1
  end
  return n
end

--- Identifiers are lower-case slugs. They never change once created, so a
--- rename in the Studio touches `name`, never `id`.
M.ID_PATTERN = "^[a-z0-9][a-z0-9_%-]*$"
M.ID_MAX = 48

function M.isId(s)
  return type(s) == "string" and #s >= 1 and #s <= M.ID_MAX and s:match(M.ID_PATTERN) ~= nil
end

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

--- Standard base64 WITHOUT padding (pure Lua: the core does not reach for C4).
function M.base64(text)
  local out, n = {}, #text
  for i = 1, n, 3 do
    local a, b, c = text:byte(i, i + 2)
    local v = a * 65536 + (b or 0) * 256 + (c or 0)
    local c1 = math.floor(v / 262144) % 64
    local c2 = math.floor(v / 4096) % 64
    local c3 = math.floor(v / 64) % 64
    local c4 = v % 64
    out[#out + 1] = B64:sub(c1 + 1, c1 + 1)
      .. B64:sub(c2 + 1, c2 + 1)
      .. (b and B64:sub(c3 + 1, c3 + 1) or "")
      .. (c and B64:sub(c4 + 1, c4 + 1) or "")
  end
  return table.concat(out)
end

--- The reverse, for tests and for tools. Ignores anything outside the alphabet.
function M.unbase64(text)
  local index = {}
  for i = 1, #B64 do
    index[B64:byte(i)] = i - 1
  end
  local out, acc, bits = {}, 0, 0
  for i = 1, #text do
    local v = index[text:byte(i)]
    if v ~= nil then
      acc = acc * 64 + v
      bits = bits + 6
      if bits >= 8 then
        bits = bits - 8
        local byte = math.floor(acc / 2 ^ bits)
        out[#out + 1] = string.char(byte)
        acc = acc - byte * 2 ^ bits
      end
    end
  end
  return table.concat(out)
end

--- "Bar TV 01" -> "bar-tv-01".
function M.slug(text)
  local s = tostring(text or ""):lower():gsub("[^a-z0-9]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
  if s == "" then
    s = "item"
  end
  return s:sub(1, M.ID_MAX)
end

--- A new id not present in `taken` (a set).
function M.freshId(base, taken)
  local id = M.slug(base)
  if not taken[id] then
    return id
  end
  local n = 2
  while true do
    local suffix = "-" .. n
    local candidate = id:sub(1, M.ID_MAX - #suffix) .. suffix
    if not taken[candidate] then
      return candidate
    end
    n = n + 1
  end
end

--- "HH:MM" -> minutes since midnight, or nil.
function M.parseTime(text)
  local h, m = tostring(text or ""):match("^(%d%d?):(%d%d)$")
  h, m = tonumber(h), tonumber(m)
  if h == nil or m == nil or h > 23 or m > 59 then
    return nil
  end
  return h * 60 + m
end

function M.formatTime(minutes)
  return string.format("%02d:%02d", math.floor(minutes / 60) % 24, minutes % 60)
end

--- Lua's wday is 1 = Sunday. VenueFlow uses ISO: 1 = Monday .. 7 = Sunday.
function M.isoWeekday(wday)
  return ((wday + 5) % 7) + 1
end

--- Text safe to put in one log line or a JSON string we build by hand.
function M.oneLine(s, max)
  s = tostring(s or ""):gsub("[%c]", " ")
  if max and #s > max then
    s = s:sub(1, max)
  end
  return s
end

return M
