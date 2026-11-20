--- SmartBuildOS AI Core — closed vocabularies and limits (pure data).
---
--- Every list here is CLOSED: a value that is not listed is refused, never
--- passed through. The driver (drivers/smartbuildos-ai-core), its pure
--- modules (src/aicore/*) and docs/ai-core/DRIVER.md all read these names;
--- the web repo mirrors the ones that cross the wire (cloud ops, restricted
--- operations, raise_event names, configuration keys).

local M = {}

M.MODULE_ID = "ai_core"
M.SKU = "SBOS_AI_CORE"
M.MANIFEST_DRIVER = "sbos.ai_core"
M.EVENT_PREFIX = "ai_core."
M.FEATURES = { BASE = true, AI_LEARNING = true, AI_ACTIONS = true, AI_CONCIERGE = true }

--- Composer events (ids are permanent: programming binds by id).
M.EVENTS = {
  { id = 1, name = "AI Response Ready", key = "ai_response_ready" },
  { id = 2, name = "Pattern Detected", key = "pattern_detected" },
  { id = 3, name = "Recommendation Available", key = "recommendation_available" },
  { id = 4, name = "Automation Conflict Detected", key = "automation_conflict_detected" },
  { id = 5, name = "Device Failure Pattern Detected", key = "device_failure_pattern_detected" },
  { id = 6, name = "Approval Required", key = "approval_required" },
  { id = 7, name = "Action Completed", key = "action_completed" },
  { id = 8, name = "Action Failed", key = "action_failed" },
  { id = 9, name = "Agent Disconnected", key = "agent_disconnected" },
  { id = 10, name = "AI Provider Error", key = "ai_provider_error" },
}
M.EVENT_ID = {}
for _, e in ipairs(M.EVENTS) do
  M.EVENT_ID[e.key] = e.id
end

--- What the platform may raise with the restricted operation `raise_event`.
--- Agent Disconnected is deliberately absent: only this driver knows that.
M.RAISABLE = {
  ai_response_ready = true,
  pattern_detected = true,
  recommendation_available = true,
  automation_conflict_detected = true,
  device_failure_pattern_detected = true,
  approval_required = true,
  action_completed = true,
  action_failed = true,
  ai_provider_error = true,
}

--- Restricted operations (Agent MODULE_COMMANDS.ai_core). None controls
--- equipment, runs code, or names a command to forward. The last two hand
--- a read-only query / a person-approved action to the driver that DECLARED
--- it (ai.query / ai.action over the bus, schema-validated by that driver's
--- own helper); invoke_driver_action needs the Agent's Remote Control tier
--- at Comfort or above (the Agent enforces it). read_device_state reads ONE
--- device's variables once and answers through device_state_result,
--- filtered in the home by aicore.devicestate (read-only: no tier).
M.OPERATIONS = {
  "apply_config",
  "refresh_status",
  "deliver_result",
  "raise_event",
  "set_learning",
  "run_diagnostic",
  "run_driver_query",
  "invoke_driver_action",
  "read_device_state",
}

--- Cloud ops (Agent MODULE_CLOUD_OPS.ai_core).
M.CLOUD_OPS = {
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
  -- Added with the bus foundations (Agent policy); the touchscreen ops are
  -- not called yet (brief D5).
  approvals_pending = true,
  approval_detail = true,
  approval_decide = true,
  -- The report hub (src/aicore/reports.lua) and the outcomes of
  -- run_driver_query / invoke_driver_action.
  driver_reports = true,
  driver_query_result = true,
  driver_action_result = true,
  -- The outcome of read_device_state (src/aicore/devicestate.lua).
  device_state_result = true,
}

--- Event categories (AI_RECORD_EVENT, exclusions, collected events).
--- `unknown` is what a collected event is when nothing says otherwise.
M.CATEGORIES = {
  general = true,
  lighting = true,
  comfort = true,
  media = true,
  security = true,
  access = true,
  safety = true,
  energy = true,
  presence = true,
  system = true,
  programming = true,
  maintenance = true,
  unknown = true,
}
M.CATEGORY_LIST = {
  "general",
  "lighting",
  "comfort",
  "media",
  "security",
  "access",
  "safety",
  "energy",
  "presence",
  "system",
  "programming",
  "maintenance",
  "unknown",
}

--- AI_SET_CONTEXT keys (closed).
M.CONTEXT_KEYS = {
  occupancy = true,
  guests_present = true,
  vacation = true,
  quiet_hours = true,
  special_event = true,
  cleaning = true,
  maintenance_window = true,
}

--- AI_GENERATE_REPORT.
M.REPORT_TYPES = {
  system_health = true,
  usage = true,
  energy = true,
  security = true,
  comfort = true,
  device_reliability = true,
}
M.REPORT_PERIODS = { today = true, last_24_hours = true, last_7_days = true, last_30_days = true }

--- AI_SEND_NOTIFICATION audiences.
M.AUDIENCES = { homeowner = true, integrator = true, all = true }

--- Permission modes (display only on the controller; System Studio owns them).
M.PERMISSION_MODES = { observe = true, recommend = true, execute_low_risk = true }

--- The cloud's refusal reasons (result.reason of an ok:false answer) in an
--- installer's words: Last Error, Last Test Result and AI Status show them
--- (commands.lua interpret). Every reason the platform can send to a cloud op
--- that interpret() reads: the RPC pipeline (rpc/handler.ts), the op bodies
--- (rpc/ops.ts validateOpBody, status.ts) and learn_preference
--- (memory/programming.ts). analyze_household shows its own reasons as they
--- are (interpretHousehold); the touchscreen has its own words (webui.lua).
--- A reason not listed here is shown as the token itself.
M.REFUSAL_REASONS = {
  -- rpc/handler.ts (every op)
  not_entitled = "not licensed for this controller",
  rate_limited = "too many requests; try again later",
  module_not_registered = "AI Core is not registered with SmartBuildOS",
  op_not_in_vocabulary = "SmartBuildOS does not accept this request from AI Core",
  unsupported = "SmartBuildOS does not support this request yet",
  in_progress = "the same request is still in progress",
  key_reused_for_a_different_request = "a request id was reused for another request",
  payload_too_large = "the request is too large",
  result_too_large = "the answer was too large",
  unreadable = "the request could not be read",
  not_json = "the request could not be read",
  not_an_object = "the request could not be read",
  bad_fields = "the request was missing a required field",
  body_not_object = "the request could not be read",
  -- rpc/ops.ts validateOpBody (every op, status included)
  no_body_spec = "SmartBuildOS does not support this request yet",
  unknown_fields = "the request carried a field SmartBuildOS does not accept",
  invalid_fields = "a field of the request was not valid",
  -- rpc/ops.ts (the ops that need a home)
  system_not_linked_to_a_property = "this system is not linked to a home in SmartBuildOS",
  -- learn_preference (rpc/ops.ts, memory/programming.ts)
  feature_required = "the licence does not include this feature",
  learning_not_enabled = "learning is not switched on in System Studio",
  learning_paused = "learning is paused for this home",
  room_excluded = "the room is excluded from learning",
  invalid_statement = "the statement is empty or not valid",
  names_a_person = "the statement names a person",
  too_many_programming_memories = "too many preferences stored from programming",
}

M.LIMITS = {
  question = 500,
  statement = 300,
  name = 120,
  detail = 400,
  value = 120,
  occasion = 120,
  title = 80,
  message = 400,
  room = 64, -- room_name sent to the cloud (code points; rpc/ops.ts L.room)
  device_name = 120, -- device_name sent to the cloud (code points; rpc/ops.ts start_diagnostic)
  last_response = 1024, -- AI_LAST_RESPONSE (Composer variable)
  result_text = 4000, -- deliver_result text accepted
  event_detail = 512, -- raise_event detail / AI_LAST_EVENT_DETAIL
  error_text = 240, -- AI_LAST_ERROR / Last Error
  commands_per_minute = 10, -- local token bucket over Composer commands
  pending_jobs = 20,
  job_ttl_seconds = 30 * 60,
  -- AI_RUN_HOUSEHOLD_ANALYSIS: at most one ACCEPTED run an hour from this
  -- controller (the cloud's own limit is one an hour per property), and one
  -- in flight at a time; an in-flight request that never got an answer stops
  -- blocking after household_inflight_seconds (the module client gives up
  -- well before: 30 s timeout, two retries).
  household_interval_seconds = 60 * 60,
  household_inflight_seconds = 3 * 60,
  -- read_device_state: a local bucket above the platform's 6 a minute, so
  -- platform retries never collide with it.
  device_reads_per_minute = 12,
}

return M
