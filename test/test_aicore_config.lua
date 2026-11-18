-- aicore.config (pure): whole-document validation, defaults, strict keys,
-- credentials refused anywhere, display strings bounded, collection policy.
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
  "{} = defaults",
  empty ~= nil
    and empty.learning.active == true
    and empty.permission_mode == nil
    and empty.collection.system_events == true
)
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

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
