--- Mode Composer configuration store: the versioned envelope, migrations,
--- and atomic import. Persistence itself is INJECTED (`opts.persist` with
--- get/set) so the module tests without the C4 shim's persist and the driver
--- hands in lib.persist. Nothing in the envelope is secret — security user
--- codes live in the driver's encrypted persist, never here — so export is
--- the whole envelope verbatim (spec §51).
---
--- The envelope is kept JSON-shaped (string keys, no functions, no cycles):
--- export/import and any future Driver Cloud backup carry it unchanged.

local model = require("modes.model")

local M = {}

--- Bump when the envelope shape changes, and add a migration below. An
--- unversioned serialized table is the corner §50 forbids painting into.
M.CONFIG_VERSION = 1

--- Migrations: MIGRATIONS[n] upgrades an envelope FROM version n TO n+1.
--- Each must be total — tolerate missing containers, never throw on partial
--- data. Tested with corrupted fixtures in test_mode_store.lua.
M.MIGRATIONS = {
  -- [1] = function(cfg) ... end,  -- future: 1 -> 2
}

local PERSIST_KEY = "ModeComposerConfig"
local STATE_KEY = "ModeComposerActive"

--- Ensure the containers the model expects all exist. Applied after load and
--- after import so partially-written data degrades instead of crashing.
local function normalize(cfg)
  cfg.configVersion = tonumber(cfg.configVersion) or M.CONFIG_VERSION
  cfg.modes = type(cfg.modes) == "table" and cfg.modes or {}
  cfg.order = type(cfg.order) == "table" and cfg.order or {}
  cfg.groups = type(cfg.groups) == "table" and cfg.groups or {}
  cfg.slots = type(cfg.slots) == "table" and cfg.slots or {}
  cfg.settings = type(cfg.settings) == "table" and cfg.settings or {}
  return cfg
end

--- Run migrations from cfg.configVersion up to CONFIG_VERSION.
--- @return table cfg, boolean migrated
function M.migrate(cfg)
  cfg = normalize(cfg)
  local migrated = false
  while cfg.configVersion < M.CONFIG_VERSION do
    local step = M.MIGRATIONS[cfg.configVersion]
    if not step then
      -- No path forward: freeze at the current version rather than guessing.
      break
    end
    step(cfg)
    cfg.configVersion = cfg.configVersion + 1
    migrated = true
  end
  return normalize(cfg), migrated
end

--- Load the envelope. A future-versioned envelope (downgraded driver) loads
--- read-only: we return it plus readOnly=true and the driver refuses writes,
--- because saving would strip fields a newer schema depends on.
--- @param persist table {get=fn(key,default), set=fn(key,value)}
--- @return table cfg, boolean readOnly
function M.load(persist)
  local raw = persist.get(PERSIST_KEY, nil)
  if type(raw) ~= "table" or raw.configVersion == nil then
    local fresh = normalize(model.emptyConfig())
    fresh.configVersion = M.CONFIG_VERSION
    return fresh, false
  end
  local cfg = M.migrate(raw)
  if cfg.configVersion > M.CONFIG_VERSION then
    return cfg, true
  end
  return cfg, false
end

--- Save the envelope. Refuses (returns false + findings) when the model says
--- the config has ERROR-level problems — a corrupt envelope on disk is how
--- restarts brick, so bad configs never reach persist.
--- @return boolean ok, table findings
function M.save(persist, cfg)
  cfg = normalize(cfg)
  local findings = model.validate(cfg)
  if not model.isSaveable(findings) then
    return false, findings
  end
  persist.set(PERSIST_KEY, cfg)
  return true, findings
end

--- Runtime active-mode state, persisted separately from configuration so a
--- config save never races the activation bookkeeping.
--- shape: { presence_id, lifestyle_id, since, activation_id }
function M.loadActive(persist)
  local raw = persist.get(STATE_KEY, nil)
  if type(raw) ~= "table" then
    return {}
  end
  return raw
end

function M.saveActive(persist, active)
  persist.set(STATE_KEY, active or {})
end

--- Export: a deep copy of the envelope (never the live table — callers keep
--- mutating it) tagged with the exporting version.
function M.export(cfg)
  local out = model.deepcopy(normalize(cfg))
  out.exported_with = M.CONFIG_VERSION
  return out
end

--- Import pipeline (spec §52): validate the candidate's shape, migrate a
--- STAGED copy, validate with the model, and only then swap it in — the
--- current config is untouched unless every step passes. Returns the staged
--- config on success; the caller persists it via save().
--- @param candidate table decoded import payload
--- @return table? staged, table|string findingsOrErr
function M.stageImport(candidate)
  if type(candidate) ~= "table" then
    return nil, "import payload is not a table"
  end
  if candidate.configVersion == nil then
    return nil, "import payload has no configVersion — not a Mode Composer export"
  end
  if tonumber(candidate.configVersion) == nil then
    return nil, "configVersion is not a number"
  end
  if tonumber(candidate.configVersion) > M.CONFIG_VERSION then
    return nil,
      string.format(
        "export is from a newer Mode Composer (config v%s, this driver reads v%s) — update the driver first",
        candidate.configVersion,
        M.CONFIG_VERSION
      )
  end
  local staged = M.migrate(model.deepcopy(candidate))
  staged.exported_with = nil
  local findings = model.validate(staged)
  if not model.isSaveable(findings) then
    return nil, findings
  end
  return staged, findings
end

return M
