-- Tests for drivers/smartbuildos/driver.lua.
--
-- The driver is loaded against a fake `lib.http`, so every assertion is about
-- what the driver *decided to send* and what state it moved to -- no network,
-- no controller. The invariants under test are the ones a controller in the
-- field would otherwise be the first to discover:
--
--   * Connected/Disconnected fire on a TRANSITION only. Firing per-heartbeat
--     would page a dealer every 15 minutes for one offline site.
--   * A non-2xx must surface its status code. Http:request rejects on any
--     non-2xx as well as on transport failure, so a handler that assumes
--     "rejected == unreachable" reports a revoked token as a network outage
--     and sends the dealer to the wrong system.
--   * The bearer token never reaches the log.
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

--- Events the driver fired, in order.
--- @type string[]
local firedEvents = {}
--- Every line the driver logged, so the token-redaction test has something to
--- search. C4:DebugLog and C4:ErrorLog are where the logging lib lands.
--- @type string[]
local logLines = {}

C4 = C4 or {}

local PROJECT = {
  [10] = { name = "Living Room TV", model = "SR-260", manufacturer = "Control4", filename = "tv.c4z" },
  [11] = { name = "Kitchen Keypad", model = "C4-KC120277", manufacturer = "Control4", filename = "keypad.c4z" },
}

function C4:GetDevices()
  return PROJECT
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

require("c4_shim")

-- ─── Load the driver ──────────────────────────────────────────────────────────

local TOKEN = "sbo_live_supersecrettoken_0123456789"

Properties = {
  ["API URL"] = "",
  ["Device Token"] = "",
  ["Property ID"] = "",
  ["Connection Status"] = "Not configured",
  ["Last Successful Sync"] = "Never",
  ["Heartbeat Interval"] = "15m",
  ["Inventory Interval"] = "24h",
  ["Report Device Inventory"] = "On",
  ["Automatic Updates"] = "On",
  ["Update Channel"] = "Production",
  ["Driver Status"] = "",
  ["Driver Version"] = "",
  ["Log Level"] = "3 - Info",
  ["Log Mode"] = "Off",
}

--- UpdateProperty writes back into Properties on a real controller; the shim's
--- C4:UpdateProperty is a no-op, so mirror it here or Connection Status assertions
--- read a stale table.
function C4:UpdateProperty(name, value)
  Properties[name] = value
end

package.path = "./drivers/smartbuildos/?.lua;" .. package.path
dofile("drivers/smartbuildos/driver.lua")

--- Puts the driver into a fully configured, initialized state without running
--- OnDriverLateInit (which would arm real timers and fire an opening sync).
local function configure()
  Properties["API URL"] = "https://app.smartbuildos.com"
  Properties["Device Token"] = TOKEN
  Properties["Property ID"] = "0f1c9a52-7d33-4f0e-9a11-2b6c8d4e5f00"
  gInitialized = true
end

local function reset()
  requests = {}
  firedEvents = {}
  logLines = {}
  nextResponse = { ok = true, code = 200 }
end

-- ─── Tests ────────────────────────────────────────────────────────────────────

