-- System Link BRIDGE driver test: loads the real driver.lua under the shim
-- and drives it end to end — init, Agent handshake, provisioning, the relay
-- round trip (fake lib.http), Composer actions/commands/conditionals,
-- mirror refusal, 401 re-provision, Forget Link.
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

C4 = C4 or {}
require("c4_shim")
JSON = require("JSON")

-- ── timers ──────────────────────────────────────────────────────────────────
local clock = { now = 0, timers = {} }
package.preload["drivers-common-public.global.timer"] = function()
  ONE_SECOND = 1000
  ONE_MINUTE = 60000
  ONE_HOUR = 3600000
  function SetTimer(id, ms, cb, repeating)
    clock.timers[id] = { at = clock.now + ms, cb = cb, every = repeating and ms or nil }
  end
  function CancelTimer(id)
    clock.timers[id] = nil
  end
  function KillAllTimers()
    clock.timers = {}
  end
  return true
end
local function advance(ms)
  local target = clock.now + ms
  while true do
    local bestId, bestAt
    for id, t in pairs(clock.timers) do
      if t.at <= target and (bestAt == nil or t.at < bestAt) then
        bestId, bestAt = id, t.at
      end
    end
    if not bestId then
      break
    end
    clock.now = bestAt
    local t = clock.timers[bestId]
    if t.every then
      t.at = clock.now + t.every
    else
      clock.timers[bestId] = nil
    end
    t.cb()
  end
  clock.now = target
end
package.preload["drivers-common-public.global.url"] = function()
  return true
end
package.preload["cloud-client-byte"] = function()
  return true
end

-- ── persist (in memory, keyed; encrypted flag ignored) ──────────────────────
local persisted = {}
package.preload["lib.persist"] = function()
  local P = {}
  -- Mirrors src/lib/persist.lua: a nil default becomes the library's EMPTY
  -- table, so a missing key answers `{}`, never nil (the 2026-10-20 bench
  -- crash: a fresh bridge loaded `{}` as its registry).
  local EMPTY = {}
  function P:get(key, default)
    if default == nil then
      default = EMPTY
    end
    if persisted[key] == nil then
      return default
    end
    return persisted[key]
  end
  function P:set(key, value)
    persisted[key] = value
  end
  function P:delete(key)
    persisted[key] = nil
  end
  function P:reset() end
  return P
end

-- ── websocket: never dials in tests ─────────────────────────────────────────
package.preload["drivers-common-public.module.websocket"] = function()
  local WS = {}
  WS.__index = WS
  function WS:new()
    return nil
  end
  return WS
end

