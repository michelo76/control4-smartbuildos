--- VenueFlow: what a venue's own people may change in the Studio (pure).
---
--- The Studio has two kinds of session. An installer session (the Installer
--- Passcode) may change anything. A client session is a staff profile that
--- signed in with its PIN and holds the `studio` permission: the owner or a
--- manager looking after the venue day to day.
---
--- A client may change:
---   scenes                      all of them
---   schedules                   rules whose trigger is a schedule
---   staff profiles and PINs     everything except who holds `studio`
---   sources                     the name, the channel label, the favourite channels
---   audio zones                 the volume presets
---
--- Everything else is the installer's: devices, rooms, displays, routing,
--- the floor layout, groups, lighting, shades, stations, variables, rules
--- with any other trigger, the venue record and the default profile.
---
--- The check does not trust a page. `locked(config)` is the configuration
--- with every client-owned part removed; a client's change is allowed when
--- the locked view is the same before and after.

local U = require("venueflow.util")

local M = {}

--- Source fields a client may edit.
M.SOURCE_FIELDS = { "name", "channel", "favorites" }

--- For the Studio page and the documents: the same list in words.
M.MAY_CHANGE = {
  "Scenes",
  "Schedules",
  "Staff profiles and PINs",
  "Source names, channel labels and favourite channels",
  "Volume presets",
}

function M.isSchedule(rule)
  return type(rule) == "table" and type(rule.trigger) == "table" and rule.trigger.type == "schedule"
end

--- Does this profile hold the Venue Studio permission?
function M.holds(profile)
  return type(profile) == "table" and type(profile.permissions) == "table" and profile.permissions.studio == true
end

--- The installer-owned part of a configuration (a copy; `config` is untouched).
function M.locked(config)
  local c = U.copy(type(config) == "table" and config or {})
  c.scenes = nil
  local rules = {}
  for _, rule in ipairs(U.list(c.rules)) do
    if not M.isSchedule(rule) then
      rules[#rules + 1] = rule
    end
  end
  c.rules = rules
  -- Profiles are the client's, except the one permission that opens the
  -- Studio: who holds it must not change.
  local holders = {}
  for _, profile in ipairs(U.list(c.profiles)) do
    if M.holds(profile) then
      holders[#holders + 1] = tostring(profile.id)
    end
  end
  table.sort(holders)
  c.profiles = holders
  for _, source in ipairs(U.list(c.sources)) do
    if type(source) == "table" then
      for _, field in ipairs(M.SOURCE_FIELDS) do
        source[field] = nil
      end
    end
  end
  for _, zone in ipairs(U.list(c.audioZones)) do
    if type(zone) == "table" then
      zone.presets = nil
    end
  end
  return c
end

local LABELS = {
  rules = "a rule that is not a schedule",
  profiles = "who may open the Venue Studio",
  sources = "a source's device or type",
  audioZones = "an audio zone's device or limits",
  defaultProfileId = "the profile a screen opens with",
  venue = "the venue record",
}

--- nil when `after` differs from `before` only in what a client may change;
--- otherwise the key of the first installer-owned part that differs and a
--- phrase for it.
function M.changed(before, after)
  local a, b = M.locked(before), M.locked(after)
  local keys, seen = {}, {}
  for _, t in ipairs({ a, b }) do
    for k in pairs(t) do
      if not seen[k] then
        seen[k] = true
        keys[#keys + 1] = tostring(k)
      end
    end
  end
  table.sort(keys)
  for _, k in ipairs(keys) do
    if not U.equal(a[k], b[k]) then
      return k, LABELS[k] or k
    end
  end
  return nil
end

return M
