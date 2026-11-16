--- PIN Lock -- pure rules (no controller calls, injected clock and hash).
---
--- A "guarded action" is a named gate (slots 1..12). A "code" is a person's
--- credential: a PIN typed on the page and/or a keypad tap sequence, with a
--- role, the guarded actions it may fire, a weekly window, an optional start
--- and expiry and an optional use limit. The engine decides, and records
--- WHAT happened (code NAME, action, entry point, reason) -- never the
--- secret that was typed.
---
--- Secrets:
---   * stored only as salted, iterated HMAC digests (`deps.hmac(key, data)`,
---     C4:HMAC SHA256 on the controller); the plaintext is not kept, logged,
---     returned or emitted anywhere in this module;
---   * compared without an early exit, and checked against EVERY code so the
---     time taken does not say which code matched;
---   * a PIN or sequence cannot be shared by two codes.
---   Honest limit: a 4..8 digit PIN is a small space. The digest only keeps
---   a casual reader of the stored data from reading PINs; the real defence
---   is the lockout below plus the controller's encrypted store.
---
--- Brute force: failures per ENTRY POINT ("page", "keypad", "admin"). After
--- `maxFails` the entry point is locked for `lockSeconds`; the lock is part
--- of the serialised state, so a reboot does not clear it. Every denial
--- counts, whatever its cause (a valid PIN used outside its hours counts as
--- a failure), so the answer never tells an attacker that a guess was right.

local Pin = require("guestmode.pin")

local M = {}

M.SLOTS = 12
M.ENTRIES = { page = true, keypad = true, admin = true }
M.ROLES = { owner = true, staff = true, vendor = true, guest = true }
M.LIMITS = {
  codes = 60,
  name = 40,
  recent = 20,
  keypads = 8,
  sessions = 4,
  token = 4,
  hours_max = 8760,
  uses_max = 9999,
  slot_name = 40,
}
M.DEFAULTS = {
  maxFails = 5,
  lockSeconds = 300,
  failWindow = 600, -- seconds of quiet after which old failures are forgotten
  seqLength = 4,
  seqWindow = 6,
  iterations = 100,
  sessionSeconds = 600,
  lockedLogEvery = 30, -- refused attempts during a lockout are recorded at most this often
}

-- ─── helpers ────────────────────────────────────────────────────────────────

local function trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Name used to match and to detect duplicates.
function M.normName(name)
  return (trim(name):lower():gsub("%s+", " "))
end

local function cleanName(name, limit)
  local s = trim(name):gsub("[%c]", " "):gsub("%s+", " ")
  return s:sub(1, limit)
end

local function toInt(v)
  local n = tonumber(v)
  if n == nil or n ~= math.floor(n) then
    return nil
  end
  return n
end

