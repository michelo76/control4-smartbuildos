package.path = "src/?.lua;" .. package.path
local F = require("notify.formatters")
local R = require("notify.router")
local pass, fail = 0, 0
local function check(name, ok, detail)
  if ok then
    pass = pass + 1
    print("  ok   " .. name)
  else
    fail = fail + 1
    print("  FAIL " .. name .. (detail ~= nil and ("  -> " .. tostring(detail)) or ""))
  end
end
local function b64(s)
  -- Only the input is asserted; a fixed fake keeps the test byte-exact.
  return "B64(" .. s .. ")"
end
local msg = R.message({ title = "Garage", body = "Door left open", priority = "high", channel = "all" })

print("== telegram")
local req, why = F.build({ kind = "telegram", config = { bot_token = "123:ABC ", chat_id = "-100" } }, msg)
check(
  "url carries the token, body the chat and text",
  req.url == "https://api.telegram.org/bot123:ABC/sendMessage"
    and req.body.chat_id == "-100"
    and req.body.text == "Garage\nDoor left open"
)
check("JSON content type", req.headers["Content-Type"] == "application/json" and req.method == "POST")
check("describe has no token", req.describe == "telegram chat -100" and not req.describe:find("ABC"))
check("safeUrl redacts the bot token", F.safeUrl(req.url) == "https://api.telegram.org/bot[redacted]/sendMessage")
req, why = F.build({ kind = "telegram", config = { bot_token = "", chat_id = "1" } }, msg)
check("missing token refused", req == nil and why:find("Bot Token") ~= nil)

print("== pushover")
req = F.build({ kind = "pushover", config = { app_token = "t", user_key = "u" } }, msg)
check(
  "fields",
  req.url == "https://api.pushover.net/1/messages.json"
    and req.body.token == "t"
    and req.body.user == "u"
    and req.body.title == "Garage"
    and req.body.message == "Door left open"
)
check("high → priority 1, no retry fields", req.body.priority == 1 and req.body.retry == nil)
local crit = F.build(
  { kind = "pushover", config = { app_token = "t", user_key = "u" } },
  R.message({ title = "Fire", priority = "critical" })
)
check(
  "critical → emergency with retry/expire",
  crit.body.priority == 2 and crit.body.retry == 60 and crit.body.expire == 3600
)
check(
  "low → -1",
  F.build(
    { kind = "pushover", config = { app_token = "t", user_key = "u" } },
    R.message({ title = "x", priority = "low" })
  ).body.priority == -1
)
check("title-only message uses the title as message", crit.body.message == "Fire")

print("== webhook (Slack/Discord)")
req = F.build({ kind = "webhook", config = { url = "https://hooks.slack.com/services/T/B/x" } }, msg)
check(
  "text and content both set",
  req.body.text == "Garage\nDoor left open" and req.body.content == req.body.text and req.body.username == "Control4"
)
check(
  "describe strips query",
  F.build({ kind = "webhook", config = { url = "https://discord.com/api/webhooks/1/abc?wait=true" } }, msg).describe
    == "webhook https://discord.com/api/webhooks/1/abc"
)
check("non-http refused", F.build({ kind = "webhook", config = { url = "ftp://x" } }, msg) == nil)

print("== generic")
req = F.build({ kind = "generic", config = { url = "https://example.test/hook", bearer = "secret" } }, msg, 1700000000)
check(
  "payload",
  req.body.title == "Garage"
    and req.body.message == "Door left open"
    and req.body.priority == "high"
    and req.body.channel == "all"
    and req.body.source == "control4"
    and req.body.sent_at == 1700000000
)
check(
  "bearer header only when set",
  req.headers["Authorization"] == "Bearer secret"
    and F.build({ kind = "generic", config = { url = "https://e.test" } }, msg).headers["Authorization"] == nil
)

print("== twilio")
req = F.build(
  { kind = "twilio", config = { account_sid = "AC1", auth_token = "tok", from = "+15550001", to = "+15559876" } },
  msg,
  nil,
  b64
)
check("url has the SID", req.url == "https://api.twilio.com/2010-04-01/Accounts/AC1/Messages.json")
check("form body in order", req.body == "To=%2B15559876&From=%2B15550001&Body=Garage%0ADoor%20left%20open", req.body)
check(
  "basic auth from sid:token",
  req.headers["Authorization"] == "Basic B64(AC1:tok)"
    and req.headers["Content-Type"] == "application/x-www-form-urlencoded"
)
check("describe masks the number", req.describe == "sms to +1555****", req.describe)
check("safeUrl redacts the SID", F.safeUrl(req.url):find("Accounts/%[redacted%]/") ~= nil)
check("missing creds refused", F.build({ kind = "twilio", config = { account_sid = "AC1" } }, msg, nil, b64) == nil)
check(
  "missing encoder refused",
  F.build({ kind = "twilio", config = { account_sid = "AC1", auth_token = "t", from = "a", to = "b" } }, msg) == nil
)

print("== misc")
check("unknown kind refused", F.build({ kind = "fax" }, msg) == nil)
check("formEncode sorts without order", F.formEncode({ b = "2", a = "1 2" }) == "a=1%202&b=2")

print("== a notification with only a MESSAGE is not sent twice")
do
  local only = R.message({ title = "", body = "Door left open", priority = "normal", channel = "all" })
  check(
    "the log still names it after its opening words",
    only.title == "Door left open" and only.title_from_body == true
  )
  check(
    "telegram sends the text once",
    F.build({ kind = "telegram", config = { bot_token = "t", chat_id = "1" } }, only).body.text == "Door left open"
  )
  check(
    "webhook sends the text once",
    F.build({ kind = "webhook", config = { url = "https://example.test/h" } }, only).body.text == "Door left open"
  )
  local sms = F.build(
    { kind = "twilio", config = { account_sid = "AC", auth_token = "t", from = "+1", to = "+2" } },
    only,
    0,
    b64
  )
  check("sms sends the text once", sms.body:find("Body=Door%%20left%%20open$") ~= nil, sms.body)
  local po = F.build({ kind = "pushover", config = { app_token = "t", user_key = "u" } }, only)
  check(
    "pushover leaves the title to the application's name",
    po.body.title == nil and po.body.message == "Door left open"
  )
  local both = R.message({ title = "Garage", body = "Door left open" })
  check(
    "a real title is still sent above the text",
    both.title_from_body == false
      and F.build({ kind = "telegram", config = { bot_token = "t", chat_id = "1" } }, both).body.text
        == "Garage\nDoor left open"
  )
  local long = R.message({ title = "", body = string.rep("word ", 30) })
  check(
    "a long message is whole, with no clipped copy above it",
    F.build({ kind = "telegram", config = { bot_token = "t", chat_id = "1" } }, long).body.text == long.body
  )
end

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
