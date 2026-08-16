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
-- REQUIRED, even though nothing here names it: `lib.http` calls the GLOBAL
-- `urlDo`, which this module defines. Without it every request throws
-- "attempt to call a nil value" inside the handler's xpcall, which prints and
-- swallows it — so the driver sits on whatever status it set before the call
-- (a pairing attempt hangs on "Pairing...") and nothing else ever happens.
require("drivers-common-public.global.url")

JSON = require("JSON")

--- SSDP discovery of devices that are NOT in the Control4 project.
---
--- Composer's "Discovered" list is not reachable from a driver — there is no
--- documented API for it — so the driver announces for itself. This module
--- creates its own UDP bindings in the 6900-6999 range via
--- CreateNetworkConnection and hooks the RFN/OCS tables that
--- drivers-common-public.global.handlers provides, so nothing has to be
--- declared in driver.xml.
local ssdpModule = require("drivers-common-public.module.ssdp")

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

--- `addresstype` values on a network binding, mapped to labels the platform can
--- group on. Same enum the DriverWorks reference documents for connection type.
--- Anything unrecognised falls back to "ip", which is what a binding carrying an
--- `addr` overwhelmingly is.
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
--- @type boolean Whether the empty-project diagnosis has already been sent.
local gDiagnosedEmpty = false
--- Devices heard announcing on the network that are not in the project, keyed
--- the same way project devices are.
--- @type table<string, table<string, any>>
local gDiscovered = {}
--- @type table|nil The live SSDP searcher, when discovery is switched on.
local gFinder = nil

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
--- pasting "https://app.smartbuildos.io/" does not silently produce "//api".
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

--- Whether a binding's address is one a device can actually be reached at.
---
--- `NOT_SET` is Control4's literal placeholder for a binding that exists but has
--- never been addressed — a driver added to the project and not yet pointed at
--- hardware. Treating that as an address makes an unconfigured device look like
--- a monitored one, and then like an offline one.
--- @param addr any
--- @return boolean
local function isRealAddress(addr)
  if type(addr) ~= "string" then
    return false
  end
  local trimmed = addr:gsub("^%s+", ""):gsub("%s+$", "")
  return trimmed ~= "" and trimmed ~= "NOT_SET" and trimmed ~= "0.0.0.0"
end

--- Finds the network-binding table for a device, or nil when it has none.
---
--- ── WHAT COUNTS AS ONE ──────────────────────────────────────────────────────
---
--- The presence of an `addr` KEY, whatever its value. A binding that carries an
--- address field is a network binding even when the address is `NOT_SET` —
--- Control4's placeholder for a driver added to the project and not yet pointed
--- at hardware. Those devices are real, and hiding them was wrong: they are
--- exactly the "discovered but not configured" list a dealer wants to see.
---
--- Whether the address is USABLE is a separate question, answered by
--- `isRealAddress` at the call site, and it decides whether the device has a
--- known state or an unknown one. It must not decide whether the device exists.
---
--- ── WHY THE SEARCH IS BOUNDED THE WAY IT IS ─────────────────────────────────
---
--- `GetBindingsByDevice` nests one level: `{bindings = {...}}`. An unbounded
--- walk of that for 214 devices — two API calls each, no early exit — is enough
--- work to stall the sync entirely, which is what an over-eager version of this
--- did. So the known shape is checked directly first, and the generic walk is a
--- shallow fallback rather than the primary path.
---
--- @param deviceId number
--- @return table<string, any>|nil binding
local function networkBinding(deviceId)
  --- True for a table that describes a network link, addressed or not.
  local function isBinding(node)
    return type(node) == "table" and node.addr ~= nil
  end

  --- Checks the documented location first, then one shallow level below it.
  local function search(raw)
    if isBinding(raw) then
      return raw
    end
    if type(raw) ~= "table" then
      return nil
    end

    -- The real shape: `{bindings = { <binding>, ... }}`.
    local list = type(raw.bindings) == "table" and raw.bindings or raw
    for _, entry in pairs(list) do
      if isBinding(entry) then
        return entry
      end
    end

    -- One level deeper, for a shape neither the docs nor this controller show.
    for _, entry in pairs(list) do
      if type(entry) == "table" then
        for _, inner in pairs(entry) do
          if isBinding(inner) then
            return inner
          end
        end
      end
    end
    return nil
  end

  local getters = {
    function()
      return C4:GetNetworkBindingsByDevice(deviceId)
    end,
    function()
      return C4:GetBindingsByDevice(deviceId)
    end,
  }

  for _, get in ipairs(getters) do
    local ok, raw = pcall(get)
    if ok and type(raw) == "table" then
      local binding = search(raw)
      if binding ~= nil then
        return binding
      end
    end
  end
  return nil
