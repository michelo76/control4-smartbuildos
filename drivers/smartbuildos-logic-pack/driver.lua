--[[==========================================================================
  SmartBuildOS Logic Pack
  Programming primitives Composer never had, keyed by a name the programmer
  types: counters, flags, a state machine, debounce, throttle, once-per-day,
  cancellable timers. One instance per project, any number of keys, all
  persisted across restarts.

  Licensing: the SmartBuildOS Agent is the authority (SKU SBOS_LOGIC_PACK
  through sbos.license). A definitive denial with enforcement on makes the
  pack READ-ONLY: every command is refused and says so, conditionals and
  variables keep answering, nothing is lost.

  Pure rules: src/logic/engine.lua (tested without a controller).
============================================================================]]

--#ifdef DRIVERCENTRAL
DC_PID = 0
DC_X = nil
DC_FILENAME = "smartbuildos-logic-pack.c4z"
--#else
DRIVER_GITHUB_REPO = "michelo76/control4-smartbuildos"
DRIVER_FILENAMES = { "smartbuildos-logic-pack.c4z" }
--#endif

-- Every require at module scope: the build's squish step discovers modules
-- by loading this file under the test shim, where OnDriverLateInit stops
-- early, so a require inside a function would be left out of the .c4z.
require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")
JSON = require("JSON")

local log = require("lib.logging")
local persist = require("lib.persist")
local license = require("sbos.license")
local Engine = require("logic.engine")

gInitialized = false

local SKU = "SBOS_LOGIC_PACK"
local STATE_KEY = "lp_state_v1"
local PERSIST_TIMER = "LpPersist"
local STATUS_TIMER = "LpStatusPaint"
local PRUNE_TIMER = "LpPrune"
local SLOTS = 8

local EVENT_DEBOUNCED, EVENT_THROTTLED, EVENT_ONCE, EVENT_TIMER = 1, 2, 3, 4
local EVENT_STATE, EVENT_COUNTER, EVENT_FLAG, EVENT_READONLY, EVENT_RESTORED = 5, 6, 7, 8, 9

local gEngine = nil
local gDirty = false
local gHalted = false
local gLastTrigger = "none yet"

--- Seconds with fractions where the controller offers them (debounce and
--- throttle windows are in milliseconds). A test pins the clock by defining
--- LOGIC_PACK_NOW before loading the driver.
local gSocket = nil
local function now()
  if type(LOGIC_PACK_NOW) == "function" then
    return LOGIC_PACK_NOW()
  end
  if gSocket == nil then
    local ok, socket = pcall(require, "socket")
    gSocket = (ok and type(socket) == "table" and type(socket.gettime) == "function") and socket or false
  end
  if gSocket then
    return gSocket.gettime()
  end
  return os.time()
end

local function localDay(t)
  return os.date("%Y-%m-%d", math.floor(t))
end

local function fire(id)
  pcall(function()
    C4:FireEventByID(id)
  end)
end

local function setVar(name, value)
  pcall(function()
    C4:SetVariable(name, value)
  end)
end

-- ─── Slots ──────────────────────────────────────────────────────────────────

local function slotKey(n)
  return Engine.key(Properties["Counter Slot " .. n .. " Key"])
end

local function paintSlots()
  if gEngine == nil then
    return
  end
  for n = 1, SLOTS do
    local key = slotKey(n)
    setVar("COUNTER_" .. n, key and gEngine:counter(key) or 0)
  end
end

-- ─── Persistence ────────────────────────────────────────────────────────────

local function save()
  if gEngine == nil then
    return
  end
  gDirty = false
  persist:set(STATE_KEY, gEngine:serialize())
end

local function saveSoon()
  gDirty = true
  SetTimer(PERSIST_TIMER, 2 * ONE_SECOND, save)
end

-- ─── Status ─────────────────────────────────────────────────────────────────

local function packStatus()
  if gEngine == nil then
    return "starting"
  end
  if gHalted then
    return "read-only (licence)"
  end
  return "active"
end

local function summaryLine()
  if gEngine == nil then
    return "nothing yet"
  end
  local snap = gEngine:snapshot()
  return string.format(
    "%d counter(s), %d flag(s), %d timer(s) running, state: %s",
    #snap.counters,
    #snap.flags,
    #snap.timers,
    snap.state ~= "" and snap.state or "(none)"
  )
end

local function paint()
  local status = packStatus()
  UpdateProperty("Pack Status", status)
  UpdateProperty("Summary", summaryLine())
  UpdateProperty("Last Trigger", gLastTrigger)
  setVar("PACK_STATUS", status)
  paintSlots()
end

-- ─── Engine events → Composer ──────────────────────────────────────────────

