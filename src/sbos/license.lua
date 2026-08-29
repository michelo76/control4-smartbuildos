--- SmartBuildOS licensing SDK — the one implementation every SmartBuildOS
--- driver uses to talk to the SmartBuildOS Agent.
---
--- Design per docs/driver-cloud-charter.md: the Agent (the SmartBuildOS
--- Connector driver, `smartbuildos.c4z`) is the local licensing authority;
--- dependent drivers never call licensing APIs themselves and never hold
--- account credentials. Transport is the proven bindingless device path:
--- exact-filename discovery + SendToDevice → the Agent's EC handlers.
---
--- BACKWARD COMPATIBILITY (charter D3): status starts as LEGACY and the
--- driver operates normally. An Agent that predates licensing simply never
--- answers, and that must never dark a working installation. Enforcement
--- policies arrive per-driver in later releases, driven by real statuses
--- from the entitlement backend.
---
--- Usage from a driver:
---   local license = require("sbos.license")
---   license.setup({ sku = "SBOS_UNIFI_PROTECT" })   -- in OnDriverLateInit
---   EC.SBOS_ENTITLEMENT = license.onEntitlement      -- the Agent's reply
---   -- license.status() / license.hasFeature("EVENTS") anywhere after.

local log = require("lib.logging")

local M = {}

--- Statuses the Agent can answer with (charter vocabulary, fixed).
M.STATUSES = {
  AUTHORIZED_SUBSCRIPTION = true,
  AUTHORIZED_PERPETUAL = true,
  AUTHORIZED_GRACE = true,
  TRIAL = true,
  NOT_ENTITLED = true,
  AGENT_UNAUTHENTICATED = true,
  ACCOUNT_SUSPENDED = true,
  ENTITLEMENT_EXPIRED = true,
  CONTROLLER_MISMATCH = true,
  CLOUD_VALIDATION_REQUIRED = true,
  LEGACY = true,
}

--- Statuses under which a driver operates normally today. Enforcement
--- narrowing happens per-driver, per-release — never here by surprise.
local OPERATIONAL = {
  AUTHORIZED_SUBSCRIPTION = true,
  AUTHORIZED_PERPETUAL = true,
  AUTHORIZED_GRACE = true,
  TRIAL = true,
  LEGACY = true,
}

--- Human labels for the standardized License Status property.
local LABELS = {
  AUTHORIZED_SUBSCRIPTION = "Authorized - Subscription Included",
  AUTHORIZED_PERPETUAL = "Authorized - Perpetual License",
  AUTHORIZED_GRACE = "Grace Period",
  TRIAL = "Trial",
  NOT_ENTITLED = "Not Licensed - see SmartBuildOS",
  AGENT_UNAUTHENTICATED = "SmartBuildOS Agent Not Authenticated",
  ACCOUNT_SUSPENDED = "Account Suspended",
  ENTITLEMENT_EXPIRED = "License Expired",
  CONTROLLER_MISMATCH = "License Belongs To Another Controller",
  CLOUD_VALIDATION_REQUIRED = "Cloud Validation Required",
  LEGACY = "Authorized - Licensing Not Yet Enforced",
  AGENT_MISSING = "SMARTBUILDOS AGENT REQUIRED",
}

local state = {
  sku = "",
  version = "",
  agentDeviceId = nil,
  status = "LEGACY",
  licenseType = "",
  features = {},
  company = "",
  graceUntil = "",
  checkedAt = "",
  statusProperty = "License Status",
}

--- Finds the Agent by its driver FILE — exact match, the same discovery
--- rule every SmartBuildOS driver uses (a substring would catch siblings).
--- @return number|nil agentDeviceId
local function findAgent()
  if state.agentDeviceId ~= nil then
    return state.agentDeviceId
  end
  local ok, devices = pcall(function()
    return C4:GetDevices({})
  end)
  if not ok or type(devices) ~= "table" then
    return nil
  end
  for rawId, device in pairs(devices) do
    local id = tonumber(rawId)
    local file = tostring((type(device) == "table" and device.driverFileName) or "")
    if id ~= nil and (file == "smartbuildos.c4z" or file == "smartbuildos.c4i") then
      state.agentDeviceId = id
      return id
    end
  end
  return nil
end

