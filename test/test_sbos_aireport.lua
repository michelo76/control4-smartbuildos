-- sbos.aireport: the AI Core reporting helper and the "AI Core" property.
--
-- The Agent side is the REAL registry (identity binding included) and the
-- REAL bus behind a fake SendToDevice; AI Core is a fake provider that
-- registers on that bus and answers `ai_core.report` (its own side is brief
-- D4). Covered:
--   [1] the closed driver tables: MODULE_IDS = RESERVED_MODULES, every file
--       is a directory in drivers/, every directory is a root, a child or
--       exempt
--   [2] the closed property value list (and nothing else is ever painted)
--   [3] (passive mode moved to sbos.aipresence: test/test_sbos_aipresence.lua)
--   [4] start with no Agent; [5] start with a v1-only Agent
--   [6] start with AI Core absent: zero requests (SendToDevice counted)
--   [7] re-discovery on DIRECTORY_CHANGED: added, report answers, removed,
--       updated, stale, unverified, a silent AI Core, a pre-D1 Agent
--   [8] kind, size and rate bounds
--   [9] declared queries and actions: params, declaration_hash, verified
--  [10] attach mode; [11] registry full; [12] Agent restart; [13] stop
--
-- Run from the driver root: make test

C4 = C4 or {}
require("c4_shim")
require("drivers-common-public.global.lib")
JSON = require("JSON")

local pass, fail = 0, 0
local function check(name, ok, detail)
  if ok then
    pass = pass + 1
    print("  ok   " .. name)
  else
    fail = fail + 1
    print("  FAIL " .. name .. (detail ~= nil and ("  -> " .. tostring(detail)) or ""))
  end
end

-- ── Director / library fakes ─────────────────────────────────────────────────
ONE_SECOND = 1000
ONE_MINUTE = 60000
local timers = {}
function SetTimer(id, ms, fn, repeating)
  timers[id] = { ms = ms, fn = fn, repeating = repeating }
end
function CancelTimer(id)
  timers[id] = nil
end
local function fire(id)
  local t = timers[id]
  if t == nil then
    return false
  end
  if not t.repeating then
    timers[id] = nil
  end
  t.fn()
  return true
end
local function timerLike(prefix)
  for id in pairs(timers) do
    if id:sub(1, #prefix) == prefix then
      return id
    end
  end
  return nil
end
EC = EC or {}
OSE = OSE or {}

local AGENT, SELF, AICORE = 99, 601, 700
local agentPresent = true
package.preload["sbos.license"] = function()
  return {
    agentDeviceId = function()
      return agentPresent and AGENT or nil
    end,
    statusLabel = function()
      return "Licensed"
    end,
  }
end
local persisted = {}
package.preload["lib.persist"] = function()
  return {
    get = function(_, k, d)
      if persisted[k] == nil then
        return d
      end
      return persisted[k]
    end,
    set = function(_, k, v)
      persisted[k] = v
    end,
  }
end
function C4:GetDeviceID()
  return SELF
end
local config = { name = "SmartBuildOS Atmosphere", version = "20261118.120000" }
function C4:GetDriverConfigInfo(k)
  return config[k]
end
-- Director's devices by file (the Agent's identity resolver and the
-- passive lookup both read it).
local c4i = {}
local resolverOff = false
function C4:GetDevicesByC4iName(file)
  return c4i[file]