end

--- Reads every project device and whatever Director knows about its link.
---
--- `C4:GetDevices({})` enumerates the whole project — the only system-wide
--- device list available to a driver. `C4:GetBindingsByDevice(id)` then returns
--- that device's network binding, carrying `addr` and `status`
--- ("online"/"offline"), and it accepts ANY device id rather than only this
--- driver's.
---
--- ⚠ `C4:GetNetworkConnections()` is NOT the API for this, despite appearances.
--- It returns connections for the CALLING device only, so a driver with no
--- bindings of its own — like this one — gets an empty table and reports zero
--- devices. That is exactly what shipped first.
---
--- Devices with no network binding at all (IR-controlled sources, serial-only
--- gear, dumb loads) are skipped rather than invented: Director has no link
--- state for them, and reporting them as online would be a guess presented as a
--- fact.
---
--- @return table<string, table<string, any>> devices Keyed by "c4:<device id>".
local function readDeviceState()
  local devices = {}
  for rawId, device in pairs(C4:GetDevices({}) or {}) do
    local id = tointeger(rawId)
    if id ~= nil then
      local binding = networkBinding(id)
      if binding ~= nil then
        -- `status` is the authority. Anything that is not the string "online"
        -- is treated as down, so an unexpected value fails visible rather than
        -- silently reporting a dead device as healthy.
        local status = tostring(binding.status or ""):lower()
        -- An unaddressed binding has no reachability to report. Sending
        -- `online = false` for it would be a fabricated outage, so the address
        -- is sent as-is and the platform reads a missing one as "state unknown".
        local addressable = isRealAddress(binding.addr)
        devices["c4:" .. id] = {
          -- Driver-local: whether this device has a state worth counting. The
          -- platform derives the same thing from the address, so this is not
          -- sent; it exists so the Devices Offline property does not count
          -- devices that were never installed.
          addressable = addressable,
          key = "c4:" .. id,
          source = "director",
          device_id = id,
          name = device.deviceName or device.name,
          online = addressable and status == "online" or false,
          connection_type = CONNECTION_TYPES[tointeger(binding.addresstype) or -1] or "ip",
          address = binding.addr,
          binding_id = tointeger(binding.networkbindingid),
          network_status = status ~= "" and status or nil,
          room = device.roomName,
          driver_file = device.driverFileName,
        }
      end
    end
  end
  return devices
end

-- ─── Non-Control4 endpoints, via ICMP ─────────────────────────────────────────

