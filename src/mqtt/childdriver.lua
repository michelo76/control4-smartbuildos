--- The common half of every MQTT child driver (contact, motion, light,
--- shade): finding the Broker driver, the hello handshake, the state and
--- availability messages, publishing a command through the broker, and the
--- status properties every child shows. A child supplies what is specific:
--- which topics it listens to, how a state payload becomes proxy
--- notifications, and which proxy commands become which payloads.
---
--- Usage from drivers/smartbuildos-mqtt-<kind>/driver.lua:
---   local base = require("mqtt.childdriver")
---   base.install({
---     kind = "light", logName = "MqttLight",
---     topics = function() return stateTopic, availabilityTopic end,
---     onState = function(payload, info) return ok, why end,   -- role "state"
---     describe = function() return "On 40%" end,
---     onOnline = function(online) end,                        -- optional
---   })
---
--- Licensing: none of its own. The Broker holds the licence and tells the
--- child when it has gone read-only (publishing is then refused here).

local log = require("lib.logging")
local Link = require("mqtt.link")
local Topics = require("mqtt.topics")
local Payload = require("mqtt.payload")

local M = {}

M.EVENT_AVAILABLE, M.EVENT_UNAVAILABLE, M.EVENT_COMMAND_FAILED = 1, 2, 3
M.FIRST_KIND_EVENT = 4

local HELLO_TIMER = "MqttChildHello"
local REHELLO_TIMER = "MqttChildRehello"
local PAINT_TIMER = "MqttChildPaint"
local PAINT_EVERY = 3 -- seconds between repaints of the message properties

local state = {
  opts = {},
  brokerId = nil,
  acked = false,
  brokerState = "unknown", -- connected | disconnected | unknown
  licence = "ok",
  available = nil, -- true | false | nil (unknown / not tracked)
  lastMessageAt = nil,
  lastPaintAt = 0,
  paintPending = false,
  messages = 0,
  lastNote = "none yet",
}

local function fire(id)
  pcall(function()
    C4:FireEventByID(id)
  end)
end

local function trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

function M.prop(name)
  return trim(Properties[name])
end

--- True for a property set to "Yes".
function M.flag(name)
  return trim(Properties[name]):lower() == "yes"
end

-- ─── Broker ─────────────────────────────────────────────────────────────────

local function findBroker()
  local ok, devices = pcall(function()
    return C4:GetDevices({})
  end)
  if not ok then
    return nil
  end
  local ids = Link.findDevices(devices, Link.BROKER_FILES)
  state.brokerId = ids[1]
  return state.brokerId
end

local function toBroker(command, params)
  local broker = findBroker()
  if not broker then
    UpdateProperty("Broker Link", "No SmartBuildOS MQTT Broker found in this project")
    return false
  end
  local ok = pcall(function()
    C4:SendToDevice(broker, command, params, true, false)
  end)
  return ok
end

function M.brokerConnected()
  return state.brokerState == "connected"
end

--- The device can be controlled/trusted: the broker is up and the device
--- itself has not said it is offline.
function M.online()
  return state.brokerState == "connected" and state.available ~= false
end

function M.available()
  return state.available
end

-- ─── Status properties ─────────────────────────────────────────────────────

local function paintNow()
  state.paintPending = false
  state.lastPaintAt = os.time()
  UpdateProperty("Last Message", state.lastNote)
  UpdateProperty(
    "Last Seen",
    state.lastMessageAt
        and (os.date("%Y-%m-%d %H:%M:%S", state.lastMessageAt) .. " (" .. state.messages .. " messages)")
      or "never"
  )
  UpdateProperty(
    "Device Availability",
    state.available == nil and "not reported" or (state.available and "online" or "offline")
  )
  if state.opts.describe then
    local ok, text = pcall(state.opts.describe)
    UpdateProperty("Current State", ok and tostring(text) or "?")
  end
end

--- A busy topic must not turn into a property write per message.
local function paint(force)
  if force or os.time() - state.lastPaintAt >= PAINT_EVERY then
    paintNow()
  elseif not state.paintPending then
    state.paintPending = true
    SetTimer(PAINT_TIMER, PAINT_EVERY * ONE_SECOND, paintNow)
  end
end
M.paint = paint

local function paintBroker()
  local text
  if state.brokerId == nil then
    text = "No SmartBuildOS MQTT Broker found in this project"
  elseif not state.acked then
    text = "Asked the broker driver, no answer yet"
  elseif state.brokerState == "connected" then
    text = "Connected" .. (state.licence == "read-only" and " (view only: licence)" or "")
  else
    text = "Broker driver found, not connected to the MQTT broker"
  end
  UpdateProperty("Broker Link", text)
  UpdateProperty(
    "Control",
    (state.brokerState == "connected" and state.licence ~= "read-only") and "enabled" or "view only"
  )