local function publishStatus()
  local label = LABELS[state.status] or state.status
  if state.status == "AUTHORIZED_GRACE" and state.graceUntil ~= "" then
    label = label .. " until " .. state.graceUntil
  end
  pcall(function()
    UpdateProperty(state.statusProperty, label)
  end)
end

--- Registers this driver with the Agent. Called from setup and safe to
--- re-call (the Agent's inventory is keyed by sku + device id).
function M.register()
  local agent = findAgent()
  if agent == nil then
    -- Absent Agent = the one state that must be LOUD but not (yet)
    -- enforcement: existing installs predate the Agent requirement.
    state.status = "LEGACY"
    pcall(function()
      UpdateProperty(state.statusProperty, LABELS.AGENT_MISSING .. " (running in legacy mode)")
    end)
    log:warn("SmartBuildOS Agent not found in this project - install smartbuildos.c4z")
    return false
  end
  SendToDevice(agent, "SBOS_REGISTER_DRIVER", {
    sku = state.sku,
    version = state.version,
    requester = tostring(C4:GetDeviceID()),
  })
  return true
end

--- Re-asks the Agent for this driver's entitlement.
function M.check()
  local agent = findAgent()
  if agent == nil then
    return
  end
  SendToDevice(agent, "SBOS_CHECK_ENTITLEMENT", {
    sku = state.sku,
    requester = tostring(C4:GetDeviceID()),
  })
end

--- The Agent's SBOS_ENTITLEMENT reply. Wire as EC.SBOS_ENTITLEMENT.
--- @param tParams table {sku, status, license_type, features, company, grace_until, checked_at}
function M.onEntitlement(tParams)
  tParams = tParams or {}
  if tostring(tParams.sku or "") ~= state.sku then
    return
  end
  local status = tostring(tParams.status or "")
  if not M.STATUSES[status] then
    log:warn("Unknown entitlement status '%s' - treating as CLOUD_VALIDATION_REQUIRED", status)
    status = "CLOUD_VALIDATION_REQUIRED"
  end
  state.status = status
  state.licenseType = tostring(tParams.license_type or "")
  state.company = tostring(tParams.company or "")
  state.graceUntil = tostring(tParams.grace_until or "")
  state.checkedAt = tostring(tParams.checked_at or "")
  state.features = {}
  for feature in tostring(tParams.features or ""):gmatch("[^,]+") do
    state.features[feature] = true
  end
  publishStatus()
  log:info("Entitlement for %s: %s", state.sku, status)
end

--- Configures and performs the first registration.
--- @param opts table {sku, version?, statusProperty?}
function M.setup(opts)
  opts = opts or {}
  state.sku = tostring(opts.sku or "")
  state.statusProperty = tostring(opts.statusProperty or "License Status")
  state.version = tostring(opts.version or "")
  if state.version == "" then
    pcall(function()
      state.version = tostring(C4:GetDriverConfigInfo("version"))
    end)
  end
  publishStatus()
  M.register()
end

--- Current status string (charter vocabulary, or LEGACY before any answer).
function M.status()
  return state.status
end

--- Whether the driver should operate normally under the current status.
--- Drivers that adopt enforcement consult this; today every shipped driver
--- treats false as "warn loudly", per the migration plan.
function M.isOperational()
  return OPERATIONAL[state.status] == true
end

--- Whether a feature flag is present on the entitlement. Under LEGACY
--- every feature is granted — enforcement cannot precede issuance.
function M.hasFeature(name)
  if state.status == "LEGACY" then
    return true
  end
  return state.features[tostring(name)] == true
end

--- For diagnostics prints.
function M.describe()
  return string.format(
    "sku=%s status=%s type=%s company=%s agent=%s",
    state.sku,
    state.status,
    state.licenseType ~= "" and state.licenseType or "-",
    state.company ~= "" and state.company or "-",
    tostring(state.agentDeviceId or "NOT FOUND")
  )
end

--- Test hook: reset module state (a require'd module is cached per-VM).
function M._reset()
  state.sku = ""
  state.version = ""
  state.agentDeviceId = nil
  state.status = "LEGACY"
  state.licenseType = ""
  state.features = {}
  state.company = ""
  state.graceUntil = ""
  state.checkedAt = ""
  state.statusProperty = "License Status"
end

return M
