--#ifdef DRIVERCENTRAL
DC_PID = 0
DC_X = nil
DC_FILENAME = "smartbuildos.c4z"
--#else
DRIVER_GITHUB_REPO = "michelo76/control4-smartbuildos"
DRIVER_FILENAMES = {
  "smartbuildos.c4z",
}
--#endif

require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")

JSON = require("JSON")

local log = require("lib.logging")
local http = require("lib.http")
local persist = require("lib.persist")
--#ifndef DRIVERCENTRAL
local githubUpdater = require("lib.github-updater")
--#endif

--- Interval labels mapped to seconds.
--- @type table<string, number>
local INTERVALS = {
  ["1m"] = 60,
  ["5m"] = 5 * 60,
  ["15m"] = 15 * 60,
  ["30m"] = 30 * 60,
  ["1h"] = 60 * 60,
  ["6h"] = 6 * 60 * 60,
  ["12h"] = 12 * 60 * 60,
  ["24h"] = 24 * 60 * 60,
}

--- `type` values returned by C4:GetNetworkConnections, mapped to labels the
--- platform can group on. Values come from the DriverWorks API reference.
--- @type table<number, string>
local CONNECTION_TYPES = {
  [0] = "unknown",
  [1] = "uuid",
  [2] = "ip",
  [3] = "zigbee",
  [4] = "hostname",
  [5] = "ssl",
  [6] = "ssl_hostname",
  [7] = "unix_socket",
  [8] = "zwave",
}

local HEARTBEAT_TIMER = "SmartBuildOSHeartbeat"
local DEVICE_POLL_TIMER = "SmartBuildOSDevicePoll"
local FULL_SYNC_TIMER = "SmartBuildOSFullSync"

--- Persist keys. The token is stored encrypted; the project file is handed
--- around between dealers and backed up, so it must not carry a usable secret.
local TOKEN_KEY = "device_token"
local PROPERTY_KEY = "property_id"
local PROPERTY_NAME_KEY = "property_name"

--- Requests are given a generous ceiling: a controller on a saturated uplink
--- should retry on the next tick rather than pile up in-flight posts.
local REQUEST_TIMEOUT = 30

--- ICMP attempts before an endpoint is called offline. Rounds are spaced 5
--- seconds apart by the platform, so this is also the failure latency budget:
--- 3 rounds means a dead host is reported ~15s after the poll starts. Enough to
--- ride out a single dropped packet without stretching past the 1m floor on the
--- poll interval.
local PING_ROUNDS = 3

--- @type boolean Whether the last delivery attempt succeeded.
local gConnected = false
--- @type number Consecutive failed deliveries, reset on success.
local gFailures = 0
--- Last observed device state, keyed by device id. Compared each poll so only
--- transitions are reported; a 200-device project otherwise re-sends an
--- unchanged snapshot every five minutes forever.
--- @type table<string, table<string, any>>
local gDeviceState = {}
--- @type boolean Whether a snapshot has been taken since the driver loaded.
local gHasSnapshot = false

-- ─── Pairing state ────────────────────────────────────────────────────────────

--- @return string token The stored device token, or "" when unpaired.
local function deviceToken()
  return persist:get(TOKEN_KEY, "", true) or ""
end

--- @return string propertyId The paired SmartBuildOS property id, or "".
local function propertyId()
  return persist:get(PROPERTY_KEY, "") or ""
end

--- @return boolean paired Whether the driver holds a usable token.
local function isPaired()
  return deviceToken() ~= "" and propertyId() ~= ""
end

-- ─── HTTP ─────────────────────────────────────────────────────────────────────

--- Builds the SmartBuildOS ingest URL for a given path.
--- Trailing slashes on the configured base URL are tolerated so a dealer
--- pasting "https://app.smartbuildos.com/" does not silently produce "//api".
--- @param path string Path beneath the ingest root, with no leading slash.
--- @return string|nil url The absolute URL, or nil when no base URL is set.
local function ingestUrl(path)
  local base = Properties["API URL"] or ""
  base = base:gsub("%s+", ""):gsub("/+$", "")
  if base == "" then
    return nil
  end
  return string.format("%s/api/integrations/control4/%s", base, path)
