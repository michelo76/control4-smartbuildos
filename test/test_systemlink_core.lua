-- System Link pure-core tests: schema, filters, freshness, protocol,
-- requests/events, loop prevention, reconciliation.
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
local schema = require("systemlink.schema")
local filters = require("systemlink.filters")
local freshness = require("systemlink.freshness")
local protocol = require("systemlink.protocol")
local requests = require("systemlink.requests")
local loop = require("systemlink.loop")
local reconcile = require("systemlink.reconcile")

local CA, NY = "ep-california", "ep-newyork"

-- ── schema ──────────────────────────────────────────────────────────────────
print("\n[1] schema: definitions, ownership, naming, tombstones")
do
  local reg = schema.newRegistry()
  local ok, err = schema.addDefinition(reg, { id = "i1", name = "Away", type = "BOOLEAN", owner = CA }, 1000)
  check("boolean definition accepted", ok, err)
  ok, err = schema.addDefinition(reg, { id = "i2", name = "Away", type = "BOOLEAN", owner = CA }, 1000)
  check("duplicate name for same owner refused", not ok and err:match("name already"), err)
  ok = schema.addDefinition(
    reg,
    { id = "i3", name = "System_Mode", type = "CHOICE", owner = CA, allowed_values = { "Home", "Away", "Vacation" } },
    1000
  )
  check("choice definition accepted", ok)
  ok, err = schema.addDefinition(reg, { id = "i4", name = "Bad name", type = "STRING", owner = CA })
  check("name with a space refused", not ok, err)
  ok, err = schema.addDefinition(reg, { id = "i5", name = "Temp", type = "INTEGER", owner = CA, min = 10, max = 5 })
  check("min > max refused", not ok, err)
  ok, err = schema.addDefinition(
    reg,
    { id = "i6", name = "Temp", type = "DECIMAL", owner = CA, precision = 1, filter = { threshold = 0.5 } }
  )
  check("decimal with threshold filter accepted", ok, err)
  ok, err =
    schema.addDefinition(reg, { id = "i7", name = "Label", type = "STRING", owner = CA, filter = { threshold = 1 } })
  check("threshold on a STRING refused", not ok, err)

  check(
    "variable name is namespaced",
    schema.variableName(schema.namespace("California Home"), reg.items.i1) == "California_Home.Away"
  )
  check("namespace drops a leading digit", schema.namespace("9 Lives") == "Lives")

  local v, e = schema.coerce(reg.items.i1, "on")
  check("boolean coerces 'on'", v == true, e)
  v, e = schema.coerce(reg.items.i3, "Party")
  check("choice refuses unknown value", v == nil and e:match("allowed"), e)
  v = schema.coerce(reg.items.i6, "21.26")
  check("decimal rounds to precision", v == 21.3, v)
  check("false is a CURRENT value", schema.current(false).s == "current" and schema.current(false).v == false)
  check("unknown has no payload", schema.unknown().v == nil and schema.toNative(reg.items.i1, schema.unknown()) == "")
  check("native boolean renders 0/1", schema.toNative(reg.items.i1, schema.current(false)) == "0")

  local orderBefore = reg.items.i3.order
  check(
    "delete tombstones but keeps order",
    schema.deleteDefinition(reg, "i1", 2000) and reg.items.i1.deleted_at == 2000 and reg.items.i3.order == orderBefore
  )
  ok, err = schema.addDefinition(reg, { id = "i8", name = "Away", type = "BOOLEAN", owner = CA }, 3000)
  check(
    "deleted name may be reused by a NEW id with a NEW order slot",
    ok and reg.items.i8.order == #reg.order and reg.items.i8.order ~= reg.items.i1.order,
    err
  )
  ok, err = schema.updateDefinition(reg, "i8", { type = "STRING" })
  check("type change refused in place", not ok, err)
  ok = schema.renameDefinition(reg, "i8", "Away_Mode")
  check(
    "rename keeps id/order and bumps schema_rev",
    ok and reg.items.i8.name == "Away_Mode" and reg.items.i8.schema_rev == 1
  )
  local owned, mirrored = schema.counts(reg, CA)
  check("counts owned active items", owned == 3 and mirrored == 0, owned .. "/" .. mirrored)
end

