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
--#ifndef DRIVERCENTRAL
local githubUpdater = require("lib.github-updater")
--#endif

--- Heartbeat/inventory interval labels mapped to seconds.
--- @type table<string, number>
local INTERVALS = {
  ["5m"] = 5 * 60,
  ["15m"] = 15 * 60,
  ["30m"] = 30 * 60,
  ["1h"] = 60 * 60,
  ["6h"] = 6 * 60 * 60,
  ["12h"] = 12 * 60 * 60,
  ["24h"] = 24 * 60 * 60,
}

local HEARTBEAT_TIMER = "SmartBuildOSHeartbeat"
local INVENTORY_TIMER = "SmartBuildOSInventory"

--- Requests are given a generous ceiling: a controller on a saturated uplink
--- should retry on the next tick rather than pile up in-flight posts.
local REQUEST_TIMEOUT = 30

--- @type boolean Whether the last delivery attempt succeeded.
local gConnected = false
--- @type number Consecutive failed deliveries, reset on success.
local gFailures = 0

--- Builds the SmartBuildOS ingest URL for a given path.
--- Trailing slashes on the configured base URL are tolerated so a dealer
--- pasting "https://app.smartbuildos.com/" does not silently produce "//api".
--- @param path string Path beneath the ingest root, with no leading slash.
--- @return string|nil url The absolute URL, or nil if the driver is unconfigured.
local function ingestUrl(path)
  local base = Properties["API URL"] or ""
  base = base:gsub("%s+", ""):gsub("/+$", "")
  if base == "" then
    return nil
  end
  return string.format("%s/api/integrations/control4/%s", base, path)
end

--- Returns the auth headers for an ingest request.
--- @return table<string, string> headers
local function authHeaders()
  return {
    ["Authorization"] = "Bearer " .. (Properties["Device Token"] or ""),
    ["Content-Type"] = "application/json",
    ["X-SmartBuildOS-Property"] = Properties["Property ID"] or "",
  }
end

--- Reports whether the driver has everything it needs to talk to SmartBuildOS.
--- @return boolean configured
--- @return string|nil reason Human-readable reason when not configured.
local function isConfigured()
  if (Properties["API URL"] or "") == "" then
    return false, "API URL is not set"
  end
  if (Properties["Device Token"] or "") == "" then
    return false, "Device Token is not set"
  end
  if (Properties["Property ID"] or "") == "" then
    return false, "Property ID is not set"
  end
  return true, nil
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

--- Collects the controller-level facts sent with every payload.
--- @return table<string, any> identity
local function systemIdentity()
  return {
    property_id = Properties["Property ID"],
    controller_type = C4:GetSystemType(),
    os_version = C4:GetVersionInfo().version,
    driver_version = C4:GetDriverConfigInfo("version"),
    device_id = C4:GetDeviceID(),
    director_name = C4:GetDeviceData(C4:GetDeviceID(), "name"),
  }
end

--- Posts a payload to SmartBuildOS and reconciles connection state.
--- @param path string Ingest path beneath the integration root.
--- @param payload table<string, any> Body to send, merged with the identity block.
--- @param description string Label used in log lines.
local function send(path, payload, description)
  local configured, reason = isConfigured()
  if not configured then
    log:warn("Not sending %s: %s", description, reason)
    setConnected(false, "Not configured - " .. reason)
    return
  end

  local url = ingestUrl(path)
  if not url then
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

--- Sends a heartbeat: proof of life plus a small health summary.
local function sendHeartbeat()
  send("heartbeat", {
    kind = "heartbeat",
    consecutive_failures = gFailures,
  }, "heartbeat")
end

