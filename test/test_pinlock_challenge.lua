-- PIN Lock challenge store (AI Core verification): closed args, bounded
-- store (the 9th open challenge is REFUSED), 60 s expiry for /verify and
-- redeem, one /verify attempt, one redeem that consumes whatever the
-- answer, binding to purpose + subject + nonce + requesting instance (an
-- approval grant is refused as a chat unlock and the reverse), and that
-- nothing it returns carries a PIN or a code name.
--
-- Run from the driver root: make test

package.path = "src/?.lua;" .. package.path
require("drivers-common-public.global.lib")
local Challenge = require("pinlock.challenge")

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

local clock = { t = 1800000000 }
local seq = 0
local function newStore()
  return Challenge.new({
    now = function()
      return clock.t
    end,
    newId = function()
      seq = seq + 1
      return string.format("%032x", seq)
    end,
  })
end

local OWNER_PIN = "7391" -- test value
local PROPOSAL = "3f2b8c1e-5d4a-4e8b-9c7d-1a2b3c4d5e6f"
local PROPOSAL_2 = "9a8b7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d"
local SESSION = string.rep("ab", 16)
local NONCE = string.rep("1f", 16)
local AI = "700"

--- A fake engine check that records what it was given and answers like
--- Engine:verifyOwnerPin (which never includes a code name).
local checked = {}
local function ownerCheck(pin)
  checked[#checked + 1] = pin
  if pin == OWNER_PIN then
    return { ok = true, role = "owner", slot = 2 }
  end
  return { ok = false, reason = "wrong_pin" }
end
local function lockedCheck()
  return { ok = false, locked = true, retry_in = 240, reason = "locked_out" }
end
local function open()
  return true
end

local function approval(subject, nonce)
  return { purpose = "approval", subject = subject or PROPOSAL, nonce = nonce or NONCE }
end
local function chat(subject, nonce)
  return { purpose = "chat_view", subject = subject or SESSION, nonce = nonce or NONCE }
end
local function redeemArgs(c, over)
  local a = { challenge_id = c.id, nonce = c.nonce, purpose = c.purpose, subject = c.subject }
  for k, v in pairs(over or {}) do
    a[k] = v
  end
  return a
end

print("[1] issue: closed args")
local s = newStore()
local c = s:issue(AI, approval())
check("approval challenge issued: 32-hex id, 60 s", c ~= nil and Challenge.hex32(c.id) and c.expires == clock.t + 60)
check("chat_view challenge issued", s:issue(AI, chat()) ~= nil)
local bad = {
  { "unknown key", { purpose = "approval", subject = PROPOSAL, nonce = NONCE, pin = "x" } },
  { "unknown purpose", { purpose = "settings", subject = PROPOSAL, nonce = NONCE } },
  { "approval subject not a uuid", approval("not-a-uuid") },
  { "chat_view subject not 32 hex", chat("abc") },
  { "a uuid is not a chat_view subject", chat(PROPOSAL) },
  { "nonce not 32 hex", approval(nil, "123") },
  { "nonce upper-case hex", approval(nil, string.rep("1F", 16)) },
  { "args not a table", "x" },
}
for _, b in ipairs(bad) do
  local got, code = s:issue(AI, b[2])
  check(b[1] .. " → invalid_args", got == nil and code == "invalid_args", code)
end
local noReq, codeReq = s:issue("", approval())
check("no requester instance → not_permitted", noReq == nil and codeReq == "not_permitted")

print("[2] bounded: the 9th open challenge is refused, never evicting one")
s = newStore()
local first
for i = 1, Challenge.MAX_OPEN do
  local x = s:issue(AI, approval())
  first = first or x
  check("challenge " .. i .. " issued", x ~= nil)
end
local over, overCode, overWhy = s:issue(AI, approval())
check("challenge 9 refused rate_limited/busy", over == nil and overCode == "rate_limited" and overWhy == "busy")
check("the first one is still there (no eviction)", s.open[first.id] ~= nil and s:count() == Challenge.MAX_OPEN)
clock.t = clock.t + 60
check("once they expire, room is made again", s:issue(AI, approval()) ~= nil)
clock.t = clock.t - 60

print("[3] verify: one PIN check per challenge, three reply shapes")
s = newStore()
checked = {}
c = s:issue(AI, approval())
local r = s:verify(c.id, OWNER_PIN, ownerCheck, open)
check("owner PIN → {ok=true}", r.ok == true and next(r, next(r)) == nil)
r = s:verify(c.id, OWNER_PIN, ownerCheck, open)
check("a second /verify on the same challenge → {ok=false}, no PIN check", r.ok == false and #checked == 1)
c = s:issue(AI, approval())
r = s:verify(c.id, "3047", ownerCheck, open)
check("wrong PIN → {ok=false} only", r.ok == false and r.locked == nil and r.reason == nil)
c = s:issue(AI, approval())
r = s:verify(c.id, OWNER_PIN, lockedCheck, open)
check(
  "locked → {ok=false, locked=true, retry_in}",
  r.ok == false and r.locked == true and r.retry_in == 240 and r.reason == nil
)
local before = #checked
r = s:verify(string.rep("0", 32), OWNER_PIN, ownerCheck, open)
check("unknown challenge → {ok=false} without a PIN check", r.ok == false and #checked == before)
r = s:verify("not hex", OWNER_PIN, ownerCheck, open)
check("malformed challenge id → {ok=false} without a PIN check", r.ok == false and #checked == before)
c = s:issue(AI, approval())
r = s:verify(c.id, OWNER_PIN, ownerCheck, function()
  return false
end)
check("gate closed (feature off) → {ok=false} without a PIN check", r.ok == false and #checked == before)
check("...and that challenge redeems not_verified", s:redeem(AI, redeemArgs(c)).reason == "not_verified")
for _, role in ipairs({ "guest", "vendor", "staff" }) do
  c = s:issue(AI, approval())
  r = s:verify(c.id, OWNER_PIN, function()
    return { ok = true, role = role, slot = 3 } -- an engine that let a non-owner through
  end, open)
  check("a non-owner '" .. role .. "' success from the engine is still refused", r.ok == false)
  check("...and redeems not_verified", s:redeem(AI, redeemArgs(c)).reason == "not_verified")
end

print("[4] 60 s expiry")
s = newStore()
c = s:issue(AI, approval())
clock.t = clock.t + 59
check("verify at 59 s works", s:verify(c.id, OWNER_PIN, ownerCheck, open).ok == true)
clock.t = clock.t + 1
check("redeem at 60 s → expired (even though verified)", s:redeem(AI, redeemArgs(c)).reason == "expired")
c = s:issue(AI, approval())
clock.t = clock.t + 60
before = #checked
check(
  "verify at 60 s → {ok=false}, no PIN check",
  s:verify(c.id, OWNER_PIN, ownerCheck, open).ok == false and #checked == before
)
check("...and redeem → expired", s:redeem(AI, redeemArgs(c)).reason == "expired")

print("[5] redeem: single use, whatever the answer")
s = newStore()
c = s:issue(AI, approval())
s:verify(c.id, OWNER_PIN, ownerCheck, open)
r = s:redeem(AI, redeemArgs(c))
check(
  "verified → {verified, verified_at (whole epoch seconds), role}; no slot",
  r.verified == true
    and type(r.verified_at) == "number"
    and r.verified_at == math.floor(r.verified_at)
    and r.verified_at > 1700000000
    and r.role == "owner"
    and r.slot == nil
)
local keys = {}
for k in pairs(r) do
  keys[#keys + 1] = k
end
table.sort(keys)
check(
  "redeem result keys are exactly role, verified, verified_at",
  table.concat(keys, ",") == "role,verified,verified_at"
)
r = s:redeem(AI, redeemArgs(c))
check("replay of the same redeem → unknown (consumed)", r.verified == false and r.reason == "unknown")
c = s:issue(AI, approval())
r = s:redeem(AI, redeemArgs(c))
check("never verified → not_verified", r.verified == false and r.reason == "not_verified")
check("...and consumed: a late /verify finds nothing", s:verify(c.id, OWNER_PIN, ownerCheck, open).ok == false)
c = s:issue(AI, approval())
s:verify(c.id, "3047", ownerCheck, open)
check("wrong PIN → not_verified", s:redeem(AI, redeemArgs(c)).reason == "not_verified")
c = s:issue(AI, approval())
s:verify(c.id, OWNER_PIN, lockedCheck, open)
check("locked at verify → locked", s:redeem(AI, redeemArgs(c)).reason == "locked")
local nilR, badCode = s:redeem(AI, { challenge_id = c.id })
check("malformed redeem args → invalid_args", nilR == nil and badCode == "invalid_args")
nilR, badCode = s:redeem(AI, redeemArgs(s:issue(AI, approval()), { extra = "x" }))
check("unknown redeem key → invalid_args", nilR == nil and badCode == "invalid_args")

print("[6] binding: purpose, subject, nonce, instance")
local function boundCase(name, issueArgs, over, requester)
  local st = newStore()
  local ch = st:issue(AI, issueArgs)
  st:verify(ch.id, OWNER_PIN, ownerCheck, open)
  local res = st:redeem(requester or AI, redeemArgs(ch, over))
  check(name .. " → wrong_subject", res.verified == false and res.reason == "wrong_subject", res.reason)
  check(name .. " → consumed anyway", st:redeem(AI, redeemArgs(ch)).reason == "unknown")
end
boundCase("an approval grant redeemed as chat_view", approval(), { purpose = "chat_view", subject = SESSION })
boundCase("a chat_view grant redeemed as an approval", chat(), { purpose = "approval", subject = PROPOSAL })
boundCase("an approval grant redeemed for another proposal", approval(), { subject = PROPOSAL_2 })
boundCase("a chat grant redeemed for another session", chat(), { subject = string.rep("cd", 16) })
boundCase("the wrong nonce", approval(), { nonce = string.rep("2e", 16) })
boundCase("another AI Core instance", approval(), nil, "701")
s = newStore()
c = s:issue(AI, approval(PROPOSAL:upper()))
s:verify(c.id, OWNER_PIN, ownerCheck, open)
check("uuid case does not matter", s:redeem(AI, redeemArgs(c, { subject = PROPOSAL })).verified == true)

print("[7] nothing returned carries a PIN or a code name")
s = newStore()
local everything = {}
local JSON = require("JSON")
c = s:issue(AI, approval())
everything[#everything + 1] = JSON:encode({ c.id, c.expires })
everything[#everything + 1] = JSON:encode(s:verify(c.id, OWNER_PIN, function()
  -- even an engine result that carried a name is not copied
  return { ok = true, role = "owner", slot = 1, code = "Owner Marta" }
end, open))
local verifiedStore = JSON:encode(s.open) -- verified, not yet redeemed
everything[#everything + 1] = JSON:encode(s:redeem(AI, redeemArgs(c)))
local blob = table.concat(everything, "\n")
check("no PIN in any answer", blob:find(OWNER_PIN, 1, true) == nil)
check("no code name in any answer", blob:find("Marta", 1, true) == nil)
local stored = JSON:encode(s.open)
check("the store holds no PIN", stored:find(OWNER_PIN, 1, true) == nil)
check(
  "a verified challenge holds the role but no slot (the engine's slot is not copied)",
  verifiedStore:find('"role":"owner"', 1, true) ~= nil and verifiedStore:find("slot", 1, true) == nil
)

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
