--- VenueFlow: where a venue's configuration lives (pure, over an injected
--- key-value store: the controller's persistence API in the driver, a table
--- in tests).
---
--- Three things are kept, each a whole document:
---   draft      what the installer is editing; saved often; never runs the venue
---   published  what the venue runs on; replaced only by Publish or Rollback
---   history    the published versions before it (newest first, bounded)
---
--- Floor-plan images are stored apart under content keys ("img_<hash>") so a
--- 300 kB picture is not rewritten with every draft save, and so versions can
--- share it. Browser storage is never the authority for any of this.

local U = require("venueflow.util")
local Schema = require("venueflow.schema")

local M = {}

M.KEYS = {
  draft = "vf_draft_v1",
  published = "vf_published_v1",
  history = "vf_history_v1",
  images = "vf_images_v1", -- index: key -> { bytes, type }
  imagePrefix = "vf_img_",
}
M.HISTORY_MAX = 5
M.IMAGE_MAX_BYTES = 600 * 1024
M.IMAGES_MAX = 12
M.BACKUP_FORMAT = "venueflow-backup"
M.BACKUP_VERSION = 1

local Store = {}
Store.__index = Store

--- deps = { kv = { get(key), set(key, value), delete(key) }, now(), hash(text) -> hex }
function M.new(deps)
  local self = setmetatable({}, Store)
  self.kv = deps.kv
  self.now = deps.now
  self.hash = deps.hash
  self.cache = {}
  return self
end

function Store:_read(name)
  if self.cache[name] == nil then
    local ok, value = pcall(self.kv.get, M.KEYS[name])
    self.cache[name] = (ok and type(value) == "table") and value or false
  end
  return self.cache[name] or nil
end

function Store:_write(name, value)
  local ok, err = pcall(self.kv.set, M.KEYS[name], value)
  if not ok then
    return false, tostring(err)
  end
  self.cache[name] = value or false
  return true
end

-- ─── Draft ──────────────────────────────────────────────────────────────────

--- { config, revision, savedAt } or nil.
function Store:draft()
  local d = self:_read("draft")
  if d == nil then
    return nil
  end
  return { config = U.copy(d.config), revision = d.revision, savedAt = d.savedAt, basedOn = d.basedOn }
end

--- Saves the draft. `baseRevision` must be the revision the editor loaded
--- (two Studio tabs cannot silently overwrite each other); pass nil only to
--- create the first draft or with `force`.
--- Returns revision, or nil + "stale" | "invalid" | "storage", detail.
function Store:saveDraft(config, baseRevision, opts)
  opts = opts or {}
  local current = self:_read("draft")
  if current ~= nil and not opts.force and baseRevision ~= current.revision then
    return nil, "stale", string.format("draft is at revision %s", tostring(current.revision))
  end
  local migrated, why = Schema.migrate(config)
  if migrated == nil then
    return nil, "invalid", why
  end
  local normalized = Schema.normalize(migrated)
  local revision = (current and current.revision or 0) + 1
  local ok, err = self:_write("draft", {
    config = normalized,
    revision = revision,
    savedAt = self.now(),
    basedOn = opts.basedOn or (current and current.basedOn) or nil,
  })
  if not ok then
    return nil, "storage", err
  end
  return revision
end

function Store:discardDraft()
  pcall(self.kv.delete, M.KEYS.draft)
  self.cache.draft = false
end

-- ─── Published and history ──────────────────────────────────────────────────

function Store:published()
  local p = self:_read("published")
  if p == nil then
    return nil
  end
  return { config = U.copy(p.config), versionId = p.versionId, publishedAt = p.publishedAt, note = p.note, by = p.by }
end

function Store:history()
  local h = self:_read("history")
  local out = {}
  for i, v in ipairs(h and h.versions or {}) do
    out[i] = { versionId = v.versionId, publishedAt = v.publishedAt, note = v.note, by = v.by }
  end
  return out
end

