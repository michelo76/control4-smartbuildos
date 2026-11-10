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
local Inbound = require("notify.inbound")

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
local EVENT_RECEIVED, EVENT_TELEGRAM_RECEIVED, EVENT_SMS_RECEIVED, EVENT_REJECTED = 9, 10, 11, 12
local EVENT_KEYWORD_BASE = 20 -- Keyword N Received is 20 + N
local INBOUND_KEY = "nr_inbound_v1"
local POLL_TIMER = "NrInboundPoll"
local CHANNEL_LABEL = { telegram = "Telegram", twilio = "Twilio SMS" }
local INBOUND_PROPERTY = { telegram = "Telegram Inbound", twilio = "Twilio Inbound" }
local REFUSAL = {
  not_allowed = "sender is not on the allow-list",
  bad_pin = "the Inbound PIN was missing or wrong",
  rate_limited = "too many messages in a minute",
  stale = "older than the replay window",
}

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
local gInbox = nil
local gInbound = {
  telegram = { offset = nil, busy = false, failures = 0, nextAt = 0, status = "off" },
  twilio = { busy = false, failures = 0, nextAt = 0, status = "off" },
}
local gLast = nil -- the last message taken: { channel, chat, sender, text }
local gMessageCounter = 0
local inboundPollSeconds, inboundMaxAge, inboundStatus, pollInbound, startInbound -- defined with the inbound code

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
    gCounts = { day = today(), sent = 0, failed = 0, received = 0 }
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
  UpdateProperty("Inbound Status", inboundStatus())
  UpdateProperty("Received Today", tostring(gCounts.received or 0))
  setVar("MESSAGES_RECEIVED_TODAY", gCounts.received or 0)
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

local function saveNow()
  if gRouter then
    persist:set(LOG_KEY, { log = gRouter.log, seq = gRouter.seq })
    persist:set(COUNTS_KEY, gCounts)
  end
  if gInbox then
    persist:set(INBOUND_KEY, {
      telegram_offset = gInbound.telegram.offset,
      seen = gInbox:export(),
      last = gLast,
      counter = gMessageCounter,
    })
  end
end

local function saveLogSoon()
  SetTimer(LOG_SAVE_TIMER, 5 * ONE_SECOND, saveNow)
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

--- Sends one message to one target without the per-target rules (a reply to
--- a message just received must not wait for quiet hours to end): only the
--- hourly rate limit, the pending bound and licence enforcement apply.
local function sendDirect(target, msg, source)
  if gLicenceHalted then
    gRouter:record({ target = "-", status = "unlicensed", title = msg.title, detail = "licence enforcement: not sent" })
    saveLogSoon()
    return 0
  end
  gLastNotification = string.format("%s (%s)", msg.title, source)
  local refused = nil
  if pendingCount() >= Router.LIMITS.pending_max then
    refused = { "dropped", "too many deliveries in flight" }
  elseif not gRouter:reserve(target.id) then
    refused = { "rate_limited", source }
    fire(EVENT_RATE)
  end
  local req, why
  if refused == nil then
    req, why = Formatters.build(target, msg, os.time(), function(s)
      return C4:Base64Encode(s)
    end)
    if req == nil then
      refused = { "failed", why }
      gLastError = why
      rollDay()
      gCounts.failed = gCounts.failed + 1
      gLastFailedTarget = target.label
      fire(EVENT_FAILED)
    end
  end
  if refused ~= nil then
    gRouter:record({ target = target.label, status = refused[1], title = msg.title, detail = refused[2] })
    saveLogSoon()
    paint()
    return 0
  end
  gPendingSeq = gPendingSeq + 1
  local id = tostring(gPendingSeq)
  gPending[id] = {
    target = target,
    request = req,
    msg = msg,
    attempts = 0,
    entry = { target = target.label, title = msg.title, via = req.describe, source = source },
  }
  attempt(id)
  saveLogSoon()
  paint()
  return 1
end

-- ─── Inbound: messages sent to the house ───────────────────────────────────
--
-- The controller cannot be called from outside, so it asks: Telegram's
-- getUpdates and Twilio's message list, on a timer, with the credentials the
-- targets already hold. Who is taken, replay protection, the PIN and the
-- keywords are src/notify/inbound.lua; here are the requests, the variables
-- and the events.

inboundPollSeconds = function()
  local n = tonumber(Properties["Inbound Poll Seconds"]) or 5
  return math.max(3, math.min(n, 300))
end

--- A message is taken only while it is fresh. The window follows the poll
--- interval so a slow poll does not turn every message stale.
inboundMaxAge = function()
  return math.max(Inbound.LIMITS.max_age, inboundPollSeconds() * 3)
end

