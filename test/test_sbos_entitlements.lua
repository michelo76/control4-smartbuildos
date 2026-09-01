-- Tests for the Agent's Phase 5 entitlement engine (drivers/smartbuildos/driver.lua).
--
-- The driver is loaded against a fake lib.http and a fake Director. The
-- invariants under test are the commercial ones from the charter:
--
--   * The canonical signing string byte-matches the platform's
--     canonicalAssertion() — the literal pipe-joined fixture below IS the
--     cross-repo contract. If either side reorders fields, this fails.
--   * A tampered assertion (any bound field edited) answers
--     CLOUD_VALIDATION_REQUIRED, never the tampered status.
--   * Staleness ladder: as-issued within the cache window; authorized
--     statuses ride a DATED grace to day 10; then CLOUD_VALIDATION_REQUIRED.
--     Refusals never improve with age.
--   * A sku with no assertion answers LEGACY (enforcement never precedes
--     issuance), and an unpaired Agent answers LEGACY for everything.
--   * A pre-Phase-5 pairing (no agent_secret) still serves statuses from a
--     TLS-live fetch, marked unsigned.
--   * Pairing persists the agent secret + support id and mirrors them into
--     the Pairing Backup property; UNPAIR forgets all licensing state.
--
-- Run from the driver root: make test

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

local requests = {}
local nextResponse = { ok = true, code = 200 }
local pairBody = nil

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
    get = function(_, url, headers, options)
      return settled(true, { url = url, code = 200, headers = {}, body = "" })
    end,
    post = function(_, url, data, headers, options)
      table.insert(requests, { url = url, data = data, headers = headers, options = options })
      if url:find("/pair$") and pairBody ~= nil and nextResponse.ok then
        return settled(true, { url = url, code = 200, headers = {}, body = pairBody })
      end
      if nextResponse.ok then
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

C4 = C4 or {}

function C4:GetDevices()
  return {}
end
function C4:GetBindingsByDevice()
  return { bindings = {} }
end
function C4:GetNetworkBindingsByDevice()
  return nil
end
function C4:GetNetworkConnections()
  return {}
end
function C4:GetProjectHierarchy()
  return {}
end
function C4:GetDeviceVariables()
  return {}
end
function C4:GetAllCodeItems()
  return {}
end
function C4:GetSystemType()
  return "XDT_EA5"
end
function C4:FireEvent() end
function C4:DebugLog() end
function C4:ErrorLog() end

