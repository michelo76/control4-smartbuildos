-- VenueFlow and AI Core (brief D7b; conductor ruling: Remote Management
-- decides). The real driver.lua under the shim, the REAL Agent registry and
-- bus, and a fake AI Core that runs every report through AI Core's REAL
-- validator (test/aicore_reporter_harness.lua). Covered:
--   [1] Remote Management off (the default): no registration and no module
--       frame of any kind; the property follows AI Core in and out through
--       sbos.aipresence (silent): Not installed / Installed — this driver
--       does not report
--   [2] switched on at run time: registers (its own module client), the
--       helper attaches; a describe and a state AI Core accepts; only the
--       non-personal facts; no event, query or action; Found — reporting
--   [3] the run-time fault it already detects (a page request failed) is a
--       diagnostic; AI Core goes away and comes back
--   [4] switched off again: unregistered once, then silent; the property is
--       back on aipresence
--   [5] OnDriverDestroyed
-- Run from the driver root: make test

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

C4 = C4 or {}
require("c4_shim")
JSON = require("JSON")
local H = require("aicore_reporter_harness")

package.preload["drivers-common-public.global.url"] = function()
  return true
end
package.preload["cloud-client-byte"] = function()
  return true
end
local persisted = {}
package.preload["lib.persist"] = function()
  local P = {}
  function P:get(key, default)
    if persisted[key] == nil then
      return default
    end
    return persisted[key]
  end
  function P:set(key, value)
    persisted[key] = value
  end
  function P:delete(key)
    persisted[key] = nil
  end
  function P:reset() end
  return P
end

local SELF = 12345
C4.GetDevices = function()
  return {
    [H.AGENT] = { deviceName = "SmartBuildOS Agent", driverFileName = "smartbuildos.c4z" },
    [SELF] = { deviceName = "VenueFlow", driverFileName = "smartbuildos-venueflow.c4z" },
  }
end
C4.GetProjectItems = function()
  return ""
end
C4.GetDeviceVariables = function()
  return {}
end
C4.RegisterVariableListener = function() end
C4.UnregisterVariableListener = function() end
C4.GetDeviceDisplayName = function(_, id)
  return "Device " .. tostring(id)
end
C4.GetBindingsByDevice = function()
  return {}
end
C4.GetDeviceID = function()
  return SELF
end
C4.GetDriverConfigInfo = function(_, key)
  if key == "minimum_os_version" then
    return "3.3.2"
  elseif key == "name" then
    return "SmartBuildOS VenueFlow"
  end
  return "20261118.000002"
end
C4.GetTimeZone = function()
  return "America/New_York"
end
C4.FireEventByID = function() end
C4.FireEvent = function() end
C4.SetVariable = function() end
C4.AddVariable = function() end
C4.AddEvent = function() end
C4.UpdateProperty = function(_, name, value)
  Properties[name] = value
end
C4.GetVersionInfo = function()
  return { version = "4.3.0.0" }
end
C4.SendDataToUI = function() end
C4.SendToProxy = function() end
C4.CreateServer = function() end
C4.DestroyServer = function() end
C4.ServerSend = function() end
C4.ServerCloseClient = function() end

Properties = {}
do
  local f = assert(io.open("drivers/smartbuildos-venueflow/driver.xml"))
  local xml = f:read("*a")
  f:close()
  for block in xml:gmatch("<property>(.-)</property>") do
    Properties[block:match("<name>(.-)</name>")] = block:match("<default>(.-)</default>") or ""
  end
  check(
    "driver.xml declares the exact AI Core property",
    xml:find(
      "<property><name>AI Core</name><type>STRING</type><default>Searching…</default><readonly>true</readonly></property>",
      1,
      true
    ) ~= nil
  )
end
Properties["App Relay Address"] = "192.0.2.10"

H.install({ selfId = SELF, file = "smartbuildos-venueflow.c4z" })
dofile("drivers/smartbuildos-venueflow/driver.lua")
H.takeTimers()

