-- VenueFlow and the SmartBuildOS licence, including a simulated cloud outage.
--
-- The rule under test (core.lua "Licence"): the licence gates CONVENIENCE and
-- CONFIGURATION (scenes, rules, schedules, publishing, rollback), never
-- control. Only a definitive denial WITH server enforcement restricts
-- anything. No Agent, an unreachable cloud, an unauthenticated Agent and the
-- grace period all leave the venue fully working, and no licence change ever
-- switches a device off.
--
-- Run from the driver root: make test

local H = require("venueflow_harness")
local T = H.checker()
local check, eq = T.check, T.eq

-- ── the Agent's own decision table (src/sbos/license.lua) ───────────────────
print("when the licensing SDK enforces")
do
  local sent = {}
  C4.GetDevices = function()
    return { [50] = { deviceName = "SmartBuildOS Agent", driverFileName = "smartbuildos.c4z" } }
  end
  C4.GetDevicesByC4iName = function(_, file)
    return file == "smartbuildos.c4z" and { [50] = {} } or {}
  end
  C4.GetProjectItems = function()
    return ""
  end
  UpdateProperty = function() end
  SendToDevice = function(id, command, params)
    sent[#sent + 1] = { id = id, command = command, params = params }
  end
  SetTimer = function() end
  CancelTimer = function() end
  local license = require("sbos.license")
  license._reset()
  eq("before any Agent answer: LEGACY", license.status(), "LEGACY")
  eq("LEGACY never enforces", license.enforces(), false)
  license.setup({ sku = "SBOS_VENUEFLOW" })
  eq("the driver registers under its SKU", sent[1] and sent[1].params.sku, "SBOS_VENUEFLOW")
  local cases = {
    { "AUTHORIZED_SUBSCRIPTION", "enforce", false },
    { "AUTHORIZED_PERPETUAL", "enforce", false },
    { "AUTHORIZED_GRACE", "enforce", false }, -- the ten-day grace: fully working
    { "TRIAL", "enforce", false },
    { "CLOUD_VALIDATION_REQUIRED", "enforce", false }, -- the cloud cannot be reached
    { "AGENT_UNAUTHENTICATED", "enforce", false },
    { "NOT_ENTITLED", "observe", false }, -- a denial the server has not chosen to enforce
    { "ENTITLEMENT_EXPIRED", "observe", false },
    { "NOT_ENTITLED", "enforce", true },
    { "ENTITLEMENT_EXPIRED", "enforce", true },
    { "ACCOUNT_SUSPENDED", "enforce", true },
    { "CONTROLLER_MISMATCH", "enforce", true },
    { "SOMETHING_NEW", "enforce", false }, -- an unknown status is treated as an outage
  }
  for _, c in ipairs(cases) do
    license.onEntitlement({ sku = "SBOS_VENUEFLOW", status = c[1], enforcement = c[2] })
    eq(string.format("%s / %s", c[1], c[2]), license.enforces(), c[3])
  end
  license._reset()
end

-- ── a venue through an outage ───────────────────────────────────────────────
print("cloud outage: the venue is unaffected")
local env = H.new({ license = { enforce = false, label = "SmartBuildOS Agent Found - Checking..." } })
local studio = env.publishSample("sports_bar")
local S = { session = studio }
local m = env.login("manager", "2580")
local M = { session = m }
env.send("VENUE_STATUS", { status = "open" }, M)
env.settle(2000)
check("operator page loads", env.send("HELLO", {}, { tile = true }).ok)
check(
  "selecting and routing works",
  env.send("ROUTE_VIDEO", { sourceId = "sports-1", displayIds = { "tv-01", "tv-02" } }, M).ok
)
check("audio works", env.send("AUDIO_VOLUME", { zoneId = "zone-bar", level = 50 }, M).ok)
check("scenes work", env.send("SCENE_ACTIVATE", { sceneId = "game-day" }, M).ok)
env.settle(9000)
check(
  "the configuration loads and publishes",
  env.send("PUBLISH", { acknowledged = {} }, S).errorCode ~= "VF_LICENSE_RESTRICTED"
)
eq("state reports no restriction", env.send("GET_STATE", {}, M).data.state.license.restricted, false)
-- the Agent disappears altogether
env.license.label = "No SmartBuildOS Agent Found"
env.core:licenseChanged()
check("no Agent: still routing", env.send("ROUTE_VIDEO", { sourceId = "sports-2", displayIds = { "tv-03" } }, M).ok)
check("no Agent: still scenes", env.send("SCENE_ACTIVATE", { sceneId = "happy-hour" }, M).ok)
env.settle(8000)
check(
  "nothing in the core makes a network call",
  (function()
    local pipe = io.popen(
      "grep -l -E 'urlGet|urlPost|urlPut|CreateNetworkConnection|NetConnect|GetControllerNetworkAddress' src/venueflow/*.lua 2>/dev/null"
    )
    local found = pipe:read("*a")
    pipe:close()
    return found == ""
  end)()
)

-- ── a definitive denial with enforcement ────────────────────────────────────
print("restricted: automation stops, control does not")
env.send("PROGRAM_EXECUTE", {
  confirm = true,
  name = "mid-run",
  program = { steps = { { type = "wait", seconds = 20 }, { type = "volume", zoneId = "zone-dining", level = 33 } } },
}, S)
env.settle(2000)
local calls = env.sim():callCount()
local on = 0
for _, d in ipairs(env.core.config.displays) do
  if env.cell("display", d.id, "power").value == "on" then
    on = on + 1
  end
end
env.license.enforce = true
env.license.label = "Agent Linked - Not Licensed (see SmartBuildOS)"
env.core:licenseChanged()
eq("the change itself sends no command", env.sim():callCount(), calls)
local stillOn = 0
for _, d in ipairs(env.core.config.displays) do
  if env.cell("display", d.id, "power").value == "on" then
    stillOn = stillOn + 1
  end
end
eq("every display that was on is still on", stillOn, on)
check(
  "the restriction is in diagnostics and fires its event",
  table.concat(env.events, ","):find("license_restricted", 1, true) ~= nil
)
env.settle(25000)
eq("a run already in progress finishes", env.cell("zone", "zone-dining", "volume").value, 33)

eq("scene", env.send("SCENE_ACTIVATE", { sceneId = "happy-hour" }, M).errorCode, "VF_LICENSE_RESTRICTED")
eq("publish", env.send("PUBLISH", { acknowledged = {} }, S).errorCode, "VF_LICENSE_RESTRICTED")
eq("rollback", env.send("ROLLBACK", { versionId = "v1", confirm = true }, S).errorCode, "VF_LICENSE_RESTRICTED")
eq(
  "installer live test of a program",
  env.send("PROGRAM_EXECUTE", { confirm = true, program = { steps = {} } }, S).errorCode,
  "VF_LICENSE_RESTRICTED"
)
eq("Composer scene", env.core:composer("ACTIVATE_SCENE", { SCENE = "Happy Hour" }), false)
local before = env.core.runtime.lastRun["rule:patio-follows-status"]
env.send("VENUE_STATUS", { status = "closed" }, M)
env.send("VENUE_STATUS", { status = "open" }, M)
env.settle(3000)
eq("a triggered rule does not run", env.core.runtime.lastRun["rule:patio-follows-status"], before)

check("route", env.send("ROUTE_VIDEO", { sourceId = "sports-3", displayIds = { "tv-04" } }, M).ok)
check("power", env.send("DISPLAY_POWER", { displayIds = { "tv-05" }, power = "off" }, M).ok)
check("volume", env.send("AUDIO_VOLUME", { zoneId = "zone-bar", level = 20 }, M).ok)
check("mute", env.send("AUDIO_MUTE", { zoneId = "zone-bar", muted = true }, M).ok)
check("lighting", env.send("LIGHTING_PRESET", { lightingId = "house-lights", presetId = "bright" }, M).ok)
check("venue status", env.send("VENUE_STATUS", { status = "open" }, M).ok)
check("query status", env.send("QUERY_STATUS", {}, M).ok)
check("All Off", env.send("ALL_OFF", { confirm = true }, M).ok)
check("Composer All Off", env.core:composer("ALL_OFF", {}))
check("Composer route", env.core:composer("ROUTE_SOURCE", { SOURCE = "Sports 1", TARGET = "TV 01" }))
check("the Studio stays readable", env.send("STUDIO_BOOTSTRAP", {}, S).ok)
check(
  "the draft can still be edited",
  (function()
    local draft = env.send("DRAFT_GET", {}, S).data.draft
    return env.send("DRAFT_SAVE", { config = draft.config, baseRevision = draft.revision }, S).ok
  end)()
)
check("a backup can still be exported", env.send("BACKUP_EXPORT", {}, S).ok)
check("a dry run is still allowed (it sends nothing)", env.send("PROGRAM_DRY_RUN", { program = { steps = {} } }, S).ok)
local state = env.send("GET_STATE", {}, M).data.state
eq("the state says restricted", state.license.restricted, true)
check(
  "the manager is told in plain words",
  (function()
    for _, a in ipairs(state.alerts) do
      if a.id == "license" then
        return a.detail:find("Manual control keeps working", 1, true) ~= nil
      end
    end
    return false
  end)()
)
local lic = env.send("LICENSE_GET", {}, S).data.license
check("the Studio shows the policy", lic.restricted == true and type(lic.policy.always) == "string")

-- ── restored ────────────────────────────────────────────────────────────────
print("restored")
env.settle(9000)
env.license.enforce = false
env.license.label = "Licensed / Subscribed"
env.core:licenseChanged()
check("restored event", table.concat(env.events, ","):find("license_restored", 1, true) ~= nil)
check("scenes again", env.send("SCENE_ACTIVATE", { sceneId = "happy-hour" }, M).ok)
env.settle(8000)
local acks = {}
for _, i in ipairs(env.send("DRAFT_GET", {}, S).data.draft.issues) do
  acks[#acks + 1] = i.id
end
check("publish again", env.send("PUBLISH", { acknowledged = acks }, S).ok)

T.done()
