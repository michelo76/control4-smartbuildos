-- Shared fake Director for the MQTT driver tests (not a test itself: the
-- Makefile only runs test/test_*.lua). One driver per process: the driver
-- files define globals (OnDriverInit, EC, OPC ...), so each test file loads
-- exactly one.
--
--   local H = dofile("test/mqtt_harness.lua")
--   local env = H.new({ driver = "smartbuildos-mqtt-broker", devices = {...}, self_id = 70 })
--   env.load()                  -- dofile the driver
--   env.advance(ms)             -- fake timers and os.time move together
--   env.sent / env.fired / env.vars / env.props / env.sockets

local H = {}

function H.new(cfg)
  C4 = C4 or {}
  require("c4_shim")
  JSON = require("JSON")

  local env = {
    clock = { now = 0, timers = {} },
    sent = {},
    fired = {},
    vars = {},
    props = {},
    sockets = {},
    proxy = {},
    renamed = {},
    devices = cfg.devices or {},
    persisted = {},
    deviceNames = cfg.names or {},
  }
  local SELF_ID = cfg.self_id or 70
  local clock = env.clock

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
  package.preload["drivers-common-public.global.url"] = function()
    return true
  end
  package.preload["cloud-client-byte"] = function()
    return true
  end
  package.preload["lib.persist"] = function()
    local P = {}
    local EMPTY = {}
    function P:get(key, default)
      if default == nil then
        default = EMPTY
      end
      if env.persisted[key] == nil then
        return default
      end
      return env.persisted[key]
    end
    function P:set(key, value)
      env.persisted[key] = value
    end
    function P:delete(key)
      env.persisted[key] = nil
    end
    function P:reset() end
    return P
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

  function env.advance(ms)
    local target = clock.now + ms
    while true do
      local bestId, bestAt
      for id, t in pairs(clock.timers) do
        if
          t.at <= target and (bestAt == nil or t.at < bestAt or (t.at == bestAt and tostring(id) < tostring(bestId)))
        then
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

  -- ── fake Director ────────────────────────────────────────────────────────
  C4.GetDevices = function()
    local out = {}
    for id, d in pairs(env.devices) do
      out[id] = d
    end
    out[SELF_ID] = out[SELF_ID] or { deviceName = "Self", driverFileName = cfg.driver .. ".c4z" }
    return out
  end
  C4.GetDeviceID = function()
    return SELF_ID
  end
  C4.GetDeviceData = function(_, id, key)
    if key == "name" then
      return env.deviceNames[id] or "Test Device"
    end
    return nil
  end
  C4.GetProxyDevices = function()
    return cfg.proxy_id
  end
  C4.RenameDevice = function(_, id, name)
    env.renamed[id] = name
  end
  C4.GetDriverConfigInfo = function(_, key)
    if key == "minimum_os_version" then
      return "3.3.2"
    elseif key == "model" then
      return "Test"
    end
    return "20261112.000000"
  end
  C4.SendToDevice = function(_, device, command, params, allowEmpty, logCommand)
    env.sent[#env.sent + 1] =
      { device = device, command = command, params = params or {}, allowEmpty = allowEmpty, logCommand = logCommand }
  end
  C4.SendToProxy = function(_, binding, command, params, kind)
    env.proxy[#env.proxy + 1] = { binding = binding, command = command, params = params or {}, kind = kind }
  end
  C4.FireEventByID = function(_, id)
    env.fired[#env.fired + 1] = id
  end
  C4.FireEvent = function() end
  C4.SetVariable = function(_, name, value)
    env.vars[name] = value
  end
  C4.AddVariable = function() end
  C4.AddEvent = function() end
  C4.UpdateProperty = function(_, name, value)
    env.props[name] = value
    Properties[name] = value
  end
  C4.UpdatePropertyList = function(_, name, list, default)
    env.props[name .. ".list"] = list
  end
  C4.GetVersionInfo = function()
    return { version = "4.2.0.0" }
  end

  -- ── fake TCP client and the broker's side of the wire ────────────────────
  C4.CreateTCPClient = function()
    local sock = { written = {}, closed = false, reads_armed = 0 }
    env.sockets[#env.sockets + 1] = sock
    function sock:OnConnect(cb)
      self.on_connect = cb
      return self
    end
    function sock:OnRead(cb)
      self.on_read = cb
      return self
    end
    function sock:OnDisconnect(cb)
      self.on_disconnect = cb
      return self
    end
    function sock:OnError(cb)
      self.on_error = cb
      return self
    end
    function sock:Connect(host, port)
      self.host, self.port = host, port
      return self
    end
    function sock:ReadUpTo()
      self.reads_armed = self.reads_armed + 1
    end
    function sock:Write(data)
      if self.closed then
        return false
      end
      self.written[#self.written + 1] = data
      if self.on_write then
        self.on_write(data)
      end
      return true
    end
    function sock:Close()
      self.closed = true
    end
    -- test controls
    function sock:accept()
      self.on_connect(self)
    end
    function sock:deliver(bytes)
      self.on_read(self, bytes)
    end
    function sock:drop()
      self.on_disconnect(self)
    end
    function sock:fail(code, msg)
      self.on_error(self, code or 111, msg or "connection refused")
    end
    return sock
  end

  -- ── properties from driver.xml ───────────────────────────────────────────
  Properties = {}
  local f = assert(io.open("drivers/" .. cfg.driver .. "/driver.xml"))
  local xml = f:read("*a")
  f:close()
  for block in xml:gmatch("<property>(.-)</property>") do
    local name = block:match("<name>(.-)</name>")
    local default = block:match("<default>(.-)</default>") or ""
    Properties[name] = default
  end
  env.xml = xml

  function env.load()
    dofile("drivers/" .. cfg.driver .. "/driver.lua")
  end

  function env.prop(name)
    return env.props[name] or Properties[name]
  end

  function env.firedCount(id)
    local n = 0
    for _, e in ipairs(env.fired) do
      if e == id then
        n = n + 1
      end
    end
    return n
  end

  --- Messages sent with this command (optionally to one device).
  function env.sentOf(command, device)
    local out = {}
    for _, s in ipairs(env.sent) do
      if s.command == command and (device == nil or s.device == device) then
        out[#out + 1] = s
      end
    end
    return out
  end

  function env.lastSent(command, device)
    local list = env.sentOf(command, device)
    return list[#list]
  end

  function env.proxyOf(command)
    local out = {}
    for _, s in ipairs(env.proxy) do
      if s.command == command then
        out[#out + 1] = s
      end
    end
    return out
  end

  function env.lastProxy(command)
    local list = env.proxyOf(command)
    return list[#list]
  end

  function env.clearSent()
    env.sent = {}
    env.proxy = {}
    env.fired = {}
  end

  return env
end

return H
