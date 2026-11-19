--- VenueFlow: basic controls for a source (pure).
---
--- A cable box needs channel up and down, digits and a few favourite
--- channels; a streaming box needs arrows and play. This module is the fixed
--- vocabulary of keys an operator page may press, the Control4 command each
--- one becomes, and the engine that sends them.
---
--- A page never names a Control4 command. It names a KEY from the table
--- below; anything else is refused. The command goes to the source's own
--- Control4 device (`c4DeviceId`), the same device a room selects to show it.
---
--- Command names are the ones Control4 documents for the Satellite, Tuner,
--- TV, DVD and Media Player proxies (SDK_RESEARCH.md). There is no published
--- Cable proxy page; cable boxes are assumed to follow the Satellite set.
--- That another driver's SendToDevice reaches the box is NOT documented and
--- NOT yet seen on a controller: HARDWARE_VALIDATION.md.
---
--- There is no feedback. A key is "sent", never "confirmed": VenueFlow does
--- not know what channel a box is on.
---
--- One box often feeds many screens. A key changes every screen showing that
--- source; the page says so before the first press.

local U = require("venueflow.util")
local Errors = require("venueflow.errors")

local M = {}

--- The groups an installer switches on per source.
M.GROUPS = { "channel", "keypad", "navigation", "transport" }

--- key -> { group, Control4 command }
M.KEYS = {
  CH_UP = { "channel", "PULSE_CHANNEL_UP" },
  CH_DOWN = { "channel", "PULSE_CHANNEL_DOWN" },
  RECALL = { "channel", "RECALL" },
  DASH = { "keypad", "DASH" },
  ENTER = { "keypad", "ENTER" },
  UP = { "navigation", "UP" },
  DOWN = { "navigation", "DOWN" },
  LEFT = { "navigation", "LEFT" },
  RIGHT = { "navigation", "RIGHT" },
  SELECT = { "navigation", "ENTER" },
  GUIDE = { "navigation", "GUIDE" },
  INFO = { "navigation", "INFO" },
  MENU = { "navigation", "MENU" },
  CANCEL = { "navigation", "CANCEL" },
  PAGE_UP = { "navigation", "PAGE_UP" },
  PAGE_DOWN = { "navigation", "PAGE_DOWN" },
  PLAY = { "transport", "PLAY" },
  PAUSE = { "transport", "PAUSE" },
  STOP = { "transport", "STOP" },
  SCAN_FWD = { "transport", "SCAN_FWD" },
  SCAN_REV = { "transport", "SCAN_REV" },
  SKIP_FWD = { "transport", "SKIP_FWD" },
  SKIP_REV = { "transport", "SKIP_REV" },
}
for digit = 0, 9 do
  M.KEYS["NUM_" .. digit] = { "keypad", "NUMBER_" .. digit }
end

--- What a new source of each kind starts with. An installer can change it.
M.DEFAULTS = {
  cable = { "channel", "keypad" },
  satellite = { "channel", "keypad" },
  streaming = { "navigation", "transport" },
  music = { "transport" },
}

M.FAVORITES_MAX = 24
M.FAVORITE_NAME_MAX = 24
M.CHANNEL_MAX = 8
--- Longest gap worth waiting between two keys of one channel number.
M.KEY_SPACING_MS = 350

function M.defaults(kind)
  return U.copy(M.DEFAULTS[kind] or {})
end

--- A channel number: digits, optionally one dash or dot and more digits
--- ("206", "5-1", "12.3").
function M.validChannel(channel)
  if type(channel) ~= "string" or #channel == 0 or #channel > M.CHANNEL_MAX then
    return false
  end
  return channel:match("^%d+$") ~= nil or channel:match("^%d+[%-%.]%d+$") ~= nil
end

