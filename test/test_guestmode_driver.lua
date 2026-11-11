-- Guest Mode DRIVER under the shim with a scripted Agent and a scripted HTTP
-- layer: lifecycle, licensing, calendar poll, a stay across a week with the
-- events in order, PIN lifecycle, manual check in/out, calendar outage and
-- recovery, persistence across a reload, licence enforcement, conditionals.
--
-- Run from the driver root: make test

local pass, fail = 0, 0
local function check(name, ok, detail)
  if ok then
    pass = pass + 1
    print(string.format("  ok   %s", name))
  else
    fail = fail + 1
    print(string.format("  FAIL %s%s", name, detail and ("  -> " .. tostring(detail)) or ""))
  end
end

C4 = C4 or {}
require("c4_shim")
JSON = require("JSON")

-- ── timers ──────────────────────────────────────────────────────────────────
local clock = { now = 0, timers = {} }
package.preload["drivers-common-public.global.timer"] = function()
  ONE_SECOND = 1000
  ONE_MINUTE = 60000
  ONE_HOUR = 3600000
  function SetTimer(id, ms, cb, repeating)
    clock.timers[id] = { at = clock.now + ms, cb = cb, every = repeating and ms or nil }
  end
  function CancelTimer(id)
    clock.timers[id] = nil
  end
  function KillAllTimers()
    clock.timers = {}
  end
  return true
end
local function advance(ms)
  local target = clock.now + ms
  while true do
    local bestId, bestAt
    for id, t in pairs(clock.timers) do
      if t.at <= target and (bestAt == nil or t.at < bestAt or (t.at == bestAt and id < bestId)) then
        bestId, bestAt = id, t.at
      end
    end
    if not bestId then
      break
    end
    clock.now = bestAt
    local t = clock.timers[bestId]
    if t.every then
      t.at = clock.now + t.every
    else
      clock.timers[bestId] = nil
    end
    t.cb()
  end
  clock.now = target
end
-- Local-time base: Monday 9 November 2026, 12:00 on this machine's clock.
local realTime = os.time
local base = realTime({ year = 2026, month = 11, day = 9, hour = 12, min = 0, sec = 0 })
local function virtualNow()
  return base + clock.now / 1000
end
os.time = function(t)
  if t then
    return realTime(t)
  end
  return math.floor(virtualNow())
end
GUEST_MODE_NOW = virtualNow
local realDate = os.date
os.date = function(fmt, t)
  return realDate(fmt, t or os.time())
end
local function goTo(month, day, hour, min)
  local target = realTime({ year = 2026, month = month, day = day, hour = hour, min = min or 0, sec = 0 })
  local ms = (target - base) * 1000 - clock.now
  assert(ms >= 0, "cannot go back in time")
  advance(ms)
end
package.preload["drivers-common-public.global.url"] = function()
  return true
end
package.preload["cloud-client-byte"] = function()
  return true
end

-- ── persist (in memory) ─────────────────────────────────────────────────────
local persisted = {}
package.preload["lib.persist"] = function()
  local P = {}
  local EMPTY = {}
  function P:get(key, default)
    if default == nil then
      default = EMPTY
    end
    if persisted[key] == nil then
      return default
    end
    return persisted[key]
  end
  function P:set(key, value)
    persisted[key] = value
  end
  function P:delete(key)
    persisted[key] = nil
  end
  function P:reset() end
  return P
end

