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
local good =
  { ref = REF_A, title = "Turn off the patio lights", detail = "All 4 patio lights", expires_in = 600, tap_in = 300 }
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
  if change.tap_in == false then
    x.tap_in = nil
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
  ChatActions.actions({ { ref = REF_A, title = string.rep("é", 80), expires_in = 60, tap_in = 300 } }) ~= nil
)
check("a detail over 300 code points dropped", bad({ detail = string.rep("a", 301) }))
check("a zero-width character dropped", bad({ title = "Lights\226\128\139 off" }))
check("expires_in 0 dropped", bad({ expires_in = 0, tap_in = 300 }))
check("expires_in over 1800 dropped", bad({ expires_in = 1801, tap_in = 300 }))
check("expires_in not whole dropped", bad({ expires_in = 1.5 }))
check("tap_in missing: dropped (required)", bad({ tap_in = false }))
check("tap_in over 300 dropped", bad({ tap_in = 301 }))
check("tap_in negative dropped", bad({ tap_in = -1 }))
check("tap_in not whole dropped", bad({ tap_in = 2.5 }))
check("tap_in as text dropped", bad({ tap_in = "300" }))
check(
  "tap_in 0 kept (the PIN flow from the start)",
  (ChatActions.actions({ { ref = REF_A, title = "Scene", expires_in = 60, tap_in = 0 } }) or {})[1] ~= nil
)
local four = {}
for i = 1, 4 do
  four[i] =
    { ref = string.format("%08d-2222-4333-8444-555555555555", i), title = "A" .. i, expires_in = 60, tap_in = 300 }
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
local eligibleRefs = nil -- refs approvals_pending lists for this screen (nil: REF_A, REF_B, REF_C)
local deferCloud = nil -- function(o, body, cb) -> true when it keeps the callback (asynchronous answers)
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
    cloud[#cloud + 1] = { op = o, body = body, at = clock }
    if deferCloud and deferCloud(o, body, cb) then
      return
    end
    if o == "ask" then
      lastJob = "job-" .. #cloud
      cb(refuseAsk and refuseAsk(body) or { status = "ok", result = { accepted = true, job_id = lastJob } })
    elseif o == "approvals_pending" then
      local el = {}
      for _, r0 in ipairs(eligibleRefs or { REF_A, REF_B, REF_C }) do
        el[#el + 1] = { ref = r0, expires_at = clock + 3600 }
      end
      cb({ status = "ok", result = { enabled = approvalsOn, count = #el, eligible = el } })
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
  eligibleRefs, deferCloud = nil, nil
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
    actions = list
      or {
        { ref = REF_A, title = "Turn off the patio lights", detail = "4 lights", expires_in = 600, tap_in = 300 },
        { ref = REF_B, title = "Set the den to 21 degrees", expires_in = 600, tap_in = 300 },
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
ui:deliver(
  nil,
  "Answer while locked.",
  job2,
  { actions = { { ref = REF_A, title = "T", expires_in = 60, tap_in = 300 } } }
)
clock = clock + 61
unlock(s2)
local e2 = state(s2).chat.conversation[1]
check("Owner PIN: an answer held while locked comes back without its card", e2.a ~= nil and e2.actions == nil)
check("…counted as dropped", ui.counters.actions_dropped == 1)
-- an answer asked open (not elevated) never gets a card
fresh("open")
local s3 = open()
http("POST", "/ask", s3, { question = "Lights?" })
ui:deliver(nil, "Open answer.", lastJob, { actions = { { ref = REF_A, title = "T", expires_in = 60, tap_in = 300 } } })
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
-- The schedule: 2, 5, 9, 15, 22, 30 s after the decision, then given up.
local function detailTimes(from)
  local out = {}
  for i = from, #cloud do
    if cloud[i].op == "approval_detail" then
      out[#out + 1] = cloud[i].at
    end
  end
  return out
end
local function tick(seconds, ...)
  local list = { ... }
  for _ = 1, seconds do
    clock = clock + 1
    for _, x in ipairs(list) do
      state(x)
    end
  end
end
s = sent({ state = "pending" })
local t0, from = clock, #cloud + 1
tick(45, s)
local offsets = {}
for _, at in ipairs(detailTimes(from)) do
  offsets[#offsets + 1] = at - t0
end
check(
  "never terminal: polled at 2, 5, 9, 15, 22 and 30 s after the decision, six at most",
  table.concat(offsets, ",") == "2,5,9,15,22,30",
  table.concat(offsets, ",")
)
c = card(s, REF_A)
check(
  "…then 'No confirmation from the controller yet', nothing to press, never Done",
  c.state == "unconfirmed" and c.message == "No confirmation from the controller yet."
)
from = #cloud + 1
tick(30, s)
check("…and no poll after that", #detailTimes(from) == 0)
s = sent({ state = "completed" }, 6)
t0, from = clock, #cloud + 1
tick(45, s)
offsets = {}
for _, at in ipairs(detailTimes(from)) do
  offsets[#offsets + 1] = at - t0
end
check(
  "a terminal state stops the polls (completed from 6 s: polls at 2, 5, 9, then Done)",
  table.concat(offsets, ",") == "2,5,9" and card(s, REF_A).state == "done",
  table.concat(offsets, ",")
)
-- a rate_limited answer to a poll stops that card at once
s = sent(nil)
DETAIL[REF_A] = function()
  return { status = "error", error_code = "rate_limited", result = { reason = "rate_limited" } }
end
from = #cloud + 1
tick(45, s)
check(
  "a poll answered rate_limited: no confirmation line, polling stops",
  #detailTimes(from) == 1 and card(s, REF_A).state == "unconfirmed"
)
-- ONE poller for every card of every session: one poll every 2 s at most,
-- 10 a minute at most, and no card left waiting forever.
fresh("open")
DETAIL = {}
local function pending(body)
  return {
    status = "ok",
    result = { ref = body.ref, risk = "low", args_hash = HASH, execution = { state = "pending" } },
  }
end
local sA = offered({
  { ref = REF_A, title = "A", expires_in = 600, tap_in = 300 },
  { ref = REF_B, title = "B", expires_in = 600, tap_in = 300 },
  { ref = REF_C, title = "C", expires_in = 600, tap_in = 300 },
})
clock = clock + 16
local sB = offered({ { ref = "dddddddd-7777-4888-9999-aaaaaaaaaaaa", title = "D", expires_in = 600, tap_in = 300 } })
local poll = function(body)
  if count("approval_decide") >= 4 then
    return pending(body)
  end
  return { status = "ok", result = { ref = body.ref, risk = "low", args_hash = HASH } }
end
for _, r0 in ipairs({ REF_A, REF_B, REF_C, "dddddddd-7777-4888-9999-aaaaaaaaaaaa" }) do
  DETAIL[r0] = poll
end
from = #cloud + 1
for _, r0 in ipairs({ REF_A, REF_B, REF_C }) do
  http("POST", "/chat/action", sA, { ref = r0, decision = "approve" })
end
http("POST", "/chat/action", sB, { ref = "dddddddd-7777-4888-9999-aaaaaaaaaaaa", decision = "approve" })
local decides = 0
for i = from, #cloud do
  decides = decides + (cloud[i].op == "approval_decide" and 1 or 0)
end
check("(four cards sent in two sessions)", decides == 4)
from = #cloud + 1
tick(90, sA, sB)
local times = detailTimes(from)
local gapOk, minuteOk = true, true
for i = 2, #times do
  gapOk = gapOk and times[i] - times[i - 1] >= 2
end
for i = 1, #times do
  local n = 0
  for j = i, #times do
    n = n + ((times[j] - times[i] < 60) and 1 or 0)
  end
  minuteOk = minuteOk and n <= 10
end
check("the shared poller: never two outcome polls within 2 s", gapOk)
check("…never more than 10 in a minute (all cards, all sessions)", minuteOk, #times)
local stuck = 0
for _, pair in ipairs({ { sA, REF_A }, { sA, REF_B }, { sA, REF_C }, { sB, "dddddddd-7777-4888-9999-aaaaaaaaaaaa" } }) do
  stuck = stuck + (card(pair[1], pair[2]).state == "sent" and 1 or 0)
end
check("…and no card is left at Sent: each ends with the no-confirmation line", stuck == 0)
-- polls are not interaction: an unattended screen still locks on time
s = sent({ state = "pending" })
local lockedAt
for i = 1, Webui.LIMITS.unlock_idle_seconds + 30 do
  clock = clock + 1
  local st0 = state(s)
  if lockedAt == nil and st0.chat.elevated == false then
    lockedAt = i
  end
end
check(
  "outcome polls never extend the idle lock: locked 5 minutes after the last tap",
  lockedAt ~= nil and lockedAt <= Webui.LIMITS.unlock_idle_seconds + 1,
  lockedAt
)
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
for _, reason in ipairs({ "session_risk_too_high", "session_needs_pin", "session_proposal_too_old" }) do
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
-- tap_in: Confirm only while the platform's one-tap window lasts, less 10 s
fresh("open")
s = offered({ { ref = REF_A, title = "Lights", expires_in = 600, tap_in = 10 } })
check("tap_in 10: inside the margin, Use PIN from the start", card(s, REF_A).needs_pin and card(s, REF_A).tap_in == nil)
s = offered({ { ref = REF_B, title = "Lights", expires_in = 600, tap_in = 11 } })
check("tap_in 11: Confirm for 1 s", card(s, REF_B).needs_pin == nil and card(s, REF_B).tap_in == 1)
fresh("open")
s = offered({ { ref = REF_A, title = "Lights", expires_in = 600, tap_in = 120 } })
check(
  "tap_in 120: Confirm, with the seconds left less the 10 s margin",
  card(s, REF_A).needs_pin == nil and card(s, REF_A).tap_in == 110
)
step(100, s)
http("POST", "/chat/touch", s)
check("…still Confirm at 100 s", card(s, REF_A).needs_pin == nil)
step(9, s)
check("…still Confirm at 109 s", card(s, REF_A).needs_pin == nil)
step(1, s)
c = card(s, REF_A)
check(
  "…at 110 s (the last 10 s of tap_in): Use PIN, the card still offered",
  c.needs_pin and c.state == "offered" and c.expires_in > 0
)
beforeD = count("approval_detail")
r = http("POST", "/chat/action", s, { ref = REF_A, decision = "approve" })
check(
  "…a tap on approve then sends nothing",
  r.ok == false and r.reason == "action_needs_pin" and count("approval_detail") == beforeD
)
fresh("open")
s = offered({ { ref = REF_A, title = "Movie Night", expires_in = 600, tap_in = 0 } })
c = card(s, REF_A)
check("tap_in 0 (a scene): Use PIN from the start", c.needs_pin and c.state == "offered" and c.tap_in == nil)
beforeD = count("approval_detail")
r = http("POST", "/chat/action", s, { ref = REF_A, decision = "approve" })
check("…Confirm is refused locally, nothing sent", r.ok == false and count("approval_detail") == beforeD)
r = http("POST", "/chat/action", s, { ref = REF_A, decision = "decline" })
check(
  "…Cancel (decline) is still sent with the session verification",
  r.ok and lastOf("approval_decide").decision == "decline"
)
-- expiry
fresh("open")
s = offered({ { ref = REF_C, title = "Short", expires_in = 30, tap_in = 300 } })
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

print("[7] the security review's findings")
-- 1. approvals switched off: nothing can be decided (and a refresh in
-- progress keeps the last known value)
fresh("open")
s = offered()
approvalsOn = false
ui.approvals.at = nil
state(s)
beforeD = count("approval_detail") + count("approval_decide")
r = http("POST", "/chat/action", s, { ref = REF_A, decision = "approve" })
check(
  "approvals off: /chat/action refused, nothing sent",
  r.ok == false and r.reason == "approvals_off" and count("approval_detail") + count("approval_decide") == beforeD
)
fresh("open")
s = offered()
local sB2 = offered({ { ref = REF_C, title = "Other", expires_in = 600, tap_in = 300 } })
approvalsOn = false
ui.approvals.at = nil
state(s) -- the list now says off
http("POST", "/chat/action", sB2, { ref = REF_C, decision = "decline" }) -- refused (off): no refresh reset either
ui.approvals.at = nil -- what a decision does: the list is asked again
check("…a refresh in progress keeps the last known 'off'", cards(s) == nil and ui:approvalsOff())
-- 2. a decide timeout is never "refused": followed, then the truth
local function timedOut(detailAfter)
  fresh("open")
  local x = offered()
  DECIDE[REF_A] = function()
    return { status = "error", error_code = "deadline_exceeded" }
  end
  local d0 = count("approval_decide")
  DETAIL[REF_A] = function(body)
    if count("approval_decide") == d0 then
      return { status = "ok", result = { ref = body.ref, risk = "low", args_hash = HASH } }
    end
    return detailAfter(body)
  end
  http("POST", "/chat/action", x, { ref = REF_A, decision = "approve" })
  return x
end
s = timedOut(function(body)
  return {
    status = "ok",
    result = { ref = body.ref, risk = "low", args_hash = HASH, execution = { state = "pending" } },
  }
end)
c = card(s, REF_A)
check(
  "a decide timeout: not refused, 'could not confirm… checking'",
  c.state == "sent" and c.message == Webui.TEXT.action_uncertain and not c.needs_pin
)
s = timedOut(function(body)
  return {
    status = "ok",
    result = { ref = body.ref, risk = "low", args_hash = HASH, execution = { state = "completed" } },
  }
end)
step(2, s)
check("…the execution appears: Done", card(s, REF_A).state == "done")
s = timedOut(function(body)
  return { status = "ok", result = { ref = body.ref, risk = "low", args_hash = HASH } }
end)
step(2, s)
c = card(s, REF_A)
check(
  "…the item still waiting: the buttons come back",
  c.state == "offered" and c.message == Webui.TEXT.action_not_sent
)
s = timedOut(function(body)
  return {
    status = "ok",
    result = { ref = body.ref, risk = "low", args_hash = HASH, execution = { state = "pending" } },
  }
end)
for _ = 1, 45 do
  clock = clock + 1
  state(s)
end
check(
  "…nothing learned: 'Check Approvals before asking again'",
  card(s, REF_A).state == "unconfirmed" and card(s, REF_A).message == Webui.TEXT.action_unconfirmed_check
)
fresh("open")
s = offered()
DECIDE[REF_A] = function()
  return { status = "error", error_code = "not_permitted", result = { reason = "session_stale" } }
end
http("POST", "/chat/action", s, { ref = REF_A, decision = "approve" })
check("a real platform refusal is still shown as refused", card(s, REF_A).state == "withdrawn")
-- a lost poll (no answer at all) does not freeze the card
fresh("open")
s = offered()
local held = 0
local decidedBefore = count("approval_decide")
deferCloud = function(o, body)
  if o == "approval_detail" and count("approval_decide") > decidedBefore then
    held = held + 1
    return true
  end
end
http("POST", "/chat/action", s, { ref = REF_A, decision = "approve" })
for _ = 1, 60 do
  clock = clock + 1
  state(s)
end
check(
  "a poll that never answers: given up, the card ends unconfirmed",
  held >= 2 and card(s, REF_A).state == "unconfirmed",
  held .. " " .. tostring(card(s, REF_A).state)
)
-- 3. decline is one-shot, also after a risk refusal; terminal whatever the answer
fresh("open")
s = offered()
DETAIL[REF_A] = function(body)
  return { status = "ok", result = { ref = body.ref, risk = "medium", args_hash = HASH } }
end
http("POST", "/chat/action", s, { ref = REF_A, decision = "approve" })
check("(medium risk: Use PIN offered)", card(s, REF_A).needs_pin)
DECIDE[REF_A] = function()
  return { status = "error", error_code = "not_permitted", result = { reason = "session_not_bound" } }
end
local d0 = count("approval_decide")
r = http("POST", "/chat/action", s, { ref = REF_A, decision = "decline" })
check("a decline of a PIN-needing item is allowed once", r.ok and count("approval_decide") == d0 + 1)
c = card(s, REF_A)
check(
  "…refused by the platform: its sentence, terminal, no buttons",
  c.state == "declined" and not c.needs_pin and not c.can_decline
)
for _ = 1, 5 do
  http("POST", "/chat/action", s, { ref = REF_A, decision = "decline" })
  http("POST", "/chat/action", s, { ref = REF_A, decision = "approve" })
end
check("…never sent again (repeated declines and approves)", count("approval_decide") == d0 + 1)
check("…and Use PIN is gone too", http("POST", "/approvals/next", s, { ref = REF_A }).ok == false)
-- 4. the shared retry after Lock: no attestation re-sent
for _, m in ipairs({ "owner_pin", "open" }) do
  fresh(m)
  detail = "household"
  local x = open()
  unlock(x)
  local pend
  deferCloud = function(o, body, cb)
    if o == "ask" and pend == nil then
      pend = cb
      return true
    end
  end
  http("POST", "/ask", x, { question = "Lights?" })
  check(
    "(" .. m .. ": the ask carried both attestations)",
    lastOf("ask").unlock ~= nil and lastOf("ask").owner_proof ~= nil
  )
  http("POST", "/chat/lock", x)
  local n0 = count("ask")
  pend({ status = "error", error_code = "invalid_args", result = { reason = "unknown_fields", fields = { "thread" } } })
  local retried = count("ask") - n0
  if m == "owner_pin" then
    local b = lastOf("ask")
    check(
      "owner_pin: a retry after Lock strips unlock and owner_proof (and thread)",
      retried == 1 and b.unlock == nil and b.owner_proof == nil and b.thread == nil and b.detail == "household"
    )
  else
    check("open: the elevated ask was abandoned at Lock: no retry at all", retried == 0)
  end
end
-- a re-unlock between the question and the answer: the cards are dropped
fresh("owner_pin")
s = open()
unlock(s)
http("POST", "/ask", s, { question = "Lights?" })
local jobR = lastJob
http("POST", "/chat/lock", s)
clock = clock + 61
unlock(s)
ui:deliver(nil, "A", jobR, { actions = { { ref = REF_A, title = "Lights", expires_in = 600, tap_in = 300 } } })
check("8. a re-unlock between ask and answer: no card (bound to the proof it was asked under)", cards(s) == nil)
-- 5. invisible and blank text
local function titleOk(t)
  return ChatActions.actions({ { ref = REF_A, title = t, expires_in = 60, tap_in = 300 } }) ~= nil
end
for _, case in ipairs({
  { "\227\133\164", "U+3164 Hangul filler" },
  { "\226\128\128Lights", "U+2000 en quad" },
  { "Lights\205\143off", "U+034F" },
  { "Lights\239\184\143", "U+FE0F variation selector" },
  { "\226\160\128", "U+2800 braille blank" },
  { "Turn\194\160off", "U+00A0" },
  { string.rep("a\204\129\204\129\204\129", 3), "three combining marks in a row" },
  { "\239\191\188", "U+FFFC" },
  { "\243\160\132\128x", "U+E0100 variation selector" },
  { "\238\128\128", "U+E000 private use" },
  { "\243\176\128\128x", "plane 15 private use" },
  { "!!! ???", "no letter or digit" },
  { "\240\159\143\160", "an emoji alone (no letter or digit)" },
}) do
  check("dropped: " .. case[2], not titleOk(case[1]))
end
for _, case in ipairs({
  { "Zo\195\171's lamp", "accented Latin" },
  { "\208\155\208\176\208\188\208\191\208\176", "Cyrillic" },
  { "\227\131\170\227\131\147\227\131\179\227\130\176", "Japanese" },
  { "Patio lights \240\159\143\160", "an emoji without a variation selector" },
  { "Cafe\204\129 light", "one combining mark" },
  { "Lamp 2", "a digit" },
}) do
  check("kept: " .. case[2], titleOk(case[1]))
end
local Cv2 = require("aicore.chatv2")
check(
  "the shared validator covers display and suggestions too",
  Cv2.display({ { t = "note", text = "\227\133\164" } }) == nil and Cv2.suggestions({ "Why\226\128\128?" }) == nil
)
-- 2b. a second ELEVATED session posting another session's ref
fresh("open")
s = offered()
local o2 = open()
unlock(o2)
beforeD = count("approval_detail")
r = http("POST", "/chat/action", o2, { ref = REF_A, decision = "approve" })
check(
  "another elevated session cannot act on this session's card",
  r.ok == false and count("approval_detail") == beforeD
)
-- 7. Use PIN only for a ref eligible for this screen
fresh("open")
eligibleRefs = { REF_B }
x = select(1, refusedWith("session_risk_too_high"))
eligibleRefs = { REF_B }
ui.approvals.at = nil
state(x)
local chs = 0
realPin = DEPS.pinRequest
DEPS.pinRequest = function(cap, args, cb)
  chs = chs + (cap == "pinlock.challenge" and 1 or 0)
  realPin(cap, args, cb)
end
r = http("POST", "/approvals/next", x, { ref = REF_A })
check(
  "Use PIN for a ref not eligible here: no PIN challenge, the card says to use the portal",
  r.ok == false
    and r.reason == "portal_only"
    and chs == 0
    and card(x, REF_A).state == "portal"
    and not card(x, REF_A).needs_pin
)
DEPS.pinRequest = realPin
-- 6. the same ref in two answers: only the newest card is live
fresh("open")
s = offered({ { ref = REF_A, title = "First", expires_in = 600, tap_in = 300 } })
clock = clock + 16
http("POST", "/ask", s, { question = "Again?" })
ui:deliver(nil, "Again.", lastJob, { actions = { { ref = REF_A, title = "Second", expires_in = 600, tap_in = 300 } } })
local st7 = state(s)
local first = st7.chat.conversation[#st7.chat.conversation - 1].actions[1]
local second = st7.chat.conversation[#st7.chat.conversation].actions[1]
check("the older card for the same ref says it was replaced", first.state == "replaced" and second.state == "offered")
http("POST", "/chat/action", s, { ref = REF_A, decision = "approve" })
st7 = state(s)
check(
  "…a tap acts on the newest card only",
  st7.chat.conversation[#st7.chat.conversation].actions[1].state == "sent"
    and st7.chat.conversation[#st7.chat.conversation - 1].actions[1].state == "replaced"
)
-- 9. /state and Print Diagnostics carry neither the nonce nor the proof
fresh("open")
s = offered()
http("POST", "/chat/action", s, { ref = REF_A, decision = "approve" })
local proof9 = ui.sessions[s].proofs.chat_view
local raw = ui:route({ method = "GET", path = "/state", query = { k = TOKEN, s = s }, body = "" }, TOKEN).body
check(
  "/state carries neither the proof's nonce nor its verified_at",
  not raw:find(proof9.nonce, 1, true) and not raw:find("verified_at", 1, true) and not raw:find("pin_lock", 1, true)
)
check(
  "Print Diagnostics' chat line carries neither",
  not ui:chatLine():find(proof9.nonce, 1, true) and not ui:chatLine():find(tostring(proof9.verified_at), 1, true)
)
-- a non-owner role from PIN Lock: no unlock, no owner_proof, no card
fresh("open")
local realPin2 = DEPS.pinRequest
DEPS.pinRequest = function(cap, args, cb)
  if cap == "pinlock.redeem" then
    cb({ status = "ok", result = { verified = true, role = "guest", verified_at = clock } })
    return
  end
  realPin2(cap, args, cb)
end
s = open()
unlock(s)
http("POST", "/ask", s, { question = "Lights?" })
check(
  "a non-owner role: not elevated, no owner_proof",
  state(s).chat.elevated == false and lastOf("ask").owner_proof == nil
)
ui:deliver(nil, "A", lastJob, { actions = { { ref = REF_A, title = "Lights", expires_in = 600, tap_in = 300 } } })
check("…and no card", cards(s) == nil)
DEPS.pinRequest = realPin2
-- in-flight ordering with asynchronous answers: detail, then a Lock, then decide
fresh("open")
s = offered()
local q = {}
deferCloud = function(o, body, cb)
  if o == "approval_detail" or o == "approval_decide" then
    q[#q + 1] = { o = o, body = body, cb = cb }
    return true
  end
end
http("POST", "/chat/action", s, { ref = REF_A, decision = "approve" })
check("(the detail is out)", #q == 1 and q[1].o == "approval_detail" and card(s, REF_A).state == "checking")
check(
  "a second tap while it is out: refused",
  http("POST", "/chat/action", s, { ref = REF_A, decision = "approve" }).ok == false
)
http("POST", "/chat/lock", s)
q[1].cb({ status = "ok", result = { ref = REF_A, risk = "low", args_hash = HASH } })
check("the detail answers after Lock: no decision is sent", #q == 1)
fresh("open")
s = offered()
q = {}
deferCloud = function(o, body, cb)
  if o == "approval_detail" or o == "approval_decide" then
    q[#q + 1] = { o = o, body = body, cb = cb }
    return true
  end
end
http("POST", "/chat/action", s, { ref = REF_A, decision = "approve" })
q[1].cb({ status = "ok", result = { ref = REF_A, risk = "low", args_hash = HASH } })
check("(the decide is out)", #q == 2 and q[2].o == "approval_decide" and q[2].body.args_hash == HASH)
http("POST", "/chat/lock", s)
q[2].cb({ status = "ok", result = { ref = REF_A, status = "queued" } })
check("the decide answers after Lock: the card stays gone, nothing polled", cards(s) == nil and #q == 2)

print(string.format("%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
