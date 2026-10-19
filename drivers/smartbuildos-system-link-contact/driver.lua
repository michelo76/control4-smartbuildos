--[[==========================================================================
  SmartBuildOS System Link — Contact companion
  Presents ONE contact export of the linked project as a native Control4
  CONTACT_SENSOR connection. State arrives from the System Link bridge on this controller;
  control requests go back through it to the owner, who executes them on
  the real device. The proxy only ever shows CONFIRMED state from the owner;
  a request is shown separately as Requested State until feedback arrives.
  Licensing: inherits the bridge's pair licence (suite convention).
  Hardware validation: none yet — see the documentation tab.
============================================================================]]

--#ifdef DRIVERCENTRAL
DC_PID = 0
DC_X = nil
DC_FILENAME = "smartbuildos-system-link-contact.c4z"
--#else
DRIVER_GITHUB_REPO = "michelo76/control4-smartbuildos"
DRIVER_FILENAMES = { "smartbuildos-system-link-contact.c4z" }
--#endif

require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")
JSON = require("JSON")
local base = require("systemlink.companiondriver")

gInitialized = false

local CONTACT_BINDING = 200
local gOpen = nil

base.install({
  kind = "contact",
  logName = "SystemLinkContact",
  applyState = function(fields, fresh)
    local open = fields.Open
    if open == JSON.null then
      open = nil
    end
    if fresh ~= "current" or open == nil then
      return
    end
    if gOpen ~= nil and gOpen ~= open then
      pcall(function()
        C4:FireEventByID(open and 4 or 5)
      end)
    end
    gOpen = open
    SendToProxy(CONTACT_BINDING, open and "OPENED" or "CLOSED", {}, "NOTIFY")
  end,
  describeState = function(fields)
    local open = fields.Open
    if open == JSON.null or open == nil then
      return "unavailable"
    end
    return open and "Open" or "Closed"
  end,
})

TC.CONTACT_OPEN = function()
  return gOpen == true
end

function RFP.GET_STATE(idBinding)
  if idBinding == CONTACT_BINDING and gOpen ~= nil then
    SendToProxy(CONTACT_BINDING, gOpen and "STATE_OPENED" or "STATE_CLOSED", {}, "NOTIFY")
  end
end
