-- MQTT Shade DRIVER under the shim with a scripted Broker: hello, position
-- messages to the blind proxy (100 = open, optional invert), open / close /
-- stop / go-to published through the broker, refusals, availability.
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
local BROKER, SELF = 80, 93
local env = H.new({
  driver = "smartbuildos-mqtt-shade",
  self_id = SELF,
  devices = { [BROKER] = { deviceName = "MQTT Broker", driverFileName = "smartbuildos-mqtt-broker.c4z" } },
  names = { [SELF] = "Living blind" },
})
env.load()
local P = 5001
local function message(payload, role)
  EC.SBOS_MQTT_MESSAGE({
    topic = Properties["State Topic"],
    payload = payload,
    retain = "false",
    role = role or "state",
  })
end
local function lastPublish()
  return env.lastSent("SBOS_MQTT_PUBLISH", BROKER)
end
local function lastStopped()
  local p = env.lastProxy("STOPPED")
  return p and p.params.LEVEL
end

print("[1] start")
Properties["State Topic"] = "zigbee2mqtt/blind"
Properties["Set Topic"] = "zigbee2mqtt/blind/set"
OnDriverInit()
OnDriverLateInit("DIT_ADDING")
local hello = env.lastSent("SBOS_MQTT_HELLO", BROKER)
check("hello says shade", hello and hello.params.kind == "shade" and hello.params.filters == "zigbee2mqtt/blind")
check(
  "the proxy is told the blind has a level and can stop",
  env.lastProxy("SET_HAS_LEVEL").params.LEVEL_OPEN == 100 and env.lastProxy("SET_CAN_STOP").params.CAN_STOP == "true"
)
EC.SBOS_MQTT_ENTITY({ state = "connected", licence = "ok", rejected = "" })

print("[2] position from the device")
env.clearSent()
message('{"position":35,"state":"CLOSE"}')
check("35 percent open", lastStopped() == 35)
env.advance(3100)
check("Current State", env.prop("Current State") == "35% open")
check("not fully open or closed: no event", env.firedCount(4) == 0 and env.firedCount(5) == 0)
check("conditional", TC.SHADE_OPEN() == true)
message('{"position":100}')
check("100 fires Shade Fully Open", lastStopped() == 100 and env.firedCount(4) == 1)
message('{"position":0}')
check("0 fires Shade Fully Closed", lastStopped() == 0 and env.firedCount(5) == 1 and TC.SHADE_OPEN() == false)
message('{"position":0}')
check("no repeat event", env.firedCount(5) == 1)
message('{"position":"73"}')
check("a numeric string works", lastStopped() == 73)
message('{"position":250}')
check("clamped to 100", lastStopped() == 100)
env.clearSent()
message('{"state":"OPEN"}')
env.advance(3100)
check("a message without a position is a note", #env.proxy == 0 and env.prop("Last Message"):find("no number"))
Properties["Position Field"] = "pos.percent"
message('{"pos":{"percent":20}}')
check("dotted position field", lastStopped() == 20)
Properties["Position Field"] = ""
message("65")
check("a bare number", lastStopped() == 65)
Properties["Position Field"] = "position"

print("[3] inverted device (0 = open)")
Properties["Invert Position"] = "Yes"
message('{"position":0}')
check("0 reads as fully open", lastStopped() == 100)
message('{"position":100}')
check("100 reads as closed", lastStopped() == 0)
RFP.SET_LEVEL_TARGET(P, nil, { LEVEL_TARGET = 30 })
check(
  "go to 30 sends 70 to the device",
  lastPublish().params.payload == '{"position":70}',
  lastPublish().params.payload
)
Properties["Invert Position"] = "No"

print("[4] commands out")
env.clearSent()
RFP.OPEN(P)
local pub = lastPublish()
check(
  "Open",
  pub
    and pub.params.topic == "zigbee2mqtt/blind/set"
    and pub.params.payload == '{"state":"OPEN"}'
    and pub.logCommand == false
)
RFP.CLOSE(P)
check("Close", lastPublish().params.payload == '{"state":"CLOSE"}')
RFP.STOP(P)
check("Stop", lastPublish().params.payload == '{"state":"STOP"}')
RFP.SET_LEVEL_TARGET(P, nil, { LEVEL_TARGET = 60 })
check("Go to 60", lastPublish().params.payload == '{"position":60}')
RFP.SET_LEVEL(P, nil, { LEVEL = 10 })
check("SET_LEVEL alias", lastPublish().params.payload == '{"position":10}')
Properties["Position Payload"] = '{"position":{position},"asked":{percent}}'
RFP.SET_LEVEL_TARGET(P, nil, { LEVEL_TARGET = 45 })
check("{percent} too", lastPublish().params.payload == '{"position":45,"asked":45}')
message('{"position":80}')
RFP.TOGGLE(P)
check("toggle from mostly open closes", lastPublish().params.payload == '{"state":"CLOSE"}')
message('{"position":20}')
RFP.TOGGLE(P)
check("toggle from mostly closed opens", lastPublish().params.payload == '{"state":"OPEN"}')
EC.TEST_STOP()
check("bench action", lastPublish().params.payload == '{"state":"STOP"}')
local n = #env.sentOf("SBOS_MQTT_PUBLISH")
RFP.OPEN(999)
check("another binding is ignored", #env.sentOf("SBOS_MQTT_PUBLISH") == n)
check("a request does not move the proxy (only the state topic does)", lastStopped() == 20)

print("[5] refusals")
Properties["Set Topic"] = ""
RFP.OPEN(P)
check("no Set Topic", #env.sentOf("SBOS_MQTT_PUBLISH") == n and env.prop("Last Result"):find("no Set Topic"))
Properties["Set Topic"] = "zigbee2mqtt/blind/set"
EC.SBOS_MQTT_ENTITY({ state = "disconnected", licence = "ok", rejected = "" })
RFP.OPEN(P)
check("broker down", #env.sentOf("SBOS_MQTT_PUBLISH") == n and env.prop("Last Result"):find("not connected"))
EC.SBOS_MQTT_ENTITY({ state = "connected", licence = "read-only", rejected = "" })
RFP.OPEN(P)
check("licence read-only", #env.sentOf("SBOS_MQTT_PUBLISH") == n and env.prop("Last Result"):find("read%-only"))
EC.SBOS_MQTT_ENTITY({ state = "connected", licence = "ok", rejected = "" })

print("[6] availability")
env.clearSent()
message('{"state":"offline"}', "availability")
check("offline event and conditional", env.firedCount(2) == 1 and TC.DEVICE_AVAILABLE() == false)
message("online", "availability")
check("online event", env.firedCount(1) == 1)

print("[7] structure")
for _, cap in ipairs({ "has_level", "can_stop", "level_discrete_control" }) do
  check("capability " .. cap, env.xml:find("<" .. cap .. ">true</" .. cap .. ">", 1, true) ~= nil)
end
check("the proxy is blind", env.xml:find(">blind</proxy>", 1, true) ~= nil)
OnDriverDestroyed()

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
