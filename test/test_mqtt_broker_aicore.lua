-- MQTT Broker reports to AI Core (sbos.aireport, ATTACH mode: the driver's
-- own module client carries the reports; brief D7a). A MULTI-INSTANCE root:
-- every broker registers as mqtt_broker under its own device id,
-- non-singleton.
--
-- The real driver.lua under test/mqtt_harness.lua (the fake Director and TCP
-- socket test_mqtt_broker_driver.lua uses), the REAL Agent registry and bus
-- and a fake AI Core answering through AI Core's REAL validator
-- (test/aicore_reporter_harness.lua); the shared lifecycle checks are
-- test/aicore_rollout_checks.lua. Driver-specific: HEALTH AND COUNTS ONLY.
-- No topic, payload, device name, host, username or password in any report;
-- the broker connected / disconnected diagnostics; a second instance.
-- Run from the driver root: make test

package.path = "test/?.lua;src/?.lua;vendor/?.lua;" .. package.path
local Packet = require("mqtt.packet")
local MH = dofile("test/mqtt_harness.lua")
local SELF = 12345
local SENSOR = 101
local env = MH.new({
  driver = "smartbuildos-mqtt-broker",
  self_id = SELF,
  devices = {
    [SENSOR] = { deviceName = "Whitfield Sink Leak", driverFileName = "smartbuildos-mqtt-contact.c4z" },
  },
})
local R = require("aicore_rollout_checks")
local H = require("aicore_reporter_harness")
local check = R.check

R.loadProperties("smartbuildos-mqtt-broker")
Properties["Broker Host"] = "mqtt.test.invalid"
Properties["Username"] = "c4user77"
Properties["Password"] = "pa55-secret-xyz"
R.watchPaints()
H.install({ selfId = SELF, file = "smartbuildos-mqtt-broker.c4z" })
env.load()

--- The fake broker: answer the CONNECT, then every PINGREQ.
local parser
local function serve(sock)
  parser = Packet.newParser()
  sock.on_write = function(data)
    for _, p in ipairs(parser:feed(data)) do
      if p.type == "connect" then
        sock.pending = Packet.connack(false, 0)
      elseif p.type == "pingreq" then
        sock.pending = Packet.pingresp()
      end
    end
  end
  sock:accept()
  if sock.pending then
    local bytes = sock.pending
    sock.pending = nil
    sock:deliver(bytes)
  end
end
local function connectBroker()
  env.advance(2500)
  local sock = env.sockets[#env.sockets]
  if sock ~= nil and not sock.served then
    sock.served = true
    serve(sock)
  end
  return sock
end

R.lifecycle({
  H = H,
  moduleId = "mqtt_broker",
  file = "smartbuildos-mqtt-broker.c4z",
  sku = "SBOS_MQTT_BROKER",
  mode = "attach",
  multiInstance = true,
  destroy = false, -- below: the driver never unregisters its client
  activity = function()
    connectBroker()
    EC.SBOS_MQTT_HELLO({
      requester = tostring(SENSOR),
      kind = "contact",
      name = "Whitfield Sink Leak",
      filters = "zigbee2mqtt/sink_leak",
      availability = "zigbee2mqtt/sink_leak/availability",
      availability_field = "state",
    })
    env.advance(6000)
  end,
  describe = function(d)
    check(
      "ONE registration: the driver's own client",
      H.count("SBOS_MODULE_REGISTER") == 1,
      H.count("SBOS_MODULE_REGISTER")
    )
    check(
      "describe: the MQTT bridge (class network)",
      #d.controls == 1 and d.controls[1].id == "mqtt_bridge" and d.controls[1].class == "network"
    )
    check("describe: no query declared", #d.queries == 0)
  end,
  state = function(facts)
    check(
      "state: broker connected, counts",
      facts.broker_connected == true
        and facts.read_only == false
        and facts.devices == 1
        and type(facts.stale_devices) == "number"
        and type(facts.topics_seen) == "number"
        and type(facts.messages_in) == "number",
      JSON:encode(facts)
    )
  end,
  forbid = { "Whitfield", "sink_leak", "zigbee2mqtt/", "mqtt.test.invalid", "pa55", "c4user77" },
})

print("[4] OnDriverDestroyed (attach mode)")
local unregisters = H.count("SBOS_MODULE_UNREGISTER")
local okD, errD = pcall(OnDriverDestroyed)
check("OnDriverDestroyed runs; the helper stops", okD and require("sbos.aireport").mode() == nil, errD)
check(
  "the helper leaves the module client to the driver (which, as before this change, does not unregister it)",
  H.count("SBOS_MODULE_UNREGISTER") == unregisters
)

print("[5] the broker link diagnostics")
OnDriverInit()
OnDriverLateInit()
local d0 = #H.reports("diagnostic")
local sock = connectBroker()
local function codes(from)
  local out = {}
  local dg = H.reports("diagnostic")
  for i = from + 1, #dg do
    out[#out + 1] = dg[i].args.code
  end
  return table.concat(out, ",")
end
check("the broker accepts the login: broker.connected (info)", codes(d0) == "broker.connected", codes(d0))
local d1 = #H.reports("diagnostic")
sock:drop()
check(
  "the link drops: broker.disconnected (warning), as the driver's own Broker Disconnected",
  codes(d1) == "broker.disconnected",
  codes(d1)
)
env.advance(6000) -- the next status paint
check(
  "…the state follows (broker_connected false)",
  H.reports("state")[#H.reports("state")].args.facts.broker_connected == false
)
check("every report valid for AI Core", H.allValid(), select(2, H.allValid()))

R.finish()
