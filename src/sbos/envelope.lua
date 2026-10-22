--- SmartBuildOS shared event envelope, schema v1 (pure).
---
--- One shape for everything an optional SmartBuildOS module hands the Agent
--- for upload: Flight Recorder observations and traces today; Guardian
--- health observations, Commissioning Inspector results, Home State modes
--- and Property Bridge messages tomorrow (reserved event-type prefixes in
--- M.PREFIXES — none of them is implemented here).
---
--- The envelope is built ON THE CONTROLLER and validated AGAIN on the server
--- with the same limits (web repo src/lib/control4/flight-recorder/envelope.ts).
--- The server adds `received_at`, derives tenant/property/system from the
--- authenticated installation credential, and never trusts a client-supplied
--- tenant. Clocks: `observed_at` is the controller's wall clock, which may be
--- wrong; `boot_id` + `sequence` are the only ordering facts the controller
--- can vouch for, and the server orders by (boot_id, sequence) within a
--- module instance and by received_at across them. Nothing here claims a
--- perfect global order.
---
--- Pure: no C4 calls, no globals (JSON is injected for size checks).

local M = {}

M.SCHEMA_VERSION = 1

M.LIMITS = {
  payload_bytes = 4 * 1024, -- JSON-encoded payload, approx (see approxSize)
  frame_bytes = 32 * 1024, -- one SendToDevice / upload frame
  batch = 100, -- events per frame / per upload
  event_type = 64,
  module_id = 48,
  label = 120,
  text = 512, -- any single string inside payload
  correlation_id = 96,
  event_id = 128,
  payload_depth = 4,
  payload_keys = 40,
}

--- Severity vocabulary (closed). Comparisons in Studio are string equality.
M.SEVERITIES = { debug = 0, info = 1, notice = 2, warning = 3, error = 4, critical = 5 }

--- Where the evidence came from (closed). The distinction the product is
--- built on: a REQUESTED action is not an OBSERVED result.
M.EVIDENCE = {
  observed = true, -- a device/room variable changed (feedback)
  initial = true, -- the first read of a source after (re)apply — a state, not a change
  requested = true, -- programming recorded that it asked for something
  instrumented = true, -- programmer-supplied trace step / decision / message
  derived = true, -- computed by the recorder (gap, budget, threshold)
  system = true, -- Director / Agent system event
}

--- How much to trust the payload (closed).
M.QUALITY = {
  confirmed = true, -- typed value from a known variable
  unreviewed_text = true, -- free text (programmer message, string variable): potentially sensitive
  partial = true, -- bounded/truncated or some fields unavailable
  unknown = true,
}

--- Reserved event-type prefixes. `module_id` must own the prefix it emits
--- under (the Agent enforces this at EC.SBOS_MODULE_EVENTS): a module cannot
--- impersonate another module's events.
M.PREFIXES = {
  flight_recorder = { "observation.", "trace.", "recorder.", "snapshot." },
  agent = { "agent." },
  -- Reserved, not implemented (extension contracts, PROTOCOL.md §8):
  guardian = { "health." },
  commissioning_inspector = { "test." },
  home_state = { "mode." },
  property_bridge = { "bridge." },
}

--- Upload priority: higher survives eviction longer. Initial observations are
--- the cheapest to lose (they describe a state the next read will restate).
function M.priority(eventType)
  local t = tostring(eventType or "")
  if t:find("^observation%.initial") then
    return 0
  end
  if t:find("^observation%.") then
    return 1
  end
  return 2
end

local function isNonEmptyString(s)
  return type(s) == "string" and s ~= ""
end

--- Approximate JSON size, monotonic, never under-counting by more than a
--- constant (same rule as systemlink.protocol.approxSize).
--- `limit` (default frame_bytes) is where counting stops early; callers
--- sizing larger documents (snapshots) pass their own.
function M.approxSize(value, depth, limit)
  depth = depth or 0
  limit = limit or M.LIMITS.frame_bytes
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
      n = n + M.approxSize(k, depth + 1, limit) + M.approxSize(v, depth + 1, limit) + 2
      if n > limit then
        return n
      end
    end
    return n
  end
  return 0
end

