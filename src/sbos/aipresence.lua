--- SmartBuildOS AI Core presence: the read-only "AI Core" Composer property
--- for a driver that does NOT report to AI Core (conductor ruling 20).
---
--- Used by every child driver (Bond, MQTT, System Link, UniFi children, the
--- Mode Button, Home Insights) and by a root while it does not report
--- (VenueFlow with Remote Management off). It never registers on the module
--- bus and never sends a frame of any kind to anyone: it only asks Director
--- whether a `smartbuildos-ai-core.c4z` device exists
--- (`C4:GetDevicesByC4iName`) and paints one of three closed values from
--- sbos.aivalues:
---   Installed — reports through ‹root›   a child whose root reports
---   Installed — this driver does not report
---                                        a child of the Agent (Insights), or
---                                        a root started with silent = true
---   Not installed                        Director lists no AI Core
--- (`Searching…` until the first answer.)
---
--- It requires neither sbos.moduleclient nor sbos.aireport (a child would
--- otherwise carry about 128 KB of unused source per .c4z).
---
--- When it looks: at start; on the system events OnDriverAdded (13) and
--- OnItemRemoved (11), debounced 5 s; and through `recheck()`, which the
--- driver calls from traffic it already receives from its root (at most one
--- lookup per RECHECK_SECONDS; no timer of its own). Whether those system
--- events reach a child driver is unverified on hardware (KI-42); without
--- them the value is corrected by the next `recheck()` or the next driver
--- start. Nothing here has run on a physical controller.

local values = require("sbos.aivalues")

local M = {}

--- Child drivers and their root, keyed by .c4z file. Same map as
--- test/test_driver_license_guard.lua `inherited`.
M.CHILDREN = {
  ["bond-color-light.c4z"] = "bond-bridge.c4z",
  ["bond-fan.c4z"] = "bond-bridge.c4z",
  ["bond-fireplace.c4z"] = "bond-bridge.c4z",
  ["bond-generic.c4z"] = "bond-bridge.c4z",
  ["bond-heater.c4z"] = "bond-bridge.c4z",
  ["bond-keypad.c4z"] = "bond-bridge.c4z",
  ["bond-light.c4z"] = "bond-bridge.c4z",
  ["bond-shade.c4z"] = "bond-bridge.c4z",
  ["bond-weather.c4z"] = "bond-bridge.c4z",
  ["smartbuildos-insights.c4z"] = "smartbuildos.c4z",
  ["smartbuildos-mqtt-contact.c4z"] = "smartbuildos-mqtt-broker.c4z",
  ["smartbuildos-mqtt-light.c4z"] = "smartbuildos-mqtt-broker.c4z",
  ["smartbuildos-mqtt-motion.c4z"] = "smartbuildos-mqtt-broker.c4z",
  ["smartbuildos-mqtt-shade.c4z"] = "smartbuildos-mqtt-broker.c4z",
  ["smartbuildos-mode-button.c4z"] = "smartbuildos-mode-composer.c4z",
  ["smartbuildos-system-link-light.c4z"] = "smartbuildos-system-link.c4z",
  ["smartbuildos-system-link-relay.c4z"] = "smartbuildos-system-link.c4z",
  ["smartbuildos-system-link-contact.c4z"] = "smartbuildos-system-link.c4z",
  ["smartbuildos-system-link-temperature.c4z"] = "smartbuildos-system-link.c4z",
  ["smartbuildos-system-link-thermostat.c4z"] = "smartbuildos-system-link.c4z",
  ["smartbuildos-system-link-shade.c4z"] = "smartbuildos-system-link.c4z",
  ["smartbuildos-system-link-media.c4z"] = "smartbuildos-system-link.c4z",
  ["smartbuildos-system-link-lock.c4z"] = "smartbuildos-system-link.c4z",
  ["smartbuildos-system-link-gate.c4z"] = "smartbuildos-system-link.c4z",
  ["smartbuildos-system-link-fan.c4z"] = "smartbuildos-system-link.c4z",
  ["smartbuildos-system-link-export-light.c4z"] = "smartbuildos-system-link.c4z",
  ["unifi-protect-camera.c4z"] = "unifi-protect.c4z",
  ["unifi-protect-light.c4z"] = "unifi-protect.c4z",
  ["unifi-protect-sensor.c4z"] = "unifi-protect.c4z",
  ["unifi-protect-viewport.c4z"] = "unifi-protect.c4z",
}

--- Roots that send no reports: a child of one must not claim "reports
--- through …" and shows `Installed — this driver does not report`.
M.SILENT_ROOTS = {
  ["smartbuildos.c4z"] = "the SmartBuildOS Agent is the bus hub and sends no reports",
}

M.DEBOUNCE_SECONDS = 5
M.RECHECK_SECONDS = 600
M.TIMER = "SbosAiPresence"

local function fresh()
  return {
    started = false,
    file = nil,
    property = values.PROPERTY,
    label = nil, -- root label, or nil: "this driver does not report"
    installed = nil, -- nil until Director answers
    lastLookup = nil,
    value = nil,
    timer = nil, -- a C4:SetTimer handle when the vendored SetTimer is absent
    counters = { lookups = 0, events = 0, rechecks = 0, values_refused = 0 },
  }
end
local S = fresh()

