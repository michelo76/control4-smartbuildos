--- Configuration only: no values, assignments, credentials or device mappings.
--- Wire shape matches the TS version-1 export. Composer applies one role locally.
local schema = require("systemlink.schema")
local M = { VERSION = 1, MAX_BYTES = 65536, MAX_ITEMS = 128 }
local fields = {
  "name",
  "type",
  "description",
  "group",
  "units",
  "allowed_values",
  "min",
  "max",
  "precision",
  "max_length",
  "export_enabled",
  "freshness",
  "filter",
  "display_name",
}
local forbidden = {
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
function M.copy(v)
  if type(v) ~= "table" then
    return v
  end
  local t = {}
  for k, x in pairs(v) do
    t[k] = M.copy(x)
  end
  return t
end
function M.noSecrets(v, depth)
  depth = depth or 0
  if depth > 16 then
    return false, "configuration nesting exceeds 16"
  end
  if type(v) ~= "table" then
    return true
  end
  for k, x in pairs(v) do
    for _, word in ipairs(forbidden) do
      if tostring(k):lower():find(word, 1, true) then
        return false, "forbidden field: " .. tostring(k)
      end
    end
    local ok, err = M.noSecrets(x, depth + 1)
    if not ok then
      return false, err
    end
  end
  return true
end
function M.definition(def)
  local out = {}
  for _, k in ipairs(fields) do
    out[k] = M.copy(def[k])
  end
  return out
end
local function array(t, limit)
  if type(t) ~= "table" or #t > limit then
    return false
  end
  local n = 0
  for k in pairs(t) do
    if type(k) ~= "number" or k < 1 or k > #t or k % 1 ~= 0 then
      return false
    end
    n = n + 1
  end
  return n == #t
end
function M.export(engine)
  if not engine.link then
    return nil, "not provisioned"
  end
  local link = engine.link
  local role = link.role
  if role ~= "a" and role ~= "b" then
    return nil, "endpoint role unavailable"
  end
  local other = role == "a" and "b" or "a"
  local doc = {
    version = 1,
    exported_at = engine.io.isoNow(),
    link_name = "System Link",
    endpoints = {},
    groups = {},
    items = {},
    templates = M.copy(engine.io.load("sl_templates") or {}),
    required_companions = {},
  }
  doc.endpoints = {
    {
      role = role,
      alias = link.alias or "",
      namespace = engine:namespaceFor({ owner = link.endpoint }),
      timezone = engine.io.timezone and engine.io.timezone() or "",
    },
    {
      role = other,
      alias = link.peer_alias or "",
      namespace = engine:namespaceFor({ owner = link.peer }),
      timezone = "",
    },
  }
  local groups, companions = {}, {}
  for _, def in ipairs(schema.registryItems(engine.registry)) do
    local ownerRole = def.owner == link.endpoint and role or other
    local out = M.definition(def)
    -- Safe descriptive metadata only. No permissions or physical mappings.
    if type(def.companion) == "table" then
      out.companion = { kind = def.companion.kind, name = def.companion.name, field = def.companion.field }
      local c = out.companion
      local key = ownerRole .. ":" .. tostring(c.name)
      if not companions[key] then
        doc.required_companions[#doc.required_companions + 1] =
          { kind = c.kind, name = c.name, on_role = ownerRole == "a" and "b" or "a" }
        companions[key] = true
      end
    end
    doc.items[#doc.items + 1] = { source_id = def.id, owner_role = ownerRole, definition = out }
    if out.group and out.group ~= "" then
      groups[out.group] = true
    end
  end
  for g in pairs(groups) do
    doc.groups[#doc.groups + 1] = g
  end
  table.sort(doc.groups)
  if #doc.items > M.MAX_ITEMS then
    return nil, "export exceeds 128 items; split the configuration"
  end
  local ok, err = M.noSecrets(doc)
  if not ok then
    return nil, err
  end
  return doc
end
--- Fail the whole preview on malformed definitions; never silently partially import.
function M.plan(doc, role)
  if role ~= "a" and role ~= "b" then
    return nil, "select local import role a or b"
  end
  if type(doc) ~= "table" or doc.version ~= 1 then
    return nil, "unsupported configuration version"
  end
  local ok, err = M.noSecrets(doc)
  if not ok then
    return nil, err
  end
  if not array(doc.items, M.MAX_ITEMS) or #doc.items == 0 then
    return nil, "items must be an array of 1..128 definitions"
  end
  local defs, names, skipped = {}, {}, 0
  for _, item in ipairs(doc.items) do
    if
      type(item) ~= "table"
      or (item.owner_role ~= "a" and item.owner_role ~= "b")
      or type(item.definition) ~= "table"
    then
      return nil, "invalid item or owner role"
    end
    local def = M.definition(item.definition)
    def.id, def.owner = "preview", "preview"
    ok, err = schema.validateDefinition(def)
    if not ok then
      return nil, err
    end
    if item.owner_role == role then
      if names[def.name] then
        return nil, "duplicate item name: " .. def.name
      end
      names[def.name] = true
      -- Export fields must be recreated via Export Device; never import detached
      -- feedback fields as controllable equipment or ordinary local variables.
      if item.definition.companion then
        skipped = skipped + 1
      else
        def.id, def.owner = nil, nil
        defs[#defs + 1] = def
      end
    end
  end
  if #defs == 0 then
    return nil, "no ordinary shared items for selected role; recreate exports with Export Device"
  end
  return { definitions = defs, skipped_exports = skipped, role = role }
end
--- Validate the complete batch against a private registry before the first write.
function M.preflight(engine, definitions)
  if not engine.link then
    return false, "not provisioned"
  end
  local reg = M.copy(engine.registry)
  for i, def in ipairs(definitions) do
    local candidate = M.copy(def)
    candidate.id, candidate.owner = "preview-" .. i, engine:selfEndpoint()
    while reg.items[candidate.id] do
      candidate.id = candidate.id .. "x"
    end
    local ok, err = schema.addDefinition(reg, candidate, engine.io.now())
    if not ok then
      return false, err
    end
  end
  return true
end
function M.apply(engine, definitions)
  local ok, err = M.preflight(engine, definitions)
  if not ok then
    return false, err
  end
  for _, def in ipairs(definitions) do
    local created, why = engine:createItem(M.copy(def), nil)
    if not created then
      return false, why
    end
  end
  return true
end
return M
