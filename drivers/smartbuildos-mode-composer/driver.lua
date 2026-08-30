--- SmartBuildOS Mode Composer — Mode Manager.
---
--- One instance per project. This driver is the single source of truth for
--- house modes: it owns the configuration, the activation engine, keypad
--- gesture recognition, LED feedback, sensor rules, schedules, and history.
--- Mode Button children (smartbuildos-mode-button.c4z) are UI satellites —
--- they render and request, never decide (spec §115).
---
--- The heavy logic lives in src/modes/* — pure, dependency-injected modules
--- with their own test suites. This file is the wiring: C4 surface in,
--- engine deps out. Keep decisions OUT of this file where possible.

DRIVER_GITHUB_REPO = "michelo76/control4-smartbuildos"
DRIVER_FILENAMES = { "smartbuildos-mode-composer.c4z" }

require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")

JSON = require("JSON")

local log = require("lib.logging")
local persist = require("lib.persist")
local bindings = require("lib.bindings")
local license = require("sbos.license")
local model = require("modes.model")
local store = require("modes.store")
local adapters = require("modes.adapters")
local planner = require("modes.plan")
local enginelib = require("modes.engine")
local gesturelib = require("modes.gesture")
local ledlib = require("modes.led")
local triggerslib = require("modes.triggers")
local historylib = require("modes.history")
local schedule = require("modes.schedule")
local lru = require("lib.lru")

-- ─── Constants ───────────────────────────────────────────────────────────────

local SKU = "SBOS_MODE_COMPOSER"

--- Persist keys. Config + history + active state each have their own key so
--- one write never risks another's data.
local USER_CODE_KEY = "ModeComposerUserCode" -- encrypted
local CHILDREN_KEY = "ModeComposerChildren"
local SCHEDULE_MARK_KEY = "ModeComposerScheduleMark"

local SLOT_NS = "slot" -- lib.bindings namespace for keypad BUTTON_LINK slots
local MAX_SLOTS = 30

local SCHEDULE_TIMER = "McScheduleTick"
local PULSE_TIMER = "McLedPulse"
local CONFIRM_TIMER = "McNavigatorConfirm"

--- Color names offered in Composer -> RRGGBB. The model stores hex; names
--- are a Composer convenience only.
local COLOR_NAMES = {
  ["Green"] = "22aa44",
  ["Blue"] = "2266dd",
  ["Deep Blue"] = "223399",
  ["Purple"] = "8844cc",
  ["Amber"] = "dd9922",
  ["Magenta"] = "cc2288",
  ["Red"] = "d02020",
  ["Orange"] = "ee7722",
  ["White"] = "e8e8e8",
  ["Cyan"] = "22aaaa",
}

local KIND_BY_TYPE_PROPERTY = {
  ["Home"] = "HOME",
  ["Away"] = "AWAY",
  ["Vacation"] = "VACATION",
  ["Sleep"] = "SLEEP",
  ["Movie"] = "MOVIE",
  ["Party"] = "PARTY",
  ["Morning"] = "MORNING",
  ["Night"] = "NIGHT",
  ["Custom Lifestyle"] = "CUSTOM",
  ["Custom Presence"] = "CUSTOM",
}

--- Variables re-added at every init (the XML set registers only at
--- instance-add; measured on the Agent). ORDER IS CONTRACTUAL — Composer
--- programming binds computed ids. Append only.
local VARIABLES = {
  { "CURRENT_PRESENCE_MODE", "", "STRING" },
  { "CURRENT_LIFESTYLE_MODE", "", "STRING" },
  { "PREVIOUS_PRESENCE_MODE", "", "STRING" },
  { "PREVIOUS_LIFESTYLE_MODE", "", "STRING" },
  { "TRANSITIONING", "false", "BOOL" },
  { "CURRENT_MODE_ID", "", "STRING" },
  { "LAST_TRIGGER", "", "STRING" },
  { "LAST_TRIGGER_DEVICE", "", "STRING" },
  { "LAST_TRIGGER_TYPE", "", "STRING" },
  { "LAST_ACTIVATION_TIME", "", "STRING" },
  { "LAST_ACTIVATION_RESULT", "", "STRING" },
  { "OCCUPANCY_STATE", "UNKNOWN", "STRING" },
  { "WARNING_COUNT", "0", "NUMBER" },
}

--- Static events (ids frozen; must match driver.xml).
local EVENTS = {
  { 1, "Presence Mode Changed", "The active Presence mode changed." },
  { 2, "Lifestyle Mode Changed", "The active Lifestyle mode changed." },
  { 3, "Activation Started", "A mode activation began executing." },
  { 4, "Activation Completed", "A mode activation completed successfully." },
  { 5, "Activation Failed", "A mode activation failed." },
  { 6, "Activation Blocked", "Preflight blocked a mode activation." },
  { 7, "Departure Countdown Started", "A departure countdown began." },
  { 8, "Departure Countdown Cancelled", "A departure countdown was cancelled." },
  { 9, "Activation Warning", "A mode activation completed with failures." },
}
--- Dynamic per-mode events allocate ids from here (below the lib.events
--- range is fine because that lib is unused in this driver).
local MODE_EVENT_ID_START = 100

-- ─── Globals (g-prefixed so handlers and gen-squishy can see them) ───────────

gInitialized = false
gConfig = nil -- the store envelope
gConfigReadOnly = false
gEngine = nil
gTriggers = nil
gHistory = nil
gGestures = {} -- slotKey -> FSM
gLedCache = {} -- slotKey -> last-sent {on_color, off_color, state}
gLedPulsePhase = false
gLedOverrides = {} -- slotKey -> {kind, until_s}
gHoldingSlot = nil -- slot with a live hold (LED feedback)
gDeviceIndex = nil -- [tostring(deviceId)] = {id, name, roomId, roomName, driverFileName}
gRooms = {} -- [tostring(roomId)] = roomName
gVarsCache = nil -- LRU deviceId -> vars map
gSelectedModeId = nil
gSelectedSlotKey = nil
gChildIds = {} -- deviceIds of mode-button children that talked to us
gPendingConfirm = nil -- {mode_id, deadline} for navigator hold-to-confirm
gLastActivationRecord = nil
gWarningCount = 0
gLastScheduleCheck = 0
gTimerSeq = 0

-- Forward declarations (assigned later; the comment convention of this repo:
-- these exist so earlier code can call later definitions).
local saveConfig
local paintModeLists
local paintSelectedMode
local paintSelectedSlot
local syncLeds
local rebuildGestures
local registerTriggerListeners
local pushStateToChildren
local activateFromSurface

-- ─── Small helpers ───────────────────────────────────────────────────────────

local persistAdapter = {
  get = function(key, default)
    local v = persist:get(key, default)
    return v
  end,
  set = function(key, value)
    persist:set(key, value)
  end,
}

local function newUuid()
  gTimerSeq = gTimerSeq + 1
  return string.format("%x%04x%x", os.time(), math.random(0, 0xffff), gTimerSeq)
end

--- Engine/gesture timer facility over the house named-timer lib. One-shot.
local timerFacility = {
  set = function(ms, cb)
    gTimerSeq = gTimerSeq + 1
    local id = "McT" .. gTimerSeq
    SetTimer(id, math.max(1, math.floor(ms)), function()
      cb()
    end, false)
    return id
  end,
  cancel = function(id)
    if id then
      CancelTimer(id)
    end
  end,
}

local function modeName(modeId)
  local mode = gConfig and gConfig.modes[modeId]
  return mode and mode.name or (modeId and tostring(modeId) or "")
end

local function formatTime(epoch)
  return os.date("%Y-%m-%d %H:%M:%S", epoch)
end

--- Mode names ride comma-separated Composer LIST properties, so commas are
--- stripped at the door.
local function sanitizeName(name)
  name = tostring(name or ""):gsub(",", " "):gsub("^%s+", ""):gsub("%s+$", "")
  return name
end

--- Config writes are the one thing licensing may refuse (spec §57 + the
--- charter: a house keeps RUNNING; a definitively unlicensed driver stops
--- being reconfigurable). Activations are operational and never gated.
local function refuseIfEnforced(what)
  if license.enforces() then
    log:print("Refused: %s — %s", what, license.enforcementReason())
    return true
  end
  return false
end

-- ─── Device index + resolution ───────────────────────────────────────────────

local function refreshDeviceIndex()
  log:trace("refreshDeviceIndex()")
  local devices = C4:GetDevices({}) or {}
  gDeviceIndex = {}
  gRooms = {}
  for id, info in pairs(devices) do
    gDeviceIndex[tostring(id)] = {
      id = tonumber(id),
      name = info.deviceName or ("Device " .. tostring(id)),
      roomId = info.roomId,
      roomName = info.roomName,
      driverFileName = info.driverFileName,
    }
    if info.roomId and info.roomName then
      gRooms[tostring(info.roomId)] = info.roomName
    end
  end
end

local function readVars(deviceId)
  gVarsCache = gVarsCache or lru:new(400, 5)
  return gVarsCache:getOrSet(tostring(deviceId), function()
    local vars = {}
    local ok, raw = pcall(function()
      return C4:GetDeviceVariables(deviceId)
    end)
    if ok and type(raw) == "table" then
      for _, v in pairs(raw) do
        if type(v) == "table" and v.name ~= nil then
          vars[v.name] = v.value
        end
      end
    end
    return vars
  end)
end

--- A crude proxy hint from the driver filename — classification pass 1.
--- Pass 2 (variable signatures) is the real workhorse; this only helps the
--- unambiguous cases (blind/lock/tstat driver names).
local function proxyHint(fileName)
  local f = tostring(fileName or ""):lower()
  if f:find("blind") or f:find("shade") then
    return "blind"
  end
  if f:find("lock") then
    return "lock"
  end
  if f:find("thermostat") or f:find("tstat") then
    return "thermostat"
  end
  if f:find("garage") then
    return "garagedoor"
  end
  if f:find("securitypanel") or f:find("security_panel") then
    return "securitypanel"
  end
  if f:find("fan") then
    return "fan"
  end
  return nil
end

--- Resolve a device key ("<id>" or "room:<id>") to the shape plan.build and
--- the adapters expect. Returns nil for devices gone from the project.
local function resolveDevice(deviceKey)
  local key = tostring(deviceKey)
  local roomId = key:match("^room:(%d+)$")
  if roomId then
    local name = gRooms[roomId]
    if not name then
      refreshDeviceIndex()
      name = gRooms[roomId]
    end
    if not name then
      return nil
    end
    return {
      id = tonumber(roomId),
      name = name .. " (room)",
      isRoom = true,
      vars = readVars(tonumber(roomId)),
      online = true,
      adapter = adapters.ADAPTERS.ROOM,
    }
  end
  if gDeviceIndex == nil or gDeviceIndex[key] == nil then
    refreshDeviceIndex()
  end
  local entry = gDeviceIndex[key]
  if not entry then
    return nil
  end
  local vars = readVars(entry.id)
  local info = {
    proxy = proxyHint(entry.driverFileName),
    vars = vars,
    deviceName = entry.name,
    driverFileName = entry.driverFileName,
  }
  return {
    id = entry.id,
    name = entry.name,
    room = entry.roomName,
    proxy = info.proxy,
    vars = vars,
    online = true, -- link state is not free to know per-device; failures report per action
    adapter = adapters.classify(info),
  }
end

local planDeps = {
  resolve = resolveDevice,
  secrets = {},
}
setmetatable(planDeps.secrets, {
  __index = function(_, k)
    if k == "security_user_code" then
      return persist:get(USER_CODE_KEY, "", true)
    end
    return nil
  end,
})

local function buildRestorePlan(captures)
  local rp = {
    mode_name = "restore previous",
    transition = { style = "IMMEDIATE", countdown_s = 0, sequence = {} },
    actions = {},
    restores = {},
    unsupported = {},
    missing = {},
    summary = { by_class = {}, total = 0 },
  }
  for key, state in pairs(captures) do
    local device = resolveDevice(key)
    if device then
      local cmds = device.adapter.plan(state)
      for _, cmd in ipairs(cmds or {}) do
        table.insert(rp.actions, {
          device_key = key,
          device_id = device.id,
          device_name = device.name,
          class = device.adapter.class,
          command = cmd.command,
          params = cmd.params,
          delay_s = 0,
          criticality = "NORMAL",
          describe = device.adapter.describe(state),
        })
      end
    end
  end
  rp.summary.total = #rp.actions
  return rp
end

-- ─── Dynamic per-mode Composer events ────────────────────────────────────────

local function modeEventIds()
  gConfig.settings.event_ids = gConfig.settings.event_ids or {}
  return gConfig.settings.event_ids
end

local function ensureModeEvent(mode)
  local ids = modeEventIds()
  if not ids[mode.id] then
    local used = {}
    for _, id in pairs(ids) do
      used[id] = true
    end
    local nextId = MODE_EVENT_ID_START
    while used[nextId] do
      nextId = nextId + 1
    end
    ids[mode.id] = nextId
  end
  pcall(function()
    C4:AddEvent(ids[mode.id], mode.name .. " Activated", "Mode '" .. mode.name .. "' became active.")
  end)
  return ids[mode.id]
end

local function fireModeEvent(modeId)
  local id = modeEventIds()[modeId]
  if id then
    pcall(function()
      C4:FireEventByID(id)
    end)
  end
end

-- ─── Variables ───────────────────────────────────────────────────────────────

local function setVar(name, value)
  pcall(function()
    C4:SetVariable(name, tostring(value))
  end)
end

local function refreshStateSurface()
  local active = gEngine:activeModes()
  local presence = modeName(active.PRESENCE)
  local lifestyle = modeName(active.LIFESTYLE)
  setVar("CURRENT_PRESENCE_MODE", presence)
  setVar("CURRENT_LIFESTYLE_MODE", lifestyle)
  setVar("PREVIOUS_PRESENCE_MODE", modeName(gEngine.previous.PRESENCE))
  setVar("PREVIOUS_LIFESTYLE_MODE", modeName(gEngine.previous.LIFESTYLE))
  setVar("TRANSITIONING", gEngine:isTransitioning() and "true" or "false")
  setVar("CURRENT_MODE_ID", active.PRESENCE or "")
  setVar("OCCUPANCY_STATE", gTriggers:occupancy(gConfig.modes).state)
  setVar("WARNING_COUNT", gWarningCount)
  UpdateProperty("Presence Mode", presence)
  UpdateProperty("Lifestyle Mode", lifestyle ~= "" and lifestyle or "-")
end

-- ─── LED engine wiring ───────────────────────────────────────────────────────

local function slotBindingId(slotKey)
  local binding = bindings:getDynamicBinding(SLOT_NS, slotKey)
  return binding and binding.bindingId or nil
end

local function sendLed(bindingId, desired)
  -- LED writes are presentation: every failure is swallowed after logging
  -- (spec §75 — a dead keypad must never block a mode).
  local ok, err = pcall(function()
    SendToProxy(bindingId, "BUTTON_COLORS", {
      ON_COLOR = { COLOR_STR = desired.on_color },
      OFF_COLOR = { COLOR_STR = desired.off_color },
    }, "NOTIFY")
    SendToProxy(bindingId, "MATCH_LED_STATE", { STATE = desired.state == 1 and "1" or "0" }, "NOTIFY")
  end)
  if not ok then
    log:warn("LED update failed on binding %s: %s", bindingId, err)
  end
end

--- Recompute every managed slot's LED and send only real changes (§17).
syncLeds = function()
  local anyPulse = false
  local ctx = {
    modes = gConfig.modes,
    active = gEngine:activeModes(),
    transitioning_id = gEngine.transitioning and gEngine.transitioning.mode_id or nil,
    holding_slot = gHoldingSlot,
  }
  for slotKey, slot in pairs(gConfig.slots or {}) do
    local bindingId = slotBindingId(slotKey)
    if bindingId then
      ctx.override = gLedOverrides[slotKey]
      if ctx.override and ctx.override.until_s and ctx.override.until_s < os.time() then
        gLedOverrides[slotKey] = nil
        ctx.override = nil
      end
      local desired = ledlib.compute(slot, ctx, slotKey)
      ctx.override = nil
      if desired then
        anyPulse = anyPulse or desired.pulse
        local shown = { on_color = desired.on_color, off_color = desired.off_color, state = desired.state }
        if desired.pulse and gLedPulsePhase then
          shown.state = shown.state == 1 and 0 or 1
        end
        local diff, newCache = ledlib.diff(gLedCache[slotKey], shown)
        if diff.colors or diff.state then
          sendLed(bindingId, shown)
          gLedCache[slotKey] = newCache
        end
      end
    end
  end
  -- The bounded pulse simulation (§16): one 1 s timer, alive only while
  -- something is actually pulsing.
  if anyPulse then
    SetTimer(PULSE_TIMER, ONE_SECOND, function()
      gLedPulsePhase = not gLedPulsePhase
      syncLeds()
    end, false)
  else
    CancelTimer(PULSE_TIMER)
    gLedPulsePhase = false
  end
end

-- ─── Keypad slots + gestures ─────────────────────────────────────────────────

local function slotByBindingId(bindingId)
  for slotKey in pairs(gConfig.slots or {}) do
    if slotBindingId(slotKey) == bindingId then
      return slotKey, gConfig.slots[slotKey]
    end
  end
  return nil
end

--- Execute a resolved gesture on a slot.
local function runSlotAction(slotKey, gesture, detail)
  local slot = gConfig.slots[slotKey]
  local g = slot and slot.gestures and slot.gestures[gesture]
  if not g or not g.action or g.action == "NONE" then
    return
  end
  local meta = { slot_name = slot.name or slotKey, gesture = gesture }
  if detail and detail.at_crossing then
    meta.hold_s = nil -- crossing fire: duration equals the configured threshold
  end
  if g.action == "ACTIVATE" and g.mode_id then
    -- A press for the mode already counting down cancels it (spec §19).
    if gEngine.transitioning and gEngine.transitioning.mode_id == g.mode_id then
      gEngine:cancelTransition("cancelled from " .. (slot.name or slotKey))
      return
    end
    activateFromSurface(g.mode_id, "KEYPAD", meta)
  elseif g.action == "DEACTIVATE_LIFESTYLE" then
    gEngine:deactivateLifestyle("KEYPAD", {})
  elseif g.action == "RESTORE_PREVIOUS" then
    gEngine:restorePrevious("PRESENCE", "KEYPAD")
  elseif g.action == "CANCEL_TRANSITION" then
    gEngine:cancelTransition("cancelled from " .. (slot.name or slotKey))
  end
end

--- (Re)build one slot's gesture FSM from its configuration.
local function buildGesture(slotKey)
  local slot = gConfig.slots[slotKey]
  if not slot then
    gGestures[slotKey] = nil
    return
  end
  local assigned = {}
  for gesture, g in pairs(slot.gestures or {}) do
    if g.action and g.action ~= "NONE" then
      assigned[gesture] = true
    end
  end
  local s = gConfig.settings
  gGestures[slotKey] = gesturelib.new({
    assigned = assigned,
    timing = {
      tap_window_ms = tonumber(s.tap_window_ms) or nil,
      hold_ms = (tonumber(s.hold_s) or 1) * 1000,
      long_hold_ms = (tonumber(s.long_hold_s) or 3) * 1000,
      very_long_hold_ms = (tonumber(s.very_long_hold_s) or 5) * 1000,
    },
    timer = timerFacility,
    emit = function(gesture, detail)
      log:debug("slot %s gesture %s", slotKey, gesture)
      runSlotAction(slotKey, gesture, detail)
    end,
    progress = function(kind)
      if kind == "hold_start" then
        gHoldingSlot = slotKey
      elseif kind == "hold_cancel" then
        gHoldingSlot = nil
      end
      syncLeds()
    end,
  })
end

rebuildGestures = function()
  gGestures = {}
  for slotKey in pairs(gConfig.slots or {}) do
    buildGesture(slotKey)
  end
end

local function addKeypadSlot()
  local n = 0
  for _ in pairs(gConfig.slots or {}) do
    n = n + 1
  end
  if n >= MAX_SLOTS then
    log:print("Refused: %d keypad slots already exist", n)
    return nil
  end
  local index = (tonumber(gConfig.settings.slot_seq) or 0) + 1
  gConfig.settings.slot_seq = index
  local slotKey = "slot_" .. index
  local name = "Keypad Slot " .. index
  bindings:getOrAddDynamicBinding(SLOT_NS, slotKey, "CONTROL", false, name, "BUTTON_LINK")
  gConfig.slots[slotKey] = { name = name, gestures = {}, led = { follow = "NONE" } }
  buildGesture(slotKey)
  saveConfig()
  paintSelectedSlot()
  log:print("Added '%s' — bind a keypad button's Button Link to it in Connections, then map gestures.", name)
  return slotKey
end

--- Raw BUTTON_LINK traffic → the slot's FSM.
local function slotRaw(idBinding, what)
  local slotKey = slotByBindingId(idBinding)
  if not slotKey then
    return
  end
  local fsm = gGestures[slotKey]
  if not fsm then
    return
  end
  if what == "push" then
    fsm:push()
  elseif what == "release" then
    fsm:release()
    if gHoldingSlot == slotKey then
      gHoldingSlot = nil
      syncLeds()
    end
  else
    fsm:click()
  end
end

RFP.DO_PUSH = function(idBinding)
  slotRaw(idBinding, "push")
end
RFP.DO_RELEASE = function(idBinding)
  slotRaw(idBinding, "release")
end
RFP.DO_CLICK = function(idBinding)
  slotRaw(idBinding, "click")
end
RFP.REQUEST_BUTTON_COLORS = function(idBinding)
  local slotKey = slotByBindingId(idBinding)
  if slotKey then
    gLedCache[slotKey] = nil -- force a full resend for this button
    syncLeds()
  end
end

-- ─── Activation surface (shared by keypad / navigator / composer) ────────────

activateFromSurface = function(modeId, source, meta)
  local mode = gConfig.modes[modeId]
  if not mode then
    log:print("Unknown mode id %s", tostring(modeId))
    return
  end
  -- Navigator hold-to-confirm (§18): keypad HOLD gestures are already
  -- deliberate; taps from Navigator/Composer on a confirm-guarded mode need
  -- a second tap inside 10 s.
  local needsConfirm = (tonumber(mode.confirm_hold_s) or 0) > 0 and source == "NAVIGATOR"
  if needsConfirm then
    if not (gPendingConfirm and gPendingConfirm.mode_id == modeId and os.time() <= gPendingConfirm.deadline) then
      gPendingConfirm = { mode_id = modeId, deadline = os.time() + 10 }
      SetTimer(CONFIRM_TIMER, 10 * ONE_SECOND, function()
        gPendingConfirm = nil
        pushStateToChildren()
      end, false)
      log:print("'%s' needs confirmation: tap it again within 10 seconds.", mode.name)
      pcall(function()
        ShowPopupEverywhere(string.format("Tap %s again to confirm", mode.name), "OK", 5)
      end)
      pushStateToChildren()
      return
    end
    gPendingConfirm = nil
  end
  local outcome = gEngine:activate(modeId, source, { meta = meta })
  if outcome.status == "REFUSED" then
    log:print("Activation refused: %s", tostring(outcome.reason))
  elseif outcome.noop then
    log:debug("'%s' already active", mode.name)
  end
  return outcome
end

-- ─── Children (Navigator mode buttons) ───────────────────────────────────────

local function childStatePayload()
  local active = gEngine:activeModes()
  local list = {}
  for _, mode in ipairs(model.orderedModes(gConfig)) do
    table.insert(list, {
      id = mode.id,
      name = mode.name,
      icon = mode.icon,
      color = mode.color,
      category = mode.category,
      active = (active[mode.category] == mode.id),
      transitioning = (gEngine.transitioning and gEngine.transitioning.mode_id == mode.id) or nil,
      pending_confirm = (gPendingConfirm and gPendingConfirm.mode_id == mode.id) or nil,
    })
  end
  return { modes = JSON:encode(list) }
end

pushStateToChildren = function()
  local payload = childStatePayload()
  for childId in pairs(gChildIds) do
    pcall(function()
      SendToDevice(childId, "MC_STATE", payload)
    end)
  end
end

local function rememberChild(requester)
  local id = tonumber(requester)
  if id and not gChildIds[id] then
    gChildIds[id] = true
    persist:set(CHILDREN_KEY, gChildIds)
  end
end

EC.MC_GET_STATE = function(tParams)
  local requester = tonumber(tParams and tParams.requester)
  if not requester then
    return
  end
  rememberChild(requester)
  pcall(function()
    SendToDevice(requester, "MC_STATE", childStatePayload())
  end)
end

EC.MC_SELECT = function(tParams)
  local modeId = tParams and tParams.mode_id
  if not modeId or not gConfig.modes[modeId] then
    return
  end
  rememberChild(tParams.requester)
  local mode = gConfig.modes[modeId]
  if mode.category == "LIFESTYLE" and gEngine:activeModes().LIFESTYLE == modeId then
    -- Tapping the active lifestyle button exits it (natural toggle).
    gEngine:deactivateLifestyle("NAVIGATOR", {})
    return
  end
  activateFromSurface(modeId, "NAVIGATOR", { device = tParams.requester })
end

-- ─── Engine construction ─────────────────────────────────────────────────────

local function onEngineEvent(name, detail)
  log:debug("engine event %s", name)
  if name == "mode_changed" then
    if detail.category == "PRESENCE" then
      pcall(function()
        C4:FireEventByID(1)
      end)
    else
      pcall(function()
        C4:FireEventByID(2)
      end)
    end
    if detail.mode_id then
      fireModeEvent(detail.mode_id)
    end
    store.saveActive(persistAdapter, gEngine:serializeState())
  elseif name == "activation_begin" then
    pcall(function()
      C4:FireEventByID(3)
    end)
    setVar("TRANSITIONING", "true")
  elseif name == "activation_complete" then
    pcall(function()
      C4:FireEventByID(4)
    end)
  elseif name == "activation_failed" then
    pcall(function()
      C4:FireEventByID(5)
    end)
  elseif name == "activation_blocked" then
    pcall(function()
      C4:FireEventByID(6)
    end)
  elseif name == "countdown_begin" then
    pcall(function()
      C4:FireEventByID(7)
    end)
  elseif name == "countdown_cancelled" then
    pcall(function()
      C4:FireEventByID(8)
    end)
  elseif name == "activation_warning" then
    pcall(function()
      C4:FireEventByID(9)
    end)
  elseif name == "delayed_result" then
    if detail.result == "FAILED" then
      log:warn("Delayed action failed: %s — %s", tostring(detail.action.device_name), tostring(detail.detail))
    end
    return -- no history/LED churn for individual delayed actions
  elseif name == "restore_begin" or name == "restore_complete" then
    log:info("%s (%s)", name, tostring(detail.reason or detail.result))
  end

  -- Records land in history + variables once per completed activation.
  if
    name == "activation_complete"
    or name == "activation_failed"
    or name == "activation_warning"
    or name == "activation_blocked"
  then
    gLastActivationRecord = detail
    -- Attention feedback on the keypad button that asked (§16): amber for
    -- warnings, red flash for failures, 10 s, then back to normal.
    if (name == "activation_failed" or name == "activation_warning") and detail.meta and detail.meta.slot_name then
      for slotKey, slot in pairs(gConfig.slots or {}) do
        if slot.name == detail.meta.slot_name then
          gLedOverrides[slotKey] =
            { kind = name == "activation_failed" and "failure" or "warning", until_s = os.time() + 10 }
          gLedCache[slotKey] = nil
        end
      end
    end
    if name == "activation_warning" then
      gWarningCount = gWarningCount + 1
    end
    gHistory:add(detail)
    setVar("LAST_ACTIVATION_TIME", formatTime(detail.time))
    setVar("LAST_ACTIVATION_RESULT", detail.result)
    if detail.meta and detail.meta.rule_id then
      setVar("LAST_TRIGGER", tostring(detail.meta.rule_id))
      setVar("LAST_TRIGGER_TYPE", "SENSOR")
    end
  end
  refreshStateSurface()
  syncLeds()
  pushStateToChildren()
end

local function buildEngine()
  gEngine = enginelib.new({
    timer = timerFacility,
    now = os.time,
    uuid = newUuid,
    send = function(deviceId, command, params)
      local ok, err = pcall(function()
        SendToDevice(deviceId, command, params or {})
      end)
      if not ok then
        return false, tostring(err)
      end
      return true
    end,
    emit = onEngineEvent,
    buildPlan = function(modeId)
      return planner.build(gConfig, modeId, planDeps)
    end,
    runPreflight = function(modeId)
      return planner.preflight(gConfig, modeId, planDeps)
    end,
    readDeviceState = function(deviceKey)
      local device = resolveDevice(deviceKey)
      if not device or not device.adapter.caps.canReadState then
        return nil
      end
      gVarsCache = nil -- capture must read fresh, not a 5s-old cache
      local d2 = resolveDevice(deviceKey)
      return d2 and d2.adapter.read(d2.vars) or nil
    end,
    buildRestorePlan = buildRestorePlan,
    interCommandDelayMs = tonumber(gConfig.settings.inter_command_delay_ms) or 50,
    sensorCooldownS = 10,
  })
  gEngine:setConfig(gConfig)
end

-- ─── Triggers + schedules ────────────────────────────────────────────────────

local function rules()
  gConfig.settings.rules = gConfig.settings.rules or {}
  return gConfig.settings.rules
end

local function buildTriggers()
  gTriggers = triggerslib.new({
    now = os.time,
    activeModes = function()
      return gEngine:activeModes()
    end,
    resolve = resolveDevice,
    localtime = function(t)
      return os.date("*t", t)
    end,
    fire = function(rule, _)
      log:info("Rule %s fired -> %s", tostring(rule.id), modeName(rule.mode_id))
      setVar("LAST_TRIGGER", tostring(rule.id))
      setVar("LAST_TRIGGER_TYPE", "SENSOR")
      gEngine:activate(rule.mode_id, "SENSOR", { meta = { rule_id = rule.id } })
    end,
    warn = function(msg)
      log:warn("%s", msg)
      log:print("%s", msg)
    end,
  })
  gTriggers:setRules(rules())
end

--- Variable names that mean "contact-ish state" per signal type.
local SIGNAL_VARS = {
  CONTACT = { "ContactState", "CONTACT_STATE", "STATE" },
  SECURITY = { "PARTITION_STATE" },
}

local gListenerKeys = {} -- "deviceId\0varName" -> true

local function listen(deviceId, varName, cb)
  local key = tostring(deviceId) .. "\0" .. varName
  if gListenerKeys[key] then
    return
  end
  local ok = pcall(function()
    RegisterVariableListener(deviceId, varName, cb)
  end)
  if ok then
    gListenerKeys[key] = true
  else
    log:warn("Could not watch %s on device %s (variable may not exist yet)", varName, deviceId)
  end
end

--- Translate a watched variable change into trigger signals. Contact-style
--- transitions fire BOTH CONTACT_* and MOTION so rules pick by device.
local function onWatchedChange(deviceId, varName, value)
  local key = tostring(deviceId)
  if varName == "PARTITION_STATE" then
    local v = tostring(value)
    if v:find("DISARMED", 1, true) then
      gTriggers:onSignal({ type = "SECURITY_DISARMED", device_key = key })
    elseif v == "ARMED" or v == "EXIT_DELAY" then
      gTriggers:onSignal({ type = "SECURITY_ARMED", device_key = key })
    end
  else
    local v = tostring(value):lower()
    local open = v == "open" or v == "opened" or v == "1" or v == "true"
    if open then
      gTriggers:onSignal({ type = "CONTACT_OPENED", device_key = key })
      gTriggers:onSignal({ type = "MOTION", device_key = key })
    else
      gTriggers:onSignal({ type = "CONTACT_CLOSED", device_key = key })
    end
  end
  gTriggers:onSignal({ type = "VARIABLE", device_key = key, variable = varName, value = value })
end

registerTriggerListeners = function()
  for _, rule in ipairs(rules()) do
    for _, signal in ipairs(rule.signals or {}) do
      local id = tonumber(signal.device_key)
      if id then
        local names
        if signal.type == "SECURITY_DISARMED" or signal.type == "SECURITY_ARMED" then
          names = SIGNAL_VARS.SECURITY
        elseif signal.type == "VARIABLE" and signal.variable then
          names = { signal.variable }
        else
          names = SIGNAL_VARS.CONTACT
        end
        for _, varName in ipairs(names) do
          listen(id, varName, function(value)
            onWatchedChange(id, varName, value)
          end)
        end
      end
    end
  end
end

local function scheduleTick()
  local now = os.time()
  local due = schedule.tick(gConfig, gLastScheduleCheck, now, {
    localtime = function(t)
      return os.date("*t", t)
    end,
    activePresence = function()
      return gEngine:activeModes().PRESENCE
    end,
  })
  gLastScheduleCheck = now
  persist:set(SCHEDULE_MARK_KEY, now)
  for _, d in ipairs(due) do
    log:info("Schedule %s fired -> %s", tostring(d.schedule_id), modeName(d.mode_id))
    setVar("LAST_TRIGGER", tostring(d.schedule_id))
    setVar("LAST_TRIGGER_TYPE", "SCHEDULE")
    gEngine:activate(d.mode_id, "SCHEDULE", { meta = { schedule_id = d.schedule_id } })
  end
end

-- ─── Config persistence + Composer painting ──────────────────────────────────

saveConfig = function()
  if gConfigReadOnly then
    log:print("Configuration is read-only: it was written by a NEWER Mode Composer. Update this driver.")
    return false
  end
  local ok, findings = store.save(persistAdapter, gConfig)
  if not ok then
    for _, f in ipairs(findings) do
      log:print("%s: %s", f.level, f.message)
    end
    return false
  end
  return true
end

--- Gesture-action list labels. Stored values are ids; labels rebuild on
--- every paint so renames stay honest.
local function actionLabels()
  local labels = { "None", "Deactivate Lifestyle", "Restore Previous Presence", "Cancel Transition" }
  for _, mode in ipairs(model.orderedModes(gConfig)) do
    table.insert(labels, "Activate: " .. mode.name)
  end
  return labels
end

local function actionFromLabel(label)
  if label == "None" or label == nil or label == "" then
    return { action = "NONE" }
  end
  if label == "Deactivate Lifestyle" then
    return { action = "DEACTIVATE_LIFESTYLE" }
  end
  if label == "Restore Previous Presence" then
    return { action = "RESTORE_PREVIOUS" }
  end
  if label == "Cancel Transition" then
    return { action = "CANCEL_TRANSITION" }
  end
  local name = label:match("^Activate: (.+)$")
  if name then
    local mode = model.findByName(gConfig, name)
    if mode then
      return { action = "ACTIVATE", mode_id = mode.id }
    end
  end
  return { action = "NONE" }
end

local function labelForGesture(slot, gesture)
  local g = slot.gestures and slot.gestures[gesture]
  if not g or g.action == "NONE" or g.action == nil then
    return "None"
  end
  if g.action == "DEACTIVATE_LIFESTYLE" then
    return "Deactivate Lifestyle"
  end
  if g.action == "RESTORE_PREVIOUS" then
    return "Restore Previous Presence"
  end
  if g.action == "CANCEL_TRANSITION" then
    return "Cancel Transition"
  end
  if g.action == "ACTIVATE" then
    return "Activate: " .. modeName(g.mode_id)
  end
  return "None"
end

paintModeLists = function()
  local names = {}
  for _, mode in ipairs(model.orderedModes(gConfig)) do
    table.insert(names, mode.name)
  end
  local csv = #names > 0 and table.concat(names, ",") or "-"
  pcall(function()
    C4:UpdatePropertyList("Selected Mode", csv, Properties["Selected Mode"])
  end)
  local parents = { "None" }
  for _, mode in ipairs(model.orderedModes(gConfig)) do
    table.insert(parents, mode.name)
  end
  pcall(function()
    C4:UpdatePropertyList("Mode Inherits From", table.concat(parents, ","), Properties["Mode Inherits From"])
  end)
  local actions = table.concat(actionLabels(), ",")
  for _, prop in ipairs({
    "Slot Tap",
    "Slot Double Tap",
    "Slot Triple Tap",
    "Slot Hold",
    "Slot Long Hold",
    "Slot Very Long Hold",
  }) do
    pcall(function()
      C4:UpdatePropertyList(prop, actions, Properties[prop])
    end)
  end
  local ledFollows = { "None", "Global Presence Mode" }
  for _, mode in ipairs(model.orderedModes(gConfig)) do
    table.insert(ledFollows, mode.name)
  end
  pcall(function()
    C4:UpdatePropertyList("Slot LED Follows", table.concat(ledFollows, ","), Properties["Slot LED Follows"])
  end)
  local slotNames = {}
  for _, slot in pairs(gConfig.slots or {}) do
    table.insert(slotNames, slot.name)
  end
  table.sort(slotNames)
  pcall(function()
    C4:UpdatePropertyList(
      "Selected Keypad Slot",
      #slotNames > 0 and table.concat(slotNames, ",") or "-",
      Properties["Selected Keypad Slot"]
    )
  end)
end

local function selectedMode()
  return gSelectedModeId and gConfig.modes[gSelectedModeId] or nil
end

local function colorLabel(hex)
  for name, h in pairs(COLOR_NAMES) do
    if h == hex then
      return name
    end
  end
  return nil
end

paintSelectedMode = function()
  local mode = selectedMode()
  if not mode then
    return
  end
  UpdateProperty("Mode Color", colorLabel(mode.color) or "Blue")
  UpdateProperty("Mode Enabled", mode.enabled and "Yes" or "No")
  UpdateProperty("Mode Priority", tostring(mode.priority or 50))
  UpdateProperty("Mode Inherits From", mode.parent_mode and modeName(mode.parent_mode) or "None")
  local t = mode.transition or {}
  local styleLabel = ({ IMMEDIATE = "Immediate", GRACEFUL = "Graceful", SEQUENCED = "Sequenced" })[t.style or "IMMEDIATE"]
  UpdateProperty("Transition Style", styleLabel or "Immediate")
  UpdateProperty("Departure Countdown Seconds", tostring(t.countdown_s or 0))
  UpdateProperty("Hold To Confirm Seconds", tostring(mode.confirm_hold_s or 0))
  UpdateProperty("Mode Duration Minutes", tostring(math.floor((mode.duration_s or 0) / 60)))
end

local function selectedSlot()
  if not gSelectedSlotKey then
    return nil
  end
  return gConfig.slots[gSelectedSlotKey]
end

paintSelectedSlot = function()
  paintModeLists()
  local slot = selectedSlot()
  if not slot then
    return
  end
  UpdateProperty("Slot Tap", labelForGesture(slot, "tap"))
  UpdateProperty("Slot Double Tap", labelForGesture(slot, "double_tap"))
  UpdateProperty("Slot Triple Tap", labelForGesture(slot, "triple_tap"))
  UpdateProperty("Slot Hold", labelForGesture(slot, "hold"))
  UpdateProperty("Slot Long Hold", labelForGesture(slot, "long_hold"))
  UpdateProperty("Slot Very Long Hold", labelForGesture(slot, "very_long_hold"))
  local led = slot.led or {}
  local ledLabel = "None"
  if led.follow == "GLOBAL" then
    ledLabel = "Global Presence Mode"
  elseif led.follow == "MODE" and led.mode_id then
    ledLabel = modeName(led.mode_id)
  end
  UpdateProperty("Slot LED Follows", ledLabel)
end

-- ─── Setting parser: dealer text -> adapter state ────────────────────────────

--- Parse a dealer-facing SETTING string against a classified device.
--- Returns entry {behavior, state} or nil, err.
local function parseSetting(adapter, setting)
  local s = tostring(setting or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
  if s == "ignore" then
    return { behavior = "IGNORE" }
  end
  if s == "restore" then
    return { behavior = "RESTORE" }
  end
  local class = adapter.class
  if class == "LIGHT" then
    if s == "off" then
      return { behavior = "SET", state = { on = false } }
    end
    if s == "on" then
      return { behavior = "SET", state = { on = true, level = 100 } }
    end
    local pct = s:match("^(%d+)%%?$")
    if pct then
      return { behavior = "SET", state = { on = tonumber(pct) > 0, level = tonumber(pct) } }
    end
  elseif class == "SHADE" then
    if s == "closed" or s == "close" then
      return { behavior = "SET", state = { position = "CLOSED" } }
    end
    if s == "open" then
      return { behavior = "SET", state = { position = "OPEN" } }
    end
    local pct = s:match("^(%d+)%%?$")
    if pct then
      return { behavior = "SET", state = { level = tonumber(pct) } }
    end
  elseif class == "THERMOSTAT" then
    local mode, deg = s:match("^(%a+)%s+(%d+)$")
    if mode == "cool" then
      return { behavior = "SET", state = { cool_setpoint_f = tonumber(deg) } }
    end
    if mode == "heat" then
      return { behavior = "SET", state = { heat_setpoint_f = tonumber(deg) } }
    end
    if s == "off" then
      return { behavior = "SET", state = { hvac_mode = "Off" } }
    end
    if s == "auto" then
      return { behavior = "SET", state = { hvac_mode = "Auto" } }
    end
  elseif class == "LOCK" then
    if s == "locked" or s == "lock" then
      return { behavior = "SET", state = { locked = true } }
    end
    if s == "unlocked" or s == "unlock" then
      return { behavior = "SET", state = { locked = false } }
    end
  elseif class == "SECURITY" then
    if s == "disarm" then
      return { behavior = "SET", state = { arm = "DISARM" } }
    end
    local armType = s:match("^arm%s+(%a+)$") or (s ~= "" and s or nil)
    if armType then
      return { behavior = "SET", state = { arm = armType:sub(1, 1):upper() .. armType:sub(2) } }
    end
  elseif class == "FAN" then
    if s == "off" then
      return { behavior = "SET", state = { on = false } }
    end
    if s == "on" then
      return { behavior = "SET", state = { on = true } }
    end
    local speed = s:match("^speed%s+(%d+)$")
    if speed then
      return { behavior = "SET", state = { speed = tonumber(speed) } }
    end
  elseif class == "ROOM" then
    if s == "off" then
      return { behavior = "SET", state = { power = "OFF" } }
    end
    local vol = s:match("^volume%s+(%d+)$")
    if vol then
      return { behavior = "SET", state = { volume = tonumber(vol) } }
    end
  elseif class == "GARAGE" then
    if s == "closed" or s == "close" then
      return { behavior = "SET", state = { open = false } }
    end
    if s == "open" then
      return { behavior = "SET", state = { open = true } }
    end
  elseif class == "RELAY" then
    if s == "closed" or s == "close" then
      return { behavior = "SET", state = { closed = true } }
    end
    if s == "open" then
      return { behavior = "SET", state = { open = false, closed = false } }
    end
  end
  return nil, string.format("'%s' is not a setting %s devices understand", tostring(setting), adapter.label)
end

-- ─── Mode operations (shared by actions + commands) ──────────────────────────

local function requireModeByName(name)
  local mode = model.findByName(gConfig, sanitizeName(name))
  if not mode then
    log:print("No mode named '%s'. Print Modes lists them.", tostring(name))
    return nil
  end
  return mode
end

local function includeDevice(mode, deviceId, setting)
  local key = tostring(deviceId)
  local device = resolveDevice(key)
  if not device then
    log:print("Device %s was not found in the project.", key)
    return false
  end
  if device.adapter.class == "GENERIC" then
    log:print(
      "'%s' is not a device type Mode Composer can control. Use the mode's Composer events instead.",
      device.name
    )
    return false
  end
  local entry, err = parseSetting(device.adapter, setting)
  if not entry then
    log:print("%s", err)
    return false
  end
  local existing = mode.desired_states[key]
  if existing then
    entry.delay_s = existing.delay_s
    entry.criticality = existing.criticality
    if existing.state and existing.state.allow_sensitive and entry.state then
      entry.state.allow_sensitive = existing.state.allow_sensitive
    end
  end
  mode.desired_states[key] = entry
  local describe = entry.behavior == "SET" and device.adapter.describe(entry.state) or entry.behavior
  log:print("%s: %s -> %s", mode.name, device.name, describe)
  return true
end

local function captureIntoMode(mode)
  refreshDeviceIndex()
  gVarsCache = nil
  local counts, captured, unsupported, unreadable = {}, 0, 0, 0
  for key, entry in pairs(gDeviceIndex) do
    local device = resolveDevice(key)
    if device and device.adapter.class ~= "GENERIC" and device.adapter.caps.canReadState then
      local state = device.adapter.read(device.vars)
      if state ~= nil then
        -- Sensitive states are never captured into SET entries: a captured
        -- unlocked door must not become "unlock the door" (§106).
        if device.adapter.class == "LOCK" and state.locked == false then
          state.locked = true
          log:print("  %s captured as Locked (an unlocked state is never stored as a mode target)", device.name)
        end
        if device.adapter.class == "SECURITY" then
          state = nil
        end
        if state then
          mode.desired_states[key] = { behavior = "SET", state = state }
          counts[device.adapter.label] = (counts[device.adapter.label] or 0) + 1
          captured = captured + 1
        end
      else
        unreadable = unreadable + 1
      end
    elseif device and device.adapter.class ~= "GENERIC" then
      unsupported = unsupported + 1
    end
  end
  log:print("Captured current state into '%s':", mode.name)
  for label, n in pairs(counts) do
    log:print("  %-10s %3d devices", label, n)
  end
  log:print(
    "  %d captured, %d unsupported, %d unreadable. Security panels are never auto-captured.",
    captured,
    unsupported,
    unreadable
  )
  log:print("Review with 'Print Devices In Selected Mode'; remove entries with 'Exclude Device From Mode'.")
  saveConfig()
end

local function testMode(mode)
  log:print("Testing '%s'...", mode.name)
  local outcome =
    gEngine:activate(mode.id, "COMPOSER", { reapply = true, skip_countdown = true, meta = { test = true } })
  if outcome.status == "REFUSED" then
    log:print("Refused: %s", tostring(outcome.reason))
  end
  -- Results land via the activation record; PRINT_LAST_ACTIVATION shows them.
  SetTimer("McTestReport", 5 * ONE_SECOND, function()
    if gLastActivationRecord then
      log:print("%s", historylib.renderDetail(gLastActivationRecord, modeName, formatTime))
    end
  end, false)
end

-- ─── Composer property handlers ──────────────────────────────────────────────

OPC.Log_Level = function(value)
  log:setLogLevel(value)
end
OPC.Log_Mode = function(value)
  log:setLogMode(value)
end

OPC.Selected_Mode = function(value)
  local mode = model.findByName(gConfig, value)
  gSelectedModeId = mode and mode.id or nil
  if mode then
    paintSelectedMode()
  end
end

OPC.Selected_Keypad_Slot = function(value)
  gSelectedSlotKey = nil
  for slotKey, slot in pairs(gConfig.slots or {}) do
    if slot.name == value then
      gSelectedSlotKey = slotKey
    end
  end
  if gSelectedSlotKey then
    paintSelectedSlot()
  end
end

local function onModeEdit(apply)
  return function(value)
    if not gInitialized then
      return
    end
    local mode = selectedMode()
    if not mode then
      return
    end
    if refuseIfEnforced("mode edit") then
      return
    end
    apply(mode, value)
    saveConfig()
    paintModeLists()
    syncLeds()
    pushStateToChildren()
  end
end

OPC.Mode_Color = onModeEdit(function(mode, value)
  mode.color = COLOR_NAMES[value] or mode.color
end)
OPC.Mode_Enabled = onModeEdit(function(mode, value)
  mode.enabled = value == "Yes"
end)
OPC.Mode_Priority = onModeEdit(function(mode, value)
  mode.priority = tonumber(value) or mode.priority
end)
OPC.Mode_Inherits_From = onModeEdit(function(mode, value)
  if value == "None" then
    model.setParent(gConfig, mode.id, nil)
    return
  end
  local parent = model.findByName(gConfig, value)
  if not parent then
    return
  end
  local ok, err = model.setParent(gConfig, mode.id, parent.id)
  if not ok then
    log:print("%s", err)
    paintSelectedMode() -- snap the property back to reality
  end
end)
OPC.Transition_Style = onModeEdit(function(mode, value)
  mode.transition = mode.transition or {}
  mode.transition.style = ({ Immediate = "IMMEDIATE", Graceful = "GRACEFUL", Sequenced = "SEQUENCED" })[value]
    or "IMMEDIATE"
end)
OPC.Departure_Countdown_Seconds = onModeEdit(function(mode, value)
  mode.transition = mode.transition or {}
  mode.transition.countdown_s = tonumber(value) or 0
end)
OPC.Hold_To_Confirm_Seconds = onModeEdit(function(mode, value)
  mode.confirm_hold_s = tonumber(value) or 0
end)
OPC.Mode_Duration_Minutes = onModeEdit(function(mode, value)
  mode.duration_s = (tonumber(value) or 0) * 60
end)

local function onSlotGestureEdit(gesture)
  return function(value)
    if not gInitialized then
      return
    end
    local slot = selectedSlot()
    if not slot then
      return
    end
    if refuseIfEnforced("keypad slot edit") then
      return
    end
    slot.gestures = slot.gestures or {}
    slot.gestures[gesture] = actionFromLabel(value)
    buildGesture(gSelectedSlotKey)
    saveConfig()
  end
end

OPC.Slot_Tap = onSlotGestureEdit("tap")
OPC.Slot_Double_Tap = onSlotGestureEdit("double_tap")
OPC.Slot_Triple_Tap = onSlotGestureEdit("triple_tap")
OPC.Slot_Hold = onSlotGestureEdit("hold")
OPC.Slot_Long_Hold = onSlotGestureEdit("long_hold")
OPC.Slot_Very_Long_Hold = onSlotGestureEdit("very_long_hold")

OPC.Slot_LED_Follows = function(value)
  if not gInitialized then
    return
  end
  local slot = selectedSlot()
  if not slot then
    return
  end
  if refuseIfEnforced("keypad LED edit") then
    return
  end
  if value == "None" then
    slot.led = { follow = "NONE" }
  elseif value == "Global Presence Mode" then
    slot.led = { follow = "GLOBAL" }
  else
    local mode = model.findByName(gConfig, value)
    slot.led = mode and { follow = "MODE", mode_id = mode.id } or { follow = "NONE" }
  end
  gLedCache[gSelectedSlotKey] = nil
  saveConfig()
  syncLeds()
end

--- Letterbox: the code is stored encrypted and the field wiped (the house
--- credential pattern).
OPC.Security_User_Code = function(value)
  local code = tostring(value or ""):gsub("%s", "")
  if code == "" then
    return
  end
  persist:set(USER_CODE_KEY, code, true)
  UpdateProperty("Security User Code", "")
  log:print("Security user code stored (encrypted).")
end

OPC.Import_Configuration = function(value)
  if not gInitialized or tostring(value or "") == "" then
    return
  end
  UpdateProperty("Import Configuration", "")
  if refuseIfEnforced("configuration import") then
    return
  end
  local ok, decoded = pcall(function()
    return JSON:decode(value)
  end)
  if not ok or type(decoded) ~= "table" then
    log:print("Import failed: that was not valid JSON. The current configuration is untouched.")
    return
  end
  local staged, findingsOrErr = store.stageImport(decoded)
  if not staged then
    if type(findingsOrErr) == "table" then
      for _, f in ipairs(findingsOrErr) do
        log:print("%s: %s", f.level, f.message)
      end
    else
      log:print("Import refused: %s", tostring(findingsOrErr))
    end
    log:print("The current configuration is untouched.")
    return
  end
  gConfig = staged
  gEngine:setConfig(gConfig)
  gTriggers:setRules(rules())
  saveConfig()
  rebuildGestures()
  registerTriggerListeners()
  paintModeLists()
  syncLeds()
  pushStateToChildren()
  log:print("Configuration imported: %d modes.", #model.orderedModes(gConfig))
end

OPC.Add_Trigger_Rule_JSON = function(value)
  if not gInitialized or tostring(value or "") == "" then
    return
  end
  UpdateProperty("Add Trigger Rule JSON", "")
  if refuseIfEnforced("trigger rule change") then
    return
  end
  local ok, rule = pcall(function()
    return JSON:decode(value)
  end)
  if not ok or type(rule) ~= "table" or type(rule.signals) ~= "table" or rule.mode_id == nil then
    log:print("Rule refused: expected JSON with mode_id and signals[]. See the documentation's Trigger Rules section.")
    return
  end
  rule.id = rule.id or ("rule_" .. newUuid())
  if not gConfig.modes[rule.mode_id] then
    local mode = model.findByName(gConfig, tostring(rule.mode_id))
    if not mode then
      log:print("Rule refused: mode '%s' does not exist.", tostring(rule.mode_id))
      return
    end
    rule.mode_id = mode.id
  end
  table.insert(rules(), rule)
  gTriggers:setRules(rules())
  registerTriggerListeners()
  saveConfig()
  log:print("Rule %s added (-> %s).", rule.id, modeName(rule.mode_id))
end

OPC.Advanced_Settings = function(value)
  local hide = value ~= "Show" and 1 or 0
  for _, prop in ipairs({
    "Double Tap Window ms",
    "Hold Seconds",
    "Long Hold Seconds",
    "Very Long Hold Seconds",
    "Inter-Command Delay ms",
    "History Size",
    "Import Configuration",
    "Add Trigger Rule JSON",
    "Mode Priority",
  }) do
    pcall(function()
      C4:SetPropertyAttribs(prop, hide)
    end)
  end
end

local function onTimingEdit(key)
  return function(value)
    if not gInitialized then
      return
    end
    gConfig.settings[key] = tonumber(value)
    saveConfig()
    rebuildGestures()
  end
end

OPC.Double_Tap_Window_ms = onTimingEdit("tap_window_ms")
OPC.Hold_Seconds = onTimingEdit("hold_s")
OPC.Long_Hold_Seconds = onTimingEdit("long_hold_s")
OPC.Very_Long_Hold_Seconds = onTimingEdit("very_long_hold_s")

OPC.Inter_Command_Delay_ms = function(value)
  if not gInitialized then
    return
  end
  gConfig.settings.inter_command_delay_ms = tonumber(value) or 50
  saveConfig()
  -- Mutate the live deps rather than rebuilding the engine: a rebuild would
  -- drop in-flight transitions and restore captures for a settings tweak.
  gEngine.deps.interCommandDelayMs = gConfig.settings.inter_command_delay_ms
end

OPC.History_Size = function(value)
  if gHistory then
    gHistory:setLimit(tonumber(value) or 100)
  end
end

-- ─── Actions ─────────────────────────────────────────────────────────────────

EC.CREATE_MODE = function()
  if refuseIfEnforced("create mode") then
    return
  end
  local typeLabel = Properties["New Mode Type"] or "Custom Lifestyle"
  local kind = KIND_BY_TYPE_PROPERTY[typeLabel] or "CUSTOM"
  local name = sanitizeName(Properties["New Mode Name"])
  local spec = { kind = kind }
  if typeLabel == "Custom Presence" then
    spec.category = "PRESENCE"
  elseif typeLabel == "Custom Lifestyle" then
    spec.category = "LIFESTYLE"
  end
  if name ~= "" then
    spec.name = name
  end
  if model.findByName(gConfig, spec.name or typeLabel) then
    log:print("A mode named '%s' already exists — set New Mode Name to something else.", spec.name or typeLabel)
    return
  end
  local mode = model.newMode(gConfig, spec, newUuid)
  ensureModeEvent(mode)
  saveConfig()
  gSelectedModeId = mode.id
  paintModeLists()
  UpdateProperty("Selected Mode", mode.name)
  UpdateProperty("New Mode Name", "")
  paintSelectedMode()
  pushStateToChildren()
  log:print(
    "Created %s mode '%s'. Select devices with Capture Current State or the Include commands.",
    mode.category,
    mode.name
  )
end

EC.DUPLICATE_MODE = function()
  local mode = selectedMode()
  if not mode then
    log:print("Select a mode first.")
    return
  end
  if refuseIfEnforced("duplicate mode") then
    return
  end
  local copy = model.duplicateMode(gConfig, mode.id, newUuid)
  ensureModeEvent(copy)
  saveConfig()
  paintModeLists()
  pushStateToChildren()
  log:print("Duplicated '%s' as '%s'.", mode.name, copy.name)
end

EC.DELETE_MODE = function()
  local mode = selectedMode()
  if not mode then
    log:print("Select a mode first.")
    return
  end
  if refuseIfEnforced("delete mode") then
    return
  end
  local affected = model.deleteMode(gConfig, mode.id)
  gSelectedModeId = nil
  saveConfig()
  paintModeLists()
  pushStateToChildren()
  log:print("Deleted '%s'.", mode.name)
  if affected and (#affected.children > 0 or #affected.slots > 0) then
    log:print(
      "  %d child mode(s) re-parented; %d keypad assignment(s) now need attention (see validation).",
      #affected.children,
      #affected.slots
    )
  end
end

EC.ACTIVATE_SELECTED = function()
  local mode = selectedMode()
  if not mode then
    log:print("Select a mode first.")
    return
  end
  activateFromSurface(mode.id, "COMPOSER", {})
end

EC.DEACTIVATE_LIFESTYLE = function()
  gEngine:deactivateLifestyle("COMPOSER", {})
end

EC.CANCEL_TRANSITION = function()
  if not gEngine:cancelTransition("cancelled from Composer") then
    log:print("No transition is in progress.")
  end
end

EC.CAPTURE_STATE = function()
  local mode = selectedMode()
  if not mode then
    log:print("Select a mode first.")
    return
  end
  if refuseIfEnforced("capture state") then
    return
  end
  captureIntoMode(mode)
end

EC.DRY_RUN = function()
  local mode = selectedMode()
  if not mode then
    log:print("Select a mode first.")
    return
  end
  local plan, err = planner.build(gConfig, mode.id, planDeps)
  if not plan then
    log:print("Cannot plan '%s': %s", mode.name, tostring(err))
    return
  end
  log:print("%s", planner.renderDryRun(plan))
end

EC.TEST_MODE = function()
  local mode = selectedMode()
  if not mode then
    log:print("Select a mode first.")
    return
  end
  testMode(mode)
end

EC.RUN_PREFLIGHT = function()
  local mode = selectedMode()
  if not mode then
    log:print("Select a mode first.")
    return
  end
  local results = planner.preflight(gConfig, mode.id, planDeps)
  if #results.checks == 0 then
    log:print("'%s' has no preflight checks configured (Add Preflight Check command).", mode.name)
    return
  end
  for _, c in ipairs(results.checks) do
    log:print("  %-8s %s should be %s%s", c.outcome, c.name, c.expect, c.detail and (" — " .. c.detail) or "")
  end
  log:print("Preflight result: %s", results.worst)
end

EC.ADD_KEYPAD_SLOT = function()
  if refuseIfEnforced("add keypad slot") then
    return
  end
  addKeypadSlot()
end

EC.PRINT_MODES = function()
  local active = gEngine:activeModes()
  log:print("Modes (%d):", #model.orderedModes(gConfig))
  for _, mode in ipairs(model.orderedModes(gConfig)) do
    local marks = {}
    if active[mode.category] == mode.id then
      table.insert(marks, "ACTIVE")
    end
    if not mode.enabled then
      table.insert(marks, "disabled")
    end
    if mode.parent_mode then
      table.insert(marks, "inherits " .. modeName(mode.parent_mode))
    end
    local deviceCount = 0
    for _ in pairs(mode.desired_states or {}) do
      deviceCount = deviceCount + 1
    end
    log:print(
      "  %-20s %-10s %3d devices  prio %3d  %s",
      mode.name,
      mode.category,
      deviceCount,
      mode.priority or 0,
      table.concat(marks, ", ")
    )
  end
  local findings = model.validate(gConfig)
  for _, f in ipairs(findings) do
    log:print("  %s: %s", f.level, f.message)
  end
end

EC.PRINT_MODE_DETAIL = function()
  local mode = selectedMode()
  if not mode then
    log:print("Select a mode first.")
    return
  end
  log:print("%s (%s)  id=%s", mode.name, mode.category, mode.id)
  log:print("  color #%s  priority %d  %s", mode.color, mode.priority or 0, mode.enabled and "enabled" or "DISABLED")
  if mode.parent_mode then
    log:print("  inherits from %s", modeName(mode.parent_mode))
  end
  local t = model.effectiveTransition(gConfig, mode.id)
  log:print(
    "  transition %s, countdown %ds, confirm hold %ds, duration %dm",
    t.style,
    t.countdown_s or 0,
    mode.confirm_hold_s or 0,
    math.floor((mode.duration_s or 0) / 60)
  )
  for _, sched in ipairs(mode.schedules or {}) do
    log:print(
      "  schedule: %s days=%s%s",
      sched.time,
      sched.days and table.concat(sched.days, "/") or "all",
      sched.require_presence and (" require " .. modeName(sched.require_presence)) or ""
    )
  end
  local plan = planner.build(gConfig, mode.id, planDeps)
  if plan then
    log:print(
      "  plan: %d actions, %d restores, %d unsupported, %d missing",
      plan.summary.total,
      #plan.restores,
      #plan.unsupported,
      #plan.missing
    )
  end
end

EC.PRINT_MODE_DEVICES = function()
  local mode = selectedMode()
  if not mode then
    log:print("Select a mode first.")
    return
  end
  local states, sources = model.effectiveStates(gConfig, mode.id)
  if not states then
    log:print("Cannot resolve: %s", tostring(sources))
    return
  end
  local rows = {}
  for deviceKey, entry in pairs(states) do
    local device = resolveDevice(deviceKey)
    local label
    if not device then
      label = string.format("MISSING (device %s no longer in project)", deviceKey)
    elseif entry.behavior == "SET" then
      label = device.adapter.describe(entry.state or {})
    else
      label = entry.behavior
    end
    local origin = sources[deviceKey] ~= mode.id and (" [from " .. modeName(sources[deviceKey]) .. "]") or ""
    table.insert(rows, string.format("  %-30s %s%s", device and device.name or ("#" .. deviceKey), label, origin))
  end
  table.sort(rows)
  log:print("%s controls %d devices:", mode.name, #rows)
  for _, row in ipairs(rows) do
    log:print("%s", row)
  end
end

EC.PRINT_HISTORY = function()
  local entries = gHistory:list(25)
  if #entries == 0 then
    log:print("No activations recorded yet.")
    return
  end
  for _, record in ipairs(entries) do
    log:print("%s", historylib.renderLine(record, modeName, nil, formatTime))
  end
end

EC.PRINT_LAST_ACTIVATION = function()
  if not gLastActivationRecord then
    log:print("No activation recorded since the driver started.")
    return
  end
  log:print("%s", historylib.renderDetail(gLastActivationRecord, modeName, formatTime))
end

EC.PRINT_RULES = function()
  local r = rules()
  if #r == 0 then
    log:print("No trigger rules configured.")
    return
  end
  for _, rule in ipairs(r) do
    log:print(
      "  %s -> %s  (%d signals, window %ds, cooldown %ds)%s",
      rule.id,
      modeName(rule.mode_id),
      #(rule.signals or {}),
      rule.window_s or triggerslib.DEFAULT_WINDOW_S,
      rule.cooldown_s or triggerslib.DEFAULT_COOLDOWN_S,
      rule.enabled == false and "  DISABLED" or ""
    )
    for _, sig in ipairs(rule.signals or {}) do
      local device = resolveDevice(sig.device_key)
      log:print("    %s on %s", sig.type, device and device.name or tostring(sig.device_key))
    end
  end
end

EC.CLEAR_RULES = function()
  if refuseIfEnforced("clear trigger rules") then
    return
  end
  gConfig.settings.rules = {}
  gTriggers:setRules({})
  saveConfig()
  log:print("All trigger rules removed.")
end

EC.DIAGNOSTIC_SNAPSHOT = function()
  log:print("── Mode Composer diagnostic snapshot ──")
  log:print("Driver version: %s", C4:GetDriverConfigInfo("version") or "?")
  log:print("License: %s", license.describe())
  log:print("Config version: %d%s", gConfig.configVersion or 0, gConfigReadOnly and "  READ-ONLY (newer schema)" or "")
  local modes = model.orderedModes(gConfig)
  local presence, lifestyle = 0, 0
  for _, m in ipairs(modes) do
    if m.category == "PRESENCE" then
      presence = presence + 1
    else
      lifestyle = lifestyle + 1
    end
  end
  log:print("Modes: %d (%d presence, %d lifestyle)", #modes, presence, lifestyle)
  local slotCount, assignments = 0, 0
  for _, slot in pairs(gConfig.slots or {}) do
    slotCount = slotCount + 1
    for _, g in pairs(slot.gestures or {}) do
      if g.action and g.action ~= "NONE" then
        assignments = assignments + 1
      end
    end
  end
  log:print("Keypad slots: %d (%d gesture assignments)", slotCount, assignments)
  log:print(
    "Trigger rules: %d   Schedules checked: %s",
    #rules(),
    gLastScheduleCheck > 0 and formatTime(gLastScheduleCheck) or "never"
  )
  local missing = 0
  for _, mode in ipairs(modes) do
    local plan = planner.build(gConfig, mode.id, planDeps)
    if plan then
      missing = missing + #plan.missing
    end
  end
  log:print("Missing device references: %d", missing)
  log:print(
    "Active: presence=%s lifestyle=%s transitioning=%s",
    modeName(gEngine:activeModes().PRESENCE),
    modeName(gEngine:activeModes().LIFESTYLE),
    tostring(gEngine:isTransitioning())
  )
  if gLastActivationRecord then
    log:print(
      "Last activation: %s %s at %s",
      modeName(gLastActivationRecord.mode_id),
      gLastActivationRecord.result,
      formatTime(gLastActivationRecord.time)
    )
  end
  local findings = model.validate(gConfig)
  log:print("Validation findings: %d", #findings)
  for _, f in ipairs(findings) do
    log:print("  %s: %s", f.level, f.message)
  end
  log:print("── end snapshot ──")
end

EC.EXPORT_CONFIG = function()
  local payload = store.export(gConfig)
  log:print("%s", JSON:encode(payload))
  log:print("(Copy the JSON above into another instance's Import Configuration property.)")
end

EC.REFRESH_LICENSE = function()
  license.register()
  license.check()
end

EC.SBOS_ENTITLEMENT = function(tParams)
  license.onEntitlement(tParams)
end

-- ─── Programming commands ────────────────────────────────────────────────────

EC.Activate_Mode = function(tParams)
  local mode = requireModeByName(tParams and tParams.NAME)
  if mode then
    activateFromSurface(mode.id, "COMPOSER", {})
  end
end
EC.Deactivate_Lifestyle_Mode = function()
  gEngine:deactivateLifestyle("COMPOSER", {})
end
EC.Restore_Previous_Presence_Mode = function()
  gEngine:restorePrevious("PRESENCE", "COMPOSER")
end
EC.Restore_Previous_Lifestyle_Mode = function()
  gEngine:restorePrevious("LIFESTYLE", "COMPOSER")
end
EC.Reapply_Mode = function(tParams)
  local mode = requireModeByName(tParams and tParams.NAME)
  if mode then
    gEngine:activate(mode.id, "COMPOSER", { reapply = true })
  end
end
EC.Run_Preflight = function(tParams)
  local mode = requireModeByName(tParams and tParams.NAME)
  if mode then
    gSelectedModeId = mode.id
    EC.RUN_PREFLIGHT()
  end
end
EC.Capture_Current_State = function(tParams)
  local mode = requireModeByName(tParams and tParams.NAME)
  if mode and not refuseIfEnforced("capture state") then
    captureIntoMode(mode)
  end
end

EC.Include_Device_In_Mode = function(tParams)
  if refuseIfEnforced("include device") then
    return
  end
  local mode = requireModeByName(tParams and tParams.NAME)
  if not mode then
    return
  end
  if includeDevice(mode, tParams.DEVICE, tParams.SETTING) then
    saveConfig()
  end
end

EC.Exclude_Device_From_Mode = function(tParams)
  if refuseIfEnforced("exclude device") then
    return
  end
  local mode = requireModeByName(tParams and tParams.NAME)
  if not mode then
    return
  end
  local key = tostring(tParams.DEVICE)
  if mode.desired_states[key] then
    mode.desired_states[key] = nil
    saveConfig()
    log:print("%s: device %s removed.", mode.name, key)
  else
    log:print("%s does not include device %s directly (it may come from a parent mode).", mode.name, key)
  end
end

local function includeAllOfClass(tParams, class, defaultSetting)
  if refuseIfEnforced("bulk include") then
    return
  end
  local mode = requireModeByName(tParams and tParams.NAME)
  if not mode then
    return
  end
  local setting = tostring(tParams.SETTING or "")
  if setting == "" then
    setting = defaultSetting
  end
  refreshDeviceIndex()
  local added = 0
  for key in pairs(gDeviceIndex) do
    local device = resolveDevice(key)
    if device and device.adapter.class == class then
      local entry = parseSetting(device.adapter, setting)
      if entry then
        mode.desired_states[key] = entry
        added = added + 1
      end
    end
  end
  saveConfig()
  log:print("%s: %d %s devices set to '%s'.", mode.name, added, class, setting)
end

EC.Include_All_Lights = function(tParams)
  includeAllOfClass(tParams, "LIGHT", "off")
end
EC.Include_All_Shades = function(tParams)
  includeAllOfClass(tParams, "SHADE", "closed")
end
EC.Include_All_Media_Rooms = function(tParams)
  if refuseIfEnforced("bulk include") then
    return
  end
  local mode = requireModeByName(tParams and tParams.NAME)
  if not mode then
    return
  end
  local added = 0
  for roomId in pairs(gRooms) do
    mode.desired_states["room:" .. roomId] = { behavior = "SET", state = { power = "OFF" } }
    added = added + 1
  end
  saveConfig()
  log:print("%s: media off in %d rooms.", mode.name, added)
end

local function editEntry(tParams, apply)
  local mode = requireModeByName(tParams and tParams.NAME)
  if not mode then
    return
  end
  local key = tostring(tParams.DEVICE)
  local entry = mode.desired_states[key]
  if not entry then
    log:print("%s does not directly include device %s — Include it first.", mode.name, key)
    return
  end
  apply(mode, entry, key)
  saveConfig()
end

EC.Set_Device_Delay = function(tParams)
  if refuseIfEnforced("device delay") then
    return
  end
  editEntry(tParams, function(mode, entry, key)
    entry.delay_s = tonumber(tParams.SECONDS) or 0
    log:print("%s: device %s delayed %ds after activation.", mode.name, key, entry.delay_s)
  end)
end

EC.Set_Device_Criticality = function(tParams)
  if refuseIfEnforced("device criticality") then
    return
  end
  editEntry(tParams, function(mode, entry, key)
    entry.criticality = tParams.CRITICALITY
    log:print("%s: device %s is now %s.", mode.name, key, entry.criticality)
  end)
end

EC.Allow_Sensitive_Action = function(tParams)
  if refuseIfEnforced("sensitive action approval") then
    return
  end
  editEntry(tParams, function(mode, entry, key)
    entry.state = entry.state or {}
    entry.state.allow_sensitive = true
    local device = resolveDevice(key)
    log:print(
      "%s: sensitive action EXPLICITLY ALLOWED for %s. This mode may now unlock/disarm/open it.",
      mode.name,
      device and device.name or key
    )
  end)
end

EC.Add_Preflight_Check = function(tParams)
  if refuseIfEnforced("preflight change") then
    return
  end
  local mode = requireModeByName(tParams and tParams.NAME)
  if not mode then
    return
  end
  mode.preflight = mode.preflight or {}
  table.insert(mode.preflight, {
    device_key = tostring(tParams.DEVICE),
    expect = tParams.EXPECT,
    policy = tParams.POLICY,
  })
  saveConfig()
  local device = resolveDevice(tostring(tParams.DEVICE))
  log:print(
    "%s preflight: %s should be %s (%s).",
    mode.name,
    device and device.name or tParams.DEVICE,
    tParams.EXPECT,
    tParams.POLICY
  )
end

EC.Configure_Return_Home_Rule = function(tParams)
  if refuseIfEnforced("trigger rule change") then
    return
  end
  local target = requireModeByName(tParams and tParams.TARGET_MODE)
  local required = requireModeByName(tParams and tParams.REQUIRED_MODE)
  if not target or not required then
    return
  end
  local rule = {
    id = "return_home_" .. newUuid(),
    mode_id = target.id,
    enabled = true,
    signals = {
      { type = "CONTACT_OPENED", device_key = tostring(tParams.DOOR) },
      { type = "SECURITY_DISARMED", device_key = tostring(tParams.PANEL) },
      { type = "MOTION", device_key = tostring(tParams.MOTION) },
    },
    conditions = { { type = "PRESENCE_IS", mode_id = required.id } },
    window_s = 120,
    cooldown_s = 60,
  }
  table.insert(rules(), rule)
  gTriggers:setRules(rules())
  registerTriggerListeners()
  saveConfig()
  log:print(
    "Return-home rule added: door + disarm + motion within 2 minutes while %s -> %s.",
    required.name,
    target.name
  )
end

EC.Set_Mode_Schedule = function(tParams)
  if refuseIfEnforced("schedule change") then
    return
  end
  local mode = requireModeByName(tParams and tParams.NAME)
  if not mode then
    return
  end
  if schedule.parseTime(tParams.TIME) == nil then
    log:print("'%s' is not a valid HH:MM time.", tostring(tParams.TIME))
    return
  end
  local days
  if tParams.DAYS == "Weekdays" then
    days = { 2, 3, 4, 5, 6 }
  elseif tParams.DAYS == "Weekends" then
    days = { 1, 7 }
  end
  local requirePresence
  if tParams.REQUIRED_MODE and tParams.REQUIRED_MODE ~= "" then
    local req = model.findByName(gConfig, tParams.REQUIRED_MODE)
    requirePresence = req and req.id or nil
  end
  mode.schedules = mode.schedules or {}
  table.insert(mode.schedules, {
    id = "sched_" .. newUuid(),
    time = tParams.TIME,
    days = days,
    require_presence = requirePresence,
    enabled = true,
  })
  saveConfig()
  log:print(
    "%s scheduled at %s (%s)%s.",
    mode.name,
    tParams.TIME,
    tParams.DAYS or "Every Day",
    requirePresence and (" while " .. modeName(requirePresence)) or ""
  )
end

EC.Clear_Mode_Schedules = function(tParams)
  if refuseIfEnforced("schedule change") then
    return
  end
  local mode = requireModeByName(tParams and tParams.NAME)
  if not mode then
    return
  end
  mode.schedules = {}
  saveConfig()
  log:print("%s: schedules cleared.", mode.name)
end

-- Composer sends action/command names with spaces collapsed to underscores;
-- these aliases keep both spellings working.
EC.Cancel_Transition = EC.CANCEL_TRANSITION

-- ─── Conditionals ────────────────────────────────────────────────────────────

TC.TRANSITIONING = function()
  return gEngine ~= nil and gEngine:isTransitioning()
end

TC.OCCUPIED = function()
  return gEngine ~= nil and gTriggers:occupancy(gConfig.modes).state == "OCCUPIED"
end

local function nameConditional(category)
  return function(_, tParams)
    if gEngine == nil then
      return false
    end
    local current = modeName(gEngine:activeModes()[category])
    local wanted = tostring((tParams and (tParams.VALUE or tParams.STRING)) or "")
    local logic = tostring((tParams and tParams.LOGIC) or "EQUAL")
    local equal = current:lower() == wanted:lower()
    if logic == "NOT_EQUAL" then
      return not equal
    end
    return equal
  end
end

TC.PRESENCE_MODE_IS = nameConditional("PRESENCE")
TC.LIFESTYLE_MODE_IS = nameConditional("LIFESTYLE")

-- ─── Lifecycle ───────────────────────────────────────────────────────────────

function OnDriverInit()
  log:setLogName("ModeComposer")
  log:setLogLevel(Properties["Log Level"])
  log:setLogMode(Properties["Log Mode"])
  math.randomseed(os.time() + (C4:GetDeviceID() or 0))

  -- Bindings must restore in OnDriverInit or Director drops consumer-side
  -- connections onto not-yet-existing bindings (lib.bindings' own warning).
  bindings:restoreBindings()

  gConfig, gConfigReadOnly = store.load(persistAdapter)
  gChildIds = persist:get(CHILDREN_KEY, {})
  if type(gChildIds) ~= "table" then
    gChildIds = {}
  end
  gLastScheduleCheck = tonumber(persist:get(SCHEDULE_MARK_KEY, 0)) or 0
  gHistory = historylib.new({ limit = tonumber(Properties["History Size"]) or 100, persist = persistAdapter })
  buildEngine()
  buildTriggers()
  gEngine:restoreState(store.loadActive(persistAdapter))
end

function OnDriverLateInit()
  -- Variables and events register at add-time only from XML; re-adding at
  -- every init is the measured house pattern.
  for _, v in ipairs(VARIABLES) do
    pcall(function()
      C4:AddVariable(v[1], v[2], v[3], true)
    end)
  end
  for _, e in ipairs(EVENTS) do
    pcall(function()
      C4:AddEvent(e[1], e[2], e[3])
    end)
  end
  for _, mode in pairs(gConfig.modes) do
    ensureModeEvent(mode)
  end

  refreshDeviceIndex()
  rebuildGestures()
  registerTriggerListeners()

  -- First run convenience: a fresh install gets two keypad slots so the
  -- Connections page has somewhere to bind before any action is run.
  if not gConfig.settings.bootstrapped then
    gConfig.settings.bootstrapped = true
    if next(gConfig.slots) == nil then
      addKeypadSlot()
      addKeypadSlot()
    end
    saveConfig()
  end

  for p, _ in pairs(Properties) do
    local ok, err = pcall(OnPropertyChanged, p)
    if not ok and err then
      log:error("OnPropertyChanged(%s): %s", p, err)
    end
  end

  license.setup({ sku = SKU })

  SetTimer(SCHEDULE_TIMER, 30 * ONE_SECOND, scheduleTick, true)

  paintModeLists()
  refreshStateSurface()
  gLedCache = {} -- restart resync: force one full LED repaint (§49, §133)
  syncLeds()
  pushStateToChildren()

  gInitialized = true
  UpdateProperty("Driver Version", C4:GetDriverConfigInfo("version") or "")
  UpdateProperty("Driver Status", gConfigReadOnly and "Config from newer driver (read-only)" or "Online")
  log:info("Mode Composer online: %d modes", #model.orderedModes(gConfig))
end

function OnDriverDestroyed()
  CancelTimer(SCHEDULE_TIMER)
  CancelTimer(PULSE_TIMER)
  KillAllTimers()
end