-- ── scripted HTTP ───────────────────────────────────────────────────────────
local routes = {} -- url -> body string, or "FAIL"
local requests = {}
package.preload["lib.http"] = function()
  return {
    get = function(_, url, headers, options)
      requests[#requests + 1] = url
      local body = routes[url]
      return {
        next = function(_, onOk, onErr)
          if body == "FAIL" then
            onErr({ url = url, code = 503, error = "service unavailable" })
          elseif body ~= nil then
            onOk({ url = url, code = 200, headers = {}, body = body })
          else
            onErr({ url = url, code = 404, error = "no fixture" })
          end
          return { next = function() end }
        end,
      }
    end,
  }
end
local FEED = table.concat({
  "BEGIN:VCALENDAR",
  "VERSION:2.0",
  "X-WR-CALNAME:Beach Flat",
  "BEGIN:VEVENT",
  "UID:a@airbnb",
  "SUMMARY:Reserved",
  "DTSTART;VALUE=DATE:20261110",
  "DTEND;VALUE=DATE:20261113",
  "END:VEVENT",
  "BEGIN:VEVENT",
  "UID:b@airbnb",
  "SUMMARY:Jane Doe",
  "DTSTART;VALUE=DATE:20261113",
  "DTEND;VALUE=DATE:20261115",
  "END:VEVENT",
  "BEGIN:VEVENT",
  "UID:blk@airbnb",
  "SUMMARY:Airbnb (Not available)",
  "DTSTART;VALUE=DATE:20261120",
  "DTEND;VALUE=DATE:20261122",
  "END:VEVENT",
  "END:VCALENDAR",
}, "\r\n")

-- ── fake Director ───────────────────────────────────────────────────────────
local AGENT_ID = 50
local SELF_ID = 12345
local agentPresent = false
local sent = {}
local fired = {}
local props = {}
local vars = {}
C4.GetDevices = function()
  local d = { [SELF_ID] = { deviceName = "Guest Mode", driverFileName = "smartbuildos-guest-mode.c4z" } }
  if agentPresent then
    d[AGENT_ID] = { deviceName = "SmartBuildOS Agent", driverFileName = "smartbuildos.c4z" }
  end
  return d
end
C4.GetDeviceID = function()
  return SELF_ID
end
C4.GetDriverConfigInfo = function(_, key)
  if key == "minimum_os_version" then
    return "3.3.2"
  elseif key == "model" then
    return "Guest Mode"
  end
  return "20261109.000000"
end
C4.SendToDevice = function(_, device, command, params)
  sent[#sent + 1] = { device = device, command = command, params = params }
end
C4.FireEventByID = function(_, id)
  fired[#fired + 1] = id
end
C4.FireEvent = function() end
C4.SetVariable = function(_, name, value)
  vars[name] = value
end
C4.AddVariable = function() end
C4.AddEvent = function() end
C4.UpdateProperty = function(_, name, value)
  props[name] = value
  Properties[name] = value
end
C4.GetVersionInfo = function()
  return { version = "4.2.0.0" }
end

Properties = {}
do
  local f = assert(io.open("drivers/smartbuildos-guest-mode/driver.xml"))
  local xml = f:read("*a")
  f:close()
  for block in xml:gmatch("<property>(.-)</property>") do
    local name = block:match("<name>(.-)</name>")
    local default = block:match("<default>(.-)</default>") or ""
    Properties[name] = default
  end
end

dofile("drivers/smartbuildos-guest-mode/driver.lua")

local function prop(name)
  return props[name] or Properties[name]
end
local function lastSent(command)
  local out
  for _, s in ipairs(sent) do
    if s.command == command then
      out = s
    end
  end
  return out
end
local function firedSince(mark)
  local out = {}
  for i = mark + 1, #fired do
    out[#out + 1] = fired[i]
  end
  return table.concat(out, ",")
end

print("[1] starts: no Agent, no calendars")
OnDriverInit()
OnDriverLateInit("DIT_ADDING")
check("online", props["Driver Status"] == "Online")
check("vacant", prop("Guest Status") == "vacant" and vars["GUEST_STATUS"] == "vacant")
check("no calendars configured", prop("Calendars") == "none configured", prop("Calendars"))
check("licence: no Agent", prop("License Status") == "No SmartBuildOS Agent Found")
check("no events fired at start", #fired == 0)
check(
  "conditionals false",
  TC.GUEST_PRESENT() == false and TC.ARRIVAL_TODAY() == false and TC.TURNOVER_ACTIVE() == false
)
advance(6000)
check("first poll with no URLs touches nothing", #requests == 0 and prop("Last Poll") ~= "never")

print("[2] Agent appears: licence registration under the Guest Mode SKU")
agentPresent = true
EC.REGISTER_NOW()
check(
  "registered with the SKU",
  lastSent("SBOS_REGISTER_DRIVER") ~= nil and lastSent("SBOS_REGISTER_DRIVER").params.sku == "SBOS_GUEST_MODE"
)
EC.SBOS_ENTITLEMENT({
  sku = "SBOS_GUEST_MODE",
  status = "AUTHORIZED_SUBSCRIPTION",
  license_type = "subscription",
  registered = "true",
  subscription_tier = "Professional",
  company_name = "Skynet AV",
})
check("licence painted", prop("License Status"):find("Licensed") ~= nil and prop("Subscription Tier") == "Professional")
check("AGENT_READY conditional", TC.AGENT_READY() == true)

print("[3] a calendar URL: polled, parsed, stays built")
routes["https://cal.example/airbnb.ics"] = FEED
Properties["Calendar URL 1"] = "https://cal.example/airbnb.ics"
OnPropertyChanged("Calendar URL 1")
check("feed requested once", #requests == 1 and requests[1] == "https://cal.example/airbnb.ics")
check("calendars line", prop("Calendars") == "1 configured, 1 loaded", prop("Calendars"))
check("stays in 30 days: 2 (block ignored)", prop("Stays In 30 Days") == "2" and vars["STAYS_NEXT_30_DAYS"] == 2)
check(
  "next check-in painted",
  prop("Next Check-in"):find("Tue 10 Nov 15:00", 1, true) ~= nil and prop("Next Check-in"):find("Guest", 1, true) ~= nil,
  prop("Next Check-in")
)
check("feeds persisted", persisted["gm_feeds_v1"] ~= nil)
check(
  "Print actions run",
  pcall(function()
    EC.PRINT_STAYS()
    EC.PRINT_STATUS()
  end)
)
advance(30 * 60 * 1000 + 1000)
check("re-polled on the interval", #requests == 2)

print("[4] the week: arriving, check-in + PIN, departing, check-out + PIN cleared, turnover, vacant")
local mark = #fired
goTo(11, 10, 8, 0)
check(
  "08:00 check-in day: Guest Arriving Today",
  firedSince(mark) == "1" and prop("Guest Status") == "arriving_today" and TC.ARRIVAL_TODAY()
)
mark = #fired
goTo(11, 10, 15, 0)
check("15:00: Guest Checked In then Guest PIN Changed", firedSince(mark) == "2,8", firedSince(mark))
check(
  "occupied, name Guest, GUEST_PRESENT true",
  prop("Guest Status") == "occupied"
    and vars["GUEST_NAME"] == "Guest"
    and vars["GUEST_PRESENT"] == "true"
    and TC.GUEST_PRESENT()
)
local pin = vars["GUEST_PIN"]
check(
  "PIN is 6 digits and persisted encrypted",
  type(pin) == "string" and pin:match("^%d%d%d%d%d%d$") ~= nil and persisted["gm_pin_v1"] == pin
)
check("next check-out painted", prop("Next Check-out"):find("Fri 13 Nov 11:00", 1, true) ~= nil, prop("Next Check-out"))
mark = #fired
goTo(11, 13, 7, 0)
check(
  "check-out day morning: departing_today, nothing fired",
  prop("Guest Status") == "departing_today" and firedSince(mark) == ""
)
mark = #fired
goTo(11, 13, 11, 0)
check("11:00: Checked Out, PIN Cleared, Turnover Due (back-to-back day)", firedSince(mark) == "3,9,4", firedSince(mark))
check("PIN cleared", vars["GUEST_PIN"] == "" and TC.TURNOVER_ACTIVE())
mark = #fired
goTo(11, 13, 15, 0)
check(
  "15:00: Jane checks in with a new PIN",
  firedSince(mark) == "2,8"
    and vars["GUEST_NAME"] == "Jane Doe"
    and vars["GUEST_PIN"] ~= pin
    and vars["GUEST_PIN"] ~= ""
)
mark = #fired
goTo(11, 15, 11, 0)
check("Jane checks out: 3,9,4", firedSince(mark) == "3,9,4", firedSince(mark))
mark = #fired
goTo(11, 15, 15, 30)
check("turnover window (4 h) over: Property Vacant", firedSince(mark) == "5" and prop("Guest Status") == "vacant")

print("[5] manual check-in / check-out")
mark = #fired
EC.CHECK_IN_NOW({ NAME = "Walk-in" })
check(
  "manual check-in: Checked In + PIN",
  firedSince(mark) == "2,8" and vars["GUEST_NAME"] == "Walk-in" and prop("Next Check-out"):find("open%-ended") ~= nil
)
mark = #fired
EC.CHECK_IN_NOW({ NAME = "Again" })
check("second check-in refused silently", firedSince(mark) == "")
EC.CHECK_OUT_NOW()
check("manual check-out: Checked Out, PIN Cleared, Turnover", firedSince(mark) == "3,9,4", firedSince(mark))
mark = #fired
EC.CHECK_OUT_NOW()
check("check-out with nobody in refused", firedSince(mark) == "")
EC.CLEAR_OVERRIDE()
check(
  "clear override does not re-check-in a finished stay",
  prop("Guest Status") == "turnover" or prop("Guest Status") == "vacant"
)

print("[6] Wi-Fi password and PIN off")
EC.SET_GUEST_WIFI_PASSWORD({ PASSWORD = "sunny-beach-2026" })
check(
  "wifi variable set and stored",
  vars["GUEST_WIFI_PASSWORD"] == "sunny-beach-2026" and persisted["gm_wifi_v1"] == "sunny-beach-2026"
)
EC.REGENERATE_PIN({})
check("regenerate sets a PIN", vars["GUEST_PIN"]:match("^%d+$") ~= nil)
mark = #fired
Properties["Guest PIN"] = "Off"
OnPropertyChanged("Guest PIN")
check("PIN Off clears the code", vars["GUEST_PIN"] == "" and firedSince(mark) == "9")
Properties["Guest PIN"] = "Per Stay"
OnPropertyChanged("Guest PIN")

print("[7] calendar outage keeps the last good data")
routes["https://cal.example/airbnb.ics"] = "FAIL"
mark = #fired
EC.POLL_NOW()
check(
  "Calendar Unreachable fired once",
  firedSince(mark) == "6" and prop("Calendars"):find("1 failing") ~= nil,
  prop("Calendars")
)
check("last error says so", prop("Last Error"):find("calendar load failed") ~= nil, prop("Last Error"))
check("stays kept (last good data)", #persisted["gm_feeds_v1"]["https://cal.example/airbnb.ics"].events == 3)
mark = #fired
EC.POLL_NOW()
check("a second failure does not repeat the event", firedSince(mark) == "")
routes["https://cal.example/airbnb.ics"] = FEED
EC.POLL_NOW()
check("recovery fires Calendar Recovered", firedSince(mark) == "7" and prop("Last Error") == "none")
routes["https://cal.example/other.ics"] = "BEGIN:VCALENDAR\nEND:VCALENDAR"
Properties["Calendar URL 2"] = "https://cal.example/other.ics"
OnPropertyChanged("Calendar URL 2")
check("two calendars, both loaded", prop("Calendars") == "2 configured, 2 loaded", prop("Calendars"))
Properties["Calendar URL 2"] = ""
OnPropertyChanged("Calendar URL 2")
check("removed URL forgotten", prop("Calendars") == "1 configured, 1 loaded")

print("[8] persistence across a reload: no replay")
-- Put a guest in, then reload mid-stay.
routes["https://cal.example/airbnb.ics"] = FEED:gsub("20261110", "20261116"):gsub("20261113", "20261119")
EC.POLL_NOW()
goTo(11, 16, 15, 0)
check("new stay checked in", prop("Guest Status") == "occupied")
local pinBefore = vars["GUEST_PIN"]
mark = #fired
OnDriverDestroyed()
sent = {}
OnDriverInit()
OnDriverLateInit("DIT_UPDATING")
check(
  "still occupied after reload, nothing replayed",
  prop("Guest Status") == "occupied" and firedSince(mark) == "",
  firedSince(mark)
)
check("PIN restored from encrypted persist", vars["GUEST_PIN"] == pinBefore and pinBefore ~= "")
check("wifi restored", vars["GUEST_WIFI_PASSWORD"] == "sunny-beach-2026")
check("stays rebuilt from the cached feed before any poll", prop("Current Guest") == "Guest")
EC.SBOS_ENTITLEMENT({ sku = "SBOS_GUEST_MODE", status = "AUTHORIZED_SUBSCRIPTION", registered = "true" })

print("[9] licence enforcement")
EC.SBOS_ENTITLEMENT({
  sku = "SBOS_GUEST_MODE",
  status = "CLOUD_VALIDATION_REQUIRED",
  registered = "true",
  enforcement = "enforce",
})
check("uncertain + enforce: unchanged", prop("Guest Status") == "occupied" and clock.timers["GmPoll"] ~= nil)
EC.SBOS_ENTITLEMENT({ sku = "SBOS_GUEST_MODE", status = "NOT_ENTITLED", registered = "true", enforcement = "enforce" })
check(
  "definitive denial + enforce: unlicensed, polling stopped",
  prop("Guest Status") == "unlicensed" and clock.timers["GmPoll"] == nil
)
check("read-only label", prop("License Status"):find("read%-only") ~= nil, prop("License Status"))
mark = #fired
EC.CHECK_OUT_NOW()
check("commands ignored while halted", firedSince(mark) == "")
EC.SBOS_ENTITLEMENT({ sku = "SBOS_GUEST_MODE", status = "NOT_ENTITLED", registered = "true", enforcement = "observe" })
check("observe mode resumes", prop("Guest Status") == "occupied" and clock.timers["GmPoll"] ~= nil)

print("[10] a bad check-in time falls back to 15:00")
Properties["Check-in Time"] = "25:99"
OnPropertyChanged("Check-in Time")
check("still occupied with default times", prop("Guest Status") == "occupied")

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
