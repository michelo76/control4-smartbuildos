--- SmartBuildOS AI Core -- the touchscreen page's relay (pure; injected
--- clock, ids and services). The driver owns the socket, the bus and the
--- cloud; this module owns every rule the page is held to.
---
--- Three areas (spec §2.1 as amended by ruling 17):
---
---   status     no PIN: licensed or not, AI provider set up or not, online
---              or offline, learning on or off, how many items await
---              approval (a count), whether PIN Lock is available here.
---   chat       an owner PIN to VIEW and to ASK. Unlock = AI Core asks PIN
---              Lock for a `chat_view` challenge whose subject is this page
---              session's id; the page posts the PIN to PIN Lock's own
---              verify_url (never here); AI Core redeems the challenge over
---              the bus and, only on {verified:true, role:"owner"}, unlocks
---              THIS session in memory. While a session is locked no route
---              returns any conversation content, /ask is refused, and the
---              suggestions and "explain what just happened" are withheld.
---   approvals  one owner-PIN entry per item. "Review next item" asks PIN
---              Lock for an `approval` challenge bound to that item's ref;
---              after the redeem AI Core holds a proof for that ONE ref, 60
---              seconds, single use; approval_detail shows the title,
---              description and risk; approve or decline calls
---              approval_decide with the detail's args_hash and the same
---              verification. A chat unlock never approves anything and an
---              approval PIN never unlocks the chat.
---
--- A PIN never enters this module: no route here accepts one (a body with a
--- `pin` key is refused before anything reads it), and nothing here sends
--- one anywhere. Fail closed: when PIN Lock is missing, unverified by the
--- Agent, unlicensed, without an owner PIN, switched off, locked out or not
--- answering, the chat is unavailable and no approval is offered; the page
--- says to use the SmartBuildOS portal.
---
--- Sessions, conversation and proofs live in memory only: a driver restart
--- forgets them (everything is locked again). Nothing here has run on a
--- controller (unit and emulator tests only).

local uirelay = require("atmosphere.uirelay")
local Commands = require("aicore.commands")
JSON = JSON or require("JSON")

local M = {}

M.parse = uirelay.parse
M.render = uirelay.render

M.PORT = 47871
M.PINLOCK_PORT = 47831

M.LIMITS = {
  sessions = 4, -- page sessions held at once (least recently seen evicted)
  session_gone_seconds = 75, -- no request for this long: the page is gone
  unlock_idle_seconds = 300, -- the chat locks after 5 minutes without interaction
  conversation = 10, -- exchanges kept per session
  conversation_idle_seconds = 900, -- cleared after 15 minutes without interaction
  answer_wait_seconds = 300, -- an unanswered question is shown as failed after this
  grant_seconds = 60, -- an approval proof, from the PIN's verification
  question = 500, -- characters
  answer_bytes = 2048, -- deliver_result's bound
  body_bytes = 4096, -- one request body
  requests_per_minute = 90, -- per session (the page polls every 3 s at most)
  asks_per_minute = 4, -- the webview's own ask bucket (plus the shared one)
  challenges_per_minute = 6, -- PIN prompts, all sessions together
  approvals_refresh_seconds = 30, -- approvals_pending at most this often
  approvals_stale_seconds = 60, -- refreshed when older, while a page is open
  pin_check_seconds = 30, -- pinlock.availability at most this often
  title = 80,
  description = 300,
}

M.DETAILS = { basic = true, standard = true, household = true }
M.DECISIONS = { "approve", "decline" }
M.CHANNEL = "touchscreen"

--- The closed list of suggested questions (driver-owned; shown only to an
--- unlocked session).
M.SUGGESTIONS = {
  {
    id = "working",
    label = "Is everything in the house working?",
    question = "Is everything in the house working right now?",
  },
  { id = "today", label = "What happened today?", question = "Summarise what happened in the house today." },
  { id = "attention", label = "Does anything need attention?", question = "Does any device or system need attention?" },
}
M.EXPLAIN_QUESTION = "Explain what just happened in the house in the last few minutes, in plain words."