function Store:_nextVersionId()
  local p = self:_read("published")
  local n = 0
  if p and type(p.versionId) == "string" then
    n = tonumber(p.versionId:match("^v(%d+)$")) or 0
  end
  local h = self:_read("history")
  for _, v in ipairs(h and h.versions or {}) do
    local m = tonumber(tostring(v.versionId):match("^v(%d+)$")) or 0
    if m > n then
      n = m
    end
  end
  return "v" .. (n + 1)
end

function Store:_pushHistory(version)
  local h = self:_read("history") or { versions = {} }
  local versions = U.copy(h.versions or {})
  table.insert(versions, 1, version)
  while #versions > M.HISTORY_MAX do
    table.remove(versions)
  end
  return self:_write("history", { versions = versions })
end

--- Publishes the draft. Validation and acknowledgements are the caller's job
--- (core.lua); this only moves documents.
function Store:publish(note, by)
  local d = self:_read("draft")
  if d == nil then
    return nil, "no draft"
  end
  local current = self:_read("published")
  local versionId = self:_nextVersionId()
  if current ~= nil then
    local ok, err = self:_pushHistory(U.copy(current))
    if not ok then
      return nil, err
    end
  end
  local version = { config = U.copy(d.config), versionId = versionId, publishedAt = self.now(), note = note, by = by }
  local ok, err = self:_write("published", version)
  if not ok then
    return nil, err
  end
  d.basedOn = versionId
  self:_write("draft", d)
  self:collectImages()
  return versionId
end

--- Makes a previous version the published one again. The version it replaces
--- goes to history, so a rollback can itself be rolled back.
function Store:rollback(versionId, by)
  local h = self:_read("history")
  local found, index
  for i, v in ipairs(h and h.versions or {}) do
    if v.versionId == versionId then
      found, index = v, i
    end
  end
  if found == nil then
    return nil, "unknown version"
  end
  local current = self:_read("published")
  local versions = U.copy(h.versions)
  table.remove(versions, index)
  if current ~= nil then
    table.insert(versions, 1, U.copy(current))
  end
  while #versions > M.HISTORY_MAX do
    table.remove(versions)
  end
  local newId = self:_nextVersionId()
  local version = {
    config = U.copy(found.config),
    versionId = newId,
    publishedAt = self.now(),
    note = "Rollback to " .. tostring(versionId) .. (found.note and (" (" .. tostring(found.note) .. ")") or ""),
    by = by,
  }
  local ok, err = self:_write("published", version)
  if not ok then
    return nil, err
  end
  self:_write("history", { versions = versions })
  return newId
end

-- ─── Images ─────────────────────────────────────────────────────────────────

function Store:_imageIndex()
  return self:_read("images") or {}
end