local everPainted = {}
local realUpdate = UpdateProperty
UpdateProperty = function(name, value, ...)
  if name == "AI Core" then
    everPainted[#everPainted + 1] = value
  end
  return realUpdate(name, value, ...)
end

local function moduleFrames(from)
  local n = 0
  for i = from or 1, #H.frames do
    if tostring(H.frames[i].command):find("^SBOS_MODULE_") then
      n = n + 1
    end
  end
  return n
end
local function event(name)
  OSE[name]('<event name="' .. name .. '"/>')
  H.fire("SbosAiPresence")
end
local function value()
  return Properties["AI Core"]
end
local aireport = require("sbos.aireport")
local aipresence = require("sbos.aipresence")

print("[1] Remote Management off (the default): silent, never on the bus")
OnDriverInit()
OnDriverLateInit("DIT_ADDING")
check("Remote Management is off by default", Properties["Remote Management"] == "Off")
check("no module registration", H.count("SBOS_MODULE_REGISTER") == 0)
check("no module frame of any kind", moduleFrames() == 0, moduleFrames())
check("AI Core absent -> Not installed", value() == "Not installed", value())
check("the helper is not running; aipresence is", aireport.mode() == nil and aipresence.started())
H.aiRegister()
event("OnDriverAdded")
check(
  "AI Core added -> Installed — this driver does not report",
  value() == "Installed — this driver does not report",
  value()
)
for _ = 1, 5 do
  H.fire("VenueFlowStatus") -- whatever the status tick is called, nothing below may change
end
for id, t in pairs(H.timers) do
  if t.repeating and id ~= "SbosAiPresence" then
    t.fn()
  end
end
check(
  "frame count while off, AI Core present and the status ticks ran: zero module frames",
  moduleFrames() == 0,
  moduleFrames()
)
check("zero reports", H.reportFrames() == 0)
H.aiRemove()
event("OnItemRemoved")
check("AI Core removed -> Not installed", value() == "Not installed", value())
H.aiRegister()
event("OnDriverAdded")

print("[2] switched on at run time: reports through its own module client")
Properties["Remote Management"] = "Draft only"
OnPropertyChanged("Remote Management")
check("registered once, under venueflow", H.count("SBOS_MODULE_REGISTER") == 1)
local entry = H.registry:find("venueflow", tostring(SELF))
check("verified by the Agent (reserved id bound to its file)", entry ~= nil and entry.verified == true)
check("aipresence stopped, the helper attached", not aipresence.started() and aireport.mode() == "attach")
check("Found — reporting (v20261118.2)", value() == "Found — reporting (v20261118.2)", value())
local valid, why = H.allValid()
check("every report accepted by AI Core's validator", valid, why)
local describe = H.reports("describe")[1]
check("a describe was sent", describe ~= nil)
if describe then
  local d = describe.args
  check(
    "hand-written summary",
    d.summary ~= nil and d.summary:find("Venue audio and video control", 1, true) ~= nil,
    d.summary
  )
  check(
    "no controls, queries or actions declared",
    #(d.controls or {}) == 0 and #(d.queries or {}) == 0 and #(d.actions or {}) == 0
  )
end
local states = H.reports("state")
local facts = states[#states] and states[#states].args.facts or {}
local ALLOWED = {
  control_mode = true,
  remote_management = true,
  relay_listening = true,
  configuration_published = true,
  displays = true,
  sources = true,
  audio_zones = true,
  scenes = true,
  alerts = true,
  driver_status = true, -- the helper's baseline
  license = true, -- the helper's baseline
}
local extra = {}
for k in pairs(facts) do
  if not ALLOWED[k] then
    extra[#extra + 1] = k
  end
end
check("state carries only the non-personal facts", #extra == 0, table.concat(extra, ", "))
check(
  "facts: simulation, draft, relay listening, nothing published",
  facts.control_mode == "simulation"
    and facts.remote_management == "draft"
    and facts.relay_listening == true
    and facts.configuration_published == false,
  JSON:encode(facts)
)
check("no event report", #H.reports("event") == 0)
check(
  "its registration advertises no ai.query / ai.action (no manifest capabilities)",
  (function()
    for _, c in ipairs(entry and entry.manifest and entry.manifest.capabilities or {}) do
      if c.id == "ai.query" or c.id == "ai.action" then
        return false
      end
    end
    return true
  end)()
)
local q = H.aiAsk("venueflow", "ai.query", { query_id = "x", params = {} })
check("ai.query is not served (the bus refuses)", q == nil or q.status == "error")
local a = H.aiAsk("venueflow", "ai.action", { action_id = "x", params = {} })
check("ai.action is not served (the bus refuses)", a == nil or a.status == "error")

print("[3] the run-time fault it detects; AI Core away and back")
local Relay = require("venueflow.relay")
local realRoute = Relay.route
Relay.route = function()
  error("boom")
end
OnServerDataIn(1, "GET /app HTTP/1.1\r\n\r\n", "192.0.2.77", 47861, "venueflow-ui-relay")
Relay.route = realRoute
local diags = H.reports("diagnostic")
check(
  "a failed page request -> diagnostic fault relay.request_failed, fixed text",
  #diags == 1
    and diags[1].args.severity == "fault"
    and diags[1].args.code == "relay.request_failed"
    and not tostring(diags[1].args.text):find("boom", 1, true),
  #diags
)
H.aiRemove()
H.pushDirectory()
local before = H.reportFrames()
check("AI Core gone -> Not installed", value() == "Not installed", value())
H.aiRegister()
H.pushDirectory()
check(
  "AI Core back -> reporting again",
  value() == "Found — reporting (v20261118.2)" and H.reportFrames() > before,
  value()
)

print("[4] switched off again: unregistered, then silent")
local mark = #H.frames
Properties["Remote Management"] = "Off"
OnPropertyChanged("Remote Management")
check("unregistered once (the existing switch-off)", H.count("SBOS_MODULE_UNREGISTER") == 1)
check("not in the Agent's registry", H.registry:find("venueflow", tostring(SELF)) == nil)
check("helper stopped, aipresence running", aireport.mode() == nil and aipresence.started())
check("Installed — this driver does not report", value() == "Installed — this driver does not report", value())
local afterOff = #H.frames
for id, t in pairs(H.timers) do
  if t.repeating and id ~= "SbosAiPresence" then
    t.fn()
  end
end
H.aiRemove()
event("OnItemRemoved")
H.aiRegister()
event("OnDriverAdded")
OnServerDataIn(2, "GET /app HTTP/1.1\r\n\r\n", "192.0.2.77", 47861, "venueflow-ui-relay")
check("frame count after the switch: zero module frames", moduleFrames(afterOff + 1) == 0, moduleFrames(afterOff + 1))
check("the switch itself sent only the unregistration", moduleFrames(mark + 1) - moduleFrames(afterOff + 1) == 1)
check("value still follows AI Core", value() == "Installed — this driver does not report", value())

print("[5] OnDriverDestroyed")
OnDriverDestroyed()
check("aipresence stopped", not aipresence.started())

local outside = {}
for _, v in ipairs(everPainted) do
  if not aireport.isValue(v) then
    outside[#outside + 1] = v
  end
end
check("only closed values painted (" .. #everPainted .. ")", #outside == 0, table.concat(outside, " | "))

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
