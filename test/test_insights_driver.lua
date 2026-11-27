-- Home Insights DRIVER under the shim: Composer's Actions tab reaching the
-- handler, the URL check, the moments the URL is sent to the screens, and the
-- retired "Get URL From Connector" action staying retired.
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

C4 = C4 or {}
require("c4_shim")

local GOOD_URL = "https://pages.example/home/panel"

local proxied, sent, timers = {}, {}, {}

Properties = { URL = "", Status = "" }
function C4:UpdateProperty(name, value)
  Properties[name] = value
end
function C4:SendToProxy(binding, command, params)
  proxied[#proxied + 1] = { binding = binding, command = command, params = params }
end
function C4:SendToDevice(id, command, params)
  sent[#sent + 1] = { id = id, command = command, params = params }
end
function C4:SetTimer(ms, callback)
  timers[#timers + 1] = { ms = ms, callback = callback }
end
function C4:DebugLog() end

local function reset()
  proxied, sent, timers = {}, {}, {}
end

dofile("drivers/smartbuildos-insights/driver.lua")
OnDriverInit()

print("\n[1] The Actions tab reaches the handler")
Properties.URL = GOOD_URL
reset()
ExecuteCommand("LUA_ACTION", { ACTION = "RELOAD" })
check(
  "Reload Now, as Composer sends it, publishes the URL",
  #proxied == 1
    and proxied[1].binding == 5001
    and proxied[1].command == "URL_CHANGED"
    and proxied[1].params.url == GOOD_URL,
  #proxied
)
check("and says so", Properties.Status:find("URL published (manual)", 1, true) == 1, Properties.Status)
reset()
ExecuteCommand("RELOAD", {})
check("a command under its own name still works", #proxied == 1, #proxied)
reset()
check(
  "an unknown action is ignored",
  pcall(ExecuteCommand, "LUA_ACTION", { ACTION = "NO_SUCH_ACTION" }) and #proxied == 0
)
check("LUA_ACTION with no parameters is ignored", pcall(ExecuteCommand, "LUA_ACTION", nil) and #proxied == 0)
check("LUA_ACTION with no ACTION is ignored", pcall(ExecuteCommand, "LUA_ACTION", {}) and #proxied == 0)

print("\n[2] Get URL From Connector is retired")
local xml = assert(io.open("drivers/smartbuildos-insights/driver.xml")):read("*a")
check("the action is not offered in Composer", xml:find("PULL_URL", 1, true) == nil)
check("Reload Now is still offered", xml:find("<command>RELOAD</command>", 1, true) ~= nil)
local before = Properties.Status
reset()
ExecuteCommand("LUA_ACTION", { ACTION = "PULL_URL" })
check("a project that still sends it asks no other driver for anything", #sent == 0, #sent)
check("and changes nothing", #proxied == 0 and #timers == 0 and Properties.Status == before, Properties.Status)
reset()
check(
  "an address sent by another driver is not taken",
  pcall(ExecuteCommand, "DISPLAY_URL", { url = "https://elsewhere.example/page" })
    and Properties.URL == GOOD_URL
    and #proxied == 0,
  Properties.URL
)
check("there is no handler for a message from another driver", ReceivedFromDevice == nil)

print("\n[3] The URL is checked before it is sent")
Properties.URL = ""
reset()
OnPropertyChanged("URL")
check("an empty URL is not sent", #proxied == 0 and Properties.Status == "No URL set", Properties.Status)
Properties.URL = "http://pages.example/home/panel"
OnPropertyChanged("URL")
check(
  "an address that is not https is not sent",
  #proxied == 0 and Properties.Status:find("does not look right", 1, true) ~= nil,
  Properties.Status
)
Properties.URL = "https://pages.example"
OnPropertyChanged("URL")
check(
  "an address with no path is not sent",
  #proxied == 0 and Properties.Status:find("does not look right", 1, true) ~= nil,
  Properties.Status
)
Properties.URL = "  " .. GOOD_URL .. "  "
OnPropertyChanged("URL")
check("a pasted URL is sent, trimmed", #proxied == 1 and proxied[1].params.url == GOOD_URL, #proxied)
check(
  "and the Status names the edit",
  Properties.Status:find("URL published (edited)", 1, true) == 1,
  Properties.Status
)

print("\n[4] The URL is sent again after a load")
Properties.URL = GOOD_URL
reset()
OnDriverLateInit()
check("once when the driver loads", #proxied == 1, #proxied)
check("the Status names the load", Properties.Status:find("URL published (load)", 1, true) == 1, Properties.Status)
check("a second send is set for 60 seconds later", #timers == 1 and timers[1].ms == 60000, #timers)
timers[1].callback()
check("and it goes out", #proxied == 2 and proxied[2].params.url == GOOD_URL, #proxied)
check("the Status names it", Properties.Status:find("URL published (startup)", 1, true) == 1, Properties.Status)

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
