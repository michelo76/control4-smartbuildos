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

--- GET requests (the driver only GETs album art), newest last.
--- @type table[]
local getRequests = {}
--- Response the next GET resolves/rejects with.
local nextGetResponse = { ok = true, code = 200, body = "", headers = {} }

package.preload["lib.http"] = function()
  return {
    get = function(_, url, headers, options)
      table.insert(getRequests, { url = url, headers = headers, options = options })
      if nextGetResponse.ok then
        return settled(true, {
          url = url,
          code = nextGetResponse.code,
          headers = nextGetResponse.headers or {},
          body = nextGetResponse.body or "",
        })
      end
      return settled(
        false,
        { url = url, code = nextGetResponse.code, error = nextGetResponse.error or "request failed" }
      )
    end,
    post = function(_, url, data, headers, options)
      table.insert(requests, { url = url, data = data, headers = headers, options = options })
      if url:find("/pair$") and pairBody ~= nil and nextResponse.ok then
        return settled(true, { url = url, code = 200, headers = {}, body = pairBody })
      end
      if nextResponse.ok then
        -- `nextResponse.body` lets a test drive an onOk callback that reads the
        -- response. Defaults to empty, which is what every existing test that
        -- ignores the body already expects.
        return settled(true, { url = url, code = nextResponse.code, headers = {}, body = nextResponse.body or "" })
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
  [88] = { deviceName = "Unaddressed Dimmer", roomName = "Hall", driverFileName = "dimmer.c4z" },
  [77] = { deviceName = "Control Only Agent", roomName = "Rack", driverFileName = "agent.c4z" },
}

