--[[==========================================================================
  SmartBuildOS System Link — Relay companion
  Presents ONE relay export of the linked project as a native Control4
  RELAY connection. State arrives from the System Link bridge on this controller;
  control requests go back through it to the owner, who executes them on
  the real device. The proxy only ever shows CONFIRMED state from the owner;
  a request is shown separately as Requested State until feedback arrives.
  Licensing: inherits the bridge's pair licence (suite convention).
  Hardware validation: none yet — see the documentation tab.
============================================================================]]

--#ifdef DRIVERCENTRAL
DC_PID = 0
DC_X = nil
DC_FILENAME = "smartbuildos-system-link-relay.c4z"
--#else
DRIVER_GITHUB_REPO = "michelo76/control4-smartbuildos"
DRIVER_FILENAMES = { "smartbuildos-system-link-relay.c4z" }
--#endif

require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")
JSON = require("JSON")
local base = require("systemlink.companiondriver")

gInitialized = false

local RELAY_BINDING = 200
local gClosed = nil

base.install({
  kind = "relay",
  logName = "SystemLinkRelay",
  applyState = function(fields, fresh)
    local closed = fields.Closed
    if closed == JSON.null then
      closed = nil
    end
    if fresh ~= "current" or closed == nil then
      return -- never fabricate a relay state; the last notify stands
    end
    if gClosed ~= nil and gClosed ~= closed then
      pcall(function()
        C4:FireEventByID(closed and 4 or 5)
      end)
    end
    gClosed = closed
    -- c4hook_relay vocabulary: OPENED/CLOSED on change, STATE_* on request.
    SendToProxy(RELAY_BINDING, closed and "CLOSED" or "OPENED", {}, "NOTIFY")
  end,
  describeState = function(fields)
    local closed = fields.Closed
    if closed == JSON.null or closed == nil then
      return "unavailable"
    end
    return closed and "Closed" or "Open"
  end,
})

TC.RELAY_CLOSED = function()
  return gClosed == true
end

function RFP.GET_STATE(idBinding)
  if idBinding == RELAY_BINDING and gClosed ~= nil then
    SendToProxy(RELAY_BINDING, gClosed and "STATE_CLOSED" or "STATE_OPENED", {}, "NOTIFY")
  end
end
function RFP.OPEN(idBinding)
  if idBinding == RELAY_BINDING then
    base.control("open", {}, "Open")
  end
end
function RFP.CLOSE(idBinding)
  if idBinding == RELAY_BINDING then
    base.control("close", {}, "Close")
  end
end
function RFP.TOGGLE(idBinding)
  if idBinding == RELAY_BINDING then
    base.control("toggle", {}, "Toggle")
  end
end
--- A pulse is ONE request; the owner's device terminates it locally.
function RFP.TRIGGER(idBinding)
  if idBinding == RELAY_BINDING then
    base.control("trigger", {}, "Pulse")
  end
end

-- ─── Bench actions: one click each, the same control path the proxy uses ───
-- (Composer's Actions tab, so a dealer can prove the link controls the
-- remote device without wiring programming first; bench 2026-10-20).
function EC.TEST_OPEN()
  base.control("open", {}, "Open")
end
function EC.TEST_CLOSE()
  base.control("close", {}, "Close")
end
