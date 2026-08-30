-- Mode model + store tests: identity, inheritance (incl. cycles),
-- effective-state merging, validation quality, and the atomic import
-- pipeline. Run from the driver root: make test

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

C4 = C4 or {}
require("c4_shim")

local model = require("modes.model")
local store = require("modes.store")

local uuidCounter = 0
local function uuid()
  uuidCounter = uuidCounter + 1
  return "u" .. uuidCounter
end

print("\n[1] Creation: stable ids, template suggestions, no devices selected")
local cfg = model.emptyConfig()
local home = model.newMode(cfg, { kind = "HOME" }, uuid)
local away = model.newMode(cfg, { kind = "AWAY" }, uuid)
local vacation = model.newMode(cfg, { kind = "VACATION" }, uuid)
local movie = model.newMode(cfg, { kind = "MOVIE" }, uuid)
check("id is prefixed and unique", home.id == "m_u1" and away.id == "m_u2")
check("home is PRESENCE", home.category == "PRESENCE")
check("movie is LIFESTYLE", movie.category == "LIFESTYLE")
check("no desired states on creation", next(home.desired_states) == nil)
check("vacation outranks its siblings by default", vacation.priority > away.priority, vacation.priority)
check("vacation suggests hold-confirm", vacation.confirm_hold_s == 3)
check("home occupancy seeded OCCUPIED", home.occupancy == "OCCUPIED")

print("\n[2] Rename is free; references use ids")
away.name = "Gone Fishing"
check("find by new name", model.findByName(cfg, "gone fishing") == away)

print("\n[3] Inheritance: vacation inherits away; overrides only diffs")
away.desired_states["1001"] = { behavior = "SET", state = { on = false } }
away.desired_states["1002"] = { behavior = "SET", state = { on = false } }
local ok = model.setParent(cfg, vacation.id, away.id)
check("parent set", ok == true)
vacation.desired_states["1002"] = { behavior = "SET", state = { on = true, level = 20 } }
local states, sources = model.effectiveStates(cfg, vacation.id)
check("inherited device came through", states["1001"] ~= nil and states["1001"].state.on == false)
check("override wins", states["1002"].state.level == 20)
check("source attribution: 1001 from away", sources["1001"] == away.id)
check("source attribution: 1002 from vacation", sources["1002"] == vacation.id)
away.desired_states["1003"] = { behavior = "SET", state = { on = false } }
states = model.effectiveStates(cfg, vacation.id)
check("a change to away flows into vacation", states["1003"] ~= nil)

print("\n[4] Cycles refused at write time: A -> B -> C -> A")
local a = model.newMode(cfg, { name = "A", category = "LIFESTYLE" }, uuid)
local b = model.newMode(cfg, { name = "B", category = "LIFESTYLE" }, uuid)
local c = model.newMode(cfg, { name = "C", category = "LIFESTYLE" }, uuid)
check("A<-B ok", model.setParent(cfg, b.id, a.id) == true)
check("B<-C ok", model.setParent(cfg, c.id, b.id) == true)
local cyc, err = model.setParent(cfg, a.id, c.id)
check("C<-A refused", cyc == false)
check("error names the modes", tostring(err):find("cycle", 1, true) ~= nil, err)
check("self-parent refused", model.setParent(cfg, a.id, a.id) == false)

print("\n[5] Cross-category inheritance refused")
local x, xerr = model.setParent(cfg, movie.id, away.id)
check("refused", x == false)
check("message explains categories", tostring(xerr):find("PRESENCE", 1, true) ~= nil, xerr)

print("\n[6] Groups expand; explicit device entries beat their group")
cfg.groups.g1 = { id = "g1", name = "All Lights", devices = { "1001", "1010" } }
movie.groups = { { group_id = "g1", behavior = "SET", state = { on = false } } }
movie.desired_states["1010"] = { behavior = "SET", state = { on = true, level = 5 } }
states = model.effectiveStates(cfg, movie.id)
check("group member present", states["1001"].state.on == false)
check("device override beats group", states["1010"].state.level == 5)

print("\n[7] Duplicate: fresh id, references stay with the original")
local copy = model.duplicateMode(cfg, away.id, uuid)
check("new id", copy.id ~= away.id)
check("name marks the copy", copy.name == "Gone Fishing Copy")
check("vacation still inherits the ORIGINAL", cfg.modes[vacation.id].parent_mode == away.id)
copy.desired_states["1001"].state.on = true
check("deep-copied states, not shared", away.desired_states["1001"].state.on == false)

