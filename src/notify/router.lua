--- Notification Router — routing rules (pure, injected clock).
---
--- A notification from Composer programming names a CHANNEL (one target or
--- "all"), a PRIORITY and text. The router decides, per target, whether to
--- send and why not, and keeps the delivery log a dealer reads. Rules a
--- technician relies on:
---
---   • PRIORITY GATE: a target has a minimum priority; below it, nothing is
---     sent and the decision is recorded as `below_priority`.
---   • QUIET HOURS per target (HH:MM .. HH:MM, may wrap midnight): suppressed
---     unless the priority is `critical`, which always bypasses.
---   • DEDUPE: the same target + title + body inside `dedupe_seconds` is not
---     sent again (`duplicate`). A different body is a different message.
---   • RATE LIMIT: at most `per_hour` sends per target in a rolling hour
---     (`rate_limited`), counted on sends attempted, not on successes, so a
---     failing target cannot burn through its retries unbounded.
---   • RETRY: a failed send is retried after BACKOFF[attempt] seconds, three
---     attempts in all; then it is `failed` and reported once.
---   • LOG: a bounded ring of the last 50 deliveries, redacted (a token
---     never appears in it: formatters give the router a safe description).
---
--- Nothing here does I/O; the driver sends and calls back with the outcome.

local M = {}

M.PRIORITIES = { low = 0, normal = 1, high = 2, critical = 3 }
M.PRIORITY_NAMES = { [0] = "low", [1] = "normal", [2] = "high", [3] = "critical" }

--- Seconds to wait before attempt 2 and attempt 3. Three attempts in all.
M.BACKOFF = { 5, 30 }
M.MAX_ATTEMPTS = #M.BACKOFF + 1

M.LIMITS = {
  log = 50,
  title = 120,
  body = 1000,
  dedupe_max = 3600,
  per_hour_max = 600,
  per_hour_default = 60,
  dedupe_default = 300,
  pending_max = 50,
}

