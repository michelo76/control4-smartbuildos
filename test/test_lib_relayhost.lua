--- lib.relayhost: which address the controller answers on.
---
--- Bench, 10 Nov 2026. The project has the controller and another Control4
--- device with an address of its own. "First control4_* device with a
--- network binding" returned the other device, and the Home Guide, Dealer
--- Settings and Variable Inspector tiles were all published at an address
--- where nothing listened. An address off a device binding is now a
--- candidate, published only after this relay has answered /ping on it.
local RelayHost = require("lib.relayhost")

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

local CONTROLLER, REMOTE = "192.168.7.20", "192.168.7.31"

--- A scripted site. `answers[host]` is what GET /ping gives there.
local function site(opts)
  local s = {
    configured = opts.configured or "",
    api = opts.api,
    devices = opts.devices or {},
    bindings = opts.bindings or {},
    answers = opts.answers or {},
    asked = {},
    changes = {},
    clock = 1000,
    pending = {},
    async = opts.async == true,
  }
  s.resolver = RelayHost.new({
    port = 47821,
    service = "home-guide",
    configured = function()
      return s.configured
    end,
    controllerAddress = function()
      return s.api
    end,
    devices = function()
      return s.devices
    end,
    bindings = function(id)
      return s.bindings[id] or {}
    end,
    now = function()
      return s.clock
    end,
    onChange = function(host)
      s.changes[#s.changes + 1] = host
    end,
    get = function(url, done)
      s.asked[#s.asked + 1] = url
      local host = url:match("^http://([%d%.]+):47821/ping$")
      local answer = s.answers[host]
      local function reply()
        if answer == "throw" then
          return
        end
        done(answer ~= nil, answer)
      end
      if answer == "throw" then
        error("transport broke")
      end
      if s.async then
        s.pending[#s.pending + 1] = reply
      else
        reply()
      end
    end,
  })
  function s.flush()
    while #s.pending > 0 do
      table.remove(s.pending, 1)()
    end
  end
  return s
end

local HOME_GUIDE = '{"ok":true,"service":"home-guide"}'
local TWO_DEVICES = {
  [40] = { deviceName = "Living Remote", driverFileName = "control4_remote_halo.c4z" },
  [60] = { deviceName = "CORE 1", driverFileName = "control4_core1.c4i" },
  [70] = { deviceName = "Lamp", driverFileName = "light_v2.c4i" },
}
local TWO_BINDINGS = {
  [40] = { { networkbindings = { { addr = REMOTE } } } },
  [60] = { { bindings = { { bindingid = 6001, info = { addr = CONTROLLER } } } }, { addr = "127.0.0.1" } },
  [70] = { { addr = "192.168.7.99" } },
}

print("== isRoutable")
check("a LAN address", RelayHost.isRoutable("192.168.7.20"))
check("trimmed", RelayHost.isRoutable(" 10.0.0.5 "))
check("not loopback", not RelayHost.isRoutable("127.0.0.1"))
check("not link-local", not RelayHost.isRoutable("169.254.10.2"))
check("not unspecified", not RelayHost.isRoutable("0.0.0.0"))
check(
  "not broadcast or multicast",
  not RelayHost.isRoutable("255.255.255.255") and not RelayHost.isRoutable("224.0.0.1")
)
check("not out of range", not RelayHost.isRoutable("300.1.1.1"))
check(
  "not a name, nil or a number",
  not RelayHost.isRoutable("core.local") and not RelayHost.isRoutable(nil) and not RelayHost.isRoutable(7)
)

print("== addresses")
local loop = { addr = "10.0.0.2" }
loop.self = loop
local found =
  RelayHost.addresses({ a = { b = { addr = "10.0.0.9" } }, list = { { addr = "127.0.0.1" }, loop }, addr = "10.0.0.1" })
check(
  "every routable addr, sorted, cycle-safe",
  table.concat(found, ",") == "10.0.0.1,10.0.0.2,10.0.0.9",
  table.concat(found, ",")
)
check("nothing in nothing", #RelayHost.addresses(nil) == 0 and #RelayHost.addresses({}) == 0)

print("== the bench: another Control4 device has the lower id")
local s = site({ devices = TWO_DEVICES, bindings = TWO_BINDINGS, answers = { [CONTROLLER] = HOME_GUIDE } })
local host, state = s.resolver:host()
check("nothing is published before an address has answered", host == "" and state == "unknown", host)
check(
  "candidates: control4_ devices only, lowest id first",
  table.concat(s.resolver:candidates(), ",") == REMOTE .. "," .. CONTROLLER
)
s.resolver:check()
host, state = s.resolver:host()
check("the address the relay answered on wins", host == CONTROLLER and state == "confirmed", host)
check("the other device was asked first and passed over", s.asked[1]:find(REMOTE, 1, true) ~= nil and #s.asked == 2)
check("the change was announced once, with the new host", #s.changes == 1 and s.changes[1] == CONTROLLER)
check(
  "status line names it plainly",
  s.resolver:statusLine() == "Listening :47821 - serving http://192.168.7.20:47821 to the app"
)

print("== a relay of ANOTHER driver answering does not count")
s = site({
  devices = TWO_DEVICES,
  bindings = TWO_BINDINGS,
  answers = { [REMOTE] = '{"ok":true,"service":"dealer-panel"}', [CONTROLLER] = HOME_GUIDE },
})
s.resolver:check()
check("only this service's answer is taken", (s.resolver:host()) == CONTROLLER)
s = site({
  devices = TWO_DEVICES,
  bindings = TWO_BINDINGS,
  answers = { [CONTROLLER] = { ok = true, service = "home-guide" } },
})
s.resolver:check()
check("a decoded body is read too", (s.resolver:host()) == CONTROLLER)

print("== the controller API")
s = site({ api = CONTROLLER, devices = TWO_DEVICES, bindings = TWO_BINDINGS, answers = { [CONTROLLER] = HOME_GUIDE } })
host, state = s.resolver:host()
check("its address is published at once, marked unconfirmed", host == CONTROLLER and state == "unconfirmed")
check("and says it is checking", s.resolver:statusLine():find("(checking)", 1, true) ~= nil)
s.resolver:check()
host, state = s.resolver:host()
check("then confirmed, asked first, nobody else asked", state == "confirmed" and #s.asked == 1)
check("no change announced when the host did not move", #s.changes == 0)
s = site({ api = "127.0.0.1", devices = TWO_DEVICES, bindings = TWO_BINDINGS, answers = { [CONTROLLER] = HOME_GUIDE } })
check("a loopback answer from the API is not an address", (s.resolver:host()) == "")
s = site({
  api = "192.168.7.50",
  devices = TWO_DEVICES,
  bindings = TWO_BINDINGS,
  answers = { [CONTROLLER] = HOME_GUIDE },
})
s.resolver:check()
check(
  "a wrong API address is replaced by the one that answered",
  (s.resolver:host()) == CONTROLLER and s.changes[1] == CONTROLLER
)

print("== nothing answers")
s = site({ devices = TWO_DEVICES, bindings = TWO_BINDINGS })
s.resolver:check()
host, state = s.resolver:host()
check("no address beats a wrong one", host == "" and state == "unknown" and s.resolver:unanswered())
check(
  "the status asks for the property",
  s.resolver:statusLine():find("UNKNOWN, set App Relay Address", 1, true) ~= nil
)
s = site({ api = CONTROLLER, devices = TWO_DEVICES, bindings = TWO_BINDINGS })
s.resolver:check()
host, state = s.resolver:host()
check(
  "the API address stays published, and the status says it did not answer",
  host == CONTROLLER and state == "unconfirmed"
)
check("…in words", s.resolver:statusLine():find("no answer on it", 1, true) ~= nil, s.resolver:statusLine())
s = site({})
s.resolver:check()
check("no candidates at all: unknown, no request made", (s.resolver:host()) == "" and #s.asked == 0)

print("== the dealer's override")
s = site({
  configured = " 10.0.0.5 ",
  devices = TWO_DEVICES,
  bindings = TWO_BINDINGS,
  answers = { [CONTROLLER] = HOME_GUIDE },
})
s.resolver:check()
host, state = s.resolver:host()
check("used as written, and nothing is asked", host == "10.0.0.5" and state == "override" and #s.asked == 0)
s.configured = "Auto"
s.resolver:check()
check("Auto goes back to finding it", (s.resolver:host()) == CONTROLLER)
s.configured = "10.0.0.5"
s.resolver:check()
s.configured = ""
check("an address confirmed before an override is not kept after it", (s.resolver:host()) == "")

print("== one pass at a time; late and repeated answers")
s = site({ devices = TWO_DEVICES, bindings = TWO_BINDINGS, answers = { [CONTROLLER] = HOME_GUIDE }, async = true })
s.resolver:check()
s.resolver:check()
check("a second check while one runs asks nothing more", #s.asked == 1)
s.flush()
check("the pass finishes when the answers come", (s.resolver:host()) == CONTROLLER and #s.asked == 2)
s =
  site({ devices = TWO_DEVICES, bindings = TWO_BINDINGS, answers = { [REMOTE] = "throw", [CONTROLLER] = HOME_GUIDE } })
check(
  "a transport that throws is a miss, not a crash",
  pcall(s.resolver.check, s.resolver) and (s.resolver:host()) == CONTROLLER
)

print("== when to ask again")
s = site({ devices = TWO_DEVICES, bindings = TWO_BINDINGS, answers = { [CONTROLLER] = HOME_GUIDE } })
s.resolver:checkIfDue()
check("the first call checks", #s.asked == 2)
s.clock = s.clock + 60
s.resolver:checkIfDue()
check("a confirmed address is left alone for a while", #s.asked == 2)
s.clock = s.clock + RelayHost.RECHECK_SECONDS
s.answers = { [REMOTE] = nil, ["192.168.7.21"] = HOME_GUIDE }
s.bindings[60] = { { addr = "192.168.7.21" } }
s.resolver:checkIfDue()
check(
  "then asked again: a changed address is followed",
  (s.resolver:host()) == "192.168.7.21" and s.changes[#s.changes] == "192.168.7.21"
)
s = site({ devices = TWO_DEVICES, bindings = TWO_BINDINGS })
local waits, last = {}, nil
for _ = 1, 3000 do
  local before = #s.asked
  s.resolver:checkIfDue()
  if #s.asked > before then
    if last ~= nil then
      waits[#waits + 1] = s.clock - last
    end
    last = s.clock
  end
  s.clock = s.clock + 60
  if #waits >= 6 then
    break
  end
end
check(
  "unanswered: asked again after 1, 2, 4, 8 minutes, then every 15",
  table.concat(waits, ",") == "60,120,240,480,900,900",
  table.concat(waits, ",")
)

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
