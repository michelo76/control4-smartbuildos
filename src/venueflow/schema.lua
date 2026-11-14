--- VenueFlow: the configuration document, its defaults, validation and
--- migration. Pure: no Control4 calls.
---
--- A configuration is one plain table (see docs/smartbuildos-venueflow/
--- DATA_MODEL.md). Every entity has a stable `id`; names are free text.
--- Layout (where an icon sits on a floor) lives beside the mapping (which
--- Control4 room a display is) in the same entity but in its own `layout`
--- field, so moving or hiding an icon can never change a mapping.
---
--- validate() returns ISSUES, never throws:
---   severity "error"   must be fixed before publishing
---   severity "warning" must be fixed OR acknowledged before publishing

local U = require("venueflow.util")
local Rules = require("venueflow.rules")

local M = {}

M.SCHEMA_VERSION = 1

M.VENUE_TYPES = {
  "sports_bar",
  "restaurant",
  "corporate_office",
  "conference_center",
  "hotel",
  "fitness_center",
  "retail",
  "custom",
}
M.INTERFACES = { "floorplan", "command", "room", "manager" }
M.SOURCE_KINDS = { "cable", "satellite", "streaming", "signage", "laptop", "conference", "music", "camera", "other" }
M.DISPLAY_KINDS = { "tv", "projector", "videowall" }
M.ROUTE_STRATEGIES = { "room", "command", "none" }
M.POWER_STRATEGIES = { "room", "device", "none" }
M.FEEDBACK = { "room", "none" }
M.ROLES = { "installer", "owner", "manager", "bartender", "host", "conference_staff", "restricted" }
M.VARIABLE_TYPES = { "bool", "number", "string" }

M.ROOM_BUTTONS_MAX = 6

M.LIMITS = {
  floors = 12,
  areas = 64,
  sources = 64,
  displays = 200,
  audioZones = 48,
  groups = 64,
  lighting = 48,
  shades = 48,
  rooms = 48,
  scenes = 64,
  rules = 96,
  variables = 48,
  profiles = 24,
  stations = 48,
  labels = 200,
  sceneButtons = 64,
  name = 80,
}

local PERMISSION_FLAGS =
  { "routeVideo", "power", "audio", "lighting", "shades", "scenes", "venueStatus", "allOff", "viewAlerts" }
local PERMISSION_SCOPES = { "floors", "areas", "sources", "zones", "sceneIds" }
M.PERMISSION_FLAGS = PERMISSION_FLAGS
M.PERMISSION_SCOPES = PERMISSION_SCOPES

local function set(list)
  local s = {}
  for _, v in ipairs(list) do
    s[v] = true
  end
  return s
end

local VENUE_TYPE_SET = set(M.VENUE_TYPES)
local INTERFACE_SET = set(M.INTERFACES)
local SOURCE_KIND_SET = set(M.SOURCE_KINDS)
local DISPLAY_KIND_SET = set(M.DISPLAY_KINDS)
local ROUTE_SET = set(M.ROUTE_STRATEGIES)
local POWER_SET = set(M.POWER_STRATEGIES)
local FEEDBACK_SET = set(M.FEEDBACK)
local ROLE_SET = set(M.ROLES)
local VARTYPE_SET = set(M.VARIABLE_TYPES)

-- ─── Defaults ───────────────────────────────────────────────────────────────

function M.empty()
  return {
    schema = M.SCHEMA_VERSION,
    venue = {
      name = "",
      type = "custom",
      timezone = "",
      defaultInterface = "floorplan",
      subsystems = { video = true, audio = true, lighting = false, shades = false },
    },
    floors = {},
    areas = {},
    sources = {},
    displays = {},
    audioZones = {},
    groups = {},
    lighting = {},
    shades = {},
    rooms = {},
    scenes = {},
    rules = {},
    variables = {},
    profiles = {},
    layout = { labels = {}, sceneButtons = {} },
  }
end

local LIST_FIELDS = {
  "floors",
  "areas",
  "sources",
  "displays",
  "audioZones",
  "groups",
  "lighting",
  "shades",
  "rooms",
  "scenes",
  "rules",
  "variables",
  "profiles",
  "stations",
}
M.LIST_FIELDS = LIST_FIELDS

local function default(t, key, value)
  if t[key] == nil then
    t[key] = value
  end
end

function M.fullPermissions()
  local p = {}
  for _, scope in ipairs(PERMISSION_SCOPES) do
    p[scope] = "all"
  end
  for _, flag in ipairs(PERMISSION_FLAGS) do
    p[flag] = true
  end
  return p
end

