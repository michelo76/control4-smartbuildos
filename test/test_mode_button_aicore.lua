-- The AI Core property of the Mode Button (a child of Mode Composer; brief
-- D7b, ruling 20): sbos.aipresence only (with its file named, since this
-- driver sets neither DC_FILENAME nor DRIVER_FILENAMES), zero frames, the
-- value follows AI Core in and out, and the manager's MC_STATE pushes are
-- the bounded KI-42 re-check. Shared checks: test/aicore_child_checks.lua.
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
  return { [400] = { driverFileName = "smartbuildos-mode-composer.c4z" } }
end
function C4:UpdateProperty(name, value)
  if Properties[name] ~= nil then
    Properties[name] = value
  end
end
function C4:GetDriverConfigInfo(key)
  return ({ version = "20261118.1" })[key]
end
function C4:AddEvent() end
function C4:FireEvent() end
K.install()

DRIVER_FILENAMES, DC_FILENAME = nil, nil
K.child({
  dir = "smartbuildos-mode-button",
  expect = "Installed — reports through SmartBuildOS Mode Composer",
  load = function()
    store = {}
    RFP, EC, OPC, TC, OBC = {}, {}, {}, {}, {}
    Properties = K.properties("smartbuildos-mode-button")
    dofile("drivers/smartbuildos-mode-button/driver.lua")
    OnDriverInit()
    OnDriverLateInit()
  end,
  inbound = function()
    EC.MC_STATE({ modes = "[]" })
  end,
})

K.finish()
