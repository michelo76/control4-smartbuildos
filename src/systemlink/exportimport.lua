--- Configuration export/import — pure module.
---
--- The Lua twin of smartbuildos/src/lib/system-link/export-import.ts
--- (decision SL-11). An export is a versioned, reviewable description of
--- the link's CONFIGURATION as this bridge knows it: aliases and
--- namespaces, groups, every item definition (its own and the peer's
--- mirrors) and the companion kinds the other side needs. It carries no
--- credential, invitation, licence, controller assignment or customer
--- data, and refuses to be built if any such field is present. An import
--- is a DRAFT: nothing is written until the dealer applies it; item ids
--- are re-minted so a source id is never reused as a live identity;
--- exports and companions are never created.

local schema = require("systemlink.schema")

local M = {}

M.EXPORT_VERSION = 1

local FORBIDDEN_KEYS = {
  "credential",
  "token",
  "secret",
  "activation",
  "invitation",
  "controller_id",
  "capability",
  "license",
  "hash",
  "email",
  "phone",
  "address",
}

local STRIP = { id = true, owner = true, order = true, schema_rev = true, created_at = true, deleted_at = true, mirror = true }

local function copyDefinition(def)
  local out = {}
  for k, v in pairs(def) do
    if not STRIP[k] then
      if type(v) == "table" then
        local t = {}
        for k2, v2 in pairs(v) do
          t[k2] = v2
        end
        out[k] = t
      else
        out[k] = v
      end
    end
  end
  return out
end

--- Defence in depth: every key path that looks like a secret or a customer
--- field, or {} when the document is clean.
function M.assertNoSecrets(doc, path)
  path = path or "$"
  local findings = {}
  if type(doc) ~= "table" then
    return findings
  end
  local keys = {}
  for k in pairs(doc) do
    keys[#keys + 1] = k
  end
  table.sort(keys, function(a, b)
    return tostring(a) < tostring(b)
  end)
  for _, k in ipairs(keys) do
    local lower = tostring(k):lower()
    for _, f in ipairs(FORBIDDEN_KEYS) do
      if lower:find(f, 1, true) then
        findings[#findings + 1] = path .. "." .. tostring(k)
        break
      end
    end
    if type(doc[k]) == "table" then
      for _, sub in ipairs(M.assertNoSecrets(doc[k], path .. "." .. tostring(k))) do
        findings[#findings + 1] = sub
      end
    end
  end
  return findings
end

--- Builds the export document.
--- input = { link = engine.link (role, alias, namespace, peer_alias,
---           peer_namespace), timezone, items = registry items (live, in
---           order), now_iso }
--- Returns the document, or nil and the secret findings.
function M.buildExport(input)
  local link = input.link
  local myRole = link.role or "a"
  local peerRole = myRole == "a" and "b" or "a"
  local groups, seen = {}, {}
  local items, companions, haveCompanion = {}, {}, {}
  for _, def in ipairs(input.items or {}) do
    if not def.deleted_at then
      local role = def.mirror and peerRole or myRole
      local copy = copyDefinition(def)
      if type(copy.group) == "string" and copy.group ~= "" and not seen[copy.group] then
        seen[copy.group] = true
        groups[#groups + 1] = copy.group
      end
      local c = type(copy.companion) == "table" and copy.companion or nil
      if c and c.kind and c.name then
        local key = role .. "/" .. c.name
        if not haveCompanion[key] then
          haveCompanion[key] = true
          companions[#companions + 1] = { kind = c.kind, name = c.name, on_role = role == "a" and "b" or "a" }
        end
      end
      items[#items + 1] = { source_id = def.id, owner_role = role, definition = copy }
    end
  end
  table.sort(groups)
  local endpoints = {
    { role = myRole, alias = link.alias or "", namespace = link.namespace or "", timezone = input.timezone or "" },
  }
  if link.peer_namespace then
    endpoints[#endpoints + 1] = { role = peerRole, alias = link.peer_alias or "", namespace = link.peer_namespace, timezone = "" }
  end
  local doc = {
    version = M.EXPORT_VERSION,
    exported_at = input.now_iso or "",
    link_name = (link.alias or "") .. " <-> " .. (link.peer_alias or ""),
    endpoints = endpoints,
    groups = groups,
    items = items,
    templates = {},
    required_companions = companions,
  }
  local findings = M.assertNoSecrets(doc)
  if #findings > 0 then
    return nil, findings
  end
  return doc
end

--- Parses a decoded export into a reviewable draft. Nothing is written.
function M.parseImport(raw)
  local draft = { ok = false, errors = {}, warnings = {}, endpoints = {}, items = {}, required_companions = {}, requires = {} }
  if type(raw) ~= "table" then
    draft.errors[#draft.errors + 1] = "Not a System Link export."
    return draft
  end
  if raw.version ~= M.EXPORT_VERSION then
    draft.errors[#draft.errors + 1] = "Unsupported export version " .. tostring(raw.version) .. "."
    return draft
  end
  local secrets = M.assertNoSecrets(raw)
  if #secrets > 0 then
    local shown = {}
    for i = 1, math.min(5, #secrets) do
      shown[i] = secrets[i]
    end
    draft.errors[#draft.errors + 1] = "The file carries fields that are never imported: " .. table.concat(shown, ", ") .. "."
  end
  for _, e in ipairs(type(raw.endpoints) == "table" and raw.endpoints or {}) do
    if type(e) == "table" and (e.role == "a" or e.role == "b") then
      draft.endpoints[#draft.endpoints + 1] = e
    end
  end
  for _, item in ipairs(type(raw.items) == "table" and raw.items or {}) do
    if type(item) ~= "table" or (item.owner_role ~= "a" and item.owner_role ~= "b") or type(item.definition) ~= "table" then
      draft.warnings[#draft.warnings + 1] = "An item without a valid owner role was skipped."
    else
      local def = copyDefinition(item.definition)
      def.id, def.owner = "pending", "pending"
      def.companion_device_id = nil
      local ok, err = schema.validateDefinition(def)
      draft.items[#draft.items + 1] = {
        source_id = tostring(item.source_id or ""),
        owner_role = item.owner_role,
        definition = def,
        verdict = ok and "ok" or tostring(err),
      }
    end
  end
  draft.required_companions = type(raw.required_companions) == "table" and raw.required_companions or {}
  draft.requires = {
    "Items whose owner role is this bridge's role are created here; the other side's items are created when the same file is applied on the other bridge.",
    "Every item gets a NEW id on import; source ids are never reused.",
  }
  if #draft.required_companions > 0 then
    draft.requires[#draft.requires + 1] =
      "Exports and companions are not imported: recreate each export on its owner, then add companions on the other side."
  end
  draft.requires[#draft.requires + 1] = "Re-run commissioning afterwards."
  local anyOk = false
  for _, i in ipairs(draft.items) do
    if i.verdict == "ok" then
      anyOk = true
    end
  end
  draft.ok = #draft.errors == 0 and anyOk
  return draft
end

--- The definitions to create on THIS bridge (role myRole) from a draft:
--- fresh tables without id, owner or companion.
function M.planImport(draft, myRole)
  local out = {}
  for _, i in ipairs(draft.items) do
    if i.verdict == "ok" and i.owner_role == myRole then
      local def = copyDefinition(i.definition)
      def.companion = nil
      out[#out + 1] = def
    end
  end
  return out
end

return M
