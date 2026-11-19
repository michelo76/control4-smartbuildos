-- The AI Core property of the nine Bond child drivers (brief D7b, ruling 20):
-- sbos.aipresence only, zero frames, the value follows AI Core in and out,
-- and the gateway's state pushes are the bounded KI-42 re-check
-- (src/bond/child.lua). Shared checks: test/aicore_child_checks.lua. The
-- fakes are the ones test/test_bond_children.lua uses.
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
JSON = JSON or require("JSON")

function C4:GetDevices()
  return { ["500"] = { driverFileName = "bond-bridge.c4z" } }
end
function C4:GetProxyDevices()
  return 9001
end
function C4:UpdateProperty(name, value)
  if Properties[name] ~= nil then
    Properties[name] = value
  end
end
function C4:GetDriverConfigInfo(key)
  return ({ model = "Bond Child", version = "1.0.0", minimum_os_version = "3.2.0" })[key]
end
function C4:GetVersionInfo()
  return { version = "4.0.0" }
end
function C4:FireEvent() end
function C4:AddEvent() end
function C4:SetConditionalState() end
function C4:SetVariable() end
function C4:AddVariable() end
function C4:RenameDevice() end
K.install()

local CHILDREN = {
  "bond-color-light",
  "bond-fan",
  "bond-fireplace",
  "bond-generic",
  "bond-heater",
  "bond-keypad",
  "bond-light",
  "bond-shade",
  "bond-weather",
}

for _, dir in ipairs(CHILDREN) do
  K.child({
    dir = dir,
    expect = "Installed — reports through Bond Bridge Gateway (SBOS)",
    load = function()
      store = {}
      package.loaded["bond.child"] = nil
      RFP, EC, OPC, TC, OBC = {}, {}, {}, {}, {}
      Properties = K.properties(dir)
      dofile("drivers/" .. dir .. "/driver.lua")
      OnDriverInit()
      OnDriverLateInit()
      -- The gateway's identity answer (so a later state push is ordinary).
      EC.BOND_DEVICE({
        id = "d1",
        fn = "X",
        name = "Test Device",
        type = "",
        location = "",
        actions_json = "[]",
        props_json = "{}",
        state_json = "{}",
      })
    end,
    inbound = function()
      EC.BOND_STATE({ id = "d1", state_json = "{}" })
    end,
  })
end

K.finish()
