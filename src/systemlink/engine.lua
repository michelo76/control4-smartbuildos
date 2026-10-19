--- The System Link bridge engine: everything the driver does between the
--- Control4 callbacks and the relay, with every side effect behind an
--- injected `io` table so the whole engine runs under the test shim.
---
--- io = {
---   now        = fun(): ms                  (monotonic enough; C4:GetTime)
---   load       = fun(key): any              persisted state
---   save       = fun(key, value)
---   addVariable= fun(name, default, c4type, readOnly, hidden)
---   setVariable= fun(name, native)
---   fireEvent  = fun(key)                   static event by key (see EVENTS)
---   fireItemEvent = fun(itemId, kind)       dynamic per-item event ("changed")
---   property   = fun(name, value)
---   log        = { info=fn, warn=fn, debug=fn }
---   uuid       = fun(): string
--- }
---
--- Persistence keys (all JSON-safe, bounded):
---   sl_registry   definitions (schema.lua registry)
---   sl_values     { [id] = { tv, gen, rev, src_at } }  owner values + mirrors
---   sl_fresh      { [id] = freshness record }
---   sl_dedup      protocol dedup ring
---   sl_requests   request registry
---   sl_varorder   { name, name, … } native variable creation order (never shrinks)
---   sl_events     { [itemId] = eventId }
---   sl_link       { endpoint, link, gen, peer, namespace, peer_namespace, … }
---   sl_cursor     { since_seq }
---   sl_pending    outbound queue (bounded)

local schema = require("systemlink.schema")
local filters = require("systemlink.filters")
local freshness = require("systemlink.freshness")
local protocol = require("systemlink.protocol")
local requests = require("systemlink.requests")
local loop = require("systemlink.loop")
local reconcile = require("systemlink.reconcile")

local M = {}
M.__index = M

M.EVENTS = {
  LINK_CONNECTED = 1,
  LINK_DISCONNECTED = 2,
  PEER_ONLINE = 3,
  PEER_OFFLINE = 4,
  PEER_STALE = 5,
  INITIAL_SYNC_COMPLETE = 6,
  REMOTE_VARIABLE_CHANGED_LIVE = 7,
  REMOTE_STATE_CURRENT = 8,
  REMOTE_STATE_STALE = 9,
  NAMED_EVENT_RECEIVED = 10,
  REQUEST_RECEIVED = 11,
  REQUEST_COMPLETED = 12,
  REQUEST_FAILED = 13,
  REQUEST_EXPIRED = 14,
  REQUEST_OUTCOME_UNKNOWN = 15,
  SCHEMA_ATTENTION = 16,
  LICENSE_CHANGED = 17,
  COMMANDS_PAUSED = 18,
  COMMANDS_RESUMED = 19,
  LOOP_SUSPENDED = 20,
  LINK_PAUSED = 21,
  LINK_RESUMED = 22,
}

M.ITEM_EVENT_ID_START = 1000
M.PENDING_MAX = 500
M.HEARTBEAT_MS = 30 * 1000
M.POLL_FALLBACK_MS = 20 * 1000
M.STATE_VAR_SUFFIX = ".STATE"

local function deepcopy(v)
  if type(v) ~= "table" then
    return v
  end
  local o = {}
  for k, x in pairs(v) do
    o[k] = deepcopy(x)
  end
  return o
end

function M.new(io)
  local self = setmetatable({}, M)
  self.io = io
  self.registry = io.load("sl_registry") or schema.newRegistry()
  self.values = io.load("sl_values") or {}
  self.fresh = io.load("sl_fresh") or {}
  self.dedup = protocol.restoreDedup(io.load("sl_dedup"))
  self.requests = io.load("sl_requests") or requests.newRegistry(io.slots or requests.DEFAULT_SLOTS)
  self.varorder = io.load("sl_varorder") or {}
  self.itemEvents = io.load("sl_events") or {}
  self.link = io.load("sl_link") -- nil until provisioned
  self.cursor = io.load("sl_cursor") or { since_seq = 0 }
  self.pending = io.load("sl_pending") or {}
  self.filterState = {} -- not persisted: filters restart on reboot (documented)
  self.loopState = loop.newState()
  self.reconcile = reconcile.newState()
  self.transport = "disconnected"
  self.peerState = "offline"
  self.peerHeartbeatAt = nil
  self.lastSyncAt = nil
  self.lastHeartbeatSentAt = nil
  self.helloDone = false
  self.needSnapshot = true
  self.license = { status = "LEGACY", ok = true }
  self.pausedLocal = nil -- { until_ms, reason } local command pause
  self.linkPaused = false
  self.commandsPaused = false
  self.latency = { samples = {}, p95_ms = nil }
  self.lastError = ""
  self.lastRemoteCommand = nil
  self.evaluateAfterSync = false
  self.remoteStateWasCurrent = nil
  self.stats = { published = 0, applied = 0, rejected = 0, events_in = 0, events_out = 0 }
  return self
end

-- ── persistence helpers ─────────────────────────────────────────────────────

function M:persistAll()
  local io = self.io
  io.save("sl_registry", self.registry)
  io.save("sl_values", self.values)
  io.save("sl_fresh", self.fresh)
  io.save("sl_dedup", { cap = self.dedup.cap, ring = self.dedup.ring, head = self.dedup.head })
  io.save("sl_requests", self.requests)
  io.save("sl_varorder", self.varorder)
  io.save("sl_events", self.itemEvents)
  io.save("sl_link", self.link)
  io.save("sl_cursor", self.cursor)
  io.save("sl_pending", self.pending)
end

-- ── identity / naming ───────────────────────────────────────────────────────

function M:selfEndpoint()
  return self.link and self.link.endpoint or nil
end

function M:peerEndpoint()
  return self.link and self.link.peer or nil
end

function M:namespaceFor(def)
  if not self.link then
    return "Link"
  end
  if def.owner == self.link.endpoint then
    return self.link.namespace or "Local"
  end
  return self.link.peer_namespace or "Remote"
end

function M:variableNameFor(def)
  return schema.variableName(self:namespaceFor(def), def)
end

-- ── native variables ────────────────────────────────────────────────────────

local function nativeType(def)
  return schema.TYPES[def.type].native
end

