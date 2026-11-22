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
---              suggestions (the dealer's presets among them) and "explain
---              what just happened" are withheld.
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
local ChatV2 = require("aicore.chatv2")
local ChatActions = require("aicore.chatactions")
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
  open_idle_seconds = 300, -- open chat: cleared (and a new thread) 5 minutes after the last question
  unlock_max_seconds = 1800, -- …and 30 minutes after the PIN, whatever the activity (= the platform's age cap for `unlock`)
  conversation = 10, -- exchanges kept per session
  conversation_idle_seconds = 900, -- cleared after 15 minutes without interaction
  answer_wait_seconds = 300, -- an unanswered question is shown as failed after this
  grant_seconds = 60, -- an approval proof, from the PIN's verification
  question = 500, -- characters
  answer_bytes = 2048, -- deliver_result's bound
  body_bytes = 4096, -- one request body
  requests_per_minute = 90, -- per session (the page polls every second at most, while an answer is pending)
  asks_per_minute = 4, -- the webview's own ask bucket (plus the shared one)
  challenges_per_minute = 6, -- PIN prompts, all sessions together
  approvals_refresh_seconds = 30, -- approvals_pending at most this often
  approvals_stale_seconds = 60, -- refreshed when older, while a page is open
  pin_check_seconds = 30, -- pinlock.availability at most this often
  redeem_wait_seconds = 30, -- a redeem PIN Lock never answered is reported after this
  orphan_seconds = 3600, -- an ask nobody waits for any more: its answer is dropped for this long
  orphans = 64, -- ids remembered for that (oldest forgotten first)
  title = 80,
  description = 300,
}

M.DETAILS = { basic = true, standard = true, household = true }
--- The privacy floor (open chat): the detail every ask carries from a
--- session that is not owner-unlocked when it asks, whatever Touchscreen
--- Detail says. The cloud only ever LOWERS the detail, so no household
--- activity is answered without an owner PIN.
M.OPEN_DETAIL = "standard"
--- Touchscreen Chat Access (dealer property): `open` = anyone at the screen
--- may ask and read their own session's answers, the owner PIN elevates;
--- `owner_pin` = the chat needs an owner PIN to view and to ask (ruling 17).
M.ACCESS = { open = true, owner_pin = true }
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

--- The dealer's preset questions (round two, D-R2b; configuration key
--- touchscreen.presets, validated whole by aicore.config): shown IN
--- ADDITION to M.SUGGESTIONS, before them, and only to an unlocked session.
--- Each is offered as { id = "p<index>-<rev>", label = its text }. `rev`
--- changes whenever the list changes (and starts from the clock, so a page
--- that outlived a restart holds ids nobody issues), so an id from an older
--- list is refused (unknown_suggestion) and never mapped to whichever
--- question now sits at that index. Asking one sends exactly its text.
M.PRESETS_MAX = 6

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
  explain_needs_pin = "Unlock with the owner PIN to ask what just happened in the house.",
  chat_locked = "The chat is locked. Enter an owner PIN to open it.",
  not_licensed = "AI Core is not licensed. Ask your integrator.",
  -- the cloud's refusal of an unlicensed controller (rpc/handler.ts)
  not_entitled = "AI Core is not licensed for this controller. Ask your integrator.",
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
  -- chat actions (local)
  action_gone = "That action is no longer offered. Ask again.",
  action_expired = "That action has expired. Ask again.",
  action_busy = "That action was already chosen.",
  action_needs_pin = "This one needs the owner PIN for this item. Use PIN.",
  action_locked = "Unlock with the owner PIN to confirm actions.",
  -- chat actions (the platform's session-verification refusals)
  session_risk_too_high = "This action needs the owner PIN for this item. Use PIN.",
  session_proposal_too_old = "This suggestion is too old for one tap. Use PIN.",
  session_not_bound = "This unlock does not cover that action any more. Ask again.",
  session_stale = "The owner unlock is too old for that action. Unlock again and ask again.",
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

--- The `command` each body carries. The platform accepts a command only
--- when it is shaped like a Composer command, `AI_` and 2 to 40 capitals or
--- underscores (platform rpc/ops.ts COMMAND), and refuses the WHOLE body
--- otherwise (invalid_args, fields ["command"]): a name without the prefix
--- made every touchscreen question and the approvals list fail on the first
--- real controller. test_aicore_webui.lua [17] holds every body to the rule.
M.COMMANDS = {
  ask = "AI_TOUCHSCREEN_ASK",
  approvals = "AI_TOUCHSCREEN_APPROVALS",
  approval = "AI_TOUCHSCREEN_APPROVAL",
}
M.COMMAND_PATTERN = "^AI_[A-Z_]+$"
M.COMMAND_NAME = { min = 2, max = 40 } -- characters after "AI_"

--- `unlock` (owner decision: an owner PIN at the touchscreen unlocks fuller
--- DEVICE answers): the ask says its session was unlocked with an owner PIN,
--- as PIN Lock's redeem established it — the four keys of an approval's
--- verification (nonce, verified_at, role, method), never a PIN. Sent only
--- while Touchscreen Detail is Household (unlockFor). The platform then reads
--- device state at scope `full` for that one ask, whatever the homeowner's
--- household switch says; household ACTIVITY stays behind that switch. The
--- platform cannot verify a PIN: it takes this driver's word, bounded by the
--- age of verified_at (LIMITS.unlock_max_seconds on both sides; the parity
--- tests of both repositories hold the name, the values and the number).
M.UNLOCK = { field = "unlock", role = "owner", method = "pin_lock" }
--- deliver_result's `channel` for an answer that belongs to this page.
M.RESULT_CHANNEL = "touchscreen"

--- @param unlock table|nil M.verification(the session's chat_view proof)
--- @param thread string|nil chat v2: the conversation's id (aicore.chatv2);
---   the cloud continues the conversation it names. An invalid one is left out.
--- `unlock` and `thread` are the ask's OPTIONAL keys: UI:optionalAskKeys
--- decides them once per ask, and one retry drops whichever a platform that
--- does not know them refuses (UI:retryWithoutRefusedKeys).
--- @param ownerProof table|nil chat actions v1: M.verification(the session's
---   live owner proof) on every ask from an owner-unlocked session
---   (ownerProofFor); also an optional key of the shared retry.
function M.askBody(requestId, question, detail, unlock, thread, ownerProof)
  local body = {
    command = M.COMMANDS.ask,
    request_id = requestId,
    question = clean(question, M.LIMITS.question),
    channel = M.CHANNEL,
    detail = M.DETAILS[detail] and detail or "standard",
    thread = ChatV2.validThread(thread) and thread or nil,
  }
  if unlock ~= nil then
    body[M.UNLOCK.field] = unlock
  end
  if ownerProof ~= nil then
    body[ChatActions.OWNER_PROOF_FIELD] = ownerProof
  end
  return body
end

--- `method` defaults to "pin_lock" (a PIN entered for this item); a chat
--- action's one tap sends ChatActions.SESSION_METHOD (the session's owner
--- unlock).
function M.verification(proof, method)
  return { nonce = proof.nonce, verified_at = proof.verified_at, role = proof.role, method = method or "pin_lock" }
end

function M.pendingBody(requestId)
  return { command = M.COMMANDS.approvals, request_id = requestId }
end

function M.detailBody(requestId, ref, proof, method)
  return {
    command = M.COMMANDS.approval,
    request_id = requestId,
    ref = ref,
    verification = M.verification(proof, method),
  }
end

function M.decideBody(requestId, ref, decision, argsHash, proof, method)
  return {
    command = M.COMMANDS.approval,
    request_id = requestId,
    ref = ref,
    decision = decision,
    args_hash = argsHash,
    verification = M.verification(proof, method),
  }
end

local function token(s, max)
  return type(s) == "string" and #s <= max and s:match("^[a-z][a-z0-9_]*$") ~= nil
end

--- A cloud refusal's reason: result.reason when it is a code this page has
--- words for; else the error code (the platform's body validation answers
--- invalid_args with reasons of its own, `invalid_fields` among them: the
--- code's sentence says more than the fallback); else the reason anyway.
--- Unknown ones still map to plain words (M.text fallback).
local function cloudReason(answer)
  answer = type(answer) == "table" and answer or {}
  local r = type(answer.result) == "table" and answer.result or {}
  local reason = token(r.reason, 48) and r.reason or nil
  if reason ~= nil and M.TEXT[reason] ~= nil then
    return reason
  end
  local code = tostring(answer.error_code or "")
  if code == "cloud_unreachable" or code == "deadline_exceeded" or code == "target_unavailable" then
    code = "cloud_unreachable"
  elseif code == "agent_not_paired" or code == "incompatible_protocol" then
    code = "agent"
  end
  if reason ~= nil and M.TEXT[code] == nil then
    return reason
  end
  return code ~= "" and code or "unavailable"
end
M.cloudReason = cloudReason

--- What a refused cloud answer said, as codes only (for Print Diagnostics
--- and the Composer property): the error code, result.reason, result.detail
--- and the field NAMES the platform's validator listed. Never a value, a
--- question, an answer or any other text of the result.
local function refusalCodes(answer, at)
  answer = type(answer) == "table" and answer or {}
  local r = type(answer.result) == "table" and answer.result or {}
  local fields = {}
  for _, f in ipairs(type(r.fields) == "table" and r.fields or {}) do
    if type(f) == "string" and #f <= 48 and f:match("^[a-z][a-z0-9_.|]*$") and #fields < 5 then
      fields[#fields + 1] = f
    end
  end
  local code = tostring(answer.error_code or "")
  return {
    code = token(code, 48) and code or (answer.status == "ok" and "not_accepted" or "unknown"),
    reason = token(r.reason, 48) and r.reason or nil,
    detail = token(r.detail, 48) and r.detail or nil,
    fields = fields,
    at = at,
  }
end
M.refusalCodes = refusalCodes

--- One refusal in one line: `invalid_args, reason invalid_fields, fields command`.
function M.refusalLine(x)
  local line = x.code
  if x.reason ~= nil and x.reason ~= x.code then
    line = line .. ", reason " .. x.reason
  end
  if x.detail ~= nil then
    line = line .. ", detail " .. x.detail
  end
  if #x.fields > 0 then
    line = line .. ", fields " .. table.concat(x.fields, " ")
  end
  return line
end

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
---   presets()                     -> optional: the dealer's preset questions
---                                    (the current configuration's list)
---   onChange()                    -> optional: the touchscreen summary changed
--- }
function M.new(deps)
  local self = setmetatable({}, UI)
  self.deps = deps
  self.sessions = {} -- [token] = session
  self.asks = {} -- [request_id] = { token, entry }
  self.orphans = {} -- [request id or job id] = until when its answer is dropped
  self.orphanOrder = {}
  self.askTimes = {}
  self.challengeTimes = {}
  self.pinState = { available = false, reason = "checking", at = nil, inflight = false }
  self.approvals = { enabled = false, count = 0, eligible = {}, portal_only_count = 0, checked_at = nil, at = nil }
  self.approvalsInflight = false
  self.approvalsReason = nil
  self.refusals = {} -- [op] = the last refused cloud answer, codes only (refusalCodes)
  -- The platform answered `unknown_fields: unlock` (it is older than this
  -- driver): `unlock` is not sent again for the rest of this driver run.
  self.unlockNotAccepted = false
  -- Optional ask keys (`thread`, `unlock`) a platform older than this driver
  -- refused as unknown: never sent again in this driver run
  -- (UI:retryWithoutRefusedKeys). unlockNotAccepted mirrors `unlock`.
  self.refusedAskKeys = {}
  self.presetRev = math.floor(tonumber(deps.now()) or 0)
  self.presetSig = nil
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
    -- chat v2 (counts only; never a question, an answer or a block's text)
    threads_minted = 0,
    thread_retries = 0, -- asks sent again without `thread` (the cloud did not know the key)
    display_answers = 0, -- answers that carried at least one valid block
    display_blocks = 0, -- blocks kept
    display_dropped = 0, -- blocks (or whole values) dropped by validation
    suggestions_kept = 0,
    suggestions_dropped = 0,
    -- open chat (counts only)
    open_asks = 0, -- asks from a session that was not owner-unlocked (sent at OPEN_DETAIL)
    elevated_asks = 0, -- asks from an owner-unlocked session
    elevated_purged = 0, -- exchanges removed when an owner unlock ended (open mode)
    open_cleared = 0, -- open conversations cleared (5 minutes without a question, page hidden)
    -- chat actions v1 (counts only)
    owner_proof_sent = 0, -- asks that carried owner_proof
    actions_offered = 0, -- action cards shown
    actions_dropped = 0, -- items dropped by validation, or offered to a session no longer unlocked
    actions_removed = 0, -- cards removed when the owner unlock ended
    actions_confirmed = 0,
    actions_declined = 0,
    actions_done = 0,
    actions_failed = 0,
    actions_refused = 0, -- the platform (or this driver) refused the one-tap decision
    actions_unconfirmed = 0, -- no execution state within 30 s
    unlock_sent = 0, -- asks that carried `unlock`
    unlock_retried = 0, -- asks sent again without it (the platform did not know the field)
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

--- Remembers what came back for a cloud `op` that was not accepted (codes
--- only, memory only), so the reason can be read on the controller: Print
--- Diagnostics, and for the approvals list the Touchscreen Approvals property.
function UI:refused(op, answer)
  self.refusals[op] = refusalCodes(answer, self:now())
end

--- The last refusal of each cloud op the page uses, one line each (codes
--- and field names only).
function UI:refusalLines()
  local out = {}
  for _, op in ipairs({ "ask", "approvals_pending", "approval_detail", "approval_decide" }) do
    local x = self.refusals[op]
    if x ~= nil then
      out[#out + 1] =
        string.format("%s not accepted: %s (%d s ago)", op, M.refusalLine(x), math.max(0, self:now() - x.at))
    end
  end
  return out
end

-- sessions ----------------------------------------------------------------

function UI:sessionCount()
  local n = 0
  for _ in pairs(self.sessions) do
    n = n + 1
  end
  return n
end

--- Locking ends the conversation's thread: the next unlock starts a new one
--- (the cloud remembers nothing across it), and the page shows where.
local function lockSession(s)
  if s.proofs.chat_view ~= nil then
    s.thread = nil
  end
  s.proofs.chat_view = nil
end

--- Ends every unlock and every approval proof (PIN Lock became unavailable,
--- or the driver is stopping).
function UI:lockAll()
  for _, s in pairs(self.sessions) do
    self:relock(s, false)
    s.proofs.approval = nil
    s.review = nil
    s.prompt = nil
  end
end

--- Stops waiting for an ask's answer (its page closed or went away, its
--- conversation was cleared, the accept answer was lost).
--- The answer may still arrive: the ask's ids stay known for orphan_seconds
--- so it is DROPPED then, never published as a Composer answer
--- (AI_LAST_RESPONSE, AI Response Ready) where no PIN guards it.
local function abandon(self, requestId)
  local a = self.asks[requestId]
  self.asks[requestId] = nil
  local ends = self:now() + M.LIMITS.orphan_seconds
  for _, id in ipairs({ requestId, a ~= nil and a.entry.job_id ~= nil and tostring(a.entry.job_id) or false }) do
    if id then
      if self.orphans[id] == nil then
        self.orphanOrder[#self.orphanOrder + 1] = id
      end
      self.orphans[id] = ends
    end
  end
  while #self.orphanOrder > M.LIMITS.orphans do
    self.orphans[table.remove(self.orphanOrder, 1)] = nil
  end
end

local function orphaned(self, id)
  local ends = id ~= nil and self.orphans[tostring(id)] or nil
  return ends ~= nil and self:now() < ends
end

--- The ask a deliver_result answers: by the ask's own request id, else by
--- the job id its accept answer named. The platform's deliver_result names
--- the job (job_id) and the id of the Agent's relay request, which is NOT
--- the ask's request id, so the job id is what matches on a real system.
local function findAsk(self, requestId, jobId)
  if requestId ~= nil and self.asks[requestId] ~= nil then
    return requestId, self.asks[requestId]
  end
  if jobId ~= nil then
    for id, a in pairs(self.asks) do
      if a.entry.job_id ~= nil and tostring(a.entry.job_id) == tostring(jobId) then
        return id, a
      end
    end
  end
  return nil, nil
end

local function dropSession(self, token)
  local s = self.sessions[token]
  if s == nil then
    return
  end
  for id, a in pairs(self.asks) do
    if a.token == token then
      abandon(self, id)
    end
  end
  self.sessions[token] = nil
end

--- Housekeeping, run before every request and on the driver's tick:
--- sessions whose page stopped asking are dropped (a closed page), idle
--- unlocks end, idle conversations are cleared, stale proofs go.
function UI:sweep()
  local t = self:now()
  for i = #self.orphanOrder, 1, -1 do
    local id = self.orphanOrder[i]
    if self.orphans[id] == nil or t >= self.orphans[id] then
      self.orphans[id] = nil
      table.remove(self.orphanOrder, i)
    end
  end
  for token, s in pairs(self.sessions) do
    if t - s.seen >= M.LIMITS.session_gone_seconds then
      dropSession(self, token)
    else
      local chat = s.proofs.chat_view
      if chat ~= nil and t >= chat.ends then
        self:relock(s, false)
      end
      self:openIdle(s)
      self:pollActions(s)
      local ap = s.proofs.approval
      if ap ~= nil and t >= ap.ends then
        s.proofs.approval = nil
        if s.review ~= nil and not s.review.decided then
          s.review = nil
          s.notice = M.text("expired")
        end
      end
      if s.prompt ~= nil and t >= s.prompt.expires_at then
        -- Never silently: a prompt PIN Lock did not answer, or a pad nobody
        -- finished, says so on the page.
        s.notice = M.text(s.prompt.waiting and "pin_not_responding" or "expired")
        s.prompt = nil
      end
      if s.checking ~= nil and t - s.checking.at >= M.LIMITS.redeem_wait_seconds then
        s.checking = nil
        s.notice = M.text("pin_not_responding")
      end
      for _, e in ipairs(s.conversation) do
        if e.state == "pending" and t - e.at >= M.LIMITS.answer_wait_seconds then
          -- Said on the page; the ask is still held, so an answer that
          -- arrives later is shown to this session (never published).
          e.state, e.message = "failed", M.text("cloud_unreachable")
        end
      end
      if #s.conversation > 0 and t - s.touched >= M.LIMITS.conversation_idle_seconds then
        for id, a in pairs(self.asks) do
          if a.token == token then
            abandon(self, id)
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
    checking = nil, -- when a redeem was sent (the page shows "Checking the PIN…")
    review = nil, -- the approval item being reviewed
    notice = nil, -- one line for the page
    skipped = {}, -- refs decided here this session
    thread = nil, -- chat v2: this unlock's conversation id (minted at unlock, gone at lock)
    conv = 0, -- which unlock an exchange belongs to (the page marks where a new conversation starts)
    asked = nil, -- when this session last asked (open chat: cleared 5 minutes later)
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

-- open chat (Touchscreen Chat Access) ------------------------------------------

--- `open` or `owner_pin`; anything else (or no such dependency) is `owner_pin`: fail
--- closed to the stricter mode.
function UI:access()
  local a = self.deps.access and self.deps.access() or "owner_pin"
  return a == "open" and "open" or "owner_pin"
end

function UI:openMode()
  return self:access() == "open"
end

--- The detail an ask from `s` carries NOW: the configured one for an
--- owner-unlocked session, OPEN_DETAIL for every other (never household).
function UI:askDetail(s)
  if self:unlocked(s) then
    return self.deps.detail()
  end
  return M.OPEN_DETAIL
end

--- A new conversation thread for `s` (nil when no random id was available:
--- the ask then goes without one).
function UI:newThread(s)
  s.thread = ChatV2.mintThread(self.deps.newHex)
  if s.thread ~= nil then
    self.counters.threads_minted = self.counters.threads_minted + 1
  end
end

--- Stops waiting for every ask of `s` matching `pick` (nil: all): an answer
--- arriving later is dropped, never shown (abandon).
local function abandonAsks(self, s, pick)
  for id, a in pairs(self.asks) do
    if a.token == s.token and (pick == nil or pick(a.entry)) then
      abandon(self, id)
    end
  end
end

--- Open mode: removes every exchange asked while owner-unlocked, from the
--- session and from the page, and drops their answers still in flight.
function UI:purgeElevated(s)
  abandonAsks(self, s, function(e)
    return e.elevated == true
  end)
  local keep = {}
  for _, e in ipairs(s.conversation) do
    if e.elevated then
      self.counters.elevated_purged = self.counters.elevated_purged + 1
    else
      keep[#keep + 1] = e
    end
  end
  s.conversation = keep
end

--- Open mode: the whole conversation goes (answers in flight dropped).
function UI:clearConversation(s)
  abandonAsks(self, s, nil)
  if #s.conversation > 0 then
    self.counters.open_cleared = self.counters.open_cleared + 1
  end
  s.conversation = {}
  s.asked = nil
end

--- Ends an owner unlock (Lock, the idle timer, the page hidden, PIN Lock
--- gone). In Owner PIN mode exactly as before: the conversation is kept
--- (shown again after the next unlock). In open mode the elevated
--- exchanges go, the page being hidden clears everything, and a new
--- thread starts so nothing asked elevated is continued without the PIN.
function UI:relock(s, hidden)
  local wasUnlocked = s.proofs.chat_view ~= nil
  lockSession(s)
  -- Chat action cards exist only while the owner unlock does, in BOTH
  -- modes: an Owner PIN session keeps its exchanges, never its cards.
  self:removeActions(s)
  if not self:openMode() then
    return
  end
  if hidden then
    self:clearConversation(s)
  elseif wasUnlocked then
    self:purgeElevated(s)
  else
    return -- nothing was elevated: the open conversation goes on
  end
  s.conv = s.conv + 1
  self:newThread(s)
end

--- Open mode: 5 minutes after the last question, a session that is not
--- owner-unlocked starts over (conversation cleared, new thread).
function UI:openIdle(s)
  if not self:openMode() or self:unlocked(s) or s.asked == nil then
    return
  end
  if self:now() - s.asked >= M.LIMITS.open_idle_seconds then
    self:clearConversation(s)
    s.conv = s.conv + 1
    self:newThread(s)
  end
end

--- A person did something (not a poll): the unlock and the conversation
--- stay alive.
local function interacted(self, s)
  local t = self:now()
  s.touched = t
  local chat = proofFor(self, s, "chat_view", s.sid)
  if chat ~= nil then
    -- Activity extends the unlock, never past 30 minutes after the PIN.
    chat.ends = math.min(t + M.LIMITS.unlock_idle_seconds, chat.max)
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
  if self:openMode() then
    return true, "ready" -- no PIN Lock needed to ask; the owner unlock is an elevation
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
  -- Until PIN Lock answers, /state says a PIN is being checked: the page
  -- shows it and keeps polling fast, so the outcome appears when it lands.
  local checking = { at = self:now() }
  s.checking = checking
  local args = { challenge_id = p.challenge_id, nonce = p.nonce, purpose = p.purpose, subject = p.subject }
  self.deps.pinRequest("pinlock.redeem", args, function(answer)
    if s.checking == checking then
      s.checking = nil
    end
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
      -- Two ends: 5 minutes without interaction (extended by use), and 30
      -- minutes after the PIN whatever the use — counted from PIN Lock's own
      -- verified_at, which is the time the platform's age cap reads.
      proof.max = math.min(t, r.verified_at) + M.LIMITS.unlock_max_seconds
      proof.ends = math.min(t + M.LIMITS.unlock_idle_seconds, proof.max)
      s.proofs.chat_view = proof
      s.touched = t
      s.notice = nil
      -- A new conversation for every unlock (chat v2).
      s.conv = s.conv + 1
      self:newThread(s)
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
      self:refused("approvals_pending", answer)
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
    self.refusals.approvals_pending = nil
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
      self:refused("approval_detail", answer)
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

--- The current preset list (plain strings, at most PRESETS_MAX) and its
--- revision. The revision moves whenever the list differs from the one
--- last seen, so ids issued for an older list stop resolving.
local function currentPresets(self)
  local raw = self.deps.presets and self.deps.presets() or nil
  local list = {}
  if type(raw) == "table" then
    for _, text in ipairs(raw) do
      if type(text) == "string" and #list < M.PRESETS_MAX then
        list[#list + 1] = text
      end
    end
  end
  -- A preset can never hold a newline (aicore.config), so this join is
  -- unambiguous.
  local sig = table.concat(list, "\n")
  if sig ~= self.presetSig then
    self.presetSig = sig
    self.presetRev = self.presetRev + 1
  end
  return list, tostring(self.presetRev)
end

--- The question a suggestion id stands for, or nil.
local function suggestionQuestion(self, id)
  if type(id) ~= "string" then
    return nil
  end
  local index, rev = id:match("^p(%d)%-(%d+)$")
  if index ~= nil then
    local list, current = currentPresets(self)
    index = tonumber(index)
    if rev == current and index >= 1 and index <= #list then
      return list[index]
    end
    return nil
  end
  for _, sug in ipairs(M.SUGGESTIONS) do
    if sug.id == id then
      return sug.question
    end
  end
  return nil
end

--- The `unlock` an ask from session `s` carries, or nil (M.UNLOCK). Only
--- while the dealer's Touchscreen Detail is Household — at Standard nothing is
--- attested and answers stay as they were —, only from this session's live
--- chat_view proof, whose role is owner (redeem creates no other), and not
--- once the platform has said it does not know the field.
--- The `owner_proof` an ask from `s` carries (chat actions v1), or nil: the
--- same wall as unlockFor — only this session's live chat_view proof, role
--- owner — but at any detail where the chat is on (not Household only).
--- An Open-mode session that is not owner-unlocked never has one.
local function ownerProofFor(self, s)
  if self.refusedAskKeys[ChatActions.OWNER_PROOF_FIELD] or self.deps.detail() == "basic" then
    return nil
  end
  local proof = proofFor(self, s, "chat_view", s.sid)
  if proof == nil or proof.role ~= "owner" then
    return nil
  end
  return M.verification(proof)
end

local function unlockFor(self, s)
  if self.unlockNotAccepted or self.deps.detail() ~= "household" then
    return nil
  end
  local proof = proofFor(self, s, "chat_view", s.sid)
  if proof == nil or proof.role ~= M.UNLOCK.role then
    return nil
  end
  return M.verification(proof)
end

local function ask(self, s, body)
  local ok, why = self:chatAvailable()
  if not ok then
    return false, why
  end
  local elevated = self:unlocked(s)
  if not elevated and not self:openMode() then
    self.counters.refused_locked = self.counters.refused_locked + 1
    return false, "chat_locked"
  end
  if body.explain == true and not elevated then
    -- "What just happened" is house activity: owner unlock only.
    return false, "explain_needs_pin"
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
    question = suggestionQuestion(self, body.suggestion_id)
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
  local entry = {
    id = requestId,
    q = question,
    state = "pending",
    at = self:now(),
    conv = s.conv,
    elevated = elevated, -- removed with its answer when the owner unlock ends (open mode)
    detail = self:askDetail(s), -- fixed at the moment of asking (the privacy floor)
  }
  addEntry(s, entry)
  self.asks[requestId] = { token = s.token, entry = entry }
  s.asked = entry.at
  self.counters.asks = self.counters.asks + 1
  if elevated then
    self.counters.elevated_asks = self.counters.elevated_asks + 1
  else
    self.counters.open_asks = self.counters.open_asks + 1
  end
  if s.thread == nil then
    self:newThread(s)
  end
  entry.optional = self:optionalAskKeys(s)
  self:sendAsk(s, entry, requestId)
  return true, entry.id
end

--- Sends one touchscreen ask with the optional keys decided when it was
--- asked (entry.optional), minus any the platform has refused in this
--- driver run.
function UI:sendAsk(s, entry, requestId)
  local sent = {}
  for k, v in pairs(entry.optional or {}) do
    if not self.refusedAskKeys[k] then
      sent[k] = v
    end
  end
  if sent.unlock ~= nil then
    self.counters.unlock_sent = self.counters.unlock_sent + 1
  end
  if sent[ChatActions.OWNER_PROOF_FIELD] ~= nil then
    self.counters.owner_proof_sent = self.counters.owner_proof_sent + 1
  end
  local body =
    M.askBody(requestId, entry.q, entry.detail, sent.unlock, sent.thread, sent[ChatActions.OWNER_PROOF_FIELD])
  self.deps.cloud("ask", body, function(answer)
    self:answered(s, entry, requestId, sent, answer)
  end)
end

--- The OPTIONAL keys of an ask from `s`, decided ONCE when it is asked (a
--- retry never adds one): `thread` (chat v2) and `unlock` (unlockFor: only
--- at Household with a live owner proof). Another optional key joins here
--- and inherits the one retry below.
function UI:optionalAskKeys(s)
  local out = {}
  if s.thread ~= nil then
    out.thread = s.thread
  end
  out.unlock = unlockFor(self, s)
  out[ChatActions.OWNER_PROOF_FIELD] = ownerProofFor(self, s)
  return out
end

--- ONE mechanism for every optional key. A platform older than a key
--- refuses the WHOLE ask (invalid_args, reason unknown_fields, the keys in
--- `fields`; aicore.chatv2 refusedKeys), and an old platform names every
--- key it does not know in that one answer. So: every refused key that the
--- ask carried is remembered for the rest of this driver run (never sent
--- again) and the ask is sent ONCE more without them, under a new request
--- id (the platform replays a stored answer for a repeated id). Never a
--- second retry. A key the platform knows and refuses (invalid_thread, …)
--- is not retried: it is this driver's bug, shown as refused. True when it
--- retried.
function UI:retryWithoutRefusedKeys(s, entry, requestId, sent, answer)
  local names = ChatV2.refusedKeys(answer, sent)
  if #names == 0 or entry.retried or self.asks[requestId] == nil then
    return false
  end
  for _, k in ipairs(names) do
    self.refusedAskKeys[k] = true
    if k == M.UNLOCK.field then
      self.unlockNotAccepted = true
      self.counters.unlock_retried = self.counters.unlock_retried + 1
    elseif k == "thread" then
      self.counters.thread_retries = self.counters.thread_retries + 1
    end
  end
  entry.retried = true
  local retryId = self.deps.newRequestId()
  self.asks[requestId] = nil
  entry.id = retryId
  self.asks[retryId] = { token = s.token, entry = entry }
  self:sendAsk(s, entry, retryId)
  return true
end

--- The cloud's quick answer to a touchscreen ask.
function UI:answered(s, entry, requestId, sent, answer)
  local r = Commands.interpret(answer)
  if r.outcome == "refused" and self:retryWithoutRefusedKeys(s, entry, requestId, sent, answer) then
    return
  end
  if r.outcome == "accepted" then
    entry.job_id = r.job_id
    self.refusals.ask = nil
    return
  end
  if r.outcome == "completed" then
    self.asks[requestId] = nil
    entry.state = "failed"
    entry.message = M.text("unavailable")
  elseif r.outcome == "unreachable" or r.outcome == "unavailable" then
    -- The accept answer was lost; the platform may hold a job all the same.
    abandon(self, requestId)
    entry.state = "failed"
    entry.message = M.text("cloud_unreachable")
  else
    self.asks[requestId] = nil
    entry.state = "refused"
    entry.message = M.text(cloudReason(answer))
    self:refused("ask", answer)
  end
  notify(self)
end

--- deliver_result for a touchscreen ask (matched by request id or job id,
--- findAsk). Returns true when it was one (the driver then keeps it out of
--- AI_LAST_RESPONSE and its persisted copy). An answer for a locked session
--- is HELD (never sent until the next unlock); one nobody waits for any more
--- (abandon) is dropped.
---
--- `extra` (chat v2, optional): { display, suggestions, display_dropped,
--- suggestions_dropped } as aicore.chatv2 validated them (operations.lua);
--- kept with the exchange, behind the same unlock as its text.
function UI:deliver(requestId, text, jobId, extra)
  local id, a = findAsk(self, requestId, jobId)
  if a == nil then
    if orphaned(self, requestId) or orphaned(self, jobId) then
      self.counters.answers_dropped = self.counters.answers_dropped + 1
      return true
    end
    return false
  end
  self.asks[id] = nil
  local s = self.sessions[a.token]
  if s == nil then
    self.counters.answers_dropped = self.counters.answers_dropped + 1
    return true
  end
  a.entry.a = Commands.cutBytes(tostring(text or ""), M.LIMITS.answer_bytes)
  a.entry.state, a.entry.message = "answered", nil
  extra = type(extra) == "table" and extra or {}
  local c = self.counters
  -- Validated again here: the driver's parse is the first line, this the
  -- second (a caller that skipped it still cannot hand the page anything
  -- outside the contract).
  local display, dDropped = ChatV2.display(extra.display)
  local suggestions, sDropped = ChatV2.suggestions(extra.suggestions)
  a.entry.display, a.entry.suggestions = display, suggestions
  c.display_dropped = c.display_dropped + (tonumber(extra.display_dropped) or 0) + dDropped
  c.suggestions_dropped = c.suggestions_dropped + (tonumber(extra.suggestions_dropped) or 0) + sDropped
  if display ~= nil then
    c.display_answers = c.display_answers + 1
    c.display_blocks = c.display_blocks + #display
  end
  c.suggestions_kept = c.suggestions_kept + (suggestions ~= nil and #suggestions or 0)
  self:offerActions(s, a.entry, extra.actions, extra.actions_dropped)
  if not self:unlocked(s) then
    self.counters.answers_held = self.counters.answers_held + 1
  end
  notify(self)
  return true
end

-- chat actions v1 ---------------------------------------------------------------

--- The action cards of an answer (deliver_result `actions`, validated by
--- aicore.chatactions). Kept only for an exchange asked under an owner
--- unlock whose session is still unlocked now: a card is never shown to a
--- session that is not elevated.
function UI:offerActions(s, entry, list, dropped)
  local c = self.counters
  c.actions_dropped = c.actions_dropped + (tonumber(dropped) or 0)
  local items, d2 = ChatActions.actions(list)
  c.actions_dropped = c.actions_dropped + d2
  if items == nil then
    return
  end
  if not entry.elevated or not self:unlocked(s) then
    c.actions_dropped = c.actions_dropped + #items
    return
  end
  local t = self:now()
  entry.actions = {}
  for _, a in ipairs(items) do
    entry.actions[#entry.actions + 1] = {
      ref = a.ref,
      title = a.title,
      detail = a.detail,
      expires_at = t + a.expires_in,
      offered_at = t, -- one tap only for ChatActions.LIMITS.one_tap_seconds after this
      state = "offered",
    }
    c.actions_offered = c.actions_offered + 1
  end
end

--- Every card of `s` goes (its owner unlock ended). A decision already
--- sent may still be carried out by the platform; the page just stops
--- following it.
function UI:removeActions(s)
  for _, e in ipairs(s.conversation) do
    if e.actions ~= nil then
      self.counters.actions_removed = self.counters.actions_removed + #e.actions
      e.actions = nil
    end
  end
end

local function findAction(s, ref)
  for _, e in ipairs(s.conversation) do
    for _, a in ipairs(e.actions or {}) do
      if a.ref == ref then
        return a
      end
    end
  end
  return nil
end

--- The page's view of an exchange's cards.
function UI:actionsView(e)
  if e.actions == nil then
    return nil
  end
  if self.approvals.at ~= nil and not self.approvals.enabled then
    return nil -- the homeowner switched touchscreen approvals off: no stale card
  end
  local t = self:now()
  local out = {}
  for _, a in ipairs(e.actions) do
    if a.state == "offered" and t >= a.expires_at then
      a.state, a.message = "expired", M.text("action_expired")
    elseif a.state == "offered" and t - a.offered_at >= ChatActions.LIMITS.one_tap_seconds then
      -- The platform takes one tap only in the first 300 s: then Use PIN.
      a.needs_pin = true
    end
    out[#out + 1] = {
      ref = a.ref,
      title = a.title,
      detail = a.detail,
      state = a.state,
      message = a.message,
      needs_pin = a.needs_pin == true or nil, -- "Use PIN" (Confirm is not offered then)
      expires_in = a.state == "offered" and math.max(0, a.expires_at - t) or nil,
    }
  end
  return out
end

--- The ref "Use PIN" may review: a card of this session the platform (or
--- this driver) said needs a fresh PIN.
function UI:pinRefFor(s, ref)
  if type(ref) ~= "string" then
    return nil
  end
  local a = findAction(s, ref:lower())
  return a ~= nil and a.needs_pin and a.ref or nil
end

--- A refused step of a card: the platform's sentence, and Use PIN when the
--- reason says a PIN is needed.
local function actionRefused(self, a, answer)
  local reason = cloudReason(answer)
  local kind = ChatActions.REFUSAL[reason]
  a.state = kind == "withdraw" and "withdrawn" or "refused"
  a.needs_pin = kind == "use_pin"
  a.message = M.text(reason)
  self.counters.actions_refused = self.counters.actions_refused + 1
  self:refused("approval_decide", answer)
end

--- One tap on a card: approve ("Confirm") or decline ("Cancel"). The same
--- plumbing as the approvals review — approval_detail for the args_hash,
--- then approval_decide — with the session's LIVE owner proof as a
--- "pin_lock_session" verification, read again at each step. A card is
--- decided once; a second tap is refused (action_busy).
function UI:decideAction(s, ref, decision)
  if decision ~= M.DECISIONS[1] and decision ~= M.DECISIONS[2] then
    return false, "bad_decision"
  end
  if type(ref) ~= "string" then
    return false, "action_gone"
  end
  local proof = proofFor(self, s, "chat_view", s.sid)
  if proof == nil then
    return false, "action_locked"
  end
  local a = findAction(s, ref:lower())
  if a == nil then
    return false, "action_gone"
  end
  if a.state == "expired" then
    return false, "action_expired"
  end
  if a.state ~= "offered" and not (a.state == "refused" and decision == "decline") then
    return false, "action_busy"
  end
  if self:now() >= a.expires_at then
    a.state, a.message = "expired", M.text("action_expired")
    return false, "action_expired"
  end
  if decision == "approve" and (a.needs_pin or self:now() - a.offered_at >= ChatActions.LIMITS.one_tap_seconds) then
    a.needs_pin = true
    return false, "action_needs_pin"
  end
  if not self.deps.take() then
    return false, "rate_limited"
  end
  a.state = "checking"
  a.decision = decision
  self.deps.cloud(
    "approval_detail",
    M.detailBody(self.deps.newRequestId(), a.ref, proof, ChatActions.SESSION_METHOD),
    function(answer)
      self:actionDetailed(s, a, answer)
    end
  )
  return true
end

function UI:actionDetailed(s, a, answer)
  if findAction(s, a.ref) ~= a then
    return -- the card went (the unlock ended)
  end
  answer = type(answer) == "table" and answer or {}
  local r = type(answer.result) == "table" and answer.result or {}
  if answer.status ~= "ok" then
    actionRefused(self, a, answer)
    notify(self)
    return
  end
  local argsHash = type(r.args_hash) == "string" and r.args_hash:lower() or ""
  if r.ref ~= a.ref or not argsHash:match("^[0-9a-f]+$") or #argsHash ~= 64 then
    a.state, a.message = "refused", M.text("unavailable")
    self.counters.actions_refused = self.counters.actions_refused + 1
    notify(self)
    return
  end
  if a.decision == "approve" and r.risk ~= "low" then
    -- One tap is for low-risk actions only, whatever the platform offered.
    a.state, a.needs_pin, a.message = "refused", true, M.text("action_needs_pin")
    self.counters.actions_refused = self.counters.actions_refused + 1
    notify(self)
    return
  end
  local proof = proofFor(self, s, "chat_view", s.sid)
  if proof == nil then
    return -- locked meanwhile: nothing is decided
  end
  a.state = "sending"
  self.deps.cloud(
    "approval_decide",
    M.decideBody(self.deps.newRequestId(), a.ref, a.decision, argsHash, proof, ChatActions.SESSION_METHOD),
    function(ans)
      self:actionDecided(s, a, ans)
    end
  )
  notify(self)
end

function UI:actionDecided(s, a, answer)
  if findAction(s, a.ref) ~= a then
    return
  end
  answer = type(answer) == "table" and answer or {}
  local r = type(answer.result) == "table" and answer.result or {}
  if answer.status ~= "ok" then
    actionRefused(self, a, answer)
  elseif a.decision == "decline" then
    a.state, a.message = "declined", M.OUTCOME_TEXT.denied
    self.counters.actions_declined = self.counters.actions_declined + 1
  elseif r.status == "queued" then
    -- Sent. Done or Failed only from the execution state approval_detail
    -- reports (pollActions); never assumed.
    a.state = "sent"
    a.sent_at = self:now()
    a.next_poll = self:now() + ChatActions.LIMITS.poll_seconds
    a.polls = 0
    self.counters.actions_confirmed = self.counters.actions_confirmed + 1
  else
    a.state, a.message = "failed", M.OUTCOME_TEXT[r.status] or M.FALLBACK_TEXT
    self.counters.actions_failed = self.counters.actions_failed + 1
  end
  self.approvals.at = nil -- the list changed: ask again
  notify(self)
end

--- Follows sent decisions of `s`: approval_detail every 2 s (one in flight
--- per card, at most 15), "No confirmation from the controller yet" after
--- 30 s. Run on every /state (the page polls every second while a card is
--- in progress) and on the driver's tick.
function UI:pollActions(s)
  local t = self:now()
  local L = ChatActions.LIMITS
  for _, e in ipairs(s.conversation) do
    for _, a in ipairs(e.actions or {}) do
      if a.state == "sent" and t - a.sent_at >= L.outcome_wait_seconds and not a.inflight then
        a.state, a.message = "unconfirmed", "No confirmation from the controller yet."
        self.counters.actions_unconfirmed = self.counters.actions_unconfirmed + 1
      elseif a.state == "sent" and not a.inflight and t >= a.next_poll and a.polls < L.polls then
        local proof = proofFor(self, s, "chat_view", s.sid)
        if proof ~= nil then
          a.inflight, a.polls, a.next_poll = true, a.polls + 1, t + L.poll_seconds
          self.deps.cloud(
            "approval_detail",
            M.detailBody(self.deps.newRequestId(), a.ref, proof, ChatActions.SESSION_METHOD),
            function(answer)
              a.inflight = false
              if findAction(s, a.ref) ~= a or a.state ~= "sent" then
                return
              end
              local r = type(answer) == "table" and answer.status == "ok" and answer.result or nil
              local st, msg = ChatActions.executionOf(r)
              if st == "done" then
                a.state, a.message = "done", nil
                self.counters.actions_done = self.counters.actions_done + 1
              elseif st == "failed" then
                a.state, a.message = "failed", msg or M.OUTCOME_TEXT.failed
                self.counters.actions_failed = self.counters.actions_failed + 1
              end
              notify(self)
            end
          )
        end
      end
    end
  end
end

--- Whether a deliver_result (its request id, its job id) answers a
--- touchscreen ask: one still waited for, or one abandoned within the hour.
function UI:owns(requestId, jobId)
  local _, a = findAsk(self, requestId, jobId)
  return a ~= nil or orphaned(self, requestId) or orphaned(self, jobId)
end

--- A deliver_result marked for this page (channel touchscreen) that no ask
--- here owns — the driver restarted, or the accept answer was lost: dropped
--- and counted. It is never a Composer answer.
function UI:dropUnowned()
  self.counters.answers_dropped = self.counters.answers_dropped + 1
end

--- Touchscreen asks waiting for an answer: how many, and the oldest's age.
function UI:waiting()
  local n, oldest = 0, nil
  for _, a in pairs(self.asks) do
    n = n + 1
    local age = self:now() - a.entry.at
    if oldest == nil or age > oldest then
      oldest = age
    end
  end
  return n, oldest
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
  local open = self:openMode()
  if p == nil and not open then
    return nil
  end
  local list = {}
  local t = self:now()
  for _, e in ipairs(s.conversation) do
    -- Never an exchange asked under an owner unlock to a session that is
    -- not unlocked now (relock removes them; this holds even if the access
    -- mode was changed while they were kept).
    if p ~= nil or not e.elevated then
      list[#list + 1] = {
        id = e.id,
        q = e.q,
        a = e.a,
        state = e.state,
        message = e.message,
        at = e.at,
        age = math.max(0, t - e.at), -- seconds since it was asked (the page's thinking timer)
        conv = e.conv,
        elevated = e.elevated == true, -- asked under an owner unlock (the page marks where that began)
        display = e.display,
        suggestions = e.suggestions,
        actions = p ~= nil and self:actionsView(e) or nil,
      }
    end
  end
  local sug = {}
  local presets, rev = currentPresets(self)
  for i, text in ipairs(presets) do
    sug[#sug + 1] = { id = "p" .. i .. "-" .. rev, label = text }
  end
  for _, x in ipairs(M.SUGGESTIONS) do
    sug[#sug + 1] = { id = x.id, label = x.label }
  end
  return {
    locked = false,
    mode = open and "open" or "owner_pin",
    elevated = p ~= nil, -- owner-unlocked (open mode: the elevation)
    can_elevate = open and p == nil and self:pinUsable(), -- "Unlock for more"
    -- whichever comes first: 5 minutes without use, or 30 minutes after the PIN
    locks_in = p ~= nil and math.max(0, p.ends - self:now()) or nil,
    -- true: the 30 minutes after the PIN end it, and using the chat no longer extends it
    locks_fixed = p ~= nil and p.ends >= p.max or nil,
    conversation = list,
    suggestions = sug,
    explain = p ~= nil, -- house activity: owner unlock only
    detail = self.deps.detail(),
    conv = s.conv, -- this unlock's conversation (entries with another conv are from before)
    followups = not self.refusedAskKeys.thread, -- whether the cloud is told the conversation (a thread per conversation)
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
  if s.checking ~= nil then
    doc.checking = true
  end
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
  ["/chat/action"] = true,
  ["/approvals/refresh"] = true,
  ["/approvals/next"] = true,
  ["/approvals/decide"] = true,
  ["/approvals/close"] = true,
}
M.POSTS = POSTS

--- Body keys each route accepts (closed). No route accepts `pin`.
local BODY_KEYS = {
  ["/pin/done"] = { challenge_id = true },
  ["/chat/lock"] = { hidden = true },
  ["/chat/action"] = { ref = true, decision = true },
  ["/approvals/next"] = { ref = true },
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
    -- hidden = the page was hidden: in open mode the whole conversation goes.
    self:relock(s, body.hidden == true)
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
  if path == "/chat/action" then
    local ok, why = self:decideAction(s, body.ref, body.decision)
    if not ok then
      return refusal(200, why)
    end
    interacted(self, s)
    return reply(200, { ok = true })
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
    -- `ref`: a chat action card that needs a fresh PIN ("Use PIN"); only a
    -- ref this session was offered and the platform said needs a PIN.
    local ref
    if body.ref ~= nil then
      ref = self:pinRefFor(s, body.ref)
    else
      ref = nextRef(self, s)
    end
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
        self:refused("approval_decide", answer)
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

--- Chat v2 in one line, counts only (Print Diagnostics): the capability,
--- conversation threads, and what validation kept and dropped from the
--- cloud's blocks and follow-up questions.
function UI:chatLine()
  local c = self.counters
  return string.format(
    "%s declared; %d conversation(s) started, %d ask(s) sent again without a thread; "
      .. "%d answer(s) with blocks, %d block(s) shown, %d dropped; %d follow-up(s) shown, %d dropped; "
      .. "%s: %d ask(s) with owner_proof, %d card(s) offered, %d dropped, %d removed at lock, "
      .. "%d confirmed, %d cancelled, %d done, %d failed, %d refused, %d unconfirmed",
    ChatV2.CAPABILITY,
    c.threads_minted,
    c.thread_retries,
    c.display_answers,
    c.display_blocks,
    c.display_dropped,
    c.suggestions_kept,
    c.suggestions_dropped,
    ChatActions.CAPABILITY,
    c.owner_proof_sent,
    c.actions_offered,
    c.actions_dropped,
    c.actions_removed,
    c.actions_confirmed,
    c.actions_declined,
    c.actions_done,
    c.actions_failed,
    c.actions_refused,
    c.actions_unconfirmed
  )
end

--- A one-line summary for the read-only Composer property.
function UI:summary()
  local detail = self.deps.detail()
  local pinPart
  if self:pinUsable() then
    pinPart = "PIN Lock ready (owner PINs only)"
  else
    pinPart = "PIN Lock unavailable ("
      .. tostring(self.pinState.reason)
      .. (self:openMode() and "): approvals and the owner unlock off" or "): chat and approvals off, use the portal")
  end
  local chatPart
  if detail == "basic" then
    chatPart = "chat off (Basic)"
  elseif self:openMode() then
    chatPart = "chat open (standard without a PIN; " .. detail .. " after an owner PIN)"
  else
    chatPart = "chat " .. detail .. ", owner PIN to view"
  end
  local a = self.approvals
  local apPart
  if self.refusals.approvals_pending ~= nil then
    -- Not "off": the list itself could not be read. Say what came back.
    apPart = "approvals not available (" .. M.refusalLine(self.refusals.approvals_pending) .. ")"
  elseif a.at == nil then
    apPart = "approvals not checked yet"
  elseif a.enabled then
    apPart = "approvals on in the homeowner portal"
  else
    apPart = "approvals off (enable in the homeowner portal)"
  end
  return pinPart .. "; " .. chatPart .. "; " .. apPart .. "; " .. self:sessionCount() .. " page(s) open"
end

return M
