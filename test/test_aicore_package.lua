-- AI Core packaging: what Director will load from the .c4z.
--
-- Two traps this pins (analysis 03 §10): a `require` inside a function is
-- never seen by the build's squish step, so the module is silently left out
-- of the .c4z; and a driver.xml without <script file="driver.lua"> ships a
-- driver that runs no Lua while every Lua test passes.
--
--   [1] always: the static require closure of driver.lua (src/ and vendor/,
--       followed transitively) — every src/aicore module is in it, and every
--       module in it is loaded at module scope when the driver loads under
--       the shim (what gen-squishy sees).
--   [2] when dist/oss/smartbuildos-ai-core.c4z exists (a build has run): the
--       squished driver.lua holds a package.preload for EVERY module of the
--       closure, the packaged driver.xml has the <script> and
--       <documentation> tags and a stamped version, the documentation file
--       is inside. Without a build this part reports "skip" and does not
--       pass or fail anything.
--
-- Run from the driver root: make test

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

local function read(path)
  local f = io.open(path, "r")
  if f == nil then
    return nil
  end
  local s = f:read("*a")
  f:close()
  return s
end

local function stripComments(src)
  return (src:gsub("%-%-%[(=*)%[.-%]%1%]", ""):gsub("%-%-[^\n]*", ""))
end

local function resolve(name)
  local rel = name:gsub("%.", "/")
  for _, base in ipairs({ "src/", "vendor/" }) do
    for _, suffix in ipairs({ ".lua", "/init.lua" }) do
      local path = base .. rel .. suffix
      if read(path) then
        return path
      end
    end
  end
  return nil
end

print("[1] the static require closure")
local closure, order = {}, {}
local function walk(path)
  local src = stripComments(read(path) or "")
  for name in src:gmatch('require%s*%(%s*"([^"]+)"%s*%)') do
    if not closure[name] then
      local file = resolve(name)
      if file then
        closure[name] = file
        order[#order + 1] = name
        walk(file)
      end
    end
  end
end
walk("drivers/smartbuildos-ai-core/driver.lua")
table.sort(order)
check("closure found", #order > 10, #order)
local p = io.popen("ls src/aicore")
for f in p:lines() do
  local mod = "aicore." .. f:gsub("%.lua$", "")
  check("src/aicore/" .. f .. " is in the closure", closure[mod] ~= nil)
end
p:close()

-- What the squish step sees: load the driver under the shim and read
-- package.loaded (LateInit never runs here, exactly as in gen-squishy).
C4 = C4 or {}
require("c4_shim")
function C4:GetVersionInfo()
  return { version = "4.2.0.0" }
end
Properties = {}
for block in read("drivers/smartbuildos-ai-core/driver.xml"):gmatch("<property>(.-)</property>") do
  Properties[block:match("<name>(.-)</name>")] = block:match("<default>(.-)</default>") or ""
end
dofile("drivers/smartbuildos-ai-core/driver.lua")
local notLoaded = {}
for _, name in ipairs(order) do
  if name:find("^aicore%.") or name:find("^sbos%.") then
    if package.loaded[name] == nil then
      notLoaded[#notLoaded + 1] = name
    end
  end
end
check(
  "every aicore./sbos. module of the closure loads at module scope (squish sees it)",
  #notLoaded == 0,
  table.concat(notLoaded, ", ")
)

print("[2] the built .c4z")
local C4Z = os.getenv("AICORE_C4Z") or "dist/oss/smartbuildos-ai-core.c4z"
if read(C4Z) == nil then
  print("  skip (no " .. C4Z .. "; run a build to check the package)")
else
  local function unzip(member)
    local h = io.popen("unzip -p '" .. C4Z .. "' '" .. member .. "' 2>/dev/null")
    local s = h:read("*a")
    h:close()
    return s
  end
  local lua = unzip("driver.lua")
  local xml = unzip("driver.xml")
  check("driver.lua inside", #lua > 0)
  local missing = {}
  for _, name in ipairs(order) do
    local esc = name:gsub("%p", "%%%0")
    if
      not (
        lua:find("package%.preload%[%s*'" .. esc .. "'%s*%]") or lua:find('package%.preload%[%s*"' .. esc .. '"%s*%]')
      )
    then
      missing[#missing + 1] = name
    end
  end
  check("every module of the closure is squished in (" .. #order .. ")", #missing == 0, table.concat(missing, ", "))
  check('<script file="driver.lua"> present', xml:find('<script%s+file="driver%.lua"') ~= nil)
  check("version stamped", xml:match("<version>(%d+%.%d+)</version>") ~= nil, xml:match("<version>(.-)</version>"))
  local doc = xml:match('<documentation%s+file="([^"]+)"')
  check("<documentation> tag", doc ~= nil)
  local list = io.popen("unzip -l '" .. C4Z .. "'")
  local listing = list:read("*a")
  list:close()
  check("the documentation file it names is inside", doc ~= nil and listing:find(doc, 1, true) ~= nil, doc)
  check("the minimum OS is declared", xml:find("<minimum_os_version>3%.3%.2</minimum_os_version>") ~= nil)
end

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
