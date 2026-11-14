--- VenueFlow: the diagnostic log (pure). A fixed-size ring: the oldest entry
--- is dropped when a new one arrives, so the log can never grow without
--- bound. Nothing secret is ever stored: values under secret-looking keys are
--- replaced before an entry is kept.

local U = require("venueflow.util")

local M = {}

M.MAX = 400
M.LEVELS = { error = 1, warning = 2, info = 3, debug = 4 }
M.CATEGORIES = {
  "driver",
  "config",
  "mapping",
  "command",
  "routing",
  "audio",
  "feedback",
  "scene",
  "webview",
  "license",
  "cloud",
  "auth",
}

local SECRET_KEY = { "pin", "pass", "token", "secret", "session", "auth", "key", "hash", "salt" }

local function isSecretKey(key)
  local k = tostring(key):lower()
  for _, word in ipairs(SECRET_KEY) do
    if k:find(word, 1, true) then
      return true
    end
  end
  return false
end

--- A copy of `value` with secret-named fields replaced, long strings cut and
--- depth bounded.
function M.redact(value, depth)
  depth = depth or 0
  if type(value) == "string" then
    -- A data: URL or a long token never belongs in a log line.
    if #value > 200 then
      return value:sub(1, 60) .. "...(" .. #value .. " chars)"
    end
    return value
  end
  if type(value) ~= "table" then
    return value
  end
  if depth >= 4 then
    return "<...>"
  end
  local out = {}
  for k, v in pairs(value) do
    if isSecretKey(k) then
      out[k] = "<hidden>"
    else
      out[k] = M.redact(v, depth + 1)
    end
  end
  return out
end

local Diag = {}
Diag.__index = Diag

--- deps = { now(), max?, sink?(entry) }
function M.new(deps)
  local self = setmetatable({}, Diag)
  self.now = deps.now
  self.max = deps.max or M.MAX
  self.sink = deps.sink
  self.entries = {} -- oldest first
  self.seq = 0
  self.counts = { error = 0, warning = 0, info = 0, debug = 0 }
  return self
end

--- level: error | warning | info | debug
function Diag:add(level, category, code, message, data)
  if M.LEVELS[level] == nil then
    level = "info"
  end
  self.seq = self.seq + 1
  local entry = {
    seq = self.seq,
    at = self.now(),
    level = level,
    category = category,
    code = code,
    message = U.oneLine(message, 300),
    data = data ~= nil and M.redact(data) or nil,
  }
  self.entries[#self.entries + 1] = entry
  self.counts[level] = self.counts[level] + 1
  while #self.entries > self.max do
    table.remove(self.entries, 1)
  end
  if self.sink then
    pcall(self.sink, entry)
  end
  return entry
end

--- Newest first. filter = { level?, category?, sinceSeq?, limit? }
function Diag:list(filter)
  filter = filter or {}
  local limit = math.min(tonumber(filter.limit) or 100, self.max)
  local maxLevel = M.LEVELS[filter.level or "debug"] or 4
  local out = {}
  for i = #self.entries, 1, -1 do
    local e = self.entries[i]
    if
      M.LEVELS[e.level] <= maxLevel
      and (filter.category == nil or e.category == filter.category)
      and (filter.sinceSeq == nil or e.seq > filter.sinceSeq)
    then
      out[#out + 1] = e
      if #out >= limit then
        break
      end
    end
  end
  return out
end

function Diag:clear()
  self.entries = {}
  self.counts = { error = 0, warning = 0, info = 0, debug = 0 }
end

function Diag:size()
  return #self.entries
end

return M