--- Fills every optional field, in a copy. Unknown fields are kept (a newer
--- Studio's extra data survives an older driver).
function M.normalize(config)
  local c = U.copy(type(config) == "table" and config or {})
  local e = M.empty()
  default(c, "schema", M.SCHEMA_VERSION)
  if type(c.venue) ~= "table" then
    c.venue = {}
  end
  for k, v in pairs(e.venue) do
    default(c.venue, k, U.copy(v))
  end
  if type(c.venue.subsystems) ~= "table" then
    c.venue.subsystems = U.copy(e.venue.subsystems)
  end
  for k, v in pairs(e.venue.subsystems) do
    default(c.venue.subsystems, k, v)
  end
  for _, field in ipairs(LIST_FIELDS) do
    if type(c[field]) ~= "table" then
      c[field] = {}
    end
  end
  if type(c.layout) ~= "table" then
    c.layout = {}
  end
  if type(c.layout.labels) ~= "table" then
    c.layout.labels = {}
  end
  if type(c.layout.sceneButtons) ~= "table" then
    c.layout.sceneButtons = {}
  end
  for _, f in ipairs(c.floors) do
    if type(f) == "table" then
      default(f, "width", 1200)
      default(f, "height", 800)
      default(f, "grid", 20)
    end
  end
  for _, s in ipairs(c.sources) do
    if type(s) == "table" then
      default(s, "kind", "other")
      default(s, "video", true)
      default(s, "audio", true)
      default(s, "enabled", true)
    end
  end
  for _, d in ipairs(c.displays) do
    if type(d) == "table" then
      default(d, "kind", "tv")
      default(d, "sources", "all")
      default(d, "power", "room")
      default(d, "feedback", "room")
      if type(d.route) ~= "table" then
        d.route = { strategy = "room" }
      end
      default(d.route, "strategy", "room")
    end
  end
  for _, z in ipairs(c.audioZones) do
    if type(z) == "table" then
      default(z, "sources", "all")
      default(z, "minVolume", 0)
      default(z, "maxVolume", 100)
      default(z, "presets", {})
      default(z, "feedback", "room")
      if type(z.can) ~= "table" then
        z.can = {}
      end
      for _, k in ipairs({ "volume", "mute", "source", "power" }) do
        default(z.can, k, true)
      end
    end
  end
  for _, g in ipairs(c.groups) do
    if type(g) == "table" then
      default(g, "displayIds", {})
    end
  end
  for _, l in ipairs(c.lighting) do
    if type(l) == "table" then
      default(l, "presets", {})
    end
  end
  for _, r in ipairs(c.rooms) do
    if type(r) == "table" then
      default(r, "buttons", {})
      default(r, "shadeIds", {})
      default(r, "showSources", false)
    end
  end
  for _, s in ipairs(c.scenes) do
    if type(s) == "table" then
      default(s, "confirm", false)
      if type(s.program) ~= "table" then
        s.program = { steps = {} }
      end
      default(s.program, "steps", {})
    end
  end
  for _, r in ipairs(c.rules) do
    if type(r) == "table" then
      default(r, "enabled", true)
      if type(r.trigger) ~= "table" then
        r.trigger = { type = "manual" }
      end
      if type(r.program) ~= "table" then
        r.program = { steps = {} }
      end
      default(r.program, "steps", {})
    end
  end
  for _, p in ipairs(c.profiles) do
    if type(p) == "table" then
      default(p, "role", "restricted")
      default(p, "interfaces", { "command" })
      if type(p.permissions) ~= "table" then
        p.permissions = {}
      end
      for _, scope in ipairs(PERMISSION_SCOPES) do
        default(p.permissions, scope, "all")
      end
      for _, flag in ipairs(PERMISSION_FLAGS) do
        default(p.permissions, flag, false)
      end
      default(p, "defaultInterface", p.interfaces[1] or "command")
    end
  end
  return c
end

-- ─── Migration ──────────────────────────────────────────────────────────────

--- MIGRATIONS[n] turns a schema-n document into schema n+1. Version 1 is the
--- first released shape, so the table is empty today; the mechanism is tested
--- with an injected table.
M.MIGRATIONS = {}

--- Returns the migrated document, or nil + reason. A document NEWER than this
--- driver is refused rather than guessed at.
function M.migrate(config, migrations, target)
  migrations = migrations or M.MIGRATIONS
  target = target or M.SCHEMA_VERSION
  if type(config) ~= "table" then
    return nil, "configuration is not a table"
  end
  local c = U.copy(config)
  local version = tonumber(c.schema) or 0
  if version > target then
    return nil, string.format("configuration schema %d is newer than this driver (%d)", version, target)
  end
  while version < target do
    local step = migrations[version]
    if type(step) ~= "function" then
      return nil, string.format("no migration from schema %d", version)
    end
    local ok, result = pcall(step, c)
    if not ok or type(result) ~= "table" then
      return nil, string.format("migration from schema %d failed: %s", version, tostring(result))
    end
    c = result
    version = version + 1
    c.schema = version
  end
  return c
end

-- ─── Validation ─────────────────────────────────────────────────────────────

--- `related` names a second entity the issue is also about (the other display
--- in a shared Control4 room), so the Studio shows it on both.
local function issue(issues, severity, code, path, message, entity, related)
  issues[#issues + 1] = {
    id = code .. ":" .. path,
    severity = severity,
    code = code,
    path = path,
    message = message,
    entity = entity,
    related = related,
  }
end

--- Issue entities use machine kinds (what the Studio looks issues up by).
local ENTITY_KIND = {
  Floor = "floor",
  Area = "area",
  Source = "source",
  Display = "display",
  ["Audio zone"] = "audioZone",
  ["Display group"] = "group",
  ["Lighting control"] = "lighting",
  Shade = "shade",
  ["Room panel"] = "room",
  Scene = "scene",
  Rule = "rule",
  Variable = "variable",
  ["Staff profile"] = "profile",
  Station = "station",
}

local function checkName(issues, path, item, kind)
  local name = item.name
  if type(name) ~= "string" or U.trim(name) == "" then
    issue(
      issues,
      "error",
      "NAME_MISSING",
      path .. ".name",
      kind .. " needs a name.",
      { kind = ENTITY_KIND[kind] or kind, id = item.id }
    )
  elseif #name > M.LIMITS.name then
    issue(
      issues,
      "error",
      "NAME_TOO_LONG",
      path .. ".name",
      kind .. " name is too long.",
      { kind = ENTITY_KIND[kind] or kind, id = item.id }
    )
  end
end

--- Checks ids of one list: present, well formed, unique. Returns the index.
local function indexList(issues, config, field, kind)
  local index = {}
  local list = config[field]
  if not U.isList(list) then
    issue(issues, "error", "NOT_A_LIST", field, field .. " must be a list.")
    return index
  end
  if M.LIMITS[field] and #list > M.LIMITS[field] then
    issue(
      issues,
      "error",
      "TOO_MANY",
      field,
      string.format("Too many %s (%d, the limit is %d).", field, #list, M.LIMITS[field])
    )
  end
  for i, item in ipairs(list) do
    local path = string.format("%s[%d]", field, i)
    if type(item) ~= "table" then
      issue(issues, "error", "NOT_AN_OBJECT", path, "Entry is not an object.")
    elseif not U.isId(item.id) then
      issue(issues, "error", "ID_INVALID", path .. ".id", kind .. " has a missing or malformed id.")
    elseif index[item.id] ~= nil then
      issue(issues, "error", "ID_DUPLICATE", path .. ".id", kind .. " id '" .. item.id .. "' is used twice.")
    else
      index[item.id] = item
      checkName(issues, path, item, kind)
    end
  end
  return index
end

local function checkRef(issues, path, value, index, kind, what, entity, optional)
  if value == nil then
    if not optional then
      issue(issues, "error", "REF_MISSING", path, what .. " is not set.", entity)
    end
    return false
  end
  if index[value] == nil then
    issue(issues, "error", "REF_UNKNOWN", path, what .. " refers to a " .. kind .. " that does not exist.", entity)
    return false
  end
  return true
end

local function checkIdList(issues, path, list, index, kind, what, entity)
  if list == "all" then
    return
  end
  if not U.isList(list) then
    issue(issues, "error", "NOT_A_LIST", path, what .. ' must be "all" or a list.', entity)
    return
  end
  for i, id in ipairs(list) do
    if index[id] == nil then
      issue(
        issues,
        "error",
        "REF_UNKNOWN",
        string.format("%s[%d]", path, i),
        what .. " refers to a " .. kind .. " that does not exist.",
        entity
      )
    end
  end
end

local function isC4Id(v)
  return type(v) == "number" and v > 0 and v == math.floor(v)
end

local function checkLayout(issues, path, layout, entity)
  if layout == nil then
    return
  end
  if type(layout) ~= "table" then
    issue(issues, "error", "LAYOUT_INVALID", path, "Layout must be an object.", entity)
    return
  end
  for _, k in ipairs({ "x", "y", "w", "h", "rot" }) do
    if layout[k] ~= nil and type(layout[k]) ~= "number" then
      issue(issues, "error", "LAYOUT_INVALID", path .. "." .. k, "Layout " .. k .. " must be a number.", entity)
    end
  end
end

--- The lookup tables program validation and the engines share.
function M.index(config)
  return {
    floors = U.indexById(config.floors),
    areas = U.indexById(config.areas),
    sources = U.indexById(config.sources),
    displays = U.indexById(config.displays),
    zones = U.indexById(config.audioZones),
    groups = U.indexById(config.groups),
    lighting = U.indexById(config.lighting),
    shades = U.indexById(config.shades),
    rooms = U.indexById(config.rooms),
    scenes = U.indexById(config.scenes),
    rules = U.indexById(config.rules),
    variables = U.indexById(config.variables),
    profiles = U.indexById(config.profiles),
    stations = U.indexById(config.stations),
  }
end

--- Validates a NORMALIZED configuration. Returns a list of issues.
function M.validate(config)
  local issues = {}
  if type(config) ~= "table" then
    issue(issues, "error", "NOT_AN_OBJECT", "", "The configuration is not an object.")
    return issues
  end
  if tonumber(config.schema) ~= M.SCHEMA_VERSION then
    issue(issues, "error", "SCHEMA_VERSION", "schema", "Unsupported configuration schema version.")
  end

  local venue = config.venue or {}
  if type(venue.name) ~= "string" or U.trim(venue.name) == "" then
    issue(issues, "error", "NAME_MISSING", "venue.name", "The venue needs a name.")
  elseif #venue.name > M.LIMITS.name then
    issue(issues, "error", "NAME_TOO_LONG", "venue.name", "The venue name is too long.")
  end
  if not VENUE_TYPE_SET[venue.type] then
    issue(issues, "error", "ENUM", "venue.type", "Unknown venue type.")
  end
  if not INTERFACE_SET[venue.defaultInterface] then
    issue(issues, "error", "ENUM", "venue.defaultInterface", "Unknown default interface.")
  end

  local floors = indexList(issues, config, "floors", "Floor")
  local areas = indexList(issues, config, "areas", "Area")
  local sources = indexList(issues, config, "sources", "Source")
  local displays = indexList(issues, config, "displays", "Display")
  local zones = indexList(issues, config, "audioZones", "Audio zone")
  local groups = indexList(issues, config, "groups", "Display group")
  local lighting = indexList(issues, config, "lighting", "Lighting control")
  local shades = indexList(issues, config, "shades", "Shade")
  local rooms = indexList(issues, config, "rooms", "Room panel")
  local scenes = indexList(issues, config, "scenes", "Scene")
  local rules = indexList(issues, config, "rules", "Rule")
  local variables = indexList(issues, config, "variables", "Variable")
  local profiles = indexList(issues, config, "profiles", "Staff profile")

  if #U.list(config.floors) == 0 then
    issue(issues, "error", "NO_FLOOR", "floors", "Add at least one floor.")
  end

  for i, f in ipairs(U.list(config.floors)) do
    if type(f) == "table" then
      local path = string.format("floors[%d]", i)
      for _, k in ipairs({ "width", "height" }) do
        if type(f[k]) ~= "number" or f[k] < 100 or f[k] > 20000 then
          issue(issues, "error", "RANGE", path .. "." .. k, "Floor " .. k .. " must be between 100 and 20000.")
        end
      end
      if f.image ~= nil and (type(f.image) ~= "table" or type(f.image.key) ~= "string") then
        issue(issues, "error", "IMAGE_INVALID", path .. ".image", "Floor plan image reference is malformed.")
      end
    end
  end

  for i, a in ipairs(U.list(config.areas)) do
    if type(a) == "table" then
      local path = string.format("areas[%d]", i)
      checkRef(issues, path .. ".floorId", a.floorId, floors, "floor", "Area floor", { kind = "area", id = a.id })
      checkLayout(issues, path .. ".layout", a.layout, { kind = "area", id = a.id })
    end
  end

  -- Sources.
  local sourceDevice = {}
  for i, s in ipairs(U.list(config.sources)) do
    if type(s) == "table" then
      local path = string.format("sources[%d]", i)
      local ent = { kind = "source", id = s.id }
      if not SOURCE_KIND_SET[s.kind] then
        issue(issues, "error", "ENUM", path .. ".kind", "Unknown source kind.", ent)
      end
      if s.c4DeviceId == nil then
        issue(
          issues,
          "warning",
          "SOURCE_UNMAPPED",
          path .. ".c4DeviceId",
          "Source '" .. tostring(s.name) .. "' is not mapped to a Control4 device; it cannot be routed.",
          ent
        )
      elseif not isC4Id(s.c4DeviceId) then
        issue(issues, "error", "C4_ID_INVALID", path .. ".c4DeviceId", "Control4 device id must be a number.", ent)
      else
        if sourceDevice[s.c4DeviceId] ~= nil then
          issue(
            issues,
            "warning",
            "SOURCE_DEVICE_SHARED",
            path .. ".c4DeviceId",
            "Sources '"
              .. tostring(s.name)
              .. "' and '"
              .. tostring(sourceDevice[s.c4DeviceId])
              .. "' use the same Control4 device.",
            ent
          )
        end
        sourceDevice[s.c4DeviceId] = s.name
      end
      if s.video == false and s.audio == false then
        issue(issues, "error", "SOURCE_NO_MEDIA", path, "A source must carry video, audio or both.", ent)
      end
    end
  end

  -- Audio zones (before displays: displays refer to them).
  local zoneRoom = {}
  for i, z in ipairs(U.list(config.audioZones)) do
    if type(z) == "table" then
      local path = string.format("audioZones[%d]", i)
      local ent = { kind = "audioZone", id = z.id }
      checkRef(issues, path .. ".areaId", z.areaId, areas, "area", "Zone area", ent, true)
      checkIdList(issues, path .. ".sources", z.sources, sources, "source", "Zone source list", ent)
      if z.c4RoomId == nil then
        issue(
          issues,
          "warning",
          "ZONE_UNMAPPED",
          path .. ".c4RoomId",
          "Audio zone '" .. tostring(z.name) .. "' is not mapped to a Control4 room; it cannot be controlled.",
          ent
        )
      elseif not isC4Id(z.c4RoomId) then
        issue(issues, "error", "C4_ID_INVALID", path .. ".c4RoomId", "Control4 room id must be a number.", ent)
      else
        if zoneRoom[z.c4RoomId] ~= nil then
          issue(
            issues,
            "error",
            "ZONE_ROOM_SHARED",
            path .. ".c4RoomId",
            "Audio zones '"
              .. tostring(z.name)
              .. "' and '"
              .. tostring(zoneRoom[z.c4RoomId].name)
              .. "' use the same Control4 room; they would always play the same thing.",
            ent,
            { kind = "audioZone", id = zoneRoom[z.c4RoomId].id }
          )
        end
        zoneRoom[z.c4RoomId] = zoneRoom[z.c4RoomId] or z
      end
      local lo, hi = z.minVolume, z.maxVolume
      if type(lo) ~= "number" or type(hi) ~= "number" or lo < 0 or hi > 100 or lo > hi then
        issue(
          issues,
          "error",
          "RANGE",
          path .. ".maxVolume",
          "Zone volume limits must satisfy 0 <= min <= max <= 100.",
          ent
        )
      end
      if
        z.defaultVolume ~= nil
        and (type(z.defaultVolume) ~= "number" or z.defaultVolume < 0 or z.defaultVolume > 100)
      then
        issue(issues, "error", "RANGE", path .. ".defaultVolume", "Default volume must be between 0 and 100.", ent)
      end
      if not FEEDBACK_SET[z.feedback] then
        issue(issues, "error", "ENUM", path .. ".feedback", "Unknown feedback setting.", ent)
      end
      local presetIds = {}
      for j, p in ipairs(U.list(z.presets)) do
        local pp = string.format("%s.presets[%d]", path, j)
        if type(p) ~= "table" or not U.isId(p.id) or presetIds[p.id] then
          issue(issues, "error", "ID_INVALID", pp .. ".id", "Volume preset has a missing or duplicate id.", ent)
        else
          presetIds[p.id] = true
          if type(p.level) ~= "number" or p.level < 0 or p.level > 100 then
            issue(issues, "error", "RANGE", pp .. ".level", "Preset level must be between 0 and 100.", ent)
          end
        end
      end
      checkLayout(issues, path .. ".layout", z.layout, ent)
    end
  end

  -- Displays.
  local displayRoom = {}
  for i, d in ipairs(U.list(config.displays)) do
    if type(d) == "table" then
      local path = string.format("displays[%d]", i)
      local ent = { kind = "display", id = d.id }
      if not DISPLAY_KIND_SET[d.kind] then
        issue(issues, "error", "ENUM", path .. ".kind", "Unknown display kind.", ent)
      end
      checkRef(issues, path .. ".floorId", d.floorId, floors, "floor", "Display floor", ent)
      if checkRef(issues, path .. ".areaId", d.areaId, areas, "area", "Display area", ent, true) then
        local area = areas[d.areaId]
        if area.floorId ~= nil and d.floorId ~= nil and area.floorId ~= d.floorId then
          issue(
            issues,
            "error",
            "AREA_FLOOR_MISMATCH",
            path .. ".areaId",
            "The display's area is on another floor.",
            ent
          )
        end
      end
      checkIdList(issues, path .. ".sources", d.sources, sources, "source", "Supported source list", ent)
      checkRef(issues, path .. ".audioZoneId", d.audioZoneId, zones, "audio zone", "Display audio zone", ent, true)
      checkRef(
        issues,
        path .. ".defaultSourceId",
        d.defaultSourceId,
        sources,
        "source",
        "Display default source",
        ent,
        true
      )
      local route = type(d.route) == "table" and d.route or {}
      if not ROUTE_SET[route.strategy] then
        issue(issues, "error", "ENUM", path .. ".route.strategy", "Unknown route strategy.", ent)
      end
      if not POWER_SET[d.power] then
        issue(issues, "error", "ENUM", path .. ".power", "Unknown power strategy.", ent)
      end
      if not FEEDBACK_SET[d.feedback] then
        issue(issues, "error", "ENUM", path .. ".feedback", "Unknown feedback setting.", ent)
      end
      if d.c4RoomId ~= nil and not isC4Id(d.c4RoomId) then
        issue(issues, "error", "C4_ID_INVALID", path .. ".c4RoomId", "Control4 room id must be a number.", ent)
      end
      if d.c4DeviceId ~= nil and not isC4Id(d.c4DeviceId) then
        issue(issues, "error", "C4_ID_INVALID", path .. ".c4DeviceId", "Control4 device id must be a number.", ent)
      end
      local needsRoom = route.strategy == "room" or d.power == "room" or d.feedback == "room"
      if needsRoom and d.c4RoomId == nil then
        issue(
          issues,
          "warning",
          "DISPLAY_UNMAPPED",
          path .. ".c4RoomId",
          "Display '" .. tostring(d.name) .. "' is not mapped to a Control4 room; it cannot be routed.",
          ent
        )
      end
      if d.power == "device" and d.c4DeviceId == nil then
        issue(
          issues,
          "warning",
          "DISPLAY_POWER_UNMAPPED",
          path .. ".c4DeviceId",
          "Display '" .. tostring(d.name) .. "' uses device power but has no Control4 device.",
          ent
        )
      end
      if route.strategy == "command" then
        local cmd = route.command
        if type(cmd) ~= "table" or not isC4Id(cmd.deviceId) or type(cmd.name) ~= "string" or cmd.name == "" then
          issue(
            issues,
            "error",
            "ROUTE_COMMAND_INVALID",
            path .. ".route.command",
            "A custom route needs a Control4 device id and a command name.",
            ent
          )
        elseif cmd.params ~= nil and type(cmd.params) ~= "table" then
          issue(
            issues,
            "error",
            "ROUTE_COMMAND_INVALID",
            path .. ".route.command.params",
            "Parameters must be an object.",
            ent
          )
        end
        issue(
          issues,
          "warning",
          "ROUTE_COMMAND_UNVERIFIED",
          path .. ".route",
          "Display '"
            .. tostring(d.name)
            .. "' uses a custom route command. Run Test Route on site: VenueFlow cannot check a custom command.",
          ent
        )
      end
      if isC4Id(d.c4RoomId) then
        if displayRoom[d.c4RoomId] ~= nil and route.strategy == "room" then
          issue(
            issues,
            "error",
            "DISPLAY_ROOM_SHARED",
            path .. ".c4RoomId",
            "Displays '"
              .. tostring(d.name)
              .. "' and '"
              .. tostring(displayRoom[d.c4RoomId].name)
              .. "' use the same Control4 room; they could never show different sources.",
            ent,
            { kind = "display", id = displayRoom[d.c4RoomId].id }
          )
        end
        displayRoom[d.c4RoomId] = displayRoom[d.c4RoomId] or d
        if zoneRoom[d.c4RoomId] ~= nil then
          issue(
            issues,
            "warning",
            "AUDIO_COUPLED",
            path .. ".c4RoomId",
            "Display '"
              .. tostring(d.name)
              .. "' and audio zone '"
              .. tostring(zoneRoom[d.c4RoomId].name)
              .. "' share a Control4 room: changing the picture there also changes that zone's sound.",
            ent,
            { kind = "audioZone", id = zoneRoom[d.c4RoomId].id }
          )
        end
      end
      checkLayout(issues, path .. ".layout", d.layout, ent)
    end
  end

  for i, g in ipairs(U.list(config.groups)) do
    if type(g) == "table" then
      local path = string.format("groups[%d]", i)
      checkIdList(issues, path .. ".displayIds", g.displayIds, displays, "display", "Group member list", {
        kind = "group",
        id = g.id,
      })
    end
  end

  -- Lighting and shades: a preset is one documented device command.
  for i, l in ipairs(U.list(config.lighting)) do
    if type(l) == "table" then
      local path = string.format("lighting[%d]", i)
      local ent = { kind = "lighting", id = l.id }
      checkRef(issues, path .. ".areaId", l.areaId, areas, "area", "Lighting area", ent, true)
      local seen = {}
      for j, p in ipairs(U.list(l.presets)) do
        local pp = string.format("%s.presets[%d]", path, j)
        if type(p) ~= "table" or not U.isId(p.id) or seen[p.id] then
          issue(issues, "error", "ID_INVALID", pp .. ".id", "Lighting preset has a missing or duplicate id.", ent)
        else
          seen[p.id] = true
          if not isC4Id(p.deviceId) or type(p.command) ~= "string" or p.command == "" then
            issue(
              issues,
              "warning",
              "LIGHTING_UNMAPPED",
              pp,
              "Lighting preset '" .. tostring(p.name) .. "' has no Control4 device or command yet.",
              ent
            )
          end
          if p.params ~= nil and type(p.params) ~= "table" then
            issue(issues, "error", "PARAMS_INVALID", pp .. ".params", "Parameters must be an object.", ent)
          end
        end
      end
    end
  end
  for i, s in ipairs(U.list(config.shades)) do
    if type(s) == "table" then
      local path = string.format("shades[%d]", i)
      local ent = { kind = "shade", id = s.id }
      checkRef(issues, path .. ".areaId", s.areaId, areas, "area", "Shade area", ent, true)
      if s.deviceId == nil then
        issue(
          issues,
          "warning",
          "SHADE_UNMAPPED",
          path .. ".deviceId",
          "Shade '" .. tostring(s.name) .. "' has no Control4 device.",
          ent
        )
      elseif not isC4Id(s.deviceId) then
        issue(issues, "error", "C4_ID_INVALID", path .. ".deviceId", "Control4 device id must be a number.", ent)
      end
    end
  end

  local ix = {
    floors = floors,
    areas = areas,
    sources = sources,
    displays = displays,
    zones = zones,
    groups = groups,
    lighting = lighting,
    shades = shades,
    rooms = rooms,
    scenes = scenes,
    rules = rules,
    variables = variables,
    profiles = profiles,
  }

  for i, v in ipairs(U.list(config.variables)) do
    if type(v) == "table" then
      local path = string.format("variables[%d]", i)
      if not VARTYPE_SET[v.type] then
        issue(issues, "error", "ENUM", path .. ".type", "Unknown variable type.", { kind = "variable", id = v.id })
      end
    end
  end

  -- Scenes and rules: the program validator owns the detail.
  for i, s in ipairs(U.list(config.scenes)) do
    if type(s) == "table" then
      local path = string.format("scenes[%d]", i)
      local ent = { kind = "scene", id = s.id }
      if s.condition ~= nil then
        Rules.validateCondition(s.condition, ix, path .. ".condition", issues, ent)
      end
      Rules.validateProgram(s.program, ix, path .. ".program", issues, ent)
    end
  end
  for i, r in ipairs(U.list(config.rules)) do
    if type(r) == "table" then
      local path = string.format("rules[%d]", i)
      local ent = { kind = "rule", id = r.id }
      Rules.validateTrigger(r.trigger, ix, path .. ".trigger", issues, ent)
      if r.condition ~= nil then
        Rules.validateCondition(r.condition, ix, path .. ".condition", issues, ent)
      end
      Rules.validateProgram(r.program, ix, path .. ".program", issues, ent)
    end
  end
  Rules.validateCycles(config, issues)
  Rules.validateScheduleOverlaps(config, ix, issues)

  -- Room panels.
  for i, r in ipairs(U.list(config.rooms)) do
    if type(r) == "table" then
      local path = string.format("rooms[%d]", i)
      local ent = { kind = "room", id = r.id }
      checkRef(issues, path .. ".areaId", r.areaId, areas, "area", "Room panel area", ent, true)
      checkRef(
        issues,
        path .. ".volumeZoneId",
        r.volumeZoneId,
        zones,
        "audio zone",
        "Room panel volume zone",
        ent,
        true
      )
      checkRef(
        issues,
        path .. ".lightingId",
        r.lightingId,
        lighting,
        "lighting control",
        "Room panel lighting",
        ent,
        true
      )
      checkIdList(issues, path .. ".shadeIds", r.shadeIds, shades, "shade", "Room panel shade list", ent)
      if r.displayIds ~= nil then
        checkIdList(issues, path .. ".displayIds", r.displayIds, displays, "display", "Room panel display list", ent)
      end
      if #U.list(r.buttons) > M.ROOM_BUTTONS_MAX then
        issue(
          issues,
          "error",
          "ROOM_TOO_MANY_BUTTONS",
          path .. ".buttons",
          string.format("A room panel has at most %d buttons.", M.ROOM_BUTTONS_MAX),
          ent
        )
      end
      local seen = {}
      for j, b in ipairs(U.list(r.buttons)) do
        local bp = string.format("%s.buttons[%d]", path, j)
        if type(b) ~= "table" or not U.isId(b.id) or seen[b.id] then
          issue(issues, "error", "ID_INVALID", bp .. ".id", "Room button has a missing or duplicate id.", ent)
        else
          seen[b.id] = true
          checkRef(issues, bp .. ".sceneId", b.sceneId, scenes, "scene", "Room button scene", ent)
        end
      end
    end
  end

  -- Staff profiles.
  local anyOpenProfile = false
  for i, p in ipairs(U.list(config.profiles)) do
    if type(p) == "table" then
      local path = string.format("profiles[%d]", i)
      local ent = { kind = "profile", id = p.id }
      if not ROLE_SET[p.role] then
        issue(issues, "error", "ENUM", path .. ".role", "Unknown role.", ent)
      end
      if not U.isList(p.interfaces) or #p.interfaces == 0 then
        issue(
          issues,
          "error",
          "PROFILE_NO_INTERFACE",
          path .. ".interfaces",
          "A profile needs at least one interface.",
          ent
        )
      else
        for j, name in ipairs(p.interfaces) do
          if not INTERFACE_SET[name] then
            issue(issues, "error", "ENUM", string.format("%s.interfaces[%d]", path, j), "Unknown interface.", ent)
          end
        end
        if not U.contains(p.interfaces, p.defaultInterface) then
          issue(
            issues,
            "error",
            "PROFILE_DEFAULT_INTERFACE",
            path .. ".defaultInterface",
            "The default interface must be one the profile may use.",
            ent
          )
        end
      end
      local perms = type(p.permissions) == "table" and p.permissions or {}
      checkIdList(issues, path .. ".permissions.floors", perms.floors, floors, "floor", "Visible floors", ent)
      checkIdList(issues, path .. ".permissions.areas", perms.areas, areas, "area", "Visible areas", ent)
      checkIdList(issues, path .. ".permissions.sources", perms.sources, sources, "source", "Available sources", ent)
      checkIdList(issues, path .. ".permissions.zones", perms.zones, zones, "audio zone", "Available zones", ent)
      checkIdList(issues, path .. ".permissions.sceneIds", perms.sceneIds, scenes, "scene", "Available scenes", ent)
      for _, flag in ipairs(PERMISSION_FLAGS) do
        if type(perms[flag]) ~= "boolean" then
          issue(
            issues,
            "error",
            "PERMISSION_INVALID",
            path .. ".permissions." .. flag,
            "Permission must be true or false.",
            ent
          )
        end
      end
      local hasPin = type(p.pinHash) == "string" and p.pinHash ~= ""
      if not hasPin then
        anyOpenProfile = true
        if perms.allOff == true or perms.venueStatus == true or p.role == "owner" or p.role == "manager" then
          issue(
            issues,
            "warning",
            "PROFILE_NO_PIN",
            path .. ".pinHash",
            "Profile '" .. tostring(p.name) .. "' can run venue-wide actions but has no PIN.",
            ent
          )
        end
      end
    end
  end
  if config.defaultProfileId ~= nil then
    if checkRef(issues, "defaultProfileId", config.defaultProfileId, profiles, "profile", "Default profile", nil) then
      local p = profiles[config.defaultProfileId]
      if type(p.pinHash) == "string" and p.pinHash ~= "" then
        issue(
          issues,
          "error",
          "DEFAULT_PROFILE_HAS_PIN",
          "defaultProfileId",
          "The profile a tile opens with must not need a PIN (staff with a PIN sign in from it)."
        )
      end
    end
  elseif #U.list(config.profiles) > 0 and not anyOpenProfile then
    -- Fine: every screen starts at the sign-in pad.
    anyOpenProfile = false
  end
  if #U.list(config.profiles) == 0 then
    issue(issues, "error", "NO_PROFILE", "profiles", "Add at least one staff profile.")
  end

  -- Stations: a fixed screen, known by its LAN address, opens as a profile.
  -- An address is not a secret (it can be imitated on the LAN), so a station
  -- may only be given a profile that has no PIN: it chooses WHICH open
  -- profile a screen gets, it never grants what a PIN protects.
  local stations = indexList(issues, config, "stations", "Station")
  local stationAddress = {}
  for i, st in ipairs(U.list(config.stations)) do
    if type(st) == "table" and stations[st.id] == st then
      local path = string.format("stations[%d]", i)
      local ent = { kind = "station", id = st.id }
      local a1, a2, a3, a4 = tostring(st.address or ""):match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
      a1, a2, a3, a4 = tonumber(a1), tonumber(a2), tonumber(a3), tonumber(a4)
      if a1 == nil or a1 > 255 or a2 > 255 or a3 > 255 or a4 > 255 then
        issue(
          issues,
          "error",
          "STATION_ADDRESS",
          path .. ".address",
          "A station needs an IPv4 address such as 192.168.1.52.",
          ent
        )
      elseif stationAddress[st.address] ~= nil then
        issue(
          issues,
          "error",
          "STATION_ADDRESS_SHARED",
          path .. ".address",
          "Stations '"
            .. tostring(st.name)
            .. "' and '"
            .. tostring(stationAddress[st.address])
            .. "' have the same address.",
          ent
        )
      else
        stationAddress[st.address] = st.name
      end
      if checkRef(issues, path .. ".profileId", st.profileId, profiles, "profile", "Station profile", ent) then
        local p = profiles[st.profileId]
        if type(p.pinHash) == "string" and p.pinHash ~= "" then
          issue(
            issues,
            "error",
            "STATION_PROFILE_HAS_PIN",
            path .. ".profileId",
            "Station '"
              .. tostring(st.name)
              .. "' cannot open as a profile that needs a PIN (staff sign in with the PIN instead).",
            ent
          )
        end
      end
    end
  end

  -- Layout extras.
  local layout = type(config.layout) == "table" and config.layout or {}
  local labelIds = {}
  if #U.list(layout.labels) > M.LIMITS.labels then
    issue(issues, "error", "TOO_MANY", "layout.labels", "Too many labels.")
  end
  for i, l in ipairs(U.list(layout.labels)) do
    local path = string.format("layout.labels[%d]", i)
    if type(l) ~= "table" or not U.isId(l.id) or labelIds[l.id] then
      issue(issues, "error", "ID_INVALID", path .. ".id", "Label has a missing or duplicate id.")
    else
      labelIds[l.id] = true
      checkRef(issues, path .. ".floorId", l.floorId, floors, "floor", "Label floor", nil)
      if type(l.text) ~= "string" or #l.text > 120 then
        issue(issues, "error", "LABEL_TEXT", path .. ".text", "Label text is missing or too long.")
      end
    end
  end
  local buttonIds = {}
  for i, b in ipairs(U.list(layout.sceneButtons)) do
    local path = string.format("layout.sceneButtons[%d]", i)
    if type(b) ~= "table" or not U.isId(b.id) or buttonIds[b.id] then
      issue(issues, "error", "ID_INVALID", path .. ".id", "Scene button has a missing or duplicate id.")
    else
      buttonIds[b.id] = true
      checkRef(issues, path .. ".floorId", b.floorId, floors, "floor", "Scene button floor", nil)
      checkRef(issues, path .. ".sceneId", b.sceneId, scenes, "scene", "Scene button scene", nil)
    end
  end

  return issues
end

function M.summarize(issues)
  local errors, warnings = 0, 0
  for _, i in ipairs(issues) do
    if i.severity == "error" then
      errors = errors + 1
    else
      warnings = warnings + 1
    end
  end
  return { errors = errors, warnings = warnings }
end

--- Whether a configuration may be published given the acknowledged issue ids.
--- Returns ok, blocking (list of issues that still block).
function M.publishable(issues, acknowledged)
  local acked = {}
  for _, id in ipairs(acknowledged or {}) do
    acked[id] = true
  end
  local blocking = {}
  for _, i in ipairs(issues) do
    if i.severity == "error" or not acked[i.id] then
      blocking[#blocking + 1] = i
    end
  end
  return #blocking == 0, blocking
end

return M
