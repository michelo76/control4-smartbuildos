--- SmartBuildOS AI Core — the report hub (pure; injected clock).
---
--- Every SmartBuildOS root driver reports to AI Core over the module bus
--- (capability `ai_core.report` v1, sent by src/sbos/aireport.lua). This
--- module is the receiving side:
---
---   validate   closed kinds (describe / state / event / diagnostic), v = 1,
---              closed keys, the size bounds, and the SHAPES the platform
---              accepts in `driver_reports` (P:src/lib/ai-core/drivers/
---              wire.ts): one item the platform would refuse fails its whole
---              batch there, so such a report is refused HERE, never queued.
---              Free text is data: control, bidi and line/paragraph
---              separator characters are removed and it is cut to its bound;
---              ids, keys, enum values and hashes are refused, never repaired.
---   identity   the sender is the module id and instance id the AGENT stamped
---              on the request (from_module_id / from_instance_id). A report
---              that names a sender itself has an unknown key and is refused.
---   picture    per reporting instance (at most 48, least recently heard
---              evicted, counted): the describe hash and when it came, the
---              driver's name/version/file, the declared query and action
---              ids, the latest state facts, per-kind counters and the
---              per-minute windows. Describes are NOT persisted (ruling 19):
---              after an AI Core restart every answer says need_describe.
---   upload     describe and state are latest-wins per instance until they
---              are uploaded; events and diagnostics wait in ONE ring of 200
---              (drop-oldest, counted). takeBatch() builds one
---              `driver_reports` body (<= 64 items, <= the 16 KB cloud body)
---              at most 3 times a rolling minute, one in flight at a time.
---              A describe counts as uploaded only when the cloud ACCEPTED
---              the batch that carried it: after a refusal, a timeout or an
---              unreachable cloud it waits again (unless a newer one
---              replaced it); the same for the latest state (ruling 23);
---              and the next batch backs off (60 s doubling
---              to 10 min, reset by a delivered batch).
---
--- Nothing here interprets report text, runs anything a report names, or
--- turns a declaration into an instruction.

local Commands = require("aicore.commands")
local Policy = require("sbos.modulepolicy")
JSON = JSON or require("JSON")

local M = {}

M.CAPABILITY = "ai_core.report"
M.CAPABILITY_VERSION = 1
M.REPORT_VERSION = 1

