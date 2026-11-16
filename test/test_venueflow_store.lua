-- VenueFlow configuration storage: draft, publish, previous versions,
-- rollback, backup and restore, floor-plan images, schema migration, and what
-- survives a driver restart. The key-value store is an in-memory table that
-- outlives the core (the same way controller persistence outlives a driver
-- restart); a real controller's limits are in the hardware plan.
--
-- Run from the driver root: make test

local H = require("venueflow_harness")
local Schema = require("venueflow.schema")
local T = H.checker()
local check, eq = T.check, T.eq

local kv = H.kv()
local env = H.new({ kv = kv })
local st = env.studio()
local S = { session = st }

-- ── before anything is configured ───────────────────────────────────────────
print("empty driver")
local boot = env.send("STUDIO_BOOTSTRAP", {}, S)
eq("no draft", boot.data.draft, nil)
eq("nothing published", boot.data.published, nil)
eq(
  "operator commands say the venue is not set up",
  env.send("GET_STATE", {}, { tile = true }).errorCode,
  "VF_NO_PUBLISHED_CONFIG"
)
eq("HELLO says so too", env.send("HELLO", {}, { tile = true }).data.published, false)
eq("publishing with no draft", env.send("PUBLISH", {}, S).errorCode, "VF_NOT_FOUND")
check(
  "the schema vocabulary is sent to the Studio",
  #boot.data.schema.venueTypes == 8 and #boot.data.schema.stepTypes == 14
)

