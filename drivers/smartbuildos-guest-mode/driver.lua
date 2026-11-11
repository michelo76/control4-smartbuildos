--[[==========================================================================
  SmartBuildOS Guest Mode
  Short-let and guest automation from the booking calendars a host already
  has (Airbnb, Booking.com, VRBO iCal feeds): who is in, who arrives today,
  when turnover is due — as Composer events, variables and conditionals.

  Pure rules: src/guestmode/{ical,stays,pin}.lua, tested without a controller.
  Licensing: the SmartBuildOS Agent (sbos.license, SKU SBOS_GUEST_MODE).
  The driver never programs a lock: a per-stay PIN is exposed as a variable
  and announced by events; the dealer wires the lock's own user-code
  programming to them.
============================================================================]]

--#ifdef DRIVERCENTRAL
DC_PID = 0
DC_X = nil
DC_FILENAME = "smartbuildos-guest-mode.c4z"
--#else
DRIVER_GITHUB_REPO = "michelo76/control4-smartbuildos"
DRIVER_FILENAMES = { "smartbuildos-guest-mode.c4z" }
--#endif

require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")
JSON = require("JSON")

local log = require("lib.logging")
local persist = require("lib.persist")
local http = require("lib.http")
local license = require("sbos.license")
local Ical = require("guestmode.ical")
local Stays = require("guestmode.stays")
local Pin = require("guestmode.pin")

gInitialized = false

local SKU = "SBOS_GUEST_MODE"
local STATE_KEY = "gm_state_v1"
local FEEDS_KEY = "gm_feeds_v1"
local PIN_KEY = "gm_pin_v1"
local WIFI_KEY = "gm_wifi_v1"
local TICK_TIMER = "GmTick"
local POLL_TIMER = "GmPoll"
local STATUS_TIMER = "GmStatusPaint"
local FEED_TIMEOUT = 20
local MAX_FEED_BYTES = 2 * 1024 * 1024

local EVENT_ARRIVING, EVENT_IN, EVENT_OUT, EVENT_TURNOVER, EVENT_VACANT = 1, 2, 3, 4, 5
local EVENT_CAL_DOWN, EVENT_CAL_UP, EVENT_PIN_CHANGED, EVENT_PIN_CLEARED = 6, 7, 8, 9

local gEngine = nil
local gFeeds = {} -- url -> { events = {...}, name, fetched_at, error }
local gLastEval = nil
local gLastError = "none"
local gLastPollAt = nil
local gCalendarsDown = false
local gLicenceHalted = false
local gPin = ""
local gWifi = ""
local gPollInFlight = 0

--- Seconds; a test pins the clock with GUEST_MODE_NOW.
local function now()
  if type(GUEST_MODE_NOW) == "function" then
    return GUEST_MODE_NOW()
  end
  return os.time()
end

local function fire(id)
  pcall(function()
    C4:FireEventByID(id)
  end)
end

local function setVar(name, value)
  pcall(function()
    C4:SetVariable(name, value)
  end)
end

local function stamp(epoch)
  if epoch == nil or epoch == math.huge then
    return "-"
  end
  return os.date("%a %d %b %H:%M", math.floor(epoch))
end

-- ─── Configuration from properties ─────────────────────────────────────────

