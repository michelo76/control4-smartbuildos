--- Deterministic keypad gesture recognition.
---
--- BUTTON_LINK guarantees only three raw events — DO_PUSH, DO_CLICK,
--- DO_RELEASE — and the official docs warn that multi-click seldom rides the
--- link, so every tap/double/triple/hold decision is made HERE, from timing,
--- by one small state machine per keypad slot. Determinism rules:
---
---   * A tap NEVER fires while a higher tap count is still possible on this
---     slot: with double-tap assigned, the first release waits out the
---     double-tap window; with nothing higher assigned, it fires instantly.
---   * Hold tiers resolve on RELEASE to the highest threshold crossed —
---     firing at each crossing would run the 1 s action on the way to the
---     3 s one. Exception: when exactly ONE hold tier is assigned and no
---     higher-count taps compete, it fires AT the crossing (classic
---     hold-to-confirm — the finger is still on the button).
---   * A missing DO_RELEASE (Director busy — the documented "runaway hold")
---     cancels after RUNAWAY_MS instead of firing anything.
---
--- The machine is scheduler-injected: `opts.timer = {set(ms, cb) -> handle,
--- cancel(handle)}`. Tests hand in a fake clock and step it; the driver hands
--- in a wrapper over the house named-timer lib. No os.time, no C4 calls.

local M = {}

--- Gesture names, in the order the resolver considers them.
M.TAP_GESTURES = { "tap", "double_tap", "triple_tap" }
M.HOLD_GESTURES = { "hold", "long_hold", "very_long_hold" }

--- Default timing (spec §13). All overridable per slot; a normal install
--- never needs to touch them.
M.DEFAULTS = {
  tap_window_ms = 500, -- wait after a tap for another, while a higher count is assigned
  hold_ms = 1000,
  long_hold_ms = 3000,
  very_long_hold_ms = 5000,
  runaway_ms = 30000, -- push with no release: cancel, fire nothing
}

local FSM = {}
FSM.__index = FSM

--- @param opts table {
---   assigned = {tap=true, double_tap=true, ...},  -- gestures mapped on this slot
---   timing   = {} overrides of M.DEFAULTS,
---   timer    = {set=fn(ms,cb)->handle, cancel=fn(handle)},
---   emit     = fn(gesture, detail),               -- resolved gesture
---   progress = fn(kind, detail) or nil,           -- hold_start/hold_tier/hold_cancel for LED feedback
--- }
function M.new(opts)
  local self = setmetatable({}, FSM)
  self.timing = {}
  for k, v in pairs(M.DEFAULTS) do
    self.timing[k] = (opts.timing and opts.timing[k]) or v
  end
  self.assigned = opts.assigned or {}
  self.timer = opts.timer
  self.emit = opts.emit or function() end
  self.progress = opts.progress or function() end
  self:reset()
  return self
end

--- Full reset: config reload, mode switch mid-gesture, driver restart. Any
--- in-flight gesture is abandoned silently — half a gesture must never fire.
function FSM:reset()
  if self.tapTimer then
    self.timer.cancel(self.tapTimer)
    self.tapTimer = nil
  end
  self:_cancelHoldTimers()
  self.tapCount = 0
  self.held = false
  self.heldTier = nil
  self.suppressRelease = false
end

--- Update which gestures are assigned (the resolver's early-exit rules
--- depend on it). Resets in-flight state.
function FSM:setAssigned(assigned)
  self.assigned = assigned or {}
  self:reset()
end

-- ── Internal helpers ─────────────────────────────────────────────────────────

function FSM:_cancelHoldTimers()
  for _, h in ipairs(self.holdTimers or {}) do
    self.timer.cancel(h)
  end
  self.holdTimers = {}
end

--- Highest tap gesture assigned above `count` taps — decides whether to wait.
function FSM:_higherTapAssigned(count)
  if count < 2 and (self.assigned.double_tap or self.assigned.triple_tap) then
    return true
  end
  if count < 3 and self.assigned.triple_tap then
    return true
  end
  return false
end

local TAP_BY_COUNT = { "tap", "double_tap", "triple_tap" }

