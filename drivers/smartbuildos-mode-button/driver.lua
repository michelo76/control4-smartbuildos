--- SmartBuildOS Mode Button — one Navigator Experience button per mode.
---
--- A UI satellite of the Mode Composer manager: it renders one mode's
--- icon/state and forwards taps. It holds NO automation logic and NO
--- licensing of its own — children inherit the gateway's entitlement (the
--- suite convention), and the manager decides everything (spec §114-§115).
---
--- Transport is the dual-path convention: the button finds the manager by
--- EXACT driver filename and talks SendToDevice both ways.

require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")

JSON = require("JSON")

local log = require("lib.logging")
local persist = require("lib.persist")

local MANAGER_FILENAMES = { ["smartbuildos-mode-composer.c4z"] = true, ["smartbuildos-mode-composer.c4i"] = true }
local MODE_KEY = "ModeButtonModeId"
local AUTO_NAME_KEY = "ModeButtonAutoName"
local RETRY_TIMER = "MbRetry"
local UI_BINDING = 5001

--- Icon kinds baked into the c4z. A mode whose icon isn't here falls back
--- to "custom" — never a broken image.
local KNOWN_ICONS = {
  home = true,
  away = true,
  vacation = true,
  moon = true,
  film = true,
  party = true,
  sunrise = true,
  night = true,
  custom = true,
  lock = true,
  shield = true,
  energy = true,
  cleaning = true,
  work = true,
  dinner = true,
  guest = true,
}

gInitialized = false
gManagerId = nil
gModes = {} -- last MC_STATE payload, decoded
gModeId = nil -- the mode this button represents
gCurrentIconState = nil

-- ─── Manager discovery (exact filename, the near-miss-proof pattern) ─────────

local function findManager()
  if gManagerId then
    return gManagerId
  end
  for id, info in pairs(C4:GetDevices({}) or {}) do
    if MANAGER_FILENAMES[info.driverFileName or ""] then
      gManagerId = tonumber(id)
      break
    end
  end
  UpdateProperty(
    "Mode Manager",
    gManagerId and ("Found (device " .. gManagerId .. ")")
      or "Not found - add SmartBuildOS Mode Composer to the project"
  )
  return gManagerId
end

local function askManager()
  local manager = findManager()
  if not manager then
    -- Keep looking: the manager may be added after the buttons.
    SetTimer(RETRY_TIMER, 30 * ONE_SECOND, askManager, false)
    return
  end
  pcall(function()
    SendToDevice(manager, "MC_GET_STATE", { requester = tostring(C4:GetDeviceID()) })
  end)
end

-- ─── Rendering ───────────────────────────────────────────────────────────────

local function myMode()
  for _, mode in ipairs(gModes) do
    if mode.id == gModeId then
      return mode
    end
  end
  return nil
end

local function setIcon(stateId)
  if stateId == gCurrentIconState then
    return
  end
  gCurrentIconState = stateId
  pcall(function()
    SendToProxy(
      UI_BINDING,
      "ICON_CHANGED",
      { icon = stateId or "", icon_description = stateId or "mode button" },
      "NOTIFY"
    )
  end)
end

local function maybeRename(mode)
  if Properties["Rename With Mode"] == "No" then
    return
  end
  local current = C4:GetDeviceData(C4:GetDeviceID(), "name") or ""
  local lastAuto = persist:get(AUTO_NAME_KEY, "")
  -- The clobber guard: only rename over the install default or our own last
  -- write; a dealer's rename is sacred (the Protect suite's field lesson).
  local isDefault = current == ""
    or current:find("SmartBuildOS Mode Button", 1, true) == 1
    or current:find("Mode Button", 1, true) == 1
  if not isDefault and current ~= lastAuto then
    return
  end
  if current == mode.name then
    return
  end
  persist:set(AUTO_NAME_KEY, mode.name)
  pcall(function()
    RenameDevice(C4:GetDeviceID(), mode.name)
    for _, proxyId in pairs(C4:GetProxyDevices() or {}) do
      RenameDevice(proxyId, mode.name)
    end
  end)
