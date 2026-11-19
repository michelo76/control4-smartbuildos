--- SmartBuildOS AI Core — one device's live state, filtered in the home (pure).
---
--- The restricted operation `read_device_state` (platform → controller) asks
--- for ONE device's current variables. The driver reads them once with
--- C4:GetDeviceVariables (the call the Agent and AI Core already use) and
--- hands them here. Everything that decides WHAT may leave the home lives in
--- this module, with no C4 surface, so every rule is tested directly:
---
---   classify(vars, file)                 → class, from the live variable
---                                          names (and the driver file name
---                                          for cameras), never the device name
---   filter(vars, scope, class, wanted)   → kept {name, value}, omitted counts
---   bound(kept, omitted)                 → at most 40 variables and 4,096
---                                          bytes of variables JSON; a variable
---                                          that does not fit is DROPPED WHOLE
---   result(input)                        → the device_state_result body
---
--- Read-only: nothing here, and nothing in the driver path that calls it,
--- writes a variable or sends a command (test_aicore_driver.lua [20]).
---
--- The rules (SPEC round two §2.5; conductor rulings §9):
---   A  every scope: a name with a secret fragment or a personal-data token
---      is dropped (counted secret / personal)
---   B  every scope: a value that is not a short plain scalar is dropped —
---      tables, strings over 64 bytes, markup / control / bidi characters,
---      URLs, e-mail, IPv4, MAC, phone- and token-shaped strings
---   C  scope `system` only: occupancy-revealing names are dropped
---   D  the class, most restrictive first (camera before everything)
---   E  restricted classes; in scope `system` they are REFUSED (no variable
---      leaves the home), except `unknown`, which gets the small allow-list
---   F  allow-lists where a deny-list is unsafe: lock and security in scope
---      `full`, and EVERY class answered in scope `system` (ALLOW_SYSTEM;
---      KI-68); a name outside them is counted `not_allowed` (KI-67);
---      cameras are refused in every scope
---   G  values are passed as Director holds them; TEMPERATURE is never
---      converted
---
--- The class signatures are copied from the Agent's `sensorReading` /
--- `looksLikeThermostat` (globals in the Agent's main chunk, so they cannot
--- be required); test_aicore_devicestate_parity.lua keeps them equal. Lights
--- use src/telemetry/lights.lua itself.

local Lights = require("telemetry.lights")

local M = {}

M.LIMITS = {
  variables = 40, -- N: variables per answer
  variables_bytes = 4096, -- M: bytes of the `variables` JSON (conservative estimate)
  name_bytes = 48,
  value_bytes = 64,
  wanted = 12, -- names the platform may narrow the read to
}

M.SCOPES = { system = true, full = true }

--- Closed classes (the device object of device_state_result).
M.CLASSES = {
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
  "camera",
  "unknown",
}

--- E: restricted classes. `light` is restricted on the touchscreen's system
--- scope by conductor ruling §9.3 (on/off is presence). `unknown` is
--- restricted, but in scope `system` it is answered with the small allow-list
--- (F) instead of a refusal (ruling §9.7).
M.RESTRICTED = {
  lock = true,
  security = true,
  opening = true,
  motion = true,
  contact = true,
  relay = true,
  camera = true,
  light = true,
  unknown = true,
}

--- Why a read failed (device_state_result.reason) and the module error code
--- it travels with (device_state_result.error_code, never `ok`).
M.REASONS = {
  not_found = "unknown_target",
  no_variables = "unsupported",
  restricted_class = "not_permitted",
  camera_not_supported = "unsupported",
  not_licensed = "not_permitted",
  busy = "rate_limited",
  read_failed = "internal_error",
}

--- The omitted counters, always all seven, in every completed body (whole
--- numbers; never a name). `not_allowed`: outside the class's allow-list for
--- the scope (KI-67 closed; the platform takes it as an optional key).
M.OMITTED_KEYS = { "secret", "personal", "occupancy", "non_scalar", "too_long", "over_limit", "not_allowed" }

-- ── A: names that never leave the home ─────────────────────────────────────

