-- UniFi Protect gateway reports to AI Core (sbos.aireport, START mode;
-- brief D7a). A MULTI-INSTANCE root: every gateway registers as
-- unifi_protect under its own device id, non-singleton.
--
-- The real driver.lua under the shim (set up as test_unifi_protect.lua
-- does: a fake lib.http console), the REAL Agent registry and bus and a
-- fake AI Core answering through AI Core's REAL validator
-- (test/aicore_reporter_harness.lua); the shared lifecycle checks are
-- test/aicore_rollout_checks.lua. Driver-specific: HEALTH AND COUNTS ONLY.
-- No camera, device or console name, address, key or webhook token in any
-- report; the console offline / online diagnostics; a second instance.
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

local consoleUp = true
local CAMERAS = {
  { id = "cam-front", name = "Whitfield Front Door", mac = "60223263A4D0", state = "CONNECTED" },
  { id = "cam-drive", name = "Driveway", mac = "60223263A4D1", state = "DISCONNECTED" },
}
local routes = {
  { match = "/v1/meta/info", body = { applicationVersion = "6.2.83" } },
  { match = "/v1/nvrs", body = { id = "nvr-1", modelKey = "nvr", name = "Dream Machine" } },
  { match = "/v1/cameras", body = CAMERAS },
  { match = "/v1/lights", body = {} },
  { match = "/v1/sensors", body = { { id = "sen-1", name = "Garage", state = "CONNECTED" } } },
  { match = "/v1/chimes", body = {} },
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
      if consoleUp then
        onOk({ url = url, code = 200, headers = {}, body = body })
      elseif onErr then
        onErr({ url = url, error = "timeout" })
      end
    end,
  }
end
package.preload["lib.http"] = function()
  local function verb(method)
    return function(_, url)
      return fakeRequest(method, url)
    end
  end
  return { get = verb("GET"), post = verb("POST"), put = verb("PUT"), patch = verb("PATCH"), delete = verb("DELETE") }
end
package.preload["drivers-common-public.module.websocket"] = function()
  local FakeWs = {}
  FakeWs.__index = FakeWs
  function FakeWs:new(url)
    return setmetatable({ url = url }, FakeWs)
  end
  for _, m in ipairs({ "SetProcessMessageFunction", "SetEstablishedFunction", "SetClosedByRemoteFunction", "SetOfflineFunction", "Start" }) do
    FakeWs[m] = function(self)
      return self
    end
  end
  function FakeWs:delete() end
  return FakeWs
end
C4.GetDriverConfigInfo = function(_, key)
  if key == "minimum_os_version" then
    return "3.3.2"
  elseif key == "name" then
    return "UniFi Protect Gateway"
  end
  return "20261118.000001"
end
C4.GetDeviceData = function()
  return "UniFi Protect"
end
C4.GetDevices = function()
  return {}
end
C4.SendToProxy = function() end
C4.AddDynamicBinding = function() end
C4.RemoveDynamicBinding = function() end
C4.GetBoundConsumerDevices = function() end
C4.SetConditionalState = function() end
C4.CreateServer = function() end
C4.DestroyServer = function() end
C4.ServerSend = function() end
C4.ServerCloseClient = function() end

R.loadProperties("unifi-protect")
Properties["Console Address"] = "https://192.168.4.1"
Properties["Event Stream"] = "Off"
Properties["Snapshot Relay"] = "Off"
Properties["Webhook Token"] = "webhooksecret77"
R.watchPaints()
H.install({ selfId = SELF, file = "unifi-protect.c4z" })
dofile("drivers/unifi-protect/driver.lua")

R.lifecycle({
  H = H,
  moduleId = "unifi_protect",
  file = "unifi-protect.c4z",
  sku = "SBOS_UNIFI_PROTECT",
  mode = "start",
  multiInstance = true,
  activity = function()
    Properties["API Key"] = "secret-key-123"
    OnPropertyChanged("API Key")
    advance(61000)
  end,
  describe = function(d)
    local classes = {}
    for _, c in ipairs(d.controls) do
      classes[#classes + 1] = c.id .. "=" .. c.class
    end
    check(
      "describe: cameras, floodlights, sensors, chimes",
      table.concat(classes, ",") == "cameras=security,floodlights=light,sensors=sensor,chimes=security",
      table.concat(classes, ",")
    )
    check("describe: no query declared", #d.queries == 0)
  end,
  state = function(facts)
    check(
      "state: connected, devices and online counts per kind",
      facts.configured == true
        and facts.connected == true
        and facts.cameras == 2
        and facts.cameras_online == 1
        and facts.sensors == 1
        and facts.sensors_online == 1
        and facts.lights == 0,
      JSON:encode(facts)
    )
  end,
  forbid = { "Whitfield", "Driveway", "Garage", "Dream Machine", "192.168", "secret-key", "webhooksecret77", "60223263" },
})

print("[5] the console offline / online diagnostics")
OnDriverInit()
OnDriverLateInit()
H.aiRegister()
H.pushDirectory()
local d0 = #H.reports("diagnostic")
consoleUp = false
advance(5 * 60000)
local dg = H.reports("diagnostic")
local last = dg[#dg] and dg[#dg].args
check(
  "the console stops answering: console.offline (warning), as the driver's own NVR Offline",
  #dg > d0 and last.code == "console.offline" and last.severity == "warning",
  last and JSON:encode(last)
)
check("…the state follows (connected false)", H.reports("state")[#H.reports("state")].args.facts.connected == false)
consoleUp = true
advance(5 * 60000)
dg = H.reports("diagnostic")
last = dg[#dg] and dg[#dg].args
check("it answers again: console.online (info)", last ~= nil and last.code == "console.online" and last.severity == "info")
check("every report valid for AI Core", H.allValid(), select(2, H.allValid()))

R.finish()
