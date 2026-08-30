--- Execution planning: turn a mode into an ordered list of device actions —
--- WITHOUT sending anything. Dry Run (spec §42) is this module's output
--- rendered; Execute is the engine walking the same output. That separation
--- is architectural (spec §43): planning is pure and shim-testable, the
--- engine owns timers and sends.

local model = require("modes.model")
local adapters = require("modes.adapters")

local M = {}

--- Default SEQUENCED stage order (spec §20): quiet the house before securing
--- it. Classes absent from a mode simply produce no stage.
M.DEFAULT_SEQUENCE = { "ROOM", "LIGHT", "SHADE", "FAN", "RELAY", "GARAGE", "LOCK", "THERMOSTAT", "SECURITY" }

--- Stage spacing for SEQUENCED when the dealer didn't specify one.
M.DEFAULT_STAGE_GAP_S = 2

--- GRACEFUL default ramp for lights that didn't set their own.
M.GRACEFUL_RAMP_MS = 3000

--- Build the execution plan for a mode.
--- @param cfg table config envelope
--- @param modeId string
--- @param deps table {
---   resolve = fn(deviceKey) -> {id, name, room, proxy, vars, online} | nil,
---   secrets = {security_user_code?},
--- }
--- @return table? plan, string? err
function M.build(cfg, modeId, deps)
  local mode = cfg.modes[modeId]
  if not mode then
    return nil, "unknown mode: " .. tostring(modeId)
  end
  local states, sourcesOrErr = model.effectiveStates(cfg, modeId)
  if not states then
    return nil, sourcesOrErr
  end
  local transition = model.effectiveTransition(cfg, modeId)

  local plan = {
    mode_id = modeId,
    mode_name = mode.name,
    transition = transition,
    actions = {},
    restores = {}, -- deviceKeys whose behavior is RESTORE (engine captures + queues)
    unsupported = {},
    missing = {},
    summary = { by_class = {}, total = 0 },
  }

  for deviceKey, entry in pairs(states) do
    if entry.behavior == "IGNORE" then
      -- Explicitly configured to be left alone: not an action, not a warning.
    else
      local device = deps.resolve(deviceKey)
      if not device then
        table.insert(plan.missing, { device_key = deviceKey, source_mode = sourcesOrErr[deviceKey] })
      else
        local adapter = device.adapter or adapters.classify(device)
        if entry.behavior == "RESTORE" then
          if adapter.caps.canReadState and adapter.caps.canRestoreState then
            table.insert(plan.restores, { device_key = deviceKey, device = device, adapter = adapter })
          else
            table.insert(plan.unsupported, {
              device_key = deviceKey,
              name = device.name,
              reason = adapter.label .. " devices cannot capture-and-restore state",
            })
          end
        else
          local state = model.deepcopy(entry.state or {})
          if transition.style == "GRACEFUL" and adapter.class == "LIGHT" and state.ramp_ms == nil then
            state.ramp_ms = M.GRACEFUL_RAMP_MS
          end
          local ok, verr = adapter.validate(state)
          if not ok then
            table.insert(plan.unsupported, { device_key = deviceKey, name = device.name, reason = verr })
          else
            local cmds, perr = adapter.plan(state, { user_code = (deps.secrets or {}).security_user_code })
            if not cmds then
              table.insert(plan.unsupported, { device_key = deviceKey, name = device.name, reason = perr })
            else
              for _, cmd in ipairs(cmds) do
                table.insert(plan.actions, {
                  device_key = deviceKey,
                  device_id = device.id,
                  device_name = device.name,
                  room = device.room,
                  class = adapter.class,
                  behavior = "SET",
                  command = cmd.command,
                  params = cmd.params,
                  redact = cmd.redact,
                  delay_s = entry.delay_s or 0,
                  criticality = entry.criticality or "NORMAL",
                  describe = adapter.describe(state),
                  offline = device.online == false,
                })
              end
              plan.summary.by_class[adapter.class] = (plan.summary.by_class[adapter.class] or 0) + 1
            end
          end
        end
      end
    end
  end

  M.order(plan)
  plan.summary.total = #plan.actions
  return plan
end

--- Order the action list according to the transition style. Delayed actions
--- keep their delay; ordering applies within the immediate batch. SEQUENCED
--- stages add cumulative stage delays on top of per-action ones.
function M.order(plan)
  local style = plan.transition.style
  local stageIndex = {}
  local sequence = plan.transition.sequence
  if not sequence or #sequence == 0 then
    sequence = nil
  end
  local stageList = {}
  if style == "SEQUENCED" then
    if sequence then
      for i, stage in ipairs(sequence) do
        stageIndex[stage.class] = i
        stageList[i] = stage
      end
    else
      for i, class in ipairs(M.DEFAULT_SEQUENCE) do
        stageIndex[class] = i
        stageList[i] = { class = class, gap_s = M.DEFAULT_STAGE_GAP_S }
      end
    end
    -- Cumulative offset per stage. Stage offsets go in stage_delay_s, NOT
    -- delay_s: the engine keeps stage-delayed actions inside the TRACKED
    -- queue (their failures shape the aggregate result), while dealer
    -- per-action delays ("off after 90s") run fire-and-forget afterwards.
    local cum = 0
    for i, stage in ipairs(stageList) do
      stage._start_s = cum
      cum = cum + (tonumber(stage.gap_s) or M.DEFAULT_STAGE_GAP_S)
    end
    for _, action in ipairs(plan.actions) do
      local idx = stageIndex[action.class]
      if idx then
        action.stage_delay_s = stageList[idx]._start_s
        action._stage = idx
      else
        action._stage = #stageList + 1
      end
    end
  end
  table.sort(plan.actions, function(a, b)
    if (a.delay_s or 0) ~= (b.delay_s or 0) then
      return (a.delay_s or 0) < (b.delay_s or 0)
    end
    if (a.stage_delay_s or 0) ~= (b.stage_delay_s or 0) then
      return (a.stage_delay_s or 0) < (b.stage_delay_s or 0)
    end
    if (a._stage or 0) ~= (b._stage or 0) then
      return (a._stage or 0) < (b._stage or 0)
    end
    if a.class ~= b.class then
      return a.class < b.class
    end
    if tostring(a.device_key) ~= tostring(b.device_key) then
      return tostring(a.device_key) < tostring(b.device_key)
    end
    return tostring(a.command) < tostring(b.command)
  end)
