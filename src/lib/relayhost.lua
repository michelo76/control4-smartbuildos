--- Which address the controller answers on, for a Web View relay.
---
--- A relay is a small HTTP server a driver opens on the controller; the
--- Navigators load `http://<controller>:<port>/app` from it. The driver runs
--- ON the controller, and Director does not hand a driver its own LAN address
--- in the device inventory: the controller's own entry is the loopback one.
---
--- The first cut took "the first control4_* device with a network binding".
--- Bench, 10 Nov 2026: that was another Control4 device on the network (a
--- remote, a touch screen and a second controller all have control4_ drivers
--- and an address). All three tiles were published at an address where
--- nothing listened, and nothing said so.
---
--- So an address read off a device binding is never published on trust. It
--- is a CANDIDATE, and a candidate is asked `GET /ping`: the first one where
--- THIS relay answers by name is the controller. In order:
---
---   1. The dealer's App Relay Address, when set. Used as written, not asked.
---   2. C4:GetControllerNetworkAddress(), "the address of the master
---      controller". Published at once (it is the documented answer), and
---      still asked, so the status can say whether it was confirmed.
---   3. Every routable address on a control4_* device binding, lowest device
---      id first. Published only after it has answered.
---
--- When nothing answers and the API gave nothing, the host is "" and the
--- status asks for the App Relay Address: no address beats a wrong one.

local M = {}

--- Seconds one candidate is given to answer.
M.TIMEOUT_SECONDS = 4

--- How often a confirmed address is asked again (the controller's lease can
--- change), and the ceiling for asking again after a pass with no answer.
M.RECHECK_SECONDS = 900

local function trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

--- A dotted IPv4 address a Navigator could reach: not loopback, link-local,
--- unspecified or broadcast.
function M.isRoutable(addr)
  if type(addr) ~= "string" then
    return false
  end
  local a, b, c, d = trim(addr):match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
  a, b, c, d = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
  if a == nil or a > 255 or b > 255 or c > 255 or d > 255 then
    return false
  end
  if a == 0 or a == 127 or a >= 224 or (a == 169 and b == 254) then
    return false
  end
  return true
end

