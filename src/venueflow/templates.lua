--- VenueFlow: starting points (pure).
---
---   M.venue(type, name)       a blank venue of a business type: floor, areas,
---                             staff profiles and editable scene templates, no devices
---   M.sportsBar(hashPin)      the reference sports bar: 24 displays, 8 sources,
---                             4 audio zones, groups, scenes, schedules, 3 profiles
---   M.conferenceCenter(hashPin)  the reference conference centre
---
--- The two reference venues use invented Control4 ids and exist for the
--- simulator, the tests and demonstrations. They are not a claim about any
--- real project.

local Schema = require("venueflow.schema")

local M = {}

-- ─── Staff profile templates ────────────────────────────────────────────────

local function perms(overrides)
  local p = {
    floors = "all",
    areas = "all",
    sources = "all",
    zones = "all",
    sceneIds = "all",
    routeVideo = false,
    power = false,
    audio = false,
    lighting = false,
    shades = false,
    scenes = false,
    venueStatus = false,
    allOff = false,
    viewAlerts = false,
  }
  for k, v in pairs(overrides or {}) do
    p[k] = v
  end
  return p
end

local ALL_ON = {
  routeVideo = true,
  power = true,
  audio = true,
  lighting = true,
  shades = true,
  scenes = true,
  venueStatus = true,
  allOff = true,
  viewAlerts = true,
}

--- The seven role templates. `installer` is a profile for using the OPERATOR
--- screens with every permission; configuration is never a profile permission,
--- it needs an Installer Studio session.
M.PROFILE_TEMPLATES = {
  installer = {
    name = "Installer",
    interfaces = { "floorplan", "command", "room", "manager" },
    defaultInterface = "manager",
    permissions = perms(ALL_ON),
  },
  owner = {
    name = "Owner",
    interfaces = { "manager", "floorplan", "command", "room" },
    defaultInterface = "manager",
    permissions = perms(ALL_ON),
  },
  manager = {
    name = "Manager",
    interfaces = { "manager", "floorplan", "command" },
    defaultInterface = "manager",
    permissions = perms(ALL_ON),
  },
  bartender = {
    name = "Bartender",
    interfaces = { "command", "floorplan" },
    defaultInterface = "command",
    permissions = perms({ routeVideo = true, power = true, audio = true, scenes = true }),
  },
  host = {
    name = "Host",
    interfaces = { "room" },
    defaultInterface = "room",
    permissions = perms({ scenes = true }),
  },
  conference_staff = {
    name = "Conference Staff",
    interfaces = { "room", "command" },
    defaultInterface = "room",
    permissions = perms({
      routeVideo = true,
      power = true,
      audio = true,
      lighting = true,
      shades = true,
      scenes = true,
    }),
  },
  restricted = {
    name = "Restricted Operator",
    interfaces = { "room" },
    defaultInterface = "room",
    permissions = perms({ audio = true, scenes = true }),
  },
}

function M.profile(role, id)
  local t = M.PROFILE_TEMPLATES[role] or M.PROFILE_TEMPLATES.restricted
  local p = {
    id = id or role:gsub("_", "-"),
    name = t.name,
    role = role,
    interfaces = {},
    defaultInterface = t.defaultInterface,
    permissions = {},
  }
  for i, v in ipairs(t.interfaces) do
    p.interfaces[i] = v
  end
  for k, v in pairs(t.permissions) do
    p.permissions[k] = v
  end
  return p
end

-- ─── Scene templates ────────────────────────────────────────────────────────
-- Valid as they stand (they use "all displays"), and meant to be edited. A
-- template never names a source: which source is "the game" is the venue's.

local ALL = { all = true }

