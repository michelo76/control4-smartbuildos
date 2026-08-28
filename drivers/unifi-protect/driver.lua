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

--- When the last websocket event arrived (display string), or nil.
gLastEventAt = nil

--- Last known alarm state off the NVR object: { armMode, armProfileId, breachDetectedAt }.
gAlarm = {}

--- ulp-users id -> { name, active } cache, refreshed lazily.
gUlpUsers = nil
gUlpUsersFetchedAt = 0

--- Per-webhook-name last-accepted time (os.time), for the flood guard.
gWebhookLast = {}

--- Serialized roster last handed to SmartBuildOS, to skip no-change pushes.
gSbosLastRoster = nil
gSbosConnectorId = nil

--- Forward declarations; defined in the Live Events section at the bottom,
--- called from lifecycle and property handlers above it.
local startEventsSocket, stopEventsSocket

--- Forward declarations; defined in the Snapshot Relay section at the
--- bottom, called from lifecycle and property handlers above it.
local startSnapshotRelay, stopSnapshotRelay, relaySnapshotUrl

--- Forward declarations for the security/alarm/health section at the bottom.
local applyNvrState, ensureKindBindings, pushDeviceStates, announceDeviceTransitions
local pushSbosRoster, fireGatewayEvent, registerGatewayEvents, handleWebhookRequest, forwardIdentityEvent

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
  -- Capability flags, straight from the API's own metadata (never model-name
  -- matching): flat comma-joined strings because they ride binding params.
  local flags = type(item.featureFlags) == "table" and item.featureFlags or {}
  local caps = {}
  if flags.hasMic then
    table.insert(caps, "mic")
  end
  if flags.hasSpeaker then
    table.insert(caps, "speaker")
  end
  if flags.hasLedStatus then
    table.insert(caps, "led")
  end
  if flags.hasHdr then
    table.insert(caps, "hdr")
  end
  if item.lcdMessage ~= nil then
    table.insert(caps, "lcd")
  end
  local function joined(list)
    return type(list) == "table" and table.concat(list, ",") or ""
  end
  return {
    id = tostring(item.id or ""),
    name = tostring(item.name or "Camera"),
    mac = tostring(item.mac or ""),
    state = tostring(item.state or "UNKNOWN"),
    caps = table.concat(caps, ","),
    detects = joined(flags.smartDetectTypes),
    audio_detects = joined(flags.smartDetectAudioTypes),
    video_modes = joined(flags.videoModes),
  }
end

local function summarizeDevice(item)
  return {
    id = tostring(item.id or ""),
    name = tostring(item.name or ""),
    mac = tostring(item.mac or ""),
    state = tostring(item.state or "UNKNOWN"),
  }
end

--- Sensor extras: readings ride as strings; absent hardware reads as absent
--- keys, never as zeroes.
local function summarizeSensor(item)
  local s = summarizeDevice(item)
  s.mount = tostring(item.mountType or "none")
  local battery = Select(item, "batteryStatus", "percentage")
  if battery ~= nil then
    s.battery = tostring(battery)
  end
  local temperature = Select(item, "stats", "temperature", "value")
  if temperature ~= nil then
    s.temperature = tostring(temperature)
  end
  local humidity = Select(item, "stats", "humidity", "value")
  if humidity ~= nil then
    s.humidity = tostring(humidity)
  end
  local light = Select(item, "stats", "light", "value")
  if light ~= nil then
    s.light = tostring(light)
  end
  if item.isOpened ~= nil then
    s.opened = item.isOpened and "true" or "false"
  end
  if item.isMotionDetected ~= nil then
    s.motion = item.isMotionDetected and "true" or "false"
  end
  return s
end

local function summarizeLight(item)
  local s = summarizeDevice(item)
  s.on = (item.isLightForceEnabled == true) and "true" or "false"
  s.mode = tostring(Select(item, "lightModeSettings", "mode") or "")
  return s
end

local function summarizeViewer(item)
  local s = summarizeDevice(item)
  s.liveview = tostring(item.liveview or "")
  return s
end

local function summarizeLiveview(item)
  return {
    id = tostring(item.id or ""),
    name = tostring(item.name or ""),
  }
end