Properties = {
  ["API URL"] = "https://app.smartbuildos.io",
  ["Pairing Code"] = "",
  ["Account Number"] = "",
  ["Verification Code"] = "",
  ["Pairing Backup"] = "",
  ["Paired Property"] = "Not paired",
  ["Connection Status"] = "Not paired",
  ["License Cloud"] = "Not paired - drivers run in legacy mode",
  ["Support ID"] = "",
  ["SmartBuildOS Company"] = "Not registered - pair to a company",
  ["Subscription Tier"] = "Not paired",
  ["Licensed Drivers"] = "No SmartBuildOS drivers installed",
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

function C4:UpdateProperty(name, value)
  Properties[name] = value
end

require("c4_shim")

package.path = "./drivers/smartbuildos/?.lua;" .. package.path
dofile("drivers/smartbuildos/driver.lua")

-- Capture the licensing protocol traffic. Overridden AFTER the driver load so
-- the global the driver resolves at call time is this one.
local deviceSent = {}
function SendToDevice(deviceId, command, params)
  table.insert(deviceSent, { device = deviceId, command = command, params = params })
end

gInitialized = true

-- ─── Fixtures ─────────────────────────────────────────────────────────────────

local SECRET = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
local COMPANY = "8f7f4a3e-0000-4000-8000-c0ffee000001"
local CONTROLLER = "8f7f4a3e-0000-4000-8000-c0ffee000002"

--- The cross-repo canonical fixture: this literal layout mirrors
--- canonicalAssertion() in the platform's src/lib/driver-cloud/entitlements.ts.
local function canonical(a)
  return table.concat({
    tostring(a.v),
    a.sig_alg,
    a.company_id,
    a.controller_id,
    a.driver_sku,
    a.status,
    a.license_type,
    table.concat(a.features, ","),
    a.issued_at,
    a.valid_until or "",
    a.grace_until or "",
  }, "|")
end

local function signedAssertion(overrides)
  local a = {
    v = 1,
    sig_alg = "HMAC-SHA256",
    company_id = COMPANY,
    controller_id = CONTROLLER,
    driver_sku = "SBOS_UNIFI_PROTECT",
    status = "AUTHORIZED_SUBSCRIPTION",
    license_type = "SUBSCRIPTION_INCLUDED",
    features = { "BASE", "EVENTS" },
    issued_at = "2026-08-29T04:00:00.000Z",
    valid_until = nil,
    grace_until = nil,
  }
  for key, value in pairs(overrides or {}) do
    a[key] = value
  end
  a.sig = C4:HMAC("SHA256", SECRET, canonical(a), {
    return_encoding = "HEX",
    key_encoding = "NONE",
    data_encoding = "NONE",
  }):lower()
  return a
end

-- A server stamp that reads as "now": refreshes that are not exercising the
-- clock-skew path must never drift past the 48h skew threshold as this file
-- ages, or they steal the once-per-boot transition section [18] asserts on.
local function isoNow()
  return os.date("!%Y-%m-%dT%H:%M:%S.000Z")
end

local function reset()
  for key in pairs(store) do
    store[key] = nil
  end
  requests = {}
  deviceSent = {}
  nextResponse = { ok = true, code = 200 }
  pairBody = nil
  Properties["Pairing Backup"] = ""
  Properties["License Cloud"] = "Not paired - drivers run in legacy mode"
  Properties["Support ID"] = ""
end

local function paired()
  store["device_token"] = "sbc4_deadbeef_token"
  store["system_id"] = "7e14128e-fb05-4645-929f-e1ee9e1ee964"
  store["agent_secret"] = SECRET
end

--- Asks the Agent about one sku through the real protocol door and returns
--- the SBOS_ENTITLEMENT payload it sent back.
local function ask(sku)
  deviceSent = {}
  EC.SBOS_CHECK_ENTITLEMENT({ sku = sku, requester = "301" })
  for _, sent in ipairs(deviceSent) do
    if sent.command == "SBOS_ENTITLEMENT" and (sent.params or {}).sku == sku then
      return sent.params
    end
  end
  return nil
end

local function lastRequestTo(suffix)
  for i = #requests, 1, -1 do
    if requests[i].url:find(suffix, 1, true) then
      return requests[i]
    end
  end
  return nil
end

local function seedCache(assertions, overrides)
  local cache = {
    fetched_at = os.time() - 60,
    checked_at = "2026-08-29T04:00:00.000Z",
    support_id = "SBOS-A1B2C3",
    revalidate_hours = 24,
    cache_days = 7,
    verified = true,
    assertions = assertions,
  }
  for key, value in pairs(overrides or {}) do
    cache[key] = value
  end
  store["sbos_entitlement_cache"] = cache
end

-- ─── Tests ────────────────────────────────────────────────────────────────────

print("\n[1] Unpaired and uncached Agents answer LEGACY")
reset()
local answer = ask("SBOS_UNIFI_PROTECT")
check("unpaired answers LEGACY", answer ~= nil and answer.status == "LEGACY", answer and answer.status)
paired()
answer = ask("SBOS_UNIFI_PROTECT")
check("paired but never fetched answers LEGACY", answer ~= nil and answer.status == "LEGACY", answer and answer.status)

print("\n[2] A verified fresh assertion answers as issued")
reset()
paired()
seedCache({ SBOS_UNIFI_PROTECT = signedAssertion() })
answer = ask("SBOS_UNIFI_PROTECT")
check("status is as issued", answer.status == "AUTHORIZED_SUBSCRIPTION", answer.status)
check("license type rides along", answer.license_type == "SUBSCRIPTION_INCLUDED", answer.license_type)
check("features are comma-joined", answer.features == "BASE,EVENTS", answer.features)
check("checked_at is the server's stamp", answer.checked_at == "2026-08-29T04:00:00.000Z", answer.checked_at)

print("\n[3] Tampering with any bound field is caught")
reset()
paired()
local tampered = signedAssertion()
tampered.status = "AUTHORIZED_PERPETUAL" -- edited AFTER signing
seedCache({ SBOS_UNIFI_PROTECT = tampered })
answer = ask("SBOS_UNIFI_PROTECT")
check("tampered status answers CLOUD_VALIDATION_REQUIRED", answer.status == "CLOUD_VALIDATION_REQUIRED", answer.status)
local securityEvent = lastRequestTo("/api/driver-cloud/events")
check("a SECURITY event was reported", securityEvent ~= nil and securityEvent.data.events[1].category == "SECURITY")

print("\n[4] A cross-controller copy fails (different secret signed it)")
reset()
paired()
local foreign = signedAssertion()
foreign.sig = C4:HMAC("SHA256", "some-other-controllers-secret", canonical(foreign), {
  return_encoding = "HEX",
  key_encoding = "NONE",
  data_encoding = "NONE",
}):lower()
seedCache({ SBOS_UNIFI_PROTECT = foreign })
answer = ask("SBOS_UNIFI_PROTECT")
check("foreign-signed assertion is refused", answer.status == "CLOUD_VALIDATION_REQUIRED", answer.status)

print("\n[5] The staleness ladder")
reset()
paired()
seedCache({ SBOS_UNIFI_PROTECT = signedAssertion() }, { fetched_at = os.time() - 8 * 86400 })
answer = ask("SBOS_UNIFI_PROTECT")
check("day 8: authorized rides grace", answer.status == "AUTHORIZED_GRACE", answer.status)
check("day 8: the grace is DATED", (answer.grace_until or "") ~= "", answer.grace_until)
seedCache(
  { SBOS_UNIFI_PROTECT = signedAssertion({ status = "NOT_ENTITLED", features = {} }) },
  { fetched_at = os.time() - 8 * 86400 }
)
answer = ask("SBOS_UNIFI_PROTECT")
check("day 8: a refusal never improves with age", answer.status == "NOT_ENTITLED", answer.status)
seedCache({ SBOS_UNIFI_PROTECT = signedAssertion() }, { fetched_at = os.time() - 11 * 86400 })
answer = ask("SBOS_UNIFI_PROTECT")
check("day 11: cloud validation is demanded", answer.status == "CLOUD_VALIDATION_REQUIRED", answer.status)

print("\n[6] A sku the platform issued nothing for stays LEGACY")
reset()
paired()
seedCache({ SBOS_UNIFI_PROTECT = signedAssertion() })
answer = ask("SBOS_SOME_FUTURE_DRIVER")
check("unknown sku answers LEGACY", answer.status == "LEGACY", answer.status)

print("\n[7] The refresh round-trip: fetch, verify, cache, push")
reset()
paired()
store["sbos_driver_inventory"] = {
  SBOS_UNIFI_PROTECT = { version = "20260828.1", device_id = 301, registered_at = "x", last_seen = "x" },
}
local good = signedAssertion()
local forged = signedAssertion({ driver_sku = "SBOS_FUTURE" })
forged.sig = "00" .. forged.sig:sub(3)
nextResponse = {
  ok = true,
  code = 200,
  body = JSON:encode({
    assertions = { good, forged },
    support_id = "SBOS-A1B2C3",
    checked_at = isoNow(),
    revalidate_after_hours = 24,
    offline_cache_days = 7,
  }),
}
deviceSent = {}
EC.REFRESH_ENTITLEMENTS()
local refreshReq = lastRequestTo("/api/driver-cloud/entitlements/refresh")
check("the refresh hit the driver-cloud route", refreshReq ~= nil)
check("the request is token-authed", (refreshReq.headers or {})["Authorization"] == "Bearer sbc4_deadbeef_token")
local sawAgent, sawProtect = false, false
for _, item in ipairs((refreshReq.data or {}).installed or {}) do
  sawAgent = sawAgent or item.sku == "SBOS_AGENT"
  sawProtect = sawProtect or item.sku == "SBOS_UNIFI_PROTECT"
end
check("the inventory rode along (registered driver)", sawProtect)
check("the inventory rode along (the Agent itself)", sawAgent)
local cache = store["sbos_entitlement_cache"]
check("the good assertion was cached", cache ~= nil and cache.assertions.SBOS_UNIFI_PROTECT ~= nil)
check("the forged assertion was dropped at fetch", cache ~= nil and cache.assertions.SBOS_FUTURE == nil)
check("the cache is marked signed", cache ~= nil and cache.verified == true)
check("the support id was stored", store["support_id"] == "SBOS-A1B2C3")
local pushed = false
for _, sent in ipairs(deviceSent) do
  if
    sent.command == "SBOS_ENTITLEMENT"
    and sent.device == 301
    and (sent.params or {}).status == "AUTHORIZED_SUBSCRIPTION"
  then
    pushed = true
  end
end
check("the registered driver was pushed the news", pushed)
check(
  "License Cloud reads OK",
  (Properties["License Cloud"] or ""):find("OK", 1, true) ~= nil,
  Properties["License Cloud"]
)
check("Support ID property is painted", Properties["Support ID"] == "SBOS-A1B2C3", Properties["Support ID"])

print("\n[8] A pre-Phase-5 pairing (no secret) serves unsigned statuses")
reset()
paired()
store["agent_secret"] = nil
store["sbos_driver_inventory"] = {}
nextResponse = {
  ok = true,
  code = 200,
  body = JSON:encode({
    assertions = { signedAssertion() },
    support_id = "SBOS-A1B2C3",
    checked_at = isoNow(),
    revalidate_after_hours = 24,
    offline_cache_days = 7,
  }),
}
EC.REFRESH_ENTITLEMENTS()
cache = store["sbos_entitlement_cache"]
check("assertions were accepted from the live TLS fetch", cache ~= nil and cache.assertions.SBOS_UNIFI_PROTECT ~= nil)
check("the cache is marked UNSIGNED", cache ~= nil and cache.verified == false)
answer = ask("SBOS_UNIFI_PROTECT")
check("statuses still serve", answer.status == "AUTHORIZED_SUBSCRIPTION", answer.status)
check(
  "the property says so",
  (Properties["License Cloud"] or ""):find("unsigned", 1, true) ~= nil,
  Properties["License Cloud"]
)

print("\n[9] A failed refresh leaves the cache and ladder in effect")
reset()
paired()
seedCache({ SBOS_UNIFI_PROTECT = signedAssertion() })
nextResponse = { ok = false, code = 503, error = "unavailable" }
EC.REFRESH_ENTITLEMENTS()
answer = ask("SBOS_UNIFI_PROTECT")
check("the cached answer survives the outage", answer.status == "AUTHORIZED_SUBSCRIPTION", answer.status)

print("\n[10] Pairing persists the secret and the backup carries it")
reset()
pairBody = {
  token = "sbc4_feedface_token",
  property_id = "0f1c9a52-7d33-4f0e-9a11-2b6c8d4e5f00",
  property_name = "Doerr Residence",
  agent_secret = SECRET,
  support_id = "SBOS-D0E44R",
}
nextResponse = { ok = true, code = 200, body = "" }
OPC.Pairing_Code("H7K2-9QXR")
check("the agent secret was stored", store["agent_secret"] == SECRET)
check("the support id was stored", store["support_id"] == "SBOS-D0E44R")
local backup = JSON:decode(Properties["Pairing Backup"] or "")
check("the backup mirrors the secret", type(backup) == "table" and backup.agent_secret == SECRET)
check("the backup mirrors the support id", type(backup) == "table" and backup.support_id == "SBOS-D0E44R")
check("pairing fired an entitlement refresh", lastRequestTo("/api/driver-cloud/entitlements/refresh") ~= nil)

print("\n[11] Backup restore brings licensing identity back")
reset()
Properties["Pairing Backup"] = JSON:encode({
  token = "sbc4_feedface_token",
  system_id = "7e14128e-fb05-4645-929f-e1ee9e1ee964",
  property_id = "",
  agent_secret = SECRET,
  support_id = "SBOS-D0E44R",
})
restorePairingFromBackup()
check("the token restored", store["device_token"] == "sbc4_feedface_token")
check("the secret restored", store["agent_secret"] == SECRET)
check("the support id restored", store["support_id"] == "SBOS-D0E44R")

print("\n[12] UNPAIR forgets every piece of licensing state")
reset()
paired()
seedCache({ SBOS_UNIFI_PROTECT = signedAssertion() })
store["support_id"] = "SBOS-A1B2C3"
EC.UNPAIR()
check("the secret is gone", store["agent_secret"] == nil)
check("the cache is gone", store["sbos_entitlement_cache"] == nil)
check("the support id is gone", store["support_id"] == nil)
answer = ask("SBOS_UNIFI_PROTECT")
check("answers fall back to LEGACY", answer.status == "LEGACY", answer.status)

print("\n[13] Adversarial: an assertion presented under the WRONG sku")
reset()
paired()
-- A real, correctly-signed assertion for Protect, filed in the cache under a
-- DIFFERENT sku key. Its bound driver_sku no longer matches the key, so the
-- signature (which covers driver_sku) must fail to verify.
local misfiled = signedAssertion()
seedCache({ SBOS_SOME_OTHER = misfiled })
answer = ask("SBOS_SOME_OTHER")
check("a misfiled assertion does not verify", answer.status == "CLOUD_VALIDATION_REQUIRED", answer.status)

print("\n[14] Adversarial: every bound field, tampered one at a time")
reset()
paired()
local function tamperField(mutate)
  local a = signedAssertion()
  mutate(a) -- edit AFTER signing
  seedCache({ SBOS_UNIFI_PROTECT = a })
  return ask("SBOS_UNIFI_PROTECT").status
end
check("tampered company_id caught", tamperField(function(a)
  a.company_id = "someone-else"
end) == "CLOUD_VALIDATION_REQUIRED")
check("tampered controller_id caught", tamperField(function(a)
  a.controller_id = "another-controller"
end) == "CLOUD_VALIDATION_REQUIRED")
check("tampered license_type caught", tamperField(function(a)
  a.license_type = "PERPETUAL"
end) == "CLOUD_VALIDATION_REQUIRED")
check("tampered features caught", tamperField(function(a)
  a.features = { "BASE", "EVENTS", "ADMIN" }
end) == "CLOUD_VALIDATION_REQUIRED")
check("tampered valid_until caught", tamperField(function(a)
  a.valid_until = "2099-01-01T00:00:00.000Z"
end) == "CLOUD_VALIDATION_REQUIRED")
check("tampered grace_until caught", tamperField(function(a)
  a.grace_until = "2099-01-01T00:00:00.000Z"
end) == "CLOUD_VALIDATION_REQUIRED")

print("\n[15] Adversarial: a whole cache lifted onto another controller")
reset()
paired()
-- The attacker copies a legitimate signed cache from controller A onto
-- controller B, whose secret is different. B's verify re-signs with ITS
-- secret and the MACs cannot match — cross-controller theft is closed.
seedCache({ SBOS_UNIFI_PROTECT = signedAssertion() })
store["agent_secret"] = "a-completely-different-controllers-secret"
answer = ask("SBOS_UNIFI_PROTECT")
check("a stolen cache fails on the new controller", answer.status == "CLOUD_VALIDATION_REQUIRED", answer.status)

print("\n[16] Clock rolled BACKWARDS cannot buy eternal freshness")
reset()
paired()
-- fetched_at in the future = the controller clock moved back after the last
-- refresh. A naive age (now - fetched_at) is negative and reads as "brand
-- new forever". cacheAge clamps to 0 and the anomaly is flagged, but the
-- answer still serves (never a dark home).
seedCache({ SBOS_UNIFI_PROTECT = signedAssertion() }, { fetched_at = os.time() + 5 * 86400 })
answer = ask("SBOS_UNIFI_PROTECT")
check(
  "a backwards clock still answers (clamped, not eternal)",
  answer.status == "AUTHORIZED_SUBSCRIPTION",
  answer.status
)
local flagged = false
for _, req in ipairs(requests) do
  if req.url:find("/events", 1, true) then
    for _, e in ipairs((req.data or {}).events or {}) do
      if e.code == "clock_backwards" then
        flagged = true
      end
    end
  end
end
check("the backwards clock was reported once", flagged)

print("\n[17] A forward clock only makes the ladder STRICTER, never looser")
reset()
paired()
-- Even a wildly-ahead clock cannot UNLOCK anything: it only ages the cache
-- faster, and grace/CLOUD_VALIDATION_REQUIRED absorb that. A refused status
-- stays refused.
seedCache(
  { SBOS_UNIFI_PROTECT = signedAssertion({ status = "NOT_ENTITLED", features = {} }) },
  { fetched_at = os.time() - 20 * 86400 }
)
answer = ask("SBOS_UNIFI_PROTECT")
check("an old refusal is still a refusal", answer.status == "NOT_ENTITLED", answer.status)

print("\n[18] Clock skew vs the server stamp is flagged once on refresh")
reset()
paired()
store["sbos_driver_inventory"] = {}
-- Server says it is 2026; a controller whose clock is years off will skew.
nextResponse = {
  ok = true,
  code = 200,
  body = JSON:encode({
    assertions = { signedAssertion() },
    support_id = "SBOS-A1B2C3",
    checked_at = "2020-01-01T00:00:00.000Z",
    revalidate_after_hours = 24,
    offline_cache_days = 7,
  }),
}
EC.REFRESH_ENTITLEMENTS()
local skewFlagged = false
for _, req in ipairs(requests) do
  if req.url:find("/events", 1, true) then
    for _, e in ipairs((req.data or {}).events or {}) do
      if e.code == "clock_skew" then
        skewFlagged = true
      end
    end
  end
end
check("a multi-year skew is reported", skewFlagged)
check("skew does not stop the cache landing", store["sbos_entitlement_cache"] ~= nil)

print("\n[19] Ladder: internet lost on day 6 is still fully authorized")
reset()
paired()
seedCache({ SBOS_UNIFI_PROTECT = signedAssertion() }, { fetched_at = os.time() - 6 * 86400 })
answer = ask("SBOS_UNIFI_PROTECT")
check("day 6 (inside the 7d cache) is as-issued", answer.status == "AUTHORIZED_SUBSCRIPTION", answer.status)

print("\n[20] Ladder: a subscription canceled while OFFLINE stays cached until reconnect")
reset()
paired()
-- The server cancels the subscription, but the controller has no internet to
-- hear it. It cannot invent a denial it was never told about; it rides its
-- last cached authorization through the ladder. This is "outage != revocation"
-- (never dark a home) and is the intended behavior, not a bug.
seedCache({ SBOS_UNIFI_PROTECT = signedAssertion() }, { fetched_at = os.time() - 5 * 86400 })
nextResponse = { ok = false, code = 503, error = "offline" }
EC.REFRESH_ENTITLEMENTS()
answer = ask("SBOS_UNIFI_PROTECT")
check(
  "an offline controller keeps its last-known authorization",
  answer.status == "AUTHORIZED_SUBSCRIPTION",
  answer.status
)

print("\n[21] Ladder: a subscription REACTIVATED during grace recovers on refresh")
reset()
paired()
store["sbos_driver_inventory"] =
  { SBOS_UNIFI_PROTECT = { version = "x", device_id = 301, registered_at = "x", last_seen = "x" } }
-- Day 8: riding grace because the cache is stale.
seedCache({ SBOS_UNIFI_PROTECT = signedAssertion() }, { fetched_at = os.time() - 8 * 86400 })
check("precondition: day 8 is grace", ask("SBOS_UNIFI_PROTECT").status == "AUTHORIZED_GRACE")
-- Reactivated: a successful refresh returns a fresh AUTHORIZED assertion.
nextResponse = {
  ok = true,
  code = 200,
  body = JSON:encode({
    assertions = { signedAssertion() },
    support_id = "SBOS-A1B2C3",
    checked_at = isoNow(),
    revalidate_after_hours = 24,
    offline_cache_days = 7,
  }),
}
EC.REFRESH_ENTITLEMENTS()
answer = ask("SBOS_UNIFI_PROTECT")
check("reactivation clears grace and restores as-issued", answer.status == "AUTHORIZED_SUBSCRIPTION", answer.status)
check("and the grace date is gone", answer.grace_until == "", answer.grace_until)

print("\n[22] Ladder: a PERPETUAL entitlement is honored regardless of subscription")
reset()
paired()
-- The server resolves perpetual-beside-expired-subscription and sends
-- AUTHORIZED_PERPETUAL; the driver honors the status it is given and never
-- second-guesses it against subscription state it does not hold.
seedCache({ SBOS_UNIFI_PROTECT = signedAssertion({ status = "AUTHORIZED_PERPETUAL", license_type = "PERPETUAL" }) })
answer = ask("SBOS_UNIFI_PROTECT")
check("perpetual is authorized", answer.status == "AUTHORIZED_PERPETUAL", answer.status)
check("perpetual rides the full cache window", answer.license_type == "PERPETUAL", answer.license_type)

print("\n[23] Account display: tier, company, registration, licensed-driver count")

-- Pairing carries the account picture so the Agent shows it before its first
-- refresh (#3). A blank value never overwrites a known one.
reset()
pairBody = {
  token = "sbc4_feedface_token",
  property_id = "0f1c9a52-7d33-4f0e-9a11-2b6c8d4e5f00",
  property_name = "Doerr Residence",
  agent_secret = SECRET,
  support_id = "SBOS-D0E44R",
  subscription_tier = "Professional",
  company_name = "Aurora AV",
}
nextResponse = { ok = true, code = 200, body = "" }
OPC.Pairing_Code("H7K2-9QXR")
check("pairing cached the subscription tier", store["sbos_subscription_tier"] == "Professional")
check("pairing cached the company name", store["sbos_company_name"] == "Aurora AV")

-- The dependent-driver protocol carries tier + company + the registration fact.
reset()
paired()
store["sbos_subscription_tier"] = "Business"
store["sbos_company_name"] = "Northlight Integrations"
seedCache({ SBOS_UNIFI_PROTECT = signedAssertion() })
answer = ask("SBOS_UNIFI_PROTECT")
check("the answer forwards the subscription tier", answer.subscription_tier == "Business", answer.subscription_tier)
check("the answer forwards the company name", answer.company_name == "Northlight Integrations", answer.company_name)
check("a paired Agent answers registered=true", answer.registered == "true", tostring(answer.registered))

-- An Agent with no registered company (unpaired) answers registered=false, so a
-- dependent driver shows REGISTRATION REQUIRED (#5).
reset()
seedCache({ SBOS_UNIFI_PROTECT = signedAssertion() })
answer = ask("SBOS_UNIFI_PROTECT")
check("an unpaired Agent answers registered=false", answer.registered == "false", tostring(answer.registered))

-- A refresh re-resolves tier + company + grace and paints the display; the
-- licensed-driver count reflects authorized inventory (#4).
reset()
paired()
store["sbos_driver_inventory"] = {
  SBOS_UNIFI_PROTECT = { version = "x", device_id = 301, registered_at = "x", last_seen = "x" },
}
nextResponse = {
  ok = true,
  code = 200,
  body = JSON:encode({
    assertions = { signedAssertion() },
    support_id = "SBOS-A1B2C3",
    checked_at = isoNow(),
    revalidate_after_hours = 24,
    offline_cache_days = 7,
    subscription_tier = "Enterprise",
    company_name = "Vantage Systems",
    subscription_in_grace = false,
  }),
}
EC.REFRESH_ENTITLEMENTS()
check("refresh cached the tier", store["sbos_subscription_tier"] == "Enterprise")
check("refresh cached the company", store["sbos_company_name"] == "Vantage Systems")
check(
  "Subscription Tier property painted",
  Properties["Subscription Tier"] == "Enterprise",
  Properties["Subscription Tier"]
)
check(
  "SmartBuildOS Company property painted",
  Properties["SmartBuildOS Company"] == "Vantage Systems",
  Properties["SmartBuildOS Company"]
)
check(
  "Licensed Drivers counts the authorized driver",
  Properties["Licensed Drivers"] == "1 licensed / 1 installed",
  Properties["Licensed Drivers"]
)

-- Grace is surfaced in the tier line so a dealer sees the account is riding it.
nextResponse = {
  ok = true,
  code = 200,
  body = JSON:encode({
    assertions = { signedAssertion() },
    revalidate_after_hours = 24,
    offline_cache_days = 7,
    subscription_tier = "Professional",
    company_name = "Vantage Systems",
    subscription_in_grace = true,
  }),
}
EC.REFRESH_ENTITLEMENTS()
check(
  "Subscription Tier shows the grace suffix",
  Properties["Subscription Tier"] == "Professional (grace)",
  Properties["Subscription Tier"]
)

-- A blank inbound tier (platform could not confirm it) keeps the last known
-- value rather than blanking a paid customer's display.
nextResponse = {
  ok = true,
  code = 200,
  body = JSON:encode({
    assertions = { signedAssertion() },
    revalidate_after_hours = 24,
    offline_cache_days = 7,
    subscription_tier = "",
    company_name = "",
  }),
}
EC.REFRESH_ENTITLEMENTS()
check(
  "a blank inbound tier does not clobber the known one",
  store["sbos_subscription_tier"] == "Professional",
  store["sbos_subscription_tier"]
)

print("\n[24] Account-number pairing: request a code, then redeem it (#6)")

-- Entering an account number asks the platform to email a code.
reset()
Properties["Account Number"] = "AB12CD"
OPC.Account_Number("AB12CD")
local req = lastRequestTo("/pair/request-code")
check("the request hit the request-code route", req ~= nil)
check(
  "it carried the account number, upper-cased",
  req and (req.data or {}).account_number == "AB12CD",
  req and (req.data or {}).account_number
)
check("it carried the controller identity", req and type((req.data or {}).system) == "table")
check("the account number was remembered", store["sbos_account_number"] == "AB12CD")
check(
  "the status invites the code",
  tostring(Properties["Connection Status"]):find("emailed", 1, true) ~= nil,
  Properties["Connection Status"]
)

-- The reload guard: a property replay before init must not email a code.
reset()
gInitialized = false
OPC.Account_Number("ZZ99YY")
check("no code was requested during the pre-init replay", lastRequestTo("/pair/request-code") == nil)
gInitialized = true

-- Entering the emailed code pairs, through the same handler as a pairing code.
reset()
store["sbos_account_number"] = "AB12CD"
Properties["Account Number"] = "AB12CD"
nextResponse = {
  ok = true,
  code = 200,
  body = JSON:encode({
    token = "sbc4_acct_token",
    system_id = "7e14128e-fb05-4645-929f-e1ee9e1ee964",
    property_id = "",
    agent_secret = SECRET,
    support_id = "SBOS-ACCT01",
    property_name = "Rivera Residence",
    subscription_tier = "Professional",
    company_name = "Aurora AV",
  }),
}
deviceSent = {}
OPC.Verification_Code("123456")
local vreq = lastRequestTo("/pair/verify-code")
check("the request hit the verify-code route", vreq ~= nil)
check("it carried the account number", vreq and (vreq.data or {}).account_number == "AB12CD")
check("it carried the code", vreq and (vreq.data or {}).code == "123456")
check("the token was stored", store["device_token"] == "sbc4_acct_token", store["device_token"])
check("the agent secret was stored", store["agent_secret"] == SECRET)
check("the subscription tier was cached", store["sbos_subscription_tier"] == "Professional")
check("the company name was cached", store["sbos_company_name"] == "Aurora AV")
check("the verification code field was cleared", Properties["Verification Code"] == "")
check("the remembered account number was consumed", store["sbos_account_number"] == nil)

-- A code with no account number entered refuses locally rather than calling out.
reset()
Properties["Account Number"] = ""
OPC.Verification_Code("123456")
check("no verify call without an account number", lastRequestTo("/pair/verify-code") == nil)
check(
  "the status asks for the account number",
  tostring(Properties["Connection Status"]):find("account number", 1, true) ~= nil,
  Properties["Connection Status"]
)

print("\n[25] An authorized driver receives only a scoped direct-upload capability")
reset()
paired()
seedCache({ SBOS_ATMOSPHERE = signedAssertion({ driver_sku = "SBOS_ATMOSPHERE" }) })
nextResponse = {
  ok = true,
  code = 200,
  body = JSON:encode({
    driver_sku = "SBOS_ATMOSPHERE",
    upload_url = "https://app.smartbuildos.io/api/driver-cloud/state/direct",
    upload_token = "sbosdu2.controller.sku.apphash.generation.signature",
  }),
}
EC.SBOS_DRIVER_CLOUD_REQUEST({
  sku = "SBOS_ATMOSPHERE",
  app_token = "aaaa1111aaaa1111",
  requester = "591",
  request_id = "Random-12345678-1",
})
local provision = lastRequestTo("/api/driver-cloud/state/provision")
check("the Agent asked the provisioning endpoint", provision ~= nil)
check("the request carries the licensed sku", provision and provision.data.driver_sku == "SBOS_ATMOSPHERE")
check("the request binds this app installation", provision and provision.data.app_token == "aaaa1111aaaa1111")
local provisioned = deviceSent[#deviceSent]
check(
  "the scoped capability was sent only to the requesting driver",
  provisioned ~= nil and provisioned.device == 591 and provisioned.command == "SBOS_DRIVER_CLOUD"
)
check(
  "the Agent bearer never rides the inter-driver answer",
  provisioned ~= nil and provisioned.params.upload_token ~= store["device_token"]
)
check(
  "the Agent echoes the one-time response challenge",
  provisioned ~= nil and provisioned.params.request_id == "Random-12345678-1"
)

local sentBeforeUntrustedUrl = #deviceSent
nextResponse = {
  ok = true,
  code = 200,
  body = JSON:encode({
    driver_sku = "SBOS_ATMOSPHERE",
    upload_url = "https://attacker.example/collect",
    upload_token = "sbosdu2.controller.sku.apphash.generation.signature",
  }),
}
EC.SBOS_DRIVER_CLOUD_REQUEST({
  sku = "SBOS_ATMOSPHERE",
  app_token = "aaaa1111aaaa1111",
  requester = "591",
  request_id = "Random-12345678-untrusted",
})
check("the Agent refuses an upload URL outside its configured origin", #deviceSent == sentBeforeUntrustedUrl)

print("\n[26] An unlicensed driver receives no cloud capability")
reset()
paired()
seedCache({
  SBOS_ATMOSPHERE = signedAssertion({
    driver_sku = "SBOS_ATMOSPHERE",
    status = "NOT_ENTITLED",
    license_type = "",
    features = {},
  }),
})
EC.SBOS_DRIVER_CLOUD_REQUEST({
  sku = "SBOS_ATMOSPHERE",
  app_token = "aaaa1111aaaa1111",
  requester = "591",
  request_id = "Random-12345678-2",
})
check("an unlicensed driver never reaches provisioning", lastRequestTo("/api/driver-cloud/state/provision") == nil)
check(
  "the Agent restates the entitlement instead",
  deviceSent[#deviceSent] ~= nil and deviceSent[#deviceSent].command == "SBOS_ENTITLEMENT"
)

-- ─── Summary ──────────────────────────────────────────────────────────────────

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
