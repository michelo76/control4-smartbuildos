--- Logic Blocks — the read-only app document (pure).
---
--- One table the dealer page renders, built from the block runtime and a
--- few facts the driver supplies. It is a REPORT: nothing in it can be sent
--- back to change configuration, because Composer is the only place blocks
--- are configured.
---
--- What the page must be able to tell apart, and so what this states:
---   1. an input was received           history[].input
---   2. the block evaluated it          history[].decision / reason
---   3. an event was emitted            history[].events
---   4. equipment was confirmed         history[].confirmed — and only when
---      a feedback variable is mapped AND reported the expected value after
---      the event. Otherwise it says not_monitored / not_confirmed / already.
--- An emitted event is never presented as proof that equipment moved.
---
--- info = {
---   now, started_at, version, status, pack_status, read_only,
---   license = { status, source, tier },
---   clock = { day, tz, utc_offset },
---   legacy = { counters, flags, timers, once, state },
---   transport = { relay, host, host_state, port, mirror },
--- }

local Blocks = require("logic.blocks")
local Defs = require("logic.blockdefs")

local M = {}

M.SCHEMA = "logic_blocks.app.v1"
M.ACTIVITY = 120
M.EXPORT_ACTIVITY = 200

local function entry(e)
  return {
    seq = e.seq,
    at = e.at,
    slot = e.slot,
    name = e.name,
    type = e.type,
    origin = e.origin,
    run = e.run,
    cause = e.cause,
    input = e.input,
    decision = e.decision,
    reason = e.reason,
    events = e.events or {},
    confirmed = e.confirmed,
  }
end

local function templates()
  local out = {}
  for _, t in ipairs(Defs.TEMPLATES) do
    local def = Defs.normalize(t.raw)
    out[#out + 1] = {
      id = t.id,
      name = t.name,
      summary = t.summary,
      type_label = Defs.TYPES[Defs.typeOf(t.raw.type)].label,
      explanation = def and Defs.explain(def) or "",
      settings = def and Defs.settingsRows(def) or {},
      wiring = t.wiring,
      needs = t.needs,
    }
  end
  return out
end