--- Parses the Non Control4 Devices property.
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
  for entry in (Properties["Non Control4 Devices"] or ""):gmatch("[^,]+") do
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
    log:warn("This controller's OS does not provide the ping API; skipping %d non-Control4 device(s)", #endpoints)
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

  -- Discovered devices are merged last and never overwrite a project device.
  -- A Sonos that IS in the project is better described by its binding — room,
  -- device id, control state — than by its SSDP announcement.
  pingEndpoints(function(pinged)
    for key, device in pairs(pinged) do
      devices[key] = device
    end
    for key, device in pairs(gDiscovered) do
      if devices[key] == nil then
        devices[key] = device
      end
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
    -- An unaddressed device has no reachability to be down. Counting it here
    -- is how a project full of unconfigured drivers reads as a site-wide
    -- outage. `addressable` is nil for ping targets, which are addressed by
    -- definition, so they still count.
    if not device.online and device.addressable ~= false then
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

    -- A project with no visible devices is either a genuinely empty project or a
    -- driver that cannot see it. Those look identical from the platform, so say
    -- which — once per driver load, because this is a diagnosis, not telemetry.
    if #list == 0 and not gDiagnosedEmpty then
      gDiagnosedEmpty = true
      log:warn("Full sync found no devices; reporting diagnostics")
      reportDiagnostics(true)
    end
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

-- ─── Discovery ────────────────────────────────────────────────────────────────

--- Turns one SSDP announcement into a device record.
---
--- An announcement is not a project device: there is no device id, no room and
--- no control binding, only what the device says about itself. The address is
--- what makes it useful, so anything without one is dropped rather than shown
--- as an unidentifiable row.
---
--- @param uuid string
--- @param device table<string, any>
--- @return table<string, any>|nil
local function discoveredDevice(uuid, device)
  local ip = device.IP
  if not isRealAddress(ip) then
    return nil
  end
  -- Keyed by ADDRESS, not by uuid, so a discovered device and a project device
  -- at the same address collapse to one entry rather than appearing twice —
  -- and so the key is stable if the device re-announces with a new uuid.
  return {
    key = "discovered:" .. ip,
    source = "discovered",
    name = device.friendlyName or device.modelName or device.manufacturer or ip,
    online = true,
    connection_type = "ip",
    address = ip,
    port = tointeger(device.PORT),
    firmware = nil,
    -- SSDP tells us what a device claims to be, which is often the only label
    -- a dealer will ever have for something not in the project.
    device_status = device.manufacturer and device.modelName and (device.manufacturer .. " " .. device.modelName)
      or device.modelName
      or device.manufacturer,
  }
end

--- Starts or stops SSDP discovery to match the property.
local function applyDiscovery()
  local wanted = Properties["Discover Network Devices"] == "On"

  if not wanted then
    if gFinder then
      pcall(function()
        gFinder:StopDiscovery()
      end)
      gFinder = nil
    end
    if next(gDiscovered) ~= nil then
      gDiscovered = {}
      log:info("Discovery off; forgetting discovered devices")
      sendFullSync()
    end
    return
  end

  if gFinder then
    return
  end

  -- `upnp:rootdevice` rather than `ssdp:all`: root devices are the physical
  -- boxes, where ssdp:all also returns every embedded service each one exposes
  -- and would list a single speaker five times.
  local ok, finder = pcall(function()
    return ssdpModule:new("upnp:rootdevice")
  end)
  if not ok or finder == nil then
    log:error("Could not start discovery: %s", tostring(finder))
    return
  end

  gFinder = finder
  finder:SetUpdateDevicesFunction(function(_, devices)
    local next_ = {}
    local count = 0
    for uuid, device in pairs(devices or {}) do
      local record = discoveredDevice(uuid, device)
      if record then
        next_[record.key] = record
        count = count + 1
      end
    end
    gDiscovered = next_
    log:info("Discovery: %d device(s) announcing on the network", count)
    -- A snapshot rather than a delta: discovery replaces the whole discovered
    -- set each time, and a delta cannot express "these ones stopped answering".
    sendFullSync()
  end)

  local started = pcall(function()
    finder:StartDiscovery()
  end)
  log:info("Network discovery %s", started and "started" or "could not be started")
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

  registerSystemEvents()
  applyDiscovery()
  scheduleTimers()
  -- Report in immediately so a controller that just rebooted shows up in
  -- SmartBuildOS without waiting out a full heartbeat interval.
  sendFullSync()
  sendHeartbeat()
end

--- Director's own online/offline notifications.
---
--- 48/49 fire the moment a device's link changes, so an outage is reported in
--- seconds rather than at the next poll. Polling stays as the backstop: an event
--- missed while the driver was reloading would otherwise never be reconciled,
--- and the periodic snapshot is what repairs that.
---
--- 17/18 cover a binding being added or removed — a device joining or leaving
--- the project — and 78 is SDDP, which is how Control4 learns about announcing
--- devices in the first place.
local SYSTEM_EVENTS = {
  [17] = "OnNetworkBindingAdded",
  [18] = "OnNetworkBindingRemoved",
  [48] = "OnDeviceOnline",
  [49] = "OnDeviceOffline",
  [78] = "OnSDDPDeviceStatus",
}

local function registerSystemEvents()
  if C4.RegisterSystemEvent == nil then
    log:warn("This controller's OS does not provide RegisterSystemEvent; falling back to polling only")
    return
  end
  for id, name in pairs(SYSTEM_EVENTS) do
    local ok, err = pcall(function()
      -- Device id 0 registers for the event system-wide rather than for one
      -- device, which is the whole point here.
      C4:RegisterSystemEvent(id, 0)
    end)
    if ok then
      log:debug("Registered for system event %d (%s)", id, name)
    else
      log:warn("Could not register for system event %d (%s): %s", id, name, tostring(err))
    end
  end
end

--- Director calls this for every event registered above.
---
--- The payload is documented as event-specific and "in most cases can be
--- ignored", and it does not reliably say WHICH device moved. So this does not
--- try to parse it: it debounces into a single poll, which reads the authorative
--- state for the whole project anyway. A burst of twenty devices coming back
--- after a switch reboots therefore costs one sync, not twenty.
function OnSystemEvent(data)
  log:debug("OnSystemEvent(%s)", tostring(data))
  if not isPaired() then
    return
  end
  CancelTimer("SystemEventDebounce")
  SetTimer("SystemEventDebounce", 5 * ONE_SECOND, function()
    log:info("Director reported a device state change; polling")
    pollDeviceState()
  end)
end

function OnDriverDestroyed()
  log:trace("OnDriverDestroyed()")
  CancelTimer(HEARTBEAT_TIMER)
  CancelTimer(DEVICE_POLL_TIMER)
  CancelTimer(FULL_SYNC_TIMER)
  if gFinder then
    pcall(function()
      gFinder:StopDiscovery()
    end)
    gFinder = nil
  end
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

--- Editing the list re-baselines immediately rather than waiting for the next
--- poll, so a dealer who just added a switch sees it appear.
--- @param propertyValue string
function OPC.Discover_Network_Devices(propertyValue)
  log:trace("OPC.Discover_Network_Devices('%s')", propertyValue)
  if gInitialized then
    applyDiscovery()
  end
end

function OPC.Non_Control4_Devices(propertyValue)
  log:trace("OPC.Non_Control4_Devices('%s')", propertyValue)
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

--- Reports what Director actually returns, to the log AND to SmartBuildOS.
---
--- Two enumeration APIs have now been read the wrong way from the reference
--- (`GetNetworkConnections` is per-caller; `GetDevices` may not be returning
--- what its examples imply), and each wrong reading cost a release. Guessing a
--- third time is not a plan, so this tries every documented way to enumerate a
--- project, records what each one yields, and ships the answer somewhere it can
--- be read without anyone copying text out of a Lua window.
---
--- @param lines string[] Accumulator, also printed.
local function diagnose(lines)
  local function note(fmt, ...)
    local line = select("#", ...) > 0 and string.format(fmt, ...) or fmt
    table.insert(lines, line)
    log:print(line)
  end

  note(
    "controller=%s os=%s driver=%s",
    tostring(C4:GetSystemType()),
    tostring(C4:GetVersionInfo().version),
    tostring(C4:GetDriverConfigInfo("version"))
  )

  --- Counts a table's entries whether it is a list or a map.
  local function count(t)
    if type(t) ~= "table" then
      return -1
    end
    local n = 0
    for _ in pairs(t) do
      n = n + 1
    end
    return n
  end

  --- Every way the reference documents to enumerate a project. Whichever
  --- returns something is the one to build on.
  local attempts = {
    {
      "GetDevices({})",
      function()
        return C4:GetDevices({})
      end,
    },
    {
      "GetDevices()",
      function()
        return C4:GetDevices()
      end,
    },
    {
      "GetDevices({},nil)",
      function()
        return C4:GetDevices({}, nil)
      end,
    },
    {
      "GetNetworkConnections()",
      function()
        return C4:GetNetworkConnections()
      end,
    },
  }

  local devices = nil
  for _, attempt in ipairs(attempts) do
    local ok, result = pcall(attempt[2])
    if not ok then
      note("%s -> ERROR %s", attempt[1], tostring(result))
    else
      note("%s -> %s, %d entr(ies)", attempt[1], type(result), count(result))
      if devices == nil and type(result) == "table" and count(result) > 0 then
        devices = result
      end
    end
  end

  -- GetProjectItems returns XML, so its size alone says whether the project is
  -- visible to this driver at all.
  local okItems, items = pcall(function()
    return C4:GetProjectItems("DEVICES", "LIMIT_DEVICE_DATA", "NO_ROOT_TAGS")
  end)
  if okItems and type(items) == "string" then
    note("GetProjectItems -> %d chars; head=%s", #items, items:sub(1, 160))
  else
    note("GetProjectItems -> %s %s", tostring(okItems), tostring(items))
  end

  if devices == nil then
    note("NO enumeration returned anything. This driver cannot see the project.")
    return
  end

  local shown = 0
  for rawId, device in pairs(devices) do
    if shown >= 6 then
      break
    end
    shown = shown + 1
    local id = tointeger(rawId)
    local okB, raw = pcall(function()
      return C4:GetBindingsByDevice(id or rawId)
    end)
    note(
      "dev[%s] key=%s name=%s -> bindings %s: %s",
      tostring(rawId),
      type(rawId),
      tostring(device and (device.deviceName or device.name)),
      tostring(okB),
      okB and (type(raw) == "table" and JSON:encode(raw):sub(1, 1200) or tostring(raw)) or tostring(raw)
    )
  end
end

--- Runs the diagnosis and, when paired, posts it so it can be read remotely.
--- Chunked because the event endpoint bounds `detail`; one line per event keeps
--- each well inside that and keeps them readable in order.
--- @param toCloud boolean
local function reportDiagnostics(toCloud)
  local lines = {}
  local ok, err = pcall(diagnose, lines)
  if not ok then
    table.insert(lines, "diagnose() itself failed: " .. tostring(err))
    log:error("diagnose() failed: %s", tostring(err))
  end

  if not toCloud or not isPaired() then
    return
  end
  for i, line in ipairs(lines) do
    send("event", {
      kind = "event",
      name = string.format("diagnostics %02d", i),
      detail = line:sub(1, 480),
    }, "diagnostic line " .. i)
  end
end

function EC.REPORT_DIAGNOSTICS()
  log:trace("EC.REPORT_DIAGNOSTICS()")
  reportDiagnostics(true)
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
