--- Keypad LED state engine.
---
--- Hardware reality (see docs/control4-capabilities.md): over a BUTTON_LINK
--- binding we get exactly a two-color contract — BUTTON_COLORS {ON_COLOR,
--- OFF_COLOR} plus MATCH_LED_STATE {STATE} choosing between them. No blink
--- API exists for third parties, so "activating/countdown" feedback is a
--- bounded simulation: the engine flags `pulse=true` and the driver toggles
--- MATCH_LED_STATE on a 1 s tick ONLY while a transition/hold is live.
---
--- This module computes desired LED state and dedupes; it never talks to
--- hardware. The driver walks slots, calls compute(), and hands diffs to its
--- send function — hardware sees traffic only when something actually
--- changed (spec §17), and LED failures are the caller's to swallow (§75).

local M = {}

M.AMBER = "e6a817"
M.RED = "d02020"
M.OFF = "000000"

--- Dim a RRGGBB color for the inactive face of a followed mode. 15% keeps
--- engraved keypads legible without reading as "on".
function M.dim(hex, factor)
  factor = factor or 0.15
  local r = tonumber(hex:sub(1, 2), 16) or 0
  local g = tonumber(hex:sub(3, 4), 16) or 0
  local b = tonumber(hex:sub(5, 6), 16) or 0
  return string.format(
    "%02x%02x%02x",
    math.floor(r * factor + 0.5),
    math.floor(g * factor + 0.5),
    math.floor(b * factor + 0.5)
  )
end

--- Resolve the color a slot shows. Inheritance (spec §15): a slot configured
--- to inherit takes the mode's color, so recoloring Away repaints every
--- inheriting button; an explicit slot color wins over inheritance.
local function slotColor(slot, mode)
  local led = slot.led or {}
  if led.inherit == false and led.color then
    return led.color
  end
  return mode and mode.color or "2266dd"
end

--- Compute the desired LED for one slot.
--- @param slot table slot config {led = {follow="GLOBAL"|"MODE"|"NONE", mode_id?, color?, inherit?}, gestures}
--- @param ctx table {
---   modes,                          -- cfg.modes
---   active = {PRESENCE=id?, LIFESTYLE=id?},
---   transitioning_id,               -- mode currently counting down / executing
---   holding_slot,                   -- slot key with a live hold-confirm
---   override = {kind="warning"|"failure"} or nil (timed, driver-managed)
--- }
--- @param slotKey string
--- @return table {on_color, off_color, state, pulse}
function M.compute(slot, ctx, slotKey)
  local led = slot.led or {}
  local follow = led.follow or "NONE"

  -- Timed attention overrides (activation failed / warning) trump everything.
  if ctx.override then
    local color = ctx.override.kind == "failure" and M.RED or M.AMBER
    return { on_color = color, off_color = M.dim(color), state = 1, pulse = ctx.override.kind == "failure" }
  end

  local watchedId
  if follow == "GLOBAL" then
    watchedId = ctx.active.PRESENCE
  elseif follow == "MODE" then
    watchedId = led.mode_id
  else
    -- Not LED-managed: leave the keypad's own behavior alone. The caller
    -- must NOT send anything for a nil return.
    return nil
  end

  local mode = watchedId and ctx.modes[watchedId] or nil
  local isTransitioning = watchedId ~= nil and ctx.transitioning_id == watchedId
  local isHolding = ctx.holding_slot == slotKey

  if follow == "GLOBAL" then
    -- The HOUSE button: face is always the current presence color.
    local color = mode and slotColor(slot, mode) or "2266dd"
    local active = mode ~= nil
    if watchedId and ctx.transitioning_id and ctx.transitioning_id ~= watchedId then
      -- A different presence mode is on its way in: show ITS color, pulsing.
      local nextMode = ctx.modes[ctx.transitioning_id]
      if nextMode and nextMode.category == "PRESENCE" then
        color = nextMode.color
        return { on_color = color, off_color = M.dim(color), state = 1, pulse = true }
      end
    end
    return {
      on_color = color,
      off_color = M.dim(color),
      state = active and 1 or 0,
      pulse = isTransitioning or isHolding,
    }
  end

  -- follow == "MODE": lit when that mode is active, pulsing while it is the
  -- one transitioning or while this slot's hold-confirm is in progress.
  local color = slotColor(slot, mode)
  local isActive = mode ~= nil and (ctx.active[mode.category] == watchedId)
  return {
    on_color = color,
    off_color = M.dim(color),
    state = (isActive or isTransitioning or isHolding) and 1 or 0,
    pulse = isTransitioning or isHolding,
  }
end

--- Diff a computed state against the last-sent cache. Returns what must be
--- sent: colors when the pair changed, state when it flipped. The cache is
--- caller-owned (per slot) so a driver restart naturally resends everything
--- once — which is exactly the LED resync §49 asks for.
--- @return table {colors=boolean, state=boolean}, table newCache
function M.diff(lastSent, desired)
  lastSent = lastSent or {}
  local sendColors = lastSent.on_color ~= desired.on_color or lastSent.off_color ~= desired.off_color
  local sendState = lastSent.state ~= desired.state or sendColors
  return { colors = sendColors, state = sendState }, {
    on_color = desired.on_color,
    off_color = desired.off_color,
    state = desired.state,
  }
end

return M