end

-- ─── Topics and hello ───────────────────────────────────────────────────────

--- The topic and availability topic, validated. A wildcard is refused: one
--- child is one device.
local function readTopics()
  local stateTopic, availability = state.opts.topics()
  local problems = {}
  local function clean(topic, what)
    topic = trim(topic)
    if topic == "" then
      return nil
    end
    local ok, why = Topics.validName(topic)
    if not ok then
      problems[#problems + 1] = what .. ": " .. why
      return nil
    end
    return topic
  end
  return clean(stateTopic, "State Topic"), clean(availability, "Availability Topic"), problems
end

function M.sendHello()
  local stateTopic, availability, problems = readTopics()
  if #problems > 0 then
    M.result("not listening: " .. problems[1], true)
  end
  local filters = {}
  if stateTopic then
    filters[1] = stateTopic
  end
  local label = ""
  pcall(function()
    local proxy = C4:GetProxyDevices()
    label = C4:GetDeviceData((type(proxy) == "number" and proxy > 0) and proxy or C4:GetDeviceID(), "name") or ""
  end)
  local sent = toBroker(Link.CMD.HELLO, {
    requester = tostring(C4:GetDeviceID()),
    kind = tostring(state.opts.kind),
    name = tostring(label),
    filters = Link.encodeFilters(filters),
    availability = availability or "",
    availability_field = M.prop("Availability Field"),
  })
  paintBroker()
  return sent
end

--- A property edit that changes what the broker should listen to.
local function rehelloSoon()
  if not gInitialized then
    return
  end
  SetTimer(REHELLO_TIMER, 1500, function()
    state.available = nil
    M.sendHello()
    paint(true)
  end)
end

-- ─── Results ────────────────────────────────────────────────────────────────

function M.result(text, isFailure)
  UpdateProperty("Last Result", text .. " (" .. os.date("%H:%M:%S") .. ")")
  if isFailure then
    fire(M.EVENT_COMMAND_FAILED)
  end
end

--- Sends a command through the broker. The proxy shows what the device
--- reports on its state topic, never what was asked for.
--- @return boolean accepted by this driver (the broker answers with the result)
function M.publish(topic, payload, opts)
  opts = opts or {}
  topic = trim(topic)
  if topic == "" then
    M.result("no Set Topic is configured", true)
    return false
  end
  local ok, why = Topics.validName(topic)
  if not ok then
    M.result("Set Topic: " .. why, true)
    return false
  end
  if state.licence == "read-only" then
    M.result("refused: the SmartBuildOS licence has made the bridge read-only", true)
    return false
  end
  if state.brokerState ~= "connected" then
    M.result("refused: the MQTT broker is not connected", true)
    return false
  end
  local sent = toBroker(Link.CMD.PUBLISH, {
    requester = tostring(C4:GetDeviceID()),
    topic = topic,
    payload = tostring(payload or ""),
    retain = opts.retain and "true" or "false",
    qos = tostring(opts.qos or 0),
  })
  if not sent then
    M.result("refused: no MQTT Broker driver in this project", true)
    return false
  end
  M.result("sent to " .. topic, false)
  return true
end

-- ─── Lifecycle ──────────────────────────────────────────────────────────────

local function registerEvents(extra)
  for _, e in ipairs({
    { M.EVENT_AVAILABLE, "Device Available", "The device is reachable again (its availability topic says online)" },
    { M.EVENT_UNAVAILABLE, "Device Unavailable", "The device reported itself offline" },
    { M.EVENT_COMMAND_FAILED, "Command Failed", "A command could not be sent (see Last Result)" },
  }) do
    pcall(function()
      C4:AddEvent(e[1], e[2], e[3])
    end)
  end
  for _, e in ipairs(extra or {}) do
    pcall(function()
      C4:AddEvent(e[1], e[2], e[3])
    end)
  end
end

function M.install(opts)
  state.opts = opts or {}

  EC.suppressDebug = EC.suppressDebug or {}
  EC.suppressDebug["SBOS_MQTT_MESSAGE"] = true

  EC.SBOS_MQTT_ENTITY = function(tParams)
    tParams = tParams or {}
    local was = state.brokerState
    state.acked = true
    state.brokerState = tostring(tParams.state or "unknown")
    state.licence = tostring(tParams.licence or "ok")
    CancelTimer(HELLO_TIMER)
    if tostring(tParams.rejected or "") ~= "" then
      M.result(tostring(tParams.rejected), true)
    end
    paintBroker()
    if was ~= state.brokerState and state.opts.onOnline then
      pcall(state.opts.onOnline, M.online())
    end
    paint(true)
  end

  EC.SBOS_MQTT_BROKER_HELLO = function()
    M.sendHello()
  end

  EC.SBOS_MQTT_RESULT = function(tParams)
    tParams = tParams or {}
    if tostring(tParams.status) == "failed" then
      M.result("failed: " .. tostring(tParams.reason or "?"), true)
    end
  end

  EC.SBOS_MQTT_MESSAGE = function(tParams)
    tParams = tParams or {}
    local payload = tostring(tParams.payload or "")
    if tostring(tParams.role) == "availability" then
      local available = Payload.availability(payload, M.prop("Availability Field"))
      if available ~= nil and available ~= state.available then
        local was = state.available
        state.available = available
        if was ~= nil or available == false then
          fire(available and M.EVENT_AVAILABLE or M.EVENT_UNAVAILABLE)
        end
        if state.opts.onOnline then
          pcall(state.opts.onOnline, M.online())
        end
      end
      paint(true)
      return
    end
    state.lastMessageAt = os.time()
    state.messages = state.messages + 1
    local ok, okOrWhy, why =
      pcall(state.opts.onState, payload, { retain = tostring(tParams.retain) == "true", topic = tParams.topic })
    if not ok then
      state.lastNote = "error: " .. tostring(okOrWhy)
      log:error("State handler failed: %s", tostring(okOrWhy))
    elseif okOrWhy == false then
      state.lastNote = tostring(why or "not understood")
    else
      state.lastNote = "read " .. os.date("%H:%M:%S")
    end
    paint(false)
  end

  EC.REFRESH_FROM_BROKER = function()
    M.sendHello()
  end

  EC.PRINT_DIAGNOSTICS = function()
    local stateTopic, availability, problems = readTopics()
    log:print("== %s diagnostics ==", opts.logName or "MQTT child")
    log:print("  broker driver: %s", tostring(findBroker() or "NOT FOUND"))
    log:print("  broker link: %s, licence: %s", state.brokerState, state.licence)
    log:print("  state topic: %s", tostring(stateTopic))
    log:print(
      "  availability topic: %s (%s)",
      tostring(availability),
      state.available == nil and "not reported" or tostring(state.available)
    )
    for _, p in ipairs(problems) do
      log:print("  PROBLEM %s", p)
    end
    log:print("  messages read: %d, last: %s", state.messages, state.lastNote)
    if state.opts.describe then
      log:print("  state: %s", tostring(state.opts.describe()))
    end
  end

  TC.BROKER_CONNECTED = function()
    return M.brokerConnected()
  end
  TC.DEVICE_AVAILABLE = function()
    return state.available ~= false
  end

  OPC.State_Topic = rehelloSoon
  OPC.Availability_Topic = rehelloSoon
  OPC.Availability_Field = rehelloSoon

  OPC.Log_Level = function(value)
    log:setLogLevel(value)
    DEBUGPRINT = tostring(value):match("^5") ~= nil
  end
  OPC.Log_Mode = function(value)
    log:setLogMode(value)
  end
  OPC.Driver_Status = function()
    if not gInitialized then
      UpdateProperty("Driver Status", "Initializing", false)
    end
  end

  function OnDriverInit()
    --#ifdef DRIVERCENTRAL
    require("cloud-client-byte")
    C4:AllowExecute(false)
    --#else
    C4:AllowExecute(true)
    --#endif
    gInitialized = false
    log:setLogName(opts.logName or "MqttChild")
    log:setLogLevel(Properties["Log Level"])
    log:setLogMode(Properties["Log Mode"])
  end

  function OnDriverLateInit()
    if not CheckMinimumVersion("Driver Status") then
      return
    end
    registerEvents(opts.events)
    for p, _ in pairs(Properties) do
      pcall(OnPropertyChanged, p)
    end
    if opts.onLateInit then
      pcall(opts.onLateInit)
    end
    gInitialized = true
    UpdateProperty("Driver Status", "Online")
    pcall(function()
      UpdateProperty("Driver Version", tostring(C4:GetDriverConfigInfo("version")))
    end)
    M.sendHello()
    paint(true)
    -- Until the broker answers, ask again every minute (it may load later).
    SetTimer(HELLO_TIMER, 60 * ONE_SECOND, function()
      if not state.acked then
        M.sendHello()
      end
    end, true)
  end

  function OnDriverDestroyed()
    CancelTimer(HELLO_TIMER)
    CancelTimer(REHELLO_TIMER)
    CancelTimer(PAINT_TIMER)
  end
end

function M._reset()
  state = {
    opts = {},
    brokerId = nil,
    acked = false,
    brokerState = "unknown",
    licence = "ok",
    available = nil,
    lastMessageAt = nil,
    lastPaintAt = 0,
    paintPending = false,
    messages = 0,
    lastNote = "none yet",
  }
end

return M
