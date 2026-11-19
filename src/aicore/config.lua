--- SmartBuildOS AI Core — the configuration System Studio delivers (pure).
---
--- Arrives through the Agent's existing SBOS_DRIVER_CONFIG forwarding for
--- SKU SBOS_AI_CORE (or the restricted operation apply_config). The WHOLE
--- document is validated; one bad field refuses all of it and the last
--- valid configuration stays in force. Unknown keys are refused (a typo in
--- System Studio must be seen, not silently ignored), and so is anything
--- shaped like a credential: the AI provider key lives in System Studio's
--- vault and never reaches the controller (ARCHITECTURE D2). What the
--- controller shows about the key is a status string System Studio wrote.
---
--- Every field is optional and defaults to its conservative value (default()):
--- learning OFF, every collection source off, nothing excluded, display
--- fields unset. What System Studio has not said is not switched on here.
---
--- This schema is the WIRE CONTRACT with the platform: System Studio builds
--- the document in src/lib/ai-core/settings/{settings,driver-config}.ts
--- (driverConfigDocument + a mirror of every rule below), and the golden
--- documents it publishes (tests/unit/fixtures/ai-core-driver-config/) are
--- fed to THIS validator by test/test_aicore_platform_parity.lua [10].
--- A room here is a Director room id — the id an envelope's / a command's
--- room_id carries and the id the platform stores in excluded_room_ids.
--- Categories are THIS driver's (vocab.lua); the platform translates its
--- learning categories to them before publishing.
---
--- Document (schema 1; the values shown are an example, not the defaults):
---   {
---     "schema": 1,
---     "learning": { "active": true },
---     "exclusions": { "rooms": [12, 40], "categories": ["security"] },
---     "permission_mode": "observe" | "recommend" | "execute_low_risk",
---     "provider": { "name": "Anthropic", "model": "claude-…" },
---     "credential_status": "Configured in System Studio · Anthropic ••••abcd",
---     "collection": {
---       "system_events": true,
---       "flight_recorder_topics": true,
---       "agent_events": true,
---       "variables": [ { "device_id": 12, "variable": "LIGHT_STATE" } ],
---       "max_events_per_minute": 60
---     },
---     "property_id": "…", "controller_id": "…",
---     "touchscreen": { "presets": [ "Is the wine cellar at the right temperature?" ] }
---   }
---
--- `touchscreen.presets` (round two, D-R2b): the dealer's preset questions
--- for the touchscreen chat, set by staff in System Studio. At most 6, each
--- 3–120 characters (≤ 360 bytes) of plain single-line text: no control, C1,
--- line-separator or bidi character, no `<` or `>`, no `://` or `www.`,
--- no leading or trailing space, nothing credential-shaped (the same rule as
--- every display string here), no two alike ignoring case and spacing. One
--- bad preset refuses the WHOLE document, like every other bad value. The
--- platform sends the key only to a driver that registers read_device_state
--- (round two); a document without it is accepted exactly as before, with
--- no presets.

local Envelope = require("sbos.envelope")
local V = require("aicore.vocab")

local M = {}

M.SCHEMA = 1
M.LIMITS = {
  excluded_rooms = 500, -- = the platform's settings bound (SETTINGS_LIMITS.excludedRooms): a saved list arrives whole
  excluded_categories = 16,
  variables = 32,
  provider_name = 40,
  model_name = 80,
  credential_status = 96,
  id = 64,
  events_per_minute_max = 300,
  presets = 6,
  preset_chars_min = 3,
  preset_chars_max = 120,
  preset_bytes = 360,
}

local TOP = {
  schema = true,
  learning = true,
  exclusions = true,
  permission_mode = true,
  provider = true,
  credential_status = true,
  collection = true,
  property_id = true,
  controller_id = true,
  touchscreen = true,
}