end

--- Returns the auth headers for an authenticated ingest request.
--- @return table<string, string> headers
local function authHeaders()
  return {
    ["Authorization"] = "Bearer " .. deviceToken(),
    ["Content-Type"] = "application/json",
    ["X-SmartBuildOS-Property"] = propertyId(),
  }
end

--- Collects the controller-level facts sent with every payload.
--- @return table<string, any> identity
local function systemIdentity()
  return {
    property_id = propertyId(),
    controller_type = C4:GetSystemType(),
    os_version = C4:GetVersionInfo().version,
    driver_version = C4:GetDriverConfigInfo("version"),
    device_id = C4:GetDeviceID(),
    director_name = C4:GetDeviceData(C4:GetDeviceID(), "name"),
  }
end

--- Updates connection state, the status property, and fires the matching event.
--- Events fire only on a transition, so a controller that has been offline for
--- a day does not generate one notification per heartbeat.
--- @param connected boolean
--- @param status string Text for the Connection Status property.
local function setConnected(connected, status)
  local changed = gConnected ~= connected
  gConnected = connected
  UpdateProperty("Connection Status", status)
  if changed then
    C4:FireEvent(connected and "Connected" or "Disconnected")
  end
end

--- Posts a payload to SmartBuildOS and reconciles connection state.
--- @param path string Ingest path beneath the integration root.
--- @param payload table<string, any> Body to send, merged with the identity block.
--- @param description string Label used in log lines.
local function send(path, payload, description)
  if not isPaired() then
    log:warn("Not sending %s: driver is not paired to a property", description)
    setConnected(false, "Not paired")
    return
  end

  local url = ingestUrl(path)
  if not url then
    setConnected(false, "API URL is not set")
    return
  end

  payload.system = systemIdentity()
  payload.sent_at = os.time()

  log:debug("Sending %s to %s", description, url)
  http:post(url, payload, authHeaders(), { timeout = REQUEST_TIMEOUT }):next(function(response)
    gFailures = 0
    UpdateProperty("Last Successful Sync", os.date("%Y-%m-%d %H:%M:%S"))
    setConnected(true, "Connected")
    log:info("%s delivered (HTTP %s)", description, tostring(response.code))
  end, function(err)
    -- Http:request rejects on *any* non-2xx as well as on transport failure, so
    -- this one handler covers both. The distinction matters to whoever reads
    -- Connection Status: a 401 means the token was revoked and a 404 means the
    -- property is gone, and those need different fixes than "no internet".
    gFailures = gFailures + 1
    local code = err and err.code
    if type(code) == "number" then
      setConnected(false, string.format("HTTP %d", code))
      log:error("%s rejected with HTTP %d: %s", description, code, tostring(err.body))
    else
      setConnected(false, "Unreachable")
      log:error("%s failed after %d attempt(s): %s", description, gFailures, tostring(err and err.error or err))
    end
    C4:FireEvent("Sync Failed")
  end)
end

-- ─── Device state, from Director ──────────────────────────────────────────────

--- Reads the whole project's connection state from Director.
---
--- `C4:GetNetworkConnections()` is the only system-wide source of online/offline
--- truth available to a driver: it returns every network binding in the project,
--- not just this driver's. `state == 1` means the connection is active. Z-Wave
--- entries additionally carry `network_status`, which is preferred when present
--- because a sleeping battery device reports `state = 1` while unreachable.
---
--- Devices with no network binding at all -- IR-controlled sources, serial-only
--- gear, dumb loads -- never appear here and therefore have no online state to
--- report. That is a limitation of Director, not of this driver.
---
--- @return table<string, table<string, any>> devices Keyed by "c4:<device id>".
local function readDeviceState()
  local devices = {}
  for _, conn in pairs(C4:GetNetworkConnections() or {}) do
    local id = tointeger(conn.deviceid)
    if id ~= nil then
      local online = tointeger(conn.state) == 1
      if conn.network_status ~= nil and conn.network_status ~= "" then
        online = conn.network_status == "online"
      end
      devices["c4:" .. id] = {
        key = "c4:" .. id,
        source = "director",
        device_id = id,
        name = conn.name,
        online = online,
        connection_type = CONNECTION_TYPES[tointeger(conn.type) or 0] or "unknown",
        address = conn.address,
        port = tointeger(conn.port),
        firmware = conn.firmware,
        binding_id = tointeger(conn.bindingid),
        network_status = conn.network_status,
        device_status = conn.device_status,
        wake_status = conn.wake_status,
      }
    end
  end
  return devices