M.SCENE_TEMPLATES = {
  opening = {
    name = "Opening",
    icon = "sun",
    description = "Daily start: displays on, venue marked open.",
    program = {
      steps = {
        { type = "set_venue_status", status = "open" },
        { type = "display_power", target = ALL, power = "on" },
      },
    },
  },
  closing = {
    name = "Closing",
    icon = "moon",
    description = "End of day: displays off, venue marked closed.",
    confirm = true,
    program = {
      steps = {
        { type = "display_power", target = ALL, power = "off" },
        { type = "set_venue_status", status = "closed" },
      },
    },
  },
  game_day = {
    name = "Game Day",
    icon = "football",
    description = "All sports displays on. Add the routes for your sources.",
    condition = { op = "venue_status", is = "open" },
    program = { steps = { { type = "display_power", target = ALL, power = "on" } } },
  },
  happy_hour = {
    name = "Happy Hour",
    icon = "cocktail",
    description = "Promotions and upbeat audio. Add your routes and levels.",
    condition = { op = "venue_status", is = "open" },
    program = { steps = { { type = "display_power", target = ALL, power = "on" } } },
  },
  dinner = {
    name = "Dinner",
    icon = "utensils",
    description = "Quieter room for dinner service. Add your levels.",
    condition = { op = "venue_status", is = "open" },
    program = { steps = {} },
  },
  presentation = {
    name = "Presentation",
    icon = "laptop",
    description = "Displays on for a presenter. Add the laptop route and lighting.",
    program = { steps = { { type = "display_power", target = ALL, power = "on" } } },
  },
  conference = {
    name = "Conference",
    icon = "video",
    description = "Video call setup. Add the conference source route.",
    program = { steps = { { type = "display_power", target = ALL, power = "on" } } },
  },
  cleaning = {
    name = "Cleaning",
    icon = "sparkles",
    description = "Displays off while the venue is cleaned.",
    confirm = true,
    program = { steps = { { type = "display_power", target = ALL, power = "off" } } },
  },
}
M.SCENE_ORDER = { "opening", "closing", "game_day", "happy_hour", "dinner", "presentation", "conference", "cleaning" }

local function copy(v)
  if type(v) ~= "table" then
    return v
  end
  local out = {}
  for k, x in pairs(v) do
    out[k] = copy(x)
  end
  return out
end

function M.scene(key)
  local t = M.SCENE_TEMPLATES[key]
  if t == nil then
    return nil
  end
  local s = copy(t)
  s.id = key:gsub("_", "-")
  s.template = key
  s.confirm = t.confirm == true
  return s
end

-- ─── Business-type templates ────────────────────────────────────────────────

M.VENUE_TEMPLATES = {
  sports_bar = {
    label = "Sports Bar",
    interface = "command",
    areas = { "Bar", "Dining", "Patio" },
    scenes = { "opening", "game_day", "happy_hour", "closing", "cleaning" },
    profiles = { "manager", "bartender", "host" },
    default = "bartender",
    subsystems = { video = true, audio = true, lighting = false, shades = false },
  },
  restaurant = {
    label = "Restaurant",
    interface = "floorplan",
    areas = { "Dining", "Bar", "Patio" },
    scenes = { "opening", "happy_hour", "dinner", "closing", "cleaning" },
    profiles = { "manager", "host", "bartender" },
    default = "host",
    subsystems = { video = true, audio = true, lighting = true, shades = false },
  },
  corporate_office = {
    label = "Corporate Office",
    interface = "room",
    areas = { "Boardroom", "Meeting Room", "Lobby" },
    scenes = { "presentation", "conference", "closing" },
    profiles = { "manager", "conference_staff", "restricted" },
    default = "restricted",
    subsystems = { video = true, audio = true, lighting = true, shades = true },
  },
  conference_center = {
    label = "Conference Center",
    interface = "room",
    areas = { "Main Hall", "Breakout A", "Breakout B", "Foyer" },
    scenes = { "opening", "presentation", "conference", "closing", "cleaning" },
    profiles = { "manager", "conference_staff", "restricted" },
    default = "restricted",
    subsystems = { video = true, audio = true, lighting = true, shades = true },
  },
  hotel = {
    label = "Hotel",
    interface = "manager",
    areas = { "Lobby", "Bar", "Restaurant", "Ballroom" },
    scenes = { "opening", "happy_hour", "dinner", "conference", "closing" },
    profiles = { "manager", "bartender", "conference_staff" },
    default = "bartender",
    subsystems = { video = true, audio = true, lighting = true, shades = false },
  },
  fitness_center = {
    label = "Fitness Center",
    interface = "command",
    areas = { "Cardio", "Weights", "Studio", "Reception" },
    scenes = { "opening", "closing", "cleaning" },
    profiles = { "manager", "restricted" },
    default = "restricted",
    subsystems = { video = true, audio = true, lighting = false, shades = false },
  },
  retail = {
    label = "Retail",
    interface = "manager",
    areas = { "Showroom", "Demo Room", "Entrance" },
    scenes = { "opening", "presentation", "closing" },
    profiles = { "manager", "restricted" },
    default = "restricted",
    subsystems = { video = true, audio = true, lighting = true, shades = false },
  },
  custom = {
    label = "Custom",
    interface = "floorplan",
    areas = { "Main" },
    scenes = { "opening", "closing" },
    profiles = { "manager", "restricted" },
    default = "restricted",
    subsystems = { video = true, audio = true, lighting = false, shades = false },
  },
}

