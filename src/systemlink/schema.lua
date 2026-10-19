--- System Link item schema: shared-variable definitions, value states and
--- the Composer naming rules.
---
--- Pure module: no C4 calls, no persistence, no timers. Everything the bridge
--- driver, the relay and System Studio agree on about an *item* lives here so
--- that the three cannot drift apart. The web side mirrors these rules in
--- `src/lib/system-link/schema.ts`; the two are kept in step by the parity
--- fixtures under `test/fixtures/systemlink/`.
---
--- Identity rules:
---   * An item's `id` is minted once (by the owning endpoint) and never
---     changes. Rename, regroup, re-filter — every edit keeps the id, so
---     Composer programming that references the variable keeps working.
---   * `owner` is an endpoint id, never a friendly name. Aliases are display.
---   * `order` is the registration order on the owning endpoint and is the
---     only thing that decides the Composer variable id; it is never reused.
---     A deleted item keeps its order as a tombstone.
---   * Local Control4 device/room ids never appear in a definition.

local M = {}

M.SCHEMA_VERSION = 1

--- Item value types and how each maps onto a native Composer variable type.
--- The native names are the DriverWorks `C4:AddVariable` type strings; CHOICE
--- has no native type, so it is a STRING whose values are validated here.
M.TYPES = {
  BOOLEAN = { native = "BOOL" },
  INTEGER = { native = "NUMBER" },
  DECIMAL = { native = "FLOAT" },
  STRING = { native = "STRING" },
  CHOICE = { native = "STRING" },
}

--- Value states. A value is more than its payload: `false`, `0` and `""` are
--- all *current* values, while UNKNOWN (never observed), UNAVAILABLE (owner
--- says it cannot read it) and STALE (not confirmed within policy) carry no
--- usable payload.
M.STATES = { CURRENT = "current", UNKNOWN = "unknown", UNAVAILABLE = "unavailable", STALE = "stale" }

M.NAME_PATTERN = "^[A-Za-z][A-Za-z0-9_]*$"
M.NAME_MAX = 48
M.ALIAS_MAX = 24
M.STRING_MAX_DEFAULT = 256
M.STRING_MAX_LIMIT = 4096
M.CHOICES_MAX = 64
M.DESCRIPTION_MAX = 512
M.GROUP_MAX = 48

local function isInteger(n)
  return type(n) == "number" and n == math.floor(n) and n == n and math.abs(n) < 2 ^ 53
end

--- Normalises a friendly alias into the namespace prefix used in Composer
--- variable names: letters, digits and underscores only, first char a letter.
--- @param alias string
--- @return string|nil
function M.namespace(alias)
  if type(alias) ~= "string" then
    return nil
  end
  local s = alias:gsub("[^A-Za-z0-9_]", "_"):gsub("^[^A-Za-z]+", "")
  if s == "" then
    return nil
  end
  return s:sub(1, M.ALIAS_MAX)
end

--- The Composer variable name for an item: `<OwnerNamespace>.<Name>`.
--- Identical names on opposite systems stay distinguishable because the
--- owner's namespace is always in front.
function M.variableName(ownerNamespace, def)
  return tostring(ownerNamespace) .. "." .. tostring(def.name)
end

