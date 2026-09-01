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

-- ── The call convention ─────────────────────────────────────────────────────

print("\n[7] updateAll is a MODULE function — a colon call shifts every argument")
-- FIELD BUG 2026-08-31: pressing Update Drivers died with
--   driver.lua:991: bad argument #1 to 'pairs' (table expected, got string)
-- The driver called `sbosUpdater:updateAll(url, authHeaders(), ...)`. This
-- module ends in `return M` — plain dot functions — so the colon passed M
-- itself as `url` and slid every argument one place along: `headers` received
-- the URL STRING, and `pairs(headers or {})` threw before a request was made.
--
-- The neighbouring `githubUpdater:updateAll(...)` IS a colon call, correctly:
-- that module ends in `return GitHubUpdater:new()`. Two updaters side by side
-- with opposite conventions, and nothing that made them agree.

-- Stub the transport so updateAll can be driven without a Director. Registered
-- into package.loaded before the module under test is re-required.
local captured = nil
package.loaded["lib.http"] = {
  get = function(_self, url, headers)
    captured = { url = url, headers = headers }
    -- A deferred that never settles: this test is about what updateAll SENDS.
    return {
      next = function(d)
        return d
      end,
    }
  end,
}
package.loaded["lib.sbos-updater"] = nil
local mod = require("lib.sbos-updater")

local okDot = pcall(function()
  mod.updateAll(
    "https://sbos.test/api/driver-cloud/updates",
    { Authorization = "Bearer t" },
    FILES,
    "Production",
    false
  )
end)
check("a dot call reaches the request", okDot and captured ~= nil, okDot)
check(
  "the URL lands in `url`, not in `headers`",
  captured ~= nil and captured.url == "https://sbos.test/api/driver-cloud/updates?appetite=Production",
  captured and captured.url
)
check(
  "the auth header survives the copy into reqHeaders",
  captured ~= nil and captured.headers ~= nil and captured.headers.Authorization == "Bearer t",
  captured and captured.headers and captured.headers.Authorization
)

-- And the shape of the failure, so the reason this exists stays legible.
captured = nil
local okColon, err = pcall(function()
  mod:updateAll(
    "https://sbos.test/api/driver-cloud/updates",
    { Authorization = "Bearer t" },
    FILES,
    "Production",
    false
  )
end)
check("a colon call still fails on `pairs`", not okColon, err)
check(
  "and it fails exactly as the field reported",
  not okColon and tostring(err):find("table expected, got string", 1, true) ~= nil,
  err
)
check("nothing was sent", captured == nil)

print("\n[8] The driver calls it the way the module is written")
-- Asserted against the source: the bug was never inside updateAll.
local f = assert(io.open("drivers/smartbuildos/driver.lua", "r"))
local src = f:read("*a")
f:close()
check(
  "driver.lua uses sbosUpdater.updateAll",
  src:find("sbosUpdater%s*%.%s*updateAll") ~= nil,
  "call site does not use a dot"
)
check(
  "driver.lua does NOT use sbosUpdater:updateAll",
  src:find("sbosUpdater%s*:%s*updateAll") == nil,
  "a colon call is back — every argument shifts one place along"
)

print("\n[9] Everything the store publishes is a driver the Agent keeps current")
-- The gap this pins: a driver can be published to the store (a sku_for case
-- in .github/workflows/publish-to-store.yml) and still never update itself,
-- because the Agent only ever checks the filenames in DRIVER_FILENAMES.
-- Publishing and updating are two registries, and they drifted apart once —
-- Protect and Mode Composer shipped builds for weeks that no install ever
-- picked up.
local wf = assert(io.open(".github/workflows/publish-to-store.yml", "r"))
local workflow = wf:read("*a")
wf:close()

-- Filenames the publish map names, i.e. everything that can reach the store.
local published = {}
for line in workflow:gmatch("[^\n]+") do
  -- Only the case arms inside sku_for(), which are the lines mapping one or
  -- more *.c4z patterns to a SKU.
  if line:find("echo SBOS_") then
    for filename in line:gmatch("([%w%-%.]+%.c4z)") do
      published[filename] = true
    end
  end
end
check("the publish map was parsed", next(published) ~= nil, "found no *.c4z cases in sku_for()")

-- Read the list from SOURCE, not from a loaded global: this suite never
-- executes the driver (see [8]), and a source-level check also catches a
-- list that is correct only on some --#ifdef branch.
local listed = {}
local block = src:match("DRIVER_FILENAMES%s*=%s*{(.-)}")
check("DRIVER_FILENAMES was found in the source", block ~= nil)
for filename in tostring(block or ""):gmatch('"([%w%-%.]+%.c4z)"') do
  listed[filename] = true
end

local missing = {}
for filename in pairs(published) do
  if not listed[filename] then
    missing[#missing + 1] = filename
  end
end
table.sort(missing)
check(
  "no published driver is left out of DRIVER_FILENAMES",
  #missing == 0,
  #missing > 0 and ("publishes but never updates: " .. table.concat(missing, ", ")) or nil
)

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
