--- SmartBuildOS module registration contract v1 — the Agent's registry (pure).
---
--- An optional SmartBuildOS driver ("module": Flight Recorder today; Guardian,
--- Commissioning Inspector, Home State, Property Bridge reserved) registers
--- with the Agent over the local SendToDevice → ExecuteCommand path. Local
--- registration is NOT authorization: ExecuteCommand carries no sender
--- identity, so the registry answers each registration with a fresh token
--- sent TO THE CLAIMED DEVICE ID. Only the driver actually at that id
--- receives it, and every later frame (status, events, command results,
--- snapshots) must carry it. A module cannot speak for another module's
--- instance without that module's token.
---
--- Vocabulary (all values travel as strings in SendToDevice params):
---   module_id        stable id, ^[a-z][a-z0-9_]{2,47}$ (e.g. flight_recorder)
---   instance_id      the driver's Director device id (string)
---   driver_version   the module's driver.xml version
---   protocol_min/max the Agent protocol versions the module supports
---   capabilities     csv (e.g. "recording,traces,snapshots")
---   entitlements     csv of SKUs it needs (e.g. "SBOS_FLIGHT_RECORDER")
---   config_version   the module's configuration document version
---   status/detail    the module's own operational status + one line
---   commands         csv of registered commands (restricted operations)
---   event_types      csv of event-type prefixes it emits
---   singleton        "true" when only one instance per project is allowed
---
--- Display status (derived here, shown in Composer and Studio):
---   ready | waiting_for_agent | unpaired | degraded | unlicensed | incompatible
---
--- Pure: injected clock and token source; the Agent persists serialize().

local M = {}

M.PROTOCOL_MIN = 1
M.PROTOCOL_MAX = 1
M.LIMITS = { modules = 16, csv_items = 32, detail = 200, stale_seconds = 15 * 60 }
M.STATUS = {
  ready = "ready",
  waiting_for_agent = "waiting_for_agent",
  unpaired = "unpaired",
  degraded = "degraded",
  unlicensed = "unlicensed",
  incompatible = "incompatible",
}

local Registry = {}
Registry.__index = Registry

