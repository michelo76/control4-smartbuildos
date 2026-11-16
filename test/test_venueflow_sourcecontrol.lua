-- VenueFlow: basic controls for a source (channel up and down, digits,
-- favourite channels, arrows, play).
--
-- Covered: the fixed key vocabulary and the Control4 command each key
-- becomes, a page that names anything else, who may press, which groups a
-- source has, an unmapped source, favourites dialled digit by digit in
-- order and spaced, what an operator page is sent, the schema, and that a
-- client may edit favourites but not which controls a source has.
--
-- SIMULATION-verified: "sent" here means the simulator's log shows the
-- command. Whether a real cable box obeys is HARDWARE_VALIDATION.md.
--
-- Run from the driver root: make test

local H = require("venueflow_harness")
local SourceControl = require("venueflow.sourcecontrol")
local Schema = require("venueflow.schema")
local T = H.checker()
local check, eq = T.check, T.eq

local function copy(t)
  return H.JSON:decode(H.JSON:encode(t))
end

print("the vocabulary")
eq("channel up is the documented pulse command", SourceControl.KEYS.CH_UP[2], "PULSE_CHANNEL_UP")
eq("channel down", SourceControl.KEYS.CH_DOWN[2], "PULSE_CHANNEL_DOWN")
eq("a digit", SourceControl.KEYS.NUM_7[2], "NUMBER_7")
eq("last channel", SourceControl.KEYS.RECALL[2], "RECALL")
eq("select on the arrows is ENTER", SourceControl.KEYS.SELECT[2], "ENTER")
local groups = {}
for _, g in ipairs(SourceControl.GROUPS) do
  groups[g] = true
end
local keyCount = 0
for key, spec in pairs(SourceControl.KEYS) do
  keyCount = keyCount + 1
  check(key .. " belongs to a known group", groups[spec[1]] == true)
  check(key .. " maps to a plain command name", type(spec[2]) == "string" and spec[2]:match("^[A-Z0-9_]+$") ~= nil)
end
eq("the vocabulary is closed at 33 keys", keyCount, 33)
eq(
  "206 is dialled 2, 0, 6, Enter",
  table.concat(SourceControl.sequence("206", true), " "),
  "NUMBER_2 NUMBER_0 NUMBER_6 ENTER"
)
eq("5-1 uses the dash", table.concat(SourceControl.sequence("5-1", true), " "), "NUMBER_5 DASH NUMBER_1 ENTER")
eq(
  "a dot is sent as the dash key",
  table.concat(SourceControl.sequence("12.3", false), " "),
  "NUMBER_1 NUMBER_2 DASH NUMBER_3"
)
for _, good in ipairs({ "2", "206", "5-1", "12.3", "12345678" }) do
  check(good .. " is a channel", SourceControl.validChannel(good))
end
for _, bad in ipairs({ "", "abc", "5--1", "-5", "5-", "123456789", "1 2", "PULSE", "5;1" }) do
  check("'" .. bad .. "' is not a channel", not SourceControl.validChannel(bad))