--- Priority from a Composer LIST/STRING value; unknown → normal.
function M.parsePriority(value)
  local s = tostring(value or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
  if M.PRIORITIES[s] ~= nil then
    return M.PRIORITIES[s]
  end
  local n = tonumber(s)
  if n ~= nil and M.PRIORITY_NAMES[n] then
    return n
  end
  return M.PRIORITIES.normal
end

--- "HH:MM" → minutes since midnight, or nil.
function M.parseClock(text)
  local h, m = tostring(text or ""):match("^%s*(%d%d?):(%d%d)%s*$")
  if h == nil then
    return nil
  end
  h, m = tonumber(h), tonumber(m)
  if h > 23 or m > 59 then
    return nil
  end
  return h * 60 + m
end

--- Whether `minuteOfDay` falls inside the quiet window [startText, endText).
--- An empty or invalid window is never quiet; equal start and end is never
--- quiet (a 24 h window would be a disabled target, which is what Enabled
--- is for). Wraps midnight when end < start.
function M.inQuietHours(startText, endText, minuteOfDay)
  local s, e = M.parseClock(startText), M.parseClock(endText)
  if s == nil or e == nil or s == e then
    return false
  end
  if s < e then
    return minuteOfDay >= s and minuteOfDay < e
  end
  return minuteOfDay >= s or minuteOfDay < e
end

local function trim(text, max)
  text = tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if #text > max then
    return text:sub(1, max)
  end
  return text
end

--- A validated message or nil + reason.
function M.message(fields)
  fields = fields or {}
  local title = trim(fields.title, M.LIMITS.title)
  local body = trim(fields.body, M.LIMITS.body)
  if title == "" and body == "" then
    return nil, "a notification needs a TITLE or a MESSAGE"
  end
  -- A notification with only a MESSAGE is named after its opening words in
  -- the log; formatters must not send those words twice.
  local titleFromBody = false
  if title == "" then
    title = body:sub(1, 60)
    titleFromBody = true
  end
  local channel = tostring(fields.channel or "all"):lower():gsub("^%s+", ""):gsub("%s+$", "")
  if channel == "" then
    channel = "all"
  end
  return {
    channel = channel,
    priority = M.parsePriority(fields.priority),
    title = title,
    body = body,
    title_from_body = titleFromBody,
  }
end

local Router = {}
Router.__index = Router

--- @param deps table { now = fun():number (seconds), minuteOfDay = fun():number,
---   targets = fun():table (list of { id, label, enabled, min_priority, quiet_start, quiet_end }),
---   dedupe_seconds = number|fun(), per_hour = number|fun() }
function M.new(deps)
  local self = setmetatable({}, Router)
  self.deps = deps
  self.recent = {} -- "target|title|body" -> last sent at
  self.sends = {} -- target id -> list of send times (rolling hour)
  self.log = {} -- newest last, bounded
  self.seq = 0
  self.counters = {
    requested = 0,
    sent = 0,
    failed = 0,
    retried = 0,
    duplicate = 0,
    rate_limited = 0,
    quiet_hours = 0,
    below_priority = 0,
    disabled = 0,
    unknown_channel = 0,
  }
  return self
end

local function setting(v, default)
  if type(v) == "function" then
    v = v()
  end
  return tonumber(v) or default
end

function Router:_dedupeSeconds()
  local n = setting(self.deps.dedupe_seconds, M.LIMITS.dedupe_default)
  return math.max(0, math.min(n, M.LIMITS.dedupe_max))
end

function Router:_perHour()
  local n = setting(self.deps.per_hour, M.LIMITS.per_hour_default)
  return math.max(1, math.min(n, M.LIMITS.per_hour_max))
end

function Router:_prune(now)
  for key, at in pairs(self.recent) do
    if now - at > M.LIMITS.dedupe_max then
      self.recent[key] = nil
    end
  end
  for id, list in pairs(self.sends) do
    local keep = {}
    for _, t in ipairs(list) do
      if now - t < 3600 then
        keep[#keep + 1] = t
      end
    end
    self.sends[id] = keep
  end
end

--- Channel matching: "all" matches every target; otherwise the target id or
--- its label, case-insensitively, spaces and dashes ignored.
local function norm(s)
  return tostring(s or ""):lower():gsub("[%s%-_]", "")
end

function M.channelMatches(channel, target)
  if channel == "all" then
    return true
  end
  local c = norm(channel)
  return c == norm(target.id) or c == norm(target.label)
end

--- Decides per target. Returns { { target, decision, reason } ... } and the
--- number of sends. A `send` decision reserves the dedupe and rate slots.
function Router:route(msg)
  local now = self.deps.now()
  self:_prune(now)
  self.counters.requested = self.counters.requested + 1
  local decisions, sends, matched = {}, 0, 0
  local dedupe = self:_dedupeSeconds()
  local perHour = self:_perHour()
  local minute = self.deps.minuteOfDay()
  for _, target in ipairs(self.deps.targets() or {}) do
    if M.channelMatches(msg.channel, target) then
      matched = matched + 1
      local decision, reason = "send", nil
      if not target.enabled then
        decision, reason = "skip", "disabled"
      elseif msg.priority < (tonumber(target.min_priority) or 0) then
        decision, reason = "skip", "below_priority"
      elseif msg.priority < M.PRIORITIES.critical and M.inQuietHours(target.quiet_start, target.quiet_end, minute) then
        decision, reason = "skip", "quiet_hours"
      else
        local key = table.concat({ target.id, msg.title, msg.body }, "|")
        local last = self.recent[key]
        if dedupe > 0 and last ~= nil and now - last < dedupe then
          decision, reason = "skip", "duplicate"
        else
          local list = self.sends[target.id] or {}
          if #list >= perHour then
            decision, reason = "skip", "rate_limited"
          else
            list[#list + 1] = now
            self.sends[target.id] = list
            self.recent[key] = now
          end
        end
      end
      if reason ~= nil then
        self.counters[reason] = (self.counters[reason] or 0) + 1
      else
        sends = sends + 1
      end
      decisions[#decisions + 1] = { target = target, decision = decision, reason = reason }
    end
  end
  if matched == 0 then
    self.counters.unknown_channel = self.counters.unknown_channel + 1
  end
  return decisions, sends, matched
end

--- A send that skips the per-target rules (a reply to a message just
--- received): only the hourly rate limit applies, and the send counts
--- toward it. Returns true, or false + "rate_limited".
function Router:reserve(targetId)
  local now = self.deps.now()
  self:_prune(now)
  local list = self.sends[targetId] or {}
  if #list >= self:_perHour() then
    self.counters.rate_limited = self.counters.rate_limited + 1
    return false, "rate_limited"
  end
  list[#list + 1] = now
  self.sends[targetId] = list
  return true
end

--- Seconds to wait before the next attempt, or nil when attempts are spent.
--- `attempt` is the number of the attempt that just failed (1-based).
function M.retryDelay(attempt)
  return M.BACKOFF[attempt]
end

--- Appends a log entry (bounded) and returns it.
function Router:record(entry)
  self.seq = self.seq + 1
  entry.seq = self.seq
  entry.t = entry.t or self.deps.now()
  self.log[#self.log + 1] = entry
  while #self.log > M.LIMITS.log do
    table.remove(self.log, 1)
  end
  if entry.status == "sent" then
    self.counters.sent = self.counters.sent + 1
  elseif entry.status == "failed" then
    self.counters.failed = self.counters.failed + 1
  elseif entry.status == "retrying" then
    self.counters.retried = self.counters.retried + 1
  end
  return entry
end

function Router:recent_log(n)
  n = math.min(tonumber(n) or #self.log, #self.log)
  local out = {}
  for i = #self.log - n + 1, #self.log do
    out[#out + 1] = self.log[i]
  end
  return out
end

--- One line per log entry for Director's log. Never includes credentials:
--- entries carry the formatter's safe description only.
function M.formatEntry(e)
  local when = e.t and os.date("%H:%M:%S", math.floor(e.t)) or "--:--:--"
  return string.format(
    "%s  #%d  %-10s %-14s %s%s%s",
    when,
    e.seq or 0,
    tostring(e.target or "-"),
    tostring(e.status or "-"),
    tostring(e.title or ""),
    e.attempts and (" (attempt " .. e.attempts .. ")") or "",
    e.detail and e.detail ~= "" and ("  — " .. tostring(e.detail)) or ""
  )
end

return M
