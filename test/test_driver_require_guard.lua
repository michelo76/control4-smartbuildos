-- Guard: every `require` of a module under src/ in a driver.lua must sit at
-- module scope. tools/gen-squishy.lua discovers a driver's modules by loading
-- driver.lua under the shim and calling OnDriverInit/OnDriverLateInit once;
-- LateInit stops at CheckMinimumVersion there, so a require inside any
-- function is never executed and the module is silently LEFT OUT of the .c4z.
-- Measured 2026-11-09: the Event Tracer shipped without tracer.catalog_data
-- and painted "built-in: 0 driver(s)" on the bench.
--
-- Heuristic: a require line that is indented is inside a block. Module-scope
-- requires start at column 1 (`local x = require(...)` or `require(...)`).
-- Vendor modules (drivers-common-public, cloud-client-byte, JSON) are exempt:
-- they are not under src/ and squishy handles them elsewhere.
--
-- Run from the driver root: make test

local pass, fail = 0, 0
local function check(name, ok, detail)
  if ok then
    pass = pass + 1
    print("  ok   " .. name)
  else
    fail = fail + 1
    print("  FAIL " .. name .. (detail and ("  -> " .. tostring(detail)) or ""))
  end
end

local function exists(path)
  local f = io.open(path, "r")
  if f then
    f:close()
    return true
  end
  return false
end

local function isSrcModule(name)
  return exists("src/" .. name:gsub("%.", "/") .. ".lua") or exists("src/" .. name:gsub("%.", "/") .. "/init.lua")
end

local p = io.popen("ls -d drivers/*/driver.lua 2>/dev/null")
local drivers = {}
for line in p:lines() do
  drivers[#drivers + 1] = line
end
p:close()
check("found driver files", #drivers > 0, #drivers)

for _, path in ipairs(drivers) do
  local f = assert(io.open(path, "r"))
  local offenders = {}
  local n = 0
  for line in f:lines() do
    n = n + 1
    for name in line:gmatch('require%s*%(?%s*"([%w%._%-]+)"') do
      if isSrcModule(name) and line:match("^%s+") then
        offenders[#offenders + 1] = string.format("%s:%d %s", path, n, name)
      end
    end
  end
  f:close()
  check(path .. ": src requires at module scope", #offenders == 0, table.concat(offenders, "; "))
end

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
