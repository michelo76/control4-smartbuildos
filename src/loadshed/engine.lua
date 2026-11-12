--- Load Shedding -- the engine (pure: injected clock, timers, device I/O).
---
--- Sheds heavy loads in three priority tiers when the grid drops or the
--- battery runs low, then restores them in order once power is back and has
--- held. Vendor-neutral: the outage and the battery level come in as plain
--- facts (setOutage, setBattery); the driver decides where they come from.
---
--- Rules (all tested):
---   * Tier 1 sheds the moment an outage starts. Tier 2 and 3 shed when the
---     battery is at or below their percentage; when no FRESH battery
---     reading exists they shed after their "no data" minutes of outage
---     (0 turns the time path off for that tier). A tier sheds only after
---     the tier below it (1 -> 2 -> 3).
---   * Before a load is shed its PRIOR state is read and remembered. A load
---     that was already off/open/at setback is never restored "on".
---   * Power back: the outage must stay clear for stable_hold_s. If it drops
---     again before then, the hold is abandoned (flap) and nothing restores.
---   * Restore runs in reverse order of shedding, tier 3 first then 2 then 1
---     (the tier that held on longest is the least heavy and comes back
---     first; the heaviest, tier 1, comes back last), tier_delay_s apart to
---     spread inrush. An outage during the restore stops it; what is still
---     shed stays shed, restored tiers are shed again.
---   * Everything needed to finish an outage is in serialize(): a reboot
---     mid-outage resumes (outage, hold or restore) from that.
---   * read-only (licence halt): everything already shed is RESTORED first,
---     then every public call is refused. A halt never leaves a load shed.
---
--- deps = { now = fn():seconds, schedule = fn(id, ms, fn), cancel = fn(id),
---          emit = fn(kind, fields), read = fn(load):prior|nil,
---          send = fn(deviceId, command, params):boolean }

local M = {}

M.LIMITS = { slots = 12, resheds_per_outage = 5, tick_s = 30, reshed_grace_s = 3, state_version = 1 }

M.DEFAULTS = {
  tier2_pct = 50,
  tier3_pct = 20,
  tier2_nodata_min = 15,
  tier3_nodata_min = 45,
  stable_hold_s = 120,
  tier_delay_s = 30,
  reshed = false,
}

M.KINDS = { light = true, relay = true, thermostat = true }

local TIMER_TICK, TIMER_HOLD, TIMER_RESTORE = "ls_tick", "ls_hold", "ls_restore"

local function shallow(t)
  local o = {}
  for k, v in pairs(t) do
    o[k] = v
  end
  return o
end

local function deepcopy(v)
  if type(v) ~= "table" then
    return v
  end
  local o = {}
  for k, x in pairs(v) do
    o[k] = deepcopy(x)
  end
  return o
end

-- ─── Pure helpers ───────────────────────────────────────────────────────────

