--- VenueFlow: what Remote Management may not change (pure).
---
--- Owner decision: device mapping and device commands are ON-SITE ONLY. A
--- dealer working remotely (smartbuildos.io, through the Agent, Core:remote)
--- may change everything else a remote draft could always change: names,
--- scenes, rules, schedules, layout, groups, volume limits and presets, staff
--- profiles, channel labels, favourites, a source's control groups. A remote
--- change that would alter WHICH Control4 room or device something is mapped
--- to, or WHICH Control4 command something sends, is refused as a whole and
--- nothing is stored. The installer on site (Installer Studio) is not
--- affected by anything here.
---
--- `changes(before, after)` lists what differs in mapping or commands, in
--- words an installer reads; `detail(changes, verb)` turns that list into the
--- refusal text, bounded for the Agent.
---
--- WHAT IS MAPPING (M.KINDS and the program walk below), and why:
---   display     c4RoomId, c4DeviceId           the room and device addressed
---               power, feedback                room / device / none: which of
---                                              the two ids power goes to and
---                                              whether the room is listened to
---               route.strategy, route.command  room or a custom command; the
---                                              command's deviceId, name and
---                                              params (any other route key too)
---   source      c4DeviceId                     the box routed and keyed
---   audio zone  c4RoomId, feedback             the room addressed and heard
---   lighting    each preset's deviceId, command, params
---   shade       deviceId
---   rules and scenes: any node anywhere in a rule or scene (trigger,
---               condition, step, at any depth) that carries a raw Control4
---               id (deviceId, c4DeviceId, c4RoomId), with its variable,
---               command and params. Today that is the c4_variable trigger
---               (the driver LISTENS to that device) and the c4_variable
---               condition (the driver READS it). A Control4 id is a mapping
---               whichever way it is used, so these are on-site only too.
---               They are compared as a SET over the whole configuration: a
---               remote draft may stop listening, or reuse a device variable
---               the configuration already reads in another rule, but may not
---               reach a device/variable (or command) the configuration did
---               not already hold. The comparison value of a condition (cmp,
---               value) is logic, not mapping, and stays remote-editable.
---
--- WHAT IS NOT MAPPING (left remote-editable on purpose):
---   source kind, controls, tuneEnter  Keys go ONLY to the source's own
---               c4DeviceId (sourcecontrol.lua, Engine:_source) and only as
---               commands of the closed vocabulary (SourceControl.KEYS,
---               NUMBER_n, DASH, ENTER). Which groups are switched on, and
---               whether ENTER follows the digits, chooses among commands
---               already allowed for a device already mapped on site: it can
---               neither redirect a key to another device nor add a command
---               outside the vocabulary. smartbuildos.io's Sources editor
---               edits exactly these. (`kind` only seeds `controls` when they
---               are absent; it addresses nothing.)
---   source favourites and channel label  dialled through the same closed
---               keypad vocabulary, to the same device.
---   audio zone min/max/default volume, presets, `can`  levels and which of
---               the fixed room commands staff see, to the same mapped room.
---   shade openLevel / closedLevel  the level of the one fixed command
---               (SET_LEVEL_TARGET) to the mapped shade, like a volume preset.
---   source name  note: a custom route may send "${sourceName}" as a
---               parameter. The installer chose that template on site; the
---               device and command stay fixed. Renaming stays allowed.
---   display kind, sources, defaultSourceId, audioZoneId, layout; groups;
---               rooms; scenes' and rules' steps (they name VenueFlow ids, not
---               Control4 ids; a lighting step picks a preset whose command
---               was set on site); variables and variableId (VenueFlow's own);
---               c4_event / external trigger names (events this driver
---               raises, not Control4 ids); stations (a LAN address and a
---               profile: access, not hardware); profiles; venue.
---
--- THE BASE OF COMPARISON (decided by the caller, core.lua REMOTE):
---   save_draft  A remote save replaces the DRAFT. When a draft exists it may
---               hold the installer's own unpublished mapping work: the
---               proposed mapping must equal the DRAFT's, entity by entity, so
---               the dealer can save other fields on top of that work and can
---               neither undo nor alter it. Without a draft, the PUBLISHED
---               configuration's; without either, an empty one. (A remote
---               save already names the draft revision it was edited from.)
---   publish     Making a mapping live is on-site work too: a remote publish
---               is refused when the draft's mapping differs from what is
---               live, even if the installer put it in the draft on site.
---   rollback    Likewise the target version's mapping against what is live.
---
--- ADDED, REMOVED, MOVED:
---   Compared by id, never by position: reordering a list is not a change.
---   An entity ADDED remotely is allowed only UNMAPPED: its mapping fields
---   must be exactly those of a blank entity of its kind after normalisation
---   (no room, no device, no command, default strategies), so it sends
---   nothing until the installer maps it on site. Refusing new entities
---   outright would stop a dealer from sketching a venue; allowing a mapped
---   one would put a command live nobody on site chose.
---   An entity REMOVED remotely is allowed: removing a mapping sends nothing.
---   Removing and re-adding the same id with another mapping in one save is
---   caught (by id it is the same entity with a changed mapping); re-adding a
---   mapping under a NEW id is caught as a mapped new entity. A lighting
---   preset is keyed by its lighting id AND its own id, so moving a preset to
---   another lighting control is a new, mapped preset.
---   Entries are found with pairs(), not ipairs(): a JSON list with a null in
---   it decodes with a hole, and an entry past the hole must not hide.
---
--- Comparison is on Schema.normalize'd copies (after Schema.migrate), so key
--- order, an absent field versus its default, and an empty table versus an
--- absent one never count as a change.

