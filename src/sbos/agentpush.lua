--- SmartBuildOS Agent — Send Push Notification (pure, injected clock).
---
--- A dealer's programming asks the Agent to send a push. The Agent fills in
--- the variables (notify.template), then this module decides whether the
--- message leaves the controller, and reads the platform's answer. The push
--- itself is sent by SmartBuildOS (Apple push to the SmartBuildOS Field app,
--- and web push): nothing here needs Control4's 4Sight or Connect.
---
--- Rules a dealer relies on:
---
---   • BOUNDED. A title is at most 120 bytes and a message 500, cut on a
---     character boundary. These leave the house and land on a lock screen.
---   • DEDUPE. The same severity + title + message inside 5 minutes is sent
---     once. A different value in a variable is a different message.
---   • RATE LIMIT. At most 30 in a rolling hour, counted on sends attempted,
---     so a platform that refuses cannot be hammered.
---   • A REFUSAL BY THIS MODULE IS QUIET. A duplicate or a rate-limited push
---     is logged and nothing else. The driver fires `Notification Failed`
---     only for a push that was attempted, which is what keeps programming
---     that answers that event with another push from looping.
---
--- Nothing here does I/O.

local M = {}

M.LIMITS = {
  title = 120,
  body = 500,
  dedupe_seconds = 300,
  per_hour = 30,
  reason = 120,
}

M.SEVERITIES = { info = "info", warning = "warning", critical = "critical" }

local function trim(s)
  return (tostring(s == nil and "" or s):gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Cuts to at most `max` bytes without splitting a UTF-8 character.
function M.bound(text, max)
  text = trim(text)
  if #text <= max then
    return text
  end
  local cut = max
  -- A continuation byte (10xxxxxx) right after the cut means the cut is
  -- inside a character: step back to the byte before that character starts.
  while cut > 0 do
    local nextByte = text:byte(cut + 1)
    if nextByte == nil or nextByte < 0x80 or nextByte >= 0xC0 then
      break
    end
    cut = cut - 1
  end
  return trim(text:sub(1, cut))
end

--- Severity from the command's SEVERITY list; anything else is info.
function M.severity(label)
  return M.SEVERITIES[trim(label):lower()] or "info"
end

--- A validated message or nil + reason. Control characters become spaces
--- except a new line in the message.
function M.message(fields)
  fields = fields or {}
  local title = M.bound((tostring(fields.title or ""):gsub("%c+", " ")), M.LIMITS.title)
  local body = M.bound((tostring(fields.body or ""):gsub("[^%C\n]+", " ")), M.LIMITS.body)
  if title == "" and body == "" then
    return nil, "a push notification needs a TITLE or a MESSAGE"
  end
  return { title = title, body = body, severity = M.severity(fields.severity) }
end

local Gate = {}
Gate.__index = Gate

--- @param deps table { now = fun():number (seconds) }
function M.new(deps)
  local self = setmetatable({}, Gate)
  self.deps = deps
  self.recent = {} -- "severity|title|body" -> when it was admitted
  self.sends = {} -- admit times in the rolling hour
  self.counters = { requested = 0, attempted = 0, accepted = 0, failed = 0, duplicate = 0, rate_limited = 0 }
  return self
end

function Gate:_prune(now)
  for key, at in pairs(self.recent) do
    if now - at >= M.LIMITS.dedupe_seconds then
      self.recent[key] = nil
    end
  end
  local keep = {}
  for _, t in ipairs(self.sends) do
    if now - t < 3600 then
      keep[#keep + 1] = t
    end
  end
  self.sends = keep
end

--- Whether this message may be sent now. true, or false + "duplicate" /
--- "rate_limited". Admitting reserves the dedupe and the rate slot.
--- @param options table|nil { fresh = true } skips the dedupe check (a test
---   push pressed twice sends twice); the rate limit always applies.
function Gate:admit(msg, options)
  local now = self.deps.now()
  self:_prune(now)
  self.counters.requested = self.counters.requested + 1
  local key = table.concat({ msg.severity, msg.title, msg.body }, "|")
  if not (options and options.fresh) and self.recent[key] ~= nil then
    self.counters.duplicate = self.counters.duplicate + 1
    return false, "duplicate"
  end
  if #self.sends >= M.LIMITS.per_hour then
    self.counters.rate_limited = self.counters.rate_limited + 1
    return false, "rate_limited"
  end
  self.sends[#self.sends + 1] = now
  self.recent[key] = now
  self.counters.attempted = self.counters.attempted + 1
  return true
end

--- Counts how an attempted push ended.
function Gate:settle(accepted)
  local key = accepted and "accepted" or "failed"
  self.counters[key] = self.counters[key] + 1
end

--- Sends left in the rolling hour.
function Gate:remaining()
  self:_prune(self.deps.now())
  return math.max(0, M.LIMITS.per_hour - #self.sends)
end

--- What the platform said. true + recipient count, or false + reason.
--- An answer with no `push` table is an older platform that does not know
--- the route's contract: not accepted.
function M.readAnswer(body)
  local push = type(body) == "table" and body.push or nil
  if type(push) ~= "table" then
    return false, "SmartBuildOS did not answer the push"
  end
  if push.state == "accepted" then
    return true, tonumber(push.approved_recipient_count) or 0
  end
  local reason = trim(push.reason)
  if reason == "" then
    reason = "refused"
  end
  return false, reason:sub(1, M.LIMITS.reason)
end

--- Reasons the platform gives, in words a dealer can act on.
M.REASONS = {
  ["no-approved-recipient-profile"] = "no recipient profile is set for this system in System Studio",
  ["recipient-profile-unusable"] = "the recipient profile is missing, disabled or has no in-app channel",
  ["no-current-approved-recipients"] = "the recipient profile names nobody who is still in the company",
  ["rate-limited"] = "SmartBuildOS reached this system's hourly push limit",
  ["dispatch-failed"] = "SmartBuildOS could not write the notification",
}

function M.explain(reason)
  return M.REASONS[reason] or tostring(reason)
end

return M
