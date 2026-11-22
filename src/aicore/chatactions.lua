--- SmartBuildOS AI Core -- actions from the touchscreen chat ("chat
--- actions v1", pure). The contract with the platform (DRIVER.md §7b):
---
---   capability  `chat_actions_v1`, declared beside `chat_v2`.
---   ask         optional `owner_proof` = { nonce, verified_at, role,
---               method } from the session's live owner proof (webui
---               ownerProofFor), on every ask at any non-Basic detail.
---   deliver_result
---               optional `actions`: up to 3 { ref, title, detail,
---               expires_in, tap_in } — proposals the platform built for this
---               answer. Validated here; an invalid item is dropped and
---               counted, never the answer.
---   confirm     one tap: approval_detail for the ref (its args_hash) then
---               approval_decide with verification method
---               "pin_lock_session" (the session's live owner proof at the
---               tap). Cancel: the same with decision decline.
---   outcome     approval_detail polled every 2 s for 30 s; Done / Failed
---               only from the execution state the platform reports.
---
--- Every parser of a platform shape for chat actions is in THIS file, so the
--- wire shapes change in one place.

local ChatV2 = require("aicore.chatv2")

local M = {}

M.CAPABILITY = "chat_actions_v1"
M.SESSION_METHOD = "pin_lock_session"
M.OWNER_PROOF_FIELD = "owner_proof"

M.LIMITS = {
  actions = 3, -- per answer
  title = 80, -- code points (as an approval's title)
  detail = 300, -- code points (as an approval's description)
  expires_min = 1, -- seconds
  expires_max = 1800,
  tap_max = 300, -- `tap_in`: seconds left for a one-tap confirm (0 = the PIN flow from the start)
  tap_margin = 10, -- the last seconds of tap_in already need a PIN (delivery lag)
  -- The outcome: approval_detail at these seconds after the approved
  -- decision (6 polls at most per card), stopping at the first terminal
  -- execution state. The platform's RPC budget is 30 requests a minute per
  -- module, shared with asks and approvals, so ONE poller for every card of
  -- every session sends at most one poll every `poll_gap_seconds` and at
  -- most `polls_per_minute` in all.
  poll_schedule = { 2, 5, 9, 15, 22, 30 },
  poll_gap_seconds = 2,
  polls_per_minute = 10,
  outcome_give_up_seconds = 40, -- a last slot the shared cap delayed this long: given up
  poll_lost_seconds = 15, -- a poll with no answer this long is taken as lost
}

local ITEM_KEYS = { ref = true, title = true, detail = true, expires_in = true, tap_in = true }
local UUID = "^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$"

local function closed(t, allowed)
  for k in pairs(t) do
    if not allowed[k] then
      return false
    end
  end
  return true
end

--- One item, normalised, or nil (dropped): `ref` a uuid (the reference
--- approval_detail and approval_decide take), `title` and `detail` plain
--- text under the chat v2 rules, `expires_in` whole seconds.
local function item(a)
  if type(a) ~= "table" or not closed(a, ITEM_KEYS) then
    return nil
  end
  local L = M.LIMITS
  if type(a.ref) ~= "string" or #a.ref ~= 36 or not a.ref:match(UUID) then
    return nil
  end
  local title = ChatV2.plain(a.title, L.title)
  local detail = a.detail ~= nil and ChatV2.plain(a.detail, L.detail) or nil
  local e = tonumber(a.expires_in)
  -- A title must say something: at least one letter or digit (a card with
  -- a blank or symbol-only title never gets a live Confirm).
  if title == nil or not ChatV2.hasWordChar(title) or (a.detail ~= nil and detail == nil) then
    return nil
  end
  if e == nil or e ~= math.floor(e) or e < L.expires_min or e > L.expires_max then
    return nil
  end
  -- REQUIRED: how long the platform still takes a one-tap confirm, counted
  -- by the platform from the proposal's creation. 0: Use PIN from the start.
  local tap = a.tap_in
  if type(tap) ~= "number" or tap ~= math.floor(tap) or tap < 0 or tap > L.tap_max then
    return nil
  end
  return { ref = a.ref:lower(), title = title, detail = detail, expires_in = e, tap_in = tap }
end

--- deliver_result `actions` (native, or a JSON-encoded string) → items
--- (nil when none survive) and how many were dropped (1 for a value that
--- could not be read). A ref given twice is kept once.
function M.actions(v)
  if v == nil then
    return nil, 0
  end
  if type(v) == "string" then
    if #v > 4096 then
      return nil, 1
    end
    local ok, t = pcall(function()
      return JSON:decode(v)
    end)
    if not ok or type(t) ~= "table" then
      return nil, 1
    end
    v = t
  end
  if type(v) ~= "table" then
    return nil, 1
  end
  local n = 0
  for _ in pairs(v) do
    n = n + 1
  end
  if n ~= #v then
    return nil, 1
  end
  local out, seen, dropped = {}, {}, 0
  for _, a in ipairs(v) do
    local x = #out < M.LIMITS.actions and item(a) or nil
    if x == nil or seen[x.ref] then
      dropped = dropped + 1
    else
      seen[x.ref] = true
      out[#out + 1] = x
    end
  end
  return #out > 0 and out or nil, dropped
end

--- The verification a one-tap decision carries: the session's live owner
--- proof, said to be a session proof (never a PIN; PIN Lock verified it at
--- the unlock).
function M.sessionVerification(proof)
  return { nonce = proof.nonce, verified_at = proof.verified_at, role = proof.role, method = M.SESSION_METHOD }
end

-- ── the platform's refusals and execution states (contract 2026-11-21) ───────

--- Refusals of a session-verified detail or decision (error_code
--- not_permitted, or rate_limited): what the card does with each.
---   use_pin   the sentence and "Use PIN" (the existing approvals review)
---   withdraw  the sentence, and the card's buttons go
M.REFUSAL = {
  session_risk_too_high = "use_pin", -- approve only
  session_needs_pin = "use_pin", -- approve only
  session_proposal_too_old = "use_pin", -- approve only, after 300 s
  rate_limited = "use_pin", -- 20 per controller per hour
  session_not_bound = "withdraw",
  session_stale = "withdraw",
}

--- The execution state a SESSION-verified approval_detail reports for an
--- action no longer waiting: `execution = { state = pending | completed |
--- failed | expired, reason?, message? }`. Returns "done", "failed" (with
--- the platform's sentence, shown verbatim) or "pending" — a detail
--- without `execution` is still pending.
function M.executionOf(result)
  local ex = type(result) == "table" and type(result.execution) == "table" and result.execution or nil
  if ex == nil then
    return "pending", nil
  end
  if ex.state == "completed" then
    return "done", nil
  end
  if ex.state == "failed" or ex.state == "expired" then
    return "failed", ChatV2.plain(ex.message, 300)
  end
  return "pending", nil
end

return M