local function summarizeArmProfile(item)
  return {
    id = tostring(item.id or ""),
    name = tostring(item.name or ""),
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
  local previous = gInventory
  gInventory = inventory

  UpdateProperty("Cameras", countLabel(inventory.cameras))
  UpdateProperty("Lights", countLabel(inventory.lights))
  UpdateProperty("Sensors", countLabel(inventory.sensors))
  UpdateProperty("Chimes", countLabel(inventory.chimes))
  UpdateProperty("Viewers", countLabel(inventory.viewers))
  UpdateProperty("Last Sync", inventory.updated_at)

  ensureCameraBindings(inventory.cameras)
  ensureKindBindings(inventory)
  pushCameraStates(inventory.cameras)
  pushDeviceStates(inventory)
  announceDeviceTransitions(previous, inventory)
  pushSbosRoster(inventory)

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
  -- `optional` steps are v7-era resources: on an older Protect they 404, and
  -- a missing siren list must not take down the camera sync. They land as
  -- empty lists and the feature reports itself unsupported instead.
  local steps = {
    { key = "cameras", fetch = "getCameras", summarize = summarizeCamera },
    { key = "lights", fetch = "getLights", summarize = summarizeLight },
    { key = "sensors", fetch = "getSensors", summarize = summarizeSensor },
    { key = "chimes", fetch = "getChimes", summarize = summarizeDevice },
    { key = "viewers", fetch = "getViewers", summarize = summarizeViewer, optional = true },
    { key = "liveviews", fetch = "getLiveviews", summarize = summarizeLiveview, optional = true },
    { key = "sirens", fetch = "getSirens", summarize = summarizeDevice, optional = true },
    { key = "relays", fetch = "getRelays", summarize = summarizeDevice, optional = true },
    { key = "hubs", fetch = "getAlarmHubs", summarize = summarizeDevice, optional = true },
    { key = "arm_profiles", fetch = "getArmProfiles", summarize = summarizeArmProfile, optional = true },
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
        if s.optional then
          inventory[s.key] = {}
          step(i + 1)
          return
        end
        fail({ code = res.code })
        return
      end
      local summarized = {}
      for _, item in ipairs(list) do
        table.insert(summarized, s.summarize(item))
      end
      inventory[s.key] = summarized
      step(i + 1)
    end, function(err)
      if s.optional then
        -- Unsupported by this Protect version: an empty list plus a debug
        -- line, never a failed sync (C2 graceful degradation).
        log:debug("Optional resource '%s' unavailable: %s", s.key, describeFailure(err))
        inventory[s.key] = {}
        step(i + 1)
        return
      end
      fail(err)
    end)
  end

  step(1)

  -- The alarm/breach state rides on the NVR object; refreshed on every sync
  -- so ARMED/DISARMED/BREACH events track the poll cadence even when the
  -- websocket is down. Fire-and-forget: alarm state must not gate the sync.
  protect:getNvr():next(function(res)
    local nvr = Protect.decodeBody(res.body)
    if type(nvr) == "table" then
      applyNvrState(nvr)
    end
  end, function() end)
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

  registerGatewayEvents()

  -- Inbound webhooks need a shared secret; mint one on first start so the
  -- feature works out of the box without the dealer inventing entropy.
  if tostring(Properties["Webhook Token"] or "") == "" then
    math.randomseed(os.time() + (tonumber(C4:GetDeviceID()) or 0))
    local token = {}
    for _ = 1, 24 do
      table.insert(token, string.format("%x", math.random(0, 15)))
    end
    UpdateProperty("Webhook Token", table.concat(token))
  end

  gInitialized = true
  UpdateProperty("Driver Status", "Online")
  -- The build actually running, said by the code itself. Instances have now
  -- twice been discovered running a stale cached driver while the Drivers
  -- folder held a newer build; this property ends the guessing.
  pcall(function()
    UpdateProperty("Driver Version", tostring(C4:GetDriverConfigInfo("version")))
  end)

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
    startSnapshotRelay()
  else
    setConnected(false, "Not configured - set the Console Address and API Key")
  end
end

function OnDriverDestroyed()
  CancelTimer(POLL_TIMER)
  stopEventsSocket()
  stopSnapshotRelay()
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

function OPC.Snapshot_Relay(propertyValue)
  log:trace("OPC.Snapshot_Relay('%s')", propertyValue)
  if gInitialized then
    startSnapshotRelay()
  end
end

function OPC.Relay_Port(propertyValue)
  log:trace("OPC.Relay_Port('%s')", propertyValue)
  if gInitialized then
    startSnapshotRelay()
  end
end

function OPC.Relay_Address(propertyValue)
  log:trace("OPC.Relay_Address('%s')", propertyValue)
  if gInitialized then
    -- Re-render the status line and let the next state push re-publish
    -- corrected snapshot URLs to every bound camera.
    startSnapshotRelay()
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
  stopSnapshotRelay()
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

--- The child driver DEVICE bound to a camera binding, or nil.
--- @param bindingId number The camera binding.
--- @return number|nil childDeviceId
local function boundConsumerForBinding(bindingId)
  local ok, consumers = pcall(function()
    return C4:GetBoundConsumerDevices(C4:GetDeviceID(), bindingId)
  end)
  if not ok or type(consumers) ~= "table" then
    return nil
  end
  for deviceId in pairs(consumers) do
    return tonumber(deviceId)
  end
  return nil
end

--- The camera a child DEVICE is bound to, walked through the bindings table.
--- This is the SendToDevice-path twin of cameraForBinding.
--- @param childDeviceId number The child driver's device id.
--- @return table|nil camera
local function cameraForChildDevice(childDeviceId)
  for key, binding in pairs(bindings:getDynamicBindings(CAMERA_BINDING_NS)) do
    if boundConsumerForBinding(binding.bindingId) == childDeviceId then
      for _, cam in ipairs((gInventory or {}).cameras or {}) do
        if cam.id == key then
          return cam
        end
      end
      return { id = key, name = binding.displayName, mac = "", state = "UNKNOWN" }
    end
  end
  return nil
end

--- Sends to the child behind a camera binding, preferring the DEVICE path.
---
--- SendToDevice → ExecuteCommand is the transport the field-tested reference
--- pair uses and the one measured to work; SendToProxy over a bound CONTROL
--- binding is the documented-but-unproven one. One preferred path, not both,
--- so an event never fires twice on a child that hears both.
--- @param binding Binding The camera binding.
--- @param command string
--- @param params table
local function sendToCamera(binding, command, params)
  local child = boundConsumerForBinding(binding.bindingId)
  if child ~= nil then
    SendToDevice(child, command, params)
  else
    SendToProxy(binding.bindingId, command, params)
  end
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
      sendToCamera(binding, "PROTECT_STATE", {
        id = cam.id,
        name = cam.name,
        state = cam.state,
        snapshot_url = relaySnapshotUrl(cam.id),
      })
    end
  end
end

--- The identity payload for one camera.
local function cameraReplyParams(cam)
  return {
    id = cam.id,
    name = cam.name,
    mac = cam.mac,
    state = cam.state,
    console_host = consoleHost(),
    snapshot_url = relaySnapshotUrl(cam.id),
  }
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
  SendToProxy(idBinding, "PROTECT_CAMERA", cameraReplyParams(cam))
end

--- The SendToDevice twin: a child asking over the device path, carrying its
--- own device id as `requester`. The answer goes back the way it came.
function EC.PROTECT_GET_CAMERA(tParams)
  local requester = tonumber((tParams or {}).requester)
  if requester == nil then
    return
  end
  local cam = cameraForChildDevice(requester)
  if cam == nil then
    log:warn(
      "Device %s asked for its camera identity but is not bound to any camera connection - bind it in Connections",
      requester
    )
    return
  end
  log:info("Camera identity requested by device %s; answering '%s' (%s)", requester, cam.name, cam.id)
  SendToDevice(requester, "PROTECT_CAMERA", cameraReplyParams(cam))
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

--- Stream URLs for a camera: read what exists, enable what is missing,
--- answer with the union — transport-agnostic core shared by both request
--- paths.
---
--- GET first because it is idempotent and free; POST only for qualities the
--- GET came back without, so a camera whose streams are already enabled is
--- never churned. `package` is not requested — it is the doorbell package
--- lens, a special view no Navigator tile asks for by default.
--- @param cam table|nil The camera, or nil when the requester maps to none.
--- @param key string The requester's correlation key, echoed untouched.
--- @param send fun(command: string, params: table) How to reach the requester.
local function answerStreams(cam, key, send)
  if cam == nil then
    send("PROTECT_STREAMS_ERROR", { KEY = key, reason = "not bound to any camera" })
    return
  end
  if not isConfigured() then
    send("PROTECT_STREAMS_ERROR", { KEY = key, reason = "gateway not configured" })
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
      send("PROTECT_STREAMS_ERROR", { KEY = key, reason = "console returned no stream URLs" })
      return
    end
    send("PROTECT_STREAMS", params)
  end

  local function fail(err)
    send("PROTECT_STREAMS_ERROR", { KEY = key, reason = describeFailure(err) })
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

function RFP.PROTECT_GET_STREAMS(idBinding, _, tParams)
  log:trace("RFP.PROTECT_GET_STREAMS(%s)", idBinding)
  local key = tostring((tParams or {}).KEY or "")
  answerStreams(cameraForBinding(idBinding), key, function(command, params)
    SendToProxy(idBinding, command, params)
  end)
end

--- The SendToDevice twin, keyed by the requester's device id.
function EC.PROTECT_GET_STREAMS(tParams)
  local requester = tonumber((tParams or {}).requester)
  if requester == nil then
    return
  end
  local key = tostring((tParams or {}).KEY or "")
  log:trace("EC.PROTECT_GET_STREAMS from device %s", requester)
  answerStreams(cameraForChildDevice(requester), key, function(command, params)
    SendToDevice(requester, command, params)
  end)
end

-- ─── Live events ──────────────────────────────────────────────────────────────
--
-- The console's event stream: wss://<console>/proxy/protect/integration/v1/
-- subscribe/events, authenticated with the same X-API-KEY header, delivering
-- plain JSON text frames of the shape { type = "add"|"update", item = {...} }.
-- Camera events are normalized and forwarded to the bound child over its
-- binding; events for devices with no bound child are dropped here — the
-- child asks for nothing on connect, so there is no queue to overflow.

--- Where every Protect event type goes. Three targets:
---   a binding NAMESPACE (cameras/sensors/lights) — normalized and forwarded
---   to the bound child as PROTECT_EVENT;
---   "gateway" — fired as this driver's own Composer event (alarm-hub
---   family: no child driver carries a hub);
---   "identity" — fingerprint/NFC events resolved against the ulp-users
---   store, then forwarded to the camera child as a known/unknown person.
--- Unlisted types are logged at debug and dropped — the EVENT_MATRIX doc is
--- the authority on what falls where.
--- @type table<string, table>
local EVENT_ROUTES = {
  motion = { ns = "cameras", kind = "motion" },
  ring = { ns = "cameras", kind = "ring" },
  smartDetectZone = { ns = "cameras", kind = "smart" },
  smartDetectLine = { ns = "cameras", kind = "line" },
  smartDetectLoiterZone = { ns = "cameras", kind = "loiter" },
  smartAudioDetect = { ns = "cameras", kind = "audio" },
  fingerprintIdentified = { identity = "fingerprint" },
  nfcCardScanned = { identity = "nfc" },
  sensorMotion = { ns = "sensors", kind = "motion" },
  sensorOpened = { ns = "sensors", kind = "opened" },
  sensorClosed = { ns = "sensors", kind = "closed" },
  sensorAlarm = { ns = "sensors", kind = "alarm" },
  sensorExtremeValues = { ns = "sensors", kind = "extreme" },
  sensorBatteryLow = { ns = "sensors", kind = "battery" },
  sensorSmokeBatteryLow = { ns = "sensors", kind = "battery" },
  sensorWaterLeak = { ns = "sensors", kind = "leak" },
  sensorTamper = { ns = "sensors", kind = "tamper" },
  sensorButtonPressed = { ns = "sensors", kind = "button" },
  sensorCoFault = { ns = "sensors", kind = "cofault" },
  sensorSmokeTest = { ns = "sensors", kind = "smoketest" },
  lightMotion = { ns = "lights", kind = "motion" },
  alarmHubEntryOpened = { gateway = "Entry Opened" },
  alarmHubEntryClosed = { gateway = "Entry Closed" },
  alarmHubGlassBreak = { gateway = "Glass Break Detected" },
  alarmHubSmoke = { gateway = "Smoke Alarm Detected" },
  alarmHubMotion = { gateway = "Hub Motion Detected" },
  alarmHubTamper = { gateway = "Hub Tamper Detected" },
  alarmHubDeviceTamper = { gateway = "Hub Tamper Detected" },
  alarmHubButtonPress = { gateway = "Hub Button Pressed" },
  alarmHubBatteryLow = { gateway = "Hub Battery Low" },
  alarmHubRelaySwitched = { gateway = "Hub Relay Switched" },
}

