--- MQTT 3.1.1 packet codec (pure: no Control4 globals, no sockets).
---
--- Encodes the packets a client sends (CONNECT, PUBLISH, PUBACK, SUBSCRIBE,
--- UNSUBSCRIBE, PINGREQ, DISCONNECT) and decodes the ones a client receives
--- (CONNACK, PUBLISH, PUBACK, SUBACK, UNSUBACK, PINGRESP). The decoder also
--- reads the client packets back, which is what the tests use to play a broker.
---
--- Out of scope on purpose: MQTT 5 and QoS 2 (a QoS 2 PUBLISH from a broker is
--- refused as a protocol error; the client subscribes at QoS 1 at most, so a
--- conforming broker never sends one).
---
--- The Parser buffers across TCP reads: one read may carry half a packet or
--- several packets, and the parser hands back exactly the complete ones.

local M = {}

M.TYPE = {
  CONNECT = 1,
  CONNACK = 2,
  PUBLISH = 3,
  PUBACK = 4,
  PUBREC = 5,
  PUBREL = 6,
  PUBCOMP = 7,
  SUBSCRIBE = 8,
  SUBACK = 9,
  UNSUBSCRIBE = 10,
  UNSUBACK = 11,
  PINGREQ = 12,
  PINGRESP = 13,
  DISCONNECT = 14,
}

local NAMES = {}
for name, code in pairs(M.TYPE) do
  NAMES[code] = name:lower()
end

M.MAX_REMAINING = 268435455 -- 4-byte remaining-length ceiling in the spec
M.MAX_STRING = 65535
M.DEFAULT_MAX_PACKET = 256 * 1024

M.CONNACK_TEXT = {
  [0] = "accepted",
  [1] = "unacceptable protocol version",
  [2] = "client identifier rejected",
  [3] = "broker unavailable",
  [4] = "bad user name or password",
  [5] = "not authorised",
}

local char, byte = string.char, string.byte

-- ─── Primitive encoders ────────────────────────────────────────────────────