-- ── templates never overwrite silently ──────────────────────────────────────
print("templates")
local r = env.send("TEMPLATE_APPLY", { venueType = "restaurant", name = "Chez Test" }, S)
check("first template applied", r.ok)
eq("venue named", r.data.draft.config.venue.name, "Chez Test")
eq("restaurant scenes", #r.data.draft.config.scenes, 5)
eq("revision 1", r.data.draft.revision, 1)
r = env.send("TEMPLATE_APPLY", { venueType = "hotel" }, S)
eq("a second template needs confirmation", r.errorCode, "VF_CONFIRM_REQUIRED")
eq("the draft is untouched", env.send("DRAFT_GET", {}, S).data.draft.config.venue.name, "Chez Test")
eq(
  "unknown type",
  env.send("TEMPLATE_APPLY", { venueType = "casino", confirm = true }, S).errorCode,
  "VF_INVALID_PAYLOAD"
)
eq(
  "samples only in Simulation",
  (function()
    env.mode = "live"
    local out = env.send("TEMPLATE_APPLY", { venueType = "sports_bar", sample = true, confirm = true }, S).errorCode
    env.mode = "simulation"
    return out
  end)(),
  "VF_SIMULATION_ONLY"
)
for _, vt in ipairs(Schema.VENUE_TYPES) do
  local c = H.Templates.venue(vt, "T")
  local errors = 0
  for _, i in ipairs(Schema.validate(c)) do
    if i.severity == "error" then
      errors = errors + 1
    end
  end
  eq("template " .. vt .. " has no errors", errors, 0)
end
eq("eight scene templates", #boot.data.schema.sceneTemplates, 8)
eq("seven profile templates", #boot.data.schema.profileTemplates, 7)

-- ── draft saves ─────────────────────────────────────────────────────────────
print("draft")
local draft = env.send("DRAFT_GET", {}, S).data.draft
local config = draft.config
config.venue.name = "Chez Test II"
r = env.send("DRAFT_SAVE", { config = config, baseRevision = draft.revision }, S)
check("saved", r.ok)
eq("revision advanced", r.data.revision, 2)
r = env.send("DRAFT_SAVE", { config = config, baseRevision = 1 }, S)
eq("a save from an old revision is refused", r.errorCode, "VF_STALE_DRAFT")
eq("...and changed nothing", env.send("DRAFT_GET", {}, S).data.draft.revision, 2)
config.schema = 99
eq(
  "a newer schema is refused, not guessed at",
  env.send("DRAFT_SAVE", { config = config, baseRevision = 2 }, S).errorCode,
  "VF_VALIDATION_FAILED"
)
config.schema = 1

-- validation comes back with the save
config.displays[1] = { id = "tv-a", name = "TV A", floorId = "main-floor", areaId = "dining" }
config.displays[2] = { id = "tv-a", name = "Twin", floorId = "nowhere" }
r = env.send("DRAFT_SAVE", { config = config, baseRevision = 2 }, S)
check("a draft with problems still saves (it is a draft)", r.ok)
local codes = {}
for _, i in ipairs(r.data.issues) do
  codes[i.code] = i.severity
end
eq("duplicate id is an error", codes.ID_DUPLICATE, "error")
eq("unmapped display is a warning", codes.DISPLAY_UNMAPPED, "warning")
r = env.send("PUBLISH", {}, S)
eq("errors block publishing", r.errorCode, "VF_VALIDATION_FAILED")
check("the blocking issues are listed", #r.data.blocking >= 1)
eq("still nothing published", env.core.config, nil)

-- ── publish needs every warning acknowledged ────────────────────────────────
print("publish")
env.send("TEMPLATE_APPLY", { venueType = "sports_bar", sample = true, confirm = true }, S)
draft = env.send("DRAFT_GET", {}, S).data.draft
eq("the sample has one warning", draft.summary.warnings, 1)
eq("...and no error", draft.summary.errors, 0)
r = env.send("PUBLISH", {}, S)
eq("an unacknowledged warning blocks", r.errorCode, "VF_VALIDATION_FAILED")
r = env.send("PUBLISH", { acknowledged = { "SOMETHING:else" } }, S)
eq("acknowledging the wrong thing does not help", r.errorCode, "VF_VALIDATION_FAILED")
r = env.send("PUBLISH", { acknowledged = { draft.issues[1].id }, note = "first" }, S)
check("published once acknowledged", r.ok)
eq("version v1", r.data.versionId, "v1")
eq("the venue now runs it", #env.core.config.displays, 24)
check("Composer event fired", table.concat(env.events, ","):find("published", 1, true) ~= nil)
env.settle(1000)

-- a draft edit does not touch what is running
draft = env.send("DRAFT_GET", {}, S).data.draft
config = draft.config
config.displays[1].name = "Renamed TV"
table.remove(config.displays, 24)
config.groups[4].displayIds = { "tv-21", "tv-22", "tv-23" }
r = env.send("DRAFT_SAVE", { config = config, baseRevision = draft.revision }, S)
check("draft changed", r.ok)
eq("the running venue still has 24 displays", #env.core.config.displays, 24)
eq("the running venue keeps the old name", env.core.config.displays[1].name, "TV 01")
r = env.send("PUBLISH", { acknowledged = {}, note = "second" }, S)
check("second publish", r.ok)
eq("version v2", r.data.versionId, "v2")
eq("history holds v1", r.data.history[1].versionId, "v1")
eq("the venue now has 23 displays", #env.core.config.displays, 23)
eq("ids are stable across a rename", env.core.config.displays[1].id, "tv-01")
env.settle(1000)

-- ── rollback ────────────────────────────────────────────────────────────────
print("rollback")
eq("rollback needs confirmation", env.send("ROLLBACK", { versionId = "v1" }, S).errorCode, "VF_CONFIRM_REQUIRED")
eq("unknown version", env.send("ROLLBACK", { versionId = "v9", confirm = true }, S).errorCode, "VF_NOT_FOUND")
r = env.send("ROLLBACK", { versionId = "v1", confirm = true }, S)
check("rolled back", r.ok)
eq("as a new version", r.data.versionId, "v3")
eq("24 displays again", #env.core.config.displays, 24)
eq("the old name again", env.core.config.displays[1].name, "TV 01")
eq("the version rolled away from is kept", r.data.history[1].versionId, "v2")
r = env.send("ROLLBACK", { versionId = "v2", confirm = true }, S)
check("a rollback can itself be rolled back", r.ok and #env.core.config.displays == 23)
env.settle(1000)

-- history is bounded
for _ = 1, 7 do
  check("publish", env.send("PUBLISH", { acknowledged = {} }, S).ok)
end
eq("at most five previous versions are kept", #env.send("VERSIONS", {}, S).data.history, 5)

-- discard returns the draft to what is published
draft = env.send("DRAFT_GET", {}, S).data.draft
draft.config.venue.name = "Scratch"
env.send("DRAFT_SAVE", { config = draft.config, baseRevision = draft.revision }, S)
eq("discard needs confirmation", env.send("DRAFT_DISCARD", {}, S).errorCode, "VF_CONFIRM_REQUIRED")
r = env.send("DRAFT_DISCARD", { confirm = true }, S)
eq("discard resets the draft to the published venue", r.data.draft.config.venue.name, "Riverside Sports Bar")

-- ── floor-plan images ───────────────────────────────────────────────────────
print("floor plan images")
local png = "data:image/png;base64," .. string.rep("iVBORw0KGgo", 200)
r = env.send("IMAGE_PUT", { dataUrl = png }, S)
check("image stored", r.ok)
local key = r.data.key
eq("the same picture gets the same key", env.send("IMAGE_PUT", { dataUrl = png }, S).data.key, key)
eq(
  "not a picture",
  env.send("IMAGE_PUT", { dataUrl = "data:text/html;base64,PHNjcmlwdD4=" }, S).errorCode,
  "VF_INVALID_PAYLOAD"
)
eq(
  "an SVG is refused (it can carry script)",
  env.send("IMAGE_PUT", { dataUrl = "data:image/svg+xml;base64,PHN2Zz4=" }, S).errorCode,
  "VF_INVALID_PAYLOAD"
)
eq(
  "too large",
  env.send("IMAGE_PUT", { dataUrl = "data:image/png;base64," .. string.rep("A", 700 * 1024) }, S).errorCode,
  "VF_TOO_LARGE"
)
draft = env.send("DRAFT_GET", {}, S).data.draft
draft.config.floors[1].image = { key = key, width = 1600, height = 1000 }
check(
  "floor refers to the image",
  env.send("DRAFT_SAVE", { config = draft.config, baseRevision = draft.revision }, S).ok
)
check("published with the image", env.send("PUBLISH", { acknowledged = {} }, S).ok)
eq(
  "an operator who sees the floor gets its picture",
  env.send("IMAGE_GET", { key = key }, { tile = true }).data.dataUrl,
  png
)
eq("an unknown key", env.send("IMAGE_GET", { key = "img_nope" }, { tile = true }).errorCode, "VF_NOT_FOUND")
eq("no identity, no picture", env.send("IMAGE_GET", { key = key }, {}).errorCode, "VF_UNAUTHENTICATED")
eq(
  "a draft saved with a malformed image reference is flagged",
  (function()
    local c = H.Templates.sportsBar()
    c.floors[1].image = "javascript:alert(1)"
    for _, i in ipairs(Schema.validate(c)) do
      if i.code == "IMAGE_INVALID" then
        return i.severity
      end
    end
  end)(),
  "error"
)

-- ── backup and restore ──────────────────────────────────────────────────────
print("backup and restore")
local backup = env.send("BACKUP_EXPORT", {}, S).data.backup
eq("backup format", backup.format, "venueflow-backup")
eq("the backup carries the published venue", #backup.published.config.displays, 23)
eq("...and the picture it refers to", backup.images[key], png)
local text = H.JSON:encode(backup)
check("the Installer Passcode is never in a backup", not text:find(env.passcode, 1, true))
check("no session token is in a backup", not text:find(st, 1, true))
check(
  "PINs are hashed in a backup, never plain",
  not text:find('"2580"', 1, true) and text:find("pinHash", 1, true) ~= nil
)

-- restore on ANOTHER driver (a replacement controller)
local env2 = H.new()
local st2 = env2.studio()
local S2 = { session = st2 }
local roundTrip = H.JSON:decode(text) -- exactly what a downloaded file holds
r = env2.send("BACKUP_RESTORE", { backup = roundTrip }, S2)
check("restored", r.ok)
eq("into the draft", #r.data.draft.config.displays, 23)
eq("nothing is published by a restore", env2.core.config, nil)
eq("the picture came along", env2.send("IMAGE_GET", { key = key }, S2).data.dataUrl, png)
check(
  "the restored draft equals the backed-up venue",
  (function()
    local a = env2.core.store:draft().config
    local b = Schema.normalize(backup.published.config)
    return require("venueflow.util").equal(a, b)
  end)()
)
r = env2.send("PUBLISH", { acknowledged = {} }, S2)
check("the restored draft publishes", r.ok)
check("staff PINs survive a restore", env2.login("manager", "2580") ~= nil)
eq(
  "a second restore needs confirmation",
  env2.send("BACKUP_RESTORE", { backup = roundTrip }, S2).errorCode,
  "VF_CONFIRM_REQUIRED"
)
eq(
  "not a backup",
  env2.send("BACKUP_RESTORE", { backup = { hello = "world" }, confirm = true }, S2).errorCode,
  "VF_VALIDATION_FAILED"
)
eq(
  "a backup from a newer schema",
  (function()
    local b = H.JSON:decode(text)
    b.published.config.schema = 7
    return env2.send("BACKUP_RESTORE", { backup = b, confirm = true }, S2).errorCode
  end)(),
  "VF_VALIDATION_FAILED"
)

-- The Studio's way: pictures uploaded one by one first (never inside JSON),
-- then the backup without them.
local env3 = H.new()
local st3x = env3.studio()
local S3 = { session = st3x }
local uploaded = env3.core:upload(st3x, png, { client = "10.0.0.50" })
eq("the picture uploaded ahead of the restore keeps its key", uploaded.data.key, key)
local stripped = H.JSON:decode(text)
stripped.images = {}
r = env3.send("BACKUP_RESTORE", { backup = stripped }, S3)
check("a backup restored without its pictures inline", r.ok)
eq("...keeps the floor's picture, because it is already stored", r.data.draft.config.floors[1].image.key, key)
local env4 = H.new()
r = env4.send("BACKUP_RESTORE", { backup = stripped }, { session = env4.studio() })
eq(
  "with no picture stored and none sent, the floor is kept and its picture dropped",
  r.data.draft.config.floors[1].image,
  nil
)
eq("...and the floor itself survives", r.data.draft.config.floors[1].id, "main-floor")

-- ── migration ───────────────────────────────────────────────────────────────
print("schema migration")
local old = { schema = 0, venue = { name = "Old" }, tvs = { { id = "a", name = "A" } } }
local migrated, why = Schema.migrate(old, {
  [0] = function(c)
    c.displays = c.tvs
    c.tvs = nil
    return c
  end,
}, 1)
check("an older document is migrated", migrated ~= nil, why)
eq("to the current version", migrated.schema, 1)
eq("by its migration step", migrated.displays[1].id, "a")
eq("the input is not modified", old.tvs[1].id, "a")
eq("no migration available", select(2, Schema.migrate({ schema = 0 }, {}, 1)), "no migration from schema 0")
check("a failing migration is reported", select(
  2,
  Schema.migrate({ schema = 0 }, {
    [0] = function()
      error("boom")
    end,
  }, 1)
):find("failed", 1, true) ~= nil)
check("a document newer than the driver is refused", Schema.migrate({ schema = 2 }) == nil)

-- ── restart ─────────────────────────────────────────────────────────────────
print("driver restart")
local m = env.login("manager", "2580")
env.send("VENUE_STATUS", { status = "open" }, { session = m })
env.send("SCENE_ACTIVATE", { sceneId = "game-day" }, { session = m })
env.settle(9000)
local rooms = env.sim().rooms -- "Control4" keeps its state while the driver restarts
env.core:stop()

local again = H.new({ kv = kv, clock = env.clock })
-- The simulator is rebuilt on load; carry the rooms over as the project would.
for id, room in pairs(rooms) do
  again.sim().rooms[id] = room
end
again.core:refreshAll()
eq("the published venue is back", #again.core.config.displays, 23)
eq("the version is back", again.core.publishedMeta.versionId, env.core.publishedMeta.versionId)
eq("the draft is back", again.core.store:draft().revision, env.core.store:draft().revision)
eq("history is back", #again.core.store:history(), 5)
eq("venue status is back", again.core.runtime.venueStatus, "open")
eq("the active scene is back", again.core.runtime.activeScene.name, "Game Day")
eq("internal variables are back", again.core.runtime.variables["big-game-on"], true)
check("last successful runs are back", again.core.runtime.lastSuccess["scene:game-day"] ~= nil)
eq(
  "device state is re-read from Control4, not remembered",
  again.cell("display", "tv-01", "source").value .. "/" .. again.cell("display", "tv-01", "source").status,
  "sports-1/confirmed"
)
eq("sessions do not survive a restart", again.send("GET_STATE", {}, { session = m }).errorCode, "VF_UNAUTHENTICATED")
check("staff sign in again with the same PIN", again.login("manager", "2580") ~= nil)
eq("the floor picture is back", again.send("IMAGE_GET", { key = key }, { tile = true }).data.dataUrl, png)
eq("the simulator did not replay any command on restart", again.sim():callCount(), 0)

-- unreferenced pictures are collected at publish
local st3 = again.studio()
draft = again.send("DRAFT_GET", {}, { session = st3 }).data.draft
draft.config.floors[1].image = nil
again.send("DRAFT_SAVE", { config = draft.config, baseRevision = draft.revision }, { session = st3 })
for _ = 1, 7 do
  again.send("PUBLISH", { acknowledged = {} }, { session = st3 })
end
eq("a picture no version refers to is deleted", again.core.store:getImage(key), nil)

T.done()