--- Ensures a native variable exists with a stable creation order. Names are
--- appended to `varorder` the first time they are seen and re-added in that
--- order on every init, so Composer ids never shift.
function M:ensureVariable(name, default, c4type, readOnly)
  local known = false
  for _, n in ipairs(self.varorder) do
    if n == name then
      known = true
      break
    end
  end
  if not known then
    self.varorder[#self.varorder + 1] = name
    self.io.save("sl_varorder", self.varorder)
  end
  self.io.addVariable(name, default, c4type, readOnly, false)
end

--- Re-adds every variable ever created, in order, hiding tombstoned ones.
--- Call from OnDriverInit (docs: variables must exist before programming
--- restores). Returns the number added.
function M:restoreVariables()
  local live = {}
  for _, def in ipairs(schema.registryItems(self.registry)) do
    live[self:variableNameFor(def)] = def
    if def.mirror then
      live[self:variableNameFor(def) .. M.STATE_VAR_SUFFIX] = { type = "STRING", mirror = true, stateVar = true }
    end
  end
  local n = 0
  for _, name in ipairs(self.varorder) do
    local def = live[name]
    if def then
      local tv = def.stateVar and nil or (self.values[def.id] and self.values[def.id].tv)
      local default = def.stateVar and "unknown" or schema.toNative(def, tv or schema.unknown())
      self.io.addVariable(name, default, def.stateVar and "STRING" or nativeType(def), def.mirror == true, false)
    else
      -- Tombstone: keep the id slot, hide the variable.
      self.io.addVariable(name, "", "STRING", true, true)
    end
    n = n + 1
  end
  return n
end

function M:writeNative(def)
  local v = self.values[def.id]
  local tv = v and v.tv or schema.unknown()
  self.io.setVariable(self:variableNameFor(def), schema.toNative(def, tv))
  if def.mirror then
    local f = freshness.evaluate(
      self.fresh[def.id] or freshness.newRecord(),
      def,
      tv,
      self.io.now(),
      reconcile.isSynced(self.reconcile)
    )
    self.io.setVariable(self:variableNameFor(def) .. M.STATE_VAR_SUFFIX, f.state)
  end
end

-- ── item events (dynamic, per item) ─────────────────────────────────────────

function M:ensureItemEvent(def)
  local id = self.itemEvents[def.id]
  if not id then
    local max = M.ITEM_EVENT_ID_START - 1
    for _, v in pairs(self.itemEvents) do
      if v > max then
        max = v
      end
    end
    id = max + 1
    self.itemEvents[def.id] = id
    self.io.save("sl_events", self.itemEvents)
  end
  self.io.addEvent(
    id,
    self:variableNameFor(def) .. " changed (live)",
    "The remote value of " .. self:variableNameFor(def) .. " changed after initial sync."
  )
  return id
end

-- ── provisioning ────────────────────────────────────────────────────────────

--- Called with the Agent's SBOS_LINK_PROVISION answer.
function M:onProvisioned(info)
  local previous = self.link
  self.link = {
    endpoint = info.endpoint_id,
    link = info.link_id,
    gen = tonumber(info.generation) or 1,
    role = info.role,
    namespace = info.namespace,
    alias = info.alias,
    peer = info.peer and info.peer.id or nil,
    peer_namespace = info.peer and info.peer.namespace or nil,
    peer_alias = info.peer and info.peer.alias or nil,
    peer_gen = previous and previous.peer_gen or 0,
    credential = info.credential,
    relay_url = info.relay_url,
    realtime = info.realtime,
    protocol = tonumber(info.protocol) or 1,
    link_state = info.link_state,
  }
  if previous and previous.endpoint ~= self.link.endpoint then
    -- A different endpoint identity: this is a reassignment, not a restart.
    self.values = {}
    self.fresh = {}
    self.cursor = { since_seq = 0 }
    self.pending = {}
    self.registry = schema.newRegistry()
  elseif previous and previous.gen ~= self.link.gen then
    -- Controller replacement: republish everything at the new generation.
    self.cursor = { since_seq = 0 }
    for _, def in ipairs(schema.ownedExport(self.registry, self.link.endpoint)) do
      local v = self.values[def.id]
      if v then
        v.gen = self.link.gen
      end
    end
  end
  self.helloDone = false
  self.needSnapshot = true
  self.reconcile = reconcile.newState()
  reconcile.advance(self.reconcile, "restored", self.io.now())
  reconcile.advance(self.reconcile, "stale_marked", self.io.now())
  self:persistAll()
end

-- ── local items (owner) ─────────────────────────────────────────────────────

function M:createItem(def, initial)
  if not self.link then
    return nil, "not provisioned"
  end
  def.id = def.id or self.io.uuid()
  def.owner = self.link.endpoint
  local ok, err = schema.addDefinition(self.registry, def, self.io.now())
  if not ok then
    return nil, err
  end
  local tv = schema.unknown()
  if initial ~= nil and initial ~= "" then
    local v, cerr = schema.coerce(def, initial)
    if v == nil then
      schema.deleteDefinition(self.registry, def.id, self.io.now())
      return nil, cerr
    end
    tv = schema.current(v)
  end
  self.values[def.id] = { tv = tv, gen = self.link.gen, rev = 0, src_at = self.io.now() }
  self:ensureVariable(self:variableNameFor(def), schema.toNative(def, tv), nativeType(def), false)
  self:queueSchema()
  if tv.s == schema.STATES.CURRENT then
    self:queueState(def, tv)
  end
  self:persistAll()
  return def
end

function M:deleteItem(id)
  local def = self.registry.items[id]
  if not def or def.mirror then
    return false, "not an owned item"
  end
  local ok, err = schema.deleteDefinition(self.registry, id, self.io.now())
  if not ok then
    return false, err
  end
  -- The native variable stays as a hidden tombstone on next init; the value is dropped.
  self.values[id] = nil
  self:queueSchema()
  self:persistAll()
  return true
end

--- Effect preview for a rename: the variable NAME changes, the id does not.
function M:renamePreview(id, newName)
  local def = self.registry.items[id]
  if not def then
    return nil
  end
  local copy = deepcopy(def)
  copy.name = newName
  return { from = self:variableNameFor(def), to = self:variableNameFor(copy), programming_keeps_pointing = true }
end

function M:renameItem(id, newName)
  local def = self.registry.items[id]
  if not def or def.mirror then
    return false, "not an owned item"
  end
  local oldName = self:variableNameFor(def)
  local ok, err = schema.renameDefinition(self.registry, id, newName)
  if not ok then
    return false, err
  end
  local newVar = self:variableNameFor(def)
  -- The old variable becomes a tombstone (hidden); the new name gets a new id.
  -- Composer programming bound to the old id keeps pointing at the hidden
  -- variable, which the preview told the dealer. A future release may use a
  -- rename API if Control4 documents one.
  self:ensureVariable(
    newVar,
    schema.toNative(def, self.values[id] and self.values[id].tv or schema.unknown()),
    nativeType(def),
    false
  )
  self.io.addVariable(oldName, "", "STRING", true, true)
  self:queueSchema()
  self:persistAll()
  return true
end

function M:updateItem(id, patch)
  local def = self.registry.items[id]
  if not def or def.mirror then
    return false, "not an owned item"
  end
  local ok, err = schema.updateDefinition(self.registry, id, patch)
  if not ok then
    return false, err
  end
  self.filterState[id] = nil
  self:queueSchema()
  self:persistAll()
  return true
end

function M:ownedItems()
  return schema.ownedExport(self.registry, self:selfEndpoint() or "")
end

function M:findOwnedByName(name)
  for _, def in ipairs(schema.registryItems(self.registry)) do
    if not def.mirror and (def.name == name or self:variableNameFor(def) == name) then
      return def
    end
  end
  return nil
end

function M:findByName(name)
  for _, def in ipairs(schema.registryItems(self.registry)) do
    if def.name == name or self:variableNameFor(def) == name then
      return def
    end
  end
  return nil
end

--- Owner write. Everything else (mirrors) is refused here, the first of the
--- five enforcement points.
function M:setLocal(idOrName, raw, cause)
  local def = self.registry.items[idOrName] or self:findByName(idOrName)
  if not def then
    return false, "no such item"
  end
  if def.mirror or def.owner ~= self:selfEndpoint() then
    return false, "read-only mirror: only " .. tostring(def.owner) .. " may write it"
  end
  local v, err = schema.coerce(def, raw)
  if v == nil then
    return false, err
  end
  local tv = schema.current(v)
  local cur = self.values[def.id]
  if cur and schema.equal(cur.tv, tv) then
    -- Same value: confirms freshness, nothing to publish.
    cur.src_at = self.io.now()
    return true, "unchanged"
  end
  self.values[def.id] = {
    tv = tv,
    gen = self.link and self.link.gen or 1,
    rev = (cur and cur.rev or 0),
    src_at = self.io.now(),
    cause = cause,
  }
  self:writeNative(def)
  self:offerFiltered(def, tv)
  self:persistAll()
  return true
end

function M:offerFiltered(def, tv)
  local st = self.filterState[def.id]
  if not st then
    st = filters.newState()
    self.filterState[def.id] = st
  end
  local d = filters.offer(st, def, tv, self.io.now())
  if d.publish then
    self:queueState(def, d.value, d.filter_delay_ms)
  end
end

--- Flushes due filters. Returns true if anything was queued.
function M:flushFilters()
  local any = false
  for id, st in pairs(self.filterState) do
    local def = self.registry.items[id]
    if def and not def.deleted_at then
      local d = filters.flush(st, def, self.io.now())
      if d.publish then
        self:queueState(def, d.value, d.filter_delay_ms)
        any = true
      end
    end
  end
  return any
end

function M:nextFilterDue()
  local due
  for id, st in pairs(self.filterState) do
    local def = self.registry.items[id]
    if def then
      local d = filters.nextDue(st, def, self.io.now())
      if d and (not due or d < due) then
        due = d
      end
    end
  end
  return due
end

-- ── outbound queue ──────────────────────────────────────────────────────────

local function pushPending(self, env)
  if #self.pending >= M.PENDING_MAX then
    table.remove(self.pending, 1)
    self.stats.rejected = self.stats.rejected + 1
  end
  self.pending[#self.pending + 1] = env
end

function M:envelope(t, body)
  return protocol.envelope(
    t,
    { link = self.link.link, self = self.link.endpoint, self_gen = self.link.gen },
    self.io.uuid(),
    body,
    self.io.isoNow and self.io.isoNow() or nil
  )
end

--- Coalesces: one pending `state` message per tick carries the latest value
--- of every changed owned item (later values replace earlier ones for the
--- same item). Events and requests are never coalesced.
function M:queueState(def, tv, filterDelay)
  if not self.link then
    return
  end
  local v = self.values[def.id]
  v.rev = (v.rev or 0) + 1
  v.gen = self.link.gen
  local allowed, reason = loop.offer(self.loopState, def.id, self.io.now(), { hops = v.cause and v.cause.hops or nil })
  if not allowed then
    self.lastError = "item " .. def.name .. " suspended: " .. reason
    self.io.fireEvent("LOOP_SUSPENDED")
    return
  end
  local last = self.pending[#self.pending]
  if not (last and last.t == "state" and not last.sent) then
    last = self:envelope("state", { items = {} })
    pushPending(self, last)
  end
  local items = last.body.items
  for i, it in ipairs(items) do
    if it.id == def.id then
      table.remove(items, i)
      break
    end
  end
  items[#items + 1] = {
    id = def.id,
    rev = v.rev,
    value = tv,
    source_at = self.io.isoNow and self.io.isoNow() or nil,
    hops = v.cause and v.cause.hops or nil,
    filter_delay_ms = filterDelay or 0,
  }
  if #items > protocol.LIMITS.state_batch then
    table.remove(items, 1)
  end
end

function M:queueSchema()
  if not self.link then
    return
  end
  -- Replace any unsent schema message: the latest full registry wins.
  for i = #self.pending, 1, -1 do
    if self.pending[i].t == "schema" and not self.pending[i].sent then
      table.remove(self.pending, i)
    end
  end
  pushPending(
    self,
    self:envelope("schema", { items = self:ownedItems(), complete = true, schema_rev = self.registry.schema_rev })
  )
end

function M:emitEvent(defName, payload, ttlS)
  if not self.link then
    return false, "not provisioned"
  end
  if self.linkPaused then
    return false, "link paused"
  end
  local peerOnline = self.peerState == "online"
  local policy = requests.outboundPolicy(peerOnline, false, 0)
  if policy == "fail" then
    return false, "peer unavailable; event not queued (time-sensitive)"
  end
  local occ = requests.newOccurrence(defName, self.io.uuid(), self.link.endpoint, self.io.now(), ttlS, payload)
  pushPending(
    self,
    self:envelope(
      "event",
      {
        def = defName,
        occurrence = occ.id,
        payload = payload,
        ttl_s = occ.ttl_s,
        source_tz = self.io.timezone and self.io.timezone() or nil,
      }
    )
  )
  self.stats.events_out = self.stats.events_out + 1
  return true
end

function M:sendRequest(routine, payload, deadlineS)
  if not self.link then
    return nil, "not provisioned"
  end
  if self.linkPaused or self.commandsPaused or (self.pausedLocal and self.io.now() < self.pausedLocal.until_ms) then
    return nil, "commands paused"
  end
  local id = self.io.uuid()
  local entry, err = requests.open(
    self.requests,
    {
      id = id,
      routine = routine,
      direction = "out",
      payload = payload,
      deadline_ms = self.io.now() + (deadlineS or requests.DEFAULT_DEADLINE_S) * 1000,
    },
    self.io.now()
  )
  if not entry then
    return nil, err
  end
  pushPending(
    self,
    self:envelope("request", { routine = routine, payload = payload, ttl_s = deadlineS or requests.DEFAULT_DEADLINE_S })
  )
  -- The envelope id must equal the request id so updates correlate.
  self.pending[#self.pending].id = id
  self:writeRequestSlot(entry)
  self:persistAll()
  return entry
end

--- Local programming reports on an INBOUND request it is handling.
function M:reportRequest(slotOrId, status, result)
  local entry
  if type(slotOrId) == "number" then
    entry = self.requests.slots[slotOrId] or nil
    if entry == false then
      entry = nil
    end
  else
    entry = requests.get(self.requests, slotOrId)
  end
  if not entry then
    return false, "no request in that slot"
  end
  if entry.direction ~= "in" then
    return false, "only the receiving system reports on a request"
  end
  local updated, err, final = requests.transition(self.requests, entry.id, status, result, self.io.now())
  if not updated then
    return false, err
  end
  pushPending(self, self:envelope("request_update", { request_id = entry.id, status = status, result = result }))
  self:writeRequestSlot(updated, final)
  self:persistAll()
  return true
end

function M:writeRequestSlot(entry, cleared)
  local ns = (self.link and self.link.namespace or "Link")
  local base = ns .. ".Request_" .. tostring(entry.slot)
  local io = self.io
  if cleared then
    io.setVariable(base .. "_Status", entry.status)
    io.setVariable(
      base .. "_Result",
      entry.result and (type(entry.result) == "table" and (entry.result.text or "") or tostring(entry.result)) or ""
    )
    return
  end
  io.setVariable(base .. "_Id", entry.id)
  io.setVariable(base .. "_Routine", entry.routine)
  io.setVariable(base .. "_Status", entry.status)
  io.setVariable(base .. "_Direction", entry.direction)
  io.setVariable(base .. "_Payload", type(entry.payload) == "string" and entry.payload or "")
  io.setVariable(base .. "_Result", "")
end

function M:ensureRequestSlotVariables()
  local ns = (self.link and self.link.namespace or "Link")
  for i = 1, self.requests.slot_count do
    local base = ns .. ".Request_" .. tostring(i)
    self:ensureVariable(base .. "_Id", "", "STRING", true)
    self:ensureVariable(base .. "_Routine", "", "STRING", true)
    self:ensureVariable(base .. "_Status", "", "STRING", true)
    self:ensureVariable(base .. "_Direction", "", "STRING", true)
    self:ensureVariable(base .. "_Payload", "", "STRING", true)
    self:ensureVariable(base .. "_Result", "", "STRING", true)
  end
  self:ensureVariable(ns .. ".Last_Event_Name", "", "STRING", true)
  self:ensureVariable(ns .. ".Last_Event_Payload", "", "STRING", true)
  self:ensureVariable(ns .. ".Last_Event_Origin", "", "STRING", true)
  self:ensureVariable(ns .. ".Last_Event_Age_Seconds", "0", "NUMBER", true)
end

-- ── sync (one round trip) ───────────────────────────────────────────────────

function M:heartbeatDue()
  return not self.lastHeartbeatSentAt or self.io.now() - self.lastHeartbeatSentAt >= M.HEARTBEAT_MS
end

--- Builds the body for POST relay/sync. Marks pending messages as sent so
--- a failed round trip can resend them (they stay until acked).
function M:buildSync()
  if not self.link then
    return nil
  end
  local body = { outbound = {}, since_seq = self.cursor.since_seq }
  if not self.helloDone then
    body.hello = {
      protocol_min = protocol.MIN_SUPPORTED,
      protocol_max = protocol.MAX_SUPPORTED,
      driver_version = self.io.driverVersion and self.io.driverVersion() or "",
      timezone = self.io.timezone and self.io.timezone() or "",
    }
  end
  if self.needSnapshot then
    body.snapshot = true
  end
  if self:heartbeatDue() then
    body.heartbeat = { pending = #self.pending, latency_ms = self.latency.p95_ms }
    self.lastHeartbeatSentAt = self.io.now()
  end
  -- Definitions travel before values: the relay refuses a value for an
  -- item it has not been told about, so an unsent schema always leads.
  local ordered = {}
  for _, env in ipairs(self.pending) do
    if env.t == "schema" then
      ordered[#ordered + 1] = env
    end
  end
  for _, env in ipairs(self.pending) do
    if env.t ~= "schema" then
      ordered[#ordered + 1] = env
    end
  end
  local n = 0
  for _, env in ipairs(ordered) do
    if n >= protocol.LIMITS.outbound_per_sync then
      break
    end
    env.sent = self.io.now()
    local wire = {}
    for k, v in pairs(env) do
      if k ~= "sent" then
        wire[k] = v
      end
    end
    body.outbound[#body.outbound + 1] = wire
    n = n + 1
  end
  self.syncSentAt = self.io.now()
  return body
end

function M:onSyncFailed(reason)
  self.transport = "disconnected"
  self.lastError = "relay: " .. tostring(reason)
  for _, env in ipairs(self.pending) do
    env.sent = nil
  end
  if reconcile.isSynced(self.reconcile) or self.reconcile.phase == "authenticated" then
    self.io.fireEvent("LINK_DISCONNECTED")
  end
  reconcile.disconnected(self.reconcile)
  -- Outage reconciliation: say hello again and take a fresh snapshot, so
  -- anything committed while we were away is applied as snapshot, not live.
  self.helloDone = false
  self.needSnapshot = true
  self:updateRemoteState()
end

local function samplePair(self, ms)
  local s = self.latency.samples
  s[#s + 1] = ms
  if #s > 50 then
    table.remove(s, 1)
  end
  local sorted = {}
  for i, v in ipairs(s) do
    sorted[i] = v
  end
  table.sort(sorted)
  self.latency.p95_ms = sorted[math.max(1, math.ceil(#sorted * 0.95))]
end

--- Applies the relay's answer.
function M:onSyncResponse(resp, rawLen)
  if type(resp) ~= "table" then
    return self:onSyncFailed("malformed response")
  end
  local now = self.io.now()
  if type(resp.server_time) == "number" then
    self.relayOffset = resp.server_time - now
  end
  local wasConnected = self.transport == "connected"
  self.transport = "connected"
  self.lastSyncAt = now
  self.lastError = ""
  if not wasConnected then
    self.io.fireEvent("LINK_CONNECTED")
  end
  if not self.helloDone then
    self.helloDone = true
    self.link.protocol = tonumber(resp.protocol) or self.link.protocol
    if self.reconcile.phase == "stale_marked" then
      reconcile.advance(self.reconcile, "authenticated", now)
    end
  end
  if type(resp.link) == "table" then
    local lp = resp.link.paused == true
    local cp = resp.link.commands_paused == true
    if lp ~= self.linkPaused then
      self.linkPaused = lp
      self.io.fireEvent(lp and "LINK_PAUSED" or "LINK_RESUMED")
    end
    if cp ~= self.commandsPaused then
      self.commandsPaused = cp
      self.io.fireEvent(cp and "COMMANDS_PAUSED" or "COMMANDS_RESUMED")
    end
    self.link.link_state = resp.link.state
  end
  if type(resp.peer) == "table" then
    self.link.peer = resp.peer.id
    self.link.peer_namespace = resp.peer.namespace
    self.link.peer_alias = resp.peer.alias
    local g = tonumber(resp.peer.generation) or 0
    if g > (self.link.peer_gen or 0) then
      self.link.peer_gen = g
    end
    if resp.peer.last_heartbeat_at and self.io.parseIso then
      self.peerHeartbeatAt = self.io.parseIso(resp.peer.last_heartbeat_at)
    end
  end

  -- Acks: drop accepted and permanently rejected messages from the queue.
  local ackd = {}
  for _, a in ipairs(resp.accepted or {}) do
    ackd[a.id] = { ok = true, result = a.result }
  end
  for _, r in ipairs(resp.rejected or {}) do
    ackd[r.id] = { ok = false, reason = r.reason }
  end
  local keep = {}
  for _, env in ipairs(self.pending) do
    local a = ackd[env.id]
    if a == nil then
      if env.sent then
        env.sent = nil -- unanswered: resend next time
      end
      keep[#keep + 1] = env
    elseif a.ok then
      self.stats.published = self.stats.published + 1
      if env.t == "state" and self.syncSentAt then
        samplePair(self, now - self.syncSentAt)
      end
      if env.t == "state" and type(a.result) == "table" then
        for _, rej in ipairs(a.result.rejected or {}) do
          if
            rej.reason == "not owner"
            and self.registry.items[rej.id]
            and not self.registry.items[rej.id].mirror
            and not self.registry.items[rej.id].deleted_at
          then
            -- The relay had not seen the definition yet; the schema has now
            -- gone ahead of it, so republish the value once.
            local v = self.values[rej.id]
            if v and v.tv.s == schema.STATES.CURRENT and not v.requeued then
              v.requeued = true
              self:queueState(self.registry.items[rej.id], v.tv)
            end
          elseif rej.reason == "stale revision" then
            -- The relay holds a newer committed revision (restored backup).
            local def = self.registry.items[rej.id]
            local v = self.values[rej.id]
            if def and v and rej.committed_rev then
              v.rev = tonumber(rej.committed_rev) or v.rev
              self.lastError = "adopted committed revision for " .. def.name
              self.needSnapshot = true
            end
          end
        end
      end
    else
      self.stats.rejected = self.stats.rejected + 1
      if
        a.reason == "relay unavailable"
        or a.reason == "peer not active"
        or a.reason == "link paused"
        or a.reason == "commands paused"
      then
        -- Transient: keep state/schema, drop time-sensitive events and commands.
        if env.t == "state" or env.t == "schema" then
          env.sent = nil
          keep[#keep + 1] = env
        else
          self.lastError = env.t .. " refused: " .. a.reason
          if env.t == "request" then
            requests.transition(self.requests, env.id, "failed", { reason = a.reason }, now)
            self.io.fireEvent("REQUEST_FAILED")
          end
        end
      else
        self.lastError = env.t .. " rejected: " .. tostring(a.reason)
        if a.reason == "obsolete generation" then
          self.needReprovision = true
        end
      end
    end
  end
  self.pending = keep

  -- Snapshot: reconcile owner revisions, apply peer definitions and values.
  if type(resp.snapshot) == "table" then
    self:applySnapshot(resp.snapshot)
    self.needSnapshot = false
  end

  -- Inbound in sequence order.
  for _, env in ipairs(resp.inbound or {}) do
    self:applyInbound(env, rawLen)
    if type(env.seq) == "number" and env.seq > self.cursor.since_seq then
      self.cursor.since_seq = env.seq
    end
  end
  if type(resp.next_seq) == "number" and resp.next_seq > self.cursor.since_seq then
    self.cursor.since_seq = resp.next_seq
  end

  if self.reconcile.phase == "snapshot" then
    reconcile.advance(self.reconcile, "synced", now)
    self:markAllMirrorsConfirmed(now)
    self.io.fireEvent("INITIAL_SYNC_COMPLETE")
    if self.evaluateAfterSync then
      for _, def in ipairs(schema.registryItems(self.registry)) do
        if def.mirror then
          self.io.fireItemEvent(def.id, "changed")
        end
      end
      self.io.fireEvent("REMOTE_VARIABLE_CHANGED_LIVE")
    end
  end
  self:updateRemoteState()
  self:persistAll()
end

function M:markAllMirrorsConfirmed(now)
  for _, def in ipairs(schema.registryItems(self.registry)) do
    if def.mirror then
      local f = self.fresh[def.id] or freshness.newRecord()
      if self.values[def.id] and self.values[def.id].tv.s ~= schema.STATES.UNKNOWN then
        freshness.onConfirm(f, now)
      end
      self.fresh[def.id] = f
      self:writeNative(def)
    end
  end
end

function M:applySnapshot(snap)
  local now = self.io.now()
  if self.reconcile.phase == "authenticated" then
    reconcile.advance(self.reconcile, "schema", now)
  end
  -- Peer definitions.
  local result = schema.applyPeerSchema(self.registry, self.link.endpoint, self.link.peer, snap.peer_items or {}, now)
  for _, id in ipairs(result.added) do
    local def = self.registry.items[id]
    self:ensureVariable(self:variableNameFor(def), "", nativeType(def), true)
    self:ensureVariable(self:variableNameFor(def) .. M.STATE_VAR_SUFFIX, "unknown", "STRING", true)
    self:ensureItemEvent(def)
    self.values[id] = self.values[id] or { tv = schema.unknown(), gen = 0, rev = 0 }
  end
  if #result.rejected > 0 then
    self.io.fireEvent("SCHEMA_ATTENTION")
    self.lastError = "schema: " .. tostring(result.rejected[1].reason)
  end
  -- Owner revisions.
  if self.reconcile.phase == "schema" then
    reconcile.advance(self.reconcile, "revisions", now)
  end
  local localItems, committed = {}, {}
  for _, def in ipairs(self:ownedItems()) do
    local v = self.values[def.id]
    if v then
      localItems[def.id] = { gen = v.gen, rev = v.rev, value = v.tv }
    end
  end
  for _, c in ipairs(snap.own_committed or {}) do
    committed[c.id] = { gen = c.gen, rev = c.rev, value = c.value }
  end
  local decisions, notices = reconcile.reconcileOwner(localItems, committed, self.link.gen)
  for id, d in pairs(decisions) do
    local def = self.registry.items[id]
    if def then
      if d.action == "republish" or d.action == "fresh" then
        if self.values[id].tv.s == schema.STATES.CURRENT then
          self.values[id].rev = (d.rev or 0)
          self:queueState(def, self.values[id].tv)
        end
      elseif d.action == "adopt" then
        self.values[id] = { tv = d.value, gen = d.gen, rev = d.rev, src_at = now }
        self:writeNative(def)
      end
    end
  end
  for _, n in ipairs(notices) do
    self.lastError = n.kind .. ": " .. n.detail
    self.io.log.warn("reconcile %s: %s", n.item, n.detail)
  end
  -- Peer values (snapshot, not live).
  if self.reconcile.phase == "revisions" then
    reconcile.advance(self.reconcile, "snapshot", now)
  end
  for _, s in ipairs(snap.peer_state or {}) do
    local def = self.registry.items[s.id]
    if def and def.mirror then
      self:applyMirrorValue(def, s, "snapshot")
    end
  end
end

--- Applies one mirrored value. Never republishes it (SL-04), never fires the
--- live event unless the link is synced.
function M:applyMirrorValue(def, incoming, source)
  local held = self.values[def.id]
  local cls = protocol.classifyIncoming(
    held and { gen = held.gen, rev = held.rev } or nil,
    { gen = incoming.gen, rev = incoming.rev }
  )
  local now = self.io.now()
  local f = self.fresh[def.id] or freshness.newRecord()
  self.fresh[def.id] = f
  if cls == "ignore" then
    return false
  end
  local tv = incoming.value
  local okValue = type(tv) == "table"
    and (
      tv.s == schema.STATES.UNKNOWN
      or tv.s == schema.STATES.UNAVAILABLE
      or (tv.s == schema.STATES.CURRENT and schema.coerce(def, tv.v) ~= nil)
    )
  if not okValue then
    self.lastError = "mirror " .. def.name .. ": value refused"
    return false
  end
  if cls == "confirm" then
    freshness.onConfirm(f, now)
    self:writeNative(def)
    return false
  end
  local changed = not (held and schema.equal(held.tv, tv))
  self.values[def.id] = { tv = tv, gen = incoming.gen, rev = incoming.rev, src_at = now, hops = incoming.hops }
  freshness.onUpdate(f, now)
  self:writeNative(def)
  self.stats.applied = self.stats.applied + 1
  local kind = reconcile.classify(self.reconcile, source)
  if kind == "live" and changed then
    self.lastInboundHops = incoming.hops
    self.io.fireItemEvent(def.id, "changed")
    self.io.fireEvent("REMOTE_VARIABLE_CHANGED_LIVE")
  end
  return true
end

function M:applyInbound(env, rawLen)
  local ctx = {
    link = self.link.link,
    self = self.link.endpoint,
    peer = self.link.peer,
    peer_gen = self.link.peer_gen,
    rawLen = rawLen,
  }
  local ok, reason = protocol.validate(env, ctx)
  if not ok then
    self.stats.rejected = self.stats.rejected + 1
    self.lastError = "inbound " .. tostring(env and env.t) .. " dropped: " .. reason
    return
  end
  if env.ep ~= "relay" and env.gen > (self.link.peer_gen or 0) then
    self.link.peer_gen = env.gen
    requests.abandonAll(self.requests, self.io.now(), "peer generation changed")
  end
  local relayNow = self.io.now() + (self.relayOffset or 0)
  local t = env.t
  if t == "state" then
    if not self.dedup:accept(env.id) then
      return
    end
    for _, it in ipairs(env.body.items or {}) do
      local def = self.registry.items[it.id]
      if def and def.mirror and def.owner == env.ep then
        self:applyMirrorValue(def, { gen = env.gen, rev = it.rev, value = it.value, hops = it.hops }, "relay")
      end
    end
  elseif t == "schema" then
    if not self.dedup:accept(env.id) then
      return
    end
    local r = schema.applyPeerSchema(self.registry, self.link.endpoint, env.ep, env.body.items or {}, self.io.now())
    for _, id in ipairs(r.added) do
      local def = self.registry.items[id]
      self:ensureVariable(self:variableNameFor(def), "", nativeType(def), true)
      self:ensureVariable(self:variableNameFor(def) .. M.STATE_VAR_SUFFIX, "unknown", "STRING", true)
      self:ensureItemEvent(def)
      self.values[id] = self.values[id] or { tv = schema.unknown(), gen = 0, rev = 0 }
      self:writeNative(def)
    end
    for _, id in ipairs(r.changed) do
      local def = self.registry.items[id]
      self:ensureVariable(
        self:variableNameFor(def),
        schema.toNative(def, self.values[id] and self.values[id].tv or schema.unknown()),
        nativeType(def),
        true
      )
    end
    for _, id in ipairs(r.removed) do
      local def = self.registry.items[id]
      self.io.setVariable(self:variableNameFor(def) .. M.STATE_VAR_SUFFIX, "unavailable")
    end
    if #r.rejected > 0 or #r.removed > 0 or #r.changed > 0 then
      self.io.fireEvent("SCHEMA_ATTENTION")
    end
    self.io.property("Schema Revision", tostring(self.registry.schema_rev))
  elseif t == "event" then
    local policy = requests.inboundPolicy(env, relayNow, self.dedup, protocol)
    if policy ~= "deliver" then
      self.stats.rejected = self.stats.rejected + 1
      return
    end
    if not reconcile.isSynced(self.reconcile) then
      -- Spec §12: never replay events on restoration; an event that arrives
      -- before sync completes is still LIVE (it was emitted after we
      -- connected) — but one older than our restore window is not. The
      -- relay already stamped expiry, so anything here is within TTL.
    end
    local ns = self.link.namespace
    local payload = env.body.payload
    self.io.setVariable(ns .. ".Last_Event_Name", tostring(env.body.def or ""))
    self.io.setVariable(
      ns .. ".Last_Event_Payload",
      type(payload) == "string" and payload or (payload ~= nil and self.io.encode and self.io.encode(payload) or "")
    )
    self.io.setVariable(
      ns .. ".Last_Event_Origin",
      tostring(self.link.peer_alias or env.ep) .. (env.body.source_tz and (" " .. env.body.source_tz) or "")
    )
    local age = env.ts and self.io.parseIso and math.max(0, math.floor((relayNow - self.io.parseIso(env.ts)) / 1000))
      or 0
    self.io.setVariable(ns .. ".Last_Event_Age_Seconds", tostring(age))
    self.stats.events_in = self.stats.events_in + 1
    self.io.fireEvent("NAMED_EVENT_RECEIVED")
    if self.io.fireNamedEvent then
      self.io.fireNamedEvent(tostring(env.body.def or ""))
    end
  elseif t == "request" or t == "command" then
    local policy = requests.inboundPolicy(env, relayNow, self.dedup, protocol)
    if policy ~= "deliver" then
      self.stats.rejected = self.stats.rejected + 1
      return
    end
    if t == "command" then
      self.lastRemoteCommand = { at = self.io.now(), origin = env.ep, routine = env.body.routine }
      if self.pausedLocal and self.io.now() < self.pausedLocal.until_ms then
        pushPending(
          self,
          self:envelope(
            "command_update",
            {
              request_id = env.id,
              status = "failed",
              result = { reason = "commands suspended on " .. tostring(self.link.alias) },
            }
          )
        )
        return
      end
      if self.io.onCommand then
        local accepted, why = self.io.onCommand(env.body, env.id)
        pushPending(
          self,
          self:envelope(
            "command_update",
            {
              request_id = env.id,
              status = accepted and "delivered" or "failed",
              result = accepted and nil or { reason = why },
            }
          )
        )
      end
      return
    end
    local entry = requests.open(
      self.requests,
      {
        id = env.id,
        routine = tostring(env.body.routine or ""),
        direction = "in",
        payload = env.body.payload,
        origin_ep = env.ep,
        deadline_ms = env.exp and (env.exp - (self.relayOffset or 0)) or nil,
      },
      self.io.now()
    )
    if not entry then
      pushPending(
        self,
        self:envelope(
          "request_update",
          { request_id = env.id, status = "failed", result = { reason = "no free request slot" } }
        )
      )
      return
    end
    requests.transition(self.requests, entry.id, "delivered", nil, self.io.now())
    pushPending(self, self:envelope("request_update", { request_id = entry.id, status = "delivered" }))
    self:writeRequestSlot(entry)
    self.io.fireEvent("REQUEST_RECEIVED")
    if self.io.fireRoutineEvent then
      self.io.fireRoutineEvent(entry.routine)
    end
  elseif t == "request_update" or t == "command_update" then
    if not self.dedup:accept(env.id) then
      return
    end
    local id = tostring(env.body.request_id or "")
    local entry = requests.get(self.requests, id)
    if entry and entry.direction == "out" then
      local status = tostring(env.body.status or "")
      local updated, _, final = requests.transition(self.requests, id, status, env.body.result, self.io.now())
      if updated then
        self:writeRequestSlot(updated, final)
        if updated.late then
          self.lastError = "late result for " .. updated.routine .. " recorded; no follow-up fired"
        elseif status == "completed" then
          self.io.fireEvent("REQUEST_COMPLETED")
        elseif status == "failed" then
          self.io.fireEvent("REQUEST_FAILED")
        end
      end
    end
  elseif t == "control" then
    if not self.dedup:accept(env.id) then
      return
    end
    self:applyControl(env.body)
  end
end

function M:applyControl(body)
  local op = tostring(body.op or "")
  if op == "item_upsert" and type(body.definition) == "table" then
    local def = body.definition
    if def.owner ~= self.link.endpoint then
      return
    end
    if self.registry.items[def.id] then
      local existing = self.registry.items[def.id]
      if existing.name ~= def.name then
        self:renameItem(def.id, def.name)
      end
      local patch = {}
      for k in pairs({
        description = 1,
        group = 1,
        units = 1,
        allowed_values = 1,
        min = 1,
        max = 1,
        precision = 1,
        max_length = 1,
        export_enabled = 1,
        freshness = 1,
        filter = 1,
        display_name = 1,
      }) do
        patch[k] = def[k]
      end
      self:updateItem(def.id, patch)
    else
      local copy = deepcopy(def)
      copy.schema_rev = nil
      copy.order = nil
      self:createItem(copy, nil)
    end
  elseif op == "item_delete" then
    self:deleteItem(tostring(body.id))
  elseif op == "pause_link" then
    self.linkPaused = true
    self.io.fireEvent("LINK_PAUSED")
  elseif op == "resume_link" then
    self.linkPaused = false
    self.io.fireEvent("LINK_RESUMED")
  elseif op == "pause_commands" then
    self.commandsPaused = true
    self.io.fireEvent("COMMANDS_PAUSED")
  elseif op == "resume_commands" then
    self.commandsPaused = false
    self.io.fireEvent("COMMANDS_RESUMED")
  elseif op == "revoked" then
    self.link.link_state = "revoked"
    requests.abandonAll(self.requests, self.io.now(), "link revoked")
    self.io.fireEvent("LINK_DISCONNECTED")
  elseif op == "peer_generation" then
    local g = tonumber(body.generation) or 0
    if g > (self.link.peer_gen or 0) then
      self.link.peer_gen = g
      requests.abandonAll(self.requests, self.io.now(), "peer controller replaced")
      self.needSnapshot = true
    end
  end
end

-- ── periodic ────────────────────────────────────────────────────────────────

--- Called every second by the driver timer. Returns true when a sync should
--- go out now (pending messages, heartbeat due, or the poll fallback).
function M:tick(doorbellUp)
  local now = self.io.now()
  if not self.link then
    return false
  end
  self:flushFilters()
  for _, e in ipairs(requests.expire(self.requests, now)) do
    self:writeRequestSlot(e, true)
    self.io.fireEvent("REQUEST_EXPIRED")
  end
  requests.prune(self.requests, now, 24 * 3600 * 1000)
  if self.pausedLocal and now >= self.pausedLocal.until_ms then
    self.pausedLocal = nil
    self.io.fireEvent("COMMANDS_RESUMED")
  end
  self:updateRemoteState()
  local hasUnsent = false
  for _, env in ipairs(self.pending) do
    if not env.sent then
      hasUnsent = true
      break
    end
  end
  if hasUnsent or self.needSnapshot then
    return true
  end
  if self:heartbeatDue() then
    return true
  end
  if not doorbellUp and self.lastSyncAt and now - self.lastSyncAt >= M.POLL_FALLBACK_MS then
    return true
  end
  return false
end

function M:updateRemoteState()
  local now = self.io.now()
  self.peerState = freshness.peerState(self.peerHeartbeatAt, M.HEARTBEAT_MS, now)
  if self.transport ~= "connected" then
    self.peerState = "offline"
  end
  if self.lastPeerState ~= self.peerState then
    if self.peerState == "online" then
      self.io.fireEvent("PEER_ONLINE")
    elseif self.peerState == "stale" then
      self.io.fireEvent("PEER_STALE")
    else
      self.io.fireEvent("PEER_OFFLINE")
    end
    self.lastPeerState = self.peerState
  end
  local stale = 0
  for _, def in ipairs(schema.registryItems(self.registry)) do
    if def.mirror then
      local f = freshness.evaluate(
        self.fresh[def.id] or freshness.newRecord(),
        def,
        self.values[def.id] and self.values[def.id].tv,
        now,
        reconcile.isSynced(self.reconcile)
      )
      if f.state == schema.STATES.STALE then
        stale = stale + 1
      end
      self.io.setVariable(self:variableNameFor(def) .. M.STATE_VAR_SUFFIX, f.state)
    end
  end
  self.staleItems = stale
  local state, reason = freshness.aggregate({
    license = self.license.ok and "ok" or "attention",
    license_reason = self.license.reason,
    paused = self.linkPaused or (self.link and self.link.link_state == "revoked"),
    paused_reason = self.link and self.link.link_state == "revoked" and "link revoked" or nil,
    transport = self.transport,
    peer = self.peerState,
    sync = reconcile.isSynced(self.reconcile) and "complete"
      or (self.reconcile.phase == "snapshot" and "in_progress" or "not_started"),
    stale_items = stale,
  })
  self.remoteState, self.remoteReason = state, reason
  local current = state == freshness.REMOTE.READY
  if self.remoteStateWasCurrent ~= current then
    if self.remoteStateWasCurrent ~= nil then
      self.io.fireEvent(current and "REMOTE_STATE_CURRENT" or "REMOTE_STATE_STALE")
    end
    self.remoteStateWasCurrent = current
  end
end

function M:setLicense(status, ok, reason)
  if self.license.status ~= status then
    self.io.fireEvent("LICENSE_CHANGED")
  end
  self.license = { status = status, ok = ok, reason = reason }
end

function M:pauseCommandsLocal(minutes, reason)
  self.pausedLocal =
    { until_ms = self.io.now() + math.max(1, minutes or 60) * 60000, reason = reason or "paused in Composer" }
  self.io.fireEvent("COMMANDS_PAUSED")
end

function M:resumeCommandsLocal()
  self.pausedLocal = nil
  self.io.fireEvent("COMMANDS_RESUMED")
end

-- ── conditionals / status ───────────────────────────────────────────────────

function M:isRemoteReady()
  return self.remoteState == freshness.REMOTE.READY
end

function M:isSynced()
  return reconcile.isSynced(self.reconcile)
end

function M:commandsPermitted()
  return self.link ~= nil
    and not self.linkPaused
    and not self.commandsPaused
    and not (self.pausedLocal and self.io.now() < self.pausedLocal.until_ms)
    and self.license.ok
end

function M:itemCurrent(name)
  local def = self:findByName(name)
  if not def then
    return false
  end
  if not def.mirror then
    return self.values[def.id] ~= nil and self.values[def.id].tv.s == schema.STATES.CURRENT
  end
  local f = freshness.evaluate(
    self.fresh[def.id] or freshness.newRecord(),
    def,
    self.values[def.id] and self.values[def.id].tv,
    self.io.now(),
    self:isSynced()
  )
  return f.state == schema.STATES.CURRENT
end

function M:requestSlotStatus(slot)
  local e = self.requests.slots[slot]
  if e and e ~= false then
    return e.status
  end
  for _, h in ipairs(self.requests.history) do
    if h.slot == slot then
      return h.status
    end
  end
  return ""
end

function M:statusProperties()
  local owned, mirrored = schema.counts(self.registry, self:selfEndpoint() or "")
  local pendingCmds = requests.inFlight(self.requests)
  return {
    ["Local System Name"] = self.link and (self.link.alias or "") or "Not linked",
    ["Linked System Name"] = self.link and (self.link.peer_alias or "Waiting for peer") or "Not linked",
    ["Local Variables Created"] = tostring(owned),
    ["Remote Variables Monitored"] = tostring(mirrored),
    ["Link Authorization"] = self.link and (self.link.link_state or "unknown") or "Not provisioned",
    ["Relay Connection"] = self.transport,
    ["Peer Status"] = self.peerState,
    ["Remote System State"] = (self.remoteState or "Offline")
      .. (self.remoteReason and (" — " .. self.remoteReason) or ""),
    ["Sync Status"] = self.reconcile.phase or "not started",
    ["Last Sync"] = self.lastSyncAt and self.io.formatTime(self.lastSyncAt) or "never",
    ["Last Heartbeat"] = self.peerHeartbeatAt and self.io.formatTime(self.peerHeartbeatAt) or "never",
    ["Pending Updates"] = tostring(#self.pending),
    ["Pending Requests"] = tostring(pendingCmds),
    ["Measured Latency"] = self.latency.p95_ms and (string.format(
      "p95 %d ms (local accept → relay commit, %d samples)",
      self.latency.p95_ms,
      #self.latency.samples
    )) or "no samples",
    ["Last Remote Command"] = self.lastRemoteCommand
        and (self.io.formatTime(self.lastRemoteCommand.at) .. " from " .. tostring(self.lastRemoteCommand.origin) .. ": " .. tostring(
          self.lastRemoteCommand.routine
        ))
      or "none",
    ["Command Suspension"] = (
      self.pausedLocal and ("Local until " .. self.io.formatTime(self.pausedLocal.until_ms))
      or (self.commandsPaused and "Paused by link" or "Active")
    ),
    ["Last Error"] = self.lastError or "",
    ["Schema Revision"] = tostring(self.registry.schema_rev),
  }
end

function M:diagnostics()
  local items = {}
  for _, def in ipairs(schema.registryItems(self.registry)) do
    local v = self.values[def.id]
    items[#items + 1] = {
      id = def.id,
      name = self:variableNameFor(def),
      type = def.type,
      owner = def.mirror and "peer" or "local",
      gen = v and v.gen,
      rev = v and v.rev,
      state = v and v.tv.s or "unknown",
      fresh = self.fresh[def.id],
      filter = def.filter,
      schema_rev = def.schema_rev,
    }
  end
  return {
    link = self.link and {
      endpoint = self.link.endpoint,
      link = self.link.link,
      gen = self.link.gen,
      peer = self.link.peer,
      peer_gen = self.link.peer_gen,
      state = self.link.link_state,
      protocol = self.link.protocol,
    } or nil,
    transport = self.transport,
    peer = self.peerState,
    phase = self.reconcile.phase,
    remote_state = self.remoteState,
    cursor = self.cursor,
    pending = #self.pending,
    stats = self.stats,
    latency_p95_ms = self.latency.p95_ms,
    suspensions = loop.suspensions(self.loopState, self.io.now()),
    requests_in_flight = requests.inFlight(self.requests),
    items = items,
    -- Payloads are never included (spec §36).
  }
end

return M
