-- PIN Lock DRIVER under the shim with a scripted Agent and Director:
-- licence registration, first-owner setup and code management through the
-- relay, granting through the page and through keypad sequences, the Composer
-- events/variables/target commands, lockouts (and their survival across a
-- reload), programming commands through Director's own dispatcher, licence
-- restriction (owner keeps working), Flight Recorder markers, and -- the
-- point of the exercise -- that no PIN, sequence or stored digest appears in
-- any log line, property, variable, command, event, relay reply or recorder
-- marker, with Trace logging and handler debug switched on.
--
-- Run from the driver root: make test

local pass, fail = 0, 0
local function check(name, ok, detail)
  if ok then
    pass = pass + 1
    io.write(string.format("  ok   %s\n", name))
  else
    fail = fail + 1
    io.write(string.format("  FAIL %s%s\n", name, detail and ("  -> " .. tostring(detail)) or ""))
  end
end

C4 = C4 or {}
require("c4_shim")
JSON = require("JSON")

-- ── everything the driver can say goes through here ────────────────────────
local captured = {}
local realPrint = print
local function capture(kind, value)
  captured[#captured + 1] = kind .. ": " .. tostring(value)
end
print = function(...)
  local parts = {}
  for i = 1, select("#", ...) do
    parts[#parts + 1] = tostring((select(i, ...)))
  end
  capture("print", table.concat(parts, "\t"))
end
C4.DebugLog = function(_, message)
  capture("debuglog", message)
end
C4.ErrorLog = function(_, message)
  capture("errorlog", message)
end

-- ── timers and clock ────────────────────────────────────────────────────────
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
local base = os.time({ year = 2027, month = 1, day = 6, hour = 12, min = 0, sec = 0 }) -- a Wednesday
PIN_LOCK_NOW = function()
  return base + clock.now / 1000
end
local realTime = os.time
os.time = function(t)
  if t then
    return realTime(t)
  end
  return base + math.floor(clock.now / 1000)
end
package.preload["drivers-common-public.global.url"] = function()
  return true
end
package.preload["cloud-client-byte"] = function()
  return true
end

-- ── persist (in memory, and inspectable) ────────────────────────────────────
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
    persisted[key] = JSON:decode(JSON:encode(value)) -- what a real store would hold: a copy
  end
  function P:delete(key)
    persisted[key] = nil
  end
  function P:reset() end
  return P
end

-- ── fake Director ───────────────────────────────────────────────────────────
local AGENT_ID, SELF_ID, LOCK_ID, RECORDER_ID = 50, 12345, 40, 60
local sent, fired, vars, props, proxySends, serverSent = {}, {}, {}, {}, {}, {}
C4.GetDevices = function()
  return {
    [AGENT_ID] = { deviceName = "SmartBuildOS Agent", driverFileName = "smartbuildos.c4z" },
    [SELF_ID] = { deviceName = "PIN Lock", driverFileName = "smartbuildos-pin-lock.c4z" },
    [LOCK_ID] = { deviceName = "Wine Cellar Lock", roomName = "Cellar", driverFileName = "lock.c4z" },
    [41] = { deviceName = "Hall Light", roomName = "Hall", driverFileName = "light.c4z" },
    [RECORDER_ID] = { deviceName = "Flight Recorder", driverFileName = "smartbuildos-flight-recorder.c4z" },
  }
end
C4.GetDeviceID = function()
  return SELF_ID
end
C4.GetDriverConfigInfo = function(_, key)
  if key == "minimum_os_version" then
    return "3.3.2"
  elseif key == "model" then
    return "PIN Lock"
  end
  return "20261112.000000"
end
C4.SendToDevice = function(_, device, command, params)
  sent[#sent + 1] = { device = device, command = command, params = params }
end
C4.SendToProxy = function(_, binding, command, params)
  proxySends[#proxySends + 1] = { binding = binding, command = command, params = params }
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
C4.UpdatePropertyList = function(_, name, csv, selected)
  props["list:" .. name] = csv
end
C4.GetVersionInfo = function()
  return { version = "4.2.0.0" }
end
C4.GetControllerNetworkAddress = function()
  return "192.0.2.10"
end
local serverCreated
C4.CreateServer = function(_, port, _, _, identifier)
  serverCreated = { port = port, identifier = identifier }
  return true
end
C4.ServerSend = function(_, handle, data)
  serverSent[#serverSent + 1] = { handle = handle, data = data }
end
C4.ServerCloseClient = function() end
C4.DestroyServer = function() end
local FAKE_APP = "<!DOCTYPE html><html><body>" .. string.rep("pin lock ", 90) .. "</body></html>"
C4.FileExists = function()
  return true
end
C4.FileOpen = function()
  return 7
end
C4.FileGetSize = function()
  return #FAKE_APP
end
C4.FileRead = function(_, handle)
  return handle == 7 and FAKE_APP or ""
end

Properties = {}
do
  local f = assert(io.open("drivers/smartbuildos-pin-lock/driver.xml"))
  local xml = f:read("*a")
  f:close()
  for block in xml:gmatch("<property>(.-)</property>") do
    local name = block:match("<name>(.-)</name>")
    local default = block:match("<default>(.-)</default>") or ""
    Properties[name] = default
  end
end
-- The dealer's configuration, with the loudest logging the driver offers.
Properties["Guarded 1 Name"] = "Unlock wine cellar"
Properties["Guarded 1 Target"] = "Wine Cellar Lock (Cellar) · 40"
Properties["Guarded 1 Target Action"] = "Unlock"
Properties["Guarded 2 Name"] = "Open garage service door"
Properties["Guarded 3 Name"] = "Disable alarm zone"
Properties["Re-lock After Seconds"] = "10"
Properties["Max Wrong Attempts"] = "5"
Properties["Lockout Minutes"] = "5"
Properties["Log Level"] = "5 - Trace"
Properties["Log Mode"] = "Print and Log"

require("lib.relayhost").get = function(url, done)
  done(true, '{"ok":true,"service":"pin-lock"}')
end

local function loadDriver()
  dofile("drivers/smartbuildos-pin-lock/driver.lua")
  OnDriverInit()
  OnPropertyChanged("Log Level") -- also turns handler debug on, like a dealer at Trace
  OnDriverLateInit("DIT_ADDING")
end

local function prop(name)
  return props[name] or Properties[name]
end
local function firedCount(id)
  local n = 0
  for _, f in ipairs(fired) do
    if f == id then
      n = n + 1
    end
  end
  return n
end
local function lastSent(command, device)
  local out
  for _, s in ipairs(sent) do
    if s.command == command and (device == nil or s.device == device) then
      out = s
    end
  end
  return out
end
local function sentCount(command, device)
  local n = 0
  for _, s in ipairs(sent) do
    if s.command == command and (device == nil or s.device == device) then
      n = n + 1
    end
  end
  return n
end
local handleSeq = 100
local function http(method, pathAndQuery, bodyTable)
  local body = bodyTable and JSON:encode(bodyTable) or ""
  handleSeq = handleSeq + 1
  local before = #serverSent
  local req = method .. " " .. pathAndQuery .. " HTTP/1.1\r\nHost: x\r\nContent-Length: " .. #body .. "\r\n\r\n" .. body
  local cut = math.floor(#req / 2)
  OnServerDataIn(handleSeq, req:sub(1, cut), nil, nil, "pinlock-ui-relay")
  OnServerDataIn(handleSeq, req:sub(cut + 1), nil, nil, "pinlock-ui-relay")
  if #serverSent == before then
    return nil, nil
  end
  local raw = serverSent[#serverSent].data
  local status = raw:match("^HTTP/1%.1 (%d+)")
  local payload = raw:match("\r\n\r\n(.*)$") or ""
  local ok, decoded = pcall(function()
    return JSON:decode(payload)
  end)
  return tonumber(status), ok and decoded or payload
end

local OWNER_PIN, STAFF_PIN, VENDOR_PIN, COURIER_PIN = "7391", "4826", "5183", "6290"
local SEQUENCE = "1-3-3-2"
local WRONG_A, WRONG_B = "3047", "8265"
local TOKEN

io.write("[1] start: licence registered, relay listening, setup needed\n")
loadDriver()
check("online", props["Driver Status"] == "Online")
check(
  "licence registered under SBOS_PIN_LOCK",
  lastSent("SBOS_REGISTER_DRIVER") ~= nil
    and lastSent("SBOS_REGISTER_DRIVER").device == AGENT_ID
    and lastSent("SBOS_REGISTER_DRIVER").params.sku == "SBOS_PIN_LOCK"
)
EC.SBOS_ENTITLEMENT({
  sku = "SBOS_PIN_LOCK",
  status = "AUTHORIZED_SUBSCRIPTION",
  license_type = "subscription",
  registered = "true",
  subscription_tier = "Professional",
  company_name = "Example AV",
})
check("licence painted", prop("License Status"):find("Licensed") ~= nil and prop("Subscription Tier") == "Professional")
check("relay on 47831", serverCreated ~= nil and serverCreated.port == 47831)
local url
for _, p in ipairs(proxySends) do
  if p.command == "URL_CHANGED" then
    url = p.params.url
  end
end
check("web view URL with token published", url ~= nil and url:find("^http://192%.0%.2%.10:47831/app%?k=%w+$") ~= nil, url)
TOKEN = url:match("k=(%w+)$")
check("gate status says setup is needed", prop("Gate Status"):find("setup needed") ~= nil, prop("Gate Status"))
check("target picker filled as Name (Room) · id", (props["list:Guarded 1 Target"] or ""):find("Wine Cellar Lock (Cellar) · 40", 1, true) ~= nil and (props["list:Guarded 1 Target"] or ""):find("Hall Light", 1, true) == nil, props["list:Guarded 1 Target"])
check("Flight Recorder found quietly", true)
local status, doc = http("GET", "/config?k=" .. TOKEN)
check("config lists the named actions and wants setup", status == 200 and #doc.actions == 3 and doc.setup_needed == true)
check("page without a token is refused", (http("GET", "/config")) == 403)

io.write("[2] first owner, then codes through the admin page\n")
status, doc = http("POST", "/admin/setup?k=" .. TOKEN, { name = "Owner", pin = OWNER_PIN })
check("owner created and signed in", status == 200 and doc.ok == true and #doc.session == 32)
local SESSION = doc.session
check("setup cannot be repeated", (http("POST", "/admin/setup?k=" .. TOKEN, { name = "Again", pin = STAFF_PIN })) == 422)
check("gate is active once an owner exists", prop("Gate Status") == "active", prop("Gate Status"))
status, doc = http("POST", "/admin/save?k=" .. TOKEN, {
  session = SESSION,
  name = "Marta",
  role = "staff",
  pin = STAFF_PIN,
  actions = { 1, 2 },
  days = {},
  from = "",
  to = "",
  start_date = "",
  expiry_date = "",
  max_uses = "",
})
check("staff code saved", status == 200 and doc.ok == true, JSON:encode(doc))
status, doc = http("POST", "/admin/save?k=" .. TOKEN, {
  session = SESSION,
  name = "Alarm tech",
  role = "staff",
  seq = SEQUENCE,
  actions = { 3 },
  keypad_action = 3,
  days = {},
  from = "",
  to = "",
  start_date = "",
  expiry_date = "",
  max_uses = "",
})
check("keypad-sequence code saved", status == 200 and doc.ok == true, JSON:encode(doc))
status, doc = http("POST", "/admin/save?k=" .. TOKEN, { session = SESSION, name = "Weak", role = "guest", pin = "1234", actions = { 1 } })
check("weak PIN refused with a reason", status == 422 and doc.error:find("PIN must be") ~= nil, JSON:encode(doc))
status, doc = http("POST", "/admin/state?k=" .. TOKEN, { session = SESSION })
check("admin state lists 3 codes without secrets", status == 200 and #doc.codes == 3 and JSON:encode(doc):find("hash", 1, true) == nil)
check("admin needs a session", (http("POST", "/admin/state?k=" .. TOKEN, { session = "nope" })) == 401)
check("Codes property updated", prop("Codes") == "3 code(s), 3 active", prop("Codes"))

io.write("[3] granting through the page\n")
status, doc = http("POST", "/unlock?k=" .. TOKEN, { action = 1, pin = STAFF_PIN })
check("granted with a generic reply", status == 200 and doc.ok == true and doc.message == "Unlock wine cellar")
check("Access Granted and Guarded 1 Granted fired", firedCount(1) == 1 and firedCount(11) == 1 and firedCount(12) == 0)
check("variables name the code, the action and the entry point", vars["LAST_CODE_NAME"] == "Marta" and vars["LAST_ACTION"] == "Unlock wine cellar" and vars["LAST_ACTION_NUMBER"] == 1 and vars["LAST_ENTRY_POINT"] == "page")
check("target lock commanded", sentCount("UNLOCK", LOCK_ID) == 1)
check("Last Access painted", prop("Last Access"):find("granted: Marta") ~= nil, prop("Last Access"))
local marker = lastSent("RECORD_EVENT", RECORDER_ID)
check("Flight Recorder got a marker with code NAME and action", marker ~= nil and marker.params.NAME:find("Unlock wine cellar", 1, true) ~= nil and marker.params.DETAIL:find("code=Marta", 1, true) ~= nil)
advance(9000)
check("no re-lock before the delay", sentCount("LOCK", LOCK_ID) == 0)
advance(2000)
check("target re-locked after the delay", sentCount("LOCK", LOCK_ID) == 1)
status, doc = http("POST", "/unlock?k=" .. TOKEN, { action = 3, pin = STAFF_PIN })
check("an action off the code's list is refused generically", status == 401 and doc.error == "not allowed" and doc.reason == nil and doc.code == nil, JSON:encode(doc))
check("Access Denied fired with the reason in a variable", firedCount(2) == 1 and vars["LAST_DENIAL_REASON"] == "not_allowed")
status, doc = http("POST", "/unlock?k=" .. TOKEN, { action = 1, pin = WRONG_B })
check("a wrong PIN is the same generic reply", status == 401 and doc.error == "not allowed")
check("conditional: Marta is active", TestCondition("CODE_ACTIVE", { VALUE = "marta", LOGIC = "EQUAL" }) == true and TestCondition("CODE_ACTIVE", { VALUE = "nobody", LOGIC = "NOT_EQUAL" }) == true)

io.write("[4] keypad sequences\n")
for _, b in ipairs({ "1", "3", "3" }) do
  ExecuteCommand("KEYPAD_PRESS", { BUTTON = b, KEYPAD = "Hall" })
end
check("nothing fires on a partial sequence", firedCount(13) == 0)
ExecuteCommand("KEYPAD_PRESS", { BUTTON = "2", KEYPAD = "Hall" })
check("the full sequence fires the code's action", firedCount(13) == 1 and vars["LAST_ENTRY_POINT"] == "keypad" and vars["LAST_CODE_NAME"] == "Alarm tech")
for _ = 1, 5 do
  for _, b in ipairs({ "9", "9", "9", "8" }) do
    ExecuteCommand("KEYPAD_PRESS", { BUTTON = b, KEYPAD = "Hall" })
  end
end
check("five wrong sequences lock the keypad", firedCount(3) == 1 and vars["LAST_LOCKED_ENTRY"] == "keypad")
check("conditional: keypad locked, page not", TestCondition("ENTRY_LOCKED", { VALUE = "keypad", LOGIC = "EQUAL" }) == true and TestCondition("ENTRY_LOCKED", { VALUE = "page", LOGIC = "EQUAL" }) == false)
check("the page still works while the keypad is locked", (http("POST", "/unlock?k=" .. TOKEN, { action = 2, pin = STAFF_PIN })) == 200)

io.write("[5] lockout on the page, and across a reload\n")
for _ = 1, 5 do
  status, doc = http("POST", "/unlock?k=" .. TOKEN, { action = 1, pin = WRONG_A })
end
check("fifth wrong PIN locks the page", status == 429 and doc.locked == true and doc.retry_in == 300, JSON:encode(doc))
check("Entry Point Locked Out fired for the page", firedCount(3) == 2 and vars["LAST_LOCKED_ENTRY"] == "page")
status, doc = http("POST", "/unlock?k=" .. TOKEN, { action = 1, pin = STAFF_PIN })
check("the RIGHT PIN is refused during the lockout", status == 429 and doc.ok == false)
check("Entry Points property shows the lock", prop("Entry Points"):find("page LOCKED") ~= nil, prop("Entry Points"))
local grantedBefore = firedCount(1)
advance(3000) -- let the 2 s persist timer run
fired, sent = {}, {}
loadDriver() -- a reboot: the persisted store survives, the process does not
status, doc = http("POST", "/unlock?k=" .. TOKEN, { action = 1, pin = STAFF_PIN })
check("lockout survives a reload", status == 429, status)
check("codes survive a reload", TestCondition("CODE_ACTIVE", { VALUE = "Marta", LOGIC = "EQUAL" }) == true and prop("Codes"):find("^3 code") ~= nil, prop("Codes"))
advance(5 * 60 * 1000)
status, doc = http("POST", "/unlock?k=" .. TOKEN, { action = 1, pin = STAFF_PIN })
check("granted again after the lockout time", status == 200 and doc.ok == true, status)
check("the lock command went out again after the reload", sentCount("UNLOCK", LOCK_ID) == 1)

io.write("[6] programming commands through Director's dispatcher\n")
ExecuteCommand("ADD_TEMPORARY_CODE", { NAME = "Courier", PIN = COURIER_PIN, ACTIONS = "2", HOURS = "2", MAX_USES = "1" })
status, doc = http("POST", "/unlock?k=" .. TOKEN, { action = 2, pin = COURIER_PIN })
check("temporary code works once", status == 200 and doc.ok == true)
status = http("POST", "/unlock?k=" .. TOKEN, { action = 2, pin = COURIER_PIN })
check("and not twice (max uses 1)", status == 401 and vars["LAST_DENIAL_REASON"] == "used_up")
ExecuteCommand("ADD_TEMPORARY_CODE", { NAME = "Nope", PIN = "1111", ACTIONS = "2" })
check("a weak temporary PIN is refused and says so", prop("Last Refusal"):find("Add Temporary Code: PIN must be") ~= nil, prop("Last Refusal"))
ExecuteCommand("ADD_TEMPORARY_CODE", { NAME = "Nope2", PIN = VENDOR_PIN, ACTIONS = "zzz" })
check("unknown actions refused", prop("Last Refusal"):find("no valid guarded actions") ~= nil)
ExecuteCommand("DISABLE_CODE", { NAME = "Marta" })
check("Disable Code", TestCondition("CODE_ACTIVE", { VALUE = "Marta", LOGIC = "EQUAL" }) == false)
status = http("POST", "/unlock?k=" .. TOKEN, { action = 1, pin = STAFF_PIN })
check("a disabled code is denied", status == 401 and vars["LAST_DENIAL_REASON"] == "disabled")
ExecuteCommand("ENABLE_CODE", { NAME = "marta" })
check("Enable Code", TestCondition("CODE_ACTIVE", { VALUE = "Marta", LOGIC = "EQUAL" }) == true)
ExecuteCommand("REVOKE_CODE", { NAME = "Courier" })
check("Revoke Code", TestCondition("CODE_ACTIVE", { VALUE = "Courier", LOGIC = "EQUAL" }) == false)
ExecuteCommand("REVOKE_CODE", { NAME = "Owner" })
check("the last owner cannot be revoked", prop("Last Refusal"):find("last owner") ~= nil)
for _ = 1, 5 do
  http("POST", "/unlock?k=" .. TOKEN, { action = 1, pin = WRONG_A })
end
check("locked again", TestCondition("ENTRY_LOCKED", { VALUE = "page", LOGIC = "EQUAL" }) == true)
ExecuteCommand("CLEAR_LOCKOUTS", {})
check("Clear Lockouts", TestCondition("ENTRY_LOCKED", { VALUE = "page", LOGIC = "EQUAL" }) == false and (http("POST", "/unlock?k=" .. TOKEN, { action = 1, pin = STAFF_PIN })) == 200)
check("Print State runs", pcall(EC.PRINT_STATE))

io.write("[7] licence: a definitive denial restricts, it does not lock the owner out\n")
fired = {}
EC.SBOS_ENTITLEMENT({ sku = "SBOS_PIN_LOCK", status = "NOT_ENTITLED", registered = "true", enforcement = "enforce" })
check("restricted event fired and status says owner codes only", firedCount(4) == 1 and prop("Gate Status"):find("owner codes only") ~= nil, prop("Gate Status"))
status = http("POST", "/unlock?k=" .. TOKEN, { action = 1, pin = STAFF_PIN })
check("non-owner codes refused", status == 401 and vars["LAST_DENIAL_REASON"] == "licence")
status = http("POST", "/unlock?k=" .. TOKEN, { action = 1, pin = OWNER_PIN })
check("the owner code still opens the gate", status == 200)
status, doc = http("POST", "/admin/login?k=" .. TOKEN, { pin = OWNER_PIN })
check("owner can still sign in to manage", status == 200 and doc.ok == true)
SESSION = doc.session
status, doc = http("POST", "/admin/save?k=" .. TOKEN, { session = SESSION, name = "New", role = "guest", pin = VENDOR_PIN, actions = { 1 } })
check("no new access can be created while restricted", status == 422 and doc.error:find("licence") ~= nil, JSON:encode(doc))
ExecuteCommand("ADD_TEMPORARY_CODE", { NAME = "Late", PIN = VENDOR_PIN, ACTIONS = "1" })
check("temporary codes refused too", prop("Last Refusal"):find("licence") ~= nil)
ExecuteCommand("DISABLE_CODE", { NAME = "Marta" })
check("removing access still works", TestCondition("CODE_ACTIVE", { VALUE = "Marta", LOGIC = "EQUAL" }) == false)
EC.SBOS_ENTITLEMENT({ sku = "SBOS_PIN_LOCK", status = "CLOUD_VALIDATION_REQUIRED", registered = "true", enforcement = "enforce" })
check("an uncertain answer fails open: restored", firedCount(5) == 1 and prop("Gate Status") == "active")
ExecuteCommand("ENABLE_CODE", { NAME = "Marta" })

io.write("[8] SECRECY: no PIN, sequence or digest in anything the driver said\n")
local secrets = { OWNER_PIN, STAFF_PIN, VENDOR_PIN, COURIER_PIN, WRONG_A, WRONG_B, SEQUENCE, "1332", "9998" }
local state = persisted["pl_state_v2"]
check("state was persisted", type(state) == "table" and #state.codes >= 3)
local digests = {}
for _, c in ipairs(state.codes) do
  for _, field in ipairs({ "pin", "seq" }) do
    if c[field] then
      digests[#digests + 1] = c[field].hash
      digests[#digests + 1] = c[field].salt
    end
  end
end
check("digests and salts exist to look for", #digests >= 6)

local both = {}
for _, s in ipairs(secrets) do
  both[#both + 1] = s
end
for _, d in ipairs(digests) do
  both[#both + 1] = d
end

local function scan(label, text, needles)
  local hits = {}
  for _, needle in ipairs(needles) do
    if text:find(needle, 1, true) then
      hits[#hits + 1] = needle:sub(1, 3) .. "..."
    end
  end
  check(label, #hits == 0, table.concat(hits, ","))
end

local logText = table.concat(captured, "\n")
check("logging really was captured (Trace, handler debug on)", #captured > 40 and logText:find("granted: code Marta", 1, true) ~= nil)
check("handler debug printed ordinary commands", logText:find("ExecuteCommand: DISABLE_CODE", 1, true) ~= nil)
check("but not the PIN-bearing ones", logText:find("ExecuteCommand: ADD_TEMPORARY_CODE", 1, true) == nil and logText:find("ExecuteCommand: KEYPAD_PRESS", 1, true) == nil)
scan("no PIN or sequence in any log or print line", logText, secrets)
scan("no stored digest or salt in any log or print line", logText, digests)

local propText = {}
for k, v in pairs(props) do
  propText[#propText + 1] = k .. "=" .. tostring(v)
end
local propBlob = table.concat(propText, "\n")
scan("no PIN or sequence in any property", propBlob, secrets)
scan("no digest in any property", propBlob, digests)

local varText = {}
for k, v in pairs(vars) do
  varText[#varText + 1] = k .. "=" .. tostring(v)
end
scan("no PIN, sequence or digest in any variable", table.concat(varText, "\n"), both)

local sentText = {}
for _, s in ipairs(sent) do
  sentText[#sentText + 1] = s.command .. JSON:encode(s.params or {})
end
local allSent = table.concat(sentText, "\n")
check("commands were sent (recorder markers among them)", sentCount("RECORD_EVENT", RECORDER_ID) > 5)
scan("no PIN, sequence or digest in any command to another device (recorder, lock)", allSent, both)

local replies = {}
for _, s in ipairs(serverSent) do
  replies[#replies + 1] = s.data
end
local replyBlob = table.concat(replies, "\n")
scan("no PIN or sequence echoed in any relay reply", replyBlob, secrets)
scan("no digest or salt in any relay reply", replyBlob, digests)

local persistedBlob = JSON:encode(persisted)
scan("no plaintext PIN or sequence in the persisted store", persistedBlob, secrets)
check("the persisted store is written as encrypted state under one key", persisted["pl_state_v2"] ~= nil)

print = realPrint
print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
