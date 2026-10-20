--- SmartBuildOS Agent contract v1.
---
--- This module is deliberately free of Control4 globals. The Agent driver owns
--- transport, persistence and Composer presentation; this file owns the wire
--- vocabulary and deterministic state transitions shared with System Studio.
--- Keeping the transition pure makes power-loss, clock and duplicate-event
--- behavior testable without pretending a simulator is Controller proof.

local M = {}

M.CONTRACT_VERSION = 1
M.DRIVER_SKU = "SBOS_AGENT"
M.STATE_SCHEMA_VERSION = 1
M.STORM_CEILING = 4

M.DEFAULT_CONFIG = {
  startupMonitoring = true,
  notificationPolicy = "default-escalation",
  countBasis = "system-startups",
  startupThreshold = 3,
  stabilizationSeconds = 120,
  serviceModeMinutes = 60,
  reportSchedule = nil,
  recipientProfileId = nil,
  autoUpdatePreference = "notify",
}

local DEFINITIONS = {
  startupMonitoring = { kind = "boolean" },
  notificationPolicy = {
    kind = "enum",
    values = { ["default-escalation"] = true, ["every-observation"] = true, ["record-only"] = true, disabled = true },
  },
  countBasis = { kind = "enum", values = { ["system-startups"] = true, ["controller-reboots"] = true } },
  startupThreshold = { kind = "integer", minimum = 1, maximum = 100 },
  stabilizationSeconds = { kind = "integer", minimum = 0, maximum = 3600 },
  serviceModeMinutes = { kind = "integer", minimum = 5, maximum = 1440 },
  reportSchedule = { kind = "nullable-string", maximum = 160 },
  recipientProfileId = { kind = "nullable-string", maximum = 160 },
  autoUpdatePreference = { kind = "enum", values = { off = true, notify = true, automatic = true } },
}

local function copy(source)
  local out = {}
  for key, value in pairs(source or {}) do
    if type(value) == "table" then
      local nested = {}
      for nestedKey, nestedValue in pairs(value) do
        nested[nestedKey] = nestedValue
      end
      out[key] = nested
    else
      out[key] = value
    end
  end
  return out
end

local function refusal(path, reason)
  return { path = path, reason = reason }
end

