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
  ["Pairing Backup"] = "",
  ["Paired Property"] = "Not paired",
  ["Connection Status"] = "Not paired",
  ["License Cloud"] = "Not paired - drivers run in legacy mode",
  ["Support ID"] = "",
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
    checked_at = "2026-08-29T05:00:00.000Z",
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
    checked_at = "2026-08-29T05:00:00.000Z",
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

-- ─── Summary ──────────────────────────────────────────────────────────────────

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