--- Substring of the joined name (upper-case, non-alphanumerics removed).
--- The first fourteen are the Flight Recorder's FIXED_EXCLUSIONS
--- (src/flightrecorder/config.lua; the parity test keeps them included).
M.SECRET_FRAGMENTS = {
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

--- Whole tokens counted as `secret`. PIN..KEYS are the spec's; PWD, PASS,
--- OTP, NONCE, JWT and HMAC are additions (secret-shaped, listed in the
--- round-two report).
M.SECRET_TOKENS = {
  "PIN",
  "CODE",
  "CODES",
  "KEY",
  "KEYS",
  "PWD",
  "PASS",
  "OTP",
  "NONCE",
  "JWT",
  "HMAC",
}

--- Whole tokens counted as `personal`. CONTACT is special: it is personal
--- only when the next token is not STATE (CONTACT_STATE is a sensor).
--- FIRSTNAME..PHONENUMBER are additions (the joined spellings of the spec's
--- tokens, which a whole-token rule would otherwise miss).
M.PERSONAL_TOKENS = {
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
  "FIRSTNAME",
  "LASTNAME",
  "FULLNAME",
  "USERID",
  "TELEPHONE",
  "HOSTNAME",
  "IPADDRESS",
  "MACADDRESS",
  "EMAILADDRESS",
  "ZIPCODE",
  "POSTCODE",
  "PHONENUMBER",
}

-- ── C: occupancy names (scope `system` only) ───────────────────────────────

M.OCCUPANCY_TOKENS = {
  "OCCUPANCY",
  "OCCUPIED",
  "PRESENCE",
  "AWAY",
  "HOME",
  "VACATION",
  "MOTION",
  "LAST",
  "ARRIVAL",
  "DEPARTURE",
  "DOORBELL",
  "RING",
  "VISITOR",
}

-- ── D: class signatures (copied from the Agent's sensorReading) ────────────
--
-- The Agent's firstOf lists, verbatim. Two differences in HOW they match,
-- both fail-closed (classification can only make an answer more
-- restrictive): a name matches in its joined form (upper-case,
-- non-alphanumerics removed — so "LockStatus" is LOCK_STATUS), and a name
-- counts even when its value is empty (presence is enough).

M.SIGNATURES = {
  lock = { "LOCK_STATUS", "LOCK STATUS", "LOCKED", "LOCK_STATE", "LOCKSTATE" },
  security = { "PARTITION_STATE", "PARTITION STATE", "ARM_STATE", "ARMED_STATE", "SECURITY_STATE" },
  leak = { "LEAK", "LEAK_DETECTED", "WATER_DETECTED", "LEAKDETECTED" },
  motion = { "MOTION_STATE", "MOTION STATE", "MOTION", "MOTIONSTATE" },
  opening = { "DOOR_STATE", "DOOR STATE", "GARAGE_STATE", "GATE_STATE", "OPENSTATE", "OPEN_STATE" },
  contact = { "CONTACT_STATE", "CONTACT STATE", "CONTACTSTATE", "SENSOR_STATE" },
  relay = { "RELAY_STATE", "RELAY STATE", "RELAYSTATE" },
  power = { "POWER_LOST", "ON_BATTERY", "RUNNING ON BATTERY", "AC_POWER" },
  battery_level = { "BATTERY_LEVEL", "BATTERY LEVEL", "BATTERY_PERCENT", "BATTERY", "BATTERYLEVEL" },
  battery_status = { "BATTERY_STATUS", "BATTERY STATUS" },
  low_battery = { "LOW_BATTERY", "LOW BATTERY", "BATTERY_LOW" },
  link = { "LINK_QUALITY", "LINK QUALITY", "LQI", "RSSI", "SIGNAL_STRENGTH" },
}

--- The names the Agent's looksLikeThermostat reads.
M.THERMOSTAT_NAMES =
  { "HVAC_MODES_LIST", "HVAC_MODE", "TEMPERATURE_F", "TEMPERATURE_C", "V1 TEMPERATURE", "V1 HVACMODES" }

--- The names the Agent's thermostatReading reads (and already uploads to
--- control4_thermostat_state), in order of first use. The thermostat's
--- `system`-scope allow-list (F) is built from them;
--- test_aicore_devicestate_parity.lua keeps them equal to the Agent's.
M.THERMOSTAT_READ_NAMES = {
  "SCALE",
  "TEMPERATURE_F",
  "V1 TEMPERATURE",
  "TEMPERATURE_C",
  "HEAT_SETPOINT_F",
  "V1 HEAT_SETPOINT",
  "COOL_SETPOINT_F",
  "V1 COOL_SETPOINT",
  "SINGLE_SETPOINT_F",
  "HVAC_MODE",
  "ANA_HVACMODE",
  "V1 HVACMODE",
  "HVAC_STATE",
  "FAN_MODE",
  "V1 FANMODE",
  "FAN_STATE",
  "HUMIDITY",
  "HUMIDITY_MODE",
  "HUMIDITY_STATE",
  "OUTDOOR_TEMPERATURE_F",
  "BATTERY STATUS",
  "RUNNING ON BATTERY",
  "HEATING ACTIVE",
  "COOLING ACTIVE",
  "IS_CONNECTED",
  "HEATPUMP",
}

--- Driver file fragments that make a device a camera (lower-case substring).
M.CAMERA_FILES = { "camera", "doorbell", "nvr", "protect-camera" }

--- The temperature scale's variable: exactly the name the Agent's
--- thermostatReading reads (`scale = str("SCALE")`), so a climate sensor or
--- thermostat read at `system` scope carries its unit when the device has
--- one. test_aicore_devicestate_parity.lua ties it to the Agent's source.
M.SCALE_NAME = "SCALE"

-- ── F: allow-lists ──────────────────────────────────────────────────────────
--
-- Matched on the joined name (upper-case, non-alphanumerics removed). An
-- entry ending in `*` is a prefix.

M.ALLOW = {
  lock = {
    "LOCKSTATUS",
    "LOCKSTATE",
    "LOCKED",
    "BATTERYLEVEL",
    "BATTERYSTATUS",
    "LOWBATTERY",
    "LINKQUALITY",
    "LQI",
    "RSSI",
  },
  security = { "PARTITIONSTATE", "ARMSTATE", "ARMEDTYPE", "ALARMSTATE", "TROUBLE*", "BATTERY*", "LOWBATTERY" },
  unknown = {
    "TEMPERATURE*",
    "HUMIDITY*",
    M.SCALE_NAME, -- the unit travels with a temperature (round two)
    "BATTERY*",
    "LOWBATTERY",
    "LINKQUALITY",
    "LQI",
    "RSSI",
    "ONLINE",
    "CONNECTED",
    "COMM*STATUS",
  },
}

--- Scope `system`: EVERY class that is answered there is answered through an
--- allow-list (fail closed; KI-68). A name nobody reviewed for that class is
--- not sent (counted `not_allowed`). The base is the `unknown` list; a class
--- adds only the names of its own signature, each taken from a list the
--- Agent already reads (and, for thermostats, already uploads):
---   climate_sensor  the base, nothing else (conductor ruling); the base
---                   carries SCALE so a temperature travels with its unit
---   thermostat      the base + THERMOSTAT_READ_NAMES
---   leak            the base + SIGNATURES.leak
---   power           the base + SIGNATURES.power
---   battery         the base + the battery, low-battery and link lists
--- A class with no entry here (a class added later) gets the base list.
local function joinedList(...)
  local out = {}
  for _, entry in ipairs(M.ALLOW.unknown) do
    out[#out + 1] = entry
  end
  for _, list in ipairs({ ... }) do
    for _, n in ipairs(list) do
      out[#out + 1] = (tostring(n):upper():gsub("[^%w]", ""))
    end
  end
  return out
end
M.ALLOW_SYSTEM = {
  unknown = M.ALLOW.unknown,
  climate_sensor = M.ALLOW.unknown,
  thermostat = joinedList(M.THERMOSTAT_READ_NAMES),
  leak = joinedList(M.SIGNATURES.leak),
  power = joinedList(M.SIGNATURES.power),
  battery = joinedList(
    M.SIGNATURES.battery_level,
    M.SIGNATURES.battery_status,
    M.SIGNATURES.low_battery,
    M.SIGNATURES.link
  ),
}

-- ── helpers ─────────────────────────────────────────────────────────────────

local function setOf(list)
  local s = {}
  for _, v in ipairs(list) do
    s[v] = true
  end
  return s
end

local SECRET_TOKEN = setOf(M.SECRET_TOKENS)
local PERSONAL_TOKEN = setOf(M.PERSONAL_TOKENS)
local OCCUPANCY_TOKEN = setOf(M.OCCUPANCY_TOKENS)

--- The joined form: upper-case, every non-alphanumeric removed.
function M.joined(name)
  return (tostring(name or ""):upper():gsub("[^%w]", ""))
end

local function split(s)
  local out = {}
  for t in s:upper():gmatch("%w+") do
    out[#out + 1] = t
  end
  return out
end

--- The two token lists of a name: the spec's split (upper-case, split on
--- non-alphanumerics) and a refined one that also cuts camelCase and
--- letter/digit boundaries ("OwnerName" -> OWNER NAME, "PIN1" -> PIN 1). A
--- token rule matches in either list: more tokens can only deny more.
function M.tokenLists(name)
  local s = tostring(name or "")
  local refined =
    s:gsub("(%l)(%u)", "%1 %2"):gsub("(%u)(%u%l)", "%1 %2"):gsub("(%a)(%d)", "%1 %2"):gsub("(%d)(%a)", "%1 %2")
  return split(s), split(refined)
end

--- A: `secret`, `personal` or nil for a variable name.
function M.deniedName(name)
  local j = M.joined(name)
  for _, frag in ipairs(M.SECRET_FRAGMENTS) do
    if j:find(frag, 1, true) then
      return "secret"
    end
  end
  local lists = { M.tokenLists(name) }
  for _, toks in ipairs(lists) do
    for _, t in ipairs(toks) do
      if SECRET_TOKEN[t] then
        return "secret"
      end
    end
  end
  for _, toks in ipairs(lists) do
    for i, t in ipairs(toks) do
      if t == "CONTACT" then
        if toks[i + 1] ~= "STATE" then
          return "personal"
        end
      elseif PERSONAL_TOKEN[t] then
        return "personal"
      end
    end
  end
  return nil
end

--- C: whether a name reveals occupancy.
function M.occupancyName(name)
  for _, toks in ipairs({ M.tokenLists(name) }) do
    for _, t in ipairs(toks) do
      if OCCUPANCY_TOKEN[t] then
        return true
      end
    end
  end
  return false
end

local function allowed(list, name)
  local j = M.joined(name)
  for _, entry in ipairs(list) do
    local star = entry:find("*", 1, true)
    if star == nil then
      if j == entry then
        return true
      end
    elseif star == #entry then
      if j:sub(1, #entry - 1) == entry:sub(1, -2) then
        return true
      end
    else
      -- COMM*STATUS: prefix and suffix.
      local pre, post = entry:sub(1, star - 1), entry:sub(star + 1)
      if #j >= #pre + #post and j:sub(1, #pre) == pre and j:sub(-#post) == post then
        return true
      end
    end
  end
  return false
end
M._allowed = allowed

-- Control (C0, DEL), C1, line/paragraph separators and bidi controls.
local function unprintable(s)
  return s:find("[%z\1-\31\127]") ~= nil
    or s:find("\194[\128-\159]") ~= nil
    or s:find("\226\128[\142\143\168-\174]") ~= nil
    or s:find("\226\129[\166-\169]") ~= nil
    or s:find("\216\156") ~= nil
    or s:find("\239\187\191") ~= nil
end

--- B: why a value may not leave the home (an omitted counter), or nil.
function M.deniedValue(v)
  local t = type(v)
  if t == "boolean" then
    return nil
  end
  if t == "number" then
    if v ~= v or v == math.huge or v == -math.huge then
      return "non_scalar"
    end
    return nil
  end
  if t ~= "string" then
    return "non_scalar"
  end
  if #v > M.LIMITS.value_bytes then
    return "too_long" -- dropped whole, never cut
  end
  if v:find("[<{%[]") or unprintable(v) then
    return "non_scalar" -- markup, a structure, or characters that are not plain text
  end
  local lower = v:lower()
  if lower:find("://", 1, true) or lower:find("www.", 1, true) or v:find("@.*%.") then
    return "personal"
  end
  if v:find("%d+%.%d+%.%d+%.%d+") or v:find("%x%x[:%-]%x%x[:%-]%x%x") then
    return "personal"
  end
  if tonumber(v) == nil then
    local digits = v:gsub("[%s%+%-%(%)]", "")
    if #digits >= 7 and digits:match("^%d+$") then
      return "personal" -- phone-shaped
    end
  end
  if v:find("[%w%+/=_%-]" .. string.rep("[%w%+/=_%-]", 19)) then
    return "secret" -- token-shaped: 20+ characters of a key alphabet, no space
  end
  return nil
end

--- Whether a variable NAME can be sent at all (bounded, plain text).
local function nameProblem(name)
  if type(name) ~= "string" or name == "" then
    return "non_scalar"
  end
  if #name > M.LIMITS.name_bytes then
    return "too_long"
  end
  if name:find("[<{%[]") or unprintable(name) then
    return "non_scalar"
  end
  return nil
end

--- The variables of a GetDeviceVariables table as a stable list
--- { id, name, value }, ordered by name then id.
local function entries(vars)
  local out = {}
  if type(vars) ~= "table" then
    return out
  end
  for id, v in pairs(vars) do
    if type(v) == "table" then
      out[#out + 1] = { id = tonumber(id) or 0, name = v.name, value = v.value }
    end
  end
  table.sort(out, function(a, b)
    local an, bn = tostring(a.name), tostring(b.name)
    if an ~= bn then
      return an < bn
    end
    return a.id < b.id
  end)
  return out
end
M._entries = entries

-- ── D: classification ───────────────────────────────────────────────────────

local function looksLikeThermostat(names)
  if (names["HVAC_MODES_LIST"] or ""):upper():find("WARN", 1, true) ~= nil then
    return false
  end
  if names["HVAC_MODE"] ~= nil and (names["TEMPERATURE_F"] ~= nil or names["TEMPERATURE_C"] ~= nil) then
    return true
  end
  return names["V1 TEMPERATURE"] ~= nil and names["V1 HVACMODES"] ~= nil
end

--- The class of a device from its live variables and its driver file name.
--- @param vars table raw C4:GetDeviceVariables result
--- @param file string|nil the device's driverFileName (C4:GetDevices)
function M.classify(vars, file)
  local names, joinedNames = {}, {}
  local any = false
  for _, e in ipairs(entries(vars)) do
    if type(e.name) == "string" then
      names[e.name:upper()] = tostring(e.value or "")
      joinedNames[M.joined(e.name)] = true
      any = true
    end
  end
  local function has(list)
    for _, n in ipairs(list) do
      if joinedNames[M.joined(n)] then
        return true
      end
    end
    return false
  end
  -- Cameras first: refused in every scope, so nothing may outrank them.
  local f = tostring(file or ""):lower()
  for _, frag in ipairs(M.CAMERA_FILES) do
    if f:find(frag, 1, true) then
      return "camera"
    end
  end
  for n in pairs(names) do
    local j = M.joined(n)
    if j:find("STREAM", 1, true) or j:find("SNAPSHOT", 1, true) or j == "AVAILABLECAMERAS" then
      return "camera"
    end
  end
  if not any then
    return "unknown"
  end
  local S = M.SIGNATURES
  if has(S.lock) then
    return "lock"
  elseif has(S.security) then
    return "security"
  elseif has(S.opening) then
    return "opening"
  elseif has(S.motion) then
    return "motion"
  elseif has(S.contact) then
    return "contact"
  elseif has(S.relay) then
    return "relay"
  elseif looksLikeThermostat(names) then
    return "thermostat"
  elseif Lights.signature(vars) ~= nil then
    return "light"
  elseif has(S.leak) then
    return "leak"
  elseif has(S.power) then
    return "power"
  elseif has(S.battery_level) or has(S.battery_status) or has(S.low_battery) then
    return "battery"
  end
  for n in pairs(names) do
    local j = M.joined(n)
    if j:sub(1, 11) == "TEMPERATURE" or j:sub(1, 8) == "HUMIDITY" then
      return "climate_sensor"
    end
  end
  return "unknown"
end

--- Whether `class` is answered with `restricted_class` (and no variable)
--- in `scope`. Cameras are refused separately (camera_not_supported).
function M.refused(class, scope)
  if class == "camera" then
    return true
  end
  return scope ~= "full" and M.RESTRICTED[class] == true and class ~= "unknown"
end

--- The `restricted` flag of the device object: the class is restricted and
--- was answered only because the scope is `full`. `unknown` in scope
--- `system` is answered through its allow-list and reports false.
function M.restrictedFlag(class, scope)
  if class == "unknown" and scope ~= "full" then
    return false
  end
  return M.RESTRICTED[class] == true
end

local function newOmitted()
  local o = {}
  for _, k in ipairs(M.OMITTED_KEYS) do
    o[k] = 0
  end
  return o
end
M.newOmitted = newOmitted

--- The allow-list in force for (class, scope), or nil (deny-list only).
--- Scope `full`: lock and security only. Scope `system`: every class
--- (ALLOW_SYSTEM, else the base list) — never nil, so a name nobody
--- reviewed never reaches the touchscreen.
function M.allowList(class, scope)
  if scope == "full" then
    if class == "lock" or class == "security" then
      return M.ALLOW[class]
    end
    return nil
  end
  return M.ALLOW_SYSTEM[class] or M.ALLOW.unknown
end

--- A, C, F, then B. Never called for a refused class.
--- @param wanted table|nil names the platform narrowed the read to
--- @return table kept { {name, value} }, table omitted
function M.filter(vars, scope, class, wanted)
  local omitted = newOmitted()
  local kept = {}
  local want = nil
  if type(wanted) == "table" and #wanted > 0 then
    want = {}
    for _, n in ipairs(wanted) do
      want[tostring(n):upper()] = true
    end
  end
  local allow = M.allowList(class, scope)
  for _, e in ipairs(entries(vars)) do
    local name = e.name
    if want == nil or (type(name) == "string" and want[name:upper()]) then
      local why = nameProblem(name)
      if why == nil then
        why = M.deniedName(name)
      end
      if why == nil and scope ~= "full" and M.occupancyName(name) then
        why = "occupancy"
      end
      if why == nil and allow ~= nil and not allowed(allow, name) then
        -- Outside the class's allow-list for this scope: not sent, counted
        -- (the count only; the name never leaves the home).
        why = "not_allowed"
      end
      if why == nil then
        why = M.deniedValue(e.value)
      end
      if why ~= nil then
        omitted[why] = omitted[why] + 1
      else
        kept[#kept + 1] = { name = name, value = e.value }
      end
    end
  end
  return kept, omitted
end

--- Conservative JSON size of one {name, value} entry: every byte of a
--- non-ASCII character counted as 3 (an encoder may write \uXXXX), a quote
--- or backslash as 2.
local function jsonLen(s)
  local n = 0
  for i = 1, #s do
    local b = s:byte(i)
    if b >= 0x80 then
      n = n + 3
    elseif b == 34 or b == 92 then
      n = n + 2
    else
      n = n + 1
    end
  end
  return n
end

function M.entryBytes(e)
  local v = e.value
  local vlen
  if type(v) == "string" then
    vlen = jsonLen(v) + 2
  elseif type(v) == "number" then
    vlen = 24
  else
    vlen = 5
  end
  -- {"name":"…","value":…} plus the separating comma
  return #'{"name":"","value":}' + jsonLen(e.name) + vlen + 1
end

--- At most N variables and M bytes; a variable that does not fit is dropped
--- whole (over_limit), never cut.
function M.bound(kept, omitted)
  local out = {}
  local bytes = 2 -- [ ]
  for _, e in ipairs(kept) do
    local b = M.entryBytes(e)
    if #out < M.LIMITS.variables and bytes + b <= M.LIMITS.variables_bytes then
      out[#out + 1] = e
      bytes = bytes + b
    else
      omitted.over_limit = omitted.over_limit + 1
    end
  end
  return out, omitted
end

--- The device_state_result body.
--- input = {
---   request_id, state_ref, device_id, scope, wanted,
---   reason        -- a refusal decided before the read (not_licensed, busy, not_found)
---   read_ok, vars -- the pcall outcome of C4:GetDeviceVariables and its table
---   file          -- the device's driver file name
---   read_at       -- controller time of the read (epoch seconds)
--- }
function M.result(input)
  local body = { request_id = input.request_id, state_ref = input.state_ref }
  local function failed(reason, class)
    body.status = "failed"
    body.reason = reason
    body.error_code = M.REASONS[reason]
    if class ~= nil then
      body.device = { id = input.device_id, class = class, restricted = M.RESTRICTED[class] == true }
    end
    return body
  end
  if input.reason ~= nil then
    return failed(input.reason)
  end
  -- From here a read happened: read_at is when (never when a value changed).
  body.read_at = input.read_at
  if not input.read_ok or (input.vars ~= nil and type(input.vars) ~= "table") then
    return failed("read_failed")
  end
  if input.vars == nil or #entries(input.vars) == 0 then
    return failed("no_variables")
  end
  local class = M.classify(input.vars, input.file)
  if class == "camera" then
    return failed("camera_not_supported", class)
  end
  if M.refused(class, input.scope) then
    -- Nothing of this device leaves the home: no variable, no count.
    return failed("restricted_class", class)
  end
  local kept, omitted = M.filter(input.vars, input.scope, class, input.wanted)
  local list
  list, omitted = M.bound(kept, omitted)
  body.status = "completed"
  body.device = { id = input.device_id, class = class, restricted = M.restrictedFlag(class, input.scope) }
  body.variables = list
  body.omitted = omitted
  return body
end

--- How many variables an answer omitted in all.
function M.omittedTotal(omitted)
  local n = 0
  for _, k in ipairs(M.OMITTED_KEYS) do
    n = n + ((omitted or {})[k] or 0)
  end
  return n
end

return M
