--[[==========================================================================
  SmartBuildOS Notification Router

  One Composer command — Notify (CHANNEL, PRIORITY, TITLE, MESSAGE) — and
  the router decides where it goes: Telegram, Pushover, a Slack/Discord
  webhook, a generic JSON webhook, Twilio SMS. Per target: enabled, minimum
  priority, quiet hours (critical bypasses). Across targets: dedupe window,
  hourly rate limit, three attempts with backoff, a delivery log the dealer
  prints from Composer. No 4Sight dependency, no cloud of ours in the path.

  Message variables: a TITLE or MESSAGE may carry ${1}..${4} (the variable
  picked in the command's VARIABLE 1..4 parameter, in the programming window)
  or ${Room->Device::VARIABLE} written out, as Control4's Push Notification
  agent writes it. Each is sent as the variable's live value.

  Pure rules: src/notify/router.lua (decisions, log),
  src/notify/formatters.lua (exact request per target) and
  src/notify/template.lua (message variables) — tested without a controller.
  Licensing: the SmartBuildOS Agent (SKU SBOS_NOTIFICATION_ROUTER).
============================================================================]]

--#ifdef DRIVERCENTRAL
DC_PID = 0
DC_X = nil
DC_FILENAME = "smartbuildos-notification-router.c4z"
--#else
DRIVER_GITHUB_REPO = "michelo76/control4-smartbuildos"
DRIVER_FILENAMES = { "smartbuildos-notification-router.c4z" }
--#endif

require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")
require("drivers-common-public.global.url")
JSON = require("JSON")

-- Every src module at module scope: the build discovers them by loading this
-- file under the shim, where a require inside a function is never seen.
local log = require("lib.logging")
local persist = require("lib.persist")
local http = require("lib.http")
local license = require("sbos.license")
local Router = require("notify.router")
local Formatters = require("notify.formatters")
local Template = require("notify.template")

gInitialized = false

local SKU = "SBOS_NOTIFICATION_ROUTER"
local LOG_KEY = "nr_log_v1"
local COUNTS_KEY = "nr_counts_v1"
local STATUS_TIMER = "NrStatusPaint"
local LOG_SAVE_TIMER = "NrLogSave"
local HTTP_TIMEOUT = 20
local PRINT_DEFAULT = 50

local EVENT_SENT, EVENT_FAILED, EVENT_UNREACHABLE, EVENT_QUIET, EVENT_RATE, EVENT_DEGRADED, EVENT_RESTORED =
  1, 2, 3, 4, 5, 6, 7
local EVENT_VARIABLE_MISSING = 8

--- Target table: id → Composer property names and the formatter kind.
local TARGETS = {
  {
    id = "telegram",
    kind = "telegram",
    label = "Telegram",
    prefix = "Telegram",
    config = function()
      return { bot_token = Properties["Telegram Bot Token"], chat_id = Properties["Telegram Chat ID"] }
    end,
  },
  {
    id = "pushover",
    kind = "pushover",
    label = "Pushover",
    prefix = "Pushover",
    config = function()
      return { app_token = Properties["Pushover App Token"], user_key = Properties["Pushover User Key"] }
    end,
  },
  {
    id = "webhook",
    kind = "webhook",
    label = "Webhook",
    prefix = "Webhook",
    config = function()
      return { url = Properties["Webhook URL"] }
    end,
  },
  {
    id = "generic",
    kind = "generic",
    label = "Generic Webhook",
    prefix = "Generic Webhook",
    config = function()
      return { url = Properties["Generic Webhook URL"], bearer = Properties["Generic Webhook Bearer Token"] }
    end,
  },
  {
    id = "twilio",
    kind = "twilio",
    label = "Twilio SMS",
    prefix = "Twilio",
    config = function()
      return {
        account_sid = Properties["Twilio Account SID"],
        auth_token = Properties["Twilio Auth Token"],
        from = Properties["Twilio From Number"],
        to = Properties["Twilio To Number"],
      }
    end,
  },
}

local gRouter = nil
local gPending = {} -- delivery id -> { target, request, msg, attempts, entry }
local gPendingSeq = 0
local gLastStatus = nil
local gLastError = "none"
local gLicenceHalted = false
local gCounts = { day = "", sent = 0, failed = 0 }
local gLastNotification = ""
local gLastFailedTarget = ""

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

local function isOn(value)
  return tostring(value or ""):lower() == "on"
end

local function today()
  return os.date("%Y-%m-%d")
end

local function rollDay()
  if gCounts.day ~= today() then
    gCounts = { day = today(), sent = 0, failed = 0 }
  end
end

-- ─── Targets from properties ────────────────────────────────────────────────

local function targetList()
  local out = {}
  for _, t in ipairs(TARGETS) do
    local p = t.prefix
    out[#out + 1] = {
      id = t.id,
      kind = t.kind,
      label = t.label,
      enabled = isOn(Properties[p == "Twilio" and "Twilio SMS" or p]),
      min_priority = Router.parsePriority(Properties[p .. " Minimum Priority"]),
      quiet_start = Properties[p .. " Quiet Start"],
      quiet_end = Properties[p .. " Quiet End"],
      config = t.config(),
    }
  end
  return out
end

local function targetById(id)
  for _, t in ipairs(targetList()) do
    if t.id == id then
      return t
    end
  end
  return nil
end

--- Targets that are on AND have their credentials: what Composer sees as ready.
local function readyTargets()
  local ready = {}
  for _, t in ipairs(targetList()) do
    if t.enabled then
      local req = Formatters.build(
        t,
        { title = "probe", body = "", priority = 1, channel = "all" },
        os.time(),
        function(s)
          return C4:Base64Encode(s)
        end
      )
      if req ~= nil then
        ready[#ready + 1] = t.label
      end
    end
  end
  return ready
end

local function minuteOfDay()
  local t = os.date("*t")
  return t.hour * 60 + t.min
end

-- ─── Message variables ──────────────────────────────────────────────────────

local function readVariables(deviceId)
  local ok, vars = pcall(function()
    return C4:GetDeviceVariables(deviceId)
  end)
  if ok and type(vars) == "table" then
    return vars
  end
  return nil
end

local function projectDevices()
  local ok, list = pcall(function()
    return C4:GetDevices({})
  end)
  if ok and type(list) == "table" then
    return list
  end
  return {}
end

-- ─── Status ─────────────────────────────────────────────────────────────────

local function pendingCount()
  local n = 0
  for _ in pairs(gPending) do
    n = n + 1
  end
  return n
end

local function routerStatus()
  if gRouter == nil then
    return "starting"
  end
  if gLicenceHalted then
    return "unlicensed"
  end
  if #readyTargets() == 0 then
    return "no_targets"
  end
  if pendingCount() > 0 then
    return "sending"
  end
  return "ready"
end

local function paint()
  rollDay()
  local status = routerStatus()
  local ready = readyTargets()
  UpdateProperty("Router Status", status)
  UpdateProperty("Targets Ready", #ready > 0 and table.concat(ready, ", ") or "none")
  UpdateProperty("Last Notification", gLastNotification ~= "" and gLastNotification or "none yet")
  UpdateProperty("Sent Today", tostring(gCounts.sent))
  UpdateProperty("Failed Today", tostring(gCounts.failed))
  UpdateProperty("Last Router Error", gLastError)
  setVar("ROUTER_STATUS", status)
  setVar("LAST_NOTIFICATION", gLastNotification)
  setVar("SENT_TODAY", gCounts.sent)
  setVar("FAILED_TODAY", gCounts.failed)
  setVar("LAST_FAILED_TARGET", gLastFailedTarget)
  setVar("PENDING_DELIVERIES", pendingCount())
  local healthy = status == "ready" or status == "sending"
  if gLastStatus ~= nil and gLastStatus ~= healthy then
    fire(healthy and EVENT_RESTORED or EVENT_DEGRADED)
  end
  gLastStatus = healthy
end

local function saveLogSoon()
  SetTimer(LOG_SAVE_TIMER, 5 * ONE_SECOND, function()
    if gRouter then
      persist:set(LOG_KEY, { log = gRouter.log, seq = gRouter.seq })
      persist:set(COUNTS_KEY, gCounts)
    end
  end)
end

-- ─── Sending ────────────────────────────────────────────────────────────────

local function finishDelivery(id, status, detail)
  local d = gPending[id]
  if d == nil then
    return
  end
  gPending[id] = nil
  CancelTimer("NrRetry:" .. id)
  rollDay()
  d.entry.status = status
  d.entry.attempts = d.attempts
  d.entry.detail = (d.entry.via and (d.entry.via .. " · ") or "") .. tostring(detail or "")
  d.entry.t = os.time()
  gRouter:record(d.entry)
  if status == "sent" then
    gCounts.sent = gCounts.sent + 1
    fire(EVENT_SENT)
  else
    gCounts.failed = gCounts.failed + 1
    gLastFailedTarget = d.target.label
    gLastError = string.format("%s: %s", d.target.label, tostring(detail or "failed"))
    fire(EVENT_FAILED)
  end
  saveLogSoon()
  paint()
end

local attempt -- forward

local function scheduleRetry(id, detail)
  local d = gPending[id]
  if d == nil then
    return
  end
  local delay = Router.retryDelay(d.attempts)
  if delay == nil then
    finishDelivery(id, "failed", detail)
    return
  end
  if d.attempts == 1 then
    fire(EVENT_UNREACHABLE)
  end
  gRouter:record({
    target = d.target.label,
    status = "retrying",
    title = d.msg.title,
    attempts = d.attempts,
    detail = tostring(detail or ""):sub(1, 160),
  })
  log:warn("%s attempt %d failed (%s); retry in %ds", d.target.label, d.attempts, tostring(detail), delay)
  SetTimer("NrRetry:" .. id, delay * ONE_SECOND, function()
    attempt(id)
  end)
end

attempt = function(id)
  local d = gPending[id]
  if d == nil then
    return
  end
  if gLicenceHalted then
    finishDelivery(id, "failed", "licence enforcement")
    return
  end
  d.attempts = d.attempts + 1
  local req = d.request
  local ok, deferred = pcall(function()
    return http:request(req.method, req.url, req.body, req.headers, { timeout = HTTP_TIMEOUT })
  end)
  if not ok or deferred == nil then
    scheduleRetry(id, "request not started: " .. tostring(deferred))
    return
  end
  deferred:next(function(response)
    local code = response and response.code or 0
    finishDelivery(id, "sent", "HTTP " .. tostring(code))
  end, function(err)
    local code = type(err) == "table" and err.code or nil
    local why = code and ("HTTP " .. tostring(code)) or "no response"
    -- 4xx (other than 408/429) is a configuration error: retrying the same
    -- request cannot help, and the log must say so at once.
    if code and code >= 400 and code < 500 and code ~= 408 and code ~= 429 then
      finishDelivery(id, "failed", why .. " (check the target's settings)")
    else
      scheduleRetry(id, why)
    end
  end)
end

--- Routes one message: decisions → log entries → deliveries in flight.
local function dispatch(msg, source)
  if gRouter == nil then
    return 0
  end
  if gLicenceHalted then
    gRouter:record({ target = "-", status = "unlicensed", title = msg.title, detail = "licence enforcement: not sent" })
    saveLogSoon()
    return 0
  end
  gLastNotification = string.format("%s (%s)", msg.title, Router.PRIORITY_NAMES[msg.priority] or "normal")
  local decisions, sends, matched = gRouter:route(msg)
  if matched == 0 then
    gLastError = "no target called '" .. tostring(msg.channel) .. "'"
    gRouter:record({
      target = tostring(msg.channel),
      status = "no_target",
      title = msg.title,
      detail = "unknown channel",
    })
  end
  local started = 0
  for _, d in ipairs(decisions) do
    if d.decision == "send" then
      if pendingCount() >= Router.LIMITS.pending_max then
        gRouter:record({
          target = d.target.label,
          status = "dropped",
          title = msg.title,
          detail = "too many deliveries in flight",
        })
      else
        local req, why = Formatters.build(d.target, msg, os.time(), function(s)
          return C4:Base64Encode(s)
        end)
        if req == nil then
          gLastError = why
          gRouter:record({ target = d.target.label, status = "failed", title = msg.title, attempts = 0, detail = why })
          rollDay()
          gCounts.failed = gCounts.failed + 1
          gLastFailedTarget = d.target.label
          fire(EVENT_FAILED)
        else
          gPendingSeq = gPendingSeq + 1
          local id = tostring(gPendingSeq)
          gPending[id] = {
            target = d.target,
            request = req,
            msg = msg,
            attempts = 0,
            entry = { target = d.target.label, title = msg.title, via = req.describe, source = source },
          }
          started = started + 1
          attempt(id)
        end
      end
    else
      gRouter:record({ target = d.target.label, status = d.reason, title = msg.title, detail = source })
      if d.reason == "quiet_hours" then
        fire(EVENT_QUIET)
      elseif d.reason == "rate_limited" then
        fire(EVENT_RATE)
      end
    end
  end
  saveLogSoon()
  paint()
  return started
end

-- ─── Licence ────────────────────────────────────────────────────────────────

local function reconcileLicence()
  local halt = license.enforces()
  if halt and not gLicenceHalted then
    gLicenceHalted = true
    gLastError = "SmartBuildOS licence: " .. tostring(license.statusLabel())
    log:warn("%s — sending halted", gLastError)
  elseif not halt and gLicenceHalted then
    gLicenceHalted = false
    gLastError = "none"
  end
end

-- ─── Lifecycle ──────────────────────────────────────────────────────────────

local function registerComposerSurface()
  for _, v in ipairs({
    { "ROUTER_STATUS", "starting", "STRING" },
    { "LAST_NOTIFICATION", "", "STRING" },
    { "SENT_TODAY", 0, "NUMBER" },
    { "FAILED_TODAY", 0, "NUMBER" },
    { "LAST_FAILED_TARGET", "", "STRING" },
    { "PENDING_DELIVERIES", 0, "NUMBER" },
  }) do
    pcall(function()
      C4:AddVariable(v[1], v[2], v[3], true)
    end)
  end
  for _, e in ipairs({
    { 1, "Notification Sent", "A notification was accepted by a target" },
    { 2, "Delivery Failed", "A notification was not accepted after every retry" },
    { 3, "Target Unreachable", "A target failed on the first attempt; retries are under way" },
    { 4, "Quiet Hours Suppressed", "A notification was held back by quiet hours" },
    { 5, "Rate Limited", "A target reached its hourly limit" },
    { 6, "Router Degraded", "Sending stopped" },
    { 7, "Router Restored", "Sending is possible again" },
    { 8, "Message Variable Missing", "A variable in a notification could not be read and was sent as ?" },
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
  log:setLogName("NotificationRouter")
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

  gRouter = Router.new({
    now = os.time,
    minuteOfDay = minuteOfDay,
    targets = targetList,
    dedupe_seconds = function()
      return tonumber(Properties["Dedupe Window"])
    end,
    per_hour = function()
      return tonumber(Properties["Rate Limit Per Hour"])
    end,
  })
  local stored = persist:get(LOG_KEY, false)
  if type(stored) == "table" and type(stored.log) == "table" then
    gRouter.log = stored.log
    gRouter.seq = tonumber(stored.seq) or #stored.log
  end
  local counts = persist:get(COUNTS_KEY, false)
  if type(counts) == "table" and counts.day == today() then
    gCounts = counts
  end

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
  SetTimer(STATUS_TIMER, 60 * ONE_SECOND, paint, true)
  paint()
end

function OnDriverDestroyed()
  if gRouter then
    persist:set(LOG_KEY, { log = gRouter.log, seq = gRouter.seq })
    persist:set(COUNTS_KEY, gCounts)
  end
  for id in pairs(gPending) do
    CancelTimer("NrRetry:" .. id)
  end
  CancelTimer(STATUS_TIMER)
  CancelTimer(LOG_SAVE_TIMER)
end

-- ─── Properties ─────────────────────────────────────────────────────────────

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

local function repaint()
  if gInitialized then
    paint()
  end
end
for _, t in ipairs(TARGETS) do
  local key = (t.prefix == "Twilio" and "Twilio_SMS" or t.prefix:gsub(" ", "_"))
  OPC[key] = repaint
end
-- ─── Actions ────────────────────────────────────────────────────────────────

function EC.REGISTER_NOW()
  license.register()
end

function EC.REFRESH_STATUS()
  paint()
end

function EC.CLEAR_LOG()
  if gRouter then
    gRouter.log = {}
    persist:set(LOG_KEY, { log = {}, seq = gRouter.seq })
    log:info("Delivery log cleared")
  end
end

local function sendTest(id)
  local target = targetById(id)
  if target == nil then
    return
  end
  if not target.enabled then
    gLastError = target.label .. " is Off"
    paint()
    log:warn("%s is Off; turn it On before testing", target.label)
    return
  end
  local msg = Router.message({
    channel = id,
    priority = "normal",
    title = "Control4 test",
    body = "Test notification from the SmartBuildOS Notification Router (" .. os.date("%Y-%m-%d %H:%M") .. ")",
  })
  -- A test bypasses dedupe so a second click sends again.
  gRouter.recent = {}
  dispatch(msg, "test")
end

function EC.TEST_TELEGRAM()
  sendTest("telegram")
end
function EC.TEST_PUSHOVER()
  sendTest("pushover")
end
function EC.TEST_WEBHOOK()
  sendTest("webhook")
end
function EC.TEST_GENERIC()
  sendTest("generic")
end
function EC.TEST_TWILIO()
  sendTest("twilio")
end

function EC.PRINT_STATUS()
  log:print("== Notification Router ==")
  log:print("  status: %s", routerStatus())
  log:print("  licence: %s", license.describe())
  log:print("  targets ready: %s", table.concat(readyTargets(), ", "))
  for _, t in ipairs(targetList()) do
    log:print(
      "  %-16s %s  min=%s  quiet=%s..%s",
      t.label,
      t.enabled and "on " or "off",
      Router.PRIORITY_NAMES[t.min_priority],
      tostring(t.quiet_start or ""),
      tostring(t.quiet_end or "")
    )
  end
  log:print(
    "  dedupe %ss, %s per hour per target",
    tostring(Properties["Dedupe Window"]),
    tostring(Properties["Rate Limit Per Hour"])
  )
  log:print("  pending deliveries: %d", pendingCount())
  if gRouter then
    local keys = {}
    for k in pairs(gRouter.counters) do
      keys[#keys + 1] = k
    end
    table.sort(keys)
    for _, k in ipairs(keys) do
      log:print("  %s = %s", k, tostring(gRouter.counters[k]))
    end
  end
end

function EC.PRINT_LOG()
  if gRouter == nil then
    return
  end
  local list = gRouter:recent_log(PRINT_DEFAULT)
  log:print("== Notification Router: last %d deliveries ==", #list)
  for _, e in ipairs(list) do
    log:print("  %s", Router.formatEntry(e))
  end
end

-- ─── Composer programming commands ─────────────────────────────────────────

local CHANNEL_BY_LABEL = {
  all = "all",
  telegram = "telegram",
  pushover = "pushover",
  webhook = "webhook",
  ["generic webhook"] = "generic",
  ["twilio sms"] = "twilio",
}

--- The VARIABLE n parameter of a command: Composer's variable picker hands
--- the driver "deviceId,variableId" (bench 2026-11-10), or "" when unset.
local function pickedFrom(tParams)
  return function(n)
    return tParams["VARIABLE " .. n]
  end
end

function EC.NOTIFY(tParams)
  tParams = tParams or {}
  local channel = CHANNEL_BY_LABEL[tostring(tParams.CHANNEL or "All"):lower()] or tostring(tParams.CHANNEL or "all")
  -- Values are read now, each device once, and the filled-in text is what
  -- the router trims, logs and de-duplicates.
  local picked = pickedFrom(tParams)
  local resolve = Template.resolver({ picked = picked, devices = projectDevices, readVariables = readVariables })
  local title, body, problems = Template.fill(tParams.TITLE, tParams.MESSAGE, resolve, picked)
  local msg, why = Router.message({
    channel = channel,
    priority = tParams.PRIORITY,
    title = title,
    body = body,
  })
  if msg == nil then
    log:warn("NOTIFY ignored: %s", tostring(why))
    gLastError = tostring(why)
    paint()
    return
  end
  local report = #problems > 0 and gRouter ~= nil and not gLicenceHalted
  if report then
    for _, p in ipairs(problems) do
      gRouter:record({
        target = "-",
        status = "variable",
        title = msg.title,
        detail = string.format("%s: %s", p.token, p.reason),
      })
      log:warn("variable %s not filled: %s", p.token, p.reason)
    end
    gRouter.counters.variable_missing = (gRouter.counters.variable_missing or 0) + #problems
    fire(EVENT_VARIABLE_MISSING)
  end
  dispatch(msg, "programming")
  if report then
    gLastError = string.format("variable %s: %s", problems[1].token, problems[1].reason)
    paint()
  end
end

function EC.NOTIFY_ALL(tParams)
  tParams = tParams or {}
  local all = { CHANNEL = "All", PRIORITY = tParams.PRIORITY, TITLE = tParams.TITLE, MESSAGE = tParams.MESSAGE }
  for n = 1, Template.PICKS do
    all["VARIABLE " .. n] = tParams["VARIABLE " .. n]
  end
  EC.NOTIFY(all)
end

-- ─── Conditionals ───────────────────────────────────────────────────────────

function TC.ROUTER_READY()
  return not gLicenceHalted and #readyTargets() > 0
end

function TC.QUIET_HOURS_ACTIVE()
  local minute = minuteOfDay()
  local enabled, quiet = 0, 0
  for _, t in ipairs(targetList()) do
    if t.enabled then
      enabled = enabled + 1
      if Router.inQuietHours(t.quiet_start, t.quiet_end, minute) then
        quiet = quiet + 1
      end
    end
  end
  return enabled > 0 and quiet == enabled
end
