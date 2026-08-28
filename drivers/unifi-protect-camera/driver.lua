--[[==========================================================================
  UniFi Protect Camera — child driver

  One instance per camera. Carries the camera proxy — the thing that actually
  puts a camera tile in Navigator — and a consumer CONTROL binding back to the
  UniFi Protect Gateway, which owns the console connection and the API key.
  This driver NEVER holds a credential: every console exchange goes over the
  binding, and everything it receives is a URL or a state string.

  ── HOW A CAMERA GETS ITS IDENTITY ────────────────────────────────────────────

  The dealer binds this driver's "Protect Camera" connection to one of the
  Gateway's per-camera connections in Composer. On bind, this driver asks
  PROTECT_GET_CAMERA over the binding; the Gateway knows which camera each of
  its bindings represents and answers with id/name/mac/state/console host.
  Identity is persisted, so a Director restart shows the camera without
  waiting for the Gateway.

  ── STREAMS ARE DYNAMIC, BECAUSE PROTECT'S ARE ────────────────────────────────

  Protect stream URLs are per-channel TOKENS (rtsps://console:7441/<token>)
  that a console can revoke and reissue. So this driver declares
  requires_dynamic_stream_urls and answers Navigator's GET_STREAM_URLS —
  synchronously from cache when it can, otherwise with a generating_key
  followed by a STREAM_URLS_READY notify once the Gateway has asked the
  console. When refreshed URLs differ from the cached ones, the proxy gets
  DYNAMIC_URLS_CHANGED so Navigators drop their caches.

  ── THE RTSPS QUESTION, MADE INTO A PROPERTY ──────────────────────────────────

  Whether a Navigator can actually PLAY rtsps+SRTP from a self-signed console
  is unmeasured (docs/unifi-protect-driver-research.md §0). The vendor-
  published fallback is the mechanical downgrade rtsps→rtsp, 7441→7447, query
  dropped. Rather than betting the driver on either answer, the Stream
  Protocol property offers both, defaulting to the native RTSPS URL. If the
  tile stays black, the dealer flips one property instead of filing a ticket —
  and the first field install answers the research question for free.
============================================================================]]

--#ifdef DRIVERCENTRAL
DC_PID = 0
DC_X = nil
DC_FILENAME = "unifi-protect-camera.c4z"
--#else
DRIVER_GITHUB_REPO = "michelo76/control4-smartbuildos"
DRIVER_FILENAMES = {
  "unifi-protect-camera.c4z",
}
--#endif

require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")

JSON = require("JSON")

local log = require("lib.logging")
local persist = require("lib.persist")

-- ─── Constants ────────────────────────────────────────────────────────────────

--- The camera proxy binding (declared in driver.xml).
local CAMERA_PROXY_BINDING = 5001
--- The consumer CONTROL binding to the Gateway (declared in driver.xml).
local GATEWAY_BINDING = 1

--- Persisted camera identity: { id, name, mac, console_host }.
local IDENTITY_PERSIST = "camera_identity"

--- The last name this driver set on its own devices. The auto-name guard:
--- rename only when the current name is the install default or OUR last
--- write, so a dealer's deliberate rename is never clobbered by a poll.
local AUTONAME_PERSIST = "auto_name_last"

--- Names the installer gets from a fresh add — the ones auto-naming may
--- overwrite. Composer suffixes duplicates ("UniFi Protect Camera 2"), so
--- prefix-match rather than equality.
local DEFAULT_NAME_PREFIX = "UniFi Protect Camera"

--- Composer events, ids matching driver.xml <events>. Registered again at
--- init because XML events only register when an instance is first added —
--- an update-in-place reaches nobody (measured on the connector).
local EVENTS = {
  { 1, "Motion Detected", "Protect detected motion on this camera." },
  { 2, "Motion Ended", "The motion event on this camera ended." },
  { 3, "Person Detected", "Protect detected a person on this camera." },
  { 4, "Vehicle Detected", "Protect detected a vehicle on this camera." },
  { 5, "Package Detected", "Protect detected a package on this camera." },
  { 6, "Animal Detected", "Protect detected an animal on this camera." },
  { 7, "License Plate Detected", "Protect read a license plate on this camera." },
  { 8, "Face Detected", "Protect detected a face on this camera." },
  { 9, "Doorbell Ring", "The doorbell button on this camera was pressed." },
  { 10, "Audio Alarm Detected", "Protect detected an audio alarm on this camera." },
  { 11, "Line Crossed", "Protect detected a line crossing on this camera." },
  { 12, "Loitering Detected", "Protect detected loitering on this camera." },
  { 13, "Camera Online", "This camera reconnected to the Protect console." },
  { 14, "Camera Offline", "This camera disconnected from the Protect console." },
}

--- Programming variables. BOOL for the live motion flag, STRINGs for the
--- last-seen facts programming can branch on.
local VARIABLES = {
  { "MOTION_DETECTED", "false", "BOOL" },
  { "LAST_MOTION", "", "STRING" },
  { "LAST_DETECTION", "", "STRING" },
  { "LAST_LICENSE_PLATE", "", "STRING" },
  { "LAST_AUDIO_TYPE", "", "STRING" },
  { "LAST_RING", "", "STRING" },
}

--- Ports Protect serves streams on. Fixed by Protect, not configurable per
--- camera: 7441 is RTSPS+SRTP, 7447 is the undocumented plain-RTSP sibling.
local RTSPS_PORT = 7441
local RTSP_PORT = 7447

--- How long a cached stream answer stays trusted. Protect URLs live until
--- revoked, so this is generous; the cache exists to spare the console a
--- round trip per tile render, not to model expiry Protect does not have.
local STREAM_CACHE_SECONDS = 12 * 60 * 60

-- ─── State ────────────────────────────────────────────────────────────────────

gInitialized = false

--- Camera identity as told by the Gateway. nil until first told.
gIdentity = nil

--- Last known camera state string (CONNECTED/CONNECTING/DISCONNECTED/UNKNOWN).
gCameraState = "UNKNOWN"

--- Cached stream URLs from the Gateway: { high?, medium?, low?, fetched_at }.
gStreams = nil

--- The Gateway's device id, once found (see findGatewayDeviceId).
gGatewayDeviceId = nil

--- Navigator requests waiting on the Gateway, keyed by the KEY echoed through
--- the binding protocol. Value: true. Keys are a 32-bit counter as the camera
--- proxy docs recommend.
gPendingStreamKeys = {}
gNextStreamKey = 0

-- ─── Helpers ──────────────────────────────────────────────────────────────────

local function xmlEscape(s)
  return (tostring(s):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
end

--- Applies the Stream Protocol property to a native Protect URL.
---
--- The downgrade is the vendor-published recipe, applied MECHANICALLY and only
--- to URLs that match the expected shape — anything else passes through
--- untouched rather than being half-rewritten.
--- @param url string A rtsps://host:7441/token?query URL from Protect.
--- @return string url The URL to hand Navigator.
local function applyProtocol(url)
  if Properties["Stream Protocol"] ~= "RTSP (unencrypted, port 7447)" then
    return url
  end
  local host, token = url:match("^rtsps://([^/:]+):" .. RTSPS_PORT .. "/([^?]+)")
  if host == nil then
    return url
  end
  return string.format("rtsp://%s:%d/%s", host, RTSP_PORT, token)
end

--- The `<streams>` XML for the current cache, in the shape the camera proxy
--- documents for GET_STREAM_URLS / STREAM_URLS_READY.
--- @param key string|nil The client's KEY to echo as an attribute, if any.
--- @return string xml
local function streamsXml(key)
  local parts = {}
  local attrs = {}
  if key ~= nil and key ~= "" then
    table.insert(attrs, string.format(' key="%s"', xmlEscape(key)))
  end
  if gIdentity ~= nil and gIdentity.console_host ~= "" then
    table.insert(attrs, string.format(' camera_address="%s"', xmlEscape(gIdentity.console_host)))
  end
  table.insert(parts, string.format("<streams%s>", table.concat(attrs)))
  -- Which qualities to offer. Navigator has no picker — the client silently
  -- takes from whatever list it is handed — so the Streams Offered property
  -- IS the resolution selector. A chosen quality the console did not provide
  -- falls back to offering everything: a wrong-resolution picture beats a
  -- black tile every time.
  local ONLY = {
    ["High only"] = "high",
    ["Medium only"] = "medium",
    ["Low only"] = "low",
  }
  local offered = { "high", "medium", "low" }
  local chosen = ONLY[Properties["Streams Offered"]]
  if chosen ~= nil then
    local url = (gStreams or {})[chosen]
    if type(url) == "string" and url ~= "" then
      offered = { chosen }
    else
      log:warn("Streams Offered wants '%s' but the console provided no such stream; offering all", chosen)
    end
  end
  -- high first: a client that ignores attributes takes the first entry, and
  -- the first entry should be the good one.
  for _, quality in ipairs(offered) do
    local url = (gStreams or {})[quality]
    if type(url) == "string" and url ~= "" then
      table.insert(parts, string.format('<stream url="%s" codec="h264"/>', xmlEscape(applyProtocol(url))))
    end
  end
  table.insert(parts, "</streams>")
  return table.concat(parts)
end

local function cacheIsFresh()
  return gStreams ~= nil and (os.time() - (gStreams.fetched_at or 0)) < STREAM_CACHE_SECONDS
end

local function updateStatusProperties()
  UpdateProperty("Camera", gIdentity ~= nil and gIdentity.name or "Not bound")
  UpdateProperty("MAC Address", gIdentity ~= nil and gIdentity.mac or "-")
  UpdateProperty("Camera State", gCameraState)
  local snapshotUrl = gIdentity ~= nil and tostring(gIdentity.snapshot_url or "") or ""
  UpdateProperty("Snapshots", snapshotUrl ~= "" and "Available via gateway relay" or "-")
end

--- The Gateway's DEVICE id, found by its driver FILE — exact match, because
--- "unifi-protect-camera.c4z" contains "unifi-protect" and a substring match
--- would find this driver's own siblings. Cached; re-scanned while unknown.
--- @return number|nil gatewayDeviceId
local function findGatewayDeviceId()
  if gGatewayDeviceId ~= nil then
    return gGatewayDeviceId
  end
  local ok, devices = pcall(function()
    return C4:GetDevices({})
  end)
  if not ok or type(devices) ~= "table" then
    return nil
  end
  for rawId, device in pairs(devices) do
    local id = tonumber(rawId)
    local file = tostring((type(device) == "table" and device.driverFileName) or "")
    if id ~= nil and (file == "unifi-protect.c4z" or file == "unifi-protect.c4i") then
      gGatewayDeviceId = id
      log:debug("Found the Gateway: device %s", id)
      return id
    end
  end
  return nil
end

--- Sends a request to the Gateway over BOTH transports.
---
--- SendToDevice → ExecuteCommand is the transport the field-tested reference
--- pair uses; SendToProxy over the bound CONTROL binding is the documented
--- one. Requests are idempotent, so both fire and whichever arrives wins —
--- the replies are keyed, and a duplicate identity answer is a no-op.
--- @param command string
--- @param params table
local function askGateway(command, params)
  SendToProxy(GATEWAY_BINDING, command, params)
  local gatewayId = findGatewayDeviceId()
  if gatewayId ~= nil then
    params = params or {}
    params.requester = tostring(C4:GetDeviceID())
    SendToDevice(gatewayId, command, params)
  end
end

--- Asks the Gateway who this driver is bound to. Cheap; asked on bind, on
--- init, on any sign of life from a Gateway while identity is unknown, and
--- every minute until answered — because the FIRST ask can land before the
--- Gateway is updated, bound, or even installed, and an ask that fires once
--- into the void was exactly how a field install ended up bound, streaming
--- state pushes, and still calling itself "Not bound".
local function requestIdentity()
  UpdateProperty("Gateway Link", "Asked gateway at " .. os.date("%H:%M:%S") .. " - waiting for a reply")
  askGateway("PROTECT_GET_CAMERA", {})
end

--- Timer that re-asks until an answer arrives. A no-op tick once identity is
--- known; cheap enough to leave armed for the driver's whole life.
local IDENTITY_RETRY_TIMER = "ProtectIdentityRetry"
local function armIdentityRetry()
  CancelTimer(IDENTITY_RETRY_TIMER)
  SetTimer(IDENTITY_RETRY_TIMER, 60 * ONE_SECOND, function()
    if gIdentity == nil then
      log:info("Still no camera identity from the Gateway; asking again")
      requestIdentity()
    end
  end, true)
end

--- Fires a Composer event by name. pcall'd: an event that failed to register
--- must not take down the handler that fires it.
local function fireEvent(name)
  log:debug("Firing event: %s", name)
  pcall(function()
    C4:FireEvent(name)
  end)
end

--- Sets a programming variable, quietly tolerating its absence.
local function setVariable(name, value)
  pcall(function()
    C4:SetVariable(name, tostring(value))
  end)
end

--- Records an event in Control4's History Agent, so detections show up in
--- the History view on touchscreens and the app with a deep link to this
--- camera.
---
--- Call pattern proven by a shipping third-party camera driver: the plain
--- four-argument form FIRST — the documented metadata-table form was
--- observed to silently stop records being stored on some OS builds — and
--- the metadata form only as a fallback where the plain form returns no
--- UUID. A nil UUID is the reliable failure signal; the History Agent not
--- being installed is the usual cause, and it costs a log line, never the
--- event pipeline.
--- @param severity string "Info" | "Warning" | "Critical"
--- @param eventType string What History displays, e.g. "Person Detected".
--- @param message string Human detail for the metadata form.
local function recordHistory(severity, eventType, message)
  local function record(...)
    local ok, uuid = pcall(C4.RecordHistory, C4, ...)
    if ok and uuid ~= nil and uuid ~= "" then
      return true
    end
    return false
  end
  if record(severity, eventType, "Cameras", "UniFi Protect") then
    return
  end
  if
    record(severity, eventType, "Cameras", "UniFi Protect", {
      Description = tostring(message or eventType),
      Camera = gIdentity ~= nil and gIdentity.name or "",
    })
  then
    return
  end
  log:debug("History not recorded for '%s' - is the History Agent installed?", eventType)
end

--- Whether the History property wants this kind of event recorded. Motion
--- fires constantly on a busy camera; smart detections are the ones worth a
--- timeline by default.
--- @param kind string The normalized event kind.
--- @return boolean record
local function historyWants(kind)
  local mode = Properties["History"] or "Smart detections only"
  if mode == "Off" then
    return false
  end
  if mode == "All events" then
    return true
  end
  -- Smart detections only: everything except plain motion.
  return kind ~= "motion"
end

--- Renames this driver's devices after the bound camera.
---
--- Renames BOTH ids: Composer's device tree shows the PROXY device, so
--- renaming only the protocol driver (this Lua's own id) changes nothing the
--- dealer can see — the API docs call this out. Guarded: a device is renamed
--- only while its name is still the install default or the name this driver
--- set last time, so a dealer who typed "Backyard Cam" keeps it forever.
--- @param cameraName string The Protect camera's name.
--- @param force boolean|nil True skips the clobber guard — the dealer asked.
local function autoNameDevices(cameraName, force)
  cameraName = tostring(cameraName or "")
  if cameraName == "" then
    return
  end
  local lastAuto = persist:get(AUTONAME_PERSIST, "")
  local renamedAny = false

  local ids = { C4:GetDeviceID() }
  local ok, proxyId = pcall(function()
    return C4:GetProxyDevices()
  end)
  if ok and type(proxyId) == "number" then
    table.insert(ids, proxyId)
  else
    -- An instance added before the proxy fix has no proxy device at all —
    -- said out loud because renaming only the protocol device of such an
    -- instance is the visible half of that bigger problem.
    log:warn("No proxy device found to rename - was this instance added with a pre-fix driver? Re-add it.")
  end

  for _, id in ipairs(ids) do
    local current = tostring(C4:GetDeviceData(id, "name") or "")
    local isDefault = current:sub(1, #DEFAULT_NAME_PREFIX) == DEFAULT_NAME_PREFIX
    local isOurs = lastAuto ~= "" and current == lastAuto
    if current == cameraName then
      log:debug("Device %s already named '%s'", id, cameraName)
    elseif force or isDefault or isOurs then
      log:info("Renaming device %s: '%s' -> '%s'", id, current, cameraName)
      pcall(function()
        C4:RenameDevice(id, cameraName)
      end)
      renamedAny = true
    else
      log:info(
        "NOT renaming device %s: '%s' is neither the install default nor this driver's last write ('%s') — use Rename From Camera to override",
        id,
        current,
        lastAuto
      )
    end
  end

  if renamedAny then
    persist:set(AUTONAME_PERSIST, cameraName)
  end
end

--- Asks the Gateway for stream URLs, tagged with a fresh key.
--- @return number key The key the reply will carry.
local function requestStreams()
  gNextStreamKey = gNextStreamKey + 1
  local key = gNextStreamKey
  gPendingStreamKeys[tostring(key)] = true
  askGateway("PROTECT_GET_STREAMS", { KEY = tostring(key) })
  return key
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
end

function OnDriverLateInit()
  log:trace("OnDriverLateInit()")
  if not CheckMinimumVersion("Driver Status") then
    return
  end

  -- Guarded by SHAPE: persist:get with no default returns its EMPTY sentinel
  -- table for a missing key.
  local cached = persist:get(IDENTITY_PERSIST)
  if type(cached) == "table" and cached.id ~= nil then
    gIdentity = cached
  end

  for p, _ in pairs(Properties) do
    local status, err = pcall(OnPropertyChanged, p)
    if not status and err then
      log:error("Error in OnPropertyChanged for property '%s': %s", p, err or "unknown error")
    end
  end

  -- Register events + variables on THIS instance. XML alone reaches only
  -- freshly-added instances; every field install is an update.
  for _, e in ipairs(EVENTS) do
    pcall(function()
      C4:AddEvent(e[1], e[2], e[3])
    end)
  end
  for _, v in ipairs(VARIABLES) do
    pcall(function()
      C4:AddVariable(v[1], v[2], v[3], true)
    end)
  end

  gInitialized = true
  UpdateProperty("Driver Status", "Online")
  -- The build actually running, said by the code itself. Instances have now
  -- twice been discovered running a stale cached driver while the Drivers
  -- folder held a newer build; this property ends the guessing.
  pcall(function()
    UpdateProperty("Driver Version", tostring(C4:GetDriverConfigInfo("version")))
  end)
  updateStatusProperties()
  requestIdentity()
  armIdentityRetry()
end

function OnDriverDestroyed()
  CancelTimer(IDENTITY_RETRY_TIMER)
end

-- ─── Gateway binding ──────────────────────────────────────────────────────────

--- Bound or unbound in Composer. On bind, learn who we are; on unbind, keep
--- the identity — an unbind during a project reshuffle must not blank a
--- camera that will be rebound in a minute. Forget Camera exists for the
--- deliberate case.
OBC[GATEWAY_BINDING] = function(_, _, bIsBound)
  log:debug("Gateway binding %s", bIsBound and "bound" or "unbound")
  if bIsBound then
    requestIdentity()
  else
    gCameraState = "UNKNOWN"
    updateStatusProperties()
  end
end

function RFP.PROTECT_CAMERA(_, _, tParams)
  tParams = tParams or {}
  gIdentity = {
    id = tostring(tParams.id or ""),
    name = tostring(tParams.name or "Camera"),
    mac = tostring(tParams.mac or ""),
    console_host = tostring(tParams.console_host or ""),
    snapshot_url = tostring(tParams.snapshot_url or ""),
  }
  gCameraState = tostring(tParams.state or "UNKNOWN")
  persist:set(IDENTITY_PERSIST, gIdentity)
  updateStatusProperties()
  UpdateProperty("Gateway Link", string.format("OK - identified as '%s' at %s", gIdentity.name, os.date("%H:%M:%S")))
  autoNameDevices(gIdentity.name)
  log:info("Bound to Protect camera '%s' (%s)", gIdentity.name, gIdentity.id)
end

function RFP.PROTECT_STATE(_, _, tParams)
  tParams = tParams or {}
  local newState = tostring(tParams.state or "UNKNOWN")
  if gIdentity ~= nil and tParams.snapshot_url ~= nil and tostring(tParams.snapshot_url) ~= gIdentity.snapshot_url then
    gIdentity.snapshot_url = tostring(tParams.snapshot_url)
    persist:set(IDENTITY_PERSIST, gIdentity)
  end
  -- A state push while identity is unknown is PROOF a Gateway is bound,
  -- alive, and knows this camera — the ask must have been lost (a driver
  -- updated in the wrong order, a Director restart mid-handshake). Re-ask
  -- now instead of waiting for someone to notice "Not bound".
  if gIdentity == nil then
    log:info("State push arrived before identity; asking the Gateway who this is")
    requestIdentity()
  end
  if gIdentity ~= nil and tostring(tParams.name or "") ~= "" then
    if gIdentity.name ~= tostring(tParams.name) then
      -- The camera was renamed in Protect; follow it (same clobber guard).
      gIdentity.name = tostring(tParams.name)
      persist:set(IDENTITY_PERSIST, gIdentity)
      autoNameDevices(gIdentity.name)
    end
  end
  if newState ~= gCameraState then
    local previous = gCameraState
    log:info("Camera state: %s -> %s", previous, newState)
    gCameraState = newState
    -- Online/Offline events fire on REAL transitions only. From UNKNOWN is a
    -- driver (re)start learning the state, not the camera changing it — an
    -- event there would page someone on every Director reboot.
    if previous ~= "UNKNOWN" then
      local cameraName = gIdentity ~= nil and gIdentity.name or "Camera"
      if newState == "CONNECTED" then
        fireEvent("Camera Online")
        if historyWants("state") then
          recordHistory("Info", "Camera Online", cameraName .. " reconnected")
        end
      elseif newState == "DISCONNECTED" then
        fireEvent("Camera Offline")
        if historyWants("state") then
          recordHistory("Warning", "Camera Offline", cameraName .. " disconnected from the console")
        end
      end
    end
  end
  updateStatusProperties()
end

--- A Protect event for this camera, normalized by the Gateway:
--- { kind = motion|smart|audio|ring|line|loiter, phase = start|end,
---   types = "person,vehicle", at = <unix ms>, value = <plate text, if any> }.
function RFP.PROTECT_EVENT(_, _, tParams)
  tParams = tParams or {}
  local kind = tostring(tParams.kind or "")
  local phase = tostring(tParams.phase or "start")
  local types = tostring(tParams.types or "")
  local now = os.date("%Y-%m-%d %H:%M:%S")

  local cameraName = gIdentity ~= nil and gIdentity.name or "Camera"

  if kind == "motion" then
    if phase == "start" then
      setVariable("MOTION_DETECTED", "true")
      setVariable("LAST_MOTION", now)
      fireEvent("Motion Detected")
      if historyWants(kind) then
        recordHistory("Info", "Motion Detected", "Motion on " .. cameraName)
      end
    else
      setVariable("MOTION_DETECTED", "false")
      fireEvent("Motion Ended")
    end
  elseif kind == "smart" and phase == "start" then
    local BY_TYPE = {
      person = "Person Detected",
      vehicle = "Vehicle Detected",
      package = "Package Detected",
      animal = "Animal Detected",
      licensePlate = "License Plate Detected",
      face = "Face Detected",
    }
    for detected in types:gmatch("[^,]+") do
      local eventName = BY_TYPE[detected]
      if eventName ~= nil then
        setVariable("LAST_DETECTION", detected)
        if detected == "licensePlate" and tostring(tParams.value or "") ~= "" then
          setVariable("LAST_LICENSE_PLATE", tostring(tParams.value))
        end
        fireEvent(eventName)
        if historyWants(kind) then
          local detail = eventName .. " on " .. cameraName
          if detected == "licensePlate" and tostring(tParams.value or "") ~= "" then
            detail = detail .. " (" .. tostring(tParams.value) .. ")"
          end
          recordHistory("Info", eventName, detail)
        end
      else
        log:debug("Unknown smart detection type '%s' — Protect grew a vocabulary word", detected)
      end
    end
  elseif kind == "audio" and phase == "start" then
    setVariable("LAST_AUDIO_TYPE", types)
    fireEvent("Audio Alarm Detected")
    if historyWants(kind) then
      -- An audio ALARM (smoke, CO, siren, glass break) outranks a sighting.
      recordHistory("Warning", "Audio Alarm Detected", "Audio alarm (" .. types .. ") on " .. cameraName)
    end
  elseif kind == "ring" then
    setVariable("LAST_RING", now)
    fireEvent("Doorbell Ring")
    if historyWants(kind) then
      recordHistory("Info", "Doorbell Ring", "Doorbell pressed at " .. cameraName)
    end
  elseif kind == "line" and phase == "start" then
    setVariable("LAST_DETECTION", types ~= "" and types or "line")
    fireEvent("Line Crossed")
    if historyWants(kind) then
      recordHistory("Info", "Line Crossed", "Line crossed on " .. cameraName)
    end
  elseif kind == "loiter" and phase == "start" then
    setVariable("LAST_DETECTION", types ~= "" and types or "loiter")
    fireEvent("Loitering Detected")
    if historyWants(kind) then
      recordHistory("Info", "Loitering Detected", "Loitering on " .. cameraName)
    end
  end
end

--- Stream URLs arrived from the Gateway. Two audiences: the cache (always),
--- and any Navigator waiting on the echoed KEY (notified via
--- STREAM_URLS_READY, per the async half of the dynamic-streams API).
function RFP.PROTECT_STREAMS(_, _, tParams)
  tParams = tParams or {}
  local key = tostring(tParams.KEY or "")

  local changed = gStreams == nil
  local fresh = { fetched_at = os.time() }
  for _, quality in ipairs({ "high", "medium", "low" }) do
    local url = tParams[quality]
    if type(url) == "string" and url ~= "" then
      fresh[quality] = url
      if gStreams ~= nil and gStreams[quality] ~= url then
        changed = true
      end
    elseif gStreams ~= nil and gStreams[quality] ~= nil then
      changed = true
    end
  end
  gStreams = fresh
  UpdateProperty(
    "Streams",
    table.concat(
      (function()
        local qualities = {}
        for _, quality in ipairs({ "high", "medium", "low" }) do
          if fresh[quality] then
            table.insert(qualities, quality)
          end
        end
        return #qualities > 0 and qualities or { "none" }
      end)(),
      ", "
    )
  )

  if gPendingStreamKeys[key] then
    gPendingStreamKeys[key] = nil
    SendToProxy(CAMERA_PROXY_BINDING, "STREAM_URLS_READY", { KEY = key, URLS = streamsXml(key) }, "NOTIFY")
  end

  -- A cache-driven refresh (no Navigator waiting) that CHANGED the URLs means
  -- every Navigator holding the old ones is now holding revoked tokens.
  if changed then
    SendToProxy(CAMERA_PROXY_BINDING, "DYNAMIC_URLS_CHANGED", {}, "NOTIFY")
  end
end

function RFP.PROTECT_STREAMS_ERROR(_, _, tParams)
  tParams = tParams or {}
  local key = tostring(tParams.KEY or "")
  gPendingStreamKeys[key] = nil
  log:warn("Gateway could not provide stream URLs: %s", tostring(tParams.reason or "unknown"))
  UpdateProperty("Streams", "unavailable - " .. tostring(tParams.reason or "unknown"))
end

-- ─── The device-path door ─────────────────────────────────────────────────────
--
-- The Gateway prefers SendToDevice → ExecuteCommand (the transport the
-- field-tested reference pair uses), which handlers dispatch through EC.
-- Same messages, same handlers, second door. EC handlers receive (tParams).

EC.PROTECT_CAMERA = function(tParams)
  RFP.PROTECT_CAMERA(nil, nil, tParams)
end
EC.PROTECT_STATE = function(tParams)
  RFP.PROTECT_STATE(nil, nil, tParams)
end
EC.PROTECT_STREAMS = function(tParams)
  RFP.PROTECT_STREAMS(nil, nil, tParams)
end
EC.PROTECT_STREAMS_ERROR = function(tParams)
  RFP.PROTECT_STREAMS_ERROR(nil, nil, tParams)
end
EC.PROTECT_EVENT = function(tParams)
  RFP.PROTECT_EVENT(nil, nil, tParams)
end

-- ─── Camera proxy ─────────────────────────────────────────────────────────────
--
-- Navigator's requests arrive through the UIRequest entry point (dispatched
-- via the UIR table), NOT ReceivedFromProxy — measured in a field-tested
-- camera driver, and the reason the first build of this driver streamed
-- nothing. The same commands are also registered under RFP because Composer's
-- Camera Test sends proxy commands; one implementation serves both doors.

--- Navigator wants stream URLs. Answered synchronously from a fresh cache,
--- otherwise with the generating_key handshake while the Gateway is asked.
--- @param tParams table|nil CODEC/RESOLUTION/FPS/useCache/KEY from the client.
--- @return string xml
local function handleGetStreamUrls(tParams)
  tParams = tParams or {}
  local useCache = tostring(tParams.useCache or "") == "true"
  if cacheIsFresh() or (useCache and gStreams ~= nil) then
    -- Echo the client's KEY when it sent one; a keyless request gets the
    -- plain form. Both are documented shapes for the synchronous answer.
    return streamsXml(tostring(tParams.KEY or ""))
  end
  local key = requestStreams()
  return string.format('<streams generating_key="%d"/>', key)
end

--- Composer/Navigator asking how to reach the camera. With dynamic streams
--- the URLs are the real answer, but the proxy still asks; the console host
--- is the only address that means anything (Protect fronts every camera).
--- @return string xml
local function handleGetProperties()
  local host = gIdentity ~= nil and gIdentity.console_host or ""
  local rtspPort = Properties["Stream Protocol"] == "RTSP (unencrypted, port 7447)" and RTSP_PORT or RTSPS_PORT
  return table.concat({
    "<camera_properties>",
    string.format("<address>%s</address>", xmlEscape(host)),
    "<http_port>443</http_port>",
    string.format("<rtsp_port>%d</rtsp_port>", rtspPort),
    "<authentication_required>false</authentication_required>",
    "<authentication_type>BASIC</authentication_type>",
    "<username></username>",
    "<password></password>",
    "<publicly_accessible>false</publicly_accessible>",
    "</camera_properties>",
  })
end

function UIR.GET_STREAM_URLS(tParams)
  return handleGetStreamUrls(tParams)
end

function UIR.GET_PROPERTIES()
  return handleGetProperties()
end

function RFP.GET_STREAM_URLS(idBinding, _, tParams)
  if idBinding ~= CAMERA_PROXY_BINDING then
    return
  end
  return handleGetStreamUrls(tParams)
end

function RFP.GET_PROPERTIES(idBinding)
  if idBinding ~= CAMERA_PROXY_BINDING then
    return
  end
  return handleGetProperties()
end

--- Snapshot URLs, from the Gateway's relay. The relay URL is header-free by
--- design — that is its whole reason to exist — so it can be handed straight
--- to any client.
--- @return string xml
local function handleGetSnapshotUrls()
  local url = gIdentity ~= nil and tostring(gIdentity.snapshot_url or "") or ""
  if url == "" then
    return "<snapshots/>"
  end
  return string.format('<snapshots><snapshot url="%s"/></snapshots>', xmlEscape(url))
end

function UIR.GET_SNAPSHOT_URLS()
  return handleGetSnapshotUrls()
end

function RFP.GET_SNAPSHOT_URLS(idBinding)
  if idBinding ~= CAMERA_PROXY_BINDING then
    return
  end
  return handleGetSnapshotUrls()
end

--- Called by the Notification Agent when a push notification with an image
--- attachment fires. High quality: a push notification is one image on a
--- phone screen, and 640x360 looks like 2012 there.
--- @return string url The snapshot URL, or "" when none is available.
function GetNotificationAttachmentURL()
  local url = gIdentity ~= nil and tostring(gIdentity.snapshot_url or "") or ""
  if url == "" then
    return ""
  end
  return url .. (url:find("?", 1, true) and "&" or "?") .. "hq=1"
end

-- ─── Conditionals ─────────────────────────────────────────────────────────────

function TC.CAMERA_ONLINE()
  return gCameraState == "CONNECTED"
end

-- ─── Property handlers ────────────────────────────────────────────────────────

function OPC.Stream_Protocol(propertyValue)
  log:trace("OPC.Stream_Protocol('%s')", propertyValue)
  if not gInitialized then
    return
  end
  -- The URLs Navigators hold were rendered under the OLD protocol choice.
  SendToProxy(CAMERA_PROXY_BINDING, "DYNAMIC_URLS_CHANGED", {}, "NOTIFY")
end

function OPC.Streams_Offered(propertyValue)
  log:trace("OPC.Streams_Offered('%s')", propertyValue)
  if not gInitialized then
    return
  end
  -- Same reasoning: the cached lists Navigators hold no longer match the offer.
  SendToProxy(CAMERA_PROXY_BINDING, "DYNAMIC_URLS_CHANGED", {}, "NOTIFY")
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

function EC.REFRESH_CAMERA_INFO()
  log:trace("EC.REFRESH_CAMERA_INFO()")
  requestIdentity()
end

function EC.REFRESH_STREAMS()
  log:trace("EC.REFRESH_STREAMS()")
  requestStreams()
end

function EC.PRINT_STREAMS()
  log:trace("EC.PRINT_STREAMS()")
  if gStreams == nil then
    log:print("No stream URLs cached - run Refresh Stream URLs, or open the camera once")
    return
  end
  for _, quality in ipairs({ "high", "medium", "low" }) do
    if gStreams[quality] then
      log:print("  %s: %s (delivered as: %s)", quality, gStreams[quality], applyProtocol(gStreams[quality]))
    end
  end
end

--- Everything a support call needs, in one log block.
function EC.PRINT_DIAGNOSTICS()
  log:print("== UniFi Protect Camera (SBOS) diagnostics ==")
  log:print("  driver version: %s", tostring(C4.GetDriverConfigInfo and C4:GetDriverConfigInfo("version") or "?"))
  log:print("  device id: %s", tostring(C4:GetDeviceID()))
  local ok, proxyId = pcall(function()
    return C4:GetProxyDevices()
  end)
  if ok and type(proxyId) == "number" then
    log:print("  proxy device: %s - Navigator can see this camera", proxyId)
  else
    log:print("  proxy device: NONE - this instance predates the proxy fix; DELETE it and add a fresh one")
  end
  local gatewayId = findGatewayDeviceId()
  log:print(
    "  gateway device: %s",
    gatewayId ~= nil and tostring(gatewayId) or "NOT FOUND in this project - add the UniFi Protect Gateway (SBOS)"
  )
  log:print("  identity: %s", gIdentity ~= nil and string.format("'%s' (%s)", gIdentity.name, gIdentity.id) or "none")
  log:print("  camera state: %s", tostring(gCameraState))
  log:print("  gateway link: %s", tostring(Properties["Gateway Link"]))
  log:print("  streams cached: %s", gStreams ~= nil and "yes" or "no")
end

--- The explicit rename — dealer intent, so the clobber guard steps aside.
function EC.RENAME_NOW()
  log:trace("EC.RENAME_NOW()")
  if gIdentity == nil or gIdentity.name == "" then
    log:print("No camera identity yet - bind to the Gateway first (see Gateway Link)")
    return
  end
  autoNameDevices(gIdentity.name, true)
end

--- The deliberate forget, for re-purposing an instance onto another camera.
function EC.FORGET_CAMERA()
  log:trace("EC.FORGET_CAMERA()")
  gIdentity = nil
  gStreams = nil
  gCameraState = "UNKNOWN"
  persist:delete(IDENTITY_PERSIST)
  -- Forgetting the camera also forgets the auto-name claim: the next bound
  -- camera may rename freely, and a dealer rename before then stays put.
  persist:delete(AUTONAME_PERSIST)
  updateStatusProperties()
  UpdateProperty("Streams", "-")
  requestIdentity()
end
