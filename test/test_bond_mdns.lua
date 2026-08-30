-- Tests for src/bond/mdns.lua.
--
-- The DNS wire-format builder and parser are pure functions; the fixture
-- response below is a byte-accurate mDNS answer with NAME COMPRESSION in
-- every place a real responder uses it (PTR rdata, SRV/TXT owners, SRV
-- target, A owner), because compression is where hand-rolled DNS parsers
-- die. The invariants:
--
--   * The query is one PTR question for _bond._tcp.local with the QU bit —
--     that bit is the whole design (unicast replies reach our socket).
--   * A full PTR+SRV+TXT+A answer yields {bondid, ip, port, txt}.
--   * Non-DNS noise, queries, and truncated packets parse to EMPTY, never
--     an error — multicast neighborhoods are noisy.
--   * The transport wires RFN and hands each device to onDevice.
--
-- Run from the driver root:
--   make test

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

local Mdns = require("bond.mdns")

-- ─── Wire helpers ─────────────────────────────────────────────────────────────

local function num16(n)
  return string.char(math.floor(n / 256), n % 256)
end

local function num32(n)
  return num16(math.floor(n / 65536)) .. num16(n % 65536)
end

local function pointer(offset)
  return string.char(192 + math.floor(offset / 256), offset % 256)
end

local function label(s)
  return string.char(#s) .. s
end

-- ─── buildQuery ───────────────────────────────────────────────────────────────

print("buildQuery")
local query = Mdns.buildQuery()
check("12-byte header + question", #query == 12 + 18 + 4, #query)
check("one question, no answers", query:sub(5, 6) == num16(1) and query:sub(7, 8) == num16(0))
check(
  "asks for _bond._tcp.local",
  query:find(label("_bond") .. label("_tcp") .. label("local") .. "\0", 1, true) ~= nil
)
check("PTR type", query:sub(#query - 3, #query - 2) == num16(12))
check("QU bit set on the class", query:sub(#query - 1) == "\128\1")

-- ─── Fixture response ─────────────────────────────────────────────────────────
--
-- Built with explicit offset tracking so the compression pointers are real.

local parts, offset = {}, 0
local function add(chunk)
  local at = offset
  table.insert(parts, chunk)
  offset = offset + #chunk
  return at
end

add(num16(0) .. num16(0x8400) .. num16(0) .. num16(2) .. num16(0) .. num16(2)) -- header: response, 2 AN + 2 AR

-- Answer 1: PTR. Owner is the service name, spelled in full (offset 12).
local svcOffset = add(label("_bond") .. label("_tcp") .. label("local") .. "\0")
local localOffset = svcOffset + 11 -- the "local" label inside the service name
add(num16(12) .. num16(1) .. num32(4500)) -- TYPE PTR, CLASS IN, TTL
add(num16(12)) -- RDLENGTH: 1+9 label + 2 pointer
local instanceOffset = add(label("ZZBL12345") .. pointer(svcOffset))

-- Answer 2: SRV. Owner compressed to the instance; target spelled with a
-- compressed "local" tail.
add(pointer(instanceOffset))
add(num16(33) .. num16(1) .. num32(120))
add(num16(18)) -- RDLENGTH: 6 + 1+9 label + 2 pointer
add(num16(0) .. num16(0) .. num16(80)) -- priority, weight, port
local hostOffset = add(label("ZZBL12345") .. pointer(localOffset))

-- Additional 1: TXT on the instance.
add(pointer(instanceOffset))
add(num16(16) .. num16(1) .. num32(4500))
local txtData = label("v=v3.5.0") .. label("d=0")
add(num16(#txtData))
add(txtData)

-- Additional 2: A on the SRV target.
add(pointer(hostOffset))
add(num16(1) .. num16(1) .. num32(120))
add(num16(4))
add(string.char(192, 168, 4, 77))

local response = table.concat(parts)

-- ─── parseResponse ────────────────────────────────────────────────────────────

print("parseResponse")
local devices = Mdns.parseResponse(response)
check("one Bond found", #devices == 1, #devices)
local device = devices[1] or {}
check("bond id from the instance label", device.bondid == "ZZBL12345", device.bondid)
check("IPv4 joined through SRV target", device.ip == "192.168.4.77", device.ip)
check("port from SRV", device.port == 80, device.port)
check("TXT firmware", (device.txt or {}).v == "v3.5.0", (device.txt or {}).v)
check("TXT discoverability", (device.txt or {}).d == "0", (device.txt or {}).d)

check("garbage → empty", #Mdns.parseResponse("definitely not dns") == 0)
check("nil → empty", #Mdns.parseResponse(nil) == 0)
check("a query (not response) → empty", #Mdns.parseResponse(Mdns.buildQuery()) == 0)
check("truncated response → empty, no error", #Mdns.parseResponse(response:sub(1, 40)) == 0)

-- A datagram about some OTHER service parses to nothing.
local otherParts, otherOffset = {}, 0
local function addOther(chunk)
  local at = otherOffset
  table.insert(otherParts, chunk)
  otherOffset = otherOffset + #chunk
  return at
end
addOther(num16(0) .. num16(0x8400) .. num16(0) .. num16(1) .. num16(0) .. num16(0))
local otherSvc = addOther(label("_http") .. label("_tcp") .. label("local") .. "\0")
addOther(num16(12) .. num16(1) .. num32(4500) .. num16(10))
addOther(label("printer") .. pointer(otherSvc))
check("another service's announce → empty", #Mdns.parseResponse(table.concat(otherParts)) == 0)

-- ─── Transport ────────────────────────────────────────────────────────────────

print("transport")

local netCalls, netSent = {}, {}
function C4:GetBindingAddress()
  return nil
end
function C4:CreateNetworkConnection(id, host)
  table.insert(netCalls, { call = "create", id = id, host = host })
end
function C4:NetPortOptions(id, port, protocol)
  table.insert(netCalls, { call = "portoptions", id = id, port = port, protocol = protocol })
end
function C4:NetConnect(id, port, protocol)
  table.insert(netCalls, { call = "connect", id = id, port = port, protocol = protocol })
end
function C4:NetDisconnect(id, port)
  table.insert(netCalls, { call = "disconnect", id = id, port = port })
end
function C4:SendToNetwork(id, port, data)
  table.insert(netSent, { id = id, port = port, data = data })
end

local found = {}
local resolver = Mdns.new({
  onDevice = function(dev)
    table.insert(found, dev)
  end,
})
check("starts", resolver:start() == true)
local udpOk = false
for _, call in ipairs(netCalls) do
  if call.call == "portoptions" and call.port == 5353 and call.protocol == "UDP" then
    udpOk = true
  end
end
check("UDP 5353 port options", udpOk)
check("multicast group addressed", netCalls[1] ~= nil and netCalls[1].host == "224.0.0.251")

resolver:query()
check("query hit the wire", #netSent == 1 and netSent[1].data == Mdns.buildQuery())

check("RFN hook registered", resolver.binding ~= nil and RFN ~= nil and RFN[resolver.binding] ~= nil)
RFN[resolver.binding](resolver.binding, 5353, response)
check("device delivered to onDevice", #found == 1 and found[1].bondid == "ZZBL12345")

resolver:stop()
check("RFN hook released", RFN[resolver.binding] == nil)

-- ─── Summary ──────────────────────────────────────────────────────────────────

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
