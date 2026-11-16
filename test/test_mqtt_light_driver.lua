-- MQTT Light DRIVER under the shim with a scripted Broker: hello, state
-- messages to the light_v2 proxy (on/off, brightness scaled from the device's
-- range), commands from Navigator and programming published through the
-- broker with their payload templates, view-only fallbacks, availability and
-- licence read-only.
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
local BROKER, SELF = 80, 92
local env = H.new({
  driver = "smartbuildos-mqtt-light",
  self_id = SELF,
  devices = { [BROKER] = { deviceName = "MQTT Broker", driverFileName = "smartbuildos-mqtt-broker.c4z" } },
  names = { [SELF] = "Lamp" },
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
local function lastBrightness()
  local p = env.lastProxy("LIGHT_BRIGHTNESS_CHANGED")
  return p and p.params.LIGHT_BRIGHTNESS_CURRENT
end

print("[1] start")
Properties["State Topic"] = "zigbee2mqtt/lamp"
Properties["Set Topic"] = "zigbee2mqtt/lamp/set"
OnDriverInit()
OnDriverLateInit("DIT_ADDING")
local hello = env.lastSent("SBOS_MQTT_HELLO", BROKER)
check("hello says light", hello and hello.params.kind == "light" and hello.params.filters == "zigbee2mqtt/lamp")
check("view-only until the broker is connected", env.prop("Control") == "view only")
env.clearSent()
RFP.ON(P)
check(
  "a command with the broker down is refused with a reason, nothing sent",
  lastPublish() == nil and env.prop("Last Result"):find("not connected") and env.firedCount(3) == 1
)
EC.SBOS_MQTT_ENTITY({ state = "connected", licence = "ok", rejected = "" })
check("connected: the proxy is told the light is online", env.lastProxy("ONLINE_CHANGED").params.STATE == true)

print("[2] state from the device")
env.clearSent()
message('{"state":"ON","brightness":127}')
env.advance(3100) -- status properties repaint at most every 3 s
check(
  "on at 50 percent (127 of 254)",
  lastBrightness() == 50 and env.lastProxy("LIGHT_LEVEL").params.LEVEL == 50 and env.prop("Current State") == "On 50%"
)
check("no event on the first reading", env.firedCount(4) == 0)
message('{"state":"OFF"}')
check("off shows 0 and fires Light Off", lastBrightness() == 0 and env.firedCount(5) == 1 and TC.LIGHT_ON() == false)
message('{"state":"ON"}')
check("on without a brightness returns to the last level (50)", lastBrightness() == 50 and env.firedCount(4) == 1)
message('{"state":"ON","brightness":254}')
check("full brightness is 100", lastBrightness() == 100)
message('{"brightness":0}')
check("brightness 0 alone means off", lastBrightness() == 0 and TC.LIGHT_ON() == false)
message('{"linkquality":50}')
env.advance(3100)
check("a message with neither field is a note", env.prop("Last Message"):find("neither"))
Properties["Level Max"] = "100"
message('{"state":"ON","brightness":30}')
check("Level Max 100: 30 is 30 percent", lastBrightness() == 30)
Properties["Level Max"] = "254"
RFP.GET_LIGHT_LEVEL(P)
check("the proxy can ask for the level (kept as a percentage, not re-scaled)", lastBrightness() == 30)
Properties["Level Field"] = ""
message("ON")
check("a switch with no level field: bare ON works", TC.LIGHT_ON() == true)
Properties["Level Field"] = "brightness"

print("[3] commands out")
env.clearSent()
RFP.ON(P)
local pub = lastPublish()
check(
  "On publishes the On Payload to the Set Topic",
  pub
    and pub.params.topic == "zigbee2mqtt/lamp/set"
    and pub.params.payload == '{"state":"ON"}'
    and pub.params.requester == tostring(SELF)
    and pub.params.retain == "false"
    and pub.logCommand == false
)
RFP.OFF(P)
check("Off", lastPublish().params.payload == '{"state":"OFF"}')
RFP.SET_BRIGHTNESS_TARGET(P, nil, { LIGHT_BRIGHTNESS_TARGET = 50, RATE = 0 })
check(
  "50 percent renders {level} in the device's range",
  lastPublish().params.payload == '{"brightness":127}',
  lastPublish().params.payload
)
RFP.RAMP_TO_LEVEL(P, nil, { LEVEL = 100 })
check("100 percent is 254", lastPublish().params.payload == '{"brightness":254}')
RFP.SET_LEVEL(P, nil, { LEVEL = 0 })
check("level 0 is the Off Payload", lastPublish().params.payload == '{"state":"OFF"}')
Properties["Level Payload"] = '{"brightness":{level},"transition":{seconds},"pct":{percent}}'
RFP.SET_BRIGHTNESS_TARGET(P, nil, { LIGHT_BRIGHTNESS_TARGET = 40, RATE = 3000 })
check(
  "{seconds} and {percent} too",
  lastPublish().params.payload == '{"brightness":102,"transition":3,"pct":40}',
  lastPublish().params.payload
)
Properties["Level Payload"] = '{"brightness":{level}}'
message('{"state":"ON","brightness":100}')
env.clearSent()
RFP.TOGGLE(P)
check("toggle from on publishes off", lastPublish().params.payload == '{"state":"OFF"}')
message('{"state":"OFF"}')
RFP.TOGGLE(P)
check("toggle from off publishes on", lastPublish().params.payload == '{"state":"ON"}')
RFP.BUTTON_ACTION(P, nil, { BUTTON_ID = 1, ACTION = 2 })
check("a Navigator tap on the bottom button is off", lastPublish().params.payload == '{"state":"OFF"}')
RFP.BUTTON_ACTION(P, nil, { BUTTON_ID = 0, ACTION = 2 })
check("top button is on", lastPublish().params.payload == '{"state":"ON"}')
local n = #env.sentOf("SBOS_MQTT_PUBLISH")
RFP.BUTTON_ACTION(P, nil, { BUTTON_ID = 0, ACTION = 1 })
check("a press without a click publishes nothing", #env.sentOf("SBOS_MQTT_PUBLISH") == n)
RFP.ON(999)
check("a command for another binding is ignored", #env.sentOf("SBOS_MQTT_PUBLISH") == n)
EC.TEST_HALF()
check("the Test: 50% action", lastPublish().params.payload == '{"brightness":127}')
check("the proxy brightness did not move on a request (only the state topic moves it)", lastBrightness() == 0)

print("[4] refusals")
Properties["Set Topic"] = ""
n = #env.sentOf("SBOS_MQTT_PUBLISH")
RFP.ON(P)
check(
  "no Set Topic: view-only, with a reason",
  #env.sentOf("SBOS_MQTT_PUBLISH") == n and env.prop("Last Result"):find("no Set Topic")
)
Properties["Set Topic"] = "zigbee2mqtt/lamp/#"
RFP.ON(P)
check(
  "a wildcard Set Topic is refused",
  #env.sentOf("SBOS_MQTT_PUBLISH") == n and env.prop("Last Result"):find("cannot contain")
)
Properties["Set Topic"] = "zigbee2mqtt/lamp/set"
EC.SBOS_MQTT_ENTITY({ state = "connected", licence = "read-only", rejected = "" })
RFP.ON(P)
check(
  "licence read-only: refused here too",
  #env.sentOf("SBOS_MQTT_PUBLISH") == n
    and env.prop("Last Result"):find("read%-only")
    and env.prop("Control") == "view only"
)
EC.SBOS_MQTT_ENTITY({ state = "connected", licence = "ok", rejected = "" })
EC.SBOS_MQTT_RESULT({ status = "failed", reason = "not connected to the broker" })
check("a failure the broker reports is shown", env.prop("Last Result"):find("not connected to the broker"))

print("[5] availability and online state")
env.clearSent()
message('{"state":"offline"}', "availability")
check(
  "offline: the proxy goes offline, event fires",
  env.lastProxy("ONLINE_CHANGED").params.STATE == false and env.firedCount(2) == 1
)
message("online", "availability")
check(
  "online again: proxy back, brightness re-sent",
  env.lastProxy("ONLINE_CHANGED").params.STATE == true and lastBrightness() ~= nil and env.firedCount(1) == 1
)
EC.SBOS_MQTT_ENTITY({ state = "disconnected", licence = "ok", rejected = "" })
check("broker lost: proxy offline", env.lastProxy("ONLINE_CHANGED").params.STATE == false)
RFP.GET_CONNECTED_STATE(P)
check("the proxy can ask", env.lastProxy("ONLINE_CHANGED").params.STATE == false)

print("[6] structure")
for _, cap in ipairs({ "dimmer", "on_off", "set_level", "ramp_level", "level_target" }) do
  check("capability " .. cap, env.xml:find("<" .. cap .. ">True</" .. cap .. ">", 1, true) ~= nil)
end
check("the proxy is light_v2", env.xml:find(">light_v2</proxy>", 1, true) ~= nil)
OnDriverDestroyed()

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
