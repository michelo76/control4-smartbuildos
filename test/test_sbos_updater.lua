-- The SmartBuildOS updater's decision logic: which hosted builds to install.
-- The install itself (write + TCP UpdateProjectC4i) needs a live Director, but
-- the part that would install the WRONG thing — picking outdated/foreign/
-- uninstalled builds — is pure and tested here.

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

-- Globals the updater's pure logic leans on (the driver runtime provides these;
-- the test stubs them minimally).
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

-- Which drivers are "installed" in the fake project, and at what version.
local INSTALLED = { ["smartbuildos.c4z"] = "20260829.170919" }
function GetDriverVersion(fn)
  return INSTALLED[fn] or ""
end
C4 = C4 or {}
function C4:GetDevicesByC4iName(fn)
  return INSTALLED[fn] ~= nil and { 1 } or {}
end

local updater = require("lib.sbos-updater")
local FILES = { "smartbuildos.c4z", "unifi-protect.c4z" }

print("\n[1] Picks a newer build for an installed driver")
local out = updater.outdated({
  { filename = "smartbuildos.c4z", version = "20260829.175513", download_url = "https://x/a.c4z" },
}, FILES, false)
check("one build selected", #out == 1, #out)
check("it is the newer smartbuildos build", out[1] and out[1].version == "20260829.175513", out[1] and out[1].version)

print("\n[2] Skips an OLDER build (never a downgrade)")
out = updater.outdated({
  { filename = "smartbuildos.c4z", version = "20260829.160000", download_url = "https://x/a.c4z" },
}, FILES, false)
check("no build selected", #out == 0, #out)

print("\n[3] Skips a driver that is not installed in this project")
out = updater.outdated({
  { filename = "unifi-protect.c4z", version = "20990101.000000", download_url = "https://x/u.c4z" },
}, FILES, false)
check("uninstalled driver ignored", #out == 0, #out)

print("\n[4] Skips a build with no download URL")
out = updater.outdated({
  { filename = "smartbuildos.c4z", version = "20260829.999999" },
}, FILES, false)
check("no-URL build ignored", #out == 0, #out)

print("\n[5] Ignores a filename that is not part of this suite")
out = updater.outdated({
  { filename = "some-other.c4z", version = "20990101.000000", download_url = "https://x/o.c4z" },
}, FILES, false)
check("foreign filename ignored", #out == 0, #out)

print("\n[6] forceUpdate re-selects an already-current build")
out = updater.outdated({
  { filename = "smartbuildos.c4z", version = "20260829.170919", download_url = "https://x/a.c4z" },
}, FILES, true)
check("force selects the current build", #out == 1, #out)

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
