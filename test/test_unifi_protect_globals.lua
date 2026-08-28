-- Every global the UniFi Protect driver's libraries call must actually be
-- defined — the driver is loaded with NOTHING faked.
--
-- Same rationale as test_driver_globals.lua: `lib.http` calls the GLOBAL
-- `urlDo`, defined only by `drivers-common-public.global.url`, and only the
-- driver's own require list pulls that in. The SmartBuildOS connector shipped
-- once with that require missing and every HTTP request dead behind a
-- swallowed xpcall — through four rounds of green tests, because the logic
-- suite (rightly) fakes the transport. This file is the one that fails if the
-- require is ever dropped from THIS driver.
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

-- The DRIVERCENTRAL branch of OnDriverInit requires this; the oss build strips
-- it at preprocess time, and this stub stands in for the strip.
package.preload["cloud-client-byte"] = function()
  return {}
end

require("c4_shim")

-- The shim's GetDriverConfigInfo returns nil for everything, but url.lua
-- builds a User-Agent from model and version, so it would throw on the nil
-- rather than on anything this test is about.
function C4:GetDriverConfigInfo(key)
  return ({ model = "UniFi Protect Gateway", version = "1.0.0", minimum_os_version = "3.3.2" })[key]
end

-- The shim reports OS version "test", which fails CheckMinimumVersion and
-- disables the driver before anything under test runs.
function C4:GetVersionInfo()
  return { version = "4.0.0" }
end

-- The shim does not stub the C4 url surface. With an OS version ≥ 3.0.0
-- reported (see GetVersionInfo above), url.lua takes its NEW transfer API —
-- `C4:url()` returning a transfer object — which is the only path a real
-- controller on 3.3.2+ ever takes, so that is the one this test stubs.
-- Nothing leaves the machine: the transfer is recorded, never dispatched, and
-- no response is ever delivered.
local dispatched = {}
local function makeTransfer()
  local t = { options = nil }
  function t:SetOptions(options)
    self.options = options
    return self
  end
  function t:OnDone()
    return self
  end
  local function record(method, url, headers, data)
    dispatched[#dispatched + 1] = { method = method, url = url, headers = headers, data = data, options = t.options }
    return t
  end
  function t:Get(url, headers)
    return record("GET", url, headers)
  end
  function t:Post(url, data, headers)
    return record("POST", url, headers, data)
  end
  function t:Put(url, data, headers)
    return record("PUT", url, headers, data)
  end
  function t:Delete(url, headers)
    return record("DELETE", url, headers)
  end
  function t:Custom(url, method, data, headers)
    return record(method, url, headers, data)
  end
  return t
end
function C4:url()
  return makeTransfer()
end
function C4:AddDynamicBinding() end
function C4:RemoveDynamicBinding() end

Properties = {
  ["Console Address"] = "https://192.168.4.1",
  ["API Key"] = "",
  ["Verify TLS Certificate"] = "Off",
  ["Device Poll Interval"] = "1m",
  ["Driver Status"] = "Starting",
  ["Connection Status"] = "",
  ["Log Level"] = "3 - Info",
  ["Log Mode"] = "Off",
}

package.path = "./drivers/unifi-protect/?.lua;" .. package.path
dofile("drivers/unifi-protect/driver.lua")

print("\n[1] Globals the driver's own libraries call")

check("urlDo is defined (lib.http calls it on every request)", type(urlDo) == "function", type(urlDo))
check("SetTimer is defined", type(SetTimer) == "function", type(SetTimer))
check("CancelTimer is defined", type(CancelTimer) == "function", type(CancelTimer))
check("ONE_SECOND is defined", type(ONE_SECOND) == "number", type(ONE_SECOND))
check("ONE_HOUR is defined (Log Mode expiry uses it)", type(ONE_HOUR) == "number", type(ONE_HOUR))
check("OPC dispatch table exists", type(OPC) == "table", type(OPC))
check("EC dispatch table exists", type(EC) == "table", type(EC))
check("TC dispatch table exists", type(TC) == "table", type(TC))
check("UpdateProperty is defined", type(UpdateProperty) == "function", type(UpdateProperty))
check("CheckMinimumVersion is defined", type(CheckMinimumVersion) == "function", type(CheckMinimumVersion))
check("Serialize is defined (persist depends on it)", type(Serialize) == "function", type(Serialize))

print("\n[2] The driver's entry points are registered")

for _, name in ipairs({
  "TEST_CONNECTION",
  "SYNC_DEVICES",
  "PRINT_INVENTORY",
  "PRUNE_STALE_CAMERAS",
  "FORGET_API_KEY",
}) do
  check(string.format("EC.%s is callable", name), type(EC[name]) == "function", type(EC[name]))
end

for _, name in ipairs({
  "API_Key",
  "Console_Address",
  "Verify_TLS_Certificate",
  "Device_Poll_Interval",
  "Log_Level",
  "Log_Mode",
}) do
  check(string.format("OPC.%s is callable", name), type(OPC[name]) == "function", type(OPC[name]))
end

check("TC.UNIFI_PROTECT_CONNECTED is callable", type(TC.UNIFI_PROTECT_CONNECTED) == "function")
check("API Key value logging is suppressed", OPC.suppressDebug ~= nil and OPC.suppressDebug["API Key"] == true)

print("\n[3] The real transport is reachable, not just present")

-- Proves the whole chain resolves: driver → unifi.protect → lib.http → urlDo →
-- C4:urlGet. The missing require breaks it at the third hop, and only a call
-- that traverses all four can show that. Pasting a key is that call: the
-- letterbox handler stores it (real persist, shim-backed) and fires the
-- connection test.
OnDriverInit()
OnDriverLateInit()

Properties["API Key"] = "globals-test-key"
local ok, err = pcall(OnPropertyChanged, "API Key")
check("pasting an API key does not throw", ok, err)
check("it reached the C4 url transfer API", #dispatched >= 1, #dispatched)
local first = dispatched[1] or {}
check(
  "GET against the Integration API",
  first.method == "GET" and tostring(first.url):find("/proxy/protect/integration/v1/meta/info", 1, true) ~= nil,
  tostring(first.url)
)
check("X-API-KEY header carried", (first.headers or {})["X-API-KEY"] == "globals-test-key")
check(
  "ssl verification disabled via SetOptions (self-signed console)",
  type(first.options) == "table" and first.options.ssl_verify_host == false and first.options.ssl_verify_peer == false,
  type(first.options)
)

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
