-- AI Core touchscreen page: the relay, the PIN-gated chat and the PIN
-- approvals (brief D5; spec §2 as amended by rulings 17, 21, 23, 24).
-- SIMULATION ONLY: the real AI Core driver under the shim behind the
-- scripted Agent (test/aicore_harness.lua), with a fake PIN Lock built on
-- PIN Lock's REAL challenge store (src/pinlock/challenge.lua) and a scripted
-- cloud. The emulator scenario (test/emulator/ai_core_webview.lua) runs the
-- real Agent and the real PIN Lock driver.
--
--   [1]  the tile: proxy, published URL, CSP, tokens, bounds, sessions
--   [2]  locked: status and an approvals count only
--   [3]  unlock with an owner PIN (chat_view challenge, redeem)
--   [4]  ask → touchscreen ask → answer, never in AI_LAST_RESPONSE
--   [5]  idle expiry, held answers, bounds of the conversation
--   [6]  Lock, page close, driver restart
--   [7]  a locked session gets no conversation bytes from ANY route
--   [8]  a guest PIN, a non-owner role, a wrong subject: still locked
--   [9]  approvals: review, approve, decline, single use, 60 s, one ref
--   [10] chat and approval proofs never stand in for each other
--   [11] the cloud's refusals in plain words
--   [12] fail closed for every PIN Lock state
--   [13] no PIN in any AI Core request, frame, cloud body or log line
--   [14] detail level, verify_url origin, rate limits
--   [15] the dealer's preset questions: locked bytes, order, exact text,
--        stale ids, the bound, a document without the key
--   [16] an unlock's outcome is never silent: "checking" while PIN Lock
--        redeems, a redeem PIN Lock never answers, a pad left unfinished
--   [17] the `command` of every cloud body is one the platform accepts (the
--        scripted cloud refuses any other, as the platform does), and what
--        a refusal said can be read on the controller as codes only
--   [18] the answer as the platform really sends it: deliver_result names
--        the job and the RELAY's request id (not the ask's), so it is
--        matched by job id; an answer nobody waits for any more is dropped,
--        never published in AI_LAST_RESPONSE
--
-- Run from the driver root: make test

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

