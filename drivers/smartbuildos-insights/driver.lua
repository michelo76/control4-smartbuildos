--[[==========================================================================
  SmartBuildOS Home Insights — WebView driver

  Puts a web page on Control4 touchscreens and in the Control4 app. Written as
  the window onto the SmartBuildOS Home Insights page. SmartBuildOS stopped
  serving that page for touchscreens in November 2026, and the Connector no
  longer issues its address, so the URL is whatever the installer pastes in.

  ── WHY THIS IS A SEPARATE DRIVER ─────────────────────────────────────────────

  A WebView driver IS a `uibutton` proxy, and a proxy is what puts a tile in
  Navigator. The Connector is a DriverWorks device with no UI proxy at all --
  it cannot grow one without becoming something a dealer has to re-add to every
  project. Two drivers is the shape Control4 imposes, not a choice.

  ── WHAT MAKES THE URL APPEAR ─────────────────────────────────────────────────

  Setting the `web_view_url` capability in driver.xml only supplies the value at
  INSTALL time. Changing it afterwards requires telling the proxy:

      C4:SendToProxy(5001, "URL_CHANGED", {url = ...})

  Measured in Control4's own WebView Sample, which is also where the startup
  timer below comes from: a notify sent before the project has finished starting
  is silently lost, so the URL is re-sent once things have settled. Without it a
  panel comes back from a controller reboot showing nothing, and the only fix a
  dealer finds is re-typing the URL.

  ── READ-ONLY, LIKE THE PAGE IT OPENS ─────────────────────────────────────────

  No device control, no write path, nothing this driver can switch on or off.
  The page's URL is its credential -- a link copied out of a panel's address bar
  must not be a link that controls somebody's house -- and a driver that could
  act on the page's behalf would hand that property away.
============================================================================]]

WEBVIEW_PROXY_BINDINGID = 5001

-- The AI Core property (ruling 20). This driver's root is the SmartBuildOS
-- Agent, which sends no reports, so it shows "Installed — this driver does
-- not report" or "Not installed". Passive: no frame of any kind.
local aipresence = require("sbos.aipresence")

--- How long to wait before re-announcing the URL after a driver load.
---
--- Control4's sample uses 60s. Kept identical rather than tuned down: the value
--- is there because the project needs to have finished starting, and a shorter
--- wait that works on a small project fails on a large one -- on the slowest
--- controller, in the least convenient house.
local STARTUP_NOTIFY_MS = 60000

do
  if C4.GetDriverConfigInfo then
    VERSION = C4:GetDriverConfigInfo("version")
  else
    VERSION = "unknown"
  end
end

ON_PROPERTY_CHANGED = {}
EC = {}

local function trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Whether a string is plausibly the Home Insights URL.
---
--- Not validation for safety -- the installer typed it and Composer is a
--- trusted surface. It is here so an EMPTY or half-pasted field reports itself
--- rather than loading a blank page that looks like a broken panel.
local function looksLikeUrl(url)
  return url:match("^https://[%w%.%-]+/") ~= nil
end

local function setStatus(text)
  C4:UpdateProperty("Status", text)
end

--- Pushes the current URL at the proxy.
local function publishUrl(reason)
  local url = trim(Properties["URL"])
  if url == "" then
    setStatus("No URL set")
    return
  end
  if not looksLikeUrl(url) then
    -- Said out loud rather than attempted. A malformed URL renders as an empty
    -- panel, which is indistinguishable from an outage to whoever is looking
    -- at it.
    setStatus("URL does not look right — expected https://…")
    return
  end
  C4:SendToProxy(WEBVIEW_PROXY_BINDINGID, "URL_CHANGED", { url = url })
  setStatus(string.format("URL published (%s) %s", reason, os.date("%Y-%m-%d %H:%M:%S")))
end

function OnDriverInit()
  C4:UpdateProperty("Driver Version", VERSION)
end

function OnDriverLateInit()
  C4:UpdateProperty("Driver Version", VERSION)
  publishUrl("load")
  aipresence.start({ file = "smartbuildos-insights.c4z" })
  -- See STARTUP_NOTIFY_MS. The first notify above is the common case; this one
  -- is what survives a controller reboot.
  C4:SetTimer(STARTUP_NOTIFY_MS, function()
    publishUrl("startup")
  end, false)
end

function OnDriverDestroyed()
  aipresence.stop()
end

--- This driver has no vendored handlers (no OSE table): Director's system
--- events reach AI Core presence here (OnDriverAdded / OnItemRemoved).
function OnSystemEvent(event)
  aipresence.onSystemEvent(event)
end

function OnPropertyChanged(name)
  aipresence.recheck() -- the bounded AI Core re-check (KI-42)
  local handler = ON_PROPERTY_CHANGED[name]
  if type(handler) == "function" then
    handler(Properties[name])
  end
end

function ON_PROPERTY_CHANGED.URL()
  publishUrl("edited")
end

function EC.RELOAD()
  publishUrl("manual")
end

--- Composer's Actions tab does not call a command by its own name. It sends
--- "LUA_ACTION" with the action's command in `ACTION`, so that is unwrapped
--- here. Without it an action runs nothing and reports nothing.
function ExecuteCommand(command, params)
  if command == "LUA_ACTION" and type(params) == "table" and params.ACTION ~= nil then
    command = params.ACTION
  end
  local handler = EC[command]
  if type(handler) == "function" then
    handler(params)
  end
end

function ReceivedFromProxy(binding, command)
  aipresence.recheck() -- proxy traffic: the bounded AI Core re-check (KI-42)
  -- Nothing to act on. The proxy's traffic is lifecycle -- the tile was shown,
  -- the URL was accepted -- and this driver has no state that depends on it.
  -- Logged rather than dropped so a future capability shows up in a log instead
  -- of being assumed absent.
  if command ~= nil then
    C4:DebugLog(string.format("Home Insights: proxy %s sent %s", tostring(binding), tostring(command)))
  end
end
