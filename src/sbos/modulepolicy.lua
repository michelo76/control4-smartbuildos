--- SmartBuildOS module contract v2 — shared vocabulary, limits and the
--- Agent's closed policy tables (pure data + tiny validators).
---
--- Both halves of the contract read this ONE file: the Agent's bus
--- (sbos.modulebus) enforces it, the module client (sbos.modulerpc) uses the
--- same limits to refuse locally before a frame is ever sent, and the same
--- error vocabulary to decide what may be retried. Spec:
--- docs/protocol/MODULE-CONTRACT-V2.md.
---
--- The policy tables are the Agent's authority. Anything not listed is
--- `not_permitted`. They are mirrored in the web repo like MODULE_COMMANDS.

local M = {}

M.PROTOCOL_MIN = 1
M.PROTOCOL_MAX = 2
--- The first protocol version that carries discovery, pub/sub,
--- request/response and the cloud relay.
M.V2 = 2

--- Closed error vocabulary (ARCHITECTURE §4.4). Nothing else is ever put in
--- an `error_code` param by the Agent or by the client library.
M.ERRORS = {
  ok = true,
  invalid_frame = true,
  incompatible_protocol = true,
  unknown_target = true,
  target_unavailable = true,
  capability_not_found = true,
  not_permitted = true,
  invalid_args = true,
  payload_too_large = true,
  deadline_exceeded = true,
  duplicate_request = true,
  rate_limited = true,
  agent_not_paired = true,
  cloud_unreachable = true,
  cloud_refused = true,
  unsupported = true,
  internal_error = true,
}

--- Codes after which the SAME call (same idempotency key) may be tried
--- again. Every other code is final.
M.RETRYABLE = {
  deadline_exceeded = true,
  target_unavailable = true,
  rate_limited = true,
  cloud_unreachable = true,
}
--- Retry schedule: at most two retries, 2 s then 5 s.
M.RETRY_DELAYS = { 2, 5 }

M.LIMITS = {
  frame_bytes = 32 * 1024, -- v1 frame limit, unchanged
  args_bytes = 16 * 1024, -- REQUEST args (raw JSON string)
  result_bytes = 24 * 1024, -- RESPONSE result (raw JSON string)
  cloud_body_bytes = 16 * 1024, -- CLOUD_REQUEST body (raw JSON string)
  cloud_result_bytes = 24 * 1024, -- what the Agent relays back from the cloud
  manifest_bytes = 2048, -- the registration manifest (raw JSON string)
  manifest_capabilities = 24,
  capability_topics = 16,
  directory_bytes = 28 * 1024, -- DIRECTORY modules param; truncated beyond
  cursor = 256,
  id = 128, -- request_id, idempotency_key
  subscription_id = 64,
  topics = 16, -- per SUBSCRIBE
  subscriptions_per_instance = 8,
  publish_batch = 25, -- envelopes per PUBLISH frame
  publish_frame_bytes = 24 * 1024, -- approx bytes of envelopes per PUBLISH frame
  subscriber_buffer = 200, -- per subscription, drop-oldest, counted
  deadline_max_seconds = 60,
  route_grace_seconds = 5, -- routing state kept past a deadline
  idempotency_ring = 256,
  target_dedup_ring = 256,
  routes = 128, -- in-flight routed requests + cloud calls, whole Agent
  directory_debounce_seconds = 5,
  tick_seconds = 5,
  publish_delay_ms = 1000,
}

--- Per-module token buckets (ARCHITECTURE §4.3).
M.RATES = {
  request = { per_minute = 30, burst = 10 }, -- REQUEST and DISCOVER
  cloud = { per_minute = 20, burst = 10 }, -- CLOUD_REQUEST
}

--- MODULE_REQUEST_POLICY[capability] = { provider = module id that may
--- SERVE it, requesters = { module ids that may CALL it } }.
--- The provider column is a strengthening of the architecture's table: a
--- module that is not the sanctioned provider cannot answer for a
--- capability even if its manifest advertises the name.
local FR_READERS = { ai_core = true }
M.REQUEST_POLICY = {
  ["events.query"] = { provider = "flight_recorder", requesters = FR_READERS },
  ["events.timeline"] = { provider = "flight_recorder", requesters = FR_READERS },
  ["events.device_history"] = { provider = "flight_recorder", requesters = FR_READERS },
  ["events.room_activity"] = { provider = "flight_recorder", requesters = FR_READERS },
}

--- MODULE_TOPIC_POLICY[prefix] = { subscriber module ids }. A requested
--- topic is granted when it starts with a listed prefix the subscriber is
--- allowed (equal or narrower). Who may EMIT under a prefix is decided by
--- sbos.envelope's PREFIXES, as in v1.
M.TOPIC_POLICY = {
  ["capture."] = { ai_core = true },
  ["observation."] = { ai_core = true },
  ["trace."] = { ai_core = true },
}

--- MODULE_CLOUD_OPS[module_id] = { op = true }: the closed per-module op
--- vocabulary of POST /api/integrations/control4/modules/rpc. Not a proxy.
M.CLOUD_OPS = {
  ai_core = {
    ask = true,
    analyze_room = true,
    analyze_system = true,
    learn_preference = true,
    suggest_scene = true,
    generate_report = true,
    start_diagnostic = true,
    send_notification = true,
    set_context = true,
    status = true,
    test_provider = true,
  },
}

M.CLOUD_PATH = "modules/rpc"

-- ── validators (strings arrive from SendToDevice) ─────────────────────────────

function M.validId(s, limit)
  return type(s) == "string" and #s >= 1 and #s <= (limit or M.LIMITS.id) and s:match("^[%w][%w%-_:%.]*$") ~= nil
end

function M.validCapability(s)
  return type(s) == "string" and #s <= 64 and s:match("^[a-z][a-z0-9_]*%.[a-z0-9_%.]+$") ~= nil
end

function M.validTopic(s)
  return type(s) == "string" and #s >= 2 and #s <= 64 and s:match("^[a-z][a-z0-9_]*%.[a-z0-9_%.]*$") ~= nil
end

function M.validOp(s)
  return type(s) == "string" and #s <= 48 and s:match("^[a-z][a-z0-9_]*$") ~= nil
end

--- Normalises any code to the closed vocabulary.
function M.code(s)
  if type(s) == "string" and M.ERRORS[s] then
    return s
  end
  return "internal_error"
end

--- Whether `moduleId` may subscribe to `topic` under MODULE_TOPIC_POLICY.
function M.topicAllowed(policy, moduleId, topic)
  for prefix, subscribers in pairs(policy or {}) do
    if subscribers[moduleId] and topic:sub(1, #prefix) == prefix then
      return true
    end
  end
  return false
end

return M
