--- Lights and keypads: what to watch, and what a reading means.
---
--- ── WHY THIS IS PURE ────────────────────────────────────────────────────────
---
--- Same doctrine as rooms.lua and climateReading: the rules live in a module
--- with no C4 surface so the interesting cases — a dimmer that only reports a
--- level, a keypad that exposes nothing, a wattage that is text — are tested
--- directly against captured variable lists rather than through Director.
---
--- ── CANDIDATES, NOT FACTS ───────────────────────────────────────────────────
---
--- The lightv2 proxy documents its notifications (LIGHT_BRIGHTNESS_CHANGED,
--- BUTTON_ACTION — finding 7 in the plan), but notifications are proxy-to-
--- protocol traffic; what a third-party driver can SEE is device variables,
--- and nobody has measured which variable names real lights expose on this
--- project. So every name below is a CANDIDATE. The discovery walk ships each
--- matched device's full variable list to the catalogue, which is how the next
--- round replaces these guesses with what the project actually said — the same
--- loop that corrected the thermostat and sensor names before.
---
--- ── WATTS ───────────────────────────────────────────────────────────────────
---
--- Measured watts come ONLY from a wattage-named variable that parses as a
--- number. No rated-load arithmetic happens here: the driver reports what the
--- device says, and the platform decides whether to estimate from catalogue
--- data — an estimate is an analytics product, not a sensor reading, and mixing
--- the two in one field is how "300 W" stops meaning anything.

local Lights = {}

--- First value among candidate names. Case-sensitive exact match first, then
--- upper-cased match, because Control4 mixes "Brightness Percent" with
--- LIGHT_STATE style in one project.
local function firstOf(values, names)
  for _, name in ipairs(names) do
    if values[name] ~= nil then
      return values[name]
    end
    local upper = name:upper()
    if values[upper] ~= nil then
      return values[upper]
    end
  end
  return nil
end

-- Measured 2026-08-21 across 15 devices the first signature matched: real
-- lights carry "Brightness Percent" (×14) and LIGHT_STATE (×14); the other two
-- matches were T4 IN-WALL TOUCHPANELS — named "In-Wall", carrying bare
-- BRIGHTNESS at 41 and 97, which is their SCREEN brightness. They rendered as
-- two lit Living Room lights on a customer-facing card.
--
-- So bare BRIGHTNESS no longer QUALIFIES a device (it stays readable as a
-- level on devices that qualify some other way), and anything carrying
-- touchpanel vocabulary is refused outright. Fourth impostor this project has
-- produced: weather-as-thermostat, weather-as-keypad, panel-as-light — the
-- lesson is always that membership needs a positive signature AND a check for
-- a stronger identity.
local QUALIFYING_VARS = { "LIGHT_LEVEL", "LIGHT LEVEL", "Brightness Percent", "BRIGHTNESS_PERCENT" }
local LEVEL_VARS = { "LIGHT_LEVEL", "LIGHT LEVEL", "Brightness Percent", "BRIGHTNESS_PERCENT", "BRIGHTNESS" }
local STATE_VARS = { "LIGHT_STATE", "LIGHT STATE", "LIGHTSTATE" }
--- Vocabulary that identifies a TOUCHPANEL, whatever else the device carries.
local PANEL_VARS = { "SCREENSAVER_ENABLED", "DEVICE_SETTINGS", "DARK_MODE_SETTINGS", "PROXIMITY_SENSOR_ENABLED" }
local WATT_VARS = {
  "CURRENT_POWER",
  "POWER_CONSUMPTION",
  "ACTIVE_POWER",
  "WATTS",
  "WATTAGE",
  "POWER_USAGE",
  "ENERGY_USAGE",
}

--- Uppercase-keyed AND verbatim-keyed view of a variable list, so candidates
--- can match either way without every caller repeating the dance.
local function valueMap(vars)
  local values = {}
  for _, v in pairs(vars) do
    if type(v) == "table" and type(v.name) == "string" then
      values[v.name] = v.value
      values[v.name:upper()] = v.value
    end
  end
  return values
end

