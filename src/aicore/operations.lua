--- SmartBuildOS AI Core — restricted operations from the platform (pure).
---
--- They arrive as SBOS_MODULE_COMMAND through the Agent, which has already
--- checked the operation name against MODULE_COMMANDS.ai_core and the
--- module's token. This module checks the ARGUMENTS, strictly: every
--- operation has a closed set of argument keys and anything else refuses
--- the whole operation. So no argument can smuggle a device id plus a
--- command name, a Lua string or a URL into the driver, and no operation
--- names something to forward: none of them controls equipment. Device
--- actions the AI proposes are executed by the Agent's existing command
--- queue (ARCHITECTURE D4), never here.
---
---   parse(command, args) → op | nil, reason
---
--- op.kind is the operation; the other fields are normalised, bounded values.

local V = require("aicore.vocab")
local Commands = require("aicore.commands")

local M = {}

local L = V.LIMITS

local ARGS = {
  apply_config = { config = true, version = true },
  refresh_status = {},
  deliver_result = {
    response_id = true,
    request_id = true,
    job_id = true,
    text = true,
    kind = true,
    pending_approvals = true,
    recommendation_count = true,
    -- Only on the answer to an ask that carried `unlock` (webui.UNLOCK): the
    -- answer belongs to the touchscreen page and is never a Composer answer.
    channel = true,
  },
  raise_event = {
    event = true,
    detail = true,
    pending_approvals = true,
    recommendation_count = true,
    -- What the platform ties the event to (an action id for approval_required /
    -- action_completed / action_failed). Optional; carried into the
    -- ai_core.event envelope and AI_LAST_CORRELATION_ID, never interpreted.
    correlation_id = true,
  },
  -- config_version: the driver_config version System Studio published this
  -- change as (DRIVER.md §9 precedence: the document decides, set_learning
  -- previews it and is ignored once that version is applied).
  set_learning = { active = true, reason = true, config_version = true },
  run_diagnostic = { device_id = true, room_id = true, note = true },
  -- A read-only query / a person-approved action for the driver that
  -- declared it (docs/ai-core/DRIVER-CONTRACT.md, platform side). `params`
  -- is checked for shape here and against the declaration by the declaring
  -- driver's own helper before its handler runs.
  run_driver_query = { query_ref = true, module_id = true, instance_id = true, query_id = true, params = true },
  invoke_driver_action = {
    ai_action_id = true,
    module_id = true,
    instance_id = true,
    action_id = true,
    params = true,
    declaration_hash = true,
  },
  -- ONE device's current variables, read once on the controller and
  -- filtered there (src/aicore/devicestate.lua) before anything leaves the
  -- home. `scope` is the platform's: `system` (no household permission) or
  -- `full`; `variables` optionally narrows the read to <= 12 names.
  read_device_state = { state_ref = true, device_id = true, scope = true, variables = true },
}

--- The argument keys each operation accepts (a copy: the parity test reads
--- it; changing the copy changes nothing here).
function M.argKeys(command)
  local out = {}
  for k in pairs(ARGS[command] or {}) do
    out[#out + 1] = k
  end
  table.sort(out)
  return out
end

--- raise_event correlation_id: the envelope's bound (sbos.envelope
--- LIMITS.correlation_id, 96) and the platform envelope's character rule
--- (no control characters).
M.CORRELATION_MAX = 96

local function validCorrelation(s)
  return type(s) == "string" and #s >= 1 and #s <= M.CORRELATION_MAX and not s:find("[%c\127]")
end

M.RESULT_KINDS = { answer = true, analysis = true, report = true, scene_suggestion = true, diagnostic = true }
--- deliver_result's `channel` (the platform's AI_CORE_RESULT_CHANNELS).
M.RESULT_CHANNELS = { touchscreen = true }

local function validId(s)
  return type(s) == "string" and #s >= 1 and #s <= 128 and s:match("^[%w][%w%-_:%.]*$") ~= nil
end

local function count(v)
  if v == nil then
    return nil, nil
  end
  local n = tonumber(v)
  if n == nil or n ~= math.floor(n) or n < 0 or n > 9999 then
    return nil, "must be a whole number 0..9999"
  end
  return n
end

local function cleanText(v, max)
  if type(v) ~= "string" then
    return nil
  end
  local s = v:gsub("%z", ""):gsub("[\1-\8\11\12\14-\31\127]", " ")
  if #s > max then
    -- bounded in BYTES, cut between two UTF-8 characters (never half of one)
    local cut = max
    while cut > 0 and (s:byte(cut + 1) or 0) >= 0x80 and s:byte(cut + 1) < 0xC0 do
      cut = cut - 1
    end
    return s:sub(1, cut), true
  end
  return s, false
end

local function validUuid(s)
  return type(s) == "string"
    and s:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$") ~= nil
    and s:lower() == s
end

local function validModule(s)
  return type(s) == "string" and #s >= 3 and #s <= 48 and s:match("^[a-z][a-z0-9_]+$") ~= nil and s ~= V.MODULE_ID
end

local function validDeclId(s)
  return type(s) == "string" and #s <= 48 and s:match("^[a-z][a-z0-9_]*$") ~= nil