local function csv(value, limit)
  local out = {}
  for item in tostring(value or ""):gmatch("[^,]+") do
    item = item:gsub("^%s+", ""):gsub("%s+$", "")
    if item ~= "" then
      out[#out + 1] = item
      if #out >= (limit or M.LIMITS.csv_items) then
        break
      end
    end
  end
  return out
end

function M.csv(value, limit)
  return csv(value, limit)
end

function M.validModuleId(id)
  return type(id) == "string" and id:match("^[a-z][a-z0-9_]*$") ~= nil and #id >= 3 and #id <= 48
end

--- @param opts table { now = fun():number, newToken = fun():string }
function Registry.new(opts)
  local self = setmetatable({}, Registry)
  self.now = opts.now
  self.newToken = opts.newToken
  self.entries = {}
  return self
end

--- Restores from serialize() output; anything unreadable yields an empty
--- registry (modules re-register on the Agent's hello).
function Registry.restore(doc, opts)
  local r = Registry.new(opts)
  if type(doc) == "table" and doc.v == 1 and type(doc.entries) == "table" then
    for _, e in ipairs(doc.entries) do
      if type(e) == "table" and M.validModuleId(e.module_id) and e.instance_id ~= nil then
        r.entries[#r.entries + 1] = e
      end
    end
  end
  return r
end

function Registry:serialize()
  return { v = 1, entries = self.entries }
end

local function key(moduleId, instanceId)
  return tostring(moduleId) .. "@" .. tostring(instanceId)
end

function Registry:find(moduleId, instanceId)
  for i, e in ipairs(self.entries) do
    if e.module_id == moduleId and tostring(e.instance_id) == tostring(instanceId) then
      return e, i
    end
  end
  return nil
end

--- Every live instance of a module (stale ones excluded).
function Registry:instances(moduleId)
  local out = {}
  for _, e in ipairs(self.entries) do
    if e.module_id == moduleId and not self:isStale(e) then
      out[#out + 1] = e
    end
  end
  return out
end

function Registry:isStale(entry)
  return (self.now() - (tonumber(entry.last_seen) or 0)) > M.LIMITS.stale_seconds
end

--- Validates and (re)registers. Re-registration of the same instance
--- replaces the token and metadata but keeps registered_at and counters —
--- the server sees one row per instance, not a new one per Director reload.
--- @return boolean ok, table reply (to send back), table|nil entry
function Registry:register(params)
  params = type(params) == "table" and params or {}
  local moduleId = tostring(params.module_id or "")
  local instanceId = tostring(params.instance_id or params.requester or "")
  local reply = { module_id = moduleId, instance_id = instanceId, ok = "false" }
  if not M.validModuleId(moduleId) then
    reply.reason = "invalid_module_id"
    return false, reply
  end
  if instanceId == "" or tonumber(instanceId) == nil then
    reply.reason = "invalid_instance_id"
    return false, reply
  end
  local pmin = tonumber(params.protocol_min) or 0
  local pmax = tonumber(params.protocol_max) or 0
  local lo, hi = math.max(pmin, M.PROTOCOL_MIN), math.min(pmax, M.PROTOCOL_MAX)
  if pmin <= 0 or pmax < pmin or lo > hi then
    reply.reason = "incompatible_protocol"
    reply.agent_protocol_min = tostring(M.PROTOCOL_MIN)
    reply.agent_protocol_max = tostring(M.PROTOCOL_MAX)
    return false, reply
  end
  local existing, index = self:find(moduleId, instanceId)
  local singleton = tostring(params.singleton or "") == "true"
  if singleton then
    for _, other in ipairs(self:instances(moduleId)) do
      if tostring(other.instance_id) ~= instanceId then
        reply.reason = "duplicate_instance"
        reply.other_instance_id = tostring(other.instance_id)
        return false, reply
      end
    end
  end
  if existing == nil and #self.entries >= M.LIMITS.modules then
    -- Make room from stale registrations first; a dead module should not
    -- block a live one.
    self:prune()
    if #self.entries >= M.LIMITS.modules then
      reply.reason = "registry_full"
      return false, reply
    end
    existing, index = nil, nil
  end
  local now = self.now()
  local entry = existing or { registered_at = now, counters = {}, registrations = 0 }
  entry.module_id = moduleId
  entry.instance_id = instanceId
  entry.driver_version = tostring(params.driver_version or "")
  entry.protocol = hi
  entry.protocol_min = pmin
  entry.protocol_max = pmax
  entry.capabilities = csv(params.capabilities)
  entry.entitlements = csv(params.entitlements)
  entry.commands = csv(params.commands)
  entry.event_types = csv(params.event_types)
  entry.config_version = tostring(params.config_version or "")
  entry.status = tostring(params.status or "")
  entry.detail = tostring(params.detail or ""):sub(1, M.LIMITS.detail)
  entry.singleton = singleton
  entry.token = self.newToken()
  entry.last_seen = now
  entry.registrations = (tonumber(entry.registrations) or 0) + 1
  if existing == nil then
    self.entries[#self.entries + 1] = entry
  else
    self.entries[index] = entry
  end
  reply.ok = "true"
  reply.token = entry.token
  reply.protocol = tostring(hi)
  return true, reply, entry
end

--- Authenticates a follow-up frame. nil + reason when it must be ignored.
function Registry:authenticate(params)
  params = type(params) == "table" and params or {}
  local entry = self:find(tostring(params.module_id or ""), tostring(params.instance_id or params.requester or ""))
  if entry == nil then
    return nil, "unknown_module"
  end
  if tostring(params.token or "") == "" or tostring(params.token) ~= entry.token then
    return nil, "bad_token"
  end
  return entry
end

--- Updates liveness, status and counters from an authenticated status frame.
function Registry:touch(entry, params)
  params = type(params) == "table" and params or {}
  entry.last_seen = self.now()
  if params.status ~= nil then
    entry.status = tostring(params.status)
  end
  if params.detail ~= nil then
    entry.detail = tostring(params.detail):sub(1, M.LIMITS.detail)
  end
  if params.config_version ~= nil then
    entry.config_version = tostring(params.config_version)
  end
  if params.applied_config_version ~= nil then
    entry.applied_config_version = tostring(params.applied_config_version)
  end
  if params.config_error ~= nil then
    entry.config_error = tostring(params.config_error):sub(1, M.LIMITS.detail)
  end
  if type(params.counters) == "table" then
    entry.counters = params.counters
  end
end

function Registry:remove(moduleId, instanceId)
  local entry, index = self:find(moduleId, instanceId)
  if entry == nil then
    return false
  end
  table.remove(self.entries, index)
  return true
end

--- Drops stale registrations; returns the removed entries.
function Registry:prune()
  local kept, removed = {}, {}
  for _, e in ipairs(self.entries) do
    if self:isStale(e) then
      removed[#removed + 1] = e
    else
      kept[#kept + 1] = e
    end
  end
  self.entries = kept
  return removed
end

function Registry:count()
  local n = 0
  for _, e in ipairs(self.entries) do
    if not self:isStale(e) then
      n = n + 1
    end
  end
  return n
end

function Registry:list()
  local out = {}
  for _, e in ipairs(self.entries) do
    out[#out + 1] = e
  end
  table.sort(out, function(a, b)
    if a.module_id ~= b.module_id then
      return a.module_id < b.module_id
    end
    return tostring(a.instance_id) < tostring(b.instance_id)
  end)
  return out
end

--- Derived display status for one entry, given the Agent's own standing.
--- @param agent table { paired = bool, connected = bool, licence = fun(sku):string|nil, enforce = fun(sku):bool }
function M.displayStatus(entry, agent, stale)
  if entry == nil then
    return M.STATUS.waiting_for_agent
  end
  if entry.protocol == nil then
    return M.STATUS.incompatible
  end
  if not agent.paired then
    return M.STATUS.unpaired
  end
  for _, sku in ipairs(entry.entitlements or {}) do
    local status = agent.licence and agent.licence(sku) or nil
    local denied = status == "NOT_ENTITLED"
      or status == "ENTITLEMENT_EXPIRED"
      or status == "ACCOUNT_SUSPENDED"
      or status == "CONTROLLER_MISMATCH"
    if denied and agent.enforce and agent.enforce(sku) then
      return M.STATUS.unlicensed
    end
  end
  if stale or entry.status == "degraded" or entry.status == "error" or not agent.connected then
    return M.STATUS.degraded
  end
  return M.STATUS.ready
end

--- The heartbeat's `modules` block: what the platform stores per instance.
--- Tokens never leave the controller.
function Registry:heartbeatBlock(agent)
  local out = {}
  for _, e in ipairs(self:list()) do
    local stale = self:isStale(e)
    out[#out + 1] = {
      module_id = e.module_id,
      instance_id = e.instance_id,
      driver_version = e.driver_version,
      protocol = e.protocol,
      capabilities = e.capabilities,
      entitlements = e.entitlements,
      commands = e.commands,
      event_types = e.event_types,
      config_version = e.config_version,
      applied_config_version = e.applied_config_version,
      config_error = e.config_error,
      status = e.status,
      detail = e.detail,
      display_status = M.displayStatus(e, agent, stale),
      stale = stale,
      registered_at = e.registered_at,
      last_seen = e.last_seen,
      registrations = e.registrations,
      counters = e.counters,
    }
  end
  return out
end

M.Registry = Registry
return M
