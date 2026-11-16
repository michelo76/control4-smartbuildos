-- VenueFlow static release checks: things that must hold in the SOURCE, the
-- built pages and the package, whatever the tests above exercise.
--
--   * no code evaluation anywhere in the engines or the pages
--   * the pages load nothing from outside and keep nothing in localStorage
--   * no development credential or sample PIN reaches a page or the driver
--   * the built pages match their sources, the embedded modules match the pages
--   * the Installer Passcode is a hidden property and stays out of debug output
--   * the .c4z (when built) holds exactly what it should
--
-- Run from the driver root: make test

local pass, fail, skipped = 0, 0, 0
local function check(name, ok, detail)
  if ok then
    pass = pass + 1
    print(string.format("  ok   %s", name))
  else
    fail = fail + 1
    print(string.format("  FAIL %s%s", name, detail ~= nil and ("  -> " .. tostring(detail)) or ""))
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

local function list(command)
  local out = {}
  local pipe = io.popen(command)
  for line in pipe:lines() do
    out[#out + 1] = line
  end
  pipe:close()
  return out
end

--- Lua source with comments and string contents removed is hard to get
--- right; these checks look for CALLS, which comments rarely imitate.
local function stripLuaComments(src)
  src = src:gsub("%-%-%[%[.-%]%]", "")
  src = src:gsub("%-%-[^\n]*", "")
  return src
end

-- ── the engines ─────────────────────────────────────────────────────────────
print("engines: no code evaluation, no shell, no file access")
local modules = list("ls src/venueflow/*.lua")
check("modules found", #modules >= 20, #modules)
for _, path in ipairs(modules) do
  if not path:match("page_%w+%.lua$") then
    local src = stripLuaComments(read(path))
    for _, banned in ipairs({
      "loadstring%s*%(",
      "[^%w_.:]load%s*%(",
      "dofile%s*%(",
      "loadfile%s*%(",
      "os%.execute",
      "io%.popen",
      "io%.open",
      "setfenv",
      "debug%.",
    }) do
      check(path .. " has no " .. banned, src:find(banned) == nil)
    end
  end
end
do
  local src = stripLuaComments(read("drivers/smartbuildos-venueflow/driver.lua"))
  for _, banned in ipairs({ "loadstring%s*%(", "dofile%s*%(", "os%.execute", "io%.popen" }) do
    check("driver.lua has no " .. banned, src:find(banned) == nil)
  end
  check(
    "driver.lua commands devices only through the adapter and the recorder marker",
    select(2, src:gsub("SendToDevice", "")) == 1
  )
end
check(
  "only adapter_c4.lua talks to Control4 devices",
  (function()
    for _, path in ipairs(modules) do
      if not path:match("adapter_c4%.lua$") and not path:match("page_%w+%.lua$") then
        local src = stripLuaComments(read(path))
        if src:find("C4:", 1, true) or src:find("C4%.") then
          return false, path
        end
      end
    end
    return true
  end)()
)

-- ── the pages ───────────────────────────────────────────────────────────────
print("pages: self-contained, nothing stored in the browser but the session")
local pages = {
  app = read("drivers/smartbuildos-venueflow/www/app/index.html"),
  studio = read("drivers/smartbuildos-venueflow/www/studio/index.html"),
}
for name, html in pairs(pages) do
  check(name .. " page is built", type(html) == "string" and #html > 20000, html and #html)
  if html ~= nil then
    -- Everything a browser could fetch: src=, href=, url(...), @import, fetch of an absolute URL.
    local external = {}
    for url in html:gmatch("https?://[%w%.%-_/:%%?=&#~+]+") do
      if
        not url:find("^http://www%.w3%.org/")
        and not url:find("^https?://localhost")
        and not url:find("^https?://<")
      then
        external[#external + 1] = url
      end
    end
    check(name .. " page names no external address", #external == 0, table.concat(external, " "))
    check(name .. " page has no <script src>", html:find("<script[^>]+src%s*=") == nil)
    check(name .. " page has no <link> to a stylesheet", html:find("<link[^>]+stylesheet") == nil)
    check(name .. " page has no @import", html:find("@import", 1, true) == nil)
    check(name .. " page has no eval", html:find("[^%w_.]eval%s*%(") == nil)
    check(name .. " page has no new Function", html:find("new%s+Function%s*%(") == nil)
    check(name .. " page has no document.write", html:find("document%.write") == nil)
    check(name .. " page never uses localStorage", html:find("localStorage", 1, true) == nil)
    check(
      name .. " page builds no HTML from strings (innerHTML)",
      html:find("innerHTML", 1, true) == nil
        and html:find("insertAdjacentHTML", 1, true) == nil
        and html:find("outerHTML", 1, true) == nil
    )
    check(name .. " page has no inline on...= handler attribute", html:find("<[%a]+[^>]-%son%a+%s*=%s*[\"']") == nil)
    check(name .. " page does not hold the development passcode", html:find("install-123", 1, true) == nil)
    check(
      name .. " page does not hold the development tile token",
      html:find("devtile0123456789abcdef", 1, true) == nil
    )
    check(name .. " page does not hold the sample PIN", html:find("2580", 1, true) == nil)
    check(
      name .. " page ends its scripts properly",
      select(2, html:gsub("<script>", "")) == select(2, html:gsub("</script>", ""))
    )
  end
end
do
  local ok = os.execute("python3 tools/venueflow-ui.py check >/dev/null 2>&1")
  check("the built pages match ui/venueflow (run `make venueflow-ui` if not)", ok == true or ok == 0)
  ok = os.execute("luajit tools/embed-pages.lua --check >/dev/null 2>&1")
  check("the embedded page modules match the built pages (run `make embed-pages` if not)", ok == true or ok == 0)
end

-- ── credentials ─────────────────────────────────────────────────────────────
print("no credential in what ships")
for _, path in ipairs(modules) do
  local src = read(path)
  check(path .. " holds no development passcode", src:find("install-123", 1, true) == nil)
  check(path .. " holds no tile token", src:find("devtile0123456789abcdef", 1, true) == nil)
end
do
  local src = read("drivers/smartbuildos-venueflow/driver.lua")
  check(
    "driver.lua holds no passcode, token or key literal",
    src:find("install-123", 1, true) == nil
      and src:find('passcode%s*=%s*"') == nil
      and src:find('token%s*=%s*"%w') == nil
  )
  local xml = read("drivers/smartbuildos-venueflow/driver.xml")
  local block = xml:match("<property><name>Installer Passcode</name>.-</property>")
  check(
    "Installer Passcode is a hidden STRING property",
    block ~= nil
      and block:find("<type>STRING</type>", 1, true) ~= nil
      and block:find("<password>true</password>", 1, true) ~= nil
  )
  check(
    "...with an empty default (no factory passcode)",
    block ~= nil and block:find("<default></default>", 1, true) ~= nil
  )
  check("no property uses the PASSWORD type Composer refuses", xml:find("<type>PASSWORD</type>", 1, true) == nil)
  check("the version is empty in source (the build stamps it)", xml:find("<version></version>", 1, true) ~= nil)
  check(
    "the default control mode is Simulation",
    xml:match("<name>Control Mode</name>.-<default>(.-)</default>") == "Simulation"
  )
end
check(
  "the only PIN in the source tree is the documented sample one",
  (function()
    local src = read("src/venueflow/templates.lua")
    return select(2, src:gsub('"2580"', "")) == 2 and src:find("pinned%(") ~= nil
  end)()
)

-- ── the package, when it has been built ─────────────────────────────────────
print("package")
local c4z = "dist/oss/smartbuildos-venueflow.c4z"
if read(c4z) == nil then
  skipped = skipped + 1
  print("  skip the .c4z is not built (run `make venueflow`); package checks not run")
else
  local okZip = os.execute("unzip -tq " .. c4z .. " >/dev/null 2>&1")
  check("the archive passes its integrity test", okZip == true or okZip == 0)
  local names, set = list("unzip -Z1 " .. c4z), {}
  for _, n in ipairs(names) do
    set[n] = true
  end
  for _, wanted in ipairs({
    "driver.xml",
    "driver.lua",
    "www/app/index.html",
    "www/studio/index.html",
    "www/documentation/index.html",
    "www/icons/device_sm.png",
    "www/icons/device_lg.png",
    "www/icons/device/experience_70.png",
    "www/icons/device/experience_90.png",
    "www/icons/device/experience_300.png",
    "www/icons/device/experience_512.png",
    "www/icons/device/experience_1024.png",
  }) do
    check("holds " .. wanted, set[wanted] == true)
  end
  local stray = {}
  for _, n in ipairs(names) do
    if
      n:find("%.%.")
      or n:sub(1, 1) == "/"
      or n:find("%.DS_Store")
      or n:find("%.c4zproj$")
      or n:find("squishy")
      or (n:find("%.md$") and n ~= "www/documentation/index.md")
    then
      stray[#stray + 1] = n
    end
  end
  -- (The manual's source, www/documentation/index.md, ships with every driver of this repository.)
  check("no absolute path, parent path or stray file", #stray == 0, table.concat(stray, " "))
  local dir = os.tmpname()
  os.remove(dir)
  os.execute(
    "mkdir -p "
      .. dir
      .. " && unzip -qo "
      .. c4z
      .. " driver.lua driver.xml www/app/index.html www/studio/index.html -d "
      .. dir
  )
  local lua, xml = read(dir .. "/driver.lua"), read(dir .. "/driver.xml")
  for _, path in ipairs(modules) do
    local module = "venueflow." .. path:match("([%w_]+)%.lua$")
    check("the squished driver holds " .. module, lua ~= nil and lua:find(module, 1, true) ~= nil)
  end
  for _, module in ipairs({ "sbos.license", "lib.relayhost", "lib.persist", "JSON" }) do
    check("the squished driver holds " .. module, lua ~= nil and lua:find(module, 1, true) ~= nil)
  end
  check(
    "the packaged version is stamped",
    xml ~= nil and xml:match("<version>%d%d%d%d%d%d%d%d%.%d%d%d%d%d%d</version>") ~= nil
  )
  check("the packaged operator page is the built one", read(dir .. "/www/app/index.html") == pages.app)
  check("the packaged Studio page is the built one", read(dir .. "/www/studio/index.html") == pages.studio)
  check(
    "the packaged driver embeds the same operator page",
    lua ~= nil and pages.app ~= nil and lua:find(pages.app:sub(1, 200), 1, true) ~= nil
  )
  os.execute("rm -rf " .. dir)
end

print(
  string.format("\n%d passed, %d failed%s", pass, fail, skipped > 0 and (", " .. skipped .. " group skipped") or "")
)
if fail > 0 then
  os.exit(1)
end
