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
local Rooms = require("telemetry.rooms")
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
local NETWORK_SCAN_TIMER = "SmartBuildOSNetworkScan"

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

--- ── SUBNET SWEEP BUDGET ─────────────────────────────────────────────────────
---
--- A /24 is 254 addresses and Director runs the house, so the sweep is bounded
--- on both axes rather than fired all at once.
---
--- ONE round, not three. `PING_ROUNDS` is tuned for MONITORING, where a dropped
--- packet must not read as an outage. A sweep asks a different question --
--- "is anything at this address" -- and a live host answers on the first round.
--- Only DEAD addresses cost the full timeout, and on a home subnet most
--- addresses are dead, so this is the difference between a sweep that takes ~1
--- minute and one that takes ~3.
local SCAN_ROUNDS = 1

--- How many pings are in flight at once. 254 concurrent ping clients is the
--- obvious implementation and the wrong one: it is a burst of socket
--- allocations on a controller whose day job is running somebody's home. At 24
--- a /24 completes in roughly 11 waves.
local SCAN_CONCURRENCY = 24

--- Ceiling on addresses per sweep, across all subnets. A misconfigured mask
--- must not turn into a /16 walk.
local SCAN_MAX_HOSTS = 512

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
--- Counter making each ping watchdog timer name unique. `SetTimer` is keyed by
--- name, so a shared one lets a second overlapping read cancel the first's only
--- way out of a stranded ping.
--- @type number
local gPingTimeoutSeq = 0
--- Devices heard announcing on the network that are not in the project, keyed
--- the same way project devices are.
--- @type table<string, table<string, any>>
local gDiscovered = {}
--- @type table|nil The live SSDP searcher, when discovery is switched on.
local gFinder = nil

--- Room activity tracking. Wall clock for what gets stored, monotonic for
--- durations — a controller whose time is corrected mid-session would otherwise
--- record a negative or wildly long span.
local gRooms = Rooms.new(function()
  return C4:GetTickCount()
end, function()
  return os.date("!%Y-%m-%dT%H:%M:%SZ")
end)

--- Monitoring configuration, as told to us by the platform in the heartbeat
--- response. Defaults are deliberately OFF: this records behavioural data about
--- someone's home and starts because a dealer chose it.
local gMonitor =
  { enabled = false, room_variables = {}, room_ids = {}, climate_enabled = true, climate_sample_minutes = 15 }
--- room id -> { [variableId] = variableName } for the variables we listen to.
local gRoomVarNames = {}
--- room id -> name, from the project hierarchy.
local gRoomNames = {}
--- room id -> thermostat device id, from the room's TEMPERATURE_ID.
local gRoomThermostat = {}
--- @type boolean Whether listeners are currently registered.
local gListening = false

local TELEMETRY_TIMER = "SmartBuildOSTelemetry"
local CLIMATE_TIMER = "SmartBuildOSClimate"

-- Declared here because the heartbeat handler applies configuration, and the
-- functions that act on it are defined further down.
local applyMonitoring
local sendCatalogue

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
--- @param onOk fun(body: table)|nil Called with the decoded response body.
local function send(path, payload, description, onOk)
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

    if onOk then
      local body = response.body
      if type(body) == "string" then
        local okDecode, decoded = pcall(function()
          return JSON:decode(body)
        end)
        body = okDecode and decoded or nil
      end
      if type(body) == "table" then
        pcall(onOk, body)
      end
    end
  end, function(err)
    -- Http:request rejects on *any* non-2xx as well as on transport failure, so
    -- this one handler covers both. The distinction matters to whoever reads
    -- Connection Status: a 401 means the token was revoked and a 404 means the
    -- property is gone, and those need different fixes than "no internet".
    gFailures = gFailures + 1
    local code = err and err.code
    local reason
    if type(code) == "number" then
      reason = string.format("HTTP %d: %s", code, tostring(err.body))
      setConnected(false, string.format("HTTP %d", code))
      log:error("%s rejected with HTTP %d: %s", description, code, tostring(err.body))
    else
      reason = tostring(err and err.error or err)
      setConnected(false, "Unreachable")
      log:error("%s failed after %d attempt(s): %s", description, gFailures, reason)
    end
    C4:FireEvent("Sync Failed")

    -- Tell the PLATFORM, not just the Lua window and a Composer event.
    --
    -- A device sync stopped landing on 2026-08-17 and nothing anywhere said so.
    -- Heartbeats and events kept arriving, so the controller looked healthy from
    -- SmartBuildOS while its device state sat frozen for hours -- and the only
    -- record of the failure was `C4:FireEvent("Sync Failed")`, which is a
    -- Composer programming hook that reaches nobody, plus a log line nobody is
    -- reading at 3am.
    --
    -- Reported on the EVENT path deliberately: it is a different endpoint with
    -- its own budget, and it is proven to work in exactly the conditions where
    -- the device path does not. A diagnostic that travels the same road as the
    -- thing it is diagnosing is no diagnostic.
    --
    -- The `path ~= "event"` guard is load-bearing. Without it a platform outage
    -- turns every failed report into another failed report, and one dead network
    -- becomes an unbounded retry storm out of a house.
    if path ~= "event" and isPaired() then
      send("event", {
        kind = "event",
        name = "sync failed",
        detail = string.format("%s: %s", description, reason):sub(1, 400),
      }, "sync failure report")
    end
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

