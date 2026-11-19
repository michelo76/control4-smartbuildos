-- aicore.config (pure): whole-document validation, defaults, strict keys,
-- credentials refused anywhere, display strings bounded, collection policy,
-- the touchscreen presets (round two).
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

local Config = require("aicore.config")

local function copy(t)
  if type(t) ~= "table" then
    return t
  end
  local o = {}
  for k, v in pairs(t) do
    o[k] = copy(v)
  end
  return o
end

local good = {
  schema = 1,
  learning = { active = false },
  exclusions = { rooms = { 9, 12 }, categories = { "security", "presence" } },
  permission_mode = "execute_low_risk",
  provider = { name = "OpenAI", model = "gpt-5" },
  credential_status = "Configured in System Studio · OpenAI ••••wxyz",
  collection = {
    system_events = false,
    flight_recorder_topics = true,
    agent_events = true,
    variables = { { device_id = 12, variable = "LIGHT_STATE" } },
    max_events_per_minute = 120,
  },
  property_id = "8f0c-prop",
  controller_id = "ctrl:0001",
}

print("[1] a valid document")
local cfg, refusals = Config.validate(good)
check("accepted", cfg ~= nil, refusals and Config.describeRefusals(refusals))
check(
  "values carried",
  cfg.learning.active == false and cfg.permission_mode == "execute_low_risk" and cfg.provider.model == "gpt-5"
)
check(
  "collection carried",
  cfg.collection.system_events == false
    and cfg.collection.max_events_per_minute == 120
    and #cfg.collection.variables == 1
)
check("sets", Config.excludedRoomSet(cfg)[12] and Config.excludedCategorySet(cfg).presence)
local empty = Config.validate({})
check(
  "{} = the conservative defaults: learning OFF, every collection source off",
  empty ~= nil
    and empty.learning.active == false
    and empty.permission_mode == nil
    and empty.collection.system_events == false
    and empty.collection.flight_recorder_topics == false
    and empty.collection.agent_events == false
    and empty.collection.max_events_per_minute == 60
    and #empty.exclusions.rooms == 0
    and #empty.exclusions.categories == 0
    and empty.provider.name == nil
    and empty.provider.model == nil
    and empty.credential_status == nil
    and empty.property_id == nil
    and empty.controller_id == nil
)
check("Config.default() is the same document", Config.default().learning.active == false)
local on = Config.validate({ learning = { active = true } })
check("learning on only when a document says so", on ~= nil and on.learning.active == true)
check("a document that only switches learning on collects nothing extra", on.collection.system_events == false)
local off = Config.validate({ learning = { active = false } })
check("explicit learning off", off ~= nil and off.learning.active == false)
check("learning without active → refused", Config.validate({ learning = {} }) == nil)
check("default: nothing listened to by variable", #empty.collection.variables == 0)

print("[2] whole-document refusal")
local function refused(mutate, pathPattern)
  local doc = copy(good)
  mutate(doc)
  local c, r = Config.validate(doc)
  local hit = false
  for _, x in ipairs(r or {}) do
    if x.path:find(pathPattern) then
      hit = true
    end
  end
  return c == nil and hit, r and Config.describeRefusals(r)
end
check(
  "an unknown top-level key",
  refused(function(d)
    d.retention_days = 3
  end, "retention_days")
)
check(
  "an unknown nested key",
  refused(function(d)
    d.collection.extra = true
  end, "collection.extra")
)
check(
  "schema 2",
  refused(function(d)
    d.schema = 2
  end, "schema")
)
check(
  "learning.active not boolean",
  refused(function(d)
    d.learning.active = "yes"
  end, "learning.active")
)
check(
  "permission mode outside the closed list",
  refused(function(d)
    d.permission_mode = "god_mode"
  end, "permission_mode")
)
check(
  "a room id that is not one",
  refused(function(d)
    d.exclusions.rooms = { "kitchen" }
  end, "exclusions.rooms")
)
check(
  "an unknown category",
  refused(function(d)
    d.exclusions.categories = { "secrets" }
  end, "exclusions.categories")
)
check(
  "max events per minute over 300",
  refused(function(d)
    d.collection.max_events_per_minute = 301
  end, "max_events_per_minute")
)
check(
  "more than 32 variables",
  refused(function(d)
    d.collection.variables = {}
    for i = 1, 33 do
      d.collection.variables[i] = { device_id = i, variable = "V" }
    end
  end, "collection.variables")
)
check(
  "a code-named variable is never collected",
  refused(function(d)
    d.collection.variables = { { device_id = 30, variable = "USER_CODE" } }
  end, "variable")
)
check(
  "property id must be an identifier",
  refused(function(d)
    d.property_id = "../../etc"
  end, "property_id")
)
check("not an object", Config.validate({ 1, 2, 3 }) == nil and Config.validate("x") == nil)
local ok1, msg = refused(function(d)
  d.permission_mode = "x"
  d.schema = 9
end, "schema")
check("one bad field refuses ALL of it (nothing partially applied)", ok1, msg)

print("[3] credentials never reach the controller")
check(
  "api_key anywhere → refused",
  refused(function(d)
    d.provider.api_key = "sk-ant-0123456789"
  end, "api_key")
)
check(
  "a nested secret key",
  refused(function(d)
    d.collection.token = "x"
  end, "token")
)
local withKey = copy(good)
withKey.provider.api_key = "sk-ant-0123456789"
local _, keyRefusals = Config.validate(withKey)
local said = false
for _, r in ipairs(keyRefusals or {}) do
  said = said or (r.path == "provider.api_key" and r.reason:find("keys stay in System Studio") ~= nil)
end
check("the refusal says why: a key never belongs on the controller (not just 'unknown key')", said)
check(
  "a key-shaped credential status",
  refused(function(d)
    d.credential_status = "sk-proj-abcdefghijklmnop"
  end, "credential_status")
)
check(
  "a long opaque blob as a model name",
  refused(function(d)
    d.provider.model = string.rep("A1b2", 12)
  end, "provider.model")
)
check(
  "a bearer string",
  refused(function(d)
    d.credential_status = "Bearer abc"
  end, "credential_status")
)
check(
  "credential_status over 96 characters",
  refused(function(d)
    d.credential_status = string.rep("x ", 49)
  end, "credential_status")
)
check("the masked status string itself is fine", Config.validate({ credential_status = "Not configured" }) ~= nil)

print("[bounds] excluded rooms: the platform's bound, exactly")
local rooms = {}
for i = 1, 500 do
  rooms[i] = 2147483647 - i
end
check(
  "500 room ids (the platform's SETTINGS_LIMITS.excludedRooms) are accepted",
  Config.validate({ exclusions = { rooms = rooms } }) ~= nil
)
rooms[501] = 1
check("501 are refused", Config.validate({ exclusions = { rooms = rooms } }) == nil)

print("[presets] touchscreen.presets (round two, D-R2b): whole-document refusal")
local PRESETS = {
  "Is the wine cellar at the right temperature?",
  "Are all the shades closed?",
}
do
  local doc = copy(good)
  doc.touchscreen = { presets = copy(PRESETS) }
  local c, r = Config.validate(doc)
  check("two valid presets: accepted", c ~= nil, r and Config.describeRefusals(r))
  check(
    "carried exactly, in order",
    c ~= nil and #c.touchscreen.presets == 2 and c.touchscreen.presets[1] == PRESETS[1] and c.touchscreen.presets[2] == PRESETS[2]
  )
  local old = Config.validate(copy(good))
  check(
    "a document WITHOUT the key (an older platform, or no presets): accepted exactly as before, no presets",
    old ~= nil and #old.touchscreen.presets == 0 and old.learning.active == false and old.provider.model == "gpt-5"
  )
  check("{} = no presets", #Config.validate({}).touchscreen.presets == 0)
  check("touchscreen {} = no presets", #Config.validate({ touchscreen = {} }).touchscreen.presets == 0)
  check("presets [] = no presets", #Config.validate({ touchscreen = { presets = {} } }).touchscreen.presets == 0)
  local six = {}
  for i = 1, 6 do
    six[i] = "Preset question number " .. i
  end
  check("6 presets (the bound): accepted", Config.validate({ touchscreen = { presets = six } }) ~= nil)
  check("3 characters: accepted", Config.validate({ touchscreen = { presets = { "Hi?" } } }) ~= nil)
  check("120 characters: accepted", Config.validate({ touchscreen = { presets = { string.rep("a", 119) .. "?" } } }) ~= nil)
  check(
    "120 non-ASCII characters (240 bytes): accepted (characters, not bytes)",
    Config.validate({ touchscreen = { presets = { string.rep("é", 120) } } }) ~= nil
  )
end
local function presetRefused(list, pathPattern)
  return refused(function(d)
    d.touchscreen = { presets = list }
  end, pathPattern or "touchscreen")
end
do
  local seven = {}
  for i = 1, 7 do
    seven[i] = "Preset question number " .. i
  end
  check("7 presets: the whole document refused", presetRefused(seven, "touchscreen.presets"))
end
check("2 characters: refused", presetRefused({ "Hi" }, "presets%[1%]"))
check("121 characters: refused", presetRefused({ string.rep("a", 121) }, "presets%[1%]"))
check(
  "over 360 bytes though within 120 characters (91 four-byte characters): refused",
  presetRefused({ string.rep("\240\159\152\128", 91) }, "presets%[1%]")
)
check("a newline (control character): refused", presetRefused({ "Is it\nwarm?" }, "presets%[1%]"))
check("a tab: refused", presetRefused({ "Is it\twarm?" }, "presets%[1%]"))
check("a C1 control: refused", presetRefused({ "Is it\194\133warm?" }, "presets%[1%]"))
check("a bidi override: refused", presetRefused({ "\226\128\174Is it warm?" }, "presets%[1%]"))
check("a line separator: refused", presetRefused({ "Is it\226\128\168warm?" }, "presets%[1%]"))
check("markup: refused", presetRefused({ "<b>Is it warm?</b>" }, "presets%[1%]"))
check("a lone > : refused", presetRefused({ "Temperature > 70?" }, "presets%[1%]"))
check("a link: refused", presetRefused({ "Open https://example.com now" }, "presets%[1%]"))
check("www.: refused", presetRefused({ "See www.example.com" }, "presets%[1%]"))
check("credential-shaped (an sk- key): refused", presetRefused({ "sk-proj-abcdefghijklmnop" }, "presets%[1%]"))
check("credential-shaped (a long opaque blob): refused", presetRefused({ string.rep("A1b2", 12) }, "presets%[1%]"))
check("credential-shaped (a bearer string): refused", presetRefused({ "Bearer abcdefgh" }, "presets%[1%]"))
check("a leading space: refused", presetRefused({ " Is it warm?" }, "presets%[1%]"))
check("a trailing space: refused", presetRefused({ "Is it warm? " }, "presets%[1%]"))
check("the same question twice (case and spacing): refused", presetRefused({ "Is it warm?", "is  IT warm?" }, "presets%[2%]"))
check("a number, not text: refused", presetRefused({ 42 }, "presets%[1%]"))
check("presets an object, not a list: refused", presetRefused({ a = "Is it warm?" }, "touchscreen.presets"))
check(
  "an unknown key under touchscreen: refused",
  refused(function(d)
    d.touchscreen = { presets = {}, rooms = {} }
  end, "touchscreen.rooms")
)
check(
  "touchscreen a list, not an object: refused",
  refused(function(d)
    d.touchscreen = { "Is it warm?" }
  end, "touchscreen")
)
do
  local doc = copy(good)
  doc.learning = { active = true }
  doc.touchscreen = { presets = { "Fine question?", "Bad\nquestion" } }
  local c, r = Config.validate(doc)
  check("one bad preset among good ones: the WHOLE document refused (learning=true not taken)", c == nil and #r >= 1)
end

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
