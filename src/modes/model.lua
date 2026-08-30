--- Mode Composer domain model: modes, categories, inheritance, validation.
---
--- Everything in here is pure — functions take the config table and return
--- values or mutate that table; no C4 calls, no persistence, no timers. That
--- is what lets the whole model run under the test shim, and it is why the
--- store (persistence) and engine (execution) live in separate modules.
---
--- Identity rules the rest of the product depends on:
---   * A mode's `id` is minted once and never changes. Every reference —
---     inheritance, keypad slots, triggers, history — uses the id, so rename
---     is always safe and duplicate always re-keys.
---   * Device ids are stored as STRINGS. The config envelope round-trips
---     through JSON (export/import, future cloud backup), and JSON object
---     keys are strings; storing numbers would silently fork the two shapes.
---   * Categories are strings, not booleans. PRESENCE and LIFESTYLE ship
---     today; a future category (SAFETY, ENERGY) is a new string plus its own
---     active slot — no schema change.

local M = {}

--- Local deep copy. Deliberately NOT the lib.utils global TableDeepCopy —
--- an implicit global dependency is the same trap urlDo already cost this
--- repo once; the model must load standalone under the shim.
local function deepcopy(value, seen)
  if type(value) ~= "table" then
    return value
  end
  seen = seen or {}
  if seen[value] then
    return seen[value]
  end
  local out = {}
  seen[value] = out
  for k, v in pairs(value) do
    out[deepcopy(k, seen)] = deepcopy(v, seen)
  end
  return out
end
M.deepcopy = deepcopy

--- Mode categories shipped in V1. `M.activeSlots` mirrors this: one active
--- mode per category, independently.
M.CATEGORIES = { PRESENCE = true, LIFESTYLE = true }

--- Device behaviors a mode entry may declare.
M.BEHAVIORS = { SET = true, IGNORE = true, RESTORE = true }

--- Action criticality: how a failure of this action affects the activation.
M.CRITICALITY = { OPTIONAL = true, NORMAL = true, CRITICAL = true }

--- Transition styles.
M.TRANSITIONS = { IMMEDIATE = true, GRACEFUL = true, SEQUENCED = true }

--- Template kinds. Kind is a HINT for icon/color suggestions and docs — no
--- engine logic may ever branch on it (spec §5: never hard-code around
--- English names). CUSTOM is the kind of every dealer-created mode.
M.KINDS = {
  HOME = { category = "PRESENCE", color = "22aa44", icon = "home", occupancy = "OCCUPIED" },
  AWAY = { category = "PRESENCE", color = "2266dd", icon = "away", occupancy = "UNOCCUPIED" },
  -- Vacation defaults to a higher priority than its siblings so a single
  -- sensor-driven Home rule cannot dethrone it without the dealer explicitly
  -- lowering it (spec §25, acceptance §131).
  VACATION = {
    category = "PRESENCE",
    color = "8844cc",
    icon = "vacation",
    confirm_hold_s = 3,
    priority = 60,
    occupancy = "UNOCCUPIED",
  },
  SLEEP = { category = "LIFESTYLE", color = "dd9922", icon = "moon" },
  MOVIE = { category = "LIFESTYLE", color = "223399", icon = "film" },
  PARTY = { category = "LIFESTYLE", color = "cc2288", icon = "party" },
  MORNING = { category = "LIFESTYLE", color = "eecc44", icon = "sunrise" },
  NIGHT = { category = "LIFESTYLE", color = "334466", icon = "night" },
  CUSTOM = { category = "LIFESTYLE", color = "888888", icon = "custom" },
}

--- Default priorities by category: presence outranks lifestyle so conflict
--- resolution has a sane floor before the dealer touches anything.
local DEFAULT_PRIORITY = { PRESENCE = 50, LIFESTYLE = 30 }

--- An empty configuration envelope. The store stamps configVersion; the
--- model only requires the containers to exist.
--- @return table
function M.emptyConfig()
  return {
    modes = {},
    order = {},
    groups = {},
    slots = {},
    settings = {},
  }
end