function M.default()
  return {
    schema = M.SCHEMA,
    -- Every default is the conservative one (most private, least capable):
    -- what System Studio has not said is not switched on here.
    learning = { active = false }, -- off until System Studio switches it on
    exclusions = { rooms = {}, categories = {} },
    permission_mode = nil, -- unknown until System Studio says
    provider = { name = nil, model = nil },
    credential_status = nil,
    collection = {
      system_events = false,
      flight_recorder_topics = false,
      agent_events = false,
      variables = {},
      max_events_per_minute = 60,
    },
    property_id = nil,
    controller_id = nil,
    touchscreen = { presets = {} }, -- no presets until System Studio sends some
  }
end

local function isList(t)
  if type(t) ~= "table" then
    return false
  end
  local n = 0
  for _ in pairs(t) do
    n = n + 1
  end
  return n == #t
end

local function onlyKeys(t, allowed, path, refusals)
  for k in pairs(t) do
    if not allowed[k] then
      refusals[#refusals + 1] = { path = path .. tostring(k), reason = "unknown key" }
    end
  end
end

local function displayString(v, max, path, refusals)
  if v == nil then
    return nil
  end
  if type(v) ~= "string" or #v > max or v:find("[%c]") then
    refusals[#refusals + 1] = { path = path, reason = "must be text of at most " .. max .. " characters" }
    return nil
  end
  if Envelope.looksLikeSecret(v) or v:find("sk%-[%w%-_]+") or v:lower():find("bearer ") then
    refusals[#refusals + 1] = { path = path, reason = "looks like a credential; a key never reaches the controller" }
    return nil
  end
  return v
end

-- C0 controls and DEL, C1, line/paragraph separators, bidi controls and
-- marks, and the byte-order mark.
local function unprintable(s)
  return s:find("[%z\1-\31\127]") ~= nil
    or s:find("\194[\128-\159]") ~= nil
    or s:find("\226\128[\142\143\168-\174]") ~= nil
    or s:find("\226\129[\166-\169]") ~= nil
    or s:find("\216\156") ~= nil
    or s:find("\239\187\191") ~= nil
end

--- The characters of a UTF-8 string (bytes that do not continue one).
local function chars(s)
  local n = 0
  for _ in s:gmatch("[^\128-\191]") do
    n = n + 1
  end
  return n
end

--- One preset question, or nil (a refusal added).
local function presetText(v, path, refusals)
  local L = M.LIMITS
  if type(v) ~= "string" then
    refusals[#refusals + 1] = { path = path, reason = "must be text" }
    return nil
  end
  local n = chars(v)
  if n < L.preset_chars_min or n > L.preset_chars_max or #v > L.preset_bytes then
    refusals[#refusals + 1] = {
      path = path,
      reason = "must be " .. L.preset_chars_min .. "-" .. L.preset_chars_max .. " characters",
    }
    return nil
  end
  if unprintable(v) then
    refusals[#refusals + 1] = { path = path, reason = "must be one line of plain text (no control characters)" }
    return nil
  end
  if v:find("^%s") or v:find("%s$") then
    refusals[#refusals + 1] = { path = path, reason = "must not start or end with a space" }
    return nil
  end
  if v:find("[<>]") then
    refusals[#refusals + 1] = { path = path, reason = "must be plain text (no markup)" }
    return nil
  end
  local lower = v:lower()
  if lower:find("://", 1, true) or lower:find("www.", 1, true) then
    refusals[#refusals + 1] = { path = path, reason = "must not carry a link" }
    return nil
  end
  return displayString(v, L.preset_bytes, path, refusals)
end

--- Any key anywhere that names a credential refuses the whole document.
--- `credential_status` (display text) is the one allowed name.
local function scanSecrets(value, path, refusals, depth)
  depth = depth or 0
  if type(value) ~= "table" or depth > 6 then
    return
  end
  for k, v in pairs(value) do
    local key = tostring(k)
    if type(k) == "string" and key ~= "credential_status" and Envelope.isSensitiveKey(key) then
      refusals[#refusals + 1] = { path = path .. key, reason = "credential-shaped key; keys stay in System Studio" }
    end
    scanSecrets(v, path .. key .. ".", refusals, depth + 1)
  end
end

--- @return table|nil config, table refusals { {path, reason} }
function M.validate(raw)
  local refusals = {}
  if type(raw) ~= "table" or isList(raw) and next(raw) ~= nil then
    return nil, { { path = "", reason = "configuration must be an object" } }
  end
  scanSecrets(raw, "", refusals)
  onlyKeys(raw, TOP, "", refusals)
  local cfg = M.default()
  if raw.schema ~= nil and raw.schema ~= M.SCHEMA then
    refusals[#refusals + 1] = { path = "schema", reason = "unsupported schema " .. tostring(raw.schema) }
  end
  if raw.learning ~= nil then
    if type(raw.learning) ~= "table" then
      refusals[#refusals + 1] = { path = "learning", reason = "must be an object" }
    else
      onlyKeys(raw.learning, { active = true }, "learning.", refusals)
      if type(raw.learning.active) ~= "boolean" then
        refusals[#refusals + 1] = { path = "learning.active", reason = "must be true or false" }
      else
        cfg.learning.active = raw.learning.active
      end
    end
  end
  if raw.exclusions ~= nil then
    local ex = raw.exclusions
    if type(ex) ~= "table" then
      refusals[#refusals + 1] = { path = "exclusions", reason = "must be an object" }
    else
      onlyKeys(ex, { rooms = true, categories = true }, "exclusions.", refusals)
      if ex.rooms ~= nil then
        if not isList(ex.rooms) or #ex.rooms > M.LIMITS.excluded_rooms then
          refusals[#refusals + 1] =
            { path = "exclusions.rooms", reason = "must be a list of at most " .. M.LIMITS.excluded_rooms }
        else
          for i, id in ipairs(ex.rooms) do
            local n = tonumber(id)
            if n == nil or n ~= math.floor(n) or n <= 0 then
              refusals[#refusals + 1] = { path = "exclusions.rooms[" .. i .. "]", reason = "not a room id" }
            else
              cfg.exclusions.rooms[#cfg.exclusions.rooms + 1] = n
            end
          end
        end
      end
      if ex.categories ~= nil then
        if not isList(ex.categories) or #ex.categories > M.LIMITS.excluded_categories then
          refusals[#refusals + 1] = { path = "exclusions.categories", reason = "must be a list" }
        else
          for i, c in ipairs(ex.categories) do
            if not V.CATEGORIES[c] then
              refusals[#refusals + 1] =
                { path = "exclusions.categories[" .. i .. "]", reason = "unknown category " .. tostring(c) }
            else
              cfg.exclusions.categories[#cfg.exclusions.categories + 1] = c
            end
          end
        end
      end
    end
  end
  if raw.permission_mode ~= nil then
    if not V.PERMISSION_MODES[raw.permission_mode] then
      refusals[#refusals + 1] = { path = "permission_mode", reason = "must be observe, recommend or execute_low_risk" }
    else
      cfg.permission_mode = raw.permission_mode
    end
  end
  if raw.provider ~= nil then
    if type(raw.provider) ~= "table" then
      refusals[#refusals + 1] = { path = "provider", reason = "must be an object" }
    else
      onlyKeys(raw.provider, { name = true, model = true }, "provider.", refusals)
      cfg.provider.name = displayString(raw.provider.name, M.LIMITS.provider_name, "provider.name", refusals)
      cfg.provider.model = displayString(raw.provider.model, M.LIMITS.model_name, "provider.model", refusals)
    end
  end
  cfg.credential_status =
    displayString(raw.credential_status, M.LIMITS.credential_status, "credential_status", refusals)
  for _, key in ipairs({ "property_id", "controller_id" }) do
    if raw[key] ~= nil then
      local v = raw[key]
      if type(v) ~= "string" or not v:match("^[%w][%w%-_:.]*$") or #v > M.LIMITS.id then
        refusals[#refusals + 1] = { path = key, reason = "must be an identifier" }
      else
        cfg[key] = v
      end
    end
  end
  if raw.collection ~= nil then
    local c = raw.collection
    if type(c) ~= "table" then
      refusals[#refusals + 1] = { path = "collection", reason = "must be an object" }
    else
      onlyKeys(c, {
        system_events = true,
        flight_recorder_topics = true,
        agent_events = true,
        variables = true,
        max_events_per_minute = true,
      }, "collection.", refusals)
      for _, key in ipairs({ "system_events", "flight_recorder_topics", "agent_events" }) do
        if c[key] ~= nil then
          if type(c[key]) ~= "boolean" then
            refusals[#refusals + 1] = { path = "collection." .. key, reason = "must be true or false" }
          else
            cfg.collection[key] = c[key]
          end
        end
      end
      if c.max_events_per_minute ~= nil then
        local n = tonumber(c.max_events_per_minute)
        if n == nil or n ~= math.floor(n) or n < 1 or n > M.LIMITS.events_per_minute_max then
          refusals[#refusals + 1] =
            { path = "collection.max_events_per_minute", reason = "must be 1.." .. M.LIMITS.events_per_minute_max }
        else
          cfg.collection.max_events_per_minute = n
        end
      end
      if c.variables ~= nil then
        if not isList(c.variables) or #c.variables > M.LIMITS.variables then
          refusals[#refusals + 1] =
            { path = "collection.variables", reason = "must be a list of at most " .. M.LIMITS.variables }
        else
          for i, v in ipairs(c.variables) do
            local p = "collection.variables[" .. i .. "]"
            if type(v) ~= "table" then
              refusals[#refusals + 1] = { path = p, reason = "must be an object" }
            else
              onlyKeys(v, { device_id = true, variable = true }, p .. ".", refusals)
              local id = tonumber(v.device_id)
              local name = v.variable
              if id == nil or id ~= math.floor(id) or id <= 0 then
                refusals[#refusals + 1] = { path = p .. ".device_id", reason = "not a device id" }
              elseif type(name) ~= "string" or name == "" or #name > 64 then
                refusals[#refusals + 1] = { path = p .. ".variable", reason = "must be a variable name" }
              elseif Envelope.isSensitiveKey(name) then
                refusals[#refusals + 1] =
                  { path = p .. ".variable", reason = "a code- or credential-named variable is never collected" }
              else
                cfg.collection.variables[#cfg.collection.variables + 1] = { device_id = id, variable = name }
              end
            end
          end
        end
      end
    end
  end
  if raw.touchscreen ~= nil then
    local t = raw.touchscreen
    if type(t) ~= "table" or (isList(t) and next(t) ~= nil) then
      refusals[#refusals + 1] = { path = "touchscreen", reason = "must be an object" }
    else
      onlyKeys(t, { presets = true }, "touchscreen.", refusals)
      local list = t.presets
      if list ~= nil then
        if not isList(list) or #list > M.LIMITS.presets then
          refusals[#refusals + 1] =
            { path = "touchscreen.presets", reason = "must be a list of at most " .. M.LIMITS.presets }
        else
          local seen = {}
          for i, v in ipairs(list) do
            local p = "touchscreen.presets[" .. i .. "]"
            local text = presetText(v, p, refusals)
            if text ~= nil then
              local key = text:lower():gsub("%s+", " ")
              if seen[key] then
                refusals[#refusals + 1] = { path = p, reason = "the same question twice" }
              else
                seen[key] = true
                cfg.touchscreen.presets[#cfg.touchscreen.presets + 1] = text
              end
            end
          end
        end
      end
    end
  end
  if #refusals > 0 then
    return nil, refusals
  end
  return cfg, refusals
end

--- Sets for fast lookups.
function M.excludedRoomSet(cfg)
  local s = {}
  for _, id in ipairs(cfg.exclusions.rooms or {}) do
    s[id] = true
  end
  return s
end

function M.excludedCategorySet(cfg)
  local s = {}
  for _, c in ipairs(cfg.exclusions.categories or {}) do
    s[c] = true
  end
  return s
end

--- One line for logs and the config_error status field.
function M.describeRefusals(refusals)
  local parts = {}
  for i, r in ipairs(refusals or {}) do
    if i > 3 then
      parts[#parts + 1] = "+" .. (#refusals - 3) .. " more"
      break
    end
    parts[#parts + 1] = (r.path ~= "" and r.path or "(document)") .. ": " .. r.reason
  end
  return table.concat(parts, "; ")
end

return M
