-- Cross-repo vocabulary parity: this repo's Agent policy tables and AI Core
-- vocabularies against the platform's TypeScript mirrors (read, never
-- edited). The platform's own test (tests/unit/ai-core-rpc-ops.test.mjs)
-- does the reverse with SBOS_DRIVER_REPO.
--
-- Runs only where the platform checkout is present:
--   SBOS_PLATFORM_REPO=/path/to/smartbuildos make test
-- Without it the file prints SKIP and passes (nothing compared).
--
-- Asserted equal (a failure is a contract break between the two repos):
--   [1] MODULE_COMMANDS.ai_core (Agent) = MODULE_OPERATIONS.ai_core
--       (modules.ts) = AI_CORE_OPERATIONS (protocol.ts) = vocab.OPERATIONS
--   [2] MODULE_CLOUD_OPS.ai_core (modulepolicy) = MODULE_CLOUD_OPS /
--       AI_CORE_CLOUD_OPS (protocol.ts) = vocab.CLOUD_OPS
--   [3] raise_event closed list: vocab.RAISABLE = AI_CORE_COMPOSER_EVENTS
--   [4] the `ai_core.` prefix: envelope.lua PREFIXES.ai_core = MODULE_PREFIXES
--       (envelope.ts) = AI_CORE_EVENT_PREFIX = vocab.EVENT_PREFIX
--   [5] the v2 error vocabulary and its retryable subset and delays
--   [6] request policy (requesters and provider) and topic policy
--   [7] restricted operations: every argument key the platform declares
--       (AI_CORE_OPERATION_ARG_KEYS, RAISE_EVENT_KEYS) or builds
--       (rpc/deliver.ts, actions/service.ts raiseEvent) is ACCEPTED by
--       operations.lua with a value of the platform's shape; result kinds,
--       detail, count and text bounds fit
--   [8] cloud ops: every body key the driver sends is in rpc/ops.ts
--       OP_BODIES (+ COMMON), every required field is in the minimal body,
--       enum lists equal, text bounds fit; {accepted, job_id: null} answers
--       read as completed, job answers as accepted
-- Reported, not asserted ([9] and NOTE lines in [7]/[8]): differences that
-- break nothing today (a key the driver accepts that nobody sends, an op
-- the platform answers `unsupported`, a body it does not validate); each
-- NOTE line names both sides.

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

local ROOT = os.getenv("SBOS_PLATFORM_REPO")
local function read(path)
  local f = io.open(path)
  if f == nil then
    return nil
  end
  local s = f:read("*a")
  f:close()
  return s
end

if ROOT == nil or ROOT == "" or read(ROOT .. "/src/lib/ai-core/protocol.ts") == nil then
  print("  SKIP cross-repo parity: set SBOS_PLATFORM_REPO to a SmartBuildOS platform checkout")
  print("       (src/lib/ai-core/protocol.ts must exist there); nothing was compared")
  print("\n0 passed, 0 failed")
  os.exit(0)
end

local protocolTs = read(ROOT .. "/src/lib/ai-core/protocol.ts")
local modulesTs = assert(read(ROOT .. "/src/lib/control4/flight-recorder/modules.ts"), "modules.ts missing")
local envelopeTs = assert(read(ROOT .. "/src/lib/control4/flight-recorder/envelope.ts"), "envelope.ts missing")
print("platform checkout: " .. ROOT)

-- ── tiny TypeScript literal readers (enough for these files) ────────────────

local CONSTS = {} -- name → string value, for identifiers used inside literals
for name, value in protocolTs:gmatch('export const ([%w_]+) = "([^"]*)";') do
  CONSTS[name] = value
end

--- The balanced literal (`[...]` or `{...}`) that follows `export const NAME`.
local function literal(src, name)
  local at = src:find("export const " .. name .. "[%s:=]")
  if at == nil then
    return nil
  end
  local eq = src:find("=", at, true)
  local open = eq and src:find("[%[{]", eq)
  if open == nil then
    return nil
  end
  local o = src:sub(open, open)
  return src:match("%b" .. o .. (o == "[" and "]" or "}"), open)
end

