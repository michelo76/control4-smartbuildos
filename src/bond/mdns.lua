--- Bond mDNS discovery — one-shot resolver for `_bond._tcp.local`.
---
--- Every Bond announces itself over mDNS: instance `<BONDID>._bond._tcp.local`,
--- an SRV record pointing at `<BONDID>.local`, an A record with the IPv4,
--- and TXT properties (`v=` firmware, `d=` discoverability 0/1/2). This
--- module finds them so a dealer never types an IP.
---
--- Design: a ONE-SHOT resolver per RFC 6762 §5.1, not a full responder. The
--- query sets the QU ("unicast response requested") bit, so Bonds reply
--- unicast straight back to our socket's source port — which is what makes
--- this workable over DriverWorks' net-binding UDP transport (the same one
--- BPUP uses) without joining the multicast group.
---
--- ⚠ UNVERIFIED ON HARDWARE, same caveat as BPUP: the UDP flavor of the
--- net-binding transport is documented but this suite has only measured the
--- SSL/TCP flavor. Discovery failing costs nothing — the dealer types the
--- IP exactly as they would with the commercial driver's fallback.
---
--- The DNS wire-format builder and parser are PURE functions, tested with
--- fixture packets; the socket is a thin wrapper. No timers here — the
--- driver owns cadence (re-query + stop), this module owns bytes.

local log = require("lib.logging")

local M = {}
M.__index = M

--- mDNS rendezvous.
local MDNS_ADDRESS = "224.0.0.251"
local MDNS_PORT = 5353

--- The service being resolved.
local SERVICE = "_bond._tcp.local"

--- DNS record types this parser understands.
local TYPE_A = 1
local TYPE_PTR = 12
local TYPE_TXT = 16
local TYPE_SRV = 33

--- Net binding scan range — the shared convention: 6001-6099 for this
--- suite's raw sockets, 6100-6199 belongs to the websocket module.
local BINDING_SCAN_START = 6001
local BINDING_SCAN_END = 6099

-- ─── Wire format: build ───────────────────────────────────────────────────────