--- Validate a complete or partial platform settings document.
--- Unknown or invalid keys reject the whole document so the Agent can never
--- acknowledge a version that it only partly understood.
--- @param raw any
--- @return table|nil config
--- @return table refusals
function M.validateConfig(raw)
  if type(raw) ~= "table" then
    return nil, { refusal("settings", "must be an object") }
  end

  local result = copy(M.DEFAULT_CONFIG)
  local refusals = {}
  for key, value in pairs(raw) do
    local definition = DEFINITIONS[key]
    if definition == nil then
      refusals[#refusals + 1] = refusal(tostring(key), "unknown agent property")
    elseif definition.kind == "boolean" then
      if type(value) ~= "boolean" then
        refusals[#refusals + 1] = refusal(key, "must be boolean")
      else
        result[key] = value
      end
    elseif definition.kind == "enum" then
      if type(value) ~= "string" or definition.values[value] ~= true then
        refusals[#refusals + 1] = refusal(key, "unsupported value")
      else
        result[key] = value
      end
    elseif definition.kind == "integer" then
      if
        type(value) ~= "number"
        or value ~= math.floor(value)
        or value < definition.minimum
        or value > definition.maximum
      then
        refusals[#refusals + 1] = refusal(key, "outside supported range")
      else
        result[key] = value
      end
    elseif definition.kind == "nullable-string" then
      if value ~= nil and (type(value) ~= "string" or #value > definition.maximum) then
        refusals[#refusals + 1] = refusal(key, "must be null or a bounded string")
      else
        result[key] = value
      end
    end
  end

  if #refusals > 0 then
    return nil, refusals
  end
  return result, refusals
end

function M.sameConfig(left, right)
  if type(left) ~= "table" or type(right) ~= "table" then
    return false
  end
  for key in pairs(DEFINITIONS) do
    if left[key] ~= right[key] then
      return false
    end
  end
  return true
end

function M.newState()
  return {
    schemaVersion = M.STATE_SCHEMA_VERSION,
    monitoringStartedAt = nil,
    localDate = nil,
    systemStartupsToday = 0,
    systemStartupsLifetime = 0,
    controllerRebootsObservedToday = 0,
    controllerRebootsObservedLifetime = 0,
    lastBootId = nil,
    lastExecutionControllerIdentity = nil,
    lastPrimaryControllerIdentity = nil,
    lastClassification = nil,
    lastConfidence = nil,
    lastEventId = nil,
    recentEventIds = {},
    notificationIntentsToday = 0,
    stormAggregateIssuedForDate = nil,
    serviceModeExpiresAt = nil,
    serviceModeExpiresEpoch = nil,
    lastReportStatus = "not-requested",
    lastReportAt = nil,
  }
end

local function nonNegativeInteger(value, fallback)
  if type(value) == "number" and value == math.floor(value) and value >= 0 then
    return value
  end
  return fallback
end

--- Restore only known state fields. A malformed or future document degrades to
--- defaults instead of preventing the Agent from arming its heartbeat timers.
function M.restoreState(raw)
  local state = M.newState()
  if type(raw) ~= "table" then
    return state
  end
  for _, key in ipairs({
    "monitoringStartedAt",
    "localDate",
    "lastBootId",
    "lastExecutionControllerIdentity",
    "lastPrimaryControllerIdentity",
    "lastClassification",
    "lastConfidence",
    "lastEventId",
    "stormAggregateIssuedForDate",
    "serviceModeExpiresAt",
    "lastReportStatus",
    "lastReportAt",
  }) do
    if raw[key] == nil or type(raw[key]) == "string" then
      state[key] = raw[key]
    end
  end
  for _, key in ipairs({
    "systemStartupsToday",
    "systemStartupsLifetime",
    "controllerRebootsObservedToday",
    "controllerRebootsObservedLifetime",
    "notificationIntentsToday",
    "serviceModeExpiresEpoch",
  }) do
    state[key] = nonNegativeInteger(raw[key], state[key])
  end
  if type(raw.recentEventIds) == "table" then
    for _, value in ipairs(raw.recentEventIds) do
      if type(value) == "string" and #value >= 8 and #value <= 180 then
        state.recentEventIds[#state.recentEventIds + 1] = value
        if #state.recentEventIds >= 128 then
          break
        end
      end
    end
  end
  return state
end

local function contains(list, sought)
  for _, value in ipairs(list or {}) do
    if value == sought then
      return true
    end
  end
  return false
end

local function validDate(value)
  return type(value) == "string" and value:match("^%d%d%d%d%-%d%d%-%d%d$") ~= nil
end

local function normalizedReason(reason)
  reason = tostring(reason or ""):upper()
  if reason == "DIT_ADDING" or reason == "ADDING" then
    return "adding"
  elseif reason == "DIT_STARTUP" or reason == "STARTUP" then
    return "startup"
  elseif reason == "DIT_UPDATING" or reason == "UPDATING" or reason == "UPDATE" then
    return "updating"
  end
  return "unknown"
end

function M.serviceModeActive(state, nowEpoch)
  local expires = type(state) == "table" and tonumber(state.serviceModeExpiresEpoch) or nil
  return expires ~= nil and expires > (tonumber(nowEpoch) or 0)
end

function M.enterServiceMode(state, nowEpoch, minutes, expiresAt)
  local nextState = M.restoreState(state)
  local duration = tonumber(minutes) or M.DEFAULT_CONFIG.serviceModeMinutes
  duration = math.max(5, math.min(1440, math.floor(duration)))
  nextState.serviceModeExpiresEpoch = math.max(0, math.floor(tonumber(nowEpoch) or 0)) + duration * 60
  nextState.serviceModeExpiresAt = expiresAt
  return nextState
end

function M.exitServiceMode(state)
  local nextState = M.restoreState(state)
  nextState.serviceModeExpiresEpoch = nil
  nextState.serviceModeExpiresAt = nil
  return nextState
end

local function classify(input, state)
  local reason = normalizedReason(input.initReason)
  if reason == "adding" then
    return false, false, "Driver was added; this is not a system startup.", "high"
  elseif reason == "updating" then
    return false, false, "Driver was updated; this is not a system startup.", "high"
  end

  local systemStartup = reason == "startup"
  if not input.bootIdSupported then
    return systemStartup,
      false,
      systemStartup and "System startup observed; controller boot identity is unsupported."
        or "Startup reason was unavailable and controller boot identity is unsupported.",
      "reduced"
  end
  if state.lastBootId == nil and input.observedBootId ~= nil then
    return systemStartup,
      false,
      "First controller boot identity establishes a baseline; no earlier reboot is invented.",
      "medium"
  end
  local changed = input.observedBootId ~= nil and state.lastBootId ~= nil and input.observedBootId ~= state.lastBootId
  if changed then
    return systemStartup, true, "Controller boot identity changed since the prior observation.", "high"
  end
  return systemStartup, false, "No controller boot identity change was observed.", "medium"
end

local function configuredDecision(policy, eventNumber, threshold, serviceModeActive)
  if serviceModeActive then
    return "suppressed-service-mode"
  elseif policy == "disabled" or policy == "record-only" or eventNumber <= 0 then
    return "record-only"
  elseif policy == "every-observation" then
    return "notify"
  elseif eventNumber == 1 then
    return "notify"
  elseif eventNumber == threshold then
    return "escalate"
  elseif eventNumber > threshold then
    return "notify"
  end
  return "record-only"
end

--- Record one driver lifecycle observation.
--- @return table result { duplicate, observed, state, event? }
function M.recordStartup(stateInput, input, configInput)
  local state = M.restoreState(stateInput)
  local config = configInput or M.DEFAULT_CONFIG
  local eventId = type(input) == "table" and tostring(input.eventId or "") or ""
  if not eventId:match("^[A-Za-z0-9:_-]+$") or #eventId < 8 or #eventId > 180 then
    return { ok = false, error = "invalid event id", state = state }
  end
  if contains(state.recentEventIds, eventId) then
    return { ok = true, duplicate = true, observed = false, state = state }
  end

  local localDate = input.localDate
  local clockStatus = "trusted"
  if not validDate(localDate) then
    localDate = nil
    clockStatus = "unavailable"
  elseif state.localDate ~= nil and localDate < state.localDate then
    localDate = nil
    clockStatus = "regressed"
  elseif state.localDate ~= localDate then
    state.localDate = localDate
    state.systemStartupsToday = 0
    state.controllerRebootsObservedToday = 0
    state.notificationIntentsToday = 0
    state.stormAggregateIssuedForDate = nil
  end

  local systemStartup, controllerReboot, classification, confidence = classify(input, state)
  if config.startupMonitoring and systemStartup then
    state.systemStartupsLifetime = state.systemStartupsLifetime + 1
    if clockStatus == "trusted" then
      state.systemStartupsToday = state.systemStartupsToday + 1
    end
  end
  if config.startupMonitoring and controllerReboot then
    state.controllerRebootsObservedLifetime = state.controllerRebootsObservedLifetime + 1
    if clockStatus == "trusted" then
      state.controllerRebootsObservedToday = state.controllerRebootsObservedToday + 1
    end
  end

  local selectedEventNumber = config.countBasis == "controller-reboots" and state.controllerRebootsObservedToday
    or state.systemStartupsToday
  local activeServiceMode = M.serviceModeActive(state, input.nowEpoch)
  if not activeServiceMode and state.serviceModeExpiresEpoch ~= nil then
    state.serviceModeExpiresEpoch = nil
    state.serviceModeExpiresAt = nil
  end
  local observed = config.startupMonitoring and (systemStartup or controllerReboot)
  local decision = observed
      and clockStatus == "trusted"
      and configuredDecision(config.notificationPolicy, selectedEventNumber, config.startupThreshold, activeServiceMode)
    or "record-only"
  if decision == "notify" or decision == "escalate" then
    if state.notificationIntentsToday >= M.STORM_CEILING then
      if state.localDate ~= nil and state.stormAggregateIssuedForDate ~= state.localDate then
        decision = "storm-aggregate"
        state.stormAggregateIssuedForDate = state.localDate
      else
        decision = "record-only"
      end
    else
      state.notificationIntentsToday = state.notificationIntentsToday + 1
    end
  end

  if input.observedBootId ~= nil then
    state.lastBootId = tostring(input.observedBootId)
  end
  state.lastExecutionControllerIdentity = input.executionControllerIdentity
  state.lastPrimaryControllerIdentity = input.primaryControllerIdentity
  state.lastClassification = classification
  state.lastConfidence = confidence
  if config.startupMonitoring and state.monitoringStartedAt == nil then
    state.monitoringStartedAt = input.observedAt
  end
  state.lastEventId = eventId
  state.recentEventIds[#state.recentEventIds + 1] = eventId
  while #state.recentEventIds > 128 do
    table.remove(state.recentEventIds, 1)
  end

  if not observed then
    return { ok = true, duplicate = false, observed = false, state = state }
  end

  local primaryObserved = controllerReboot
    and input.executionControllerIdentity ~= nil
    and input.executionControllerIdentity == input.primaryControllerIdentity
  local thresholdReached = selectedEventNumber == config.startupThreshold
  local eventType = thresholdReached and "startup-threshold-reached"
    or (controllerReboot and "controller-reboot-observed" or "system-startup-observed")
  return {
    ok = true,
    duplicate = false,
    observed = true,
    state = state,
    event = {
      source_event_id = eventId,
      observed_at = input.observedAt,
      local_date = clockStatus == "trusted" and localDate or nil,
      event_type = eventType,
      classification = classification,
      confidence = confidence,
      clock_status = clockStatus,
      notification_decision = decision,
      system_startups_today = state.systemStartupsToday,
      system_startups_lifetime = state.systemStartupsLifetime,
      controller_reboots_observed_today = state.controllerRebootsObservedToday,
      controller_reboots_observed_lifetime = state.controllerRebootsObservedLifetime,
      execution_controller_identity = input.executionControllerIdentity,
      primary_controller_identity = input.primaryControllerIdentity,
      primary_controller_reboot_observed = primaryObserved,
      boot_id_supported = input.bootIdSupported == true,
    },
  }
end

return M
