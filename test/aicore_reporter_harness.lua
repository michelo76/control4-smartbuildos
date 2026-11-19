-- Shared harness for the reference drivers' AI Core tests
-- (test_atmosphere_aicore, test_mode_composer_aicore,
-- test_flightrecorder_aicore). Not a test file itself (no test_ prefix).
--
-- The Agent side is the REAL registry (identity binding included) and the
-- REAL bus behind a fake C4:SendToDevice; AI Core is a fake provider on that
-- bus that answers `ai_core.report` after running every report through AI
-- Core's REAL validator (aicore.reports.validate): a report AI Core would
-- refuse is answered `accepted = false`, so a driver that builds one never
-- reaches "Found — reporting". Frames to this driver go through its real
-- ExecuteCommand dispatch.
--
-- Use:
--   local H = require("aicore_reporter_harness")
--   H.install({ selfId = 42, file = "smartbuildos-atmosphere.c4z" })
--   ... load the driver chunk ...
--   H.takeTimers()               -- after the chunk: timers become manual
--   OnDriverInit(); OnDriverLateInit()
--   H.aiRegister(); H.pushDirectory()

JSON = JSON or require("JSON")

local H = {}

H.AGENT, H.AICORE = 99, 700
H.frames = {} -- every C4:SendToDevice the driver made
H.timers = {}
H.c4i = {}
H.agentPresent = true
H.ai = {}

local Modules, ModuleBus, AiReports
local busTimers = {}

local function aiReset()
  H.ai = {
    entry = nil,
    state = "ready",
    version = "20261118.2",
    received = {}, -- { capability, args, from, from_instance, item, why, field }
    responses = {}, -- answers to AI Core's own requests
  }
end
aiReset()

