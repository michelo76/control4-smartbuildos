--[[==========================================================================
  UniFi Protect Gateway — parent driver

  Owns the connection to ONE UniFi Protect console: address, API key, the
  device inventory, and one provider CONTROL binding per camera for child
  camera drivers to attach to. It carries no camera proxy itself — a `.c4z`
  cannot grow proxies at runtime, so cameras that appear in Navigator are the
  child driver's job (one instance per camera), and this driver is the single
  place the console is polled from.

  ── SCOPE ─────────────────────────────────────────────────────────────────────

  Connect, inventory, bindings, polling, stream URL fan-out to bound children,
  and the live events websocket (motion / smart detections / doorbell rings,
  routed per-camera over the bindings). NOT here yet: snapshots, PTZ preset
  surfacing, talkback. See docs/unifi-protect-driver-research.md for the whole
  programme.

  ── THE API KEY NEVER LIVES IN THE PROJECT FILE ───────────────────────────────

  A Composer project file is handed between dealers and backed up in the
  clear; a <password> property is masked in the UI, not in the file. So the
  key follows the Pairing Code pattern from the SmartBuildOS connector: the
  property is a LETTERBOX — paste, store encrypted via persist, wipe the
  property. What survives in the project is nothing.
============================================================================]]

--#ifdef DRIVERCENTRAL
DC_PID = 0
DC_X = nil
DC_FILENAME = "unifi-protect.c4z"
--#else
DRIVER_GITHUB_REPO = "michelo76/control4-smartbuildos"
DRIVER_FILENAMES = {
  "unifi-protect.c4z",
}
--#endif

require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")
-- REQUIRED, even though nothing here names it: `lib.http` calls the GLOBAL
-- `urlDo`, which this module defines. Without it every request throws
-- "attempt to call a nil value" inside the handler's xpcall, which prints and
-- swallows it — the driver sits on whatever status it set before the call and
-- nothing else ever happens. This exact omission once shipped in the
-- SmartBuildOS connector with every test green; test_unifi_protect_globals.lua
-- exists to fail if this line is ever dropped.
require("drivers-common-public.global.url")

JSON = require("JSON")

local log = require("lib.logging")
local persist = require("lib.persist")
local bindings = require("lib.bindings")
local Protect = require("unifi.protect")
--- The vendored (locally-forked) websocket module — used for the console's
--- live event stream. The official Protect events socket speaks PLAIN JSON
--- text frames, unlike the unofficial API's deflate-compressed binary
--- framing; that simplicity is half the reason this driver builds on the
--- official surface.
local WebSocket = require("drivers-common-public.module.websocket")

--- The one client this driver drives. Reconfigured from properties + persist
--- on every relevant change; see configureClient().
local protect = Protect:new()

-- ─── Constants ────────────────────────────────────────────────────────────────

--- Persist keys. The API key is stored ENCRYPTED — it is an administrator
--- credential to the customer's camera system.
local API_KEY_PERSIST = "protect_api_key"
--- Cached inventory from the last successful sync, so a Director restart
--- shows the last-known fleet instead of dashes until the first poll lands.
local INVENTORY_PERSIST = "protect_inventory"

--- Namespace for the per-camera bindings in lib.bindings' persisted table.
local CAMERA_BINDING_NS = "cameras"
--- Class the child camera driver's consumer connection must declare.
local CAMERA_BINDING_CLASS = "UNIFI_PROTECT_CAMERA"

local POLL_TIMER = "ProtectPoll"
local EVENTS_RECONNECT_TIMER = "ProtectEventsReconnect"

--- How long after a drop before the events socket is retried. Long enough
--- not to hammer a rebooting console, short enough that a doorbell pressed
--- two minutes after a Protect update still rings through.
local EVENTS_RECONNECT_SECONDS = 30

--- Poll interval labels mapped to seconds.
--- @type table<string, number>
local INTERVALS = {
  ["30s"] = 30,
  ["1m"] = 60,
  ["2m"] = 2 * 60,
  ["5m"] = 5 * 60,
  ["15m"] = 15 * 60,
}

-- ─── State ────────────────────────────────────────────────────────────────────

