--- Bounded activation history + the "why did this happen" renderer.
---
--- History is a dealer-support feature (spec §39-§40), not telemetry: it
--- lives locally, holds mode-level records only (never per-light command
--- logs), and is capped so a busy house cannot grow it forever. Persistence
--- is injected and best-effort — losing history must never take
--- configuration with it, which is why it saves under its own key.

local M = {}

M.DEFAULT_LIMIT = 100
M.LIMITS = { 100, 250, 500 }

local History = {}
History.__index = History

--- @param opts table {limit?, persist? = {get,set}, key?}
function M.new(opts)
  opts = opts or {}
  local self = setmetatable({}, History)
  self.limit = opts.limit or M.DEFAULT_LIMIT
  self.persist = opts.persist
  self.key = opts.key or "ModeComposerHistory"
  self.entries = {}
  if self.persist then
    local saved = self.persist.get(self.key, nil)
    if type(saved) == "table" and type(saved.entries) == "table" then
      self.entries = saved.entries
      self:_trim()
    end
  end
  return self
end

function History:setLimit(limit)
  self.limit = tonumber(limit) or M.DEFAULT_LIMIT
  self:_trim()
  self:_save()
end

--- Record one activation (the engine's record shape). Newest first.
function History:add(record)
  table.insert(self.entries, 1, record)
  self:_trim()
  self:_save()
end

function History:_trim()
  while #self.entries > self.limit do
    table.remove(self.entries)
  end
end

function History:_save()
  if self.persist then
    self.persist.set(self.key, { entries = self.entries })
  end
end

function History:list(n)
  local out = {}
  for i = 1, math.min(n or #self.entries, #self.entries) do
    out[i] = self.entries[i]
  end
  return out
end

function History:clear()
  self.entries = {}
  self:_save()
end

--- Source metadata → one dealer-readable line (spec §38-§40).
local function describeSource(record, names)
  local meta = record.meta or {}
  local bits = { tostring(record.source or "UNKNOWN") }
  if meta.slot_name then
    bits[1] = string.format("%s (%s)", bits[1], meta.slot_name)
  end
  if meta.gesture then
    table.insert(bits, "gesture " .. tostring(meta.gesture))
  end
  if meta.hold_s then
    table.insert(bits, string.format("held %.1fs", meta.hold_s))
  end
  if meta.rule_id then
    table.insert(bits, "rule " .. tostring(meta.rule_id))
  end
  if meta.schedule_id then
    table.insert(bits, "schedule " .. tostring(meta.schedule_id))
  end
  if meta.device then
    table.insert(bits, "device " .. (names and names(meta.device) or tostring(meta.device)))
  end
  return table.concat(bits, ", ")
end

--- Render one entry as a compact history line.
--- @param names fn(deviceKey)->string? optional device-name resolver
--- @param modeName fn(modeId)->string
function M.renderLine(record, modeName, names, formatTime)
  local when = formatTime and formatTime(record.time) or tostring(record.time)
  local line = string.format(
    "%s  %s  %s  via %s",
    when,
    modeName(record.mode_id) or record.mode_id,
    record.result or "?",
    describeSource(record, names)
  )
  if record.failures and #record.failures > 0 then
    line = line .. string.format("  (%d failed)", #record.failures)
  end
  return line
end

--- Render the full "why did this happen" detail for one entry (spec §40).
function M.renderDetail(record, modeName, formatTime)
  local lines = {
    "Mode:        " .. (modeName(record.mode_id) or tostring(record.mode_id)),
    "Result:      " .. tostring(record.result),
    "When:        " .. (formatTime and formatTime(record.time) or tostring(record.time)),
    "Activation:  " .. tostring(record.activation_id),
    "Source:      " .. describeSource(record),
  }
  if record.previous_presence then
    table.insert(lines, "Prev. presence:  " .. (modeName(record.previous_presence) or record.previous_presence))
  end
  table.insert(
    lines,
    string.format(
      "Actions:     %d  (%d succeeded, %d failed)",
      record.actions or 0,
      record.succeeded or 0,
      #(record.failures or {})
    )
  )
  if record.preflight_warnings and record.preflight_warnings > 0 then
    table.insert(lines, string.format("Preflight:   %d warning(s)", record.preflight_warnings))
  end
  for _, f in ipairs(record.failures or {}) do
    table.insert(lines, string.format("  FAILED  %s — %s", tostring(f.device), tostring(f.detail)))
  end
  if record.error then
    table.insert(lines, "Error:       " .. tostring(record.error))
  end
  return table.concat(lines, "\n")
end

return M