end

-- ─── Non-Control4 endpoints, via ICMP ─────────────────────────────────────────

--- Parses the Monitored Endpoints property.
---
--- Director only knows about devices that are bound into the project, so a core
--- switch, an access point, a NAS or an IP camera with no driver is invisible to
--- `GetNetworkConnections`. Those are named here and reached with ICMP instead.
---
--- Accepts a comma-separated list, each entry either `Label=host` or a bare
--- host. A bare host is labelled with itself.
---
--- @return table[] endpoints List of `{ name = string, host = string }`.
local function parseEndpoints()
  local endpoints = {}
  local seen = {}
  for entry in (Properties["Monitored Endpoints"] or ""):gmatch("[^,]+") do
    local name, host = entry:match("^%s*(.-)%s*=%s*(.-)%s*$")
    if host == nil or host == "" then
      host = entry:gsub("^%s+", ""):gsub("%s+$", "")
      name = host
    end
    -- A duplicate host would produce two entries with the same key, and the
    -- second would overwrite the first mid-diff and read as a flap.
    if host ~= "" and not seen[host] then
      seen[host] = true
      table.insert(endpoints, { name = name ~= "" and name or host, host = host })
    end
  end
  return endpoints
end

--- Pings every monitored endpoint and invokes `done` once all have settled.
---
--- Each C4Ping round is spaced 5 seconds apart, so an unreachable host takes
--- `PING_ROUNDS * 5` seconds to fail. That is why the results are gathered
--- against a pending counter rather than awaited in sequence -- serially, a
--- dozen dead hosts would outlast the poll interval that started them.
---
--- @param done fun(devices: table<string, table<string, any>>)
local function pingEndpoints(done)
  local endpoints = parseEndpoints()
  if #endpoints == 0 then
    done({})
    return
  end

  if C4.CreatePingClient == nil then
    log:warn("This controller's OS does not provide the ping API; skipping %d monitored endpoint(s)", #endpoints)
    done({})
    return
  end

  local results = {}
  local pending = #endpoints
  local settled = false

  --- Guards against a callback firing twice: `pending` would go negative and
  --- `done` would run again on a half-built result set.
  local function settle(endpoint, online)
    if results[endpoint.host] ~= nil then
      return
    end
    results[endpoint.host] = {
      key = "ping:" .. endpoint.host,
      source = "ping",
      name = endpoint.name,
      address = endpoint.host,
      connection_type = "icmp",
      online = online,
    }
    pending = pending - 1
    if pending <= 0 and not settled then
      settled = true
      local byKey = {}
      for _, device in pairs(results) do
        byKey[device.key] = device
      end
      done(byKey)
    end
  end

  for _, endpoint in ipairs(endpoints) do
    local client, err = C4:CreatePingClient()
    if client == nil then
      log:error("Could not create ping client for %s: %s", endpoint.host, tostring(err))
      settle(endpoint, false)
    else
      client:SetOnResult(function(_, success)
        settle(endpoint, success == true)
      end)
      local ok, pingErr = client:Ping(endpoint.host, PING_ROUNDS)
      if ok == nil then
        log:error("Ping to %s could not start: %s", endpoint.host, tostring(pingErr))
        settle(endpoint, false)
      end
    end
  end

  -- A ping client that never calls back would strand the poll forever. Cap the
  -- wait at the worst case a full round set can take, plus a margin.
  SetTimer("PingTimeout", (PING_ROUNDS * 5 + 10) * ONE_SECOND, function()
    if settled then
      return
    end
    settled = true
    log:warn("%d endpoint ping(s) did not report back in time; treating as offline", pending)
    local byKey = {}
    for _, endpoint in ipairs(endpoints) do
      local device = results[endpoint.host]
        or {
          key = "ping:" .. endpoint.host,
          source = "ping",
          name = endpoint.name,
          address = endpoint.host,
          connection_type = "icmp",
          online = false,
        }
      byKey[device.key] = device
    end
    done(byKey)
  end)
end

--- Reads Director state and pings monitored endpoints, then hands the merged
--- picture to `done`.
--- @param done fun(devices: table<string, table<string, any>>)
local function readAllState(done)
  local devices = readDeviceState()
  pingEndpoints(function(pinged)
    for key, device in pairs(pinged) do
      devices[key] = device
    end
    done(devices)
  end)
end

--- Flattens the device map into a list for transport. JSON encoders emit a
--- sparse integer-keyed table as an object with numeric string keys, which is
--- awkward on the receiving end; a list is unambiguous.
--- @param devices table<number, table<string, any>>
--- @return table[] list
local function toList(devices)
  local list = {}
  for _, device in pairs(devices) do
    table.insert(list, device)
  end
  return list
end

--- Counts how many devices in a snapshot are offline.
--- @param devices table<number, table<string, any>>
--- @return number count
local function offlineCount(devices)
  local count = 0
  for _, device in pairs(devices) do
    if not device.online then
      count = count + 1
    end
  end
  return count
end

--- Sends the complete device snapshot. Used on pairing, on a timer, and from
--- the action, so the platform can reconcile away any delta it missed.
local function sendFullSync()
  readAllState(function(devices)
    gDeviceState = devices
    gHasSnapshot = true

    local list = toList(devices)
    UpdateProperty("Devices Offline", tostring(offlineCount(devices)))
    log:info("Sending full sync of %d device(s)", #list)
    send("devices", { kind = "snapshot", devices = list }, "full sync")
  end)
end

--- Polls Director and the monitored endpoints, then reports only what changed.
--- Fires Device Came Online / Device Went Offline for programming, and records
--- the device that moved so a dealer can see it without reading the log.
local function pollDeviceState()
  readAllState(function(devices)
    if not gHasSnapshot then
      -- Nothing to diff against: treat the first poll as the baseline rather
      -- than reporting every device in the project as a fresh transition.
      gDeviceState = devices
      gHasSnapshot = true
      UpdateProperty("Devices Offline", tostring(offlineCount(devices)))
      return
    end

    local changes = {}
    for key, device in pairs(devices) do
      local previous = gDeviceState[key]
      if previous == nil then
        table.insert(changes, device)
        log:info("Device %s appeared", tostring(device.name))
      elseif previous.online ~= device.online then
        table.insert(changes, device)
        UpdateProperty(
          "Last Device Change",
          string.format("%s %s", tostring(device.name), device.online and "came online" or "went offline")
        )
        C4:FireEvent(device.online and "Device Came Online" or "Device Went Offline")
        log:info("Device %s %s", tostring(device.name), device.online and "came online" or "went offline")
      end
    end

    -- A device that disappears has been removed from the project, or dropped
    -- from Monitored Endpoints. Report it so the platform stops counting it.
    for key, previous in pairs(gDeviceState) do
      if devices[key] == nil then
        table.insert(changes, {
          key = key,
          source = previous.source,
          device_id = previous.device_id,
          name = previous.name,
          removed = true,
        })
        log:info("Device %s is no longer monitored", tostring(previous.name))
      end
    end

    gDeviceState = devices
    UpdateProperty("Devices Offline", tostring(offlineCount(devices)))

    if #changes == 0 then
      log:debug("Device poll: no changes")
      return
    end

    log:info("Device poll: %d change(s)", #changes)
    send("devices", { kind = "delta", devices = changes }, "device delta")
  end)
end

--- Sends a heartbeat: proof of life plus a small health summary.
local function sendHeartbeat()
  send("heartbeat", {
    kind = "heartbeat",
    consecutive_failures = gFailures,
    devices_total = TableLength(gDeviceState),
    devices_offline = offlineCount(gDeviceState),
  }, "heartbeat")
end

--- (Re)arms every reporting timer from the current properties.
local function scheduleTimers()
  CancelTimer(HEARTBEAT_TIMER)
  CancelTimer(DEVICE_POLL_TIMER)
  CancelTimer(FULL_SYNC_TIMER)

  local heartbeat = INTERVALS[Properties["Heartbeat Interval"] or ""] or INTERVALS["15m"]
  local poll = INTERVALS[Properties["Device Poll Interval"] or ""] or INTERVALS["5m"]
  local fullSync = INTERVALS[Properties["Full Sync Interval"] or ""] or INTERVALS["24h"]

  SetTimer(HEARTBEAT_TIMER, heartbeat * ONE_SECOND, sendHeartbeat, true)
  SetTimer(DEVICE_POLL_TIMER, poll * ONE_SECOND, pollDeviceState, true)
  SetTimer(FULL_SYNC_TIMER, fullSync * ONE_SECOND, sendFullSync, true)
  log:debug("Timers armed: heartbeat %ds, device poll %ds, full sync %ds", heartbeat, poll, fullSync)
end

-- ─── Pairing ──────────────────────────────────────────────────────────────────

--- Reflects the current pairing state into the read-only properties.
local function showPairingState()
  if isPaired() then
    local name = persist:get(PROPERTY_NAME_KEY, "") or ""
    UpdateProperty("Paired Property", name ~= "" and string.format("%s (%s)", name, propertyId()) or propertyId())
  else
    UpdateProperty("Paired Property", "Not paired")
  end
end

--- Redeems a pairing code for a long-lived device token.
---
--- This is the only unauthenticated call the driver makes. The code is minted by
--- SmartBuildOS against a specific property, is single-use, and is short-lived,
--- so the window in which it is worth anything to an attacker is the window
--- between the dealer generating it and pasting it in. The token that comes back
--- is what actually grants access, and it is stored encrypted and never logged.
---
--- @param code string The pairing code the dealer pasted in.
local function redeemPairingCode(code)
  local url = ingestUrl("pair")
  if not url then
    UpdateProperty("Connection Status", "API URL is not set")
    return
  end

  log:info("Redeeming pairing code")
  UpdateProperty("Connection Status", "Pairing...")

  http
    :post(url, {
      code = code,
      system = {
        controller_type = C4:GetSystemType(),
        os_version = C4:GetVersionInfo().version,
        driver_version = C4:GetDriverConfigInfo("version"),
        device_id = C4:GetDeviceID(),
        director_name = C4:GetDeviceData(C4:GetDeviceID(), "name"),
      },
    }, { ["Content-Type"] = "application/json" }, { timeout = REQUEST_TIMEOUT })
    :next(function(response)
      local body = response.body
      if type(body) == "string" then
        local ok, decoded = pcall(function()
          return JSON:decode(body)
        end)
        body = ok and decoded or nil
      end

      if type(body) ~= "table" or IsEmpty(body.token) or IsEmpty(body.property_id) then
        -- A 2xx with an unusable body is a server-side contract break, not a
        -- dealer error. Say so plainly rather than leaving "Pairing..." up.
        UpdateProperty("Connection Status", "Pairing failed - unexpected response")
        log:error("Pairing response did not contain a token and property id")
        return
      end

      persist:set(TOKEN_KEY, body.token, true)
      persist:set(PROPERTY_KEY, body.property_id)
      persist:set(PROPERTY_NAME_KEY, body.property_name or "")
      showPairingState()
      C4:FireEvent("Paired")
      log:info("Paired to property %s", tostring(body.property_id))

      -- The code is spent. Clearing it keeps it out of the project file and
      -- makes the field obviously reusable for a future re-pair.
      UpdateProperty("Pairing Code", "", true)

      scheduleTimers()
      sendFullSync()
      sendHeartbeat()
    end, function(err)
      local code_ = err and err.code
      if code_ == 404 or code_ == 410 then
        UpdateProperty("Connection Status", "Pairing failed - code is invalid or expired")
      elseif type(code_) == "number" then
        UpdateProperty("Connection Status", string.format("Pairing failed - HTTP %d", code_))
      else
        UpdateProperty("Connection Status", "Pairing failed - SmartBuildOS unreachable")
      end
      log:error("Pairing failed: %s", tostring(err and (err.error or err.code) or err))
    end)
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

  for p, _ in pairs(Properties) do
    local status, err = pcall(OnPropertyChanged, p)
    if not status and err then
      log:error("Error in OnPropertyChanged for property '%s': %s", p, err or "unknown error")
    end
  end

  gInitialized = true
  UpdateProperty("Driver Status", "Online")
  showPairingState()

  --#ifndef DRIVERCENTRAL
  SetTimer("UpdateCheck", 30 * 60 * ONE_SECOND, function()
    if toboolean(Properties["Automatic Updates"]) then
      log:info("Checking for driver update")
      UpdateDrivers()
    end
  end, true)
  --#endif

  if not isPaired() then
    setConnected(false, "Not paired")
    log:warn("SmartBuildOS Connector is not paired. Paste a pairing code from SmartBuildOS.")
    return
  end

  scheduleTimers()
  -- Report in immediately so a controller that just rebooted shows up in
  -- SmartBuildOS without waiting out a full heartbeat interval.
  sendFullSync()
  sendHeartbeat()
end

function OnDriverDestroyed()
  log:trace("OnDriverDestroyed()")
  CancelTimer(HEARTBEAT_TIMER)
  CancelTimer(DEVICE_POLL_TIMER)
  CancelTimer(FULL_SYNC_TIMER)
end

-- ─── Property handlers ────────────────────────────────────────────────────────

function OPC.Driver_Status(propertyValue)
  log:trace("OPC.Driver_Status('%s')", propertyValue)
  if not gInitialized then
    UpdateProperty("Driver Status", "Initializing", false)
    return
  end
end

function OPC.Driver_Version(propertyValue)
  log:trace("OPC.Driver_Version('%s')", propertyValue)
  C4:UpdateProperty("Driver Version", C4:GetDriverConfigInfo("version"))
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
  if log:getLogLevel() >= 6 and log:isPrintEnabled() then
    DEBUGPRINT = true
    DEBUG_TIMER = true
    DEBUG_RFN = true
    DEBUG_URL = true
  else
    DEBUGPRINT = false
    DEBUG_TIMER = false
    DEBUG_RFN = false
    DEBUG_URL = false
  end
end

--- A non-empty pairing code is a request to pair. The handler runs on every
--- property load, so the empty case has to be a no-op or clearing the field
--- would itself look like a pairing attempt.
function OPC.Pairing_Code(propertyValue)
  log:trace("OPC.Pairing_Code(<redacted>)")
  if not gInitialized then
    return
  end
  local code = (propertyValue or ""):gsub("%s+", "")
  if code == "" then
    return
  end
  redeemPairingCode(code)
end

function OPC.API_URL(propertyValue)
  log:trace("OPC.API_URL('%s')", propertyValue)
  if gInitialized and isPaired() then
    scheduleTimers()
    sendHeartbeat()
  end
end

function OPC.Heartbeat_Interval(propertyValue)
  log:trace("OPC.Heartbeat_Interval('%s')", propertyValue)
  if gInitialized and isPaired() then
    scheduleTimers()
  end
end

function OPC.Device_Poll_Interval(propertyValue)
  log:trace("OPC.Device_Poll_Interval('%s')", propertyValue)
  if gInitialized and isPaired() then
    scheduleTimers()
  end
end

--- Editing the endpoint list re-baselines immediately rather than waiting for
--- the next poll, so a dealer who just added a switch sees it appear.
function OPC.Monitored_Endpoints(propertyValue)
  log:trace("OPC.Monitored_Endpoints('%s')", propertyValue)
  if gInitialized and isPaired() then
    pollDeviceState()
  end
end

function OPC.Full_Sync_Interval(propertyValue)
  log:trace("OPC.Full_Sync_Interval('%s')", propertyValue)
  if gInitialized and isPaired() then
    scheduleTimers()
  end
end

--#ifndef DRIVERCENTRAL
function OPC.Automatic_Updates(propertyValue)
  log:trace("OPC.Automatic_Updates('%s')", propertyValue)
end

function OPC.Update_Channel(propertyValue)
  log:trace("OPC.Update_Channel('%s')", propertyValue)
end

--- Updates this driver from its GitHub releases.
--- `updateAll` filters to drivers actually installed in the project and writes
--- into C4Z_ROOT itself, so there is no file-directory setup to do here.
--- @param forceUpdate? boolean Re-download even when already current.
function UpdateDrivers(forceUpdate)
  log:trace("UpdateDrivers(%s)", forceUpdate)
  githubUpdater
    :updateAll(DRIVER_GITHUB_REPO, DRIVER_FILENAMES, Properties["Update Channel"] == "Prerelease", forceUpdate)
    :next(function(updatedDrivers)
      if not IsEmpty(updatedDrivers) then
        log:info("Updated driver(s): %s", table.concat(updatedDrivers, ","))
      else
        log:info("No driver updates available")
      end
    end, function(err)
      log:error("An error occurred updating drivers: %s", tostring(err))
    end)
end
--#endif

-- ─── Actions and programming commands ─────────────────────────────────────────

function EC.TEST_CONNECTION()
  log:trace("EC.TEST_CONNECTION()")
  if not isPaired() then
    log:error("Cannot test connection: driver is not paired")
    setConnected(false, "Not paired")
    return
  end
  send("heartbeat", { kind = "test" }, "connection test")
end

function EC.SEND_HEARTBEAT()
  log:trace("EC.SEND_HEARTBEAT()")
  sendHeartbeat()
end

function EC.SEND_FULL_SYNC()
  log:trace("EC.SEND_FULL_SYNC()")
  sendFullSync()
end

function EC.POLL_DEVICES()
  log:trace("EC.POLL_DEVICES()")
  pollDeviceState()
end

--- Forgets the token locally. SmartBuildOS is told first so the property stops
--- expecting heartbeats, but a failure there must not strand the driver in a
--- paired state it cannot leave -- the local wipe happens either way.
function EC.UNPAIR()
  log:trace("EC.UNPAIR()")
  if isPaired() then
    send("unpair", { kind = "unpair" }, "unpair notice")
  end
  persist:delete(TOKEN_KEY)
  persist:delete(PROPERTY_KEY)
  persist:delete(PROPERTY_NAME_KEY)
  CancelTimer(HEARTBEAT_TIMER)
  CancelTimer(DEVICE_POLL_TIMER)
  CancelTimer(FULL_SYNC_TIMER)
  gDeviceState = {}
  gHasSnapshot = false
  showPairingState()
  setConnected(false, "Not paired")
  log:info("Unpaired from SmartBuildOS")
end

--#ifndef DRIVERCENTRAL
function EC.UPDATE_DRIVERS()
  log:trace("EC.UPDATE_DRIVERS()")
  UpdateDrivers(true)
end
--#endif

--- Lets Composer programming push a named event into SmartBuildOS, so a dealer
--- can surface things the driver has no way to observe on its own (a rack door
--- contact, a UPS on battery, a "client called" button).
--- @param tParams table<string, string>
function EC.SEND_EVENT(tParams)
  tParams = tParams or {}
  local name = tParams.NAME or ""
  if name == "" then
    log:warn("SEND_EVENT called with no NAME; ignoring")
    return
  end
  log:info("Sending event '%s'", name)
  send("event", {
    kind = "event",
    name = name,
    detail = tParams.DETAIL or "",
  }, "event '" .. name .. "'")
end

-- ─── Conditionals ─────────────────────────────────────────────────────────────

function TC.SMARTBUILDOS_CONNECTED()
  return gConnected
end

function TC.SMARTBUILDOS_PAIRED()
  return isPaired()
end