--- Finds the binding for a device id in one namespace, or nil.
local function bindingFor(ns, deviceId)
  return bindings:getDynamicBinding(ns, deviceId)
end

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
  gLastEventAt = os.date("%Y-%m-%d %H:%M:%S")
  UpdateProperty("Last Event", string.format("%s at %s", tostring(item.type), gLastEventAt))

  local route = EVENT_ROUTES[tostring(item.type or "")]
  if route == nil then
    log:debug("Unrouted event type '%s' (see EVENT_MATRIX)", tostring(item.type))
    return
  end

  -- The alarm-hub family fires as this driver's own Composer events.
  if route.gateway ~= nil then
    log:info("Alarm hub event: %s", route.gateway)
    fireGatewayEvent(route.gateway)
    return
  end

  -- Identity events resolve a name first, then land on the camera child.
  if route.identity ~= nil then
    forwardIdentityEvent(item, route.identity)
    return
  end

  local binding = bindingFor(route.ns, tostring(item.device or ""))
  if binding == nil then
    return
  end

  -- "end" is a Lua keyword, hence the bracket access. An add-frame has no end
  -- timestamp; the update-frame that closes the event carries one — that is
  -- the entire start/end distinction.
  local phase = item["end"] ~= nil and "end" or "start"

  local params = { kind = route.kind, phase = phase }
  if type(item.smartDetectTypes) == "table" and #item.smartDetectTypes > 0 then
    params.types = table.concat(item.smartDetectTypes, ",")
  end
  if item.start ~= nil then
    params.at = tostring(item.start)
  end
  -- Per-type detail rides in metadata where the console provides it: plate
  -- text (defensive — not yet in the published schema), sensor extreme
  -- values (sensorType/sensorValue), alarm classes.
  local plate = Select(item, "metadata", "licensePlate", "text")
  if type(plate) == "string" and plate ~= "" then
    params.value = plate
  end
  local sensorType = Select(item, "metadata", "sensorType", "text")
  if sensorType ~= nil then
    params.sensor_type = tostring(sensorType)
  end
  local sensorValue = Select(item, "metadata", "sensorValue", "text")
  if sensorValue ~= nil then
    params.sensor_value = tostring(sensorValue)
  end

  log:debug("Event %s/%s for %s -> binding %s", route.kind, phase, tostring(item.device), binding.bindingId)
  sendToCamera(binding, "PROTECT_EVENT", params)
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

-- ─── Snapshot relay ───────────────────────────────────────────────────────────
--
-- The one bridge that makes snapshots possible on the OFFICIAL API alone:
-- the console's snapshot endpoint demands the X-API-KEY header, and nothing
-- on the Navigator side can send a header. So this driver listens on a
-- controller port, fetches the JPEG from the console WITH the key, and
-- serves it plain on the LAN:
--
--     GET http://<controller>:<Relay Port>/snapshot/<cameraId>[?hq=1]
--
-- Camera thumbnails, push-notification stills and platform uploads all feed
-- off this one URL shape. Only ids with a camera binding behind them are
-- served — everything else is a 404 — and the relay exposes exactly what
-- Protect's own "anonymous snapshot" option would, scoped to the LAN.