end

local function render()
  local mode = myMode()
  if not mode then
    setIcon("")
    UpdateProperty("Driver Status", gModeId and "Assigned mode is gone - pick another" or "Pick a mode in Properties")
    return
  end
  local icon = KNOWN_ICONS[mode.icon or ""] and mode.icon or "custom"
  -- Transitioning/pending-confirm shows as active: the tile should light up
  -- the moment the user commits, not after the countdown.
  local lit = mode.active or mode.transitioning or mode.pending_confirm
  setIcon(icon .. (lit and "_on" or "_off"))
  maybeRename(mode)
  UpdateProperty("Driver Status", mode.active and (mode.name .. " (active)") or mode.name)
end

local function paintModeList()
  local names = {}
  for _, mode in ipairs(gModes) do
    table.insert(names, mode.name)
  end
  pcall(function()
    C4:UpdatePropertyList(
      "Mode",
      #names > 0 and table.concat(names, ",") or "-",
      myMode() and myMode().name or Properties["Mode"]
    )
  end)
end

-- ─── Manager traffic ─────────────────────────────────────────────────────────

EC.MC_STATE = function(tParams)
  local ok, decoded = pcall(function()
    return JSON:decode((tParams or {}).modes or "[]")
  end)
  if not ok or type(decoded) ~= "table" then
    log:warn("MC_STATE carried undecodable modes payload")
    return
  end
  gModes = decoded
  paintModeList()
  render()
end

-- ─── Navigator tap ───────────────────────────────────────────────────────────

RFP.SELECT = function()
  pcall(function()
    C4:FireEventByID(1)
  end)
  local manager = findManager()
  if not manager or not gModeId then
    log:print("This button has no mode assigned or no Mode Composer manager was found.")
    return
  end
  pcall(function()
    SendToDevice(manager, "MC_SELECT", { requester = tostring(C4:GetDeviceID()), mode_id = gModeId })
  end)
end

-- ─── Composer surface ────────────────────────────────────────────────────────

OPC.Log_Level = function(value)
  log:setLogLevel(value)
end
OPC.Log_Mode = function(value)
  log:setLogMode(value)
end

OPC.Mode = function(value)
  if not gInitialized then
    return
  end
  for _, mode in ipairs(gModes) do
    if mode.name == value then
      gModeId = mode.id
      persist:set(MODE_KEY, gModeId)
      render()
      return
    end
  end
end

OPC.Rename_With_Mode = function()
  render()
end

EC.REFRESH_STATE = function()
  gManagerId = nil
  askManager()
end

EC.PRINT_DIAGNOSTICS = function()
  log:print("Mode Button %s", C4:GetDriverConfigInfo("version") or "?")
  log:print("Manager: %s", gManagerId and ("device " .. gManagerId) or "NOT FOUND")
  log:print("Assigned mode: %s (%s)", gModeId or "none", myMode() and myMode().name or "?")
  log:print("Known modes: %d   Icon state: %s", #gModes, tostring(gCurrentIconState))
end

-- ─── Lifecycle ───────────────────────────────────────────────────────────────

function OnDriverInit()
  log:setLogName("ModeButton")
  log:setLogLevel(Properties["Log Level"])
  log:setLogMode(Properties["Log Mode"])
  gModeId = persist:get(MODE_KEY, nil)
  if type(gModeId) ~= "string" then
    gModeId = nil
  end
end

function OnDriverLateInit()
  pcall(function()
    C4:AddEvent(1, "Pressed", "The mode button was tapped in Navigator.")
  end)
  for p, _ in pairs(Properties) do
    pcall(OnPropertyChanged, p)
  end
  askManager()
  gInitialized = true
  UpdateProperty("Driver Version", C4:GetDriverConfigInfo("version") or "")
  UpdateProperty("Driver Status", "Online")
end

function OnDriverDestroyed()
  KillAllTimers()
end
