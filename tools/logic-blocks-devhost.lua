#!/usr/bin/env luajit
--- Logic Blocks development host: the REAL block runtime, sandbox, app
--- document and relay router, driven over stdin/stdout by
--- tools/logic-blocks-dev.py.
---
--- This is how the dealer page is developed and browser-tested without a
--- controller. It runs the Lua the driver ships (src/logic/*); only the
--- socket, the clock, the timers and the device variables are stand-ins. It
--- is NOT evidence of controller behaviour: there is no Director, no
--- Composer and no equipment here.
---
--- Protocol: one JSON object per line, in and out.
---   in   {"type":"tick","now":1800000000.25}
---   in   {"type":"http","now":…,"method":"GET","path":"/state","query":{…},"body":""}
---   out  {"status":"200 OK","contentType":"application/json","body":"…"}
---
--- Environment:
---   LB_DEV_SCENARIO  house (default) | empty | restore_failed
---   LB_DEV_TOKEN     the page token (default below)
---
--- Dev-only routes (never in the driver), all under /__dev:
---   POST /__dev/command  {slot, command, value, by, input}   a Composer command
---   POST /__dev/variable {device, variable, value|null}      a device variable changes / goes away
---   POST /__dev/restart  {down_seconds}                       save, wait, restore
---   POST /__dev/readonly {on}                                 licence read-only

package.path = "src/?.lua;vendor/?.lua;test/?.lua;" .. package.path
C4 = C4 or {}
require("c4_shim")
require("drivers-common-public.global.lib")

local JSON = require("JSON")
local Defs = require("logic.blockdefs")
local Blocks = require("logic.blocks")
local Sandbox = require("logic.sandbox")
local AppState = require("logic.appstate")
local Relay = require("logic.relay")

local SCENARIO = os.getenv("LB_DEV_SCENARIO") or "house"
local TOKEN = os.getenv("LB_DEV_TOKEN") or "devblocks0123456789abcdef"
local PAGE = "drivers/smartbuildos-logic-pack/www/app/index.html"

local clock = 0
local startedAt = nil
local timers = {}
local order = 0
local fired = {} -- what a controller would have fired (dev log only)
local readOnly = false
local blocks, sandbox
local ids = 0

-- Stand-in devices. `nil` value = the variable does not exist.
local devices = {
  [60] = { name = "Front Door Contact", vars = { [1001] = { name = "CONTACT_STATE", value = "closed" } } },
  [61] = { name = "Office Motion", vars = { [1002] = { name = "MOTION_STATE", value = "0" } } },
  [82] = { name = "Rack Sensor", vars = { [1000] = { name = "TEMPERATURE_F", value = "81" } } },
  [90] = { name = "Rack Fan Relay", vars = { [1] = { name = "RELAY_STATE", value = "0" } } },
}

local function variable(dev, var)
  local d = devices[dev]
  return d and d.vars[var] or nil
end

local function localDay(t)
  return os.date("%Y-%m-%d", math.floor(t))
end

local function newBlocks()
  return Blocks.new({
    origin = "live",
    now = function()
      return clock
    end,
    schedule = function(id, ms, fn)
      order = order + 1
      timers[id] = { at = clock + ms / 1000, fn = fn, order = order }
    end,
    cancel = function(id)
      timers[id] = nil
    end,
    localDay = localDay,
    emit = function(slot, kind)
      fired[#fired + 1] = { at = clock, event = Defs.eventName(slot, kind) }
      while #fired > 200 do
        table.remove(fired, 1)
      end
    end,
    outputs = function() end,
    watch = function(dev, var)
      local v = variable(dev, var)
      if v == nil then
        return false,
          devices[dev] == nil and ("device " .. dev .. " is not in the project")
            or ("variable " .. var .. " is not on device " .. dev)
      end
      -- Director reports the current value the moment a listener is set.
      order = order + 1
      timers["dev:open:" .. dev .. ":" .. var .. ":" .. order] = {
        at = clock,
        order = order,
        fn = function()
          blocks:variable(dev, var, v.value)
        end,
      }
      return true
    end,
    unwatch = function() end,
    newId = function()
      ids = ids + 1
      return "dev" .. ids
    end,
    changed = function() end,
    refused = function() end,
    selfDevice = 500,
  })
end

local function runTimers()
  local guard = 0
  while guard < 5000 do
    local bestId, best
    for id, t in pairs(timers) do
      if t.at <= clock and (best == nil or t.at < best.at or (t.at == best.at and t.order < best.order)) then
        bestId, best = id, t
      end
    end
    if bestId == nil then
      break
    end
    timers[bestId] = nil
    best.fn()
    guard = guard + 1
  end
end

local function make(raw)
  local def, problems = Defs.normalize(raw)
  assert(def, problems and table.concat(problems, "; "))
  local slot, why = blocks:create(def)
  assert(slot, why)
  runTimers()
  return slot
end

local function house()
  local driveway = make({
    type = "cooldown",
    name = "Driveway Welcome",
    tag = "Driveway",
    duration = "10m",
    notes = "Welcome scene is the Exterior > Welcome advanced lighting scene.",
  })
  local bath = make({
    type = "timer",
    name = "Bathroom Vacancy",
    tag = "Bathroom",
    duration = "15m",
    repeat_start = "restart",
    recovery = "cancel_if_missed",
  })
  local guest = make({ type = "flag", name = "Guest Override", tag = "House" })
  local greeting = make({ type = "once", name = "Daily Greeting", tag = "Kitchen" })
  make({
    type = "threshold",
    name = "Rack Temperature",
    tag = "Rack",
    upper = "85",
    lower = "78",
    units = "°F",
    inputs = {
      {
        used = true,
        label = "Rack temperature",
        device_id = 82,
        variable_id = 1000,
        device_name = "Rack Sensor",
        variable_name = "TEMPERATURE_F",
      },
    },
    feedback = {
      device_id = 90,
      variable_id = 1,
      device_name = "Rack Fan Relay",
      variable_name = "RELAY_STATE",
      expect = "1,on",
      within = "10s",
    },
  })
  make({
    type = "conditions",
    name = "Entry Ready",
    tag = "Entry",
    mode = "All",
    evaluation = "Continuous output",
    inputs = {
      {
        used = true,
        label = "Door closed",
        device_id = 60,
        variable_id = 1001,
        device_name = "Front Door Contact",
        variable_name = "CONTACT_STATE",
        true_when = "closed",
      },
      { used = true, label = "Alarm disarmed" },
    },
  })
  make({
    type = "stable",
    name = "Office Occupied",
    tag = "Office",
    duration = "30s",
    inputs = {
      {
        used = true,
        label = "Office motion",
        device_id = 61,
        variable_id = 1002,
        device_name = "Office Motion",
        variable_name = "MOTION_STATE",
        true_when = "1",
      },
    },
  })
  local mode = make({
    type = "selector",
    name = "House Mode",
    tag = "House",
    states = "Home, Away, Night",
    initial_state = "Home",
    transitions = "Home > Away, Home > Night, Away > Home, Night > Home",
  })
  local visitors = make({
    type = "counter",
    name = "Visitors Today",
    tag = "Entry",
    counter_threshold = "3",
    counter_comparison = ">=",
  })
  make({ type = "quiet", name = "Hallway Settled", tag = "Hallway", duration = "20s" })
  local old = make({ type = "flag", name = "Old Test Flag" })
  blocks:retire(old)
  -- A little history, the way programming would have produced it.
  blocks:input(driveway, "trigger")
  clock = clock + 180
  blocks:input(driveway, "trigger")
  blocks:input(bath, "start")
  blocks:input(guest, "set")
  blocks:input(greeting, "trigger")
  blocks:input(greeting, "trigger")
  blocks:input(mode, "set", { VALUE = "Night" })
  blocks:input(mode, "set", { VALUE = "Away" })
  blocks:input(visitors, "increment")
  blocks:input(visitors, "increment")
  runTimers()
end

local function start(now)
  clock = now - 200
  startedAt = clock
  blocks = newBlocks()
  if SCENARIO == "house" then
    house()
  elseif SCENARIO == "restore_failed" then
    blocks:restore({ schema = Blocks.SCHEMA, v = 99, blocks = {} })
  end
  clock = now
  runTimers()
end

local function info()
  return {
    now = clock,
    started_at = startedAt,
    version = "dev-host",
    status = "Online (development host)",
    pack_status = readOnly and "read-only (licence)" or "active",
    read_only = readOnly,
    license = { status = "Development host - no Agent", source = "-", tier = "-" },
    clock = {
      day = localDay(clock),
      tz = os.date("%Z"),
      utc_offset = os.date("%z"),
      basis = "Once Per Day uses the controller's local calendar day.",
    },
    legacy = { counters = 0, flags = 0, timers = 0, once = 0, state = "", note = "Development host: no classic keys." },
    transport = {
      kind = "DEVELOPMENT HOST (not a controller)",
      listening = true,
      port = 0,
      host = "localhost",
      host_state = "development",
      mirror = "off",
      remote = "Development host on this computer.",
    },
  }
end

local function readPage()
  local f = io.open(PAGE, "rb")
  if f == nil then
    return nil
  end
  local s = f:read("*a")
  f:close()
  return s
end

local function sandboxState()
  if sandbox == nil then
    return { ok = true, open = false }
  end
  local s = sandbox:state()
  s.ok, s.open = true, true
  return s
end

--- The same contract as the driver's lbSandbox.
local function sandboxOp(op, body)
  if op == nil then
    return sandboxState()
  end
  if op == "open" then
    local slot = tonumber(body.slot)
    local block = slot and blocks.blocks[slot] or nil
    if block == nil then
      return { ok = false, error = "that slot holds no block" }
    end
    local sources = {}
    for _, row in ipairs(blocks:view(slot).sources or {}) do
      if row.mode == "variable" and row.status == "ok" then
        sources[row.index] = row.value
      end
    end
    local sb, why =
      Sandbox.open({ def = Blocks.copy(block), slot = slot, now = clock, localDay = localDay, sources = sources })
    if sb == nil then
      return { ok = false, error = tostring(why) }
    end
    sandbox = sb
    return sandboxState()
  end
  if op == "close" then
    sandbox = nil
    return sandboxState()
  end
  if sandbox == nil then
    return { ok = false, error = "no sandbox is open" }
  end
  if op == "input" then
    sandbox:input(tostring(body.command or ""), { VALUE = body.value, BY = body.by, INPUT = body.input })
  elseif op == "source" then
    sandbox:source(tonumber(body.index) or 1, body.value, body.unavailable == true)
  elseif op == "advance" then
    local ok, why = sandbox:advance(tonumber(body.seconds))
    if not ok then
      return { ok = false, error = tostring(why) }
    end
  elseif op == "reset" then
    sandbox:reset()
  elseif op == "replay" then
    sandbox:replay(type(body.steps) == "table" and body.steps or nil)
  end
  return sandboxState()
end

local provider = {
  appHtml = readPage,
  state = function()
    return AppState.build(blocks, info())
  end,
  activity = function(query)
    return AppState.activity(blocks, query)
  end,
  export = function()
    return AppState.export(blocks, info())
  end,
  sandbox = sandboxOp,
  encode = function(t)
    return JSON:encode(t)
  end,
  decode = function(s)
    return JSON:decode(tostring(s))
  end,
}

local function dev(path, body)
  if path == "/__dev/command" then
    local ok, why = blocks:input(
      tonumber(body.slot),
      tostring(body.command or ""),
      { VALUE = body.value, BY = body.by, INPUT = body.input }
    )
    runTimers()
    return { ok = ok == true, info = tostring(why) }
  elseif path == "/__dev/variable" then
    local d, v = tonumber(body.device), tonumber(body.variable)
    if devices[d] == nil or devices[d].vars[v] == nil and body.value == nil then
      return { ok = false, error = "no such stand-in variable" }
    end
    if body.value == nil or body.value == JSON.null then
      devices[d].vars[v] = nil
      blocks:variableLost(d, v, "variable " .. v .. " is not on device " .. d)
    else
      devices[d].vars[v] = devices[d].vars[v] or { name = "VAR_" .. v }
      devices[d].vars[v].value = tostring(body.value)
      blocks:checkWatches(function(dd, vv)
        return variable(dd, vv) ~= nil, "gone"
      end)
      blocks:variable(d, v, tostring(body.value))
    end
    runTimers()
    return { ok = true }
  elseif path == "/__dev/restart" then
    local doc = blocks:serialize()
    blocks:stop()
    timers = {}
    clock = clock + (tonumber(body.down_seconds) or 0)
    startedAt = clock
    blocks = newBlocks()
    local report = blocks:restore(doc)
    runTimers()
    return { ok = true, report = report }
  elseif path == "/__dev/readonly" then
    readOnly = body.on == true
    blocks:setReadOnly(readOnly)
    runTimers()
    return { ok = true, read_only = readOnly }
  elseif path == "/__dev/fired" then
    return { ok = true, fired = fired }
  end
  return nil
end

local function handle(msg)
  if msg.now ~= nil then
    local now = tonumber(msg.now)
    if blocks == nil then
      start(now)
    elseif now > clock then
      clock = now
    end
  end
  runTimers()
  if msg.type == "tick" then
    if blocks ~= nil and (blocks.lastTick == nil or clock - blocks.lastTick >= 60) then
      blocks:tick(blocks.lastTick and 60 or nil)
    end
    return { ok = true }
  end
  local req = { method = msg.method, path = msg.path, query = msg.query or {}, body = msg.body or "" }
  if tostring(req.path):find("^/__dev/") then
    local body = {}
    if req.body ~= "" then
      local ok, doc = pcall(function()
        return JSON:decode(req.body)
      end)
      if ok and type(doc) == "table" then
        body = doc
      end
    end
    local result = dev(req.path, body)
    if result == nil then
      return { status = "404 Not Found", contentType = "application/json", body = '{"ok":false}' }
    end
    return { status = "200 OK", contentType = "application/json", body = JSON:encode(result) }
  end
  local result = Relay.route(req, TOKEN, provider)
  return { status = result.status, contentType = result.contentType, body = result.body }
end

io.stdout:setvbuf("line")
for line in io.lines() do
  local ok, msg = pcall(function()
    return JSON:decode(line)
  end)
  local out
  if ok and type(msg) == "table" then
    local okH, result = pcall(handle, msg)
    out = okH and result
      or {
        status = "500 Internal Server Error",
        contentType = "application/json",
        body = JSON:encode({ ok = false, error = tostring(result) }),
      }
  else
    out = { status = "400 Bad Request", contentType = "application/json", body = '{"ok":false}' }
  end
  io.stdout:write(JSON:encode(out), "\n")
  io.stdout:flush()
end