--- The driver's own .c4z file name (as sbos.aireport): DC_FILENAME in the
--- DriverCentral variant, else DRIVER_FILENAMES[1] (the OSS build).
local function defaultFile()
  if type(DC_FILENAME) == "string" and DC_FILENAME ~= "" then
    return DC_FILENAME
  end
  if type(DRIVER_FILENAMES) == "table" and type(DRIVER_FILENAMES[1]) == "string" then
    return DRIVER_FILENAMES[1]
  end
  return nil
end
M._defaultFile = defaultFile

--- Paints `text` when it is a closed value (sbos.aivalues) and differs from
--- the last one; anything else is refused (counted) and never written.
local function paint(text)
  if not values.isValue(text) then
    S.counters.values_refused = S.counters.values_refused + 1
    return false
  end
  if S.value == text then
    return true
  end
  S.value = text
  if type(Properties) == "table" and Properties[S.property] ~= nil then
    if type(UpdateProperty) == "function" then
      pcall(UpdateProperty, S.property, text)
    else
      -- A driver without the vendored handlers (Home Insights).
      pcall(function()
        C4:UpdateProperty(S.property, text)
      end)
    end
  end
  return true
end
M._paint = paint

function M.computeValue()
  if not S.started or S.installed == nil then
    return values.V.searching
  end
  if not S.installed then
    return values.V.not_installed
  end
  if S.label ~= nil then
    return string.format(values.V.passive_installed, S.label)
  end
  return values.V.no_report
end

local function lookup()
  if not S.started then
    return
  end
  S.counters.lookups = S.counters.lookups + 1
  S.lastLookup = os.time()
  local ok, found = pcall(function()
    return C4:GetDevicesByC4iName(values.AI_CORE_FILE)
  end)
  if ok then
    S.installed = type(found) == "table" and next(found) ~= nil
  end -- no answer: keep what we knew
  paint(M.computeValue())
end

local function cancelTimer()
  if type(CancelTimer) == "function" then
    CancelTimer(M.TIMER)
  end
  if S.timer ~= nil then
    pcall(function()
      S.timer:Cancel()
    end)
    S.timer = nil
  end
end

--- A debounced lookup (a burst of added / removed devices is one lookup).
local function soon()
  if not S.started then
    return
  end
  S.counters.events = S.counters.events + 1
  local ms = M.DEBOUNCE_SECONDS * 1000
  if type(SetTimer) == "function" then
    SetTimer(M.TIMER, ms, lookup)
  else
    cancelTimer()
    pcall(function()
      S.timer = C4:SetTimer(ms, function()
        S.timer = nil
        lookup()
      end, false)
    end)
  end
end
M._soon = soon
M._oseHooks = {}

--- Starts the property. opts = { file? (default: the driver's own file),
--- property? ("AI Core"), silent? }. A file in CHILDREN is a child; a root
--- file from sbos.aivalues LABELS is accepted only with `silent = true` (a
--- root that does not report now, e.g. VenueFlow with Remote Management
--- off). Returns true, or false + "unknown_driver_file" (nothing is set up).
function M.start(opts)
  opts = opts or {}
  local file = opts.file or defaultFile()
  local root = M.CHILDREN[file or ""]
  local label
  if root ~= nil then
    if values.LABELS[root] == nil then
      return false, "unknown_driver_file"
    end
    label = M.SILENT_ROOTS[root] == nil and values.LABELS[root] or nil
  elseif opts.silent == true and file ~= nil and values.LABELS[file] ~= nil then
    label = nil
  else
    return false, "unknown_driver_file"
  end
  cancelTimer()
  local counters = S.counters
  S = fresh()
  S.counters = counters
  S.started = true
  S.file = file
  S.property = opts.property or values.PROPERTY
  S.label = label
  paint(values.V.searching)
  if type(OSE) == "table" then
    -- Chain whatever the driver already handles; never wrap our own hook.
    for _, name in ipairs({ "OnDriverAdded", "OnItemRemoved" }) do
      local previous = OSE[name]
      if previous == nil or previous ~= M._oseHooks[name] then
        local hook = function(event)
          soon()
          if type(previous) == "function" then
            return previous(event)
          end
        end
        OSE[name] = hook
        M._oseHooks[name] = hook
      end
    end
  end
  for _, id in ipairs({ 13, 11 }) do
    pcall(function()
      C4:RegisterSystemEvent(id, 0)
    end)
  end
  lookup()
  return true
end

--- For a driver without the vendored OSE table (Home Insights): forward
--- Director's OnSystemEvent here.
function M.onSystemEvent(event)
  -- Parsed as the vendored OnSystemEvent and sbos.agenttelemetry do.
  local name = tostring(event or ""):match('.-name="(.-)"')
  if name == "OnDriverAdded" or name == "OnItemRemoved" then
    soon()
  end
end

--- The bounded fallback for KI-42: called from traffic the driver already
--- receives (its root's pushes). Looks again only if the last lookup is
--- RECHECK_SECONDS old or more; otherwise does nothing. No timer.
function M.recheck()
  if not S.started then
    return false
  end
  if S.lastLookup ~= nil and os.time() - S.lastLookup < M.RECHECK_SECONDS then
    return false
  end
  S.counters.rechecks = S.counters.rechecks + 1
  lookup()
  return true
end

--- OnDriverDestroyed (or a root about to start reporting).
function M.stop()
  cancelTimer()
  S.started = false
end

function M.value()
  return S.value
end

function M.counters()
  return S.counters
end

function M.started()
  return S.started
end

--- Tests only.
function M._reset()
  cancelTimer()
  S = fresh()
  M._oseHooks = {}
end

return M
