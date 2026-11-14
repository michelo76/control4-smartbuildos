--- VenueFlow: who is asking (pure).
---
--- Two kinds of sign-in, both checked by the driver:
---   installer  the Installer Passcode (a driver property). No passcode set
---              means Installer Studio is OFF; there is no default.
---   profile    a staff profile's PIN. The PIN is stored only as a salted
---              HMAC inside the configuration.
---
--- A successful sign-in mints a random session token that lives in the
--- driver's memory. A page holds the token and nothing else: it never says
--- which profile it is, and editing anything in the browser changes nothing
--- the driver believes. Tokens die with a driver restart (staff sign in
--- again), on expiry, on idle, and when a profile's PIN or the passcode
--- changes.
---
--- Wrong attempts are counted per client address and overall; too many lock
--- sign-in for a while.

local U = require("venueflow.util")

local M = {}

M.DEFAULTS = {
  maxAttempts = 5, -- per client address
  lockSeconds = 60,
  globalAttempts = 40, -- across all addresses, per window
  globalWindowSeconds = 600,
  installerTtl = 8 * 3600,
  installerIdle = 30 * 60,
  profileTtl = 16 * 3600,
  profileIdle = 16 * 3600,
  maxSessions = 96,
}

M.PIN_PATTERN = "^%d%d%d%d%d?%d?%d?%d?$" -- 4 to 8 digits
M.PASSCODE_MIN = 6

local Auth = {}
Auth.__index = Auth

--- deps = { now(), hmac(key, data) -> hex, random() -> hex (>= 32 chars), passcode() -> string }
function M.new(deps, options)
  local self = setmetatable({}, Auth)
  self.deps = deps
  self.opt = {}
  for k, v in pairs(M.DEFAULTS) do
    self.opt[k] = options and options[k] or v
  end
  self.sessions = {} -- token -> session
  self.gates = {} -- key -> { failures, lockedUntil }
  self.global = { count = 0, windowStart = 0 }
  self.onLocked = options and options.onLocked or nil
  return self
end

function M.validPin(pin)
  return type(pin) == "string" and pin:match(M.PIN_PATTERN) ~= nil
end

function Auth:newSalt()
  return tostring(self.deps.random()):sub(1, 16)
end

function Auth:hashPin(pin, salt)
  return self.deps.hmac(tostring(salt), "vf-pin:" .. tostring(pin))
end

-- ── attempt gates ───────────────────────────────────────────────────────────

function Auth:_gate(key)
  local g = self.gates[key]
  if g == nil then
    g = { failures = 0 }
    self.gates[key] = g
  end
  if g.lockedUntil ~= nil and self.deps.now() >= g.lockedUntil then
    g.lockedUntil = nil
    g.failures = 0
  end
  return g
end

function Auth:_globalLocked()
  local now = self.deps.now()
  if now - self.global.windowStart > self.opt.globalWindowSeconds then
    self.global.windowStart = now
    self.global.count = 0
  end
  return self.global.count >= self.opt.globalAttempts
end

function Auth:lockedFor(kind, client)
  if self:_globalLocked() then
    return math.max(1, math.ceil(self.global.windowStart + self.opt.globalWindowSeconds - self.deps.now()))
  end
  local g = self:_gate(kind .. "|" .. tostring(client or "?"))
  if g.lockedUntil ~= nil then
    return math.max(1, math.ceil(g.lockedUntil - self.deps.now()))
  end
  return 0
end

function Auth:_fail(kind, client)
  local g = self:_gate(kind .. "|" .. tostring(client or "?"))
  g.failures = g.failures + 1
  self.global.count = self.global.count + 1
  if g.failures >= self.opt.maxAttempts then
    g.lockedUntil = self.deps.now() + self.opt.lockSeconds
    g.failures = 0
    if self.onLocked then
      pcall(self.onLocked, kind, client)
    end
  end
end

function Auth:_pass(kind, client)
  local g = self:_gate(kind .. "|" .. tostring(client or "?"))
  g.failures = 0
