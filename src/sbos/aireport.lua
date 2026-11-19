--- SmartBuildOS AI Core reporting helper: ONE module for both halves of a
--- driver's relationship with AI Core.
---
---   (a) The reporting client: `describe`, `state`, `event` and `diagnostic`
---       reports to capability `ai_core.report` v1 (provider `ai_core`), with
---       the closed kinds, size bounds and per-module rate bounds enforced
---       HERE, before anything is sent; and the serving side of `ai.query`
---       (declared read-only queries) and `ai.action` (declared actions), with
---       typed-param validation and the `declaration_hash` check.
---   (b) The "AI Core" Composer property, a state machine over the closed
---       value list (VALUES), driven by the module directory and
---       SBOS_MODULE_DIRECTORY_CHANGED and by the answers to reports, so the
---       property and the reports can never disagree.
---
--- Three entry modes:
---   start(opts)          a root driver NOT yet on the bus: the helper sets
---                        sbos.moduleclient up (claim_driver_config = false,
---                        protocol_min = 2) and registers.
---   attach(client, opts) a root driver that already runs its own
---                        moduleclient (Flight Recorder, ...): the helper uses
---                        that client; the driver forwards three callbacks.
---   passive(opts)        a child driver: no bus registration, no frame of any
---                        kind; it only looks AI Core up by file name.
---
--- Silent when AI Core is absent: no request is sent unless the directory
--- lists a live `ai_core` instance whose manifest advertises
--- `ai_core.report` v1. Nothing raises, nothing logs per report.
---
--- Wire contract: docs/protocol/MODULE-CONTRACT-V2.md (bus) and
--- docs/DRIVER_PLATFORM_GUIDE.md §9 (adoption). Nothing here has run on a
--- physical controller.

local log = require("lib.logging")
local license = require("sbos.license")
local moduleclient = require("sbos.moduleclient")
JSON = JSON or require("JSON")

local M = {}

M.PROPERTY = "AI Core"
M.CAPABILITY = "ai_core.report"
M.CAPABILITY_VERSION = 1
M.REPORT_VERSION = 1
M.QUERY_CAPABILITY = "ai.query"
M.ACTION_CAPABILITY = "ai.action"
M.AI_CORE_MODULE = "ai_core"
M.AI_CORE_FILE = "smartbuildos-ai-core.c4z"

-- ── closed driver tables ─────────────────────────────────────────────────────

--- Module id of every ROOT driver in drivers/, keyed by .c4z file name. The
--- id is never free text. Every entry is also a reserved id in the Agent's
--- modulepolicy.RESERVED_MODULES bound to the same file (test-enforced), so
--- the Agent can mark each root `verified`.
M.MODULE_IDS = {
  ["smartbuildos-ai-core.c4z"] = "ai_core",
  ["smartbuildos-flight-recorder.c4z"] = "flight_recorder",
  ["smartbuildos-usage-analytics.c4z"] = "usage_analytics",
  ["smartbuildos-mqtt-broker.c4z"] = "mqtt_broker",
  ["smartbuildos-venueflow.c4z"] = "venueflow",
  ["smartbuildos-pin-lock.c4z"] = "pin_lock",
  ["smartbuildos-atmosphere.c4z"] = "atmosphere",
  ["smartbuildos-mode-composer.c4z"] = "mode_composer",
  ["bond-bridge.c4z"] = "bond_bridge",
  ["smartbuildos-commissioning.c4z"] = "commissioning",
  ["smartbuildos-daypart.c4z"] = "daypart",
  ["smartbuildos-dealer-panel.c4z"] = "dealer_panel",
  ["smartbuildos-guest-mode.c4z"] = "guest_mode",
  ["smartbuildos-load-shedding.c4z"] = "load_shedding",
  ["smartbuildos-logic-pack.c4z"] = "logic_pack",
  ["smartbuildos-notification-router.c4z"] = "notification_router",
  ["smartbuildos-solar.c4z"] = "solar",
  ["smartbuildos-system-link.c4z"] = "system_link",
  ["smartbuildos-user-manual.c4z"] = "user_manual",
  ["smartbuildos-variable-inspector.c4z"] = "variable_inspector",
  ["unifi-protect.c4z"] = "unifi_protect",
}

--- Display name of every root (its driver.xml <name>), for the passive
--- value "Installed — reports through ‹root›" and as the describe name
--- fallback. The Agent is listed because smartbuildos-insights is its child.
M.LABELS = {
  ["smartbuildos.c4z"] = "SmartBuildOS Agent",
  ["smartbuildos-ai-core.c4z"] = "SmartBuildOS AI Core",
  ["smartbuildos-flight-recorder.c4z"] = "SmartBuildOS Flight Recorder",
  ["smartbuildos-usage-analytics.c4z"] = "SmartBuildOS Usage Analytics",
  ["smartbuildos-mqtt-broker.c4z"] = "SmartBuildOS MQTT Broker",
  ["smartbuildos-venueflow.c4z"] = "SmartBuildOS VenueFlow",
  ["smartbuildos-pin-lock.c4z"] = "SmartBuildOS PIN Lock",
  ["smartbuildos-atmosphere.c4z"] = "SmartBuildOS Atmosphere",
  ["smartbuildos-mode-composer.c4z"] = "SmartBuildOS Mode Composer",
  ["bond-bridge.c4z"] = "Bond Bridge Gateway (SBOS)",
  ["smartbuildos-commissioning.c4z"] = "SmartBuildOS Commissioning Matrix",
  ["smartbuildos-daypart.c4z"] = "SmartBuildOS Daypart Scheduler",
  ["smartbuildos-dealer-panel.c4z"] = "SmartBuildOS Dealer Settings",
  ["smartbuildos-guest-mode.c4z"] = "SmartBuildOS Guest Mode",
  ["smartbuildos-load-shedding.c4z"] = "SmartBuildOS Load Shedding",
  ["smartbuildos-logic-pack.c4z"] = "SmartBuildOS Logic Pack",
  ["smartbuildos-notification-router.c4z"] = "SmartBuildOS Notification Router",
  ["smartbuildos-solar.c4z"] = "SmartBuildOS Solar Position",
  ["smartbuildos-system-link.c4z"] = "SmartBuildOS System Link",
  ["smartbuildos-user-manual.c4z"] = "SmartBuildOS Home Guide",
  ["smartbuildos-variable-inspector.c4z"] = "SmartBuildOS Variable Inspector",
  ["unifi-protect.c4z"] = "UniFi Protect Gateway (SBOS)",
}

--- The baseline describe summary per root (a driver may pass its own).
M.SUMMARIES = {
  ["smartbuildos-ai-core.c4z"] = "SmartBuildOS AI Core.",
  ["smartbuildos-flight-recorder.c4z"] = "Records device and room activity for SmartBuildOS.",
  ["smartbuildos-usage-analytics.c4z"] = "Measures how the system is used.",
  ["smartbuildos-mqtt-broker.c4z"] = "Connects MQTT devices to Control4.",
  ["smartbuildos-venueflow.c4z"] = "Venue audio and video routing.",
  ["smartbuildos-pin-lock.c4z"] = "PIN codes for touchscreen actions.",
  ["smartbuildos-atmosphere.c4z"] = "Weather conditions and forecast for the home.",
  ["smartbuildos-mode-composer.c4z"] = "House modes composed from Control4 programming.",
  ["bond-bridge.c4z"] = "Bond Bridge gateway for fans, shades, fireplaces and lights.",
  ["smartbuildos-commissioning.c4z"] = "Commissioning checks for the installation.",
  ["smartbuildos-daypart.c4z"] = "Schedules by part of the day.",
  ["smartbuildos-dealer-panel.c4z"] = "Dealer settings panel.",
  ["smartbuildos-guest-mode.c4z"] = "Guest stays and guest access.",
  ["smartbuildos-load-shedding.c4z"] = "Sheds electrical loads by priority.",
  ["smartbuildos-logic-pack.c4z"] = "Reusable programming logic blocks.",
  ["smartbuildos-notification-router.c4z"] = "Routes notifications to people and devices.",
  ["smartbuildos-solar.c4z"] = "Sun position for the home's location.",
  ["smartbuildos-system-link.c4z"] = "Links devices between Control4 systems.",
  ["smartbuildos-user-manual.c4z"] = "The home guide on the touchscreens.",
  ["smartbuildos-variable-inspector.c4z"] = "Inspects Control4 variables.",
  ["unifi-protect.c4z"] = "UniFi Protect gateway for cameras, lights and sensors.",
}