--- The elements of an array literal: quoted strings, and identifiers that
--- name an exported string constant (`[AI_CORE_MODULE_ID]`).
local function strings(lit)
  local out = {}
  local body = tostring(lit or "")
  local i = 1
  while i <= #body do
    local qs, qe, q = body:find('^"([^"]*)"', i)
    local is, ie, ident = body:find("^([%u][%u%d_]+)", i)
    if qs then
      out[#out + 1] = q
      i = qe + 1
    elseif is then
      if CONSTS[ident] then
        out[#out + 1] = CONSTS[ident]
      end
      i = ie + 1
    else
      i = i + 1
    end
  end
  return out
end

--- { key: [ "a", "b" ] , [IDENT]: IDENT_ARRAY , "k": "v" } → key → list/string.
local function record(src, name)
  local lit = literal(src, name)
  local out = {}
  if lit == nil then
    return nil
  end
  local body = lit:sub(2, -2)
  -- key: [ ... ]
  for key, arr in body:gmatch('["%[]?([%w_%.]+)["%]]?%s*:%s*(%b[])') do
    out[CONSTS[key] or key] = strings(arr)
  end
  -- key: IDENTIFIER (an exported array constant)
  for key, ident in body:gmatch('["%[]?([%w_%.]+)["%]]?%s*:%s*([%u_]+)%s*[,}\n]') do
    local arr = literal(src, ident)
    if arr then
      out[CONSTS[key] or key] = strings(arr)
    end
  end
  -- key: "value"
  for key, value in body:gmatch('"([%w_%.]+)"%s*:%s*"([^"]*)"') do
    out[key] = value
  end
  return out
end

local function set(list)
  local s = {}
  for _, v in ipairs(list or {}) do
    s[v] = true
  end
  return s
end
local function keys(t)
  local out = {}
  for k, v in pairs(t or {}) do
    if v then
      out[#out + 1] = k
    end
  end
  table.sort(out)
  return out
end
local function sorted(list)
  local out = {}
  for _, v in ipairs(list or {}) do
    out[#out + 1] = v
  end
  table.sort(out)
  return out
end
local function same(a, b)
  return table.concat(a, ",") == table.concat(b, ",")
end
local function show(a, b)
  return "driver {" .. table.concat(a, ",") .. "} vs platform {" .. table.concat(b, ",") .. "}"
end

-- ── the driver side ─────────────────────────────────────────────────────────

local V = require("aicore.vocab")
local Policy = require("sbos.modulepolicy")
local Envelope = require("sbos.envelope")
local agentSrc = assert(read("drivers/smartbuildos/driver.lua"))
local mcBlock = agentSrc:match("\nMODULE_COMMANDS = (%b{})")
local agentAiCore = {}
for name in tostring(tostring(mcBlock):match("ai_core = (%b{})")):gmatch("([%w_]+) = true") do
  agentAiCore[#agentAiCore + 1] = name
end
table.sort(agentAiCore)

print("[1] restricted operations")
local opsModules = record(modulesTs, "MODULE_OPERATIONS")
local opsTs = sorted(strings(literal(protocolTs, "AI_CORE_OPERATIONS")))
check("the Agent's MODULE_COMMANDS.ai_core is readable", #agentAiCore > 0)
check(
  "MODULE_COMMANDS.ai_core = MODULE_OPERATIONS.ai_core (modules.ts)",
  same(agentAiCore, sorted(opsModules and opsModules.ai_core)),
  show(agentAiCore, sorted(opsModules and opsModules.ai_core))
)
check("= AI_CORE_OPERATIONS (protocol.ts)", same(agentAiCore, opsTs), show(agentAiCore, opsTs))
check("= the driver's registered vocab.OPERATIONS", same(agentAiCore, sorted(V.OPERATIONS)))

print("[2] cloud ops")
local cloudTs = sorted(strings(literal(protocolTs, "AI_CORE_CLOUD_OPS")))
local cloudMap = record(protocolTs, "MODULE_CLOUD_OPS")
check(
  "MODULE_CLOUD_OPS.ai_core (Agent) = AI_CORE_CLOUD_OPS",
  same(keys(Policy.CLOUD_OPS.ai_core), cloudTs),
  show(keys(Policy.CLOUD_OPS.ai_core), cloudTs)
)
check(
  "= MODULE_CLOUD_OPS.ai_core (protocol.ts)",
  same(keys(Policy.CLOUD_OPS.ai_core), sorted(cloudMap and cloudMap.ai_core)),
  show(keys(Policy.CLOUD_OPS.ai_core), sorted(cloudMap and cloudMap.ai_core))
)
check(
  "MODULE_CLOUD_OPS has no module but ai_core on either side",
  same(keys(Policy.CLOUD_OPS), keys(cloudMap or {})),
  show(keys(Policy.CLOUD_OPS), keys(cloudMap or {}))
)
check("= the driver's vocab.CLOUD_OPS", same(keys(V.CLOUD_OPS), cloudTs))

print("[3] raise_event closed list")
local raiseTs = sorted(strings(literal(protocolTs, "AI_CORE_COMPOSER_EVENTS")))
check("vocab.RAISABLE = AI_CORE_COMPOSER_EVENTS", same(keys(V.RAISABLE), raiseTs), show(keys(V.RAISABLE), raiseTs))

print("[4] the ai_core. prefix")
local prefixesTs = record(envelopeTs, "MODULE_PREFIXES")
check(
  "envelope.lua PREFIXES.ai_core = MODULE_PREFIXES.ai_core (envelope.ts)",
  same(sorted(Envelope.PREFIXES.ai_core), sorted(prefixesTs and prefixesTs.ai_core)),
  show(sorted(Envelope.PREFIXES.ai_core), sorted(prefixesTs and prefixesTs.ai_core))
)
check(
  "AI_CORE_EVENT_PREFIX = vocab.EVENT_PREFIX = ai_core.",
  CONSTS.AI_CORE_EVENT_PREFIX == V.EVENT_PREFIX and V.EVENT_PREFIX == "ai_core."
)
check(
  "AI_CORE_MODULE_ID / SKU / manifest driver agree",
  CONSTS.AI_CORE_MODULE_ID == V.MODULE_ID
    and CONSTS.AI_CORE_SKU == V.SKU
    and CONSTS.AI_CORE_MANIFEST_DRIVER == V.MANIFEST_DRIVER
)

print("[5] the v2 error vocabulary")
local errorsTs = sorted(strings(literal(protocolTs, "MODULE_ERROR_CODES")))
check(
  "modulepolicy.ERRORS = MODULE_ERROR_CODES",
  same(keys(Policy.ERRORS), errorsTs),
  show(keys(Policy.ERRORS), errorsTs)
)
local retryTs = sorted(strings(literal(protocolTs, "RETRYABLE_ERROR_CODES")))
check("RETRYABLE = RETRYABLE_ERROR_CODES", same(keys(Policy.RETRYABLE), retryTs), show(keys(Policy.RETRYABLE), retryTs))
local delays = {}
for n in tostring(literal(protocolTs, "MODULE_RETRY_DELAYS_SECONDS")):gmatch("%d+") do
  delays[#delays + 1] = tonumber(n)
end
check(
  "RETRY_DELAYS = MODULE_RETRY_DELAYS_SECONDS",
  #delays == #Policy.RETRY_DELAYS and delays[1] == Policy.RETRY_DELAYS[1] and delays[2] == Policy.RETRY_DELAYS[2]
)
check(
  "protocol range 1..2 on both sides",
  protocolTs:find("MODULE_PROTOCOL_MIN = " .. Policy.PROTOCOL_MIN .. ";", 1, true) ~= nil
    and protocolTs:find("MODULE_PROTOCOL_MAX = " .. Policy.PROTOCOL_MAX .. ";", 1, true) ~= nil
)

print("[6] request and topic policy")
local reqTs = record(protocolTs, "MODULE_REQUEST_POLICY") or {}
local provTs = record(protocolTs, "MODULE_REQUEST_PROVIDERS") or {}
local reqDriver = {}
for cap in pairs(Policy.REQUEST_POLICY) do
  reqDriver[#reqDriver + 1] = cap
end
table.sort(reqDriver)
check("same capabilities in the request policy", same(reqDriver, keys(reqTs)), show(reqDriver, keys(reqTs)))
local reqWrong = {}
for _, cap in ipairs(reqDriver) do
  local p = Policy.REQUEST_POLICY[cap]
  if not same(keys(p.requesters), sorted(reqTs[cap])) or provTs[cap] ~= p.provider then
    reqWrong[#reqWrong + 1] = cap
  end
end
check("same requesters and provider per capability", #reqWrong == 0, table.concat(reqWrong, ","))
local topicTs = record(protocolTs, "MODULE_TOPIC_POLICY") or {}
local topicDriver = {}
for prefix in pairs(Policy.TOPIC_POLICY) do
  topicDriver[#topicDriver + 1] = prefix
end
table.sort(topicDriver)
check("same topic prefixes", same(topicDriver, keys(topicTs)), show(topicDriver, keys(topicTs)))
local topicWrong = {}
for _, prefix in ipairs(topicDriver) do
  if not same(keys(Policy.TOPIC_POLICY[prefix]), sorted(topicTs[prefix])) then
    topicWrong[#topicWrong + 1] = prefix
  end
end
check("same subscribers per prefix", #topicWrong == 0, table.concat(topicWrong, ","))

-- ── more literal readers: non-exported consts, object literals, functions ───

--- The balanced literal after `const NAME` (exported or not).
local function anyLiteral(src, name)
  local at = src:find("const " .. name .. "[%s:=]")
  if at == nil then
    return nil
  end
  local eq = src:find("=", at, true)
  local open = eq and src:find("[%[{]", eq)
  if open == nil then
    return nil
  end
  local o = src:sub(open, open)
  return src:match("%b" .. o .. (o == "[" and "]" or "}"), open)
end

--- `{ a: {..}, b: {..} }` → ordered list of { name, literal } (one level).
local function entries(lit)
  local out = {}
  for name, body in tostring(lit or ""):sub(2, -2):gmatch("([%w_]+):%s*(%b{})") do
    out[#out + 1] = { name = name, body = body }
  end
  return out
end

--- The keys of an object literal: `k: v`, `...(x ? { k: v } : {})` and
--- shorthand `{ event, detail }`.
local function objectKeys(lit)
  local out, seen = {}, {}
  local body = tostring(lit or ""):sub(2, -2)
  local function add(k)
    if k and not seen[k] then
      seen[k] = true
      out[#out + 1] = k
    end
  end
  for k in body:gmatch("([%a_][%w_]*)%s*:") do
    add(k)
  end
  if body:find(":", 1, true) == nil then
    for part in body:gmatch("[^,]+") do
      add(part:match("^%s*([%a_][%w_]*)%s*$"))
    end
  end
  table.sort(out)
  return out
end

local function minus(a, b)
  local sb, out = set(b), {}
  for _, v in ipairs(a) do
    if not sb[v] then
      out[#out + 1] = v
    end
  end
  return out
end

local notes = 0
local function note(text)
  notes = notes + 1
  print("  NOTE " .. text)
end
local Operations = require("aicore.operations")

local opsTs = assert(read(ROOT .. "/src/lib/ai-core/rpc/ops.ts"), "rpc/ops.ts missing")
local deliverTs = assert(read(ROOT .. "/src/lib/ai-core/rpc/deliver.ts"), "rpc/deliver.ts missing")
local actionsTs = read(ROOT .. "/src/lib/ai-core/actions/service.ts") or ""
local Commands = require("aicore.commands")

print("[7] restricted operations: every argument the platform sends, field by field")
-- Asserted: every key the platform declares or builds for an operation is
-- one the driver's operations.lua ACCEPTS, with a value of the platform's
-- shape (the driver refuses the WHOLE operation for one unknown key, so one
-- such key ends every such operation Failed on the controller). Reported
-- (NOTE): keys the driver accepts that the platform never sends.
local SAMPLE = {
  config = {},
  version = 1,
  response_id = "r-1",
  request_id = "aic-1",
  job_id = "job-1",
  text = "t",
  kind = "answer",
  pending_approvals = 1,
  recommendation_count = 1,
  event = "pattern_detected",
  detail = "d",
  correlation_id = "0d6f9a2e-5b1c-4c8e-9f00-123456789abc",
  active = true,
  reason = "r",
  device_id = 12,
  room_id = 3,
  note = "n",
}
local BASE = {
  apply_config = { config = {}, version = 1 },
  refresh_status = {},
  deliver_result = { response_id = "r-1", text = "t" },
  raise_event = { event = "pattern_detected" },
  set_learning = { active = true },
  run_diagnostic = { device_id = 12 },
}
--- Whether the driver accepts `key` (with the platform's kind of value) on `op`.
local function driverTakes(op, key)
  local args = {}
  for k, v in pairs(BASE[op] or {}) do
    args[k] = v
  end
  if op == "run_diagnostic" and key == "room_id" then
    args.device_id = nil
  end
  args[key] = SAMPLE[key] ~= nil and SAMPLE[key] or "x"
  return Operations.parse(op, args) ~= nil
end
local argKeysTs = record(protocolTs, "AI_CORE_OPERATION_ARG_KEYS") or {}
local sources = {} -- op → { {label, keys} }
for _, op in ipairs(V.OPERATIONS) do
  sources[op] = { { "AI_CORE_OPERATION_ARG_KEYS." .. op .. " (protocol.ts)", sorted(argKeysTs[op] or {}) } }
end
local raiseKeysTs = sorted(strings(anyLiteral(protocolTs, "RAISE_EVENT_KEYS")))
table.insert(sources.raise_event, { "RAISE_EVENT_KEYS (protocol.ts validateRaiseEventArgs)", raiseKeysTs })
local deliverFn = deliverTs:match("export function deliverResultArgs.-\n}") or ""
local deliverKeys = objectKeys(deliverFn:match("return (%b{});"))
table.insert(sources.deliver_result, { "deliverResultArgs() (rpc/deliver.ts)", deliverKeys })
local raiseFn = deliverTs:match("export function raiseEventArgs.-\n}") or ""
local raiseKeys = objectKeys(raiseFn:match("verdict%.ok %? (%b{})"))
table.insert(sources.raise_event, { "raiseEventArgs() (rpc/deliver.ts)", raiseKeys })
local svcFn = actionsTs:match("async function raiseEvent.-\n}") or ""
local svcArgs = svcFn:match("validateRaiseEventArgs%((%b{})%)")
if svcArgs then
  table.insert(sources.raise_event, { "actions/service.ts raiseEvent()", objectKeys(svcArgs) })
end
check(
  "the platform's key lists are readable",
  #(argKeysTs.deliver_result or {}) > 0 and #raiseKeysTs > 0 and #deliverKeys > 0 and #raiseKeys > 0
)
for _, op in ipairs(V.OPERATIONS) do
  local platformKeys = {}
  for _, src in ipairs(sources[op]) do
    local refused = {}
    for _, k in ipairs(src[2]) do
      platformKeys[k] = true
      if not driverTakes(op, k) then
        refused[#refused + 1] = k
      end
    end
    check(
      op .. ": the driver accepts every key of " .. src[1],
      #refused == 0,
      "refused by operations.lua: {"
        .. table.concat(refused, ",")
        .. "} — every such "
        .. op
        .. " ends Failed on the controller"
    )
  end
  local extra = minus(Operations.argKeys(op), keys(platformKeys))
  if #extra > 0 then
    note(op .. ": the driver also accepts {" .. table.concat(extra, ",") .. "}, which no platform source sends")
  end
end
check(
  "deliver_result kinds: AI_CORE_RESULT_KINDS = operations.lua RESULT_KINDS",
  same(keys(Operations.RESULT_KINDS), sorted(strings(literal(protocolTs, "AI_CORE_RESULT_KINDS"))))
)
local detailMaxTs = tonumber(protocolTs:match("RAISE_EVENT_DETAIL_MAX = (%d+)"))
check(
  "raise_event detail: what the platform sends (RAISE_EVENT_DETAIL_MAX) fits what the driver keeps",
  detailMaxTs ~= nil and detailMaxTs <= V.LIMITS.event_detail,
  tostring(detailMaxTs) .. " vs " .. V.LIMITS.event_detail
)
local countMaxTs = tonumber(protocolTs:match("RAISE_EVENT_COUNT_MAX = (%d+)"))
check(
  "counts: RAISE_EVENT_COUNT_MAX is accepted by the driver, one more is not",
  countMaxTs ~= nil
    and Operations.parse("raise_event", { event = "pattern_detected", pending_approvals = countMaxTs }) ~= nil
    and Operations.parse("raise_event", { event = "pattern_detected", pending_approvals = countMaxTs + 1 }) == nil
)
local corrMaxTs = tonumber(protocolTs:match("RAISE_EVENT_CORRELATION_MAX = (%d+)"))
if corrMaxTs == nil then
  note("protocol.ts has no RAISE_EVENT_CORRELATION_MAX: the platform does not bound raise_event correlation_id")
else
  check(
    "raise_event correlation_id: RAISE_EVENT_CORRELATION_MAX fits the driver's bound",
    corrMaxTs <= Operations.CORRELATION_MAX,
    corrMaxTs .. " vs " .. Operations.CORRELATION_MAX
  )
end
local textBytesTs = tonumber(protocolTs:match("DELIVER_RESULT_TEXT_BYTES = (%d+)"))
check(
  "deliver_result text: DELIVER_RESULT_TEXT_BYTES fits the driver's result_text",
  textBytesTs ~= nil and textBytesTs <= V.LIMITS.result_text
)

print("[8] cloud ops: every body the driver sends against rpc/ops.ts OP_BODIES")
-- Asserted, per op the driver sends: every body key is one OP_BODIES (with
-- COMMON) lists — validateOpBody refuses the whole request for one unknown
-- key — every field the platform requires is in the driver's minimal body,
-- enum vocabularies are equal, and the driver's text bounds fit the
-- platform's. And per answer shape: an op the platform answers
-- {accepted: true, job_id: null} is read by the driver as COMPLETED (no
-- pending job), a job op as ACCEPTED (a job waits for deliver_result).
local driverSrc = assert(read("drivers/smartbuildos-ai-core/driver.lua"))
local limitsTs = record(protocolTs, "AI_CORE_DRIVER_LIMITS") or {}
for k, v in tostring(literal(protocolTs, "AI_CORE_DRIVER_LIMITS")):gmatch("([%w_]+): (%d+)") do
  limitsTs[k] = tonumber(v)
end
local function platformFields(lit)
  local out = {}
  for _, f in ipairs(entries(lit)) do
    local max = f.body:match("max:%s*([%w_%.]+)")
    if max and max:match("^L%.") then
      max = limitsTs[max:sub(3)]
    else
      max = tonumber(max)
    end
    out[f.name] = {
      kind = f.body:match('kind:%s*"(%w+)"'),
      required = f.body:find("required:%s*true") ~= nil,
      max = max,
      list = f.body:match("list:%s*([%w_]+)"),
    }
  end
  return out
end
local common = platformFields(anyLiteral(opsTs, "COMMON"))
local bodies = {}
for _, e in ipairs(entries(anyLiteral(opsTs, "OP_BODIES"))) do
  local spec = platformFields(e.body)
  for k, v in pairs(common) do
    spec[k] = v
  end
  bodies[e.name] = spec
end
check(
  "OP_BODIES and COMMON are readable",
  bodies.ask ~= nil and common.request_id ~= nil and bodies.ask.question ~= nil
)
local handled = set(strings(literal(opsTs, "AI_CORE_JOB_OPS")))
for name in opsTs:gmatch("handlers%.([%w_]+) = async") do
  handled[name] = true
end
local routeTs = read(ROOT .. "/src/app/api/integrations/control4/modules/rpc/route.ts") or ""
if routeTs:find("status: statusHandler", 1, true) then
  handled.status = true
end

-- The driver's bodies: the Composer commands (built by commands.lua), the
-- extra start_diagnostic fields and the two actions (read from driver.lua).
local ctx = {
  rooms = function()
    return { [3] = "Kitchen" }
  end,
  devices = function()
    return { [12] = { name = "Pendants", room_id = 3, room_name = "Kitchen" } }
  end,
  learningActive = true,
}
local FULL = {
  QUESTION = "q",
  ROOM = "3",
  NAME = "n",
  DETAIL = "d",
  CATEGORY = "general",
  KEY = "vacation",
  VALUE = "v",
  STATEMENT = "s",
  OCCASION = "o",
  TYPE = "usage",
  PERIOD = "today",
  DEVICE = "12",
  TITLE = "t",
  MESSAGE = "m",
  AUDIENCE = "all",
}
local diagExtra = {}
for k in tostring(driverSrc:match("cloud%(cmd, requestId, (%b{})%)")):gmatch("([%a_][%w_]*) =") do
  diagExtra[k] = true
end
check("driver.lua's start_diagnostic extra fields are readable", next(diagExtra) ~= nil)
local function driverBody(name, minimal)
  local spec = Commands.SPECS[name]
  local params = {}
  for key, p in pairs(spec.params) do
    if not minimal or p.required then
      params[key] = FULL[key]
    end
  end
  if spec.one_of then
    params.ROOM = nil -- exactly one: the device
    params.DEVICE = FULL.DEVICE
  end
  local cmd = assert(Commands.build(name, params, ctx))
  local extra = nil
  if spec.op == "start_diagnostic" then
    extra = {}
    for k in pairs(diagExtra) do
      extra[k] = k == "local_event_ids" and { "e-1" } or (k == "flight_recorder_available" and true or "e-1")
    end
  end
  return Commands.body(cmd, "aic-1", extra)
end
local driverBodies = {} -- op → { full = body, minimal = body, max = { key → bound } }
for _, name in ipairs(Commands.NAMES) do
  local spec = Commands.SPECS[name]
  if spec.op then
    local bounds = {}
    for key, p in pairs(spec.params) do
      if p.kind == "text" then
        bounds[Commands.BODY_NAMES[key:lower()] or key:lower()] = p.max
      end
    end
    driverBodies[spec.op] = { full = driverBody(name, false), minimal = driverBody(name, true), max = bounds }
  end
end
for _, op in ipairs({ "test_provider", "status" }) do
  local lit = driverSrc:match('cloudRequest%("' .. op .. '", (%b{})')
  local body = {}
  for k in tostring(lit):gmatch("([%a_][%w_]*) =") do
    body[k] = true
  end
  driverBodies[op] = { full = body, minimal = body, max = {} }
end
for _, op in ipairs(keys(V.CLOUD_OPS)) do
  local d = driverBodies[op]
  local spec = bodies[op]
  if d == nil then
    note(op .. ": in the vocabulary, but no driver path sends it")
  elseif not handled[op] then
    note(
      op
        .. ": the driver sends it; the platform registers no handler, so it answers `unsupported`"
        .. " (shown as a refusal on the controller; tested in test_aicore_cloud_answers.lua [2])"
    )
  elseif spec == nil then
    note(
      op
        .. ": the platform validates no body for it (OP_BODIES has no entry); the driver sends {"
        .. table.concat(keys(d.full), ",")
        .. "}"
    )
  else
    local unknown = minus(keys(d.full), keys(spec))
    check(
      op .. ": every body key the driver sends is in OP_BODIES." .. op .. " (+ COMMON)",
      #unknown == 0,
      "unknown to the platform: {" .. table.concat(unknown, ",") .. "} — validateOpBody refuses the whole request"
    )
    local missing = {}
    for field, f in pairs(spec) do
      if f.required and d.minimal[field] == nil then
        missing[#missing + 1] = field
      end
    end
    table.sort(missing)
    check(
      op .. ": every field the platform requires is in the driver's minimal body",
      #missing == 0,
      "missing: {" .. table.concat(missing, ",") .. "}"
    )
    for field, f in pairs(spec) do
      if f.kind == "enum" and d.full[field] ~= nil and f.list then
        local tsList = sorted(strings(literal(protocolTs, f.list)))
        local driverList = {}
        for _, name in ipairs(Commands.NAMES) do
          local sp = Commands.SPECS[name]
          if sp.op == op then
            for key, p in pairs(sp.params) do
              if p.kind == "enum" and (Commands.BODY_NAMES[p.as or key:lower()] or p.as or key:lower()) == field then
                driverList = keys(p.list)
              end
            end
          end
        end
        check(
          op .. "." .. field .. ": the same closed list (" .. f.list .. ")",
          same(driverList, tsList),
          show(driverList, tsList)
        )
      elseif f.kind == "text" and d.full[field] ~= nil and field ~= "command" then
        local bound = d.max[field]
        if bound == nil then
          note(
            op
              .. "."
              .. field
              .. ": the driver sends a name Director supplies, not bounded by the driver; the platform refuses over "
              .. tostring(f.max)
              .. " characters"
          )
        else
          check(
            op .. "." .. field .. ": the driver's bound " .. bound .. " fits the platform's " .. tostring(f.max),
            f.max ~= nil and bound <= f.max
          )
        end
      end
    end
  end
end
-- Answer shapes.
local syncNull = {}
for name, block in opsTs:gmatch("handlers%.([%w_]+) = async(.-)\n%s+};") do
  if block:find("job_id: null", 1, true) then
    syncNull[#syncNull + 1] = name
  end
end
table.sort(syncNull)
check("ops.ts has synchronous answers ({..., job_id: null}) to compare", #syncNull > 0)
for _, op in ipairs(syncNull) do
  local r = Commands.interpret({ status = "ok", result = require("JSON"):decode('{"accepted":true,"job_id":null}') })
  check(
    op .. ": {accepted: true, job_id: null} → the driver reads it as completed (no pending job)",
    r.outcome == "completed",
    r.outcome
  )
end
local jobFn = opsTs:match("function jobOp.-\n}") or ""
check(
  "job ops answer {accepted: true, job_id} → the driver tracks the job",
  jobFn:find("accepted: true, job_id: jobId", 1, true) ~= nil
    and Commands.interpret({ status = "ok", result = { accepted = true, job_id = "uuid-1" } }).outcome == "accepted"
)

print("[9] reported differences (NOTE lines are not failures)")
local detailMax = tonumber(protocolTs:match("RAISE_EVENT_DETAIL_MAX = (%d+)"))
if detailMax ~= V.LIMITS.event_detail then
  note(
    "raise_event detail bound: platform RAISE_EVENT_DETAIL_MAX "
      .. tostring(detailMax)
      .. " vs driver "
      .. V.LIMITS.event_detail
      .. " (AI_CORE_DRIVER_LIMITS.eventDetail says "
      .. tostring(protocolTs:match("eventDetail: (%d+)"))
      .. ")"
  )
end
local typesTs = strings(literal(protocolTs, "AI_CORE_EVENT_TYPES"))
-- What the driver emits besides ai_core.observation.* (AI_CORE_OBSERVATION_PREFIX).
local emittedList = { "ai_core.command", "ai_core.record", "ai_core.status", "ai_core.diagnostic", "ai_core.event" }
local emitted = set(emittedList)
for _, t in ipairs(typesTs) do
  if not emitted[t] then
    note(
      "AI_CORE_EVENT_TYPES lists "
        .. t
        .. ", which the driver never emits (DRIVER.md §15: the context travels in the ai_core.command of AI_SET_CONTEXT)"
    )
  end
end
local listedTs = set(typesTs)
for _, t in ipairs(emittedList) do
  if not listedTs[t] then
    note("the driver emits " .. t .. ", which AI_CORE_EVENT_TYPES (protocol.ts) does not list")
  end
end
local featuresTs = sorted(strings(literal(protocolTs, "AI_CORE_FEATURES")))
if not same(keys(V.FEATURES), featuresTs) then
  note(
    "features: driver {"
      .. table.concat(keys(V.FEATURES), ",")
      .. "} vs platform {"
      .. table.concat(featuresTs, ",")
      .. "}"
  )
end
print(string.format("  (%d difference(s) reported)", notes))

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
