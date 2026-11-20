-- Studio release G1 under the Director emulator (EMULATOR ONLY — not a bench
-- result): the real Agent (drivers/smartbuildos) in a small made-up project,
-- paired against the emulator's scripted cloud (examples/connector/fake_cloud.lua,
-- read only). Every heartbeat and devices body the Agent posts is captured
-- RAW, as the wire carries it, and the interesting ones are written to
-- $SBOS_G1_PAYLOADS (docs/studio-g1/sample-payloads/ via the run script).
--
-- What this proves that the shim suites cannot: the real transport (lib/http
-- → drivers-common-public url.lua → C4:urlPost) emits JSON null inside a row,
-- and the digest the Agent sends equals SHA-256 of the contract's input
-- string built from the payload it sent (C4:Hash is the emulator's own
-- SHA-256, checked against FIPS 180 vectors). Device names are invented.
--
-- Run: test/emulator/run-agent-studio-g1.sh   (exit 1 on any failed CHECK)

local EMU = assert(os.getenv("DIRECTOR_EMULATOR"), "DIRECTOR_EMULATOR not set (use the run script)")
local OUT = assert(os.getenv("SBOS_G1_OUT"), "SBOS_G1_OUT not set (use the run script)")
local PAYLOADS = os.getenv("SBOS_G1_PAYLOADS")
package.path = EMU .. "/examples/connector/?.lua;" .. package.path
local Cloud = require("fake_cloud")
local digest = require("director.digest")

local passed, failed = 0, 0
local function check(label, ok, detail)
  if ok then
    passed = passed + 1
    print("  CHECK ok    " .. label)
  else
    failed = failed + 1
    print("  CHECK FAIL  " .. label .. (detail ~= nil and ("  -> " .. tostring(detail)) or ""))
  end
end

local function sha256hex(s)
  return digest.tohex(digest.hash("SHA256", s)):lower()
end

-- ── The pinned vector (docs/studio-g1/DIGEST-VECTORS.md), on this SHA-256 ──
print("[0] the pinned digest vectors on the emulator's SHA-256")
local VECTOR_INPUT =
  "c4:1:1\nc4:10:0\nc4:2:u\nc4:99:u\ndiscovered:192.168.1.60:1\nping:192.168.1.99:0\nping:nas.local:1"