end

--- Preflight (spec §28): evaluate the mode's configured checks. Each check:
--- {device_key, expect = "CLOSED"|"LOCKED"|"READY", policy = "WARN"|"BLOCK"|"IGNORE", label?}
--- @return table results {checks={...}, worst="OK"|"WARNING"|"BLOCKING"}
function M.preflight(cfg, modeId, deps)
  local mode = cfg.modes[modeId]
  local results = { checks = {}, worst = "OK" }
  if not mode then
    return results
  end
  -- Walk the chain so Vacation inherits Away's checks (spec §29).
  local chain = model.resolveChain(cfg, modeId) or {}
  local merged = {}
  for _, m in ipairs(chain) do
    for _, check in ipairs(m.preflight or {}) do
      merged[tostring(check.device_key) .. "\0" .. tostring(check.expect)] = check
    end
  end
  local function worse(level)
    if level == "BLOCKING" then
      results.worst = "BLOCKING"
    elseif level == "WARNING" and results.worst == "OK" then
      results.worst = "WARNING"
    end
  end
  for _, check in pairs(merged) do
    if check.policy ~= "IGNORE" then
      local device = deps.resolve(check.device_key)
      local outcome, detail
      if not device then
        outcome, detail = "WARNING", "device is missing from the project"
      elseif device.online == false then
        outcome, detail = "WARNING", "device is offline"
      else
        local ok, why = M.evaluateExpectation(device, check.expect)
        if ok == nil then
          outcome, detail = "WARNING", "cannot read state: " .. tostring(why)
        elseif ok then
          outcome, detail = "OK", nil
        else
          outcome = check.policy == "BLOCK" and "BLOCKING" or "WARNING"
          detail = why
        end
      end
      table.insert(results.checks, {
        device_key = check.device_key,
        name = device and device.name or tostring(check.device_key),
        expect = check.expect,
        outcome = outcome,
        detail = detail,
      })
      worse(outcome)
    end
  end
  return results
end

--- Evaluate one expectation against a resolved device's variables.
--- @return boolean? ok, string? why (nil ok = unreadable)
function M.evaluateExpectation(device, expect)
  local vars = device.vars or {}
  if expect == "CLOSED" then
    local raw = vars["ContactState"] or vars["CONTACT_STATE"] or vars["STATE"] or vars["GARAGE_DOOR_STATE"]
    if raw == nil then
      return nil, "no contact state variable"
    end
    local s = tostring(raw):lower()
    local closed = s == "closed" or s == "0" or s == "false"
    return closed, closed and nil or (device.name .. " is OPEN")
  elseif expect == "LOCKED" then
    local adapter = adapters.ADAPTERS.LOCK
    local state = adapter.read(vars)
    if state == nil then
      return nil, "no lock state variable"
    end
    return state.locked, state.locked and nil or (device.name .. " is UNLOCKED")
  elseif expect == "READY" then
    local raw = vars["PARTITION_STATE"]
    if raw == nil then
      return nil, "no partition state variable"
    end
    local ok = raw == "DISARMED_READY" or raw == "ARMED" or raw == "EXIT_DELAY"
    return ok, ok and nil or ("security panel is " .. tostring(raw))
  end
  return nil, "unknown expectation " .. tostring(expect)
end

--- Render a dry run for a dealer (spec §42): counts per category + notable
--- rows, in plain language, no proxy ids.
function M.renderDryRun(plan)
  local lines = { string.format("%s WOULD:", tostring(plan.mode_name):upper()) }
  local counts = {}
  for _, action in ipairs(plan.actions) do
    local key = action.class .. "\0" .. action.describe
    counts[key] = counts[key] or { class = action.class, describe = action.describe, n = 0, delayed = 0 }
    counts[key].n = counts[key].n + 1
    if (action.delay_s or 0) > 0 then
      counts[key].delayed = counts[key].delayed + 1
    end
  end
  local rows = {}
  for _, row in pairs(counts) do
    table.insert(rows, row)
  end
  table.sort(rows, function(a, b)
    if a.class ~= b.class then
      return a.class < b.class
    end
    return a.describe < b.describe
  end)
  for _, row in ipairs(rows) do
    local label = (adapters.ADAPTERS[row.class] or {}).label or row.class
    local suffix = row.delayed > 0 and string.format(" (%d delayed)", row.delayed) or ""
    table.insert(lines, string.format("  %-10s %3d x %s%s", label, row.n, row.describe, suffix))
  end
  if #plan.restores > 0 then
    table.insert(lines, string.format("  Restore    %3d devices back to captured state on exit", #plan.restores))
  end
  for _, u in ipairs(plan.unsupported) do
    table.insert(lines, string.format("  SKIP       %s — %s", u.name or u.device_key, u.reason))
  end
  for _, miss in ipairs(plan.missing) do
    table.insert(
      lines,
      string.format("  MISSING    device %s no longer exists in the project", tostring(miss.device_key))
    )
  end
  table.insert(lines, string.format("  Total actions: %d", plan.summary.total))
  return table.concat(lines, "\n")
end

return M
