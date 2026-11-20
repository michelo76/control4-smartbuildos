--- PIN Lock -- AI Core verification challenges (pure; injected clock and id).
---
--- AI Core never sees a PIN. It asks PIN Lock for a challenge over the module
--- bus (pinlock.challenge), the AI Core touchscreen page posts the PIN to
--- PIN Lock's own relay (POST /verify, authenticated by the challenge id),
--- and AI Core then redeems the challenge over the bus (pinlock.redeem) to
--- learn the outcome. No bus frame carries a PIN.
---
--- A challenge is:
---   * in memory only (a driver restart forgets every challenge);
---   * bounded: at most M.MAX_OPEN live at once; the next one is REFUSED
---     (`busy`), it never evicts a challenge a page may be typing against;
---   * valid M.TTL seconds from issue, for /verify and for redeem alike;
---   * good for ONE /verify attempt (one PIN checked by the engine);
---   * consumed by ONE redeem, whatever the answer;
---   * bound to its purpose ("approval" of one proposal, or "chat_view" of
---     one page session), its subject, the requester's nonce and the AI Core
---     instance that asked. A redeem that names another purpose, subject or
---     nonce, or comes from another instance, answers `wrong_subject` (and
---     still consumes it), so an approval grant can never be redeemed as a
---     chat unlock or the reverse.
---
--- The store never holds a PIN, and it never holds or returns a code NAME
--- or slot: from the engine's verification result it keeps the role only.
--- A verified redeem answers exactly { verified = true, verified_at = <whole
--- epoch seconds>, role = "owner" } (spec rulings 21 and 22): nothing that
--- identifies which owner code was typed leaves PIN Lock.

local M = {}

M.TTL = 60
M.MAX_OPEN = 8
--- Closed purposes and the shape of their subject.
M.PURPOSES = {
  approval = "^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$", -- proposal uuid
  chat_view = "^[0-9a-f]+$", -- page session id, 32 hex (length checked below)
}
M.CHALLENGE_ARGS = { purpose = true, subject = true, nonce = true }
M.REDEEM_ARGS = { challenge_id = true, nonce = true, purpose = true, subject = true }

local function hex32(s)
  return type(s) == "string" and #s == 32 and s:match("^[0-9a-f]+$") ~= nil
end
M.hex32 = hex32

local function closedKeys(t, allowed)
  if type(t) ~= "table" then
    return false
  end
  for k in pairs(t) do
    if not allowed[k] then
      return false
    end
  end
  return true
end

local function subjectOk(purpose, subject)
  local pattern = M.PURPOSES[purpose]
  if pattern == nil or type(subject) ~= "string" then
    return false
  end
  if purpose == "chat_view" then
    return hex32(subject)
  end
  return #subject == 36 and subject:match(pattern) ~= nil
end
M.subjectOk = subjectOk

local Store = {}
Store.__index = Store

--- deps = { now = fn() -> seconds, newId = fn() -> 32 lowercase hex }
function M.new(deps)
  deps = deps or {}
  assert(type(deps.newId) == "function", "newId required")
  local self = setmetatable({}, Store)
  self.nowFn = deps.now or os.time
  self.newId = deps.newId
  self.open = {} -- [id] = challenge
  return self
end

function Store:now()
  return self.nowFn()
end

--- Live (not yet redeemed) challenges, expired ones included until pruned.
function Store:count()
  local n = 0
  for _ in pairs(self.open) do
    n = n + 1
  end
  return n
end

--- Drops challenges that expired more than one TTL ago (a redeem shortly
--- after expiry still answers `expired`, not `unknown`); when `hard`, every
--- expired one.
function Store:prune(hard)
  local t = self:now()
  for id, c in pairs(self.open) do
    if t >= c.expires + (hard and 0 or M.TTL) then
      self.open[id] = nil
    end
  end
end

--- Forgets every challenge (the dealer switched the feature off, or the
--- codes were wiped).
function Store:clear()
  self.open = {}
