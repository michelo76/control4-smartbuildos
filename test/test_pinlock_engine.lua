-- PIN Lock engine: hashing, code validity (hours, dates, uses, roles),
-- attempts, lockouts and their persistence, keypad sequences, admin
-- sessions, licence restriction, persistence, and the rule that no PIN, no
-- sequence and no digest ever shows up in anything the engine emits or lists.
--
-- Run from the driver root: make test

package.path = "src/?.lua;" .. package.path
require("drivers-common-public.global.lib")
local Engine = require("pinlock.engine")

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

-- Deterministic stand-in for C4:HMAC (the shim's), different per key and data.
local function hmac(key, data)
  return C4:HMAC("SHA256", key, data)
end

-- A calendar the tests control: Wednesday 2027-01-06 12:00 local, as an epoch.
local BASE = os.time({ year = 2027, month = 1, day = 6, hour = 12, min = 0, sec = 0 })
local clock = { t = BASE }
local emitted = {}
local function newEngine(extra)
  emitted = {}
  local e = Engine.new({
    now = function()
      return clock.t
    end,
    hmac = hmac,
    emit = function(kind, f)
      emitted[#emitted + 1] = { kind = kind, f = f }
    end,
    settings = extra,
  })
  e:setSlots({ [1] = "Unlock wine cellar", [2] = "Open garage service door", [3] = "Disable alarm zone" })
  return e
end
local function at(h, m, dayOffset)
  local d = os.date("*t", BASE)
  return os.time({ year = d.year, month = d.month, day = d.day + (dayOffset or 0), hour = h, min = m, sec = 0 })
end
local function count(kind)
  local n = 0
  for _, ev in ipairs(emitted) do
    if ev.kind == kind then
      n = n + 1
    end
  end
  return n
end

local OWNER_PIN, STAFF_PIN, VENDOR_PIN, GUEST_PIN = "7391", "4826", "5183", "6290"

print("[1] adding codes: validation")
local e = newEngine()
check("owner code added", e:addCode({ name = "Owner", role = "owner", pin = OWNER_PIN }) ~= false)
check("weak PIN refused", e:addCode({ name = "A", role = "guest", pin = "1234", actions = { 1 } }) == false)
check("repeat PIN refused", e:addCode({ name = "A", role = "guest", pin = "1111", actions = { 1 } }) == false)
check("short PIN refused", e:addCode({ name = "A", role = "guest", pin = "482", actions = { 1 } }) == false)
check("non-digit PIN refused", e:addCode({ name = "A", role = "guest", pin = "48x6", actions = { 1 } }) == false)
local dupOk, dupWhy = e:addCode({ name = "Twin", role = "guest", pin = OWNER_PIN, actions = { 1 } })
check("a PIN already in use is refused", dupOk == false and dupWhy:find("already in use") ~= nil, dupWhy)
check("duplicate name refused (case/space-blind)", e:addCode({ name = "  owner ", role = "guest", pin = STAFF_PIN }) == false)
check("bad role refused", e:addCode({ name = "X", role = "admin", pin = STAFF_PIN }) == false)
check("PIN or sequence needed", e:addCode({ name = "X", role = "guest" }) == false)
check("hours need both ends", e:addCode({ name = "X", role = "guest", pin = STAFF_PIN, from = "08:00" }) == false)
check("hours must be HH:MM", e:addCode({ name = "X", role = "guest", pin = STAFF_PIN, from = "8am", to = "5pm" }) == false)
check("From equal To refused", e:addCode({ name = "X", role = "guest", pin = STAFF_PIN, from = "08:00", to = "08:00" }) == false)
check("expiry must follow start", e:addCode({ name = "X", role = "guest", pin = STAFF_PIN, starts = 100, expires = 50 }) == false)
check("max uses bounded", e:addCode({ name = "X", role = "guest", pin = STAFF_PIN, max_uses = 0.5 }) == false)
check(
  "owner is the only code so far",
  #e.codes == 1 and e:hasOwner()
)

print("[2] storage: hashed and salted, plaintext nowhere")
local snapshot = e:serialize()
local flat = require("JSON"):encode(snapshot)
check("serialised state holds no plaintext PIN", flat:find(OWNER_PIN, 1, true) == nil)
check("serialised state holds a digest and a salt", snapshot.codes[1].pin.hash ~= nil and snapshot.codes[1].pin.salt ~= nil)
e:addCode({ name = "Marta", role = "staff", pin = STAFF_PIN, actions = { 1, 2 } })
local s2 = e:serialize()
check("each code has its own salt", s2.codes[1].pin.salt ~= s2.codes[2].pin.salt)
local pub = require("JSON"):encode(e:publicCodes())
check("admin list carries no digest, salt or PIN", pub:find(s2.codes[1].pin.hash, 1, true) == nil and pub:find(s2.codes[1].pin.salt, 1, true) == nil and pub:find(OWNER_PIN, 1, true) == nil)

print("[3] granting: actions, roles, uses")
e = newEngine()
e:addCode({ name = "Owner", role = "owner", pin = OWNER_PIN })
e:addCode({ name = "Marta", role = "staff", pin = STAFF_PIN, actions = { 1, 2 } })
local r = e:tryPin("page", 1, STAFF_PIN)
check("staff granted an allowed action", r.ok == true and r.code == "Marta" and r.action == "Unlock wine cellar")
local grantedEv
for _, ev in ipairs(emitted) do
  if ev.kind == "granted" then
    grantedEv = ev.f
  end
end
check("granted event emitted once with names", count("granted") == 1 and grantedEv.slot == 1 and grantedEv.code == "Marta")
r = e:tryPin("page", 3, STAFF_PIN)
check("staff refused an action not on its list", r.ok == false and r.reason == "not_allowed")
r = e:tryPin("page", 3, OWNER_PIN)
check("owner fires every action", r.ok == true)
r = e:tryPin("page", 9, OWNER_PIN)
check("unnamed action refused", r.ok == false and r.reason == "no_such_action")
r = e:tryPin("page", 1, "9999")
check("wrong PIN refused", r.ok == false and r.reason == "wrong_pin" and r.code == nil)
check("use counted on grant only", e:find("Marta").uses == 1)

print("[4] weekly hours")
e = newEngine()
e:addCode({ name = "Owner", role = "owner", pin = OWNER_PIN })
e:addCode({
  name = "Vendor",
  role = "vendor",
  pin = VENDOR_PIN,
  actions = { 2 },
  days = { 2, 3, 4, 5, 6 }, -- Monday..Friday
  from = "08:00",
  to = "17:00",
})
clock.t = at(12, 0)
check("inside Wed 12:00", e:tryPin("page", 2, VENDOR_PIN).ok == true)
clock.t = at(7, 59)
check("before opening", e:tryPin("page", 2, VENDOR_PIN).reason == "outside_window")
clock.t = at(17, 0)
check("closing time is exclusive", e:tryPin("page", 2, VENDOR_PIN).reason == "outside_window")
clock.t = at(12, 0, 3) -- Saturday
check("weekend refused", e:tryPin("page", 2, VENDOR_PIN).reason == "outside_window")
-- overnight window Fri 22:00 - 06:00, "Friday" only
e = newEngine()
e:addCode({ name = "Owner", role = "owner", pin = OWNER_PIN })
e:addCode({ name = "Night", role = "staff", pin = STAFF_PIN, actions = { 1 }, days = { 6 }, from = "22:00", to = "06:00" })
clock.t = at(23, 0, 2) -- Friday 23:00
check("overnight: Friday late evening in", e:tryPin("page", 1, STAFF_PIN).ok == true)
clock.t = at(3, 0, 3) -- Saturday 03:00, the Friday window still open
check("overnight: Saturday small hours still the Friday window", e:tryPin("page", 1, STAFF_PIN).ok == true)
clock.t = at(3, 0, 2) -- Friday 03:00 belongs to Thursday's window
check("overnight: Friday small hours is Thursday's, refused", e:tryPin("page", 1, STAFF_PIN).reason == "outside_window")
clock.t = BASE

print("[5] dates and use limits")
e = newEngine()
e:addCode({ name = "Owner", role = "owner", pin = OWNER_PIN })
e:addCode({ name = "Trial", role = "guest", pin = GUEST_PIN, actions = { 1 }, starts = clock.t + 3600, expires = clock.t + 7200, max_uses = 2 })
check("not yet started", e:tryPin("page", 1, GUEST_PIN).reason == "not_yet")
clock.t = clock.t + 4000
check("inside dates", e:tryPin("page", 1, GUEST_PIN).ok == true)
check("second use", e:tryPin("page", 1, GUEST_PIN).ok == true)
check("third use refused: used up", e:tryPin("page", 1, GUEST_PIN).reason == "used_up")
check("state says used up", e:find("Trial") and e:codeState(e:find("Trial")) == "used up")
clock.t = clock.t + 4000
e:find("Trial").uses = 0
check("after expiry", e:tryPin("page", 1, GUEST_PIN).reason == "expired")
check("code is no longer active", e:isActive("Trial") == false and e:isActive("owner") == true)
clock.t = at(12, 0)

print("[6] enable, disable, revoke, last-owner protection")
e = newEngine()
e:addCode({ name = "Owner", role = "owner", pin = OWNER_PIN })
e:addCode({ name = "Marta", role = "staff", pin = STAFF_PIN, actions = { 1 } })
check("disable", e:setEnabled("marta", false) == true and e:tryPin("page", 1, STAFF_PIN).reason == "disabled")
check("enable", e:setEnabled("Marta", true) == true and e:tryPin("page", 1, STAFF_PIN).ok == true)
check("last owner cannot be disabled", e:setEnabled("Owner", false) == false)
check("last owner cannot be revoked", e:revoke("Owner") == false)
check("last owner cannot be demoted", e:updateCode("Owner", { role = "staff" }) == false)
check("revoke removes the code", e:revoke("Marta") == true and e:find("Marta") == nil and e:tryPin("page", 1, STAFF_PIN).reason == "wrong_pin")
check("unknown code reported", e:revoke("nobody") == false and e:setEnabled("nobody", true) == false)
e:addCode({ name = "Second", role = "owner", pin = VENDOR_PIN })
check("a second owner frees the first", e:revoke("Owner") == true)

print("[7] editing")
e = newEngine()
e:addCode({ name = "Owner", role = "owner", pin = OWNER_PIN })
e:addCode({ name = "Marta", role = "staff", pin = STAFF_PIN, actions = { 1 } })
check("edit keeps the PIN when none is given", e:updateCode("Marta", { name = "Marta B", role = "staff", actions = { 2 } }) == true)
check("old PIN still works for the new action", e:tryPin("page", 2, STAFF_PIN).ok == true and e:tryPin("page", 1, STAFF_PIN).reason == "not_allowed")
check("edit with a new PIN", e:updateCode("Marta B", { pin = GUEST_PIN }) == true and e:tryPin("page", 2, GUEST_PIN).ok == true and e:tryPin("page", 2, STAFF_PIN).reason == "wrong_pin")
check("editing into another code's PIN refused", e:updateCode("Marta B", { pin = OWNER_PIN }) == false)
check("editing into another code's name refused", e:updateCode("Marta B", { name = "owner" }) == false)

print("[8] lockout")
e = newEngine({ maxFails = 3, lockSeconds = 300 })
e:addCode({ name = "Owner", role = "owner", pin = OWNER_PIN })
e:addCode({ name = "Marta", role = "staff", pin = STAFF_PIN, actions = { 1 } })
e:tryPin("page", 1, "0000")
e:tryPin("page", 1, "0001")
check("two wrong attempts: not locked", select(1, e:lockState("page")) == false)
check("a good attempt still works", e:tryPin("page", 1, STAFF_PIN).ok == true)
r = e:tryPin("page", 1, "0002")
check("a good attempt does NOT reset the count: the third wrong one locks the page", r.locked == true and (e:lockState("page")) == true)
check("one lockout event", count("locked_out") == 1)
r = e:tryPin("page", 1, STAFF_PIN)
check("the RIGHT PIN is refused while locked", r.ok == false and r.locked == true and r.reason == "locked_out")
check("keypad and admin are separate entry points", select(1, e:lockState("keypad")) == false and select(1, e:lockState("admin")) == false)
check("the lock does not re-fire the lockout event", count("locked_out") == 1)
clock.t = clock.t + 299
check("still locked after 299 s", select(1, e:lockState("page")) == true)
-- persisted across a reboot
local doc = e:serialize()
local e2 = newEngine({ maxFails = 3, lockSeconds = 300 })
e2:setSlots({ [1] = "Unlock wine cellar" })
e2:restore(doc)
check("lockout survives a restart", select(1, e2:lockState("page")) == true and e2:tryPin("page", 1, STAFF_PIN).locked == true)
clock.t = clock.t + 2
check("lock ends after the time", select(1, e:lockState("page")) == false and e:tryPin("page", 1, STAFF_PIN).ok == true)
e:tryPin("page", 1, "0000")
e:tryPin("page", 1, "0001")
e:tryPin("page", 1, "0002")
check("locked again", select(1, e:lockState("page")) == true)
check("clear lockouts", e:clearLockouts() == true and select(1, e:lockState("page")) == false)
-- a valid PIN outside its hours is a failure too (no oracle for a guess)
e = newEngine({ maxFails = 2, lockSeconds = 60 })
e:addCode({ name = "Owner", role = "owner", pin = OWNER_PIN })
e:addCode({ name = "Vendor", role = "vendor", pin = VENDOR_PIN, actions = { 2 }, from = "08:00", to = "09:00" })
e:tryPin("page", 2, VENDOR_PIN)
r = e:tryPin("page", 2, VENDOR_PIN)
check("valid PIN outside hours counts toward the lockout", r.locked == true)
-- old failures are forgotten after the quiet window
e = newEngine({ maxFails = 3, lockSeconds = 60, failWindow = 100 })
e:addCode({ name = "Owner", role = "owner", pin = OWNER_PIN })
e:tryPin("page", 1, "0000")
e:tryPin("page", 1, "0001")
clock.t = clock.t + 101
e:tryPin("page", 1, "0002")
check("failures decay after the quiet window", select(1, e:lockState("page")) == false)

-- a holder of one valid PIN cannot guess forever by interleaving a success
e = newEngine({ maxFails = 5, lockSeconds = 300 })
e:addCode({ name = "Owner", role = "owner", pin = OWNER_PIN })
e:addCode({ name = "Marta", role = "staff", pin = STAFF_PIN, actions = { 1 } })
local guesses, lockedAt = 0, nil
for round = 1, 20 do
  for i = 1, 4 do
    local g = e:tryPin("page", 1, string.format("%04d", 7000 + guesses))
    guesses = guesses + 1
    if g.locked and not lockedAt then
      lockedAt = guesses
    end
  end
  if lockedAt then
    break
  end
  e:tryPin("page", 1, STAFF_PIN)
end
check("4 wrong, 1 valid, repeat: locked out by the 5th wrong guess", lockedAt ~= nil and lockedAt <= 8, tostring(lockedAt))
-- the count still ages out by itself
e = newEngine({ maxFails = 3, lockSeconds = 60, failWindow = 100 })
e:addCode({ name = "Owner", role = "owner", pin = OWNER_PIN })
e:tryPin("page", 1, "0000")
e:tryPin("page", 1, "0001")
e:tryPin("page", 1, OWNER_PIN)
clock.t = clock.t + 101
e:tryPin("page", 1, "0002")
check("failures kept across a success still decay after the quiet window", select(1, e:lockState("page")) == false)

print("[9] keypad sequences")
e = newEngine({ maxFails = 3, lockSeconds = 120, seqLength = 4, seqWindow = 6 })
e:addCode({ name = "Owner", role = "owner", pin = OWNER_PIN })
check("sequence length enforced", e:addCode({ name = "S", role = "staff", seq = "1-3-3", actions = { 3 } }) == false)
check("sequence tokens validated", e:addCode({ name = "S", role = "staff", seq = "1-3-3-toolong", actions = { 3 } }) == false)
check("sequence needs an allowed action", e:addCode({ name = "S", role = "staff", seq = "1-3-3-2" }) == false)
local sid = e:addCode({ name = "Alarm tech", role = "staff", seq = "1-3-3-2", actions = { 3 }, keypad_action = 3 })
check("sequence code added", sid ~= false)
check("sequence stored as a digest only", require("JSON"):encode(e:serialize()):find("1-3-3-2", 1, true) == nil)
check("a partial entry returns nothing", e:keypadPress("hall", "1") == nil and e:keypadPress("hall", "3") == nil and e:keypadPress("hall", "3") == nil)
r = e:keypadPress("hall", "2")
check("the fourth press completes and grants", r and r.ok == true and r.slot == 3 and r.entry == "keypad")
clock.t = clock.t + 1
e:keypadPress("hall", "1")
clock.t = clock.t + 7
e:keypadPress("hall", "3")
e:keypadPress("hall", "3")
r = e:keypadPress("hall", "2")
check("presses spread over more than the window start over (no match)", r == nil)
-- two keypads do not mix
e:keypadPress("a", "1")
e:keypadPress("b", "3")
e:keypadPress("a", "3")
e:keypadPress("b", "3")
e:keypadPress("a", "3")
e:keypadPress("b", "2")
r = e:keypadPress("a", "2")
check("two keypads keep separate buffers", r and r.ok == true)
-- wrong sequences are attempts and lock the keypad entry point
for _ = 1, 3 do
  for _, b in ipairs({ "9", "9", "9", "8" }) do
    e:keypadPress("hall", b)
  end
end
check("three wrong sequences lock the keypad", select(1, e:lockState("keypad")) == true)
for _, b in ipairs({ "1", "3", "3" }) do
  e:keypadPress("hall", b)
end
r = e:keypadPress("hall", "2")
check("the right sequence is refused while locked", r and r.ok == false and r.locked == true)
check("the page is not locked by keypad guesses", select(1, e:lockState("page")) == false)
-- nothing configured -> presses are inert
local bare = newEngine()
bare:addCode({ name = "Owner", role = "owner", pin = OWNER_PIN })
for _ = 1, 40 do
  bare:keypadPress("hall", "5")
end
check("with no sequence code, presses never count as attempts", select(1, bare:lockState("keypad")) == false and #bare.recent == 0)
check("a bad button id is ignored", bare:keypadPress("x", "way-too-long!") == nil)

print("[10] temporary codes")
e = newEngine()
e:addCode({ name = "Owner", role = "owner", pin = OWNER_PIN })
local tid = e:addTemporary({ name = "Courier", pin = GUEST_PIN, actions = { 2 }, hours = 2 })
check("temporary code added", tid ~= false and e:find("Courier").temp == true)
check("works now", e:tryPin("page", 2, GUEST_PIN).ok == true)
clock.t = clock.t + 3 * 3600
check("expired after its hours", e:tryPin("page", 2, GUEST_PIN).reason == "expired")
clock.t = at(12, 0)
check("same name replaces an earlier temporary code", e:addTemporary({ name = "Courier", pin = VENDOR_PIN, actions = { 2 }, hours = 1 }) ~= false and #e.codes == 2)
check("a replaced code's old PIN stops", e:tryPin("page", 2, GUEST_PIN).reason == "wrong_pin" and e:tryPin("page", 2, VENDOR_PIN).ok == true)
check("a failed replacement keeps the old code", e:addTemporary({ name = "Courier", pin = "1111", actions = { 2 } }) == false and e:tryPin("page", 2, VENDOR_PIN).ok == true)
check("a permanent code's name is not replaced", e:addTemporary({ name = "Owner", pin = STAFF_PIN, actions = { 1 } }) == false)
check("hours bounded", e:addTemporary({ name = "Long", pin = STAFF_PIN, actions = { 1 }, hours = 99999 }) == false)
clock.t = clock.t + 5 * 86400
check("old temporary codes are pruned", e:prune() >= 1 and e:find("Courier") == nil)
clock.t = at(12, 0)
check("parseActions: all / numbers / names", #e:parseActions("all") == 3 and e:parseActions("1, 3")[2] == 3 and e:parseActions("open garage service door")[1] == 2 and #e:parseActions("zzz") == 0)

print("[11] admin: setup, login, sessions")
e = newEngine({ maxFails = 3, lockSeconds = 60 })
check("no owner yet", e:hasOwner() == false)
check("setup creates the first owner", e:setup("Owner", OWNER_PIN) == true and e:hasOwner())
check("setup refused once an owner exists", e:setup("Again", STAFF_PIN) == false)
e:addCode({ name = "Marta", role = "staff", pin = STAFF_PIN, actions = { 1 } })
r = e:login(STAFF_PIN)
check("a non-owner PIN cannot sign in to admin", r.ok == false and r.reason == "not_owner")
r = e:login(OWNER_PIN)
check("owner signs in and gets a session", r.ok == true and #r.session == 32 and e:sessionValid(r.session))
check("a made-up session is refused", e:sessionValid("deadbeef") == false)
local token = r.session
clock.t = clock.t + 601
check("sessions expire", e:sessionValid(token) == false)
e:login("0000")
e:login("0001")
r = e:login("0002")
check("admin entry point locks too", r.locked == true and e:login(OWNER_PIN).ok == false)
check("admin lock leaves the page usable", e:tryPin("page", 1, STAFF_PIN).ok == true)
clock.t = at(12, 0)

print("[12] licence restriction: owner keeps working, nothing new, removal allowed")
e = newEngine()
e:addCode({ name = "Owner", role = "owner", pin = OWNER_PIN })
e:addCode({ name = "Marta", role = "staff", pin = STAFF_PIN, actions = { 1 } })
e:setRestricted(true)
check("owner still fires actions", e:tryPin("page", 1, OWNER_PIN).ok == true)
r = e:tryPin("page", 1, STAFF_PIN)
check("non-owner refused with reason licence", r.ok == false and r.reason == "licence")
check("owner can still sign in to admin", e:login(OWNER_PIN).ok == true)
check("new codes refused", e:addCode({ name = "New", role = "guest", pin = GUEST_PIN, actions = { 1 } }) == false)
check("temporary codes refused", e:addTemporary({ name = "T", pin = GUEST_PIN, actions = { 1 } }) == false)
check("non-owner cannot be enabled or edited", e:setEnabled("Marta", true) == false and e:updateCode("Marta", { name = "M2", role = "staff", actions = { 1, 2 } }) == false)
check("disabling and revoking still work", e:setEnabled("Marta", false) == true and e:revoke("Marta") == true)
e:setRestricted(false)
check("restored: new codes allowed again", e:addCode({ name = "New", role = "guest", pin = GUEST_PIN, actions = { 1 } }) ~= false)

print("[13] persistence")
e = newEngine()
e:addCode({ name = "Owner", role = "owner", pin = OWNER_PIN })
e:addCode({ name = "Marta", role = "staff", pin = STAFF_PIN, actions = { 1, 2 }, days = { 3, 4 }, from = "08:00", to = "17:00", max_uses = 5, expires = clock.t + 99999, seq = "2-4-4-6", keypad_action = 2 })
e:tryPin("page", 1, STAFF_PIN)
local round = newEngine()
round:setSlots({ [1] = "Unlock wine cellar", [2] = "Open garage service door" })
check("restore returns the code count", round:restore(e:serialize()) == 2)
local m = round:find("Marta")
check("fields survive", m.uses == 1 and m.max_uses == 5 and m.from == 480 and m.to == 1020 and m.days[3] and m.days[4] and not m.days[1] and m.actions[2] and m.keypad_action == 2)
check("PIN still verifies after a restart", round:tryPin("page", 2, STAFF_PIN).ok == true)
check("sequence still verifies after a restart", round:keypadPress("k", "2") == nil and round:keypadPress("k", "4") == nil and round:keypadPress("k", "4") == nil and round:keypadPress("k", "6").ok == true)
check("junk state is ignored", newEngine():restore({ v = 99 }) == 0 and newEngine():restore("x") == 0 and newEngine():restore({ v = 1, codes = { { id = 1 }, "x", { id = "c", name = "n", role = "owner" } } }) == 0)

print("[14] nothing secret leaves the engine")
e = newEngine({ maxFails = 3, lockSeconds = 60 })
e:addCode({ name = "Owner", role = "owner", pin = OWNER_PIN, seq = "5-5-6-7" })
e:addCode({ name = "Marta", role = "staff", pin = STAFF_PIN, actions = { 1 } })
e:tryPin("page", 1, STAFF_PIN)
e:tryPin("page", 1, "9090")
e:tryPin("page", 3, STAFF_PIN)
e:login(OWNER_PIN)
for _, b in ipairs({ "9", "9", "9", "8" }) do
  e:keypadPress("hall", b)
end
local secrets = { OWNER_PIN, STAFF_PIN, "9090", "5-5-6-7" }
for _, c in ipairs(e.codes) do
  if c.pin then
    secrets[#secrets + 1] = c.pin.hash
  end
  if c.seq then
    secrets[#secrets + 1] = c.seq.hash
  end
end
local blob = require("JSON"):encode(emitted) .. require("JSON"):encode(e.recent) .. require("JSON"):encode(e:publicCodes())
local leaked = {}
for _, s in ipairs(secrets) do
  if blob:find(s, 1, true) then
    leaked[#leaked + 1] = s:sub(1, 4) .. "..."
  end
end
check("no PIN, sequence or digest in events, recent list or code list", #leaked == 0, table.concat(leaked, ","))
local sawNamed = false
for _, rec in ipairs(e.recent) do
  if rec.code == "Marta" and rec.action == "Unlock wine cellar" and rec.entry == "page" then
    sawNamed = true
  end
end
check("recent list holds names, actions, entry points", #e.recent >= 4 and sawNamed)

print("[15] helpers")
local list = Engine.targetList({
  [10] = { deviceName = "Wine Cellar Lock", roomName = "Cellar", driverFileName = "lock.c4z" },
  [11] = { deviceName = "Hall Light", roomName = "Hall", driverFileName = "light.c4z" },
  [12] = { deviceName = "Garage, Side Door", roomName = "Garage", driverFileName = "relay.c4z" },
  [13] = { deviceName = "Self", driverFileName = "pin.c4z" },
}, 13, "lock,relay,door")
check("target list is filtered, sorted and labelled Name (Room) · id", #list == 2 and list[1].label == "Wine Cellar Lock (Cellar) · 10" and list[2].label:find("Garage  Side Door") ~= nil, list[1] and list[1].label)
check("a star keeps every device but this one", #Engine.targetList({ [1] = { deviceName = "A" }, [2] = { deviceName = "B" } }, 2, "*") == 1)
check("target id comes from the label", Engine.targetId("Wine Cellar Lock (Cellar) · 10") == 10 and Engine.targetId("-") == nil)
check("hours parse", Engine.parseHM("08:30") == 510 and Engine.parseHM("24:00") == nil and Engine.formatHM(510) == "08:30")
check("sequence parse", #Engine.parseSequence("1-3, 3 2") == 4 and Engine.parseSequence("a-!") == nil and Engine.normToken(" ab ") == "AB")
local spec = Engine.specFromPage({ name = "X", role = "guest", pin = " 4826 ", actions = { 1 }, days = {}, from = "", to = "", start_date = "2027-02-01", expiry_date = "2027-02-03", max_uses = "" })
check("page document becomes a spec with local-day epochs", spec.pin == "4826" and spec.starts == os.time({ year = 2027, month = 2, day = 1, hour = 0, min = 0, sec = 0 }) and spec.expires == os.time({ year = 2027, month = 2, day = 3, hour = 23, min = 59, sec = 59 }))
check("bad page date refused", Engine.specFromPage({ name = "X", start_date = "tomorrow" }) == nil)
check("constant compare", Engine.constEq("abc", "abc") and not Engine.constEq("abc", "abd") and not Engine.constEq("abc", "abcd"))

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
