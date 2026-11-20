-- Packaging check for EVERY driver, with no packager: what the build's own
-- offline steps would squish into each .c4z, against what the driver can
-- `require` at run time.
--
-- A driver whose squished driver.lua misses a module it requires fails to
-- load on a controller, and unit tests that load raw source do not see it:
-- tools/gen-squishy.lua builds the list from package.loaded after loading
-- driver.lua under the shim and calling OnDriverInit / OnDriverLateInit once,
-- so a require that only runs later (inside a function, a timer, a branch the
-- shim never takes) is left out. Measured 2026-11-09: the Event Tracer
-- shipped without tracer.catalog_data. test/test_driver_require_guard.lua
-- catches an indented require in a driver.lua only; test/test_aicore_package.lua
-- walks AI Core alone. This walks every driver, every module, transitively.
--
-- In a scratch folder (never the repo's build/), exactly as the Makefile does
-- before the packager:
--   [1] tools/preprocess.py --oss on a copy of src/ drivers/ vendor/ tools/
--       and test/c4_shim.lua (the `oss` distribution's #ifdef branches);
--   [2] tools/gen-squishy.lua from each build/oss/drivers/<dir>/ (the squish
--       list: `Module "name" "path"` lines of its squishy file);
-- then, for EVERY directory in drivers/:
--   [3] the static require closure of the PREPROCESSED driver.lua (string
--       literal `require("x")`, `require "x"` and `pcall(require, "x")`,
--       comments stripped, followed through every module it resolves to under
--       the build's src/, vendor/ or the driver folder — gen-squishy's own
--       package.path) is entirely in that driver's squish list;
--   [4] no child driver's list holds sbos.aireport or sbos.moduleclient
--       (children only look AI Core up through sbos.aipresence; ruling 20).
-- Names that resolve to no file (Director-provided modules) are listed as
-- information, not failed. A require built from a variable cannot be seen.
-- It also prints, per driver, the bytes of the squish input (preprocessed
-- driver.lua plus every listed module): that is source in, not a .c4z size.
--
-- SQUISH_SRC=<dir> runs it against another source tree (for a size baseline).
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

local function read(path)
  local f = io.open(path, "rb")
  if f == nil then
    return nil
  end
  local s = f:read("*a")
  f:close()
  return s
end

local function sh(cmd)
  local p = io.popen(cmd .. ' 2>&1; echo "__exit=$?"')
  local out = p:read("*a")
  p:close()
  local code = tonumber(out:match("__exit=(%d+)%s*$"))
  return code, (out:gsub("__exit=%d+%s*$", ""))
end

local function q(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function stripComments(src)
  src = src:gsub("%-%-%[(=*)%[.-%]%1%]", "")
  return (src:gsub("%-%-[^\n]*", ""))
end

local SRC = os.getenv("SQUISH_SRC") or "."
local _, tmpOut = sh("mktemp -d -t sbos-squish")
local TMP = tmpOut:match("([^\n]+)")
check("scratch folder created", TMP ~= nil and TMP:match("sbos%-squish") ~= nil, TMP)
if TMP == nil then
  os.exit(1)
end

print("[1] preprocess --oss in a scratch copy")
local code, out = sh(
  "mkdir -p "
    .. q(TMP .. "/tools")
    .. " "
    .. q(TMP .. "/test")
    .. " && cp "
    .. q(SRC .. "/tools/preprocess.py")
    .. " "
    .. q(SRC .. "/tools/gen-squishy.lua")
    .. " "
    .. q(TMP .. "/tools/")
    .. " && cp "
    .. q(SRC .. "/test/c4_shim.lua")
    .. " "
    .. q(TMP .. "/test/")
    .. " && cp -R "
    .. q(SRC .. "/src")
    .. " "
    .. q(SRC .. "/drivers")
    .. " "
    .. q(SRC .. "/vendor")
    .. " "
    .. q(TMP)
    .. " && { [ ! -d "
    .. q(SRC .. "/documentation")
    .. " ] || cp -R "
    .. q(SRC .. "/documentation")
    .. " "
    .. q(TMP)
    .. "; } && python3 "
    .. q(TMP .. "/tools/preprocess.py")
    .. " --oss"
)
check("preprocess.py --oss ran", code == 0, out)
local BUILD = TMP .. "/build/oss"

local dirs = {}
do
  local p = io.popen("ls -1 " .. q(SRC .. "/drivers"))
  for line in p:lines() do
    if read(SRC .. "/drivers/" .. line .. "/driver.lua") then
      dirs[#dirs + 1] = line
    end
  end
  p:close()
end
check("drivers found (" .. #dirs .. ")", #dirs > 0, #dirs)

print("[2] gen-squishy for every driver")
local squish = {} -- dir -> { [name] = path } | nil
for _, dir in ipairs(dirs) do
  local ddir = BUILD .. "/drivers/" .. dir
  local c, o = sh("cd " .. q(ddir) .. " && luajit ../../../../tools/gen-squishy.lua")
  local text = c == 0 and read(ddir .. "/squishy") or nil
  if text then
    local list = {}
    for name, path in text:gmatch('Module "([^"]+)" "([^"]+)"') do
      list[name] = path
    end
    squish[dir] = list
  end
  check(dir .. ": squish list generated", text ~= nil, o:match("[^\n]*$"))
end

-- gen-squishy's package.path, from the driver folder.
local function resolve(ddir, name)
  local rel = name:gsub("%.", "/")
  for _, pat in ipairs({
    "../../src/?.lua",
    "../../src/?/init.lua",
    "../../vendor/?.lua",
    "../../vendor/?/init.lua",
    "./?.lua",
    "./?/init.lua",
  }) do
    local path = pat:gsub("%?", rel)
    if read(ddir .. "/" .. path) then
      return path
    end
  end
  return nil
end

local function requiresIn(src)
  local names = {}
  src = stripComments(src)
  for name in src:gmatch("require%s*%(?%s*[\"']([%w%._%-]+)[\"']") do
    names[#names + 1] = name
  end
  for name in src:gmatch("pcall%(%s*require%s*,%s*[\"']([%w%._%-]+)[\"']") do
    names[#names + 1] = name
  end
  return names
end

print("[3] every module a driver can require is in its squish list")
local sizes = {}
for _, dir in ipairs(dirs) do
  local ddir = BUILD .. "/drivers/" .. dir
  local list = squish[dir]
  if list then
    local closure, unresolved, missing = {}, {}, {}
    local function walk(path)
      for _, name in ipairs(requiresIn(read(ddir .. "/" .. path) or "")) do
        if closure[name] == nil and unresolved[name] == nil then
          local file = resolve(ddir, name)
          if file then
            closure[name] = file
            walk(file)
          else
            unresolved[name] = true
          end
        end
      end
    end
    walk("driver.lua")
    local n = 0
    for name in pairs(closure) do
      n = n + 1
      if list[name] == nil then
        missing[#missing + 1] = name
      end
    end
    table.sort(missing)
    check(
      dir .. ": all " .. n .. " modules of the require closure are squished in",
      #missing == 0,
      table.concat(missing, ", ")
    )
    local un = {}
    for name in pairs(unresolved) do
      un[#un + 1] = name
    end
    table.sort(un)
    if #un > 0 then
      print("  info " .. dir .. ": required but resolves to no file (Director-provided?): " .. table.concat(un, ", "))
    end
    local bytes = #(read(ddir .. "/driver.lua") or "")
    for _, path in pairs(list) do
      bytes = bytes + #(read(ddir .. "/" .. path) or "")
    end
    sizes[#sizes + 1] = string.format("%s=%d", dir, bytes)
  end
end

print("[4] no child squishes the report helper or the module client")
do
  local children = {}
  local presence = read(SRC .. "/src/sbos/aipresence.lua") or ""
  local block = presence:match("M%.CHILDREN%s*=%s*(%b{})") or ""
  for file in block:gmatch('%["([%w%._%-]+)%.c4z"%]%s*=') do
    children[#children + 1] = file
  end
  check("children read from sbos.aipresence (" .. #children .. ")", #children > 0, #children)
  for _, dir in ipairs(children) do
    local list = squish[dir]
    check(dir .. ": a driver directory with a squish list", list ~= nil)
    if list then
      local bad = {}
      for _, name in ipairs({ "sbos.aireport", "sbos.moduleclient" }) do
        if list[name] then
          bad[#bad + 1] = name
        end
      end
      check(dir .. ": squishes neither sbos.aireport nor sbos.moduleclient", #bad == 0, table.concat(bad, ", "))
    end
  end
end

print("  info squish input bytes (preprocessed source, not a .c4z size): " .. table.concat(sizes, " "))

if TMP and TMP:match("sbos%-squish") then
  sh("rm -rf " .. q(TMP))
end

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
