-- SmartBuildOS AI Core: update delivery (SIMULATION ONLY). The Agent's
-- SmartBuildOS-store updater (src/lib/sbos-updater.lua) decides what to
-- install by comparing each hosted package's `version` — the <version>
-- inside the .c4z, which publish-to-store.yml extracts — with the installed
-- driver's version. The download, the write to C4Z_ROOT and Director's
-- UpdateProjectC4i need a controller (docs/ai-core/TEST-MATRIX.md, hardware).
--
--   [1] the Agent's real DRIVER_FILENAMES / SKU_FILENAMES name the AI Core file
--   [2] a newer AI Core build is picked up; equal / older / not installed are not
--   [3] build versions (date -u +%Y%m%d.%H%M%S) order correctly, incl. a
--       leading-zero time and a day boundary
--   [4] the store publish workflow maps the file to SBOS_AI_CORE and reads
--       the version inside the .c4z, not the tag
--
-- Run from the driver root: make test

local pass, fail = 0, 0
local function check(name, cond, detail)
  if cond then
    pass = pass + 1
    print(string.format("  ok   %s", name))
  else
    fail = fail + 1
    print(string.format("  FAIL %s%s", name, detail and ("  -> " .. tostring(detail)) or ""))
  end
end

require("c4_shim")

local function read(path)
  local f = assert(io.open(path))
  local s = f:read("*a")
  f:close()
  return s
end

function TableReverse(t)
  local r = {}
  for _, v in pairs(t or {}) do
    r[v] = true
  end
  return r
end
function IsEmpty(v)
  if v == nil then
    return true
  end
  if type(v) == "string" then
    return v == ""
  end
  if type(v) == "table" then
    return next(v) == nil
  end
  return false
end

local FILE = "smartbuildos-ai-core.c4z"
local INSTALLED = {}
function GetDriverVersion(fn)
  return INSTALLED[fn] or ""
end
C4 = C4 or {}
function C4:GetDevicesByC4iName(fn)
  return INSTALLED[fn] ~= nil and { 1 } or {}
end

print("[1] the Agent's file lists name AI Core")
local agent = read("drivers/smartbuildos/driver.lua")
local block = agent:match("\nDRIVER_FILENAMES = (%b{})")
local FILES = {}
for name in tostring(block):gmatch('"([^"]+%.c4z)"') do
  FILES[#FILES + 1] = name
end
check("the Agent's DRIVER_FILENAMES lists " .. FILE, TableReverse(FILES)[FILE] == true, #FILES .. " files")
check(
  "SKU_FILENAMES.SBOS_AI_CORE → " .. FILE .. " (configuration forwarding)",
  agent:find('SBOS_AI_CORE = { "smartbuildos%-ai%-core%.c4z" }') ~= nil
)
check(
  "the AI Core driver names its own file for the GitHub updater",
  read("drivers/smartbuildos-ai-core/driver.lua"):find('DRIVER_FILENAMES = { "smartbuildos%-ai%-core%.c4z" }') ~= nil
)

local updater = require("lib.sbos-updater")
local function pick(installed, offered, force)
  INSTALLED = { [FILE] = installed }
  local out =
    updater.outdated({ { filename = FILE, version = offered, download_url = "https://x/ai.c4z" } }, FILES, force)
  return #out == 1
end

print("[2] the store updater picks up a newer AI Core")
check("newer → installed", pick("20261118.120000", "20261119.090000"))
check("same → not re-installed", not pick("20261118.120000", "20261118.120000"))
check("older → never a downgrade", not pick("20261118.120000", "20261117.235959"))
check("same + force → re-installed (Update Drivers, forced)", pick("20261118.120000", "20261118.120000", true))
INSTALLED = {}
local none = updater.outdated(
  { { filename = FILE, version = "20991231.235959", download_url = "https://x/ai.c4z" } },
  FILES,
  false
)
check("not installed in this project → never added by an update", #none == 0)

print("[3] build versions order correctly")
check("leading-zero time: 093000 < 120000 on the same day", pick("20261118.093000", "20261118.120000"))
check("…and not the other way", not pick("20261118.120000", "20261118.093000"))
check("day boundary: 235959 < next day 000001", pick("20261118.235959", "20261119.000001"))
check("seconds matter: 120000 < 120001", pick("20261118.120000", "20261118.120001"))
local makefile = read("Makefile")
check("the build mints the version as UTC YYYYMMDD.HHMMSS", makefile:find("date -u +'%Y%m%d.%H%M%S'", 1, true) ~= nil)

print("[4] the store publish workflow")
local wf = read(".github/workflows/publish-to-store.yml")
check("sku_for maps " .. FILE .. " → SBOS_AI_CORE", wf:find("smartbuildos%-ai%-core%.c4z%) echo SBOS_AI_CORE") ~= nil)
check(
  "the uploaded version is the <version> inside the .c4z, not the tag",
  wf:find('unzip %-p "%$f" driver%.xml') ~= nil and wf:find("<version>%[0%-9%.%]%+</version>") ~= nil
)
local sample = "<version>20261118.093000</version>"
check(
  "that extraction keeps a leading-zero time intact",
  sample:match("<version>([0-9.]+)</version>") == "20261118.093000"
)

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