--- Identifier passed to CreateServer so callbacks can tell this server from
--- any future listener this driver grows.
local SNAPSHOT_RELAY_ID = "protect-snapshot-relay"

--- The port the relay is actually listening on, or nil when stopped.
gRelayPort = nil

--- The relay host as published in snapshot URLs, or "" when unknown.
--- @return string host
local function relayHost()
  local configured = tostring(Properties["Relay Address"] or ""):gsub("%s+", "")
  if configured ~= "" and configured:lower() ~= "auto" then
    return configured
  end
  -- Auto: the controller's own LAN address, as Director reports it on a
  -- controller device's network binding. Best-effort — a project can be
  -- arranged in ways this cannot see, which is what the property override
  -- is for.
  local ok, devices = pcall(function()
    return C4:GetDevices({})
  end)
  if not ok or type(devices) ~= "table" then
    return ""
  end
  for rawId, device in pairs(devices) do
    local id = tonumber(rawId)
    local file = tostring((type(device) == "table" and device.driverFileName) or "")
    if id ~= nil and file:find("^control4_") ~= nil then
      local okB, raw = pcall(function()
        return C4:GetNetworkBindingsByDevice(id)
      end)
      if okB and type(raw) == "table" then
        for _, binding in ipairs(raw.networkbindings or {}) do
          local addr = tostring(binding.addr or "")
          if addr:match("^%d+%.%d+%.%d+%.%d+$") ~= nil and addr:find("^127%.") == nil then
            return addr
          end
        end
      end
    end
  end
  return ""
end

--- One snapshot URL, or nil when the relay cannot publish. (Assigns the
--- forward declaration.)
--- @param cameraId string
--- @param highQuality boolean|nil
--- @return string|nil url
relaySnapshotUrl = function(cameraId, highQuality)
  if gRelayPort == nil then
    return nil
  end
  local host = relayHost()
  if host == "" then
    return nil
  end
  return string.format("http://%s:%d/snapshot/%s%s", host, gRelayPort, cameraId, highQuality and "?hq=1" or "")
end

--- Answers one HTTP client and closes it. Always closes: the relay speaks
--- exactly one request per connection, which keeps the handle bookkeeping at
--- zero.
--- @param handle number The connection handle.
--- @param status string e.g. "200 OK".
--- @param contentType string
--- @param body string
local function relayRespond(handle, status, contentType, body)
  body = body or ""
  local response = table.concat({
    "HTTP/1.1 " .. status,
    "Content-Type: " .. contentType,
    "Content-Length: " .. #body,
    "Cache-Control: no-store",
    "Connection: close",
    "",
    body,
  }, "\r\n")
  pcall(function()
    C4:ServerSend(handle, response)
  end)
  pcall(function()
    C4:ServerCloseClient(handle)
  end)
end

--- One HTTP request off the wire. Deliberately minimal: GET, one known path
--- shape, everything else refused. A browser poking the port gets honest
--- 404s, not surprises.
--- @param handle number The connection handle.
--- @param data string The raw request bytes.
local function handleRelayRequest(handle, data)
  local method, path = tostring(data or ""):match("^(%u+)%s+(%S+)")
  if method == nil then
    relayRespond(handle, "400 Bad Request", "text/plain", "bad request")
    return
  end
  -- Webhooks accept GET and POST — Protect's Alarm Manager sends POST.
  local webhookName, webhookQuery = path:match("^/webhook/([%w%-%_]+)%??(.*)$")
  if webhookName ~= nil then
    handleWebhookRequest(handle, webhookName, webhookQuery, data)
    return
  end
  if method ~= "GET" then
    relayRespond(handle, "405 Method Not Allowed", "text/plain", "GET only")
    return
  end
  local cameraId, query = path:match("^/snapshot/([%w%-]+)%??(.*)$")
  if cameraId == nil then
    relayRespond(handle, "404 Not Found", "text/plain", "not found")
    return
  end
  -- Serve only ids this driver has a camera binding for. The binding table
  -- is persisted, so the relay answers correctly even before the first poll
  -- after a restart.
  if bindings:getDynamicBinding(CAMERA_BINDING_NS, cameraId) == nil then
    relayRespond(handle, "404 Not Found", "text/plain", "unknown camera")
    return
  end
  if not isConfigured() then
    relayRespond(handle, "503 Service Unavailable", "text/plain", "gateway not configured")
    return
  end
  configureClient()
  local highQuality = query:find("hq=1", 1, true) ~= nil or query:find("hq=true", 1, true) ~= nil
  protect:getSnapshot(cameraId, highQuality):next(function(res)
    if type(res.body) ~= "string" or res.body == "" then
      relayRespond(handle, "502 Bad Gateway", "text/plain", "console returned no image")
      return
    end
    relayRespond(handle, "200 OK", "image/jpeg", res.body)
  end, function(err)
    relayRespond(handle, "502 Bad Gateway", "text/plain", describeFailure(err))
  end)
end

function OnServerDataIn(handle, data, _, _, identifier)
  if identifier ~= nil and identifier ~= SNAPSHOT_RELAY_ID then
    return
  end
  local ok, err = pcall(handleRelayRequest, handle, data)
  if not ok then
    log:warn("Snapshot relay request failed: %s", tostring(err))
    pcall(function()
      C4:ServerCloseClient(handle)
    end)
  end
end

--- Starts (or restarts) the relay per the properties. (Assigns the forward
--- declaration.)
startSnapshotRelay = function()
  stopSnapshotRelay()
  if Properties["Snapshot Relay"] ~= "On" then
    UpdateProperty("Relay Status", "Off")
    return
  end
  local port = tonumber(Properties["Relay Port"]) or 47800
  local ok = pcall(function()
    C4:CreateServer(port, "", false, SNAPSHOT_RELAY_ID)
  end)
  if not ok then
    UpdateProperty("Relay Status", "Failed to listen on port " .. port)
    log:error("Snapshot relay could not listen on port %s", port)
    return
  end
  gRelayPort = port
  local host = relayHost()
  if host ~= "" then
    UpdateProperty("Relay Status", string.format("Serving http://%s:%d/snapshot/<camera>", host, port))
  else
    -- Listening, but URLs cannot be published without a host the LAN can
    -- reach. Said plainly, with the fix in the sentence.
    UpdateProperty(
      "Relay Status",
      string.format("Listening on port %d - set Relay Address to the controller's IP", port)
    )
  end
end

--- Stops the relay. (Assigns the forward declaration.)
stopSnapshotRelay = function()
  if gRelayPort ~= nil then
    local port = gRelayPort
    gRelayPort = nil
    pcall(function()
      C4:DestroyServer(port)
    end)
  end
  UpdateProperty("Relay Status", "Off")
