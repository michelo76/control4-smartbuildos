--- Smoke-runs ONE driver under the test shim, the way Director drives it, and
--- reports every Lua error it raises. Used by test/test_drivers_smoke.lua,
--- which runs it once per driver in its own interpreter so no driver's
--- globals leak into the next.
---
---   luajit tools/smoke-driver.lua drivers/<name>      (from the repo root)
---
--- What it does, in order, on a virtual clock (no real time passes):
---   1. Properties get the defaults driver.xml declares, then driver.lua is
---      loaded and OnDriverInit / OnDriverLateInit run.        phase "init"
---   2. Every writable property is set to another valid value, then (for a
---      STRING) to an empty string, then back to its default, each followed
---      by OnPropertyChanged.                                  phase "properties"
---   3. Every <command> runs with dummy parameters of the declared types,
---      and every <action> runs as Director sends it, LUA_ACTION. phase "commands"
---   4. Ten minutes pass, so every timer fires at least once. phase "timers"
---   5. OnDriverDestroyed, then the driver is loaded again with the same
---      persisted data and properties, as after a Director restart, and runs
---      for two more minutes.                                  phase "reload"
---
--- An error is: a Lua error thrown out of any of those calls, a handler
--- error the common library catches (ON_HANDLER_ERROR), an error inside a
--- timer callback, or a printed "stack traceback:" (a driver that catches
--- its own error and prints it). The shim has no network, so nothing leaves
--- the machine; C4 methods the shim lacks return nil and are listed.
---
--- Output: one `ERROR <phase> <where>: <message>` line per error, then
--- `SUMMARY errors=<n> commands=<n> actions=<n> properties=<n> timers=<fired>`.
--- Exit code 0 when there were no errors, 1 otherwise, 2 when the driver
--- could not even be found.

local dir = arg[1]
if dir == nil then
  io.stderr:write("usage: smoke-driver.lua drivers/<name>\n")
  os.exit(2)
end
dir = dir:gsub("/+$", "")

local function readFile(path)
  local f = io.open(path, "r")
  if f == nil then
    return nil
  end
  local s = f:read("*a")
  f:close()
  return s
end

local xml = readFile(dir .. "/driver.xml")
local driverPath = dir .. "/driver.lua"
if xml == nil or readFile(driverPath) == nil then
  io.stderr:write("no driver.xml or driver.lua in " .. dir .. "\n")
  os.exit(2)
end

package.path = table.concat({
  dir .. "/?.lua",
  "test/?.lua",
  "src/?.lua",
  "src/?/init.lua",
  "vendor/?.lua",
  "vendor/?/init.lua",
  package.path,
}, ";")

-- ── output capture ──────────────────────────────────────────────────────────
-- Drivers print a lot; keep the console quiet and look only for tracebacks.
local realPrint = print
local errors = {}
local phase = "load"

local function firstLine(s)
  s = tostring(s or "")
  return (s:match("^[^\n]*") or s):sub(1, 300)
end

