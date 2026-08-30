--- Shared child-driver plumbing for the Bond suite.
---
--- Every Bond child (fan / light / shade / …) has the same relationship with
--- the gateway: a consumer CONTROL binding (always binding 1), an identity
--- handshake, state pushes, action requests, rename requests, and the
--- dual-path transport lesson from the Protect suite (SendToProxy over the
--- binding is documented, SendToDevice → ExecuteCommand is the path measured
--- to work in the field — ask on BOTH, let the gateway answer on its
--- preferred one). Doing that once here keeps each child driver down to its
--- proxy mapping.
---
--- Usage from a child driver, after the vendored handlers are required:
---
---   local child = require("bond.child")
---   child.setup({
---     defaultNamePrefix = "Bond Fan",
---     onIdentity = function(identity) ... end,  -- decoded documents
---     onState = function(state) ... end,        -- decoded state doc
---     onActionResult = function(result) ... end,
---   })
---   child.action("SetSpeed", 3)
---
--- setup() registers the protocol handlers (RFP + EC twins), the binding
--- hook (OBC), and the identity retry timer wiring is left to the driver's
--- lifecycle via child.requestIdentity()/child.armRetry().

local log = require("lib.logging")
local persist = require("lib.persist")

JSON = JSON or require("JSON")

local M = {}

--- The gateway's consumer-side binding id on every child.
M.GATEWAY_BINDING = 1

--- Exact filename the gateway ships as. Substring matching would catch
--- sibling children; exact is the measured-safe discovery key.
local GATEWAY_FILES = { ["bond-bridge.c4z"] = true, ["bond-bridge.c4i"] = true }

local IDENTITY_PERSIST = "bond_identity"
local AUTONAME_PERSIST = "auto_name_last"
local RETRY_TIMER = "BondIdentityRetry"

local state = {
  opts = {},
  identity = nil,
  gatewayDeviceId = nil,
}

--- The decoded identity: { id, fn, name, type, subtype, location,
--- actions (list), actionSet (set), props (table), state (table) }, or nil
--- until the gateway has answered (or the persisted copy loaded).
function M.identity()
  return state.identity
end

--- Whether the device's action list carries `name`. False while unidentified.
function M.hasAction(name)
  local identity = state.identity
  if identity == nil or identity.actionSet == nil then
    return false
  end
  return identity.actionSet[name] == true
end

--- The gateway's device id, found once by exact driver filename.
function M.findGatewayDeviceId()
  if state.gatewayDeviceId ~= nil then
    return state.gatewayDeviceId
  end
  local ok, devices = pcall(function()
    return C4:GetDevices({})
  end)
  if not ok or type(devices) ~= "table" then
    return nil
  end
  for rawId, device in pairs(devices) do
    local id = tonumber(rawId)
    local file = tostring((type(device) == "table" and device.driverFileName) or "")
    if id ~= nil and GATEWAY_FILES[file] then
      state.gatewayDeviceId = id
      return id
    end
  end
  return nil
end

--- Sends a request to the gateway down BOTH paths, with `requester` so the
--- device-path answer can come straight back.
function M.askGateway(command, params)
  params = params or {}
  SendToProxy(M.GATEWAY_BINDING, command, params)
  local gatewayId = M.findGatewayDeviceId()
  if gatewayId ~= nil then
    params.requester = tostring(C4:GetDeviceID())
    SendToDevice(gatewayId, command, params)
  end
end

--- Asks the gateway who this child is. Called at init, on bind, and by the
--- retry timer until answered (the Protect round-3 lesson: a gateway bound
--- or updated later never heard a single init-time ask).
function M.requestIdentity()
  UpdateProperty("Gateway Link", "Asked gateway at " .. os.date("%H:%M:%S") .. " - waiting for a reply")
  M.askGateway("BOND_GET_DEVICE", {})
end

--- Arms the 60s ask-again timer; disarms itself once identified.
function M.armRetry()
  CancelTimer(RETRY_TIMER)
  SetTimer(RETRY_TIMER, 60 * ONE_SECOND, function()
    if state.identity == nil then
      M.requestIdentity()
    end
  end, true)
end

function M.cancelRetry()
  CancelTimer(RETRY_TIMER)
end

--- Requests a Bond action through the gateway. Scalars ride as strings
--- (SendToDevice serializes loosely — the gateway re-derives the type);
--- tables ride as JSON text.
--- @param action string The Bond action name.
--- @param argument any|nil Number, string, or table.
function M.action(action, argument)
  local params = { action = action }
  if type(argument) == "table" then
    params.argument = JSON:encode(argument)
  elseif argument ~= nil then
    params.argument = tostring(argument)
  end
  UpdateProperty("Last Control", action .. ": sent " .. os.date("%H:%M:%S"))
  M.askGateway("BOND_ACTION", params)
end