local function inboundOn(channel)
  return isOn(Properties[INBOUND_PROPERTY[channel]])
end

inboundStatus = function()
  local parts = {}
  for _, channel in ipairs({ "telegram", "twilio" }) do
    if inboundOn(channel) then
      parts[#parts + 1] = CHANNEL_LABEL[channel] .. ": " .. tostring(gInbound[channel].status)
    end
  end
  if #parts == 0 then
    return "off"
  end
  if gLicenceHalted then
    return "halted by licence enforcement"
  end
  return table.concat(parts, " · ")
end

local function maskSender(msg)
  if msg.channel == "twilio" then
    return (tostring(msg.sender):gsub("%d%d%d%d$", "****"))
  end
  return "chat " .. tostring(msg.chat)
end

--- One message from a poll: decided by the inbox, then variables first and
--- events after, so programming on an event reads the new values.
local function handleInbound(msg)
  local r = gInbox:accept(msg)
  local label = CHANNEL_LABEL[msg.channel] or tostring(msg.channel)
  if r.outcome == "duplicate" or r.outcome == "bot" or r.outcome == "empty" then
    return
  end
  if r.outcome ~= "received" then
    -- The text of a refused message is never kept: it may hold a mistyped PIN.
    local why = REFUSAL[r.outcome] or r.outcome
    gRouter:record({
      target = label,
      status = r.outcome == "stale" and "stale" or "rejected",
      title = "",
      detail = why .. " · from " .. maskSender(msg),
    })
    if r.outcome ~= "stale" then
      gLastError = label .. " message refused: " .. why
      fire(EVENT_REJECTED)
      paint()
    end
    saveLogSoon()
    return
  end
  rollDay()
  gCounts.received = (gCounts.received or 0) + 1
  gMessageCounter = gMessageCounter + 1
  gLast = { channel = msg.channel, chat = msg.chat, sender = msg.sender, text = r.text }
  setVar("LAST_MESSAGE", r.text)
  setVar("LAST_MESSAGE_CHANNEL", label)
  setVar("LAST_MESSAGE_SENDER", tostring(msg.username or msg.sender or ""))
  setVar("LAST_MESSAGE_ARGUMENT", r.argument or "")
  setVar("LAST_KEYWORD", r.keyword or "")
  setVar(msg.channel == "twilio" and "SMS_LAST_MESSAGE" or "TELEGRAM_LAST_MESSAGE", r.text)
  setVar("MESSAGE_COUNTER", gMessageCounter)
  UpdateProperty("Last Message", string.format("%s: %s", label, r.text:sub(1, 80)))
  gRouter:record({
    target = label,
    status = "received",
    title = r.text:sub(1, 60),
    detail = "from " .. maskSender(msg) .. (r.keyword_index and (" · keyword " .. r.keyword_index) or ""),
  })
  fire(EVENT_RECEIVED)
  fire(msg.channel == "twilio" and EVENT_SMS_RECEIVED or EVENT_TELEGRAM_RECEIVED)
  if r.keyword_index then
    fire(EVENT_KEYWORD_BASE + r.keyword_index)
  end
  saveLogSoon()
  paint()
end

--- lib.http hands back a decoded table for a JSON answer, or the text.
local function decodeBody(body)
  if type(body) == "table" then
    return body
  end
  if type(body) == "string" and body ~= "" then
    local ok, decoded = pcall(function()
      return JSON:decode(body)
    end)
    if ok and type(decoded) == "table" then
      return decoded
    end
  end
  return nil
end

local function pollFailed(channel, why)
  local st = gInbound[channel]
  st.busy = false
  st.failures = st.failures + 1
  -- Back off: twice the interval per failure in a row, five minutes at most.
  st.nextAt = os.time() + math.min(300, inboundPollSeconds() * 2 ^ math.min(st.failures, 6))
  if st.status ~= why then
    st.status = why
    log:warn("%s inbound: %s", CHANNEL_LABEL[channel], tostring(why))
    paint()
  end
end

local function pollOk(channel)
  local st = gInbound[channel]
  st.busy = false
  st.failures = 0
  st.nextAt = 0
  if st.status ~= "listening" then
    st.status = "listening"
    paint()
  end
end

local function httpWhy(err, hints)
  local code = type(err) == "table" and err.code or nil
  if code and hints[code] then
    return "HTTP " .. code .. ": " .. hints[code]
  end
  return code and ("HTTP " .. tostring(code)) or "no response"
end

--- Sends one inbound request. `onBody` gets the decoded answer and returns
--- nil, or a reason the answer could not be used.
local function ask(channel, req, hints, onBody)
  local st = gInbound[channel]
  st.busy = true
  local ok, deferred = pcall(function()
    return http:request(req.method, req.url, nil, req.headers, { timeout = HTTP_TIMEOUT })
  end)
  if not ok or deferred == nil then
    pollFailed(channel, "request not started")
    return
  end
  deferred:next(function(response)
    local why = onBody(decodeBody(response and response.body))
    if why ~= nil then
      pollFailed(channel, why)
    else
      pollOk(channel)
    end
  end, function(err)
    pollFailed(channel, httpWhy(err, hints))
  end)
end

local function pollTelegram()
  local st = gInbound.telegram
  local req, why = Inbound.telegramRequest({ bot_token = Properties["Telegram Bot Token"] }, st.offset)
  if req == nil then
    st.status = why
    return
  end
  ask("telegram", req, {
    [401] = "check the Bot Token",
    [409] = "another program or a webhook is reading this bot",
  }, function(body)
    local messages, nextOffset, err = Inbound.parseTelegram(body)
    if messages == nil then
      return err
    end
    if nextOffset ~= nil then
      st.offset = nextOffset
      saveLogSoon()
    end
    for _, m in ipairs(messages) do
      handleInbound(m)
    end
    return nil
  end)
end

local function pollTwilio()
  local st = gInbound.twilio
  local req, why = Inbound.twilioRequest(
    {
      account_sid = Properties["Twilio Account SID"],
      auth_token = Properties["Twilio Auth Token"],
      from = Properties["Twilio From Number"],
    },
    os.time() - inboundMaxAge(),
    function(s)
      return C4:Base64Encode(s)
    end
  )
  if req == nil then
    st.status = why
    return
  end
  ask("twilio", req, { [401] = "check the Account SID and Auth Token" }, function(body)
    local messages, err = Inbound.parseTwilio(body)
    if messages == nil then
      return err
    end
    for _, m in ipairs(messages) do
      handleInbound(m)
    end
    return nil
  end)
end

pollInbound = function()
  if gInbox == nil or gRouter == nil or gLicenceHalted then
    return
  end
  local now = os.time()
  for channel, poll in pairs({ telegram = pollTelegram, twilio = pollTwilio }) do
    local st = gInbound[channel]
    if inboundOn(channel) and not st.busy and now >= st.nextAt then
      poll()
    end
  end
end

--- (Re)starts the poll timer to match the properties.
startInbound = function()
  CancelTimer(POLL_TIMER)
  if not gInitialized then
    return
  end
  local any = false
  for channel, st in pairs(gInbound) do
    st.busy, st.failures, st.nextAt = false, 0, 0
    if inboundOn(channel) then
      any = true
      st.status = "starting"
    else
      st.status = "off"
    end
  end
  if any then
    SetTimer(POLL_TIMER, inboundPollSeconds() * ONE_SECOND, pollInbound, true)
    pollInbound()
  end
  paint()
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
    { "LAST_MESSAGE", "", "STRING" },
    { "LAST_MESSAGE_CHANNEL", "", "STRING" },
    { "LAST_MESSAGE_SENDER", "", "STRING" },
    { "LAST_MESSAGE_ARGUMENT", "", "STRING" },
    { "LAST_KEYWORD", "", "STRING" },
    { "TELEGRAM_LAST_MESSAGE", "", "STRING" },
    { "SMS_LAST_MESSAGE", "", "STRING" },
    { "MESSAGE_COUNTER", 0, "NUMBER" },
    { "MESSAGES_RECEIVED_TODAY", 0, "NUMBER" },
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
    { 9, "Message Received", "A message from an allowed sender arrived (see Last Message)" },
    { 10, "Telegram Message Received", "A Telegram message from an allowed sender arrived" },
    { 11, "SMS Message Received", "A text message from an allowed sender arrived" },
    { 12, "Message Rejected", "A message was refused: sender not allowed, PIN missing or wrong, or too many" },
    { 21, "Keyword 1 Received", "A message that is, or begins with, Keyword 1" },
    { 22, "Keyword 2 Received", "A message that is, or begins with, Keyword 2" },
    { 23, "Keyword 3 Received", "A message that is, or begins with, Keyword 3" },
    { 24, "Keyword 4 Received", "A message that is, or begins with, Keyword 4" },
    { 25, "Keyword 5 Received", "A message that is, or begins with, Keyword 5" },
    { 26, "Keyword 6 Received", "A message that is, or begins with, Keyword 6" },
    { 27, "Keyword 7 Received", "A message that is, or begins with, Keyword 7" },
    { 28, "Keyword 8 Received", "A message that is, or begins with, Keyword 8" },
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

  gInbox = Inbound.new({
    now = os.time,
    home = function(channel)
      return channel == "twilio" and Properties["Twilio To Number"] or Properties["Telegram Chat ID"]
    end,
    allowed = function(channel)
      return Inbound.list(Properties[(channel == "twilio" and "Twilio" or "Telegram") .. " Allowed Senders"])
    end,
    pin = function()
      return Properties["Inbound PIN"]
    end,
    keywords = function()
      local list = {}
      for n = 1, Inbound.LIMITS.keywords do
        list[n] = Properties["Keyword " .. n] or ""
      end
      return list
    end,
    max_age = inboundMaxAge,
  })
  local inbound = persist:get(INBOUND_KEY, false)
  if type(inbound) == "table" then
    gInbox:restore(inbound.seen)
    gInbound.telegram.offset = tonumber(inbound.telegram_offset)
    gMessageCounter = tonumber(inbound.counter) or 0
    if type(inbound.last) == "table" and CHANNEL_LABEL[inbound.last.channel] then
      gLast = inbound.last
    end
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
  startInbound()
  paint()
end

function OnDriverDestroyed()
  saveNow()
  CancelTimer(POLL_TIMER)
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
function OPC.Telegram_Inbound()
  startInbound()
end

function OPC.Twilio_Inbound()
  startInbound()
end

function OPC.Inbound_Poll_Seconds()
  startInbound()
end

-- ─── Actions ────────────────────────────────────────────────────────────────

function EC.CHECK_MESSAGES()
  for _, st in pairs(gInbound) do
    st.nextAt = 0
  end
  pollInbound()
  paint()
end

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
  log:print("  inbound: %s (every %ds, replay window %ds)", inboundStatus(), inboundPollSeconds(), inboundMaxAge())
  if gInbox then
    local names = {}
    for k in pairs(gInbox.counters) do
      names[#names + 1] = k
    end
    table.sort(names)
    for _, k in ipairs(names) do
      log:print("  inbound %s = %s", k, tostring(gInbox.counters[k]))
    end
  end
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

--- Fills a command's TITLE and MESSAGE with live values, read now, each
--- device once. The filled-in text is what the router trims, logs and
--- de-duplicates.
local function fillFrom(tParams, title)
  local picked = pickedFrom(tParams)
  local resolve = Template.resolver({ picked = picked, devices = projectDevices, readVariables = readVariables })
  return Template.fill(title, tParams.MESSAGE, resolve, picked)
end

--- Logs what could not be read and raises the event, once per notification.
--- Returns a function to call after the send, so the error survives it.
local function reportVariables(msg, problems)
  if #problems == 0 or gRouter == nil or gLicenceHalted then
    return function() end
  end
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
  return function()
    gLastError = string.format("variable %s: %s", problems[1].token, problems[1].reason)
    paint()
  end
end

function EC.NOTIFY(tParams)
  tParams = tParams or {}
  local channel = CHANNEL_BY_LABEL[tostring(tParams.CHANNEL or "All"):lower()] or tostring(tParams.CHANNEL or "all")
  local title, body, problems = fillFrom(tParams, tParams.TITLE)
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
  local after = reportVariables(msg, problems)
  dispatch(msg, "programming")
  after()
end

function EC.NOTIFY_ALL(tParams)
  tParams = tParams or {}
  local all = { CHANNEL = "All", PRIORITY = tParams.PRIORITY, TITLE = tParams.TITLE, MESSAGE = tParams.MESSAGE }
  for n = 1, Template.PICKS do
    all["VARIABLE " .. n] = tParams["VARIABLE " .. n]
  end
  EC.NOTIFY(all)
end

--- Reply: MESSAGE goes to whoever sent the last message taken, on the
--- channel they used. Message variables work as in Notify.
function EC.REPLY(tParams)
  tParams = tParams or {}
  if gRouter == nil then
    return
  end
  local function refuse(why)
    log:warn("REPLY ignored: %s", why)
    gLastError = "Reply: " .. why
    paint()
  end
  if gLast == nil then
    return refuse("no message has been received yet")
  end
  local base = targetById(gLast.channel)
  if base == nil then
    return refuse("unknown channel " .. tostring(gLast.channel))
  end
  local _, body, problems = fillFrom(tParams, "")
  local msg, why = Router.message({ channel = gLast.channel, priority = "normal", title = "", body = body })
  if msg == nil then
    return refuse("a reply needs a MESSAGE")
  end
  -- The same credentials as the target, addressed to the sender.
  local config = {}
  for k, v in pairs(base.config) do
    config[k] = v
  end
  if gLast.channel == "twilio" then
    config.to = gLast.sender
  else
    config.chat_id = gLast.chat
  end
  local after = reportVariables(msg, problems)
  sendDirect({ id = base.id, kind = base.kind, label = base.label, config = config }, msg, "reply")
  after()
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
