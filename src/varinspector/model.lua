--- Variable Inspector — the inspector model (pure, injected Director surface).
---
--- What a technician gets without Composer Pro: every device in the
--- project, the variables of the one they tapped (live while it is open),
--- a persisted watch list with a short history per watched variable, and a
--- guarded Set. The rules a technician relies on:
---
---   • ONE OPEN DEVICE. Opening a device registers listeners for its
---     variables and releases the previous device's; closing releases them.
---     Listeners for WATCHED variables stay registered whatever is open.
---   • RECONCILIATION. The desired listener set (open device ∪ watch list)
---     is diffed against the registered set; an identical apply registers
---     nothing twice and a removed watch releases exactly its pair.
---   • MASKING. Variables whose name carries a credential fragment (the
---     Flight Recorder's FIXED_EXCLUSIONS: USERCODE, PINCODE, PASSWORD,
---     TOKEN, …) are shown as a mask, never watched, never set, never kept
---     in history. Not overridable.
---   • BOUNDED. At most `max_watches` watched variables (default 64); a
---     history ring of `history_size` entries per watched variable
---     (tracer.ring, 50..2000, default 50).
---   • SET IS A PROBE. The write path calls the injected `setVariable`
---     (C4:SetDeviceVariable on the controller — documented, unmeasured
---     here) and reports what happened by NAME; it never claims success
---     from silence: the page reads the value back on the next refresh.
---   • READ-ONLY MODE. With `readOnly` true (licence enforcement, or no
---     Dealer PIN configured for the page) every write is refused by name.

local Ring = require("tracer.ring")
local Config = require("flightrecorder.config")
local Recorder = require("flightrecorder.recorder")

local M = {}

M.LIMITS = {
  max_watches_default = 64,
  max_watches_ceiling = 64,
  history_default = Ring.LIMITS.capacity_default,
  history_min = Ring.LIMITS.capacity_min, -- the ring's own floor (50)
  history_max = 200,
  filter = 60,
  value_text = 512,
}

M.MASK = "••••••"

--- A credential-named variable, by the Flight Recorder's fixed list.
function M.isMasked(variableName)
  return Config.isFixedExclusion(variableName)
end

--- The project's devices as a sorted list the page can render.
--- `devices` has the C4:GetDevices shape; `selfId` is left out.
function M.deviceList(devices, selfId)
  local out = {}
  for rawId, d in pairs(devices or {}) do
    local id = tonumber(rawId)
    if id ~= nil and type(d) == "table" and id ~= selfId then
      out[#out + 1] = {
        id = id,
        name = tostring(d.deviceName or ("Device " .. id)),
        room_id = tonumber(d.roomId),
        room = d.roomName and tostring(d.roomName) or nil,
        driver = tostring(d.driverFileName or ""),
      }
    end
  end
  table.sort(out, function(a, b)
    local ra, rb = a.room or "", b.room or ""
    if ra ~= rb then
      return ra < rb
    end
    if a.name ~= b.name then
      return a.name < b.name
    end
    return a.id < b.id
  end)
  return out
end