local function aiReceive(command, params)
  if command == "SBOS_MODULE_REQUEST" then
    local okA, args = pcall(function()
      return JSON:decode(params.args)
    end)
    local item, why, field = nil, "invalid", "decode"
    if okA and type(args) == "table" then
      item, why, field = AiReports.validate(params.from_module_id, params.from_instance_id, args)
    end
    H.ai.received[#H.ai.received + 1] = {
      capability = params.capability,
      args = okA and args or nil,
      from = params.from_module_id,
      from_instance = params.from_instance_id,
      item = item,
      why = why,
      field = field,
    }
    local result = { accepted = item ~= nil, ai_core = { state = H.ai.state, version = H.ai.version } }
    if item == nil then
      result.reason = why
    end
    H.bus:response(H.ai.entry, {
      request_id = params.request_id,
      status = "ok",
      error_code = "ok",
      result = JSON:encode(result),
      cursor = "",
    })
  elseif command == "SBOS_MODULE_RESPONSE" then
    H.ai.responses[#H.ai.responses + 1] = params
  end
end

local METHODS = {
  SBOS_MODULE_DISCOVER = "discover",
  SBOS_MODULE_REQUEST = "request",
  SBOS_MODULE_RESPONSE = "response",
  SBOS_MODULE_SUBSCRIBE = "subscribe",
}

--- opts = { selfId, file }
function H.install(opts)
  H.selfId = opts.selfId
  H.file = opts.file
  Modules = require("sbos.modules")
  ModuleBus = require("sbos.modulebus")
  AiReports = require("aicore.reports")
  H.c4i[H.file] = { [H.selfId] = {} }
  H.registry = Modules.Registry.new({
    now = os.time,
    newToken = function()
      H.n = (H.n or 0) + 1
      return string.format("tok%029d", H.n)
    end,
    -- nil = Director gave no answer: the Agent registers unverified.
    devicesForFile = function(file)
      return H.c4i[file]
    end,
  })
  H.bus = ModuleBus.new({
    registry = H.registry,
    now = os.time,
    send = function(id, command, params)
      if tostring(id) == tostring(H.AICORE) then
        aiReceive(command, params)
      elseif tostring(id) == tostring(H.selfId) then
        ExecuteCommand(command, params)
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
  })
  -- The Agent's own buckets are covered by test_sbos_modulebus; a test runs
  -- minutes of traffic inside one wall-clock second.
  H.bus.allow = function()
    return true
  end
  function C4:GetDevicesByC4iName(file)
    if file == "smartbuildos.c4z" then
      return H.agentPresent and { [H.AGENT] = {} } or nil
    end
    return H.c4i[file]
  end
  function C4:SendToDevice(id, command, params)
    local copy = {}
    for k, v in pairs(params or {}) do
      copy[k] = v
    end
    H.frames[#H.frames + 1] = { id = id, command = command, params = copy }
    if tonumber(id) ~= H.AGENT or not H.agentPresent then
      return
    end
    if command == "SBOS_MODULE_REGISTER" then
      local ok, reply, entry = H.registry:register(params)
      reply.agent_protocol_min = "1"
      reply.agent_protocol_max = "2"
      reply.paired = "true"
      reply.connected = "true"
      if ok then
        H.bus:onRegistered(entry)
      end
      ExecuteCommand("SBOS_MODULE_REGISTERED", reply)
    elseif command == "SBOS_MODULE_STATUS" then
      local entry = H.registry:authenticate(params)
      if entry then
        H.registry:touch(entry, params)
      end
    elseif command == "SBOS_MODULE_UNREGISTER" then
      local entry = H.registry:authenticate(params)
      if entry then
        H.registry:remove(entry.module_id, entry.instance_id)
        H.bus:onRemoved(entry)
      end
    elseif METHODS[command] then
      local entry = H.registry:authenticate(params)
      if entry then
        H.bus[METHODS[command]](H.bus, entry, params)
      end
    end
  end
end

--- After the driver chunk ran (the vendored timer lib is loaded by then):
--- timers become manual, fired by name with H.fire.
function H.takeTimers()
  function SetTimer(id, ms, fn, repeating)
    H.timers[id] = { ms = ms, fn = fn, repeating = repeating }
  end
  function CancelTimer(id)
    if type(id) == "string" then
      H.timers[id] = nil
    end
  end
  function KillAllTimers()
    H.timers = {}
  end
end

function H.fire(id)
  local t = H.timers[id]
  if t == nil then
    return false
  end
  if not t.repeating then
    H.timers[id] = nil
  end
  t.fn()
  return true
end

--- Fires the Agent's debounced SBOS_MODULE_DIRECTORY_CHANGED push.
function H.pushDirectory()
  local fn = busTimers[ModuleBus.DIRECTORY_TIMER]
  busTimers[ModuleBus.DIRECTORY_TIMER] = nil
  if fn then
    fn()
  end
  return fn ~= nil
end

local AI_CAPS = { { id = "ai_core.report", version = 1, kind = "request" } }

--- AI Core registers on the Agent (verified: Director lists its file;
--- opts.unverified: Director gives no answer for it).
function H.aiRegister(opts)
  H.c4i["smartbuildos-ai-core.c4z"] = not (opts and opts.unverified) and { [H.AICORE] = {} } or nil
  local ok, reply, entry = H.registry:register({
    module_id = "ai_core",
    instance_id = tostring(H.AICORE),
    requester = tostring(H.AICORE),
    driver_version = H.ai.version,
    protocol_min = "1",
    protocol_max = "2",
    singleton = "true",
    status = "ready",
    manifest = JSON:encode({ driver = "sbos.ai_core", version = H.ai.version, protocol = 2, capabilities = AI_CAPS }),
  })
  if ok then
    H.ai.entry = entry
    H.bus:onRegistered(entry)
  end
  return ok, reply
end

function H.aiRemove()
  local entry = H.ai.entry
  H.registry:remove("ai_core", tostring(H.AICORE))
  H.c4i["smartbuildos-ai-core.c4z"] = nil
  H.bus:onRemoved(entry)
end

--- AI Core asks this driver (through the real bus routing and policy).
local nreq = 0
function H.aiAsk(to, capability, args)
  nreq = nreq + 1
  local before = #H.ai.responses
  H.bus:request(H.ai.entry, {
    module_id = "ai_core",
    instance_id = tostring(H.AICORE),
    token = H.ai.entry.token,
    request_id = "q" .. nreq,
    idempotency_key = "k" .. nreq,
    to = to,
    capability = capability,
    args = JSON:encode(args),
    deadline = tostring(os.time() + 30),
  })
  local r = H.ai.responses[before + 1]
  if r == nil then
    return nil
  end
  local okR, result = pcall(function()
    return JSON:decode(r.result)
  end)
  return { status = r.status, error_code = r.error_code, result = okR and result or nil }
end

--- Reports AI Core received (of one kind, or all).
function H.reports(kind)
  local out = {}
  for _, r in ipairs(H.ai.received) do
    if r.capability == "ai_core.report" and r.args and (kind == nil or r.args.kind == kind) then
      out[#out + 1] = r
    end
  end
  return out
end

--- Every report AI Core received was valid by AI Core's own validator.
function H.allValid()
  for _, r in ipairs(H.reports()) do
    if r.item == nil then
      return false, tostring(r.args and r.args.kind) .. ": " .. tostring(r.why) .. ":" .. tostring(r.field)
    end
  end
  return true
end

--- Count of frames this driver sent, by command (and capability).
function H.count(command, capability)
  local n = 0
  for _, f in ipairs(H.frames) do
    if f.command == command and (capability == nil or f.params.capability == capability) then
      n = n + 1
    end
  end
  return n
end

function H.reportFrames()
  return H.count("SBOS_MODULE_REQUEST", "ai_core.report")
end

return H