--- The Control4 commands that dial a channel, in order.
function M.sequence(channel, enter)
  local out = {}
  for ch in tostring(channel):gmatch(".") do
    if ch:match("%d") then
      out[#out + 1] = "NUMBER_" .. ch
    else
      out[#out + 1] = "DASH"
    end
  end
  if enter ~= false then
    out[#out + 1] = "ENTER"
  end
  return out
end

function M.has(source, group)
  return type(source) == "table" and U.contains(U.list(source.controls), group)
end

--- What an operator page is told about a source's controls, or nil.
function M.describe(source)
  local groups = {}
  for _, g in ipairs(M.GROUPS) do
    if M.has(source, g) then
      groups[#groups + 1] = g
    end
  end
  if #groups == 0 or source.c4DeviceId == nil then
    return nil
  end
  local favorites = {}
  for _, f in ipairs(U.list(source.favorites)) do
    if type(f) == "table" and M.validChannel(f.channel) then
      favorites[#favorites + 1] = { id = f.id, name = f.name, channel = f.channel }
    end
  end
  return { groups = groups, favorites = favorites }
end

-- ─── Engine ─────────────────────────────────────────────────────────────────

local Engine = {}
Engine.__index = Engine

--- deps = { index() -> ix, adapter() -> adapter, timers = { set, cancel },
---          diag = Diag, spacingMs? }
function M.new(deps)
  local self = setmetatable({}, Engine)
  self.deps = deps
  self.spacingMs = deps.spacingMs or M.KEY_SPACING_MS
  self.pending = {} -- { deviceId, command, source, sourceId, seq }
  self.busy = false
  self.sent = 0
  self.seq = 0 -- one number per key press or channel being dialled
  self.mode = nil -- the control mode the waiting keys were pressed in
  return self
end

local function refuse(code, detail)
  local out = Errors.fail(code, detail)
  out.status = "failed"
  return out
end

function Engine:_source(sourceId, opts)
  local ix = self.deps.index()
  local source = ix and ix.sources[sourceId or ""] or nil
  if source == nil or source.enabled == false then
    return nil, refuse("VF_NOT_FOUND", "unknown source " .. tostring(sourceId))
  end
  if not opts.access:source(source) then
    return nil, refuse("VF_FORBIDDEN", "profile may not use this source")
  end
  if not opts.access:flag("sourceControl") then
    return nil, refuse("VF_FORBIDDEN", "profile may not use source controls")
  end
  if type(source.c4DeviceId) ~= "number" then
    return nil, refuse("VF_DEVICE_UNMAPPED", "source has no Control4 device")
  end
  return source
end

--- Drops every waiting key of sequence `seq` (the rest of a channel number)
--- and says so in diagnostics: a box is never left half-dialled in silence.
function Engine:_stop(seq, sourceName, why)
  local kept, dropped = {}, 0
  for _, job in ipairs(self.pending) do
    if job.seq == seq then
      dropped = dropped + 1
    else
      kept[#kept + 1] = job
    end
  end
  self.pending = kept
  self.deps.diag:add(
    "warning",
    "source",
    "VF_CANCELLED",
    string.format("%s: %d key(s) not sent: %s", tostring(sourceName), dropped, why)
  )
end

--- Is the source a waiting key was pressed for still the same Control4 device
--- in the configuration that runs now? nil when yes, otherwise why not.
function Engine:_changed(job)
  local ix = self.deps.index()
  local source = ix and ix.sources and ix.sources[job.sourceId or ""] or nil
  if source == nil or source.enabled == false then
    return "the source is no longer in the configuration"
  end
  if source.c4DeviceId ~= job.deviceId then
    return "the source's Control4 device changed"
  end
  return nil
end

function Engine:_pump()
  if self.busy then
    return
  end
  local job = table.remove(self.pending, 1)
  while job ~= nil do
    local why = self:_changed(job)
    if why == nil then
      break
    end
    table.insert(self.pending, 1, job)
    self:_stop(job.seq, job.source, why)
    job = table.remove(self.pending, 1)
  end
  if job == nil then
    return
  end
  self.busy = true
  local ok, sent, why = pcall(function()
    return self.deps.adapter().deviceCommand(job.deviceId, job.command, {})
  end)
  if not ok or sent == false then
    self.deps.diag:add(
      "warning",
      "source",
      "VF_DISPATCH_FAILED",
      string.format("%s: %s was not sent", tostring(job.source), job.command),
      { detail = tostring(ok and why or sent) }
    )
  else
    self.sent = self.sent + 1
  end
  self.deps.timers.set("VfSourceKeys", self.spacingMs, function()
    self.busy = false
    self:_pump()
  end)
end

function Engine:_send(source, commands, label, opts)
  if #self.pending + #commands > 64 then
    return refuse("VF_UNSUPPORTED", "too many keys are waiting; try again in a moment")
  end
  self.seq = self.seq + 1
  for _, command in ipairs(commands) do
    self.pending[#self.pending + 1] = {
      deviceId = source.c4DeviceId,
      command = command,
      source = source.name,
      sourceId = source.id,
      seq = self.seq,
    }
  end
  self.deps.diag:add(
    "info",
    "source",
    nil,
    string.format("%s: %s", tostring(source.name), label),
    { who = opts.origin }
  )
  self:_pump()
  -- "sent" is all VenueFlow can say: a box gives no feedback.
  return { ok = true, status = "ok", data = { sent = #commands, feedback = false } }
end

--- One key press.
function Engine:key(sourceId, key, opts)
  local spec = M.KEYS[key or ""]
  if spec == nil then
    return refuse("VF_INVALID_PAYLOAD", "unknown key " .. tostring(key))
  end
  local source, failure = self:_source(sourceId, opts)
  if source == nil then
    return failure
  end
  if not M.has(source, spec[1]) then
    return refuse("VF_UNSUPPORTED", "this source has no " .. spec[1] .. " controls")
  end
  return self:_send(source, { spec[2] }, key, opts)
end

--- Dials a channel: a favourite by id, or a number typed on the page.
function Engine:tune(sourceId, target, opts)
  local source, failure = self:_source(sourceId, opts)
  if source == nil then
    return failure
  end
  if not M.has(source, "keypad") then
    return refuse("VF_UNSUPPORTED", "this source has no keypad controls")
  end
  local channel, label = target.channel, nil
  if target.favoriteId ~= nil then
    channel = nil
    for _, f in ipairs(U.list(source.favorites)) do
      if type(f) == "table" and f.id == target.favoriteId then
        channel, label = f.channel, tostring(f.name)
      end
    end
    if channel == nil then
      return refuse("VF_NOT_FOUND", "unknown favourite " .. tostring(target.favoriteId))
    end
  end
  if not M.validChannel(channel) then
    return refuse("VF_INVALID_PAYLOAD", "a channel is digits, with at most one dash or dot")
  end
  return self:_send(
    source,
    M.sequence(channel, source.tuneEnter),
    "channel " .. channel .. (label and (" (" .. label .. ")") or ""),
    opts
  )
end

--- Drops keys that have not left yet.
function Engine:clear()
  self.pending = {}
end

--- A new configuration is being loaded (Core:load), in control mode `mode`.
--- A channel already being dialled finishes: cutting it off would leave a
--- partial number typed into the box, after the page was told how many keys
--- were sent. Each waiting key is checked again just before it leaves
--- (`_pump`): if its source is no longer the same Control4 device in the new
--- configuration, the rest of that sequence stops. If the control mode
--- changed (Simulation <-> Live), every waiting key stops: they were pressed
--- for the other mode's devices. Either way diagnostics say what was dropped.
function Engine:reconfigure(mode)
  if self.mode ~= nil and mode ~= self.mode then
    local order, names = {}, {}
    for _, job in ipairs(self.pending) do
      if names[job.seq] == nil then
        order[#order + 1] = job.seq
        names[job.seq] = job.source
      end
    end
    for _, seq in ipairs(order) do
      self:_stop(seq, names[seq], "the control mode changed")
    end
  end
  self.mode = mode
end

return M
