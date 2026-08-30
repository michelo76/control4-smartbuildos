--- Bond device model: which Control4 functions a Bond device grows.
---
--- One Bond device can be SEVERAL Navigator devices — a ceiling fan with a
--- light is a fan child AND a light child, each on its own provider binding.
--- This module derives that function list, and it derives it from the
--- device's `actions[]` — the vendor's own guidance is that `type` is
--- cosmetic and Features (actions/state/properties) are the functional
--- truth. `type` only breaks ties where the action vocabulary is shared
--- (TurnOn belongs to fans, fireplaces, heaters and switches alike).
---
--- Pure functions only: this is shared by the gateway (binding creation,
--- provisioning) and the children (capability checks), and it is what the
--- tests grind without a driver loaded.

local M = {}

--- Function identifiers, stable protocol vocabulary — these ride bindings
--- (provider class BOND_<FN>), the child handshake and persist, so they are
--- append-only.
M.FUNCTIONS = {
  FAN = "FAN",
  LIGHT = "LIGHT",
  SHADE = "SHADE",
  FIREPLACE = "FIREPLACE",
  HEATER = "HEATER",
  GENERIC = "GENERIC",
  COLOR_LIGHT = "COLOR_LIGHT",
  -- Not derived from actions[]: assigned by the gateway from the
  -- /v2/sidekicks enumeration (keypads and Breeze weather sensors).
  KEYPAD = "KEYPAD",
  WEATHER = "WEATHER",
}

--- Binding class per function (provider side; children declare the same
--- class on their consumer connection).
---
--- SBOS_-prefixed ON PURPOSE: the official Bond driver suite
--- (driverworks_bond_*.c4z, Chowmain-built) already uses BOND_FAN,
--- BOND_LIGHT, BOND_BLIND, BOND_FIREPLACE and BOND_GENERIC as its
--- connection classes. A dealer's Drivers folder holding both suites is the
--- normal case, and sharing a class would let Composer bind their children
--- to our gateway and vice versa — the exact cross-suite mispairing the
--- UniFi Protect suite lived through before its "(SBOS)" rename.
M.BINDING_CLASSES = {
  FAN = "SBOS_BOND_FAN",
  LIGHT = "SBOS_BOND_LIGHT",
  SHADE = "SBOS_BOND_SHADE",
  FIREPLACE = "SBOS_BOND_FIREPLACE",
  HEATER = "SBOS_BOND_HEATER",
  GENERIC = "SBOS_BOND_GENERIC",
  COLOR_LIGHT = "SBOS_BOND_COLOR_LIGHT",
  KEYPAD = "SBOS_BOND_KEYPAD",
  WEATHER = "SBOS_BOND_WEATHER",
}

--- Turns an actions array into a lookup set.
--- @param actions string[]|nil The device's actions list.
--- @return table<string, boolean> set
function M.actionSet(actions)
  local set = {}
  for _, name in ipairs(actions or {}) do
    set[tostring(name)] = true
  end
  return set
end

--- Derives the function list for one device.
---
--- Order is deliberate: the list is also the provisioning order, and the
--- "primary" function (first entry) is the one that inherits the device's
--- bare name — the light on a fan is "<name> Light", never the reverse.
--- @param deviceType string|nil The Bond `type` (CF/FP/MS/…), cosmetic tiebreaker.
--- @param actions string[]|nil The device's actions list.
--- @return string[] functions Function identifiers, possibly empty.
function M.deriveFunctions(deviceType, actions)
  local has = M.actionSet(actions)
  local functions = {}
  local claimed = false

  -- A fan is anything that can set a speed — plus the single-speed CF whose
  -- whole vocabulary is TurnOn/TurnOff.
  if has.SetSpeed or has.IncreaseSpeed or (deviceType == "CF" and (has.TurnOn or has.TogglePower)) then
    table.insert(functions, M.FUNCTIONS.FAN)
    claimed = true
  end

  -- Shades: the OpenRaiseRetract vocabulary. Position alone never appears
  -- without Open/Close, but check both — actions are the truth.
  if has.Open or has.Close or has.ToggleOpen or has.SetPosition then
    table.insert(functions, M.FUNCTIONS.SHADE)
    claimed = true
  end

  -- Fireplaces: a flame level, or an FP whose only vocabulary is power.
  if has.SetFlame or has.IncreaseFlame or (deviceType == "FP" and (has.TurnOn or has.TogglePower)) then
    table.insert(functions, M.FUNCTIONS.FIREPLACE)
    claimed = true
  end

  -- The main light rides ALONGSIDE whatever the device otherwise is. A pure
  -- light device (LT, or a dimmer template) has only this. Full-color
  -- devices (Firefly — the Color feature's SetHSV) get the color child
  -- instead; the plain light child would waste the hardware.
  if has.SetHSV then
    table.insert(functions, M.FUNCTIONS.COLOR_LIGHT)
    claimed = true
  elseif has.TurnLightOn or has.ToggleLight then
    table.insert(functions, M.FUNCTIONS.LIGHT)
    claimed = true
  end

  -- Heaters with an adjustable heat level get the thermostat child (the
  -- 0-100 dial). An HT whose only vocabulary is power stays GENERIC — a
  -- thermostat UI over a device that cannot set a level is a lie.
  if has.SetHeat or has.IncreaseHeat then
    table.insert(functions, M.FUNCTIONS.HEATER)
    claimed = true
  end

  -- Anything else that can at least switch power: on/off heaters, bidets,
  -- generic templates, smart switches. One relay-ish child, no pretending.
  if not claimed and (has.TurnOn or has.TogglePower) then
    table.insert(functions, M.FUNCTIONS.GENERIC)
  end

  return functions
end

--- Human label for a function child, derived from the device name. The
--- primary function keeps the bare name; secondary functions get a suffix so
--- "Master Fan" and "Master Fan Light" sit next to each other in a project
--- tree without inventing names the dealer never typed.
--- @param name string The Bond device name.
--- @param fn string The function identifier.
--- @param isPrimary boolean Whether this is the device's first function.
--- @return string label
function M.childLabel(name, fn, isPrimary)
  name = tostring(name or "Bond Device")
  if isPrimary then
    return name
  end
  local suffixes = {
    LIGHT = " Light",
    COLOR_LIGHT = " Light",
    FAN = " Fan",
    SHADE = " Shade",
    FIREPLACE = " Fireplace",
    HEATER = " Heater",
    GENERIC = " Switch",
    KEYPAD = " Keypad",
    WEATHER = " Weather",
  }
  return name .. (suffixes[fn] or "")
end

return M
