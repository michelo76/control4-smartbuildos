package.path = "src/?.lua;" .. package.path
local C = require("flightrecorder.config")
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
local function find(refusals, path)
  for _, r in ipairs(refusals or {}) do
    if r.path == path then
      return r
    end
  end
end

print("[1] a valid document normalises")
local cfg, ref = C.validate({
  version = 3,
  sources = {
    {
      kind = "device_variable",
      device_id = 12,
      variable = "LIGHT_LEVEL",
      label = "Kitchen lights",
      category = "lighting",
      debounce_ms = 1500,
      min_change = 1,
    },
    { kind = "room_variable", device_id = 5, variable = "POWER_STATE" },
    { kind = "sbos_event", event = "director_reloaded" },
  },
  budgets = { max_sources = 10, events_per_minute = 60 },
})
check("accepted", cfg ~= nil, ref and ref[1] and (ref[1].path .. ": " .. ref[1].reason))
check(
  "source ids",
  cfg.sources[1].id == "device_variable:12:LIGHTLEVEL" and cfg.sources[3].id == "sbos_event:0:DIRECTORRELOADED"
)
check("label defaults to the variable", cfg.sources[2].label == "POWER_STATE")
check("budgets kept", cfg.budgets.max_sources == 10 and cfg.budgets.events_per_minute == 60)

print("[2] refusals reject the whole document")
local bad, r2 = C.validate({
  version = 1,
  bogus = true,
  sources = {
    { kind = "device_variable", device_id = 1, variable = "USER_CODE" },
    { kind = "device_event", device_id = 1, variable = "X" },
    { kind = "device_variable", device_id = 1, variable = "A", debounce_ms = 99999 },
  },
  budgets = { max_sources = 9999 },
})
check("rejected", bad == nil)
check("unknown property named", find(r2, "bogus") ~= nil)
check("credential variable refused", find(r2, "sources[1].variable") ~= nil)
check(
  "device_event reserved",
  find(r2, "sources[2].kind") ~= nil and find(r2, "sources[2].kind").reason:find("reserved")
)
check("debounce bound", find(r2, "sources[3].debounce_ms") ~= nil)
check("max_sources ceiling", find(r2, "budgets.max_sources") ~= nil)
check("duplicate sources refused", select(
  2,
  C.validate({
    sources = {
      { kind = "device_variable", device_id = 1, variable = "A" },
      { kind = "device_variable", device_id = 1, variable = "a" },
    },
  })
)[1].reason:find("duplicate") ~= nil)
check("too many sources for the budget", find(
  select(
    2,
    C.validate({
      sources = {
        { kind = "device_variable", device_id = 1, variable = "A" },
        { kind = "device_variable", device_id = 2, variable = "A" },
      },
      budgets = { max_sources = 1 },
    })
  ),
  "sources"
) ~= nil)
check("schema version pinned", find(select(2, C.validate({ schema_version = 2 })), "schema_version") ~= nil)

print("[3] resolve: stale / unsupported / excluded / listeners")
local cfg3 = select(
  1,
  C.validate({
    sources = {
      { kind = "device_variable", device_id = 12, variable = "Light Level" },
      { kind = "device_variable", device_id = 13, variable = "LIGHT_LEVEL" },
      { kind = "device_variable", device_id = 14, variable = "LIGHT_LEVEL" },
      { kind = "device_variable", device_id = 12, variable = "SCENE_NAME" },
      { kind = "sbos_event", event = "clock_drift" },
    },
    exclusions = { variable_patterns = { "SCENE*" } },
  })
)
local plan = C.resolve(cfg3, function(id)
  if id == 12 then
    return { ["1001"] = { name = "LIGHT_LEVEL", value = "40" }, ["1002"] = { name = "SCENE_NAME", value = "x" } }
  end
  if id == 13 then
    return { ["1"] = { name = "OTHER", value = "" } }
  end
  return nil
end)
check(
  "name resolves case/underscore-insensitively to the id",
  #plan.listeners == 1 and plan.listeners[1].variable_id == 1001 and plan.listeners[1].value == "40"
)
check("missing variable → unsupported", #plan.unsupported == 1 and plan.unsupported[1].source.device_id == 13)
check("missing device → stale", #plan.stale == 1 and plan.stale[1].source.device_id == 14)
check("pattern exclusion", #plan.excluded == 1 and plan.excluded[1].reason == "pattern")
check("event source listed", #plan.events == 1 and plan.events[1].event == "clock_drift")
local s = C.summary(cfg3, plan)
check("summary", s.sources == 5 and s.listeners == 1 and s.stale == 1 and s.unsupported == 1 and s.excluded == 1)

print("[4] templates only offer what exists")
local cat = {
  {
    kind = "device_variable",
    device_id = 12,
    device_label = "Kitchen",
    room_id = 3,
    room_label = "Kitchen",
    variables = { "LIGHT_LEVEL", "LIGHT_STATE", "USER_CODE" },
  },
  { kind = "device_variable", device_id = 20, device_label = "Front door", variables = { "ContactState" } },
  { kind = "room_variable", device_id = 3, device_label = "Kitchen", variables = { "POWER_STATE" } },
}
local lighting = C.applyTemplate("lighting", cat)
check(
  "lighting picks the two light variables",
  #lighting == 2 and lighting[1].device_id == 12 and lighting[1].debounce_ms == 1500
)
check("contacts", #C.applyTemplate("contacts", cat) == 1)
check(
  "room media",
  #C.applyTemplate("room_media", cat) == 1 and C.applyTemplate("room_media", cat)[1].kind == "room_variable"
)
check("motion: none available → empty", #C.applyTemplate("motion", cat) == 0)
check("sbos events template", #C.applyTemplate("sbos_events", cat) == #C.SBOS_EVENTS)
check("unknown template", select(2, C.applyTemplate("nope", cat)) == "unknown template")
check(
  "fixed exclusion never templated",
  (function()
    for _, s in ipairs(lighting) do
      if s.variable == "USER_CODE" then
        return false
      end
    end
    return true
  end)()
)

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
