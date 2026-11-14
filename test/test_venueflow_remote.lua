-- VenueFlow: Remote Management, the driver side (Core:remote).
--
-- A dealer at smartbuildos.io reaches a venue's CONFIGURATION through the
-- Agent's restricted module commands. The "Remote Management" driver property
-- decides how far: off, draft only, or draft and publish. Covered here: each
-- level's commands, that a remote edit cannot overwrite work done on site,
-- that publish only publishes what was reviewed, that no PIN material leaves
-- the controller, and that nothing remote controls equipment.
--
-- SIMULATION-verified, and the Agent and the platform are NOT in this test:
-- nothing here proves the path from smartbuildos.io to the controller.
--
-- Run from the driver root: make test

local H = require("venueflow_harness")
local Core = require("venueflow.core")
local Envelope = require("sbos.envelope")
local T = H.checker()
local check, eq = T.check, T.eq

local function copy(t)
  return H.JSON:decode(H.JSON:encode(t))
end

local env = H.new()
local installer = env.publishSample("sports_bar")
local I = { session = installer }
local core = env.core

print("off")
eq("off: a snapshot is refused", core:remote("snapshot", {}, nil).errorCode, "VF_FORBIDDEN")
eq("off: a draft is refused", core:remote("save_draft", { config = {} }, nil).errorCode, "VF_FORBIDDEN")
eq("off: a publish is refused", core:remote("publish", {}, nil).errorCode, "VF_FORBIDDEN")
eq("an unknown level is off", core:remote("snapshot", {}, "everything").errorCode, "VF_FORBIDDEN")

print("draft only")
local snap = core:remote("snapshot", {}, "draft")
eq("a snapshot is given", snap.ok, true)
eq("...marked as a VenueFlow configuration", snap.data.kind, "venueflow.config")
eq("...with the draft", type(snap.data.draft.config), "table")
eq("...and what is live", snap.data.published.versionId, "v1")
local text = H.JSON:encode(snap.data)
check("no PIN material leaves the controller", not text:find("pinHash", 1, true) and not text:find("pinSalt", 1, true))
check("...and no passcode", not text:find(env.passcode, 1, true))

local cfg = copy(snap.data.draft.config)
cfg.venue.name = "Riverside (remote)"
cfg.displays[1].name = "TV 01 remote"
eq(
  "a draft without its base revision is refused",
  core:remote("save_draft", { config = cfg }, "draft").errorCode,
  "VF_STALE_DRAFT"
)
local saved = core:remote("save_draft", { config = cfg, baseRevision = snap.data.draft.revision }, "draft")
eq("a remote draft is saved", saved.ok, true)
eq("the installer's scope: any part may change", core.store:draft().config.displays[1].name, "TV 01 remote")
eq("the manager's PIN survives a remote draft", type(core.store:draft().config.profiles[1].pinHash), "string")
eq("nothing is live yet", core.config.venue.name, "Riverside Sports Bar")
eq(
  "draft only: publish is refused",
  core:remote("publish", { baseRevision = saved.data.revision }, "draft").errorCode,
  "VF_FORBIDDEN"
)
eq("draft only: rollback is refused", core:remote("rollback", { versionId = "v1" }, "draft").errorCode, "VF_FORBIDDEN")

print("work done on site wins")
local onsite = env.send("DRAFT_GET", {}, I).data.draft
local c2 = copy(onsite.config)
c2.venue.name = "Riverside (on site)"
eq("the installer on site saves", env.send("DRAFT_SAVE", { config = c2, baseRevision = onsite.revision }, I).ok, true)
local late = core:remote("save_draft", { config = cfg, baseRevision = saved.data.revision }, "draft")
eq("a remote draft made from the older revision is refused", late.errorCode, "VF_STALE_DRAFT")
eq("the on-site work is intact", core.store:draft().config.venue.name, "Riverside (on site)")

print("draft and publish")
local snap2 = core:remote("snapshot", {}, "publish")
local acks = {}
for _, i in ipairs(snap2.data.draft.issues) do
  acks[#acks + 1] = i.id
end
eq(
  "publish needs the revision that was reviewed",
  core:remote("publish", { baseRevision = snap2.data.draft.revision - 1, acknowledged = acks }, "publish").errorCode,
  "VF_STALE_DRAFT"
)
eq(
  "publish still needs the warnings acknowledged",
  core:remote("publish", { baseRevision = snap2.data.draft.revision }, "publish").errorCode,
  "VF_VALIDATION_FAILED"
)
local pub = core:remote(
  "publish",
  { baseRevision = snap2.data.draft.revision, acknowledged = acks, note = "from the platform" },
  "publish"
)
eq("a reviewed draft is published remotely", pub.ok, true)
eq("...and is live", core.config.venue.name, "Riverside (on site)")
eq("...recorded as remote", core.store:published().by, "remote")
local sawRecord = false
for _, r in ipairs(env.records) do
  if r.name == "remote publish" then
    sawRecord = true
  end
end
check("the project's history hears about it", sawRecord)
local back = core:remote("rollback", { versionId = "v1" }, "publish")
eq("a rollback works remotely", back.ok, true)
eq("...and v1's venue is live again", core.config.venue.name, "Riverside Sports Bar")
eq(
  "an unknown version is refused",
  core:remote("rollback", { versionId = "v999" }, "publish").errorCode,
  "VF_NOT_FOUND"
)

print("what remote can never do")
for _, command in ipairs({
  "ROUTE_VIDEO",
  "route_video",
  "AUDIO_VOLUME",
  "SCENE_ACTIVATE",
  "run_scene",
  "ALL_OFF",
  "PROFILE_PIN_SET",
  "set_pin",
  "SIM_FAULT",
  "BACKUP_RESTORE",
  "TEMPLATE_APPLY",
  "SESSIONS_REVOKE",
}) do
  eq(command .. " is not a remote command", core:remote(command, {}, "publish").errorCode, "VF_FORBIDDEN")
end
for _, level in ipairs({ "draft", "publish" }) do
  for _, command in ipairs(Core.REMOTE_COMMANDS[level]) do
    check(
      level .. ": " .. command .. " is a configuration command",
      command == "snapshot"
        or command == "save_draft"
        or command == "publish"
        or command == "rollback"
        or command == "refresh_status"
    )
  end
end
eq("a broken argument does not raise", core:remote("save_draft", "nonsense", "draft").errorCode, "VF_INVALID_PAYLOAD")
eq("a status refresh answers", core:remote("refresh_status", {}, "draft").ok, true)

print("the module contract")
check(
  "VenueFlow owns the venueflow. event prefix",
  Envelope.PREFIXES.venueflow ~= nil and Envelope.PREFIXES.venueflow[1] == "venueflow."
)
local built, why = Envelope.build({
  event_type = "venueflow.config.published",
  evidence_source = "system",
  payload = { versionId = "v2", how = "configuration published" },
}, { module_id = "venueflow", instance_id = "1", observed_at = "2026-11-14T00:00:00Z", sequence = 1 })
check("a published event builds as a valid envelope", type(built) == "table", why)
eq("...and validates as VenueFlow's own", built ~= nil and Envelope.validate(built, "venueflow"), true)

T.done()
