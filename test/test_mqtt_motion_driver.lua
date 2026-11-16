-- MQTT Motion DRIVER under the shim with a scripted Broker: hello, state
-- messages to the motion proxy, value maps, events, conditionals,
-- availability.
--
-- Run from the driver root: make test

local pass, fail = 0, 0
local function check(name, ok, detail)
  if ok then
    pass = pass + 1
    print("  ok   " .. name)
  else
    fail = fail + 1
    print("  FAIL " .. name .. (detail ~= nil and ("  -> " .. tostring(detail)) or ""))
  end
end

package.path = "test/?.lua;src/?.lua;vendor/?.lua;" .. package.path
local H = dofile("test/mqtt_harness.lua")
local BROKER, SELF = 80, 91
local env = H.new({
  driver = "smartbuildos-mqtt-motion",
  self_id = SELF,
  devices = { [BROKER] = { deviceName = "MQTT Broker", driverFileName = "smartbuildos-mqtt-broker.c4z" } },
  names = { [SELF] = "Hall motion" },
})
env.load()
local function message(payload, role)
  EC.SBOS_MQTT_MESSAGE({
    topic = Properties["State Topic"],
    payload = payload,
    retain = "false",
    role = role or "state",
  })
end

print("[1] start and hello")
Properties["State Topic"] = "zigbee2mqtt/hall_motion"
OnDriverInit()
OnDriverLateInit("DIT_ADDING")
local hello = env.lastSent("SBOS_MQTT_HELLO", BROKER)
check(
  "hello says motion with its topic",
  hello and hello.params.kind == "motion" and hello.params.filters == "zigbee2mqtt/hall_motion"
)
EC.SBOS_MQTT_ENTITY({ state = "connected", licence = "ok", rejected = "" })
check(
  "defaults suit Zigbee2MQTT: field occupancy, no invert",
  Properties["State Field"] == "occupancy" and Properties["Invert"] == "No"
)

print("[2] occupancy")
env.clearSent()
message('{"occupancy":true,"illuminance":12,"battery":100}')
check(
  "true: motion notified",
  env.proxy[#env.proxy].command == "MOTION"
    and env.proxy[#env.proxy].binding == 5001
    and env.proxy[#env.proxy].kind == "NOTIFY"
    and TC.MOTION_ACTIVE() == true
)
check("no event on the first reading", env.firedCount(4) == 0)
message('{"occupancy":false}')
check(
  "false: no motion, Motion Cleared event",
  env.proxy[#env.proxy].command == "NO_MOTION" and env.firedCount(5) == 1 and TC.MOTION_ACTIVE() == false
)
message('{"occupancy":true}')
check("motion again: Motion Detected event", env.firedCount(4) == 1)
message('{"occupancy":true}')
check("no repeat event", env.firedCount(4) == 1)
env.advance(3100)
check("Current State", env.prop("Current State") == "Motion")
RFP.GET_STATE(5001)
check("the proxy can ask", env.proxy[#env.proxy].command == "MOTION")

print("[3] other shapes")
Properties["State Field"] = ""
env.clearSent()
message("ON")
check("a bare ON", env.proxy[#env.proxy].command == "MOTION")
message("OFF")
check("a bare OFF", env.proxy[#env.proxy].command == "NO_MOTION")
Properties["State Field"] = "presence"
Properties["Invert"] = "Yes"
message('{"presence":true}')
check("inverted", env.proxy[#env.proxy].command == "NO_MOTION")
Properties["Invert"] = "No"
Properties["State Field"] = "sensor.pir"
Properties["Active Values"] = "detected"
Properties["Inactive Values"] = "clear"
message('{"sensor":{"pir":"detected"}}')
check("dotted path with a word list", env.proxy[#env.proxy].command == "MOTION")
message('{"sensor":{"pir":"clear"}}')
check("...and its opposite", env.proxy[#env.proxy].command == "NO_MOTION")
env.clearSent()
message('{"other":1}')
check("a message without the field changes nothing", #env.proxy == 0)

print("[4] availability and the broker")
env.clearSent()
message("offline", "availability")
check("offline", env.firedCount(2) == 1 and TC.DEVICE_AVAILABLE() == false)
message('{"state":"online"}', "availability")
check("online", env.firedCount(1) == 1)
EC.SBOS_MQTT_ENTITY({ state = "disconnected", licence = "ok", rejected = "" })
check("broker down", TC.BROKER_CONNECTED() == false)

print("[5] structure")
check("the proxy is motionsensor", env.xml:find(">motionsensor</proxy>", 1, true) ~= nil)
OnDriverDestroyed()

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
