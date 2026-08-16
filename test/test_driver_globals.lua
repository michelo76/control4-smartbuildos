-- Every global the driver's libraries call must actually be defined.
--
-- ── WHY THIS EXISTS ─────────────────────────────────────────────────────────
--
-- `lib.http` calls the GLOBAL `urlDo`, defined by
-- `drivers-common-public.global.url`. Nothing in `lib/http.lua` requires that
-- module — the dependency is implicit, satisfied only if the DRIVER requires it.
--
-- It did not. The driver shipped calling `urlDo` without ever defining it, so
-- every HTTP request threw "attempt to call a nil value" inside the handler's
-- xpcall, which prints the error and swallows it. The visible symptom was a
-- pairing attempt stuck on "Pairing..." forever: the status set before the call
-- was the last thing that ever ran. No request had ever worked.
--
-- test_smartbuildos_connector.lua could not catch it. That file replaces
-- `lib.http` with a fake to assert on payloads, which is the right way to test
-- the driver's decisions — and it means the real transport, and its unmet
-- dependency, were never loaded.
--
-- So this file deliberately loads the driver with NOTHING faked, and asserts the
-- globals its libraries reach for are present. Any future `require` that gets
-- dropped, or any new library with an implicit global dependency, fails here.
--
-- Run from the driver root:
--   make test

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

C4 = C4 or {}
function C4:GetNetworkConnections()
  return {}
end
function C4:GetSystemType()
  return "XDT_EA5"
end
function C4:FireEvent() end
function C4:CreatePingClient()
  return nil
end

require("c4_shim")

-- The shim's C4:GetDriverConfigInfo returns nil for everything, but url.lua
-- builds a User-Agent by concatenating model and version, so it would throw on
-- the nil rather than on anything this test is about. A real controller returns
-- strings here.
function C4:GetDriverConfigInfo(key)
  return ({ model = "SmartBuildOS Connector", version = "1.0.0", minimum_os_version = "3.3.1" })[key]
end

-- The shim does not stub the C4 Curl surface that url.lua drives. Each of these
-- returns a TICKET id on a controller; url.lua treats 0/nil as "could not
-- start" and invokes the callback with an error, so a truthy value is what keeps
-- the happy path under test. Nothing leaves the machine — the request is never
-- actually dispatched, and no response is ever delivered.
local dispatched = {}
function C4:urlPost(url, data, headers)
  dispatched[#dispatched + 1] = { "POST", url, data, headers }
  return 1
end
function C4:urlGet(url, headers)
  dispatched[#dispatched + 1] = { "GET", url, headers }
  return 1
end
function C4:urlPut()
  return 1
end
function C4:urlDelete()
  return 1
end
function C4:urlCustom()
  return 1
end
function C4:urlGetCookies()
  return {}
end

Properties = {
  ["API URL"] = "https://app.smartbuildos.io",
  ["Pairing Code"] = "",
  ["Log Level"] = "3 - Info",
  ["Log Mode"] = "Off",
}

package.path = "./drivers/smartbuildos/?.lua;" .. package.path
dofile("drivers/smartbuildos/driver.lua")

print("\n[1] Globals the driver's own libraries call")

-- The one that actually broke. `lib.http` calls it on every request.
check("urlDo is defined (lib.http calls it on every request)", type(urlDo) == "function", type(urlDo))

-- From drivers-common-public.global.timer, used by every scheduling path here.
check("SetTimer is defined", type(SetTimer) == "function", type(SetTimer))
check("CancelTimer is defined", type(CancelTimer) == "function", type(CancelTimer))
check("ONE_SECOND is defined", type(ONE_SECOND) == "number", type(ONE_SECOND))

-- From drivers-common-public.global.handlers — the dispatch tables the driver
-- hangs every entry point on. A missing require here means Composer's actions
-- and property edits silently do nothing.
check("OPC dispatch table exists", type(OPC) == "table", type(OPC))
check("EC dispatch table exists", type(EC) == "table", type(EC))
check("TC dispatch table exists", type(TC) == "table", type(TC))
check("UpdateProperty is defined", type(UpdateProperty) == "function", type(UpdateProperty))

-- From lib.utils.
check("CheckMinimumVersion is defined", type(CheckMinimumVersion) == "function", type(CheckMinimumVersion))
check("tointeger is defined", type(tointeger) == "function", type(tointeger))
check("IsEmpty is defined", type(IsEmpty) == "function", type(IsEmpty))

print("\n[2] The driver's own entry points are registered")

for _, name in ipairs({
  "TEST_CONNECTION",
  "SEND_HEARTBEAT",
  "SEND_FULL_SYNC",
  "POLL_DEVICES",
  "UNPAIR",
  "SEND_EVENT",
  "REPORT_DIAGNOSTICS",
  "REPORT_TELEMETRY_SURVEY",
}) do
  check(string.format("EC.%s is callable", name), type(EC[name]) == "function", type(EC[name]))
end

for _, name in ipairs({
  "Pairing_Code",
  "API_URL",
  "Log_Level",
  "Log_Mode",
  "Device_Poll_Interval",
  "Non_Control4_Devices",
}) do
  check(string.format("OPC.%s is callable", name), type(OPC[name]) == "function", type(OPC[name]))
end

check("TC.SMARTBUILDOS_CONNECTED is callable", type(TC.SMARTBUILDOS_CONNECTED) == "function")
check("TC.SMARTBUILDOS_PAIRED is callable", type(TC.SMARTBUILDOS_PAIRED) == "function")

-- Director calls this by name for every registered system event. A rename or a
-- missing definition means pushed online/offline silently stops working and only
-- the poll keeps the data alive.
check("OnSystemEvent is defined for Director to call", type(OnSystemEvent) == "function", type(OnSystemEvent))

print("\n[3] The real transport is reachable, not just present")

-- Proves the whole chain resolves: driver → lib.http → urlDo → C4:urlPost. The
-- missing require broke it at the third hop, and only a call that actually
-- traverses all four can show that.
local http = require("lib.http")
local ok, err = pcall(function()
  return http:post("https://example.invalid/probe", { probe = true }, { ["Content-Type"] = "application/json" })
end)
check("a POST through lib.http does not throw", ok, err)
check("it reached the C4 Curl API", #dispatched == 1 and dispatched[1][1] == "POST", #dispatched)
check(
  "with the URL it was given",
  (dispatched[1] or {})[2] == "https://example.invalid/probe",
  (dispatched[1] or {})[2]
)

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
