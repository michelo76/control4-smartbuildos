--- Shared plumbing for System Link companion drivers (light, relay, contact,
--- temperature, thermostat, shade): discovery of the bridge by exact
--- filename, the identity handshake, state pushes and control requests.
---
--- A companion presents ONE export the peer project shared. It never talks
--- to the cloud: everything goes through the bridge on the same controller
--- over the bindingless SendToDevice → EC path the rest of the suite uses.
---
--- Protocol (companion → bridge, all params strings):
---   SBOS_LINK_COMPANION_HELLO   { requester, export (name or ""), kind }
---   SBOS_LINK_COMPANION_CONTROL { requester, export, op, params (json) }
--- bridge → companion:
---   SBOS_LINK_COMPANION_EXPORTS { exports (json list of { id, name, kind, control, ops }) }
---   SBOS_LINK_COMPANION_STATE   { export, fields (json { suffix = value|null }), fresh, state }
---   SBOS_LINK_COMPANION_RESULT  { export, op, status, reason }

local log = require("lib.logging")
local persist = require("lib.persist")
JSON = JSON or require("JSON")

local M = {}

local BRIDGE_FILES = { ["smartbuildos-system-link.c4z"] = true, ["smartbuildos-system-link.c4i"] = true }
local RETRY_TIMER = "SlCompanionRetry"
local EXPORT_KEY = "sl_companion_export"

local state = { opts = {}, bridgeId = nil, export = nil, exports = {}, fresh = "unknown", fields = {} }

function M.findBridge()
  if state.bridgeId then
    return state.bridgeId
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
    if id and BRIDGE_FILES[file] then
      state.bridgeId = id
      return id
    end
  end
  return nil
end

--- opts = { kind, onState = fn(fields, fresh, meta), onExports = fn(list), onResult = fn(op, status, reason) }
function M.setup(opts)
  state.opts = opts or {}
  -- `false`, not nil: lib.persist answers a missing key with a table when the
  -- default is nil, and a table export never matches an incoming state.
  state.export = persist:get(EXPORT_KEY, false)
  if type(state.export) ~= "string" or state.export == "" then
    state.export = nil
  end
  EC.SBOS_LINK_COMPANION_EXPORTS = function(tParams)
    local ok, list = pcall(function()
      return JSON:decode(tostring((tParams or {}).exports or "[]"))
    end)
    state.exports = ok and type(list) == "table" and list or {}
    if state.opts.onExports then
      pcall(state.opts.onExports, state.exports)
    end
  end
  EC.SBOS_LINK_COMPANION_STATE = function(tParams)
    tParams = tParams or {}
    if state.export == nil or tostring(tParams.export or "") ~= state.export then
      return
    end
    local ok, fields = pcall(function()
      return JSON:decode(tostring(tParams.fields or "{}"))
    end)
    state.fields = ok and type(fields) == "table" and fields or {}
    state.fresh = tostring(tParams.fresh or "unknown")
    if state.opts.onState then
      pcall(
        state.opts.onState,
        state.fields,
        state.fresh,
        { remote_state = tParams.state, control = tParams.control == "true" }
      )
    end
  end
  EC.SBOS_LINK_COMPANION_RESULT = function(tParams)
    tParams = tParams or {}
    if state.export == nil or tostring(tParams.export or "") ~= state.export then
      return
    end
    if state.opts.onResult then
      pcall(
        state.opts.onResult,
        tostring(tParams.op or ""),
        tostring(tParams.status or ""),
        tostring(tParams.reason or "")
      )
    end
  end
end

function M.export()
  return state.export
end

function M.exports()
  return state.exports
end

function M.fields()
  return state.fields
end

function M.fresh()
  return state.fresh
end

function M.selectExport(name)
  name = tostring(name or "")
  if name == "" or name == "-" then
    state.export = nil
    persist:delete(EXPORT_KEY)
  else
    state.export = name
    persist:set(EXPORT_KEY, name)
  end
  state.fields = {}
  state.fresh = "unknown"
  M.hello()
end

function M.hello()
  local bridge = M.findBridge()
  if not bridge then
    UpdateProperty("Bridge Link", "No SmartBuildOS System Link found in this project")
    return false
  end
  UpdateProperty("Bridge Link", "Asked bridge at " .. os.date("%H:%M:%S"))
  pcall(function()
    C4:SendToDevice(
      bridge,
      "SBOS_LINK_COMPANION_HELLO",
      { requester = tostring(C4:GetDeviceID()), export = state.export or "", kind = tostring(state.opts.kind or "") }
    )
  end)
  return true
end

function M.armRetry()
  CancelTimer(RETRY_TIMER)
  SetTimer(RETRY_TIMER, 60 * ONE_SECOND, function()
    if state.fresh == "unknown" or next(state.exports) == nil then
      M.hello()
    end
  end, true)
end

function M.cancelRetry()
  CancelTimer(RETRY_TIMER)
end

--- Sends a control request to the bridge. The bridge answers with
--- SBOS_LINK_COMPANION_RESULT; the physical feedback arrives separately as
--- state, and only that updates the proxy.
function M.control(op, params)
  local bridge = M.findBridge()
  if not bridge or not state.export then
    return false
  end
  pcall(function()
    C4:SendToDevice(
      bridge,
      "SBOS_LINK_COMPANION_CONTROL",
      {
        requester = tostring(C4:GetDeviceID()),
        export = state.export,
        op = tostring(op),
        params = JSON:encode(params or {}),
      }
    )
  end)
  return true
end

function M._reset()
  state = { opts = {}, bridgeId = nil, export = nil, exports = {}, fresh = "unknown", fields = {} }
end

return M