gInitialized = false

--- Whether the last exchange with the console succeeded. Drives the
--- UNIFI_PROTECT_CONNECTED conditional and the Connection Status property,
--- and transitions are LOGGED ONCE — a poll every minute must not write
--- "Connected" sixty times an hour.
gConnected = false

--- The last inventory applied, keyed by kind. Shape:
--- { cameras = { {id, name, mac, state}, ... }, lights = {...}, sensors = {...},
---   chimes = {...}, updated_at = "..." }
gInventory = nil

--- Forward declaration; defined with the binding protocol below, called from
--- applyInventory above it.
local pushCameraStates

--- The live events websocket, or nil when not running.
gEventsSocket = nil

--- Forward declarations; defined in the Live Events section at the bottom,
--- called from lifecycle and property handlers above it.
local startEventsSocket, stopEventsSocket

-- ─── Helpers ──────────────────────────────────────────────────────────────────

local function apiKey()
  return persist:get(API_KEY_PERSIST, "", true) or ""
end

local function isConfigured()
  return Protect.normalizeAddress(Properties["Console Address"]) ~= "" and apiKey() ~= ""
end

--- Rebuilds the client from current settings. Called from every property
--- handler that feeds it, so the client can never be stale.
local function configureClient()
  protect:configure(Properties["Console Address"], apiKey(), Properties["Verify TLS Certificate"] == "On")
end

--- Sets the connected flag and says so — on TRANSITION only.
--- @param connected boolean
--- @param reason string What to show in Connection Status.
local function setConnected(connected, reason)
  if connected ~= gConnected then
    gConnected = connected
    if connected then
      log:info("Connected to UniFi Protect: %s", reason)
    else
      log:warn("Not connected to UniFi Protect: %s", reason)
    end
  end
  UpdateProperty("Connection Status", reason)
end

--- Renders a rejected request into a status line that says WHICH failure this
--- is. `lib.http` rejects on any non-2xx as well as on transport failure; a
--- numeric code means the console answered. 401/403 is the key being wrong,
--- and reporting that as "unreachable" sends the dealer to check cables when
--- they should be checking the key.
--- @param err table The HTTPErrorResponse.
--- @return string status
local function describeFailure(err)
  local code = type(err) == "table" and tonumber(err.code) or nil
  if code == 401 or code == 403 then
    return string.format("Refused (HTTP %d) - check the API key", code)
  elseif code ~= nil and code > 0 then
    return string.format("Console error (HTTP %d)", code)
  end
  return "Console unreachable - check the address and network"
end

--- One camera's worth of what this driver keeps. The full API object carries
--- settings this driver has no use for; keeping the cache small keeps the
--- persist write small.
local function summarizeCamera(item)
  return {
    id = tostring(item.id or ""),
    name = tostring(item.name or "Camera"),
    mac = tostring(item.mac or ""),
    state = tostring(item.state or "UNKNOWN"),
  }
end

local function summarizeDevice(item)
  return {
    id = tostring(item.id or ""),
    name = tostring(item.name or ""),
    state = tostring(item.state or "UNKNOWN"),
  }
end

