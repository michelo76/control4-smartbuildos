-- Pure configuration and engine regression tests: no controller/network required.
package.path = "./src/?.lua;./vendor/?.lua;" .. package.path
require("lib.utils")
require("drivers-common-public.global.lib")
local config = require("systemlink.configuration")
local templates = require("systemlink.templates")
local Engine = require("systemlink.engine")
local schema = require("systemlink.schema")
local JSON = require("JSON")
local pass, fail = 0, 0
local function check(name, ok)
  if ok then
    pass = pass + 1
    print("  ok   " .. name)
  else
    fail = fail + 1
    print("  FAIL " .. name)
  end
end
local function same(a, b)
  if type(a) ~= type(b) then
    return false
  end
  if type(a) ~= "table" then
    return a == b
  end
  for k, v in pairs(a) do
    if not same(v, b[k]) then
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
local f = assert(io.open("test/fixtures/systemlink/templates.json"))
local reference = JSON:decode(f:read("*a"))
f:close()
check("all seven recipes exactly match the TS reference fixture", #templates == 7 and same(reference, templates))
local now, n = 1000000, 0
local store, vars, events = {}, {}, {}
local ioFake = {
  now = function()
    return now
  end,
  isoNow = function()
    return "2026-10-19T12:00:00Z"
  end,
  timezone = function()
    return "America/New_York"
  end,
  load = function(k)
    return config.copy(store[k])
  end,
  save = function(k, v)
    store[k] = config.copy(v)
  end,
  uuid = function()
    n = n + 1
    return "new-" .. n
  end,
  encode = function(t)
    return JSON:encode(t)
  end,
  addVariable = function(name, v, t, r, h)
    vars[name] = { value = v, hidden = h, readOnly = r }
  end,
  setVariable = function(name, v)
    vars[name] = vars[name] or {}
    vars[name].value = v
  end,
  addEvent = function() end,
  fireItemEvent = function() end,
  fireEvent = function(e)
    events[#events + 1] = e
  end,
  property = function() end,
  formatTime = tostring,
  log = { warn = function() end, info = function() end, debug = function() end },
}
local e = Engine.new(ioFake)
e:onProvisioned({
  endpoint_id = "local",
  link_id = "link",
  generation = 1,
  role = "a",
  namespace = "Home",
  peer = { id = "peer", namespace = "Guest" },
  protocol = 1,
  link_state = "approved",
})
for _, t in ipairs(templates) do
  for _, d in ipairs(t.ownerItems) do
    local def = config.copy(d)
    def.id = "test"
    def.owner = "local"
    check("template definition validates: " .. t.id .. "/" .. d.name, schema.validateDefinition(def))
  end
end
local ordinary = assert(
  e:createItem({ name = "Mode", type = "CHOICE", allowed_values = { "Home", "Away" }, group = "Arrival" }, "Away")
)
local id = ordinary.id
assert(e:createItem({
  name = "Light_Level",
  type = "INTEGER",
  companion = {
    kind = "light",
    name = "Porch",
    field = "Level",
    control = true,
    device_id = 47,
  },
}, 20))
e.registry.items.remote =
  { id = "remote", owner = "peer", name = "Temperature", type = "DECIMAL", order = 3, mirror = true, group = "Weather" }
e.registry.order[3] = "remote"
local doc = assert(config.export(e))
local encoded = JSON:encode(doc)
check("export version and roles match version-1 contract", doc.version == 1 and #doc.endpoints == 2 and #doc.items == 3)
check(
  "export omits values credentials and equipment identifiers",
  not encoded:find('"value"')
    and not encoded:find('"device_id"')
    and not encoded:find('"credential"')
    and not encoded:find('"control"')
)
check(
  "groups sorted and companion requirement retained",
  doc.groups[1] == "Arrival" and doc.groups[2] == "Weather" and doc.required_companions[1].on_role == "b"
)
local plan = assert(config.plan(doc, "a"))
check(
  "local role only; export feedback requires explicit recreation",
  #plan.definitions == 1
    and plan.skipped_exports == 1
    and plan.definitions[1].name == "Mode"
    and plan.definitions[1].companion == nil
)
check("source IDs and owners never imported", plan.definitions[1].id == nil and plan.definitions[1].owner == nil)
local other = assert(config.plan(doc, "b"))
check(
  "opposite role selects its own definitions",
  #other.definitions == 1 and other.definitions[1].name == "Temperature"
)
local before = #e.registry.order
local ok = config.apply(e, { { name = "Fresh", type = "BOOLEAN" }, { name = "Mode", type = "STRING" } })
check(
  "duplicate anywhere refuses entire batch before writes",
  not ok and #e.registry.order == before and e:findByName("Fresh") == nil
)
local malicious = config.copy(doc)
malicious.items[1].definition.token = "never"
check("nested secrets refused", config.plan(malicious, "a") == nil)
malicious = config.copy(doc)
malicious.items[2].definition.type = "NOPE"
check("malformed item refuses entire import", config.plan(malicious, "a") == nil)
check("unknown versions refused", config.plan({ version = 2, items = {} }, "a") == nil)
check("non-array item collection refused", config.plan({ version = 1, items = { surprise = {} } }, "a") == nil)
check("invalid role refused", config.plan(doc, "z") == nil)
check("import into same owner refuses name collision", not config.apply(e, plan.definitions))
local definitions = config.copy(plan.definitions)
definitions[1].name = "Imported_Mode"
check("valid import applies", config.apply(e, definitions))
local imported = e:findByName("Imported_Mode")
check("import creates a new id and unknown value", imported.id ~= id and e.values[imported.id].tv.s == "unknown")
local p = assert(e:namespacePreview("local", "Residence"))
check(
  "namespace preview is read only and explains rebind",
  e:variableNameFor(ordinary) == "Home.Mode" and #p.changes > 0 and p.effect:find("Rebind")
)
check("namespace collisions refused", e:namespacePreview("local", "Guest") == nil)
check(
  "invalid/truncated namespace refused",
  e:namespacePreview("local", "123 Bad") == nil and e:namespacePreview("local", string.rep("a", 25)) == nil
)
check(
  "rename applies with same item identity",
  e:renameNamespace("local", "Residence") and ordinary.id == id and e:variableNameFor(ordinary) == "Residence.Mode"
)
check(
  "old native names tombstoned and new value preserved",
  vars["Home.Mode"].hidden and vars["Residence.Mode"].value == "Away"
)
local reboot = Engine.new(ioFake)
check("namespace override survives persistence", reboot:variableNameFor(reboot.registry.items[id]) == "Residence.Mode")
reboot:onProvisioned({
  endpoint_id = "local",
  link_id = "link",
  generation = 2,
  role = "a",
  namespace = "Home",
  peer = { id = "peer", namespace = "Guest" },
  protocol = 1,
})
check(
  "reprovision preserves local namespace without changing relay identity",
  reboot:variableNameFor(reboot.registry.items[id]) == "Residence.Mode" and reboot.link.namespace == "Home"
)
check("unavailable peer cannot be a namespace target", e:namespacePreview(nil, "Other") == nil)
local mirrored = e.registry.items.remote
local mirrorId = mirrored.id
local peerBefore = e.link.peer_namespace
check(
  "remote namespace rename keeps mirror ownership and read-only flag",
  e:renameNamespace("peer", "Guesthouse")
    and mirrored.id == mirrorId
    and mirrored.owner == "peer"
    and vars["Guesthouse.Temperature"].readOnly
    and e.link.peer_namespace == peerBefore
)
check("local writes to renamed remote mirror still refused", not e:setLocal("Guesthouse.Temperature", 25))
check("historical native names cannot be reused", e:namespacePreview("local", "Home") == nil)
e.pending[#e.pending + 1] = { id = "pulse", t = "command", body = { routine = "relay.trigger" } }
e.pending[#e.pending + 1] = { id = "event", t = "event", body = {} }
check("whole-link pause accepted", e:pauseLinkLocal(1))
check(
  "paused link blocks relay, commands, requests and events",
  e:buildSync() == nil
    and not e:commandsPermitted()
    and not e:emitEvent("Doorbell", "", 30)
    and not e:sendRequest("Run", "", 30)
)
local onlyState = true
for _, env in ipairs(e.pending) do
  if env.t ~= "schema" and env.t ~= "state" then
    onlyState = false
  end
end
check("pause discards pending physical commands and events", onlyState)
check("local values continue changing during suspension", e:setLocal("Mode", "Home"))
local oldCursor = e.cursor.since_seq
e:onSyncResponse({ next_seq = 9999, peer = { namespace = "Changed" }, inbound = {} })
check(
  "in-flight relay response ignored while paused",
  e.cursor.since_seq == oldCursor and e.link.peer_namespace == "Guest"
)
local paused = Engine.new(ioFake)
check("whole-link suspension survives restart", paused.wholePause ~= nil and paused:buildSync() == nil)
check("mirror cannot be treated current while paused", not paused:isSynced())
now = now + 61000
check(
  "timed pause expires and requests fresh snapshot",
  paused:tick(false) and paused.wholePause == nil and paused.needSnapshot and paused.resumeSnapshot
)
check("manual resume is idempotent and does not clear server suspension", not paused:resumeLinkLocal())
-- A queued remote request at the resume snapshot boundary must never execute.
local count = #events
paused:onSyncResponse({
  protocol = 1,
  server_time = now,
  link = { state = "approved" },
  snapshot = { peer_items = {}, peer_state = {}, own_committed = {}, head_seq = 99 },
  inbound = {
    {
      v = 1,
      t = "event",
      id = "stale-event",
      link = "link",
      ep = "peer",
      gen = 1,
      seq = 99,
      ts = now,
      exp = now + 30000,
      body = {
        def = "Doorbell",
      },
    },
  },
  next_seq = 99,
})
local delivered = false
for i = count + 1, #events do
  if events[i] == "NAMED_EVENT_RECEIVED" then
    delivered = true
  end
end
check(
  "resume skips queued one-time occurrences at snapshot boundary",
  not delivered and paused.cursor.since_seq == 99 and not paused.resumeSnapshot
)
local applied = 0
paused.io.onCommand = function()
  applied = applied + 1
  return true
end
local function command(seq)
  return {
    v = 1,
    t = "command",
    id = "remote-command-" .. seq,
    link = "link",
    ep = "peer",
    gen = 1,
    seq = seq,
    ts = "2026-10-19T12:00:00Z",
    exp = now + 30000,
    body = { routine = "relay.trigger", target = "gate" },
  }
end
paused:onSyncResponse({ link = { state = "approved" }, inbound = { command(98) }, next_seq = 99 })
check("later relay pages cannot replay pre-resume commands", applied == 0)
local again = Engine.new(ioFake)
again.io.onCommand = paused.io.onCommand
again:applyInbound(command(98)) -- direct entry is fenced too below
check("resume high-water mark persisted and enforced", again.resumeFence == 99 and applied == 0)
paused:onSyncResponse({ link = { state = "approved" }, inbound = { command(100) }, next_seq = 100 })
check("new command after resume snapshot remains deliverable", applied == 1)
check("invalid duration refused", not paused:pauseLinkLocal(-1) and not paused:pauseLinkLocal(0 / 0))
print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
