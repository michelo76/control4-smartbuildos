--- VenueFlow: what a staff profile may see and do (pure).
---
--- An Access object is built by the driver from the session, never from
--- anything a page says about itself. Every engine asks it before acting, so
--- hiding a button in a page is a convenience, not the protection.

local U = require("venueflow.util")

local M = {}

local Access = {}
Access.__index = Access

local function allows(scope, id)
  if scope == "all" then
    return true
  end
  if type(scope) ~= "table" then
    return false
  end
  return U.contains(scope, id)
end

--- The driver itself (scenes, schedules, Composer programming, the installer).
function M.system(label)
  local self = setmetatable({}, Access)
  self.system = true
  self.label = label or "system"
  self.profileId = nil
  return self
end

function M.forProfile(profile)
  local self = setmetatable({}, Access)
  self.system = false
  self.profile = profile
  self.profileId = profile.id
  self.label = "profile:" .. tostring(profile.id)
  self.permissions = type(profile.permissions) == "table" and profile.permissions or {}
  return self
end

function Access:flag(name)
  if self.system then
    return true
  end
  return self.permissions[name] == true
end

function Access:floor(id)
  if self.system then
    return true
  end
  return allows(self.permissions.floors, id)
end

function Access:area(id)
  if self.system or id == nil then
    return true
  end
  return allows(self.permissions.areas, id)
end

function Access:display(display)
  if self.system then
    return true
  end
  return self:floor(display.floorId) and self:area(display.areaId)
end

function Access:source(source)
  if self.system then
    return true
  end
  return allows(self.permissions.sources, source.id)
end

function Access:zone(zone)
  if self.system then
    return true
  end
  return allows(self.permissions.zones, zone.id) and self:area(zone.areaId)
end

function Access:scene(scene)
  if self.system then
    return true
  end
  return self.permissions.scenes == true and allows(self.permissions.sceneIds, scene.id)
end

function Access:lightingControl(item)
  if self.system then
    return true
  end
  return self.permissions.lighting == true and self:area(item.areaId)
end

function Access:shade(item)
  if self.system then
    return true
  end
  return self.permissions.shades == true and self:area(item.areaId)
end

function Access:interface(name)
  if self.system then
    return true
  end
  return U.contains(U.list(self.profile.interfaces), name)
end