--- Equal-length-walk compare: no early exit on the first difference.
local function constEq(a, b)
  a, b = tostring(a), tostring(b)
  local diff = (#a ~= #b) and 1 or 0
  for i = 1, math.max(#a, #b) do
    if a:byte(i) ~= b:byte(i) then
      diff = diff + 1
    end
  end
  return diff == 0
end
M.constEq = constEq

--- "HH:MM" -> minutes after midnight, or nil.
function M.parseHM(text)
  local h, m = trim(text):match("^(%d%d?):(%d%d)$")
  h, m = tonumber(h), tonumber(m)
  if h == nil or h > 23 or m > 59 then
    return nil
  end
  return h * 60 + m
end

function M.formatHM(minutes)
  if minutes == nil then
    return ""
  end
  return string.format("%02d:%02d", math.floor(minutes / 60), minutes % 60)
end

--- "YYYY-MM-DD" -> local epoch (start of that day, or its last second).
function M.dayEpoch(text, endOfDay)
  local y, mo, d = trim(text):match("^(%d%d%d%d)-(%d%d)-(%d%d)$")
  y, mo, d = tonumber(y), tonumber(mo), tonumber(d)
  if y == nil or mo < 1 or mo > 12 or d < 1 or d > 31 then
    return nil
  end
  return os.time({
    year = y,
    month = mo,
    day = d,
    hour = endOfDay and 23 or 0,
    min = endOfDay and 59 or 0,
    sec = endOfDay and 59 or 0,
  })
end

local function defaultLocalParts(t)
  local d = os.date("*t", math.floor(t))
  return d.wday, d.hour * 60 + d.min
end

--- A button token of a keypad sequence: 1..4 letters or digits, upper-cased.
function M.normToken(token)
  local s = trim(token):upper()
  if s:match("^%w+$") and #s <= M.LIMITS.token then
    return s
  end
  return nil
end

--- "1-3-3-2" (separators: dash, comma, space) -> {"1","3","3","2"}, or nil.
function M.parseSequence(text)
  local out = {}
  for part in tostring(text or ""):gmatch("[^%-,%s]+") do
    local tok = M.normToken(part)
    if tok == nil then
      return nil
    end
    out[#out + 1] = tok
  end
  if #out == 0 then
    return nil
  end
  return out
end

local function joinSeq(tokens)
  return table.concat(tokens, "-")
end

--- The "Name (Room) · id" list for the guarded-action target picker.
--- `devices` has the C4:GetDevices shape. `filter` is a comma list of words
--- matched against name, room and driver file ("*" or "" keeps everything).
--- @return table list of { id, label }
function M.targetList(devices, selfId, filter)
  local words = {}
  for w in tostring(filter or ""):lower():gmatch("[^,]+") do
    w = trim(w)
    if w == "*" then
      words = {}
      break
    elseif w ~= "" then
      words[#words + 1] = w
    end
  end
  local out = {}
  for rawId, d in pairs(devices or {}) do
    local id = tonumber(rawId)
    if id ~= nil and type(d) == "table" and id ~= selfId then
      local name = cleanName(d.deviceName or ("Device " .. id), 60):gsub(",", " ")
      local room = d.roomName and cleanName(d.roomName, 40):gsub(",", " ") or nil
      local hay = (name .. " " .. (room or "") .. " " .. tostring(d.driverFileName or "")):lower()
      local keep = #words == 0
      for _, w in ipairs(words) do
        if hay:find(w, 1, true) then
          keep = true
        end
      end
      if keep then
        out[#out + 1] = {
          id = id,
          sort = (room or "") .. "\0" .. name,
          label = string.format("%s%s · %d", name, room and (" (" .. room .. ")") or "", id),
        }
      end
    end
  end
  table.sort(out, function(a, b)
    if a.sort ~= b.sort then
      return a.sort < b.sort
    end
    return a.id < b.id
  end)
  return out
end

--- The device id at the end of a picker label.
function M.targetId(label)
  return tonumber(tostring(label or ""):match("·%s*(%d+)%s*$"))
end

-- ─── engine ─────────────────────────────────────────────────────────────────

local Engine = {}
Engine.__index = Engine

--- @param deps table {
---   now = fn() -> epoch seconds (fractions allowed),
---   hmac = fn(key, data) -> hex string,
---   random = fn() -> [0,1) (default math.random),
---   localParts = fn(epoch) -> weekday 1..7 (1 = Sunday), minutes after midnight,
---   emit = fn(kind, fields) | nil,
---   settings = { maxFails, lockSeconds, seqLength, seqWindow, iterations ... },
--- }
function M.new(deps)
  deps = deps or {}
  assert(type(deps.hmac) == "function", "hmac required")
  local self = setmetatable({}, Engine)
  self.nowFn = deps.now or os.time
  self.hmac = deps.hmac
  self.random = deps.random or math.random
  self.localParts = deps.localParts or defaultLocalParts
  self.emit = deps.emit or function() end
  self.settings = {}
  for k, v in pairs(M.DEFAULTS) do
    self.settings[k] = v
  end
  for k, v in pairs(deps.settings or {}) do
    self.settings[k] = v
  end
  self.codes = {}
  self.slots = {} -- [n] = guarded action name
  self.locks = {} -- [entry] = { fails, last, until_ }
  self.recent = {}
  self.buffers = {}
  self.sessions = {}
  self.restricted = false
  self.counter = 0
  self.lockedLogged = {}
  return self
end

function Engine:now()
  return self.nowFn()
end

function Engine:_emit(kind, fields)
  pcall(self.emit, kind, fields or {})
end

function Engine:configure(settings)
  for k, v in pairs(settings or {}) do
    if self.settings[k] ~= nil and tonumber(v) ~= nil then
      self.settings[k] = tonumber(v)
    end
  end
end

--- Licence enforcement: owner codes keep working, everything else is refused,
--- and nothing that ADDS access can be created. Removing access always works.
function Engine:setRestricted(flag)
  self.restricted = flag == true
end

function Engine:setSlots(map)
  self.slots = {}
  for n = 1, M.SLOTS do
    local name = cleanName(map and map[n] or "", M.LIMITS.slot_name)
    if name ~= "" then
      self.slots[n] = name
    end
  end
end

function Engine:slotName(n)
  return self.slots[tonumber(n) or 0]
end

function Engine:slotList()
  local out = {}
  for n = 1, M.SLOTS do
    if self.slots[n] then
      out[#out + 1] = { n = n, name = self.slots[n] }
    end
  end
  return out
end

-- ─── hashing ────────────────────────────────────────────────────────────────

function Engine:_salt()
  self.counter = self.counter + 1
  local seed = string.format(
    "%s|%d|%.9f|%.9f",
    tostring(self:now()),
    self.counter,
    self.random(),
    self.random()
  )
  return (self.hmac("pinlock-salt", seed)):sub(1, 24)
end

--- Salted, iterated digest. The secret is mixed in on every round.
function Engine:_digest(secret, salt, iterations)
  local h = self.hmac(salt, "pinlock:" .. secret)
  for _ = 2, iterations do
    h = self.hmac(salt, h .. ":" .. secret)
  end
  return h
end

function Engine:_seal(secret)
  local salt = self:_salt()
  local it = self.settings.iterations
  return { salt = salt, it = it, hash = self:_digest(secret, salt, it) }
end

function Engine:_matches(cred, secret)
  if type(cred) ~= "table" then
    return false
  end
  return constEq(self:_digest(secret, cred.salt, cred.it), cred.hash)
end

--- Every code whose `field` credential matches (all codes are always tried).
function Engine:_findBySecret(field, secret)
  local found
  for _, code in ipairs(self.codes) do
    if code[field] and self:_matches(code[field], secret) and found == nil then
      found = code
    end
  end
  return found
end

-- ─── codes ──────────────────────────────────────────────────────────────────

function Engine:find(ref)
  local text = trim(ref)
  if text == "" then
    return nil
  end
  local want = M.normName(text)
  for _, code in ipairs(self.codes) do
    if code.id == text or M.normName(code.name) == want then
      return code
    end
  end
  return nil
end

function Engine:_enabledOwners(except)
  local n = 0
  for _, c in ipairs(self.codes) do
    if c.role == "owner" and c.enabled and c ~= except then
      n = n + 1
    end
  end
  return n
end

function Engine:hasOwner()
  for _, c in ipairs(self.codes) do
    if c.role == "owner" then
      return true
    end
  end
  return false
end

local function slotSet(list)
  local set = {}
  for _, v in ipairs(list or {}) do
    local n = toInt(v)
    if n ~= nil and n >= 1 and n <= M.SLOTS then
      set[n] = true
    end
  end
  return set
end

local function sortedKeys(set)
  local out = {}
  for k in pairs(set or {}) do
    out[#out + 1] = k
  end
  table.sort(out)
  return out
end

--- Validates a spec into code fields. `base` is the code being edited (nil
--- for a new one). Secrets are not touched here.
function Engine:_fields(spec, base)
  local f = {}
  local function pick(key, current)
    if spec[key] ~= nil then
      return spec[key]
    end
    return current
  end

  local name = cleanName(pick("name", base and base.name), M.LIMITS.name)
  if name == "" then
    return nil, "name required"
  end
  local clash = self:find(name)
  if clash ~= nil and clash ~= base then
    return nil, "name already in use"
  end
  f.name = name

  local role = trim(pick("role", base and base.role)):lower()
  if not M.ROLES[role] then
    return nil, "role must be owner, staff, vendor or guest"
  end
  f.role = role

  if spec.actions ~= nil then
    f.actions = slotSet(spec.actions)
  else
    f.actions = base and base.actions or {}
  end

  local days = pick("days", base and base.days)
  if days ~= nil and type(days) == "table" and next(days) ~= nil then
    local set = {}
    -- accepts a list {1,2,3} or a set {[1]=true}
    for k, v in pairs(days) do
      local d = toInt(v == true and k or v)
      if d == nil or d < 1 or d > 7 then
        return nil, "days must be 1 (Sunday) to 7 (Saturday)"
      end
      set[d] = true
    end
    f.days = (#sortedKeys(set) == 7) and nil or set
  else
    f.days = nil
  end

  local function hours(value)
    if type(value) == "string" then
      if trim(value) == "" then
        return nil
      end
      local m = M.parseHM(value)
      if m == nil then
        return nil, true
      end
      return m
    end
    return tonumber(value)
  end
  local from, badFrom = hours(pick("from", base and base.from))
  local to, badTo = hours(pick("to", base and base.to))
  if badFrom or badTo then
    return nil, "hours must be HH:MM"
  end
  if (from == nil) ~= (to == nil) then
    return nil, "give both From and To, or neither"
  end
  if from ~= nil and from == to then
    return nil, "From and To must differ"
  end
  f.from, f.to = from, to

  f.starts = tonumber(pick("starts", base and base.starts))
  f.expires = tonumber(pick("expires", base and base.expires))
  if f.starts == 0 then
    f.starts = nil -- 0 means "no start" (an edit clearing the field)
  end
  if f.expires == 0 then
    f.expires = nil
  end
  if f.starts and f.expires and f.expires <= f.starts then
    return nil, "expiry must be after the start"
  end

  local maxUses = pick("max_uses", base and base.max_uses)
  if maxUses == "" or maxUses == 0 or maxUses == false then
    maxUses = nil
  end
  if maxUses ~= nil then
    maxUses = toInt(maxUses)
    if maxUses == nil or maxUses < 1 or maxUses > M.LIMITS.uses_max then
      return nil, "max uses must be 1 to " .. M.LIMITS.uses_max
    end
  end
  f.max_uses = maxUses

  local ka = pick("keypad_action", base and base.keypad_action)
  if ka == "" then
    ka = nil
  end
  if ka ~= nil then
    ka = toInt(ka)
    if ka == nil or ka < 1 or ka > M.SLOTS then
      return nil, "keypad action must be a guarded action number"
    end
  end
  f.keypad_action = ka
  return f
end

--- Checks a PIN for form and for a clash with another code.
function Engine:_checkPin(pin, base)
  pin = tostring(pin or "")
  if not Pin.isAcceptable(pin) then
    return nil, "PIN must be 4 to 8 digits, not a repeat, a run (1234) or an alternation (1212)"
  end
  local other = self:_findBySecret("pin", pin)
  if other ~= nil and other ~= base then
    return nil, "that PIN is already in use"
  end
  return pin
end

function Engine:_checkSeq(text, base)
  local tokens = M.parseSequence(text)
  if tokens == nil then
    return nil, "sequence: use button ids of 1 to 4 letters or digits, like 1-3-3-2"
  end
  if #tokens ~= self.settings.seqLength then
    return nil, string.format("sequence must be exactly %d presses", self.settings.seqLength)
  end
  local joined = joinSeq(tokens)
  local other = self:_findBySecret("seq", joined)
  if other ~= nil and other ~= base then
    return nil, "that sequence is already in use"
  end
  return joined
end

function Engine:_finish(code)
  if code.seq and code.role ~= "owner" then
    local ka = code.keypad_action
    if ka == nil then
      ka = sortedKeys(code.actions)[1]
      code.keypad_action = ka
    end
    if ka == nil or not code.actions[ka] then
      return nil, "a keypad sequence needs a guarded action the code may fire"
    end
  elseif code.seq and code.keypad_action == nil then
    code.keypad_action = 1
  end
  return true
end

--- Adds a code. spec = { name, role, pin?, seq?, keypad_action?, actions?,
--- days?, from?, to?, starts?, expires?, max_uses?, temp? }.
--- @return string|false id, string|nil reason
function Engine:addCode(spec)
  spec = spec or {}
  if self.restricted then
    return false, "licence: new codes are refused"
  end
  if #self.codes >= M.LIMITS.codes then
    return false, "code limit reached"
  end
  local f, why = self:_fields(spec, nil)
  if not f then
    return false, why
  end
  if spec.pin == nil and spec.seq == nil then
    return false, "give a PIN, a keypad sequence, or both"
  end
  local code = {
    enabled = true,
    uses = 0,
    created = self:now(),
    temp = spec.temp == true or nil,
  }
  for k, v in pairs(f) do
    code[k] = v
  end
  if spec.pin ~= nil then
    local pin, e = self:_checkPin(spec.pin, nil)
    if not pin then
      return false, e
    end
    code.pin = self:_seal(pin)
  end
  if spec.seq ~= nil then
    local seq, e = self:_checkSeq(spec.seq, nil)
    if not seq then
      return false, e
    end
    code.seq = self:_seal(seq)
  end
  local ok, e = self:_finish(code)
  if not ok then
    return false, e
  end
  self.counter = self.counter + 1
  code.id = string.format("c%d%d", math.floor(self:now()) % 100000, self.counter)
  self.codes[#self.codes + 1] = code
  self:_emit("changed", { what = "added", name = code.name })
  return code.id
end

--- Edits a code. A PIN/sequence is replaced only when one is given; passing
--- `clear_seq = true` removes the sequence.
function Engine:updateCode(ref, spec)
  spec = spec or {}
  local code = self:find(ref)
  if code == nil then
    return false, "no such code"
  end
  if self.restricted and code.role ~= "owner" then
    -- narrowing is allowed under restriction, widening is not: keep it simple
    -- and refuse every edit except through enable/disable/revoke.
    return false, "licence: codes cannot be edited"
  end
  local f, why = self:_fields(spec, code)
  if not f then
    return false, why
  end
  if code.role == "owner" and f.role ~= "owner" and self:_enabledOwners(code) == 0 and code.enabled then
    return false, "this is the last owner code"
  end
  local staged = {}
  for k, v in pairs(code) do
    staged[k] = v
  end
  for k, v in pairs(f) do
    staged[k] = v
  end
  staged.days, staged.from, staged.to, staged.starts, staged.expires, staged.max_uses, staged.keypad_action =
    f.days, f.from, f.to, f.starts, f.expires, f.max_uses, f.keypad_action
  if spec.pin ~= nil and trim(spec.pin) ~= "" then
    local pin, e = self:_checkPin(spec.pin, code)
    if not pin then
      return false, e
    end
    staged.pin = self:_seal(pin)
  end
  if spec.clear_seq == true then
    staged.seq = nil
  end
  if spec.seq ~= nil and trim(spec.seq) ~= "" then
    local seq, e = self:_checkSeq(spec.seq, code)
    if not seq then
      return false, e
    end
    staged.seq = self:_seal(seq)
  end
  if not staged.pin and not staged.seq then
    return false, "a code needs a PIN or a keypad sequence"
  end
  local ok, e = self:_finish(staged)
  if not ok then
    return false, e
  end
  for k in pairs(code) do
    code[k] = nil
  end
  for k, v in pairs(staged) do
    code[k] = v
  end
  self:_emit("changed", { what = "updated", name = code.name })
  return true
end

function Engine:setEnabled(ref, flag)
  local code = self:find(ref)
  if code == nil then
    return false, "no such code"
  end
  if flag and self.restricted and code.role ~= "owner" then
    return false, "licence: codes cannot be enabled"
  end
  if not flag and code.role == "owner" and code.enabled and self:_enabledOwners(code) == 0 then
    return false, "this is the last owner code"
  end
  if code.enabled ~= (flag == true) then
    code.enabled = flag == true
    self:_emit("changed", { what = flag and "enabled" or "disabled", name = code.name })
  end
  return true
end

function Engine:revoke(ref)
  local code = self:find(ref)
  if code == nil then
    return false, "no such code"
  end
  if code.role == "owner" and code.enabled and self:_enabledOwners(code) == 0 then
    return false, "this is the last owner code"
  end
  for i, c in ipairs(self.codes) do
    if c == code then
      table.remove(self.codes, i)
      break
    end
  end
  self:_emit("changed", { what = "revoked", name = code.name })
  return true
end

--- Dealer-only wipe (Composer action). Sessions and keypad buffers go too.
function Engine:removeAllCodes()
  self.codes = {}
  self.sessions = {}
  self.buffers = {}
  self:_emit("changed", { what = "reset" })
end

--- Temporary code from programming: guest role, expires after `hours`.
--- Replaces an earlier temporary code of the same name.
function Engine:addTemporary(spec)
  spec = spec or {}
  local hours = tonumber(spec.hours) or 24
  if hours <= 0 or hours > M.LIMITS.hours_max then
    return false, "hours must be between 0 and " .. M.LIMITS.hours_max
  end
  local existing = self:find(spec.name)
  if existing ~= nil then
    if not existing.temp then
      return false, "name already in use"
    end
    local snapshot = existing
    local pos
    for i, c in ipairs(self.codes) do
      if c == snapshot then
        pos = i
      end
    end
    table.remove(self.codes, pos)
    local id, why = self:addTemporary({
      name = spec.name,
      pin = spec.pin,
      actions = spec.actions,
      hours = hours,
      max_uses = spec.max_uses,
    })
    if not id then
      table.insert(self.codes, pos, snapshot) -- the old one stays
    end
    return id, why
  end
  if spec.pin == nil then
    return false, "PIN required"
  end
  local t = self:now()
  return self:addCode({
    name = spec.name,
    role = "guest",
    pin = spec.pin,
    actions = spec.actions,
    starts = t - 1,
    expires = t + hours * 3600,
    max_uses = spec.max_uses,
    temp = true,
  })
end

--- Turns "all", "1,3" or "Unlock wine cellar, 4" into slot numbers.
function Engine:parseActions(text)
  local out = {}
  local raw = trim(text)
  if raw == "" or raw:lower() == "all" then
    for n = 1, M.SLOTS do
      if self.slots[n] then
        out[#out + 1] = n
      end
    end
    return out
  end
  for part in raw:gmatch("[^,;]+") do
    part = trim(part)
    local n = toInt(part)
    if n == nil then
      local want = M.normName(part)
      for i = 1, M.SLOTS do
        if self.slots[i] and M.normName(self.slots[i]) == want then
          n = i
        end
      end
    end
    if n ~= nil and n >= 1 and n <= M.SLOTS then
      out[#out + 1] = n
    end
  end
  return out
end

--- Removes temporary codes that expired more than a day ago.
function Engine:prune()
  local t = self:now()
  local kept, dropped = {}, 0
  for _, c in ipairs(self.codes) do
    if c.temp and c.expires and t > c.expires + 86400 then
      dropped = dropped + 1
    else
      kept[#kept + 1] = c
    end
  end
  self.codes = kept
  if dropped > 0 then
    self:_emit("changed", { what = "pruned" })
  end
  return dropped
end

-- ─── validity ───────────────────────────────────────────────────────────────

function Engine:_inWindow(code, t)
  if code.from == nil and code.days == nil then
    return true
  end
  local wday, minutes = self.localParts(t)
  local overnight = code.from ~= nil and code.from > code.to
  local day = wday
  local inHours = true
  if code.from ~= nil then
    if overnight then
      inHours = minutes >= code.from or minutes < code.to
      if minutes < code.to then
        day = (wday + 5) % 7 + 1 -- the window opened yesterday
      end
    else
      inHours = minutes >= code.from and minutes < code.to
    end
  end
  if not inHours then
    return false
  end
  return code.days == nil or code.days[day] == true
end

--- ok, reason. `slot` nil = admin (no action check).
function Engine:_validity(code, slot, t)
  if not code.enabled then
    return false, "disabled"
  end
  if code.starts and t < code.starts then
    return false, "not_yet"
  end
  if code.expires and t > code.expires then
    return false, "expired"
  end
  if code.max_uses and code.uses >= code.max_uses then
    return false, "used_up"
  end
  if slot ~= nil and code.role ~= "owner" and not code.actions[slot] then
    return false, "not_allowed"
  end
  if not self:_inWindow(code, t) then
    return false, "outside_window"
  end
  if slot ~= nil and self.restricted and code.role ~= "owner" then
    return false, "licence"
  end
  return true
end

--- "active" | "disabled" | "not yet" | "expired" | "used up" -- hours not considered.
function Engine:codeState(code)
  local t = self:now()
  if not code.enabled then
    return "disabled"
  end
  if code.starts and t < code.starts then
    return "not yet"
  end
  if code.expires and t > code.expires then
    return "expired"
  end
  if code.max_uses and code.uses >= code.max_uses then
    return "used up"
  end
  return "active"
end

function Engine:isActive(ref)
  local code = self:find(ref)
  return code ~= nil and self:codeState(code) == "active"
end

-- ─── lockouts ───────────────────────────────────────────────────────────────

function Engine:_lock(entry)
  local l = self.locks[entry]
  if l == nil then
    l = { fails = 0 }
    self.locks[entry] = l
  end
  return l
end

--- @return boolean locked, number secondsLeft
function Engine:lockState(entry)
  local l = self.locks[entry]
  if l == nil or l.until_ == nil then
    return false, 0
  end
  local left = l.until_ - self:now()
  if left <= 0 then
    l.until_ = nil
    l.fails = 0
    self:_emit("changed", { what = "lock_expired", entry = entry })
    return false, 0
  end
  return true, math.ceil(left)
end

function Engine:clearLockouts(entry)
  local cleared = false
  for name, l in pairs(self.locks) do
    if entry == nil or name == entry then
      if l.until_ ~= nil or l.fails > 0 then
        cleared = true
      end
      l.until_, l.fails, l.last = nil, 0, nil
      self:_emit("lock_cleared", { entry = name })
    end
  end
  if cleared then
    self:_emit("changed", { what = "lock_cleared" })
  end
  return cleared
end

function Engine:_recordRecent(rec)
  table.insert(self.recent, 1, rec)
  while #self.recent > M.LIMITS.recent do
    table.remove(self.recent)
  end
end

function Engine:_lockedResult(entry, slot, left)
  local t = self:now()
  local last = self.lockedLogged[entry]
  if last == nil or t - last >= self.settings.lockedLogEvery then
    self.lockedLogged[entry] = t
    self:_recordRecent({ t = t, result = "locked", entry = entry, action = slot and self.slots[slot] or nil })
    self:_emit("denied", { reason = "locked_out", entry = entry, slot = slot, action = slot and self.slots[slot] })
  end
  return { ok = false, locked = true, retry_in = left, reason = "locked_out" }
end

function Engine:_fail(entry, code, slot, reason)
  local t = self:now()
  local l = self:_lock(entry)
  if l.last ~= nil and t - l.last > self.settings.failWindow then
    l.fails = 0
  end
  l.last = t
  l.fails = l.fails + 1
  local action = slot and self.slots[slot] or nil
  local result = { ok = false, reason = reason, code = code and code.name or nil, entry = entry, action = action }
  self:_recordRecent({
    t = t,
    result = "denied",
    code = result.code,
    action = action,
    entry = entry,
    reason = reason,
  })
  self:_emit("denied", { code = result.code, reason = reason, entry = entry, slot = slot, action = action })
  if l.fails >= self.settings.maxFails then
    l.until_ = t + self.settings.lockSeconds
    l.fails = 0
    result.locked = true
    result.retry_in = self.settings.lockSeconds
    self:_recordRecent({ t = t, result = "locked", entry = entry, reason = "lockout started" })
    self:_emit("locked_out", { entry = entry, seconds = self.settings.lockSeconds })
  end
  self:_emit("changed", { what = "lock_state", entry = entry })
  return result
end

function Engine:_grant(entry, code, slot)
  local t = self:now()
  code.uses = (code.uses or 0) + 1
  -- A success must not forgive earlier wrong guesses: the failure count only
  -- ages out through failWindow, or ends with a lockout / clearLockouts.
  local action = slot and self.slots[slot] or nil
  self:_recordRecent({ t = t, result = "granted", code = code.name, action = action, entry = entry })
  self:_emit("granted", { code = code.name, role = code.role, slot = slot, action = action, entry = entry })
  self:_emit("changed", { what = "use", name = code.name })
  return { ok = true, code = code.name, role = code.role, slot = slot, action = action, entry = entry }
end

-- ─── attempts ───────────────────────────────────────────────────────────────

--- A PIN typed on the page for one guarded action.
function Engine:tryPin(entry, slot, pin)
  entry = M.ENTRIES[entry] and entry or "page"
  slot = toInt(slot)
  local locked, left = self:lockState(entry)
  if locked then
    return self:_lockedResult(entry, slot, left)
  end
  pin = tostring(pin or "")
  if slot == nil or self.slots[slot] == nil then
    return self:_fail(entry, nil, nil, "no_such_action")
  end
  if not pin:match("^%d+$") or #pin < Pin.MIN or #pin > Pin.MAX then
    return self:_fail(entry, nil, slot, "wrong_pin")
  end
  local code = self:_findBySecret("pin", pin)
  if code == nil then
    return self:_fail(entry, nil, slot, "wrong_pin")
  end
  local ok, why = self:_validity(code, slot, self:now())
  if not ok then
    return self:_fail(entry, code, slot, why)
  end
  return self:_grant(entry, code, slot)
end

--- A complete keypad sequence ("1-3-3-2"); the code says which action.
function Engine:trySequence(joined)
  local entry = "keypad"
  local locked, left = self:lockState(entry)
  if locked then
    return self:_lockedResult(entry, nil, left)
  end
  local code = self:_findBySecret("seq", tostring(joined or ""))
  if code == nil then
    return self:_fail(entry, nil, nil, "wrong_sequence")
  end
  local slot = code.keypad_action
  if slot == nil or self.slots[slot] == nil then
    return self:_fail(entry, code, nil, "no_such_action")
  end
  local ok, why = self:_validity(code, slot, self:now())
  if not ok then
    return self:_fail(entry, code, slot, why)
  end
  return self:_grant(entry, code, slot)
end

local function anySequence(self)
  for _, c in ipairs(self.codes) do
    if c.seq then
      return true
    end
  end
  return false
end

--- One keypad button press. Returns nil while a sequence is incomplete (or
--- ignored); the attempt's result once `seqLength` presses were collected
--- inside `seqWindow` seconds. A partial entry that times out is dropped and
--- is not an attempt; every complete entry is exactly one attempt.
function Engine:keypadPress(keypadId, button)
  local token = M.normToken(button)
  if token == nil then
    return nil
  end
  if not anySequence(self) then
    return nil -- nothing is configured to listen: no buffer, no attempts
  end
  local locked, left = self:lockState("keypad")
  if locked then
    self.buffers = {}
    return self:_lockedResult("keypad", nil, left)
  end
  local id = trim(keypadId):lower():sub(1, 20)
  if id == "" then
    id = "default"
  end
  local t = self:now()
  local count = 0
  for _ in pairs(self.buffers) do
    count = count + 1
  end
  if self.buffers[id] == nil and count >= M.LIMITS.keypads then
    id = "default"
  end
  local buf = self.buffers[id]
  if buf == nil or t - buf.first > self.settings.seqWindow then
    buf = { first = t, tokens = {} }
    self.buffers[id] = buf
  end
  buf.tokens[#buf.tokens + 1] = token
  if #buf.tokens < self.settings.seqLength then
    return nil
  end
  self.buffers[id] = nil
  return self:trySequence(joinSeq(buf.tokens))
end

-- ─── admin sessions ─────────────────────────────────────────────────────────

function Engine:_newSession()
  local t = self:now()
  for token, exp in pairs(self.sessions) do
    if exp <= t then
      self.sessions[token] = nil
    end
  end
  local n = 0
  local oldest, oldestExp
  for token, exp in pairs(self.sessions) do
    n = n + 1
    if oldestExp == nil or exp < oldestExp then
      oldest, oldestExp = token, exp
    end
  end
  if n >= M.LIMITS.sessions and oldest then
    self.sessions[oldest] = nil
  end
  self.counter = self.counter + 1
  local token = (self.hmac("pinlock-session", string.format("%s|%d|%.9f|%.9f", tostring(t), self.counter, self.random(), self.random()))):sub(1, 32)
  self.sessions[token] = t + self.settings.sessionSeconds
  return token
end

function Engine:sessionValid(token)
  token = tostring(token or "")
  local exp = self.sessions[token]
  if exp == nil then
    return false
  end
  local t = self:now()
  if exp <= t then
    self.sessions[token] = nil
    return false
  end
  self.sessions[token] = t + self.settings.sessionSeconds
  return true
end

function Engine:endSession(token)
  self.sessions[tostring(token or "")] = nil
end

--- Admin sign-in with an owner PIN. Counts against the "admin" entry point.
--- @return table { ok, session?, code?, locked?, retry_in? }
function Engine:login(pin)
  local entry = "admin"
  local locked, left = self:lockState(entry)
  if locked then
    return self:_lockedResult(entry, nil, left)
  end
  pin = tostring(pin or "")
  if not pin:match("^%d+$") or #pin < Pin.MIN or #pin > Pin.MAX then
    return self:_fail(entry, nil, nil, "wrong_pin")
  end
  local code = self:_findBySecret("pin", pin)
  if code == nil then
    return self:_fail(entry, nil, nil, "wrong_pin")
  end
  if code.role ~= "owner" then
    return self:_fail(entry, code, nil, "not_owner")
  end
  local ok, why = self:_validity(code, nil, self:now())
  if not ok then
    return self:_fail(entry, code, nil, why)
  end
  local l = self:_lock(entry)
  l.fails, l.last = 0, nil
  self:_recordRecent({ t = self:now(), result = "granted", code = code.name, entry = entry, action = "admin sign-in" })
  self:_emit("granted_admin", { code = code.name })
  return { ok = true, session = self:_newSession(), code = code.name }
end

--- Creates the first owner code. Allowed only while no owner code exists.
function Engine:setup(name, pin)
  if self:hasOwner() then
    return false, "an owner code already exists"
  end
  local id, why = self:addCode({ name = name, role = "owner", pin = pin })
  if not id then
    return false, why
  end
  return true, id
end

-- ─── views ──────────────────────────────────────────────────────────────────

function Engine:activeCount()
  local n = 0
  for _, c in ipairs(self.codes) do
    if self:codeState(c) == "active" then
      n = n + 1
    end
  end
  return n
end

--- Codes for the admin page: hashes and salts are never included.
function Engine:publicCodes()
  local out = {}
  for _, c in ipairs(self.codes) do
    out[#out + 1] = {
      id = c.id,
      name = c.name,
      role = c.role,
      enabled = c.enabled,
      state = self:codeState(c),
      actions = sortedKeys(c.actions),
      has_pin = c.pin ~= nil,
      has_seq = c.seq ~= nil,
      keypad_action = c.keypad_action,
      days = c.days and sortedKeys(c.days) or {},
      from = M.formatHM(c.from),
      to = M.formatHM(c.to),
      starts = c.starts,
      expires = c.expires,
      max_uses = c.max_uses,
      uses = c.uses or 0,
      temp = c.temp == true,
    }
  end
  return out
end

function Engine:lockSummary()
  local out = {}
  for entry in pairs(M.ENTRIES) do
    local locked, left = self:lockState(entry)
    out[entry] = { locked = locked, seconds = left }
  end
  return out
end

--- Turns the admin page's save document into an addCode/updateCode spec.
function M.specFromPage(doc)
  doc = type(doc) == "table" and doc or {}
  local spec = {
    name = doc.name,
    role = doc.role,
    actions = doc.actions or {},
    days = doc.days or {},
    from = doc.from or "",
    to = doc.to or "",
    max_uses = doc.max_uses,
    keypad_action = doc.keypad_action,
  }
  if type(doc.pin) == "string" and trim(doc.pin) ~= "" then
    spec.pin = trim(doc.pin)
  end
  if type(doc.seq) == "string" and trim(doc.seq) ~= "" then
    spec.seq = trim(doc.seq)
  end
  if doc.clear_seq == true then
    spec.clear_seq = true
  end
  local sd, ed = trim(doc.start_date), trim(doc.expiry_date)
  -- 0 means "no start" / "no expiry" (an edit clearing the field).
  spec.starts, spec.expires = 0, 0
  if sd ~= "" then
    spec.starts = M.dayEpoch(sd, false)
    if spec.starts == nil then
      return nil, "dates must be YYYY-MM-DD"
    end
  end
  if ed ~= "" then
    spec.expires = M.dayEpoch(ed, true)
    if spec.expires == nil then
      return nil, "dates must be YYYY-MM-DD"
    end
  end
  return spec
end

-- ─── persistence ────────────────────────────────────────────────────────────

--- State for the controller's ENCRYPTED persist store: digests, never PINs.
function Engine:serialize()
  local codes = {}
  for _, c in ipairs(self.codes) do
    codes[#codes + 1] = {
      id = c.id,
      name = c.name,
      role = c.role,
      enabled = c.enabled,
      actions = sortedKeys(c.actions),
      pin = c.pin,
      seq = c.seq,
      keypad_action = c.keypad_action,
      days = c.days and sortedKeys(c.days) or nil,
      from = c.from,
      to = c.to,
      starts = c.starts,
      expires = c.expires,
      max_uses = c.max_uses,
      uses = c.uses,
      created = c.created,
      temp = c.temp,
    }
  end
  local locks = {}
  for entry, l in pairs(self.locks) do
    locks[entry] = { fails = l.fails, last = l.last, until_ = l.until_ }
  end
  return { v = 1, counter = self.counter, codes = codes, locks = locks }
end

local function cred(v)
  if type(v) == "table" and type(v.salt) == "string" and type(v.hash) == "string" and tonumber(v.it) then
    return { salt = v.salt, hash = v.hash, it = tonumber(v.it) }
  end
  return nil
end

function Engine:restore(doc)
  if type(doc) ~= "table" or doc.v ~= 1 then
    return 0
  end
  self.codes = {}
  self.counter = tonumber(doc.counter) or 0
  for _, raw in ipairs(type(doc.codes) == "table" and doc.codes or {}) do
    if type(raw) == "table" and type(raw.id) == "string" and type(raw.name) == "string" and M.ROLES[raw.role] then
      local code = {
        id = raw.id,
        name = cleanName(raw.name, M.LIMITS.name),
        role = raw.role,
        enabled = raw.enabled ~= false,
        actions = slotSet(raw.actions),
        pin = cred(raw.pin),
        seq = cred(raw.seq),
        keypad_action = toInt(raw.keypad_action),
        days = nil,
        from = tonumber(raw.from),
        to = tonumber(raw.to),
        starts = tonumber(raw.starts),
        expires = tonumber(raw.expires),
        max_uses = toInt(raw.max_uses),
        uses = toInt(raw.uses) or 0,
        created = tonumber(raw.created),
        temp = raw.temp == true or nil,
      }
      if type(raw.days) == "table" and next(raw.days) ~= nil then
        code.days = slotSet(raw.days)
        if next(code.days) == nil then
          code.days = nil
        end
      end
      if (code.pin or code.seq) and code.name ~= "" and #self.codes < M.LIMITS.codes then
        self.codes[#self.codes + 1] = code
      end
    end
  end
  self.locks = {}
  local t = self:now()
  for entry, l in pairs(type(doc.locks) == "table" and doc.locks or {}) do
    if M.ENTRIES[entry] and type(l) == "table" then
      local lock = { fails = toInt(l.fails) or 0, last = tonumber(l.last) }
      local untilAt = tonumber(l.until_)
      if untilAt ~= nil and untilAt > t then
        lock.until_ = untilAt
      end
      self.locks[entry] = lock
    end
  end
  return #self.codes
end

return M
