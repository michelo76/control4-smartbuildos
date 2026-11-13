--[[==========================================================================
  SmartBuildOS Daypart Scheduler
  A weekly time-block schedule of music source, volume and display power,
  per zone (room), that on-site staff edit from a touch screen or phone
  WITHOUT Composer programming.

  The dealer decides, in properties, which zones exist, which sources each
  zone may play, the volume range, and which displays power with it. The
  manager opens one tile and can only choose from what the dealer allowed:
  that restriction is the product. At each block start the driver selects
  the source, ramps the volume over a set number of seconds and switches the
  displays; at the end of the last block it holds, fades out or turns off.

  Surface: a uibutton proxy whose web view is the page shipped in this c4z,
  served same-origin from a LAN relay (the pattern of Home Guide and Dealer
  Settings). Everyone who opens the tile can read the schedule; changes need
  the Manager PIN. Licensing: SKU SBOS_DAYPART through the SmartBuildOS Agent
  (sbos.license); a definitive denial with enforcement PAUSES the schedule
  (no more block actions) and makes the page read-only. Nothing is deleted.

  Pure rules: src/daypart/engine.lua and relay.lua (tested without a
  controller). History: block starts/ends and every schedule edit go to the
  Flight Recorder when one is in the project.
============================================================================]]

--#ifdef DRIVERCENTRAL
DC_PID = 0
DC_X = nil
DC_FILENAME = "smartbuildos-daypart.c4z"
--#else
DRIVER_GITHUB_REPO = "michelo76/control4-smartbuildos"
DRIVER_FILENAMES = { "smartbuildos-daypart.c4z" }
--#endif

-- Every require at module scope: the build discovers modules by loading this
-- file under the shim, where OnDriverLateInit stops early, so a require in a
-- function would be left out of the .c4z.
require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")
JSON = require("JSON")

local log = require("lib.logging")
local persist = require("lib.persist")
local license = require("sbos.license")
local appfile = require("lib.appfile")
local pagedata = require("daypart.page")
local RelayHost = require("lib.relayhost")
local Engine = require("daypart.engine")
local Relay = require("daypart.relay")

gInitialized = false

local SKU = "SBOS_DAYPART"
local C4Z_NAME = "smartbuildos-daypart"
local FLIGHT_RECORDER_C4Z = "smartbuildos-flight-recorder.c4z"
local STATE_KEY = "dp_state_v1"
local P_RELAY_TOKEN = "dp_relay_token_v1"
local WEBVIEW_BINDING = 5001
local UI_RELAY_PORT = 47851
local UI_RELAY_ID = "daypart-ui-relay"
local MAX_REQUEST_BYTES = 64 * 1024
local PERSIST_TIMER = "DpPersist"
local TICK_TIMER = "DpTick"
local STATUS_TIMER = "DpStatusPaint"
local REPUBLISH_TIMER = "DpRepublish"
local TICK_SECONDS = 10
--- A gap between two ticks longer than this (or backwards) is a clock change
--- or a stall: the schedule re-reads the wall clock and reconciles.
local CLOCK_JUMP_SECONDS = 180

local EVENT_STARTED, EVENT_ENDED, EVENT_PAUSED, EVENT_RESUMED, EVENT_CHANGED, EVENT_HALTED, EVENT_RESTORED =
  1, 2, 3, 4, 5, 6, 7

local ZONE_SOURCE_SLOTS, ZONE_DISPLAY_SLOTS = 4, 2

local gEngine = nil
local gGate = nil
local gHost = nil
local gPaused = false
local gHalted = false
local gDirty = false
local gLastTick = nil
local gStepTimers = {} -- slot -> { timerId, ... }
local gStepSeq = 0
local gLastEdit = "none yet"
local gLastRefusal = "none"
local gRecorderId = nil
local gRecorderAsked = nil
local gRelayPort = nil
local gRelayToken = nil
local gRelayBuffers = {}
local gAppHtml = nil
local gAppHtmlReported = 0
local gAppHtmlWhy = ""
local gPublishedUrl = nil
local gLastError = "none"

-- ─── Small helpers ──────────────────────────────────────────────────────────

--- The clock. A test pins it by defining DAYPART_NOW before loading.
local function now()
  if type(DAYPART_NOW) == "function" then
    return DAYPART_NOW()
  end
  return os.time()
end

local function localtime(epoch)
  if type(DAYPART_LOCALTIME) == "function" then
    return DAYPART_LOCALTIME(epoch)
  end
  return os.date("*t", math.floor(epoch))
end

local function trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
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

local function prop(name)
  return Properties[name]
end

-- ─── Flight Recorder (quiet when absent) ────────────────────────────────────

local function recorderId()
  if gRecorderId ~= nil then
    return gRecorderId
  end
  local t = now()
  if gRecorderAsked ~= nil and t - gRecorderAsked < 60 then
    return nil
  end
  gRecorderAsked = t
  local ok, found = pcall(function()
    return C4:GetDevicesByC4iName(FLIGHT_RECORDER_C4Z)
  end)
  if ok and type(found) == "table" then
    for rawId in pairs(found) do
      local id = tonumber(rawId)
      if id ~= nil then
        gRecorderId = id
        return id
      end
    end
  end
  return nil
end

--- One marker in the common history. Never throws, never blocks the schedule.
local function record(name, detail)
  local id = recorderId()
  if id == nil then
    return
  end
  pcall(function()
    C4:SendToDevice(
      id,
      "RECORD_EVENT",
      { NAME = "Daypart: " .. name, DETAIL = tostring(detail or ""), CHANNEL = "daypart" }
    )
  end)
