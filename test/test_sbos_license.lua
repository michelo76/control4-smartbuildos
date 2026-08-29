-- Tests for src/sbos/license.lua — the SmartBuildOS licensing SDK — and the
-- Agent protocol it speaks. The SDK is exercised standalone (it needs only
-- the C4 surface), and the Agent side is asserted through the same message
-- shapes the connector's EC handlers implement. Invariants:
--
--   * A missing Agent is LOUD (property says AGENT REQUIRED) but never
--     enforcement: status stays LEGACY and the driver operates (D3).
--   * Registration finds the Agent by EXACT driver filename.
--   * The entitlement reply updates status/features/property; an unknown
--     status degrades to CLOUD_VALIDATION_REQUIRED, never to a crash.
--   * Feature checks: everything granted under LEGACY; only listed
--     features granted under a real status.
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
require("c4_shim")

local props = {}
function UpdateProperty(name, value)
  props[name] = value
end

local deviceSent = {}
function SendToDevice(deviceId, command, params)
  table.insert(deviceSent, { device = deviceId, command = command, params = params })
end

function C4:GetDriverConfigInfo(key)
  return ({ version = "20260828.1" })[key]
end

local PROJECT = {}
function C4:GetDevices()
  return PROJECT
end

local license = require("sbos.license")

print("\n[1] No Agent in the project: loud, legacy, operational")

license._reset()
license.setup({ sku = "SBOS_UNIFI_PROTECT" })
check("status is LEGACY", license.status() == "LEGACY", license.status())
check("still operational", license.isOperational() == true)
check(
  "property shouts AGENT REQUIRED",
  tostring(props["License Status"]):find("AGENT REQUIRED", 1, true) ~= nil,
  props["License Status"]
)
check("no message went anywhere", #deviceSent == 0, #deviceSent)
check("every feature granted under LEGACY", license.hasFeature("ANYTHING") == true)

print("\n[2] Agent found by exact filename; registration carries sku+version")

PROJECT = {
  [901] = { deviceName = "Camera", driverFileName = "smartbuildos-insights.c4z" }, -- the near-miss
  [900] = { deviceName = "Agent", driverFileName = "smartbuildos.c4z" },
}
license._reset()
deviceSent = {}
license.setup({ sku = "SBOS_UNIFI_PROTECT" })
check("exactly one registration", #deviceSent == 1, #deviceSent)
check("to the AGENT, not the insights sibling", deviceSent[1].device == 900, deviceSent[1].device)
check("as SBOS_REGISTER_DRIVER", deviceSent[1].command == "SBOS_REGISTER_DRIVER")
check("with the sku", (deviceSent[1].params or {}).sku == "SBOS_UNIFI_PROTECT")
check("and the running version", (deviceSent[1].params or {}).version == "20260828.1")
check("and the requester id", (deviceSent[1].params or {}).requester == "12345")

print("\n[3] Entitlement replies drive status, property and features")

license.onEntitlement({
  sku = "SBOS_UNIFI_PROTECT",
  status = "AUTHORIZED_SUBSCRIPTION",
  license_type = "SUBSCRIPTION_INCLUDED",
  features = "BASE,EVENTS,DOORBELL",
  company = "Premium Audio And Video",
})
check("status updated", license.status() == "AUTHORIZED_SUBSCRIPTION")
check(
  "property reads as the subscription",
  tostring(props["License Status"]):find("Subscription Included", 1, true) ~= nil,
  props["License Status"]
)
check("listed feature granted", license.hasFeature("EVENTS") == true)
check("unlisted feature refused", license.hasFeature("AI_EVENTS") == false)

license.onEntitlement({ sku = "SBOS_UNIFI_NETWORK", status = "NOT_ENTITLED" })
check("a reply for ANOTHER sku is ignored", license.status() == "AUTHORIZED_SUBSCRIPTION")

license.onEntitlement({ sku = "SBOS_UNIFI_PROTECT", status = "AUTHORIZED_GRACE", grace_until = "2026-09-07" })
check(
  "grace shows its end date",
  tostring(props["License Status"]):find("2026-09-07", 1, true) ~= nil,
  props["License Status"]
)
check("grace is operational", license.isOperational() == true)

license.onEntitlement({ sku = "SBOS_UNIFI_PROTECT", status = "NOT_ENTITLED" })
check("NOT_ENTITLED is not operational", license.isOperational() == false)
check("and refuses features", license.hasFeature("BASE") == false)

license.onEntitlement({ sku = "SBOS_UNIFI_PROTECT", status = "SOMETHING_FROM_THE_FUTURE" })
check(
  "unknown status degrades to CLOUD_VALIDATION_REQUIRED",
  license.status() == "CLOUD_VALIDATION_REQUIRED",
  license.status()
)

print("\n[4] check() re-asks the Agent")

deviceSent = {}
license.check()
check("SBOS_CHECK_ENTITLEMENT sent", #deviceSent == 1 and deviceSent[1].command == "SBOS_CHECK_ENTITLEMENT")

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