-- ── fake relay behind lib.http ──────────────────────────────────────────────
local relay = { calls = {}, nextError = nil, seq = 0, items = {}, state = {}, inbound = {} }
package.preload["lib.http"] = function()
  return {
    post = function(_, url, data, headers, options)
      relay.calls[#relay.calls + 1] = { url = url, data = data, headers = headers, options = options }
      return {
        next = function(_, resolved, rejected)
          if relay.nextError then
            local e = relay.nextError
            relay.nextError = nil
            rejected(e)
            return
          end
          local accepted, rejectedMsgs = {}, {}
          for _, env in ipairs(data.outbound or {}) do
            if env.t == "schema" then
              for _, def in ipairs(env.body.items) do
                relay.items[def.id] = def
              end
              relay.seq = relay.seq + 1
              accepted[#accepted + 1] = { id = env.id, seq = relay.seq }
            elseif env.t == "state" then
              local acc = {}
              for _, it in ipairs(env.body.items) do
                if relay.items[it.id] then
                  relay.state[it.id] = { rev = it.rev, value = it.value }
                  acc[#acc + 1] = it
                end
              end
              relay.seq = relay.seq + 1
              accepted[#accepted + 1] = { id = env.id, seq = relay.seq, result = { accepted = acc, rejected = {} } }
            else
              relay.seq = relay.seq + 1
              accepted[#accepted + 1] = { id = env.id, seq = relay.seq }
            end
          end
          local inbound = relay.inbound
          relay.inbound = {}
          resolved({
            code = 200,
            body = JSON:encode({
              server_time = clock.now + 1000,
              protocol = 1,
              link = { id = "L", state = "approved", generation = 1, paused = false, commands_paused = false },
              self = { id = "ep-ca", generation = 1 },
              peer = {
                id = "ep-ny",
                generation = 1,
                namespace = "NewYork",
                alias = "New York Home",
                status = "active",
                last_heartbeat_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
              },
              accepted = accepted,
              rejected = rejectedMsgs,
              inbound = inbound,
              next_seq = relay.seq,
              snapshot = (data.since_seq == 0 or data.snapshot)
                  and {
                    peer_items = {
                      {
                        id = "ny-occ",
                        name = "Occupied",
                        type = "BOOLEAN",
                        owner = "ep-ny",
                        schema_rev = 0,
                        order = 1,
                      },
                    },
                    peer_state = { { id = "ny-occ", gen = 1, rev = 3, value = { s = "current", v = true }, seq = 1 } },
                    own_committed = {},
                    head_seq = relay.seq,
                  }
                or nil,
            }),
          })
        end,
      }
    end,
  }
end

-- ── C4 fakes ────────────────────────────────────────────────────────────────
local variables, varMeta, varOrder, firedEvents, sent = {}, {}, {}, {}, {}
function C4:AddVariable(name, default, vtype, readOnly, hidden)
  if varMeta[name] == nil then
    varOrder[#varOrder + 1] = name
    variables[name] = default
  end
  varMeta[name] = { type = vtype, readOnly = readOnly, hidden = hidden }
  return true, 1000 + #varOrder
end
function C4:SetVariable(name, value)
  variables[name] = value
end
function C4:AddEvent() end
function C4:FireEventByID(id)
  firedEvents[#firedEvents + 1] = id
end
function C4:UpdatePropertyList(name, list)
  Properties[name .. "__list"] = list
end
function C4:GetDevices()
  return { [900] = { driverFileName = "smartbuildos.c4z" }, [901] = { driverFileName = "smartbuildos-insights.c4z" } }
end
function C4:SendToDevice(id, command, params)
  sent[#sent + 1] = { id = id, command = command, params = params }
end
function C4:GetDriverConfigInfo(tag)
  if tag == "version" then
    return "20261018.1"
  end
  if tag == "minimum_os_version" then
    return "3.3.2"
  end
  return ""
end
function C4:GetVersionInfo()
  return { version = "3.3.2.1" }
end
function C4:GetTime()
  return clock.now
end
function C4:GetTimeZone()
  return "America/Los_Angeles"
end
function C4:UUID()
  relay.uuidN = (relay.uuidN or 0) + 1
  return string.format("8f7f4a3e-0000-4000-8000-%012d", relay.uuidN)
end
function C4:UpdateProperty(name, value)
  Properties[name] = tostring(value)
end

Properties = {
  ["Log Level"] = "1 - Error",
  ["Log Mode"] = "Print",
  ["Selected Item"] = "-",
  ["New Item Name"] = "",
  ["New Item Type"] = "BOOLEAN",
  ["New Item Description"] = "",
  ["New Item Initial Value"] = "",
  ["New Item Group"] = "",
  ["New Item Allowed Values"] = "",
  ["New Item Export"] = "Yes",
  ["Filter Debounce Seconds"] = "0",
  ["Filter Change Threshold"] = "0",
  ["Filter Minimum Interval Seconds"] = "0",
  ["Filter Maximum Silence Seconds"] = "0",
  ["Request Slots"] = "2",
  ["Evaluate State After Initial Sync"] = "No",
  ["Pause Minutes"] = "60",
  ["Link Credential Backup"] = "",
}

dofile("drivers/smartbuildos-system-link/driver.lua")

for _, p in ipairs({
  "Driver Status",
  "Driver Version",
  "Installed Version",
  "License Status",
  "License Source",
  "License State",
  "Subscription Tier",
  "SmartBuildOS Company",
  "Local System Name",
  "Linked System Name",
  "Link Authorization",
  "Relay Connection",
  "Peer Status",
  "Remote System State",
  "Sync Status",
  "Last Sync",
  "Last Heartbeat",
  "Local Variables Created",
  "Remote Variables Monitored",
  "Pending Updates",
  "Pending Requests",
  "Measured Latency",
  "Last Remote Command",
  "Command Suspension",
  "Schema Revision",
  "Last Error",
  "Selected Item Details",
}) do
  Properties[p] = Properties[p] or ""
end

local function fired(id)
  local n = 0
  for _, e in ipairs(firedEvents) do
    if e == id then
      n = n + 1
    end
  end
  return n
end
local function lastSent(command)
  for i = #sent, 1, -1 do
    if sent[i].command == command then
      return sent[i]
    end
  end
  return nil
end

print("\n[1] init without a link")
OnDriverInit()
OnDriverLateInit()
check("driver online", Properties["Driver Status"] == "Online", Properties["Driver Status"])
check(
  "not provisioned yet",
  Properties["Link Authorization"]:match("Not provisioned"),
  Properties["Link Authorization"]
)
advance(3100)
local ask = lastSent("SBOS_LINK_PROVISION_REQUEST")
check(
  "asked the exact-filename Agent (900, not insights 901)",
  ask ~= nil and ask.id == 900 and ask.params.protocol_max == "1",
  ask and ask.id
)
check("licence SDK registered through the Agent", lastSent("SBOS_REGISTER_DRIVER") ~= nil)

print("\n[1b] the Agent's refusal stays readable and is retried")
local askedBefore = #sent
EC.SBOS_LINK_PROVISION({ request_id = ask.params.request_id, error = "HTTP 404" })
advance(2500) -- two status repaints
check(
  "Link Authorization keeps the Agent's answer, not the generic 'Not provisioned'",
  Properties["Link Authorization"] == "Agent: HTTP 404",
  Properties["Link Authorization"]
)
check("Last Error says the same", Properties["Last Error"] == "Agent: HTTP 404", Properties["Last Error"])
advance(61 * 1000)
local again = lastSent("SBOS_LINK_PROVISION_REQUEST")
check(
  "asked the Agent again after the retry interval",
  again ~= nil and again.params.request_id ~= ask.params.request_id and #sent > askedBefore,
  again and again.params.request_id
)
ask = again

print("\n[2] provisioning answer and first sync")
EC.SBOS_LINK_PROVISION({ request_id = "wrong", info = "{}" })
check("answer with the wrong request id is ignored", gEngine.link == nil)
local info = {
  endpoint_id = "ep-ca",
  link_id = "L",
  generation = 1,
  role = "a",
  namespace = "California",
  alias = "California Home",
  peer = { id = "ep-ny", namespace = "NewYork", alias = "New York Home" },
  credential = "sbosl1.8f7f4a3e-0000-4000-8000-c0ffee000011.1.8f7f4a3e-0000-4000-8000-c0ffee000022.aa",
  relay_url = "https://app.smartbuildos.io/api/system-link/relay/sync",
  realtime = { url = "https://x.supabase.co", key = "anon", channel = "syslink:ep-ca" },
  protocol = 1,
  link_state = "approved",
}
EC.SBOS_LINK_PROVISION({ request_id = ask.params.request_id, info = JSON:encode(info) })
check("provisioned", gEngine.link ~= nil and gEngine.link.endpoint == "ep-ca")
check(
  "credential stored encrypted and mirrored to the hidden backup",
  persisted["sl_credential"] ~= nil and Properties["Link Credential Backup"]:find("sbosl1") ~= nil
)
advance(200)
check(
  "first sync posted with hello and bearer",
  #relay.calls >= 1 and relay.calls[1].data.hello ~= nil and relay.calls[1].headers.Authorization:find("^Bearer sbosl1")
)
check("synced after the first round trip", gEngine:isSynced(), gEngine.reconcile.phase)
check("Initial Sync Complete fired, Link Connected fired", fired(6) == 1 and fired(1) == 1)
check(
  "mirror NewYork.Occupied created read-only with the snapshot value",
  variables["NewYork.Occupied"] == "1" and varMeta["NewYork.Occupied"].readOnly == true
)
check("no live-change event from the snapshot", fired(7) == 0)
check(
  "request slot variables exist under the local namespace",
  varMeta["California.Request_1_Status"] ~= nil
    and varMeta["California.Request_2_Status"] ~= nil
    and varMeta["California.Request_3_Status"] == nil
)
advance(1000)
check(
  "status properties painted",
  Properties["Linked System Name"] == "New York Home"
    and Properties["Relay Connection"]:match("^connected") ~= nil
    and Properties["Remote System State"]:match("^Ready"),
  Properties["Remote System State"]
)

print("\n[3] Composer: create, set, mirror refusal, commands")
Properties["New Item Name"] = "Away"
Properties["New Item Type"] = "BOOLEAN"
Properties["New Item Initial Value"] = "false"
EC.CREATE_SHARED_ITEM()
check(
  "owned variable created writable",
  varMeta["California.Away"] ~= nil
    and varMeta["California.Away"].readOnly == false
    and variables["California.Away"] == "0"
)
check("selected item list refreshed", Properties["Selected Item__list"]:find("California.Away") ~= nil)
advance(200)
check("schema and state published; relay holds the item", relay.items[gEngine:findByName("Away").id] ~= nil)
EC.Set_Local_Boolean({ ITEM = "Away", VALUE = "True" })
check("programming command sets the owned variable", variables["California.Away"] == "1")
-- Composer's native "variable = value" programming: Director writes the
-- variable and calls OnVariableChanged. It must publish exactly like the
-- Set Local command, and the driver's own echo must publish nothing.
Variables = Variables or variables -- Director's table of this driver's variables
local awayId = gEngine:findByName("Away").id
advance(200)
local revBefore = gEngine.values[awayId].rev
variables["California.Away"] = "0"
OnVariableChanged("California.Away")
advance(200)
check(
  "native variable write publishes the owned item",
  gEngine.values[awayId].tv.v == false and gEngine.values[awayId].rev == revBefore + 1,
  tostring(gEngine.values[awayId].rev)
)
variables["California.Away"] = "0"
OnVariableChanged("California.Away")
advance(200)
check("the echo of the same value publishes nothing", gEngine.values[awayId].rev == revBefore + 1)
check("mirrors get no native-write handler", OVC["NewYork.Occupied"] == nil)
EC.Set_Local_Boolean({ ITEM = "NewYork.Occupied", VALUE = "False" })
check(
  "programming cannot write a mirror",
  variables["NewYork.Occupied"] == "1" and Properties["Last Error"]:find("read%-only") ~= nil,
  Properties["Last Error"]
)
Properties["New Item Name"] = "Mode"
Properties["New Item Type"] = "CHOICE"
Properties["New Item Allowed Values"] = "Home, Away, Vacation"
Properties["New Item Initial Value"] = "Home"
EC.CREATE_SHARED_ITEM()
EC.Set_Local_Choice({ ITEM = "Mode", VALUE = "Party" })
check(
  "choice refuses a value outside the allowed list",
  variables["California.Mode"] == "Home" and Properties["Last Error"]:find("allowed") ~= nil,
  Properties["Last Error"]
)
Properties["Selected Item"] = "California.Mode"
Properties["Filter Debounce Seconds"] = "5"
EC.APPLY_FILTER_TO_SELECTED_ITEM()
check(
  "filter applied to the selected item",
  gEngine:findByName("Mode").filter and gEngine:findByName("Mode").filter.debounce_s == 5
)

print("\n[4] conditionals and events")
check("REMOTE_READY true", TC.REMOTE_READY() == true)
check("LINK_SYNCED true", TC.LINK_SYNCED() == true)
check("COMMANDS_PERMITTED true", TC.COMMANDS_PERMITTED() == true)
check("ITEM_CURRENT on a mirror", TC.ITEM_CURRENT(nil, { VALUE = "NewYork.Occupied", LOGIC = "EQUAL" }) == true)
check(
  "ITEM_CURRENT NOT_EQUAL inverts",
  TC.ITEM_CURRENT(nil, { VALUE = "NewYork.Occupied", LOGIC = "NOT_EQUAL" }) == false
)
EC.Emit_Named_Event({ EVENT = "Doorbell", PAYLOAD = "front", TTL = "30" })
advance(200)
local lastCall = relay.calls[#relay.calls]
local sawEvent = false
for _, env in ipairs(lastCall.data.outbound or {}) do
  if env.t == "event" and env.body.def == "Doorbell" then
    sawEvent = true
  end
end
check("named event went out with its payload and TTL", sawEvent)
relay.inbound = {
  {
    v = 1,
    t = "request",
    id = "req-0001",
    link = "L",
    ep = "ep-ny",
    gen = 1,
    seq = 50,
    ts = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    exp = clock.now + 60000,
    body = { routine = "Prepare_Home", payload = "guests=2" },
  },
}
gEngine.needSnapshot = false
EC.REFRESH_LINK()
advance(200)
check(
  "inbound request lands in slot 1 and fires Request Received",
  variables["California.Request_1_Routine"] == "Prepare_Home" and fired(11) == 1,
  variables["California.Request_1_Routine"]
)
check("REQUEST_STATUS conditional reads the slot", TC.REQUEST_STATUS(nil, { VALUE = "1 delivered" }) == true)
EC.Report_Request_Success({ SLOT = "1", RESULT = "done" })
advance(200)
local sawUpdate = false
for _, env in ipairs(relay.calls[#relay.calls].data.outbound or {}) do
  if env.t == "request_update" and env.body.status == "completed" and env.body.request_id == "req-0001" then
    sawUpdate = true
  end
end
check("success report travels as a correlated request_update", sawUpdate)
check(
  "slot released after the final report",
  TC.REQUEST_STATUS(nil, { VALUE = "1 completed" }) == true and gEngine.requests.slots[1] == false
)

print("\n[4b] exports: owner watches a light, publishes fields, executes remote commands")
local watched = {}
function C4:GetDeviceVariables(id)
  if id == 41 then
    return { ["1000"] = { name = "LIGHT_STATE", value = "1" }, ["1001"] = { name = "Brightness Percent", value = "55" } }
  end
  return {}
end
function C4:RegisterVariableListener(id, varId)
  watched[#watched + 1] = { id = id, varId = varId }
  return true
end
function C4:UnregisterVariableListener() end
function C4:GetDeviceDisplayName(id)
  return "device " .. tostring(id)
end
function C4:GetDeviceData(id, key)
  if key == "name" then
    return "Porch Light"
  end
end
EC.Export_Device({
  DEVICE = "41",
  NAME = "Porch_Light",
  KIND = "light",
  CONTROL = "Control allowed",
  OPS = "on,off,set_level",
})
check(
  "export created two owned items",
  gEngine:findByName("Porch_Light_On") ~= nil and gEngine:findByName("Porch_Light_Level") ~= nil,
  Properties["Last Error"]
)
check("both source variables watched", #watched == 2 and watched[1].id == 41)
check(
  "initial values published from the device",
  variables["California.Porch_Light_On"] == "1" and variables["California.Porch_Light_Level"] == "55",
  tostring(variables["California.Porch_Light_Level"])
)
OnWatchedVariableChanged(41, 1001, "20")
check("variable listener drives the field", variables["California.Porch_Light_Level"] == "20")
local exp
for _, e in pairs(gExports) do
  exp = e
end
check(
  "companion metadata carries no local device id",
  exp
    and gEngine:findByName("Porch_Light_Level").companion.device_id == nil
    and gEngine:findByName("Porch_Light_Level").companion.name == "Porch_Light"
)
sent = {}
local okCmd, why =
  OnSystemLinkCommand({ routine = "light.set_level", target = exp.id, params = { level = 70, time_ms = 500 } }, "cmd-1")
check(
  "remote command executes RAMP_TO_LEVEL on the real device",
  okCmd
    and lastSent("RAMP_TO_LEVEL")
    and lastSent("RAMP_TO_LEVEL").id == 41
    and lastSent("RAMP_TO_LEVEL").params.LEVEL == 70,
  why
)
check("variable NOT written by the command (feedback only)", variables["California.Porch_Light_Level"] == "20")
EC.Set_Export_Schedule({ NAME = "Porch_Light", DAYS = "1", FROM = "00:00", TO = "00:01" })
local okSched, whySched = OnSystemLinkCommand({ routine = "light.on", target = exp.id }, "cmd-2")
check("schedule refuses outside the window", not okSched and tostring(whySched):match("schedule"), whySched)
EC.Clear_Export_Schedule({ NAME = "Porch_Light" })
check(
  "thermostat export refused without the gated feature",
  (function()
    EC.Export_Device({ DEVICE = "42", NAME = "Hall_Stat", KIND = "thermostat", CONTROL = "Control allowed" })
    return gEngine:findByName("Hall_Stat_Temperature") == nil and Properties["Last Error"]:match("THERMOSTAT")
  end)(),
  Properties["Last Error"]
)
-- companion handshake on the PEER side: pretend we mirror an export
gEngine.registry.items["ny-occ"].companion =
  { id = "nyx", name = "Guest_Lamp", kind = "light", control = true, ops = { "on", "off" }, field = "On" }
sent = {}
EC.SBOS_LINK_COMPANION_HELLO({ requester = "777", kind = "light", export = "Guest_Lamp" })
check(
  "companion receives the export list and a state push",
  lastSent("SBOS_LINK_COMPANION_EXPORTS")
    and JSON:decode(lastSent("SBOS_LINK_COMPANION_EXPORTS").params.exports)[1].name == "Guest_Lamp"
    and lastSent("SBOS_LINK_COMPANION_STATE") ~= nil
)
EC.SBOS_LINK_COMPANION_CONTROL({ requester = "777", export = "Guest_Lamp", op = "on", params = "{}" })
check(
  "companion control becomes an outbound command and an accepted result",
  lastSent("SBOS_LINK_COMPANION_RESULT").params.status == "accepted"
    and (function()
      for _, env in ipairs(gEngine.pending) do
        if env.t == "command" and env.body.routine == "light.on" then
          return true
        end
      end
    end)(),
  lastSent("SBOS_LINK_COMPANION_RESULT").params.reason
)
EC.Remove_Export({ NAME = "Porch_Light" })
check("remove export tombstones its items", gEngine:findByName("Porch_Light_On") == nil)

print("\n[5] pause, 401 re-provision, forget")
EC.Pause_Remote_Commands({ MINUTES = "1" })
check("local pause suspends commands and fires Commands Paused", TC.COMMANDS_PERMITTED() == false and fired(18) == 1)
check("state still flows while paused", select(1, gEngine:setLocal("Away", false)) == true)
advance(61 * 1000)
check("pause expires on its own", TC.COMMANDS_PERMITTED() == true and fired(19) >= 1)
relay.nextError = { code = 401, body = "{}" }
sent = {}
EC.REFRESH_LINK()
advance(200)
advance(5100)
check(
  "401 → Link Disconnected and a fresh provisioning request",
  fired(2) >= 1 and lastSent("SBOS_LINK_PROVISION_REQUEST") ~= nil
)
EC.FORGET_LINK()
check(
  "forget clears the credential and backup but keeps definitions",
  persisted["sl_credential"] == nil
    and Properties["Link Credential Backup"] == ""
    and gEngine.registry.items[gEngine:findByName("Away").id] ~= nil
)

print("\n[6] restart restores variables in creation order")
local orderBefore = {}
for i, n in ipairs(varOrder) do
  orderBefore[i] = n
end
varMeta, varOrder, variables = {}, {}, {}
OnDriverInit()
check(
  "same variables, same order",
  #varOrder == #orderBefore and varOrder[1] == orderBefore[1] and varOrder[#varOrder] == orderBefore[#orderBefore],
  #varOrder .. " vs " .. #orderBefore
)

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
