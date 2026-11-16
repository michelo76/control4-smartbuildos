--- Who listens to which topic, which topics the broker has been seen
--- carrying, and when each listener last heard something (pure).
---
--- Entities are the child drivers: each registers the topic filters it needs
--- (its state topic, optionally an availability topic). The router answers
--- "which entities get this message" and "which filters must the broker
--- connection be subscribed to". The seen-topics list is capped so a chatty
--- broker cannot grow it without bound; it keeps only topic names and counts,
--- never payloads (a payload can carry a credential, a topic name cannot).

local Topics = require("mqtt.topics")

local Router = {}
Router.__index = Router

local M = {}

M.DEFAULT_SEEN_CAP = 200
M.MAX_ENTITIES = 128
M.MAX_FILTERS_PER_ENTITY = 4

--- @param opts table { now = fn():number, seen_cap = 200 }
function M.new(opts)
  opts = opts or {}
  return setmetatable({
    now = opts.now or os.time,
    seenCap = opts.seen_cap or M.DEFAULT_SEEN_CAP,
    entities = {}, -- id -> { id, kind, name, filters, last_seen, last_topic, messages, available }
    seen = {}, -- topic -> { topic, count, last }
    seenCount = 0,
    dropped = 0,
  }, Router)
end

-- ─── Entities ──────────────────────────────────────────────────────────────

--- Registers (or replaces) an entity. Invalid filters are dropped and listed
--- in the second result so the child can say why it hears nothing.
--- @return table|nil entity, table rejected  { { filter, why }, ... }
function Router:setEntity(id, spec)
  id = tostring(id)
  local rejected, filters = {}, {}
  local existing = self.entities[id]
  if existing == nil then
    local count = 0
    for _ in pairs(self.entities) do
      count = count + 1
    end
    if count >= M.MAX_ENTITIES then
      return nil, { { filter = "", why = "the broker already serves " .. M.MAX_ENTITIES .. " devices" } }
    end
  end
  local wanted = {}
  for _, filter in ipairs(spec.filters or {}) do
    wanted[#wanted + 1] = filter
  end
  local availabilityAlsoState = false
  for _, filter in ipairs(wanted) do
    availabilityAlsoState = availabilityAlsoState or filter == spec.availability
  end
  if spec.availability and spec.availability ~= "" and not availabilityAlsoState then
    wanted[#wanted + 1] = spec.availability
  end
  local availability = nil
  for _, filter in ipairs(wanted) do
    local ok, why = Topics.validFilter(filter)
    if not ok then
      rejected[#rejected + 1] = { filter = tostring(filter), why = why }
    elseif #filters < M.MAX_FILTERS_PER_ENTITY then
      filters[#filters + 1] = filter
      if filter == spec.availability and not availabilityAlsoState then
        availability = filter
      end
    end
  end
  local entity = existing or { id = id, messages = 0 }
  entity.kind = spec.kind or entity.kind or "device"
  entity.name = spec.name or entity.name or ("device " .. id)
  entity.filters = filters
  entity.availability = availability
  if availability == nil then
    entity.available = nil
  end
  self.entities[id] = entity
  return entity, rejected
end

function Router:removeEntity(id)
  self.entities[tostring(id)] = nil
end

function Router:entity(id)
  return self.entities[tostring(id)]
end

function Router:entityCount()
  local n = 0
  for _ in pairs(self.entities) do
    n = n + 1
  end
  return n
end

--- Every distinct filter the entities need, sorted (stable for tests).
function Router:filters()
  local set, out = {}, {}
  for _, e in pairs(self.entities) do
    for _, f in ipairs(e.filters) do
      if not set[f] then
        set[f] = true
        out[#out + 1] = f
      end
    end
  end
  table.sort(out)
  return out
end

--- Entities whose filters match `topic`. A STATE message updates the
--- entity's last_seen; a message on its availability filter (and not also on
--- a state filter) does not: the bridge reporting a device online is not the
--- device speaking.
--- @return table hits   list of { id, filter, role = "state"|"availability" }
function Router:route(topic)
  local out = {}
  local now = self.now()
  for id, e in pairs(self.entities) do
    local hit
    for _, f in ipairs(e.filters) do
      if Topics.matches(f, topic) then
        local role = (f == e.availability) and "availability" or "state"
        if hit == nil or role == "state" then
          hit = { id = id, filter = f, role = role }
        end
      end
    end
    if hit then
      if hit.role == "state" then
        e.last_seen = now
        e.last_topic = topic
        e.messages = e.messages + 1
      end
      out[#out + 1] = hit
    end
  end
  table.sort(out, function(a, b)
    return (tonumber(a.id) or 0) < (tonumber(b.id) or 0)
  end)
  return out
end

function Router:setAvailable(id, available)
  local e = self.entities[tostring(id)]
  if e then
    e.available = available
  end
end

-- ─── Seen topics ───────────────────────────────────────────────────────────

--- Notes a topic name. When the cap is hit the least recently seen topic
--- makes room.
function Router:noteTopic(topic)
  local now = self.now()
  local item = self.seen[topic]
  if item then
    item.count = item.count + 1
    item.last = now
    return
  end
  if self.seenCount >= self.seenCap then
    local oldest
    for _, s in pairs(self.seen) do
      if oldest == nil or s.last < oldest.last or (s.last == oldest.last and s.topic < oldest.topic) then
        oldest = s
      end
    end
    if oldest then
      self.seen[oldest.topic] = nil
      self.seenCount = self.seenCount - 1
      self.dropped = self.dropped + 1
    end
  end
  self.seen[topic] = { topic = topic, count = 1, last = now }
  self.seenCount = self.seenCount + 1
end

--- Most recently seen first.
function Router:seenList(limit)
  local list = {}
  for _, s in pairs(self.seen) do
    list[#list + 1] = s
  end
  table.sort(list, function(a, b)
    if a.last ~= b.last then
      return a.last > b.last
    end
    return a.topic < b.topic
  end)
  if limit and #list > limit then
    for i = #list, limit + 1, -1 do
      list[i] = nil
    end
  end
  return list
end

function Router:clearSeen()
  self.seen = {}
  self.seenCount = 0
  self.dropped = 0
end

-- ─── Health ────────────────────────────────────────────────────────────────

--- Health of every entity. `staleAfter` seconds without a message marks an
--- entity stale (0 = never stale). An entity that has never heard anything
--- reports age = nil and is "silent" rather than stale, so a freshly added
--- contact sensor is not alarming before its first event.
--- @return table { count, stale, entries = { { id, name, kind, age, state, available } } }
function Router:health(staleAfter)
  local now = self.now()
  local entries, stale = {}, 0
  for _, e in pairs(self.entities) do
    local age = e.last_seen and math.max(0, now - e.last_seen) or nil
    local state = "silent"
    if age ~= nil then
      state = (staleAfter and staleAfter > 0 and age > staleAfter) and "stale" or "ok"
    end
    if e.available == false then
      state = "offline"
    end
    if state == "stale" or state == "offline" then
      stale = stale + 1
    end
    entries[#entries + 1] = {
      id = e.id,
      name = e.name,
      kind = e.kind,
      age = age,
      state = state,
      available = e.available,
      messages = e.messages,
    }
  end
  table.sort(entries, function(a, b)
    return (tonumber(a.id) or 0) < (tonumber(b.id) or 0)
  end)
  return { count = #entries, stale = stale, entries = entries }
end

return M
