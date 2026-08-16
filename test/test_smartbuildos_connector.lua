-- Tests for drivers/smartbuildos/driver.lua.
--
-- The driver is loaded against a fake `lib.http` and a fake Director, so every
-- assertion is about what the driver *decided to send* and what state it moved
-- to -- no network, no controller. The invariants under test are the ones a
-- controller in the field would otherwise be the first to discover:
--
--   * Pairing exchanges a single-use code for a token; the token is the only
--     thing that grants access and it must never reach the log.
--   * Device online/offline is reported as a DELTA. A 200-device project that
--     re-sent an unchanged snapshot every five minutes would be unusable.
--   * The first poll is a baseline, not 200 spurious "came online" events.
--   * Connected/Disconnected fire on a TRANSITION only. Firing per-heartbeat
--     would page a dealer every 15 minutes for one offline site.
--   * A non-2xx must surface its status code. Http:request rejects on any
--     non-2xx as well as on transport failure, so a handler that assumes
--     "rejected == unreachable" reports a revoked token as a network outage.
--
-- Run from the driver root:
--   make test
-- or:
--   LUA_PATH="$PWD/test/?.lua;$PWD/src/?.lua;$PWD/src/?/init.lua;$PWD/vendor/?.lua;$PWD/vendor/?/init.lua;;" \
--     luajit -e "require('c4_shim')" test/test_smartbuildos_connector.lua

local pass, fail = 0, 0
local function check(name, ok, detail)
  if ok then
    pass = pass + 1
    print(string.format("  ok   %s", name))
  else
    fail = fail + 1
    print(string.format("  FAIL %s%s", name, detail and ("  -> " .. tostring(detail)) or ""))
  end
end

-- ─── Fakes ────────────────────────────────────────────────────────────────────

--- Requests the driver handed to lib.http, newest last.
--- @type table[]
local requests = {}
--- Response the next request resolves/rejects with.
local nextResponse = { ok = true, code = 200 }
--- Body returned to the next pair request.
local pairBody = nil

--- Minimal stand-in for the Deferred lib.http returns. The driver only ever
--- calls `:next(onOk, onErr)` once per request and never chains, so resolving
--- synchronously is faithful enough and keeps the tests free of an event loop.
local function settled(isOk, value)
  return {
    next = function(_, onOk, onErr)
      if isOk then
        if onOk then
          onOk(value)
        end
      elseif onErr then
        onErr(value)
      end
    end,
  }
end

package.preload["lib.http"] = function()
  return {
    post = function(_, url, data, headers, options)
      table.insert(requests, { url = url, data = data, headers = headers, options = options })
      if url:find("/pair$") and pairBody ~= nil and nextResponse.ok then
        return settled(true, { url = url, code = 200, headers = {}, body = pairBody })
      end
      if nextResponse.ok then
        return settled(true, { url = url, code = nextResponse.code, headers = {}, body = "" })
      end
      return settled(false, {
        url = url,
        code = nextResponse.code,
        headers = {},
        body = nextResponse.body or "",
        error = nextResponse.error or "request failed",
      })
    end,
  }
end

--- A persistence store that lives only for the test run.
local store = {}
package.preload["lib.persist"] = function()
  return {
    get = function(_, key, default)
      local value = store[key]
      if value == nil then
        return default
      end
      return value
    end,
    set = function(_, key, value)
      store[key] = value
    end,
    delete = function(_, key)
      store[key] = nil
    end,
  }
end

--- @type string[]
local firedEvents = {}
--- @type string[]
local logLines = {}

C4 = C4 or {}

--- The project as Director reports it, in the two calls the driver actually
--- makes: GetDevices({}) for the list, GetBindingsByDevice(id) for the link.
--- Mutated by tests to model a device dropping off.
---
--- Device 99 deliberately has NO binding — an IR or serial device — and must
--- never be reported, because Director knows nothing about its reachability.
local PROJECT = {
  [63] = { deviceName = "Home Controller EA5", roomName = "Rack", driverFileName = "control4_ea5.c4z" },
  [43] = { deviceName = "8-Channel Relay", roomName = "Rack", driverFileName = "relay.c4z" },
  [75] = { deviceName = "Configurable Keypad", roomName = "Kitchen", driverFileName = "keypad.c4z" },
  [25] = { deviceName = "Leviton Dimmer", roomName = "Study", driverFileName = "dimmer.c4z" },
  [99] = { deviceName = "IR Blaster", roomName = "Media", driverFileName = "ir.c4z" },
}