end

-- ─── The dealer's zones, from properties ────────────────────────────────────

--- "Name (Room) · 123" -> 123. The id is whatever follows the last middle dot.
local function parseId(text)
  return tonumber(tostring(text or ""):match("·%s*(%d+)%s*$"))
end

local function labelOf(text)
  return trim((tostring(text or ""):gsub("%s*·%s*%d+%s*$", "")))
end

local function clampVolume(text, default)
  local v = tonumber(text)
  if v == nil then
    return default
  end
  v = math.floor(v + 0.5)
  return math.max(0, math.min(100, v))
end

local function buildZones()
  local zones = {}
  for slot = 1, Engine.MAX_ZONES do
    local name = trim(Properties["Zone " .. slot .. " Name"])
    local room = parseId(Properties["Zone " .. slot .. " Room"])
    if name ~= "" and room ~= nil then
      local sources, displays = {}, {}
      local seen = {}
      for n = 1, ZONE_SOURCE_SLOTS do
        local text = Properties["Zone " .. slot .. " Source " .. n]
        local id = parseId(text)
        if id ~= nil and not seen[id] then
          seen[id] = true
          sources[#sources + 1] = { id = id, label = labelOf(text) }
        end
      end
      for n = 1, ZONE_DISPLAY_SLOTS do
        local text = Properties["Zone " .. slot .. " Display " .. n]
        local id = parseId(text)
        if id ~= nil then
          displays[#displays + 1] = { id = id, label = labelOf(text) }
        end
      end
      local lo = clampVolume(Properties["Zone " .. slot .. " Min Volume"], 0)
      local hi = clampVolume(Properties["Zone " .. slot .. " Max Volume"], 100)
      if hi < lo then
        hi = lo
      end
      zones[slot] =
        { slot = slot, name = name, room = room, sources = sources, displays = displays, min = lo, max = hi }
    end
  end
  return zones
end

local function zoneCount()
  local n = 0
  for _ in pairs(gEngine and gEngine.zones or {}) do
    n = n + 1
  end
  return n
end

--- Zone by number ("2") or by name, case-insensitive. nil when unknown.
local function findZone(text)
  text = trim(text)
  if text == "" or gEngine == nil then
    return nil
  end
  local n = tonumber(text)
  if n ~= nil and gEngine.zones[n] ~= nil then
    return n
  end
  for slot, z in pairs(gEngine.zones) do
    if z.name:lower() == text:lower() then
      return slot
    end
  end
  return nil
end

-- ─── Room reads and command execution ───────────────────────────────────────

local function roomVars(roomId)
  local vars = {}
  local ok, raw = pcall(function()
    return C4:GetDeviceVariables(roomId)
  end)
  if ok and type(raw) == "table" then
    for _, v in pairs(raw) do
      if type(v) == "table" and v.name ~= nil then
        vars[v.name] = v.value
      end
    end
  end
  return vars
end

--- true / false / nil (unknown) from the room's POWER_STATE.
local function powerOf(value)
  if value == nil then
    return nil
  end
  local v = tostring(value):upper()
  if v == "1" or v == "ON" or v == "TRUE" then
    return true
  end
  if v == "0" or v == "OFF" or v == "FALSE" then
    return false
  end
  return nil
end

local function roomContext(roomId)
  local vars = roomVars(roomId)
  return {
    roomOn = powerOf(vars["POWER_STATE"]),
    currentVolume = tonumber(vars["CURRENT_VOLUME"]),
  }
end

local function rampSeconds()
  return math.max(0, math.min(600, math.floor(tonumber(Properties["Volume Ramp Seconds"]) or 20)))
end

local function fadeSeconds()
  return math.max(0, math.min(600, math.floor(tonumber(Properties["Fade Out Seconds"]) or 30)))
end

local function endBehaviour()
  local v = tostring(Properties["End Behaviour"] or "Hold"):lower()
  if v:find("fade", 1, true) then
    return "fade"
  elseif v == "off" then
    return "off"
  end
  return "hold"
end

local function cancelSteps(slot)
  for _, id in ipairs(gStepTimers[slot] or {}) do
    pcall(CancelTimer, id)
  end
  gStepTimers[slot] = nil
end

local function cancelAllSteps()
  for slot in pairs(gStepTimers) do
    cancelSteps(slot)
  end
end

local function sendStep(step)
  pcall(function()
    C4:SendToDevice(step.device, step.command, step.params or {})
  end)
end

local function saveSoon() end -- replaced below once save() exists

--- Carries out a plan: step 0 now, the rest on timers. The zone's previous
--- plan (a ramp still running) is cancelled first, so two blocks never
--- fight over the volume.
local function runSteps(slot, steps)
  cancelSteps(slot)
  local last = 0
  for _, s in ipairs(steps) do
    if s.at > last then
      last = s.at
    end
  end
  local timers = {}
  for _, s in ipairs(steps) do
    if s.at <= 0 then
      sendStep(s)
    else
      gStepSeq = gStepSeq + 1
      local id = string.format("DpStep%d_%d", slot, gStepSeq)
      timers[#timers + 1] = id
      SetTimer(id, s.at * ONE_SECOND, function()
        sendStep(s)
      end)
    end
  end
  gStepTimers[slot] = timers
  -- The ramp is done once its last step has gone out.
  if gEngine ~= nil then
    if last <= 0 then
      gEngine:markSteady(slot)
    else
      gStepSeq = gStepSeq + 1
      local id = string.format("DpStep%d_%d", slot, gStepSeq)
      timers[#timers + 1] = id
      SetTimer(id, (last + 1) * ONE_SECOND, function()
        if gEngine ~= nil then
          gEngine:markSteady(slot)
          saveSoon()
        end
      end)
    end
  end
end

-- ─── Status and variables ───────────────────────────────────────────────────

local function scheduleStatus()
  if gEngine == nil then
    return "starting"
  end
  if gHalted then
    return "halted (licence)"
  end
  if gPaused then
    return "paused"
  end
  if zoneCount() == 0 then
    return "no zones set up"
  end
  return "running"
end

local WEEKDAY_SHORT = Engine.DAY_NAMES

local function nextText(nxt, zoneName)
  if nxt == nil then
    return ""
  end
  local when
  if nxt.in_days == 0 then
    when = nxt.from
  else
    local day = Engine.isoWeekday(Engine.parseDate(nxt.date))
    when = WEEKDAY_SHORT[day] .. " " .. nxt.from
  end
  return string.format("%s: %s at %s", zoneName, nxt.block.name, when)
end

local function paint()
  if gEngine == nil then
    return
  end
  local mo = gEngine:moment(now())
  local status = scheduleStatus()
  UpdateProperty("Schedule Status", status)
  setVar("SCHEDULE_STATUS", status)
  local soonest, soonestKey = "", nil
  for slot = 1, Engine.MAX_ZONES do
    local z = gEngine.zones[slot]
    local run = gEngine.run[slot]
    local current = (z ~= nil and run ~= nil) and run.name or ""
    setVar("CURRENT_BLOCK_" .. slot, current)
    local nxt = z ~= nil and gEngine:nextBlock(slot, mo) or nil
    setVar("NEXT_BLOCK_" .. slot, nxt and nextText(nxt, z.name) or "")
    if nxt ~= nil then
      local k = string.format("%s %s", nxt.date, nxt.from)
      if soonestKey == nil or k < soonestKey then
        soonestKey, soonest = k, nextText(nxt, z.name)
      end
    end
  end
  setVar("NEXT_BLOCK", soonest)
  UpdateProperty("Next Block", soonest ~= "" and soonest or "none")
  UpdateProperty("Last Edit", gLastEdit)
  UpdateProperty("Last Refusal", gLastRefusal)
  local pieces = {}
  for slot = 1, Engine.MAX_ZONES do
    local z = gEngine.zones[slot]
    if z ~= nil then
      local run = gEngine.run[slot]
      pieces[#pieces + 1] = z.name .. ": " .. (run and run.name or "no block")
    end
  end
  UpdateProperty("Zones", #pieces > 0 and table.concat(pieces, " | ") or "none set up")
end

-- ─── Persistence ────────────────────────────────────────────────────────────

local function save()
  if gEngine == nil then
    return
  end
  gDirty = false
  local state = gEngine:serialize()
  state.paused = gPaused
  persist:set(STATE_KEY, state)
end

saveSoon = function()
  gDirty = true
  SetTimer(PERSIST_TIMER, 2 * ONE_SECOND, save)
end

-- ─── Block start and end ────────────────────────────────────────────────────

--- The dealer may have narrowed the zone since the block was saved: clamp the
--- volume again and drop a source that is no longer allowed.
local function effectiveBlock(zone, block)
  local b = Engine.copy(block)
  if type(b.source) == "number" then
    local allowed = false
    for _, s in ipairs(zone.sources) do
      if s.id == b.source then
        allowed = true
      end
    end
    if not allowed then
      log:warn(
        "Block %s: source %s is no longer allowed in zone %s; source left alone",
        tostring(b.name),
        tostring(b.source),
        zone.name
      )
      b.source = nil
    end
  end
  if b.volume ~= nil then
    b.volume = math.max(zone.min, math.min(zone.max, b.volume))
  end
  if #zone.displays == 0 then
    b.displays = "keep"
  end
  return b
end

local function announce(kind, zone, name)
  setVar("EVENT_ZONE", zone.name)
  setVar("EVENT_BLOCK", name)
  fire(kind == "start" and EVENT_STARTED or EVENT_ENDED)
end

local function doStart(action)
  local zone = gEngine:zone(action.slot)
  if zone == nil then
    return
  end
  local block = effectiveBlock(zone, action.block)
  local ctx = roomContext(zone.room)
  ctx.rampSeconds = rampSeconds()
  if action.resume then
    ctx.resume, ctx.minutesIn = true, action.minutes_in
    -- The controller restarted (or the schedule was paused) mid-ramp: carry
    -- on from wherever the room is now, to the same target. No source or
    -- display commands again, no new event.
    block.source, block.displays = nil, "keep"
  end
  runSteps(action.slot, Engine.planStart(zone, block, ctx))
  if action.resume then
    log:info("Zone %s: resuming %s", zone.name, tostring(block.name))
    return
  end
  if action.update then
    record("block changed while running", string.format("%s / %s", zone.name, tostring(block.name)))
    return
  end
  announce("start", zone, tostring(block.name))
  local late = (action.minutes_in or 0) >= 2
  record(
    "block started",
    string.format(
      "%s / %s%s",
      zone.name,
      tostring(block.name),
      late and string.format(" (late start, %d min in)", action.minutes_in) or ""
    )
  )
end

local function doEnd(action)
  local zone = gEngine:zone(action.slot)
  if zone == nil then
    return
  end
  cancelSteps(action.slot)
  announce("end", zone, tostring(action.run.name))
  record("block ended", string.format("%s / %s", zone.name, tostring(action.run.name)))
  if action.gap then
    local behaviour = endBehaviour()
    if behaviour ~= "hold" then
      local ctx = roomContext(zone.room)
      ctx.fadeSeconds = fadeSeconds()
      runSteps(action.slot, Engine.planEnd(zone, behaviour, ctx))
    end
  end
end

local function reconcile()
  if gEngine == nil or gPaused or gHalted then
    return
  end
  local actions = gEngine:reconcile(now())
  for _, a in ipairs(actions) do
    local ok, err = pcall(function()
      if a.kind == "end" then
        doEnd(a)
      else
        doStart(a)
      end
    end)
    if not ok then
      gLastError = "block action failed: " .. tostring(err)
      log:error("%s", gLastError)
    end
  end
  if #actions > 0 then
    saveSoon()
  end
end

local function tick()
  if gEngine == nil then
    return
  end
  local t = now()
  if gLastTick ~= nil and (t < gLastTick or t - gLastTick > CLOCK_JUMP_SECONDS) then
    local detail = string.format("clock moved %d s between checks", math.floor(t - gLastTick))
    log:warn("Daypart: %s; re-reading the schedule", detail)
    gEngine:invalidateRuntime()
    record("clock change", detail)
  end
  gLastTick = t
  reconcile()
  paint()
end

-- ─── Licence ────────────────────────────────────────────────────────────────

local function reconcileLicence()
  local halt = license.enforces()
  if halt and not gHalted then
    gHalted = true
    cancelAllSteps()
    gEngine:setReadOnly(true)
    log:warn("SmartBuildOS licence: %s - schedule halted, page read-only", tostring(license.statusLabel()))
    record("schedule halted", tostring(license.statusLabel()))
    fire(EVENT_HALTED)
  elseif not halt and gHalted then
    gHalted = false
    gEngine:setReadOnly(false)
    gEngine:invalidateRuntime()
    record("schedule restored", "licence")
    fire(EVENT_RESTORED)
    reconcile()
  end
  paint()
end

-- ─── Pause / resume / skip / run now ────────────────────────────────────────

local function pauseSchedule(who)
  if gPaused then
    return false
  end
  gPaused = true
  cancelAllSteps()
  saveSoon()
  record("schedule paused", who)
  fire(EVENT_PAUSED)
  paint()
  return true
end

local function resumeSchedule(who)
  if not gPaused then
    return false
  end
  gPaused = false
  gEngine:invalidateRuntime()
  saveSoon()
  record("schedule resumed", who)
  fire(EVENT_RESUMED)
  reconcile()
  paint()
  return true
end

local function skipNext(slot, who)
  if gEngine == nil then
    return {}
  end
  local skipped = gEngine:skipNext(slot)
  for _, s in ipairs(skipped) do
    record(
      "block skipped",
      string.format("%s / %s on %s %s (%s)", gEngine.zones[s.slot].name, s.name, s.date, s.from, who)
    )
  end
  saveSoon()
  paint()
  return skipped
end

local function runBlockNow(slot, blockName, who)
  if gHalted then
    return nil, "The schedule is halted by the licence."
  end
  local zone = gEngine:zone(slot)
  if zone == nil then
    return nil, "That zone is not set up."
  end
  local id, scope = gEngine:findBlockByName(slot, blockName, now())
  if id == nil then
    return nil, "No block with that name in this zone."
  end
  local block, err = gEngine:startManual(slot, id, scope)
  if block == nil then
    return nil, err
  end
  doStart({ slot = slot, block = block, minutes_in = 0 })
  record("block run by hand", string.format("%s / %s (%s)", zone.name, tostring(block.name), who))
  saveSoon()
  paint()
  return block
end

-- ─── Device lists (DYNAMIC_LIST properties) ─────────────────────────────────

local AGENT_FILE_PATTERN = "^smartbuildos"

local function cleanForList(text)
  return (tostring(text or ""):gsub(",", " "):gsub("%s+", " "))
end

local function deviceEntries()
  local ok, devices = pcall(function()
    return C4:GetDevices({})
  end)
  if not ok or type(devices) ~= "table" then
    return {}, {}
  end
  local me = C4:GetDeviceID()
  local filter = trim(Properties["Device List Filter"]):lower()
  local rooms, roomSeen, items = {}, {}, {}
  for rawId, d in pairs(devices) do
    local id = tonumber(rawId)
    if id ~= nil and type(d) == "table" then
      local file = tostring(d.driverFileName or ""):lower()
      local name = tostring(d.deviceName or d.name or "")
      local roomName = tostring(d.roomName or "")
      local roomId = tonumber(d.roomId)
      if roomId ~= nil and roomName ~= "" and not roomSeen[roomId] then
        roomSeen[roomId] = true
        rooms[#rooms + 1] = { id = roomId, label = cleanForList(roomName) .. " · " .. roomId }
      end
      if file:find("^roomdevice") then
        if not roomSeen[id] and name ~= "" then
          roomSeen[id] = true
          rooms[#rooms + 1] = { id = id, label = cleanForList(name) .. " · " .. id }
        end
      elseif id ~= me and not file:find(AGENT_FILE_PATTERN) and name ~= "" then
        local label = cleanForList(name)
        if roomName ~= "" then
          label = label .. " (" .. cleanForList(roomName) .. ")"
        end
        if filter == "" or label:lower():find(filter, 1, true) then
          items[#items + 1] = { id = id, label = label .. " · " .. id }
        end
      end
    end
  end
  table.sort(rooms, function(a, b)
    return a.label < b.label
  end)
  table.sort(items, function(a, b)
    return a.label < b.label
  end)
  return rooms, items
end

local function fillList(name, entries)
  local labels = { "-" }
  local current = tostring(Properties[name] or "-")
  local present = current == "-" or current == ""
  for _, e in ipairs(entries) do
    labels[#labels + 1] = e.label
    if e.label == current then
      present = true
    end
  end
  if not present then
    labels[#labels + 1] = current -- keep a pick whose device is gone, visibly
  end
  pcall(function()
    C4:UpdatePropertyList(name, table.concat(labels, ","), current ~= "" and current or "-")
  end)
end

local function refreshLists()
  local rooms, items = deviceEntries()
  for slot = 1, Engine.MAX_ZONES do
    fillList("Zone " .. slot .. " Room", rooms)
    for n = 1, ZONE_SOURCE_SLOTS do
      fillList("Zone " .. slot .. " Source " .. n, items)
    end
    for n = 1, ZONE_DISPLAY_SLOTS do
      fillList("Zone " .. slot .. " Display " .. n, items)
    end
  end
end

-- ─── Edits (shared by the page and Composer) ────────────────────────────────

local function pinConfigured()
  return trim(Properties["Manager PIN"]) ~= ""
end

local function canEdit()
  return not gHalted and pinConfigured() and not (gGate ~= nil and gGate:isLocked())
end

local function editBlocked()
  if gHalted then
    return "unlicensed", "The schedule is read-only (SmartBuildOS licence)."
  end
  if not pinConfigured() then
    return "pin_not_configured", "Editing is off: ask the installer to set a Manager PIN."
  end
  return nil
end

local EDIT_OPS = {
  add_block = true,
  update_block = true,
  delete_block = true,
  set_holidays = true,
  clear_today = true,
  pause = true,
  resume = true,
  skip_next = true,
  run_now = true,
}

local function refuse(what, why)
  gLastRefusal = string.format("%s: %s (%s)", what, tostring(why), os.date("%H:%M:%S", math.floor(now())))
  UpdateProperty("Last Refusal", gLastRefusal)
  log:warn("%s refused: %s", what, tostring(why))
end

--- One edit from the page. The PIN gate runs first; the engine's own
--- validation (allowed sources, range, overlaps) runs after.
local function applyEdit(doc)
  local op = tostring(doc.op or "")
  if not EDIT_OPS[op] then
    return { ok = false, error = "Unknown action." }
  end
  local reason, text = editBlocked()
  if reason ~= nil then
    return { ok = false, reason = reason, error = text }
  end
  local okPin, pinReason = gGate:check(Properties["Manager PIN"], doc.pin)
  if not okPin then
    local msg = ({
      locked = string.format("Too many wrong PINs. Try again in %d seconds.", gGate:secondsLeft()),
      wrong_pin = "That PIN is not right.",
    })[pinReason] or "PIN refused."
    return { ok = false, reason = pinReason, error = msg }
  end
  local who = "Manager page"
  local slot = tonumber(doc.zone)
  local result, err
  if op == "add_block" then
    result, err = gEngine:addBlock(slot, tostring(doc.scope or "week"), doc.block)
  elseif op == "update_block" then
    result, err = gEngine:updateBlock(slot, tostring(doc.scope or "week"), tostring(doc.id or ""), doc.block)
  elseif op == "delete_block" then
    result, err = gEngine:deleteBlock(slot, tostring(doc.scope or "week"), tostring(doc.id or ""))
  elseif op == "set_holidays" then
    result, err = gEngine:setHolidays(doc.dates)
  elseif op == "clear_today" then
    result, err = gEngine:clearToday(slot)
  elseif op == "pause" then
    result = { summary = "schedule paused" }
    pauseSchedule(who)
  elseif op == "resume" then
    result = { summary = "schedule resumed" }
    resumeSchedule(who)
  elseif op == "skip_next" then
    local skipped = skipNext(slot, who)
    if #skipped == 0 then
      err = "There is no upcoming block to skip."
    else
      result = { summary = "skipped " .. skipped[1].name }
    end
  elseif op == "run_now" then
    local block, why = runBlockNow(slot, tostring(doc.name or ""), who)
    if block == nil then
      err = why
    else
      result = { summary = "ran " .. tostring(block.name) .. " now" }
    end
  end
  if result == nil then
    refuse(op, err)
    return { ok = false, error = tostring(err or "Not saved.") }
  end
  local edited = op ~= "pause" and op ~= "resume" and op ~= "skip_next" and op ~= "run_now"
  gLastEdit = string.format("%s: %s (%s)", who, result.summary, os.date("%H:%M:%S", math.floor(now())))
  if edited then
    record(
      "schedule edited",
      string.format(
        "%s: %s%s",
        who,
        result.summary,
        slot and gEngine.zones[slot] and (" [" .. gEngine.zones[slot].name .. "]") or ""
      )
    )
    fire(EVENT_CHANGED)
    saveSoon()
    -- An edit to the block running right now takes effect now.
    reconcile()
  end
  paint()
  return { ok = true, warnings = result.warnings or {}, summary = result.summary }
end

-- ─── The page document ──────────────────────────────────────────────────────

local function stateDocument()
  local view = gEngine:view(now())
  view.status = scheduleStatus()
  view.can_edit = canEdit()
  view.edit_reason = (editBlocked()) or (gGate:isLocked() and "locked" or nil)
  view.paused = gPaused
  view.halted = gHalted
  view.ramp_seconds = rampSeconds()
  view.fade_seconds = fadeSeconds()
  view.end_behaviour = endBehaviour()
  view.running = {}
  for slot, run in pairs(gEngine.run) do
    view.running[tostring(slot)] = run.name
  end
  return JSON:encode(view)
end

-- ─── Relay (the Home Guide / Dealer Settings pattern) ───────────────────────

local function relayHost()
  if gHost == nil then
    return ""
  end
  return (gHost:host())
end

local function relayToken()
  if gRelayToken ~= nil then
    return gRelayToken
  end
  local stored = persist:get(P_RELAY_TOKEN, nil, true)
  if type(stored) == "string" and #stored >= 16 then
    gRelayToken = stored
    return stored
  end
  local seed = string.format("%d|%d|%d|%s", os.time(), os.clock() * 1000000, C4:GetDeviceID(), tostring({}))
  local ok, hex = pcall(function()
    return C4:HMAC("SHA256", seed, "daypart-relay", { return_encoding = "HEX" })
  end)
  local token = ok and type(hex) == "string" and #hex >= 16 and hex:sub(1, 32)
    or (tostring(os.time()) .. tostring(math.floor(os.clock() * 1000000)))
  gRelayToken = token
  persist:set(P_RELAY_TOKEN, token, true)
  return token
end

local function appHtml()
  if gAppHtml ~= nil then
    return gAppHtml
  end
  -- The page is compiled into the driver (tools/embed-pages.lua): OS 4.3
  -- refuses a driver read access to its own c4z files.
  if type(pagedata) == "string" and #pagedata >= 512 then
    gAppHtml = pagedata
    gAppHtmlWhy = "embedded in the driver"
    return gAppHtml
  end
  local html, report = appfile.read(C4Z_NAME, "app/index.html", C4, 512)
  gAppHtmlWhy = report or ""
  if html ~= nil then
    gAppHtml = html
  end
  if html == nil then
    -- The page cannot be served: say so (at most once a minute) and say why.
    local now = os.time()
    if now - gAppHtmlReported >= 60 then
      gAppHtmlReported = now
      log:warn("Page file not found: %s", report)
    end
  elseif gAppHtmlReported >= 0 then
    gAppHtmlReported = -1
    log:info("Page file: %s", report)
  end
  return gAppHtml
end

local relayProvider = {
  appHtml = appHtml,
  appWhy = function()
    return gAppHtmlWhy
  end,
  state = function()
    return stateDocument()
  end,
  verify = function(pin)
    local reason, _ = editBlocked()
    if reason ~= nil then
      return false, reason
    end
    return gGate:check(Properties["Manager PIN"], pin)
  end,
  edit = applyEdit,
  encode = function(t)
    return JSON:encode(t)
  end,
  decode = function(s)
    return JSON:decode(s)
  end,
}

function OnServerDataIn(handle, data, _, _, identifier)
  if identifier ~= nil and identifier ~= UI_RELAY_ID then
    return
  end
  gRelayBuffers[handle] = (gRelayBuffers[handle] or "") .. tostring(data or "")
  if #gRelayBuffers[handle] > MAX_REQUEST_BYTES then
    gRelayBuffers[handle] = nil
    pcall(function()
      C4:ServerCloseClient(handle)
    end)
    return
  end
  local req = Relay.parse(gRelayBuffers[handle])
  if req == nil then
    return
  end
  gRelayBuffers[handle] = nil
  local result = Relay.route(req, relayToken(), relayProvider)
  pcall(function()
    C4:ServerSend(handle, Relay.render(result))
  end)
  pcall(function()
    C4:ServerCloseClient(handle)
  end)
end

local function startRelay()
  if gRelayPort ~= nil then
    return
  end
  local ok = pcall(function()
    C4:CreateServer(UI_RELAY_PORT, "", false, UI_RELAY_ID)
  end)
  if ok then
    gRelayPort = UI_RELAY_PORT
    log:info("Daypart relay listening on port %d", UI_RELAY_PORT)
  else
    gLastError = "relay could not listen on port " .. UI_RELAY_PORT
    log:warn("%s", gLastError)
  end
end

local function stopRelay()
  if gRelayPort ~= nil then
    pcall(function()
      C4:DestroyServer(gRelayPort)
    end)
    gRelayPort = nil
  end
  gRelayBuffers = {}
end

local function encodeParam(s)
  return (tostring(s):gsub("[^%w%-%._~]", function(ch)
    return string.format("%%%02X", ch:byte())
  end))
end

local function desiredWebViewUrl()
  local host = gRelayPort ~= nil and relayHost() or ""
  if host ~= "" and appHtml() ~= nil then
    return string.format("http://%s:%d/app?k=%s", host, gRelayPort, relayToken())
  end
  local base = "controller://driver/" .. C4Z_NAME .. "/app/index.html"
  if host == "" then
    return base
  end
  return base .. "?relay=" .. encodeParam(string.format("http://%s:%d", host, gRelayPort)) .. "&k=" .. relayToken()
end

local function paintRelay()
  local line
  if gRelayPort == nil then
    line = string.format("Not listening - port %d unavailable", UI_RELAY_PORT)
  else
    line = gHost:statusLine()
  end
  UpdateProperty("App Data Relay", line)
end

local function publishWebViewUrl(reason)
  local url = desiredWebViewUrl()
  pcall(function()
    C4:SendToProxy(WEBVIEW_BINDING, "URL_CHANGED", { url = url })
  end)
  gPublishedUrl = url
  paintRelay()
  log:debug("Daypart URL published (%s): %s", tostring(reason), (url:gsub("k=[%w]+", "k=[token]")))
end

gHost = RelayHost.new({
  port = UI_RELAY_PORT,
  service = "daypart",
  configured = function()
    return Properties["App Relay Address"]
  end,
  onChange = function()
    if gInitialized then
      publishWebViewUrl("address confirmed")
    end
  end,
})

-- ─── Lifecycle ──────────────────────────────────────────────────────────────

local function registerComposerSurface()
  local vars = {
    { "SCHEDULE_STATUS", "starting", "STRING" },
    { "NEXT_BLOCK", "", "STRING" },
    { "EVENT_ZONE", "", "STRING" },
    { "EVENT_BLOCK", "", "STRING" },
  }
  for slot = 1, Engine.MAX_ZONES do
    vars[#vars + 1] = { "CURRENT_BLOCK_" .. slot, "", "STRING" }
    vars[#vars + 1] = { "NEXT_BLOCK_" .. slot, "", "STRING" }
  end
  for _, v in ipairs(vars) do
    pcall(function()
      C4:AddVariable(v[1], v[2], v[3], true)
    end)
  end
  for _, e in ipairs({
    { EVENT_STARTED, "Block Started", "A block started in a zone (EVENT_ZONE and EVENT_BLOCK say which)" },
    { EVENT_ENDED, "Block Ended", "A block ended in a zone (EVENT_ZONE and EVENT_BLOCK say which)" },
    { EVENT_PAUSED, "Schedule Paused", "The schedule was paused" },
    { EVENT_RESUMED, "Schedule Resumed", "The schedule was resumed" },
    { EVENT_CHANGED, "Schedule Edited", "Someone changed the schedule from the page" },
    { EVENT_HALTED, "Schedule Halted", "The SmartBuildOS licence halted the schedule" },
    { EVENT_RESTORED, "Schedule Restored", "The schedule is running again after a halt" },
  }) do
    pcall(function()
      C4:AddEvent(e[1], e[2], e[3])
    end)
  end
end

--- Rebuilds the zones from the properties and lets the schedule react.
local function rebuildZones()
  if gEngine == nil then
    return
  end
  gEngine:setZones(buildZones())
  gEngine:invalidateRuntime()
end

function OnDriverInit()
  --#ifdef DRIVERCENTRAL
  require("cloud-client-byte")
  C4:AllowExecute(false)
  --#else
  C4:AllowExecute(true)
  --#endif
  gInitialized = false
  log:setLogName("Daypart")
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

  gEngine = Engine.new({ now = now, localtime = localtime })
  gGate = Relay.newGate({
    now = os.time,
    onLocked = function()
      log:warn("Daypart: too many wrong Manager PINs; edits locked for a minute")
      record("manager pin locked", "too many wrong PINs")
    end,
  })
  gEngine:setZones(buildZones())
  local stored = persist:get(STATE_KEY, false)
  if type(stored) == "table" then
    local ok, dropped = pcall(function()
      return gEngine:restore(stored)
    end)
    if not ok then
      log:error("Persisted schedule unreadable (%s); starting empty", tostring(dropped))
    else
      gPaused = stored.paused == true
      if dropped and dropped > 0 then
        log:warn("%d stored block(s) could not be read and were dropped", dropped)
      end
    end
  end

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

  refreshLists()
  startRelay()
  gHost:check()
  publishWebViewUrl("late init")
  -- Resume: whatever is active now, compared with what was running before.
  gLastTick = now()
  reconcile()
  SetTimer(TICK_TIMER, TICK_SECONDS * ONE_SECOND, tick, true)
  SetTimer(REPUBLISH_TIMER, 60 * ONE_SECOND, function()
    publishWebViewUrl("60s republish")
  end)
  SetTimer(STATUS_TIMER, 60 * ONE_SECOND, function()
    if gRelayPort ~= nil then
      gHost:checkIfDue()
    end
    paint()
  end, true)
  paint()
  record("driver started", string.format("%s, %d zone(s)", scheduleStatus(), zoneCount()))
end

function OnDriverDestroyed()
  pcall(license.stop) -- the licence retry timer
  stopRelay()
  cancelAllSteps()
  if gEngine then
    save()
  end
  CancelTimer(PERSIST_TIMER)
  CancelTimer(TICK_TIMER)
  CancelTimer(STATUS_TIMER)
  CancelTimer(REPUBLISH_TIMER)
end

-- ─── Properties ─────────────────────────────────────────────────────────────

-- The Manager PIN must never reach the debug log: Handlers print a property's
-- value on change (and the boot replay does too) unless suppressDebug names
-- it. Both spellings are listed, as the name is consulted before sanitising.
OPC.suppressDebug = OPC.suppressDebug or {}
OPC.suppressDebug["Manager PIN"] = true
OPC.suppressDebug["Manager_PIN"] = true

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

function OPC.App_Relay_Address()
  if gInitialized then
    gHost:check()
    publishWebViewUrl("relay address changed")
  end
end

function OPC.Manager_PIN()
  if gInitialized and gGate then
    gGate:reset()
  end
end

local function zonePropertyChanged()
  if gInitialized then
    rebuildZones()
    reconcile()
    paint()
  end
end

for slot = 1, Engine.MAX_ZONES do
  OPC["Zone_" .. slot .. "_Name"] = zonePropertyChanged
  OPC["Zone_" .. slot .. "_Room"] = zonePropertyChanged
  OPC["Zone_" .. slot .. "_Min_Volume"] = zonePropertyChanged
  OPC["Zone_" .. slot .. "_Max_Volume"] = zonePropertyChanged
  for n = 1, ZONE_SOURCE_SLOTS do
    OPC["Zone_" .. slot .. "_Source_" .. n] = zonePropertyChanged
  end
  for n = 1, ZONE_DISPLAY_SLOTS do
    OPC["Zone_" .. slot .. "_Display_" .. n] = zonePropertyChanged
  end
end

function OPC.Device_List_Filter()
  if gInitialized then
    refreshLists()
  end
end

-- ─── Actions ────────────────────────────────────────────────────────────────

function EC.REGISTER_NOW()
  license.register()
end

function EC.PRINT_PAGE_LINK()
  -- Printed, not logged: the dealer asked for it, and the link carries the access token.
  log:print("Page link: %s", desiredWebViewUrl())
end

function EC.REFRESH_STATUS()
  paint()
end

function EC.REFRESH_DEVICE_LISTS()
  refreshLists()
end

function EC.RESET_PIN_LOCK()
  if gGate then
    gGate:reset()
  end
end

function EC.RELOAD()
  if gEngine == nil then
    return
  end
  refreshLists()
  rebuildZones()
  gAppHtml = nil
  gHost:check()
  publishWebViewUrl("reload")
  reconcile()
  paint()
  record("reloaded", "Composer")
end

function EC.PAUSE_SCHEDULE()
  if gEngine then
    pauseSchedule("Composer")
  end
end

function EC.RESUME_SCHEDULE()
  if gEngine then
    resumeSchedule("Composer")
  end
end

function EC.SKIP_NEXT_BLOCK(t)
  t = t or {}
  if gEngine == nil then
    return
  end
  local text = trim(t.ZONE)
  local slot = nil
  if text ~= "" and text:lower() ~= "all" then
    slot = findZone(text)
    if slot == nil then
      refuse("Skip Next Block", "unknown zone " .. text)
      return
    end
  end
  if #skipNext(slot, "Composer") == 0 then
    refuse("Skip Next Block", "no upcoming block")
  end
end

function EC.RUN_BLOCK_NOW(t)
  t = t or {}
  if gEngine == nil then
    return
  end
  local slot = findZone(t.ZONE)
  if slot == nil then
    refuse("Run Block Now", "unknown zone " .. trim(t.ZONE))
    return
  end
  local block, err = runBlockNow(slot, trim(t.BLOCK), "Composer")
  if block == nil then
    refuse("Run Block Now", err)
  end
end

function EC.PRINT_SCHEDULE()
  if gEngine == nil then
    return
  end
  log:print("== Daypart Scheduler ==")
  log:print("  status: %s", scheduleStatus())
  log:print("  licence: %s", license.describe())
  log:print("  relay: %s", tostring(Properties["App Data Relay"]))
  local mo = gEngine:moment(now())
  log:print("  now: %s %s", mo.date, Engine.formatTime(mo.minute))
  for slot = 1, Engine.MAX_ZONES do
    local z = gEngine.zones[slot]
    if z ~= nil then
      log:print(
        "  zone %d %s: room %d, volume %d-%d, %d source(s), %d display(s)",
        slot,
        z.name,
        z.room,
        z.min,
        z.max,
        #z.sources,
        #z.displays
      )
      local zs = gEngine.doc.zones[slot]
      for _, b in ipairs(zs.week) do
        log:print("    week     %s", Engine.describeBlock(b))
      end
      for _, b in ipairs(zs.holiday) do
        log:print("    holiday  %s", Engine.describeBlock(b))
      end
      for _, b in ipairs(zs.today.blocks) do
        log:print("    today    %s", Engine.describeBlock(b))
      end
      local run = gEngine.run[slot]
      log:print("    running: %s", run and run.name or "none")
    end
  end
  log:print("  holidays: %s", #gEngine.doc.holidays > 0 and table.concat(gEngine.doc.holidays, ", ") or "none")
  log:print("  last edit: %s", gLastEdit)
  if gLastError ~= "none" then
    log:print("  last error: %s", gLastError)
  end
end

-- ─── Conditionals (TestCondition name, tParams{VALUE, LOGIC}) ──────────────

function TC.SCHEDULE_PAUSED()
  return gPaused or gHalted
end

--- "= zone" is true when the zone has a block running; "!= zone" when not.
function TC.ZONE_ACTIVE(_, tParams)
  tParams = tParams or {}
  local slot = findZone(tParams.VALUE)
  local answer = slot ~= nil and gEngine ~= nil and gEngine.run[slot] ~= nil
  if tostring(tParams.LOGIC or "EQUAL"):upper() == "NOT_EQUAL" then
    return not answer
  end
  return answer
end