--- Validates a definition. Returns `true` or `false, reason`.
--- Only shape and ranges are checked here; ownership is enforced by the
--- registry (and, independently, by the relay and the backend).
function M.validateDefinition(def)
  if type(def) ~= "table" then
    return false, "definition must be a table"
  end
  if type(def.id) ~= "string" or def.id == "" then
    return false, "id is required"
  end
  if type(def.name) ~= "string" or not def.name:match(M.NAME_PATTERN) or #def.name > M.NAME_MAX then
    return false, "name must be letters, digits and underscores, start with a letter, max " .. M.NAME_MAX
  end
  if not M.TYPES[def.type] then
    return false, "unknown type " .. tostring(def.type)
  end
  if type(def.owner) ~= "string" or def.owner == "" then
    return false, "owner endpoint is required"
  end
  if def.description ~= nil and (type(def.description) ~= "string" or #def.description > M.DESCRIPTION_MAX) then
    return false, "description too long"
  end
  if def.group ~= nil and (type(def.group) ~= "string" or #def.group > M.GROUP_MAX) then
    return false, "group too long"
  end
  if def.units ~= nil and type(def.units) ~= "string" then
    return false, "units must be a string"
  end
  if def.type == "CHOICE" then
    if type(def.allowed_values) ~= "table" or #def.allowed_values == 0 then
      return false, "CHOICE needs allowed_values"
    end
    if #def.allowed_values > M.CHOICES_MAX then
      return false, "too many allowed_values"
    end
    local seen = {}
    for _, v in ipairs(def.allowed_values) do
      if type(v) ~= "string" or v == "" or #v > M.STRING_MAX_DEFAULT then
        return false, "allowed_values must be non-empty strings"
      end
      if seen[v] then
        return false, "duplicate allowed value " .. v
      end
      seen[v] = true
    end
  end
  if def.type == "INTEGER" or def.type == "DECIMAL" then
    if def.min ~= nil and type(def.min) ~= "number" then
      return false, "min must be a number"
    end
    if def.max ~= nil and type(def.max) ~= "number" then
      return false, "max must be a number"
    end
    if def.min ~= nil and def.max ~= nil and def.min > def.max then
      return false, "min exceeds max"
    end
    if
      def.type == "INTEGER"
      and ((def.min ~= nil and not isInteger(def.min)) or (def.max ~= nil and not isInteger(def.max)))
    then
      return false, "INTEGER bounds must be integers"
    end
    if def.precision ~= nil then
      if def.type ~= "DECIMAL" or not isInteger(def.precision) or def.precision < 0 or def.precision > 6 then
        return false, "precision is 0..6 and DECIMAL only"
      end
    end
  end
  if def.type == "STRING" and def.max_length ~= nil then
    if not isInteger(def.max_length) or def.max_length < 1 or def.max_length > M.STRING_MAX_LIMIT then
      return false, "max_length is 1.." .. M.STRING_MAX_LIMIT
    end
  end
  if def.freshness ~= nil then
    if type(def.freshness) ~= "table" then
      return false, "freshness must be a table"
    end
    if
      def.freshness.max_age_s ~= nil and (type(def.freshness.max_age_s) ~= "number" or def.freshness.max_age_s <= 0)
    then
      return false, "freshness.max_age_s must be positive"
    end
  end
  if def.filter ~= nil then
    local ok, err = M.validateFilter(def, def.filter)
    if not ok then
      return false, err
    end
  end
  return true
end

--- Publication filter shape (the engine is `systemlink.filters`).
function M.validateFilter(def, f)
  if type(f) ~= "table" then
    return false, "filter must be a table"
  end
  for _, k in ipairs({ "debounce_s", "min_interval_s", "max_silence_s" }) do
    if f[k] ~= nil and (type(f[k]) ~= "number" or f[k] < 0 or f[k] > 86400) then
      return false, "filter." .. k .. " must be 0..86400 seconds"
    end
  end
  if f.threshold ~= nil then
    if def.type ~= "INTEGER" and def.type ~= "DECIMAL" then
      return false, "filter.threshold applies to numeric items only"
    end
    if type(f.threshold) ~= "number" or f.threshold < 0 then
      return false, "filter.threshold must be a non-negative number"
    end
  end
  if f.max_silence_s ~= nil and f.min_interval_s ~= nil and f.max_silence_s < f.min_interval_s then
    return false, "filter.max_silence_s must not be below min_interval_s"
  end
  return true
end

--- A typed value: `{ s = state, v = payload }`. Payload is only meaningful
--- when the state is CURRENT.
function M.current(v)
  return { s = M.STATES.CURRENT, v = v }
end
function M.unknown()
  return { s = M.STATES.UNKNOWN }
end
function M.unavailable()
  return { s = M.STATES.UNAVAILABLE }
end

--- Coerces a raw payload (string, number or boolean as Composer or the wire
--- hands it over) into the item's type. Returns value, nil or nil, reason.
function M.coerce(def, raw)
  local t = def.type
  if t == "BOOLEAN" then
    if type(raw) == "boolean" then
      return raw
    end
    if type(raw) == "number" then
      return raw ~= 0
    end
    if type(raw) == "string" then
      local s = raw:lower():gsub("^%s+", ""):gsub("%s+$", "")
      if s == "true" or s == "1" or s == "on" or s == "yes" then
        return true
      end
      if s == "false" or s == "0" or s == "off" or s == "no" then
        return false
      end
    end
    return nil, "not a boolean"
  end
  if t == "INTEGER" or t == "DECIMAL" then
    local n = type(raw) == "number" and raw or tonumber(raw)
    if n == nil or n ~= n or n == math.huge or n == -math.huge then
      return nil, "not a number"
    end
    if t == "INTEGER" then
      if not isInteger(n) then
        return nil, "not an integer"
      end
    elseif def.precision ~= nil then
      local p = 10 ^ def.precision
      n = math.floor(n * p + 0.5) / p
    end
    if def.min ~= nil and n < def.min then
      return nil, "below minimum " .. tostring(def.min)
    end
    if def.max ~= nil and n > def.max then
      return nil, "above maximum " .. tostring(def.max)
    end
    return n
  end
  if t == "STRING" then
    if type(raw) == "number" or type(raw) == "boolean" then
      raw = tostring(raw)
    end
    if type(raw) ~= "string" then
      return nil, "not a string"
    end
    local limit = def.max_length or M.STRING_MAX_DEFAULT
    if #raw > limit then
      return nil, "longer than " .. limit
    end
    return raw
  end
  if t == "CHOICE" then
    if type(raw) ~= "string" then
      return nil, "not a choice"
    end
    for _, v in ipairs(def.allowed_values or {}) do
      if v == raw then
        return raw
      end
    end
    return nil, "not an allowed value"
  end
  return nil, "unknown type"
end

--- Formats a typed value for a native Composer variable. States without a
--- payload render as "" so programming can tell them from real values only
--- through the companion `<name>.STATE` variable the driver maintains.
function M.toNative(def, tv)
  if type(tv) ~= "table" or tv.s ~= M.STATES.CURRENT then
    return ""
  end
  local v = tv.v
  if def.type == "BOOLEAN" then
    return v and "1" or "0"
  end
  if def.type == "INTEGER" then
    return string.format("%d", v)
  end
  if def.type == "DECIMAL" then
    return string.format("%." .. tostring(def.precision or 2) .. "f", v)
  end
  return tostring(v)
end

--- Deep equality for typed values.
function M.equal(a, b)
  if type(a) ~= "table" or type(b) ~= "table" then
    return a == b
  end
  return a.s == b.s and a.v == b.v
end

-- ── Registry ────────────────────────────────────────────────────────────────

--- The definition registry of one endpoint: every item it owns, every mirror
--- it has accepted, the tombstones, and the registration order.
--- Shape (JSON-safe, persisted whole):
---   { version = 1, order = { id, id, ... }, items = { [id] = def }, schema_rev = n }
function M.newRegistry()
  return { version = M.SCHEMA_VERSION, order = {}, items = {}, schema_rev = 0 }
end

function M.registryItems(reg)
  local out = {}
  for _, id in ipairs(reg.order) do
    local def = reg.items[id]
    if def and not def.deleted_at then
      out[#out + 1] = def
    end
  end
  return out
end

local function nameTaken(reg, owner, name, exceptId)
  for id, def in pairs(reg.items) do
    if id ~= exceptId and not def.deleted_at and def.owner == owner and def.name == name then
      return true
    end
  end
  return false
end

--- Adds a definition. The registration order is assigned once and persisted
--- with the registry: it never shifts when an earlier item is deleted.
--- @return boolean ok, string|nil err
function M.addDefinition(reg, def, now)
  local ok, err = M.validateDefinition(def)
  if not ok then
    return false, err
  end
  if reg.items[def.id] then
    return false, "id already registered"
  end
  if nameTaken(reg, def.owner, def.name) then
    return false, "name already used by this owner"
  end
  def.order = #reg.order + 1
  def.schema_rev = (def.schema_rev or 0)
  def.created_at = def.created_at or now
  if def.export_enabled == nil then
    def.export_enabled = true
  end
  reg.order[def.order] = def.id
  reg.items[def.id] = def
  reg.schema_rev = reg.schema_rev + 1
  return true
end

--- Updates editable fields of a definition. Type changes are refused here:
--- a type change is a delete + create that programming must be re-pointed
--- at, and the caller shows that effect before asking.
local EDITABLE = {
  description = true,
  group = true,
  units = true,
  allowed_values = true,
  min = true,
  max = true,
  precision = true,
  max_length = true,
  export_enabled = true,
  freshness = true,
  filter = true,
  display_name = true,
}
function M.updateDefinition(reg, id, patch)
  local def = reg.items[id]
  if not def or def.deleted_at then
    return false, "no such item"
  end
  if patch.type ~= nil and patch.type ~= def.type then
    return false, "type cannot change; delete and create a new item"
  end
  if patch.name ~= nil and patch.name ~= def.name then
    return false, "name cannot change in place; use renameDefinition"
  end
  local candidate = {}
  for k, v in pairs(def) do
    candidate[k] = v
  end
  for k, v in pairs(patch) do
    if not EDITABLE[k] then
      return false, "field " .. tostring(k) .. " is not editable"
    end
    candidate[k] = v
  end
  local ok, err = M.validateDefinition(candidate)
  if not ok then
    return false, err
  end
  for k in pairs(EDITABLE) do
    def[k] = candidate[k]
  end
  def.schema_rev = (def.schema_rev or 0) + 1
  reg.schema_rev = reg.schema_rev + 1
  return true
end

--- Renames an item. The id, order and Composer variable id are unchanged;
--- the Composer *variable name* changes, which is the effect the caller
--- must show (programming keeps pointing at the same variable).
function M.renameDefinition(reg, id, newName)
  local def = reg.items[id]
  if not def or def.deleted_at then
    return false, "no such item"
  end
  if type(newName) ~= "string" or not newName:match(M.NAME_PATTERN) or #newName > M.NAME_MAX then
    return false, "invalid name"
  end
  if nameTaken(reg, def.owner, newName, id) then
    return false, "name already used by this owner"
  end
  def.name = newName
  def.schema_rev = (def.schema_rev or 0) + 1
  reg.schema_rev = reg.schema_rev + 1
  return true
end

--- Tombstones an item. The order slot stays occupied forever so a later
--- item can never inherit its Composer variable id and silently take over
--- existing programming.
function M.deleteDefinition(reg, id, now)
  local def = reg.items[id]
  if not def or def.deleted_at then
    return false, "no such item"
  end
  def.deleted_at = now or 0
  def.schema_rev = (def.schema_rev or 0) + 1
  reg.schema_rev = reg.schema_rev + 1
  return true
end

--- Applies the peer's published definitions as read-only mirrors. Returns
--- the lists of added, changed and removed ids so the driver can create,
--- rename or tombstone the native variables accordingly.
--- Ownership is checked: a definition claiming to be owned by *this*
--- endpoint, arriving from the peer, is rejected.
function M.applyPeerSchema(reg, selfEndpoint, peerEndpoint, defs, now)
  local added, changed, removed, rejected = {}, {}, {}, {}
  local seen = {}
  for _, def in ipairs(defs or {}) do
    local ok, err = M.validateDefinition(def)
    if not ok then
      rejected[#rejected + 1] = { id = def and def.id, reason = err }
    elseif def.owner ~= peerEndpoint or def.owner == selfEndpoint then
      rejected[#rejected + 1] = { id = def.id, reason = "owner mismatch" }
    elseif def.export_enabled == false then
      -- Not shared with us: treat as absent.
    else
      seen[def.id] = true
      local existing = reg.items[def.id]
      if not existing then
        local copy = {}
        for k, v in pairs(def) do
          copy[k] = v
        end
        copy.mirror = true
        copy.order = #reg.order + 1
        copy.created_at = now
        reg.order[copy.order] = copy.id
        reg.items[copy.id] = copy
        added[#added + 1] = copy.id
      else
        if existing.deleted_at then
          -- A deleted mirror that re-appears with the same id is the same
          -- item (the owner never reuses ids); revive it in place.
          existing.deleted_at = nil
          added[#added + 1] = existing.id
        end
        local diff = existing.schema_rev ~= def.schema_rev or existing.name ~= def.name or existing.type ~= def.type
        if diff then
          if existing.type ~= def.type then
            rejected[#rejected + 1] = { id = def.id, reason = "type changed on owner; mirror kept at old type" }
          else
            for k, v in pairs(def) do
              existing[k] = v
            end
            existing.mirror = true
            changed[#changed + 1] = existing.id
          end
        end
      end
    end
  end
  for id, def in pairs(reg.items) do
    if def.mirror and def.owner == peerEndpoint and not def.deleted_at and not seen[id] then
      def.deleted_at = now
      removed[#removed + 1] = id
    end
  end
  if #added + #changed + #removed > 0 then
    reg.schema_rev = reg.schema_rev + 1
  end
  return { added = added, changed = changed, removed = removed, rejected = rejected }
end

--- The exportable view of this endpoint's own definitions (what goes to the
--- relay as `schema`). Mirrors and non-exported items are excluded.
function M.ownedExport(reg, selfEndpoint)
  local out = {}
  for _, def in ipairs(M.registryItems(reg)) do
    if def.owner == selfEndpoint and not def.mirror and def.export_enabled ~= false then
      out[#out + 1] = def
    end
  end
  return out
end

--- Counts, for the status properties: active user items by role.
function M.counts(reg, selfEndpoint)
  local owned, mirrored = 0, 0
  for _, def in ipairs(M.registryItems(reg)) do
    if def.owner == selfEndpoint and not def.mirror then
      owned = owned + 1
    elseif def.mirror then
      mirrored = mirrored + 1
    end
  end
  return owned, mirrored
end

return M
