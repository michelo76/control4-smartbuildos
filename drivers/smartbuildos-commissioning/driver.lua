--[[==========================================================================
  SmartBuildOS Commissioning Matrix
  A guided pre-handoff test run. The driver builds a test list by room from
  the project (lights, shades, AV zones, sensors, plus items the dealer adds
  by hand), a technician works through it from a phone page, the driver ACTS
  on each device (ramp, move, route a source) and reads back what the device
  REPORTS, and the technician taps Pass / Fail / Skip. Sensors run the other
  way: trigger the sensor and it passes by itself. Signing off stores the
  run and offers it to the Agent as the as-built record.

  What it does not do: prove the lamp lit (the technician's tap does) or
  measure radio signal health.

  Licensing: the SmartBuildOS Agent is the authority (SKU SBOS_COMMISSIONING
  through sbos.license). A definitive denial with enforcement on makes the
  driver READ-ONLY: runs cannot start or change, results stay readable.

  Pure rules: src/commissioning/engine.lua. Actuation adapters:
  src/commissioning/actuate.lua. Phone page router: src/commissioning/relay.lua.
============================================================================]]

--#ifdef DRIVERCENTRAL
DC_PID = 0
DC_X = nil
DC_FILENAME = "smartbuildos-commissioning.c4z"
--#else
DRIVER_GITHUB_REPO = "michelo76/control4-smartbuildos"
DRIVER_FILENAMES = { "smartbuildos-commissioning.c4z" }
--#endif

-- Every require at module scope (the build's squish step discovers modules
-- by loading this file under the test shim).
require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")
JSON = require("JSON")

local log = require("lib.logging")
local persist = require("lib.persist")
local license = require("sbos.license")
local appfile = require("lib.appfile")
local pagedata = require("commissioning.page")
local RelayHost = require("lib.relayhost")
local Engine = require("commissioning.engine")
local Actuate = require("commissioning.actuate")
local Relay = require("commissioning.relay")

gInitialized = false

local SKU = "SBOS_COMMISSIONING"
local C4Z_NAME = "smartbuildos-commissioning"
local STATE_KEY = "cm_state_v1"
local MANUAL_KEY = "cm_manual_v1"
local TOKEN_KEY = "cm_relay_token_v1"
local PUSH_KEY = "cm_pending_push_v1"
local PERSIST_TIMER = "CmPersist"
local STATUS_TIMER = "CmStatus"
local UI_RELAY_PORT = 47841
local UI_RELAY_ID = "commissioning-ui-relay"
local RECORDER_FILE = "smartbuildos-flight-recorder.c4z"

local EVENT_ROOM_PASSED, EVENT_RUN_COMPLETED, EVENT_ITEM_FAILED = 1, 2, 3

local gEngine = nil
local gHalted = false
local gManual = {}
local gDeviceList = {} -- label -> device id, for the property lists
local gWatch = {} -- "deviceId:varId" -> variable name
local gTimerSeq = 0
local gTimerIds = {}
local gRelayPort = nil
local gRelayToken = nil
local gRelayBuffers = {}
local gAppHtml = nil
local gAppHtmlReported = 0
local gAppHtmlWhy = ""
local gHost = nil
local gRecorderId = nil
local gPendingPush = nil -- run id awaiting the Agent's ack
local gRebuildWanted = false
local gLastResult = "none yet"
local gOptions = { av_volume = 15 }

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

local function trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- ─── Project access ─────────────────────────────────────────────────────────

local function readDevices()
  local ok, devices = pcall(function()
    return C4:GetDevices({})
  end)
  if not ok or type(devices) ~= "table" then
    return {}
  end
  local out = {}
  local self = nil
  pcall(function()
    self = C4:GetDeviceID()
  end)
  for id, d in pairs(devices) do
    if tonumber(id) ~= tonumber(self) and type(d) == "table" then
      out[tonumber(id)] = d
    end
  end
  return out
end

--- name -> value of one device's variables.
local function readVars(deviceId)
  local ok, raw = pcall(function()
    return C4:GetDeviceVariables(deviceId)
  end)
  local vars = {}
  if ok and type(raw) == "table" then
    for _, v in pairs(raw) do
      if type(v) == "table" and v.name ~= nil then
        vars[v.name] = v.value
      end
    end
  end
  return vars
end

local function varIdByName(deviceId, name)
  local ok, raw = pcall(function()
    return C4:GetDeviceVariables(deviceId)
  end)
  if ok and type(raw) == "table" then
    for id, v in pairs(raw) do
      if type(v) == "table" and v.name == name then
        return tonumber(id)
      end
    end
  end
  return nil
end

local function avSource()
  local entry = Engine.parseListEntry(Properties["AV Test Source"])
  return entry and entry.id or nil
end

-- ─── Flight Recorder (the common history) ───────────────────────────────────

local function findRecorder()
  if gRecorderId ~= nil then
    return gRecorderId
  end
  local ok, found = pcall(function()
    return C4:GetDevicesByC4iName(RECORDER_FILE)
  end)
  if ok and type(found) == "table" then
    for id in pairs(found) do
      gRecorderId = tonumber(id)
      return gRecorderId
    end
  end
  for id, d in pairs(readDevices()) do
    if tostring(d.driverFileName or ""):find("flight%-recorder") then
      gRecorderId = id
      return id
    end
  end
  return nil
end

--- A marker in the Flight Recorder's history. Quiet when there is none.
local function recordHistory(name, detail)
  local id = findRecorder()
  if id == nil then
    return false
  end
  pcall(function()
    C4:SendToDevice(id, "RECORD_EVENT", {
      NAME = tostring(name):sub(1, 120),
      DETAIL = tostring(detail or ""):sub(1, 400),
      CHANNEL = Engine.CHANNEL,
    })
  end)
  return true
end

-- ─── Persistence ────────────────────────────────────────────────────────────

local function save()
  if gEngine == nil then
    return
  end
  persist:set(STATE_KEY, gEngine:serialize())
  persist:set(MANUAL_KEY, gManual)
  persist:set(PUSH_KEY, gPendingPush or "")
end

local function saveSoon()
  SetTimer(PERSIST_TIMER, 2 * ONE_SECOND, save)
end

-- ─── Status and variables ───────────────────────────────────────────────────

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
  local stored = persist:get(TOKEN_KEY, nil, true)
  if type(stored) == "string" and #stored >= 16 then
    gRelayToken = stored
    return stored
  end
  local seed = string.format("%d|%d|%d|%s", os.time(), os.clock() * 1000000, C4:GetDeviceID(), tostring({}))
  local ok, hex = pcall(function()
    return C4:HMAC("SHA256", seed, "commissioning-relay", { return_encoding = "HEX" })
  end)
  local token = ok and type(hex) == "string" and hex:sub(1, 32) or tostring(os.time()) .. tostring(os.clock())
  gRelayToken = token
  persist:set(TOKEN_KEY, token, true)
  return token
end

local function pageUrl()
  if gRelayPort == nil then
    return "not listening (port " .. UI_RELAY_PORT .. " unavailable)"
  end
  local host = relayHost()
  if host == "" then
    return "controller address unknown: set App Relay Address"
  end
  return string.format("http://%s:%d/app?k=%s", host, gRelayPort, relayToken())
end

local function runStatus()
  if gEngine == nil then
    return "starting"
  end
  if gHalted then
    return "read-only (licence)"
  end
  return gEngine:status()
end

local function paint()
  if gEngine == nil then
    return
  end
  local c = gEngine:counts()
  local status = runStatus()
  UpdateProperty("Run Status", status)
  UpdateProperty("Test List", string.format("%d item(s) in %d room(s)", #gEngine.items, #gEngine:rooms()))
  UpdateProperty(
    "Run Summary",
    c.total == 0 and "no run yet"
      or string.format("%d passed, %d failed, %d skipped, %d open", c.passed, c.failed, c.skipped, c.pending)
  )
  UpdateProperty("Technician Page", pageUrl())
  UpdateProperty("Last Result", gLastResult)
  setVar("RUN_STATUS", status)
  setVar("CURRENT_ROOM", gEngine:currentRoom() or "")
  setVar("PASSED_COUNT", c.passed)
  setVar("FAILED_COUNT", c.failed)
  setVar("SKIPPED_COUNT", c.skipped)
  setVar("OPEN_COUNT", c.pending)
end

local function refused(what, why)
  UpdateProperty("Last Refusal", string.format("%s: %s (%s)", what, tostring(why), os.date("%H:%M:%S")))
  log:warn("%s refused: %s", what, tostring(why))
end

-- ─── The Agent: as-built record ─────────────────────────────────────────────

--- Offers a signed-off run to the Agent. Quiet when there is no Agent; kept
--- pending until the Agent acknowledges it (EC.SBOS_COMMISSIONING_ACK).
local function pushResult()
  if gEngine == nil or gPendingPush == nil or gEngine.last_signed == nil then
    return false
  end
  local agent = license.agentDeviceId()
  if agent == nil or gEngine.last_signed.run_id ~= gPendingPush then
    return false
  end
  local ok = pcall(function()
    C4:SendToDevice(agent, "SBOS_COMMISSIONING_RESULT", {
      run_id = gPendingPush,
      json = JSON:encode(gEngine.last_signed),
    })
  end)
  return ok
end

-- ─── Engine wiring ──────────────────────────────────────────────────────────

local function onEngineEvent(kind, f)
  saveSoon()
  if kind == "run_started" then
    recordHistory("Commissioning run started", "scope: " .. tostring(f.scope))
  elseif kind == "item_judged" then
    recordHistory(
      string.format("Commissioning: %s %s", tostring(f.name), tostring(f.status)),
      string.format("room %s%s%s", tostring(f.room), f.auto and " (automatic)" or "", f.note and (": " .. f.note) or "")
    )
  elseif kind == "item_failed" then
    setVar("LAST_FAILED_ITEM", string.format("%s (%s)", tostring(f.name), tostring(f.room)))
    fire(EVENT_ITEM_FAILED)
  elseif kind == "room_passed" then
    setVar("LAST_PASSED_ROOM", tostring(f.room))
    recordHistory("Commissioning: room passed", tostring(f.room))
    fire(EVENT_ROOM_PASSED)
  elseif kind == "run_completed" then
    local c = f.record.counts
    gLastResult = string.format(
      "%s: %d passed, %d failed, %d skipped (%s)",
      f.record.run_id,
      c.passed,
      c.failed,
      c.skipped,
      os.date("%Y-%m-%d %H:%M")
    )
    gPendingPush = f.record.run_id
    save()
    recordHistory(
      "Commissioning run signed off",
      string.format(
        "%d passed, %d failed, %d skipped, by %s",
        c.passed,
        c.failed,
        c.skipped,
        tostring(f.record.signed_off_by)
      )
    )
    pushResult()
    fire(EVENT_RUN_COMPLETED)
  elseif kind == "run_aborted" then
    recordHistory("Commissioning run aborted", tostring(f.run_id))
  end
  paint()
end

local function schedule(ms, fn)
  gTimerSeq = gTimerSeq + 1
  local id = "CmSettle" .. gTimerSeq
  gTimerIds[id] = true
  SetTimer(id, ms, function()
    gTimerIds[id] = nil
    fn()
  end)
end

local function watchSensor(item)
  local vars = readVars(item.device_id)
  local name, value = Actuate.sensorVariable(vars)
  if name == nil then
    return nil
  end
  local varId = varIdByName(item.device_id, name)
  if varId == nil then
    return nil
  end
  local ok = pcall(function()
    C4:RegisterVariableListener(item.device_id, varId)
  end)
  if not ok then
    return nil
  end
  gWatch[item.device_id .. ":" .. varId] = name
  return { id = varId, name = name, value = value }
end

local function unwatchSensor(item)
  for key in pairs(gWatch) do
    local dev, varId = key:match("^(%d+):(%d+)$")
    if tonumber(dev) == item.device_id then
      gWatch[key] = nil
      pcall(function()
        C4:UnregisterVariableListener(item.device_id, tonumber(varId))
      end)
    end
  end
end

local function buildEngine()
  gEngine = Engine.new({
    now = os.time,
    schedule = schedule,
    emit = onEngineEvent,
    watch = watchSensor,
    unwatch = unwatchSensor,
    options = gOptions,
    settle_ms = (tonumber(Properties["Settle Seconds"]) or 4) * 1000,
    actuator = Actuate.new({
      send = function(deviceId, command, params)
        C4:SendToDevice(deviceId, command, params)
      end,
      vars = readVars,
    }),
  })
end

-- ─── Test list ──────────────────────────────────────────────────────────────

--- Rebuilds the list from the project. Never while a run is in progress: the
--- run holds its own results and the list must not move under it.
local function rebuildList()
  if gEngine == nil then
    return
  end
  if gEngine:active() then
    gRebuildWanted = true
    return
  end
  gRebuildWanted = false
  gEngine:setItems(Engine.buildList(readDevices(), { manual = gManual, av_source = avSource() }))
  paint()
end

--- The Add Item picker, back to "-" after a pick.
local function paintAddList()
  local l = {}
  for label in pairs(gDeviceList) do
    l[#l + 1] = label
  end
  table.sort(l)
  pcall(function()
    C4:UpdatePropertyList("Add Item", "-" .. (#l > 0 and ("," .. table.concat(l, ",")) or ""), "-")
  end)
end

--- Fills the two device pickers. Returns the labels, for tests.
local function refreshPickers()
  local labels, byLabel = {}, {}
  for id, d in pairs(readDevices()) do
    local label = Engine.listLabel(d.deviceName or ("Device " .. id), d.roomName, id)
    labels[#labels + 1] = label
    byLabel[label] = id
  end
  table.sort(labels)
  gDeviceList = byLabel
  local joined = table.concat(labels, ",")
  pcall(function()
    C4:UpdatePropertyList("Add Item", joined == "" and "-" or ("-," .. joined), "-")
    C4:UpdatePropertyList(
      "AV Test Source",
      joined == "" and "-" or ("-," .. joined),
      Properties["AV Test Source"] or "-"
    )
  end)
  return labels
end

local function addManual(entry, kindChoice)
  local devices = readDevices()
  local d = devices[entry.id]
  local kind = Engine.kindFromChoice(kindChoice) or (d and Engine.classify(d.driverFileName))
  if kind == nil then
    refused("Add Item", "cannot tell what kind of device " .. entry.name .. " is; choose Add Item As first")
    return false
  end
  for i, m in ipairs(gManual) do
    if m.id == entry.id and m.kind == kind then
      table.remove(gManual, i)
      break
    end
  end
  gManual[#gManual + 1] = {
    id = entry.id,
    name = entry.name,
    room = entry.room,
    kind = kind,
    source = kind == "av" and avSource() or nil,
  }
  save()
  rebuildList()
  return true
end

-- ─── Licence ────────────────────────────────────────────────────────────────

local function reconcileLicence()
  local halt = license.enforces()
  if halt and not gHalted then
    gHalted = true
    log:warn("SmartBuildOS licence: %s - Commissioning Matrix is read-only", tostring(license.statusLabel()))
  elseif not halt and gHalted then
    gHalted = false
  end
  if not halt then
    pushResult()
  end
  paint()
end

--- Runs an engine mutation from Composer or the phone page.
local function run(what, fn)
  if gEngine == nil then
    return { ok = false, reason = "starting" }
  end
  if gHalted then
    refused(what, "read-only: SmartBuildOS licence")
    return { ok = false, reason = "read-only: SmartBuildOS licence" }
  end
  local ok, a, b = fn()
  saveSoon()
  paint()
  if not ok then
    refused(what, a)
    return { ok = false, reason = tostring(a) }
  end
  return { ok = true, record = b }
end

-- ─── Phone page ─────────────────────────────────────────────────────────────

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

local function stateDoc()
  local counts = gEngine:counts()
  local items = {}
  local run = gEngine.run
  local byKey = {}
  for _, r in ipairs(run and run.results or {}) do
    byKey[r.key] = r
  end
  -- Two devices in one room can carry the same name (bench, 13 Nov: two
  -- "Living" lights): the page shows the device id on both so the technician
  -- can tell them apart. The record keeps the plain name and the id.
  local seen = {}
  for _, it in ipairs(gEngine.items) do
    local k = tostring(it.room) .. "\0" .. tostring(it.name)
    seen[k] = (seen[k] or 0) + 1
  end
  for _, it in ipairs(gEngine.items) do
    local r = byKey[it.key]
    if run == nil or r ~= nil then
      local dup = seen[tostring(it.room) .. "\0" .. tostring(it.name)] > 1
      items[#items + 1] = {
        key = it.key,
        name = dup and (tostring(it.name) .. " (#" .. tostring(it.key):match("(%d+)$") .. ")") or it.name,
        room = it.room,
        kind = it.kind,
        origin = it.origin,
        status = r and r.status or "pending",
        prompt = r and r.prompt or nil,
        reported = r and r.reported or nil,
        detail = r and r.detail or nil,
        readback = r and r.readback or nil,
        note = r and r.note or nil,
        attempts = r and r.attempts or 0,
      }
    end
  end
  return {
    status = runStatus(),
    read_only = gHalted,
    licence = license.statusLabel(),
    run_id = run and run.id or nil,
    scope = run and run.scope or nil,
    technician = run and run.technician or trim(Properties["Technician Name"]),
    signed_off_by = run and run.signed_by or nil,
    current_room = gEngine:currentRoom(),
    counts = counts,
    rooms = gEngine:rooms(),
    items = items,
    driver_version = tostring(C4:GetDriverConfigInfo("version")),
  }
end

local function resultJson()
  local rec = gEngine.run and gEngine:record() or gEngine.last_signed
  if rec == nil then
    return nil
  end
  return JSON:encode(rec)
end

local PAGE_ACTIONS = {
  run = function(doc)
    return run("Start Run", function()
      rebuildList()
      return gEngine:startRun({ scope = doc.scope, technician = doc.technician or Properties["Technician Name"] })
    end)
  end,
  room = function(doc)
    return run("Start Room", function()
      rebuildList()
      if not gEngine:active() then
        local ok, why =
          gEngine:startRun({ scope = doc.room, technician = doc.technician or Properties["Technician Name"] })
        if not ok then
          return ok, why
        end
      end
      return gEngine:selectRoom(doc.room)
    end)
  end,
  test = function(doc)
    return run("Test Item", function()
      return gEngine:test(tostring(doc.key or ""))
    end)
  end,
  mark = function(doc)
    return run("Mark Item", function()
      return gEngine:mark(tostring(doc.key or ""), doc.verdict, doc.note)
    end)
  end,
  signoff = function(doc)
    local r = run("Sign Off", function()
      return gEngine:signOff(doc.name or Properties["Technician Name"])
    end)
    r.record = nil
    return r
  end,
  abort = function()
    return run("Abort Run", function()
      return gEngine:abort()
    end)
  end,
}

local relayProvider = {
  appHtml = appHtml,
  appWhy = function()
    return gAppHtmlWhy
  end,
  state = function()
    return JSON:encode(stateDoc())
  end,
  result = resultJson,
  act = function(name, doc)
    return PAGE_ACTIONS[name](doc)
  end,
  encode = function(t)
    return JSON:encode(t)
  end,
  decode = function(s)
    return JSON:decode(tostring(s))
  end,
}

function OnServerDataIn(handle, data, _, _, identifier)
  if identifier ~= nil and identifier ~= UI_RELAY_ID then
    return
  end
  gRelayBuffers[handle] = (gRelayBuffers[handle] or "") .. tostring(data or "")
  if #gRelayBuffers[handle] > 64 * 1024 then
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

local function startUiRelay()
  if gRelayPort ~= nil then
    return
  end
  local ok = pcall(function()
    C4:CreateServer(UI_RELAY_PORT, "", false, UI_RELAY_ID)
  end)
  if ok then
    gRelayPort = UI_RELAY_PORT
    log:info("Technician page relay listening on port %d", UI_RELAY_PORT)
  else
    log:warn("Technician page relay could not listen on port %d", UI_RELAY_PORT)
  end
end

local function stopUiRelay()
  if gRelayPort ~= nil then
    pcall(function()
      C4:DestroyServer(gRelayPort)
    end)
    gRelayPort = nil
  end
  gRelayBuffers = {}
end

gHost = RelayHost.new({
  port = UI_RELAY_PORT,
  service = "commissioning",
  configured = function()
    return Properties["App Relay Address"]
  end,
  onChange = function()
    if gInitialized then
      paint()
    end
  end,
})

-- ─── Lifecycle ──────────────────────────────────────────────────────────────

local function registerComposerSurface()
  for _, v in ipairs({
    { "RUN_STATUS", "starting", "STRING" },
    { "CURRENT_ROOM", "", "STRING" },
    { "PASSED_COUNT", 0, "NUMBER" },
    { "FAILED_COUNT", 0, "NUMBER" },
    { "SKIPPED_COUNT", 0, "NUMBER" },
    { "OPEN_COUNT", 0, "NUMBER" },
    { "LAST_FAILED_ITEM", "", "STRING" },
    { "LAST_PASSED_ROOM", "", "STRING" },
  }) do
    pcall(function()
      C4:AddVariable(v[1], v[2], v[3], true)
    end)
  end
  for _, e in ipairs({
    { 1, "Room Passed", "Every item in a room passed (LAST_PASSED_ROOM says which)" },
    { 2, "Run Completed", "A technician signed the run off" },
    { 3, "Item Failed", "An item was marked failed (LAST_FAILED_ITEM says which)" },
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
  log:setLogName("Commissioning")
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

  buildEngine()
  local stored = persist:get(STATE_KEY, false)
  if type(stored) == "table" then
    local ok, err = pcall(function()
      gEngine:restore(stored)
    end)
    if not ok then
      log:error("Persisted state unreadable (%s); starting empty", tostring(err))
    end
  end
  local manual = persist:get(MANUAL_KEY, false)
  if type(manual) == "table" then
    gManual = manual
  end
  local pending = persist:get(PUSH_KEY, "")
  gPendingPush = (type(pending) == "string" and pending ~= "") and pending or nil
  if gEngine.last_signed then
    gLastResult = string.format("%s (restored)", tostring(gEngine.last_signed.run_id))
  end

  license.setup({ sku = SKU })
  EC.SBOS_ENTITLEMENT = function(tParams)
    license.onEntitlement(tParams)
    reconcileLicence()
  end

  rebuildList()
  refreshPickers()
  gInitialized = true
  UpdateProperty("Driver Status", "Online")
  pcall(function()
    UpdateProperty("Driver Version", tostring(C4:GetDriverConfigInfo("version")))
  end)
  startUiRelay()
  gHost:check()
  paint()
  SetTimer(STATUS_TIMER, 60 * ONE_SECOND, function()
    if gRelayPort ~= nil then
      gHost:checkIfDue()
    end
    if gRebuildWanted then
      rebuildList()
    end
    pushResult()
    paint()
  end, true)
end

function OnDriverDestroyed()
  pcall(license.stop)
  if gEngine then
    save()
  end
  stopUiRelay()
  CancelTimer(PERSIST_TIMER)
  CancelTimer(STATUS_TIMER)
  for id in pairs(gTimerIds) do
    CancelTimer(id)
  end
  gTimerIds = {}
end

--- Director's callback for a registered sensor variable.
function OnWatchedVariableChanged(idDevice, idVariable, strValue)
  if gEngine == nil then
    return
  end
  local name = gWatch[tostring(tonumber(idDevice)) .. ":" .. tostring(tonumber(idVariable))]
  if name == nil then
    return
  end
  pcall(function()
    gEngine:sensorChanged(tonumber(idDevice), name, strValue)
  end)
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

function OPC.Settle_Seconds(value)
  local n = tonumber(value)
  if n == nil or n < 1 or n > 30 then
    n = 4
  end
  if gEngine then
    gEngine.deps.settle_ms = n * 1000
  end
end

function OPC.AV_Test_Volume(value)
  local n = tonumber(value)
  if n == nil or n < 1 or n > 40 then
    n = 15
  end
  gOptions.av_volume = n
end

function OPC.AV_Test_Source()
  if gInitialized then
    rebuildList()
  end
end

function OPC.Add_Item(value)
  if not gInitialized or value == nil or value == "-" or value == "" then
    return
  end
  local entry = Engine.parseListEntry(value)
  if entry == nil then
    refused("Add Item", "could not read '" .. tostring(value) .. "'")
  else
    addManual(entry, Properties["Add Item As"])
  end
  paintAddList()
  Properties["Add Item"] = "-"
end

function OPC.App_Relay_Address()
  if gInitialized then
    gHost:check()
    paint()
  end
end

-- ─── Actions ────────────────────────────────────────────────────────────────

function EC.REGISTER_NOW()
  license.register()
end

function EC.PRINT_PAGE_LINK()
  -- Printed, not logged: the dealer asked for it, and the link carries the access token.
  log:print("Page link: %s", pageUrl())
end

function EC.REFRESH_STATUS()
  paint()
end

function EC.REFRESH_LISTS_ACTION()
  refreshPickers()
  rebuildList()
end

function EC.REBUILD_LIST_ACTION()
  rebuildList()
end

function EC.CLEAR_MANUAL_ACTION()
  gManual = {}
  save()
  rebuildList()
end

function EC.NEW_PAGE_LINK_ACTION()
  gRelayToken = nil
  persist:delete(TOKEN_KEY)
  relayToken()
  paint()
end

local function printList()
  if gEngine == nil then
    return
  end
  log:print("== Commissioning test list ==")
  local room = nil
  for _, it in ipairs(gEngine.items) do
    if it.room ~= room then
      room = it.room
      log:print("  %s", room)
    end
    log:print(
      "    %-8s %-32s id %d%s",
      Engine.KIND_LABEL[it.kind],
      it.name,
      it.device_id,
      it.origin == "manual" and "  (added by hand)" or ""
    )
  end
end

function EC.PRINT_LIST_ACTION()
  printList()
end

function EC.PRINT_RESULTS()
  if gEngine == nil then
    return
  end
  log:print("== Commissioning results ==")
  log:print("  licence: %s", license.describe())
  local rec = gEngine.run and gEngine:record() or gEngine.last_signed
  for _, line in ipairs(Engine.textLines(rec)) do
    log:print("%s", line)
  end
end

-- ─── Composer programming commands ─────────────────────────────────────────

function EC.START_RUN(t)
  t = t or {}
  run("Start Run", function()
    rebuildList()
    return gEngine:startRun({ technician = t.TECHNICIAN or Properties["Technician Name"] })
  end)
end

EC.START_RUN_ACTION = EC.START_RUN

function EC.START_ROOM(t)
  t = t or {}
  run("Start Room", function()
    rebuildList()
    if not gEngine:active() then
      local ok, why = gEngine:startRun({ scope = t.ROOM, technician = t.TECHNICIAN or Properties["Technician Name"] })
      if not ok then
        return ok, why
      end
    end
    return gEngine:selectRoom(t.ROOM)
  end)
end

function EC.ABORT_RUN()
  run("Abort Run", function()
    return gEngine:abort()
  end)
end

EC.ABORT_RUN_ACTION = EC.ABORT_RUN

--- The Agent asks for the latest signed-off record (or acknowledges it).
function EC.SBOS_COMMISSIONING_PULL()
  if gEngine and gEngine.last_signed then
    gPendingPush = gEngine.last_signed.run_id
    pushResult()
  end
end

function EC.SBOS_COMMISSIONING_ACK(t)
  t = t or {}
  if gPendingPush ~= nil and tostring(t.run_id or "") == gPendingPush then
    gPendingPush = nil
    save()
    paint()
  end
end

-- ─── Conditionals ───────────────────────────────────────────────────────────

function TC.RUN_HAS_FAILURES()
  return gEngine ~= nil and gEngine:hasFailures()
end
