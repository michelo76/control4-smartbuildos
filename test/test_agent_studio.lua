-- Tests for src/sbos/agentstudio.lua — the pure half of Studio release G1
-- (docs/studio-g1/AGENT-CONTRACT-G1.md): the device_poll digest, JSON null in
-- a device row, rooms, the driver census, the controller block and
-- last_errors. The driver wiring is tested in test_smartbuildos_connector.lua
-- and end to end under the Director emulator (test/emulator/agent_studio_g1.lua).
--
--   LUA_PATH="$PWD/test/?.lua;$PWD/src/?.lua;$PWD/src/?/init.lua;$PWD/vendor/?.lua;$PWD/vendor/?/init.lua;;" \
--     luajit -e "require('c4_shim')" test/test_agent_studio.lua

local S = require("sbos.agentstudio")
local JSONlib = require("JSON")
-- Director supplies this global; JSON.lua formats numbers with it.
tostring_return_period = tostring_return_period or tostring

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

--- SHA-256 by an implementation that is not this repo's: the system's own
--- shasum / sha256sum. nil when neither exists (the digest is then still
--- checked against the pinned vector under the emulator's C4:Hash).
local function systemSha256(input)
  local path = os.tmpname()
  local f = io.open(path, "wb")
  if not f then
    return nil
  end
  f:write(input)
  f:close()
  for _, cmd in ipairs({ "shasum -a 256 ", "sha256sum " }) do
    local p = io.popen(cmd .. "'" .. path .. "' 2>/dev/null")
    if p then
      local out = p:read("*a") or ""
      p:close()
      local hex = out:match("^(%x+)")
      if hex and #hex == 64 then
        os.remove(path)
        return hex:lower()
      end
    end
  end
  os.remove(path)
  return nil
end

-- ── The pinned vector (docs/studio-g1/DIGEST-VECTORS.md) ────────────────────
local VECTOR_ROWS = {
  ["c4:1"] = { key = "c4:1", online = true, addressable = true },
  ["c4:10"] = { key = "c4:10", online = false, addressable = true },
  ["c4:2"] = { key = "c4:2", online = false, addressable = false }, -- NOT_SET binding
  ["c4:99"] = { key = "c4:99", online = false, addressable = false, unmonitored = true }, -- IR, no binding
  ["discovered:192.168.1.60"] = { key = "discovered:192.168.1.60", online = true },
  ["ping:192.168.1.99"] = { key = "ping:192.168.1.99", online = false },
  ["ping:nas.local"] = { key = "ping:nas.local", online = true },
}
local VECTOR_INPUT = table.concat({
  "c4:1:1",
  "c4:10:0",
  "c4:2:u",
  "c4:99:u",
  "discovered:192.168.1.60:1",
  "ping:192.168.1.99:0",
  "ping:nas.local:1",
}, "\n")
local VECTOR_HEX = "0ef1484482b04ba81a3cdf97804ac0d95aca5d66834ea78ae1f5a9aadb0a911d"
local EMPTY_HEX = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
-- Sorting by LINE instead of by KEY puts "c4:10:0" before "c4:1:1"; this is
-- the digest an implementation with that bug produces.
local WRONG_ORDER_HEX = "7cc8fa04c54bd3012d53d3876c0b60fceeb66ca518c2403fed5cc5ae7ea94fba"

print("\n[1] device_poll digest: byte-exact input")
local input, n, offline, unknown = S.digestInput(VECTOR_ROWS)
check("input is byte-exact (sorted by key, \\n-joined, no trailing newline)", input == VECTOR_INPUT, input)
check(
  "counts: 7 devices, 2 offline, 2 unknown",
  n == 7 and offline == 2 and unknown == 2,
  n .. "/" .. offline .. "/" .. unknown
)
check("c4:1 sorts before c4:10 (key order, not line order)", input:find("c4:1:1\nc4:10:0", 1, true) == 1)
check("removed rows are not lines", (S.digestInput({ { key = "c4:5", removed = true } })) == "")
check("zero devices is the empty string", (S.digestInput({})) == "")
check("wire NULL reads as unknown", S.pollState({ key = "x", online = S.NULL }) == "u")
check("byteLess is bytewise", S.byteLess("Z", "a") and S.byteLess("c4:1", "c4:10") and not S.byteLess("c4:2", "c4:10"))

local sys = systemSha256(VECTOR_INPUT)
if sys ~= nil then
  check("the pinned hex is SHA-256 of the input (system shasum)", sys == VECTOR_HEX, sys)
  check("the empty-string hex (system shasum)", systemSha256("") == EMPTY_HEX)
  check(
    "line-order digest differs (system shasum)",
    systemSha256((VECTOR_INPUT:gsub("c4:1:1\nc4:10:0", "c4:10:0\nc4:1:1"))) == WRONG_ORDER_HEX
  )
else
  print("  skip system shasum not available; the emulator scenario checks the hex")
end

print("\n[2] device_poll block")
local seen
local block = S.devicePollBlock(VECTOR_ROWS, 1795014245, 300, function(s)
  seen = s
  return VECTOR_HEX:upper()
end)
check("hash is asked for exactly the canonical input", seen == VECTOR_INPUT)
check("digest lower-cased", block.digest == VECTOR_HEX, block.digest)
check("completed_at is ISO UTC with Z", block.completed_at == "2026-11-18T15:04:05Z", block.completed_at)
check(
  "interval and counts",
  block.interval_s == 300 and block.devices == 7 and block.offline == 2 and block.unknown == 2
)
local noHash = S.devicePollBlock(VECTOR_ROWS, 0, 300, function()
  error("C4:Hash unavailable")
end)
check("no hash primitive: block without digest (never a false match)", noHash.digest == nil and noHash.devices == 7)
local badHash = S.devicePollBlock({}, 0, 300, function()
  return "not-hex"
end)
check("a malformed hash answer is not sent", badHash.digest == nil and badHash.devices == 0)
check(
  "block field names avoid the redaction vocabulary",
  (function()
    for k in pairs(block) do
      if k:find("token") or k:find("secret") or k:find("session") then
        return false
      end
    end
    return true
  end)()
)

print("\n[3] JSON null in a device row (vendored JSON.lua + installJsonNull)")
local json = JSONlib:new()
check(
  "before install a nil field is DROPPED (the problem)",
  json:encode({ online = nil, key = "c4:1" }) == '{"key":"c4:1"}'
)
S.installJsonNull(json)
S.installJsonNull(json) -- idempotent
local wire =
  S.wireRow({ key = "c4:2", online = false, addressable = false, address = "NOT_SET", connection_type = "ip" })
local encoded = json:encode(wire)
check("an unaddressed binding encodes online as a real null", encoded:find('"online":null', 1, true) ~= nil, encoded)
check("its connection_type is untouched", encoded:find('"connection_type":"ip"', 1, true) ~= nil, encoded)
check("the placeholder never leaks as text", encoded:find("sbos:json-null", 1, true) == nil, encoded)
local unbound = S.wireRow(VECTOR_ROWS["c4:99"])
local encodedUnbound = json:encode(unbound)
check(
  "an unbound device encodes connection_type AND online as null",
  encodedUnbound:find('"online":null', 1, true) and encodedUnbound:find('"connection_type":null', 1, true),
  encodedUnbound
)
check("the driver-local marker is not sent", encodedUnbound:find("unmonitored", 1, true) == nil, encodedUnbound)
check(
  "the driver's own row keeps its boolean",
  VECTOR_ROWS["c4:99"].online == false and VECTOR_ROWS["c4:99"].unmonitored
)
check(
  "a reachable row is unchanged",
  json:encode(S.wireRow({ online = true, addressable = true })) == '{"addressable":true,"online":true}'
)
check("null inside a list", json:encode({ S.NULL, 1 }) == "[null,1]")
check("explicit caller null option still wins", json:encode({ a = "x" }, nil, { null = "x" }) == '{"a":null}')
check("decode is untouched", json:decode('{"a":null}').a == nil)
local roundtrip = json:decode(json:encode({ devices = S.wireRows({ wire }) }))
check("round trip: the key is present-and-null, not absent", roundtrip.devices[1].address == "NOT_SET")

print("\n[4] unbound rows, proxies, the 2,000-row ceiling")
local project = {
  [10] = {
    deviceName = "Receiver",
    roomName = "Media",
    roomId = 12,
    driverFileName = "receiver.c4z",
    proxies = { [11] = { deviceName = "Receiver" }, [10] = {} },
  },
  [11] = { deviceName = "Receiver", roomName = "Media", roomId = 12, driverFileName = "receiver.c4i" },
  [20] = { deviceName = "IR TV", roomName = "Den", roomId = 14, driverFileName = "tv_ir.c4i" },
  [30] = { deviceName = "Kitchen", driverFileName = "roomdevice.c4i" },
}
local proxies = S.proxyIds(project)
check("a listed proxy of another device is a proxy", proxies[11] == true)
check("a device listing itself is not its own proxy", proxies[10] == nil)
check("the proxy is not reported as an unbound twin", S.unboundRow(11, project[11], proxies) == nil)
local tv = S.unboundRow(20, project[20], proxies)
check(
  "an IR device is a row: key, room, room_id, driver_file",
  tv
    and tv.key == "c4:20"
    and tv.room == "Den"
    and tv.room_id == 14
    and tv.driver_file == "tv_ir.c4i"
    and tv.source == "director"
)
check(
  "internally it reads like an unaddressed binding",
  tv.online == false and tv.addressable == false and tv.unmonitored == true
)
check("a room item is not a device", S.unboundRow(30, project[30], proxies) == nil)

local big = {}
for i = 1, 1500 do
  big["c4:" .. i] = { key = "c4:" .. i, online = true, addressable = true }
end
for i = 1501, 2600 do
  big["c4:" .. i] = { key = "c4:" .. i, online = false, addressable = false, unmonitored = true }
end
local capped, truncated = S.capRows(big)
local count, unmon = 0, 0
for _, row in pairs(capped) do
  count = count + 1
  if row.unmonitored then
    unmon = unmon + 1
  end
end
check("capped at 2,000 and flagged", count == 2000 and truncated == true, count)
check("every network-bound row survives the cap", count - unmon == 1500, count - unmon)
local same, notTruncated = S.capRows(VECTOR_ROWS)
check("under the ceiling: untouched, not flagged", same == VECTOR_ROWS and notTruncated == false)
local capped2 = S.capRows(big)
local stable = true
for k in pairs(capped) do
  if capped2[k] == nil then
    stable = false
  end
end
check("the same rows survive every time (digest stays stable)", stable)

print("\n[5] wire-state changes the poll must report")
check(
  "offline -> unknown is a wire change",
  S.wireStateChanged({ online = false, addressable = true }, { online = false, addressable = false })
)
check(
  "unknown -> unknown is not",
  not S.wireStateChanged({ online = false, addressable = false }, { online = false, addressable = false })
)
check("online -> online is not", not S.wireStateChanged({ online = true }, { online = true }))

print("\n[6] rooms from GetProjectItems(LOCATIONS)")
local LOCATIONS = '<item majorversion="4" minorversion="3"><id>1</id><name>Project</name><type>1</type>'
  .. "<itemdata><timezone>America/New_York</timezone><name>not-a-room</name></itemdata><subitems>"
  .. "<item><id>2</id><name>Home</name><type>2</type><itemdata/><subitems>"
  .. "<item><id>3</id><name>Main House</name><type>3</type><subitems>"
  .. "<item><id>4</id><name>Main Floor</name><type>4</type><subitems>"
  .. "<item><id>12</id><name>Kitchen &amp; Dining</name><type>8</type><itemdata><config_data_file>roomdevice.c4i</config_data_file></itemdata><subitems>"
  .. "<item><id>40</id><name>Kitchen Lights</name><type>6</type><itemdata><driver>light.c4z</driver></itemdata></item>"
  .. "</subitems></item>"
  .. "<item><id>13</id><name>Empty Room</name><type>8</type><subitems/></item>"
  .. "</subitems></item></subitems></item>"
  .. "<item><id>9</id><name>Garage</name><type>8</type></item>"
  .. "</subitems></item></subitems></item>"
local rooms = S.roomsFromLocations(LOCATIONS)
check(
  "every room including the empty one, sorted by id",
  #rooms == 3 and rooms[1].id == 9 and rooms[2].id == 12 and rooms[3].id == 13,
  #rooms
)
check("names are unescaped", rooms[2].name == "Kitchen & Dining", rooms[2].name)
check(
  "parent_id is the enclosing location",
  rooms[2].parent_id == 4 and rooms[1].parent_id == 2,
  tostring(rooms[1].parent_id)
)
check("floor and building by name", rooms[2].floor == "Main Floor" and rooms[2].building == "Main House")
check("no floor/building when the project has none above the room", rooms[1].floor == nil and rooms[1].building == nil)
check(
  "devices inside a room are not rooms",
  (function()
    for _, r in ipairs(rooms) do
      if r.id == 40 then
        return false
      end
    end
    return true
  end)()
)
check("itemdata <name> is never read as the item's", S.parseProjectItems(LOCATIONS)[1].name == "Project")
local manyRooms = { "<item><id>1</id><type>1</type><subitems>" }
for i = 1, 520 do
  manyRooms[#manyRooms + 1] =
    string.format("<item><id>%d</id><name>%s</name><type>8</type></item>", 1000 + i, string.rep("é", 60))
end
manyRooms[#manyRooms + 1] = "</subitems></item>"
local capRooms = S.roomsFromLocations(table.concat(manyRooms))
check("at most 500 rooms", #capRooms == 500, #capRooms)
check(
  "names at most 80 bytes, never a split UTF-8 sequence",
  #capRooms[1].name == 80 and capRooms[1].name == string.rep("é", 40),
  #capRooms[1].name
)
check(
  "unreadable XML is no rooms (the key is then omitted)",
  #S.roomsFromLocations(nil) == 0 and #S.roomsFromLocations("garbage") == 0
)

print("\n[7] driver census")
local censusProject = {
  [5] = { driverFileName = "thermostat_xyz.c4z" },
  [6] = { driverFileName = "thermostat_xyz.c4z" },
  [4] = { driverFileName = "thermostat_xyz.c4z" },
  [7] = { driverFileName = "smartbuildos.c4z" },
  [8] = { driverFileName = "light_v2.c4i" },
  [9] = { deviceName = "no file" },
  -- The Agent's self-proxy: part of smartbuildos.c4z, never a census entry.
  [70] = { driverFileName = "smartbuildos.c4i" },
}
censusProject[7].proxies = { [70] = { deviceName = "SmartBuildOS" } }
local asked = {}
local census = S.driverCensus(censusProject, function(id, field)
  asked[#asked + 1] = id .. ":" .. field
  if field == "name" then
    return ({ [4] = "XYZ Thermostat", [7] = "SmartBuildOS Agent" })[id]
  end
  if field == "version" then
    if id == 4 then
      return 112
    end
    error("GetDeviceData version unavailable")
  end
end, function(file)
  return file == "smartbuildos.c4z"
end)
check("one entry per distinct file, proxies of another device excluded", #census == 3, #census)
check("largest count first", census[1].file == "thermostat_xyz.c4z" and census[1].count == 3)
check(
  "name and version read from the lowest-id device",
  census[1].name == "XYZ Thermostat" and census[1].version == "112" and asked[1] == "4:name"
)
check("version only when it answered (PROBE)", census[2].version == nil and census[3].version == nil)
check("sbos flag", census[3].sbos == true or census[2].sbos == true)
check("sbos false otherwise", census[1].sbos == false)
local manyFiles = {}
for i = 1, 520 do
  manyFiles[i] = { driverFileName = string.format("driver_%03d_%s.c4z", i, string.rep("x", 130)) }
end
local bigCensus = S.driverCensus(manyFiles, function() end, function()
  return false
end)
check("at most 500 entries", #bigCensus == 500, #bigCensus)
check("strings at most 120", #bigCensus[1].file == 120, #bigCensus[1].file)
check("no name key when unreadable", bigCensus[1].name == nil)

print("\n[8] controller block")
local function reader(value, probe)
  return {
    probe = probe,
    read = function()
      if value == "error" then
        error("method absent")
      end
      return value
    end,
  }
end
local cb = S.controllerBlock({
  timezone = reader("America/New_York", true),
  locale = reader("error", true),
  hostname = reader("Beach-House-000FFF000001", false),
  project_id = reader(nil, true),
  boot_id = reader(7, false),
})
check("answered fields are sent", cb.timezone == "America/New_York" and cb.hostname == "Beach-House-000FFF000001")
check("a number answer is text", cb.boot_id == "7")
check("an erroring probe is omitted", cb.locale == nil)
check("a nil answer is omitted", cb.project_id == nil)
check(
  "probed lists only answered PROBE fields",
  #cb.probed == 1 and cb.probed[1] == "timezone",
  table.concat(cb.probed, ",")
)
check(
  "nothing answered: no block at all",
  S.controllerBlock({ timezone = reader("error", true), locale = reader("", true), boot_id = reader(nil, false) })
    == nil
)
local noProbe = S.controllerBlock({ hostname = reader("h", false) })
check("no PROBE answered: no probed key", noProbe.probed == nil and noProbe.hostname == "h")
check("signature changes with a value", S.controllerSignature(cb) ~= S.controllerSignature(noProbe))
check("signature is stable", S.controllerSignature(cb) == S.controllerSignature(S.controllerBlock({
  timezone = reader("America/New_York", true),
  hostname = reader("Beach-House-000FFF000001", false),
  boot_id = reader(7, false),
})))
check(
  "long values are cut to 200",
  #S.controllerBlock({ hostname = reader(string.rep("h", 300), false) }).hostname == 200
)

print("\n[9] last_errors")
local E = S.newLastErrors()
check("nothing failed: no block", E.block() == nil)
E.failure("devices", 413, "Payload too large", 1795014245)
E.failure("telemetry", nil, "Timeout was reached", 1795014245)
E.failure(nil, 500, "an unmapped path is ignored", 0)
local b = E.block()
check("one entry per failed channel", b.devices and b.telemetry and b.events == nil)
check("status is the HTTP status", b.devices.status == 413 and b.devices.at == "2026-11-18T15:04:05Z")
check("a transport failure is status 0", b.telemetry.status == 0 and b.telemetry.message == "Timeout was reached")
E.success("devices")
b = E.block()
check("cleared on that channel's next success", b.devices == nil and b.telemetry ~= nil)
E.success("telemetry")
check("all cleared: no block", E.block() == nil)
check(
  "channel map",
  S.channelFor("devices") == "devices"
    and S.channelFor("events") == "events"
    and S.channelFor("telemetry") == "telemetry"
    and S.channelFor("heartbeat") == nil
    and S.channelFor("event") == nil
)
check(
  "transport reason",
  S.transportReason("HTTP POST request to https://x/api failed; Timeout was reached") == "Timeout was reached"
)

local secrets = {
  { "Authorization: Bearer sbc4_abc123DEF456", "sbc4_abc123DEF456" },
  { 'rejected {"token":"tok-123-secret-value"}', "tok-123-secret-value" },
  { "url?api_key=AKIA1234&x=1", "AKIA1234" },
  { "X-SmartBuildOS-Property: 7d3c1c3e-prop", "7d3c1c3e-prop" },
  { "Cookie: sid=abcdef; Path=/", "abcdef" },
  { "password=hunter2 rejected", "hunter2" },
  { "Basic dXNlcjpwYXNz failed", "dXNlcjpwYXNz" },
  {
    "jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4ifQ.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c here",
    "SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c",
  },
  { "opaque " .. string.rep("A", 48) .. " end", string.rep("A", 48) },
}
for _, case in ipairs(secrets) do
  local out = S.sanitizeMessage(case[1])
  check("stripped: " .. case[1]:sub(1, 30), out:find(case[2], 1, true) == nil, out)
end
check(
  "useful text survives",
  S.sanitizeMessage("Could not record device state. — PGRST204 Could not find the 'room_id' column")
    == "Could not record device state. — PGRST204 Could not find the 'room_id' column"
)
local long = S.sanitizeMessage(string.rep("é", 150))
check("≤ 200 bytes, valid UTF-8 cut", #long <= 200 and #long == 200, #long)
E.failure("events", 500, "Bearer abc.def " .. string.rep("x ", 200), 0)
check(
  "failure() sanitizes and truncates",
  #E.block().events.message <= 200 and not E.block().events.message:find("abc.def", 1, true)
)

print("\n[10] capabilities")
check("six capability strings", #S.CAPABILITIES == 6)
for _, cap in ipairs({
  "device_poll_v1",
  "device_online_null_v1",
  "room_identity_v1",
  "driver_census_v1",
  "controller_identity_v1",
  "last_errors_v1",
}) do
  local found = false
  for _, c in ipairs(S.CAPABILITIES) do
    found = found or c == cap
  end
  check("declares " .. cap, found)
end

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