--- "3 (2 online)" — the shape every count property uses.
--- @param list table[]|nil Devices with a `state` field.
--- @return string label
local function countLabel(list)
  if list == nil then
    return "-"
  end
  local online = 0
  for _, device in ipairs(list) do
    if device.state == "CONNECTED" then
      online = online + 1
    end
  end
  return string.format("%d (%d online)", #list, online)
end

-- ─── Bindings ─────────────────────────────────────────────────────────────────

--- Ensures a provider CONTROL binding exists for every camera in the
--- inventory. Bindings are CREATED for new cameras and NEVER auto-deleted for
--- missing ones: a camera that is offline for a rebuild, or mid-migration
--- between consoles, must not cost the dealer their Composer connections.
--- Deleting is an explicit action (Prune Missing Camera Bindings).
--- @param cameras table[] Summarized cameras.
local function ensureCameraBindings(cameras)
  for _, cam in ipairs(cameras) do
    if cam.id ~= "" then
      bindings:getOrAddDynamicBinding(CAMERA_BINDING_NS, cam.id, "CONTROL", true, cam.name, CAMERA_BINDING_CLASS)
    end
  end
end

--- Camera bindings with no camera behind them in the current inventory.
--- @return table<string, Binding> stale Keyed by camera id.
local function staleCameraBindings()
  local present = {}
  for _, cam in ipairs((gInventory or {}).cameras or {}) do
    present[cam.id] = true
  end
  local stale = {}
  for key, binding in pairs(bindings:getDynamicBindings(CAMERA_BINDING_NS)) do
    if not present[key] then
      stale[key] = binding
    end
  end
  return stale
end

-- ─── Sync ─────────────────────────────────────────────────────────────────────

--- Applies a completed inventory: counts, bindings, cache.
--- @param inventory table The new inventory.
--- @return number staleCount Camera bindings with no camera behind them.
local function applyInventory(inventory)
  inventory.updated_at = os.date("%Y-%m-%d %H:%M:%S")
  gInventory = inventory

  UpdateProperty("Cameras", countLabel(inventory.cameras))
  UpdateProperty("Lights", countLabel(inventory.lights))
  UpdateProperty("Sensors", countLabel(inventory.sensors))
  UpdateProperty("Chimes", countLabel(inventory.chimes))
  UpdateProperty("Last Sync", inventory.updated_at)

  ensureCameraBindings(inventory.cameras)
  pushCameraStates(inventory.cameras)

  local staleCount = 0
  for _, binding in pairs(staleCameraBindings()) do
    staleCount = staleCount + 1
    log:warn(
      "Camera binding '%s' (id %s) has no camera behind it; run 'Prune Missing Camera Bindings' to remove it",
      binding.displayName,
      binding.bindingId
    )
  end

  persist:set(INVENTORY_PERSIST, inventory)
  return staleCount
end

--- Pulls the whole inventory, one list at a time.
---
--- SEQUENTIAL on purpose. Four parallel HTTPS requests against a console that
--- is also serving video is a burst for no benefit at a once-a-minute cadence,
--- and sequencing means one failure aborts the sync with a single status line
--- instead of four racing ones.
--- @param onDone fun(ok: boolean)|nil Called when the sync settles.
function syncDevices(onDone)
  if not isConfigured() then
    setConnected(false, "Not configured - set the Console Address and API Key")
    if onDone then
      onDone(false)
    end
    return
  end
  configureClient()

  local inventory = {}
  local steps = {
    { key = "cameras", fetch = "getCameras", summarize = summarizeCamera },
    { key = "lights", fetch = "getLights", summarize = summarizeDevice },
    { key = "sensors", fetch = "getSensors", summarize = summarizeDevice },
    { key = "chimes", fetch = "getChimes", summarize = summarizeDevice },
  }

  local function fail(err)
    setConnected(false, describeFailure(err))
    if onDone then
      onDone(false)
    end
  end

  local function step(i)
    if i > #steps then
      local staleCount = applyInventory(inventory)
      if staleCount > 0 then
        setConnected(true, string.format("Connected (%d stale camera binding(s) - see Actions)", staleCount))
      else
        setConnected(true, "Connected")
      end
      if onDone then
        onDone(true)
      end
      return
    end
    local s = steps[i]
    protect[s.fetch](protect):next(function(res)
      local list = Protect.decodeBody(res.body)
      if type(list) ~= "table" then
        fail({ code = res.code })
        return
      end
      local summarized = {}
      for _, item in ipairs(list) do
        table.insert(summarized, s.summarize(item))
      end
      inventory[s.key] = summarized
      step(i + 1)
    end, fail)
  end

  step(1)
end

--- Proves the address + key work and reads what they unlock: the Protect
--- version and the NVR's name. On success, runs a full sync — a connection
--- test that succeeds and then shows dash-for-cameras answers half the
--- question it was asked.
function testConnection()
  if not isConfigured() then
    setConnected(false, "Not configured - set the Console Address and API Key")
    return
  end
  configureClient()
  UpdateProperty("Connection Status", "Testing...")

  protect:getInfo():next(function(res)
    local info = Protect.decodeBody(res.body) or {}
    UpdateProperty("Protect Version", tostring(info.applicationVersion or "unknown"))
    protect:getNvr():next(function(nvrRes)
      local nvr = Protect.decodeBody(nvrRes.body) or {}
      UpdateProperty("NVR Name", tostring(nvr.name or "unknown"))
      syncDevices()
    end, function(err)
      -- meta/info answered, nvrs did not: still connected enough to say so.
      log:warn("NVR details unavailable: %s", describeFailure(err))
      syncDevices()
    end)
  end, function(err)
    setConnected(false, describeFailure(err))
  end)
end

-- ─── Polling ──────────────────────────────────────────────────────────────────

local function schedulePoll()
  CancelTimer(POLL_TIMER)
  local seconds = INTERVALS[Properties["Device Poll Interval"]]
  if seconds == nil or not isConfigured() then
    return
  end
  SetTimer(POLL_TIMER, seconds * ONE_SECOND, function()
    syncDevices()
  end, true)
end

-- ─── Lifecycle ────────────────────────────────────────────────────────────────

function OnDriverInit()
  --#ifdef DRIVERCENTRAL
  require("cloud-client-byte")
  C4:AllowExecute(false)
  --#else
  C4:AllowExecute(true)
  --#endif
  gInitialized = false
  log:setLogName(C4:GetDeviceData(C4:GetDeviceID(), "name"))
  log:setLogLevel(Properties["Log Level"])
  log:setLogMode(Properties["Log Mode"])
  log:trace("OnDriverInit()")
  -- From OnDriverInit, NOT OnDriverLateInit: Director resolves stored
  -- connections before late init, and consumer-side connections onto a binding
  -- that does not exist yet are permanently dropped. The child camera drivers
  -- are exactly such consumers.
  bindings:restoreBindings()
end

function OnDriverLateInit()
  log:trace("OnDriverLateInit()")
  if not CheckMinimumVersion("Driver Status") then
    return
  end

  -- Guarded by SHAPE, not nil: persist:get with no default returns its EMPTY
  -- sentinel table for a missing key, and a sentinel treated as an inventory
  -- publishes dash-counts for a fleet that was never synced.
  local cached = persist:get(INVENTORY_PERSIST)
  if type(cached) == "table" and cached.cameras ~= nil then
    gInventory = cached
  end

  for p, _ in pairs(Properties) do
    local status, err = pcall(OnPropertyChanged, p)
    if not status and err then
      log:error("Error in OnPropertyChanged for property '%s': %s", p, err or "unknown error")
    end
  end

  gInitialized = true
  UpdateProperty("Driver Status", "Online")

  if gInventory ~= nil then
    -- Last-known fleet, labelled as such: cached counts presented as live
    -- would show "4 online" for a console that has been dark for a week.
    UpdateProperty("Cameras", countLabel(gInventory.cameras))
    UpdateProperty("Lights", countLabel(gInventory.lights))
    UpdateProperty("Sensors", countLabel(gInventory.sensors))
    UpdateProperty("Chimes", countLabel(gInventory.chimes))
    UpdateProperty("Last Sync", tostring(gInventory.updated_at or "unknown") .. " (cached)")
  end

  if isConfigured() then
    testConnection()
    schedulePoll()
    startEventsSocket()
  else
    setConnected(false, "Not configured - set the Console Address and API Key")
  end
end

function OnDriverDestroyed()
  CancelTimer(POLL_TIMER)
  stopEventsSocket()
end

-- ─── Conditionals ─────────────────────────────────────────────────────────────

function TC.UNIFI_PROTECT_CONNECTED()
  return gConnected
end

-- ─── Property handlers ────────────────────────────────────────────────────────

--- The letterbox. A pasted key is stored encrypted and the property wiped in
--- the same handler, so the key exists in the project file only between the
--- paste and the next property flush. The wipe writes "" back, and the empty
--- guard keeps that write from looking like a second (blank) key.
function OPC.API_Key(propertyValue)
  log:trace("OPC.API_Key(<redacted>)")
  local key = tostring(propertyValue or ""):gsub("%s+", "")
  if key == "" then
    return
  end
  persist:set(API_KEY_PERSIST, key, true)
  UpdateProperty("API Key", "")
  if gInitialized then
    testConnection()
    schedulePoll()
    startEventsSocket()
  end
end

-- The dispatcher logs property VALUES unless told otherwise. Both spellings,
-- because suppressDebug is consulted before the name is sanitized.
OPC.suppressDebug = OPC.suppressDebug or {}
OPC.suppressDebug["API Key"] = true
OPC.suppressDebug.API_Key = true

function OPC.Console_Address(propertyValue)
  log:trace("OPC.Console_Address('%s')", propertyValue)
  configureClient()
  if gInitialized and isConfigured() then
    testConnection()
    schedulePoll()
    -- The socket is keyed to the old address; tear it down and dial the new
    -- console rather than letting the old one reconnect-loop forever.
    stopEventsSocket()
    startEventsSocket()
  end
end

function OPC.Verify_TLS_Certificate(propertyValue)
  log:trace("OPC.Verify_TLS_Certificate('%s')", propertyValue)
  configureClient()
  if gInitialized and isConfigured() then
    testConnection()
  end
end

function OPC.Device_Poll_Interval(propertyValue)
  log:trace("OPC.Device_Poll_Interval('%s')", propertyValue)
  if gInitialized then
    schedulePoll()
  end
end

function OPC.Log_Mode(propertyValue)
  log:trace("OPC.Log_Mode('%s')", propertyValue)
  log:setLogMode(propertyValue)
  CancelTimer("LogMode")
  if not log:isEnabled() then
    UpdateProperty("Log Level", "3 - Info", true)
    return
  end
  log:warn("Log mode '%s' will expire in 3 hours", propertyValue)
  SetTimer("LogMode", 3 * ONE_HOUR, function()
    log:warn("Setting log mode to 'Off' (timer expired)")
    UpdateProperty("Log Mode", "Off", true)
  end)
  OnPropertyChanged("Log Level")
end

function OPC.Log_Level(propertyValue)
  log:trace("OPC.Log_Level('%s')", propertyValue)
  log:setLogLevel(propertyValue)
end

-- ─── Actions ──────────────────────────────────────────────────────────────────

function EC.TEST_CONNECTION()
  log:trace("EC.TEST_CONNECTION()")
  testConnection()
end

function EC.SYNC_DEVICES()
  log:trace("EC.SYNC_DEVICES()")
  syncDevices()
end

--- The inventory, into the log, for the dealer on the phone with support.
function EC.PRINT_INVENTORY()
  log:trace("EC.PRINT_INVENTORY()")
  if gInventory == nil then
    log:print("No inventory yet - run Sync Devices Now first")
    return
  end
  log:print("UniFi Protect inventory as of %s:", tostring(gInventory.updated_at))
  for _, kind in ipairs({ "cameras", "lights", "sensors", "chimes" }) do
    local list = gInventory[kind] or {}
    log:print("  %s (%d):", kind, #list)
    for _, device in ipairs(list) do
      log:print("    %s [%s] %s %s", device.name, device.state, device.id, device.mac or "")
    end
  end
end

--- The explicit destruction that syncs refuse to do implicitly. Severs any
--- Composer connections on the pruned bindings, which is why it is an action
--- with a warning in its name and not a side effect of polling.
function EC.PRUNE_STALE_CAMERAS()
  log:trace("EC.PRUNE_STALE_CAMERAS()")
  if gInventory == nil then
    log:warn("No inventory to prune against - run Sync Devices Now first")
    return
  end
  local pruned = 0
  for key, binding in pairs(staleCameraBindings()) do
    log:warn("Pruning camera binding '%s' (id %s)", binding.displayName, binding.bindingId)
    bindings:deleteBinding(CAMERA_BINDING_NS, key)
    pruned = pruned + 1
  end
  log:print("Pruned %d stale camera binding(s)", pruned)
end

--- Forgets the key and says so. Does NOT touch bindings or the cached
--- inventory: forgetting a credential and dismantling the project tree are
--- different intents, and the second one has its own action.
function EC.FORGET_API_KEY()
  log:trace("EC.FORGET_API_KEY()")
  persist:delete(API_KEY_PERSIST)
  configureClient()
  CancelTimer(POLL_TIMER)
  stopEventsSocket()
  setConnected(false, "Not configured - set the Console Address and API Key")
  log:print("API key forgotten")
end

-- ─── Child driver traffic ─────────────────────────────────────────────────────
--
-- The binding protocol, spoken over the per-camera CONTROL bindings with the
-- UniFi Protect Camera driver (one instance bound per camera):
--
--   child → parent  PROTECT_GET_CAMERA   {}            who am I bound to?
--   parent → child  PROTECT_CAMERA       {id, name, mac, state, console_host}
--   child → parent  PROTECT_GET_STREAMS  {KEY}         stream URLs, please
--   parent → child  PROTECT_STREAMS      {KEY, high?, medium?, low?}
--   parent → child  PROTECT_STREAMS_ERROR{KEY, reason}
--   parent → child  PROTECT_STATE        {id, name, state}   pushed on every sync
--
-- The child NEVER sees the API key: every console exchange happens here. KEY
-- is the child's correlation token for Navigator's async GET_STREAM_URLS flow
-- and is echoed back untouched.

--- The camera behind a binding id, or nil. The bindings table is keyed by
--- camera id; traffic arrives keyed by binding id, hence the reverse walk.
--- @param idBinding number The binding the request arrived on.
--- @return table|nil camera The summarized camera, plus its id.
local function cameraForBinding(idBinding)
  for key, binding in pairs(bindings:getDynamicBindings(CAMERA_BINDING_NS)) do
    if binding.bindingId == idBinding then
      for _, cam in ipairs((gInventory or {}).cameras or {}) do
        if cam.id == key then
          return cam
        end
      end
      -- Bound but not in the inventory (console down since the binding was
      -- made): identity still answerable from the binding itself.
      return { id = key, name = binding.displayName, mac = "", state = "UNKNOWN" }
    end
  end
  return nil
end

--- The console's host, for the child's GET_PROPERTIES answer. Protect serves
--- every camera's stream through the console (ports 7441/7447), so the
--- console host IS the camera address as far as a Navigator is concerned.
--- @return string host
local function consoleHost()
  return tostring(protect.baseUrl or ""):gsub("^https?://", ""):gsub(":%d+$", "")
end

--- Pushes online/offline to every bound child. Runs on every sync; a child
--- that is not bound simply never hears it, which is fine — it asks on bind.
--- (Assigns the forward declaration above applyInventory.)
--- @param cameras table[] Summarized cameras.
function pushCameraStates(cameras)
  local byId = {}
  for _, cam in ipairs(cameras) do
    byId[cam.id] = cam
  end
  for key, binding in pairs(bindings:getDynamicBindings(CAMERA_BINDING_NS)) do
    local cam = byId[key]
    if cam ~= nil then
      SendToProxy(binding.bindingId, "PROTECT_STATE", { id = cam.id, name = cam.name, state = cam.state })
    end
  end
end

function RFP.PROTECT_GET_CAMERA(idBinding)
  local cam = cameraForBinding(idBinding)
  if cam == nil then
    log:warn("PROTECT_GET_CAMERA on binding %s, which maps to no camera", tostring(idBinding))
    return
  end
  -- INFO, not trace: this is the handshake a dealer is watching for when a
  -- camera instance says "waiting for a reply".
  log:info("Camera identity requested on binding %s; answering '%s' (%s)", idBinding, cam.name, cam.id)
  SendToProxy(idBinding, "PROTECT_CAMERA", {
    id = cam.id,
    name = cam.name,
    mac = cam.mac,
    state = cam.state,
    console_host = consoleHost(),
  })
end

--- The Connections picture from this driver's side of the fence: every
--- camera binding, its camera, and which device (if any) Composer has bound
--- to it. The answer to "is the handshake even possible right now?".
function EC.PRINT_CAMERA_BINDINGS()
  log:trace("EC.PRINT_CAMERA_BINDINGS()")
  local byId = {}
  for _, cam in ipairs((gInventory or {}).cameras or {}) do
    byId[cam.id] = cam
  end
  local count = 0
  for key, binding in pairs(bindings:getDynamicBindings(CAMERA_BINDING_NS)) do
    count = count + 1
    local cam = byId[key]
    local boundTo = "nothing bound"
    local ok, consumers = pcall(function()
      return C4:GetBoundConsumerDevices(C4:GetDeviceID(), binding.bindingId)
    end)
    if ok and type(consumers) == "table" then
      local ids = {}
      for deviceId in pairs(consumers) do
        table.insert(ids, tostring(deviceId))
      end
      if #ids > 0 then
        boundTo = "bound to device " .. table.concat(ids, ", ")
      end
    end
    log:print(
      "  binding %s: '%s' (%s) [%s] - %s",
      binding.bindingId,
      binding.displayName,
      key,
      cam ~= nil and cam.state or "not in inventory",
      boundTo
    )
  end
  log:print("%d camera binding(s) total", count)
end

--- Stream URLs for the bound camera: read what exists, enable what is
--- missing, answer with the union.
---
--- GET first because it is idempotent and free; POST only for qualities the
--- GET came back without, so a camera whose streams are already enabled is
--- never churned. `package` is not requested — it is the doorbell package
--- lens, a special view no Navigator tile asks for by default.
function RFP.PROTECT_GET_STREAMS(idBinding, _, tParams)
  log:trace("RFP.PROTECT_GET_STREAMS(%s)", idBinding)
  local key = tostring((tParams or {}).KEY or "")
  local cam = cameraForBinding(idBinding)
  if cam == nil then
    SendToProxy(idBinding, "PROTECT_STREAMS_ERROR", { KEY = key, reason = "binding maps to no camera" })
    return
  end
  if not isConfigured() then
    SendToProxy(idBinding, "PROTECT_STREAMS_ERROR", { KEY = key, reason = "gateway not configured" })
    return
  end
  configureClient()

  local WANTED = { "high", "medium", "low" }

  local function reply(streams)
    local params = { KEY = key }
    local delivered = 0
    for _, quality in ipairs(WANTED) do
      local url = streams[quality]
      if type(url) == "string" and url ~= "" then
        params[quality] = url
        delivered = delivered + 1
      end
    end
    if delivered == 0 then
      SendToProxy(idBinding, "PROTECT_STREAMS_ERROR", { KEY = key, reason = "console returned no stream URLs" })
      return
    end
    SendToProxy(idBinding, "PROTECT_STREAMS", params)
  end

  local function fail(err)
    SendToProxy(idBinding, "PROTECT_STREAMS_ERROR", { KEY = key, reason = describeFailure(err) })
  end

  protect:getRtspsStreams(cam.id):next(function(res)
    local existing = Protect.decodeBody(res.body) or {}
    local missing = {}
    for _, quality in ipairs(WANTED) do
      if type(existing[quality]) ~= "string" or existing[quality] == "" then
        table.insert(missing, quality)
      end
    end
    if #missing == 0 then
      reply(existing)
      return
    end
    protect:createRtspsStreams(cam.id, missing):next(function(createRes)
      local created = Protect.decodeBody(createRes.body) or {}
      for _, quality in ipairs(WANTED) do
        if type(created[quality]) == "string" and created[quality] ~= "" then
          existing[quality] = created[quality]
        end
      end
      reply(existing)
    end, fail)
  end, fail)
end

-- ─── Live events ──────────────────────────────────────────────────────────────
--
-- The console's event stream: wss://<console>/proxy/protect/integration/v1/
-- subscribe/events, authenticated with the same X-API-KEY header, delivering
-- plain JSON text frames of the shape { type = "add"|"update", item = {...} }.
-- Camera events are normalized and forwarded to the bound child over its
-- binding; events for devices with no bound child are dropped here — the
-- child asks for nothing on connect, so there is no queue to overflow.

--- Protect event `type` values mapped to the binding protocol's `kind`.
--- Anything not listed (sensor, light, nvr events) has no camera child to
--- route to yet and is deliberately dropped.
--- @type table<string, string>
local EVENT_KINDS = {
  motion = "motion",
  ring = "ring",
  smartDetectZone = "smart",
  smartDetectLine = "line",
  smartDetectLoiterZone = "loiter",
  smartAudioDetect = "audio",
}

--- One frame off the events socket. pcall'd by the caller: a malformed frame
--- must cost one event, never the socket.
--- @param data string The raw JSON text frame.
local function handleProtectEvent(data)
  local msg = Protect.decodeBody(data)
  if type(msg) ~= "table" or type(msg.item) ~= "table" then
    return
  end
  local item = msg.item
  if item.modelKey ~= "event" then
    return
  end
  local kind = EVENT_KINDS[tostring(item.type or "")]
  if kind == nil then
    return
  end
  local binding = bindings:getDynamicBinding(CAMERA_BINDING_NS, tostring(item.device or ""))
  if binding == nil then
    return
  end

  -- "end" is a Lua keyword, hence the bracket access. An add-frame has no end
  -- timestamp; the update-frame that closes the event carries one — that is
  -- the entire start/end distinction.
  local phase = item["end"] ~= nil and "end" or "start"

  local params = { kind = kind, phase = phase }
  if type(item.smartDetectTypes) == "table" and #item.smartDetectTypes > 0 then
    params.types = table.concat(item.smartDetectTypes, ",")
  end
  if item.start ~= nil then
    params.at = tostring(item.start)
  end
  -- Plate text, if this Protect version includes it. The published schema
  -- carries none, so this is a defensive read that upgrades the experience
  -- when the console provides more than it promises.
  local plate = Select(item, "metadata", "licensePlate", "text")
  if type(plate) == "string" and plate ~= "" then
    params.value = plate
  end

  log:debug("Event %s/%s for camera %s -> binding %s", kind, phase, tostring(item.device), binding.bindingId)
  SendToProxy(binding.bindingId, "PROTECT_EVENT", params)
end

local function scheduleEventsReconnect()
  CancelTimer(EVENTS_RECONNECT_TIMER)
  SetTimer(EVENTS_RECONNECT_TIMER, EVENTS_RECONNECT_SECONDS * ONE_SECOND, function()
    startEventsSocket()
  end)
end

--- Opens (or re-opens) the events socket. (Assigns the forward declaration.)
startEventsSocket = function()
  if not isConfigured() then
    return
  end
  configureClient()

  local url = protect.baseUrl:gsub("^https://", "wss://") .. "/proxy/protect/integration/v1/subscribe/events"
  -- WebSocket:new reuses one instance per URL and re-takes the headers, so a
  -- changed API key lands on the existing socket rather than leaking a second.
  local ws, err = WebSocket:new(url, { "X-API-KEY: " .. apiKey() })
  if ws == nil then
    log:error("Could not create events socket: %s", tostring(err))
    UpdateProperty("Event Stream", "Failed to start")
    return
  end
  gEventsSocket = ws

  ws:SetProcessMessageFunction(function(_, data)
    local ok, handlerErr = pcall(handleProtectEvent, data)
    if not ok then
      log:warn("Event frame handling failed: %s", tostring(handlerErr))
    end
  end)
  ws:SetEstablishedFunction(function()
    log:info("Protect event stream connected")
    UpdateProperty("Event Stream", "Connected")
  end)
  local function dropped()
    -- Deliberate teardown nils gEventsSocket first; a drop while it is still
    -- set is the console going away, which is what the retry exists for.
    if gEventsSocket ~= nil then
      log:warn("Protect event stream dropped; retrying in %ds", EVENTS_RECONNECT_SECONDS)
      UpdateProperty("Event Stream", "Reconnecting...")
      scheduleEventsReconnect()
    end
  end
  ws:SetClosedByRemoteFunction(dropped)
  ws:SetOfflineFunction(dropped)

  UpdateProperty("Event Stream", "Connecting...")
  ws:Start()
end

--- Closes the events socket and stops retrying. (Assigns the forward
--- declaration.)
stopEventsSocket = function()
  CancelTimer(EVENTS_RECONNECT_TIMER)
  if gEventsSocket ~= nil then
    local ws = gEventsSocket
    gEventsSocket = nil
    pcall(function()
      ws:delete()
    end)
  end
  UpdateProperty("Event Stream", "Off")
end
