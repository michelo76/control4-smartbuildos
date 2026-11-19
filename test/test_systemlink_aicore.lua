-- System Link (bridge) reports to AI Core (sbos.aireport, START mode;
-- brief D7a).
--
-- The real driver.lua under the shim (set up as test_systemlink_driver.lua
-- does: a fake relay over lib.http, no websocket), the REAL Agent registry
-- and bus and a fake AI Core answering through AI Core's REAL validator
-- (test/aicore_reporter_harness.lua); the shared lifecycle checks are
-- test/aicore_rollout_checks.lua. Driver-specific: describe (class
-- network), the link state once provisioned (never the system names, the
-- credential or shared values), the link diagnostics.
-- Run from the driver root: make test

C4 = C4 or {}
require("c4_shim")
JSON = require("JSON")
local R = require("aicore_rollout_checks")
local H = require("aicore_reporter_harness")
local check = R.check

-- ── timers (a manual clock, as the driver's own test) ───────────────────────
local clock = { now = 0, timers = {} }
package.preload["drivers-common-public.global.timer"] = function()
  ONE_SECOND = 1000
  ONE_MINUTE = 60000
  ONE_HOUR = 3600000
  function SetTimer(id, ms, cb, repeating)
    clock.timers[id] = { at = clock.now + ms, cb = cb, every = repeating and ms or nil }
  end
  function CancelTimer(id)
    if type(id) == "string" then
      clock.timers[id] = nil
    end
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
      if t.at <= target and (bestAt == nil or t.at < bestAt or (t.at == bestAt and tostring(id) < tostring(bestId))) then
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
local realTime = os.time
local base = 1800000000
os.time = function(t)
  if t then
    return realTime(t)
  end
  return base + math.floor(clock.now / 1000)
end
package.preload["drivers-common-public.global.url"] = function()
  return true
end
package.preload["cloud-client-byte"] = function()
  return true
end
local persisted = {}
package.preload["lib.persist"] = function()
  local P = {}
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

local SELF = 12345
C4.GetDeviceID = function()
  return SELF
end
C4.FireEventByID = function() end
C4.FireEvent = function() end
C4.SetVariable = function() end
C4.AddVariable = function() end
C4.AddEvent = function() end
C4.GetVersionInfo = function()
  return { version = "4.2.0.0" }
end
C4.UpdateProperty = function() end

package.preload["drivers-common-public.module.websocket"] = function()
  local WS = {}
  WS.__index = WS
  function WS:new()
    return nil
  end
  return WS
end
local relay = { nextError = nil, seq = 0 }
package.preload["lib.http"] = function()
  return {
    post = function(_, _, data)
      return {
        next = function(_, resolved, rejected)
          if relay.nextError then
            local e = relay.nextError
            relay.nextError = nil
            rejected(e)
            return
          end
          local accepted = {}
          for _, env in ipairs(data.outbound or {}) do
            relay.seq = relay.seq + 1
            accepted[#accepted + 1] = { id = env.id, seq = relay.seq }
          end
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
                alias = "Whitfield Lake House",
                status = "active",
                last_heartbeat_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
              },
              accepted = accepted,
              rejected = {},
              inbound = {},
              next_seq = relay.seq,
              snapshot = (data.since_seq == 0 or data.snapshot) and {
                peer_items = {
                  { id = "ny-occ", name = "Occupied", type = "BOOLEAN", owner = "ep-ny", schema_rev = 0, order = 1 },
                },
                peer_state = { { id = "ny-occ", gen = 1, rev = 3, value = { s = "current", v = true }, seq = 1 } },
                own_committed = {},
                head_seq = relay.seq,
              } or nil,
            }),
          })
        end,
      }
    end,
  }
end
C4.GetDevices = function()
  return {}
end
C4.GetDriverConfigInfo = function(_, key)
  if key == "minimum_os_version" then
    return "3.3.2"
  elseif key == "name" then
    return "SmartBuildOS System Link"
  end
  return "20261118.000001"
end
C4.AddVariable = function()
  return true, 1000
end
C4.UpdatePropertyList = function() end
C4.GetTime = function()
  return clock.now
end
C4.GetTimeZone = function()
  return "America/Los_Angeles"
end
local uuidN = 0
C4.UUID = function()
  uuidN = uuidN + 1
  return string.format("8f7f4a3e-0000-4000-8000-%012d", uuidN)
