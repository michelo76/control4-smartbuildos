-- Send Push Notification on the SmartBuildOS Agent.
--
-- Part 1 is the pure gate (src/sbos/agentpush.lua): bounds, dedupe, the
-- hourly limit, reading the platform's answer. Part 2 loads the Agent under
-- the shim with a scripted platform and runs the command the way Composer
-- programming does: variables filled in, what is posted and where, a refusal
-- firing Notification Failed, and the quiet refusals that must NOT fire it.
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
JSON = require("JSON")

-- ── timers ──────────────────────────────────────────────────────────────────
local clock = { now = 0, timers = {} }
package.preload["drivers-common-public.global.timer"] = function()
  ONE_SECOND = 1000
  ONE_MINUTE = 60000
  ONE_HOUR = 3600000
  function SetTimer(id, ms, cb, repeating)
    clock.timers[id] = { at = clock.now + ms, cb = cb, every = repeating and ms or nil }
  end
  function CancelTimer(id)
    clock.timers[id] = nil
  end
  function KillAllTimers()
    clock.timers = {}
  end
  return true
end
local function advance(ms)
  local target = clock.now + ms
  while true do
    local bestId, bestAt
    for id, t in pairs(clock.timers) do
      if t.at <= target and (bestAt == nil or t.at < bestAt or (t.at == bestAt and id < bestId)) then
        bestId, bestAt = id, t.at
      end
    end
    if not bestId then
      break
    end
    clock.now = bestAt
    local t = clock.timers[bestId]
    if t.every then
      t.at = clock.now + t.every
    else
      clock.timers[bestId] = nil
    end
    t.cb()
  end
  clock.now = target
end
local realTime = os.time
local base = 1800000000
os.time = function(t)
  if t then
    return realTime(t)
  end
  return base + math.floor(clock.now / 1000)
end
local realDate = os.date
os.date = function(fmt, t)
  return realDate(fmt, t or os.time())
end
package.preload["drivers-common-public.global.url"] = function()
  return true
end
package.preload["cloud-client-byte"] = function()
  return true
end
package.preload["drivers-common-public.module.websocket"] = function()
  local WS = {}
  WS.__index = WS
  function WS:new()
    return nil
  end
  return WS
end
package.preload["drivers-common-public.module.ssdp"] = function()
  return {
    new = function()
      return { StartDiscovery = function() end, StopDiscovery = function() end }
    end,
  }
end
package.preload["lib.github-updater"] = function()
  return { checkForUpdates = function() end, updateAll = function() end }
end
package.preload["lib.sbos-updater"] = function()
  return { checkForUpdates = function() end, updateAll = function() end }
end

-- ── persist ─────────────────────────────────────────────────────────────────
local store = {}
package.preload["lib.persist"] = function()
  local EMPTY = {}
  return {
    get = function(_, key, default)
      if default == nil then
        default = EMPTY
      end
      local value = store[key]
      if value == nil then
        return default
      end
      return value
    end,
    set = function(_, key, value)
      store[key] = value
    end,
    delete = function(_, key)
      store[key] = nil
    end,
  }
end

-- ── fake platform behind lib.http ───────────────────────────────────────────
local requests = {}
--- url suffix -> function(data) -> { ok, code, body } ; default accepts.
local responders = {}
local function settled(isOk, value)
  return {
    next = function(_, onOk, onErr)
      if isOk then
        if onOk then
          onOk(value)
        end
      elseif onErr then
        onErr(value)
      end
    end,
  }