local U = require("venueflow.util")
local Schema = require("venueflow.schema")

local M = {}

local function routeOf(e)
  return type(e.route) == "table" and e.route or nil
end

--- Per entity kind: where it lives and which fields are mapping. `get`
--- reads a field when it is not a plain key.
M.KINDS = {
  {
    list = "displays",
    label = "Display",
    fields = {
      { key = "c4RoomId", label = "room" },
      { key = "c4DeviceId", label = "device" },
      { key = "power", label = "power control" },
      { key = "feedback", label = "feedback" },
      {
        key = "route.strategy",
        label = "route type",
        get = function(e)
          local r = routeOf(e)
          return r and r.strategy
        end,
      },
      {
        -- The command (deviceId, name, params) and anything else a route holds.
        key = "route.command",
        label = "route command",
        get = function(e)
          local r = routeOf(e)
          if r == nil then
            return nil
          end
          local rest = U.copy(r)
          rest.strategy = nil
          return rest
        end,
      },
    },
  },
  { list = "sources", label = "Source", fields = { { key = "c4DeviceId", label = "device" } } },
  {
    list = "audioZones",
    label = "Audio zone",
    fields = { { key = "c4RoomId", label = "room" }, { key = "feedback", label = "feedback" } },
  },
  {
    list = "lighting",
    within = "presets",
    label = "Lighting preset",
    fields = {
      { key = "deviceId", label = "device" },
      { key = "command", label = "command" },
      { key = "params", label = "command parameters" },
    },
  },
  { list = "shades", label = "Shade", fields = { { key = "deviceId", label = "device" } } },
}

--- The lists whose entities are walked for raw Control4 ids at any depth.
M.PROGRAM_LISTS = { { list = "rules", label = "Rule" }, { list = "scenes", label = "Scene" } }
--- Keys that make a node in a rule or scene a Control4 reference, and the
--- keys that, beside it, say what is read or sent.
M.RAW_ID_KEYS = { "deviceId", "c4DeviceId", "c4RoomId" }
M.RAW_WITH_KEYS = { "variable", "command", "name", "params" }

--- Every field name this module compares, for the guard test.
function M.fieldNames()
  local out = {}
  for _, kind in ipairs(M.KINDS) do
    for _, f in ipairs(kind.fields) do
      out[f.key:match("^[^.]+")] = true
      out[f.key:match("[^.]+$")] = true
    end
  end
  for _, k in ipairs(M.RAW_ID_KEYS) do
    out[k] = true
  end
  for _, k in ipairs(M.RAW_WITH_KEYS) do
    out[k] = true
  end
  return out
end

--- Names a field guard would flag that are deliberately not mapping, and why.
M.NOT_MAPPING = {
  variables = "VenueFlow's own variables (a list in the configuration), not Control4 ones",
  variableId = "a VenueFlow variable's id, not a Control4 id",
  sourceControl = "a staff permission flag",
  VARIABLE_TYPES = "the list of VenueFlow variable types",
  -- Names of runtime functions and runtime state, not configuration fields:
  c4Variable = "the rule engine's reader of a condition's Control4 variable",
  setVariable = "the rule engine's writer of a VenueFlow variable",
  deviceCommand = "the adapter's send",
  devicePower = "the adapter's power send",
  deviceOnline = "the adapter's link-state read",
  sourceForDevice = "a lookup from a room's reported device to a source",
  videoDevice = "a room's reported video device (feedback, read only)",
  audioDevice = "a room's reported audio device (feedback, read only)",
}