print("\n[8] Delete: children re-parent, slots flagged, nothing silent")
cfg.slots.s1 = { name = "Kitchen 5", gestures = { double_tap = { action = "ACTIVATE", mode_id = away.id } } }
local affected = model.deleteMode(cfg, away.id)
check("vacation re-parented to away's (nil) parent", cfg.modes[vacation.id].parent_mode == nil)
check("affected children reported", affected.children[1] == vacation.id)
check("affected slots reported", affected.slots[1] == "s1")
local findings = model.validate(cfg)
local orphanFound = false
for _, f in ipairs(findings) do
  if f.code == "orphaned-slot" then
    orphanFound = true
    check("orphan message is actionable", f.message:find("Kitchen 5", 1, true) ~= nil, f.message)
  end
end
check("validation flags the orphaned slot", orphanFound)

print("\n[9] Validation: actionable errors, saveable gate")
cfg.modes[vacation.id].desired_states["9999"] = { behavior = "EXPLODE" }
findings = model.validate(cfg)
local badBehavior = false
for _, f in ipairs(findings) do
  if f.code == "bad-behavior" then
    badBehavior = true
    check("names the mode and device", f.message:find("9999", 1, true) ~= nil, f.message)
  end
end
check("bad behavior flagged as ERROR", badBehavior)
check("not saveable with errors", model.isSaveable(findings) == false)
cfg.modes[vacation.id].desired_states["9999"] = nil

print("\n[10] Ordering survives drift")
check("ordered list covers all presence modes", #model.orderedModes(cfg, "PRESENCE") == 3) -- home, vacation, away-copy
model.reorder(cfg, vacation.id, 1)
check("reorder to front", model.orderedModes(cfg)[1].id == vacation.id)

print("\n[11] Store: fresh load, save, reload round-trip")
local persisted = {}
local fakePersist = {
  get = function(key, default)
    if persisted[key] == nil then
      return default
    end
    return persisted[key]
  end,
  set = function(key, value)
    persisted[key] = value
  end,
}
local fresh, ro = store.load(fakePersist)
check("fresh envelope at current version", fresh.configVersion == store.CONFIG_VERSION)
check("not read-only", ro == false)
local saved, sfindings = store.save(fakePersist, cfg)
check("valid config saves", saved == true, saved == false and sfindings and sfindings[1] and sfindings[1].message)
local reloaded = store.load(fakePersist)
check("round-trip keeps modes", reloaded.modes[vacation.id] ~= nil)

print("\n[12] Save refuses an ERROR-level config; persist untouched")
local snapshot = persisted.ModeComposerConfig
cfg.modes[vacation.id].desired_states["777"] = { behavior = "NOPE" }
local ok2 = store.save(fakePersist, cfg)
check("refused", ok2 == false)
check("previous persisted config untouched", persisted.ModeComposerConfig == snapshot)
cfg.modes[vacation.id].desired_states["777"] = nil

print("\n[13] Import: staged, validated, never corrupts current")
local exported = store.export(cfg)
check("export tags its version", exported.exported_with == store.CONFIG_VERSION)
local staged = store.stageImport(exported)
check("clean import stages", staged ~= nil)
local nilStage, nerr = store.stageImport("garbage")
check("non-table refused", nilStage == nil and tostring(nerr):find("not a table", 1, true) ~= nil, nerr)
local future = store.export(cfg)
future.configVersion = store.CONFIG_VERSION + 5
local fStage, ferr = store.stageImport(future)
check(
  "future version refused with guidance",
  fStage == nil and tostring(ferr):find("update the driver", 1, true) ~= nil,
  ferr
)
local corrupt = store.export(cfg)
corrupt.modes[vacation.id].desired_states["55"] = { behavior = "BROKEN" }
local cStage, cfindings = store.stageImport(corrupt)
check("invalid import refused with findings", cStage == nil and type(cfindings) == "table")

print("\n[14] Migration scaffolding: old version walks forward")
store.MIGRATIONS[0] = function(old)
  old.settings.migrated_marker = true
end
local oldCfg = { configVersion = 0, modes = {} }
local migrated = store.migrate(oldCfg)
check("version walked to 1", migrated.configVersion >= 1, migrated.configVersion)
check("migration ran", migrated.settings.migrated_marker == true)
store.MIGRATIONS[0] = nil

print("\n[15] Corrupted persist degrades to a fresh config, not a crash")
persisted.ModeComposerConfig = { configVersion = "not-a-number-but-truthy" }
local recovered = store.load(fakePersist)
check("load survived", type(recovered) == "table" and type(recovered.modes) == "table")

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
