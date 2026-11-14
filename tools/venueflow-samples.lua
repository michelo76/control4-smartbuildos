#!/usr/bin/env luajit
--- Writes the VenueFlow reference configurations and the protocol description
--- as JSON files under docs/smartbuildos-venueflow, from the same Lua the
--- driver ships (templates.lua, protocol.lua), so the files cannot drift from
--- the code. Run from the repository root:
---
---   luajit tools/venueflow-samples.lua [--check]
---
--- The sample venues carry no PIN (the driver hashes PINs with a per-profile
--- salt when a sample is loaded in Simulation mode).

package.path = "src/?.lua;vendor/?.lua;test/?.lua;" .. package.path
tostring_return_period = tostring_return_period or tostring

local JSON = require("JSON")
local Templates = require("venueflow.templates")
local Protocol = require("venueflow.protocol")
local Schema = require("venueflow.schema")
local Rules = require("venueflow.rules")
local Errors = require("venueflow.errors")

local OUT = "docs/smartbuildos-venueflow"
local files = {
  [OUT .. "/samples/sports-bar.json"] = Templates.sportsBar(),
  [OUT .. "/samples/conference-center.json"] = Templates.conferenceCenter(),
  [OUT .. "/samples/blank-restaurant.json"] = Templates.venue("restaurant", "New Restaurant"),
  [OUT .. "/schema/protocol.json"] = {
    protocol = Protocol.VERSION,
    note = "Generated from src/venueflow/protocol.lua. Field kinds: s string, n number, b boolean, t object, l list of ids; a trailing ? means optional.",
    commands = Protocol.describe(),
  },
  [OUT .. "/schema/vocabulary.json"] = {
    schema = Schema.SCHEMA_VERSION,
    note = "Generated from src/venueflow/schema.lua, rules.lua and errors.lua: the enumerations and limits a configuration is validated against.",
    venueTypes = Schema.VENUE_TYPES,
    interfaces = Schema.INTERFACES,
    sourceKinds = Schema.SOURCE_KINDS,
    displayKinds = Schema.DISPLAY_KINDS,
    routeStrategies = Schema.ROUTE_STRATEGIES,
    powerStrategies = Schema.POWER_STRATEGIES,
    feedback = Schema.FEEDBACK,
    roles = Schema.ROLES,
    variableTypes = Schema.VARIABLE_TYPES,
    permissionFlags = Schema.PERMISSION_FLAGS,
    permissionScopes = Schema.PERMISSION_SCOPES,
    limits = Schema.LIMITS,
    stepTypes = Rules.STEP_TYPES,
    conditionOps = Rules.CONDITION_OPS,
    triggerTypes = Rules.TRIGGER_TYPES,
    comparators = Rules.COMPARATORS,
    maxSteps = Rules.MAX_STEPS,
    maxWaitSeconds = Rules.MAX_WAIT_SECONDS,
    maxNesting = Rules.MAX_NESTING,
    maxSceneDepth = Rules.MAX_DEPTH,
    errorCodes = (function()
      local out = {}
      for code, entry in pairs(Errors.CODES) do
        out[code] = entry.operator
      end
      return out
    end)(),
  },
}

local check = arg[1] == "--check"
local stale = {}
local names = {}
for path in pairs(files) do
  names[#names + 1] = path
end
table.sort(names)
for _, path in ipairs(names) do
  local text = JSON:encode_pretty(files[path]) .. "\n"
  local f = io.open(path, "rb")
  local current = f and f:read("*a") or nil
  if f then
    f:close()
  end
  if current ~= text then
    if check then
      stale[#stale + 1] = path
    else
      os.execute('mkdir -p "' .. path:match("^(.*)/[^/]+$") .. '"')
      local w = assert(io.open(path, "wb"))
      w:write(text)
      w:close()
      print("wrote " .. path)
    end
  end
end
if #stale > 0 then
  io.stderr:write("stale: " .. table.concat(stale, ", ") .. " -- run `luajit tools/venueflow-samples.lua`\n")
  os.exit(1)
end
