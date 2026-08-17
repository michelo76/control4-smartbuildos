--[[==========================================================================
  SmartBuildOS Home Insights — WebView driver

  Puts the Home Insights page on Control4 touchscreens and in the Control4 app.
  Companion to the SmartBuildOS Connector: the Connector is the sensor, this is
  the window.

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
  -- See STARTUP_NOTIFY_MS. The first notify above is the common case; this one
  -- is what survives a controller reboot.
  C4:SetTimer(STARTUP_NOTIFY_MS, function()
    publishUrl("startup")
  end, false)
end

function OnPropertyChanged(name)
  local handler = ON_PROPERTY_CHANGED[name]
  if type(handler) == "function" then
    handler(Properties[name])
  end
end

function ON_PROPERTY_CHANGED.URL()
  publishUrl("edited")
end

--- Asks the SmartBuildOS Connector in this project for its panel URL.
---
--- ⚠ EXPERIMENTAL. `C4:SendToDevice` between two DriverWorks drivers is
--- documented, but this particular exchange has NOT been measured on hardware,
--- and this repository's rule is that documentation is a hypothesis and the
--- controller is the answer. So it degrades: on no reply the installer pastes
--- the URL by hand, exactly as they would with Control4's own sample, and the
--- Status property says which happened rather than leaving them guessing.
function EC.PULL_URL()
  local connectorId
  for rawId, device in pairs(C4:GetDevices({}) or {}) do
    local id = tonumber(rawId)
    local name = tostring((type(device) == "table" and (device.deviceName or device.name)) or "")
    -- Matched on the DRIVER FILE, not the device name: a dealer is free to
    -- rename "SmartBuildOS Connector" to anything, and a name match would then
    -- silently find nothing and report it as "not installed".
    local file = tostring((type(device) == "table" and device.driverFileName) or "")
    if id and (file:find("smartbuildos", 1, true) and not file:find("insights", 1, true)) then
      connectorId = id
      break
    end
    if id and name == "SmartBuildOS Connector" then
      connectorId = id
    end
  end

  if connectorId == nil then
    setStatus("No SmartBuildOS Connector found in this project — paste the URL by hand")
    return
  end

  local ok = pcall(function()
    C4:SendToDevice(connectorId, "REQUEST_DISPLAY_URL", { requester = C4:GetDeviceID() })
  end)
  if not ok then
    setStatus("Connector did not accept the request — paste the URL by hand")
    return
  end
  setStatus("Asked the Connector for a URL — check back in a moment")
end

--- The Connector's answer, if it supports one.
function ReceivedFromDevice(_, command, params)
  if command ~= "DISPLAY_URL" then
    return
  end
  local url = trim(type(params) == "table" and params.url or "")
  if not looksLikeUrl(url) then
    setStatus("Connector replied with an unusable URL — paste it by hand")
    return
  end
  C4:UpdateProperty("URL", url)
  publishUrl("from connector")
end

function EC.RELOAD()
  publishUrl("manual")
end

function ExecuteCommand(command, params)
  local handler = EC[command]
  if type(handler) == "function" then
    handler(params)
  end
end

function ReceivedFromProxy(binding, command)
  -- Nothing to act on. The proxy's traffic is lifecycle -- the tile was shown,
  -- the URL was accepted -- and this driver has no state that depends on it.
  -- Logged rather than dropped so a future capability shows up in a log instead
  -- of being assumed absent.
  if command ~= nil then
    C4:DebugLog(string.format("Home Insights: proxy %s sent %s", tostring(binding), tostring(command)))
  end
end
