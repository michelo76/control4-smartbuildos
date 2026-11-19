-- The AI Core property of the eleven System Link child drivers (brief D7b,
-- ruling 20). Ten companions get it from their shared base
-- src/systemlink/companiondriver.lua (the bridge's state pushes are the
-- bounded KI-42 re-check); the Export Light wires sbos.aipresence itself
-- (the bridge's export answers are its re-check). Shared checks:
-- test/aicore_child_checks.lua; the fakes are the ones
-- test/test_systemlink_companions.lua uses.
-- Run from the driver root: make test

local K = require("aicore_child_checks")

C4 = C4 or {}
require("c4_shim")
JSON = require("JSON")

package.preload["drivers-common-public.global.timer"] = function()
  ONE_SECOND = 1000
  function SetTimer() end
  function CancelTimer() end
  function KillAllTimers() end
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
  return P
end

function C4:GetDevices()
  return {
    [800] = { driverFileName = "smartbuildos-system-link.c4z" },
    [900] = { driverFileName = "smartbuildos.c4z" },
  }
end
function C4:FireEventByID() end
function C4:GetDeviceID()
  return 701
end
function C4:GetDriverConfigInfo(tag)
  if tag == "minimum_os_version" then
    return "3.3.2"
  end
  return "20261018.1"
end
function C4:GetVersionInfo()
  return { version = "3.3.2.1" }
end
function C4:UpdatePropertyList() end
function C4:UpdateProperty(name, value)
  Properties[name] = tostring(value)
end
function C4:AddVariable() end
function C4:SetVariable() end
K.install()

local EXPECT = "Installed — reports through SmartBuildOS System Link"

for _, kind in ipairs({
  "contact",
  "fan",
  "gate",
  "light",
  "lock",
  "media",
  "relay",
  "shade",
  "temperature",
  "thermostat",
}) do
  local dir = "smartbuildos-system-link-" .. kind
  K.child({
    dir = dir,
    expect = EXPECT,
    load = function()
      persisted = {}
      package.loaded["systemlink.companiondriver"] = nil
      package.loaded["systemlink.companion"] = nil
      RFP, EC, OPC, TC, OBC = {}, {}, {}, {}, {}
      Properties = K.properties(dir)
      dofile("drivers/" .. dir .. "/driver.lua")
      OnDriverInit()
      OnDriverLateInit()
      EC.SBOS_LINK_COMPANION_ASSIGN({ export = "Test_Export" })
    end,
    inbound = function()
      EC.SBOS_LINK_COMPANION_STATE({ export = "Test_Export", fields = "{}", fresh = "current", state = "Online" })
    end,
  })
end

K.child({
  dir = "smartbuildos-system-link-export-light",
  expect = EXPECT,
  load = function()
    persisted = {}
    package.loaded["systemlink.companion"] = nil
    RFP, EC, OPC, TC, OBC = {}, {}, {}, {}, {}
    Properties = K.properties("smartbuildos-system-link-export-light")
    dofile("drivers/smartbuildos-system-link-export-light/driver.lua")
    OnDriverInit()
    OnDriverLateInit()
  end,
  inbound = function()
    EC.SBOS_LINK_EXPORT_RESULT({ ok = "true", reason = "exported", name = "Test_Export" })
  end,
})

K.finish()