local BINDINGS = {
  [63] = { networkbindingid = 6001, addr = "127.0.0.1", status = "online", addresstype = 1, deviceid = 63 },
  [43] = { networkbindingid = 6001, addr = "192.168.1.40", status = "online", addresstype = 2, deviceid = 43 },
  [75] = { networkbindingid = 6001, addr = "000fff000077f532", status = "online", addresstype = 3, deviceid = 75 },
  [25] = { networkbindingid = 6001, addr = "cd94eba9:11", status = "online", addresstype = 8, deviceid = 25 },
}

function C4:GetDevices()
  return PROJECT
end

function C4:GetBindingsByDevice(deviceId)
  return BINDINGS[deviceId]
end

local UNUSED_CONNECTIONS = {
  {
    deviceid = 63,
    name = "Home Controller EA5",
    type = 1,
    state = 1,
    address = "127.0.0.1",
    port = 5116,
    bindingid = 6001,
  },
  { deviceid = 43, name = "8-Channel Relay", type = 2, state = 1, address = "192.168.1.40", bindingid = 6001 },
  {
    deviceid = 75,
    name = "Configurable Keypad",
    type = 3,
    state = 1,
    address = "000fff000077f532",
    firmware = "4.1.22",
    bindingid = 6001,
  },
  {
    deviceid = 25,
    name = "Leviton Dimmer",
    type = 8,
    state = 1,
    network_status = "online",
    device_status = "ready",
    wake_status = "awake",
  },
}

function C4:GetNetworkConnections()
  -- Per-CALLER only, which is why the driver no longer uses it for the project.
  return UNUSED_CONNECTIONS
end

function C4:GetSystemType()
  return "XDT_EA5"
end

function C4:FireEvent(name)
  table.insert(firedEvents, name)
end

function C4:DebugLog(message)
  table.insert(logLines, tostring(message))
end

function C4:ErrorLog(message)
  table.insert(logLines, tostring(message))
end

--- Hosts the fake ping client reports as reachable.
--- @type table<string, boolean>
local PINGABLE = {}

function C4:CreatePingClient()
  local client = { _onResult = nil }
  function client:SetOnResult(callback)
    self._onResult = callback
    return self
  end
  --- Resolves synchronously. The driver must not depend on that -- it counts
  --- pending callbacks rather than assuming an order -- but it keeps the test
  --- free of a scheduler.
  function client:Ping(host)
    if self._onResult then
      self._onResult(self, PINGABLE[host] == true)
    end
    return self
  end
  return client
end

require("c4_shim")

-- ─── Load the driver ──────────────────────────────────────────────────────────

local TOKEN = "sbo_live_supersecrettoken_0123456789"
local CODE = "H7K2-9QXR"
local PROPERTY = "0f1c9a52-7d33-4f0e-9a11-2b6c8d4e5f00"

Properties = {
  ["API URL"] = "https://app.smartbuildos.io",
  ["Pairing Code"] = "",
  ["Paired Property"] = "Not paired",
  ["Connection Status"] = "Not paired",
  ["Last Successful Sync"] = "Never",
  ["Monitored Endpoints"] = "",
  ["Devices Offline"] = "0",
  ["Last Device Change"] = "",
  ["Device Poll Interval"] = "5m",
  ["Heartbeat Interval"] = "15m",
  ["Full Sync Interval"] = "24h",
  ["Automatic Updates"] = "On",
  ["Update Channel"] = "Production",
  ["Driver Status"] = "",
  ["Driver Version"] = "",
  ["Log Level"] = "3 - Info",
  ["Log Mode"] = "Off",
}

--- UpdateProperty writes back into Properties on a real controller; the shim's
--- C4:UpdateProperty is a no-op, so mirror it here or every status assertion
--- reads a stale table.
function C4:UpdateProperty(name, value)
  Properties[name] = value
end

package.path = "./drivers/smartbuildos/?.lua;" .. package.path
dofile("drivers/smartbuildos/driver.lua")

local function reset()
  requests = {}
  firedEvents = {}
  logLines = {}
  nextResponse = { ok = true, code = 200 }
  pairBody = nil
end

