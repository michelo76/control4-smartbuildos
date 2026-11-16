--- Flight Recorder recording configuration v1 (pure).
---
--- A configuration document says WHICH sources are recorded and HOW
--- (debounce, minimum change, coalescing, labels, categories), what the
--- resource budgets are, and what is excluded for privacy. It is versioned:
--- the platform and Composer both produce revisions; the driver validates
--- a whole document before applying it and keeps the last valid one when a
--- revision is refused (System Studio Agent contract rule, reused).
---
--- Nothing here subscribes to anything. Resolution (variable name → id on
--- THIS controller) happens in resolve() with an injected reader, so a
--- renamed/replaced device shows as a stale or unsupported mapping instead
--- of a silent miss.

local M = {}

M.SCHEMA_VERSION = 1

M.LIMITS = {
  sources_ceiling = 200, -- hard; a budget cannot raise it
  sources_default = 64,
  label = 120,
  category = 40,
  debounce_ms = 60000,
  coalesce_ms = 60000,
  min_change = 1000000,
  events_per_minute_ceiling = 600,
  events_per_minute_default = 120,
  exclusions = 64,
  pattern = 60,
}

--- Source kinds. `device_event` is RESERVED and unsupported in v1 (no
--- documented enumeration call; CAPABILITY-MATRIX row 7).
M.KINDS = { device_variable = true, room_variable = true, sbos_event = true, device_event = false }

--- Variables that are never recorded whatever the configuration says. Matched
--- against the UPPER-CASED variable name with non-alphanumerics removed.
M.FIXED_EXCLUSIONS = {
  "USERCODE",
  "ACCESSCODE",
  "PINCODE",
  "PASSCODE",
  "PASSWORD",
  "PASSWD",
  "TOKEN",
  "SECRET",
  "APIKEY",
  "DISARMCODE",
  "ARMCODE",
  "KEYCODE",
  "LOCKCODE",
  "CREDENTIAL",
}

--- Agent-classified system events a configuration may select (the Agent's
--- own vocabulary; see AGENT_TELEMETRY.md). The recorder subscribes to the
--- Agent's SBOS_MODULE_AGENT_EVENT frames for these, never to Director.
M.SBOS_EVENTS = {
  "director_reloaded",
  "unexpected_restart",
  "os_update_started",
  "project_changed",
  "programming_changed",
  "clock_drift",
  "device_offline",
  "device_online",
  "cloud_connected",
  "cloud_disconnected",
}

M.CATEGORIES =
  { "lighting", "contact", "motion", "media", "climate", "security", "lock", "shade", "keypad", "system", "custom" }

local function refusal(path, reason)
  return { path = path, reason = reason }
end

local function normalizeVarName(name)
  return tostring(name or ""):upper():gsub("[^%w]", "")
end

function M.isFixedExclusion(variableName)
  local n = normalizeVarName(variableName)
  for _, frag in ipairs(M.FIXED_EXCLUSIONS) do
    if n:find(frag, 1, true) then
      return true
    end
  end
  return false
end

--- Simple glob (`*` only) match on a normalised variable name.
function M.patternMatches(pattern, variableName)
  local p = tostring(pattern or ""):upper():gsub("[^%w%*]", ""):gsub("%*", ".*")
  if p == "" then
    return false
  end
  return normalizeVarName(variableName):match("^" .. p .. "$") ~= nil
end

function M.default()
  return {
    schema_version = M.SCHEMA_VERSION,
    version = 0,
    enabled = true,
    sources = {},
    budgets = {
      max_sources = M.LIMITS.sources_default,
      events_per_minute = M.LIMITS.events_per_minute_default,
    },
    exclusions = { variable_patterns = {} },
    privacy = { string_values = "flag" }, -- flag | exclude
  }
end

local function sourceId(kind, deviceId, variableName)
  return string.format("%s:%s:%s", kind, tostring(deviceId or 0), normalizeVarName(variableName))
end
M.sourceId = sourceId

local TOP_KEYS = {
  schema_version = true,
  version = true,
  enabled = true,
  sources = true,
  budgets = true,
  exclusions = true,
  privacy = true,
}
local SOURCE_KEYS = {
  kind = true,
  device_id = true,
  variable = true,
  label = true,
  category = true,
  enabled = true,
  debounce_ms = true,
  min_change = true,
  coalesce_ms = true,
  event = true,
  device_label = true,
  room_id = true,
  room_label = true,
}

