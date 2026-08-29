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

--- The ONLY statuses enforcement may act on: a DEFINITIVE "you are not
--- entitled" from the backend. Everything else — authorized, trial, legacy,
--- and crucially the UNCERTAIN states (cloud unreachable, agent not yet
--- authenticated) — is never enforced against. Uncertainty fails OPEN: a
--- SmartBuildOS outage must never dark a home (charter). CLOUD_VALIDATION_
--- REQUIRED and AGENT_UNAUTHENTICATED are deliberately absent from this set.
local DEFINITIVE_DENY = {
  NOT_ENTITLED = true,
  ENTITLEMENT_EXPIRED = true,
  ACCOUNT_SUSPENDED = true,
  CONTROLLER_MISMATCH = true,
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
  REGISTRATION_REQUIRED = "SMARTBUILDOS COMPANY REGISTRATION REQUIRED",
}

--- Human labels for the per-driver license SOURCE (#3a): is this driver
--- covered by the company's subscription tier, or bought outright?
local SOURCE_LABELS = {
  SUBSCRIPTION_INCLUDED = "Included with subscription",
  PERPETUAL = "Purchased outright",
  TRIAL = "Trial",
  GRACE = "Grace period",
  DEVELOPER = "Developer license",
  NFR = "Not for resale",
}

local state = {
  sku = "",
  version = "",
  agentDeviceId = nil,
  status = "LEGACY",
  licenseType = "",
  features = {},
  company = "",
  -- Display context the Agent forwards (unsigned): the company's subscription
  -- tier and name, and whether the Agent is paired to a REGISTERED company. A
  -- SmartBuildOS driver needs the Agent AND a registered company (#5).
  subscriptionTier = "",
  companyName = "",
  registered = false,
  registrationKnown = false,
  agentPresent = false,
  graceUntil = "",
  checkedAt = "",
  -- "observe" | "enforce", set by the Agent from the server's (unsigned)
  -- per-SKU enforcement config. Defaults to observe so a backend that does
  -- not send it — every backend before this release — never enforces.
  enforcement = "observe",
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

--- Updates an optional standardized display property, if the driver declares
--- it. pcall so a driver that has not added the property is a silent no-op.
local function setDisplay(name, value)
  pcall(function()
    UpdateProperty(name, value)
  end)
end

local function publishStatus()
  local label = LABELS[state.status] or state.status
  -- The Agent found the company unregistered (paired to no registered
  -- company): the loudest thing a dependent driver can say short of enforcing.
  if state.agentPresent and state.registrationKnown and not state.registered then
    label = LABELS.REGISTRATION_REQUIRED
  end
  if state.status == "AUTHORIZED_GRACE" and state.graceUntil ~= "" then
    label = label .. " until " .. state.graceUntil
  end
  if state.enforcement == "enforce" and DEFINITIVE_DENY[state.status] then
    -- Enforcement is live AND the account is definitively unlicensed: make
    -- the READ-ONLY consequence explicit, not just the status.
    label = label .. " (read-only)"
  end
  setDisplay(state.statusProperty, label)
  -- The standardized display set (#3/#3a): each optional, painted only if the
  -- driver declares the property.
  setDisplay(
    "License Source",
    SOURCE_LABELS[state.licenseType] or (state.licenseType ~= "" and state.licenseType or "-")
  )
  setDisplay("Subscription Tier", state.subscriptionTier ~= "" and state.subscriptionTier or "-")
  setDisplay("SmartBuildOS Company", state.companyName ~= "" and state.companyName or "-")
end

--- Registers this driver with the Agent. Called from setup and safe to
--- re-call (the Agent's inventory is keyed by sku + device id).
function M.register()
  local agent = findAgent()
  state.agentPresent = agent ~= nil
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
  state.subscriptionTier = tostring(tParams.subscription_tier or "")
  state.companyName = tostring(tParams.company_name or "")
  state.registrationKnown = tParams.registered ~= nil
  state.registered = tostring(tParams.registered or "") == "true"
  state.graceUntil = tostring(tParams.grace_until or "")
  state.checkedAt = tostring(tParams.checked_at or "")
  state.enforcement = tostring(tParams.enforcement or "") == "enforce" and "enforce" or "observe"
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

--- The enforcement gate. Returns true ONLY when the server has turned
--- enforcement on for this SKU AND the status is a definitive denial. A
--- driver consults this at each PRIVILEGED action (control, provisioning,
--- platform reporting) and refuses when it is true; it must NEVER consult it
--- for safety/awareness paths (live video, detections, status reads), which
--- always run. Three independent conditions must all hold, so the default
--- everywhere — legacy installs, outages, authorized accounts, observe mode
--- — is false. Enforcement is opt-in by the server and blind to uncertainty.
--- @return boolean
function M.enforces()
  return state.enforcement == "enforce" and DEFINITIVE_DENY[state.status] == true
end

--- The current server-set enforcement mode ("observe" | "enforce").
function M.enforcementMode()
  return state.enforcement
end

--- A human line for the property/log when enforcement denies an action.
function M.enforcementReason()
  local label = LABELS[state.status] or state.status
  return string.format("%s - control disabled until licensed", label)
end

--- Whether a feature flag is present on the entitlement. Under LEGACY
--- every feature is granted — enforcement cannot precede issuance.
function M.hasFeature(name)
  if state.status == "LEGACY" then
    return true
  end
  return state.features[tostring(name)] == true
end

--- The company's subscription tier (#3), e.g. "Professional". Blank until the
--- Agent has answered with it.
function M.subscriptionTier()
  return state.subscriptionTier
end

--- The company this project is licensed to (#3).
function M.companyName()
  return state.companyName
end

--- Whether the Agent is paired to a REGISTERED company (#5). A SmartBuildOS
--- driver needs both the Agent present AND a registered company.
function M.isRegistered()
  return state.agentPresent and state.registered
end

--- Whether the loud "registration required" state applies (#5): the Agent is
--- present and has DEFINITIVELY answered that no registered company is paired.
--- An absent answer is not treated as unregistered (fail-safe).
function M.isRegistrationRequired()
  return state.agentPresent and state.registrationKnown and not state.registered
end

--- A friendly label for THIS driver's license source (#3a): included with the
--- subscription, or purchased outright.
function M.licenseSource()
  return SOURCE_LABELS[state.licenseType] or (state.licenseType ~= "" and state.licenseType or "-")
end

--- For diagnostics prints.
function M.describe()
  return string.format(
    "sku=%s status=%s type=%s company=%s enforcement=%s agent=%s",
    state.sku,
    state.status,
    state.licenseType ~= "" and state.licenseType or "-",
    state.company ~= "" and state.company or "-",
    state.enforcement,
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
  state.subscriptionTier = ""
  state.companyName = ""
  state.registered = false
  state.registrationKnown = false
  state.agentPresent = false
  state.graceUntil = ""
  state.checkedAt = ""
  state.enforcement = "observe"
  state.statusProperty = "License Status"
end

return M
