--- The activation engine: the only thing allowed to change which mode is
--- active or send device commands. Everything is dependency-injected so the
--- full lifecycle — countdown, hold-confirm, throttled execution, partial
--- failure, restore-previous, duration expiry — runs under the test shim
--- with a fake clock.
---
--- Invariants:
---   * One active mode per category; activating a Lifestyle mode never
---     touches Presence (spec §4).
---   * Re-activating the active mode is a no-op; Reapply is explicit (§47).
---   * Automatic sources (SENSOR/SCHEDULE) cannot dethrone a
---     higher-priority active mode; manual sources always can (§25).
---   * One decorative failure never fails an activation; a CRITICAL failure
---     with policy ABORT stops the queue (§46).
---   * Execution is a paced queue, never a 150-command burst (§48).
---   * Every activation carries a correlation id through results, history,
---     and events (§78).

local model = require("modes.model")

local M = {}

--- Activation sources (spec §38).
M.SOURCES = {
  KEYPAD = true,
  NAVIGATOR = true,
  COMPOSER = true,
  SENSOR = true,
  SCHEDULE = true,
  SECURITY = true,
  SMARTBUILDOS = true,
  API = true,
  RESTORE = true,
  SYSTEM = true,
}

--- Sources that count as automatic for the priority ladder.
local AUTOMATIC = { SENSOR = true, SCHEDULE = true, SECURITY = true }

--- Aggregate results (spec §110).
M.AGGREGATES = { SUCCESS = true, SUCCESS_WITH_WARNINGS = true, FAILED = true, CANCELLED = true, BLOCKED = true }

local Engine = {}
Engine.__index = Engine

--- @param deps table {
---   timer  = {set=fn(ms,cb)->h, cancel=fn(h)},
---   send   = fn(deviceId, command, params) -> ok:boolean, err:string?,
---   now    = fn() -> epoch seconds,
---   uuid   = fn() -> string,
---   emit   = fn(event, detail),      -- lifecycle: countdown_begin/cancelled,
---                                    -- activation_begin/complete/failed/warning,
---                                    -- mode_changed, delayed_result
---   buildPlan        = fn(modeId) -> plan|nil, err,
---   runPreflight     = fn(modeId) -> {checks, worst},
---   readDeviceState  = fn(device_key) -> state|nil,   -- for RESTORE capture
---   buildRestorePlan = fn(captures) -> plan,          -- captures: {device_key=state}
---   interCommandDelayMs? (default 50),
---   sensorCooldownS?     (default 10): min gap between automatic activations
---                                      of the SAME mode.
--- }
function M.new(deps)
  local self = setmetatable({}, Engine)
  self.deps = deps
  self.active = {} -- category -> mode id
  self.previous = {} -- category -> mode id
  self.activeSince = {}
  self.transitioning = nil -- {mode_id, activation_id, deadline, timer, source, meta}
  self.restoreStack = {} -- category -> {mode_id, captures}
  self.lastAutoActivation = {} -- mode id -> epoch seconds
  self.durationTimer = nil
  self.executions = 0 -- live queues (diagnostic)
  self.cfg = nil
  return self
end

function Engine:setConfig(cfg)
  self.cfg = cfg
end

function Engine:activeModes()
  return { PRESENCE = self.active.PRESENCE, LIFESTYLE = self.active.LIFESTYLE }
end

function Engine:isTransitioning()
  return self.transitioning ~= nil
end

--- Restore logical state after a restart (spec §49): believe the persisted
--- record, resync nothing to hardware. In-flight transitions do not survive
--- a restart — half-executed is worse than cancelled.
function Engine:restoreState(saved)
  saved = saved or {}
  for _, cat in ipairs({ "PRESENCE", "LIFESTYLE" }) do
    local id = saved[cat:lower() .. "_id"]
    if id and self.cfg and self.cfg.modes[id] then
      self.active[cat] = id
    end
  end
  self.activeSince.PRESENCE = saved.presence_since
  self.activeSince.LIFESTYLE = saved.lifestyle_since
end

function Engine:serializeState()
  return {
    presence_id = self.active.PRESENCE,
    lifestyle_id = self.active.LIFESTYLE,
    presence_since = self.activeSince.PRESENCE,
    lifestyle_since = self.activeSince.LIFESTYLE,
  }
end

-- ─── Activation ──────────────────────────────────────────────────────────────

