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

  LOGIC BLOCKS (the second half of this file). Named, typed rules in 16
  numbered slots, configured on the Properties and Actions tabs, fed by the
  BLOCK_* commands or a device variable, answering with per-slot events,
  variables and conditionals. They run on a second, private engine and their
  own persisted document (lb_state_v1), so nothing above changes: every
  free-form key, command, event, variable and conditional works as before,
  and a block never adopts a free-form key by having the same name.
  Rules: src/logic/blocks.lua, blockdefs.lua, blockdraft.lua. The dealer app
  (www/app, served on the LAN by src/logic/relay.lua) reports and simulates;
  Composer is the only place a block is configured.
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
-- REQUIRED though nothing here names it: lib.http (under sbos.mirror) calls
-- the GLOBAL urlDo, which this module defines.
require("drivers-common-public.global.url")
JSON = require("JSON")

local log = require("lib.logging")
local persist = require("lib.persist")
local license = require("sbos.license")
local Engine = require("logic.engine")
--- AI Core reporting (sbos.aireport, start mode). Module scope: the build
--- packs only modules it sees at load.
local aireport = require("sbos.aireport")
local Defs = require("logic.blockdefs")
local Blocks = require("logic.blocks")
local BlockDraft = require("logic.blockdraft")
local Sandbox = require("logic.sandbox")
local AppState = require("logic.appstate")
local Relay = require("logic.relay")
local RelayHost = require("lib.relayhost")
local appfile = require("lib.appfile")
local pagedata = require("logic.page")
local mirror = require("sbos.mirror")

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
local gHalted = false
local gLastTrigger = "none yet"

--- Everything the Logic Blocks half keeps, in ONE table: the main chunk has
--- a 200-local ceiling and a function a 60-upvalue one.
local LB = {
  blocks = nil, -- logic.blocks runtime
  draft = nil, -- logic.blockdraft
  sandbox = nil, -- logic.sandbox, at most one
  relayPort = nil,
  relayBuffers = {},
  relayToken = nil,
  appHtml = nil,
  appHtmlWhy = "",
  host = nil,
  armed = nil, -- a two-step action waiting for its second press
  startedAt = nil,
  devices = {}, -- label -> device id, for the Draft device lists
  mirrorOn = false,
}
local LB_STATE_KEY = "lb_state_v1"
local LB_DRAFT_KEY = "lb_draft_v1"
local LB_TOKEN_KEY = "lb_relay_token_v1"
local LB_PERSIST_TIMER = "LbPersist"
local LB_RELAY_PORT = 47871
local LB_RELAY_ID = "logic-blocks-ui-relay"
local LB_MAX_REQUEST = 64 * 1024
local C4Z_NAME = "smartbuildos-logic-pack"
local EVENT_BLOCKS_RESTORE_FAILED, EVENT_BLOCKS_APPLIED = 10, 11

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
  persist:set(STATE_KEY, gEngine:serialize())
end

local function saveSoon()
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

-- ─── AI Core (sbos.aireport, start mode) ────────────────────────────────────
--
-- Reported only when AI Core is installed (the helper sends nothing
-- otherwise):
--   describe   what the pack is: named counters, flags, a state machine and
--              timers for Composer programming
--   state      pack status and how many counters, flags and running timers
--              it holds (counts only: the key names are free text typed by
--              the programmer, and the values are household activity)
--   diagnostic the pack went read-only (licence) / was restored
--   events, queries, actions: none. Every command is Composer programming;
--              nothing here is safe to run on a model's say-so.

local function aiReportState(status)
  if gEngine == nil then
    return
  end
  local snap = gEngine:snapshot()
  aireport.state({
    pack_status = status,
    read_only = gHalted == true,
    counters = #snap.counters,
    flags = #snap.flags,
    timers_running = #snap.timers,
  })
end

local function startAiCore()
  aireport.start({ sku = SKU })
  aireport.describe({
    summary = "Programming building blocks for this home's Control4 system: named counters, on/off flags, a house state and countdown timers that the installer's programming uses.",
    controls = {
      { id = "counters", label = "Counters", class = "other" },
      { id = "flags", label = "Flags", class = "other" },
      { id = "house_state", label = "House state", class = "other" },
      { id = "timers", label = "Timers", class = "other" },
    },
    vocabulary = { "programming", "counter", "flag", "timer", "countdown", "state", "logic", "automation" },
  })
end

local function paint()
  local status = packStatus()
  UpdateProperty("Pack Status", status)
  UpdateProperty("Summary", summaryLine())
  UpdateProperty("Last Trigger", gLastTrigger)
  setVar("PACK_STATUS", status)
  paintSlots()
  aiReportState(status)
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
    if LB.blocks ~= nil then
      LB.blocks:setReadOnly(true)
    end
    log:warn("SmartBuildOS licence: %s — Logic Pack is read-only", tostring(license.statusLabel()))
    fire(EVENT_READONLY)
    aireport.diagnostic(
      "warning",
      "pack.read_only",
      "Logic Pack is read-only: the SmartBuildOS licence does not cover it"
    )
  elseif not halt and gHalted then
    gHalted = false
    gEngine:setReadOnly(false)
    if LB.blocks ~= nil then
      LB.blocks:setReadOnly(false)
    end
    fire(EVENT_RESTORED)
    aireport.diagnostic("info", "pack.restored", "Logic Pack accepts commands again")
  end
  paint()
  if LB.paint ~= nil then
    LB.paint()
  end
end

-- ═══ Logic Blocks ═══════════════════════════════════════════════════════════
--
-- Everything from here to "Lifecycle" is the adapter between Composer and
-- src/logic/blocks.lua. It owns no rule: it turns properties, actions and
-- commands into calls, and the runtime's answers into events, variables and
-- property lines.

local function lbSave()
  -- A stored document that could not be read is never written over.
  if LB.blocks == nil or LB.blocks.restoreFailed ~= nil then
    return
  end
  persist:set(LB_STATE_KEY, LB.blocks:serialize())
end

local function lbSaveSoon()
  SetTimer(LB_PERSIST_TIMER, 2 * ONE_SECOND, lbSave)
end

-- ─── Devices and variables (for direct input mappings) ─────────────────────

local function lbDevices()
  local ok, d = pcall(function()
    return C4:GetDevices({})
  end)
  if ok and type(d) == "table" then
    return d
  end
  return {}
end

--- { [variableId] = name } for one device, and whether Director answered.
local function lbVariables(deviceId)
  local ok, raw = pcall(function()
    return C4:GetDeviceVariables(deviceId)
  end)
  local out = {}
  if not ok or type(raw) ~= "table" then
    return out, false
  end
  for k, v in pairs(raw) do
    if type(v) == "table" then
      local id = tonumber(k) or tonumber(v.id)
      if id ~= nil then
        out[id] = tostring(v.name or id)
      end
    end
  end
  return out, true
