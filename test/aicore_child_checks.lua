-- Shared checks for the AI Core property of CHILD drivers (brief D7b,
-- conductor ruling 20). Every child family has a
-- test/test_<family>_aicore.lua that loads each of its drivers under the
-- shim with that family's own fakes and then runs `K.child(o)` here. Not a
-- test file itself (no test_ prefix).
--
-- What every child proves:
--   * driver.xml declares the read-only `AI Core` property, exact default;
--   * loading it pulls in sbos.aipresence and NEITHER sbos.aireport NOR
--     sbos.moduleclient;
--   * AI Core absent -> `Not installed`; AI Core added (OnDriverAdded) ->
--     the child value (`Installed — reports through ‹root›`, or `Installed —
--     this driver does not report` for a child of the Agent); removed
--     (OnItemRemoved) -> `Not installed`;
--   * the KI-42 fallback: with no system event at all, ordinary traffic
--     from the root corrects the value once 10 minutes have passed, and not
--     before;
--   * FRAME COUNT: over the whole AI Core cycle above the driver sent zero
--     frames of any kind to anyone (SendToDevice, SendToProxy,
--     SendToNetwork, SendUIRequest), and over its whole life no SBOS_MODULE_*
--     frame and nothing to the AI Core device;
--   * only closed values were painted; OnDriverDestroyed stops it.

local K = {}

K.pass, K.fail = 0, 0
function K.check(name, ok, detail)
  if ok then
    K.pass = K.pass + 1
    print("  ok   " .. name)
  else
    K.fail = K.fail + 1
    print("  FAIL " .. name .. (detail ~= nil and ("  -> " .. tostring(detail)) or ""))
  end
end

function K.finish()
  print(string.format("\n%d passed, %d failed", K.pass, K.fail))
  if K.fail > 0 then
    os.exit(1)
  end
end

K.AICORE_ID = 700
K.AICORE_FILE = "smartbuildos-ai-core.c4z"
K.XML =
  "<property><name>AI Core</name><type>STRING</type><default>Searching…</default><readonly>true</readonly></property>"

local function read(path)
  local f = assert(io.open(path, "rb"))
  local s = f:read("*a")
  f:close()
  return s
end

--- The driver's properties from driver.xml (name -> default).
function K.properties(dir)
  local props = {}
  local xml = read("drivers/" .. dir .. "/driver.xml"):gsub("<!%-%-.-%-%->", "")
  for block in xml:gmatch("<property>(.-)</property>") do
    local name = block:match("<name>%s*(.-)%s*</name>")
    if name ~= nil then
      props[name] = block:match("<default>(.-)</default>") or ""
    end
  end
  return props, xml
end

local function aiCoreXml(xml)
  for block in xml:gmatch("<property>(.-)</property>") do
    if block:match("<name>%s*(.-)%s*</name>") == "AI Core" then
      return (("<property>" .. block .. "</property>"):gsub(">%s+<", "><"))
    end
  end
  return nil
end

-- ── the world every child sees ──────────────────────────────────────────────
K.devices = {} -- what C4:GetDevicesByC4iName answers for the AI Core file
K.frames = {} -- every frame the driver sent: { kind, to, command }
K.systemEvents = {}
K.painted = {}
K.debounce = nil -- the aipresence debounce callback, when armed

local FRAME_FNS = { "SendToDevice", "SendToProxy", "SendToNetwork", "SendUIRequest" }