--- Every `addr` anywhere in a Director bindings answer (its shape varies by
--- project and OS: walked, depth-bounded, cycle-guarded), sorted so the
--- order does not depend on table iteration.
function M.addresses(node)
  local found, seen = {}, {}
  local function walk(n, depth)
    if type(n) ~= "table" or depth > 6 or seen[n] then
      return
    end
    seen[n] = true
    if M.isRoutable(n.addr) then
      found[trim(n.addr)] = true
    end
    for _, child in pairs(n) do
      if type(child) == "table" then
        walk(child, depth + 1)
      end
    end
  end
  walk(node, 0)
  local out = {}
  for addr in pairs(found) do
    out[#out + 1] = addr
  end
  table.sort(out)
  return out
end

-- ── what Director can tell us (each replaceable for a test) ─────────────────

local function c4ControllerAddress()
  local ok, addr = pcall(function()
    return C4:GetControllerNetworkAddress()
  end)
  return ok and addr or nil
end

local function c4Devices()
  local ok, devices = pcall(function()
    return C4:GetDevices({})
  end)
  return ok and type(devices) == "table" and devices or {}
end

local function c4Bindings(id)
  local out = {}
  for _, api in ipairs({ "GetNetworkBindingsByDevice", "GetBindingsByDevice" }) do
    local ok, raw = pcall(function()
      return C4[api](C4, id)
    end)
    if ok and type(raw) == "table" then
      out[#out + 1] = raw
    end
  end
  return out
end

--- GET a URL from the controller. `done(ok, body)` is called exactly once.
--- Replaceable (`M.get = ...`) so a test never touches the network.
function M.get(url, done)
  local called = false
  local function once(ok, body)
    if not called then
      called = true
      done(ok, body)
    end
  end
  local started = pcall(function()
    C4:url()
      :SetOptions({ timeout = M.TIMEOUT_SECONDS, connect_timeout = M.TIMEOUT_SECONDS, fail_on_error = false })
      :OnDone(function(_, responses, errCode)
        local last = type(responses) == "table" and responses[#responses] or nil
        once(errCode == 0 and last ~= nil and tonumber(last.code) == 200, last and last.body)
      end)
      :Get(url, {})
  end)
  if not started then
    once(false)
  end
end

local function answersAs(body, service)
  if type(body) == "table" then
    return body.service == service
  end
  return type(body) == "string" and body:find('"service":"' .. service .. '"', 1, true) ~= nil
end

local Resolver = {}
Resolver.__index = Resolver

--- @param deps table {
---   port = number, service = string  -- the relay's port and its /ping name
---   configured = fun():string|nil    -- the App Relay Address property
---   onChange = fun(host)|nil         -- the published host changed
---   controllerAddress, devices, bindings, get  -- optional, for tests
--- }
function M.new(deps)
  local self = setmetatable({}, Resolver)
  self.deps = deps or {}
  self.verified = nil -- the address this relay answered on
  self.checking = false
  self.checked = false -- a full pass has finished
  self.misses = 0 -- passes in a row with no answer
  self.lastCheck = nil
  return self
end

function Resolver:_configured()
  local value = trim(self.deps.configured and self.deps.configured() or "")
  if value ~= "" and value:lower() ~= "auto" then
    return value
  end
  return nil
end

function Resolver:_api()
  local addr = (self.deps.controllerAddress or c4ControllerAddress)()
  return M.isRoutable(addr) and trim(addr) or nil
end

--- The addresses worth asking, in order, without repeats.
function Resolver:candidates()
  local out, seen = {}, {}
  local function add(addr)
    if addr ~= nil and not seen[addr] then
      seen[addr] = true
      out[#out + 1] = addr
    end
  end
  add(self:_api())
  local devices = (self.deps.devices or c4Devices)()
  local ids = {}
  for rawId, device in pairs(devices) do
    local id = tonumber(rawId)
    local file = tostring((type(device) == "table" and device.driverFileName) or "")
    if id ~= nil and file:find("^control4_") ~= nil then
      ids[#ids + 1] = id
    end
  end
  table.sort(ids)
  for _, id in ipairs(ids) do
    for _, raw in ipairs((self.deps.bindings or c4Bindings)(id)) do
      for _, addr in ipairs(M.addresses(raw)) do
        add(addr)
      end
    end
  end
  return out
end

--- The host to publish, and how sure it is:
---   "override"     the dealer set it
---   "confirmed"    this relay answered on it
---   "unconfirmed"  the controller API says so; not (yet) answered
---   "unknown"      nothing to publish ("")
--- @return string host, string state
function Resolver:host()
  local configured = self:_configured()
  if configured ~= nil then
    return configured, "override"
  end
  if self.verified ~= nil then
    return self.verified, "confirmed"
  end
  local api = self:_api()
  if api ~= nil then
    return api, "unconfirmed"
  end
  return "", "unknown"
end

--- Whether a pass has finished without any candidate answering.
function Resolver:unanswered()
  return self.checked and self.verified == nil and self:_configured() == nil
end

--- Asks the candidates, one at a time, until this relay answers on one.
--- Safe to call often: one pass at a time, and none while an override is set.
function Resolver:check()
  if self.checking then
    return
  end
  if self:_configured() ~= nil then
    self.verified, self.checked = nil, false
    return
  end
  local list = self:candidates()
  local before = self:host()
  local port, service = tonumber(self.deps.port), tostring(self.deps.service or "")
  local get = self.deps.get or M.get
  self.lastCheck = (self.deps.now or os.time)()
  local function finish(addr)
    self.checking, self.checked, self.verified = false, true, addr
    self.misses = addr == nil and (self.misses + 1) or 0
    local after = self:host()
    if after ~= before and self.deps.onChange ~= nil then
      pcall(self.deps.onChange, after)
    end
  end
  if #list == 0 or port == nil then
    finish(nil)
    return
  end
  self.checking = true
  local i = 0
  local function nextOne()
    i = i + 1
    local addr = list[i]
    if addr == nil then
      finish(nil)
      return
    end
    -- Each candidate is settled once, whether the transport answers, answers
    -- twice, or throws.
    local settled = false
    local function settle(ok, body)
      if settled or not self.checking then
        return
      end
      settled = true
      if ok and answersAs(body, service) then
        finish(addr)
      else
        nextOne()
      end
    end
    if not pcall(get, string.format("http://%s:%d/ping", addr, port), settle) then
      settle(false)
    end
  end
  nextOne()
end

--- Runs a pass when one is due: every RECHECK_SECONDS once confirmed, and
--- after a pass with no answer at 1, 2, 4, 8 minutes and then that often too.
--- Meant for a driver's one-minute status timer.
function Resolver:checkIfDue()
  local now = (self.deps.now or os.time)()
  local wait = M.RECHECK_SECONDS
  if self.verified == nil then
    wait = math.min(wait, 60 * 2 ^ math.max(0, math.min(self.misses, 5) - 1))
  end
  if self.lastCheck == nil or now - self.lastCheck >= wait then
    self:check()
  end
end

--- The App Data Relay status line for a listening relay.
function Resolver:statusLine()
  local port = tonumber(self.deps.port) or 0
  local host, state = self:host()
  if state == "unknown" then
    return string.format("Listening :%d - controller address UNKNOWN, set App Relay Address", port)
  end
  local line = string.format("Listening :%d - serving http://%s:%d to the app", port, host, port)
  if state == "unconfirmed" then
    line = line .. (self.checked and " (no answer on it: check App Relay Address)" or " (checking)")
  end
  return line
end

return M
