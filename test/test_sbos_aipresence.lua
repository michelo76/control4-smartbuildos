-- sbos.aipresence: the "AI Core" property of a driver that does not report
-- (every child driver; a root that does not report now). Ruling 20.
--   [1] it loads neither sbos.moduleclient nor sbos.aireport
--   [2] a child: Not installed / Installed — reports through ‹root›, on
--       OnDriverAdded / OnItemRemoved (debounced, chained), zero frames
--   [3] a child of the Agent (Insights) and a silent root (VenueFlow off):
--       Installed — this driver does not report
--   [4] a driver without the vendored handlers (Insights): C4:SetTimer,
--       C4:UpdateProperty, OnSystemEvent forwarded by hand
--   [5] recheck(): the KI-42 fallback, at most one lookup per 10 minutes
--   [6] refusals, stop, an undeclared property
-- Run from the driver root: make test

C4 = C4 or {}
require("c4_shim")

local pass, fail = 0, 0
local function check(name, ok, detail)
  if ok then
    pass = pass + 1
    print("  ok   " .. name)
  else
    fail = fail + 1
    print("  FAIL " .. name .. (detail ~= nil and ("  -> " .. tostring(detail)) or ""))
  end
end

-- ── Director fakes ──────────────────────────────────────────────────────────
local frames = 0
function C4:SendToDevice()
  frames = frames + 1
end
function C4:SendToProxy()
  frames = frames + 1
end
local c4i = {}
local lookups = 0
function C4:GetDevicesByC4iName(file)
  lookups = lookups + 1
  return c4i[file]