print("\n[1] An unconfigured driver sends nothing and says why")
reset()
Properties["API URL"] = ""
Properties["Device Token"] = ""
Properties["Property ID"] = ""
gInitialized = true
EC.SEND_HEARTBEAT()
check("no request was made", #requests == 0, #requests)
check(
  "Connection Status names the missing property",
  (Properties["Connection Status"] or ""):find("API URL is not set", 1, true) ~= nil,
  Properties["Connection Status"]
)

print("\n[2] A configured heartbeat posts to the ingest URL with a bearer token")
reset()
configure()
EC.SEND_HEARTBEAT()
check("exactly one request", #requests == 1, #requests)
local req = requests[1] or {}
check(
  "URL is the heartbeat ingest path",
  req.url == "https://app.smartbuildos.com/api/integrations/control4/heartbeat",
  req.url
)
check("Authorization is the bearer token", (req.headers or {})["Authorization"] == "Bearer " .. TOKEN)
check("property id travels in the header", (req.headers or {})["X-SmartBuildOS-Property"] == Properties["Property ID"])
check("payload is tagged as a heartbeat", (req.data or {}).kind == "heartbeat", (req.data or {}).kind)
check("payload carries the system identity", ((req.data or {}).system or {}).controller_type == "XDT_EA5")
check("Connection Status is Connected", Properties["Connection Status"] == "Connected", Properties["Connection Status"])

print("\n[3] A trailing slash on API URL does not produce a double slash")
reset()
configure()
Properties["API URL"] = "https://app.smartbuildos.com/"
EC.SEND_HEARTBEAT()
check(
  "URL has exactly one slash before /api",
  (requests[1] or {}).url == "https://app.smartbuildos.com/api/integrations/control4/heartbeat",
  (requests[1] or {}).url
)

print("\n[4] Connected/Disconnected fire on transition only")
reset()
configure()
-- Earlier tests left the driver connected. Drive it down first so the run below
-- genuinely starts from "disconnected" rather than silently testing nothing.
nextResponse = { ok = false, code = 500, error = "boom" }
EC.SEND_HEARTBEAT()
reset()
configure()
EC.SEND_HEARTBEAT() -- disconnected -> connected: one Connected
EC.SEND_HEARTBEAT() -- still connected: silent
EC.SEND_HEARTBEAT()
check(
  "one Connected for three successes",
  #firedEvents == 1 and firedEvents[1] == "Connected",
  table.concat(firedEvents, ",")
)

nextResponse = { ok = false, code = 500, error = "boom" }
EC.SEND_HEARTBEAT() -- connected -> disconnected
EC.SEND_HEARTBEAT() -- still disconnected: no second Disconnected
local disconnects = 0
for _, e in ipairs(firedEvents) do
  if e == "Disconnected" then
    disconnects = disconnects + 1
  end
end
check("exactly one Disconnected for two consecutive failures", disconnects == 1, disconnects)

print("\n[5] A non-2xx reports its status code, not 'Unreachable'")
reset()
configure()
nextResponse = { ok = false, code = 401, body = "revoked" }
EC.SEND_HEARTBEAT()
check("Connection Status is HTTP 401", Properties["Connection Status"] == "HTTP 401", Properties["Connection Status"])
check("Sync Failed fired", firedEvents[#firedEvents] == "Sync Failed", table.concat(firedEvents, ","))

print("\n[6] A transport failure with no status code reads as Unreachable")
reset()
configure()
nextResponse = { ok = false, code = nil, error = "dns failure" }
EC.SEND_HEARTBEAT()
check(
  "Connection Status is Unreachable",
  Properties["Connection Status"] == "Unreachable",
  Properties["Connection Status"]
)

print("\n[7] Inventory reports the project, and honours the Off switch")
reset()
configure()
EC.SEND_INVENTORY()
local devices = ((requests[1] or {}).data or {}).devices or {}
check("both project devices are reported", #devices == 2, #devices)
check("device carries name and model", devices[1].name ~= nil and devices[1].model ~= nil)

reset()
configure()
Properties["Report Device Inventory"] = "Off"
EC.SEND_INVENTORY()
check("device list is empty when reporting is off", #(((requests[1] or {}).data or {}).devices or {}) == 0)
Properties["Report Device Inventory"] = "On"

print("\n[8] SEND_EVENT requires a name")
reset()
configure()
EC.SEND_EVENT({ NAME = "", DETAIL = "ignored" })
check("an unnamed event sends nothing", #requests == 0, #requests)

EC.SEND_EVENT({ NAME = "Rack Door Opened", DETAIL = "north rack" })
check(
  "a named event posts to the event path",
  (requests[1] or {}).url:find("/control4/event$") ~= nil,
  (requests[1] or {}).url
)
check("event name is in the payload", ((requests[1] or {}).data or {}).name == "Rack Door Opened")

print("\n[9] The conditional tracks connection state")
reset()
configure()
EC.SEND_HEARTBEAT()
check("conditional is true while connected", TC.SMARTBUILDOS_CONNECTED() == true)
nextResponse = { ok = false, code = 503 }
EC.SEND_HEARTBEAT()
check("conditional is false once disconnected", TC.SMARTBUILDOS_CONNECTED() == false)

print("\n[10] The device token never reaches the log")
reset()
configure()
Properties["Log Mode"] = "Print and Log"
Properties["Log Level"] = "6 - Ultra"
OnPropertyChanged("Log Mode")
OnPropertyChanged("Log Level")
EC.SEND_HEARTBEAT()
OPC.Device_Token(TOKEN)
local leaked = false
for _, line in ipairs(logLines) do
  if line:find(TOKEN, 1, true) then
    leaked = true
  end
end
check("no log line contains the token", not leaked, "token appeared in " .. #logLines .. " log lines")
Properties["Log Mode"] = "Off"

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
