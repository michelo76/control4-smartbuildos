-- lib.appfile: tries each place a packaged file may be, reports what it tried.
local appfile = require("lib.appfile")

local pass, fail = 0, 0
local function check(name, ok, detail)
  if ok then
    pass = pass + 1
    print("  ok   " .. name)
  else
    fail = fail + 1
    print("  FAIL " .. name .. (detail and ("  -> " .. tostring(detail)) or ""))
  end
end

--- A fake C4 whose files exist only under (dir, path) pairs it is given.
local function fakeC4(files)
  local c4 = { dir = nil, closed = 0 }
  function c4:FileSetDir(d)
    self.dir = d
  end
  local function key(self, path)
    return (self.dir or "") .. "|" .. path
  end
  function c4:FileExists(path)
    return files[key(self, path)] ~= nil
  end
  function c4:FileOpen(path)
    return { text = files[key(self, path)] }
  end
  function c4:FileGetSize(f)
    return #f.text
  end
  function c4:FileSetPos() end
  function c4:FileRead(f, n)
    return f.text:sub(1, n)
  end
  function c4:FileClose()
    self.closed = self.closed + 1
  end
  return c4
end

local html = string.rep("<p>page</p>", 100)

local c4 = fakeC4({ ["C4Z_ROOT|www/app/index.html"] = html })
local got, report = appfile.read("drv", "app/index.html", c4, 100)
check("finds the usual location", got == html)
check(
  "report names what worked",
  report:find("used", 1, true) ~= nil and report:find("C4Z_ROOT,drv + www/app/index.html", 1, true) ~= nil
)
check("file handle closed", c4.closed == 1)

c4 = fakeC4({ ["C4Z_ROOT|driver/drv/www/app/index.html"] = html })
got, report = appfile.read("drv", "app/index.html", c4, 100)
check("falls through to a later location", got == html, report)
check("report lists the misses first", report:find("not found", 1, true) ~= nil)

c4 = fakeC4({})
got, report = appfile.read("drv", "app/index.html", c4, 100)
check("nothing found gives nil and a report", got == nil and report:find("not found", 1, true) ~= nil)

c4 = fakeC4({ ["C4Z_ROOT|www/app/index.html"] = "tiny" })
got = appfile.read("drv", "app/index.html", c4, 100)
check("a too-small file is not accepted", got == nil)

local broken = fakeC4({})
function broken:FileExists()
  error("boom")
end
got, report = appfile.read("drv", "app/index.html", broken, 100)
check("a C4 error is survived and reported", got == nil and report:find("error", 1, true) ~= nil)

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
