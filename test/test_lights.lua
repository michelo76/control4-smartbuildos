-- Lights and keypads: signature discovery and reading normalisation.
--
-- Every rule here decides what renders beside a bulb icon on a customer
-- screen. The dangerous failures are all quiet ones: a wattage that is text, a
-- level in a scale nobody measured, a weather-style impostor. Tested against
-- constructed variable lists because no light on the real project has been
-- measured yet — these are the CANDIDATE rules, and the catalogue loop exists
-- to correct them.
--
-- Run from the driver root:
--   make test

local pass, fail = 0, 0
local function check(name, ok, detail)
  if ok then
    pass = pass + 1
    print(string.format("  ok   %s", name))
  else
    fail = fail + 1
    print(string.format("  FAIL %s%s", name, detail and ("  -> " .. tostring(detail)) or ""))
  end
end

package.path = "./src/?.lua;./src/?/init.lua;" .. package.path
local Lights = require("telemetry.lights")

local function vars(list)
  local out = {}
  for i, v in ipairs(list) do
    out[tostring(1000 + i)] = { name = v[1], value = v[2] }
  end
  return out
end

print("\n[1] Signature: what counts as a light")

check("a dimmer with LIGHT_LEVEL is a light", Lights.signature(vars({ { "LIGHT_LEVEL", "75" } })) ~= nil)
check("a switch with only LIGHT_STATE is a light", Lights.signature(vars({ { "LIGHT_STATE", "1" } })) ~= nil)
check(
  "'Brightness Percent' — mixed case, with a space — is recognised",
  Lights.signature(vars({ { "Brightness Percent", "40" } })) ~= nil
)
check("a thermostat is not a light", Lights.signature(vars({ { "TEMPERATURE_F", "72" } })) == nil)
check("an empty device is not a light", Lights.signature(vars({})) == nil)
check("garbage yields nil rather than throwing", Lights.signature("nonsense") == nil)

-- Verbatim from production 2026-08-21: a T4 In-Wall touchpanel, named
-- "In-Wall", whose bare BRIGHTNESS (its screen, at 41%) put two lit "lights"
-- in the Living Room on a customer-facing card.
local TOUCHPANEL = vars({
  { "BRIGHTNESS", "41" },
  { "SCREENSAVER_ENABLED", "1" },
  { "SCREENSAVER_TIMEOUT", "300" },
  { "PROXIMITY_SENSOR_ENABLED", "1" },
  { "DARK_MODE_SETTINGS", "<dark_mode><dm_enabled>false</dm_enabled></dark_mode>" },
})
check("a touchpanel is not a light, whatever its screen brightness", Lights.signature(TOUCHPANEL) == nil)
check("bare BRIGHTNESS alone no longer qualifies a device", Lights.signature(vars({ { "BRIGHTNESS", "97" } })) == nil)
check(
  "the 14 real lights' vocabulary still qualifies",
  Lights.signature(vars({ { "Brightness Percent", "0" }, { "LIGHT_STATE", "0" } })) ~= nil
)

local watch = Lights.signature(vars({ { "LIGHT_LEVEL", "75" }, { "CURRENT_POWER", "12" }, { "APP_NAME", "Hulu" } }))
local watched = 0
for _ in pairs(watch) do
  watched = watched + 1
end
check("the watch list carries level AND power, not unrelated vars", watched == 2, watched)

print("\n[2] Reading: on, level, watts")

local r = Lights.reading(vars({ { "LIGHT_LEVEL", "75" } }))
check("level 75 reads on at 75", r.on == true and r.level == 75, tostring(r.level))
r = Lights.reading(vars({ { "LIGHT_LEVEL", "0" } }))
check("level 0 reads off", r.on == false and r.level == 0)
r = Lights.reading(vars({ { "LIGHT_STATE", "0" }, { "LIGHT_LEVEL", "75" } }))
check("an explicit state var beats the level", r.on == false, tostring(r.on))
r = Lights.reading(vars({ { "LIGHT_LEVEL", "254" } }))
check(
  "a level in an unmeasured scale yields nil level, but 254 is not off",
  r ~= nil and r.level == nil and r.on == true,
  r and string.format("level=%s on=%s", tostring(r.level), tostring(r.on))
)

print("\n[3] Watts are measured or absent, never invented")

r = Lights.reading(vars({ { "LIGHT_LEVEL", "75" }, { "CURRENT_POWER", "12.5" } }))
check("a numeric wattage is carried", r.watts == 12.5, tostring(r.watts))
r = Lights.reading(vars({ { "LIGHT_LEVEL", "75" }, { "CURRENT_POWER", "unavailable" } }))
check("a text wattage is nil, not zero", r.watts == nil, tostring(r.watts))
r = Lights.reading(vars({ { "LIGHT_LEVEL", "75" }, { "WATTS", "-3" } }))
check("a negative wattage is rejected", r.watts == nil)
check("no readable values yields nil", Lights.reading(vars({ { "APP_NAME", "Hulu" } })) == nil)

print("\n[4] Keypad watch: cast the net, forward verbatim")

local kw = Lights.keypadWatch(vars({ { "BUTTON_ACTION_1", "0" }, { "LED_COLOR", "ff0000" }, { "APP_NAME", "x" } }))
check("button-named vars are watched", kw ~= nil and (function()
  for _, name in pairs(kw) do
    if name == "BUTTON_ACTION_1" then
      return true
    end
  end
  return false
end)())
check("unrelated vars are not", kw ~= nil and (function()
  for _, name in pairs(kw) do
    if name == "APP_NAME" or name == "LED_COLOR" then
      return false
    end
  end
  return true
end)())
check(
  "a keypad exposing NO button vars answers nil — that absence is the measurement",
  Lights.keypadWatch(vars({ { "BATTERY_LEVEL", "80" } })) == nil
)

-- The first real catch, verbatim from production 2026-08-21. The substring net
-- filed the WEATHER DRIVER as a keypad via PRESSURE and shipped a barometric
-- reading as a press; these pin the word-boundary net against that catch.
check(
  "'Button 1' — the real Halo Remote press — is watched",
  Lights.keypadWatch(vars({ { "Button 1", "" } })) ~= nil
)
check("PRESSURE is weather, not a press", Lights.keypadWatch(vars({ { "PRESSURE", "30.03" } })) == nil)
check("LastActionTime is not an action", Lights.keypadWatch(vars({ { "LastActionTime", "0" } })) == nil)
check(
  "TRANSPORTS_BUTTONS — a static capability list — is not a button",
  Lights.keypadWatch(vars({ { "TRANSPORTS_BUTTONS", "HOME,MENU" } })) == nil
)
check("garbage yields nil rather than throwing", Lights.keypadWatch(42) == nil)

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