end

--- "Kitchen Motion · 82" → 82. The id is what is stored; the name is for
--- people and may change.
local function lbPickId(text)
  return tonumber(tostring(text or ""):match("·%s*(%d+)%s*$"))
end

local function lbPickName(text)
  return (tostring(text or ""):gsub("%s*·%s*%d+%s*$", ""))
end

local function lbLabel(name, id)
  local clean = tostring(name or ""):gsub(",", " "):gsub("·", "-")
  return string.format("%s · %d", clean ~= "" and clean or "?", id)
end

local function lbVariableExists(deviceId, variableId)
  local devices = lbDevices()
  if devices[deviceId] == nil and devices[tostring(deviceId)] == nil then
    return false, string.format("device %d is not in the project", deviceId)
  end
  local vars = lbVariables(deviceId)
  if vars[variableId] == nil then
    return false, string.format("variable %d is not on device %d", variableId, deviceId)
  end
  return true
end

local function lbWatch(deviceId, variableId)
  local ok, why = lbVariableExists(deviceId, variableId)
  if not ok then
    return false, why
  end
  local registered = pcall(function()
    -- The shared handler prints a debug line (two Director calls) for every
    -- change unless told not to; a busy sensor would pay for that each time.
    OWVC = OWVC or {}
    OWVC.suppressDebug = OWVC.suppressDebug or {}
    OWVC.suppressDebug[deviceId] = OWVC.suppressDebug[deviceId] or {}
    OWVC.suppressDebug[deviceId][variableId] = true
    RegisterVariableListener(deviceId, variableId, function(dev, var, value)
      if LB.blocks ~= nil then
        LB.blocks:variable(tonumber(dev), tonumber(var), value)
      end
    end)
  end)
  if not registered then
    return false, "the listener could not be registered"
  end
  return true
end

local function lbUnwatch(deviceId, variableId)
  pcall(function()
    UnregisterVariableListener(deviceId, variableId)
  end)
end

local function lbNewId()
  LB.idCounter = (LB.idCounter or 0) + 1
  return string.format("b%x%x%x", os.time(), math.floor((os.clock() * 1000000) % 0xFFFFF), LB.idCounter)
end

local function lbNewBlocks()
  local selfId = nil
  pcall(function()
    selfId = tonumber(C4:GetDeviceID())
  end)
  return Blocks.new({
    origin = "live",
    now = now,
    schedule = function(id, ms, fn)
      SetTimer(id, math.max(1, math.floor(ms)), fn)
    end,
    cancel = function(id)
      CancelTimer(id)
    end,
    localDay = localDay,
    emit = function(slot, kind)
      local id = Defs.eventId(slot, kind)
      if id ~= nil then
        fire(id)
      end
    end,
    -- Written BEFORE the slot's event fires (logic.blocks guarantees the
    -- order), so programming on the event reads this decision's values.
    outputs = function(slot, out)
      setVar(Defs.variableName(slot, "ACTIVE"), out.active and "1" or "0")
      setVar(Defs.variableName(slot, "VALID"), out.valid and "1" or "0")
      setVar(Defs.variableName(slot, "VALUE"), tonumber(out.value) or 0)
      setVar(Defs.variableName(slot, "STATE"), tostring(out.state or ""))
    end,
    watch = lbWatch,
    unwatch = lbUnwatch,
    newId = lbNewId,
    changed = function()
      LB.dirty = true
      lbSaveSoon()
    end,
    refused = function(slot, what, why)
      refused((slot and Defs.slotLabel(slot) or "Block") .. " " .. tostring(what), why)
    end,
    selfDevice = selfId,
  })
end

-- ─── What the app and the properties are told ───────────────────────────────

local function lbLegacySummary()
  if gEngine == nil then
    return {}
  end
  local snap = gEngine:snapshot()
  return {
    counters = #snap.counters,
    flags = #snap.flags,
    timers = #snap.timers,
    once = #snap.once,
    state = snap.state,
    note = "Free-form keys used by the classic commands (INCREMENT_COUNTER, SET_FLAG, START_TIMER, …). They are separate from blocks.",
  }
end

local function lbHostState()
  if LB.host == nil then
    return "", "unknown"
  end
  return LB.host:host()
end

local function lbInfo()
  local host, hostState = lbHostState()
  return {
    now = now(),
    started_at = LB.startedAt,
    version = Properties["Driver Version"],
    status = Properties["Driver Status"],
    pack_status = packStatus(),
    read_only = gHalted == true,
    license = {
      status = Properties["License Status"],
      source = Properties["License Source"],
      tier = Properties["Subscription Tier"],
    },
    clock = {
      day = localDay(now()),
      tz = os.date("%Z"),
      utc_offset = os.date("%z"),
      basis = "Once Per Day uses the controller's local calendar day.",
    },
    legacy = lbLegacySummary(),
    transport = {
      kind = "LAN relay on the controller",
      listening = LB.relayPort ~= nil,
      port = LB_RELAY_PORT,
      host = host,
      host_state = hostState,
      mirror = LB.mirrorOn and "on (summary only; not verified end to end on a controller)" or "off",
      remote = "This page is reachable on the home network only.",
    },
  }
end

local function lbSelectedSlot()
  return Defs.parseSlot(Properties["Selected Block"])
end

local function lbStatusLine()
  if LB.blocks == nil then
    return "starting"
  end
  if LB.blocks.restoreFailed ~= nil then
    return "RESTORE FAILED: "
      .. LB.blocks.restoreFailed.why
      .. ". Nothing was reset and the stored copy is untouched. Blocks do nothing until Acknowledge Restore Failure is run."
  end
  local c = LB.blocks:counts()
  local faults, unreadable = 0, 0
  for slot = 1, Defs.SLOTS do
    local view = LB.blocks:view(slot)
    if view.kind == "unreadable" then
      unreadable = unreadable + 1
    elseif view.kind == "block" and (view.isolated ~= nil or (view.enabled and not view.output.valid)) then
      faults = faults + 1
    end
  end
  local line = string.format("%d of %d slots used, %d enabled, %d retired", c.used, Defs.SLOTS, c.enabled, c.retired)
  if faults > 0 then
    line = line .. string.format(", %d need attention", faults)
  end
  if unreadable > 0 then
    line = line .. string.format(", %d UNREADABLE", unreadable)
  end
  if gHalted then
    line = line .. " - read-only (licence)"
  end
  return line
end

