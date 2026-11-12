-- MQTT 3.1.1 packet codec: byte-exact vectors for every packet the client
-- sends, decoding of every packet it receives, the remaining-length varint at
-- its boundaries, partial reads (every possible split point), several
-- packets in one read, and malformed input.
--
-- Run from the driver root: make test

package.path = "src/?.lua;" .. package.path
local P = require("mqtt.packet")

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

local function hex(s)
  return (s:gsub(".", function(c)
    return string.format("%02X ", c:byte())
  end):gsub(" $", ""))
end
local function unhex(h)
  return (h:gsub("%s+", ""):gsub("%x%x", function(x)
    return string.char(tonumber(x, 16))
  end))
end
local function eq(name, got, wantHex)
  check(name, hex(got) == wantHex, hex(got) .. "  (want " .. wantHex .. ")")
end

print("[1] remaining-length varint (spec table 2.4)")
eq("0", P.encodeLength(0), "00")
eq("127", P.encodeLength(127), "7F")
eq("128", P.encodeLength(128), "80 01")
eq("16383", P.encodeLength(16383), "FF 7F")
eq("16384", P.encodeLength(16384), "80 80 01")
eq("2097151", P.encodeLength(2097151), "FF FF 7F")
eq("2097152", P.encodeLength(2097152), "80 80 80 01")
eq("268435455", P.encodeLength(268435455), "FF FF FF 7F")
check("268435456 refused", not pcall(P.encodeLength, 268435456))
check("negative refused", not pcall(P.encodeLength, -1))
for _, n in ipairs({ 0, 1, 127, 128, 300, 16383, 16384, 65535, 2097151, 2097152, 268435455 }) do
  local v, nextPos = P.decodeLength("X" .. P.encodeLength(n), 2)
  check("round trip " .. n, v == n and nextPos == 2 + #P.encodeLength(n), tostring(v))
end
local v, why = P.decodeLength(unhex("80"), 1)
check("half a varint is incomplete, not an error", v == nil and why == "incomplete")
v, why = P.decodeLength(unhex("80 80 80 80 01"), 1)
check("five-byte varint is malformed", v == nil and why == "malformed")

print("[2] client packets, byte exact")
eq(
  "CONNECT no auth",
  P.connect({ client_id = "c4", keepalive = 60 }),
  "10 0E 00 04 4D 51 54 54 04 02 00 3C 00 02 63 34"
)
eq(
  "CONNECT user + password",
  P.connect({ client_id = "c4", keepalive = 60, username = "u", password = "p" }),
  "10 14 00 04 4D 51 54 54 04 C2 00 3C 00 02 63 34 00 01 75 00 01 70"
)
eq(
  "CONNECT user only",
  P.connect({ client_id = "c4", keepalive = 60, username = "u" }),
  "10 11 00 04 4D 51 54 54 04 82 00 3C 00 02 63 34 00 01 75"
)
eq(
  "CONNECT keepalive 300 (0x012C)",
  P.connect({ client_id = "c4", keepalive = 300 }),
  "10 0E 00 04 4D 51 54 54 04 02 01 2C 00 02 63 34"
)
eq(
  "CONNECT with will (qos 1, retain)",
  P.connect({ client_id = "c", keepalive = 10, will = { topic = "w", payload = "bye", qos = 1, retain = true } }),
  "10 15 00 04 4D 51 54 54 04 2E 00 0A 00 01 63 00 01 77 00 03 62 79 65"
)
check("password without user is refused", not pcall(P.connect, { client_id = "c", password = "p" }))
check("NUL in client id refused", not pcall(P.connect, { client_id = "a\0b" }))
eq("PUBLISH qos0", P.publish({ topic = "a/b", payload = "hi" }), "30 07 00 03 61 2F 62 68 69")
eq(
  "PUBLISH qos1 retain id 10",
  P.publish({ topic = "a/b", payload = "x", qos = 1, retain = true, id = 10 }),
  "33 08 00 03 61 2F 62 00 0A 78"
)
eq(
  "PUBLISH qos1 dup",
  P.publish({ topic = "a/b", payload = "x", qos = 1, dup = true, id = 10 }),
  "3A 08 00 03 61 2F 62 00 0A 78"
)
eq("PUBLISH empty payload", P.publish({ topic = "t" }), "30 03 00 01 74")
check("PUBLISH qos 2 refused", not pcall(P.publish, { topic = "t", qos = 2, id = 1 }))
check("PUBLISH qos 1 without id refused", not pcall(P.publish, { topic = "t", qos = 1 }))
check("PUBLISH to a wildcard refused", not pcall(P.publish, { topic = "a/#" }))
check("PUBLISH to empty topic refused", not pcall(P.publish, { topic = "" }))
eq("PUBACK", P.puback(10), "40 02 00 0A")
eq("SUBSCRIBE one filter", P.subscribe(1, { { filter = "a/#", qos = 1 } }), "82 08 00 01 00 03 61 2F 23 01")
eq("SUBSCRIBE two filters (plain strings = QoS 0)", P.subscribe(2, { "a", "b" }), "82 0A 00 02 00 01 61 00 00 01 62 00")
check("SUBSCRIBE with no filters refused", not pcall(P.subscribe, 1, {}))
check("SUBSCRIBE id 0 refused", not pcall(P.subscribe, 0, { "a" }))
eq("UNSUBSCRIBE", P.unsubscribe(2, { "a/b" }), "A2 07 00 02 00 03 61 2F 62")
eq("PINGREQ", P.pingreq(), "C0 00")
eq("PINGRESP", P.pingresp(), "D0 00")
eq("DISCONNECT", P.disconnect(), "E0 00")
eq("CONNACK accepted", P.connack(false, 0), "20 02 00 00")
eq("CONNACK session present, refused 5", P.connack(true, 5), "20 02 01 05")
eq("SUBACK", P.suback(1, { 1 }), "90 03 00 01 01")

print("[3] a large PUBLISH uses a multi-byte length")
do
  local payload = string.rep("z", 200)
  local bytes = P.publish({ topic = "t", payload = payload })
  eq("header of a 200-byte payload", bytes:sub(1, 3), "30 CB 01") -- 203 = 0xCB 0x01
  local parser = P.newParser()
  local pkts, err = parser:feed(bytes)
  check("decodes", err == nil and #pkts == 1 and pkts[1].payload == payload and pkts[1].topic == "t")
end

print("[4] decoding what a broker sends")
do
  local parser = P.newParser()
  local pkts, err = parser:feed(unhex("20 02 00 00"))
  check("CONNACK", err == nil and pkts[1].type == "connack" and pkts[1].accepted and not pkts[1].session_present)
  pkts = parser:feed(unhex("20 02 01 00"))
  check("CONNACK session present", pkts[1].session_present == true)
  pkts = parser:feed(unhex("20 02 00 04"))
  check("CONNACK bad credentials", pkts[1].code == 4 and not pkts[1].accepted and pkts[1].text:find("user name"))
  pkts = parser:feed(unhex("30 07 00 03 61 2F 62 68 69"))
  check(
    "PUBLISH qos0",
    pkts[1].type == "publish"
      and pkts[1].topic == "a/b"
      and pkts[1].payload == "hi"
      and pkts[1].qos == 0
      and not pkts[1].retain
  )
  pkts = parser:feed(unhex("33 08 00 03 61 2F 62 00 0A 78"))
  check(
    "PUBLISH qos1 retain",
    pkts[1].qos == 1 and pkts[1].retain and pkts[1].id == 10 and pkts[1].payload == "x" and not pkts[1].dup
  )
  pkts = parser:feed(unhex("3A 08 00 03 61 2F 62 00 0A 78"))
  check("PUBLISH dup flag", pkts[1].dup == true)
  pkts = parser:feed(unhex("30 03 00 01 74"))
  check("PUBLISH empty payload", pkts[1].payload == "" and pkts[1].topic == "t")
  pkts = parser:feed(unhex("40 02 00 0A"))
  check("PUBACK", pkts[1].type == "puback" and pkts[1].id == 10)
  pkts = parser:feed(unhex("90 04 00 01 01 80"))
  check(
    "SUBACK with a refusal",
    pkts[1].type == "suback" and pkts[1].id == 1 and pkts[1].codes[1] == 1 and pkts[1].codes[2] == 0x80
  )
  pkts = parser:feed(unhex("B0 02 00 02"))
  check("UNSUBACK", pkts[1].type == "unsuback" and pkts[1].id == 2)
  pkts = parser:feed(unhex("D0 00"))
  check("PINGRESP", pkts[1].type == "pingresp")
  check("parser alive after all that", parser.failed == nil and parser:pending() == 0)
end

print("[5] the client's own packets decode back (the tests play a broker)")
do
  local parser = P.newParser()
  local pkts = parser:feed(P.connect({ client_id = "me", keepalive = 45, username = "bob", password = "s3cret" }))
  local c = pkts[1]
  check(
    "CONNECT fields",
    c.type == "connect"
      and c.client_id == "me"
      and c.keepalive == 45
      and c.username == "bob"
      and c.password == "s3cret"
      and c.clean_session
  )
  pkts = parser:feed(
    P.connect({ client_id = "me", keepalive = 45, will = { topic = "w", payload = "bye", qos = 1, retain = true } })
  )
  check(
    "CONNECT will",
    pkts[1].will.topic == "w" and pkts[1].will.payload == "bye" and pkts[1].will.qos == 1 and pkts[1].will.retain
  )
  pkts = parser:feed(P.subscribe(7, { { filter = "x/+", qos = 1 }, { filter = "y/#", qos = 0 } }))
  check(
    "SUBSCRIBE",
    pkts[1].id == 7
      and #pkts[1].filters == 2
      and pkts[1].filters[1].filter == "x/+"
      and pkts[1].filters[1].qos == 1
      and pkts[1].filters[2].qos == 0
  )
  pkts = parser:feed(P.unsubscribe(8, { "x/+" }))
  check("UNSUBSCRIBE", pkts[1].id == 8 and pkts[1].filters[1] == "x/+")
  pkts = parser:feed(P.pingreq() .. P.disconnect())
  check("PINGREQ and DISCONNECT in one read", pkts[1].type == "pingreq" and pkts[2].type == "disconnect")
end

print("[6] partial reads: every split point of a stream of packets")
do
  local stream = P.connack(false, 0)
    .. P.publish({ topic = "zigbee2mqtt/sink_leak", payload = '{"water_leak":true}', retain = true })
    .. P.publish({ topic = "a/b", payload = string.rep("q", 300), qos = 1, id = 3 })
    .. P.suback(1, { 1, 0 })
    .. P.pingresp()
  local allOk = true
  for split = 1, #stream - 1 do
    local parser = P.newParser()
    local a, errA = parser:feed(stream:sub(1, split))
    local b, errB = parser:feed(stream:sub(split + 1))
    local all = {}
    for _, p in ipairs(a) do
      all[#all + 1] = p
    end
    for _, p in ipairs(b) do
      all[#all + 1] = p
    end
    if
      errA ~= nil
      or errB ~= nil
      or #all ~= 5
      or all[1].type ~= "connack"
      or all[2].payload ~= '{"water_leak":true}'
      or all[3].payload ~= string.rep("q", 300)
      or all[4].type ~= "suback"
      or all[5].type ~= "pingresp"
      or parser:pending() ~= 0
    then
      allOk = false
      print("    split at " .. split .. " failed")
      break
    end
  end
  check("two-chunk split at every byte offset", allOk)

  local parser = P.newParser()
  local got = {}
  for i = 1, #stream do
    for _, p in ipairs((parser:feed(stream:sub(i, i)))) do
      got[#got + 1] = p
    end
  end
  check("one byte at a time", #got == 5 and got[3].payload == string.rep("q", 300) and parser:pending() == 0)

  parser = P.newParser()
  local pkts = parser:feed(stream)
  check("all five in one read", #pkts == 5)
  pkts = parser:feed(stream .. stream:sub(5, 11))
  check("five complete + 7 bytes of the next packet held back", #pkts == 5 and parser:pending() == 7)
  pkts = parser:feed(stream:sub(12))
  check("the held-back bytes complete into the rest of the stream", #pkts == 4 and parser:pending() == 0, #pkts)
end

print("[7] malformed input")
local function bad(name, bytesHex, wantFragment)
  local parser = P.newParser()
  local pkts, err = parser:feed(unhex(bytesHex))
  check(name, err ~= nil and (wantFragment == nil or err:find(wantFragment, 1, true) ~= nil), tostring(err))
  local more, err2 = parser:feed(unhex("D0 00"))
  check(name .. ": parser stays dead", #more == 0 and err2 ~= nil)
  return pkts
end
bad("reserved type 0", "00 00", "reserved")
bad("reserved type 15", "F0 00", "reserved")
bad("five-byte remaining length", "30 80 80 80 80 01", "remaining length")
bad("CONNACK of the wrong size", "20 03 00 00 00", "CONNACK")
bad("CONNACK return code 9", "20 02 00 09", "return code")
bad("CONNACK reserved bits", "20 02 02 00", "reserved")
bad("PUBLISH qos 3", "36 05 00 01 74 00 01", "QoS 3")
bad("PUBLISH topic longer than the body", "30 04 00 09 61 62", "truncated")
bad("PUBLISH with empty topic", "30 02 00 00", "empty")
bad("PUBLISH with wildcard topic", "30 04 00 02 61 23", "wildcard")
bad("PUBLISH qos1 id 0", "32 05 00 01 74 00 00", "id 0")
bad("PUBLISH qos1 missing id", "32 03 00 01 74", "truncated")
bad("PUBACK too long", "40 03 00 01 00", "PUBACK")
bad("PINGRESP with a body", "D0 01 00", "PINGRESP")
bad("SUBACK with no codes", "90 02 00 01", "SUBACK")
bad("SUBACK with a bad code", "90 03 00 01 07", "return code")
bad("PUBREL with wrong flags", "60 02 00 01", "flags")
bad("SUBSCRIBE with wrong flags", "80 06 00 01 00 01 61 00", "flags")
bad("NUL inside a topic", "30 05 00 03 61 00 62", "truncated")
do
  local parser = P.newParser({ max_packet = 100 })
  local _, err = parser:feed(P.publish({ topic = "t", payload = string.rep("x", 200) }):sub(1, 5))
  check("oversize packet refused from its header alone", err ~= nil and err:find("exceeds"), tostring(err))
end
do
  -- A good packet before a bad one is still delivered.
  local parser = P.newParser()
  local pkts, err = parser:feed(P.pingresp() .. unhex("F0 00"))
  check("packets before the error are returned", #pkts == 1 and pkts[1].type == "pingresp" and err ~= nil)
  parser:reset()
  pkts, err = parser:feed(P.pingresp())
  check("reset revives the parser", #pkts == 1 and err == nil)
end

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
