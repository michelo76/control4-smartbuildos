-- sbos.moduleclient with contract v2: the manifest registration param,
-- protocol 1..2, degradation against a v1-only Agent (agent_update_required,
-- v1 services intact), a v2-only module refused by a v1 Agent, subscriptions
-- re-sent after SBOS_MODULE_AGENT_HELLO, and bus counters on the status
-- frame. The Agent side is the real registry + bus behind a fake
-- SendToDevice.
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

-- ── timers / clock ───────────────────────────────────────────────────────────
ONE_SECOND = 1000
ONE_MINUTE = 60000
-- Timers are recorded, never fired: this file drives every step by hand.
local timers = {}
function SetTimer(id, ms, fn, repeating)
  timers[id] = { ms = ms, fn = fn, repeating = repeating }
end
function CancelTimer(id)
  timers[id] = nil
end
EC = EC or {}

local AGENT = 99
local SELF = 601
package.preload["sbos.license"] = function()
  return {
    agentDeviceId = function()
      return AGENT
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

local Modules = require("sbos.modules")
local ModuleBus = require("sbos.modulebus")
local client = require("sbos.moduleclient")

-- ── the Agent ────────────────────────────────────────────────────────────────
local agent = {}
local toAgent = {}
local function newAgent(max)
  agent.max = max
  agent.registry = Modules.Registry.new({
    now = os.time,
    newToken = function()
      agent.n = (agent.n or 0) + 1
      return string.format("tok%029d", agent.n)
    end,
  })
  agent.bus = ModuleBus.new({
    registry = agent.registry,
    now = os.time,
    send = function(_, command, params)
      local h = EC[command]
      if h then
        h(params)
      end
      return true
    end,
    cloudPost = function() end,
    setTimer = function() end,
    cancelTimer = function() end,
    agent = function()
      return { paired = true, connected = true }
    end,
  })
end
local METHODS = {
  SBOS_MODULE_SUBSCRIBE = "subscribe",
  SBOS_MODULE_DISCOVER = "discover",
  SBOS_MODULE_REQUEST = "request",
}
function C4:SendToDevice(id, command, params)
  toAgent[#toAgent + 1] = { id = id, command = command, params = params }
  if id ~= AGENT then
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
  elseif METHODS[command] and agent.max >= 2 then
    local entry = agent.registry:authenticate(params)
    if entry then
      agent.bus[METHODS[command]](agent.bus, entry, params)
    end
  end
end
local function frames(command)
  local out = {}
  for _, f in ipairs(toAgent) do
    if f.command == command then
      out[#out + 1] = f
    end
  end
  return out
end
local function lastFrame(command)
  local list = frames(command)
  return list[#list]
end

local MANIFEST = { driver = "sbos.ai_core", version = "20261118.1", capabilities = {} }
local states = {}
local function setup(over)
  local opts = {
    module_id = "ai_core",
    driver_version = "20261118.1",
    entitlements = { "SBOS_AI_CORE" },
    event_types = { "ai_core." },
    singleton = true,
    manifest = MANIFEST,
    require_protocol = 2,
    status = function()
      return "running", "", { custom = 1 }
    end,
    onAgentState = function(_, why)
      states[#states + 1] = why
    end,
  }
  for k, v in pairs(over or {}) do
    opts[k] = v
  end
  client.setup(opts)
end

print("[1] registration carries the v2 contract")
newAgent(2)
setup()
client.register()
local reg = lastFrame("SBOS_MODULE_REGISTER")
local manifest = reg and JSON:decode(reg.params.manifest) or {}
check("protocol 1..2 offered", reg.params.protocol_min == "1" and reg.params.protocol_max == "2")
check(
  "manifest param: driver, version, protocol 2, capabilities",
  manifest.driver == "sbos.ai_core"
    and manifest.version == "20261118.1"
    and manifest.protocol == 2
    and type(manifest.capabilities) == "table"
)
check("v1 csv params unchanged", reg.params.entitlements == "SBOS_AI_CORE" and reg.params.event_types == "ai_core.")
check("negotiated 2 with a v2 Agent", client.protocol() == 2 and client.agentUpdateRequired() == false)
check("display status ready", client.displayStatus() == "ready", client.displayStatus())
local status = lastFrame("SBOS_MODULE_STATUS")
check("status frame counters carry the bus block", status and JSON:decode(status.params.counters).bus ~= nil)
local dir
client.discover(nil, function(d)
  dir = d
end)
check("discover answered through EC.SBOS_MODULE_DIRECTORY", dir ~= nil and dir.modules[1].module_id == "ai_core")

print("[2] subscriptions are desired state: re-sent after AGENT_HELLO + re-registration")
toAgent = {}
local okS = client.subscribe("fr", { "capture." }, function() end)
check("subscribe sent at once while registered", okS and #frames("SBOS_MODULE_SUBSCRIBE") == 1)
local oldToken = lastFrame("SBOS_MODULE_SUBSCRIBE").params.token
newAgent(2) -- the Agent restarted: empty registry, no subscriptions
toAgent = {}
EC.SBOS_MODULE_AGENT_HELLO({ agent_version = "x" })
check("hello → re-register", #frames("SBOS_MODULE_REGISTER") == 1)
local sub = lastFrame("SBOS_MODULE_SUBSCRIBE")
check(
  "…then the subscription is re-sent with the NEW token",
  sub ~= nil and sub.params.token ~= oldToken and sub.params.token == agent.lastReply.token
)
check("…and granted by the new Agent", agent.bus:health().subscriptions == 1)
check("onAgentState saw the hello", states[#states] == "hello" or states[#states - 1] == "hello")

print("[3] a v2 client against a v1-only Agent: agent_update_required, v1 intact")
newAgent(1)
states = {}
setup()
toAgent = {}
client.register()
check("registered at protocol 1 (v1 services kept)", client.isRegistered() and client.protocol() == 1)
check(
  "agent_update_required reported",
  client.agentUpdateRequired() == true and client.displayStatus() == "agent_update_required"
)
check("onAgentState told agent_update_required", states[#states] == "agent_update_required")
check("lastError says so", client.lastError():find("agent_update_required") ~= nil)
local answer
client.request("flight_recorder", "events.query", {}, {}, function(a)
  answer = a
end)
check(
  "request → incompatible_protocol, nothing sent",
  answer and answer.error_code == "incompatible_protocol" and #frames("SBOS_MODULE_REQUEST") == 0
)
check(
  "subscribe kept but not sent",
  client.subscribe("fr", { "capture." }, function() end) and #frames("SBOS_MODULE_SUBSCRIBE") == 0
)
local env = client.event({ event_type = "ai_core.status", evidence_source = "derived", payload = { ok = true } })
client.sendEvents({ env })
client.flush()
check("v1 event upload still works", #frames("SBOS_MODULE_EVENTS") == 1)
setup({ require_protocol = false })
client.register()
check(
  "a module that does not require v2 is not flagged",
  client.isRegistered() and client.agentUpdateRequired() == false and client.displayStatus() ~= "agent_update_required"
)

print("[4] a v2-only module (protocol_min 2) refused by a v1 Agent")
newAgent(1)
states = {}
setup({ protocol_min = 2 })
client.register()
check("refused incompatible_protocol", not client.isRegistered() and agent.lastReply.reason == "incompatible_protocol")
check(
  "agent_update_required reported",
  client.agentUpdateRequired() == true and client.displayStatus() == "agent_update_required"
)

print("[5] claim_driver_config: the opt-out leaves EC.SBOS_DRIVER_CONFIG to the driver")
do
  local mine = function() end
  EC.SBOS_DRIVER_CONFIG = mine
  setup({ claim_driver_config = false })
  check("claim_driver_config = false → the driver's own handler stays", EC.SBOS_DRIVER_CONFIG == mine)
  setup()
  check("default → the client takes it (unchanged)", EC.SBOS_DRIVER_CONFIG == client.onConfig)
  EC.SBOS_DRIVER_CONFIG = mine
  setup({ claim_driver_config = true })
  check("claim_driver_config = true → the client takes it", EC.SBOS_DRIVER_CONFIG == client.onConfig)
end

print("[6] onConfig: a superseded (older) document is neither applied nor acknowledged")
do
  local inForce = "11"
  setup({
    onConfig = function(_, version)
      if tonumber(version) < tonumber(inForce) then
        return false, 0, true
      end
      inForce = version
      return true, 0
    end,
    configVersion = function()
      return inForce
    end,
  })
  newAgent(2)
  client.register() -- an Agent to acknowledge to, so a missing ACK means something
  local acks = #frames("SBOS_DRIVER_CONFIG_ACK")
  client.onConfig({ sku = "SBOS_AI_CORE", settings = "{}", settings_version = "10" })
  check("superseded → no SBOS_DRIVER_CONFIG_ACK", #frames("SBOS_DRIVER_CONFIG_ACK") == acks)
  client.onConfig({ sku = "SBOS_AI_CORE", settings = "{}", settings_version = "12" })
  local ack = lastFrame("SBOS_DRIVER_CONFIG_ACK")
  check(
    "a newer one is applied and acknowledged as before",
    #frames("SBOS_DRIVER_CONFIG_ACK") == acks + 1
      and ack.params.applied == "true"
      and ack.params.settings_version == "12"
  )
end

client.stop()
check("stop cancels the client's timers", timers.SbosModuleStatus == nil and timers.SbosModuleTick == nil)
print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