local function types()
  local out = {}
  for _, id in ipairs(Defs.TYPE_ORDER) do
    local t = Defs.TYPES[id]
    local commands = {}
    for _, c in ipairs(t.commands) do
      commands[#commands + 1] = "BLOCK_" .. c:upper()
    end
    local events = {}
    for _, e in ipairs(t.events) do
      events[#events + 1] = Defs.EVENT_LABELS[e]
    end
    out[#out + 1] = { id = id, label = t.label, summary = t.summary, commands = commands, events = events }
  end
  return out
end

--- The full document for the page.
function M.build(blocks, info)
  info = info or {}
  local now = info.now or blocks:_now()
  local doc = {
    schema = M.SCHEMA,
    generated_at = now,
    source = "controller",
    driver = {
      version = info.version,
      status = info.status,
      pack_status = info.pack_status,
      read_only = info.read_only == true,
      started_at = info.started_at,
      config_revision = blocks.revision,
      schema_version = Blocks.VERSION,
      clock = info.clock or {},
    },
    license = info.license or {},
    capacity = blocks:counts(),
    blocks = {},
    retired = {},
    unreadable = {},
    legacy = info.legacy or {},
    activity = {},
    recovery = Blocks.copy(blocks.recovery),
    diagnostics = {
      restore_failed = blocks.restoreFailed and blocks.restoreFailed.why or nil,
      missing_mappings = blocks:missingMappings(),
      stats = Blocks.copy(blocks.stats),
      clock_jump = Blocks.copy(blocks.lastJump),
      limits = {
        slots = Defs.SLOTS,
        inputs_per_block = Defs.MAX_INPUTS,
        history = Blocks.LIMITS.history,
        history_saved = Blocks.LIMITS.history_saved,
        queue = Blocks.LIMITS.queue,
        inputs_per_window = Blocks.LIMITS.inputs_per_window,
        window_s = Blocks.LIMITS.window_s,
      },
      transport = info.transport or {},
    },
    templates = templates(),
    types = types(),
    authority = "Blocks are configured in Composer Pro, on this driver's Properties and Actions tabs. This page reports and simulates; it cannot change a block.",
  }
  doc.capacity.slots = Defs.SLOTS
  for slot = 1, Defs.SLOTS do
    local view = blocks:view(slot)
    if view.kind == "block" then
      doc.blocks[#doc.blocks + 1] = view
    elseif view.kind == "retired" then
      doc.retired[#doc.retired + 1] = view
    elseif view.kind == "unreadable" then
      doc.unreadable[#doc.unreadable + 1] = view
    end
  end
  for _, e in ipairs(blocks:activity({ limit = M.ACTIVITY })) do
    doc.activity[#doc.activity + 1] = entry(e)
  end
  doc.faults = 0
  for _, view in ipairs(doc.blocks) do
    if view.isolated ~= nil or (view.enabled and view.output.valid == false) then
      doc.faults = doc.faults + 1
    end
  end
  return doc
end

--- Filtered history for the Activity screen.
function M.activity(blocks, query)
  query = query or {}
  local out = {}
  for _, e in ipairs(blocks:activity({
    slot = tonumber(query.slot),
    decision = query.decision ~= nil and query.decision ~= "" and tostring(query.decision) or nil,
    since = tonumber(query.since),
    limit = tonumber(query.limit) or M.ACTIVITY,
  })) do
    out[#out + 1] = entry(e)
  end
  return { ok = true, generated_at = blocks:_now(), activity = out }
end

local SENSITIVE = { "token", "secret", "password", "passwd", "authorization", "bearer", "credential", "apikey", "api_key" }

local function sensitiveKey(k)
  local s = tostring(k):lower()
  for _, word in ipairs(SENSITIVE) do
    if s:find(word, 1, true) then
      return true
    end
  end
  return false
end

--- Blanks anything that looks like a secret: a sensitive key, a relay token
--- riding a URL (k=…), or a long hex/base64 run inside a string.
function M.redact(value, depth)
  depth = depth or 0
  if type(value) == "string" then
    local s = value:gsub("([%?&]k=)[%w%-_%.]+", "%1[redacted]")
    s = s:gsub("[Bb]earer%s+[%w%-_%.]+", "Bearer [redacted]")
    s = s:gsub("%f[%w][%x]+%f[%W]", function(run)
      if #run >= 24 then
        return "[redacted]"
      end
      return run
    end)
    return s
  end
  if type(value) ~= "table" or depth > 10 then
    return value
  end
  local out = {}
  for k, v in pairs(value) do
    if sensitiveKey(k) then
      out[k] = "[redacted]"
    else
      out[k] = M.redact(v, depth + 1)
    end
  end
  return out
end

--- The diagnostics export: the same report, bounded and redacted, with the
--- dealer's notes and the licensed company left out.
function M.export(blocks, info)
  local doc = M.build(blocks, info)
  doc.exported_at = doc.generated_at
  doc.export = "Logic Blocks diagnostics. Redacted: no tokens, no licence identifiers, no dealer notes."
  doc.templates, doc.types = nil, nil
  doc.license = { status = doc.license.status, source = doc.license.source, tier = doc.license.tier }
  for _, view in ipairs(doc.blocks) do
    view.notes = view.notes ~= nil and view.notes ~= "" and "[omitted]" or ""
  end
  local activity = {}
  for _, e in ipairs(blocks:activity({ limit = M.EXPORT_ACTIVITY })) do
    activity[#activity + 1] = entry(e)
  end
  doc.activity = activity
  return M.redact(doc)
end

--- The small document for the optional cloud mirror: what exists and
--- whether it is healthy. No source values, no history, no notes.
function M.summary(blocks, info)
  info = info or {}
  local out = {
    schema = "logic_blocks.summary.v1",
    generated_at = info.now or blocks:_now(),
    version = info.version,
    pack_status = info.pack_status,
    read_only = info.read_only == true,
    config_revision = blocks.revision,
    capacity = blocks:counts(),
    restore_failed = blocks.restoreFailed ~= nil,
    missing_mappings = #blocks:missingMappings(),
    blocks = {},
  }
  for slot = 1, Defs.SLOTS do
    local view = blocks:view(slot)
    if view.kind == "block" then
      out.blocks[#out.blocks + 1] = {
        slot = slot,
        name = view.name,
        tag = view.tag,
        type = view.type,
        enabled = view.enabled,
        state = view.output.state,
        valid = view.output.valid,
        isolated = view.isolated ~= nil,
        last_activity_at = view.last_accepted and view.last_accepted.at or nil,
      }
    end
  end
  return out
end

return M
