--- Logic Blocks — the block runtime (pure: injected clock, timers, outputs).
---
--- A block is a named rule in a numbered slot. The dealer configures it in
--- Composer, programming feeds it with BLOCK_* commands (or it reads a
--- device variable directly), and it answers with per-slot events and
--- variables. The driver evaluates the rule and says what it decided; what
--- the house does about it is Composer programming.
---
--- The six classic block types (cooldown, quiet period, timer, once per
--- day, flag, counter) run on a PRIVATE instance of logic/engine.lua, the
--- same primitives the free-form keys use, with its own timers and its own
--- persisted document. A block and a free-form key are therefore never the
--- same thing: a block named "Good Night" cannot adopt, read or disturb the
--- legacy key "good_night". The four extensions (conditions, threshold,
--- stable filter, selector) are implemented here.
---
--- What a programmer and a dealer rely on:
---   • IDENTITY. A block has an immutable id and a slot. Its Composer ids are
---     a function of the slot. Renaming keeps both. A retired slot is never
---     handed to a new block unless the dealer releases it.
---   • ATOMIC CONFIGURATION. apply() takes a whole validated definition or
---     nothing. impact() says, before anything changes, what happens to a
---     countdown that is running.
---   • NO INVENTED VALUES. An input that cannot be read is UNKNOWN. It is
---     never false and never zero. Conditions use three-valued logic; a
---     result that depends on an unknown input is unknown, and the block
---     says so (Faulted) instead of guessing.
---   • STARTUP IS SILENT. The value a variable listener reports the moment it
---     is registered, and anything restored from before a restart, sets
---     state and fires nothing.
---   • UNCHANGED IS NOT A CHANGE. Setting a flag that is set, or a counter to
---     its own value, fires nothing.
---   • VARIABLES FIRST. A slot's variables are written before its event
---     fires, so programming on the event reads the values of that event.
---   • ORDER. An input that arrives while another is being worked on (a
---     command sent by programming that an event started) is queued and
---     handled next, in arrival order.
---   • RUNAWAY. A block fed faster than any house does it (LIMITS) is
---     ISOLATED: it stops, says why, fires Faulted once and stays stopped
---     until the dealer resumes it. Other blocks keep working. Ordinary
---     input is never dropped by a rate limit.
---   • READ-ONLY. When the licence halts the pack every input is refused
---     with "read-only". Running countdowns are held, not fired; when the
---     pack is restored each follows its own After Restart rule.
---
--- deps = {
---   now      = fn(): seconds (wall clock, fractions welcome)
---   schedule = fn(id, ms, fn), cancel = fn(id)
---   localDay = fn(seconds): "YYYY-MM-DD"
---   emit     = fn(slot, kind, record)        -- fire the slot's event
---   outputs  = fn(slot, out)                 -- write the slot's variables
---   watch    = fn(deviceId, variableId): ok, why   -- start a listener
---   unwatch  = fn(deviceId, variableId)
---   newId    = fn(): string                  -- a fresh block identity
---   changed  = fn()                          -- state worth saving changed
---   refused  = fn(slot, what, why)           -- an input was refused
---   origin   = "live" | "sim"
---   selfDevice = number | nil                -- this driver's device id
--- }

local Engine = require("logic.engine")
local Defs = require("logic.blockdefs")

local M = {}

M.SCHEMA = "logic_blocks"
M.VERSION = 1

M.LIMITS = {
  history = 200, -- records kept in memory
  history_saved = 50, -- records written with the state
  queue = 64, -- inputs waiting while one is being handled
  drain = 32, -- queued inputs handled per callback
  window_s = 10, -- runaway window
  inputs_per_window = 300, -- inputs to ONE block inside the window
  raw = 120, -- characters of a source value kept
  reason = 400,
}

--- Upgrades between document versions: MIGRATIONS[n] turns a version n
--- document into version n + 1. Empty today; restore() walks it.
M.MIGRATIONS = {}

local Blocks = {}
Blocks.__index = Blocks

local function copy(value, depth)
  if type(value) ~= "table" then
    return value
  end
  depth = depth or 0
  if depth > 8 then
    return nil
  end
  local out = {}
  for k, v in pairs(value) do
    out[k] = copy(v, depth + 1)
  end
  return out
end
M.copy = copy

