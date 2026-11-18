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
-- Reported, not asserted ([7]): mirrors that differ today; each NOTE line
-- names both sides.

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

print("[7] reported differences (NOTE lines are not failures)")
local notes = 0
local function note(text)
  notes = notes + 1
  print("  NOTE " .. text)
end
-- raise_event arguments: the platform's validator vs the driver's parser.
local Operations = require("aicore.operations")
local validator = protocolTs:match("function validateRaiseEventArgs.-\n}")
local tsRaiseKeys = sorted(strings(tostring(validator):match("%!%[(.-)%]%.includes")))
local argKeys = record(protocolTs, "AI_CORE_OPERATION_ARG_KEYS") or {}
local driverRaise = {}
for _, k in ipairs({ "event", "detail", "pending_approvals", "recommendation_count", "correlation_id" }) do
  local args = { event = "pattern_detected" }
  if k ~= "event" then
    args[k] = k == "detail" and "x" or (k == "correlation_id" and "c-1" or 1)
  end
  if Operations.parse("raise_event", args) ~= nil then
    driverRaise[#driverRaise + 1] = k
  end
end
table.sort(driverRaise)
if not same(driverRaise, tsRaiseKeys) then
  note(
    "raise_event keys: driver accepts {"
      .. table.concat(driverRaise, ",")
      .. "}; protocol.ts validateRaiseEventArgs accepts {"
      .. table.concat(tsRaiseKeys, ",")
      .. "} — a correlation_id the platform validates is refused whole by the driver; pending_approvals / recommendation_count the driver reads are refused by the validator"
  )
end
if not same(driverRaise, sorted(argKeys.raise_event)) then
  note(
    "AI_CORE_OPERATION_ARG_KEYS.raise_event {"
      .. table.concat(sorted(argKeys.raise_event), ",")
      .. "} vs driver {"
      .. table.concat(driverRaise, ",")
      .. "}"
  )
end
local actionsTs = read(ROOT .. "/src/lib/ai-core/actions/service.ts") or ""
if actionsTs:find("correlation_id: row.id", 1, true) and not set(driverRaise).correlation_id then
  note(
    "BREAK: src/lib/ai-core/actions/service.ts raiseEvent() sends raise_event args WITH correlation_id;"
      .. " operations.lua refuses the whole operation, so approval_required / action_completed /"
      .. " action_failed queued by the actions service end Failed on the controller"
  )
end
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
local emitted = set({ "ai_core.command", "ai_core.record", "ai_core.status", "ai_core.diagnostic" })
for _, t in ipairs(typesTs) do
  if not emitted[t] then
    note(
      "AI_CORE_EVENT_TYPES lists "
        .. t
        .. ", which the driver never emits (DRIVER.md §15: the context travels in the ai_core.command of AI_SET_CONTEXT)"
    )
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
