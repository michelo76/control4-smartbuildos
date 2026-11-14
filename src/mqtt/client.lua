--- MQTT 3.1.1 client session (pure state machine over an injected transport).
---
--- The driver owns the TCP socket. It tells this module when the socket is
--- up (open), hands it every chunk read (receive), tells it when the socket
--- went away (closed) and calls tick() about once a second. The session
--- writes through opts.write(bytes) and asks the driver to drop a dead
--- connection through opts.close(reason).
---
--- Scope: MQTT 3.1.1, clean session, QoS 0 and 1 in both directions, no TLS
--- (that is the socket's job and is not offered), no QoS 2, no MQTT 5.
---
--- States: idle → connecting (CONNECT sent) → connected (CONNACK accepted).
--- Subscriptions are wanted-state: subscribe() records a filter, and every
--- time the session reaches `connected` all wanted filters are sent again, so
--- a reconnect restores them without the caller doing anything.
---
--- Secrets: the password goes into the CONNECT packet and nowhere else. This
--- module never logs a packet body and never stores the password.

local Packet = require("mqtt.packet")
local Topics = require("mqtt.topics")

local Client = {}
Client.__index = Client

local M = {}

M.CONNECT_TIMEOUT = 15 -- seconds to wait for a CONNACK
M.PUBACK_TIMEOUT = 15 -- seconds before an unacknowledged QoS 1 publish is given up
M.SUBSCRIBE_BATCH = 20 -- filters per SUBSCRIBE packet
M.MAX_INFLIGHT = 64

--- @param opts table
---   write(bytes) → boolean       send on the socket
---   close(reason)                ask the driver to drop the socket
---   now() → seconds              monotonic-ish clock (os.time is fine)
---   client_id, username, password, keepalive (seconds, default 60)
---   onMessage(topic, payload, info)   info = { retain, qos, dup }
---   onState(state, detail, info)      state = "connecting"|"connected"|"closed"|"refused"|"failed"
---   onSubscribed(filter, granted)     granted = QoS or nil when the broker refused
function M.new(opts)
  local self = setmetatable({}, Client)
  self.opts = opts
  self.state = "idle"
  self.parser = Packet.newParser()
  self.dropSeen = 0
  self.wanted = {} -- filter -> true
  self.wantedOrder = {}
  self.pendingSubs = {} -- packet id -> { filters }
  self.inflight = {} -- packet id -> { topic, at }
  self.nextId = 0
  self.sentAt = 0 -- last time ANY packet went out
  self.heardAt = 0 -- last time ANY packet came in
  self.pingAt = nil -- set while a PINGREQ is unanswered
  self.connectAt = nil
  self.stats = {
    received = 0,
    published = 0,
    puback_missed = 0,
    dropped_offline = 0,
    reconnects = 0,
    bytes_in = 0,
    dropped_oversize = 0,
  }
  return self
end

function Client:keepalive()
  local k = tonumber(self.opts.keepalive)
  if k == nil then
    k = 60
  end
  return math.max(0, math.floor(k))
end

local function setState(self, state, detail, info)
  self.state = state
  if self.opts.onState then
    self.opts.onState(state, detail, info)
  end
end

local function send(self, bytes)
  local ok = self.opts.write(bytes)
  if ok ~= false then
    self.sentAt = self.opts.now()
  end
  return ok ~= false
end

local function fail(self, reason, state, info)
  if self.state == "idle" or self.state == "closed" then
    return
  end
  local lost = 0
  for _ in pairs(self.inflight) do
    lost = lost + 1
  end
  self.stats.puback_missed = self.stats.puback_missed + lost
  self.inflight = {}
  self.pendingSubs = {}
  self.pingAt = nil
  setState(self, state or "failed", reason, info)
  -- The driver is told once. Its socket-closed callback arrives next and
  -- must not announce the same loss a second time.
  self.state = "closed"
  self.opts.close(reason)
end

local function allocId(self)
  for _ = 1, 65535 do
    self.nextId = self.nextId % 65535 + 1
    if self.inflight[self.nextId] == nil and self.pendingSubs[self.nextId] == nil then
      return self.nextId
    end
  end
  return nil
end

local function sendSubscribe(self, filters)
  local i = 1
  while i <= #filters do
    local batch = {}
    for j = i, math.min(#filters, i + M.SUBSCRIBE_BATCH - 1) do
      batch[#batch + 1] = { filter = filters[j], qos = 1 }
    end
    local id = allocId(self)
    if id == nil then
      return false
    end
    local names = {}
    for _, b in ipairs(batch) do
      names[#names + 1] = b.filter
    end
    self.pendingSubs[id] = names
    send(self, Packet.subscribe(id, batch))
    i = i + M.SUBSCRIBE_BATCH
  end
  return true
end

-- ─── Transport events ──────────────────────────────────────────────────────

--- The socket is connected: say hello.
function Client:open()
  self.parser = Packet.newParser()
  self.dropSeen = 0
  self.pingAt = nil
  self.inflight = {}
  self.pendingSubs = {}
  self.connectAt = self.opts.now()
  self.heardAt = self.connectAt
  setState(self, "connecting", "waiting for the broker to accept the login")
  local ok, packetOrErr = pcall(Packet.connect, {
    client_id = self.opts.client_id,
    keepalive = self:keepalive(),
    username = self.opts.username,
    password = self.opts.password,
  })
  if not ok then
    fail(self, tostring(packetOrErr):gsub("^.-:%d+: ", ""), "failed")
    return false
  end
  if not send(self, packetOrErr) then
    fail(self, "could not write to the broker socket", "failed")
    return false
  end
  return true
end

--- The socket closed or errored (driver → session).
function Client:closed(reason)
  if self.state == "idle" or self.state == "closed" then
    return
  end
  local wasConnected = self.state == "connected"
  local lost = 0
  for _ in pairs(self.inflight) do
    lost = lost + 1
  end
  self.stats.puback_missed = self.stats.puback_missed + lost
  self.inflight = {}
  self.pendingSubs = {}
  self.pingAt = nil
  self.parser:reset()
  if wasConnected then
    self.stats.reconnects = self.stats.reconnects + 1
  end
  setState(self, "closed", reason or "connection closed", { was_connected = wasConnected })
end

--- A chunk of bytes from the socket.
function Client:receive(data)
  if self.state == "idle" or self.state == "closed" then
    return
  end
  self.stats.bytes_in = self.stats.bytes_in + #data
  self.heardAt = self.opts.now()
  local packets, err = self.parser:feed(data)
  if self.parser.dropped > (self.dropSeen or 0) then
    local n = self.parser.dropped - (self.dropSeen or 0)
    self.dropSeen = self.parser.dropped
    self.stats.dropped_oversize = self.stats.dropped_oversize + n
    if self.opts.onError then
      self.opts.onError(
        string.format(
          "Discarded %d oversize retained/published message(s) (last one %d bytes; limit %d); the connection stays up",
          n,
          self.parser.lastDropped and self.parser.lastDropped.bytes or 0,
          self.parser.max_packet
        )
      )
    end
  end
  if #packets > 0 then
    self.pingAt = nil -- any packet proves the broker is alive
  end
  for _, pkt in ipairs(packets) do
    if self.state == "idle" or self.state == "closed" then
      return -- an earlier packet in this read ended the session
    end
    self:handle(pkt)
  end
  if err then
    fail(self, "protocol error: " .. err, "failed")
  end
end

function Client:handle(pkt)
  local kind = pkt.type
  if self.state == "connecting" then
    if kind ~= "connack" then
      fail(self, "broker sent " .. kind .. " before CONNACK", "failed")
      return
    end
    if not pkt.accepted then
      -- 4 (bad credentials) and 5 (not authorised) will not fix themselves.
      fail(
        self,
        "broker refused the login: " .. tostring(pkt.text),
        "refused",
        { permanent = pkt.code == 4 or pkt.code == 5, code = pkt.code }
      )
      return
    end
    setState(self, "connected", "connected", { session_present = pkt.session_present })
    local filters = {}
    for _, f in ipairs(self.wantedOrder) do
      if self.wanted[f] then
        filters[#filters + 1] = f
      end
    end
    if #filters > 0 then
      sendSubscribe(self, filters)
    end
    return
  end
  if kind == "publish" then
    if pkt.qos == 2 then
      fail(self, "protocol error: QoS 2 delivery is not supported", "failed")
      return
    end
    self.stats.received = self.stats.received + 1
    if self.opts.onMessage then
      local ok, err =
        pcall(self.opts.onMessage, pkt.topic, pkt.payload, { retain = pkt.retain, qos = pkt.qos, dup = pkt.dup })
      if not ok and self.opts.onError then
        self.opts.onError("message handler failed: " .. tostring(err))
      end
    end
    if pkt.qos == 1 then
      send(self, Packet.puback(pkt.id))
    end
  elseif kind == "puback" then
    self.inflight[pkt.id] = nil
  elseif kind == "suback" then
    local filters = self.pendingSubs[pkt.id]
    self.pendingSubs[pkt.id] = nil
    if filters and self.opts.onSubscribed then
      for i, f in ipairs(filters) do
        local code = pkt.codes[i]
        self.opts.onSubscribed(f, (code ~= nil and code ~= 0x80) and code or nil)
      end
    end
  elseif kind == "pingresp" then
    self.pingAt = nil
  elseif kind == "unsuback" then
    -- nothing to do: wanted-state was already updated
  elseif kind == "connack" then
    fail(self, "protocol error: second CONNACK", "failed")
  else
    fail(self, "protocol error: unexpected " .. kind, "failed")
  end
end

-- ─── Calls from the driver ─────────────────────────────────────────────────

function Client:isConnected()
  return self.state == "connected"
end

--- Wants a filter (now if connected, and again after every reconnect).
--- @return boolean ok, string|nil why
function Client:subscribe(filter)
  local ok, why = Topics.validFilter(filter)
  if not ok then
    return false, why
  end
  if self.wanted[filter] then
    return true
  end
  self.wanted[filter] = true
  self.wantedOrder[#self.wantedOrder + 1] = filter
  if self.state == "connected" then
    sendSubscribe(self, { filter })
  end
  return true
end

local function forget(self, filter)
  self.wanted[filter] = nil
  for i, f in ipairs(self.wantedOrder) do
    if f == filter then
      table.remove(self.wantedOrder, i)
      break
    end
  end
end

local function sendUnsubscribe(self, filters)
  if self.state ~= "connected" or #filters == 0 then
    return
  end
  local id = allocId(self)
  if id then
    send(self, Packet.unsubscribe(id, filters))
  end
end

function Client:unsubscribe(filter)
  if not self.wanted[filter] then
    return
  end
  forget(self, filter)
  sendUnsubscribe(self, { filter })
end

--- Replaces the wanted set with exactly `filters`: one UNSUBSCRIBE for what
--- went, one batch of SUBSCRIBE for what is new.
--- @return table rejected  { { filter, why }, ... }
function Client:setSubscriptions(filters)
  local keep = {}
  for _, f in ipairs(filters) do
    keep[f] = true
  end
  local gone = {}
  for _, f in ipairs(self:subscriptions()) do
    if not keep[f] then
      gone[#gone + 1] = f
      forget(self, f)
    end
  end
  sendUnsubscribe(self, gone)
  local rejected, added = {}, {}
  for _, f in ipairs(filters) do
    local ok, why = Topics.validFilter(f)
    if not ok then
      rejected[#rejected + 1] = { filter = f, why = why }
    elseif not self.wanted[f] then
      self.wanted[f] = true
      self.wantedOrder[#self.wantedOrder + 1] = f
      added[#added + 1] = f
    end
  end
  if self.state == "connected" and #added > 0 then
    sendSubscribe(self, added)
  end
  return rejected
end

function Client:subscriptions()
  local out = {}
  for _, f in ipairs(self.wantedOrder) do
    out[#out + 1] = f
  end
  return out
end

--- Publishes. Refuses (does not queue) while not connected: a stale "turn it
--- off" delivered minutes later is worse than a reported failure.
--- @return boolean ok, string|nil why
function Client:publish(topic, payload, opts)
  opts = opts or {}
  if self.state ~= "connected" then
    self.stats.dropped_offline = self.stats.dropped_offline + 1
    return false, "not connected to the broker"
  end
  local okName, why = Topics.validName(topic)
  if not okName then
    return false, why
  end
  local qos = opts.qos or 0
  if qos ~= 0 and qos ~= 1 then
    return false, "only QoS 0 and 1 are supported"
  end
  payload = tostring(payload or "")
  local id
  if qos == 1 then
    local count = 0
    for _ in pairs(self.inflight) do
      count = count + 1
    end
    if count >= M.MAX_INFLIGHT then
      return false, "too many unacknowledged publishes"
    end
    id = allocId(self)
    if id == nil then
      return false, "no free packet id"
    end
    self.inflight[id] = { topic = topic, at = self.opts.now() }
  end
  local okP, bytes =
    pcall(Packet.publish, { topic = topic, payload = payload, qos = qos, retain = opts.retain, id = id })
  if not okP then
    if id then
      self.inflight[id] = nil
    end
    return false, (tostring(bytes):gsub("^.-:%d+: ", ""))
  end
  if not send(self, bytes) then
    if id then
      self.inflight[id] = nil
    end
    return false, "could not write to the broker socket"
  end
  self.stats.published = self.stats.published + 1
  return true
end

--- Polite goodbye. The driver closes the socket afterwards.
function Client:disconnect()
  if self.state == "connected" or self.state == "connecting" then
    send(self, Packet.disconnect())
  end
  self.inflight = {}
  self.pendingSubs = {}
  self.pingAt = nil
  if self.state ~= "idle" then
    self.state = "idle"
  end
end

--- Housekeeping, about once a second: CONNACK timeout, keepalive, unacked
--- QoS 1. A keepalive of 0 disables the pings (the spec allows it).
function Client:tick()
  local now = self.opts.now()
  if self.state == "connecting" then
    if now - (self.connectAt or now) > M.CONNECT_TIMEOUT then
      fail(self, "broker did not answer the login within " .. M.CONNECT_TIMEOUT .. " seconds", "failed")
    end
    return
  end
  if self.state ~= "connected" then
    return
  end
  for id, item in pairs(self.inflight) do
    if now - item.at > M.PUBACK_TIMEOUT then
      self.inflight[id] = nil
      self.stats.puback_missed = self.stats.puback_missed + 1
    end
  end
  local keepalive = self:keepalive()
  if keepalive == 0 then
    return
  end
  if self.pingAt ~= nil then
    -- Anything heard from the broker clears the ping (see receive), so an
    -- unanswered one this long means the link is dead.
    if now - self.pingAt > math.max(5, keepalive * 0.5) then
      fail(self, "no answer from the broker (keepalive of " .. keepalive .. " seconds ran out)", "failed")
    end
    return
  end
  if now - self.sentAt >= keepalive * 0.75 then
    if send(self, Packet.pingreq()) then
      self.pingAt = now
    end
  end
end

return M