--- Request an activation.
--- @param modeId string
--- @param source string one of M.SOURCES
--- @param opts table? {dry_run, skip_countdown, reapply, skip_preflight, meta={device, gesture, rule_id, ...}}
--- @return table outcome {status="DRY_RUN"|"COUNTDOWN"|"DONE"|"REFUSED", ...}
function Engine:activate(modeId, source, opts)
  opts = opts or {}
  local cfg = self.cfg
  local mode = cfg and cfg.modes[modeId]
  if not mode then
    return { status = "REFUSED", reason = "unknown mode: " .. tostring(modeId) }
  end
  if not mode.enabled then
    return { status = "REFUSED", reason = string.format("mode '%s' is disabled", mode.name) }
  end

  -- Idempotency (§47): the active mode re-requested is a quiet success.
  if self.active[mode.category] == modeId and not opts.reapply and not opts.dry_run then
    return { status = "DONE", result = "SUCCESS", noop = true, reason = "already active" }
  end

  -- Priority ladder (§25): automatic sources cannot dethrone higher priority.
  local currentId = self.active[mode.category]
  local current = currentId and cfg.modes[currentId]
  if current and AUTOMATIC[source] and (mode.priority or 0) < (current.priority or 0) then
    return {
      status = "REFUSED",
      reason = string.format(
        "'%s' (priority %d) stays: automatic %s activation of '%s' (priority %d) is outranked",
        current.name,
        current.priority or 0,
        source,
        mode.name,
        mode.priority or 0
      ),
    }
  end

  -- Cooldown for automatic sources (§25, §76): the same mode cannot be
  -- auto-activated in rapid succession even if the caller's debounce leaks.
  if AUTOMATIC[source] and not opts.dry_run then
    local last = self.lastAutoActivation[modeId]
    local cooldown = self.deps.sensorCooldownS or 10
    if last and (self.deps.now() - last) < cooldown then
      return { status = "REFUSED", reason = "cooldown: activated moments ago" }
    end
  end

  -- One transition at a time: a new request replaces a pending countdown
  -- (manual) or is refused (automatic).
  if self.transitioning and not opts.dry_run then
    if AUTOMATIC[source] then
      return { status = "REFUSED", reason = "a transition is already in progress" }
    end
    self:cancelTransition("superseded by " .. source)
  end

  local countdown = tonumber(model.effectiveTransition(cfg, modeId).countdown_s) or 0

  if countdown > 0 and not opts.skip_countdown and not opts.dry_run then
    local activationId = self.deps.uuid()
    self.transitioning = {
      mode_id = modeId,
      activation_id = activationId,
      source = source,
      meta = opts.meta,
      deadline = self.deps.now() + countdown,
    }
    self.transitioning.timer = self.deps.timer.set(countdown * 1000, function()
      local pending = self.transitioning
      self.transitioning = nil
      if pending and pending.mode_id == modeId then
        self:_execute(modeId, source, { meta = opts.meta, activation_id = activationId })
      end
    end)
    self.deps.emit(
      "countdown_begin",
      { mode_id = modeId, activation_id = activationId, seconds = countdown, source = source }
    )
    return { status = "COUNTDOWN", seconds = countdown, activation_id = activationId }
  end

  return self:_execute(modeId, source, opts)
end

--- Cancel a pending departure countdown (spec §19).
function Engine:cancelTransition(reason)
  local pending = self.transitioning
  if not pending then
    return false
  end
  self.transitioning = nil
  if pending.timer then
    self.deps.timer.cancel(pending.timer)
  end
  self.deps.emit(
    "countdown_cancelled",
    { mode_id = pending.mode_id, activation_id = pending.activation_id, reason = reason or "cancelled" }
  )
  return true
end

--- Deactivate the current Lifestyle mode (back to plain Presence living),
--- restoring captured states where the mode asked for it.
function Engine:deactivateLifestyle(source, opts)
  local id = self.active.LIFESTYLE
  if not id then
    return { status = "DONE", result = "SUCCESS", noop = true, reason = "no lifestyle mode active" }
  end
  return self:_exitLifestyle(id, source, opts or {})
end

--- Restore the previous mode in a category.
function Engine:restorePrevious(category, source)
  local prev = self.previous[category]
  if not prev or not self.cfg.modes[prev] then
    return { status = "REFUSED", reason = "no previous " .. tostring(category) .. " mode to restore" }
  end
  return self:activate(prev, source or "RESTORE", {})
end

-- ─── Internal: execution ─────────────────────────────────────────────────────

