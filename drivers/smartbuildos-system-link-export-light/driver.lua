--[[==========================================================================
  SmartBuildOS System Link — Export Light
  The Composer Connections way to share a light with the linked project:
  bind the real light to this driver's "Light" connection, name the export
  in its properties, and it registers with the System Link bridge using the
  BOUND device (the light's proxy, which carries LIGHT_STATE and the level).
  The bridge does everything else — the same validation, watch and items as
  Export Selected Device — so nothing here reads or drives the light.
  Unbinding or deleting this driver removes the export.
  Licensing: inherits the bridge's pair licence (suite convention).
  Hardware validation: none yet — see the documentation tab.
============================================================================]]

--#ifdef DRIVERCENTRAL
DC_PID = 0
DC_X = nil
DC_FILENAME = "smartbuildos-system-link-export-light.c4z"
--#else
DRIVER_GITHUB_REPO = "michelo76/control4-smartbuildos"
DRIVER_FILENAMES = { "smartbuildos-system-link-export-light.c4z" }
--#endif

require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")
JSON = require("JSON")
local log = require("lib.logging")
local persist = require("lib.persist")
local companion = require("systemlink.companion")

gInitialized = false

local KIND = "light"
local LIGHT_BINDING = 5001
local BOUND_KEY = "sl_export_bound_device"
local REGISTERED_KEY = "sl_export_registered_name"

local function boundDevice()
  return tonumber(persist:get(BOUND_KEY, false)) or nil
end

local function registeredName()
  local v = persist:get(REGISTERED_KEY, false)
  return type(v) == "string" and v ~= "" and v or nil
end

local function exportName()
  local name = tostring(Properties["Export Name"] or "")
  if name ~= "" then
    return name
  end
  -- Prefill from the bound light's name under the export-name rule.
  local id = boundDevice()
  if not id then
    return ""
  end
  local okN, raw = pcall(function()
    return C4:GetDeviceData(id, "name")
  end)
  local derived = (okN and tostring(raw or "") or ""):gsub("[^%w]+", "_"):gsub("^_+", ""):gsub("_+$", ""):gsub("^[^%a]+", "")
  return derived:sub(1, 40)
end

local function register()
  local bridge = companion.findBridge()
  local id = boundDevice()
  if not bridge then
    UpdateProperty("Export Status", "No SmartBuildOS System Link found in this project")
    return
  end
  if not id then
    UpdateProperty("Export Status", "Bind the light to this driver's Light connection in Composer Connections")
    return
  end
  local name = exportName()
  if name == "" then
    UpdateProperty("Export Status", "Fill in Export Name")
    return
  end
  if tostring(Properties["Export Name"] or "") == "" then
    UpdateProperty("Export Name", name)
  end
  UpdateProperty("Export Status", "Registering " .. name .. " with the bridge…")
  pcall(function()
    C4:SendToDevice(bridge, "SBOS_LINK_EXPORT_REGISTER", {
      requester = tostring(C4:GetDeviceID()),
      name = name,
      kind = KIND,
      device_id = tostring(id),
      control = tostring(Properties["Export Control"] or "View only"),
      ops = tostring(Properties["Export Operations"] or ""),
    })
  end)
end

local function unregister(name)
  local bridge = companion.findBridge()
  if bridge and name and name ~= "" then
    pcall(function()
      C4:SendToDevice(bridge, "SBOS_LINK_EXPORT_UNREGISTER", { requester = tostring(C4:GetDeviceID()), name = name })
    end)
  end
end

-- Composer Connections: the real light is bound to (or removed from) us.
-- otherDeviceId is the bound device, which is the light's proxy: exactly
-- the id that carries LIGHT_STATE and the level for the bridge to watch.
OBC[LIGHT_BINDING] = function(_, _, bIsBound, otherDeviceId)
  if bIsBound then
    persist:set(BOUND_KEY, tonumber(otherDeviceId))
    register()
  else
    local name = registeredName()
    persist:set(BOUND_KEY, nil)
    if name then
      unregister(name)
    end
    UpdateProperty("Export Status", "Unbound — export removed")
  end
end

EC.SBOS_LINK_EXPORT_RESULT = function(tParams)
  tParams = tParams or {}
  local ok = tostring(tParams.ok) == "true"
  local reason = tostring(tParams.reason or "")
  if ok and reason ~= "removed" then
    persist:set(REGISTERED_KEY, tostring(tParams.name or ""))
    UpdateProperty("Export Status", "Exported as " .. tostring(tParams.name or "") .. " (" .. reason .. ")")
  elseif ok then
    persist:set(REGISTERED_KEY, nil)
  else
    UpdateProperty("Export Status", "Refused: " .. reason)
  end
end

EC.REGISTER_EXPORT = function()
  register()
end

EC.REMOVE_EXPORT = function()
  local name = registeredName()
  if name then
    unregister(name)
    UpdateProperty("Export Status", "Export " .. name .. " removed")
  else
    UpdateProperty("Export Status", "Nothing exported yet")
  end
end

OPC.Export_Name = function()
  if boundDevice() then
    local old = registeredName()
    if old and old ~= tostring(Properties["Export Name"]) then
      unregister(old)
    end
    register()
  end
end
OPC.Export_Control = function()
  if boundDevice() then
    register()
  end
end
OPC.Export_Operations = OPC.Export_Control
OPC.Log_Level = function(value)
  log:setLogLevel(value)
end
OPC.Log_Mode = function(value)
  log:setLogMode(value)
end

function OnDriverInit()
  C4:AllowExecute(true)
  gInitialized = false
  log:setLogName("SystemLinkExportLight")
end

function OnDriverLateInit()
  if not CheckMinimumVersion("Driver Status") then
    return
  end
  for p, _ in pairs(Properties) do
    pcall(OnPropertyChanged, p)
  end
  UpdateProperty("Driver Version", tostring(C4:GetDriverConfigInfo("version") or ""))
  UpdateProperty("Driver Status", "Online")
  if boundDevice() then
    register()
  else
    UpdateProperty("Export Status", "Bind the light to this driver's Light connection in Composer Connections")
  end
  gInitialized = true
end

function OnDriverDestroyed()
  local name = registeredName()
  if name then
    unregister(name)
  end
end