--- Whether this device is a light, and which variables to watch on it.
---
--- A device qualifies by exposing a light-level or light-state variable —
--- signature, never name, for the reason the sensor code learned the hard way:
--- installers name devices after rooms. A dimmer keypad qualifies as both a
--- light and a keypad, which is true.
---
--- @param vars table|nil Raw GetDeviceVariables result.
--- @return table|nil watch { [varId] = varName } for listener registration, or nil.
function Lights.signature(vars)
  if type(vars) ~= "table" then
    return nil
  end
  local values = valueMap(vars)
  -- A panel is a panel no matter what brightness it reports.
  if firstOf(values, PANEL_VARS) ~= nil then
    return nil
  end
  if firstOf(values, QUALIFYING_VARS) == nil and firstOf(values, STATE_VARS) == nil then
    return nil
  end

  local watch = {}
  local wanted = {}
  for _, list in ipairs({ LEVEL_VARS, STATE_VARS, WATT_VARS }) do
    for _, name in ipairs(list) do
      wanted[name:upper()] = true
    end
  end
  for varId, v in pairs(vars) do
    local id = tonumber(varId)
    if id ~= nil and type(v) == "table" and type(v.name) == "string" and wanted[v.name:upper()] then
      watch[id] = v.name
    end
  end
  return watch
end

--- Turns a light's variables into a reading.
---
--- @param vars table|nil Raw GetDeviceVariables result.
--- @return table|nil { on = boolean|nil, level = number|nil, watts = number|nil }
function Lights.reading(vars)
  if type(vars) ~= "table" then
    return nil
  end
  local values = valueMap(vars)

  local level = tonumber(firstOf(values, LEVEL_VARS))
  -- Levels above 100 mean a scale nobody has measured (0–255? deci-percent?).
  -- The truthful move is a nil level with on-ness preserved, not a guess that
  -- renders as "Light at 254%". On-ness IS defensible from an out-of-range
  -- level — 254 of anything is not off — so it is derived from the raw number
  -- BEFORE the unmeasurable value is discarded.
  local onFromLevel = nil
  if level ~= nil then
    onFromLevel = level > 0
  end
  if level ~= nil and (level < 0 or level > 100) then
    level = nil
  end

  local on = nil
  local stateRaw = firstOf(values, STATE_VARS)
  if stateRaw ~= nil then
    local s = tostring(stateRaw):lower()
    if s == "1" or s == "true" or s == "on" then
      on = true
    elseif s == "0" or s == "false" or s == "off" then
      on = false
    end
  end
  if on == nil then
    on = onFromLevel
  end

  local watts = tonumber(firstOf(values, WATT_VARS))
  if watts ~= nil and watts < 0 then
    watts = nil
  end
  -- A light that reports nothing readable is not a reading.
  if on == nil and level == nil and watts == nil then
    return nil
  end
  return { on = on, level = level, watts = watts }
end

--- Which variables to watch on a KEYPAD device.
---
--- Substring match, unlike the lights' exact candidates, because the keypad
--- proxy's notification vocabulary (KEYPAD_BUTTON_ACTION, CLICK_COUNT — the
--- documented names) may surface under per-driver variable names nobody has
--- enumerated. The match is what CASTS THE NET; every event forwards the
--- variable's real name verbatim, so the platform learns the true vocabulary
--- from the first press.
---
--- Returns nil rather than {} when nothing matches: "this keypad exposes no
--- button variables" is itself the measurement finding 7 says still needs
--- taking, and callers count it.
---
--- @param vars table|nil Raw GetDeviceVariables result.
--- @return table|nil watch { [varId] = varName }, or nil.
function Lights.keypadWatch(vars)
  if type(vars) ~= "table" then
    return nil
  end
  local watch, found = {}, false
  for varId, v in pairs(vars) do
    local id = tonumber(varId)
    local name = type(v) == "table" and type(v.name) == "string" and v.name:upper() or nil
    if id ~= nil and name ~= nil then
      -- WORD-boundary matching (Lua frontier patterns), measured into shape on
      -- 2026-08-21. The first net used substrings and its first real catch was
      -- mostly bycatch:
      --
      --   PRESSURE          the WEATHER DRIVER, via "PRESS" — a barometric
      --                     event on every change, filed as a keypad
      --   LASTACTIONTIME    via "ACTION" mid-word
      --   TRANSPORTS_BUTTONS a static capability list ("HOME,MENU"), plural
      --
      -- while the one genuine press was "Button 1" on a Halo Remote. Frontier
      -- patterns keep BUTTON/CLICK/PRESS/ACTION as whole words: "BUTTON 1" and
      -- "BUTTON_ACTION_3" match; PRESSURE, LASTACTIONTIME and BUTTONS do not.
      local isButton = name:find("%f[%w]BUTTON%f[%W]") ~= nil
        or name:find("%f[%w]CLICK%f[%W]") ~= nil
        or name:find("%f[%w]PRESS%f[%W]") ~= nil
        or name:find("%f[%w]ACTION%f[%W]") ~= nil
      if isButton then
        watch[id] = v.name
        found = true
      end
    end
  end
  if not found then
    return nil
  end
  return watch
end

return Lights