--- A stable text form of a table, for "did the rule change?".
local function fingerprint(value)
  if type(value) ~= "table" then
    return tostring(value)
  end
  local keys = {}
  for k in pairs(value) do
    keys[#keys + 1] = tostring(k)
  end
  table.sort(keys)
  local parts = {}
  for _, k in ipairs(keys) do
    local v = value[k]
    if v == nil then
      v = value[tonumber(k)]
    end
    parts[#parts + 1] = k .. "=" .. fingerprint(v)
  end
  return "{" .. table.concat(parts, ";") .. "}"
end

local function key(slot)
  return "s" .. slot
end

local function slotOf(k)
  return tonumber(tostring(k):match("^s(%d+)$"))
end

local function clip(text, max)
  text = tostring(text or "")
  if #text > max then
    return text:sub(1, max - 1) .. "…"
  end
  return text
end

function M.new(deps)
  local self = setmetatable({}, Blocks)
  self.deps = deps
  self.origin = deps.origin or "live"
  self.blocks = {} -- slot -> definition
  self.retired = {} -- slot -> { id, name, type, retired_at }
  self.unreadable = {} -- slot -> { raw, why }
  self.rt = {} -- slot -> runtime
  self.watching = {} -- "dev:var" -> { { slot, index } ... }
  self.history = {}
  self.queue = {}
  self.depth = 0
  self.seq = 0
  self.runId = 0
  self.revision = 0
  self.readOnly = false
  self.restoreFailed = nil -- { why, at } when the stored document could not be used
  self.recovery = { at = nil, notes = {} }
  self.stats = { inputs = 0, refused = 0, emitted = 0, queued_max = 0, isolations = 0, clock_jumps = 0 }
  self.lastTick = nil
  self.eng = Engine.new({
    now = deps.now,
    schedule = function(id, ms, fn)
      deps.schedule("lb:" .. id, ms, function()
        self:_enter()
        local ok, err = pcall(fn)
        self:_leave()
        if not ok then
          error(err, 0)
        end
      end)
    end,
    cancel = function(id)
      deps.cancel("lb:" .. id)
    end,
    emit = function(kind, fields)
      self:_onEngine(kind, fields)
    end,
    localDay = deps.localDay,
  })
  self._sync = nil
  return self
end

-- ── Small helpers ───────────────────────────────────────────────────────────

function Blocks:_now()
  return self.deps.now()
end

function Blocks:_changed()
  if self.deps.changed ~= nil and self.restoreFailed == nil then
    self.deps.changed()
  end
end

function Blocks:_schedule(id, ms, fn)
  self.deps.schedule(id, ms, function()
    self:_enter()
    local ok, err = pcall(fn)
    self:_leave()
    if not ok then
      error(err, 0)
    end
  end)
end

local function newRuntime()
  return {
    src = {},
    counts = { accepted = 0, suppressed = 0, refused = 0, emitted = 0 },
    win = { start = 0, count = 0 },
    last = false, -- the last VALID true/false output
    valid = true,
    suppressed = 0,
    suppressed_total = 0,
    burst = 0,
  }
end

--- The typed inputs of a block, by index.
local function inputAt(block, index)
  for _, input in ipairs(block.inputs or {}) do
    if input.index == index then
      return input
    end
  end
  return nil
end

local function trueWhen(input)
  if input ~= nil and input.true_when ~= nil then
    return Defs.wordList(input.true_when)
  end
  return nil
end

-- ── History ─────────────────────────────────────────────────────────────────

--- Appends a decision record. `rec` = { input, decision, reason, fire = {kinds},
--- accepted = bool, suppressed = bool, cause = runId }.
--- Order inside: variables are written, THEN events fire, THEN the record is
--- kept, so programming on the event reads this decision's values.
function Blocks:_decide(slot, rec)
  local block, rt = self.blocks[slot], self.rt[slot]
  local now = self:_now()
  self.seq = self.seq + 1
  local entry = {
    seq = self.seq,
    at = now,
    slot = slot,
    block_id = block and block.id or nil,
    name = block and block.name or Defs.slotLabel(slot),
    type = block and block.type or nil,
    origin = rec.origin or self.origin,
    run = rec.run or self.currentRun,
    cause = rec.cause,
    input = rec.input,
    decision = rec.decision,
    reason = clip(rec.reason or "", M.LIMITS.reason),
    events = {},
    confirmed = nil,
  }
  if rt ~= nil then
    if rec.accepted then
      rt.counts.accepted = rt.counts.accepted + 1
      rt.last_accepted = { at = now, text = entry.reason, decision = entry.decision, seq = entry.seq }
    end
    if rec.suppressed then
      rt.counts.suppressed = rt.counts.suppressed + 1
      rt.last_suppressed = { at = now, text = entry.reason, decision = entry.decision, seq = entry.seq }
    end
    if rec.refused then
      rt.counts.refused = rt.counts.refused + 1
      rt.last_refused = { at = now, text = entry.reason, seq = entry.seq }
    end
  end
  self:_refresh(slot)
  local action = false
  for _, kind in ipairs(rec.fire or {}) do
    entry.events[#entry.events + 1] = kind
    if kind == "passed" or kind == "expired" or kind == "became_true" then
      action = true
    end
  end
  self.history[#self.history + 1] = entry
  while #self.history > M.LIMITS.history do
    table.remove(self.history, 1)
  end
  if block ~= nil and block.feedback ~= nil then
    entry.confirmed = action and "pending" or nil
  elseif #entry.events > 0 then
    entry.confirmed = "not_monitored"
  end
  for _, kind in ipairs(entry.events) do
    self.stats.emitted = self.stats.emitted + 1
    if rt ~= nil then
      rt.counts.emitted = rt.counts.emitted + 1
    end
    self.deps.emit(slot, kind, entry)
  end
  if action and block ~= nil and block.feedback ~= nil then
    self:_openFeedback(slot, entry)
  end
  self:_changed()
  return entry
end

function Blocks:_refuse(slot, what, why)
  self.stats.refused = self.stats.refused + 1
  self:_decide(slot, { input = what, decision = "refused", reason = why, refused = true })
  if self.deps.refused ~= nil then
    self.deps.refused(slot, what, why)
  end
  return false, why
end

--- A note that is not about an input: configuration, recovery, licence.
function Blocks:_note(slot, decision, reason, extra)
  local rec = { input = "(driver)", decision = decision, reason = reason }
  for k, v in pairs(extra or {}) do
    rec[k] = v
  end
  return self:_decide(slot, rec)
end

-- ── Outputs ─────────────────────────────────────────────────────────────────

--- The four values a slot shows Composer: active (true/false), valid
--- (true/false), value (number), state (text). Live: computed from the
--- runtime every time, so a conditional never reads a stale variable.
function Blocks:outputs(slot)
  local block, rt = self.blocks[slot], self.rt[slot]
  if self.unreadable[slot] ~= nil then
    return { active = false, valid = false, value = 0, state = "unreadable" }
  end
  if block == nil then
    return { active = false, valid = false, value = 0, state = self.retired[slot] and "retired" or "empty" }
  end
  if rt.isolated ~= nil then
    return { active = false, valid = false, value = 0, state = "isolated" }
  end
  if not block.enabled then
    return { active = false, valid = false, value = 0, state = "disabled" }
  end
  local k, eng, now = key(slot), self.eng, self:_now()
  local t = block.type
  if t == "cooldown" then
    local last = eng:throttleLastAt(k)
    local cooling = last ~= nil and (now - last) * 1000 < block.settings.interval_ms and now >= last
    return { active = cooling, valid = true, value = rt.suppressed, state = cooling and "cooling" or "ready" }
  elseif t == "quiet" then
    local pending = eng:debouncePendingFor(k)
    return { active = pending, valid = true, value = rt.burst, state = pending and "waiting" or "idle" }
  elseif t == "timer" then
    local info = eng:timerInfo(k)
    if rt.held ~= nil then
      return { active = false, valid = true, value = 0, state = "held" }
    end
    return {
      active = info ~= nil,
      valid = true,
      value = info ~= nil and math.max(0, math.ceil(info.expires_at - now)) or 0,
      state = info ~= nil and "running" or "idle",
    }
  elseif t == "once" then
    local done = eng:onceDoneToday(k)
    return { active = done, valid = true, value = rt.suppressed, state = done and "done_today" or "ready" }
  elseif t == "flag" then
    local on = eng:flag(k)
    return { active = on, valid = true, value = on and 1 or 0, state = on and "on" or "off" }
  elseif t == "counter" then
    local count = eng:counter(k)
    local s = block.settings
    if s.threshold ~= nil then
      local reached = Defs.compare(s.comparison, count, s.threshold)
      return { active = reached, valid = true, value = count, state = reached and "reached" or "below" }
    end
    return { active = false, valid = true, value = count, state = "counting" }
  elseif t == "conditions" then
    local trues = 0
    for _, input in ipairs(block.inputs or {}) do
      if self:_sourceBool(slot, input) == true then
        trues = trues + 1
      end
    end
    if not rt.valid then
      return { active = false, valid = false, value = trues, state = "unknown" }
    end
    return { active = rt.last == true, valid = true, value = trues, state = rt.last and "true" or "false" }
  elseif t == "threshold" then
    if not rt.valid then
      return { active = false, valid = false, value = rt.reading or 0, state = "unknown" }
    end
    return { active = rt.last == true, valid = true, value = rt.reading or 0, state = rt.last and "active" or "clear" }
  elseif t == "stable" then
    if not rt.valid then
      return { active = false, valid = false, value = 0, state = "unknown" }
    end
    local on = rt.stable ~= nil and Defs.boolean(rt.stable, trueWhen(inputAt(block, 1))) == true
    return { active = on, valid = true, value = on and 1 or 0, state = rt.stable or "waiting" }
  elseif t == "selector" then
    local index = 0
    for i, name in ipairs(block.settings.states) do
      if name == rt.state then
        index = i
      end
    end
    return { active = rt.state ~= block.settings.initial, valid = true, value = index, state = rt.state or "" }
  end
  return { active = false, valid = false, value = 0, state = "unknown" }
end

--- Writes a slot's variables when they differ from what was last written.
function Blocks:_refresh(slot)
  if self.deps.outputs == nil then
    return
  end
  local out = self:outputs(slot)
  local rt = self.rt[slot]
  local pushed = rt and rt.pushed or self._emptyPushed and self._emptyPushed[slot]
  if
    pushed ~= nil
    and pushed.active == out.active
    and pushed.valid == out.valid
    and pushed.value == out.value
    and pushed.state == out.state
  then
    return
  end
  if rt ~= nil then
    rt.pushed = out
  else
    self._emptyPushed = self._emptyPushed or {}
    self._emptyPushed[slot] = out
  end
  self.deps.outputs(slot, out)
end

function Blocks:refreshAll()
  for slot = 1, Defs.SLOTS do
    self:_refresh(slot)
  end
end

-- ── Sources ─────────────────────────────────────────────────────────────────

local function watchKey(deviceId, variableId)
  return tostring(deviceId) .. ":" .. tostring(variableId)
end

function Blocks:_source(slot, index)
  local rt = self.rt[slot]
  rt.src[index] = rt.src[index] or { status = "never" }
  return rt.src[index]
end

--- true / false / nil (unknown) for a conditions input.
function Blocks:_sourceBool(slot, input)
  local src = self.rt[slot].src[input.index]
  if src == nil or src.status ~= "ok" then
    return nil
  end
  return Defs.boolean(src.raw, trueWhen(input))
end

function Blocks:_subscribe(slot, index, deviceId, variableId)
  local wk = watchKey(deviceId, variableId)
  local subs = self.watching[wk]
  local src = index == "fb" and self.rt[slot].fbsrc or self:_source(slot, index)
  src.awaiting = true
  if subs ~= nil then
    subs[#subs + 1] = { slot = slot, index = index }
    -- The listener already exists, so Director will not send its opening
    -- value again. Another subscriber's last value is the best evidence.
    if subs.last ~= nil then
      self:_observe(slot, index, subs.last, { initial = true })
    end
    return true
  end
  self.watching[wk] = { { slot = slot, index = index }, device = deviceId, variable = variableId }
  local ok, why = true, nil
  if self.deps.watch ~= nil then
    ok, why = self.deps.watch(deviceId, variableId)
  end
  if not ok then
    src.status, src.why, src.awaiting = "unavailable", tostring(why or "cannot be watched"), nil
    self.watching[wk].failed = src.why
  end
  return ok, why
end

function Blocks:_unsubscribe(slot)
  for wk, subs in pairs(self.watching) do
    for i = #subs, 1, -1 do
      if subs[i].slot == slot then
        table.remove(subs, i)
      end
    end
    if #subs == 0 then
      if self.deps.unwatch ~= nil then
        self.deps.unwatch(subs.device, subs.variable)
      end
      self.watching[wk] = nil
    end
  end
end

--- Starts the listeners a block's definition asks for.
function Blocks:_watch(slot)
  local block, rt = self.blocks[slot], self.rt[slot]
  for _, input in ipairs(block.inputs or {}) do
    if input.device_id ~= nil then
      rt.src[input.index] = { status = "never" }
      self:_subscribe(slot, input.index, input.device_id, input.variable_id)
    end
  end
  if block.feedback ~= nil then
    rt.fbsrc = { status = "never" }
    self:_subscribe(slot, "fb", block.feedback.device_id, block.feedback.variable_id)
  end
end

--- Director reports a watched variable. The driver calls this for every
--- OnWatchedVariableChanged; `value` nil means the variable went away.
function Blocks:variable(deviceId, variableId, value)
  local subs = self.watching[watchKey(deviceId, variableId)]
  if subs == nil then
    return false
  end
  local first = subs.last == nil and subs.seen ~= true
  subs.seen = true
  subs.last = value
  local list = {}
  for i, sub in ipairs(subs) do
    list[i] = sub
  end
  for _, sub in ipairs(list) do
    self:_submit({ kind = "observe", slot = sub.slot, index = sub.index, value = value, initial = first })
  end
  return true
end

--- The driver could not find a watched device or variable any more.
function Blocks:variableLost(deviceId, variableId, why)
  local subs = self.watching[watchKey(deviceId, variableId)]
  if subs == nil then
    return
  end
  subs.failed = tostring(why or "no longer in the project")
  subs.last, subs.seen = nil, nil
  local list = {}
  for i, sub in ipairs(subs) do
    list[i] = sub
  end
  for _, sub in ipairs(list) do
    self:_submit({ kind = "observe", slot = sub.slot, index = sub.index, value = nil, why = subs.failed })
  end
end

--- Re-checks every watched variable with `exists(deviceId, variableId) ->
--- ok, why`. One that is gone is reported lost (the block's result becomes
--- unknown); one that is back is watched again, and the value Director then
--- reports is taken silently, like any opening value.
function Blocks:checkWatches(exists)
  local list = {}
  for _, subs in pairs(self.watching) do
    list[#list + 1] = subs
  end
  for _, subs in ipairs(list) do
    local ok, why = exists(subs.device, subs.variable)
    if not ok and subs.failed == nil then
      self:variableLost(subs.device, subs.variable, why)
    elseif ok and subs.failed ~= nil then
      subs.failed, subs.last, subs.seen = nil, nil, nil
      for _, sub in ipairs(subs) do
        local rt = self.rt[sub.slot]
        local src = rt and (sub.index == "fb" and rt.fbsrc or rt.src[sub.index])
        if src ~= nil then
          src.awaiting = true
        end
      end
      if self.deps.watch ~= nil then
        local watched, reason = self.deps.watch(subs.device, subs.variable)
        if not watched then
          subs.failed = tostring(reason or "cannot be watched")
        end
      end
    end
  end
end

function Blocks:_observe(slot, index, value, info)
  local block, rt = self.blocks[slot], self.rt[slot]
  if block == nil or rt == nil then
    return
  end
  info = info or {}
  if index == "fb" then
    local src = rt.fbsrc
    if src == nil then
      return
    end
    local initial = info.initial == true or src.awaiting == true
    src.awaiting = nil
    src.status = value == nil and "unavailable" or "ok"
    src.raw = value ~= nil and clip(tostring(value), M.LIMITS.raw) or nil
    src.at = self:_now()
    src.why = info.why
    if not initial then
      self:_feedbackSeen(slot)
    end
    return
  end
  local src = self:_source(slot, index)
  local initial = info.initial == true or src.awaiting == true
  src.awaiting = nil
  src.at = self:_now()
  src.via = "variable"
  if value == nil then
    src.status, src.raw, src.why = "unavailable", nil, tostring(info.why or "the variable cannot be read")
  else
    src.status, src.raw, src.why = "ok", clip(tostring(value), M.LIMITS.raw), nil
  end
  if not block.enabled or rt.isolated ~= nil then
    return
  end
  local label = inputAt(block, index)
  self.currentRun = self:_nextRun()
  self:_evaluate(slot, {
    silent = initial or self.readOnly,
    input = string.format("%s = %s", label and label.label or ("Input " .. index), tostring(src.raw or "unavailable")),
    opening = initial,
  })
end

-- ── Evaluation of the input-driven types ────────────────────────────────────

--- Applies a three-valued result to a block: true, false or nil (unknown).
--- `silent` sets state and fires nothing (startup, restore, read-only).
function Blocks:_setResult(slot, result, ctx, why)
  local rt = self.rt[slot]
  ctx = ctx or {}
  if result == nil then
    if rt.valid then
      rt.valid = false
      rt.fault = { at = self:_now(), text = why or "an input cannot be read" }
      if ctx.silent then
        self:_note(slot, "baseline", "No result yet: " .. rt.fault.text)
      else
        self:_decide(slot, {
          input = ctx.input,
          decision = "faulted",
          reason = "No result: " .. rt.fault.text .. ". It is unknown, not false.",
          fire = { "faulted" },
          accepted = true,
        })
      end
    else
      rt.fault = { at = rt.fault and rt.fault.at or self:_now(), text = why or "an input cannot be read" }
      self:_refresh(slot)
    end
    return
  end
  local wasValid = rt.valid
  rt.valid = true
  rt.fault = nil
  if result == rt.last then
    if not wasValid then
      self:_decide(slot, {
        input = ctx.input or "(driver)",
        decision = ctx.silent and "baseline" or "readable",
        reason = (why or ("The result is " .. (result and "true" or "false") .. "."))
          .. " It can be read now; the state did not change, so nothing fired.",
        accepted = ctx.input ~= nil and not ctx.silent,
      })
    elseif ctx.input ~= nil and not ctx.silent and ctx.quietIfSame ~= true then
      self:_decide(slot, {
        input = ctx.input,
        decision = "unchanged",
        reason = why or ("The result is still " .. (result and "true" or "false") .. "."),
        accepted = true,
      })
    else
      self:_refresh(slot)
    end
    return
  end
  rt.last = result
  if ctx.silent then
    self:_note(
      slot,
      "baseline",
      (ctx.opening and "Opening value read: " or "State set without firing: ")
        .. "the result is "
        .. (result and "true" or "false")
        .. "."
    )
    return
  end
  self:_decide(slot, {
    input = ctx.input,
    decision = result and "became_true" or "became_false",
    reason = why or ("The result became " .. (result and "true" or "false") .. "."),
    fire = { result and "became_true" or "became_false" },
    accepted = true,
  })
end

--- Three-valued ALL / ANY over the configured inputs. Returns the result
--- (true / false / nil) and a sentence naming what decided it.
function Blocks:_conditions(slot)
  local block = self.blocks[slot]
  local any = block.settings.mode == "any"
  local trues, falses, unknowns = {}, {}, {}
  for _, input in ipairs(block.inputs or {}) do
    local b = self:_sourceBool(slot, input)
    if b == true then
      trues[#trues + 1] = input.label
    elseif b == false then
      falses[#falses + 1] = input.label
    else
      unknowns[#unknowns + 1] = input.label
    end
  end
  if any then
    if #trues > 0 then
      return true, table.concat(trues, ", ") .. (#trues == 1 and " is true" or " are true")
    elseif #unknowns > 0 then
      return nil, "cannot read " .. table.concat(unknowns, ", ")
    end
    return false, "none of the inputs is true"
  end
  if #falses > 0 then
    return false, table.concat(falses, ", ") .. (#falses == 1 and " is false" or " are false")
  elseif #unknowns > 0 then
    return nil, "cannot read " .. table.concat(unknowns, ", ")
  end
  return true, "every input is true"
end

function Blocks:_evaluate(slot, ctx)
  local block, rt = self.blocks[slot], self.rt[slot]
  ctx = ctx or {}
  local t = block.type
  if t == "conditions" then
    local result, why = self:_conditions(slot)
    if block.settings.evaluation == "gate" then
      -- A gate fires nothing by itself; it only keeps its display current.
      rt.valid = result ~= nil
      rt.last = result == true
      rt.fault = result == nil and { at = self:_now(), text = why } or nil
      if ctx.input ~= nil and not ctx.silent then
        self:_decide(slot, {
          input = ctx.input,
          decision = "unchanged",
          reason = "Input noted (" .. why .. "). A gate acts only on BLOCK_TRIGGER.",
          accepted = true,
        })
      else
        self:_refresh(slot)
      end
      return
    end
    ctx.quietIfSame = false
    self:_setResult(slot, result, ctx, result == nil and why or ("Result: " .. why .. "."))
  elseif t == "threshold" then
    local src = rt.src[1]
    local s = block.settings
    local units = s.units ~= "" and (" " .. s.units) or ""
    if src == nil or src.status ~= "ok" then
      self:_setResult(slot, nil, ctx, (src and src.why) or "no reading yet")
      return
    end
    local x = Defs.number(src.raw)
    if x == nil then
      src.status, src.why = "invalid", string.format('"%s" is not a number', tostring(src.raw))
      self:_setResult(slot, nil, ctx, src.why)
      return
    end
    rt.reading = x
    local result = rt.last
    local why
    if x > s.upper then
      result = true
      why = string.format("Reading %s%s is above the upper threshold %s%s.", tostring(x), units, tostring(s.upper), units)
    elseif x < s.lower then
      result = false
      why = string.format("Reading %s%s is below the lower threshold %s%s.", tostring(x), units, tostring(s.lower), units)
    else
      why = string.format(
        "Reading %s%s is between %s and %s: it stays %s.",
        tostring(x),
        units,
        tostring(s.lower),
        tostring(s.upper),
        rt.last and "active" or "clear"
      )
    end
    self:_setResult(slot, result, ctx, why)
  elseif t == "stable" then
    self:_stable(slot, ctx)
  end
end

function Blocks:_stable(slot, ctx)
  local block, rt = self.blocks[slot], self.rt[slot]
  local src = rt.src[1]
  local id = "lb:st:" .. slot
  local function drop()
    if rt.pending ~= nil then
      rt.pending, rt.pending_deadline = nil, nil
      self.deps.cancel(id)
      return true
    end
    return false
  end
  if src == nil or src.status ~= "ok" then
    drop()
    if rt.valid then
      rt.valid = false
      rt.fault = { at = self:_now(), text = (src and src.why) or "no value yet" }
      if ctx.silent then
        self:_note(slot, "baseline", "No value yet: " .. rt.fault.text)
      else
        self:_decide(slot, {
          input = ctx.input,
          decision = "faulted",
          reason = "The source cannot be read (" .. rt.fault.text .. "). A pending change was dropped.",
          fire = { "faulted" },
          accepted = true,
        })
      end
    end
    return
  end
  local value = Defs.trim(src.raw):lower()
  local wasValid = rt.valid
  rt.valid, rt.fault = true, nil
  if rt.stable == nil or ctx.silent then
    drop()
    local had = rt.stable
    rt.stable = value
    if had ~= value or not wasValid then
      self:_note(slot, "baseline", string.format('Starting state "%s" taken as it is; nothing fired.', value))
    else
      self:_refresh(slot)
    end
    return
  end
  if value == rt.stable then
    local dropped = drop()
    self:_decide(slot, {
      input = ctx.input,
      decision = dropped and "cancelled" or "unchanged",
      reason = dropped
          and string.format('The source went back to "%s" before the change had held. The pending change was dropped.', value)
        or string.format('The source is still "%s".', value),
      accepted = true,
      suppressed = dropped,
    })
    return
  end
  if rt.pending == value then
    self:_refresh(slot)
    return
  end
  rt.pending = value
  rt.pending_deadline = self:_now() + block.settings.stable_ms / 1000
  self:_schedule(id, block.settings.stable_ms, function()
    if self.blocks[slot] ~= block or rt.pending ~= value then
      return
    end
    local before = Defs.boolean(rt.stable, trueWhen(inputAt(block, 1)))
    rt.stable, rt.pending, rt.pending_deadline = value, nil, nil
    local after = Defs.boolean(value, trueWhen(inputAt(block, 1)))
    local fire = { "value_changed" }
    if after ~= nil and after ~= (before == true) then
      fire[#fire + 1] = after and "became_true" or "became_false"
    end
    self.currentRun = self:_nextRun()
    self:_decide(slot, {
      input = "(timer)",
      decision = "changed",
      reason = string.format('The source held "%s" for %s.', value, Defs.duration(block.settings.stable_ms)),
      fire = fire,
      accepted = true,
    })
  end)
  self:_decide(slot, {
    input = ctx.input,
    decision = "started",
    reason = string.format(
      'The source changed to "%s". It becomes the output if it holds for %s.',
      value,
      Defs.duration(block.settings.stable_ms)
    ),
    accepted = true,
  })
end

-- ── Equipment feedback ──────────────────────────────────────────────────────

function Blocks:_openFeedback(slot, entry)
  local block, rt = self.blocks[slot], self.rt[slot]
  local fb = block.feedback
  local expect = Defs.wordList(fb.expect)
  local src = rt.fbsrc
  if src ~= nil and src.status == "ok" and expect.set[Defs.trim(src.raw):lower()] then
    entry.confirmed = "already"
    self:_note(
      slot,
      "feedback",
      "The equipment was already in the expected state when the event fired, so the event cannot be credited with it.",
      { cause = entry.run }
    )
    return
  end
  rt.fb = { seq = entry.seq, run = entry.run, deadline = self:_now() + fb.within_ms / 1000 }
  self:_schedule("lb:fb:" .. slot, fb.within_ms, function()
    if rt.fb == nil or rt.fb.seq ~= entry.seq then
      return
    end
    rt.fb = nil
    entry.confirmed = "not_confirmed"
    self.currentRun = self:_nextRun()
    self:_note(
      slot,
      "feedback",
      string.format("No equipment feedback within %s of the event.", Defs.duration(fb.within_ms)),
      { cause = entry.run }
    )
  end)
end

function Blocks:_feedbackSeen(slot)
  local block, rt = self.blocks[slot], self.rt[slot]
  if rt.fb == nil or block.feedback == nil then
    return
  end
  local expect = Defs.wordList(block.feedback.expect)
  local src = rt.fbsrc
  if src.status ~= "ok" or not expect.set[Defs.trim(src.raw):lower()] then
    return
  end
  local pending = rt.fb
  rt.fb = nil
  self.deps.cancel("lb:fb:" .. slot)
  for i = #self.history, 1, -1 do
    if self.history[i].seq == pending.seq then
      self.history[i].confirmed = "confirmed"
      break
    end
  end
  self.currentRun = self:_nextRun()
  self:_note(
    slot,
    "feedback",
    string.format('Equipment confirmed: feedback reported "%s" after the event.', tostring(src.raw)),
    { cause = pending.run }
  )
end

-- ── Engine events (the six classic types) ───────────────────────────────────

function Blocks:_onEngine(kind, f)
  local slot = slotOf(f.key)
  if slot == nil then
    return
  end
  if kind == "debounced" or kind == "timer_expired" then
    self:_async(kind, slot, f)
    return
  end
  if self._sync ~= nil then
    self._sync[#self._sync + 1] = { kind = kind, slot = slot, fields = f }
  end
end

--- Runs an engine call and returns what it emitted synchronously.
function Blocks:_call(fn)
  local saved = self._sync
  self._sync = {}
  local ok, a, b = pcall(fn)
  local events = self._sync
  self._sync = saved
  if not ok then
    error(a, 0)
  end
  return a, b, events
end

function Blocks:_async(kind, slot, f)
  local block, rt = self.blocks[slot], self.rt[slot]
  if block == nil or rt == nil then
    return
  end
  self.currentRun = self:_nextRun()
  if kind == "debounced" then
    local burst = rt.burst
    rt.burst, rt.quiet_deadline = 0, nil
    self:_decide(slot, {
      input = "(timer)",
      decision = "passed",
      reason = string.format(
        "Triggers stopped for %s (%d in the burst).",
        Defs.duration(block.settings.quiet_ms),
        math.max(burst, 1)
      ),
      fire = { "passed" },
      accepted = true,
      cause = rt.cause,
    })
  elseif kind == "timer_expired" then
    local late = rt.late == true
    rt.late, rt.timer = nil, nil
    self:_decide(slot, {
      input = "(timer)",
      decision = late and "expired_late" or "expired",
      reason = late and "The countdown ended while the controller was down; After Restart is Fire late, so it expired now."
        or string.format("The countdown of %s ended.", Defs.duration(block.settings.duration_ms)),
      fire = { "expired" },
      accepted = true,
      cause = rt.cause,
    })
  end
end

-- ── Runaway protection and the input queue ──────────────────────────────────

function Blocks:_nextRun()
  self.runId = self.runId + 1
  return "r" .. self.runId
end

function Blocks:_enter()
  self.depth = self.depth + 1
end

function Blocks:_leave()
  self.depth = self.depth - 1
  if self.depth == 0 and #self.queue > 0 then
    self:_drain()
  end
end

function Blocks:_drain()
  self.depth = 1
  local handled = 0
  while #self.queue > 0 and handled < M.LIMITS.drain do
    local item = table.remove(self.queue, 1)
    handled = handled + 1
    local ok, err = pcall(function()
      self:_handle(item)
    end)
    if not ok then
      self.depth = 0
      error(err, 0)
    end
  end
  self.depth = 0
  if #self.queue > 0 then
    self.deps.schedule("lb:drain", 1, function()
      if self.depth == 0 and #self.queue > 0 then
        self:_drain()
      end
    end)
  end
end

--- Takes an item in: handled now, or queued behind the one in progress.
function Blocks:_submit(item)
  if self.depth > 0 then
    if #self.queue >= M.LIMITS.queue then
      self:isolate(
        item.slot,
        string.format(
          "more than %d inputs arrived while one was still being handled: programming is probably feeding this block from its own events",
          M.LIMITS.queue
        )
      )
      return false, "queue full"
    end
    self.queue[#self.queue + 1] = item
    self.stats.queued_max = math.max(self.stats.queued_max, #self.queue)
    return true, "queued"
  end
  self:_enter()
  local ok, a, b = pcall(function()
    return self:_handle(item)
  end)
  self:_leave()
  if not ok then
    error(a, 0)
  end
  return a, b
end

function Blocks:_flood(slot)
  local rt = self.rt[slot]
  local now = self:_now()
  if now - rt.win.start >= M.LIMITS.window_s or now < rt.win.start then
    rt.win.start, rt.win.count = now, 0
  end
  rt.win.count = rt.win.count + 1
  return rt.win.count > M.LIMITS.inputs_per_window
end

--- Stops a block's pending callbacks. Nothing fires.
function Blocks:_cancelPending(slot)
  local rt = self.rt[slot]
  local k = key(slot)
  local eng = self.eng
  local stopped = {}
  if eng.timers[k] ~= nil then
    stopped.timer = { deadline = eng.timers[k].expires_at, seconds = eng.timers[k].seconds }
    eng.timers[k] = nil
    self.deps.cancel("lb:lp:t:" .. k)
  end
  if eng.debouncePending[k] ~= nil then
    stopped.quiet = true
    eng.debouncePending[k] = nil
    self.deps.cancel("lb:lp:d:" .. k)
  end
  if rt ~= nil then
    if rt.pending ~= nil then
      stopped.stable = rt.pending
      rt.pending, rt.pending_deadline = nil, nil
    end
    if rt.fb ~= nil then
      stopped.feedback = true
      rt.fb = nil
    end
    rt.burst, rt.quiet_deadline, rt.timer, rt.late = 0, nil, nil, nil
  end
  self.deps.cancel("lb:st:" .. slot)
  self.deps.cancel("lb:fb:" .. slot)
  self.deps.cancel("lb:cd:" .. slot)
  return stopped
end

--- Isolates a runaway block: it stops, says why and fires Faulted once.
function Blocks:isolate(slot, why)
  local block, rt = self.blocks[slot], self.rt[slot]
  if block == nil or rt == nil or rt.isolated ~= nil then
    return
  end
  self:_cancelPending(slot)
  rt.isolated = { at = self:_now(), text = why }
  self.stats.isolations = self.stats.isolations + 1
  for i = #self.queue, 1, -1 do
    if self.queue[i].slot == slot then
      table.remove(self.queue, i)
    end
  end
  self:_decide(slot, {
    input = "(driver)",
    decision = "isolated",
    reason = "Isolated: " .. why .. ". It stays stopped until it is resumed in Composer (Resume Selected Block).",
    fire = { "faulted" },
  })
end

--- Puts an isolated block back to work.
function Blocks:resume(slot)
  local rt = self.rt[slot]
  if self.blocks[slot] == nil or rt == nil then
    return false, "no block in that slot"
  end
  if rt.isolated == nil then
    return true, false
  end
  rt.isolated = nil
  rt.win = { start = 0, count = 0 }
  self:_note(slot, "resumed", "Resumed after isolation.")
  self:_evaluate(slot, { silent = true })
  return true, true
end

-- ── Inputs ──────────────────────────────────────────────────────────────────

local HANDLERS = {}

local COMMAND_LABEL = {
  trigger = "Trigger",
  start = "Start",
  restart = "Restart",
  cancel = "Cancel",
  set = "Set",
  clear = "Clear",
  toggle = "Toggle",
  increment = "Increment",
  decrement = "Decrement",
  reset = "Reset",
  input = "Input",
  input_unavailable = "Input unavailable",
}

--- A command from programming. `args` = { VALUE, BY, INPUT }.
--- Returns ok, info. When another input is in progress it returns true,
--- "queued" and the outcome arrives through history and deps.refused.
function Blocks:input(slot, command, args)
  slot = tonumber(slot)
  if slot == nil or slot < 1 or slot > Defs.SLOTS or slot ~= math.floor(slot) then
    self.stats.refused = self.stats.refused + 1
    if self.deps.refused ~= nil then
      self.deps.refused(nil, COMMAND_LABEL[command] or tostring(command), "BLOCK names no slot")
    end
    return false, "BLOCK names no slot"
  end
  self.stats.inputs = self.stats.inputs + 1
  return self:_submit({ kind = "command", slot = slot, command = command, args = copy(args or {}) })
end

function Blocks:_handle(item)
  if item.kind == "observe" then
    self:_observe(item.slot, item.index, item.value, { initial = item.initial, why = item.why })
    return true
  end
  local slot, command, args = item.slot, item.command, item.args or {}
  local what = COMMAND_LABEL[command] or tostring(command)
  self.currentRun = self:_nextRun()
  if self.restoreFailed ~= nil then
    return self:_refuse(slot, what, "the stored blocks could not be read; see Blocks Status")
  end
  if self.unreadable[slot] ~= nil then
    return self:_refuse(slot, what, "this block's stored settings could not be read: " .. self.unreadable[slot].why)
  end
  local block, rt = self.blocks[slot], self.rt[slot]
  if block == nil then
    return self:_refuse(
      slot,
      what,
      self.retired[slot] and ('this slot held "' .. self.retired[slot].name .. '", which was retired') or "this slot is empty"
    )
  end
  if self.readOnly then
    return self:_refuse(slot, what, "read-only")
  end
  if rt.isolated ~= nil then
    return self:_refuse(slot, what, "the block is isolated: " .. rt.isolated.text)
  end
  if not block.enabled then
    return self:_refuse(slot, what, "the block is disabled")
  end
  if not Defs.accepts(block.type, command) then
    return self:_refuse(
      slot,
      what,
      string.format("a %s block has no %s command", Defs.TYPES[block.type].label, what)
    )
  end
  if self:_flood(slot) then
    self:isolate(
      slot,
      string.format("more than %d inputs in %d seconds", M.LIMITS.inputs_per_window, M.LIMITS.window_s)
    )
    return false, "isolated"
  end
  return HANDLERS[block.type][command](self, slot, block, rt, args, what)
end

-- Cooldown ───────────────────────────────────────────────────────────────────

HANDLERS.cooldown = {}

function HANDLERS.cooldown.trigger(self, slot, block, rt)
  local k, now, ms = key(slot), self:_now(), block.settings.interval_ms
  local last = self.eng:throttleLastAt(k)
  local note = ""
  if last ~= nil and last > now then
    -- The controller clock went backwards. Counting from a time in the
    -- future would hold the block shut for the size of the jump.
    self.eng.throttleLast[k] = now
    last = now
    note = " (the controller clock moved backwards; the cooldown was restarted from now)"
  end
  local ok, passed = self:_call(function()
    return self.eng:throttle(k, ms, Defs.LIMITS.duration_ms_max)
  end)
  if not ok then
    return self:_refuse(slot, "Trigger", tostring(passed))
  end
  if passed then
    rt.suppressed = 0
    self:_schedule("lb:cd:" .. slot, ms, function()
      self:_refresh(slot)
    end)
    self:_decide(slot, {
      input = "Trigger",
      decision = "passed",
      reason = string.format("Passed. Repeats are suppressed for %s.", Defs.duration(ms)),
      fire = { "passed" },
      accepted = true,
    })
    return true, "passed"
  end
  rt.suppressed = rt.suppressed + 1
  rt.suppressed_total = rt.suppressed_total + 1
  local since = now - last
  self:_decide(slot, {
    input = "Trigger",
    decision = "suppressed",
    reason = string.format(
      "Trigger suppressed: %s passed %s ago. Its cooldown is %s. Eligible again in %s.%s",
      block.name,
      Defs.remaining(since),
      Defs.duration(ms),
      Defs.remaining(ms / 1000 - since),
      note
    ),
    suppressed = true,
  })
  return true, "suppressed"
end

function HANDLERS.cooldown.reset(self, slot, _, rt)
  self.eng:forgetThrottle(key(slot))
  rt.suppressed = 0
  self.deps.cancel("lb:cd:" .. slot)
  self:_decide(slot, { input = "Reset", decision = "reset", reason = "Cooldown cleared: the next trigger passes.", accepted = true })
  return true, "reset"
end

-- Quiet period ───────────────────────────────────────────────────────────────

HANDLERS.quiet = {}

function HANDLERS.quiet.trigger(self, slot, block, rt)
  local k, ms = key(slot), block.settings.quiet_ms
  local wasPending = self.eng:debouncePendingFor(k)
  self:_call(function()
    return self.eng:debounce(k, ms, Defs.LIMITS.duration_ms_max)
  end)
  rt.burst = wasPending and (rt.burst + 1) or 1
  rt.quiet_deadline = self:_now() + ms / 1000
  if not wasPending then
    rt.cause = self.currentRun
    self:_decide(slot, {
      input = "Trigger",
      decision = "started",
      reason = string.format("Countdown started. It passes if no trigger arrives for %s.", Defs.duration(ms)),
      fire = { "started" },
      accepted = true,
    })
    return true, "started"
  end
  self:_decide(slot, {
    input = "Trigger",
    decision = "restarted",
    reason = string.format("Countdown restarted (%d triggers in this burst). Nothing passes yet.", rt.burst),
    accepted = true,
  })
  return true, "restarted"
end

function HANDLERS.quiet.cancel(self, slot, _, rt)
  local _, was = self:_call(function()
    return self.eng:cancelDebounce(key(slot))
  end)
  if was then
    rt.burst, rt.quiet_deadline = 0, nil
    self:_decide(slot, {
      input = "Cancel",
      decision = "cancelled",
      reason = "The pending countdown was cancelled. Nothing passes.",
      fire = { "cancelled" },
      accepted = true,
    })
    return true, "cancelled"
  end
  self:_decide(slot, { input = "Cancel", decision = "unchanged", reason = "Nothing was pending.", accepted = true })
  return true, "unchanged"
end

function HANDLERS.quiet.reset(self, slot)
  self:_cancelPending(slot)
  self:_decide(slot, { input = "Reset", decision = "reset", reason = "Cleared. Nothing fired.", accepted = true })
  return true, "reset"
end

-- Timer ──────────────────────────────────────────────────────────────────────

HANDLERS.timer = {}

local function startTimer(self, slot, block, rt, force, what)
  local k = key(slot)
  local seconds = block.settings.duration_ms / 1000
  local info = self.eng:timerInfo(k)
  if info ~= nil and not force and block.settings.repeat_start == "ignore" then
    self:_decide(slot, {
      input = what,
      decision = "suppressed",
      reason = string.format(
        "Start ignored: the countdown is already running with %s left, and Repeated Start is Ignore while running.",
        Defs.remaining(info.expires_at - self:_now())
      ),
      suppressed = true,
    })
    return true, "suppressed"
  end
  self:_call(function()
    return self.eng:startTimer(k, seconds)
  end)
  rt.timer = { deadline = self:_now() + seconds, seconds = seconds, started_at = self:_now() }
  rt.late = nil
  if info == nil then
    rt.cause = self.currentRun
    self:_decide(slot, {
      input = what,
      decision = "started",
      reason = string.format("Countdown started: it expires in %s.", Defs.duration(block.settings.duration_ms)),
      fire = { "started" },
      accepted = true,
    })
    return true, "started"
  end
  self:_decide(slot, {
    input = what,
    decision = "restarted",
    reason = string.format(
      "Countdown restarted: %s again from now (it had %s left).",
      Defs.duration(block.settings.duration_ms),
      Defs.remaining(info.expires_at - self:_now())
    ),
    accepted = true,
  })
  return true, "restarted"
end

function HANDLERS.timer.start(self, slot, block, rt)
  return startTimer(self, slot, block, rt, false, "Start")
end

function HANDLERS.timer.trigger(self, slot, block, rt)
  return startTimer(self, slot, block, rt, false, "Trigger")
end

function HANDLERS.timer.restart(self, slot, block, rt)
  return startTimer(self, slot, block, rt, true, "Restart")
end

function HANDLERS.timer.cancel(self, slot, _, rt)
  local _, was = self:_call(function()
    return self.eng:cancelTimer(key(slot))
  end)
  rt.timer, rt.late = nil, nil
  if was then
    self:_decide(slot, {
      input = "Cancel",
      decision = "cancelled",
      reason = "The countdown was cancelled. It will not expire.",
      fire = { "cancelled" },
      accepted = true,
    })
    return true, "cancelled"
  end
  self:_decide(slot, { input = "Cancel", decision = "unchanged", reason = "No countdown was running.", accepted = true })
  return true, "unchanged"
end

function HANDLERS.timer.reset(self, slot)
  self:_cancelPending(slot)
  self:_decide(slot, { input = "Reset", decision = "reset", reason = "Cleared. Nothing fired.", accepted = true })
  return true, "reset"
end

-- Once per day ───────────────────────────────────────────────────────────────

HANDLERS.once = {}

function HANDLERS.once.trigger(self, slot, _, rt)
  local k = key(slot)
  local today = self.deps.localDay(self:_now())
  local stored = self.eng:onceDay(k)
  if stored ~= nil and stored > today then
    rt.suppressed = rt.suppressed + 1
    rt.suppressed_total = rt.suppressed_total + 1
    self:_decide(slot, {
      input = "Trigger",
      decision = "suppressed",
      reason = string.format(
        "Trigger suppressed: this block last passed on %s, and the controller clock now says %s. It passes again on a later day than %s.",
        stored,
        today,
        stored
      ),
      suppressed = true,
    })
    return true, "suppressed"
  end
  if stored ~= today then
    rt.suppressed = 0
  end
  local ok, passed = self:_call(function()
    return self.eng:oncePerDay(k)
  end)
  if not ok then
    return self:_refuse(slot, "Trigger", tostring(passed))
  end
  if passed then
    rt.suppressed = 0
    self:_decide(slot, {
      input = "Trigger",
      decision = "passed",
      reason = string.format("Passed: first trigger of %s.", today),
      fire = { "passed" },
      accepted = true,
    })
    return true, "passed"
  end
  rt.suppressed = rt.suppressed + 1
  rt.suppressed_total = rt.suppressed_total + 1
  self:_decide(slot, {
    input = "Trigger",
    decision = "suppressed",
    reason = string.format(
      "Trigger suppressed: already passed today (%s). It passes again after midnight on the controller's clock.",
      today
    ),
    suppressed = true,
  })
  return true, "suppressed"
end

function HANDLERS.once.reset(self, slot, _, rt)
  self.eng:forgetOnce(key(slot))
  rt.suppressed = 0
  self:_decide(slot, { input = "Reset", decision = "reset", reason = "Today's pass was forgotten: the next trigger passes.", accepted = true })
  return true, "reset"
end

-- Flag ───────────────────────────────────────────────────────────────────────

HANDLERS.flag = {}

local function flagResult(self, slot, what, events)
  local changed
  for _, e in ipairs(events) do
    if e.kind == "flag" and e.slot == slot then
      changed = e.fields.value
    end
  end
  if changed == nil then
    local on = self.eng:flag(key(slot))
    self:_decide(slot, {
      input = what,
      decision = "unchanged",
      reason = "Already " .. (on and "on" or "off") .. ": nothing fired.",
      accepted = true,
    })
    return true, "unchanged"
  end
  self:_decide(slot, {
    input = what,
    decision = changed and "became_true" or "became_false",
    reason = "Turned " .. (changed and "on." or "off."),
    fire = { changed and "became_true" or "became_false" },
    accepted = true,
  })
  return true, changed and "on" or "off"
end

function HANDLERS.flag.set(self, slot, _, _, args, what)
  local want = true
  if args.VALUE ~= nil and Defs.trim(args.VALUE) ~= "" then
    want = Defs.boolean(args.VALUE)
    if want == nil then
      return self:_refuse(slot, what, string.format('VALUE "%s" is not true/false, on/off, yes/no or 1/0', tostring(args.VALUE)))
    end
  end
  local _, _, events = self:_call(function()
    if want then
      return self.eng:setFlag(key(slot))
    end
    return self.eng:clearFlag(key(slot))
  end)
  return flagResult(self, slot, what, events)
end

function HANDLERS.flag.clear(self, slot, _, _, _, what)
  local _, _, events = self:_call(function()
    return self.eng:clearFlag(key(slot))
  end)
  return flagResult(self, slot, what, events)
end

function HANDLERS.flag.toggle(self, slot, _, _, _, what)
  local _, _, events = self:_call(function()
    return self.eng:toggleFlag(key(slot))
  end)
  return flagResult(self, slot, what, events)
end

HANDLERS.flag.reset = HANDLERS.flag.clear

-- Counter ────────────────────────────────────────────────────────────────────

HANDLERS.counter = {}

local function counterResult(self, slot, block, rt, what, ok, why, events)
  if not ok then
    return self:_refuse(slot, what, why)
  end
  local changed
  for _, e in ipairs(events) do
    if e.kind == "counter" and e.slot == slot then
      changed = e.fields.value
    end
  end
  local count = self.eng:counter(key(slot))
  if changed == nil then
    self:_decide(slot, {
      input = what,
      decision = "unchanged",
      reason = string.format("The count is already %d: nothing fired.", count),
      accepted = true,
    })
    return true, "unchanged"
  end
  local fire = { "value_changed" }
  local reason = string.format("The count is now %d.", count)
  local s = block.settings
  if s.threshold ~= nil then
    local reached = Defs.compare(s.comparison, count, s.threshold)
    if reached ~= rt.last then
      rt.last = reached
      fire[#fire + 1] = reached and "became_true" or "became_false"
      reason = reason
        .. string.format(
          " It %s the threshold (%s %d).",
          reached and "reached" or "left",
          s.comparison,
          s.threshold
        )
    end
  end
  self:_decide(slot, { input = what, decision = "changed", reason = reason, fire = fire, accepted = true })
  return true, count
end

local function by(args)
  local text = Defs.trim(args.BY)
  if text == "" then
    return 1
  end
  local n = Defs.number(text)
  if n == nil or n ~= math.floor(n) then
    return nil
  end
  return n
end

function HANDLERS.counter.increment(self, slot, block, rt, args, what)
  local n = by(args)
  if n == nil then
    return self:_refuse(slot, what, string.format('BY "%s" is not a whole number', tostring(args.BY)))
  end
  local ok, why, events = self:_call(function()
    return self.eng:increment(key(slot), n)
  end)
  return counterResult(self, slot, block, rt, what, ok, why, events)
end

function HANDLERS.counter.decrement(self, slot, block, rt, args, what)
  local n = by(args)
  if n == nil then
    return self:_refuse(slot, what, string.format('BY "%s" is not a whole number', tostring(args.BY)))
  end
  local ok, why, events = self:_call(function()
    return self.eng:increment(key(slot), -n)
  end)
  return counterResult(self, slot, block, rt, what, ok, why, events)
end

function HANDLERS.counter.set(self, slot, block, rt, args, what)
  local n = Defs.number(args.VALUE)
  if n == nil or n ~= math.floor(n) then
    return self:_refuse(slot, what, string.format('VALUE "%s" is not a whole number', tostring(args.VALUE)))
  end
  local ok, why, events = self:_call(function()
    return self.eng:setCounter(key(slot), n)
  end)
  return counterResult(self, slot, block, rt, what, ok, why, events)
end

function HANDLERS.counter.reset(self, slot, block, rt, _, what)
  local ok, why, events = self:_call(function()
    return self.eng:setCounter(key(slot), 0)
  end)
  return counterResult(self, slot, block, rt, what, ok, why, events)
end

HANDLERS.counter.clear = HANDLERS.counter.reset

-- Inputs shared by conditions, threshold and stable ─────────────────────────

local function inputIndex(args)
  local n = tostring(args.INPUT or ""):match("(%d+)")
  n = tonumber(n)
  if n == nil then
    return 1
  end
  return n
end

local function commandInput(self, slot, block, args, what)
  local index = inputIndex(args)
  local input = inputAt(block, index)
  if input == nil then
    return nil, self:_refuse(slot, what, string.format("Input %d is not configured on this block", index))
  end
  if input.device_id ~= nil then
    return nil,
      self:_refuse(
        slot,
        what,
        string.format(
          "%s is read from %s › %s; it does not take commands",
          input.label,
          input.device_name ~= "" and input.device_name or ("device " .. input.device_id),
          input.variable_name ~= "" and input.variable_name or ("variable " .. input.variable_id)
        )
      )
  end
  return input
end

local function setSource(self, slot, input, raw)
  local src = self:_source(slot, input.index)
  src.status, src.raw, src.why = "ok", clip(tostring(raw), M.LIMITS.raw), nil
  src.at, src.via, src.awaiting = self:_now(), "command", nil
end

local function inputUnavailable(self, slot, block, _, args, what)
  local input = commandInput(self, slot, block, args, what)
  if input == nil then
    return false
  end
  local src = self:_source(slot, input.index)
  src.status, src.raw, src.why = "unavailable", nil, "programming reported it cannot be read"
  src.at, src.via, src.awaiting = self:_now(), "command", nil
  self:_evaluate(slot, { input = input.label .. " = unavailable" })
  return true, "unavailable"
end

-- Conditions ─────────────────────────────────────────────────────────────────

HANDLERS.conditions = { input_unavailable = inputUnavailable }

function HANDLERS.conditions.input(self, slot, block, _, args, what)
  local input = commandInput(self, slot, block, args, what)
  if input == nil then
    return false
  end
  local value = Defs.boolean(args.VALUE, trueWhen(input))
  if value == nil then
    return self:_refuse(
      slot,
      what,
      string.format('VALUE "%s" is not true/false, on/off, yes/no or 1/0', tostring(args.VALUE))
    )
  end
  setSource(self, slot, input, args.VALUE)
  self:_evaluate(slot, { input = string.format("%s = %s", input.label, value and "true" or "false") })
  return true, value
end

function HANDLERS.conditions.trigger(self, slot, block, _, _, what)
  if block.settings.evaluation ~= "gate" then
    return self:_refuse(
      slot,
      what,
      "this block gives a continuous result (Became True / Became False); only a Gate a trigger block takes BLOCK_TRIGGER"
    )
  end
  local result, why = self:_conditions(slot)
  if result == true then
    self:_decide(slot, {
      input = "Trigger",
      decision = "passed",
      reason = "Passed: " .. why .. ".",
      fire = { "passed" },
      accepted = true,
    })
    return true, "passed"
  elseif result == false then
    self:_decide(slot, {
      input = "Trigger",
      decision = "suppressed",
      reason = "Trigger held back: " .. why .. ".",
      suppressed = true,
    })
    return true, "suppressed"
  end
  self:_decide(slot, {
    input = "Trigger",
    decision = "faulted",
    reason = "Trigger held back: " .. why .. ". An input that cannot be read is not treated as false or as true.",
    fire = { "faulted" },
    suppressed = true,
  })
  return true, "unknown"
end

-- Threshold ──────────────────────────────────────────────────────────────────

HANDLERS.threshold = { input_unavailable = inputUnavailable }

function HANDLERS.threshold.input(self, slot, block, _, args, what)
  local input = commandInput(self, slot, block, { INPUT = "1" }, what)
  if input == nil then
    return false
  end
  local x = Defs.number(args.VALUE)
  if x == nil then
    return self:_refuse(slot, what, string.format('VALUE "%s" is not a number', tostring(args.VALUE)))
  end
  setSource(self, slot, input, x)
  local units = block.settings.units ~= "" and (" " .. block.settings.units) or ""
  self:_evaluate(slot, { input = string.format("%s = %s%s", input.label, tostring(x), units) })
  return true, x
end

HANDLERS.threshold.set = HANDLERS.threshold.input

-- Stable-state filter ────────────────────────────────────────────────────────

HANDLERS.stable = { input_unavailable = inputUnavailable }

function HANDLERS.stable.input(self, slot, block, _, args, what)
  local input = commandInput(self, slot, block, { INPUT = "1" }, what)
  if input == nil then
    return false
  end
  local value = Defs.clean(args.VALUE, 60)
  if value == "" then
    return self:_refuse(slot, what, "VALUE is empty: send the state the source is in")
  end
  setSource(self, slot, input, value)
  self:_evaluate(slot, { input = string.format("%s = %s", input.label, value) })
  return true, value
end

function HANDLERS.stable.cancel(self, slot, _, rt)
  if rt.pending ~= nil then
    local dropped = rt.pending
    rt.pending, rt.pending_deadline = nil, nil
    self.deps.cancel("lb:st:" .. slot)
    self:_decide(slot, {
      input = "Cancel",
      decision = "cancelled",
      reason = string.format('The pending change to "%s" was dropped. The output stays "%s".', dropped, tostring(rt.stable)),
      fire = { "cancelled" },
      accepted = true,
    })
    return true, "cancelled"
  end
  self:_decide(slot, { input = "Cancel", decision = "unchanged", reason = "No change was pending.", accepted = true })
  return true, "unchanged"
end

-- State selector ─────────────────────────────────────────────────────────────

HANDLERS.selector = {}

local function allowedFrom(block, from)
  local out, any = {}, false
  for _, t in ipairs(block.settings.transitions) do
    if t.from == from or t.from == "*" then
      if t.to == "*" then
        any = true
      else
        out[#out + 1] = t.to
      end
    end
  end
  return out, any
end

function HANDLERS.selector.set(self, slot, block, rt, args, what)
  local wanted = Defs.clean(args.VALUE, Defs.LIMITS.state_name)
  local target
  for _, name in ipairs(block.settings.states) do
    if name:lower() == wanted:lower() then
      target = name
    end
  end
  if target == nil then
    return self:_refuse(
      slot,
      what,
      string.format('"%s" is not one of this block\'s states: %s', wanted, table.concat(block.settings.states, ", "))
    )
  end
  if target == rt.state then
    self:_decide(slot, {
      input = "Set " .. target,
      decision = "unchanged",
      reason = string.format('Already in "%s": nothing fired.', target),
      accepted = true,
    })
    return true, "unchanged"
  end
  if #block.settings.transitions > 0 then
    local list, any = allowedFrom(block, rt.state)
    local ok = any
    for _, name in ipairs(list) do
      if name == target then
        ok = true
      end
    end
    if not ok then
      return self:_refuse(
        slot,
        "Set " .. target,
        string.format(
          '%s → %s is not an allowed transition. From "%s" it may go to: %s',
          rt.state,
          target,
          rt.state,
          #list > 0 and table.concat(list, ", ") or "nothing"
        )
      )
    end
  end
  rt.previous, rt.state = rt.state, target
  self:_decide(slot, {
    input = "Set " .. target,
    decision = "changed",
    reason = string.format("State changed: %s → %s.", rt.previous, target),
    fire = { "value_changed" },
    accepted = true,
  })
  return true, target
end

function HANDLERS.selector.reset(self, slot, block, rt)
  local initial = block.settings.initial
  if rt.state == initial then
    self:_decide(slot, { input = "Reset", decision = "unchanged", reason = "Already in the initial state.", accepted = true })
    return true, "unchanged"
  end
  rt.previous, rt.state = rt.state, initial
  self:_decide(slot, {
    input = "Reset",
    decision = "changed",
    reason = string.format("Returned to the initial state: %s → %s.", rt.previous, initial),
    fire = { "value_changed" },
    accepted = true,
  })
  return true, initial
end

-- ── Configuration ───────────────────────────────────────────────────────────

--- The first slot that has never held a block. nil when none is left.
function Blocks:freeSlot()
  for slot = 1, Defs.SLOTS do
    if self.blocks[slot] == nil and self.retired[slot] == nil and self.unreadable[slot] == nil then
      return slot
    end
  end
  return nil
end

function Blocks:counts()
  local used, retired, enabled = 0, 0, 0
  for slot = 1, Defs.SLOTS do
    if self.blocks[slot] ~= nil then
      used = used + 1
      if self.blocks[slot].enabled then
        enabled = enabled + 1
      end
    end
    if self.retired[slot] ~= nil then
      retired = retired + 1
    end
  end
  return { used = used, retired = retired, enabled = enabled, free = Defs.SLOTS - used - retired }
end

--- Is the name taken by another block? (Names are for people; identity is
--- the id and the slot. A duplicate name is refused only because two blocks
--- nobody can tell apart is a commissioning trap.)
function Blocks:nameTaken(name, exceptSlot)
  local wanted = tostring(name or ""):lower()
  for slot, block in pairs(self.blocks) do
    if slot ~= exceptSlot and block.name:lower() == wanted then
      return slot
    end
  end
  return nil
end

local function ruleOf(def)
  return fingerprint({ settings = def.settings, inputs = def.inputs, feedback = def.feedback or false })
end

--- What applying `def` to `slot` would do, as sentences. Read-only.
function Blocks:impact(slot, def)
  local out = {}
  local block, rt = self.blocks[slot], self.rt[slot]
  if block == nil then
    out[#out + 1] = string.format("Creates %s as a new %s block.", Defs.slotLabel(slot), Defs.TYPES[def.type].label)
    return out
  end
  if def.type ~= block.type then
    out[#out + 1] = "REFUSED: a block's type cannot change. Retire it and create a new block instead."
    return out
  end
  if block.name ~= def.name then
    out[#out + 1] = string.format(
      'Renames "%s" to "%s". The slot, its events and its variables keep their ids: programming is not affected.',
      block.name,
      def.name
    )
  end
  if ruleOf(block) == ruleOf(def) then
    if #out == 0 then
      out[#out + 1] = "Changes only the tag or notes. Nothing running is touched."
    else
      out[#out + 1] = "The rule itself is unchanged: nothing running is touched."
    end
    return out
  end
  local k, now = key(slot), self:_now()
  local info = self.eng:timerInfo(k)
  if info ~= nil then
    out[#out + 1] = string.format(
      "The running countdown (%s left) is CANCELLED. Expired and Cancelled do not fire.",
      Defs.remaining(info.expires_at - now)
    )
  end
  if self.eng:debouncePendingFor(k) then
    out[#out + 1] = "The pending quiet countdown is DROPPED. Passed does not fire."
  end
  if rt.pending ~= nil then
    out[#out + 1] = string.format('The pending change to "%s" is DROPPED.', rt.pending)
  end
  if block.type == "flag" then
    out[#out + 1] = string.format("The flag keeps its value (%s).", self.eng:flag(k) and "on" or "off")
  elseif block.type == "counter" then
    out[#out + 1] = string.format("The count (%d) is kept.", self.eng:counter(k))
  elseif block.type == "cooldown" and self.eng:throttleLastAt(k) ~= nil then
    out[#out + 1] = "The time of the last pass is kept; the new cooldown is measured from it."
  elseif block.type == "once" and self.eng:onceDay(k) ~= nil then
    out[#out + 1] = "Today's pass is kept."
  elseif block.type == "selector" then
    local keeps = false
    for _, name in ipairs(def.settings.states) do
      if name == rt.state then
        keeps = true
      end
    end
    if keeps then
      out[#out + 1] = string.format('The current state ("%s") is kept.', tostring(rt.state))
    else
      out[#out + 1] = string.format(
        'The current state ("%s") is not in the new list: it returns to "%s" and nothing fires.',
        tostring(rt.state),
        def.settings.initial
      )
    end
  elseif block.type == "conditions" or block.type == "threshold" or block.type == "stable" then
    out[#out + 1] = "Inputs are read again from scratch; the first result sets the state without firing."
  end
  if #out == 0 then
    out[#out + 1] = "Nothing is running: the new settings apply at once."
  end
  return out
end

--- Sets a slot's runtime up for a definition, keeping what `keep` allows.
function Blocks:_install(slot, block, fresh)
  local rt = self.rt[slot]
  if rt == nil or fresh then
    local old = rt
    rt = newRuntime()
    if old ~= nil then
      rt.counts, rt.suppressed_total = old.counts, old.suppressed_total
      rt.last_accepted, rt.last_suppressed, rt.last_refused = old.last_accepted, old.last_suppressed, old.last_refused
      rt.state, rt.previous = old.state, old.previous
      rt.pushed = old.pushed
    end
    self.rt[slot] = rt
  end
  local t = block.type
  if t == "selector" then
    local keeps = false
    for _, name in ipairs(block.settings.states) do
      if name == rt.state then
        keeps = true
      end
    end
    if not keeps then
      rt.state, rt.previous = block.settings.initial, nil
    end
  elseif t == "counter" then
    local s = block.settings
    rt.last = s.threshold ~= nil and Defs.compare(s.comparison, self.eng:counter(key(slot)), s.threshold) or false
  elseif t == "conditions" or t == "threshold" or t == "stable" then
    -- Nothing has been read yet: the result is unknown until it has.
    if rt.valid and (rt.fault == nil) and next(rt.src) == nil then
      rt.valid = false
      rt.fault = { at = self:_now(), text = "no input has been read yet" }
    end
  end
  return rt
end

--- Creates a block from a normalized definition (blockdefs.normalize).
--- Returns slot, block or nil, why.
function Blocks:create(def)
  if self.restoreFailed ~= nil then
    return nil, "the stored blocks could not be read; nothing can be configured until that is acknowledged"
  end
  if self.readOnly then
    return nil, "read-only"
  end
  local taken = self:nameTaken(def.name)
  if taken ~= nil then
    return nil, string.format('%s is already named "%s"', Defs.slotLabel(taken), def.name)
  end
  local slot = self:freeSlot()
  if slot == nil then
    local c = self:counts()
    if c.retired > 0 then
      return nil,
        string.format(
          "all %d slots have been used. %d hold retired blocks: release one with Release Retired Slot (programming still pointing at it would then drive the new block)",
          Defs.SLOTS,
          c.retired
        )
    end
    return nil, string.format("all %d slots are in use", Defs.SLOTS)
  end
  local block = copy(def)
  block.id = self.deps.newId()
  block.slot = slot
  block.enabled = true
  block.created_at = self:_now()
  block.updated_at = block.created_at
  block.rev = 1
  self.blocks[slot] = block
  self.revision = self.revision + 1
  self:_install(slot, block, true)
  self:_watch(slot)
  self:_note(slot, "configured", string.format('Created: %s block named "%s".', Defs.TYPES[block.type].label, block.name))
  self:_evaluateIfInputDriven(slot)
  return slot, block
end

function Blocks:_evaluateIfInputDriven(slot)
  local block = self.blocks[slot]
  if block ~= nil and block.enabled and Defs.TYPES[block.type].inputs > 0 then
    self:_evaluate(slot, { silent = true })
  else
    self:_refresh(slot)
  end
end

--- Replaces a block's definition in one step. Identity, slot, enabled state
--- and created_at are kept; the type cannot change.
function Blocks:apply(slot, def)
  if self.restoreFailed ~= nil then
    return false, "the stored blocks could not be read; nothing can be configured until that is acknowledged"
  end
  if self.readOnly then
    return false, "read-only"
  end
  local block = self.blocks[slot]
  if block == nil then
    return false, "no block in that slot"
  end
  if def.type ~= block.type then
    return false, "a block's type cannot change: retire it and create a new block"
  end
  local taken = self:nameTaken(def.name, slot)
  if taken ~= nil then
    return false, string.format('%s is already named "%s"', Defs.slotLabel(taken), def.name)
  end
  local ruleChanged = ruleOf(block) ~= ruleOf(def)
  local renamed = block.name ~= def.name
  local oldName = block.name
  local updated = copy(def)
  updated.id, updated.slot, updated.enabled = block.id, slot, block.enabled
  updated.created_at, updated.updated_at = block.created_at, self:_now()
  updated.rev = (block.rev or 1) + 1
  if ruleChanged then
    self:_cancelPending(slot)
    self:_unsubscribe(slot)
  end
  self.blocks[slot] = updated
  self.revision = self.revision + 1
  if ruleChanged then
    self:_install(slot, updated, true)
    if updated.enabled then
      self:_watch(slot)
    end
  end
  self:_note(
    slot,
    "configured",
    (renamed and string.format('Renamed from "%s". ', oldName) or "")
      .. (ruleChanged and "Settings changed; anything pending was dropped without firing." or "Rule unchanged.")
  )
  if ruleChanged then
    self:_evaluateIfInputDriven(slot)
  end
  return true, updated
end

--- A copy of a block under a new name: new identity, new slot, no history,
--- no carried-over value.
function Blocks:copyBlock(slot, name)
  local block = self.blocks[slot]
  if block == nil then
    return nil, "no block in that slot"
  end
  local def = copy(block)
  def.id, def.slot, def.created_at, def.updated_at, def.rev, def.enabled = nil, nil, nil, nil, nil, nil
  def.name = Defs.clean(name, Defs.LIMITS.name)
  if def.name == "" then
    def.name = Defs.clean(block.name .. " copy", Defs.LIMITS.name)
  end
  return self:create(def)
end

function Blocks:setEnabled(slot, enabled)
  local block = self.blocks[slot]
  if block == nil then
    return false, "no block in that slot"
  end
  if self.readOnly then
    return false, "read-only"
  end
  enabled = enabled == true
  if block.enabled == enabled then
    return true, false
  end
  block.enabled = enabled
  block.updated_at = self:_now()
  self.revision = self.revision + 1
  if not enabled then
    local stopped = self:_cancelPending(slot)
    self:_unsubscribe(slot)
    local what = {}
    if stopped.timer then
      what[#what + 1] = "a running countdown"
    end
    if stopped.quiet then
      what[#what + 1] = "a pending quiet countdown"
    end
    if stopped.stable then
      what[#what + 1] = "a pending change"
    end
    self:_note(
      slot,
      "disabled",
      #what > 0 and ("Disabled. Dropped without firing: " .. table.concat(what, ", ") .. ".") or "Disabled."
    )
  else
    self.rt[slot].src = {}
    self:_install(slot, block, false)
    self:_watch(slot)
    self:_note(slot, "enabled", "Enabled.")
    self:_evaluateIfInputDriven(slot)
  end
  return true, true
end

--- Retires a block: it stops, its slot is kept out of use, and its values
--- are discarded. Programming that still points at the slot is refused with
--- the retired block's name.
function Blocks:retire(slot)
  local block = self.blocks[slot]
  if block == nil then
    return false, "no block in that slot"
  end
  if self.readOnly then
    return false, "read-only"
  end
  self:_cancelPending(slot)
  self:_unsubscribe(slot)
  local k = key(slot)
  self.eng.counters[k], self.eng.flags[k], self.eng.once[k], self.eng.throttleLast[k] = nil, nil, nil, nil
  self:_note(slot, "retired", string.format('"%s" was retired. %s stays out of use.', block.name, Defs.slotLabel(slot)))
  self.retired[slot] = { id = block.id, name = block.name, type = block.type, retired_at = self:_now() }
  self.blocks[slot] = nil
  local pushed = self.rt[slot] and self.rt[slot].pushed
  self.rt[slot] = nil
  self._emptyPushed = self._emptyPushed or {}
  self._emptyPushed[slot] = pushed
  self.revision = self.revision + 1
  self:_refresh(slot)
  self:_changed()
  return true
end

--- Makes a retired slot available again. Explicit, because programming
--- written for the retired block would drive whatever lands there next.
function Blocks:releaseRetired(slot)
  if self.retired[slot] == nil then
    return false, "that slot holds no retired block"
  end
  if self.readOnly then
    return false, "read-only"
  end
  self.retired[slot] = nil
  self.revision = self.revision + 1
  self:_refresh(slot)
  self:_changed()
  return true
end

--- Gives a new flag or counter block a starting value WITHOUT firing: the
--- one-time copy behind an explicit legacy adoption. Returns ok, why.
function Blocks:seed(slot, value)
  local block = self.blocks[slot]
  if block == nil then
    return false, "no block in that slot"
  end
  local k = key(slot)
  if block.type == "flag" then
    self.eng.flags[k] = value == true and true or nil
  elseif block.type == "counter" then
    local n = tonumber(value)
    if n == nil or n ~= math.floor(n) or math.abs(n) > Engine.LIMITS.counter_abs then
      return false, "not a whole number"
    end
    self.eng.counters[k] = n
  else
    return false, "only a flag or a counter can take a starting value"
  end
  self:_install(slot, block, false)
  self:_note(slot, "configured", "Starting value copied in. Nothing fired.")
  return true
end

--- What retiring or disabling a block would do, as sentences.
function Blocks:stopImpact(slot, retiring)
  local block, rt = self.blocks[slot], self.rt[slot]
  local out = {}
  if block == nil then
    return { "No block in that slot." }
  end
  local k, now = key(slot), self:_now()
  local info = self.eng:timerInfo(k)
  if info ~= nil then
    out[#out + 1] = string.format(
      "Its countdown (%s left) is cancelled without firing.",
      Defs.remaining(info.expires_at - now)
    )
  end
  if self.eng:debouncePendingFor(k) then
    out[#out + 1] = "Its pending quiet countdown is dropped without firing."
  end
  if rt.pending ~= nil then
    out[#out + 1] = "Its pending change is dropped."
  end
  if retiring then
    out[#out + 1] = string.format(
      "%s is kept out of use so that programming written for \"%s\" can never drive a different block. Commands sent to it are refused and say so.",
      Defs.slotLabel(slot),
      block.name
    )
    if block.type == "counter" or block.type == "flag" or block.type == "selector" then
      out[#out + 1] = "Its stored value is discarded."
    end
    out[#out + 1] = "Composer programming on its events stays in the project and simply never runs: remove it by hand."
  else
    out[#out + 1] = "It ignores inputs and fires nothing until it is enabled. Its stored value is kept."
  end
  return out
end

-- ── Licence (read-only) ─────────────────────────────────────────────────────

--- When the licence halts the pack: inputs are refused, running countdowns
--- are HELD (not fired), pending quiet countdowns and pending changes are
--- dropped. When it is restored each held countdown follows its block's
--- After Restart rule, measured from the moment it was held.
function Blocks:setReadOnly(flag)
  flag = flag == true
  if flag == self.readOnly then
    return
  end
  local now = self:_now()
  if flag then
    for slot, block in pairs(self.blocks) do
      local rt = self.rt[slot]
      local stopped = self:_cancelPending(slot)
      if stopped.timer ~= nil then
        rt.held = { deadline = stopped.timer.deadline, seconds = stopped.timer.seconds, at = now }
        self:_note(
          slot,
          "held",
          string.format(
            "Read-only (licence): the countdown is held with %s left. It follows After Restart (%s) when the pack is restored.",
            Defs.remaining(stopped.timer.deadline - now),
            Defs.RECOVERY[block.settings.recovery] or "Cancel if missed"
          )
        )
      elseif stopped.quiet or stopped.stable then
        self:_note(slot, "held", "Read-only (licence): what was pending was dropped without firing.")
      end
    end
    self.readOnly = true
    self.eng:setReadOnly(true)
    self:refreshAll()
    return
  end
  self.readOnly = false
  self.eng:setReadOnly(false)
  for slot in pairs(self.blocks) do
    local rt = self.rt[slot]
    if rt.held ~= nil then
      local held = rt.held
      rt.held = nil
      self:_recoverTimer(slot, held.deadline, held.seconds, held.at, "the pack was read-only")
    end
    self:_evaluateIfInputDriven(slot)
  end
  self:refreshAll()
end

-- ── Persistence ─────────────────────────────────────────────────────────────

function Blocks:serialize()
  local doc = {
    schema = M.SCHEMA,
    v = M.VERSION,
    revision = self.revision,
    saved_at = self:_now(),
    seq = self.seq,
    run = self.runId,
    blocks = {},
    retired = {},
    rt = {},
    history = {},
  }
  for slot, block in pairs(self.blocks) do
    doc.blocks[key(slot)] = copy(block)
    local rt = self.rt[slot]
    local k = key(slot)
    local saved = {
      last = rt.last,
      valid = rt.valid,
      suppressed = rt.suppressed,
      suppressed_total = rt.suppressed_total,
      state = rt.state,
      previous = rt.previous,
      stable = rt.stable,
      reading = rt.reading,
      counts = copy(rt.counts),
      last_accepted = copy(rt.last_accepted),
      last_suppressed = copy(rt.last_suppressed),
      last_refused = copy(rt.last_refused),
      isolated = copy(rt.isolated),
      quiet_deadline = self.eng:debouncePendingFor(k) and rt.quiet_deadline or nil,
      pending_deadline = rt.pending ~= nil and rt.pending_deadline or nil,
      src = {},
    }
    local info = self.eng:timerInfo(k)
    if info ~= nil then
      saved.timer = { deadline = info.expires_at, seconds = info.seconds }
    elseif rt.held ~= nil then
      saved.timer = { deadline = rt.held.deadline, seconds = rt.held.seconds, held_at = rt.held.at }
    end
    for index, src in pairs(rt.src) do
      local input = inputAt(block, index)
      -- A value programming SENT is the only copy of it there is, so it is
      -- kept. A value read from a device variable is read again instead.
      if input ~= nil and input.device_id == nil and src.status == "ok" then
        saved.src["i" .. index] = { raw = src.raw, at = src.at }
      end
    end
    doc.rt[k] = saved
  end
  for slot, entry in pairs(self.unreadable) do
    -- Written back exactly as it was found: nothing unreadable is lost.
    doc.blocks[key(slot)] = entry.raw
  end
  for slot, entry in pairs(self.retired) do
    doc.retired[key(slot)] = copy(entry)
  end
  local eng = self.eng:serialize()
  doc.eng = { counters = eng.counters, flags = eng.flags, once = eng.once, throttle_last = eng.throttle_last }
  local from = math.max(1, #self.history - M.LIMITS.history_saved + 1)
  for i = from, #self.history do
    doc.history[#doc.history + 1] = copy(self.history[i])
  end
  return doc
end

--- Walks MIGRATIONS from the document's version to M.VERSION.
--- Returns doc or nil, why.
function M.migrate(doc, migrations, target)
  migrations = migrations or M.MIGRATIONS
  target = target or M.VERSION
  local v = tonumber(doc.v)
  if v == nil or v < 0 or v ~= math.floor(v) then
    return nil, "the stored document has no version"
  end
  if v > target then
    return nil,
      string.format(
        "the stored document is version %d and this driver reads up to version %d: it was written by a newer driver",
        v,
        target
      )
  end
  while v < target do
    local step = migrations[v]
    if type(step) ~= "function" then
      return nil, string.format("no upgrade from document version %d", v)
    end
    local ok, upgraded = pcall(step, doc)
    if not ok or type(upgraded) ~= "table" then
      return nil, string.format("the upgrade from document version %d failed", v)
    end
    doc = upgraded
    v = v + 1
    doc.v = v
  end
  return doc
end

--- Applies a timer's After Restart rule. `since` is when it stopped being
--- counted (the last save before a restart, or the moment it was held).
function Blocks:_recoverTimer(slot, deadline, seconds, since, cause)
  local block, rt = self.blocks[slot], self.rt[slot]
  local now = self:_now()
  local policy = block.settings.recovery
  local k = key(slot)
  local remaining = deadline - now
  local function arm(secs, late)
    rt.timer = { deadline = now + secs, seconds = seconds, started_at = now }
    rt.late = late or nil
    self:_call(function()
      return self.eng:startTimer(k, secs)
    end)
  end
  if policy == "resume" and since ~= nil then
    local left = deadline - since
    if left > 0 then
      arm(left)
      local text = string.format(
        "Countdown resumed with the %s it had left (%s; After Restart is Resume remaining).",
        Defs.remaining(left),
        cause
      )
      self:_note(slot, "recovered", text, { origin = "restored" })
      return text
    end
  end
  if remaining > 0 then
    arm(remaining)
    local text = string.format("Countdown carried on: %s left (%s).", Defs.remaining(remaining), cause)
    self:_note(slot, "recovered", text, { origin = "restored" })
    return text
  end
  if policy == "fire_late" then
    arm(0.001, true)
    local text = string.format(
      "Countdown ended %s ago while it was not being counted (%s). After Restart is Fire late: it expires now.",
      Defs.remaining(-remaining),
      cause
    )
    self:_note(slot, "recovered", text, { origin = "restored" })
    return text
  end
  rt.timer = nil
  local text = string.format(
    "Countdown ended %s ago while it was not being counted (%s). It was cancelled and Expired did NOT fire (After Restart is %s).",
    Defs.remaining(-remaining),
    cause,
    Defs.RECOVERY[policy] or "Cancel if missed"
  )
  self:_note(slot, "missed", text, { origin = "restored" })
  return text
end

--- Loads a stored document. Never resets silently:
---   • not a blocks document, or from a newer driver → restoreFailed is set,
---     nothing is loaded, and serialize()/changed() stop writing so the
---     stored copy is left exactly as it is until the dealer decides;
---   • one block's settings unreadable → that slot is kept, marked
---     unreadable and written back verbatim; the others load.
--- Returns a report { ok, failed, why, loaded, unreadable, notes }.
function Blocks:restore(doc)
  local report = { ok = true, loaded = 0, unreadable = 0, notes = {} }
  local function fail(why)
    self.restoreFailed = { why = why, at = self:_now() }
    report.ok, report.failed, report.why = false, true, why
    self.recovery = { at = self:_now(), failed = why, notes = { "Stored blocks were NOT loaded: " .. why } }
    return report
  end
  if doc == nil then
    self.recovery = { at = self:_now(), notes = {} }
    return report
  end
  if type(doc) ~= "table" then
    return fail("the stored document is not a table")
  end
  if doc.schema ~= M.SCHEMA then
    return fail("the stored document is not a Logic Blocks document")
  end
  local migrated, why = M.migrate(copy(doc))
  if migrated == nil then
    return fail(why)
  end
  doc = migrated
  if type(doc.blocks) ~= "table" then
    return fail("the stored document has no blocks table")
  end
  local now = self:_now()
  self.revision = tonumber(doc.revision) or 0
  self.seq = tonumber(doc.seq) or 0
  self.runId = tonumber(doc.run) or 0
  local eng = type(doc.eng) == "table" and doc.eng or {}
  self.eng:restore({
    counters = eng.counters,
    flags = eng.flags,
    once = eng.once,
    throttle_last = eng.throttle_last,
  })
  for k, last in pairs(self.eng.throttleLast) do
    if last > now then
      self.eng.throttleLast[k] = now
      report.notes[#report.notes + 1] = string.format(
        "%s: the controller clock is earlier than its last pass; the cooldown was restarted from now.",
        Defs.slotLabel(slotOf(k) or 0)
      )
    end
  end
  for i, entry in ipairs(type(doc.history) == "table" and doc.history or {}) do
    if type(entry) == "table" and i <= M.LIMITS.history_saved then
      local kept = copy(entry)
      kept.origin = "restored"
      if kept.confirmed == "pending" then
        kept.confirmed = "not_confirmed"
      end
      self.history[#self.history + 1] = kept
    end
  end
  for k, entry in pairs(type(doc.retired) == "table" and doc.retired or {}) do
    local slot = slotOf(k)
    if slot ~= nil and slot >= 1 and slot <= Defs.SLOTS and type(entry) == "table" then
      self.retired[slot] = copy(entry)
    end
  end
  local slots = {}
  for k in pairs(doc.blocks) do
    local slot = slotOf(k)
    if slot ~= nil and slot >= 1 and slot <= Defs.SLOTS then
      slots[#slots + 1] = slot
    else
      report.notes[#report.notes + 1] = string.format('Stored entry "%s" names no slot and was left alone.', tostring(k))
    end
  end
  table.sort(slots)
  for _, slot in ipairs(slots) do
    local raw = doc.blocks[key(slot)]
    local okDef, whyDef = Defs.wellFormed(raw)
    if not okDef then
      self.unreadable[slot] = { raw = raw, why = whyDef }
      report.unreadable = report.unreadable + 1
      report.notes[#report.notes + 1] = string.format(
        "%s: its stored settings could not be read (%s). It is kept as it was found and does nothing until it is fixed or retired.",
        Defs.slotLabel(slot),
        whyDef
      )
    else
      local block = copy(raw)
      block.slot = slot
      block.enabled = block.enabled ~= false
      self.blocks[slot] = block
      local saved = type(doc.rt) == "table" and type(doc.rt[key(slot)]) == "table" and doc.rt[key(slot)] or {}
      local rt = newRuntime()
      rt.last = saved.last == true
      rt.valid = saved.valid ~= false
      rt.suppressed = tonumber(saved.suppressed) or 0
      rt.suppressed_total = tonumber(saved.suppressed_total) or 0
      rt.state, rt.previous = saved.state, saved.previous
      rt.stable = type(saved.stable) == "string" and saved.stable or nil
      rt.reading = tonumber(saved.reading)
      if type(saved.counts) == "table" then
        for name in pairs(rt.counts) do
          rt.counts[name] = tonumber(saved.counts[name]) or 0
        end
      end
      rt.last_accepted, rt.last_suppressed, rt.last_refused =
        copy(saved.last_accepted), copy(saved.last_suppressed), copy(saved.last_refused)
      rt.isolated = type(saved.isolated) == "table" and copy(saved.isolated) or nil
      self.rt[slot] = rt
      for name, src in pairs(type(saved.src) == "table" and saved.src or {}) do
        local index = tonumber(tostring(name):match("^i(%d+)$"))
        local input = index and inputAt(block, index)
        if input ~= nil and input.device_id == nil and type(src) == "table" and src.raw ~= nil then
          rt.src[index] = { status = "ok", raw = tostring(src.raw), at = tonumber(src.at), via = "restored" }
        end
      end
      self:_install(slot, block, false)
      report.loaded = report.loaded + 1
      if block.enabled and rt.isolated == nil then
        self:_watch(slot)
        if type(saved.timer) == "table" and tonumber(saved.timer.deadline) ~= nil and block.type == "timer" then
          report.notes[#report.notes + 1] = Defs.slotLabel(slot)
            .. " "
            .. block.name
            .. ": "
            .. self:_recoverTimer(
              slot,
              tonumber(saved.timer.deadline),
              tonumber(saved.timer.seconds) or block.settings.duration_ms / 1000,
              tonumber(saved.timer.held_at) or tonumber(doc.saved_at),
              "the controller restarted"
            )
        end
        if saved.quiet_deadline ~= nil then
          local text = "A quiet countdown was pending when the controller stopped. It was dropped and did NOT pass."
          self:_note(slot, "missed", text, { origin = "restored" })
          report.notes[#report.notes + 1] = Defs.slotLabel(slot) .. " " .. block.name .. ": " .. text
        end
        if saved.pending_deadline ~= nil then
          local text = "A change was waiting to hold when the controller stopped. It was dropped."
          self:_note(slot, "missed", text, { origin = "restored" })
          report.notes[#report.notes + 1] = Defs.slotLabel(slot) .. " " .. block.name .. ": " .. text
        end
        self:_evaluateIfInputDriven(slot)
      elseif rt.isolated ~= nil then
        report.notes[#report.notes + 1] = Defs.slotLabel(slot)
          .. " "
          .. block.name
          .. ": still isolated from before the restart ("
          .. tostring(rt.isolated.text)
          .. ")."
      end
    end
  end
  self.recovery = { at = now, saved_at = tonumber(doc.saved_at), notes = report.notes, loaded = report.loaded }
  self:refreshAll()
  return report
end

--- The dealer accepts that the stored blocks cannot be used. The runtime
--- starts empty and may write again. The caller keeps the old document.
function Blocks:acknowledgeRestoreFailure()
  if self.restoreFailed == nil then
    return false
  end
  self.restoreFailed = nil
  self.recovery.acknowledged_at = self:_now()
  self:_changed()
  return true
end

-- ── Housekeeping ────────────────────────────────────────────────────────────

--- Call about once a minute. Notices a controller clock that jumped,
--- forgets yesterday's once-per-day passes and rewrites variables whose
--- state changes with time alone (a cooldown ending, midnight passing).
function Blocks:tick(expectedSeconds)
  local now = self:_now()
  if self.lastTick ~= nil and expectedSeconds ~= nil then
    local drift = (now - self.lastTick) - expectedSeconds
    if math.abs(drift) > math.max(30, expectedSeconds / 2) then
      self.stats.clock_jumps = self.stats.clock_jumps + 1
      self.lastJump = { at = now, seconds = drift }
      for k, last in pairs(self.eng.throttleLast) do
        if last > now then
          self.eng.throttleLast[k] = now
        end
      end
    end
  end
  self.lastTick = now
  self.eng:pruneOnce()
  for slot, block in pairs(self.blocks) do
    if block.type == "once" and not self.eng:onceDoneToday(key(slot)) then
      self.rt[slot].suppressed = 0
    end
  end
  self:refreshAll()
end

--- True while a running countdown needs the saved document kept fresh:
--- Resume remaining measures what was left from the last save.
function Blocks:needsHeartbeat()
  for slot, block in pairs(self.blocks) do
    if block.type == "timer" and block.settings.recovery == "resume" and self.eng:timerInfo(key(slot)) ~= nil then
      return true
    end
  end
  return false
end

function Blocks:stop()
  for slot in pairs(self.blocks) do
    local k = key(slot)
    self.deps.cancel("lb:lp:t:" .. k)
    self.deps.cancel("lb:lp:d:" .. k)
    self.deps.cancel("lb:st:" .. slot)
    self.deps.cancel("lb:fb:" .. slot)
    self.deps.cancel("lb:cd:" .. slot)
  end
  self.deps.cancel("lb:drain")
  for _, subs in pairs(self.watching) do
    if self.deps.unwatch ~= nil then
      self.deps.unwatch(subs.device, subs.variable)
    end
  end
  self.watching = {}
end

-- ── Views (read-only) ───────────────────────────────────────────────────────

--- One sentence saying where a block stands right now.
function Blocks:statusLine(slot)
  local block, rt = self.blocks[slot], self.rt[slot]
  if self.unreadable[slot] ~= nil then
    return "Stored settings unreadable: " .. self.unreadable[slot].why
  end
  if block == nil then
    return self.retired[slot] and ('Retired ("' .. self.retired[slot].name .. '")') or "Empty"
  end
  if rt.isolated ~= nil then
    return "Isolated: " .. rt.isolated.text
  end
  if not block.enabled then
    return "Disabled"
  end
  local k, now, eng = key(slot), self:_now(), self.eng
  local t = block.type
  if t == "cooldown" then
    local last = eng:throttleLastAt(k)
    if last ~= nil and (now - last) * 1000 < block.settings.interval_ms then
      return string.format(
        "Cooling down: eligible again in %s (%d suppressed since the last pass)",
        Defs.remaining(block.settings.interval_ms / 1000 - (now - last)),
        rt.suppressed
      )
    end
    return "Ready: the next trigger passes"
  elseif t == "quiet" then
    if eng:debouncePendingFor(k) then
      return string.format(
        "Waiting for quiet: passes in %s unless another trigger arrives (%d so far)",
        Defs.remaining((rt.quiet_deadline or now) - now),
        rt.burst
      )
    end
    return "Idle"
  elseif t == "timer" then
    if rt.held ~= nil then
      return "Countdown held while the pack is read-only"
    end
    local info = eng:timerInfo(k)
    if info ~= nil then
      return "Running: expires in " .. Defs.remaining(info.expires_at - now)
    end
    return "Idle"
  elseif t == "once" then
    if eng:onceDoneToday(k) then
      return string.format("Passed today (%s); %d suppressed since", tostring(eng:onceDay(k)), rt.suppressed)
    end
    return "Ready: the next trigger passes"
  elseif t == "flag" then
    return eng:flag(k) and "On" or "Off"
  elseif t == "counter" then
    local out = self:outputs(slot)
    if block.settings.threshold ~= nil then
      return string.format(
        "Count %d — %s the threshold (%s %d)",
        out.value,
        out.active and "at" or "not at",
        block.settings.comparison,
        block.settings.threshold
      )
    end
    return string.format("Count %d", out.value)
  elseif t == "conditions" or t == "threshold" then
    if not rt.valid then
      return "Unknown: " .. (rt.fault and rt.fault.text or "an input cannot be read")
    end
    if t == "threshold" then
      local units = block.settings.units ~= "" and (" " .. block.settings.units) or ""
      return string.format("%s (last reading %s%s)", rt.last and "Active" or "Clear", tostring(rt.reading or "-"), units)
    end
    return rt.last and "True" or "False"
  elseif t == "stable" then
    if not rt.valid then
      return "Unknown: " .. (rt.fault and rt.fault.text or "the source cannot be read")
    end
    if rt.pending ~= nil then
      return string.format(
        'Holding "%s"; "%s" becomes the output in %s if it lasts',
        tostring(rt.stable),
        rt.pending,
        Defs.remaining((rt.pending_deadline or now) - now)
      )
    end
    return string.format('Stable at "%s"', tostring(rt.stable or "(nothing yet)"))
  elseif t == "selector" then
    return string.format('State "%s"', tostring(rt.state))
  end
  return ""
end

--- Everything the app shows for one slot. Plain data, safe to encode.
function Blocks:view(slot)
  local block, rt = self.blocks[slot], self.rt[slot]
  local out = self:outputs(slot)
  local view = {
    slot = slot,
    label = Defs.slotLabel(slot),
    output = out,
    status = self:statusLine(slot),
  }
  if self.unreadable[slot] ~= nil then
    view.kind = "unreadable"
    view.why = self.unreadable[slot].why
    return view
  end
  if block == nil then
    view.kind = self.retired[slot] and "retired" or "empty"
    view.retired = copy(self.retired[slot])
    return view
  end
  local now, k = self:_now(), key(slot)
  view.kind = "block"
  view.id, view.name, view.tag, view.notes = block.id, block.name, block.tag, block.notes
  view.type, view.type_label = block.type, Defs.TYPES[block.type].label
  view.enabled = block.enabled
  view.isolated = copy(rt.isolated)
  view.rev, view.created_at, view.updated_at = block.rev, block.created_at, block.updated_at
  view.explanation = Defs.explain(block)
  view.settings = Defs.settingsRows(block)
  view.wiring = Defs.wiring(block, slot)
  view.counts = copy(rt.counts)
  view.suppressed = rt.suppressed
  view.suppressed_total = rt.suppressed_total
  view.last_accepted, view.last_suppressed, view.last_refused =
    copy(rt.last_accepted), copy(rt.last_suppressed), copy(rt.last_refused)
  view.fault = copy(rt.fault)
  local info = self.eng:timerInfo(k)
  if block.type == "timer" and info ~= nil then
    view.deadline = { at = info.expires_at, remaining = math.max(0, info.expires_at - now), what = "expires" }
  elseif block.type == "quiet" and self.eng:debouncePendingFor(k) and rt.quiet_deadline ~= nil then
    view.deadline = { at = rt.quiet_deadline, remaining = math.max(0, rt.quiet_deadline - now), what = "passes" }
  elseif block.type == "cooldown" then
    local last = self.eng:throttleLastAt(k)
    if last ~= nil then
      view.last_pass_at = last
      local eligible = last + block.settings.interval_ms / 1000
      if eligible > now then
        view.deadline = { at = eligible, remaining = eligible - now, what = "eligible again" }
      end
    end
  elseif block.type == "stable" and rt.pending ~= nil then
    view.deadline = {
      at = rt.pending_deadline,
      remaining = math.max(0, (rt.pending_deadline or now) - now),
      what = 'becomes "' .. rt.pending .. '"',
    }
  elseif block.type == "once" then
    view.day = self.eng:onceDay(k)
  end
  view.sources = {}
  for _, input in ipairs(block.inputs or {}) do
    local src = rt.src[input.index] or { status = "never" }
    local wk = input.device_id ~= nil and self.watching[watchKey(input.device_id, input.variable_id)] or nil
    local row = {
      index = input.index,
      label = input.label,
      mode = input.device_id ~= nil and "variable" or "command",
      device_id = input.device_id,
      variable_id = input.variable_id,
      device_name = input.device_name,
      variable_name = input.variable_name,
      true_when = input.true_when,
      status = src.status,
      value = src.raw,
      observed_at = src.at,
      via = src.via,
      why = src.why or (wk and wk.failed) or nil,
    }
    if src.status == "never" and src.awaiting then
      row.status = "awaiting"
    end
    if block.type == "conditions" then
      local b = self:_sourceBool(slot, input)
      row.reads_as = b == nil and "unknown" or (b and "true" or "false")
    end
    if self.deps.selfDevice ~= nil and input.device_id == self.deps.selfDevice then
      local other = math.floor((input.variable_id - 4000) / 10)
      if other >= 1 and other <= Defs.SLOTS and other ~= slot then
        row.reads_block = other
      end
    end
    view.sources[#view.sources + 1] = row
  end
  if block.feedback ~= nil then
    local src = rt.fbsrc or { status = "never" }
    view.feedback = {
      device_id = block.feedback.device_id,
      variable_id = block.feedback.variable_id,
      device_name = block.feedback.device_name,
      variable_name = block.feedback.variable_name,
      expect = block.feedback.expect,
      within_ms = block.feedback.within_ms,
      status = src.status,
      value = src.raw,
      observed_at = src.at,
      why = src.why,
      waiting = rt.fb ~= nil,
    }
  end
  return view
end

--- History, newest first. filter = { slot, decision, since, limit }.
function Blocks:activity(filter)
  filter = filter or {}
  local limit = math.min(tonumber(filter.limit) or M.LIMITS.history, M.LIMITS.history)
  local out = {}
  for i = #self.history, 1, -1 do
    local e = self.history[i]
    if
      (filter.slot == nil or e.slot == filter.slot)
      and (filter.decision == nil or e.decision == filter.decision)
      and (filter.since == nil or (e.at or 0) >= filter.since)
    then
      out[#out + 1] = e
      if #out >= limit then
        break
      end
    end
  end
  return out
end

--- Slots with something to show, in slot order.
function Blocks:slots()
  local out = {}
  for slot = 1, Defs.SLOTS do
    if self.blocks[slot] ~= nil or self.retired[slot] ~= nil or self.unreadable[slot] ~= nil then
      out[#out + 1] = slot
    end
  end
  return out
end

--- Inputs that are meant to come from a device variable and do not.
function Blocks:missingMappings()
  local out = {}
  for slot, block in pairs(self.blocks) do
    if block.enabled then
      local rt = self.rt[slot]
      for _, input in ipairs(block.inputs or {}) do
        local src = rt.src[input.index]
        if input.device_id ~= nil and (src == nil or src.status == "unavailable") then
          out[#out + 1] = {
            slot = slot,
            name = block.name,
            input = input.label,
            device_id = input.device_id,
            variable_id = input.variable_id,
            why = src and src.why or "not read yet",
          }
        end
      end
      if block.feedback ~= nil and rt.fbsrc ~= nil and rt.fbsrc.status == "unavailable" then
        out[#out + 1] = {
          slot = slot,
          name = block.name,
          input = "Equipment feedback",
          device_id = block.feedback.device_id,
          variable_id = block.feedback.variable_id,
          why = rt.fbsrc.why or "cannot be read",
        }
      end
    end
  end
  table.sort(out, function(a, b)
    return a.slot < b.slot
  end)
  return out
end

M.key = key
M.fingerprint = fingerprint

return M
