--- VenueFlow: the visual programming engine (pure).
---
--- A PROGRAM is data, never code: a list of steps drawn from a fixed
--- vocabulary. Nothing an installer types is ever evaluated as Lua or
--- JavaScript; an unknown step type is refused by validation and skipped by
--- the runner.
---
---   program   = { steps = { step, ... } }
---   step      = { type = "route_video", sourceId, target }        and so on
---   condition = { op = "and", items = {...} } | { op = "venue_status", is = "open" } ...
---   trigger   = { type = "schedule", days = {1..7}, time = "HH:MM" } ...
---
--- The runner executes a program through an `ops` table supplied by the core
--- (the same engines the operator screens use), so a scene can do nothing a
--- screen could not. A DRY RUN passes `dry = true` down to those engines,
--- which validate and plan but never reach the Control4 adapter.

local U = require("venueflow.util")

local M = {}

M.MAX_DEPTH = 4
M.MAX_STEPS = 60
M.MAX_WAIT_SECONDS = 600
M.MAX_NESTING = 4

M.STEP_TYPES = {
  "display_power",
  "route_video",
  "route_audio",
  "volume",
  "mute",
  "zone_power",
  "lighting",
  "shade",
  "wait",
  "run_scene",
  "set_variable",
  "set_venue_status",
  "notify",
  "if",
}
M.CONDITION_OPS = {
  "and",
  "or",
  "not",
  "bool",
  "venue_status",
  "time_range",
  "day_of_week",
  "display_state",
  "zone_state",
  "source_available",
  "variable",
  "c4_variable",
  "context_area",
}
M.TRIGGER_TYPES = {
  "manual",
  "scene_activated",
  "schedule",
  "c4_event",
  "external",
  "device_state",
  "c4_variable",
  "venue_status",
}
M.COMPARATORS = { "eq", "ne", "gt", "lt", "ge", "le" }

local function set(list)
  local s = {}
  for _, v in ipairs(list) do
    s[v] = true
  end
  return s
end

local STEP_SET = set(M.STEP_TYPES)
local COND_SET = set(M.CONDITION_OPS)
local TRIGGER_SET = set(M.TRIGGER_TYPES)
local CMP_SET = set(M.COMPARATORS)