local function addError(where, msg)
  errors[#errors + 1] = { phase = phase, where = where, msg = firstLine(msg) }
end

print = function(...)
  local parts = {}
  for i = 1, select("#", ...) do
    parts[#parts + 1] = tostring((select(i, ...)))
  end
  local line = table.concat(parts, " ")
  -- The common handlers print "<Handler> error: <traceback>" and then call
  -- ON_HANDLER_ERROR, which records it; any other printed traceback is a
  -- driver catching its own error.
  if
    line:find("stack traceback:", 1, true)
    and not line:match("^On%a+ error:")
    and not line:match("^ExecuteCommand error:")
  then
    addError("printed traceback", line)
  end
end

require("c4_shim")

-- What the controller has that the shim does not: the DriverCentral cloud
-- client (a stub, as the driver suites use), the driver's own XML through
-- GetDriverConfigInfo, a real OS version, and the C4: forms of persistence.
package.preload["cloud-client-byte"] = function()
  return true
end

function C4:GetDriverConfigInfo(key)
  if type(key) ~= "string" then
    return nil
  end
  local v = xml:match("<" .. key .. ">%s*(.-)%s*</" .. key .. ">")
  if key == "version" and (v == nil or v == "") then
    return "20260101.000000"
  end
  return v
end

function C4:GetVersionInfo()
  return { version = "4.0.0.000000", buildtype = "", builddate = "", buildtime = "", brand = "Control4" }
end

-- C4:url() is the controller's HTTP request object. Here every method is
-- accepted and returns the request, so calls chain, and nothing is sent or
-- ever answered: a driver must cope with a request that never completes.
function C4:url()
  local req = {}
  return setmetatable(req, {
    __index = function()
      return function()
        return req
      end
    end,
  })
end

-- Bound now: a library may later redefine the globals to call these.
local shimGet, shimSet, shimDelete = PersistGetValue, PersistSetValue, PersistDeleteValue
function C4:PersistGetValue(key, encrypted)
  return shimGet(key, encrypted)
end
function C4:PersistSetValue(key, value, encrypted)
  return shimSet(key, value, encrypted)
end
function C4:PersistDeleteValue(key)
  return shimDelete(key)
end

-- ── virtual clock ───────────────────────────────────────────────────────────
local clock = { now = 0, seq = 0, timers = {}, fired = 0 }

function C4:SetTimer(delay, fn, repeating)
  clock.seq = clock.seq + 1
  local t = { id = clock.seq, at = clock.now + math.max(tonumber(delay) or 0, 1), fn = fn }
  if repeating then
    t.every = math.max(tonumber(delay) or 0, 1)
  end
  clock.timers[t.id] = t
  -- The callback gets this same handle back, as on the controller: the
  -- common timer library looks its function up by it.
  local handle = {}
  function handle.Cancel()
    clock.timers[t.id] = nil
  end
  t.handle = handle
  return handle
end

function C4:GetTime()
  return clock.now
end

local function advance(ms)
  local target = clock.now + ms
  local fired = 0
  while fired < 100000 do
    local best
    for _, t in pairs(clock.timers) do
      if t.at <= target and (best == nil or t.at < best.at or (t.at == best.at and t.id < best.id)) then
        best = t
      end
    end
    if best == nil then
      break
    end
    clock.now = best.at
    if best.every then
      best.at = clock.now + best.every
    else
      clock.timers[best.id] = nil
    end
    fired = fired + 1
    clock.fired = clock.fired + 1
    local ok, err = xpcall(function()
      best.fn(best.handle, 0)
    end, debug.traceback)
    if not ok then
      addError("timer", err)
    end
  end
  clock.now = target
end

-- ── C4 methods the shim lacks ───────────────────────────────────────────────
-- Return what Director returns when there is nothing: an empty table for the
-- calls that list things, nil otherwise. Each name is reported once.
local missing = {}
local LISTS = {
  GetDevices = true,
  GetDevicesByC4iName = true,
  GetBoundConsumerDevices = true,
  GetBoundProviderDevice = false,
  GetDeviceVariables = true,
  GetProxyDevices = true,
  GetProxyDevicesById = true,
  GetBindingsByDevice = true,
  GetRoomsByFloor = true,
  GetNetworkConnections = true,
  GetDriverConfigInfo = false,
}
setmetatable(C4, {
  __index = function(_, name)
    missing[name] = true
    if LISTS[name] then
      return function()
        return {}
      end
    end
    return function()
      return nil
    end
  end,
})

-- ── driver.xml ──────────────────────────────────────────────────────────────
local function tag(body, name)
  local v = body:match("<" .. name .. ">%s*(.-)%s*</" .. name .. ">")
  if v == nil then
    return nil
  end
  v = v:gsub("<!%[CDATA%[(.-)%]%]>", "%1")
  return (v:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&apos;", "'"):gsub("&amp;", "&"))
end

local function items(body)
  local out = {}
  local block = body:match("<items>(.-)</items>")
  if block then
    for item in block:gmatch("<item>%s*(.-)%s*</item>") do
      out[#out + 1] = item
    end
  end
  return out
end

local function section(name)
  return xml:match("<" .. name .. ">(.-)</" .. name .. ">") or ""
end

local configBlock = section("config")
local properties = {}
for body in (configBlock:match("<properties>(.-)</properties>") or ""):gmatch("<property>(.-)</property>") do
  local name = tag(body, "name")
  if name then
    properties[#properties + 1] = {
      name = name,
      type = (tag(body, "type") or "STRING"):upper(),
      default = tag(body, "default") or "",
      readonly = (tag(body, "readonly") or ""):lower() == "true",
      min = tonumber(tag(body, "minimum") or ""),
      max = tonumber(tag(body, "maximum") or ""),
      items = items(body),
    }
  end
end

local commands = {}
for body in (configBlock:match("<commands>(.-)</commands>") or ""):gmatch("<command>(.-)</command>") do
  local name = tag(body, "name")
  if name then
    local params = {}
    for pbody in body:gmatch("<param>(.-)</param>") do
      params[#params + 1] = {
        name = tag(pbody, "name"),
        type = (tag(pbody, "type") or "STRING"):upper(),
        min = tonumber(tag(pbody, "minimum") or ""),
        items = items(pbody),
      }
    end
    commands[#commands + 1] = { name = name, params = params }
  end
end

local actions = {}
for body in (configBlock:match("<actions>(.-)</actions>") or ""):gmatch("<action>(.-)</action>") do
  local cmd = tag(body, "command")
  if cmd then
    actions[#actions + 1] = cmd
  end
end

--- A value Composer could hand over for this type, other than `current`.
local function anotherValue(p, current)
  local t = p.type
  if t == "LIST" or t == "DYNAMIC_LIST" then
    for _, item in ipairs(p.items) do
      if item ~= current then
        return item
      end
    end
    return p.items[1]
  elseif t == "BOOL" then
    return current == "True" and "False" or "True"
  elseif t == "RANGED_INTEGER" or t == "RANGED_FLOAT" or t == "NUMBER" then
    local lo = p.min or 0
    local hi = p.max or (lo + 10)
    local v = (tostring(lo) == current) and hi or lo
    return tostring(t == "RANGED_FLOAT" and v or math.floor(v))
  elseif t == "LABEL" or t == "IMAGE_JPEG" then
    return nil
  elseif t == "DEVICE_SELECTOR" or t == "VARIABLE_SELECTOR" then
    return ""
  end
  return current == "smoke test" and "smoke test 2" or "smoke test"
end

local function paramValue(p)
  local t = p.type
  if t == "LIST" or t == "DYNAMIC_LIST" then
    return p.items[1] or ""
  elseif t == "BOOL" then
    return "True"
  elseif t == "RANGED_INTEGER" or t == "RANGED_FLOAT" or t == "NUMBER" or t == "INTEGER" then
    return tostring(p.min or 1)
  elseif t == "DEVICE_SELECTOR" then
    return "0"
  elseif t == "VARIABLE_SELECTOR" or t == "VARIABLE_SELECTOR_VALUE" then
    return ""
  end
  return "smoke"
end

-- ── the run ─────────────────────────────────────────────────────────────────
-- Both hooks are nil on a controller, where the common library then drops
-- the error silently (a failing timer callback leaves no trace at all).
local function hooks()
  ON_HANDLER_ERROR = function(source, err)
    addError(source, err)
  end
  ON_TIMER_ERROR = function(timerId, err)
    addError("timer " .. tostring(timerId), err)
  end
end
hooks()

local function call(where, fn, ...)
  if type(fn) ~= "function" then
    return
  end
  local args = { n = select("#", ...), ... }
  local ok, err = xpcall(function()
    return fn(unpack(args, 1, args.n))
  end, debug.traceback)
  if not ok then
    addError(where, err)
  end
end

for _, p in ipairs(properties) do
  Properties[p.name] = p.default
end

local baseline = {}
for k in pairs(package.loaded) do
  baseline[k] = true
end
local globalsBefore = {}
for k in pairs(_G) do
  globalsBefore[k] = true
end

local function loadDriver()
  local chunk, err = loadfile(driverPath)
  if chunk == nil then
    addError("driver.lua", err)
    return false
  end
  local before = #errors
  call("driver.lua", chunk)
  return #errors == before
end

phase = "init"
if loadDriver() then
  call("OnDriverInit", rawget(_G, "OnDriverInit"), "DIT_ADDING")
  call("OnDriverLateInit", rawget(_G, "OnDriverLateInit"), "DIT_ADDING")
  advance(2 * 60 * 1000)

  phase = "properties"
  local changed = 0
  for _, p in ipairs(properties) do
    if not p.readonly then
      local v = anotherValue(p, Properties[p.name])
      if v ~= nil then
        changed = changed + 1
        Properties[p.name] = v
        call("OnPropertyChanged " .. p.name, rawget(_G, "OnPropertyChanged"), p.name)
        advance(1000)
        if p.type == "STRING" then
          Properties[p.name] = ""
          call("OnPropertyChanged " .. p.name .. " (empty)", rawget(_G, "OnPropertyChanged"), p.name)
          advance(1000)
        end
        Properties[p.name] = p.default
        call("OnPropertyChanged " .. p.name .. " (default)", rawget(_G, "OnPropertyChanged"), p.name)
        advance(1000)
      end
    end
  end

  phase = "commands"
  for _, c in ipairs(commands) do
    local params = {}
    for _, p in ipairs(c.params) do
      if p.name then
        params[p.name] = paramValue(p)
      end
    end
    call("command " .. c.name, rawget(_G, "ExecuteCommand"), c.name, params)
    advance(1000)
  end
  for _, a in ipairs(actions) do
    call("action " .. a, rawget(_G, "ExecuteCommand"), "LUA_ACTION", { ACTION = a })
    advance(1000)
  end

  phase = "timers"
  advance(10 * 60 * 1000)

  phase = "reload"
  call("OnDriverDestroyed", rawget(_G, "OnDriverDestroyed"))
  clock.timers = {}
  -- A new Lua state on the controller: the driver's globals and modules go,
  -- the persisted data and the property values stay.
  for k in pairs(_G) do
    if not globalsBefore[k] then
      _G[k] = nil
    end
  end
  for k in pairs(package.loaded) do
    if not baseline[k] then
      package.loaded[k] = nil
    end
  end
  hooks()
  if loadDriver() then
    call("OnDriverInit", rawget(_G, "OnDriverInit"), "DIT_STARTUP")
    call("OnDriverLateInit", rawget(_G, "OnDriverLateInit"), "DIT_STARTUP")
    advance(2 * 60 * 1000)
  end
  properties.changed = changed
end

print = realPrint
for _, e in ipairs(errors) do
  print(string.format("ERROR %s %s: %s", e.phase, e.where, e.msg))
end
local names = {}
for name in pairs(missing) do
  names[#names + 1] = name
end
table.sort(names)
if #names > 0 then
  print("SHIM-MISSING " .. table.concat(names, ","))
end
print(
  string.format(
    "SUMMARY errors=%d commands=%d actions=%d properties=%d timers=%d",
    #errors,
    #commands,
    #actions,
    properties.changed or 0,
    clock.fired
  )
)
os.exit(#errors == 0 and 0 or 1)
