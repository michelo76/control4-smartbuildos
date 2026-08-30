--- BPUP transport — the Bond Push UDP Protocol socket.
---
--- BPUP (docs-local.appbond.com, Beta): open a UDP "connection" to the Bond
--- on port 30007, send a bare newline as Keep-Alive, and the Bond replies
--- with `{"B":"<bondid>"}` and starts pushing `devices/*/state` updates as
--- newline-terminated JSON datagrams. Keep-Alives must repeat within 60s;
--- the Bond drops the subscriber after 125 quiet seconds.
---
--- Transport is DriverWorks' network-connection surface, the same one the
--- vendored websocket module uses — a runtime net binding via
--- C4:CreateNetworkConnection + C4:NetPortOptions(port, "UDP"), datagrams in
--- through the RFN dispatch table and out through C4:SendToNetwork. Bindings
--- are allocated from 6001-6099 by scanning for a free slot; the websocket
--- module owns 6100-6199, and staying below it means the two allocators can
--- never fight over a slot.
---
--- ⚠ UNVERIFIED ON HARDWARE: the UDP flavor of NetPortOptions/SendToNetwork
--- is documented but this suite has only field-measured the SSL/TCP flavor
--- (websocket). The gateway therefore treats BPUP as an accelerator, never a
--- dependency — hash polling keeps running underneath, and isAlive() lets
--- the driver display exactly which of the two is feeding it.
---
--- One instance fronts one Bond. The module does NOT own timers (drivers
--- own timers); it exposes keepalive() for the driver's 60s timer, and
--- isAlive() judged against the Bond's own 125s contract.

local log = require("lib.logging")

local M = {}
M.__index = M

--- BPUP's fixed UDP port on the Bond.
local BPUP_PORT = 30007

--- Seconds of datagram silence after which the subscription is presumed
--- dead. The Bond's own client timeout is 125s; one extra keep-alive round
--- of slack keeps a single lost datagram from flapping the status.
local ALIVE_WINDOW_SECONDS = 130

--- Net binding scan range (inclusive). Below the websocket module's
--- 6100-6199 pool, above the static XML bindings drivers actually declare.
local BINDING_SCAN_START = 6001
local BINDING_SCAN_END = 6099

--- Creates an idle transport.
--- @param opts table|nil { onFrame = function(datagramLine), onStatus = function(statusString) }
--- @return table bpup
function M.new(opts)
  opts = opts or {}
  local instance = setmetatable({}, M)
  instance.host = ""
  instance.binding = nil
  instance.running = false
  instance.lastRxAt = nil
  instance.onFrame = opts.onFrame
  instance.onStatus = opts.onStatus
  return instance
end

--- Finds a free net binding slot, or nil when the pool is exhausted.
--- @private
--- @return number|nil binding
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

--- Opens the socket toward `host` and registers the dispatch hooks.
--- Idempotent per host: starting while already running against the same
--- host is a no-op; a different host tears down and redials.
--- @param host string The Bond's host/IP (no scheme, no port).
--- @return boolean started
function M:start(host)
  host = tostring(host or "")
  if host == "" then
    return false
  end
  if self.running and self.host == host then
    return true
  end
  if self.running then
    self:stop()
  end

  self.binding = self.binding or self:_allocateBinding()
  if self.binding == nil then
    log:warn("BPUP: no free net binding slot; push updates unavailable")
    return false
  end

  self.host = host
  self.lastRxAt = nil

  local ok, err = pcall(function()
    C4:CreateNetworkConnection(self.binding, host)
    C4:NetPortOptions(self.binding, BPUP_PORT, "UDP")
    C4:NetConnect(self.binding, BPUP_PORT, "UDP")
  end)
  if not ok then
    log:warn("BPUP: socket setup failed: %s", tostring(err))
    return false
  end

  OCS = OCS or {}
  OCS[self.binding] = function(_, _, strStatus)
    log:debug("BPUP connection status: %s", tostring(strStatus))
    if strStatus == "ONLINE" then
      -- First keep-alive rides the moment the socket opens; the driver's
      -- 60s timer takes it from there.
      self:keepalive()
    end
    if self.onStatus then
      pcall(self.onStatus, strStatus)
    end
  end

  RFN = RFN or {}
  RFN[self.binding] = function(_, _, strData)
    self.lastRxAt = os.time()
    if self.onFrame == nil then
      return
    end
    -- Datagrams are newline-terminated and can arrive coalesced; hand the
    -- parser one line at a time.
    for line in tostring(strData or ""):gmatch("[^\n]+") do
      pcall(self.onFrame, line)
    end
  end

  self.running = true
  log:info("BPUP: subscribing to %s:%s on net binding %s", host, BPUP_PORT, self.binding)
  return true
end

--- Sends the Keep-Alive datagram (a single newline). Safe to call any time;
--- quietly does nothing while stopped.
function M:keepalive()
  if not self.running or self.binding == nil then
    return
  end
  pcall(function()
    C4:SendToNetwork(self.binding, BPUP_PORT, "\n")
  end)
end

--- Whether datagrams have arrived recently enough to trust push coverage.
--- @param now number|nil os.time() override for tests.
--- @return boolean alive
function M:isAlive(now)
  if not self.running or self.lastRxAt == nil then
    return false
  end
  return ((now or os.time()) - self.lastRxAt) <= ALIVE_WINDOW_SECONDS
end

--- Tears the socket down and releases the dispatch hooks. The binding slot
--- is kept for reuse by this instance — Director does not reliably release
--- net bindings anyway (the websocket module's measured lesson).
function M:stop()
  if self.binding ~= nil then
    pcall(function()
      C4:NetDisconnect(self.binding, BPUP_PORT)
    end)
    if OCS then
      OCS[self.binding] = nil
    end
    if RFN then
      RFN[self.binding] = nil
    end
  end
  self.running = false
  self.lastRxAt = nil
end

return M