local function issue(issues, severity, code, path, message, entity)
  issues[#issues + 1] =
    { id = code .. ":" .. path, severity = severity, code = code, path = path, message = message, entity = entity }
end

-- ─── Targets ────────────────────────────────────────────────────────────────

--- target = { all = true } | { displayIds = {}, groupIds = {}, areaIds = {} }
--- Returns the display ids, in configuration order, without duplicates.
function M.resolveTarget(target, config, ix)
  local wanted = {}
  if type(target) ~= "table" then
    return {}
  end
  if target.all == true then
    local out = {}
    for _, d in ipairs(config.displays or {}) do
      out[#out + 1] = d.id
    end
    return out
  end
  for _, id in ipairs(U.list(target.displayIds)) do
    wanted[id] = true
  end
  for _, gid in ipairs(U.list(target.groupIds)) do
    local g = ix.groups[gid]
    for _, id in ipairs(g and U.list(g.displayIds) or {}) do
      wanted[id] = true
    end
  end
  local areaSet = {}
  for _, aid in ipairs(U.list(target.areaIds)) do
    areaSet[aid] = true
  end
  local out = {}
  for _, d in ipairs(config.displays or {}) do
    if wanted[d.id] or (d.areaId ~= nil and areaSet[d.areaId]) then
      out[#out + 1] = d.id
    end
  end
  return out
end

local function targetEmpty(target)
  if type(target) ~= "table" then
    return true
  end
  if target.all == true then
    return false
  end
  return #U.list(target.displayIds) == 0 and #U.list(target.groupIds) == 0 and #U.list(target.areaIds) == 0
end

local function validateTarget(target, ix, path, issues, entity)
  if type(target) ~= "table" then
    issue(issues, "warning", "STEP_INCOMPLETE", path, "This step has no displays chosen yet.", entity)
    return
  end
  if target.all == true then
    return
  end
  local function refs(field, index, kind)
    local list = target[field]
    if list == nil then
      return
    end
    if not U.isList(list) then
      issue(issues, "error", "NOT_A_LIST", path .. "." .. field, "Must be a list.", entity)
      return
    end
    for i, id in ipairs(list) do
      if index[id] == nil then
        issue(
          issues,
          "error",
          "REF_UNKNOWN",
          string.format("%s.%s[%d]", path, field, i),
          "Refers to a " .. kind .. " that does not exist.",
          entity
        )
      end
    end
  end
  refs("displayIds", ix.displays, "display")
  refs("groupIds", ix.groups, "display group")
  refs("areaIds", ix.areas, "area")
  if targetEmpty(target) then
    issue(issues, "warning", "STEP_INCOMPLETE", path, "This step has no displays chosen yet.", entity)
  end
end

-- ─── Validation ─────────────────────────────────────────────────────────────

local function needRef(value, index, kind, path, issues, entity, what)
  if value == nil or value == "" then
    issue(issues, "warning", "STEP_INCOMPLETE", path, what .. " is not chosen yet.", entity)
    return false
  end
  if index[value] == nil then
    issue(issues, "error", "REF_UNKNOWN", path, what .. " refers to a " .. kind .. " that does not exist.", entity)
    return false
  end
  return true
end

function M.validateCondition(cond, ix, path, issues, entity, depth)
  depth = depth or 1
  if type(cond) ~= "table" or not COND_SET[cond.op] then
    issue(issues, "error", "CONDITION_UNKNOWN", path, "Unknown condition.", entity)
    return
  end
  if depth > 6 then
    issue(issues, "error", "CONDITION_TOO_DEEP", path, "Conditions are nested too deeply.", entity)
    return
  end
  local op = cond.op
  if op == "and" or op == "or" then
    if not U.isList(cond.items) or #cond.items == 0 then
      issue(
        issues,
        "error",
        "CONDITION_EMPTY",
        path .. ".items",
        string.upper(op) .. " needs at least one condition.",
        entity
      )
      return
    end
    for i, item in ipairs(cond.items) do
      M.validateCondition(item, ix, string.format("%s.items[%d]", path, i), issues, entity, depth + 1)
    end
  elseif op == "not" then
    M.validateCondition(cond.item, ix, path .. ".item", issues, entity, depth + 1)
  elseif op == "bool" then
    if type(cond.value) ~= "boolean" then
      issue(issues, "error", "CONDITION_INVALID", path .. ".value", "Must be true or false.", entity)
    end
  elseif op == "venue_status" then
    if cond.is ~= "open" and cond.is ~= "closed" then
      issue(issues, "error", "CONDITION_INVALID", path .. ".is", "Venue status must be open or closed.", entity)
    end
  elseif op == "time_range" then
    if U.parseTime(cond.from) == nil or U.parseTime(cond.to) == nil then
      issue(issues, "error", "CONDITION_INVALID", path, "Time range needs a start and an end as HH:MM.", entity)
    end
  elseif op == "day_of_week" then
    if not U.isList(cond.days) or #cond.days == 0 then
      issue(issues, "error", "CONDITION_INVALID", path .. ".days", "Choose at least one day.", entity)
    else
      for _, d in ipairs(cond.days) do
        if type(d) ~= "number" or d < 1 or d > 7 or d ~= math.floor(d) then
          issue(issues, "error", "CONDITION_INVALID", path .. ".days", "Days are 1 (Monday) to 7 (Sunday).", entity)
          break
        end
      end
    end
  elseif op == "display_state" then
    needRef(cond.displayId, ix.displays, "display", path .. ".displayId", issues, entity, "Display")
    if cond.field ~= "power" and cond.field ~= "source" then
      issue(issues, "error", "CONDITION_INVALID", path .. ".field", "Display state is power or source.", entity)
    elseif cond.field == "source" and cond.equals ~= nil then
      needRef(cond.equals, ix.sources, "source", path .. ".equals", issues, entity, "Source")
    end
  elseif op == "zone_state" then
    needRef(cond.zoneId, ix.zones, "audio zone", path .. ".zoneId", issues, entity, "Audio zone")
    if cond.field ~= "power" and cond.field ~= "muted" and cond.field ~= "source" then
      issue(issues, "error", "CONDITION_INVALID", path .. ".field", "Zone state is power, muted or source.", entity)
    end
  elseif op == "source_available" then
    needRef(cond.sourceId, ix.sources, "source", path .. ".sourceId", issues, entity, "Source")
  elseif op == "variable" then
    needRef(cond.variableId, ix.variables, "variable", path .. ".variableId", issues, entity, "Variable")
    if not CMP_SET[cond.cmp or "eq"] then
      issue(issues, "error", "CONDITION_INVALID", path .. ".cmp", "Unknown comparison.", entity)
    end
  elseif op == "c4_variable" then
    if type(cond.deviceId) ~= "number" or type(cond.variable) ~= "string" or cond.variable == "" then
      issue(
        issues,
        "error",
        "CONDITION_INVALID",
        path,
        "A Control4 variable condition needs a device id and a variable name.",
        entity
      )
    end
    if not CMP_SET[cond.cmp or "eq"] then
      issue(issues, "error", "CONDITION_INVALID", path .. ".cmp", "Unknown comparison.", entity)
    end
  elseif op == "context_area" then
    needRef(cond.areaId, ix.areas, "area", path .. ".areaId", issues, entity, "Area")
  end
end

local function validateSteps(steps, ix, path, issues, entity, nesting, counter)
  if not U.isList(steps) then
    issue(issues, "error", "NOT_A_LIST", path, "Steps must be a list.", entity)
    return
  end
  for i, step in ipairs(steps) do
    local sp = string.format("%s[%d]", path, i)
    counter.n = counter.n + 1
    if type(step) ~= "table" or not STEP_SET[step.type] then
      issue(issues, "error", "STEP_UNKNOWN", sp, "Unknown step type; it cannot run.", entity)
    else
      local t = step.type
      if t == "display_power" then
        validateTarget(step.target, ix, sp .. ".target", issues, entity)
        if step.power ~= "on" and step.power ~= "off" then
          issue(issues, "error", "STEP_INVALID", sp .. ".power", "Power must be on or off.", entity)
        end
      elseif t == "route_video" then
        validateTarget(step.target, ix, sp .. ".target", issues, entity)
        if needRef(step.sourceId, ix.sources, "source", sp .. ".sourceId", issues, entity, "Source") then
          if ix.sources[step.sourceId].video == false then
            issue(issues, "error", "STEP_INVALID", sp .. ".sourceId", "That source has no video.", entity)
          end
        end
      elseif t == "route_audio" then
        needRef(step.zoneId, ix.zones, "audio zone", sp .. ".zoneId", issues, entity, "Audio zone")
        if needRef(step.sourceId, ix.sources, "source", sp .. ".sourceId", issues, entity, "Source") then
          if ix.sources[step.sourceId].audio == false then
            issue(issues, "error", "STEP_INVALID", sp .. ".sourceId", "That source has no audio.", entity)
          end
        end
      elseif t == "volume" then
        needRef(step.zoneId, ix.zones, "audio zone", sp .. ".zoneId", issues, entity, "Audio zone")
        if type(step.level) ~= "number" or step.level < 0 or step.level > 100 then
          issue(issues, "error", "STEP_INVALID", sp .. ".level", "Volume must be between 0 and 100.", entity)
        end
      elseif t == "mute" then
        needRef(step.zoneId, ix.zones, "audio zone", sp .. ".zoneId", issues, entity, "Audio zone")
        if type(step.muted) ~= "boolean" then
          issue(issues, "error", "STEP_INVALID", sp .. ".muted", "Mute must be true or false.", entity)
        end
      elseif t == "zone_power" then
        needRef(step.zoneId, ix.zones, "audio zone", sp .. ".zoneId", issues, entity, "Audio zone")
        if step.power ~= "off" then
          issue(
            issues,
            "error",
            "STEP_INVALID",
            sp .. ".power",
            "A zone can only be switched off (choose a source to start it).",
            entity
          )
        end
      elseif t == "lighting" then
        if
          needRef(step.lightingId, ix.lighting, "lighting control", sp .. ".lightingId", issues, entity, "Lighting")
        then
          local found = false
          for _, p in ipairs(U.list(ix.lighting[step.lightingId].presets)) do
            if p.id == step.presetId then
              found = true
            end
          end
          if step.presetId == nil or step.presetId == "" then
            issue(issues, "warning", "STEP_INCOMPLETE", sp .. ".presetId", "Lighting preset is not chosen yet.", entity)
          elseif not found then
            issue(issues, "error", "REF_UNKNOWN", sp .. ".presetId", "That lighting preset does not exist.", entity)
          end
        end
      elseif t == "shade" then
        needRef(step.shadeId, ix.shades, "shade", sp .. ".shadeId", issues, entity, "Shade")
        if step.action ~= "open" and step.action ~= "close" then
          issue(issues, "error", "STEP_INVALID", sp .. ".action", "Shade action must be open or close.", entity)
        end
      elseif t == "wait" then
        if type(step.seconds) ~= "number" or step.seconds <= 0 or step.seconds > M.MAX_WAIT_SECONDS then
          issue(
            issues,
            "error",
            "STEP_INVALID",
            sp .. ".seconds",
            string.format("A wait must be between 1 and %d seconds.", M.MAX_WAIT_SECONDS),
            entity
          )
        end
      elseif t == "run_scene" then
        needRef(step.sceneId, ix.scenes, "scene", sp .. ".sceneId", issues, entity, "Scene")
      elseif t == "set_variable" then
        needRef(step.variableId, ix.variables, "variable", sp .. ".variableId", issues, entity, "Variable")
        local vt = type(step.value)
        if vt ~= "boolean" and vt ~= "number" and vt ~= "string" then
          issue(
            issues,
            "error",
            "STEP_INVALID",
            sp .. ".value",
            "A variable value is a yes/no, a number or text.",
            entity
          )
        end
      elseif t == "set_venue_status" then
        if step.status ~= "open" and step.status ~= "closed" then
          issue(issues, "error", "STEP_INVALID", sp .. ".status", "Venue status must be open or closed.", entity)
        end
      elseif t == "notify" then
        if type(step.message) ~= "string" or U.trim(step.message) == "" or #step.message > 200 then
          issue(
            issues,
            "error",
            "STEP_INVALID",
            sp .. ".message",
            "A notification needs a message of up to 200 characters.",
            entity
          )
        end
      elseif t == "if" then
        if nesting >= M.MAX_NESTING then
          issue(issues, "error", "STEP_TOO_DEEP", sp, "IF blocks are nested too deeply.", entity)
        else
          M.validateCondition(step.condition, ix, sp .. ".condition", issues, entity)
          validateSteps(step["then"] or {}, ix, sp .. ".then", issues, entity, nesting + 1, counter)
          validateSteps(step["else"] or {}, ix, sp .. ".else", issues, entity, nesting + 1, counter)
        end
      end
    end
  end
end

function M.validateProgram(program, ix, path, issues, entity)
  if type(program) ~= "table" then
    issue(issues, "error", "PROGRAM_INVALID", path, "The program is missing.", entity)
    return
  end
  local counter = { n = 0 }
  validateSteps(program.steps or {}, ix, path .. ".steps", issues, entity, 0, counter)
  if counter.n > M.MAX_STEPS then
    issue(
      issues,
      "error",
      "PROGRAM_TOO_LONG",
      path .. ".steps",
      string.format("This program has %d steps; the limit is %d.", counter.n, M.MAX_STEPS),
      entity
    )
  end
end

function M.validateTrigger(trigger, ix, path, issues, entity)
  if type(trigger) ~= "table" or not TRIGGER_SET[trigger.type] then
    issue(issues, "error", "TRIGGER_UNKNOWN", path, "Unknown trigger.", entity)
    return
  end
  local t = trigger.type
  if t == "scene_activated" then
    needRef(trigger.sceneId, ix.scenes, "scene", path .. ".sceneId", issues, entity, "Scene")
  elseif t == "schedule" then
    if U.parseTime(trigger.time) == nil then
      issue(issues, "error", "TRIGGER_INVALID", path .. ".time", "A schedule needs a time as HH:MM.", entity)
    end
    if not U.isList(trigger.days) or #trigger.days == 0 then
      issue(issues, "error", "TRIGGER_INVALID", path .. ".days", "Choose at least one day.", entity)
    else
      for _, d in ipairs(trigger.days) do
        if type(d) ~= "number" or d < 1 or d > 7 or d ~= math.floor(d) then
          issue(issues, "error", "TRIGGER_INVALID", path .. ".days", "Days are 1 (Monday) to 7 (Sunday).", entity)
          break
        end
      end
    end
  elseif t == "c4_event" or t == "external" then
    if type(trigger.name) ~= "string" or not trigger.name:match("^[%w _%-]+$") or #trigger.name > 40 then
      issue(
        issues,
        "error",
        "TRIGGER_INVALID",
        path .. ".name",
        "An event name is letters, digits, spaces, dashes or underscores (up to 40).",
        entity
      )
    end
  elseif t == "device_state" then
    if trigger.entity == "display" then
      needRef(trigger.id, ix.displays, "display", path .. ".id", issues, entity, "Display")
      if trigger.field ~= "power" and trigger.field ~= "source" then
        issue(issues, "error", "TRIGGER_INVALID", path .. ".field", "Display state is power or source.", entity)
      end
    elseif trigger.entity == "zone" then
      needRef(trigger.id, ix.zones, "audio zone", path .. ".id", issues, entity, "Audio zone")
      if trigger.field ~= "power" and trigger.field ~= "muted" and trigger.field ~= "source" then
        issue(issues, "error", "TRIGGER_INVALID", path .. ".field", "Zone state is power, muted or source.", entity)
      end
    else
      issue(
        issues,
        "error",
        "TRIGGER_INVALID",
        path .. ".entity",
        "Device state triggers watch a display or a zone.",
        entity
      )
    end
  elseif t == "c4_variable" then
    if type(trigger.deviceId) ~= "number" or type(trigger.variable) ~= "string" or trigger.variable == "" then
      issue(
        issues,
        "error",
        "TRIGGER_INVALID",
        path,
        "A Control4 variable trigger needs a device id and a variable name.",
        entity
      )
    end
  elseif t == "venue_status" then
    if trigger.status ~= "open" and trigger.status ~= "closed" then
      issue(issues, "error", "TRIGGER_INVALID", path .. ".status", "Venue status must be open or closed.", entity)
    end
  end
end

--- Scene ids a list of steps can run (through run_scene, at any depth).
local function scenesRun(steps, out)
  for _, step in ipairs(U.list(steps)) do
    if type(step) == "table" then
      if step.type == "run_scene" and step.sceneId ~= nil then
        out[step.sceneId] = true
      elseif step.type == "if" then
        scenesRun(step["then"], out)
        scenesRun(step["else"], out)
      end
    end
  end
  return out
end

--- A scene that (directly or through other scenes and scene-triggered rules)
--- runs itself is refused: the runner would stop it at MAX_DEPTH anyway, but
--- a loop is always a mistake and is better said at publish time.
function M.validateCycles(config, issues)
  local edges = {}
  for _, s in ipairs(U.list(config.scenes)) do
    if type(s) == "table" and s.id ~= nil then
      edges[s.id] = scenesRun(type(s.program) == "table" and s.program.steps or {}, {})
    end
  end
  for _, r in ipairs(U.list(config.rules)) do
    if
      type(r) == "table"
      and r.enabled ~= false
      and type(r.trigger) == "table"
      and r.trigger.type == "scene_activated"
    then
      local from = r.trigger.sceneId
      if from ~= nil and edges[from] ~= nil then
        scenesRun(type(r.program) == "table" and r.program.steps or {}, edges[from])
      end
    end
  end
  local state = {}
  local reported = {}
  local function visit(id, trail)
    if state[id] == "done" then
      return
    end
    if state[id] == "open" then
      if not reported[id] then
        reported[id] = true
        issue(
          issues,
          "error",
          "SCENE_CYCLE",
          "scenes." .. id,
          "Scene '" .. id .. "' ends up running itself (" .. table.concat(trail, " > ") .. " > " .. id .. ").",
          { kind = "scene", id = id }
        )
      end
      return
    end
    state[id] = "open"
    trail[#trail + 1] = id
    for _, nextId in ipairs(U.sortedKeys(edges[id] or {})) do
      if edges[nextId] ~= nil then
        visit(nextId, trail)
      end
    end
    trail[#trail] = nil
    state[id] = "done"
  end
  for _, id in ipairs(U.sortedKeys(edges)) do
    visit(id, {})
  end
end

--- What a program can change: a set of "d:<displayId>" and "z:<zoneId>".
function M.touches(steps, config, ix, out, depth)
  out = out or {}
  depth = depth or 0
  for _, step in ipairs(U.list(steps)) do
    if type(step) == "table" then
      local t = step.type
      if t == "display_power" or t == "route_video" then
        for _, id in ipairs(M.resolveTarget(step.target, config, ix)) do
          out["d:" .. id] = true
        end
      elseif t == "route_audio" or t == "volume" or t == "mute" or t == "zone_power" then
        if step.zoneId ~= nil then
          out["z:" .. step.zoneId] = true
        end
      elseif t == "if" then
        M.touches(step["then"], config, ix, out, depth)
        M.touches(step["else"], config, ix, out, depth)
      elseif t == "run_scene" and depth < M.MAX_DEPTH then
        local scene = ix.scenes[step.sceneId]
        if scene ~= nil and type(scene.program) == "table" then
          M.touches(scene.program.steps, config, ix, out, depth + 1)
        end
      end
    end
  end
  return out
end

local function intersects(a, b)
  for k in pairs(a) do
    if b[k] then
      return true
    end
  end
  return false
end
M.intersects = intersects

--- Two enabled schedules at the same minute on a shared day that change the
--- same device are flagged: whichever ran second would win, silently.
function M.validateScheduleOverlaps(config, ix, issues)
  local scheduled = {}
  for i, r in ipairs(U.list(config.rules)) do
    if
      type(r) == "table"
      and r.enabled ~= false
      and type(r.trigger) == "table"
      and r.trigger.type == "schedule"
      and U.parseTime(r.trigger.time) ~= nil
      and U.isList(r.trigger.days)
    then
      scheduled[#scheduled + 1] = {
        rule = r,
        index = i,
        touches = M.touches(type(r.program) == "table" and r.program.steps or {}, config, ix),
      }
    end
  end
  for a = 1, #scheduled do
    for b = a + 1, #scheduled do
      local ra, rb = scheduled[a], scheduled[b]
      if ra.rule.trigger.time == rb.rule.trigger.time then
        local shared = false
        for _, d in ipairs(ra.rule.trigger.days) do
          if U.contains(rb.rule.trigger.days, d) then
            shared = true
          end
        end
        if shared and intersects(ra.touches, rb.touches) then
          issue(
            issues,
            "warning",
            "SCHEDULE_OVERLAP",
            string.format("rules[%d].trigger", rb.index),
            "Schedules '"
              .. tostring(ra.rule.name)
              .. "' and '"
              .. tostring(rb.rule.name)
              .. "' run at the same time and change the same devices; the second stops the first.",
            { kind = "rule", id = rb.rule.id }
          )
        end
      end
    end
  end
end

-- ─── Describing steps (for logs and the dry-run plan) ───────────────────────

local function nameOf(index, id)
  local item = id ~= nil and index[id] or nil
  return item and tostring(item.name) or ("(" .. tostring(id or "not set") .. ")")
end

local function targetLabel(target, ix)
  if type(target) ~= "table" then
    return "(no displays)"
  end
  if target.all == true then
    return "all displays"
  end
  local parts = {}
  for _, gid in ipairs(U.list(target.groupIds)) do
    parts[#parts + 1] = "group " .. nameOf(ix.groups, gid)
  end
  for _, aid in ipairs(U.list(target.areaIds)) do
    parts[#parts + 1] = "area " .. nameOf(ix.areas, aid)
  end
  local n = #U.list(target.displayIds)
  if n > 0 and n <= 3 then
    for _, id in ipairs(target.displayIds) do
      parts[#parts + 1] = nameOf(ix.displays, id)
    end
  elseif n > 3 then
    parts[#parts + 1] = n .. " displays"
  end
  return #parts > 0 and table.concat(parts, ", ") or "(no displays)"
end

function M.describeStep(step, ix)
  local t = type(step) == "table" and step.type or "?"
  if t == "display_power" then
    return string.format("Power %s %s", tostring(step.power), targetLabel(step.target, ix))
  elseif t == "route_video" then
    return string.format("Route %s to %s", nameOf(ix.sources, step.sourceId), targetLabel(step.target, ix))
  elseif t == "route_audio" then
    return string.format("Play %s in %s", nameOf(ix.sources, step.sourceId), nameOf(ix.zones, step.zoneId))
  elseif t == "volume" then
    return string.format("Set %s volume to %s%%", nameOf(ix.zones, step.zoneId), tostring(step.level))
  elseif t == "mute" then
    return string.format("%s %s", step.muted and "Mute" or "Unmute", nameOf(ix.zones, step.zoneId))
  elseif t == "zone_power" then
    return string.format("Turn off %s", nameOf(ix.zones, step.zoneId))
  elseif t == "lighting" then
    local l = ix.lighting[step.lightingId or ""]
    local preset = "(not set)"
    for _, p in ipairs(l and U.list(l.presets) or {}) do
      if p.id == step.presetId then
        preset = tostring(p.name)
      end
    end
    return string.format("Lighting %s: %s", nameOf(ix.lighting, step.lightingId), preset)
  elseif t == "shade" then
    return string.format("%s shade %s", step.action == "open" and "Open" or "Close", nameOf(ix.shades, step.shadeId))
  elseif t == "wait" then
    return string.format("Wait %s s", tostring(step.seconds))
  elseif t == "run_scene" then
    return string.format("Run scene %s", nameOf(ix.scenes, step.sceneId))
  elseif t == "set_variable" then
    return string.format("Set %s to %s", nameOf(ix.variables, step.variableId), tostring(step.value))
  elseif t == "set_venue_status" then
    return string.format("Mark the venue %s", tostring(step.status))
  elseif t == "notify" then
    return string.format("Notify: %s", U.oneLine(step.message, 80))
  elseif t == "if" then
    return "IF " .. M.describeCondition(step.condition, ix)
  end
  return "Unknown step"
end

local DAY_SHORT = { "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" }
local CMP_TEXT = { eq = "=", ne = "is not", gt = ">", lt = "<", ge = ">=", le = "<=" }

function M.describeCondition(cond, ix)
  if type(cond) ~= "table" then
    return "(no condition)"
  end
  local op = cond.op
  if op == "and" or op == "or" then
    local parts = {}
    for _, item in ipairs(U.list(cond.items)) do
      parts[#parts + 1] = M.describeCondition(item, ix)
    end
    return "(" .. table.concat(parts, op == "and" and " AND " or " OR ") .. ")"
  elseif op == "not" then
    return "NOT " .. M.describeCondition(cond.item, ix)
  elseif op == "bool" then
    return cond.value and "always" or "never"
  elseif op == "venue_status" then
    return "venue is " .. tostring(cond.is)
  elseif op == "time_range" then
    return string.format("time is %s to %s", tostring(cond.from), tostring(cond.to))
  elseif op == "day_of_week" then
    local parts = {}
    for _, d in ipairs(U.list(cond.days)) do
      parts[#parts + 1] = DAY_SHORT[d] or "?"
    end
    return "day is " .. table.concat(parts, "/")
  elseif op == "display_state" then
    local value = cond.field == "source" and nameOf(ix.sources, cond.equals) or tostring(cond.equals)
    return string.format("%s %s is %s", nameOf(ix.displays, cond.displayId), tostring(cond.field), value)
  elseif op == "zone_state" then
    local value = cond.field == "source" and nameOf(ix.sources, cond.equals) or tostring(cond.equals)
    return string.format("%s %s is %s", nameOf(ix.zones, cond.zoneId), tostring(cond.field), value)
  elseif op == "source_available" then
    return nameOf(ix.sources, cond.sourceId) .. " is available"
  elseif op == "variable" then
    return string.format(
      "%s %s %s",
      nameOf(ix.variables, cond.variableId),
      CMP_TEXT[cond.cmp or "eq"],
      tostring(cond.value)
    )
  elseif op == "c4_variable" then
    return string.format(
      "Control4 %s.%s %s %s",
      tostring(cond.deviceId),
      tostring(cond.variable),
      CMP_TEXT[cond.cmp or "eq"],
      tostring(cond.value)
    )
  elseif op == "context_area" then
    return "pressed in " .. nameOf(ix.areas, cond.areaId)
  end
  return "(unknown condition)"
end

-- ─── Condition evaluation ───────────────────────────────────────────────────

local function compare(cmp, actual, expected)
  cmp = cmp or "eq"
  if cmp == "eq" or cmp == "ne" then
    local same
    if type(expected) == "boolean" then
      local truthy = actual == true or actual == "true" or actual == "1" or actual == 1
      same = truthy == expected
    elseif type(expected) == "number" then
      same = tonumber(actual) == expected
    else
      same = tostring(actual) == tostring(expected)
    end
    if cmp == "eq" then
      return same
    end
    return not same
  end
  local a, b = tonumber(actual), tonumber(expected)
  if a == nil or b == nil then
    return false
  end
  if cmp == "gt" then
    return a > b
  elseif cmp == "lt" then
    return a < b
  elseif cmp == "ge" then
    return a >= b
  end
  return a <= b
end
M.compare = compare

--- env = { venueStatus(), localtime() -> {hour,min,wday}, displayState(id) -> {power, source},
---         zoneState(id) -> {power, muted, source}, sourceAvailable(id), variable(id),
---         c4Variable(deviceId, name), context = { areaId } }
--- An unknown fact makes a condition FALSE (never guessed true).
function M.evaluate(cond, env, depth)
  depth = depth or 1
  if type(cond) ~= "table" or depth > 8 then
    return false
  end
  local op = cond.op
  if op == "and" then
    for _, item in ipairs(U.list(cond.items)) do
      if not M.evaluate(item, env, depth + 1) then
        return false
      end
    end
    return #U.list(cond.items) > 0
  elseif op == "or" then
    for _, item in ipairs(U.list(cond.items)) do
      if M.evaluate(item, env, depth + 1) then
        return true
      end
    end
    return false
  elseif op == "not" then
    return not M.evaluate(cond.item, env, depth + 1)
  elseif op == "bool" then
    return cond.value == true
  elseif op == "venue_status" then
    return env.venueStatus() == cond.is
  elseif op == "time_range" then
    local from, to = U.parseTime(cond.from), U.parseTime(cond.to)
    local lt = env.localtime()
    if from == nil or to == nil or type(lt) ~= "table" then
      return false
    end
    local minute = lt.hour * 60 + lt.min
    if from <= to then
      return minute >= from and minute < to
    end
    return minute >= from or minute < to -- a range over midnight
  elseif op == "day_of_week" then
    local lt = env.localtime()
    if type(lt) ~= "table" or lt.wday == nil then
      return false
    end
    return U.contains(U.list(cond.days), U.isoWeekday(lt.wday))
  elseif op == "display_state" then
    local s = env.displayState(cond.displayId)
    if s == nil then
      return false
    end
    local actual = s[cond.field]
    if actual == nil then
      return false
    end
    return tostring(actual) == tostring(cond.equals)
  elseif op == "zone_state" then
    local s = env.zoneState(cond.zoneId)
    if s == nil then
      return false
    end
    local actual = s[cond.field]
    if actual == nil then
      return false
    end
    if cond.field == "muted" then
      return (actual == true) == (cond.equals == true or cond.equals == "true")
    end
    return tostring(actual) == tostring(cond.equals)
  elseif op == "source_available" then
    return env.sourceAvailable(cond.sourceId) == true
  elseif op == "variable" then
    local actual = env.variable(cond.variableId)
    if actual == nil then
      return false
    end
    return compare(cond.cmp, actual, cond.value)
  elseif op == "c4_variable" then
    local actual = env.c4Variable(cond.deviceId, cond.variable)
    if actual == nil then
      return false
    end
    return compare(cond.cmp, actual, cond.value)
  elseif op == "context_area" then
    return env.context ~= nil and env.context.areaId == cond.areaId
  end
  return false
end

-- ─── The runner ─────────────────────────────────────────────────────────────

local Runner = {}
Runner.__index = Runner

--- deps = {
---   ops      the engines (see core.lua): displayPower, routeVideo, routeAudio, volume, mute,
---            zonePower, lighting, shade, setVariable, setVenueStatus, notify. Each takes
---            (args..., opts) with opts = { dry, origin, executionId } and returns
---            { ok, status, results?, operationId?, errorCode?, message?, detail? }
---   env()    -> condition environment (see M.evaluate)
---   config() -> the published configuration;  index() -> its lookup tables
---   timers   = { set(id, ms, fn), cancel(id) }
---   now()    -> epoch seconds
---   onUpdate(exec)  called whenever an execution record changes
---   keep     how many finished executions to remember (default 40)
--- }
function M.newRunner(deps)
  local self = setmetatable({}, Runner)
  self.deps = deps
  self.seq = 0
  self.running = {} -- id -> exec (still stepping or waiting for device confirmation)
  self.history = {} -- finished, newest first
  self.byOperation = {} -- operationId -> { exec, step }
  self.keep = deps.keep or 40
  self.stack = {}
  return self
end

local BAD = { failed = true, partial = true, cancelled = true, incomplete = true }

local function finalStatus(exec)
  local good, bad = 0, 0
  for _, s in ipairs(exec.steps) do
    if BAD[s.status] then
      bad = bad + 1
    elseif s.status == "ok" or s.status == "planned" then
      good = good + 1
    end
  end
  if exec.cancelled then
    return "cancelled"
  end
  if bad == 0 then
    return exec.dryRun and "planned" or "ok"
  end
  -- A partial step did something; a run with any success is partial.
  for _, s in ipairs(exec.steps) do
    if s.status == "partial" then
      return "partial"
    end
  end
  return good > 0 and "partial" or "failed"
end

function Runner:_notify(exec)
  if self.deps.onUpdate then
    pcall(self.deps.onUpdate, exec)
  end
end

function Runner:_finish(exec)
  exec.status = exec.forcedStatus or finalStatus(exec)
  exec.finishedAt = self.deps.now()
  exec._frames = nil
  self.running[exec.id] = nil
  for opId, ref in pairs(self.byOperation) do
    if ref.exec == exec then
      self.byOperation[opId] = nil
    end
  end
  table.insert(self.history, 1, exec)
  while #self.history > self.keep do
    table.remove(self.history)
  end
  self:_notify(exec)
end

--- Steps are done; the run is final once every device operation it started
--- has settled (confirmed, failed or timed out).
function Runner:_maybeFinish(exec)
  if exec._frames ~= nil and #exec._frames > 0 and not exec.cancelled then
    return
  end
  for _, s in ipairs(exec.steps) do
    if s.status == "sent" then
      exec.status = "settling"
      self:_notify(exec)
      return
    end
  end
  self:_finish(exec)
end

local function record(exec, path, step, label)
  local entry = { path = path, type = type(step) == "table" and step.type or "?", label = label, status = "running" }
  exec.steps[#exec.steps + 1] = entry
  return entry
end

function Runner:_applyResult(exec, entry, result)
  result = type(result) == "table" and result or { ok = false, errorCode = "VF_INTERNAL" }
  entry.results = result.results
  entry.errorCode = result.errorCode
  entry.message = result.message
  entry.detail = result.detail
  local status = result.status
  if exec.dryRun then
    if status == "partial" then
      entry.status = "partial"
    elseif result.ok then
      entry.status = "planned"
    else
      entry.status = "failed"
    end
    return
  end
  if result.operationId ~= nil and (status == "accepted" or status == "partial") then
    entry.status = "sent"
    entry.operationId = result.operationId
    entry.partialAtDispatch = status == "partial"
    if result.settled and type(result.final) == "table" then
      -- Already finished (the devices were in the requested state).
      self:_settleStep(entry, result.final.summary, result.final.targets)
    else
      self.byOperation[result.operationId] = { exec = exec, step = entry }
    end
  elseif result.ok and status ~= "partial" then
    entry.status = "ok"
  elseif status == "partial" then
    entry.status = "partial"
  else
    entry.status = "failed"
  end
end

function Runner:_settleStep(entry, summary, results)
  entry.results = results or entry.results
  if summary.bad == 0 and not entry.partialAtDispatch then
    entry.status = "ok"
  elseif summary.good > 0 then
    entry.status = "partial"
  else
    entry.status = "failed"
    entry.errorCode = entry.errorCode or "VF_NOT_CONFIRMED"
  end
end

--- Called by the core when a device operation started by a step has settled.
--- summary = { total, good, bad }; results = per-target final outcomes.
function Runner:operationSettled(operationId, summary, results)
  local ref = self.byOperation[operationId]
  if ref == nil then
    return
  end
  self.byOperation[operationId] = nil
  local entry, exec = ref.step, ref.exec
  if entry.status ~= "sent" then
    return
  end
  self:_settleStep(entry, summary, results)
  if self.running[exec.id] ~= nil then
    self:_maybeFinish(exec)
  end
end

function Runner:_runStep(exec, frame, step, path)
  local deps = self.deps
  local ix = deps.index()
  local entry = record(exec, path, step, M.describeStep(step, ix))
  local opts = { dry = exec.dryRun, origin = exec.origin, executionId = exec.id }
  if type(step) ~= "table" or not STEP_SET[step.type] then
    entry.status = "failed"
    entry.errorCode = "VF_UNSUPPORTED"
    entry.message = "Unknown step type; skipped."
    return
  end
  local t = step.type
  local ops = deps.ops
  if t == "if" then
    local met = M.evaluate(step.condition, deps.env(exec.context))
    entry.status = "ok"
    entry.branch = met and "then" or "else"
    entry.message = met and "condition met" or "condition not met"
    exec._frames[#exec._frames + 1] = {
      steps = U.list(met and step["then"] or step["else"]),
      i = 1,
      prefix = path .. "." .. entry.branch .. ".",
      depth = frame.depth,
      chain = frame.chain,
    }
    return
  elseif t == "wait" then
    local seconds = math.min(tonumber(step.seconds) or 0, M.MAX_WAIT_SECONDS)
    if exec.dryRun or seconds <= 0 then
      entry.status = exec.dryRun and "planned" or "ok"
      return
    end
    entry.status = "waiting"
    exec._timer = "VfRun_" .. exec.id
    deps.timers.set(exec._timer, seconds * 1000, function()
      exec._timer = nil
      if self.running[exec.id] == nil or exec.cancelled then
        return
      end
      entry.status = "ok"
      self:_advance(exec)
    end)
    return "wait"
  elseif t == "run_scene" then
    local scene = ix.scenes[step.sceneId or ""]
    if scene == nil then
      entry.status = "incomplete"
      entry.errorCode = "VF_NOT_FOUND"
      entry.message = "No scene chosen."
      return
    end
    if frame.depth + 1 > M.MAX_DEPTH or frame.chain[scene.id] then
      entry.status = "failed"
      entry.errorCode = "VF_RECURSION_LIMIT"
      entry.message = "Scene '" .. tostring(scene.name) .. "' would run itself; stopped."
      return
    end
    if scene.condition ~= nil and not M.evaluate(scene.condition, deps.env(exec.context)) then
      entry.status = "skipped"
      entry.errorCode = "VF_CONDITION_FALSE"
      entry.message = "Scene condition not met."
      return
    end
    local chain = U.copy(frame.chain)
    chain[scene.id] = true
    entry.status = "ok"
    exec._frames[#exec._frames + 1] = {
      steps = U.list(type(scene.program) == "table" and scene.program.steps or {}),
      i = 1,
      prefix = path .. ".",
      depth = frame.depth + 1,
      chain = chain,
    }
    if not exec.dryRun and deps.onSceneRun then
      pcall(deps.onSceneRun, scene, exec)
    end
    return
  end

  -- Incomplete template steps are reported, never guessed.
  local function incomplete(what)
    entry.status = "incomplete"
    entry.errorCode = "VF_INVALID_PAYLOAD"
    entry.message = what .. " is not chosen; step skipped."
  end
  local config = deps.config()
  local ok, result = pcall(function()
    if t == "display_power" then
      local ids = M.resolveTarget(step.target, config, ix)
      if #ids == 0 then
        return nil
      end
      return ops.displayPower(ids, step.power, opts)
    elseif t == "route_video" then
      local ids = M.resolveTarget(step.target, config, ix)
      if #ids == 0 or step.sourceId == nil then
        return nil
      end
      return ops.routeVideo(step.sourceId, ids, opts)
    elseif t == "route_audio" then
      if step.zoneId == nil or step.sourceId == nil then
        return nil
      end
      return ops.routeAudio(step.zoneId, step.sourceId, opts)
    elseif t == "volume" then
      if step.zoneId == nil then
        return nil
      end
      return ops.volume(step.zoneId, step.level, opts)
    elseif t == "mute" then
      if step.zoneId == nil then
        return nil
      end
      return ops.mute(step.zoneId, step.muted, opts)
    elseif t == "zone_power" then
      if step.zoneId == nil then
        return nil
      end
      return ops.zonePower(step.zoneId, step.power, opts)
    elseif t == "lighting" then
      if step.lightingId == nil then
        return nil
      end
      return ops.lighting(step.lightingId, step.presetId, opts)
    elseif t == "shade" then
      if step.shadeId == nil then
        return nil
      end
      return ops.shade(step.shadeId, step.action, opts)
    elseif t == "set_variable" then
      if step.variableId == nil then
        return nil
      end
      return ops.setVariable(step.variableId, step.value, opts)
    elseif t == "set_venue_status" then
      return ops.setVenueStatus(step.status, opts)
    elseif t == "notify" then
      return ops.notify(step.message, step.level, opts)
    end
    return { ok = false, errorCode = "VF_UNSUPPORTED" }
  end)
  if not ok then
    entry.status = "failed"
    entry.errorCode = "VF_INTERNAL"
    entry.detail = tostring(result)
    entry.message = "The step failed inside the driver."
    return
  end
  if result == nil then
    incomplete("A target or value")
    return
  end
  self:_applyResult(exec, entry, result)
end

--- `stack` holds the runs whose step is executing right now. A rule that a
--- step triggers (a scene marks the venue open; a rule waits for that) starts
--- INSIDE its parent's step: it must not be treated as a rival of its parent.
function Runner:_advance(exec)
  self.stack[#self.stack + 1] = exec
  local ok, err = pcall(self._advanceInner, self, exec)
  self.stack[#self.stack] = nil
  if not ok then
    error(err, 0)
  end
end

function Runner:_advanceInner(exec)
  local guard = 0
  while self.running[exec.id] ~= nil and not exec.cancelled do
    guard = guard + 1
    if guard > M.MAX_STEPS * 4 then
      exec.steps[#exec.steps + 1] = {
        path = "-",
        type = "?",
        label = "Stopped",
        status = "failed",
        errorCode = "VF_RECURSION_LIMIT",
        message = "Too many steps.",
      }
      exec._frames = {}
      break
    end
    local frame = exec._frames[#exec._frames]
    if frame == nil then
      break
    end
    local step = frame.steps[frame.i]
    if step == nil then
      exec._frames[#exec._frames] = nil
    else
      local index = frame.i
      frame.i = frame.i + 1
      local signal = self:_runStep(exec, frame, step, frame.prefix .. index)
      if signal == "wait" then
        self:_notify(exec)
        return
      end
    end
  end
  if self.running[exec.id] ~= nil then
    self:_maybeFinish(exec)
  end
end

--- spec = { kind = "scene"|"rule"|"adhoc", refId, name, program, condition?, dryRun?, origin?, context? }
--- Returns the execution record (finished, or still running when it waits).
function Runner:start(spec)
  local deps = self.deps
  self.seq = self.seq + 1
  local exec = {
    id = string.format("x%d", self.seq),
    kind = spec.kind or "adhoc",
    refId = spec.refId,
    name = spec.name or spec.refId or "Program",
    dryRun = spec.dryRun == true,
    origin = spec.origin or "unknown",
    context = spec.context,
    startedAt = deps.now(),
    status = "running",
    steps = {},
    touches = spec.touches,
  }
  self.running[exec.id] = exec
  if spec.condition ~= nil then
    exec.conditionMet = M.evaluate(spec.condition, deps.env(exec.context))
    if not exec.conditionMet then
      exec._frames = {}
      exec.steps[1] = {
        path = "condition",
        type = "condition",
        label = "IF " .. M.describeCondition(spec.condition, deps.index()),
        status = "skipped",
        errorCode = "VF_CONDITION_FALSE",
        message = "Condition not met; nothing was run.",
      }
      exec.forcedStatus = "skipped"
      self:_finish(exec)
      return exec
    end
  end
  local chain = {}
  if spec.kind == "scene" and spec.refId ~= nil then
    chain[spec.refId] = true
  end
  exec._frames = {
    {
      steps = U.list(type(spec.program) == "table" and spec.program.steps or {}),
      i = 1,
      prefix = "",
      depth = 0,
      chain = chain,
    },
  }
  self:_advance(exec)
  return exec
end

--- Stops a run: remaining steps do not happen. Never silent: the record says
--- who stopped it.
function Runner:cancel(execId, reason, by)
  local exec = self.running[execId]
  if exec == nil then
    return false
  end
  exec.cancelled = true
  exec.cancelReason = reason or "VF_CANCELLED"
  exec.cancelledBy = by
  if exec._timer ~= nil then
    pcall(self.deps.timers.cancel, exec._timer)
    exec._timer = nil
  end
  for _, s in ipairs(exec.steps) do
    if s.status == "waiting" or s.status == "running" then
      s.status = "cancelled"
      s.errorCode = exec.cancelReason
    end
  end
  exec._frames = {}
  self:_finish(exec)
  return true
end

function Runner:cancelAll(reason, by)
  for _, id in ipairs(U.sortedKeys(self.running)) do
    self:cancel(id, reason, by)
  end
end

--- Running executions whose targets overlap `touches`.
function Runner:overlapping(touches)
  local out = {}
  for _, id in ipairs(U.sortedKeys(self.running)) do
    local exec = self.running[id]
    local ancestor = false
    for _, active in ipairs(self.stack) do
      if active == exec then
        ancestor = true
      end
    end
    if not ancestor and not exec.dryRun and type(exec.touches) == "table" and intersects(exec.touches, touches) then
      out[#out + 1] = exec
    end
  end
  return out
end

--- A copy safe to hand to a page (no frames, no functions).
function M.publicExecution(exec, includeDetail)
  local out = {
    id = exec.id,
    kind = exec.kind,
    refId = exec.refId,
    name = exec.name,
    dryRun = exec.dryRun,
    origin = exec.origin,
    startedAt = exec.startedAt,
    finishedAt = exec.finishedAt,
    status = exec.status,
    conditionMet = exec.conditionMet,
    cancelReason = exec.cancelReason,
    cancelledBy = exec.cancelledBy,
    steps = {},
  }
  for i, s in ipairs(exec.steps) do
    out.steps[i] = {
      path = s.path,
      type = s.type,
      label = s.label,
      status = s.status,
      errorCode = s.errorCode,
      message = s.message,
      branch = s.branch,
      operationId = s.operationId,
      results = s.results,
      detail = includeDetail and s.detail or nil,
    }
  end
  return out
end

function Runner:list(includeDetail)
  local out = {}
  for _, id in ipairs(U.sortedKeys(self.running)) do
    out[#out + 1] = M.publicExecution(self.running[id], includeDetail)
  end
  for _, exec in ipairs(self.history) do
    out[#out + 1] = M.publicExecution(exec, includeDetail)
  end
  return out
end

return M
