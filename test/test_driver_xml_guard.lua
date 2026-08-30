-- Structural guard over every drivers/*/driver.xml.
--
-- Born from a field failure (2026-08-30): three Bond drivers shipped
-- WITHOUT the <script file="driver.lua"/> element inside <config>. Director
-- rendered their properties from the XML and never loaded a line of Lua —
-- Driver Status stuck at its "Starting" default, no version, no license
-- registration. Every Lua test passed, because every Lua test loads the
-- source directly; only the XML knows whether the controller ever will.
--
-- Checks per driver:
--   * <config> carries a <script> element pointing at driver.lua.
--   * A driver.lua actually exists next to the XML.
--   * The <version> element is empty in SOURCE (the build stamps it; a
--     hardcoded version would make Composer skip updates silently).
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

local function listDrivers()
  local names = {}
  -- Both invocation styles the suite supports: repo root and test/.
  for _, base in ipairs({ "drivers", "../drivers" }) do
    local pipe = io.popen('ls -1 "' .. base .. '" 2>/dev/null')
    if pipe ~= nil then
      for line in pipe:lines() do
        table.insert(names, { name = line, dir = base .. "/" .. line })
      end
      pipe:close()
    end
    if #names > 0 then
      break
    end
  end
  return names
end

local drivers = listDrivers()
check("driver directories found", #drivers > 0, #drivers)

for _, driver in ipairs(drivers) do
  local xmlFile = io.open(driver.dir .. "/driver.xml", "r")
  if xmlFile == nil then
    check(driver.name .. ": driver.xml present", false)
  else
    local xml = xmlFile:read("*a")
    xmlFile:close()

    check(
      driver.name .. ": <script> element loads driver.lua",
      xml:find('<script%s+file="driver%.lua"') ~= nil
    )

    local luaFile = io.open(driver.dir .. "/driver.lua", "r")
    check(driver.name .. ": driver.lua exists", luaFile ~= nil)
    if luaFile ~= nil then
      luaFile:close()
    end

    check(
      driver.name .. ": source version left for the build to stamp",
      xml:find("<version/>") ~= nil or xml:find("<version></version>") ~= nil
    )
  end
end

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