-- ── Redaction ────────────────────────────────────────────────────────────────
--
-- Keys that mark a value as a credential or access code, matched against the
-- key lowered with every non-alphanumeric removed ("User Code" → "usercode").
-- Deliberately broader than lib/http's logging redaction: this data is
-- PERSISTED and DISPLAYED, so false positives cost a hidden label, false
-- negatives cost a stored PIN.
local SENSITIVE_KEY_FRAGMENTS = {
  "password",
  "passwd",
  "secret",
  "token",
  "apikey",
  "authorization",
  "credential",
  "usercode",
  "accesscode",
  "pincode",
  "keycode",
  "passcode",
  "disarmcode",
  "armcode",
  "lockcode",
  "privatekey",
  "clientkey",
  "cookie",
  "bearer",
}
--- Exact (normalised) keys that are sensitive on their own.
local SENSITIVE_KEYS = { pin = true, code = true, key = true, auth = true, sig = true, signature = true }

M.REDACTED = "[redacted]"

function M.isSensitiveKey(key)
  local normalized = tostring(key or ""):lower():gsub("[^%a%d]", "")
  if SENSITIVE_KEYS[normalized] then
    return true
  end
  for _, fragment in ipairs(SENSITIVE_KEY_FRAGMENTS) do
    if normalized:find(fragment, 1, true) then
      return true
    end
  end
  return false
end

--- Values that look like a bearer credential whatever their key: JWTs, long
--- hex/base64 blobs. A 4–8 digit numeric string is NOT redacted here on its
--- own (it is a level, a count, a temperature far more often than a PIN);
--- string VARIABLES are instead marked quality=unreviewed_text and the
--- recorder config carries explicit exclusions for known code-bearing ones.
function M.looksLikeSecret(value)
  if type(value) ~= "string" then
    return false
  end
  if #value > 60 and value:match("^[%w_%-]+%.[%w_%-]+%.[%w_%-]+$") then
    return true
  end
  if #value >= 32 and value:match("^[0-9a-fA-F]+$") then
    return true
  end
  if #value >= 40 and value:match("^[%w%+/=_%-]+$") and not value:find(" ") then
    return true
  end
  return false
end

--- Copy of `value` with every sensitive key's value and every secret-looking
--- string replaced. Bounded depth (fails CLOSED to the marker) and cycle-safe.
function M.redact(value, depth, seen)
  depth = (depth or 0) + 1
  if type(value) == "string" then
    if M.looksLikeSecret(value) then
      return M.REDACTED
    end
    return value
  end
  if type(value) ~= "table" then
    return value
  end
  if depth > M.LIMITS.payload_depth + 2 then
    return M.REDACTED
  end
  seen = seen or {}
  if seen[value] then
    return M.REDACTED
  end
  seen[value] = true
  local out = {}
  for k, v in pairs(value) do
    if M.isSensitiveKey(k) then
      out[k] = M.REDACTED
    else
      out[k] = M.redact(v, depth, seen)
    end
  end
  seen[value] = nil
  return out
end

--- Truncates every string in a payload to LIMITS.text and caps key count and
--- depth. Returns the bounded copy and whether anything was cut.
function M.bound(value, depth)
  depth = (depth or 0) + 1
  local cut = false
  if type(value) == "string" then
    if #value > M.LIMITS.text then
      return value:sub(1, M.LIMITS.text), true
    end
    return value, false
  end
  if type(value) ~= "table" then
    return value, false
  end
  if depth > M.LIMITS.payload_depth then
    return M.REDACTED, true
  end
  local out, n = {}, 0
  for k, v in pairs(value) do
    n = n + 1
    if n > M.LIMITS.payload_keys then
      cut = true
      break
    end
    local bounded, c = M.bound(v, depth)
    out[k] = bounded
    cut = cut or c
  end
  return out, cut
end