local function boundedInt(value, path, min, max, refusals, default)
  if value == nil then
    return default
  end
  local n = tonumber(value)
  if n == nil or n ~= math.floor(n) or n < min or n > max then
    refusals[#refusals + 1] = refusal(path, string.format("must be an integer %d..%d", min, max))
    return default
  end
  return n
end

--- Validates a whole document. Any refusal rejects the document (nil); the
--- caller keeps its last valid configuration.
--- @return table|nil config, table refusals
function M.validate(raw)
  local refusals = {}
  if type(raw) ~= "table" then
    return nil, { refusal("config", "must be an object") }
  end
  for key in pairs(raw) do
    if not TOP_KEYS[key] then
      refusals[#refusals + 1] = refusal(tostring(key), "unknown property")
    end
  end
  if raw.schema_version ~= nil and tonumber(raw.schema_version) ~= M.SCHEMA_VERSION then
    refusals[#refusals + 1] = refusal("schema_version", "unsupported; this driver speaks v" .. M.SCHEMA_VERSION)
  end
  local out = M.default()
  out.version = boundedInt(raw.version, "version", 0, 2 ^ 31, refusals, 0)
  if raw.enabled ~= nil then
    if type(raw.enabled) ~= "boolean" then
      refusals[#refusals + 1] = refusal("enabled", "must be a boolean")
    else
      out.enabled = raw.enabled
    end
  end
  local budgets = type(raw.budgets) == "table" and raw.budgets or {}
  out.budgets.max_sources = boundedInt(
    budgets.max_sources,
    "budgets.max_sources",
    1,
    M.LIMITS.sources_ceiling,
    refusals,
    M.LIMITS.sources_default
  )
  out.budgets.events_per_minute = boundedInt(
    budgets.events_per_minute,
    "budgets.events_per_minute",
    1,
    M.LIMITS.events_per_minute_ceiling,
    refusals,
    M.LIMITS.events_per_minute_default
  )
  local privacy = type(raw.privacy) == "table" and raw.privacy or {}
  if privacy.string_values ~= nil then
    if privacy.string_values ~= "flag" and privacy.string_values ~= "exclude" then
      refusals[#refusals + 1] = refusal("privacy.string_values", "must be flag or exclude")
    else
      out.privacy.string_values = privacy.string_values
    end
  end
  local exclusions = type(raw.exclusions) == "table" and raw.exclusions or {}
  if exclusions.variable_patterns ~= nil then
    if type(exclusions.variable_patterns) ~= "table" then
      refusals[#refusals + 1] = refusal("exclusions.variable_patterns", "must be a list")
    else
      for i, p in ipairs(exclusions.variable_patterns) do
        if type(p) ~= "string" or p == "" or #p > M.LIMITS.pattern then
          refusals[#refusals + 1] = refusal("exclusions.variable_patterns[" .. i .. "]", "must be a non-empty string")
        elseif #out.exclusions.variable_patterns < M.LIMITS.exclusions then
          out.exclusions.variable_patterns[#out.exclusions.variable_patterns + 1] = p
        end
      end
    end
  end
  local sources = raw.sources
  if sources ~= nil and type(sources) ~= "table" then
    refusals[#refusals + 1] = refusal("sources", "must be a list")
    sources = {}
  end
  local seen = {}
  for i, s in ipairs(sources or {}) do
    local path = "sources[" .. i .. "]"
    if type(s) ~= "table" then
      refusals[#refusals + 1] = refusal(path, "must be an object")
    else
      for key in pairs(s) do
        if not SOURCE_KEYS[key] then
          refusals[#refusals + 1] = refusal(path .. "." .. tostring(key), "unknown property")
        end
      end
      local kind = tostring(s.kind or "")
      if M.KINDS[kind] == nil then
        refusals[#refusals + 1] = refusal(path .. ".kind", "unknown kind")
      elseif M.KINDS[kind] == false then
        refusals[#refusals + 1] = refusal(path .. ".kind", kind .. " is reserved and not supported by this driver")
      else
        local src = {
          kind = kind,
          enabled = s.enabled ~= false,
          label = tostring(s.label or ""):sub(1, M.LIMITS.label),
          category = tostring(s.category or "custom"):sub(1, M.LIMITS.category),
          device_label = s.device_label ~= nil and tostring(s.device_label):sub(1, M.LIMITS.label) or nil,
          room_label = s.room_label ~= nil and tostring(s.room_label):sub(1, M.LIMITS.label) or nil,
          room_id = tonumber(s.room_id),
          debounce_ms = boundedInt(s.debounce_ms, path .. ".debounce_ms", 0, M.LIMITS.debounce_ms, refusals, 0),
          coalesce_ms = boundedInt(s.coalesce_ms, path .. ".coalesce_ms", 0, M.LIMITS.coalesce_ms, refusals, 0),
          min_change = s.min_change ~= nil and tonumber(s.min_change) or 0,
        }
        if
          s.min_change ~= nil and (src.min_change == nil or src.min_change < 0 or src.min_change > M.LIMITS.min_change)
        then
          refusals[#refusals + 1] = refusal(path .. ".min_change", "must be a number 0.." .. M.LIMITS.min_change)
          src.min_change = 0
        end
        if kind == "sbos_event" then
          local event = tostring(s.event or "")
          local known = false
          for _, e in ipairs(M.SBOS_EVENTS) do
            if e == event then
              known = true
            end
          end
          if not known then
            refusals[#refusals + 1] = refusal(path .. ".event", "unknown SmartBuildOS event")
          end
          src.event = event
          src.id = sourceId(kind, 0, event)
          if src.label == "" then
            src.label = event
          end
        else
          local deviceId = tonumber(s.device_id)
          local variable = tostring(s.variable or "")
          if deviceId == nil or deviceId <= 0 then
            refusals[#refusals + 1] = refusal(path .. ".device_id", "must be a positive device id")
          end
          if variable == "" then
            refusals[#refusals + 1] = refusal(path .. ".variable", "must name a variable")
          end
          if M.isFixedExclusion(variable) then
            refusals[#refusals + 1] = refusal(path .. ".variable", "credential-bearing variables are never recorded")
          end
          src.device_id = deviceId
          src.variable = variable
          src.id = sourceId(kind, deviceId, variable)
          if src.label == "" then
            src.label = variable
          end
        end
        if src.id ~= nil then
          if seen[src.id] then
            refusals[#refusals + 1] = refusal(path, "duplicate source " .. src.id)
          else
            seen[src.id] = true
            out.sources[#out.sources + 1] = src
          end
        end
      end
    end
  end
  if #out.sources > out.budgets.max_sources then
    refusals[#refusals + 1] = refusal(
      "sources",
      string.format("%d sources exceed budgets.max_sources (%d)", #out.sources, out.budgets.max_sources)
    )
  end
  if #refusals > 0 then
    return nil, refusals
  end
  return out, refusals
end

--- Whether a variable is excluded by the fixed list, the user patterns, or
--- the string-value policy (string values decided by the caller per value).
function M.isExcluded(config, variableName)
  if M.isFixedExclusion(variableName) then
    return true, "fixed"
  end
  for _, p in ipairs(config.exclusions.variable_patterns or {}) do
    if M.patternMatches(p, variableName) then
      return true, "pattern"
    end
  end
  return false
end

--- Resolves every enabled variable source against the live project through
--- `readVariables(deviceId)` → { [id] = { name = ..., value = ... } } | nil.
--- A source whose device is gone is `stale`; one whose variable is gone is
--- `unsupported` (the device exists but does not expose it). Both are
--- reported, never silently dropped.
--- @return table plan { listeners = { {source, device_id, variable_id} }, stale = {...}, unsupported = {...}, excluded = {...}, events = {...} }
function M.resolve(config, readVariables)
  local plan = { listeners = {}, stale = {}, unsupported = {}, excluded = {}, events = {} }
  local cache = {}
  for _, src in ipairs(config.sources) do
    if src.enabled then
      if src.kind == "sbos_event" then
        plan.events[#plan.events + 1] = src
      else
        local excluded, why = M.isExcluded(config, src.variable)
        if excluded then
          plan.excluded[#plan.excluded + 1] = { source = src, reason = why }
        else
          local vars = cache[src.device_id]
          if vars == nil then
            local ok, result = pcall(readVariables, src.device_id)
            vars = ok and result or false
            cache[src.device_id] = vars
          end
          if type(vars) ~= "table" then
            plan.stale[#plan.stale + 1] = { source = src, reason = "device not in project" }
          else
            local found = nil
            local wanted = normalizeVarName(src.variable)
            for varId, v in pairs(vars) do
              if type(v) == "table" and normalizeVarName(v.name) == wanted then
                found = { id = tonumber(varId), name = v.name, value = v.value }
                break
              end
            end
            if found == nil or found.id == nil then
              plan.unsupported[#plan.unsupported + 1] = { source = src, reason = "variable not exposed by this device" }
            else
              plan.listeners[#plan.listeners + 1] = {
                source = src,
                device_id = src.device_id,
                variable_id = found.id,
                variable_name = found.name,
                value = found.value,
              }
            end
          end
        end
      end
    end
  end
  return plan
end

--- Practical templates. Each lists the variable names it would select; the
--- caller intersects with the catalogue so Studio shows ONLY sources that
--- actually exist in this project (never auto-subscribing to everything).
M.TEMPLATES = {
  {
    id = "lighting",
    label = "Lighting",
    category = "lighting",
    kind = "device_variable",
    variables = { "LIGHT_LEVEL", "LIGHT LEVEL", "Brightness Percent", "LIGHT_STATE", "LIGHT STATE" },
    debounce_ms = 1500,
    coalesce_ms = 1500,
    min_change = 1,
  },
  {
    id = "contacts",
    label = "Contacts and openings",
    category = "contact",
    kind = "device_variable",
    variables = {
      "ContactState",
      "CONTACT_STATE",
      "STATE",
      "DOOR_STATE",
      "GARAGE_STATE",
      "OPENED",
      "ContactSensorState",
    },
    debounce_ms = 0,
  },
  {
    id = "motion",
    label = "Motion and occupancy",
    category = "motion",
    kind = "device_variable",
    variables = { "MotionState", "MOTION_STATE", "OCCUPANCY_STATE", "MOTION" },
    debounce_ms = 2000,
    coalesce_ms = 5000,
  },
  {
    id = "room_media",
    label = "Room media",
    category = "media",
    kind = "room_variable",
    variables = { "POWER_STATE", "CURRENT_VOLUME", "CURRENT_SELECTED_DEVICE", "CURRENT MEDIA INFO", "PLAYING" },
    debounce_ms = 1000,
    coalesce_ms = 3000,
  },
  {
    id = "sbos_events",
    label = "SmartBuildOS events",
    category = "system",
    kind = "sbos_event",
    events = M.SBOS_EVENTS,
  },
}

--- Applies a template to a catalogue: catalogue = list of { kind, device_id,
--- device_label, room_id, room_label, variables = { names } }. Returns the
--- sources the template would add (present in the catalogue only).
function M.applyTemplate(templateId, catalogue)
  local template
  for _, t in ipairs(M.TEMPLATES) do
    if t.id == templateId then
      template = t
    end
  end
  if template == nil then
    return nil, "unknown template"
  end
  local out = {}
  if template.kind == "sbos_event" then
    for _, e in ipairs(template.events) do
      out[#out + 1] = { kind = "sbos_event", event = e, label = e, category = template.category }
    end
    return out
  end
  local wanted = {}
  for _, v in ipairs(template.variables) do
    wanted[normalizeVarName(v)] = v
  end
  for _, item in ipairs(catalogue or {}) do
    if item.kind == template.kind then
      for _, name in ipairs(item.variables or {}) do
        if wanted[normalizeVarName(name)] and not M.isFixedExclusion(name) then
          out[#out + 1] = {
            kind = template.kind,
            device_id = item.device_id,
            variable = name,
            label = (item.device_label and (item.device_label .. " · ") or "") .. name,
            category = template.category,
            device_label = item.device_label,
            room_id = item.room_id,
            room_label = item.room_label,
            debounce_ms = template.debounce_ms,
            coalesce_ms = template.coalesce_ms,
            min_change = template.min_change,
          }
        end
      end
    end
  end
  return out
end

--- The counts Studio shows next to a configuration.
function M.summary(config, plan)
  local enabled = 0
  for _, s in ipairs(config.sources) do
    if s.enabled then
      enabled = enabled + 1
    end
  end
  return {
    version = config.version,
    sources = #config.sources,
    enabled = enabled,
    listeners = plan and #plan.listeners or 0,
    stale = plan and #plan.stale or 0,
    unsupported = plan and #plan.unsupported or 0,
    excluded = plan and #plan.excluded or 0,
    events = plan and #plan.events or 0,
  }
end

return M