local AREA_COLORS = { "#2dd4bf", "#60a5fa", "#a78bfa", "#f59e0b", "#f472b6", "#34d399" }

--- A blank venue of one business type.
function M.venue(venueType, name)
  local t = M.VENUE_TEMPLATES[venueType] or M.VENUE_TEMPLATES.custom
  if M.VENUE_TEMPLATES[venueType] == nil then
    venueType = "custom"
  end
  local c = Schema.empty()
  c.venue.name = (name ~= nil and name ~= "") and name or ("New " .. t.label)
  c.venue.type = venueType
  c.venue.defaultInterface = t.interface
  c.venue.subsystems = copy(t.subsystems)
  c.floors[1] = { id = "main-floor", name = "Main Floor", width = 1200, height = 800, grid = 20 }
  local n = #t.areas
  local cols = n <= 2 and n or math.ceil(n / 2)
  local rows = math.ceil(n / cols)
  local cw, ch = (1200 - 80) / cols, (800 - 80) / rows
  for i, areaName in ipairs(t.areas) do
    local col, row = (i - 1) % cols, math.floor((i - 1) / cols)
    c.areas[i] = {
      id = areaName:lower():gsub("[^a-z0-9]+", "-"),
      name = areaName,
      floorId = "main-floor",
      color = AREA_COLORS[((i - 1) % #AREA_COLORS) + 1],
      layout = { x = 40 + col * cw + 10, y = 40 + row * ch + 10, w = cw - 20, h = ch - 20 },
    }
  end
  for i, key in ipairs(t.scenes) do
    c.scenes[i] = M.scene(key)
  end
  for i, role in ipairs(t.profiles) do
    c.profiles[i] = M.profile(role)
  end
  c.defaultProfileId = t.default:gsub("_", "-")
  return Schema.normalize(c)
end

-- ─── Reference venue 1: Riverside Sports Bar ────────────────────────────────

local function pinned(profile, hashPin, pin)
  if hashPin ~= nil then
    profile.pinSalt, profile.pinHash = hashPin(pin)
  end
  return profile
end

--- hashPin(pin) -> salt, hash. Without it the manager profile has no PIN
--- (validation then warns, as it should).
function M.sportsBar(hashPin)
  local c = Schema.empty()
  c.venue = {
    name = "Riverside Sports Bar",
    sample = true, -- invented Control4 ids: Simulation mode only
    type = "sports_bar",
    timezone = "",
    defaultInterface = "command",
    subsystems = { video = true, audio = true, lighting = true, shades = false },
  }
  c.floors = { { id = "main-floor", name = "Main Floor", width = 1200, height = 800, grid = 20 } }
  c.areas = {
    {
      id = "bar",
      name = "Bar",
      floorId = "main-floor",
      color = "#2dd4bf",
      layout = { x = 40, y = 40, w = 420, h = 440 },
    },
    {
      id = "dining",
      name = "Dining",
      floorId = "main-floor",
      color = "#60a5fa",
      layout = { x = 480, y = 40, w = 440, h = 440 },
    },
    {
      id = "patio",
      name = "Patio",
      floorId = "main-floor",
      color = "#34d399",
      layout = { x = 940, y = 40, w = 220, h = 720 },
    },
    {
      id = "lounge",
      name = "Lounge",
      floorId = "main-floor",
      color = "#a78bfa",
      layout = { x = 40, y = 500, w = 880, h = 260 },
    },
  }
  c.sources = {
    { id = "sports-1", name = "Sports 1", kind = "satellite", c4DeviceId = 3001 },
    { id = "sports-2", name = "Sports 2", kind = "satellite", c4DeviceId = 3002 },
    { id = "sports-3", name = "Sports 3", kind = "cable", c4DeviceId = 3003 },
    { id = "sports-4", name = "Sports 4", kind = "cable", c4DeviceId = 3004 },
    { id = "news", name = "Cable News", kind = "cable", c4DeviceId = 3005 },
    { id = "signage", name = "Menu Signage", kind = "signage", c4DeviceId = 3006, audio = false },
    { id = "streaming", name = "Streaming", kind = "streaming", c4DeviceId = 3007 },
    { id = "music", name = "House Music", kind = "music", c4DeviceId = 3008, video = false },
  }
  c.audioZones = {
    {
      id = "zone-bar",
      name = "Bar",
      areaId = "bar",
      c4RoomId = 1201,
      minVolume = 0,
      maxVolume = 85,
      defaultVolume = 60,
      presets = { { id = "quiet", name = "Quiet", level = 35 }, { id = "game", name = "Game", level = 70 } },
      layout = { x = 220, y = 260, w = 150, h = 60 },
    },
    {
      id = "zone-dining",
      name = "Dining",
      areaId = "dining",
      c4RoomId = 1202,
      minVolume = 0,
      maxVolume = 60,
      defaultVolume = 40,
      presets = { { id = "quiet", name = "Quiet", level = 25 }, { id = "normal", name = "Normal", level = 40 } },
      layout = { x = 600, y = 260, w = 150, h = 60 },
    },
    {
      id = "zone-patio",
      name = "Patio",
      areaId = "patio",
      c4RoomId = 1203,
      minVolume = 0,
      maxVolume = 70,
      defaultVolume = 50,
      presets = {},
      layout = { x = 975, y = 325, w = 150, h = 60 },
    },
    {
      id = "zone-lounge",
      name = "Lounge",
      areaId = "lounge",
      c4RoomId = 1204,
      minVolume = 0,
      maxVolume = 65,
      defaultVolume = 35,
      presets = {},
      layout = { x = 410, y = 610, w = 140, h = 60 },
    },
  }
  -- 24 displays: 8 bar, 8 dining, 4 patio, 4 lounge. Each is its own Control4
  -- room (the usual commercial arrangement), with a TV device for link state.
  local function tv(n, areaId, zoneId, x, y, rot, extra)
    local d = {
      id = string.format("tv-%02d", n),
      name = string.format("TV %02d", n),
      kind = "tv",
      floorId = "main-floor",
      areaId = areaId,
      c4RoomId = 1100 + n,
      c4DeviceId = 2100 + n,
      route = { strategy = "room" },
      sources = { "sports-1", "sports-2", "sports-3", "sports-4", "news", "signage", "streaming" },
      power = "room",
      feedback = "room",
      audioZoneId = zoneId,
      defaultSourceId = "sports-1",
      layout = { x = x, y = y, w = 96, h = 58, rot = rot or 0 },
    }
    for k, v in pairs(extra or {}) do
      d[k] = v
    end
    return d
  end
  local displays = {}
  -- Sized for a finger on a 1280-wide touch screen, and never overlapping.
  for i = 1, 8 do -- bar: four on the top wall, four down the left wall
    if i <= 4 then
      displays[#displays + 1] = tv(i, "bar", "zone-bar", 50 + (i - 1) * 102, 50)
    else
      displays[#displays + 1] = tv(i, "bar", "zone-bar", 50, 140 + (i - 5) * 70)
    end
  end
  for i = 9, 16 do -- dining: four on the top wall, four down the right wall
    if i <= 12 then
      displays[#displays + 1] = tv(i, "dining", "zone-dining", 490 + (i - 9) * 106, 50)
    else
      displays[#displays + 1] = tv(i, "dining", "zone-dining", 814, 140 + (i - 13) * 70)
    end
  end
  for i = 17, 20 do -- patio
    displays[#displays + 1] = tv(i, "patio", "zone-patio", 1002, 70 + (i - 17) * 170)
  end
  for i = 21, 24 do -- lounge
    displays[#displays + 1] = tv(i, "lounge", "zone-lounge", 90 + (i - 21) * 210, 690)
  end
  -- Two deliberate variations, so the simulator covers more than one kind:
  -- a signage panel that cannot show sports, and a projector driven by a
  -- custom command with no feedback.
  displays[20].name = "Patio Menu Board"
  displays[20].sources = { "signage" }
  displays[20].defaultSourceId = "signage"
  displays[24].name = "Lounge Projector"
  displays[24].kind = "projector"
  displays[24].route = {
    strategy = "command",
    command = { deviceId = 2900, name = "SET_INPUT", params = { INPUT = "${source}", OUTPUT = 24 } },
  }
  displays[24].power = "device"
  displays[24].feedback = "none"
  displays[24].c4RoomId = nil
  c.displays = displays

  local function ids(from, to)
    local out = {}
    for n = from, to do
      out[#out + 1] = string.format("tv-%02d", n)
    end
    return out
  end
  c.groups = {
    { id = "main-bar", name = "Main Bar", color = "#2dd4bf", displayIds = ids(1, 8) },
    { id = "dining-wall", name = "Dining Wall", color = "#60a5fa", displayIds = ids(9, 16) },
    { id = "patio-screens", name = "Patio Screens", color = "#34d399", displayIds = ids(17, 20) },
    { id = "lounge-screens", name = "Lounge Screens", color = "#a78bfa", displayIds = ids(21, 24) },
    {
      id = "big-game",
      name = "Big Game Wall",
      color = "#f59e0b",
      displayIds = { "tv-01", "tv-02", "tv-03", "tv-09", "tv-10", "tv-11" },
    },
  }
  c.lighting = {
    {
      id = "house-lights",
      name = "House Lights",
      areaId = "bar",
      presets = {
        {
          id = "game-day",
          name = "Game Day",
          deviceId = 4001,
          command = "ACTIVATE_SCENE",
          params = { SCENE_ID = 11 },
        },
        {
          id = "evening",
          name = "Evening",
          deviceId = 4001,
          command = "ACTIVATE_SCENE",
          params = { SCENE_ID = 12 },
        },
        {
          id = "bright",
          name = "Bright",
          deviceId = 4001,
          command = "ACTIVATE_SCENE",
          params = { SCENE_ID = 13 },
        },
      },
    },
  }
  c.variables = { { id = "big-game-on", name = "Big game on", type = "bool", initial = false } }
  c.scenes = {
    {
      id = "opening",
      name = "Opening",
      icon = "sun",
      template = "opening",
      description = "Daily startup. TVs on, venue audio on, standard sources.",
      program = {
        steps = {
          { type = "set_venue_status", status = "open" },
          {
            type = "route_video",
            sourceId = "news",
            target = { groupIds = { "main-bar", "dining-wall", "lounge-screens" } },
          },
          { type = "route_video", sourceId = "signage", target = { groupIds = { "patio-screens" } } },
          { type = "route_audio", zoneId = "zone-bar", sourceId = "music" },
          { type = "volume", zoneId = "zone-bar", level = 45 },
          { type = "route_audio", zoneId = "zone-dining", sourceId = "music" },
          { type = "volume", zoneId = "zone-dining", level = 35 },
          { type = "lighting", lightingId = "house-lights", presetId = "bright" },
        },
      },
    },
    {
      id = "game-day",
      name = "Game Day",
      icon = "football",
      template = "game_day",
      description = "All sports displays on, game sources, venue audio optimized.",
      condition = { op = "venue_status", is = "open" },
      program = {
        steps = {
          { type = "display_power", target = { groupIds = { "main-bar" } }, power = "on" },
          { type = "route_video", sourceId = "sports-1", target = { displayIds = ids(1, 6) } },
          { type = "route_video", sourceId = "sports-2", target = { displayIds = ids(7, 12) } },
          { type = "route_audio", zoneId = "zone-bar", sourceId = "sports-1" },
          { type = "volume", zoneId = "zone-bar", level = 65 },
          { type = "lighting", lightingId = "house-lights", presetId = "game-day" },
          { type = "set_variable", variableId = "big-game-on", value = true },
          { type = "notify", message = "Game Day is running", level = "info" },
        },
      },
    },
    {
      id = "happy-hour",
      name = "Happy Hour",
      icon = "cocktail",
      template = "happy_hour",
      description = "Promotions on key displays, upbeat audio at a moderate level.",
      condition = { op = "venue_status", is = "open" },
      program = {
        steps = {
          {
            type = "route_video",
            sourceId = "signage",
            target = { displayIds = { "tv-04", "tv-05", "tv-13" } },
          },
          { type = "route_audio", zoneId = "zone-bar", sourceId = "music" },
          { type = "volume", zoneId = "zone-bar", level = 55 },
          {
            type = "if",
            condition = { op = "time_range", from = "17:00", to = "23:00" },
            ["then"] = { { type = "lighting", lightingId = "house-lights", presetId = "evening" } },
            ["else"] = { { type = "lighting", lightingId = "house-lights", presetId = "bright" } },
          },
        },
      },
    },
    {
      id = "closing",
      name = "Closing",
      icon = "moon",
      template = "closing",
      description = "End of day. Displays off, venue audio off, systems ready.",
      confirm = true,
      program = {
        steps = {
          { type = "display_power", target = { all = true }, power = "off" },
          { type = "zone_power", zoneId = "zone-bar", power = "off" },
          { type = "zone_power", zoneId = "zone-dining", power = "off" },
          { type = "zone_power", zoneId = "zone-patio", power = "off" },
          { type = "zone_power", zoneId = "zone-lounge", power = "off" },
          { type = "set_variable", variableId = "big-game-on", value = false },
          { type = "set_venue_status", status = "closed" },
        },
      },
    },
    {
      id = "cleaning",
      name = "Cleaning",
      icon = "sparkles",
      template = "cleaning",
      description = "Displays off, lights bright.",
      confirm = true,
      program = {
        steps = {
          { type = "display_power", target = { all = true }, power = "off" },
          { type = "lighting", lightingId = "house-lights", presetId = "bright" },
        },
      },
    },
  }
  c.rules = {
    {
      id = "open-weekdays",
      name = "Open on weekdays",
      enabled = true,
      trigger = { type = "schedule", days = { 1, 2, 3, 4, 5 }, time = "11:00" },
      program = { steps = { { type = "run_scene", sceneId = "opening" } } },
    },
    {
      id = "happy-hour-daily",
      name = "Happy hour at four",
      enabled = true,
      trigger = { type = "schedule", days = { 1, 2, 3, 4, 5 }, time = "16:00" },
      condition = { op = "venue_status", is = "open" },
      program = { steps = { { type = "run_scene", sceneId = "happy-hour" } } },
    },
    {
      id = "patio-follows-status",
      name = "Patio signage when the venue opens",
      enabled = true,
      trigger = { type = "venue_status", status = "open" },
      program = {
        steps = { { type = "route_video", sourceId = "signage", target = { displayIds = { "tv-20" } } } },
      },
    },
  }
  c.profiles = {
    pinned(M.profile("manager"), hashPin, "2580"),
    M.profile("bartender"),
    M.profile("host"),
  }
  -- The bartender tablet is a bar-only device.
  c.profiles[2].permissions.areas = { "bar" }
  c.profiles[2].permissions.zones = { "zone-bar" }
  c.profiles[2].permissions.sceneIds = { "game-day", "happy-hour" }
  c.profiles[3].permissions.sceneIds = { "opening", "happy-hour" }
  c.defaultProfileId = "bartender"
  c.rooms = {
    {
      id = "host-stand",
      name = "Host Station",
      areaId = "dining",
      buttons = {
        { id = "open", label = "Opening", icon = "sun", sceneId = "opening" },
        { id = "happy", label = "Happy Hour", icon = "cocktail", sceneId = "happy-hour" },
      },
      volumeZoneId = "zone-dining",
      shadeIds = {},
    },
  }
  c.layout = {
    labels = {
      { id = "lbl-entry", floorId = "main-floor", text = "Main Entry", x = 560, y = 775, size = 14 },
      { id = "lbl-bar", floorId = "main-floor", text = "BAR", x = 270, y = 190, size = 22 },
    },
    sceneButtons = {
      { id = "sb-game", floorId = "main-floor", sceneId = "game-day", x = 240, y = 390, w = 150, h = 50 },
    },
  }
  return Schema.normalize(c)
end

-- ─── Reference venue 2: Sterling Conference Centre ──────────────────────────

function M.conferenceCenter(hashPin)
  local c = Schema.empty()
  c.venue = {
    name = "Sterling Conference Centre",
    sample = true, -- invented Control4 ids: Simulation mode only
    type = "conference_center",
    timezone = "",
    defaultInterface = "room",
    subsystems = { video = true, audio = true, lighting = true, shades = true },
  }
  c.floors = {
    { id = "level-1", name = "Level 1", width = 1200, height = 800, grid = 20 },
    { id = "level-2", name = "Level 2", width = 1200, height = 800, grid = 20 },
  }
  c.areas = {
    {
      id = "boardroom-a",
      name = "Boardroom A",
      floorId = "level-1",
      color = "#2dd4bf",
      layout = { x = 40, y = 40, w = 540, h = 340 },
    },
    {
      id = "boardroom-b",
      name = "Boardroom B",
      floorId = "level-1",
      color = "#60a5fa",
      layout = { x = 620, y = 40, w = 540, h = 340 },
    },
    {
      id = "foyer",
      name = "Foyer",
      floorId = "level-1",
      color = "#f59e0b",
      layout = { x = 40, y = 420, w = 1120, h = 340 },
    },
    {
      id = "training",
      name = "Training Room",
      floorId = "level-2",
      color = "#a78bfa",
      layout = { x = 40, y = 40, w = 1120, h = 720 },
    },
  }
  c.sources = {
    { id = "laptop-a", name = "Laptop HDMI (A)", kind = "laptop", c4DeviceId = 5001 },
    { id = "laptop-b", name = "Laptop HDMI (B)", kind = "laptop", c4DeviceId = 5002 },
    { id = "wireless", name = "Wireless Presenter", kind = "laptop", c4DeviceId = 5003 },
    { id = "codec", name = "Video Conference", kind = "conference", c4DeviceId = 5004 },
    { id = "tv-tuner", name = "Cable TV", kind = "cable", c4DeviceId = 5005 },
    { id = "signage", name = "Welcome Signage", kind = "signage", c4DeviceId = 5006, audio = false },
  }
  c.audioZones = {
    {
      id = "audio-a",
      name = "Boardroom A",
      areaId = "boardroom-a",
      c4RoomId = 6201,
      maxVolume = 70,
      defaultVolume = 35,
      presets = {},
    },
    {
      id = "audio-b",
      name = "Boardroom B",
      areaId = "boardroom-b",
      c4RoomId = 6202,
      maxVolume = 70,
      defaultVolume = 35,
      presets = {},
    },
    {
      id = "audio-foyer",
      name = "Foyer",
      areaId = "foyer",
      c4RoomId = 6203,
      maxVolume = 50,
      defaultVolume = 25,
      presets = {},
    },
    {
      id = "audio-training",
      name = "Training Room",
      areaId = "training",
      c4RoomId = 6204,
      maxVolume = 80,
      defaultVolume = 40,
      presets = {},
    },
  }
  local function display(id, name, kind, floorId, areaId, n, x, y, sources, zoneId)
    return {
      id = id,
      name = name,
      kind = kind,
      floorId = floorId,
      areaId = areaId,
      c4RoomId = 6100 + n,
      c4DeviceId = 6300 + n,
      route = { strategy = "room" },
      sources = sources,
      power = "room",
      feedback = "room",
      audioZoneId = zoneId,
      layout = { x = x, y = y, w = 90, h = 50, rot = 0 },
    }
  end
  local roomA = { "laptop-a", "wireless", "codec", "tv-tuner" }
  local roomB = { "laptop-b", "wireless", "codec", "tv-tuner" }
  c.displays = {
    display("a-main", "Boardroom A Main", "tv", "level-1", "boardroom-a", 1, 200, 60, roomA, "audio-a"),
    display("a-side", "Boardroom A Side", "tv", "level-1", "boardroom-a", 2, 60, 200, roomA, "audio-a"),
    display("b-main", "Boardroom B Main", "tv", "level-1", "boardroom-b", 3, 800, 60, roomB, "audio-b"),
    display("b-side", "Boardroom B Side", "tv", "level-1", "boardroom-b", 4, 1050, 200, roomB, "audio-b"),
    display(
      "foyer-left",
      "Foyer Left",
      "tv",
      "level-1",
      "foyer",
      5,
      200,
      440,
      { "signage", "tv-tuner" },
      "audio-foyer"
    ),
    display(
      "foyer-right",
      "Foyer Right",
      "tv",
      "level-1",
      "foyer",
      6,
      900,
      440,
      { "signage", "tv-tuner" },
      "audio-foyer"
    ),
    display(
      "training-projector",
      "Training Projector",
      "projector",
      "level-2",
      "training",
      7,
      550,
      60,
      "all",
      "audio-training"
    ),
    display(
      "training-confidence",
      "Confidence Monitor",
      "tv",
      "level-2",
      "training",
      8,
      550,
      680,
      "all",
      "audio-training"
    ),
  }
  c.groups = {
    { id = "boardroom-a-displays", name = "Boardroom A", displayIds = { "a-main", "a-side" } },
    { id = "boardroom-b-displays", name = "Boardroom B", displayIds = { "b-main", "b-side" } },
    { id = "foyer-displays", name = "Foyer", displayIds = { "foyer-left", "foyer-right" } },
    {
      id = "training-displays",
      name = "Training Room",
      displayIds = { "training-projector", "training-confidence" },
    },
  }
  c.lighting = {
    {
      id = "lights-a",
      name = "Boardroom A Lights",
      areaId = "boardroom-a",
      presets = {
        {
          id = "presentation",
          name = "Presentation",
          deviceId = 7001,
          command = "ACTIVATE_SCENE",
          params = { SCENE_ID = 21 },
        },
        {
          id = "meeting",
          name = "Meeting",
          deviceId = 7001,
          command = "ACTIVATE_SCENE",
          params = { SCENE_ID = 22 },
        },
        {
          id = "bright",
          name = "Bright",
          deviceId = 7001,
          command = "ACTIVATE_SCENE",
          params = { SCENE_ID = 23 },
        },
      },
    },
  }
  c.shades = { { id = "shades-a", name = "Boardroom A Shades", areaId = "boardroom-a", deviceId = 7101 } }
  c.scenes = {
    {
      id = "a-present",
      name = "Present Laptop",
      icon = "laptop",
      template = "presentation",
      description = "Boardroom A: laptop on both displays, presentation lighting, shades closed.",
      program = {
        steps = {
          { type = "route_video", sourceId = "laptop-a", target = { groupIds = { "boardroom-a-displays" } } },
          { type = "route_audio", zoneId = "audio-a", sourceId = "laptop-a" },
          { type = "volume", zoneId = "audio-a", level = 35 },
          { type = "lighting", lightingId = "lights-a", presetId = "presentation" },
          { type = "shade", shadeId = "shades-a", action = "close" },
        },
      },
    },
    {
      id = "a-conference",
      name = "Video Conference",
      icon = "video",
      template = "conference",
      description = "Boardroom A: conference codec on the main display.",
      program = {
        steps = {
          { type = "route_video", sourceId = "codec", target = { displayIds = { "a-main" } } },
          { type = "route_audio", zoneId = "audio-a", sourceId = "codec" },
          { type = "volume", zoneId = "audio-a", level = 45 },
          { type = "lighting", lightingId = "lights-a", presetId = "meeting" },
        },
      },
    },
    {
      id = "a-tv",
      name = "Watch TV",
      icon = "tv",
      description = "Boardroom A: cable TV on the main display.",
      program = {
        steps = {
          { type = "route_video", sourceId = "tv-tuner", target = { displayIds = { "a-main" } } },
          { type = "route_audio", zoneId = "audio-a", sourceId = "tv-tuner" },
        },
      },
    },
    {
      id = "a-off",
      name = "Room Off",
      icon = "power",
      description = "Boardroom A: displays and audio off, lights bright, shades open.",
      program = {
        steps = {
          { type = "display_power", target = { groupIds = { "boardroom-a-displays" } }, power = "off" },
          { type = "zone_power", zoneId = "audio-a", power = "off" },
          { type = "lighting", lightingId = "lights-a", presetId = "bright" },
          { type = "shade", shadeId = "shades-a", action = "open" },
        },
      },
    },
    {
      id = "opening",
      name = "Opening",
      icon = "sun",
      template = "opening",
      description = "Welcome signage in the foyer; venue marked open.",
      program = {
        steps = {
          { type = "set_venue_status", status = "open" },
          { type = "route_video", sourceId = "signage", target = { groupIds = { "foyer-displays" } } },
        },
      },
    },
    {
      id = "closing",
      name = "Closing",
      icon = "moon",
      template = "closing",
      description = "Every display off; venue marked closed.",
      confirm = true,
      program = {
        steps = {
          { type = "display_power", target = { all = true }, power = "off" },
          { type = "set_venue_status", status = "closed" },
        },
      },
    },
  }
  c.rules = {
    {
      id = "weekday-open",
      name = "Open at 7:30 on weekdays",
      enabled = true,
      trigger = { type = "schedule", days = { 1, 2, 3, 4, 5 }, time = "07:30" },
      program = { steps = { { type = "run_scene", sceneId = "opening" } } },
    },
  }
  c.rooms = {
    {
      id = "panel-boardroom-a",
      name = "Boardroom A",
      areaId = "boardroom-a",
      buttons = {
        { id = "present", label = "Present Laptop", icon = "laptop", sceneId = "a-present" },
        { id = "conference", label = "Video Conference", icon = "video", sceneId = "a-conference" },
        { id = "tv", label = "Watch TV", icon = "tv", sceneId = "a-tv" },
        { id = "off", label = "Room Off", icon = "power", sceneId = "a-off" },
      },
      volumeZoneId = "audio-a",
      lightingId = "lights-a",
      shadeIds = { "shades-a" },
      displayIds = { "a-main", "a-side" },
      showSources = true,
    },
  }
  c.profiles = {
    pinned(M.profile("manager", "facilities"), hashPin, "2580"),
    M.profile("conference_staff", "conference-staff"),
    M.profile("restricted", "meeting-room"),
  }
  c.profiles[1].name = "Facilities Manager"
  c.profiles[3].name = "Meeting Room Panel"
  c.profiles[3].permissions.areas = { "boardroom-a" }
  c.profiles[3].permissions.zones = { "audio-a" }
  c.profiles[3].permissions.sceneIds = { "a-present", "a-conference", "a-tv", "a-off" }
  c.profiles[3].permissions.lighting = true
  c.profiles[3].permissions.shades = true
  c.defaultProfileId = "meeting-room"
  return Schema.normalize(c)
end

return M