--- Sends the full project device inventory.
--- `C4:GetProjectItems` is explicitly documented as unsafe during
--- OnDriverInit, so this is only ever reached from a timer or an action.
local function sendInventory()
  if Properties["Report Device Inventory"] ~= "On" then
    log:debug("Device inventory reporting is off; sending identity only")
    send("inventory", { kind = "inventory", devices = {} }, "inventory")
    return
  end

  local devices = {}
  for id, device in pairs(C4:GetDevices({}) or {}) do
    table.insert(devices, {
      id = tointeger(id),
      name = device.name,
      model = device.model,
      manufacturer = device.manufacturer,
      driver = device.filename,
    })
  end

  log:info("Sending inventory of %d device(s)", #devices)
  send("inventory", { kind = "inventory", devices = devices }, "inventory")
end

--- (Re)arms the heartbeat and inventory timers from the current properties.
local function scheduleTimers()
  CancelTimer(HEARTBEAT_TIMER)
  CancelTimer(INVENTORY_TIMER)

  local heartbeat = INTERVALS[Properties["Heartbeat Interval"] or ""] or INTERVALS["15m"]
  local inventory = INTERVALS[Properties["Inventory Interval"] or ""] or INTERVALS["24h"]

  SetTimer(HEARTBEAT_TIMER, heartbeat * ONE_SECOND, sendHeartbeat, true)
  SetTimer(INVENTORY_TIMER, inventory * ONE_SECOND, sendInventory, true)
  log:debug("Timers armed: heartbeat %ds, inventory %ds", heartbeat, inventory)
end

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

  local configured, reason = isConfigured()
  if not configured then
    setConnected(false, "Not configured - " .. reason)
    log:warn("SmartBuildOS Connector is not configured: %s", reason)
    return
  end

  --#ifndef DRIVERCENTRAL
  SetTimer("UpdateCheck", 30 * 60 * ONE_SECOND, function()
    if toboolean(Properties["Automatic Updates"]) then
      log:info("Checking for driver update")
      UpdateDrivers()
    end
  end, true)
  --#endif

  scheduleTimers()
  -- Report in immediately so a freshly added driver shows up in SmartBuildOS
  -- without waiting out a full heartbeat interval.
  sendHeartbeat()
  sendInventory()
end

function OnDriverDestroyed()
  log:trace("OnDriverDestroyed()")
  CancelTimer(HEARTBEAT_TIMER)
  CancelTimer(INVENTORY_TIMER)
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

--- Re-validates and re-arms whenever a connection property changes, so a dealer
--- correcting a typo gets feedback without reloading the driver.
local function onConnectionPropertyChanged()
  if not gInitialized then
    return
  end
  local configured, reason = isConfigured()
  if not configured then
    CancelTimer(HEARTBEAT_TIMER)
    CancelTimer(INVENTORY_TIMER)
    setConnected(false, "Not configured - " .. reason)
    return
  end
  scheduleTimers()
  sendHeartbeat()
end

function OPC.API_URL(propertyValue)
  log:trace("OPC.API_URL('%s')", propertyValue)
  onConnectionPropertyChanged()
end

function OPC.Device_Token(propertyValue)
  -- Deliberately not logged, even at trace: this is a bearer credential.
  log:trace("OPC.Device_Token(<redacted>)")
  onConnectionPropertyChanged()
end

function OPC.Property_ID(propertyValue)
  log:trace("OPC.Property_ID('%s')", propertyValue)
  onConnectionPropertyChanged()
end

function OPC.Heartbeat_Interval(propertyValue)
  log:trace("OPC.Heartbeat_Interval('%s')", propertyValue)
  if gInitialized and select(1, isConfigured()) then
    scheduleTimers()
  end
end

function OPC.Inventory_Interval(propertyValue)
  log:trace("OPC.Inventory_Interval('%s')", propertyValue)
  if gInitialized and select(1, isConfigured()) then
    scheduleTimers()
  end
end

function OPC.Report_Device_Inventory(propertyValue)
  log:trace("OPC.Report_Device_Inventory('%s')", propertyValue)
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
  local configured, reason = isConfigured()
  if not configured then
    log:error("Cannot test connection: %s", reason)
    setConnected(false, "Not configured - " .. reason)
    return
  end
  send("heartbeat", { kind = "test" }, "connection test")
end

function EC.SEND_HEARTBEAT()
  log:trace("EC.SEND_HEARTBEAT()")
  sendHeartbeat()
end

function EC.SEND_INVENTORY()
  log:trace("EC.SEND_INVENTORY()")
  sendInventory()
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
