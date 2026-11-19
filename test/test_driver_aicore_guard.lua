-- Ratchet: every ROOT driver reports to AI Core (brief D7a).
--
-- Every directory in drivers/ is either wired or on the exemption list
-- below, with a written reason:
--   * wired: driver.xml declares the read-only `AI Core` property exactly as
--     docs/DRIVER_PLATFORM_GUIDE.md §9 gives it, and driver.lua requires
--     sbos.aireport at module scope, calls aireport.start( or
--     aireport.attach(, and calls aireport.stop() (OnDriverDestroyed; a
--     `pcall(aireport.stop)` counts);
--   * exempt: AI Core itself; the Agent and the child drivers until the next
--     brief wires them (`pending = true`: that brief must remove each entry,
--     and this test FAILS once a pending driver is wired but still listed);
--     a root the conductor has not yet decided on.
-- A new driver directory is on neither list, so it fails until it is wired
-- or given a reason. A stale exemption (directory gone) fails too.
-- Comments are stripped before matching, so a commented-out require or a
-- property inside <!-- --> does not count.
-- Run from the driver root: make test

local pass, fail = 0, 0
local function check(name, ok, detail)
  if ok then
    pass = pass + 1
    print("  ok   " .. name)
  else
    fail = fail + 1
    print("  FAIL " .. name .. (detail ~= nil and ("  -> " .. tostring(detail)) or ""))
  end
end

local aireport = require("sbos.aireport")

local PENDING = "pending next brief (D7b): the next brief wires it and must remove this entry"
local PENDING_CHILD = "child driver: passive mode (src/sbos/aipresence.lua, ruling 20) is "
  .. PENDING

--- dir -> { reason, pending = bool }
local EXEMPT = {
  ["smartbuildos-ai-core"] = { reason = "it is AI Core itself; it does not report to itself" },
  ["smartbuildos"] = {
    reason = "the SmartBuildOS Agent (the bus hub): its AI Core property from its own registry is " .. PENDING,
    pending = true,
  },
  ["smartbuildos-venueflow"] = {
    reason = "root not wired in D7a: its module client exists only while Remote Management is on (off by "
      .. "default), so there is nothing to attach to, and `start` would put it on the bus against that "
      .. "setting; conductor decision pending",
  },
}
for file in pairs(aireport.CHILDREN) do
  EXEMPT[(file:gsub("%.c4z$", ""))] = { reason = PENDING_CHILD, pending = true }
end

local XML = "<property><name>AI Core</name><type>STRING</type><default>Searching…</default><readonly>true</readonly></property>"

local function read(path)
  local f = io.open(path, "rb")
  if f == nil then
    return nil
  end
  local s = f:read("*a")
  f:close()
  return s
end

local function stripLua(src)
  src = src:gsub("%-%-%[(=*)%[.-%]%1%]", "")
  return (src:gsub("%-%-[^\n]*", ""))
end

local function stripXml(src)
  return (src:gsub("<!%-%-.-%-%->", ""))
end

--- The AI Core <property> block of a driver.xml, whitespace-compacted, or nil.
local function aiCoreProperty(xml)
  for block in stripXml(xml):gmatch("<property>(.-)</property>") do
    local name = block:match("<name>%s*(.-)%s*</name>")
    if name == "AI Core" then
      return (("<property>" .. block .. "</property>"):gsub(">%s+<", "><"))
    end
  end
  return nil
end

--- Problems with a driver's wiring (empty when wired).
local function wiringProblems(dir)
  local out = {}
  local xml = read("drivers/" .. dir .. "/driver.xml")
  local lua = read("drivers/" .. dir .. "/driver.lua")
  if xml == nil or lua == nil then
    out[#out + 1] = "driver.xml or driver.lua missing"
    return out
  end
  local prop = aiCoreProperty(xml)
  if prop == nil then
    out[#out + 1] = "no AI Core property in driver.xml"
  elseif prop ~= XML then
    out[#out + 1] = "AI Core property is not the exact guide XML: " .. prop
  end
  local code = stripLua(lua)
  local var = code:match("\nlocal%s+([%w_]+)%s*=%s*require%(%s*[\"']sbos%.aireport[\"']%s*%)")
  if var == nil then
    out[#out + 1] = 'no module-scope `local x = require("sbos.aireport")`'
  else
    local esc = var:gsub("%p", "%%%0")
    if not (code:find(esc .. "%.start%(") or code:find(esc .. "%.attach%(")) then
      out[#out + 1] = var .. ".start( or " .. var .. ".attach( is never called"
    end
    if not (code:find(esc .. "%.stop%(%)") or code:find("pcall%(%s*" .. esc .. "%.stop%s*%)")) then
      out[#out + 1] = var .. ".stop() is never called"
    end
  end
  return out
end

-- ── the directories ─────────────────────────────────────────────────────────
local dirs = {}
local pipe = assert(io.popen('ls -1 "drivers" 2>/dev/null'))
for line in pipe:lines() do
  if read("drivers/" .. line .. "/driver.xml") ~= nil or read("drivers/" .. line .. "/driver.lua") ~= nil then
    dirs[#dirs + 1] = line
  end
end
pipe:close()
table.sort(dirs)
check("found the driver directories", #dirs >= 50, #dirs)

local present = {}
for _, dir in ipairs(dirs) do
  present[dir] = true
end

print("[1] every root driver is wired")
local wired = 0
for _, dir in ipairs(dirs) do
  local ex = EXEMPT[dir]
  if ex == nil then
    local problems = wiringProblems(dir)
    check(dir .. " reports to AI Core", #problems == 0, table.concat(problems, "; "))
    if #problems == 0 then
      wired = wired + 1
    end
    check(
      dir .. " is a root in aireport.MODULE_IDS (a new root needs its id in both tables)",
      aireport.MODULE_IDS[dir .. ".c4z"] ~= nil
    )
  end
end

print("[2] the exemptions")
for dir, ex in pairs(EXEMPT) do
  check(dir .. ": exemption has a written reason", type(ex.reason) == "string" and #ex.reason > 20)
  check(dir .. ": exempt directory exists (no stale exemption)", present[dir] == true)
  if ex.pending then
    -- The next brief adds the AI Core property to each of these; from then
    -- on the entry must go (and this test learns the child rule: passive).
    check(
      dir .. ": still pending (it has no AI Core property yet; once it has, remove it from EXEMPT)",
      aiCoreProperty(read("drivers/" .. dir .. "/driver.xml") or "") == nil
    )
  end
end
local roots = 0
for file in pairs(aireport.MODULE_IDS) do
  roots = roots + 1
  local dir = file:gsub("%.c4z$", "")
  check(file .. ": its directory exists", present[dir] == true)
end
print(string.format("  (%d roots in MODULE_IDS; %d wired; exempt: %d)", roots, wired, (function()
  local n = 0
  for _ in pairs(EXEMPT) do
    n = n + 1
  end
  return n
end)()))

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
