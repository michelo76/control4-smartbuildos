-- Daypart Scheduler DRIVER under the shim with a scripted Agent, room and
-- Flight Recorder: licence registration, edits through the relay (PIN gate,
-- allowed sources, overlaps), block start/end commands and events, the volume
-- ramp (never above target, never from a room's last level), restart mid-block
-- and mid-ramp, pause/resume/skip/run-now, clock changes, licence halt, the
-- dealer narrowing a zone after the fact, and the programming surface.
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
local E = require("daypart.engine")

-- ── a wall clock and timers ─────────────────────────────────────────────────
local function wall(date, hhmm)
  local y, m, d = date:match("^(%d+)-(%d+)-(%d+)$")
  local h, mi = hhmm:match("^(%d+):(%d+)$")
  return E.daysFromCivil(tonumber(y), tonumber(m), tonumber(d)) * 86400 + tonumber(h) * 3600 + tonumber(mi) * 60
end
local MON, TUE = "2026-11-09", "2026-11-10"
local clock = { now = 0, timers = {}, base = wall(MON, "06:58") }
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
local function toWall(date, hhmm)
  advance(math.max(0, (wall(date, hhmm) - clock.base) * 1000 - clock.now))
end
os.time = function(t)
  if t then
    return clock.base + math.floor(clock.now / 1000)
  end
  return clock.base + math.floor(clock.now / 1000)
end
DAYPART_NOW = function()
  return clock.base + clock.now / 1000
end
DAYPART_LOCALTIME = function(epoch)
  local days = math.floor(epoch / 86400)
  local rem = epoch - days * 86400
  local y, m, d = E.civilFromDays(days)
  return {
    year = y,
    month = m,
    day = d,
    hour = math.floor(rem / 3600),
    min = math.floor(rem % 3600 / 60),
    sec = rem % 60,
  }
end
package.preload["drivers-common-public.global.url"] = function()
  return true
end
package.preload["cloud-client-byte"] = function()
  return true
end

-- ── persist (in memory, survives a driver reload) ───────────────────────────
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
local AGENT_ID, RECORDER_ID, SELF_ID = 50, 60, 12345
local ROOM, PLAYLIST, RADIO, TV = 100, 200, 201, 300
local sent, fired, vars, props, lists = {}, {}, {}, {}, {}
local roomVars = { POWER_STATE = "0", CURRENT_VOLUME = "65" }
local withRecorder = true
C4.GetDevices = function()
  return {
    [AGENT_ID] = { deviceName = "SmartBuildOS Agent", driverFileName = "smartbuildos.c4z" },
    [SELF_ID] = { deviceName = "Daypart", driverFileName = "smartbuildos-daypart.c4z" },
    [ROOM] = { deviceName = "Main Dining", driverFileName = "roomdevice.c4i", roomId = ROOM, roomName = "Main Dining" },
    [PLAYLIST] = {
      deviceName = "Digital Music",
      driverFileName = "streamer.c4z",
      roomId = ROOM,
      roomName = "Main Dining",
    },
    [RADIO] = { deviceName = "Radio, FM", driverFileName = "tuner.c4z", roomId = ROOM, roomName = "Main Dining" },
    [TV] = { deviceName = "Bar TV", driverFileName = "tv.c4z", roomId = ROOM, roomName = "Main Dining" },
  }
end
C4.GetDevicesByC4iName = function(_, file)
  if file == "smartbuildos.c4z" then
    return { [AGENT_ID] = {} }
  elseif file == "smartbuildos-flight-recorder.c4z" and withRecorder then
    return { [RECORDER_ID] = {} }
  end
  return {}
end
C4.GetDeviceVariables = function(_, id)
  if id == ROOM then
    local out, i = {}, 0
    for k, v in pairs(roomVars) do
      i = i + 1
      out[i] = { name = k, value = v }
    end
    return out
  end
  return {}
end
C4.GetDeviceID = function()
  return SELF_ID
end
C4.GetDriverConfigInfo = function(_, key)
  if key == "minimum_os_version" then
    return "3.3.2"
  elseif key == "model" then
    return "Daypart Scheduler"
  end
  return "20261112.000000"
end
C4.SendToDevice = function(_, device, command, params)
  sent[#sent + 1] = { device = device, command = command, params = params }
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
C4.UpdatePropertyList = function(_, name, csv, current)
  lists[name] = { csv = csv, current = current }
end
C4.GetVersionInfo = function()
  return { version = "4.2.0.0" }
end
local urlPublished = nil
C4.SendToProxy = function(_, _, command, params)
  if command == "URL_CHANGED" then
    urlPublished = params.url
  end
end
local servers = {}
C4.CreateServer = function(_, port)
  servers[port] = true
end
C4.DestroyServer = function(_, port)
  servers[port] = nil
end
local replies = {}
C4.ServerSend = function(_, handle, data)
  replies[handle] = data
end
C4.ServerCloseClient = function() end

Properties = {}
do
  local f = assert(io.open("drivers/smartbuildos-daypart/driver.xml"))
  local xml = f:read("*a")
  f:close()
  for block in xml:gmatch("<property>(.-)</property>") do
    local name = block:match("<name>(.-)</name>")
    local default = block:match("<default>(.-)</default>") or ""
    Properties[name] = default
  end
end
Properties["App Relay Address"] = "192.0.2.10" -- a documentation address
Properties["Zone 1 Name"] = "Dining"
Properties["Zone 1 Room"] = "Main Dining · 100"
Properties["Zone 1 Source 1"] = "Digital Music (Main Dining) · 200"
Properties["Zone 1 Source 2"] = "Radio FM (Main Dining) · 201"
Properties["Zone 1 Display 1"] = "Bar TV (Main Dining) · 300"
Properties["Zone 1 Min Volume"] = "10"
Properties["Zone 1 Max Volume"] = "50"
Properties["Volume Ramp Seconds"] = "20"
Properties["Fade Out Seconds"] = "10"

local function loadDriver()
  dofile("drivers/smartbuildos-daypart/driver.lua")
end
loadDriver()

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
local function commands(device, command)
  local out = {}
  for _, s in ipairs(sent) do
    if s.device == device and (command == nil or s.command == command) then
      out[#out + 1] = s
    end
  end
  return out
end
local function levels()
  local out = {}
  for _, s in ipairs(commands(ROOM, "SET_VOLUME_LEVEL")) do
    out[#out + 1] = s.params.LEVEL
  end
  return out
end
local function recorded(text)
  for _, s in ipairs(commands(RECORDER_ID, "RECORD_EVENT")) do
    if s.params.NAME:find(text, 1, true) then
      return s.params
    end
  end
  return nil
end
local function reset()
  sent, fired = {}, {}
end

-- ── the page's door: raw HTTP into OnServerDataIn ───────────────────────────
local token
local nextHandle = 0
local function http(method, path, body, noToken)
  nextHandle = nextHandle + 1
  local payload = body and JSON:encode(body) or ""
  local sep = path:find("?", 1, true) and "&" or "?"
  local target = noToken and path or (path .. sep .. "k=" .. token)
  local raw = string.format("%s %s HTTP/1.1\r\nContent-Length: %d\r\n\r\n%s", method, target, #payload, payload)
  OnServerDataIn(nextHandle, raw, nil, nil, "daypart-ui-relay")
  local reply = replies[nextHandle] or ""
  local status = tonumber(reply:match("^HTTP/1%.1 (%d+)"))
  local text = reply:match("\r\n\r\n(.*)$") or ""
  local ok, doc = pcall(function()
    return JSON:decode(text)
  end)
  return status, ok and doc or nil, text
end
local PIN = "2468"
local function edit(doc, pin)
  doc.pin = pin or PIN
  return http("POST", "/edit", doc)
end
local function morning(extra)
  local b = {
    name = "Morning",
    days = { 1, 2, 3, 4, 5 },
    from = "07:00",
    to = "11:00",
    source = PLAYLIST,
    volume = 30,
    displays = "on",
  }
  for k, v in pairs(extra or {}) do
    b[k] = v
  end
  return b
end

print("[1] start: online, licence registered under the Daypart SKU, zones read from properties")
OnDriverInit()
OnDriverLateInit("DIT_ADDING")
local reg
for _, s in ipairs(sent) do
  if s.command == "SBOS_REGISTER_DRIVER" then
    reg = s
  end
end
check("online", props["Driver Status"] == "Online")
check(
  "licence registered with the Agent under SBOS_DAYPART",
  reg ~= nil and reg.device == AGENT_ID and reg.params.sku == "SBOS_DAYPART"
)
check("relay listening", servers[47851] == true)
token = urlPublished and urlPublished:match("k=(%w+)")
check("a tile URL with a token was published", token ~= nil and #token >= 16, urlPublished)
check(
  "schedule running with one zone",
  prop("Schedule Status") == "running" and prop("Zones"):find("Dining") ~= nil,
  prop("Schedule Status")
)
EC.SBOS_ENTITLEMENT({
  sku = "SBOS_DAYPART",
  status = "AUTHORIZED_SUBSCRIPTION",
  license_type = "subscription",
  registered = "true",
  subscription_tier = "Professional",
  company_name = "Example AV",
})
check("licence painted", prop("License Status"):find("Licensed") ~= nil and prop("Subscription Tier") == "Professional")
check("SCHEDULE_PAUSED false", TC.SCHEDULE_PAUSED() == false)
local list = lists["Zone 1 Source 1"]
check(
  "source list filled as Name (Room) · id, commas stripped",
  list ~= nil
    and list.csv:find("Radio FM (Main Dining) · 201", 1, true) ~= nil
    and list.csv:find("Digital Music (Main Dining) · 200", 1, true) ~= nil,
  list and list.csv
)
check(
  "the Agent and this driver are not offered",
  list.csv:find("Agent", 1, true) == nil and list.csv:find("Daypart", 1, true) == nil
)
check("room list names the room", lists["Zone 1 Room"].csv:find("Main Dining · 100", 1, true) ~= nil)
check("a saved pick stays in its list", list.current == "Digital Music (Main Dining) · 200")

print("[2] the page: anyone can read, changes need the Manager PIN")
local status, doc = http("GET", "/ping", nil, true)
check("ping needs no token", status == 200 and doc.service == "daypart")
status = http("GET", "/state", nil, true)
check("state needs the token", status == 403)
status, doc = http("GET", "/state")
check(
  "state readable",
  status == 200
    and doc.zones[1].name == "Dining"
    and doc.zones[1].min == 10
    and doc.zones[1].max == 50
    and doc.can_edit == false
)
check("the page is told why it is read-only", doc.edit_reason == "pin_not_configured")
status, doc = edit({ op = "add_block", zone = 1, scope = "week", block = morning() })
check("no Manager PIN: edit refused as read-only", status == 403 and doc.reason == "pin_not_configured")
Properties["Manager PIN"] = PIN
OnPropertyChanged("Manager PIN")
status, doc = edit({ op = "add_block", zone = 1, scope = "week", block = morning() }, "0000")
check("wrong PIN refused", status == 403 and doc.reason == "wrong_pin")
status, doc = edit({ op = "add_block", zone = 1, scope = "week", block = morning() })
check("right PIN saves the block", status == 200 and doc.ok == true, doc and doc.error)
status, doc = http("GET", "/state")
check(
  "state shows the block and can_edit",
  doc.can_edit == true and doc.zones[1].week[1].name == "Morning" and doc.zones[1].week[1].source == PLAYLIST
)
status, doc = edit({
  op = "add_block",
  zone = 1,
  scope = "week",
  block = morning({ name = "Clash", from = "10:00", to = "12:00" }),
})
check(
  "overlap refused with the clear message",
  status == 422 and doc.error:find('Overlaps "Morning"') and doc.error:find("07:00%-11:00"),
  doc and doc.error
)
status, doc = edit({
  op = "add_block",
  zone = 1,
  scope = "week",
  block = morning({ name = "Sneaky", from = "12:00", to = "13:00", source = 999 }),
})
check(
  "a source the dealer did not allow is refused",
  status == 422 and doc.error:find("not allowed"),
  doc and doc.error
)
status, doc = edit({
  op = "add_block",
  zone = 1,
  scope = "week",
  block = morning({ name = "Loud", from = "12:00", to = "13:00", volume = 95, displays = "keep" }),
})
check(
  "volume clamped to the zone's range, with a warning",
  status == 200 and doc.warnings[1]:find("set to 50"),
  doc and doc.error
)
status, doc = http("GET", "/state")
local loud
for _, b in ipairs(doc.zones[1].week) do
  if b.name == "Loud" then
    loud = b
  end
end
check("and saved at 50", loud ~= nil and loud.volume == 50)
status, doc = edit({ op = "frobnicate" })
check("unknown operation refused", status == 422)
status, doc = http("POST", "/edit", "not json")
check("a body that is not a JSON object is refused", status == 400)
for _ = 1, 5 do
  edit({ op = "pause" }, "9999")
end
status, doc = edit({ op = "pause" })
check(
  "five wrong PINs lock edits, even for the right PIN",
  status == 403 and doc.reason == "locked",
  doc and doc.reason
)
EC.RESET_PIN_LOCK()
check("Reset PIN Lock unlocks", select(1, edit({ op = "set_holidays", dates = {} })) == 200)
check(
  "an edit is on the common history with what changed",
  recorded("schedule edited") ~= nil and recorded("schedule edited").DETAIL:find("added") ~= nil,
  recorded("schedule edited") and recorded("schedule edited").DETAIL
)
check(
  "the history marker carries no PIN",
  (function()
    for _, s in ipairs(commands(RECORDER_ID)) do
      if tostring(s.params.DETAIL):find(PIN, 1, true) then
        return false
      end
    end
    return true
  end)()
)
check("Schedule Edited event fired", firedCount(5) >= 2)

print("[3] 07:00: source selected, volume ramped (never from the room's last level), display on")
reset()
roomVars = { POWER_STATE = "0", CURRENT_VOLUME = "65" } -- the room was off, last played loud
toWall(MON, "06:59")
check("nothing before the block", #commands(ROOM) == 0 and firedCount(1) == 0)
toWall(MON, "07:00")
advance(10000) -- one tick
local sel = commands(ROOM, "SELECT_AUDIO_DEVICE")
check("source selected on the room", #sel == 1 and sel[1].params.deviceid == PLAYLIST)
check("display switched on", #commands(TV, "ON") == 1)
local lv = levels()
check("first level is the bottom of the range, not 65", lv[1] == 10, table.concat(lv, ","))
advance(30000)
lv = levels()
check("ramp ends on the block level", lv[#lv] == 30, table.concat(lv, ","))
local maxSeen = 0
for _, l in ipairs(lv) do
  maxSeen = math.max(maxSeen, l)
end
check("the volume never exceeded the target", maxSeen == 30, maxSeen)
check(
  "Block Started fired once with zone and block variables",
  firedCount(1) == 1 and vars["EVENT_ZONE"] == "Dining" and vars["EVENT_BLOCK"] == "Morning"
)
check(
  "current and next block variables",
  vars["CURRENT_BLOCK_1"] == "Morning" and vars["NEXT_BLOCK_1"]:find("Dining: Loud at 12:00") ~= nil,
  vars["NEXT_BLOCK_1"]
)
check("overall next block variable", vars["NEXT_BLOCK"]:find("Loud") ~= nil)
check(
  "zone has an active block",
  TC.ZONE_ACTIVE(nil, { VALUE = "Dining", LOGIC = "EQUAL" }) == true
    and TC.ZONE_ACTIVE(nil, { VALUE = "dining", LOGIC = "NOT_EQUAL" }) == false
)
check("unknown zone is not active", TC.ZONE_ACTIVE(nil, { VALUE = "Patio", LOGIC = "EQUAL" }) == false)
check(
  "block start in the history",
  recorded("block started") ~= nil and recorded("block started").DETAIL == "Dining / Morning"
)
local startedCommands = #sent
advance(120000)
check("nothing is re-sent while the block runs", #sent == startedCommands)

print("[4] restart mid-block: the right block carries on, nothing is blasted or re-announced")
reset()
loadDriver() -- a fresh Lua state, the persisted schedule survives
clock.timers = {}
OnDriverInit()
OnDriverLateInit("DIT_ADDING")
advance(15000)
check(
  "after a restart the running block is still Morning",
  vars["CURRENT_BLOCK_1"] == "Morning" and TC.ZONE_ACTIVE(nil, { VALUE = "Dining", LOGIC = "EQUAL" }) == true
)
check("no new source command", #commands(ROOM, "SELECT_AUDIO_DEVICE") == 0)
check("no volume command at all", #commands(ROOM, "SET_VOLUME_LEVEL") == 0)
check("no second Block Started", firedCount(1) == 0)
token = urlPublished and urlPublished:match("k=(%w+)")
check("the tile URL token survives a restart", token ~= nil)

print("[5] restart mid-ramp: the ramp resumes from where the room is")
-- Move to Tuesday 07:00 -> new instance, then restart 5 s into its ramp.
reset()
toWall(TUE, "06:59")
advance(10000)
reset()
roomVars = { POWER_STATE = "1", CURRENT_VOLUME = "20" }
toWall(TUE, "07:00")
advance(10000)
check("Tuesday's block started (new calendar day, new instance)", firedCount(1) == 1)
reset()
loadDriver()
clock.timers = {}
roomVars = { POWER_STATE = "1", CURRENT_VOLUME = "22" }
OnDriverInit()
OnDriverLateInit("DIT_ADDING")
advance(25000)
lv = levels()
check(
  "the interrupted ramp resumes towards the target",
  #lv >= 1 and lv[#lv] == 30 and lv[1] >= 22,
  table.concat(lv, ",")
)
check("without selecting the source again", #commands(ROOM, "SELECT_AUDIO_DEVICE") == 0)
check("or announcing the block again", firedCount(1) == 0)
advance(40000)

print("[6] 11:00: Block Ended; end behaviour decides what the room does")
reset()
toWall(TUE, "10:59")
advance(10000)
toWall(TUE, "11:00")
advance(10000)
check("Block Ended fired with the block name", firedCount(2) == 1 and vars["EVENT_BLOCK"] == "Morning")
check("Hold: nothing sent to the room", #commands(ROOM) == 0)
check("current block variable cleared", vars["CURRENT_BLOCK_1"] == "")
check("block end in the history", recorded("block ended") ~= nil)
-- Fade Out for the next gap (Loud 12:00-13:00)
Properties["End Behaviour"] = "Fade Out"
OnPropertyChanged("End Behaviour")
toWall(TUE, "12:00")
advance(10000)
roomVars = { POWER_STATE = "1", CURRENT_VOLUME = "50" }
reset()
toWall(TUE, "13:00")
advance(10000)
advance(20000)
lv = levels()
check("Fade Out lowers the volume to nothing", #lv >= 1 and lv[#lv] == 0, table.concat(lv, ","))
check("then turns the room off", #commands(ROOM, "ROOM_OFF") == 1)
Properties["End Behaviour"] = "Off"
OnPropertyChanged("End Behaviour")
toWall("2026-11-11", "07:00")
advance(40000)
toWall("2026-11-11", "10:59")
reset()
toWall("2026-11-11", "11:00")
advance(10000)
check("Off turns the room off at once", #commands(ROOM, "ROOM_OFF") == 1 and #levels() == 0)
Properties["End Behaviour"] = "Hold"
OnPropertyChanged("End Behaviour")

print("[7] pause, resume, skip next, run block now")
toWall("2026-11-12", "06:59")
advance(10000)
reset()
EC.PAUSE_SCHEDULE()
check(
  "paused: status, conditional, event",
  prop("Schedule Status") == "paused" and TC.SCHEDULE_PAUSED() == true and firedCount(3) == 1
)
toWall("2026-11-12", "07:30")
advance(10000)
check("a paused schedule sends nothing at block start", #commands(ROOM) == 0 and firedCount(1) == 0)
reset()
EC.RESUME_SCHEDULE()
advance(5000)
check(
  "resume picks up the block that should be running",
  firedCount(4) == 1
    and firedCount(1) == 1
    and #commands(ROOM, "SELECT_AUDIO_DEVICE") == 1
    and vars["CURRENT_BLOCK_1"] == "Morning"
)
advance(40000)
reset()
-- Skip: Friday 13 Nov is the next Morning after Thursday's? Today (Thu) Loud 12:00 is next.
EC.SKIP_NEXT_BLOCK({ ZONE = "Dining" })
check(
  "skip next block names a real block in the history",
  recorded("block skipped") ~= nil and recorded("block skipped").DETAIL:find("Loud") ~= nil,
  recorded("block skipped") and recorded("block skipped").DETAIL
)
toWall("2026-11-12", "12:05")
advance(10000)
check("the skipped block does not start", firedCount(1) == 0)
EC.SKIP_NEXT_BLOCK({ ZONE = "Patio" })
check(
  "unknown zone named in Last Refusal",
  prop("Last Refusal"):find("unknown zone Patio") ~= nil,
  prop("Last Refusal")
)
reset()
roomVars = { POWER_STATE = "1", CURRENT_VOLUME = "10" }
EC.RUN_BLOCK_NOW({ ZONE = "dining", BLOCK = "morning" })
advance(30000)
check(
  "Run Block Now starts the named block",
  firedCount(1) == 1 and #commands(ROOM, "SELECT_AUDIO_DEVICE") == 1 and vars["EVENT_BLOCK"] == "Morning"
)
reset()
advance(120000)
check(
  "and it holds (the schedule does not undo it a tick later)",
  #commands(ROOM) == 0 and vars["CURRENT_BLOCK_1"] == "Morning"
)
EC.RUN_BLOCK_NOW({ ZONE = "Dining", BLOCK = "Nope" })
check(
  "unknown block named in Last Refusal",
  prop("Last Refusal"):find("No block with that name") ~= nil,
  prop("Last Refusal")
)

print("[8] the clock jumps")
reset()
toWall("2026-11-13", "06:00")
advance(10000)
check("ordinary ticks are not a clock change", recorded("clock change") == nil)
clock.base = clock.base + 3 * 3600 -- someone sets the controller clock three hours forward
advance(10000)
check("a big jump is noticed and recorded", recorded("clock change") ~= nil)
check(
  "after a jump into a block it starts, with a late-start note",
  firedCount(1) == 1 and recorded("block started").DETAIL:find("late start") ~= nil,
  recorded("block started") and recorded("block started").DETAIL
)
roomVars = { POWER_STATE = "1", CURRENT_VOLUME = "30" }
advance(40000)

print("[9] the dealer narrows the zone after blocks were saved")
reset()
Properties["Zone 1 Max Volume"] = "25"
OnPropertyChanged("Zone 1 Max Volume")
toWall("2026-11-13", "12:30") -- inside Loud (volume saved at 50)
advance(10000)
reset()
Properties["Zone 1 Source 1"] = "-"
OnPropertyChanged("Zone 1 Source 1")
status, doc = http("GET", "/state")
check(
  "the page now offers only the remaining source",
  #doc.zones[1].sources == 1 and doc.zones[1].sources[1].id == RADIO and doc.zones[1].max == 25
)
Properties["Zone 1 Source 1"] = "Digital Music (Main Dining) · 200"
OnPropertyChanged("Zone 1 Source 1")
toWall("2026-11-16", "06:59")
advance(10000)
reset()
Properties["Zone 1 Source 1"] = "-"
OnPropertyChanged("Zone 1 Source 1")
roomVars = { POWER_STATE = "1", CURRENT_VOLUME = "20" }
toWall("2026-11-16", "07:00")
advance(10000)
check(
  "a source the dealer removed is no longer selected",
  #commands(ROOM, "SELECT_AUDIO_DEVICE") == 0 and firedCount(1) == 1
)
advance(40000)
lv = levels()
check("volume is clamped to the new maximum at run time", #lv >= 1 and lv[#lv] == 25, table.concat(lv, ","))
Properties["Zone 1 Source 1"] = "Digital Music (Main Dining) · 200"
OnPropertyChanged("Zone 1 Source 1")

print("[10] licence: a definitive denial halts block actions; the page stays readable; nothing is deleted")
toWall("2026-11-16", "11:30")
advance(10000)
reset()
EC.SBOS_ENTITLEMENT({
  sku = "SBOS_DAYPART",
  status = "CLOUD_VALIDATION_REQUIRED",
  registered = "true",
  enforcement = "enforce",
})
check("uncertain status changes nothing", prop("Schedule Status") ~= "halted (licence)" and firedCount(6) == 0)
EC.SBOS_ENTITLEMENT({ sku = "SBOS_DAYPART", status = "NOT_ENTITLED", registered = "true", enforcement = "enforce" })
check(
  "definitive denial + enforce halts the schedule",
  prop("Schedule Status") == "halted (licence)" and firedCount(6) == 1 and TC.SCHEDULE_PAUSED() == true
)
toWall("2026-11-16", "12:00")
advance(10000)
check("no block actions while halted", #commands(ROOM) == 0 and firedCount(1) == 0)
status, doc = http("GET", "/state")
check(
  "the page still reads the whole schedule",
  status == 200 and doc.halted == true and #doc.zones[1].week == 2 and doc.can_edit == false
)
status, doc = edit({
  op = "add_block",
  zone = 1,
  scope = "week",
  block = morning({ name = "Extra", from = "15:00", to = "16:00" }),
})
check("edits are refused while halted", status == 403 and doc.reason == "unlicensed")
status, doc = http("GET", "/state")
check("nothing was deleted", #doc.zones[1].week == 2)
EC.SBOS_ENTITLEMENT({ sku = "SBOS_DAYPART", status = "NOT_ENTITLED", registered = "true", enforcement = "observe" })
check("observe mode restores the schedule", prop("Schedule Status") == "running" and firedCount(7) == 1)

print("[11] holidays and today-only through the page")
status, doc = edit({
  op = "add_block",
  zone = 1,
  scope = "holiday",
  block = { name = "Holiday brunch", from = "10:00", to = "15:00", source = RADIO, volume = 25 },
})
check("holiday template block saved", status == 200, doc and doc.error)
status, doc = edit({ op = "set_holidays", dates = { "2026-11-17", "2026-13-99" } })
check(
  "a bad holiday date is refused with a message",
  status == 422 and doc.error:find("not a valid date"),
  doc and doc.error
)
status, doc = edit({ op = "set_holidays", dates = { "2026-11-17" } })
check("holiday date saved", status == 200)
status, doc = http("GET", "/state")
check("page document carries holidays", doc.holidays[1] == "2026-11-17")
reset()
toWall("2026-11-17", "07:30")
advance(10000)
check("on a holiday the weekday block does not run", firedCount(1) == 0)
toWall("2026-11-17", "10:30")
advance(10000)
check(
  "the holiday template runs instead",
  firedCount(1) == 1
    and vars["EVENT_BLOCK"] == "Holiday brunch"
    and #commands(ROOM, "SELECT_AUDIO_DEVICE") == 1
    and commands(ROOM, "SELECT_AUDIO_DEVICE")[1].params.deviceid == RADIO
)
reset()
toWall("2026-11-18", "09:00")
advance(10000)
status, doc = edit({
  op = "add_block",
  zone = 1,
  scope = "today",
  block = { name = "Private party", from = "09:00", to = "10:00", source = PLAYLIST, volume = 40 },
})
check(
  "today-only block starts at once when it covers now",
  status == 200 and vars["CURRENT_BLOCK_1"] == "Private party" and firedCount(1) >= 1,
  doc and doc.error
)
status, doc = edit({ op = "clear_today", zone = 1 })
check("clearing the override ends it", status == 200 and vars["CURRENT_BLOCK_1"] ~= "Private party")

print("[12] no Flight Recorder in the project: the schedule works and says nothing")
withRecorder = false
local ranCleanly = pcall(function()
  loadDriver()
  clock.timers = {}
  gRecorderId = nil
  OnDriverInit()
  OnDriverLateInit("DIT_ADDING")
  toWall("2026-11-19", "07:00")
  advance(20000)
end)
check("runs without a recorder", ranCleanly and vars["CURRENT_BLOCK_1"] == "Morning")

print("[13] Print Schedule, reload")
local printed = pcall(EC.PRINT_SCHEDULE)
check("Print Schedule does not throw", printed)
reset()
EC.RELOAD()
check("Reload keeps the schedule", vars["CURRENT_BLOCK_1"] == "Morning")
check("Reload does not restart the block", firedCount(1) == 0)

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