end

R.loadProperties("smartbuildos-system-link")
Properties["Request Slots"] = "2"
R.watchPaints()
H.install({ selfId = SELF, file = "smartbuildos-system-link.c4z" })
dofile("drivers/smartbuildos-system-link/driver.lua")

local INFO = {
  endpoint_id = "ep-ca",
  link_id = "L",
  generation = 1,
  role = "a",
  namespace = "California",
  alias = "Whitfield Residence",
  peer = { id = "ep-ny", namespace = "NewYork", alias = "Whitfield Lake House" },
  credential = "sbosl1.8f7f4a3e-0000-4000-8000-c0ffee000011.1.8f7f4a3e-0000-4000-8000-c0ffee000022.aa",
  relay_url = "https://relay.example/api/system-link/relay/sync",
  realtime = { url = "https://rt.example", key = "anonkey", channel = "syslink:ep-ca" },
  protocol = 1,
  link_state = "approved",
}
local function provision()
  local ask
  for _, f in ipairs(H.frames) do
    if f.command == "SBOS_LINK_PROVISION_REQUEST" then
      ask = f
    end
  end
  if ask ~= nil then
    EC.SBOS_LINK_PROVISION({ request_id = ask.params.request_id, info = JSON:encode(INFO) })
  end
  return ask ~= nil
end

R.lifecycle({
  H = H,
  moduleId = "system_link",
  file = "smartbuildos-system-link.c4z",
  sku = "SBOS_SYSTEM_LINK",
  mode = "start",
  activity = function()
    if gEngine.link == nil then
      advance(3100)
      assert(provision(), "no provision request")
    end
    advance(2000)
  end,
  describe = function(d)
    check(
      "describe: the link (class network)",
      #d.controls == 1 and d.controls[1].id == "system_link" and d.controls[1].class == "network"
    )
    check("describe: no query declared", #d.queries == 0)
  end,
  state = function(facts)
    check(
      "state: linked, approved, connected, synced, counts",
      facts.linked == true
        and facts.link_authorization == "approved"
        and facts.relay_connection == "connected"
        and type(facts.peer_status) == "string"
        and type(facts.sync_status) == "string"
        and facts.remote_variables == 1
        and type(facts.pending_updates) == "number"
        and facts.commands_suspended == false,
      JSON:encode(facts)
    )
  end,
  forbid = { "Whitfield", "sbosl1", "c0ffee", "anonkey", "relay.example", "Occupied" },
})

print("[5] the link diagnostics")
OnDriverInit()
OnDriverLateInit()
H.aiRegister()
H.pushDirectory()
local function codes(from)
  local out = {}
  local dg = H.reports("diagnostic")
  for i = from + 1, #dg do
    out[#out + 1] = dg[i].args.code
  end
  return table.concat(out, ",")
end
local d0 = #H.reports("diagnostic")
advance(2000)
check("the stored link reconnects: link.connected (info)", codes(d0):find("link.connected", 1, true) ~= nil, codes(d0))
advance(61000) -- past the helper's 6-a-minute diagnostic budget
local d1 = #H.reports("diagnostic")
local firedIds = {}
C4.FireEventByID = function(_, id)
  firedIds[#firedIds + 1] = id
end
relay.nextError = { code = 401, body = "{}" } -- the relay refuses the credential
EC.REFRESH_LINK()
advance(200)
-- Exactly the engine's own fault events, mirrored: 1 Link Connected,
-- 2 Link Disconnected, 3 Peer Online, 4 Peer Offline, 20 Loop Suspended.
local MIRROR = { [1] = "link.connected", [2] = "link.disconnected", [3] = "peer.online", [4] = "peer.offline", [20] = "item.loop_suspended" }
local expected = {}
for _, id in ipairs(firedIds) do
  if MIRROR[id] then
    expected[#expected + 1] = MIRROR[id]
  end
end
check(
  "the relay refuses the link: each fault event the engine fired is one diagnostic, no more",
  #expected > 0 and codes(d1) == table.concat(expected, ","),
  codes(d1) .. " vs " .. table.concat(expected, ",")
)
check("no system name or credential in any report", JSON:encode(H.reports()):find("Whitfield", 1, true) == nil)
check("every report valid for AI Core", H.allValid(), select(2, H.allValid()))

R.finish()
