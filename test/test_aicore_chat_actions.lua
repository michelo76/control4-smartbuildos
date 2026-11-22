-- AI Core: actions from the touchscreen chat ("chat actions v1"; pure:
-- src/aicore/chatactions.lua and src/aicore/webui.lua with injected fakes).
--
--   [1] the capability; deliver_result `actions` validation
--   [2] owner_proof only from a live owner proof (every mode and detail),
--       stripped by the shared retry
--   [3] cards: shown only to the elevated session that asked; removed on
--       every kind of lock; hidden while touchscreen approvals are off
--   [4] Confirm: approval_detail then approval_decide with the session
--       verification and the detail's args_hash; double tap; not elevated
--   [5] outcomes: Done, Failed (the platform's sentence), still pending,
--       no confirmation after 30 s, Cancel
--   [6] refusals: Use PIN, withdrawn, rate limit, 300 s, medium risk; the
--       PIN fallback opens the existing review for that ref
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

require("drivers-common-public.global.lib")
JSON = JSON or require("JSON")
local V = require("aicore.vocab")
local ChatActions = require("aicore.chatactions")
local Operations = require("aicore.operations")
local Webui = require("aicore.webui")

local REF_A = "11111111-2222-4333-8444-555555555555"
local REF_B = "66666666-7777-4888-9999-aaaaaaaaaaaa"
local REF_C = "cccccccc-7777-4888-9999-aaaaaaaaaaaa"
local HASH = string.rep("ab", 32)

print("[1] the capability and `actions`")
local reg = table.concat(V.registeredCommands(), ",")
check("chat_actions_v1 declared next to chat_v2", reg:find("chat_v2,chat_actions_v1", 1, true) ~= nil, reg)
check("…and is not an operation", Operations.parse("chat_actions_v1", {}) == nil)
local good = { ref = REF_A, title = "Turn off the patio lights", detail = "All 4 patio lights", expires_in = 600 }
local a, d = ChatActions.actions({ good })
check("a valid item kept, normalised", a and a[1].ref == REF_A and a[1].expires_in == 600 and d == 0)
check("…as a JSON string too", ChatActions.actions(JSON:encode({ good })) ~= nil)
local function bad(change)
  local x = {}
  for k, v in pairs(good) do
    x[k] = v
  end
  for k, v in pairs(change) do
    x[k] = v
  end
  if change.ref == false then
    x.ref = nil
  end
  local out, n = ChatActions.actions({ x })
  return out == nil and n == 1
end
check("an unknown key dropped", bad({ command = "LOCK" }))
check("a ref that is not a uuid dropped", bad({ ref = "lock-front-door" }))
check("no ref dropped", bad({ ref = false }))
check("markup in the title dropped", bad({ title = "<b>x</b>" }))
check("a title over 80 code points dropped", bad({ title = string.rep("é", 81) }))
check(
  "an 80-code-point title kept",
  ChatActions.actions({ { ref = REF_A, title = string.rep("é", 80), expires_in = 60 } }) ~= nil
)
check("a detail over 300 code points dropped", bad({ detail = string.rep("a", 301) }))
check("a zero-width character dropped", bad({ title = "Lights\226\128\139 off" }))
check("expires_in 0 dropped", bad({ expires_in = 0 }))
check("expires_in over 1800 dropped", bad({ expires_in = 1801 }))
check("expires_in not whole dropped", bad({ expires_in = 1.5 }))
local four = {}
for i = 1, 4 do
  four[i] = { ref = string.format("%08d-2222-4333-8444-555555555555", i), title = "A" .. i, expires_in = 60 }
end
a, d = ChatActions.actions(four)
check("four items: three kept, one counted", a and #a == 3 and d == 1)
a, d = ChatActions.actions({ good, good })
check("a ref twice: once", a and #a == 1 and d == 1)
local op = Operations.parse("deliver_result", { response_id = "r", text = "T.", actions = { good, { ref = "x" } } })
check(
  "deliver_result accepts `actions`; an invalid item is dropped, never the answer",
  op and op.text == "T." and #op.actions == 1 and op.actions_dropped == 1
)
op = Operations.parse("deliver_result", {
  response_id = "r",
  text = "T.",
  channel = "touchscreen",
  display = { { t = "note", text = "x" } },
  actions = { good },
})
check("…together with channel and display", op and op.channel == "touchscreen" and op.display and op.actions)
check(
  "execution: completed = done; failed / expired = failed with the sentence; pending or absent = pending",
  ChatActions.executionOf({ execution = { state = "completed" } }) == "done"
    and select(2, ChatActions.executionOf({ execution = { state = "failed", message = "The controller failed." } })) == "The controller failed."
    and ChatActions.executionOf({ execution = { state = "expired", reason = "expired" } }) == "failed"
    and ChatActions.executionOf({ execution = { state = "pending" } }) == "pending"
    and ChatActions.executionOf({ ref = REF_A }) == "pending"
)

-- ── a pure page relay with fakes ────────────────────────────────────────────
local clock = 1800000000
local seq = 0
local cloud = {}
local mode, detail, pinReady, approvalsOn = "open", "standard", true, true
local refuseAsk = nil -- function(body) -> answer
local DETAIL = {} -- [ref] = function(body) -> answer
local DECIDE = {} -- [ref] = function(body) -> answer
local lastJob
local DEPS = {
  now = function()
    return clock
  end,
  newHex = function()
    seq = seq + 1
    return string.format("%032x", seq)
  end,
  newRequestId = function()
    seq = seq + 1
    return "aic-" .. seq
  end,
  facts = function()
    return { licensed = true, provider_configured = true, online = true, learning_active = true }
  end,
  detail = function()
    return detail
  end,
  access = function()
    return mode
  end,
  relayHost = function()
    return "h"
  end,
  pinAvailability = function(cb)
    cb(pinReady and { available = true, reason = "ready" } or { available = false, reason = "pin_not_installed" })
  end,
  pinRequest = function(cap, args, cb)
    if cap == "pinlock.challenge" then
      seq = seq + 1
      cb({
        status = "ok",
        result = { challenge_id = string.format("%032x", seq), verify_url = "http://h:47831/verify" },
      })
    else
      cb({ status = "ok", result = { verified = true, role = "owner", verified_at = clock } })
    end
  end,
  cloud = function(o, body, cb)
    cloud[#cloud + 1] = { op = o, body = body }
    if o == "ask" then
      lastJob = "job-" .. #cloud
      cb(refuseAsk and refuseAsk(body) or { status = "ok", result = { accepted = true, job_id = lastJob } })
    elseif o == "approvals_pending" then
      cb({ status = "ok", result = { enabled = approvalsOn, count = 1, eligible = {} } })
    elseif o == "approval_detail" then
      local f = DETAIL[body.ref]
      cb(f and f(body) or {
        status = "ok",
        result = { ref = body.ref, title = "T", risk = "low", args_hash = HASH },
      })
    elseif o == "approval_decide" then
      local f = DECIDE[body.ref]
      cb(f and f(body) or { status = "ok", result = { ref = body.ref, status = "queued" } })
    end
  end,
  take = function()
    return true
  end,
  appHtml = function()
    return "<html></html>"
  end,
}
local TOKEN = string.rep("a", 32)
local ui
local function http(method, path, s, body)
  local r = ui:route({
    method = method,
    path = path,
    query = { k = TOKEN, s = s },
    body = body and JSON:encode(body) or "",
  }, TOKEN)
  return JSON:decode(r.body)
end
local function open()
  return http("POST", "/session").s
end
local function state(s)
  return http("GET", "/state", s)
end
local function unlock(s)
  http("POST", "/chat/unlock", s)
  local st = state(s)
  return http("POST", "/pin/done", s, { challenge_id = st.prompt.challenge_id })
end
local function lastOf(o)
  for i = #cloud, 1, -1 do
    if cloud[i].op == o then
      return cloud[i].body
    end
  end
end
local function count(o)
  local n = 0
  for _, c in ipairs(cloud) do
    n = n + (c.op == o and 1 or 0)
  end
  return n
end
local function step(seconds, s)
  while seconds > 0 do
    local x = math.min(seconds, 20)
    clock = clock + x
    seconds = seconds - x
    state(s)
  end
end
local function fresh(m)
  mode, detail, pinReady, approvalsOn = m or "open", "standard", true, true
  refuseAsk, DETAIL, DECIDE = nil, {}, {}
  clock = clock + 3600
  ui = Webui.new(DEPS)
end
--- An elevated session with an answer offering `list` (default: A, B).
local function offered(list)
  local s = open()
  unlock(s)
  http("POST", "/ask", s, { question = "Turn off the patio lights?" })
  ui:deliver(nil, "I can do that.", lastJob, {
    actions = list or {
      { ref = REF_A, title = "Turn off the patio lights", detail = "4 lights", expires_in = 600 },
      { ref = REF_B, title = "Set the den to 21 degrees", expires_in = 600 },
    },
  })
  return s
end
local function cards(s)
  local st = state(s)
  local e = st.chat and st.chat.conversation and st.chat.conversation[#st.chat.conversation]
  return e and e.actions, st
end
local function card(s, ref)
  for _, c in ipairs(cards(s) or {}) do
    if c.ref == ref then
      return c
    end
  end
end

print("[2] owner_proof")
for _, m in ipairs({ "open", "owner_pin" }) do
  for _, dl in ipairs({ "standard", "household" }) do
    fresh(m)
    detail = dl
    local s = open()
    if m == "open" then
      http("POST", "/ask", s, { question = "Lights?" })
      check(m .. ", " .. dl .. ", not unlocked: no owner_proof", lastOf("ask").owner_proof == nil)
      check("…and no unlock", lastOf("ask").unlock == nil)
    end
    unlock(s)
    clock = clock + 16
    http("POST", "/ask", s, { question = "Lights?" })
    local p = lastOf("ask").owner_proof
    check(
      m .. ", " .. dl .. ", owner-unlocked: owner_proof = the four keys, method pin_lock",
      type(p) == "table"
        and #p.nonce == 32
        and p.role == "owner"
        and p.method == "pin_lock"
        and type(p.verified_at) == "number"
    )
    check("…unlock only at household", (lastOf("ask").unlock ~= nil) == (dl == "household"))
    http("POST", "/chat/lock", s)
    clock = clock + 16
    if m == "open" then
      http("POST", "/ask", s, { question = "Again?" })
      check("…after Lock: no owner_proof", lastOf("ask").owner_proof == nil)
    end
  end
end
fresh("open")
local s0 = open()
for _, pinOk in ipairs({ true, false }) do
  pinReady = pinOk
  ui:checkPin(true)
  clock = clock + 61
  http("POST", "/ask", s0, { question = "Lights?" })
  check("open, never unlocked, PIN Lock " .. tostring(pinOk) .. ": no owner_proof", lastOf("ask").owner_proof == nil)
end
fresh("open")
refuseAsk = function(body)
  if body.owner_proof ~= nil then
    return {
      status = "error",
      error_code = "invalid_args",
      result = { reason = "unknown_fields", fields = { "owner_proof" } },
    }
  end
end
local sp = open()
unlock(sp)
local before = count("ask")
http("POST", "/ask", sp, { question = "Lights?" })
check(
  "an old platform: one retry without owner_proof, thread kept",
  count("ask") == before + 2 and lastOf("ask").owner_proof == nil and lastOf("ask").thread ~= nil
)
clock = clock + 16
http("POST", "/ask", sp, { question = "Again?" })
check("…then never sent again in the run (one send)", count("ask") == before + 3 and lastOf("ask").owner_proof == nil)
fresh("owner_pin")
detail = "basic"
check("Basic: no chat, nothing to carry it", ui:chatAvailable() == false)

print("[3] cards: who sees them, and when they go")
fresh("open")
local s = offered()
local list = cards(s)
check("an elevated session sees its two cards", list and #list == 2 and list[1].state == "offered")
check("…with a countdown", list[1].expires_in == 600)
check("…and Confirm (no Use PIN yet)", list[1].needs_pin == nil)
local other = open()
check("another session sees none", #state(other).chat.conversation == 0)
approvalsOn = false
ui.approvals.at = nil
state(s)
check("touchscreen approvals switched off: no stale card", cards(s) == nil)
approvalsOn = true
ui.approvals.at = nil
state(s)
check("…back on: shown again", cards(s) ~= nil)
-- a card offered to a session that is no longer unlocked is dropped
fresh("owner_pin")
local s2 = open()
unlock(s2)
http("POST", "/ask", s2, { question = "Lights?" })
local job2 = lastJob
http("POST", "/chat/lock", s2)
ui:deliver(nil, "Answer while locked.", job2, { actions = { { ref = REF_A, title = "T", expires_in = 60 } } })
clock = clock + 61
unlock(s2)
local e2 = state(s2).chat.conversation[1]
check("Owner PIN: an answer held while locked comes back without its card", e2.a ~= nil and e2.actions == nil)
check("…counted as dropped", ui.counters.actions_dropped == 1)
-- an answer asked open (not elevated) never gets a card
fresh("open")
local s3 = open()
http("POST", "/ask", s3, { question = "Lights?" })
ui:deliver(nil, "Open answer.", lastJob, { actions = { { ref = REF_A, title = "T", expires_in = 60 } } })
check("an open (not unlocked) answer gets no card", state(s3).chat.conversation[1].actions == nil)
-- every kind of lock removes the cards
local locks = {
  {
    "the Lock button",
    function(x)
      http("POST", "/chat/lock", x)
    end,
  },
  {
    "the page hidden",
    function(x)
      http("POST", "/chat/lock", x, { hidden = true })
    end,
  },
  {
    "5 minutes without use",
    function(x)
      step(Webui.LIMITS.unlock_idle_seconds + 1, x)
    end,
  },
  {
    "30 minutes after the PIN",
    function(x)
      local t0 = clock
      while clock - t0 < Webui.LIMITS.unlock_max_seconds + 1 do
        step(60, x)
        http("POST", "/chat/touch", x)
      end
    end,
  },
  {
    "PIN Lock gone",
    function(x)
      pinReady = false
      ui:checkPin(true)
    end,
  },
}
for _, m in ipairs({ "open", "owner_pin" }) do
  for _, l in ipairs(locks) do
    fresh(m)
    local x = offered()
    l[2](x)
    pinReady = true
    local st = state(x)
    local any = false
    for _, e in ipairs((st.chat and st.chat.conversation) or {}) do
      any = any or e.actions ~= nil
    end
    check(m .. ": " .. l[1] .. " removes the cards", not any and ui.counters.actions_removed >= 2)
    check(
      "…and nothing can be decided",
      http("POST", "/chat/action", x, { ref = REF_A, decision = "approve" }).ok == false
    )
  end
end

print("[4] Confirm")
fresh("open")
s = offered()
local proof = ui.sessions[s].proofs.chat_view
local r = http("POST", "/chat/action", s, { ref = REF_A, decision = "approve" })
check("Confirm accepted", r.ok == true)
local det, dec = lastOf("approval_detail"), lastOf("approval_decide")
check(
  "approval_detail first, with the session verification",
  det.ref == REF_A
    and det.verification.method == "pin_lock_session"
    and det.verification.nonce == proof.nonce
    and det.verification.verified_at == proof.verified_at
    and det.verification.role == "owner"
)
check(
  "then approval_decide approve with the detail's args_hash and the same verification",
  dec.ref == REF_A
    and dec.decision == "approve"
    and dec.args_hash == HASH
    and dec.verification.method == "pin_lock_session"
    and dec.verification.nonce == proof.nonce
)
check("the card says Sent", card(s, REF_A).state == "sent")
check("…not Done", card(s, REF_A).state ~= "done")
local nDec = count("approval_decide")
r = http("POST", "/chat/action", s, { ref = REF_A, decision = "approve" })
check(
  "a double tap is refused, nothing sent again",
  r.ok == false and r.reason == "action_busy" and count("approval_decide") == nDec
)
r = http("POST", "/chat/action", s, { ref = "99999999-2222-4333-8444-555555555555", decision = "approve" })
check("a ref this session was not offered: refused, nothing sent", r.ok == false and r.reason == "action_gone")
r = http("POST", "/chat/action", s, { ref = REF_B, decision = "maybe" })
check("a decision that is not approve/decline: refused", r.ok == false and r.reason == "bad_decision")
r = http("POST", "/chat/action", s, { ref = REF_B, decision = "approve", command = "UNLOCK" })
check("an extra body key: refused whole", r.ok == false and r.reason == "invalid_args")
-- not elevated
fresh("open")
s = offered()
local beforeD = count("approval_decide") + count("approval_detail")
http("POST", "/chat/lock", s)
r = http("POST", "/chat/action", s, { ref = REF_A, decision = "approve" })
check(
  "after Lock: refused, nothing sent",
  r.ok == false and count("approval_decide") + count("approval_detail") == beforeD
)
-- locked between the detail and the decision: nothing decided
fresh("open")
s = offered()
DETAIL[REF_A] = function(body)
  http("POST", "/chat/lock", s)
  return { status = "ok", result = { ref = body.ref, risk = "low", args_hash = HASH } }
end
beforeD = count("approval_decide")
http("POST", "/chat/action", s, { ref = REF_A, decision = "approve" })
check("locked while the detail was out: no decision sent", count("approval_decide") == beforeD)
-- a detail that does not match is never decided
fresh("open")
s = offered()
DETAIL[REF_A] = function()
  return { status = "ok", result = { ref = REF_B, risk = "low", args_hash = HASH } }
end
beforeD = count("approval_decide")
http("POST", "/chat/action", s, { ref = REF_A, decision = "approve" })
check(
  "a detail for another ref: not decided, refused",
  count("approval_decide") == beforeD and card(s, REF_A).state == "refused"
)

print("[5] outcomes")
local function sent(execution, afterDelta)
  fresh("open")
  local after = clock + (afterDelta or 0)
  local x = offered()
  DETAIL[REF_A] = function(body)
    if body.verification.method ~= "pin_lock_session" then
      return { status = "error", error_code = "not_permitted", result = { reason = "verification_stale" } }
    end
    local res = { ref = body.ref, risk = "low", args_hash = HASH }
    if count("approval_decide") > 0 and clock >= after then
      res.execution = execution
    end
    return { status = "ok", result = res }
  end
  http("POST", "/chat/action", x, { ref = REF_A, decision = "approve" })
  return x
end
s = sent({ state = "completed" })
check("(sent)", card(s, REF_A).state == "sent")
step(2, s)
check("Done only from execution completed", card(s, REF_A).state == "done", card(s, REF_A).state)
check("…every poll is a session-verified detail", lastOf("approval_detail").verification.method == "pin_lock_session")
s = sent({ state = "failed", reason = "device_not_found", message = "The patio lights did not answer." })
step(2, s)
local c = card(s, REF_A)
check(
  "Failed with the platform's sentence, verbatim",
  c.state == "failed" and c.message == "The patio lights did not answer."
)
s = sent({ state = "expired", reason = "expired", message = "The proposal expired." })
step(2, s)
check("expired = Failed with its sentence", card(s, REF_A).state == "failed")
s = sent({ state = "pending" })
step(10, s)
check("execution pending: still Sent", card(s, REF_A).state == "sent")
local polls = count("approval_detail")
step(1, s)
check("…polled at most every 2 s", count("approval_detail") - polls <= 1)
s = sent(nil)
step(31, s)
c = card(s, REF_A)
check(
  "no execution within 30 s: 'No confirmation from the controller yet', never Done",
  c.state == "unconfirmed" and c.message == "No confirmation from the controller yet."
)
local nPolls = count("approval_detail")
step(10, s)
check("…and polling stops", count("approval_detail") == nPolls)
check("at most 15 polls per card", nPolls <= 2 + 15)
-- a late execution after its arrival in time
s = sent({ state = "completed" }, 6)
step(4, s)
check("execution reported late: Sent until then", card(s, REF_A).state == "sent")
step(4, s)
check("…then Done", card(s, REF_A).state == "done")
-- Cancel
fresh("open")
s = offered()
r = http("POST", "/chat/action", s, { ref = REF_B, decision = "decline" })
dec = lastOf("approval_decide")
check(
  "Cancel: the decline with the session verification and args_hash",
  r.ok and dec.decision == "decline" and dec.args_hash == HASH and dec.verification.method == "pin_lock_session"
)
check("…the card says Declined", card(s, REF_B).state == "declined")
check(
  "…and cannot be confirmed afterwards",
  http("POST", "/chat/action", s, { ref = REF_B, decision = "approve" }).ok == false
)
-- a decision the platform did not queue
fresh("open")
s = offered()
DECIDE[REF_A] = function(body)
  return { status = "ok", result = { ref = body.ref, status = "expired" } }
end
http("POST", "/chat/action", s, { ref = REF_A, decision = "approve" })
check("a decision answered 'expired': Failed with its sentence", card(s, REF_A).state == "failed")

print("[6] refusals and the PIN fallback")
local function refusedWith(reason, code, onDetail)
  fresh("open")
  local x = offered()
  local f = function()
    return { status = "error", error_code = code or "not_permitted", result = { reason = reason } }
  end
  if onDetail then
    DETAIL[REF_A] = f
  else
    DECIDE[REF_A] = f
  end
  http("POST", "/chat/action", x, { ref = REF_A, decision = "approve" })
  return x, card(x, REF_A)
end
for _, reason in ipairs({ "session_risk_too_high", "session_proposal_too_old" }) do
  local _, cc = refusedWith(reason)
  check(
    reason .. ": its sentence and Use PIN",
    cc.state == "refused" and cc.needs_pin and cc.message == Webui.TEXT[reason]
  )
end
local x, cc = refusedWith("rate_limited", "rate_limited")
check(
  "rate_limited: its sentence and Use PIN kept",
  cc.state == "refused" and cc.needs_pin and cc.message == Webui.TEXT.rate_limited
)
for _, reason in ipairs({ "session_not_bound", "session_stale" }) do
  x, cc = refusedWith(reason, nil, true)
  check(reason .. " (on the detail): the sentence, the card withdrawn", cc.state == "withdrawn" and not cc.needs_pin)
  check("…nothing decided", http("POST", "/chat/action", x, { ref = REF_A, decision = "approve" }).ok == false)
end
-- this driver: a medium-risk detail is never one-tapped
fresh("open")
s = offered()
DETAIL[REF_A] = function(body)
  return { status = "ok", result = { ref = body.ref, risk = "medium", args_hash = HASH } }
end
beforeD = count("approval_decide")
http("POST", "/chat/action", s, { ref = REF_A, decision = "approve" })
check("a medium-risk detail: no decision, Use PIN", count("approval_decide") == beforeD and card(s, REF_A).needs_pin)
-- 300 s after the answer: Confirm becomes Use PIN (the card stays until it expires)
fresh("open")
s = offered()
step(ChatActions.LIMITS.one_tap_seconds - 20, s)
http("POST", "/chat/touch", s)
check("before 300 s: Confirm", card(s, REF_A).needs_pin == nil)
step(21, s)
c = card(s, REF_A)
check("after 300 s: Use PIN, the card still offered", c.needs_pin and c.state == "offered" and c.expires_in > 0)
beforeD = count("approval_detail")
r = http("POST", "/chat/action", s, { ref = REF_A, decision = "approve" })
check(
  "…a tap on approve then sends nothing",
  r.ok == false and r.reason == "action_needs_pin" and count("approval_detail") == beforeD
)
-- expiry
fresh("open")
s = offered({ { ref = REF_C, title = "Short", expires_in = 30 } })
step(31, s)
check("the countdown runs out: expired", card(s, REF_C).state == "expired" and card(s, REF_C).expires_in == nil)
check(
  "…and cannot be decided",
  http("POST", "/chat/action", s, { ref = REF_C, decision = "approve" }).reason == "action_expired"
)
-- the PIN fallback: the existing approvals review, one PIN for that ref
x, cc = refusedWith("session_risk_too_high")
local ch = 0
local realPin = DEPS.pinRequest
DEPS.pinRequest = function(cap, args, cb)
  if cap == "pinlock.challenge" then
    ch = ch + 1
    check(
      "Use PIN asks PIN Lock for an APPROVAL challenge bound to that ref",
      args.purpose == "approval" and args.subject == REF_A
    )
  end
  realPin(cap, args, cb)
end
r = http("POST", "/approvals/next", x, { ref = REF_A })
check("Use PIN: the review starts", r.ok == true and ch == 1)
local st = state(x)
http("POST", "/pin/done", x, { challenge_id = st.prompt.challenge_id })
det = lastOf("approval_detail")
check(
  "…then the existing detail with a PIN verification (method pin_lock)",
  det.ref == REF_A and det.verification.method == "pin_lock"
)
check("…and the review shows the item", state(x).review ~= nil)
DEPS.pinRequest = realPin
r = http("POST", "/approvals/next", x, { ref = REF_B })
check("Use PIN for a card that does not need it: refused", r.ok == false)
check("Use PIN for a ref never offered: refused", http("POST", "/approvals/next", x, { ref = REF_C }).ok == false)
check(
  "Print Diagnostics line counts actions, no text",
  ui:chatLine():find("chat_actions_v1", 1, true) ~= nil and not ui:chatLine():find("patio", 1, true)
)

print(string.format("%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
