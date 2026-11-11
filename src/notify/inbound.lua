--- Notification Router — inbound messages (pure, injected clock).
---
--- Two-way messaging: a person sends a text to the house and programming
--- reacts to it. A controller sits behind the home router, so it cannot be
--- called; it ASKS. Two channels can be asked with the credentials the
--- router already holds:
---
---   telegram  GET https://api.telegram.org/bot<token>/getUpdates?offset=N
---   twilio    GET https://api.twilio.com/2010-04-01/Accounts/<sid>/Messages.json?To=<our number>
---
--- An inbound text can start programming, so this is a remote control for
--- the house. Rules a dealer relies on:
---
---   • ALLOW-LIST. A message is taken only from a sender the dealer named:
---     by default the chat (Telegram) or number (SMS) the router already
---     sends to. Everything else is `not_allowed` and its text is never
---     kept, logged or exposed.
---   • NOT A REPLAY. A message older than `max_age` seconds is `stale`: a
---     controller that was off for an hour does not open the garage on boot.
---     A message is handled once (`duplicate` afterwards), across restarts.
---   • OPTIONAL PIN. With a PIN set, a message must begin with it; the PIN
---     is stripped before anything else sees the text.
---   • BOUNDED. At most `per_minute` messages a minute per channel
---     (`rate_limited`), text cut to 500 bytes on one line.
---   • TEXT IS DATA. The text only ever becomes a variable, an argument and
---     a keyword match. Nothing in it is executed.
---
--- Nothing here does I/O: the driver sends the request and hands back the
--- decoded body.

local M = {}

M.LIMITS = {
  text = 500,
  max_age = 120,
  seen = 200,
  per_minute = 20,
  keywords = 8,
  keyword = 40,
  page = 50,
}

local function trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function missing(value)
  return value == nil or trim(value) == ""
end

