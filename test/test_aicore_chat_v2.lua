-- AI Core touchscreen chat v2 and open chat (pure: src/aicore/chatv2.lua
-- and src/aicore/webui.lua with injected fakes; no driver, no controller).
--
--   [1] the capability: declared after the operations, in the same list
--   [2] display: every block type, closed keys, tones, bounds, JSON string
--       or structured value, dropped and counted, never an error
--   [3] suggestions: up to 3, 80 characters, dropped and counted
--   [4] deliver_result: the args are accepted and validated in operations.lua
--   [5] threads: minted per unlock, replaced at lock, never on the page
--   [6] the retry without a refused optional key (once, new request id,
--       remembered for the session)
--   [7] open chat: no PIN to ask; the privacy floor (never household
--       without an owner unlock); Explain behind the PIN
--   [8] open chat: elevation never mixes content (purge, in-flight answers
--       dropped, new thread), idle and hidden clear, own session only
--   [9] Owner PIN mode: locked = no conversation, held answers as before
--   [10] abuse limits apply to open sessions
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

require("drivers-common-public.global.lib") -- tostring_return_period (the JSON encoder's number format)
JSON = JSON or require("JSON")
local V = require("aicore.vocab")
local ChatV2 = require("aicore.chatv2")
local Operations = require("aicore.operations")
local Webui = require("aicore.webui")

print("[1] the capability")
local reg = V.registeredCommands()
check("chat_v2 is declared (vocab.DECLARED = chatv2.CAPABILITY)", V.DECLARED[1] == ChatV2.CAPABILITY)
check(
  "registered after the nine operations, in the same list",
  #reg == #V.OPERATIONS + 1 and reg[#reg] == "chat_v2" and reg[9] == "read_device_state",
  table.concat(reg, ",")
)
local isOp = false
for _, op in ipairs(V.OPERATIONS) do
  isOp = isOp or op == "chat_v2"
end
check("…and is not an operation (operations.lua refuses it)", not isOp and Operations.parse("chat_v2", {}) == nil)

print("[2] display")
local good = {
  { t = "stat", label = "Living room", value = "21.5", unit = "°C", tone = "ok" },
  {
    t = "list",
    title = "Doors",
    items = { { label = "Front", value = "Locked", tone = "ok" }, { label = "Garage", value = "Open", tone = "warn" } },
  },
  { t = "note", text = "The garage has been open for 2 hours.", tone = "warn" },
}
local d, dropped = ChatV2.display(JSON:encode(good))
check("a JSON-encoded string of three blocks: all kept", d ~= nil and #d == 3 and dropped == 0, dropped)
check(
  "…normalised exactly",
  d and d[1].value == "21.5" and d[1].unit == "°C" and d[2].items[2].tone == "warn" and d[3].tone == "warn"
)
d, dropped = ChatV2.display(good)
check("the same as a structured value", d ~= nil and #d == 3 and dropped == 0)
check("absent: nothing, nothing dropped", select(2, ChatV2.display(nil)) == 0 and ChatV2.display(nil) == nil)
local function only(block)
  local out, n = ChatV2.display({ block })
  return out == nil and n == 1
end
check(
  "a value sent as a number is dropped (every field is a string)",
  only({ t = "stat", label = "Power", value = 1250 })
)
check("leading whitespace dropped", only({ t = "note", text = " x" }))
check("trailing whitespace dropped", only({ t = "note", text = "x " }))
check("markup dropped", only({ t = "note", text = "<b>bold</b>" }))
check("a URL dropped", only({ t = "note", text = "See https://example.org/x" }))
check("a www address dropped", only({ t = "note", text = "See www.example" }))
check("a bare domain dropped", only({ t = "note", text = "Visit example.com today" }))
check("a bidi control dropped", only({ t = "note", text = "abc\226\128\174def" }))
-- Limits are in CODE POINTS (accents and emoji count one each), never cut.
local E = "\240\159\143\160" -- U+1F3E0 (house), 4 bytes
check("UTF-8 counter: é = 1, an emoji = 1, ASCII = 1", ChatV2.length("é" .. E .. "a") == 3)
check("UTF-8 counter: malformed = nil", ChatV2.length("a\255") == nil and ChatV2.length("\237\160\128") == nil)
check(
  "120 accented characters (240 bytes): kept",
  ChatV2.display({ { t = "stat", label = string.rep("é", 120), value = "1" } }) ~= nil
)
check("121 accented characters: dropped, not cut", only({ t = "stat", label = string.rep("é", 121), value = "1" }))
check("120 emoji (480 bytes): kept", ChatV2.display({ { t = "stat", label = "x", value = string.rep(E, 120) } }) ~= nil)
check("121 emoji: dropped", only({ t = "stat", label = "x", value = string.rep(E, 121) }))
check("a 300-emoji note kept", ChatV2.display({ { t = "note", text = string.rep(E, 300) } }) ~= nil)
check("a 301-emoji note dropped", only({ t = "note", text = string.rep(E, 301) }))
local keptE = ChatV2.display({ { t = "list", items = { { label = "Zoë's room " .. E, value = "21 °C" } } } })
check(
  "a list item with accents and an emoji is kept verbatim",
  keptE and keptE[1].items[1].label == "Zoë's room " .. E
)
check("a zero-width space dropped", only({ t = "note", text = "a\226\128\139b" }))
check("a soft hyphen dropped", only({ t = "note", text = "a\194\173b" }))
check("a word joiner dropped", only({ t = "note", text = "a\226\129\160b" }))
check("a tag character dropped", only({ t = "note", text = "a\243\160\128\129b" }))
check("a full-width letter dropped", only({ t = "note", text = "\239\188\161" }))
check("a byte-order mark dropped", only({ t = "note", text = "\239\187\191x" }))
check("a decimal value is not a domain", ChatV2.display({ { t = "stat", label = "Cellar", value = "13.2" } }) ~= nil)
check("unknown type dropped", only({ t = "html", text = "<b>x</b>" }))
check("unknown key dropped (closed keys)", only({ t = "note", text = "x", onclick = "y" }))
check("bad tone dropped", only({ t = "note", text = "x", tone = "red" }))
check("label over 120 characters dropped", only({ t = "stat", label = string.rep("a", 121), value = "1" }))
check(
  "a 120-character label kept",
  ChatV2.display({ { t = "stat", label = string.rep("é", 120), value = "1" } }) ~= nil
)
check("note over 300 characters dropped", only({ t = "note", text = string.rep("a", 301) }))
check("a 300-character note kept", ChatV2.display({ { t = "note", text = string.rep("a", 300) } }) ~= nil)
check("a stat without a value dropped", only({ t = "stat", label = "x" }))
check("an empty string dropped", only({ t = "note", text = "" }))
check("a control character dropped", only({ t = "note", text = "a\27[31mb" }))
check("a line break dropped (a control character)", only({ t = "note", text = "a\nb" }))
check("malformed UTF-8 dropped", only({ t = "note", text = "a\255b" }))
check("a table where text belongs dropped", only({ t = "note", text = { "x" } }))
local items = {}
for i = 1, 13 do
  items[i] = { label = "Item " .. i }
end
check("a list of 13 items dropped", only({ t = "list", items = items }))
items[13] = nil
check("a list of 12 items kept", ChatV2.display({ { t = "list", items = items } }) ~= nil)
check("an empty list dropped", only({ t = "list", items = {} }))
check("an item with an unknown key drops the list", only({ t = "list", items = { { label = "a", href = "x" } } }))
local seven = {}
for i = 1, 7 do
  seven[i] = { t = "note", text = "n" .. i }
end
d, dropped = ChatV2.display(seven)
check("seven blocks: six kept, one counted", d and #d == 6 and dropped == 1, dropped)
d, dropped = ChatV2.display({ good[1], { t = "bogus" }, good[3] })
check("one bad block among good ones: the others stay", d and #d == 2 and dropped == 1)
d, dropped = ChatV2.display("{not json")
check("unreadable JSON: nothing, one counted", d == nil and dropped == 1)
d, dropped = ChatV2.display(JSON:encode({ t = "note", text = "x" }))
check("an object instead of a list: nothing, one counted", d == nil and dropped == 1)
local bigList = {}
for i = 1, 6 do
  local its = {}
  for j = 1, 12 do
    its[j] = { label = string.rep("l", 60), value = string.rep("v", 60) }
  end
  bigList[i] = { t = "list", items = its }
end
d, dropped = ChatV2.display(bigList)
check("over 4096 bytes serialised: nothing, one counted", d == nil and dropped == 1, dropped)
d, dropped = ChatV2.display(JSON:encode(bigList))
check("…the same as a string", d == nil and dropped == 1)
d, dropped = ChatV2.display(42)
check("a number: nothing, one counted", d == nil and dropped == 1)

print("[3] suggestions")
local E = "\240\159\143\160"
local sg, sd = ChatV2.suggestions(JSON:encode({ "Is the gate closed?", "And the garage?" }))
check("a JSON string of two: both", sg and #sg == 2 and sd == 0)
sg, sd = ChatV2.suggestions({ "a?", "b?", "c?", "d?" })
check("four: three kept, one counted", sg and #sg == 3 and sd == 1)
sg, sd = ChatV2.suggestions({ string.rep("q", 80) .. "?", "ok?", "ok?", 5, "", "No question mark" })
check("too long, twice, a number, empty, not a question: counted", sg and #sg == 1 and sd == 5, sd)
sg = ChatV2.suggestions({ string.rep("é", 79) .. "?", string.rep(E, 79) .. "?", "Ça va " .. E .. "?" })
check("80 code points with accents or emoji: kept", sg and #sg == 3, sg and #sg)
sg, sd = ChatV2.suggestions({ string.rep(E, 80) .. "?" })
check("81 emoji code points: dropped", sg == nil and sd == 1)
sg, sd = ChatV2.suggestions({ "Is it on\226\128\143?" })
check("a suggestion with a bidi mark: dropped", sg == nil and sd == 1)
sg, sd = ChatV2.suggestions("nope")
check("unreadable: nothing, one counted", sg == nil and sd == 1)

print("[4] deliver_result args")
local op = Operations.parse("deliver_result", {
  response_id = "r-1",
  job_id = "j-1",
  text = "Two doors.",
  display = JSON:encode(good),
  suggestions = JSON:encode({ "Lock the garage?" }),
})
check(
  "accepted with display and suggestions",
  op ~= nil and #op.display == 3 and op.suggestions[1] == "Lock the garage?"
)
op = Operations.parse("deliver_result", { response_id = "r-2", text = "Hi.", display = "garbage", suggestions = 7 })
check(
  "invalid ones never refuse the answer: text kept, both dropped and counted",
  op ~= nil and op.text == "Hi." and op.display == nil and op.display_dropped == 1 and op.suggestions_dropped == 1
)
op = Operations.parse("deliver_result", { response_id = "r-3", text = "Plain." })
check("an answer with neither key: text only", op and op.display == nil and op.suggestions == nil)

-- ── a pure page relay with fakes ────────────────────────────────────────────
local clock = 1800000000
local hexSeq = 0
local reqSeq = 0
local DEPS
local cloud = {} -- every body sent
local lastJob -- the job id of the last accepted ask
local cloudAnswer -- function(op, body) -> answer
local mode = "open"
local detail = "household"
local pinReady = true
local takeOk = true
DEPS = {
  now = function()
    return clock
  end,
  newHex = function()
    hexSeq = hexSeq + 1
    return string.format("%032x", hexSeq)
  end,
  newRequestId = function()
    reqSeq = reqSeq + 1
    return "aic-" .. reqSeq
  end,
  facts = function()
    return { licensed = true, provider_configured = true, online = true, learning_active = true }
  end,
  detail = function()
    return detail
  end,
  access = function()
    return mode
  end,
  relayHost = function()
    return "h"
  end,
  pinAvailability = function(cb)
    cb(pinReady and { available = true, reason = "ready" } or { available = false, reason = "pin_not_installed" })
  end,
  pinRequest = function(cap, args, cb)
    if cap == "pinlock.challenge" then
      cb({ status = "ok", result = { challenge_id = string.rep("c", 32), verify_url = "http://h:47831/verify" } })
    else
      cb({ status = "ok", result = { verified = true, role = "owner", verified_at = clock } })
    end
  end,
  cloud = function(o, body, cb)
    cloud[#cloud + 1] = { op = o, body = body }
    if o ~= "ask" then
      cb({ status = "ok", result = { enabled = false, count = 0, eligible = {} } })
      return
    end
    lastJob = "job-" .. #cloud
    cb(cloudAnswer and cloudAnswer(o, body) or { status = "ok", result = { accepted = true, job_id = lastJob } })
  end,
  take = function()
    return takeOk
  end,
  appHtml = function()
    return "<html></html>"
  end,
}
local TOKEN = string.rep("a", 32)
local ui = Webui.new(DEPS)
local function http(method, path, s, body)
  local r = ui:route({
    method = method,
    path = path,
    query = { k = TOKEN, s = s },
    body = body and JSON:encode(body) or "",
  }, TOKEN)
  return JSON:decode(r.body), r.status
end
local function open()
  return http("POST", "/session").s
end
local function state(s)
  return http("GET", "/state", s)
end
local function unlock(s)
  local u = http("POST", "/chat/unlock", s)
  local st = state(s)
  assert(st.prompt, "no prompt: " .. JSON:encode(u))
  return http("POST", "/pin/done", s, { challenge_id = st.prompt.challenge_id })
end
local function asksSent()
  local n = 0
  for _, c in ipairs(cloud) do
    n = n + (c.op == "ask" and 1 or 0)
  end
  return n
end
--- Time passes while the page keeps polling (every 25 s; polls are not
--- interaction).
local function wait(seconds, s)
  while seconds > 0 do
    local step = math.min(seconds, 25)
    clock = clock + step
    seconds = seconds - step
    state(s)
  end
end
local function lastAsk()
  for i = #cloud, 1, -1 do
    if cloud[i].op == "ask" then
      return cloud[i].body
    end
  end
end
local function deliverLast(text, extra)
  local job = lastJob
  return ui:deliver("relay-x", text, job, extra)
end

print("[5] threads")
mode = "owner_pin"
local s = open()
check("Owner PIN mode, locked: no thread exists yet", ui.sessions[s].thread == nil)
unlock(s)
local t1 = ui.sessions[s].thread
check("an unlock mints a thread (valid by the contract)", ChatV2.validThread(t1), t1)
http("POST", "/ask", s, { question = "Is the gate closed?" })
check("the ask carries it", lastAsk().thread == t1)
http("POST", "/ask", s, { question = "And the garage?" })
check("…and the follow-up the same one", lastAsk().thread == t1)
local st = state(s)
check("the page never sees the thread id", not JSON:encode(st):find(t1, 1, true))
check("…but is told follow-ups are on", st.chat.followups == true)
http("POST", "/chat/lock", s)
check("Lock drops the thread", ui.sessions[s].thread == nil)
clock = clock + 61
unlock(s)
local t2 = ui.sessions[s].thread
check("the next unlock mints a NEW thread", ChatV2.validThread(t2) and t2 ~= t1)
st = state(s)
check(
  "the page can mark where the new conversation starts (conv moved)",
  st.chat.conv == 2 and st.chat.conversation[1].conv == 1,
  st.chat.conv
)
local ui2 = Webui.new(DEPS)
check("a driver restart: nothing remembered (new module state)", next(ui2.sessions) == nil)

print("[6] the retry without a refused key")
clock = clock + 61
local refusedOnce = 0
cloudAnswer = function(_, body)
  if body.thread ~= nil then
    refusedOnce = refusedOnce + 1
    return {
      status = "error",
      error_code = "invalid_args",
      result = { reason = "invalid_fields", fields = { "thread" } },
    }
  end
end
local before = asksSent()
local firstAt = #cloud + 1
local r = http("POST", "/ask", s, { question = "Retry me?" })
check("an ask the cloud refuses for `thread` is sent again without it", asksSent() == before + 2 and refusedOnce == 1)
check(
  "…under a new request id, which the page's id follows",
  cloud[firstAt].body.request_id ~= cloud[firstAt + 1].body.request_id and r.id == cloud[firstAt + 1].body.request_id
)
st = state(s)
check(
  "…and is pending, not refused",
  st.chat.conversation[#st.chat.conversation].state == "pending",
  st.chat.conversation[#st.chat.conversation].state
)
check("the session remembers: follow-ups off", st.chat.followups == false)
http("POST", "/ask", s, { question = "Again?" })
check("the next ask goes without `thread` at once (one send)", asksSent() == before + 3 and lastAsk().thread == nil)
check("counted", ui.counters.thread_retries == 1)
cloudAnswer = function()
  return {
    status = "error",
    error_code = "invalid_args",
    result = { reason = "invalid_fields", fields = { "question" } },
  }
end
clock = clock + 61
local s2 = open()
unlock(s2)
before = asksSent()
http("POST", "/ask", s2, { question = "Other refusal" })
check("a refusal about another field is not retried", asksSent() == before + 1)
st = state(s2)
check("…shown as refused", st.chat.conversation[1].state == "refused")
cloudAnswer = nil
check(
  "ChatV2.refusedKeys reads a dotted path and only keys that were sent",
  #ChatV2.refusedKeys({ error_code = "invalid_args", result = { fields = { "body.thread" } } }, { thread = "x" }) == 1
    and #ChatV2.refusedKeys({ error_code = "invalid_args", result = { fields = { "thread" } } }, {}) == 0
)

print("[7] open chat: no PIN, the privacy floor, Explain")
mode = "open"
detail = "household"
pinReady = false
clock = clock + 61
ui = Webui.new(DEPS)
s = open()
st = state(s)
check("open mode without PIN Lock: the chat is available and visible", st.chat.available and st.chat.locked == false)
check(
  "…not elevated, and no unlock offered without PIN Lock",
  st.chat.elevated == false and st.chat.can_elevate == false
)
check("…built-ins and presets shown, Explain not", #st.chat.suggestions >= 3 and st.chat.explain == false)
r = http("POST", "/ask", s, { question = "Is anyone home?" })
check("anyone may ask", r.ok == true)
check("an un-elevated ask NEVER carries household (Touchscreen Detail = household)", lastAsk().detail == "standard")
for _, dl in ipairs({ "household", "standard" }) do
  detail = dl
  clock = clock + 16
  http("POST", "/ask", s, { suggestion_id = "today" })
  check("…" .. dl .. " configured: a built-in asks at standard", lastAsk().detail == "standard")
end
check("…and a thread is minted lazily for the open conversation", ChatV2.validThread(lastAsk().thread))
r = http("POST", "/ask", s, { explain = true })
check("Explain is refused without the owner PIN, in words", r.ok == false and r.message == Webui.TEXT.explain_needs_pin)
detail = "basic"
st = state(s)
check("Basic switches the open chat off", st.chat.available == false and st.chat.message == Webui.TEXT.basic)
r = http("POST", "/ask", s, { question = "Still?" })
check("…and refuses an ask", r.ok == false and r.reason == "basic")
detail = "household"
deliverLast("Yes, two people.", { display = { { t = "stat", label = "People home", value = "2" } } })
st = state(s)
local last = st.chat.conversation[#st.chat.conversation]
check(
  "the open session reads its own answer, with its block",
  last.a == "Yes, two people." and last.display[1].value == "2"
)
local other = open()
st = state(other)
check("another open session sees none of it", #st.chat.conversation == 0)

print("[8] elevation never mixes content")
pinReady = true
clock = clock + 61
ui = Webui.new(DEPS)
s = open()
http("POST", "/ask", s, { question = "Open question" })
local openThread = lastAsk().thread
local openJob = lastJob
ui:deliver("x", "Open answer", openJob)
st = state(s)
check("PIN Lock ready: Unlock for more offered", st.chat.can_elevate == true)
unlock(s)
st = state(s)
check("elevated: locks_in shown, Explain shown", st.chat.elevated == true and st.chat.locks_in > 0 and st.chat.explain)
local elevThread = ui.sessions[s].thread
check("the unlock minted a new thread", ChatV2.validThread(elevThread) and elevThread ~= openThread)
clock = clock + 16
http("POST", "/ask", s, { question = "Who came home today?" })
check("an elevated ask carries the configured detail and the new thread", lastAsk().detail == "household")
check("…on the elevated thread", lastAsk().thread == elevThread)
local elevJob = lastJob
clock = clock + 16
http("POST", "/ask", s, { question = "Answered while elevated" })
ui:deliver("x", "Household answer", lastJob)
st = state(s)
check("while elevated, both conversations are shown", #st.chat.conversation == 3)
http("POST", "/chat/lock", s)
st = state(s)
check(
  "Lock removes every elevated exchange from the page",
  #st.chat.conversation == 1 and st.chat.conversation[1].q == "Open question",
  #st.chat.conversation
)
check("…and from the session's history", #ui.sessions[s].conversation == 1)
check("…a new thread (not the elevated one)", ui.sessions[s].thread ~= elevThread and ui.sessions[s].thread ~= nil)
local owned = ui:deliver("x", "Late household answer", elevJob)
st = state(s)
check(
  "an elevated answer still in flight is dropped, never shown later",
  owned == true and not JSON:encode(st):find("Late household", 1, true)
)
clock = clock + 16
http("POST", "/ask", s, { question = "Back to open" })
check("after Lock the asks are standard again", lastAsk().detail == "standard")
-- the idle timer ends the elevation the same way
unlock(s)
clock = clock + 16
http("POST", "/ask", s, { question = "Elevated again" })
wait(Webui.LIMITS.unlock_idle_seconds + 1, s)
st = state(s)
check(
  "the unlock timer relocks: the elevated exchange is gone",
  st.chat.elevated == false and not JSON:encode(st):find("Elevated again", 1, true)
)
-- open idle: 5 minutes after the last question
clock = clock + 61
http("POST", "/ask", s, { question = "An open question" })
local beforeThread = ui.sessions[s].thread
st = state(s)
check("(an open question on the screen)", #st.chat.conversation == 1)
wait(Webui.LIMITS.open_idle_seconds - 10, s)
st = state(s)
check("…still there just under 5 minutes", #st.chat.conversation == 1)
wait(11, s)
st = state(s)
check("5 minutes after the last question the open conversation is cleared", #st.chat.conversation == 0)
check("…with a new thread", ui.sessions[s].thread ~= beforeThread)
http("POST", "/ask", s, { question = "Hidden soon" })
beforeThread = ui.sessions[s].thread
http("POST", "/chat/lock", s, { hidden = true })
st = state(s)
check("the page hidden: the open conversation is cleared, new thread", #st.chat.conversation == 0)
check("…new thread", ui.sessions[s].thread ~= beforeThread)
-- a mode switch never shows elevated content to an un-elevated view
mode = "owner_pin"
local s3 = open()
unlock(s3)
clock = clock + 16
http("POST", "/ask", s3, { question = "Asked in PIN mode" })
http("POST", "/chat/lock", s3)
mode = "open"
st = state(s3)
check(
  "switching to Open never shows what was asked under the PIN",
  not JSON:encode(st):find("Asked in PIN mode", 1, true) and st.chat.locked == false
)
mode = "open"

print("[9] Owner PIN mode")
mode = "owner_pin"
clock = clock + 61
ui = Webui.new(DEPS)
s = open()
st = state(s)
check(
  "locked: no conversation, no suggestions",
  st.chat.locked == true and st.chat.conversation == nil and st.chat.suggestions == nil
)
r = http("POST", "/ask", s, { question = "x" })
check("an ask is refused locked", r.ok == false and r.reason == "chat_locked")
unlock(s)
http("POST", "/ask", s, { question = "Held?" })
local heldJob = lastJob
http("POST", "/chat/lock", s)
ui:deliver("x", "Held answer", heldJob)
clock = clock + 61
unlock(s)
st = state(s)
check(
  "an answer that arrived while locked is shown after the next unlock (as before)",
  st.chat.conversation[1].a == "Held answer"
)
check("Owner PIN asks carry the configured detail", lastAsk().detail == "household")

print("[10] abuse limits in open mode")
mode = "open"
clock = clock + 61
ui = Webui.new(DEPS)
s = open()
local okN = 0
local refused
for i = 1, 6 do
  local x = http("POST", "/ask", s, { question = "Q" .. i })
  if x.ok then
    okN = okN + 1
  else
    refused = x
  end
end
check("four asks a minute, then refused", okN == Webui.LIMITS.asks_per_minute, okN)
check("…with a sentence the page shows", refused and refused.message == Webui.TEXT.rate_limited)
for _ = 1, Webui.LIMITS.sessions + 2 do
  open()
end
check("the session cap holds for open sessions", ui:sessionCount() == Webui.LIMITS.sessions)
check(
  "counted for Print Diagnostics, counts only",
  ui:chatLine():find("chat_v2 declared", 1, true) ~= nil and not ui:chatLine():find("Q1", 1, true)
)

print(string.format("%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
