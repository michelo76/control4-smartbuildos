--[[==========================================================================
  SmartBuildOS System Link — Media room companion (read-only)
  Presents ONE media export of the linked project (a room's playing state:
  powered, source, volume, media info) as variables, events and
  conditionals on this controller. There is no proxy and no control: a
  remote room cannot be driven in this release, only observed. Every value
  shown is the owner's CONFIRMED state, never inferred.
  Licensing: inherits the bridge's pair licence (suite convention).
  Hardware validation: none yet — see the documentation tab.
============================================================================]]

--#ifdef DRIVERCENTRAL
DC_PID = 0
DC_X = nil
DC_FILENAME = "smartbuildos-system-link-media.c4z"
--#else
DRIVER_GITHUB_REPO = "michelo76/control4-smartbuildos"
DRIVER_FILENAMES = { "smartbuildos-system-link-media.c4z" }
--#endif

require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")
JSON = require("JSON")
local base = require("systemlink.companiondriver")

gInitialized = false

local EVENT_ROOM_ON, EVENT_ROOM_OFF, EVENT_MEDIA_CHANGED = 4, 5, 6
local VARS =
  { { "Powered", "BOOL", "0" }, { "Source", "STRING", "" }, { "Volume", "NUMBER", "0" }, { "Media", "STRING", "" } }
local gPowered, gMedia = nil, nil

local function clean(v)
  if v == JSON.null then
    return nil
  end
  return v
end

base.install({
  kind = "media",
  logName = "SystemLinkMedia",
  onLateInit = function()
    -- Variables for programming; a mirror is read-only by nature.
    for _, v in ipairs(VARS) do
      pcall(function()
        C4:AddVariable(v[1], v[3], v[2], true, false)
      end)
    end
  end,
  applyState = function(fields, fresh)
    local powered, source, volume, media =
      clean(fields.Powered), clean(fields.Source), clean(fields.Volume), clean(fields.Media)
    pcall(function()
      C4:SetVariable("Powered", powered and "1" or "0")
      C4:SetVariable("Source", tostring(source or ""))
      C4:SetVariable("Volume", tostring(volume or 0))
      C4:SetVariable("Media", tostring(media or ""))
    end)
    if fresh ~= "current" then
      return
    end
    if powered ~= nil and gPowered ~= nil and gPowered ~= powered then
      pcall(function()
        C4:FireEventByID(powered and EVENT_ROOM_ON or EVENT_ROOM_OFF)
      end)
    end
    if media ~= nil and gMedia ~= nil and gMedia ~= media then
      pcall(function()
        C4:FireEventByID(EVENT_MEDIA_CHANGED)
      end)
    end
    if powered ~= nil then
      gPowered = powered
    end
    if media ~= nil then
      gMedia = media
    end
  end,
  describeState = function(fields)
    local powered, source, volume, media =
      clean(fields.Powered), clean(fields.Source), clean(fields.Volume), clean(fields.Media)
    if powered == nil and source == nil and volume == nil and media == nil then
      return "unavailable"
    end
    if powered == false then
      return "Off"
    end
    local parts = { powered and "On" or "Power unknown" }
    if source and source ~= "" then
      parts[#parts + 1] = tostring(source)
    end
    if volume ~= nil then
      parts[#parts + 1] = "volume " .. tostring(volume)
    end
    if media and media ~= "" then
      parts[#parts + 1] = tostring(media)
    end
    return table.concat(parts, " · ")
  end,
})

TC.ROOM_ON = function()
  return gPowered == true
end
