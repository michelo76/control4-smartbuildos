package.path = "src/?.lua;" .. package.path
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

print("== priorities and clocks")
check(
  "names parse",
  R.parsePriority("High") == 2 and R.parsePriority(" critical ") == 3 and R.parsePriority("low") == 0
)
check("unknown → normal", R.parsePriority("urgent") == 1 and R.parsePriority(nil) == 1)
check("numbers parse", R.parsePriority("3") == 3 and R.parsePriority("9") == 1)
check(
  "clock parse",
  R.parseClock("22:30") == 1350
    and R.parseClock("7:05") == 425
    and R.parseClock("24:00") == nil
    and R.parseClock("") == nil
)
check(
  "quiet window same day",
  R.inQuietHours("13:00", "15:00", 14 * 60) and not R.inQuietHours("13:00", "15:00", 15 * 60)
)
check(
  "quiet window wraps midnight",
  R.inQuietHours("22:00", "07:00", 23 * 60)
    and R.inQuietHours("22:00", "07:00", 30)
    and not R.inQuietHours("22:00", "07:00", 8 * 60)
)
check(
  "empty or equal window never quiet",
  not R.inQuietHours("", "", 100) and not R.inQuietHours("08:00", "08:00", 8 * 60)
)

print("== message")
local m, why = R.message({ title = "  Door  ", body = "Front door open", priority = "high", channel = " Telegram " })
check("message trimmed and typed", m.title == "Door" and m.priority == 2 and m.channel == "telegram")
check("empty message refused", R.message({}) == nil and why == nil)
local only = R.message({ body = "just a body" })
check("title falls back to the body", only.title == "just a body")
check("long body cut", #R.message({ body = string.rep("x", 5000) }).body == R.LIMITS.body)
check("blank channel → all", R.message({ title = "x", channel = "" }).channel == "all")

print("== routing")
local clock = { t = 1000, minute = 12 * 60 }
local targets = {
  { id = "telegram", label = "Telegram", enabled = true, min_priority = 0, quiet_start = "", quiet_end = "" },
  { id = "pushover", label = "Pushover", enabled = true, min_priority = 2, quiet_start = "", quiet_end = "" },
  { id = "webhook", label = "Slack / Discord Webhook", enabled = false, min_priority = 0 },
  { id = "twilio", label = "Twilio SMS", enabled = true, min_priority = 0, quiet_start = "22:00", quiet_end = "07:00" },
}
local cfg = { dedupe = 300, perHour = 3 }
local router = R.new({
  now = function()
    return clock.t
  end,
  minuteOfDay = function()
    return clock.minute
  end,
  targets = function()
    return targets
  end,
  dedupe_seconds = function()
    return cfg.dedupe
  end,
  per_hour = function()
    return cfg.perHour
  end,
})
local function reasons(decisions)
  local out = {}
  for _, d in ipairs(decisions) do
    out[#out + 1] = d.target.id .. ":" .. (d.reason or d.decision)
  end
  return table.concat(out, " ")
end
local d, sends, matched =
  router:route(R.message({ title = "Hello", body = "world", priority = "normal", channel = "all" }))
check("all: 4 matched, 2 sends", matched == 4 and sends == 2, reasons(d))
check(
  "decisions name the reasons",
  reasons(d) == "telegram:send pushover:below_priority webhook:disabled twilio:send",
  reasons(d)
)
d, sends = router:route(R.message({ title = "Hello", body = "world", priority = "normal", channel = "all" }))
check(
  "identical message inside the window is a duplicate",
  sends == 0 and reasons(d):find("telegram:duplicate") ~= nil,
  reasons(d)
)
d, sends = router:route(R.message({ title = "Hello", body = "world 2", priority = "normal", channel = "all" }))
check("different body is not a duplicate", sends == 2)
clock.t = clock.t + 301
d, sends = router:route(R.message({ title = "Hello", body = "world", priority = "normal", channel = "telegram" }))
check("after the dedupe window the same message sends again; channel picks one target", sends == 1 and #d == 1)
d, sends = router:route(R.message({ title = "Hello", body = "world 4", priority = "normal", channel = "telegram" }))
check("rate limit: 3 per hour reached", sends == 0 and reasons(d) == "telegram:rate_limited", reasons(d))
clock.t = clock.t + 3601
d, sends = router:route(R.message({ title = "Hello", body = "world 5", priority = "normal", channel = "telegram" }))
check("rolling hour frees the slot", sends == 1)
d, sends = router:route(R.message({ title = "Alarm", body = "x", priority = "high", channel = "Pushover" }))
check(
  "priority gate passes high to pushover; label match is case-insensitive",
  sends == 1 and d[1].target.id == "pushover"
)
clock.minute = 23 * 60
d, sends = router:route(R.message({ title = "Night", body = "x", priority = "high", channel = "Twilio SMS" }))
check("quiet hours suppress high", sends == 0 and reasons(d) == "twilio:quiet_hours", reasons(d))
d, sends = router:route(R.message({ title = "Night", body = "fire", priority = "critical", channel = "twilio" }))
check("critical bypasses quiet hours", sends == 1)
d, sends, matched = router:route(R.message({ title = "x", body = "y", channel = "pigeon" }))
check(
  "unknown channel matches nothing and is counted",
  matched == 0 and sends == 0 and router.counters.unknown_channel == 1
)
cfg.dedupe = 0
d, sends = router:route(R.message({ title = "Night", body = "fire", priority = "critical", channel = "twilio" }))
check("dedupe 0 disables dedupe", sends == 1)
check(
  "counters",
  router.counters.requested == 11
    and router.counters.duplicate == 2
    and router.counters.quiet_hours == 1
    and router.counters.rate_limited == 1
    and router.counters.below_priority == 3,
  table.concat({ router.counters.requested, router.counters.duplicate, router.counters.below_priority }, "/")
)

print("== retry schedule and log")
check(
  "backoff 5 then 30 then stop",
  R.retryDelay(1) == 5 and R.retryDelay(2) == 30 and R.retryDelay(3) == nil and R.MAX_ATTEMPTS == 3
)
for i = 1, 55 do
  router:record({ target = "telegram", status = i % 2 == 0 and "sent" or "failed", title = "m" .. i, attempts = 1 })
end
check("log bounded at 50, newest kept", #router.log == 50 and router.log[50].title == "m55" and router.log[1].seq == 6)
check("sent/failed counted", router.counters.sent == 27 and router.counters.failed == 28)
router:record({ target = "pushover", status = "retrying", title = "r", attempts = 1, detail = "HTTP 500" })
check("retrying counted", router.counters.retried == 1)
local line = R.formatEntry(router:recent_log(1)[1])
check(
  "formatEntry",
  line:find("pushover") and line:find("retrying") and line:find("attempt 1") and line:find("HTTP 500"),
  line
)
check("recent_log(3) chronological", #router:recent_log(3) == 3 and router:recent_log(3)[3].title == "r")

print("== reserve: a direct send (a reply) counts toward the hourly limit and nothing else")
do
  local t = 5000
  local direct = R.new({
    now = function()
      return t
    end,
    minuteOfDay = function()
      return 23 * 60
    end,
    targets = function()
      return {
        {
          id = "telegram",
          label = "Telegram",
          enabled = false,
          min_priority = 3,
          quiet_start = "22:00",
          quiet_end = "07:00",
        },
      }
    end,
    per_hour = 2,
  })
  check(
    "allowed although the target is off, quiet and gated",
    direct:reserve("telegram") == true and direct:reserve("telegram") == true
  )
  local ok, why = direct:reserve("telegram")
  check(
    "the third in an hour is rate limited",
    ok == false and why == "rate_limited" and direct.counters.rate_limited == 1
  )
  check("another target has its own count", direct:reserve("twilio") == true)
  t = t + 3601
  check("an hour later it is allowed again", direct:reserve("telegram") == true)
end

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
