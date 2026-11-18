-- PIN Lock <-> AI Core verification at bus level: the REAL PIN Lock driver
-- under the shim, the REAL Agent registry (identity binding) and bus
-- (policy) behind a fake SendToDevice, and a fake `ai_core` module that asks
-- pinlock.availability / pinlock.challenge / pinlock.redeem the way brief D5
-- will. The PIN goes only to PIN Lock's relay (POST /verify).
--
--   [1] PIN Lock registers as pin_lock: verified, singleton, the three
--       capabilities; the AI Core and AI Core Approvals properties
--   [2] owner + staff/vendor/guest codes (the dealer's widest grants)
--   [3] availability states
--   [4] the full approval path; [5] single use; [6] guest/vendor/staff
--       refused; [7] approval <-> chat_view never cross; [8] 60 s expiry
--   [9] one lockout shared with the page, both directions
--  [10] the bus refuses redeem from a requester other than ai_core; PIN
--       Lock's own wall refuses a forged or unverified requester
--  [11] the dealer switch; [12] the bounded store over the bus
--  [13] no PIN in any print/log/debug line, property, variable, frame or
--       relay reply (Trace logging and handler debug on; positive control)
--
-- Run from the driver root: make test

local pass, fail = 0, 0
local function check(name, ok, detail)
  if ok then
    pass = pass + 1
    io.write(string.format("  ok   %s\n", name))
  else
    fail = fail + 1
    io.write(string.format("  FAIL %s%s\n", name, detail and ("  -> " .. tostring(detail)) or ""))
  end
end

C4 = C4 or {}
require("c4_shim")
require("drivers-common-public.global.lib")
JSON = require("JSON")

-- ── everything the driver can say goes through here ────────────────────────
local captured = {}
local realPrint = print
local function capture(kind, value)
  captured[#captured + 1] = kind .. ": " .. tostring(value)
end
print = function(...)
  local parts = {}
  for i = 1, select("#", ...) do
    parts[#parts + 1] = tostring((select(i, ...)))
  end
  capture("print", table.concat(parts, "\t"))
end
C4.DebugLog = function(_, message)
  capture("debuglog", message)
end
C4.ErrorLog = function(_, message)
  capture("errorlog", message)
end

-- ── timers and clock ────────────────────────────────────────────────────────
local clock = { now = 0, timers = {} }
package.preload["drivers-common-public.global.timer"] = function()
  ONE_SECOND = 1000
  ONE_MINUTE = 60000
  ONE_HOUR = 3600000
  function SetTimer(id, ms, cb, repeating)
    clock.timers[id] = { at = clock.now + ms, cb = cb, every = repeating and ms or nil }
  end
  function CancelTimer(id)
    clock.timers[id] = nil
  end
  function KillAllTimers()
    clock.timers = {}
  end
  return true
end
local function advance(ms)
  local target = clock.now + ms
  while true do
    local bestId, bestAt
    for id, t in pairs(clock.timers) do
      if t.at <= target and (bestAt == nil or t.at < bestAt or (t.at == bestAt and id < bestId)) then
        bestId, bestAt = id, t.at
      end
    end
    if not bestId then
      break
    end
    clock.now = bestAt
    local t = clock.timers[bestId]
    if t.every then
      t.at = clock.now + t.every
    else
      clock.timers[bestId] = nil
    end
    t.cb()
  end
  clock.now = target
end
local base = os.time({ year = 2027, month = 1, day = 6, hour = 12, min = 0, sec = 0 })
PIN_LOCK_NOW = function()
  return base + clock.now / 1000
end
local realTime = os.time
os.time = function(t)
  if t then
    return realTime(t)
  end
  return base + math.floor(clock.now / 1000)
end
package.preload["drivers-common-public.global.url"] = function()
  return true
end
package.preload["cloud-client-byte"] = function()
  return true
end

local persisted = {}
package.preload["lib.persist"] = function()
  local P = {}
  local EMPTY = {}
  function P:get(key, default)
    if default == nil then
      default = EMPTY
    end
    if persisted[key] == nil then
      return default
    end
    return persisted[key]
  end
  function P:set(key, value)
    persisted[key] = JSON:decode(JSON:encode(value))
  end
  function P:delete(key)
    persisted[key] = nil
  end
  function P:reset() end
  return P
end

-- ── fake Director ───────────────────────────────────────────────────────────
local AGENT, SELF, AICORE, ATMO = 50, 12345, 700, 800
local sent, vars, props, proxySends, serverSent = {}, {}, {}, {}, {}
local c4i = {
  ["smartbuildos-pin-lock.c4z"] = { [SELF] = {} },
  ["smartbuildos-ai-core.c4z"] = { [AICORE] = {} },
  ["smartbuildos-atmosphere.c4z"] = { [ATMO] = {} },
  ["smartbuildos.c4z"] = { [AGENT] = {} },
}
local resolverOff = false
C4.GetDevicesByC4iName = function(_, file)
  return c4i[file]
end
C4.GetDevices = function()
  return {
    [AGENT] = { deviceName = "SmartBuildOS Agent", driverFileName = "smartbuildos.c4z" },
    [SELF] = { deviceName = "PIN Lock", driverFileName = "smartbuildos-pin-lock.c4z" },
    [AICORE] = { deviceName = "AI Core", driverFileName = "smartbuildos-ai-core.c4z" },
  }
end
C4.GetDeviceID = function()
  return SELF
end
C4.GetDriverConfigInfo = function(_, key)
  if key == "minimum_os_version" then
    return "3.3.2"
  elseif key == "model" or key == "name" then
    return "PIN Lock"
  end
  return "20261118.000000"
end
C4.SendToProxy = function(_, binding, command, params)
  proxySends[#proxySends + 1] = { binding = binding, command = command, params = params }
end
C4.FireEventByID = function() end
C4.FireEvent = function() end
C4.SetVariable = function(_, name, value)
  vars[name] = value
end
C4.AddVariable = function() end
C4.AddEvent = function() end
C4.RegisterSystemEvent = function() end
C4.UpdateProperty = function(_, name, value)
  props[name] = value
  Properties[name] = value
end
C4.UpdatePropertyList = function() end
C4.GetVersionInfo = function()
  return { version = "4.2.0.0" }
end
C4.GetControllerNetworkAddress = function()
  return "192.0.2.10"
end
C4.CreateServer = function()
  return true
end
C4.ServerSend = function(_, handle, data)
  serverSent[#serverSent + 1] = { handle = handle, data = data }
end
C4.ServerCloseClient = function() end
C4.DestroyServer = function() end

Properties = {}
do
  local f = assert(io.open("drivers/smartbuildos-pin-lock/driver.xml"))
  local xml = f:read("*a")
  f:close()
  for block in xml:gmatch("<property>(.-)</property>") do
    Properties[block:match("<name>(.-)</name>")] = block:match("<default>(.-)</default>") or ""
  end
end
Properties["Guarded 1 Name"] = "Unlock wine cellar"
Properties["Guarded 2 Name"] = "Open garage service door"
Properties["Guarded 3 Name"] = "Disable alarm zone"
Properties["Max Wrong Attempts"] = "5"
Properties["Lockout Minutes"] = "5"
Properties["Log Level"] = "5 - Trace"
Properties["Log Mode"] = "Print and Log"

require("lib.relayhost").get = function(_, done)
  done(true, '{"ok":true,"service":"pin-lock"}')
end

-- ── the Agent: real registry + bus; a fake AI Core and a fake Atmosphere ────
local Modules = require("sbos.modules")
local ModuleBus = require("sbos.modulebus")
local agent = { n = 0 }
local busTimers = {}
local mods = {
  ai = { id = AICORE, module_id = "ai_core", responses = {}, received = {} },
  atmo = { id = ATMO, module_id = "atmosphere", responses = {}, received = {} },
}
local byDevice = { [tostring(AICORE)] = mods.ai, [tostring(ATMO)] = mods.atmo }

local function moduleReceive(m, command, params)
  if command == "SBOS_MODULE_REQUEST" then
    m.received[#m.received + 1] = params
    -- AI Core answers PIN Lock's ai_core.report like D4 will (accepted).
    agent.bus:response(m.entry, {
      request_id = params.request_id,
      status = "ok",
      error_code = "ok",
      result = JSON:encode({ accepted = true, ai_core = { state = "ready", version = "20261118.2" } }),
      cursor = "",
    })
  elseif command == "SBOS_MODULE_RESPONSE" then
    m.responses[#m.responses + 1] = params
  end
end

agent.registry = Modules.Registry.new({
  now = os.time,
  newToken = function()
    agent.n = agent.n + 1
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
    local m = byDevice[tostring(id)]
    if m then
      moduleReceive(m, command, params)
    elseif tostring(id) == tostring(SELF) then
      ExecuteCommand(command, params) -- Director's dispatcher: handler debug applies
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
-- The Agent's own token buckets are covered by test_sbos_modulebus; this
-- file runs dozens of requests in a few simulated seconds, so they are open.
agent.bus.allow = function()
  return true
end
local function pushDirectory()
  local fn = busTimers[ModuleBus.DIRECTORY_TIMER]
  busTimers[ModuleBus.DIRECTORY_TIMER] = nil
  if fn then
    fn()
  end
end

local function registerModule(m, caps)
  local ok, reply, entry = agent.registry:register({
    module_id = m.module_id,
    instance_id = tostring(m.id),
    requester = tostring(m.id),
    driver_version = "20261118.2",
    protocol_min = "1",
    protocol_max = "2",
    singleton = "true",
    status = "ready",
    manifest = JSON:encode({
      driver = "sbos." .. m.module_id,
      version = "20261118.2",
      protocol = 2,
      capabilities = caps,
    }),
  })
  if ok then
    m.entry = entry
    agent.bus:onRegistered(entry)
  end
  return ok, reply, entry
end

local METHODS = {
  SBOS_MODULE_DISCOVER = "discover",
  SBOS_MODULE_REQUEST = "request",
  SBOS_MODULE_RESPONSE = "response",
  SBOS_MODULE_SUBSCRIBE = "subscribe",
}
C4.SendToDevice = function(_, device, command, params)
  local copy = {}
  for k, v in pairs(params or {}) do
    copy[k] = v
  end
  sent[#sent + 1] = { device = device, command = command, params = copy }
  if device ~= AGENT then
    return
  end
  if command == "SBOS_MODULE_REGISTER" then
    local ok, reply, entry = agent.registry:register(params)
    reply.agent_protocol_min = "1"
    reply.agent_protocol_max = "2"
    reply.paired = "true"
    reply.connected = "true"
    if ok then
      agent.bus:onRegistered(entry)
    end
    agent.lastReply = reply
    ExecuteCommand("SBOS_MODULE_REGISTERED", reply)
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
  elseif METHODS[command] then
    local entry = agent.registry:authenticate(params)
    if entry then
      agent.bus[METHODS[command]](agent.bus, entry, params)
    end
  end
end

--- A module asks pin_lock through the REAL bus (routing + policy).
local nreq = 0
local function ask(m, capability, args)
  nreq = nreq + 1
  local before = #m.responses
  local ackRefused
  local realSend = agent.bus.sendTo
  agent.bus.sendTo = function(bus, entry, command, params)
    if command == "SBOS_MODULE_REQUEST_ACK" and entry == m.entry and params.state == "Refused" then
      ackRefused = params.error_code
    end
    return realSend(bus, entry, command, params)
  end
  agent.bus:request(m.entry, {
    module_id = m.module_id,
    instance_id = tostring(m.id),
    token = m.entry.token,
    request_id = "r" .. nreq,
    idempotency_key = "i" .. nreq,
    to = "pin_lock",
    capability = capability,
    args = JSON:encode(args or {}),
    deadline = tostring(os.time() + 30),
  })
  agent.bus.sendTo = realSend
  local r = m.responses[before + 1]
  if r == nil then
    return { refused = ackRefused or "no_answer" }
  end
  local okR, result = pcall(function()
    return JSON:decode(r.result)
  end)
  return { status = r.status, error_code = r.error_code, result = okR and result or nil, raw = r.result }
end

-- ── the relay (OnServerDataIn), as the AI Core page and PIN Lock's page use it
local handleSeq = 100
local function http(method, pathAndQuery, bodyTable)
  local body = bodyTable and JSON:encode(bodyTable) or ""
  handleSeq = handleSeq + 1
  local before = #serverSent
  local req = method .. " " .. pathAndQuery .. " HTTP/1.1\r\nHost: x\r\nContent-Length: " .. #body .. "\r\n\r\n" .. body
  OnServerDataIn(handleSeq, req, nil, nil, "pinlock-ui-relay")
  if #serverSent == before then
    return nil, nil, nil
  end
  local raw = serverSent[#serverSent].data
  local status = raw:match("^HTTP/1%.1 (%d+)")
  local payload = raw:match("\r\n\r\n(.*)$") or ""
  local ok, decoded = pcall(function()
    return JSON:decode(payload)
  end)
  return tonumber(status), ok and decoded or payload, payload
end

-- Test values. Eight digits, not four: the leak scans below search the whole
-- persisted store and every frame, which also hold salts, digests and
-- challenge ids in hex. The shim's fake C4:HMAC repeats one 8-hex word eight
-- times, and PIN Lock seeds math.random from os.clock (so salts differ run to
-- run): a 4-digit PIN turned up inside another code's digest about one run in
-- thirty. An 8-digit decimal needle cannot plausibly occur in that hex, and
-- math.random is pinned below so the run is the same every time.
local OWNER_PIN, OWNER2_PIN, STAFF_PIN, VENDOR_PIN, GUEST_PIN =
  "73915826", "61583947", "48261937", "51836429", "62907318"
local WRONG = { "30471865", "82651904", "91527360", "27394185", "46183072", "59273618" }
local PROPOSAL = "3f2b8c1e-5d4a-4e8b-9c7d-1a2b3c4d5e6f"
local SESSION = string.rep("ab", 16)
local nonceSeq = 0
local function nonce()
  nonceSeq = nonceSeq + 1
  return string.format("%032x", 0xa0000 + nonceSeq)
end
local function prop(name)
  return props[name] or Properties[name]
end

--- AI Core's side of one verification (D5's job; faked here).
local function challenge(purpose, subject)
  local n = nonce()
  local r = ask(mods.ai, "pinlock.challenge", { purpose = purpose, subject = subject, nonce = n })
  return r, { purpose = purpose, subject = subject, nonce = n }
end
local function redeem(id, bound, over)
  local args = { challenge_id = id, nonce = bound.nonce, purpose = bound.purpose, subject = bound.subject }
  for k, v in pairs(over or {}) do
    args[k] = v
  end
  return ask(mods.ai, "pinlock.redeem", args)
end
local function verify(id, pin)
  return http("POST", "/verify", { challenge_id = id, pin = pin })
end

-- ════════════════════════════════════════════════════════════════════════════
io.write("[1] PIN Lock joins the bus as pin_lock\n")
registerModule(mods.ai, { { id = "ai_core.report", version = 1, kind = "request" } })
-- PIN Lock seeds math.random from the clock at late init; pin it so salts,
-- digests and challenge ids are the same on every run (see the PINs above).
local realRandomseed = math.randomseed
math.randomseed = function()
  realRandomseed(20261118)
end
dofile("drivers/smartbuildos-pin-lock/driver.lua")
OnDriverInit()
OnPropertyChanged("Log Level") -- Trace: handler debug on
OnDriverLateInit("DIT_ADDING")
EC.SBOS_ENTITLEMENT({ sku = "SBOS_PIN_LOCK", status = "AUTHORIZED_SUBSCRIPTION", registered = "true" })
local pinEntry = agent.registry:find("pin_lock", tostring(SELF))
check("registered as pin_lock", pinEntry ~= nil)
check("...verified by the Agent's identity binding", pinEntry and pinEntry.verified == true)
check("...singleton", pinEntry and (pinEntry.singleton == true or pinEntry.singleton == "true"))
local capIds = {}
for _, c in ipairs(pinEntry and pinEntry.manifest and pinEntry.manifest.capabilities or {}) do
  capIds[#capIds + 1] = c.id .. "@" .. tostring(c.version)
end
table.sort(capIds)
check(
  "manifest advertises the three capabilities, v1",
  table.concat(capIds, ",") == "pinlock.availability@1,pinlock.challenge@1,pinlock.redeem@1",
  table.concat(capIds, ",")
)
check("the AI Core property is painted by the helper", prop("AI Core"):find("^Found") ~= nil, prop("AI Core"))
check(
  "AI Core Approvals says no owner PIN yet",
  prop("AI Core Approvals") == "Unavailable — no active owner code with a PIN",
  prop("AI Core Approvals")
)
local url
for _, p in ipairs(proxySends) do
  if p.command == "URL_CHANGED" then
    url = p.params.url
  end
end
local TOKEN = url and url:match("k=(%w+)$")
check("page token known", TOKEN ~= nil, url)

local r = ask(mods.ai, "pinlock.availability", {})
check(
  "availability before an owner exists: ready=false, no_owner_pin",
  r.status == "ok" and r.result.ready == false and r.result.reason == "no_owner_pin",
  r.raw
)
r = challenge("approval", PROPOSAL)
check(
  "challenge refused while not ready: unsupported",
  r.error_code == "unsupported" and r.result.reason == "no_owner_pin",
  r.raw
)

io.write("[2] codes: one owner, and staff/vendor/guest with every guarded action\n")
local st, doc = http("POST", "/admin/setup?k=" .. TOKEN, { name = "Owner Marta", pin = OWNER_PIN })
check("owner created", st == 200 and doc.ok == true)
local ADMIN = doc.session
for _, c in ipairs({
  { "Owner Two", "owner", OWNER2_PIN },
  { "Staff Sam", "staff", STAFF_PIN },
  { "Vendor Vic", "vendor", VENDOR_PIN },
  { "Guest Gia", "guest", GUEST_PIN },
}) do
  st, doc = http("POST", "/admin/save?k=" .. TOKEN, {
    session = ADMIN,
    name = c[1],
    role = c[2],
    pin = c[3],
    actions = { 1, 2, 3 },
    days = {},
    from = "",
    to = "",
    start_date = "",
    expiry_date = "",
    max_uses = "",
  })
  check(c[1] .. " saved", st == 200 and doc.ok == true, JSON:encode(doc))
end
st = http("POST", "/unlock?k=" .. TOKEN, { action = 3, pin = GUEST_PIN })
check("the guest code really may fire guarded actions on the page", st == 200)

io.write("[3] availability\n")
r = ask(mods.ai, "pinlock.availability", {})
check(
  "ready once an owner PIN exists",
  r.status == "ok" and r.result.ready == true and r.result.reason == "ready",
  r.raw
)
check(
  "AI Core Approvals says On, owner PINs only",
  prop("AI Core Approvals"):find("^On — owner PINs only") ~= nil,
  prop("AI Core Approvals")
)
r = ask(mods.ai, "pinlock.availability", { extra = 1 })
check("availability with args → invalid_args", r.error_code == "invalid_args")

io.write("[4] the approval path: challenge, /verify, redeem\n")
local c, bound = challenge("approval", PROPOSAL)
check(
  "challenge: 32-hex id, 60 s, PIN Lock's own /verify",
  c.status == "ok"
    and c.result.challenge_id:match("^[0-9a-f]+$")
    and #c.result.challenge_id == 32
    and c.result.expires_in == 60
    and c.result.verify_url == "http://192.0.2.10:47831/verify",
  c.raw
)
local vst, _, vraw = verify(c.result.challenge_id, OWNER_PIN)
check('/verify with the owner PIN, no page token → 200 {"ok":true}', vst == 200 and vraw == '{"ok":true}', vraw)
r = redeem(c.result.challenge_id, bound)
check(
  "redeem → verified, role owner, slot, verified_at; nothing else",
  r.status == "ok"
    and r.result.verified == true
    and r.result.role == "owner"
    and r.result.slot == 1
    and type(r.result.verified_at) == "string"
    and r.raw:find("Marta", 1, true) == nil,
  r.raw
)
local n = 0
for _ in pairs(r.result) do
  n = n + 1
end
check("redeem answer has exactly 4 keys", n == 4, r.raw)
c, bound = challenge("chat_view", SESSION)
verify(c.result.challenge_id, OWNER2_PIN)
r = redeem(c.result.challenge_id, bound)
check("a second owner code verifies a chat unlock (slot 2)", r.result.verified == true and r.result.slot == 2, r.raw)

io.write("[5] single use\n")
r = redeem(c.result.challenge_id, bound)
check(
  "redeeming the same challenge again → unknown",
  r.result.verified == false and r.result.reason == "unknown",
  r.raw
)
c, bound = challenge("approval", PROPOSAL)
r = redeem(c.result.challenge_id, bound)
check("redeem before any /verify → not_verified", r.result.reason == "not_verified")
vst, _, vraw = verify(c.result.challenge_id, OWNER_PIN)
check("...and the consumed challenge cannot be verified afterwards", vst == 401 and vraw == '{"ok":false}', vraw)
c, bound = challenge("approval", PROPOSAL)
verify(c.result.challenge_id, OWNER_PIN)
vst, _, vraw = verify(c.result.challenge_id, OWNER_PIN)
check('one /verify per challenge: a second post → {"ok":false}', vst == 401 and vraw == '{"ok":false}')
check("...but the first verification stands", redeem(c.result.challenge_id, bound).result.verified == true)

io.write("[6] guest, vendor and staff PINs are refused (owner-role only)\n")
for _, case in ipairs({ { "guest", GUEST_PIN }, { "vendor", VENDOR_PIN }, { "staff", STAFF_PIN } }) do
  c, bound = challenge("approval", PROPOSAL)
  vst, _, vraw = verify(c.result.challenge_id, case[2])
  check(case[1] .. ' PIN → /verify {"ok":false} exactly', vst == 401 and vraw == '{"ok":false}', vraw)
  r = redeem(c.result.challenge_id, bound)
  check(case[1] .. " PIN → redeem not_verified", r.result.verified == false and r.result.reason == "not_verified")
end
-- Those were three failures in the page bucket; clear them for what follows.
EC.CLEAR_LOCKOUTS()

io.write("[7] an approval grant is never a chat unlock, and the reverse\n")
c, bound = challenge("approval", PROPOSAL)
verify(c.result.challenge_id, OWNER_PIN)
r = redeem(c.result.challenge_id, bound, { purpose = "chat_view", subject = SESSION })
check(
  "approval grant redeemed as chat_view → wrong_subject",
  r.result.verified == false and r.result.reason == "wrong_subject"
)
check("...and it is gone", redeem(c.result.challenge_id, bound).result.reason == "unknown")
c, bound = challenge("chat_view", SESSION)
verify(c.result.challenge_id, OWNER_PIN)
r = redeem(c.result.challenge_id, bound, { purpose = "approval", subject = PROPOSAL })
check("chat grant redeemed as an approval → wrong_subject", r.result.reason == "wrong_subject")
c, bound = challenge("approval", PROPOSAL)
verify(c.result.challenge_id, OWNER_PIN)
r = redeem(c.result.challenge_id, bound, { subject = "9a8b7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d" })
check("approval grant redeemed for another proposal → wrong_subject", r.result.reason == "wrong_subject")
c, bound = challenge("approval", PROPOSAL)
verify(c.result.challenge_id, OWNER_PIN)
r = redeem(c.result.challenge_id, bound, { nonce = string.rep("9e", 16) })
check("wrong nonce → wrong_subject", r.result.reason == "wrong_subject")
r = ask(mods.ai, "pinlock.challenge", { purpose = "settings", subject = PROPOSAL, nonce = nonce() })
check("an unknown purpose → invalid_args", r.error_code == "invalid_args")

io.write("[8] 60 s expiry\n")
c, bound = challenge("approval", PROPOSAL)
advance(61 * 1000)
vst, _, vraw = verify(c.result.challenge_id, OWNER_PIN)
check('/verify after 61 s → {"ok":false}', vst == 401 and vraw == '{"ok":false}')
check("redeem after 61 s → expired", redeem(c.result.challenge_id, bound).result.reason == "expired")
c, bound = challenge("approval", PROPOSAL)
advance(30 * 1000)
verify(c.result.challenge_id, OWNER_PIN)
advance(31 * 1000)
check("verified at 30 s, redeemed at 61 s → expired", redeem(c.result.challenge_id, bound).result.reason == "expired")

io.write("[9] one lockout: AI attempts lock the page, page attempts lock AI\n")
for i = 1, 4 do
  c = challenge("approval", PROPOSAL)
  verify(c.result.challenge_id, WRONG[i])
end
c, bound = challenge("approval", PROPOSAL)
vst, doc, vraw = verify(c.result.challenge_id, WRONG[5])
check(
  "5th wrong AI PIN → 429 {ok:false, locked, retry_in}",
  vst == 429 and doc.locked == true and doc.retry_in == 300 and vraw:find("Marta", 1, true) == nil,
  vraw
)
check("redeem → locked", redeem(c.result.challenge_id, bound).result.reason == "locked")
st, doc = http("POST", "/unlock?k=" .. TOKEN, { action = 1, pin = OWNER_PIN })
check("the page is now locked out too (even the owner PIN)", st == 429 and doc.locked == true)
check("Entry Points shows the page locked", prop("Entry Points"):find("page LOCKED") ~= nil, prop("Entry Points"))
r = ask(mods.ai, "pinlock.availability", {})
check(
  "availability: ready=false, locked, retry_in",
  r.result.ready == false and r.result.reason == "locked" and (r.result.retry_in or 0) > 0,
  r.raw
)
check("challenge while locked → unsupported/locked", challenge("approval", PROPOSAL).result.reason == "locked")
check("AI Core Approvals says paused", prop("AI Core Approvals"):find("^Paused") ~= nil, prop("AI Core Approvals"))
advance(301 * 1000)
check("after the lockout: ready again", ask(mods.ai, "pinlock.availability", {}).result.ready == true)
for i = 1, 5 do
  http("POST", "/unlock?k=" .. TOKEN, { action = 1, pin = WRONG[i] })
end
r = ask(mods.ai, "pinlock.availability", {})
check("5 wrong page PINs → AI verification locked", r.result.ready == false and r.result.reason == "locked", r.raw)
EC.CLEAR_LOCKOUTS()

io.write("[10] who may ask\n")
registerModule(mods.atmo, { { id = "pinlock.redeem", version = 1, kind = "request" } })
local servedBefore = #sent
for _, cap in ipairs({ "pinlock.availability", "pinlock.challenge", "pinlock.redeem" }) do
  r = ask(mods.atmo, cap, {})
  check(
    "the bus refuses " .. cap .. " from atmosphere (not_permitted)",
    r.refused == "not_permitted",
    r.refused or r.raw
  )
end
local reachedPinLock = false
for i = servedBefore + 1, #sent do
  if sent[i].command == "SBOS_MODULE_RESPONSE" then
    reachedPinLock = true
  end
end
check("...and PIN Lock never answered (nothing reached it)", not reachedPinLock)
-- A frame that reached PIN Lock claiming another module (the bus would never
-- forward it; PIN Lock's own wall refuses it anyway).
local forged = {
  module_id = "pin_lock",
  instance_id = tostring(SELF),
  token = pinEntry.token,
  request_id = "forged1",
  from_module_id = "atmosphere",
  from_instance_id = tostring(ATMO),
  capability = "pinlock.redeem",
  args = JSON:encode({ challenge_id = string.rep("0", 32), nonce = nonce(), purpose = "approval", subject = PROPOSAL }),
  deadline = tostring(os.time() + 30),
}
ExecuteCommand("SBOS_MODULE_REQUEST", forged)
local forgedAnswer
for i = #sent, 1, -1 do
  if sent[i].command == "SBOS_MODULE_RESPONSE" and sent[i].params.request_id == "forged1" then
    forgedAnswer = sent[i].params
    break
  end
end
check(
  "a forged non-ai_core requester at PIN Lock → not_permitted",
  forgedAnswer ~= nil and forgedAnswer.status == "error" and forgedAnswer.error_code == "not_permitted"
)
-- A colliding request_id: PIN Lock stored a "verified" redeem answer for
-- ai_core under request_id rN. A frame from another sender under the SAME
-- request_id must reach the requester check, never the stored answer.
c, bound = challenge("approval", PROPOSAL)
verify(c.result.challenge_id, OWNER_PIN)
r = redeem(c.result.challenge_id, bound)
local redeemId = "r" .. nreq
check("(ai_core's redeem verified under " .. redeemId .. ")", r.result and r.result.verified == true, r.raw)
local function replayAs(fromModule, fromInstance)
  local frame = {}
  for k, v in pairs(forged) do
    frame[k] = v
  end
  frame.request_id = redeemId
  frame.from_module_id = fromModule
  frame.from_instance_id = fromInstance
  frame.args = JSON:encode({
    challenge_id = c.result.challenge_id,
    nonce = bound.nonce,
    purpose = bound.purpose,
    subject = bound.subject,
  })
  local mark = #sent
  ExecuteCommand("SBOS_MODULE_REQUEST", frame)
  for i = #sent, mark + 1, -1 do
    if sent[i].command == "SBOS_MODULE_RESPONSE" and sent[i].params.request_id == redeemId then
      return sent[i].params
    end
  end
end
for _, who in ipairs({ { "atmosphere", tostring(ATMO) }, { "ai_core", "999" } }) do
  local a = replayAs(who[1], who[2])
  check(
    "replayed redeem id from " .. who[1] .. "@" .. who[2] .. " → not_permitted, not the stored answer",
    a ~= nil
      and a.status == "error"
      and a.error_code == "not_permitted"
      and tostring(a.result):find("verified", 1, true) == nil,
    a and JSON:encode(a)
  )
end
-- An ai_core the Agent could not verify (Director gave no answer).
resolverOff = true
agent.registry:remove("ai_core", tostring(AICORE))
agent.bus:onRemoved(mods.ai.entry)
registerModule(mods.ai, { { id = "ai_core.report", version = 1, kind = "request" } })
resolverOff = false
check("ai_core re-registered unverified", mods.ai.entry.verified == false)
pushDirectory()
r = ask(mods.ai, "pinlock.availability", {})
check("an unverified ai_core is refused by PIN Lock (not_permitted)", r.error_code == "not_permitted", r.raw)
agent.registry:remove("ai_core", tostring(AICORE))
agent.bus:onRemoved(mods.ai.entry)
registerModule(mods.ai, { { id = "ai_core.report", version = 1, kind = "request" } })
pushDirectory()
check("verified again → served", ask(mods.ai, "pinlock.availability", {}).result.ready == true)

io.write("[11] the dealer switch at PIN Lock\n")
c, bound = challenge("approval", PROPOSAL)
Properties["AI Core PIN Verification"] = "Off"
OnPropertyChanged("AI Core PIN Verification")
r = ask(mods.ai, "pinlock.availability", {})
check("Off → ready=false, off", r.result.ready == false and r.result.reason == "off", r.raw)
check("Off → challenge unsupported", challenge("approval", PROPOSAL).error_code == "unsupported")
vst, _, vraw = verify(c.result.challenge_id, OWNER_PIN)
check("a challenge opened before Off cannot be verified", vst == 401 and vraw == '{"ok":false}')
check("...and redeems unknown (cleared)", redeem(c.result.challenge_id, bound).result.reason == "unknown")
check("AI Core Approvals says Off", prop("AI Core Approvals"):find("^Off") ~= nil, prop("AI Core Approvals"))
Properties["AI Core PIN Verification"] = "On when an owner PIN exists"
OnPropertyChanged("AI Core PIN Verification")
check("On again → ready", ask(mods.ai, "pinlock.availability", {}).result.ready == true)

io.write("[12] the store is bounded: the 9th open challenge is refused\n")
local ids = {}
for i = 1, 8 do
  ids[i] = challenge("approval", PROPOSAL)
end
r = challenge("approval", PROPOSAL)
check(
  "9th challenge → rate_limited (busy); none evicted",
  r.error_code == "rate_limited" and r.result.reason == "busy",
  r.raw
)
vst = verify(ids[1].result.challenge_id, OWNER_PIN)
check("the first of the eight still verifies", vst == 200)
advance(61 * 1000)
check("after they expire, a new one is issued", challenge("approval", PROPOSAL).status == "ok")

io.write("[13] the PIN appears nowhere\n")
-- Positive control: the capture really records handler debug at Trace, and
-- would have seen a PIN had anything printed one.
local mark = #captured
ExecuteCommand("REFRESH_STATUS", { PROBE = "probe-" .. OWNER_PIN })
local controlSeen = false
for i = mark + 1, #captured do
  if captured[i]:find("probe-" .. OWNER_PIN, 1, true) then
    controlSeen = true
  end
end
check("positive control: a param printed by handler debug is captured", controlSeen)
for i = #captured, mark + 1, -1 do
  table.remove(captured, i) -- the probe itself is not the driver's output
end

local secrets = { OWNER_PIN, OWNER2_PIN, STAFF_PIN, VENDOR_PIN, GUEST_PIN }
for _, w in ipairs(WRONG) do
  secrets[#secrets + 1] = w
end
local function hitsIn(text, needles)
  local hits = {}
  for _, needle in ipairs(needles) do
    if text:find(needle, 1, true) then
      hits[#hits + 1] = needle:sub(1, 1) .. "..."
    end
  end
  return hits
end
local function scan(label, text, needles)
  local hits = hitsIn(text, needles)
  check(label, #hits == 0, table.concat(hits, ","))
end
local logText = table.concat(captured, "\n")
check(
  "logging was captured (Trace + handler debug), AI Core lines among it",
  #captured > 20 and logText:find("AI Core verification", 1, true) ~= nil
)
scan("no PIN in any print / log / debug line", logText, secrets)
local propText = {}
for k, v in pairs(props) do
  propText[#propText + 1] = k .. "=" .. tostring(v)
end
scan("no PIN in any property", table.concat(propText, "\n"), secrets)
local varText = {}
for k, v in pairs(vars) do
  varText[#varText + 1] = k .. "=" .. tostring(v)
end
scan("no PIN in any variable", table.concat(varText, "\n"), secrets)
local frames, toAi = {}, {}
for _, s in ipairs(sent) do
  frames[#frames + 1] = s.command .. JSON:encode(s.params or {})
  if s.command == "SBOS_MODULE_RESPONSE" then
    toAi[#toAi + 1] = JSON:encode(s.params or {})
  end
end
scan("no PIN in any frame PIN Lock sent (Agent, AI Core, recorder)", table.concat(frames, "\n"), secrets)
scan(
  "no code name in any bus answer PIN Lock sent",
  table.concat(toAi, "\n"),
  { "Marta", "Owner Two", "Staff Sam", "Vendor Vic", "Guest Gia" }
)
local replies = {}
for _, s in ipairs(serverSent) do
  if s.data:find('"ok":', 1, true) then
    replies[#replies + 1] = s.data
  end
end
scan("no PIN echoed in any relay reply", table.concat(replies, "\n"), secrets)
local storeText = JSON:encode(persisted)
check(
  "the persisted store holds the codes (salted digests), so the scan reads real data",
  storeText:find("Owner Two", 1, true) ~= nil and storeText:find('"hash":"', 1, true) ~= nil
)
scan("no plaintext PIN in the persisted store", storeText, secrets)
-- Positive control: the same scan over a copy of the store with one code's
-- digest replaced by its plaintext PIN (what a real leak would look like).
local leaked = storeText:gsub('"hash":"[0-9a-f]+"', '"hash":"' .. OWNER_PIN .. '"', 1)
check("positive control: a plaintext PIN in the store is caught", #hitsIn(leaked, secrets) == 1)

print = realPrint
print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