end

-- ─── Kinds, bindings and state fan-out beyond cameras ─────────────────────────

--- Binding namespace + class per child-driver kind. Cameras predate this
--- table and keep their own constants; these three are the new children.
local KIND_BINDINGS = {
  sensors = { ns = "sensors", class = "UNIFI_PROTECT_SENSOR" },
  lights = { ns = "lights", class = "UNIFI_PROTECT_LIGHT" },
  viewers = { ns = "viewers", class = "UNIFI_PROTECT_VIEWER" },
}

--- Ensures provider bindings for sensors, lights and viewers — same
--- create-only policy as cameras: never auto-deleted. (Assigns fwd decl.)
ensureKindBindings = function(inventory)
  for key, spec in pairs(KIND_BINDINGS) do
    for _, device in ipairs(inventory[key] or {}) do
      if device.id ~= "" then
        bindings:getOrAddDynamicBinding(spec.ns, device.id, "CONTROL", true, device.name, spec.class)
      end
    end
  end
end

--- Extra state params per kind, beyond id/name/state.
local function deviceStateParams(key, device)
  local params = { id = device.id, name = device.name, state = device.state }
  if key == "sensors" then
    params.mount = device.mount
    params.battery = device.battery
    params.temperature = device.temperature
    params.humidity = device.humidity
    params.light = device.light
    params.opened = device.opened
    params.motion = device.motion
  elseif key == "lights" then
    params.on = device.on
    params.mode = device.mode
  elseif key == "viewers" then
    params.liveview = device.liveview
    local names = {}
    for _, lv in ipairs((gInventory or {}).liveviews or {}) do
      table.insert(names, lv.id .. "=" .. lv.name)
    end
    params.liveviews = table.concat(names, ";")
  end
  return params
end

--- Pushes state to sensor/light/viewer children on every sync. (Assigns
--- fwd decl.) Cameras keep their own richer push.
pushDeviceStates = function(inventory)
  for key, spec in pairs(KIND_BINDINGS) do
    local byId = {}
    for _, device in ipairs(inventory[key] or {}) do
      byId[device.id] = device
    end
    for id, binding in pairs(bindings:getDynamicBindings(spec.ns)) do
      local device = byId[id]
      if device ~= nil then
        sendToCamera(binding, "PROTECT_STATE", deviceStateParams(key, device))
      end
    end
  end
end

