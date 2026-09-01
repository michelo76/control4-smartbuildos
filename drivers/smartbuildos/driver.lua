--#ifdef DRIVERCENTRAL
DC_PID = 0
DC_X = nil
DC_FILENAME = "smartbuildos.c4z"
--#else
DRIVER_GITHUB_REPO = "michelo76/control4-smartbuildos"
DRIVER_FILENAMES = {
  "smartbuildos.c4z",
  -- Every driver the store publishes, so an install keeps itself current.
  -- updateAll only touches drivers ACTUALLY INSTALLED in this project and
  -- only when the store holds a NEWER build — it never installs a driver a
  -- dealer did not choose, and a filename with no store package is simply
  -- skipped. Suite children are listed individually because the update is
  -- per .c4z file; they share the parent's SKU, not its filename.
  "smartbuildos-atmosphere.c4z",
  "smartbuildos-mode-composer.c4z",
  "smartbuildos-mode-button.c4z",
  "unifi-protect.c4z",
  "unifi-protect-camera.c4z",
  "unifi-protect-light.c4z",
  "unifi-protect-sensor.c4z",
  "unifi-protect-viewport.c4z",
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
local sbosUpdater = require("lib.sbos-updater")
--#endif

--- Interval labels mapped to seconds.
--- @type table<string, number>
local INTERVALS = {
  ["30s"] = 30,
  ["1m"] = 60,
  ["2m"] = 2 * 60,
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
--- The system this driver is paired to.
---
--- ⚠ A SYSTEM NEED NOT HAVE A PROPERTY. SmartBuildOS tracks Control4 projects
--- for customers who are not its clients, and those systems carry no property
--- at all — the platform re-keyed on the system and made `property_id`
--- advisory. This driver did not follow, and the result was a pairing that
--- SUCCEEDED on the server (code redeemed, controller minted, token issued)
--- and reported "Pairing failed - unexpected response" in Composer, because
--- the response carried no property id. Three attempts, three spent codes,
--- three orphan controllers, and no way for the dealer to tell.
local SYSTEM_KEY = "system_id"
--- Per-controller HMAC secret for entitlement assertions (Driver Cloud
--- Phase 5). Minted by /pair alongside the token; same trust domain, same
--- storage rules: encrypted persist + the Pairing Backup mirror. It rides
--- the project file for the same measured reason the token does (encrypted
--- persist has not survived driver updates) — and that is an accepted
--- tradeoff, not an oversight: a restored project IS the same paired
--- controller identity, so secret and cache moving together changes
--- nothing the token has not already decided.
local AGENT_SECRET_KEY = "agent_secret"
local SUPPORT_ID_KEY = "support_id"
--- Verified entitlement assertions from the platform, encrypted persist:
--- { fetched_at, checked_at, support_id, revalidate_hours, cache_days,
---   verified, assertions = { [sku] = assertion } }.
local ENTITLEMENT_CACHE_KEY = "sbos_entitlement_cache"
local ENTITLEMENT_TIMER = "SmartBuildOSEntitlements"
local PROPERTY_NAME_KEY = "property_name"
--- The registered company name + its SmartBuildOS subscription tier, as the
--- platform resolves them. Sent on pair and every refresh; cached so the Agent
--- can display the account picture (#3) before its first refresh and while
--- offline. A BLANK inbound value never overwrites a known one — the platform
--- sends blank only when it could not confirm the value, and last-known beats
--- mislabeling a paid customer.
local ACCOUNT_NUMBER_KEY = "sbos_account_number"
local SUBSCRIPTION_TIER_KEY = "sbos_subscription_tier"
local COMPANY_NAME_KEY = "sbos_company_name"
--- The site's street address, as SmartBuildOS composes it.
---
--- Composed on the platform, never here: a system linked to a property uses
--- the property's address and a standalone Control4 customer uses its own, and
--- that rule should not exist in two languages. The driver renders what it is
--- handed.
local SITE_LABEL_KEY = "site_label"
--- How many times this driver has started, and when it last did.
---
--- ── WHAT THIS ACTUALLY MEASURES ─────────────────────────────────────────────
---
--- OnDriverLateInit runs when the driver loads, and the driver loads when
--- Director does: a controller reboot, a Director restart, a project reload,
--- or a driver update all produce exactly one of these. There is no
--- documented API that says "the controller rebooted" on its own, so rather
--- than claim one, this counts STARTS — a fact — and classifies the cause by
--- the one signal available: if the driver version changed since the last
--- start, the cause was an update; otherwise Director reloaded underneath a
--- driver that did not change.
---
--- `persist` survives the restart (Director stores it), which is what makes
--- counting possible at all.
local RELOAD_COUNT_KEY = "director_reload_count"
local RELOAD_AT_KEY = "director_reload_at"
local RELOAD_VERSION_KEY = "director_reload_version"
local RELOAD_KIND_KEY = "director_reload_kind"

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

--- The general telemetry queue (Phase 2). Bounded per the driver budget:
--- 500 items, 24h, 200 per batch, drop-oldest, drops counted. The sequence
--- behind the idempotency keys is PERSISTED -- a driver reload that reset it
--- would mint keys the platform has already seen, and the first N real events
--- after every update would be silently swallowed as duplicates.
local TelemetryQueue = require("telemetry.queue")
local Lights = require("telemetry.lights")
local RealtimeClient = require("telemetry.realtime")
local WebSocket = require("drivers-common-public.module.websocket")
local TELEMETRY_SEQ_KEY = "telemetry_seq"
local gTelemetry = TelemetryQueue.new({
  now = os.time,
  wallClock = function()
    return os.date("!%Y-%m-%dT%H:%M:%SZ")
  end,
  -- The token prefix is stable per pairing and never secret on its own.
  keyPrefix = (function()
    local token = persist:get(TOKEN_KEY, "", true) or ""
    return token:match("^sbc4_([0-9a-f]+)_") or "c4"
  end)(),
  loadSeq = function()
    return persist:get(TELEMETRY_SEQ_KEY, 0)
  end,
  saveSeq = function(seq)
    -- Persisted every 25 events rather than every event: Director persistence
    -- is a write to flash, and a key that restarts at most 25 late never
    -- repeats -- gaps are fine, repeats are not.
    if seq % 25 == 0 then
      persist:set(TELEMETRY_SEQ_KEY, seq + 25)
    end
  end,
})
--- Consecutive telemetry upload failures, for backoff.
local gTelemetryFailures = 0
--- room id -> { [variableId] = variableName } for the variables we listen to.
local gRoomVarNames = {}
--- room id -> name, from the project hierarchy.
local gRoomNames = {}
--- room id -> thermostat device id, from the room's TEMPERATURE_ID.
local gRoomThermostat = {}
--- Thermostats found by their own VARIABLES rather than by a room pointing at
--- them. Measured 2026-08-18: every room's TEMPERATURE_ID on the real project
--- points at ONE unit (the Living Room's), while a second real thermostat
--- ("Master Bedroom", named after its room) is nobody's TEMPERATURE_ID at
--- all. Room-linked discovery alone reports half the house's climate.
--- @type table<number, boolean>
local gDiscoveredThermostats = {}
--- The latest full thermostat readings, refreshed by `sampleClimate` and
--- shipped with every state upload. A list, not a map: it travels as JSON.
--- @type table[]
local gThermostatSnapshot = {}
--- What the self-update channel last did, so the platform can see it.
--- @type table
local gUpdate = { checked_at = nil, automatic = nil, reads_version_as = nil }
--- What this driver start was: count, timestamp, and cause.
--- @type table
local gStart = { count = 0, at = nil, kind = nil }
--- Devices that reported a sensor or battery signature at the last catalogue
--- walk: id -> { name, room }. Re-read on each state upload.
--- @type table<number, table>
local gSensorDevices = {}
--- Lights found by signature: id -> { name, room, watch = {varId -> varName} }.
local gLightDevices = {}
--- Keypads found by signature: id -> { name, room, watch = {varId -> varName} }.
local gKeypadDevices = {}
--- Keypads that exposed NO button variables — the count IS the measurement
--- finding 7 left open, so it is kept and reported rather than discarded.
local gKeypadsSilent = 0
--- Bounded: a project with a thousand contacts is a firehose, not a report.
local MAX_SENSORS = 200
local MAX_LIGHTS = 150
--- Listener budget, spent on the lights nearest the front of the walk. Every
--- light is still SAMPLED on the telemetry tick; listeners only buy immediacy,
--- so running out of them degrades freshness, never coverage. Keeps total
--- listeners inside the plan's §P budget.
local MAX_LIGHT_LISTENERS = 40
local MAX_KEYPAD_LISTENERS = 30
--- @type boolean Whether listeners are currently registered.
local gListening = false

local TELEMETRY_TIMER = "SmartBuildOSTelemetry"
local CLIMATE_TIMER = "SmartBuildOSClimate"
local TELEMETRY_QUEUE_TIMER = "SmartBuildOSTelemetryQueue"
--- One-shot: a light changing arms this instead of sending immediately, so a
--- scene that moves twelve loads produces one upload, not twelve.
local flushTelemetry
local LIGHT_PUSH_TIMER = "SmartBuildOSLightPush"
local REALTIME_HB_TIMER = "SmartBuildOSRealtimeHeartbeat"
local REALTIME_RECONNECT_TIMER = "SmartBuildOSRealtimeReconnect"
--- Ping reactions are debounced: a burst of doorbell rings is one check-in.
local REALTIME_PING_TIMER = "SmartBuildOSRealtimePing"

--- The doorbell socket. `config` is what the platform last offered; comparing
--- against it is how a changed channel or key reconnects and an unchanged one
--- does not. `backoff` doubles 15s→300s across failures and resets on join.
local gRealtime = { ws = nil, client = nil, config = nil, backoff = 15 }
--- One-shot fast flush: armed by the first queued event of a burst, so a
--- keypad press reaches the platform in seconds while the 45s cycle remains
--- the backstop. Re-arming on every event would STARVE the flush during a
--- sustained burst; a one-shot cannot.
local TELEMETRY_FAST_FLUSH_TIMER = "SmartBuildOSTelemetryFastFlush"

-- Declared here because the heartbeat handler applies configuration, and the
-- functions that act on it are defined further down.
local applyMonitoring
local sendCatalogue
-- Called from the heartbeat response (config apply) which is defined above
-- the definition — same lexical trap as collectCommands below.
local scheduleTimers
-- Phase 5 licensing engine (defined with the Agent section at file end;
-- referenced by timers, pairing and unpair above it).
local entitlementTick, refreshEntitlements, updateLicenseProperties, licensedDriverCounts
-- Same trap again: the heartbeat refreshes the site address and repaints the
-- "Paired Property" line, and that painter is defined with the pairing code
-- far below. Without this it resolves to a nil GLOBAL and dies inside the
-- response callback's pcall, where nothing would ever report it.
local showPairingState
-- ⚠ This forward declaration is a BUG FIX, not tidiness.
-- was a  defined at the bottom of the file while two call
-- sites — including the empty-project self-diagnosis on the very outage path
-- this driver spent 2026-08-17 in — sat above it, resolving a nil GLOBAL and
-- failing inside an outer pcall, invisibly. Found by the command-queue test
-- asking REQUEST_DIAGNOSTICS to actually run.
local reportDiagnostics
-- Assigned after every function it dispatches to exists: a local closure binds
-- upvalues LEXICALLY, so defining this above `sendFullSync` would quietly
-- resolve the runner targets as nil globals and every remote command would ack
-- as "attempt to call a nil value".
local collectCommands

--- Classify a driver start from what changed since the last one.
---
--- Pure and global so the rule is testable without a controller. The only
--- distinguishing signal available is the driver version: a start whose
--- version differs from the last recorded one was caused by an UPDATE, and a
--- start at the same version means Director came up underneath an unchanged
--- driver — a reboot, a restart or a project reload, which are not
--- distinguishable from in here and are not claimed to be.
--- @return string kind  "first" | "update" | "reload"
function classifyStart(previousVersion, currentVersion, previousCount)
  if previousCount == nil or previousCount == 0 then
    return "first"
  end
  if previousVersion ~= nil and currentVersion ~= nil and previousVersion ~= currentVersion then
    return "update"
  end
  return "reload"
end

--- Record this start, and answer what it was.
--- @return table { count, at, kind, previous_version, version }
local function recordStart()
  local previousCount = tointeger(persist:get(RELOAD_COUNT_KEY, 0)) or 0
  local previousVersion = persist:get(RELOAD_VERSION_KEY, nil)
  local okV, currentVersion = pcall(function()
    return C4:GetDriverConfigInfo("version")
  end)
  currentVersion = okV and currentVersion or nil

  local kind = classifyStart(previousVersion, currentVersion, previousCount)
  -- A driver UPDATE is not a controller reboot, and counting it as one would
  -- inflate the number on every release — of which there were eight today.
  local count = kind == "reload" and previousCount + 1 or previousCount
  local at = os.date("!%Y-%m-%dT%H:%M:%SZ")

  persist:set(RELOAD_COUNT_KEY, count)
  persist:set(RELOAD_AT_KEY, at)
  persist:set(RELOAD_KIND_KEY, kind)
  if currentVersion ~= nil then
    persist:set(RELOAD_VERSION_KEY, currentVersion)
  end

  return {
    count = count,
    at = at,
    kind = kind,
    previous_version = previousVersion,
    version = currentVersion,
  }
end

--- What the installer asked to be emailed about, as configured in Composer.
---
--- ── WHY THE DRIVER DOES NOT SEND THE EMAIL ──────────────────────────────────
---
--- A Control4 driver has no mail transport worth relying on: no SMTP
--- credentials, no sender reputation, no retry, and nowhere to see that a
--- message bounced. SmartBuildOS already sends mail for the rest of the
--- product, with a domain that is set up to be delivered.
---
--- So the CHOICE lives here — in Composer, next to the system it is about,
--- which is where an installer expects to configure it — and the SENDING
--- happens on the platform. The driver states its preferences with every
--- alert it raises; the platform is what turns one into a message.
--- @return table
function alertPreferences()
  local function on(name)
    return tostring(Properties[name] or "Off") == "On"
  end
  local to = tostring(Properties["Alert Email"] or ""):gsub("^%s+", ""):gsub("%s+$", "")
  return {
    email = to ~= "" and to or nil,
    on_reload = on("Email on Director Reload"),
    on_device_offline = on("Email on Device Offline"),
    on_low_battery = on("Email on Low Battery"),
    on_sync_failure = on("Email on Sync Failure"),
  }
end

--- Tell Composer, programming and SmartBuildOS about this start.
---
--- Every call here is optional, and every one can fail without costing
--- anything that matters: a property that did not update, an event nobody
--- received. What must NOT happen is any of it stopping the driver from
--- reporting — which is why the whole thing is guarded, and why it runs only
--- after the timers are armed.
local function announceStart()
  local ok, err = pcall(function()
    UpdateProperty("Director Reloads", tostring(gStart.count))
    UpdateProperty(
      "Last Reload",
      string.format("%s (%s)", (gStart.at or ""):gsub("T", " "):gsub("Z", " UTC"), gStart.kind or "unknown")
    )
    C4:SetVariable("DIRECTOR_RELOADS", gStart.count)
    C4:SetVariable("LAST_RELOAD", gStart.at)
  end)
  if not ok then
    log:warn("Could not publish the start state to Composer: %s", tostring(err))
  end

  -- Programming fires only for an actual reload. A driver update restarts the
  -- driver too, and firing "the controller rebooted" on every release would
  -- teach somebody to ignore it.
  if gStart.kind ~= "reload" then
    return
  end

  local firedOk, fireErr = pcall(function()
    C4:FireEvent("Director Reloaded")
  end)
  if not firedOk then
    log:warn("Could not fire the Director Reloaded event: %s", tostring(fireErr))
  end

  if isPaired() then
    local sentOk, sendErr = pcall(function()
      send("event", {
        kind = "event",
        name = "director_reloaded",
        detail = string.format("Director reload #%d", gStart.count),
        director_reloads = gStart.count,
        last_reload_at = gStart.at,
        alerts = alertPreferences(),
      }, "director reload")
    end)
    if not sentOk then
      log:warn("Could not report the reload to SmartBuildOS: %s", tostring(sendErr))
    end
  end
end

-- ─── Pairing state ────────────────────────────────────────────────────────────

--- @return string token The stored device token, or "" when unpaired.
local function deviceToken()
  return persist:get(TOKEN_KEY, "", true) or ""
end

--- @return string propertyId The paired SmartBuildOS property id, or "".
local function propertyId()
  return persist:get(PROPERTY_KEY, "") or ""
end

--- @return string systemId The paired SmartBuildOS system id, or "".
local function systemId()
  return persist:get(SYSTEM_KEY, "") or ""
end

--- Whether the driver holds a usable credential.
---
--- The TOKEN is the credential: the server resolves company, system and
--- property from it and treats anything the driver asserts as advisory. So a
--- system with no property is paired, and requiring a property id here is what
--- made a property-less pairing impossible to complete.
---
--- Either id satisfies the second half, so a driver paired before this change
--- — which stored a property and no system — stays paired across the upgrade.
--- @return boolean paired
local function isPaired()
  return deviceToken() ~= "" and (systemId() ~= "" or propertyId() ~= "")
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

--- Builds a Driver Cloud URL (a different API root than the ingest routes).
--- @param path string Path beneath /api/driver-cloud, no leading slash.
--- @return string|nil url The absolute URL, or nil when no base URL is set.
local function driverCloudUrl(path)
  local base = Properties["API URL"] or ""
  base = base:gsub("%s+", ""):gsub("/+$", "")
  if base == "" then
    return nil
  end
  return string.format("%s/api/driver-cloud/%s", base, path)
end

--- Returns the auth headers for an authenticated ingest request.
--- @return table<string, string> headers
local function authHeaders()
  return {
    ["Authorization"] = "Bearer " .. deviceToken(),
    ["Content-Type"] = "application/json",
    -- Both are advisory; the token decides. Sent when known, omitted rather
    -- than sent empty so a property-less system does not assert a blank one.
    ["X-SmartBuildOS-Property"] = propertyId(),
    ["X-SmartBuildOS-System"] = systemId(),
  }
end

--- What Composer calls this PROJECT, or nil.
---
--- ⚠ The 2026-08-19 sweep recorded "A DRIVER CANNOT READ THE COMPOSER PROJECT
--- NAME" and the plumbing for it was removed. That conclusion was wrong, and
--- it was wrong for a specific reason worth keeping: it asked
--- GetProjectHierarchy, which starts at the SITE (type 2, "Home" here) and
--- never shows the type-1 root above it. The docs' own LOCATIONS example does:
---
---   <item majorversion="4" ...><id>1</id><name>Miami-Beta</name><type>1</type>
---
--- Measured 2026-09-01 on the same controller that produced the "Home" answer.
--- Note it is "Miami-Beta" while the host name is "Beta-Miami" — two different
--- names, reversed, which is exactly why one must not be used for the other.
--- @return string|nil
local function composerProjectName()
  local ok, xml = pcall(function()
    return C4:GetProjectItems("LOCATIONS", "LIMIT_DEVICE_DATA", "NO_ROOT_TAGS")
  end)
  if not ok or type(xml) ~= "string" or xml == "" then
    return nil
  end
  for item in xml:gmatch("<item[^>]*>(.-)</item>") do
    if item:match("<type>%s*1%s*</type>") then
      local name = item:match("<name>%s*(.-)%s*</name>")
      if type(name) == "string" and name ~= "" then
        return (name:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&apos;", "'"):gsub("&amp;", "&"))
      end
      return nil
    end
  end
  return nil
end

--- Is this a routable IPv4 address a support engineer could actually dial?
---
--- Rejects loopback, the unspecified address and link-local: those are true
--- strings that answer the wrong question. "Director IP: 127.0.0.1" is worse
--- than a blank row, because a blank row prompts somebody to go and look
--- while a confident wrong answer ends the search.
--- @param value any
--- @return boolean
local function isRoutableIPv4(value)
  if type(value) ~= "string" then
    return false
  end
  local a, b, c, d = value:match("^%s*(%d+)%.(%d+)%.(%d+)%.(%d+)%s*$")
  if a == nil then
    return false
  end
  a, b, c, d = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
  for _, octet in ipairs({ a, b, c, d }) do
    if octet > 255 then
      return false
    end
  end
  if a == 127 or a == 0 then
    return false
  end
  if a == 169 and b == 254 then
    return false
  end
  return true
end

--- The controller's own LAN address, or nil.
---
--- ⚠ THE DRIVER RUNS ON THE CONTROLLER, so the obvious sources answer with the
--- controller's SELF-reference rather than its address on the network: the
--- Director appears in this driver's own device inventory as 127.0.0.1, which
--- is how directorIdentity finds it. The real address (192.168.1.123 on the
--- first controller) appears nowhere in that inventory.
---
--- ⚠ AND `GetNetworkConnections` IS NOT A FALLBACK, however much it looks like
--- one. It is PER-DEVICE: it lists a binding row per device, each with its own
--- `deviceid` and `address`. A first cut here scanned it for the first
--- routable IPv4 and the test fixture immediately handed back 192.168.1.40 —
--- an 8-Channel Relay. That would have printed another device's address under
--- "Director IP" on every system. Filtering to the Director's own row does not
--- rescue it either: that row is the loopback one, by construction.
---
--- So there is exactly one candidate, GetControllerNetworkAddress, documented
--- as "the address of the master controller in a project, in IP format". It
--- has never been observed on hardware, so it is not trusted — whatever it
--- says must survive isRoutableIPv4 before it is reported.
---
--- Reports nothing rather than something wrong. A blank Director IP is a
--- question somebody will go and answer; a loopback or a relay's address is a
--- wrong answer that ends the search. The diagnostics probes dump the raw
--- values, so if a real source does turn up it can be wired deliberately.
--- @return string|nil
local function controllerIp()
  local ok, address = pcall(function()
    return C4:GetControllerNetworkAddress()
  end)
  if ok and isRoutableIPv4(address) then
    return (address:match("^%s*(.-)%s*$"))
  end
  return nil
end

--- Collects the controller-level facts sent with every payload.
--- @return table<string, any> identity
local function systemIdentity()
  return {
    property_id = propertyId(),
    system_id = systemId(),
    controller_type = C4:GetSystemType(),
    os_version = C4:GetVersionInfo().version,
    driver_version = C4:GetDriverConfigInfo("version"),
    device_id = C4:GetDeviceID(),
    -- The DRIVER's own identity, named as such. Kept because it is genuinely
    -- useful (which instance, which version) — it was only ever wrong as an
    -- answer to "what is the Director?".
    driver_name = C4:GetDeviceData(C4:GetDeviceID(), "name"),
    driver_device_id = C4:GetDeviceID(),
    director_device_id = select(1, directorIdentity()),
    director_name = select(2, directorIdentity()),
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
--- @param onDelivered fun()|nil Called on ANY 2xx, before decoding. Delivery
---   confirmation must not depend on the body being parseable JSON: a proxy
---   that returns an empty 200 would otherwise turn "delivered" into
---   "unconfirmed", and anything retrying on unconfirmed would resend the
---   same payload forever.
--- Renders a rejected response body as something a person can act on.
---
--- ⚠ `err.body` is the DECODED response — a TABLE, not a string — so
--- `tostring()` on it yields "table: 0x4dd4abc05778". That is not a hypothetical:
--- on 2026-08-29 every device sync on every controller failed for about a day,
--- and SmartBuildOS said exactly why in the body it returned —
---
---   {"error":"Could not record device state.",
---    "detail":"PGRST204 Could not find the 'room_id' column"}
---
--- — while this driver reported `HTTP 503: table: 0x4dd4abc05778` to the
--- dealer's screen and to the platform's own event log. The cause was named,
--- travelled the whole way back, and was replaced with a pointer address at the
--- last step. The outage read as a pairing problem for a day because of it.
---
--- The platform's routes deliberately return `detail` alongside `error` for
--- this reason (see the devices route). Rendering it is the other half of that
--- contract.
--- @param body any Decoded response body, a string, or nil.
--- @return string
local function bodyText(body)
  if type(body) == "table" then
    local parts = {}
    if type(body.error) == "string" and body.error ~= "" then
      parts[#parts + 1] = body.error
    end
    if type(body.detail) == "string" and body.detail ~= "" then
      parts[#parts + 1] = body.detail
    end
    if #parts > 0 then
      return table.concat(parts, " — ")
    end
    -- No known shape: the whole body beats a pointer, truncated by the caller.
    local ok, encoded = pcall(function()
      return JSON:encode(body)
    end)
    return (ok and type(encoded) == "string") and encoded or "unreadable response body"
  end
  if body == nil or body == "" then
    return "no response body"
  end
  return tostring(body)
end

local function send(path, payload, description, onOk, onDelivered)
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
  -- The platform has parsed and displayed `composer_project_ref` since the
  -- technical inventory shipped, and nothing has ever sent it — the field has
  -- been blank in every system's inventory because the driver was told the
  -- project name was unreadable. It is not; see composerProjectName().
  local technical = {}
  local projectName = composerProjectName()
  if projectName ~= nil then
    technical.composer_project_ref = projectName
  end
  local ip = controllerIp()
  if ip ~= nil then
    technical.director_ip = ip
  end
  if next(technical) ~= nil then
    payload.technical_metadata = technical
  end
  payload.sent_at = os.time()

  log:debug("Sending %s to %s", description, url)
  http:post(url, payload, authHeaders(), { timeout = REQUEST_TIMEOUT }):next(function(response)
    gFailures = 0
    UpdateProperty("Last Successful Sync", os.date("%Y-%m-%d %H:%M:%S"))
    setConnected(true, "Connected")
    log:info("%s delivered (HTTP %s)", description, tostring(response.code))

    if onDelivered then
      pcall(onDelivered)
    end

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
      reason = string.format("HTTP %d: %s", code, bodyText(err.body))
      setConnected(false, string.format("HTTP %d", code))
      log:error("%s rejected with HTTP %d: %s", description, code, bodyText(err.body))
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
--- The name Composer shows for a project item, or nil.
---
--- `C4:GetProjectItems` returns the project as XML whose items look like
--- `<item><id>39</id><name>Apple TV Jesse Alt</name><type>6</type>...` — the
--- DEALER-TYPED name, which is the one worth reporting. Measured on this
--- project (diagnostics line 06).
---
--- Non-greedy to the first `</item>`, which is safe here only because `<id>`
--- and `<name>` precede any nested item in the observed shape. The id is
--- verified against the match rather than assumed by position.
--- @param id number
--- @return string|nil
function projectItemName(id)
  local ok, xml = pcall(function()
    return C4:GetProjectItems("DEVICES", "LIMIT_DEVICE_DATA", "NO_ROOT_TAGS")
  end)
  if not ok or type(xml) ~= "string" or xml == "" then
    return nil
  end
  -- `<item[^>]*>` and not a bare `<item>`: the DEVICES filter emits bare tags,
  -- but LOCATIONS emits `<item majorversion="4" ...>`, and a pattern that only
  -- matched the bare form silently found nothing there.
  for item in xml:gmatch("<item[^>]*>(.-)</item>") do
    if tonumber(item:match("<id>%s*(%d+)%s*</id>") or "") == id then
      local name = item:match("<name>%s*(.-)%s*</name>")
      if type(name) == "string" and name ~= "" then
        -- Composer permits & and < in a name; the XML carries them escaped.
        name = name:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&apos;", "'"):gsub("&amp;", "&")
        return name
      end
      return nil
    end
  end
  return nil
end

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
      detail = string
        .format(
          "%s: %d of %d answered across %s in %ds; %d not in project or monitored list: %s",
          reason,
          answered,
          settled,
          table.concat(swept, ", "),
          elapsed,
          #unknown,
          #unknown > 0 and table.concat(unknown, " ") or "none"
        )
        :sub(1, 400),
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
    send("devices", { kind = "snapshot", devices = list }, "full sync", collectCommands)

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
        -- Mirrored into the telemetry queue (T-2.1). The delta above is
        -- CURRENT STATE and a failed delta is only healed by the next full
        -- sync; the queued event survives an outage and replays with its
        -- ORIGINAL timestamp -- which is the whole point of a local journal:
        -- the internet being down is exactly when transitions matter.
        gTelemetry:add("DEVICE", {
          subcategory = device.online and "online" or "offline",
          source_type = device.source,
          source_id = device.key,
          source_name = device.name,
          control4_device_id = device.device_id,
          event_type = "transition",
          state = device.online and "online" or "offline",
        })
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
    send("devices", { kind = "delta", devices = changes }, "device delta", collectCommands)
  end)
end

--- The Composer-set write gate (D-8). The DRIVER is the authority: a platform
--- compromise cannot command a home whose dealer left this Off, because the
--- refusal happens here, behind the firewall, not in the cloud.
--- @return string setting "Off" | "Identify only"
local function remoteControlSetting()
  local value = tostring(Properties and Properties["Remote Control"] or "")
  if value == "" then
    return "Identify only"
  end
  return value
end

--- The write-tier ladder (D-8). Each tier is a SUPERSET of the ones below,
--- so a single numeric rank answers every gate: a runner needs rank >= N.
--- The homeowner sets this in Composer; the DRIVER is the authority, so no
--- platform state can command a home above the tier its dealer chose.
---   Off (0)           nothing
---   Identify only (1) flash a keypad's LEDs
---   Comfort (2)       lights, scenes, thermostat setpoints (clamped), camera snapshot
---   Full control (3)  locks, garage, security — and ONLY with per-action
---                     homeowner approval, which the platform enforces before
---                     the command is ever queued to this driver
--- @return integer rank 0..3
local function remoteControlRank()
  local v = remoteControlSetting()
  if v == "Full control" then
    return 3
  end
  if v == "Comfort" then
    return 2
  end
  if v == "Off" then
    return 0
  end
  return 1 -- "Identify only", and the safe default for any unknown value
end

--- What this build can do, as capability strings. Write capabilities are
--- DERIVED from the Composer property, so lowering Remote Control makes the
--- platform's buttons honestly disable at the next heartbeat — and the runner
--- refuses immediately in the meantime.
--- @return string[] capabilities
function driverCapabilities()
  local caps = {
    "device_monitoring",
    "telemetry_v1",
    "home_insights_v1",
    "catalogue_v1",
    "notify_v1",
    "realtime_v1",
  }
  local rank = remoteControlRank()
  if rank >= 1 then
    caps[#caps + 1] = "identify_v1"
  end
  if rank >= 2 then
    caps[#caps + 1] = "comfort_v1" -- lights, scenes, thermostat setpoints
    caps[#caps + 1] = "camera_v1" -- live snapshot, never persisted
  end
  if rank >= 3 then
    caps[#caps + 1] = "control_v1"
  end -- locks/garage/security
  return caps
end

--- The tier gate every write runner calls first. Defense in depth: the
--- platform gates too (capability + permission + homeowner approval for
--- control), but the LAST word is here, behind the firewall, where a platform
--- compromise cannot reach.
--- @param needed integer required rank
--- @param label string what was refused, for the ack
local function requireTier(needed, label)
  if remoteControlRank() < needed then
    error(string.format("%s needs a higher Remote Control tier than this home is set to (Composer property)", label))
  end
end

--- Resolve a c4:<id> payload key to a live device, or error by name.
local function resolveWriteTarget(payload)
  local key = tostring(payload.key or "")
  local id = tointeger(key:match("^c4:(%d+)$"))
  if id == nil then
    error("payload.key must be a c4:<device id> key")
  end
  local device = readDeviceState()[key]
  if device == nil then
    error("no such device in this project: " .. key)
  end
  return id, key, device
end

--- The HTTP snapshot URL for a camera device, or nil.
---
--- ── HOW A CAMERA IS ASKED ───────────────────────────────────────────────────
---
--- The camera proxy answers `GET_SNAPSHOT_QUERY_STRING`, which per the Snap One
--- Camera Proxy SDK "immediately returns a block of XML" of the form
--- `<snapshot_query_string>url-query-string</snapshot_query_string>` — the
--- QUERY STRING only, to be combined with the camera's own address.
---
--- ⚠ This resolver previously returned nil for every camera and said it was
--- "waiting on hardware", on the belief that the call was "an async proxy
--- return the shim cannot model". That was wrong, and it cost the feature: the
--- ASYNC pattern belongs to GET_STREAM_URLS, which answers later through the
--- separate STREAM_URLS_READY notify keyed back to the caller. Snapshots are
--- synchronous. `C4:SendUIRequest` is the synchronous driver-to-driver call and
--- it returns XML, which is exactly the shape the camera proxy documents.
---
--- The one thing NOT guessed is the path. We send the request and use what
--- comes back; a camera whose driver answers nothing still yields nil, because
--- a fabricated snapshot URL is worse than "no snapshot available" — it
--- produces a broken image instead of an honest refusal. The address is the
--- one the device inventory already holds, never invented.
--- @param device table Device record from readDeviceState().
--- @param id number|nil Control4 device id, for the proxy request.
--- @return string|nil url
--- @return string|nil why  Why there is no URL, for the failure message.
function snapshotUrlFor(device, id)
  -- An explicit URL on the record still wins: a camera integration that
  -- already knows its own snapshot path should not be re-interrogated.
  local carried = device and device.snapshot_url
  if type(carried) == "string" and carried:match("^https?://") then
    return carried, nil
  end

  local address = device and device.address
  if type(address) ~= "string" or not isRealAddress(address) then
    return nil, "the camera has no reachable address in this project"
  end
  if type(id) ~= "number" then
    return nil, "no device id to ask"
  end

  -- SIZE X / SIZE Y are the documented parameters. Asking for a modest frame
  -- keeps the relay well inside the payload budget; the viewer is a check on
  -- a camera, not a recording.
  local okReq, xml = pcall(function()
    return C4:SendUIRequest(id, "GET_SNAPSHOT_QUERY_STRING", { ["SIZE X"] = 640, ["SIZE Y"] = 480 })
  end)
  if not okReq then
    return nil, "the camera driver refused the snapshot request: " .. tostring(xml):sub(1, 80)
  end
  if type(xml) ~= "string" or xml == "" then
    return nil, "the camera driver does not answer GET_SNAPSHOT_QUERY_STRING"
  end

  local query = xml:match("<snapshot_query_string>%s*(.-)%s*</snapshot_query_string>")
  if query == nil or query == "" then
    -- Some drivers answer with the bare string rather than the documented
    -- wrapper. Accept that, but only when it cannot be anything else.
    local bare = xml:gsub("^%s+", ""):gsub("%s+$", "")
    if bare ~= "" and not bare:find("<") then
      query = bare
    else
      return nil, "the camera answered without a snapshot query string"
    end
  end

  local port = tonumber(device.http_port) or 80
  local base = port == 80 and string.format("http://%s", address) or string.format("http://%s:%d", address, port)
  -- The proxy returns a QUERY STRING, which may or may not carry its own
  -- leading separator. Normalising here keeps a double slash out of the URL.
  if query:sub(1, 1) ~= "/" and query:sub(1, 1) ~= "?" then
    query = "/" .. query
  end
  return base .. query, nil
end

--- The controller's own name, from its host name.
---
--- MEASURED 2026-09-01 on XDT_CORE1 / OS 4.2.0, the run that settled this:
---   GetHostname                    Beta-Miami-000FFF9CB2CB
---   projectItemName(19)            Control4 CORE 1
---   GetDeviceDisplayName(19)       System Controller
--- Composer shows this Director as "Beta-Miami". Only the host name carries
--- it. The project item is the MODEL (its config_data_file is
--- control4_core1.c4i — the item was never renamed), and GetDeviceDisplayName,
--- despite being documented as "the name of the device as shown in Composer",
--- answers with the generic proxy label.
---
--- Control4 forms the host name as `<name>-<MAC>`. The MAC suffix is stripped
--- only when it is exactly twelve hex digits after a dash, so a controller
--- named "Rack-1" keeps its name rather than being trimmed on a guess.
--- @return string|nil
local function controllerName()
  local ok, host = pcall(function()
    return C4:GetHostname()
  end)
  if not ok or type(host) ~= "string" then
    return nil
  end
  host = host:match("^%s*(.-)%s*$")
  if host == "" then
    return nil
  end
  return host:match("^(.+)%-%x%x%x%x%x%x%x%x%x%x%x%x$") or host
end

--- Cached Director identity; see directorIdentity().
local gDirector = { id = nil, name = nil, at = nil }
local DIRECTOR_CACHE_SECONDS = 3600

--- The DIRECTOR's identity — the controller this driver runs on.
---
--- ⚠ NOT this driver's, which is what was reported until 2026-08-29.
--- `C4:GetDeviceData(C4:GetDeviceID(), "name")` returns the `<name>` tag from
--- THIS DRIVER'S OWN driver.xml. That is documented behaviour — GetDeviceData
--- "returns data found in the driver's device data, <devicedata> XML" — so it
--- was always going to answer "SmartBuildOS Agent" and device 591, no matter
--- which controller it ran on. Composer showed the Director as "Beta-Miami",
--- device 19. Owner-confirmed.
---
--- ── HOW THE DIRECTOR IS FOUND ───────────────────────────────────────────────
---
--- By LOOPBACK. The controller this driver runs on is the one device that
--- reports 127.0.0.1. Measured on the live project: device 19,
--- "System Controller", c4:control4_core1, address 127.0.0.1 — the id the
--- owner confirmed.
---
--- Loopback is the discriminator, and device TYPE is not: the same project
--- holds two more c4:control4_core1 devices (584, 587) with no address at
--- all, so matching on type would pick whichever came first out of a pairs()
--- loop. This is also why `addressKey()` deliberately refuses to MATCH on
--- loopback across inventories — every controller has one — while
--- `hasUsableAddress()` accepts it as real. Both remain correct.
---
--- Confirmed on two projects and two controller models:
---   Fort Lauderdale Condo  device 19    "System Controller"  c4:control4_core1
---   Julie Dwyer            device 4656  "Dwyer-Director"     c4:control4_ca10
--- both at 127.0.0.1.
---
--- ⚠ 127.0.0.1 IS NOT THE CONTROLLER'S IP. It is how Director refers to
--- itself. The real LAN address of the first controller is 192.168.1.123
--- (owner-confirmed), and NOTHING in the project inventory carries it — the
--- network scan even lists .123 among the addresses that answered but are
--- "not in project". So this value must never be reported as a "Director IP";
--- that field needs a different source entirely.
---
--- The instance NAME comes from the project item, because that is where a
--- dealer-typed name lives. `C4:GetDevices()` returns the DRIVER's name
--- ("System Controller"); the project item carries what Composer shows.
--- ── CACHED, BECAUSE IT IS NOT FREE ──────────────────────────────────────────
---
--- This walks every device and parses the project XML (33KB on the live
--- project). It is called from three payload builders, twice each for the id
--- and the name, and the heartbeat runs every 30 seconds — so uncached it
--- would be six full project parses a minute to answer a question whose
--- answer changes when somebody re-names a controller in Composer. The TTL
--- makes a rename appear within the hour without paying for it every beat;
--- a driver restart clears it immediately.
--- @return number|nil id
--- @return string|nil name
function directorIdentity()
  -- A NEGATIVE age means the clock moved backwards, which a controller does
  -- on NTP correction after a cold boot. Treating that as "fresh" would pin
  -- the cache until the clock caught up — potentially forever. Re-read
  -- instead: the cost is one project parse, the alternative is a stale
  -- Director name nobody can flush without restarting the driver.
  local age = gDirector.at ~= nil and (os.time() - gDirector.at) or nil
  if age ~= nil and age >= 0 and age < DIRECTOR_CACHE_SECONDS then
    return gDirector.id, gDirector.name
  end

  -- The snapshot the driver already holds, not a fresh enumeration. A full
  -- read walks every device and its bindings; the poll has just done that and
  -- gDeviceState is the result. Falls back to a read only before the first
  -- poll, when there is no snapshot to consult.
  local snapshot = gDeviceState
  if snapshot == nil or next(snapshot) == nil then
    snapshot = readDeviceState() or {}
  end

  local id, driverName
  for key, device in pairs(snapshot) do
    if type(device) == "table" and device.address == "127.0.0.1" then
      id = tointeger(device.device_id) or tointeger(tostring(key):match("^c4:(%d+)$"))
      driverName = device.name
      break
    end
  end
  if id == nil then
    -- NOT cached: a missing controller is usually a snapshot that has not
    -- been taken yet, and caching that would keep the field empty for an hour
    -- after the project became readable.
    return nil, nil
  end
  -- Host name FIRST: it is the only one of the three that carries what an
  -- integrator typed. The project item name is the model and the device name
  -- is the proxy label, so both are kept only as fallbacks for a controller
  -- whose host name is unreadable or empty.
  gDirector = { id = id, name = controllerName() or projectItemName(id) or driverName, at = os.time() }
  return gDirector.id, gDirector.name
end

--- Fetch one snapshot and relay it to the platform — LIVE-ONLY, NEVER STORED.
--- The image goes to the camera-relay endpoint, which holds it transiently for
--- the one requesting viewer; nothing is written to a bucket or a row, and the
--- image never touches the bounded command ack. pcall'd end to end: a camera
--- that will not answer must never wedge the command pump.
--- @param key string c4:<id>
--- @param url string snapshot URL
--- @param requestId string correlates the relay to the viewer that asked
function postCameraSnapshot(key, url, requestId)
  http:get(url, {}, { timeout = REQUEST_TIMEOUT }):next(function(response)
    local body = response and response.body
    if type(body) ~= "string" or body == "" then
      return
    end
    local ok, encoded = pcall(function()
      return C4:Base64Encode(body)
    end)
    if not ok or type(encoded) ~= "string" then
      return
    end
    -- send() stamps identity + auth; the relay never persists this.
    send("camera-snapshot", {
      kind = "camera_snapshot",
      device_key = key,
      request_id = requestId,
      content_type = "image/jpeg",
      image_base64 = encoded,
    }, "camera snapshot")
  end, function()
    log:warn("Camera snapshot fetch failed for %s", key)
  end)
end

--- Posts one driver_events row for a non-Agent SKU (licenseEvent is
--- Agent-scoped and defined later in the file; this one takes the sku).
local function postDriverEvent(sku, severity, category, code, message)
  local url = driverCloudUrl("events")
  if not url or not isPaired() then
    return
  end
  pcall(function()
    http
      :post(url, {
        events = {
          { severity = severity, category = category, code = code, message = message, driver_sku = sku },
        },
      }, authHeaders(), { timeout = REQUEST_TIMEOUT })
      :next(function() end, function() end)
  end)
end

--- Which .c4z files carry which SKU. Remote settings are addressed by SKU
--- on the platform and delivered to DEVICES here, so the Agent needs the
--- mapping; a suite's children share the parent's SKU exactly as the store
--- publish map does. Unknown SKUs are simply not deliverable — an Agent
--- that predates a driver must never guess at filenames.
local SKU_FILENAMES = {
  SBOS_ATMOSPHERE = { "smartbuildos-atmosphere.c4z" },
  SBOS_MODE_COMPOSER = { "smartbuildos-mode-composer.c4z", "smartbuildos-mode-button.c4z" },
  SBOS_UNIFI_PROTECT = {
    "unifi-protect.c4z",
    "unifi-protect-camera.c4z",
    "unifi-protect-chime.c4z",
    "unifi-protect-input.c4z",
    "unifi-protect-light.c4z",
    "unifi-protect-sensor.c4z",
    "unifi-protect-viewport.c4z",
  },
}

--- Forwards ONE driver's remote settings from the heartbeat response to
--- every installed instance of that driver. Forwarded, not applied — the
--- receiving driver owns its versioned validation and answers with
--- SBOS_DRIVER_CONFIG_ACK. Change-gated per SKU so a static config does not
--- re-send on every heartbeat.
local function forwardDriverConfig(cfg, legacySku)
  if type(cfg) ~= "table" or cfg.settings == nil then
    return
  end
  local sku = tostring(cfg.driver_sku or legacySku or "")
  local filenames = SKU_FILENAMES[sku]
  if filenames == nil then
    return
  end
  local ok, encoded = pcall(function()
    return JSON:encode(cfg.settings)
  end)
  if not ok or type(encoded) ~= "string" then
    return
  end
  local fingerprintKey = "sbos_driver_config_fwd_" .. sku:lower()
  local fingerprint = tostring(cfg.settings_version or 1) .. "|" .. encoded
  if fingerprint == persist:get(fingerprintKey, "") then
    return
  end
  local sent = 0
  for _, filename in ipairs(filenames) do
    for id in pairs(C4:GetDevicesByC4iName(filename) or {}) do
      local deviceId = tonumber(id)
      if deviceId ~= nil then
        local params = {
          sku = sku,
          settings = encoded,
          settings_version = tostring(cfg.settings_version or 1),
          requester = tostring(C4:GetDeviceID()),
        }
        pcall(function()
          C4:SendToDevice(deviceId, "SBOS_DRIVER_CONFIG", params)
        end)
        -- Drivers released before the generic protocol listen for the
        -- Atmosphere-specific command; harmless for others to ignore.
        if sku == "SBOS_ATMOSPHERE" then
          pcall(function()
            C4:SendToDevice(deviceId, "SBOS_ATMOSPHERE_CONFIG", params)
          end)
        end
        sent = sent + 1
      end
    end
  end
  if sent > 0 then
    -- Remember only after a successful send so a driver added LATER still
    -- receives the current config on the next change (the fingerprint
    -- intentionally carries no target list; a fresh install with no config
    -- change waits for the next edit or re-pair — see
    -- SMARTBUILDOS_INTEGRATION).
    persist:set(fingerprintKey, fingerprint)
    log:info("%s settings forwarded to %d instance(s) (v%s)", sku, sent, tostring(cfg.settings_version or 1))
  end
end

--- The heartbeat's generic block: one entry per driver with remote settings.
local function forwardDriverConfigs(list)
  if type(list) ~= "table" then
    return
  end
  for _, cfg in ipairs(list) do
    forwardDriverConfig(cfg)
  end
end

--- A driver's answer to a forwarded config: audit-logged to Driver Cloud so
--- a dealer can see whether a remote change actually landed.
local function recordConfigAck(tParams, legacySku)
  tParams = tParams or {}
  local sku = tostring(tParams.sku or legacySku or "")
  if sku == "" then
    return
  end
  local applied = tostring(tParams.applied) == "true"
  local refused = tonumber(tParams.refused) or 0
  log:info(
    "%s config ack: applied=%s refused=%d (schema v%s)",
    sku,
    tostring(applied),
    refused,
    tostring(tParams.settings_version)
  )
  postDriverEvent(
    sku,
    applied and (refused > 0 and "WARNING" or "INFO") or "ERROR",
    "CONFIGURATION",
    applied and "remote_settings_applied" or "remote_settings_refused",
    string.format("Remote settings v%s: %d field(s) refused", tostring(tParams.settings_version), refused)
  )
end

function EC.SBOS_DRIVER_CONFIG_ACK(tParams)
  recordConfigAck(tParams)
end

--- Back-compat for drivers released before the generic protocol.
function EC.SBOS_ATMOSPHERE_CONFIG_ACK(tParams)
  recordConfigAck(tParams, "SBOS_ATMOSPHERE")
end

--- Atmosphere cloud state mirror: the Atmosphere driver asks us to publish
--- its UI state (so its app works off-LAN, where the LAN relay is
--- unreachable). We fetch the state from the driver's OWN relay on
--- the controller's private LAN address — same-controller, avoids inter-driver message size limits —
--- and POST it with our bearer auth. Throttled here as the last line of
--- defense; the driver throttles too.
--- Per-SKU throttle. One shared timestamp would let a chatty driver spend
--- another driver's budget, so each SKU gets its own window.
local gStateLastPush = {}
local STATE_THROTTLE_SECONDS = 45

--- Mirrors ONE driver's UI state to SmartBuildOS.
---
--- The driver asks; this does the fetch and the authenticated POST, because
--- the Agent is where the account credentials live and a dependent driver
--- must never hold them. The state is read from the asking driver's own LAN
--- server over the controller's private LAN address — same controller, so
--- inter-driver message size limits never apply. Older drivers that do not
--- send an address retain the original loopback fallback.
---
--- tParams: sku, port, path (default /state), relay_host, app_token,
--- requester, urgent.
local function privateRelayHost(value)
  local host = tostring(value or ""):match("^%s*(.-)%s*$")
  local a, b, c, d = host:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
  a, b, c, d = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
  if a == nil or b == nil or c == nil or d == nil or a > 255 or b > 255 or c > 255 or d > 255 then
    return nil
  end
  if
    a == 10
    or a == 127
    or (a == 169 and b == 254)
    or (a == 172 and b >= 16 and b <= 31)
    or (a == 192 and b == 168)
    or (a == 100 and b >= 64 and b <= 127)
  then
    return string.format("%d.%d.%d.%d", a, b, c, d)
  end
  return nil
end

--- Accept a LAN relay address only when Director reports that exact address
--- on a Control4 controller device. Merely being RFC1918 is insufficient: a
--- sibling driver could otherwise turn the legacy command into an Agent-side
--- fetch of any router, NAS, or service on the customer's LAN.
local function controllerRelayHost(value)
  local wanted = privateRelayHost(value)
  if wanted == nil then
    return nil
  end
  if wanted == "127.0.0.1" then
    return wanted
  end
  local function containsAddress(node, depth, seen)
    if type(node) ~= "table" or depth > 6 or seen[node] then
      return false
    end
    seen[node] = true
    if privateRelayHost(node.addr) == wanted then
      return true
    end
    for _, child in pairs(node) do
      if type(child) == "table" and containsAddress(child, depth + 1, seen) then
        return true
      end
    end
    return false
  end
  local okDevices, devices = pcall(function()
    return C4:GetDevices({})
  end)
  if not okDevices or type(devices) ~= "table" then
    return nil
  end
  for rawId, device in pairs(devices) do
    local id = tonumber(rawId)
    local file = tostring(type(device) == "table" and device.driverFileName or "")
    if id ~= nil and file:find("^control4_") ~= nil then
      for _, api in ipairs({ "GetNetworkBindingsByDevice", "GetBindingsByDevice" }) do
        local okBindings, bindings = pcall(function()
          return C4[api](C4, id)
        end)
        if okBindings and containsAddress(bindings, 0, {}) then
          return wanted
        end
      end
    end
  end
  return nil
end

local function mirrorDriverState(tParams, legacy)
  tParams = tParams or {}
  local sku = tostring(tParams.sku or "")
  local port = tonumber(tParams.port)
  local token = tostring(tParams.app_token or "")
  local path = tostring(tParams.path or "/state")
  local requester = tonumber(tParams.requester)
  if sku == "" or port == nil or port < 1 or port > 65535 or port % 1 ~= 0 or token == "" then
    return
  end
  if path:sub(1, 1) ~= "/" then
    path = "/" .. path
  end
  local last = gStateLastPush[sku] or 0
  if os.time() - last < STATE_THROTTLE_SECONDS and tostring(tParams.urgent) ~= "true" then
    return
  end
  local base = tostring(Properties["API URL"] or ""):gsub("/+$", "")
  if base == "" or not isPaired() then
    return
  end
  -- OS 4.2 hardware proved that 127.0.0.1 can hang when one driver fetches
  -- another driver's CreateServer listener. A current driver sends the same
  -- private controller address its Navigator app already uses successfully.
  -- Reject public/malformed addresses so this inter-driver command cannot be
  -- turned into an arbitrary Agent-side HTTP request.
  local relayHost = controllerRelayHost(tParams.relay_host) or "127.0.0.1"
  local localUrl = string.format("http://%s:%d%s?k=%s", relayHost, port, path, token)
  log:debug("%s state fetch from %s:%d%s", sku, relayHost, port, path)
  http:get(localUrl, {}, { timeout = 10 }):next(function(resp)
    local ok, state = pcall(function()
      return JSON:decode(resp.body)
    end)
    if not ok or type(state) ~= "table" then
      return
    end
    gStateLastPush[sku] = os.time()
    -- The ack a successful post produces, either route.
    local function announce(postResp)
      local okB, body = pcall(function()
        return JSON:decode(postResp.body)
      end)
      if not okB or type(body) ~= "table" or body.view_url == nil or requester == nil then
        return
      end
      local ack = {
        sku = sku,
        view_url = tostring(body.view_url),
        view_handle = tostring(body.view_handle or ""),
      }
      pcall(function()
        C4:SendToDevice(requester, "SBOS_DRIVER_STATE_ACK", ack)
      end)
      -- A driver that asked with the legacy command is listening for the
      -- legacy ack name; without this it would mirror successfully and
      -- still never learn its capability URL.
      if legacy then
        pcall(function()
          C4:SendToDevice(requester, "SBOS_ATMOSPHERE_STATE_ACK", ack)
        end)
      end
    end

    local payload = { driver_sku = sku, state = state, app_token = token }
    http
      :post(driverCloudUrl("state"), payload, authHeaders(), { timeout = REQUEST_TIMEOUT })
      :next(announce, function(err)
        -- A platform that predates the generic route answers 404. Deploy
        -- order between this driver and the server is not ours to control
        -- (a dealer updates drivers whenever, and a rollback can move the
        -- server backwards), so Atmosphere retries its original route
        -- rather than going dark. Any other failure is just logged.
        local code = type(err) == "table" and tonumber(err.code) or nil
        if code == 404 and sku == "SBOS_ATMOSPHERE" then
          log:debug("Generic state route absent; falling back to the Atmosphere route")
          http
            :post(
              driverCloudUrl("atmosphere/state"),
              { state = state, app_token = token },
              authHeaders(),
              { timeout = REQUEST_TIMEOUT }
            )
            :next(announce, function(err2)
              log:debug("%s state push failed: %s", sku, tostring(type(err2) == "table" and err2.error or err2))
            end)
          return
        end
        log:debug("%s state push failed: %s", sku, tostring(type(err) == "table" and err.error or err))
      end)
  end, function()
    log:debug("%s state fetch from %s:%d%s failed", sku, relayHost, port, path)
  end)
end

function EC.SBOS_DRIVER_STATE(tParams)
  mirrorDriverState(tParams)
end

--- Back-compat: drivers released before the generic protocol ask with the
--- Atmosphere-specific command and no sku. Kept so a mixed-version fleet
--- keeps mirroring during a rollout; remove once no field build sends it.
function EC.SBOS_ATMOSPHERE_STATE(tParams)
  tParams = tParams or {}
  tParams.sku = tParams.sku or "SBOS_ATMOSPHERE"
  mirrorDriverState(tParams, true)
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
      -- What this driver can DO, so the platform never sends a command an
      -- older build cannot run. Strings, not booleans: a newer server reading
      -- an older driver sees absence, which is the correct claim.
      capabilities = driverCapabilities(),
      -- The queue confesses its own state. A queue that sheds data invisibly
      -- turns a gap in a report into "the house was quiet".
      queued_telemetry = gTelemetry:depth(),
      telemetry_dropped = gTelemetry:dropped(),
      -- The cadence actually in force, stated rather than inferred.
      heartbeat_seconds = activeHeartbeatSeconds(),
      -- The self-update channel's own account of itself.
      update_channel = gUpdate,
      -- How many times Director has come back under this driver, and when.
      -- On the heartbeat rather than only on the event, so a platform that
      -- missed the event still converges on the truth.
      director_reloads = gStart.count,
      last_reload_at = gStart.at,
      last_reload_kind = gStart.kind,
    },
    "heartbeat",
    function(body)
      -- The response is how configuration reaches this driver. It has no inbound
      -- channel — it sits behind the client's firewall and is never contacted —
      -- so an installer's choices in SmartBuildOS ride back on a call it already
      -- makes, rather than costing a second timer to poll for them.
      collectCommands(body)

      -- ⚠ ABOVE the monitor early-return, deliberately. An address correction
      -- must land whether or not the response carries a monitoring block, and
      -- putting it below would make the refresh depend on an unrelated
      -- feature being configured.
      --
      -- Refreshed every heartbeat rather than only at pairing: an address
      -- fixed in SmartBuildOS would otherwise stay wrong in Composer until
      -- somebody re-paired, and a stale address on a rack is worse than none.
      local label = type(body.site_label) == "string" and body.site_label or ""
      if label ~= (persist:get(SITE_LABEL_KEY, "") or "") then
        persist:set(SITE_LABEL_KEY, label)
        showPairingState()
        log:info("Site address updated to %s", label ~= "" and label or "(none)")
      end

      -- The doorbell offer rides every heartbeat and is applied ABOVE the
      -- monitor early-return for the same reason the site label is: it must
      -- land whether or not the response carries a monitoring block. pcall'd
      -- because the accelerator must never break the transport it accelerates.
      pcall(applyRealtimeConfig, body.realtime)

      -- Atmosphere remote settings ride the same heartbeat (this driver has
      -- no inbound channel), ABOVE the monitor early-return for the same
      -- reason the site label is.
      -- Generic block: one entry per driver with remote settings. The
      -- legacy `atmosphere` block is still honored so an older platform
      -- deploy keeps configuring Atmosphere during a rollout.
      pcall(forwardDriverConfigs, body.driver_config)
      pcall(forwardDriverConfig, body.atmosphere, "SBOS_ATMOSPHERE")

      local monitor = body.monitor
      if type(monitor) ~= "table" then
        return
      end

      -- Re-registering listeners on every heartbeat would be pointless churn, so
      -- only a real change is applied.
      local before = JSON:encode(gMonitor)
      local heartbeatSeconds = tointeger(monitor.heartbeat_seconds)
      if heartbeatSeconds ~= nil then
        heartbeatSeconds = math.max(30, math.min(heartbeatSeconds, 3600))
      end
      gMonitor = {
        enabled = monitor.enabled == true,
        room_variables = type(monitor.room_variables) == "table" and monitor.room_variables or {},
        room_ids = type(monitor.room_ids) == "table" and monitor.room_ids or {},
        climate_enabled = monitor.climate_enabled ~= false,
        climate_sample_minutes = tointeger(monitor.climate_sample_minutes) or 15,
        -- Platform-set check-in cadence, nil = the Composer property decides.
        -- This exists because the property CANNOT be trusted to hold a value:
        -- an open Composer session re-pushes its cached properties after a
        -- driver restart, which is how the 1m migration got silently reverted
        -- to 5m on 2026-08-18. The platform is the management plane.
        heartbeat_seconds = heartbeatSeconds,
      }
      if JSON:encode(gMonitor) ~= before then
        log:info(
          "Monitoring configuration changed (enabled=%s, %d variable(s))",
          tostring(gMonitor.enabled),
          #gMonitor.room_variables
        )
        -- The cadence may be what changed, and timers are armed from config.
        scheduleTimers()
        applyMonitoring()
        if gMonitor.enabled then
          sendCatalogue()
        end
      end
    end
  )
end

-- ─── Collected commands (Phase 10, T-10.1) ──────────────────────────────────
--
-- Commands ride back on responses to requests this driver already makes — the
-- heartbeat and the device sends. There is no poll, no listener, no inbound
-- anything: the platform stores a request, and the next time this driver
-- speaks, the answer to "anything for me?" comes home with the receipt.
--
-- Every command in the v1 vocabulary asks this driver to REPORT something it
-- already reports on its own schedule. Nothing here can act on the house, and
-- an unknown command is acked as failed with its name — visible on the
-- dealer's screen rather than swallowed, because "the driver ignored it" and
-- "the driver cannot do it" deserve different next moves.

--- What each permitted command runs. Thunks, so the table reads as the
--- allowlist it is.
local COMMAND_RUNNERS = {
  REQUEST_FULL_SYNC = function()
    sendFullSync()
    return "full sync sent"
  end,
  REQUEST_HEARTBEAT = function()
    sendHeartbeat()
    return "heartbeat sent"
  end,
  REQUEST_DIAGNOSTICS = function()
    reportDiagnostics(true)
    return "diagnostics reported"
  end,
  RUN_NETWORK_SCAN = function()
    runNetworkScan("remote")
    return "network scan started"
  end,
  PROBE_CAPABILITIES = function()
    EC.PROBE_CAPABILITIES()
    return "capability probe started"
  end,
  -- Exists because on 2026-08-21 a catalogue resend had to be faked by nudging
  -- the monitor config (climate_sample_minutes 15→16→15) — config changes are
  -- the only other path to sendCatalogue(). A diagnostic that needs a
  -- side-effectful hack to trigger is a diagnostic nobody runs.
  REQUEST_CATALOGUE = function()
    sendCatalogue()
    return "catalogue sent"
  end,
  -- A platform-authored notice, surfaced through Control4's OWN channels.
  --
  -- Two halves, verified against the SDK docs 2026-08-21, because they solve
  -- different halves of the problem:
  --
  --   FireEvent    fixed-name events ("Issue Detected") the dealer wires to
  --                the Notification Agent ONCE — that wiring is what makes the
  --                phone buzz. Event names cannot carry text.
  --   RecordHistory the dynamic text, into the app's History feed — which is
  --                where a 3.4+ push deep-links to. Returns nil (not an
  --                error) when the History agent is not installed.
  --
  -- The driver never invents a message: it relays what the platform sent,
  -- bounded, and acks exactly which halves landed so the platform can tell
  -- "delivered" from "no History agent on this site".
  SEND_NOTIFICATION = function(payload)
    local kind = tostring(payload.kind or "update")
    local title = tostring(payload.title or ""):sub(1, 120)
    local detail = tostring(payload.detail or ""):sub(1, 400)
    if title == "" then
      error("notification without a title")
    end

    local EVENT_FOR = {
      update = "Service Update",
      issue = "Issue Detected",
      issue_update = "Issue Updated",
      resolved = "Issue Resolved",
    }
    local eventName = EVENT_FOR[kind] or EVENT_FOR.update
    C4:FireEvent(eventName)

    -- Severity: the platform may state it; otherwise it follows the kind. The
    -- vocabulary is closed so Composer comparisons ("is Critical") never meet
    -- a spelling they were not written against.
    local SEVERITIES = { info = "Info", warning = "Warning", critical = "Critical" }
    local severity = SEVERITIES[tostring(payload.severity or ""):lower()]
      or ((kind == "issue" or kind == "issue_update") and "Warning" or "Info")

    -- ── The programming bridge ───────────────────────────────────────────────
    --
    -- Variables, because events alone made dealer programming convoluted: an
    -- event says THAT something happened, never WHAT — so every distinct
    -- reaction needed its own Notification Agent wiring and none could branch.
    -- These four let one wiring carry everything:
    --
    --   NOTICE_TYPE     what kind of notice, always
    --   ISSUE_SEVERITY  Info/Warning/Critical while an issue is active, else None
    --   ISSUE_TEXT      the active issue, empty when clear
    --   NOTICE_TEXT     the last plain notice / appointment message
    --
    -- Issue text and severity are STATE, not a log: resolved clears them, so
    -- "if ISSUE_SEVERITY is Critical" is always about the house as it stands.
    local text = detail ~= "" and (title .. " — " .. detail) or title
    pcall(function()
      C4:SetVariable("NOTICE_TYPE", eventName)
      if kind == "issue" or kind == "issue_update" then
        C4:SetVariable("ISSUE_SEVERITY", severity)
        C4:SetVariable("ISSUE_TEXT", text)
      elseif kind == "resolved" then
        C4:SetVariable("ISSUE_SEVERITY", "None")
        C4:SetVariable("ISSUE_TEXT", "")
      else
        C4:SetVariable("NOTICE_TEXT", text)
      end
    end)

    local uuid = nil
    local historySeverity = severity == "Info" and "Info" or (severity == "Critical" and "Critical" or "Warning")
    pcall(function()
      uuid = C4:RecordHistory(historySeverity, title, "SmartBuildOS", eventName, detail)
    end)

    if uuid ~= nil then
      return string.format("event %s fired; history %s", eventName, tostring(uuid))
    end
    return string.format("event %s fired; history unavailable on this controller", eventName)
  end,
  -- W1's first write (D-8): flash a keypad's LEDs so a tech can physically
  -- find it — the affordance the device-linking review screen needs on a
  -- house full of "Keypad 2"s. Deliberately the SMALLEST possible write:
  -- visible, self-reverting, and touching nothing that changes how the home
  -- behaves.
  --
  -- Gate first, always: the Composer "Remote Control" property is the
  -- homeowner-side authority, and the refusal happens HERE even if the
  -- platform's capability picture is stale.
  --
  -- Command vocabulary VERIFIED_BY_DOCS (proxyprotocol-keypad):
  -- KEYPAD_ALL_BUTTON_COLOR sets CURRENT_COLOR immediately;
  -- KEYPAD_ALL_BUTTON_COLOR_CLEAR restores the programmed colors. Hardware
  -- confirmation pending, per the matrix rule that docs rank below hardware.
  IDENTIFY_DEVICE = function(payload)
    if remoteControlSetting() == "Off" then
      error("remote control is disabled on this system (Composer property)")
    end
    local key = tostring(payload.key or "")
    local id = tointeger(key:match("^c4:(%d+)$"))
    if id == nil then
      error("payload.key must be a c4:<device id> key")
    end
    local device = readDeviceState()[key]
    if device == nil then
      error("no such device in this project: " .. key)
    end
    -- Keypads only, by POSITIVE signature (the fourth-impostor rule): the
    -- binding's ssdptype on real hardware, the driver file name as a second
    -- witness. Anything else refuses by name rather than flashing a guess.
    local dtype = tostring(device.device_type or ""):lower()
    local dfile = tostring(device.driver_file or ""):lower()
    local isKeypad = dtype:find("control4_kp", 1, true) ~= nil
      or dtype:find("keypad", 1, true) ~= nil
      or dfile:find("keypad", 1, true) ~= nil
      or dfile:find("_kp", 1, true) ~= nil
    if not isKeypad then
      error(
        string.format(
          "identify supports keypads only for now; %s is %s",
          key,
          dtype ~= "" and dtype or (dfile ~= "" and dfile or "untyped")
        )
      )
    end
    local seconds = tointeger(payload.seconds) or 5
    if seconds < 1 then
      seconds = 1
    elseif seconds > 30 then
      seconds = 30
    end
    C4:SendToDevice(
      id,
      "KEYPAD_ALL_BUTTON_COLOR",
      { CURRENT_COLOR = "ff0000", ON_COLOR = "ff0000", OFF_COLOR = "ff0000" }
    )
    -- Self-reverting: the clear is scheduled BEFORE we report success, and is
    -- pcall'd so a restore failure logs rather than wedging the timer pump.
    SetTimer("SmartBuildOSIdentify" .. id, seconds * ONE_SECOND, function()
      local ok = pcall(function()
        C4:SendToDevice(id, "KEYPAD_ALL_BUTTON_COLOR_CLEAR", {})
      end)
      if not ok then
        log:error("Identify: could not restore LED colors on device %d", id)
      end
    end)
    return string.format("identify: flashing %s (%s) for %ds", tostring(device.name or key), key, seconds)
  end,

  -- ── W2 COMFORT (D-8, comfort_v1) ─────────────────────────────────────────
  -- Visible, reversible, bounded. Vocabulary VERIFIED_BY_DOCS (lightv2 /
  -- tstat proxy protocols); hardware confirmation pending per the matrix.

  -- Lights: level 0..100 ramps a dimmer; a bare on/off toggles a switch.
  SET_LIGHT = function(payload)
    requireTier(2, "light control")
    local id, key = resolveWriteTarget(payload)
    local on = payload.on
    local level = tointeger(payload.level)
    if level ~= nil then
      if level < 0 then
        level = 0
      elseif level > 100 then
        level = 100
      end
      C4:SendToDevice(id, "RAMP_TO_LEVEL", { LEVEL = level, TIME = 1000 })
      return string.format("light %s -> %d%%", key, level)
    end
    if on == true then
      C4:SendToDevice(id, "ON", {})
      return string.format("light %s -> on", key)
    elseif on == false then
      C4:SendToDevice(id, "OFF", {})
      return string.format("light %s -> off", key)
    end
    error("SET_LIGHT needs on:boolean or level:0..100")
  end,

  -- Thermostat setpoints, CLAMPED to 60..85F and never able to turn the
  -- system off or change mode (D-8 ruling): a remote command may make a home
  -- more comfortable, never leave it dangerously cold or hot.
  SET_THERMOSTAT = function(payload)
    requireTier(2, "thermostat control")
    local id, key = resolveWriteTarget(payload)
    local function clamp(v)
      v = tointeger(v)
      if v == nil then
        return nil
      end
      if v < 60 then
        return 60
      elseif v > 85 then
        return 85
      end
      return v
    end
    local heat, cool, single = clamp(payload.heat_f), clamp(payload.cool_f), clamp(payload.single_f)
    local applied = {}
    if single ~= nil then
      C4:SendToDevice(id, "SET_SETPOINT_SINGLE", { FAHRENHEIT = single })
      applied[#applied + 1] = "single=" .. single
    end
    if heat ~= nil then
      C4:SendToDevice(id, "SET_SETPOINT_HEAT", { FAHRENHEIT = heat })
      applied[#applied + 1] = "heat=" .. heat
    end
    if cool ~= nil then
      C4:SendToDevice(id, "SET_SETPOINT_COOL", { FAHRENHEIT = cool })
      applied[#applied + 1] = "cool=" .. cool
    end
    if #applied == 0 then
      error("SET_THERMOSTAT needs heat_f, cool_f, or single_f (60..85)")
    end
    return string.format("thermostat %s: %s", key, table.concat(applied, ", "))
  end,

  -- Scene activation. Vocabulary least-certain of the comfort set (the scene
  -- agent's invoke command varies by driver); marked hardware-gated and
  -- refuses by name rather than firing a guess that changes the wrong scene.
  ACTIVATE_SCENE = function(payload)
    requireTier(2, "scene activation")
    local id, key = resolveWriteTarget(payload)
    C4:SendToDevice(id, "DO_PUSH", { BUTTON_ID = tointeger(payload.button) or 1 })
    return string.format("scene %s invoked", key)
  end,

  -- ── W3 CONTROL (D-8, control_v1) ─────────────────────────────────────────
  -- Locks, garage, security. The Composer "Full control" tier is the
  -- driver-side hard gate; the platform enforces PER-ACTION HOMEOWNER
  -- APPROVAL before a command of this class is ever queued here, so a command
  -- reaching this runner has already been approved by the person in the home.
  -- LOCK/UNLOCK/OPEN/CLOSE and PARTITION_ARM/DISARM are VERIFIED_BY_DOCS.

  LOCK_DEVICE = function(payload)
    requireTier(3, "lock control")
    local id, key = resolveWriteTarget(payload)
    local action = tostring(payload.action or "")
    if action == "lock" then
      C4:SendToDevice(id, "LOCK", {})
    elseif action == "unlock" then
      C4:SendToDevice(id, "UNLOCK", {})
    else
      error("LOCK_DEVICE needs action: lock | unlock")
    end
    return string.format("lock %s -> %s", key, action)
  end,

  GARAGE_DEVICE = function(payload)
    requireTier(3, "garage control")
    local id, key = resolveWriteTarget(payload)
    local action = tostring(payload.action or "")
    if action == "open" then
      C4:SendToDevice(id, "OPEN", {})
    elseif action == "close" then
      C4:SendToDevice(id, "CLOSE", {})
    else
      error("GARAGE_DEVICE needs action: open | close")
    end
    return string.format("garage %s -> %s", key, action)
  end,

  SECURITY_PARTITION = function(payload)
    requireTier(3, "security control")
    local id, key = resolveWriteTarget(payload)
    local action = tostring(payload.action or "")
    local code = tostring(payload.code or "")
    if action == "arm" then
      C4:SendToDevice(id, "PARTITION_ARM", {
        ArmType = tostring(payload.arm_type or "Away"),
        UserCode = code ~= "" and code or nil,
        InterfaceID = "SmartBuildOS",
      })
    elseif action == "disarm" then
      if code == "" then
        error("disarm needs a user code")
      end
      C4:SendToDevice(id, "PARTITION_DISARM", { UserCode = code, InterfaceID = "SmartBuildOS" })
    else
      error("SECURITY_PARTITION needs action: arm | disarm")
    end
    -- The code is NEVER echoed back in the ack.
    return string.format("security %s -> %s", key, action)
  end,

  -- ── CAMERA SNAPSHOT (D-8, camera_v1) ─────────────────────────────────────
  -- Live-only, NEVER stored. The driver fetches one JPEG and POSTs it to the
  -- platform's camera-relay endpoint, which holds it transiently and hands it
  -- to the one requesting viewer — nothing is written to a bucket or a row.
  -- The image never rides the command ack (bounded at 400 chars); the ack
  -- only reports whether the snapshot was captured. GET_SNAPSHOT_QUERY_STRING
  -- is VERIFIED_BY_DOCS; the async proxy return is the hardware-gated part.
  CAMERA_SNAPSHOT = function(payload)
    requireTier(2, "camera snapshot")
    local id, key, device = resolveWriteTarget(payload)
    local url, why = snapshotUrlFor(device, id)
    if url == nil then
      -- The REASON, not a shrug. "camera driver does not expose one" was true
      -- of every camera and told nobody which of several things to check.
      error(string.format("no snapshot for %s: %s", key, why or "unknown reason"))
    end
    -- Fetch and relay happen off the ack path; the ack confirms the attempt.
    postCameraSnapshot(key, url, tostring(payload.request_id or ""))
    return string.format("camera %s: snapshot requested", key)
  end,
}

--- Executes whatever a response carried and acknowledges every outcome.
--- @param body table A decoded response body that may carry `commands`.
collectCommands = function(body)
  local commands = type(body) == "table" and body.commands or nil
  if type(commands) ~= "table" or #commands == 0 then
    return
  end

  local acks = {}
  for _, cmd in ipairs(commands) do
    local id = type(cmd) == "table" and tostring(cmd.id or "") or ""
    local name = type(cmd) == "table" and tostring(cmd.command or "") or ""
    if id ~= "" then
      local runner = COMMAND_RUNNERS[name]
      if runner == nil then
        log:warn("Remote command %s is not one this build understands", name)
        acks[#acks + 1] = { id = id, ok = false, error = "unknown command: " .. name }
      else
        log:info("Running remote command %s", name)
        local ok, result = pcall(runner, type(cmd.payload) == "table" and cmd.payload or {})
        if ok then
          acks[#acks + 1] = { id = id, ok = true, result = tostring(result) }
        else
          acks[#acks + 1] = { id = id, ok = false, error = tostring(result):sub(1, 400) }
        end
      end
    end
  end

  if #acks > 0 then
    send("commands", { acks = acks }, string.format("%d command ack(s)", #acks))
  end
end

--- Uploads queued telemetry, with backoff that fails soft.
---
--- Every 45s when the queue has anything -- inside the 30-60s window the
--- ingest is budgeted for.
---
--- ── FAILURE IS OBSERVED, NOT GUESSED ────────────────────────────────────────
---
--- send() is asynchronous: nothing about this request is knowable on the line
--- after it. So the batch is held IN FLIGHT rather than assumed delivered;
--- the success callback releases it, and the NEXT tick finding it still held
--- is the failure signal -- at which point it goes back to the queue (an
--- upload failure must not delete an evening) and uploading backs off
--- exponentially, 90s doubling to a 12-minute cap. Collection never pauses;
--- only uploading does.
---
--- A batch that was actually delivered but slowly -- landed after the next
--- tick already reclaimed it -- gets resent and DEDUPED at ingest by its
--- idempotency keys. That is what they are for: the failure mode of this
--- design is a wasted request, never a doubled count.
local gTelemetrySkip = 0
local gInflight = nil
flushTelemetry = function()
  if not isPaired() then
    return
  end

  -- Whatever was in flight at the last tick and never confirmed: failed.
  if gInflight ~= nil then
    local returned = gInflight
    gInflight = nil
    gTelemetry:putBack(returned)
    gTelemetryFailures = gTelemetryFailures + 1
    gTelemetrySkip = math.min(2 ^ gTelemetryFailures, 16)
    log:warn("Telemetry batch of %d not confirmed; requeued, backing off %d tick(s)", #returned, gTelemetrySkip)
  end

  if gTelemetrySkip > 0 then
    gTelemetrySkip = gTelemetrySkip - 1
    return
  end
  if gTelemetry:depth() == 0 then
    return
  end

  local batch = gTelemetry:takeBatch()
  gInflight = batch
  send(
    "telemetry",
    { kind = "telemetry", events = batch },
    string.format("telemetry batch of %d", #batch),
    function(body)
      -- The platform says how many it kept; a shortfall is dropped-by-policy
      -- (unknown category, clock out of range) -- worth a line, not an alarm.
      if type(body) == "table" and tointeger(body.dropped) ~= nil and tointeger(body.dropped) > 0 then
        log:warn("Platform dropped %d telemetry event(s) by policy", tointeger(body.dropped))
      end
    end,
    function()
      -- Confirmation rides DELIVERY (any 2xx), deliberately not the decoded
      -- body: an empty-bodied 200 through some middlebox must read as
      -- delivered, or this loop resends the same batch forever while ingest
      -- dedupes it -- an infinite, invisible, low-rate retry.
      gInflight = nil
      gTelemetryFailures = 0
      gTelemetrySkip = 0
    end
  )
end

--- The check-in interval actually in force: the platform's monitor config
--- wins, the Composer property is the fallback. Global so the heartbeat can
--- REPORT it — cadence should be a stated fact on the platform, not a
--- timestamp-gap inference (which is how a reverted value went unnoticed).
function activeHeartbeatSeconds()
  return gMonitor.heartbeat_seconds or INTERVALS[Properties["Heartbeat Interval"] or ""] or INTERVALS["15m"]
end

--- (Re)arms every reporting timer from the current properties and config.
function scheduleTimers()
  CancelTimer(HEARTBEAT_TIMER)
  CancelTimer(DEVICE_POLL_TIMER)
  CancelTimer(FULL_SYNC_TIMER)
  CancelTimer(NETWORK_SCAN_TIMER)

  local heartbeat = activeHeartbeatSeconds()
  local poll = INTERVALS[Properties["Device Poll Interval"] or ""] or INTERVALS["5m"]
  local fullSync = INTERVALS[Properties["Full Sync Interval"] or ""] or INTERVALS["24h"]

  SetTimer(HEARTBEAT_TIMER, heartbeat * ONE_SECOND, sendHeartbeat, true)
  -- Hourly CHECK, server-tuned ACTION: the tick refreshes entitlements only
  -- once the cache is past the platform's revalidate window.
  CancelTimer(ENTITLEMENT_TIMER)
  SetTimer(ENTITLEMENT_TIMER, 3600 * ONE_SECOND, entitlementTick, true)
  SetTimer(DEVICE_POLL_TIMER, poll * ONE_SECOND, pollDeviceState, true)
  SetTimer(FULL_SYNC_TIMER, fullSync * ONE_SECOND, sendFullSync, true)
  SetTimer(TELEMETRY_QUEUE_TIMER, 45 * ONE_SECOND, flushTelemetry, true)

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

  -- ── Thermostats, found by SIGNATURE over the whole project ────────────────
  -- TEMPERATURE_ID discovery alone found half the house (see the note on
  -- gDiscoveredThermostats). One GetDeviceVariables per device, once per
  -- catalogue — the same order of work the capability probe already does.
  gDiscoveredThermostats = {}
  gSensorDevices = {}
  gLightDevices = {}
  gKeypadDevices = {}
  gKeypadsSilent = 0
  local found, sensors = 0, 0
  local lights, lightListeners, keypadListeners = 0, 0, 0
  local okD, devs = pcall(function()
    return C4:GetDevices()
  end)
  if okD and type(devs) == "table" then
    for rawId, device in pairs(devs) do
      local id = tointeger(rawId)
      if id ~= nil then
        local okV, vars = pcall(function()
          return C4:GetDeviceVariables(id)
        end)
        if okV and looksLikeThermostat(vars) then
          gDiscoveredThermostats[id] = true
          found = found + 1
        end
        -- Sensors, locks, openings and batteries — anything reporting a state
        -- worth watching. A thermostat can also carry a battery, so this is
        -- not exclusive with the branch above.
        if
          okV
          and sensors < MAX_SENSORS
          and sensorReading(vars, type(device) == "table" and device.deviceName or nil) ~= nil
        then
          gSensorDevices[id] = {
            name = type(device) == "table" and device.deviceName or nil,
            room = type(device) == "table" and device.roomName or nil,
          }
          sensors = sensors + 1
          -- Ship this device's variables to the catalogue. The names above are
          -- CANDIDATES from documentation and one project; this is how the
          -- next round reads what the project actually said instead of
          -- guessing again. Bounded per device.
          if okV and type(vars) == "table" then
            local shipped = 0
            for varId, v in pairs(vars) do
              local vid = tointeger(varId)
              local vname = type(v) == "table" and v.name or nil
              if vid and vname and shipped < 40 and #observables < 3800 then
                observables[#observables + 1] = {
                  kind = "device",
                  source_id = id,
                  source_name = type(device) == "table" and device.deviceName or nil,
                  variable_id = vid,
                  variable_name = vname,
                  sample_value = tostring(v.value or ""),
                  readonly = tostring(v.readonly) == "True",
                }
                shipped = shipped + 1
              end
            end
          end
        end

        -- ── Lights, by signature ────────────────────────────────────────────
        --
        -- Same walk, same variables, zero extra Director reads. A dimmer keypad
        -- can land here AND in the keypad branch below; both are true.
        local lightWatch = okV and Lights.signature(vars) or nil
        if lightWatch ~= nil and lights < MAX_LIGHTS then
          gLightDevices[id] = {
            name = type(device) == "table" and device.deviceName or nil,
            room = type(device) == "table" and device.roomName or nil,
            room_id = type(device) == "table" and tointeger(device.roomId) or nil,
            watch = lightWatch,
          }
          lights = lights + 1
          if lightListeners < MAX_LIGHT_LISTENERS then
            for varId in pairs(lightWatch) do
              pcall(function()
                C4:RegisterVariableListener(id, varId)
              end)
            end
            lightListeners = lightListeners + 1
          end
          -- Ship this light's variables to the catalogue: the candidate names
          -- in telemetry/lights.lua are guesses until a project confirms them,
          -- and this is the loop that turns guesses into vocabulary — it is
          -- how the thermostat and sensor names got corrected.
          if type(vars) == "table" then
            local shippedLight = 0
            for varId, v in pairs(vars) do
              local vid = tointeger(varId)
              local vname = type(v) == "table" and v.name or nil
              if vid and vname and shippedLight < 40 and #observables < 3800 then
                observables[#observables + 1] = {
                  kind = "light",
                  source_id = id,
                  source_name = type(device) == "table" and device.deviceName or nil,
                  variable_id = vid,
                  variable_name = vname,
                  sample_value = tostring(v.value or ""),
                  readonly = tostring(v.readonly) == "True",
                }
                shippedLight = shippedLight + 1
              end
            end
          end
        end

        -- ── Keypads, by signature ───────────────────────────────────────────
        local keypadWatch = okV and Lights.keypadWatch(vars) or nil
        if keypadWatch ~= nil then
          gKeypadDevices[id] = {
            name = type(device) == "table" and device.deviceName or nil,
            room = type(device) == "table" and device.roomName or nil,
            watch = keypadWatch,
          }
          if keypadListeners < MAX_KEYPAD_LISTENERS then
            for varId in pairs(keypadWatch) do
              pcall(function()
                C4:RegisterVariableListener(id, varId)
              end)
            end
            keypadListeners = keypadListeners + 1
          end
        elseif okV and type(vars) == "table" then
          -- A device the binding census calls a KEYPAD but which exposes no
          -- button variables is the open half of finding 7: presses may only
          -- exist as proxy notifications a third-party driver cannot see.
          -- Counted here, reported below — absence measured, not assumed.
          local dt = type(device) == "table" and tostring(device.deviceName or ""):upper() or ""
          if dt:find("KEYPAD", 1, true) then
            gKeypadsSilent = gKeypadsSilent + 1
          end
        end
      end
    end
  end
  log:info(
    "Catalogue: %d light(s) (%d listening), %d keypad(s) listening, %d keypad(s) silent",
    lights,
    lightListeners,
    keypadListeners,
    gKeypadsSilent
  )
  -- ── Climate targets ship their variables UNCONDITIONALLY ─────────────────
  --
  -- Measured need, 2026-08-21, on the first real customer site: 37 rooms point
  -- at three climate devices and ZERO thermostat records formed — their driver
  -- speaks a vocabulary climateReading does not know, and nothing anywhere
  -- showed what that vocabulary IS. An unrecognised thermostat was invisible:
  -- the rooms name it, the read returns nothing, and the platform sees empty.
  --
  -- So every device a room's TEMPERATURE_ID points at ships its variable list
  -- to the catalogue, recognised or not. Recognition is the sampler's job;
  -- VISIBILITY is the catalogue's, and tying visibility to recognition is how
  -- this blind spot happened. Deduplicated — many rooms share one thermostat —
  -- and bounded like every other shipper in this walk.
  local climateShipped = {}
  for _, target in pairs(gRoomThermostat) do
    if not climateShipped[target] and #observables < 3800 then
      climateShipped[target] = true
      local okT, tvars = pcall(function()
        return C4:GetDeviceVariables(target)
      end)
      if okT and type(tvars) == "table" then
        local shipped = 0
        for varId, v in pairs(tvars) do
          local vid = tointeger(varId)
          local vname = type(v) == "table" and v.name or nil
          -- 60, not the walk's usual 40: the measured thermostats expose ~45+
          -- variables and the 40 cap cut off the tail where SCALE would sit.
          if vid and vname and shipped < 60 and #observables < 3800 then
            observables[#observables + 1] = {
              kind = "device",
              source_id = target,
              source_name = "climate target " .. tostring(target),
              variable_id = vid,
              variable_name = vname,
              sample_value = tostring(v.value or ""),
              readonly = tostring(v.readonly) == "True",
            }
            shipped = shipped + 1
          end
        end
      end
    end
  end

  log:info(
    "Catalogue: %d room(s), %d observable(s); %d thermostat(s) and %d sensor/battery device(s) by signature",
    #rooms,
    #observables,
    found,
    sensors
  )

  -- The catalogue walk is what populates room -> thermostat, so this is the
  -- first moment a full climate sample is possible. Sampling here (and
  -- pushing) means thermostats appear when monitoring turns on, not at the
  -- climate timer up to fifteen minutes later.
  if gMonitor.enabled and gMonitor.climate_enabled then
    sampleClimate()
    sendTelemetry()
  end
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

--- Director calls this for every registered variable — rooms, lights, keypads.
function OnWatchedVariableChanged(idDevice, idVariable, strValue)
  local deviceId = tointeger(idDevice)
  local varId = tointeger(idVariable)
  if deviceId == nil or varId == nil then
    return
  end

  local names = gRoomVarNames[deviceId]
  local name = names and names[varId] or nil
  if name ~= nil then
    log:debug("room %s %s = %s", tostring(deviceId), name, tostring(strValue))
    gRooms:apply(deviceId, gRoomNames[deviceId], name, strValue)
    -- Tier 1 (2026-08-21): rooms ride the same debounced push lights already
    -- use. Director told us the INSTANT this changed; making the platform wait
    -- for the five-minute tick was our own batching, and it was the largest
    -- staleness left in the pipeline. Ten seconds coalesces a burst — a track
    -- change updates title, artist, album and art in quick succession — into
    -- one upload of the settled state.
    SetTimer(LIGHT_PUSH_TIMER, 10 * ONE_SECOND, function()
      sendTelemetry()
    end)
    return
  end

  -- A light moved. The reading is re-sampled at push time rather than patched
  -- from this one variable, and the push is DEBOUNCED: a scene that ramps
  -- twelve loads should arrive as one upload showing the settled state, not
  -- twelve uploads showing a staircase.
  local light = gLightDevices[deviceId]
  if light ~= nil and light.watch[varId] ~= nil then
    log:debug("light %s %s = %s", tostring(deviceId), light.watch[varId], tostring(strValue))
    SetTimer(LIGHT_PUSH_TIMER, 10 * ONE_SECOND, function()
      sendTelemetry()
    end)
    return
  end

  -- A keypad variable. Presses are EVENTS, not state — they ride the journaled
  -- queue with their timestamp and the variable's real name verbatim, which is
  -- how the platform learns the true button vocabulary from the first press
  -- (the candidate matching in telemetry/lights.lua only casts the net).
  local keypad = gKeypadDevices[deviceId]
  if keypad ~= nil and keypad.watch[varId] ~= nil then
    log:debug("keypad %s %s = %s", tostring(deviceId), keypad.watch[varId], tostring(strValue))
    -- Tier 1: the first press arms a short flush rather than waiting out the
    -- 45-second cycle. Five seconds coalesces a double/triple tap into one
    -- batch; the repeating timer stays as the backstop.
    SetTimer(TELEMETRY_FAST_FLUSH_TIMER, 5 * ONE_SECOND, function()
      flushTelemetry()
    end)
    gTelemetry:add("KEYPAD", {
      subcategory = keypad.watch[varId],
      source_type = "device",
      source_id = tostring(deviceId),
      source_name = keypad.name,
      room_name = keypad.room,
      value_text = tostring(strValue or ""):sub(1, 120),
      -- Which button was pressed in which room is household-pattern data.
      privacy_class = "INTEGRATOR_ONLY",
    })
  end
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
  -- "V1 *" is the OLDER thermostat-proxy generation, measured on the first
  -- real customer site 2026-08-21: the modern names all read 0/None while
  -- V1 TEMPERATURE=68 / V1 COOL_SETPOINT=90 carried the live values. The V1
  -- names come LAST so a modern stat never falls through to them.
  local temp = firstNumber({ "TEMPERATURE_F", "TEMPERATURE_C", "V1 TEMPERATURE" })
  if temp == nil then
    local raw = tonumber(values["TEMPERATURE"])
    if raw ~= nil and raw ~= 0 then
      temp = raw / 10
    end
  end

  local heat = firstNumber({ "HEAT_SETPOINT_F", "DISPLAY_HEATSETPOINT", "HEAT_SETPOINT_C", "V1 HEAT_SETPOINT" })
  local cool = firstNumber({ "COOL_SETPOINT_F", "DISPLAY_COOLSETPOINT", "COOL_SETPOINT_C", "V1 COOL_SETPOINT" })
  -- HVAC_STATE ("Stage 1 Cool") says what it is DOING; ANA_HVACMODE ("Cool")
  -- says what it is set to. State is the more useful and falls back to mode.
  local mode = values["HVAC_STATE"] or values["ANA_HVACMODE"] or values["HVAC_MODE"]

  if temp == nil and heat == nil and cool == nil then
    return nil
  end
  return { temperature = temp, heat = heat, cool = cool, mode = mode }
end

-- ─── Sensors, batteries and openings ────────────────────────────────────────
--
-- Everything in a project that reports a STATE worth watching but is not a
-- thermostat and not an up/down device: door locks, contacts, motion, water
-- leaks, garage doors and gates, security partitions, UPS/power, and the
-- battery in any of them.
--
-- ── DETECTION IS BY VARIABLE SIGNATURE ──────────────────────────────────────
--
-- Not by name and not by proxy class, the two methods this project has
-- already disproved: name-matching scored 0 of 223 devices twice, and a
-- WEATHER driver answers the thermostat proxy. A device that reports
-- CONTACT_STATE is a contact sensor no matter what anybody called it.
--
-- ── THE NAMES BELOW ARE CANDIDATES, NOT MEASUREMENTS ────────────────────────
--
-- Control4 driver authors are inconsistent: BATTERY_LEVEL, "Battery Level"
-- and BATTERY_PERCENT all appear in the wild, and a single project mixes
-- them (this one reports "Battery Status" and "Running on Battery" on the
-- thermostat, "Battery Level" on the remote). So each field lists every
-- plausible spelling, matching is case-insensitive, and the catalogue now
-- ships DEVICE variables too — which turns the next round of this from
-- guessing into reading what the project actually said.

--- Case-folded variable map for a device.
local function variableMap(vars)
  if type(vars) ~= "table" then
    return nil
  end
  local values = {}
  for _, v in pairs(vars) do
    if type(v) == "table" and type(v.name) == "string" then
      values[v.name:upper()] = v.value
    end
  end
  return values
end

--- First present value among candidate names.
local function firstOf(values, names)
  for _, name in ipairs(names) do
    local v = values[name]
    if v ~= nil and tostring(v) ~= "" then
      return tostring(v)
    end
  end
  return nil
end

--- A state string normalised to the vocabulary a screen renders.
---
--- Control4 reports the same fact as "0"/"1", "true"/"false", "Open"/"Closed"
--- and "OPENED" depending on the driver. One vocabulary here means the UI
--- never has to guess, and a value nobody has seen passes through verbatim
--- rather than being forced into a bucket it may not belong in.
local function normalizeState(raw, kind)
  if raw == nil then
    return nil
  end
  local s = tostring(raw):lower()
  local openish = { ["1"] = true, ["true"] = true, ["open"] = true, ["opened"] = true, ["on"] = true }
  local closedish = { ["0"] = true, ["false"] = true, ["close"] = true, ["closed"] = true, ["off"] = true }
  if kind == "lock" then
    if s == "1" or s == "true" or s == "locked" then
      return "Locked"
    end
    if s == "0" or s == "false" or s == "unlocked" then
      return "Unlocked"
    end
  elseif kind == "motion" then
    if openish[s] or s == "motion" or s == "detected" then
      return "Motion"
    end
    if closedish[s] or s == "no motion" or s == "clear" then
      return "Clear"
    end
  elseif kind == "leak" then
    if openish[s] or s == "wet" or s == "detected" then
      return "Leak detected"
    end
    if closedish[s] or s == "dry" then
      return "Dry"
    end
  else
    if openish[s] then
      return "Open"
    end
    if closedish[s] then
      return "Closed"
    end
  end
  return tostring(raw):sub(1, 40)
end

--- One sensor/battery record for a device, or nil when it is neither.
---
--- Pure and global so the classification can be tested directly — this is the
--- part that can be quietly wrong: a lock misread as a contact renders
--- perfectly and tells a dealer the wrong thing about somebody's front door.
function sensorReading(vars, name)
  local values = variableMap(vars)
  if values == nil then
    return nil
  end

  local battery = tonumber(firstOf(values, {
    "BATTERY_LEVEL",
    "BATTERY LEVEL",
    "BATTERY_PERCENT",
    "BATTERY",
    "BATTERYLEVEL",
  }))
  if battery ~= nil and (battery < 0 or battery > 100) then
    battery = nil
  end
  local batteryStatus = firstOf(values, { "BATTERY_STATUS", "BATTERY STATUS" })
  -- ⚠ EXACTLY ZERO IS CONTROL4'S UNSET, NOT A FLAT BATTERY.
  --
  -- Measured 2026-08-18 on the live project: two locks added for testing and
  -- never paired both reported BATTERY_LEVEL 0, and they would have ranked
  -- ABOVE a genuinely low remote at 10% — sending somebody out with
  -- batteries for devices that have none. The same rule already governs
  -- thermostat setpoints, which also read 0 when unset.
  --
  -- A battery that truly reaches 0 belongs to a device that has already
  -- stopped talking, and a driver that means it says so in BATTERY_STATUS.
  -- So a zero survives only when a status corroborates it.
  if battery == 0 and IsEmpty(batteryStatus) then
    battery = nil
  end
  local lowBatteryRaw = firstOf(values, { "LOW_BATTERY", "LOW BATTERY", "BATTERY_LOW" })
  local lowBattery = nil
  if lowBatteryRaw ~= nil then
    local l = lowBatteryRaw:lower()
    lowBattery = (l == "true" or l == "1" or l == "yes")
  end
  -- A status string of its own can also mean low, e.g. "Low"/"Replace".
  if lowBattery == nil and batteryStatus ~= nil then
    local b = batteryStatus:lower()
    if b == "low" or b == "replace" or b == "critical" or b == "bad" then
      lowBattery = true
    elseif b == "good" or b == "normal" or b == "ok" then
      lowBattery = false
    end
  end

  -- Category, most specific first: a door lock reports a contact too, and
  -- calling it a contact sensor loses what it is.
  local category, state
  local lockRaw = firstOf(values, { "LOCK_STATUS", "LOCK STATUS", "LOCKED", "LOCK_STATE", "LOCKSTATE" })
  local partitionRaw =
    firstOf(values, { "PARTITION_STATE", "PARTITION STATE", "ARM_STATE", "ARMED_STATE", "SECURITY_STATE" })
  local leakRaw = firstOf(values, { "LEAK", "LEAK_DETECTED", "WATER_DETECTED", "LEAKDETECTED" })
  local motionRaw = firstOf(values, { "MOTION_STATE", "MOTION STATE", "MOTION", "MOTIONSTATE" })
  local doorRaw =
    firstOf(values, { "DOOR_STATE", "DOOR STATE", "GARAGE_STATE", "GATE_STATE", "OPENSTATE", "OPEN_STATE" })
  local contactRaw = firstOf(values, { "CONTACT_STATE", "CONTACT STATE", "CONTACTSTATE", "SENSOR_STATE" })
  local relayRaw = firstOf(values, { "RELAY_STATE", "RELAY STATE", "RELAYSTATE" })
  local powerRaw = firstOf(values, { "POWER_LOST", "ON_BATTERY", "RUNNING ON BATTERY", "AC_POWER" })

  if lockRaw ~= nil then
    category, state = "lock", normalizeState(lockRaw, "lock")
  elseif partitionRaw ~= nil then
    category, state = "security", tostring(partitionRaw):sub(1, 40)
  elseif leakRaw ~= nil then
    category, state = "leak", normalizeState(leakRaw, "leak")
  elseif doorRaw ~= nil then
    category, state = "opening", normalizeState(doorRaw, "opening")
  elseif motionRaw ~= nil then
    category, state = "motion", normalizeState(motionRaw, "motion")
  elseif contactRaw ~= nil then
    -- Control4 motion sensors report CONTACT_STATE — they ARE contacts
    -- electrically. Signature alone therefore files six devices named
    -- "Motion Sensor" under Contacts reading "Closed", which is true and
    -- tells nobody anything. The name refines the label only AFTER the
    -- signature has established what kind of device this is; it is never
    -- the thing that finds the device.
    if type(name) == "string" and name:lower():find("motion", 1, true) ~= nil then
      category, state = "motion", normalizeState(contactRaw, "motion")
    else
      category, state = "contact", normalizeState(contactRaw, "contact")
    end
  elseif relayRaw ~= nil then
    category, state = "relay", normalizeState(relayRaw, "relay")
  elseif powerRaw ~= nil then
    -- A THERMOSTAT reports "Running on Battery" too, and it already has a
    -- far richer record of its own. Measured 2026-08-18: both real
    -- thermostats landed here as "power" sensors reading "Open", which is
    -- meaningless for a thermostat and duplicated a device already shown.
    if looksLikeThermostat(vars) then
      return nil
    end
    category = "power"
    -- On battery / on mains — not open / closed.
    local onBattery = tostring(powerRaw):lower()
    state = (onBattery == "true" or onBattery == "1") and "On battery" or "On mains"
  elseif battery ~= nil or batteryStatus ~= nil or lowBattery ~= nil then
    -- Battery with no state of its own: a keypad, a remote, a thermostat.
    -- Still worth reporting — the battery IS the finding.
    category, state = "battery", nil
  else
    return nil
  end

  -- Mesh quality, where the driver exposes it. An integrator diagnostic: a
  -- Zigbee sensor at 30% link quality is a truck roll waiting to happen.
  local link = tonumber(firstOf(values, { "LINK_QUALITY", "LINK QUALITY", "LQI", "RSSI", "SIGNAL_STRENGTH" }))

  return {
    category = category,
    state = state,
    battery_level = battery,
    battery_status = batteryStatus and batteryStatus:sub(1, 40) or nil,
    low_battery = lowBattery,
    link_quality = link,
  }
end

--- Whether a device's variable set says "thermostat".
---
--- By SIGNATURE, not by name or proxy class — the two ways that have already
--- been wrong on this project (a WEATHER driver answers the thermostat proxy,
--- and name-matching scored 0/223 twice). HVAC_MODE plus a converted
--- temperature is the signature; the weather guard still applies on top.
--- Pure and global so it can be tested directly.
function looksLikeThermostat(vars)
  if type(vars) ~= "table" then
    return false
  end
  local names = {}
  for _, v in pairs(vars) do
    if type(v) == "table" and type(v.name) == "string" then
      names[v.name:upper()] = tostring(v.value or "")
    end
  end
  if (names["HVAC_MODES_LIST"] or ""):upper():find("WARN", 1, true) ~= nil then
    return false
  end
  if names["HVAC_MODE"] ~= nil and (names["TEMPERATURE_F"] ~= nil or names["TEMPERATURE_C"] ~= nil) then
    return true
  end
  -- The V1 proxy generation (first real customer site): modern names exist but
  -- read empty; the live signature is the V1 namespace.
  return names["V1 TEMPERATURE"] ~= nil and names["V1 HVACMODES"] ~= nil
end

--- The FULL thermostat record, from the device's own variables.
---
--- The room endpoint carries one number; the thermostat itself carries the
--- whole picture — measured in Composer 2026-08-18 on the two real units
--- (each named after its room): TEMPERATURE_F 78, HEAT/COOL_SETPOINT_F,
--- HVAC_MODE "Heat", HVAC_STATE "Off", FAN_MODE/STATE, HUMIDITY 56,
--- "Battery Status" Good beside "Running on Battery" True, OUTDOOR_
--- TEMPERATURE_F, SCALE F. Pure and global like `climateReading`, and
--- guarded by the same weather-driver check: a forecast station answers the
--- same proxy and must never render as a room's comfort.
---
--- Unset numbers read exactly 0 on the measured hardware (setpoints,
--- humidity, outdoor temperature on a unit with no outdoor sensor), so 0 is
--- read as absent for every field where 0 is not a value anyone configured.
---
--- @return table|nil a flat record for the state payload, or nil
function thermostatReading(vars)
  if type(vars) ~= "table" then
    return nil
  end
  local values = {}
  for _, v in pairs(vars) do
    if type(v) == "table" and type(v.name) == "string" then
      values[v.name:upper()] = v.value
    end
  end

  local modesList = tostring(values["HVAC_MODES_LIST"] or "")
  if modesList:upper():find("WARN", 1, true) ~= nil then
    return nil
  end

  local function numNonZero(name)
    local n = tonumber(values[name])
    if n ~= nil and n ~= 0 then
      return n
    end
    return nil
  end
  local function str(name)
    local s = values[name]
    if s == nil then
      return nil
    end
    s = tostring(s)
    return s ~= "" and s:sub(1, 60) or nil
  end
  local function boolOrNil(name)
    local s = values[name]
    if s == nil then
      return nil
    end
    s = tostring(s):lower()
    if s == "true" or s == "1" then
      return true
    end
    if s == "false" or s == "0" then
      return false
    end
    return nil
  end

  local reading = {
    scale = str("SCALE"),
    -- V1 fallbacks per the measured site: SCALE was not among the shipped
    -- vars there, so a V1 value's unit is the controller's display unit. 68
    -- beside a cooling setpoint of 90 is Fahrenheit on that site; a Celsius
    -- site would read ~20/26 and still display correctly as a bare number.
    temperature_f = numNonZero("TEMPERATURE_F") or numNonZero("V1 TEMPERATURE"),
    temperature_c = numNonZero("TEMPERATURE_C"),
    heat_setpoint_f = numNonZero("HEAT_SETPOINT_F") or numNonZero("V1 HEAT_SETPOINT"),
    cool_setpoint_f = numNonZero("COOL_SETPOINT_F") or numNonZero("V1 COOL_SETPOINT"),
    single_setpoint_f = numNonZero("SINGLE_SETPOINT_F"),
    hvac_mode = str("HVAC_MODE") or str("ANA_HVACMODE") or str("V1 HVACMODE"),
    hvac_state = str("HVAC_STATE"),
    fan_mode = str("FAN_MODE") or str("V1 FANMODE"),
    fan_state = str("FAN_STATE"),
    -- Real indoor humidity is never 0%; a unit without the sensor reads 0.
    humidity = numNonZero("HUMIDITY"),
    humidity_mode = str("HUMIDITY_MODE"),
    humidity_state = str("HUMIDITY_STATE"),
    outdoor_temperature_f = numNonZero("OUTDOOR_TEMPERATURE_F"),
    battery_status = str("BATTERY STATUS"),
    running_on_battery = boolOrNil("RUNNING ON BATTERY"),
    heating_active = boolOrNil("HEATING ACTIVE"),
    cooling_active = boolOrNil("COOLING ACTIVE"),
    is_connected = boolOrNil("IS_CONNECTED"),
    heatpump = boolOrNil("HEATPUMP"),
  }

  if
    reading.temperature_f == nil
    and reading.temperature_c == nil
    and reading.heat_setpoint_f == nil
    and reading.cool_setpoint_f == nil
    and reading.single_setpoint_f == nil
  then
    return nil
  end
  return reading
end

--- Samples climate rather than watching it: temperature moves constantly and
--- every change is not worth an event.
---
--- One read per THERMOSTAT, not per room: several rooms routinely share a
--- unit, and reading it once both saves Director calls and keeps the full
--- snapshot to one record per physical device.
function sampleClimate()
  if not gMonitor.enabled or not gMonitor.climate_enabled then
    return
  end

  -- The device's own name. On the measured project each thermostat is named
  -- after its room ("Master Bedroom", "Living Room"), which is exactly the
  -- label a screen should show — and, below, the attribution of last resort.
  local deviceNames = {}
  local okD, devs = pcall(function()
    return C4:GetDevices()
  end)
  if okD and type(devs) == "table" then
    for rawId, d in pairs(devs) do
      local id = tointeger(rawId)
      if id ~= nil and type(d) == "table" and type(d.deviceName) == "string" then
        deviceNames[id] = d.deviceName
      end
    end
  end

  -- Invert room -> thermostat into thermostat -> rooms served, skipping the
  -- rooms Control4 hides from its own navigator (Equipment, Cloud): they are
  -- wiring, and "serves Equipment" on a comfort card is a database export.
  local served = {}
  for roomId, thermostat in pairs(gRoomThermostat) do
    local roomName = gRoomNames[roomId] or ""
    if not roomName:lower():match("^equipment$") and not roomName:lower():match("^cloud$") then
      served[thermostat] = served[thermostat] or {}
      served[thermostat][#served[thermostat] + 1] = roomId
    end
  end

  -- Signature-discovered units join the map even when no room points at them.
  for thermostat in pairs(gDiscoveredThermostats) do
    served[thermostat] = served[thermostat] or {}
  end

  -- A room NAMED after a thermostat belongs to THAT thermostat. Measured
  -- 2026-08-18: every room's TEMPERATURE_ID points at the Living Room unit,
  -- while the Master Bedroom's own thermostat (named "Master Bedroom") is
  -- nobody's TEMPERATURE_ID. The name is the installer's statement of where
  -- the device lives, and it beats a shared project-wide pointer.
  for thermostat in pairs(served) do
    local unitName = (deviceNames[thermostat] or ""):lower()
    if unitName ~= "" then
      for roomId, roomName in pairs(gRoomNames) do
        if type(roomName) == "string" and roomName:lower() == unitName then
          for other, roomIds in pairs(served) do
            if other ~= thermostat then
              for i = #roomIds, 1, -1 do
                if roomIds[i] == roomId then
                  table.remove(roomIds, i)
                end
              end
            end
          end
          local mine = served[thermostat]
          local already = false
          for _, id in ipairs(mine) do
            if id == roomId then
              already = true
            end
          end
          if not already then
            mine[#mine + 1] = roomId
          end
        end
      end
    end
  end

  local snapshot = {}
  for thermostat, roomIds in pairs(served) do
    local okV, vars = pcall(function()
      return C4:GetDeviceVariables(thermostat)
    end)
    if not okV then
      vars = nil
    end

    local reading = climateReading(vars)
    if reading ~= nil then
      for _, roomId in ipairs(roomIds) do
        -- The thermostat travels with the reading, so the platform can tell
        -- six copies of one thermostat from six thermostats.
        gRooms:setClimate(roomId, reading.temperature, reading.heat, reading.cool, reading.mode, thermostat)
      end
      -- Telemetry history is per THERMOSTAT (attributed to its first room):
      -- one shared unit sampled into six rooms would count six-fold in the
      -- hourly mean.
      if reading.temperature ~= nil then
        gTelemetry:add("CLIMATE", {
          subcategory = "temperature",
          source_type = "thermostat",
          source_id = tostring(thermostat),
          room_id = roomIds[1],
          room_name = gRoomNames[roomIds[1]],
          value_numeric = reading.temperature,
          unit = "F",
          -- Comfort is the one customer-safe reading in this file: it is what
          -- the Home Insights climate screen already shows.
          privacy_class = "CUSTOMER_SAFE",
        })
      end
    end

    -- The FULL record for the state payload (screens show setpoints, mode,
    -- fan, humidity, battery — not just one number).
    local full = thermostatReading(vars)
    if full ~= nil then
      full.device_id = thermostat
      full.name = deviceNames[thermostat]
      local roomNames = {}
      for _, roomId in ipairs(roomIds) do
        roomNames[#roomNames + 1] = gRoomNames[roomId] or tostring(roomId)
      end
      full.room_ids = roomIds
      full.room_names = roomNames
      full.changed_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
      snapshot[#snapshot + 1] = full
      if full.humidity ~= nil then
        gTelemetry:add("CLIMATE", {
          subcategory = "humidity",
          source_type = "thermostat",
          source_id = tostring(thermostat),
          room_id = roomIds[1],
          room_name = gRoomNames[roomIds[1]],
          value_numeric = full.humidity,
          unit = "%",
          privacy_class = "CUSTOMER_SAFE",
        })
      end
    end
  end
  gThermostatSnapshot = snapshot
end

--- Re-reads every discovered sensor/battery device.
---
--- Read on each state upload rather than watched: a contact that opens twice
--- a minute would be an event storm for a screen that shows current state,
--- and the devices worth ALERTING on (leak, low battery) do not change on a
--- timescale where a few minutes matters. Bounded by the discovery cap.
function sampleSensors()
  if not gMonitor.enabled then
    return {}
  end
  local out = {}
  for id, info in pairs(gSensorDevices) do
    local okV, vars = pcall(function()
      return C4:GetDeviceVariables(id)
    end)
    if okV then
      local reading = sensorReading(vars, info.name)
      if reading ~= nil then
        reading.device_id = id
        reading.name = info.name
        reading.room_name = info.room
        reading.changed_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
        out[#out + 1] = reading
        -- Battery level is a NUMBER that trends — the one sensor field worth
        -- history, because "it was at 40% a month ago" is what turns a
        -- replacement into a scheduled visit instead of a callback.
        if reading.battery_level ~= nil then
          gTelemetry:add("MEASUREMENT", {
            subcategory = "battery",
            source_type = "device",
            source_id = tostring(id),
            room_name = info.room,
            value_numeric = reading.battery_level,
            unit = "%",
            -- A battery percentage says nothing about what anyone did.
            privacy_class = "CUSTOMER_SAFE",
          })
        end
      end
    end
  end
  return out
end

--- Reads every discovered light. One GetDeviceVariables per light per tick —
--- the same order of work sampleSensors already does for up to 200 sensors.
--- Sampling is the COVERAGE path; listeners only add immediacy for the subset
--- inside the listener budget, so a project with 150 lights still reports all
--- of them, just on the tick.
function sampleLights()
  if not gMonitor.enabled then
    return {}
  end
  local out = {}
  for id, info in pairs(gLightDevices) do
    local okV, vars = pcall(function()
      return C4:GetDeviceVariables(id)
    end)
    if okV then
      local reading = Lights.reading(vars)
      if reading ~= nil then
        out[#out + 1] = {
          device_id = id,
          name = info.name,
          room_id = info.room_id,
          room_name = info.room,
          on = reading.on,
          level = reading.level,
          watts = reading.watts,
          changed_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        }
      end
    end
  end
  return out
end

-- ─── Album art, fetched HERE because only here has a route to it ─────────────
--
-- The artwork URL a player reports is a LAN address (http://192.168...). The
-- page that shows it is HTTPS in a modern WebView, which BLOCKS mixed-content
-- images -- measured on the Control4 phone app 2026-08-17: a black box where
-- the art belongs, on a page that renders perfectly on the wall panel WebKit.
-- And a phone on cellular has no route to the LAN at all. The platform cannot
-- proxy it either: Vercel cannot reach a private address.
--
-- This driver is the one party standing next to the player, so it fetches the
-- image and ships it INLINE as a data URI. Bounded: raw art over 96KB is
-- skipped (the URL still travels for WebKits that can use it), failures are
-- cached so a dead URL is not re-fetched every five minutes, and the cache is
-- wiped past a dozen entries -- art churns per track, and the current track is
-- one refetch away.

-- MEASURED 2026-08-18: the Sonos getaa endpoint served a 261KB PNG for an
-- Apple Music track. The original 96KB cap rejected it — and every track like
-- it — then cached the URL as failed FOREVER, which is exactly how "cover art
-- is missing" presented with a perfectly healthy pipeline. The platform
-- validator accepts a 512KB data URI; base64 inflates by 4/3, so 360KB of raw
-- image is the largest art that survives the trip.
local MAX_ART_BYTES = 360 * 1024
--- Failures cool off instead of sticking: the first fetch can race a player
--- that is still buffering, and a transient error must not blank the art for
--- the rest of the track.
local ART_RETRY_SECONDS = 600
--- url -> { data = "data:...;base64,..." } | { failed = true, at = <epoch> } | { pending = true }
local gArtCache = {}
local gArtCacheCount = 0

-- Global, like computeClimate, so the cap/retry/sanitise rules can be tested
-- directly — the cache is local state no test can reach otherwise.
function artDataFor(url)
  local hit = url ~= nil and gArtCache[url] or nil
  return hit ~= nil and hit.data or nil
end

function fetchArt(url)
  if url == nil or url == "" then
    return
  end
  local hit = gArtCache[url]
  if hit ~= nil and (hit.failed ~= true or os.time() - (hit.at or 0) < ART_RETRY_SECONDS) then
    return
  end
  if gArtCacheCount >= 12 then
    gArtCache = {}
    gArtCacheCount = 0
  end
  gArtCache[url] = { pending = true }
  gArtCacheCount = gArtCacheCount + 1
  http:get(url, {}, { timeout = 10 }):next(function(response)
    local body = response.body
    if type(body) ~= "string" or #body == 0 or #body > MAX_ART_BYTES then
      gArtCache[url] = { failed = true, at = os.time() }
      log:warn(
        "Art fetch unusable (%s bytes, cap %d): %s",
        type(body) == "string" and tostring(#body) or "no",
        MAX_ART_BYTES,
        url
      )
      return
    end
    local headers = response.headers or {}
    local contentType = headers["Content-Type"] or headers["content-type"] or "image/jpeg"
    if type(contentType) ~= "string" or contentType:find("^image/") == nil then
      contentType = "image/jpeg"
    end
    -- Some base64 encoders wrap lines; the platform validator rejects any
    -- whitespace, so strip it here rather than trust the encoder's dialect.
    local encoded = (C4:Base64Encode(body):gsub("%s+", ""))
    gArtCache[url] = { data = "data:" .. contentType .. ";base64," .. encoded }
    -- Push promptly: whoever is looking at a placeholder should not wait out
    -- the five-minute tick for art that just resolved.
    sendTelemetry()
  end, function(err)
    gArtCache[url] = { failed = true, at = os.time() }
    log:warn("Art fetch failed (%s): %s", tostring(type(err) == "table" and err.error or err), url)
  end)
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

  local sensors = sampleSensors()
  local lightStates = sampleLights()
  local rooms = gRooms:snapshot()
  if #rooms > 0 or #gThermostatSnapshot > 0 or #sensors > 0 or #lightStates > 0 then
    for _, room in ipairs(rooms) do
      local data = artDataFor(room.media_image_url)
      if data ~= nil then
        room.media_image_data = data
      elseif room.media_image_url ~= nil then
        fetchArt(room.media_image_url)
      end
    end
    -- Thermostats ride the same state upload: they ARE state, and giving them
    -- their own send would double the request count for no isolation gain.
    send("telemetry", {
      kind = "state",
      rooms = rooms,
      thermostats = gThermostatSnapshot,
      sensors = sensors,
      lights = lightStates,
    }, "room state")
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
showPairingState = function()
  if isPaired() then
    -- Name and ADDRESS. The uuid is the last resort, not the default: it is
    -- the one thing here that answers nothing for somebody at a rack trying to
    -- work out which house this controller is in.
    local name = persist:get(PROPERTY_NAME_KEY, "") or ""
    local label = persist:get(SITE_LABEL_KEY, "") or ""
    local detail = label ~= "" and label or (propertyId() ~= "" and propertyId() or systemId())
    UpdateProperty("Paired Property", name ~= "" and string.format("%s (%s)", name, detail) or detail)
  else
    UpdateProperty("Paired Property", "Not paired")
  end
end

--- Applies a successful pair/verify response: persists the token, secret,
--- identity and account display, mirrors the pairing backup, and starts the
--- paired lifecycle. Shared by the pairing-code and account-number doors, which
--- receive an identical response body. The caller clears its own input field.
--- @return boolean ok False if the 2xx body was unusable.
local function applyPairResponse(response)
  local body = response.body
  if type(body) == "string" then
    local ok, decoded = pcall(function()
      return JSON:decode(body)
    end)
    body = ok and decoded or nil
  end

  -- A system need not have a property, so a missing property id is NOT a
  -- broken response. The token plus SOME identity is the contract.
  if type(body) ~= "table" or IsEmpty(body.token) or (IsEmpty(body.property_id) and IsEmpty(body.system_id)) then
    -- A 2xx with an unusable body is a server-side contract break, not a
    -- dealer error. Say so plainly rather than leaving "Pairing..." up.
    UpdateProperty("Connection Status", "Pairing failed - unexpected response")
    log:error("Pairing response did not contain a token and property id")
    return false
  end

  persist:set(TOKEN_KEY, body.token, true)
  persist:set(PROPERTY_KEY, body.property_id or "")
  persist:set(SYSTEM_KEY, body.system_id or "")
  -- Phase 5: the per-controller entitlement secret rides the same
  -- pairing response. Absent on older platforms — that is the unsigned
  -- legacy path, not an error.
  if type(body.agent_secret) == "string" and body.agent_secret ~= "" then
    persist:set(AGENT_SECRET_KEY, body.agent_secret, true)
  end
  if type(body.support_id) == "string" and body.support_id ~= "" then
    persist:set(SUPPORT_ID_KEY, body.support_id)
  end
  -- Mirrored into a hidden readonly property. Property VALUES live in the
  -- project file and survive a driver update; encrypted persist has not
  -- (measured: five re-pairs on the first customer site, one per update).
  -- The same trust domain as Composer access, which can pair afresh anyway.
  UpdateProperty(
    "Pairing Backup",
    JSON:encode({
      token = body.token,
      system_id = body.system_id or "",
      property_id = body.property_id or "",
      agent_secret = type(body.agent_secret) == "string" and body.agent_secret or "",
      support_id = type(body.support_id) == "string" and body.support_id or "",
    }),
    true
  )
  persist:set(PROPERTY_NAME_KEY, body.property_name or "")
  persist:set(SITE_LABEL_KEY, body.site_label or "")
  -- The account picture the Agent shows before its first refresh (#3). A
  -- blank tier means the platform could not confirm it; keep last-known.
  if type(body.subscription_tier) == "string" and body.subscription_tier ~= "" then
    persist:set(SUBSCRIPTION_TIER_KEY, body.subscription_tier)
  end
  if type(body.company_name) == "string" and body.company_name ~= "" then
    persist:set(COMPANY_NAME_KEY, body.company_name)
  end
  showPairingState()
  C4:FireEvent("Paired")
  log:info(
    "Paired to system %s (property %s)",
    tostring(body.system_id),
    body.property_id and tostring(body.property_id) or "none"
  )

  scheduleTimers()
  sendFullSync()
  sendHeartbeat()
  refreshEntitlements("paired")

  return true
end

--- The shared failure painter for both pairing doors.
local function pairError(err)
  local code_ = err and err.code
  if code_ == 404 or code_ == 410 then
    UpdateProperty("Connection Status", "Pairing failed - code is invalid or expired")
  elseif type(code_) == "number" then
    UpdateProperty("Connection Status", string.format("Pairing failed - HTTP %d", code_))
  else
    UpdateProperty("Connection Status", "Pairing failed - SmartBuildOS unreachable")
  end
  log:error("Pairing failed: %s", tostring(err and (err.error or err.code) or err))
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
        driver_name = C4:GetDeviceData(C4:GetDeviceID(), "name"),
        driver_device_id = C4:GetDeviceID(),
        director_device_id = select(1, directorIdentity()),
        director_name = select(2, directorIdentity()),
      },
    }, { ["Content-Type"] = "application/json" }, { timeout = REQUEST_TIMEOUT })
    :next(function(response)
      if applyPairResponse(response) then
        -- The code is spent. Clearing it keeps it out of the project file and
        -- makes the field obviously reusable for a future re-pair.
        UpdateProperty("Pairing Code", "", true)
      end
    end, pairError)
end

--- The controller identity every pairing call carries.
local function pairingSystemInfo()
  return {
    controller_type = C4:GetSystemType(),
    os_version = C4:GetVersionInfo().version,
    driver_version = C4:GetDriverConfigInfo("version"),
    device_id = C4:GetDeviceID(),
    -- The DRIVER's own identity, named as such. Kept because it is genuinely
    -- useful (which instance, which version) — it was only ever wrong as an
    -- answer to "what is the Director?".
    driver_name = C4:GetDeviceData(C4:GetDeviceID(), "name"),
    driver_device_id = C4:GetDeviceID(),
    director_device_id = select(1, directorIdentity()),
    director_name = select(2, directorIdentity()),
  }
end

--- Account-number pairing, step 1: ask SmartBuildOS to email a code to the
--- account's own address. The platform answers the same whether or not the
--- account exists, so the driver only ever reports the generic outcome — it
--- never becomes a way to test which account numbers are real.
--- @param accountNumber string The account number (company code) the client typed.
local function requestAccountCode(accountNumber)
  local url = ingestUrl("pair/request-code")
  if not url then
    UpdateProperty("Connection Status", "API URL is not set")
    return
  end
  persist:set(ACCOUNT_NUMBER_KEY, accountNumber)
  log:info("Requesting an account pairing code")
  UpdateProperty("Connection Status", "Requesting a code...")
  http
    :post(url, {
      account_number = accountNumber,
      system = pairingSystemInfo(),
    }, { ["Content-Type"] = "application/json" }, { timeout = REQUEST_TIMEOUT })
    :next(function()
      UpdateProperty("Connection Status", "If that account matches, a code was emailed. Enter it in Verification Code.")
    end, function(err)
      local code_ = err and err.code
      if type(code_) == "number" then
        UpdateProperty("Connection Status", string.format("Could not request a code - HTTP %d", code_))
      else
        UpdateProperty("Connection Status", "Could not request a code - SmartBuildOS unreachable")
      end
      log:error("Account code request failed: %s", tostring(err and (err.error or err.code) or err))
    end)
end

--- Account-number pairing, step 2: submit the emailed code and pair. Reuses the
--- shared pair-response handler, so redeeming an emailed code and redeeming a
--- dealer pairing code end in exactly the same paired state.
--- @param accountNumber string
--- @param code string The code from the account's email.
local function redeemAccountCode(accountNumber, code)
  local url = ingestUrl("pair/verify-code")
  if not url then
    UpdateProperty("Connection Status", "API URL is not set")
    return
  end
  log:info("Verifying account pairing code")
  UpdateProperty("Connection Status", "Pairing...")
  http
    :post(url, {
      account_number = accountNumber,
      code = code,
      system = pairingSystemInfo(),
    }, { ["Content-Type"] = "application/json" }, { timeout = REQUEST_TIMEOUT })
    :next(function(response)
      if applyPairResponse(response) then
        -- The code is single-use. Clear it (and the now-consumed account number)
        -- so the field is obviously reusable for a future re-pair.
        UpdateProperty("Verification Code", "", true)
        persist:delete(ACCOUNT_NUMBER_KEY)
      end
    end, pairError)
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

--- Restores pairing from the property mirror when persist came up empty.
---
--- Exists because a driver UPDATE was costing a re-pair every time: encrypted
--- persist did not survive it, and the operator's evidence was five controller
--- rows on one site, one per update. Property values DO survive an update —
--- Composer keeps them in the project — so the mirror is the recovery path.
--- Identity details (names, address) refresh on the first check-in; only the
--- credential and scope need to come back from here.
function restorePairingFromBackup()
  if persist:get(TOKEN_KEY, "", true) ~= "" then
    return false
  end
  local raw = Properties["Pairing Backup"] or ""
  if raw == "" then
    return false
  end
  local ok, backup = pcall(function()
    return JSON:decode(raw)
  end)
  if not ok or type(backup) ~= "table" or IsEmpty(backup.token) then
    -- A backup that exists but cannot restore is the one case that must not
    -- be quiet: the installer believes updates keep pairing now, and a silent
    -- failure here looks exactly like that promise being broken at random.
    log:error("Pairing Backup present but unusable; a re-pair is needed")
    UpdateProperty("Driver Status", "Pairing backup unusable - re-pair needed")
    return false
  end
  persist:set(TOKEN_KEY, backup.token, true)
  persist:set(SYSTEM_KEY, backup.system_id or "")
  persist:set(PROPERTY_KEY, backup.property_id or "")
  if type(backup.agent_secret) == "string" and backup.agent_secret ~= "" then
    persist:set(AGENT_SECRET_KEY, backup.agent_secret, true)
  end
  if type(backup.support_id) == "string" and backup.support_id ~= "" then
    persist:set(SUPPORT_ID_KEY, backup.support_id)
  end
  log:info("Pairing restored from backup after a driver update")
  return true
end

--- Registers the programming-bridge variables on THIS instance.
---
--- Measured on the test system 2026-08-21: the four variables were in
--- driver.xml and absent from Composer's programming view. Static <variables>
--- register when a driver instance is first ADDED; an update-in-place does not
--- register ones added since — and every install in the field is an update, so
--- XML alone reaches nobody. AddVariable at init is idempotent in effect
--- (re-adding errors; the pcall absorbs it) and reaches every instance.
function registerBridgeVariables()
  for _, v in ipairs({
    { "NOTICE_TYPE", "" },
    { "ISSUE_SEVERITY", "None" },
    { "ISSUE_TEXT", "" },
    { "NOTICE_TEXT", "" },
  }) do
    pcall(function()
      C4:AddVariable(v[1], v[2], "STRING", true)
    end)
  end
  -- Events share the variables' add-time trap, proven on the same instance:
  -- FireEvent("Service Update") on an instance added before the event existed
  -- fires into a void — the Notification Agent never sees it, so the phone
  -- never buzzes, silently. AddEvent reaches every instance.
  for _, e in ipairs({
    { 8, "Service Update", "SmartBuildOS sent a notice for this home" },
    { 9, "Issue Detected", "SmartBuildOS detected a problem at this home" },
    { 11, "Issue Updated", "SmartBuildOS updated a previously reported problem" },
    { 10, "Issue Resolved", "SmartBuildOS resolved a reported problem" },
  }) do
    pcall(function()
      C4:AddEvent(e[1], e[2], e[3])
    end)
  end
end

function OnDriverLateInit()
  log:trace("OnDriverLateInit()")
  if not CheckMinimumVersion("Driver Status") then
    return
  end

  restorePairingFromBackup()

  registerBridgeVariables()

  for p, _ in pairs(Properties) do
    local status, err = pcall(OnPropertyChanged, p)
    if not status and err then
      log:error("Error in OnPropertyChanged for property '%s': %s", p, err or "unknown error")
    end
  end

  gInitialized = true
  UpdateProperty("Driver Status", "Online")
  showPairingState()

  -- Recording the start is safe: persist plus a pcall'd version read.
  -- ANNOUNCING it is not, and is deferred until the timers are armed.
  gStart = recordStart()

  --#ifndef DRIVERCENTRAL
  SetTimer("UpdateCheck", 30 * 60 * ONE_SECOND, function()
    -- The update channel REPORTS ITSELF now. It went five releases without
    -- updating on 2026-08-18 while every other signal looked healthy, and
    -- the only way to tell was to remember what had been published. A
    -- channel nobody can observe is a channel nobody can fix.
    gUpdate.checked_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
    gUpdate.automatic = toboolean(Properties["Automatic Updates"]) and true or false
    -- What the updater will compare against — the value that silently
    -- rejected every check when it came back nil.
    local okV, seen = pcall(function()
      return GetDriverVersion("smartbuildos.c4z")
    end)
    gUpdate.reads_version_as = okV and tostring(seen or "nil") or "error"
    if gUpdate.automatic then
      log:info("Checking for driver update (installed version reads as %s)", gUpdate.reads_version_as)
      UpdateDrivers()
    else
      log:info("Automatic Updates is off; not checking")
    end
  end, true)
  --#endif

  if not isPaired() then
    setConnected(false, "Not paired")
    log:warn("SmartBuildOS Connector is not paired. Paste a pairing code from SmartBuildOS.")
    return
  end

  -- One-time migration to the fast check-in default (2026-08-18). Composer
  -- properties persist across updates, so installs configured before the 30s/
  -- 1m/2m options existed would sit on the old 5m/15m defaults forever —
  -- and the property is the command latency. Deliberately narrow: only the
  -- two old DEFAULT values are moved, an installer's explicit 30m/1h choice
  -- is not overridden, and the flag makes it happen once, so choosing 5m
  -- again afterwards sticks.
  if persist:get("hb_fast_default_applied") == nil then
    persist:set("hb_fast_default_applied", true)
    local current = Properties["Heartbeat Interval"]
    if current == "5m" or current == "15m" then
      Properties["Heartbeat Interval"] = "1m"
      UpdateProperty("Heartbeat Interval", "1m")
      log:info("Heartbeat Interval migrated %s -> 1m (one-time fast check-in default)", tostring(current))
    end
  end

  -- Guarded INDIVIDUALLY, because this corridor has now killed the timers
  -- twice: once at 17:30 on 2026-08-18 (the announceStart incident, recorded
  -- below) and again on 2026-08-21 15:55–17:12, when something in here threw
  -- after a driver update and the connector ran actions perfectly for an hour
  -- while sending nothing — EC calls work without timers, which makes this
  -- failure look like a healthy driver to everyone except the platform.
  -- Timers arm NO MATTER WHAT above them survives, and a failure NAMES itself.
  for _, step in ipairs({
    { "registerSystemEvents", registerSystemEvents },
    { "applyDiscovery", applyDiscovery },
    -- Phase 5: paint licensing properties from the cache, then fetch only
    -- if the revalidate window has passed. Guarded like the rest — a
    -- licensing hiccup must never cost the heartbeat timers below.
    { "updateLicenseProperties", updateLicenseProperties },
    { "entitlementTick", entitlementTick },
  }) do
    local okStep, errStep = pcall(step[2])
    if not okStep then
      log:error("Init step %s failed (continuing to timers): %s", step[1], tostring(errStep))
    end
  end
  scheduleTimers()

  -- ⚠ ANNOUNCED ONLY AFTER THE TIMERS ARE ARMED, AND NEVER FATALLY.
  --
  -- This block used to sit ABOVE scheduleTimers with an unguarded
  -- C4:FireEvent in it, and it took the connector down at 17:30 on
  -- 2026-08-18. The shape is worth keeping: it runs only when kind ==
  -- "reload", so the driver UPDATE that installed it took the safe path and
  -- looked perfect for three minutes — and the first real Director restart
  -- afterwards threw, aborted OnDriverLateInit, and left a driver with no
  -- heartbeat timer AND no update timer. Silent, and unable to update itself
  -- out of it.
  --
  -- Telling somebody about a restart is decoration. Reporting at all is the
  -- product. Decoration never runs before the product, and never uncaught.
  announceStart()
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
-- The dispatcher logs every property VALUE unless told otherwise, and the
-- token-hygiene test proved it: the mirror's JSON — token included — landed in
-- 22 log lines.
--
-- Keyed by the RAW property name, spaces and all: OnPropertyChanged looks up
-- suppressDebug BEFORE it sanitises the name, which the first attempt at this
-- fix discovered by not working. Both spellings are set because relying on the
-- dispatcher's internal ordering twice would be asking for the same surprise.
OPC.suppressDebug = OPC.suppressDebug or {}
OPC.suppressDebug["Pairing Backup"] = true
OPC.suppressDebug.Pairing_Backup = true
OPC.suppressDebug["Pairing Code"] = true
OPC.suppressDebug.Pairing_Code = true
OPC.suppressDebug["Verification Code"] = true
OPC.suppressDebug.Verification_Code = true

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

-- Account-number pairing (#6), alongside the dealer pairing code. Entering an
-- account number emails a code to the account; entering the code pairs. Both
-- guard on gInitialized so the property replay on every Director reload — which
-- runs before init completes — never re-fires an email or a pairing attempt.
function OPC.Account_Number(propertyValue)
  log:trace("OPC.Account_Number('%s')", propertyValue)
  if not gInitialized then
    return
  end
  local account = (propertyValue or ""):gsub("%s+", ""):upper()
  if account == "" then
    return
  end
  requestAccountCode(account)
end

function OPC.Verification_Code(propertyValue)
  log:trace("OPC.Verification_Code(<redacted>)")
  if not gInitialized then
    return
  end
  local code = (propertyValue or ""):gsub("%s+", "")
  if code == "" then
    return
  end
  local account = persist:get(ACCOUNT_NUMBER_KEY, "") or ""
  if account == "" then
    account = (Properties["Account Number"] or ""):gsub("%s+", ""):upper()
  end
  if account == "" then
    UpdateProperty("Connection Status", "Enter your account number first")
    return
  end
  redeemAccountCode(account, code)
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

function OPC.Update_Source(propertyValue)
  log:trace("OPC.Update_Source('%s')", propertyValue)
end

--- Updates installed SmartBuildOS drivers.
---
--- Source is server-of-record first: a paired Agent asks SmartBuildOS what
--- builds it hosts (`/api/driver-cloud/updates`) and installs from there, so a
--- dealer never has to touch GitHub. The `Update Source` property chooses:
---   Auto (default) — SmartBuildOS when paired, falling back to GitHub when the
---     platform hosts nothing yet or is unreachable (nothing regresses during
---     the migration to self-hosted builds);
---   SmartBuildOS — platform only (skips silently if unpaired, since the
---     endpoint is token-authed);
---   GitHub — the original public-releases path.
--- Both updaters filter to drivers actually installed and write into C4Z_ROOT
--- themselves, so there is no directory setup here.
--- @param forceUpdate? boolean Re-download even when already current.
function UpdateDrivers(forceUpdate)
  log:trace("UpdateDrivers(%s)", forceUpdate)
  local source = Properties["Update Source"] or "Auto"
  local prerelease = Properties["Update Channel"] == "Prerelease"

  local function fromGitHub()
    githubUpdater:updateAll(DRIVER_GITHUB_REPO, DRIVER_FILENAMES, prerelease, forceUpdate):next(function(updated)
      if not IsEmpty(updated) then
        log:info("Updated driver(s) from GitHub: %s", table.concat(updated, ","))
      else
        log:info("No driver updates available (GitHub)")
      end
    end, function(err)
      log:error("An error occurred updating drivers from GitHub: %s", tostring(err))
    end)
  end

  local url = driverCloudUrl("updates")
  if source ~= "GitHub" and url and isPaired() then
    -- ⚠ DOT, NOT COLON — and the `githubUpdater:updateAll` two lines up is a
    -- colon on purpose. `lib.github-updater` ends in `return GitHubUpdater:new()`,
    -- an instance whose methods use `self`; `lib.sbos-updater` ends in
    -- `return M`, a plain module of dot functions. A colon here passes the
    -- module itself as `url`, shifting every argument along: `headers` receives
    -- the URL string and `pairs(headers or {})` dies with "table expected, got
    -- string" before a single request is made. Two updaters side by side with
    -- opposite call conventions is the whole trap.
    sbosUpdater
      .updateAll(url, authHeaders(), DRIVER_FILENAMES, prerelease and "Prerelease" or "Production", forceUpdate)
      :next(function(updated)
        if not IsEmpty(updated) then
          log:info("Updated driver(s) from SmartBuildOS: %s", table.concat(updated, ","))
        elseif source == "Auto" then
          log:info("No SmartBuildOS-hosted updates; checking GitHub (Auto)")
          fromGitHub()
        else
          log:info("No driver updates available (SmartBuildOS)")
        end
      end, function(err)
        log:warn(
          "SmartBuildOS update check failed (%s)%s",
          tostring(err),
          source == "Auto" and "; checking GitHub" or ""
        )
        if source == "Auto" then
          fromGitHub()
        end
      end)
    return
  end

  if source == "SmartBuildOS" then
    log:info("Update Source is SmartBuildOS but the Agent is not paired; nothing to check")
    return
  end
  fromGitHub()
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

--- Closes the doorbell socket and stops its timers.
local function realtimeStop()
  CancelTimer(REALTIME_HB_TIMER)
  CancelTimer(REALTIME_RECONNECT_TIMER)
  if gRealtime.ws ~= nil then
    pcall(function()
      gRealtime.ws:delete()
    end)
  end
  gRealtime.ws = nil
  gRealtime.client = nil
end

--- Connects (or reconnects) the doorbell to the platform-offered channel.
---
--- The socket is an ACCELERATOR, never a dependency: every failure path ends
--- in a scheduled retry while the heartbeat timers carry on regardless, so
--- the worst a dead Realtime service can do is return command latency to one
--- heartbeat interval — exactly where it was before this existed.
local function realtimeConnect()
  local cfg = gRealtime.config
  if cfg == nil or not gMonitor then
    return
  end
  realtimeStop()

  local url = RealtimeClient.socketUrl(cfg.url, cfg.key)
  if url == nil or IsEmpty(cfg.channel) then
    return
  end

  local client = RealtimeClient.new({
    encode = function(t)
      return JSON:encode(t)
    end,
    decode = function(raw)
      return JSON:decode(raw)
    end,
  })

  local ws = WebSocket:new(url)
  if ws == nil then
    log:warn("Realtime: could not create the socket; retrying in %ds", gRealtime.backoff)
    SetTimer(REALTIME_RECONNECT_TIMER, gRealtime.backoff * ONE_SECOND, realtimeConnect)
    gRealtime.backoff = math.min(gRealtime.backoff * 2, 300)
    return
  end

  gRealtime.ws = ws
  gRealtime.client = client

  ws:SetEstablishedFunction(function()
    ws:Send(client:joinFrame(cfg.channel))
    -- Phoenix reaps silent sockets; ~30s keeps this one alive.
    SetTimer(REALTIME_HB_TIMER, 30 * ONE_SECOND, function()
      if gRealtime.ws ~= nil and gRealtime.client ~= nil then
        pcall(function()
          gRealtime.ws:Send(gRealtime.client:heartbeatFrame())
        end)
      end
    end, true)
  end)

  ws:SetProcessMessageFunction(function(_, data)
    local event = client:handleFrame(data)
    if event.type == "joined" then
      gRealtime.backoff = 15
      log:info("Realtime doorbell connected (channel %s)", tostring(cfg.channel))
    elseif event.type == "ping" then
      -- The doorbell rang. The REACTION is the ordinary authenticated
      -- heartbeat — the socket itself is never trusted with instructions.
      log:debug("Realtime ping; checking in")
      SetTimer(REALTIME_PING_TIMER, 2 * ONE_SECOND, function()
        sendHeartbeat()
      end)
    elseif event.type == "closed" then
      log:warn("Realtime channel closed; reconnecting in %ds", gRealtime.backoff)
      SetTimer(REALTIME_RECONNECT_TIMER, gRealtime.backoff * ONE_SECOND, realtimeConnect)
      gRealtime.backoff = math.min(gRealtime.backoff * 2, 300)
    end
  end)

  ws:SetClosedByRemoteFunction(function()
    log:warn("Realtime socket closed by remote; reconnecting in %ds", gRealtime.backoff)
    SetTimer(REALTIME_RECONNECT_TIMER, gRealtime.backoff * ONE_SECOND, realtimeConnect)
    gRealtime.backoff = math.min(gRealtime.backoff * 2, 300)
  end)

  ws:Start()
end

--- Accepts (or drops) the platform's doorbell offer from a heartbeat response.
function applyRealtimeConfig(offer)
  if type(offer) ~= "table" or IsEmpty(offer.url) or IsEmpty(offer.key) or IsEmpty(offer.channel) then
    if gRealtime.config ~= nil then
      log:info("Realtime offer withdrawn; closing the doorbell")
      gRealtime.config = nil
      realtimeStop()
    end
    return
  end
  local next = { url = tostring(offer.url), key = tostring(offer.key), channel = tostring(offer.channel) }
  local unchanged = gRealtime.config ~= nil
    and gRealtime.config.url == next.url
    and gRealtime.config.key == next.key
    and gRealtime.config.channel == next.channel
  if unchanged and gRealtime.ws ~= nil then
    return
  end
  gRealtime.config = next
  gRealtime.backoff = 15
  realtimeConnect()
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

  -- ── What Control4 calls this project ─────────────────────────────────────
  --
  -- ⚠ ANSWERED 2026-08-19, on a live XDT_CORE1 running OS 4.2.0. A DRIVER
  -- CANNOT READ THE COMPOSER PROJECT NAME. Measured, every one of them:
  --
  --   GetProjectName        nil — the method does not exist
  --   GetSystemName         nil — the method does not exist
  --   GetProjectId          nil — the method does not exist
  --   GetControllerName     nil — the method does not exist
  --   GetDeviceData(1,name) nil
  --   GetDeviceData(0,name) nil
  --   hierarchy top         [13]Home(2)
  --
  -- ⚠ THAT CONCLUSION WAS WRONG, and the re-run it asked for is what caught
  -- it. Corrected 2026-09-01 on the same controller:
  --
  --   GetHostname                    Beta-Miami-000FFF9CB2CB
  --   GetProjectItems(LOCATIONS)     <id>1</id><name>Miami-Beta</name><type>1</type>
  --
  -- Both names are readable. The sweep missed them because it asked
  -- GetProjectHierarchy, which begins at the SITE (type 2, "Home") and never
  -- shows the type-1 root above it — so "Home" was the top of the wrong tree,
  -- not the top of the project. The four methods it tried do not exist at all,
  -- and four nils from four non-existent methods prove nothing.
  --
  -- Kept as a standing probe, because a negative result is worth as much as a
  -- positive one — but read it as "not found by these means", never as "not
  -- reachable". Re-run against a different OS version before concluding
  -- anything has changed.
  --
  -- Deliberately in diagnose() and not surveyTelemetry(): the latter runs
  -- only from the Actions tab in Composer, which is why its project-hierarchy
  -- dump has never once reached the cloud — eleven REQUEST_DIAGNOSTICS runs,
  -- twelve lines every time, and the answer sitting in a function nobody
  -- remote can trigger.
  local function probe(label, fn)
    local okP, value = pcall(fn)
    if not okP then
      note("project? %s -> ERROR %s", label, tostring(value):sub(1, 160))
    elseif type(value) == "table" then
      note("project? %s -> table %s", label, JSON:encode(value):sub(1, 320))
    else
      note("project? %s -> %s", label, tostring(value):sub(1, 200))
    end
  end

  probe("GetProjectName", function()
    return C4:GetProjectName()
  end)
  probe("GetSystemName", function()
    return C4:GetSystemName()
  end)
  probe("GetProjectId", function()
    return C4:GetProjectId()
  end)
  probe("GetControllerName", function()
    return C4:GetControllerName()
  end)
  -- Item 1 is the project root in Composer's tree; if the name lives anywhere
  -- addressable, this is the most likely place.
  probe("GetDeviceData(1,name)", function()
    return C4:GetDeviceData(1, "name")
  end)
  probe("GetDeviceData(0,name)", function()
    return C4:GetDeviceData(0, "name")
  end)
  -- The top of the location tree: type 2 is the site. On this project it is
  -- named "Home", which may well be the Control4 default rather than anything
  -- an integrator chose — worth confirming against a second project.
  -- ── Untested until now (2026-09-01) ──────────────────────────────────────
  --
  -- The 2026-08-19 sweep above concluded "a driver cannot read the project
  -- name" after trying four methods that do not exist. It never tried the two
  -- that DO exist in the documented API, and the field still shows a name the
  -- platform cannot account for: Composer displays this Director as
  -- "Beta-Miami" while the platform reports "Control4 CORE 1".
  --
  -- GetHostname (OS 3.3.1+) is the controller's host name, which is what an
  -- integrator sets in System Manager and the likeliest home for a name like
  -- "Beta-Miami". GetDeviceDisplayName (OS 1.6.0+) is documented as "the name
  -- of the device as shown in Composer" — i.e. the OFFICIAL form of what
  -- projectItemName() currently reconstructs by scraping GetProjectItems XML.
  -- If those two disagree, the scrape is the bug.
  -- ── The controller's own address ─────────────────────────────────────────
  --
  -- "Director IP" has been a row in the technical inventory since it shipped
  -- and nothing has ever filled it. The obvious sources answer with the
  -- controller's SELF-reference (the Director is 127.0.0.1 in this driver's
  -- own inventory), so these dump the RAW values — including every connection
  -- row, which the old `GetNetworkConnections -> table, N entr(ies)` line
  -- counted and threw away. A count cannot tell you an address.
  probe("GetControllerNetworkAddress", function()
    return C4:GetControllerNetworkAddress()
  end)
  probe("GetMyNetworkAddress", function()
    return C4:GetMyNetworkAddress()
  end)
  probe("connections (address/type/state)", function()
    local conns = C4:GetNetworkConnections()
    local rows = {}
    for _, conn in pairs(type(conns) == "table" and conns or {}) do
      if type(conn) == "table" then
        rows[#rows + 1] = string.format(
          "%s(type=%s,state=%s,dev=%s)",
          tostring(conn.address),
          tostring(conn.type),
          tostring(conn.state),
          tostring(conn.deviceid)
        )
      end
    end
    return table.concat(rows, " ")
  end)
  -- What the driver will actually SEND, after the routable check. Printed
  -- beside the raw values so a nil here is traceable to which source failed.
  probe("controllerIp() -> sent", function()
    return controllerIp() or "nil (nothing routable found)"
  end)

  -- Composer's Director page shows MODEL / MAC / OS / SERVICE TAG / IP / I/O
  -- FIRMWARE plus Zigbee and ZAP state and CPU/memory. Model and OS the driver
  -- already sends. Of the rest, only these have a documented API — the others
  -- (service tag, I/O firmware, ZAP, CPU, memory) appear nowhere in the 391
  -- documented calls, so they are probably Composer reading the controller's
  -- own system service rather than anything DriverWorks exposes. Probed, not
  -- assumed: that is exactly the mistake the project-name sweep made.
  probe("GetUniqueMAC", function()
    return C4:GetUniqueMAC()
  end)
  probe("GetUptime", function()
    return C4:GetUptime()
  end)
  probe("GetZigbeeEUID", function()
    return C4:GetZigbeeEUID()
  end)

  probe("GetHostname", function()
    return C4:GetHostname()
  end)
  probe("GetUname", function()
    return C4:GetUname()
  end)

  -- Is the reported name the SCRAPE or the fallback? `directorIdentity` uses
  -- `projectItemName(id) or driverName`, so "Control4 CORE 1" could be either
  -- the project item's name or the device's own name standing in for it. The
  -- two cases point at completely different fixes, and nothing recorded so far
  -- distinguishes them.
  local directorId = select(1, directorIdentity())
  probe("directorId", function()
    return directorId
  end)
  probe("projectItemName(director)", function()
    return directorId ~= nil and projectItemName(directorId) or "no director id"
  end)
  probe("GetDeviceDisplayName(director)", function()
    return directorId ~= nil and C4:GetDeviceDisplayName(directorId) or "no director id"
  end)
  probe("GetDeviceDisplayName()", function()
    return C4:GetDeviceDisplayName()
  end)
  -- The raw XML item, so a name that IS present but shaped differently than
  -- the non-greedy pattern expects is visible rather than silently nil.
  probe("raw item xml(director)", function()
    if directorId == nil then
      return "no director id"
    end
    local xml = C4:GetProjectItems("DEVICES", "LIMIT_DEVICE_DATA", "NO_ROOT_TAGS")
    for item in tostring(xml):gmatch("<item>(.-)</item>") do
      if tonumber(item:match("<id>%s*(%d+)%s*</id>") or "") == directorId then
        return item:sub(1, 300)
      end
    end
    return "id not found among items"
  end)

  -- The docs' own example for "general information about the project i.e.
  -- location, dealer info, etc" — the LOCATIONS filter, which this driver has
  -- never asked for. NO_ROOT_TAGS is dropped here on purpose: if a project
  -- name lives in a root tag, stripping it is exactly how we would keep
  -- missing it.
  probe("GetProjectItems(LOCATIONS) head", function()
    return C4:GetProjectItems("LOCATIONS", "LIMIT_DEVICE_DATA", "NO_ROOT_TAGS"):sub(1, 400)
  end)
  probe("GetProjectItems(LOCATIONS, root tags) head", function()
    return C4:GetProjectItems("LOCATIONS", "LIMIT_DEVICE_DATA"):sub(1, 400)
  end)

  probe("hierarchy top", function()
    local h = C4:GetProjectHierarchy()
    local tops = {}
    for id, loc in pairs(type(h) == "table" and h or {}) do
      if type(loc) == "table" then
        tops[#tops + 1] = string.format("[%s]%s(%s)", tostring(id), tostring(loc.name), tostring(loc.type))
      end
    end
    return table.concat(tops, " ")
  end)

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
reportDiagnostics = function(toCloud)
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
  -- Devices whose bindings say KEYPAD or BLIND — selection by the project's own
  -- classification, the method that has now beaten name-matching twice.
  local keypadIds, blindIds = {}, {}
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
                  if bc.class == "KEYPAD" and #keypadIds < 3 and keypadIds[#keypadIds] ~= id then
                    keypadIds[#keypadIds + 1] = id
                  elseif
                    (bc.class == "BLIND" or bc.class == "BLIND_GROUP")
                    and #blindIds < 3
                    and blindIds[#blindIds] ~= id
                  then
                    blindIds[#blindIds + 1] = id
                  end
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

  -- ── The T-0.6 residual: is there anything to LISTEN to? ─────────────────
  --
  -- The 22:24Z probe proved keypad button IDENTITY (298 named BUTTON_LINK
  -- bindings) and shade PRESENCE (BLIND class). What it did not answer is
  -- whether presses and movements are OBSERVABLE: that depends on the devices
  -- exposing VARIABLES a listener can register on. So dump every variable of
  -- the class-selected keypads and blinds, verbatim — if a LAST_BUTTON or
  -- LEVEL variable exists, the collection design writes itself; if nothing
  -- does, screens 4 and 6 stay honestly gated rather than optimistically
  -- built.
  for label, ids in pairs({ keypadvars = keypadIds, blindvars = blindIds }) do
    if #ids == 0 then
      note("PROBE %s: no class-selected devices", label)
    end
    for _, id in ipairs(ids) do
      local okV, vars = pcall(function()
        return C4:GetDeviceVariables(id)
      end)
      if okV and type(vars) == "table" then
        local count = 0
        for _, v in pairs(vars) do
          if type(v) == "table" and count < 40 then
            count = count + 1
            note("PROBE %s[%d] %s = %s", label, id, tostring(v.name), tostring(v.value):sub(1, 80))
          end
        end
        if count == 0 then
          note("PROBE %s[%d]: device exposes NO variables — nothing to listen to", label, id)
        end
      else
        note("PROBE %s[%d]: variables unavailable: %s", label, id, tostring(vars))
      end
    end
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
  UpdateProperty("Pairing Backup", "", true)
  gRealtime.config = nil
  realtimeStop()
  persist:delete(PROPERTY_KEY)
  -- ⚠ Must be cleared too. `isPaired()` is satisfied by EITHER id, so a
  -- surviving system id would leave the driver claiming to be paired with no
  -- token — authenticated requests failing forever against a system the
  -- dealer believes they disconnected.
  persist:delete(SYSTEM_KEY)
  persist:delete(PROPERTY_NAME_KEY)
  persist:delete(SITE_LABEL_KEY)
  -- Licensing state is pairing state: the secret and every cached assertion
  -- belong to the identity being forgotten. Registered drivers fall back to
  -- LEGACY on their next ask — unpairing never darks a home (charter D3).
  persist:delete(AGENT_SECRET_KEY)
  persist:delete(SUPPORT_ID_KEY)
  persist:delete(ENTITLEMENT_CACHE_KEY)
  CancelTimer(ENTITLEMENT_TIMER)
  updateLicenseProperties()
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
-- ─── Structured telemetry commands (Phase 2, T-2.5) ─────────────────────────
--
-- The Composer-facing half of the general telemetry model. SEND_EVENT stays
-- exactly as it was -- these are ADDITIONS, and they queue rather than send:
-- a keypad macro that fires REPORT_COUNTER twenty times in a burst becomes one
-- batched upload, not twenty HTTP requests.
--
-- Everything lands as category CUSTOM with privacy INTEGRATOR_ONLY. Custom
-- telemetry describes racks, generators and garage doors -- integrator
-- material until a human decides otherwise, which is a platform decision the
-- driver must not preempt.

--- Queues one custom telemetry event and confirms in the Lua output.
--- @param eventType string state | measurement | counter | fault | service
--- @param name string What the installer called it.
--- @param fields table Extra platform-shape fields.
local function reportCustom(eventType, name, fields)
  if name == "" then
    log:warn("REPORT_%s called with no NAME; ignoring", eventType:upper())
    return
  end
  local event = {
    subcategory = eventType,
    source_type = "composer",
    source_name = name,
    event_type = eventType,
    privacy_class = "INTEGRATOR_ONLY",
  }
  for k, v in pairs(fields or {}) do
    event[k] = v
  end
  gTelemetry:add("CUSTOM", event)
  log:info("Queued %s %s (%d queued)", eventType, name, gTelemetry:depth())
end

function EC.REPORT_STATE(tParams)
  tParams = tParams or {}
  reportCustom("state", tostring(tParams.NAME or ""), {
    state = tostring(tParams.VALUE or ""),
  })
end

function EC.REPORT_MEASUREMENT(tParams)
  tParams = tParams or {}
  local value = tonumber(tParams.VALUE)
  if value == nil then
    -- A measurement whose value does not parse is refused loudly rather than
    -- shipped as text: "37%" in a numeric column is how a chart goes blank.
    log:warn(
      "REPORT_MEASUREMENT %s: VALUE %s is not a number; ignoring",
      tostring(tParams.NAME or ""),
      tostring(tParams.VALUE or "")
    )
    return
  end
  reportCustom("measurement", tostring(tParams.NAME or ""), {
    value_numeric = value,
    unit = tostring(tParams.UNIT or ""),
  })
end

function EC.REPORT_COUNTER(tParams)
  tParams = tParams or {}
  reportCustom("counter", tostring(tParams.NAME or ""), {
    value_numeric = 1,
  })
end

function EC.REPORT_FAULT(tParams)
  tParams = tParams or {}
  reportCustom("fault", tostring(tParams.NAME or ""), {
    value_text = tostring(tParams.DETAIL or ""),
  })
end

function EC.REPORT_SERVICE_EVENT(tParams)
  tParams = tParams or {}
  reportCustom("service", tostring(tParams.NAME or ""), {
    value_text = tostring(tParams.DETAIL or ""),
  })
end

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

-- ─── SmartBuildOS Agent: local licensing authority (Driver Cloud Phase 2) ─────
--
-- Per docs/driver-cloud-charter.md (decision D1): this driver IS the
-- SmartBuildOS Agent. Dependent SmartBuildOS drivers (UniFi Protect today,
-- everything after) register here and ask entitlement questions here; they
-- never hold account credentials and never call licensing APIs themselves.
--
-- PHASE 2 SCOPE: registration inventory + the protocol + the LEGACY answer.
-- The entitlement backend does not exist yet, so every check answers
-- LEGACY — drivers operate normally and say so. Phase 5 replaces
-- answerEntitlement's body with HMAC-verified cached assertions from the
-- platform; the protocol and every caller stay untouched (charter D3).

--- Registered SmartBuildOS drivers in this project, persisted:
--- { [sku] = { version, device_id, registered_at, last_seen } }.
local SBOS_DRIVERS_PERSIST = "sbos_driver_inventory"

-- ── Phase 5: real entitlements ───────────────────────────────────────────────
--
-- The Agent fetches HMAC-signed assertions from Driver Cloud, verifies them
-- with the per-controller secret minted at pairing, caches them in encrypted
-- persist, and answers dependent drivers from that cache. Staleness ladder
-- (server-tunable via the refresh response): fresh within cache_days; then a
-- dated grace until GRACE_DAYS; then CLOUD_VALIDATION_REQUIRED. A sku with
-- no assertion — or an Agent that has never fetched — still answers LEGACY:
-- enforcement can never precede issuance (charter D3).

--- Days from the last successful fetch until an authorized status stops
--- riding grace and demands the cloud. cache_days (7 by default) ends the
--- as-issued window first; this ends the grace window.
local GRACE_DAYS = 10

--- Refresh bookkeeping that must not persist across reboots.
local gEntitlements = {
  lastAttempt = 0,
  inFlight = false,
  lastError = "",
  verifyWarned = {},
  backwardsWarned = false,
  clockSkewed = false,
}
-- One Agent-authenticated provisioning exchange per SKU at a time. The
-- dependent driver receives only the resulting controller+SKU+install scoped
-- upload capability — never this Agent's bearer or HMAC secret.
local gDriverCloudProvisioning = {}

--- @return string secret The per-controller HMAC secret, "" pre-Phase-5 pairings.
local function agentSecret()
  return persist:get(AGENT_SECRET_KEY, "", true) or ""
end

--- @return table|nil cache The entitlement cache, shape-checked.
local function entitlementCache()
  local cache = persist:get(ENTITLEMENT_CACHE_KEY, nil, true)
  if type(cache) ~= "table" or type(cache.assertions) ~= "table" then
    return nil
  end
  return cache
end

--- The nullable string fields ride JSON null; anything non-string is "".
local function fieldOrEmpty(value)
  if type(value) == "string" then
    return value
  end
  return ""
end

--- Canonical signing string. MUST byte-match canonicalAssertion() in the
--- platform's src/lib/driver-cloud/entitlements.ts — fixed field order,
--- pipe-joined, features comma-joined. NEVER reorder.
--- @param a table A decoded assertion.
--- @return string canonical
local function canonicalAssertion(a)
  local features = {}
  if type(a.features) == "table" then
    for _, feature in ipairs(a.features) do
      features[#features + 1] = tostring(feature)
    end
  end
  return table.concat({
    tostring(a.v or ""),
    fieldOrEmpty(a.sig_alg),
    fieldOrEmpty(a.company_id),
    fieldOrEmpty(a.controller_id),
    fieldOrEmpty(a.driver_sku),
    fieldOrEmpty(a.status),
    fieldOrEmpty(a.license_type),
    table.concat(features, ","),
    fieldOrEmpty(a.issued_at),
    fieldOrEmpty(a.valid_until),
    fieldOrEmpty(a.grace_until),
  }, "|")
end

--- HMAC-SHA256 as lowercase hex, matching node crypto's digest("hex").
--- @return string|nil hex nil when the platform primitive is unavailable.
local function hmacHex(secret, data)
  local ok, result = pcall(function()
    return C4:HMAC("SHA256", secret, data, {
      return_encoding = "HEX",
      key_encoding = "NONE",
      data_encoding = "NONE",
    })
  end)
  if not ok or type(result) ~= "string" or result == "" then
    return nil
  end
  return result:lower()
end

--- Re-signs the canonical string and compares. There is no C4:Verify; this
--- IS the verification (charter D2). An unavailable HMAC primitive fails
--- verification — the fetch path then drops the assertion LOUDLY and the
--- unknown sku answers LEGACY, so an ancient OS degrades, never darks.
--- @return boolean verified
local function verifyAssertion(a, secret)
  local expected = hmacHex(secret, canonicalAssertion(a))
  if expected == nil then
    return false
  end
  return expected == tostring(a.sig or ""):lower()
end

--- Reports one licensing event to Driver Cloud. Fire-and-forget: an event
--- that cannot send must never affect licensing behavior.
local function licenseEvent(severity, category, code, message)
  local url = driverCloudUrl("events")
  if not url or not isPaired() then
    return
  end
  pcall(function()
    http
      :post(url, {
        events = {
          {
            severity = severity,
            category = category,
            code = code,
            message = message,
            driver_sku = "SBOS_AGENT",
          },
        },
      }, authHeaders(), { timeout = REQUEST_TIMEOUT })
      :next(function() end, function() end)
  end)
end

--- Parses an ISO-8601 UTC timestamp ("2026-08-29T04:00:00.000Z") to epoch
--- seconds, nil when unparseable. os.time interprets its table as LOCAL
--- time, so the current UTC offset is backed out via the os.date round-trip.
--- @param iso string
--- @return number|nil epoch
local function isoToEpoch(iso)
  local y, mo, d, h, mi, sec = tostring(iso or ""):match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
  if y == nil then
    return nil
  end
  local utc = os.time({
    year = tonumber(y),
    month = tonumber(mo),
    day = tonumber(d),
    hour = tonumber(h),
    min = tonumber(mi),
    sec = tonumber(sec),
  })
  if utc == nil then
    return nil
  end
  local offset = os.difftime(os.time(os.date("*t", utc)), os.time(os.date("!*t", utc)))
  return utc + offset
end

--- Clock-anomaly policy (charter: FLAG, never auto-brick).
---
--- The exploit this closes: set the controller clock BACKWARDS and a cached
--- authorization stays "fresh" forever, because age = now - fetched_at goes
--- negative. cacheAge() therefore clamps at zero and reports the anomaly so
--- the ladder keeps moving — while a skewed-but-forward clock only ever
--- makes the ladder STRICTER, which grace absorbs. Nothing here refuses an
--- answer: a wrong clock is a support signal, not a dark home.
--- @param cache table
--- @return number ageSeconds
--- @return boolean anomalous
local function cacheAge(cache)
  local fetched = tonumber(cache.fetched_at) or 0
  local age = os.time() - fetched
  if age < -3600 then
    return 0, true
  end
  return math.max(0, age), false
end

--- Reports (once per boot) that the controller clock disagrees with the
--- platform's. Called from the refresh path where both times are in hand.
local function noteClockSkew(serverIso)
  local serverEpoch = isoToEpoch(serverIso)
  if serverEpoch == nil then
    return
  end
  local skew = os.time() - serverEpoch
  local skewed = math.abs(skew) > 48 * 3600
  -- Warn on the transition INTO skew (the connection-transition pattern used
  -- throughout this driver), so a fixed-then-broken clock re-alerts and a
  -- persistent one does not spam every refresh.
  if skewed and not gEntitlements.clockSkewed then
    local hours = math.floor(math.abs(skew) / 3600)
    local direction = skew > 0 and "ahead of" or "behind"
    log:warn("Controller clock is %dh %s SmartBuildOS - licensing stays up, but fix the clock", hours, direction)
    UpdateProperty(
      "License Cloud",
      string.format("OK - but the controller clock is %dh %s the cloud", hours, direction)
    )
    licenseEvent(
      "WARNING",
      "CONFIGURATION",
      "clock_skew",
      string.format("Controller clock %dh %s platform time", hours, direction)
    )
  end
  gEntitlements.clockSkewed = skewed
end

--- Paints the License Cloud + Support ID properties from current state.
function updateLicenseProperties()
  local cache = entitlementCache()
  UpdateProperty("Support ID", persist:get(SUPPORT_ID_KEY, "") or (cache and fieldOrEmpty(cache.support_id)) or "")
  -- #3/#3a/#4: the account picture a dealer reads at a glance — which company
  -- this Agent authenticates, its SmartBuildOS subscription tier, and how many
  -- installed SmartBuildOS drivers currently hold a license. Painted in every
  -- path (including not-yet-validated) from cached values.
  do
    local company = persist:get(COMPANY_NAME_KEY, "") or ""
    local tier = persist:get(SUBSCRIPTION_TIER_KEY, "") or ""
    if not isPaired() then
      UpdateProperty("SmartBuildOS Company", "Not registered - pair to a company")
      UpdateProperty("Subscription Tier", "Not paired")
    else
      UpdateProperty("SmartBuildOS Company", company ~= "" and company or "Registered (name syncing)")
      local inGrace = type(cache) == "table" and cache.subscription_in_grace == true
      UpdateProperty("Subscription Tier", tier ~= "" and (tier .. (inGrace and " (grace)" or "")) or "Syncing...")
    end
    local installed, licensed = licensedDriverCounts()
    if installed == 0 then
      UpdateProperty("Licensed Drivers", "No SmartBuildOS drivers installed")
    else
      UpdateProperty("Licensed Drivers", string.format("%d licensed / %d installed", licensed, installed))
    end
  end
  if cache == nil then
    if isPaired() then
      UpdateProperty("License Cloud", "Not yet validated - drivers run in legacy mode")
    else
      UpdateProperty("License Cloud", "Not paired - drivers run in legacy mode")
    end
    return
  end
  local count = 0
  for _ in pairs(cache.assertions) do
    count = count + 1
  end
  local age = cacheAge(cache)
  local cacheDays = tonumber(cache.cache_days) or 7
  local label
  if age <= cacheDays * 86400 then
    label = string.format(
      "OK - %d assertion(s), checked %s",
      count,
      os.date("%Y-%m-%d %H:%M", tonumber(cache.fetched_at) or 0)
    )
  elseif age <= GRACE_DAYS * 86400 then
    label = string.format(
      "Offline - riding grace until %s",
      os.date("%Y-%m-%d", (tonumber(cache.fetched_at) or 0) + GRACE_DAYS * 86400)
    )
  else
    label = "Offline too long - cloud validation required"
  end
  if not cache.verified then
    label = label .. " (unsigned cache - re-pair to enable signing)"
  end
  UpdateProperty("License Cloud", label)
end

--- The answer for one SKU, from the cache through the staleness ladder.
--- @param sku string
--- @return table answer {status, license_type, features, grace_until, checked_at}
local function statusForSku(sku)
  local answer = {
    status = "LEGACY",
    license_type = "",
    features = "",
    grace_until = "",
    enforcement = "observe",
    checked_at = os.date("%Y-%m-%d %H:%M:%S"),
  }
  local cache = entitlementCache()
  if not isPaired() or cache == nil then
    return answer
  end
  -- Enforcement mode is UNSIGNED server config carried alongside the signed
  -- assertions: it changes how the driver REACTS to a status, never whether
  -- a status is authentic. Absent => observe (every pre-Phase-9 backend).
  if type(cache.enforcement) == "table" and cache.enforcement[sku] == "enforce" then
    answer.enforcement = "enforce"
  end
  local a = cache.assertions[sku]
  if type(a) ~= "table" then
    -- A sku the platform issued nothing for is not refused — it is simply
    -- not enrolled in licensing yet. Enforcement cannot precede issuance.
    return answer
  end
  if fieldOrEmpty(a.driver_sku) ~= sku then
    -- The assertion's bound sku disagrees with the key it is filed under: a
    -- misfiled or swapped entry. The signature covers driver_sku so this also
    -- fails verification below — but refuse plainly rather than trust the key.
    return {
      status = "CLOUD_VALIDATION_REQUIRED",
      license_type = "",
      features = "",
      grace_until = "",
      checked_at = os.date("%Y-%m-%d %H:%M:%S"),
    }
  end

  local secret = agentSecret()
  if secret ~= "" and cache.verified and not verifyAssertion(a, secret) then
    -- A cached assertion that no longer verifies is tampering or corruption,
    -- never a network condition. Say so once per boot, loudly.
    if not gEntitlements.verifyWarned[sku] then
      gEntitlements.verifyWarned[sku] = true
      log:error("Entitlement for %s failed signature verification - demanding cloud validation", sku)
      licenseEvent(
        "CRITICAL",
        "SECURITY",
        "assertion_verify_failed",
        "Cached assertion for " .. sku .. " failed HMAC verification"
      )
    end
    answer.status = "CLOUD_VALIDATION_REQUIRED"
    return answer
  end

  local features = {}
  if type(a.features) == "table" then
    for _, feature in ipairs(a.features) do
      features[#features + 1] = tostring(feature)
    end
  end
  answer.license_type = fieldOrEmpty(a.license_type)
  answer.features = table.concat(features, ",")
  answer.grace_until = fieldOrEmpty(a.grace_until)
  answer.checked_at = fieldOrEmpty(cache.checked_at)

  local age, clockAnomaly = cacheAge(cache)
  if clockAnomaly and not gEntitlements.backwardsWarned then
    -- fetched_at is in the FUTURE: the clock moved backwards since the last
    -- refresh. Flag once and revalidate — the clamped age keeps serving.
    gEntitlements.backwardsWarned = true
    log:warn("Controller clock moved backwards since the last entitlement refresh - revalidating")
    licenseEvent(
      "WARNING",
      "CONFIGURATION",
      "clock_backwards",
      "Cache fetched_at is in the future; controller clock moved backwards"
    )
  end
  local cacheDays = tonumber(cache.cache_days) or 7
  local status = fieldOrEmpty(a.status)
  local authorizedish = status == "AUTHORIZED_SUBSCRIPTION"
    or status == "AUTHORIZED_PERPETUAL"
    or status == "AUTHORIZED_GRACE"
    or status == "TRIAL"
  if age <= cacheDays * 86400 then
    answer.status = status
  elseif not authorizedish then
    -- Staleness NEVER grants what the server did not: a refusal that has aged
    -- out is still that refusal, never softened to a revalidate a caller
    -- might read as maybe-authorized.
    answer.status = status
  elseif age <= GRACE_DAYS * 86400 then
    -- Authorized but past cache: a dated grace instead of going dark.
    answer.status = "AUTHORIZED_GRACE"
    answer.grace_until = os.date("%Y-%m-%d", (tonumber(cache.fetched_at) or 0) + GRACE_DAYS * 86400)
  else
    -- Authorized but past grace too: the one case that must re-reach cloud.
    answer.status = "CLOUD_VALIDATION_REQUIRED"
  end
  return answer
end

--- #4: installed vs licensed SmartBuildOS drivers in this project. "Installed"
--- is every driver registered with this Agent; "licensed" is those whose
--- current entitlement answer is an authorized status. Best-effort display,
--- never a gate. Assigned to the forward-declared local so updateLicenseProperties
--- (defined above statusForSku) can call it.
--- @return number installed, number licensed
licensedDriverCounts = function()
  local inventory = persist:get(SBOS_DRIVERS_PERSIST, {}) or {}
  local installed, licensed = 0, 0
  for sku in pairs(inventory) do
    installed = installed + 1
    local status = statusForSku(sku).status
    if
      status == "AUTHORIZED_SUBSCRIPTION"
      or status == "AUTHORIZED_PERPETUAL"
      or status == "AUTHORIZED_GRACE"
      or status == "TRIAL"
    then
      licensed = licensed + 1
    end
  end
  return installed, licensed
end

--- Answers one entitlement question — the Phase-2 seam, now with real
--- statuses behind it. Every caller and the protocol shape are unchanged.
--- @param requester number The asking driver's device id.
--- @param sku string The driver SKU.
local function answerEntitlement(requester, sku)
  local answer = statusForSku(sku)
  SendToDevice(requester, "SBOS_ENTITLEMENT", {
    sku = sku,
    status = answer.status,
    license_type = answer.license_type,
    features = answer.features,
    company = persist:get(PROPERTY_NAME_KEY, "") or "",
    -- #3/#3a: the account the driver is licensed under, so a dependent driver
    -- can show tier + company + which company it came from without its own
    -- cloud call. #5: `registered` is the pairing fact — a paired Agent means a
    -- fully registered company. Sent as a string so it survives SendToDevice's
    -- string-typed params on-controller (the SDK reads it as "true"/"false").
    subscription_tier = persist:get(SUBSCRIPTION_TIER_KEY, "") or "",
    company_name = persist:get(COMPANY_NAME_KEY, "") or "",
    registered = isPaired() and "true" or "false",
    grace_until = answer.grace_until,
    enforcement = answer.enforcement,
    checked_at = answer.checked_at,
  })
end

--- Pushes current entitlements to every registered driver — after a refresh,
--- nobody should wait out their own daily re-ask to hear the news.
local function pushEntitlements()
  local inventory = persist:get(SBOS_DRIVERS_PERSIST, {}) or {}
  for sku, entry in pairs(inventory) do
    local device = tonumber(entry.device_id)
    if device ~= nil then
      answerEntitlement(device, sku)
    end
  end
end

--- Fetches fresh assertions from Driver Cloud and re-caches.
--- @param reason string For the log line.
function refreshEntitlements(reason)
  local url = driverCloudUrl("entitlements/refresh")
  if not url or not isPaired() or gEntitlements.inFlight then
    return
  end
  gEntitlements.inFlight = true
  gEntitlements.lastAttempt = os.time()

  local installed = {}
  local inventory = persist:get(SBOS_DRIVERS_PERSIST, {}) or {}
  for sku, entry in pairs(inventory) do
    installed[#installed + 1] = {
      sku = sku,
      version = tostring(entry.version or ""),
      device_id = tonumber(entry.device_id),
    }
  end
  installed[#installed + 1] = {
    sku = "SBOS_AGENT",
    version = tostring(C4:GetDriverConfigInfo("version")),
    device_id = C4:GetDeviceID(),
  }

  log:info("Refreshing entitlements (%s)", reason)
  http:post(url, { installed = installed }, authHeaders(), { timeout = REQUEST_TIMEOUT }):next(function(response)
    gEntitlements.inFlight = false
    local body = response.body
    if type(body) == "string" then
      local okDecode, decoded = pcall(function()
        return JSON:decode(body)
      end)
      body = okDecode and decoded or nil
    end
    if type(body) ~= "table" or type(body.assertions) ~= "table" then
      gEntitlements.lastError = "unexpected response"
      log:warn("Entitlement refresh returned an unexpected response")
      return
    end

    local secret = agentSecret()
    local assertions = {}
    -- Per-SKU enforcement policy from the server (unsigned). Whitelisted to
    -- the two known modes so a malformed value degrades to observe, never to
    -- surprise enforcement.
    local enforcement = {}
    if type(body.enforcement) == "table" then
      for sku, mode in pairs(body.enforcement) do
        enforcement[tostring(sku)] = tostring(mode) == "enforce" and "enforce" or "observe"
      end
    end
    local rejected = 0
    for _, a in ipairs(body.assertions) do
      local sku = fieldOrEmpty(a.driver_sku)
      if sku ~= "" then
        if secret == "" or verifyAssertion(a, secret) then
          assertions[sku] = a
        else
          rejected = rejected + 1
          log:error("Assertion for %s failed verification at fetch - dropped", sku)
        end
      end
    end
    if rejected > 0 then
      licenseEvent(
        "CRITICAL",
        "SECURITY",
        "assertion_verify_failed",
        string.format("%d assertion(s) failed HMAC verification at fetch", rejected)
      )
    end

    persist:set(ENTITLEMENT_CACHE_KEY, {
      fetched_at = os.time(),
      checked_at = fieldOrEmpty(body.checked_at),
      support_id = fieldOrEmpty(body.support_id),
      revalidate_hours = tonumber(body.revalidate_after_hours) or 24,
      cache_days = tonumber(body.offline_cache_days) or 7,
      verified = secret ~= "",
      assertions = assertions,
      enforcement = enforcement,
      -- Account-level display config (#3), unsigned like enforcement mode.
      subscription_in_grace = body.subscription_in_grace == true,
    }, true)
    if fieldOrEmpty(body.support_id) ~= "" then
      persist:set(SUPPORT_ID_KEY, body.support_id)
    end
    -- The tier + company the platform re-resolves each refresh. Blank means
    -- "could not confirm"; keep the last known rather than blanking a paid
    -- customer's display (mirrors the pairing path).
    if fieldOrEmpty(body.subscription_tier) ~= "" then
      persist:set(SUBSCRIPTION_TIER_KEY, body.subscription_tier)
    end
    if fieldOrEmpty(body.company_name) ~= "" then
      persist:set(COMPANY_NAME_KEY, body.company_name)
    end
    gEntitlements.lastError = ""
    gEntitlements.verifyWarned = {}
    noteClockSkew(fieldOrEmpty(body.checked_at))
    local count = 0
    for _ in pairs(assertions) do
      count = count + 1
    end
    log:info(
      "Entitlements refreshed: %d assertion(s)%s",
      count,
      secret == "" and " (unsigned - pre-Phase-5 pairing, re-pair to enable signing)" or ""
    )
    updateLicenseProperties()
    pushEntitlements()
  end, function(err)
    gEntitlements.inFlight = false
    local detail = tostring(err and (err.error or err.code) or err)
    -- An unreachable cloud is a CONNECTION condition, never a licensing
    -- one: the cache and its grace ladder carry the answers (fail-secure
    -- but an outage must never dark a home).
    if gEntitlements.lastError == "" then
      log:warn("Entitlement refresh failed (%s) - cache and grace ladder remain in effect", detail)
    end
    gEntitlements.lastError = detail
    updateLicenseProperties()
  end)
end

--- The hourly tick: refresh only once the cache is older than the server's
--- revalidate window (default 24h), so the cadence is server-tunable.
function entitlementTick()
  local cache = entitlementCache()
  if cache == nil then
    refreshEntitlements("initial validation")
    return
  end
  local age, clockAnomaly = cacheAge(cache)
  if clockAnomaly then
    refreshEntitlements("clock anomaly")
    return
  end
  local revalidateHours = tonumber(cache.revalidate_hours) or 24
  if age >= revalidateHours * 3600 then
    refreshEntitlements("revalidation window")
  end
end

--- A SmartBuildOS driver announcing itself: inventoried, then answered.
function EC.SBOS_REGISTER_DRIVER(tParams)
  tParams = tParams or {}
  local sku = tostring(tParams.sku or "")
  local requester = tonumber(tParams.requester)
  if sku == "" or requester == nil then
    return
  end
  local inventory = persist:get(SBOS_DRIVERS_PERSIST, {}) or {}
  local now = os.date("%Y-%m-%d %H:%M:%S")
  local entry = inventory[sku] or { registered_at = now }
  entry.version = tostring(tParams.version or "")
  entry.device_id = requester
  entry.last_seen = now
  inventory[sku] = entry
  persist:set(SBOS_DRIVERS_PERSIST, inventory)
  log:info("SmartBuildOS driver registered: %s %s (device %s)", sku, entry.version, requester)
  answerEntitlement(requester, sku)
  -- A sku the cache has never seen deserves a prompt cloud ask (debounced:
  -- a Director restart registers everybody at once, and one refresh serves
  -- them all).
  local cache = entitlementCache()
  if isPaired() and (cache == nil or cache.assertions[sku] == nil) and os.time() - gEntitlements.lastAttempt > 300 then
    refreshEntitlements("new driver " .. sku)
  end
end

function EC.SBOS_CHECK_ENTITLEMENT(tParams)
  tParams = tParams or {}
  local sku = tostring(tParams.sku or "")
  local requester = tonumber(tParams.requester)
  if sku == "" or requester == nil then
    return
  end
  answerEntitlement(requester, sku)
end

--- Whether a signed entitlement may receive a direct cloud-state capability.
--- The provisioning path is deliberately stricter than the driver's local
--- fail-open behavior: cloud publishing is an additive service, so LEGACY or
--- uncertain licensing never needs a credential.
local function cloudProvisioningAllowed(status)
  return status == "AUTHORIZED_SUBSCRIPTION"
    or status == "AUTHORIZED_PERPETUAL"
    or status == "AUTHORIZED_GRACE"
    or status == "TRIAL"
end

--- Exchanges the Agent's paired-controller bearer for a capability restricted
--- to one controller, one catalog SKU and the driver's current app token. The
--- dependent driver then publishes its own state over outbound HTTPS, avoiding
--- the inter-driver CreateServer path that hangs on CORE hardware.
function EC.SBOS_DRIVER_CLOUD_REQUEST(tParams)
  tParams = tParams or {}
  local sku = tostring(tParams.sku or "")
  local appToken = tostring(tParams.app_token or "")
  local requester = tonumber(tParams.requester)
  local requestId = tostring(tParams.request_id or "")
  if
    sku == ""
    or appToken == ""
    or requester == nil
    or #requestId < 8
    or #requestId > 128
    or requestId:find("^[%w%-]+$") == nil
    or not isPaired()
  then
    return
  end
  if not cloudProvisioningAllowed(statusForSku(sku).status) then
    answerEntitlement(requester, sku)
    return
  end
  if gDriverCloudProvisioning[sku] then
    return
  end
  local url = driverCloudUrl("state/provision")
  if not url then
    return
  end
  gDriverCloudProvisioning[sku] = true
  http
    :post(url, { driver_sku = sku, app_token = appToken }, authHeaders(), { timeout = REQUEST_TIMEOUT })
    :next(function(response)
      gDriverCloudProvisioning[sku] = nil
      local body = response.body
      if type(body) == "string" then
        local okDecode, decoded = pcall(function()
          return JSON:decode(body)
        end)
        body = okDecode and decoded or nil
      end
      if
        type(body) ~= "table"
        or tostring(body.driver_sku or "") ~= sku
        or tostring(body.upload_url or "") ~= tostring(driverCloudUrl("state/direct") or "")
        or tostring(body.upload_token or ""):find("^sbosdu2%.") == nil
      then
        log:warn("Driver Cloud provisioning returned an unusable response for %s", sku)
        return
      end
      SendToDevice(requester, "SBOS_DRIVER_CLOUD", {
        sku = sku,
        upload_url = tostring(body.upload_url),
        upload_token = tostring(body.upload_token),
        request_id = requestId,
      })
      log:info("Driver Cloud direct upload provisioned for %s (device %d)", sku, requester)
    end, function(err)
      gDriverCloudProvisioning[sku] = nil
      log:debug(
        "Driver Cloud provisioning failed for %s: %s",
        sku,
        tostring(type(err) == "table" and (err.error or err.code) or err)
      )
    end)
end

--- The UniFi Protect Gateway's device roster (name/MAC/state per Protect
--- device). Persisted for the platform handoff; the ingest endpoint that
--- carries it upstream is Driver Cloud Phase 3-4 — inventing a payload the
--- current telemetry route would 400 helps nobody.
--- Forwards a driver's device roster to Driver Cloud (Phase 9B). The Agent is
--- the telemetry aggregator: dependent drivers hand it their roster and it
--- relays operational metadata (id/name/model/state) to the platform. Change-
--- driven at the gateway already; here we only require a paired Agent. Fire-
--- and-forget — device telemetry must never disrupt licensing or the driver.
--- @param source string The reporting driver ("unifi-protect").
--- @param roster table Array of { kind, id, name, mac, state, model, firmware }.
--- Legacy source names, from before drivers sent their own SKU.
local ROSTER_SOURCE_SKUS = { ["unifi-protect"] = "SBOS_UNIFI_PROTECT" }

local function forwardDeviceRoster(source, roster, sku)
  local url = driverCloudUrl("devices")
  if not url or not isPaired() then
    return
  end
  sku = tostring(sku or "")
  if sku == "" then
    sku = ROSTER_SOURCE_SKUS[tostring(source or "")] or ""
  end
  -- No SKU, nowhere to file it: the platform keys devices by (controller,
  -- sku, external id), so an unattributed roster would collide with the
  -- next driver's. Refuse loudly rather than write into the wrong bucket.
  if sku == "" then
    log:warn("Device roster from '%s' carried no sku - not forwarded", tostring(source or "?"))
    return
  end
  local devices = {}
  for _, d in ipairs(roster) do
    if type(d) == "table" and d.id ~= nil then
      devices[#devices + 1] = {
        external_id = tostring(d.id),
        kind = tostring(d.kind or "unknown"),
        name = tostring(d.name or ""),
        model = tostring(d.model or ""),
        firmware = tostring(d.firmware or ""),
        mac = tostring(d.mac or ""),
        -- The gateway reports state as a Protect string; normalize the two we
        -- key on and leave the rest to the server's "unknown".
        state = (tostring(d.state or ""):upper() == "CONNECTED" or tostring(d.state or ""):lower() == "online")
            and "online"
          or (tostring(d.state or ""):upper() == "DISCONNECTED" or tostring(d.state or ""):lower() == "offline") and "offline"
          or "unknown",
      }
    end
  end
  if #devices == 0 then
    return
  end
  pcall(function()
    http
      :post(url, { driver_sku = sku, devices = devices }, authHeaders(), { timeout = REQUEST_TIMEOUT })
      :next(function()
        log:debug("Forwarded %d device(s) to Driver Cloud", #devices)
      end, function(err)
        log:debug("Device roster forward failed (non-fatal): %s", tostring(err and (err.error or err.code) or err))
      end)
  end)
end

--- Any driver's device roster. The driver names its own SKU, so fleet
--- device tracking is a platform capability rather than a Protect one.
--- tParams: sku, source (a human label), payload (JSON array of devices).
local function receiveDeviceRoster(tParams, legacySku)
  tParams = tParams or {}
  local ok, roster = pcall(function()
    return JSON:decode(tostring(tParams.payload or ""))
  end)
  if not ok or type(roster) ~= "table" then
    log:warn("Device roster carried an undecodable payload")
    return
  end
  local source = tostring(tParams.source or "")
  local sku = tostring(tParams.sku or legacySku or "")
  -- Kept per source so two drivers' rosters never overwrite each other in
  -- the support snapshot.
  local key = "sbos_roster_" .. (source ~= "" and source or sku):lower():gsub("%W", "_")
  persist:set(key, { received_at = os.date("%Y-%m-%d %H:%M:%S"), sku = sku, devices = roster })
  log:info("Device roster received from %s: %d device(s)", source ~= "" and source or sku, #roster)
  forwardDeviceRoster(source, roster, sku)
end

function EC.SBOS_DEVICE_ROSTER(tParams)
  receiveDeviceRoster(tParams)
end

--- Back-compat: the Protect gateway shipped before the generic command.
function EC.SBOS_PROTECT_ROSTER(tParams)
  tParams = tParams or {}
  -- The legacy snapshot key some support tooling reads.
  local ok, roster = pcall(function()
    return JSON:decode(tostring(tParams.payload or ""))
  end)
  if ok and type(roster) == "table" then
    persist:set("sbos_protect_roster", { received_at = os.date("%Y-%m-%d %H:%M:%S"), devices = roster })
  end
  receiveDeviceRoster(tParams, "SBOS_UNIFI_PROTECT")
end

--- The Agent-side inventory, for support calls.
function EC.PRINT_SBOS_DRIVERS()
  local inventory = persist:get(SBOS_DRIVERS_PERSIST, {}) or {}
  local count = 0
  for sku, entry in pairs(inventory) do
    count = count + 1
    log:print("  %s v%s (device %s, last seen %s)", sku, entry.version, tostring(entry.device_id), entry.last_seen)
  end
  log:print("%d SmartBuildOS driver(s) registered with this Agent", count)
end

--- Dealer-triggered refresh (Actions): the support move after a purchase,
--- a transfer, or any "why does it still say..." call.
function EC.REFRESH_ENTITLEMENTS()
  gEntitlements.lastAttempt = 0
  refreshEntitlements("dealer request")
end

--- The whole licensing picture in one print, for support calls.
function EC.PRINT_ENTITLEMENTS()
  local cache = entitlementCache()
  log:print("Support ID: %s", persist:get(SUPPORT_ID_KEY, "") or "")
  if cache == nil then
    log:print(
      "No entitlement cache - %s",
      isPaired() and "not yet validated (legacy mode)" or "not paired (legacy mode)"
    )
    return
  end
  log:print(
    "Fetched %s, revalidate %sh, cache %sd, %s",
    os.date("%Y-%m-%d %H:%M", tonumber(cache.fetched_at) or 0),
    tostring(cache.revalidate_hours),
    tostring(cache.cache_days),
    cache.verified and "signed" or "UNSIGNED (pre-Phase-5 pairing)"
  )
  for sku in pairs(cache.assertions) do
    local answer = statusForSku(sku)
    log:print(
      "  %s: %s%s%s",
      sku,
      answer.status,
      answer.license_type ~= "" and (" (" .. answer.license_type .. ")") or "",
      answer.grace_until ~= "" and (" grace until " .. answer.grace_until) or ""
    )
  end
  if gEntitlements.lastError ~= "" then
    log:print("Last refresh error: %s", gEntitlements.lastError)
  end
end
