-- MQTT Broker DRIVER under the shim with a scripted TCP socket, a scripted
-- Agent, Flight Recorder and children: licence registration, login (and that
-- the password only ever appears in the CONNECT packet), subscriptions,
-- routing to children, publishing for children and for programming, Topics
-- Seen, Message Received events, health (stale, offline, recovery),
-- reconnect with backoff, refused logins, licence enforcement and cleanup.
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
local Packet = require("mqtt.packet")
local H = dofile("test/mqtt_harness.lua")

local AGENT, RECORDER, SELF = 50, 60, 70
local SENSOR, LIGHT = 101, 102
local SECRET = "pa55-secret-xyz"
local env = H.new({
  driver = "smartbuildos-mqtt-broker",
  self_id = SELF,
  devices = {
    [AGENT] = { deviceName = "SmartBuildOS Agent", driverFileName = "smartbuildos.c4z" },
    [RECORDER] = { deviceName = "Flight Recorder", driverFileName = "smartbuildos-flight-recorder.c4z" },
    [SENSOR] = { deviceName = "Sink Leak", driverFileName = "smartbuildos-mqtt-contact.c4z" },
    [LIGHT] = { deviceName = "Lamp", driverFileName = "smartbuildos-mqtt-light.c4z" },
  },
})
env.load()