--- Fires DEVICE OFFLINE/ONLINE on real transitions across every kind, and
--- keeps the Offline Devices property/variable honest. (Assigns fwd decl.)
announceDeviceTransitions = function(previous, inventory)
  local offline = {}
  local prevStates = {}
  for _, key in ipairs({ "cameras", "lights", "sensors", "chimes", "viewers", "sirens", "relays", "hubs" }) do
    for _, device in ipairs((previous or {})[key] or {}) do
      prevStates[device.id] = device.state
    end
  end
  for _, key in ipairs({ "cameras", "lights", "sensors", "chimes", "viewers", "sirens", "relays", "hubs" }) do
    for _, device in ipairs(inventory[key] or {}) do
      if device.state ~= "CONNECTED" then
        table.insert(offline, device.name)
      end
      local before = prevStates[device.id]
      -- Transitions only, and only from a KNOWN before-state: the first sync
      -- after a restart is learning, not news.
      if before ~= nil and before ~= device.state then
        if device.state == "DISCONNECTED" then
          log:warn("Device offline: %s", device.name)
          fireGatewayEvent("Device Offline")
        elseif device.state == "CONNECTED" and before == "DISCONNECTED" then
          log:info("Device back online: %s", device.name)
          fireGatewayEvent("Device Online")
        end
      end
    end
  end
  local label = #offline == 0 and "None" or table.concat(offline, ", ")
  UpdateProperty("Offline Devices", label)
  pcall(function()
    C4:SetVariable("OFFLINE_DEVICES", tostring(#offline))
  end)
end

-- ─── Gateway Composer events + variables ──────────────────────────────────────

--- Event ids match driver.xml <events>; re-registered at init because an
--- update-in-place never registers XML events on existing instances.
local GATEWAY_EVENTS = {
  { 1, "Armed", "Protect armed (any profile)." },
  { 2, "Disarmed", "Protect disarmed." },
  { 3, "Arm Profile Changed", "The active Protect arm profile changed." },
  { 4, "Breach Detected", "Protect detected an alarm breach." },
  { 5, "Siren Started", "A Protect siren started sounding." },
  { 6, "Siren Stopped", "A Protect siren stopped." },
  { 7, "NVR Offline", "The Protect console stopped answering." },
  { 8, "NVR Online", "The Protect console is answering again." },
  { 9, "Device Offline", "A Protect device went offline." },
  { 10, "Device Online", "A Protect device came back online." },
  { 11, "Custom Webhook Received", "A webhook arrived from Protect's Alarm Manager." },
  { 12, "Entry Opened", "An alarm hub entry opened." },
  { 13, "Entry Closed", "An alarm hub entry closed." },
  { 14, "Glass Break Detected", "An alarm hub detected glass breaking." },
  { 15, "Smoke Alarm Detected", "An alarm hub detected a smoke alarm." },
  { 16, "Hub Motion Detected", "An alarm hub detected motion." },
  { 17, "Hub Tamper Detected", "An alarm hub or its device was tampered with." },
  { 18, "Hub Button Pressed", "An alarm hub button was pressed." },
  { 19, "Hub Battery Low", "An alarm hub battery is low." },
  { 20, "Hub Relay Switched", "An alarm hub relay switched." },
}

local GATEWAY_VARIABLES = {
  { "ARM_MODE", "", "STRING" },
  { "ARM_PROFILE", "", "STRING" },
  { "OFFLINE_DEVICES", "0", "NUMBER" },
  { "LAST_WEBHOOK_NAME", "", "STRING" },
  { "LAST_WEBHOOK_TIME", "", "STRING" },
}

--- (Assigns fwd decl.)
registerGatewayEvents = function()
  for _, e in ipairs(GATEWAY_EVENTS) do
    pcall(function()
      C4:AddEvent(e[1], e[2], e[3])
    end)
  end
  for _, v in ipairs(GATEWAY_VARIABLES) do
    pcall(function()
      C4:AddVariable(v[1], v[2], v[3], true)
    end)
  end
end

--- (Assigns fwd decl.)
fireGatewayEvent = function(name)
  pcall(function()
    C4:FireEvent(name)
  end)
end

-- ─── Alarm state (armMode / breach off the NVR object) ────────────────────────

--- The active profile's display name, from the synced profile list.
local function armProfileName(profileId)
  for _, profile in ipairs((gInventory or {}).arm_profiles or {}) do
    if profile.id == profileId then
      return profile.name
    end
  end
  return tostring(profileId or "")
end

--- Resolves a dealer-typed profile (name, case-insensitive, or raw id).
local function armProfileByNameOrId(value)
  value = tostring(value or "")
  if value == "" then
    return nil
  end
  local lowered = value:lower()
  for _, profile in ipairs((gInventory or {}).arm_profiles or {}) do
    if profile.id == value or profile.name:lower() == lowered then
      return profile
    end
  end
  return nil
end

--- Applies the NVR's alarm fields, firing events on TRANSITIONS only.
--- (Assigns fwd decl.)
applyNvrState = function(nvr)
  local mode = tostring(nvr.armMode or "")
  local profileId = tostring(nvr.armProfileId or "")
  local breachAt = nvr.breachDetectedAt

  if mode ~= "" then
    UpdateProperty("Arm Mode", mode)
    pcall(function()
      C4:SetVariable("ARM_MODE", mode)
    end)
  end
  local profileLabel = profileId ~= "" and armProfileName(profileId) or "-"
  UpdateProperty("Arm Profile", profileLabel)
  pcall(function()
    C4:SetVariable("ARM_PROFILE", profileLabel)
  end)

  local before = gAlarm
  -- An absent field is UNKNOWN, not a state: never record "" as something a
  -- later real value would "transition" from.
  gAlarm = {
    armMode = mode ~= "" and mode or before.armMode,
    armProfileId = profileId ~= "" and profileId or before.armProfileId,
    breachDetectedAt = breachAt or before.breachDetectedAt,
  }

  if before.armMode ~= nil and before.armMode ~= "" and before.armMode ~= mode and mode ~= "" then
    -- armMode vocabulary is the console's; "disarmed"-shaped values read as
    -- disarmed, anything else as armed. Both events carry the raw mode in
    -- the ARM_MODE variable for programming that needs the exact word.
    local disarmedNow = mode:lower():find("disarm") ~= nil or mode:lower() == "off"
    if disarmedNow then
      log:info("Protect disarmed (mode %s)", mode)
      fireGatewayEvent("Disarmed")
    else
      log:info("Protect armed (mode %s)", mode)
      fireGatewayEvent("Armed")
    end
  end
  if
    before.armProfileId ~= nil
    and before.armProfileId ~= ""
    and before.armProfileId ~= profileId
    and profileId ~= ""
  then
    log:info("Arm profile changed to %s", profileLabel)
    fireGatewayEvent("Arm Profile Changed")
  end
  if breachAt ~= nil and breachAt ~= before.breachDetectedAt then
    log:warn("BREACH detected by Protect (at %s)", tostring(breachAt))
    fireGatewayEvent("Breach Detected")
  end
end

--- One-shot security command runner: executes EXACTLY once and reports.
--- A timeout is reported as unknown-outcome, never retried — a lost
--- response is not a lost command (see the client's security note).
local function runSecurityCommand(label, deferred)
  deferred:next(function()
    log:print("%s: done", label)
  end, function(err)
    log:warn("%s: %s (NOT retried - verify in Protect before repeating)", label, describeFailure(err))
  end)
end

function EC.ARM_WITH_PROFILE(tParams)
  local wanted = tostring((tParams or {}).Profile or (tParams or {}).profile or "")
  if not isConfigured() then
    return
  end
  configureClient()
  if wanted ~= "" then
    local profile = armProfileByNameOrId(wanted)
    if profile == nil then
      log:warn("Arm With Profile: no profile named '%s' - run Print Arm Profiles", wanted)
      return
    end
    protect:setArmProfile(profile.id):next(function()
      runSecurityCommand("Arm (" .. profile.name .. ")", protect:enableArm())
    end, function(err)
      log:warn("Selecting profile failed: %s", describeFailure(err))
    end)
    return
  end
  runSecurityCommand("Arm (current profile)", protect:enableArm())
end

function EC.DISARM(tParams)
  if not isConfigured() then
    return
  end
  configureClient()
  runSecurityCommand("Disarm", protect:disableArm())
end

function EC.SELECT_ARM_PROFILE(tParams)
  local profile = armProfileByNameOrId((tParams or {}).Profile or (tParams or {}).profile)
  if profile == nil then
    log:warn("Select Arm Profile: unknown profile - run Print Arm Profiles")
    return
  end
  configureClient()
  runSecurityCommand("Select profile " .. profile.name, protect:setArmProfile(profile.id))
end

function EC.PRINT_ARM_PROFILES()
  local profiles = (gInventory or {}).arm_profiles or {}
  if #profiles == 0 then
    log:print("No arm profiles known - is this Protect version 7+, and has a sync run?")
    return
  end
  for _, profile in ipairs(profiles) do
    log:print("  %s (%s)%s", profile.name, profile.id, profile.id == gAlarm.armProfileId and "  <- current" or "")
  end
end

-- ─── Sirens / relays / alarm-hub outputs ──────────────────────────────────────

local function securityDeviceByNameOrId(key, value)
  value = tostring(value or "")
  local lowered = value:lower()
  for _, device in ipairs((gInventory or {})[key] or {}) do
    if device.id == value or tostring(device.name):lower() == lowered then
      return device
    end
  end
  return nil
end

--- Snaps a requested siren duration onto the console's accepted steps.
local function snapSirenDuration(seconds)
  seconds = tonumber(seconds)
  if seconds == nil then
    return nil
  end
  local snapped = 5
  for _, step in ipairs({ 5, 10, 20, 30 }) do
    if seconds >= step then
      snapped = step
    end
  end
  return snapped
end

function EC.PLAY_SIREN(tParams)
  tParams = tParams or {}
  local siren = securityDeviceByNameOrId("sirens", tParams.Siren or tParams.siren)
  if siren == nil then
    log:warn("Play Siren: unknown siren - run Print Security Devices")
    return
  end
  configureClient()
  fireGatewayEvent("Siren Started")
  runSecurityCommand("Play siren " .. siren.name, protect:playSiren(siren.id, snapSirenDuration(tParams.Duration)))
end

function EC.STOP_SIREN(tParams)
  local siren = securityDeviceByNameOrId("sirens", (tParams or {}).Siren or (tParams or {}).siren)
  if siren == nil then
    log:warn("Stop Siren: unknown siren")
    return
  end
  configureClient()
  fireGatewayEvent("Siren Stopped")
  runSecurityCommand("Stop siren " .. siren.name, protect:stopSiren(siren.id))
end

function EC.TEST_SIREN(tParams)
  local siren = securityDeviceByNameOrId("sirens", (tParams or {}).Siren or (tParams or {}).siren)
  if siren == nil then
    log:warn("Test Siren: unknown siren")
    return
  end
  configureClient()
  runSecurityCommand("Test siren " .. siren.name, protect:testSiren(siren.id, tonumber((tParams or {}).Volume)))
end

function EC.ACTIVATE_RELAY(tParams)
  tParams = tParams or {}
  local relay = securityDeviceByNameOrId("relays", tParams.Relay or tParams.relay)
  if relay == nil then
    log:warn("Activate Relay: unknown relay - run Print Security Devices")
    return
  end
  local output = tostring(tParams.Output or tParams.output or "1")
  local state = tParams.State
  if state ~= "on" and state ~= "off" then
    state = nil -- console toggles
  end
  configureClient()
  runSecurityCommand(
    "Relay " .. relay.name .. " output " .. output,
    protect:activateRelayOutput(relay.id, output, state, tonumber(tParams.PulseMs))
  )
end

function EC.TRIGGER_HUB_OUTPUT(tParams)
  tParams = tParams or {}
  local hub = securityDeviceByNameOrId("hubs", tParams.Hub or tParams.hub)
  if hub == nil then
    log:warn("Trigger Hub Output: unknown alarm hub - run Print Security Devices")
    return
  end
  local output = tostring(tParams.Output or tParams.output or "1")
  local enable = nil
  if tParams.Enable == "true" or tParams.Enable == "on" then
    enable = true
  elseif tParams.Enable == "false" or tParams.Enable == "off" then
    enable = false
  end
  configureClient()
  runSecurityCommand(
    "Hub " .. hub.name .. " output " .. output,
    protect:triggerAlarmHubOutput(hub.id, output, enable, nil, tonumber(tParams.DurationMs))
  )
end

function EC.PRINT_SECURITY_DEVICES()
  for _, key in ipairs({ "sirens", "relays", "hubs" }) do
    local list = (gInventory or {})[key] or {}
    log:print("%s (%d):", key, #list)
    for _, device in ipairs(list) do
      log:print("  %s [%s] %s", device.name, device.state, device.id)
    end
  end
end

function EC.TRIGGER_PROTECT_WEBHOOK(tParams)
  local triggerId = tostring((tParams or {}).TriggerId or (tParams or {}).trigger_id or "")
  if triggerId == "" then
    log:warn("Trigger Protect Webhook: TriggerId required (from Protect's Alarm Manager)")
    return
  end
  configureClient()
  runSecurityCommand("Protect webhook " .. triggerId, protect:triggerAlarmWebhook(triggerId))
end

-- ─── Identity (fingerprint / NFC → known person) ──────────────────────────────

--- Resolves a ulp user id to a display name via a lazily-refreshed cache.
--- (Assigns fwd decl... no — local helper.)
local function ulpUserById(ulpId, onDone)
  if gUlpUsers ~= nil and os.time() - gUlpUsersFetchedAt < 600 then
    onDone(gUlpUsers[ulpId])
    return
  end
  protect:getUlpUsers():next(function(res)
    local list = Protect.decodeBody(res.body) or {}
    gUlpUsers = {}
    for _, user in ipairs(list) do
      gUlpUsers[tostring(user.id or "")] = {
        name = tostring(user.fullName or user.firstName or ""),
        active = tostring(user.status or "") == "ACTIVE",
      }
    end
    gUlpUsersFetchedAt = os.time()
    onDone(gUlpUsers[ulpId])
  end, function()
    onDone(nil)
  end)
end

--- A fingerprint/NFC event: resolve who, then tell the doorbell's camera
--- child. (Assigns fwd decl.)
forwardIdentityEvent = function(item, method)
  local binding = bindings:getDynamicBinding(CAMERA_BINDING_NS, tostring(item.device or ""))
  if binding == nil then
    return
  end
  local ulpId = tostring(Select(item, "metadata", "ulpUserId") or Select(item, "metadata", "userId") or "")
  ulpUserById(ulpId, function(user)
    local known = user ~= nil and user.active and user.name ~= ""
    sendToCamera(binding, "PROTECT_EVENT", {
      kind = "identity",
      method = method,
      known = known and "true" or "false",
      value = known and user.name or "",
      at = tostring(item.start or ""),
    })
  end)
end

-- ─── Inbound webhooks (Protect Alarm Manager → Control4) ──────────────────────

--- (Assigns fwd decl.) Token required, wrong/missing token indistinguishable
--- from a missing route; per-name flood guard; oversized payloads refused.
handleWebhookRequest = function(handle, name, query, rawRequest)
  local token = tostring(Properties["Webhook Token"] or "")
  if token == "" or query:find("token=" .. token, 1, true) == nil then
    relayRespond(handle, "404 Not Found", "text/plain", "not found")
    return
  end
  if #tostring(rawRequest or "") > 8192 then
    relayRespond(handle, "413 Payload Too Large", "text/plain", "too large")
    return
  end
  local now = os.time()
  if gWebhookLast[name] ~= nil and now - gWebhookLast[name] < 2 then
    relayRespond(handle, "200 OK", "text/plain", "cooldown")
    return
  end
  gWebhookLast[name] = now
  log:info("Custom webhook received: %s", name)
  pcall(function()
    C4:SetVariable("LAST_WEBHOOK_NAME", name)
    C4:SetVariable("LAST_WEBHOOK_TIME", os.date("%Y-%m-%d %H:%M:%S"))
  end)
  fireGatewayEvent("Custom Webhook Received")
  relayRespond(handle, "200 OK", "text/plain", "ok")
end

-- ─── PROTECT_GET_DEVICE / PROTECT_CONTROL (children beyond cameras) ───────────

--- The device (and its kind) behind a binding id, across every namespace.
local function findBindingDevice(idBinding)
  for key, spec in pairs(KIND_BINDINGS) do
    for id, binding in pairs(bindings:getDynamicBindings(spec.ns)) do
      if binding.bindingId == idBinding then
        for _, device in ipairs((gInventory or {})[key] or {}) do
          if device.id == id then
            return key, device
          end
        end
        return key, { id = id, name = binding.displayName, state = "UNKNOWN" }
      end
    end
  end
  local cam = cameraForBinding(idBinding)
  if cam ~= nil then
    return "cameras", cam
  end
  return nil, nil
end

--- The device behind a bound CHILD DEVICE id, across every namespace.
local function findChildDevice(childDeviceId)
  for key, spec in pairs(KIND_BINDINGS) do
    for id, binding in pairs(bindings:getDynamicBindings(spec.ns)) do
      if boundConsumerForBinding(binding.bindingId) == childDeviceId then
        for _, device in ipairs((gInventory or {})[key] or {}) do
          if device.id == id then
            return key, device
          end
        end
        return key, { id = id, name = binding.displayName, state = "UNKNOWN" }
      end
    end
  end
  local cam = cameraForChildDevice(childDeviceId)
  if cam ~= nil then
    return "cameras", cam
  end
  return nil, nil
end

local function deviceReplyParams(key, device)
  local params
  if key == "cameras" then
    params = cameraReplyParams(device)
  else
    params = deviceStateParams(key, device)
  end
  params.kind = key
  return params
end

function RFP.PROTECT_GET_DEVICE(idBinding)
  local key, device = findBindingDevice(idBinding)
  if key == nil then
    log:warn("PROTECT_GET_DEVICE on binding %s, which maps to no device", tostring(idBinding))
    return
  end
  log:info("Device identity requested on binding %s; answering '%s' (%s)", idBinding, device.name, key)
  SendToProxy(idBinding, "PROTECT_DEVICE", deviceReplyParams(key, device))
end

function EC.PROTECT_GET_DEVICE(tParams)
  local requester = tonumber((tParams or {}).requester)
  if requester == nil then
    return
  end
  local key, device = findChildDevice(requester)
  if key == nil then
    log:warn("Device %s asked for identity but is not bound to any Protect connection", requester)
    return
  end
  SendToDevice(requester, "PROTECT_DEVICE", deviceReplyParams(key, device))
end

--- Every control a child can ask for, by op name. One client call each; the
--- security rule (no retry) is structural — nothing here loops.
local CONTROL_OPS = {
  lcd_message = function(id, p)
    local seconds = tonumber(p.duration_s)
    local resetAt = nil
    if seconds ~= nil and seconds > 0 then
      resetAt = (os.time() + seconds) * 1000
    end
    return protect:setLcdMessage(id, "CUSTOM_MESSAGE", tostring(p.text or ""), resetAt)
  end,
  lcd_dnd = function(id)
    return protect:setLcdMessage(id, "DO_NOT_DISTURB")
  end,
  lcd_leave_package = function(id)
    return protect:setLcdMessage(id, "LEAVE_PACKAGE_AT_DOOR")
  end,
  lcd_reset = function(id)
    return protect:resetLcdMessage(id)
  end,
  led = function(id, p)
    return protect:setCameraLed(id, p.on == "true")
  end,
  mic_volume = function(id, p)
    return protect:setMicVolume(id, tonumber(p.volume) or 50)
  end,
  hdr = function(id, p)
    return protect:setHdrType(id, tostring(p.mode or "auto"))
  end,
  video_mode = function(id, p)
    return protect:setVideoMode(id, tostring(p.mode or "default"))
  end,
  ptz_goto = function(id, p)
    return protect:gotoPtzPreset(id, tonumber(p.slot) or 0)
  end,
  ptz_patrol_start = function(id, p)
    return protect:startPtzPatrol(id, tonumber(p.slot) or 0)
  end,
  ptz_patrol_stop = function(id)
    return protect:stopPtzPatrol(id)
  end,
  light_force = function(id, p)
    return protect:setLightForce(id, p.on == "true")
  end,
  light_mode = function(id, p)
    return protect:setLightMode(id, tostring(p.mode or "motion"), p.enable_at)
  end,
  viewer_liveview = function(id, p)
    local wanted = tostring(p.liveview or "")
    for _, lv in ipairs((gInventory or {}).liveviews or {}) do
      if lv.id == wanted or lv.name:lower() == wanted:lower() then
        wanted = lv.id
        break
      end
    end
    return protect:setViewerLiveview(id, wanted)
  end,
}

local function executeControl(deviceId, tParams, reply)
  local opName = tostring((tParams or {}).op or "")
  local op = CONTROL_OPS[opName]
  if op == nil then
    reply({ op = opName, ok = "false", reason = "unknown op" })
    return
  end
  if not isConfigured() then
    reply({ op = opName, ok = "false", reason = "gateway not configured" })
    return
  end
  configureClient()
  op(deviceId, tParams or {}):next(function()
    reply({ op = opName, ok = "true" })
  end, function(err)
    reply({ op = opName, ok = "false", reason = describeFailure(err) })
  end)
end

function RFP.PROTECT_CONTROL(idBinding, _, tParams)
  local key, device = findBindingDevice(idBinding)
  if key == nil then
    return
  end
  executeControl(device.id, tParams, function(result)
    SendToProxy(idBinding, "PROTECT_CONTROL_RESULT", result)
  end)
end

function EC.PROTECT_CONTROL(tParams)
  local requester = tonumber((tParams or {}).requester)
  if requester == nil then
    return
  end
  local key, device = findChildDevice(requester)
  if key == nil then
    return
  end
  executeControl(device.id, tParams, function(result)
    SendToDevice(requester, "PROTECT_CONTROL_RESULT", result)
  end)
end

-- ─── SmartBuildOS roster handoff ──────────────────────────────────────────────

--- Hands the device roster to the SmartBuildOS Connector in this project —
--- the platform matches by MAC into the property's equipment registry.
--- Gated by a property (default Off) and change-driven: an unchanged roster
--- costs nothing. (Assigns fwd decl.)
pushSbosRoster = function(inventory)
  if Properties["SmartBuildOS Reporting"] ~= "On" then
    return
  end
  if gSbosConnectorId == nil then
    local ok, devices = pcall(function()
      return C4:GetDevices({})
    end)
    if ok and type(devices) == "table" then
      for rawId, device in pairs(devices) do
        local file = tostring((type(device) == "table" and device.driverFileName) or "")
        if file == "smartbuildos.c4z" then
          gSbosConnectorId = tonumber(rawId)
          break
        end
      end
    end
    if gSbosConnectorId == nil then
      return
    end
  end
  local roster = {}
  for _, key in ipairs({ "cameras", "sensors", "lights", "viewers", "sirens", "relays", "hubs" }) do
    for _, device in ipairs(inventory[key] or {}) do
      table.insert(roster, { kind = key, id = device.id, name = device.name, mac = device.mac, state = device.state })
    end
  end
  local serialized = JSON:encode(roster)
  if serialized == gSbosLastRoster then
    return
  end
  gSbosLastRoster = serialized
  log:debug("Handing %d Protect devices to the SmartBuildOS Connector", #roster)
  SendToDevice(gSbosConnectorId, "SBOS_PROTECT_ROSTER", { source = "unifi-protect", payload = serialized })
end

-- Composer sends command NAMES with spaces underscored by the dispatcher;
-- these aliases keep the canonical UPPER_CASE handlers as the one
-- implementation.
EC.Arm_With_Profile = EC.ARM_WITH_PROFILE
EC.Disarm = EC.DISARM
EC.Select_Arm_Profile = EC.SELECT_ARM_PROFILE
EC.Play_Siren = EC.PLAY_SIREN
EC.Stop_Siren = EC.STOP_SIREN
EC.Test_Siren = EC.TEST_SIREN
EC.Activate_Relay = EC.ACTIVATE_RELAY
EC.Trigger_Hub_Output = EC.TRIGGER_HUB_OUTPUT
EC.Trigger_Protect_Webhook = EC.TRIGGER_PROTECT_WEBHOOK