--- Resolve an accumulated tap count into the best assigned gesture at or
--- below it. Four rapid taps resolve as triple_tap (highest assigned), and a
--- double on a slot with only `tap` assigned degrades to tap — a configured
--- action beats firing nothing.
function FSM:_resolveTaps()
  local count = math.min(self.tapCount, 3)
  self.tapCount = 0
  for c = count, 1, -1 do
    local g = TAP_BY_COUNT[c]
    if self.assigned[g] then
      self.emit(g, { taps = count })
      return
    end
  end
end

function FSM:_holdTiers()
  local tiers = {}
  if self.assigned.hold then
    table.insert(tiers, { name = "hold", ms = self.timing.hold_ms })
  end
  if self.assigned.long_hold then
    table.insert(tiers, { name = "long_hold", ms = self.timing.long_hold_ms })
  end
  if self.assigned.very_long_hold then
    table.insert(tiers, { name = "very_long_hold", ms = self.timing.very_long_hold_ms })
  end
  return tiers
end

--- Fire-at-crossing applies only when this press cannot be anything else:
--- one hold tier assigned, and no pending tap sequence in flight.
function FSM:_fireAtCrossing()
  local tiers = self:_holdTiers()
  return #tiers == 1 and self.tapCount == 0
end

-- ── Raw events from ReceivedFromProxy ────────────────────────────────────────

--- DO_PUSH: the button went down. Starts hold tracking.
function FSM:push()
  if self.held then
    return -- duplicate PUSH without RELEASE: keep the original press
  end
  self.held = true
  self.heldTier = nil
  self.suppressRelease = false
  self:_cancelHoldTimers()

  local fireAtCrossing = self:_fireAtCrossing()
  for _, tier in ipairs(self:_holdTiers()) do
    local t = tier
    table.insert(
      self.holdTimers,
      self.timer.set(t.ms, function()
        if not self.held then
          return
        end
        self.heldTier = t.name
        self.progress("hold_tier", { tier = t.name })
        if fireAtCrossing then
          -- Classic hold-to-confirm: fire now, swallow the coming release.
          self.suppressRelease = true
          self.held = false
          self:_cancelHoldTimers()
          self.emit(t.name, { at_crossing = true })
        end
      end)
    )
  end
  -- Runaway guard: a release that never comes cancels everything.
  table.insert(
    self.holdTimers,
    self.timer.set(self.timing.runaway_ms, function()
      if self.held then
        self.held = false
        self.heldTier = nil
        self.suppressRelease = true
        self:_cancelHoldTimers()
        self.tapCount = 0
        self.progress("hold_cancel", { reason = "runaway" })
      end
    end)
  )
  if #self:_holdTiers() > 0 then
    self.progress("hold_start", {})
  end
end

--- DO_RELEASE: the button came up. Resolves a hold, or becomes a tap.
function FSM:release()
  if self.suppressRelease then
    self.suppressRelease = false
    return
  end
  if not self.held then
    return -- release without push (already resolved, or restart mid-press)
  end
  self.held = false
  self:_cancelHoldTimers()

  if self.heldTier then
    local tier = self.heldTier
    self.heldTier = nil
    self.tapCount = 0
    self.emit(tier, {})
    return
  end
  if #self:_holdTiers() > 0 then
    self.progress("hold_cancel", { reason = "released_early" })
  end
  self:_tap()
end

--- DO_CLICK: some keypads send this instead of (or as well as) the
--- PUSH/RELEASE pair. A CLICK while we are tracking a live press is
--- redundant with the RELEASE that follows; a bare CLICK is a tap.
function FSM:click()
  if self.held or self.suppressRelease then
    return
  end
  self:_tap()
end

function FSM:_tap()
  self.tapCount = self.tapCount + 1
  if self.tapTimer then
    self.timer.cancel(self.tapTimer)
    self.tapTimer = nil
  end
  if not self:_higherTapAssigned(self.tapCount) then
    self:_resolveTaps()
    return
  end
  self.tapTimer = self.timer.set(self.timing.tap_window_ms, function()
    self.tapTimer = nil
    self:_resolveTaps()
  end)
end

return M