--- The fake broker's side: decode what the driver wrote on the current socket.
local function currentSocket()
  return env.sockets[#env.sockets]
end
local brokerParser
local function wireSocket(sock)
  brokerParser = Packet.newParser()
  sock.inbox = {}
  sock.on_write = function(data)
    local pkts, err = brokerParser:feed(data)
    assert(err == nil, "driver wrote undecodable bytes: " .. tostring(err))
    for _, p in ipairs(pkts) do
      sock.inbox[#sock.inbox + 1] = p
    end
  end
end
local function take(sock, kind)
  local out, keep = {}, {}
  for _, p in ipairs(sock.inbox) do
    if p.type == kind then
      out[#out + 1] = p
    else
      keep[#keep + 1] = p
    end
  end
  sock.inbox = keep
  return out
end
local function topicsOf(subscribe)
  local names = {}
  for _, f in ipairs(subscribe.filters) do
    names[#names + 1] = f.filter
  end
  table.sort(names)
  return table.concat(names, ",")
end
local sock
--- Time passes with the broker answering every PINGREQ (a healthy idle link).
local function idle(ms)
  local step = 20000
  while ms > 0 do
    local n = math.min(step, ms)
    env.advance(n)
    ms = ms - n
    if sock and not sock.closed then
      for _ = 1, #take(sock, "pingreq") do
        sock:deliver(Packet.pingresp())
      end
    end
  end
end
--- Connects the driver to the fake broker and answers CONNACK.
local function bringUp(code)
  env.advance(2500) -- the 2 s property debounce, then the connect
  local sock = currentSocket()
  wireSocket(sock)
  sock:accept()
  sock:deliver(Packet.connack(false, code or 0))
  return sock
end

print("[1] start: online, nothing configured, licence and Agent registration")
OnDriverInit()
OnDriverLateInit("DIT_ADDING")
check("online", env.props["Driver Status"] == "Online")
check("no host: no socket, says so", #env.sockets == 0 and env.prop("Connection"):find("Broker Host"))
check("not connected", TC.BROKER_CONNECTED() == false and env.vars["BROKER_STATE"] == "disconnected")
local reg = env.lastSent("SBOS_REGISTER_DRIVER")
check(
  "licence registered with the Agent under the broker SKU",
  reg and reg.device == AGENT and reg.params.sku == "SBOS_MQTT_BROKER"
)
local mod = env.lastSent("SBOS_MODULE_REGISTER")
check(
  "registered with the Agent as module mqtt_broker (not a singleton)",
  mod
    and mod.params.module_id == "mqtt_broker"
    and mod.params.singleton == "false"
    and mod.params.event_types == "mqtt."
)
check(
  "the standard licence properties exist in the XML",
  (function()
    for _, p in ipairs({ "License Status", "License Source", "Subscription Tier", "SmartBuildOS Company" }) do
      if not env.xml:find("<name>" .. p .. "</name>", 1, true) then
        return false
      end
    end
    return env.xml:find("<name>Password</name><type>STRING</type><password>true</password>", 1, true) ~= nil
  end)()
)
check("REGISTER_NOW exists", type(EC.REGISTER_NOW) == "function")
env.advance(4000)
check(
  "children are asked to say hello three seconds after start",
  #env.sentOf("SBOS_MQTT_BROKER_HELLO", SENSOR) == 1 and #env.sentOf("SBOS_MQTT_BROKER_HELLO", LIGHT) == 1
)

print("[2] a child says hello before the broker is configured")
EC.SBOS_MQTT_HELLO({
  requester = tostring(SENSOR),
  kind = "contact",
  name = "Sink leak",
  filters = "zigbee2mqtt/sink_leak",
  availability = "zigbee2mqtt/sink_leak/availability",
  availability_field = "state",
})
local ent = env.lastSent("SBOS_MQTT_ENTITY", SENSOR)
check(
  "answered with the broker state",
  ent
    and ent.params.state == "disconnected"
    and ent.params.licence == "ok"
    and ent.allowEmpty == true
    and ent.logCommand == false
)
EC.SBOS_MQTT_HELLO({
  requester = tostring(LIGHT),
  kind = "light",
  name = "Lamp",
  filters = "zigbee2mqtt/lamp\nzigbee2mqtt/bad/#/x",
  availability = "",
})
ent = env.lastSent("SBOS_MQTT_ENTITY", LIGHT)
check(
  "an invalid topic is reported back to the child",
  ent and ent.params.rejected:find("zigbee2mqtt/bad/#/x", 1, true)
)
check("the Devices property counts them", env.prop("Devices"):find("2 linked"), env.prop("Devices"))
EC.SBOS_MQTT_HELLO({ requester = "not-a-number", filters = "x" })
check("a hello without a device id is ignored", env.prop("Devices"):find("2 linked"))

print("[3] configure and log in")
Properties["Broker Host"] = "mqtt.test.invalid"
OnPropertyChanged("Broker Host")
Properties["Broker Port"] = "1884"
OnPropertyChanged("Broker Port")
Properties["Username"] = "bridge"
OnPropertyChanged("Username")
Properties["Password"] = SECRET
OnPropertyChanged("Password")
check("nothing happens until the edits settle", #env.sockets == 0)
env.advance(2500)
sock = currentSocket()
check(
  "one socket to the configured host and port",
  #env.sockets == 1 and sock.host == "mqtt.test.invalid" and sock.port == 1884
)
check("status says connecting", env.prop("Connection"):find("Connecting"))
wireSocket(sock)
sock:accept()
local conn = take(sock, "connect")[1]
check(
  "CONNECT carries the identity, the keepalive and the password",
  conn
    and conn.username == "bridge"
    and conn.password == SECRET
    and conn.keepalive == 60
    and conn.client_id == "sbos-c4-" .. SELF
)
check("the socket is armed for reading", sock.reads_armed >= 1)
sock:deliver(Packet.connack(false, 0))
check(
  "CONNACK: connected, variable, conditional, event, status",
  TC.BROKER_CONNECTED() == true
    and env.vars["BROKER_STATE"] == "connected"
    and env.firedCount(2) == 1
    and env.prop("Connection") == "Connected"
)
local sub = take(sock, "subscribe")
check(
  "subscribes to every child topic, availability, and the discovery filter at once",
  #sub == 1
    and topicsOf(sub[1]) == "zigbee2mqtt/#,zigbee2mqtt/lamp,zigbee2mqtt/sink_leak,zigbee2mqtt/sink_leak/availability",
  sub[1] and topicsOf(sub[1])
)
sock:deliver(Packet.suback(sub[1].id, { 1, 1, 1, 1 }))
local marker = env.lastSent("RECORD_EVENT", RECORDER)
check("the Flight Recorder is told (a marker, no secrets)", marker and marker.params.NAME == "MQTT broker connected")
local ent2 = env.lastSent("SBOS_MQTT_ENTITY", SENSOR)
check("children are told the broker is up", ent2.params.state == "connected")

print("[4] the password stays out of everything but CONNECT")
do
  local leaked = {}
  for name, v in pairs(env.props) do
    if tostring(v):find(SECRET, 1, true) and name ~= "Password" then
      leaked[#leaked + 1] = name
    end
  end
  for _, s in ipairs(env.sent) do
    for k, v in pairs(s.params) do
      if tostring(v):find(SECRET, 1, true) then
        leaked[#leaked + 1] = s.command .. "." .. k
      end
    end
  end
  for k, v in pairs(env.vars) do
    if tostring(v):find(SECRET, 1, true) then
      leaked[#leaked + 1] = "var " .. k
    end
  end
  check("no property, command or variable carries the password", #leaked == 0, table.concat(leaked, ","))
  check(
    "Password and Username are on OPC.suppressDebug (both spellings are the same word)",
    OPC.suppressDebug["Password"] == true and OPC.suppressDebug["Username"] == true
  )
  check("password type is a masked STRING, never PASSWORD", not env.xml:find("<type>PASSWORD</type>", 1, true))
  local pwSeen = false
  for _, w in ipairs(sock.written) do
    if w:find(SECRET, 1, true) then
      pwSeen = true
    end
  end
  check("only the CONNECT packet written to the socket carries it", pwSeen and #sock.written >= 1)
  local count = 0
  for _, w in ipairs(sock.written) do
    if w:find(SECRET, 1, true) then
      count = count + 1
    end
  end
  check("exactly one write contains it", count == 1)
end

print("[5] messages route to the right child")
sock:deliver(
  Packet.publish({ topic = "zigbee2mqtt/sink_leak", payload = '{"water_leak":true,"battery":90}', retain = true })
)
local msg = env.lastSent("SBOS_MQTT_MESSAGE", SENSOR)
check(
  "the sensor gets its payload, the retain flag and the state role",
  msg
    and msg.params.topic == "zigbee2mqtt/sink_leak"
    and msg.params.payload == '{"water_leak":true,"battery":90}'
    and msg.params.retain == "true"
    and msg.params.role == "state"
    and msg.logCommand == false
)
check("the light does not get it", #env.sentOf("SBOS_MQTT_MESSAGE", LIGHT) == 0)
sock:deliver(Packet.publish({ topic = "zigbee2mqtt/other_device", payload = "{}" }))
check("an unrelated topic goes to nobody but Topics Seen", #env.sentOf("SBOS_MQTT_MESSAGE") == 1)
env.advance(5000)
check("Topics Seen counts them", env.prop("Topics Seen"):find("^2 "), env.prop("Topics Seen"))
check("Messages counter", env.prop("Messages"):find("2 in"), env.prop("Messages"))
local payloadsKept = false
for _, s in pairs(env.props) do
  if tostring(s):find("water_leak", 1, true) then
    payloadsKept = true
  end
end
check("payloads are not kept in any property", not payloadsKept)
sock:deliver(Packet.publish({ topic = "zigbee2mqtt/lamp", payload = string.rep("x", 17000) }))
check("a payload over 16 KiB is not forwarded", #env.sentOf("SBOS_MQTT_MESSAGE", LIGHT) == 0)
sock:deliver(Packet.publish({ topic = "zigbee2mqtt/lamp", payload = '{"state":"ON"}', qos = 1, id = 4 }))
check(
  "QoS 1 delivery reaches the light and is acknowledged",
  #env.sentOf("SBOS_MQTT_MESSAGE", LIGHT) == 1 and #take(sock, "puback") == 1
)

print("[6] availability marks a device offline without refreshing last seen")
sock:deliver(
  Packet.publish({ topic = "zigbee2mqtt/sink_leak/availability", payload = '{"state":"offline"}', retain = true })
)
msg = env.lastSent("SBOS_MQTT_MESSAGE", SENSOR)
check("the child gets the availability message with its role", msg.params.role == "availability")
idle(61000)
check(
  "the health scan counts the offline device as stale",
  env.vars["STALE_DEVICE_COUNT"] == 1 and env.vars["DEVICE_COUNT"] == 2,
  tostring(env.vars["STALE_DEVICE_COUNT"])
)
check("Device Went Stale fired and names it", env.firedCount(4) == 1 and env.vars["LAST_STALE_DEVICE"] == "Sink leak")
local health = JSON:decode(env.vars["DEVICE_HEALTH"])
local byName = {}
for _, h in ipairs(health) do
  byName[h.name] = h
end
check(
  "DEVICE_HEALTH variable lists both with state and age",
  byName["Sink leak"].state == "offline" and byName["Lamp"].state == "ok" and byName["Lamp"].age_s ~= nil,
  env.vars["DEVICE_HEALTH"]
)
check("(nothing is uploaded before the Agent has registered the module)", env.lastSent("SBOS_MODULE_EVENTS") == nil)
EC.SBOS_MODULE_REGISTERED({
  module_id = "mqtt_broker",
  ok = "true",
  token = "TOK",
  protocol = "1",
  paired = "true",
  connected = "true",
})
idle(3000)
local function uploaded()
  local types = {}
  for _, s in ipairs(env.sentOf("SBOS_MODULE_EVENTS", AGENT)) do
    for _, e in ipairs(JSON:decode(s.params.events)) do
      types[#types + 1] = e
    end
  end
  return types
end
local up = uploaded()
local seenState = false
for _, e in ipairs(up) do
  seenState = seenState
    or (e.event_type == "mqtt.broker_state" and e.module_id == "mqtt_broker" and e.payload.state == "connected")
end
check("once registered, the staged broker_state event is uploaded", seenState)
local healthEvent
for _, e in ipairs(uploaded()) do
  if e.event_type == "mqtt.entity_health" then
    healthEvent = e
  end
end
check(
  "an mqtt.entity_health event reports each device with its state",
  healthEvent
    and healthEvent.payload.count == 2
    and healthEvent.payload.stale == 1
    and #healthEvent.payload.devices == 2
    and healthEvent.severity == "warning"
)
sock:deliver(Packet.publish({ topic = "zigbee2mqtt/sink_leak/availability", payload = "online" }))
sock:deliver(Packet.publish({ topic = "zigbee2mqtt/sink_leak", payload = '{"water_leak":false}' }))
idle(61000)
check(
  "back online: Device Recovered fired once, stale count 0",
  env.firedCount(5) == 1 and env.vars["STALE_DEVICE_COUNT"] == 0
)

print("[7] stale by silence")
Properties["Stale After Minutes"] = "10"
OnPropertyChanged("Stale After Minutes")
for _ = 1, 11 do
  idle(60000)
  sock:deliver(Packet.publish({ topic = "zigbee2mqtt/lamp", payload = '{"state":"OFF"}' })) -- the lamp talks, the sensor stays silent
end
idle(61000)
check(
  "silent past the threshold: stale",
  env.vars["STALE_DEVICE_COUNT"] == 1 and env.vars["LAST_STALE_DEVICE"] == "Sink leak" and env.firedCount(4) == 2
)
sock:deliver(Packet.publish({ topic = "zigbee2mqtt/sink_leak", payload = '{"water_leak":false}' }))
idle(61000)
check("speaks again: recovered", env.vars["STALE_DEVICE_COUNT"] == 0 and env.firedCount(5) == 2)
Properties["Stale After Minutes"] = "0"
OnPropertyChanged("Stale After Minutes")
idle(3 * 60 * 60 * 1000)
sock:deliver(Packet.publish({ topic = "zigbee2mqtt/lamp", payload = "x" }))
idle(61000)
check("0 minutes means never stale", env.vars["STALE_DEVICE_COUNT"] == 0)

print("[8] commands out: children and programming")
sock:deliver(Packet.pingresp())
env.clearSent()
EC.SBOS_MQTT_PUBLISH({
  requester = tostring(LIGHT),
  topic = "zigbee2mqtt/lamp/set",
  payload = '{"state":"ON"}',
  retain = "false",
  qos = "0",
})
local pub = take(sock, "publish")[1]
check(
  "a child's publish reaches the broker",
  pub and pub.topic == "zigbee2mqtt/lamp/set" and pub.payload == '{"state":"ON"}' and pub.qos == 0 and not pub.retain
)
local res = env.lastSent("SBOS_MQTT_RESULT", LIGHT)
check("the child is told it was sent", res and res.params.status == "sent")
EC.SBOS_MQTT_PUBLISH({ requester = tostring(LIGHT), topic = "zigbee2mqtt/lamp/#", payload = "x" })
res = env.lastSent("SBOS_MQTT_RESULT", LIGHT)
check(
  "a wildcard topic is refused with a reason",
  res.params.status == "failed" and res.params.reason:find("cannot contain")
)
EC.PUBLISH_MESSAGE({ TOPIC = "home/announce", PAYLOAD = "hello", RETAIN = "Yes", QOS = "1" })
pub = take(sock, "publish")[1]
check(
  "Publish Message: topic, payload, retain, QoS 1",
  pub and pub.topic == "home/announce" and pub.retain and pub.qos == 1 and pub.id
)
check("Last Publish records it", env.prop("Last Publish"):find("home/announce"))
EC.PUBLISH_MESSAGE({ TOPIC = "home/plain", PAYLOAD = "x", RETAIN = "No", QOS = "0" })
pub = take(sock, "publish")[1]
check("Publish Message with defaults is QoS 0 and not retained", pub and pub.qos == 0 and not pub.retain)

print("[9] Message Received event on chosen topics")
Properties["Event Topics"] = "home/button/+, alarms/#"
OnPropertyChanged("Event Topics")
sub = take(sock, "subscribe")
check(
  "the event filters are subscribed",
  #sub == 1 and topicsOf(sub[1]) == "alarms/#,home/button/+",
  sub[1] and topicsOf(sub[1])
)
env.clearSent()
sock:deliver(Packet.publish({ topic = "home/button/doorbell", payload = "pressed" }))
check(
  "Message Received fires with the topic and payload in variables",
  env.firedCount(1) == 1 and env.vars["LAST_TOPIC"] == "home/button/doorbell" and env.vars["LAST_PAYLOAD"] == "pressed"
)
sock:deliver(Packet.publish({ topic = "alarms/smoke/kitchen", payload = string.rep("z", 3000) }))
check(
  "a long payload is cut for the variable",
  #env.vars["LAST_PAYLOAD"] == 1000 and env.vars["LAST_TOPIC"] == "alarms/smoke/kitchen"
)
for i = 1, 40 do
  sock:deliver(Packet.publish({ topic = "alarms/storm", payload = tostring(i) }))
end
check("a flood is limited to 20 events per 10 s window", env.firedCount(1) == 20, env.firedCount(1))
env.advance(11000)
sock:deliver(Packet.publish({ topic = "alarms/storm", payload = "after" }))
check("...and the window reopens", env.firedCount(1) == 21)
sock:deliver(Packet.publish({ topic = "unrelated/topic", payload = "x" }))
check("a topic outside the filters fires nothing", env.firedCount(1) == 21)
Properties["Event Topics"] = ""
OnPropertyChanged("Event Topics")
local un = take(sock, "unsubscribe")
check("clearing the filters unsubscribes both in one packet", #un == 1 and #un[1].filters == 2)

print("[10] Topics Seen, Print Topics, discovery")
Properties["Base Topic"] = ""
OnPropertyChanged("Base Topic")
check("an empty Base Topic drops the discovery subscription", #take(sock, "unsubscribe") == 1)
Properties["Base Topic"] = "zigbee2mqtt/"
OnPropertyChanged("Base Topic")
sub = take(sock, "subscribe")
check("a trailing slash is tolerated: zigbee2mqtt/#", #sub == 1 and topicsOf(sub[1]) == "zigbee2mqtt/#")
EC.PRINT_TOPICS()
EC.PRINT_DEVICES()
EC.CLEAR_TOPICS_SEEN()
env.advance(5000)
check("Clear Topics Seen empties the list", env.prop("Topics Seen"):find("^0 "))

print("[11] losing the broker: events, children told, backoff, resubscribe")
env.clearSent()
sock:drop()
check(
  "Broker Disconnected fired, conditional false, children told",
  env.firedCount(3) == 1
    and TC.BROKER_CONNECTED() == false
    and env.lastSent("SBOS_MQTT_ENTITY", SENSOR).params.state == "disconnected"
)
check("the Flight Recorder is told", env.lastSent("RECORD_EVENT", RECORDER).params.NAME == "MQTT broker disconnected")
check("status shows a retry is waiting", env.prop("Connection"):find("Waiting"), env.prop("Connection"))
local before = #env.sockets
env.advance(1500)
check("no retry before the first backoff (2 s plus jitter)", #env.sockets == before)
env.advance(1500)
check("then one new socket", #env.sockets == before + 1)
env.sockets[#env.sockets]:fail(111, "connection refused")
check(
  "a failed TCP connect is reported and the next retry waits longer",
  env.prop("Last Error"):find("connection refused") and env.prop("Connection"):find("Waiting")
)
env.advance(3000)
check("(second backoff is 4 s plus jitter: not yet)", #env.sockets == before + 1)
env.advance(2500)
check("second retry", #env.sockets == before + 2)
local s2 = currentSocket()
wireSocket(s2)
s2:accept()
check("login resent", #take(s2, "connect") == 1)
s2:deliver(Packet.connack(false, 0))
sub = take(s2, "subscribe")
check(
  "everything is subscribed again after the reconnect",
  #sub >= 1 and topicsOf(sub[1]):find("zigbee2mqtt/lamp", 1, true) and topicsOf(sub[1]):find("zigbee2mqtt/#", 1, true)
)
check("Broker Connected fired again", env.firedCount(2) == 1)
sock = s2

print("[12] keepalive and a silent broker")
env.advance(46000) -- 0.75 x 60
check("a PINGREQ goes out when the line is quiet", #take(sock, "pingreq") == 1)
sock:deliver(Packet.pingresp())
env.advance(46000)
take(sock, "pingreq")
env.clearSent()
env.advance(35000) -- no answer for longer than half the keepalive
check(
  "an unanswered ping drops the connection and retries",
  TC.BROKER_CONNECTED() == false and env.firedCount(3) == 1 and sock.closed == true
)
check("the reason names the keepalive", env.prop("Last Error"):find("keepalive"), env.prop("Last Error"))
env.advance(130000)
s2 = currentSocket()
check("it reconnects on its own", s2 ~= sock)
wireSocket(s2)
s2:accept()
s2:deliver(Packet.connack(false, 0))
sock = s2

print("[13] a refused login does not hammer the broker")
Properties["Password"] = "wrong-" .. SECRET
OnPropertyChanged("Password")
local nSockets
env.advance(2500)
sock = currentSocket()
wireSocket(sock)
sock:accept()
sock:deliver(Packet.connack(false, 4))
check(
  "refused: not connected, reason shown, no secret in it",
  not TC.BROKER_CONNECTED()
    and env.prop("Last Error"):find("user name or password")
    and not env.prop("Last Error"):find("pa55", 1, true)
)
nSockets = #env.sockets
env.advance(100000)
check("no retry for a bad login inside 100 s", #env.sockets == nSockets)
env.advance(40000)
check("retries at the ceiling (about two minutes)", #env.sockets == nSockets + 1)
Properties["Password"] = SECRET
OnPropertyChanged("Password")
env.advance(2500)
sock = currentSocket()
wireSocket(sock)
sock:accept()
sock:deliver(Packet.connack(false, 0))
check("correcting the password reconnects at once", TC.BROKER_CONNECTED() == true)

print("[14] Reconnect Now")
local count = #env.sockets
EC.RECONNECT_NOW()
check("a new socket immediately", #env.sockets == count + 1)
sock = currentSocket()
wireSocket(sock)
sock:accept()
sock:deliver(Packet.connack(false, 0))

print("[15] children that were removed are forgotten")
env.devices[LIGHT] = nil
idle(61000)
check("the light is no longer a linked device", env.vars["DEVICE_COUNT"] == 1, tostring(env.vars["DEVICE_COUNT"]))

print("[16] licence enforcement: messages flow, nothing is published")
EC.SBOS_ENTITLEMENT({ sku = "SBOS_MQTT_BROKER", status = "NOT_ENTITLED", registered = "true", enforcement = "enforce" })
check(
  "definitive denial + enforce: read-only, event 6, children told",
  env.firedCount(6) == 1
    and env.prop("Bridge Status") == "read-only (licence)"
    and env.lastSent("SBOS_MQTT_ENTITY", SENSOR).params.licence == "read-only"
)
env.clearSent()
EC.PUBLISH_MESSAGE({ TOPIC = "x/y", PAYLOAD = "z" })
check(
  "Publish Message refused",
  #take(sock, "publish") == 0 and env.prop("Last Publish"):find("read%-only") and env.firedCount(6) == 1
)
EC.SBOS_MQTT_PUBLISH({ requester = tostring(SENSOR), topic = "x/y", payload = "z" })
res = env.lastSent("SBOS_MQTT_RESULT", SENSOR)
check(
  "a child's publish is refused with the reason",
  #take(sock, "publish") == 0 and res.params.status == "failed" and res.params.reason:find("read%-only")
)
sock:deliver(Packet.publish({ topic = "zigbee2mqtt/sink_leak", payload = '{"water_leak":true}' }))
check("messages still reach children", env.lastSent("SBOS_MQTT_MESSAGE", SENSOR) ~= nil)
EC.SBOS_ENTITLEMENT({ sku = "SBOS_MQTT_BROKER", status = "NOT_ENTITLED", registered = "true", enforcement = "observe" })
EC.PUBLISH_MESSAGE({ TOPIC = "x/y", PAYLOAD = "z" })
check("observe mode (or any uncertainty) fails open", #take(sock, "publish") == 1)
EC.SBOS_ENTITLEMENT({
  sku = "SBOS_MQTT_BROKER",
  status = "CLOUD_VALIDATION_REQUIRED",
  registered = "true",
  enforcement = "enforce",
})
EC.PUBLISH_MESSAGE({ TOPIC = "x/y", PAYLOAD = "z" })
check("an uncertain status never enforces", #take(sock, "publish") == 1)

print("[17] shutdown")
OnDriverDestroyed()
check("destroy sends DISCONNECT and closes the socket", #take(sock, "disconnect") == 1 and sock.closed == true)
check("timers are cancelled", env.clock.timers["MqttTick"] == nil and env.clock.timers["MqttReconnect"] == nil)

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
