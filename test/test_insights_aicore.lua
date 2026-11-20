-- The AI Core property of Home Insights (a child of the SmartBuildOS Agent;
-- brief D7b, ruling 20). Its root sends no reports, so the value is
-- "Installed — this driver does not report" or "Not installed". Insights
-- has no vendored handlers: no OSE table, no global SetTimer or
-- UpdateProperty, so sbos.aipresence paints through C4:UpdateProperty,
-- debounces on C4:SetTimer and gets Director's system events from the
-- driver's own OnSystemEvent. Proxy traffic and property changes are the
-- bounded KI-42 re-check. Shared checks: test/aicore_child_checks.lua.
-- Run from the driver root: make test

local K = require("aicore_child_checks")

C4 = C4 or {}
require("c4_shim")

-- What a driver without drivers-common-public sees.
SetTimer, CancelTimer, UpdateProperty, OSE, EC = nil, nil, nil, nil, nil

function C4:UpdateProperty(name, value)
  if Properties[name] ~= nil then
    Properties[name] = value
  end
end
function C4:GetDriverConfigInfo(key)
  return ({ version = "20261118.1" })[key]
end
function C4:GetDevices()
  return {}
end
local startupTimers = 0
function C4:SetTimer(ms, fn)
  if ms == 5000 then
    K.debounce = fn
  else
    startupTimers = startupTimers + 1
  end
  return { Cancel = function() end }
end
K.install()

K.child({
  dir = "smartbuildos-insights",
  expect = "Installed — this driver does not report",
  load = function()
    Properties = K.properties("smartbuildos-insights")
    Properties["URL"] = ""
    dofile("drivers/smartbuildos-insights/driver.lua")
    OnDriverInit()
    OnDriverLateInit()
  end,
  inbound = function()
    ReceivedFromProxy(5001, "TILE_SHOWN")
  end,
})

K.check(
  "no vendored SetTimer / UpdateProperty / OSE appeared",
  SetTimer == nil and UpdateProperty == nil and OSE == nil
)
K.check("the driver's own 60 s startup re-publish is still armed", startupTimers >= 1, startupTimers)
K.finish()
