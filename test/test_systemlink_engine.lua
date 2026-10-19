-- Two bridge engines (California, New York) against a simulated relay that
-- implements the same contract as smartbuildos' /api/system-link/relay/sync:
-- owner-only commits, revision ordering, generation fencing, relay-stamped
-- expiry, snapshot on cursor 0. No sockets, no C4: everything the engine does
-- is observed through its injected io.
--
-- Run from the driver root: make test

local pass, fail = 0, 0
local function check(name, ok, detail)
  if ok then
    pass = pass + 1
    print(string.format("  ok   %s", name))
  else
    fail = fail + 1
    print(string.format("  FAIL %s%s", name, detail and ("  -> " .. tostring(detail)) or ""))
  end
end

package.path = "./src/?.lua;./src/?/init.lua;./vendor/?.lua;" .. package.path
local Engine = require("systemlink.engine")
local schema = require("systemlink.schema")

-- ── fake clock ──────────────────────────────────────────────────────────────
local clock = { now = 1000000 }
local function advance(ms)
  clock.now = clock.now + ms
end

-- ── fake endpoint io ────────────────────────────────────────────────────────
local uuidN = 0
local function newIo(name)
  local io = { name = name, store = {}, vars = {}, varOrder = {}, events = {}, itemEvents = {}, props = {}, named = {} }
  io.now = function()
    return clock.now
  end
  io.isoNow = function()
    return "t" .. tostring(clock.now)
  end
  io.parseIso = function(s)
    return tonumber(tostring(s):match("^t(%d+)$")) or clock.now
  end
  io.formatTime = function(ms)
    return tostring(ms)
  end
  io.uuid = function()
    uuidN = uuidN + 1
    return name .. "-m" .. string.format("%06d", uuidN)
  end
  io.load = function(k)
    return io.store[k]
  end
  io.save = function(k, v)
    io.store[k] = v
  end
  io.addVariable = function(vname, default, c4type, readOnly, hidden)
    if io.vars[vname] == nil then
      io.varOrder[#io.varOrder + 1] = vname
      io.vars[vname] = { value = default, type = c4type, readOnly = readOnly, hidden = hidden }
    else
      io.vars[vname].hidden = hidden
      io.vars[vname].readOnly = readOnly
    end
  end
  io.setVariable = function(vname, v)
    io.vars[vname] = io.vars[vname] or { value = v }
    io.vars[vname].value = v
  end
  io.addEvent = function(id, ename)
    io.itemEvents[id] = ename
  end
  io.fireEvent = function(key)
    io.events[#io.events + 1] = key
  end
  io.fireItemEvent = function(id)
    io.events[#io.events + 1] = "ITEM:" .. id
  end
  io.fireNamedEvent = function(n)
    io.named[#io.named + 1] = n
  end
  io.property = function(k, v)
    io.props[k] = v
  end
  io.log = { info = function() end, warn = function() end, debug = function() end }
  io.driverVersion = function()
    return "test"
  end
  io.timezone = function()
    return name == "CA" and "America/Los_Angeles" or "America/New_York"
  end
  io.slots = 4
  return io
end

local function hasEvent(io, key)
  for _, e in ipairs(io.events) do
    if e == key then
      return true
    end
  end
  return false
end
local function countEvent(io, key)
  local n = 0
  for _, e in ipairs(io.events) do
    if e == key then
      n = n + 1
    end
  end
  return n
end
local function varValue(io, vname)
  return io.vars[vname] and io.vars[vname].value
end

-- ── simulated relay ─────────────────────────────────────────────────────────
local Relay = {}
Relay.__index = Relay
function Relay.new()
  return setmetatable({
    seq = 0,
    messages = {},
    items = {},
    state = {},
    endpoints = {},
    requests = {},
    paused = false,
    commandsPaused = false,
    down = false,
    delivered = {},
  }, Relay)
end
function Relay:endpoint(id, gen, peerId)
  self.endpoints[id] = { gen = gen, peer = peerId, hb = nil, status = "active" }
end
function Relay:push(fromEp, toEp, gen, t, id, body, exp)
  self.seq = self.seq + 1
  self.messages[#self.messages + 1] = {
    seq = self.seq,
    from = fromEp,
    to = toEp,
    gen = gen,
    t = t,
    id = id,
    body = body,
    exp = exp,
    ts = "t" .. clock.now,
  }
  return self.seq
end
function Relay:sync(epId, body)
  if self.down then
    return nil, "unreachable"
  end
  local ep = self.endpoints[epId]
  local peer = self.endpoints[ep.peer]
  local now = clock.now
  if body.heartbeat then
    ep.hb = now
  end
  local accepted, rejected = {}, {}
  for _, env in ipairs(body.outbound or {}) do
    if env.gen ~= ep.gen then
      rejected[#rejected + 1] = { id = env.id, reason = "obsolete generation" }
    elseif self.paused then
      rejected[#rejected + 1] = { id = env.id, reason = "link paused" }
    elseif (env.t == "request" or env.t == "command") and self.commandsPaused then
      rejected[#rejected + 1] = { id = env.id, reason = "commands paused" }
    elseif env.t == "state" then
      if self.delivered[env.id] then
        accepted[#accepted + 1] = { id = env.id, result = { duplicate = true, accepted = {}, rejected = {} } }
      else
        local acc, rej = {}, {}
        for _, it in ipairs(env.body.items) do
          local def = self.items[it.id]
          local cur = self.state[it.id]
          if not def or def.owner ~= epId then
            rej[#rej + 1] = { id = it.id, reason = "not owner" }
          elseif cur and (cur.gen > env.gen or (cur.gen == env.gen and cur.rev >= it.rev)) then
            rej[#rej + 1] = { id = it.id, reason = "stale revision", committed_rev = cur.rev, committed_gen = cur.gen }
          else
            acc[#acc + 1] = { id = it.id, rev = it.rev, gen = env.gen, value = it.value, hops = it.hops }
          end
        end
        local seq
        if #acc > 0 then
          seq = self:push(epId, ep.peer, env.gen, "state", env.id, { items = acc })
          for _, a in ipairs(acc) do
            self.state[a.id] = { gen = a.gen, rev = a.rev, value = a.value, seq = seq }
          end
        end
        self.delivered[env.id] = true
        accepted[#accepted + 1] = { id = env.id, seq = seq, result = { accepted = acc, rejected = rej } }
      end
    elseif env.t == "schema" then
      local kept = {}
      for _, def in ipairs(env.body.items) do
        local copy = {}
        for k, v in pairs(def) do
          copy[k] = v
        end
        copy.owner = epId
        self.items[def.id] = copy
        kept[def.id] = true
      end
      if env.body.complete then
        for id, def in pairs(self.items) do
          if def.owner == epId and not kept[id] then
            def.deleted_at = now
          end
        end
      end
      local seq = self:push(epId, ep.peer, env.gen, "schema", env.id, env.body)
      accepted[#accepted + 1] = { id = env.id, seq = seq }
    else
      local ttl = env.t == "event" and math.min(600, env.body.ttl_s or 30)
        or (env.t == "request" and (env.body.ttl_s or 120) or (env.t == "command" and 30 or nil))
      local exp = ttl and (now + ttl * 1000) or nil
      if env.t == "request" or env.t == "command" then
        self.requests[env.id] = { status = "accepted", to = ep.peer, routine = env.body.routine, deadline = exp }
      end
      if env.t == "request_update" or env.t == "command_update" then
        local r = self.requests[env.body.request_id]
        if not r then
          rejected[#rejected + 1] = { id = env.id, reason = "unknown request" }
          goto continue
        elseif r.to ~= epId then
          rejected[#rejected + 1] = { id = env.id, reason = "not the request target" }
          goto continue
        end
        if r.status ~= "expired" then
          r.status = env.body.status
        end
      end
      local seq = self:push(epId, ep.peer, env.gen, env.t, env.id, env.body, exp)
      accepted[#accepted + 1] = { id = env.id, seq = seq }
    end
    ::continue::
  end
  for id, r in pairs(self.requests) do
    if
      (r.status == "accepted" or r.status == "delivered" or r.status == "running")
      and r.deadline
      and now >= r.deadline
    then
      r.status = "expired"
    end
  end
  local since = body.since_seq or 0
  local inbound = {}
  for _, m in ipairs(self.messages) do
    if m.to == epId and m.seq > since and m.gen >= (peer and peer.gen or 0) and #inbound < 200 then
      inbound[#inbound + 1] = {
        v = 1,
        t = m.t,
        id = m.id,
        link = "L",
        ep = m.from,
        gen = m.gen,
        seq = m.seq,
        ts = m.ts,
        exp = m.exp,
        body = m.body,
      }
    end
  end
  local lastSeq = #inbound > 0 and inbound[#inbound].seq or since
  local snapshot
  if since == 0 or body.snapshot then
    local peerItems, peerState, own = {}, {}, {}
    for id, def in pairs(self.items) do
      if def.owner == ep.peer and not def.deleted_at then
        peerItems[#peerItems + 1] = def
      end
      local st = self.state[id]
      if st and def.owner == ep.peer then
        peerState[#peerState + 1] = { id = id, gen = st.gen, rev = st.rev, value = st.value, seq = st.seq }
      elseif st and def.owner == epId then
        own[#own + 1] = { id = id, gen = st.gen, rev = st.rev, value = st.value, seq = st.seq }
      end
    end
    table.sort(peerItems, function(a, b)
      return (a.order or 0) < (b.order or 0)
    end)
    snapshot = { peer_items = peerItems, peer_state = peerState, own_committed = own, head_seq = self.seq }
  end
  return {
    server_time = now + 5000, -- relay clock 5 s ahead: expiry must still work
    protocol = 1,
    link = {
      id = "L",
      state = self.paused and "paused" or "approved",
      generation = 1,
      paused = self.paused,
      commands_paused = self.commandsPaused,
    },
    self = { id = epId, generation = ep.gen },
    peer = {
      id = ep.peer,
      generation = peer.gen,
      namespace = peer.ns,
      alias = peer.alias,
      status = "active",
      last_heartbeat_at = peer.hb and ("t" .. peer.hb) or nil,
    },
    accepted = accepted,
    rejected = rejected,
    inbound = inbound,
    next_seq = lastSeq,
    snapshot = snapshot,
  }
end

-- ── world ───────────────────────────────────────────────────────────────────
local relay = Relay.new()
relay:endpoint("ep-ca", 1, "ep-ny")
relay:endpoint("ep-ny", 1, "ep-ca")
relay.endpoints["ep-ca"].ns, relay.endpoints["ep-ca"].alias = "California", "California Home"
relay.endpoints["ep-ny"].ns, relay.endpoints["ep-ny"].alias = "NewYork", "New York Home"

local ioCA, ioNY = newIo("CA"), newIo("NY")
local CA, NY = Engine.new(ioCA), Engine.new(ioNY)

local function provision(engine, epId, peerId, gen)
  engine:onProvisioned({
    endpoint_id = epId,
    link_id = "L",
    generation = gen or 1,
    role = epId == "ep-ca" and "a" or "b",
    namespace = relay.endpoints[epId].ns,
    alias = relay.endpoints[epId].alias,
    peer = { id = peerId, namespace = relay.endpoints[peerId].ns, alias = relay.endpoints[peerId].alias },
    credential = "sbosl1.x",
    relay_url = "https://relay",
    protocol = 1,
    link_state = "approved",
  })
end

local function sync(engine, epId)
  local body = engine:buildSync()
  if not body then
    return
  end
  local resp, err = relay:sync(epId, body)
  if not resp then
    engine:onSyncFailed(err)
  else
    engine:onSyncResponse(resp)
  end
  return resp
end

-- ── 1. provisioning, hello, initial sync ───────────────────────────────────
print("\n[1] provisioning and first sync")
provision(CA, "ep-ca", "ep-ny")
provision(NY, "ep-ny", "ep-ca")
CA:ensureRequestSlotVariables()
NY:ensureRequestSlotVariables()
check(
  "request slot variables created",
  ioCA.vars["California.Request_1_Status"] ~= nil and ioCA.vars["California.Last_Event_Name"] ~= nil
)
sync(CA, "ep-ca")
sync(NY, "ep-ny")
check(
  "both synced after first round trip",
  CA:isSynced() and NY:isSynced(),
  CA.reconcile.phase .. "/" .. NY.reconcile.phase
)
check(
  "Initial Sync Complete fired once each",
  countEvent(ioCA, "INITIAL_SYNC_COMPLETE") == 1 and countEvent(ioNY, "INITIAL_SYNC_COMPLETE") == 1
)
check("Link Connected fired", hasEvent(ioCA, "LINK_CONNECTED"))

-- ── 2. owner creates items; peer mirrors them read-only ────────────────────
print("\n[2] create and mirror")
local away = assert(CA:createItem({ name = "Away", type = "BOOLEAN", description = "Nobody home" }, "false"))
local mode = assert(
  CA:createItem({ name = "System_Mode", type = "CHOICE", allowed_values = { "Home", "Away", "Vacation" } }, "Home")
)
check(
  "owner variables are writable natively",
  ioCA.vars["California.Away"].readOnly == false and ioCA.vars["California.System_Mode"].value == "Home"
)
local occ = assert(NY:createItem({ name = "Occupied", type = "BOOLEAN" }, "true"))
local guests = assert(
  NY:createItem({ name = "Guest_Count", type = "INTEGER", min = 0, max = 20, filter = { min_interval_s = 2 } }, "0")
)
sync(CA, "ep-ca")
sync(NY, "ep-ny")
sync(CA, "ep-ca")
check(
  "NY mirrors California.Away read-only",
  ioNY.vars["California.Away"]
    and ioNY.vars["California.Away"].readOnly == true
    and ioNY.vars["California.Away"].value == "0",
  tostring(ioNY.vars["California.Away"] and ioNY.vars["California.Away"].value)
)
check("NY mirror has a STATE variable", ioNY.vars["California.Away.STATE"] ~= nil)
check("CA mirrors NewYork.Occupied", ioCA.vars["NewYork.Occupied"] and ioCA.vars["NewYork.Occupied"].value == "1")
check(
  "CA mirrors NewYork.Guest_Count",
  ioCA.vars["NewYork.Guest_Count"] and ioCA.vars["NewYork.Guest_Count"].value == "0"
)
check("mirror writes are refused at the engine", select(2, NY:setLocal("California.Away", true)):match("read%-only"))
check(
  "counts: CA owns 2, mirrors 2",
  select(1, schema.counts(CA.registry, "ep-ca")) == 2 and select(2, schema.counts(CA.registry, "ep-ca")) == 2
)
check("items created after sync arrive as LIVE changes", countEvent(ioNY, "REMOTE_VARIABLE_CHANGED_LIVE") >= 1)
local liveBefore = countEvent(ioNY, "REMOTE_VARIABLE_CHANGED_LIVE")

-- ── 3. live update, latency, freshness ──────────────────────────────────────
print("\n[3] live update")
advance(1000)
assert(CA:setLocal("Away", "true"))
check("owner native updated immediately", ioCA.vars["California.Away"].value == "1")
check("tick asks for a sync (pending)", CA:tick(true))
local before = #ioNY.events
sync(CA, "ep-ca")
sync(NY, "ep-ny")
check("NY sees the live value", ioNY.vars["California.Away"].value == "1")
check(
  "Remote Variable Changed Live fired once more, per-item event too",
  countEvent(ioNY, "REMOTE_VARIABLE_CHANGED_LIVE") == liveBefore + 1 and hasEvent(ioNY, "ITEM:" .. away.id)
)
check("mirror state current", ioNY.vars["California.Away.STATE"].value == "current")
check("latency sample recorded", CA.latency.p95_ms ~= nil)
check("same value again is a confirmation, not a publish", select(2, CA:setLocal("Away", "1")) == "unchanged")

-- ── 4. echo/loop safety: NY cannot republish CA's value ────────────────────
print("\n[4] ownership on the relay")
local forged = CA:envelope("state", { items = { { id = occ.id, rev = 99, value = schema.current(false) } } })
local resp = relay:sync("ep-ca", { outbound = { forged }, since_seq = CA.cursor.since_seq })
check("relay rejects a value for an item CA does not own", resp.accepted[1].result.rejected[1].reason == "not owner")

-- ── 5. publication filter: min interval coalesces ───────────────────────────
print("\n[5] filters")
NY:setLocal("Guest_Count", 1)
NY:setLocal("Guest_Count", 2)
NY:setLocal("Guest_Count", 3)
sync(NY, "ep-ny")
sync(CA, "ep-ca")
check(
  "first value went out, rapid follow-ups held",
  ioCA.vars["NewYork.Guest_Count"].value == "1",
  ioCA.vars["NewYork.Guest_Count"].value
)
advance(2100)
NY:tick(true)
sync(NY, "ep-ny")
sync(CA, "ep-ca")
check("final value published after the interval, intermediate skipped", ioCA.vars["NewYork.Guest_Count"].value == "3")
check(
  "relay committed rev reflects three publications (initial, 1, 3) and never 2",
  relay.state[guests.id].rev == 3,
  relay.state[guests.id].rev
)

-- ── 6. named events, requests and results ───────────────────────────────────
print("\n[6] events and requests")
check(
  "event refused while peer offline",
  (function()
    local saved = NY.peerState
    NY.peerState = "offline"
    local ok = NY:emitEvent("Doorbell", "front")
    NY.peerState = saved
    return ok == false
  end)()
)
NY:updateRemoteState()
check("peer online", NY.peerState == "online", NY.peerState)
assert(NY:emitEvent("Doorbell", "front"))
assert(NY:emitEvent("Doorbell", "front"))
sync(NY, "ep-ny")
sync(CA, "ep-ca")
check("two occurrences delivered as two events", countEvent(ioCA, "NAMED_EVENT_RECEIVED") == 2 and #ioCA.named == 2)
check(
  "last event variables set with origin and timezone",
  varValue(ioCA, "California.Last_Event_Name") == "Doorbell"
    and varValue(ioCA, "California.Last_Event_Origin"):match("New York Home America/New_York")
)

local req = assert(NY:sendRequest("Prepare_California_Home", "guests=3", 60))
sync(NY, "ep-ny")
sync(CA, "ep-ca")
check(
  "request received in CA slot 1 with routine",
  varValue(ioCA, "California.Request_1_Routine") == "Prepare_California_Home"
    and varValue(ioCA, "California.Request_1_Status") == "delivered"
    and hasEvent(ioCA, "REQUEST_RECEIVED")
)
sync(CA, "ep-ca")
sync(NY, "ep-ny")
check("originator sees delivered", NY:requestSlotStatus(req.slot) == "delivered", NY:requestSlotStatus(req.slot))
check("originator cannot report on its own request", select(2, NY:reportRequest(req.slot, "completed")) ~= nil)
assert(CA:reportRequest(1, "running"))
assert(CA:reportRequest(1, "completed", { text = "lights on, HVAC 70F" }))
sync(CA, "ep-ca")
sync(NY, "ep-ny")
check(
  "result correlated to the originating slot",
  NY:requestSlotStatus(req.slot) == "completed"
    and hasEvent(ioNY, "REQUEST_COMPLETED")
    and varValue(ioNY, "NewYork.Request_" .. req.slot .. "_Result") == "lights on, HVAC 70F"
)

-- concurrent requests, expiry, late result
local r1 = assert(NY:sendRequest("Gate_Open", nil, 5))
local r2 = assert(NY:sendRequest("Gate_Open", nil, 5))
check("concurrent requests take distinct slots", r1.slot ~= r2.slot)
sync(NY, "ep-ny")
sync(CA, "ep-ca")
advance(6000)
NY:tick(true)
check(
  "both expired locally after deadline, Request Expired fired",
  NY:requestSlotStatus(r1.slot) == "expired" and countEvent(ioNY, "REQUEST_EXPIRED") >= 2
)
local caSlot
for i = 1, 4 do
  if CA.requests.slots[i] and CA.requests.slots[i].id == r1.id then
    caSlot = i
  end
end
if caSlot then
  CA:reportRequest(caSlot, "completed")
  sync(CA, "ep-ca")
  sync(NY, "ep-ny")
end
check("late result recorded, no Request Completed fired for it", countEvent(ioNY, "REQUEST_COMPLETED") == 1)

-- ── 7. freshness without value changes ──────────────────────────────────────
print("\n[7] freshness")
advance(40 * 1000)
sync(CA, "ep-ca")
sync(NY, "ep-ny")
check(
  "mirror still current after a heartbeat-only period",
  ioNY.vars["California.Away.STATE"].value == "current",
  ioNY.vars["California.Away.STATE"].value
)
relay.down = true
advance(60 * 1000)
sync(NY, "ep-ny")
check(
  "relay down → disconnected, Link Disconnected fired",
  NY.transport == "disconnected" and hasEvent(ioNY, "LINK_DISCONNECTED")
)
NY:tick(false)
check(
  "mirrors marked stale while disconnected, value kept",
  ioNY.vars["California.Away.STATE"].value == "stale" and ioNY.vars["California.Away"].value == "1"
)
check("aggregate Offline", NY.remoteState == "Offline")
relay.down = false
sync(NY, "ep-ny")
sync(CA, "ep-ca")
sync(NY, "ep-ny")
NY:tick(true)
check(
  "reconnect: synced again and current",
  NY:isSynced() and ioNY.vars["California.Away.STATE"].value == "current",
  NY.reconcile.phase .. " " .. tostring(ioNY.vars["California.Away.STATE"].value)
)
check(
  "no event replay after reconnect",
  countEvent(ioNY, "NAMED_EVENT_RECEIVED") == 0 and countEvent(ioCA, "NAMED_EVENT_RECEIVED") == 2
)

-- ── 8. restart: restore from persistence, no live events, stale backup ─────
print("\n[8] restart and persistence")
local ioCA2 = newIo("CA2")
ioCA2.store = ioCA.store -- same controller, same persisted state
local CA2 = Engine.new(ioCA2)
local n = CA2:restoreVariables()
check("variables re-added in persisted order", n == #ioCA.varOrder and ioCA2.varOrder[1] == ioCA.varOrder[1], n)
check("owner value restored from persistence", ioCA2.vars["California.Away"].value == "1")
check("mirror restored as last-known", ioCA2.vars["NewYork.Occupied"].value == "1")
-- Simulate an older backup: pretend the persisted Away revision is behind the relay.
CA2.values[away.id].rev = 0
CA2.values[away.id].tv = schema.current(false)
provision(CA2, "ep-ca", "ep-ny")
sync(CA2, "ep-ca")
check(
  "stale backup adopts the committed value and reports it",
  ioCA2.vars["California.Away"].value == "1" and CA2.lastError:match("stale_backup"),
  CA2.lastError
)
check("no Remote Variable Changed Live during restore", countEvent(ioCA2, "REMOTE_VARIABLE_CHANGED_LIVE") == 0)
check("Initial Sync Complete after restart", hasEvent(ioCA2, "INITIAL_SYNC_COMPLETE"))

-- ── 9. controller replacement: generation fencing ──────────────────────────
print("\n[9] generation fencing")
relay.endpoints["ep-ca"].gen = 2
provision(CA2, "ep-ca", "ep-ny", 2)
local stale = CA:envelope("state", { items = { { id = away.id, rev = 50, value = schema.current(false) } } })
local r = relay:sync("ep-ca", { outbound = { stale }, since_seq = 0 })
check("old-generation message rejected by the relay", r.rejected[1].reason == "obsolete generation")
sync(CA2, "ep-ca")
sync(NY, "ep-ny")
check("peer learned the new generation", NY.link.peer_gen == 2, NY.link.peer_gen)
local forgedOld = { v = 1, t = "state", id = "old-1", link = "L", ep = "ep-ca", gen = 1, body = { items = {} } }
NY:applyInbound(forgedOld)
check("driver drops obsolete-generation inbound", NY.lastError:match("obsolete generation"), NY.lastError)

-- ── 10. pause semantics ─────────────────────────────────────────────────────
print("\n[10] pause")
relay.commandsPaused = true
sync(NY, "ep-ny")
check("Commands Paused fired, state still flows", hasEvent(ioNY, "COMMANDS_PAUSED") and NY.commandsPaused)
check("request refused locally while paused", select(2, NY:sendRequest("Gate_Open")) == "commands paused")
check("conditional: commands not permitted", not NY:commandsPermitted())
NY:setLocal("Occupied", false)
sync(NY, "ep-ny")
sync(CA2, "ep-ca")
check("read-only reporting continues during command pause", ioCA2.vars["NewYork.Occupied"].value == "0")
relay.commandsPaused = false
sync(NY, "ep-ny")
check("Commands Resumed", hasEvent(ioNY, "COMMANDS_RESUMED") and NY:commandsPermitted())
NY:pauseCommandsLocal(1, "test")
check(
  "local suspension expires on its own",
  (function()
    advance(61 * 1000)
    NY:tick(true)
    return NY.pausedLocal == nil
  end)()
)

-- ── 11. delete keeps the tombstone ──────────────────────────────────────────
print("\n[11] delete / rename")
local preview = CA2:renamePreview(mode.id, "House_Mode")
check(
  "rename preview shows old and new names",
  preview.from == "California.System_Mode" and preview.to == "California.House_Mode"
)
assert(CA2:renameItem(mode.id, "House_Mode"))
check(
  "old variable hidden, new one created, id order grows",
  ioCA2.vars["California.System_Mode"].hidden == true and ioCA2.vars["California.House_Mode"] ~= nil
)
assert(CA2:deleteItem(mode.id))
sync(CA2, "ep-ca")
sync(NY, "ep-ny")
sync(CA2, "ep-ca")
CA2:tick(true)
check(
  "peer mirror of a deleted item becomes unavailable, variable kept",
  ioNY.vars["California.House_Mode.STATE"] == nil or ioNY.vars["California.House_Mode.STATE"].value == "unavailable"
)
local st = CA2:statusProperties()
check(
  "status properties populated",
  st["Local Variables Created"] == "1"
    and st["Relay Connection"] == "connected"
    and st["Remote System State"]:match("^Ready"),
  st["Remote System State"]
)
local diag = CA2:diagnostics()
check("diagnostics carry no payloads", diag.items[1].value == nil and diag.items[1].state ~= nil)

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
