-- VenueFlow: the Venue Studio as the venue's own people get it (a client
-- session). A staff profile that holds the `studio` permission and signed in
-- with its PIN may change scenes, schedules, staff, source names and channel
-- labels, and volume presets, and publish that. Everything else stays the
-- installer's. The DRIVER decides; hand-made requests stand in for a
-- tampered page throughout.
--
-- SIMULATION-verified (see venueflow_harness.lua).
--
-- Run from the driver root: make test

local H = require("venueflow_harness")
local ClientScope = require("venueflow.clientscope")
local T = H.checker()
local check, eq = T.check, T.eq

local function copy(t)
  return H.JSON:decode(H.JSON:encode(t))
end

local function acks(env, session)
  local out = {}
  local r = env.send("DRAFT_VALIDATE", {}, { session = session })
  for _, i in ipairs(r.data and r.data.issues or {}) do
    out[#out + 1] = i.id
  end
  return out
end

local env = H.new()
local installer = env.publishSample("sports_bar")
local I = { session = installer }

-- ── who gets in ─────────────────────────────────────────────────────────────
print("who may open the Venue Studio")
local managerToken, loginReply = env.login("manager", "2580")
check("the manager signs in with the PIN", managerToken ~= nil)
eq("the sign-in reply says the Studio is open to them", loginReply.data.studio, true)
local C = { session = managerToken }
local boot = env.send("STUDIO_BOOTSTRAP", {}, C)
eq("a client session opens the Studio", boot.ok, true)
eq("...as a client", boot.data.role, "client")
eq("...named by its profile", boot.data.who, "Manager")
eq("...and may publish", boot.data.client.canPublish, true)
check("no controller detail goes to a client", next(boot.data.info) == nil)
local bootText = H.JSON:encode(boot)
check(
  "no PIN material goes to a client",
  not bootText:find("pinHash", 1, true) and not bootText:find("pinSalt", 1, true)
)
eq("the installer's bootstrap says installer", env.send("STUDIO_BOOTSTRAP", {}, I).data.role, "installer")

eq("no session: refused", env.send("STUDIO_BOOTSTRAP", {}).errorCode, "VF_UNAUTHENTICATED")
eq("a tile is not a Studio session", env.send("DRAFT_GET", {}, { tile = true }).errorCode, "VF_UNAUTHENTICATED")
local hello = env.send("HELLO", {}, C)
eq("HELLO tells the operator page the Studio is open", hello.data.studio, true)
eq("...and not for a tile", env.send("HELLO", {}, { tile = true }).data.studio, nil)

-- A profile without the permission, signed in with a PIN, is refused.
local draft = copy(env.send("DRAFT_GET", {}, I).data.draft.config)
local rev = env.send("DRAFT_GET", {}, I).data.draft.revision
eq("the host has no Studio permission", draft.profiles[3].permissions.studio, false)
eq(
  "the installer gives the host a PIN",
  env.send("PROFILE_PIN_SET", { profileId = "host", pin = "4321", baseRevision = rev }, I).ok,
  true
)
eq("...and publishes", env.send("PUBLISH", { acknowledged = acks(env, installer) }, I).ok, true)
local hostToken = env.login("host", "4321")
check("the host signs in", hostToken ~= nil)
eq(
  "...and the Studio refuses them",
  env.send("STUDIO_BOOTSTRAP", {}, { session = hostToken }).errorCode,
  "VF_FORBIDDEN"
)
eq("...draft included", env.send("DRAFT_GET", {}, { session = hostToken }).errorCode, "VF_FORBIDDEN")
managerToken = env.login("manager", "2580")
C = { session = managerToken }

-- ── what a client may change ────────────────────────────────────────────────
print("what a client may change")
local function draftNow(o)
  local d = env.send("DRAFT_GET", {}, o or C).data.draft
  return copy(d.config), d.revision
end
local cfg, r0 = draftNow()
cfg.scenes[1].name = "Doors Open"
cfg.sources[1].name = "Game of the Week"
cfg.sources[1].channel = "ESPN 206"
cfg.audioZones[1].presets[1].level = 30
cfg.profiles[2].name = "Bar Team"
cfg.profiles[2].permissions.audio = false
for _, rule in ipairs(cfg.rules) do
  if rule.trigger.type == "schedule" then
    rule.trigger.time = "10:30"
  end
end
cfg.rules[#cfg.rules + 1] = {
  id = "late-close",
  name = "Late close",
  enabled = true,
  trigger = { type = "schedule", days = { 6, 7 }, time = "23:30" },
  program = { steps = { { type = "run_scene", sceneId = cfg.scenes[1].id } } },
}
local saved = env.send("DRAFT_SAVE", { config = cfg, baseRevision = r0 }, C)
eq("scenes, schedules, staff, source names, channel and presets save", saved.ok, true)
local pinSet = env.send("PROFILE_PIN_SET", { profileId = "host", pin = "1357", baseRevision = saved.data.revision }, C)
eq("a client sets a staff PIN", pinSet.ok, true)
eq("a client validates", env.send("DRAFT_VALIDATE", {}, C).ok, true)
check("the client is told which warnings are live already", #boot.data.client.liveWarnings >= 1)
-- The sample's one warning (a custom route command) is the installer's and is
-- live already, so a client is not asked about it again. Moving both
-- schedules to the same time is the client's own doing, and that warning
-- still needs their tick.
local unticked = env.send("PUBLISH", { note = "new hours" }, C)
eq("a warning the client's own change brings blocks the publish", unticked.errorCode, "VF_VALIDATION_FAILED")
local own = {}
for _, i in ipairs(unticked.data.blocking) do
  own[#own + 1] = i.id
end
eq("...and it is the only thing asked", #own, 1)
check("...the schedules, not the installer's route command", own[1]:find("SCHEDULE_OVERLAP", 1, true) ~= nil, own[1])
local published = env.send("PUBLISH", { acknowledged = own, note = "new hours" }, C)
check("a client publishes their own changes", published.ok == true, H.JSON:encode(published):sub(1, 600))
eq("the version records who", published.data.published.by, "profile:manager")
eq("the scene is live", env.core.config.scenes[1].name, "Doors Open")
eq("the channel label is live", env.core.config.sources[1].channel, "ESPN 206")
eq("the manager keeps their session (their PIN did not change)", env.send("DRAFT_GET", {}, C).ok, true)
local opHello = env.send("HELLO", {}, C)
local seenChannel
for _, s in ipairs(opHello.data.config.sources) do
  if s.id == cfg.sources[1].id then
    seenChannel = s.channel
  end
end
eq("the operator page receives the channel label", seenChannel, "ESPN 206")
eq("the new PIN works", env.login("host", "1357") ~= nil, true)
eq("...and the old one does not", env.login("host", "4321"), nil)

-- ── what a client may not change ────────────────────────────────────────────
print("what stays the installer's")
local function refused(name, mutate, key)
  local c, rv = draftNow()
  mutate(c)
  local out = env.send("DRAFT_SAVE", { config = c, baseRevision = rv }, C)
  eq(name .. ": refused", out.errorCode, "VF_FORBIDDEN")
  eq(name .. ": names the part", out.data and out.data.installerOnly ~= nil, true)
  if key ~= nil then
    local k = ClientScope.changed(env.core.store:draft().config, c)
    eq(name .. ": the part is " .. key, k, key)
  end
  local _, after = draftNow()
  eq(name .. ": the draft is untouched", after, rv)
end
refused("a display's Control4 room", function(c)
  c.displays[1].c4RoomId = 9999
end, "displays")
refused("a display's route", function(c)
  c.displays[1].route = { strategy = "none" }
end, "displays")
refused("a source's Control4 device", function(c)
  c.sources[1].c4DeviceId = 4242
end, "sources")
refused("switching a source off", function(c)
  c.sources[1].enabled = false
end, "sources")
refused("a new source", function(c)
  c.sources[#c.sources + 1] = { id = "extra", name = "Extra", kind = "streaming", video = true, audio = true }
end, "sources")
refused("a zone's volume limit", function(c)
  c.audioZones[1].maxVolume = 100
end, "audioZones")
refused("the floor layout", function(c)
  c.displays[1].layout.x = 1
end, "displays")
refused("the venue record", function(c)
  c.venue.name = "Mine Now"
end, "venue")
refused("the profile a screen opens with", function(c)
  c.defaultProfileId = "manager"
end, "defaultProfileId")
refused("a station", function(c)
  c.stations[#c.stations + 1] = { id = "s1", name = "S1", address = "10.0.0.31", profileId = "bartender" }
end, "stations")
refused("a rule that is not a schedule", function(c)
  for _, rule in ipairs(c.rules) do
    if rule.trigger.type ~= "schedule" then
      rule.enabled = not rule.enabled
      return
    end
  end
  c.rules[#c.rules + 1] = {
    id = "on-open",
    name = "On open",
    enabled = true,
    trigger = { type = "venue_status", is = "open" },
    program = { steps = {} },
  }
end, "rules")
refused("a new rule on an event", function(c)
  c.rules[#c.rules + 1] = {
    id = "on-open-2",
    name = "On open",
    enabled = true,
    trigger = { type = "venue_status", is = "open" },
    program = { steps = {} },
  }
end, "rules")
refused("granting the Studio to someone else", function(c)
  c.profiles[2].permissions.studio = true
end, "profiles")
refused("dropping their own Studio permission", function(c)
  c.profiles[1].permissions.studio = false
end, "profiles")
refused("a new profile that holds the Studio", function(c)
  local p = copy(c.profiles[2])
  p.id, p.name, p.permissions.studio = "shadow", "Shadow", true
  c.profiles[#c.profiles + 1] = p
end, "profiles")
refused("removing the profile that holds the Studio", function(c)
  table.remove(c.profiles, 1)
end, "profiles")

print("installer-only commands")
for _, case in ipairs({
  { "TEMPLATE_APPLY", { venueType = "sports_bar", confirm = true } },
  { "BACKUP_EXPORT", {} },
  { "BACKUP_RESTORE", { backup = {}, confirm = true } },
  { "DISCOVER", {} },
  { "DIAG_GET", {} },
  { "DIAG_CLEAR", {} },
  { "LICENSE_GET", {} },
  { "SESSIONS_REVOKE", {} },
  { "SIM_FAULT", { targetId = 1101, fault = "offline" } },
  { "IMAGE_PUT", { dataUrl = "data:image/png;base64,AAAA" } },
  { "EXECUTION_CANCEL", { executionId = "x" } },
}) do
  eq(case[1] .. " is refused to a client", env.send(case[1], case[2], C).errorCode, "VF_FORBIDDEN")
end
local up = env.core:upload("data:image/png;base64,AAAA", managerToken)
eq("a picture upload is refused to a client", up.ok, false)
eq("a dry run is allowed", env.send("PROGRAM_DRY_RUN", { program = { steps = {} } }, C).ok, true)
eq("the version list is allowed", env.send("VERSIONS", {}, C).ok, true)

-- ── the installer's unfinished work ─────────────────────────────────────────
print("the installer's unfinished changes")
local icfg, irev = draftNow(I)
icfg.venue.name = "Riverside (new sign)"
eq(
  "the installer saves a change of their own",
  env.send("DRAFT_SAVE", { config = icfg, baseRevision = irev }, I).ok,
  true
)
local standing = env.send("STUDIO_BOOTSTRAP", {}, C).data.client
eq("the client is told they cannot publish", standing.canPublish, false)
check("...and why", type(standing.installerPending) == "string")
local blocked = env.send("PUBLISH", { acknowledged = acks(env, managerToken) }, C)
eq("a client cannot publish the installer's draft", blocked.errorCode, "VF_FORBIDDEN")
eq("...with the reason marked", blocked.data.installerPending, true)
eq("a client cannot discard it either", env.send("DRAFT_DISCARD", { confirm = true }, C).errorCode, "VF_FORBIDDEN")
local ccfg, crev = draftNow()
ccfg.scenes[1].name = "Doors"
eq(
  "a client can still edit their own part of it",
  env.send("DRAFT_SAVE", { config = ccfg, baseRevision = crev }, C).ok,
  true
)
eq("the installer's change is still there", env.core.store:draft().config.venue.name, "Riverside (new sign)")
local ipub = env.send("PUBLISH", { acknowledged = acks(env, installer) }, I)
eq("the installer publishes both", ipub.ok, true)
eq("the client may publish again", env.send("STUDIO_BOOTSTRAP", {}, C).data.client.canPublish, true)

-- ── going back ──────────────────────────────────────────────────────────────
print("rollback")
local history = env.send("VERSIONS", {}, C).data.history
-- history[1] is the version before the installer's venue rename.
local back = env.send("ROLLBACK", { versionId = history[1].versionId, confirm = true }, C)
eq("a client cannot go back across an installer change", back.errorCode, "VF_FORBIDDEN")
local c2, r2 = draftNow()
c2.scenes[1].name = "Doors Wide Open"
eq("a client edits", env.send("DRAFT_SAVE", { config = c2, baseRevision = r2 }, C).ok, true)
eq("...and publishes", env.send("PUBLISH", { acknowledged = acks(env, managerToken) }, C).ok, true)
history = env.send("VERSIONS", {}, C).data.history
eq(
  "a client must confirm a rollback",
  env.send("ROLLBACK", { versionId = history[1].versionId }, C).errorCode,
  "VF_CONFIRM_REQUIRED"
)
local ownBack = env.send("ROLLBACK", { versionId = history[1].versionId, confirm = true }, C)
eq("a client goes back over their own change", ownBack.ok, true)
eq("the earlier scene name is live", env.core.config.scenes[1].name, "Doors")

-- ── the permission ends, the session ends ───────────────────────────────────
print("losing the permission")
managerToken = env.login("manager", "2580")
C = { session = managerToken }
eq("the manager is in", env.send("DRAFT_GET", {}, C).ok, true)
local d3, r3 = draftNow(I)
d3.profiles[1].permissions.studio = false
eq("the installer takes the permission away", env.send("DRAFT_SAVE", { config = d3, baseRevision = r3 }, I).ok, true)
eq("...publishes", env.send("PUBLISH", { acknowledged = acks(env, installer) }, I).ok, true)
eq("the same session is now refused", env.send("DRAFT_GET", {}, C).errorCode, "VF_FORBIDDEN")
eq("...but still runs the venue", env.send("GET_STATE", {}, C).ok, true)

-- ── the schema ──────────────────────────────────────────────────────────────
print("schema")
local Schema = require("venueflow.schema")
local Templates = require("venueflow.templates")
eq("the Owner role holds the Studio", Templates.profile("owner").permissions.studio, true)
eq("the Manager role does not, until the installer grants it", Templates.profile("manager").permissions.studio, false)
local venue = Schema.normalize(Templates.venue("restaurant", "Test"))
local owner = Templates.profile("owner")
venue.profiles[#venue.profiles + 1] = owner
local sawNoPin = false
for _, i in ipairs(Schema.validate(venue)) do
  if i.code == "STUDIO_NO_PIN" then
    sawNoPin = true
  end
end
check("a Studio holder without a PIN is flagged", sawNoPin)
venue.sources[1] =
  { id = "s1", name = "S1", kind = "streaming", video = true, audio = true, channel = string.rep("x", 41) }
local sawChannel = false
for _, i in ipairs(Schema.validate(venue)) do
  if i.code == "CHANNEL_INVALID" then
    sawChannel = true
  end
end
check("an over-long channel label is refused", sawChannel)

T.done()