--- Mint a new mode. `spec.kind` picks template suggestions; nothing is
--- device-selected on creation (spec §66: defaults never control devices).
--- @param cfg table config envelope
--- @param spec table {name, kind?, category?, color?, icon?, priority?}
--- @param uuid function () -> string unique id source (C4:UUID in the driver)
--- @return table mode
function M.newMode(cfg, spec, uuid)
  local kind = spec.kind and M.KINDS[spec.kind] and spec.kind or "CUSTOM"
  local tpl = M.KINDS[kind]
  local category = spec.category or tpl.category
  assert(M.CATEGORIES[category], "unknown category: " .. tostring(category))
  local mode = {
    id = "m_" .. uuid(),
    name = spec.name or (kind:sub(1, 1) .. kind:sub(2):lower()),
    category = category,
    kind = kind,
    icon = spec.icon or tpl.icon,
    color = spec.color or tpl.color,
    priority = spec.priority or tpl.priority or DEFAULT_PRIORITY[category],
    enabled = true,
    parent_mode = nil,
    desired_states = {},
    groups = {},
    triggers = {},
    transition = { style = "IMMEDIATE", countdown_s = 0, sequence = {} },
    keypad_color_inherit = true,
    confirm_hold_s = tpl.confirm_hold_s or 0,
    occupancy = tpl.occupancy, -- PRESENCE only; nil = UNKNOWN
    duration_s = 0,
    metadata = {},
  }
  cfg.modes[mode.id] = mode
  table.insert(cfg.order, mode.id)
  return mode
end

--- Duplicate a mode under a fresh id. References (slots, triggers, children)
--- keep pointing at the ORIGINAL — a copy must never steal them (spec §71).
--- @return table copy
function M.duplicateMode(cfg, modeId, uuid)
  local src = cfg.modes[modeId]
  if not src then
    return nil, "unknown mode: " .. tostring(modeId)
  end
  local copy = deepcopy(src)
  copy.id = "m_" .. uuid()
  copy.name = src.name .. " Copy"
  cfg.modes[copy.id] = copy
  table.insert(cfg.order, copy.id)
  return copy
end

--- Delete a mode. Children re-parent to the deleted mode's own parent so
--- their inherited behavior degrades gracefully instead of dangling; slot and
--- trigger references are left for validate() to flag — silent deletion of
--- dealer configuration is exactly what §73 forbids.
--- @return table affected {children={ids}, slots={keys}}
function M.deleteMode(cfg, modeId)
  local mode = cfg.modes[modeId]
  if not mode then
    return nil, "unknown mode: " .. tostring(modeId)
  end
  local affected = { children = {}, slots = {} }
  for id, m in pairs(cfg.modes) do
    if m.parent_mode == modeId then
      m.parent_mode = mode.parent_mode
      table.insert(affected.children, id)
    end
  end
  for key, slot in pairs(cfg.slots or {}) do
    for _, g in pairs(slot.gestures or {}) do
      if g.mode_id == modeId then
        table.insert(affected.slots, key)
      end
    end
  end
  cfg.modes[modeId] = nil
  for i, id in ipairs(cfg.order) do
    if id == modeId then
      table.remove(cfg.order, i)
      break
    end
  end
  return affected
end

--- Set (or clear, with nil) a mode's parent. Refuses cycles and cross-category
--- inheritance at WRITE time — a cycle must never be reachable at activation.
--- @return boolean ok, string? err
function M.setParent(cfg, modeId, parentId)
  local mode = cfg.modes[modeId]
  if not mode then
    return false, "unknown mode: " .. tostring(modeId)
  end
  if parentId == nil then
    mode.parent_mode = nil
    return true
  end
  local parent = cfg.modes[parentId]
  if not parent then
    return false, "unknown parent mode: " .. tostring(parentId)
  end
  if parent.category ~= mode.category then
    return false,
      string.format(
        "%s is %s but %s is %s — modes inherit only within a category",
        mode.name,
        mode.category,
        parent.name,
        parent.category
      )
  end
  -- Walk up from the proposed parent; hitting ourselves means a cycle.
  local seen, cursor = {}, parentId
  while cursor do
    if cursor == modeId then
      return false, string.format("inheritance cycle: %s already inherits from %s", parent.name, mode.name)
    end
    if seen[cursor] then
      break -- pre-existing cycle elsewhere; validate() reports it
    end
    seen[cursor] = true
    local up = cfg.modes[cursor]
    cursor = up and up.parent_mode or nil
  end
  mode.parent_mode = parentId
  return true
