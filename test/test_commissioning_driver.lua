-- Commissioning Matrix DRIVER under the shim with a scripted Agent and a
-- fake project: licence registration, the test list, a full run through
-- Composer commands and through the phone-page relay, events/variables, the
-- Flight Recorder markers, the as-built push to the Agent (and its ack),
-- persistence across a reload, a sensor passing on its own, the manual
-- Add Item picker, and licence enforcement.
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
tostring_return_period = tostring_return_period or tostring

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

-- ── persist (in memory) ─────────────────────────────────────────────────────
local persisted = {}
package.preload["lib.persist"] = function()
  local P = {}
  local EMPTY = {}
  function P:get(key, default)
    if default == nil then
      default = EMPTY
    end
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

-- ── fake Director ───────────────────────────────────────────────────────────
local AGENT_ID = 50
local RECORDER_ID = 60
local SELF_ID = 12345
local sent, fired, vars, props = {}, {}, {}, {}
local devVars = {
  [10] = { [1] = { name = "Brightness Percent", value = "20" } },
  [11] = { [1] = { name = "Level", value = "100" } },
  [12] = { [7] = { name = "ContactState", value = "0" } },
}
local listeners, serverCreated, serverSent = {}, nil, {}
local propLists = {}
local FAKE_APP_HTML = "<title>Commissioning Matrix</title>" .. string.rep("<!-- app -->", 120)
local function devices()
  return {
    [AGENT_ID] = { deviceName = "SmartBuildOS Agent", driverFileName = "smartbuildos.c4z" },
    [RECORDER_ID] = { deviceName = "Flight Recorder", driverFileName = "smartbuildos-flight-recorder.c4z" },
    [SELF_ID] = { deviceName = "Commissioning", driverFileName = "smartbuildos-commissioning.c4z" },
    [10] = { deviceName = "Pendant", roomName = "Kitchen", driverFileName = "light_v2.c4z" },
    [11] = { deviceName = "Roller", roomName = "Den", driverFileName = "blind.c4z" },
    [12] = { deviceName = "Door", roomName = "Den", driverFileName = "contactsingle_v2.c4z" },
    [13] = { deviceName = "Hall Lamp", roomName = "Hall", driverFileName = "mystery_switch.c4z" },
    [14] = { deviceName = "Thermostat", roomName = "Den", driverFileName = "thermostatV2.c4z" },
  }
end
C4.GetDevices = function()
  return devices()
end
C4.GetDevicesByC4iName = function(_, name)
  if name == "smartbuildos-flight-recorder.c4z" then
    return { [RECORDER_ID] = {} }
  end
  return {}
end
C4.GetDeviceVariables = function(_, id)
  return devVars[id] or {}
