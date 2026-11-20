-- AI Core: the live device read's filter (src/aicore/devicestate.lua, pure).
-- Fixtures are SYNTHETIC variable lists shaped like the Agent's candidate
-- names (driver.lua sensorReading / looksLikeThermostat, telemetry/lights);
-- no physical controller has produced any of them.
--
--   [1]  class from the live signature, one fixture per class
--   [2]  A: secret and personal names dropped in every scope, counted
--   [3]  B: values that are not short plain scalars dropped whole, counted
--   [4]  C: occupancy names dropped in scope system only
--   [5]  E: restricted classes in scope system: restricted_class, ZERO variables
--   [6]  F: allow-lists — lock and security (full), every class answered in
--        system (KI-68: a climate sensor's door flag never leaves)
--   [7]  cameras refused in both scopes
--   [8]  bounds: 40 variables / 4,096 bytes, dropped whole, never cut
--   [9]  G: TEMPERATURE passed raw; narrowing; typed outcomes
--  [10]  the body shapes (closed keys, seven counters, no dropped name)
--  [11]  not_allowed: what an allow-list withheld, counted, never named (KI-67)

require("drivers-common-public.global.lib") -- the JSON encoder's number formatter
JSON = require("JSON")
local D = require("aicore.devicestate")

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

--- { {name, value}, … } → a GetDeviceVariables-shaped table (id → entry).
local function vars(list)
  local out = {}
  for i, nv in ipairs(list) do
    out[tostring(1000 + i)] = { name = nv[1], value = nv[2], readonly = "False" }
  end
  return out
end

local REF = "0d6f9a2e-5b1c-4c8e-9f00-123456789abc"
local function read(v, scope, file, wanted)
  return D.result({
    request_id = "aic-1",
    state_ref = REF,
    device_id = 120,
    scope = scope,
    wanted = wanted,
    read_ok = true,
    vars = v,
    file = file,
    read_at = 1800000000,
  })
end
local function names(body)
  local out = {}
  for _, e in ipairs(body.variables or {}) do
    out[e.name] = e.value
  end
  return out
end
local function count(t)
  local n = 0
  for _ in pairs(t) do
    n = n + 1
  end
  return n
end

-- ── fixtures, one per class ────────────────────────────────────────────────
local FX = {
  thermostat = vars({
    { "HVAC_MODE", "Heat" },
    { "HVAC_STATE", "Stage 1 Heat" },
    { "TEMPERATURE_F", "71" },
    { "TEMPERATURE", "215" }, -- deci-Celsius on thermostats: passed raw
    { "HEAT_SETPOINT_F", "68" },
    { "HUMIDITY", "45" },
    { "AWAY_MODE", "Off" }, -- occupancy name
    { "LAST_CHANGED_BY", "schedule" }, -- occupancy name (LAST)
    { "Battery Status", "Good" },
  }),
  climate_sensor = vars({ { "TEMPERATURE_F", "55" }, { "HUMIDITY", "61" }, { "SCALE", "F" } }),
  light = vars({ { "LIGHT_STATE", "1" }, { "Brightness Percent", "75" }, { "CURRENT_POWER", "12" } }),
  leak = vars({ { "LEAK", "0" }, { "BATTERY_LEVEL", "80" } }),
  power = vars({ { "ON_BATTERY", "false" }, { "AC_POWER", "true" } }),
  battery = vars({ { "BATTERY_LEVEL", "54" }, { "LINK_QUALITY", "80" } }),
  lock = vars({
    { "LOCK_STATUS", "Locked" },
    { "BATTERY_LEVEL", "77" },
    { "RSSI", "-60" },
    { "LAST_USER", "Resident One" },
    { "USER_CODE_1", "1234" },
    { "Slot 3 Label", "Nanny" }, -- personal data under an unpredictable name
    { "AUTO_LOCK_TIME", "30" },
  }),
  security = vars({
    { "PARTITION_STATE", "Armed Away" },
    { "TROUBLE_STATE", "None" },
    { "BATTERY_LOW", "false" },
    { "ZONE_1_NAME", "Back door" },
    { "ZONE_1_STATE", "Closed" },
    { "ARM_CODE", "4321" },
  }),
  opening = vars({ { "GARAGE_STATE", "Closed" }, { "BATTERY_LEVEL", "90" } }),
  motion = vars({ { "MOTION_STATE", "Clear" }, { "BATTERY_LEVEL", "90" } }),
  contact = vars({ { "CONTACT_STATE", "Closed" }, { "BATTERY_LEVEL", "90" } }),
  relay = vars({ { "RELAY_STATE", "0" }, { "BATTERY_LEVEL", "90" } }),
  -- Two climate sensors carrying a name no list knows (KI-68).
  fridge = vars({
    { "Temperature Probe", "54" },
    { "HUMIDITY", "61" },
    { "SCALE", "FAHRENHEIT" },
    { "DOOR_AJAR", "1" },
  }),
  room_sensor = vars({
    { "TEMPERATURE_F", "70" },
    { "HUMIDITY", "40" },
    { "OCCUPANCY_SENSED", "1" },
    { "IN_USE", "1" },
  }),
  unknown = vars({
    { "CURRENT_INPUT", "HDMI 1" },
    { "VOLUME", "30" },
    { "ONLINE", "true" },
    { "COMM_STATUS", "OK" },
    { "BATTERY_VOLTAGE", "3.0" },
    { "LINK_QUALITY", "88" },
  }),
}

print("[1] class from the live signature")
for _, c in ipairs({
  "thermostat",
  "climate_sensor",
  "light",
  "leak",
  "power",
  "battery",
  "lock",
  "security",
  "opening",
  "motion",
  "contact",
  "relay",
  "unknown",
}) do
  check("fixture → " .. c, D.classify(FX[c], "generic.c4z") == c, D.classify(FX[c], "generic.c4z"))
end
check("a camera by driver file", D.classify(FX.battery, "uniview_camera.c4z") == "camera")
check("a camera by driver file (doorbell)", D.classify(FX.climate_sensor, "ring_doorbell.c4z") == "camera")
check("a camera by driver file (nvr)", D.classify(FX.unknown, "hikvision_nvr.c4z") == "camera")
check("a camera by a STREAM variable", D.classify(vars({ { "MAIN_STREAM_URL", "x" } }), "x.c4z") == "camera")
check("a camera by a SNAPSHOT variable", D.classify(vars({ { "SnapshotPath", "x" } }), "x.c4z") == "camera")
check("a camera by AVAILABLE_CAMERAS", D.classify(vars({ { "AVAILABLE_CAMERAS", "<x/>" } }), "x.c4z") == "camera")
check("a camera outranks a lock (most restrictive first)", D.classify(FX.lock, "doorbell_lock_combo.c4z") == "camera")
check(
  "a lock outranks its contact and battery",
  D.classify(vars({ { "CONTACT_STATE", "Closed" }, { "LOCK_STATE", "1" }, { "BATTERY_LEVEL", "5" } }), "x") == "lock"
)
check(
  "a signature name with an EMPTY value still classifies (fail closed)",
  D.classify(vars({ { "LOCK_STATUS", "" }, { "TEMPERATURE_F", "70" } }), "x") == "lock"
)
check(
  "a touch panel's bare BRIGHTNESS is not a light",
  D.classify(vars({ { "BRIGHTNESS", "41" }, { "SCREENSAVER_ENABLED", "1" } }), "x") == "unknown"
)
check(
  "the weather guard: HVAC_MODES_LIST WARN is not a thermostat (TEMPERATURE_F → climate_sensor)",
  D.classify(vars({ { "HVAC_MODES_LIST", "WARNING" }, { "HVAC_MODE", "Off" }, { "TEMPERATURE_F", "60" } }), "x")
    == "climate_sensor"
)
check(
  "the V1 thermostat namespace",
  D.classify(vars({ { "V1 TEMPERATURE", "70" }, { "V1 HVACMODES", "x" } }), "x") == "thermostat"
)
check("names are case-insensitive", D.classify(vars({ { "lock_status", "1" } }), "x") == "lock")
check(
  "names match joined: LockStatus is LOCK_STATUS (fail closed)",
  D.classify(vars({ { "LockStatus", "1" } }), "x") == "lock"
)
check(
  "names match joined: Garage-State is GARAGE_STATE",
  D.classify(vars({ { "Garage-State", "1" } }), "x") == "opening"
)
check("no variables → unknown", D.classify({}, "x") == "unknown")

print("[2] A: secret and personal names, every scope")
local SPEC_TOKENS_SECRET = { "PIN", "CODE", "CODES", "KEY", "KEYS" }
local SPEC_TOKENS_PERSONAL = {
  "USER",
  "USERS",
  "USERNAME",
  "LOGIN",
  "ACCOUNT",
  "OWNER",
  "GUEST",
  "PERSON",
  "NAME",
  "EMAIL",
  "MAIL",
  "PHONE",
  "MOBILE",
  "SMS",
  "CONTACT",
  "ADDRESS",
  "STREET",
  "CITY",
  "ZIP",
  "POSTAL",
  "LATITUDE",
  "LONGITUDE",
  "GPS",
  "LOCATION",
  "URL",
  "URI",
  "HOST",
  "IP",
  "MAC",
  "SSID",
  "WIFI",
  "SERIAL",
  "STREAM",
  "RTSP",
  "SNAPSHOT",
  "CAMERA",
  "HISTORY",
  "LOG",
}
local SPEC_FRAGMENTS = {
  "USERCODE",
  "ACCESSCODE",
  "PINCODE",
  "PASSCODE",
  "PASSWORD",
  "PASSWD",
  "TOKEN",
  "SECRET",
  "APIKEY",
  "DISARMCODE",
  "ARMCODE",
  "KEYCODE",
  "LOCKCODE",
  "CREDENTIAL",
  "PASSPHRASE",
  "PRIVATEKEY",
  "AUTH",
  "BEARER",
  "SESSION",
  "COOKIE",
  "CERT",
}
for _, scope in ipairs({ "system", "full" }) do
  for _, t in ipairs(SPEC_TOKENS_SECRET) do
    local name = "SLOT_" .. t
    local b = read(vars({ { "BATTERY_LEVEL", "50" }, { name, "1" } }), scope)
    check(
      scope .. ": token " .. t .. " (" .. name .. ") dropped, counted secret",
      b.status == "completed" and names(b)[name] == nil and b.omitted.secret == 1 and names(b).BATTERY_LEVEL == "50"
    )
  end
  for _, t in ipairs(SPEC_TOKENS_PERSONAL) do
    local name = "SLOT_" .. t
    local b = read(vars({ { "BATTERY_LEVEL", "50" }, { name, "1" } }), scope)
    if t == "STREAM" or t == "SNAPSHOT" then
      -- Such a name also makes the device a camera: refused whole.
      check(
        scope .. ": token " .. t .. " is personal, and the device is refused as a camera",
        D.deniedName(name) == "personal" and b.status == "failed" and b.reason == "camera_not_supported"
      )
    else
      check(
        scope .. ": token " .. t .. " dropped, counted personal",
        b.status == "completed" and names(b)[name] == nil and b.omitted.personal == 1
      )
    end
  end
  for _, f in ipairs(SPEC_FRAGMENTS) do
    local name = "X" .. f:lower() .. "2"
    local b = read(vars({ { "BATTERY_LEVEL", "50" }, { name, "1" } }), scope)
    check(
      scope .. ": fragment " .. f .. " (" .. name .. ") dropped, counted secret",
      b.status == "completed" and names(b)[name] == nil and b.omitted.secret == 1
    )
  end
end
check("the secret fixture: a lock PIN slot never leaves (deniedName)", D.deniedName("Lock PIN 3") == "secret")
check("PIN is a whole token, not a substring: PINNED_FAVOURITE passes A", D.deniedName("PINNED_FAVOURITE") == nil)
check("camelCase cannot hide a token: OwnerName", D.deniedName("OwnerName") == "personal")
check("a digit cannot hide a token: Pin1", D.deniedName("Pin1") == "secret")
check("CONTACT_STATE is a sensor, not personal data", D.deniedName("CONTACT_STATE") == nil)
check("Contact State (space) is a sensor too", D.deniedName("Contact State") == nil)
check("ContactState (camel) is a sensor too", D.deniedName("ContactState") == nil)
check("EMERGENCY_CONTACT is personal", D.deniedName("EMERGENCY_CONTACT") == "personal")
check("CONTACT_NUMBER is personal", D.deniedName("CONTACT_NUMBER") == "personal")
check("TEMPERATURE_F passes A", D.deniedName("TEMPERATURE_F") == nil)
check("Brightness Percent passes A", D.deniedName("Brightness Percent") == nil)
for _, extra in ipairs({ "PWD", "PASS", "OTP", "NONCE", "JWT", "HMAC" }) do
  check("addition: token " .. extra .. " is secret", D.deniedName("X_" .. extra) == "secret")
end
for _, extra in ipairs({ "FIRSTNAME", "LASTNAME", "HOSTNAME", "IPADDRESS", "MACADDRESS", "ZIPCODE", "PHONENUMBER" }) do
  check("addition: token " .. extra .. " is personal", D.deniedName(extra) == "personal")
end
do
  local FR = require("flightrecorder.config")
  local mine = {}
  for _, f in ipairs(D.SECRET_FRAGMENTS) do
    mine[f] = true
  end
  local missing = {}
  for _, f in ipairs(FR.FIXED_EXCLUSIONS) do
    if not mine[f] then
      missing[#missing + 1] = f
    end
  end
  check(
    "every Flight Recorder FIXED_EXCLUSIONS fragment is a secret fragment here",
    #FR.FIXED_EXCLUSIONS >= 14 and #missing == 0,
    table.concat(missing, ",")
  )
end

print("[3] B: values that are not short plain scalars")
local BAD = {
  { "a table", { a = 1 }, "non_scalar" },
  { "NaN", 0 / 0, "non_scalar" },
  { "infinity", math.huge, "non_scalar" },
  { "65 bytes", string.rep("a", 65), "too_long" },
  -- review (UTF-8 cut): a multi-byte character across the 64-byte bound is
  -- never cut into; the value is dropped whole
  { "65 bytes ending in a 2-byte character", string.rep("a b ", 15) .. "abc" .. "é", "too_long" },
  { "markup <", "<zone id=1/>", "non_scalar" },
  { "structure {", "{a}", "non_scalar" },
  { "structure [", "[1]", "non_scalar" },
  { "a newline", "a\nb", "non_scalar" },
  { "a tab", "a\tb", "non_scalar" },
  { "a C1 control", "a\194\133b", "non_scalar" },
  { "a bidi override", "\226\128\174abc", "non_scalar" },
  { "a bidi isolate", "\226\129\166abc", "non_scalar" },
  { "a URL", "rtsp://cam.local/live", "personal" },
  { "www.", "see www.example.com", "personal" },
  { "an e-mail", "jane@example.com", "personal" },
  { "IPv4", "192.168.1.20", "personal" },
  { "MAC", "AA:BB:CC:DD:EE:FF", "personal" },
  { "MAC with dashes", "aa-bb-cc-dd-ee-ff", "personal" },
  { "a phone", "+1 (555) 123-4567", "personal" },
  { "a phone without +", "555 123 4567", "personal" },
  { "a token shape", "AbCdEfGhIjKlMnOpQrSt", "secret" },
  { "a base64 key", "dGhpcyBpcyBhIHNlY3JldA==", "secret" },
}
for _, c in ipairs(BAD) do
  local b = read(vars({ { "BATTERY_LEVEL", "50" }, { "SOME_VALUE", c[2] } }), "full")
  check(
    "dropped: " .. c[1] .. " (" .. c[3] .. ")",
    b.status == "completed" and names(b).SOME_VALUE == nil and b.omitted[c[3]] == 1 and D.omittedTotal(b.omitted) == 1,
    JSON:encode(b.omitted)
  )
end
local GOOD = {
  { "a plain whole number of 7 digits", "1234567" },
  { "a negative decimal", "-12.5" },
  { "a word", "Locked" },
  { "an empty string", "" },
  { "64 bytes exactly", string.rep("ab ", 21) .. "c" },
  { "a number", 42 },
  { "a boolean", true },
  { "a 19-character word", "ABCDEFGHIJKLMNOPQRS" },
}
for _, c in ipairs(GOOD) do
  local b = read(vars({ { "BATTERY_LEVEL", "50" }, { "SOME_VALUE", c[2] } }), "full")
  check("kept as returned: " .. c[1], b.status == "completed" and names(b).SOME_VALUE == c[2])
end
do
  -- The URL-tail fixture: clean for its first 64 bytes, a credential URL
  -- after. Dropped WHOLE; a cut would have sent the head.
  -- (its head is plain words, so a cut head would pass every other rule)
  local tail = "Status OK " .. string.rep("ab ", 20) .. "http://user:pw@cam.local/?token=abc"
  local b = read(vars({ { "BATTERY_LEVEL", "50" }, { "STATUS_TEXT", tail } }), "full")
  check(
    "the URL-tail fixture: dropped whole (too_long), no part of it sent",
    b.status == "completed"
      and names(b).STATUS_TEXT == nil
      and b.omitted.too_long == 1
      and not JSON:encode(b):find("Status OK", 1, true),
    JSON:encode(b.variables)
  )
  local longName = string.rep("N", 49)
  local b2 = read(vars({ { "BATTERY_LEVEL", "50" }, { longName, "1" } }), "full")
  check("a name over 48 bytes is dropped whole (too_long)", names(b2)[longName] == nil and b2.omitted.too_long == 1)
end

print("[4] C: occupancy names, scope system only")
for _, t in ipairs(D.OCCUPANCY_TOKENS) do
  local name = "X_" .. t
  local sys = read(vars({ { "BATTERY_LEVEL", "50" }, { name, "1" } }), "system")
  local full = read(vars({ { "BATTERY_LEVEL", "50" }, { name, "1" } }), "full")
  check(
    t .. ": dropped in system (occupancy), kept in full",
    names(sys)[name] == nil and sys.omitted.occupancy == 1 and names(full)[name] == "1"
  )
end
do
  local sys = read(FX.thermostat, "system")
  local full = read(FX.thermostat, "full")
  check(
    "thermostat, system: AWAY_MODE and LAST_CHANGED_BY dropped, the rest kept",
    sys.status == "completed"
      and names(sys).AWAY_MODE == nil
      and names(sys).LAST_CHANGED_BY == nil
      and sys.omitted.occupancy == 2
      and names(sys).TEMPERATURE_F == "71"
      and names(sys).HVAC_MODE == "Heat",
    JSON:encode(sys.omitted)
  )
  check(
    "thermostat, full: the occupancy names are kept",
    full.status == "completed" and names(full).AWAY_MODE == "Off" and full.omitted.occupancy == 0
  )
  check("thermostat is not restricted", sys.device.class == "thermostat" and sys.device.restricted == false)
end

print("[5] E: restricted classes in scope system — refused, ZERO variables")
for _, c in ipairs({ "lock", "security", "opening", "motion", "contact", "relay", "light" }) do
  local b = read(FX[c], "system")
  local raw = JSON:encode(b)
  check(
    c .. " (system): failed restricted_class, error not_permitted, no variables and no counts in the body",
    b.status == "failed"
      and b.reason == "restricted_class"
      and b.error_code == "not_permitted"
      and b.variables == nil
      and b.omitted == nil
      and b.device.class == c
      and b.device.restricted == true
      and not raw:find("BATTERY", 1, true)
      and not raw:find('"value"', 1, true),
    raw
  )
end
check(
  "D.refused: thermostat / climate / leak / power / battery answer in system",
  (function()
    for _, c in ipairs({ "thermostat", "climate_sensor", "leak", "power", "battery" }) do
      if D.refused(c, "system") then
        return false
      end
    end
    return true
  end)()
)
check("D.refused: unknown answers (allow-list) in system", not D.refused("unknown", "system"))

print("[6] F: allow-lists")
do
  local b = read(FX.lock, "full")
  local n = names(b)
  check(
    "lock (full): only LOCK_STATUS, BATTERY_LEVEL, RSSI",
    b.status == "completed"
      and count(n) == 3
      and n.LOCK_STATUS == "Locked"
      and n.BATTERY_LEVEL == "77"
      and n.RSSI == "-60",
    JSON:encode(b.variables)
  )
  check(
    "lock (full): user code (secret) and last user (personal) counted; AUTO_LOCK_TIME and the slot label not sent (not_allowed 2)",
    b.omitted.secret == 1
      and b.omitted.personal == 1
      and b.omitted.not_allowed == 2
      and n.AUTO_LOCK_TIME == nil
      and n["Slot 3 Label"] == nil,
    JSON:encode(b.omitted)
  )
  check("lock (full): class lock, restricted true", b.device.class == "lock" and b.device.restricted == true)
  local s = read(FX.security, "full")
  local sn = names(s)
  check(
    "security (full): PARTITION_STATE, TROUBLE_STATE, BATTERY_LOW only; zone name and arm code never",
    s.status == "completed"
      and count(sn) == 3
      and sn.PARTITION_STATE == "Armed Away"
      and sn.TROUBLE_STATE == "None"
      and sn.BATTERY_LOW == "false"
      and s.omitted.secret == 1
      and s.omitted.personal == 1
      and s.omitted.not_allowed == 1,
    JSON:encode(s.variables) .. JSON:encode(s.omitted)
  )
  local u = read(FX.unknown, "system")
  local un = names(u)
  check(
    "unknown (system): only ONLINE, COMM_STATUS, BATTERY_VOLTAGE, LINK_QUALITY; restricted false",
    u.status == "completed"
      and count(un) == 4
      and un.ONLINE == "true"
      and un.COMM_STATUS == "OK"
      and un.BATTERY_VOLTAGE == "3.0"
      and un.LINK_QUALITY == "88"
      and u.device.class == "unknown"
      and u.device.restricted == false
      and u.omitted.not_allowed == 2,
    JSON:encode(u.variables)
  )
  -- KI-68 (closed): a climate_sensor in scope system gets the SAME allow-list
  -- as an unknown device. A wine fridge's door flag, which no list knows,
  -- never reaches the touchscreen; in scope full it is unchanged.
  local fridge = read(FX.fridge, "system")
  local fn = names(fridge)
  check(
    "the wine fridge (system): climate_sensor, temperature, humidity and SCALE answer",
    fridge.status == "completed"
      and fridge.device.class == "climate_sensor"
      and fridge.device.restricted == false
      and fn["Temperature Probe"] == "54"
      and fn.HUMIDITY == "61"
      and fn.SCALE == "FAHRENHEIT",
    JSON:encode(fridge)
  )
  check(
    "the wine fridge (system): DOOR_AJAR is NOT sent (outside the allow-list)",
    fn.DOOR_AJAR == nil
      and count(fn) == 3
      and fridge.omitted.not_allowed == 1
      and not JSON:encode(fridge):find("DOOR", 1, true),
    JSON:encode(fridge.variables)
  )
  local fridgeFull = read(FX.fridge, "full")
  check(
    "the wine fridge (full): unchanged, the deny-lists only (DOOR_AJAR kept)",
    fridgeFull.status == "completed" and names(fridgeFull).DOOR_AJAR == "1" and count(names(fridgeFull)) == 4
  )
  local base = table.concat(D.ALLOW.unknown, ",")
  check(
    "the base allow-list is exactly the reviewed 11 (SCALE the only round-two addition)",
    base == "TEMPERATURE*,HUMIDITY*,SCALE,BATTERY*,LOWBATTERY,LINKQUALITY,LQI,RSSI,ONLINE,CONNECTED,COMM*STATUS",
    base
  )
  local occ = read(FX.room_sensor, "system")
  local on = names(occ)
  check(
    "the room sensor (system): climate_sensor; temperature and humidity only",
    occ.status == "completed"
      and occ.device.class == "climate_sensor"
      and count(on) == 2
      and on.TEMPERATURE_F == "70"
      and on.HUMIDITY == "40",
    JSON:encode(occ.variables)
  )
  check(
    "the room sensor (system): neither occupancy flag sent (OCCUPANCY_SENSED by C, IN_USE by the allow-list)",
    on.OCCUPANCY_SENSED == nil and on.IN_USE == nil and occ.omitted.occupancy == 1 and occ.omitted.not_allowed == 1,
    JSON:encode(occ.omitted)
  )
  check(
    "the room sensor (full): unchanged (both flags kept)",
    names(read(FX.room_sensor, "full")).IN_USE == "1" and names(read(FX.room_sensor, "full")).OCCUPANCY_SENSED == "1"
  )
  -- The same fail-closed rule for every other class answered in system.
  for _, c in ipairs({ "thermostat", "leak", "power", "battery", "climate_sensor", "unknown" }) do
    local v = {}
    for id, e in pairs(FX[c]) do
      v[id] = e
    end
    v["9999"] = { name = "DOOR_AJAR", value = "1", readonly = "False" }
    local sys, full = read(v, "system"), read(v, "full")
    check(
      c .. " (system): an unreviewed DOOR_AJAR is not sent; (full): it is",
      sys.status == "completed"
        and sys.device.class == c
        and names(sys).DOOR_AJAR == nil
        and sys.omitted.not_allowed >= 1
        and full.status == "completed"
        and names(full).DOOR_AJAR == "1"
        and full.omitted.not_allowed == 0,
      JSON:encode(sys.variables)
    )
  end
  check(
    "every class answered in system has an allow-list (none falls to deny-lists only)",
    (function()
      for _, c in ipairs(D.CLASSES) do
        if not D.refused(c, "system") and D.allowList(c, "system") == nil then
          return false
        end
      end
      return true
    end)()
  )
  check(
    "a class with no ALLOW_SYSTEM entry gets the base list (fail closed)",
    D.allowList("a_class_added_later", "system") == D.ALLOW.unknown
  )
  check("climate_sensor's system list IS the unknown list", D.allowList("climate_sensor", "system") == D.ALLOW.unknown)
  check(
    "full scope: allow-lists for lock and security only",
    D.allowList("lock", "full") ~= nil
      and D.allowList("security", "full") ~= nil
      and D.allowList("thermostat", "full") == nil
      and D.allowList("climate_sensor", "full") == nil
      and D.allowList("unknown", "full") == nil
  )
  local uf = read(FX.unknown, "full")
  check(
    "unknown (full): the deny-lists only (CURRENT_INPUT kept); restricted true",
    uf.status == "completed" and names(uf).CURRENT_INPUT == "HDMI 1" and uf.device.restricted == true
  )
  for _, c in ipairs({ "opening", "motion", "contact", "relay", "light" }) do
    local f = read(FX[c], "full")
    check(
      c .. " (full): answered with the deny-lists, restricted true",
      f.status == "completed" and count(names(f)) >= 2 and f.device.class == c and f.device.restricted == true
    )
  end
  check("the allow-list matcher: COMM*STATUS", D._allowed({ "COMM*STATUS" }, "COMM_LINK_STATUS"))
  check("the allow-list matcher: exact LQI is not LQI_RAW", not D._allowed({ "LQI" }, "LQI_RAW"))
end

print("[7] cameras: refused in both scopes")
for _, scope in ipairs({ "system", "full" }) do
  local b = read(vars({ { "MAIN_STREAM_URL", "rtsp://x" }, { "BATTERY_LEVEL", "9" } }), scope, "cam.c4z")
  check(
    "camera (" .. scope .. "): failed camera_not_supported, no variables",
    b.status == "failed"
      and b.reason == "camera_not_supported"
      and b.error_code == "unsupported"
      and b.variables == nil
      and b.device.class == "camera"
      and not JSON:encode(b):find("rtsp", 1, true)
  )
end

print("[8] bounds: 40 variables, 4,096 bytes, dropped whole")
do
  local many = {}
  for i = 1, 60 do
    many[i] = { string.format("TEMPERATURE_%02d", i), tostring(i) }
  end
  local b = read(vars(many), "full")
  check(
    "60 small variables: 40 kept, 20 over_limit",
    b.status == "completed" and #b.variables == 40 and b.omitted.over_limit == 20,
    #b.variables
  )
  local big = {}
  for i = 1, 40 do
    big[i] = { string.format("TEMPERATURE_%036d", i), string.rep(string.char(65 + (i % 26)) .. "b ", 21) .. "c" }
  end
  local bb = read(vars(big), "full")
  local raw = JSON:encode(bb.variables)
  local whole = true
  for _, e in ipairs(bb.variables) do
    if #e.value ~= 64 then
      whole = false
    end
  end
  check(
    "40 variables of 48-byte names and 64-byte values: cut by bytes, each kept one whole",
    bb.status == "completed" and #bb.variables < 40 and #bb.variables + bb.omitted.over_limit == 40 and whole,
    #bb.variables .. " kept, " .. bb.omitted.over_limit .. " over"
  )
  check("the variables JSON stays within 4,096 bytes", #raw <= D.LIMITS.variables_bytes, #raw)
  check("the whole body stays well under the 16 KB cloud body", #JSON:encode(bb) < 8 * 1024, #JSON:encode(bb))
  local quotes = {}
  for i = 1, 40 do
    quotes[i] = { string.format("HUMIDITY_%02d", i), string.rep('"\\', 32) }
  end
  local q = read(vars(quotes), "full")
  local qraw = JSON:encode(q.variables)
  check("escaped values: the estimate still bounds the real JSON", #qraw <= D.LIMITS.variables_bytes, #qraw)
  local utf = {}
  for i = 1, 40 do
    utf[i] = { string.format("HUMIDITY_%02d", i), string.rep("é", 32) }
  end
  local u = read(vars(utf), "full")
  check("non-ASCII values: the real JSON stays bounded", #JSON:encode(u.variables) <= D.LIMITS.variables_bytes)
end

print("[9] G: raw values; narrowing; typed outcomes")
do
  local full = read(FX.thermostat, "full")
  check("TEMPERATURE passed raw (deci-Celsius, unconverted)", names(full).TEMPERATURE == "215")
  check("TEMPERATURE_F as named", names(full).TEMPERATURE_F == "71")
  local narrowed = read(FX.thermostat, "system", nil, { "temperature_f", "HUMIDITY", "AWAY_MODE", "NOPE" })
  local n = names(narrowed)
  check(
    "narrowing (case-insensitive): only the asked names; an occupancy one still dropped and counted",
    count(n) == 2 and n.TEMPERATURE_F == "71" and n.HUMIDITY == "45" and narrowed.omitted.occupancy == 1,
    JSON:encode(narrowed.variables)
  )
  local asked = read(vars({ { "USER_CODE_1", "1234" }, { "BATTERY_LEVEL", "5" } }), "full", nil, { "USER_CODE_1" })
  check(
    "narrowing to a secret name: dropped, counted, completed with no variable",
    asked.status == "completed"
      and #asked.variables == 0
      and asked.omitted.secret == 1
      and JSON:encode(asked):find('"variables":%[%]') ~= nil,
    JSON:encode(asked)
  )
  local function outcome(over)
    local input = {
      request_id = "aic-2",
      state_ref = REF,
      device_id = 7,
      scope = "full",
      read_ok = true,
      vars = FX.battery,
      read_at = 1800000000,
    }
    for k, v in pairs(over) do
      input[k] = v
    end
    if over.vars == false then
      input.vars = nil
    end
    return D.result(input)
  end
  local cases = {
    { "not_licensed", { reason = "not_licensed", read_at = false }, "not_permitted", false },
    { "busy", { reason = "busy", read_at = false }, "rate_limited", false },
    { "not_found", { reason = "not_found", read_at = false }, "unknown_target", false },
    { "read_failed", { read_ok = false, vars = "boom" }, "internal_error", true },
    { "no_variables", { vars = {} }, "unsupported", true },
    { "no_variables", { vars = false }, "unsupported", true },
  }
  for _, c in ipairs(cases) do
    local over = c[2]
    if over.read_at == false then
      over.read_at = nil
    end
    local b = outcome(over)
    check(
      "outcome " .. c[1] .. ": failed, error_code " .. c[3] .. ", no variables, read_at only after a read",
      b.status == "failed"
        and b.reason == c[1]
        and b.error_code == c[3]
        and b.variables == nil
        and b.device == nil
        and (b.read_at ~= nil) == c[4],
      JSON:encode(b)
    )
  end
  check(
    "every reason maps to a module error code other than ok",
    (function()
      local Policy = require("sbos.modulepolicy")
      for _, code in pairs(D.REASONS) do
        if code == "ok" or not Policy.ERRORS[code] then
          return false
        end
      end
      return true
    end)()
  )
end

print("[10] body shapes")
do
  local b = read(FX.lock, "full")
  local keys = {}
  for k in pairs(b) do
    keys[#keys + 1] = k
  end
  table.sort(keys)
  check(
    "completed: exactly device, omitted, read_at, request_id, state_ref, status, variables",
    table.concat(keys, ",") == "device,omitted,read_at,request_id,state_ref,status,variables",
    table.concat(keys, ",")
  )
  local ok6 = count(b.omitted) == 7 and #D.OMITTED_KEYS == 7
  for _, k in ipairs(D.OMITTED_KEYS) do
    ok6 = ok6 and type(b.omitted[k]) == "number"
  end
  check("omitted: all seven counters, numbers", ok6)
  local raw = JSON:encode(b)
  check(
    "no dropped secret or personal NAME or VALUE is in the body",
    not raw:find("USER", 1, true)
      and not raw:find('"1234"', 1, true)
      and not raw:find("Resident One", 1, true)
      and not raw:find("Nanny", 1, true),
    raw
  )
  local f = read(FX.lock, "system")
  local fk = {}
  for k in pairs(f) do
    fk[#fk + 1] = k
  end
  table.sort(fk)
  check(
    "failed after a read: device, error_code, read_at, reason, request_id, state_ref, status",
    table.concat(fk, ",") == "device,error_code,read_at,reason,request_id,state_ref,status",
    table.concat(fk, ",")
  )
  local e = read(vars({ { "BATTERY_LEVEL", "50" }, { "USER_CODE", "1" } }), "full", nil, { "USER_CODE" })
  check('an empty answer encodes "variables":[] (an array)', JSON:encode(e):find('"variables":%[%]') ~= nil)
  check("D.CLASSES is the closed list of 14", #D.CLASSES == 14)
  local all = true
  for _, c in ipairs(D.CLASSES) do
    if c ~= "camera" and c ~= "unknown" and FX[c] == nil then
      all = false
    end
  end
  check("a fixture exists for every class (camera by file and variables)", all)
end

print("[11] not_allowed: counted, never named (KI-67)")
do
  local b = read(FX.fridge, "system")
  local raw = JSON:encode(b)
  check(
    "the wine fridge (system): omitted.not_allowed = 1, a whole number",
    b.omitted.not_allowed == 1 and math.floor(b.omitted.not_allowed) == b.omitted.not_allowed
  )
  check(
    "the withheld NAME and VALUE are nowhere in the body",
    not raw:find("DOOR", 1, true) and not raw:find("AJAR", 1, true),
    raw
  )
  check("omittedTotal counts not_allowed", D.omittedTotal(b.omitted) == 1)
  local n = read(FX.fridge, "system", nil, { "HUMIDITY", "DOOR_AJAR" })
  check(
    "narrowed to a withheld name: still not sent, counted once; a name not asked for is not counted",
    #n.variables == 1 and n.omitted.not_allowed == 1 and D.omittedTotal(n.omitted) == 1,
    JSON:encode(n)
  )
  local s = read(vars({ { "TEMPERATURE_F", "70" }, { "OWNER_NAME", "x" }, { "AWAY_FLAG", "1" } }), "system")
  check(
    "a name A or C drops is counted there first, never also as not_allowed",
    s.omitted.personal == 1 and s.omitted.occupancy == 1 and s.omitted.not_allowed == 0,
    JSON:encode(s.omitted)
  )
  local r = read(FX.lock, "system")
  check("a refused class carries no counter at all (not_allowed included)", r.omitted == nil)
  local t = read(FX.thermostat, "full")
  check("scope full, deny-list class: not_allowed is 0", t.omitted.not_allowed == 0)
end

print("[review] joined allow-lists keep every list, none stops at a missing one")
do
  -- joinedList walks its arguments with ipairs({ ... }): a nil argument would
  -- end the walk there and silently drop every later list. Each class's
  -- system list must hold every entry of every list it joins.
  local function has(list, entry)
    local want = (tostring(entry):upper():gsub("[^%w]", ""))
    for _, e in ipairs(list) do
      if e == want then
        return true
      end
    end
    return false
  end
  local joins = {
    thermostat = { D.THERMOSTAT_READ_NAMES },
    leak = { D.SIGNATURES.leak },
    power = { D.SIGNATURES.power },
    battery = { D.SIGNATURES.battery_level, D.SIGNATURES.battery_status, D.SIGNATURES.low_battery, D.SIGNATURES.link },
  }
  local missing = {}
  for class, lists in pairs(joins) do
    for i = 1, 4 do
      if i <= #lists or class == "battery" then
        local list = lists[i]
        if type(list) ~= "table" then
          missing[#missing + 1] = class .. " list " .. i .. " is nil"
        else
          for _, entry in ipairs(list) do
            if not has(D.ALLOW_SYSTEM[class], entry) then
              missing[#missing + 1] = class .. ":" .. tostring(entry)
            end
          end
        end
      end
    end
  end
  check("every joined list is present in full (the last one too)", #missing == 0, table.concat(missing, ","))
end

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