local function lower(s)
  return tostring(s or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
end

--- True when raw equals one of the comma-separated values (case-insensitive,
--- numbers compare numerically so "1" matches "1.0").
function M.valueMatches(raw, csv)
  local v = lower(raw)
  if v == "" then
    return false
  end
  for item in tostring(csv or ""):gmatch("[^,]+") do
    local w = lower(item)
    if w ~= "" and (w == v or (tonumber(w) ~= nil and tonumber(w) == tonumber(v))) then
      return true
    end
  end
  return false
end

--- "Kitchen Heat Pump (Garage) · 142" -> 142
function M.parseDeviceId(label)
  local id = tostring(label or ""):match("·%s*(%d+)%s*$")
  return id and tonumber(id) or nil
end

--- "82,5015" (a VARIABLE_SELECTOR value) -> 82, 5015
function M.parseVariablePick(s)
  local d, v = tostring(s or ""):match("^%s*(%d+)%s*,%s*(%d+)%s*$")
  if d then
    return tonumber(d), tonumber(v)
  end
  return nil
end

local function truthy(s)
  s = lower(s)
  return s == "1" or s == "true" or s == "on" or s == "closed" or s == "close"
end

--- Prior-state readers: vars is { [name] = value }. nil = unknown.
function M.readLight(vars)
  local level = tonumber(vars["Brightness Percent"]) or tonumber(vars["LIGHT_LEVEL"])
  local state = vars["LIGHT_STATE"]
  local on
  if state ~= nil then
    on = truthy(state)
  elseif level ~= nil then
    on = level > 0
  else
    return nil
  end
  return { known = true, on = on, level = level }
end

function M.readRelay(vars)
  local raw = vars["STATE"] or vars["RELAY_STATE"] or vars["CONTACT_STATE"]
  if raw == nil then
    return nil
  end
  return { known = true, closed = truthy(raw) }
end

function M.readThermostat(vars)
  if vars["HVAC_MODE"] == nil then
    return nil
  end
  return {
    known = true,
    hvac_mode = tostring(vars["HVAC_MODE"]),
    heat_f = tonumber(vars["HEAT_SETPOINT_F"]) or tonumber(vars["DISPLAY_HEATSETPOINT"]),
    cool_f = tonumber(vars["COOL_SETPOINT_F"]),
  }
end

function M.readerFor(kind)
  if kind == "light" then
    return M.readLight
  elseif kind == "relay" then
    return M.readRelay
  end
  return M.readThermostat
end

--- The commands that shed `load` given its prior state, or nil + a reason
--- when there is nothing to do (already off, unknown mode, ...).
function M.shedCommands(load, prior)
  prior = prior or {}
  if load.kind == "light" then
    if prior.known and prior.on == false then
      return nil, "already off"
    end
    return { { "OFF", {} } }
  elseif load.kind == "relay" then
    if prior.known and prior.closed == false then
      return nil, "already open"
    end
    return { { "OPEN", {} } }
  elseif load.kind == "thermostat" then
    if not prior.known then
      return nil, "thermostat state unknown, left alone"
    end
    local mode = lower(prior.hvac_mode)
    local sb = tonumber(load.setback_f)
    if sb == nil then
      return nil, "no setback temperature set"
    end
    if mode:find("heat", 1, true) then
      if prior.heat_f == nil or prior.heat_f <= sb then
        return nil, "heat setpoint already at or below the setback"
      end
      return { { "SET_SETPOINT_HEAT", { FAHRENHEIT = sb } } }
    elseif mode:find("cool", 1, true) then
      if prior.cool_f == nil or prior.cool_f >= sb then
        return nil, "cool setpoint already at or above the setback"
      end
      return { { "SET_SETPOINT_COOL", { FAHRENHEIT = sb } } }
    end
    return nil, "mode '" .. tostring(prior.hvac_mode) .. "' has no setback (Heat and Cool only)"
  end
  return nil, "unknown kind"
end

--- The commands that put `load` back. Uses the snapshot taken at shed time.
function M.restoreCommands(load, prior)
  prior = prior or {}
  if load.kind == "light" then
    local level = tonumber(prior.level)
    if level and level > 0 and level < 100 then
      return { { "RAMP_TO_LEVEL", { LEVEL = level, TIME = 0 } } }
    end
    return { { "ON", {} } }
  elseif load.kind == "relay" then
    return { { "CLOSE", {} } }
  elseif load.kind == "thermostat" then
    local mode = lower(prior.hvac_mode)
    if mode:find("heat", 1, true) and prior.heat_f then
      return { { "SET_SETPOINT_HEAT", { FAHRENHEIT = prior.heat_f } } }
    elseif mode:find("cool", 1, true) and prior.cool_f then
      return { { "SET_SETPOINT_COOL", { FAHRENHEIT = prior.cool_f } } }
    end
  end
  return nil
end

--- Normalises a load definition. nil + reason when it cannot be used.
function M.normaliseLoad(raw)
  raw = raw or {}
  local slot = tonumber(raw.slot)
  local id = tonumber(raw.device_id)
  local tier = tonumber(raw.tier)
  if slot == nil or id == nil then
    return nil, "no device"
  end
  if not M.KINDS[raw.kind] then
    return nil, "unknown kind"
  end
  if tier == nil or tier < 1 or tier > 3 or tier ~= math.floor(tier) then
    return nil, "tier must be 1, 2 or 3"
  end
  local sb = tonumber(raw.setback_f)
  if raw.kind == "thermostat" and (sb == nil or sb < 40 or sb > 95) then
    return nil, "setback must be 40-95 F"
  end
  return {
    slot = slot,
    device_id = id,
    kind = raw.kind,
    tier = tier,
    setback_f = sb,
    name = raw.name and tostring(raw.name):sub(1, 60) or nil,
  }
end

-- ─── Engine ─────────────────────────────────────────────────────────────────

local Engine = {}
Engine.__index = Engine

local function fresh()
  return {
    phase = "normal", -- normal | outage | holding | restoring
    outage_since = nil,
    power_back_at = nil,
    shed_tiers = {}, -- [tier] = true
    shed = {}, -- [slot] = { load = snapshot, prior = table, skip = reason|nil, at = t, failed = bool }
    queue = {}, -- tiers still to restore (descending)
    battery = nil,
    battery_at = nil,
    resheds = {}, -- [slot] = count this outage
    last_cmd = {}, -- [slot] = time of our last command
    flaps = 0,
  }
end

function M.new(deps)
  local self = setmetatable({}, Engine)
  self.deps = deps
  self.cfg = shallow(M.DEFAULTS)
  self.loads = {}
  self.st = fresh()
  self.readOnly = false
  self.draining = false -- restoring because of a licence halt
  return self
end

function Engine:now()
  return self.deps.now()
end

function Engine:emit(kind, f)
  pcall(self.deps.emit, kind, f or {})
  pcall(self.deps.emit, "changed", {})
end

function Engine:setConfig(c)
  for k, d in pairs(M.DEFAULTS) do
    local v = c and c[k]
    if v == nil then
      v = d
    end
    self.cfg[k] = v
  end
  for _, k in ipairs({ "tier2_pct", "tier3_pct" }) do
    self.cfg[k] = math.max(0, math.min(100, tonumber(self.cfg[k]) or M.DEFAULTS[k]))
  end
  for _, k in ipairs({ "tier2_nodata_min", "tier3_nodata_min", "stable_hold_s", "tier_delay_s" }) do
    self.cfg[k] = math.max(0, tonumber(self.cfg[k]) or M.DEFAULTS[k])
  end
  self.cfg.reshed = self.cfg.reshed == true
end

--- loads: array of raw definitions; returns the problems found.
function Engine:setLoads(list)
  self.loads = {}
  local problems = {}
  for _, raw in ipairs(list or {}) do
    local l, why = M.normaliseLoad(raw)
    if l then
      self.loads[#self.loads + 1] = l
    elseif raw and raw.slot then
      problems[#problems + 1] = { slot = raw.slot, why = why }
    end
  end
  table.sort(self.loads, function(a, b)
    return a.slot < b.slot
  end)
  return problems
end

function Engine:refuse()
  if self.readOnly then
    return false, "read-only"
  end
  return true
end

-- ── timers ──

function Engine:armTick()
  self.deps.schedule(TIMER_TICK, M.LIMITS.tick_s * 1000, function()
    self:onTick()
  end)
end

function Engine:cancelAll()
  self.deps.cancel(TIMER_TICK)
  self.deps.cancel(TIMER_HOLD)
  self.deps.cancel(TIMER_RESTORE)
end

function Engine:onTick()
  if self.st.phase ~= "outage" or self.readOnly then
    return
  end
  self:evaluate()
  self:armTick()
end

-- ── shedding ──

function Engine:shedLoad(load, reason)
  local prior = {}
  local okRead, got = pcall(self.deps.read, load)
  if okRead and type(got) == "table" then
    prior = got
  end
  local cmds, why = M.shedCommands(load, prior)
  local rec = { load = shallow(load), prior = prior, at = self:now() }
  if not cmds then
    rec.skip = why
  else
    for _, c in ipairs(cmds) do
      local ok = self.deps.send(load.device_id, c[1], c[2])
      if ok == false then
        rec.failed = true
        self:emit("load_error", { slot = load.slot, action = "shed", command = c[1] })
      end
    end
    self.st.last_cmd[load.slot] = self:now()
  end
  self.st.shed[load.slot] = rec
  self:emit("load_shed", { slot = load.slot, tier = load.tier, skipped = rec.skip, reason = reason })
end

function Engine:shedTier(t, reason)
  if self.st.shed_tiers[t] then
    return 0
  end
  local n = 0
  for _, l in ipairs(self.loads) do
    if l.tier == t and self.st.shed[l.slot] == nil then
      self:shedLoad(l, reason)
      n = n + 1
    end
  end
  self.st.shed_tiers[t] = true
  self:emit("tier_shed", { tier = t, count = n, reason = reason })
  return n
end

function Engine:batteryFresh(maxAgeMin)
  local s = self.st
  return s.battery ~= nil and s.battery_at ~= nil and (self:now() - s.battery_at) <= maxAgeMin * 60
end

--- Which tiers the outage calls for right now (pure given state).
function Engine:wantedTiers()
  local s, c = self.st, self.cfg
  local elapsed = self:now() - (s.outage_since or self:now())
  local want = { true, false, false }
  for t = 2, 3 do
    local pct = c["tier" .. t .. "_pct"]
    local nodata = c["tier" .. t .. "_nodata_min"]
    local by = false
    if want[t - 1] then
      if self:batteryFresh(nodata > 0 and nodata or 15) then
        by = s.battery <= pct and "battery"
      elseif nodata > 0 and elapsed >= nodata * 60 then
        by = "no battery data"
      end
    end
    want[t] = by
  end
  return want
end

function Engine:evaluate()
  if self.st.phase ~= "outage" then
    return
  end
  local want = self:wantedTiers()
  for t = 1, 3 do
    if want[t] and not self.st.shed_tiers[t] then
      self:shedTier(t, want[t] == true and "outage" or want[t])
    end
  end
end

-- ── public: facts in ──

function Engine:setBattery(pct)
  pct = tonumber(pct)
  if pct == nil then
    return false, "not a number"
  end
  self.st.battery = math.max(0, math.min(100, pct))
  self.st.battery_at = self:now()
  self:emit("battery", { pct = self.st.battery })
  if not self.readOnly then
    self:evaluate()
  end
  return true
end

--- The battery input was removed: forget the last reading so the time path
--- (no-data minutes) takes over instead of an old percentage.
function Engine:clearBattery()
  self.st.battery = nil
  self.st.battery_at = nil
  self:emit("battery", {})
end

function Engine:setOutage(on, source)
  local ok, why = self:refuse()
  if not ok then
    return false, why
  end
  local s = self.st
  if on then
    if s.phase == "outage" then
      return true, "already in an outage"
    end
    if s.phase == "holding" then
      self.deps.cancel(TIMER_HOLD)
      s.phase = "outage"
      s.power_back_at = nil
      s.flaps = s.flaps + 1
      self:emit("flap", { flaps = s.flaps })
      self:armTick()
      self:evaluate()
      return true
    end
    if s.phase == "restoring" then
      self.deps.cancel(TIMER_RESTORE)
      s.queue = {}
      s.phase = "outage"
      s.power_back_at = nil
      s.flaps = s.flaps + 1
      self:emit("flap", { flaps = s.flaps, during = "restore" })
      self:armTick()
      self:evaluate()
      return true
    end
    s.phase = "outage"
    s.outage_since = self:now()
    s.power_back_at = nil
    s.resheds = {}
    self:emit("outage_started", { source = source })
    self:armTick()
    self:evaluate()
    return true
  end
  if s.phase ~= "outage" then
    return true, "no outage in progress"
  end
  self.deps.cancel(TIMER_TICK)
  s.phase = "holding"
  s.power_back_at = self:now()
  self:emit("restore_delayed", { hold_s = self.cfg.stable_hold_s, reason = "power back" })
  if self.cfg.stable_hold_s <= 0 then
    self:beginRestore()
  else
    self.deps.schedule(TIMER_HOLD, self.cfg.stable_hold_s * 1000, function()
      self:onHoldElapsed()
    end)
  end
  return true
end

function Engine:onHoldElapsed()
  if self.st.phase == "holding" then
    self:beginRestore()
  end
end

-- ── restoring ──

function Engine:beginRestore()
  local s = self.st
  s.phase = "restoring"
  s.queue = {}
  for t = 3, 1, -1 do
    if s.shed_tiers[t] then
      s.queue[#s.queue + 1] = t
    end
  end
  self:stepRestore()
end

function Engine:restoreLoad(slot, rec)
  if rec.skip then
    self:emit("load_restored", { slot = slot, skipped = rec.skip })
    return
  end
  local cmds = M.restoreCommands(rec.load, rec.prior)
  if not cmds then
    self:emit("load_restored", { slot = slot, skipped = "nothing to restore" })
    return
  end
  for _, c in ipairs(cmds) do
    if self.deps.send(rec.load.device_id, c[1], c[2]) == false then
      self:emit("load_error", { slot = slot, action = "restore", command = c[1] })
    end
  end
  self:emit("load_restored", { slot = slot })
end

function Engine:stepRestore()
  local s = self.st
  while #s.queue > 0 do
    local t = table.remove(s.queue, 1)
    local slots = {}
    for slot, rec in pairs(s.shed) do
      if rec.load.tier == t then
        slots[#slots + 1] = slot
      end
    end
    table.sort(slots)
    for _, slot in ipairs(slots) do
      self:restoreLoad(slot, s.shed[slot])
      s.shed[slot] = nil
      s.last_cmd[slot] = self:now()
    end
    s.shed_tiers[t] = nil
    self:emit("tier_restored", { tier = t, count = #slots })
    if #s.queue > 0 and self.cfg.tier_delay_s > 0 then
      self.deps.schedule(TIMER_RESTORE, self.cfg.tier_delay_s * 1000, function()
        if self.st.phase == "restoring" then
          self:stepRestore()
        end
      end)
      return
    end
  end
  -- Anything shed with no tier flag (manual single-tier shed) is back too.
  local since = s.outage_since
  s.phase = "normal"
  s.outage_since = nil
  s.power_back_at = nil
  s.shed_tiers = {}
  s.shed = {}
  s.resheds = {}
  self.draining = false
  self:emit("restored", { duration_s = since and math.floor(self:now() - since) or 0 })
end

function Engine:anyShed()
  return next(self.st.shed) ~= nil or next(self.st.shed_tiers) ~= nil
end

-- ── public: commands ──

function Engine:shedTierNow(t)
  local ok, why = self:refuse()
  if not ok then
    return false, why
  end
  t = tonumber(t)
  if t == nil or t < 1 or t > 3 or t ~= math.floor(t) then
    return false, "tier must be 1, 2 or 3"
  end
  self:shedTier(t, "manual")
  return true
end

function Engine:restoreAll()
  local ok, why = self:refuse()
  if not ok then
    return false, why
  end
  if not self:anyShed() and self.st.phase == "normal" then
    return true, "nothing is shed"
  end
  self:cancelAll()
  self:beginRestore()
  return true
end

--- Licence halt: put everything back, then go read-only. A halt must never
--- leave a load shed.
function Engine:setReadOnly(flag)
  if flag and not self.readOnly then
    self.draining = true
    self:cancelAll()
    if self:anyShed() or self.st.phase ~= "normal" then
      self:beginRestore()
    end
    self.readOnly = true
    self:emit("read_only", { value = true })
  elseif not flag and self.readOnly then
    self.readOnly = false
    self.draining = false
    self:emit("read_only", { value = false })
  end
end

--- A load's own state changed (feedback). Re-sheds it when the homeowner
--- turned it back on mid-outage and re-shed is enabled. Capped per outage.
function Engine:observe(slot, isOn)
  local s = self.st
  local rec = s.shed[slot]
  if self.readOnly or not self.cfg.reshed or rec == nil or rec.skip or s.phase ~= "outage" then
    return false
  end
  if not isOn then
    return false
  end
  if self:now() - (s.last_cmd[slot] or 0) < M.LIMITS.reshed_grace_s then
    return false
  end
  s.resheds[slot] = (s.resheds[slot] or 0) + 1
  if s.resheds[slot] > M.LIMITS.resheds_per_outage then
    return false
  end
  local cmds = M.shedCommands(rec.load, {})
  if cmds then
    for _, c in ipairs(cmds) do
      self.deps.send(rec.load.device_id, c[1], c[2])
    end
  end
  s.last_cmd[slot] = self:now()
  self:emit("reshed", { slot = slot, count = s.resheds[slot] })
  return true
end

-- ── views ──

function Engine:highestShedTier()
  local h = 0
  for t = 1, 3 do
    if self.st.shed_tiers[t] then
      h = t
    end
  end
  return h
end

function Engine:isTierShed(t)
  return self.st.shed_tiers[t] == true
end

function Engine:outageActive()
  return self.st.phase == "outage"
end

local PHASE_LABEL = {
  normal = "Normal",
  outage = "Outage",
  holding = "Power back, waiting to restore",
  restoring = "Restoring",
}

function Engine:phaseLabel()
  return PHASE_LABEL[self.st.phase] or self.st.phase
end

function Engine:shedCount()
  local n = 0
  for _, rec in pairs(self.st.shed) do
    if not rec.skip then
      n = n + 1
    end
  end
  return n
end

--- Test mode: what a full outage would do, nothing sent, nothing changed.
function Engine:dryRun()
  local lines = {}
  for t = 1, 3 do
    local when = t == 1 and "at once" or string.format("battery <= %d%% or %d min without battery data", self.cfg["tier" .. t .. "_pct"], self.cfg["tier" .. t .. "_nodata_min"])
    for _, l in ipairs(self.loads) do
      if l.tier == t then
        lines[#lines + 1] = {
          phase = "shed",
          tier = t,
          slot = l.slot,
          text = string.format("tier %d (%s): would shed load %d (%s, device %d)", t, when, l.slot, l.kind, l.device_id),
        }
      end
    end
  end
  for t = 3, 1, -1 do
    for _, l in ipairs(self.loads) do
      if l.tier == t then
        lines[#lines + 1] = {
          phase = "restore",
          tier = t,
          slot = l.slot,
          text = string.format("tier %d: would restore load %d after power holds %ds, tiers %ds apart", t, l.slot, self.cfg.stable_hold_s, self.cfg.tier_delay_s),
        }
      end
    end
  end
  return lines
end

function Engine:snapshot()
  local s = self.st
  local shed = {}
  for slot, rec in pairs(s.shed) do
    shed[#shed + 1] = { slot = slot, tier = rec.load.tier, skip = rec.skip, failed = rec.failed }
  end
  table.sort(shed, function(a, b)
    return a.slot < b.slot
  end)
  return {
    phase = s.phase,
    label = self:phaseLabel(),
    outage_since = s.outage_since,
    battery = s.battery,
    battery_at = s.battery_at,
    shed = shed,
    flaps = s.flaps,
    queue = deepcopy(s.queue),
    read_only = self.readOnly,
  }
end

-- ─── Persistence ────────────────────────────────────────────────────────────

function Engine:serialize()
  local s = self.st
  -- Arrays only: a JSON round trip must not meet sparse numeric keys.
  local tiers, shed, resheds = {}, {}, {}
  for t = 1, 3 do
    if s.shed_tiers[t] then
      tiers[#tiers + 1] = t
    end
  end
  for _, rec in pairs(s.shed) do
    shed[#shed + 1] = deepcopy(rec)
  end
  table.sort(shed, function(a, b)
    return a.load.slot < b.load.slot
  end)
  for slot, n in pairs(s.resheds) do
    resheds[#resheds + 1] = { slot = slot, n = n }
  end
  return {
    v = M.LIMITS.state_version,
    phase = s.phase,
    outage_since = s.outage_since,
    power_back_at = s.power_back_at,
    shed_tiers = tiers,
    shed = shed,
    queue = deepcopy(s.queue),
    battery = s.battery,
    battery_at = s.battery_at,
    resheds = resheds,
    flaps = s.flaps,
  }
end

--- Rebuilds state after a restart and re-arms whatever was running.
function Engine:restore(t)
  if type(t) ~= "table" or t.v ~= M.LIMITS.state_version then
    return false, "unrecognised state"
  end
  local s = fresh()
  local phase = t.phase
  if phase ~= "normal" and phase ~= "outage" and phase ~= "holding" and phase ~= "restoring" then
    return false, "bad phase"
  end
  s.phase = phase
  s.outage_since = tonumber(t.outage_since)
  s.power_back_at = tonumber(t.power_back_at)
  s.battery = tonumber(t.battery)
  s.battery_at = tonumber(t.battery_at)
  s.flaps = tonumber(t.flaps) or 0
  for _, v in ipairs(t.shed_tiers or {}) do
    local n = tonumber(v)
    if n then
      s.shed_tiers[n] = true
    end
  end
  for _, rec in ipairs(t.shed or {}) do
    if type(rec) == "table" and type(rec.load) == "table" then
      rec.load.slot = tonumber(rec.load.slot)
      rec.load.device_id = tonumber(rec.load.device_id)
      rec.load.tier = tonumber(rec.load.tier)
      rec.prior = type(rec.prior) == "table" and rec.prior or {}
      if rec.load.slot then
        s.shed[rec.load.slot] = rec
      end
    end
  end
  for _, v in ipairs(t.queue or {}) do
    s.queue[#s.queue + 1] = tonumber(v)
  end
  for _, r in ipairs(t.resheds or {}) do
    if type(r) == "table" and tonumber(r.slot) then
      s.resheds[tonumber(r.slot)] = tonumber(r.n) or 0
    end
  end
  self:cancelAll()
  self.st = s
  if phase == "outage" then
    self:armTick()
  elseif phase == "holding" then
    local left = (s.power_back_at or self:now()) + self.cfg.stable_hold_s - self:now()
    self.deps.schedule(TIMER_HOLD, math.max(1, left) * 1000, function()
      self:onHoldElapsed()
    end)
  elseif phase == "restoring" then
    self.deps.schedule(TIMER_RESTORE, 1000, function()
      if self.st.phase == "restoring" then
        self:stepRestore()
      end
    end)
  end
  return true
end

function Engine:stop()
  self:cancelAll()
end

return M
