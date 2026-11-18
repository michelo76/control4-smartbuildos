--- SmartBuildOS AI Core — event collection without double capture (pure).
---
--- ARCHITECTURE D7: AI Core consumes the event classes the Flight Recorder
--- already captures (by subscribing to its topics through the Agent) and
--- collects ITSELF only what the Flight Recorder does not capture — plus a
--- small documented set when no Flight Recorder is installed. The split,
--- read from the Flight Recorder's source (drivers/smartbuildos-flight-
--- recorder, src/tracer, src/flightrecorder):
---
---   class                               Flight Recorder        AI Core
---   Composer device events (all devs)   capture.event          consumes `capture.` topic; never registers device events
---   selected device/room variables      observation.change     consumes `observation.`; own listeners ONLY when FR absent
---   programming markers / traces        observation.programmed, trace.*  consumes; AI_RECORD_EVENT is AI Core's own marker
---   Agent-classified events             observation.system (when selected)  own record ONLY when FR absent
---   Director system events (OnSystemEvent)  not captured       own collector, always (documented ids only)
---
--- Every own observation passes `admit` first: learning paused, licence
--- halted, excluded room, excluded category, per-minute budget and event-id
--- dedup are all decided BEFORE anything is recorded. DriverWorks does not
--- say who caused a change, what the previous value was, or that a
--- programming item ran, so no event built here claims any of those.

local V = require("aicore.vocab")

local M = {}

--- Director system events AI Core registers for (documented ids only;
--- API reference › Event Interface). Severity: what the buffer keeps.
M.SYSTEM_EVENTS = {
  { id = 17, name = "OnNetworkBindingAdded", severity = "info" },
  { id = 18, name = "OnNetworkBindingRemoved", severity = "notice" },
  { id = 19, name = "OnNetworkBindingRegistered", severity = "info" },
  { id = 20, name = "OnNetworkBindingUnregistered", severity = "notice" },
  { id = 48, name = "OnDeviceOnline", severity = "info" },
  { id = 49, name = "OnDeviceOffline", severity = "warning" },
  { id = 90, name = "OnDirectorIPAddressChanged", severity = "notice" },
}
M.SYSTEM_BY_NAME = {}
for _, e in ipairs(M.SYSTEM_EVENTS) do
  M.SYSTEM_BY_NAME[e.name] = e
end

--- Topics consumed from the Flight Recorder (the Agent's MODULE_TOPIC_POLICY
--- grants exactly these to ai_core).
M.FR_TOPICS = { "capture.", "observation.", "trace." }

M.DEDUP_RING = 512

--- The event name in an OnSystemEvent payload. The payload format is not
--- documented ("event specific"); shipped drivers read a name="…"
--- attribute. Nil when it cannot be read: such an event is not guessed at.
function M.systemEventName(data)
  if type(data) ~= "string" then
    return nil
  end
  local name = data:match('name="(.-)"') or data:match("<name>(.-)</name>")
  if name ~= nil and name ~= "" then
    return name
  end
  if data:match("^On%a+$") then
    return data
  end
  return nil
end

--- Category of an envelope consumed from the Flight Recorder. A category the
--- recorder's configuration gave is used; otherwise what the event type
--- implies; otherwise `unknown` (never a guess from a device's name).
function M.categoryOf(env)
  local p = type(env) == "table" and type(env.payload) == "table" and env.payload or {}
  local c = p.category
  if type(c) == "string" and V.CATEGORIES[c] then
    return c
  end
  local t = tostring(type(env) == "table" and env.event_type or "")
  if t:find("^trace%.") or t == "observation.programmed" then
    return "programming"
  end
  if t == "observation.system" then
    return "system"
  end
  return "unknown"
end

--- What to collect, from what is known about the Flight Recorder.
--- @param fr string "present" (v2, serves topics) | "present_v1" | "absent" | "unknown"
--- @param cfg table aicore.config document
--- @param active boolean learning on AND licence not halted
function M.plan(fr, cfg, active)
  local c = cfg.collection
  local frGone = fr == "absent"
  return {
    subscribe = active and fr == "present" and c.flight_recorder_topics == true,
    system_events = active and c.system_events == true,
    agent_events = active and frGone and c.agent_events == true,
    variables = active and frGone and #c.variables > 0,
    flight_recorder = fr,
  }
end

local Collector = {}
Collector.__index = Collector

--- @param deps table { now = fn():number }
function M.new(deps)
  local self = setmetatable({}, Collector)
  self.now = deps.now
  self.policy = {
    active = true,
    excludedRooms = {},
    excludedCategories = {},
    maxPerMinute = 60,
  }
  self.window = { start = deps.now(), count = 0 }
  self.seen = { map = {}, order = {} }
  self.counters = {
    admitted = 0,
    paused = 0,
    excluded_room = 0,
    excluded_category = 0,
    over_budget = 0,
    duplicate = 0,
    consumed = 0,
    consumed_dropped_by_agent = 0,
  }
  return self
end

function Collector:setPolicy(p)
  for k, v in pairs(p) do
    self.policy[k] = v
  end
end

--- Remembers an event id; true when it was new.
function Collector:remember(id)
  if id == nil then
    return true
  end
  if self.seen.map[id] then
    return false
  end
  self.seen.map[id] = true
  self.seen.order[#self.seen.order + 1] = id
  while #self.seen.order > M.DEDUP_RING do
    local old = table.remove(self.seen.order, 1)
    self.seen.map[old] = nil
  end
  return true
end

--- Decides whether an observation may be recorded / used. `ev` =
--- { id?, room_id?, category, budgeted? }. Returns ok, reason.
function Collector:admit(ev)
  local p = self.policy
  if not p.active then
    self.counters.paused = self.counters.paused + 1
    return false, "paused"
  end
  if ev.room_id ~= nil and p.excludedRooms[tonumber(ev.room_id)] then
    self.counters.excluded_room = self.counters.excluded_room + 1
    return false, "excluded_room"
  end
  if p.excludedCategories[ev.category or "unknown"] then
    self.counters.excluded_category = self.counters.excluded_category + 1
    return false, "excluded_category"
  end
  if ev.id ~= nil and self.seen.map[ev.id] then
    self.counters.duplicate = self.counters.duplicate + 1
    return false, "duplicate"
  end
  if ev.budgeted ~= false then
    local t = self.now()
    if t - self.window.start >= 60 then
      self.window = { start = t, count = 0 }
    end
    if self.window.count >= (p.maxPerMinute or 60) then
      self.counters.over_budget = self.counters.over_budget + 1
      return false, "over_budget"
    end
    self.window.count = self.window.count + 1
  end
  self:remember(ev.id)
  self.counters.admitted = self.counters.admitted + 1
  return true
end

--- Consumes a PUBLISH frame of Flight Recorder envelopes: dedup by event id
--- (a re-subscription can deliver one twice), exclusions and pause applied.
--- Nothing is re-uploaded: these events already reach the cloud through the
--- Flight Recorder's own upload. Returns the admitted envelopes.
function Collector:consume(events, dropped)
  local out = {}
  self.counters.consumed_dropped_by_agent = self.counters.consumed_dropped_by_agent + (tonumber(dropped) or 0)
  for _, env in ipairs(type(events) == "table" and events or {}) do
    if type(env) == "table" and type(env.event_id) == "string" then
      local ok = self:admit({
        id = env.event_id,
        room_id = env.room_id,
        category = M.categoryOf(env),
        budgeted = false, -- already budgeted by the Flight Recorder
      })
      if ok then
        self.counters.consumed = self.counters.consumed + 1
        out[#out + 1] = env
      end
    end
  end
  return out
end

return M
