--- The Realtime doorbell: a Phoenix-channel client that carries NO data.
---
--- ── WHY A DOORBELL, NOT A MAILBOX ───────────────────────────────────────────
---
--- The socket exists to make command delivery instant instead of
--- one-heartbeat-late. It would be easy to push the commands themselves down
--- it — and wrong: the HTTPS path authenticates with the device token, and a
--- socket that carries instructions would need that whole story retold. So
--- the platform broadcasts a contentless "ping", and this driver reacts by
--- running the same authenticated heartbeat it always runs. A spoofed ping
--- costs one rate-limited check-in; the security model does not move.
---
--- ── WHY THIS MODULE IS PURE ─────────────────────────────────────────────────
---
--- Same doctrine as rooms/lights/queue: the Phoenix protocol details — join
--- frames, ref counting, the phoenix-topic heartbeat, what counts as a ping —
--- are all decisions, and decisions get tested without a socket. The driver
--- glue owns I/O and timers; this owns the protocol.

local Realtime = {}
Realtime.__index = Realtime

--- @param opts { encode: fun(t: table): string, decode: fun(s: string): table }
function Realtime.new(opts)
  local self = setmetatable({}, Realtime)
  self._encode = opts.encode
  self._decode = opts.decode
  self._ref = 0
  self._topic = nil
  self._joined = false
  return self
end

function Realtime:nextRef()
  self._ref = self._ref + 1
  return tostring(self._ref)
end

--- The frame that subscribes to the system's doorbell channel.
--- @param channel string e.g. "c4ping:<system uuid>"
function Realtime:joinFrame(channel)
  self._topic = "realtime:" .. channel
  self._joined = false
  return self._encode({
    topic = self._topic,
    event = "phx_join",
    payload = {
      config = {
        broadcast = { self = false },
        presence = { key = "" },
        postgres_changes = {},
      },
    },
    ref = self:nextRef(),
  })
end

--- The Phoenix-level keepalive. Sent on a timer by the glue; ~30s keeps the
--- upstream from reaping the socket.
function Realtime:heartbeatFrame()
  return self._encode({
    topic = "phoenix",
    event = "heartbeat",
    payload = {},
    ref = self:nextRef(),
  })
end

--- Classifies one incoming frame.
---
--- Returns one of:
---   { type = "joined" }       the subscription is live
---   { type = "ping" }         the platform rang the doorbell
---   { type = "closed" }       the channel was closed server-side
---   { type = "noise" }        anything else — replies, presence, keepalives
---
--- Anything malformed is noise, never an error: a hostile or garbled frame
--- must cost nothing.
function Realtime:handleFrame(raw)
  local ok, msg = pcall(self._decode, raw)
  if not ok or type(msg) ~= "table" then
    return { type = "noise" }
  end

  if msg.topic == self._topic and msg.event == "phx_reply" then
    local status = type(msg.payload) == "table" and msg.payload.status or nil
    if status == "ok" and not self._joined then
      self._joined = true
      return { type = "joined" }
    end
    return { type = "noise" }
  end

  if msg.topic == self._topic and msg.event == "phx_close" then
    self._joined = false
    return { type = "closed" }
  end

  if msg.topic == self._topic and msg.event == "broadcast" then
    local p = type(msg.payload) == "table" and msg.payload or {}
    -- The doorbell payload is deliberately ignored beyond its name: nothing a
    -- broadcast says may change what this driver DOES. It checks in; the
    -- authenticated response is the instruction channel.
    if p.event == "ping" then
      return { type = "ping" }
    end
    return { type = "noise" }
  end

  return { type = "noise" }
end

function Realtime:isJoined()
  return self._joined
end

--- Builds the WSS URL from the platform-supplied base and anon key.
---
--- The anon key is PUBLISHABLE by design (it is in every browser bundle); it
--- buys subscription only, and the channel carries nothing worth reading.
function Realtime.socketUrl(baseUrl, anonKey)
  if type(baseUrl) ~= "string" or baseUrl == "" or type(anonKey) ~= "string" or anonKey == "" then
    return nil
  end
  local host = baseUrl:gsub("^https://", ""):gsub("^http://", ""):gsub("/+$", "")
  return "wss://" .. host .. "/realtime/v1/websocket?apikey=" .. anonKey .. "&vsn=1.0.0"
end

return Realtime