end
local systemEvents = {}
function C4:RegisterSystemEvent(id)
  systemEvents[#systemEvents + 1] = id
end
local timers = {}
function SetTimer(id, ms, fn)
  timers[id] = { ms = ms, fn = fn }
end
function CancelTimer(id)
  timers[id] = nil
end
local function fire(id)
  local t = timers[id]
  timers[id] = nil
  if t then
    t.fn()
  end
  return t ~= nil
end
Properties = {}
local painted = {}
function UpdateProperty(name, value)
  painted[#painted + 1] = { name = name, value = value }
  Properties[name] = value
end
OSE = {}

local before = {}
for k in pairs(package.loaded) do
  before[k] = true
end
local aipresence = require("sbos.aipresence")
local V = require("sbos.aivalues").V

local function value()
  return aipresence.value()
end
local function fresh()
  aipresence._reset()
  painted = {}
  systemEvents = {}
  timers = {}
  Properties = { ["AI Core"] = "Searching…" }
  c4i = {}
end

print("[1] small: no bus client, no helper")
do
  local loaded = {}
  for k in pairs(package.loaded) do
    if not before[k] then
      loaded[#loaded + 1] = k
    end
  end
  table.sort(loaded)
  check(
    "requiring it loads sbos.aipresence + sbos.aivalues only",
    #loaded == 2 and loaded[1] == "sbos.aipresence" and loaded[2] == "sbos.aivalues",
    table.concat(loaded, ", ")
  )
  check("sbos.moduleclient not loaded", package.loaded["sbos.moduleclient"] == nil)
  check("sbos.aireport not loaded", package.loaded["sbos.aireport"] == nil)
end

print("[2] a child whose root reports")
do
  fresh()
  local chained = 0
  OSE.OnDriverAdded = function()
    chained = chained + 1
  end
  OSE.OnItemRemoved = nil
  local ok = aipresence.start({ file = "bond-light.c4z" })
  check("starts for a child", ok == true and aipresence.started())
  check("AI Core absent -> Not installed", value() == V.not_installed, value())
  check("system events 13 and 11 registered", systemEvents[1] == 13 and systemEvents[2] == 11)
  c4i["smartbuildos-ai-core.c4z"] = { [700] = {} }
  OSE.OnDriverAdded('<event name="OnDriverAdded"/>')
  check("OnDriverAdded chains the driver's own handler", chained == 1)
  check("value waits for the 5 s debounce", value() == V.not_installed and timers[aipresence.TIMER].ms == 5000)
  fire(aipresence.TIMER)
  check(
    "AI Core added -> Installed — reports through the root",
    value() == "Installed — reports through Bond Bridge Gateway (SBOS)",
    value()
  )
  c4i["smartbuildos-ai-core.c4z"] = nil
  OSE.OnItemRemoved('<event name="OnItemRemoved"/>')
  fire(aipresence.TIMER)
  check("AI Core removed -> Not installed", value() == V.not_installed, value())
  aipresence.start({ file = "bond-light.c4z" })
  OSE.OnDriverAdded("x")
  check("a second start() does not wrap its own hook again", chained == 2)
  check(
    "Director answered nothing (error): the last value is kept",
    (function()
      local saved = C4.GetDevicesByC4iName
      C4.GetDevicesByC4iName = function()
        error("no")
      end
      aipresence._soon()
      fire(aipresence.TIMER)
      C4.GetDevicesByC4iName = saved
      return value() == V.not_installed
    end)()
  )
  check("zero frames of any kind", frames == 0, frames)
  for file, root in pairs(aipresence.CHILDREN) do
    fresh()
    c4i["smartbuildos-ai-core.c4z"] = { [700] = {} }
    aipresence.start({ file = file })
    if aipresence.SILENT_ROOTS[root] == nil then
      check(file .. " -> reports through its root", value():find("^Installed — reports through ") ~= nil, value())
    end
  end
  check("zero frames for all 30 children", frames == 0, frames)
end

print("[3] a child of a root that does not report, and a silent root")
do
  fresh()
  c4i["smartbuildos-ai-core.c4z"] = { [700] = {} }
  aipresence.start({ file = "smartbuildos-insights.c4z" })
  check("Insights (child of the Agent) -> Installed — this driver does not report", value() == V.no_report, value())
  fresh()
  check("a root without silent is refused", aipresence.start({ file = "smartbuildos-venueflow.c4z" }) == false)
  check("…and nothing was painted", #painted == 0)
  c4i["smartbuildos-ai-core.c4z"] = { [700] = {} }
  check("a root with silent = true starts", aipresence.start({ file = "smartbuildos-venueflow.c4z", silent = true }))
  check("VenueFlow silent, AI Core present -> does not report", value() == V.no_report, value())
  c4i["smartbuildos-ai-core.c4z"] = nil
  aipresence._soon()
  fire(aipresence.TIMER)
  check("VenueFlow silent, AI Core absent -> Not installed", value() == V.not_installed, value())
  check(
    "the default file is the driver's own (DRIVER_FILENAMES[1])",
    (function()
      DRIVER_FILENAMES = { "unifi-protect-light.c4z" }
      local f = aipresence._defaultFile()
      DRIVER_FILENAMES = nil
      return f == "unifi-protect-light.c4z"
    end)()
  )
  check("frames still zero", frames == 0, frames)
end

print("[4] a driver without the vendored handlers (Home Insights)")
do
  fresh()
  local savedSet, savedCancel, savedUpdate, savedOSE = SetTimer, CancelTimer, UpdateProperty, OSE
  SetTimer, CancelTimer, UpdateProperty, OSE = nil, nil, nil, nil
  local c4timers, c4props = {}, {}
  function C4:SetTimer(ms, fn)
    local t = { ms = ms, fn = fn, cancelled = false }
    t.Cancel = function(self)
      self.cancelled = true
    end
    c4timers[#c4timers + 1] = t
    return t
  end
  function C4:UpdateProperty(name, v)
    c4props[name] = v
  end
  aipresence.start({ file = "smartbuildos-insights.c4z" })
  check("painted through C4:UpdateProperty", c4props["AI Core"] == V.not_installed, c4props["AI Core"])
  c4i["smartbuildos-ai-core.c4z"] = { [700] = {} }
  aipresence.onSystemEvent('<event name="OnDriverAdded" id="13"/>')
  aipresence.onSystemEvent('<event name="OnDriverAdded" id="13"/>')
  check(
    "debounced on C4:SetTimer (the first cancelled)",
    #c4timers == 2 and c4timers[1].cancelled and c4timers[2].ms == 5000
  )
  c4timers[2].fn()
  check("Insights -> does not report", c4props["AI Core"] == V.no_report, c4props["AI Core"])
  aipresence.onSystemEvent('<event name="OnItemMoved"/>')
  check("another system event is ignored", #c4timers == 2)
  SetTimer, CancelTimer, UpdateProperty, OSE = savedSet, savedCancel, savedUpdate, savedOSE
  C4.SetTimer, C4.UpdateProperty = nil, nil
end

print("[5] recheck(): bounded fallback when system events never arrive (KI-42)")
do
  fresh()
  local realTime = os.time
  local t = 5000
  os.time = function()
    return t
  end
  aipresence.start({ file = "unifi-protect-camera.c4z" })
  local n = lookups
  check("recheck right after start does nothing", aipresence.recheck() == false and lookups == n)
  c4i["smartbuildos-ai-core.c4z"] = { [700] = {} }
  t = t + 599
  check("…nor at 599 s", aipresence.recheck() == false and value() == V.not_installed)
  t = t + 1
  check("at 600 s one lookup corrects the value", aipresence.recheck() == true and lookups == n + 1, lookups - n)
  check(
    "…Installed — reports through UniFi Protect Gateway (SBOS)",
    value() == "Installed — reports through UniFi Protect Gateway (SBOS)",
    value()
  )
  for _ = 1, 50 do
    aipresence.recheck()
  end
  check("a burst of traffic costs no further lookup", lookups == n + 1, lookups - n)
  check("no timer armed by recheck", next(timers) == nil)
  os.time = realTime
end

print("[6] refusals, stop, an undeclared property")
do
  fresh()
  check("an unknown file is refused", aipresence.start({ file = "other.c4z" }) == false)
  check("no file at all is refused", aipresence.start({}) == false)
  aipresence.start({ file = "bond-fan.c4z" })
  check("paint refuses an outside value", aipresence._paint("Connected") == false and value() == V.not_installed)
  aipresence.stop()
  check("stopped", not aipresence.started())
  c4i["smartbuildos-ai-core.c4z"] = { [700] = {} }
  OSE.OnDriverAdded("x")
  check("after stop an event arms nothing", next(timers) == nil)
  check("after stop recheck does nothing", aipresence.recheck() == false and value() == V.not_installed)
  fresh()
  Properties = {}
  aipresence.start({ file = "unifi-protect-camera.c4z" })
  check("an undeclared property is never written", #painted == 0)
  check("frames zero over the whole run", frames == 0, frames)
end

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