--- Encodes a dotted name into DNS label format.
local function encodeName(name)
  local out = {}
  for label in tostring(name):gmatch("[^%.]+") do
    table.insert(out, string.char(#label) .. label)
  end
  table.insert(out, "\0")
  return table.concat(out)
end

--- One PTR question for the Bond service, QU bit set.
--- @return string packet
function M.buildQuery()
  return table.concat({
    "\0\0", -- ID 0 (mDNS convention for one-shot)
    "\0\0", -- flags: standard query
    "\0\1", -- QDCOUNT 1
    "\0\0", -- ANCOUNT
    "\0\0", -- NSCOUNT
    "\0\0", -- ARCOUNT
    encodeName(SERVICE),
    "\0\12", -- QTYPE PTR
    "\128\1", -- QCLASS IN with the QU (unicast response) bit
  })
end

-- ─── Wire format: parse ───────────────────────────────────────────────────────

local function u16(data, pos)
  local hi, lo = data:byte(pos, pos + 1)
  if hi == nil or lo == nil then
    return nil
  end
  return hi * 256 + lo
end

--- Decodes a (possibly compressed) DNS name starting at `pos`.
--- @return string|nil name Dotted lowercase name.
--- @return number|nil nextPos Position after the name (in the ORIGINAL stream).
local function decodeName(data, pos)
  local labels = {}
  local jumps = 0
  local nextPos = nil
  while true do
    local len = data:byte(pos)
    if len == nil then
      return nil, nil
    end
    if len == 0 then
      nextPos = nextPos or (pos + 1)
      break
    end
    if len >= 192 then
      -- Compression pointer: 14-bit offset. Remember where the original
      -- stream resumes, then follow (guarded — malformed loops must not
      -- hang a Director).
      local lo = data:byte(pos + 1)
      if lo == nil then
        return nil, nil
      end
      nextPos = nextPos or (pos + 2)
      pos = (len % 64) * 256 + lo + 1
      jumps = jumps + 1
      if jumps > 16 then
        return nil, nil
      end
    else
      if #labels >= 32 then
        return nil, nil
      end
      table.insert(labels, data:sub(pos + 1, pos + len):lower())
      pos = pos + 1 + len
    end
  end
  return table.concat(labels, "."), nextPos
end

--- Splits a TXT record's data into key=value pairs.
local function decodeTxt(data)
  local txt = {}
  local pos = 1
  while pos <= #data do
    local len = data:byte(pos)
    if len == nil or len == 0 then
      break
    end
    local entry = data:sub(pos + 1, pos + len)
    local key, value = entry:match("^([^=]+)=(.*)$")
    if key ~= nil then
      txt[key] = value
    end
    pos = pos + 1 + len
  end
  return txt
end

--- Parses one mDNS datagram into Bond devices.
---
--- Correlation: instances of `_bond._tcp.local` come from PTR targets and
--- SRV/TXT owners; the IP comes from the A record of the SRV target (or of
--- `<bondid>.local` when the SRV is absent from this datagram). Anything
--- non-DNS or non-Bond parses to an empty list, never an error — multicast
--- neighborhoods are noisy.
--- @param datagram string The raw packet.
--- @return table[] devices { bondid, ip, port, txt } — possibly empty.
function M.parseResponse(datagram)
  if type(datagram) ~= "string" or #datagram < 12 then
    return {}
  end
  local flags = u16(datagram, 3)
  if flags == nil or flags < 32768 then
    return {} -- not a response
  end
  local qdcount = u16(datagram, 5) or 0
  local records = (u16(datagram, 7) or 0) + (u16(datagram, 9) or 0) + (u16(datagram, 11) or 0)
  local pos = 13

  -- Skip questions.
  for _ = 1, qdcount do
    local _, nextPos = decodeName(datagram, pos)
    if nextPos == nil then
      return {}
    end
    pos = nextPos + 4
  end

  local instances = {} -- instance name -> true
  local srv = {} -- instance name -> { target, port }
  local txt = {} -- instance name -> table
  local addresses = {} -- host name -> ip

  for _ = 1, records do
    local owner, nextPos = decodeName(datagram, pos)
    if owner == nil then
      break
    end
    pos = nextPos
    local rtype = u16(datagram, pos)
    local rdlength = u16(datagram, pos + 8)
    if rtype == nil or rdlength == nil then
      break
    end
    local rdataStart = pos + 10
    local rdata = datagram:sub(rdataStart, rdataStart + rdlength - 1)
    if #rdata < rdlength then
      break
    end

    if rtype == TYPE_PTR and owner == SERVICE then
      local target = decodeName(datagram, rdataStart)
      if target ~= nil then
        instances[target] = true
      end
    elseif rtype == TYPE_SRV and owner:find("._bond._tcp.local", 1, true) then
      instances[owner] = true
      local target = decodeName(datagram, rdataStart + 6)
      srv[owner] = { target = target, port = u16(datagram, rdataStart + 4) }
    elseif rtype == TYPE_TXT and owner:find("._bond._tcp.local", 1, true) then
      instances[owner] = true
      txt[owner] = decodeTxt(rdata)
    elseif rtype == TYPE_A and rdlength == 4 then
      local a, b, c, d = rdata:byte(1, 4)
      addresses[owner] = string.format("%d.%d.%d.%d", a, b, c, d)
    end

    pos = rdataStart + rdlength
  end

  local devices = {}
  for instance in pairs(instances) do
    local bondid = instance:match("^([^%.]+)%._bond%._tcp%.local$")
    if bondid ~= nil then
      local record = srv[instance] or {}
      local ip = (record.target and addresses[record.target]) or addresses[bondid .. ".local"]
      table.insert(devices, {
        bondid = bondid:upper(),
        ip = ip,
        port = record.port,
        txt = txt[instance] or {},
      })
    end
  end
  table.sort(devices, function(x, y)
    return x.bondid < y.bondid
  end)
  return devices
end

-- ─── Transport ────────────────────────────────────────────────────────────────

--- Creates an idle resolver.
--- @param opts table|nil { onDevice = function(device) } — called once per device per datagram.
--- @return table mdns
function M.new(opts)
  opts = opts or {}
  local instance = setmetatable({}, M)
  instance.binding = nil
  instance.running = false
  instance.onDevice = opts.onDevice
  return instance
end

--- @private
function M:_allocateBinding()
  for candidate = BINDING_SCAN_START, BINDING_SCAN_END do
    local ok, address = pcall(function()
      return C4:GetBindingAddress(candidate)
    end)
    if ok and (address == nil or address == "") then
      return candidate
    end
  end
  return nil
end

--- Opens the socket toward the mDNS group. Idempotent.
--- @return boolean started
function M:start()
  if self.running then
    return true
  end
  self.binding = self.binding or self:_allocateBinding()
  if self.binding == nil then
    log:warn("mDNS: no free net binding slot; discovery unavailable")
    return false
  end
  local ok, err = pcall(function()
    C4:CreateNetworkConnection(self.binding, MDNS_ADDRESS)
    C4:NetPortOptions(self.binding, MDNS_PORT, "UDP")
    C4:NetConnect(self.binding, MDNS_PORT, "UDP")
  end)
  if not ok then
    log:warn("mDNS: socket setup failed: %s", tostring(err))
    return false
  end

  RFN = RFN or {}
  RFN[self.binding] = function(_, _, strData)
    if self.onDevice == nil then
      return
    end
    for _, device in ipairs(M.parseResponse(strData)) do
      pcall(self.onDevice, device)
    end
  end

  self.running = true
  return true
end

--- Sends one PTR query for the Bond service.
function M:query()
  if not self.running or self.binding == nil then
    return
  end
  pcall(function()
    C4:SendToNetwork(self.binding, MDNS_PORT, M.buildQuery())
  end)
end

--- Tears the socket down and releases the dispatch hook.
function M:stop()
  if self.binding ~= nil then
    pcall(function()
      C4:NetDisconnect(self.binding, MDNS_PORT)
    end)
    if RFN then
      RFN[self.binding] = nil
    end
  end
  self.running = false
end

return M
