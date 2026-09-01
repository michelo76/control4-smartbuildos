--- SmartBuildOS cloud-mirror SDK — the one implementation every SmartBuildOS
--- driver uses to publish its UI state to SmartBuildOS and to receive remote
--- settings, both through the SmartBuildOS Agent.
---
--- Companion to `sbos.license`, and deliberately the same shape: the Agent
--- (`smartbuildos.c4z`) owns the account credentials and the HTTP path; a
--- dependent driver never holds a token and never calls the platform.
--- Transport is the same bindingless device path — exact-filename discovery
--- plus SendToDevice into the Agent's EC handlers.
---
--- WHY A MIRROR EXISTS (measured, 2026-08-31): a driver-hosted Navigator
--- page can reach its driver over the LAN, but a phone off the home network
--- cannot, and the Navigator JS API delivered nothing on real hardware. So
--- the driver hands its state to the Agent, the Agent posts it to
--- SmartBuildOS, and the page reads it back from a capability URL when it
--- has no better channel. The mirror is also what feeds fleet dashboards,
--- sampled history and briefings — those exist for every driver, not just
--- ones with a web view.
---
--- BACKWARD COMPATIBILITY: an Agent that predates the generic handlers
--- simply never answers. Nothing here may make a driver worse off than not
--- calling it at all — every failure path is silent-and-retry, never a
--- refusal, and never an event.
---
--- Usage from a driver:
---   local mirror = require("sbos.mirror")
---   mirror.setup({ sku = "SBOS_UNIFI_PROTECT", port = 47820, path = "/state" })
---   mirror.setRelayHost("192.168.1.20")          -- controller LAN address
---   EC.SBOS_DRIVER_STATE_ACK = mirror.onAck        -- where to read it back
---   EC.SBOS_DRIVER_CONFIG = mirror.onConfig(apply) -- remote settings
---   mirror.publish()          -- steady state, throttled
---   mirror.publish(true)      -- something changed, send now
---   mirror.viewUrl()          -- capability URL once the Agent answers

local log = require("lib.logging")

local M = {}

--- Steady-state throttle. Transitions bypass it; the Agent throttles again
--- on its own side, so this is the polite floor rather than the guarantee.
M.THROTTLE_SECONDS = 60

local state = {
  sku = nil,
  port = nil,
  path = "/state",
  token = nil,
  relayHost = nil,
  lastAsk = 0,
  view = nil, -- { url, handle }
  onView = nil,
}

--- Exact-filename Agent discovery. Substring matching is WRONG here — it
--- also matches smartbuildos-insights.c4z and smartbuildos-atmosphere.c4z
--- (the license SDK carries the same warning and a test that pins it).
local function findAgent()
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
      return id
    end
  end
  return nil
end

--- Configures the SDK.
--- opts = {
---   sku    (required) the driver's catalog SKU, e.g. "SBOS_ATMOSPHERE"
---   port   (required) the driver's own LAN state server port
---   path   optional state route on that server (default "/state")
---   token  optional shared token the Agent must present to that route
---   relayHost optional controller LAN address the Agent can use to reach it
---   onView optional callback(url, handle) when the capability URL arrives
--- }
function M.setup(opts)
  opts = opts or {}
  state.sku = tostring(opts.sku or "")
  state.port = tonumber(opts.port)
  state.path = tostring(opts.path or "/state")
  state.token = opts.token ~= nil and tostring(opts.token) or nil
  state.relayHost = opts.relayHost ~= nil and tostring(opts.relayHost) or nil
  state.onView = type(opts.onView) == "function" and opts.onView or nil
  state.lastAsk = 0
end

--- Lets a driver hand over a token minted after setup (the common case:
--- the token is created lazily with the state server).
function M.setToken(token)
  state.token = token ~= nil and tostring(token) or nil
end

--- Supplies the controller's reachable LAN address after setup. Control4 OS
--- 4.2 was measured hanging forever when the Agent fetched another driver's
--- CreateServer listener through 127.0.0.1, even though the same listener was
--- healthy on the controller's LAN address. The Agent validates this value as
--- a private IPv4 address before using it.
function M.setRelayHost(host)
  state.relayHost = host ~= nil and tostring(host) or nil
end

function M.isConfigured()
  return state.sku ~= nil and state.sku ~= "" and state.port ~= nil and state.token ~= nil and state.token ~= ""
end

