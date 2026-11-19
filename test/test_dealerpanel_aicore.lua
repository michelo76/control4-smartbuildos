-- Dealer Settings reports to AI Core (sbos.aireport, START mode; brief D7a).
--
-- The real driver.lua under the shim (set up as test_dealerpanel_driver.lua
-- does), the REAL Agent registry and bus and a fake AI Core answering
-- through AI Core's REAL validator (test/aicore_reporter_harness.lua); the
-- shared lifecycle checks are test/aicore_rollout_checks.lua.
-- Driver-specific: describe, the state (counts and flags; never setting
-- names, values or the PIN), the panel-locked diagnostic.
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
      if
        t.at <= target and (bestAt == nil or t.at < bestAt or (t.at == bestAt and tostring(id) < tostring(bestId)))
      then
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

local proxySends = {}
local serverSent = {}
local FAKE_APP_HTML = "<title>Dealer Settings</title>" .. string.rep("<!-- app -->", 120)
C4.GetDevices = function()
  return { [12] = { deviceName = "Controller", driverFileName = "control4_core3.c4i" } }
end
C4.GetNetworkBindingsByDevice = function()
  return {}
end
C4.GetBindingsByDevice = function()
  return { bindings = { { bindingid = 6001, info = { addr = "192.168.7.20" } } } }
end
C4.GetDriverConfigInfo = function(_, key)
  if key == "minimum_os_version" then
    return "3.3.2"
  elseif key == "name" then
    return "SmartBuildOS Dealer Settings"
  end
  return "20261118.000001"
end
C4.SendToProxy = function(_, binding, command, params)
  proxySends[#proxySends + 1] = { binding = binding, command = command, params = params }
end
C4.FileSetDir = function() end
C4.FileExists = function(_, path)
  return path == "www/app/index.html"
end
C4.FileOpen = function(_, path)
  return path == "www/app/index.html" and 7 or -1
end
C4.FileGetSize = function(_, handle)
  return handle == 7 and #FAKE_APP_HTML or 0
end
C4.FileSetPos = function() end
C4.FileRead = function(_, handle)
  return handle == 7 and FAKE_APP_HTML or ""
end
C4.FileClose = function() end
C4.CreateServer = function()
  return true
end
C4.ServerSend = function(_, handle, data)
  serverSent[#serverSent + 1] = { handle = handle, data = data }
end
C4.ServerCloseClient = function() end
C4.DestroyServer = function() end
-- The relay answers its own /ping on the controller's address (lib.relayhost).
require("lib.relayhost").get = function(url, done)
  done(url:match("^http://192%.168%.7%.20:") ~= nil, '{"ok":true,"service":"dealer-panel"}')
end

R.loadProperties("smartbuildos-dealer-panel")
Properties["Setting 1 Name"] = "Hall timeout"
Properties["Setting 1 Type"] = "Number"
Properties["Setting 1 Value"] = "120"
Properties["Setting 1 Options"] = "0..600"
Properties["Setting 2 Name"] = "Night mode"
Properties["Setting 2 Type"] = "Toggle"
Properties["Setting 2 Value"] = "Off"
Properties["Dealer PIN"] = "4321"
R.watchPaints()
H.install({ selfId = SELF, file = "smartbuildos-dealer-panel.c4z" })
dofile("drivers/smartbuildos-dealer-panel/driver.lua")

local function relay(method, path, body)
  body = body or ""
  OnServerDataIn(
    100,
    method .. " " .. path .. " HTTP/1.1\r\nContent-Length: " .. #body .. "\r\n\r\n" .. body,
    nil,
    nil,
    "dealerpanel-ui-relay"
  )
end
local function token()
  local url = proxySends[#proxySends] and proxySends[#proxySends].params.url or ""
  return url:match("[?&]k=(%w+)") or ""
end

R.lifecycle({
  H = H,
  moduleId = "dealer_panel",
  file = "smartbuildos-dealer-panel.c4z",
  sku = "SBOS_DEALER_PANEL",
  mode = "start",
  activity = function()
    EC.SET_SETTING({ NAME = "Hall timeout", VALUE = "150" })
    advance(61000)
  end,
  describe = function(d)
    check(
      "describe: the dealer settings (class other)",
      #d.controls == 1 and d.controls[1].id == "dealer_settings" and d.controls[1].class == "other"
    )
    check("describe: no query declared", #d.queries == 0)
  end,
  state = function(facts)
    check(
      "state: counts and flags",
      facts.settings_configured == 2 and facts.writable == true and facts.read_only == false and facts.locked == false,
      JSON:encode(facts)
    )
  end,
  forbid = { "4321", "Hall timeout", "Night mode", "150" },
})

print("[5] the panel-locked diagnostic")
OnDriverInit()
OnDriverLateInit()
H.aiRegister()
H.pushDirectory()
local before = #H.reports("diagnostic")
for _ = 1, 5 do
  relay("POST", "/set?k=" .. token(), '{"name":"Hall timeout","value":"10","pin":"nope"}')
end
local dg = H.reports("diagnostic")
local last = dg[#dg] and dg[#dg].args
check(
  "five wrong PINs: panel.locked (warning), as the driver's own Panel Locked",
  #dg == before + 1 and last.code == "panel.locked" and last.severity == "warning",
  last and JSON:encode(last)
)
check("the state follows (locked)", H.reports("state")[#H.reports("state")].args.facts.locked == true)
local everything = JSON:encode(H.reports())
check(
  "no PIN attempt in any report",
  everything:find("nope", 1, true) == nil and everything:find("4321", 1, true) == nil
)
check("every report valid for AI Core", H.allValid(), select(2, H.allValid()))

R.finish()
