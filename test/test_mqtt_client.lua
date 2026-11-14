-- MQTT client session against a scripted fake broker: login, subscriptions
-- (batching, refusals, re-subscribe after a reconnect), QoS 0/1 in and out,
-- fragmented and coalesced reads, keepalive (PINGREQ, silence detection),
-- login refusals, malformed input, and that the password never leaves the
-- CONNECT packet.
--
-- Run from the driver root: make test

package.path = "src/?.lua;vendor/?.lua;" .. package.path
local P = require("mqtt.packet")
local Client = require("mqtt.client")

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

local SECRET = "pa55-secret-xyz"

local function newRig(overrides)
  local rig = { t = 1000, wire = {}, states = {}, messages = {}, subscribed = {}, closes = {}, errors = {} }
  local parser = P.newParser()
  rig.parser = parser
  local opts = {
    client_id = "sbos-test",
    username = "bob",
    password = SECRET,
    keepalive = 60,
    now = function()
      return rig.t
    end,
    write = function(bytes)
      if rig.writeFails then
        return false
      end
      local pkts, err = parser:feed(bytes)
      assert(err == nil, "client wrote something undecodable: " .. tostring(err))
      for _, p in ipairs(pkts) do
        rig.wire[#rig.wire + 1] = p
      end
      return true
    end,
    close = function(reason)
      rig.closes[#rig.closes + 1] = reason
    end,
    onMessage = function(topic, payload, info)
      if rig.throwInHandler then
        error("handler exploded")
      end
      rig.messages[#rig.messages + 1] = { topic = topic, payload = payload, retain = info.retain, qos = info.qos }
    end,
    onState = function(state, detail, info)
      rig.states[#rig.states + 1] = { state = state, detail = detail, info = info }
    end,
    onSubscribed = function(filter, granted)
      rig.subscribed[#rig.subscribed + 1] = { filter = filter, granted = granted }
    end,
    onError = function(text)
      rig.errors[#rig.errors + 1] = text
    end,
  }
  for k, v in pairs(overrides or {}) do
    opts[k] = v
  end
  rig.client = Client.new(opts)
  function rig.take(kind)
    local out = {}
    local keep = {}
    for _, p in ipairs(rig.wire) do
      if p.type == kind then
        out[#out + 1] = p
      else
        keep[#keep + 1] = p
      end
    end
    rig.wire = keep
    return out
  end
  function rig.lastState()
    return rig.states[#rig.states] and rig.states[#rig.states].state
  end
  function rig.connect()
    rig.client:open()
    rig.client:receive(P.connack(false, 0))
  end
  return rig
end

print("[1] login")
do
  local r = newRig()
  r.client:open()
  local c = r.take("connect")[1]
  check(
    "CONNECT sent with the configured identity",
    c
      and c.client_id == "sbos-test"
      and c.username == "bob"
      and c.password == SECRET
      and c.keepalive == 60
      and c.clean_session
  )
  check("state is connecting", r.lastState() == "connecting")
  r.client:receive(P.connack(false, 0))
  check("CONNACK accepted: connected", r.lastState() == "connected" and r.client:isConnected())
  check(
    "no secret in any state detail",
    (function()
      for _, s in ipairs(r.states) do
        if tostring(s.detail):find(SECRET, 1, true) then
          return false
        end
      end
      return true
    end)()
  )
end

print("[2] login refused")
do
  for _, case in ipairs({
    { code = 4, permanent = true, text = "user name or password" },
    { code = 5, permanent = true, text = "not authorised" },
    { code = 3, permanent = false, text = "unavailable" },
    { code = 2, permanent = false, text = "identifier" },
  }) do
    local r = newRig()
    r.client:open()
    r.client:receive(P.connack(false, case.code))
    local s = r.states[#r.states]
    check(
      "code " .. case.code .. " refused" .. (case.permanent and " (permanent)" or " (retry)"),
      s.state == "refused"
        and (s.info.permanent == case.permanent)
        and s.detail:find(case.text, 1, true)
        and #r.closes == 1,
      s.detail
    )
    check(
      "code " .. case.code .. ": not connected, no secret in the message",
      not r.client:isConnected() and not s.detail:find(SECRET, 1, true)
    )
    r.client:closed("socket closed")
    check("code " .. case.code .. ": the socket-closed echo is not announced twice", #r.states == 2, #r.states)
  end
  local r = newRig()
  r.client:open()
  r.t = r.t + 14
  r.client:tick()
  check("no timeout yet at 14 s", r.lastState() == "connecting")
  r.t = r.t + 2
  r.client:tick()
  check("no CONNACK for 15 s fails the attempt", r.lastState() == "failed" and #r.closes == 1)
  r = newRig()
  r.client:open()
  r.client:receive(P.pingresp())
  check(
    "anything but CONNACK first is a protocol error",
    r.lastState() == "failed" and r.states[#r.states].detail:find("before CONNACK")
  )
  r = newRig()
  r.writeFails = true
  r.client:open()
  check("a socket that will not take the CONNECT fails", r.lastState() == "failed")
  r = newRig({ username = "", password = "x" })
  r.client:open()
  check(
    "password without a user name fails with a readable reason",
    r.lastState() == "failed" and r.states[#r.states].detail:find("password without a user name"),
    r.states[#r.states].detail
  )
  check("...and that reason does not echo the password", not tostring(r.states[#r.states].detail):find("x$"))
end

print("[3] subscriptions")
do
  local r = newRig()
  check("subscribe before connecting is accepted", r.client:subscribe("zigbee2mqtt/sink_leak"))
  r.client:subscribe("zigbee2mqtt/+/availability")
  check("invalid filter refused", select(1, r.client:subscribe("a/#/b")) == false)
  r.connect()
  local subs = r.take("subscribe")
  check(
    "one SUBSCRIBE after CONNACK with both filters at QoS 1",
    #subs == 1
      and #subs[1].filters == 2
      and subs[1].filters[1].qos == 1
      and subs[1].filters[2].filter == "zigbee2mqtt/+/availability"
  )
  r.client:receive(P.suback(subs[1].id, { 1, 0x80 }))
  check(
    "SUBACK reported per filter, refusal as nil",
    #r.subscribed == 2 and r.subscribed[1].granted == 1 and r.subscribed[2].granted == nil
  )
  r.client:subscribe("late/one")
  subs = r.take("subscribe")
  check("subscribing while connected sends at once", #subs == 1 and subs[1].filters[1].filter == "late/one")
  r.client:subscribe("late/one")
  check("subscribing twice sends nothing", #r.take("subscribe") == 0)
  r.client:unsubscribe("late/one")
  local un = r.take("unsubscribe")
  check("unsubscribe", #un == 1 and un[1].filters[1] == "late/one" and #r.client:subscriptions() == 2)
  local rejected = r.client:setSubscriptions({ "keep/me", "zigbee2mqtt/sink_leak", "bad/#/x" })
  check(
    "setSubscriptions replaces the set",
    #rejected == 1 and #r.client:subscriptions() == 2,
    table.concat(r.client:subscriptions(), ",")
  )
  r.take("subscribe")
  r.take("unsubscribe")
  -- reconnect
  r.client:closed("lost")
  check("closed reported once", r.lastState() == "closed")
  r.client:open()
  r.client:receive(P.connack(false, 0))
  subs = r.take("subscribe")
  local names = {}
  for _, f in ipairs(subs[1] and subs[1].filters or {}) do
    names[#names + 1] = f.filter
  end
  table.sort(names)
  check(
    "re-subscribes everything after a reconnect",
    #subs == 1 and table.concat(names, ",") == "keep/me,zigbee2mqtt/sink_leak",
    table.concat(names, ",")
  )
  check("reconnect counted", r.client.stats.reconnects == 1)
end
do
  local r = newRig()
  for i = 1, 45 do
    r.client:subscribe("t/" .. i)
  end
  r.connect()
  local subs = r.take("subscribe")
  check("45 filters go out in batches of 20", #subs == 3 and #subs[1].filters == 20 and #subs[3].filters == 5)
  local ids = {}
  for _, s in ipairs(subs) do
    ids[s.id] = true
  end
  check(
    "each batch has its own packet id",
    (function()
      local n = 0
      for _ in pairs(ids) do
        n = n + 1
      end
      return n == 3
    end)()
  )
  r.client:receive(P.suback(subs[3].id, { 0, 0, 0, 0, 0 }))
  check("a SUBACK maps back to its own batch", r.subscribed[1].filter == "t/41")
end

print("[3b] an oversize retained message does not kill the session")
do
  local r = newRig()
  r.connect()
  local big = P.publish({
    topic = "zigbee2mqtt/bridge/devices",
    payload = string.rep("d", 300 * 1000),
    retain = true,
  })
  for i = 1, #big, 4000 do
    r.client:receive(big:sub(i, i + 3999))
  end
  check("still connected, nothing delivered", r.lastState() == "connected" and #r.messages == 0)
  r.client:receive(P.publish({ topic = "zigbee2mqtt/lamp", payload = '{"state":"ON"}' }))
  check("the next normal publish IS delivered", #r.messages == 1 and r.messages[1].topic == "zigbee2mqtt/lamp")
  check("counted and logged without the payload", r.client.stats.dropped_oversize == 1 and #r.errors == 1)
  local leaked = false
  for _, e in ipairs(r.errors) do
    if tostring(e):find("ddddd", 1, true) then
      leaked = true
    end
  end
  check("log line carries no payload", not leaked)
end

print("[4] messages in")
do
  local r = newRig()
  r.connect()
  r.client:receive(P.publish({ topic = "zigbee2mqtt/sink_leak", payload = '{"water_leak":true}' }))
  check(
    "QoS 0 delivered",
    #r.messages == 1
      and r.messages[1].topic == "zigbee2mqtt/sink_leak"
      and r.messages[1].payload == '{"water_leak":true}'
  )
  check("QoS 0 is not acknowledged", #r.take("puback") == 0)
  r.client:receive(P.publish({ topic = "a/b", payload = "x", qos = 1, id = 77, retain = true }))
  local acks = r.take("puback")
  check(
    "QoS 1 delivered, retain flag kept, PUBACKed with its id",
    #r.messages == 2 and r.messages[2].retain and r.messages[2].qos == 1 and #acks == 1 and acks[1].id == 77
  )
  local bytes = P.publish({ topic = "frag/topic", payload = string.rep("p", 500) })
    .. P.publish({ topic = "second", payload = "2" })
  r.client:receive(bytes:sub(1, 3))
  r.client:receive(bytes:sub(4, 300))
  check("a half-delivered packet is held", #r.messages == 2)
  r.client:receive(bytes:sub(301))
  check(
    "completed across three reads, the next one in the same read",
    #r.messages == 4 and #r.messages[3].payload == 500 and r.messages[4].topic == "second"
  )
  r.client:receive(
    P.publish({ topic = "t", payload = "1" })
      .. P.publish({ topic = "t", payload = "2" })
      .. P.publish({ topic = "t", payload = "3" })
  )
  check("three packets in one read", #r.messages == 7 and r.messages[7].payload == "3")
  r.throwInHandler = true
  r.client:receive(
    P.publish({ topic = "t", payload = "boom" }) .. P.publish({ topic = "t", payload = "after", qos = 1, id = 5 })
  )
  check(
    "a failing message handler does not kill the session",
    r.client:isConnected() and #r.errors == 2 and #r.take("puback") == 1,
    #r.errors
  )
  r.throwInHandler = false
  r.client:receive(P.publish({ topic = "t", payload = "x", qos = 1, id = 9 }):sub(1, 6))
  r.client:receive(P.publish({ topic = "t", payload = "x", qos = 1, id = 9 }):sub(7))
  check("QoS 1 split mid-packet", #r.take("puback") == 1)
end

print("[5] messages out")
do
  local r = newRig()
  local ok, why = r.client:publish("a/b", "x")
  check(
    "publish while offline is refused, not queued",
    ok == false and why:find("not connected") and r.client.stats.dropped_offline == 1
  )
  r.connect()
  r.take("subscribe")
  ok = r.client:publish("zigbee2mqtt/lamp/set", '{"state":"ON"}')
  local pub = r.take("publish")[1]
  check(
    "QoS 0 publish",
    ok and pub.topic == "zigbee2mqtt/lamp/set" and pub.payload == '{"state":"ON"}' and pub.qos == 0 and not pub.retain
  )
  ok = r.client:publish("a/b", "retained", { retain = true })
  check("retain flag", r.take("publish")[1].retain == true)
  ok = r.client:publish("a/b", "q1", { qos = 1 })
  pub = r.take("publish")[1]
  check(
    "QoS 1 publish carries an id and waits for PUBACK",
    ok and pub.qos == 1 and pub.id and r.client.inflight[pub.id] ~= nil
  )
  r.client:receive(P.puback(pub.id))
  check("PUBACK clears it", r.client.inflight[pub.id] == nil)
  r.client:publish("a/b", "q1", { qos = 1 })
  r.t = r.t + 16
  r.client:tick()
  check(
    "an unacknowledged QoS 1 publish is given up after 15 s and counted",
    next(r.client.inflight) == nil and r.client.stats.puback_missed == 1
  )
  check("wildcard topic refused", r.client:publish("a/+", "x") == false)
  check("QoS 2 refused", r.client:publish("a/b", "x", { qos = 2 }) == false)
  check("empty payload allowed", r.client:publish("a/b", "") == true and r.take("publish")[2].payload == "")
  r.take("publish")
  local ids = {}
  for i = 1, 64 do
    assert(r.client:publish("a/b", tostring(i), { qos = 1 }))
  end
  ok, why = r.client:publish("a/b", "65", { qos = 1 })
  check("64 unacknowledged QoS 1 publishes is the ceiling", ok == false and why:find("unacknowledged"))
  r.client:closed("lost")
  check(
    "a lost connection counts the unacknowledged ones",
    r.client.stats.puback_missed == 65 and next(r.client.inflight) == nil
  )
end

print("[6] keepalive")
do
  local r = newRig({ keepalive = 40 })
  r.connect()
  r.take("subscribe")
  r.t = r.t + 29
  r.client:tick()
  check("quiet for 29 s of a 40 s keepalive: no ping yet", #r.take("pingreq") == 0)
  r.t = r.t + 1
  r.client:tick()
  check("at 75 percent of the keepalive a PINGREQ goes out", #r.take("pingreq") == 1)
  r.client:tick()
  check("only one ping while it is unanswered", #r.take("pingreq") == 0)
  r.client:receive(P.pingresp())
  r.t = r.t + 30
  r.client:tick()
  check("PINGRESP clears it; the next ping comes 30 s later", #r.take("pingreq") == 1 and r.client:isConnected())
  r.t = r.t + 19
  r.client:tick()
  check("still waiting 19 s after the ping", r.client:isConnected())
  r.t = r.t + 2
  r.client:tick()
  check(
    "no answer within half a keepalive: connection declared dead",
    r.lastState() == "failed" and #r.closes == 1 and r.states[#r.states].detail:find("keepalive")
  )
end
do
  local r = newRig({ keepalive = 40 })
  r.connect()
  r.take("subscribe")
  r.t = r.t + 30
  r.client:tick()
  r.take("pingreq")
  r.t = r.t + 10
  r.client:receive(P.publish({ topic = "x", payload = "y" }))
  r.client:tick()
  check("any packet from the broker clears an unanswered ping (no failure at +10 s)", r.client:isConnected())
  r.t = r.t + 25
  r.client:tick()
  check(
    "...and the next quiet spell pings again instead of failing",
    r.client:isConnected() and #r.take("pingreq") == 1
  )
end
do
  local r = newRig({ keepalive = 40 })
  r.connect()
  r.take("subscribe")
  r.t = r.t + 20
  r.client:publish("a/b", "x")
  r.take("publish")
  r.t = r.t + 20
  r.client:tick()
  check("outgoing traffic counts as activity: no ping 20 s after a publish", #r.take("pingreq") == 0)
  local z = newRig({ keepalive = 0 })
  z.connect()
  z.t = z.t + 100000
  z.client:tick()
  check("keepalive 0 disables pings and the silence check", #z.take("pingreq") == 0 and z.client:isConnected())
  check(
    "keepalive 0 is what CONNECT says",
    (function()
      local zz = newRig({ keepalive = 0 })
      zz.client:open()
      return zz.take("connect")[1].keepalive == 0
    end)()
  )
end

print("[7] protocol errors and goodbye")
do
  local r = newRig()
  r.connect()
  r.client:receive(string.char(0xF0, 0))
  check(
    "a reserved packet type fails the session once",
    r.lastState() == "failed" and #r.closes == 1 and r.states[#r.states].detail:find("protocol error")
  )
  r.client:receive(P.pingresp())
  r.client:closed("echo")
  check("nothing more is announced", #r.states == 3, #r.states)

  r = newRig()
  r.connect()
  r.client:receive(string.char(0x34, 5, 0, 1, 116, 0, 1)) -- QoS 2 PUBLISH
  check("QoS 2 delivery is refused", r.lastState() == "failed" and r.states[#r.states].detail:find("QoS 2"))

  r = newRig()
  r.connect()
  r.client:receive(P.connack(false, 0))
  check("a second CONNACK is an error", r.lastState() == "failed")

  r = newRig()
  r.connect()
  r.client:receive(P.pingresp() .. string.char(0xF0, 0) .. P.publish({ topic = "t", payload = "late" }))
  check("packets after the bad one in the same read are not delivered", #r.messages == 0 and r.lastState() == "failed")

  r = newRig()
  r.connect()
  r.take("subscribe")
  r.client:disconnect()
  check("disconnect says goodbye", #r.take("disconnect") == 1)
  r.client:closed("done")
  check("a deliberate disconnect is not announced as a loss", r.lastState() == "connected")
end

print("[8] the password stays in CONNECT")
do
  local r = newRig()
  r.client:subscribe("a/b")
  r.connect()
  r.client:publish("a/b", "x")
  r.client:receive(P.publish({ topic = "a/b", payload = "y" }))
  r.t = r.t + 60
  r.client:tick()
  r.client:closed("reset")
  local leaked = false
  for _, s in ipairs(r.states) do
    if tostring(s.detail):find(SECRET, 1, true) then
      leaked = true
    end
  end
  for _, e in ipairs(r.errors) do
    if e:find(SECRET, 1, true) then
      leaked = true
    end
  end
  check("no state detail or error text contains the password", not leaked)
  local json = ""
  for k, v in pairs(r.client) do
    if type(v) ~= "table" and type(v) ~= "function" and tostring(v):find(SECRET, 1, true) then
      json = k
    end
  end
  check("the session keeps no copy of the password in its own fields", json == "")
end

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