end

--- params: at most 6 keys ^[a-z][a-z0-9_]{0,31}$, each a string of at most
--- 64 characters without control characters, a finite number or a boolean.
local function validParams(p)
  if p == nil then
    return {}
  end
  if type(p) ~= "table" then
    return nil
  end
  local n = 0
  for k, v in pairs(p) do
    n = n + 1
    if n > 6 or type(k) ~= "string" or #k > 32 or not k:match("^[a-z][a-z0-9_]*$") then
      return nil
    end
    local t = type(v)
    if t == "string" then
      if #v > 256 or v:find("[%z\1-\31\127]") or v:find("\194[\128-\159]") or v:find("\226\128[\168\169]") then
        return nil
      end
      if Commands.length(v) > 64 then
        return nil
      end
    elseif t == "number" then
      if v ~= v or v == math.huge or v == -math.huge then
        return nil
      end
    elseif t ~= "boolean" then
      return nil
    end
  end
  return p
end

--- read_device_state: the largest Director device id the platform sends.
M.DEVICE_ID_MAX = 2147483647
--- read_device_state `variables`: at most this many names, each matching
--- ^[A-Za-z0-9 _.-]{1,48}$, no name twice.
M.VARIABLES_MAX = 12

--- read_device_state `variables`: nil/absent or an empty array = every
--- variable that passes the filter; otherwise an array (no other keys) of
--- distinct names.
local function validVariableNames(v)
  if v == nil then
    return {}
  end
  if type(v) ~= "table" then
    return nil, "variables must be an array of variable names"
  end
  local n = 0
  for _ in pairs(v) do
    n = n + 1
  end
  if n ~= #v then
    return nil, "variables must be an array of variable names"
  end
  if n > M.VARIABLES_MAX then
    return nil, "variables: at most " .. M.VARIABLES_MAX .. " names"
  end
  local seen = {}
  for i = 1, n do
    local s = v[i]
    if type(s) ~= "string" or #s < 1 or #s > 48 or not s:match("^[A-Za-z0-9 _%.%-]+$") then
      return nil, "variables: each name must match ^[A-Za-z0-9 _.-]{1,48}$"
    end
    if seen[s] then
      return nil, "variables: a name is listed twice"
    end
    seen[s] = true
  end
  return v
end

--- The declaring driver both operations address: its module id (never
--- AI Core) and its device id as a decimal string.
local function driverTarget(op, args)
  if not validModule(args.module_id) then
    return nil, "module_id must be a module id ^[a-z][a-z0-9_]{2,47}$ other than ai_core"
  end
  local inst = args.instance_id
  if type(inst) == "number" and inst == math.floor(inst) and inst > 0 then
    inst = string.format("%d", inst)
  end
  if type(inst) ~= "string" or #inst > 12 or not inst:match("^%d+$") then
    return nil, "instance_id must be the driver's device id (digits)"
  end
  local params = validParams(args.params)
  if params == nil then
    return nil, "params must be an object of at most 6 scalar values"
  end
  op.module_id, op.instance_id, op.params = args.module_id, inst, params
  return op
end