print("\n[2] schema: peer mirrors, ownership enforcement")
do
  local reg = schema.newRegistry()
  schema.addDefinition(reg, { id = "ca1", name = "Away", type = "BOOLEAN", owner = CA }, 1)
  local r = schema.applyPeerSchema(reg, CA, NY, {
    { id = "ny1", name = "Occupied", type = "BOOLEAN", owner = NY, schema_rev = 0 },
    { id = "ny2", name = "Guest_Count", type = "INTEGER", owner = NY, schema_rev = 0, min = 0 },
    { id = "ny3", name = "Private", type = "STRING", owner = NY, schema_rev = 0, export_enabled = false },
    { id = "evil", name = "Away", type = "BOOLEAN", owner = CA, schema_rev = 0 },
  }, 5)
  check("two mirrors added", #r.added == 2, #r.added)
  check("non-exported item not mirrored", reg.items.ny3 == nil)
  check("definition claiming OUR ownership rejected", #r.rejected == 1 and r.rejected[1].id == "evil")
  check("mirror flagged and ordered after local", reg.items.ny1.mirror == true and reg.items.ny1.order == 2)
  local owned, mirrored = schema.counts(reg, CA)
  check("counts mirrors separately", owned == 1 and mirrored == 2)

  r = schema.applyPeerSchema(reg, CA, NY, {
    { id = "ny1", name = "Is_Occupied", type = "BOOLEAN", owner = NY, schema_rev = 1 },
  }, 6)
  check("renamed mirror reported as changed", #r.changed == 1 and reg.items.ny1.name == "Is_Occupied")
  check("absent mirror tombstoned", #r.removed == 1 and reg.items.ny2.deleted_at == 6)
  r = schema.applyPeerSchema(reg, CA, NY, {
    { id = "ny1", name = "Is_Occupied", type = "STRING", owner = NY, schema_rev = 2 },
    { id = "ny2", name = "Guest_Count", type = "INTEGER", owner = NY, schema_rev = 0, min = 0 },
  }, 7)
  check("type change on owner rejected for the mirror", #r.rejected == 1 and reg.items.ny1.type == "BOOLEAN")
  check("revived tombstone keeps its order", reg.items.ny2.deleted_at == nil and reg.items.ny2.order == 3)
  local exp = schema.ownedExport(reg, CA)
  check("owned export excludes mirrors", #exp == 1 and exp[1].id == "ca1")
end

-- ── filters ─────────────────────────────────────────────────────────────────
print("\n[3] filters: defaults, debounce, threshold, min interval, max silence")
do
  local def = { id = "x", name = "X", type = "INTEGER", owner = CA }
  local st = filters.newState()
  local d = filters.offer(st, def, schema.current(1), 1000)
  check("no filter: immediate publish", d.publish and d.filter_delay_ms == 0, d.reason)
  d = filters.offer(st, def, schema.current(1), 2000)
  check("same value: no publish but confirmed", not d.publish and d.confirmed)

  def = { id = "o", name = "Occ", type = "BOOLEAN", owner = CA, filter = { debounce_s = 5 } }
  st = filters.newState()
  d = filters.offer(st, def, schema.current(true), 1000)
  check("debounce defers", not d.publish and d.due_at == 6000, d.due_at)
  d = filters.offer(st, def, schema.current(false), 3000)
  check("change during debounce restarts the window", not d.publish and d.due_at == 8000, d.due_at)
  d = filters.flush(st, def, 7999)
  check("not due yet", not d.publish)
  d = filters.flush(st, def, 8000)
  check(
    "publishes final value after stability with delay reported",
    d.publish and d.value.v == false and d.filter_delay_ms == 7000,
    d.filter_delay_ms
  )
  check("source and published kept apart", st.source.v == false and st.published.v == false)

  def = { id = "t", name = "Temp", type = "DECIMAL", owner = CA, filter = { threshold = 0.5 } }
  st = filters.newState()
  check("first value publishes", filters.offer(st, def, schema.current(20.0), 1).publish)
  check("0.3 change suppressed", filters.offer(st, def, schema.current(20.3), 2).reason == "threshold")
  check("0.5 cumulative change vs PUBLISHED publishes", filters.offer(st, def, schema.current(20.5), 3).publish)
  check("state change always passes threshold", filters.offer(st, def, schema.unavailable(), 4).publish)

  def = { id = "d", name = "Dim", type = "INTEGER", owner = CA, filter = { min_interval_s = 2 } }
  st = filters.newState()
  check("first publishes", filters.offer(st, def, schema.current(10), 1000).publish)
  d = filters.offer(st, def, schema.current(20), 1500)
  check("rapid change deferred to interval", not d.publish and d.due_at == 3000)
  filters.offer(st, def, schema.current(30), 1600)
  filters.offer(st, def, schema.current(40), 1700)
  d = filters.flush(st, def, 3000)
  check("coalesced: only the final value goes out", d.publish and d.value.v == 40)

  def = { id = "s", name = "Sil", type = "INTEGER", owner = CA, filter = { max_silence_s = 60 } }
  st = filters.newState()
  filters.offer(st, def, schema.current(5), 1000)
  d = filters.flush(st, def, 30000)
  check("max silence not yet due", not d.publish and d.due_at == 61000)
  d = filters.flush(st, def, 61000)
  check("max silence refreshes the published value", d.publish and d.refresh and d.value.v == 5)
end

-- ── freshness ───────────────────────────────────────────────────────────────
print("\n[4] freshness and aggregate state")
do
  local rec = freshness.newRecord()
  local def = { freshness = { max_age_s = 60 } }
  check("never confirmed = unknown", freshness.evaluate(rec, def, schema.current(1), 0, true).state == "unknown")
  freshness.onUpdate(rec, 1000)
  check("fresh after update", freshness.evaluate(rec, def, schema.current(1), 30000, true).state == "current")
  freshness.onConfirm(rec, 50000)
  local e = freshness.evaluate(rec, def, schema.current(1), 100000, true)
  check("unchanged value stays current while confirmed", e.state == "current" and e.age_ms == 50000, e.state)
  e = freshness.evaluate(rec, def, schema.current(1), 120000, true)
  check("stale once unconfirmed past policy", e.state == "stale")
  check(
    "not synced = stale even if recent",
    freshness.evaluate(rec, def, schema.current(1), 51000, false).state == "stale"
  )
  check(
    "unavailable reported as such",
    freshness.evaluate(rec, def, schema.unavailable(), 51000, true).state == "unavailable"
  )

  local s = freshness.aggregate({ license = "attention", paused = true, transport = "disconnected" })
  check("license outranks paused and offline", s == "License Attention", s)
  s = freshness.aggregate({ license = "ok", paused = true, transport = "disconnected" })
  check("paused outranks offline", s == "Paused")
  s = freshness.aggregate({ license = "ok", transport = "connected", peer = "online", sync = "in_progress" })
  check("synchronizing", s == "Synchronizing")
  s = freshness.aggregate({
    license = "ok",
    transport = "connected",
    peer = "online",
    sync = "complete",
    stale_items = 2,
  })
  check("stale items", s == "Stale")
  local st, reason = freshness.aggregate({
    license = "ok",
    transport = "connected",
    peer = "online",
    sync = "complete",
    stale_items = 0,
  })
  check("ready", st == "Ready" and reason == "synchronized")
  check("peer online within 2 intervals", freshness.peerState(1000, 30000, 60000) == "online")
  check("peer stale within 5", freshness.peerState(1000, 30000, 100000) == "stale")
  check("peer offline beyond", freshness.peerState(1000, 30000, 200000) == "offline")
end

-- ── protocol ────────────────────────────────────────────────────────────────
print("\n[5] protocol: validation, fencing, dedup, ordering, negotiation")
do
  local ctx = { link = "L1", self = CA, peer = NY, peer_gen = 3 }
  local function env(over)
    local e = { v = 1, t = "state", id = "m1", link = "L1", ep = NY, gen = 3, body = {} }
    for k, v in pairs(over or {}) do
      e[k] = v
    end
    return e
  end
  check("valid envelope", protocol.validate(env(), ctx))
  check(
    "oversized rejected",
    select(2, protocol.validate(env(), { link = "L1", self = CA, peer = NY, rawLen = 40000 })) == "oversized"
  )
  check("wrong link rejected", select(2, protocol.validate(env({ link = "L2" }), ctx)) == "wrong link")
  check("echo rejected", select(2, protocol.validate(env({ ep = CA }), ctx)) == "echo")
  check("obsolete generation rejected", select(2, protocol.validate(env({ gen = 2 }), ctx)) == "obsolete generation")
  check("newer generation accepted", protocol.validate(env({ gen = 4 }), ctx))
  check("unknown type rejected", select(2, protocol.validate(env({ t = "lua" }), ctx)) == "unknown type")
  check("unsupported version rejected", select(2, protocol.validate(env({ v = 2 }), ctx)) == "unsupported version")
  check("relay messages accepted", protocol.validate(env({ ep = "relay", t = "snapshot" }), ctx))
  check(
    "expiry uses relay time",
    protocol.isExpired({ exp = 1000 }, 1000)
      and not protocol.isExpired({ exp = 1000 }, 999)
      and not protocol.isExpired({}, 5)
  )

  local d = protocol.newDedup(3)
  check("first seen accepted", d:accept("a") and d:accept("b") and d:accept("c"))
  check("repeat rejected", not d:accept("a"))
  check("ring evicts oldest", d:accept("d") and d:accept("a"))
  local restored = protocol.restoreDedup({ cap = 3, ring = { "x", "y" }, head = 2 })
  check("restored dedup still rejects", not restored:accept("x") and restored:accept("z"))

  check("rev order within gen", protocol.compareRev(1, 5, 1, 6) == -1)
  check("gen outranks rev", protocol.compareRev(2, 1, 1, 99) == 1)
  check("incoming newer applies", protocol.classifyIncoming({ gen = 1, rev = 5 }, { gen = 1, rev = 6 }) == "apply")
  check("incoming equal confirms", protocol.classifyIncoming({ gen = 1, rev = 5 }, { gen = 1, rev = 5 }) == "confirm")
  check("incoming older ignored", protocol.classifyIncoming({ gen = 2, rev = 0 }, { gen = 1, rev = 9 }) == "ignore")
  check("negotiate picks highest common", protocol.negotiate(1, 3, 2, 5) == 3)
  check("negotiate fails with no overlap", select(2, protocol.negotiate(1, 1, 2, 3)) ~= nil)
  check("approxSize bounded", protocol.approxSize({ a = string.rep("x", 100) }) > 100)
end

-- ── requests & events ───────────────────────────────────────────────────────
print("\n[6] requests: slots, transitions, expiry, late results, abandonment")
do
  local reg = requests.newRegistry(2)
  local r1 = requests.open(reg, { id = "r1", routine = "Prepare_Home", direction = "out" }, 1000)
  local r2 = requests.open(reg, { id = "r2", routine = "Prepare_Home", direction = "out", deadline_ms = 5000 }, 1000)
  check("two concurrent requests in distinct slots", r1.slot ~= r2.slot and requests.inFlight(reg) == 2)
  check(
    "third refused when slots are full",
    select(2, requests.open(reg, { id = "r3", routine = "x" }, 1000)) == "no free request slot"
  )
  check("duplicate id refused", select(2, requests.open(reg, { id = "r1", routine = "x" }, 1000)) ~= nil)
  local e = requests.transition(reg, "r1", "delivered", nil, 1100)
  check("accepted → delivered", e.status == "delivered")
  check("illegal backwards transition refused", select(2, requests.transition(reg, "r1", "accepted", nil, 1200)) ~= nil)
  local done, _, final = requests.transition(reg, "r1", "completed", { ok = true }, 2000)
  check("completed releases slot and keeps result", final and done.result.ok and requests.inFlight(reg) == 1)
  check("slot reusable", requests.open(reg, { id = "r3", routine = "x" }, 2001) ~= nil)
  local expired = requests.expire(reg, 5000)
  check("deadline expires r2 only", #expired == 1 and expired[1].id == "r2" and reg.by_id.r3.status == "accepted")
  local late = requests.transition(reg, "r2", "completed", { ok = true }, 6000)
  check(
    "late result recorded, status stays expired",
    late.late == true and late.status == "expired" and late.late_status == "completed"
  )
  check(
    "completed cannot be re-completed",
    select(2, requests.transition(reg, "r1", "failed", nil, 6000)) == "request already final"
  )
  check("unknown id refused", select(2, requests.transition(reg, "nope", "completed", nil, 6000)) == "unknown request")
  local ab = requests.abandonAll(reg, 7000, "link revoked")
  check("abandon marks in-flight unknown", #ab == 1 and ab[1].status == "unknown" and requests.inFlight(reg) == 0)
  requests.prune(reg, 2000 + 3600000, 3600000)
  check("prune keeps recent history", #reg.history == 3, #reg.history)
  requests.prune(reg, 7000 + 3600001, 3600000)
  check("prune forgets old ids", reg.by_id.r1 == nil and #reg.history == 0)

  check("outbound: send when online", requests.outboundPolicy(true, false, 0) == "send")
  check("outbound: fail when offline and not queueable", requests.outboundPolicy(false, false, 0) == "fail")
  check(
    "outbound: bounded queue",
    requests.outboundPolicy(false, true, 5) == "queue" and requests.outboundPolicy(false, true, 20) == "fail"
  )
  local dd = protocol.newDedup(10)
  check(
    "inbound expired never delivered",
    requests.inboundPolicy({ id = "e1", exp = 10 }, 11, dd, protocol) == "expired"
  )
  check(
    "inbound delivered once",
    requests.inboundPolicy({ id = "e2", exp = 100 }, 11, dd, protocol) == "deliver"
      and requests.inboundPolicy({ id = "e2", exp = 100 }, 12, dd, protocol) == "duplicate"
  )
  local occ = requests.newOccurrence("def1", "o1", NY, 0, 9999)
  check("occurrence ttl clamped", occ.ttl_s == requests.EVENT_MAX_TTL_S)
end

-- ── loop ────────────────────────────────────────────────────────────────────
print("\n[7] loop prevention: bursts and causal hops")
do
  local st = loop.newState()
  local allowed = 0
  for i = 1, 31 do
    if loop.offer(st, "i1", i * 100) then
      allowed = allowed + 1
    end
  end
  check("30 in 10 s allowed, 31st suspended", allowed == 30 and #loop.suspensions(st, 3100) == 1)
  check("suspended while window lasts", select(2, loop.offer(st, "i1", 4000)) == "suspended")
  check("recovers after suspension", loop.offer(st, "i1", 3100 + 60001))
  check("independent item unaffected", loop.offer(st, "i2", 3200))
  local st2 = loop.newState()
  check("causal loop detected at max hops", select(2, loop.offer(st2, "i1", 1, { hops = loop.MAX_HOPS })) == "loop")
  check("hop count increments", loop.nextHops(2) == 3 and loop.nextHops(nil) == 1)
  loop.recover(st2, "i1")
  check("authorized recovery clears suspension", loop.offer(st2, "i1", 2, { hops = 1 }))
end

-- ── reconcile ───────────────────────────────────────────────────────────────
print("\n[8] reconciliation phases and owner revisions")
do
  local st = reconcile.newState()
  check("cannot skip phases", not reconcile.advance(st, "authenticated", 1))
  reconcile.advance(st, "restored", 1)
  check("restore classified", reconcile.classify(st, "relay") == "restore")
  reconcile.advance(st, "stale_marked", 2)
  reconcile.advance(st, "authenticated", 3)
  reconcile.advance(st, "schema", 4)
  reconcile.advance(st, "revisions", 5)
  reconcile.advance(st, "snapshot", 6)
  check("snapshot classified before synced", reconcile.classify(st, "relay") == "snapshot")
  reconcile.advance(st, "synced", 7)
  check("live after synced", reconcile.isSynced(st) and reconcile.classify(st, "relay") == "live")
  check("admin always admin", reconcile.classify(st, "admin") == "admin")
  reconcile.disconnected(st)
  check("disconnect drops to stale_marked", st.phase == "stale_marked" and not reconcile.isSynced(st))

  local decisions, notices = reconcile.reconcileOwner({
    a = { gen = 2, rev = 5, value = "local" },
    b = { gen = 2, rev = 2, value = "backup" },
    c = { gen = 2, rev = 3, value = "same" },
    d = { gen = 2, rev = 1, value = "new" },
    e = { gen = 1, rev = 9, value = "old-gen-local" },
  }, {
    a = { gen = 2, rev = 4, value = "committed" },
    b = { gen = 2, rev = 7, value = "committed-newer" },
    c = { gen = 2, rev = 3, value = "same" },
    e = { gen = 1, rev = 9, value = "old-gen-committed" },
  }, 2)
  check("pending local update republishes", decisions.a.action == "republish")
  check(
    "stale backup adopts committed and is reported",
    decisions.b.action == "adopt"
      and decisions.b.value == "committed-newer"
      and #notices == 1
      and notices[1].kind == "stale_backup"
  )
  check("equal confirmed", decisions.c.action == "confirmed")
  check("never published is fresh", decisions.d.action == "fresh")
  check(
    "old generation on relay republishes at new generation",
    decisions.e.action == "republish" and decisions.e.reason == "new generation"
  )
  check(
    "persistence policy",
    reconcile.persistencePolicy(false, true) == "rebuild_from_relay"
      and reconcile.persistencePolicy(false, false) == "defaults"
      and reconcile.persistencePolicy(true, false) == "use"
  )
end

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
