--- SmartBuildOS AI Core — the persisted priority buffer for while no Agent
--- is reachable (pure; persistence injected).
---
--- The normal path is the module client's stage → the Agent's durable,
--- acknowledged queue. This buffer exists only for the gap when no Agent
--- answers (not installed yet, reloading, unreachable): it keeps CRITICAL
--- envelopes only (severity warning or above), at most `capacity`, persisted
--- so a controller restart does not lose them. When full, the lowest
--- severity, then the oldest, is dropped — and every drop is counted and
--- reported (status counters, Telemetry Status, the next ai_core.status).
--- An envelope id already held is refused (dedup). On recovery the buffer
--- is drained oldest first, so the Agent receives them in the order they
--- happened. Non-critical events meanwhile wait in the module client's own
--- in-memory stage (300, drop-oldest, counted), which a restart clears.

local M = {}

M.CAPACITY_DEFAULT = 50
M.SEVERITY = { debug = 0, info = 1, notice = 2, warning = 3, error = 4, critical = 5 }
M.CRITICAL_AT = 3 -- warning

local Buffer = {}
Buffer.__index = Buffer

function M.isCritical(env)
  return type(env) == "table" and (M.SEVERITY[tostring(env.severity)] or 0) >= M.CRITICAL_AT
end

--- @param io table { load = fn():table|nil, save = fn(doc) }
function M.new(io, capacity)
  local self = setmetatable({}, Buffer)
  self.io = io
  self.capacity = capacity or M.CAPACITY_DEFAULT
  self.items = {} -- oldest first
  self.ids = {}
  self.dropped = 0
  self.duplicates = 0
  self.flushed = 0
  local doc = io and io.load and io.load() or nil
  if type(doc) == "table" then
    self.dropped = tonumber(doc.dropped) or 0
    self.flushed = tonumber(doc.flushed) or 0
  end
  if type(doc) == "table" and type(doc.items) == "table" then
    local loaded = {}
    for _, env in ipairs(doc.items) do
      if type(env) == "table" and type(env.event_id) == "string" and not self.ids[env.event_id] then
        loaded[#loaded + 1] = env
        self.ids[env.event_id] = true
      end
    end
    -- A persisted document is bounded like a live buffer: keep `capacity`,
    -- the most severe first and among equals the newest; the rest is a
    -- counted drop. Order (oldest first) is kept for what stays.
    if #loaded > self.capacity then
      local rank = {}
      for i, env in ipairs(loaded) do
        rank[i] = { i = i, s = M.SEVERITY[env.severity] or 0 }
      end
      table.sort(rank, function(a, b)
        if a.s ~= b.s then
          return a.s > b.s
        end
        return a.i > b.i
      end)
      local keep = {}
      for n = 1, self.capacity do
        keep[rank[n].i] = true
      end
      local bounded = {}
      for i, env in ipairs(loaded) do
        if keep[i] then
          bounded[#bounded + 1] = env
        else
          self.ids[env.event_id] = nil
        end
      end
      self.dropped = self.dropped + (#loaded - #bounded)
      loaded = bounded
    end
    self.items = loaded
  end
  return self
end

function Buffer:save()
  if self.io and self.io.save then
    self.io.save({ v = 1, items = self.items, dropped = self.dropped, flushed = self.flushed })
  end
end

--- Holds one critical envelope. Returns "held" | "duplicate" | "not_critical"
--- | "dropped_new" (the newcomer was the least important) | "invalid" (no
--- event id: it could neither be deduplicated nor acknowledged).
function Buffer:push(env)
  if not M.isCritical(env) then
    return "not_critical"
  end
  if type(env.event_id) ~= "string" or env.event_id == "" then
    return "invalid"
  end
  if self.ids[env.event_id] then
    self.duplicates = self.duplicates + 1
    return "duplicate"
  end
  if #self.items >= self.capacity then
    -- Evict the least severe, oldest first; the newcomer itself if it is
    -- the least severe of all.
    local victim, worst = nil, math.huge
    for i, held in ipairs(self.items) do
      local s = M.SEVERITY[held.severity] or 0
      if s < worst then
        victim, worst = i, s
      end
    end
    local mine = M.SEVERITY[env.severity] or 0
    self.dropped = self.dropped + 1
    if victim == nil or mine < worst then
      self:save()
      return "dropped_new"
    end
    local gone = table.remove(self.items, victim)
    self.ids[gone.event_id] = nil
  end
  self.items[#self.items + 1] = env
  self.ids[env.event_id] = true
  self:save()
  return "held"
end

--- Hands every held envelope to `send(env)` oldest first and forgets it.
--- Returns how many were handed over.
function Buffer:drain(send)
  local n = 0
  local items = self.items
  self.items, self.ids = {}, {}
  for _, env in ipairs(items) do
    local ok = pcall(send, env)
    if ok then
      n = n + 1
    else
      self.dropped = self.dropped + 1
    end
  end
  self.flushed = self.flushed + n
  self:save()
  return n
end

function Buffer:depth()
  return #self.items
end

function Buffer:counters()
  return {
    depth = #self.items,
    capacity = self.capacity,
    dropped = self.dropped,
    duplicates = self.duplicates,
    flushed = self.flushed,
  }
end

return M