function Engine:_execute(modeId, source, opts)
  opts = opts or {}
  local cfg = self.cfg
  local mode = cfg.modes[modeId]
  local activationId = opts.activation_id or self.deps.uuid()

  -- Preflight (§28): BLOCKING refuses, WARNING rides along into the record.
  local preflight = nil
  if not opts.skip_preflight and self.deps.runPreflight then
    preflight = self.deps.runPreflight(modeId)
    if preflight.worst == "BLOCKING" and not opts.dry_run then
      local record = self:_record(modeId, source, activationId, "BLOCKED", {}, preflight, opts.meta)
      self.deps.emit("activation_blocked", record)
      return { status = "DONE", result = "BLOCKED", preflight = preflight, activation_id = activationId }
    end
  end

  local plan, err = self.deps.buildPlan(modeId)
  if not plan then
    local record = self:_record(modeId, source, activationId, "FAILED", {}, preflight, opts.meta)
    record.error = err
    self.deps.emit("activation_failed", record)
    return { status = "DONE", result = "FAILED", error = err, activation_id = activationId }
  end
  plan.activation_id = activationId

  if opts.dry_run then
    return { status = "DRY_RUN", plan = plan, preflight = preflight, activation_id = activationId }
  end

  -- Capture-for-restore BEFORE any command lands (§27): the states being
  -- captured are the ones this activation is about to destroy.
  local captures = {}
  for _, r in ipairs(plan.restores) do
    local state = self.deps.readDeviceState(r.device_key)
    if state ~= nil then
      captures[r.device_key] = state
    end
  end

  -- A Lifestyle mode replacing another Lifestyle mode restores the outgoing
  -- one's captures first, so Movie -> exit -> Party doesn't leak Movie's
  -- dimmed baseline into Party's restore.
  if mode.category == "LIFESTYLE" and self.active.LIFESTYLE and self.active.LIFESTYLE ~= modeId then
    self:_queueRestore(self.active.LIFESTYLE, "replaced by " .. mode.name)
  end

  self.deps.emit(
    "activation_begin",
    { mode_id = modeId, activation_id = activationId, source = source, actions = #plan.actions }
  )

  self:_runQueue(plan, function(results, aggregate)
    -- Commit the state change even on SUCCESS_WITH_WARNINGS: the house
    -- largely moved; refusing the label would lie to LEDs and history.
    -- A FAILED aggregate (critical abort) does NOT change the active mode.
    if aggregate ~= "FAILED" then
      self.previous[mode.category] = self.active[mode.category]
      self.active[mode.category] = modeId
      self.activeSince[mode.category] = self.deps.now()
      if next(captures) ~= nil then
        self.restoreStack[mode.category] = { mode_id = modeId, captures = captures }
      else
        self.restoreStack[mode.category] = nil
      end
      self:_armDuration(mode)
      self.deps.emit(
        "mode_changed",
        { category = mode.category, mode_id = modeId, previous = self.previous[mode.category] }
      )
    end
    local record = self:_record(modeId, source, activationId, aggregate, results, preflight, opts.meta)
    if aggregate == "FAILED" then
      self.deps.emit("activation_failed", record)
    elseif aggregate == "SUCCESS_WITH_WARNINGS" then
      self.deps.emit("activation_warning", record)
    else
      self.deps.emit("activation_complete", record)
    end
  end)

  return { status = "STARTED", activation_id = activationId, actions = #plan.actions }
end

--- Exit a lifestyle mode: restore its captures, clear the slot.
function Engine:_exitLifestyle(modeId, source, opts)
  local mode = self.cfg.modes[modeId]
  local activationId = self.deps.uuid()
  self.previous.LIFESTYLE = modeId
  self.active.LIFESTYLE = nil
  self.activeSince.LIFESTYLE = nil
  if self.durationTimer then
    self.deps.timer.cancel(self.durationTimer)
    self.durationTimer = nil
  end
  self:_queueRestore(modeId, opts.reason or ("deactivated via " .. tostring(source)))
  self.deps.emit("mode_changed", { category = "LIFESTYLE", mode_id = nil, previous = modeId })
  local record = self:_record(modeId, source, activationId, "SUCCESS", {}, nil, { exit = true })
  self.deps.emit("activation_complete", record)
  return { status = "DONE", result = "SUCCESS", activation_id = activationId, exited = mode and mode.name }
end

--- Queue the restore plan for a mode's captured states, if any.
function Engine:_queueRestore(modeId, reason)
  for _, cat in ipairs({ "LIFESTYLE", "PRESENCE" }) do
    local stack = self.restoreStack[cat]
    if stack and stack.mode_id == modeId then
      self.restoreStack[cat] = nil
      local plan = self.deps.buildRestorePlan(stack.captures)
      if plan and #plan.actions > 0 then
        plan.activation_id = self.deps.uuid()
        self.deps.emit("restore_begin", { mode_id = modeId, actions = #plan.actions, reason = reason })
        self:_runQueue(plan, function(results, aggregate)
          self.deps.emit("restore_complete", { mode_id = modeId, result = aggregate, results = results })
        end)
      end
      return
    end
  end
end

--- Arm the auto-exit timer for a Lifestyle mode with a duration (§33).
function Engine:_armDuration(mode)
  if self.durationTimer then
    self.deps.timer.cancel(self.durationTimer)
    self.durationTimer = nil
  end
  if mode.category ~= "LIFESTYLE" then
    return
  end
  local duration = tonumber(mode.duration_s) or 0
  if duration <= 0 then
    return
  end
  self.durationTimer = self.deps.timer.set(duration * 1000, function()
    self.durationTimer = nil
    if self.active.LIFESTYLE == mode.id then
      self:_exitLifestyle(mode.id, "SYSTEM", { reason = "duration expired" })
    end
  end)
end

--- Run a plan's actions as a paced queue. Immediate actions go out one per
--- interCommandDelay tick; delayed actions are grouped by their delay so the
--- timer count stays bounded regardless of plan size (§48, §107).
--- @param onComplete fn(results, aggregate) called when the IMMEDIATE batch
---        drains; delayed actions report via emit("delayed_result") (§21).
function Engine:_runQueue(plan, onComplete)
  local immediate, delayedBuckets = {}, {}
  for _, action in ipairs(plan.actions) do
    if (action.delay_s or 0) > 0 then
      local key = action.delay_s
      delayedBuckets[key] = delayedBuckets[key] or {}
      table.insert(delayedBuckets[key], action)
    else
      table.insert(immediate, action)
    end
  end

  local results = {}
  local aggregate = "SUCCESS"
  local aborted = false
  local gap = self.deps.interCommandDelayMs or 50
  self.executions = self.executions + 1

  local function runOne(action)
    if action.offline then
      -- Known-offline device: record it honestly instead of firing into
      -- the void, but only warn — plans must survive one dead shade (§132).
      return { action = action, result = "FAILED", detail = "device offline" }
    end
    local ok, err = self.deps.send(action.device_id, action.command, action.params)
    if ok then
      -- Fire-and-forget: SENT, not SUCCESS — we did not verify state (§108).
      return { action = action, result = "SENT" }
    end
    return { action = action, result = "FAILED", detail = err or "send failed" }
  end

  local function absorb(r)
    table.insert(results, r)
    if r.result == "FAILED" then
      if r.action.criticality == "CRITICAL" then
        aggregate = "FAILED"
        aborted = true
      elseif r.action.criticality ~= "OPTIONAL" and aggregate == "SUCCESS" then
        aggregate = "SUCCESS_WITH_WARNINGS"
      end
    end
  end

  -- Stage delays (SEQUENCED choreography) run INSIDE the tracked queue so
  -- their failures still shape the aggregate; elapsedMs tracks how far into
  -- the choreography the queue is.
  local index = 0
  local elapsedMs = 0
  local function step()
    index = index + 1
    local action = immediate[index]
    if action == nil or aborted then
      if aborted then
        for i = index, #immediate do
          table.insert(
            results,
            { action = immediate[i], result = "SKIPPED", detail = "aborted after critical failure" }
          )
        end
      end
      self.executions = self.executions - 1
      -- Delayed buckets still fire unless the run aborted.
      if not aborted then
        for delay, bucket in pairs(delayedBuckets) do
          self.deps.timer.set(delay * 1000, function()
            for _, a in ipairs(bucket) do
              local r = runOne(a)
              self.deps.emit(
                "delayed_result",
                { activation_id = plan.activation_id, action = a, result = r.result, detail = r.detail }
              )
            end
          end)
        end
      end
      onComplete(results, aggregate)
      return
    end
    local notBefore = (tonumber(action.stage_delay_s) or 0) * 1000
    if notBefore > elapsedMs then
      local wait = notBefore - elapsedMs
      elapsedMs = notBefore
      index = index - 1 -- re-enter on this action after the stage gap
      self.deps.timer.set(wait, step)
      return
    end
    absorb(runOne(action))
    if aborted then
      step() -- flush the skip records and finish
      return
    end
    if immediate[index + 1] == nil then
      step() -- no need to wait a tick to finish
      return
    end
    elapsedMs = elapsedMs + gap
    self.deps.timer.set(gap, step)
  end
  step()
end

function Engine:_record(modeId, source, activationId, aggregate, results, preflight, meta)
  local failures, warnings, sent = {}, 0, 0
  for _, r in ipairs(results) do
    if r.result == "FAILED" then
      table.insert(failures, { device = r.action.device_name or r.action.device_key, detail = r.detail })
    elseif r.result == "SENT" or r.result == "SUCCESS" then
      sent = sent + 1
    end
  end
  if preflight then
    for _, check in ipairs(preflight.checks) do
      if check.outcome ~= "OK" then
        warnings = warnings + 1
      end
    end
  end
  return {
    mode_id = modeId,
    activation_id = activationId,
    source = source,
    meta = meta,
    time = self.deps.now(),
    result = aggregate,
    actions = #results,
    succeeded = sent,
    failures = failures,
    preflight_warnings = warnings,
    previous_presence = self.previous.PRESENCE,
    previous_lifestyle = self.previous.LIFESTYLE,
  }
end

return M
