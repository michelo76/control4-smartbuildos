--[[==========================================================================
  SmartBuildOS Solar Position

  Control4 knows sunrise and sunset. It does not know where the sun IS: how
  high, which way, and whether it is shining on the west glass right now.
  This driver computes that every minute from the project's coordinates
  (NOAA equations, offline) and hands it to programming as variables,
  events and conditionals: elevation, azimuth, day phase, next sunrise and
  sunset, and up to four building facades with "sun hits" / "sun leaves".

  Licensing: SmartBuildOS Agent, SKU SBOS_SOLAR (sbos.license). A definitive
  denial with enforcement on stops the minute tick; uncertainty never does.

  Pure rules: src/solarpos/{position,engine}.lua on top of
  src/atmosphere/solar.lua — tested without a controller.
============================================================================]]

--#ifdef DRIVERCENTRAL
DC_PID = 0
DC_X = nil
DC_FILENAME = "smartbuildos-solar.c4z"
--#else
DRIVER_GITHUB_REPO = "michelo76/control4-smartbuildos"
DRIVER_FILENAMES = { "smartbuildos-solar.c4z" }
--#endif

require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")
JSON = require("JSON")

local log = require("lib.logging")
local persist = require("lib.persist")
local license = require("sbos.license")
local Solar = require("atmosphere.solar")
local Position = require("solarpos.position")
local Engine = require("solarpos.engine")

gInitialized = false

local SKU = "SBOS_SOLAR"
local P_LOCATION = "solar_location_v1"
local TICK_TIMER = "SolarTick"
local STATUS_TIMER = "SolarStatus"

local EVENT_GOLDEN, EVENT_DAWN, EVENT_DUSK, EVENT_LOCATION = 1, 2, 3, 12
local function facadeHitEvent(i)
  return 2 + 2 * i
end
local function facadeLeftEvent(i)
  return 3 + 2 * i
end

local gEngine = nil
local gLocation = nil
local gLast = nil
local gLastError = "none"
local gLicenceHalted = false
local gLastHealthy = nil

--- UTC epoch now. A test may pin the clock by defining SOLAR_NOW first.
local function now()
  if type(SOLAR_NOW) == "function" then
    return SOLAR_NOW()
  end
  return os.time()
end

--- Seconds east of UTC for the controller's zone (atmosphere's rule).
local function localOffset()
  return os.time() - os.time(os.date("!*t"))
end

local function fire(id)
  pcall(function()
    C4:FireEventByID(id)
  end)
end

local function setVar(name, value)
  pcall(function()
    C4:SetVariable(name, value)
  end)
end

local function fmtTime(epoch)
  if epoch == nil then
    return ""
  end
  return os.date("%H:%M", epoch)
end

-- ─── Location ───────────────────────────────────────────────────────────────

--- Resolves site coordinates: manual fields, or the project's own location
--- from GetProjectItems (tolerant tag grab, the same approach Atmosphere
--- ships). Returns nil when nothing yields a pair, and says so.
local function resolveLocation()
  local source = tostring(Properties["Location Source"] or "Control4 Project")
  if source == "Manual Coordinates" then
    local lat = tonumber(Properties["Latitude"])
    local lon = tonumber(Properties["Longitude"])
    if lat ~= nil and lon ~= nil and lat >= -90 and lat <= 90 and lon >= -180 and lon <= 180 then
      return { lat = lat, lon = lon, source = "manual", label = string.format("%.4f, %.4f", lat, lon) }
    end
    return nil, "Manual Coordinates needs a valid Latitude and Longitude"
  end
  local ok, proj = pcall(function()
    local raw = C4:GetProjectItems("LOCATIONS", "LIMIT_DEVICE_DATA", "NO_ROOT_TAGS")
    if type(XMLDecode) == "function" then
      return XMLDecode(raw)
    end
    return raw
  end)
  if ok and type(proj) == "string" then
    local function grab(tag)
      return proj:match("<" .. tag .. "[^>]*>%s*([^<]-)%s*</" .. tag .. ">")
    end
    local lat = tonumber(grab("latitude"))
    local lon = tonumber(grab("longitude"))
    if lat ~= nil and lon ~= nil and not (lat == 0 and lon == 0) then
      local city = grab("city_name")
      local label = tostring(city or "")
      if label == "" then
        label = string.format("%.4f, %.4f", lat, lon)
      end
      return { lat = lat, lon = lon, source = "project", label = label }
    end
  end
  return nil, "the project has no latitude/longitude; set them in the project properties or use Manual Coordinates"
end