--- data = a data: URL (image/png, image/jpeg or image/webp). Returns key, or nil + reason.
function Store:putImage(data)
  if type(data) ~= "string" then
    return nil, "invalid"
  end
  local mime = data:match("^data:(image/[%w%+%-%.]+);base64,")
  if mime ~= "image/png" and mime ~= "image/jpeg" and mime ~= "image/webp" then
    return nil, "invalid"
  end
  if #data > M.IMAGE_MAX_BYTES then
    return nil, "too_large"
  end
  local key = "img_" .. tostring(self.hash(data)):sub(1, 16)
  local index = U.copy(self:_imageIndex())
  if index[key] == nil then
    if U.count(index) >= M.IMAGES_MAX then
      self:collectImages()
      index = U.copy(self:_imageIndex())
      if U.count(index) >= M.IMAGES_MAX then
        return nil, "too_many"
      end
    end
    local ok = pcall(self.kv.set, M.KEYS.imagePrefix .. key, data)
    if not ok then
      return nil, "storage"
    end
    index[key] = { bytes = #data, type = mime }
    self:_write("images", index)
  end
  return key
end

function Store:getImage(key)
  if type(key) ~= "string" or self:_imageIndex()[key] == nil then
    return nil
  end
  local ok, data = pcall(self.kv.get, M.KEYS.imagePrefix .. key)
  if ok and type(data) == "string" then
    return data
  end
  return nil
end

local function referenced(config, into)
  for _, f in ipairs(type(config) == "table" and config.floors or {}) do
    if type(f) == "table" and type(f.image) == "table" and type(f.image.key) == "string" then
      into[f.image.key] = true
    end
  end
end

--- Deletes images no draft, published or history version refers to.
function Store:collectImages()
  local used = {}
  local d, p, h = self:_read("draft"), self:_read("published"), self:_read("history")
  if d then
    referenced(d.config, used)
  end
  if p then
    referenced(p.config, used)
  end
  for _, v in ipairs(h and h.versions or {}) do
    referenced(v.config, used)
  end
  local index = U.copy(self:_imageIndex())
  local removed = 0
  for key in pairs(self:_imageIndex()) do
    if not used[key] then
      pcall(self.kv.delete, M.KEYS.imagePrefix .. key)
      index[key] = nil
      removed = removed + 1
    end
  end
  if removed > 0 then
    self:_write("images", index)
  end
  return removed
end

-- ─── Backup and restore ─────────────────────────────────────────────────────

--- One self-contained document: the draft, the published version and every
--- picture they refer to (previous versions are not included). PIN hashes are included (so a restore keeps staff PINs);
--- the Installer Passcode and session tokens never are.
function Store:exportBackup()
  local d, p = self:_read("draft"), self:_read("published")
  local doc = {
    format = M.BACKUP_FORMAT,
    version = M.BACKUP_VERSION,
    schema = Schema.SCHEMA_VERSION,
    exportedAt = self.now(),
    draft = d and { config = U.copy(d.config) } or nil,
    published = p
        and { config = U.copy(p.config), versionId = p.versionId, publishedAt = p.publishedAt, note = p.note }
      or nil,
    images = {},
  }
  local used = {}
  if d then
    referenced(d.config, used)
  end
  if p then
    referenced(p.config, used)
  end
  for key in pairs(used) do
    doc.images[key] = self:getImage(key)
  end
  return doc
end

--- Restores a backup INTO THE DRAFT. The venue keeps running on what is
--- published until the installer publishes the restored draft.
--- which = "published" (default when present) | "draft"
--- Returns revision, or nil + reason, detail.
function Store:restoreBackup(doc, which)
  if type(doc) ~= "table" or doc.format ~= M.BACKUP_FORMAT then
    return nil, "invalid", "not a VenueFlow backup"
  end
  if tonumber(doc.version) ~= M.BACKUP_VERSION then
    return nil, "invalid", "unsupported backup version"
  end
  local source
  if which == "draft" then
    source = doc.draft
  else
    source = doc.published or doc.draft
  end
  if type(source) ~= "table" or type(source.config) ~= "table" then
    return nil, "invalid", "the backup holds no configuration"
  end
  local migrated, why = Schema.migrate(source.config)
  if migrated == nil then
    return nil, "invalid", why
  end
  local config = Schema.normalize(migrated)
  -- Images first: a floor whose picture cannot be stored loses the picture,
  -- not the floor.
  local needed = {}
  referenced(config, needed)
  for key in pairs(needed) do
    local data = type(doc.images) == "table" and doc.images[key] or nil
    local stored = data and self:putImage(data) or nil
    -- The Studio uploads pictures one by one before the restore (a picture
    -- must not travel inside JSON); one that is already stored is kept.
    if stored == nil and self:getImage(key) ~= nil then
      stored = key
    end
    if stored ~= key then
      for _, f in ipairs(config.floors) do
        if type(f.image) == "table" and f.image.key == key then
          f.image = stored and { key = stored, width = f.image.width, height = f.image.height } or nil
        end
      end
    end
  end
  return self:saveDraft(config, nil, { force = true })
end

return M
