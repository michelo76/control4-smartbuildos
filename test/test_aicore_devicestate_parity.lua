-- AI Core's device classes vs the Agent's (no drift).
--
-- src/aicore/devicestate.lua classifies a device by the SAME candidate
-- variable names the Agent's sensor sweep uses. The Agent's lists are
-- literals inside `sensorReading` and `looksLikeThermostat`, globals in its
-- main chunk (drivers/smartbuildos/driver.lua, at its local limit), so AI
-- Core holds a copy. This test reads the Agent's source and fails when a
-- list changes on one side only.
--
--   [1] each firstOf(values, { … }) list in sensorReading = the matching
--       devicestate.SIGNATURES list (exact names, same order)
--   [2] every name looksLikeThermostat reads = devicestate.THERMOSTAT_NAMES
--  [2b] every name thermostatReading reads = devicestate.THERMOSTAT_READ_NAMES
--       (the thermostat's system-scope allow-list)
--   [3] the lists were really read (a guard that compared nothing is a fail)

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

local D = require("aicore.devicestate")

local f = assert(io.open("drivers/smartbuildos/driver.lua"))
local src = f:read("*a")
f:close()

local sensorFn = src:match("\nfunction sensorReading%(vars, name%)(.-)\nend\n") or ""
local thermoFn = src:match("\nfunction looksLikeThermostat%(vars%)(.-)\nend\n") or ""

--- The Agent's firstOf lists, by the local they are assigned to.
local agent = {}
for var, lit in sensorFn:gmatch("local ([%w_]+)%s*=%s*[%w%(]*%s*firstOf%(values,%s*(%b{})") do
  local names = {}
  for n in lit:gmatch('"([^"]+)"') do
    names[#names + 1] = n
  end
  agent[var] = names
end

local function show(list)
  return "{" .. table.concat(list or {}, ",") .. "}"
end
local function same(a, b)
  if a == nil or b == nil or #a ~= #b then
    return false
  end
  for i = 1, #a do
    if a[i] ~= b[i] then
      return false
    end
  end
  return true
end

print("[1] sensorReading lists = devicestate.SIGNATURES")
local MAP = {
  battery = "battery_level",
  batteryStatus = "battery_status",
  lowBatteryRaw = "low_battery",
  lockRaw = "lock",
  partitionRaw = "security",
  leakRaw = "leak",
  motionRaw = "motion",
  doorRaw = "opening",
  contactRaw = "contact",
  relayRaw = "relay",
  powerRaw = "power",
  link = "link",
}
local read = 0
for agentVar, sig in pairs(MAP) do
  if agent[agentVar] then
    read = read + 1
  end
  check(
    "Agent " .. agentVar .. " = devicestate.SIGNATURES." .. sig,
    same(agent[agentVar], D.SIGNATURES[sig]),
    "Agent " .. show(agent[agentVar]) .. " vs AI Core " .. show(D.SIGNATURES[sig])
  )
end
local extra = {}
for agentVar in pairs(agent) do
  if MAP[agentVar] == nil then
    extra[#extra + 1] = agentVar
  end
end
table.sort(extra)
check("the Agent has no firstOf list AI Core does not mirror", #extra == 0, "unmapped: " .. table.concat(extra, ","))

print("[2] looksLikeThermostat names = devicestate.THERMOSTAT_NAMES")
local thermo, seen = {}, {}
for n in thermoFn:gmatch('names%["([^"]+)"%]') do
  if not seen[n] then
    seen[n] = true
    thermo[#thermo + 1] = n
  end
end
check(
  "the same names in the same order",
  same(thermo, D.THERMOSTAT_NAMES),
  "Agent " .. show(thermo) .. " vs AI Core " .. show(D.THERMOSTAT_NAMES)
)

print("[2b] thermostatReading names = devicestate.THERMOSTAT_READ_NAMES")
local readingFn = src:match("\nfunction thermostatReading%(vars%)(.-)\nend\n") or ""
local reading, rseen = {}, {}
for _, n in readingFn:gmatch('(%a+)%("([^"]+)"%)') do
  if not rseen[n] then
    rseen[n] = true
    reading[#reading + 1] = n
  end
end
check(
  "the same names in the same order (the thermostat's system allow-list)",
  same(reading, D.THERMOSTAT_READ_NAMES),
  "Agent " .. show(reading) .. " vs AI Core " .. show(D.THERMOSTAT_READ_NAMES)
)

print("[2c] the base allow-list's SCALE = the name thermostatReading reads as `scale`")
local agentScale = readingFn:match('scale%s*=%s*str%("([^"]+)"%)')
check(
  "the Agent reads its scale as str(\"" .. tostring(agentScale) .. "\") = devicestate.SCALE_NAME",
  agentScale ~= nil and agentScale == D.SCALE_NAME,
  "Agent " .. tostring(agentScale) .. " vs AI Core " .. tostring(D.SCALE_NAME)
)
local inBase = false
for _, n in ipairs(D.ALLOW.unknown) do
  if n == D.SCALE_NAME then
    inBase = true
  end
end
check("SCALE_NAME is in the base (system-scope) allow-list", inBase)

print("[3] the comparison compared something")
check("sensorReading found in the Agent", #sensorFn > 1000, #sensorFn)
check("looksLikeThermostat found in the Agent", #thermoFn > 100, #thermoFn)
check("all 12 Agent lists read", read == 12, read)
check("6 thermostat names read", #thermo == 6, #thermo)
check("thermostatReading found in the Agent", #readingFn > 1000, #readingFn)
check("26 thermostatReading names read", #reading == 26, #reading)

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