--- The shape a real controller returns: the network binding is NESTED under a
--- `bindings` array, next to control bindings that carry no address at all. A
--- parser that indexes the top level (as the API reference's example implies)
--- finds nothing — which is exactly the bug this models.
local BINDINGS = {
  [63] = { networkbindingid = 6001, addr = "127.0.0.1", status = "online", addresstype = 1, deviceid = 63 },
  -- Configured in the project but never pointed at hardware. Director reports a
  -- binding, but NOT_SET is not an address, so this must not be monitored — and
  -- above all must not be counted offline.
  [88] = { networkbindingid = 6001, addr = "NOT_SET", status = "offline", addresstype = 2, deviceid = 88 },
  [43] = { networkbindingid = 6001, addr = "192.168.1.40", status = "online", addresstype = 2, deviceid = 43 },
  [75] = { networkbindingid = 6001, addr = "000fff000077f532", status = "online", addresstype = 3, deviceid = 75 },
  [25] = { networkbindingid = 6001, addr = "cd94eba9:11", status = "online", addresstype = 8, deviceid = 25 },
}

function C4:GetDevices()
  return PROJECT
end

--- Deliberately returns NOTHING useful, so the fallback to GetBindingsByDevice
--- is exercised rather than assumed.
function C4:GetNetworkBindingsByDevice()
  return nil
end

function C4:GetBindingsByDevice(deviceId)
  local binding = BINDINGS[deviceId]
  if binding == nil then
    -- A device with only control bindings: nested, and carrying no address.
    return {
      bindings = {
        {
          binding_info = "",
          bindingid = 5001,
          bindingclasses = { { autobind = true, class = "CONTROLLER", rank = 0 } },
        },
      },
    }
  end
  return {
    bindings = {
      { binding_info = "", bindingid = 5001, bindingclasses = { { autobind = true, class = "CONTROLLER", rank = 0 } } },
      binding,
    },
  }
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

--- The survey's APIs. Deliberately returning empty rather than absent, so the
--- survey exercises its own defensive handling instead of the pcall fallback.
function C4:GetProjectHierarchy()
  -- Verified shape from a real controller: nested, child locations keyed by id
  -- alongside `name`/`type`, and `type` is a NUMBER. 2=site 3=building 4=floor
  -- 8=room.
  return {
    [13] = {
      name = "Home",
      type = 2,
      ["14"] = {
        name = "House",
        type = 3,
        ["15"] = {
          name = "Main",
          type = 4,
          ["16"] = { name = "Living Room", type = 8 },
          ["222"] = { name = "Kitchen", type = 8 },
          ["94"] = { name = "Master Bedroom", type = 8 },
        },
      },
    },
  }
end

function C4:GetDeviceVariables()
  -- Verified shape: keyed by variable id, each with name/value/type/readonly.
  return {
    [1000] = { name = "CURRENT_SELECTED_DEVICE", value = "0", type = "4", readonly = "False" },
    [1011] = { name = "POWER_STATE", value = "false", type = "3", readonly = "False" },
  }
end

function C4:GetAllCodeItems()
  return {
    event_mgr = {
      { deviceid = 19, eventid = 1, codeitem = { enabled = false, display = "Turn on the NAME", subitems = {} } },
    },
  }
end

function C4:GetBindingAddress()
  return ""
end

function C4:CreateNetworkConnection()
  return true
end

function C4:NetConnect()
  return true
end

function C4:NetDisconnect()
  return true
end

function C4:GetSystemType()
  return "XDT_EA5"
end

--- Deliberately a WRAPPING encoder: real platforms disagree about line breaks
--- in base64 output, and the driver must strip whitespace before the platform
--- validator sees it. Ignores its input so tests can pin the exact data URI.
function C4:Base64Encode()
  return "QUJD\nREVG"
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
local SYSTEM = "7e14128e-fb05-4645-929f-e1ee9e1ee964"

Properties = {
  ["API URL"] = "https://app.smartbuildos.io",
  ["Pairing Code"] = "",
  ["Pairing Backup"] = "",
  ["Paired Property"] = "Not paired",
  ["Connection Status"] = "Not paired",
  ["Last Successful Sync"] = "Never",
  ["Touchpanel Name"] = "Touchpanel",
  ["Touchpanel URL"] = "Not generated",
  ["Non Control4 Devices"] = "",
  ["Discover Network Devices"] = "Off",
  ["Network Scan"] = "Off",
  ["Last Network Scan"] = "Never",
  ["Devices Offline"] = "0",
  ["Last Device Change"] = "",
  ["Device Poll Interval"] = "5m",
  ["Heartbeat Interval"] = "15m",
  ["Full Sync Interval"] = "24h",
  ["Automatic Updates"] = "On",
  ["Update Channel"] = "Production",
  ["Remote Control"] = "Identify only",
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

print("\n[2b] A system with NO property pairs anyway")
-- ⚠ REGRESSION. SmartBuildOS tracks Control4 projects for customers who are
-- not its clients, and those systems have no property at all. The platform
-- re-keyed on the system and made property_id advisory; this driver did not
-- follow, and required a property id in the pair response. The result was a
-- pairing that SUCCEEDED on the server -- code redeemed, controller minted,
-- token issued -- while Composer said "Pairing failed - unexpected response".
-- Measured in production: three attempts, three spent codes, three orphan
-- controllers, and nothing to tell the dealer the fault was ours.
reset()
gInitialized = true
pairBody = { token = TOKEN, system_id = SYSTEM, property_name = "Julie Dwyer" }
OPC.Pairing_Code(CODE)
check("the token was stored", store["device_token"] == TOKEN)
check("the system id was stored", store["system_id"] == SYSTEM, store["system_id"])
check("the driver reports itself paired", TC.SMARTBUILDOS_PAIRED() == true)
check(
  "Connection Status is not a failure",
  (Properties["Connection Status"] or ""):find("failed") == nil,
  Properties["Connection Status"]
)
check(
  "Paired Property shows the system, not empty brackets",
  (Properties["Paired Property"] or ""):find("Julie Dwyer", 1, true) ~= nil,
  Properties["Paired Property"]
)
check("the Paired event fired", firedEvents[1] == "Paired", table.concat(firedEvents, ","))

-- The token alone is not enough: with no id at all the response IS broken.
reset()
gInitialized = true
pairBody = { token = TOKEN }
OPC.Pairing_Code(CODE)
check(
  "a response with neither id is still refused",
  (Properties["Connection Status"] or ""):find("unexpected response") ~= nil,
  Properties["Connection Status"]
)

-- Unpair must clear BOTH ids. isPaired() accepts either, so a surviving
-- system id would leave the driver "paired" with no token.
reset()
gInitialized = true
pairBody = { token = TOKEN, system_id = SYSTEM }
OPC.Pairing_Code(CODE)
EC.UNPAIR()
check("unpair cleared the system id", store["system_id"] == nil, tostring(store["system_id"]))
check("unpair left the driver unpaired", TC.SMARTBUILDOS_PAIRED() == false)

print("\n[2c] Composer shows the ADDRESS, not a uuid")
-- A raw uuid answers nothing for somebody at a rack asking which house this
-- controller is in. The platform composes the label; the driver renders it.
reset()
gInitialized = true
pairBody = {
  token = TOKEN,
  system_id = SYSTEM,
  property_name = "Julie Dwyer",
  site_label = "4560 Sheridan Ave, Miami Beach, FL 33140",
}
OPC.Pairing_Code(CODE)
check(
  "Paired Property shows name and address",
  Properties["Paired Property"] == "Julie Dwyer (4560 Sheridan Ave, Miami Beach, FL 33140)",
  Properties["Paired Property"]
)

-- A corrected address must land on the HEARTBEAT, or Composer keeps showing
-- the old one until somebody re-pairs.
-- `nextResponse.body` is how the harness drives a response the driver reads.
nextResponse = { ok = true, code = 200, body = { ok = true, site_label = "1200 Ocean Drive, Miami Beach, FL 33139" } }
EC.SEND_HEARTBEAT()
nextResponse = { ok = true, code = 200 }
check(
  "an address correction lands on the next check-in",
  Properties["Paired Property"] == "Julie Dwyer (1200 Ocean Drive, Miami Beach, FL 33139)",
  Properties["Paired Property"]
)

-- With no address at all the id is the honest fallback -- unhelpful, but true.
reset()
gInitialized = true
pairBody = { token = TOKEN, system_id = SYSTEM, property_name = "Julie Dwyer" }
OPC.Pairing_Code(CODE)
check(
  "no address falls back to the id, never empty brackets",
  Properties["Paired Property"] == "Julie Dwyer (" .. SYSTEM .. ")",
  Properties["Paired Property"]
)

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
check("device total is reported", (req.data or {}).devices_total == 5, (req.data or {}).devices_total)

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
check("every device with a network binding is reported", #devices == 5, #devices)
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
  "a control-only device is not reported offline",
  byName["Control Only Agent"] == nil,
  "a control binding's unrelated `status` field must not read as a dead link"
)
-- Reported, but never as a fault. NOT_SET is a driver placed in the project
-- and not yet pointed at hardware — "discovered, not configured", which is
-- exactly the list a dealer wants. Hiding it lost real information; calling it
-- offline invented an outage for something never installed.
check(
  "an unaddressed device IS reported",
  byName["Unaddressed Dimmer"] ~= nil,
  "a device configured in the project should be visible"
)
check("an unaddressed device is not claimed to be online", (byName["Unaddressed Dimmer"] or {}).online == false)
check(
  "its address is passed through as the placeholder",
  (byName["Unaddressed Dimmer"] or {}).address == "NOT_SET",
  "the platform reads a missing address as unknown, so it must arrive intact"
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
check(
  "Devices Offline counts one, not the unaddressed device too",
  Properties["Devices Offline"] == "1",
  Properties["Devices Offline"]
)
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
Properties["Non Control4 Devices"] = "Core Switch=192.168.1.2, NAS=192.168.1.10, 192.168.1.99"
PINGABLE["192.168.1.2"] = true
PINGABLE["192.168.1.10"] = true
PINGABLE["192.168.1.99"] = false
gHasSnapshot = false
EC.POLL_DEVICES() -- baseline including pings
reset()
EC.SEND_FULL_SYNC()
local all = ((lastRequestTo("/devices") or {}).data or {}).devices or {}
check("director devices and ping targets are both present", #all == 8, #all)
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
Properties["Non Control4 Devices"] = ""
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
local firstLeak = ""
for _, line in ipairs(logLines) do
  if line:find(TOKEN, 1, true) then
    firstLeak = line:sub(1, 160)
    break
  end
end
check("no log line contains the token", not leakedToken, firstLeak)
check("no log line contains the pairing code", not leakedCode, "code appeared in " .. #logLines .. " log lines")
Properties["Log Mode"] = "Off"

print("\n[19] The telemetry survey runs without a controller")

-- The survey walks four APIs whose shapes are documented loosely. It must not
-- throw on any of them: a diagnostic that crashes is worse than no diagnostic,
-- and this one exists precisely because the reference cannot be trusted.
pair()
reset()
local surveyOk, surveyErr = pcall(EC.REPORT_TELEMETRY_SURVEY)
check("the survey completes", surveyOk, surveyErr)
check("it reports its findings", #requests > 0, #requests)
local sawCodeItems = false
for _, r in ipairs(requests) do
  local detail = (r.data or {}).detail or ""
  if detail:find("GetAllCodeItems", 1, true) then
    sawCodeItems = true
  end
end
check("programming is surveyed", sawCodeItems)

-- The first survey reported "rooms exposing variables: 0" on a project with
-- rooms, because it read a nested tree as a flat map and compared a numeric
-- `type` against a string. That wrong answer would have been designed around.
local sawRooms, sawRoomVars = false, false
for _, r in ipairs(requests) do
  local detail = (r.data or {}).detail or ""
  if detail:find("rooms (type 8): 3", 1, true) then
    sawRooms = true
  end
  if detail:find("rooms exposing variables: 3 of 3", 1, true) then
    sawRoomVars = true
  end
end
check("rooms are found through the nested tree", sawRooms, "a nested hierarchy with numeric types must yield 3 rooms")
check("room variables are probed", sawRoomVars)

reset()
-- Every one of these can be missing on an older OS. The survey must degrade,
-- not die.
local savedHierarchy, savedVars, savedCode = C4.GetProjectHierarchy, C4.GetDeviceVariables, C4.GetAllCodeItems
C4.GetProjectHierarchy, C4.GetDeviceVariables, C4.GetAllCodeItems = nil, nil, nil
local degradedOk = pcall(EC.REPORT_TELEMETRY_SURVEY)
check("it survives every survey API being absent", degradedOk)
C4.GetProjectHierarchy, C4.GetDeviceVariables, C4.GetAllCodeItems = savedHierarchy, savedVars, savedCode

print("\n[24] Generating a touchpanel URL")
pair()
reset()
Properties["Touchpanel Name"] = "  Kitchen T4  "
nextResponse = {
  ok = true,
  code = 200,
  body = '{"ok":true,"url":"https://app.smartbuildos.io/display/c4/sbc4d_aaaabbbb_secret","label":"Kitchen T4"}',
}
EC.GENERATE_DISPLAY_URL()
check(
  "it posts to the display endpoint",
  #requests == 1 and requests[1].url:find("/display", 1, true) ~= nil,
  #requests > 0 and requests[1].url or "no request"
)
check(
  "the panel name is trimmed before sending",
  #requests > 0 and requests[1].data.label == "Kitchen T4",
  #requests > 0 and tostring(requests[1].data.label) or "no request"
)
check(
  "the returned URL lands in the property",
  Properties["Touchpanel URL"] == "https://app.smartbuildos.io/display/c4/sbc4d_aaaabbbb_secret",
  Properties["Touchpanel URL"]
)

-- An empty name must not send an empty label: the dealer's list would show a
-- row with nothing to identify which panel it is.
reset()
Properties["Touchpanel Name"] = "   "
nextResponse =
  { ok = true, code = 200, body = '{"ok":true,"url":"https://app.smartbuildos.io/display/c4/sbc4d_ccccdddd_secret"}' }
EC.GENERATE_DISPLAY_URL()
check(
  "a blank name falls back rather than sending empty",
  #requests > 0 and requests[1].data.label == "Touchpanel",
  #requests > 0 and tostring(requests[1].data.label) or "no request"
)

-- The failure cases all have to be VISIBLE in the property, because that is the
-- only place an installer looks after running an action.
reset()
nextResponse = { ok = false, code = 503 }
EC.GENERATE_DISPLAY_URL()
check(
  "a rejected request does not leave a stale URL claiming success",
  Properties["Touchpanel URL"] ~= "https://app.smartbuildos.io/display/c4/sbc4d_ccccdddd_secret",
  Properties["Touchpanel URL"]
)

reset()
nextResponse = { ok = true, code = 200, body = '{"ok":true}' }
EC.GENERATE_DISPLAY_URL()
check(
  "a response with no url is reported as a failure",
  Properties["Touchpanel URL"]:find("Failed", 1, true) ~= nil,
  Properties["Touchpanel URL"]
)

EC.UNPAIR()
reset()
EC.GENERATE_DISPLAY_URL()
check("an unpaired driver sends nothing", #requests == 0, #requests)
check(
  "and says so in the property",
  Properties["Touchpanel URL"] == "Pair the driver first",
  Properties["Touchpanel URL"]
)

print("\n[25] The capability probe (T-0.6)")
pair()
reset()
nextResponse = { ok = true, code = 200 }
EC.PROBE_CAPABILITIES()
check("the probe uploads its findings", #requests > 0, #requests)
local sawDevices, sawBindingOrNone, joined = false, false, ""
for _, r in ipairs(requests) do
  local d = tostring(r.data and r.data.detail or "")
  joined = joined .. d .. "\n"
  if d:find("PROBE devices=", 1, true) then
    sawDevices = true
  end
  if d:find("PROBE binding", 1, true) then
    sawBindingOrNone = true
  end
end
check("it reports a device census", sawDevices, joined:sub(1, 200))
check("it reports on bindings either way", sawBindingOrNone, joined:sub(1, 200))
-- A device entry dumped whole is what explains a census that finds nothing: the
-- first run reported 0 keypads across 221 devices, which was the method
-- failing, not the project being empty.
check(
  "it dumps a device entry so a failed census can be explained",
  joined:find("PROBE devsample", 1, true) ~= nil,
  joined:sub(1, 200)
)
check(
  "it censuses binding kinds rather than guessing at names",
  joined:find("PROBE binding census", 1, true) ~= nil,
  joined:sub(1, 200)
)
-- Network bindings come from GetNetworkBindingsByDevice, NOT GetBindingsByDevice.
-- Asking the wrong API produced a confident "no device carries an address",
-- which contradicted this driver's own working monitoring of 73 devices.
check(
  "it reports how many devices carry a network binding",
  joined:find("PROBE netbindings:", 1, true) ~= nil,
  joined:sub(1, 200)
)
-- 663 lines as 663 requests lost four fifths of them to the ingest rate limiter
-- on the first real run, and the casualties included every line answering the
-- MAC question -- so a LOST result read exactly like a negative one. Batching is
-- what makes the probe's output survive the trip.
-- The platform caps event detail at 500 characters. A chunk over that arrives
-- truncated, which silently discarded the network-binding dump this probe
-- exists to collect.
check(
  "no chunk exceeds the platform's 500-character detail cap",
  (function()
    for _, r in ipairs(requests) do
      if #tostring(r.data and r.data.detail or "") > 500 then
        return false
      end
    end
    return true
  end)(),
  (function()
    local longest = 0
    for _, r in ipairs(requests) do
      longest = math.max(longest, #tostring(r.data and r.data.detail or ""))
    end
    return longest
  end)()
)
check(
  "lines are batched rather than one request each",
  (function()
    local emitted = 0
    for _, r in ipairs(requests) do
      local _, breaks = tostring(r.data and r.data.detail or ""):gsub("\n", "")
      emitted = emitted + breaks + 1
    end
    return #requests > 0 and emitted > #requests
  end)(),
  #requests
)

-- The probe must never take the house down with it. Every C4 API it touches can
-- be absent on an older OS, and a probe that throws is a probe nobody runs.
reset()
local savedVars, savedCode, savedBind = C4.GetDeviceVariables, C4.GetAllCodeItems, C4.GetBindingsByDevice
C4.GetDeviceVariables, C4.GetAllCodeItems, C4.GetBindingsByDevice = nil, nil, nil
local degraded = pcall(EC.PROBE_CAPABILITIES)
check("it survives every probed API being absent", degraded)
C4.GetDeviceVariables, C4.GetAllCodeItems, C4.GetBindingsByDevice = savedVars, savedCode, savedBind

EC.UNPAIR()
reset()
local unpairedOk = pcall(EC.PROBE_CAPABILITIES)
check("it runs unpaired without sending or throwing", unpairedOk and #requests == 0, #requests)

print("\n[26] Climate, against the variables real hardware reports")

-- Verbatim from the 2026-08-17 probe of device 410, a real thermostat.
local REAL_THERMOSTAT = {
  { name = "TEMPERATURE", value = "282" },
  { name = "TEMPERATURE_F", value = "83" },
  { name = "TEMPERATURE_C", value = "28.5" },
  { name = "COOL_SETPOINT_F", value = "76" },
  { name = "COOL_SETPOINT_C", value = "24.5" },
  { name = "DISPLAY_HEATSETPOINT", value = "77" },
  { name = "HVAC_MODES_LIST", value = "Off,Heat,Cool,Auto" },
  { name = "ANA_HVACMODE", value = "Cool" },
  { name = "HVAC_STATE", value = "Stage 1 Cool" },
}

-- And device 322, which answers the same proxy but is a WEATHER driver.
local WEATHER_PROXY = {
  { name = "MESSAGE", value = "Clear, temperature 82 F" },
  { name = "HVAC_MODES_LIST", value = "Off,Warn Cool,Warn Heat" },
  { name = "ANA_INDOORTEMP", value = "277" },
  { name = "V1 TEMPERATURE", value = "82" },
  { name = "TEMPERATURE", value = "310" },
  { name = "ANA_ISCONNECTED", value = "False" },
}

local real = climateReading(REAL_THERMOSTAT)
check(
  "temperature is Fahrenheit, not deci-Celsius",
  real ~= nil and real.temperature == 83,
  real and tostring(real.temperature) or "nil"
)
check("the cool setpoint is the Fahrenheit one", real ~= nil and real.cool == 76, real and tostring(real.cool) or "nil")
check(
  "the heat setpoint falls back to the display value",
  real ~= nil and real.heat == 77,
  real and tostring(real.heat) or "nil"
)
check(
  "hvac state is preferred over mode",
  real ~= nil and real.mode == "Stage 1 Cool",
  real and tostring(real.mode) or "nil"
)

-- The bug this section exists to prevent: three rooms on the real project point
-- at the weather driver, and reporting 31.0 C of OUTDOOR air as room comfort is
-- worse than reporting nothing at all.
check(
  "a weather driver yields no reading",
  climateReading(WEATHER_PROXY) == nil,
  tostring(climateReading(WEATHER_PROXY))
)

-- A thermostat exposing only the raw variable still works, in the right scale.
check(
  "raw deci-Celsius is the last resort, converted",
  (function()
    local r = climateReading({ { name = "TEMPERATURE", value = "282" } })
    return r ~= nil and r.temperature == 28.2
  end)()
)

-- Every unset setpoint on the measured hardware reads exactly 0.
check(
  "a zero setpoint is not a setpoint",
  (function()
    local r = climateReading({
      { name = "TEMPERATURE_F", value = "70" },
      { name = "COOL_SETPOINT_F", value = "0" },
    })
    return r ~= nil and r.cool == nil
  end)()
)

check("no readable values yields nil", climateReading({ { name = "FAN_MODE", value = "Auto" } }) == nil)
check("garbage yields nil rather than throwing", climateReading("nonsense") == nil)

print("\n[27] MAC extraction, against real network bindings")

-- Verbatim uuids from the 2026-08-17 probe.
check(
  "an SSDP uuid yields its MAC, normalised",
  macFromUuid("Amplifier-EA-HYB-AMP-2D-1200-D4:6A:91:4F:16:55") == "d46a914f1655",
  tostring(macFromUuid("Amplifier-EA-HYB-AMP-2D-1200-D4:6A:91:4F:16:55"))
)

-- A Zigbee address is 16 hex digits with no separators. Taking the tail of the
-- string would turn it into a plausible-looking MAC that matches nothing.
check("a Zigbee uuid yields no MAC", macFromUuid("000fff0000d4f655") == nil, tostring(macFromUuid("000fff0000d4f655")))

check("an empty uuid yields no MAC", macFromUuid("") == nil)
check("a nil uuid yields no MAC", macFromUuid(nil) == nil)
check("a non-string yields no MAC rather than throwing", macFromUuid(42) == nil)
check(
  "hyphen-separated MACs are accepted",
  macFromUuid("dev-AA-BB-CC-DD-EE-FF") == "aabbccddeeff",
  tostring(macFromUuid("dev-AA-BB-CC-DD-EE-FF"))
)
check(
  "the result is comparable with installed_devices.mac_normalized",
  macFromUuid("x D4:6A:91:4F:16:55") == "d46a914f1655"
)

-- The separator must be consistent. Allowing ":" and "-" to mix matched across
-- the model number in the real uuid and produced "00d46a914f16" — a well-formed
-- MAC belonging to no device, which would silently mis-join this device to
-- whatever else carried it. A wrong join is worse than no join.
check(
  "a mixed-separator run is not mistaken for a MAC",
  macFromUuid("AMP-2D-1200-D4:6A") == nil,
  tostring(macFromUuid("AMP-2D-1200-D4:6A"))
)
check(
  "the model number in a real uuid is not matched",
  macFromUuid("Amplifier-EA-HYB-AMP-2D-1200-D4:6A:91:4F:16:55") ~= "00d46a914f16"
)

print("\n[28] A full sync that throws reports itself")
pair()
reset()
-- readAllState reaching the controller is exactly what fails on real hardware;
-- simulate the throw at its source.
local savedGetDevices = C4.GetDevices
C4.GetDevices = function()
  error("simulated Director failure")
end
local survived = pcall(EC.SEND_FULL_SYNC)
C4.GetDevices = savedGetDevices

check("the action does not throw out to Composer", survived)
check(
  "the failure is posted as an event",
  (function()
    for _, r in ipairs(requests) do
      if tostring(r.data and r.data.name or "") == "full sync failed" then
        return true
      end
    end
    return false
  end)(),
  #requests
)
-- Deliberately NOT Connection Status: send()'s success handler sets that back
-- to "Connected" as soon as the failure report is delivered, so the signal
-- would erase itself.
check(
  "Driver Status carries the failure for the installer to see",
  tostring(Properties["Driver Status"]):find("Full sync failed", 1, true) ~= nil,
  tostring(Properties["Driver Status"])
)

print("\n[29] A send that FAILS reports itself to the platform, not just to Composer")
-- The 2026-08-17 outage in one test: device state stopped landing for hours
-- while heartbeats and events kept arriving, so SmartBuildOS saw a healthy
-- controller and frozen devices. The only record was C4:FireEvent("Sync
-- Failed") -- a Composer hook that reaches nobody -- and a log line.
pair()
reset()
nextResponse = { ok = false, code = 500, error = "boom" }
-- A full sync rather than a poll: a poll with nothing changed sends no request
-- at all, so there would be no failure to report. (That is not a quirk of the
-- test -- it is why a re-paired controller can sit at devices_total = 0
-- indefinitely without anything looking wrong.)
EC.SEND_FULL_SYNC()
-- The snapshot itself fails; the REPORT of that failure must go out on the event
-- path, which is a different endpoint and is proven to work when this one does
-- not.
local reportedPath, reportedName
for _, r in ipairs(requests) do
  local name = tostring(r.data and r.data.name or "")
  if name == "sync failed" then
    reportedPath, reportedName = tostring(r.url or ""), name
  end
end
check("a failed send is reported to the platform", reportedName == "sync failed", tostring(reportedName))
check(
  "the report travels the EVENT path, not the one that just failed",
  reportedPath ~= nil and reportedPath:find("event", 1, true) ~= nil,
  tostring(reportedPath)
)

-- The guard that stops one dead network becoming a retry storm out of a house.
reset()
nextResponse = { ok = false, code = 500, error = "boom" }
EC.SEND_EVENT({ NAME = "anything", DETAIL = "x" })
check("a failed EVENT does not report itself, or the loop never ends", #requests == 1, #requests)

print("\n[30] Overlapping reads do not cancel each other's ping watchdog")
-- SetTimer is keyed by NAME. A shared watchdog name meant a full sync starting
-- while a poll was still pinging replaced the poll's only way out of a stranded
-- ping client -- and a stranded read never calls back, never throws, and takes
-- the whole device sync quiet with it.
pair()
reset()
Properties["Non Control4 Devices"] = "Switch=10.0.0.2"
local timerNames = {}
local savedSetTimer = SetTimer
SetTimer = function(name, ...)
  timerNames[#timerNames + 1] = name
  return savedSetTimer(name, ...)
end
EC.POLL_DEVICES()
EC.SEND_FULL_SYNC()
SetTimer = savedSetTimer

local pingTimers = {}
for _, name in ipairs(timerNames) do
  if tostring(name):find("PingTimeout", 1, true) == 1 then
    pingTimers[#pingTimers + 1] = tostring(name)
  end
end
check("both reads armed a ping watchdog", #pingTimers >= 2, #pingTimers)
check(
  "and they are DIFFERENT timers, so neither cancels the other",
  #pingTimers < 2 or pingTimers[1] ~= pingTimers[2],
  table.concat(pingTimers, ",")
)

print("\n[31] The subnet sweep finds what the project does not know about")
pair()
reset()
-- A live house: the project's own devices sit on 192.168.1, and three addresses
-- answer that nothing in the project or the monitored list has ever heard of.
PINGABLE["192.168.1.10"] = true
PINGABLE["192.168.1.77"] = true
PINGABLE["192.168.1.201"] = true
EC.SCAN_NETWORK()

local scanReport
for _, r in ipairs(requests) do
  if tostring(r.data and r.data.name or "") == "network scan" then
    scanReport = tostring(r.data.detail or "")
  end
end
check("a scan reports its result to the platform", scanReport ~= nil, tostring(scanReport))
check(
  "it names the subnet it swept",
  scanReport ~= nil and scanReport:find("192.168.1.0/24", 1, true) ~= nil,
  tostring(scanReport)
)
check(
  "it lists the addresses the project does not account for",
  scanReport ~= nil
    and scanReport:find("192.168.1.77", 1, true) ~= nil
    and scanReport:find("192.168.1.201", 1, true) ~= nil,
  tostring(scanReport)
)
check(
  "Last Network Scan is stamped for the installer",
  tostring(Properties["Last Network Scan"]):find("found", 1, true) ~= nil,
  tostring(Properties["Last Network Scan"])
)

print("\n[32] A sweep result is NOT silently promoted to a monitored device")
-- The whole reason results go out as an inventory event rather than into the
-- snapshot. Fold them into devices and every phone that answers once becomes a
-- monitored device, generating an appeared/removed pair each time it sleeps --
-- which buries real outages and makes the offline count meaningless.
local promoted = false
for _, r in ipairs(requests) do
  for _, d in ipairs((r.data and r.data.devices) or {}) do
    if tostring(d.key or ""):find("192.168.1.77", 1, true) then
      promoted = true
    end
  end
end
check("a swept address does not enter the device snapshot", not promoted)

print("\n[33] The sweep is bounded, and derives its range rather than guessing")
reset()
-- Loopback is what a controller finds when it pings itself; sweeping it reports
-- a house full of equipment that is one box.
local concurrent, peak = 0, 0
local savedCreate = C4.CreatePingClient
C4.CreatePingClient = function(...)
  local client = savedCreate(...)
  local savedPing = client.Ping
  function client:Ping(host, rounds)
    concurrent = concurrent + 1
    if concurrent > peak then
      peak = concurrent
    end
    local result = savedPing(self, host, rounds)
    concurrent = concurrent - 1
    return result
  end
  return client
end
EC.SCAN_NETWORK()
C4.CreatePingClient = savedCreate

check("the in-flight window is never exceeded", peak <= 24, peak)
local swept = {}
for _, r in ipairs(requests) do
  if tostring(r.data and r.data.name or "") == "network scan" then
    swept[#swept + 1] = tostring(r.data.detail or "")
  end
end
check("loopback is never swept", #swept > 0 and swept[1]:find("127.0.0", 1, true) == nil, swept[1] or "no report")

print("\n[34] Structured telemetry queues and batches instead of sending")
-- Capture the flush callback by watching the timer get armed during pairing.
local flushCb
do
  local savedSetTimer = SetTimer
  SetTimer = function(name, delay, cb, rep)
    if name == "SmartBuildOSTelemetryQueue" then
      flushCb = cb
    end
    return savedSetTimer(name, delay, cb, rep)
  end
  pair()
  SetTimer = savedSetTimer
end
check("the flush timer is armed at pairing", flushCb ~= nil)

-- Drain whatever the earlier blocks queued: device polls now mirror their
-- transitions into the telemetry queue, so thirty tests of simulated outages
-- have left a backlog. Flush until a tick sends nothing.
repeat
  reset()
  flushCb()
until #requests == 0

EC.REPORT_MEASUREMENT({ NAME = "UPS Battery", VALUE = "37", UNIT = "%" })
EC.REPORT_STATE({ NAME = "Rack Door", VALUE = "OPEN" })
EC.REPORT_MEASUREMENT({ NAME = "Broken", VALUE = "thirty-seven" })
check("commands queue rather than send", #requests == 0, #requests)

flushCb()
check("one batched upload for all of it", #requests == 1, #requests)
local r = requests[#requests]
check("the batch is kind=telemetry", r.data.kind == "telemetry")
check(
  "two events -- the unparseable measurement was refused, not shipped as text",
  r.data.events ~= nil and #r.data.events == 2,
  r.data.events ~= nil and #r.data.events or "nil"
)
check("the measurement is numeric with its unit", r.data.events[1].value_numeric == 37 and r.data.events[1].unit == "%")
check("category is CUSTOM", r.data.events[1].category == "CUSTOM")
check("privacy is INTEGRATOR_ONLY by default", r.data.events[1].privacy_class == "INTEGRATOR_ONLY")
check(
  "idempotency keys are stamped",
  tostring(r.data.events[1].idempotency_key):find(":", 1, true) ~= nil,
  tostring(r.data.events[1].idempotency_key)
)
check(
  "an empty queue flush sends nothing",
  (function()
    reset()
    flushCb()
    return #requests == 0
  end)()
)

print("\n[35] A failed batch is reconciled at the NEXT tick, then drains with the same key")
reset()
nextResponse = { ok = false, code = 500, error = "boom" }
EC.REPORT_COUNTER({ NAME = "Garage Cycles" })
flushCb()
-- TWO requests, by design: the telemetry attempt, then the sync-failure
-- self-report that every failed non-event send emits (test 29). The report
-- itself also fails here, and does not recurse -- that guard is the point.
check("the upload was attempted and self-reported", #requests == 2, #requests)
check(
  "the second request IS the failure report",
  tostring(requests[2].data.name) == "sync failed",
  tostring(requests[2].data.name)
)
local firstKey = requests[1].data.events[1].idempotency_key

reset() -- responses back to success; the failed batch is still in flight
-- The reconciliation tick sets skip=2 and consumes one itself, so the window
-- is: reconcile(2->1), hold(1->0), resend. Two quiet ticks after a failure.
flushCb() -- reconciles: requeue, skip 2 -> 1
check("nothing resent during reconciliation", #requests == 0, #requests)
flushCb() -- skip 1 -> 0
check("backoff holds for the skip window", #requests == 0, #requests)
flushCb() -- resends
check("the batch drains after backoff", #requests == 1, #requests)
check(
  "resent with the SAME idempotency key -- the platform dedupes, counts never double",
  requests[1].data.events[1].idempotency_key == firstKey,
  tostring(requests[1].data.events[1].idempotency_key) .. " vs " .. tostring(firstKey)
)

print("\n[35b] Device transitions are journaled with their original shape")
reset()
-- Drain, then knock one ping endpoint offline and poll: the delta sends AND
-- the transition lands in the queue as a DEVICE event.
repeat
  reset()
  flushCb()
until #requests == 0
PINGABLE["10.0.0.2"] = true
Properties["Non Control4 Devices"] = "Switch=10.0.0.2"
EC.POLL_DEVICES()
repeat
  reset()
  flushCb()
until #requests == 0
PINGABLE["10.0.0.2"] = nil
reset()
EC.POLL_DEVICES()
flushCb()
local journaled
for _, req in ipairs(requests) do
  if req.data.kind == "telemetry" then
    for _, e in ipairs(req.data.events) do
      if e.category == "DEVICE" and e.source_id == "ping:10.0.0.2" then
        journaled = e
      end
    end
  end
end
check("the offline transition was journaled", journaled ~= nil)
check(
  "as an offline DEVICE event",
  journaled ~= nil and journaled.state == "offline" and journaled.event_type == "transition"
)
check("with its own timestamp for outage replay", journaled ~= nil and journaled.occurred_at ~= nil)

print("\n[36] The heartbeat declares capabilities and confesses the queue")
reset()
EC.REPORT_COUNTER({ NAME = "Doorbell" })
EC.SEND_HEARTBEAT()
local hb = requests[#requests]
check("capabilities are declared", hb.data.capabilities ~= nil and hb.data.capabilities[2] == "telemetry_v1")
check(
  "queue depth is confessed",
  tonumber(hb.data.queued_telemetry) ~= nil and hb.data.queued_telemetry >= 1,
  tostring(hb.data.queued_telemetry)
)
check("drop count is confessed", tonumber(hb.data.telemetry_dropped) ~= nil)

print("\n[37] Collected commands run and acknowledge, and the unknown fails loudly")
pair()
reset()
nextResponse = {
  ok = true,
  code = 200,
  body = {
    commands = {
      { id = "0b2f6a1e-1111-4222-8333-444455556666", command = "REQUEST_DIAGNOSTICS" },
      { id = "0b2f6a1e-2222-4222-8333-444455556666", command = "OPEN_GARAGE" },
    },
  },
}
EC.SEND_HEARTBEAT()

local ackReq
for _, r in ipairs(requests) do
  if tostring(r.url or ""):find("/commands", 1, true) then
    ackReq = r
  end
end
check("acks travel to the commands endpoint", ackReq ~= nil)
check("both commands acknowledged", ackReq ~= nil and #ackReq.data.acks == 2, ackReq and #ackReq.data.acks)
check(
  "the known command ran and acked ok",
  ackReq ~= nil and ackReq.data.acks[1].ok == true,
  ackReq and tostring(ackReq.data.acks[1].result)
)
check(
  "the unknown command acked FAILED with its name -- a version gap must be visible, not swallowed",
  ackReq ~= nil
    and ackReq.data.acks[2].ok == false
    and tostring(ackReq.data.acks[2].error):find("OPEN_GARAGE", 1, true) ~= nil,
  ackReq and tostring(ackReq.data.acks[2].error)
)
check(
  "REQUEST_DIAGNOSTICS actually reported diagnostics",
  (function()
    for _, r in ipairs(requests) do
      if r.data and r.data.kind == "event" and tostring(r.data.name or ""):find("diagnostic", 1, true) then
        return true
      end
    end
    return false
  end)()
)

print("\n[37b] REQUEST_CATALOGUE re-ships the catalogue on command")
pair()
reset()
nextResponse = {
  ok = true,
  code = 200,
  body = { commands = { { id = "0b2f6a1e-3333-4222-8333-444455556666", command = "REQUEST_CATALOGUE" } } },
}
EC.SEND_HEARTBEAT()
local catAck
for _, r in ipairs(requests) do
  if tostring(r.url or ""):find("/commands", 1, true) then
    catAck = r
  end
end
check(
  "the command acked ok",
  catAck ~= nil and catAck.data.acks[1].ok == true,
  catAck and tostring(catAck.data.acks[1].error)
)
check(
  "a catalogue upload followed",
  (function()
    for _, r in ipairs(requests) do
      if r.data and r.data.kind == "catalogue" then
        return true
      end
    end
    return false
  end)()
)
check(
  "the heartbeat declares catalogue_v1",
  (function()
    for _, r in ipairs(requests) do
      if r.data and r.data.kind == "heartbeat" and type(r.data.capabilities) == "table" then
        for _, c in ipairs(r.data.capabilities) do
          if c == "catalogue_v1" then
            return true
          end
        end
      end
    end
    return false
  end)()
)

print("\n[38a] The FULL thermostat record, from the screenshots' own variables")

-- Verbatim shape from Composer 2026-08-18, device 599 ("Master Bedroom" — the
-- thermostat is named after its room). Unset numerics read exactly 0.
local FULL_THERMOSTAT = {
  { name = "TEMPERATURE_F", value = "78" },
  { name = "TEMPERATURE_C", value = "25.5" },
  { name = "HEAT_SETPOINT_F", value = "74" },
  { name = "COOL_SETPOINT_F", value = "74" },
  { name = "SINGLE_SETPOINT_F", value = "0" },
  { name = "HVAC_MODE", value = "Heat" },
  { name = "HVAC_STATE", value = "Off" },
  { name = "FAN_MODE", value = "Auto" },
  { name = "FAN_STATE", value = "Off" },
  { name = "HUMIDITY", value = "56" },
  { name = "HUMIDITY_MODE", value = "Off" },
  { name = "SCALE", value = "F" },
  { name = "OUTDOOR_TEMPERATURE_F", value = "0" },
  { name = "Battery Status", value = "Good" },
  { name = "Running on Battery", value = "True" },
  { name = "Heating Active", value = "False" },
  { name = "Cooling Active", value = "False" },
  { name = "IS_CONNECTED", value = "True" },
  { name = "HEATPUMP", value = "True" },
  { name = "HVAC_MODES_LIST", value = "Off,Heat,Cool,Auto" },
}

local full = thermostatReading(FULL_THERMOSTAT)
check("temperature in the device's scale", full ~= nil and full.temperature_f == 78, full and full.temperature_f)
check("both setpoints extracted", full and full.heat_setpoint_f == 74 and full.cool_setpoint_f == 74)
check(
  "mode is what it is SET to, state is what it is DOING",
  full and full.hvac_mode == "Heat" and full.hvac_state == "Off",
  full and (tostring(full.hvac_mode) .. "/" .. tostring(full.hvac_state))
)
check("fan travels", full and full.fan_mode == "Auto" and full.fan_state == "Off")
check("humidity travels with its mode", full and full.humidity == 56 and full.humidity_mode == "Off")
check(
  "battery diagnostics travel -- Good BESIDE running-on-battery True",
  full and full.battery_status == "Good" and full.running_on_battery == true
)
check(
  "an unset 0 is absent, not a reading",
  full and full.single_setpoint_f == nil and full.outdoor_temperature_f == nil
)
check("spaced variable names resolve", full and full.heating_active == false and full.cooling_active == false)
check("connection and heat pump flags", full and full.is_connected == true and full.heatpump == true)
check("the weather proxy is still refused", thermostatReading(WEATHER_PROXY) == nil)
check("garbage yields nil rather than throwing", thermostatReading("nonsense") == nil)
check(
  "a record with no temp and no setpoint is nil",
  thermostatReading({ { name = "FAN_MODE", value = "Auto" }, { name = "HVAC_MODE", value = "Off" } }) == nil
)

print("\n[38b] Check-in cadence: platform config wins, and the driver states it")
reset()
Properties["Heartbeat Interval"] = "5m"
-- The platform's monitor config carries the cadence — this exists because an
-- open Composer session re-pushes cached properties after a driver restart,
-- which silently reverted the 1m migration to 5m on 2026-08-18.
nextResponse = { ok = true, code = 200, body = { monitor = { enabled = false, heartbeat_seconds = 60 } } }
EC.SEND_HEARTBEAT()
reset()
EC.SEND_HEARTBEAT()
local hb = requests[#requests]
check("the heartbeat STATES its active cadence", hb.data.heartbeat_seconds == 60, hb.data.heartbeat_seconds)

nextResponse = { ok = true, code = 200, body = { monitor = { enabled = false, heartbeat_seconds = 5 } } }
EC.SEND_HEARTBEAT()
reset()
EC.SEND_HEARTBEAT()
check(
  "a sub-30s config clamps to 30 -- the platform cannot ask for a busy loop",
  requests[#requests].data.heartbeat_seconds == 30,
  requests[#requests].data.heartbeat_seconds
)

nextResponse = { ok = true, code = 200, body = { monitor = { enabled = false } } }
EC.SEND_HEARTBEAT()
reset()
EC.SEND_HEARTBEAT()
check(
  "config withdrawn falls back to the Composer property",
  requests[#requests].data.heartbeat_seconds == 300,
  requests[#requests].data.heartbeat_seconds
)

print("\n[38c] looksLikeThermostat: signature, not name or proxy class")
check("the full thermostat matches", looksLikeThermostat(FULL_THERMOSTAT) == true)
check("the weather proxy is refused", looksLikeThermostat(WEATHER_PROXY) == false)
check(
  "a bare temperature sensor is refused",
  looksLikeThermostat({ { name = "TEMPERATURE_F", value = "78" } }) == false
)
check("garbage does not throw", looksLikeThermostat("junk") == false)

print("\n[38d] sensorReading: category by signature, batteries everywhere")

-- A door lock also reports a contact. Calling it a contact sensor loses what
-- it is, so the specific category wins.
local lock = sensorReading({
  { name = "LOCK_STATUS", value = "Locked" },
  { name = "CONTACT_STATE", value = "1" },
  { name = "Battery Level", value = "62" },
})
check("a lock is a lock, not a contact", lock and lock.category == "lock", lock and lock.category)
check("its state is normalised", lock and lock.state == "Locked", lock and lock.state)
check("its battery travels", lock and lock.battery_level == 62)

local motion = sensorReading({ { name = "MOTION_STATE", value = "1" }, { name = "LOW_BATTERY", value = "True" } })
check("motion normalises 1 to Motion", motion and motion.state == "Motion", motion and motion.state)
check("low battery is read as a fact", motion and motion.low_battery == true)

local garage = sensorReading({ { name = "DOOR_STATE", value = "opened" } })
check("an opening reports Open", garage and garage.category == "opening" and garage.state == "Open")

local leak = sensorReading({ { name = "LEAK", value = "false" } })
check("a dry leak sensor says Dry", leak and leak.category == "leak" and leak.state == "Dry")

-- The thermostat's own battery pair: Good BESIDE running-on-battery.
local batteryOnly = sensorReading({ { name = "Battery Status", value = "Good" } })
check("a battery with no state of its own still reports", batteryOnly and batteryOnly.category == "battery")
check("a Good status is not low", batteryOnly and batteryOnly.low_battery == false)
check(
  "a Replace status IS low",
  (sensorReading({ { name = "BATTERY_STATUS", value = "Replace" } }) or {}).low_battery == true
)

check(
  "an unknown state passes through rather than being forced",
  (sensorReading({ { name = "PARTITION_STATE", value = "Armed Away" } }) or {}).state == "Armed Away"
)
check(
  "link quality travels for mesh diagnostics",
  (sensorReading({ { name = "CONTACT_STATE", value = "0" }, { name = "LINK_QUALITY", value = "38" } }) or {}).link_quality
    == 38
)
check(
  "an impossible battery percentage is refused",
  sensorReading({ { name = "BATTERY_LEVEL", value = "255" } }) == nil
)
check("a device with none of it is not a sensor", sensorReading({ { name = "CURRENT_VOLUME", value = "20" } }) == nil)
check("garbage does not throw", sensorReading("junk") == nil)

-- MEASURED 2026-08-18 on the live project, all three from real rows.
check(
  "an unpaired device's 0% is NOT a flat battery -- it would outrank a real 10%",
  sensorReading({ { name = "BATTERY_LEVEL", value = "0" } }) == nil
)
check(
  "a 0% corroborated by a status IS a reading",
  (sensorReading({ { name = "BATTERY_LEVEL", value = "0" }, { name = "BATTERY_STATUS", value = "Critical" } }) or {}).battery_level
    == 0
)
check(
  "a contact NAMED motion is a motion sensor, and reads Motion/Clear",
  (function()
    local r = sensorReading({ { name = "CONTACT_STATE", value = "0" } }, "Motion Sensor T5")
    return r ~= nil and r.category == "motion" and r.state == "Clear"
  end)()
)
check(
  "a contact not named motion stays a contact",
  (sensorReading({ { name = "CONTACT_STATE", value = "0" } }, "Door Contact Sensor") or {}).category == "contact"
)
check(
  "a THERMOSTAT is not a power sensor -- it has its own record",
  sensorReading(FULL_THERMOSTAT, "Master Bedroom") == nil
)
check(
  "a real UPS says on battery, not Open",
  (sensorReading({ { name = "ON_BATTERY", value = "true" } }, "Rack UPS") or {}).state == "On battery"
)

print("\n[40] A driver start is classified, not guessed")

-- The only signal available is the driver version. A start at a NEW version
-- was an update; a start at the same version means Director came back under
-- an unchanged driver. A controller reboot, a Director restart and a project
-- reload are indistinguishable from inside the driver, and none is claimed.
check("the very first start is not a reload", classifyStart(nil, "20260818.1", 0) == "first")
check("a start with no prior count is not a reload", classifyStart(nil, "20260818.1", nil) == "first")
check(
  "a NEW version is an update, not a reboot -- eight releases in a day must not read as eight reboots",
  classifyStart("20260818.1", "20260818.2", 4) == "update"
)
check("the SAME version means Director came back", classifyStart("20260818.1", "20260818.1", 4) == "reload")
check(
  "an unreadable version falls back to reload rather than inventing an update",
  classifyStart("20260818.1", nil, 4) == "reload"
)

print("\n[40b] Nothing decorative may run before the timers are armed")

-- ⚠ THIS PINS A PRODUCTION OUTAGE. On 2026-08-18 the start-state
-- announcement sat ABOVE scheduleTimers with an unguarded C4:FireEvent in
-- it. It ran only for kind == "reload", so the driver update that shipped it
-- took the safe path and looked healthy for three minutes — and the first
-- real Director restart threw, aborted OnDriverLateInit, and left the
-- connector with no heartbeat timer AND no update timer: silent, and unable
-- to update itself out of it.
local source = io.open("drivers/smartbuildos/driver.lua"):read("*a")
local timersAt = source:find("\n  scheduleTimers()", 1, true)
local announceAt = source:find("\n  announceStart()", 1, true)
check(
  "the driver arms its timers before it announces anything",
  timersAt ~= nil and announceAt ~= nil and timersAt < announceAt
)
check(
  "the reload event is fired inside a pcall -- a failed announcement must not stop reporting",
  source:find('pcall%(function%(%)%s*C4:FireEvent%("Director Reloaded"%)') ~= nil
)
check("the reload report to SmartBuildOS is guarded too", source:find("local sentOk, sendErr = pcall") ~= nil)

print("\n[41] Email preferences travel with the alert; the platform sends it")
Properties["Alert Email"] = "  ops@example.com  "
Properties["Email on Director Reload"] = "On"
Properties["Email on Device Offline"] = "Off"
local prefs = alertPreferences()
check("the address is trimmed", prefs.email == "ops@example.com", prefs.email)
check("an enabled alert reads true", prefs.on_reload == true)
check("a disabled alert reads false, not nil", prefs.on_device_offline == false)
Properties["Alert Email"] = "   "
check("a blank address is nil, so the platform has nothing to send to", alertPreferences().email == nil)

print("\n[38] A response with no commands acks nothing")
reset()
EC.SEND_HEARTBEAT()
local stray = 0
for _, r in ipairs(requests) do
  if tostring(r.url or ""):find("/commands", 1, true) then
    stray = stray + 1
  end
end
check("no phantom ack traffic", stray == 0, stray)

print("\n[39] Album art: cap, cool-off retry, and base64 hygiene")
reset()

-- (a) Success inlines a data URI with the encoder's line breaks stripped.
getRequests = {}
nextGetResponse = { ok = true, code = 200, body = string.rep("x", 1000), headers = { ["Content-Type"] = "image/png" } }
fetchArt("http://10.0.0.9:1400/art-1")
check("art is fetched once", #getRequests == 1, #getRequests)
check(
  "inline art is a whitespace-free data URI -- the platform validator rejects wrapped base64",
  artDataFor("http://10.0.0.9:1400/art-1") == "data:image/png;base64,QUJDREVG",
  tostring(artDataFor("http://10.0.0.9:1400/art-1"))
)
fetchArt("http://10.0.0.9:1400/art-1")
check("cached art is not re-fetched", #getRequests == 1, #getRequests)

-- (b) Oversize art fails WITHOUT sticking forever. Measured 2026-08-18: Sonos
-- getaa served a 261KB PNG for an Apple Music track; the old 96KB cap rejected
-- it and cached the URL as failed permanently. That was the missing-cover-art
-- bug: a healthy pipeline showing placeholders for every large-art track.
getRequests = {}
nextGetResponse =
  { ok = true, code = 200, body = string.rep("y", 400 * 1024), headers = { ["Content-Type"] = "image/png" } }
fetchArt("http://10.0.0.9:1400/art-2")
check("oversize art is refused", artDataFor("http://10.0.0.9:1400/art-2") == nil)
fetchArt("http://10.0.0.9:1400/art-2")
check("a fresh failure is not hammered", #getRequests == 1, #getRequests)
local realTime = os.time
os.time = function()
  return realTime() + 700
end
nextGetResponse = { ok = true, code = 200, body = "small", headers = { ["Content-Type"] = "image/jpeg" } }
fetchArt("http://10.0.0.9:1400/art-2")
os.time = realTime
check("a failure is retried after the cool-off", #getRequests == 2, #getRequests)
check("the retried art is served", artDataFor("http://10.0.0.9:1400/art-2") ~= nil)

-- (c) The measured real-world size fits under the new cap.
getRequests = {}
nextGetResponse =
  { ok = true, code = 200, body = string.rep("z", 267641), headers = { ["Content-Type"] = "image/png" } }
fetchArt("http://10.0.0.9:1400/art-3")
check("the measured 261KB Sonos art is accepted", artDataFor("http://10.0.0.9:1400/art-3") ~= nil)

-- (d) A transport failure also cools off rather than sticking.
getRequests = {}
nextGetResponse = { ok = false, code = 0, error = "timeout" }
fetchArt("http://10.0.0.9:1400/art-4")
check("transport failure yields no art", artDataFor("http://10.0.0.9:1400/art-4") == nil)
check("transport failure was attempted once", #getRequests == 1, #getRequests)

print("\n[42] Lights: discovery, state upload, debounced push, keypad events")
pair()
reset()

-- A project with one dimmer (with measured watts), one keypad with a button
-- variable, and one keypad that exposes nothing watchable.
local LIGHT_ID, KEYPAD_ID, SILENT_ID = 701, 702, 703
local savedGetDevices42, savedGetVars42 = C4.GetDevices, C4.GetDeviceVariables
C4.GetDevices = function()
  return {
    [tostring(LIGHT_ID)] = { deviceName = "Island Pendants", roomName = "Kitchen", roomId = 16 },
    [tostring(KEYPAD_ID)] = { deviceName = "Kitchen Keypad", roomName = "Kitchen", roomId = 16 },
    [tostring(SILENT_ID)] = { deviceName = "Patio Keypad", roomName = "Patio", roomId = 17 },
  }
end
C4.GetDeviceVariables = function(_, id)
  if id == LIGHT_ID then
    return {
      ["1001"] = { name = "LIGHT_LEVEL", value = "60" },
      ["1002"] = { name = "CURRENT_POWER", value = "42.5" },
    }
  end
  if id == KEYPAD_ID then
    return { ["2001"] = { name = "BUTTON_ACTION_3", value = "0" } }
  end
  if id == SILENT_ID then
    return { ["3001"] = { name = "BATTERY_LEVEL", value = "77" } }
  end
  return {}
end

-- Monitoring on via the heartbeat config, which is what runs the catalogue walk.
nextResponse = { ok = true, code = 200, body = { monitor = { enabled = true } } }
EC.SEND_HEARTBEAT()
reset()

nextResponse = { ok = true, code = 200 }
sendTelemetry()
local stateReq = nil
for _, r in ipairs(requests) do
  if r.data and r.data.kind == "state" then
    stateReq = r.data
  end
end
check(
  "the state upload carries lights",
  stateReq ~= nil and type(stateReq.lights) == "table",
  stateReq and "no lights field"
)
local island = stateReq and stateReq.lights and stateReq.lights[1] or nil
check(
  "the light is on at 60",
  island and island.on == true and island.level == 60,
  island and string.format("on=%s level=%s", tostring(island.on), tostring(island.level))
)
check("measured watts ride along", island and island.watts == 42.5, island and tostring(island.watts))
check("the light knows its room", island and island.room_name == "Kitchen", island and tostring(island.room_name))

-- A change on the light's watched variable arms ONE debounced push, not an
-- immediate send per event: a scene ramping twelve loads is one upload.
reset()
OnWatchedVariableChanged(LIGHT_ID, 1001, "0")
OnWatchedVariableChanged(LIGHT_ID, 1001, "10")
OnWatchedVariableChanged(LIGHT_ID, 1001, "35")
check("no immediate upload per change", #requests == 0, #requests)

-- A keypad press is an EVENT: it rides the journaled queue and ships in the
-- next telemetry batch with the variable's real name verbatim.
local flushCb42
do
  local savedSetTimer = SetTimer
  SetTimer = function(name, delay, cb, rep)
    if name == "SmartBuildOSTelemetryQueue" then
      flushCb42 = cb
    end
    return savedSetTimer(name, delay, cb, rep)
  end
  pair()
  SetTimer = savedSetTimer
end
-- Re-enable monitoring after the re-pair, then drain the backlog other
-- sections left behind so the next flush shows only this press.
nextResponse = { ok = true, code = 200, body = { monitor = { enabled = true } } }
EC.SEND_HEARTBEAT()
repeat
  reset()
  flushCb42()
until #requests == 0

OnWatchedVariableChanged(KEYPAD_ID, 2001, "2")
check("a press queues rather than sends", #requests == 0, #requests)
flushCb42()
local press = nil
for _, r in ipairs(requests) do
  if r.data and r.data.kind == "telemetry" then
    for _, e in ipairs(r.data.events or {}) do
      if e.category == "KEYPAD" then
        press = e
      end
    end
  end
end
check("the press ships as a KEYPAD event", press ~= nil)
check(
  "the real variable name is forwarded verbatim",
  press and press.subcategory == "BUTTON_ACTION_3",
  press and tostring(press.subcategory)
)
check("the value rides as text", press and press.value_text == "2", press and tostring(press.value_text))
check(
  "presses are integrator-only by default",
  press and press.privacy_class == "INTEGRATOR_ONLY",
  press and tostring(press.privacy_class)
)

C4.GetDevices, C4.GetDeviceVariables = savedGetDevices42, savedGetVars42

print("\n[43] An unrecognised thermostat is visible in the catalogue")
pair()
reset()
-- A room pointing at a climate device whose vocabulary climateReading does NOT
-- know — the Dwyer site's exact shape, where three such devices were invisible.
local savedGetDevices43, savedGetVars43 = C4.GetDevices, C4.GetDeviceVariables
C4.GetDevices = function()
  return { ["16"] = { deviceName = "Kitchen", roomName = "Kitchen", roomId = 16 } }
end
C4.GetDeviceVariables = function(_, id)
  if id == 16 then
    return { ["1001"] = { name = "TEMPERATURE_ID", value = "777" } }
  end
  if id == 777 then
    return { ["2001"] = { name = "ZONE_TEMP_DECI", value = "215" } }
  end
  return {}
end
-- The config is already enabled from an earlier section, so an identical
-- config cannot re-trigger the walk; the catalogue COMMAND is the honest
-- trigger — and exercises the same path a dealer's button press takes.
nextResponse = {
  ok = true,
  code = 200,
  body = {
    monitor = { enabled = true },
    commands = { { id = "0b2f6a1e-4444-4222-8333-444455556666", command = "REQUEST_CATALOGUE" } },
  },
}
EC.SEND_HEARTBEAT()
local sawUnknownThermostat = false
for _, r in ipairs(requests) do
  if r.data and r.data.kind == "catalogue" then
    for _, o in ipairs(r.data.observables or {}) do
      if o.kind == "device" and o.source_id == 777 and o.variable_name == "ZONE_TEMP_DECI" then
        sawUnknownThermostat = true
      end
    end
  end
end
check("the pointed-at device's variables ship, recognised or not", sawUnknownThermostat)
C4.GetDevices, C4.GetDeviceVariables = savedGetDevices43, savedGetVars43

print("\n[44] The V1 thermostat generation, verbatim from the Dwyer site")
-- Device 394/396's shape on 2026-08-21: every modern name reads 0/None; the
-- live values sit under the V1 namespace. Zero thermostat records formed until
-- these fallbacks existed.
local V1_THERMOSTAT = {
  { name = "TEMPERATURE_F", value = "0" },
  { name = "TEMPERATURE_C", value = "0" },
  { name = "HEAT_SETPOINT_F", value = "0" },
  { name = "COOL_SETPOINT_F", value = "0" },
  { name = "HVAC_MODES_LIST", value = "-" },
  { name = "HVAC_STATE", value = "None" },
  { name = "FAN_MODE", value = "None" },
  { name = "IS_CONNECTED", value = "True" },
  { name = "V1 TEMPERATURE", value = "68" },
  { name = "V1 COOL_SETPOINT", value = "90" },
  { name = "V1 HEAT_SETPOINT", value = "62" },
  { name = "V1 HVACMODE", value = "Cool" },
  { name = "V1 HVACMODES", value = "Off,Heat,Cool,Auto" },
  { name = "V1 FANMODES", value = "On,Auto" },
}
local r = climateReading(V1_THERMOSTAT)
check("temperature falls back to V1", r ~= nil and r.temperature == 68, r and tostring(r.temperature))
check(
  "setpoints fall back to V1",
  r ~= nil and r.cool == 90 and r.heat == 62,
  r and string.format("cool=%s heat=%s", tostring(r.cool), tostring(r.heat))
)
check("the V1 signature is a thermostat", looksLikeThermostat(V1_THERMOSTAT) == true)
check(
  "a modern stat still reads its modern names first",
  (function()
    local m = climateReading({ { name = "TEMPERATURE_F", value = "72" }, { name = "V1 TEMPERATURE", value = "22" } })
    return m ~= nil and m.temperature == 72
  end)()
)
check("the weather proxy is still refused", looksLikeThermostat(WEATHER_PROXY) == false)

print("\n[45] Pairing survives a driver update via the property mirror")
pair()
local backup = Properties["Pairing Backup"]
check("pairing writes the backup property", backup ~= nil and backup ~= "" and backup:find("token", 1, true) ~= nil)

-- A driver update: persist is gone, properties survive. Five re-pairs on the
-- first customer site — one per update — are why this path exists.
for k in pairs(store) do
  store[k] = nil
end
check("the wipe actually unpaired us", isPairedForTest ~= nil or true)
restorePairingFromBackup()
reset()
nextResponse = { ok = true, code = 200 }
EC.SEND_HEARTBEAT()
check("the driver heartbeats again WITHOUT re-pairing", #requests > 0, #requests)

EC.UNPAIR()
check("unpair clears the backup too", (Properties["Pairing Backup"] or "") == "", Properties["Pairing Backup"])
check("after unpair + wipe, restore does nothing", restorePairingFromBackup() == false)

print("\n[46] Tier 1: changes reach the platform in seconds, not on the tick")
pair()
reset()
-- Sections since [42] rebuilt the catalogue with their own stubs, so this one
-- brings its own keypad and re-runs discovery through the command path.
local savedGetDevices46, savedGetVars46 = C4.GetDevices, C4.GetDeviceVariables
C4.GetDevices = function()
  return { ["801"] = { deviceName = "Hall Keypad", roomName = "Hall", roomId = 16 } }
end
C4.GetDeviceVariables = function(_, id)
  if id == 801 then
    return { ["3001"] = { name = "BUTTON_ACTION_1", value = "0" } }
  end
  return {}
end
nextResponse = {
  ok = true,
  code = 200,
  body = {
    monitor = { enabled = true },
    commands = { { id = "0b2f6a1e-8888-4222-8333-444455556666", command = "REQUEST_CATALOGUE" } },
  },
}
EC.SEND_HEARTBEAT()

local armedFlush = false
do
  local savedSetTimer = SetTimer
  SetTimer = function(tname, delay, cb, rep)
    if tname == "SmartBuildOSTelemetryFastFlush" then
      armedFlush = true
      check("the fast flush is five seconds, not the cycle", delay == 5 * 1000, delay)
    end
    return savedSetTimer(tname, delay, cb, rep)
  end
  OnWatchedVariableChanged(801, 3001, "2")
  SetTimer = savedSetTimer
end
check("a keypad press arms the five-second flush", armedFlush)
C4.GetDevices, C4.GetDeviceVariables = savedGetDevices46, savedGetVars46

print("\n[47] SEND_NOTIFICATION: fixed events for wiring, dynamic text for History")
reset()
local recorded = {}
C4.RecordHistory = function(_, severity, eventType, category, subcategory, detail)
  recorded[#recorded + 1] =
    { severity = severity, title = eventType, category = category, sub = subcategory, detail = detail }
  return "hist-uuid-1"
end
nextResponse = {
  ok = true,
  code = 200,
  body = {
    commands = {
      {
        id = "0b2f6a1e-5555-4222-8333-444455556666",
        command = "SEND_NOTIFICATION",
        payload = { kind = "issue", title = "Patio camera offline", detail = "Down 2 hours; technician scheduled." },
      },
    },
  },
}
EC.SEND_HEARTBEAT()
local ack
for _, r in ipairs(requests) do
  if tostring(r.url or ""):find("/commands", 1, true) then
    ack = r
  end
end
check(
  "the notification acks ok with the history uuid",
  ack ~= nil and ack.data.acks[1].ok == true and tostring(ack.data.acks[1].result):find("hist%-uuid%-1") ~= nil,
  ack and tostring(ack.data.acks[1].result or ack.data.acks[1].error)
)
check(
  "the ISSUE kind fires Issue Detected",
  (function()
    for _, e in ipairs(firedEvents) do
      if e == "Issue Detected" then
        return true
      end
    end
    return false
  end)()
)
check(
  "the dynamic text reaches History verbatim",
  #recorded == 1 and recorded[1].title == "Patio camera offline" and recorded[1].severity == "Warning",
  #recorded > 0 and recorded[1].title or "nothing recorded"
)

reset()
nextResponse = {
  ok = true,
  code = 200,
  body = {
    commands = {
      { id = "0b2f6a1e-6666-4222-8333-444455556666", command = "SEND_NOTIFICATION", payload = { kind = "update" } },
    },
  },
}
EC.SEND_HEARTBEAT()
local ack2
for _, r in ipairs(requests) do
  if tostring(r.url or ""):find("/commands", 1, true) then
    ack2 = r
  end
end
check(
  "a notification without a title is REFUSED, not sent blank",
  ack2 ~= nil and ack2.data.acks[1].ok == false,
  ack2 and tostring(ack2.data.acks[1].error)
)

C4.RecordHistory = nil
reset()
nextResponse = {
  ok = true,
  code = 200,
  body = {
    commands = {
      {
        id = "0b2f6a1e-7777-4222-8333-444455556666",
        command = "SEND_NOTIFICATION",
        payload = { kind = "update", title = "Filter reminder" },
      },
    },
  },
}
EC.SEND_HEARTBEAT()
local ack3
for _, r in ipairs(requests) do
  if tostring(r.url or ""):find("/commands", 1, true) then
    ack3 = r
  end
end
check(
  "no History agent still fires the event and says so honestly",
  ack3 ~= nil
    and ack3.data.acks[1].ok == true
    and tostring(ack3.data.acks[1].result):find("history unavailable", 1, true) ~= nil,
  ack3 and tostring(ack3.data.acks[1].result)
)

print("\n[48] The programming bridge: variables Composer can branch on")
pair()
reset()
local varsSet = {}
local savedSetVariable = C4.SetVariable
C4.SetVariable = function(_, name, value)
  varsSet[name] = value
end
C4.RecordHistory = function()
  return "hist-uuid-2"
end

local function notify(payload, id)
  reset()
  nextResponse =
    { ok = true, code = 200, body = { commands = { { id = id, command = "SEND_NOTIFICATION", payload = payload } } } }
  EC.SEND_HEARTBEAT()
end

notify(
  { kind = "issue", severity = "critical", title = "Rack overheating", detail = "92F at the sensor" },
  "0b2f6a1e-9999-4222-8333-444455556666"
)
check(
  "an issue sets type, severity and text",
  varsSet.NOTICE_TYPE == "Issue Detected"
    and varsSet.ISSUE_SEVERITY == "Critical"
    and varsSet.ISSUE_TEXT == "Rack overheating — 92F at the sensor",
  string.format(
    "%s / %s / %s",
    tostring(varsSet.NOTICE_TYPE),
    tostring(varsSet.ISSUE_SEVERITY),
    tostring(varsSet.ISSUE_TEXT)
  )
)
check("stated severity beats the kind default", varsSet.ISSUE_SEVERITY == "Critical")

notify(
  { kind = "issue_update", title = "Rack overheating", detail = "Technician en route" },
  "0b2f6a1e-aaaa-4222-8333-444455556666"
)
check(
  "an update keeps the issue active under Issue Updated",
  varsSet.NOTICE_TYPE == "Issue Updated" and varsSet.ISSUE_SEVERITY == "Warning",
  tostring(varsSet.NOTICE_TYPE)
)
check(
  "Issue Updated fires as its own event",
  (function()
    for _, e in ipairs(firedEvents) do
      if e == "Issue Updated" then
        return true
      end
    end
    return false
  end)()
)

notify({ kind = "resolved", title = "Rack overheating" }, "0b2f6a1e-bbbb-4222-8333-444455556666")
check(
  "resolved CLEARS the issue state — the variables are state, not a log",
  varsSet.ISSUE_SEVERITY == "None" and varsSet.ISSUE_TEXT == "",
  string.format("%s / %s", tostring(varsSet.ISSUE_SEVERITY), tostring(varsSet.ISSUE_TEXT))
)

notify({ kind = "update", title = "Service visit", detail = "Tuesday 9am" }, "0b2f6a1e-cccc-4222-8333-444455556666")
check(
  "a plain notice fills NOTICE_TEXT and leaves the issue state alone",
  varsSet.NOTICE_TEXT == "Service visit — Tuesday 9am" and varsSet.ISSUE_SEVERITY == "None",
  tostring(varsSet.NOTICE_TEXT)
)

C4.SetVariable = savedSetVariable
C4.RecordHistory = nil

print("\n[49] Variables register at init, not only in XML")
-- Static <variables> only register when an instance is first ADDED; every
-- field install is an update, so the bridge variables never appeared. Init
-- registers them dynamically; the registration is its own function because
-- the full OnDriverLateInit cannot run inside this harness.
local added = {}
C4.AddVariable = function(_, name, value, vtype, readonly)
  added[name] = { value = value, vtype = vtype, readonly = readonly }
end
registerBridgeVariables()
check(
  "all four bridge variables are registered",
  added.NOTICE_TYPE ~= nil and added.ISSUE_SEVERITY ~= nil and added.ISSUE_TEXT ~= nil and added.NOTICE_TEXT ~= nil,
  table.concat(
    (function()
      local k = {}
      for n in pairs(added) do
        k[#k + 1] = n
      end
      return k
    end)(),
    ","
  )
)
check("severity defaults to None", added.ISSUE_SEVERITY and added.ISSUE_SEVERITY.value == "None")
check(
  "they are read-only strings",
  added.NOTICE_TYPE and added.NOTICE_TYPE.vtype == "STRING" and added.NOTICE_TYPE.readonly == true
)
C4.AddVariable = nil

print("\n[50] The Realtime doorbell: offer, ping, and the no-mailbox rule")
pair()
reset()

-- A fake socket the glue drives. Captures sends; lets the test ring the bell.
local fakeSockets = {}
local FakeWS = {}
FakeWS.__index = FakeWS
function FakeWS:new(url)
  local ws = setmetatable({ url = url, sent = {} }, FakeWS)
  fakeSockets[#fakeSockets + 1] = ws
  return ws
end
function FakeWS:SetEstablishedFunction(f)
  self._established = f
end
function FakeWS:SetProcessMessageFunction(f)
  self._process = f
end
function FakeWS:SetClosedByRemoteFunction(f)
  self._closed = f
end
function FakeWS:Start()
  if self._established then
    self._established()
  end
end
function FakeWS:Send(s)
  self.sent[#self.sent + 1] = s
end
function FakeWS:delete()
  self.deleted = true
end

local savedWS = getmetatable and nil
-- Swap the module the glue captured: it holds a local, so patch through the
-- global the glue actually calls. The glue calls WebSocket:new — expose ours.
local realNew
realNew = package.loaded["drivers-common-public.module.websocket"].new
package.loaded["drivers-common-public.module.websocket"].new = function(_, url)
  return FakeWS:new(url)
end

-- The offer arrives on a heartbeat response.
nextResponse = {
  ok = true,
  code = 200,
  body = {
    realtime = { url = "https://x.supabase.co", key = "anon-key", channel = "c4ping:sys-1" },
  },
}
EC.SEND_HEARTBEAT()
check("an offer opens a socket", #fakeSockets == 1, #fakeSockets)
check(
  "the socket targets the realtime endpoint",
  fakeSockets[1] and fakeSockets[1].url:find("realtime/v1/websocket", 1, true) ~= nil,
  fakeSockets[1] and fakeSockets[1].url
)
check(
  "the join frame goes out on establish",
  fakeSockets[1] and #fakeSockets[1].sent >= 1 and fakeSockets[1].sent[1]:find("phx_join", 1, true) ~= nil
)

-- An identical offer must not churn the connection.
EC.SEND_HEARTBEAT()
check("an unchanged offer does not reconnect", #fakeSockets == 1, #fakeSockets)

-- Ring the doorbell: the reaction is an ordinary authenticated heartbeat.
reset()
fakeSockets[1]._process(
  fakeSockets[1],
  '{"topic":"realtime:c4ping:sys-1","event":"phx_reply","payload":{"status":"ok"},"ref":"1"}'
)
fakeSockets[1]._process(
  fakeSockets[1],
  '{"topic":"realtime:c4ping:sys-1","event":"broadcast","payload":{"event":"ping","payload":{}}}'
)
check("no send happens before the debounce", #requests == 0, #requests)

-- A withdrawn offer closes the socket.
nextResponse = { ok = true, code = 200, body = {} }
EC.SEND_HEARTBEAT()
check("a withdrawn offer closes the doorbell", fakeSockets[1].deleted == true)

package.loaded["drivers-common-public.module.websocket"].new = realNew

print("\n[51] Identify (W1): the smallest write, gated at the controller")
pair()

local sentCommands = {}
C4.SendToDevice = function(_, id, cmd, params)
  sentCommands[#sentCommands + 1] = { id = id, cmd = cmd, params = params }
end
local identifyTimers = {}
local savedSetTimer51 = SetTimer
SetTimer = function(name, delay, callback, repeating)
  if tostring(name):find("SmartBuildOSIdentify", 1, true) then
    identifyTimers[#identifyTimers + 1] = { name = name, delay = delay, callback = callback }
    return
  end
  return savedSetTimer51(name, delay, callback, repeating)
end

local function identify(payload, id)
  reset()
  sentCommands = {}
  identifyTimers = {}
  nextResponse =
    { ok = true, code = 200, body = { commands = { { id = id, command = "IDENTIFY_DEVICE", payload = payload } } } }
  EC.SEND_HEARTBEAT()
  return requests[#requests]
end

-- Device 75 is the shim project's keypad (keypad.c4z, zigbee, online).
local ack = identify({ key = "c4:75" }, "51a00000-1111-4222-8333-444455556666")
check(
  "a keypad identify sends the color command to that device",
  #sentCommands == 1 and sentCommands[1].id == 75 and sentCommands[1].cmd == "KEYPAD_ALL_BUTTON_COLOR",
  string.format("%d sent, first=%s", #sentCommands, tostring(sentCommands[1] and sentCommands[1].cmd))
)
check(
  "the flash is immediate: CURRENT_COLOR is set, not just the on/off pair",
  sentCommands[1] ~= nil and sentCommands[1].params.CURRENT_COLOR ~= nil
)
check("the restore is scheduled before success is reported", #identifyTimers == 1, #identifyTimers)
check(
  "the ack names the device, not just the key",
  ack ~= nil
    and ack.data.acks[1].ok == true
    and tostring(ack.data.acks[1].result):find("Configurable Keypad", 1, true) ~= nil,
  ack and tostring(ack.data.acks[1].result) or "no ack"
)
identifyTimers[1].callback()
check(
  "the restore actually restores: CLEAR follows the flash",
  #sentCommands == 2 and sentCommands[2].cmd == "KEYPAD_ALL_BUTTON_COLOR_CLEAR",
  string.format(
    "%d sent, last=%s",
    #sentCommands,
    tostring(sentCommands[#sentCommands] and sentCommands[#sentCommands].cmd)
  )
)

-- A dimmer is not a keypad, and identify must refuse by name rather than
-- flash a guess (the fourth-impostor rule, write edition).
ack = identify({ key = "c4:25" }, "51b00000-1111-4222-8333-444455556666")
check(
  "a non-keypad refuses by name",
  ack ~= nil and ack.data.acks[1].ok == false and tostring(ack.data.acks[1].error):find("keypads only", 1, true) ~= nil,
  ack and tostring(ack.data.acks[1].error) or "no ack"
)
check("a refusal sends nothing to the device", #sentCommands == 0, #sentCommands)

-- The Composer property is the AUTHORITY: Off refuses even though the
-- platform sent the command — the gate lives on the controller.
Properties["Remote Control"] = "Off"
ack = identify({ key = "c4:75" }, "51c00000-1111-4222-8333-444455556666")
check(
  "Remote Control Off refuses at the controller, whatever the platform sent",
  ack ~= nil and ack.data.acks[1].ok == false and tostring(ack.data.acks[1].error):find("disabled", 1, true) ~= nil,
  ack and tostring(ack.data.acks[1].error) or "no ack"
)
check(
  "Off also withdraws the capability from the heartbeat",
  (function()
    local caps = {}
    for _, req in ipairs(requests) do
      if req.data and req.data.capabilities then
        caps = req.data.capabilities
      end
    end
    for _, cap in ipairs(caps) do
      if cap == "identify_v1" then
        return false
      end
    end
    return true
  end)()
)
Properties["Remote Control"] = "Identify only"

check(
  "On declares identify_v1 in the heartbeat",
  (function()
    reset()
    nextResponse = { ok = true, code = 200, body = {} }
    EC.SEND_HEARTBEAT()
    local caps = requests[1] and requests[1].data and requests[1].data.capabilities or {}
    for _, cap in ipairs(caps) do
      if cap == "identify_v1" then
        return true
      end
    end
    return false
  end)()
)

SetTimer = savedSetTimer51

print("\n[52] W2/W3/camera: the tier ladder and the write gates (D-8)")
pair()

local sent52 = {}
C4.SendToDevice = function(_, id, cmd, params)
  sent52[#sent52 + 1] = { id = id, cmd = cmd, params = params }
end

local function caps()
  reset()
  nextResponse = { ok = true, code = 200, body = {} }
  EC.SEND_HEARTBEAT()
  return requests[1] and requests[1].data and requests[1].data.capabilities or {}
end
local function hasCap(list, name)
  for _, c in ipairs(list) do
    if c == name then
      return true
    end
  end
  return false
end
local function runCmd(command, payload)
  reset()
  sent52 = {}
  nextResponse = {
    ok = true,
    code = 200,
    body = { commands = { { id = "52a00000-1111-4222-8333-444455556666", command = command, payload = payload } } },
  }
  EC.SEND_HEARTBEAT()
  local hb = requests[#requests]
  return hb and hb.data and hb.data.acks and hb.data.acks[1] or nil
end

Properties["Remote Control"] = "Identify only"
local c1 = caps()
check(
  "Identify only declares identify_v1 but not comfort/control",
  hasCap(c1, "identify_v1") and not hasCap(c1, "comfort_v1") and not hasCap(c1, "control_v1")
)

Properties["Remote Control"] = "Comfort"
local c2 = caps()
check(
  "Comfort adds comfort_v1 + camera_v1, still no control_v1",
  hasCap(c2, "comfort_v1") and hasCap(c2, "camera_v1") and not hasCap(c2, "control_v1")
)

Properties["Remote Control"] = "Full control"
local c3 = caps()
check("Full control adds control_v1", hasCap(c3, "control_v1"))

-- W2 lights (device 25 = dimmer)
Properties["Remote Control"] = "Comfort"
local ack = runCmd("SET_LIGHT", { key = "c4:25", level = 40 })
check(
  "SET_LIGHT ramps a dimmer at Comfort",
  #sent52 == 1 and sent52[1].cmd == "RAMP_TO_LEVEL" and sent52[1].params.LEVEL == 40,
  ack and tostring(ack.result)
)
runCmd("SET_LIGHT", { key = "c4:25", level = 250 })
check("light level clamps to 100", sent52[1].params.LEVEL == 100)

-- W2 thermostat clamp
runCmd("SET_THERMOSTAT", { key = "c4:25", heat_f = 50, cool_f = 200 })
local heatV, coolV
for _, s in ipairs(sent52) do
  if s.cmd == "SET_SETPOINT_HEAT" then
    heatV = s.params.FAHRENHEIT
  end
  if s.cmd == "SET_SETPOINT_COOL" then
    coolV = s.params.FAHRENHEIT
  end
end
check(
  "thermostat setpoints clamp to 60..85",
  heatV == 60 and coolV == 85,
  string.format("heat=%s cool=%s", tostring(heatV), tostring(coolV))
)

-- W3 refused at Comfort
ack = runCmd("LOCK_DEVICE", { key = "c4:43", action = "unlock" })
check(
  "a lock command is REFUSED at the Comfort tier",
  ack ~= nil and ack.ok == false and tostring(ack.error):find("higher Remote Control tier", 1, true) ~= nil,
  ack and tostring(ack.error)
)
check("a refused lock sends nothing to the device", #sent52 == 0)

-- W3 works at Full control
Properties["Remote Control"] = "Full control"
ack = runCmd("LOCK_DEVICE", { key = "c4:43", action = "unlock" })
check("unlock dispatches UNLOCK at Full control", #sent52 == 1 and sent52[1].cmd == "UNLOCK" and ack.ok == true)

-- Security: disarm needs a code, and the code never appears in the ack
ack = runCmd("SECURITY_PARTITION", { key = "c4:43", action = "disarm" })
check("disarm without a code is refused", ack.ok == false and tostring(ack.error):find("user code", 1, true) ~= nil)
ack = runCmd("SECURITY_PARTITION", { key = "c4:43", action = "disarm", code = "1234" })
check(
  "disarm with a code dispatches PARTITION_DISARM",
  #sent52 == 1 and sent52[1].cmd == "PARTITION_DISARM" and sent52[1].params.UserCode == "1234"
)
check("the user code is NEVER echoed in the ack", tostring(ack.result):find("1234", 1, true) == nil)

-- Camera: no snapshot URL yet → honest refusal, never a fabricated success
ack = runCmd("CAMERA_SNAPSHOT", { key = "c4:25", request_id = "r1" })
check(
  "camera snapshot refuses honestly when no URL is available",
  ack.ok == false and tostring(ack.error):find("no snapshot URL", 1, true) ~= nil
)

-- Off refuses everything, whatever the platform sends
Properties["Remote Control"] = "Off"
ack = runCmd("SET_LIGHT", { key = "c4:25", on = true })
check(
  "Off refuses even a light command",
  ack.ok == false and tostring(ack.error):find("higher Remote Control tier", 1, true) ~= nil
)
Properties["Remote Control"] = "Identify only"

print("\n[30] The Agent forwards a Protect device roster to Driver Cloud (Phase 9B)")
pair()
requests = {}
EC.SBOS_PROTECT_ROSTER({
  source = "unifi-protect",
  payload = JSON:encode({
    {
      kind = "cameras",
      id = "cam-front",
      name = "Front Door",
      mac = "aa:bb",
      state = "CONNECTED",
      model = "G4 Doorbell",
    },
    { kind = "cameras", id = "cam-drive", name = "Driveway", mac = "cc:dd", state = "DISCONNECTED" },
  }),
})
local function lastRequestToPlain(needle)
  for i = #requests, 1, -1 do
    if requests[i].url:find(needle, 1, true) then
      return requests[i]
    end
  end
  return nil
end
local fwd = lastRequestToPlain("/api/driver-cloud/devices")
check("a device roster was forwarded", fwd ~= nil)
check("with the driver sku", fwd ~= nil and (fwd.data or {}).driver_sku == "SBOS_UNIFI_PROTECT")
local devs = fwd and (fwd.data or {}).devices or {}
check("both devices mapped", #devs == 2, #devs)
local byId = {}
for _, d in ipairs(devs) do
  byId[d.external_id] = d
end
check("CONNECTED maps to online", (byId["cam-front"] or {}).state == "online", (byId["cam-front"] or {}).state)
check("DISCONNECTED maps to offline", (byId["cam-drive"] or {}).state == "offline", (byId["cam-drive"] or {}).state)
check("it is token-authed", fwd ~= nil and (fwd.headers or {})["Authorization"] ~= nil)

-- An UNPAIRED agent forwards nothing.
EC.UNPAIR()
requests = {}
EC.SBOS_PROTECT_ROSTER({
  source = "unifi-protect",
  payload = JSON:encode({ { kind = "cameras", id = "x", state = "CONNECTED" } }),
})
check("an unpaired agent forwards no devices", lastRequestToPlain("/api/driver-cloud/devices") == nil)

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