local function lbBlocksLine()
  if LB.blocks == nil then
    return "none"
  end
  local parts = {}
  for _, slot in ipairs(LB.blocks:slots()) do
    local view = LB.blocks:view(slot)
    if view.kind == "block" then
      parts[#parts + 1] =
        string.format("%02d %s (%s%s)", slot, view.name, view.type_label, view.enabled and "" or ", disabled")
    elseif view.kind == "retired" then
      parts[#parts + 1] = string.format("%02d retired: %s", slot, view.retired.name)
    else
      parts[#parts + 1] = string.format("%02d UNREADABLE", slot)
    end
  end
  if #parts == 0 then
    return "none"
  end
  local line = table.concat(parts, "; ")
  if #line > 900 then
    line = line:sub(1, 897) .. "..."
  end
  return line
end

--- The Selected Block list: "-" then one entry per used slot. The entry
--- starts with the slot number, which is what is read back.
local function lbRefreshSelect()
  if LB.blocks == nil then
    return
  end
  local items = { "-" }
  for _, slot in ipairs(LB.blocks:slots()) do
    local view = LB.blocks:view(slot)
    local name = view.kind == "block" and view.name
      or view.kind == "retired" and ("(retired) " .. view.retired.name)
      or "(unreadable)"
    items[#items + 1] = string.format("%02d · %s", slot, (name:gsub(",", " ")))
  end
  local current = Properties["Selected Block"] or "-"
  local slot = Defs.parseSlot(current)
  local keep = "-"
  for _, item in ipairs(items) do
    if slot ~= nil and Defs.parseSlot(item) == slot then
      keep = item
    end
  end
  pcall(function()
    C4:UpdatePropertyList("Selected Block", table.concat(items, ","), keep)
  end)
  if keep ~= current then
    UpdateProperty("Selected Block", keep)
  end
end

local function lbSelectedLine()
  if LB.blocks == nil then
    return "-"
  end
  if LB.armed ~= nil and now() <= LB.armed.until_at then
    return LB.armed.text
  end
  LB.armed = nil
  local slot = lbSelectedSlot()
  if slot == nil then
    return "No block selected"
  end
  local view = LB.blocks:view(slot)
  if view.kind == "block" then
    return string.format("%s %s (%s): %s", view.label, view.name, view.type_label, view.status)
  end
  return string.format("%s: %s", view.label, view.status)
end

-- ─── The draft ↔ the Draft properties ───────────────────────────────────────

local LB_DRAFT_TEXT = {
  ["Draft Name"] = { "name", "" },
  ["Draft Tag"] = { "tag", "" },
  ["Draft Notes"] = { "notes", "" },
  ["Draft Duration"] = { "duration", "" },
  ["Draft Repeated Start"] = { "repeat_start", "Restart the countdown" },
  ["Draft After Restart"] = { "recovery", "Cancel if missed" },
  ["Draft Mode"] = { "mode", "All" },
  ["Draft Evaluation"] = { "evaluation", "Continuous output" },
  ["Draft Upper Threshold"] = { "upper", "" },
  ["Draft Lower Threshold"] = { "lower", "" },
  ["Draft Units"] = { "units", "" },
  ["Draft Counter Threshold"] = { "counter_threshold", "" },
  ["Draft Counter Comparison"] = { "counter_comparison", ">=" },
  ["Draft States"] = { "states", "" },
  ["Draft Initial State"] = { "initial_state", "" },
  ["Draft Transitions"] = { "transitions", "" },
  ["Draft Adopt Legacy Key"] = { "adopt_legacy", "" },
}

local function lbDeviceItems()
  local list = {}
  LB.devices = {}
  for rawId, d in pairs(lbDevices()) do
    local id = tonumber(rawId)
    if id ~= nil and type(d) == "table" then
      list[#list + 1] = { id = id, label = lbLabel(d.deviceName or d.name or ("Device " .. id), id) }
    end
  end
  table.sort(list, function(a, b)
    return a.label:lower() < b.label:lower()
  end)
  local items = { "-" }
  for i, entry in ipairs(list) do
    if i > 500 then
      break
    end
    items[#items + 1] = entry.label
  end
  return table.concat(items, ",")
end

local function lbVariableItems(deviceId)
  if deviceId == nil then
    return "-"
  end
  local list = {}
  for id, name in pairs((lbVariables(deviceId))) do
    list[#list + 1] = { id = id, label = lbLabel(name, id) }
  end
  table.sort(list, function(a, b)
    return a.label:lower() < b.label:lower()
  end)
  local items = { "-" }
  for _, entry in ipairs(list) do
    items[#items + 1] = entry.label
  end
  return table.concat(items, ",")
end

local function lbSetList(prop, csv, value)
  pcall(function()
    C4:UpdatePropertyList(prop, csv, value)
  end)
end

--- Shows only the Draft properties the draft's type uses. Display only: a
--- hidden property is still read by nothing, because validate() takes just
--- the fields the type owns.
local function lbDraftVisibility()
  local typeId = LB.draft ~= nil and LB.draft:typeId() or nil
  local uses = typeId and BlockDraft.USES[typeId] or {}
  local inputs = typeId and Defs.TYPES[typeId].inputs or 0
  local function show(prop, visible)
    pcall(function()
      C4:SetPropertyAttribs(prop, visible and 0 or 1)
    end)
  end
  for prop, spec in pairs(LB_DRAFT_TEXT) do
    local field = spec[1]
    local always = field == "name" or field == "tag" or field == "notes"
    show(prop, typeId ~= nil and (always or uses[field] == true))
  end
  for i = 1, Defs.MAX_INPUTS do
    local visible = typeId ~= nil and i <= inputs
    show("Draft Input " .. i .. " Label", visible)
    show("Draft Input " .. i .. " Device", visible)
    show("Draft Input " .. i .. " Variable", visible)
    show("Draft Input " .. i .. " True When", visible and typeId ~= "threshold")
  end
  for _, prop in ipairs({
    "Draft Feedback Device",
    "Draft Feedback Variable",
    "Draft Feedback Expect",
    "Draft Feedback Within",
    "Draft Check",
    "Draft Impact",
  }) do
    show(prop, typeId ~= nil)
  end
end

--- Writes the draft into the Draft properties (after New Draft, Edit
--- Selected Block, Load Template Into Draft, Discard Draft).
local function lbWriteDraft()
  local raw = LB.draft ~= nil and LB.draft.raw or nil
  for prop, spec in pairs(LB_DRAFT_TEXT) do
    local value = raw and raw[spec[1]] or nil
    if value == nil or value == "" then
      value = spec[2]
    end
    UpdateProperty(prop, tostring(value))
  end
  local devices = raw ~= nil and lbDeviceItems() or "-"
  for i = 1, Defs.MAX_INPUTS do
    local input = raw and raw.inputs[i] or {}
    UpdateProperty("Draft Input " .. i .. " Label", tostring(input.label or ""))
    UpdateProperty("Draft Input " .. i .. " True When", tostring(input.true_when or ""))
    local dev = input.device_id and lbLabel(input.device_name, input.device_id) or "-"
    local var = input.variable_id and lbLabel(input.variable_name, input.variable_id) or "-"
    lbSetList("Draft Input " .. i .. " Device", devices, dev)
    UpdateProperty("Draft Input " .. i .. " Device", dev)
    lbSetList("Draft Input " .. i .. " Variable", lbVariableItems(input.device_id), var)
    UpdateProperty("Draft Input " .. i .. " Variable", var)
  end
  local fb = raw and raw.feedback or {}
  local fbDev = fb.device_id and lbLabel(fb.device_name, fb.device_id) or "-"
  local fbVar = fb.variable_id and lbLabel(fb.variable_name, fb.variable_id) or "-"
  lbSetList("Draft Feedback Device", devices, fbDev)
  UpdateProperty("Draft Feedback Device", fbDev)
  lbSetList("Draft Feedback Variable", lbVariableItems(fb.device_id), fbVar)
  UpdateProperty("Draft Feedback Variable", fbVar)
  UpdateProperty("Draft Feedback Expect", tostring(fb.expect or ""))
  UpdateProperty("Draft Feedback Within", tostring(fb.within or "10s"))
  UpdateProperty("Draft Check", raw ~= nil and "Not checked. Run Validate Draft." or "-")
  UpdateProperty("Draft Impact", "-")
  UpdateProperty("Draft", LB.draft ~= nil and LB.draft:describe() or "No draft")
  lbDraftVisibility()
  if LB.draft ~= nil then
    local doc = LB.draft:serialize()
    if doc ~= nil then
      persist:set(LB_DRAFT_KEY, doc)
    else
      persist:delete(LB_DRAFT_KEY)
    end
  end
end

--- One Draft property changed in Composer. It changes the DRAFT only.
local function lbDraftProperty(prop, value)
  if LB.draft == nil or not LB.draft:active() then
    return
  end
  value = tostring(value or "")
  local spec = LB_DRAFT_TEXT[prop]
  if spec ~= nil then
    LB.draft:set(spec[1], value)
  else
    local index, what = prop:match("^Draft Input (%d) (.+)$")
    index = tonumber(index)
    if index ~= nil then
      if what == "Label" then
        LB.draft:setInput(index, "label", value)
      elseif what == "True When" then
        LB.draft:setInput(index, "true_when", value)
      elseif what == "Device" then
        local id = lbPickId(value)
        LB.draft:setInput(index, "device_id", id)
        LB.draft:setInput(index, "device_name", id and lbPickName(value) or nil)
        LB.draft:setInput(index, "variable_id", nil)
        LB.draft:setInput(index, "variable_name", nil)
        lbSetList(prop:gsub("Device$", "Variable"), lbVariableItems(id), "-")
        UpdateProperty("Draft Input " .. index .. " Variable", "-")
      elseif what == "Variable" then
        local id = lbPickId(value)
        LB.draft:setInput(index, "variable_id", id)
        LB.draft:setInput(index, "variable_name", id and lbPickName(value) or nil)
      end
    elseif prop == "Draft Feedback Device" then
      local id = lbPickId(value)
      LB.draft:setFeedback("device_id", id)
      LB.draft:setFeedback("device_name", id and lbPickName(value) or nil)
      LB.draft:setFeedback("variable_id", nil)
      LB.draft:setFeedback("variable_name", nil)
      lbSetList("Draft Feedback Variable", lbVariableItems(id), "-")
      UpdateProperty("Draft Feedback Variable", "-")
    elseif prop == "Draft Feedback Variable" then
      local id = lbPickId(value)
      LB.draft:setFeedback("variable_id", id)
      LB.draft:setFeedback("variable_name", id and lbPickName(value) or nil)
    elseif prop == "Draft Feedback Expect" then
      LB.draft:setFeedback("expect", value)
    elseif prop == "Draft Feedback Within" then
      LB.draft:setFeedback("within", value)
    else
      return
    end
  end
  UpdateProperty("Draft", LB.draft:describe())
  if LB.draft.checked == nil then
    UpdateProperty("Draft Check", "Changed since the last check. Run Validate Draft.")
    UpdateProperty("Draft Impact", "-")
  end
end

--- After a restart: the draft's purpose is restored from storage and its
--- text is read back from Composer's own properties.
local function lbRestoreDraft()
  local doc = persist:get(LB_DRAFT_KEY, false)
  if type(doc) ~= "table" or Defs.TYPES[doc.type] == nil then
    return
  end
  local ok
  if doc.target ~= nil then
    ok = LB.draft:load(tonumber(doc.target))
  else
    ok = LB.draft:start(doc.type, Properties["Draft Name"])
  end
  if not ok then
    persist:delete(LB_DRAFT_KEY)
    return
  end
  for prop in pairs(LB_DRAFT_TEXT) do
    lbDraftProperty(prop, Properties[prop])
  end
  for i = 1, Defs.MAX_INPUTS do
    local dev = Properties["Draft Input " .. i .. " Device"]
    local var = Properties["Draft Input " .. i .. " Variable"]
    LB.draft:setInput(i, "label", Properties["Draft Input " .. i .. " Label"])
    LB.draft:setInput(i, "true_when", Properties["Draft Input " .. i .. " True When"])
    LB.draft:setInput(i, "device_id", lbPickId(dev))
    LB.draft:setInput(i, "device_name", lbPickId(dev) and lbPickName(dev) or nil)
    LB.draft:setInput(i, "variable_id", lbPickId(var))
    LB.draft:setInput(i, "variable_name", lbPickId(var) and lbPickName(var) or nil)
  end
  local fbDev, fbVar = Properties["Draft Feedback Device"], Properties["Draft Feedback Variable"]
  LB.draft:setFeedback("device_id", lbPickId(fbDev))
  LB.draft:setFeedback("device_name", lbPickId(fbDev) and lbPickName(fbDev) or nil)
  LB.draft:setFeedback("variable_id", lbPickId(fbVar))
  LB.draft:setFeedback("variable_name", lbPickId(fbVar) and lbPickName(fbVar) or nil)
  LB.draft:setFeedback("expect", Properties["Draft Feedback Expect"])
  LB.draft:setFeedback("within", Properties["Draft Feedback Within"])
end

-- ─── The dealer app relay (the Atmosphere transport) ────────────────────────

local function lbRelayToken()
  if LB.relayToken ~= nil then
    return LB.relayToken
  end
  local stored = persist:get(LB_TOKEN_KEY, nil, true)
  if type(stored) == "string" and #stored >= 16 then
    LB.relayToken = stored
    return stored
  end
  local seed = string.format("%d|%d|%s|%s", os.time(), os.clock() * 1000000, tostring(LB), tostring({}))
  local ok, hex = pcall(function()
    return C4:HMAC("SHA256", seed, "logic-blocks-relay", { return_encoding = "HEX" })
  end)
  local token = ok and type(hex) == "string" and #hex >= 16 and hex:sub(1, 32)
    or (tostring(os.time()) .. tostring(math.floor(os.clock() * 1000000)))
  LB.relayToken = token
  persist:set(LB_TOKEN_KEY, token, true)
  return token
end

local function lbAppHtml()
  if LB.appHtml ~= nil then
    return LB.appHtml
  end
  -- The page is compiled into the driver (tools/embed-pages.lua): OS 4.3
  -- refuses a driver read access to its own c4z files.
  if type(pagedata) == "string" and #pagedata >= 512 then
    LB.appHtml = pagedata
    LB.appHtmlWhy = "embedded in the driver"
    return LB.appHtml
  end
  local html, report = appfile.read(C4Z_NAME, "app/index.html", C4, 512)
  LB.appHtmlWhy = report or ""
  if html ~= nil then
    LB.appHtml = html
  end
  return LB.appHtml
end

local function lbSandboxState()
  if LB.sandbox == nil then
    return { ok = true, open = false }
  end
  local state = LB.sandbox:state()
  state.ok, state.open = true, true
  return state
end

--- Every write the page can make lands here, and only here. It touches the
--- sandbox and nothing else.
local function lbSandbox(op, body)
  if op == nil then
    return lbSandboxState()
  end
  if op == "open" then
    local slot = tonumber(body.slot)
    local block = slot and LB.blocks.blocks[slot] or nil
    if block == nil then
      return { ok = false, error = "that slot holds no block" }
    end
    local sources = {}
    for _, row in ipairs(LB.blocks:view(slot).sources or {}) do
      if row.mode == "variable" and row.status == "ok" then
        sources[row.index] = row.value
      end
    end
    local sandbox, why = Sandbox.open({
      def = Blocks.copy(block),
      slot = slot,
      now = now(),
      localDay = localDay,
      sources = sources,
    })
    if sandbox == nil then
      return { ok = false, error = tostring(why) }
    end
    LB.sandbox = sandbox
    return lbSandboxState()
  end
  if op == "close" then
    LB.sandbox = nil
    return lbSandboxState()
  end
  if LB.sandbox == nil then
    return { ok = false, error = "no sandbox is open" }
  end
  if op == "input" then
    LB.sandbox:input(tostring(body.command or ""), { VALUE = body.value, BY = body.by, INPUT = body.input })
  elseif op == "source" then
    LB.sandbox:source(tonumber(body.index) or 1, body.value, body.unavailable == true)
  elseif op == "advance" then
    local ok, why = LB.sandbox:advance(tonumber(body.seconds))
    if not ok then
      return { ok = false, error = tostring(why) }
    end
  elseif op == "reset" then
    LB.sandbox:reset()
  elseif op == "replay" then
    LB.sandbox:replay(type(body.steps) == "table" and body.steps or nil)
  end
  return lbSandboxState()
end

local lbRelayProvider = {
  appHtml = lbAppHtml,
  state = function()
    return AppState.build(LB.blocks, lbInfo())
  end,
  activity = function(query)
    return AppState.activity(LB.blocks, query)
  end,
  export = function()
    return AppState.export(LB.blocks, lbInfo())
  end,
  sandbox = lbSandbox,
  encode = function(t)
    return JSON:encode(t)
  end,
  decode = function(s)
    return JSON:decode(tostring(s))
  end,
}

function OnServerDataIn(handle, data, _, _, identifier)
  if identifier ~= nil and identifier ~= LB_RELAY_ID then
    return
  end
  LB.relayBuffers[handle] = (LB.relayBuffers[handle] or "") .. tostring(data or "")
  if #LB.relayBuffers[handle] > LB_MAX_REQUEST then
    LB.relayBuffers[handle] = nil
    pcall(function()
      C4:ServerCloseClient(handle)
    end)
    return
  end
  local req = Relay.parse(LB.relayBuffers[handle])
  if req == nil then
    return
  end
  LB.relayBuffers[handle] = nil
  local result
  if LB.blocks == nil then
    result =
      { status = "503 Service Unavailable", contentType = "application/json", body = '{"ok":false,"error":"starting"}' }
  else
    result = Relay.route(req, lbRelayToken(), lbRelayProvider)
  end
  pcall(function()
    C4:ServerSend(handle, Relay.render(result))
  end)
  pcall(function()
    C4:ServerCloseClient(handle)
  end)
end

local function lbStopRelay()
  if LB.relayPort ~= nil then
    pcall(function()
      C4:DestroyServer(LB.relayPort)
    end)
    LB.relayPort = nil
  end
  LB.relayBuffers = {}
end

local function lbStartRelay()
  if Properties["Dealer App Access"] == "Off" then
    lbStopRelay()
    return
  end
  if LB.relayPort ~= nil then
    return
  end
  local ok = pcall(function()
    C4:CreateServer(LB_RELAY_PORT, "", false, LB_RELAY_ID)
  end)
  if ok then
    LB.relayPort = LB_RELAY_PORT
    log:info("Dealer app relay listening on port %d", LB_RELAY_PORT)
  else
    log:warn("Dealer app relay could not listen on port %d", LB_RELAY_PORT)
  end
end

--- The Dealer App and App Data Relay property lines. The address carries
--- the token, so it is written to the property and never to the log.
local function lbPaintRelay()
  if Properties["Dealer App Access"] == "Off" then
    UpdateProperty("App Data Relay", "Off")
    UpdateProperty("Dealer App", "Off (Dealer App Access)")
    return
  end
  if LB.relayPort == nil then
    UpdateProperty("App Data Relay", string.format("Not listening - port %d unavailable", LB_RELAY_PORT))
    UpdateProperty("Dealer App", "Not available: the controller port could not be opened")
    return
  end
  UpdateProperty("App Data Relay", LB.host ~= nil and LB.host:statusLine() or "Listening")
  local host = lbHostState()
  if host == "" then
    UpdateProperty("Dealer App", "Controller address unknown: set App Relay Address to the controller's IP address")
  elseif lbAppHtml() == nil then
    UpdateProperty("Dealer App", "Not available: the page could not be loaded (" .. tostring(LB.appHtmlWhy) .. ")")
  else
    UpdateProperty("Dealer App", string.format("http://%s:%d/app?k=%s", host, LB.relayPort, lbRelayToken()))
  end
end

LB.host = RelayHost.new({
  port = LB_RELAY_PORT,
  service = Relay.SERVICE,
  configured = function()
    return Properties["App Relay Address"]
  end,
  onChange = function()
    if gInitialized then
      lbPaintRelay()
    end
  end,
})

-- ─── Optional cloud summary (off unless the dealer turns it on) ─────────────

local function lbMirrorToken()
  local stored = persist:get("lb_mirror_token_v1", nil, true)
  if type(stored) == "string" and #stored >= 16 then
    return stored
  end
  local ok, hex = pcall(function()
    return C4:HMAC("SHA256", tostring(os.time()) .. tostring({}), "logic-blocks-mirror", { return_encoding = "HEX" })
  end)
  if not ok or type(hex) ~= "string" or #hex < 32 then
    return nil
  end
  local token = hex:sub(1, 32)
  persist:set("lb_mirror_token_v1", token, true)
  return token
end

--- Sends nothing unless Cloud Status Mirror is On. When it is, the document
--- is logic.appstate.summary: names, types and health. No source values, no
--- history, no notes. Its read token is never shown anywhere, so the
--- public capability URL is of use to nobody; SmartBuildOS staff tooling is
--- the only reader today.
local function lbConfigureMirror()
  local on = Properties["Cloud Status Mirror"] == "On" and LB.blocks ~= nil
  if on and not LB.mirrorOn then
    local token = lbMirrorToken()
    if token == nil then
      return
    end
    mirror.setup({
      sku = SKU,
      token = token,
      state = function()
        return AppState.summary(LB.blocks, lbInfo())
      end,
    })
    LB.mirrorOn = true
    mirror.publish(true)
  elseif not on and LB.mirrorOn then
    mirror.setup({})
    LB.mirrorOn = false
  end
end

-- ─── Painting ───────────────────────────────────────────────────────────────

local function lbPaint()
  if LB.blocks == nil then
    return
  end
  UpdateProperty("Blocks Status", lbStatusLine())
  UpdateProperty("Blocks", lbBlocksLine())
  if LB.listRevision ~= LB.blocks.revision then
    LB.listRevision = LB.blocks.revision
    lbRefreshSelect()
  end
  UpdateProperty("Selected Block Status", lbSelectedLine())
  UpdateProperty("Draft", LB.draft ~= nil and LB.draft:describe() or "No draft")
  lbPaintRelay()
end

--- Once a minute: time-driven variable states, watched variables that went
--- away or came back, the heartbeat Resume remaining needs, the address.
local function lbTick()
  if LB.blocks == nil then
    return
  end
  LB.blocks:tick(60)
  LB.blocks:checkWatches(lbVariableExists)
  if LB.blocks:needsHeartbeat() then
    lbSave()
  end
  if LB.relayPort ~= nil then
    LB.host:checkIfDue()
  end
  if LB.mirrorOn then
    mirror.publish(LB.dirty == true)
  end
  LB.dirty = false
  lbPaint()
end

local function lbStart()
  LB.startedAt = now()
  LB.blocks = lbNewBlocks()
  local stored = persist:get(LB_STATE_KEY, false)
  local report
  if stored ~= false and stored ~= nil then
    local ok, result = pcall(function()
      return LB.blocks:restore(stored)
    end)
    if ok then
      report = result
    else
      -- An error half-way through leaves a runtime that cannot be trusted.
      LB.blocks = lbNewBlocks()
      LB.blocks.restoreFailed = { why = "restoring the stored blocks raised an error", at = now() }
      LB.blocks.recovery = { at = now(), failed = LB.blocks.restoreFailed.why, notes = { tostring(result) } }
      report = { ok = false, failed = true, why = LB.blocks.restoreFailed.why }
    end
  end
  if report ~= nil and report.failed then
    log:error("Logic Blocks NOT restored: %s. Nothing was reset.", tostring(report.why))
    fire(EVENT_BLOCKS_RESTORE_FAILED)
    aireport.diagnostic("error", "blocks.restore_failed", "Logic Blocks could not be restored after a restart")
  elseif report ~= nil then
    for _, note in ipairs(report.notes or {}) do
      log:info("Blocks recovery: %s", note)
    end
  end
  LB.draft = BlockDraft.new(LB.blocks, {
    legacy = {
      describe = function(text)
        local key = Engine.key(text)
        if key == nil or gEngine == nil then
          return nil
        end
        local found = {
          counter = gEngine.counters[key],
          flag = gEngine.flags[key] == true and true or nil,
          timer = gEngine.timers[key] ~= nil or nil,
          once = gEngine.once[key] ~= nil or nil,
        }
        if next(found) == nil then
          return nil
        end
        return found
      end,
    },
  })
  lbRestoreDraft()
  lbDraftVisibility()
  LB.blocks:refreshAll()
  lbStartRelay()
  LB.host:check()
  lbConfigureMirror()
  lbPaint()
end

local function lbStop()
  if LB.blocks ~= nil then
    lbSave()
    LB.blocks:stop()
  end
  lbStopRelay()
  CancelTimer(LB_PERSIST_TIMER)
end

--- Says what happened to a configuration action, in Last Refusal when it
--- was refused and in Draft Check / Selected Block Status otherwise.
local function lbConfigured(slot)
  fire(EVENT_BLOCKS_APPLIED)
  lbSave()
  LB.listRevision = nil
  if slot ~= nil then
    local view = LB.blocks:view(slot)
    if view.kind == "block" then
      UpdateProperty("Selected Block", string.format("%02d · %s", slot, (view.name:gsub(",", " "))))
    end
  end
  lbPaint()
end

local function lbSelectedOrRefuse(what)
  if LB.blocks == nil then
    return nil
  end
  local slot = lbSelectedSlot()
  if slot == nil then
    refused(what, "pick a block in Selected Block first")
    return nil
  end
  return slot
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
    { EVENT_BLOCKS_RESTORE_FAILED, "Blocks Restore Failed", "The stored Logic Blocks could not be read at startup" },
    {
      EVENT_BLOCKS_APPLIED,
      "Blocks Configuration Applied",
      "A block was created, changed, enabled, disabled or retired",
    },
  }) do
    pcall(function()
      C4:AddEvent(e[1], e[2], e[3])
    end)
  end
  -- The per-slot surface. APPENDED after everything above and added in slot
  -- order: Composer binds by id and by add order, so this list only grows.
  -- XML events register only when an instance is first added, so an update
  -- in place needs them added here too (ids are permanent).
  for slot = 1, Defs.SLOTS do
    for _, v in ipairs(Defs.VARIABLES) do
      pcall(function()
        C4:AddVariable(Defs.variableName(slot, v.suffix), v.type == "NUMBER" and 0 or v.default, v.type, true)
      end)
    end
    for _, kind in ipairs(Defs.EVENTS) do
      pcall(function()
        C4:AddEvent(
          Defs.eventId(slot, kind),
          Defs.eventName(slot, kind),
          Defs.slotLabel(slot) .. ": " .. Defs.EVENT_LABELS[kind]
        )
      end)
    end
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

  lbStart()
  LB.paint = lbPaint

  license.setup({ sku = SKU })
  EC.SBOS_ENTITLEMENT = function(tParams)
    license.onEntitlement(tParams)
    reconcileLicence()
  end
  startAiCore()

  gInitialized = true
  UpdateProperty("Driver Status", "Online")
  pcall(function()
    UpdateProperty("Driver Version", tostring(C4:GetDriverConfigInfo("version")))
  end)
  SetTimer(STATUS_TIMER, 60 * ONE_SECOND, function()
    paint()
    lbTick()
  end, true)
  SetTimer(PRUNE_TIMER, 10 * ONE_MINUTE, function()
    if gEngine then
      gEngine:pruneOnce()
    end
  end, true)
  paint()
end

function OnDriverDestroyed()
  pcall(license.stop) -- the licence retry timer
  aireport.stop()
  if gEngine then
    save()
    gEngine:stop()
  end
  lbStop()
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
  lbPaint()
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

-- ═══ Logic Blocks: properties, actions, commands, conditionals ══════════════

for prop in pairs(LB_DRAFT_TEXT) do
  OPC[(prop:gsub(" ", "_"))] = function(value)
    lbDraftProperty(prop, value)
  end
end
for i = 1, Defs.MAX_INPUTS do
  for _, what in ipairs({ "Label", "Device", "Variable", "True When" }) do
    local prop = "Draft Input " .. i .. " " .. what
    OPC[(prop:gsub(" ", "_"))] = function(value)
      lbDraftProperty(prop, value)
    end
  end
end
for _, prop in ipairs({
  "Draft Feedback Device",
  "Draft Feedback Variable",
  "Draft Feedback Expect",
  "Draft Feedback Within",
}) do
  OPC[(prop:gsub(" ", "_"))] = function(value)
    lbDraftProperty(prop, value)
  end
end

function OPC.Selected_Block()
  if gInitialized then
    LB.armed = nil
    UpdateProperty("Selected Block Status", lbSelectedLine())
  end
end

function OPC.Dealer_App_Access()
  if gInitialized then
    lbStartRelay()
    if LB.relayPort ~= nil then
      LB.host:check()
    end
    lbPaintRelay()
  end
end

function OPC.App_Relay_Address()
  if gInitialized then
    LB.host:check()
    lbPaintRelay()
  end
end

function OPC.Cloud_Status_Mirror()
  if gInitialized then
    lbConfigureMirror()
  end
end

-- ─── Draft actions ──────────────────────────────────────────────────────────

local function lbDraftStarted(ok, why, what)
  if not ok then
    refused(what, why)
    return
  end
  lbWriteDraft()
  lbPaint()
end

function EC.BLOCK_DRAFT_NEW()
  if LB.blocks == nil then
    return
  end
  local ok, why = LB.draft:start(Properties["New Block Type"], Properties["New Block Name"])
  lbDraftStarted(ok, why, "New Draft")
end

function EC.BLOCK_DRAFT_TEMPLATE()
  if LB.blocks == nil then
    return
  end
  local ok, why = LB.draft:fromTemplate(Properties["Template"])
  lbDraftStarted(ok, why, "Load Template Into Draft")
end

function EC.BLOCK_DRAFT_EDIT()
  local slot = lbSelectedOrRefuse("Edit Selected Block")
  if slot == nil then
    return
  end
  local ok, why = LB.draft:load(slot)
  lbDraftStarted(ok, why, "Edit Selected Block")
end

function EC.BLOCK_DRAFT_VALIDATE()
  if LB.blocks == nil then
    return
  end
  local ok, lines = LB.draft:validate()
  if ok then
    UpdateProperty("Draft Check", "Valid. Run Apply Draft to make it live.")
    UpdateProperty("Draft Impact", table.concat(lines, " "))
  else
    UpdateProperty("Draft Check", "NOT VALID: " .. table.concat(lines, "; "))
    UpdateProperty("Draft Impact", "-")
  end
  UpdateProperty("Draft", LB.draft:describe())
end

function EC.BLOCK_DRAFT_APPLY()
  if LB.blocks == nil then
    return
  end
  local ok, result = LB.draft:apply()
  if not ok then
    -- Nothing was applied: the live block is exactly as it was.
    UpdateProperty("Draft Check", "NOT APPLIED: " .. table.concat(result, "; "))
    UpdateProperty("Draft Impact", "-")
    refused("Apply Draft", table.concat(result, "; "))
    return
  end
  persist:delete(LB_DRAFT_KEY)
  lbWriteDraft()
  UpdateProperty("Draft Check", string.format("Applied to %s.", Defs.slotLabel(result)))
  lbConfigured(result)
end

function EC.BLOCK_DRAFT_DISCARD()
  if LB.blocks == nil then
    return
  end
  LB.draft:discard()
  persist:delete(LB_DRAFT_KEY)
  lbWriteDraft()
  lbPaint()
end

-- ─── Selected-block actions ─────────────────────────────────────────────────

local function lbSetEnabled(enabled, what)
  local slot = lbSelectedOrRefuse(what)
  if slot == nil then
    return
  end
  local ok, why = LB.blocks:setEnabled(slot, enabled)
  if not ok then
    refused(what, why)
    return
  end
  lbConfigured(slot)
end

function EC.BLOCK_ENABLE_SELECTED()
  lbSetEnabled(true, "Enable Selected Block")
end

function EC.BLOCK_DISABLE_SELECTED()
  lbSetEnabled(false, "Disable Selected Block")
end

function EC.BLOCK_RESUME_SELECTED()
  local slot = lbSelectedOrRefuse("Resume Selected Block")
  if slot == nil then
    return
  end
  local ok, why = LB.blocks:resume(slot)
  if not ok then
    refused("Resume Selected Block", why)
    return
  end
  lbConfigured(slot)
end

function EC.BLOCK_COPY_SELECTED()
  local slot = lbSelectedOrRefuse("Copy Selected Block")
  if slot == nil then
    return
  end
  local created, why = LB.blocks:copyBlock(slot, Properties["New Block Name"])
  if created == nil then
    refused("Copy Selected Block", why)
    return
  end
  lbConfigured(created)
end

--- Two presses: the first says what would happen and arms it for a minute,
--- the second does it.
local function lbTwoStep(what, slot, text, act)
  if LB.armed ~= nil and LB.armed.what == what and LB.armed.slot == slot and now() <= LB.armed.until_at then
    LB.armed = nil
    act()
    return
  end
  LB.armed = {
    what = what,
    slot = slot,
    until_at = now() + 60,
    text = string.format(
      "%s %s? %s Run %s again within 60 seconds to confirm.",
      what:upper(),
      Defs.slotLabel(slot),
      text,
      what
    ),
  }
  UpdateProperty("Selected Block Status", LB.armed.text)
end

function EC.BLOCK_RETIRE_SELECTED()
  local slot = lbSelectedOrRefuse("Retire Selected Block")
  if slot == nil then
    return
  end
  if LB.blocks.blocks[slot] == nil then
    refused("Retire Selected Block", "that slot holds no block")
    return
  end
  lbTwoStep("Retire Selected Block", slot, table.concat(LB.blocks:stopImpact(slot, true), " "), function()
    local ok, why = LB.blocks:retire(slot)
    if not ok then
      refused("Retire Selected Block", why)
      return
    end
    lbConfigured(nil)
  end)
end

function EC.BLOCK_RELEASE_SELECTED()
  local slot = lbSelectedOrRefuse("Release Retired Slot")
  if slot == nil then
    return
  end
  if LB.blocks.retired[slot] == nil then
    refused("Release Retired Slot", "that slot holds no retired block")
    return
  end
  lbTwoStep(
    "Release Retired Slot",
    slot,
    string.format(
      'Programming that still uses %s was written for "%s". After this, the next new block may land in %s and that programming will drive it.',
      Defs.slotLabel(slot),
      LB.blocks.retired[slot].name,
      Defs.slotLabel(slot)
    ),
    function()
      local ok, why = LB.blocks:releaseRetired(slot)
      if not ok then
        refused("Release Retired Slot", why)
        return
      end
      lbConfigured(nil)
    end
  )
end

function EC.BLOCK_REFRESH_LISTS()
  if LB.blocks == nil then
    return
  end
  LB.listRevision = nil
  if LB.draft:active() then
    local devices = lbDeviceItems()
    for i = 1, Defs.MAX_INPUTS do
      local prop = "Draft Input " .. i .. " Device"
      lbSetList(prop, devices, Properties[prop] or "-")
    end
    lbSetList("Draft Feedback Device", devices, Properties["Draft Feedback Device"] or "-")
  end
  LB.blocks:checkWatches(lbVariableExists)
  lbPaint()
end

--- The stored blocks could not be read. This keeps a copy of exactly what
--- was stored under a dated key, then lets the pack start empty.
function EC.BLOCK_ACK_RESTORE()
  if LB.blocks == nil or LB.blocks.restoreFailed == nil then
    refused("Acknowledge Restore Failure", "the blocks were restored normally")
    return
  end
  local stored = persist:get(LB_STATE_KEY, false)
  local backup = string.format("lb_state_unreadable_%d", os.time())
  persist:set(backup, stored)
  log:warn("Unreadable Logic Blocks document kept under %s; starting empty", backup)
  LB.blocks:acknowledgeRestoreFailure()
  lbConfigured(nil)
end

function EC.PRINT_BLOCKS()
  if LB.blocks == nil then
    return
  end
  log:print("== Logic Blocks ==")
  log:print("  %s", lbStatusLine())
  for _, slot in ipairs(LB.blocks:slots()) do
    local view = LB.blocks:view(slot)
    if view.kind == "block" then
      log:print("  %s  %s  [%s]%s", view.label, view.name, view.type_label, view.enabled and "" or "  DISABLED")
      log:print("      %s", view.explanation)
      log:print("      now: %s", view.status)
      for _, row in ipairs(view.sources or {}) do
        log:print(
          "      input %d %s: %s (%s%s)",
          row.index,
          row.label,
          tostring(row.value or "-"),
          row.status,
          row.why and (": " .. row.why) or ""
        )
      end
      for _, o in ipairs(view.wiring.outputs) do
        log:print("      event %d  %s", o.id, o.event)
      end
    else
      log:print("  %s  %s", view.label, view.status)
    end
  end
  for _, note in ipairs(LB.blocks.recovery.notes or {}) do
    log:print("  recovery: %s", note)
  end
end

-- ─── Block commands (Composer programming) ─────────────────────────────────

local function lbCommand(command, t)
  if LB.blocks == nil then
    return
  end
  t = t or {}
  LB.blocks:input(Defs.parseSlot(t.BLOCK), command, { VALUE = t.VALUE, BY = t.BY, INPUT = t.INPUT })
end

for name, command in pairs({
  BLOCK_TRIGGER = "trigger",
  BLOCK_START = "start",
  BLOCK_RESTART = "restart",
  BLOCK_CANCEL = "cancel",
  BLOCK_SET = "set",
  BLOCK_CLEAR = "clear",
  BLOCK_TOGGLE = "toggle",
  BLOCK_INCREMENT = "increment",
  BLOCK_DECREMENT = "decrement",
  BLOCK_RESET = "reset",
  BLOCK_INPUT = "input",
  BLOCK_INPUT_UNAVAILABLE = "input_unavailable",
}) do
  EC[name] = function(t)
    lbCommand(command, t)
  end
end

-- ─── Block conditionals ────────────────────────────────────────────────────
-- Answered from the runtime, not from the variables, so a conditional is
-- right even between two variable writes.

for slot = 1, Defs.SLOTS do
  TC[Defs.conditionalName(slot, "IS_ACTIVE")] = function()
    return LB.blocks ~= nil and LB.blocks:outputs(slot).active == true
  end
  TC[Defs.conditionalName(slot, "VALUE")] = function(_, tParams)
    tParams = tParams or {}
    local value = LB.blocks ~= nil and LB.blocks:outputs(slot).value or 0
    return Engine.compare(tParams.LOGIC, tonumber(value) or 0, tonumber(tParams.VALUE))
  end
  TC[Defs.conditionalName(slot, "STATE")] = function(_, tParams)
    tParams = tParams or {}
    local state = LB.blocks ~= nil and tostring(LB.blocks:outputs(slot).state or "") or ""
    local wanted = tostring(tParams.VALUE or ""):gsub("^%s+", ""):gsub("%s+$", "")
    return Engine.compare(tParams.LOGIC, state:lower(), wanted:lower())
  end
end

-- ─── Cloud summary handshakes (ignored unless the mirror is on) ────────────

function EC.SBOS_DRIVER_CLOUD(tParams)
  if LB.mirrorOn then
    mirror.onProvision(tParams)
  end
end

function EC.SBOS_DRIVER_STATE_ACK(tParams)
  if LB.mirrorOn then
    mirror.onAck(tParams)
  end
end
