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
-- profiles[3] is the host: a staff profile no screen opens with (the default
-- profile, the bartender, stays the installer's: see below).
cfg.profiles[3].name = "Front Desk"
cfg.profiles[3].permissions.audio = false
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

-- ── the profiles a screen opens with ────────────────────────────────────────
-- A tile opens as the default profile without a PIN, and a station opens as
-- its profile by a LAN address: whatever those profiles may do, anyone on the
-- LAN may do. Their whole records stay as the installer left them.
print("the profiles a screen or station opens with")
do
  local e = H.new()
  local inst = { session = e.publishSample("sports_bar") }
  local ic, ir = (function()
    local d = e.send("DRAFT_GET", {}, inst).data.draft
    return copy(d.config), d.revision
  end)()
  ic.stations = { { id = "host-stand", name = "Host station", address = "10.0.0.31", profileId = "host" } }
  eq(
    "the installer adds a station that opens as the host",
    e.send("DRAFT_SAVE", { config = ic, baseRevision = ir }, inst).ok,
    true
  )
  eq("...and publishes", e.send("PUBLISH", { acknowledged = acks(e, inst.session) }, inst).ok, true)
  local TILE, STATION = { tile = true }, { tile = true, client = "10.0.0.31" }
  eq("a tile may not run All Off", e.send("ALL_OFF", { confirm = true }, TILE).errorCode, "VF_FORBIDDEN")
  eq("nor may the station", e.send("ALL_OFF", { confirm = true }, STATION).errorCode, "VF_FORBIDDEN")
  local mgr = { session = e.login("manager", "2580") }
  local function clientSave(mutate)
    local d = e.send("DRAFT_GET", {}, mgr).data.draft
    local c = copy(d.config)
    mutate(c)
    return e.send("DRAFT_SAVE", { config = c, baseRevision = d.revision }, mgr), d.revision
  end
  local function profile(c, id)
    for _, p in ipairs(c.profiles) do
      if p.id == id then
        return p
      end
    end
  end
  local widened, before = clientSave(function(c)
    for k, v in pairs(profile(c, c.defaultProfileId).permissions) do
      if k ~= "studio" then
        profile(c, c.defaultProfileId).permissions[k] = (type(v) == "boolean") and true or "all"
      end
    end
  end)
  eq("a client cannot widen the default profile", widened.errorCode, "VF_FORBIDDEN")
  eq(
    "...refused as installer-only",
    widened.data and widened.data.installerOnly,
    "the profile a screen or station opens with"
  )
  eq("...the draft is untouched", e.send("DRAFT_GET", {}, mgr).data.draft.revision, before)
  eq(
    "a client cannot rename it either",
    clientSave(function(c)
      profile(c, "bartender").name = "Anyone"
    end).errorCode,
    "VF_FORBIDDEN"
  )
  eq(
    "nor remove it",
    clientSave(function(c)
      for i, p in ipairs(c.profiles) do
        if p.id == "bartender" then
          table.remove(c.profiles, i)
          break
        end
      end
    end).errorCode,
    "VF_FORBIDDEN"
  )
  eq(
    "a client cannot widen a station's profile",
    clientSave(function(c)
      profile(c, "host").permissions.allOff = true
    end).errorCode,
    "VF_FORBIDDEN"
  )
  eq(
    "nor change the station profile's areas",
    clientSave(function(c)
      profile(c, "host").permissions.areas = { "patio" }
    end).errorCode,
    "VF_FORBIDDEN"
  )
  -- Any other staff profile is still the client's.
  local staff, _ = clientSave(function(c)
    local p = copy(profile(c, "host"))
    p.id, p.name, p.permissions.allOff = "floor-lead", "Floor lead", true
    p.hasPin = nil
    c.profiles[#c.profiles + 1] = p
  end)
  eq("a client may add a staff profile no screen opens with", staff.ok, true)
  eq(
    "...and change it",
    clientSave(function(c)
      profile(c, "floor-lead").permissions.routeVideo = true
      profile(c, "manager").name = "Head manager"
    end).ok,
    true
  )
  eq("...and publish it", e.send("PUBLISH", { acknowledged = acks(e, mgr.session) }, mgr).ok, true)
  eq("the tile still may not run All Off", e.send("ALL_OFF", { confirm = true }, TILE).errorCode, "VF_FORBIDDEN")
  eq("nor may the station", e.send("ALL_OFF", { confirm = true }, STATION).errorCode, "VF_FORBIDDEN")
  -- A PIN on the default profile (PROFILE_PIN_SET) is refused to a client
  -- (more below), so every tile keeps working.
  local dr = e.send("DRAFT_GET", {}, mgr).data.draft.revision
  local pinSet = e.send("PROFILE_PIN_SET", { profileId = "bartender", pin = "9999", baseRevision = dr }, mgr)
  eq("a client cannot put a PIN on the default profile", pinSet.errorCode, "VF_FORBIDDEN")
  eq("...and tiles still open without one", e.send("HELLO", {}, TILE).data.profile.id, "bartender")
  -- The installer still may change them.
  local d = e.send("DRAFT_GET", {}, inst).data.draft
  local c = copy(d.config)
  profile(c, "bartender").name = "Bar tablet"
  eq(
    "the installer may change the default profile",
    e.send("DRAFT_SAVE", { config = c, baseRevision = d.revision }, inst).ok,
    true
  )
end

-- ── whose work is in the draft ──────────────────────────────────────────────
-- The installer's (or the dealer's) unfinished work is theirs even in a part
-- a client may change: a half-built schedule must not go live, or be thrown
-- away, because a client pressed Publish or Discard.
print("whose work is in the draft")
do
  local e = H.new()
  local inst = { session = e.publishSample("sports_bar") }
  local mgr = { session = e.login("manager", "2580") }
  local function save(o, mutate)
    local d = e.send("DRAFT_GET", {}, o).data.draft
    local c = copy(d.config)
    mutate(c)
    return e.send("DRAFT_SAVE", { config = c, baseRevision = d.revision }, o)
  end
  local function wip(c)
    c.rules[#c.rules + 1] = {
      id = "wip-sched",
      name = "WIP: everything on at 12:01",
      enabled = true,
      trigger = { type = "schedule", days = { 1, 2, 3, 4, 5, 6, 7 }, time = "12:01" },
      program = { steps = { { type = "display_power", target = { all = true }, power = "on" } } },
    }
  end
  local function live(id)
    for _, r in ipairs(e.core.config.rules) do
      if r.id == id then
        return true
      end
    end
    return false
  end
  eq("the installer saves an unfinished schedule", save(inst, wip).ok, true)
  local st = e.send("STUDIO_BOOTSTRAP", {}, mgr).data.client
  eq("the client is told the installer has unfinished work", type(st.installerPending), "string")
  eq("...and cannot publish", st.canPublish, false)
  local pub = e.send("PUBLISH", { acknowledged = acks(e, mgr.session) }, mgr)
  eq("a client's publish is refused", pub.errorCode, "VF_FORBIDDEN")
  eq("...as the installer's unfinished work", pub.data and pub.data.installerPending, true)
  eq("...and the schedule is not live", live("wip-sched"), false)
  eq("a client's discard is refused", e.send("DRAFT_DISCARD", { confirm = true }, mgr).errorCode, "VF_FORBIDDEN")
  eq(
    "...and the schedule is still in the draft",
    e.core.store:draft().config.rules[#e.core.store:draft().config.rules].id,
    "wip-sched"
  )
  eq(
    "a client may edit on top",
    save(mgr, function(c)
      c.scenes[1].name = "Client's name"
    end).ok,
    true
  )
  eq(
    "...and it is still the installer's to publish",
    e.send("PUBLISH", { acknowledged = acks(e, mgr.session) }, mgr).errorCode,
    "VF_FORBIDDEN"
  )
  eq("the installer publishes both", e.send("PUBLISH", { acknowledged = acks(e, inst.session) }, inst).ok, true)
  eq("...the schedule is live", live("wip-sched"), true)
  eq("...and the draft is nobody's unfinished work", #(e.core.store:draft().savedBy or {}), 0)
  eq("the client may publish again", e.send("STUDIO_BOOTSTRAP", {}, mgr).data.client.canPublish, true)

  -- A client's own save is the client's: the installer may publish it.
  eq(
    "a client saves",
    save(mgr, function(c)
      c.scenes[1].name = "Doors"
    end).ok,
    true
  )
  eq("...the client could publish it", e.send("STUDIO_BOOTSTRAP", {}, mgr).data.client.canPublish, true)
  eq(
    "the installer publishes the client's work",
    e.send("PUBLISH", { acknowledged = acks(e, inst.session) }, inst).ok,
    true
  )

  -- The dealer's remote save is the installer's side too.
  local snap = e.core:remote("snapshot", {}, "draft")
  local rc = copy(snap.data.draft.config)
  rc.scenes[1].name = "Dealer's scene"
  local rs = e.core:remote("save_draft", { config = rc, baseRevision = snap.data.draft.revision }, "draft")
  eq("the dealer saves remotely", rs.ok, true)
  eq(
    "a client cannot publish the dealer's work",
    e.send("PUBLISH", { acknowledged = acks(e, mgr.session) }, mgr).errorCode,
    "VF_FORBIDDEN"
  )
  eq("nor discard it", e.send("DRAFT_DISCARD", { confirm = true }, mgr).errorCode, "VF_FORBIDDEN")
  eq("the installer discards it", e.send("DRAFT_DISCARD", { confirm = true }, inst).ok, true)
  eq("...and a discard clears it too", e.send("STUDIO_BOOTSTRAP", {}, mgr).data.client.canPublish, true)

  -- An optional baseRevision: Publish and Discard of exactly what was loaded.
  eq(
    "a client saves again",
    save(mgr, function(c)
      c.scenes[1].name = "Doors again"
    end).ok,
    true
  )
  local now = e.send("DRAFT_GET", {}, mgr).data.draft.revision
  eq(
    "a publish naming an older revision is refused as stale",
    e.send("PUBLISH", { acknowledged = acks(e, mgr.session), baseRevision = now - 1 }, mgr).errorCode,
    "VF_STALE_DRAFT"
  )
  eq(
    "so is a discard",
    e.send("DRAFT_DISCARD", { confirm = true, baseRevision = now - 1 }, mgr).errorCode,
    "VF_STALE_DRAFT"
  )
  eq(
    "...the installer's too",
    e.send("PUBLISH", { acknowledged = acks(e, inst.session), baseRevision = now + 5 }, inst).errorCode,
    "VF_STALE_DRAFT"
  )
  eq("...and nothing was published", e.core.config.scenes[1].name, "Doors")
  eq(
    "a publish naming the current revision goes through",
    e.send("PUBLISH", { acknowledged = acks(e, mgr.session), baseRevision = now }, mgr).ok,
    true
  )
  local after = e.send("DRAFT_GET", {}, mgr).data.draft.revision
  eq("so does a discard naming it", e.send("DRAFT_DISCARD", { confirm = true, baseRevision = after }, mgr).ok, true)
end

-- ── PINs, templates and whose work is in the draft ─────────────────────────
print("PINs and templates: refused or attributed")
do
  local e = H.new()
  local inst = { session = e.publishSample("sports_bar") }
  local d = e.send("DRAFT_GET", {}, inst).data.draft
  local c = copy(d.config)
  c.stations = { { id = "host-stand", name = "Host station", address = "10.0.0.31", profileId = "host" } }
  eq(
    "the installer adds a station that opens as the host",
    e.send("DRAFT_SAVE", { config = c, baseRevision = d.revision }, inst).ok,
    true
  )
  eq("...and publishes", e.send("PUBLISH", { acknowledged = acks(e, inst.session) }, inst).ok, true)
  local mgr = { session = e.login("manager", "2580") }
  local function rev()
    return e.send("DRAFT_GET", {}, mgr).data.draft.revision
  end
  local function pinOf(id)
    for _, p in ipairs(e.core.store:draft().config.profiles) do
      if p.id == id then
        return p.pinHash
      end
    end
  end
  for _, case in ipairs({
    { "a client's PIN on the default profile", "bartender", "9999" },
    { "a client's PIN on a station's profile", "host", "9999" },
    { "a client clearing the default profile's PIN", "bartender", "" },
    { "a client clearing a station profile's PIN", "host", "" },
  }) do
    local before = rev()
    local r = e.send("PROFILE_PIN_SET", { profileId = case[2], pin = case[3], baseRevision = before }, mgr)
    eq(case[1] .. ": refused there and then", r.errorCode, "VF_FORBIDDEN")
    eq(case[1] .. ": as installer-only", r.data and r.data.installerOnly, "the profile a screen or station opens with")
    eq(case[1] .. ": the draft is untouched", rev(), before)
  end
  eq("...no PIN reached the default profile", pinOf("bartender"), nil)
  eq("...nor the station's", pinOf("host"), nil)

  -- A client's PIN on an ordinary staff profile is the client's work.
  local own = e.send("PROFILE_PIN_SET", { profileId = "manager", pin = "2468", baseRevision = rev() }, mgr)
  eq("a client sets a PIN on an ordinary staff profile", own.ok, true)
  eq("...the draft records the client", e.core.store:draft().savedBy[1], "profile:manager")
  eq("...and the client may still publish", e.send("STUDIO_BOOTSTRAP", {}, mgr).data.client.canPublish, true)
  eq("...and does", e.send("PUBLISH", { acknowledged = acks(e, mgr.session) }, mgr).ok, true)
  mgr = { session = e.login("manager", "2468") }
  check("the new PIN signs in", mgr.session ~= nil)

  -- The installer's PIN is the installer's work, wherever it is set.
  local ip = e.send("PROFILE_PIN_SET", { profileId = "manager", pin = "1357", baseRevision = rev() }, inst)
  eq("the installer sets a staff PIN", ip.ok, true)
  local st = e.send("STUDIO_BOOTSTRAP", {}, mgr).data.client
  eq("...the client may not publish it", st.canPublish, false)
  eq(
    "...a client's publish is refused",
    e.send("PUBLISH", { acknowledged = acks(e, mgr.session) }, mgr).errorCode,
    "VF_FORBIDDEN"
  )
  eq("...and so is a client's discard", e.send("DRAFT_DISCARD", { confirm = true }, mgr).errorCode, "VF_FORBIDDEN")
  eq(
    "the installer may set the default profile's PIN",
    e.send("PROFILE_PIN_SET", { profileId = "bartender", pin = "8642", baseRevision = rev() }, inst).ok,
    true
  )
  eq(
    "...and clear it",
    e.send("PROFILE_PIN_SET", { profileId = "bartender", pin = "", baseRevision = rev() }, inst).ok,
    true
  )
  eq("the installer discards", e.send("DRAFT_DISCARD", { confirm = true }, inst).ok, true)
end
do
  -- A template or sample applied by the installer is installer work, even
  -- when it changes nothing an installer-owned comparison would see (the
  -- published sample, applied again: only the staff PIN salts differ).
  local e = H.new()
  local inst = { session = e.publishSample("sports_bar") }
  local mgr = { session = e.login("manager", "2580") }
  eq(
    "the installer re-applies the published sample",
    e.send("TEMPLATE_APPLY", { venueType = "sports_bar", sample = true, confirm = true }, inst).ok,
    true
  )
  eq("...the draft records the installer", e.core.store:draft().savedBy[1], "installer")
  eq("...a client may not publish it", e.send("STUDIO_BOOTSTRAP", {}, mgr).data.client.canPublish, false)
  eq("...nor discard it", e.send("DRAFT_DISCARD", { confirm = true }, mgr).errorCode, "VF_FORBIDDEN")
end

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

-- ── a client's scene that tunes a source; a favourite it uses removed ──────
print("a tune step in the client's hands")
do
  local e = H.new()
  e.publishSample("sports_bar")
  local CM = { session = e.login("manager", "2580") }
  local function draft()
    local d = e.send("DRAFT_GET", {}, CM).data.draft
    return copy(d.config), d.revision
  end
  local function publish()
    local own = {}
    for _, i in ipairs(e.send("DRAFT_VALIDATE", {}, CM).data.issues) do
      if i.severity ~= "error" then
        own[#own + 1] = i.id
      end
    end
    return e.send("PUBLISH", { acknowledged = own, note = "tune" }, CM)
  end
  local function sceneOf(c, id)
    for _, sc in ipairs(c.scenes) do
      if sc.id == id then
        return sc
      end
    end
  end
  local c, rev = draft()
  local gameDay = sceneOf(c, "game-day")
  table.insert(gameDay.program.steps, 3, { type = "tune", sourceId = "sports-1", favoriteId = "sports-a" })
  c.rules[#c.rules + 1] = {
    id = "lobby-news",
    name = "Lobby news",
    enabled = true,
    trigger = { type = "schedule", days = { 1, 2, 3, 4, 5 }, time = "07:00" },
    program = { steps = { { type = "tune", sourceId = "news", channel = "202" } } },
  }
  local saved = e.send("DRAFT_SAVE", { config = c, baseRevision = rev }, CM)
  eq("a client adds a tune step to a scene and a schedule", saved.ok, true)
  local p1 = publish()
  eq("...and publishes them", p1.ok, true)
  eq("...the scene's step is live", sceneOf(e.core.config, "game-day").program.steps[3].favoriteId, "sports-a")

  c, rev = draft()
  c.sources[1].favorites = { c.sources[1].favorites[2], c.sources[1].favorites[3] } -- Sports A goes
  eq("a client may remove a favourite channel", e.send("DRAFT_SAVE", { config = c, baseRevision = rev }, CM).ok, true)
  local refused = publish()
  eq("...but not publish while a scene still uses it", refused.errorCode, "VF_VALIDATION_FAILED")
  local said
  for _, b in ipairs(refused.data.blocking) do
    if b.code == "REF_UNKNOWN" then
      said = b.message
    end
  end
  eq(
    "...the issue names the scene and what to do",
    said,
    "Scene 'Game Day' tunes Sports 1 to a favourite channel that no longer exists (sports-a). "
      .. "Choose another favourite or type the channel number in the step."
  )
  eq("...and the live favourite is still there", #e.core.config.sources[1].favorites, 3)
  c, rev = draft()
  sceneOf(c, "game-day").program.steps[3] = { type = "tune", sourceId = "sports-1", channel = "206" }
  e.send("DRAFT_SAVE", { config = c, baseRevision = rev }, CM)
  eq("with the step typing the channel instead, it publishes", publish().ok, true)
  eq("...and the favourite is gone", #e.core.config.sources[1].favorites, 2)
end

T.done()
