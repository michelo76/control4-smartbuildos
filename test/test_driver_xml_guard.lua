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
--   * No property uses a type Composer Pro 2026.10.14 refuses to create
--     ("Property Invalid … Object reference not set to an instance of an
--     object", one dialog per property, the property then missing):
--     PASSWORD (2026-11-09: use STRING with <password>true</password>) and
--     DEVICE_SELECTOR with no <items> filter (2026-11-10: list the devices
--     in a DYNAMIC_LIST instead). Command parameters are not properties and
--     may use DEVICE_SELECTOR.
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

    check(driver.name .. ": <script> element loads driver.lua", xml:find('<script%s+file="driver%.lua"') ~= nil)

    local luaFile = io.open(driver.dir .. "/driver.lua", "r")
    check(driver.name .. ": driver.lua exists", luaFile ~= nil)
    if luaFile ~= nil then
      luaFile:close()
    end

    check(
      driver.name .. ": source version left for the build to stamp",
      xml:find("<version/>") ~= nil or xml:find("<version></version>") ~= nil
    )

    local refused = {}
    for block in xml:gmatch("<property>(.-)</property>") do
      local name = block:match("<name>(.-)</name>") or "?"
      local ptype = block:match("<type>(.-)</type>") or ""
      if ptype == "PASSWORD" then
        refused[#refused + 1] = name .. " (PASSWORD)"
      elseif ptype == "DEVICE_SELECTOR" and not block:find("<items>%s*<item>") then
        refused[#refused + 1] = name .. " (DEVICE_SELECTOR without <items>)"
      end
    end
    check(driver.name .. ": no property type Composer refuses to create", #refused == 0, table.concat(refused, "; "))
  end
end

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