--- Renames this child's protocol AND proxy devices, guarded so a dealer's
--- own rename is never clobbered: only the install-default name and the
--- driver's own last write are eligible (force overrides, for the explicit
--- Rename action).
function M.autoName(name, force)
  name = tostring(name or "")
  if name == "" then
    return
  end
  local prefix = tostring(state.opts.defaultNamePrefix or "")
  local lastAuto = persist:get(AUTONAME_PERSIST, "")
  local ids = { C4:GetDeviceID() }
  local ok, proxyId = pcall(function()
    return C4:GetProxyDevices()
  end)
  if ok and type(proxyId) == "number" then
    table.insert(ids, proxyId)
  elseif ok and type(proxyId) == "table" then
    -- Multi-proxy drivers (fireplace): rename only the FIRST proxy — that
    -- tile carries the device's name; the others ("Flame Up", "Flame Down")
    -- keep their function names from the XML.
    for _, id in ipairs(proxyId) do
      if type(id) == "number" then
        table.insert(ids, id)
        break
      end
    end
  end
  local renamed = false
  for _, id in ipairs(ids) do
    local current = tostring(C4:GetDeviceData(id, "name") or "")
    local isDefault = prefix ~= "" and current:sub(1, #prefix) == prefix
    if current ~= name and (force or isDefault or (lastAuto ~= "" and current == lastAuto)) then
      pcall(function()
        C4:RenameDevice(id, name)
      end)
      renamed = true
    end
  end
  if renamed then
    persist:set(AUTONAME_PERSIST, name)
  end
end

--- JSON decode that never throws.
local function decodeJson(text)
  if type(text) ~= "string" or text == "" then
    return nil
  end
  local ok, decoded = pcall(function()
    return JSON:decode(text)
  end)
  if ok and type(decoded) == "table" then
    return decoded
  end
  return nil
end

--- Decodes the gateway's identity payload into the shape drivers use.
local function decodeIdentity(tParams)
  local actions = decodeJson(tParams.actions_json) or {}
  local actionSet = {}
  for _, name in ipairs(actions) do
    actionSet[tostring(name)] = true
  end
  return {
    id = tostring(tParams.id or ""),
    fn = tostring(tParams.fn or ""),
    name = tostring(tParams.name or "Bond Device"),
    type = tostring(tParams.type or ""),
    subtype = tParams.subtype and tostring(tParams.subtype) or nil,
    location = tostring(tParams.location or ""),
    actions = actions,
    actionSet = actionSet,
    props = decodeJson(tParams.props_json) or {},
    state = decodeJson(tParams.state_json) or {},
  }
end

--- Loads the persisted identity (survives Director restarts while the
--- gateway is still syncing). Guarded by SHAPE, not nil.
function M.restoreIdentity()
  local cached = persist:get(IDENTITY_PERSIST)
  if type(cached) == "table" and cached.id ~= nil then
    state.identity = cached
  end
  return state.identity
end

function M.forget()
  state.identity = nil
  persist:delete(IDENTITY_PERSIST)
  persist:delete(AUTONAME_PERSIST)
end

--- Wires the protocol handlers. Call once at file scope, after the vendored
--- handlers are required (RFP/EC/OBC exist).
--- @param opts table { defaultNamePrefix, onIdentity, onState, onActionResult }
function M.setup(opts)
  state.opts = opts or {}

  local function handleIdentity(tParams)
    tParams = tParams or {}
    state.identity = decodeIdentity(tParams)
    persist:set(IDENTITY_PERSIST, state.identity)
    UpdateProperty(
      "Gateway Link",
      string.format("OK - identified as '%s' at %s", state.identity.name, os.date("%H:%M:%S"))
    )
    M.autoName(state.identity.name)
    if state.opts.onIdentity then
      state.opts.onIdentity(state.identity)
    end
    if state.identity.state ~= nil and state.opts.onState then
      state.opts.onState(state.identity.state)
    end
  end

  local function handleState(tParams)
    tParams = tParams or {}
    -- A state push before identity means the gateway knows us but we missed
    -- the handshake (bound later, updated later): re-ask instead of
    -- ignoring pushes forever.
    if state.identity == nil then
      M.requestIdentity()
      return
    end
    local doc = decodeJson(tParams.state_json)
    if doc == nil then
      return
    end
    state.identity.state = doc
    if state.opts.onState then
      state.opts.onState(doc)
    end
  end

  local function handleActionResult(tParams)
    tParams = tParams or {}
    local action = tostring(tParams.action or "")
    if tostring(tParams.ok or "") == "true" then
      UpdateProperty("Last Control", action .. ": ok " .. os.date("%H:%M:%S"))
    else
      log:warn("Action %s failed: %s", action, tostring(tParams.detail or "unknown"))
      UpdateProperty("Last Control", action .. ": FAILED - " .. tostring(tParams.detail or "unknown"))
    end
    if state.opts.onActionResult then
      state.opts.onActionResult(tParams)
    end
  end

  RFP.BOND_DEVICE = function(_, _, tParams)
    handleIdentity(tParams)
  end
  RFP.BOND_STATE = function(_, _, tParams)
    handleState(tParams)
  end
  RFP.BOND_ACTION_RESULT = function(_, _, tParams)
    handleActionResult(tParams)
  end
  EC.BOND_DEVICE = handleIdentity
  EC.BOND_STATE = handleState
  EC.BOND_ACTION_RESULT = handleActionResult
  EC.BOND_RENAME = function(tParams)
    M.autoName(tostring((tParams or {}).name or (state.identity or {}).name or ""), true)
  end

  OBC = OBC or {}
  OBC[M.GATEWAY_BINDING] = function(_, _, bIsBound)
    if bIsBound then
      M.requestIdentity()
    end
  end
end

--- Test hook: reset module state between loads.
function M._reset()
  state.identity = nil
  state.gatewayDeviceId = nil
  state.opts = {}
end

return M
