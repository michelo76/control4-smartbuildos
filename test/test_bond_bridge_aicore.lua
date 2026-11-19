-- Bond Bridge gateway reports to AI Core (sbos.aireport, START mode; brief
-- D7a). A MULTI-INSTANCE root: every gateway registers as bond_bridge under
-- its own device id, non-singleton.
--
-- The real driver.lua under the shim (set up as test_bond_bridge.lua does:
-- a fake lib.http Bond), the REAL Agent registry and bus and a fake AI Core
-- answering through AI Core's REAL validator
-- (test/aicore_reporter_harness.lua); the shared lifecycle checks are
-- test/aicore_rollout_checks.lua. Driver-specific: describe, the
-- connection / inventory counts (never the address, Bond id, token or
-- device names), the Bond offline / online diagnostics, a second instance.
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

local bondUp = true
local routes = {
  { match = "/v2/sys/version", body = { bondid = "ZZBL12345", make = "Olibra", model = "BD-1000", fw_ver = "v3.5.0" } },
  { match = "/v2/devices/fan1/state", body = { ["_"] = "s-fan-1", power = 1, speed = 3, light = 0 } },
  { match = "/v2/devices/fan1/properties", body = { ["_"] = "p-fan", max_speed = 6 } },
  {
    match = "/v2/devices/fan1",
    body = { name = "Whitfield Master Fan", type = "CF", location = "Master Bedroom", actions = { "TurnOn", "TurnOff", "SetSpeed" } },
  },
  { match = "/v2/scenes", body = { ["_"] = "sc-0" } },
  { match = "/v2/sidekicks", body = { ["_"] = "sk-0" } },
  { match = "/v2/devices", body = { ["_"] = "root-1", fan1 = { ["_"] = "d1" } } },
}
local function fakeRequest(_, url)
  local body = {}
  for _, r in ipairs(routes) do
    if url:find(r.match, 1, true) then
      body = r.body
      break
    end
  end
  return {
    next = function(_, onOk, onErr)
      if bondUp then
        onOk({ url = url, code = 200, headers = {}, body = body })
      elseif onErr then
        onErr({ url = url, error = "timeout" })
      end
    end,
  }
end
package.preload["lib.http"] = function()
  return {
    request = fakeRequest,
    get = function(_, url)
      return fakeRequest("GET", url)
    end,
    put = function(_, url)
      return fakeRequest("PUT", url)
    end,
    patch = function(_, url)
      return fakeRequest("PATCH", url)
    end,
  }
end
C4.GetDriverConfigInfo = function(_, key)
  if key == "minimum_os_version" then
    return "3.2.0"
  elseif key == "name" then
    return "Bond Bridge Gateway (SBOS)"
  end
  return "20261118.000001"
end
C4.GetDeviceData = function()
  return "Bond Bridge"
end
C4.SendToProxy = function() end
C4.AddDynamicBinding = function() end
C4.RemoveDynamicBinding = function() end
C4.GetBoundConsumerDevices = function() end
C4.GetBindingAddress = function() end
C4.CreateNetworkConnection = function() end
C4.NetPortOptions = function() end
C4.NetConnect = function() end
C4.NetDisconnect = function() end
C4.SendToNetwork = function() end
C4.SetConditionalState = function() end
C4.Bind = function() end
C4.RenameDevice = function() end

R.loadProperties("bond-bridge")
Properties["Push Updates"] = "Off"
Properties["Bond Address"] = "192.168.1.50"
R.watchPaints()
H.install({ selfId = SELF, file = "bond-bridge.c4z" })
dofile("drivers/bond-bridge/driver.lua")

R.lifecycle({
  H = H,
  moduleId = "bond_bridge",
  file = "bond-bridge.c4z",
  sku = "SBOS_BOND",
  mode = "start",
  multiInstance = true,
  activity = function()
    Properties["Local Token"] = "deadbeef01"
    OnPropertyChanged("Local Token")
    advance(61000)
  end,
  describe = function(d)
    local classes = {}
    for _, c in ipairs(d.controls) do
      classes[#classes + 1] = c.id .. "=" .. c.class
    end
    check(
      "describe: fans, shades, fireplaces, fan lights",
      table.concat(classes, ",") == "fans=climate,shades=shade,fireplaces=climate,lights=light",
      table.concat(classes, ",")
    )
    check("describe: no query declared", #d.queries == 0)
  end,
  state = function(facts)
    check(
      "state: configured, connected, one device, no scenes",
      facts.configured == true and facts.connected == true and facts.devices == 1 and facts.scenes == 0,
      JSON:encode(facts)
    )
  end,
  forbid = { "192.168", "ZZBL12345", "deadbeef", "Whitfield", "Master" },
})

print("[5] the Bond offline / online diagnostics")
OnDriverInit()
OnDriverLateInit()
H.aiRegister()
H.pushDirectory()
local d0 = #H.reports("diagnostic")
bondUp = false
advance(5 * 60000)
local dg = H.reports("diagnostic")
local last = dg[#dg] and dg[#dg].args
check(
  "the Bond stops answering: bond.offline (warning), as the driver's own Bond Offline",
  #dg > d0 and last.code == "bond.offline" and last.severity == "warning",
  last and JSON:encode(last)
)
check("…the state follows (connected false)", H.reports("state")[#H.reports("state")].args.facts.connected == false)
bondUp = true
advance(5 * 60000)
dg = H.reports("diagnostic")
last = dg[#dg] and dg[#dg].args
check("it answers again: bond.online (info)", last ~= nil and last.code == "bond.online" and last.severity == "info")
check("every report valid for AI Core", H.allValid(), select(2, H.allValid()))

R.finish()