--- Asks the Agent to mirror this driver's state.
--- `urgent` bypasses the steady-state throttle — pass it when something a
--- remote viewer would care about changed (an alert, a mode transition).
--- Returns true when an ask was actually sent.
function M.publish(urgent)
  if not M.isConfigured() then
    return false
  end
  local now = os.time()
  if not urgent and (now - state.lastAsk) < M.THROTTLE_SECONDS then
    return false
  end
  local agent = findAgent()
  if agent == nil then
    return false
  end
  state.lastAsk = now
  local ok = pcall(function()
    C4:SendToDevice(agent, "SBOS_DRIVER_STATE", {
      sku = state.sku,
      port = tostring(state.port),
      path = state.path,
      relay_host = state.relayHost,
      app_token = state.token,
      requester = tostring(C4:GetDeviceID()),
      urgent = urgent and "true" or "false",
    })
  end)
  return ok
end

--- Wire as EC.SBOS_DRIVER_STATE_ACK. The Agent answers with where the
--- mirrored state can be read. A reply for another SKU is ignored: several
--- SmartBuildOS drivers can share one controller and one Agent.
function M.onAck(tParams)
  tParams = tParams or {}
  if tostring(tParams.sku or "") ~= state.sku then
    return
  end
  local url = tostring(tParams.view_url or "")
  -- https only: this URL ends up in a page and must never be a downgrade.
  if url == "" or url:find("^https://") == nil then
    return
  end
  local handle = tostring(tParams.view_handle or "")
  local changed = state.view == nil or state.view.url ~= url or state.view.handle ~= handle
  state.view = { url = url, handle = handle }
  if changed then
    log:info("Cloud mirror ready for %s (handle %s)", state.sku, handle)
    if state.onView ~= nil then
      pcall(state.onView, url, handle)
    end
  end
end

--- The capability URL and handle, or nil until the Agent has answered.
function M.view()
  return state.view
end

function M.viewUrl()
  return state.view ~= nil and state.view.url or nil
end

function M.viewHandle()
  return state.view ~= nil and state.view.handle or nil
end

--- Restores a persisted view (so a restart advertises the URL immediately
--- instead of waiting for the next publish round-trip).
function M.restoreView(stored)
  if type(stored) ~= "table" then
    return
  end
  local url = tostring(stored.url or "")
  if url:find("^https://") == nil then
    return
  end
  state.view = { url = url, handle = tostring(stored.handle or "") }
end

--- Builds an EC handler for remote settings pushed from SmartBuildOS.
--- `apply(patch)` receives the decoded settings table and returns the list
--- of refusals (empty when everything applied) — exactly the shape a
--- versioned settings store already produces. The ack rides back to the
--- Agent so the platform gets an audit trail of what actually landed.
---
---   EC.SBOS_DRIVER_CONFIG = mirror.onConfig(function(patch)
---     return settingsstore.applyPatch(patch)
---   end)
function M.onConfig(apply)
  return function(tParams)
    tParams = tParams or {}
    if tostring(tParams.sku or "") ~= state.sku then
      return
    end
    local raw = tParams.settings
    if raw == nil then
      return
    end
    local ok, patch = pcall(function()
      return JSON:decode(tostring(raw))
    end)
    if not ok or type(patch) ~= "table" then
      log:warn("Remote settings for %s refused: payload did not decode", state.sku)
      return
    end
    local okApply, refused = pcall(apply, patch)
    if not okApply then
      log:warn("Remote settings for %s refused: apply failed", state.sku)
      return
    end
    refused = type(refused) == "table" and refused or {}
    local requester = tonumber(tParams.requester)
    if requester ~= nil then
      pcall(function()
        C4:SendToDevice(requester, "SBOS_DRIVER_CONFIG_ACK", {
          sku = state.sku,
          applied = tostring(#refused == 0),
          refused = tostring(#refused),
          settings_version = tostring(tParams.settings_version or ""),
        })
      end)
    end
    -- A remote change that lands and a remote change that is refused are
    -- both worth seeing in a log; neither is an error.
    log:info("Remote settings for %s applied with %d refusal(s)", state.sku, #refused)
  end
end

--- Test hook: forgets all SDK state.
function M._reset()
  state = {
    sku = nil,
    port = nil,
    path = "/state",
    token = nil,
    relayHost = nil,
    lastAsk = 0,
    view = nil,
    onView = nil,
  }
end

return M