--- Case-insensitive filter over name, room, driver and id.
function M.filterDevices(list, text)
  text = tostring(text or ""):lower():sub(1, M.LIMITS.filter)
  if text == "" then
    return list
  end
  local out = {}
  for _, d in ipairs(list) do
    local hay = (d.name .. " " .. (d.room or "") .. " " .. d.driver .. " " .. tostring(d.id)):lower()
    if hay:find(text, 1, true) then
      out[#out + 1] = d
    end
  end
  return out
end

--- One device's variables (C4:GetDeviceVariables shape, keyed by id) as a
--- sorted, typed, masked list.
function M.snapshot(vars)
  local out = {}
  for rawId, v in pairs(vars or {}) do
    local id = tonumber(rawId)
    if id ~= nil and type(v) == "table" and type(v.name) == "string" then
      local masked = M.isMasked(v.name)
      local value, vtype = Recorder.typedValue(v.value)
      if type(value) == "string" then
        value = value:sub(1, M.LIMITS.value_text)
      end
      out[#out + 1] = {
        id = id,
        name = v.name,
        value = masked and M.MASK or value,
        type = masked and "masked" or vtype,
        readonly = tostring(v.readonly) == "true" or v.readonly == true,
        masked = masked,
      }
    end
  end
  table.sort(out, function(a, b)
    return a.name < b.name or (a.name == b.name and a.id < b.id)
  end)
  return out
end

local function wkey(deviceId, varId)
  return tostring(deviceId) .. ":" .. tostring(varId)
end
M.key = wkey

local Inspector = {}
Inspector.__index = Inspector

--- @param deps table {
---   now = fun():number,
---   register = fun(deviceId, varId):boolean, unregister = fun(deviceId, varId),
---   readVariables = fun(deviceId):table|nil, devices = fun():table,
---   setVariable = fun(deviceId, varId, value):boolean, string|nil,
---   emit = fun(kind, detail)   -- "change" | "set" | "refused"
---   selfDeviceId = number|nil, historySize = number|nil, maxWatches = number|nil,
--- }
function M.new(deps)
  local self = setmetatable({}, Inspector)
  self.deps = deps
  self.historySize = math.max(
    M.LIMITS.history_min,
    math.min(M.LIMITS.history_max, tonumber(deps.historySize) or M.LIMITS.history_default)
  )
  self.maxWatches =
    math.max(1, math.min(M.LIMITS.max_watches_ceiling, tonumber(deps.maxWatches) or M.LIMITS.max_watches_default))
  self.open = nil -- { device_id, vars = {[id]=entry} }
  self.watches = {} -- key -> { device_id, variable_id, name, device_label, ring, added_at }
  self.watchOrder = {}
  self.registered = {} -- key -> { device_id, variable_id, name }
  self.readOnly = false
  self.last = nil -- last watched change
  self.counters = { changes = 0, watched_changes = 0, sets = 0, refused = 0, listeners = 0 }
  return self
end

function Inspector:setReadOnly(flag)
  self.readOnly = flag == true
end

-- ── Listener reconciliation ──────────────────────────────────────────────────

function Inspector:_desired()
  local want = {}
  for key, w in pairs(self.watches) do
    want[key] = { device_id = w.device_id, variable_id = w.variable_id, name = w.name }
  end
  if self.open ~= nil then
    for id, e in pairs(self.open.vars) do
      if not e.masked then
        want[wkey(self.open.device_id, id)] = { device_id = self.open.device_id, variable_id = id, name = e.name }
      end
    end
  end
  return want
end

function Inspector:_reconcile()
  local want = self:_desired()
  local added, removed = 0, 0
  for key, r in pairs(self.registered) do
    if want[key] == nil then
      pcall(self.deps.unregister, r.device_id, r.variable_id)
      self.registered[key] = nil
      removed = removed + 1
    end
  end
  for key, w in pairs(want) do
    if self.registered[key] == nil then
      local ok, result = pcall(self.deps.register, w.device_id, w.variable_id)
      if ok and result ~= false then
        self.registered[key] = w
        added = added + 1
      end
    end
  end
  local n = 0
  for _ in pairs(self.registered) do
    n = n + 1
  end
  self.counters.listeners = n
  return added, removed
end

-- ── Devices and the open device ──────────────────────────────────────────────

function Inspector:devices(filter)
  local list = M.deviceList(self.deps.devices() or {}, self.deps.selfDeviceId)
  return M.filterDevices(list, filter)
end

function Inspector:deviceInfo(deviceId)
  local d = (self.deps.devices() or {})[deviceId] or (self.deps.devices() or {})[tostring(deviceId)]
  if type(d) ~= "table" then
    return nil
  end
  return {
    id = deviceId,
    name = tostring(d.deviceName or ("Device " .. deviceId)),
    room = d.roomName,
    driver = d.driverFileName,
  }
end

--- Opens a device: reads its variables, registers listeners for them (the
--- previous open device is released). Returns the snapshot or nil, reason.
function Inspector:openDevice(deviceId)
  deviceId = tonumber(deviceId)
  if deviceId == nil then
    return nil, "device id required"
  end
  if deviceId == self.deps.selfDeviceId then
    return nil, "the inspector does not inspect itself"
  end
  local vars = self.deps.readVariables(deviceId)
  if type(vars) ~= "table" or next(vars) == nil then
    return nil, "device has no readable variables (or is not in the project)"
  end
  local snap = M.snapshot(vars)
  local byId = {}
  for _, e in ipairs(snap) do
    byId[e.id] = e
  end
  self.open = { device_id = deviceId, vars = byId, opened_at = self.deps.now() }
  self:_reconcile()
  return snap
end

function Inspector:closeDevice()
  if self.open == nil then
    return false
  end
  self.open = nil
  self:_reconcile()
  return true
end

--- The open device's live snapshot (sorted list), or nil.
function Inspector:openSnapshot()
  if self.open == nil then
    return nil
  end
  local out = {}
  for _, e in pairs(self.open.vars) do
    out[#out + 1] = e
  end
  table.sort(out, function(a, b)
    return a.name < b.name or (a.name == b.name and a.id < b.id)
  end)
  return out
end

-- ── Watch list ───────────────────────────────────────────────────────────────

function Inspector:watchCount()
  return #self.watchOrder
end

--- Adds a watch. The variable name is read from the device if not given.
--- @return boolean ok, string reason
function Inspector:watch(deviceId, varId, name)
  deviceId, varId = tonumber(deviceId), tonumber(varId)
  if deviceId == nil or varId == nil then
    return false, "device id and variable id required"
  end
  if self.readOnly then
    return false, "read-only: licence enforcement or no Dealer PIN"
  end
  local key = wkey(deviceId, varId)
  if self.watches[key] ~= nil then
    return false, "already watched"
  end
  if #self.watchOrder >= self.maxWatches then
    return false, "watch list full (" .. self.maxWatches .. ")"
  end
  local current = nil
  if name == nil or name == "" then
    local vars = self.deps.readVariables(deviceId)
    local v = type(vars) == "table" and (vars[varId] or vars[tostring(varId)]) or nil
    if type(v) ~= "table" or type(v.name) ~= "string" then
      return false, "variable not found on the device"
    end
    name = v.name
    current = v.value
  end
  if M.isMasked(name) then
    return false, "credential-named variables are never watched"
  end
  local info = self:deviceInfo(deviceId)
  local w = {
    device_id = deviceId,
    variable_id = varId,
    name = tostring(name),
    device_label = info and info.name or ("Device " .. deviceId),
    room = info and info.room or nil,
    ring = Ring.new(self.historySize),
    added_at = self.deps.now(),
  }
  if current ~= nil then
    local value, vtype = Recorder.typedValue(current)
    w.value, w.vtype = value, vtype
  end
  self.watches[key] = w
  self.watchOrder[#self.watchOrder + 1] = key
  self:_reconcile()
  return true, "watching"
end

function Inspector:unwatch(deviceId, varId)
  local key = wkey(tonumber(deviceId), tonumber(varId))
  if self.watches[key] == nil then
    return false, "not watched"
  end
  if self.readOnly then
    return false, "read-only: licence enforcement or no Dealer PIN"
  end
  self.watches[key] = nil
  local keep = {}
  for _, k in ipairs(self.watchOrder) do
    if k ~= key then
      keep[#keep + 1] = k
    end
  end
  self.watchOrder = keep
  self:_reconcile()
  return true, "released"
end

function Inspector:clearHistory()
  for _, w in pairs(self.watches) do
    w.ring = Ring.new(self.historySize)
  end
  self.last = nil
end

--- The watch list with the newest `n` history entries each.
function Inspector:watchList(n)
  local out = {}
  for _, key in ipairs(self.watchOrder) do
    local w = self.watches[key]
    if w then
      out[#out + 1] = {
        key = key,
        device_id = w.device_id,
        variable_id = w.variable_id,
        name = w.name,
        device_label = w.device_label,
        room = w.room,
        value = w.value,
        type = w.vtype or "unknown",
        changed_at = w.changed_at,
        changes = w.ring.seq,
        history = w.ring:recent(n or 10),
      }
    end
  end
  return out
end

--- Persistable watch list (no history: the ring is memory, the list is the
--- durable part) and restoration.
function Inspector:watchDoc()
  local doc = {}
  for _, key in ipairs(self.watchOrder) do
    local w = self.watches[key]
    if w then
      doc[#doc + 1] = {
        device_id = w.device_id,
        variable_id = w.variable_id,
        name = w.name,
        device_label = w.device_label,
        room = w.room,
      }
    end
  end
  return doc
end

function Inspector:restoreWatches(doc)
  if type(doc) ~= "table" then
    return 0
  end
  local n = 0
  local wasReadOnly = self.readOnly
  self.readOnly = false
  for _, item in ipairs(doc) do
    if
      type(item) == "table"
      and tonumber(item.device_id)
      and tonumber(item.variable_id)
      and type(item.name) == "string"
    then
      local ok = self:watch(item.device_id, item.variable_id, item.name)
      if ok then
        n = n + 1
        local w = self.watches[wkey(tonumber(item.device_id), tonumber(item.variable_id))]
        w.device_label = item.device_label or w.device_label
        w.room = item.room or w.room
      end
    end
  end
  self.readOnly = wasReadOnly
  return n
end

-- ── Changes ──────────────────────────────────────────────────────────────────

--- Director's callback for a registered variable. Returns true when it was
--- one of ours (open device or watched).
function Inspector:onChange(deviceId, varId, raw)
  deviceId, varId = tonumber(deviceId), tonumber(varId)
  local key = wkey(deviceId, varId)
  local ours = false
  local value, vtype = Recorder.typedValue(raw)
  if type(value) == "string" then
    value = value:sub(1, M.LIMITS.value_text)
  end
  if self.open ~= nil and self.open.device_id == deviceId then
    local e = self.open.vars[varId]
    if e ~= nil and not e.masked then
      e.value, e.type, e.changed_at = value, vtype, self.deps.now()
      ours = true
    end
  end
  local w = self.watches[key]
  if w ~= nil then
    ours = true
    local previous, previousKnown = w.value, w.vtype ~= nil and w.vtype ~= "unknown"
    w.value, w.vtype, w.changed_at = value, vtype, self.deps.now()
    w.ring:push({ t = self.deps.now(), value = value, type = vtype, previous = previousKnown and previous or nil })
    self.counters.watched_changes = self.counters.watched_changes + 1
    self.last = {
      key = key,
      device_id = deviceId,
      variable_id = varId,
      name = w.name,
      device_label = w.device_label,
      value = value,
      type = vtype,
      t = self.deps.now(),
    }
    if self.deps.emit then
      pcall(self.deps.emit, "change", self.last)
    end
  end
  if ours then
    self.counters.changes = self.counters.changes + 1
  end
  return ours
end

-- ── Set (the PROBE) ──────────────────────────────────────────────────────────

--- Writes a variable through the injected setter. Refused by name when
--- read-only, masked, or not identifiable. The result never claims the
--- value took: the next read of the device says.
--- @return boolean ok, string detail
function Inspector:setValue(deviceId, varId, value, pinOk)
  deviceId, varId = tonumber(deviceId), tonumber(varId)
  local function refuse(why)
    self.counters.refused = self.counters.refused + 1
    if self.deps.emit then
      pcall(self.deps.emit, "refused", { device_id = deviceId, variable_id = varId, reason = why })
    end
    return false, why
  end
  if deviceId == nil or varId == nil then
    return refuse("device id and variable id required")
  end
  if self.readOnly then
    return refuse("read-only: licence enforcement or no Dealer PIN")
  end
  if pinOk ~= true then
    return refuse("Dealer PIN required")
  end
  local name = nil
  local vars = self.deps.readVariables(deviceId)
  local v = type(vars) == "table" and (vars[varId] or vars[tostring(varId)]) or nil
  if type(v) == "table" and type(v.name) == "string" then
    name = v.name
  elseif self.watches[wkey(deviceId, varId)] then
    name = self.watches[wkey(deviceId, varId)].name
  end
  if name == nil then
    return refuse("variable not found on the device")
  end
  if M.isMasked(name) then
    return refuse("credential-named variables are never written")
  end
  if type(v) == "table" and (tostring(v.readonly) == "true" or v.readonly == true) then
    return refuse("variable is read-only on its device")
  end
  local text = tostring(value == nil and "" or value):sub(1, M.LIMITS.value_text)
  local ok, result, err = pcall(self.deps.setVariable, deviceId, varId, text)
  if not ok then
    return refuse("set failed: " .. tostring(result))
  end
  if result == false then
    return refuse("set refused: " .. tostring(err or "Director returned false"))
  end
  self.counters.sets = self.counters.sets + 1
  if self.deps.emit then
    pcall(self.deps.emit, "set", { device_id = deviceId, variable_id = varId, name = name, value = text })
  end
  return true, "sent to Director (C4:SetDeviceVariable); verify on the next read"
end

-- ── Lifecycle / views ────────────────────────────────────────────────────────

function Inspector:stop()
  for key, r in pairs(self.registered) do
    pcall(self.deps.unregister, r.device_id, r.variable_id)
    self.registered[key] = nil
  end
  self.counters.listeners = 0
end

function Inspector:status()
  return {
    read_only = self.readOnly,
    open_device = self.open and self.open.device_id or nil,
    watched = #self.watchOrder,
    max_watches = self.maxWatches,
    history_size = self.historySize,
    listeners = self.counters.listeners,
    counters = self.counters,
    last = self.last,
  }
end

function M.formatHistory(name, e)
  local when = e.t and os.date("%H:%M:%S", math.floor(e.t)) or "--:--:--"
  return string.format(
    "%s  #%d  %s = %s%s",
    when,
    e.seq or 0,
    name,
    tostring(e.value),
    e.previous ~= nil and ("  (was " .. tostring(e.previous) .. ")") or ""
  )
end

return M
