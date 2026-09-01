-- Tests for src/sbos/mirror.lua — the cloud-mirror SDK every SmartBuildOS
-- driver uses to publish state and receive remote settings.
--
-- The invariants a SECOND driver adopting this must be able to trust:
--   * Agent discovery is EXACT-filename (smartbuildos-atmosphere.c4z and
--     smartbuildos-insights.c4z are near-misses that must never match).
--   * Steady state throttles; urgent bypasses; unconfigured never sends.
--   * Acks and configs for ANOTHER sku are ignored — several SmartBuildOS
--     drivers share one controller and one Agent.
--   * A non-https view URL is refused (it ends up in a Navigator page).
--   * onConfig decodes, applies, acks with the refusal count, and survives
--     garbage payloads and a throwing apply without propagating.
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

JSON = require("JSON")

-- ─── C4 fakes ─────────────────────────────────────────────────────────────────

local devices = {}
local sent = {}
function C4:GetDevices()
  return devices
end
function C4:SendToDevice(id, command, params)
  sent[#sent + 1] = { id = id, command = command, params = params }
end
function C4:GetDeviceID()
  return 55
end

local mirror = require("sbos.mirror")

local function reset(withAgent)
  mirror._reset()
  sent = {}
  devices = withAgent and { [9] = { driverFileName = "smartbuildos.c4z" } } or {}
end

local function lastSent()
  return sent[#sent]
end

-- ─── discovery ────────────────────────────────────────────────────────────────

reset(false)
devices = {
  [3] = { driverFileName = "smartbuildos-atmosphere.c4z" },
  [4] = { driverFileName = "smartbuildos-insights.c4z" },
}
mirror.setup({ sku = "SBOS_TEST", port = 47815, token = "tok" })
check("near-miss filenames are not the Agent", mirror.publish(true) == false and #sent == 0)

reset(true)
mirror.setup({ sku = "SBOS_TEST", port = 47815, token = "tok", relayHost = "192.168.1.123" })
check("exact smartbuildos.c4z is the Agent", mirror.publish(true) == true)
check("ask goes to the Agent device", lastSent().id == 9)
check("ask uses the generic command", lastSent().command == "SBOS_DRIVER_STATE")
check("ask carries sku", lastSent().params.sku == "SBOS_TEST")
check("ask carries port as string", lastSent().params.port == "47815")
check("ask carries default path", lastSent().params.path == "/state")
check("ask carries the reachable relay host", lastSent().params.relay_host == "192.168.1.123")
check("ask carries token", lastSent().params.app_token == "tok")
check("ask identifies the requester", lastSent().params.requester == "55")
check("urgent flagged", lastSent().params.urgent == "true")

reset(true)
devices[9] = { driverFileName = "smartbuildos.c4i" }
mirror.setup({ sku = "SBOS_TEST", port = 1, token = "t" })
check("the .c4i form is also the Agent", mirror.publish(true) == true)

-- ─── configuration gate + throttle ────────────────────────────────────────────

reset(true)
mirror.setup({ sku = "SBOS_TEST", port = 47815 })
check("no token = not configured", mirror.isConfigured() == false)
check("unconfigured never sends", mirror.publish(true) == false and #sent == 0)
mirror.setToken("later-token")
mirror.setRelayHost("10.0.0.15")
check("setToken completes configuration", mirror.isConfigured() == true)
check("configured sends", mirror.publish(true) == true)
check("late token is the one sent", lastSent().params.app_token == "later-token")
check("late relay host is the one sent", lastSent().params.relay_host == "10.0.0.15")

reset(true)
mirror.setup({ sku = "SBOS_TEST", port = 47815, token = "tok" })
check("first steady-state ask sends", mirror.publish(false) == true)
check("second steady-state ask is throttled", mirror.publish(false) == false)
check("urgent bypasses the throttle", mirror.publish(true) == true)
check("throttle window is a minute", mirror.THROTTLE_SECONDS == 60)

reset(true)
mirror.setup({ sku = "SBOS_TEST", port = 47815, token = "tok", path = "status" })
mirror.publish(true)
check("a path without a leading slash is still sent verbatim", lastSent().params.path == "status")

-- ─── ack ──────────────────────────────────────────────────────────────────────

reset(true)
local viewCalls = {}
mirror.setup({
  sku = "SBOS_TEST",
  port = 1,
  token = "t",
  onView = function(url, handle)
    viewCalls[#viewCalls + 1] = { url = url, handle = handle }
  end,
})
mirror.onAck({ sku = "SBOS_OTHER", view_url = "https://x/y", view_handle = "H" })
check("ack for another sku is ignored", mirror.viewUrl() == nil and #viewCalls == 0)

mirror.onAck({ sku = "SBOS_TEST", view_url = "http://insecure/y", view_handle = "H" })
check("non-https view url refused", mirror.viewUrl() == nil)

mirror.onAck({
  sku = "SBOS_TEST",
  view_url = "https://app.example/api/public/driver/state",
  view_handle = "SBOS-A1B2C3",
})
check("valid ack stored", mirror.viewUrl() == "https://app.example/api/public/driver/state")
check("handle stored", mirror.viewHandle() == "SBOS-A1B2C3")
check("onView fired once", #viewCalls == 1)
mirror.onAck({
  sku = "SBOS_TEST",
  view_url = "https://app.example/api/public/driver/state",
  view_handle = "SBOS-A1B2C3",
})
check("identical ack does not re-fire onView", #viewCalls == 1)
mirror.onAck({ sku = "SBOS_TEST", view_url = "https://app.example/other", view_handle = "SBOS-A1B2C3" })
check("changed url re-fires onView", #viewCalls == 2)

reset(true)
mirror.setup({ sku = "SBOS_TEST", port = 1, token = "t" })
mirror.restoreView({ url = "https://app.example/restored", handle = "SBOS-ZZZ999" })
check("restoreView accepts https", mirror.viewUrl() == "https://app.example/restored")
mirror._reset()
mirror.setup({ sku = "SBOS_TEST", port = 1, token = "t" })
mirror.restoreView({ url = "http://nope", handle = "X" })
check("restoreView refuses non-https", mirror.viewUrl() == nil)
mirror.restoreView("garbage")
check("restoreView survives garbage", mirror.viewUrl() == nil)

-- ─── onConfig ─────────────────────────────────────────────────────────────────

reset(true)
local applied = {}
mirror.setup({ sku = "SBOS_TEST", port = 1, token = "t" })
local handler = mirror.onConfig(function(patch)
  applied[#applied + 1] = patch
  if patch.bad ~= nil then
    return { { path = "bad", reason = "unknown" } }
  end
  return {}
end)

handler({ sku = "SBOS_OTHER", settings = '{"a":1}', requester = "7" })
check("config for another sku is ignored", #applied == 0 and #sent == 0)

handler({ sku = "SBOS_TEST", settings = '{"a":1}', requester = "7", settings_version = "4" })
check("config applied", #applied == 1 and applied[1].a == 1)
check("ack sent to requester", lastSent().id == 7 and lastSent().command == "SBOS_DRIVER_CONFIG_ACK")
check("ack reports applied", lastSent().params.applied == "true")
check("ack reports zero refusals", lastSent().params.refused == "0")
check("ack echoes the version", lastSent().params.settings_version == "4")
check("ack carries the sku", lastSent().params.sku == "SBOS_TEST")

sent = {}
handler({ sku = "SBOS_TEST", settings = '{"bad":true}', requester = "7" })
check("refusals reported in the ack", lastSent().params.applied == "false" and lastSent().params.refused == "1")

sent = {}
applied = {}
handler({ sku = "SBOS_TEST", settings = "not json", requester = "7" })
check("undecodable payload is not applied", #applied == 0)
check("undecodable payload sends no ack", #sent == 0)

handler({ sku = "SBOS_TEST", requester = "7" })
check("missing settings is a no-op", #sent == 0)

local throwing = mirror.onConfig(function()
  error("apply blew up")
end)
local okCall = pcall(throwing, { sku = "SBOS_TEST", settings = "{}", requester = "7" })
check("a throwing apply does not propagate", okCall == true)
check("a throwing apply sends no ack", #sent == 0)

-- ─── result ───────────────────────────────────────────────────────────────────

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