--- The configuration as this profile may see it: only visible entities, and
--- nothing an operator screen has no use for (Control4 ids, route commands,
--- PIN hashes, programs).
function Access:view(config)
  local out = {
    venue = {
      name = config.venue.name,
      type = config.venue.type,
      subsystems = U.copy(config.venue.subsystems),
      defaultInterface = config.venue.defaultInterface,
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
    labels = {},
    sceneButtons = {},
  }
  local floorOk = {}
  for _, f in ipairs(config.floors or {}) do
    if self:floor(f.id) then
      floorOk[f.id] = true
      out.floors[#out.floors + 1] = {
        id = f.id,
        name = f.name,
        width = f.width,
        height = f.height,
        image = f.image and U.copy(f.image) or nil,
      }
    end
  end
  for _, a in ipairs(config.areas or {}) do
    if floorOk[a.floorId] and self:area(a.id) then
      out.areas[#out.areas + 1] = {
        id = a.id,
        name = a.name,
        floorId = a.floorId,
        color = a.color,
        layout = a.layout and U.copy(a.layout) or nil,
      }
    end
  end
  for _, s in ipairs(config.sources or {}) do
    if s.enabled ~= false and self:source(s) then
      out.sources[#out.sources + 1] = {
        id = s.id,
        name = s.name,
        kind = s.kind,
        video = s.video ~= false,
        audio = s.audio ~= false,
        mapped = s.c4DeviceId ~= nil,
      }
    end
  end
  local displayOk = {}
  for _, d in ipairs(config.displays or {}) do
    if floorOk[d.floorId] and self:display(d) then
      displayOk[d.id] = true
      out.displays[#out.displays + 1] = {
        id = d.id,
        name = d.name,
        kind = d.kind,
        floorId = d.floorId,
        areaId = d.areaId,
        sources = U.copy(d.sources),
        audioZoneId = d.audioZoneId,
        canRoute = d.route.strategy ~= "none",
        canPower = d.power ~= "none",
        hasFeedback = d.feedback == "room",
        layout = d.layout and U.copy(d.layout) or nil,
      }
    end
  end
  for _, z in ipairs(config.audioZones or {}) do
    if self:zone(z) then
      out.audioZones[#out.audioZones + 1] = {
        id = z.id,
        name = z.name,
        areaId = z.areaId,
        floorId = z.floorId,
        sources = U.copy(z.sources),
        minVolume = z.minVolume,
        maxVolume = z.maxVolume,
        presets = U.copy(z.presets),
        can = U.copy(z.can),
        layout = z.layout and U.copy(z.layout) or nil,
      }
    end
  end
  for _, g in ipairs(config.groups or {}) do
    local members = {}
    for _, id in ipairs(g.displayIds or {}) do
      if displayOk[id] then
        members[#members + 1] = id
      end
    end
    if #members > 0 then
      out.groups[#out.groups + 1] = { id = g.id, name = g.name, color = g.color, displayIds = members }
    end
  end
  for _, l in ipairs(config.lighting or {}) do
    if self:lightingControl(l) then
      local presets = {}
      for _, p in ipairs(l.presets or {}) do
        presets[#presets + 1] = { id = p.id, name = p.name }
      end
      out.lighting[#out.lighting + 1] = { id = l.id, name = l.name, areaId = l.areaId, presets = presets }
    end
  end
  for _, s in ipairs(config.shades or {}) do
    if self:shade(s) then
      out.shades[#out.shades + 1] = { id = s.id, name = s.name, areaId = s.areaId }
    end
  end
  local sceneOk = {}
  for _, s in ipairs(config.scenes or {}) do
    if self:scene(s) then
      sceneOk[s.id] = true
      out.scenes[#out.scenes + 1] =
        { id = s.id, name = s.name, icon = s.icon, description = s.description, confirm = s.confirm == true }
    end
  end
  for _, r in ipairs(config.rooms or {}) do
    if self:area(r.areaId) then
      local buttons = {}
      for _, b in ipairs(r.buttons or {}) do
        if sceneOk[b.sceneId] then
          buttons[#buttons + 1] = { id = b.id, label = b.label, icon = b.icon, sceneId = b.sceneId }
        end
      end
      out.rooms[#out.rooms + 1] = {
        id = r.id,
        name = r.name,
        areaId = r.areaId,
        buttons = buttons,
        volumeZoneId = r.volumeZoneId,
        lightingId = r.lightingId,
        shadeIds = U.copy(r.shadeIds),
        showSources = r.showSources == true,
        displayIds = U.copy(r.displayIds),
      }
    end
  end
  local layout = config.layout or {}
  for _, l in ipairs(layout.labels or {}) do
    if floorOk[l.floorId] then
      out.labels[#out.labels + 1] = U.copy(l)
    end
  end
  for _, b in ipairs(layout.sceneButtons or {}) do
    if floorOk[b.floorId] and sceneOk[b.sceneId] then
      out.sceneButtons[#out.sceneButtons + 1] = U.copy(b)
    end
  end
  return out
end

--- What the page may show about the signed-in profile.
function Access:describe()
  if self.system then
    -- An Installer Studio session using the operator page: everything allowed.
    local all = {}
    for _, name in ipairs({
      "routeVideo",
      "power",
      "audio",
      "lighting",
      "shades",
      "scenes",
      "venueStatus",
      "allOff",
      "viewAlerts",
    }) do
      all[name] = true
    end
    return {
      id = nil,
      name = "Installer",
      role = "installer",
      system = true,
      interfaces = { "floorplan", "command", "room", "manager" },
      defaultInterface = "manager",
      can = all,
    }
  end
  local p = self.profile
  local flags = {}
  for _, name in ipairs({
    "routeVideo",
    "power",
    "audio",
    "lighting",
    "shades",
    "scenes",
    "venueStatus",
    "allOff",
    "viewAlerts",
  }) do
    flags[name] = self.permissions[name] == true
  end
  return {
    id = p.id,
    name = p.name,
    role = p.role,
    interfaces = U.copy(p.interfaces),
    defaultInterface = p.defaultInterface,
    can = flags,
  }
end

return M
