--- Fast answers: a short burst of heartbeats while a module's cloud job is
--- pending, so its result reaches the module in seconds instead of one
--- heartbeat interval later.
---
--- ── WHY ────────────────────────────────────────────────────────────────────
---
--- A module's cloud request (AI Core's ask, through modules/rpc) is answered
--- `{accepted, job_id}` at once; the RESULT comes back later as a queued
--- MODULE_COMMAND, and queued commands reach this Agent only on the answer to
--- a request it makes (heartbeat, device sync). The Realtime doorbell makes
--- that instant when it works; this is the fallback that does not depend on
--- it: check in every CADENCE_SECONDS until the job's result has arrived, the
--- doorbell has proved itself by ringing, or CAP_SECONDS have passed.
---
--- ── THE LIMITS IT KEEPS ────────────────────────────────────────────────────
---
---   * ONE burst, whatever the number of pending jobs: jobs join the live
---     burst, they never stack timers. Each job is waited for at most
---     CAP_SECONDS from its own acceptance; the burst ends when none is left.
---   * Never closer than CADENCE_SECONDS to the previous heartbeat of ANY
---     kind (the Agent's own timer, a doorbell ring, Send Heartbeat Now), and
---     never while one is in flight: at most 12 a minute, against the
---     platform's 60 a minute per address for the heartbeat route. The
---     Agent's own timer skips its beat under the same rule (busy()), so a
---     burst REPLACES the ordinary check-ins rather than adding to them.
---   * Not started while unpaired, while the last delivery failed (the Agent
---     is already in trouble with the cloud), or within QUIET_SECONDS of a
---     429. A failed burst heartbeat ends the burst; the ordinary heartbeat
---     carries on regardless.
---   * Nothing is persisted: a driver restart forgets the burst, and the
---     result then arrives on the ordinary heartbeat.
---
--- Pure: the clock is injected (milliseconds) and the glue owns timers and
--- I/O, so every decision here is tested without a controller.

local M = {}
M.__index = M

M.CADENCE_SECONDS = 5
M.CAP_SECONDS = 90
--- After a 429 from the platform: its rate-limit window is one minute.
M.QUIET_SECONDS = 60
--- A heartbeat with no answer after this long no longer blocks the burst
--- (the HTTP layer's own timeout should have ended it well before).
M.INFLIGHT_STALE_SECONDS = 30
--- Jobs tracked at once; more join the burst without being tracked.
M.MAX_JOBS = 16
--- The one Director timer the glue arms for a burst, and how often it looks:
--- every second, so the next beat leaves on the cadence and not up to a
--- whole cadence late when another heartbeat intervened. A look that finds
--- nothing to do costs nothing.
M.TIMER = "SmartBuildOSFastAnswers"
M.TICK_SECONDS = 1

local ID = "^[A-Za-z0-9][A-Za-z0-9._:-]*$"

--- The job a modules/rpc answer promises to deliver later, or nil.
---
--- `{ok: true, result: {accepted: true, job_id}}` with NO `state`: the job
--- ops (ask, analyze_room, …) whose result returns as deliver_result.
--- analyze_household also answers a job_id but with a `state`, and nothing
--- is delivered for it, so it must not start a burst that can only time out.
--- @param body any the decoded response body
--- @return string|nil jobId
function M.pendingJob(body)
  if type(body) ~= "table" or body.ok ~= true then
    return nil
  end
  local r = body.result
  if type(r) ~= "table" or r.accepted ~= true or r.state ~= nil then
    return nil
  end
  return M.jobKey(r.job_id)
end

--- A job id as the burst keys it: a string or a number (AI Core accepts
--- both), as text; nil for anything else.
function M.jobKey(id)
  if type(id) == "number" and id == math.floor(id) then
    id = string.format("%d", id)
  end
  if type(id) ~= "string" or #id > 128 or id:match(ID) == nil then
    return nil
  end
  return id
end

--- @param opts { now: fun(): number } milliseconds, monotonic where possible
function M.new(opts)
  local self = setmetatable({}, M)
  self.now = opts and opts.now or function()
    return os.time() * 1000
  end
  self:reset()
  self.stats = { bursts = 0, beats = 0, ended = {} }
  self.lastEnd = nil
  self.quietUntil = nil
  return self
end

function M:reset()
  self.active = false
  self.jobs = {}
  self.jobCount = 0
  self.startedAt = nil
end

--- Milliseconds from `t` to now; a clock that went backwards (a tick counter
--- wrapping, a test resetting) reads as "long ago", never as negative.
function M:since(t)
  if t == nil then
    return math.huge
  end
  local d = self.now() - t
  if d < 0 then
    return math.huge
  end
  return d
end

--- Whether a 429 is still being honoured. Bounded both ways, so a clock that
--- jumped cannot hold bursts off for longer than QUIET_SECONDS.
function M:quiet()
  if self.quietUntil == nil then
    return false
  end
  local left = self.quietUntil - self.now()
  return left > 0 and left <= M.QUIET_SECONDS * 1000
end

--- A job was accepted. Returns "started" (the glue arms the timer),
--- "joined" (a burst is already running) or "refused:<why>".
--- @param jobId string|nil
--- @param ctx { paired: boolean, failing: boolean }
function M:expect(jobId, ctx)
  if jobId == nil then
    return "refused:no job"
  end
  ctx = ctx or {}
  if ctx.paired ~= true then
    return "refused:unpaired"
  end
  if ctx.failing == true then
    return "refused:cloud failing"
  end
  if self:quiet() then
    return "refused:rate limited"
  end
  if self.jobs[jobId] == nil and self.jobCount < M.MAX_JOBS then
    self.jobs[jobId] = self.now()
    self.jobCount = self.jobCount + 1
  end
  if self.active then
    return "joined"
  end
  self.active = true
  self.startedAt = self.now()
  self.stats.bursts = self.stats.bursts + 1
  return "started"
end

function M:finish(reason)
  if not self.active then
    return false
  end
  self.stats.ended[reason] = (self.stats.ended[reason] or 0) + 1
  self.lastEnd = { reason = reason, at = self.now(), lasted_ms = self:since(self.startedAt) }
  self:reset()
  return true
end

--- What the timer should do now: "beat", "wait" or "stop" (and why).
--- @param ctx { paired: boolean }
function M:tick(ctx)
  if not self.active then
    return "stop", "idle"
  end
  if not (ctx and ctx.paired == true) then
    self:finish("unpaired")
    return "stop", "unpaired"
  end
  for id, at in pairs(self.jobs) do
    if self:since(at) >= M.CAP_SECONDS * 1000 then
      self.jobs[id] = nil
      self.jobCount = self.jobCount - 1
    end
  end
  if self.jobCount <= 0 then
    self:finish("cap")
    return "stop", "cap"
  end
  if self.inflightAt ~= nil and self:since(self.inflightAt) < M.INFLIGHT_STALE_SECONDS * 1000 then
    return "wait", "in flight"
  end
  -- The first beat one cadence after the acceptance, not at once: the job
  -- has only just been queued, and no answer is ready in a second.
  if
    self:since(self.lastBeatAt) < M.CADENCE_SECONDS * 1000 or self:since(self.startedAt) < M.CADENCE_SECONDS * 1000
  then
    return "wait", "cadence"
  end
  return "beat"
end

--- A heartbeat is in flight, or one left under CADENCE_SECONDS ago: the
--- Agent's own timer skips its beat rather than double one.
function M:busy()
  if self.inflightAt ~= nil and self:since(self.inflightAt) < M.INFLIGHT_STALE_SECONDS * 1000 then
    return true
  end
  return self:since(self.lastBeatAt) < M.CADENCE_SECONDS * 1000
end

--- Any heartbeat is leaving (burst = true for the burst's own).
function M:beatStarted(burst)
  self.inflightAt = self.now()
  self.lastBeatAt = self.inflightAt
  if burst then
    self.stats.beats = self.stats.beats + 1
  end
end

--- A heartbeat ended. A failure ends the burst; a 429 also keeps new
--- bursts away for QUIET_SECONDS. Returns true when a burst ended here.
function M:beatEnded(ok, status)
  self.inflightAt = nil
  if ok then
    return false
  end
  if tonumber(status) == 429 then
    self.quietUntil = self.now() + M.QUIET_SECONDS * 1000
  end
  return self:finish("failed")
end

--- A deliver_result for `jobId` reached the Agent. Returns true when that
--- was the last pending job (the burst is over).
function M:delivered(jobId)
  if jobId == nil or self.jobs[jobId] == nil then
    return false
  end
  self.jobs[jobId] = nil
  self.jobCount = self.jobCount - 1
  if self.jobCount <= 0 then
    return self:finish("delivered")
  end
  return false
end

--- The doorbell rang: it is live, and its own heartbeat collects the
--- result, so the burst stops adding load. Returns true when one ended.
function M:rang()
  return self:finish("rang")
end

--- Driver destroyed, unpaired.
function M:stop(reason)
  self.inflightAt = nil
  return self:finish(reason or "stopped")
end

--- One line for the Lua tab and the log. No ids, no secrets.
function M:status()
  local parts = {}
  if self.active then
    parts[#parts + 1] =
      string.format("burst active %ds, %d job(s) pending", math.floor(self:since(self.startedAt) / 1000), self.jobCount)
  else
    parts[#parts + 1] = "no burst"
  end
  parts[#parts + 1] = string.format("%d burst(s), %d burst heartbeat(s)", self.stats.bursts, self.stats.beats)
  local ended = {}
  for reason, n in pairs(self.stats.ended) do
    ended[#ended + 1] = reason .. "=" .. n
  end
  table.sort(ended)
  if #ended > 0 then
    parts[#parts + 1] = "ended: " .. table.concat(ended, " ")
  end
  if self.lastEnd ~= nil then
    parts[#parts + 1] = string.format(
      "last ended %s after %ds, %ds ago",
      self.lastEnd.reason,
      math.floor(self.lastEnd.lasted_ms / 1000),
      math.floor(self:since(self.lastEnd.at) / 1000)
    )
  end
  if self:quiet() then
    parts[#parts + 1] = "quiet after a 429"
  end
  return table.concat(parts, "; ")
end

return M
