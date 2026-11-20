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

--- The wildcard requester: `requesters = ANY` lets EVERY authenticated,
--- registered v2 module call the capability (the Agent drops frames that do
--- not carry a registration token before policy is ever consulted). It is a
--- unique, empty, read-only table, never a string: an engine that does not
--- know the marker indexes an empty table and refuses (fails closed), and a
--- string would answer its own methods (`("*").len`) as truthy. Mirrored as
--- `"*"` in the web repo.
M.ANY = setmetatable({}, {
  __newindex = function()
    error("modulepolicy.ANY is read-only")
  end,
  __tostring = function()
    return "ANY"
  end,
})
local ANY = M.ANY

--- MODULE_REQUEST_POLICY[capability] = { provider = module id that may
--- SERVE it (nil = any module that advertises it), requesters = { module ids
--- that may CALL it } or ANY }.
--- The provider column is a strengthening of the architecture's table: a
--- module that is not the sanctioned provider cannot answer for a
--- capability even if its manifest advertises the name.
local FR_READERS = { ai_core = true }
local AI_CORE_ONLY = { ai_core = true }
M.REQUEST_POLICY = {
  ["events.query"] = { provider = "flight_recorder", requesters = FR_READERS },
  ["events.timeline"] = { provider = "flight_recorder", requesters = FR_READERS },
  ["events.device_history"] = { provider = "flight_recorder", requesters = FR_READERS },
  ["events.room_activity"] = { provider = "flight_recorder", requesters = FR_READERS },
  -- Any registered module reports to AI Core (describe/state/event/diagnostic).
  ["ai_core.report"] = { provider = "ai_core", requesters = ANY },
  -- PIN Lock's challenge/redeem for touchscreen approvals. No PIN ever
  -- travels in these frames; it goes to PIN Lock's own LAN relay only.
  ["pinlock.availability"] = { provider = "pin_lock", requesters = AI_CORE_ONLY },
  ["pinlock.challenge"] = { provider = "pin_lock", requesters = AI_CORE_ONLY },
  ["pinlock.redeem"] = { provider = "pin_lock", requesters = AI_CORE_ONLY },
  -- Served by any driver that declares queries / actions; only AI Core asks.
  ["ai.query"] = { provider = nil, requesters = AI_CORE_ONLY },
  ["ai.action"] = { provider = nil, requesters = AI_CORE_ONLY },
}

--- Whether `moduleId` may CALL a capability under `rule` (a REQUEST_POLICY
--- row). The ONE reading of the requesters column, wildcard included.
function M.requesterAllowed(rule, moduleId)
  if type(rule) ~= "table" or type(moduleId) ~= "string" or moduleId == "" then
    return false
  end
  if rule.requesters == ANY then
    return true
  end
  return type(rule.requesters) == "table" and rule.requesters[moduleId] == true
end

--- Reserved module ids, bound to the .c4z file(s) that may register them.
--- The Agent checks a registration under one of these ids against the
--- devices Director reports for that file (sbos.modules identity binding):
--- a claimant at another device id is refused, so no other driver can
--- squat `pin_lock` or `ai_core`. Ids not listed here register as before,
--- marked unverified. Adding a SmartBuildOS module here is an Agent release.
--- Every root driver's id is reserved, so a root that joins the bus through
--- sbos.aireport is `verified` (declared actions are honoured only for a
--- verified module); test/test_sbos_aireport.lua keeps this table and
--- aireport.MODULE_IDS identical.
M.RESERVED_MODULES = {
  ai_core = { "smartbuildos-ai-core.c4z" },
  flight_recorder = { "smartbuildos-flight-recorder.c4z" },
  usage_analytics = { "smartbuildos-usage-analytics.c4z" },
  mqtt_broker = { "smartbuildos-mqtt-broker.c4z" },
  venueflow = { "smartbuildos-venueflow.c4z" },
  pin_lock = { "smartbuildos-pin-lock.c4z" },
  atmosphere = { "smartbuildos-atmosphere.c4z" },
  mode_composer = { "smartbuildos-mode-composer.c4z" },
  bond_bridge = { "bond-bridge.c4z" },
  commissioning = { "smartbuildos-commissioning.c4z" },
  daypart = { "smartbuildos-daypart.c4z" },
  dealer_panel = { "smartbuildos-dealer-panel.c4z" },
  guest_mode = { "smartbuildos-guest-mode.c4z" },
  load_shedding = { "smartbuildos-load-shedding.c4z" },
  logic_pack = { "smartbuildos-logic-pack.c4z" },
  notification_router = { "smartbuildos-notification-router.c4z" },
  solar = { "smartbuildos-solar.c4z" },
  system_link = { "smartbuildos-system-link.c4z" },
  user_manual = { "smartbuildos-user-manual.c4z" },
  variable_inspector = { "smartbuildos-variable-inspector.c4z" },
  unifi_protect = { "unifi-protect.c4z" },
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
    analyze_household = true,
    -- Touchscreen approvals (the PIN itself never reaches the cloud).
    approvals_pending = true,
    approval_detail = true,
    approval_decide = true,
    -- Driver reporting: batched reports, and the outcomes of
    -- run_driver_query / invoke_driver_action.
    driver_reports = true,
    driver_query_result = true,
    driver_action_result = true,
    -- The filtered outcome of the restricted operation read_device_state
    -- (one device's live variables; AI Core's aicore.devicestate).
    device_state_result = true,
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
