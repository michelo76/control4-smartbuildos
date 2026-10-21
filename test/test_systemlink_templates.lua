-- System Link templates: every recipe's items validate, the catalogue is
-- the TypeScript reference's seven, the printed steps name the dealer's
-- deliberate actions (exports, companions) and never claim to do them.
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

package.path = "./src/?.lua;./src/?/init.lua;./vendor/?.lua;" .. package.path
local schema = require("systemlink.schema")
local templates = require("systemlink.templates")

print("\n[1] catalogue")
local ids = {}
for _, t in ipairs(templates.TEMPLATES) do
  ids[#ids + 1] = t.id
end
check(
  "the seven recipes of the reference, in order",
  table.concat(ids, ",") == "away-home,guesthouse-occupancy,remote-light,remote-thermostat,arrival-request,readonly-sensors,gate-request",
  table.concat(ids, ",")
)
check("find by id", templates.find("gate-request") ~= nil and templates.find("nope") == nil)
check("a list label resolves back to its template", templates.fromLabel("away-home — Away / Home coordination").id == "away-home")
check("labels are id — title", templates.labels()[1] == "away-home — Away / Home coordination", templates.labels()[1])

print("\n[2] every owner item validates as a definition")
for _, t in ipairs(templates.TEMPLATES) do
  for _, def in ipairs(templates.ownerDefinitions(t)) do
    def.id, def.owner = "x", "ep"
    local ok, err = schema.validateDefinition(def)
    check(t.id .. ": " .. def.name .. " validates", ok, err)
  end
end
local away = templates.ownerDefinitions(templates.find("away-home"))
check("filters and choices are carried", away[1].filter.debounce_s == 5 and #away[2].allowed_values == 3)
check("a fresh table per call", templates.ownerDefinitions(templates.find("away-home"))[1] ~= away[1])
check("gate feedback carries its freshness policy", templates.ownerDefinitions(templates.find("gate-request"))[1].freshness.max_age_s == 120)

print("\n[3] the printed steps")
local lines = templates.describe(templates.find("gate-request"), "Beta", { "Beta.Gate_Open" }, {})
local joined = table.concat(lines, "\n")
check("sensitive recipes say so", joined:find("enable on purpose") ~= nil)
check("exports are named as the dealer's own action, never automatic", joined:find("Export to make here %(never automatic%): relay as Gate_Relay, Control allowed") ~= nil)
check("<Owner> is replaced by this bridge's prefix", joined:find("Beta%.Gate_Open changed") ~= nil and joined:find("<Owner>") == nil)
check("created items are listed", joined:find("Created on this bridge: Beta.Gate_Open") ~= nil)

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
