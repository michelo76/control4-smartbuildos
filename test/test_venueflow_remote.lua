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
local function count(list, wanted)
  local n = 0
  for _, v in ipairs(list) do
    if v == wanted then
      n = n + 1
    end
  end
  return n
end
local publishedBefore = count(env.events, "published")
local back = core:remote("rollback", { versionId = "v1" }, "publish")
eq("a rollback works remotely", back.ok, true)
eq("...and v1's venue is live again", core.config.venue.name, "Riverside Sports Bar")
check("...as a new live version", back.data.versionId ~= "v1", back.data.versionId)
eq("...Configuration Published fires for a rollback", count(env.events, "published"), publishedBefore + 1)
do
  local rolled
  for _, r in ipairs(env.records) do
    if r.name == "configuration rolled back" then
      rolled = r
    end
  end
  -- The driver forwards this detail as the versionId of venueflow.config.published.
  eq("...and its record names the NEW live version, not the target", rolled and rolled.detail, back.data.versionId)
end
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

print("how a snapshot travels")
-- Two redactors stand between the driver and the platform's storage. A
-- configuration must survive both untouched, so it goes as base64 groups.
local U = require("venueflow.util")
eq(
  "base64 of the usual vectors",
  U.base64("f") .. " " .. U.base64("fo") .. " " .. U.base64("foo") .. " " .. U.base64("foobar"),
  "Zg Zm8 Zm9v Zm9vYmFy"
)
eq("...and back", U.unbase64("Zm9vYmFy") .. U.unbase64("Zm8"), "foobarfo")
local every = {}
for b = 0, 255 do
  every[#every + 1] = string.char(b)
end
every = table.concat(every)
eq("every byte value survives the round trip", U.unbase64(U.base64(every)), every)

local live = core:remote("snapshot", {}, "publish")
local function encodeJson(t)
  return H.JSON:encode(t)
end
local document, why = Core.snapshotDocument(live.data, encodeJson)
check("a snapshot becomes a document", document ~= nil, why)
eq("...marked as a VenueFlow configuration", document.kind, "venueflow.config")
eq("...in the base64-groups form", document.encoding .. "/" .. document.format, "base64-groups/2")
check("...in several parts", #document.parts >= 2)
local clean = true
for _, part in ipairs(document.parts) do
  if #part > Core.SNAPSHOT_PART_BYTES or part:find("[^%w%+/,]") then
    clean = false
  end
  for group in part:gmatch("[^,]+") do
    if #group > Core.SNAPSHOT_GROUP then
      clean = false
    end
  end
end
check("every part is short groups of base64 and commas, nothing else", clean)
local redacted = Envelope.redact(document)
eq("the Agent's redaction leaves every part alone", H.JSON:encode(redacted.parts), H.JSON:encode(document.parts))
local rebuilt = H.JSON:decode(U.unbase64(table.concat(redacted.parts)))
eq(
  "the parts decode back into the same snapshot",
  H.JSON:encode(rebuilt),
  H.JSON:encode(H.JSON:decode(H.JSON:encode(live.data)))
)
eq("...deep scene steps included", type(rebuilt.draft.config.scenes[1].program.steps[1].type), "string")
eq("...and an issue keeps its code", type(rebuilt.draft.issues[1].code), "string")
local naive = Envelope.redact(H.JSON:decode(H.JSON:encode(live.data)))
check("(sent as a plain object it would not have survived)", H.JSON:encode(naive):find("[redacted]", 1, true) ~= nil)
eq("the bytes are the JSON's", document.bytes, #H.JSON:encode(live.data))
check(
  "while the draft differs, the live configuration is sent too",
  live.data.published.sameAsDraft == nil and type(live.data.published.config) == "table"
)
eq("the installer discards the draft", env.send("DRAFT_DISCARD", { confirm = true }, I).ok, true)
local same = core:remote("snapshot", {}, "draft")
check(
  "once the draft is the live configuration, it is sent once",
  same.data.published.sameAsDraft == true and same.data.published.config == nil
)
local tooBig, bigWhy = Core.snapshotDocument({ blob = string.rep("x", Core.SNAPSHOT_MAX_BYTES + 10) }, encodeJson)
check("an oversized configuration is refused, with a reason", tooBig == nil and type(bigWhy) == "string")
local largest = Core.snapshotDocument({ blob = string.rep("x", Core.SNAPSHOT_MAX_BYTES - 20) }, encodeJson)
check("the largest allowed one fits the Agent's 256 kB", largest ~= nil and #H.JSON:encode(largest) < 256 * 1024)

print("a draft arriving as parts")
local snapP = core:remote("snapshot", {}, "draft")
local cfgP = copy(snapP.data.draft.config)
cfgP.venue.name = "Riverside (parts)"
local textP = H.JSON:encode(cfgP)
local partsP = {}
for i = 1, #textP, 3000 do
  partsP[#partsP + 1] = textP:sub(i, i + 2999)
end
local savedP = core:remote("save_draft", { configParts = partsP, baseRevision = snapP.data.draft.revision }, "draft")
eq("a configuration sent as JSON text in parts is saved", savedP.ok, true)
eq("...and is the draft", core.store:draft().config.venue.name, "Riverside (parts)")
eq(
  "parts that are not JSON are refused",
  core:remote("save_draft", { configParts = { "{not json" }, baseRevision = savedP.data.revision }, "draft").errorCode,
  "VF_INVALID_PAYLOAD"
)
eq(
  "parts that are not text are refused",
  core:remote("save_draft", { configParts = { { a = 1 } }, baseRevision = savedP.data.revision }, "draft").errorCode,
  "VF_INVALID_PAYLOAD"
)

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

-- ── Device mapping and device commands are on-site only ─────────────────────
-- Owner decision: a remote draft may change names, scenes, rules, schedules,
-- layout, presets and the rest, but never which Control4 room or device
-- anything is mapped to, nor which Control4 command anything sends
-- (src/venueflow/remotescope.lua). Refused whole, nothing stored.
print("on-site only: device mapping and device commands")
local RemoteScope = require("venueflow.remotescope")
local E = H.new()
local EI = { session = E.publishSample("sports_bar") }
local ecore = E.core

local function find(list, id)
  for _, x in ipairs(list or {}) do
    if x.id == id then
      return x
    end
  end
  return nil
end
local function acksOf(draft)
  local out = {}
  for _, i in ipairs(draft.issues or {}) do
    out[#out + 1] = i.id
  end
  return out
end
local function installerSave(mutate)
  local d = E.send("DRAFT_GET", {}, EI).data.draft
  local c = copy(d.config)
  mutate(c)
  return E.send("DRAFT_SAVE", { config = c, baseRevision = d.revision }, EI)
end
local function installerPublish()
  local d = E.send("DRAFT_GET", {}, EI).data.draft
  return E.send("PUBLISH", { acknowledged = acksOf(d) }, EI)
end

-- On site, the installer gives the venue one of each mapping kind the sample
-- lacks: a shade, a rule on a Control4 variable (trigger and condition), and
-- a scene step that reads a Control4 variable.
check(
  "the installer adds a shade and Control4 variable rules on site",
  installerSave(function(c)
    c.venue.subsystems.shades = true
    c.shades = {
      { id = "patio-blind", name = "Patio Blind", areaId = "patio", deviceId = 5101, openLevel = 100, closedLevel = 0 },
    }
    c.rules[#c.rules + 1] = {
      id = "door-motion",
      name = "Door motion",
      enabled = true,
      trigger = { type = "c4_variable", deviceId = 5201, variable = "MOTION" },
      condition = { op = "c4_variable", deviceId = 5202, variable = "LUX", cmp = "lt", value = 40 },
      program = { steps = { { type = "set_venue_status", status = "open" } } },
    }
    local closing = find(c.scenes, "closing")
    closing.program.steps[#closing.program.steps + 1] = {
      type = "if",
      condition = { op = "c4_variable", deviceId = 5203, variable = "OCCUPIED", cmp = "eq", value = false },
      ["then"] = { { type = "notify", message = "The venue is empty" } },
    }
  end).ok
)
check("...and publishes it", installerPublish().ok)

--- A remote save of the current draft after `mutate`.
local function remoteSave(mutate, level)
  local snap = ecore:remote("snapshot", {}, "publish")
  local cfg = copy(snap.data.draft.config)
  mutate(cfg)
  local before = ecore.store:draft()
  local r = ecore:remote("save_draft", { config = cfg, baseRevision = snap.data.draft.revision }, level or "draft")
  return r, before, ecore.store:draft()
end
local function display(c, id)
  return find(c.displays, id)
end
local function preset(c)
  return find(find(c.lighting, "house-lights").presets, "game-day")
end

-- One case per mapping or command field: a remote save changing only that.
local MAPPING = {
  {
    "a display's room",
    "Display 'TV 03' room",
    function(c)
      display(c, "tv-03").c4RoomId = 1999
    end,
  },
  {
    "a display's device",
    "Display 'TV 03' device",
    function(c)
      display(c, "tv-03").c4DeviceId = 2999
    end,
  },
  {
    "a display's power control",
    "Display 'TV 03' power control",
    function(c)
      display(c, "tv-03").power = "device"
    end,
  },
  {
    "a display's feedback",
    "Display 'TV 03' feedback",
    function(c)
      display(c, "tv-03").feedback = "none"
    end,
  },
  {
    "a display's route type",
    "Display 'TV 03' route type",
    function(c)
      display(c, "tv-03").route = { strategy = "none" }
    end,
  },
  {
    "a custom route's device",
    "Display 'Lounge Projector' route command",
    function(c)
      display(c, "tv-24").route.command.deviceId = 2901
    end,
  },
  {
    "a custom route's command",
    "Display 'Lounge Projector' route command",
    function(c)
      display(c, "tv-24").route.command.name = "SET_OUTPUT"
    end,
  },
  {
    "a custom route's parameter",
    "Display 'Lounge Projector' route command",
    function(c)
      display(c, "tv-24").route.command.params.OUTPUT = 99
    end,
  },
  {
    "a custom route's new parameter",
    "Display 'Lounge Projector' route command",
    function(c)
      display(c, "tv-24").route.command.params.EXTRA = "1"
    end,
  },
  {
    "a source's device",
    "Source 'Sports 1' device",
    function(c)
      find(c.sources, "sports-1").c4DeviceId = 3999
    end,
  },
  {
    "an audio zone's room",
    "Audio zone 'Bar' room",
    function(c)
      find(c.audioZones, "zone-bar").c4RoomId = 1299
    end,
  },
  {
    "an audio zone's feedback",
    "Audio zone 'Bar' feedback",
    function(c)
      find(c.audioZones, "zone-bar").feedback = "none"
    end,
  },
  {
    "a lighting preset's device",
    "Lighting preset 'Game Day' device",
    function(c)
      preset(c).deviceId = 4002
    end,
  },
  {
    "a lighting preset's command",
    "Lighting preset 'Game Day' command",
    function(c)
      preset(c).command = "SET_LEVEL"
    end,
  },
  {
    "a lighting preset's parameters",
    "Lighting preset 'Game Day' command parameters",
    function(c)
      preset(c).params.SCENE_ID = 99
    end,
  },
  {
    "a shade's device",
    "Shade 'Patio Blind' device",
    function(c)
      find(c.shades, "patio-blind").deviceId = 5199
    end,
  },
  {
    "the device a rule listens to",
    "Rule 'Door motion' Control4 variable",
    function(c)
      find(c.rules, "door-motion").trigger.deviceId = 5299
    end,
  },
  {
    "the variable a rule listens to",
    "Rule 'Door motion' Control4 variable",
    function(c)
      find(c.rules, "door-motion").trigger.variable = "DOOR"
    end,
  },
  {
    "the device a rule condition reads",
    "Rule 'Door motion' Control4 variable",
    function(c)
      find(c.rules, "door-motion").condition.deviceId = 5298
    end,
  },
  {
    "the device a scene step's condition reads",
    "Scene 'Closing' Control4 variable",
    function(c)
      local steps = find(c.scenes, "closing").program.steps
      steps[#steps].condition.deviceId = 5297
    end,
  },
  {
    "a new Control4 variable read in a scene",
    "Scene 'Opening' Control4 variable",
    function(c)
      local steps = find(c.scenes, "opening").program.steps
      steps[#steps + 1] = {
        type = "if",
        condition = { op = "c4_variable", deviceId = 5296, variable = "ARMED", cmp = "eq", value = true },
        ["then"] = { { type = "notify", message = "Armed" } },
      }
    end,
  },
}
for _, case in ipairs(MAPPING) do
  local r, before, after = remoteSave(case[3])
  eq("remote: " .. case[1] .. " is refused", r.errorCode, "VF_ONSITE_ONLY")
  check("...naming it", tostring(r.detail):find(case[2], 1, true) ~= nil, r.detail)
  check("...saying to change it on site", tostring(r.detail):find("on site in Installer Studio", 1, true) ~= nil)
  eq("...nothing is stored (same revision)", after.revision, before.revision)
  check("...and the draft is untouched", U.equal(after.config, before.config))
end

-- The installer on site can still change every one of those fields.
for _, case in ipairs(MAPPING) do
  local before = ecore.store:draft()
  local r = installerSave(case[3])
  check(
    "on site: " .. case[1] .. " may change",
    r.ok and not U.equal(ecore.store:draft().config, before.config),
    r.detail
  )
  -- Back to where it was, so each case changes one field.
  local d = E.send("DRAFT_GET", {}, EI).data.draft
  E.send("DRAFT_SAVE", { config = copy(before.config), baseRevision = d.revision }, EI)
end
check(
  "(the draft is back to the published mapping)",
  #RemoteScope.changes(ecore.store:published().config, ecore.store:draft().config) == 0
)

-- What a dealer does day to day still goes through.
local ORDINARY = {
  {
    "renaming a display",
    function(c)
      display(c, "tv-03").name = "TV 03 (bar end)"
    end,
  },
  {
    "moving a display on the floor plan",
    function(c)
      display(c, "tv-03").layout.x = display(c, "tv-03").layout.x + 20
    end,
  },
  {
    "changing a schedule",
    function(c)
      find(c.rules, "open-weekdays").trigger.time = "10:30"
    end,
  },
  {
    "changing a scene",
    function(c)
      local s = find(c.scenes, "opening")
      s.name = "Opening (late)"
      s.program.steps[5].level = 50
    end,
  },
  {
    "adding a favourite channel",
    function(c)
      local favorites = find(c.sources, "sports-1").favorites
      favorites[#favorites + 1] = { id = "fox", name = "Fox", channel = "250" }
    end,
  },
  {
    "changing a channel label",
    function(c)
      find(c.sources, "sports-2").channel = "ESPN 206"
    end,
  },
  {
    "changing a volume preset",
    function(c)
      find(c.audioZones, "zone-bar").presets[1].level = 30
    end,
  },
  {
    "changing a zone's volume limits",
    function(c)
      find(c.audioZones, "zone-bar").maxVolume = 80
    end,
  },
  {
    "switching a source's control groups and Enter",
    function(c)
      local s = find(c.sources, "sports-3")
      s.controls = { "channel", "keypad", "navigation" }
      s.tuneEnter = false
    end,
  },
  {
    "changing a source's kind",
    function(c)
      find(c.sources, "sports-4").kind = "satellite"
    end,
  },
  {
    "changing a shade's levels",
    function(c)
      find(c.shades, "patio-blind").openLevel = 80
    end,
  },
  {
    "changing a Control4 condition's threshold",
    function(c)
      find(c.rules, "door-motion").condition.value = 30
    end,
  },
  {
    "reading a Control4 variable the configuration already reads",
    function(c)
      find(c.scenes, "happy-hour").condition =
        { op = "c4_variable", deviceId = 5202, variable = "LUX", cmp = "gt", value = 10 }
    end,
  },
  {
    "renaming a lighting preset",
    function(c)
      preset(c).name = "Game Night"
    end,
  },
  {
    "reordering displays, sources, zones and presets",
    function(c)
      for _, field in ipairs({ "displays", "sources", "audioZones" }) do
        local list, rev = c[field], {}
        for i = #list, 1, -1 do
          rev[#rev + 1] = list[i]
        end
        c[field] = rev
      end
      local presets = find(c.lighting, "house-lights").presets
      presets[1], presets[3] = presets[3], presets[1]
    end,
  },
  {
    "leaving out fields that hold their defaults",
    function(c)
      local d = display(c, "tv-01")
      d.power, d.feedback, d.route = nil, nil, nil
      find(c.audioZones, "zone-dining").feedback = nil
    end,
  },
  {
    "adding an unmapped display",
    function(c)
      c.displays[#c.displays + 1] = { id = "tv-99", name = "TV 99", kind = "tv", floorId = "main-floor" }
    end,
  },
  {
    "adding an unmapped source",
    function(c)
      c.sources[#c.sources + 1] = { id = "laptop", name = "Laptop", kind = "laptop" }
    end,
  },
  {
    "adding an unmapped lighting preset",
    function(c)
      local presets = find(c.lighting, "house-lights").presets
      presets[#presets + 1] = { id = "late", name = "Late" }
    end,
  },
  {
    "adding an unmapped shade",
    function(c)
      c.shades[#c.shades + 1] = { id = "bar-blind", name = "Bar Blind", areaId = "bar" }
    end,
  },
  {
    "removing a mapped display",
    function(c)
      for i, d in ipairs(c.displays) do
        if d.id == "tv-23" then
          table.remove(c.displays, i)
          break
        end
      end
    end,
  },
}
for _, case in ipairs(ORDINARY) do
  local r, before, after = remoteSave(case[2])
  eq("remote: " .. case[1] .. " is accepted", r.ok, true)
  if not r.ok then
    print("    " .. tostring(r.errorCode) .. ": " .. tostring(r.detail))
  end
  eq("...as a new revision", after.revision, before.revision + 1)
end
eq("(the installer discards those edits)", E.send("DRAFT_DISCARD", { confirm = true }, EI).ok, true)

-- Adding and removing cannot carry a mapping in.
local function removeDisplay(c, id)
  for i, d in ipairs(c.displays) do
    if d.id == id then
      return table.remove(c.displays, i)
    end
  end
end
local SHAPES = {
  {
    "a new display that is mapped",
    "Display 'TV 99' (new) room",
    function(c)
      c.displays[#c.displays + 1] = { id = "tv-99", name = "TV 99", floorId = "main-floor", c4RoomId = 1199 }
    end,
  },
  {
    "a new display with a custom route command",
    "Display 'TV 99' (new) route command",
    function(c)
      c.displays[#c.displays + 1] = {
        id = "tv-99",
        name = "TV 99",
        floorId = "main-floor",
        route = { strategy = "command", command = { deviceId = 2950, name = "SET_INPUT" } },
      }
    end,
  },
  {
    "a new display with a power strategy chosen",
    "Display 'TV 99' (new) power control",
    function(c)
      c.displays[#c.displays + 1] = { id = "tv-99", name = "TV 99", floorId = "main-floor", power = "device" }
    end,
  },
  {
    "a new source that is mapped",
    "Source 'Laptop' (new) device",
    function(c)
      c.sources[#c.sources + 1] = { id = "laptop", name = "Laptop", kind = "laptop", c4DeviceId = 3100 }
    end,
  },
  {
    "a new lighting preset that is mapped",
    "Lighting preset 'Late' (new) command",
    function(c)
      local presets = find(c.lighting, "house-lights").presets
      presets[#presets + 1] = { id = "late", name = "Late", deviceId = 4001, command = "ACTIVATE_SCENE" }
    end,
  },
  {
    "a new shade that is mapped",
    "Shade 'Bar Blind' (new) device",
    function(c)
      c.shades[#c.shades + 1] = { id = "bar-blind", name = "Bar Blind", deviceId = 5102 }
    end,
  },
  {
    "a display removed and added back with another room",
    "Display 'TV 03' room",
    function(c)
      local d = removeDisplay(c, "tv-03")
      d.c4RoomId = 1999
      c.displays[#c.displays + 1] = d
    end,
  },
  {
    "a removed display's mapping under a new id",
    "Display 'TV 03' (new) room",
    function(c)
      local d = removeDisplay(c, "tv-03")
      d.id = "tv-03b"
      c.displays[#c.displays + 1] = d
    end,
  },
  {
    "a lighting preset moved to another lighting control",
    "Lighting preset 'Game Day' (new) device",
    function(c)
      c.lighting[#c.lighting + 1] = { id = "bar-lights", name = "Bar Lights", presets = { copy(preset(c)) } }
    end,
  },
  {
    "a mapped display behind a hole in the list",
    "Display 'TV 98' (new) room",
    function(c)
      c.displays[#c.displays + 2] = { id = "tv-98", name = "TV 98", floorId = "main-floor", c4RoomId = 1198 }
    end,
  },
}
for _, case in ipairs(SHAPES) do
  local r, before, after = remoteSave(case[3])
  eq("remote: " .. case[1] .. " is refused", r.errorCode, "VF_ONSITE_ONLY")
  check("...naming it", tostring(r.detail):find(case[2], 1, true) ~= nil, r.detail)
  eq("...nothing is stored", after.revision, before.revision)
end

-- The refusal: bounded, readable, logged; the snapshot still shows the mapping.
do
  local r = remoteSave(function(c)
    for _, d in ipairs(c.displays) do
      d.c4RoomId = (d.c4RoomId or 0) + 500
    end
    display(c, "tv-02").name = string.rep("\195\169", 30) -- "é" x 30, 60 bytes
  end)
  eq("many changes: still one refusal", r.errorCode, "VF_ONSITE_ONLY")
  local detail = tostring(r.detail)
  local wire = "VF_ONSITE_ONLY: " .. detail
  check("...within the Agent's 400 characters, code included", #wire <= 400, #wire)
  check(
    "...whole (it ends with what to do)",
    detail:sub(-#". Change these on site in Installer Studio.") == ". Change these on site in Installer Studio.",
    detail
  )
  check("...the rest counted", detail:find("%d+ more%.") ~= nil, detail)
  check(
    "...a long name is cut between characters",
    detail:find(string.rep("\195\169", 14) .. "...'", 1, true) ~= nil
      and detail:find(string.rep("\195\169", 15), 1, true) == nil,
    detail
  )
  check(
    "...the detail starts as the dealer reads it",
    detail:find("^Remote Management cannot change device mapping or device commands: Display 'TV 01' room") ~= nil,
    detail
  )
  local entry = ecore.diag:list({ limit = 1 })[1]
  eq("diagnostics record the refusal", entry and entry.code, "VF_ONSITE_ONLY")
  check(
    "...with what was on-site only",
    entry
      and entry.data
      and type(entry.data.onSiteOnly) == "table"
      and tostring(entry.data.onSiteOnly[1]):find("TV 01", 1, true) ~= nil
  )
  local snapM = ecore:remote("snapshot", {}, "draft")
  local tv24 = display(snapM.data.draft.config, "tv-24")
  check(
    "the snapshot still shows the mapping to the dealer",
    (display(snapM.data.draft.config, "tv-03") or {}).c4RoomId == 1103
      and tv24 ~= nil
      and tv24.route.command.name == "SET_INPUT"
  )
end

-- A stale base is answered as stale, not as on-site only.
do
  local snap = ecore:remote("snapshot", {}, "draft")
  local cfg = copy(snap.data.draft.config)
  display(cfg, "tv-03").c4RoomId = 1999
  eq(
    "a mapping change from an old revision is answered as stale",
    ecore:remote("save_draft", { config = cfg, baseRevision = snap.data.draft.revision - 1 }, "draft").errorCode,
    "VF_STALE_DRAFT"
  )
end

-- With the installer's unpublished mapping work in the draft.
print("on-site only: the installer's work in the draft")
check(
  "on site, the installer remaps TV 05 in the draft (not published)",
  installerSave(function(c)
    display(c, "tv-05").c4RoomId = 1305
  end).ok
)
do
  local r, before, after = remoteSave(function(c)
    display(c, "tv-01").name = "TV 01 (remote)"
  end)
  eq("remote: other fields may be saved on top of it", r.ok, true)
  eq("...as a new revision", after.revision, before.revision + 1)
  eq("...and the installer's mapping is kept", display(after.config, "tv-05").c4RoomId, 1305)
  r, before, after = remoteSave(function(c)
    display(c, "tv-05").c4RoomId = 1105
  end)
  eq("remote: putting the live mapping back over it is refused", r.errorCode, "VF_ONSITE_ONLY")
  eq("...the installer's mapping stays", display(after.config, "tv-05").c4RoomId, 1305)
  eq("...nothing is stored", after.revision, before.revision)
end
do
  local live = ecore.store:published()
  local snap = ecore:remote("snapshot", {}, "publish")
  local args = { baseRevision = snap.data.draft.revision, acknowledged = acksOf(snap.data.draft) }
  eq("draft only: publish is still refused", ecore:remote("publish", args, "draft").errorCode, "VF_FORBIDDEN")
  local r = ecore:remote("publish", args, "publish")
  eq("remote publish of a draft whose mapping differs from what is live is refused", r.errorCode, "VF_ONSITE_ONLY")
  check("...naming it", tostring(r.detail):find("Display 'TV 05' room", 1, true) ~= nil, r.detail)
  check(
    "...saying it cannot put it live",
    tostring(r.detail):find("cannot put device mapping or device commands live", 1, true) ~= nil,
    r.detail
  )
  eq("...nothing went live", ecore.store:published().versionId, live.versionId)
  eq("...the live mapping is unchanged", display(ecore.config, "tv-05").c4RoomId, 1105)
  eq("...and the draft is still there", display(ecore.store:draft().config, "tv-05").c4RoomId, 1305)
end
eq(
  "Off: a remote save is refused before any of this",
  ecore:remote(
    "save_draft",
    { config = copy(ecore.store:draft().config), baseRevision = ecore.store:draft().revision },
    nil
  ).errorCode,
  "VF_FORBIDDEN"
)

print("on-site only: publish and rollback")
local beforeRemap = ecore.store:published().versionId
local onSitePub = installerPublish()
check("the installer publishes the remap on site", onSitePub.ok)
local remapped = onSitePub.data.versionId
eq("...TV 05 is live in its new room", display(ecore.config, "tv-05").c4RoomId, 1305)
do
  local r = ecore:remote("rollback", { versionId = beforeRemap }, "publish")
  eq("remote rollback to a version with another mapping is refused", r.errorCode, "VF_ONSITE_ONLY")
  check("...naming it", tostring(r.detail):find("Display 'TV 05' room", 1, true) ~= nil, r.detail)
  check(
    "...saying to roll back on site",
    tostring(r.detail):find("Roll back on site in Installer Studio", 1, true) ~= nil,
    r.detail
  )
  eq("...nothing changed live", ecore.store:published().versionId, remapped)
end
do
  local r = remoteSave(function(c)
    display(c, "tv-06").name = "TV 06 (remote)"
  end)
  eq("remote: a rename on the new mapping is saved", r.ok, true)
  local snap = ecore:remote("snapshot", {}, "publish")
  local pub = ecore:remote(
    "publish",
    { baseRevision = snap.data.draft.revision, acknowledged = acksOf(snap.data.draft) },
    "publish"
  )
  eq("...and published remotely (the mapping is what is live)", pub.ok, true)
  eq("...TV 06's new name is live", display(ecore.config, "tv-06").name, "TV 06 (remote)")
  local back = ecore:remote("rollback", { versionId = remapped }, "publish")
  eq("remote rollback to a version with the same mapping works", back.ok, true)
  eq("...the older name is live again", display(ecore.config, "tv-06").name, "TV 06")
end
eq(
  "an unknown version is still answered as unknown",
  ecore:remote("rollback", { versionId = "v999" }, "publish").errorCode,
  "VF_NOT_FOUND"
)

print("on-site only: with no draft, the live configuration is the base")
ecore.store:discardDraft()
check("(no draft)", ecore.store:draft() == nil)
do
  local snap = ecore:remote("snapshot", {}, "draft")
  local cfg = copy(snap.data.published.config)
  display(cfg, "tv-07").c4RoomId = 1999
  local r = ecore:remote("save_draft", { config = cfg }, "draft")
  eq("remote: a mapping change against what is live is refused", r.errorCode, "VF_ONSITE_ONLY")
  check("...and no draft was made", ecore.store:draft() == nil)
  display(cfg, "tv-07").c4RoomId = 1107
  display(cfg, "tv-07").name = "TV 07 (remote)"
  eq("remote: a rename against what is live is saved", ecore:remote("save_draft", { config = cfg }, "draft").ok, true)
end

-- ── The guard: no Control4 id or command field slips through ─────────────────
print("on-site only: guard")
local WORDS = { "c4", "device", "command", "param", "variable" }
local function looksMapped(key)
  local k = tostring(key):lower()
  for _, w in ipairs(WORDS) do
    if k:find(w, 1, true) then
      return true
    end
  end
  return false
end
local function mutated(v)
  if type(v) == "number" then
    return v + 1
  elseif type(v) == "string" then
    return v .. "-X"
  elseif type(v) == "boolean" then
    return not v
  elseif type(v) == "table" then
    local t = U.copy(v)
    t.guard = 1
    return t
  end
  return 1
end
--- Changes every field of `base` whose name looks like a Control4 id or a
--- command, one at a time; returns how many and the paths not caught.
local function guardWalk(base)
  local walked, missed = 0, {}
  local function walk(node, trail)
    for _, k in ipairs(U.sortedKeys(node)) do
      local v = node[k]
      local here = {}
      for i, t in ipairs(trail) do
        here[i] = t
      end
      here[#here + 1] = k
      if type(k) == "string" and looksMapped(k) and RemoteScope.NOT_MAPPING[k] == nil then
        walked = walked + 1
        local m = U.copy(base)
        local target = m
        for i = 1, #trail do
          target = target[trail[i]]
        end
        target[k] = mutated(target[k])
        if #RemoteScope.changes(base, m) == 0 then
          local names = {}
          for i, t in ipairs(here) do
            names[i] = tostring(t)
          end
          missed[#missed + 1] = table.concat(names, ".")
        end
      end
      if type(v) == "table" then
        walk(v, here)
      end
    end
  end
  walk(base, {})
  return walked, missed
end
local guardBase = ecore.store:published().config
local walked, missed = guardWalk(guardBase)
check("the guard walks every Control4-looking field of a full venue", walked >= 60, walked)
check("...and changing any one of them is caught", #missed == 0, table.concat(missed, " "))
do
  -- The guard itself catches a field the module forgets.
  local displays = RemoteScope.KINDS[1]
  local keep = displays.fields
  displays.fields = { keep[2], keep[3], keep[4], keep[5], keep[6] } -- without c4RoomId
  local _, missedWithout = guardWalk(guardBase)
  displays.fields = keep
  check("(the guard notices a field left out)", #missedWithout > 0)
end
do
  -- Every Control4-looking field name the code reads or a template writes is
  -- compared by the module or listed as not mapping, with its reason.
  local covered = RemoteScope.fieldNames()
  local unknown = {}
  local function consider(name, where)
    if looksMapped(name) and not covered[name] and RemoteScope.NOT_MAPPING[name] == nil then
      unknown[#unknown + 1] = where .. ":" .. name
    end
  end
  for _, file in ipairs({ "schema", "rules", "routing", "audio", "sourcecontrol", "templates" }) do
    local f = io.open("src/venueflow/" .. file .. ".lua")
    local src = f:read("*a")
    f:close()
    for name in src:gmatch("%.([%a_][%w_]*)") do
      consider(name, file)
    end
    if file == "templates" then
      for name in src:gmatch("([%a_][%w_]*)%s*=[^=]") do
        consider(name, file)
      end
    end
  end
  check("every Control4-looking field in the code is covered or explained", #unknown == 0, table.concat(unknown, " "))
  for name, why in pairs(RemoteScope.NOT_MAPPING) do
    check("not mapping, with a reason: " .. name, type(why) == "string" and #why > 10)
  end
  -- A step that tunes a source to a channel (a step type being added) is
  -- not mapping: it names a VenueFlow source and a channel.
  check("a step's sourceId and channel are not flagged", not looksMapped("sourceId") and not looksMapped("channel"))
end

T.done()
