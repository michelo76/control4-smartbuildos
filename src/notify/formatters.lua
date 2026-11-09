--- Notification Router — one request shape per target (pure).
---
--- Each formatter turns (target config, message) into the exact HTTP request
--- the driver sends through lib.http: method, url, headers, body (a table is
--- JSON-encoded by lib.http with Content-Type application/json; a string is
--- sent as-is with the headers given). Every formatter also returns a
--- `describe` string safe for the delivery log: never a token, key or SID.
---
--- Targets (all documented public HTTP APIs, no SDKs):
---   telegram  POST https://api.telegram.org/bot<token>/sendMessage  {chat_id, text}
---   pushover  POST https://api.pushover.net/1/messages.json  {token, user, title, message, priority[, retry, expire]}
---   webhook   POST <url>  {text, content}   (Slack- and Discord-compatible)
---   generic   POST <url>  {title, message, priority, channel, source, sent_at}
---   twilio    POST https://api.twilio.com/2010-04-01/Accounts/<sid>/Messages.json
---             application/x-www-form-urlencoded To/From/Body, Basic auth sid:token
---
--- Missing credentials are a refusal (nil + reason), never a request with a
--- blank secret.

local Router = require("notify.router")

local M = {}

local function missing(value)
  return value == nil or tostring(value):gsub("%s+", "") == ""
end

local function text(msg)
  if msg.body == "" then
    return msg.title
  end
  if msg.title == "" then
    return msg.body
  end
  return msg.title .. "\n" .. msg.body
end

--- RFC 3986 form encoding.
function M.formEncode(fields, order)
  local parts = {}
  local keys = order
  if keys == nil then
    keys = {}
    for k in pairs(fields) do
      keys[#keys + 1] = k
    end
    table.sort(keys)
  end
  for _, k in ipairs(keys) do
    local v = fields[k]
    if v ~= nil then
      local enc = tostring(v):gsub("[^%w%-%._~]", function(c)
        return string.format("%%%02X", string.byte(c))
      end)
      parts[#parts + 1] = k .. "=" .. enc
    end
  end
  return table.concat(parts, "&")
end

--- Redacts a token that may appear in a URL path (Telegram) for logging.
local function safeUrl(url)
  return (tostring(url):gsub("/bot[^/]+/", "/bot[redacted]/"):gsub("/Accounts/[^/]+/", "/Accounts/[redacted]/"))
end

local PUSHOVER_PRIORITY = { [0] = -1, [1] = 0, [2] = 1, [3] = 2 }

M.builders = {}

function M.builders.telegram(cfg, msg)
  if missing(cfg.bot_token) or missing(cfg.chat_id) then
    return nil, "Telegram needs Bot Token and Chat ID"
  end
  local url = "https://api.telegram.org/bot" .. tostring(cfg.bot_token):gsub("%s+", "") .. "/sendMessage"
  return {
    method = "POST",
    url = url,
    headers = { ["Content-Type"] = "application/json" },
    body = { chat_id = tostring(cfg.chat_id), text = text(msg), disable_web_page_preview = true },
    describe = "telegram chat " .. tostring(cfg.chat_id),
  }
end

function M.builders.pushover(cfg, msg)
  if missing(cfg.app_token) or missing(cfg.user_key) then
    return nil, "Pushover needs App Token and User Key"
  end
  local body = {
    token = tostring(cfg.app_token),
    user = tostring(cfg.user_key),
    title = msg.title,
    message = msg.body ~= "" and msg.body or msg.title,
    priority = PUSHOVER_PRIORITY[msg.priority] or 0,
  }
  if body.priority == 2 then
    -- Emergency priority must carry retry/expire or the API refuses it.
    body.retry = 60
    body.expire = 3600
  end
  return {
    method = "POST",
    url = "https://api.pushover.net/1/messages.json",
    headers = { ["Content-Type"] = "application/json" },
    body = body,
    describe = "pushover",
  }
end

function M.builders.webhook(cfg, msg)
  if missing(cfg.url) or not tostring(cfg.url):match("^https?://") then
    return nil, "Webhook needs an http(s) URL"
  end
  local t = text(msg)
  return {
    method = "POST",
    url = tostring(cfg.url),
    headers = { ["Content-Type"] = "application/json" },
    -- Slack reads `text`, Discord reads `content`; each ignores the other.
    body = { text = t, content = t, username = cfg.username or "Control4" },
    describe = "webhook " .. safeUrl(tostring(cfg.url)):gsub("%?.*$", ""),
  }
end

function M.builders.generic(cfg, msg, now)
  if missing(cfg.url) or not tostring(cfg.url):match("^https?://") then
    return nil, "Generic webhook needs an http(s) URL"
  end
  local headers = { ["Content-Type"] = "application/json" }
  if not missing(cfg.bearer) then
    headers["Authorization"] = "Bearer " .. tostring(cfg.bearer)
  end
  return {
    method = "POST",
    url = tostring(cfg.url),
    headers = headers,
    body = {
      title = msg.title,
      message = msg.body,
      priority = Router.PRIORITY_NAMES[msg.priority] or "normal",
      channel = msg.channel,
      source = "control4",
      sent_at = now or 0,
    },
    describe = "generic " .. tostring(cfg.url):gsub("%?.*$", ""),
  }
end

function M.builders.twilio(cfg, msg, _, base64)
  if missing(cfg.account_sid) or missing(cfg.auth_token) or missing(cfg.from) or missing(cfg.to) then
    return nil, "Twilio needs Account SID, Auth Token, From and To"
  end
  if type(base64) ~= "function" then
    return nil, "Twilio needs a Base64 encoder"
  end
  local sid = tostring(cfg.account_sid):gsub("%s+", "")
  local url = "https://api.twilio.com/2010-04-01/Accounts/" .. sid .. "/Messages.json"
  local body = M.formEncode(
    { To = tostring(cfg.to), From = tostring(cfg.from), Body = text(msg):sub(1, 1600) },
    { "To", "From", "Body" }
  )
  local credential = (base64(sid .. ":" .. tostring(cfg.auth_token)) or ""):gsub("%s+", "")
  return {
    method = "POST",
    url = url,
    headers = {
      ["Content-Type"] = "application/x-www-form-urlencoded",
      ["Authorization"] = "Basic " .. credential,
    },
    body = body,
    describe = "sms to " .. tostring(cfg.to):gsub("%d%d%d%d$", "****"),
  }
end

--- Builds the request for a target. `target.kind` picks the builder;
--- `target.config` carries its credentials. Returns request or nil + reason.
function M.build(target, msg, now, base64)
  local builder = M.builders[tostring(target.kind or target.id)]
  if builder == nil then
    return nil, "unknown target kind " .. tostring(target.kind or target.id)
  end
  return builder(target.config or {}, msg, now, base64)
end

M.safeUrl = safeUrl

return M