end
package.preload["lib.http"] = function()
  return {
    get = function(_, url)
      return settled(true, { url = url, code = 200, headers = {}, body = "" })
    end,
    post = function(_, url, data, headers, options)
      requests[#requests + 1] = { url = url, data = data, headers = headers }
      local path = url:match("/api/integrations/control4/(.*)$") or url:match("/api/driver%-cloud/(.*)$") or url
      local r = responders[path]
      local answer = r and r(data) or { ok = true, code = 200, body = { ok = true } }
      if answer.ok then
        return settled(
          true,
          { url = url, code = answer.code or 200, headers = {}, body = JSON:encode(answer.body or {}) }
        )
      end
      return settled(false, {
        url = url,
        code = answer.code or 0,
        headers = {},
        body = answer.body or "",
        error = answer.error or "unreachable",
      })
    end,
  }
end

-- ── Director ────────────────────────────────────────────────────────────────
local sent = {}
local fired = {}
local AGENT_ID = 99
local PROJECT = {
  [63] = { deviceName = "Home Controller EA5", roomName = "Rack", driverFileName = "control4_ea5.c4z" },
  [12] = { deviceName = "Kitchen Pendants", roomName = "Kitchen", roomId = 3, driverFileName = "light_v2.c4i" },
  [40] = { deviceName = "Front Door Lock", roomName = "Entry", driverFileName = "lock.c4z" },
  [AGENT_ID] = { deviceName = "SmartBuildOS Agent", roomName = "Rack", driverFileName = "smartbuildos.c4z" },
}
--- The Agent's own variables, as Director hands them to a VARIABLE picker.
local agentVariables = {
  [2000] = { name = "DIRECTOR_RELOADS", value = "41" },
  [2012] = { name = "DIRECTOR_RELOADS_TODAY", value = "3" },
}
setmetatable(C4, {
  __index = function(_, key)
    -- Anything the driver probes that this test does not model answers nil
    -- (the driver pcalls every such read).
    return function()
      return nil
    end
  end,
})
function C4:GetDevices()
  return PROJECT
end
function C4:GetDeviceVariables(id)
  if tonumber(id) == AGENT_ID then
    return agentVariables
  end
  if tonumber(id) == 40 then
    return { [1500] = { name = "USERCODE", value = "4321" }, [1501] = { name = "LOCK_STATUS", value = "locked" } }
  end
  if tonumber(id) == 12 then
    return {
      [1001] = { name = "LIGHT_LEVEL", value = "40", readonly = "False" },
      [1002] = { name = "LIGHT_STATE", value = "True", readonly = "True" },
    }
  end
  return {}
end
function C4:GetBindingsByDevice()
  return { bindings = {} }
end
function C4:GetNetworkBindingsByDevice()
  return nil
end
function C4:GetProjectItems()
  return ""
end
function C4:GetProjectHierarchy()
  return {}
end
function C4:GetAllCodeItems()
  return {}
end
function C4:GetSystemType()
  return "XDT_EA5"
end
function C4:GetVersionInfo()
  return { version = "4.2.0.0" }
end
function C4:GetDriverConfigInfo(key)
  if key == "minimum_os_version" then
    return "3.3.1"
  end
  return "20261022.100000"
end
function C4:GetDeviceID()
  return AGENT_ID
end
function C4:GetDeviceData(_, key)
  if key == "name" then
    return "SmartBuildOS Agent"
  end
  return nil
end
function C4:GetTickCount()
  return clock.now
end
function C4:GetBootID()
  return "boot-7"
end
function C4:SendToDevice(device, command, params)
  sent[#sent + 1] = { device = device, command = command, params = params }
end
function C4:FireEvent(name)
  fired[#fired + 1] = name
end
function C4:UpdateProperty(name, value)
  Properties[name] = value
end
function C4:AllowExecute() end
function C4:HMAC()
  return "00"
end

Properties = {}
do
  local f = assert(io.open("drivers/smartbuildos/driver.xml"))
  local xml = f:read("*a")
  f:close()
  for block in xml:gmatch("<property>(.-)</property>") do
    local name = block:match("<name>(.-)</name>")
    Properties[name] = block:match("<default>(.-)</default>") or ""
  end
end
Properties["API URL"] = "https://app.smartbuildos.io"
Properties["Heartbeat Interval"] = "1m"
Properties["Log Level"] = "1 - Error"

-- Paired already: the token is the credential; the server derives everything.
store["device_token"] = "sbc4_0123abcd_secret"
store["system_id"] = "7e14128e-fb05-4645-929f-e1ee9e1ee964"

package.path = "./drivers/smartbuildos/?.lua;" .. package.path
dofile("drivers/smartbuildos/driver.lua")

--- Moves the clock without running the timers in between: an hour of the
--- Agent's own schedule (update checks, full syncs) is not what is under test.
local function skip(ms)
  clock.now = clock.now + ms
end
local function pushes()
  local out = {}
  for _, r in ipairs(requests) do
    if r.url:find("/api/integrations/control4/push$") then
      out[#out + 1] = r
    end
  end
  return out
end
local function firedCount(name)
  local n = 0
  for _, f in ipairs(fired) do
    if f == name then
      n = n + 1
    end
  end
  return n
end
local function accept(count)
  responders["push"] = function()
    return {
      ok = true,
      code = 201,
      body = { ok = true, push = { state = "accepted", approved_recipient_count = count } },
    }
  end
end
local function refuse(reason)
  responders["push"] = function()
    return { ok = true, code = 202, body = { ok = true, push = { state = "failed", reason = reason } } }
  end
end

-- ─── Part 1: the gate, on its own ───────────────────────────────────────────

local AgentPushModule = require("sbos.agentpush")

print("[1] a message is bounded and needs a title or a text")
do
  local msg = AgentPushModule.message({ title = "  Rack  ", body = " door open\n\tsecond line ", severity = "Warning" })
  check("trimmed title", msg.title == "Rack", msg.title)
  check("a new line in the message survives, a tab does not", msg.body == "door open\n second line", msg.body)
  check("severity from the list label", msg.severity == "warning", msg.severity)
  check("an unknown severity is info", AgentPushModule.message({ title = "x", severity = "Loud" }).severity == "info")
  local none, why = AgentPushModule.message({ title = "  ", body = "" })
  check("neither title nor message is refused", none == nil and why:find("TITLE or a MESSAGE") ~= nil, why)
  local long = AgentPushModule.message({ title = string.rep("t", 400), body = string.rep("b", 2000) })
  check("title cut to 120 bytes", #long.title == 120, #long.title)
  check("message cut to 500 bytes", #long.body == 500, #long.body)
  -- 300 two-byte characters: a byte cut at 500 is on a boundary, at 499 not.
  local accents = AgentPushModule.bound("a" .. string.rep("\195\169", 300), 500)
  check("a cut never splits a character", #accents == 499 and accents:sub(-2) == "\195\169", #accents)
end

print("[2] dedupe and the hourly limit")
do
  local now = 1000
  local gate = AgentPushModule.new({
    now = function()
      return now
    end,
  })
  local a = AgentPushModule.message({ title = "Rack", body = "door open", severity = "warning" })
  check("first is admitted", gate:admit(a) == true)
  local again, why = gate:admit(a)
  check("the same message inside the window is a duplicate", again == false and why == "duplicate", why)
  check(
    "another severity is another message",
    gate:admit(AgentPushModule.message({ title = "Rack", body = "door open", severity = "critical" })) == true
  )
  check(
    "another value is another message",
    gate:admit(AgentPushModule.message({ title = "Rack", body = "door closed", severity = "warning" })) == true
  )
  check("a fresh send skips the dedupe check", gate:admit(a, { fresh = true }) == true)
  now = now + AgentPushModule.LIMITS.dedupe_seconds
  check("the same message after the window is admitted", gate:admit(a) == true)
  check(
    "a duplicate does not use a rate slot",
    gate:remaining() == AgentPushModule.LIMITS.per_hour - 5,
    gate:remaining()
  )

  local busy = AgentPushModule.new({
    now = function()
      return now
    end,
  })
  for i = 1, AgentPushModule.LIMITS.per_hour do
    busy:admit(AgentPushModule.message({ body = "message " .. i }))
  end
  local over, reason = busy:admit(AgentPushModule.message({ body = "one too many" }))
  check("over the hourly limit is rate_limited", over == false and reason == "rate_limited", reason)
  check(
    "a fresh send is rate limited too",
    busy:admit(AgentPushModule.message({ body = "test" }), { fresh = true }) == false
  )
  now = now + 3600
  check("an hour later it is admitted again", busy:admit(AgentPushModule.message({ body = "one too many" })) == true)
  check("counters", busy.counters.rate_limited == 2 and busy.counters.attempted == AgentPushModule.LIMITS.per_hour + 1)
end

print("[3] reading the platform's answer")
do
  local ok, count =
    AgentPushModule.readAnswer({ ok = true, push = { state = "accepted", approved_recipient_count = 2 } })
  check("accepted with a recipient count", ok == true and count == 2, count)
  local no, reason =
    AgentPushModule.readAnswer({ ok = true, push = { state = "failed", reason = "no-approved-recipient-profile" } })
  check("failed with its reason", no == false and reason == "no-approved-recipient-profile", reason)
  local old, why = AgentPushModule.readAnswer({ ok = true })
  check("an answer with no push table is not accepted", old == false and why:find("did not answer") ~= nil, why)
  check(
    "a known reason is explained in words",
    AgentPushModule.explain("no-approved-recipient-profile"):find("System Studio") ~= nil
  )
  check("an unknown reason is passed through", AgentPushModule.explain("HTTP 404: Not Found") == "HTTP 404: Not Found")
end

-- ─── Part 2: the command, in the Agent ──────────────────────────────────────

print("[4] the Agent comes up paired")
OnDriverInit()
OnDriverLateInit("DIT_STARTUP")
check("online", Properties["Driver Status"] == "Online", Properties["Driver Status"])
check("the command is declared", EC.SEND_PUSH_NOTIFICATION ~= nil and EC.SEND_TEST_PUSH ~= nil)

print("[5] a programmed push: variables filled in, posted on the Agent's own path")
accept(2)
fired = {}
ExecuteCommand("SEND_PUSH_NOTIFICATION", {
  TITLE = "Controller",
  MESSAGE = "Controller restarted ${1} times today",
  SEVERITY = "Warning",
  ["VARIABLE 1"] = AGENT_ID .. ",2012",
  ["VARIABLE 2"] = "",
})
do
  local list = pushes()
  local r = list[1]
  check("one request to /api/integrations/control4/push", #list == 1, #list)
  check(
    "the picked variable is filled in",
    r ~= nil and r.data.body == "Controller restarted 3 times today",
    r and r.data.body
  )
  check("title and severity", r ~= nil and r.data.title == "Controller" and r.data.severity == "warning")
  check("says it came from programming", r ~= nil and r.data.kind == "push" and r.data.source == "programming")
  check(
    "a stable bounded event id",
    r ~= nil and tostring(r.data.source_event_id):match("^agent%-push:99:%d+:%d+$") ~= nil,
    r and r.data.source_event_id
  )
  check(
    "observed_at is ISO-8601 UTC",
    r ~= nil and tostring(r.data.observed_at):match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$") ~= nil
  )
  check(
    "authenticated with the controller token",
    r ~= nil and r.headers["Authorization"] == "Bearer sbc4_0123abcd_secret"
  )
  check(
    "no recipient or address is ever sent",
    r ~= nil and r.data.recipient == nil and r.data.email == nil and r.data.to == nil
  )
  check("accepted: Notification Failed is not fired", firedCount("Notification Failed") == 0)
  check(
    "the property says who it reached",
    tostring(Properties["Last Push Notification"]):find("accepted for 2 recipient%(s%): Controller") ~= nil,
    Properties["Last Push Notification"]
  )
end

print("[6] variables: picked but not written, written by name, unreadable, credential")
do
  requests = {}
  ExecuteCommand("SEND_PUSH_NOTIFICATION", {
    MESSAGE = "Restarts today:",
    SEVERITY = "Info",
    ["VARIABLE 1"] = AGENT_ID .. ",2012",
  })
  local r = pushes()[1]
  check(
    "a picked variable nobody wrote goes after the message",
    r ~= nil and r.data.body == "Restarts today: 3",
    r and r.data.body
  )
  check("no TITLE is sent as an empty title", r ~= nil and r.data.title == "")

  requests = {}
  ExecuteCommand("SEND_PUSH_NOTIFICATION", {
    TITLE = "Kitchen at ${Kitchen->Kitchen Pendants::LIGHT_LEVEL}%",
    MESSAGE = "Lifetime ${2}, missing ${3}, code ${4}",
    ["VARIABLE 2"] = AGENT_ID .. ",2000",
    ["VARIABLE 4"] = "40,1500",
  })
  r = pushes()[1]
  check("a variable written by name fills the title", r ~= nil and r.data.title == "Kitchen at 40%", r and r.data.title)
  check(
    "unpicked is ?, a credential is [hidden], the push still goes",
    r ~= nil and r.data.body == "Lifetime 41, missing ?, code [hidden]",
    r and r.data.body
  )
  check("no severity chosen is info", r ~= nil and r.data.severity == "info")
end

print("[7] the same message twice: sent once, quietly")
do
  requests = {}
  fired = {}
  local params = { TITLE = "Rack", MESSAGE = "Door open", SEVERITY = "Critical" }
  ExecuteCommand("SEND_PUSH_NOTIFICATION", params)
  ExecuteCommand("SEND_PUSH_NOTIFICATION", params)
  check("one request for two identical commands", #pushes() == 1, #pushes())
  check("a duplicate does not fire Notification Failed", firedCount("Notification Failed") == 0)
  check(
    "the property says it was not repeated",
    tostring(Properties["Last Push Notification"]):find("not repeated") ~= nil,
    Properties["Last Push Notification"]
  )
  agentVariables[2012].value = "4"
  requests = {}
  ExecuteCommand(
    "SEND_PUSH_NOTIFICATION",
    { MESSAGE = "Controller restarted ${1} times today", ["VARIABLE 1"] = "99,2012" }
  )
  check(
    "a new value is a new message",
    #pushes() == 1 and pushes()[1].data.body == "Controller restarted 4 times today"
  )
  advance(AgentPushModule.LIMITS.dedupe_seconds * 1000)
  requests = {}
  ExecuteCommand("SEND_PUSH_NOTIFICATION", params)
  check("after the window the same message goes again", #pushes() == 1, #pushes())
end

print("[8] SmartBuildOS refuses: Notification Failed fires, with the reason")
do
  refuse("no-approved-recipient-profile")
  requests = {}
  fired = {}
  ExecuteCommand("SEND_PUSH_NOTIFICATION", { TITLE = "UPS", MESSAGE = "On battery", SEVERITY = "Critical" })
  check("the push was attempted", #pushes() == 1)
  check("Notification Failed fired once", firedCount("Notification Failed") == 1, firedCount("Notification Failed"))
  check(
    "the property gives a reason a dealer can act on",
    tostring(Properties["Last Push Notification"]):find("no recipient profile is set for this system") ~= nil,
    Properties["Last Push Notification"]
  )
  check(
    "a refusal is not a lost connection",
    firedCount("Sync Failed") == 0 and Properties["Connection Status"] == "Connected"
  )
end

print("[9] SmartBuildOS cannot be reached, or does not know the route")
do
  responders["push"] = function()
    return { ok = false, code = 404, body = "Not Found" }
  end
  requests = {}
  fired = {}
  ExecuteCommand("SEND_PUSH_NOTIFICATION", { TITLE = "UPS", MESSAGE = "Back on mains" })
  check("Notification Failed fired", firedCount("Notification Failed") == 1, firedCount("Notification Failed"))
  check(
    "the property names the HTTP status",
    tostring(Properties["Last Push Notification"]):find("HTTP 404") ~= nil,
    Properties["Last Push Notification"]
  )
  responders["push"] = function()
    return { ok = true, code = 200, body = { ok = true } }
  end
  fired = {}
  ExecuteCommand("SEND_PUSH_NOTIFICATION", { TITLE = "UPS", MESSAGE = "Battery low" })
  check(
    "an answer with no push state is a failure",
    firedCount("Notification Failed") == 1,
    firedCount("Notification Failed")
  )
end

print("[10] empty, and the hourly limit: refused here, quietly")
do
  accept(1)
  requests = {}
  fired = {}
  ExecuteCommand("SEND_PUSH_NOTIFICATION", { TITLE = " ", MESSAGE = "" })
  check("nothing to send is not posted", #pushes() == 0)
  check("and does not fire Notification Failed", firedCount("Notification Failed") == 0)

  skip(3600 * 1000)
  requests = {}
  for i = 1, AgentPushModule.LIMITS.per_hour + 5 do
    ExecuteCommand("SEND_PUSH_NOTIFICATION", { MESSAGE = "Burst " .. i })
  end
  check(
    "a burst stops at the hourly limit",
    #pushes() == AgentPushModule.LIMITS.per_hour,
    #pushes() .. " of " .. AgentPushModule.LIMITS.per_hour
  )
  check("a rate-limited push does not fire Notification Failed", firedCount("Notification Failed") == 0)
  check(
    "the property says the limit was reached",
    tostring(Properties["Last Push Notification"]):find("hourly limit of 30 reached") ~= nil,
    Properties["Last Push Notification"]
  )
end

print("[11] Actions > Send Test Push")
do
  skip(3600 * 1000)
  accept(1)
  requests = {}
  ExecuteCommand("SEND_TEST_PUSH", {})
  ExecuteCommand("SEND_TEST_PUSH", {})
  local list = pushes()
  check("a second press sends again", #list == 2, #list)
  check(
    "marked as a test",
    list[1] ~= nil and list[1].data.source == "test" and list[1].data.title == "SmartBuildOS test push"
  )
  check("each press has its own event id", list[1].data.source_event_id ~= list[2].data.source_event_id)
end

print("[12] not paired: nothing leaves, Notification Failed fires")
do
  store["device_token"] = nil
  requests = {}
  fired = {}
  ExecuteCommand("SEND_PUSH_NOTIFICATION", { TITLE = "Rack", MESSAGE = "Fan failed" })
  check("no request", #pushes() == 0)
  check("Notification Failed fired", firedCount("Notification Failed") == 1, firedCount("Notification Failed"))
  check(
    "the property says why",
    tostring(Properties["Last Push Notification"]):find("not paired") ~= nil,
    Properties["Last Push Notification"]
  )
end

print("[13] driver.xml declares the command the way the code reads it")
do
  local f = assert(io.open("drivers/smartbuildos/driver.xml"))
  local xml = f:read("*a")
  f:close()
  local command = xml:match("<command>%s*<name>SEND_PUSH_NOTIFICATION</name>.-</command>") or ""
  check("the command exists", command ~= "")
  for _, name in ipairs({ "TITLE", "MESSAGE", "SEVERITY", "VARIABLE 1", "VARIABLE 2", "VARIABLE 3", "VARIABLE 4" }) do
    check("parameter " .. name, command:find("<name>" .. name .. "</name>", 1, true) ~= nil)
  end
  local _, pickers = command:gsub("<type>VARIABLE_SELECTOR</type>", "")
  check("four variable pickers", pickers == 4, pickers)
  check(
    "severity is Info / Warning / Critical",
    command:find("<item>Info</item><item>Warning</item><item>Critical</item>", 1, true) ~= nil
  )
  check("the test action exists", xml:find("<command>SEND_TEST_PUSH</command>", 1, true) ~= nil)
  check("the status property exists", xml:find("<name>Last Push Notification</name>", 1, true) ~= nil)
end

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
