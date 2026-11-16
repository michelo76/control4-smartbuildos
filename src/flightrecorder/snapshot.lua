--- Flight Recorder diagnostic snapshots (pure).
---
--- A snapshot is DIAGNOSTIC EVIDENCE, not a project backup: versions and
--- registration, the recording configuration and its limits, queue and
--- upload health, the selected sources' current observations, the recent
--- recorded events the driver still holds, and explicit warnings about what
--- is missing. Secrets are redacted before the document exists; sizes are
--- bounded by trimming the recent events, then the observations, and the
--- document says so.

local Envelope = require("sbos.envelope")

local M = {}

M.LIMITS = { max_bytes = 64 * 1024, observations = 200, recent = 100, warnings = 40 }

local function copyList(list, limit)
  local out = {}
  for i, item in ipairs(list or {}) do
    if i > limit then
      break
    end
    out[#out + 1] = item
  end
  return out
end

--- @param input table { job_id, request_id?, requested_by?, now_iso, agent = {...}, module = {...},
---   config = {...} (validated config), plan_summary = {...}, queue = {...}|nil, observations = {...},
---   recent = {...}, warnings = {...} }
--- @return table document
function M.build(input)
  local warnings = copyList(input.warnings, M.LIMITS.warnings)
  local sources = {}
  for _, s in ipairs((input.config or {}).sources or {}) do
    sources[#sources + 1] = {
      id = s.id,
      kind = s.kind,
      device_id = s.device_id,
      variable = s.variable,
      event = s.event,
      label = s.label,
      category = s.category,
      enabled = s.enabled,
      debounce_ms = s.debounce_ms,
      coalesce_ms = s.coalesce_ms,
      min_change = s.min_change,
    }
  end
  local doc = {
    schema_version = 1,
    kind = "flight_recorder_snapshot",
    job_id = input.job_id,
    request_id = input.request_id,
    requested_by = input.requested_by,
    captured_at = input.now_iso,
    not_a_backup = true,
    coverage = {
      "versions and registration",
      "recording configuration and limits",
      "queue and upload health as last reported by the Agent",
      "current values of selected sources",
      "recent recorded events held by the driver",
    },
    not_collected = {
      "arbitrary driver properties",
      "full Director or driver logs",
      "unselected variables",
      "credentials, codes, tokens (redacted when they appear)",
    },
    agent = input.agent or {},
    module = input.module or {},
    configuration = {
      version = (input.config or {}).version,
      enabled = (input.config or {}).enabled,
      budgets = (input.config or {}).budgets,
      exclusions = (input.config or {}).exclusions,
      privacy = (input.config or {}).privacy,
      sources = sources,
      plan = input.plan_summary,
    },
    queue = input.queue,
    observations = copyList(input.observations, M.LIMITS.observations),
    recent_events = copyList(input.recent, M.LIMITS.recent),
    warnings = warnings,
    truncation = { observations = 0, recent_events = 0 },
  }
  if input.queue == nil then
    doc.warnings[#doc.warnings + 1] =
      "queue health unavailable: the Agent has not reported it since this driver registered"
  end
  if #(input.observations or {}) > M.LIMITS.observations then
    doc.truncation.observations = #input.observations - M.LIMITS.observations
  end
  if #(input.recent or {}) > M.LIMITS.recent then
    doc.truncation.recent_events = #input.recent - M.LIMITS.recent
  end
  doc = Envelope.redact(doc)
  -- Size bound: trim recent events first, then observations.
  while Envelope.approxSize(doc, 0, M.LIMITS.max_bytes * 4) > M.LIMITS.max_bytes do
    if #doc.recent_events > 0 then
      table.remove(doc.recent_events)
      doc.truncation.recent_events = doc.truncation.recent_events + 1
    elseif #doc.observations > 0 then
      table.remove(doc.observations)
      doc.truncation.observations = doc.truncation.observations + 1
    else
      doc.warnings[#doc.warnings + 1] = "document exceeded the size limit after trimming; configuration list truncated"
      doc.configuration.sources = {}
      break
    end
  end
  if doc.truncation.recent_events > 0 or doc.truncation.observations > 0 then
    doc.warnings[#doc.warnings + 1] = string.format(
      "truncated to fit %d KB: %d recent event(s) and %d observation(s) omitted",
      math.floor(M.LIMITS.max_bytes / 1024),
      doc.truncation.recent_events,
      doc.truncation.observations
    )
  end
  return doc
end

--- Job lifecycle helper: statuses queued → running → completed | failed |
--- expired. The driver keeps at most `maxJobs` jobs and expires the rest.
M.STATUSES = { queued = true, running = true, completed = true, failed = true, expired = true }

function M.newJob(jobId, requestId, requestedBy, now)
  return {
    job_id = jobId,
    request_id = requestId,
    requested_by = requestedBy,
    status = "queued",
    created_at = now,
    updated_at = now,
    error = nil,
  }
end

function M.transition(job, status, now, err)
  if not M.STATUSES[status] then
    return false
  end
  job.status = status
  job.updated_at = now
  if err ~= nil then
    job.error = tostring(err):sub(1, 400)
  end
  return true
end

return M