end

--- Resolve a mode's inheritance chain, root first, child last.
--- @return table? chain, string? err (err set on cycle or dangling parent)
function M.resolveChain(cfg, modeId)
  local chain, seen = {}, {}
  local cursor = modeId
  while cursor do
    if seen[cursor] then
      return nil, "inheritance cycle at " .. tostring(cursor)
    end
    seen[cursor] = true
    local mode = cfg.modes[cursor]
    if not mode then
      return nil, "dangling parent reference: " .. tostring(cursor)
    end
    table.insert(chain, 1, mode)
    cursor = mode.parent_mode
  end
  return chain
end

--- Compute a mode's EFFECTIVE desired states: parent entries first, child
--- entries override per device. Group targets expand before device-level
--- entries so an explicit device entry always wins over its group (spec §10).
--- Returns `{ [deviceKey] = entry }` plus `sources[deviceKey] = modeId` for
--- diagnostics ("where did this state come from").
--- @return table? states, table|string sourcesOrErr
function M.effectiveStates(cfg, modeId)
  local chain, err = M.resolveChain(cfg, modeId)
  if not chain then
    return nil, err
  end
  local states, sources = {}, {}
  for _, mode in ipairs(chain) do
    for _, gref in ipairs(mode.groups or {}) do
      local group = (cfg.groups or {})[gref.group_id]
      if group then
        for _, deviceKey in ipairs(group.devices or {}) do
          states[deviceKey] = {
            behavior = gref.behavior or "SET",
            state = gref.state,
            delay_s = gref.delay_s or 0,
            criticality = gref.criticality or "NORMAL",
            via_group = gref.group_id,
          }
          sources[deviceKey] = mode.id
        end
      end
    end
    for deviceKey, entry in pairs(mode.desired_states or {}) do
      states[deviceKey] = entry
      sources[deviceKey] = mode.id
    end
  end
  return states, sources
end

--- Effective transition/confirm settings: nearest definition in the chain
--- wins (child overrides parent), falling back to the defaults newMode set.
function M.effectiveTransition(cfg, modeId)
  local chain = M.resolveChain(cfg, modeId)
  if not chain then
    return { style = "IMMEDIATE", countdown_s = 0, sequence = {} }
  end
  local t = { style = "IMMEDIATE", countdown_s = 0, sequence = {} }
  for _, mode in ipairs(chain) do
    local mt = mode.transition or {}
    if mt.style then
      t.style = mt.style
    end
    if mt.countdown_s and mt.countdown_s > 0 then
      t.countdown_s = mt.countdown_s
    end
    if mt.sequence and #mt.sequence > 0 then
      t.sequence = mt.sequence
    end
  end
  return t
end