M.LIMITS = {
  args_bytes = 16 * 1024, -- one report (the bus bound)
  describe_bytes = 8 * 1024, -- one describe (what AI Core keeps per instance)
  instances = 48, -- reporting instances held (the Agent's registry cap)
  ring = 200, -- events + diagnostics waiting for upload
  batch_items = 64, -- driver_reports items (wire.ts reportsPerBatch)
  batch_bytes = 16 * 1024, -- the cloud body (modulepolicy cloud_body_bytes)
  batches_per_minute = 3,
  batch_interval_seconds = 20, -- the driver's flush timer
  -- After a batch that did not land (refused, timed out, unreachable) the
  -- next one waits backoff_base_seconds, doubling per consecutive failure up
  -- to backoff_max_seconds; a delivered batch resets it. Against a cloud
  -- that keeps refusing, the steady state is one batch every 10 minutes.
  backoff_base_seconds = 60,
  backoff_max_seconds = 600,
  describe_same_hash_seconds = 600,
  -- text, in code points (the platform counts code points)
  name = 64,
  version = 32,
  sku = 40,
  file = 64,
  summary = 200,
  controls = 32,
  control_id = 48,
  control_label = 64,
  vocabulary = 24,
  vocabulary_len = 40,
  queries = 8,
  actions = 8,
  params = 6,
  description = 200,
  title = 80,
  param_values = 16,
  param_value_len = 40,
  param_max_len = 64,
  facts = 32,
  fact_len = 120,
  event_data = 16,
  text = 240,
  result_text = 240,
  data_depth = 3,
  -- driver operations (run_driver_query / invoke_driver_action)
  ops_in_flight = 8,
  recent_actions = 64,
}

--- Per instance, per rolling minute (spec §3.2).
M.RATES = { state = 6, event = 10, diagnostic = 6 }

M.KINDS = { describe = true, state = true, event = true, diagnostic = true }
M.CLASSES = {
  light = true,
  shade = true,
  climate = true,
  lock = true,
  security = true,
  media = true,
  sensor = true,
  power = true,
  network = true,
  scene = true,
  mode = true,
  weather = true,
  other = true,
}
M.SEVERITIES = { info = true, warning = true, fault = true }
M.RISKS = { low = true, medium = true, high = true }
M.PARAM_TYPES = { enum = true, integer = true, number = true, boolean = true, string = true }
--- The answer's ai_core.state values (what aireport understands).
M.STATES = { ready = true, unlicensed = true, agent_unpaired = true, cloud_unreachable = true }
--- driver_query_result status.
M.RESULT_STATUSES = { "completed", "failed" }
--- driver_action_result status (ruling 23): `started` = the driver's handler
--- began work that finishes later (ai.action answered in_progress); never
--- recorded as completed.
M.ACTION_STATUSES = { "started", "completed", "failed" }

local KEYS = {
  describe = { "driver", "summary", "controls", "vocabulary", "queries", "actions", "hash" },
  state = { "facts" },
  event = { "type", "text", "data", "at" },
  diagnostic = { "severity", "code", "text", "at" },
}
M.KIND_KEYS = KEYS

local EPOCH_MIN, EPOCH_MAX = 1000000000, 4102444800

-- ── text and value helpers ──────────────────────────────────────────────────

local function encode(v)
  local ok, out = pcall(function()
    return JSON:encode(v)
  end)
  return ok and out or nil
end
M._encode = encode

local function finite(n)
  return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end

local function whole(n)
  return finite(n) and n == math.floor(n)
end

local function isArray(t)
  if type(t) ~= "table" then
    return false
  end
  local n = 0
  for k in pairs(t) do
    if type(k) ~= "number" then
      return false
    end
    n = n + 1
  end
  return n == #t
end

local function isMap(t)
  if type(t) ~= "table" then
    return false
  end
  for k in pairs(t) do
    if type(k) ~= "string" then
      return false
    end
  end
  return true
end

local function closed(t, list)
  local allowed = {}
  for _, k in ipairs(list) do
    allowed[k] = true
  end
  for k in pairs(t) do
    if not allowed[k] then
      return false
    end
  end
  return true
end

local function stripBidi(s)
  s = s:gsub("\226\128[\142\143\170-\174]", "") -- U+200E/200F, U+202A-202E
  s = s:gsub("\226\129[\166-\169]", "") -- U+2066-2069
  s = s:gsub("\216\156", "") -- U+061C
  return s
end

--- Free text: bidi characters removed, every character the platform refuses
--- (C0, DEL, C1, U+2028/2029 — newline and tab included, so it is one line)
--- turned into a space, ends trimmed, cut to `max` code points.
function M.clean(s, max)
  if type(s) ~= "string" then
    return nil
  end
  return Commands.sanitise(stripBidi(s), max)
end

--- An identifier-like string (enum value, control id): refused unless it is
--- already clean and within its bound. Never repaired.
local function exact(s, max)
  return type(s) == "string" and s ~= "" and M.clean(s, max) == s
end

local function pattern(s, p)
  return type(s) == "string" and s:match(p) ~= nil
end

local DECL_ID = "^[a-z][a-z0-9_]*$" -- with a 1..48 length check
local function declId(s)
  return pattern(s, DECL_ID) and #s <= 48
end
local function paramName(s)
  return pattern(s, DECL_ID) and #s <= 32
end
local function code(s)
  return pattern(s, "^[a-z0-9_%.]+$") and #s <= 48
end
M.validModuleId = function(s)
  return pattern(s, "^[a-z][a-z0-9_]+$") and #s >= 3 and #s <= 48
end
M.validInstanceId = function(s)
  return pattern(s, "^%d+$") and #s <= 12
end

-- ── validation (one report → one driver_reports item) ───────────────────────

local function scalarMap(t, maxKeys)
  if not isMap(t) then
    return nil
  end
  local out, n = JSON:newObject({}), 0
  for k, v in pairs(t) do
    n = n + 1
    if n > maxKeys or not declId(k) then
      return nil
    end
    if type(v) == "string" then
      out[k] = M.clean(v, M.LIMITS.fact_len)
    elseif type(v) == "boolean" or finite(v) then
      out[k] = v
    else
      return nil
    end
  end
  return out
end

local function param(p)
  if type(p) ~= "table" or not closed(p, { "name", "type", "values", "min", "max", "max_len", "required" }) then
    return nil
  end
  if not paramName(p.name) or not M.PARAM_TYPES[p.type] or type(p.required) ~= "boolean" then
    return nil
  end
  local out = { name = p.name, type = p.type, required = p.required }
  if p.type == "enum" then
    if not isArray(p.values) or #p.values < 1 or #p.values > M.LIMITS.param_values then
      return nil
    end
    out.values = {}
    for i, v in ipairs(p.values) do
      if not exact(v, M.LIMITS.param_value_len) then
        return nil
      end
      out.values[i] = v
    end
  elseif p.values ~= nil then
    return nil
  end
  local numeric = p.type == "integer" or p.type == "number"
  for _, k in ipairs({ "min", "max" }) do
    if p[k] ~= nil then
      if not numeric or not finite(p[k]) or (p.type == "integer" and not whole(p[k])) then
        return nil
      end
      out[k] = p[k]
    end
  end
  if out.min ~= nil and out.max ~= nil and out.min > out.max then
    return nil
  end
  if p.max_len ~= nil then
    if p.type ~= "string" or not whole(p.max_len) or p.max_len < 1 or p.max_len > M.LIMITS.param_max_len then
      return nil
    end
    out.max_len = p.max_len
  end
  return out
end

local function params(list)
  if not isArray(list) or #list > M.LIMITS.params then
    return nil
  end
  local out, seen = {}, {}
  for i, p in ipairs(list) do
    local q = param(p)
    if q == nil or seen[q.name] then
      return nil
    end
    seen[q.name] = true
    out[i] = q
  end
  return out
end

--- Non-empty cleaned text (the platform refuses an empty one).
local function needText(s, max)
  local c = M.clean(s, max)
  if c == nil or c == "" then
    return nil
  end
  return c
end

local function decls(list, maxN, action)
  if not isArray(list) or #list > maxN then
    return nil
  end
  local out, seen = {}, {}
  for i, d in ipairs(list) do
    local keys = action and { "id", "title", "description", "params", "risk" } or { "id", "description", "params" }
    if type(d) ~= "table" or not closed(d, keys) or not declId(d.id) or seen[d.id] then
      return nil
    end
    seen[d.id] = true
    local e = { id = d.id, description = needText(d.description, M.LIMITS.description), params = params(d.params) }
    if e.description == nil or e.params == nil then
      return nil
    end
    if action then
      e.title = needText(d.title, M.LIMITS.title)
      e.risk = M.RISKS[d.risk] and d.risk or nil
      if e.title == nil or e.risk == nil then
        return nil
      end
    end
    out[i] = e
  end
  return out
end

local function describeBody(a, item)
  local d = a.driver
  if type(d) ~= "table" or not closed(d, { "name", "version", "sku", "file" }) then
    return "driver"
  end
  item.driver = {
    name = needText(d.name, M.LIMITS.name),
    version = needText(d.version, M.LIMITS.version),
    sku = M.clean(d.sku, M.LIMITS.sku),
    file = needText(d.file, M.LIMITS.file),
  }
  if item.driver.name == nil or item.driver.version == nil or item.driver.sku == nil or item.driver.file == nil then
    return "driver"
  end
  item.summary = needText(a.summary, M.LIMITS.summary)
  if item.summary == nil then
    return "summary"
  end
  if not isArray(a.controls) or #a.controls > M.LIMITS.controls then
    return "controls"
  end
  item.controls = {}
  local seen = {}
  for i, c in ipairs(a.controls) do
    if
      type(c) ~= "table"
      or not closed(c, { "id", "label", "class" })
      or not exact(c.id, M.LIMITS.control_id)
      or seen[c.id]
      or not M.CLASSES[c.class]
    then
      return "controls"
    end
    seen[c.id] = true
    local label = needText(c.label, M.LIMITS.control_label)
    if label == nil then
      return "controls"
    end
    item.controls[i] = { id = c.id, label = label, class = c.class }
  end
  if not isArray(a.vocabulary) or #a.vocabulary > M.LIMITS.vocabulary then
    return "vocabulary"
  end
  item.vocabulary = {}
  for i, w in ipairs(a.vocabulary) do
    item.vocabulary[i] = needText(w, M.LIMITS.vocabulary_len)
    if item.vocabulary[i] == nil then
      return "vocabulary"
    end
  end
  item.queries = decls(a.queries, M.LIMITS.queries, false)
  if item.queries == nil then
    return "queries"
  end
  item.actions = decls(a.actions, M.LIMITS.actions, true)
  if item.actions == nil then
    return "actions"
  end
  -- 16 lower-case hex: the helper's fingerprint (aireport.hash); conductor
  -- ruling, the platform moves its DECLARATION_HASH to 16.
  if not pattern(a.hash, "^%x+$") or #a.hash ~= 16 or a.hash:lower() ~= a.hash then
    return "hash"
  end
  item.hash = a.hash
  return nil
end

--- Validates one report as the bus delivered it. `fromModule` /
--- `fromInstance` are the AGENT's stamp (never taken from `args`).
--- @return table|nil item, string|nil reason (invalid | too_large | unsupported_version), string|nil field
function M.validate(fromModule, fromInstance, args)
  if not M.validModuleId(fromModule) or not M.validInstanceId(fromInstance) then
    return nil, "invalid", "sender"
  end
  if type(args) ~= "table" then
    return nil, "invalid", "args"
  end
  if args.v ~= M.REPORT_VERSION then
    if whole(args.v) and args.v > M.REPORT_VERSION then
      return nil, "unsupported_version", "v"
    end
    return nil, "invalid", "v"
  end
  local kind = args.kind
  if type(kind) ~= "string" or not M.KINDS[kind] then
    return nil, "invalid", "kind"
  end
  local keys = { "v", "kind" }
  for _, k in ipairs(KEYS[kind]) do
    keys[#keys + 1] = k
    if args[k] == nil then
      return nil, "invalid", k
    end
  end
  if not closed(args, keys) then
    return nil, "invalid", "keys"
  end
  local raw = encode(args)
  if raw == nil then
    return nil, "invalid", "encode"
  end
  if #raw > M.LIMITS.args_bytes or (kind == "describe" and #raw > M.LIMITS.describe_bytes) then
    return nil, "too_large", "bytes"
  end
  local item = { from_module_id = fromModule, from_instance_id = fromInstance, v = M.REPORT_VERSION, kind = kind }
  if kind == "describe" then
    local bad = describeBody(args, item)
    if bad then
      return nil, "invalid", bad
    end
  elseif kind == "state" then
    item.facts = scalarMap(args.facts, M.LIMITS.facts)
    if item.facts == nil then
      return nil, "invalid", "facts"
    end
  else
    if kind == "event" then
      if not code(args.type) then
        return nil, "invalid", "type"
      end
      item.type = args.type
      item.data = scalarMap(args.data, M.LIMITS.event_data)
      if item.data == nil then
        return nil, "invalid", "data"
      end
    else
      if not M.SEVERITIES[args.severity] then
        return nil, "invalid", "severity"
      end
      if not code(args.code) then
        return nil, "invalid", "code"
      end
      item.severity, item.code = args.severity, args.code
    end
    item.text = M.clean(args.text, M.LIMITS.text)
    if item.text == nil then
      return nil, "invalid", "text"
    end
    -- Epoch seconds, a whole number (conductor ruling: end to end).
    if not whole(args.at) or args.at < EPOCH_MIN or args.at > EPOCH_MAX then
      return nil, "invalid", "at"
    end
    item.at = args.at
  end
  return item
end

-- ── the hub ─────────────────────────────────────────────────────────────────

local Hub = {}
Hub.__index = Hub

local COUNTERS = {
  "received",
  "accepted",
  "refused",
  "invalid",
  "too_large",
  "rate_limited",
  "unsupported_version",
  "unlicensed",
  "need_describe",
  "coalesced",
  "ring_dropped",
  "evicted",
  "batches_sent",
  "batches_delivered",
  "batches_retried",
  "batches_refused",
  "items_delivered",
  "items_dropped",
  "queries",
  "actions",
  "ops_refused",
}

--- opts: { now = fun():number (epoch seconds) }
function M.new(opts)
  opts = opts or {}
  local self = setmetatable({
    now = opts.now or os.time,
    mods = {}, -- "module@instance" → picture
    count = 0,
    ring = {}, -- { key, item }
    dropped = 0, -- since the last delivered batch (driver_reports `dropped`)
    sends = {}, -- epoch of each batch sent, last minute
    inflight = nil,
    failures = 0, -- consecutive batches that did not land
    backoffUntil = nil, -- no batch before this epoch
    ops = 0, -- driver operations in flight
    recentActions = {}, -- ai_action_id → true
    recentOrder = {},
    counters = {},
  }, Hub)
  for _, k in ipairs(COUNTERS) do
    self.counters[k] = 0
  end
  return self
end

local function bump(self, k, n)
  self.counters[k] = (self.counters[k] or 0) + (n or 1)
end

local function windowTake(m, kind, now, rate)
  local keep = {}
  for _, at in ipairs(m.windows[kind]) do
    if now - at < 60 then
      keep[#keep + 1] = at
    end
  end
  m.windows[kind] = keep
  if #keep >= rate then
    return false
  end
  keep[#keep + 1] = now
  return true
end

function Hub:picture(moduleId, instanceId)
  return self.mods[moduleId .. "@" .. instanceId]
end

local function evictOne(self)
  local oldestKey, oldestAt
  for k, m in pairs(self.mods) do
    if oldestAt == nil or m.last_report_at < oldestAt or (m.last_report_at == oldestAt and k < oldestKey) then
      oldestKey, oldestAt = k, m.last_report_at
    end
  end
  if oldestKey ~= nil then
    local m = self.mods[oldestKey]
    local lost = (m.pendingDescribe and 1 or 0) + (m.pendingState and 1 or 0)
    self.mods[oldestKey] = nil
    self.count = self.count - 1
    self.dropped = self.dropped + lost
    bump(self, "evicted")
    bump(self, "items_dropped", lost)
  end
end

local function ensure(self, moduleId, instanceId)
  local key = moduleId .. "@" .. instanceId
  local m = self.mods[key]
  if m == nil then
    if self.count >= M.LIMITS.instances then
      evictOne(self)
    end
    m = {
      module_id = moduleId,
      instance_id = instanceId,
      describe_hash = nil,
      describe_at = nil,
      driver = nil,
      query_ids = {},
      action_ids = {},
      facts = nil,
      state_at = nil,
      last_report_at = self.now(),
      counts = { describe = 0, state = 0, event = 0, diagnostic = 0, refused = 0 },
      windows = { state = {}, event = {}, diagnostic = {} },
      pendingDescribe = nil,
      pendingState = nil,
    }
    self.mods[key] = m
    self.count = self.count + 1
  end
  return m, key
end

local function idsOf(list)
  local out = {}
  for i, d in ipairs(list) do
    out[i] = d.id
  end
  return out
end

--- One report from the bus. ctx = { state = ready|unlicensed|agent_unpaired|
--- cloud_unreachable, version = AI Core's directory driver_version }.
--- Returns the answer the helper consumes:
---   { accepted, ai_core = { state, version }, reason?, need_describe? }
function Hub:receive(fromModule, fromInstance, args, ctx)
  ctx = ctx or {}
  local state = M.STATES[ctx.state] and ctx.state or "ready"
  local answer = { accepted = false, ai_core = { state = state, version = tostring(ctx.version or "") } }
  bump(self, "received")
  fromModule = type(fromModule) == "string" and fromModule or ""
  fromInstance = fromInstance ~= nil and tostring(fromInstance) or ""
  if state == "unlicensed" then
    -- Answered, never accepted, nothing kept (ruling 19).
    bump(self, "unlicensed")
    return answer
  end
  local item, reason = M.validate(fromModule, fromInstance, args)
  local m = item and self:picture(fromModule, fromInstance) or nil
  if item ~= nil then
    local now = self.now()
    local kind = item.kind
    if kind == "describe" then
      local existing = m
      if
        existing ~= nil
        and existing.describe_hash == item.hash
        and existing.describe_at ~= nil
        and now - existing.describe_at < M.LIMITS.describe_same_hash_seconds
      then
        reason = "rate_limited"
      end
    elseif m ~= nil and not windowTake(m, kind, now, M.RATES[kind]) then
      reason = "rate_limited"
    end
    if reason == nil then
      local key
      m, key = ensure(self, fromModule, fromInstance)
      if kind ~= "describe" and #m.windows[kind] == 0 then
        windowTake(m, kind, now, M.RATES[kind]) -- the first one of a fresh picture
      end
      m.last_report_at = now
      m.counts[kind] = m.counts[kind] + 1
      if kind == "describe" then
        m.describe_hash, m.describe_at = item.hash, now
        m.driver = { name = item.driver.name, version = item.driver.version, file = item.driver.file }
        m.query_ids, m.action_ids = idsOf(item.queries), idsOf(item.actions)
        m.pendingDescribe = item
      elseif kind == "state" then
        if m.pendingState ~= nil then
          bump(self, "coalesced")
        end
        m.facts, m.state_at = item.facts, now
        m.pendingState = item
      else
        self.ring[#self.ring + 1] = { key = key, item = item }
        while #self.ring > M.LIMITS.ring do
          table.remove(self.ring, 1)
          self.dropped = self.dropped + 1
          bump(self, "ring_dropped")
          bump(self, "items_dropped")
        end
      end
      answer.accepted = true
      bump(self, "accepted")
    end
  end
  if not answer.accepted then
    answer.reason = reason or "invalid"
    bump(self, "refused")
    bump(self, answer.reason)
    -- Over budget, invalid or oversize: dropped (ruling: `dropped`).
    self.dropped = self.dropped + 1
    if m ~= nil then
      m.counts.refused = m.counts.refused + 1
    end
  end
  -- Ruling 19: whenever AI Core holds no describe for this sender, say so
  -- (after an AI Core restart nothing is held). Only for a sender the Agent
  -- stamped with ids the platform could ever take.
  if M.validModuleId(fromModule) and M.validInstanceId(fromInstance) then
    local held = self:picture(fromModule, fromInstance)
    if held == nil or held.describe_hash == nil then
      answer.need_describe = true
      bump(self, "need_describe")
    end
  end
  return answer
end

--- Whether a batch may go now: something waits, nothing in flight, fewer
--- than batches_per_minute sent in the last 60 s.
function Hub:due()
  if self.inflight ~= nil then
    return false
  end
  local now = self.now()
  if self.backoffUntil ~= nil and now < self.backoffUntil then
    return false
  end
  local keep = {}
  for _, at in ipairs(self.sends) do
    if now - at < 60 then
      keep[#keep + 1] = at
    end
  end
  self.sends = keep
  if #keep >= M.LIMITS.batches_per_minute then
    return false
  end
  if #self.ring > 0 then
    return true
  end
  for _, m in pairs(self.mods) do
    if m.pendingDescribe or m.pendingState then
      return true
    end
  end
  return false
end

local function sortedKeys(t)
  local out = {}
  for k in pairs(t) do
    out[#out + 1] = k
  end
  table.sort(out)
  return out
end

--- Builds the next driver_reports body (or nil when not due) and marks it in
--- flight: describes first, then states, then events and diagnostics oldest
--- first, as many as fit 64 items and the 16 KB body.
function Hub:takeBatch(requestId)
  if not self:due() then
    return nil
  end
  local body = { request_id = requestId }
  if self.dropped > 0 then
    body.dropped = self.dropped
  end
  local overhead = #encode({ request_id = requestId, reports = { 0 }, dropped = self.dropped }) - 1
  local room = M.LIMITS.batch_bytes - overhead - 64 -- margin for the encoder
  local items, taken, used = {}, {}, 0
  local function try(item)
    if #items >= M.LIMITS.batch_items then
      return false
    end
    local raw = encode(item)
    if raw == nil then
      return false
    end
    local add = #raw + (#items > 0 and 1 or 0)
    if used + add > room then
      return false
    end
    used = used + add
    items[#items + 1] = item
    return true
  end
  local keys = sortedKeys(self.mods)
  for _, k in ipairs(keys) do
    local m = self.mods[k]
    if m.pendingDescribe and try(m.pendingDescribe) then
      taken[#taken + 1] = { key = k, slot = "pendingDescribe", item = m.pendingDescribe }
      m.pendingDescribe = nil
    end
  end
  for _, k in ipairs(keys) do
    local m = self.mods[k]
    if m.pendingState and try(m.pendingState) then
      taken[#taken + 1] = { key = k, slot = "pendingState", item = m.pendingState }
      m.pendingState = nil
    end
  end
  local n = 0
  for _, e in ipairs(self.ring) do
    if not try(e.item) then
      break
    end
    n = n + 1
    taken[#taken + 1] = { key = e.key, ring = true, item = e.item }
  end
  for _ = 1, n do
    table.remove(self.ring, 1)
  end
  if #items == 0 then
    return nil
  end
  body.reports = items
  self.inflight = { taken = taken, dropped = body.dropped or 0 }
  self.sends[#self.sends + 1] = self.now()
  bump(self, "batches_sent")
  return body
end

--- Puts a taken describe or state back unless something newer replaced it;
--- an evicted instance's item is dropped and counted.
local function putBack(self, t)
  local m = self.mods[t.key]
  if m == nil then
    self.dropped = self.dropped + 1
    bump(self, "items_dropped")
  elseif m[t.slot] == nil then
    m[t.slot] = t.item
  end
end

--- One more batch that did not land: the next waits longer.
local function backOff(self)
  self.failures = self.failures + 1
  local wait = M.LIMITS.backoff_base_seconds * 2 ^ math.min(self.failures - 1, 10)
  self.backoffUntil = self.now() + math.min(wait, M.LIMITS.backoff_max_seconds)
end

--- The outcome of the batch in flight:
---   "delivered" the cloud took it (the dropped count it carried is settled;
---               the backoff is reset)
---   "retry"     it never got there (unreachable / timeout / rate limit):
---               describe and state go back unless something newer replaced
---               them; events go back to the front of the ring (bounded)
---   "refused"   the cloud said no: describes and states go back unless
---               something newer replaced them (each is uploaded only when
---               the cloud accepted it: KI-51, ruling 23); events and
---               diagnostics are dropped and counted
--- After "retry" or "refused" the next batch backs off.
function Hub:settle(outcome)
  local f = self.inflight
  self.inflight = nil
  if f == nil then
    return
  end
  if outcome == "delivered" then
    bump(self, "batches_delivered")
    bump(self, "items_delivered", #f.taken)
    self.dropped = math.max(0, self.dropped - f.dropped)
    self.failures, self.backoffUntil = 0, nil
    return
  end
  backOff(self)
  if outcome == "retry" then
    bump(self, "batches_retried")
    local back = {}
    for _, t in ipairs(f.taken) do
      if t.ring then
        back[#back + 1] = { key = t.key, item = t.item }
      else
        putBack(self, t)
      end
    end
    for i = #back, 1, -1 do
      table.insert(self.ring, 1, back[i])
    end
    while #self.ring > M.LIMITS.ring do
      table.remove(self.ring, 1)
      self.dropped = self.dropped + 1
      bump(self, "ring_dropped")
      bump(self, "items_dropped")
    end
    return
  end
  bump(self, "batches_refused")
  local lost = 0
  for _, t in ipairs(f.taken) do
    if t.slot == "pendingDescribe" or t.slot == "pendingState" then
      putBack(self, t)
    else
      lost = lost + 1
    end
  end
  bump(self, "items_dropped", lost)
  self.dropped = self.dropped + lost
end

--- Cloud answer → settle outcome. Codes after which the SAME batch may go
--- again later; everything else is a refusal.
local RETRY = {
  cloud_unreachable = true,
  deadline_exceeded = true,
  target_unavailable = true,
  rate_limited = true,
  agent_not_paired = true,
  incompatible_protocol = true,
}
function M.outcome(answer)
  answer = type(answer) == "table" and answer or {}
  if answer.status == "ok" then
    return "delivered"
  end
  if RETRY[answer.error_code] then
    return "retry"
  end
  return "refused"
end

function Hub:pendingCount()
  local n = #self.ring
  for _, m in pairs(self.mods) do
    n = n + (m.pendingDescribe and 1 or 0) + (m.pendingState and 1 or 0)
  end
  return n
end

function Hub:modules()
  local out = {}
  for _, k in ipairs(sortedKeys(self.mods)) do
    out[#out + 1] = self.mods[k]
  end
  return out
end

-- ── driver operations: guards and result bodies ─────────────────────────────

--- Admits one run_driver_query / invoke_driver_action. An ai_action_id is
--- admitted ONCE per AI Core run (a re-sent approval never runs twice).
--- @return boolean ok, string|nil error_code, string|nil reason
function Hub:beginOp(aiActionId)
  if self.ops >= M.LIMITS.ops_in_flight then
    return false, "rate_limited", "busy"
  end
  if aiActionId ~= nil then
    if self.recentActions[aiActionId] then
      return false, "duplicate_request", "already_invoked"
    end
    self.recentActions[aiActionId] = true
    self.recentOrder[#self.recentOrder + 1] = aiActionId
    while #self.recentOrder > M.LIMITS.recent_actions do
      self.recentActions[table.remove(self.recentOrder, 1)] = nil
    end
    bump(self, "actions")
  else
    bump(self, "queries")
  end
  self.ops = self.ops + 1
  return true
end

function Hub:endOp()
  self.ops = math.max(0, self.ops - 1)
end

function Hub:refuseOp()
  bump(self, "ops_refused")
end

local UNPRINTABLE_BYTES = {
  { "[%z\1-\8\11-\31\127]", " " }, -- C0 except tab/newline, DEL
  { "\194[\128-\159]", " " }, -- C1
  { "\226\128[\168\169]", " " }, -- U+2028 / U+2029
}

--- A query answer's data as the platform takes it (wire.ts validDriverData):
--- scalars, arrays and objects nested at most 3 containers deep, finite
--- numbers, keys 1..64 bytes without control characters. Strings lose the
--- characters the platform refuses (replaced, never cut). nil = unusable.
local function boundData(v, depth)
  local t = type(v)
  if t == "boolean" then
    return v
  elseif t == "number" then
    return finite(v) and v or nil
  elseif t == "string" then
    for _, r in ipairs(UNPRINTABLE_BYTES) do
      v = v:gsub(r[1], r[2])
    end
    return v
  elseif t == "table" then
    if depth >= M.LIMITS.data_depth then
      return nil
    end
    local out = {}
    for k, x in pairs(v) do
      if type(k) == "string" then
        if k == "" or #k > 64 or k:find("[%z\1-\31\127]") or k:find("\194[\128-\159]") then
          return nil
        end
      elseif type(k) ~= "number" then
        return nil
      end
      local y = boundData(x, depth + 1)
      if y == nil then
        return nil
      end
      out[k] = y
    end
    return out
  end
  return nil
end
M.boundData = boundData

--- driver_query_result body from the declaring driver's ai.query answer
--- (or a local refusal: answer = { status = "error", error_code = … }).
function M.queryResultBody(requestId, queryRef, answer)
  answer = type(answer) == "table" and answer or {}
  local body = { request_id = requestId, query_ref = queryRef }
  local r = type(answer.result) == "table" and answer.result or {}
  if answer.status == "ok" and r.ok == true and r.data ~= nil then
    local data = boundData(r.data, 0)
    if data == nil then
      body.status, body.error_code = "failed", "internal_error"
      return body
    end
    body.status, body.data = "completed", data
    local raw = encode(body)
    if raw == nil then
      body.status, body.data, body.error_code = "failed", nil, "internal_error"
    elseif #raw > M.LIMITS.batch_bytes then
      -- The bus allows a 24 KB answer, the cloud body 16 KB: never cut it.
      body.status, body.data, body.error_code = "failed", nil, "payload_too_large"
    end
    return body
  end
  body.status = "failed"
  if answer.status == "ok" then
    -- The driver's handler answered { ok = false, reason }: it could not.
    body.error_code = "internal_error"
  else
    local c = Policy.code(answer.error_code)
    body.error_code = c ~= "ok" and c or "internal_error"
  end
  return body
end

--- driver_action_result body from the declaring driver's REAL ai.action
--- answer. Only { ok = true } from the driver is `completed`;
--- { ok = true, in_progress = true } is `started` (ruling 23: begun, the
--- outcome follows as the driver's event); a refusal, a changed
--- declaration, an unverified target and no answer are `failed` with the
--- reason as result_text. "Sent" is never "completed".
function M.actionResultBody(requestId, aiActionId, answer, localReason)
  answer = type(answer) == "table" and answer or {}
  local body = { request_id = requestId, ai_action_id = aiActionId }
  local r = type(answer.result) == "table" and answer.result or {}
  local function text(s)
    local c = M.clean(type(s) == "string" and s or nil, M.LIMITS.result_text)
    return (c ~= nil and c ~= "") and c or nil
  end
  if answer.status == "ok" and r.ok == true then
    body.status = r.in_progress == true and "started" or "completed"
    body.result_text = text(r.result_text)
    return body
  end
  body.status = "failed"
  if answer.status == "ok" then
    -- The driver ran its handler and said it did not succeed.
    body.error_code = "internal_error"
    body.result_text = text(r.result_text) or "failed"
    return body
  end
  local c = Policy.code(answer.error_code)
  body.error_code = c ~= "ok" and c or "internal_error"
  if c == "deadline_exceeded" then
    body.result_text = "no_answer: the driver did not answer in time; the outcome is unknown"
  else
    body.result_text = text(localReason) or (code(r.reason) and r.reason) or nil
  end
  return body
end

return M
