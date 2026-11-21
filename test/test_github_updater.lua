-- The GitHub fallback updater's decision: which release assets to install.
--
-- FIELD RISK 2026-11-20: the updater compared the latest release against the
-- OLDEST installed SmartBuildOS driver and then took the release's asset for
-- EVERY installed driver. One stale sibling was enough to pull a newer,
-- hand-loaded Agent (20261120.x) back to the public release (20261116.x).
-- The rule is now per driver file, and it is the platform updater's rule.

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
require("lib.utils")
require("drivers-common-public.global.lib")

-- The installed project: filename -> installed version.
local INSTALLED = {}
function GetDriverVersion(fn)
  return INSTALLED[fn]
end
C4 = C4 or {}
function C4:GetDevicesByC4iName(fn)
  return INSTALLED[fn] ~= nil and { 1 } or {}
end

-- The GitHub releases list the stubbed transport answers with.
local RELEASES = {}
package.loaded["lib.http"] = {
  get = function(_self, _url, _headers)
    local d = require("deferred").new()
    d:resolve({ code = 200, body = RELEASES })
    return d
  end,
}
package.loaded["lib.github-updater"] = nil
local updater = require("lib.github-updater")

local function asset(name)
  return { name = name, browser_download_url = "https://example.invalid/" .. name }
end

local function release(tag, prerelease, names)
  local assets = {}
  for _, n in ipairs(names) do
    assets[#assets + 1] = asset(n)
  end
  return { tag_name = tag, name = tag, draft = false, prerelease = prerelease, assets = assets }
end

local ALL = { "smartbuildos.c4z", "smartbuildos-atmosphere.c4z", "smartbuildos-ai-core.c4z" }

--- Runs the decision and returns the sorted asset names (or nil, err).
local function decide(files, prerelease, force)
  local result, rejected
  updater:getOutdatedDriverAssets("owner/repo", files, prerelease, force):next(function(assets)
    result = assets
  end, function(err)
    rejected = err
  end)
  if result == nil then
    return nil, rejected
  end
  local names = {}
  for _, a in ipairs(result) do
    names[#names + 1] = a.name
  end
  table.sort(names)
  return table.concat(names, ",")
end

print("\n[1] Mixed versions: only the older driver updates")
RELEASES = { release("20261116.035552", false, ALL) }
INSTALLED = {
  ["smartbuildos.c4z"] = "20261120.160545", -- hand-loaded, newer than the release
  ["smartbuildos-atmosphere.c4z"] = "20260831.051407", -- older sibling
  ["smartbuildos-ai-core.c4z"] = "20261120.145352",
}
local got, err = decide(ALL, false, false)
check("only the older sibling is taken", got == "smartbuildos-atmosphere.c4z", got or err)
check("the newer hand-loaded Agent is left alone", got ~= nil and not got:find("smartbuildos.c4z,", 1, true), got)

print("\n[2] All current: nothing downloads")
INSTALLED = {
  ["smartbuildos.c4z"] = "20261116.035552",
  ["smartbuildos-atmosphere.c4z"] = "20261116.035552",
  ["smartbuildos-ai-core.c4z"] = "20261116.035552",
}
got, err = decide(ALL, false, false)
check("nothing selected", got == "", got or err)

print("\n[3] Installed newer than the release: nothing downloads, even forced")
INSTALLED = {
  ["smartbuildos.c4z"] = "20261120.210226",
  ["smartbuildos-atmosphere.c4z"] = "20261120.210226",
  ["smartbuildos-ai-core.c4z"] = "20261120.210226",
}
got, err = decide(ALL, false, false)
check("nothing selected", got == "", got or err)
got, err = decide(ALL, false, true)
check("a forced update never downgrades", got == "", got or err)
INSTALLED["smartbuildos-atmosphere.c4z"] = "20261116.035552"
got, err = decide(ALL, false, true)
check("a forced update re-installs only a driver AT the release", got == "smartbuildos-atmosphere.c4z", got or err)

print("\n[4] Beta channel vs production tags")
-- GitHub lists newest first; the prerelease is skipped on Production.
RELEASES = {
  release("20261121.010101", true, ALL),
  release("20261116.035552", false, ALL),
}
INSTALLED = {
  ["smartbuildos.c4z"] = "20261120.160545",
  ["smartbuildos-atmosphere.c4z"] = "20261116.035552",
  ["smartbuildos-ai-core.c4z"] = "20261120.145352",
}
got, err = decide(ALL, false, false)
check("Production ignores the newer prerelease: nothing to do", got == "", got or err)
got, err = decide(ALL, true, false)
check(
  "Prerelease takes the prerelease, for every driver it is newer than",
  got == "smartbuildos-ai-core.c4z,smartbuildos-atmosphere.c4z,smartbuildos.c4z",
  got or err
)

print("\n[5] An unparsable tag is skipped, never compared")
-- NOTE: the vendored parser is lenient: "beta-20261116.035552" parses as
-- 20261116.35552 (pinned in [8]). A tag with no version in it does not.
RELEASES = {
  release("nightly", false, ALL),
  release("20261116.035552", false, ALL),
}
INSTALLED = {
  ["smartbuildos.c4z"] = "20261120.160545",
  ["smartbuildos-atmosphere.c4z"] = "20261101.000000",
}
got, err = decide({ "smartbuildos.c4z", "smartbuildos-atmosphere.c4z" }, false, false)
check("the next valid release decides, per driver", got == "smartbuildos-atmosphere.c4z", got or err)

print("\n[6] An unreadable installed version skips that driver only")
RELEASES = { release("20261116.035552", false, ALL) }
INSTALLED = {
  ["smartbuildos.c4z"] = "",
  ["smartbuildos-atmosphere.c4z"] = "20260831.051407",
}
got, err = decide({ "smartbuildos.c4z", "smartbuildos-atmosphere.c4z" }, false, false)
check("the readable older driver still updates", got == "smartbuildos-atmosphere.c4z", got or err)

print("\n[7] A release missing one asset still updates the others")
RELEASES = { release("20261116.035552", false, { "smartbuildos-atmosphere.c4z" }) }
INSTALLED = {
  ["smartbuildos.c4z"] = "20261101.000000",
  ["smartbuildos-atmosphere.c4z"] = "20261101.000000",
}
got, err = decide({ "smartbuildos.c4z", "smartbuildos-atmosphere.c4z" }, false, false)
check("the present asset is taken", got == "smartbuildos-atmosphere.c4z", got or err)

print("\n[8] The platform updater uses the same rule")
local sbos = require("lib.sbos-updater")
check("strictly newer installs", sbos.shouldInstall("20261116.035552", "20261101.000000", false) == true)
check("older never installs", sbos.shouldInstall("20261116.035552", "20261120.160545", true) == false)
check("same installs only when forced", sbos.shouldInstall("20261116.035552", "20261116.035552", true) == true)
check("an unparsable candidate never installs", sbos.shouldInstall("nightly", "20261101.000000") == false)
check("an unparsable installed version never installs", sbos.shouldInstall("20261116.035552", "") == false)
check(
  "a beta- tag parses as its date (lenient parser, pinned)",
  sbos.shouldInstall("beta-20261116.035552", "20261101.000000") == true
)

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