check(
  "vector A",
  sha256hex(VECTOR_INPUT) == "0ef1484482b04ba81a3cdf97804ac0d95aca5d66834ea78ae1f5a9aadb0a911d",
  sha256hex(VECTOR_INPUT)
)
check("vector B (empty)", sha256hex("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
check("vector C (one line)", sha256hex("c4:42:1") == "6302f52fab81bcdc4c8757fcbd369a064c11fd12e8ddadbc7f6d3a51b59b95e6")

-- ── A made-up project ───────────────────────────────────────────────────────
local d = Director.new({
  cacheDir = os.getenv("DIRECTOR_CACHE"),
  timezone = "America/New_York",
  locale = "en-US",
  hostname = "Beach-House-000FFF000001",
})
local cloud = Cloud.new(d)
local captured = {} -- { path, raw, body }
local failDevicesOnce = false
d.http = function(req, dev)
  local path = tostring(req.url):match("^https?://[^/]+(/[^?]*)")
  if path == "/api/integrations/control4/heartbeat" or path == "/api/integrations/control4/devices" then
    captured[#captured + 1] = { path = path, raw = req.body, body = json.decode(req.body) }
    if path == "/api/integrations/control4/devices" and failDevicesOnce then
      failDevicesOnce = false
      return {
        code = 413,
        headers = { ["Content-Type"] = "application/json" },
        body = json.encode({
          error = "Payload too large",
          detail = "request rejected; Authorization: Bearer sbc4_made_up_value_that_must_not_travel",
        }),
      }
    end
  end
  return cloud:handle(req, dev)
end

local equipment = d:addRoom("Equipment")
local living = d:addRoom("Living Room")
local den = d:addRoom("Den")
d:addRoom("Guest Room") -- deliberately empty

local function networkDriverXml(name, version)
  return "<devicedata><name>"
    .. name
    .. "</name><model>"
    .. name
    .. "</model><manufacturer>Example AV</manufacturer><version>"
    .. version
    .. "</version><control>lua_gen</control><connections><connection><id>6001</id><type>4</type>"
    .. "<connectionname>Network</connectionname><consumer>True</consumer><classes><class><classname>TCP</classname>"
    .. "<ports><port><number>23</number></port></ports></class></classes></connection></connections>"
    .. "<config><properties/></config></devicedata>"
end
local IR_TV_XML = "<devicedata><name>Example IR Television</name><model>IRTV</model><manufacturer>Example AV</manufacturer>"
  .. "<version>7</version><control>lua_gen</control>"
  .. '<proxies><proxy proxybindingid="5001" name="Den TV">tv</proxy></proxies>'
  .. "<connections><connection><id>5001</id><type>2</type><connectionname>TV</connectionname><consumer>False</consumer>"
  .. "<classes><class><classname>TV</classname></class></classes></connection></connections>"
  .. "<config><properties/></config></devicedata>"

local agent = assert(d:addDevice(OUT .. "/smartbuildos", { roomId = equipment, name = "SmartBuildOS" }))
d:setProperty(agent, "Automatic Updates", "Off")
d:advance(1000)

local amp1 = assert(d:addDeviceFromXml(networkDriverXml("Example Network Amplifier", "112"), {
  key = "amp1",
  name = "Living Room Amplifier",
  roomId = living,
  filename = "example_amplifier.c4z",
}))
local amp2 = assert(d:addDeviceFromXml(networkDriverXml("Example Network Amplifier", "112"), {
  key = "amp2",
  name = "Den Amplifier",
  roomId = den,
  filename = "example_amplifier.c4z",
}))
local pool = assert(d:addDeviceFromXml(networkDriverXml("Example Pool Controller", "3"), {
  key = "pool",
  name = "Pool Controller",
  roomId = equipment,
  filename = "example_pool.c4z",
}))
-- An IR television: no network binding, and a `tv` proxy device of its own.
assert(d:addDeviceFromXml(IR_TV_XML, { key = "irtv", name = "Den TV", roomId = den, filename = "example_irtv.c4i" }))
d:identify(amp1, 6001, "192.168.1.50")
d:identify(pool, 6001, "192.168.1.51")
-- Placed in the project, never pointed at hardware: Control4's placeholder.
d:identify(amp2, 6001, "NOT_SET")

d:setProperty(agent, "Pairing Code", "ABCD-2345")
d:advance(5000)

local function last(path, pred)
  for i = #captured, 1, -1 do
    local c = captured[i]
    if c.path:find(path, 1, true) and (pred == nil or pred(c)) then
      return c, i
    end
  end
  return nil
end

local function save(name, c)
  if PAYLOADS == nil or c == nil then
    return
  end
  local f = assert(io.open(PAYLOADS .. "/" .. name, "wb"))
  f:write(c.raw)
  f:close()
end

print("[1] full sync: rooms, driver census, room_id, real nulls")
local snap = last("/devices", function(c)
  return c.body.kind == "snapshot"
end)
check("a snapshot was sent after pairing", snap ~= nil)
snap = snap or { raw = "", body = { devices = {} } }
save("devices-snapshot.json", snap)
local byName = {}
for _, row in ipairs(snap.body.devices or {}) do
  byName[row.name] = row
end
check("raw body carries online:null", snap.raw:find('"online":null', 1, true) ~= nil)
check("raw body carries connection_type:null", snap.raw:find('"connection_type":null', 1, true) ~= nil)
check("the placeholder never reaches the wire", snap.raw:find("sbos:json-null", 1, true) == nil)
check(
  "reachable amplifier online with room_id",
  (byName["Living Room Amplifier"] or {}).online == true and (byName["Living Room Amplifier"] or {}).room_id == living
)
check(
  "NOT_SET amplifier: key present, value null",
  byName["Den Amplifier"] ~= nil
    and byName["Den Amplifier"].online == nil
    and snap.raw:find('"address":"NOT_SET"', 1, true) ~= nil
)
check("IR TV reported once (its proxy is not a twin)", byName["Den TV"] ~= nil and (function()
  local n = 0
  for _, row in ipairs(snap.body.devices) do
    if row.name == "Den TV" then
      n = n + 1
    end
  end
  return n == 1
end)())
check("IR TV room_id", (byName["Den TV"] or {}).room_id == den)
local roomIds = {}
for _, r in ipairs(snap.body.rooms or {}) do
  roomIds[r.id] = r
end
check(
  "rooms include the empty Guest Room",
  (function()
    for _, r in ipairs(snap.body.rooms or {}) do
      if r.name == "Guest Room" then
        return true
      end
    end
    return false
  end)()
)
check(
  "rooms carry floor and building",
  (roomIds[living] or {}).floor == "Main Floor" and (roomIds[living] or {}).building == "Main House",
  json.encode(roomIds[living] or {})
)
local census = {}
for _, entry in ipairs(snap.body.drivers or {}) do
  census[entry.file] = entry
end
local amps = census["example_amplifier.c4z"] or {}
check("census: amplifier file counted twice", amps.count == 2, json.encode(amps))
check(
  "census: name and version from GetDeviceData",
  amps.name == "Example Network Amplifier" and amps.version == "112",
  json.encode(amps)
)
check(
  "census: proxies are not driver entries",
  census["tv.c4i"] == nil and census["smartbuildos.c4i"] == nil,
  json.encode(snap.body.drivers)
)
check("census: the IR TV's own file", (census["example_irtv.c4i"] or {}).count == 1)
check(
  "census: the Agent is sbos",
  (census["smartbuildos"] or census["smartbuildos.c4z"] or {}).sbos == true,
  json.encode(snap.body.drivers)
)

print("[2] first heartbeat: controller block")
local firstHb = last("/heartbeat", function(c)
  return c.body.controller ~= nil
end)
check("controller block sent", firstHb ~= nil)
firstHb = firstHb or { raw = "", body = {} }
save("heartbeat-first.json", firstHb)
local ctl = firstHb.body.controller or {}
check(
  "timezone, locale, hostname, boot_id",
  ctl.timezone == "America/New_York"
    and ctl.locale == "en-US"
    and ctl.hostname == "Beach-House-000FFF000001"
    and ctl.boot_id ~= nil,
  json.encode(ctl)
)
check("project_id absent (GetProjectId absent on OS 4.3)", ctl.project_id == nil)
check(
  "probed = timezone, locale",
  table.concat(ctl.probed or {}, ",") == "timezone,locale",
  table.concat(ctl.probed or {}, ",")
)
local caps = table.concat(firstHb.body.capabilities or {}, ",")
check("capabilities declared", caps:find("device_poll_v1", 1, true) and caps:find("last_errors_v1", 1, true), caps)

print("[3] a device poll, then device_poll on the next heartbeat")
local before = #captured
d:advance(6 * 60 * 1000)
local pollHb
for i = before + 1, #captured do
  if captured[i].path:find("/heartbeat", 1, true) and captured[i].body.device_poll ~= nil then
    pollHb = captured[i]
    break
  end
end
check("a heartbeat carried device_poll", pollHb ~= nil)
pollHb = pollHb or { raw = "", body = {} }
save("heartbeat-device-poll.json", pollHb)
local poll = pollHb.body.device_poll or {}
-- The digest, rebuilt from the WIRE rows exactly as the contract words it.
local lines = {}
for _, row in ipairs(snap.body.devices or {}) do
  lines[#lines + 1] = { key = row.key, state = row.online == true and "1" or (row.online == false and "0" or "u") }
end
table.sort(lines, function(a, b)
  return a.key < b.key -- LuaJIT compares bytes
end)
local text = {}
for i, l in ipairs(lines) do
  text[i] = l.key .. ":" .. l.state
end
local expected = sha256hex(table.concat(text, "\n"))
check(
  "digest = SHA-256 of the contract input built from the snapshot",
  poll.digest == expected,
  tostring(poll.digest) .. " vs " .. expected
)
check("counts agree with the snapshot", poll.devices == #lines, poll.devices)
check("interval_s is the 5-minute poll", poll.interval_s == 300, poll.interval_s)
check("controller not repeated", pollHb.body.controller == nil)

print("[4] a devices upload fails: last_errors, stripped")
failDevicesOnce = true
d:executeCommand(agent, "SEND_FULL_SYNC", {})
d:advance(2 * 60 * 1000)
local errHb = last("/heartbeat", function(c)
  return c.body.last_errors ~= nil
end)
check("a heartbeat carried last_errors", errHb ~= nil)
errHb = errHb or { raw = "", body = {} }
save("heartbeat-last-errors.json", errHb)
local de = (errHb.body.last_errors or {}).devices or {}
check(
  "devices: status 413, the platform's reason",
  de.status == 413 and tostring(de.message):find("Payload too large", 1, true) ~= nil,
  json.encode(de)
)
check("the credential value is stripped", errHb.raw:find("sbc4_made_up_value", 1, true) == nil)
d:executeCommand(agent, "SEND_FULL_SYNC", {})
d:advance(2 * 60 * 1000)
local cleared = last("/heartbeat")
check("cleared after the next devices success", cleared and cleared.body.last_errors == nil)

print("[5] an address cleared to NOT_SET: a delta, online null")
d:identify(amp1, 6001, "NOT_SET")
before = #captured
d:advance(6 * 60 * 1000)
local delta
for i = before + 1, #captured do
  if captured[i].path:find("/devices", 1, true) and captured[i].body.kind == "delta" then
    delta = captured[i]
  end
end
check("a delta was sent", delta ~= nil)
delta = delta or { raw = "", body = { devices = {} } }
save("devices-delta.json", delta)
check("the amplifier's online is null on the wire", delta.raw:find('"online":null', 1, true) ~= nil)

if #agent.errors > 0 then
  print("  NOTE agent runtime errors: " .. tostring(agent.errors[1]):gsub("\n.*", ""))
end
check("the Agent raised no runtime error", #agent.errors == 0, agent.errors[1])
print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then
  os.exit(1)
end
