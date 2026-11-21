-- A two-sided Director for unit tests: several drivers in ONE Lua state,
-- each with its own EC table and Properties, exchanging C4:SendToDevice
-- frames the way a controller would hand them to ExecuteCommand.
--
-- Delivery is a switch, because the order of a reply and the sender's own
-- bookkeeping depends on it:
--
--   "async"  the frame is queued and delivered by drain() after the sender's
--            handler has returned (what the Director emulator models).
--   "sync"   the receiver's handler runs INSIDE the sender's SendToDevice
--            call, before it returns. Not confirmed on hardware; a sender
--            must be correct either way, and only this mode can prove it.
--
-- Empty-string params are dropped unless the sender passes allowEmptyValues
-- (the fourth SendToDevice argument), as Control4 documents for SendToDevice
-- (src/lib/utils.lua). Turn it off with D.dropEmpty = false.
--
-- Timers set while a driver is "current" fire as that driver (SetTimer is
-- the test's own; call D.wrapTimer(cb) when storing a callback).

local D = {
  mode = "async",
  dropEmpty = true,
  devices = {},
  queue = {},
  frames = {},
  current = nil,
}

--- Registers a driver: id -> { EC = {}, Properties = {} } (both created when
--- missing). Returns the context.
function D.add(id, ctx)
  ctx = ctx or {}
  ctx.id = id
  ctx.EC = ctx.EC or {}
  ctx.Properties = ctx.Properties or {}
  D.devices[id] = ctx
  return ctx
end

--- Runs fn as driver `id`: its EC, its Properties, its C4:GetDeviceID().
--- Nests (a sync frame runs the receiver inside the sender).
function D.as(id, fn, ...)
  local dev = assert(D.devices[id], "unknown device " .. tostring(id))
  local saved = { current = D.current, EC = EC, Properties = Properties }
  D.current = dev
  EC = dev.EC
  Properties = dev.Properties
  local results = { pcall(fn, ...) }
  D.current = saved.current
  EC = saved.EC
  Properties = saved.Properties
  if not results[1] then
    error(results[2], 0)
  end
  return unpack(results, 2)
end

local function deliver(frame)
  frame.delivered = true
  D.as(frame.to, function()
    -- The vendor dispatcher every driver here uses (handlers.lua): it looks
    -- the command up in the CURRENT EC and xpcalls the handler.
    ExecuteCommand(frame.command, frame.params)
  end)
end

--- C4:SendToDevice from whichever driver is current.
function D.send(toId, command, params, allowEmpty)
  local copy = {}
  for k, v in pairs(params or {}) do
    if not (D.dropEmpty and allowEmpty ~= true and v == "") then
      copy[k] = v
    end
  end
  local frame = {
    from = D.current and D.current.id or nil,
    to = tonumber(toId),
    command = command,
    params = copy,
    allowEmpty = allowEmpty == true,
  }
  D.frames[#D.frames + 1] = frame
  if D.devices[frame.to] == nil then
    return
  end
  if D.mode == "sync" then
    deliver(frame)
  else
    D.queue[#D.queue + 1] = frame
  end
end

--- Delivers queued frames (async mode) until none are left.
function D.drain()
  local n = 0
  while #D.queue > 0 do
    deliver(table.remove(D.queue, 1))
    n = n + 1
    assert(n < 10000, "frames keep coming: a delivery loop")
  end
  return n
end

--- Binds a timer callback to the driver that set it.
function D.wrapTimer(cb)
  local owner = D.current and D.current.id or nil
  if owner == nil then
    return cb
  end
  return function(...)
    return D.as(owner, cb, ...)
  end
end

--- Frames sent so far, filtered.
function D.framesOf(command, to)
  local out = {}
  for _, f in ipairs(D.frames) do
    if f.command == command and (to == nil or f.to == to) then
      out[#out + 1] = f
    end
  end
  return out
end

--- Installs SendToDevice / GetDeviceID on the shim's C4.
function D.install(c4)
  c4.SendToDevice = function(_, id, command, params, allowEmpty)
    D.send(id, command, params, allowEmpty)
  end
  c4.GetDeviceID = function()
    return D.current and D.current.id or nil
  end
end

return D