end
check("a number is not a channel string", not SourceControl.validChannel(206))
eq(
  "a cable box starts with channel keys and a keypad",
  table.concat(SourceControl.defaults("cable"), ","),
  "channel,keypad"
)
eq("signage starts with nothing", #SourceControl.defaults("signage"), 0)

-- ── a venue ─────────────────────────────────────────────────────────────────
local env = H.new({ spacingMs = 50 })
local installer = env.publishSample("sports_bar")
local I = { session = installer }
local core = env.core

local function calls(deviceId)
  local out = {}
  for _, c in ipairs(core.sim.calls) do
    if c.target == deviceId and c.command ~= "SELECT_VIDEO_DEVICE" then
      out[#out + 1] = c.command
    end
  end
  return out
end
local function drain()
  for _ = 1, 40 do
    env.clock.advance(400)
  end
end

local sports1 = core.ix.sources["sports-1"]
local device = sports1.c4DeviceId
eq("the sample's satellite source has channel keys and a keypad", table.concat(sports1.controls, ","), "channel,keypad")

print("who may press")
local manager = env.login("manager", "2580")
local M = { session = manager }
local TILE = { tile = true } -- the bartender tablet
eq(
  "no identity: refused",
  env.send("SOURCE_KEY", { sourceId = "sports-1", key = "CH_UP" }).errorCode,
  "VF_UNAUTHENTICATED"
)
local up = env.send("SOURCE_KEY", { sourceId = "sports-1", key = "CH_UP" }, M)
eq("the manager presses channel up", up.ok, true)
eq("...and is told it was sent, with no feedback to expect", up.data.feedback, false)
drain()
eq("the box's device got the documented command", calls(device)[1], "PULSE_CHANNEL_UP")
eq(
  "the bartender tablet may too (the role has the permission)",
  env.send("SOURCE_KEY", { sourceId = "sports-1", key = "CH_DOWN" }, TILE).ok,
  true
)

-- Take the permission from the bartender.
local d = env.send("DRAFT_GET", {}, I).data.draft
local cfg = copy(d.config)
for _, p in ipairs(cfg.profiles) do
  if p.id == "bartender" then
    p.permissions.sourceControl = false
  end
end
cfg.sources[1].favorites = {
  { id = "espn", name = "ESPN", channel = "206" },
  { id = "local", name = "Local 5", channel = "5-1" },
}
cfg.sources[3].controls = {}
local acks = {}
local sv = env.send("DRAFT_SAVE", { config = cfg, baseRevision = d.revision }, I)
eq("the installer saves favourites and permissions", sv.ok, true)
for _, i in ipairs(sv.data.issues) do
  acks[#acks + 1] = i.id
end
eq("...and publishes", env.send("PUBLISH", { acknowledged = acks }, I).ok, true)
drain()
manager = env.login("manager", "2580")
M = { session = manager }
eq(
  "a profile without the permission is refused",
  env.send("SOURCE_KEY", { sourceId = "sports-1", key = "CH_UP" }, TILE).errorCode,
  "VF_FORBIDDEN"
)
local tileHello = env.send("HELLO", {}, TILE)
local sawControls = false
for _, s in ipairs(tileHello.data.config.sources) do
  if s.controls ~= nil then
    sawControls = true
  end
end
check("...and its screen is not sent any controls", not sawControls)

print("what a page may name")
eq(
  "an unknown key",
  env.send("SOURCE_KEY", { sourceId = "sports-1", key = "POWER_OFF" }, M).errorCode,
  "VF_INVALID_PAYLOAD"
)
eq(
  "a Control4 command name is not a key",
  env.send("SOURCE_KEY", { sourceId = "sports-1", key = "PULSE_CHANNEL_UP" }, M).errorCode,
  "VF_INVALID_PAYLOAD"
)
eq("an unknown source", env.send("SOURCE_KEY", { sourceId = "nope", key = "CH_UP" }, M).errorCode, "VF_NOT_FOUND")
eq(
  "a group the source does not have",
  env.send("SOURCE_KEY", { sourceId = "sports-1", key = "PLAY" }, M).errorCode,
  "VF_UNSUPPORTED"
)
eq(
  "a source whose controls the installer switched off",
  env.send("SOURCE_KEY", { sourceId = cfg.sources[3].id, key = "CH_UP" }, M).errorCode,
  "VF_UNSUPPORTED"
)
eq(
  "a channel that is not a number",
  env.send("SOURCE_TUNE", { sourceId = "sports-1", channel = "ESPN" }, M).errorCode,
  "VF_INVALID_PAYLOAD"
)
eq(
  "an unknown favourite",
  env.send("SOURCE_TUNE", { sourceId = "sports-1", favoriteId = "hbo" }, M).errorCode,
  "VF_NOT_FOUND"
)
local before = #core.sim.calls
drain()
eq("none of those sent anything", #core.sim.calls, before)

print("favourites")
local view = env.send("HELLO", {}, M).data.config.sources
local seen
for _, s in ipairs(view) do
  if s.id == "sports-1" then
    seen = s.controls
  end
end
check("the manager's screen is sent the controls", seen ~= nil)
eq("...the groups", table.concat(seen.groups, ","), "channel,keypad")
eq("...and both favourites", #seen.favorites, 2)
local text = H.JSON:encode(view)
check(
  "no Control4 id or command name reaches the page",
  not text:find("c4DeviceId", 1, true) and not text:find("PULSE_", 1, true)
)

core.sim.calls = {}
local tune = env.send("SOURCE_TUNE", { sourceId = "sports-1", favoriteId = "espn" }, M)
eq("a favourite is dialled", tune.ok, true)
eq("...as four keys", tune.data.sent, 4)
eq("the first key leaves at once", table.concat(calls(device), " "), "NUMBER_2")
env.clock.advance(200)
eq("the second waits its turn", #calls(device), 1)
drain()
eq("all four arrive in order", table.concat(calls(device), " "), "NUMBER_2 NUMBER_0 NUMBER_6 ENTER")
core.sim.calls = {}
env.send("SOURCE_TUNE", { sourceId = "sports-1", channel = "5-1" }, M)
env.send("SOURCE_KEY", { sourceId = "sports-1", key = "CH_UP" }, M)
drain()
eq(
  "a typed channel, then a key pressed meanwhile, keep their order",
  table.concat(calls(device), " "),
  "NUMBER_5 DASH NUMBER_1 ENTER PULSE_CHANNEL_UP"
)

print("when the box does not answer")
core.sim.calls = {}
env.send("SIM_FAULT", { targetId = device, fault = "offline" }, I)
local off = env.send("SOURCE_KEY", { sourceId = "sports-1", key = "CH_UP" }, M)
eq("the press is still accepted (there is no feedback to wait for)", off.ok, true)
drain()
local logged = false
for _, e in ipairs(env.send("DIAG_GET", { category = "source" }, I).data.entries or {}) do
  if e.code == "VF_DISPATCH_FAILED" then
    logged = true
  end
end
check("...and the failure is in the diagnostic log", logged)
env.send("SIM_FAULT", { targetId = device }, I)

print("a flood of keys")
local refusedAt
for i = 1, 80 do
  local r = env.send("SOURCE_KEY", { sourceId = "sports-1", key = "CH_UP" }, M)
  if not r.ok and refusedAt == nil then
    refusedAt = i
  end
end
check("the waiting list is bounded", refusedAt ~= nil and refusedAt <= 66, tostring(refusedAt))
drain()
drain()

print("schema")
local function issuesFor(mutate)
  local c = copy(env.send("DRAFT_GET", {}, I).data.draft.config)
  mutate(c)
  local codes = {}
  for _, i in ipairs(Schema.validate(Schema.normalize(c))) do
    codes[i.code .. "@" .. tostring(i.path)] = i.severity
  end
  return codes
end
local function has(codes, code)
  for k in pairs(codes) do
    if k:find(code, 1, true) == 1 then
      return true
    end
  end
  return false
end
check(
  "an unknown control group is an error",
  has(
    issuesFor(function(c)
      c.sources[1].controls = { "channel", "lasers" }
    end),
    "ENUM"
  )
)
check(
  "a favourite with a bad channel is an error",
  has(
    issuesFor(function(c)
      c.sources[1].favorites[1].channel = "ESPN"
    end),
    "CHANNEL_INVALID"
  )
)
check(
  "two favourites with one id is an error",
  has(
    issuesFor(function(c)
      c.sources[1].favorites[2].id = c.sources[1].favorites[1].id
    end),
    "ID_INVALID"
  )
)
check(
  "too many favourites is an error",
  has(
    issuesFor(function(c)
      for i = 1, 30 do
        c.sources[1].favorites[i] = { id = "f" .. i, name = "F" .. i, channel = tostring(i) }
      end
    end),
    "TOO_MANY"
  )
)
check(
  "favourites without a keypad is flagged",
  has(
    issuesFor(function(c)
      c.sources[1].controls = { "channel" }
    end),
    "FAVORITES_NO_KEYPAD"
  )
)
local fresh = Schema.normalize({
  sources = { { id = "a", name = "A", kind = "cable" }, { id = "b", name = "B", kind = "signage" } },
})
eq(
  "an older configuration's cable box gains its defaults",
  table.concat(fresh.sources[1].controls, ","),
  "channel,keypad"
)
eq("...and signage gains none", #fresh.sources[2].controls, 0)
eq("Enter after the digits is on by default", fresh.sources[1].tuneEnter, true)

print("the client and the installer")
local ccfg = copy(env.send("DRAFT_GET", {}, M).data.draft.config)
local crev = env.send("DRAFT_GET", {}, M).data.draft.revision
ccfg.sources[1].favorites[#ccfg.sources[1].favorites + 1] = { id = "news", name = "News", channel = "202" }
local csave = env.send("DRAFT_SAVE", { config = ccfg, baseRevision = crev }, M)
eq("a client adds a favourite channel", csave.ok, true)
ccfg.sources[1].controls = { "channel", "keypad", "navigation", "transport" }
local cbad = env.send("DRAFT_SAVE", { config = ccfg, baseRevision = csave.data.revision }, M)
eq("a client cannot change which controls a source has", cbad.errorCode, "VF_FORBIDDEN")
ccfg.sources[1].controls = { "channel", "keypad" }
ccfg.sources[1].tuneEnter = false
eq(
  "...or how a channel is dialled",
  env.send("DRAFT_SAVE", { config = ccfg, baseRevision = csave.data.revision }, M).errorCode,
  "VF_FORBIDDEN"
)

T.done()
