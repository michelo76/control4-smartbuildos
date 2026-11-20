-- The AI Core property of the four UniFi Protect child drivers (brief D7b,
-- ruling 20): sbos.aipresence only, zero frames, the value follows AI Core
-- in and out, and the gateway's PROTECT_STATE pushes are the bounded KI-42
-- re-check. Shared checks: test/aicore_child_checks.lua. The fakes are the
-- ones test/test_unifi_protect_children.lua uses.
-- Run from the driver root: make test

local K = require("aicore_child_checks")

package.preload["cloud-client-byte"] = function()
  return {}
end
local store = {}
package.preload["lib.persist"] = function()
  return {
    get = function(_, key, default)
      local value = store[key]
      if value == nil then
        return default
      end
      return value
    end,
    set = function(_, key, value)
      store[key] = value
    end,
    delete = function(_, key)
      store[key] = nil
    end,
  }
end

C4 = C4 or {}
require("c4_shim")

function C4:UpdateProperty(name, value)
  if Properties[name] ~= nil then
    Properties[name] = value
  end
end
function C4:FireEvent() end
function C4:SetVariable() end
function C4:GetVersionInfo()
  return { version = "4.0.0" }
end
function C4:GetDevices()
  return { [900] = { deviceName = "Gateway", driverFileName = "unifi-protect.c4z" } }
end
function C4:GetDriverConfigInfo(key)
  return ({ model = "UniFi Protect Child", version = "1.0.0", minimum_os_version = "3.3.2" })[key]
end
K.install()

local GATEWAY = 1

for _, dir in ipairs({
  "unifi-protect-camera",
  "unifi-protect-light",
  "unifi-protect-sensor",
  "unifi-protect-viewport",
}) do
  K.child({
    dir = dir,
    expect = "Installed — reports through UniFi Protect Gateway (SBOS)",
    load = function()
      store = {}
      RFP, EC, OPC, TC, OBC = {}, {}, {}, {}, {}
      Properties = K.properties(dir)
      dofile("drivers/" .. dir .. "/driver.lua")
      OnDriverInit()
      OnDriverLateInit()
    end,
    inbound = function()
      ReceivedFromProxy(GATEWAY, "PROTECT_STATE", { id = "x-1", state = "CONNECTED" })
    end,
  })
end

K.finish()
