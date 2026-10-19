--- System Link wire protocol v1: envelopes, limits, generation fencing,
--- deduplication and revision ordering.
---
--- Pure module. The transport (HTTPS to the relay plus the Realtime
--- doorbell) is hidden behind `systemlink.transport`; this module only knows
--- what a message *is* and whether it may be accepted.
---
--- Envelope (JSON object):
---   v     protocol version (integer)
---   t     message type (see M.TYPES)
---   id    message id, unique per sender (uuid)
---   link  link id
---   ep    sending endpoint id
---   gen   sending endpoint generation (fenced: obsolete generations drop)
---   seq   relay sequence number (relay-assigned, monotonic per link; absent
---         on the way UP, present on the way DOWN)
---   ts    sender wall clock, ISO-8601 — informational only, never used for
---         ordering or expiry on its own
---   exp   optional expiry in relay time (ms since epoch) stamped by the relay
---   body  type-specific payload
---
--- Ordering rule: for an owner's item the authoritative order is
--- (owner generation, owner revision). The relay sequence breaks ties and
--- orders unrelated messages. Wall clocks are never compared across
--- controllers.

local M = {}

M.VERSION = 1
M.MIN_SUPPORTED = 1
M.MAX_SUPPORTED = 1

M.TYPES = {
  hello = true, -- endpoint → relay: negotiate protocol, announce generation
  schema = true, -- owner definitions
  state = true, -- owner values (batched)
  snapshot = true, -- relay → endpoint: full state of the peer
  event = true, -- one-time occurrence
  request = true, -- named routine request
  request_update = true, -- progress / result for a request
  command = true, -- companion control request
  command_update = true, -- ack / feedback for a command
  heartbeat = true,
  control = true, -- pause/resume, revoke, suspension notices
}

--- Hard limits. Oversized frames are rejected before parsing deeper.
M.LIMITS = {
  frame_bytes = 32 * 1024,
  payload_bytes = 4 * 1024, -- event/request/command payloads
  state_batch = 200, -- items per state message
  outbound_per_sync = 50,
  inbound_per_sync = 200,
  dedup_window = 512,
}

local function isNonEmptyString(s)
  return type(s) == "string" and s ~= ""
end

--- Validates an envelope against what this endpoint knows.
--- @param env table decoded JSON
--- @param ctx table { link = id, self = endpoint id, peer = endpoint id,
---                    peer_gen = known peer generation, rawLen = bytes }
--- @return boolean ok, string|nil reason
function M.validate(env, ctx)
  if ctx.rawLen and ctx.rawLen > M.LIMITS.frame_bytes then
    return false, "oversized"
  end
  if type(env) ~= "table" then
    return false, "malformed"
  end
  if type(env.v) ~= "number" or env.v < M.MIN_SUPPORTED or env.v > M.MAX_SUPPORTED then
    return false, "unsupported version"
  end
  if not M.TYPES[env.t] then
    return false, "unknown type"
  end
  if not isNonEmptyString(env.id) or not isNonEmptyString(env.link) or not isNonEmptyString(env.ep) then
    return false, "malformed"
  end
  if env.link ~= ctx.link then
    return false, "wrong link"
  end
  if env.ep == ctx.self then
    return false, "echo"
  end
  if env.ep ~= ctx.peer and env.ep ~= "relay" then
    return false, "unknown endpoint"
  end
  if type(env.gen) ~= "number" then
    return false, "malformed"
  end
  if env.ep ~= "relay" and ctx.peer_gen and env.gen < ctx.peer_gen then
    return false, "obsolete generation"
  end
  if type(env.body) ~= "table" then
    return false, "malformed"
  end
  return true
end

--- Expiry is decided against RELAY time, which the relay stamps on the way
--- down (`exp`). The sender's own `ts` is never trusted for it. If the relay
--- stamped nothing, the message is treated as not expiring.
--- @param relayNowMs number the relay's clock as last observed (the driver
---        keeps an offset from the relay's response headers)
function M.isExpired(env, relayNowMs)
  if type(env.exp) ~= "number" then
    return false
  end
  return relayNowMs >= env.exp
end

-- ── Deduplication ───────────────────────────────────────────────────────────

local Dedup = {}
Dedup.__index = Dedup

--- Bounded ring of seen message ids. JSON-safe so it can be persisted
--- (a restart must not re-apply the last few frames).
function M.newDedup(capacity)
  return setmetatable({ cap = capacity or M.LIMITS.dedup_window, ring = {}, set = {}, head = 0 }, Dedup)
end

--- Re-attaches methods to a persisted dedup table.
function M.restoreDedup(t)
  if type(t) ~= "table" or type(t.ring) ~= "table" then
    return M.newDedup()
  end
  t.set = {}
  for _, id in ipairs(t.ring) do
    t.set[id] = true
  end
  return setmetatable(t, Dedup)
end

--- @return boolean true if this id was NOT seen before (and is now recorded)
function Dedup:accept(id)
  if self.set[id] then
    return false
  end
  self.head = self.head + 1
  if self.head > self.cap then
    self.head = 1
  end
  local evicted = self.ring[self.head]
  if evicted then
    self.set[evicted] = nil
  end
  self.ring[self.head] = id
  self.set[id] = true
  return true
end

function Dedup:seen(id)
  return self.set[id] == true
end

-- ── Revision ordering ───────────────────────────────────────────────────────

--- Compares two (generation, revision) pairs for the same owner item.
--- @return number -1 if a < b, 0 if equal, 1 if a > b
function M.compareRev(aGen, aRev, bGen, bRev)
  if aGen ~= bGen then
    return aGen < bGen and -1 or 1
  end
  if aRev ~= bRev then
    return aRev < bRev and -1 or 1
  end
  return 0
end

--- Whether an incoming value for a mirrored item should replace the held
--- one. Equal revisions are a confirmation, not a change.
--- @return "apply" | "confirm" | "ignore"
function M.classifyIncoming(held, incoming)
  if held == nil then
    return "apply"
  end
  local c = M.compareRev(held.gen or 0, held.rev or 0, incoming.gen or 0, incoming.rev or 0)
  if c < 0 then
    return "apply"
  end
  if c == 0 then
    return "confirm"
  end
  return "ignore"
end

-- ── Builders ────────────────────────────────────────────────────────────────

function M.envelope(t, ctx, id, body, ts)
  return { v = M.VERSION, t = t, id = id, link = ctx.link, ep = ctx.self, gen = ctx.self_gen, ts = ts, body = body }
end

--- Negotiation: the relay answers hello with the version both sides will
--- use. The highest common version wins; no overlap is a hard failure.
function M.negotiate(ourMin, ourMax, theirMin, theirMax)
  local lo = math.max(ourMin, theirMin)
  local hi = math.min(ourMax, theirMax)
  if lo > hi then
    return nil, "no common protocol version"
  end
  return hi
end

--- Approximate byte size of a JSON-encoded payload, for the limit check.
--- Exact size is the encoder's business; this must only be monotonic and
--- never under-count by more than a constant factor.
function M.approxSize(value, depth)
  depth = depth or 0
  if depth > 16 then
    return math.huge
  end
  local t = type(value)
  if t == "string" then
    return #value + 2
  elseif t == "number" then
    return 12
  elseif t == "boolean" or t == "nil" then
    return 5
  elseif t == "table" then
    local n = 2
    for k, v in pairs(value) do
      n = n + M.approxSize(k, depth + 1) + M.approxSize(v, depth + 1) + 2
      if n > M.LIMITS.frame_bytes then
        return n
      end
    end
    return n
  end
  return 0
end

return M