--- @return table|nil op, string|nil reason
function M.parse(command, args)
  local allowed = ARGS[command]
  if allowed == nil then
    return nil, "unknown operation " .. Commands.cutBytes(command, 64) -- between characters
  end
  if type(args) ~= "table" then
    return nil, "args must be an object"
  end
  for k in pairs(args) do
    if not allowed[k] then
      -- The key is the platform's choice: bounded before it is shown.
      return nil, "argument '" .. Commands.cutBytes(k, 64) .. "' is not accepted by " .. command
    end
  end
  local op = { kind = command }
  if command == "apply_config" then
    if type(args.config) ~= "table" then
      return nil, "apply_config needs args.config (an object)"
    end
    local v = tonumber(args.version)
    if v == nil or v ~= math.floor(v) or v < 0 then
      return nil, "apply_config needs args.version (a whole number)"
    end
    op.config, op.version = args.config, v
  elseif command == "deliver_result" then
    if not validId(args.response_id) then
      return nil, "deliver_result needs a response_id"
    end
    op.response_id = args.response_id
    if args.request_id ~= nil then
      if not validId(args.request_id) then
        return nil, "request_id malformed"
      end
      op.request_id = args.request_id
    end
    if args.job_id ~= nil then
      if not validId(tostring(args.job_id)) then
        return nil, "job_id malformed"
      end
      op.job_id = tostring(args.job_id)
    end
    if type(args.text) ~= "string" or args.text == "" then
      return nil, "deliver_result needs text"
    end
    if #args.text > L.result_text then
      return nil, "text longer than " .. L.result_text .. " characters"
    end
    op.text = cleanText(args.text, L.result_text)
    op.kind_of = args.kind ~= nil and tostring(args.kind) or "answer"
    if not M.RESULT_KINDS[op.kind_of] then
      return nil, "kind must be one of answer, analysis, report, scene_suggestion, diagnostic"
    end
    if args.channel ~= nil then
      if type(args.channel) ~= "string" or not M.RESULT_CHANNELS[args.channel] then
        return nil, "channel must be touchscreen"
      end
      op.channel = args.channel
    end
  elseif command == "raise_event" then
    if type(args.event) ~= "string" or not V.RAISABLE[args.event] then
      return nil, "event '" .. tostring(args.event) .. "' is not in the closed list"
    end
    op.event = args.event
    op.event_id = V.EVENT_ID[args.event]
    if args.detail ~= nil then
      if type(args.detail) ~= "string" then
        return nil, "detail must be text"
      end
      op.detail, op.detail_truncated = cleanText(args.detail, L.event_detail)
    else
      op.detail = ""
    end
    if args.correlation_id ~= nil then
      if not validCorrelation(args.correlation_id) then
        return nil,
          "correlation_id must be text of 1.." .. M.CORRELATION_MAX .. " characters without control characters"
      end
      op.correlation_id = args.correlation_id
    end
  elseif command == "set_learning" then
    if type(args.active) ~= "boolean" then
      return nil, "set_learning needs active = true or false"
    end
    op.active = args.active
    if args.reason ~= nil then
      if type(args.reason) ~= "string" then
        return nil, "reason must be text"
      end
      op.reason = cleanText(args.reason, 120)
    end
    if args.config_version ~= nil then
      local v = tonumber(args.config_version)
      if type(args.config_version) ~= "number" or v ~= math.floor(v) or v < 0 then
        return nil, "config_version must be a whole number (the configuration version it previews)"
      end
      op.config_version = v
    end
  elseif command == "run_driver_query" then
    if not validUuid(args.query_ref) then
      return nil, "run_driver_query needs a query_ref (a lower-case uuid)"
    end
    if not validDeclId(args.query_id) then
      return nil, "query_id must match ^[a-z][a-z0-9_]{0,47}$"
    end
    op.query_ref, op.query_id = args.query_ref, args.query_id
    local ok, why = driverTarget(op, args)
    if not ok then
      return nil, why
    end
  elseif command == "invoke_driver_action" then
    if not validUuid(args.ai_action_id) then
      return nil, "invoke_driver_action needs an ai_action_id (a lower-case uuid)"
    end
    if not validDeclId(args.action_id) then
      return nil, "action_id must match ^[a-z][a-z0-9_]{0,47}$"
    end
    -- 16 lower-case hex: the declaring driver's describe hash (aireport.hash).
    local h = args.declaration_hash
    if type(h) ~= "string" or #h ~= 16 or not h:match("^[0-9a-f]+$") then
      return nil, "declaration_hash must be 16 lower-case hex characters"
    end
    op.ai_action_id, op.action_id, op.declaration_hash = args.ai_action_id, args.action_id, h
    local ok, why = driverTarget(op, args)
    if not ok then
      return nil, why
    end
  elseif command == "read_device_state" then
    if not validUuid(args.state_ref) then
      return nil, "read_device_state needs a state_ref (a lower-case uuid)"
    end
    local d = args.device_id
    if type(d) ~= "number" or d ~= math.floor(d) or d < 1 or d > M.DEVICE_ID_MAX then
      return nil, "device_id must be a Director device id (a whole number 1.." .. M.DEVICE_ID_MAX .. ")"
    end
    if args.scope ~= "system" and args.scope ~= "full" then
      return nil, "scope must be system or full"
    end
    op.state_ref, op.device_id, op.scope = args.state_ref, d, args.scope
    local names, why = validVariableNames(args.variables)
    if names == nil then
      return nil, why
    end
    op.variables = names
  elseif command == "run_diagnostic" then
    local d = args.device_id ~= nil and tonumber(args.device_id) or nil
    local r = args.room_id ~= nil and tonumber(args.room_id) or nil
    if args.device_id ~= nil and (d == nil or d ~= math.floor(d) or d <= 0) then
      return nil, "device_id must be a Director device id"
    end
    if args.room_id ~= nil and (r == nil or r ~= math.floor(r) or r <= 0) then
      return nil, "room_id must be a Director room id"
    end
    if (d == nil) == (r == nil) then
      return nil, "run_diagnostic needs exactly one of device_id, room_id"
    end
    op.device_id, op.room_id = d, r
    if args.note ~= nil then
      op.note = cleanText(tostring(args.note), 200)
    end
  end
  if command == "deliver_result" or command == "raise_event" then
    local why
    op.pending_approvals, why = count(args.pending_approvals)
    if why then
      return nil, "pending_approvals " .. why
    end
    op.recommendation_count, why = count(args.recommendation_count)
    if why then
      return nil, "recommendation_count " .. why
    end
  end
  return op
end

--- AI_LAST_RESPONSE: bounded for a Composer variable; the cut is marked.
function M.boundResponse(text)
  text = tostring(text or "")
  if #text <= L.last_response then
    return text, false
  end
  -- Do not split a UTF-8 sequence: back off continuation bytes.
  local cut = L.last_response - 3
  while cut > 1 and text:byte(cut + 1) and text:byte(cut + 1) >= 0x80 and text:byte(cut + 1) < 0xC0 do
    cut = cut - 1
  end
  return text:sub(1, cut) .. "...", true
end

return M