--- Pairs the driver by driving the real pairing path, so the token in `store`
--- got there the same way it would in the field.
local function pair()
  reset()
  gInitialized = true
  pairBody = { token = TOKEN, property_id = PROPERTY, property_name = "Kraus Residence" }
  OPC.Pairing_Code(CODE)
end

--- Finds the last request whose URL ends in `suffix`.
local function lastRequestTo(suffix)
  for i = #requests, 1, -1 do
    if requests[i].url:find(suffix .. "$") then
      return requests[i]
    end
  end
  return nil
end

-- ─── Tests ────────────────────────────────────────────────────────────────────

print("\n[1] An unpaired driver sends nothing")
reset()
gInitialized = true
EC.SEND_HEARTBEAT()
check("no request was made", #requests == 0, #requests)
check(
  "Connection Status says Not paired",
  Properties["Connection Status"] == "Not paired",
  Properties["Connection Status"]
)

print("\n[2] Pairing exchanges the code for a token")
pair()
local pairReq = lastRequestTo("/pair")
check("a pair request was made", pairReq ~= nil)
check("the code was sent", (pairReq.data or {}).code == CODE, (pairReq.data or {}).code)
check("pairing is unauthenticated", (pairReq.headers or {})["Authorization"] == nil)
check("controller identity was sent", ((pairReq.data or {}).system or {}).controller_type == "XDT_EA5")
check("the token was stored", store["device_token"] == TOKEN)
check("the property id was stored", store["property_id"] == PROPERTY)
check(
  "Paired Property shows the name",
  (Properties["Paired Property"] or ""):find("Kraus Residence", 1, true) ~= nil,
  Properties["Paired Property"]
)
check("the Paired event fired", firedEvents[1] == "Paired", table.concat(firedEvents, ","))
check("the pairing code was cleared", Properties["Pairing Code"] == "", Properties["Pairing Code"])

print("\n[3] A bad pairing code is reported as such, not as an outage")
reset()
gInitialized = true
store["device_token"], store["property_id"] = nil, nil
nextResponse = { ok = false, code = 410 }
OPC.Pairing_Code("BAD-CODE")
check(
  "status names an invalid or expired code",
  (Properties["Connection Status"] or ""):find("invalid or expired", 1, true) ~= nil,
  Properties["Connection Status"]
)
check("no token was stored", store["device_token"] == nil)

print("\n[4] A 2xx with an unusable body does not silently look like success")
reset()
gInitialized = true
pairBody = { property_id = PROPERTY } -- no token
OPC.Pairing_Code(CODE)
check(
  "status reports an unexpected response",
  (Properties["Connection Status"] or ""):find("unexpected response", 1, true) ~= nil,
  Properties["Connection Status"]
)
check("no token was stored", store["device_token"] == nil)

print("\n[5] An empty pairing code is a no-op, not a pairing attempt")
pair()
reset()
OPC.Pairing_Code("")
check("nothing was sent", #requests == 0, #requests)

print("\n[6] A heartbeat carries the bearer token and the device counts")
pair()
reset()
EC.SEND_HEARTBEAT()
local req = requests[1] or {}
check(
  "URL is the heartbeat path",
  req.url == "https://app.smartbuildos.io/api/integrations/control4/heartbeat",
  req.url
)
check("Authorization is the bearer token", (req.headers or {})["Authorization"] == "Bearer " .. TOKEN)
check("property id travels in the header", (req.headers or {})["X-SmartBuildOS-Property"] == PROPERTY)
check("device total is reported", (req.data or {}).devices_total == 4, (req.data or {}).devices_total)

print("\n[7] A trailing slash on API URL does not produce a double slash")
pair()
reset()
Properties["API URL"] = "https://app.smartbuildos.io/"
EC.SEND_HEARTBEAT()
check(
  "URL has exactly one slash before /api",
  (requests[1] or {}).url == "https://app.smartbuildos.io/api/integrations/control4/heartbeat",
  (requests[1] or {}).url
)
Properties["API URL"] = "https://app.smartbuildos.io"

print("\n[8] Full sync reports every device Director knows about")
pair()
reset()
EC.SEND_FULL_SYNC()
local sync = lastRequestTo("/devices")
local devices = ((sync or {}).data or {}).devices or {}
check("payload is a snapshot", ((sync or {}).data or {}).kind == "snapshot")
check("all four bound devices are reported", #devices == 4, #devices)
local byName = {}
for _, d in ipairs(devices) do
  byName[d.name] = d
end
check(
  "a device with no network binding is omitted",
  byName["IR Blaster"] == nil,
  "Director has no link state for IR devices; reporting one would be a guess"
)
check(
  "connection type is decoded to a label",
  (byName["Configurable Keypad"] or {}).connection_type == "zigbee",
  (byName["Configurable Keypad"] or {}).connection_type
)
check("Z-Wave dimmer is decoded", (byName["Leviton Dimmer"] or {}).connection_type == "zwave")
check("devices are marked as coming from Director", (byName["8-Channel Relay"] or {}).source == "director")

print("\n[9] The first poll is a baseline, not a flood of transitions")
pair()
reset()
gHasSnapshot = false
EC.POLL_DEVICES()
check("nothing was sent for the baseline poll", #requests == 0, #requests)
check("no device events fired", #firedEvents == 0, table.concat(firedEvents, ","))

print("\n[10] A device dropping off is reported as a delta, and only once")
pair()
reset()
EC.SEND_FULL_SYNC() -- establish the baseline
reset()
BINDINGS[43].status = "offline" -- the 8-Channel Relay drops
EC.POLL_DEVICES()
local delta = lastRequestTo("/devices")
check("payload is a delta", ((delta or {}).data or {}).kind == "delta", ((delta or {}).data or {}).kind)
check(
  "exactly one device changed",
  #(((delta or {}).data or {}).devices or {}) == 1,
  #(((delta or {}).data or {}).devices or {})
)
check(
  "the changed device is the relay",
  ((((delta or {}).data or {}).devices or {})[1] or {}).name == "8-Channel Relay"
)
check("Device Went Offline fired", firedEvents[#firedEvents] == "Device Went Offline", table.concat(firedEvents, ","))
check("Devices Offline counts one", Properties["Devices Offline"] == "1", Properties["Devices Offline"])
check(
  "Last Device Change names it",
  (Properties["Last Device Change"] or ""):find("8-Channel Relay went offline", 1, true) ~= nil,
  Properties["Last Device Change"]
)

reset()
EC.POLL_DEVICES() -- still offline
check("a still-offline device is not re-reported", #requests == 0, #requests)
check("no repeat event", #firedEvents == 0, table.concat(firedEvents, ","))

reset()
BINDINGS[43].status = "online" -- it comes back
EC.POLL_DEVICES()
check("recovery is reported", #requests == 1, #requests)
check("Device Came Online fired", firedEvents[#firedEvents] == "Device Came Online", table.concat(firedEvents, ","))
check("Devices Offline is back to zero", Properties["Devices Offline"] == "0", Properties["Devices Offline"])

print("\n[11] Non-Control4 endpoints are monitored by ping")
pair()
reset()
Properties["Monitored Endpoints"] = "Core Switch=192.168.1.2, NAS=192.168.1.10, 192.168.1.99"
PINGABLE["192.168.1.2"] = true
PINGABLE["192.168.1.10"] = true
PINGABLE["192.168.1.99"] = false
gHasSnapshot = false
EC.POLL_DEVICES() -- baseline including pings
reset()
EC.SEND_FULL_SYNC()
local all = ((lastRequestTo("/devices") or {}).data or {}).devices or {}
check("director devices and ping targets are both present", #all == 7, #all)
local pinged = {}
for _, d in ipairs(all) do
  if d.source == "ping" then
    pinged[d.name] = d
  end
end
check("three endpoints were pinged", (pinged["Core Switch"] and pinged["NAS"] and pinged["192.168.1.99"]) ~= nil)
check("a reachable endpoint is online", (pinged["Core Switch"] or {}).online == true)
check("an unreachable endpoint is offline", (pinged["192.168.1.99"] or {}).online == false)
check("a bare host is labelled with itself", (pinged["192.168.1.99"] or {}).name == "192.168.1.99")
check("ping targets are typed as icmp", (pinged["NAS"] or {}).connection_type == "icmp")

print("\n[12] A pinged endpoint going down is reported like any other device")
reset()
PINGABLE["192.168.1.2"] = false
EC.POLL_DEVICES()
local pingDelta = ((lastRequestTo("/devices") or {}).data or {}).devices or {}
check("one change reported", #pingDelta == 1, #pingDelta)
check("it is the core switch", (pingDelta[1] or {}).name == "Core Switch")
check("Device Went Offline fired", firedEvents[#firedEvents] == "Device Went Offline")
Properties["Monitored Endpoints"] = ""
PINGABLE = {}

print("\n[13] Connected/Disconnected fire on transition only")
pair()
reset()
nextResponse = { ok = false, code = 500, error = "boom" }
EC.SEND_HEARTBEAT() -- drive to disconnected
reset()
EC.SEND_HEARTBEAT()
EC.SEND_HEARTBEAT()
EC.SEND_HEARTBEAT()
check(
  "one Connected for three successes",
  #firedEvents == 1 and firedEvents[1] == "Connected",
  table.concat(firedEvents, ",")
)

reset()
nextResponse = { ok = false, code = 500, error = "boom" }
EC.SEND_HEARTBEAT()
EC.SEND_HEARTBEAT()
local disconnects = 0
for _, e in ipairs(firedEvents) do
  if e == "Disconnected" then
    disconnects = disconnects + 1
  end
end
check("exactly one Disconnected for two consecutive failures", disconnects == 1, disconnects)

print("\n[14] A non-2xx reports its status code, not 'Unreachable'")
pair()
reset()
nextResponse = { ok = false, code = 401, body = "revoked" }
EC.SEND_HEARTBEAT()
check("Connection Status is HTTP 401", Properties["Connection Status"] == "HTTP 401", Properties["Connection Status"])
check("Sync Failed fired", firedEvents[#firedEvents] == "Sync Failed", table.concat(firedEvents, ","))

reset()
nextResponse = { ok = false, code = nil, error = "dns failure" }
EC.SEND_HEARTBEAT()
check(
  "a transport failure reads as Unreachable",
  Properties["Connection Status"] == "Unreachable",
  Properties["Connection Status"]
)

print("\n[15] Unpair forgets the token even if the notice fails")
pair()
reset()
nextResponse = { ok = false, code = 500 }
EC.UNPAIR()
check("the token is gone", store["device_token"] == nil)
check("the property id is gone", store["property_id"] == nil)
check("Paired Property resets", Properties["Paired Property"] == "Not paired", Properties["Paired Property"])
check("status is Not paired", Properties["Connection Status"] == "Not paired", Properties["Connection Status"])

print("\n[16] The conditionals track connection and pairing state")
pair()
reset()
EC.SEND_HEARTBEAT()
check("connected conditional is true", TC.SMARTBUILDOS_CONNECTED() == true)
check("paired conditional is true", TC.SMARTBUILDOS_PAIRED() == true)
nextResponse = { ok = false, code = 503 }
EC.SEND_HEARTBEAT()
check("connected conditional is false once disconnected", TC.SMARTBUILDOS_CONNECTED() == false)
EC.UNPAIR()
check("paired conditional is false once unpaired", TC.SMARTBUILDOS_PAIRED() == false)

print("\n[17] SEND_EVENT requires a name")
pair()
reset()
EC.SEND_EVENT({ NAME = "", DETAIL = "ignored" })
check("an unnamed event sends nothing", #requests == 0, #requests)
EC.SEND_EVENT({ NAME = "Rack Door Opened", DETAIL = "north rack" })
check(
  "a named event posts to the event path",
  (requests[1] or {}).url:find("/control4/event$") ~= nil,
  (requests[1] or {}).url
)
check("event name is in the payload", ((requests[1] or {}).data or {}).name == "Rack Door Opened")

print("\n[18] Neither the token nor the pairing code reaches the log")
reset()
gInitialized = true
Properties["Log Mode"] = "Print and Log"
Properties["Log Level"] = "6 - Ultra"
OnPropertyChanged("Log Mode")
OnPropertyChanged("Log Level")
pairBody = { token = TOKEN, property_id = PROPERTY, property_name = "Kraus Residence" }
OPC.Pairing_Code(CODE)
EC.SEND_HEARTBEAT()
EC.SEND_FULL_SYNC()
local leakedToken, leakedCode = false, false
for _, line in ipairs(logLines) do
  if line:find(TOKEN, 1, true) then
    leakedToken = true
  end
  if line:find(CODE, 1, true) then
    leakedCode = true
  end
end
check("no log line contains the token", not leakedToken, "token appeared in " .. #logLines .. " log lines")
check("no log line contains the pairing code", not leakedCode, "code appeared in " .. #logLines .. " log lines")
Properties["Log Mode"] = "Off"

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
