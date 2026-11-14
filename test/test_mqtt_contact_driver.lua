-- MQTT Contact DRIVER under the shim with a scripted Broker: hello, state
-- messages to the contact proxy (invert, dotted paths, custom value lists,
-- report-as), events and conditionals, availability, bad configuration, and
-- the way it behaves with no broker in the project.
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
local BROKER, SELF = 80, 90
local env = H.new({
  driver = "smartbuildos-mqtt-contact",
  self_id = SELF,
  devices = { [BROKER] = { deviceName = "MQTT Broker", driverFileName = "smartbuildos-mqtt-broker.c4z" } },
  names = { [SELF] = "Sink leak" },
})
env.load()

local function message(payload, role, topic)
  EC.SBOS_MQTT_MESSAGE({
    topic = topic or Properties["State Topic"],
    payload = payload,
    retain = "false",
    role = role or "state",
  })
end
local function lastNotify()
  local p = env.proxy[#env.proxy]
  return p and p.command
end

print("[1] start and hello")
Properties["State Topic"] = "zigbee2mqtt/front_door"
Properties["Availability Topic"] = "zigbee2mqtt/front_door/availability"
OnDriverInit()
OnDriverLateInit("DIT_ADDING")
check("online", env.props["Driver Status"] == "Online")
local hello = env.lastSent("SBOS_MQTT_HELLO", BROKER)
check(
  "hello to the broker: who, what kind, which topics",
  hello
    and hello.params.requester == tostring(SELF)
    and hello.params.kind == "contact"
    and hello.params.filters == "zigbee2mqtt/front_door"
    and hello.params.availability == "zigbee2mqtt/front_door/availability"
    and hello.params.availability_field == "state"
    and hello.params.name == "Sink leak"
)
check("hello is not logged and may carry empty values", hello.logCommand == false and hello.allowEmpty == true)
check("Broker Link says it is waiting", env.prop("Broker Link"):find("no answer yet"))
env.advance(61000)
check("no answer: it asks again after a minute", #env.sentOf("SBOS_MQTT_HELLO") == 2)
EC.SBOS_MQTT_ENTITY({ state = "connected", licence = "ok", rejected = "" })
check(
  "answer: connected",
  env.prop("Broker Link") == "Connected" and TC.BROKER_CONNECTED() == true and env.prop("Control") == "enabled"
)
env.advance(61000)
check("an answered child stops asking", #env.sentOf("SBOS_MQTT_HELLO") == 2)
EC.SBOS_MQTT_BROKER_HELLO({})
check("a restarted broker asks again", #env.sentOf("SBOS_MQTT_HELLO") == 3)

print("[2] Zigbee2MQTT door contact: contact true means CLOSED")
env.clearSent()
message('{"contact":true,"battery":97}')
check(
  "true (inverted by default) reports Closed",
  lastNotify() == "CLOSED" and TC.CONTACT_OPEN() == false and env.prop("Current State") == "Closed"
)
check("no event on the first reading", env.firedCount(4) == 0 and env.firedCount(5) == 0)
message('{"contact":false}')
check(
  "false reports Opened with the event",
  lastNotify() == "OPENED" and env.firedCount(4) == 1 and TC.CONTACT_OPEN() == true
)
message('{"contact":false}')
check("the same value again fires nothing more", env.firedCount(4) == 1)
message('{"contact":true}')
check("closing fires Contact Closed", env.firedCount(5) == 1)
RFP.GET_STATE(5001)
check("the proxy can ask for the state", env.lastProxy("STATE_CLOSED") ~= nil)
check("Last Seen counts messages", env.prop("Last Seen"):find("messages"))

print("[3] a message that lacks the field is left alone")
env.clearSent()
message('{"linkquality":120}')
check("no proxy traffic", #env.proxy == 0)
env.advance(3100) -- the message properties repaint at most every 3 s
check("the note says why", env.prop("Last Message"):find("no 'contact'"), env.prop("Last Message"))
message("not json at all")
env.advance(3100)
check("garbage is a note, not an error", env.prop("Last Message"):find("no 'contact'"))

print("[4] a leak sensor: water_leak true is wet is Opened")
Properties["State Field"] = "water_leak"
OnPropertyChanged("State Field")
Properties["Invert"] = "No"
OnPropertyChanged("Invert")
Properties["State Topic"] = "zigbee2mqtt/sink_leak"
OnPropertyChanged("State Topic")
env.advance(2000)
hello = env.lastSent("SBOS_MQTT_HELLO", BROKER)
check("editing the topic says hello again with the new topic", hello.params.filters == "zigbee2mqtt/sink_leak")
env.clearSent()
message('{"water_leak":true,"battery":80}')
check("wet reports Opened", lastNotify() == "OPENED")
message('{"water_leak":false}')
check("dry reports Closed", lastNotify() == "CLOSED")

print("[5] dotted paths and custom value lists")
Properties["State Field"] = "alarm.water.state"
OnPropertyChanged("State Field")
Properties["Active Values"] = "ALARM, 2"
Properties["Inactive Values"] = "ok"
env.clearSent()
message('{"alarm":{"water":{"state":"ALARM"}}}')
check("a nested value, listed as active", lastNotify() == "OPENED")
message('{"alarm":{"water":{"state":"ok"}}}')
check("listed as inactive", lastNotify() == "CLOSED")
env.clearSent()
message('{"alarm":{"water":{"state":"banana"}}}')
env.advance(3100)
check("an unlisted word is refused with a hint", #env.proxy == 0 and env.prop("Last Message"):find("Active Values"))
Properties["Active Values"] = ""
Properties["Inactive Values"] = ""
Properties["State Field"] = ""
message("detected")
check("empty field: the whole payload is the value", lastNotify() == "OPENED")
message("clear")
check("plain words", lastNotify() == "CLOSED")
message('{"a":1}')
env.advance(3100)
check("a JSON object with no field named is refused", env.prop("Last Message"):find("State Field"))

print("[6] Report Active As Closed")
Properties["Report Active As"] = "Closed"
env.clearSent()
message("detected")
check("active is reported as Closed", lastNotify() == "CLOSED")
Properties["Report Active As"] = "Opened"

print("[7] availability")
env.clearSent()
message('{"state":"offline"}', "availability")
check(
  "offline: event, conditional, property",
  env.firedCount(2) == 1 and TC.DEVICE_AVAILABLE() == false and env.prop("Device Availability") == "offline"
)
message("online", "availability")
check("online again: event", env.firedCount(1) == 1 and TC.DEVICE_AVAILABLE() == true)
message("online", "availability")
check("repeating online fires nothing", env.firedCount(1) == 1)
check("an availability message is not a state message", env.prop("Last Message") ~= nil)

print("[8] the broker goes away")
EC.SBOS_MQTT_ENTITY({ state = "disconnected", licence = "ok", rejected = "" })
check(
  "link text and conditional follow",
  TC.BROKER_CONNECTED() == false
    and env.prop("Broker Link"):find("not connected")
    and env.prop("Control") == "view only"
)

print("[9] a wildcard topic is refused")
Properties["State Topic"] = "zigbee2mqtt/#"
OnPropertyChanged("State Topic")
env.advance(2000)
hello = env.lastSent("SBOS_MQTT_HELLO", BROKER)
check("nothing to listen to is sent", hello.params.filters == "")
check(
  "and the reason is shown",
  env.prop("Last Result"):find("not listening") and env.prop("Last Result"):find("cannot contain"),
  env.prop("Last Result")
)
check("Command Failed fired", env.firedCount(3) >= 1)

print("[10] the broker rejects a topic")
EC.SBOS_MQTT_ENTITY({ state = "connected", licence = "ok", rejected = "ignored topic 'x': nope" })
check("its reason is shown", env.prop("Last Result"):find("ignored topic"))

print("[11] no broker in the project")
env.devices[BROKER] = nil
EC.REFRESH_FROM_BROKER()
check("says so", env.prop("Broker Link") == "No SmartBuildOS MQTT Broker found in this project")

print("[12] shutdown and the licence guard")
OnDriverDestroyed()
check("timers cancelled", env.clock.timers["MqttChildHello"] == nil)
local src = io.open("drivers/smartbuildos-mqtt-contact/driver.lua"):read("*a")
check("the child holds no licence of its own (the broker's covers it)", not src:find("sbos.license", 1, true))
check("the proxy is contactsingle", env.xml:find(">contactsingle</proxy>", 1, true) ~= nil)

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