end
local systemEvents = {}
function C4:RegisterSystemEvent(id)
  systemEvents[#systemEvents + 1] = id
end
Properties = Properties or {}
local painted = {}
local everPainted = {} -- every value written to "AI Core" in the whole run
function UpdateProperty(name, value)
  painted[#painted + 1] = { name = name, value = value }
  if name == "AI Core" then
    everPainted[#everPainted + 1] = value
  end
  Properties[name] = value
end

local Policy = require("sbos.modulepolicy")
local Modules = require("sbos.modules")
local ModuleBus = require("sbos.modulebus")
local client = require("sbos.moduleclient")
local aireport = require("sbos.aireport")
local aipresence = require("sbos.aipresence")

-- ── the Agent (real registry + bus) and a fake AI Core on it ────────────────
local agent = {}
local frames = {} -- every SendToDevice this driver made
local busTimers = {}
local ai = {}

local function aiReset()
  ai = {
    entry = nil,
    state = "ready",
    accepted = true,
    reason = nil,
    version = "20261118.2",
    silent = false,
    received = {}, -- requests that reached AI Core
    responses = {}, -- answers to AI Core's own requests
  }
end
aiReset()

local function aiReceive(command, params)
  if command == "SBOS_MODULE_REQUEST" then
    local okA, args = pcall(function()
      return JSON:decode(params.args)
    end)
    ai.received[#ai.received + 1] = {
      capability = params.capability,
      args = okA and args or nil,
      from = params.from_module_id,
      from_instance = params.from_instance_id,
    }
    if ai.silent then
      return
    end
    local result = { accepted = ai.accepted, ai_core = { state = ai.state, version = ai.version } }
    if ai.reason ~= nil then
      result.reason = ai.reason
    end
    if ai.needDescribe ~= nil and okA and type(args) == "table" then
      -- The real AI Core says need_describe while it holds no describe.
      result.need_describe = ai.needDescribe(args)
    end
    agent.bus:response(ai.entry, {
      request_id = params.request_id,
      status = "ok",
      error_code = "ok",
      result = JSON:encode(result),
      cursor = "",
    })
  elseif command == "SBOS_MODULE_RESPONSE" then
    ai.responses[#ai.responses + 1] = params
  end
end

local function newAgent(max, policy)
  agent.max = max
  busTimers = {}
  agent.registry = Modules.Registry.new({
    now = os.time,
    newToken = function()
      agent.n = (agent.n or 0) + 1
      return string.format("tok%029d", agent.n)
    end,
    devicesForFile = function(file)
      if resolverOff then
        return nil
      end
      return c4i[file] or {}
    end,
  })
  agent.bus = ModuleBus.new({
    registry = agent.registry,
    now = os.time,
    send = function(id, command, params)
      if tostring(id) == tostring(AICORE) then
        aiReceive(command, params)
      elseif tostring(id) == tostring(SELF) then
        local h = EC[command]
        if h then
          h(params)
        end
      end
      return true
    end,
    cloudPost = function() end,
    setTimer = function(id, _, fn)
      busTimers[id] = fn
    end,
    cancelTimer = function(id)
      busTimers[id] = nil
    end,
    agent = function()
      return { paired = true, connected = true }
    end,
    policy = policy,
  })
  -- The Agent's own token buckets are covered by test_sbos_modulebus; this
  -- file runs minutes of traffic inside one wall-clock second, so they are
  -- open here (the helper's own client-side rates are what is under test).
  agent.bus.allow = function()
    return true
  end
end

--- Fires the Agent's debounced DIRECTORY_CHANGED push.
local function pushDirectory()
  local fn = busTimers[ModuleBus.DIRECTORY_TIMER]
  busTimers[ModuleBus.DIRECTORY_TIMER] = nil
  if fn then
    fn()
  end
  return fn ~= nil
end

local AI_CAPS = { { id = "ai_core.report", version = 1, kind = "request" } }
local function aiRegister(over)
  over = over or {}
  c4i["smartbuildos-ai-core.c4z"] = { [AICORE] = {} }
  local ok, reply, entry = agent.registry:register({
    module_id = "ai_core",
    instance_id = tostring(AICORE),
    requester = tostring(AICORE),
    driver_version = over.version or ai.version,
    protocol_min = "1",
    protocol_max = "2",
    singleton = "true",
    status = over.status or "ready",
    manifest = JSON:encode({
      driver = "sbos.ai_core",
      version = over.version or ai.version,
      protocol = 2,
      capabilities = over.caps or AI_CAPS,
    }),
  })
  if ok then
    ai.entry = entry
    agent.bus:onRegistered(entry)
  end
  return ok, reply
end
local function aiRemove()
  local entry = ai.entry
  agent.registry:remove("ai_core", tostring(AICORE))
  agent.bus:onRemoved(entry)
end

--- AI Core asks this driver (through the real bus routing and policy).
local nreq = 0
local function aiAsk(capability, args, to)
  nreq = nreq + 1
  local before = #ai.responses
  agent.bus:request(ai.entry, {
    module_id = "ai_core",
    instance_id = tostring(AICORE),
    token = ai.entry.token,
    request_id = "q" .. nreq,
    idempotency_key = "k" .. nreq,
    to = to or "atmosphere",
    capability = capability,
    args = JSON:encode(args),
    deadline = tostring(os.time() + 30),
  })
  local r = ai.responses[before + 1]
  if r == nil then
    return nil
  end
  local okR, result = pcall(function()
    return JSON:decode(r.result)
  end)
  return { status = r.status, error_code = r.error_code, result = okR and result or nil }
end

local METHODS = {
  SBOS_MODULE_DISCOVER = "discover",
  SBOS_MODULE_REQUEST = "request",
  SBOS_MODULE_RESPONSE = "response",
  SBOS_MODULE_SUBSCRIBE = "subscribe",
}
function C4:SendToDevice(id, command, params)
  local copy = {}
  for k, v in pairs(params or {}) do
    copy[k] = v
  end
  frames[#frames + 1] = { id = id, command = command, params = copy }
  if id ~= AGENT or agent.registry == nil then
    return
  end
  if command == "SBOS_MODULE_REGISTER" then
    local saved = Modules.PROTOCOL_MAX
    Modules.PROTOCOL_MAX = agent.max
    local ok, reply, entry = agent.registry:register(params)
    Modules.PROTOCOL_MAX = saved
    reply.agent_protocol_min = "1"
    reply.agent_protocol_max = tostring(agent.max)
    reply.paired = "true"
    reply.connected = "true"
    if ok and agent.max >= 2 then
      agent.bus:onRegistered(entry)
    end
    agent.lastReply = reply
    EC.SBOS_MODULE_REGISTERED(reply)
  elseif command == "SBOS_MODULE_STATUS" then
    local entry = agent.registry:authenticate(params)
    if entry then
      agent.registry:touch(entry, params)
    end
  elseif command == "SBOS_MODULE_UNREGISTER" then
    local entry = agent.registry:authenticate(params)
    if entry then
      agent.registry:remove(entry.module_id, entry.instance_id)
      agent.bus:onRemoved(entry)
    end
  elseif METHODS[command] and agent.max >= 2 then
    local entry = agent.registry:authenticate(params)
    if entry then
      agent.bus[METHODS[command]](agent.bus, entry, params)
    end
  end
end

local function count(command)
  local n = 0
  for _, f in ipairs(frames) do
    if f.command == command then
      n = n + 1
    end
  end
  return n
end
local function last(command)
  for i = #frames, 1, -1 do
    if frames[i].command == command then
      return frames[i]
    end
  end
  return nil
end
local function reportsOfKind(kind)
  local out = {}
  for _, r in ipairs(ai.received) do
    if r.capability == "ai_core.report" and r.args and r.args.kind == kind then
      out[#out + 1] = r
    end
  end
  return out
end

local V = aireport.V
local function fresh()
  aireport._reset()
  aireport._clock = nil
  frames = {}
  timers = {}
  painted = {}
  aiReset()
  resolverOff = false
  agentPresent = true
  c4i = { ["smartbuildos-atmosphere.c4z"] = { [SELF] = {} } }
  Properties["AI Core"] = "Searching…"
  Properties["Driver Status"] = "Running"
  DC_FILENAME = "smartbuildos-atmosphere.c4z"
end
local function value()
  return Properties["AI Core"]
end

-- ── [1] closed driver tables ────────────────────────────────────────────────
print("[1] closed driver tables: MODULE_IDS = RESERVED_MODULES, files = drivers/")
do
  local dirs = {}
  local pipe = assert(io.popen("ls -d drivers/*/ 2>/dev/null"))
  for line in pipe:lines() do
    local name = line:match("^drivers/([^/]+)/?$")
    if name then
      dirs[name] = true
    end
  end
  pipe:close()
  local function isDir(file)
    local stem = type(file) == "string" and file:match("^(.+)%.c4z$")
    return stem ~= nil and dirs[stem] == true
  end
  local nDirs = 0
  for _ in pairs(dirs) do
    nDirs = nDirs + 1
  end
  check("found the driver directories", nDirs >= 52, nDirs)

  local drift = {}
  for file, id in pairs(aireport.MODULE_IDS) do
    local bound = Policy.RESERVED_MODULES[id]
    if type(bound) ~= "table" or #bound ~= 1 or bound[1] ~= file then
      drift[#drift + 1] = id .. " <- " .. file
    end
  end
  for id, files in pairs(Policy.RESERVED_MODULES) do
    for _, file in ipairs(files) do
      if aireport.MODULE_IDS[file] ~= id then
        drift[#drift + 1] = "reserved " .. id .. " (" .. file .. ") not in MODULE_IDS"
      end
    end
  end
  check("MODULE_IDS and RESERVED_MODULES name the same ids and files", #drift == 0, table.concat(drift, "; "))

  local missing, ids = {}, {}
  for file, id in pairs(aireport.MODULE_IDS) do
    if not isDir(file) then
      missing[#missing + 1] = file
    end
    if ids[id] then
      missing[#missing + 1] = "duplicate id " .. id
    end
    ids[id] = true
    if not Modules.validModuleId(id) then
      missing[#missing + 1] = "invalid id " .. id
    end
  end
  for id, files in pairs(Policy.RESERVED_MODULES) do
    for _, file in ipairs(files) do
      if not isDir(file) then
        missing[#missing + 1] = id .. " -> " .. file
      end
    end
  end
  check("every MODULE_IDS / RESERVED_MODULES file is a directory in drivers/", #missing == 0, table.concat(missing, "; "))

  local unknown = {}
  for file, root in pairs(aipresence.CHILDREN) do
    if not isDir(file) then
      unknown[#unknown + 1] = file
    end
    if aireport.MODULE_IDS[root] == nil and aireport.EXEMPT[root] == nil then
      unknown[#unknown + 1] = file .. " -> " .. root
    end
    if aireport.LABELS[root] == nil then
      unknown[#unknown + 1] = "no label for " .. root
    end
  end
  check("every child is a directory and its root a root (or the Agent)", #unknown == 0, table.concat(unknown, "; "))

  local unclassified = {}
  local nRoots, nChildren = 0, 0
  for name in pairs(dirs) do
    local file = name .. ".c4z"
    local n = (aireport.MODULE_IDS[file] and 1 or 0)
      + (aipresence.CHILDREN[file] and 1 or 0)
      + (aireport.EXEMPT[file] and 1 or 0)
    if n ~= 1 then
      unclassified[#unclassified + 1] = file .. " x" .. n
    end
    nRoots = nRoots + (aireport.MODULE_IDS[file] and 1 or 0)
    nChildren = nChildren + (aipresence.CHILDREN[file] and 1 or 0)
  end
  check("every driver directory is exactly one of root / child / exempt", #unclassified == 0, table.concat(unclassified, "; "))
  check("21 roots + 30 children + the Agent", nRoots == 21 and nChildren == 30, nRoots .. "/" .. nChildren)
  check("exempt is the Agent alone", aireport.EXEMPT["smartbuildos.c4z"] ~= nil and next(aireport.EXEMPT, "smartbuildos.c4z") == nil)

  local gaps = {}
  for file in pairs(aireport.MODULE_IDS) do
    if aireport.LABELS[file] == nil or aireport.SUMMARIES[file] == nil then
      gaps[#gaps + 1] = file
    end
  end
  for file in pairs(aireport.SUMMARIES) do
    if aireport.MODULE_IDS[file] == nil then
      gaps[#gaps + 1] = "summary for non-root " .. file
    end
  end
  check("every root has a label and a summary (and only roots have summaries)", #gaps == 0, table.concat(gaps, "; "))

  -- The default `file` is DC_FILENAME: where a driver sets it, it must name
  -- its own directory.
  local wrong = {}
  for name in pairs(dirs) do
    local f = io.open("drivers/" .. name .. "/driver.lua", "r")
    if f then
      local src = f:read("*a")
      f:close()
      local dc = src:match('\nDC_FILENAME%s*=%s*"([^"]+)"')
      if dc ~= nil and dc ~= name .. ".c4z" then
        wrong[#wrong + 1] = name .. " says " .. dc
      end
    end
  end
  check("DC_FILENAME, where set, names the driver's own directory", #wrong == 0, table.concat(wrong, "; "))
  -- The OSS build has no DC_FILENAME: the default is DRIVER_FILENAMES[1].
  local wrongOss = {}
  for name in pairs(dirs) do
    local f = io.open("drivers/" .. name .. "/driver.lua", "r")
    if f then
      local src = f:read("*a")
      f:close()
      local first = src:match('\nDRIVER_FILENAMES%s*=%s*{%s*"([^"]+)"')
      if first ~= nil and first ~= name .. ".c4z" then
        wrongOss[#wrongOss + 1] = name .. " says " .. first
      end
    end
  end
  check("DRIVER_FILENAMES[1], where set, names the driver's own directory", #wrongOss == 0, table.concat(wrongOss, "; "))
end

-- ── [2] the closed value list ───────────────────────────────────────────────
print("[2] the closed property value list")
do
  local SPEC = {
    "Searching…",
    "SmartBuildOS Agent not found",
    "SmartBuildOS Agent update required",
    "Not registered — Agent module list full",
    "Not installed",
    "Found — not responding",
    "Found — AI Core update required (v%s)",
    "Found — not licensed (v%s)",
    "Found — SmartBuildOS Agent not paired (v%s)",
    "Found — reporting, cloud offline (v%s)",
    "Found — reporting (v%s)",
    "Installed — reports through %s",
    "Installed — this driver does not report",
    -- the Agent's two (sbos.agentaicore only; this helper never paints them)
    "Found — registered (v%s)",
    "Found — not verified (v%s)",
  }
  local same = #aireport.VALUES == #SPEC
  for i, v in ipairs(SPEC) do
    same = same and aireport.VALUES[i] == v
  end
  check("VALUES is exactly the spec §3.6 list, ruling 20's value and the Agent's two, in order", same)
  check("each plain value is accepted", aireport.isValue("Not installed") and aireport.isValue("Searching…"))
  check(
    "templates accept a bounded version / a known root label",
    aireport.isValue("Found — reporting (v20261118.2)")
      and aireport.isValue("Found — reporting (vunknown)")
      and aireport.isValue("Installed — reports through Bond Bridge Gateway (SBOS)")
  )
  local outside = {
    "Connected",
    "Found — reporting",
    "Found — reporting (v)",
    "Found — reporting (v1 2)",
    "Found — reporting (v" .. string.rep("9", 33) .. ")",
    "Installed — reports through Someone Else",
    "searching…",
    "",
  }
  local leaked = {}
  for _, v in ipairs(outside) do
    if aireport.isValue(v) then
      leaked[#leaked + 1] = v
    end
  end
  check("anything else is refused", #leaked == 0, table.concat(leaked, " | "))
  fresh()
  local before = value()
  local refusedBefore = aireport.counters().values_refused
  aireport._paint("Connected")
  check(
    "paint() refuses a value outside the list: property unchanged, counted",
    value() == before and aireport.counters().values_refused == refusedBefore + 1,
    value()
  )
end

-- ── [4] no Agent ────────────────────────────────────────────────────────────
print("[4] start with no SmartBuildOS Agent")
do
  fresh()
  agentPresent = false
  agent.registry = nil
  local ok = aireport.start({ sku = "SBOS_ATMOSPHERE" })
  check("start returns true", ok)
  check("value: SmartBuildOS Agent not found", value() == V.no_agent, value())
  check("zero SendToDevice", #frames == 0, #frames)
  check("event refused as absent, nothing sent", select(2, aireport.event("weather.change", "x")) == "absent" and #frames == 0)
  check("an unknown file is refused, nothing set up", aireport.start({ file = "nope.c4z" }) == false)
  -- KI-47: an empty summary in the start options is ignored, not sent.
  aireport.start({ sku = "SBOS_ATMOSPHERE", summary = "  " })
  check(
    "start with a blank summary keeps the built-in summary",
    aireport.buildDescribe().summary == aireport.SUMMARIES["smartbuildos-atmosphere.c4z"],
    aireport.buildDescribe().summary
  )
  local saved = aireport.SUMMARIES["smartbuildos-atmosphere.c4z"]
  aireport.SUMMARIES["smartbuildos-atmosphere.c4z"] = nil
  local fallback = aireport.buildDescribe().summary
  aireport.SUMMARIES["smartbuildos-atmosphere.c4z"] = saved
  check(
    "a file without a built-in summary falls back to its label (never empty)",
    fallback == aireport.LABELS["smartbuildos-atmosphere.c4z"],
    fallback
  )
end

-- ── [5] v1-only Agent ───────────────────────────────────────────────────────
print("[5] start with a v1-only Agent")
do
  fresh()
  newAgent(1)
  aireport.start({ sku = "SBOS_ATMOSPHERE" })
  local reg = last("SBOS_MODULE_REGISTER")
  check("registration offered protocol 2..2", reg and reg.params.protocol_min == "2" and reg.params.protocol_max == "2")
  check(
    "refused incompatible_protocol: nothing stored in the v1 registry",
    agent.lastReply.reason == "incompatible_protocol" and #agent.registry:list() == 0
  )
  check("value: SmartBuildOS Agent update required", value() == V.agent_update, value())
  check(
    "only the REGISTER frame was sent (no discover, no report)",
    #frames == 1 and frames[1].command == "SBOS_MODULE_REGISTER",
    #frames
  )
  check("reports refused as absent", aireport.state({ temp = 20 }) == false and aireport.diagnostic("info", "x", "y") == false)
  check("the client retries registration slowly (300 s)", timers.SbosModuleRegister and timers.SbosModuleRegister.ms == 300000)
  check("still only one frame", #frames == 1)
end

-- ── [6] AI Core absent ──────────────────────────────────────────────────────
print("[6] start, v2 Agent, AI Core absent: silent")
do
  fresh()
  newAgent(2)
  local mine = function() end
  EC.SBOS_DRIVER_CONFIG = mine
  aireport.start({ sku = "SBOS_ATMOSPHERE" })
  check("registered at v2", client.isRegistered() and client.protocol() == 2)
  check("verified by the Agent (reserved id bound to its file)", agent.registry:find("atmosphere", tostring(SELF)).verified == true)
  local reg = last("SBOS_MODULE_REGISTER")
  local manifest = JSON:decode(reg.params.manifest)
  check("module id from MODULE_IDS, singleton false", reg.params.module_id == "atmosphere" and reg.params.singleton == "false")
  check("manifest driver sbos.atmosphere, no capabilities without declarations", manifest.driver == "sbos.atmosphere" and #manifest.capabilities == 0)
  check("EC.SBOS_DRIVER_CONFIG left to the driver (claim_driver_config = false)", EC.SBOS_DRIVER_CONFIG == mine)
  check("debug printing suppressed for module frames", EC.suppressDebug and EC.suppressDebug.SBOS_MODULE_REQUEST == true)
  check("discover sent for ai_core", count("SBOS_MODULE_DISCOVER") == 1 and last("SBOS_MODULE_DISCOVER").params.filter:find("ai_core") ~= nil)
  check("value: Not installed", value() == V.not_installed, value())
  local results = {
    { aireport.state({ temp = 20 }) },
    { aireport.event("weather.change", "rain") },
    { aireport.diagnostic("warning", "feed.stale", "no data") },
    { aireport.describe({ summary = "Weather" }) },
  }
  check(
    "state / event / diagnostic answer absent; describe stores only",
    results[1][2] == "absent" and results[2][2] == "absent" and results[3][2] == "absent" and results[4][1] == true
  )
  check("ZERO SBOS_MODULE_REQUEST frames while ai_core is absent", count("SBOS_MODULE_REQUEST") == 0, count("SBOS_MODULE_REQUEST"))
  local others = 0
  for _, f in ipairs(frames) do
    if f.id ~= AGENT then
      others = others + 1
    end
  end
  check("no frame to any device but the Agent", others == 0)
  check("no polling: no aireport timer armed", timerLike("SbosAiReport") == nil, timerLike("SbosAiReport"))
  -- a directory push about some other module re-discovers and stays silent
  local ok = agent.registry:register({
    module_id = "probex",
    instance_id = "650",
    protocol_min = "1",
    protocol_max = "2",
    singleton = "true",
  })
  check("(another module registered)", ok ~= nil)
  agent.bus:onRegistered(agent.registry:find("probex", "650"))
  pushDirectory()
  check("DIRECTORY_CHANGED -> re-discovered", count("SBOS_MODULE_DISCOVER") == 2)
  check("still Not installed, still zero requests", value() == V.not_installed and count("SBOS_MODULE_REQUEST") == 0)
end

-- ── [7] re-discovery ────────────────────────────────────────────────────────
print("[7] DIRECTORY_CHANGED: added, answers, removed, updated, stale, unverified")
do
  fresh()
  newAgent(2)
  aireport.start({ sku = "SBOS_ATMOSPHERE", summary = "Weather for the home." })
  aireport.state({ temperature_f = 71, condition = "Clear" })
  check("(absent first)", value() == V.not_installed and count("SBOS_MODULE_REQUEST") == 0)

  aiRegister()
  check("value does not move before the push", value() == V.not_installed)
  pushDirectory()
  local describes, states = reportsOfKind("describe"), reportsOfKind("state")
  check("added: describe sent", #describes == 1)
  check("added: current state sent", #states == 1)
  local d = describes[1] and describes[1].args or {}
  check(
    "describe shape",
    d.v == 1
      and d.kind == "describe"
      and d.driver.name == "SmartBuildOS Atmosphere"
      and d.driver.version == "20261118.120000"
      and d.driver.sku == "SBOS_ATMOSPHERE"
      and d.driver.file == "smartbuildos-atmosphere.c4z"
      and d.summary == "Weather for the home."
      and type(d.controls) == "table"
      and type(d.queries) == "table"
      and type(d.hash) == "string"
      and #d.hash == 16
  )
  local unhashed = {}
  for k, v in pairs(d) do
    if k ~= "hash" then
      unhashed[k] = v
    end
  end
  check("describe hash is the hash of the describe without it", d.hash == aireport.hash(unhashed))
  local s = states[1] and states[1].args or {}
  check(
    "state carries the driver's facts and the baseline",
    s.v == 1
      and s.facts.temperature_f == 71
      and s.facts.condition == "Clear"
      and s.facts.driver_status == "Running"
      and s.facts.license == "Licensed"
  )
  check("the Agent stamped the sender", describes[1].from == "atmosphere" and describes[1].from_instance == tostring(SELF))
  check("value: Found — reporting (v20261118.2)", value() == "Found — reporting (v20261118.2)", value())

  ai.state = "cloud_unreachable"
  aireport.state({ temperature_f = 72 })
  check("answer cloud_unreachable -> reporting, cloud offline", value() == "Found — reporting, cloud offline (v20261118.2)", value())
  ai.state = "agent_unpaired"
  aireport.state({ temperature_f = 73 })
  check("answer agent_unpaired -> Agent not paired", value() == "Found — SmartBuildOS Agent not paired (v20261118.2)", value())
  ai.state = "unlicensed"
  aireport.state({ temperature_f = 74 })
  check("answer unlicensed -> not licensed", value() == "Found — not licensed (v20261118.2)", value())
  ai.state = "ready"
  ai.accepted = false
  ai.reason = "rate_limited"
  aireport.state({ temperature_f = 75 })
  check("a refused (rate_limited) answer leaves the value", value() == "Found — not licensed (v20261118.2)", value())
  ai.accepted, ai.reason = true, nil
  aireport._clock = function()
    return os.time() + 120
  end
  aireport.state({ temperature_f = 76 })
  check("accepted again -> reporting", value() == "Found — reporting (v20261118.2)", value())

  -- directory status unlicensed (AI Core's own status frame)
  -- (AI Core rate-limits the state the push triggers, so the directory row
  -- is the only news)
  ai.accepted, ai.reason = false, "rate_limited"
  aiRegister({ status = "unlicensed" })
  pushDirectory()
  check("directory status unlicensed -> not licensed", value() == "Found — not licensed (v20261118.2)", value())
  ai.accepted, ai.reason = true, nil
  aiRegister({ status = "ready" })
  pushDirectory()
  check("status back to ready -> a state is sent and its answer repaints", value() == "Found — reporting (v20261118.2)", value())

  -- updated: an AI Core build without ai_core.report
  local before = #ai.received
  aiRegister({ version = "20261101.1", caps = {} })
  pushDirectory()
  check("updated (no ai_core.report): AI Core update required", value() == "Found — AI Core update required (v20261101.1)", value())
  aireport.event("weather.change", "x")
  aireport.state({ temperature_f = 80 })
  check("…and nothing is sent to it", #ai.received == before, #ai.received - before)
  aiRegister({ version = "20261101.1", caps = { { id = "ai_core.report", version = 0, kind = "request" } } })
  pushDirectory()
  check("a lower capability version is also update-required", value() == "Found — AI Core update required (v20261101.1)", value())

  -- updated: a new AI Core build with the capability
  local d0 = #reportsOfKind("describe")
  aiRegister({ version = "20261120.1" })
  ai.version = "20261120.1"
  pushDirectory()
  check("updated (new build): describe re-sent", #reportsOfKind("describe") == d0 + 1)
  check("…value shows the new version", value() == "Found — reporting (v20261120.1)", value())

  -- unsupported_version answer
  ai.accepted, ai.reason = false, "unsupported_version"
  aireport.state({ temperature_f = 81 })
  check("answer unsupported_version -> AI Core update required", value() == "Found — AI Core update required (v20261120.1)", value())
  local n = #ai.received
  aireport.state({ temperature_f = 82 })
  check("…and the helper stops sending", #ai.received == n)
  ai.accepted, ai.reason = true, nil
  aiRegister({ version = "20261121.1" })
  ai.version = "20261121.1"
  pushDirectory()
  check("an updated AI Core clears it", value() == "Found — reporting (v20261121.1)", value())

  -- stale
  ai.entry.last_seen = os.time() - 16 * 60
  agent.bus:tick()
  pushDirectory()
  check("stale -> Found — not responding", value() == V.not_responding, value())
  n = #ai.received
  aireport.event("weather.change", "y")
  aireport.state({ temperature_f = 83 })
  check("…nothing sent while stale", #ai.received == n)
  agent.registry:touch(ai.entry, {})
  agent.bus:tick()
  local d1 = #reportsOfKind("describe")
  pushDirectory()
  check("live again -> describe re-sent, reporting", #reportsOfKind("describe") == d1 + 1 and value() == "Found — reporting (v20261121.1)", value())

  -- unverified
  resolverOff = true
  aiRegister()
  pushDirectory()
  check("unverified ai_core row seen as unverified", aireport.target().verified == false)
  check("unverified: reports continue (no closed value for it)", value() == "Found — reporting (v20261121.1)", value())
  resolverOff = false
  aiRegister()
  pushDirectory()
  check("verified again", aireport.target().verified == true)

  -- silent AI Core: the report times out
  aireport._clock = function()
    return os.time() + 600
  end
  ai.silent = true
  aireport.state({ temperature_f = 90 })
  local rpcTimer = timerLike("SbosRpc:")
  check("(a report is in flight)", rpcTimer ~= nil)
  fire(rpcTimer)
  check("deadline_exceeded -> Found — not responding", value() == V.not_responding, value())
  ai.silent = false
  aireport._clock = function()
    return os.time() + 900
  end
  aireport.state({ temperature_f = 91 })
  check("an answer clears it", value() == "Found — reporting (v20261121.1)", value())

  -- removed
  aiRemove()
  pushDirectory()
  check("removed -> Not installed", value() == V.not_installed, value())
  n = count("SBOS_MODULE_REQUEST")
  aireport.state({ temperature_f = 92 })
  aireport.event("weather.change", "z")
  aireport.diagnostic("fault", "feed.down", "down")
  check("…zero requests after removal", count("SBOS_MODULE_REQUEST") == n)
  check("…baseline timer stopped", timers.SbosAiReportBaseline == nil)

  -- a pre-D1 v2 Agent: no ai_core.report policy row
  fresh()
  local policy = { REQUEST_POLICY = {} }
  for k, v in pairs(Policy.REQUEST_POLICY) do
    if k ~= "ai_core.report" then
      policy.REQUEST_POLICY[k] = v
    end
  end
  newAgent(2, policy)
  aiRegister()
  aireport.start({ sku = "SBOS_ATMOSPHERE" })
  check("a v2 Agent without the ai_core.report row -> Agent update required", value() == V.agent_update, value())
  local nr = count("SBOS_MODULE_REQUEST")
  aireport.state({ temperature_f = 1 })
  check("…and nothing more is sent", count("SBOS_MODULE_REQUEST") == nr)
end

-- ── [8] bounds ──────────────────────────────────────────────────────────────
print("[8] kind, size and rate bounds")
do
  check("exactly four kinds", (function()
    local n = 0
    for _ in pairs(aireport.KINDS) do
      n = n + 1
    end
    return n == 4 and aireport.KINDS.describe and aireport.KINDS.state and aireport.KINDS.event and aireport.KINDS.diagnostic
  end)())
  fresh()
  newAgent(2)
  aiRegister()
  local t0 = os.time()
  local clock = t0
  aireport._clock = function()
    return clock
  end
  aireport.start({ sku = "SBOS_ATMOSPHERE" })
  check("(reporting)", value() == "Found — reporting (v20261118.2)", value())

  -- state shape
  check("fact key pattern enforced", aireport.state({ ["Bad Key"] = 1 }) == false)
  check("baseline keys are the helper's", aireport.state({ license = "x" }) == false)
  check("a table value is refused", aireport.state({ a = {} }) == false)
  local many = {}
  for i = 1, 31 do
    many["k" .. i] = i
  end
  check("31 driver facts refused (32 with the baseline)", select(2, aireport.state(many)) == "too_many_facts")
  local long = string.rep("é", 100) -- 200 bytes
  local before = #reportsOfKind("state")
  aireport.state({ note = long .. "\226\128\174evil\0x" })
  local st = reportsOfKind("state")[#reportsOfKind("state")]
  local note = st and st.args.facts.note or ""
  check("a string fact is cut to 120 bytes between characters", #note <= 120 and note:sub(-1):byte() ~= 0xC3, #note)
  check("…carrying no bidi or control characters", note:find("\226\128\174") == nil and note:find("%z") == nil)
  check("(that state went out)", #reportsOfKind("state") == before + 1)

  -- state rate: 6 per rolling minute, coalesced, latest wins
  clock = t0 + 600
  local sent0 = #reportsOfKind("state")
  for i = 1, 9 do
    aireport.state({ n = i })
  end
  check("state: at most 6 a minute", #reportsOfKind("state") == sent0 + 6, #reportsOfKind("state") - sent0)
  check("…the rest coalesced behind a timer", timers.SbosAiReportState ~= nil)
  clock = t0 + 661
  fire("SbosAiReportState")
  local lastState = reportsOfKind("state")[#reportsOfKind("state")]
  check("…which sends the LATEST facts once", #reportsOfKind("state") == sent0 + 7 and lastState.args.facts.n == 9)
  aireport.state({ n = 9 })
  check("identical facts are not re-sent", #reportsOfKind("state") == sent0 + 7)

  -- event
  clock = t0 + 1200
  check("event type pattern enforced", aireport.event("Bad Type", "x") == false)
  check("event data must be scalars", aireport.event("a.b", "x", { t = {} }) == false)
  local data = {}
  for i = 1, 17 do
    data["k" .. i] = i
  end
  check("event data over 16 keys refused", aireport.event("a.b", "x", data) == false)
  local e0 = #reportsOfKind("event")
  local okCount = 0
  for i = 1, 12 do
    if aireport.event("weather.change", string.rep("x", 300), { i = i }) then
      okCount = okCount + 1
    end
  end
  check("event: at most 10 a minute, the rest dropped (counted)", okCount == 10 and #reportsOfKind("event") == e0 + 10)
  check("…rate_limited counter", aireport.counters().rate_limited >= 2)
  local ev = reportsOfKind("event")[#reportsOfKind("event")].args
  check(
    "event text cut to 240, `at` stamped in epoch seconds (a whole number)",
    #ev.text == 240 and type(ev.at) == "number" and ev.at == math.floor(ev.at) and math.abs(ev.at - os.time()) < 3600,
    tostring(ev.at)
  )

  -- diagnostic
  check("diagnostic severity closed", aireport.diagnostic("critical", "a.b", "x") == false)
  check("diagnostic code pattern", aireport.diagnostic("info", "A B", "x") == false)
  local g0 = #reportsOfKind("diagnostic")
  okCount = 0
  for _ = 1, 8 do
    if aireport.diagnostic("warning", "feed.stale", "stale") then
      okCount = okCount + 1
    end
  end
  check("diagnostic: at most 6 a minute", okCount == 6 and #reportsOfKind("diagnostic") == g0 + 6)
  clock = t0 + 1261
  check("…the window refills", aireport.diagnostic("info", "feed.ok", "ok") == true)

  -- every frame sent is v1 and one of the four kinds
  local bad = 0
  for _, r in ipairs(ai.received) do
    if r.capability == "ai_core.report" and (r.args.v ~= 1 or not aireport.KINDS[r.args.kind]) then
      bad = bad + 1
    end
  end
  check("every report sent is v=1 and a closed kind", bad == 0)

  -- describe size bound (8 KB) and same-hash spacing
  local values = {}
  for i = 1, 16 do
    values[i] = string.format("value_%02d_", i) .. string.rep("v", 30)
  end
  local refusedLarge = false
  for q = 1, 8 do
    local params = {}
    for p = 1, 6 do
      params[p] = { name = "p" .. p, type = "enum", values = values, required = false }
    end
    local ok, why = aireport.declareQuery({ id = "big_" .. q, description = "d", params = params }, function()
      return {}
    end)
    if not ok and why == "too_large" then
      refusedLarge = true
    end
  end
  check("a declaration that pushes describe over 8 KB is refused", refusedLarge)
  local raw = JSON:encode(aireport.buildDescribe())
  check("…describe stays within 8 KB", #raw <= 8192, #raw)
  local dCount = #reportsOfKind("describe")
  aireport.describe({ summary = "Weather." })
  check("a describe change is sent (hash differs)", #reportsOfKind("describe") == dCount + 1)
  aireport.describe({ summary = "Weather." })
  check("an unchanged describe is not re-sent", #reportsOfKind("describe") == dCount + 1)
  pushDirectory() -- (nothing changed in the directory)
  check("a directory change within 10 min does not re-send the same describe", #reportsOfKind("describe") == dCount + 1)
  local sBefore = #reportsOfKind("state")
  clock = clock + 601
  agent.bus:directoryChanged()
  pushDirectory()
  check(
    "after 10 min a directory change re-sends it (an AI Core restart recovers it)",
    #reportsOfKind("describe") == dCount + 2
  )
  check("…and every directory change re-sends the latest state", #reportsOfKind("state") == sBefore + 1)
  check("controls: class closed", aireport.describe({ controls = { { id = "x", label = "X", class = "toaster" } } }) == false)
  check("describe keys closed", aireport.describe({ hash = "x" }) == false)
  -- KI-47: no describe the helper builds may carry empty text, because AI
  -- Core refuses such a describe whole. Checked against AI Core's own
  -- validator (src/aicore/reports.lua), not a copy of its rules.
  local AiReports = require("aicore.reports")
  local function aiCoreAccepts()
    local item, why, field = AiReports.validate("atmosphere", "800", aireport.buildDescribe())
    return item ~= nil, tostring(why) .. ":" .. tostring(field)
  end
  check("(AI Core accepts the describe as it stands)", aiCoreAccepts())
  local okV = aireport.describe({ vocabulary = { "rain", "", "   ", "\1\2", "wind" } })
  local vocab = aireport.buildDescribe().vocabulary
  check(
    "empty vocabulary words are dropped, the rest kept in order",
    okV == true and #vocab == 2 and vocab[1] == "rain" and vocab[2] == "wind",
    JSON:encode(vocab)
  )
  check("…and AI Core accepts that describe", aiCoreAccepts())
  local okE, whyE = aireport.describe({ summary = "" })
  local okB, whyB = aireport.describe({ summary = " \t " })
  check(
    "an explicitly empty or blank summary is refused (summary), the old one kept",
    okE == false and whyE == "summary" and okB == false and whyB == "summary" and aireport.buildDescribe().summary == "Weather."
  )
  local okC = aireport.describe({ controls = { { id = "zone_1", label = "", class = "other" }, { id = "zone_2", class = "other" } } })
  local controls = aireport.buildDescribe().controls
  check(
    "a control with an empty or missing label is labelled with its id",
    okC == true and controls[1].label == "zone_1" and controls[2].label == "zone_2",
    JSON:encode(controls)
  )
  check("…and AI Core accepts that describe", aiCoreAccepts())
  -- Two controls of one id: AI Core refuses that whole describe, so the
  -- helper refuses it first and keeps the controls it had.
  local before = JSON:encode(aireport.buildDescribe().controls)
  local okDup, whyDup = aireport.describe({
    controls = { { id = "zone_1", label = "One", class = "other" }, { id = "zone_1", label = "Two", class = "other" } },
  })
  check(
    "duplicate control ids are refused (control_duplicate), the old controls kept",
    okDup == false and whyDup == "control_duplicate" and JSON:encode(aireport.buildDescribe().controls) == before,
    tostring(okDup) .. ":" .. tostring(whyDup)
  )
  local okDup2, whyDup2 = aireport.describe({
    controls = { { id = "zone_1", label = "One", class = "other" }, { id = "zone_1\1", label = "Two", class = "other" } },
  })
  check("…also when two ids only differ before cleaning", okDup2 == false and whyDup2 == "control_duplicate")
  check("…and AI Core accepts the describe the helper still holds", aiCoreAccepts())
  -- The defect itself, built by hand: AI Core refuses it (so the guard is
  -- what keeps it off the wire).
  local raw = aireport.buildDescribe()
  raw.controls = { { id = "a", label = "A", class = "other" }, { id = "a", label = "B", class = "other" } }
  raw.hash = aireport.hash(raw)
  check("(AI Core refuses a describe with duplicate control ids)", AiReports.validate("atmosphere", "800", raw) == nil)

  -- clean()
  check("clean strips U+2066..2069 and U+061C", aireport.clean("a\226\129\166b\216\156c") == "abc")
  check("clean cuts between characters", aireport.clean("aé", 2) == "a")
end

-- ── [9] declared queries and actions ────────────────────────────────────────
print("[9] declared queries and actions")
do
  fresh()
  newAgent(2)
  aiRegister()
  -- declaration validation: each case is otherwise valid, so the reason
  -- returned is the one under test (not a missing description).
  local NOOP = function() end
  local function reason(ok, why)
    return ok == false and why or ("accepted:" .. tostring(ok))
  end
  local function q(decl, handler)
    decl.description = decl.description or "d"
    return reason(aireport.declareQuery(decl, handler == nil and NOOP or handler))
  end
  local function a(decl)
    decl.description = decl.description or "d"
    return reason(aireport.declareAction(decl, NOOP))
  end
  check("query id pattern", q({ id = "Bad" }) == "query_id")
  check("query keys closed", q({ id = "q", extra = 1 }) == "query_keys")
  check("handler required", reason(aireport.declareQuery({ id = "q", description = "d" })) == "handler")
  check("action risk closed", a({ id = "a", title = "A", risk = "critical" }) == "action_risk")
  check("action title <= 80", a({ id = "a", title = string.rep("t", 81), risk = "low" }) == "action_title")
  local seven = {}
  for i = 1, 7 do
    seven[i] = { name = "p" .. i, type = "boolean" }
  end
  check("<= 6 params", q({ id = "q", params = seven }) == "params")
  check(
    "duplicate param refused",
    q({ id = "q", params = { { name = "a", type = "boolean" }, { name = "a", type = "boolean" } } }) == "param_duplicate"
  )
  check("enum needs values", q({ id = "q", params = { { name = "a", type = "enum" } } }) == "param_values")
  check("min <= max", q({ id = "q", params = { { name = "a", type = "integer", min = 5, max = 1 } } }) == "param_range")
  check(
    "max_len only on strings, <= 64",
    q({ id = "q", params = { { name = "a", type = "string", max_len = 65 } } }) == "param_max_len"
      and q({ id = "q", params = { { name = "a", type = "integer", max_len = 5 } } }) == "param_max_len"
  )
  -- KI-47: required, non-empty text. AI Core refuses a describe with empty
  -- text, so the helper refuses the declaration instead.
  check("query without a description → query_description", reason(aireport.declareQuery({ id = "q" }, NOOP)) == "query_description")
  check(
    "query with an empty or blank description → query_description",
    q({ id = "q", description = "" }) == "query_description" and q({ id = "q", description = "   " }) == "query_description"
  )
  check("query with a missing id → query_id", q({ description = "d" }) == "query_id" and q({ id = "" }) == "query_id")
  check(
    "action without a description → action_description",
    reason(aireport.declareAction({ id = "a", title = "A", risk = "low" }, NOOP)) == "action_description"
      and a({ id = "a", title = "A", risk = "low", description = "" }) == "action_description"
  )
  check(
    "action with a missing or empty title → action_title",
    a({ id = "a", risk = "low" }) == "action_title" and a({ id = "a", title = "", risk = "low" }) == "action_title"
  )
  check("action with a missing id → action_id", a({ title = "A", risk = "low" }) == "action_id")
  check("nothing refused above was declared", next(aireport._state().queries) == nil and next(aireport._state().actions) == nil)

  local queryCalls, actionCalls = 0, 0
  local okQ = aireport.declareQuery({
    id = "forecast",
    description = "The forecast for a day.",
    params = {
      { name = "day", type = "enum", values = { "today", "tomorrow" }, required = true },
      { name = "hours", type = "integer", min = 1, max = 48 },
      { name = "units", type = "string", max_len = 8 },
      { name = "detail", type = "boolean" },
      { name = "ratio", type = "number", min = 0, max = 1 },
    },
  }, function(params)
    queryCalls = queryCalls + 1
    if params.hours == 13 then
      error("boom")
    end
    if params.hours == 14 then
      return { a = { b = { c = { d = 1 } } } }
    end
    if params.hours == 15 then
      return nil, "feed_down"
    end
    return { day = params.day, high_f = 80 }
  end)
  local okA = aireport.declareAction({
    id = "refresh_now",
    title = "Refresh the weather now",
    description = "Fetches fresh data.",
    params = { { name = "source", type = "enum", values = { "primary", "backup" }, required = false } },
    risk = "low",
  }, function(params)
    actionCalls = actionCalls + 1
    if params.source == "primary" then
      -- Ruling 23: work begun that finishes later.
      return "Refresh started; the outcome follows as an event", { in_progress = true }
    end
    return "Refreshed from " .. tostring(params.source or "backup"), "ignored second value"
  end)
  check("valid query and action declared", okQ and okA)
  aireport.start({ sku = "SBOS_ATMOSPHERE" })
  local manifest = JSON:decode(last("SBOS_MODULE_REGISTER").params.manifest)
  local caps = {}
  for _, c in ipairs(manifest.capabilities) do
    caps[c.id] = c.version
  end
  check("manifest advertises ai.query v1 and ai.action v1", caps["ai.query"] == 1 and caps["ai.action"] == 1)
  local d = reportsOfKind("describe")[1].args
  check(
    "describe carries the declarations as data",
    #d.queries == 1 and d.queries[1].id == "forecast" and #d.actions == 1 and d.actions[1].risk == "low"
  )
  local itemD, whyD, fieldD = require("aicore.reports").validate("atmosphere", "800", d)
  check("AI Core accepts the describe carrying the declarations", itemD ~= nil, tostring(whyD) .. ":" .. tostring(fieldD))
  local hash = d.hash
  check("declarationHash() is the describe hash", aireport.declarationHash() == hash)

  -- queries
  local r = aiAsk("ai.query", { query_id = "forecast", params = { day = "today", hours = 3 } })
  check("valid query answered ok", r and r.status == "ok" and r.result.ok == true and r.result.data.high_f == 80, r and r.error_code)
  local function refused(args, code)
    local n = queryCalls
    local a = aiAsk("ai.query", args)
    return a ~= nil and a.status == "error" and a.error_code == code and queryCalls == n
  end
  check("unknown query refused", refused({ query_id = "nope" }, "invalid_args"))
  check("args keys closed", refused({ query_id = "forecast", params = { day = "today" }, x = 1 }, "invalid_args"))
  check("unknown param refused", refused({ query_id = "forecast", params = { day = "today", zone = 1 } }, "invalid_args"))
  check("missing required refused", refused({ query_id = "forecast", params = { hours = 3 } }, "invalid_args"))
  check("enum outside values refused", refused({ query_id = "forecast", params = { day = "yesterday" } }, "invalid_args"))
  check("integer must be integral", refused({ query_id = "forecast", params = { day = "today", hours = 2.5 } }, "invalid_args"))
  check("integer range", refused({ query_id = "forecast", params = { day = "today", hours = 49 } }, "invalid_args"))
  check("number range", refused({ query_id = "forecast", params = { day = "today", ratio = 1.5 } }, "invalid_args"))
  check("boolean type", refused({ query_id = "forecast", params = { day = "today", detail = "yes" } }, "invalid_args"))
  check("string length", refused({ query_id = "forecast", params = { day = "today", units = "fahrenheit" } }, "invalid_args"))
  check("string with a control character", refused({ query_id = "forecast", params = { day = "today", units = "f\1" } }, "invalid_args"))
  check("wrong type for enum", refused({ query_id = "forecast", params = { day = 1 } }, "invalid_args"))
  r = aiAsk("ai.query", { query_id = "forecast", params = { day = "today", hours = 13 } })
  check("a failing handler -> internal_error", r and r.status == "error" and r.error_code == "internal_error")
  r = aiAsk("ai.query", { query_id = "forecast", params = { day = "today", hours = 14 } })
  check("data deeper than 3 -> internal_error", r and r.status == "error" and r.error_code == "internal_error")
  r = aiAsk("ai.query", { query_id = "forecast", params = { day = "today", hours = 15 } })
  check("handler nil, reason -> {ok=false, reason}", r and r.status == "ok" and r.result.ok == false and r.result.reason == "feed_down")
  local direct
  aireport._serveQuery({ from_module_id = "flight_recorder", args = { query_id = "forecast", params = { day = "today" } } }, function(s, res, code)
    direct = { s, res, code }
  end)
  check("a requester other than ai_core is refused (beyond the bus policy)", direct[1] == "error" and direct[3] == "not_permitted")

  -- actions
  local function act(args)
    return aiAsk("ai.action", args)
  end
  r = act({ action_id = "refresh_now", params = { source = "backup" }, ai_action_id = "act-1", declaration_hash = hash })
  check(
    "action with the current hash runs once",
    r and r.status == "ok" and r.result.ok == true and r.result.result_text == "Refreshed from backup" and actionCalls == 1
  )
  check("…a finished action is plain success (no in_progress key)", r and r.result.in_progress == nil)
  r = act({ action_id = "refresh_now", params = { source = "primary" }, ai_action_id = "act-1b", declaration_hash = hash })
  check(
    "started, not finished: { ok = true, in_progress = true, result_text } (ruling 23)",
    r
      and r.status == "ok"
      and r.result.ok == true
      and r.result.in_progress == true
      and r.result.result_text == "Refresh started; the outcome follows as an event"
      and actionCalls == 2,
    r and JSON:encode(r.result)
  )
  actionCalls = 1 -- the counts below are about the refused calls
  r = act({ action_id = "refresh_now", params = {}, ai_action_id = "act-2", declaration_hash = "0000000000000000" })
  check(
    "declaration_hash mismatch refused, handler not run",
    r and r.status == "error" and r.error_code == "not_permitted" and r.result.reason == "declaration_changed" and actionCalls == 1
  )
  r = act({ action_id = "refresh_now", params = {}, ai_action_id = "act-3" })
  check("missing declaration_hash refused", r and r.error_code == "not_permitted" and actionCalls == 1)
  r = act({ action_id = "refresh_now", params = { source = "other" }, ai_action_id = "act-4", declaration_hash = hash })
  check("action params validated, handler not run", r and r.error_code == "invalid_args" and actionCalls == 1)
  r = act({ action_id = "nope", params = {}, ai_action_id = "act-5", declaration_hash = hash })
  check("unknown action refused", r and r.error_code == "invalid_args" and actionCalls == 1)
  r = act({ action_id = "refresh_now", ai_action_id = "bad id!", declaration_hash = hash })
  check("ai_action_id shape", r and r.error_code == "invalid_args" and actionCalls == 1)

  -- unverified AI Core: actions refused, queries still served
  resolverOff = true
  aiRegister()
  pushDirectory()
  r = act({ action_id = "refresh_now", params = {}, ai_action_id = "act-6", declaration_hash = hash })
  check(
    "an unverified AI Core cannot invoke an action",
    r and r.error_code == "not_permitted" and r.result.reason == "requester_unverified" and actionCalls == 1
  )
  r = aiAsk("ai.query", { query_id = "forecast", params = { day = "today" } })
  check("…a read-only query is still served", r and r.status == "ok")
  resolverOff = false
  aiRegister()
  pushDirectory()

  -- a declaration change changes the hash: the approved one is refused
  local regs = count("SBOS_MODULE_REGISTER")
  -- A second, different declaration under the same id is refused: the
  -- first one stays, the hash does not move.
  local okDupA, whyDupA = aireport.declareAction({ id = "refresh_now", title = "Refresh now", description = "d", risk = "medium" }, function()
    actionCalls = actionCalls + 1
    return "dup"
  end)
  check(
    "a different action under a declared id is refused (action_duplicate), the hash unchanged",
    okDupA == false and whyDupA == "action_duplicate" and aireport.declarationHash() == hash,
    tostring(okDupA) .. ":" .. tostring(whyDupA)
  )
  local okDupQ, whyDupQ = aireport.declareQuery({ id = "forecast", description = "Another forecast." }, function()
    return {}
  end)
  check(
    "a different query under a declared id is refused (query_duplicate)",
    okDupQ == false and whyDupQ == "query_duplicate" and aireport.declarationHash() == hash
  )
  local sameDecl = aireport._state().actions.refresh_now.decl
  local okSame = aireport.declareAction({
    id = sameDecl.id,
    title = sameDecl.title,
    description = sameDecl.description,
    params = { { name = "source", type = "enum", values = { "primary", "backup" }, required = false } },
    risk = sameDecl.risk,
  }, function(params)
    actionCalls = actionCalls + 1
    return "Refreshed from " .. tostring(params.source or "primary")
  end)
  check("re-declaring the SAME declaration is accepted (handler swapped, hash unchanged)", okSame == true and aireport.declarationHash() == hash)
  check(
    "options are closed",
    select(2, aireport.declareQuery({ id = "forecast", description = "x" }, function() end, { force = true })) == "options"
  )
  local dNow = aireport.buildDescribe()
  local itemNow = require("aicore.reports").validate("atmosphere", "800", dNow)
  check("AI Core accepts the describe after the refused duplicates", itemNow ~= nil)
  aireport.declareAction({ id = "refresh_now", title = "Refresh now", description = "d", risk = "medium" }, function()
    actionCalls = actionCalls + 1
    return "ok"
  end, { replace = true })
  check("changed declaration ({ replace = true }) -> new hash", aireport.declarationHash() ~= hash)
  r = act({ action_id = "refresh_now", params = {}, ai_action_id = "act-7", declaration_hash = hash })
  check("…the old hash is refused", r and r.result.reason == "declaration_changed" and actionCalls == 1)
  check("same capability set: no re-registration", count("SBOS_MODULE_REGISTER") == regs)
  check("…describe re-sent with the new hash", reportsOfKind("describe")[#reportsOfKind("describe")].args.hash == aireport.declarationHash())

  -- declaring the first query after start re-registers with the new manifest
  fresh()
  newAgent(2)
  aiRegister()
  aireport.start({ sku = "SBOS_ATMOSPHERE" })
  regs = count("SBOS_MODULE_REGISTER")
  aireport.declareQuery({ id = "now", description = "d" }, function()
    return { t = 1 }
  end)
  manifest = JSON:decode(last("SBOS_MODULE_REGISTER").params.manifest)
  check("first query after start -> re-registered advertising ai.query", count("SBOS_MODULE_REGISTER") == regs + 1 and manifest.capabilities[1].id == "ai.query")
  r = aiAsk("ai.query", { query_id = "now" })
  check("…and served", r and r.status == "ok" and r.result.data.t == 1)
end

-- ── [10] attach mode ────────────────────────────────────────────────────────
print("[10] attach mode (a driver with its own moduleclient)")
do
  fresh()
  newAgent(2)
  aiRegister()
  DC_FILENAME = "smartbuildos-flight-recorder.c4z"
  c4i["smartbuildos-flight-recorder.c4z"] = { [SELF] = {} }
  local mine = function() end
  local driverSaw = {}
  client.setup({
    module_id = "flight_recorder",
    driver_version = "1",
    singleton = true,
    require_protocol = 2,
    manifest = { driver = "sbos.flight_recorder", capabilities = aireport.capabilities({ { id = "events.query", version = 1 } }) },
    onRegistered = function(reply)
      driverSaw[#driverSaw + 1] = "registered"
      aireport.onRegistered(reply)
    end,
    onDirectoryChanged = function(v)
      aireport.onDirectoryChanged(v)
    end,
    onAgentState = function(a, why)
      aireport.onAgentState(a, why)
    end,
    onConfig = function()
      return true, 0
    end,
  })
  local theirs = EC.SBOS_DRIVER_CONFIG
  local ok = aireport.attach(client, { sku = "SBOS_FLIGHT_RECORDER" })
  check("attach accepts the driver's client", ok and aireport.mode() == "attach")
  check("value Searching… before the driver registers", value() == V.searching, value())
  client.register()
  check("the driver's own callback still runs", driverSaw[1] == "registered")
  check("the driver's EC.SBOS_DRIVER_CONFIG is untouched", EC.SBOS_DRIVER_CONFIG == theirs and theirs ~= mine)
  local d = reportsOfKind("describe")[1]
  check("discovered and described through the driver's client", d ~= nil and d.from == "flight_recorder")
  check("value: reporting", value() == "Found — reporting (v20261118.2)", value())
  local regs = count("SBOS_MODULE_REGISTER")
  aireport.declareQuery({ id = "late", description = "d" }, function()
    return {}
  end)
  check("attach never re-registers the driver's client", count("SBOS_MODULE_REGISTER") == regs)
  aireport.stop()
  check("stop in attach mode leaves the driver's client registered", client.isRegistered() and count("SBOS_MODULE_UNREGISTER") == 0)

  -- attach against a v1-only Agent where the driver does not require v2
  fresh()
  newAgent(1)
  DC_FILENAME = "smartbuildos-flight-recorder.c4z"
  c4i["smartbuildos-flight-recorder.c4z"] = { [SELF] = {} }
  client.setup({
    module_id = "flight_recorder",
    driver_version = "1",
    singleton = true,
    onRegistered = function(reply)
      aireport.onRegistered(reply)
    end,
    onAgentState = function(a, why)
      aireport.onAgentState(a, why)
    end,
  })
  aireport.attach(client, {})
  client.register()
  check("v1 Agent (driver not requiring v2): registered at 1", client.isRegistered() and client.protocol() == 1)
  check("value: SmartBuildOS Agent update required", value() == V.agent_update, value())
  check("no discover, no request", count("SBOS_MODULE_DISCOVER") == 0 and count("SBOS_MODULE_REQUEST") == 0)
  check("attach with an unknown file is refused", aireport.attach(client, { file = "x.c4z" }) == false)
  DC_FILENAME = "smartbuildos-atmosphere.c4z"
end

-- ── [11] registry full ──────────────────────────────────────────────────────
print("[11] the Agent's module list is full")
do
  fresh()
  newAgent(2)
  for i = 1, Modules.LIMITS.modules do
    agent.registry:register({
      module_id = "probe" .. i,
      instance_id = tostring(1000 + i),
      protocol_min = "1",
      protocol_max = "2",
      singleton = "true",
    })
  end
  aireport.start({ sku = "SBOS_ATMOSPHERE" })
  check("refused registry_full", agent.lastReply.reason == "registry_full")
  check("value: Not registered — Agent module list full", value() == V.registry_full, value())
  check("no discover, no request", count("SBOS_MODULE_DISCOVER") == 0 and count("SBOS_MODULE_REQUEST") == 0)
  agent.registry:remove("probe1", "1001")
  client.register()
  check("room again -> registered, Not installed", client.isRegistered() and value() == V.not_installed, value())
end

-- ── [12] Agent restart ──────────────────────────────────────────────────────
print("[12] the Agent restarts (SBOS_MODULE_AGENT_HELLO)")
do
  fresh()
  newAgent(2)
  aiRegister()
  aireport.start({ sku = "SBOS_ATMOSPHERE" })
  check("(reporting)", value() == "Found — reporting (v20261118.2)")
  newAgent(2) -- memory lost; AI Core re-registers first
  aiRegister()
  local seen = {}
  local realUpdate = UpdateProperty
  UpdateProperty = function(n, v)
    seen[#seen + 1] = v
    realUpdate(n, v)
  end
  EC.SBOS_MODULE_AGENT_HELLO({})
  UpdateProperty = realUpdate
  check("hello -> Searching… then re-registered and reporting again", seen[1] == V.searching and value() == "Found — reporting (v20261118.2)", table.concat(seen, " | "))
end

-- ── [13] stop ───────────────────────────────────────────────────────────────
print("[13] stop")
do
  fresh()
  newAgent(2)
  aiRegister()
  aireport.start({ sku = "SBOS_ATMOSPHERE" })
  aireport.stop()
  check("start mode unregisters its client", count("SBOS_MODULE_UNREGISTER") == 1 and not client.isRegistered())
  check("no aireport timer left", timerLike("SbosAiReport") == nil)
  local n = count("SBOS_MODULE_REQUEST")
  aireport.event("weather.change", "x")
  check("nothing is sent after stop", count("SBOS_MODULE_REQUEST") == n)
end

print("[13a] need_describe (AI Core holds no describe for us): describe re-sent at once (KI-43 closed)")
do
  fresh()
  newAgent(2)
  aireport.start({ sku = "SBOS_ATMOSPHERE", summary = "Weather for the home." })
  aiRegister()
  pushDirectory()
  check("(reporting)", #reportsOfKind("describe") == 1 and value():find("^Found — reporting") ~= nil, value())
  -- AI Core restarted without going stale: it holds nothing now. Like the
  -- real hub, it says need_describe until a describe arrives.
  local held = false
  ai.needDescribe = function(args)
    if args.kind == "describe" then
      held = true
    end
    return not held
  end
  local d0 = #reportsOfKind("describe")
  aireport._clock = function()
    return os.time() + 61
  end
  aireport.state({ temperature_f = 80 })
  check("a state answered need_describe -> the same-hash describe goes again at once", #reportsOfKind("describe") == d0 + 1)
  check("…counted", aireport.counters().describe_requested == 1, aireport.counters().describe_requested)
  aireport._clock = function()
    return os.time() + 122
  end
  aireport.state({ temperature_f = 81 })
  check("once AI Core holds it, no further describe", #reportsOfKind("describe") == d0 + 1)
  -- An AI Core that REFUSED this describe (invalid): need_describe does not
  -- loop it back.
  held = false
  ai.accepted, ai.reason = false, "invalid"
  ai.needDescribe = function()
    return true
  end
  aireport._clock = function()
    return os.time() + 183
  end
  aireport.state({ temperature_f = 82 }) -- refused + need_describe -> describe (refused)
  local d1 = #reportsOfKind("describe")
  aireport._clock = function()
    return os.time() + 244
  end
  aireport.state({ temperature_f = 83 })
  aireport._clock = function()
    return os.time() + 305
  end
  aireport.state({ temperature_f = 84 })
  check(
    "a describe AI Core refused (invalid) is not re-sent on need_describe",
    #reportsOfKind("describe") == d1,
    #reportsOfKind("describe") - d1
  )
  ai.accepted, ai.reason, ai.needDescribe = true, nil, nil
end

print("[13b] the OSS build: no DC_FILENAME (removed by the preprocessor), DRIVER_FILENAMES")
do
  fresh()
  newAgent(2)
  aiRegister()
  DC_FILENAME = nil
  DRIVER_FILENAMES = { "smartbuildos-atmosphere.c4z" }
  check("the default file is DRIVER_FILENAMES[1]", aireport._defaultFile() == "smartbuildos-atmosphere.c4z")
  local ok, why = aireport.start({ sku = "SBOS_ATMOSPHERE" })
  check("start with neither file nor DC_FILENAME works in the OSS build", ok == true, why)
  check("…registered as atmosphere and reporting", client.isRegistered() and value() == "Found — reporting (v20261118.2)", value())
  aireport.stop()
  DRIVER_FILENAMES = nil
  local okNone, whyNone = aireport.start({})
  check("no file at all: refused, nothing set up", okNone == false and whyNone == "unknown_driver_file")
  DC_FILENAME = "smartbuildos-atmosphere.c4z"
end

print("[14] over the whole run: every closed value was reached, nothing else was painted")
do
  local reached, outside = {}, {}
  for _, v in ipairs(everPainted) do
    if not aireport.isValue(v) then
      outside[#outside + 1] = v
    end
    for i, template in ipairs(aireport.VALUES) do
      local at = template:find("%s", 1, true)
      if (at == nil and v == template) or (at ~= nil and v:sub(1, at - 1) == template:sub(1, at - 1)) then
        reached[i] = true
      end
    end
  end
  local missing = {}
  -- The two "Installed — …" values are painted by sbos.aipresence only;
  -- registered / unverified by the Agent (sbos.agentaicore) only.
  local notHelper = {
    [V.passive_installed] = true,
    [V.no_report] = true,
    [V.registered] = true,
    [V.unverified] = true,
  }
  local helperPainted = {}
  for i, template in ipairs(aireport.VALUES) do
    if reached[i] and (template == V.registered or template == V.unverified) then
      helperPainted[#helperPainted + 1] = template
    end
    if not reached[i] and not notHelper[template] then
      missing[#missing + 1] = template
    end
  end
  check("all 11 helper values of §3.6 were painted at least once", #missing == 0, table.concat(missing, " | "))
  check("the helper never painted the Agent's two values", #helperPainted == 0, table.concat(helperPainted, " | "))
  check("no painted value is outside the closed list", #outside == 0, table.concat(outside, " | "))
end

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