local function stamp(text)
  gLastTrigger = string.format("%s (%s)", text, os.date("%H:%M:%S"))
  UpdateProperty("Last Trigger", gLastTrigger)
end

local function onEngineEvent(kind, f)
  saveSoon()
  if kind == "counter" then
    setVar("LAST_COUNTER_KEY", f.key)
    setVar("LAST_COUNTER_VALUE", f.value)
    for n = 1, SLOTS do
      if slotKey(n) == f.key then
        setVar("COUNTER_" .. n, f.value)
      end
    end
    fire(EVENT_COUNTER)
  elseif kind == "flag" then
    setVar("LAST_FLAG_KEY", f.key)
    setVar("LAST_FLAG_VALUE", f.value and "True" or "False")
    fire(EVENT_FLAG)
  elseif kind == "state" then
    setVar("CURRENT_STATE", f.state)
    setVar("PREVIOUS_STATE", f.previous)
    stamp("state → " .. (f.state ~= "" and f.state or "(none)"))
    fire(EVENT_STATE)
  elseif kind == "debounced" then
    setVar("LAST_TRIGGER_KEY", f.key)
    stamp("debounced " .. f.key)
    fire(EVENT_DEBOUNCED)
  elseif kind == "throttled" then
    setVar("LAST_TRIGGER_KEY", f.key)
    stamp("throttled " .. f.key)
    fire(EVENT_THROTTLED)
  elseif kind == "once_per_day" then
    setVar("ONCE_KEY", f.key)
    stamp("once per day " .. f.key)
    fire(EVENT_ONCE)
  elseif kind == "timer_expired" then
    setVar("LAST_TIMER_KEY", f.key)
    setVar("LAST_TIMER_LATE", f.late and "True" or "False")
    stamp("timer " .. f.key .. (f.late and " (late)" or ""))
    fire(EVENT_TIMER)
  end
end

local function refused(what, why)
  UpdateProperty("Last Refusal", string.format("%s: %s (%s)", what, tostring(why), os.date("%H:%M:%S")))
  log:warn("%s refused: %s", what, tostring(why))
end

--- Runs an engine mutation from a Composer command; records refusals.
local function run(what, fn)
  if gEngine == nil then
    return false
  end
  local ok, why = fn()
  if not ok then
    refused(what, why)
    return false
  end
  return true
end

-- ─── Licence ────────────────────────────────────────────────────────────────

local function reconcileLicence()
  local halt = license.enforces()
  if halt and not gHalted then
    gHalted = true
    gEngine:setReadOnly(true)
    log:warn("SmartBuildOS licence: %s — Logic Pack is read-only", tostring(license.statusLabel()))
    fire(EVENT_READONLY)
  elseif not halt and gHalted then
    gHalted = false
    gEngine:setReadOnly(false)
    fire(EVENT_RESTORED)
  end
  paint()
end

-- ─── Lifecycle ──────────────────────────────────────────────────────────────