--- Child drivers (passive mode only) and their root, keyed by file. Same
--- map as test/test_driver_license_guard.lua `inherited`.
M.CHILDREN = {
  ["bond-color-light.c4z"] = "bond-bridge.c4z",
  ["bond-fan.c4z"] = "bond-bridge.c4z",
  ["bond-fireplace.c4z"] = "bond-bridge.c4z",
  ["bond-generic.c4z"] = "bond-bridge.c4z",
  ["bond-heater.c4z"] = "bond-bridge.c4z",
  ["bond-keypad.c4z"] = "bond-bridge.c4z",
  ["bond-light.c4z"] = "bond-bridge.c4z",
  ["bond-shade.c4z"] = "bond-bridge.c4z",
  ["bond-weather.c4z"] = "bond-bridge.c4z",
  ["smartbuildos-insights.c4z"] = "smartbuildos.c4z",
  ["smartbuildos-mqtt-contact.c4z"] = "smartbuildos-mqtt-broker.c4z",
  ["smartbuildos-mqtt-light.c4z"] = "smartbuildos-mqtt-broker.c4z",
  ["smartbuildos-mqtt-motion.c4z"] = "smartbuildos-mqtt-broker.c4z",
  ["smartbuildos-mqtt-shade.c4z"] = "smartbuildos-mqtt-broker.c4z",
  ["smartbuildos-mode-button.c4z"] = "smartbuildos-mode-composer.c4z",
  ["smartbuildos-system-link-light.c4z"] = "smartbuildos-system-link.c4z",
  ["smartbuildos-system-link-relay.c4z"] = "smartbuildos-system-link.c4z",
  ["smartbuildos-system-link-contact.c4z"] = "smartbuildos-system-link.c4z",
  ["smartbuildos-system-link-temperature.c4z"] = "smartbuildos-system-link.c4z",
  ["smartbuildos-system-link-thermostat.c4z"] = "smartbuildos-system-link.c4z",
  ["smartbuildos-system-link-shade.c4z"] = "smartbuildos-system-link.c4z",
  ["smartbuildos-system-link-media.c4z"] = "smartbuildos-system-link.c4z",
  ["smartbuildos-system-link-lock.c4z"] = "smartbuildos-system-link.c4z",
  ["smartbuildos-system-link-gate.c4z"] = "smartbuildos-system-link.c4z",
  ["smartbuildos-system-link-fan.c4z"] = "smartbuildos-system-link.c4z",
  ["smartbuildos-system-link-export-light.c4z"] = "smartbuildos-system-link.c4z",
  ["unifi-protect-camera.c4z"] = "unifi-protect.c4z",
  ["unifi-protect-light.c4z"] = "unifi-protect.c4z",
  ["unifi-protect-sensor.c4z"] = "unifi-protect.c4z",
  ["unifi-protect-viewport.c4z"] = "unifi-protect.c4z",
}

--- Drivers that never use the helper, with the reason.
M.EXEMPT = {
  ["smartbuildos.c4z"] = "the SmartBuildOS Agent is the bus hub (and at its top-level local limit)",
}

-- ── the closed property value list (spec §3.6) ──────────────────────────────

M.V = {
  searching = "Searching…",
  no_agent = "SmartBuildOS Agent not found",
  agent_update = "SmartBuildOS Agent update required",
  registry_full = "Not registered — Agent module list full",
  not_installed = "Not installed",
  not_responding = "Found — not responding",
  ai_update = "Found — AI Core update required (v%s)",
  unlicensed = "Found — not licensed (v%s)",
  unpaired = "Found — SmartBuildOS Agent not paired (v%s)",
  cloud_offline = "Found — reporting, cloud offline (v%s)",
  reporting = "Found — reporting (v%s)",
  passive_installed = "Installed — reports through %s",
}
--- In spec order.
M.VALUES = {
  M.V.searching,
  M.V.no_agent,
  M.V.agent_update,
  M.V.registry_full,
  M.V.not_installed,
  M.V.not_responding,
  M.V.ai_update,
  M.V.unlicensed,
  M.V.unpaired,
  M.V.cloud_offline,
  M.V.reporting,
  M.V.passive_installed,
}

local function validVersion(s)
  return type(s) == "string" and #s >= 1 and #s <= 32 and s:match("^[%w%._%-]+$") ~= nil
end

local function rootLabelAllowed(label)
  for _, l in pairs(M.LABELS) do
    if l == label then
      return true
    end
  end
  return false
end