--- Reorder: move a mode to a 1-based position in cfg.order.
function M.reorder(cfg, modeId, position)
  for i, id in ipairs(cfg.order) do
    if id == modeId then
      table.remove(cfg.order, i)
      table.insert(cfg.order, math.max(1, math.min(position, #cfg.order + 1)), modeId)
      return true
    end
  end
  return false, "unknown mode: " .. tostring(modeId)
end

--- Modes in display order, tolerating an order list that drifted (a mode in
--- the map but absent from order still lists, at the end).
function M.orderedModes(cfg, category)
  local out, seen = {}, {}
  for _, id in ipairs(cfg.order or {}) do
    local mode = cfg.modes[id]
    if mode and (category == nil or mode.category == category) then
      table.insert(out, mode)
      seen[id] = true
    end
  end
  for id, mode in pairs(cfg.modes) do
    if not seen[id] and (category == nil or mode.category == category) then
      table.insert(out, mode)
    end
  end
  return out
end

--- Find a mode by display name (exact, then case-insensitive). For dealer
--- commands only — engine logic references ids.
function M.findByName(cfg, name)
  for _, mode in pairs(cfg.modes) do
    if mode.name == name then
      return mode
    end
  end
  local lower = tostring(name):lower()
  for _, mode in pairs(cfg.modes) do
    if tostring(mode.name):lower() == lower then
      return mode
    end
  end
  return nil
end

--- Validate the whole configuration. Returns a list of findings, each
--- `{level="ERROR"|"WARNING", code, message}` with messages written for a
--- dealer, naming the mode/slot involved (spec §72: never bare "Invalid
--- configuration"). An empty list means saveable.
function M.validate(cfg)
  local findings = {}
  local function add(level, code, fmt, ...)
    table.insert(findings, { level = level, code = code, message = string.format(fmt, ...) })
  end

  for id, mode in pairs(cfg.modes or {}) do
    if mode.id ~= id then
      add(
        "ERROR",
        "id-mismatch",
        "Mode '%s' is stored under key %s but carries id %s",
        mode.name,
        id,
        tostring(mode.id)
      )
    end
    if not M.CATEGORIES[mode.category or ""] then
      add("ERROR", "bad-category", "Mode '%s' has unknown category '%s'", mode.name, tostring(mode.category))
    end
    if mode.parent_mode then
      local _, err = M.resolveChain(cfg, id)
      if err then
        add("ERROR", "inheritance", "Mode '%s': %s", mode.name, err)
      end
    end
    for deviceKey, entry in pairs(mode.desired_states or {}) do
      if not M.BEHAVIORS[entry.behavior or ""] then
        add(
          "ERROR",
          "bad-behavior",
          "Mode '%s', device %s: behavior '%s' is not SET/IGNORE/RESTORE",
          mode.name,
          deviceKey,
          tostring(entry.behavior)
        )
      end
      if entry.criticality and not M.CRITICALITY[entry.criticality] then
        add(
          "ERROR",
          "bad-criticality",
          "Mode '%s', device %s: criticality '%s' is not OPTIONAL/NORMAL/CRITICAL",
          mode.name,
          deviceKey,
          tostring(entry.criticality)
        )
      end
    end
    for _, gref in ipairs(mode.groups or {}) do
      if not (cfg.groups or {})[gref.group_id] then
        add(
          "WARNING",
          "missing-group",
          "Mode '%s' targets group %s which no longer exists",
          mode.name,
          tostring(gref.group_id)
        )
      end
    end
    if mode.transition and mode.transition.style and not M.TRANSITIONS[mode.transition.style] then
      add(
        "ERROR",
        "bad-transition",
        "Mode '%s': transition style '%s' is not IMMEDIATE/GRACEFUL/SEQUENCED",
        mode.name,
        tostring(mode.transition.style)
      )
    end
  end

  local nameSeen = {}
  for _, mode in pairs(cfg.modes or {}) do
    local key = (mode.category or "?") .. "\0" .. tostring(mode.name):lower()
    if nameSeen[key] then
      add(
        "WARNING",
        "duplicate-name",
        "Two %s modes are both named '%s' — rename one to avoid ambiguity",
        mode.category,
        mode.name
      )
    end
    nameSeen[key] = true
  end

  for slotKey, slot in pairs(cfg.slots or {}) do
    for gesture, g in pairs(slot.gestures or {}) do
      if g.mode_id and not (cfg.modes or {})[g.mode_id] then
        add(
          "WARNING",
          "orphaned-slot",
          "Keypad slot '%s', gesture %s points at a deleted mode — reassign or clear it",
          slot.name or slotKey,
          gesture
        )
      end
    end
    if slot.led and slot.led.follow == "MODE" and slot.led.mode_id and not (cfg.modes or {})[slot.led.mode_id] then
      add("WARNING", "orphaned-led", "Keypad slot '%s' LED follows a deleted mode", slot.name or slotKey)
    end
  end

  return findings
end

--- True when validate() found no ERROR-level findings.
function M.isSaveable(findings)
  for _, f in ipairs(findings) do
    if f.level == "ERROR" then
      return false
    end
  end
  return true
end

return M