local function urls()
  local out = {}
  for i = 1, 3 do
    local u = tostring(Properties["Calendar URL " .. i] or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if u ~= "" then
      out[#out + 1] = u
    end
  end
  return out
end

local function stayOptions(source)
  return {
    checkinMinutes = Stays.parseClock(Properties["Check-in Time"], 15 * 60),
    checkoutMinutes = Stays.parseClock(Properties["Check-out Time"], 11 * 60),
    blocksAre = tostring(Properties["Blocked Dates"] or ""):find("Occupied") and "occupied" or "ignore",
    source = source,
  }
end

local function turnoverSeconds()
  return (tonumber(Properties["Turnover Window"]) or 4) * 3600
end

local function pinEnabled()
  return tostring(Properties["Guest PIN"] or "Per Stay") == "Per Stay"
end

-- ─── Stays from the cached feeds ───────────────────────────────────────────

local function rebuildStays()
  if gEngine == nil then
    return
  end
  local all = {}
  for url, feed in pairs(gFeeds) do
    local events = type(feed) == "table" and feed.events or nil
    if type(events) == "table" then
      local built = Stays.build(events, stayOptions(feed.name or url), { mktime = os.time })
      for _, s in ipairs(built) do
        all[#all + 1] = s
      end
    end
  end
  table.sort(all, function(a, b)
    return a.start < b.start
  end)
  gEngine.turnoverSeconds = turnoverSeconds()
  gEngine:setStays(all)
end

local function persistState()
  if gEngine then
    persist:set(STATE_KEY, gEngine:serialize())
  end
end

-- ─── PIN ───────────────────────────────────────────────────────────────────

local function setPin(code, reason)
  code = tostring(code or "")
  if code == gPin then
    return
  end
  gPin = code
  persist:set(PIN_KEY, gPin, true)
  setVar("GUEST_PIN", gPin)
  if gPin ~= "" then
    log:info("Guest PIN changed (%s)", tostring(reason))
    fire(EVENT_PIN_CHANGED)
  else
    log:info("Guest PIN cleared (%s)", tostring(reason))
    fire(EVENT_PIN_CLEARED)
  end
end

local function newPin(reason)
  setPin(Pin.generate(tonumber(Properties["PIN Length"]) or 6, math.random, gPin), reason)
end

-- ─── Status ────────────────────────────────────────────────────────────────

local function guestStatus()
  if gEngine == nil then
    return "starting"
  end
  if gLicenceHalted then
    return "unlicensed"
  end
  return gEngine.state.status
end

local function calendarsLine()
  local list = urls()
  if #list == 0 then
    return "none configured"
  end
  local ok, bad = 0, 0
  for _, u in ipairs(list) do
    local f = gFeeds[u]
    if type(f) == "table" and f.events ~= nil then
      ok = ok + 1
    end
    if type(f) == "table" and f.error ~= nil then
      bad = bad + 1
    end
  end
  return string.format("%d configured, %d loaded%s", #list, ok, bad > 0 and (", " .. bad .. " failing") or "")
end

local function paint()
  local status = guestStatus()
  local ev = gLastEval
  UpdateProperty("Guest Status", status)
  UpdateProperty("Current Guest", ev and ev.current and ev.current.name or "-")
  UpdateProperty(
    "Next Check-in",
    ev and ev.nextStay and (stamp(ev.nextStay.start) .. " " .. tostring(ev.nextStay.name)) or "-"
  )
  UpdateProperty(
    "Next Check-out",
    ev and ev.current and ev.current.finish ~= math.huge and stamp(ev.current.finish)
      or (ev and ev.current and "open-ended (manual)")
      or "-"
  )
  UpdateProperty("Stays In 30 Days", tostring(ev and ev.staysNext30 or 0))
  UpdateProperty("Calendars", calendarsLine())
  UpdateProperty("Last Poll", gLastPollAt and os.date("%Y-%m-%d %H:%M:%S", gLastPollAt) or "never")
  UpdateProperty("Last Error", gLastError)
  setVar("GUEST_STATUS", status)
  setVar("GUEST_NAME", ev and ev.current and ev.current.name or "")
  setVar("NEXT_CHECKIN", ev and ev.nextStay and os.date("%Y-%m-%dT%H:%M", math.floor(ev.nextStay.start)) or "")
  setVar(
    "NEXT_CHECKOUT",
    ev and ev.current and ev.current.finish ~= math.huge and os.date("%Y-%m-%dT%H:%M", math.floor(ev.current.finish))
      or ""
  )
  setVar("STAYS_NEXT_30_DAYS", ev and ev.staysNext30 or 0)
  setVar("GUEST_PRESENT", (status == "occupied" or status == "departing_today") and "true" or "false")
  local okCount = 0
  for _, u in ipairs(urls()) do
    if type(gFeeds[u]) == "table" and gFeeds[u].events ~= nil and gFeeds[u].error == nil then
      okCount = okCount + 1
    end
  end
  setVar("CALENDARS_OK", okCount)
  setVar("LAST_ERROR", gLastError ~= "none" and gLastError or "")
end

-- ─── The clock tick ────────────────────────────────────────────────────────

local function tick()
  if gEngine == nil or gLicenceHalted then
    return
  end
  local t = now()
  local transitions, ev = gEngine:tick(t)
  gLastEval = ev
  for _, tr in ipairs(transitions) do
    if tr.kind == "arriving_today" then
      fire(EVENT_ARRIVING)
    elseif tr.kind == "checked_in" then
      fire(EVENT_IN)
      if pinEnabled() then
        newPin("check-in of " .. tostring(tr.name))
      end
    elseif tr.kind == "checked_out" then
      fire(EVENT_OUT)
      if pinEnabled() then
        setPin("", "check-out of " .. tostring(tr.name))
      end
    elseif tr.kind == "turnover_due" then
      fire(EVENT_TURNOVER)
    elseif tr.kind == "vacant" then
      fire(EVENT_VACANT)
    end
    log:info("Guest Mode: %s%s", tr.kind, tr.name and (" (" .. tostring(tr.name) .. ")") or "")
  end
  if #transitions > 0 then
    gEngine:prune(t)
    persistState()
  end
  paint()
end

-- ─── Calendars ─────────────────────────────────────────────────────────────

local function finishPoll()
  gPollInFlight = gPollInFlight - 1
  if gPollInFlight > 0 then
    return
  end
  gLastPollAt = now()
  local list = urls()
  local anyOk, anyConfigured = false, #list > 0
  for _, u in ipairs(list) do
    local f = gFeeds[u]
    if type(f) == "table" and f.error == nil and f.events ~= nil then
      anyOk = true
    end
  end
  if anyConfigured and not anyOk then
    if not gCalendarsDown then
      gCalendarsDown = true
      fire(EVENT_CAL_DOWN)
      log:warn("Every calendar failed to load; the last good data stays in force")
    end
  elseif gCalendarsDown then
    gCalendarsDown = false
    gLastError = "none"
    fire(EVENT_CAL_UP)
  end
  persist:set(FEEDS_KEY, gFeeds)
  rebuildStays()
  tick()
end

local function pollCalendars()
  if gLicenceHalted then
    return
  end
  local list = urls()
  -- Forget feeds whose URL was removed.
  local keep = {}
  for _, u in ipairs(list) do
    keep[u] = gFeeds[u] or {}
  end
  gFeeds = keep
  if #list == 0 then
    gLastPollAt = now()
    rebuildStays()
    tick()
    return
  end
  if gPollInFlight > 0 then
    return
  end
  gPollInFlight = #list
  for _, u in ipairs(list) do
    local url = u
    http
      :get(url, { ["Accept"] = "text/calendar, text/plain;q=0.5, */*;q=0.1" }, { timeout = FEED_TIMEOUT })
      :next(function(response)
        local body = response and response.body
        if type(body) ~= "string" or body == "" then
          gFeeds[url] = { events = gFeeds[url] and gFeeds[url].events or nil, error = "empty body", fetched_at = now() }
          gLastError = "calendar returned an empty body"
        elseif #body > MAX_FEED_BYTES then
          gFeeds[url] =
            { events = gFeeds[url] and gFeeds[url].events or nil, error = "feed too large", fetched_at = now() }
          gLastError = "calendar feed larger than 2 MB ignored"
        else
          local events, report = Ical.parse(body)
          gFeeds[url] = { events = events, name = report.calendarName, fetched_at = now(), report = report }
          if report.total == 0 and not body:find("VCALENDAR", 1, true) then
            gFeeds[url].error = "not an iCalendar document"
            gLastError = "a calendar URL did not return an iCalendar document"
          end
        end
        finishPoll()
      end, function(err)
        local code = type(err) == "table" and err.code or nil
        gFeeds[url] = {
          events = gFeeds[url] and gFeeds[url].events or nil,
          name = gFeeds[url] and gFeeds[url].name or nil,
          error = "HTTP " .. tostring(code or "failure"),
          fetched_at = now(),
        }
        gLastError = "calendar load failed (" .. tostring(code or "no answer") .. ")"
        finishPoll()
      end)
  end
end

local function armPoll()
  local minutes = tonumber(Properties["Poll Interval"]) or 30
  SetTimer(POLL_TIMER, minutes * ONE_MINUTE, pollCalendars, true)
end

-- ─── Licence ───────────────────────────────────────────────────────────────

local function reconcileLicence()
  local halt = license.enforces()
  if halt and not gLicenceHalted then
    gLicenceHalted = true
    CancelTimer(POLL_TIMER)
    gLastError = "SmartBuildOS licence: " .. tostring(license.statusLabel())
    log:warn("%s — Guest Mode halted", gLastError)
  elseif not halt and gLicenceHalted then
    gLicenceHalted = false
    gLastError = "none"
    armPoll()
    pollCalendars()
  end
end

-- ─── Lifecycle ─────────────────────────────────────────────────────────────

local function registerComposerSurface()
  for _, v in ipairs({
    { "GUEST_STATUS", "vacant", "STRING" },
    { "GUEST_NAME", "", "STRING" },
    { "NEXT_CHECKIN", "", "STRING" },
    { "NEXT_CHECKOUT", "", "STRING" },
    { "GUEST_PIN", "", "STRING" },
    { "GUEST_WIFI_PASSWORD", "", "STRING" },
    { "STAYS_NEXT_30_DAYS", 0, "NUMBER" },
    { "GUEST_PRESENT", "false", "BOOL" },
    { "CALENDARS_OK", 0, "NUMBER" },
    { "LAST_ERROR", "", "STRING" },
  }) do
    pcall(function()
      C4:AddVariable(v[1], v[2], v[3], true)
    end)
  end
  for _, e in ipairs({
    { 1, "Guest Arriving Today", "A stay checks in later today" },
    { 2, "Guest Checked In", "A stay began" },
    { 3, "Guest Checked Out", "A stay ended" },
    { 4, "Turnover Due", "A guest left within the Turnover Window and nobody is in yet" },
    { 5, "Property Vacant", "No guest, no arrival today, turnover window over" },
    { 6, "Calendar Unreachable", "Every configured calendar failed to load" },
    { 7, "Calendar Recovered", "A calendar loaded again" },
    { 8, "Guest PIN Changed", "GUEST_PIN holds a new code" },
    { 9, "Guest PIN Cleared", "GUEST_PIN was cleared at check-out" },
  }) do
    pcall(function()
      C4:AddEvent(e[1], e[2], e[3])
    end)
  end
end

function OnDriverInit()
  --#ifdef DRIVERCENTRAL
  require("cloud-client-byte")
  C4:AllowExecute(false)
  --#else
  C4:AllowExecute(true)
  --#endif
  gInitialized = false
  log:setLogName("GuestMode")
  log:setLogLevel(Properties["Log Level"])
  log:setLogMode(Properties["Log Mode"])
end

function OnDriverLateInit(reason)
  if not CheckMinimumVersion("Driver Status") then
    return
  end
  registerComposerSurface()
  for p, _ in pairs(Properties) do
    pcall(OnPropertyChanged, p)
  end

  gEngine = Stays.new({ date = os.date, turnoverSeconds = turnoverSeconds() })
  local stored = persist:get(STATE_KEY, false)
  if type(stored) == "table" then
    gEngine:restore(stored)
  end
  local feeds = persist:get(FEEDS_KEY, false)
  gFeeds = {}
  if type(feeds) == "table" then
    for url, f in pairs(feeds) do
      if type(url) == "string" and type(f) == "table" then
        gFeeds[url] = { events = f.events, name = f.name, fetched_at = f.fetched_at, error = f.error }
      end
    end
  end
  local storedPin = persist:get(PIN_KEY, false, true)
  gPin = type(storedPin) == "string" and storedPin or ""
  local storedWifi = persist:get(WIFI_KEY, false, true)
  gWifi = type(storedWifi) == "string" and storedWifi or ""
  setVar("GUEST_PIN", gPin)
  setVar("GUEST_WIFI_PASSWORD", gWifi)

  license.setup({ sku = SKU })
  EC.SBOS_ENTITLEMENT = function(tParams)
    license.onEntitlement(tParams)
    reconcileLicence()
    paint()
  end

  gInitialized = true
  UpdateProperty("Driver Status", "Online")
  pcall(function()
    UpdateProperty("Driver Version", tostring(C4:GetDriverConfigInfo("version")))
  end)

  rebuildStays()
  -- The first evaluation does not replay: the engine restored its last
  -- state, so only genuine changes since then fire.
  tick()
  armPoll()
  SetTimer(TICK_TIMER, ONE_MINUTE, tick, true)
  SetTimer(STATUS_TIMER, 5 * ONE_MINUTE, paint, true)
  -- First poll shortly after start (not in LateInit's own call stack).
  SetTimer("GmFirstPoll", 5 * ONE_SECOND, pollCalendars)
  paint()
end

function OnDriverDestroyed()
  pcall(license.stop) -- the licence retry timer
  persistState()
  CancelTimer(TICK_TIMER)
  CancelTimer(POLL_TIMER)
  CancelTimer(STATUS_TIMER)
  CancelTimer("GmFirstPoll")
end

-- ─── Properties ────────────────────────────────────────────────────────────

function OPC.Log_Level(value)
  log:setLogLevel(value)
  DEBUGPRINT = tostring(value):match("^5") ~= nil
end

function OPC.Log_Mode(value)
  log:setLogMode(value)
end

function OPC.Driver_Status()
  if not gInitialized then
    UpdateProperty("Driver Status", "Initializing", false)
  end
end

local function calendarProperty()
  if gInitialized then
    pollCalendars()
  end
end
OPC.Calendar_URL_1 = calendarProperty
OPC.Calendar_URL_2 = calendarProperty
OPC.Calendar_URL_3 = calendarProperty

function OPC.Poll_Interval()
  if gInitialized then
    armPoll()
  end
end

local function stayProperty()
  if gInitialized then
    rebuildStays()
    tick()
  end
end
OPC.Check_in_Time = stayProperty
OPC.Check_out_Time = stayProperty
OPC.Turnover_Window = stayProperty
OPC.Blocked_Dates = stayProperty

function OPC.Guest_PIN(value)
  if gInitialized and tostring(value) == "Off" and gPin ~= "" then
    setPin("", "Guest PIN turned off")
  end
end

-- ─── Actions ───────────────────────────────────────────────────────────────

function EC.POLL_NOW()
  pollCalendars()
end

function EC.POLL_CALENDARS()
  pollCalendars()
end

function EC.REGISTER_NOW()
  license.register()
end

function EC.REFRESH_STATUS()
  tick()
end

function EC.REGENERATE_PIN_ACTION()
  EC.REGENERATE_PIN({})
end

function EC.CLEAR_OVERRIDE()
  if gEngine then
    gEngine:clearOverrides()
    persistState()
    tick()
    log:info("Manual override cleared")
  end
end

function EC.PRINT_STATUS()
  log:print("== Guest Mode ==")
  log:print("  status: %s", guestStatus())
  log:print("  licence: %s", license.describe())
  log:print("  calendars: %s", calendarsLine())
  for url, f in pairs(gFeeds) do
    log:print(
      "   %s → %s%s%s",
      url:sub(1, 60),
      f.events and (#f.events .. " event(s)") or "no data",
      f.name and (" [" .. f.name .. "]") or "",
      f.error and (" ERROR " .. f.error) or ""
    )
  end
  local ev = gLastEval
  if ev then
    log:print("  current: %s", ev.current and (ev.current.name .. " until " .. stamp(ev.current.finish)) or "nobody")
    log:print("  next: %s", ev.nextStay and (ev.nextStay.name .. " from " .. stamp(ev.nextStay.start)) or "none")
    log:print("  stays in 30 days: %d", ev.staysNext30 or 0)
  end
  log:print("  pin: %s  wifi: %s", gPin ~= "" and "set" or "none", gWifi ~= "" and "set" or "none")
  log:print("  last error: %s", gLastError)
end

function EC.PRINT_STAYS()
  if gEngine == nil then
    return
  end
  log:print("== Guest Mode stays (%d) ==", #gEngine.stays)
  for _, s in ipairs(gEngine.stays) do
    log:print(
      "  %s → %s  %s%s%s",
      stamp(s.start),
      stamp(s.finish),
      s.name,
      s.block and " (blocked)" or "",
      gEngine.cutoffs[s.uid] and " (checked out early)" or ""
    )
  end
  if gEngine.manual then
    log:print(
      "  manual: %s from %s to %s",
      gEngine.manual.name,
      stamp(gEngine.manual.start),
      stamp(gEngine.manual.finish)
    )
  end
end

-- ─── Programming commands ─────────────────────────────────────────────────

function EC.CHECK_IN_NOW(tParams)
  tParams = tParams or {}
  if gEngine == nil or gLicenceHalted then
    return
  end
  local ok, why = gEngine:checkIn(now(), tParams.NAME)
  if not ok then
    log:warn("Check In Now refused: %s", tostring(why))
    return
  end
  persistState()
  tick()
end

function EC.CHECK_OUT_NOW()
  if gEngine == nil or gLicenceHalted then
    return
  end
  local ok, why = gEngine:checkOut(now())
  if not ok then
    log:warn("Check Out Now refused: %s", tostring(why))
    return
  end
  persistState()
  tick()
end

function EC.SET_GUEST_WIFI_PASSWORD(tParams)
  tParams = tParams or {}
  gWifi = tostring(tParams.PASSWORD or ""):sub(1, 63)
  persist:set(WIFI_KEY, gWifi, true)
  setVar("GUEST_WIFI_PASSWORD", gWifi)
end

function EC.REGENERATE_PIN()
  if gLicenceHalted then
    return
  end
  newPin("regenerate")
end

-- ─── Conditionals ─────────────────────────────────────────────────────────

function TC.GUEST_PRESENT()
  local s = guestStatus()
  return s == "occupied" or s == "departing_today"
end

function TC.ARRIVAL_TODAY()
  return guestStatus() == "arriving_today"
end

function TC.TURNOVER_ACTIVE()
  return guestStatus() == "turnover"
end

function TC.AGENT_READY()
  return license.isOperational() and license.agentDeviceId() ~= nil
end
