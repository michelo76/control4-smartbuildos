-- Notification Router inbound messages (src/notify/inbound.lua), pure: the
-- exact requests that ask Telegram and Twilio for messages, parsing their
-- answers, the allow-list, replay protection (stale, duplicate, across a
-- restart), the optional PIN, the per-minute bound, text cleaning, keywords
-- and their argument.
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

local In = require("notify.inbound")

print("[1] Telegram: the request")
do
  local req = In.telegramRequest({ bot_token = " 123:ABC " }, nil)
  check(
    "first ask has no offset",
    req.method == "GET"
      and req.url
        == "https://api.telegram.org/bot123:ABC/getUpdates?timeout=0&limit=50&allowed_updates=%5B%22message%22%2C%22channel_post%22%2C%22my_chat_member%22%5D",
    req.url
  )
  req = In.telegramRequest({ bot_token = "123:ABC" }, 987654321012)
  check(
    "later asks carry the offset, written out in full",
    req.url:find("&offset=987654321012", 1, true) ~= nil,
    req.url
  )
  check("the description carries no token", not req.describe:find("123", 1, true))
  check("no token, no request", In.telegramRequest({ bot_token = " " }) == nil and In.telegramRequest(nil) == nil)
end

print("[2] Telegram: the answer")
do
  local msgs, nextOffset, err = In.parseTelegram({
    ok = true,
    result = {
      {
        update_id = 100,
        message = {
          date = 1800000000,
          text = "Goodnight",
          chat = { id = 8068, type = "private" },
          from = { id = 8068, username = "Owner", is_bot = false },
        },
      },
      { update_id = 101, edited_message = { text = "ignored" } },
      {
        update_id = 102,
        message = { date = 1800000005, chat = { id = -1001234567890, type = "group" }, from = { id = 555 }, photo = {} },
      },
      {
        update_id = 103,
        message = {
          date = 1800000009,
          text = "/status@HouseBot",
          chat = { id = -1001234567890, type = "supergroup" },
          from = { id = 555, is_bot = false },
        },
      },
      { update_id = 104, message = { date = 1, text = "beep", chat = { id = 9 }, from = { id = 9, is_bot = true } } },
    },
  })
  check(
    "only text messages come out, oldest first",
    err == nil and #msgs == 3 and msgs[1].text == "Goodnight",
    msgs and #msgs
  )
  check(
    "a message carries chat, sender, username and time",
    msgs[1].id == "tg:100"
      and msgs[1].channel == "telegram"
      and msgs[1].chat == "8068"
      and msgs[1].sender == "8068"
      and msgs[1].username == "Owner"
      and msgs[1].at == 1800000000
  )
  check(
    "a group's id is written out in full",
    msgs[2].chat == "-1001234567890" and msgs[2].sender == "555",
    msgs[2].chat
  )
  check("a bot is marked", msgs[3].bot == true and msgs[1].bot == false)
  check("the next offset passes every update, text or not", nextOffset == 105, nextOffset)
  msgs, nextOffset = In.parseTelegram({ ok = true, result = {} })
  check("nothing new: no messages, offset left alone", #msgs == 0 and nextOffset == nil)
  msgs, nextOffset, err =
    In.parseTelegram({ ok = false, error_code = 409, description = "Conflict: webhook is active" })
  check("an error answer says why", msgs == nil and err:find("Conflict: webhook is active", 1, true) ~= nil, err)
  check(
    "garbage is refused",
    In.parseTelegram("nope") == nil and In.parseTelegram(nil) == nil and In.parseTelegram({ ok = true }) == nil
  )
end

print("[3] Twilio: the request")
do
  local b64 = function(s)
    return "B64(" .. s .. ")"
  end
  local req = In.twilioRequest({ account_sid = "AC1", auth_token = "tok", from = "+1 (555) 000-1111" }, 1800000000, b64)
  check(
    "lists texts sent to the router's own number since that UTC day",
    req.method == "GET"
      and req.url
        == "https://api.twilio.com/2010-04-01/Accounts/AC1/Messages.json?To=%2B15550001111&DateSent%3E=2027-01-15&PageSize=50",
    req.url
  )
  check(
    "Basic auth, and no secret in the description",
    req.headers.Authorization == "Basic B64(AC1:tok)" and not req.describe:find("tok", 1, true)
  )
  check(
    "missing credentials or encoder: no request",
    In.twilioRequest({ account_sid = "AC1", auth_token = "", from = "+1" }, 0, b64) == nil
      and In.twilioRequest({ account_sid = "AC1", auth_token = "t", from = "+1" }, 0, nil) == nil
  )
end

print("[4] Twilio: the answer and its dates")
do
  check(
    "RFC 2822, UTC",
    In.parseRfc2822("Fri, 15 Jan 2027 08:00:00 +0000") == 1800000000,
    In.parseRfc2822("Fri, 15 Jan 2027 08:00:00 +0000")
  )
  check("a zone west of UTC", In.parseRfc2822("Fri, 15 Jan 2027 03:00:00 -0500") == 1800000000)
  check("a zone east of UTC", In.parseRfc2822("Fri, 15 Jan 2027 13:30:00 +0530") == 1800000000)
  check("a leap day", In.parseRfc2822("Thu, 29 Feb 2024 00:00:00 +0000") == 1709164800)
  check("the epoch", In.parseRfc2822("Thu, 01 Jan 1970 00:00:00 +0000") == 0)
  check("not a date", In.parseRfc2822("yesterday") == nil and In.parseRfc2822(nil) == nil)
  local msgs = In.parseTwilio({
    messages = {
      {
        sid = "SM3",
        direction = "inbound",
        from = "+15559876",
        body = "second",
        date_sent = "Fri, 15 Jan 2027 08:00:30 +0000",
      },
      {
        sid = "SM2",
        direction = "outbound-api",
        from = "+15550001111",
        body = "ours",
        date_sent = "Fri, 15 Jan 2027 08:00:20 +0000",
      },
      {
        sid = "SM1",
        direction = "inbound",
        from = "+1 555 9876",
        body = "first",
        date_created = "Fri, 15 Jan 2027 08:00:10 +0000",
      },
    },
  })
  check("only inbound texts, oldest first", #msgs == 2 and msgs[1].text == "first" and msgs[2].text == "second")
  check(
    "a text carries its sender and time",
    msgs[1].id == "sms:SM1"
      and msgs[1].channel == "twilio"
      and msgs[1].sender == "+15559876"
      and msgs[1].at == 1800000010,
    msgs[1].at
  )
  check("garbage is refused", In.parseTwilio({}) == nil and In.parseTwilio("x") == nil)
  check(
    "phone numbers compare by digits",
    In.phone(" +1 (555) 000-1111 ") == "+15550001111" and In.phone("555.0001") == "5550001"
  )
end

print("[5] the allow-list")
do
  local tg = function(chat, sender, username)
    return { channel = "telegram", chat = chat, sender = sender, username = username }
  end
  check("the chat the router sends to is allowed", In.isAllowed(tg("8068", "8068"), "8068", {}))
  check("any other chat is not", not In.isAllowed(tg("9999", "9999"), "8068", {}))
  check("no chat configured, nobody listed: nobody", not In.isAllowed(tg("8068", "8068"), "", {}))
  check("everyone in the configured group, by default", In.isAllowed(tg("-100", "555"), "-100", {}))
  check(
    "a group narrowed to listed people",
    In.isAllowed(tg("-100", "555"), "-100", { "555" }) and not In.isAllowed(tg("-100", "777"), "-100", { "555" })
  )
  check(
    "a person listed by @username, any case",
    In.isAllowed(tg("-100", "777", "Owner"), "-100", { "@owner" })
      and In.isAllowed(tg("-100", "777", "Owner"), "-100", { "OWNER" })
  )
  check("a listed person's private chat", In.isAllowed(tg("555", "555"), "-100", { "555" }))
  check("a listed id is not a way into some other group", not In.isAllowed(tg("-200", "555"), "-100", { "555" }))
  local sms = function(from)
    return { channel = "twilio", chat = from, sender = from }
  end
  check("the number the router texts is allowed", In.isAllowed(sms("+15559876"), "+1 (555) 9876", {}))
  check("a listed number is allowed", In.isAllowed(sms("+15551234"), "+15559876", { "+1 555 1234" }))
  check("any other number is not", not In.isAllowed(sms("+15550000"), "+15559876", { "+15551234" }))
  check("an empty sender is never allowed", not In.isAllowed(sms(""), "", {}) and not In.isAllowed(sms("+"), "+", {}))
  check("the list splits on commas, semicolons and lines", #In.list(" a, b ;c\n d ,, ") == 4 and #In.list(nil) == 0)
end

print("[6] keywords")
do
  local kws = { "Goodnight", "gate", "gate open", "", "  Arm   Away ", string.rep("x", 60) }
  local i, kw, arg = In.matchKeyword("goodnight", kws)
  check("the whole text, any case", i == 1 and kw == "goodnight" and arg == "")
  i, kw, arg = In.matchKeyword("  GATE   Now Please ", kws)
  check("the text begins with it: the rest is the argument, capitals kept", i == 2 and arg == "Now Please", arg)
  i, kw, arg = In.matchKeyword("gate open slowly", kws)
  check("the longest keyword wins", i == 3 and kw == "gate open" and arg == "slowly", kw)
  check("a keyword of several words, spaces folded", In.matchKeyword("arm away", kws) == 5)
  check("only a whole word", In.matchKeyword("gateway", kws) == nil and In.matchKeyword("goodnights", kws) == nil)
  i, kw, arg = In.matchKeyword("/gate@HouseBot 30", kws)
  check("a Telegram bot command counts", i == 2 and arg == "30", arg)
  check("no match", In.matchKeyword("hello there", kws) == nil and select(3, In.matchKeyword("hello", kws)) == "")
  check(
    "an over-long keyword is ignored; no keywords at all is fine",
    In.matchKeyword(string.rep("x", 60), kws) == nil and In.matchKeyword("gate", nil) == nil
  )
end

print("[7] the inbox: what is taken and what is not")
local now = 1800000100
local pin, keywords, home, extra =
  "", { "goodnight", "gate" }, { telegram = "8068", twilio = "+15559876" }, { telegram = {}, twilio = {} }
local function newInbox()
  return In.new({
    now = function()
      return now
    end,
    home = function(channel)
      return home[channel]
    end,
    allowed = function(channel)
      return extra[channel]
    end,
    pin = function()
      return pin
    end,
    keywords = function()
      return keywords
    end,
  })
end
local seq = 0
local function tg(text, fields)
  seq = seq + 1
  local m = { id = "tg:" .. seq, channel = "telegram", chat = "8068", sender = "8068", text = text, at = now - 3 }
  for k, v in pairs(fields or {}) do
    m[k] = v
  end
  return m
end
do
  local box = newInbox()
  local r = box:accept(tg("Gate  open\nnow"))
  check(
    "received: one line, keyword and argument",
    r.outcome == "received" and r.text == "Gate open now" and r.keyword_index == 2 and r.argument == "open now",
    r.text
  )
  local m = tg("goodnight")
  check("received once", box:accept(m).outcome == "received" and box:accept(m).outcome == "duplicate")
  r = box:accept(tg("hello"))
  check("no keyword: still received", r.outcome == "received" and r.keyword_index == nil and r.argument == "")
  r = box:accept(tg("open the garage", { at = now - 121 }))
  check("older than two minutes: stale, and no text comes back", r.outcome == "stale" and r.text == nil)
  r = box:accept({ id = "tg:none", channel = "telegram", chat = "8068", sender = "8068", text = "x" })
  check("a message without a time is stale", r.outcome == "stale")
  check("a clock a little ahead of ours is fine", box:accept(tg("hello", { at = now + 30 })).outcome == "received")
  r = box:accept(tg("open the garage", { chat = "9999", sender = "9999" }))
  check("a stranger: not allowed, and no text comes back", r.outcome == "not_allowed" and r.text == nil)
  check("a bot is ignored", box:accept(tg("beep", { bot = true })).outcome == "bot")
  check("only spaces: empty", box:accept(tg("  \n ")).outcome == "empty")
  check("not a message", box:accept(nil).outcome == "empty" and box:accept({}).outcome == "empty")
  check(
    "counters",
    box.counters.received == 4
      and box.counters.duplicate == 1
      and box.counters.stale == 2
      and box.counters.not_allowed == 1,
    box.counters.received
  )
end

print("[8] the inbox: PIN")
do
  pin = "4471"
  local box = newInbox()
  local r = box:accept(tg("4471 gate open"))
  check(
    "the PIN is stripped before anything else sees the text",
    r.outcome == "received" and r.text == "gate open" and r.keyword_index == 2 and r.argument == "open",
    r.text
  )
  r = box:accept(tg("gate open"))
  check("no PIN: refused, and no text comes back", r.outcome == "bad_pin" and r.text == nil)
  check(
    "a wrong PIN, or the PIN glued to the text",
    box:accept(tg("4472 gate")).outcome == "bad_pin" and box:accept(tg("4471gate")).outcome == "bad_pin"
  )
  check("the PIN alone is an empty message", box:accept(tg("4471")).outcome == "empty")
  pin = "  "
  check("a blank PIN is no PIN", newInbox():accept(tg("gate")).outcome == "received")
  pin = ""
end

print("[9] the inbox: bounded")
do
  local box = newInbox()
  local taken, limited = 0, 0
  for _ = 1, In.LIMITS.per_minute + 5 do
    local o = box:accept(tg("hello")).outcome
    taken = taken + (o == "received" and 1 or 0)
    limited = limited + (o == "rate_limited" and 1 or 0)
  end
  check("twenty a minute, the rest refused", taken == In.LIMITS.per_minute and limited == 5, taken)
  local other =
    box:accept({ id = "sms:1", channel = "twilio", chat = "+15559876", sender = "+15559876", text = "hello", at = now })
  check("the other channel has its own count", other.outcome == "received")
  now = now + 61
  check("a minute later it is taken again", box:accept(tg("hello")).outcome == "received")
  local long = box:accept(tg(string.rep("é", 400)))
  check(
    "text is cut to 500 bytes without half a character",
    #long.text == 500 and long.text:sub(-2) == "é",
    #long.text
  )
  check("cleanText: control characters and edges", In.cleanText("\t a\r\nb \0 c ") == "a b c")
end

print("[10] the inbox: handled once, across a restart")
do
  local box = newInbox()
  local m = tg("goodnight")
  box:accept(m)
  local saved = box:export()
  local again = newInbox()
  again:restore(saved)
  check("a message handled before the restart is a duplicate after it", again:accept(m).outcome == "duplicate")
  check("a new one is taken", again:accept(tg("goodnight")).outcome == "received")
  again:restore("garbage")
  check("a broken store is an empty one", #again:export() == 0)
  local big = newInbox()
  for i = 1, In.LIMITS.seen + 50 do
    big:accept({ id = "x:" .. i, channel = "telegram", chat = "9", sender = "9", text = "x", at = now })
  end
  check("the memory of handled ids is bounded", #big:export() == In.LIMITS.seen)
end

print("== Find Telegram Chat ID: naming and remembering chats")
check("a group is called by its title", In.chatName({ title = "Family", first_name = "x" }, {}) == "Family")
check("a person by their first name, though the title is missing", In.chatName({ first_name = "Sam" }, {}) == "Sam")
check(
  "else the sender, else a username, else 'chat'",
  In.chatName({}, { first_name = "Ana" }) == "Ana"
    and In.chatName({ username = "u1" }, {}) == "u1"
    and In.chatName(nil, nil) == "chat"
)
do
  local seen = {}
  In.noteChats(
    seen,
    { { chat = "1", chat_name = "A", chat_type = "private" }, { chat = "-9", chat_name = "G", chat_type = "group" } }
  )
  In.noteChats(
    seen,
    { { chat = "1", chat_name = "A", chat_type = "private" }, { chat = "7", chat_name = "Bot", bot = true } }
  )
  check(
    "newest first, each chat once, bots left out",
    In.chatsLine(seen) == "A (private): 1 · G (group): -9",
    In.chatsLine(seen)
  )
  for n = 10, 20 do
    In.noteChats(seen, { { chat = tostring(n), chat_name = "N", chat_type = "private" } })
  end
  check("only the last five are kept", #seen == 5 and seen[1].id == "20")
  check("nothing seen is nil, not an empty line", In.chatsLine({}) == nil)
  local msgs, _, _, chats = In.parseTelegram({
    ok = true,
    result = {
      {
        update_id = 1,
        message = {
          date = 1,
          text = "hi",
          chat = { id = 44, type = "private", first_name = "Sam" },
          from = { id = 44, first_name = "Sam" },
        },
      },
      {
        update_id = 2,
        channel_post = { date = 1, text = "post", chat = { id = -1009, type = "channel", title = "House Alerts" } },
      },
      {
        update_id = 3,
        my_chat_member = {
          chat = { id = -77, type = "group", title = "Family" },
          from = { id = 44, first_name = "Sam" },
        },
      },
    },
  })
  check("a channel post and being added to a group are never messages", #msgs == 1 and msgs[1].text == "hi")
  check(
    "but they name their chats, so the id can be read before anybody writes",
    In.chatsLine(In.noteChats({}, chats)) == "Family (group): -77 · House Alerts (channel): -1009 · Sam (private): 44",
    In.chatsLine(In.noteChats({}, chats))
  )
end

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