local function registerComposerSurface()
  local vars = {
    { "CURRENT_STATE", "", "STRING" },
    { "PREVIOUS_STATE", "", "STRING" },
    { "LAST_TRIGGER_KEY", "", "STRING" },
    { "LAST_TIMER_KEY", "", "STRING" },
    { "LAST_TIMER_LATE", "False", "STRING" },
    { "LAST_COUNTER_KEY", "", "STRING" },
    { "LAST_COUNTER_VALUE", 0, "NUMBER" },
    { "LAST_FLAG_KEY", "", "STRING" },
    { "LAST_FLAG_VALUE", "False", "STRING" },
    { "ONCE_KEY", "", "STRING" },
    { "PACK_STATUS", "starting", "STRING" },
  }
  for n = 1, SLOTS do
    vars[#vars + 1] = { "COUNTER_" .. n, 0, "NUMBER" }
  end
  for _, v in ipairs(vars) do
    pcall(function()
      C4:AddVariable(v[1], v[2], v[3], true)
    end)
  end
  for _, e in ipairs({
    { 1, "Debounced Trigger", "A Debounce key stayed quiet for its window" },
    { 2, "Throttled Trigger", "A Throttle key fired" },
    { 3, "Once Per Day Passed", "A Once Per Day key passed for the first time today" },
    { 4, "Timer Expired", "A named timer expired" },
    { 5, "State Changed", "The state machine moved" },
    { 6, "Counter Changed", "A counter changed" },
    { 7, "Flag Changed", "A flag was set or cleared" },
    { 8, "Pack Read-Only", "The SmartBuildOS licence halted the pack" },
    { 9, "Pack Restored", "The pack is active again" },
  }) do
    pcall(function()
      C4:AddEvent(e[1], e[2], e[3])
    end)
  end
end

function OnDriverInit()
  --#ifdef DRIVERCENTRAL
  require("cloud-client-byte")
  C4:AllowExecute(false)
  --#else
  C4:AllowExecute(true)
  --#endif
  gInitialized = false
  log:setLogName("LogicPack")
  log:setLogLevel(Properties["Log Level"])
  log:setLogMode(Properties["Log Mode"])
end

function OnDriverLateInit(reason)
  if not CheckMinimumVersion("Driver Status") then
    return
  end
  registerComposerSurface()
  for p, _ in pairs(Properties) do
    pcall(OnPropertyChanged, p)
  end

  gEngine = Engine.new({
    now = now,
    schedule = function(id, ms, fn)
      SetTimer(id, ms, fn)
    end,
    cancel = function(id)
      CancelTimer(id)
    end,
    emit = onEngineEvent,
    localDay = localDay,
  })
  local stored = persist:get(STATE_KEY, false)
  if type(stored) == "table" then
    local ok, err = pcall(function()
      gEngine:restore(stored)
    end)
    if not ok then
      log:error("Persisted state unreadable (%s); starting empty", tostring(err))
    end
  end
  -- Variables reflect the restored state before any programming runs.
  setVar("CURRENT_STATE", gEngine.state)
  setVar("PREVIOUS_STATE", gEngine.previousState)

  license.setup({ sku = SKU })
  EC.SBOS_ENTITLEMENT = function(tParams)
    license.onEntitlement(tParams)
    reconcileLicence()
  end

  gInitialized = true
  UpdateProperty("Driver Status", "Online")
  pcall(function()
    UpdateProperty("Driver Version", tostring(C4:GetDriverConfigInfo("version")))
  end)
  SetTimer(STATUS_TIMER, 60 * ONE_SECOND, paint, true)
  SetTimer(PRUNE_TIMER, 10 * ONE_MINUTE, function()
    if gEngine then
      gEngine:pruneOnce()
    end
  end, true)
  paint()
end

function OnDriverDestroyed()
  pcall(license.stop) -- the licence retry timer
  if gEngine then
    save()
    gEngine:stop()
  end
  CancelTimer(PERSIST_TIMER)
  CancelTimer(STATUS_TIMER)
  CancelTimer(PRUNE_TIMER)
end

-- ─── Properties ─────────────────────────────────────────────────────────────

function OPC.Log_Level(value)
  log:setLogLevel(value)
  DEBUGPRINT = tostring(value):match("^5") ~= nil
end

function OPC.Log_Mode(value)
  log:setLogMode(value)
end

function OPC.Driver_Status()
  if not gInitialized then
    UpdateProperty("Driver Status", "Initializing", false)
  end
end

for n = 1, SLOTS do
  OPC["Counter_Slot_" .. n .. "_Key"] = function()
    if gInitialized then
      paintSlots()
    end
  end
end

-- ─── Actions ────────────────────────────────────────────────────────────────

function EC.REGISTER_NOW()
  license.register()
end

function EC.REFRESH_STATUS()
  paint()
end

function EC.RESET_COUNTERS_ACTION()
  run("Reset All Counters", function()
    return gEngine:resetAll("counters")
  end)
  paint()
end

function EC.RESET_FLAGS_ACTION()
  run("Clear All Flags", function()
    return gEngine:resetAll("flags")
  end)
  paint()
end

function EC.CANCEL_TIMERS_ACTION()
  run("Cancel All Timers", function()
    return gEngine:resetAll("timers")
  end)
  paint()
end

function EC.RESET_EVERYTHING_ACTION()
  run("Reset Everything", function()
    return gEngine:resetAll("everything")
  end)
  paint()
end

function EC.PRINT_STATE()
  if gEngine == nil then
    return
  end
  local snap = gEngine:snapshot()
  log:print("== Logic Pack ==")
  log:print("  status: %s", packStatus())
  log:print("  licence: %s", license.describe())
  log:print("  state: %s (previous: %s)", snap.state ~= "" and snap.state or "(none)", snap.previous_state)
  for _, t in ipairs(snap.transitions) do
    log:print("    %s  %s → %s", os.date("%H:%M:%S", math.floor(t.at)), t.from ~= "" and t.from or "(none)", t.to)
  end
  log:print("  counters (%d):", #snap.counters)
  for _, c in ipairs(snap.counters) do
    local slot = ""
    for n = 1, SLOTS do
      if slotKey(n) == c.key then
        slot = "  [slot " .. n .. "]"
      end
    end
    log:print("    %-40s %d%s", c.key, c.value, slot)
  end
  log:print("  flags set (%d): %s", #snap.flags, table.concat(snap.flags, ", "))
  log:print("  timers running (%d):", #snap.timers)
  for _, t in ipairs(snap.timers) do
    log:print("    %-40s %ds of %ds left", t.key, math.floor(t.remaining), t.seconds)
  end
  log:print("  once-per-day passed today (%d):", #snap.once)
  for _, o in ipairs(snap.once) do
    log:print("    %-40s %s", o.key, o.day)
  end
  local keys = {}
  for k in pairs(snap.counts) do
    keys[#keys + 1] = k
  end
  table.sort(keys)
  for _, k in ipairs(keys) do
    log:print("  %s = %d", k, snap.counts[k])
  end
end

-- ─── Composer programming commands ─────────────────────────────────────────

function EC.INCREMENT_COUNTER(t)
  t = t or {}
  run("Increment Counter", function()
    return gEngine:increment(t.KEY, t.BY)
  end)
end

function EC.DECREMENT_COUNTER(t)
  t = t or {}
  run("Decrement Counter", function()
    return gEngine:decrement(t.KEY, t.BY)
  end)
end

function EC.SET_COUNTER(t)
  t = t or {}
  run("Set Counter", function()
    return gEngine:setCounter(t.KEY, t.VALUE)
  end)
end

function EC.RESET_COUNTER(t)
  t = t or {}
  run("Reset Counter", function()
    return gEngine:resetCounter(t.KEY)
  end)
end

function EC.SET_FLAG(t)
  t = t or {}
  run("Set Flag", function()
    return gEngine:setFlag(t.KEY)
  end)
end

function EC.CLEAR_FLAG(t)
  t = t or {}
  run("Clear Flag", function()
    return gEngine:clearFlag(t.KEY)
  end)
end

function EC.TOGGLE_FLAG(t)
  t = t or {}
  run("Toggle Flag", function()
    return gEngine:toggleFlag(t.KEY)
  end)
end

function EC.SET_STATE(t)
  t = t or {}
  run("Set State", function()
    return gEngine:setState(t.STATE)
  end)
end

function EC.DEBOUNCE(t)
  t = t or {}
  run("Debounce", function()
    return gEngine:debounce(t.KEY, t.MILLISECONDS)
  end)
end

function EC.THROTTLE(t)
  t = t or {}
  run("Throttle", function()
    return gEngine:throttle(t.KEY, t.MILLISECONDS)
  end)
end

function EC.ONCE_PER_DAY(t)
  t = t or {}
  run("Once Per Day", function()
    return gEngine:oncePerDay(t.KEY)
  end)
end

function EC.START_TIMER(t)
  t = t or {}
  run("Start Timer", function()
    return gEngine:startTimer(t.KEY, t.SECONDS)
  end)
  saveSoon()
end

function EC.CANCEL_TIMER(t)
  t = t or {}
  run("Cancel Timer", function()
    return gEngine:cancelTimer(t.KEY)
  end)
  saveSoon()
end

local RESET_SCOPES = { Counters = "counters", Flags = "flags", Timers = "timers", Everything = "everything" }

function EC.RESET_ALL(t)
  t = t or {}
  local scope = RESET_SCOPES[tostring(t.WHAT or "")] or "everything"
  run("Reset All", function()
    return gEngine:resetAll(scope)
  end)
  paint()
end

-- ─── Conditionals (TestCondition name, tParams{VALUE, LOGIC}) ──────────────

for n = 1, SLOTS do
  TC["COUNTER_SLOT_" .. n] = function(_, tParams)
    tParams = tParams or {}
    local key = slotKey(n)
    local value = key and gEngine and gEngine:counter(key) or 0
    return Engine.compare(tParams.LOGIC, value, tonumber(tParams.VALUE))
  end
end

--- "= key" is true when the thing holds for key; "!= key" when it does not.
local function keyedTruth(tParams, holds)
  tParams = tParams or {}
  local answer = gEngine ~= nil and holds(tParams.VALUE) == true
  if tostring(tParams.LOGIC or "EQUAL"):upper() == "NOT_EQUAL" then
    return not answer
  end
  return answer
end

function TC.FLAG_SET(_, tParams)
  return keyedTruth(tParams, function(key)
    return gEngine:flag(key)
  end)
end

function TC.TIMER_RUNNING(_, tParams)
  return keyedTruth(tParams, function(key)
    return gEngine:timerRunning(key)
  end)
end

function TC.ONCE_TODAY_DONE(_, tParams)
  return keyedTruth(tParams, function(key)
    return gEngine:onceDoneToday(key)
  end)
end

function TC.STATE_IS(_, tParams)
  tParams = tParams or {}
  local wanted = tostring(tParams.VALUE or ""):gsub("^%s+", ""):gsub("%s+$", "")
  return Engine.compare(tParams.LOGIC, gEngine and gEngine.state or "", wanted)
end

function TC.PACK_ACTIVE()
  return gInitialized and not gHalted
end
