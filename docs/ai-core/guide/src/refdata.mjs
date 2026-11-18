// Builds the guide's reference JSON. Names are copied from driver.xml,
// DRIVER.md, MODULE-CONTRACT-V2.md, PROTOCOL.md (v1) and the platform tool
// registry dump (tools.json, produced by importing the real registry).
import fs from "node:fs";
const dir = new URL(".", import.meta.url).pathname;
const toolsRaw = JSON.parse(fs.readFileSync(dir + "tool-registry.json", "utf8"));

const CAT = ["General", "Lighting", "Comfort", "Media", "Security", "Access", "Safety", "Energy", "Presence", "System", "Programming", "Maintenance"];
const commands = [
  { name: "AI_ASK", description: "Ask SmartBuildOS AI a question (the answer arrives later as AI Response Ready)", op: "ask", feature: "BASE",
    params: [{ name: "QUESTION", type: "STRING", rule: "≤ 500 characters, required" }, { name: "ROOM", type: "STRING", rule: "optional; room name or id (≤ 64)" }] },
  { name: "AI_ANALYZE_ROOM", description: "Ask SmartBuildOS AI to analyse one room (room name or id)", op: "analyze_room", feature: "BASE",
    params: [{ name: "ROOM", type: "STRING", rule: "required; room name or id" }] },
  { name: "AI_ANALYZE_SYSTEM", description: "Ask SmartBuildOS AI to analyse the whole system", op: "analyze_system", feature: "BASE", params: [] },
  { name: "AI_RECORD_EVENT", description: "Record a named event for SmartBuildOS AI (what the programming reports; not an observed result)", op: null, feature: "BASE",
    params: [{ name: "NAME", type: "STRING", rule: "≤ 120, required" }, { name: "DETAIL", type: "STRING", rule: "≤ 400, optional" }, { name: "ROOM", type: "STRING", rule: "optional" }, { name: "CATEGORY", type: "LIST", rule: "optional, default General", items: CAT }],
    note: "No cloud call: recorded as an ai_core.record envelope on the durable event path (severity warning for Security/Safety). A dealer's marker, not learning: recorded whether learning is off, on or paused; refused for an excluded room or category; never learned from." },
  { name: "AI_SET_CONTEXT", description: "Tell SmartBuildOS AI about the home's situation (closed list of keys)", op: "set_context", feature: "BASE",
    params: [{ name: "KEY", type: "LIST", rule: "required (sent as key in the set_context cloud body; context_key in the envelope)", items: ["Occupancy", "Guests Present", "Vacation", "Quiet Hours", "Special Event", "Cleaning", "Maintenance Window"] }, { name: "VALUE", type: "STRING", rule: "≤ 120, required" }] },
  { name: "AI_LEARN_PREFERENCE", description: "Teach SmartBuildOS AI a household preference (needs learning active)", op: "learn_preference", feature: "AI_LEARNING",
    params: [{ name: "STATEMENT", type: "STRING", rule: "≤ 300, required" }, { name: "ROOM", type: "STRING", rule: "optional" }],
    note: "Refused locally while learning is off (the default) or paused. The platform records the statement as a verified explicit preference with source `programming` and answers completed at once (`job_id` null), so AI Response Ready is not fired; it refuses `not_permitted` when learning is not enabled or paused, the feature is missing or the room is excluded." },
  { name: "AI_SUGGEST_SCENE", description: "Ask SmartBuildOS AI to suggest a scene for a room and occasion (a suggestion only)", op: "suggest_scene", feature: "BASE",
    params: [{ name: "ROOM", type: "STRING", rule: "required" }, { name: "OCCASION", type: "STRING", rule: "≤ 120, required" }] },
  { name: "AI_GENERATE_REPORT", description: "Ask SmartBuildOS AI for a report", op: "generate_report", feature: "BASE",
    params: [{ name: "TYPE", type: "LIST", rule: "required", items: ["System Health", "Usage", "Energy", "Security", "Comfort", "Device Reliability"] }, { name: "PERIOD", type: "LIST", rule: "required", items: ["Today", "Last 24 Hours", "Last 7 Days", "Last 30 Days"] }] },
  { name: "AI_START_DIAGNOSTIC", description: "Start a diagnostic for one device or one room (attaches the Flight Recorder's recent local events)", op: "start_diagnostic", feature: "BASE",
    params: [{ name: "DEVICE", type: "DEVICE_SELECTOR", rule: "exactly one of DEVICE or ROOM" }, { name: "ROOM", type: "STRING", rule: "exactly one of DEVICE or ROOM" }],
    note: "Runs the local diagnostic first, then the cloud op with diagnostic_event_id, local_event_ids and flight_recorder_available." },
  { name: "AI_SEND_NOTIFICATION", description: "Send a notification through SmartBuildOS (recipients are decided by SmartBuildOS)", op: "send_notification", feature: "BASE",
    params: [{ name: "TITLE", type: "STRING", rule: "≤ 80, required" }, { name: "MESSAGE", type: "STRING", rule: "≤ 400, required" }, { name: "AUDIENCE", type: "LIST", rule: "optional, default Homeowner", items: ["Homeowner", "Integrator", "All"] }] },
];
const actions = [
  { name: "Test Agent Link", command: "TEST_AGENT_LINK", does: "SBOS_MODULE_DISCOVER to the Agent; writes the Agent's version, protocol range, pairing, cloud state and module count to Last Test Result (or why it cannot: no Agent, protocol 1, failed with a code)." },
  { name: "Test AI Connection", command: "TEST_AI_CONNECTION", does: "Cloud op test_provider; Last Test Result says accepted (job id; the result arrives as AI Response Ready) or the refusal code." },
  { name: "Sync Now", command: "SYNC_NOW", does: "Re-registers if needed, drains the buffer, flushes staged events, re-reads the directory, sends a status frame (which carries applied_config_version), and (protocol 2) calls cloud op status, whose body is {request_id} only." },
  { name: "Print Diagnostics", command: "PRINT_DIAGNOSTICS", does: "Prints state, Agent link, licence, configuration, learning, Flight Recorder link, collection plan, every counter, pending jobs and bus counters to the Lua output." },
];
const P = (name, def, shows, editable) => ({ name, type: editable ? "LIST" : "STRING", default: def, readonly: !editable, shows });
const properties = [
  P("Driver Status", "Starting", "Online once started"),
  P("Driver Version", "", "the built <version>"),
  P("SmartBuildOS Connection Status", "Starting", "one of the connection-state texts (Connected, No SmartBuildOS Agent in this project, SmartBuildOS Agent update required (module contract v2), SmartBuildOS Agent not responding, Registering with the SmartBuildOS Agent, SmartBuildOS Agent not paired, SmartBuildOS cloud unreachable, Connected (not licensed))"),
  P("Agent Pairing Status", "Unknown", "Paired, Not paired, No SmartBuildOS Agent, Agent update required, Unknown (not registered with the Agent yet)"),
  P("Property ID", "Not delivered yet (System Studio)", "the id System Studio delivered (configuration property_id) — the platform does not send it today, so it reads Not delivered yet"),
  P("Controller ID", "Not delivered yet (System Studio)", "the id System Studio delivered (configuration controller_id) — not sent today either"),
  P("AI Provider", "Not configured (System Studio)", "provider display name from configuration provider.name"),
  P("AI Model", "Not configured (System Studio)", "model display name from configuration provider.model"),
  P("AI API Credential", "Not configured", "Status only, e.g. Configured in System Studio · Anthropic ••••abcd. Keys are entered in System Studio and never reach the controller."),
  P("AI Status", "Starting", "Ready, Working: N request(s) waiting for a result, Degraded: <connection text>, Unavailable: <licence>; (learning paused) and — last request refused (<code>) / refused locally (<code>) / not delivered (<code>) appended when they apply"),
  P("Telemetry Status", "-", "Through the Agent: N sent, N acknowledged, N dropped; buffer N, buffer drops N — or No Agent answering: N critical event(s) buffered, N waiting in memory, N dropped — or Learning paused: …"),
  P("Learning Status", "-", "Off (not switched on in System Studio) — the default; Active; Paused by System Studio; Paused by System Studio: the configuration does not switch it on; Paused by configuration: vN refused; Paused by …: the licence does not include AI_LEARNING; Stopped (not licensed)"),
  P("Permission Mode", "Not delivered yet (System Studio owns it)", "observe, recommend or execute_low_risk + (set in System Studio)"),
  P("Flight Recorder Link", "Unknown", "Installed: local history served; topics subscribed · Installed (no local history service; update the Flight Recorder) · Not installed: AI Core collects its minimal set itself · Unknown (needs Agent protocol 2)"),
  P("License Status", "No SmartBuildOS Agent Found", "the licence SDK's one line (sbos.license)"),
  P("License Source", "-", "licence display set: included with the subscription, or purchased"),
  P("Subscription Tier", "-", "licence display set: the company's tier"),
  P("SmartBuildOS Company", "-", "licence display set: the company the project is licensed to"),
  P("Last Synchronization", "never", "last time the platform was heard (config applied, restricted operation, accepted cloud answer, Sync Now)"),
  P("Last Test Result", "none", "result line of Test Agent Link / Test AI Connection"),
  P("Last Error", "none", "last error or refusal, ≤ 240 bytes (cut between UTF-8 characters), none when clear"),
  { name: "Log Level", type: "LIST", default: "2 - Warning", readonly: false, shows: "editable", items: ["0 - Fatal", "1 - Error", "2 - Warning", "3 - Info", "4 - Debug", "5 - Trace"] },
  { name: "Log Mode", type: "LIST", default: "Off", readonly: false, shows: "editable", items: ["Off", "Print", "Log", "Print and Log"] },
];
const events = [
  { id: 1, name: "AI Response Ready", key: "ai_response_ready", description: "A result from SmartBuildOS AI arrived (AI_LAST_RESPONSE, AI_LAST_RESPONSE_ID)", fired: "deliver_result (or raise_event ai_response_ready)" },
  { id: 2, name: "Pattern Detected", key: "pattern_detected", description: "SmartBuildOS detected a pattern (AI_LAST_EVENT_DETAIL)", fired: "raise_event pattern_detected" },
  { id: 3, name: "Recommendation Available", key: "recommendation_available", description: "A recommendation is waiting in System Studio (AI_RECOMMENDATION_COUNT)", fired: "raise_event recommendation_available" },
  { id: 4, name: "Automation Conflict Detected", key: "automation_conflict_detected", description: "SmartBuildOS found programming or automations that conflict (AI_LAST_EVENT_DETAIL)", fired: "raise_event automation_conflict_detected" },
  { id: 5, name: "Device Failure Pattern Detected", key: "device_failure_pattern_detected", description: "SmartBuildOS found a device failing repeatedly (AI_LAST_EVENT_DETAIL)", fired: "raise_event device_failure_pattern_detected" },
  { id: 6, name: "Approval Required", key: "approval_required", description: "An AI-proposed action waits for the homeowner's approval (AI_PENDING_APPROVALS)", fired: "raise_event approval_required" },
  { id: 7, name: "Action Completed", key: "action_completed", description: "An approved AI action completed (AI_LAST_EVENT_DETAIL)", fired: "raise_event action_completed" },
  { id: 8, name: "Action Failed", key: "action_failed", description: "An approved AI action failed (AI_LAST_EVENT_DETAIL)", fired: "raise_event action_failed" },
  { id: 9, name: "Agent Disconnected", key: "agent_disconnected", description: "This driver lost the SmartBuildOS Agent (registration lost or the Agent stopped answering)", fired: "this driver only: AGENT_CONNECTED goes true → false. Not raisable by the platform" },
  { id: 10, name: "AI Provider Error", key: "ai_provider_error", description: "The AI provider configured in System Studio returned an error (AI_LAST_ERROR, AI_LAST_EVENT_DETAIL)", fired: "raise_event ai_provider_error; also sets AI_LAST_ERROR / Last Error to AI provider error: <detail> (cleared by the next deliver_result)" },
];
const variables = [
  { id: 4000, name: "AI_STATUS", type: "STRING", default: "starting", value: "state code (no_agent, agent_update_required, agent_lost, registering, agent_unpaired, cloud_unreachable, unlicensed, ready) or working" },
  { id: 4001, name: "AI_LAST_RESPONSE", type: "STRING", default: "", value: "last delivered result, ≤ 1024 bytes: a longer result keeps its first ≤ 1021 bytes, cut between two UTF-8 characters, followed by ..." },
  { id: 4002, name: "AI_LAST_RESPONSE_ID", type: "STRING", default: "", value: "its response_id" },
  { id: 4003, name: "AI_LAST_REQUEST_ID", type: "STRING", default: "", value: "the last command's request_id (aic-<uuid>)" },
  { id: 4004, name: "AI_LAST_EVENT_DETAIL", type: "STRING", default: "", value: "raise_event detail (≤ 512 bytes, cut between UTF-8 characters) or the Agent Disconnected reason" },
  { id: 4005, name: "AI_PENDING_APPROVALS", type: "NUMBER", default: "0", value: "from deliver_result / raise_event pending_approvals" },
  { id: 4006, name: "AI_RECOMMENDATION_COUNT", type: "NUMBER", default: "0", value: "from recommendation_count" },
  { id: 4007, name: "AGENT_CONNECTED", type: "BOOL", default: "false", value: "registered and answering" },
  { id: 4008, name: "LEARNING_ACTIVE", type: "BOOL", default: "false", value: "learning on (false until a valid configuration or set_learning switches it on)" },
  { id: 4009, name: "AI_LAST_ERROR", type: "STRING", default: "", value: "as Last Error (empty when clear); includes the platform's AI provider error (raise_event ai_provider_error)" },
  { id: 4010, name: "AI_LAST_CORRELATION_ID", type: "STRING", default: "", value: "the correlation_id of the last raise_event (for an approval or action event, the platform's action id); empty after an event without one" },
];
const conditionals = [
  { id: 1, name: "AI_READY", type: "BOOL", statement: "AI Core is ready", meaning: "state ready" },
  { id: 2, name: "AGENT_CONNECTED", type: "BOOL", statement: "The SmartBuildOS Agent is connected", meaning: "registered and answering" },
  { id: 3, name: "LEARNING_ACTIVE", type: "BOOL", statement: "AI learning is active", meaning: "learning on and licence not halted" },
  { id: 4, name: "APPROVALS_PENDING", type: "BOOL", statement: "AI actions are waiting for approval", meaning: "AI_PENDING_APPROVALS > 0" },
  { id: 5, name: "RECOMMENDATIONS_AVAILABLE", type: "BOOL", statement: "AI recommendations are available", meaning: "AI_RECOMMENDATION_COUNT > 0" },
];
const F = (dir, name, params, answer, ver) => ({ dir, name, params, answer, ver });
const frames = [
  F("M→A", "SBOS_MODULE_REGISTER", "module_id, instance_id, requester, driver_version, protocol_min, protocol_max, capabilities, entitlements, commands, event_types, config_version, singleton, status; v2: manifest (JSON ≤ 2 KB)", "SBOS_MODULE_REGISTERED", 1),
  F("A→M", "SBOS_MODULE_REGISTERED", "ok, token, protocol, reason, agent_protocol_min/max, paired, connected, installation_id, boot_id, agent_version; v2: manifest_error", "then SBOS_DRIVER_CONFIG per SKU", 1),
  F("M→A", "SBOS_MODULE_STATUS", "auth, status, detail, config_version, applied_config_version, config_error, counters (JSON)", "none (liveness; stale after 15 min)", 1),
  F("M→A", "SBOS_MODULE_EVENTS", "auth, batch_id, events (JSON array of envelopes, ≤ 100)", "SBOS_MODULE_EVENTS_ACK", 1),
  F("A→M", "SBOS_MODULE_EVENTS_ACK", "batch_id, accepted, rejected, duplicates, reason, queue", "—", 1),
  F("M→A", "SBOS_MODULE_COMMAND_RESULT", "auth, request_id, state (Accepted/Executing/Completed/Failed/Expired/Unverified), detail", "none", 1),
  F("M→A", "SBOS_MODULE_SNAPSHOT", "auth, job_id, request_id, status, document (JSON ≤ 256 KB)", "SBOS_MODULE_SNAPSHOT_ACK", 1),
  F("A→M", "SBOS_MODULE_SNAPSHOT_ACK", "job_id, ok, reason, snapshot_id", "—", 1),
  F("M→A", "SBOS_MODULE_UNREGISTER", "auth", "none", 1),
  F("A→M", "SBOS_MODULE_AGENT_HELLO", "agent_version", "every known instance re-registers (new token)", 1),
  F("A→M", "SBOS_MODULE_AGENT_STATE", "paired, connected, installation_id, boot_id, agent_version, protocol", "—", 1),
  F("A→M", "SBOS_MODULE_AGENT_EVENT", "name, detail (JSON)", "—", 1),
  F("A→M", "SBOS_DRIVER_CONFIG", "sku, settings (JSON), settings_version, requester", "SBOS_DRIVER_CONFIG_ACK", 1),
  F("M→A", "SBOS_DRIVER_CONFIG_ACK", "sku, applied, refused, settings_version, requester", "audited", 1),
  F("A→M", "SBOS_MODULE_COMMAND", "module_id, instance_id, token, request_id, command, args (JSON), expires_at, issued_at", "SBOS_MODULE_COMMAND_RESULT", 1),
  F("M→A", "SBOS_MODULE_DISCOVER", "auth, request_id, filter (JSON {module_id?, capability?}, optional)", "SBOS_MODULE_DIRECTORY", 2),
  F("A→M", "SBOS_MODULE_DIRECTORY", "request_id, error_code, directory_version, agent (JSON), modules (JSON array), truncated", "—", 2),
  F("A→M", "SBOS_MODULE_DIRECTORY_CHANGED", "directory_version", "—", 2),
  F("M→A", "SBOS_MODULE_SUBSCRIBE", "auth, subscription_id, topics (JSON array, 1–16)", "SBOS_MODULE_SUBSCRIBED", 2),
  F("A→M", "SBOS_MODULE_SUBSCRIBED", "subscription_id, ok, reason, granted (JSON), refused (JSON)", "—", 2),
  F("M→A", "SBOS_MODULE_UNSUBSCRIBE", "auth, subscription_id", "none", 2),
  F("A→M", "SBOS_MODULE_PUBLISH", "subscription_id, events (JSON array of envelopes, ≤ 25), dropped", "—", 2),
  F("M→A / A→M", "SBOS_MODULE_REQUEST", "M→A: auth, request_id, idempotency_key, to, to_instance (optional), capability, args (JSON ≤ 16 KB), deadline (now < d ≤ now + 60). A→M: target's auth, request_id, idempotency_key, from_module_id, from_instance_id, capability, args, deadline", "SBOS_MODULE_REQUEST_ACK; target answers SBOS_MODULE_RESPONSE", 2),
  F("A→M", "SBOS_MODULE_REQUEST_ACK", "request_id, state (Routed / Refused), error_code", "—", 2),
  F("M→A / A→M", "SBOS_MODULE_RESPONSE", "M→A: auth, request_id, status (ok / error), error_code, result (JSON ≤ 24 KB), cursor (≤ 256). A→M adds from_module_id, from_instance_id (stamped), replayed", "relayed to the requester", 2),
  F("M→A", "SBOS_MODULE_CLOUD_REQUEST", "auth, request_id, idempotency_key, op, body (JSON ≤ 16 KB), deadline", "SBOS_MODULE_CLOUD_RESPONSE", 2),
  F("A→M", "SBOS_MODULE_CLOUD_RESPONSE", "request_id, status, http_status, error_code, result (JSON)", "—", 2),
];
const errorCodes = [
  ["ok", "success", "—"], ["invalid_frame", "a required param is missing or malformed", "no"], ["incompatible_protocol", "one side negotiated v1", "no"],
  ["unknown_target", "no module (or instance) by that id is registered", "no"], ["target_unavailable", "registered, but not live at v2; or it went away; or the Agent restarted", "yes"],
  ["capability_not_found", "target does not serve it (manifest / provider / no handler)", "no"], ["not_permitted", "policy refuses it", "no"],
  ["invalid_args", "args/body/topics/deadline range wrong", "no"], ["payload_too_large", "over a size limit", "no"],
  ["deadline_exceeded", "no answer by the deadline, or deadline already past", "yes"], ["duplicate_request", "same request id, or same key still in flight; informational on a replay ACK", "no"],
  ["rate_limited", "a token bucket or the route cap", "yes"], ["agent_not_paired", "cloud relay without a pairing", "no"],
  ["cloud_unreachable", "no usable answer from the platform", "yes"], ["cloud_refused", "the platform refused", "no"],
  ["unsupported", "reserved for a platform answer", "no"], ["internal_error", "a handler failed, or an out-of-vocabulary code was normalised", "no"],
].map(([code, meaning, retry]) => ({ code, meaning, retry }));
const restrictedOps = ["apply_config", "refresh_status", "deliver_result", "raise_event", "set_learning", "run_diagnostic"];
const cloudOps = ["ask", "analyze_room", "analyze_system", "learn_preference", "suggest_scene", "generate_report", "start_diagnostic", "send_notification", "set_context", "status", "test_provider"];
const tools = toolsRaw.map((t) => ({
  id: t.id, wire: t.wire, risk: t.risk, household: t.household, feature: t.feature ?? null, verb: t.verb ?? null, description: t.description,
  required: t.schema.required ?? [],
  props: Object.entries(t.schema.properties).map(([k, v]) => {
    const parts = [];
    let type = v.type ?? (v.anyOf ? "anyOf" : "");
    if (v.format) parts.push(v.format);
    if (v.enum) parts.push("one of " + v.enum.join(", "));
    if (v.minimum !== undefined) parts.push("min " + v.minimum);
    if (v.maximum !== undefined && v.maximum < 2147483647) parts.push("max " + v.maximum);
    if (v.maxLength !== undefined) parts.push("≤ " + v.maxLength + " chars");
    if (v.minItems !== undefined) parts.push("min items " + v.minItems);
    if (v.maxItems !== undefined) parts.push("max items " + v.maxItems);
    return { name: k, type, rule: parts.join("; ") };
  }),
}));
const routes = [
  ["POST", "/api/integrations/control4/modules/rpc", "Agent pairing token", "Cloud relay for AI Core ops (HTTP 200 for every business outcome)", "Completed in simulation (2.12); not deployed"],
  ["GET/PUT", "/api/monitoring/ai-core/settings", "monitoring:view / manage (+ homecontrol:manage to raise permission_mode)", "Property settings; save with expected_version (409 on mismatch); publishes driver_config; queues set_learning / apply_config", "Completed in simulation (5.8); Studio page browser-verified (8.8)"],
  ["GET/PUT/DELETE", "/api/monitoring/ai-core/credentials", "monitoring:view / manage", "Masked keys; store, rotate, delete", "Completed in simulation (5.7); Studio page browser-verified (8.8)"],
  ["POST", "/api/monitoring/ai-core/credentials/test", "monitoring:manage", "Token-free connectivity test (6/min per property)", "Completed in simulation (5.7); never called a live provider"],
  ["GET", "/api/monitoring/ai-core/usage", "monitoring:view", "Month-to-date usage and limits (UTC)", "Completed in simulation (5.9)"],
  ["GET", "/api/monitoring/ai-core/overview", "monitoring:view (learned data: + homecontrol:view, AI_LEARNING)", "Studio AI Overview", "Completed (8.2); browser-verified"],
  ["GET", "/api/monitoring/ai-core/household-usage", "monitoring:view + homecontrol:view", "Studio Household Usage", "Completed (8.3); browser-verified"],
  ["GET", "/api/monitoring/ai-core/flight-recorder", "monitoring:view", "Studio Flight Recorder Intelligence (search, incident)", "Completed (8.4); browser-verified"],
  ["GET/POST", "/api/monitoring/ai-core/memories", "monitoring:view / manage + homecontrol:view; AI_LEARNING", "Household memory; staff facts; accept/reject pending proposals", "Completed in simulation (6.1); browser-verified (8.5)"],
  ["GET/POST", "/api/monitoring/ai-core/patterns", "monitoring:view / manage + homecontrol:view; AI_LEARNING", "Findings; on-demand analysis", "Completed in simulation (6.3)"],
  ["GET", "/api/monitoring/ai-core/recommendations", "monitoring:view + homecontrol:view; AI_LEARNING", "Recommendations", "Completed in simulation (6.5); browser-verified (8.5)"],
  ["GET/PATCH", "/api/monitoring/ai-core/recommendations/[id]", "monitoring:view / manage", "Status transitions, customer_visible", "Completed in simulation (6.5); browser-verified (8.5)"],
  ["GET", "/api/monitoring/ai-core/actions", "monitoring:view + homecontrol:view; AI_ACTIONS", "Actions for a property", "Completed in simulation (7.2); browser-verified (8.5)"],
  ["GET/POST", "/api/monitoring/ai-core/actions/[id]", "monitoring:manage + homecontrol:manage to decide", "Staff approve/decline low actions a person asked for", "Completed in simulation (7.2)"],
  ["GET/POST/DELETE", "/api/monitoring/ai-core/rules", "monitoring:manage + homecontrol:manage to write", "Pre-approved low-risk rules (inactive until consent)", "Completed in simulation (7.4); browser-verified (8.5)"],
  ["GET/POST", "/api/monitoring/ai-core/programming", "monitoring:view / manage + homecontrol:view; AI_ACTIONS", "Programming hand-offs", "Completed in simulation (7.8); browser-verified (8.5)"],
  ["GET/POST", "/api/monitoring/ai-core/programming/[id]", "monitoring:view / manage (+ own Composer Studio edit permission)", "Hand-off state", "Completed in simulation (7.8)"],
  ["GET/POST", "/api/monitoring/ai-core/jobs", "monitoring:view / manage", "Jobs; process due jobs on demand", "Completed in simulation (5.10)"],
  ["GET/POST", "/api/monitoring/ai-core/conversations", "monitoring:view / manage", "Staff conversation threads", "Completed (8.7); no live model answer"],
  ["GET", "/api/monitoring/ai-core/conversations/[id]", "monitoring:view", "One thread", "Completed (8.7)"],
  ["POST", "/api/monitoring/ai-core/conversations/[id]/messages", "monitoring:manage", "One turn; SSE progress stream", "Completed (8.7); no live model answer"],
  ["GET/POST", "/api/monitoring/ai-core/service/findings", "monitoring:view / manage", "Service findings; emit maintenance recommendations", "Completed (8.6); browser-verified"],
  ["GET", "/api/monitoring/ai-core/service/driver-health", "monitoring:view", "Driver module health", "Completed (8.6)"],
  ["GET", "/api/monitoring/ai-core/service/playbook", "monitoring:view", "Service playbooks", "Completed (8.6)"],
  ["GET/POST", "/api/monitoring/ai-core/service/ticket", "monitoring:view (+ tickets:create to create)", "Ticket draft; staff-confirmed ticket", "Completed (8.6)"],
  ["GET/PATCH", "/api/monitoring/ai-core/concierge", "monitoring:view / manage + homecontrol:manage; AI_CONCIERGE", "Read-only requests; turn the SIMULATION sandbox on/off", "Sandbox Completed in simulation (9.2)"],
  ["GET/PATCH/DELETE", "/api/portal/ai-core/learning", "homeowner portal", "Pause, exclusions, export, erase", "Completed in simulation (6.2); portal screen browser-verified (9.4)"],
  ["GET/PATCH/DELETE", "/api/portal/ai-core/memories", "homeowner portal", "Review, correct, accept, assign, delete", "Completed in simulation (6.2); portal screen browser-verified (9.4)"],
  ["GET", "/api/portal/ai-core/status", "homeowner portal", "The homeowner's AI Core status for their own property: licensed, features, assistant set up (a boolean, never a provider or key), learning state, SIMULATION sandbox on/off", "Built (platform commit 13a9147f9)"],
  ["GET/PATCH", "/api/portal/ai-core/recommendations", "homeowner portal; SBOS_AI_CORE (list needs AI_LEARNING)", "Recommendations shared with the homeowner; approve (homeowner approver only) or dismiss", "Built; portal screen browser-verified (9.4)"],
  ["GET/POST", "/api/portal/ai-core/actions", "homeowner portal; AI_ACTIONS to approve", "Pending approvals; approve / deny", "Completed in simulation (7.3); portal screen browser-verified (9.4)"],
  ["GET/POST", "/api/portal/ai-core/rules", "homeowner portal; AI_ACTIONS to consent", "Consent / revoke pre-approved rules", "Completed in simulation (7.4); portal screen browser-verified (9.4)"],
  ["GET/POST", "/api/portal/ai-core/conversations (+ [id], [id]/messages)", "homeowner portal; AI_CONCIERGE", "Homeowner conversation threads (persona homeowner)", "Built; no live model answer; portal screen browser-verified (9.4)"],
  ["GET/POST", "/api/portal/ai-core/concierge", "homeowner portal; AI_CONCIERGE except the safe direction", "The homeowner's own concierge steps", "Recovery Completed in simulation (9.5); state machine Tested (9.1); SIMULATION sandbox only"],
  ["GET/PATCH/DELETE", "/api/portal/ai-core/calendar (+ connect/[provider], callback/[provider])", "homeowner portal", "Calendar connections, read consent, disconnect", "Tested against wire fixtures (9.3); blocked on OAuth credentials (9.7)"],
].map(([method, path, gate, does, state]) => ({ method, path, gate, does, state }));
const envelope = [
  ["event_id", "\"<module_id>:<instance_id>:<boot_id|nb>:<sequence>\" (≤ 128)"], ["schema_version", "1"],
  ["event_type", "\"<prefix>.<name>\" — the module must own the prefix"], ["module_id", "^[a-z][a-z0-9_]{2,47}$"],
  ["source_driver_instance_id", "the module's Director device id (string)"], ["installation_id", "stamped by the Agent (system id); a module's value is overwritten"],
  ["device_id", "integer when applicable"], ["room_id", "integer when applicable"], ["observed_at", "controller wall clock, ISO-8601 UTC"],
  ["boot_id", "stamped by the Agent when absent (C4:GetBootID)"], ["sequence", "module-persisted monotonic integer (may skip, never repeats)"],
  ["correlation_id", "≤ 96 chars, when explicitly supplied (trace id, request id)"], ["severity", "debug | info | notice | warning | error | critical"],
  ["evidence_source", "observed | initial | requested | instrumented | derived | system"], ["quality", "confirmed | unreviewed_text | partial | unknown"],
  ["label", "≤ 120"], ["payload", "object, ≤ 4 KB approx, depth ≤ 4, ≤ 40 keys, strings ≤ 512; redacted on both sides"],
].map(([field, rule]) => ({ field, rule }));

const out = { commands, actions, properties, events, variables, conditionals, frames, errorCodes, restrictedOps, cloudOps, tools, routes, envelope };
process.stdout.write(JSON.stringify(out).replace(/</g, "\\u003c"));