--- Remaining-length varint: 7 bits per byte, high bit = more follows.
function M.encodeLength(n)
  if type(n) ~= "number" or n < 0 or n > M.MAX_REMAINING or n ~= math.floor(n) then
    error("remaining length out of range: " .. tostring(n), 2)
  end
  local out = {}
  repeat
    local digit = n % 128
    n = math.floor(n / 128)
    if n > 0 then
      digit = digit + 128
    end
    out[#out + 1] = char(digit)
  until n == 0
  return table.concat(out)
end

--- Reads a remaining-length varint at `pos`.
--- @return number|nil value, number|string nextPos   nil + "incomplete" when more bytes are needed;
---         nil + "malformed" when the varint runs past four bytes.
function M.decodeLength(buf, pos)
  local multiplier, value = 1, 0
  for i = 0, 3 do
    local b = byte(buf, pos + i)
    if b == nil then
      return nil, "incomplete"
    end
    value = value + (b % 128) * multiplier
    if b < 128 then
      return value, pos + i + 1
    end
    multiplier = multiplier * 128
  end
  return nil, "malformed"
end

local function u16(n)
  return char(math.floor(n / 256) % 256, n % 256)
end

local function readU16(s, pos)
  local hi, lo = byte(s, pos, pos + 1)
  if lo == nil then
    return nil
  end
  return hi * 256 + lo
end

--- Length-prefixed UTF-8 string. MQTT forbids U+0000 in these.
local function utf(s, what)
  s = tostring(s == nil and "" or s)
  if #s > M.MAX_STRING then
    error((what or "string") .. " longer than 65535 bytes", 3)
  end
  if s:find("\0", 1, true) then
    error((what or "string") .. " contains a NUL character", 3)
  end
  return u16(#s) .. s
end

local function packet(typeCode, flags, body)
  return char(typeCode * 16 + (flags or 0)) .. M.encodeLength(#body) .. body
end

-- ─── Encoders ──────────────────────────────────────────────────────────────

--- @param o table { client_id, keepalive (s), username?, password?, clean_session? (default true),
---                  will? = { topic, payload, qos, retain } }
function M.connect(o)
  o = o or {}
  local flags = 0
  if o.clean_session ~= false then
    flags = flags + 0x02
  end
  local hasUser = o.username ~= nil and o.username ~= ""
  local hasPass = o.password ~= nil and o.password ~= ""
  if hasPass and not hasUser then
    error("MQTT 3.1.1 cannot send a password without a user name", 2)
  end
  if hasUser then
    flags = flags + 0x80
  end
  if hasPass then
    flags = flags + 0x40
  end
  local willPart = ""
  if o.will then
    local qos = o.will.qos or 0
    if qos < 0 or qos > 2 then
      error("will QoS must be 0, 1 or 2", 2)
    end
    flags = flags + 0x04 + qos * 8 + (o.will.retain and 0x20 or 0)
    willPart = utf(o.will.topic, "will topic") .. u16(#(o.will.payload or "")) .. (o.will.payload or "")
  end
  local keepalive = tonumber(o.keepalive) or 60
  if keepalive < 0 or keepalive > 65535 then
    error("keepalive must be 0..65535 seconds", 2)
  end
  local body = utf("MQTT")
    .. char(4)
    .. char(flags)
    .. u16(math.floor(keepalive))
    .. utf(o.client_id or "", "client id")
    .. willPart
  if hasUser then
    body = body .. utf(o.username, "user name")
  end
  if hasPass then
    body = body .. u16(#o.password) .. o.password
  end
  return packet(M.TYPE.CONNECT, 0, body)
end

--- @param o table { topic, payload?, qos? (0|1), retain?, dup?, id? (required when qos > 0) }
function M.publish(o)
  local qos = o.qos or 0
  if qos ~= 0 and qos ~= 1 then
    error("only QoS 0 and 1 are supported", 2)
  end
  local topic = tostring(o.topic or "")
  if topic == "" or topic:find("[#+]") then
    error("a PUBLISH topic must be non-empty and carry no wildcard", 2)
  end
  local flags = (o.retain and 1 or 0) + qos * 2 + (o.dup and 8 or 0)
  local body = utf(topic, "topic")
  if qos > 0 then
    if type(o.id) ~= "number" or o.id < 1 or o.id > 65535 then
      error("QoS 1 needs a packet id 1..65535", 2)
    end
    body = body .. u16(o.id)
  end
  return packet(M.TYPE.PUBLISH, flags, body .. tostring(o.payload or ""))
end

function M.puback(id)
  return packet(M.TYPE.PUBACK, 0, u16(id))
end

--- @param id number
--- @param filters table list of { filter = string, qos = 0|1 } or plain strings (QoS 0)
function M.subscribe(id, filters)
  if type(id) ~= "number" or id < 1 or id > 65535 then
    error("SUBSCRIBE needs a packet id 1..65535", 2)
  end
  if #filters == 0 then
    error("SUBSCRIBE needs at least one filter", 2)
  end
  local parts = { u16(id) }
  for _, f in ipairs(filters) do
    local filter, qos = f, 0
    if type(f) == "table" then
      filter, qos = f.filter, f.qos or 0
    end
    if qos ~= 0 and qos ~= 1 then
      error("only QoS 0 and 1 are supported", 2)
    end
    parts[#parts + 1] = utf(filter, "topic filter") .. char(qos)
  end
  return packet(M.TYPE.SUBSCRIBE, 2, table.concat(parts))
end

function M.unsubscribe(id, filters)
  local parts = { u16(id) }
  for _, filter in ipairs(filters) do
    parts[#parts + 1] = utf(filter, "topic filter")
  end
  return packet(M.TYPE.UNSUBSCRIBE, 2, table.concat(parts))
end

function M.pingreq()
  return char(0xC0, 0x00)
end

function M.pingresp()
  return char(0xD0, 0x00)
end

function M.disconnect()
  return char(0xE0, 0x00)
end

-- Broker-side encoders, used by the tests to play a broker.

function M.connack(sessionPresent, code)
  return packet(M.TYPE.CONNACK, 0, char(sessionPresent and 1 or 0, code or 0))
end

function M.suback(id, codes)
  local body = u16(id)
  for _, c in ipairs(codes) do
    body = body .. char(c)
  end
  return packet(M.TYPE.SUBACK, 0, body)
end

function M.unsuback(id)
  return packet(M.TYPE.UNSUBACK, 0, u16(id))
end

-- ─── Body decoders ─────────────────────────────────────────────────────────

local function readString(body, pos)
  local len = readU16(body, pos)
  if len == nil or pos + 1 + len > #body then
    return nil
  end
  local s = body:sub(pos + 2, pos + 1 + len)
  if s:find("\0", 1, true) then
    return nil
  end
  return s, pos + 2 + len
end

local EXACT_FLAGS = {
  [M.TYPE.CONNECT] = 0,
  [M.TYPE.CONNACK] = 0,
  [M.TYPE.PUBACK] = 0,
  [M.TYPE.PUBREC] = 0,
  [M.TYPE.PUBREL] = 2,
  [M.TYPE.PUBCOMP] = 0,
  [M.TYPE.SUBSCRIBE] = 2,
  [M.TYPE.SUBACK] = 0,
  [M.TYPE.UNSUBSCRIBE] = 2,
  [M.TYPE.UNSUBACK] = 0,
  [M.TYPE.PINGREQ] = 0,
  [M.TYPE.PINGRESP] = 0,
  [M.TYPE.DISCONNECT] = 0,
}

local DECODERS = {}

DECODERS[M.TYPE.CONNACK] = function(_, body)
  if #body ~= 2 then
    return nil, "CONNACK must be 2 bytes"
  end
  local flags, code = byte(body, 1, 2)
  if flags > 1 then
    return nil, "CONNACK reserved flag bits set"
  end
  if code > 5 then
    return nil, "CONNACK return code " .. code .. " is not defined"
  end
  return {
    type = "connack",
    session_present = flags == 1,
    code = code,
    text = M.CONNACK_TEXT[code],
    accepted = code == 0,
  }
end

DECODERS[M.TYPE.PUBLISH] = function(flags, body)
  local qos = math.floor(flags / 2) % 4
  if qos == 3 then
    return nil, "PUBLISH with QoS 3"
  end
  local topic, pos = readString(body, 1)
  if topic == nil then
    return nil, "PUBLISH topic is truncated"
  end
  if topic == "" or topic:find("[#+]") then
    return nil, "PUBLISH topic is empty or carries a wildcard"
  end
  local id
  if qos > 0 then
    id = readU16(body, pos)
    if id == nil then
      return nil, "PUBLISH packet id is truncated"
    end
    if id == 0 then
      return nil, "PUBLISH packet id 0"
    end
    pos = pos + 2
  end
  return {
    type = "publish",
    dup = math.floor(flags / 8) % 2 == 1,
    qos = qos,
    retain = flags % 2 == 1,
    topic = topic,
    id = id,
    payload = body:sub(pos),
  }
end

local function idOnly(name)
  return function(_, body)
    if #body ~= 2 then
      return nil, name:upper() .. " must be 2 bytes"
    end
    return { type = name, id = readU16(body, 1) }
  end
end
DECODERS[M.TYPE.PUBACK] = idOnly("puback")
DECODERS[M.TYPE.PUBREC] = idOnly("pubrec")
DECODERS[M.TYPE.PUBREL] = idOnly("pubrel")
DECODERS[M.TYPE.PUBCOMP] = idOnly("pubcomp")
DECODERS[M.TYPE.UNSUBACK] = idOnly("unsuback")

DECODERS[M.TYPE.SUBACK] = function(_, body)
  if #body < 3 then
    return nil, "SUBACK carries no return codes"
  end
  local codes = {}
  for i = 3, #body do
    local c = byte(body, i)
    if not (c == 0 or c == 1 or c == 2 or c == 0x80) then
      return nil, "SUBACK return code " .. c .. " is not defined"
    end
    codes[#codes + 1] = c
  end
  return { type = "suback", id = readU16(body, 1), codes = codes }
end

local function emptyBody(name)
  return function(_, body)
    if #body ~= 0 then
      return nil, name:upper() .. " must have no body"
    end
    return { type = name }
  end
end
DECODERS[M.TYPE.PINGREQ] = emptyBody("pingreq")
DECODERS[M.TYPE.PINGRESP] = emptyBody("pingresp")
DECODERS[M.TYPE.DISCONNECT] = emptyBody("disconnect")

DECODERS[M.TYPE.SUBSCRIBE] = function(_, body)
  local id = readU16(body, 1)
  if id == nil or id == 0 then
    return nil, "SUBSCRIBE packet id missing or 0"
  end
  local pos, filters = 3, {}
  while pos <= #body do
    local filter, nextPos = readString(body, pos)
    if filter == nil or nextPos > #body then
      return nil, "SUBSCRIBE filter is truncated"
    end
    filters[#filters + 1] = { filter = filter, qos = byte(body, nextPos) }
    pos = nextPos + 1
  end
  if #filters == 0 then
    return nil, "SUBSCRIBE carries no filters"
  end
  return { type = "subscribe", id = id, filters = filters }
end

DECODERS[M.TYPE.UNSUBSCRIBE] = function(_, body)
  local id = readU16(body, 1)
  if id == nil or id == 0 then
    return nil, "UNSUBSCRIBE packet id missing or 0"
  end
  local pos, filters = 3, {}
  while pos <= #body do
    local filter, nextPos = readString(body, pos)
    if filter == nil then
      return nil, "UNSUBSCRIBE filter is truncated"
    end
    filters[#filters + 1] = filter
    pos = nextPos
  end
  if #filters == 0 then
    return nil, "UNSUBSCRIBE carries no filters"
  end
  return { type = "unsubscribe", id = id, filters = filters }
end

DECODERS[M.TYPE.CONNECT] = function(_, body)
  local proto, pos = readString(body, 1)
  if proto ~= "MQTT" then
    return nil, "CONNECT protocol name is not MQTT"
  end
  local level, flags = byte(body, pos, pos + 1)
  if level ~= 4 or flags == nil then
    return nil, "CONNECT protocol level is not 4"
  end
  if flags % 2 == 1 then
    return nil, "CONNECT reserved flag bit set"
  end
  local keepalive = readU16(body, pos + 2)
  if keepalive == nil then
    return nil, "CONNECT is truncated"
  end
  pos = pos + 4
  local out = {
    type = "connect",
    clean_session = math.floor(flags / 2) % 2 == 1,
    keepalive = keepalive,
  }
  out.client_id, pos = readString(body, pos)
  if out.client_id == nil then
    return nil, "CONNECT client id is truncated"
  end
  if math.floor(flags / 4) % 2 == 1 then
    local topic
    topic, pos = readString(body, pos)
    local plen = topic and readU16(body, pos)
    if topic == nil or plen == nil or pos + 1 + plen > #body then
      return nil, "CONNECT will is truncated"
    end
    out.will = {
      topic = topic,
      payload = body:sub(pos + 2, pos + 1 + plen),
      qos = math.floor(flags / 8) % 4,
      retain = math.floor(flags / 32) % 2 == 1,
    }
    pos = pos + 2 + plen
  end
  if flags >= 128 then
    out.username, pos = readString(body, pos)
    if out.username == nil then
      return nil, "CONNECT user name is truncated"
    end
  end
  if math.floor(flags / 64) % 2 == 1 then
    if flags < 128 then
      return nil, "CONNECT password without user name"
    end
    local plen = readU16(body, pos)
    if plen == nil or pos + 1 + plen > #body then
      return nil, "CONNECT password is truncated"
    end
    out.password = body:sub(pos + 2, pos + 1 + plen)
  end
  return out
end

--- Decodes one packet's body given its fixed-header nibbles.
--- @return table|nil packet, string|nil err
function M.decodeBody(typeCode, flags, body)
  local decoder = DECODERS[typeCode]
  if decoder == nil then
    return nil, "packet type " .. tostring(typeCode) .. " is reserved or not supported"
  end
  local want = EXACT_FLAGS[typeCode]
  if want ~= nil and flags ~= want then
    return nil, string.format("%s has fixed-header flags %d, expected %d", NAMES[typeCode], flags, want)
  end
  return decoder(flags, body)
end

-- ─── Streaming parser ──────────────────────────────────────────────────────

local Parser = {}
Parser.__index = Parser

--- @param opts table|nil { max_packet = bytes (default 256 KiB) }
function M.newParser(opts)
  return setmetatable({
    buf = "",
    max_packet = (opts and opts.max_packet) or M.DEFAULT_MAX_PACKET,
    failed = nil,
  }, Parser)
end

--- Adds bytes and returns every packet now complete. After the first
--- protocol error the parser is dead: it returns the packets decoded before
--- the error, then the error text, and ignores further input until reset().
--- @return table packets, string|nil err
function Parser:feed(data)
  if self.failed then
    return {}, self.failed
  end
  self.buf = self.buf .. (data or "")
  local out, pos, buf = {}, 1, self.buf
  while true do
    if #buf - pos + 1 < 2 then
      break
    end
    local first = byte(buf, pos)
    local typeCode, flags = math.floor(first / 16), first % 16
    local remaining, nextPos = M.decodeLength(buf, pos + 1)
    if remaining == nil then
      if nextPos == "malformed" then
        self.failed = "malformed remaining length"
        self.buf = ""
        return out, self.failed
      end
      break -- incomplete length bytes: wait for more
    end
    if remaining > self.max_packet then
      self.failed = string.format("packet of %d bytes exceeds the %d byte limit", remaining, self.max_packet)
      self.buf = ""
      return out, self.failed
    end
    if #buf - nextPos + 1 < remaining then
      break -- body incomplete
    end
    local body = buf:sub(nextPos, nextPos + remaining - 1)
    local pkt, err = M.decodeBody(typeCode, flags, body)
    if pkt == nil then
      self.failed = err
      self.buf = ""
      return out, err
    end
    out[#out + 1] = pkt
    pos = nextPos + remaining
  end
  self.buf = pos > 1 and buf:sub(pos) or buf
  return out, nil
end

--- Bytes held back waiting for the rest of a packet.
function Parser:pending()
  return #self.buf
end

function Parser:reset()
  self.buf = ""
  self.failed = nil
end

M.Parser = Parser

return M