--- Pulls a MAC address out of a network binding's `uuid`.
---
--- SSDP bindings carry it on the end of an identifier
--- ("Amplifier-EA-HYB-AMP-2D-1200-D4:6A:91:4F:16:55"); Zigbee bindings put a
--- 16-hex-digit address there instead ("000fff0000d4f655"). Matching the MAC
--- SHAPE rather than taking the tail keeps the second from being mistaken for
--- the first.
---
--- Returned lowercase and colon-free, matching `installed_devices.mac_normalized`
--- so the two can be compared without either side normalising again.
--- @return string|nil
function macFromUuid(uuid)
  if type(uuid) ~= "string" or uuid == "" then
    return nil
  end
  -- The separator must be CONSISTENT, enforced with a back-reference. Allowing
  -- ":" and "-" to mix matched straight across the model number in
  -- "...-2D-1200-D4:6A:91:4F:16:55" and produced "00d46a914f16" — a
  -- well-formed MAC that belongs to no device, which would have silently
  -- mis-joined this device to whatever else happened to carry it.
  local a, sep, b, c, d, e, f = uuid:match("(%x%x)([:%-])(%x%x)%2(%x%x)%2(%x%x)%2(%x%x)%2(%x%x)")
  if a == nil then
    return nil
  end
  return (a .. b .. c .. d .. e .. f):lower()
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
          -- MEASURED 2026-08-17. The `uuid` on an SSDP-discovered binding
          -- carries the device's MAC on the end of its identifier:
          --
          --   "Amplifier-EA-HYB-AMP-2D-1200-D4:6A:91:4F:16:55"
          --
          -- That MAC is the ONLY identifier Control4 shares with UniFi and with
          -- `installed_devices` -- Control4 knows a device by its binding and
          -- UniFi by its MAC, and until now the two could only be matched on IP,
          -- which DHCP moves and which only 14 of 72 devices even had. Five
          -- probe runs went into finding it, so it is extracted rather than
          -- left in a string nobody parses.
          --
          -- Zigbee bindings put their own address in `uuid` instead
          -- ("000fff0000d4f655"), which is why this matches the MAC SHAPE
          -- rather than taking the tail of the string.
          mac = macFromUuid(binding.uuid),
          -- The SSDP type is what Control4 itself calls the device
          -- ("Amplifier", "c4:control4_light:C4-V-ODIM120"). A far better
          -- classifier than the device name, which is whatever an installer
          -- typed -- and it is how lighting, dimmers and keypads identify
          -- themselves without any name matching.
          device_type = binding.ssdptype ~= "" and binding.ssdptype or nil,
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
  --
  -- The timer name must be UNIQUE PER CALL. `SetTimer` is keyed by name, so a
  -- second `readAllState` starting while the first is still pinging -- the poll
  -- timer and a full sync overlapping, which is routine -- would replace the
  -- first call's watchdog and leave it with no way back. Its `done` would then
  -- never run, and because nothing throws, the whole device sync would go quiet
  -- with no error anywhere. That is precisely the shape of the outage this
  -- driver spent 2026-08-17 in.
  gPingTimeoutSeq = gPingTimeoutSeq + 1
  local timerName = "PingTimeout" .. gPingTimeoutSeq
  SetTimer(timerName, (PING_ROUNDS * 5 + 10) * ONE_SECOND, function()
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

-- ─── Subnet sweep ─────────────────────────────────────────────────────────────
--
-- ── WHAT THIS IS AND IS NOT ─────────────────────────────────────────────────
--
-- It answers "what else is on this network" -- the gap between the 214 devices
-- Control4 knows about and the 173 the network inventory holds. It is an
-- INVENTORY question, not a monitoring one, and the difference decides where
-- the results are allowed to go.
--
-- A swept address that answers ICMP gives an IP and nothing else. No MAC, no
-- name, no identity. So it does NOT solve the Control4-to-installed_devices
-- join -- that still needs the binding MAC. Anyone reading a sweep result as
-- device identity will be matching on an address DHCP is free to move tomorrow.
--
-- ── WHY SILENCE IS NOT ABSENCE ──────────────────────────────────────────────
--
-- Plenty of real devices never answer a ping: host firewalls drop ICMP by
-- default on Windows, and a fair number of IoT boxes ignore it. A sweep
-- therefore UNDERCOUNTS, and "did not answer" must never render as "not
-- present". Same rule as everywhere else here -- zero and unknown are different
-- and must not look the same.
--
-- ── AND WHY IT IS NOT BORROWED FROM OvrC ────────────────────────────────────
--
-- Some Control4 controllers do run an OvrC agent that scans the LAN, so the box
-- demonstrably knows how. But that agent is a separate service with no
-- DriverWorks surface: there is no documented Lua call that starts an OvrC scan
-- or reads its results. This sweep therefore uses `C4:CreatePingClient`, which
-- is the one network primitive measured working on this hardware.

--- Works out which /24s to sweep from the addresses Director already gave us.
---
--- No new Control4 API and nothing guessed: the network bindings read every
--- poll already carry the controller's neighbours, so the subnet is derivable
--- from data in hand. Asking Director for its own interface configuration would
--- mean a fifth unverified API this month.
---
--- @param devices table<string, table<string, any>> Current device state.
--- @return string[] prefixes Dotted /24 prefixes, e.g. "192.168.1".
local function deriveSubnets(devices)
  local counts, order = {}, {}
  for _, device in pairs(devices or {}) do
    local a, b, c = tostring(device.address or ""):match("^(%d+)%.(%d+)%.(%d+)%.%d+$")
    -- 127/8 is loopback and 169.254/16 is what an interface gives itself when
    -- DHCP failed. Sweeping either finds the controller talking to itself and
    -- reports it as a house full of equipment.
    if a ~= nil and a ~= "127" and not (a == "169" and b == "254") then
      local prefix = a .. "." .. b .. "." .. c
      if counts[prefix] == nil then
        counts[prefix] = 0
        order[#order + 1] = prefix
      end
      counts[prefix] = counts[prefix] + 1
    end
  end

  -- Busiest first, so a capped sweep spends its budget where the equipment is
  -- rather than on whichever subnet happened to sort first.
  table.sort(order, function(x, y)
    if counts[x] ~= counts[y] then
      return counts[x] > counts[y]
    end
    return x < y
  end)
  return order
end

--- Sweeps a list of addresses with bounded concurrency, calling `done` with the
--- ones that answered.
---
--- @param hosts string[]
--- @param done fun(found: string[], answered: number, swept: number)
local function sweepHosts(hosts, done)
  if #hosts == 0 or C4.CreatePingClient == nil then
    done({}, 0, 0)
    return
  end

  local found, nextIndex, inFlight, settledCount = {}, 1, 0, 0
  local finished = false

  local function finish()
    if finished then
      return
    end
    finished = true
    table.sort(found)
    done(found, #found, settledCount)
  end

  local pump

  --- One address settled, either way. Refills the window so it stays full
  --- rather than draining to zero between waves.
  local function settle(host, online)
    settledCount = settledCount + 1
    inFlight = inFlight - 1
    if online then
      found[#found + 1] = host
    end
    if settledCount >= #hosts then
      finish()
      return
    end
    pump()
  end

  --- Fills the in-flight window, re-entrantly SAFE.
  ---
  --- The guard is not a nicety. A ping client is free to resolve synchronously
  --- -- the test shim does, and nothing documents that hardware never will --
  --- in which case `Ping` calls back into `settle` before it returns, `settle`
  --- calls back into here, and a 512-address sweep becomes 512 frames of
  --- recursion. With the guard the nested call returns immediately and the
  --- ORIGINAL while loop keeps going, so a synchronous client drains the sweep
  --- iteratively and an asynchronous one refills a slot at a time. Both are
  --- correct and neither grows the stack.
  local pumping = false
  pump = function()
    if pumping then
      return
    end
    pumping = true
    while inFlight < SCAN_CONCURRENCY and nextIndex <= #hosts do
      local host = hosts[nextIndex]
      nextIndex = nextIndex + 1
      inFlight = inFlight + 1

      local client = C4:CreatePingClient()
      if client == nil then
        settle(host, false)
      else
        -- Guarded: a client that fires twice would double-count `settledCount`
        -- and finish the sweep early on a partial result.
        local reported = false
        client:SetOnResult(function(_, success)
          if reported then
            return
          end
          reported = true
          settle(host, success == true)
        end)
        local ok = client:Ping(host, SCAN_ROUNDS)
        if ok == nil and not reported then
          reported = true
          settle(host, false)
        end
      end
    end
    pumping = false
  end

  pump()

  -- The sweep's own watchdog, on its own timer name for the reason the ping
  -- watchdog now has one: a shared name lets a second sweep cancel the first's
  -- only way out. Budget is the worst case -- every address dead, every wave
  -- paying the full round timeout -- plus margin.
  gPingTimeoutSeq = gPingTimeoutSeq + 1
  local waves = math.ceil(#hosts / SCAN_CONCURRENCY)
  SetTimer("SweepTimeout" .. gPingTimeoutSeq, (waves * (SCAN_ROUNDS * 5 + 2) + 15) * ONE_SECOND, function()
    if finished then
      return
    end
    log:warn("Subnet sweep timed out with %d of %d address(es) settled", settledCount, #hosts)
    finish()
  end)
end

--- Sweeps the derived subnets and reports what answered.
---
--- Results are reported as an EVENT rather than folded into the device
--- snapshot, and that is deliberate. A snapshot is authoritative: anything it
--- omits gets retired. Feeding sweep results into it would mean every phone,
--- laptop and guest device that answered once becomes a monitored device, and
--- then generates an appeared/removed pair every time it sleeps -- burying real
--- outages under churn and making the offline count meaningless. An integrator
--- who wants one of these actually monitored adds it to Non Control4 Devices,
--- which is what that property is for.
---
--- @param reason string What triggered this sweep, for the log and the report.
local function runNetworkScan(reason)
  local prefixes = deriveSubnets(gDeviceState)
  if #prefixes == 0 then
    log:warn("Network scan: no usable subnet could be derived from device addresses")
    if isPaired() then
      send("event", {
        kind = "event",
        name = "network scan",
        detail = "No usable subnet: no device reported a routable IPv4 address.",
      }, "network scan report")
    end
    return
  end

  local hosts, swept = {}, {}
  for _, prefix in ipairs(prefixes) do
    for octet = 1, 254 do
      if #hosts >= SCAN_MAX_HOSTS then
        break
      end
      hosts[#hosts + 1] = prefix .. "." .. octet
    end
    swept[#swept + 1] = prefix .. ".0/24"
    if #hosts >= SCAN_MAX_HOSTS then
      break
    end
  end

  log:info("Network scan (%s): sweeping %d address(es) across %s", reason, #hosts, table.concat(swept, ", "))
  local startedAt = os.time()

  sweepHosts(hosts, function(found, answered, settled)
    local elapsed = os.time() - startedAt
    UpdateProperty("Last Network Scan", string.format("%s — %d found", os.date("%Y-%m-%d %H:%M:%S"), answered))
    log:info("Network scan: %d of %d address(es) answered in %ds", answered, settled, elapsed)

    if not isPaired() then
      return
    end

    -- Which of these are already accounted for. The useful number is not "how
    -- many answered" but "how many answered that nothing in the project or the
    -- monitored list knows about" -- that is the reconciliation gap, and it is
    -- the only reason to run this at all.
    local known = {}
    for _, device in pairs(gDeviceState) do
      if device.address ~= nil then
        known[tostring(device.address)] = true
      end
    end
    local unknown = {}
    for _, host in ipairs(found) do
      if not known[host] then
        unknown[#unknown + 1] = host
      end
    end

    send("event", {
      kind = "event",
      name = "network scan",
      detail = string.format(
        "%s: %d of %d answered across %s in %ds; %d not in project or monitored list: %s",
        reason,
        answered,
        settled,
        table.concat(swept, ", "),
        elapsed,
        #unknown,
        #unknown > 0 and table.concat(unknown, " ") or "none"
      ):sub(1, 400),
    }, "network scan report")
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
  send(
    "heartbeat",
    {
      kind = "heartbeat",
      consecutive_failures = gFailures,
      devices_total = TableLength(gDeviceState),
      devices_offline = offlineCount(gDeviceState),
    },
    "heartbeat",
    function(body)
      -- The response is how configuration reaches this driver. It has no inbound
      -- channel — it sits behind the client's firewall and is never contacted —
      -- so an installer's choices in SmartBuildOS ride back on a call it already
      -- makes, rather than costing a second timer to poll for them.
      local monitor = body.monitor
      if type(monitor) ~= "table" then
        return
      end

      -- Re-registering listeners on every heartbeat would be pointless churn, so
      -- only a real change is applied.
      local before = JSON:encode(gMonitor)
      gMonitor = {
        enabled = monitor.enabled == true,
        room_variables = type(monitor.room_variables) == "table" and monitor.room_variables or {},
        room_ids = type(monitor.room_ids) == "table" and monitor.room_ids or {},
        climate_enabled = monitor.climate_enabled ~= false,
        climate_sample_minutes = tointeger(monitor.climate_sample_minutes) or 15,
      }
      if JSON:encode(gMonitor) ~= before then
        log:info(
          "Monitoring configuration changed (enabled=%s, %d variable(s))",
          tostring(gMonitor.enabled),
          #gMonitor.room_variables
        )
        applyMonitoring()
        if gMonitor.enabled then
          sendCatalogue()
        end
      end
    end
  )
end

--- (Re)arms every reporting timer from the current properties.
local function scheduleTimers()
  CancelTimer(HEARTBEAT_TIMER)
  CancelTimer(DEVICE_POLL_TIMER)
  CancelTimer(FULL_SYNC_TIMER)
  CancelTimer(NETWORK_SCAN_TIMER)

  local heartbeat = INTERVALS[Properties["Heartbeat Interval"] or ""] or INTERVALS["15m"]
  local poll = INTERVALS[Properties["Device Poll Interval"] or ""] or INTERVALS["5m"]
  local fullSync = INTERVALS[Properties["Full Sync Interval"] or ""] or INTERVALS["24h"]

  SetTimer(HEARTBEAT_TIMER, heartbeat * ONE_SECOND, sendHeartbeat, true)
  SetTimer(DEVICE_POLL_TIMER, poll * ONE_SECOND, pollDeviceState, true)
  SetTimer(FULL_SYNC_TIMER, fullSync * ONE_SECOND, sendFullSync, true)

  -- Off by DEFAULT, and stays off until somebody chooses it. A subnet sweep is
  -- the one thing this driver does that touches addresses nobody put in the
  -- project, so it is opt-in rather than something a dealer discovers running.
  local scanLabel = Properties["Network Scan"] or "Off"
  local scan = INTERVALS[scanLabel]
  if scan ~= nil then
    SetTimer(NETWORK_SCAN_TIMER, scan * ONE_SECOND, function()
      runNetworkScan("scheduled")
    end, true)
  end
  log:debug(
    "Timers armed: heartbeat %ds, device poll %ds, full sync %ds, network scan %s",
    heartbeat,
    poll,
    fullSync,
    scan ~= nil and tostring(scan) .. "s" or "off"
  )
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

-- ─── Room telemetry ───────────────────────────────────────────────────────────

--- Walks the project hierarchy and returns rooms.
---
--- The hierarchy is a NESTED tree whose child locations are keyed by id
--- alongside the `name`/`type` attributes, and `type` is a number: measured on a
--- real controller, 2=site 3=building 4=floor 8=room.
--- @return table[] rooms
local function projectRooms()
  local rooms = {}
  local okH, hierarchy = pcall(function()
    return C4:GetProjectHierarchy()
  end)
  if not okH or type(hierarchy) ~= "table" then
    return rooms
  end

  local function walk(node, depth)
    if type(node) ~= "table" or depth > 8 then
      return
    end
    for key, child in pairs(node) do
      local childId = tointeger(key)
      if childId ~= nil and type(child) == "table" then
        if tointeger(child.type) == 8 then
          rooms[#rooms + 1] = { id = childId, name = child.name }
        end
        walk(child, depth + 1)
      end
    end
  end

  for id, loc in pairs(hierarchy) do
    local topId = tointeger(id)
    if topId and type(loc) == "table" then
      if tointeger(loc.type) == 8 then
        rooms[#rooms + 1] = { id = topId, name = loc.name }
      end
      walk(loc, 1)
    end
  end
  return rooms
end

--- Uploads the catalogue of what this project could report.
---
--- This is what the installer's picker in SmartBuildOS is built from, so it
--- lists everything observable rather than only what is currently watched —
--- a picker that only offers what is already selected is not a picker.
function sendCatalogue()
  local observables = {}
  local rooms = projectRooms()

  for _, room in ipairs(rooms) do
    gRoomNames[room.id] = room.name
    local okV, vars = pcall(function()
      return C4:GetDeviceVariables(room.id)
    end)
    if okV and type(vars) == "table" then
      for varId, v in pairs(vars) do
        local id = tointeger(varId)
        local name = type(v) == "table" and v.name or nil
        if id and name then
          observables[#observables + 1] = {
            kind = "room",
            source_id = room.id,
            source_name = room.name,
            variable_id = id,
            variable_name = name,
            sample_value = type(v) == "table" and tostring(v.value or "") or nil,
            readonly = type(v) == "table" and tostring(v.readonly) == "True" or false,
          }
          -- A room points at its thermostat through TEMPERATURE_ID, which is
          -- how climate reads next to activity rather than as a separate thing.
          if name == "TEMPERATURE_ID" then
            local thermostat = tointeger(v.value)
            if thermostat and thermostat > 0 then
              gRoomThermostat[room.id] = thermostat
            end
          end
        end
      end
    end
  end

  log:info("Catalogue: %d room(s), %d observable(s)", #rooms, #observables)
  send("telemetry", { kind = "catalogue", observables = observables }, "catalogue")
end

--- Registers or clears variable listeners to match the configuration.
---
--- Watching all fifty-nine of a room's variables would be a firehose of EQ
--- noise for no report value, so only the configured names are listened to —
--- six by default, which produce the entire customer report.
function applyMonitoring()
  if C4.UnregisterAllVariableListeners then
    pcall(function()
      C4:UnregisterAllVariableListeners()
    end)
  end
  gRoomVarNames = {}
  gListening = false

  if not gMonitor.enabled then
    log:info("Room monitoring is off")
    CancelTimer(TELEMETRY_TIMER)
    CancelTimer(CLIMATE_TIMER)
    return
  end

  local wanted = {}
  for _, name in ipairs(gMonitor.room_variables or {}) do
    wanted[name] = true
  end

  local onlyRooms = nil
  if gMonitor.room_ids and #gMonitor.room_ids > 0 then
    onlyRooms = {}
    for _, id in ipairs(gMonitor.room_ids) do
      onlyRooms[id] = true
    end
  end

  local registered = 0
  for _, room in ipairs(projectRooms()) do
    gRoomNames[room.id] = room.name
    if onlyRooms == nil or onlyRooms[room.id] then
      local okV, vars = pcall(function()
        return C4:GetDeviceVariables(room.id)
      end)
      if okV and type(vars) == "table" then
        local names = {}
        for varId, v in pairs(vars) do
          local id = tointeger(varId)
          local name = type(v) == "table" and v.name or nil
          -- Media is always seeded, listener or not: the client app should
          -- show what is playing the moment monitoring is enabled, and these
          -- variables are the only source for it.
          local isMedia = name == "CURRENT MEDIA INFO" or name == "MEDIA WALL INFO" or name == "CURRENT_MEDIA"
          if id and name and (wanted[name] or isMedia) then
            names[id] = name
            pcall(function()
              C4:RegisterVariableListener(room.id, id)
            end)
            registered = registered + 1
            -- Seed from the current value, so a room that is already on does
            -- not wait for a change before it appears in the client app.
            gRooms:apply(room.id, room.name, name, v.value)
          end
        end
        gRoomVarNames[room.id] = names
      end
    end
  end

  gListening = registered > 0
  log:info("Room monitoring on: %d listener(s)", registered)

  -- Seeded state is uploaded immediately rather than at the first timer tick.
  -- An installer who has just switched monitoring on should see the rooms
  -- appear, not wait five minutes wondering whether it worked.
  sendTelemetry()

  SetTimer(TELEMETRY_TIMER, 5 * 60 * ONE_SECOND, function()
    sendTelemetry()
  end, true)

  if gMonitor.climate_enabled then
    local minutes = tointeger(gMonitor.climate_sample_minutes) or 15
    SetTimer(CLIMATE_TIMER, minutes * 60 * ONE_SECOND, function()
      sampleClimate()
    end, true)
  end
end

--- Director calls this for every registered variable.
function OnWatchedVariableChanged(idDevice, idVariable, strValue)
  local roomId = tointeger(idDevice)
  local varId = tointeger(idVariable)
  local names = roomId and gRoomVarNames[roomId] or nil
  local name = names and varId and names[varId] or nil
  if name == nil then
    return
  end
  log:debug("room %s %s = %s", tostring(roomId), name, tostring(strValue))
  gRooms:apply(roomId, gRoomNames[roomId], name, strValue)
end

--- Turns a thermostat's raw variable list into a room climate reading.
---
--- Pure, and global so it can be tested directly: the values below were
--- measured on real hardware and the two mistakes they correct are both
--- invisible in a screenshot.
---
--- 1. `TEMPERATURE` IS DECI-CELSIUS, not degrees. The real thermostat reports
---    TEMPERATURE=282 beside TEMPERATURE_C=28.5 and TEMPERATURE_F=83. That is
---    where "310 degrees" came from -- 31.0 C = 87.8 F, a correct reading in a
---    scale nobody displays. The already-converted variables are read directly
---    rather than dividing by ten and converting, because the thermostat has
---    done the work and a hand-rolled conversion is one more thing to be wrong
---    about.
---
--- 2. NOT EVERY `TEMPERATURE_ID` TARGET IS A THERMOSTAT. One of the two on the
---    measured project is a WEATHER driver: it answers the same proxy, carries
---    a forecast in MESSAGE, reports ANA_ISCONNECTED=False, and lists its modes
---    as "Off,Warn Cool,Warn Heat". THREE rooms point at it, so treating it as
---    a thermostat puts the OUTDOOR temperature on a customer's screen labelled
---    as room comfort.
---
--- @return table|nil  { temperature, heat, cool, mode }, or nil for no reading
function climateReading(vars)
  if type(vars) ~= "table" then
    return nil
  end

  local values = {}
  for _, v in pairs(vars) do
    if type(v) == "table" and type(v.name) == "string" then
      values[v.name:upper()] = v.value
    end
  end

  --- First readable number among candidates, in preference order.
  ---
  --- Zero is rejected deliberately: every unset setpoint on the measured
  --- hardware reads exactly 0, and 0 F is not a setpoint anyone configured.
  local function firstNumber(names)
    for _, name in ipairs(names) do
      local n = tonumber(values[name])
      if n ~= nil and n ~= 0 then
        return n
      end
    end
    return nil
  end

  -- Checked before anything is read. A weather station's temperature is
  -- perfectly valid and perfectly wrong for this purpose.
  local modesList = tostring(values["HVAC_MODES_LIST"] or "")
  if modesList:upper():find("WARN", 1, true) ~= nil then
    return nil
  end

  -- Fahrenheit first: SCALE reads FAHRENHEIT on the measured project and it is
  -- what a US homeowner expects. Celsius is the documented fallback, and raw
  -- deci-Celsius the last resort for a thermostat exposing neither.
  local temp = firstNumber({ "TEMPERATURE_F", "TEMPERATURE_C" })
  if temp == nil then
    local raw = tonumber(values["TEMPERATURE"])
    if raw ~= nil and raw ~= 0 then
      temp = raw / 10
    end
  end

  local heat = firstNumber({ "HEAT_SETPOINT_F", "DISPLAY_HEATSETPOINT", "HEAT_SETPOINT_C" })
  local cool = firstNumber({ "COOL_SETPOINT_F", "DISPLAY_COOLSETPOINT", "COOL_SETPOINT_C" })
  -- HVAC_STATE ("Stage 1 Cool") says what it is DOING; ANA_HVACMODE ("Cool")
  -- says what it is set to. State is the more useful and falls back to mode.
  local mode = values["HVAC_STATE"] or values["ANA_HVACMODE"] or values["HVAC_MODE"]

  if temp == nil and heat == nil and cool == nil then
    return nil
  end
  return { temperature = temp, heat = heat, cool = cool, mode = mode }
end

--- Samples climate rather than watching it: temperature moves constantly and
--- every change is not worth an event.
function sampleClimate()
  if not gMonitor.enabled or not gMonitor.climate_enabled then
    return
  end
  for roomId, thermostat in pairs(gRoomThermostat) do
    local okV, vars = pcall(function()
      return C4:GetDeviceVariables(thermostat)
    end)
    local reading = climateReading(vars)
    if reading ~= nil then
      -- The thermostat travels with the reading. Several rooms routinely share
      -- one, and without this the platform cannot tell six copies of one
      -- thermostat from six thermostats.
      gRooms:setClimate(roomId, reading.temperature, reading.heat, reading.cool, reading.mode, thermostat)
    end
  end
end

--- Uploads current state and any completed sessions.
---
--- Sessions are TAKEN from the tracker, so a successful upload cannot send the
--- same span twice — and returned on failure, so a network problem does not
--- silently delete an evening's history.
function sendTelemetry()
  if not gMonitor.enabled or not isPaired() then
    return
  end

  local rooms = gRooms:snapshot()
  if #rooms > 0 then
    send("telemetry", { kind = "state", rooms = rooms }, "room state")
  end

  local sessions = gRooms:takeSessions()
  if #sessions > 0 then
    log:info("Uploading %d completed session(s)", #sessions)
    send("telemetry", { kind = "sessions", sessions = sessions }, "sessions", function()
      -- Delivered. Nothing to do: they are already out of the queue.
    end)
    -- The send is asynchronous and its failure path cannot see these, so they
    -- are held for one cycle and returned if the connection is down at the next
    -- tick. Imperfect, and deliberately biased toward keeping data.
    if gFailures > 0 then
      gRooms:returnSessions(sessions)
    end
  end
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
  CancelTimer(TELEMETRY_TIMER)
  CancelTimer(CLIMATE_TIMER)
  -- Close open sessions so an evening's viewing is not lost because the driver
  -- reloaded at 11pm. They upload on the next start.
  pcall(function()
    gRooms:closeAll()
  end)
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

--- Runs a full sync and REPORTS its own failure.
---
--- Device syncs stopped reaching the platform at 02:00 on 2026-08-17 while
--- heartbeats kept arriving, which is the signature of `readAllState` throwing
--- before anything is sent: the platform sees a healthy controller and no
--- devices, and nothing anywhere says why. The Lua window would show it, but
--- nobody is watching the Lua window at 3am.
---
--- Events still work when device sync does not -- they take a different code
--- path and are proven by every probe run -- so the error is posted as one. A
--- diagnostic that only works when the thing being diagnosed works is no
--- diagnostic at all.
function EC.SEND_FULL_SYNC()
  log:trace("EC.SEND_FULL_SYNC()")
  local ok, err = pcall(sendFullSync)
  if not ok then
    local detail = tostring(err):sub(1, 400)
    log:error("Full sync failed before sending: %s", detail)
    -- NOT Connection Status: that property is owned by send(), whose success
    -- handler sets it back to "Connected" the moment the failure REPORT below
    -- is delivered. It is also arguably right -- the platform is reachable; it
    -- is the read from Director that failed, which is a different fault.
    UpdateProperty("Driver Status", "Full sync failed: " .. detail:sub(1, 120))
    if isPaired() then
      send("event", {
        kind = "event",
        name = "full sync failed",
        detail = detail,
      }, "full sync failure report")
    end
  end
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

--- Surveys what telemetry this project could support, for the Home Intelligence
--- and maintenance reports.
---
--- Control4 has NO history API — `RecordHistory` writes and nothing reads it
--- back — so every number in a quarterly report has to come from telemetry we
--- collect ourselves. Before designing a schema for that, this reports what is
--- actually available on a real project: which rooms exist, which room variables
--- are populated, and how much programming there is to cross-reference against.
---
--- Runs ONLY from the action, never on a timer. `GetAllCodeItems` and a walk of
--- every room's variables is far more work than a device poll, and this driver
--- has already stalled a sync once by doing too much in one pass.
---
--- @param lines string[] Accumulator, also printed.
local function surveyTelemetry(lines)
  local function note(fmt, ...)
    local line = select("#", ...) > 0 and string.format(fmt, ...) or fmt
    table.insert(lines, line)
    log:print(line)
  end

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

  -- ── Rooms ────────────────────────────────────────────────────────────────
  local okH, hierarchy = pcall(function()
    return C4:GetProjectHierarchy()
  end)
  if not okH or type(hierarchy) ~= "table" then
    note("GetProjectHierarchy -> %s %s", tostring(okH), tostring(hierarchy))
    hierarchy = {}
  else
    note("GetProjectHierarchy -> %d location(s)", count(hierarchy))
    -- The shape is documented loosely ("a table with entries of all of the
    -- location's children"). Dump one verbatim rather than assume it.
    for id, loc in pairs(hierarchy) do
      note("  sample location [%s] = %s", tostring(id), JSON:encode(loc):sub(1, 700))
      break
    end
  end

  -- ── Rooms ────────────────────────────────────────────────────────────────
  --
  -- The hierarchy is a NESTED tree, not the flat map the first version of this
  -- survey assumed. A location table carries `name` and `type` alongside its
  -- CHILD LOCATIONS, keyed by their ids:
  --
  --   [13] Home(2) -> "14" House(3) -> "15" Main(4) -> "16" Living Room(8), ...
  --
  -- and `type` is a number. Measured on a real project: 2=site, 3=building,
  -- 4=floor, 8=room. The type distribution is reported below rather than
  -- assumed, so the mapping stays evidence-based.
  local ROOM_TYPE = 8
  local rooms, typeCounts = {}, {}

  local function walk(node, depth)
    if type(node) ~= "table" or depth > 8 then
      return
    end
    for key, child in pairs(node) do
      -- `name` and `type` are attributes; every other key is a child location
      -- id. Numeric-looking keys are the children.
      local childId = tointeger(key)
      if childId ~= nil and type(child) == "table" then
        local t = tointeger(child.type)
        if t ~= nil then
          typeCounts[t] = (typeCounts[t] or 0) + 1
          if t == ROOM_TYPE then
            rooms[#rooms + 1] = { id = childId, name = child.name }
          end
        end
        walk(child, depth + 1)
      end
    end
  end

  for id, loc in pairs(hierarchy) do
    local topId = tointeger(id)
    if topId and type(loc) == "table" then
      local t = tointeger(loc.type)
      if t then
        typeCounts[t] = (typeCounts[t] or 0) + 1
        if t == ROOM_TYPE then
          rooms[#rooms + 1] = { id = topId, name = loc.name }
        end
      end
      walk(loc, 1)
    end
  end

  local typeSummary = {}
  for t, n in pairs(typeCounts) do
    typeSummary[#typeSummary + 1] = string.format("type %d x%d", t, n)
  end
  table.sort(typeSummary)
  note("location types found: %s", table.concat(typeSummary, ", "))
  note("rooms (type %d): %d", ROOM_TYPE, #rooms)

  local names = {}
  for i, r in ipairs(rooms) do
    if i > 12 then
      break
    end
    names[#names + 1] = string.format("%s(%d)", tostring(r.name), r.id)
  end
  note("  %s", table.concat(names, ", "))

  -- ── Room variables ───────────────────────────────────────────────────────
  --
  -- These ARE the customer report: Current_Selected_Device says a room is in
  -- use, Current_Media_Type says what kind of thing is playing, Power_State is
  -- the cleanest activity signal. Whether a ROOM answers GetDeviceVariables is
  -- the open question — the reference only ever shows RegisterVariableListener
  -- against a room id, never GetDeviceVariables — so it is tried and reported.
  local roomsWithVars, sampled = 0, false
  for _, room in ipairs(rooms) do
    local okV, vars = pcall(function()
      return C4:GetDeviceVariables(room.id)
    end)
    if okV and type(vars) == "table" and count(vars) > 0 then
      roomsWithVars = roomsWithVars + 1
      if not sampled then
        sampled = true
        note("room %d (%s) exposes %d variable(s):", room.id, tostring(room.name), count(vars))
        -- Names only: the full table for a room is far too large for one event,
        -- and the names are what decide which listeners to register.
        local varNames = {}
        for varId, v in pairs(vars) do
          varNames[#varNames + 1] = string.format(
            "%s=%s",
            tostring(type(v) == "table" and v.name or varId),
            tostring(type(v) == "table" and v.value or "?")
          )
        end
        table.sort(varNames)
        local joined = table.concat(varNames, " | ")
        -- Chunked across notes so nothing is lost to the 480-char event cap.
        for i = 1, math.min(#joined, 1800), 440 do
          note("    %s", joined:sub(i, i + 439))
        end
      end
    end
  end
  note("rooms exposing variables: %d of %d", roomsWithVars, #rooms)

  -- ── Programming ──────────────────────────────────────────────────────────
  --
  -- GetAllCodeItems is what turns "19 scenes, 7 used" into a real join, and it
  -- is also the maintenance report's best source: `enabled = false` is disabled
  -- programming nobody remembers switching off.
  local okC, codeItems = pcall(function()
    return C4:GetAllCodeItems()
  end)
  if not okC or type(codeItems) ~= "table" then
    note("GetAllCodeItems -> %s %s", tostring(okC), tostring(codeItems))
  else
    local groups, total, disabled, lines, withText = 0, 0, 0, 0, 0
    local sampleText = nil

    --- Programming nests: a code item's `subitems` hold the actual commands,
    --- and the top level is only the event hook. Counting the top level alone
    --- reports 123 attachments and says nothing about how much programming
    --- exists, which is the number the report needs.
    local function countItem(ci, depth)
      if type(ci) ~= "table" or depth > 12 then
        return
      end
      lines = lines + 1
      if ci.enabled == false then
        disabled = disabled + 1
      end
      local display = type(ci.display) == "string" and ci.display or ""
      if display ~= "" then
        withText = withText + 1
        if sampleText == nil then
          sampleText = display
        end
      end
      if type(ci.subitems) == "table" then
        for _, sub in pairs(ci.subitems) do
          countItem(sub, depth + 1)
        end
      end
    end

    for groupName, list in pairs(codeItems) do
      groups = groups + 1
      if type(list) == "table" then
        for _, item in pairs(list) do
          total = total + 1
          if type(item) == "table" then
            countItem(item.codeitem, 0)
          end
        end
      end
      note("  group %s: %d attachment(s)", tostring(groupName), total)
    end
    note("GetAllCodeItems -> %d group(s), %d event attachment(s)", groups, total)
    note("  programming lines (incl. nested): %d, with readable text: %d, disabled: %d", lines, withText, disabled)
    if sampleText then
      note("  sample line: %s", sampleText:sub(1, 200))
    end
  end

  -- ── Device variables ─────────────────────────────────────────────────────
  --
  -- Climate is the other half of the customer report. Rather than guess which
  -- devices are thermostats, report which devices expose variables at all and
  -- sample one, so the schema is designed from the real shape.
  local devices = C4:GetDevices({}) or {}
  local withVars, checked = 0, 0
  local sampleShown = false
  for rawId, device in pairs(devices) do
    if checked >= 40 then
      break
    end
    checked = checked + 1
    local id = tointeger(rawId)
    if id then
      local okV, vars = pcall(function()
        return C4:GetDeviceVariables(id)
      end)
      if okV and type(vars) == "table" and count(vars) > 0 then
        withVars = withVars + 1
        if not sampleShown then
          sampleShown = true
          note("device %s (%s) variables:", tostring(id), tostring(device.deviceName or device.name))
          note("  %s", JSON:encode(vars):sub(1, 800))
        end
      end
    end
  end
  note("devices sampled: %d, of which %d expose variables", checked, withVars)
  note("project size: %d device(s) total", count(devices))
end

--- Runs the survey and posts it, so the result is readable from the platform
--- rather than copied out of a Lua window.

-- ─── Capability probe (T-0.6) ────────────────────────────────────────────────
--
-- Six things Home Intelligence needs and nobody has measured on hardware:
--
--   1. a MAC address per device      -- the only key that joins Control4 to
--                                       Installed Equipment and UniFi
--   2. lighting scene activation     -- gates scene utilisation analytics
--   3. keypad button identity        -- gates keypad analytics
--   4. shade state                   -- gates shade analytics
--   5. thermostat variable names     -- production reports 0 and 310, which are
--                                       not temperatures
--   6. event ORIGIN (auto vs manual) -- gates automation override rate, the
--                                       highest-value metric in the brief
--
-- This DUMPS REAL STRUCTURES rather than testing for field names it expects.
-- Four assumptions have already been wrong this month -- GetBindingsByDevice
-- nests under `bindings`, GetProjectHierarchy is a nested tree with numeric
-- types, the media payload is XML, and GetNetworkConnections is per-caller --
-- and every one of them was found by printing the thing instead of believing
-- the documentation. A probe that only looks for `binding.mac` would report
-- "no MAC available" on a controller that calls it something else.
local function probeCapabilities(lines)
  local function note(fmt, ...)
    local line = select("#", ...) > 0 and string.format(fmt, ...) or fmt
    table.insert(lines, line)
    log:print(line)
  end

  local function dump(value, limit)
    local ok, encoded = pcall(function()
      return JSON:encode(value)
    end)
    if not ok then
      return "<unencodable: " .. tostring(encoded) .. ">"
    end
    return tostring(encoded):sub(1, limit or 420)
  end

  -- Classify by NAME, because the proxy id is not reliably exposed here. This
  -- only chooses what to dump -- it never decides what anything is.
  local CANDIDATES = {
    thermostat = "thermostat|hvac|temp|climate|nest|ecobee",
    shade = "shade|blind|drape|curtain|shutter",
    keypad = "keypad|button|dimmer|switch|remote",
    lighting = "light|lamp|scene|load",
  }

  local devices = C4:GetDevices({}) or {}
  local total, byKind = 0, {}
  local samples = {}
  for kind in pairs(CANDIDATES) do
    samples[kind] = {}
  end

  for rawId, device in pairs(devices) do
    local id = tointeger(rawId)
    if id ~= nil then
      total = total + 1
      local name = tostring(type(device) == "table" and (device.name or device.Name) or device or "")
      local lowered = name:lower()
      for kind, pattern in pairs(CANDIDATES) do
        if lowered:find(pattern) then
          byKind[kind] = (byKind[kind] or 0) + 1
          if #samples[kind] < 3 then
            samples[kind][#samples[kind] + 1] = { id = id, name = name }
          end
        end
      end
    end
  end

  note(
    "PROBE devices=%d thermostat=%d shade=%d keypad=%d lighting=%d",
    total,
    byKind.thermostat or 0,
    byKind.shade or 0,
    byKind.keypad or 0,
    byKind.lighting or 0
  )

  -- 0. What a device entry actually LOOKS like.
  --
  -- The name-matching census above reported 0 thermostats, 0 shades, 0 keypads
  -- and 0 lighting across 221 devices, which cannot be true. Rather than guess
  -- why, dump one entry whole. The previous run's null results were a broken
  -- method reporting nothing, not a project containing nothing, and that
  -- distinction is worth a single line of output.
  for rawId, device in pairs(devices) do
    note("PROBE devsample [%s] = %s", tostring(rawId), dump(device, 700))
    break
  end

  -- 1. MAC, from the API that actually returns network bindings.
  --
  -- Two wrong turns before this, both worth recording because both produced a
  -- confident negative from a question that was never asked:
  --
  --   a) Dumping "the first binding" got MEDIA_PLAYER and MediaService -- type
  --      2 control bindings that never carry an address.
  --   b) Filtering those for `addr` then reported "NO device returned a binding
  --      carrying addr", which CONTRADICTS this driver's own device monitoring:
  --      73 devices report online/offline, and that requires an addressed
  --      binding. The contradiction was the tell.
  --
  -- The cause is that network bindings come from a DIFFERENT API.
  -- `networkBinding()` above tries `C4:GetNetworkBindingsByDevice` first and
  -- only falls back to `GetBindingsByDevice`; the probe was calling the
  -- fallback and concluding from it.
  --
  -- So: dump the raw response of the correct API, whole, plus the exact object
  -- `networkBinding()` selects. If a MAC is exposed anywhere, one of those two
  -- carries it, and if neither does then the answer is a real no.
  --
  -- THIRD attempt at this question, so the selection is now explicit about what
  -- "has a network binding" means. `GetNetworkBindingsByDevice` answers
  -- `{networkbindings = {}}` for a device with none -- the WRAPPER is always
  -- present and non-empty, so testing the response table for emptiness passed
  -- every device and spent all three dump slots on media devices that have no
  -- network binding at all.
  local netDumped, withNet, scannedNet = 0, 0, 0
  for rawId in pairs(devices) do
    local id = tointeger(rawId)
    if id ~= nil then
      scannedNet = scannedNet + 1
      local okRaw, raw = pcall(function()
        return C4:GetNetworkBindingsByDevice(id)
      end)
      if okRaw and type(raw) == "table" then
        local list = raw.networkbindings
        -- The ARRAY, not the wrapper.
        if type(list) == "table" and #list > 0 then
          withNet = withNet + 1
          if netDumped < 3 then
            netDumped = netDumped + 1
            note("PROBE netraw[%d] = %s", id, dump(raw, 900))
            local selected = networkBinding(id)
            if type(selected) == "table" then
              note("PROBE netselected[%d] = %s", id, dump(selected, 900))
            end
          end
        end
      end
    end
  end
  -- The count is the sanity check: device monitoring reports on 73 devices, so a
  -- number near that means the right question was finally asked. Far from it
  -- means the probe is still wrong, whatever the dumps appear to say.
  note("PROBE netbindings: %d of %d device(s) carry a network binding", withNet, scannedNet)
  if withNet == 0 then
    note("PROBE netbindings: zero CONTRADICTS working device monitoring -- probe fault, not a finding")
  end

  -- 2. What kinds of device this project contains, by BINDING CLASS.
  --
  -- Replaces the name matching that failed. A project describes its own device
  -- kinds through binding classes -- MEDIA_PLAYER, MediaService and so on --
  -- and those are assigned by Control4 rather than typed by whoever named the
  -- device. If keypads, shades or lighting loads exist, they say so here, under
  -- whatever Control4 actually calls them.
  local classCount = {}
  local scanned = 0
  for rawId in pairs(devices) do
    local id = tointeger(rawId)
    if id ~= nil then
      local okB, bindings = pcall(function()
        return C4:GetBindingsByDevice(id)
      end)
      if okB and type(bindings) == "table" then
        scanned = scanned + 1
        local list = type(bindings.bindings) == "table" and bindings.bindings or bindings
        for _, entry in pairs(list) do
          if type(entry) == "table" then
            if type(entry.name) == "string" and entry.name ~= "" then
              local key = "name:" .. entry.name
              classCount[key] = (classCount[key] or 0) + 1
            end
            if type(entry.bindingclasses) == "table" then
              for _, bc in pairs(entry.bindingclasses) do
                if type(bc) == "table" and type(bc.class) == "string" then
                  local key = "class:" .. bc.class
                  classCount[key] = (classCount[key] or 0) + 1
                end
              end
            end
          end
        end
      end
    end
  end
  note("PROBE binding census over %d device(s):", scanned)
  for key, n in pairs(classCount) do
    note("PROBE bindingkind %s x%d", key, n)
  end

  -- 2-5. Every variable, verbatim, for a few candidates of each kind. The
  --      thermostat dump is what will finally explain 0 and 310.
  for kind, list in pairs(samples) do
    if #list == 0 then
      note("PROBE %s: no candidate devices in this project", kind)
    end
    for _, entry in ipairs(list) do
      local okV, vars = pcall(function()
        return C4:GetDeviceVariables(entry.id)
      end)
      if okV and type(vars) == "table" then
        note("PROBE %s[%d] %s vars=%s", kind, entry.id, entry.name, dump(vars, 620))
      else
        note("PROBE %s[%d] %s vars unavailable: %s", kind, entry.id, entry.name, tostring(vars))
      end
    end
  end

  -- 5b. THERMOSTATS, found by POINTER rather than by name.
  --
  -- `TEMPERATURE_ID` is a room variable holding a thermostat's DEVICE ID -- it
  -- is not a temperature, which is what made the catalogue look like it was
  -- reporting 310 degrees. Following it is exact, where matching a device name
  -- against "thermostat|hvac|temp" is a guess that misses anything named after
  -- the room it serves.
  --
  -- Measured on the live project: rooms point at devices 322 and 410, and the
  -- TEMPERATURE variable on those reads 310 and 0. Neither is a temperature in
  -- any unit anyone would display, so the FULL variable set of each thermostat
  -- is dumped here -- including every name and value -- to find which variable
  -- carries the real reading and in what scale.
  local thermostats = {}
  for _, target in pairs(gRoomThermostat or {}) do
    thermostats[target] = true
  end
  if next(thermostats) == nil then
    -- The pointer map is only built during a catalogue upload, so a probe run
    -- before one has to find them itself.
    for rawId in pairs(devices) do
      local id = tointeger(rawId)
      if id ~= nil then
        local okV, vars = pcall(function()
          return C4:GetDeviceVariables(id)
        end)
        if okV and type(vars) == "table" then
          for _, v in pairs(vars) do
            if type(v) == "table" and type(v.name) == "string" and v.name:upper() == "TEMPERATURE_ID" then
              local target = tointeger(v.value)
              if target and target > 0 then
                thermostats[target] = true
              end
            end
          end
        end
      end
    end
  end

  -- Thermostat VARIABLE dumps are deliberately not repeated. That question is
  -- answered -- TEMPERATURE is deci-Celsius, one of the two targets is a
  -- weather driver -- and re-sending ~180 lines of it every run crowds out the
  -- unknowns this probe still exists to measure. The count stays, because it is
  -- how a newly added thermostat announces itself.
  local thermostatCount = 0
  for _ in pairs(thermostats) do
    thermostatCount = thermostatCount + 1
  end
  note("PROBE thermostats found via TEMPERATURE_ID = %d", thermostatCount)

  -- 6. Event origin. The whole point of the override-rate metric is knowing
  --    whether a human or a program caused a change. Dump the complete
  --    OnWatchedVariableChanged argument set the next time one fires, rather
  --    than asserting the callback signature.
  note("PROBE origin: watch payload shape is reported by the listener itself; see 'PROBE origin sample'")

  -- Scene / programming inventory. GetAllCodeItems is already verified; what is
  -- unknown is whether scene ACTIVATION is observable, so dump what a code item
  -- actually contains.
  local okC, items = pcall(function()
    return C4:GetAllCodeItems()
  end)
  if okC and type(items) == "table" then
    local n = 0
    for _ in pairs(items) do
      n = n + 1
    end
    note("PROBE codeitems=%d", n)
    for _, item in pairs(items) do
      note("PROBE codeitem sample = %s", dump(item, 620))
      break
    end
  else
    note("PROBE codeitems unavailable: %s", tostring(items))
  end
end

function EC.REPORT_TELEMETRY_SURVEY()
  log:trace("EC.REPORT_TELEMETRY_SURVEY()")
  -- Also refresh the stored catalogue: its sample values are how the platform
  -- learns what a variable actually looks like, and they only update when this
  -- runs or the configuration changes.
  if isPaired() and gMonitor.enabled then
    pcall(sendCatalogue)
    pcall(sendTelemetry)
  end
  local lines = {}
  local ok, err = pcall(surveyTelemetry, lines)
  if not ok then
    table.insert(lines, "survey failed: " .. tostring(err))
    log:error("Telemetry survey failed: %s", tostring(err))
  end
  if not isPaired() then
    return
  end
  for i, line in ipairs(lines) do
    send("event", {
      kind = "event",
      name = string.format("survey %02d", i),
      detail = line:sub(1, 480),
    }, "survey line " .. i)
  end
end

--- Runs the T-0.6 capability probe and reports it as events.
---
--- Read out of `control4_device_events` rather than the Lua window: the findings
--- are long, and the point is to get REAL structures somewhere they can be
--- studied against the schema they will drive.
function EC.PROBE_CAPABILITIES()
  log:trace("EC.PROBE_CAPABILITIES()")
  local lines = {}
  local ok, err = pcall(probeCapabilities, lines)
  if not ok then
    table.insert(lines, "probe failed: " .. tostring(err))
    log:error("Capability probe failed: %s", tostring(err))
  end
  if not isPaired() then
    log:warn("Capability probe ran but the driver is not paired; nothing uploaded")
    return
  end
  -- BATCHED, one request per chunk rather than one per line.
  --
  -- The first full run of this probe produced 663 lines and 125 arrived. Each
  -- line was its own HTTP request, the ingest rate limiter dropped four out of
  -- five, and the casualties included every `netbinding` line -- so the MAC
  -- question came back unanswered and looked like a negative result rather than
  -- a lost one. Silence from a dropped request is indistinguishable from
  -- silence meaning "no".
  --
  -- This is the same defect the telemetry design forbids ("do not send one HTTP
  -- request for every keypad press") arriving in the diagnostic path first.
  -- Chunked by CHARACTER BUDGET, not by line count.
  --
  -- The platform caps an event's `detail` at 500 characters. Batching twenty
  -- lines into one field made the REQUESTS survive the rate limiter and then
  -- threw most of their CONTENT away at the other end -- the network-binding
  -- dump, the entire point of the run, arrived cut off mid-object.
  --
  -- Budgeting under the cap means a long line lands in a chunk of its own
  -- rather than being truncated by its neighbours, which matters because the
  -- longest lines here are the raw structure dumps this probe exists to
  -- collect. Nothing is silently lost: a single line over the cap is split
  -- across chunks rather than clipped.
  local BUDGET = 470
  local chunk, chunkLen, chunkIndex = {}, 0, 0
  local function flush()
    if #chunk == 0 then
      return
    end
    chunkIndex = chunkIndex + 1
    send("event", {
      kind = "event",
      name = string.format("probe %03d", chunkIndex),
      detail = table.concat(chunk, "\n"),
    }, "probe chunk " .. chunkIndex)
    chunk, chunkLen = {}, 0
  end

  for _, line in ipairs(lines) do
    -- A line longer than the whole budget is split rather than dropped.
    local remaining = line
    while #remaining > BUDGET do
      flush()
      chunk, chunkLen = { remaining:sub(1, BUDGET) }, BUDGET
      flush()
      remaining = remaining:sub(BUDGET + 1)
    end
    if chunkLen + #remaining + 1 > BUDGET then
      flush()
    end
    chunk[#chunk + 1] = remaining
    chunkLen = chunkLen + #remaining + 1
  end
  flush()
  log:info("Capability probe: %d line(s) in %d request(s)", #lines, chunkIndex)
end

function EC.REPORT_DIAGNOSTICS()
  log:trace("EC.REPORT_DIAGNOSTICS()")
  reportDiagnostics(true)
end

function EC.POLL_DEVICES()
  log:trace("EC.POLL_DEVICES()")
  pollDeviceState()
end

--- Sweeps the subnet now, rather than waiting for the schedule.
---
--- Wrapped the way SEND_FULL_SYNC is: an action that throws out to Composer
--- shows the installer a red box with no detail, and the throw is the only
--- record. This one can fail on a controller whose OS has no ping API, which is
--- a perfectly ordinary thing to discover from a button.
function EC.SCAN_NETWORK()
  log:trace("EC.SCAN_NETWORK()")
  if C4.CreatePingClient == nil then
    log:error("Network scan unavailable: this controller's OS provides no ping API")
    UpdateProperty("Last Network Scan", "Unavailable: no ping API on this controller")
    return
  end
  local ok, err = pcall(runNetworkScan, "manual")
  if not ok then
    local detail = tostring(err):sub(1, 400)
    log:error("Network scan failed: %s", detail)
    UpdateProperty("Last Network Scan", "Failed: " .. detail:sub(1, 120))
    if isPaired() then
      send("event", { kind = "event", name = "network scan failed", detail = detail }, "network scan failure")
    end
  end
end

--- Mints a touchpanel URL and writes it into the driver's own properties.
---
--- Exists because the person configuring a panel is standing at the rack in
--- Composer and very often has no SmartBuildOS session -- the owner of the
--- client record and the installer wiring the house are frequently not the same
--- person, and the second cannot be blocked on the first.
---
--- The URL is stored HERE, in the driver, because SmartBuildOS keeps only a hash
--- and cannot show it again. That is not a weakening: this driver already holds
--- a device token, which is a strictly stronger credential, and it lives inside
--- the client's own rack.
---
--- Every run mints a NEW panel and deliberately does not revoke the last one, so
--- an installer who runs this twice -- or a year later, adding a second panel --
--- cannot silently kill the panel already hanging on the wall.
function EC.GENERATE_DISPLAY_URL()
  log:trace("EC.GENERATE_DISPLAY_URL()")

  if not isPaired() then
    -- Said in the property itself rather than only the log. An installer runs
    -- an action and looks at the property; nobody opens Lua output for this.
    UpdateProperty("Touchpanel URL", "Pair the driver first")
    log:warn("Cannot generate a touchpanel URL: driver is not paired")
    return
  end

  local label = Properties["Touchpanel Name"] or ""
  label = label:match("^%s*(.-)%s*$")
  if label == "" then
    label = "Touchpanel"
  end

  UpdateProperty("Touchpanel URL", "Generating...")

  send("display", { kind = "display", label = label }, "touchpanel URL request", function(body)
    -- Only ever set from a URL the server actually returned. Writing anything
    -- optimistic here would hand the installer a link that 404s on the panel
    -- they just configured.
    if type(body.url) == "string" and body.url ~= "" then
      UpdateProperty("Touchpanel URL", body.url)
      log:info("Touchpanel URL generated for '%s'", label)
    else
      UpdateProperty("Touchpanel URL", "Failed - see Lua output")
      log:error("Touchpanel URL response carried no url")
    end
  end)
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
  -- The panels themselves keep working: a display URL is its own credential and
  -- is revoked from SmartBuildOS, not from here. What is cleared is this
  -- driver's COPY, which after unpairing is no longer a URL it can vouch for.
  UpdateProperty("Touchpanel URL", "Not generated")
  CancelTimer(HEARTBEAT_TIMER)
  CancelTimer(DEVICE_POLL_TIMER)
  CancelTimer(FULL_SYNC_TIMER)
  CancelTimer(TELEMETRY_TIMER)
  CancelTimer(CLIMATE_TIMER)
  gMonitor.enabled = false
  applyMonitoring()
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