--- Whether `text` is one of the closed values (a template is matched with
--- its slot: a bounded version, or a root label from LABELS).
function M.isValue(text)
  if type(text) ~= "string" then
    return false
  end
  for _, v in ipairs(M.VALUES) do
    local at = v:find("%s", 1, true)
    if at == nil then
      if text == v then
        return true
      end
    else
      local head, tail = v:sub(1, at - 1), v:sub(at + 2)
      if #text > #head + #tail and text:sub(1, #head) == head and text:sub(#text - #tail + 1) == tail then
        local slot = text:sub(#head + 1, #text - #tail)
        if v == M.V.passive_installed then
          if rootLabelAllowed(slot) then
            return true
          end
        elseif validVersion(slot) then
          return true
        end
      end
    end
  end
  return false
end

-- ── bounds (spec §3.2, §3.3) ─────────────────────────────────────────────────

M.LIMITS = {
  args_bytes = 16 * 1024, -- any report
  describe_bytes = 8 * 1024, -- what AI Core keeps per instance
  name = 64,
  version = 32,
  sku = 40,
  file = 64,
  summary = 200,
  controls = 32,
  control_id = 48,
  control_label = 64,
  vocabulary = 24,
  vocabulary_len = 40,
  queries = 8,
  actions = 8,
  params = 6,
  description = 200,
  title = 80,
  param_values = 16,
  param_value_len = 40,
  string_param = 64,
  facts = 32,
  fact_len = 120,
  event_text = 240,
  event_data = 16,
  diagnostic_text = 240,
  result_text = 240,
  query_result_bytes = 24 * 1024,
  query_depth = 3,
  query_string = 1024,
}

--- Per-module client-side rates (per rolling minute), and the describe
--- same-hash spacing.
M.RATES = { state = 6, event = 10, diagnostic = 6 }
M.DESCRIBE_SAME_HASH_SECONDS = 600
M.BASELINE_SECONDS = 60
M.DISCOVER_RETRY_SECONDS = 30
M.PASSIVE_DEBOUNCE_SECONDS = 5
M.REPORT_TIMEOUT_SECONDS = 10

M.KINDS = { describe = true, state = true, event = true, diagnostic = true }
M.CLASSES = {
  light = true,
  shade = true,
  climate = true,
  lock = true,
  security = true,
  media = true,
  sensor = true,
  power = true,
  network = true,
  scene = true,
  mode = true,
  weather = true,
  other = true,
}
M.SEVERITIES = { info = true, warning = true, fault = true }
M.RISKS = { low = true, medium = true, high = true }
M.PARAM_TYPES = { enum = true, integer = true, number = true, boolean = true, string = true }
M.AI_STATES = { ready = true, unlicensed = true, agent_unpaired = true, cloud_unreachable = true }
M.REASONS = { rate_limited = true, invalid = true, unsupported_version = true, too_large = true }

local TIMERS = {
  state = "SbosAiReportState",
  baseline = "SbosAiReportBaseline",
  discover = "SbosAiReportDiscover",
  passive = "SbosAiReportPassive",
}

-- ── text and value helpers ──────────────────────────────────────────────────

--- Strips control and bidi characters, trims, and cuts to `max` BYTES
--- between UTF-8 characters (a byte bound is never looser than the same
--- bound in characters).
function M.clean(s, max)
  if s == nil then
    return ""
  end
  s = tostring(s)
  s = s:gsub("\226\128[\142\143\170-\174]", "") -- U+200E/200F, U+202A-202E
  s = s:gsub("\226\129[\166-\169]", "") -- U+2066-2069
  s = s:gsub("\216\156", "") -- U+061C
  s = s:gsub("\194[\128-\159]", "") -- C1 controls
  s = s:gsub("[%z\1-\31\127]", " ")
  s = s:gsub("^%s+", ""):gsub("%s+$", "")
  if max ~= nil and #s > max then
    s = s:sub(1, max)
    local i = #s
    while i > 0 do
      local b = s:byte(i)
      if b < 128 or b >= 192 then
        break
      end
      i = i - 1
    end
    if i > 0 then
      local lead = s:byte(i)
      local need = lead >= 240 and 4 or lead >= 224 and 3 or lead >= 192 and 2 or 1
      if #s - i + 1 < need then
        s = s:sub(1, i - 1)
      end
    end
  end
  return s
end

local function now()
  return (M._clock or os.time)()
end

--- `at` of an event / diagnostic: epoch seconds, a whole number (the
--- driver_reports wire takes epoch seconds end to end).
local function epochNow()
  return math.floor(now())
end

local function finite(n)
  return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end

local function keyOk(k, maxLen)
  return type(k) == "string" and #k <= (maxLen or 48) and k:match("^[a-z][a-z0-9_]*$") ~= nil
end

local function codeOk(s)
  return type(s) == "string" and #s >= 1 and #s <= 48 and s:match("^[a-z0-9_%.]+$") ~= nil
end

local function closedKeys(t, allowed)
  for k in pairs(t) do
    if not allowed[k] then
      return false
    end
  end
  return true
end

local function isArray(t)
  if type(t) ~= "table" then
    return false
  end
  local n = 0
  for k in pairs(t) do
    if type(k) ~= "number" then
      return false
    end
    n = n + 1
  end
  return n == #t
end

local function encode(v)
  local ok, out = pcall(function()
    return JSON:encode(v)
  end)
  return ok and out or nil
end

--- Canonical text of a value (sorted keys), for the hash.
local function canonical(v)
  local t = type(v)
  if t == "string" then
    return string.format("%q", v)
  elseif t == "number" then
    return string.format("%.14g", v)
  elseif t == "boolean" then
    return v and "true" or "false"
  elseif t == "table" then
    if isArray(v) then
      local parts = {}
      for i = 1, #v do
        parts[i] = canonical(v[i])
      end
      return "[" .. table.concat(parts, ",") .. "]"
    end
    local keys = {}
    for k in pairs(v) do
      keys[#keys + 1] = tostring(k)
    end
    table.sort(keys)
    local parts = {}
    for i, k in ipairs(keys) do
      parts[i] = string.format("%q", k) .. ":" .. canonical(v[k])
    end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  return "null"
end

--- A 64-bit, NON-cryptographic fingerprint (two 32-bit polynomial hashes
--- over the canonical text) as 16 hex characters. It detects that a
--- declaration changed; it is not a MAC. Pure arithmetic (Lua 5.1, no bit
--- library), so every controller computes the same value.
function M.hash(value)
  local s = canonical(value)
  local h1, h2 = 7, 11
  for i = 1, #s do
    local b = s:byte(i)
    h1 = (h1 * 31 + b) % 4294967291
    h2 = (h2 * 257 + b) % 4294967279
  end
  return string.format("%08x%08x", h1, h2)
end

-- ── declarations (QueryDecl / ActionDecl / Param) ───────────────────────────

local PARAM_KEYS = { name = true, type = true, values = true, min = true, max = true, max_len = true, required = true }
local QUERY_KEYS = { id = true, description = true, params = true }
local ACTION_KEYS = { id = true, title = true, description = true, params = true, risk = true }

local function boundedText(s, max)
  return type(s) == "string" and #s <= max and M.clean(s, max) == s
end

--- Validates one Param; returns a normalised copy or nil, reason.
function M.validateParam(p)
  if type(p) ~= "table" or not closedKeys(p, PARAM_KEYS) then
    return nil, "param_keys"
  end
  if not keyOk(p.name, 32) then
    return nil, "param_name"
  end
  if not M.PARAM_TYPES[p.type] then
    return nil, "param_type"
  end
  if p.required ~= nil and type(p.required) ~= "boolean" then
    return nil, "param_required"
  end
  local out = { name = p.name, type = p.type, required = p.required == true }
  if p.type == "enum" then
    if not isArray(p.values) or #p.values < 1 or #p.values > M.LIMITS.param_values then
      return nil, "param_values"
    end
    out.values = {}
    for i, v in ipairs(p.values) do
      if not boundedText(v, M.LIMITS.param_value_len) or v == "" then
        return nil, "param_values"
      end
      out.values[i] = v
    end
  elseif p.values ~= nil then
    return nil, "param_values"
  end
  if p.type == "integer" or p.type == "number" then
    if p.min ~= nil and not finite(p.min) or p.max ~= nil and not finite(p.max) then
      return nil, "param_range"
    end
    if p.min ~= nil and p.max ~= nil and p.min > p.max then
      return nil, "param_range"
    end
    out.min, out.max = p.min, p.max
  elseif p.min ~= nil or p.max ~= nil then
    return nil, "param_range"
  end
  if p.type == "string" then
    if p.max_len ~= nil then
      if
        type(p.max_len) ~= "number"
        or p.max_len ~= math.floor(p.max_len)
        or p.max_len < 1
        or p.max_len > M.LIMITS.string_param
      then
        return nil, "param_max_len"
      end
    end
    out.max_len = p.max_len
  elseif p.max_len ~= nil then
    return nil, "param_max_len"
  end
  return out
end

local function validateParamList(list)
  if list == nil then
    return {}
  end
  if not isArray(list) or #list > M.LIMITS.params then
    return nil, "params"
  end
  local out, seen = {}, {}
  for i, p in ipairs(list) do
    local norm, why = M.validateParam(p)
    if norm == nil then
      return nil, why
    end
    if seen[norm.name] then
      return nil, "param_duplicate"
    end
    seen[norm.name] = true
    out[i] = norm
  end
  return out
end

--- Validates a QueryDecl; returns a normalised copy or nil, reason.
function M.validateQuery(decl)
  if type(decl) ~= "table" or not closedKeys(decl, QUERY_KEYS) then
    return nil, "query_keys"
  end
  if not keyOk(decl.id, 48) then
    return nil, "query_id"
  end
  -- Required, non-empty text: AI Core (and the platform) refuse a describe
  -- with an empty description, which would keep this driver's whole
  -- describe from ever reaching the cloud (KI-47).
  if not boundedText(decl.description, M.LIMITS.description) or decl.description == "" then
    return nil, "query_description"
  end
  local params, why = validateParamList(decl.params)
  if params == nil then
    return nil, why
  end
  return { id = decl.id, description = decl.description, params = params }
end

--- Validates an ActionDecl; returns a normalised copy or nil, reason.
function M.validateAction(decl)
  if type(decl) ~= "table" or not closedKeys(decl, ACTION_KEYS) then
    return nil, "action_keys"
  end
  if not keyOk(decl.id, 48) then
    return nil, "action_id"
  end
  if not boundedText(decl.title, M.LIMITS.title) or decl.title == "" then
    return nil, "action_title"
  end
  if not boundedText(decl.description, M.LIMITS.description) or decl.description == "" then
    return nil, "action_description"
  end
  if not M.RISKS[decl.risk] then
    return nil, "action_risk"
  end
  local params, why = validateParamList(decl.params)
  if params == nil then
    return nil, why
  end
  return { id = decl.id, title = decl.title, description = decl.description, params = params, risk = decl.risk }
end

--- Validates incoming params against a declaration's Param list. Unknown
--- keys, a missing required param, a wrong type, a value outside the enum
--- or range, and a string over its bound or carrying control/bidi
--- characters are all refused (never repaired). Returns a copy or nil, why.
function M.validateParams(decls, params)
  if params == nil then
    params = {}
  end
  if type(params) ~= "table" then
    return nil, "params_not_object"
  end
  local byName = {}
  for _, d in ipairs(decls or {}) do
    byName[d.name] = d
  end
  for k in pairs(params) do
    if type(k) ~= "string" or byName[k] == nil then
      return nil, "unknown_param"
    end
  end
  local out = {}
  for _, d in ipairs(decls or {}) do
    local v = params[d.name]
    if v == nil then
      if d.required then
        return nil, "missing_param"
      end
    else
      local t = d.type
      if t == "enum" then
        local hit = false
        for _, allowed in ipairs(d.values) do
          if v == allowed then
            hit = true
          end
        end
        if type(v) ~= "string" or not hit then
          return nil, "bad_enum"
        end
      elseif t == "integer" or t == "number" then
        if not finite(v) or (t == "integer" and v ~= math.floor(v)) then
          return nil, "bad_number"
        end
        if d.min ~= nil and v < d.min or d.max ~= nil and v > d.max then
          return nil, "out_of_range"
        end
      elseif t == "boolean" then
        if type(v) ~= "boolean" then
          return nil, "bad_boolean"
        end
      elseif t == "string" then
        if not boundedText(v, d.max_len or M.LIMITS.string_param) then
          return nil, "bad_string"
        end
      end
      out[d.name] = v
    end
  end
  return out
end

-- ── module state ────────────────────────────────────────────────────────────

local S

local function fresh()
  return {
    mode = nil, -- "start" | "attach" | "passive"
    client = nil,
    file = nil,
    moduleId = nil,
    property = M.PROPERTY,
    sku = "",
    summary = nil,
    controls = {},
    vocabulary = {},
    queries = {}, -- id -> { decl, handler }
    actions = {},
    manifest = nil,
    tried = false, -- registration attempted
    agentMissing = false,
    registryFull = false,
    policyRefused = false, -- the Agent has no ai_core.report row (pre-D1 Agent)
    directoryKnown = false,
    discovering = false,
    discoverAgain = false,
    target = nil, -- { instance_id, version, verified, stale, hasReport }
    aiState = nil,
    aiStateSource = nil, -- "answer" | "directory"
    lastAccepted = nil,
    unsupportedVersion = false,
    notResponding = false,
    describeHash = nil, -- last describe hash ACCEPTED by AI Core
    describeSentHash = nil,
    describeAt = nil,
    describeInFlight = false,
    describeRefusedHash = nil, -- AI Core refused this describe (invalid / too_large)
    facts = {}, -- the driver's own facts (state())
    lastStateSent = nil,
    windows = { state = {}, event = {}, diagnostic = {} },
    passiveInstalled = nil,
    rootLabel = nil,
    value = nil,
    counters = {
      sent = 0,
      accepted = 0,
      refused = 0,
      suppressed = 0, -- not sent: AI Core absent / not reportable
      rate_limited = 0, -- dropped by the client-side rate bound
      invalid = 0, -- refused by the client-side shape / size bound
      queries = 0,
      actions = 0,
      requests_refused = 0,
      values_refused = 0,
      discovers = 0,
      describe_requested = 0, -- describes re-sent because AI Core said need_describe
    },
  }
end
S = fresh()

-- ── the property ────────────────────────────────────────────────────────────

--- Paints `text` when it is a closed value and differs from the last one.
--- Anything else is refused (counted) and never reaches Composer.
local function paint(text)
  if not M.isValue(text) then
    S.counters.values_refused = S.counters.values_refused + 1
    return false
  end
  if S.value == text then
    return true
  end
  S.value = text
  log:debug("AI Core property: %s", text)
  if type(Properties) == "table" and Properties[S.property] ~= nil then
    pcall(UpdateProperty, S.property, text)
  end
  return true
end
M._paint = paint

local function agentUpdateRequired()
  local c = S.client
  if c == nil then
    return false
  end
  if S.policyRefused or c.agentUpdateRequired() then
    return true
  end
  return c.isRegistered() and (tonumber(c.protocol()) or 0) < 2
end

local function ver()
  return S.target and S.target.version or "unknown"
end

--- The closed-list value for the current facts (spec §3.6, in precedence).
function M.computeValue()
  if S.mode == "passive" then
    if S.passiveInstalled == nil then
      return M.V.searching
    end
    if S.passiveInstalled then
      return string.format(M.V.passive_installed, S.rootLabel)
    end
    return M.V.not_installed
  end
  if S.mode == nil or not S.tried then
    return M.V.searching
  end
  if S.agentMissing then
    return M.V.no_agent
  end
  if agentUpdateRequired() then
    return M.V.agent_update
  end
  if S.registryFull then
    return M.V.registry_full
  end
  if not S.client.isRegistered() or not S.directoryKnown then
    return M.V.searching
  end
  local t = S.target
  if t == nil then
    return M.V.not_installed
  end
  if t.stale or S.notResponding then
    return M.V.not_responding
  end
  if not t.hasReport or S.unsupportedVersion then
    return string.format(M.V.ai_update, ver())
  end
  if S.aiState == "unlicensed" then
    return string.format(M.V.unlicensed, ver())
  end
  if S.aiState == "agent_unpaired" then
    return string.format(M.V.unpaired, ver())
  end
  if S.aiState == "cloud_unreachable" then
    return string.format(M.V.cloud_offline, ver())
  end
  if S.aiState == "ready" and S.lastAccepted then
    return string.format(M.V.reporting, ver())
  end
  -- Found, but no report answered yet.
  return M.V.searching
end

local function repaint()
  return paint(M.computeValue())
end

-- ── sending ─────────────────────────────────────────────────────────────────

--- Whether a report may be sent now: a bus root, registered at v2, a live
--- ai_core that advertises ai_core.report v1, and an Agent that routes it.
local function reportable()
  if S.mode ~= "start" and S.mode ~= "attach" then
    return false
  end
  if S.agentMissing or S.registryFull or agentUpdateRequired() then
    return false
  end
  if not S.client.isRegistered() then
    return false
  end
  local t = S.target
  return t ~= nil and not t.stale and t.hasReport and not S.unsupportedVersion
end
M.reportable = reportable

local function windowTake(kind)
  local w = S.windows[kind]
  local t = now()
  local keep = {}
  for _, at in ipairs(w) do
    if t - at < 60 then
      keep[#keep + 1] = at
    end
  end
  S.windows[kind] = keep
  if #keep >= M.RATES[kind] then
    return false, keep[1] + 60 - t
  end
  keep[#keep + 1] = t
  return true
end

local discover -- forward
local sendDescribe -- forward

local function onAnswer(kind, body, answer)
  if kind == "describe" then
    S.describeInFlight = false
  end
  if answer.status == "ok" then
    S.notResponding = false
    local r = type(answer.result) == "table" and answer.result or {}
    local ai = type(r.ai_core) == "table" and r.ai_core or {}
    -- A refused report (rate_limited / invalid / too_large) never turns the
    -- property to "reporting"; AI Core's own non-ready state always shows.
    if M.AI_STATES[ai.state] and (r.accepted == true or ai.state ~= "ready") then
      S.aiState = ai.state
      S.aiStateSource = "answer"
    end
    if S.target ~= nil and validVersion(ai.version) then
      S.target.version = ai.version
    end
    if r.accepted == true then
      S.counters.accepted = S.counters.accepted + 1
      S.lastAccepted = true
      if kind == "describe" then
        S.describeHash = body.hash
      end
    else
      S.counters.refused = S.counters.refused + 1
      if r.reason == "unsupported_version" then
        S.unsupportedVersion = true
      end
      if kind == "describe" and (r.reason == "invalid" or r.reason == "too_large") then
        -- The same describe would be refused again: need_describe does not
        -- re-send it (a changed describe has a new hash and goes).
        S.describeRefusedHash = body.hash
      end
      -- rate_limited / invalid / too_large leave the property as it is.
    end
    -- AI Core holds no describe for us (it restarted, or never got one):
    -- send it again now (KI-43 closed), unless one is on its way or AI Core
    -- refused this very describe.
    if r.need_describe == true and kind ~= "describe" and not S.describeInFlight and reportable() then
      if M.buildDescribe().hash ~= S.describeRefusedHash then
        S.describeHash = nil
        S.counters.describe_requested = S.counters.describe_requested + 1
        sendDescribe(true)
      end
    end
  else
    S.counters.refused = S.counters.refused + 1
    local code = answer.error_code
    if code == "deadline_exceeded" then
      S.notResponding = true
    elseif code == "not_permitted" then
      -- The Agent has no ai_core.report policy row: it predates it.
      S.policyRefused = true
    elseif code == "unknown_target" or code == "target_unavailable" or code == "capability_not_found" then
      discover()
    end
  end
  repaint()
end

local function send(kind, body)
  if not reportable() then
    S.counters.suppressed = S.counters.suppressed + 1
    return false, "absent"
  end
  local raw = encode(body)
  local cap = kind == "describe" and M.LIMITS.describe_bytes or M.LIMITS.args_bytes
  if raw == nil or #raw > cap then
    S.counters.invalid = S.counters.invalid + 1
    return false, "too_large"
  end
  S.counters.sent = S.counters.sent + 1
  S.client.request(M.AI_CORE_MODULE, M.CAPABILITY, body, {
    timeout = M.REPORT_TIMEOUT_SECONDS,
    retries = 0,
    to_instance = S.target.instance_id,
  }, function(answer)
    onAnswer(kind, body, answer or { status = "error", error_code = "internal_error" })
  end)
  return true
end

local function sortedDecls(map)
  local ids = {}
  for id in pairs(map) do
    ids[#ids + 1] = id
  end
  table.sort(ids)
  local out = {}
  for i, id in ipairs(ids) do
    out[i] = map[id].decl
  end
  return out
end

local function configInfo(key)
  local ok, v = pcall(function()
    return C4:GetDriverConfigInfo(key)
  end)
  if ok and v ~= nil then
    return tostring(v)
  end
  return ""
end

--- The describe summary: the driver's own, else the built-in one for its
--- file, else its label or file name. Never empty (AI Core refuses that).
local function describeSummary(file)
  -- A numeric loop: any of these may be nil, which would stop ipairs.
  local candidates = { S.summary, M.SUMMARIES[file], M.LABELS[file], configInfo("name"), file }
  for i = 1, 5 do
    local c = M.clean(candidates[i], M.LIMITS.summary)
    if c ~= "" then
      return c
    end
  end
  return "SmartBuildOS driver."
end

--- The describe report as it would be sent now (hash included).
function M.buildDescribe()
  local file = S.file or ""
  local d = {
    v = M.REPORT_VERSION,
    kind = "describe",
    driver = {
      name = M.clean(configInfo("name") ~= "" and configInfo("name") or M.LABELS[file] or file, M.LIMITS.name),
      version = M.clean(configInfo("version"), M.LIMITS.version),
      sku = M.clean(S.sku, M.LIMITS.sku),
      file = M.clean(file, M.LIMITS.file),
    },
    summary = describeSummary(file),
    controls = S.controls,
    vocabulary = S.vocabulary,
    queries = sortedDecls(S.queries),
    actions = sortedDecls(S.actions),
  }
  d.hash = M.hash(d)
  return d
end

--- The declaration hash an `ai.action` must carry: the describe hash.
function M.declarationHash()
  return M.buildDescribe().hash
end

--- Sends describe when forced (AI Core appeared, revived or was updated),
--- when the hash changed, or when the same hash was last sent at least
--- 10 minutes ago (so an AI Core that restarted without going stale gets
--- it back at the next directory change after that).
sendDescribe = function(force)
  local d = M.buildDescribe()
  if
    not force
    and (d.hash == S.describeHash or d.hash == S.describeSentHash)
    and S.describeAt ~= nil
    and now() - S.describeAt < M.DESCRIBE_SAME_HASH_SECONDS
  then
    return false, "unchanged"
  end
  S.describeInFlight = true
  local ok, why = send("describe", d)
  if ok then
    S.describeSentHash = d.hash
    S.describeAt = now()
  else
    S.describeInFlight = false
  end
  return ok, why
end

local function baselineFacts()
  local f = {}
  if type(Properties) == "table" and Properties["Driver Status"] ~= nil then
    f.driver_status = M.clean(Properties["Driver Status"], M.LIMITS.fact_len)
  end
  local ok, label = pcall(license.statusLabel)
  if ok and label ~= nil then
    f.license = M.clean(label, M.LIMITS.fact_len)
  end
  return f
end

local function mergedFacts()
  local out = {}
  for k, v in pairs(S.facts) do
    out[k] = v
  end
  for k, v in pairs(baselineFacts()) do
    out[k] = v
  end
  return out
end

local function flushState(force)
  CancelTimer(TIMERS.state)
  if not reportable() then
    return false, "absent"
  end
  local facts = mergedFacts()
  local sig = canonical(facts)
  if not force and sig == S.lastStateSent then
    return false, "unchanged"
  end
  local ok, wait = windowTake("state")
  if not ok then
    -- Coalesced: the latest facts go out when the window has room.
    SetTimer(TIMERS.state, math.max(1, wait) * 1000, function()
      flushState(true)
    end)
    return false, "coalesced"
  end
  S.lastStateSent = sig
  return send("state", { v = M.REPORT_VERSION, kind = "state", facts = facts })
end

local function armBaseline()
  SetTimer(TIMERS.baseline, M.BASELINE_SECONDS * 1000, function()
    if reportable() then
      flushState(false)
    else
      CancelTimer(TIMERS.baseline)
    end
  end, true)
end

-- ── discovery ───────────────────────────────────────────────────────────────

local function hasReportCap(row)
  for _, c in ipairs(type(row.capabilities) == "table" and row.capabilities or {}) do
    if
      type(c) == "table"
      and c.id == M.CAPABILITY
      and (tonumber(c.version) or 0) >= M.CAPABILITY_VERSION
      and (c.kind == nil or c.kind == "request")
    then
      return true
    end
  end
  return false
end

--- The ai_core row to report to: live v2 first, verified first.
local function pickRow(modules)
  local best, bestScore = nil, -1
  for _, row in ipairs(type(modules) == "table" and modules or {}) do
    if type(row) == "table" and row.module_id == M.AI_CORE_MODULE then
      local score = 0
      if row.stale ~= true then
        score = score + 4
      end
      if (tonumber(row.protocol) or 1) >= 2 then
        score = score + 2
      end
      if row.verified == true then
        score = score + 1
      end
      if score > bestScore then
        best, bestScore = row, score
      end
    end
  end
  return best
end

local function onDirectory(dir, code)
  S.discovering = false
  if code ~= "ok" or type(dir) ~= "table" then
    if code ~= "incompatible_protocol" then
      -- One bounded retry; a directory push re-discovers anyway.
      SetTimer(TIMERS.discover, M.DISCOVER_RETRY_SECONDS * 1000, function()
        discover()
      end)
    end
    repaint()
    return
  end
  if S.discoverAgain then
    S.discoverAgain = false
    discover()
  end
  S.directoryKnown = true
  local row = pickRow(dir.modules)
  local prev = S.target
  if row == nil then
    S.target = nil
    CancelTimer(TIMERS.baseline)
    CancelTimer(TIMERS.state)
    repaint()
    return
  end
  local t = {
    instance_id = tostring(row.instance_id or ""),
    version = validVersion(row.driver_version) and row.driver_version or "unknown",
    verified = row.verified == true,
    stale = row.stale == true or (tonumber(row.protocol) or 1) < 2,
    hasReport = hasReportCap(row),
  }
  local changed = prev == nil
    or prev.instance_id ~= t.instance_id
    or prev.version ~= t.version
    or prev.stale ~= t.stale
    or prev.hasReport ~= t.hasReport
  if changed then
    -- A new, updated or revived AI Core: everything it told us is void.
    S.aiState, S.aiStateSource = nil, nil
    S.lastAccepted = nil
    S.unsupportedVersion = false
    S.notResponding = false
    S.describeHash = nil
    S.describeRefusedHash = nil
    S.lastStateSent = nil
  elseif prev ~= nil and validVersion(prev.version) and t.version == "unknown" then
    t.version = prev.version
  end
  if row.status == "unlicensed" then
    S.aiState, S.aiStateSource = "unlicensed", "directory"
  elseif S.aiStateSource == "directory" then
    S.aiState, S.aiStateSource = nil, nil
  end
  S.target = t
  repaint()
  if reportable() then
    -- describe when AI Core appeared / changed (or the same one is due);
    -- the latest state on every directory change (spec: latest wins,
    -- re-sent on change or directory change), within the 6/min window.
    armBaseline()
    sendDescribe(changed)
    flushState(true)
  else
    CancelTimer(TIMERS.baseline)
    CancelTimer(TIMERS.state)
  end
end

discover = function()
  if S.mode ~= "start" and S.mode ~= "attach" then
    return false
  end
  local c = S.client
  if not c.isRegistered() or agentUpdateRequired() then
    return false
  end
  if S.discovering then
    S.discoverAgain = true
    return false
  end
  CancelTimer(TIMERS.discover)
  S.discovering = true
  S.counters.discovers = S.counters.discovers + 1
  c.discover({ module_id = M.AI_CORE_MODULE }, onDirectory)
  return true
end

-- ── callbacks a bus driver forwards (start wires them itself) ───────────────

--- moduleclient onRegistered(reply).
function M.onRegistered(reply)
  if S.mode ~= "start" and S.mode ~= "attach" then
    return
  end
  reply = type(reply) == "table" and reply or {}
  S.tried = true
  S.agentMissing = false
  if tostring(reply.ok) == "true" then
    S.registryFull = false
    S.policyRefused = false
    S.directoryKnown = false
    discover()
  else
    S.registryFull = reply.reason == "registry_full"
    S.target = nil
    S.directoryKnown = false
  end
  repaint()
end

--- moduleclient onDirectoryChanged(version).
function M.onDirectoryChanged()
  discover()
  repaint()
end

--- moduleclient onAgentState(agent, why).
function M.onAgentState(_, why)
  if S.mode ~= "start" and S.mode ~= "attach" then
    return
  end
  if why == "no_agent" then
    S.tried = true
    S.agentMissing = true
    S.target = nil
    S.directoryKnown = false
  elseif why == "hello" then
    -- The Agent restarted; we re-register and re-discover.
    S.agentMissing = false
    S.target = nil
    S.directoryKnown = false
    S.discovering = false
  end
  repaint()
end

-- ── serving ai.query / ai.action ────────────────────────────────────────────

local QUERY_ARGS = { query_id = true, params = true }
local ACTION_ARGS = { action_id = true, params = true, ai_action_id = true, declaration_hash = true }

local function boundData(v, depth)
  local t = type(v)
  if t == "string" then
    return M.clean(v, M.LIMITS.query_string)
  elseif t == "boolean" then
    return v
  elseif t == "number" then
    if finite(v) then
      return v
    end
    return nil
  elseif t == "table" then
    if depth >= M.LIMITS.query_depth then
      return nil
    end
    local out = {}
    for k, x in pairs(v) do
      if type(k) ~= "number" and not (type(k) == "string" and #k <= 48) then
        return nil
      end
      local y = boundData(x, depth + 1)
      if y == nil then
        return nil
      end
      out[type(k) == "string" and M.clean(k, 48) or k] = y
    end
    return out
  end
  return nil
end

local function refuse(respond, code, reason)
  S.counters.requests_refused = S.counters.requests_refused + 1
  respond("error", { ok = false, reason = reason }, code)
end

local function serveQuery(req, respond)
  if req.from_module_id ~= M.AI_CORE_MODULE then
    return refuse(respond, "not_permitted", "requester")
  end
  local args = req.args
  if type(args) ~= "table" or not closedKeys(args, QUERY_ARGS) then
    return refuse(respond, "invalid_args", "invalid_args")
  end
  local q = type(args.query_id) == "string" and S.queries[args.query_id] or nil
  if q == nil then
    return refuse(respond, "invalid_args", "unknown_query")
  end
  local params, why = M.validateParams(q.decl.params, args.params)
  if params == nil then
    return refuse(respond, "invalid_args", why)
  end
  S.counters.queries = S.counters.queries + 1
  local ok, data, reason = pcall(q.handler, params, req)
  if not ok then
    return refuse(respond, "internal_error", "failed")
  end
  if data == nil then
    respond("ok", { ok = false, reason = codeOk(reason) and reason or "failed" })
    return
  end
  if type(data) ~= "table" then
    return refuse(respond, "internal_error", "data_invalid")
  end
  local bounded = boundData(data, 0)
  if bounded == nil then
    return refuse(respond, "internal_error", "data_invalid")
  end
  local raw = encode({ ok = true, data = bounded })
  if raw == nil or #raw > M.LIMITS.query_result_bytes then
    return refuse(respond, "payload_too_large", "too_large")
  end
  respond("ok", { ok = true, data = bounded })
end

local function serveAction(req, respond)
  if req.from_module_id ~= M.AI_CORE_MODULE then
    return refuse(respond, "not_permitted", "requester")
  end
  -- Only an AI Core the Agent verified (identity binding) may invoke an
  -- action: the requester must be the ai_core instance of our directory
  -- view, marked verified.
  local t = S.target
  if t == nil or not t.verified or tostring(req.from_instance_id or "") ~= t.instance_id then
    return refuse(respond, "not_permitted", "requester_unverified")
  end
  local args = req.args
  if type(args) ~= "table" or not closedKeys(args, ACTION_ARGS) then
    return refuse(respond, "invalid_args", "invalid_args")
  end
  if type(args.ai_action_id) ~= "string" or not args.ai_action_id:match("^[%w][%w%-_:%.]*$") or #args.ai_action_id > 128 then
    return refuse(respond, "invalid_args", "ai_action_id")
  end
  if type(args.declaration_hash) ~= "string" or args.declaration_hash ~= M.declarationHash() then
    -- What was approved is not what this driver declares now.
    return refuse(respond, "not_permitted", "declaration_changed")
  end
  local a = type(args.action_id) == "string" and S.actions[args.action_id] or nil
  if a == nil then
    return refuse(respond, "invalid_args", "unknown_action")
  end
  local params, why = M.validateParams(a.decl.params, args.params)
  if params == nil then
    return refuse(respond, "invalid_args", why)
  end
  S.counters.actions = S.counters.actions + 1
  local ok, text, reason = pcall(a.handler, params, req)
  if not ok then
    return refuse(respond, "internal_error", "failed")
  end
  if text == nil or text == false then
    respond("ok", { ok = false, result_text = M.clean(reason or "failed", M.LIMITS.result_text) })
    return
  end
  respond("ok", { ok = true, result_text = M.clean(text, M.LIMITS.result_text) })
end
M._serveQuery = serveQuery
M._serveAction = serveAction

local function wireHandlers()
  S.client.onRequest(M.QUERY_CAPABILITY, serveQuery)
  S.client.onRequest(M.ACTION_CAPABILITY, serveAction)
end

--- The manifest capabilities this driver needs: `base` (copied) plus
--- ai.query / ai.action when it declares any. A driver in attach mode puts
--- this list in its own manifest (declare before its setup).
function M.capabilities(base)
  local out = {}
  for _, c in ipairs(base or {}) do
    out[#out + 1] = c
  end
  if next(S.queries) ~= nil then
    out[#out + 1] = { id = M.QUERY_CAPABILITY, version = 1, kind = "request" }
  end
  if next(S.actions) ~= nil then
    out[#out + 1] = { id = M.ACTION_CAPABILITY, version = 1, kind = "request" }
  end
  return out
end

--- After a declaration change: start mode re-registers when the advertised
--- capabilities changed; any mode re-sends describe when reporting.
local function declarationsChanged(capsBefore)
  if S.mode == "start" and S.manifest ~= nil then
    local caps = M.capabilities()
    S.manifest.capabilities = caps
    if #caps ~= capsBefore and S.client.isRegistered() then
      S.client.register()
      return
    end
  end
  if reportable() then
    sendDescribe(false)
  end
end

local function declare(kind, decl, handler, opts)
  if type(handler) ~= "function" then
    return false, "handler"
  end
  if opts ~= nil and (type(opts) ~= "table" or not closedKeys(opts, { replace = true })) then
    return false, "options"
  end
  local norm, why
  if kind == "query" then
    norm, why = M.validateQuery(decl)
  else
    norm, why = M.validateAction(decl)
  end
  if norm == nil then
    S.counters.invalid = S.counters.invalid + 1
    return false, why
  end
  local map = kind == "query" and S.queries or S.actions
  local existing = map[norm.id]
  if existing ~= nil and canonical(existing.decl) ~= canonical(norm) and not (opts and opts.replace == true) then
    -- A second, DIFFERENT declaration under an id already declared is a
    -- mistake (two queries named alike), not a silent replacement: refused,
    -- the first one stays. Re-declaring the same declaration only swaps the
    -- handler; changing one on purpose passes { replace = true }.
    S.counters.invalid = S.counters.invalid + 1
    return false, kind .. "_duplicate"
  end
  local limit = kind == "query" and M.LIMITS.queries or M.LIMITS.actions
  local count = 0
  for id in pairs(map) do
    if id ~= norm.id then
      count = count + 1
    end
  end
  if count >= limit then
    return false, "too_many"
  end
  local capsBefore = #M.capabilities()
  local previous = map[norm.id]
  map[norm.id] = { decl = norm, handler = handler }
  local raw = encode(M.buildDescribe())
  if raw == nil or #raw > M.LIMITS.describe_bytes then
    map[norm.id] = previous
    return false, "too_large"
  end
  declarationsChanged(capsBefore)
  return true
end

--- Declares a read-only query. handler(params, req) returns a data table
--- (scalars and tables, at most 3 deep, <= 24 KB encoded), or nil, reason.
--- An id already declared with a different declaration is refused
--- (`query_duplicate`) unless opts = { replace = true }.
function M.declareQuery(decl, handler, opts)
  return declare("query", decl, handler, opts)
end

--- Declares an action. It never runs without a person's approval in the
--- platform; here it runs only for a verified AI Core with the current
--- declaration hash. handler(params, req) returns result text (<= 240), or
--- nil, reason. An id already declared with a different declaration is
--- refused (`action_duplicate`) unless opts = { replace = true }.
function M.declareAction(decl, handler, opts)
  return declare("action", decl, handler, opts)
end

-- ── reports ─────────────────────────────────────────────────────────────────

local DESCRIBE_KEYS = { summary = true, controls = true, vocabulary = true }

--- Sets the richer describe fields: { summary?, controls?, vocabulary? }.
--- Re-sends describe when reporting and the hash changed.
function M.describe(fields)
  fields = fields or {}
  if type(fields) ~= "table" or not closedKeys(fields, DESCRIBE_KEYS) then
    S.counters.invalid = S.counters.invalid + 1
    return false, "describe_keys"
  end
  local controls, vocabulary = S.controls, S.vocabulary
  if fields.controls ~= nil then
    if not isArray(fields.controls) or #fields.controls > M.LIMITS.controls then
      S.counters.invalid = S.counters.invalid + 1
      return false, "controls"
    end
    controls = {}
    local seenIds = {}
    for i, c in ipairs(fields.controls) do
      if
        type(c) ~= "table"
        or not closedKeys(c, { id = true, label = true, class = true })
        or not M.CLASSES[c.class]
        or M.clean(c.id, M.LIMITS.control_id) == ""
      then
        S.counters.invalid = S.counters.invalid + 1
        return false, "control"
      end
      local id = M.clean(c.id, M.LIMITS.control_id)
      if seenIds[id] then
        -- AI Core refuses a describe with two controls of one id (the
        -- whole describe), so the helper refuses it first.
        S.counters.invalid = S.counters.invalid + 1
        return false, "control_duplicate"
      end
      seenIds[id] = true
      local label = M.clean(c.label, M.LIMITS.control_label)
      controls[i] = {
        id = id,
        -- An empty label would make AI Core refuse the describe: the id stands in.
        label = label ~= "" and label or M.clean(id, M.LIMITS.control_label),
        class = c.class,
      }
    end
  end
  if fields.vocabulary ~= nil then
    if not isArray(fields.vocabulary) or #fields.vocabulary > M.LIMITS.vocabulary then
      S.counters.invalid = S.counters.invalid + 1
      return false, "vocabulary"
    end
    vocabulary = {}
    for _, w in ipairs(fields.vocabulary) do
      -- An empty word is dropped, never sent (AI Core refuses empty text).
      local word = M.clean(w, M.LIMITS.vocabulary_len)
      if word ~= "" then
        vocabulary[#vocabulary + 1] = word
      end
    end
  end
  local summary = S.summary
  if fields.summary ~= nil then
    summary = M.clean(fields.summary, M.LIMITS.summary)
    if summary == "" then
      -- Passed explicitly but empty: refused (the built-in default stays).
      S.counters.invalid = S.counters.invalid + 1
      return false, "summary"
    end
  end
  local before = { S.summary, S.controls, S.vocabulary }
  S.summary = summary
  S.controls, S.vocabulary = controls, vocabulary
  local raw = encode(M.buildDescribe())
  if raw == nil or #raw > M.LIMITS.describe_bytes then
    S.summary, S.controls, S.vocabulary = before[1], before[2], before[3]
    S.counters.invalid = S.counters.invalid + 1
    return false, "too_large"
  end
  if reportable() then
    sendDescribe(false)
  end
  return true
end

--- The driver's current facts (replaces the previous set): <= 30 keys
--- (`driver_status` and `license` are the helper's baseline), key
--- ^[a-z][a-z0-9_]{0,47}$, value string (<= 120) | number | boolean.
--- Coalesced, at most 6 state reports a minute, only when changed.
function M.state(facts)
  if type(facts) ~= "table" then
    S.counters.invalid = S.counters.invalid + 1
    return false, "facts"
  end
  local out, n = {}, 0
  for k, v in pairs(facts) do
    n = n + 1
    if not keyOk(k, 48) or k == "driver_status" or k == "license" then
      S.counters.invalid = S.counters.invalid + 1
      return false, "fact_key"
    end
    if type(v) == "string" then
      out[k] = M.clean(v, M.LIMITS.fact_len)
    elseif type(v) == "boolean" or finite(v) then
      out[k] = v
    else
      S.counters.invalid = S.counters.invalid + 1
      return false, "fact_value"
    end
  end
  if n > M.LIMITS.facts - 2 then
    S.counters.invalid = S.counters.invalid + 1
    return false, "too_many_facts"
  end
  S.facts = out
  if not reportable() then
    S.counters.suppressed = S.counters.suppressed + 1
    return false, "absent"
  end
  return flushState(false)
end

local function scalarData(data)
  if data == nil then
    return {}
  end
  if type(data) ~= "table" then
    return nil
  end
  local out, n = {}, 0
  for k, v in pairs(data) do
    n = n + 1
    if n > M.LIMITS.event_data or not keyOk(k, 48) then
      return nil
    end
    if type(v) == "string" then
      out[k] = M.clean(v, M.LIMITS.fact_len)
    elseif type(v) == "boolean" or finite(v) then
      out[k] = v
    else
      return nil
    end
  end
  return out
end

--- One event: type ^[a-z0-9_.]{1,48}$, text <= 240, data <= 16 scalar keys.
--- At most 10 a minute; lossy by contract (dropped while AI Core is absent).
function M.event(eventType, text, data)
  local d = scalarData(data)
  if not codeOk(eventType) or d == nil then
    S.counters.invalid = S.counters.invalid + 1
    return false, "invalid"
  end
  if not reportable() then
    S.counters.suppressed = S.counters.suppressed + 1
    return false, "absent"
  end
  if not windowTake("event") then
    S.counters.rate_limited = S.counters.rate_limited + 1
    return false, "rate_limited"
  end
  return send("event", {
    v = M.REPORT_VERSION,
    kind = "event",
    type = eventType,
    text = M.clean(text, M.LIMITS.event_text),
    data = d,
    at = epochNow(),
  })
end

--- One diagnostic: severity info|warning|fault, code ^[a-z0-9_.]{1,48}$,
--- text <= 240. At most 6 a minute; lossy by contract.
function M.diagnostic(severity, code, text)
  if not M.SEVERITIES[severity] or not codeOk(code) then
    S.counters.invalid = S.counters.invalid + 1
    return false, "invalid"
  end
  if not reportable() then
    S.counters.suppressed = S.counters.suppressed + 1
    return false, "absent"
  end
  if not windowTake("diagnostic") then
    S.counters.rate_limited = S.counters.rate_limited + 1
    return false, "rate_limited"
  end
  return send("diagnostic", {
    v = M.REPORT_VERSION,
    kind = "diagnostic",
    severity = severity,
    code = code,
    text = M.clean(text, M.LIMITS.diagnostic_text),
    at = epochNow(),
  })
end

-- ── entry modes ─────────────────────────────────────────────────────────────

local function suppressDebug()
  -- The vendored ExecuteCommand prints every param at debug level; module
  -- frames carry this module's token and report bodies. Never printed.
  EC.suppressDebug = EC.suppressDebug or {}
  for name in pairs(EC) do
    if type(name) == "string" and name:find("^SBOS_MODULE_") then
      EC.suppressDebug[name] = true
    end
  end
end

--- The driver's own .c4z file name when the driver does not pass `file`:
--- DC_FILENAME (set only in the DriverCentral variant) or, in the OSS
--- variant every release is built from, the first DRIVER_FILENAMES entry
--- (the `--#ifdef DRIVERCENTRAL` block that sets DC_FILENAME is removed by
--- the OSS preprocessor, so DC_FILENAME alone is nil in a shipped build).
local function defaultFile()
  if type(DC_FILENAME) == "string" and DC_FILENAME ~= "" then
    return DC_FILENAME
  end
  if type(DRIVER_FILENAMES) == "table" and type(DRIVER_FILENAMES[1]) == "string" then
    return DRIVER_FILENAMES[1]
  end
  return nil
end
M._defaultFile = defaultFile

local function common(mode, opts)
  local keepQ, keepA = S.queries, S.actions
  S = fresh()
  S.queries, S.actions = keepQ, keepA -- declarations made before the mode
  S.mode = mode
  S.file = opts.file or defaultFile()
  S.property = opts.property or M.PROPERTY
  S.sku = tostring(opts.sku or "")
  if opts.summary ~= nil then
    local summary = M.clean(opts.summary, M.LIMITS.summary)
    -- An empty summary in the options is ignored: the built-in default stands.
    S.summary = summary ~= "" and summary or nil
  end
end

--- Root driver not yet on the bus. opts = { file? (default DC_FILENAME, else
--- DRIVER_FILENAMES[1]), sku?, property? ("AI Core"), summary?, singleton?
--- (false), status? (fn returning status, detail, counters for the module
--- status frame) }.
--- Sets sbos.moduleclient up (protocol_min 2, claim_driver_config = false,
--- so EC.SBOS_DRIVER_CONFIG stays the driver's) and registers.
--- Returns true, or false + reason (unknown file: nothing is set up).
function M.start(opts)
  opts = opts or {}
  local file = opts.file or defaultFile()
  local id = M.MODULE_IDS[file]
  if id == nil then
    return false, "unknown_driver_file"
  end
  common("start", opts)
  S.moduleId = id
  S.client = opts.client or moduleclient
  paint(M.V.searching)
  local c = S.client
  S.manifest = { driver = "sbos." .. id, capabilities = M.capabilities() }
  local version = configInfo("version")
  c.setup({
    module_id = id,
    driver_version = version,
    entitlements = S.sku ~= "" and { S.sku } or {},
    singleton = opts.singleton == true,
    -- v2 only: a v1-only Agent refuses the registration (incompatible
    -- protocol) instead of filling its 16-entry registry with a module it
    -- cannot serve.
    protocol_min = 2,
    require_protocol = 2,
    manifest = S.manifest,
    claim_driver_config = false,
    status = opts.status or function()
      return c.displayStatus(), "", {}
    end,
    onRegistered = M.onRegistered,
    onAgentState = M.onAgentState,
    onDirectoryChanged = M.onDirectoryChanged,
  })
  wireHandlers()
  suppressDebug()
  S.tried = true
  c.register()
  repaint()
  return true
end

--- Root driver with its own moduleclient. opts as start (file, sku,
--- property, summary). The driver forwards onRegistered, onDirectoryChanged
--- and onAgentState from its client setup to aireport.onRegistered /
--- onDirectoryChanged / onAgentState, and lists aireport.capabilities() in
--- its manifest when it declares queries or actions.
function M.attach(client, opts)
  opts = opts or {}
  local file = opts.file or defaultFile()
  if M.MODULE_IDS[file] == nil then
    return false, "unknown_driver_file"
  end
  if type(client) ~= "table" or type(client.request) ~= "function" then
    return false, "client"
  end
  common("attach", opts)
  S.moduleId = M.MODULE_IDS[file]
  S.client = client
  paint(M.V.searching)
  wireHandlers()
  suppressDebug()
  S.tried = true
  if client.agentId() == nil and license.agentDeviceId() == nil then
    S.agentMissing = true
  end
  if client.isRegistered() then
    discover()
  end
  repaint()
  return true
end

local function passiveLookup()
  local ok, found = pcall(function()
    return C4:GetDevicesByC4iName(M.AI_CORE_FILE)
  end)
  if not ok then
    return -- keep what we knew
  end
  S.passiveInstalled = type(found) == "table" and next(found) ~= nil
  repaint()
end

local function passiveSoon()
  SetTimer(TIMERS.passive, M.PASSIVE_DEBOUNCE_SECONDS * 1000, passiveLookup)
end
M._passiveSoon = passiveSoon
M._oseHooks = {}

--- Child driver: no bus registration and no frame of any kind. Looks AI
--- Core up by file name at start and on OnDriverAdded (13) / OnItemRemoved
--- (11) (debounced 5 s; whether those system events reach a child driver
--- is unverified). opts = { file? (default as start), property? }.
function M.passive(opts)
  opts = opts or {}
  local file = opts.file or defaultFile()
  local root = M.CHILDREN[file]
  if root == nil or M.LABELS[root] == nil then
    return false, "unknown_driver_file"
  end
  common("passive", opts)
  S.rootLabel = M.LABELS[root]
  paint(M.V.searching)
  if type(OSE) == "table" then
    -- Chain whatever the driver already handles; never wrap our own hook.
    for _, name in ipairs({ "OnDriverAdded", "OnItemRemoved" }) do
      local previous = OSE[name]
      if previous == nil or previous ~= M._oseHooks[name] then
        local hook = function(event)
          passiveSoon()
          if type(previous) == "function" then
            return previous(event)
          end
        end
        OSE[name] = hook
        M._oseHooks[name] = hook
      end
    end
  end
  for _, id in ipairs({ 13, 11 }) do
    pcall(function()
      C4:RegisterSystemEvent(id, 0)
    end)
  end
  passiveLookup()
  return true
end

--- OnDriverDestroyed. start mode stops (and unregisters) its client;
--- attach leaves the driver's client alone.
function M.stop()
  for _, id in pairs(TIMERS) do
    CancelTimer(id)
  end
  if S.mode == "start" and S.client ~= nil then
    S.client.stop()
  end
  S.mode = nil
end

-- ── introspection ───────────────────────────────────────────────────────────

function M.value()
  return S.value
end

function M.counters()
  return S.counters
end

function M.mode()
  return S.mode
end

function M.target()
  return S.target
end

function M.describeStatus()
  return string.format(
    "mode=%s value=%s target=%s sent=%d accepted=%d suppressed=%d rate_limited=%d",
    tostring(S.mode),
    tostring(S.value),
    S.target and S.target.instance_id or "none",
    S.counters.sent,
    S.counters.accepted,
    S.counters.suppressed,
    S.counters.rate_limited
  )
end

--- Tests only: forget everything (declarations included).
function M._reset()
  S = fresh()
  M._oseHooks = {}
end

function M._state()
  return S
end

return M
