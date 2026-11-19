-- The AI Core property of the four MQTT child drivers (brief D7b, ruling
-- 20): wired once in their shared base src/mqtt/childdriver.lua
-- (sbos.aipresence, started in its OnDriverLateInit, stopped in its
-- OnDriverDestroyed; the Broker's entity and message pushes are the bounded
-- KI-42 re-check). Shared checks: test/aicore_child_checks.lua, on the fake
-- Director of test/mqtt_harness.lua.
-- Run from the driver root: make test

local K = require("aicore_child_checks")
local H = dofile("test/mqtt_harness.lua")
local BROKER, SELF = 80, 92

for _, dir in ipairs({
  "smartbuildos-mqtt-contact",
  "smartbuildos-mqtt-light",
  "smartbuildos-mqtt-motion",
  "smartbuildos-mqtt-shade",
}) do
  H.new({
    driver = dir,
    self_id = SELF,
    devices = { [BROKER] = { deviceName = "MQTT Broker", driverFileName = "smartbuildos-mqtt-broker.c4z" } },
    names = { [SELF] = "Device" },
  })
  K.install()
  K.child({
    dir = dir,
    expect = "Installed — reports through SmartBuildOS MQTT Broker",
    load = function()
      package.loaded["mqtt.childdriver"] = nil
      RFP, EC, OPC, TC, OBC = {}, {}, {}, {}, {}
      dofile("drivers/" .. dir .. "/driver.lua")
      OnDriverInit()
      OnDriverLateInit()
    end,
    inbound = function()
      EC.SBOS_MQTT_MESSAGE({ topic = "x/state", payload = "{}", retain = "false", role = "state" })
    end,
  })
end

K.finish()