--- Cuts a UTF-8 string to `max` bytes without leaving half a character.
local function utf8cut(s, max)
  if #s <= max then
    return s
  end
  s = s:sub(1, max)
  local tail = s:match("[\192-\247][\128-\191]*$")
  if tail ~= nil then
    local lead = tail:byte(1)
    local need = lead >= 240 and 4 or lead >= 224 and 3 or 2
    if #tail < need then
      s = s:sub(1, #s - #tail)
    end
  end
  return s
end

--- An inbound text as the house sees it: one line, bounded.
function M.cleanText(text)
  return utf8cut(trim(tostring(text or ""):gsub("%c", " "):gsub("%s+", " ")), M.LIMITS.text)
end

--- A whole number as text, whatever size JSON decoded it to.
local function wholeNumber(n)
  if type(n) == "number" then
    return string.format("%.0f", n)
  end
  return trim(n)
end

-- ─── Telegram ────────────────────────────────────────────────────────────────

--- The request that asks Telegram for messages after `offset`.
--- Returns request or nil + reason.
function M.telegramRequest(cfg, offset)
  cfg = cfg or {}
  if missing(cfg.bot_token) then
    return nil, "Telegram needs Bot Token"
  end
  local url = "https://api.telegram.org/bot"
    .. tostring(cfg.bot_token):gsub("%s+", "")
    .. "/getUpdates?timeout=0&limit="
    .. M.LIMITS.page
    -- message: what people write. channel_post and my_chat_member are never
    -- taken as messages; they only tell "Find Telegram Chat ID" which
    -- channels and groups the bot is in.
    .. "&allowed_updates=%5B%22message%22%2C%22channel_post%22%2C%22my_chat_member%22%5D"
  if tonumber(offset) ~= nil then
    url = url .. "&offset=" .. wholeNumber(tonumber(offset))
  end
  return { method = "GET", url = url, headers = {}, describe = "telegram getUpdates" }
end

--- A name for a Telegram chat: a group's title, else the person's name.
function M.chatName(chat, from)
  chat, from = type(chat) == "table" and chat or {}, type(from) == "table" and from or {}
  -- Not a list literal: a missing first field would end an ipairs at once.
  local candidates = { chat.title, chat.first_name, from.first_name, chat.username, from.username }
  for i = 1, 5 do
    local v = candidates[i]
    if type(v) == "string" and v:gsub("%s+", "") ~= "" then
      return (v:gsub("%c+", " "):sub(1, 40))
    end
  end
  return "chat"
end

--- Remembers the chats that wrote to the bot, newest first, each once.
--- @param seen table  list of { id, name, kind }, changed in place
--- @param messages table  from parseTelegram
--- @param max number|nil  how many to keep (default 5)
function M.noteChats(seen, messages, max)
  max = max or 5
  for _, m in ipairs(messages or {}) do
    if m.chat ~= nil and not m.bot then
      for i = #seen, 1, -1 do
        if seen[i].id == m.chat then
          table.remove(seen, i)
        end
      end
      table.insert(seen, 1, { id = m.chat, name = m.chat_name or "chat", kind = m.chat_type or "chat" })
      while #seen > max do
        table.remove(seen)
      end
    end
  end
  return seen
end

--- "Owner (private): 12345 · Family (group): -100123", or nil when empty.
function M.chatsLine(seen)
  local parts = {}
  for _, c in ipairs(seen or {}) do
    parts[#parts + 1] = string.format("%s (%s): %s", c.name, c.kind, c.id)
  end
  return #parts > 0 and table.concat(parts, " · ") or nil
end

--- A decoded getUpdates body → messages (oldest first) and the offset to ask
--- from next time (nil when the body carried no update). An update that is
--- not a text message still moves the offset on.
--- @return table|nil messages, number|nil nextOffset, string|nil err
function M.parseTelegram(body)
  if type(body) ~= "table" or body.ok ~= true or type(body.result) ~= "table" then
    local why = type(body) == "table" and body.description or nil
    return nil, nil, "unexpected answer" .. (why and (": " .. tostring(why)) or "")
  end
  local out, highest, chats = {}, nil, {}
  for _, update in ipairs(body.result) do
    local id = tonumber(update.update_id)
    if id ~= nil then
      if highest == nil or id > highest then
        highest = id
      end
      local m = update.message
      if type(m) == "table" and type(m.text) == "string" and type(m.chat) == "table" then
        local from = type(m.from) == "table" and m.from or {}
        out[#out + 1] = {
          id = "tg:" .. wholeNumber(id),
          channel = "telegram",
          chat = wholeNumber(m.chat.id),
          sender = wholeNumber(from.id or m.chat.id),
          username = type(from.username) == "string" and from.username or nil,
          bot = from.is_bot == true,
          text = m.text,
          at = tonumber(m.date),
        }
      end
      -- For "Find Telegram Chat ID": every chat this update names. A post
      -- in a channel and the bot being added to a group or channel count,
      -- so the chat shows up before anybody has written in it.
      for _, key in ipairs({ "message", "channel_post", "my_chat_member" }) do
        local u = update[key]
        if type(u) == "table" and type(u.chat) == "table" and u.chat.id ~= nil then
          local from = type(u.from) == "table" and u.from or {}
          chats[#chats + 1] = {
            chat = wholeNumber(u.chat.id),
            chat_name = M.chatName(u.chat, key == "message" and from or {}),
            chat_type = type(u.chat.type) == "string" and u.chat.type or "chat",
            bot = key == "message" and from.is_bot == true,
          }
        end
      end
    end
  end
  return out, highest and (highest + 1) or nil, nil, chats
end

-- ─── Twilio ──────────────────────────────────────────────────────────────────

local MONTHS =
  { jan = 1, feb = 2, mar = 3, apr = 4, may = 5, jun = 6, jul = 7, aug = 8, sep = 9, oct = 10, nov = 11, dec = 12 }

--- Seconds since 1970 for a UTC calendar time (no os.time: it is local time).
local function epochUtc(y, mo, d, h, mi, s)
  if mo <= 2 then
    y = y - 1
  end
  local era = math.floor(y / 400)
  local yoe = y - era * 400
  local doy = math.floor((153 * (mo + (mo > 2 and -3 or 9)) + 2) / 5) + d - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  return (era * 146097 + doe - 719468) * 86400 + h * 3600 + mi * 60 + s
end

--- "Tue, 10 Nov 2026 06:45:00 +0000" → seconds since 1970, or nil.
function M.parseRfc2822(text)
  local d, mon, y, h, mi, s, sign, zh, zm =
    tostring(text or ""):match("(%d%d?)%s+(%a%a%a)%a*%s+(%d%d%d%d)%s+(%d%d):(%d%d):(%d%d)%s*([%+%-])(%d%d)(%d%d)")
  local month = mon and MONTHS[mon:lower()] or nil
  if month == nil then
    return nil
  end
  local t = epochUtc(tonumber(y), month, tonumber(d), tonumber(h), tonumber(mi), tonumber(s))
  local offset = tonumber(zh) * 3600 + tonumber(zm) * 60
  return sign == "-" and (t + offset) or (t - offset)
end

--- A phone number as compared: digits with a leading + kept.
function M.phone(text)
  local s = trim(text)
  local plus = s:sub(1, 1) == "+" and "+" or ""
  return plus .. s:gsub("%D", "")
end

--- The request that lists texts sent TO the router's own number since the
--- day `since` falls on (UTC). Returns request or nil + reason.
function M.twilioRequest(cfg, since, base64)
  cfg = cfg or {}
  if missing(cfg.account_sid) or missing(cfg.auth_token) or missing(cfg.from) then
    return nil, "Twilio needs Account SID, Auth Token and From Number"
  end
  if type(base64) ~= "function" then
    return nil, "Twilio needs a Base64 encoder"
  end
  local sid = tostring(cfg.account_sid):gsub("%s+", "")
  local to = M.phone(cfg.from):gsub("%+", "%%2B")
  local url = "https://api.twilio.com/2010-04-01/Accounts/"
    .. sid
    .. "/Messages.json?To="
    .. to
    .. "&DateSent%3E="
    .. os.date("!%Y-%m-%d", since)
    .. "&PageSize="
    .. M.LIMITS.page
  local credential = (base64(sid .. ":" .. tostring(cfg.auth_token)) or ""):gsub("%s+", "")
  return {
    method = "GET",
    url = url,
    headers = { ["Authorization"] = "Basic " .. credential },
    describe = "twilio inbound list",
  }
end

--- A decoded Messages.json body → inbound messages, oldest first.
--- @return table|nil messages, string|nil err
function M.parseTwilio(body)
  if type(body) ~= "table" or type(body.messages) ~= "table" then
    return nil, "unexpected answer"
  end
  local out = {}
  for _, m in ipairs(body.messages) do
    if type(m) == "table" and m.direction == "inbound" and type(m.sid) == "string" and type(m.body) == "string" then
      out[#out + 1] = {
        id = "sms:" .. m.sid,
        channel = "twilio",
        chat = M.phone(m.from),
        sender = M.phone(m.from),
        text = m.body,
        at = M.parseRfc2822(m.date_sent) or M.parseRfc2822(m.date_created),
      }
    end
  end
  table.sort(out, function(a, b)
    if (a.at or 0) ~= (b.at or 0) then
      return (a.at or 0) < (b.at or 0)
    end
    return a.id < b.id
  end)
  return out
end

-- ─── Allow-list ──────────────────────────────────────────────────────────────

--- "a, b; c" → { "a", "b", "c" }.
function M.list(text)
  local out = {}
  for part in tostring(text or ""):gmatch("[^,;\n]+") do
    local item = trim(part)
    if item ~= "" then
      out[#out + 1] = item
    end
  end
  return out
end

--- Whether a message's sender is one the dealer named.
---
--- Telegram: the message must come from the configured chat, or from a
--- private chat with a listed person; when people are listed, the person
--- must be one of them (so a group can be narrowed to its owners).
--- SMS: the number the router texts, or a listed number.
--- @param home string   the chat id / number the router sends to
--- @param extra table   Allowed Senders: ids, @usernames or numbers
function M.isAllowed(msg, home, extra)
  extra = extra or {}
  if msg.channel == "twilio" then
    local from = M.phone(msg.sender)
    if from == "" or from == "+" then
      return false
    end
    if not missing(home) and M.phone(home) == from then
      return true
    end
    for _, item in ipairs(extra) do
      if M.phone(item) == from then
        return true
      end
    end
    return false
  end
  local function listed(value)
    if value == nil or value == "" then
      return false
    end
    local v = tostring(value):lower()
    for _, item in ipairs(extra) do
      local i = trim(item):lower()
      if i == v or i == "@" .. v or "@" .. i == v then
        return true
      end
    end
    return false
  end
  local person = listed(msg.sender) or listed(msg.username)
  local chatOk = (not missing(home) and trim(home) == tostring(msg.chat))
    or (listed(msg.chat) and msg.chat == msg.sender)
  if not chatOk then
    return false
  end
  return #extra == 0 or person
end

-- ─── Keywords ────────────────────────────────────────────────────────────────

local function fold(text)
  return (trim(text):lower():gsub("%s+", " "))
end

--- The keyword a text is, or begins with, and what follows it. A Telegram
--- bot command counts: "/status" and "/status@MyBot" match keyword "status".
--- The longest matching keyword wins.
--- @param keywords table  up to 8 strings, index = keyword number
--- @return number|nil index, string|nil keyword, string argument
function M.matchKeyword(text, keywords)
  local cleaned = trim(text)
  local first, rest = cleaned:match("^(%S+)%s*(.*)$")
  if first ~= nil and first:sub(1, 1) == "/" then
    cleaned = trim(first:sub(2):gsub("@.*$", "") .. " " .. rest)
  end
  local folded = fold(cleaned)
  local best, bestLen = nil, -1
  for i = 1, M.LIMITS.keywords do
    local kw = fold((keywords or {})[i] or "")
    if kw ~= "" and #kw <= M.LIMITS.keyword and #kw > bestLen then
      if folded == kw or folded:sub(1, #kw + 1) == kw .. " " then
        best, bestLen = i, #kw
      end
    end
  end
  if best == nil then
    return nil, nil, ""
  end
  -- The argument keeps the sender's own capitals: take it from the text
  -- with single spaces, past the keyword's words.
  local words = {}
  for w in cleaned:gmatch("%S+") do
    words[#words + 1] = w
  end
  local skip = select(2, fold(keywords[best]):gsub("%S+", ""))
  local argument = table.concat(words, " ", skip + 1)
  return best, fold(keywords[best]), argument
end

-- ─── Inbox ───────────────────────────────────────────────────────────────────

local Inbox = {}
Inbox.__index = Inbox

--- @param deps table {
---   now = fun():number,
---   home = fun(channel):string|nil     -- the chat / number the router sends to
---   allowed = fun(channel):table       -- Allowed Senders for the channel
---   pin = fun():string|nil,
---   keywords = fun():table,
---   max_age = number|fun(), per_minute = number|fun() }
function M.new(deps)
  local self = setmetatable({}, Inbox)
  self.deps = deps
  self.seen = {} -- id -> true
  self.order = {} -- ids, oldest first (bounded)
  self.recent = {} -- channel -> list of accept times (rolling minute)
  self.counters = {
    received = 0,
    duplicate = 0,
    stale = 0,
    not_allowed = 0,
    bad_pin = 0,
    rate_limited = 0,
    empty = 0,
    bot = 0,
  }
  return self
end

local function setting(v, default)
  if type(v) == "function" then
    v = v()
  end
  return tonumber(v) or default
end

function Inbox:_remember(id)
  self.seen[id] = true
  self.order[#self.order + 1] = id
  while #self.order > M.LIMITS.seen do
    self.seen[table.remove(self.order, 1)] = nil
  end
end

--- The ids already handled, for the driver to persist, and back.
function Inbox:export()
  local out = {}
  for i, id in ipairs(self.order) do
    out[i] = id
  end
  return out
end

function Inbox:restore(ids)
  self.seen, self.order = {}, {}
  for _, id in ipairs(type(ids) == "table" and ids or {}) do
    if type(id) == "string" then
      self:_remember(id)
    end
  end
end

--- Decides one message. Returns { outcome, text, keyword, keyword_index,
--- argument }; `outcome` is `received` or the reason it was not taken.
--- Only a `received` result carries text.
function Inbox:accept(msg)
  local function result(outcome, extra)
    self.counters[outcome] = (self.counters[outcome] or 0) + 1
    local r = extra or {}
    r.outcome = outcome
    return r
  end
  if type(msg) ~= "table" or type(msg.id) ~= "string" then
    return result("empty")
  end
  if self.seen[msg.id] then
    return result("duplicate")
  end
  self:_remember(msg.id)
  if msg.bot then
    return result("bot")
  end
  local now = self.deps.now()
  local maxAge = setting(self.deps.max_age, M.LIMITS.max_age)
  if msg.at == nil or now - msg.at > maxAge then
    return result("stale")
  end
  if not M.isAllowed(msg, self.deps.home(msg.channel), self.deps.allowed(msg.channel)) then
    return result("not_allowed")
  end
  local list = self.recent[msg.channel] or {}
  local keep = {}
  for _, t in ipairs(list) do
    if now - t < 60 then
      keep[#keep + 1] = t
    end
  end
  if #keep >= setting(self.deps.per_minute, M.LIMITS.per_minute) then
    self.recent[msg.channel] = keep
    return result("rate_limited")
  end
  keep[#keep + 1] = now
  self.recent[msg.channel] = keep

  local text = M.cleanText(msg.text)
  local pin = trim(self.deps.pin and self.deps.pin() or "")
  if pin ~= "" then
    if text == pin then
      text = ""
    elseif text:sub(1, #pin + 1) == pin .. " " then
      text = trim(text:sub(#pin + 2))
    else
      return result("bad_pin")
    end
  end
  if text == "" then
    return result("empty")
  end
  local index, keyword, argument = M.matchKeyword(text, self.deps.keywords and self.deps.keywords() or {})
  return result("received", { text = text, keyword_index = index, keyword = keyword, argument = argument })
end

return M