--- Every reason a reply may carry, in plain words. A reason that is not
--- here is never shown as a code: it becomes M.FALLBACK_TEXT.
M.TEXT = {
  -- PIN Lock availability (pinlock.availability reasons and discovery)
  ready = "PIN Lock is ready for this screen.",
  checking = "Checking PIN Lock…",
  starting = "PIN Lock is starting. Try again in a moment, or use the SmartBuildOS portal.",
  off = "PIN verification is switched off in PIN Lock. Use the SmartBuildOS portal.",
  unlicensed = "PIN Lock is not licensed for this. Use the SmartBuildOS portal.",
  no_owner_pin = "PIN Lock has no owner PIN set. Use the SmartBuildOS portal.",
  relay_unavailable = "PIN Lock's page connection is not available. Use the SmartBuildOS portal.",
  locked = "Too many wrong PINs: PIN entry is locked for a while. Use the SmartBuildOS portal.",
  pin_not_installed = "PIN Lock is not installed, so this screen cannot ask for a PIN. Use the SmartBuildOS portal.",
  pin_unverified = "The SmartBuildOS Agent could not confirm PIN Lock. Use the SmartBuildOS portal.",
  pin_not_responding = "PIN Lock is not responding. Use the SmartBuildOS portal.",
  pin_update_required = "PIN Lock needs an update for this screen. Use the SmartBuildOS portal.",
  pin_no_agent = "The SmartBuildOS Agent is not answering, so PIN Lock cannot be reached. Use the SmartBuildOS portal.",
  pin_relay_mismatch = "PIN Lock answers on a different address than AI Core. Ask your integrator to set the same App Relay Address on both. Use the SmartBuildOS portal.",
  pin_busy = "PIN Lock is busy. Try again in a minute.",
  -- the chat
  basic = "The chat is switched off on this screen. Use the SmartBuildOS portal.",
  chat_locked = "The chat is locked. Enter an owner PIN to open it.",
  not_licensed = "AI Core is not licensed. Ask your integrator.",
  offline = "SmartBuildOS cannot be reached right now. Try again later.",
  too_long = "That question is too long (500 characters at most).",
  empty = "Type a question first.",
  rate_limited = "Too many requests. Wait a minute and try again.",
  unknown_suggestion = "That suggestion is not available.",
  -- the PIN entry (pinlock.redeem and local)
  not_verified = "That PIN was not accepted. Only an owner PIN works here.",
  expired = "That took too long. Start again.",
  wrong_subject = "That PIN entry was for something else. Start again.",
  unknown = "That PIN entry is no longer valid. Start again.",
  role_not_owner = "Only an owner PIN works here.",
  no_prompt = "Nothing is waiting for a PIN.",
  -- approvals (local)
  approvals_off = "The homeowner has not switched on approvals at the touchscreen. Use the SmartBuildOS portal.",
  nothing_to_review = "Nothing here can be approved at this screen. Use the SmartBuildOS portal for the rest.",
  no_grant = "Enter the owner PIN again for this item.",
  no_review = "Choose an item to review first.",
  bad_decision = "Choose approve or decline.",
  -- approvals (the cloud's closed reasons, ruling 24)
  invalid_args = "SmartBuildOS could not read that request. Use the SmartBuildOS portal.",
  system_not_linked_to_a_property = "This system is not linked to a home in SmartBuildOS yet. Use the SmartBuildOS portal.",
  unavailable = "SmartBuildOS approvals are not available right now. Try again later or use the SmartBuildOS portal.",
  touchscreen_approval_off = "The homeowner has switched approvals at the touchscreen off. Use the SmartBuildOS portal.",
  role_not_permitted = "Only an owner PIN may approve. Use the SmartBuildOS portal.",
  verification_stale = "The PIN check is too old (or the controller's clock is off). Enter the PIN again.",
  verification_replayed = "That PIN entry was already used. Enter the PIN again.",
  not_for_this_controller = "That item belongs to another system. Use the SmartBuildOS portal.",
  not_pending = "That item was already decided.",
  portal_only = "That item can only be approved in the SmartBuildOS portal.",
  above_ceiling = "That item is above what a PIN may approve. Use the SmartBuildOS portal.",
  approval_mismatch = "That item changed after it was shown. Review it again.",
  -- transport
  cloud_unreachable = "SmartBuildOS did not answer. Try again later.",
  agent = "The SmartBuildOS Agent is not answering. Try again later.",
}
M.FALLBACK_TEXT = "SmartBuildOS refused that. Use the SmartBuildOS portal."

--- What approval_decide's status means.
M.OUTCOME_TEXT = {
  queued = "Approved. SmartBuildOS is carrying it out.",
  denied = "Declined.",
  failed = "SmartBuildOS could not carry it out.",
  expired = "That item expired before it was decided.",
}

--- Plain words for a reason; never the raw code.
function M.text(reason)
  return M.TEXT[reason] or M.FALLBACK_TEXT
end

-- ── small helpers ────────────────────────────────────────────────────────────

local HEX32 = "^[0-9a-f]+$"
local UUID = "^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$"

local function hex32(s)
  return type(s) == "string" and #s == 32 and s:match(HEX32) ~= nil
end
M.hex32 = hex32

local function uuid(s)
  return type(s) == "string" and #s == 36 and s:match(UUID) ~= nil
end
M.uuid = uuid

local function epoch(n)
  return type(n) == "number" and n == n and n > 1000000000 and n < 4102444800 and n == math.floor(n)
end

local function json(status, doc)
  local ok, body = pcall(function()
    return JSON:encode(doc)
  end)
  return { status = status, contentType = "application/json", body = ok and body or '{"ok":false}' }
end

local STATUS = {
  [200] = "200 OK",
  [400] = "400 Bad Request",
  [401] = "401 Unauthorized",
  [403] = "403 Forbidden",
  [404] = "404 Not Found",
  [405] = "405 Method Not Allowed",
  [413] = "413 Payload Too Large",
  [429] = "429 Too Many Requests",
  [500] = "500 Internal Server Error",
  [503] = "503 Service Unavailable",
}

local function reply(code, doc)
  return json(STATUS[code] or STATUS[500], doc)
end

local function refusal(code, reason, extra)
  local doc = { ok = false, reason = reason, message = M.text(reason) }
  for k, v in pairs(extra or {}) do
    doc[k] = v
  end
  return reply(code, doc)
end

--- Free text shown on the page: one line of cleaned text, cut to `max`
--- characters (code points). Never interpreted; the page renders it with
--- textContent.
local function clean(s, max)
  if type(s) ~= "string" then
    return ""
  end
  return Commands.sanitise(s, max)
end
M.clean = clean

--- A sliding per-minute window.
local function windowTake(list, now, limit)
  local keep = {}
  for _, at in ipairs(list) do
    if now - at < 60 then
      keep[#keep + 1] = at
    end
  end
  for i = #list, 1, -1 do
    list[i] = nil
  end
  for i, at in ipairs(keep) do
    list[i] = at
  end
  if #list >= limit then
    return false
  end
  list[#list + 1] = now
  return true
end

-- ── cloud bodies (the parity test reads these) ───────────────────────────────

function M.askBody(requestId, question, detail)
  return {
    command = "TOUCHSCREEN_ASK",
    request_id = requestId,
    question = clean(question, M.LIMITS.question),
    channel = M.CHANNEL,
    detail = M.DETAILS[detail] and detail or "standard",
  }
end

function M.verification(proof)
  return { nonce = proof.nonce, verified_at = proof.verified_at, role = proof.role, method = "pin_lock" }
end

function M.pendingBody(requestId)
  return { command = "TOUCHSCREEN_APPROVALS", request_id = requestId }
end

function M.detailBody(requestId, ref, proof)
  return { command = "TOUCHSCREEN_APPROVAL", request_id = requestId, ref = ref, verification = M.verification(proof) }
end

function M.decideBody(requestId, ref, decision, argsHash, proof)
  return {
    command = "TOUCHSCREEN_APPROVAL",
    request_id = requestId,
    ref = ref,
    decision = decision,
    args_hash = argsHash,
    verification = M.verification(proof),
  }
end

--- A cloud refusal's reason: result.reason when it is a code, else the
--- error code. Unknown ones still map to plain words (M.text fallback).
local function cloudReason(answer)
  answer = type(answer) == "table" and answer or {}
  local r = type(answer.result) == "table" and answer.result or {}
  if type(r.reason) == "string" and r.reason:match("^[a-z][a-z0-9_]*$") and #r.reason <= 48 then
    return r.reason
  end
  local code = tostring(answer.error_code or "")
  if code == "cloud_unreachable" or code == "deadline_exceeded" or code == "target_unavailable" then
    return "cloud_unreachable"
  end
  if code == "rate_limited" then
    return "rate_limited"
  end
  if code == "agent_not_paired" or code == "incompatible_protocol" then
    return "agent"
  end
  return code ~= "" and code or "unavailable"
end
M.cloudReason = cloudReason

-- ── the UI ───────────────────────────────────────────────────────────────────

local UI = {}
UI.__index = UI

--- deps = {
---   now()                         -> epoch seconds
---   newHex()                      -> 32 lowercase hex (session ids, tokens, nonces)
---   newRequestId()                -> a cloud request id
---   facts()                       -> { licensed, provider_configured, online, learning_active }
---   detail()                      -> "basic" | "standard" | "household"
---   relayHost()                   -> the host this relay is published on
---   pinAvailability(cb)           -> cb({ available, reason, retry_in? })
---   pinRequest(capability, args, cb) -> cb(answer{status, result, error_code})
---   cloud(op, body, cb)           -> cb(answer{status, result, error_code})
---   take()                        -> the shared command bucket (true = may send)
---   appHtml()                     -> the page
---   onChange()                    -> optional: the touchscreen summary changed
--- }
function M.new(deps)
  local self = setmetatable({}, UI)
  self.deps = deps
  self.sessions = {} -- [token] = session
  self.asks = {} -- [request_id] = { token, entry }
  self.askTimes = {}
  self.challengeTimes = {}
  self.pinState = { available = false, reason = "checking", at = nil, inflight = false }
  self.approvals = { enabled = false, count = 0, eligible = {}, portal_only_count = 0, checked_at = nil, at = nil }
  self.approvalsInflight = false
  self.approvalsReason = nil
  self.counters = {
    sessions_opened = 0,
    sessions_evicted = 0,
    unlocks = 0,
    unlock_refused = 0,
    asks = 0,
    asks_refused = 0,
    answers_held = 0,
    answers_dropped = 0,
    approvals_verified = 0,
    decisions = 0,
    refused_locked = 0,
    pin_bodies_refused = 0,
  }
  return self
end

function UI:now()
  return self.deps.now()
end

local function notify(self)
  if self.deps.onChange then
    pcall(self.deps.onChange)
  end
end

-- sessions ----------------------------------------------------------------

function UI:sessionCount()
  local n = 0
  for _ in pairs(self.sessions) do
    n = n + 1
  end
  return n
end

local function lockSession(s)
  s.proofs.chat_view = nil
end

--- Ends every unlock and every approval proof (PIN Lock became unavailable,
--- or the driver is stopping).
function UI:lockAll()
  for _, s in pairs(self.sessions) do
    lockSession(s)
    s.proofs.approval = nil
    s.review = nil
    s.prompt = nil
  end
end

local function dropSession(self, token)
  local s = self.sessions[token]
  if s == nil then
    return
  end
  for id, a in pairs(self.asks) do
    if a.token == token then
      self.asks[id] = nil
    end
  end
  self.sessions[token] = nil
end

--- Housekeeping, run before every request and on the driver's tick:
--- sessions whose page stopped asking are dropped (a closed page), idle
--- unlocks end, idle conversations are cleared, stale proofs go.
function UI:sweep()
  local t = self:now()
  for token, s in pairs(self.sessions) do
    if t - s.seen >= M.LIMITS.session_gone_seconds then
      dropSession(self, token)
    else
      local chat = s.proofs.chat_view
      if chat ~= nil and t >= chat.ends then
        lockSession(s)
      end
      local ap = s.proofs.approval
      if ap ~= nil and t >= ap.ends then
        s.proofs.approval = nil
        if s.review ~= nil and not s.review.decided then
          s.review = nil
          s.notice = M.text("expired")
        end
      end
      if s.prompt ~= nil and t >= s.prompt.expires_at then
        s.prompt = nil
      end
      for _, e in ipairs(s.conversation) do
        if e.state == "pending" and t - e.at >= M.LIMITS.answer_wait_seconds then
          e.state, e.message = "failed", M.text("cloud_unreachable")
          self.asks[e.id] = nil
        end
      end
      if #s.conversation > 0 and t - s.touched >= M.LIMITS.conversation_idle_seconds then
        for id, a in pairs(self.asks) do
          if a.token == token then
            self.asks[id] = nil
          end
        end
        s.conversation = {}
      end
    end
  end
end

function UI:openSession()
  self:sweep()
  if self:sessionCount() >= M.LIMITS.sessions then
    local oldestToken, oldestAt
    for token, s in pairs(self.sessions) do
      if oldestAt == nil or s.seen < oldestAt then
        oldestToken, oldestAt = token, s.seen
      end
    end
    dropSession(self, oldestToken)
    self.counters.sessions_evicted = self.counters.sessions_evicted + 1
  end
  local token, sid = self.deps.newHex(), self.deps.newHex()
  if not hex32(token) or not hex32(sid) or self.sessions[token] ~= nil then
    return nil
  end
  local t = self:now()
  self.sessions[token] = {
    token = token,
    sid = sid, -- the chat_view challenge subject; never the token
    seen = t,
    touched = t,
    requests = {},
    proofs = {}, -- chat_view = {...}, approval = {...}
    conversation = {},
    prompt = nil, -- the PIN entry the page is asked for
    review = nil, -- the approval item being reviewed
    notice = nil, -- one line for the page
    skipped = {}, -- refs decided here this session
  }
  self.counters.sessions_opened = self.counters.sessions_opened + 1
  self:checkPin(true)
  self:refreshApprovals(false)
  return self.sessions[token]
end

--- The proof for `purpose` and `subject`, while it is valid; nil otherwise.
--- The ONE check behind "is the chat unlocked" and "may this ref be
--- detailed / decided": a chat_view proof never satisfies an approval and an
--- approval proof never satisfies the chat.
local function proofFor(self, s, purpose, subject)
  local p = s.proofs[purpose]
  if p == nil or p.purpose ~= purpose or p.subject ~= subject or self:now() >= p.ends then
    return nil
  end
  return p
end
M._proofFor = proofFor

function UI:unlocked(s)
  return proofFor(self, s, "chat_view", s.sid) ~= nil
end

--- A person did something (not a poll): the unlock and the conversation
--- stay alive.
local function interacted(self, s)
  local t = self:now()
  s.touched = t
  local chat = proofFor(self, s, "chat_view", s.sid)
  if chat ~= nil then
    chat.ends = t + M.LIMITS.unlock_idle_seconds
  end
end

-- PIN Lock -------------------------------------------------------------------

--- Refreshes what PIN Lock says (at most every pin_check_seconds unless
--- forced). When it says no, every unlock and proof ends (fail closed).
function UI:checkPin(force)
  local t = self:now()
  if
    self.pinState.inflight
    or (not force and self.pinState.at ~= nil and t - self.pinState.at < M.LIMITS.pin_check_seconds)
  then
    return
  end
  self.pinState.inflight = true
  self.deps.pinAvailability(function(a)
    a = type(a) == "table" and a or {}
    self.pinState = {
      available = a.available == true,
      reason = type(a.reason) == "string" and a.reason or "pin_not_responding",
      retry_in = tonumber(a.retry_in),
      at = self:now(),
      inflight = false,
    }
    if not self.pinState.available then
      self:lockAll()
    end
    notify(self)
  end)
end

function UI:pinUsable()
  return self.pinState.available == true and self.pinState.reason == "ready"
end

function UI:chatAvailable()
  if self.deps.detail() == "basic" then
    return false, "basic"
  end
  if not self:pinUsable() then
    return false, self.pinState.reason
  end
  return true, "ready"
end

--- Starts a PIN entry for `purpose` / `subject` on session `s`. The page is
--- told through /state (prompt) once PIN Lock answered.
local function beginChallenge(self, s, purpose, subject, ref)
  if not self:pinUsable() then
    return false, self.pinState.reason
  end
  if not windowTake(self.challengeTimes, self:now(), M.LIMITS.challenges_per_minute) then
    return false, "rate_limited"
  end
  local nonce = self.deps.newHex()
  if not hex32(nonce) then
    return false, "unavailable"
  end
  s.prompt =
    { purpose = purpose, subject = subject, ref = ref, nonce = nonce, waiting = true, expires_at = self:now() + 60 }
  local prompt = s.prompt
  self.deps.pinRequest("pinlock.challenge", { purpose = purpose, subject = subject, nonce = nonce }, function(answer)
    if s.prompt ~= prompt then
      return -- superseded or cancelled
    end
    answer = type(answer) == "table" and answer or {}
    local r = type(answer.result) == "table" and answer.result or {}
    if answer.status ~= "ok" then
      s.prompt = nil
      local why = r.reason
      if answer.error_code == "rate_limited" then
        why = "pin_busy"
      elseif answer.error_code == "unsupported" and type(why) == "string" then
        self.pinState = { available = false, reason = why, at = self:now(), inflight = false }
        self:lockAll()
      elseif answer.error_code == "unknown_target" or answer.error_code == "target_unavailable" then
        why = "pin_not_responding"
      else
        why = "pin_not_responding"
      end
      s.notice = M.text(why)
      notify(self)
      return
    end
    local host = self.deps.relayHost()
    local expected = string.format("http://%s:%d/verify", tostring(host), M.PINLOCK_PORT)
    if not hex32(r.challenge_id) or host == "" or r.verify_url ~= expected then
      -- The page's security policy allows PIN Lock's port on THIS host only:
      -- anything else is refused here, never handed to the page.
      s.prompt = nil
      s.notice = M.text(hex32(r.challenge_id) and "pin_relay_mismatch" or "pin_not_responding")
      notify(self)
      return
    end
    prompt.challenge_id = r.challenge_id
    prompt.verify_url = r.verify_url
    prompt.waiting = false
    prompt.expires_at = self:now() + math.min(60, tonumber(r.expires_in) or 60)
    notify(self)
  end)
  return true
end

--- The page tried a PIN at verify_url (whatever PIN Lock answered it): AI
--- Core redeems the challenge over the bus. Only {verified:true,
--- role:"owner"} counts.
local function redeem(self, s, challengeId)
  local p = s.prompt
  if p == nil or p.challenge_id == nil or p.challenge_id ~= challengeId then
    return false, "no_prompt"
  end
  s.prompt = nil
  p.redeeming = true
  local args = { challenge_id = p.challenge_id, nonce = p.nonce, purpose = p.purpose, subject = p.subject }
  self.deps.pinRequest("pinlock.redeem", args, function(answer)
    answer = type(answer) == "table" and answer or {}
    local r = type(answer.result) == "table" and answer.result or {}
    if answer.status ~= "ok" then
      s.notice = M.text("pin_not_responding")
      self.counters.unlock_refused = self.counters.unlock_refused + 1
      notify(self)
      return
    end
    if r.verified ~= true then
      local why = type(r.reason) == "string" and r.reason or "not_verified"
      s.notice = M.text(why)
      self.counters.unlock_refused = self.counters.unlock_refused + 1
      notify(self)
      return
    end
    if r.role ~= "owner" or not epoch(r.verified_at) then
      s.notice = M.text("role_not_owner")
      self.counters.unlock_refused = self.counters.unlock_refused + 1
      notify(self)
      return
    end
    local t = self:now()
    local proof = {
      purpose = p.purpose,
      subject = p.subject,
      nonce = p.nonce,
      verified_at = r.verified_at,
      role = r.role,
    }
    if p.purpose == "chat_view" then
      if p.subject ~= s.sid then
        return
      end
      proof.ends = t + M.LIMITS.unlock_idle_seconds
      s.proofs.chat_view = proof
      s.touched = t
      s.notice = nil
      self.counters.unlocks = self.counters.unlocks + 1
    else
      proof.ends = math.min(t, r.verified_at) + M.LIMITS.grant_seconds
      s.proofs.approval = proof
      self.counters.approvals_verified = self.counters.approvals_verified + 1
      self:openReview(s, p.ref)
    end
    notify(self)
  end)
  return true
end

-- approvals --------------------------------------------------------------------

--- approvals_pending, at most every approvals_refresh_seconds (and only
--- when the shared bucket allows).
function UI:refreshApprovals(force)
  local t = self:now()
  local a = self.approvals
  if self.approvalsInflight then
    return false
  end
  if a.at ~= nil and t - a.at < M.LIMITS.approvals_refresh_seconds then
    return false
  end
  if not force and a.at ~= nil and t - a.at < M.LIMITS.approvals_stale_seconds then
    return false
  end
  if not self.deps.take() then
    return false
  end
  self.approvalsInflight = true
  a.at = t
  self.deps.cloud("approvals_pending", M.pendingBody(self.deps.newRequestId()), function(answer)
    self.approvalsInflight = false
    answer = type(answer) == "table" and answer or {}
    local r = type(answer.result) == "table" and answer.result or {}
    if answer.status ~= "ok" then
      self.approvalsReason = cloudReason(answer)
      notify(self)
      return
    end
    local eligible = {}
    for _, e in ipairs(type(r.eligible) == "table" and r.eligible or {}) do
      if type(e) == "table" and uuid(e.ref) and #eligible < 10 then
        eligible[#eligible + 1] = { ref = e.ref:lower(), expires_at = tonumber(e.expires_at) }
      end
    end
    self.approvals = {
      enabled = r.enabled == true,
      count = math.max(0, math.floor(tonumber(r.count) or 0)),
      eligible = eligible,
      portal_only_count = math.max(0, math.floor(tonumber(r.portal_only_count) or 0)),
      checked_at = tonumber(r.checked_at),
      at = self:now(),
    }
    self.approvalsReason = nil
    notify(self)
  end)
  return true
end

--- The first item this screen may review that this session has not
--- already decided and that has not expired.
local function nextRef(self, s)
  local t = self:now()
  for _, e in ipairs(self.approvals.eligible) do
    if not s.skipped[e.ref] and (e.expires_at == nil or e.expires_at > t) then
      return e.ref
    end
  end
  return nil
end

--- After a verified approval PIN: approval_detail for that one ref.
function UI:openReview(s, ref)
  local proof = proofFor(self, s, "approval", ref)
  if proof == nil then
    s.notice = M.text("no_grant")
    return false
  end
  if not self.deps.take() then
    s.proofs.approval = nil
    s.notice = M.text("rate_limited")
    return false
  end
  s.review = { ref = ref, loading = true }
  local review = s.review
  self.deps.cloud("approval_detail", M.detailBody(self.deps.newRequestId(), ref, proof), function(answer)
    if s.review ~= review then
      return
    end
    answer = type(answer) == "table" and answer or {}
    local r = type(answer.result) == "table" and answer.result or {}
    if answer.status ~= "ok" then
      s.review = nil
      s.proofs.approval = nil -- the proof dies with the item it was for
      s.notice = M.text(cloudReason(answer))
      s.skipped[ref] = true
      notify(self)
      return
    end
    local argsHash = type(r.args_hash) == "string" and r.args_hash:lower() or ""
    if
      r.ref ~= ref
      or not argsHash:match("^[0-9a-f]+$")
      or #argsHash ~= 64
      or (r.risk ~= "low" and r.risk ~= "medium")
    then
      s.review = nil
      s.proofs.approval = nil
      s.notice = M.text("unavailable")
      notify(self)
      return
    end
    review.loading = false
    review.title = clean(r.title, M.LIMITS.title)
    review.description = clean(r.description, M.LIMITS.description)
    review.risk = r.risk
    review.expires_at = tonumber(r.expires_at)
    review.args_hash = argsHash
    notify(self)
  end)
  return true
end

-- the chat ----------------------------------------------------------------------

local function addEntry(s, entry)
  s.conversation[#s.conversation + 1] = entry
  while #s.conversation > M.LIMITS.conversation do
    table.remove(s.conversation, 1)
  end
end

local function ask(self, s, body)
  local ok, why = self:chatAvailable()
  if not ok then
    return false, why
  end
  if not self:unlocked(s) then
    self.counters.refused_locked = self.counters.refused_locked + 1
    return false, "chat_locked"
  end
  local f = self.deps.facts()
  if not f.licensed then
    return false, "not_licensed"
  end
  if not f.online then
    return false, "offline"
  end
  local question
  if body.explain == true then
    question = M.EXPLAIN_QUESTION
  elseif body.suggestion_id ~= nil then
    for _, sug in ipairs(M.SUGGESTIONS) do
      if sug.id == body.suggestion_id then
        question = sug.question
      end
    end
    if question == nil then
      return false, "unknown_suggestion"
    end
  else
    if type(body.question) ~= "string" then
      return false, "empty"
    end
    question = clean(body.question, M.LIMITS.question + 1)
    if question == "" then
      return false, "empty"
    end
    local chars = 0
    for _ in question:gmatch("[^\128-\191]") do
      chars = chars + 1
    end
    if chars > M.LIMITS.question then
      return false, "too_long"
    end
  end
  if not windowTake(self.askTimes, self:now(), M.LIMITS.asks_per_minute) then
    return false, "rate_limited"
  end
  if not self.deps.take() then
    return false, "rate_limited"
  end
  local requestId = self.deps.newRequestId()
  local entry = { id = requestId, q = question, state = "pending", at = self:now() }
  addEntry(s, entry)
  self.asks[requestId] = { token = s.token, entry = entry }
  self.counters.asks = self.counters.asks + 1
  self.deps.cloud("ask", M.askBody(requestId, question, self.deps.detail()), function(answer)
    local r = Commands.interpret(answer)
    if r.outcome == "accepted" then
      entry.job_id = r.job_id
      return
    end
    self.asks[requestId] = nil
    if r.outcome == "completed" then
      entry.state = "failed"
      entry.message = M.text("unavailable")
    elseif r.outcome == "unreachable" or r.outcome == "unavailable" then
      entry.state = "failed"
      entry.message = M.text("cloud_unreachable")
    else
      entry.state = "refused"
      entry.message = M.text(cloudReason(answer))
    end
    notify(self)
  end)
  return true, requestId
end

--- deliver_result for a touchscreen ask. Returns true when it was one (the
--- driver then keeps it out of AI_LAST_RESPONSE and its persisted copy).
--- An answer for a locked session is HELD (never sent until the next
--- unlock); one whose session or conversation is gone is dropped.
function UI:deliver(requestId, text)
  local a = requestId and self.asks[requestId] or nil
  if a == nil then
    return false
  end
  self.asks[requestId] = nil
  local s = self.sessions[a.token]
  if s == nil then
    self.counters.answers_dropped = self.counters.answers_dropped + 1
    return true
  end
  a.entry.a = Commands.cutBytes(tostring(text or ""), M.LIMITS.answer_bytes)
  a.entry.state = "answered"
  if not self:unlocked(s) then
    self.counters.answers_held = self.counters.answers_held + 1
  end
  notify(self)
  return true
end

--- Whether a deliver_result request id belongs to a touchscreen ask.
function UI:owns(requestId)
  return requestId ~= nil and self.asks[requestId] ~= nil
end

-- the state document --------------------------------------------------------------

local function plainFacts(f)
  return {
    licensed = f.licensed and "Licensed" or "Not licensed. Ask your integrator.",
    provider = f.provider_configured and "AI provider set up" or "No AI provider set up yet",
    online = f.online and "Online" or "Offline: SmartBuildOS cannot be reached",
    learning = f.learning_active and "Learning is on" or "Learning is off",
  }
end

local function approvalsDoc(self)
  local a = self.approvals
  local doc = {
    count = a.count,
    screen_count = #a.eligible,
    portal_only_count = a.portal_only_count,
    enabled = a.enabled,
    can_review = false,
  }
  if a.count == 1 then
    doc.text = "1 item awaits approval"
  elseif a.count > 1 then
    doc.text = a.count .. " items await approval"
  else
    doc.text = a.at ~= nil and "Nothing awaits approval" or "Checking approvals…"
  end
  if self.approvalsReason ~= nil then
    doc.message = M.text(self.approvalsReason)
  elseif not self:pinUsable() then
    doc.message = M.text(self.pinState.reason)
  elseif a.count > 0 and not a.enabled then
    doc.message = M.text("approvals_off")
  elseif a.count > 0 and #a.eligible == 0 then
    doc.message = M.text("nothing_to_review")
  elseif a.portal_only_count > 0 then
    doc.message = (a.portal_only_count == 1 and "1 item" or (a.portal_only_count .. " items"))
      .. " can only be approved in the SmartBuildOS portal."
  end
  doc.can_review = self:pinUsable() and a.enabled and #a.eligible > 0
  return doc
end

--- The ONE place conversation content leaves this module: nil for a
--- locked session (no question, answer, suggestion or explain action).
local function chatView(self, s)
  local p = proofFor(self, s, "chat_view", s.sid)
  if p == nil then
    return nil
  end
  local list = {}
  for _, e in ipairs(s.conversation) do
    list[#list + 1] = { id = e.id, q = e.q, a = e.a, state = e.state, message = e.message, at = e.at }
  end
  local sug = {}
  for _, x in ipairs(M.SUGGESTIONS) do
    sug[#sug + 1] = { id = x.id, label = x.label }
  end
  return {
    locked = false,
    locks_in = math.max(0, p.ends - self:now()),
    conversation = list,
    suggestions = sug,
    explain = true,
    detail = self.deps.detail(),
  }
end

--- The page's whole view. Conversation content, suggestions and the
--- explain action appear ONLY for an unlocked session.
function UI:stateDoc(s)
  local f = self.deps.facts()
  local doc = {
    ok = true,
    status = {
      licensed = f.licensed == true,
      provider_configured = f.provider_configured == true,
      online = f.online == true,
      learning_active = f.learning_active == true,
      text = plainFacts(f),
    },
    approvals = approvalsDoc(self),
    pin = {
      available = self:pinUsable(),
      reason = self.pinState.reason,
      message = M.text(self:pinUsable() and "ready" or self.pinState.reason),
      retry_in = self.pinState.reason == "locked" and self.pinState.retry_in or nil,
    },
    notice = s.notice,
  }
  local available, why = self:chatAvailable()
  local chat = { available = available, locked = true }
  if not available then
    chat.message = M.text(why)
  else
    local view = chatView(self, s)
    if view == nil then
      chat.message = M.text("chat_locked")
    else
      for k, v in pairs(view) do
        chat[k] = v
      end
    end
  end
  doc.chat = chat
  if s.prompt ~= nil then
    local p = s.prompt
    doc.prompt = {
      ["for"] = p.purpose == "chat_view" and "chat" or "approval",
      waiting = p.waiting == true,
      challenge_id = p.challenge_id,
      verify_url = p.verify_url,
      expires_in = math.max(0, p.expires_at - self:now()),
    }
  end
  if s.review ~= nil then
    local r = s.review
    local proof = proofFor(self, s, "approval", r.ref)
    doc.review = {
      loading = r.loading == true,
      title = r.title,
      description = r.description,
      risk = r.risk,
      grant_left = proof and math.max(0, proof.ends - self:now()) or 0,
    }
  end
  return doc
end

-- the router ------------------------------------------------------------------------

local POSTS = {
  ["/session"] = true,
  ["/session/close"] = true,
  ["/chat/unlock"] = true,
  ["/chat/lock"] = true,
  ["/chat/touch"] = true,
  ["/pin/done"] = true,
  ["/pin/cancel"] = true,
  ["/ask"] = true,
  ["/approvals/refresh"] = true,
  ["/approvals/next"] = true,
  ["/approvals/decide"] = true,
  ["/approvals/close"] = true,
}
M.POSTS = POSTS

--- Body keys each route accepts (closed). No route accepts `pin`.
local BODY_KEYS = {
  ["/pin/done"] = { challenge_id = true },
  ["/ask"] = { question = true, suggestion_id = true, explain = true },
  ["/approvals/decide"] = { decision = true },
}

local function decodeBody(self, path, raw)
  raw = raw or ""
  if raw == "" then
    return {}
  end
  local ok, body = pcall(function()
    return JSON:decode(raw)
  end)
  if not ok or type(body) ~= "table" then
    return nil, "invalid_args"
  end
  local allowed = BODY_KEYS[path] or {}
  for k in pairs(body) do
    if k == "pin" then
      -- A PIN goes to PIN Lock's verify_url only. Refused unread.
      self.counters.pin_bodies_refused = self.counters.pin_bodies_refused + 1
      return nil, "invalid_args"
    end
    if not allowed[k] then
      return nil, "invalid_args"
    end
  end
  return body
end

--- Routes one parsed request (uirelay.parse). `token` is the install token
--- (the `k` in the web view URL).
function UI:route(req, token)
  if req.method == "BAD" then
    return reply(400, { ok = false })
  end
  if req.method == "OPTIONS" then
    return { status = "204 No Content", contentType = "application/json", body = "" }
  end
  if req.path == "/ping" and req.method == "GET" then
    return { status = "200 OK", contentType = "application/json", body = '{"ok":true,"service":"ai-core"}' }
  end
  if req.path == "/app" and req.method == "GET" then
    local ok, html = pcall(self.deps.appHtml)
    if not ok or type(html) ~= "string" or html == "" then
      return reply(503, { ok = false, error = "app not loadable" })
    end
    return { status = "200 OK", contentType = "text/html; charset=utf-8", body = html }
  end
  if token == nil or token == "" or req.query.k ~= token then
    return reply(403, { ok = false, error = "bad token" })
  end
  if #(req.body or "") > M.LIMITS.body_bytes then
    return reply(413, { ok = false })
  end
  self:sweep()
  if req.path == "/session" then
    if req.method ~= "POST" then
      return reply(405, { ok = false })
    end
    local s = self:openSession()
    if s == nil then
      return reply(503, { ok = false })
    end
    return reply(200, { ok = true, s = s.token })
  end
  local known = req.path == "/state" or POSTS[req.path]
  if not known then
    return reply(404, { ok = false })
  end
  local s = hex32(req.query.s) and self.sessions[req.query.s] or nil
  if s == nil then
    return reply(401, { ok = false, reason = "session" })
  end
  local t = self:now()
  s.seen = t
  if not windowTake(s.requests, t, M.LIMITS.requests_per_minute) then
    return refusal(429, "rate_limited")
  end
  if req.path == "/state" then
    if req.method ~= "GET" then
      return reply(405, { ok = false })
    end
    self:checkPin(false)
    self:refreshApprovals(false)
    return reply(200, self:stateDoc(s))
  end
  if req.method ~= "POST" then
    return reply(405, { ok = false })
  end
  local body, bad = decodeBody(self, req.path, req.body)
  if body == nil then
    return refusal(400, bad)
  end
  local path = req.path
  if path == "/session/close" then
    dropSession(self, s.token)
    return reply(200, { ok = true })
  end
  if path == "/chat/lock" then
    lockSession(s)
    if s.prompt ~= nil and s.prompt.purpose == "chat_view" then
      s.prompt = nil
    end
    return reply(200, { ok = true })
  end
  if path == "/chat/touch" then
    interacted(self, s)
    return reply(200, { ok = true })
  end
  if path == "/pin/cancel" then
    s.prompt = nil
    if s.review ~= nil and s.review.loading then
      s.review = nil
    end
    return reply(200, { ok = true })
  end
  if path == "/pin/done" then
    if type(body.challenge_id) ~= "string" then
      return refusal(400, "invalid_args")
    end
    local ok, why = redeem(self, s, body.challenge_id)
    if not ok then
      return refusal(200, why)
    end
    return reply(200, { ok = true })
  end
  s.notice = nil
  if path == "/chat/unlock" then
    interacted(self, s)
    local ok, why = self:chatAvailable()
    if not ok then
      self.counters.unlock_refused = self.counters.unlock_refused + 1
      return refusal(200, why)
    end
    if self:unlocked(s) then
      return reply(200, { ok = true })
    end
    local started, why2 = beginChallenge(self, s, "chat_view", s.sid, nil)
    if not started then
      return refusal(200, why2)
    end
    return reply(200, { ok = true, waiting = true })
  end
  if path == "/ask" then
    local ok, idOrWhy = ask(self, s, body)
    if not ok then
      self.counters.asks_refused = self.counters.asks_refused + 1
      return refusal(200, idOrWhy)
    end
    interacted(self, s)
    return reply(200, { ok = true, id = idOrWhy })
  end
  if path == "/approvals/refresh" then
    self:refreshApprovals(true)
    return reply(200, { ok = true })
  end
  if path == "/approvals/next" then
    if not self:pinUsable() then
      return refusal(200, self.pinState.reason)
    end
    if not self.approvals.enabled then
      return refusal(200, "approvals_off")
    end
    local ref = nextRef(self, s)
    if ref == nil then
      return refusal(200, "nothing_to_review")
    end
    s.review = nil
    s.proofs.approval = nil -- a proof is for ONE ref: a new item needs a new PIN
    local started, why = beginChallenge(self, s, "approval", ref, ref)
    if not started then
      return refusal(200, why)
    end
    return reply(200, { ok = true, waiting = true })
  end
  if path == "/approvals/close" then
    s.review = nil
    s.proofs.approval = nil
    if s.prompt ~= nil and s.prompt.purpose == "approval" then
      s.prompt = nil
    end
    return reply(200, { ok = true })
  end
  if path == "/approvals/decide" then
    local decision = body.decision
    if decision ~= M.DECISIONS[1] and decision ~= M.DECISIONS[2] then
      return refusal(200, "bad_decision")
    end
    local review = s.review
    if review == nil or review.loading or review.args_hash == nil then
      return refusal(200, "no_review")
    end
    local ref = review.ref
    local proof = proofFor(self, s, "approval", ref)
    -- Single use: the proof is gone whatever happens next.
    s.proofs.approval = nil
    if proof == nil then
      s.review = nil
      return refusal(200, "no_grant")
    end
    if not self.deps.take() then
      s.review = nil
      return refusal(200, "rate_limited")
    end
    review.decided = true
    s.skipped[ref] = true
    self.counters.decisions = self.counters.decisions + 1
    local body2 = M.decideBody(self.deps.newRequestId(), ref, decision, review.args_hash, proof)
    self.deps.cloud("approval_decide", body2, function(answer)
      answer = type(answer) == "table" and answer or {}
      local r = type(answer.result) == "table" and answer.result or {}
      if s.review == review then
        s.review = nil
      end
      if answer.status ~= "ok" then
        s.notice = M.text(cloudReason(answer))
      else
        s.notice = M.OUTCOME_TEXT[r.status] or M.FALLBACK_TEXT
      end
      self.approvals.at = nil -- the list changed: ask again
      self:refreshApprovals(true)
      notify(self)
    end)
    return reply(200, { ok = true })
  end
  return reply(404, { ok = false })
end

--- A one-line summary for the read-only Composer property.
function UI:summary()
  local detail = self.deps.detail()
  local pinPart
  if self:pinUsable() then
    pinPart = "PIN Lock ready (owner PINs only)"
  else
    pinPart = "PIN Lock unavailable (" .. tostring(self.pinState.reason) .. "): chat and approvals off, use the portal"
  end
  local chatPart = detail == "basic" and "chat off (Basic)" or ("chat " .. detail .. ", owner PIN to view")
  local a = self.approvals
  local apPart
  if a.at == nil then
    apPart = "approvals not checked yet"
  elseif a.enabled then
    apPart = "approvals on in the homeowner portal"
  else
    apPart = "approvals off (enable in the homeowner portal)"
  end
  return pinPart .. "; " .. chatPart .. "; " .. apPart .. "; " .. self:sessionCount() .. " page(s) open"
end

return M