end
C4.RegisterVariableListener = function(_, id, varId)
  listeners[#listeners + 1] = id .. ":" .. varId
end
C4.UnregisterVariableListener = function(_, id, varId)
  for i, l in ipairs(listeners) do
    if l == id .. ":" .. varId then
      table.remove(listeners, i)
      break
    end
  end
end
C4.GetDeviceID = function()
  return SELF_ID
end
C4.GetDriverConfigInfo = function(_, key)
  if key == "minimum_os_version" then
    return "3.3.2"
  elseif key == "model" then
    return "Commissioning Matrix"
  end
  return "20261112.000000"
end
C4.SendToDevice = function(_, device, command, params)
  sent[#sent + 1] = { device = device, command = command, params = params }
  -- The devices follow their commands.
  if command == "RAMP_TO_LEVEL" and device == 10 then
    devVars[10][1].value = tostring(params.LEVEL)
  elseif command == "SET_LEVEL_TARGET" and device == 11 then
    devVars[11][1].value = tostring(params.LEVEL_TARGET)
  end
end
C4.FireEventByID = function(_, id)
  fired[#fired + 1] = id
end
C4.FireEvent = function() end
C4.SetVariable = function(_, name, value)
  vars[name] = value
end
C4.AddVariable = function() end
C4.AddEvent = function() end
C4.UpdateProperty = function(_, name, value)
  props[name] = value
  Properties[name] = value
end
C4.UpdatePropertyList = function(_, name, list, current)
  propLists[name] = list
  props[name] = current
  Properties[name] = current
end
C4.GetVersionInfo = function()
  return { version = "4.2.0.0" }
end
C4.FileSetDir = function() end
C4.FileExists = function(_, path)
  return path == "www/app/index.html"
end
C4.FileOpen = function(_, path)
  return path == "www/app/index.html" and 7 or -1
end
C4.FileGetSize = function(_, handle)
  return handle == 7 and #FAKE_APP_HTML or 0
end
C4.FileSetPos = function() end
C4.FileRead = function(_, handle)
  return handle == 7 and FAKE_APP_HTML or ""
end
C4.FileClose = function() end
C4.CreateServer = function(_, port, _, _, identifier)
  serverCreated = { port = port, identifier = identifier }
  return true
end
C4.ServerSend = function(_, handle, data)
  serverSent[#serverSent + 1] = { handle = handle, data = data }
end
C4.ServerCloseClient = function() end
C4.DestroyServer = function() end

local function loadProperties()
  Properties = {}
  local f = assert(io.open("drivers/smartbuildos-commissioning/driver.xml"))
  local xml = f:read("*a")
  f:close()
  for block in xml:gmatch("<property>(.-)</property>") do
    Properties[block:match("<name>(.-)</name>")] = block:match("<default>(.-)</default>") or ""
  end
end
loadProperties()
Properties["Settle Seconds"] = "1"
Properties["Technician Name"] = "Sam"

RELAY_PINGS = {}
require("lib.relayhost").get = function(url, done)
  RELAY_PINGS[#RELAY_PINGS + 1] = url
  done(false)
end
Properties["App Relay Address"] = "10.9.9.9"

dofile("drivers/smartbuildos-commissioning/driver.lua")

local function prop(name)
  return props[name] or Properties[name]
end
local function countFired(id)
  local n = 0
  for _, f in ipairs(fired) do
    if f == id then
      n = n + 1
    end
  end
  return n
end
local function sentOf(command, device)
  local out = {}
  for _, s in ipairs(sent) do
    if s.command == command and (device == nil or s.device == device) then
      out[#out + 1] = s
    end
  end
  return out
end
local function relay(method, path, body)
  serverSent = {}
  body = body or ""
  OnServerDataIn(
    100,
    method .. " " .. path .. " HTTP/1.1\r\nContent-Length: " .. #body .. "\r\n\r\n" .. body,
    nil,
    nil,
    "commissioning-ui-relay"
  )
  local data = serverSent[1] and serverSent[1].data or ""
  local status = data:match("^HTTP/1.1 (%d+)")
  local payload = data:match("\r\n\r\n(.*)$") or ""
  local ok, doc = pcall(function()
    return JSON:decode(payload)
  end)
  return tonumber(status), ok and doc or nil, payload
end
local function token()
  return prop("Technician Page"):match("[?&]k=(%w+)") or ""
end
local function post(name, doc)
  return relay("POST", "/" .. name .. "?k=" .. token(), JSON:encode(doc or {}))
end

print("[1] start: online, licence registered under the SKU, list built, page link")
OnDriverInit()
OnDriverLateInit("DIT_ADDING")
check("online", props["Driver Status"] == "Online")
check(
  "licence registration under SBOS_COMMISSIONING to the Agent",
  #sentOf("SBOS_REGISTER_DRIVER") == 1
    and sentOf("SBOS_REGISTER_DRIVER")[1].params.sku == "SBOS_COMMISSIONING"
    and sentOf("SBOS_REGISTER_DRIVER")[1].device == AGENT_ID
)
EC.SBOS_ENTITLEMENT({ sku = "SBOS_COMMISSIONING", status = "AUTHORIZED_SUBSCRIPTION", registered = "true", subscription_tier = "Professional", company_name = "Skynet AV" })
check("licence painted", prop("License Status"):find("Licensed") ~= nil and prop("Subscription Tier") == "Professional")
check("list holds light, shade, sensor (not the thermostat, the agent or itself)", prop("Test List") == "3 item(s) in 2 room(s)", prop("Test List"))
check("page relay on its port", serverCreated ~= nil and serverCreated.port == 47841 and serverCreated.identifier == "commissioning-ui-relay")
check("technician page link", prop("Technician Page"):find("http://10.9.9.9:47841/app?k=", 1, true) == 1, prop("Technician Page"))
check("idle state", prop("Run Status") == "idle" and vars["RUN_STATUS"] == "idle" and TC.RUN_HAS_FAILURES() == false)
check("device pickers filled", (propLists["Add Item"] or ""):find("Thermostat (Den) · 14", 1, true) ~= nil)
check("the driver is not in its own picker", (propLists["Add Item"] or ""):find("Commissioning", 1, true) == nil)

print("[2] the phone page: app, token wall, state")
local status = relay("GET", "/ping")
check("ping tokenless", status == 200)
local status2, _, html = relay("GET", "/app")
check("app served tokenless", status2 == 200 and html:find("Commissioning Matrix", 1, true) ~= nil)
check("state without token refused", (relay("GET", "/state")) == 403)
local st, doc = relay("GET", "/state?k=" .. token())
check("state lists rooms and items", st == 200 and #doc.rooms == 2 and #doc.items == 3 and doc.status == "idle", st)
check("state carries the licence label and no run", doc.run_id == nil and doc.read_only == false)

print("[3] a run from the page: start, test a light, readback, verdict")
st, doc = post("room", { room = "Kitchen" })
check("picking a room starts a run scoped to it", st == 200 and doc.ok == true and vars["CURRENT_ROOM"] == "Kitchen" and prop("Run Status") == "running")
check("start recorded in the Flight Recorder", #sentOf("RECORD_EVENT", RECORDER_ID) >= 1 and sentOf("RECORD_EVENT", RECORDER_ID)[1].params.CHANNEL == "commissioning")
st, doc = post("test", { key = "light:10" })
check("test accepted", st == 200 and doc.ok == true)
check("the light was asked for 100%", sentOf("RAMP_TO_LEVEL", 10)[1].params.LEVEL == 100)
advance(1000)
check("restore ramp goes back to the level it had", sentOf("RAMP_TO_LEVEL", 10)[2] and sentOf("RAMP_TO_LEVEL", 10)[2].params.LEVEL == 20)
advance(1000)
st, doc = relay("GET", "/state?k=" .. token())
local item = doc.items[1]
check("item awaits a verdict with what the device reported", item.status == "awaiting" and item.reported == "match" and item.readback.act.level == 100)
st, doc = post("mark", { key = "light:10", verdict = "pass", note = "lamp lit" })
check("pass accepted", st == 200 and doc.ok == true)
check("Room Passed fired and variables set", countFired(1) == 1 and vars["LAST_PASSED_ROOM"] == "Kitchen" and vars["PASSED_COUNT"] == 1)
check("marker for the verdict", (function()
  for _, s in ipairs(sentOf("RECORD_EVENT", RECORDER_ID)) do
    if s.params.NAME:find("Pendant passed", 1, true) then
      return true
    end
  end
  return false
end)())
check("a refused action reports why and says 409", (function()
  local s, d = post("mark", { key = "light:10", verdict = "bogus" })
  return s == 409 and d.ok == false and d.reason:find("verdict") ~= nil
end)())
check("Last Refusal painted", prop("Last Refusal"):find("Mark Item") ~= nil)
check("bad JSON body refused", (relay("POST", "/mark?k=" .. token(), "not json")) == 400)
check("unknown route 404", (relay("GET", "/nope?k=" .. token())) == 404)
check("scoped run is complete and waits for sign-off", prop("Run Status") == "complete")

print("[4] sign-off: record stored, pushed to the Agent, acknowledged")
check("no result before sign-off", (relay("GET", "/result?k=" .. token())) ~= nil)
st, doc = post("signoff", { name = "Sam" })
check("signed off", st == 200 and doc.ok == true and prop("Run Status") == "signed_off")
check("Run Completed fired", countFired(2) == 1)
local push = sentOf("SBOS_COMMISSIONING_RESULT", AGENT_ID)[1]
check("the as-built record is offered to the Agent", push ~= nil and push.params.run_id ~= nil)
local pushed = JSON:decode(push.params.json)
check("record: schema, who, counts, rooms", pushed.schema == "commissioning.run.v1" and pushed.signed_off_by == "Sam" and pushed.counts.passed == 1 and pushed.rooms[1].name == "Kitchen")
check("record keeps the readback and the honest limits", pushed.rooms[1].items[1].readback.act.level == 100 and pushed.honest_limits ~= nil)
check("Last Result painted", prop("Last Result"):find(pushed.run_id, 1, true) ~= nil)
st, doc = relay("GET", "/result?k=" .. token())
check("result route serves the same record", st == 200 and doc.run_id == pushed.run_id)
advance(3000)
EC.SBOS_COMMISSIONING_PULL()
check("the Agent can pull the record again", #sentOf("SBOS_COMMISSIONING_RESULT", AGENT_ID) == 2)
EC.SBOS_COMMISSIONING_PULL()
check("a pull offers it again and keeps offering until the ack", #sentOf("SBOS_COMMISSIONING_RESULT", AGENT_ID) == 3)
advance(61000)
check("the status timer re-offers an unacknowledged record", #sentOf("SBOS_COMMISSIONING_RESULT", AGENT_ID) >= 4)
EC.SBOS_COMMISSIONING_ACK({ run_id = pushed.run_id })
local before = #sentOf("SBOS_COMMISSIONING_RESULT", AGENT_ID)
EC.SBOS_ENTITLEMENT({ sku = "SBOS_COMMISSIONING", status = "AUTHORIZED_SUBSCRIPTION", registered = "true" })
advance(61000)
check("no re-push after the ack", #sentOf("SBOS_COMMISSIONING_RESULT", AGENT_ID) == before)

print("[5] Composer commands: Start Run, sensor by itself, shade, failure, Print Results")
EC.START_RUN({ TECHNICIAN = "Ana" })
check("whole-project run started", prop("Run Status") == "running" and vars["OPEN_COUNT"] == 3)
EC.START_ROOM({ ROOM = "Den" })
check("Start Room picks the room inside the run", vars["CURRENT_ROOM"] == "Den")
EC.START_ROOM({ ROOM = "Moon" })
check("an unknown room is refused and named", prop("Last Refusal"):find("Start Room") ~= nil and prop("Last Refusal"):find("Moon") ~= nil)
post("test", { key = "sensor:12" })
check("a listener is registered on the sensor's state variable", listeners[1] == "12:7", listeners[1])
OnWatchedVariableChanged(12, 7, "1")
st, doc = relay("GET", "/state?k=" .. token())
local door
for _, it in ipairs(doc.items) do
  if it.key == "sensor:12" then
    door = it
  end
end
check("the sensor passed by itself", door.status == "passed" and door.readback.after == "1")
check("listener removed after the pass", #listeners == 0)
post("test", { key = "shade:11" })
advance(4000)
advance(4000)
check("shade asked for the end it was not at", sentOf("SET_LEVEL_TARGET", 11)[1].params.LEVEL_TARGET == 0)
post("mark", { key = "shade:11", verdict = "fail", note = "stuck half way" })
check("Item Failed fired with the item named", countFired(3) == 1 and vars["LAST_FAILED_ITEM"] == "Roller (Den)" and vars["FAILED_COUNT"] == 1)
check("conditional: run has failures", TC.RUN_HAS_FAILURES() == true)
post("mark", { key = "light:10", verdict = "skip" })
check("run complete with one failure", prop("Run Status") == "complete" and vars["SKIPPED_COUNT"] == 1)
local printed = {}
local realPrint = print
print = function(...)
  printed[#printed + 1] = table.concat({ ... }, " ")
end
Properties["Log Mode"] = "Print"
OnPropertyChanged("Log Mode")
OnPropertyChanged("Log Level")
EC.PRINT_RESULTS()
print = realPrint
check("Print Results does not throw", true)
EC.ABORT_RUN()
check("abort ends the run and stays on the record", prop("Run Status") == "aborted")

print("[6] persistence: a reload keeps the signed record and the history")
advance(3000)
OnDriverDestroyed()
vars, props, fired = {}, {}, {}
loadProperties()
Properties["Settle Seconds"] = "1"
Properties["App Relay Address"] = "10.9.9.9"
dofile("drivers/smartbuildos-commissioning/driver.lua")
OnDriverInit()
OnDriverLateInit("DIT_ADDING")
check("restored: last result remembered", prop("Last Result"):find("restored", 1, true) ~= nil or prop("Last Result"):find(pushed.run_id, 1, true) ~= nil, prop("Last Result"))
st, doc = relay("GET", "/result?k=" .. token())
check("restored: result route has a record", st == 200 and doc.run_id ~= nil)
check("restored: the page token survived the reload", token() ~= "" and relay("GET", "/state?k=" .. token()) == 200)

print("[7] manual items: the Add Item picker")
Properties["Add Item As"] = "Light"
Properties["Add Item"] = "Hall Lamp (Hall) · 13"
OnPropertyChanged("Add Item")
check("the picker went back to -", Properties["Add Item"] == "-" and props["Add Item"] == "-")
check("a manual item joined the list", prop("Test List") == "4 item(s) in 3 room(s)", prop("Test List"))
Properties["Add Item As"] = "Auto-detect"
Properties["Add Item"] = "Thermostat (Den) · 14"
OnPropertyChanged("Add Item")
check("an undetectable kind is refused with advice", prop("Last Refusal"):find("Add Item As", 1, true) ~= nil, prop("Last Refusal"))
Properties["Add Item"] = "garbage"
OnPropertyChanged("Add Item")
check("an unreadable entry is refused", prop("Last Refusal"):find("could not read") ~= nil)
EC.CLEAR_MANUAL_ACTION()
check("clearing manual items rebuilds the list", prop("Test List") == "3 item(s) in 2 room(s)")
Properties["Add Item As"] = "Light"
Properties["Add Item"] = "Hall Lamp (Hall) · 13"
OnPropertyChanged("Add Item")

print("[8] licence enforcement: read-only, results still readable; fail-open otherwise")
EC.SBOS_ENTITLEMENT({ sku = "SBOS_COMMISSIONING", status = "NOT_ENTITLED", registered = "true", enforcement = "observe" })
EC.START_RUN({})
check("denial without enforcement still runs (fail open)", prop("Run Status") == "running")
EC.ABORT_RUN()
EC.SBOS_ENTITLEMENT({ sku = "SBOS_COMMISSIONING", status = "NOT_ENTITLED", registered = "true", enforcement = "enforce" })
check("definitive denial + enforcement is read-only", prop("Run Status") == "read-only (licence)")
EC.START_RUN({})
check("start refused and said so", prop("Last Refusal"):find("read-only", 1, true) ~= nil, prop("Last Refusal"))
st, doc = post("run", {})
check("the page is refused too", st == 409 and doc.reason:find("read-only", 1, true) ~= nil)
st = relay("GET", "/result?k=" .. token())
check("results stay readable", st == 200)
st, doc = relay("GET", "/state?k=" .. token())
check("page state says read-only", doc.read_only == true)
EC.SBOS_ENTITLEMENT({ sku = "SBOS_COMMISSIONING", status = "CLOUD_VALIDATION_REQUIRED", registered = "true", enforcement = "enforce" })
EC.START_RUN({})
check("an unreachable cloud is not a denial: runs again", prop("Run Status") == "running")

print("[9] new page link, removal")
local oldToken = token()
EC.NEW_PAGE_LINK_ACTION()
check("a new link replaces the token", token() ~= oldToken and (relay("GET", "/state?k=" .. oldToken)) == 403)
OnDriverDestroyed()
check("destroyed without error", true)

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