--- Installs the fakes: call after the family's own C4 fakes, before loading.
--- Wraps the family's frame functions (they keep working) to count frames.
function K.install()
  for _, fn in ipairs(FRAME_FNS) do
    local inner = C4[fn]
    C4[fn] = function(self, to, command, ...)
      K.frames[#K.frames + 1] = { kind = fn, to = to, command = command }
      if type(inner) == "function" then
        return inner(self, to, command, ...)
      end
    end
  end
  function C4:GetDevicesByC4iName(file)
    if file == K.AICORE_FILE then
      return K.devices
    end
    return {}
  end
  function C4:RegisterSystemEvent(id)
    K.systemEvents[#K.systemEvents + 1] = id
  end
end

--- After the driver loaded: catch the aipresence debounce timer and every
--- write to the AI Core property.
local function intercept(aipresence)
  local realSet = SetTimer
  if type(realSet) == "function" then
    SetTimer = function(id, ms, fn, repeating)
      if id == aipresence.TIMER then
        K.debounce = fn
        return
      end
      return realSet(id, ms, fn, repeating)
    end
  end
  local realUpdate = UpdateProperty
  if type(realUpdate) == "function" then
    UpdateProperty = function(name, value, ...)
      if name == "AI Core" then
        K.painted[#K.painted + 1] = value
      end
      return realUpdate(name, value, ...)
    end
  end
end

local function fireDebounce()
  local fn = K.debounce
  K.debounce = nil
  if fn ~= nil then
    fn()
  end
  return fn ~= nil
end

local function event(name)
  local ev = '<event name="' .. name .. '"/>'
  if type(OSE) == "table" and type(OSE[name]) == "function" then
    OSE[name](ev)
  elseif type(OnSystemEvent) == "function" then
    OnSystemEvent(ev)
  end
end

--- o = {
---   dir = "bond-fan",
---   expect = "Installed — reports through Bond Bridge Gateway (SBOS)",
---   load = function() end,     -- the family's loader: fresh driver, Init + LateInit
---   inbound = function() end,  -- one ordinary push from the root (KI-42 fallback)
--- }
function K.child(o)
  print("[" .. o.dir .. "]")
  local _, xml = K.properties(o.dir)
  K.check(o.dir .. ": driver.xml declares the exact AI Core property", aiCoreXml(xml) == K.XML, aiCoreXml(xml))

  package.loaded["sbos.aipresence"] = nil
  package.loaded["sbos.aireport"] = nil
  package.loaded["sbos.moduleclient"] = nil
  K.devices = {}
  K.frames = {}
  K.systemEvents = {}
  K.painted = {}
  K.debounce = nil
  local realTime = os.time
  local t = 1800000000
  os.time = function(x)
    if x then
      return realTime(x)
    end
    return t
  end

  o.load()
  local aipresence = package.loaded["sbos.aipresence"]
  K.check(o.dir .. ": sbos.aipresence loaded", aipresence ~= nil)
  K.check(o.dir .. ": sbos.aireport NOT loaded", package.loaded["sbos.aireport"] == nil)
  K.check(o.dir .. ": sbos.moduleclient NOT loaded", package.loaded["sbos.moduleclient"] == nil)
  if aipresence == nil then
    os.time = realTime
    return
  end
  intercept(aipresence)
  K.check(o.dir .. ": started at LateInit", aipresence.started())
  K.check(
    o.dir .. ": system events 13 and 11 registered",
    (function()
      local seen = {}
      for _, id in ipairs(K.systemEvents) do
        seen[id] = true
      end
      return seen[13] and seen[11]
    end)()
  )
  K.check(o.dir .. ": AI Core absent -> Not installed", Properties["AI Core"] == "Not installed", Properties["AI Core"])

  local before = #K.frames
  K.devices = { [K.AICORE_ID] = {} }
  event("OnDriverAdded")
  K.check(o.dir .. ": OnDriverAdded arms the 5 s debounce", K.debounce ~= nil)
  fireDebounce()
  K.check(o.dir .. ": AI Core added -> " .. o.expect, Properties["AI Core"] == o.expect, Properties["AI Core"])
  K.devices = {}
  event("OnItemRemoved")
  fireDebounce()
  K.check(
    o.dir .. ": AI Core removed -> Not installed",
    Properties["AI Core"] == "Not installed",
    Properties["AI Core"]
  )
  local cycle = #K.frames - before
  K.check(o.dir .. ": frame count: AI Core added and removed -> zero frames of any kind to anyone", cycle == 0, cycle)
  before = #K.frames

  -- KI-42: no system event at all; the root's ordinary traffic re-checks.
  K.devices = { [K.AICORE_ID] = {} }
  t = t + 60
  o.inbound()
  K.check(
    o.dir .. ": KI-42 fallback: a push 1 min later does not look again",
    Properties["AI Core"] == "Not installed",
    Properties["AI Core"]
  )
  t = t + 600
  o.inbound()
  K.check(
    o.dir .. ": KI-42 fallback: a push 10 min later corrects it, no event needed",
    Properties["AI Core"] == o.expect,
    Properties["AI Core"]
  )
  -- inbound() may make the driver do its ordinary work (a proxy notify);
  -- the re-check itself sends nothing to the bus or to AI Core.
  local ownCycle = 0
  for i = before + 1, #K.frames do
    local f = K.frames[i]
    if tostring(f.command or ""):find("^SBOS_MODULE_") or tonumber(f.to) == K.AICORE_ID then
      ownCycle = ownCycle + 1
    end
  end
  K.check(o.dir .. ": frame count: the re-check sends no bus / AI Core frame", ownCycle == 0, ownCycle)

  local busFrames = 0
  for _, f in ipairs(K.frames) do
    if tostring(f.command or ""):find("^SBOS_MODULE_") or tonumber(f.to) == K.AICORE_ID then
      busFrames = busFrames + 1
    end
  end
  K.check(o.dir .. ": over its whole life: no SBOS_MODULE_* frame, nothing to AI Core", busFrames == 0, busFrames)

  local outside = {}
  local values = require("sbos.aivalues")
  for _, v in ipairs(K.painted) do
    if not values.isValue(v) then
      outside[#outside + 1] = v
    end
  end
  K.check(o.dir .. ": only closed values painted", #outside == 0, table.concat(outside, " | "))

  OnDriverDestroyed()
  K.check(o.dir .. ": OnDriverDestroyed stops it", not aipresence.started())
  os.time = realTime
end

return K