--- Builds an envelope from module-supplied fields and the context the caller
--- (the module, then the Agent) owns.
--- @param fields table {event_type, severity?, evidence_source, quality?, payload?, device_id?, room_id?, correlation_id?, observed_at?, label?}
--- @param ctx table {module_id, instance_id, observed_at (ISO string, default), boot_id?, sequence, installation_id?}
--- @return table|nil env, string|nil reason
function M.build(fields, ctx)
  if type(fields) ~= "table" or type(ctx) ~= "table" then
    return nil, "malformed"
  end
  local eventType = tostring(fields.event_type or "")
  if eventType == "" or #eventType > M.LIMITS.event_type or not eventType:match("^[%a][%w_]*%.[%w_%.]+$") then
    return nil, "event_type"
  end
  local moduleId = tostring(ctx.module_id or "")
  if moduleId == "" or #moduleId > M.LIMITS.module_id then
    return nil, "module_id"
  end
  local severity = tostring(fields.severity or "info")
  if M.SEVERITIES[severity] == nil then
    return nil, "severity"
  end
  local evidence = tostring(fields.evidence_source or "")
  if not M.EVIDENCE[evidence] then
    return nil, "evidence_source"
  end
  local quality = tostring(fields.quality or "confirmed")
  if not M.QUALITY[quality] then
    return nil, "quality"
  end
  local sequence = tonumber(ctx.sequence)
  if sequence == nil then
    return nil, "sequence"
  end
  local payload, cut = M.bound(M.redact(fields.payload or {}))
  if type(payload) ~= "table" then
    payload = { value = payload }
  end
  if M.approxSize(payload) > M.LIMITS.payload_bytes then
    return nil, "payload_too_large"
  end
  if cut then
    quality = "partial"
  end
  local correlation = fields.correlation_id
  if correlation ~= nil then
    correlation = tostring(correlation)
    if correlation == "" then
      correlation = nil
    elseif #correlation > M.LIMITS.correlation_id then
      return nil, "correlation_id"
    end
  end
  local label = fields.label
  if label ~= nil then
    label = tostring(label):sub(1, M.LIMITS.label)
  end
  local instance = tostring(ctx.instance_id or "")
  local bootId = ctx.boot_id ~= nil and tostring(ctx.boot_id) or nil
  local env = {
    event_id = string.format("%s:%s:%s:%d", moduleId, instance, bootId or "nb", sequence),
    schema_version = M.SCHEMA_VERSION,
    event_type = eventType,
    module_id = moduleId,
    source_driver_instance_id = instance,
    installation_id = ctx.installation_id, -- the Agent fills this; a module leaves it nil
    device_id = tonumber(fields.device_id),
    room_id = tonumber(fields.room_id),
    observed_at = tostring(fields.observed_at or ctx.observed_at or ""),
    boot_id = bootId,
    sequence = sequence,
    correlation_id = correlation,
    severity = severity,
    evidence_source = evidence,
    quality = quality,
    label = label,
    payload = payload,
  }
  if env.observed_at == "" then
    return nil, "observed_at"
  end
  return env
end

--- Validates an envelope as received (the Agent on a module frame; the server
--- on upload — same rules, mirrored in TypeScript).
--- @param env any
--- @param ownerModule string|nil when set, the module that must own the prefix
--- @return boolean ok, string|nil reason
function M.validate(env, ownerModule)
  if type(env) ~= "table" then
    return false, "malformed"
  end
  if env.schema_version ~= M.SCHEMA_VERSION then
    return false, "schema_version"
  end
  if not isNonEmptyString(env.event_id) or #env.event_id > M.LIMITS.event_id then
    return false, "event_id"
  end
  if not isNonEmptyString(env.event_type) or #env.event_type > M.LIMITS.event_type then
    return false, "event_type"
  end
  if not isNonEmptyString(env.module_id) or #env.module_id > M.LIMITS.module_id then
    return false, "module_id"
  end
  if ownerModule ~= nil and env.module_id ~= ownerModule then
    return false, "module_mismatch"
  end
  local prefixes = M.PREFIXES[env.module_id]
  if prefixes ~= nil then
    local owned = false
    for _, p in ipairs(prefixes) do
      if env.event_type:sub(1, #p) == p then
        owned = true
        break
      end
    end
    if not owned then
      return false, "event_type_not_owned"
    end
  end
  if not isNonEmptyString(env.observed_at) then
    return false, "observed_at"
  end
  if type(env.sequence) ~= "number" then
    return false, "sequence"
  end
  if M.SEVERITIES[tostring(env.severity)] == nil then
    return false, "severity"
  end
  if not M.EVIDENCE[tostring(env.evidence_source)] then
    return false, "evidence_source"
  end
  if not M.QUALITY[tostring(env.quality)] then
    return false, "quality"
  end
  if env.payload ~= nil and type(env.payload) ~= "table" then
    return false, "payload"
  end
  if M.approxSize(env.payload or {}) > M.LIMITS.payload_bytes then
    return false, "payload_too_large"
  end
  if
    env.correlation_id ~= nil
    and (type(env.correlation_id) ~= "string" or #env.correlation_id > M.LIMITS.correlation_id)
  then
    return false, "correlation_id"
  end
  return true
end

return M
