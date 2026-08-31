-- Guard test for the Atmosphere Navigator WebView single-file app.
--
-- The page ships inside the .c4z and renders on T3/T4 panels behind a
-- strict CSP. It must be fully self-contained: the ONLY external host it
-- may ever reference is radar.weather.gov (NWS RIDGE imagery). Everything
-- else — fonts, scripts, styles — must be inlined, and the driver command
-- vocabulary must stay in sync with driver.lua.
--
-- Run from the repo root:
--   luajit -e "require('c4_shim')" test/test_atmosphere_webview.lua

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

local function readFile(path)
  local f = io.open(path, "rb")
  if f == nil then
    return nil
  end
  local body = f:read("*a")
  f:close()
  return body
end

-- Support both invocation styles the suite allows: repo root and test/.
local html, htmlPath
for _, candidate in ipairs({
  "drivers/smartbuildos-atmosphere/www/app/index.html",
  "../drivers/smartbuildos-atmosphere/www/app/index.html",
}) do
  html = readFile(candidate)
  if html ~= nil then
    htmlPath = candidate
    break
  end
end

check("index.html exists and is non-empty", html ~= nil and #html > 0, htmlPath or "not found")
if html == nil then
  print(string.format("%d passed, %d failed", pass, fail))
  os.exit(1)
end

-- (2) Every http(s):// occurrence must point at radar.weather.gov.
local badUrls = {}
for url in html:gmatch("https?://[%w%.%-]+") do
  if url ~= "https://radar.weather.gov" then
    table.insert(badUrls, url)
  end
end
check(
  "no external URLs besides https://radar.weather.gov",
  #badUrls == 0,
  #badUrls > 0 and table.concat(badUrls, ", ") or nil
)

-- Belt-and-braces: any bare protocol occurrence must be the radar host.
local protoCount, radarCount = 0, 0
for _ in html:gmatch("https?://") do
  protoCount = protoCount + 1
end
for _ in html:gmatch("https://radar%.weather%.gov") do
  radarCount = radarCount + 1
end
check(
  "every protocol occurrence is the radar host",
  protoCount == radarCount,
  string.format("%d protocol refs, %d radar refs", protoCount, radarCount)
)

-- (3) No external script/style loading.
local lower = html:lower()
check("no <script src=...>", lower:find("<script%s+[^>]*src%s*=") == nil)
check('no <link ... href="http', lower:find('<link[^>]*href%s*=%s*["\']http') == nil)

-- (4) CSP meta tag present.
check(
  "CSP meta tag present",
  html:find('http%-equiv="Content%-Security%-Policy"') ~= nil
    and html:find("default%-src 'none'") ~= nil
)

-- (5) Size budget: the whole app must stay under 300 KB.
check(
  string.format("file under 300KB (actual: %.1f KB)", #html / 1024),
  #html < 300 * 1024
)

-- (6) Full driver command vocabulary present.
for _, cmd in ipairs({ "ATMOS_GET_STATE", "ATMOS_SET_SETTINGS", "ATMOS_REFRESH", "ATMOS_SIMULATE" }) do
  check("references command " .. cmd, html:find(cmd, 1, true) ~= nil)
end

print(string.format("%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