-- ─── Comparison ─────────────────────────────────────────────────────────────

--- Empty tables read as absent, recursively, so {} and nil compare equal.
local function trimmed(v)
  if type(v) ~= "table" then
    return v
  end
  local out, any = {}, false
  for k, x in pairs(v) do
    local t = trimmed(x)
    if t ~= nil then
      out[k] = t
      any = true
    end
  end
  return any and out or nil
end

local function same(a, b)
  a, b = trimmed(a), trimmed(b)
  if a == nil or b == nil then
    return a == nil and b == nil
  end
  return U.equal(a, b)
end

--- One text for a value, keys sorted (for the set of raw references).
local function canon(v)
  if type(v) == "table" then
    local keys = U.sortedKeys(v)
    local parts = {}
    for _, k in ipairs(keys) do
      parts[#parts + 1] = string.format("%q", tostring(k)) .. "=" .. canon(v[k])
    end
    return "{" .. table.concat(parts, ",") .. "}"
  elseif type(v) == "string" then
    return string.format("%q", v)
  end
  return tostring(v)
end

--- Every table value of `t`, by every key (pairs; numeric keys first and in
--- order, then the others sorted, so lists read in their own order).
local function entries(t)
  local out = {}
  if type(t) ~= "table" then
    return out
  end
  local keys = {}
  for k in pairs(t) do
    keys[#keys + 1] = k
  end
  table.sort(keys, function(x, y)
    local nx, ny = type(x) == "number", type(y) == "number"
    if nx ~= ny then
      return nx
    end
    if nx then
      return x < y
    end
    return tostring(x) < tostring(y)
  end)
  for _, k in ipairs(keys) do
    if type(t[k]) == "table" then
      out[#out + 1] = t[k]
    end
  end
  return out
end

local function prepared(config)
  if type(config) ~= "table" then
    return Schema.normalize({})
  end
  local migrated = Schema.migrate(config)
  return Schema.normalize(migrated or config)
end

local function idOf(e)
  return type(e.id) == "string" and e.id or nil
end

local function nameOf(e)
  if type(e.name) == "string" and e.name ~= "" then
    return (e.name:gsub("%c", " "))
  end
  return idOf(e) or "(no id)"
end

--- calls fn(key, entity, name) for every entity of `kind` in `config`; key is
--- nil when the entity has no usable id.
local function eachEntity(config, kind, fn)
  for _, e in ipairs(entries(config[kind.list])) do
    if kind.within == nil then
      fn(idOf(e), e, nameOf(e))
    else
      for _, p in ipairs(entries(e[kind.within])) do
        local key = (idOf(e) and idOf(p)) and (idOf(e) .. "\0" .. idOf(p)) or nil
        fn(key, p, nameOf(p))
      end
    end
  end
end

local function fieldValue(entity, field)
  if field.get then
    return field.get(entity)
  end
  return entity[field.key]
end

--- What a new entity of this kind holds when nobody has mapped it.
local function blankOf(kind)
  if kind.within ~= nil then
    return {}
  end
  return Schema.normalize({ [kind.list] = { {} } })[kind.list][1]
end

--- set[canon] = "Rule 'x' Control4 variable" for every raw Control4 reference.
local function rawReferences(config)
  local out, order = {}, {}
  for _, spec in ipairs(M.PROGRAM_LISTS) do
    for _, item in ipairs(entries(config[spec.list])) do
      local function walk(node, depth)
        if type(node) ~= "table" or depth > 40 then
          return
        end
        local ref
        for _, k in ipairs(M.RAW_ID_KEYS) do
          if node[k] ~= nil then
            ref = ref or {}
            ref[k] = node[k]
          end
        end
        if ref ~= nil then
          for _, k in ipairs(M.RAW_WITH_KEYS) do
            ref[k] = node[k]
          end
          local key = canon(ref)
          if out[key] == nil then
            out[key] = {
              label = spec.label,
              name = nameOf(item),
              rest = node.variable ~= nil and " Control4 variable" or " Control4 device",
            }
            order[#order + 1] = key
          end
        end
        for _, k in ipairs(U.sortedKeys(node)) do
          walk(node[k], depth + 1)
        end
      end
      walk(item, 0)
    end
  end
  return out, order
end

--- The mapping and command differences between two configurations, as a
--- list of { kind, id?, name, field, new?, label, rest } (read them with
--- M.text); empty when there are none.
--- `before` is the trusted base (see the header), `after` the proposal.
function M.changes(before, after)
  local a, b = prepared(before), prepared(after)
  local out = {}
  for _, kind in ipairs(M.KINDS) do
    local base = {}
    eachEntity(a, kind, function(key, e)
      if key ~= nil and base[key] == nil then
        base[key] = e
      end
    end)
    local blank = blankOf(kind)
    eachEntity(b, kind, function(key, e, name)
      local was = key and base[key] or nil
      for _, field in ipairs(kind.fields) do
        local old = fieldValue(was or blank, field)
        if not same(old, fieldValue(e, field)) then
          out[#out + 1] = {
            kind = kind.label,
            id = key,
            name = name,
            field = field.key,
            new = was == nil,
            label = kind.label,
            rest = (was == nil and " (new)" or "") .. " " .. field.label,
          }
        end
      end
    end)
  end
  local known = rawReferences(a)
  local proposed, order = rawReferences(b)
  for _, key in ipairs(order) do
    if known[key] == nil then
      local ref = proposed[key]
      out[#out + 1] = { kind = ref.label, name = ref.name, field = "c4", label = ref.label, rest = ref.rest }
    end
  end
  return out
end

-- ─── The refusal ────────────────────────────────────────────────────────────

--- The Agent keeps 400 bytes of a result's detail, and the driver puts
--- "VF_ONSITE_ONLY: " (16) in front of it.
M.DETAIL_MAX = 380
M.NAME_MAX = 32

M.WORDING = {
  save = {
    "Remote Management cannot change device mapping or device commands: ",
    ". Change these on site in Installer Studio.",
  },
  publish = {
    "Remote Management cannot put device mapping or device commands live: ",
    ". Publish these on site in Installer Studio.",
  },
  rollback = {
    "Remote Management cannot roll back device mapping or device commands: ",
    ". Roll back on site in Installer Studio.",
  },
}

--- Cuts a name to NAME_MAX bytes without splitting a UTF-8 character.
local function shortName(text)
  if #text <= M.NAME_MAX then
    return text
  end
  local cut = M.NAME_MAX - 3
  while cut > 0 and text:byte(cut + 1) ~= nil and text:byte(cut + 1) >= 0x80 and text:byte(cut + 1) < 0xC0 do
    cut = cut - 1
  end
  return text:sub(1, cut) .. "..."
end

--- One change in words: "Display 'TV 03' room". `short` cuts a long name.
function M.text(change, short)
  local name = short and shortName(change.name) or change.name
  return change.label .. " '" .. name .. "'" .. change.rest
end

local function itemText(change)
  return M.text(change, true)
end

--- The refusal text: verb = "save" | "publish" | "rollback". At most
--- DETAIL_MAX bytes; items that do not fit are counted ("and 3 more").
function M.detail(changes, verb)
  local words = M.WORDING[verb] or M.WORDING.save
  local budget = M.DETAIL_MAX - #words[1] - #words[2]
  local items, used = {}, 0
  for i, change in ipairs(changes) do
    local text = itemText(change)
    local sep = #items > 0 and 2 or 0
    local remaining = #changes - i
    local reserve = remaining > 0 and #("; and " .. remaining .. " more") or 0
    if used + sep + #text + reserve > budget then
      local more = #changes - #items
      items[#items + 1] = (#items > 0 and "and " or "") .. more .. " more"
      break
    end
    items[#items + 1] = text
    used = used + sep + #text
  end
  return words[1] .. table.concat(items, "; ") .. words[2]
end

--- Short items for diagnostics (each well under the log's 200-character cut).
function M.items(changes, max)
  local out = {}
  for i, change in ipairs(changes) do
    if i > (max or 20) then
      out[#out + 1] = (#changes - (max or 20)) .. " more"
      break
    end
    out[#out + 1] = itemText(change)
  end
  return out
end

return M
