-- Ratchet: EVERY driver in drivers/ shows the read-only `AI Core` property,
-- wired the way its kind requires (briefs D7a, D7b; conductor ruling 20).
--
-- Every directory in drivers/ has the property exactly as
-- docs/DRIVER_PLATFORM_GUIDE.md §9 gives it, and:
--   * a ROOT (aireport.MODULE_IDS): driver.lua requires sbos.aireport at
--     module scope, calls aireport.start( or aireport.attach(, and calls
--     aireport.stop() (a `pcall(aireport.stop)` counts);
--   * VenueFlow (a root that reports only while Remote Management is on):
--     the root wiring above with attach(, AND sbos.aipresence at module
--     scope with start({... silent = true ...}) and stop() for the off state;
--   * a CHILD (aipresence.CHILDREN): sbos.aipresence at module scope with
--     start( and stop(, either in driver.lua or in a shared child base in
--     CHILD_BASES that driver.lua requires at module scope; and it carries
--     neither sbos.aireport nor sbos.moduleclient (ruling 20);
--   * the AGENT: `AgentAiCore = require("sbos.agentaicore")` and
--     AgentAiCore.refresh( called from its module hooks (onDirectoryChanged
--     included), with NO new top-level local (the main chunk is at its
--     200-local limit).
-- The only exemption is AI Core itself. A new driver directory fails until
-- it is a root (MODULE_IDS) or a child (CHILDREN) and wired. Every child
-- must name a real directory and a real root. Comments are stripped before
-- matching, so a commented-out require or a property inside <!-- --> does
-- not count.
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
local aipresence = require("sbos.aipresence")

local AGENT = "smartbuildos"
local VENUEFLOW = "smartbuildos-venueflow"

--- dir -> reason. AI Core is the only driver without the property.
local EXEMPT = {
  ["smartbuildos-ai-core"] = "it is AI Core itself; it does not report to itself",
}

--- Shared child bases that install a child's lifecycle (OnDriverLateInit /
--- OnDriverDestroyed) and so carry its sbos.aipresence wiring.
local CHILD_BASES = {
  ["mqtt.childdriver"] = "src/mqtt/childdriver.lua",
  ["systemlink.companiondriver"] = "src/systemlink/companiondriver.lua",
}

--- Drivers not wired yet in this brief (D7b works family by family). Must be
--- EMPTY when the brief is done; an entry that is already wired fails.
local PENDING = {
  ["smartbuildos-venueflow"] = true,
}

local XML =
  "<property><name>AI Core</name><type>STRING</type><default>Searching…</default><readonly>true</readonly></property>"

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

local function esc(s)
  return (s:gsub("%p", "%%%0"))
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

--- The module-scope local a chunk binds to require(name), or nil.
local function requiredAs(code, name)
  return ("\n" .. code):match("\nlocal%s+([%w_]+)%s*=%s*require%(%s*[\"']" .. esc(name) .. "[\"']%s*%)")
end

local function calls(code, var, fn)
  return code:find(esc(var) .. "%." .. fn .. "%(") ~= nil
    or code:find("pcall%(%s*" .. esc(var) .. "%." .. fn .. "%s*[,%)]") ~= nil
end

local function propertyProblems(dir, out)
  local xml = read("drivers/" .. dir .. "/driver.xml")
  if xml == nil then
    out[#out + 1] = "driver.xml missing"
    return
  end
  local prop = aiCoreProperty(xml)
  if prop == nil then
    out[#out + 1] = "no AI Core property in driver.xml"
  elseif prop ~= XML then
    out[#out + 1] = "AI Core property is not the exact guide XML: " .. prop
  end
end

local function rootWiring(code, out, needAttach)
  local var = requiredAs(code, "sbos.aireport")
  if var == nil then
    out[#out + 1] = 'no module-scope `local x = require("sbos.aireport")`'
    return
  end
  if needAttach then
    if not calls(code, var, "attach") then
      out[#out + 1] = var .. ".attach( is never called"
    end
  elseif not (calls(code, var, "start") or calls(code, var, "attach")) then
    out[#out + 1] = var .. ".start( or " .. var .. ".attach( is never called"
  end
  if not calls(code, var, "stop") then
    out[#out + 1] = var .. ".stop() is never called"
  end
end

--- `where` is the source that must carry the wiring; returns the local name.
local function presenceWiring(code, out, where)
  local var = requiredAs(code, "sbos.aipresence")
  if var == nil then
    out[#out + 1] = where .. ': no module-scope `local x = require("sbos.aipresence")`'
    return nil
  end
  if not calls(code, var, "start") then
    out[#out + 1] = where .. ": " .. var .. ".start( is never called"
  end
  if not calls(code, var, "stop") then
    out[#out + 1] = where .. ": " .. var .. ".stop() is never called"
  end
  return var
end

local function childProblems(dir)
  local out = {}
  propertyProblems(dir, out)
  local lua = read("drivers/" .. dir .. "/driver.lua")
  if lua == nil then
    out[#out + 1] = "driver.lua missing"
    return out
  end
  local code = stripLua(lua)
  if requiredAs(code, "sbos.aipresence") ~= nil then
    presenceWiring(code, out, "driver.lua")
  else
    local viaBase = nil
    for name, path in pairs(CHILD_BASES) do
      if requiredAs(code, name) ~= nil then
        viaBase = path
      end
    end
    if viaBase == nil then
      out[#out + 1] = "no sbos.aipresence wiring: neither driver.lua nor a child base it requires"
    else
      presenceWiring(stripLua(read(viaBase) or ""), out, viaBase)
    end
  end
  if code:find("require%(%s*[\"']sbos%.aireport[\"']") or code:find("require%(%s*[\"']sbos%.moduleclient[\"']") then
    out[#out + 1] = "a child carries sbos.aireport / sbos.moduleclient (ruling 20: passive module only)"
  end
  return out
end

local function rootProblems(dir)
  local out = {}
  propertyProblems(dir, out)
  local lua = read("drivers/" .. dir .. "/driver.lua")
  if lua == nil then
    out[#out + 1] = "driver.lua missing"
    return out
  end
  local code = stripLua(lua)
  if dir == VENUEFLOW then
    rootWiring(code, out, true)
    local var = presenceWiring(code, out, "driver.lua")
    if var ~= nil and not code:find(esc(var) .. "%.start%(%s*{[^}]*silent%s*=%s*true") then
      out[#out + 1] = var .. ".start({ silent = true }) is never called (the Remote Management off state)"
    end
  else
    rootWiring(code, out, false)
  end
  return out
end

local function agentProblems(dir)
  local out = {}
  propertyProblems(dir, out)
  local code = stripLua(read("drivers/" .. dir .. "/driver.lua") or "")
  if not ("\n" .. code):find("\nAgentAiCore%s*=%s*require%(%s*[\"']sbos%.agentaicore[\"']%s*%)") then
    out[#out + 1] = 'no module-scope global `AgentAiCore = require("sbos.agentaicore")`'
  end
  if not code:find("onDirectoryChanged%s*=%s*function%(%)%s*AgentAiCore%.refresh%(") then
    out[#out + 1] = "AgentAiCore.refresh( is not the bus's onDirectoryChanged hook"
  end
  local _, n = code:gsub("AgentAiCore%.refresh%(", "")
  if n < 3 then
    out[#out + 1] = "AgentAiCore.refresh( called " .. n .. " time(s); expected module start, directory change, status"
  end
  if ("\n" .. code):find("\nlocal%s+[%w_]+%s*=%s*require%(%s*[\"']sbos%.agentaicore") then
    out[#out + 1] = "sbos.agentaicore bound to a top-level LOCAL (the main chunk is at its limit)"
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

local function kindOf(dir)
  local file = dir .. ".c4z"
  if EXEMPT[dir] then
    return "exempt"
  elseif dir == AGENT then
    return "agent"
  elseif aipresence.CHILDREN[file] then
    return "child"
  elseif aireport.MODULE_IDS[file] then
    return "root"
  end
  return nil
end

print("[1] every driver directory shows AI Core, wired for its kind")
local counts = { root = 0, child = 0, agent = 0, exempt = 0, property = 0 }
for _, dir in ipairs(dirs) do
  local kind = kindOf(dir)
  if kind == nil then
    check(dir .. " is a root (aireport.MODULE_IDS) or a child (aipresence.CHILDREN)", false, "neither")
  elseif kind ~= "exempt" then
    counts[kind] = counts[kind] + 1
    if aiCoreProperty(read("drivers/" .. dir .. "/driver.xml") or "") ~= nil then
      counts.property = counts.property + 1
    end
    local problems = (kind == "agent" and agentProblems(dir))
      or (kind == "child" and childProblems(dir))
      or rootProblems(dir)
    if PENDING[dir] then
      check(dir .. ": still pending (not wired yet; once it is, remove it from PENDING)", #problems > 0)
    else
      check(dir .. " (" .. kind .. ") shows AI Core", #problems == 0, table.concat(problems, "; "))
    end
  else
    counts.exempt = counts.exempt + 1
  end
end

print("[2] the tables")
for file, root in pairs(aipresence.CHILDREN) do
  local dir = file:gsub("%.c4z$", "")
  local rootDir = root:gsub("%.c4z$", "")
  check(file .. ": names a real directory", present[dir] == true)
  check(
    file .. ": its root " .. root .. " is a real root directory",
    present[rootDir] == true and (aireport.MODULE_IDS[root] ~= nil or rootDir == AGENT)
  )
  check(file .. ": is not also a root", aireport.MODULE_IDS[file] == nil)
end
for file in pairs(aireport.MODULE_IDS) do
  check(file .. ": its directory exists", present[(file:gsub("%.c4z$", ""))] == true)
end
local nExempt = 0
for dir, reason in pairs(EXEMPT) do
  nExempt = nExempt + 1
  check(dir .. ": exemption has a written reason", type(reason) == "string" and #reason > 20)
  check(dir .. ": exempt directory exists (no stale exemption)", present[dir] == true)
end
check("AI Core is the only exemption", nExempt == 1 and EXEMPT["smartbuildos-ai-core"] ~= nil)
for dir in pairs(PENDING) do
  check(dir .. ": a pending entry is a driver directory", present[dir] == true and kindOf(dir) ~= nil)
end
for name, path in pairs(CHILD_BASES) do
  check(name .. ": child base exists", read(path) ~= nil)
end
print(
  string.format(
    "  (%d directories: %d roots, %d children, %d Agent; %d declare AI Core; exempt: %d; pending: %d)",
    #dirs,
    counts.root,
    counts.child,
    counts.agent,
    counts.property,
    counts.exempt,
    (function()
      local n = 0
      for _ in pairs(PENDING) do
        n = n + 1
      end
      return n
    end)()
  )
)

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