-- Everything printed, for the log scan ([13]).
local printed = {}
local realPrint = print
print = function(...)
  local parts = {}
  for i = 1, select("#", ...) do
    parts[#parts + 1] = tostring((select(i, ...)))
  end
  printed[#printed + 1] = table.concat(parts, "\t")
  realPrint(...)
end

local H = require("aicore_harness")
local A = H.agent
local Challenge = require("pinlock.challenge")
local Webui = require("aicore.webui")

local OWNER_PIN = "73914562"
local GUEST_PIN = "86027315"
local REF_A = "11111111-2222-4333-8444-555555555555"
local REF_B = "66666666-7777-4888-9999-aaaaaaaaaaaa"
local HASH_A = string.rep("ab", 32)
local HASH_B = string.rep("cd", 32)

-- ── a fake PIN Lock on its real challenge store ──────────────────────────────
local PIN = {
  row = {
    module_id = "pin_lock",
    instance_id = "777",
    driver = "sbos.pin_lock",
    protocol = 2,
    status = "ready",
    stale = false,
    verified = true,
    capabilities = {
      { id = "pinlock.availability", version = 1, kind = "request" },
      { id = "pinlock.challenge", version = 1, kind = "request" },
      { id = "pinlock.redeem", version = 1, kind = "request" },
    },
  },
  ready = true,
  reason = "ready",
  retry_in = nil,
  silent = false, -- true: PIN Lock never answers
  silentRedeem = false, -- true: PIN Lock never answers a redeem (only)
  fails = 0,
  lockedUntil = 0,
  redeemOverride = nil, -- function(result) -> result (a misbehaving PIN Lock)
  frames = {}, -- every request AI Core sent PIN Lock
}
local idSeq = 0
PIN.store = Challenge.new({
  now = os.time,
  newId = function()
    idSeq = idSeq + 1
    return string.format("%032x", 0xc0de0000 + idSeq)
  end,
})
--- PIN Lock's /verify, as the page would call it (NOT an AI Core route).
function PIN.verify(challengeId, pin)
  return PIN.store:verify(challengeId, pin, function(p)
    if os.time() < PIN.lockedUntil then
      return { ok = false, locked = true, retry_in = PIN.lockedUntil - os.time() }
    end
    if p == OWNER_PIN then
      return { ok = true, role = "owner" }
    end
    PIN.fails = PIN.fails + 1
    if PIN.fails >= 5 then
      PIN.lockedUntil = os.time() + 300
      return { ok = false, locked = true, retry_in = 300 }
    end
    return { ok = false }
  end)
end
A.modules = { PIN.row }
A.busAnswer = function(to, capability, args, p)
  if to ~= "pin_lock" then
    return "error", {}, "unknown_target"
  end
  PIN.frames[#PIN.frames + 1] = { capability = capability, args = args, raw = p.args }
  if PIN.silent or (PIN.silentRedeem and capability == "pinlock.redeem") then
    return false
  end
  if capability == "pinlock.availability" then
    if os.time() < PIN.lockedUntil then
      return "ok", { ready = false, reason = "locked", retry_in = PIN.lockedUntil - os.time() }
    end
    return "ok", { ready = PIN.ready, reason = PIN.reason, retry_in = PIN.retry_in }
  elseif capability == "pinlock.challenge" then
    if not PIN.ready then
      return "error", { reason = PIN.reason }, "unsupported"
    end
    local c, code, why = PIN.store:issue("12345", args)
    if c == nil then
      return "error", { reason = why }, code
    end
    return "ok",
      { challenge_id = c.id, expires_in = 60, verify_url = PIN.verifyUrl or "http://192.168.1.20:47831/verify" }
  elseif capability == "pinlock.redeem" then
    local r, code, why = PIN.store:redeem("12345", args)
    if r == nil then
      return "error", { reason = why }, code
    end
    if PIN.redeemOverride then
      r = PIN.redeemOverride(r)
    end
    return "ok", r
  end
  return "error", {}, "capability_not_found"
end
local function framesOf(capability)
  local out = {}
  for _, f in ipairs(PIN.frames) do
    if f.capability == capability then
      out[#out + 1] = f
    end
  end
  return out
end

-- ── a scripted cloud ─────────────────────────────────────────────────────────
local CLOUD = {
  pending = {
    enabled = true,
    count = 3,
    eligible = { { ref = REF_A, expires_at = 0 }, { ref = REF_B, expires_at = 0 } },
    portal_only_count = 1,
  },
  detail = {},
  refuse = {}, -- op -> reason
  refuseResult = {}, -- op -> the whole result of the refusal (with refuse[op])
  decideStatus = "queued",
  commandRefused = 0,
}
--- The platform's rule for a body's `command` (rpc/ops.ts: COMMON.command
--- is text of at most 48 characters matching COMMAND = /^AI_[A-Z_]{2,40}$/;
--- anything else refuses the WHOLE body). The answers below are the ones the
--- platform's handlers give for it: a job op answers reason invalid_fields,
--- a touchscreen approval op reason invalid_args with the detail.
local function platformCommandOk(command)
  return type(command) == "string"
    and #command <= 48
    and command:match("^AI_[A-Z_]+$") ~= nil
    and #command >= 5
    and #command <= 43
end
A.cloud = function(op, body)
  if not platformCommandOk(body.command) then
    CLOUD.commandRefused = CLOUD.commandRefused + 1
    local result = op == "ask" and { reason = "invalid_fields", fields = { "command" } }
      or { reason = "invalid_args", detail = "invalid_fields", fields = { "command" } }
    return { status = "error", http_status = "200", error_code = "invalid_args", result = result }
  end
  if CLOUD.refuse[op] then
    local reason = CLOUD.refuse[op]
    local code = reason == "rate_limited" and "rate_limited"
      or reason == "invalid_args" and "invalid_args"
      or "not_permitted"
    return {
      status = "error",
      http_status = "200",
      error_code = code,
      result = CLOUD.refuseResult[op] or { reason = reason },
    }
  end
  if op == "approvals_pending" then
    local r = {}
    for k, v in pairs(CLOUD.pending) do
      r[k] = v
    end
    for _, e in ipairs(r.eligible) do
      e.expires_at = os.time() + 3600
    end
    r.checked_at = os.time()
    return { status = "ok", http_status = "200", error_code = "ok", result = r }
  elseif op == "approval_detail" then
    local hash = body.ref == REF_A and HASH_A or HASH_B
    return {
      status = "ok",
      http_status = "200",
      error_code = "ok",
      result = {
        ref = body.ref,
        title = body.ref == REF_A and "Turn off the patio lights" or "Lower the den shades",
        description = "<img src=x onerror=alert(1)> Proposed by SmartBuildOS AI",
        risk = "low",
        expires_at = os.time() + 3600,
        args_hash = hash,
      },
    }
  elseif op == "approval_decide" then
    return {
      status = "ok",
      http_status = "200",
      error_code = "ok",
      result = { ref = body.ref, status = CLOUD.decideStatus },
    }
  end
  return nil -- the default: accepted with a job id
end
local function lastCloud(op)
  local l = H.cloudOps(op)
  return l[#l]
end

local function ready()
  H.agentPresent = true
  H.load("DIT_ADDING")
  H.advance(31000)
  H.advance(61000)
end

local K
local function tokenFromUrls()
  local url = H.urls[#H.urls] or ""
  return url:match("[?&]k=(%x+)")
end
local function q(path, s)
  return path .. "?k=" .. tostring(K) .. (s and ("&s=" .. s) or "")
end
local function open()
  local code, doc = H.http("POST", q("/session"), {})
  assert(code == 200 and doc and doc.s, "session")
  return doc.s
end
local function state(s)
  local _, doc, raw = H.http("GET", q("/state", s))
  return doc, raw
end
local function post(s, path, body)
  local code, doc, raw = H.http("POST", q(path, s), body or {})
  return doc, code, raw
end
--- The page's part of one PIN entry: read the prompt, post the PIN to PIN
--- Lock's verify_url (the fake), tell AI Core it is done.
local function enterPin(s, pin)
  local st = state(s)
  local p = st.prompt
  if p == nil or p.challenge_id == nil then
    return nil, "no prompt"
  end
  local v = PIN.verify(p.challenge_id, pin)
  post(s, "/pin/done", { challenge_id = p.challenge_id })
  return v, p
end
--- Time passes while the given page sessions keep polling (every 25 s, as
--- an open page does); polls are not interaction.
local function wait(ms, ...)
  local list = { ... }
  while ms > 0 do
    local step = math.min(ms, 25000)
    H.advance(step)
    ms = ms - step
    for _, x in ipairs(list) do
      H.http("GET", q("/state", x))
    end
  end
end
local function unlock(s, pin)
  post(s, "/chat/unlock")
  return enterPin(s, pin or OWNER_PIN)
end

-- ── [1] ──────────────────────────────────────────────────────────────────────
print("[1] the tile: proxy, published URL, CSP, tokens, bounds, sessions")
ready()
check("setup: AI Core ready", H.vars.AI_STATUS == "ready", H.vars.AI_STATUS)
check("the relay listens on 47871", H.servers[47871] == "aicore-ui-relay")
K = tokenFromUrls()
check(
  "the web view URL is the relay with the install token",
  K ~= nil and H.urls[#H.urls]:find("^http://192%.168%.1%.20:47871/app%?k=") ~= nil,
  H.urls[#H.urls]
)
check("published at start and again 60 s later (a notify before project start is lost)", #H.urls == 2, #H.urls)
check("nothing reached equipment (URL_CHANGED to its own proxy only)", #H.equipment == 0, #H.equipment)
check(
  "Webview Address says where, home network only",
  tostring(H.prop("Webview Address")):find("47871/app %(home network only%)") ~= nil,
  H.prop("Webview Address")
)
local code, doc, raw = H.http("GET", "/ping")
check("/ping is tokenless", code == 200 and doc.service == "ai-core")
code, _, raw = H.http("GET", "/app")
check("/app serves the embedded page", code == 200 and raw:find("aicore%-pure") ~= nil)
check(
  "the page's CSP allows only its own relay and PIN Lock's port on this host",
  raw:find("connect-src 'self' http://192.168.1.20:47831;", 1, true) ~= nil
    and select(2, raw:gsub("connect%-src", "")) == 1,
  raw:match("connect%-src[^;]*")
)
check("…and no third-party resources (default-src 'none')", raw:find("default-src 'none'", 1, true) ~= nil)
code = H.http("GET", "/state?k=wrong")
check("a bad install token: 403", code == 403)
code = H.http("POST", "/session?k=" .. string.rep("0", 32), {})
check("…on /session too", code == 403)
local s1 = open()
check("a session token is 32 hex", Webui.hex32(s1))
code = H.http("GET", q("/state", string.rep("f", 32)))
check("an unknown session: 401", code == 401)
code = H.http("GET", q("/state"))
check("no session: 401", code == 401)
code = H.http("POST", q("/ask", s1), string.rep("x", 5000))
check("a body over 4 KB: 413", code == 413)
local sessions = { s1 }
for _ = 1, 3 do
  H.advance(1000)
  sessions[#sessions + 1] = open()
end
H.advance(1000)
local s5 = open()
code = H.http("GET", q("/state", sessions[1]))
check("at most 4 sessions: a fifth evicts the least recently seen", code == 401 and state(s5).ok == true)
check("…and is counted", H.http("GET", q("/state", s5)) == 200)

-- ── [2] ──────────────────────────────────────────────────────────────────────
print("[2] locked: status and an approvals count only")
local s = open()
local st, stRaw = state(s)
check(
  "status in plain words",
  st.status.text.online == "Online" and st.status.text.licensed == "Licensed",
  JSON:encode(st.status)
)
check(
  "provider and learning",
  st.status.text.provider == "No AI provider set up yet" and st.status.text.learning == "Learning is off"
)
check(
  "approvals: a count",
  st.approvals.count == 3 and st.approvals.text == "3 items await approval",
  JSON:encode(st.approvals)
)
check("…no refs reach the page", stRaw:find(REF_A, 1, true) == nil and stRaw:find(REF_B, 1, true) == nil)
check(
  "…one is portal only, said plainly",
  tostring(st.approvals.message):find("1 item can only be approved in the SmartBuildOS portal") ~= nil,
  st.approvals.message
)
check("PIN Lock available for this screen", st.pin.available == true and st.pin.message == Webui.TEXT.ready)
check(
  "chat available but locked",
  st.chat.available == true and st.chat.locked == true and st.chat.message == Webui.TEXT.chat_locked
)
check(
  "locked: no conversation, no suggestions, no explain",
  st.chat.conversation == nil and st.chat.suggestions == nil and st.chat.explain == nil
)
check(
  "Touchscreen Approvals summarises it",
  tostring(H.prop("Touchscreen Approvals")):find("PIN Lock ready") ~= nil,
  H.prop("Touchscreen Approvals")
)
local doc2 = post(s, "/ask", { question = "Is the garage open?" })
check(
  "/ask refused while locked (chat_locked), plain words",
  doc2.ok == false and doc2.reason == "chat_locked" and doc2.message == Webui.TEXT.chat_locked
)
check("…and no ask reached the cloud", #H.cloudOps("ask") == 0)

-- ── [3] ──────────────────────────────────────────────────────────────────────
print("[3] unlock with an owner PIN")
local nCh = #framesOf("pinlock.challenge")
doc2 = post(s, "/chat/unlock")
check("/chat/unlock: waiting for PIN Lock", doc2.ok == true and doc2.waiting == true)
local ch = framesOf("pinlock.challenge")[nCh + 1]
check("one pinlock.challenge, purpose chat_view", ch ~= nil and ch.args.purpose == "chat_view")
check(
  "…subject = the session id (32 hex), never the session token",
  Webui.hex32(ch.args.subject) and ch.args.subject ~= s
)
check("…nonce 32 hex minted by AI Core", Webui.hex32(ch.args.nonce))
check(
  "…exactly three keys",
  ch.args.purpose and ch.args.subject and ch.args.nonce and select(2, ch.raw:gsub(":", "")) == 3,
  ch.raw
)
st = state(s)
check(
  "/state: a prompt for the chat with PIN Lock's verify_url",
  st.prompt and st.prompt["for"] == "chat" and st.prompt.verify_url == "http://192.168.1.20:47831/verify",
  JSON:encode(st.prompt)
)
local v = PIN.verify(st.prompt.challenge_id, OWNER_PIN)
check("(PIN Lock's /verify accepted the owner PIN)", v.ok == true)
local nRd = #framesOf("pinlock.redeem")
post(s, "/pin/done", { challenge_id = st.prompt.challenge_id })
local rd = framesOf("pinlock.redeem")[nRd + 1]
check(
  "pinlock.redeem with the same nonce, purpose and subject",
  rd and rd.args.nonce == ch.args.nonce and rd.args.purpose == "chat_view" and rd.args.subject == ch.args.subject
)
st = state(s)
check("unlocked", st.chat.locked == false and st.prompt == nil)
check("suggestions and explain only now", #st.chat.suggestions == #Webui.SUGGESTIONS and st.chat.explain == true)
check("locks in 5 minutes without interaction", st.chat.locks_in == 300, st.chat.locks_in)
local other = open()
check("another page session stays locked", state(other).chat.locked == true)

-- ── [4] ──────────────────────────────────────────────────────────────────────
print("[4] ask → touchscreen ask → answer")
local respBefore = H.vars.AI_LAST_RESPONSE
local fired1 = H.firedCount(1)
doc2 = post(s, "/ask", { question = "Is the garage open?" })
local askOp = lastCloud("ask")
check("/ask accepted with an id", doc2.ok == true and type(doc2.id) == "string")
check(
  "the ask op: question, channel touchscreen, detail standard",
  askOp
    and askOp.body.question == "Is the garage open?"
    and askOp.body.channel == "touchscreen"
    and askOp.body.detail == "standard"
    and askOp.body.request_id == doc2.id,
  askOp and JSON:encode(askOp.body)
)
check(
  "…no envelope carries the question (it is not a Composer event)",
  (function()
    for _, e in ipairs(H.envelopes()) do
      if JSON:encode(e):find("garage open", 1, true) then
        return false
      end
    end
    return true
  end)()
)
st = state(s)
check(
  "pending in the conversation",
  st.chat.conversation[1].q == "Is the garage open?" and st.chat.conversation[1].state == "pending"
)
local states = H.operation(
  "deliver_result",
  { response_id = "resp-1", job_id = "job-x", request_id = doc2.id, text = "The garage door is closed." }
)
check("deliver_result Completed", H.finalState(states) == "Completed")
st = state(s)
check(
  "the answer is shown to the unlocked session",
  st.chat.conversation[1].a == "The garage door is closed." and st.chat.conversation[1].state == "answered"
)
check(
  "…never in AI_LAST_RESPONSE",
  H.vars.AI_LAST_RESPONSE == respBefore and tostring(H.vars.AI_LAST_RESPONSE):find("garage") == nil
)
check("…never persisted", JSON:encode(H.persisted):find("garage", 1, true) == nil)
check("…no AI Response Ready (Composer programming could show it)", H.firedCount(1) == fired1)
check("…and the other session sees nothing", state(other).chat.conversation == nil)
H.operation("deliver_result", { response_id = "resp-c", text = "A Composer answer." })
check("a Composer ask's answer still goes to AI_LAST_RESPONSE", H.vars.AI_LAST_RESPONSE == "A Composer answer.")
doc2 = post(s, "/ask", { suggestion_id = "working" })
check(
  "a suggestion asks its fixed question",
  doc2.ok and lastCloud("ask").body.question == Webui.SUGGESTIONS[1].question
)
doc2 = post(s, "/ask", { explain = true })
check(
  "'explain what just happened' asks the fixed template",
  doc2.ok and lastCloud("ask").body.question == Webui.EXPLAIN_QUESTION
)
doc2 = post(s, "/ask", { suggestion_id = "bogus" })
check(
  "an unknown suggestion is refused in plain words",
  doc2.ok == false and doc2.message == Webui.TEXT.unknown_suggestion
)

-- ── [5] ──────────────────────────────────────────────────────────────────────
print("[5] idle expiry, held answers, bounds")
wait(61000, s) -- the ask bucket refills
wait(240000, s)
st = state(s)
check("polling alone does not keep it open: locked after 5 minutes", st.chat.locked == true, st.chat.locks_in)
s = open()
unlock(s)
check("(unlocked again)", state(s).chat.locked == false)
wait(200000, s)
post(s, "/chat/touch")
wait(200000, s)
check("interaction (touch) keeps it open past 5 minutes from unlock", state(s).chat.locked == false)
wait(61000, s)
post(s, "/chat/touch")
doc2 = post(s, "/ask", { question = "Held question?" })
local heldId = doc2.id
post(s, "/chat/lock")
H.operation("deliver_result", { response_id = "resp-2", request_id = heldId, text = "Held answer text." })
st, stRaw = state(s)
check(
  "an answer that arrives while locked is held: not in any locked body",
  stRaw:find("Held answer", 1, true) == nil and stRaw:find("Held question", 1, true) == nil
)
unlock(s)
st = state(s)
check("…and shown at the next unlock", st.chat.conversation[#st.chat.conversation].a == "Held answer text.")
post(s, "/chat/touch")
local late = post(s, "/ask", { question = "Never answered?" })
wait(290000, s)
post(s, "/chat/touch")
wait(15000, s)
st = state(s)
check(
  "a question unanswered after 5 minutes is shown as failed, in words",
  (function()
    for _, e in ipairs(st.chat.conversation or {}) do
      if e.id == late.id then
        return e.state == "failed" and e.message == Webui.TEXT.cloud_unreachable
      end
    end
    return false
  end)(),
  st.chat.locked
)
unlock(s)
for i = 1, 12 do
  H.advance(16000)
  post(s, "/ask", { question = "Bound question " .. i .. "?" })
end
st = state(s)
check("at most 10 exchanges kept", #st.chat.conversation == 10, #st.chat.conversation)
post(s, "/chat/lock")
wait(901000, s)
unlock(s)
st = state(s)
check(
  "15 minutes without interaction clear the conversation (held answers too)",
  st.chat.locked == false and #st.chat.conversation == 0,
  #st.chat.conversation
)

-- ── [6] ──────────────────────────────────────────────────────────────────────
print("[6] Lock, page close, driver restart")
unlock(s)
post(s, "/chat/lock")
check("Lock locks", state(s).chat.locked == true)
unlock(s)
post(s, "/session/close")
check("closing the page ends the session", H.http("GET", q("/state", s)) == 401)
s = open()
unlock(s)
H.advance(76000)
check("a page that stopped polling for 75 s is closed (unlock gone)", H.http("GET", q("/state", s)) == 401)
s = open()
unlock(s)
check("(unlocked)", state(s).chat.locked == false)
H.load("restart")
H.advance(31000)
K = tokenFromUrls()
check("after a driver restart the session is unknown: everything locked again", H.http("GET", q("/state", s)) == 401)
check("…the install token survives (persisted)", K ~= nil)
s = open()
check("…a new session starts locked", state(s).chat.locked == true)

-- ── [7] ──────────────────────────────────────────────────────────────────────
print("[7] a locked session gets no conversation bytes from ANY route")
unlock(s)
wait(61000, s)
post(s, "/chat/touch")
doc2 = post(s, "/ask", { question = "Secret question zebra?" })
H.operation("deliver_result", { response_id = "resp-z", request_id = doc2.id, text = "Secret answer giraffe." })
check("(unlocked, it is there)", select(2, state(s)):find("giraffe", 1, true) ~= nil)
post(s, "/chat/lock")
local leaks = {}
local function scan(label, body)
  body = tostring(body or "")
  if body:find("zebra", 1, true) or body:find("giraffe", 1, true) then
    leaks[#leaks + 1] = label
  end
end
for _, r in ipairs({
  { "GET", "/state" },
  { "POST", "/chat/unlock" },
  { "POST", "/chat/touch" },
  { "POST", "/pin/cancel" },
  { "POST", "/pin/done", { challenge_id = string.rep("0", 32) } },
  { "POST", "/ask", { question = "x" } },
  { "POST", "/ask", { explain = true } },
  { "POST", "/approvals/refresh" },
  { "POST", "/approvals/next" },
  { "POST", "/approvals/decide", { decision = "approve" } },
  { "POST", "/approvals/close" },
  { "POST", "/chat/lock" },
  { "GET", "/app" },
  { "GET", "/ping" },
  { "POST", "/nope" },
}) do
  local _, _, body = H.http(r[1], q(r[2], s), r[3])
  scan(r[1] .. " " .. r[2], body)
end
scan("GET /state (again)", select(2, state(s)))
check("no route returned any conversation content to the locked session", #leaks == 0, table.concat(leaks, ", "))
post(s, "/pin/cancel")
post(s, "/approvals/close")

-- ── [8] ──────────────────────────────────────────────────────────────────────
print("[8] a guest PIN, a non-owner role, a wrong subject")
local g = open()
local gv = unlock(g, GUEST_PIN)
check("(PIN Lock refused the guest PIN at /verify)", gv and gv.ok == false)
st = state(g)
check(
  "a guest PIN: still locked, said plainly",
  st.chat.locked == true and st.notice == Webui.TEXT.not_verified,
  st.notice
)
PIN.redeemOverride = function(r)
  r.role = "guest"
  return r
end
unlock(g, OWNER_PIN)
st = state(g)
check(
  "a redeem that answers a non-owner role is refused",
  st.chat.locked == true and st.notice == Webui.TEXT.role_not_owner,
  st.notice
)
PIN.redeemOverride = nil
post(g, "/chat/unlock")
st = state(g)
local wrongId = st.prompt.challenge_id
PIN.verify(wrongId, OWNER_PIN)
local d = post(g, "/pin/done", { challenge_id = string.rep("e", 32) })
check(
  "/pin/done for a challenge this session was not given: refused, nothing redeemed",
  d.ok == false and d.reason == "no_prompt"
)
post(g, "/pin/done", { challenge_id = wrongId })
check("(the real one still unlocks)", state(g).chat.locked == false)
PIN.fails = 0

-- ── [9] ──────────────────────────────────────────────────────────────────────
print("[9] approvals: review, approve, decline, single use, 60 s, one ref")
local a = open()
st = state(a)
check(
  "can review (approvals on, PIN Lock ready, 2 for this screen)",
  st.approvals.can_review == true and st.approvals.screen_count == 2
)
nCh = #framesOf("pinlock.challenge")
doc2 = post(a, "/approvals/next")
ch = framesOf("pinlock.challenge")[nCh + 1]
check(
  "Review next item: an approval challenge bound to the first ref",
  doc2.ok and ch.args.purpose == "approval" and ch.args.subject == REF_A
)
local nDetail = #H.cloudOps("approval_detail")
check("…no detail before the PIN", #H.cloudOps("approval_detail") == nDetail)
st = state(a)
check("the prompt is for one item", st.prompt["for"] == "approval")
PIN.verify(st.prompt.challenge_id, OWNER_PIN)
post(a, "/pin/done", { challenge_id = st.prompt.challenge_id })
local det = lastCloud("approval_detail")
check(
  "approval_detail with verification {nonce, verified_at, role, method}",
  det
    and det.body.ref == REF_A
    and det.body.verification.nonce == ch.args.nonce
    and det.body.verification.role == "owner"
    and det.body.verification.method == "pin_lock"
    and type(det.body.verification.verified_at) == "number",
  det and JSON:encode(det.body)
)
check(
  "…exactly those four verification keys (no label, no slot)",
  (function()
    local n = 0
    for _ in pairs(det.body.verification) do
      n = n + 1
    end
    return n == 4
  end)()
)
st, stRaw = state(a)
check(
  "the item: title, description, risk",
  st.review.title == "Turn off the patio lights"
    and st.review.risk == "low"
    and st.review.description:find("Proposed by", 1, true) ~= nil
)
check(
  "…cloud text travels as data (JSON string), rendered with textContent by the page",
  stRaw:find("<img src=x", 1, true) ~= nil
)
check("an approval PIN never unlocks the chat", st.chat.locked == true and st.chat.conversation == nil)
check("…60 seconds to decide", st.review.grant_left == 60, st.review.grant_left)
post(a, "/approvals/decide", { decision = "approve" })
local dec = lastCloud("approval_decide")
check(
  "approval_decide: ref, approve, the detail's args_hash, the same verification",
  dec
    and dec.body.ref == REF_A
    and dec.body.decision == "approve"
    and dec.body.args_hash == HASH_A
    and dec.body.verification.nonce == ch.args.nonce,
  dec and JSON:encode(dec.body)
)
st = state(a)
check("the outcome in plain words", st.notice == Webui.OUTCOME_TEXT.queued, st.notice)
local nDec = #H.cloudOps("approval_decide")
d = post(a, "/approvals/decide", { decision = "approve" })
check(
  "the proof was single use: a second decide is refused, nothing sent",
  d.ok == false and #H.cloudOps("approval_decide") == nDec
)
-- decline the next one
wait(61000, a)
nCh = #framesOf("pinlock.challenge")
d = post(a, "/approvals/next")
ch = framesOf("pinlock.challenge")[nCh + 1]
check(
  "the next item (REF_A decided here) is REF_B, with a NEW challenge",
  ch and ch.args.subject == REF_B,
  JSON:encode(d)
)
enterPin(a, OWNER_PIN)
post(a, "/approvals/decide", { decision = "decline" })
dec = lastCloud("approval_decide")
check(
  "decline: decision decline, REF_B's args_hash",
  dec.body.ref == REF_B and dec.body.decision == "decline" and dec.body.args_hash == HASH_B
)
-- the 60 s grant
CLOUD.decideStatus = "queued"
local b = open()
H.advance(31000)
post(b, "/approvals/next")
enterPin(b, OWNER_PIN)
check("(reviewing)", state(b).review ~= nil)
H.advance(61000)
nDec = #H.cloudOps("approval_decide")
d = post(b, "/approvals/decide", { decision = "approve" })
check("after 60 s the proof is gone: refused, nothing sent", d.ok == false and #H.cloudOps("approval_decide") == nDec)
-- one ref per proof
local c = open()
H.advance(31000)
post(c, "/approvals/next")
enterPin(c, OWNER_PIN)
check("(reviewing REF_A)", state(c).review.title == "Turn off the patio lights")
nDetail = #H.cloudOps("approval_detail")
nCh = #framesOf("pinlock.challenge")
post(c, "/approvals/next")
check("Review next item again: a new PIN challenge, the proof is not reused", #framesOf("pinlock.challenge") == nCh + 1)
check("…no approval_detail without that new PIN", #H.cloudOps("approval_detail") == nDetail)
post(c, "/pin/cancel")

-- ── [10] ─────────────────────────────────────────────────────────────────────
print("[10] chat and approval proofs never stand in for each other")
local x = open()
unlock(x)
check("(chat unlocked)", state(x).chat.locked == false)
H.advance(31000)
post(x, "/approvals/next")
enterPin(x, OWNER_PIN)
check("(reviewing an item; chat still unlocked)", state(x).review ~= nil and state(x).chat.locked == false)
H.advance(61000)
post(x, "/chat/touch")
check("(chat still unlocked, the approval proof expired)", state(x).chat.locked == false)
nDec = #H.cloudOps("approval_decide")
d = post(x, "/approvals/decide", { decision = "approve" })
check(
  "a chat_view unlock is refused for approval_decide",
  d.ok == false and #H.cloudOps("approval_decide") == nDec,
  d.reason
)
do
  -- White-box, on the pure module: a session whose chat is unlocked and
  -- which still holds a reviewed item, but no approval proof for it (any
  -- path that leaves the item behind). approval_decide must not go.
  local clock = 1800000000
  local sent = {}
  local hexN = 0
  local ui = Webui.new({
    now = function()
      return clock
    end,
    newHex = function()
      hexN = hexN + 1
      return string.format("%032x", hexN)
    end,
    newRequestId = function()
      return "aic-w" .. hexN
    end,
    facts = function()
      return { licensed = true, online = true }
    end,
    detail = function()
      return "standard"
    end,
    relayHost = function()
      return "192.168.1.20"
    end,
    pinAvailability = function(cb)
      cb({ available = true, reason = "ready" })
    end,
    pinRequest = function() end,
    cloud = function(op, body)
      sent[#sent + 1] = { op = op, body = body }
    end,
    take = function()
      return true
    end,
    appHtml = function()
      return "x"
    end,
  })
  local sess = ui:openSession()
  sess.proofs.chat_view = {
    purpose = "chat_view",
    subject = sess.sid,
    nonce = string.rep("a", 32),
    verified_at = clock,
    role = "owner",
    ends = clock + 300,
  }
  sess.review = { ref = REF_A, loading = false, args_hash = HASH_A, title = "t" }
  local n0 = #sent
  local r = ui:route({
    method = "POST",
    path = "/approvals/decide",
    query = { k = "K", s = sess.token },
    body = '{"decision":"approve"}',
  }, "K")
  local okDoc = JSON:decode(r.body)
  local decided = false
  for i = n0 + 1, #sent do
    if sent[i].op == "approval_decide" then
      decided = true
    end
  end
  check(
    "pure: an unlocked chat never stands in for an approval proof (no_grant, nothing sent)",
    okDoc.ok == false and okDoc.reason == "no_grant" and not decided,
    r.body
  )
  sess.proofs.chat_view = nil
  sess.proofs.approval = {
    purpose = "approval",
    subject = REF_A,
    nonce = string.rep("b", 32),
    verified_at = clock,
    role = "owner",
    ends = clock + 60,
  }
  check(
    "pure: an approval proof never unlocks the chat",
    ui:unlocked(sess) == false and ui:stateDoc(sess).chat.conversation == nil
  )
end
check(
  "Webui proof check: a chat_view proof never answers for an approval",
  (function()
    local ui = {
      now = function()
        return os.time()
      end,
    }
    local sess = { proofs = { chat_view = { purpose = "chat_view", subject = "s", ends = os.time() + 100 } } }
    return Webui._proofFor(ui, sess, "approval", REF_A) == nil and Webui._proofFor(ui, sess, "approval", "s") == nil
  end)()
)

-- ── [11] ─────────────────────────────────────────────────────────────────────
print("[11] the cloud's refusals in plain words")
local REASONS = {
  "invalid_args",
  "system_not_linked_to_a_property",
  "touchscreen_approval_off",
  "role_not_permitted",
  "verification_stale",
  "verification_replayed",
  "rate_limited",
  "not_for_this_controller",
  "not_pending",
  "expired",
  "portal_only",
  "above_ceiling",
  "approval_mismatch",
  "unavailable",
}
local raw_ = {}
for _, r in ipairs(REASONS) do
  if Webui.TEXT[r] == nil or Webui.TEXT[r]:find("_") then
    raw_[#raw_ + 1] = r
  end
end
check("every closed refusal reason (ruling 24) has plain words, no code in them", #raw_ == 0, table.concat(raw_, ", "))
local codey = {}
for k, t in pairs(Webui.TEXT) do
  if t:find("[a-z]+_[a-z]+") then
    codey[#codey + 1] = k
  end
end
check("no text in the table reads like a code", #codey == 0, table.concat(codey, ", "))
check("an unknown reason falls back to words, never the code", Webui.text("brand_new_reason") == Webui.FALLBACK_TEXT)
-- An unlicensed controller's ask: the platform's real refusal (rpc/handler.ts
-- step 8) as the Agent relays it.
local unlicensedAnswer = {
  status = "error",
  error_code = "cloud_refused",
  result = { reason = "not_entitled", license_status = "NOT_ENTITLED" },
}
local unlicensedText = Webui.text(Webui.cloudReason(unlicensedAnswer))
check(
  "an unlicensed controller's refusal: 'not licensed for this controller' in words, no code, no licence status",
  unlicensedText == Webui.TEXT.not_entitled
    and unlicensedText:find("not licensed for this controller", 1, true) ~= nil
    and not unlicensedText:find("NOT_ENTITLED", 1, true),
  unlicensedText
)
for _, r in ipairs({
  "above_ceiling",
  "portal_only",
  "expired",
  "not_pending",
  "touchscreen_approval_off",
  "verification_replayed",
}) do
  CLOUD.refuse.approval_detail = r
  local y = open()
  H.advance(31000)
  post(y, "/approvals/next")
  enterPin(y, OWNER_PIN)
  st = state(y)
  check(
    "approval_detail refused " .. r .. ": shown as words, no item, no code",
    st.review == nil and st.notice == Webui.TEXT[r] and not tostring(st.notice):find(r, 1, true),
    st.notice
  )
  post(y, "/session/close")
end
CLOUD.refuse.approval_detail = nil
CLOUD.refuse.approval_decide = "approval_mismatch"
local z = open()
H.advance(31000)
post(z, "/approvals/next")
enterPin(z, OWNER_PIN)
post(z, "/approvals/decide", { decision = "approve" })
check("approval_decide refused approval_mismatch: words", state(z).notice == Webui.TEXT.approval_mismatch)
CLOUD.refuse.approval_decide = nil
post(z, "/session/close")
CLOUD.refuse.approvals_pending = "system_not_linked_to_a_property"
local w = open()
H.advance(61000)
post(w, "/approvals/refresh")
st = state(w)
check(
  "approvals_pending refused: words, nothing to review",
  st.approvals.message == Webui.TEXT.system_not_linked_to_a_property,
  st.approvals.message
)
CLOUD.refuse.approvals_pending = nil
H.advance(31000)
post(w, "/approvals/refresh")
CLOUD.pending.enabled = false
H.advance(31000)
post(w, "/approvals/refresh")
st = state(w)
check(
  "approvals switched off by the homeowner: said, no review offered",
  st.approvals.can_review == false and st.approvals.message == Webui.TEXT.approvals_off,
  st.approvals.message
)
d = post(w, "/approvals/next")
check("…and Review next item is refused", d.ok == false and d.reason == "approvals_off")
CLOUD.pending.enabled = true
H.advance(31000)
post(w, "/approvals/refresh")
post(w, "/session/close")

-- ── [12] ─────────────────────────────────────────────────────────────────────
print("[12] fail closed for every PIN Lock state")
local function pinCase(label, setup, teardown)
  local p = open()
  unlock(p)
  local wasOpen = state(p).chat.locked == false
  setup()
  wait(31000, p)
  wait(10000, p) -- a PIN Lock that never answers times out (8 s)
  local n0 = #framesOf("pinlock.challenge")
  st = state(p)
  local d1 = post(p, "/chat/unlock")
  local d2 = post(p, "/approvals/next")
  st = state(p)
  local closed = wasOpen
    and st.pin.available == false
    and st.chat.available == false
    and st.chat.locked == true
    and st.chat.conversation == nil
    and st.approvals.can_review == false
    and d1.ok == false
    and d2.ok == false
    and #framesOf("pinlock.challenge") == n0
    and tostring(st.chat.message):find("portal", 1, true) ~= nil
  check(
    "PIN Lock " .. label .. ": chat unavailable, no approval offered, use the portal",
    closed,
    JSON:encode({ st.pin, st.chat.message, d1.reason })
  )
  teardown()
  post(p, "/session/close")
  H.advance(31000)
end
pinCase("not installed", function()
  A.modules = {}
end, function()
  A.modules = { PIN.row }
end)
pinCase("not verified by the Agent", function()
  PIN.row.verified = false
end, function()
  PIN.row.verified = true
end)
pinCase("stale", function()
  PIN.row.stale = true
end, function()
  PIN.row.stale = false
end)
pinCase("without the pinlock capabilities (needs an update)", function()
  PIN.row.capabilities = {}
end, function()
  PIN.row.capabilities = {
    { id = "pinlock.availability", version = 1, kind = "request" },
    { id = "pinlock.challenge", version = 1, kind = "request" },
    { id = "pinlock.redeem", version = 1, kind = "request" },
  }
end)
pinCase("not answering", function()
  PIN.silent = true
end, function()
  PIN.silent = false
end)
for _, reason in ipairs({ "starting", "off", "unlicensed", "no_owner_pin", "relay_unavailable" }) do
  pinCase("ready:false " .. reason, function()
    PIN.ready, PIN.reason = false, reason
  end, function()
    PIN.ready, PIN.reason = true, "ready"
  end)
end
pinCase("locked out", function()
  PIN.lockedUntil = os.time() + 300
end, function()
  PIN.lockedUntil = 0
end)
do
  local p = open()
  PIN.lockedUntil = os.time() + 300
  H.advance(31000)
  state(p)
  st = state(p)
  check(
    "a lockout shows its time",
    st.pin.reason == "locked" and type(st.pin.retry_in) == "number" and st.pin.retry_in > 0,
    JSON:encode(st.pin)
  )
  PIN.lockedUntil = 0
  post(p, "/session/close")
  H.advance(31000)
end
do
  -- lockout shared with PIN Lock: wrong PINs here count in PIN Lock's bucket
  PIN.fails = 0
  local p = open()
  for _ = 1, 5 do
    H.advance(11000)
    unlock(p, GUEST_PIN)
  end
  H.advance(31000)
  state(p)
  st = state(p)
  check(
    "five wrong PINs lock PIN entry (PIN Lock's lockout), chat unavailable",
    st.pin.reason == "locked" and st.chat.available == false,
    JSON:encode(st.pin)
  )
  PIN.lockedUntil, PIN.fails = 0, 0
  post(p, "/session/close")
  H.advance(31000)
end

-- ── [13] ─────────────────────────────────────────────────────────────────────
print("[13] no PIN in any AI Core request, frame, cloud body or log line")
OPC.Log_Level("5 - Trace")
OPC.Log_Mode("Print and Log")
local p = open()
code, doc = H.http("POST", q("/pin/done", p), { challenge_id = string.rep("1", 32), pin = OWNER_PIN })
check("a body with a pin key is refused (400) before anything reads it", code == 400 and doc.ok == false)
code, doc = H.http("POST", q("/ask", p), { question = "x", pin = OWNER_PIN })
check("…on /ask too", code == 400)
code = H.http("POST", q("/chat/unlock", p), { pin = OWNER_PIN })
check("…on /chat/unlock too", code == 400)
unlock(p, OWNER_PIN)
post(p, "/approvals/close")
EC.PRINT_DIAGNOSTICS()
local positive = #printed
print("positive control " .. OWNER_PIN)
local function anyLeak()
  local found = {}
  for i, line in ipairs(printed) do
    if
      i ~= positive + 1
      and line:find(OWNER_PIN, 1, true)
      and not line:find("^%s*ok ")
      and not line:find("^%s*FAIL ")
    then
      found[#found + 1] = line:sub(1, 80)
    end
  end
  for _, f in ipairs(H.sent) do
    if JSON:encode(f.params or {}):find(OWNER_PIN, 1, true) then
      found[#found + 1] = "frame " .. tostring(f.command)
    end
  end
  for _, c in ipairs(H.agent.cloudCalls) do
    if JSON:encode(c.body):find(OWNER_PIN, 1, true) then
      found[#found + 1] = "cloud " .. c.op
    end
  end
  for _, out in pairs(H.serverOut) do
    if out:find(OWNER_PIN, 1, true) then
      found[#found + 1] = "relay reply"
    end
  end
  if JSON:encode(H.persisted):find(OWNER_PIN, 1, true) then
    found[#found + 1] = "persist"
  end
  return found
end
check(
  "positive control: the capture sees a PIN that is printed",
  printed[positive + 1] and printed[positive + 1]:find(OWNER_PIN, 1, true) ~= nil
)
check(
  "…and the driver's own output (diagnostics) was captured",
  (function()
    for _, l in ipairs(printed) do
      if l:find("SmartBuildOS AI Core", 1, true) then
        return true
      end
    end
    return false
  end)()
)
local leaked = anyLeak()
check(
  "the owner PIN is in no log line, bus frame, cloud body, relay reply or persisted value",
  #leaked == 0,
  table.concat(leaked, " | ")
)
OPC.Log_Level("3 - Info")
OPC.Log_Mode("Off")
-- the grep guard: no AI Core code path names a pin field
local function readAll(path)
  local f = assert(io.open(path, "r"))
  local t = f:read("*a")
  f:close()
  return t
end
local files = { "drivers/smartbuildos-ai-core/driver.lua" }
local pipe = io.popen("ls src/aicore/*.lua")
for line in pipe:lines() do
  if not line:find("page%.lua$") then
    files[#files + 1] = line
  end
end
pipe:close()
local hits = {}
local allowed = 0
for _, path in ipairs(files) do
  local n = 0
  for line in readAll(path):gmatch("[^\n]+") do
    n = n + 1
    local code_ = line:gsub("%-%-.*$", "")
    if code_:find('k == "pin"', 1, true) then
      allowed = allowed + 1
    elseif
      code_:find("[%.%[\"']pin[\"'%]]?%s*[=%]]")
      or code_:find("%.pin%f[^%w_]")
      or code_:find("[{,]%s*pin%s*=")
      or code_:find('"pin"', 1, true)
    then
      hits[#hits + 1] = path .. ":" .. n
    end
  end
end
check(
  "grep guard: no `pin` field is read, written or sent in src/aicore or the driver",
  #hits == 0,
  table.concat(hits, ", ")
)
check("…the one allowed mention is the refusal of a body that carries one", allowed == 1, allowed)

-- ── [14] ─────────────────────────────────────────────────────────────────────
print("[14] detail level, verify_url origin, rate limits")
Properties["Touchscreen Detail"] = "Basic (status and approvals only)"
OPC.Touchscreen_Detail()
local bsc = open()
st = state(bsc)
check("Basic: no chat at all", st.chat.available == false and st.chat.message == Webui.TEXT.basic)
check("…approvals still shown", st.approvals.count == 3)
d = post(bsc, "/chat/unlock")
check("…unlock refused", d.ok == false and d.reason == "basic")
Properties["Touchscreen Detail"] = "Household (only if the homeowner allows it)"
local hh = open()
unlock(hh)
H.advance(61000)
post(hh, "/ask", { question = "When is the house empty?" })
check(
  "Household: the ask says detail household (the cloud decides whether the homeowner allows it)",
  lastCloud("ask").body.detail == "household"
)
Properties["Touchscreen Detail"] = "Standard (no household activity)"
PIN.verifyUrl = "http://10.9.9.9:47831/verify"
local mm = open()
H.advance(11000)
post(mm, "/chat/unlock")
st = state(mm)
check(
  "a verify_url on another host is never handed to the page",
  st.prompt == nil and st.notice == Webui.TEXT.pin_relay_mismatch,
  st.notice
)
PIN.verifyUrl = nil
H.advance(61000)
local rl = open()
unlock(rl)
local okN = 0
for i = 1, 6 do
  local r = post(rl, "/ask", { question = "Rate " .. i .. "?" })
  if r.ok then
    okN = okN + 1
  end
end
check("the webview asks at most 4 a minute", okN == 4, okN)
d = post(rl, "/ask", { question = string.rep("x", 501) })
H.advance(61000)
d = post(rl, "/ask", { question = string.rep("x", 501) })
check(
  "a question over 500 characters: too_long, plain words",
  d.ok == false and d.reason == "too_long" and d.message == Webui.TEXT.too_long
)
d = post(rl, "/ask", { question = "   " })
check("an empty question: refused", d.ok == false and d.reason == "empty")

-- ── [15] ─────────────────────────────────────────────────────────────────────
print("[15] the dealer's preset questions (round two, D-R2b)")
local P1 = "Is the wine cellar at the right temperature?"
local P2 = "Are all the shades closed?"
local P3 = "Is the pool heater on?"
local LONG = string.rep("Is every keypad in the guest wing answering ", 3):sub(1, 119) .. "?"
H.advance(61000)
local ack15 = H.config(H.learningOn({ touchscreen = { presets = { P1, P2 } } }), 9001)
check("a configuration with two presets is applied", ack15 and ack15.params.applied == "true")
local pl = open()
local pst, praw = state(pl)
check(
  "locked: no preset text in the /state bytes",
  pst.chat.locked == true
    and pst.chat.suggestions == nil
    and not praw:find("wine cellar", 1, true)
    and not praw:find("shades closed", 1, true),
  praw
)
local presetLeaks = {}
for _, r in ipairs({
  { "GET", "/state" },
  { "POST", "/chat/touch" },
  { "POST", "/pin/cancel" },
  { "POST", "/ask", { question = "x" } },
  { "POST", "/ask", { suggestion_id = "p1-1" } },
  { "POST", "/ask", { explain = true } },
  { "POST", "/approvals/refresh" },
  { "POST", "/approvals/next" },
  { "POST", "/approvals/close" },
  { "POST", "/chat/lock" },
  { "GET", "/app" },
  { "GET", "/ping" },
  { "POST", "/nope" },
}) do
  local _, _, body = H.http(r[1], q(r[2], pl), r[3])
  body = tostring(body or "")
  if body:find("wine cellar", 1, true) or body:find("shades closed", 1, true) then
    presetLeaks[#presetLeaks + 1] = r[1] .. " " .. r[2]
  end
end
check("no route returns preset text to a locked session", #presetLeaks == 0, table.concat(presetLeaks, ", "))
local asksBefore = #H.cloudOps("ask")
local lockedAsk = post(pl, "/ask", { suggestion_id = "p1-1" })
check(
  "a locked session cannot ask a preset (chat_locked, nothing sent)",
  lockedAsk.ok == false and lockedAsk.reason == "chat_locked" and #H.cloudOps("ask") == asksBefore
)
post(pl, "/pin/cancel")
H.advance(11000)
unlock(pl)
pst, praw = state(pl)
local sugs = pst.chat.suggestions or {}
check(
  "unlocked: the two presets first, then the three built-ins (five)",
  #sugs == 5
    and sugs[1].label == P1
    and sugs[2].label == P2
    and sugs[3].id == "working"
    and sugs[4].id == "today"
    and sugs[5].id == "attention",
  JSON:encode(sugs)
)
check("each preset id is p<index>-<rev>", tostring(sugs[1].id):match("^p1%-%d+$") ~= nil, sugs[1].id)
local p2id = sugs[2].id
local okAsk = post(pl, "/ask", { suggestion_id = p2id })
local presetAsk = lastCloud("ask")
check(
  "asking a preset sends EXACTLY its text through the ask path (channel touchscreen)",
  okAsk.ok == true
    and presetAsk.body.question == P2
    and presetAsk.body.channel == "touchscreen"
    and presetAsk.body.request_id == okAsk.id,
  presetAsk and JSON:encode(presetAsk.body)
)
check("the conversation shows the preset as the question", state(pl).chat.conversation[1].q == P2)
local p1old = sugs[1].id
H.advance(61000)
H.config(H.learningOn({ touchscreen = { presets = { P3, P2 } } }), 9002)
asksBefore = #H.cloudOps("ask")
local stale = post(pl, "/ask", { suggestion_id = p1old })
check(
  "a stale index after a config change: refused unknown_suggestion, never mapped to the new first question",
  stale.ok == false
    and stale.reason == "unknown_suggestion"
    and stale.message == Webui.TEXT.unknown_suggestion
    and #H.cloudOps("ask") == asksBefore,
  JSON:encode(stale)
)
sugs = state(pl).chat.suggestions
check("the new list is offered", sugs[1].label == P3 and sugs[2].label == P2 and sugs[1].id ~= p1old)
local fresh = post(pl, "/ask", { suggestion_id = sugs[1].id })
check("the fresh id asks the new question", fresh.ok == true and lastCloud("ask").body.question == P3)
asksBefore = #H.cloudOps("ask")
for _, bad in ipairs({ "p9-" .. sugs[1].id:match("%-(%d+)$"), "p0-1", "p1-", "p1", "P1-1", "p1-1-1" }) do
  local r = post(pl, "/ask", { suggestion_id = bad })
  check(
    "a malformed or out-of-range id (" .. bad .. "): unknown_suggestion",
    r.ok == false and r.reason == "unknown_suggestion"
  )
end
check("…and nothing was sent for any of them", #H.cloudOps("ask") == asksBefore)
local seven = {}
for i = 1, 7 do
  seven[i] = "Preset question number " .. i
end
local ack7 = H.config(H.learningOn({ touchscreen = { presets = seven } }), 9003)
check("a configuration with 7 presets is refused whole", ack7 and ack7.params.applied == "false")
sugs = state(pl).chat.suggestions
check("…and the page keeps the last valid list", #sugs == 5 and sugs[1].label == P3, JSON:encode(sugs))
H.config(H.learningOn({ touchscreen = { presets = { LONG } } }), 9004)
sugs = state(pl).chat.suggestions
check("a 120-character preset is offered whole", #LONG == 120 and sugs[1].label == LONG, sugs[1] and sugs[1].label)
local lastId = sugs[1].id
H.config(H.learningOn(), 9005)
sugs = state(pl).chat.suggestions
check("a document WITHOUT the key: no presets, the three built-ins only", #sugs == 3 and sugs[1].id == "working")
check(
  "…and the last preset id no longer resolves",
  post(pl, "/ask", { suggestion_id = lastId }).reason == "unknown_suggestion"
)

-- ── [16] ─────────────────────────────────────────────────────────────────────
print("[16] an unlock's outcome is never silent")
H.advance(61000) -- a fresh minute for the PIN prompt bucket
local u = open()
post(u, "/chat/unlock")
st = state(u)
check("setup: a PIN prompt for the chat", st.prompt ~= nil and st.prompt.challenge_id ~= nil, JSON:encode(st.prompt))
PIN.silentRedeem = true
check("(PIN Lock's /verify accepted the owner PIN)", PIN.verify(st.prompt.challenge_id, OWNER_PIN).ok == true)
post(u, "/pin/done", { challenge_id = st.prompt.challenge_id })
st = state(u)
check(
  "while PIN Lock has not answered the redeem, /state says the PIN is being checked",
  st.checking == true and st.chat.locked == true and st.prompt == nil,
  JSON:encode({ checking = st.checking, locked = st.chat.locked, notice = st.notice })
)
H.advance(9000) -- past the bus deadline (8 s)
st = state(u)
check(
  "a redeem PIN Lock never answers ends in plain words, not silence",
  st.checking == nil and st.chat.locked == true and st.notice == Webui.TEXT.pin_not_responding,
  JSON:encode({ checking = st.checking, notice = st.notice })
)
PIN.silentRedeem = false
post(u, "/chat/unlock")
st = state(u)
check("a new prompt", st.prompt ~= nil and st.prompt.challenge_id ~= nil and st.notice == nil, JSON:encode(st))
wait(61000, u)
st = state(u)
check(
  "a pad left unfinished past the challenge's minute says so",
  st.prompt == nil and st.notice == Webui.TEXT.expired and st.chat.locked == true,
  JSON:encode({ prompt = st.prompt, notice = st.notice })
)
post(u, "/chat/unlock")
local v16 = enterPin(u, OWNER_PIN)
st = state(u)
check(
  "…and the next unlock still works (no stale checking)",
  v16 and v16.ok == true and st.chat.locked == false and st.checking == nil,
  JSON:encode({ locked = st.chat.locked, checking = st.checking })
)

-- ── [17] ─────────────────────────────────────────────────────────────────────
print("[17] the command of every cloud body, and reading a refusal on the controller")
check(
  "(the scripted cloud holds the platform's command rule)",
  platformCommandOk("AI_ASK") and not platformCommandOk("TOUCHSCREEN_ASK") and not platformCommandOk("AI_ask")
)
local proof17 = { nonce = string.rep("a", 32), verified_at = os.time(), role = "owner" }
local built = {
  ask = Webui.askBody("aic-1", "q", "standard"),
  approvals_pending = Webui.pendingBody("aic-1"),
  approval_detail = Webui.detailBody("aic-1", REF_A, proof17),
  approval_decide = Webui.decideBody("aic-1", REF_A, "approve", HASH_A, proof17),
}
for _, op in ipairs({ "ask", "approvals_pending", "approval_detail", "approval_decide" }) do
  local c = built[op].command
  local name = type(c) == "string" and c:match("^AI_([A-Z_]+)$") or nil
  check(
    op .. ": its command is one the platform accepts (AI_ and 2 to 40 capitals or underscores)",
    name ~= nil and #name >= Webui.COMMAND_NAME.min and #name <= Webui.COMMAND_NAME.max and platformCommandOk(c),
    c
  )
end
check(
  "no touchscreen request of the whole run was refused for its command",
  CLOUD.commandRefused == 0,
  CLOUD.commandRefused
)
H.advance(61000)
local w = open()
st = state(w)
check(
  "the approvals list is read (not 'could not read that request')",
  st.approvals.count == 3 and st.approvals.message ~= Webui.TEXT.invalid_args,
  JSON:encode(st.approvals)
)
unlock(w)
local QUESTION17 = "Is the wine cellar door closed?"
local r17 = post(w, "/ask", { question = QUESTION17 })
st = state(w)
check(
  "a touchscreen question is accepted and waits for its answer",
  r17.ok == true and st.chat.conversation[#st.chat.conversation].state == "pending",
  JSON:encode(st.chat.conversation)
)
check(
  "…sent as AI_TOUCHSCREEN_ASK",
  lastCloud("ask").body.command == "AI_TOUCHSCREEN_ASK",
  lastCloud("ask").body.command
)
-- A body the platform's validator refuses (what an older build's command
-- got): the page says so in words, and the codes can be read in Composer.
CLOUD.refuse.ask = "invalid_args"
CLOUD.refuseResult.ask = { reason = "invalid_fields", fields = { "command", "Not A Field Name", QUESTION17 } }
H.advance(61000)
post(w, "/chat/touch")
r17 = post(w, "/ask", { question = QUESTION17 })
st = state(w)
local last17 = st.chat.conversation[#st.chat.conversation]
check(
  "a body the platform could not read: 'could not read that request', not the bare fallback",
  r17.ok == true and last17.state == "refused" and last17.message == Webui.TEXT.invalid_args,
  JSON:encode(last17)
)
CLOUD.refuse.ask, CLOUD.refuseResult.ask = nil, nil
CLOUD.refuse.approvals_pending = "invalid_args"
CLOUD.refuseResult.approvals_pending = { reason = "invalid_args", detail = "invalid_fields", fields = { "command" } }
H.advance(61000)
post(w, "/approvals/refresh")
st = state(w)
check("the approvals list refused: said on the page", st.approvals.message == Webui.TEXT.invalid_args)
check(
  "…and Touchscreen Approvals says what came back, not 'approvals off'",
  tostring(H.prop("Touchscreen Approvals")):find(
    "approvals not available (invalid_args, detail invalid_fields, fields command)",
    1,
    true
  ) ~= nil,
  H.prop("Touchscreen Approvals")
)
local before17 = #printed
EC.PRINT_DIAGNOSTICS()
local diag17 = table.concat(printed, "\n", before17 + 1)
check(
  "Print Diagnostics names the last refusal of each: code, reason and field names",
  diag17:find("touchscreen ask not accepted: invalid_args, reason invalid_fields, fields command (", 1, true) ~= nil
    and diag17:find(
        "touchscreen approvals_pending not accepted: invalid_args, detail invalid_fields, fields command (",
        1,
        true
      )
      ~= nil,
  diag17:match("touchscreen ask[^\n]*")
)
check(
  "…codes only: no question, nothing that is not a field name",
  diag17:find(QUESTION17, 1, true) == nil and diag17:find("Not A Field Name", 1, true) == nil
)
CLOUD.refuse.approvals_pending, CLOUD.refuseResult.approvals_pending = nil, nil
H.advance(61000)
post(w, "/approvals/refresh")
check(
  "once the list is read again the property stops saying it",
  tostring(H.prop("Touchscreen Approvals")):find("not available", 1, true) == nil,
  H.prop("Touchscreen Approvals")
)

-- ── [18] ─────────────────────────────────────────────────────────────────────
print("[18] the answer as the platform sends it: job id and the relay's request id")
-- What the platform puts in deliver_result (jobs.ts deliverJob): job_id = the
-- job the accept answer named, request_id = the request_id of the FRAME the
-- Agent relayed (the module client's per-attempt id) — never the ask's own
-- request id, which travels as idempotency_key and body.request_id.
local function askAndFrame(session, question)
  local r = post(session, "/ask", { question = question })
  local op = lastCloud("ask")
  return r, op, "job-" .. #H.agent.cloudCalls
end
local function platformAnswer(op, jobId, text, n)
  return H.operation("deliver_result", {
    response_id = "resp-18-" .. n,
    job_id = jobId,
    request_id = op.request_id,
    text = text,
    kind = "answer",
    pending_approvals = 0,
  })
end
H.advance(61000)
local z = open()
unlock(z)
local resp18, fired18 = H.vars.AI_LAST_RESPONSE, H.firedCount(1)
local r18, op18, job18 = askAndFrame(z, "Is the pool heater on?")
check(
  "(the relay's request id is not the ask's id; the ask's id is the idempotency key and body.request_id)",
  r18.ok == true and op18.request_id ~= r18.id and op18.idempotency_key == r18.id and op18.body.request_id == r18.id,
  tostring(op18.request_id) .. " / " .. tostring(r18.id)
)
check(
  "deliver_result with the job id and the relay's request id: Completed",
  H.finalState(platformAnswer(op18, job18, "The pool heater is off.", 1)) == "Completed"
)
st = state(z)
local e18 = st.chat.conversation[#st.chat.conversation]
check(
  "…the answer reaches the page that asked",
  e18.state == "answered" and e18.a == "The pool heater is off.",
  JSON:encode(e18)
)
check(
  "…and is NOT published as a Composer answer (AI_LAST_RESPONSE, AI Response Ready)",
  H.vars.AI_LAST_RESPONSE == resp18 and H.firedCount(1) == fired18,
  H.vars.AI_LAST_RESPONSE
)
-- The wait runs out, then the answer arrives: shown to the session, late.
H.advance(61000)
post(z, "/chat/touch")
r18, op18, job18 = askAndFrame(z, "Is the spa covered?")
wait(290000, z)
post(z, "/chat/touch")
wait(15000, z)
st = state(z)
e18 = st.chat.conversation[#st.chat.conversation]
check(
  "after 5 minutes without an answer the page says so",
  e18.state == "failed" and e18.message == Webui.TEXT.cloud_unreachable,
  JSON:encode(e18)
)
platformAnswer(op18, job18, "The spa is covered.", 2)
st = state(z)
e18 = st.chat.conversation[#st.chat.conversation]
check(
  "an answer that arrives after that is still shown to the session that asked",
  e18.state == "answered" and e18.a == "The spa is covered." and e18.message == nil,
  JSON:encode(e18)
)
check("…never as a Composer answer", H.vars.AI_LAST_RESPONSE == resp18 and H.firedCount(1) == fired18)
-- The page closes while its question is out: the answer is dropped.
H.advance(61000)
post(z, "/chat/touch")
r18, op18, job18 = askAndFrame(z, "Did the gate close?")
post(z, "/session/close")
check(
  "a closed page's answer: deliver_result Completed",
  H.finalState(platformAnswer(op18, job18, "The gate is closed.", 3)) == "Completed"
)
check(
  "…dropped: not in AI_LAST_RESPONSE, no AI Response Ready, not persisted",
  H.vars.AI_LAST_RESPONSE == resp18
    and H.firedCount(1) == fired18
    and JSON:encode(H.persisted):find("gate is closed", 1, true) == nil,
  H.vars.AI_LAST_RESPONSE
)
before17 = #printed
EC.PRINT_DIAGNOSTICS()
diag17 = table.concat(printed, "\n", before17 + 1)
check(
  "Print Diagnostics counts the touchscreen asks (sent, waiting, dropped), no text of any",
  diag17:find("touchscreen asks: %d+ sent, 0 waiting for an answer, %d+ answered while locked, 1 dropped") ~= nil
    and diag17:find("gate", 1, true) == nil
    and diag17:find("spa", 1, true) == nil,
  diag17:match("touchscreen asks[^\n]*")
)
H.operation("deliver_result", {
  response_id = "resp-18-c",
  job_id = "job-unknown",
  request_id = "some-relay-id",
  text = "A Composer answer, later.",
})
check(
  "an answer for no touchscreen ask is still a Composer answer",
  H.vars.AI_LAST_RESPONSE == "A Composer answer, later."
)

check("nothing reached equipment in the whole run", #H.equipment == 0, #H.equipment)

print = realPrint
print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