end

--- pinlock.challenge. `requester` = the AI Core instance id the Agent
--- stamped on the request. Returns the challenge, or nil + bus error code +
--- reason.
function Store:issue(requester, args)
  if not closedKeys(args, M.CHALLENGE_ARGS) then
    return nil, "invalid_args", "invalid_args"
  end
  if M.PURPOSES[args.purpose] == nil then
    return nil, "invalid_args", "purpose"
  end
  if not subjectOk(args.purpose, args.subject) then
    return nil, "invalid_args", "subject"
  end
  if not hex32(args.nonce) then
    return nil, "invalid_args", "nonce"
  end
  requester = tostring(requester or "")
  if requester == "" then
    return nil, "not_permitted", "requester"
  end
  self:prune(false)
  if self:count() >= M.MAX_OPEN then
    self:prune(true)
  end
  if self:count() >= M.MAX_OPEN then
    return nil, "rate_limited", "busy"
  end
  local id = tostring(self.newId() or "")
  if not hex32(id) or self.open[id] ~= nil then
    return nil, "internal_error", "id"
  end
  local t = self:now()
  local c = {
    id = id,
    purpose = args.purpose,
    subject = args.subject:lower(),
    nonce = args.nonce,
    requester = requester,
    issued = t,
    expires = t + M.TTL,
    state = "open", -- open | verified | failed | locked
  }
  self.open[id] = c
  return c
end

--- POST /verify. `check(pin)` is the engine's owner verification
--- (Engine:verifyOwnerPin); `gate()` false means PIN Lock cannot verify for
--- AI Core right now (switched off, unlicensed, no owner PIN). The reply is
--- one of exactly three shapes: { ok = true }, { ok = false } or
--- { ok = false, locked = true, retry_in = n }. An unknown, expired or
--- already-attempted challenge is { ok = false } without any PIN check.
function Store:verify(id, pin, check, gate)
  local c = hex32(id) and self.open[id] or nil
  if c == nil or c.state ~= "open" or self:now() >= c.expires then
    return { ok = false }
  end
  if type(gate) == "function" and not gate() then
    c.state = "failed"
    return { ok = false }
  end
  local res = check(pin)
  if type(res) ~= "table" then
    c.state = "failed"
    return { ok = false }
  end
  if res.ok == true and res.role == "owner" then
    c.state = "verified"
    c.role = res.role
    c.verified_at = math.floor(self:now())
    return { ok = true }
  end
  if res.locked == true then
    c.state = "locked"
    return { ok = false, locked = true, retry_in = tonumber(res.retry_in) or 0 }
  end
  c.state = "failed"
  return { ok = false }
end

--- pinlock.redeem. Always consumes a challenge it finds. Returns the
--- result table for the bus answer, or nil + bus error code + reason for
--- malformed args.
function Store:redeem(requester, args)
  if not closedKeys(args, M.REDEEM_ARGS) or not hex32(args.challenge_id) or not hex32(args.nonce) then
    return nil, "invalid_args", "invalid_args"
  end
  if M.PURPOSES[args.purpose] == nil or not subjectOk(args.purpose, args.subject) then
    return nil, "invalid_args", "subject"
  end
  local c = self.open[args.challenge_id]
  if c == nil then
    return { verified = false, reason = "unknown" }
  end
  self.open[args.challenge_id] = nil -- single use, whatever the answer
  if
    c.purpose ~= args.purpose
    or c.subject ~= args.subject:lower()
    or c.nonce ~= args.nonce
    or c.requester ~= tostring(requester or "")
  then
    return { verified = false, reason = "wrong_subject" }
  end
  if self:now() >= c.expires then
    return { verified = false, reason = "expired" }
  end
  if c.state == "locked" then
    return { verified = false, reason = "locked" }
  end
  if c.state ~= "verified" then
    return { verified = false, reason = "not_verified" }
  end
  return { verified = true, verified_at = c.verified_at, role = c.role }
end

return M
