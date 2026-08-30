-- Every global the Bond Bridge driver's libraries call must actually be
-- defined — the driver is loaded with NOTHING faked.
--
-- Same rationale as test_driver_globals.lua: `lib.http` calls the GLOBAL
-- `urlDo`, defined only by `drivers-common-public.global.url`, and only the
-- driver's own require list pulls that in. The SmartBuildOS connector shipped
-- once with that require missing and every HTTP request dead behind a
-- swallowed xpcall. This file is the one that fails if the require is ever
-- dropped from THIS driver.
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

-- url.lua builds a User-Agent from model and version; the shim returns nil.
function C4:GetDriverConfigInfo(key)
  return ({ model = "Bond Bridge Gateway", version = "1.0.0", minimum_os_version = "3.2.0" })[key]
end

-- The shim reports OS version "test", which fails CheckMinimumVersion and
-- disables the driver before anything under test runs.
function C4:GetVersionInfo()
  return { version = "4.0.0" }
end

-- With OS ≥ 3.0.0 reported, url.lua takes its NEW transfer API — the only
-- path a real controller takes. Recorded, never dispatched.
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
function C4:CreateNetworkConnection() end
function C4:NetPortOptions() end
function C4:NetConnect() end
function C4:NetDisconnect() end
function C4:GetBindingAddress() end
function C4:FireEvent() end
function C4:AddEvent() end
function C4:SetConditionalState() end

Properties = {
  ["Bond Address"] = "192.168.1.50",
  ["Local Token"] = "",
  ["Device Poll Interval"] = "1m",
  ["Push Updates"] = "On",
  ["Driver Status"] = "Starting",
  ["Connection Status"] = "",
  ["Bond ID"] = "-",
  ["Model"] = "-",
  ["Firmware"] = "-",
  ["Devices"] = "-",
  ["Push Status"] = "Off",
  ["Last Sync"] = "Never",
  ["License Status"] = "-",
  ["License Source"] = "-",
  ["Log Level"] = "3 - Info",
  ["Log Mode"] = "Off",
}

package.path = "./drivers/bond-bridge/?.lua;" .. package.path
dofile("drivers/bond-bridge/driver.lua")

print("\n[1] Globals the driver's own libraries call")

check("urlDo is defined (lib.http calls it on every request)", type(urlDo) == "function", type(urlDo))
check("SetTimer is defined", type(SetTimer) == "function", type(SetTimer))
check("CancelTimer is defined", type(CancelTimer) == "function", type(CancelTimer))
check("ONE_SECOND is defined", type(ONE_SECOND) == "number", type(ONE_SECOND))
check("OPC dispatch table exists", type(OPC) == "table", type(OPC))
check("EC dispatch table exists", type(EC) == "table", type(EC))
check("TC dispatch table exists", type(TC) == "table", type(TC))
check("RFP dispatch table exists", type(RFP) == "table", type(RFP))
check("UpdateProperty is defined", type(UpdateProperty) == "function", type(UpdateProperty))
check("CheckMinimumVersion is defined", type(CheckMinimumVersion) == "function", type(CheckMinimumVersion))
check("Serialize is defined (persist depends on it)", type(Serialize) == "function", type(Serialize))
check("SendToDevice is defined (child protocol depends on it)", type(SendToDevice) == "function", type(SendToDevice))
check("SendToProxy is defined", type(SendToProxy) == "function", type(SendToProxy))

print("\n[2] The driver's entry points are registered")

for _, name in ipairs({
  "TEST_CONNECTION",
  "SYNC_DEVICES",
  "FETCH_TOKEN",
  "FORGET_TOKEN",
  "PRINT_INVENTORY",
  "PRINT_DEVICE_BINDINGS",
  "PRUNE_STALE_DEVICES",
  "AUTO_CONFIGURE_DEVICES",
  "AUTO_RENAME_BOUND_DRIVERS",
  "REFRESH_LICENSE",
  "BOND_GET_DEVICE",
  "BOND_ACTION",
  "RUN_BOND_ACTION",
}) do
  check(string.format("EC.%s is callable", name), type(EC[name]) == "function", type(EC[name]))
end

for _, name in ipairs({
  "Local_Token",
  "Bond_Address",
  "Device_Poll_Interval",
  "Push_Updates",
  "Log_Level",
  "Log_Mode",
}) do
  check(string.format("OPC.%s is callable", name), type(OPC[name]) == "function", type(OPC[name]))
end

check("RFP.BOND_GET_DEVICE is callable", type(RFP.BOND_GET_DEVICE) == "function")
check("TC.BOND_CONNECTED is callable", type(TC.BOND_CONNECTED) == "function")
check("Local Token value logging is suppressed", OPC.suppressDebug ~= nil and OPC.suppressDebug["Local Token"] == true)

print("\n[3] The real transport is reachable, not just present")

-- Proves the whole chain resolves: driver → bond.api → lib.http → urlDo →
-- C4:url. The missing require breaks it at the third hop, and only a call
-- that traverses all four can show that. Pasting a token is that call.
OnDriverInit()
OnDriverLateInit()

dispatched = {}
Properties["Local Token"] = "globals-test-token"
local ok, err = pcall(OnPropertyChanged, "Local Token")
check("pasting a token does not throw", ok, err)
check("it reached the C4 url transfer API", #dispatched >= 1, #dispatched)
local first = dispatched[1] or {}
check(
  "GET against the Bond Local API over PLAIN HTTP",
  first.method == "GET" and tostring(first.url):find("http://192.168.1.50/v2/sys/version", 1, true) ~= nil,
  tostring(first.url)
)

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