end

function Auth:resetGates()
  self.gates = {}
  self.global = { count = 0, windowStart = 0 }
end

--- Compares two secrets through an HMAC so the comparison time does not
--- depend on how many leading characters match.
function Auth:_same(a, b)
  local key = "vf-compare"
  return self.deps.hmac(key, tostring(a)) == self.deps.hmac(key, tostring(b))
end

-- ── sessions ────────────────────────────────────────────────────────────────

function Auth:_mint(kind, profileId, client)
  local now = self.deps.now()
  local count, oldestToken, oldestAt = 0, nil, nil
  for token, s in pairs(self.sessions) do
    count = count + 1
    if oldestAt == nil or s.lastSeen < oldestAt then
      oldestToken, oldestAt = token, s.lastSeen
    end
  end
  if count >= self.opt.maxSessions and oldestToken ~= nil then
    self.sessions[oldestToken] = nil
  end
  local token = tostring(self.deps.random())
  self.sessions[token] = {
    kind = kind,
    profileId = profileId,
    client = client,
    createdAt = now,
    lastSeen = now,
    expiresAt = now + (kind == "installer" and self.opt.installerTtl or self.opt.profileTtl),
    idle = kind == "installer" and self.opt.installerIdle or self.opt.profileIdle,
  }
  return token, self.sessions[token]
end

--- Returns token, or nil + code ("VF_STUDIO_DISABLED" | "VF_LOCKED" | "VF_BAD_PASSCODE").
function Auth:installerLogin(offered, client)
  local passcode = tostring(self.deps.passcode() or "")
  if #passcode < M.PASSCODE_MIN then
    return nil, "VF_STUDIO_DISABLED"
  end
  if self:lockedFor("installer", client) > 0 then
    return nil, "VF_LOCKED"
  end
  if type(offered) ~= "string" or not self:_same(offered, passcode) then
    self:_fail("installer", client)
    return nil, self:lockedFor("installer", client) > 0 and "VF_LOCKED" or "VF_BAD_PASSCODE"
  end
  self:_pass("installer", client)
  return self:_mint("installer", nil, client)
end

--- profile = the configuration's profile entry (with pinSalt / pinHash).
function Auth:profileLogin(profile, pin, client)
  if type(profile) ~= "table" or type(profile.pinHash) ~= "string" or profile.pinHash == "" then
    return nil, "VF_FORBIDDEN"
  end
  if self:lockedFor("profile", client) > 0 then
    return nil, "VF_LOCKED"
  end
  if not M.validPin(pin) or not self:_same(self:hashPin(pin, profile.pinSalt), profile.pinHash) then
    self:_fail("profile", client)
    return nil, self:lockedFor("profile", client) > 0 and "VF_LOCKED" or "VF_BAD_PIN"
  end
  self:_pass("profile", client)
  return self:_mint("profile", profile.id, client)
end

--- The session behind a token, or nil. Touches lastSeen.
function Auth:resolve(token)
  if type(token) ~= "string" or token == "" then
    return nil
  end
  local s = self.sessions[token]
  if s == nil then
    return nil
  end
  local now = self.deps.now()
  if now >= s.expiresAt or now - s.lastSeen > s.idle then
    self.sessions[token] = nil
    return nil
  end
  s.lastSeen = now
  return s
end

function Auth:logout(token)
  if type(token) == "string" then
    self.sessions[token] = nil
  end
end

function Auth:revoke(kind, profileId)
  local n = 0
  for token, s in pairs(self.sessions) do
    if (kind == nil or s.kind == kind) and (profileId == nil or s.profileId == profileId) then
      self.sessions[token] = nil
      n = n + 1
    end
  end
  return n
end

function Auth:count(kind)
  local n = 0
  for _, s in pairs(self.sessions) do
    if kind == nil or s.kind == kind then
      n = n + 1
    end
  end
  return n
end

function Auth:studioEnabled()
  return #tostring(self.deps.passcode() or "") >= M.PASSCODE_MIN
end

M._util = U

return M
