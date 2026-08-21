-- The Realtime doorbell's protocol decisions.
--
-- Run from the driver root:
--   make test

local pass, fail = 0, 0
local function check(name, ok, detail)
  if ok then
    pass = pass + 1
    print(string.format("  ok   %s", name))
  else
    fail = fail + 1
    print(string.format("  FAIL %s%s", name, detail and ("  -> " .. tostring(detail)) or ""))
  end
end

package.path = "./src/?.lua;./src/?/init.lua;./vendor/?.lua;" .. package.path
local JSON = require("JSON")
local Realtime = require("telemetry.realtime")

local function client()
  return Realtime.new({
    encode = function(t)
      return JSON:encode(t)
    end,
    decode = function(s)
      return JSON:decode(s)
    end,
  })
end

print("\n[1] Frames")
local c = client()
local join = JSON:decode(c:joinFrame("c4ping:abc-123"))
check("join targets the realtime-prefixed topic", join.topic == "realtime:c4ping:abc-123", join.topic)
check("join subscribes to nothing but broadcast", #join.payload.config.postgres_changes == 0)
check("refs increment", JSON:decode(c:heartbeatFrame()).ref == "2")
check("the phoenix heartbeat rides its own topic", JSON:decode(c:heartbeatFrame()).topic == "phoenix")

print("\n[2] Frame classification")
c = client()
c:joinFrame("c4ping:abc-123")
local reply =
  JSON:encode({ topic = "realtime:c4ping:abc-123", event = "phx_reply", payload = { status = "ok" }, ref = "1" })
check("the first ok reply means joined", c:handleFrame(reply).type == "joined")
check("a second reply is noise, not a rejoin", c:handleFrame(reply).type == "noise")
check("joined state tracks", c:isJoined() == true)

local ping =
  JSON:encode({ topic = "realtime:c4ping:abc-123", event = "broadcast", payload = { event = "ping", payload = {} } })
check("a ping is a ping", c:handleFrame(ping).type == "ping")

local other = JSON:encode({
  topic = "realtime:c4ping:abc-123",
  event = "broadcast",
  payload = { event = "command", payload = { run = "OPEN_GARAGE" } },
})
check(
  "a broadcast that TRIES to carry an instruction is noise — the doorbell has no mailbox",
  c:handleFrame(other).type == "noise"
)

check(
  "a foreign topic is noise",
  c:handleFrame(JSON:encode({ topic = "realtime:other", event = "broadcast", payload = { event = "ping" } })).type
    == "noise"
)
check("garbage is noise, never an error", c:handleFrame("{not json").type == "noise")
check(
  "a close clears joined",
  c:handleFrame(JSON:encode({ topic = "realtime:c4ping:abc-123", event = "phx_close", payload = {} })).type == "closed"
    and c:isJoined() == false
)

print("\n[3] URL assembly")
check(
  "https base becomes wss",
  Realtime.socketUrl("https://x.supabase.co", "anonkey")
    == "wss://x.supabase.co/realtime/v1/websocket?apikey=anonkey&vsn=1.0.0"
)
check("missing pieces yield nil", Realtime.socketUrl("", "k") == nil and Realtime.socketUrl("https://x", "") == nil)

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
