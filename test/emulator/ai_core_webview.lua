-- The AI Core touchscreen page under the Director emulator (EMULATOR ONLY —
-- not a bench result; no physical controller and no Navigator has run any
-- of this): the REAL Agent, the REAL PIN Lock and the REAL AI Core, their
-- module-bus frames through the emulator's asynchronous SendToDevice path,
-- the page's HTTP requests through the emulator's server sockets (AI Core's
-- relay on 47871, PIN Lock's on 47831), and a scripted cloud
-- (/modules/rpc answered here, deliver_result pushed as a MODULE_COMMAND).
--
--   [1] PIN Lock and AI Core find each other (verified on the bus)
--   [2] unlock the chat with an owner PIN, ask, receive, auto-lock
--   [3] a guest PIN is refused
--   [4] the lockout is PIN Lock's own (shared with its page)
--   [5] review and approve one item end to end; decline one
--   [6] the cloud refuses an above-ceiling item: plain words
--  [6b] the dealer's preset questions: a config with two arrives; locked,
--       none; unlocked, the three built-ins plus the two; asking one sends
--       its exact text
--   [7] the PIN never reached AI Core, the bus or the cloud
-- Run: test/emulator/run-ai-core.sh (exit 1 on any failure).

local EMU = assert(os.getenv("DIRECTOR_EMULATOR"), "DIRECTOR_EMULATOR not set (use the run script)")
local OUT = assert(os.getenv("SBOS_AI_OUT"), "SBOS_AI_OUT not set (use the run script)")
package.path = EMU .. "/examples/connector/?.lua;" .. package.path
local Cloud = require("fake_cloud")

local passed, failed = 0, 0
local function check(label, ok, detail)
  if ok then
    passed = passed + 1
    print("  CHECK ok    " .. label)
  else
    failed = failed + 1
    print("  CHECK FAIL  " .. label .. (detail ~= nil and ("  -> " .. tostring(detail)) or ""))
  end
end

local OWNER_PIN = "73914562"
local GUEST_PIN = "86027315"
local REF_A = "11111111-2222-4333-8444-555555555555"
local REF_B = "66666666-7777-4888-9999-aaaaaaaaaaaa"
local REF_C = "bbbbbbbb-cccc-4ddd-8eee-ffffffffffff"
local HASH = { [REF_A] = string.rep("ab", 32), [REF_B] = string.rep("cd", 32), [REF_C] = string.rep("ef", 32) }

local d = Director.new({ cacheDir = os.getenv("DIRECTOR_CACHE") .. "-webview" })
local cloud = Cloud.new(d):install()
cloud.catalog.SBOS_AI_CORE = {
  status = "AUTHORIZED_SUBSCRIPTION",
  license_type = "SUBSCRIPTION_INCLUDED",
  features = { "BASE", "AI_LEARNING", "AI_ACTIONS" },
}
cloud.catalog.SBOS_PIN_LOCK =
  { status = "AUTHORIZED_SUBSCRIPTION", license_type = "SUBSCRIPTION_INCLUDED", features = { "BASE" } }

-- ── the scripted cloud ───────────────────────────────────────────────────────
local rpc = {}
local pending = { commands = {}, driver_config = nil }
local refuseDetail = {} -- ref -> reason
d.http = function(req, dev)
  local url = tostring(req.url)
  local path = url:match("^https?://[^/]+(/[^?]*)")
  if url:find(":47871/ping", 1, true) then
    return { code = 200, headers = {}, body = '{"ok":true,"service":"ai-core"}' }
  elseif url:find(":47831/ping", 1, true) then
    return { code = 200, headers = {}, body = '{"ok":true,"service":"pin-lock"}' }
  end
  if path == "/api/integrations/control4/modules/rpc" then
    local body = type(req.body) == "string" and json.decode(req.body) or req.body
    rpc[#rpc + 1] = {
      op = body.op,
      body = body.body,
      -- The frame around the body, as the Agent relays it: its request_id is
      -- the module client's per-attempt id, NOT the body's request_id.
      frame_request_id = body.request_id,
      idempotency_key = body.idempotency_key,
      job_id = body.op == "ask" and ("job-" .. (#rpc + 1)) or nil,
      raw = type(req.body) == "string" and req.body or json.encode(req.body),
    }
    local b = body.body or {}
    local result = { accepted = true }
    local okAnswer = true
    if body.op == "ask" then
      result = { accepted = true, job_id = "job-" .. #rpc }
    elseif body.op == "approvals_pending" then
      local now = math.floor(d.clock:now() / 1000)
      result = {
        enabled = true,
        count = 4,
        eligible = {
          { ref = REF_A, expires_at = now + 3600 },
          { ref = REF_B, expires_at = now + 3600 },
          { ref = REF_C, expires_at = now + 3600 },
        },
        portal_only_count = 1,
        checked_at = now,
      }
    elseif body.op == "approval_detail" then
      if refuseDetail[b.ref] then
        okAnswer = false
        result = { reason = refuseDetail[b.ref] }
      else
        result = {
          ref = b.ref,
          title = b.ref == REF_A and "Turn off the patio lights" or "Lower the den shades",
          description = "Proposed by SmartBuildOS AI.",
          risk = "low",
          expires_at = math.floor(d.clock:now() / 1000) + 3600,
          args_hash = HASH[b.ref],
        }
      end
    elseif body.op == "approval_decide" then
      result = { ref = b.ref, status = b.decision == "approve" and "queued" or "denied" }
    end
    return {
      code = 200,
      headers = { ["Content-Type"] = "application/json" },
      body = okAnswer and json.encode({ ok = true, result = result })
        or json.encode({ ok = false, error_code = "not_permitted", result = result }),
    }
  end
  local resp = cloud:handle(req, dev)
  if
    resp
    and resp.code == 200
    and path == "/api/integrations/control4/heartbeat"
    and (#pending.commands > 0 or pending.driver_config ~= nil)
  then
    local hb = json.decode(resp.body)
    if #pending.commands > 0 then
      hb.commands = pending.commands
      pending.commands = {}
    end
    if pending.driver_config ~= nil then
      hb.driver_config = pending.driver_config
      pending.driver_config = nil
    end
    resp.body = json.encode(hb)
  end
  return resp
end
local function ops(op)
  local out = {}
  for _, c in ipairs(rpc) do
    if c.op == op then
      out[#out + 1] = c
    end
  end
  return out
end
local function lastOp(op)
  local l = ops(op)
  return l[#l]
end

-- ── the project ──────────────────────────────────────────────────────────────
local room = d:addRoom("Equipment")
local agent = assert(d:addDevice(OUT .. "/smartbuildos", { roomId = room, name = "SmartBuildOS" }))
d:setProperty(agent, "Automatic Updates", "Off")
d:advance(1000)
d:setProperty(agent, "Pairing Code", "ABCD-2345")
d:advance(5000)
local pl = assert(d:addDevice(OUT .. "/webview/smartbuildos-pin-lock", { roomId = room, name = "PIN Lock" }))
local aic = assert(d:addDevice(OUT .. "/webview/smartbuildos-ai-core", { roomId = room, name = "AI Core" }))
d:advance(90000)

-- Every frame AI Core sends, for the PIN scan in [7].
local aiFrames = {}
local realSend = d.sendToDevice
d.sendToDevice = function(self, from, id, command, params)
  if from ~= nil and from.id == aic.id then
    aiFrames[#aiFrames + 1] = command .. " " .. json.encode(params or {})
  end
  return realSend(self, from, id, command, params)
end

local cmdSeq = 0
local function moduleCommand(command, args)
  cmdSeq = cmdSeq + 1
  local requestId = "emu-web-" .. cmdSeq
  pending.commands[#pending.commands + 1] = {
    id = "cmd-web-" .. cmdSeq,
    command = "MODULE_COMMAND",
    payload = { module_id = "ai_core", command = command, request_id = requestId, args = args or {} },
  }
  d:executeCommand(agent, "SEND_HEARTBEAT", {})
  d:advance(3000)
end

local function proxyUrl(dev)
  for _, p in ipairs(d:partners(dev.id, 5001)) do
    local proxy = d.devices[p.deviceId]
    if proxy and proxy.notifies then
      for i = #proxy.notifies, 1, -1 do
        local n = proxy.notifies[i]
        if n.command == "URL_CHANGED" then
          return n.params.url
        end
      end
    end
  end
end

--- One HTTP request to a driver's relay through the emulator's server
--- sockets. Returns status, decoded JSON (or nil), raw body.
local replies = {}
local function http(dev, port, method, target, body)
  local raw = type(body) == "table" and json.encode(body) or body or ""
  local got = ""
  local link = assert(d:connectToServer(dev, port, {
    onData = function(_, data)
      got = got .. data
    end,
  }))
  link:send(
    method .. " " .. target .. " HTTP/1.1\r\nHost: 192.168.1.2\r\nContent-Length: " .. #raw .. "\r\n\r\n" .. raw
  )
  d:advance(200)
  replies[#replies + 1] = got
  local code = tonumber(got:match("^HTTP/1%.1 (%d+)"))
  local payload = got:match("\r\n\r\n(.*)$") or ""
  local ok, doc = pcall(json.decode, payload)
  return code, ok and type(doc) == "table" and doc or nil, payload
end

print("[1] PIN Lock and AI Core find each other")
local aiUrl, plUrl = proxyUrl(aic), proxyUrl(pl)
check(
  "AI Core published its page (relay, install token)",
  aiUrl and aiUrl:find("^http://192%.168%.1%.2:47871/app%?k=%x+$") ~= nil,
  aiUrl
)
check("PIN Lock published its page", plUrl and plUrl:find(":47831/app%?k=") ~= nil, plUrl)
local AK, PK = aiUrl:match("k=(%x+)"), plUrl:match("k=(%x+)")
local function row(module)
  return agent.env.gModules:instances(module)[1]
end
check("pin_lock registered and verified by the Agent", row("pin_lock") ~= nil and row("pin_lock").verified == true)
check("ai_core registered and verified by the Agent", row("ai_core") ~= nil and row("ai_core").verified == true)
-- PIN Lock's first owner code (its own page's setup) and a guest code.
local code, doc = http(pl, 47831, "POST", "/admin/setup?k=" .. PK, { name = "Owner", pin = OWNER_PIN })
check("PIN Lock: first owner code set through its own page", code == 200 and doc.ok == true, code)
local adminSession = doc and doc.session
code, doc = http(
  pl,
  47831,
  "POST",
  "/admin/save?k=" .. PK,
  { session = adminSession, name = "Visitor", role = "guest", pin = GUEST_PIN, actions = {} }
)
check("PIN Lock: a guest code added", code == 200 and doc.ok == true, doc and doc.error)
d:advance(61000)
check(
  "PIN Lock says AI Core may verify (owner PINs only)",
  tostring(pl.Properties["AI Core Approvals"]):find("^On") ~= nil,
  pl.Properties["AI Core Approvals"]
)

local function q(path, s)
  return path .. "?k=" .. AK .. (s and ("&s=" .. s) or "")
end
code, doc = http(aic, 47871, "POST", q("/session"), {})
check("a page session", code == 200 and doc.s ~= nil)
local S = doc.s
local function state()
  local _, st, raw = http(aic, 47871, "GET", q("/state", S))
  return st, raw
end
local function post(path, body)
  local _, r = http(aic, 47871, "POST", q(path, S), body or {})
  return r
end
local lastAfterDone = nil
local function enterPin(pin)
  local st = state()
  local p = st.prompt
  if not p or not p.challenge_id then
    d:advance(1000)
    st = state()
    p = st.prompt
  end
  if not p or not p.challenge_id then
    return nil
  end
  local vhost = p.verify_url:match("^http://([%d%.]+):47831/verify$")
  local vcode, vdoc = http(pl, 47831, "POST", "/verify", { challenge_id = p.challenge_id, pin = pin })
  post("/pin/done", { challenge_id = p.challenge_id })
  -- Before PIN Lock's redeem answer arrives (the bus is asynchronous here):
  -- what the page's very next poll sees.
  lastAfterDone = state()
  d:advance(1000)
  return vcode, vdoc, vhost
end
d:advance(2000)
local st = state()
check("PIN Lock available for this screen", st.pin.available == true, json.encode(st.pin))
check(
  "locked: status and a count only",
  st.chat.locked == true and st.chat.conversation == nil and st.approvals.count == 4,
  json.encode(st.approvals)
)

print("[2] unlock with an owner PIN, ask, receive, auto-lock")
post("/chat/unlock")
d:advance(1000)
local vcode, _, vhost = enterPin(OWNER_PIN)
check(
  "PIN Lock's /verify accepted the owner PIN (200), on this controller",
  vcode == 200 and vhost == "192.168.1.2",
  vcode
)
check(
  "the poll right after /pin/done is never 'locked, nothing pending': unlocked already, or checking",
  lastAfterDone ~= nil
    and (lastAfterDone.chat.locked == false or (lastAfterDone.checking == true and lastAfterDone.chat.locked == true)),
  json.encode(lastAfterDone or {})
)
st = state()
check("the chat is unlocked", st.chat.locked == false and #st.chat.suggestions == 3, json.encode(st.chat))
local r = post("/ask", { question = "Is the garage open?" })
d:advance(2000)
local askOp = lastOp("ask")
check(
  "a touchscreen ask reached the cloud (channel, detail)",
  askOp and askOp.body.channel == "touchscreen" and askOp.body.detail == "standard" and askOp.body.request_id == r.id,
  askOp and json.encode(askOp.body)
)
check(
  "…the frame's request_id is the relay's own, not the ask's (which is the idempotency key)",
  askOp and askOp.frame_request_id ~= nil and askOp.frame_request_id ~= r.id and askOp.idempotency_key == r.id,
  askOp and (tostring(askOp.frame_request_id) .. " / " .. tostring(askOp.idempotency_key))
)
-- As the platform sends it (jobs.ts deliverJob): the job's id and the
-- FRAME's request_id.
moduleCommand("deliver_result", {
  response_id = "resp-1",
  job_id = askOp.job_id,
  request_id = askOp.frame_request_id,
  text = "The garage door is closed.",
  kind = "answer",
  pending_approvals = 0,
})
st = state()
check(
  "the answer arrived through deliver_result (matched by its job id)",
  st.chat.conversation[1] and st.chat.conversation[1].a == "The garage door is closed.",
  json.encode(st.chat.conversation)
)
check(
  "…not in AI_LAST_RESPONSE",
  tostring(aic.Variables and aic.Variables.AI_LAST_RESPONSE or ""):find("garage") == nil
)
for _ = 1, 13 do
  d:advance(25000)
  state() -- polls are not interaction
end
local stRaw
st, stRaw = state()
check("five minutes without interaction: locked again", st.chat.locked == true, st.chat.locks_in)
check("…and the locked body carries no conversation", stRaw:find("garage", 1, true) == nil)

print("[3] a guest PIN is refused")
post("/chat/unlock")
d:advance(1000)
vcode = enterPin(GUEST_PIN)
st = state()
check(
  "PIN Lock refused the guest PIN (401) and the chat stays locked",
  vcode == 401 and st.chat.locked == true and st.notice ~= nil,
  st.notice
)

print("[4] the lockout is PIN Lock's own")
for _ = 1, 4 do
  d:advance(11000)
  post("/chat/unlock")
  d:advance(1000)
  enterPin("11111111")
end
d:advance(31000)
state()
d:advance(2000)
st = state()
check(
  "five wrong PINs: PIN Lock's page lockout, the chat is unavailable here",
  st.pin.reason == "locked" and st.chat.available == false,
  json.encode(st.pin)
)
local lcode, ldoc = http(pl, 47831, "POST", "/unlock?k=" .. PK, { action = 1, pin = OWNER_PIN })
check("…and PIN Lock's own page is locked by the same count", lcode == 429 and ldoc.locked == true, lcode)
d:executeCommand(pl, "CLEAR_LOCKOUTS", {})
d:advance(31000)
state()
d:advance(2000)
st = state()
check("Clear Lockouts on PIN Lock: available again", st.pin.available == true, json.encode(st.pin))

print("[5] review and approve one item; decline one")
post("/approvals/refresh")
d:advance(31000)
post("/approvals/refresh")
d:advance(2000)
st = state()
check(
  "can review (3 for this screen, 1 portal only)",
  st.approvals.can_review == true and st.approvals.screen_count == 3,
  json.encode(st.approvals)
)
local nx = post("/approvals/next")
d:advance(1000)
check("Review next item: waiting for PIN Lock", nx and nx.ok == true, json.encode(nx))
check("no detail before the PIN", #ops("approval_detail") == 0)
local acode = enterPin(OWNER_PIN)
d:advance(2000)
check(
  "PIN Lock's /verify accepted the owner PIN for the item",
  acode == 200,
  tostring(acode) .. " " .. tostring(state().notice)
)
local det = lastOp("approval_detail")
check(
  "approval_detail with an owner-PIN verification",
  det and det.body.ref == REF_A and det.body.verification.role == "owner" and det.body.verification.method == "pin_lock",
  det and json.encode(det.body)
)
st = state()
check(
  "the item is shown; the chat stays locked",
  st.review and st.review.title == "Turn off the patio lights" and st.chat.locked == true,
  json.encode(st.review)
)
post("/approvals/decide", { decision = "approve" })
d:advance(2000)
local dec = lastOp("approval_decide")
check(
  "approval_decide: approve, the detail's args_hash, the same nonce",
  dec
    and dec.body.decision == "approve"
    and dec.body.args_hash == HASH[REF_A]
    and dec.body.verification.nonce == det.body.verification.nonce,
  dec and json.encode(dec.body)
)
st = state()
check("outcome in words: approved", st.notice == "Approved. SmartBuildOS is carrying it out.", st.notice)
d:advance(11000)
post("/approvals/next")
d:advance(1000)
enterPin(OWNER_PIN)
d:advance(2000)
post("/approvals/decide", { decision = "decline" })
d:advance(2000)
dec = lastOp("approval_decide")
check(
  "decline REF_B with its own PIN entry",
  dec.body.ref == REF_B
    and dec.body.decision == "decline"
    and dec.body.verification.nonce ~= det.body.verification.nonce
)
check("outcome in words: declined", state().notice == "Declined.")

print("[6] the cloud refuses an above-ceiling item")
refuseDetail[REF_C] = "above_ceiling"
d:advance(11000)
post("/approvals/next")
d:advance(1000)
enterPin(OWNER_PIN)
d:advance(2000)
st = state()
check(
  "above_ceiling: no item, plain words, the portal",
  st.review == nil and st.notice == "That item is above what a PIN may approve. Use the SmartBuildOS portal.",
  st.notice
)

print("[6b] the dealer's preset questions (round two)")
-- A configuration with two presets arrives the way the platform delivers it
-- (the heartbeat's driver_config block, forwarded by the real Agent).
local P1 = "Is the wine cellar at the right temperature?"
local P2 = "Are all the shades closed?"
post("/chat/lock")
pending.driver_config = {
  {
    driver_sku = "SBOS_AI_CORE",
    settings = { schema = 1, touchscreen = { presets = { P1, P2 } } },
    settings_version = 1,
  },
}
d:executeCommand(agent, "SEND_HEARTBEAT", {})
d:advance(3000)
-- PIN Lock may still be settling after [4]-[6] (its availability is
-- re-read every 30 s): wait, bounded, until this screen may ask for a PIN.
for _ = 1, 10 do
  if state().pin.available == true then
    break
  end
  d:advance(31000)
end
st, stRaw = state()
check(
  "locked: the page shows no preset (no suggestion, no preset text in the bytes)",
  st.chat.locked == true
    and st.chat.suggestions == nil
    and stRaw:find("wine cellar", 1, true) == nil
    and stRaw:find("shades closed", 1, true) == nil,
  stRaw
)
d:advance(11000)
post("/chat/unlock")
d:advance(1000)
vcode = enterPin(OWNER_PIN)
st = state()
local sugs = st.chat.suggestions or {}
check(
  "unlocked: the two presets, then the three built-in questions",
  vcode == 200
    and st.chat.locked == false
    and #sugs == 5
    and sugs[1].label == P1
    and sugs[2].label == P2
    and sugs[3].id == "working"
    and sugs[4].id == "today"
    and sugs[5].id == "attention",
  tostring(vcode) .. " " .. json.encode(st.chat) .. " " .. tostring(st.notice)
)
local asked = post("/ask", { suggestion_id = sugs[1] and sugs[1].id })
d:advance(2000)
askOp = lastOp("ask")
check(
  "asking a preset sends its exact text (channel touchscreen)",
  asked
    and asked.ok == true
    and askOp
    and askOp.body.question == P1
    and askOp.body.channel == "touchscreen"
    and askOp.body.request_id == asked.id,
  askOp and json.encode(askOp.body)
)
post("/chat/lock")

print("[7] the PIN never reached AI Core, the bus or the cloud")
local leaks = {}
for _, f in ipairs(aiFrames) do
  if f:find(OWNER_PIN, 1, true) or f:find(GUEST_PIN, 1, true) then
    leaks[#leaks + 1] = f:sub(1, 60)
  end
end
for _, c in ipairs(rpc) do
  if c.raw:find(OWNER_PIN, 1, true) or c.raw:find(GUEST_PIN, 1, true) then
    leaks[#leaks + 1] = "rpc " .. c.op
  end
end
check(
  "no AI Core frame and no cloud body carries a PIN (" .. #aiFrames .. " frames, " .. #rpc .. " cloud bodies)",
  #leaks == 0 and #aiFrames > 20,
  table.concat(leaks, " | ")
)
check(
  "no runtime errors (Agent, PIN Lock, AI Core)",
  #agent.errors + #pl.errors + #aic.errors == 0,
  agent.errors[1] or pl.errors[1] or aic.errors[1]
)

print(string.format("\nEMULATOR ONLY: %d passed, %d failed", passed, failed))
if failed > 0 then
  os.exit(1)
end