local function facadesFromProperties()
  local list = {}
  for i = 1, Engine.LIMITS.facades do
    list[i] = {
      name = Properties["Facade " .. i .. " Name"],
      azimuth = Properties["Facade " .. i .. " Azimuth"],
      width = Properties["Facade " .. i .. " Width"],
      min_elevation = Properties["Facade " .. i .. " Min Elevation"],
    }
  end
  return list
end

-- ─── Status ─────────────────────────────────────────────────────────────────

local function solarStatus()
  if gEngine == nil then
    return "starting"
  end
  if gLicenceHalted then
    return "unlicensed"
  end
  if gLocation == nil then
    return "no_location"
  end
  return "tracking"
end

local function paint()
  local status = solarStatus()
  UpdateProperty("Solar Status", status)
  UpdateProperty(
    "Location",
    gLocation and string.format("%s (%s: %.4f, %.4f)", gLocation.label, gLocation.source, gLocation.lat, gLocation.lon)
      or "unresolved"
  )
  UpdateProperty("Last Solar Error", gLastError)
  setVar("LOCATION_SOURCE", gLocation and gLocation.source or "none")
  local r = gLast
  if r ~= nil then
    local pos = r.position
    UpdateProperty(
      "Sun Now",
      string.format("elevation %.1f°, azimuth %.1f° (%s)", pos.elevation, pos.azimuth, r.phase)
    )
    if r.solar ~= nil then
      UpdateProperty(
        "Today",
        string.format(
          "sunrise %s, solar noon %s, sunset %s; next sunrise %s, next sunset %s",
          fmtTime(r.solar.sunrise),
          fmtTime(r.solar.solarNoon),
          fmtTime(r.solar.sunset),
          fmtTime(r.solar.nextSunrise),
          fmtTime(r.solar.nextSunset)
        )
      )
    else
      UpdateProperty("Today", "polar day or night: no sunrise or sunset today")
    end
    local parts = {}
    for i = 1, Engine.LIMITS.facades do
      local f = r.facades[i]
      if f ~= nil then
        parts[#parts + 1] = string.format("%s: %s", f.name, f.lit and "sun" or "shade")
      end
    end
    UpdateProperty("Facade Status", #parts > 0 and table.concat(parts, "; ") or "no facades configured")
    setVar("SUN_ELEVATION", math.floor(pos.elevation + 0.5))
    setVar("SUN_AZIMUTH", math.floor(pos.azimuth + 0.5))
    setVar("IS_DAYLIGHT", r.is_daylight)
    setVar("DAY_PHASE", r.phase)
    setVar("NEXT_SUNRISE", r.solar and fmtTime(r.solar.nextSunrise) or "")
    setVar("NEXT_SUNSET", r.solar and fmtTime(r.solar.nextSunset) or "")
    setVar("MINUTES_TO_SUNSET", r.solar and r.solar.minutesToSunset or 0)
    setVar("MINUTES_TO_SUNRISE", r.solar and r.solar.minutesToSunrise or 0)
    for i = 1, Engine.LIMITS.facades do
      setVar("SUN_ON_FACADE_" .. i, r.facades[i] ~= nil and r.facades[i].lit == true)
    end
  end
  local healthy = status == "tracking"
  gLastHealthy = healthy
end

-- ─── Tick ───────────────────────────────────────────────────────────────────

local function tick()
  if gEngine == nil or gLicenceHalted or gLocation == nil then
    return nil
  end
  local ok, result = pcall(function()
    return gEngine:tick(now(), localOffset())
  end)
  if not ok then
    gLastError = "tick failed: " .. tostring(result)
    log:error("%s", gLastError)
    paint()
    return nil
  end
  gLast = result
  if result ~= nil then
    for _, e in ipairs(result.events) do
      if e == "golden_hour" then
        fire(EVENT_GOLDEN)
      elseif e == "civil_dawn" then
        fire(EVENT_DAWN)
      elseif e == "civil_dusk" then
        fire(EVENT_DUSK)
      else
        local kind, idx = e:match("^facade_(%a+):(%d+)$")
        if kind == "hit" then
          fire(facadeHitEvent(tonumber(idx)))
        elseif kind == "left" then
          fire(facadeLeftEvent(tonumber(idx)))
        end
      end
      log:info("Solar: %s", e)
    end
  end
  paint()
  return result
end

local function applyLocation(reason)
  local loc, why = resolveLocation()
  local changed = (loc == nil) ~= (gLocation == nil)
    or (loc ~= nil and gLocation ~= nil and (loc.lat ~= gLocation.lat or loc.lon ~= gLocation.lon))
  gLocation = loc
  if loc == nil then
    gLastError = why or "location unresolved"
    gEngine:setLocation(nil, nil)
    gLast = nil
  else
    gLastError = "none"
    gEngine:setLocation(loc.lat, loc.lon)
  end
  persist:set(P_LOCATION, loc)
  if changed and gInitialized then
    log:info("Location %s (%s)", loc and loc.label or "unresolved", tostring(reason))
    fire(EVENT_LOCATION)
  end
  tick()
  paint()
  return loc
end

local function applyFacades()
  if gEngine then
    gEngine:setFacades(facadesFromProperties())
    tick()
  end
end

-- ─── Licence ────────────────────────────────────────────────────────────────

local function reconcileLicence()
  local halt = license.enforces()
  if halt and not gLicenceHalted then
    gLicenceHalted = true
    gLastError = "SmartBuildOS licence: " .. tostring(license.statusLabel())
    log:warn("%s — solar tracking halted", gLastError)
    paint()
  elseif not halt and gLicenceHalted then
    gLicenceHalted = false
    gLastError = "none"
    if gEngine then
      gEngine:setLocation(nil, nil)
      if gLocation then
        gEngine:setLocation(gLocation.lat, gLocation.lon)
      end
    end
    tick()
  end
end

-- ─── Lifecycle ──────────────────────────────────────────────────────────────

local function registerComposerSurface()
  for _, v in ipairs({
    { "SUN_ELEVATION", 0, "NUMBER" },
    { "SUN_AZIMUTH", 0, "NUMBER" },
    { "IS_DAYLIGHT", false, "BOOL" },
    { "DAY_PHASE", "unknown", "STRING" },
    { "NEXT_SUNRISE", "", "STRING" },
    { "NEXT_SUNSET", "", "STRING" },
    { "MINUTES_TO_SUNSET", 0, "NUMBER" },
    { "MINUTES_TO_SUNRISE", 0, "NUMBER" },
    { "SUN_ON_FACADE_1", false, "BOOL" },
    { "SUN_ON_FACADE_2", false, "BOOL" },
    { "SUN_ON_FACADE_3", false, "BOOL" },
    { "SUN_ON_FACADE_4", false, "BOOL" },
    { "LOCATION_SOURCE", "none", "STRING" },
  }) do
    pcall(function()
      C4:AddVariable(v[1], v[2], v[3], true)
    end)
  end
  local events = {
    { EVENT_GOLDEN, "Golden Hour Started", "The sun entered golden hour, morning or evening" },
    { EVENT_DAWN, "Civil Dawn", "Civil twilight began in the morning" },
    { EVENT_DUSK, "Civil Dusk", "The sun set into civil twilight" },
    { EVENT_LOCATION, "Location Changed", "The site coordinates changed" },
  }
  for i = 1, Engine.LIMITS.facades do
    events[#events + 1] = { facadeHitEvent(i), "Sun Hits Facade " .. i, "The sun started shining on facade " .. i }
    events[#events + 1] = { facadeLeftEvent(i), "Sun Leaves Facade " .. i, "The sun stopped shining on facade " .. i }
  end
  for _, e in ipairs(events) do
    pcall(function()
      C4:AddEvent(e[1], e[2], e[3])
    end)
  end
end

--- Director location changes (52 zip, 53 latitude, 54 longitude) re-resolve
--- the project location. Registered system-wide (device 0), as the Agent
--- does; an OS without RegisterSystemEvent still works from the hourly
--- re-resolve.
local function registerSystemEvents()
  if C4.RegisterSystemEvent == nil then
    return
  end
  for _, id in ipairs({ 52, 53, 54 }) do
    pcall(function()
      C4:RegisterSystemEvent(id, 0)
    end)
  end
end

local function onProjectLocationEvent()
  if gInitialized and tostring(Properties["Location Source"]) == "Control4 Project" then
    applyLocation("project location event")
  end
end
OSE.OnZipcodeChanged = onProjectLocationEvent
OSE.OnLatitudeChanged = onProjectLocationEvent
OSE.OnLongitudeChanged = onProjectLocationEvent

function OnDriverInit()
  --#ifdef DRIVERCENTRAL
  require("cloud-client-byte")
  C4:AllowExecute(false)
  --#else
  C4:AllowExecute(true)
  --#endif
  gInitialized = false
  log:setLogName("SolarPosition")
  log:setLogLevel(Properties["Log Level"])
  log:setLogMode(Properties["Log Mode"])
end

function OnDriverLateInit(reason)
  if not CheckMinimumVersion("Driver Status") then
    return
  end
  registerComposerSurface()
  for p, _ in pairs(Properties) do
    pcall(OnPropertyChanged, p)
  end

  gEngine = Engine.new()
  gEngine:setFacades(facadesFromProperties())

  license.setup({ sku = SKU })
  EC.SBOS_ENTITLEMENT = function(tParams)
    license.onEntitlement(tParams)
    reconcileLicence()
    paint()
  end

  registerSystemEvents()
  UpdateProperty("Driver Status", "Online")
  pcall(function()
    UpdateProperty("Driver Version", tostring(C4:GetDriverConfigInfo("version")))
  end)

  -- The first resolution is a state, not a change: resolve before the
  -- driver counts as initialised so Location Changed stays quiet.
  applyLocation("startup")
  gInitialized = true
  SetTimer(TICK_TIMER, 60 * ONE_SECOND, tick, true)
  -- Hourly: re-resolve the location (covers an OS without system events)
  -- and re-register the licence if the Agent arrived later.
  SetTimer(STATUS_TIMER, 60 * ONE_MINUTE, function()
    if tostring(Properties["Location Source"]) == "Control4 Project" then
      applyLocation("hourly")
    end
    pcall(license.register)
    paint()
  end, true)
  paint()
end

function OnDriverDestroyed()
  pcall(license.stop) -- the licence retry timer
  CancelTimer(TICK_TIMER)
  CancelTimer(STATUS_TIMER)
end

-- ─── Properties ─────────────────────────────────────────────────────────────

function OPC.Log_Level(value)
  log:setLogLevel(value)
  DEBUGPRINT = tostring(value):match("^5") ~= nil
end

function OPC.Log_Mode(value)
  log:setLogMode(value)
end

function OPC.Driver_Status()
  if not gInitialized then
    UpdateProperty("Driver Status", "Initializing", false)
  end
end

local function locationProperty()
  if gInitialized then
    applyLocation("property change")
  end
end
OPC.Location_Source = locationProperty
OPC.Latitude = locationProperty
OPC.Longitude = locationProperty

local function facadeProperty()
  if gInitialized then
    applyFacades()
  end
end
for i = 1, Engine.LIMITS.facades do
  OPC["Facade_" .. i .. "_Name"] = facadeProperty
  OPC["Facade_" .. i .. "_Azimuth"] = facadeProperty
  OPC["Facade_" .. i .. "_Width"] = facadeProperty
  OPC["Facade_" .. i .. "_Min_Elevation"] = facadeProperty
end

-- ─── Actions and commands ───────────────────────────────────────────────────

function EC.REGISTER_NOW()
  license.register()
end

function EC.REFRESH_STATUS()
  paint()
end

function EC.RECOMPUTE()
  tick()
end

function EC.RECOMPUTE_SUN()
  tick()
end

function EC.REDISCOVER_LOCATION()
  applyLocation("Composer action")
end

function EC.PRINT_STATUS()
  log:print("== Solar Position ==")
  log:print("  status: %s", solarStatus())
  log:print("  licence: %s", license.describe())
  log:print(
    "  location: %s",
    gLocation and string.format("%s (%s) %.4f, %.4f", gLocation.label, gLocation.source, gLocation.lat, gLocation.lon)
      or "unresolved"
  )
  if gLast then
    local p = gLast.position
    log:print(
      "  sun: elevation %.2f (geometric %.2f), azimuth %.2f, declination %.2f, hour angle %.2f, phase %s",
      p.elevation,
      p.geometric_elevation,
      p.azimuth,
      p.declination,
      p.hour_angle,
      gLast.phase
    )
    if gLast.solar then
      log:print(
        "  today: sunrise %s noon %s sunset %s; next sunrise %s next sunset %s (%s min)",
        fmtTime(gLast.solar.sunrise),
        fmtTime(gLast.solar.solarNoon),
        fmtTime(gLast.solar.sunset),
        fmtTime(gLast.solar.nextSunrise),
        fmtTime(gLast.solar.nextSunset),
        tostring(gLast.solar.minutesToSunset)
      )
    end
    for i = 1, Engine.LIMITS.facades do
      local f = gEngine.facades[i]
      if f then
        log:print(
          "  facade %d %s: heading %d width %d min elevation %d -> %s",
          i,
          f.name,
          f.azimuth,
          f.width,
          f.min_elevation,
          gLast.facades[i] and gLast.facades[i].lit and "sun" or "shade"
        )
      end
    end
  end
  log:print("  last error: %s", gLastError)
end

-- ─── Conditionals ───────────────────────────────────────────────────────────

function TC.IS_DAYLIGHT()
  return gLast ~= nil and gLast.is_daylight == true
end

function TC.IS_GOLDEN_HOUR()
  return gLast ~= nil and (gLast.phase == "golden_morning" or gLast.phase == "golden_evening")
end

for i = 1, Engine.LIMITS.facades do
  TC["SUN_ON_FACADE_" .. i] = function()
    return gLast ~= nil and gLast.facades[i] ~= nil and gLast.facades[i].lit == true
  end
end
