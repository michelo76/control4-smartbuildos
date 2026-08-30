--[[==========================================================================
  Bond Bridge Gateway — parent driver

  Owns the connection to ONE Bond unit (a Bond Bridge fronting RF appliances,
  or a Smart by Bond appliance — same API either way): address, local token,
  the device inventory, the BPUP push subscription, and one provider CONTROL
  binding per (device, function) for the child drivers to attach to. A Bond
  ceiling fan with a light is a fan child AND a light child in Navigator, so
  bindings are per FUNCTION, not per device — that is the one structural
  difference from the UniFi Protect gateway this driver is patterned on.

  ── SCOPE ─────────────────────────────────────────────────────────────────────

  Connect, inventory, per-function bindings, actions on behalf of children,
  BPUP push state with hash-polling as the safety net, auto-provisioning.
  NOT here yet: Bond groups (C4 has scenes), skeds (C4 has the scheduler),
  Breeze/Timer programming surface, TDBU/dual-layer shade rails. See
  docs/bond-driver-research.md for the whole programme.

  ── THE TOKEN NEVER LIVES IN THE PROJECT FILE ─────────────────────────────────

  Same letterbox pattern as the Protect gateway's API key: the Local Token
  property is paste-only — stored encrypted via persist, then wiped. What
  survives in a handed-around project file is nothing.
============================================================================]]

--#ifdef DRIVERCENTRAL
DC_PID = 0
DC_X = nil
DC_FILENAME = "bond-bridge.c4z"
--#else
DRIVER_GITHUB_REPO = "michelo76/control4-smartbuildos"
DRIVER_FILENAMES = {
  "bond-bridge.c4z",
}
--#endif

require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")
-- REQUIRED, even though nothing here names it: `lib.http` calls the GLOBAL
-- `urlDo`, which this module defines. Without it every request throws inside
-- the handler's xpcall and the driver sits silent. test_bond_bridge_globals
-- exists to fail if this line is ever dropped.
require("drivers-common-public.global.url")

JSON = require("JSON")

local log = require("lib.logging")
local persist = require("lib.persist")
local bindings = require("lib.bindings")
local Bond = require("bond.api")
local model = require("bond.model")
local Bpup = require("bond.bpup")
local Mdns = require("bond.mdns")
--- The SmartBuildOS licensing SDK: this driver registers as SBOS_BOND with
--- the SmartBuildOS Agent and carries the standardized License Status
--- property. LEGACY = operate normally until the entitlement backend lists
--- the SKU; child drivers inherit through this gateway.
local license = require("sbos.license")

--- The one client this driver drives.
local bond = Bond:new()

-- ─── Constants ────────────────────────────────────────────────────────────────

--- Persist keys. The token is stored ENCRYPTED — it is full control of the
--- customer's appliances.
local TOKEN_PERSIST = "bond_token"
--- The Bond's PIN (printed on the unit), held only until a PIN-unlock token
--- fetch succeeds, then deleted.
local PIN_PERSIST = "bond_pin"
local INVENTORY_PERSIST = "bond_inventory"

--- Binding namespace per function in lib.bindings' persisted table.
local FUNCTION_NS = {
  FAN = "bond_fan",
  LIGHT = "bond_light",
  SHADE = "bond_shade",
  FIREPLACE = "bond_fireplace",
  HEATER = "bond_heater",
  GENERIC = "bond_generic",
  KEYPAD = "bond_keypad",
  WEATHER = "bond_weather",
  COLOR_LIGHT = "bond_color_light",
}

--- Child driver file per function, for Auto Configure.
local PROVISION_FILES = {
  FAN = "bond-fan.c4z",
  LIGHT = "bond-light.c4z",
  SHADE = "bond-shade.c4z",
  FIREPLACE = "bond-fireplace.c4z",
  HEATER = "bond-heater.c4z",
  GENERIC = "bond-generic.c4z",
  KEYPAD = "bond-keypad.c4z",
  WEATHER = "bond-weather.c4z",
  COLOR_LIGHT = "bond-color-light.c4z",
}

--- Function order for walks that should be deterministic.
local FUNCTION_ORDER = { "FAN", "LIGHT", "COLOR_LIGHT", "SHADE", "FIREPLACE", "HEATER", "GENERIC", "KEYPAD", "WEATHER" }

local POLL_TIMER = "BondPoll"
local KEEPALIVE_TIMER = "BondBpupKeepalive"
local PROVISION_RENAME_TIMER = "BondProvisionRename"
local DISCOVERY_QUERY_TIMER = "BondDiscoveryQuery"
local DISCOVERY_STOP_TIMER = "BondDiscoveryStop"

--- How long a discovery session listens. mDNS answers arrive within a
--- second or two; the window covers a lossy Wi-Fi re-ask.
local DISCOVERY_WINDOW_SECONDS = 6

--- The Bond Address property's install default, treated as "unset" by the
--- discovery auto-fill.
local DEFAULT_ADDRESS = "192.168.1.50"

--- BPUP keep-alives are due every 60s; 50 keeps one lost datagram from
--- crossing the Bond's 125s client timeout.
local KEEPALIVE_SECONDS = 50

--- Poll interval labels mapped to seconds.
--- @type table<string, number>
local INTERVALS = {
  ["30s"] = 30,
  ["1m"] = 60,
  ["2m"] = 2 * 60,
  ["5m"] = 5 * 60,
  ["15m"] = 15 * 60,
}

--- Events registered again at init — XML events only register when an
--- instance is first added. Ids are frozen.
local GATEWAY_EVENTS = {
  { 1, "Bond Online", "The Bond started answering again." },
  { 2, "Bond Offline", "The Bond stopped answering." },
}

-- ─── State ────────────────────────────────────────────────────────────────────

gInitialized = false

--- Whether the last exchange with the Bond succeeded. Drives the
--- BOND_CONNECTED conditional and Connection Status; transitions are logged
--- and fired ONCE.
gConnected = false

--- The last inventory applied:
--- { devices = { {id, name, type, subtype, location, actions, props, state,
---   functions}, ... }, bondid, updated_at }.
gInventory = nil

--- Root hash of /v2/devices from the last sync — the poll's "did anything
--- change" comparator.
gDevicesHash = nil

--- Per-(device, fn) state hash last pushed to a child, so BPUP echoes and
--- poll re-reads do not re-fire children for a state they already hold.
gPushedStateHash = {}

--- The BPUP transport, created at init (needs handlers loaded first).
gBpup = nil

--- The mDNS resolver, created on first discovery.
gDiscovery = nil

--- Bonds heard during discovery: bondid -> { ip, port, fw, setup }.
gDiscovered = {}

--- Root hash of /v2/sidekicks from the last sync. Weather measurements and
--- keypad batteries live under this tree, not /v2/devices — the poll checks
--- both comparators.
gSidekicksHash = nil

--- Forward declarations, defined below in dependency order.
local pushDeviceStates, syncDevices, testConnection, startPush, stopPush
local autoRenameBoundDrivers

-- ─── Helpers ──────────────────────────────────────────────────────────────────

local function token()
  local value = persist:get(TOKEN_PERSIST, "", true)
  if type(value) ~= "string" then
    return ""
  end
  return value
end

local function isConfigured()
  return bond:isConfigured()
end

local function configureClient()
  bond:configure(Properties["Bond Address"], token())
end

--- The Bond's bare host (for BPUP), out of the normalized base URL.
local function bondHost()
  return tostring(bond.baseUrl or ""):gsub("^https?://", ""):gsub(":%d+$", "")
end

--- Single writer for connection state: property, conditional, events, log —
--- transitions only.
--- @param connected boolean
--- @param reason string|nil Status line detail (used when disconnected, or as override).
local function setConnected(connected, reason)
  local line
  if connected then
    line = reason or "Connected"
  else
    line = reason or "Disconnected"
  end
  UpdateProperty("Connection Status", line)
  if connected ~= gConnected then
    gConnected = connected
    if connected then
      log:info("Bond connected")
      pcall(function()
        C4:FireEvent("Bond Online")
      end)
    else
      log:warn("Bond disconnected: %s", line)
      pcall(function()
        C4:FireEvent("Bond Offline")
      end)
    end
    pcall(function()
      C4:SetConditionalState("BOND_CONNECTED", connected)
    end)
  end
end

--- One dealer-readable line out of a lib.http rejection. A rejection WITH a
--- code is the Bond speaking (401 = token, 404 = stale id); without one the
--- Bond is unreachable — different failures, different places to send the
--- dealer.
--- @param err table|nil The rejection.
--- @return string line
local function describeFailure(err)
  err = err or {}
  local code = tonumber(err.code)
  if code == 401 then
    return "Token rejected - re-paste the Local Token (Bond Home app: Settings > Advanced > Local Token)"
  end
  if code ~= nil then
    return string.format("Bond answered HTTP %d", code)
  end
  return "Bond unreachable - check the Bond Address and that it is on this network"
end

--- One inventory entry from the three per-device documents.
local function summarizeDevice(id, info, props, state)
  info = info or {}
  return {
    id = id,
    name = tostring(info.name or id),
    type = tostring(info.type or ""),
    subtype = info.subtype and tostring(info.subtype) or nil,
    location = tostring(info.location or ""),
    actions = type(info.actions) == "table" and info.actions or {},
    props = type(props) == "table" and props or {},
    state = type(state) == "table" and state or {},
    functions = model.deriveFunctions(info.type, info.actions),
  }
end

--- The inventory entry for a device id, or nil.
local function deviceById(deviceId)
  for _, device in ipairs((gInventory or {}).devices or {}) do
    if device.id == deviceId then
      return device
    end
  end
  return nil
end

-- ─── Bindings ─────────────────────────────────────────────────────────────────

--- Ensures one provider CONTROL binding per (device, function). Never
--- deletes — pruning is an explicit action, same policy as every driver in
--- this suite.
local function ensureFunctionBindings(devices)
  for _, device in ipairs(devices) do
    for i, fn in ipairs(device.functions) do
      bindings:getOrAddDynamicBinding(
        FUNCTION_NS[fn],
        device.id,
        "CONTROL",
        true,
        model.childLabel(device.name, fn, i == 1),
        model.BINDING_CLASSES[fn]
      )
    end
  end
end

--- Bindings whose device (or device function) is gone from the current
--- inventory. Keyed "<fn>:<device id>".
--- @return table<string, Binding> stale
local function staleFunctionBindings()
  local present = {}
  for _, device in ipairs((gInventory or {}).devices or {}) do
    for _, fn in ipairs(device.functions) do
      present[fn .. ":" .. device.id] = true
    end
  end
  local stale = {}
  for _, fn in ipairs(FUNCTION_ORDER) do
    for key, binding in pairs(bindings:getDynamicBindings(FUNCTION_NS[fn])) do
      if not present[fn .. ":" .. key] then
        stale[fn .. ":" .. key] = binding
      end
    end
  end
  return stale
end

--- The (device, fn) behind a provider binding id, walked from the persisted
--- bindings table. Nil when the binding maps to nothing.
local function deviceForBinding(idBinding)
  for _, fn in ipairs(FUNCTION_ORDER) do
    for key, binding in pairs(bindings:getDynamicBindings(FUNCTION_NS[fn])) do
      if binding.bindingId == idBinding then
        return deviceById(key), fn, binding
      end
    end
  end
  return nil, nil, nil
end

--- The child driver DEVICE bound to a binding, or nil.
--- @param bindingId number
--- @return number|nil childDeviceId
local function boundConsumerForBinding(bindingId)
  local ok, consumers = pcall(function()
    return C4:GetBoundConsumerDevices(C4:GetDeviceID(), bindingId)
  end)
  if not ok or type(consumers) ~= "table" then
    return nil
  end
  for deviceId in pairs(consumers) do
    return tonumber(deviceId)
  end
  return nil
end

--- The (device, fn, binding) a child DEVICE is bound to — the
--- SendToDevice-path twin of deviceForBinding.
local function deviceForChildDevice(childDeviceId)
  for _, fn in ipairs(FUNCTION_ORDER) do
    for key, binding in pairs(bindings:getDynamicBindings(FUNCTION_NS[fn])) do
      if boundConsumerForBinding(binding.bindingId) == childDeviceId then
        return deviceById(key), fn, binding, key
      end
    end
  end
  return nil, nil, nil, nil
end

--- Sends to the child behind a binding, preferring the DEVICE path
--- (SendToDevice → ExecuteCommand is the field-measured transport; proxy
--- delivery over a bound CONTROL binding is the documented-but-unproven
--- one). One preferred path, never both, so nothing fires twice.
local function sendToChild(binding, command, params)
  local child = boundConsumerForBinding(binding.bindingId)
  if child ~= nil then
    SendToDevice(child, command, params)
  else
    SendToProxy(binding.bindingId, command, params)
  end
end

-- ─── Child protocol ───────────────────────────────────────────────────────────
--
-- Nested documents (actions/props/state) ride the child protocol as JSON
-- STRINGS: SendToDevice serializes booleans as strings and its table
-- handling is undocumented, so the safe contract is scalars + JSON text.

--- The identity payload for one (device, fn).
local function deviceReplyParams(device, fn, binding)
  local isPrimary = device.functions[1] == fn
  return {
    id = device.id,
    fn = fn,
    name = binding and binding.displayName or model.childLabel(device.name, fn, isPrimary),
    type = device.type,
    subtype = device.subtype,
    location = device.location,
    actions_json = JSON:encode(device.actions or {}),
    props_json = JSON:encode(device.props or {}),
    state_json = JSON:encode(device.state or {}),
  }
end

--- Pushes one device's state to every bound child of every function, unless
--- that exact state (by Bond's own subtree hash) was already pushed there.
--- @param device table The inventory entry.
--- @param force boolean|nil Push even when the hash matches (identity answers).
local function pushDeviceState(device, force)
  local stateJson = JSON:encode(device.state or {})
  local hash = (device.state or {})["_"]
  for _, fn in ipairs(device.functions) do
    local binding = bindings:getDynamicBinding(FUNCTION_NS[fn], device.id)
    if binding ~= nil then
      local key = fn .. ":" .. device.id
      if force or hash == nil or gPushedStateHash[key] ~= hash then
        gPushedStateHash[key] = hash
        sendToChild(binding, "BOND_STATE", {
          id = device.id,
          fn = fn,
          name = binding.displayName,
          state_json = stateJson,
        })
      end
    end
  end
end

--- (Assigns the forward declaration.) Pushes every device's state.
pushDeviceStates = function(devices, force)
  for _, device in ipairs(devices or {}) do
    pushDeviceState(device, force)
  end
end

function RFP.BOND_GET_DEVICE(idBinding)
  local device, fn, binding = deviceForBinding(idBinding)
  if device == nil then
    log:warn("BOND_GET_DEVICE on binding %s, which maps to no Bond device", tostring(idBinding))
    return
  end
  -- INFO, not trace: this is the handshake a dealer is watching for when a
  -- child says "waiting for a reply".
  log:info("Device identity requested on binding %s; answering '%s' (%s/%s)", idBinding, device.name, device.id, fn)
  SendToProxy(idBinding, "BOND_DEVICE", deviceReplyParams(device, fn, binding))
end

--- The SendToDevice twin: a child asking over the device path, carrying its
--- own device id as `requester`. The answer goes back the way it came.
function EC.BOND_GET_DEVICE(tParams)
  local requester = tonumber((tParams or {}).requester)
  if requester == nil then
    return
  end
  local device, fn, binding = deviceForChildDevice(requester)
  if device == nil then
    log:warn(
      "Device %s asked for its Bond identity but is not bound to any Bond connection - bind it in Connections",
      requester
    )
    return
  end
  log:info("Device identity requested by device %s; answering '%s' (%s/%s)", requester, device.name, device.id, fn)
  SendToDevice(requester, "BOND_DEVICE", deviceReplyParams(device, fn, binding))
end

--- Runs one Bond action and refreshes state on success. The shared engine
--- behind the child protocol and the Composer command.
--- @param device table The inventory entry.
--- @param action string The action name.
--- @param argument any|nil Decoded argument.
--- @param onDone fun(ok: boolean, detail: string|nil)|nil
local function runAction(device, action, argument, onDone)
  if not isConfigured() then
    if onDone then
      onDone(false, "not configured")
    end
    return
  end
  if not model.actionSet(device.actions)[action] then
    log:warn("Action '%s' is not in '%s' action list; sending anyway (list may be stale)", action, device.name)
  end
  bond:action(device.id, action, argument):next(function()
    setConnected(true)
    -- The 200 means "RF transmitted"; the resulting state is re-read
    -- rather than assumed, and the BPUP echo (if any) dedupes by hash.
    bond:getDeviceState(device.id):next(function(response)
      local state = Bond.decodeBody(response.body)
      if type(state) == "table" then
        device.state = state
        pushDeviceState(device)
      end
    end, function() end)
    if onDone then
      onDone(true)
    end
  end, function(err)
    local detail = describeFailure(err)
    log:warn("Bond action %s on '%s' failed: %s", action, device.name, detail)
    if tonumber((err or {}).code) == nil then
      setConnected(false, detail)
    end
    if onDone then
      onDone(false, detail)
    end
  end)
end

--- Decodes a child/Composer argument string: absent → nil, number → number,
--- JSON → table, anything else → the string itself.
local function decodeArgument(raw)
  if raw == nil then
    return nil
  end
  local s = tostring(raw)
  if s == "" then
    return nil
  end
  local n = tonumber(s)
  if n ~= nil then
    return n
  end
  local decoded = Bond.decodeBody(s)
  if decoded ~= nil then
    return decoded
  end
  return s
end

--- A child asking for an action: { requester, action, argument? }. The
--- device is resolved from the requester's binding — a child can never
--- action a device it is not bound to.
function EC.BOND_ACTION(tParams)
  tParams = tParams or {}
  local requester = tonumber(tParams.requester)
  local action = tostring(tParams.action or "")
  if requester == nil or action == "" then
    return
  end
  local device = deviceForChildDevice(requester)
  if device == nil then
    log:warn("Device %s requested action '%s' but is not bound to any Bond connection", requester, action)
    return
  end
  runAction(device, action, decodeArgument(tParams.argument), function(ok, detail)
    SendToDevice(requester, "BOND_ACTION_RESULT", {
      id = device.id,
      action = action,
      ok = ok and "true" or "false",
      detail = detail or "",
    })
  end)
end

--- The Composer command: device by id or name, argument as number or JSON.
function EC.RUN_BOND_ACTION(tParams)
  tParams = tParams or {}
  local wanted = tostring(tParams.Device or "")
  local action = tostring(tParams.Action or "")
  if wanted == "" or action == "" then
    log:print("Run Bond Action: Device and Action are required")
    return
  end
  local device = deviceById(wanted)
  if device == nil then
    for _, candidate in ipairs((gInventory or {}).devices or {}) do
      if candidate.name:lower() == wanted:lower() then
        device = candidate
        break
      end
    end
  end
  if device == nil then
    log:print("Run Bond Action: no device '%s' in the inventory", wanted)
    return
  end
  runAction(device, action, decodeArgument(tParams.Argument), function(ok, detail)
    log:print("Run Bond Action: %s %s -> %s", device.name, action, ok and "ok" or ("FAILED: " .. tostring(detail)))
  end)
end
EC.Run_Bond_Action = EC.RUN_BOND_ACTION

--- Runs one of the Bond's own scenes (the app's scenes) by name or id —
--- Composer programming can fire what the homeowner already built.
function EC.RUN_BOND_SCENE(tParams)
  local wanted = tostring((tParams or {}).Scene or "")
  if wanted == "" then
    log:print("Run Bond Scene: Scene is required")
    return
  end
  local scene
  for _, candidate in ipairs((gInventory or {}).scenes or {}) do
    if candidate.id == wanted or candidate.name:lower() == wanted:lower() then
      scene = candidate
      break
    end
  end
  if scene == nil then
    log:print("Run Bond Scene: no scene '%s' - run Sync Devices Now and check Print Scenes To Log", wanted)
    return
  end
  bond:runScene(scene.id):next(function()
    setConnected(true)
    log:print("Run Bond Scene: '%s' ran", scene.name)
  end, function(err)
    log:print("Run Bond Scene: '%s' FAILED: %s", scene.name, describeFailure(err))
  end)
end
EC.Run_Bond_Scene = EC.RUN_BOND_SCENE

function EC.PRINT_SCENES()
  log:trace("EC.PRINT_SCENES()")
  local scenes = (gInventory or {}).scenes or {}
  if #scenes == 0 then
    log:print("No Bond scenes in the inventory - run Sync Devices Now (scenes are built in the Bond Home app)")
    return
  end
  log:print("Bond scenes:")
  for _, scene in ipairs(scenes) do
    log:print("  %s '%s'", scene.id, scene.name)
  end
end

-- ─── Sync ─────────────────────────────────────────────────────────────────────

--- Applies a completed inventory: counts, bindings, pushes, cache.
local function applyInventory(inventory)
  inventory.updated_at = os.date("%Y-%m-%d %H:%M:%S")
  gInventory = inventory

  UpdateProperty("Devices", tostring(#inventory.devices))
  UpdateProperty("Scenes", tostring(#(inventory.scenes or {})))
  UpdateProperty("Last Sync", inventory.updated_at)

  ensureFunctionBindings(inventory.devices)
  pushDeviceStates(inventory.devices)

  local staleCount = 0
  for key, binding in pairs(staleFunctionBindings()) do
    staleCount = staleCount + 1
    log:warn(
      "Binding '%s' (%s, id %s) has no Bond device behind it; run 'Prune Missing Device Bindings' to remove it",
      binding.displayName,
      key,
      binding.bindingId
    )
  end

  persist:set(INVENTORY_PERSIST, inventory)
  return staleCount
end

--- Pulls the whole inventory: the device tree, then per device the identity,
--- properties and state documents. SEQUENTIAL on purpose — a Bond Bridge is
--- a small embedded box, and at a once-a-minute cadence a burst buys
--- nothing; sequencing also means one failure aborts with one status line.
--- (Assigns the forward declaration.)
--- @param onDone fun(ok: boolean)|nil
syncDevices = function(onDone)
  if not isConfigured() then
    setConnected(false, "Not configured - set the Bond Address and Local Token")
    if onDone then
      onDone(false)
    end
    return
  end

  bond:getDevices():next(function(response)
    local tree = Bond.decodeBody(response.body)
    if type(tree) ~= "table" then
      setConnected(false, "Device list unreadable")
      if onDone then
        onDone(false)
      end
      return
    end
    local rootHash = tree["_"]
    local ids = Bond.idsFromTree(tree)
    local devices = {}

    local function finish(scenes)
      gDevicesHash = rootHash
      applyInventory({
        devices = devices,
        scenes = scenes or (gInventory or {}).scenes,
        bondid = (gInventory or {}).bondid,
      })
      setConnected(true)
      log:info("Sync complete: %d device(s), %d scene(s)", #devices, #((gInventory or {}).scenes or {}))
      if onDone then
        onDone(true)
      end
    end

    --- Sidekick keypads ride the sync as PSEUDO-DEVICES with the KEYPAD
    --- function — one entry per /v2/sidekicks item that has a `keys` count
    --- (weather sensors on the same endpoint have none and are skipped).
    --- Folding them into `devices` means bindings, identity answers,
    --- provisioning and renames all reuse the device machinery unchanged.
    --- Optional by design: firmware without Sidekick support 404s and the
    --- sync carries on.
    local function fetchSidekicks(scenes)
      bond:getSidekicks():next(function(sidekicksResponse)
        local sidekicksTree = Bond.decodeBody(sidekicksResponse.body)
        gSidekicksHash = (sidekicksTree or {})["_"]
        local sidekickIds = Bond.idsFromTree(sidekicksTree)
        local function fetchSidekick(j)
          if j > #sidekickIds then
            finish(scenes)
            return
          end
          local id = sidekickIds[j]
          bond:getSidekick(id):next(function(sidekickResponse)
            local doc = Bond.decodeBody(sidekickResponse.body) or {}
            if tonumber(doc.keys) ~= nil then
              table.insert(devices, {
                id = id,
                name = tostring(doc.name or id),
                type = "SK",
                location = tostring(doc.location or ""),
                actions = {},
                props = { keys = tonumber(doc.keys), model = doc.model },
                state = { battery = tonumber(doc.battery), signal = tonumber(doc.signal) },
                functions = { model.FUNCTIONS.KEYPAD },
              })
              fetchSidekick(j + 1)
            elseif tostring(doc.type or "") == "weather_sensor" then
              -- Breeze weather station: the measurements live on its own
              -- state endpoint. A failed state read still lists the sensor
              -- (a Breeze with a dead battery is exactly when the child's
              -- No Data surfaces matter).
              bond:getSidekickState(id):next(function(stateResponse)
                table.insert(devices, {
                  id = id,
                  name = tostring(doc.name or id),
                  type = "WS",
                  location = tostring(doc.location or ""),
                  actions = {},
                  props = { model = doc.model },
                  state = Bond.decodeBody(stateResponse.body) or {},
                  functions = { model.FUNCTIONS.WEATHER },
                })
                fetchSidekick(j + 1)
              end, function()
                table.insert(devices, {
                  id = id,
                  name = tostring(doc.name or id),
                  type = "WS",
                  location = tostring(doc.location or ""),
                  actions = {},
                  props = { model = doc.model },
                  state = {},
                  functions = { model.FUNCTIONS.WEATHER },
                })
                fetchSidekick(j + 1)
              end)
            else
              fetchSidekick(j + 1)
            end
          end, function()
            fetchSidekick(j + 1)
          end)
        end
        fetchSidekick(1)
      end, function()
        finish(scenes)
      end)
    end

    --- Scenes ride the same sync (the app's scenes, runnable on the Bond).
    --- Optional by design: a Bond without scene support still applies its
    --- devices — a scenes failure must never abort a device sync.
    local function fetchScenes()
      bond:getScenes():next(function(scenesResponse)
        local sceneIds = Bond.idsFromTree(Bond.decodeBody(scenesResponse.body))
        local scenes = {}
        local function fetchScene(j)
          if j > #sceneIds then
            fetchSidekicks(scenes)
            return
          end
          local id = sceneIds[j]
          bond:getScene(id):next(function(sceneResponse)
            local doc = Bond.decodeBody(sceneResponse.body) or {}
            table.insert(scenes, { id = id, name = tostring(doc.name or id) })
            fetchScene(j + 1)
          end, function()
            table.insert(scenes, { id = id, name = id })
            fetchScene(j + 1)
          end)
        end
        fetchScene(1)
      end, function()
        fetchSidekicks(nil)
      end)
    end

    local function fetchNext(i)
      if i > #ids then
        fetchScenes()
        return
      end
      local id = ids[i]
      bond:getDevice(id):next(function(infoResponse)
        local info = Bond.decodeBody(infoResponse.body)
        bond:getDeviceProperties(id):next(function(propsResponse)
          local props = Bond.decodeBody(propsResponse.body)
          bond:getDeviceState(id):next(function(stateResponse)
            local state = Bond.decodeBody(stateResponse.body)
            table.insert(devices, summarizeDevice(id, info, props, state))
            fetchNext(i + 1)
          end, function(err)
            log:warn("State fetch for %s failed: %s", id, describeFailure(err))
            table.insert(devices, summarizeDevice(id, info, props, nil))
            fetchNext(i + 1)
          end)
        end, function(err)
          log:warn("Properties fetch for %s failed: %s", id, describeFailure(err))
          table.insert(devices, summarizeDevice(id, info, nil, nil))
          fetchNext(i + 1)
        end)
      end, function(err)
        -- Identity is not optional: without it there is no name, no
        -- actions and no function list. Skip the device, keep the sync.
        log:warn("Device fetch for %s failed: %s", id, describeFailure(err))
        fetchNext(i + 1)
      end)
    end

    fetchNext(1)
  end, function(err)
    local detail = describeFailure(err)
    setConnected(false, detail)
    if onDone then
      onDone(false)
    end
  end)
end

--- Version probe + auth check, writing the identity properties.
--- (Assigns the forward declaration.)
testConnection = function()
  if not bond:hasAddress() then
    setConnected(false, "Not configured - set the Bond Address and Local Token")
    return
  end
  bond:getVersion():next(function(response)
    local info = Bond.decodeBody(response.body) or {}
    if info.bondid ~= nil then
      UpdateProperty("Bond ID", tostring(info.bondid))
      if gInventory ~= nil then
        gInventory.bondid = tostring(info.bondid)
      end
    end
    local modelName = tostring(info.model or info.target or "-")
    if info.make ~= nil then
      modelName = tostring(info.make) .. " " .. modelName
    end
    UpdateProperty("Model", modelName)
    UpdateProperty("Firmware", tostring(info.fw_ver or "-"))
    if token() == "" then
      setConnected(false, "Bond found - paste the Local Token to connect")
    else
      -- The version endpoint is tokenless; only an authenticated call
      -- proves the token. The device list doubles as that check.
      syncDevices()
    end
  end, function(err)
    setConnected(false, describeFailure(err))
  end)
end

-- ─── Polling ──────────────────────────────────────────────────────────────────

--- One poll tick: the root hash answers "did anything change" in a single
--- request; only a moved hash pays for a full sync.
local function pollTick()
  if not isConfigured() then
    return
  end
  bond:getDevices():next(function(response)
    local tree = Bond.decodeBody(response.body)
    if type(tree) ~= "table" then
      return
    end
    setConnected(true)
    if tree["_"] ~= nil and tree["_"] == gDevicesHash then
      -- Devices unmoved: weather measurements and keypad batteries live
      -- under the SIDEKICKS tree, so check its hash too (skipped entirely
      -- when the last sync saw no sidekicks tree at all).
      if gSidekicksHash ~= nil then
        bond:getSidekicks():next(function(sidekicksResponse)
          local sidekicksTree = Bond.decodeBody(sidekicksResponse.body)
          local hash = (sidekicksTree or {})["_"]
          if hash ~= nil and hash ~= gSidekicksHash then
            log:debug("Sidekicks tree hash moved (%s -> %s); syncing", tostring(gSidekicksHash), tostring(hash))
            syncDevices()
          end
        end, function() end)
      end
      return
    end
    log:debug("Device tree hash moved (%s -> %s); syncing", tostring(gDevicesHash), tostring(tree["_"]))
    syncDevices()
  end, function(err)
    local detail = describeFailure(err)
    if tonumber((err or {}).code) == nil then
      setConnected(false, detail)
    end
  end)
end

local function schedulePoll()
  CancelTimer(POLL_TIMER)
  local seconds = INTERVALS[tostring(Properties["Device Poll Interval"] or "")]
  if seconds == nil or not isConfigured() then
    return
  end
  SetTimer(POLL_TIMER, seconds * ONE_SECOND, pollTick, true)
end

-- ─── BPUP (push updates) ──────────────────────────────────────────────────────

--- A pushed state document for one device. Unknown ids mean the inventory
--- is stale (a device added from the app); the next poll's hash mismatch
--- picks it up.
local function applyPushedState(deviceId, state)
  if type(state) ~= "table" then
    return
  end
  local device = deviceById(deviceId)
  if device == nil then
    log:debug("BPUP update for unknown device %s; waiting for the next sync", tostring(deviceId))
    return
  end
  device.state = state
  pushDeviceState(device)
end

local function handleBpupFrame(line)
  local frame = Bond.parseBpup(line)
  if frame == nil then
    return
  end
  if frame.error ~= nil then
    log:debug("BPUP error frame: %s %s", tostring(frame.error.id), tostring(frame.error.msg))
    return
  end
  UpdateProperty("Push Status", "Delivering")
  if frame.deviceId ~= nil then
    applyPushedState(frame.deviceId, frame.state)
    return
  end
  -- Weather sensor (and future sidekick) state pushes: same pipeline as
  -- device state — the sensor is a pseudo-device in the inventory.
  local wsId = tostring(frame.topic or ""):match("^sidekicks/([^/]+)/state$")
  if wsId ~= nil and type(frame.body) == "table" then
    applyPushedState(wsId, frame.body)
    return
  end
  -- Sidekick key events: push-only by contract (the HTTP endpoint answers
  -- 204). Routed to the keypad child bound for that Sidekick; presses on a
  -- keypad with no bound child are simply nobody's business yet.
  local sidekickId = tostring(frame.topic or ""):match("^sidekicks/([^/]+)/keystream$")
  if sidekickId ~= nil and type(frame.body) == "table" then
    local binding = bindings:getDynamicBinding(FUNCTION_NS.KEYPAD, sidekickId)
    if binding ~= nil then
      sendToChild(binding, "BOND_KEYSTREAM", {
        id = sidekickId,
        event = tostring(frame.body.event or ""),
        key = tostring(frame.body.key or ""),
        hold_ms = tostring(frame.body.hold_ms or ""),
        seq = tostring(frame.body.seq or ""),
      })
    end
  end
end

--- (Assigns the forward declaration.)
startPush = function()
  if tostring(Properties["Push Updates"] or "On") ~= "On" or not isConfigured() then
    return
  end
  if gBpup == nil then
    gBpup = Bpup.new({ onFrame = handleBpupFrame })
  end
  if gBpup:start(bondHost()) then
    UpdateProperty("Push Status", "Waiting")
    gBpup:keepalive()
    CancelTimer(KEEPALIVE_TIMER)
    SetTimer(KEEPALIVE_TIMER, KEEPALIVE_SECONDS * ONE_SECOND, function()
      gBpup:keepalive()
      if not gBpup:isAlive() then
        UpdateProperty("Push Status", "Waiting - no push traffic; polling covers")
      end
    end, true)
  else
    UpdateProperty("Push Status", "Unavailable - polling covers")
  end
end

--- (Assigns the forward declaration.)
stopPush = function()
  CancelTimer(KEEPALIVE_TIMER)
  if gBpup ~= nil then
    gBpup:stop()
  end
  UpdateProperty("Push Status", "Off")
end

-- ─── mDNS discovery ───────────────────────────────────────────────────────────
--
-- Every Bond announces `_bond._tcp.local`; a one-shot resolver (QU-bit
-- unicast replies, src/bond/mdns.lua) finds them so nobody types an IP.
-- Runs once at startup and on demand; results land in the Discovered Bonds
-- property, and an UNCONFIGURED gateway auto-fills its address with the
-- first Bond heard — a configured or connected gateway is never re-pointed.

--- One line per Bond heard, for the property.
local function describeDiscovered()
  local ids = {}
  for bondid in pairs(gDiscovered) do
    table.insert(ids, bondid)
  end
  table.sort(ids)
  local lines = {}
  for _, bondid in ipairs(ids) do
    local device = gDiscovered[bondid]
    table.insert(
      lines,
      string.format("%s @ %s%s", bondid, tostring(device.ip or "?"), device.setup and " (setup mode)" or "")
    )
  end
  return table.concat(lines, "; ")
end

local function handleDiscoveredDevice(device)
  if device.ip == nil then
    return
  end
  local known = gDiscovered[device.bondid]
  if known ~= nil and known.ip == device.ip then
    return
  end
  gDiscovered[device.bondid] = {
    ip = device.ip,
    port = device.port,
    fw = (device.txt or {}).v,
    setup = (device.txt or {}).d == "1",
  }
  UpdateProperty("Discovered Bonds", describeDiscovered())
  log:print(
    "Discovered Bond %s at %s%s",
    device.bondid,
    device.ip,
    (device.txt or {}).v and (" (fw " .. device.txt.v .. ")") or ""
  )

  -- Auto-fill: only while the address is still the install default (or
  -- empty) and nothing is connected. First Bond heard wins; a second one
  -- shows up in the property for the dealer to pick deliberately.
  local address = tostring(Properties["Bond Address"] or "")
  if not gConnected and (address == "" or address == DEFAULT_ADDRESS) then
    log:print("Bond Address auto-filled with %s (%s)", device.ip, device.bondid)
    UpdateProperty("Bond Address", device.ip)
    configureClient()
    testConnection()
    schedulePoll()
    startPush()
  end
end

local function stopDiscovery()
  CancelTimer(DISCOVERY_QUERY_TIMER)
  CancelTimer(DISCOVERY_STOP_TIMER)
  if gDiscovery ~= nil then
    gDiscovery:stop()
  end
end

local function startDiscovery()
  stopDiscovery()
  if gDiscovery == nil then
    gDiscovery = Mdns.new({ onDevice = handleDiscoveredDevice })
  end
  if not gDiscovery:start() then
    UpdateProperty("Discovered Bonds", "unavailable - no free network binding")
    return
  end
  gDiscovery:query()
  -- mDNS is lossy multicast: re-ask through the window, then close the
  -- socket — this is a one-shot resolver, not a standing responder.
  SetTimer(DISCOVERY_QUERY_TIMER, 2 * ONE_SECOND, function()
    gDiscovery:query()
  end, true)
  SetTimer(DISCOVERY_STOP_TIMER, DISCOVERY_WINDOW_SECONDS * ONE_SECOND, function()
    stopDiscovery()
    if next(gDiscovered) == nil then
      UpdateProperty("Discovered Bonds", "none heard - check that the controller and Bond share a network")
    end
  end)
end

-- ─── Lifecycle ────────────────────────────────────────────────────────────────

local function registerGatewayEvents()
  for _, e in ipairs(GATEWAY_EVENTS) do
    pcall(function()
      C4:AddEvent(e[1], e[2], e[3])
    end)
  end
end

function OnDriverInit()
  --#ifdef DRIVERCENTRAL
  require("cloud-client-byte")
  C4:AllowExecute(false)
  --#else
  C4:AllowExecute(true)
  --#endif
  gInitialized = false
  log:setLogName(C4:GetDeviceData(C4:GetDeviceID(), "name"))
  log:setLogLevel(Properties["Log Level"])
  log:setLogMode(Properties["Log Mode"])
  log:trace("OnDriverInit()")
  -- From OnDriverInit, NOT OnDriverLateInit: Director resolves stored
  -- connections before late init, and consumer-side connections onto a
  -- binding that does not exist yet are permanently dropped. The children
  -- are exactly such consumers.
  bindings:restoreBindings()
end

function OnDriverLateInit()
  log:trace("OnDriverLateInit()")
  if not CheckMinimumVersion("Driver Status") then
    return
  end

  -- Guarded by SHAPE, not nil: persist:get with no default returns its EMPTY
  -- sentinel table for a missing key.
  local cached = persist:get(INVENTORY_PERSIST)
  if type(cached) == "table" and cached.devices ~= nil then
    gInventory = cached
  end

  for p, _ in pairs(Properties) do
    local status, err = pcall(OnPropertyChanged, p)
    if not status and err then
      log:error("Error in OnPropertyChanged for property '%s': %s", p, err or "unknown error")
    end
  end

  registerGatewayEvents()

  license.setup({ sku = "SBOS_BOND" })

  gInitialized = true
  UpdateProperty("Driver Status", "Online")
  -- The build actually running, said by the code itself — stale cached
  -- driver copies have twice been mistaken for broken code in this suite.
  pcall(function()
    UpdateProperty("Driver Version", tostring(C4:GetDriverConfigInfo("version")))
  end)

  configureClient()

  if gInventory ~= nil then
    UpdateProperty("Devices", tostring(#(gInventory.devices or {})))
    UpdateProperty("Last Sync", tostring(gInventory.updated_at or "unknown") .. " (cached)")
  end

  if bond:hasAddress() then
    testConnection()
    schedulePoll()
    startPush()
  else
    setConnected(false, "Not configured - set the Bond Address and Local Token")
  end

  -- One discovery pass at every start: fills the Discovered Bonds property,
  -- and auto-fills the address on a factory-fresh instance. Cheap (a 6s
  -- listening window), and a configured gateway is never re-pointed by it.
  startDiscovery()
end

function OnDriverDestroyed()
  CancelTimer(POLL_TIMER)
  CancelTimer(PROVISION_RENAME_TIMER)
  stopPush()
  stopDiscovery()
end

-- ─── Conditionals ─────────────────────────────────────────────────────────────

function TC.BOND_CONNECTED()
  return gConnected
end

-- ─── Property handlers ────────────────────────────────────────────────────────

function OPC.Local_Token(propertyValue)
  log:trace("OPC.Local_Token(<redacted>)")
  local value = tostring(propertyValue or ""):gsub("%s+", "")
  if value == "" then
    return
  end
  persist:set(TOKEN_PERSIST, value, true)
  UpdateProperty("Local Token", "")
  configureClient()
  if gInitialized then
    testConnection()
    schedulePoll()
    startPush()
  end
end

--- The PIN letterbox: stored encrypted for the next Fetch Token run, wiped
--- from the property immediately, deleted from persist once used.
function OPC.Bond_PIN(propertyValue)
  log:trace("OPC.Bond_PIN(<redacted>)")
  local value = tostring(propertyValue or ""):gsub("%s+", "")
  if value == "" then
    return
  end
  persist:set(PIN_PERSIST, value, true)
  UpdateProperty("Bond PIN", "")
  log:print("Bond PIN stored - run 'Fetch Token From Bond' to pair")
end

-- The dispatcher logs property VALUES unless told otherwise. Both spellings,
-- because suppressDebug is consulted before the name is sanitized.
OPC.suppressDebug = OPC.suppressDebug or {}
OPC.suppressDebug["Local Token"] = true
OPC.suppressDebug.Local_Token = true
OPC.suppressDebug["Bond PIN"] = true
OPC.suppressDebug.Bond_PIN = true

function OPC.Bond_Address(propertyValue)
  log:trace("OPC.Bond_Address('%s')", propertyValue)
  configureClient()
  if gInitialized then
    -- The push socket is keyed to the old host; redial rather than letting
    -- it keep-alive a Bond that is no longer the target.
    stopPush()
    if bond:hasAddress() then
      testConnection()
      schedulePoll()
      startPush()
    end
  end
end

function OPC.Device_Poll_Interval(propertyValue)
  log:trace("OPC.Device_Poll_Interval('%s')", propertyValue)
  if gInitialized then
    schedulePoll()
  end
end

function OPC.Push_Updates(propertyValue)
  log:trace("OPC.Push_Updates('%s')", propertyValue)
  if not gInitialized then
    return
  end
  if tostring(propertyValue) == "On" then
    startPush()
  else
    stopPush()
  end
end

function OPC.Log_Mode(propertyValue)
  log:setLogMode(propertyValue)
  if not log:isEnabled() then
    return
  end
  log:setLogName(C4:GetDeviceData(C4:GetDeviceID(), "name"))
end

function OPC.Log_Level(propertyValue)
  log:setLogLevel(propertyValue)
end

-- ─── Actions ──────────────────────────────────────────────────────────────────

function EC.TEST_CONNECTION()
  log:trace("EC.TEST_CONNECTION()")
  configureClient()
  testConnection()
end

--- Opens the Bond's Sidekick learn window so a new keypad pairs by key
--- press. The new Sidekick shows up on the next sync.
function EC.LEARN_SIDEKICK()
  log:trace("EC.LEARN_SIDEKICK()")
  if not isConfigured() then
    log:print("Connect to the Bond first")
    return
  end
  bond:openSidekickLearn():next(function()
    log:print(
      "Sidekick learn window open for 60s: press any key on the new Sidekick near the Bond, "
        .. "then run Sync Devices Now and Auto Configure Bond Devices."
    )
  end, function(err)
    log:print("Could not open the learn window: %s", describeFailure(err))
  end)
end

function EC.DISCOVER_BONDS()
  log:trace("EC.DISCOVER_BONDS()")
  gDiscovered = {}
  UpdateProperty("Discovered Bonds", "searching...")
  log:print("Searching for Bonds on the network (mDNS _bond._tcp, %ds window)...", DISCOVERY_WINDOW_SECONDS)
  startDiscovery()
end

function EC.SYNC_DEVICES()
  log:trace("EC.SYNC_DEVICES()")
  syncDevices()
end

function EC.FETCH_TOKEN()
  log:trace("EC.FETCH_TOKEN()")
  configureClient()
  if not bond:hasAddress() then
    log:print("Set the Bond Address first")
    return
  end

  --- One read of /v2/token. `unlocked` marks the PIN-unlock retry: the
  --- endpoint gets re-locked afterwards either way, and the stored PIN is
  --- cleared once it has done its job.
  local function readToken(unlocked)
    bond:getToken():next(function(response)
      local body = Bond.decodeBody(response.body) or {}
      if type(body.token) == "string" and body.token ~= "" then
        persist:set(TOKEN_PERSIST, body.token, true)
        configureClient()
        log:print("Token received from the Bond and stored")
        if unlocked then
          bond:patchToken(1)
          persist:delete(PIN_PERSIST)
        end
        testConnection()
        schedulePoll()
        startPush()
        return
      end
      -- Locked. Try the PIN path once (the PIN printed on the Bond itself),
      -- then fall back to the power-cycle / app instructions.
      local pin = persist:get(PIN_PERSIST, "", true)
      if not unlocked and type(pin) == "string" and pin ~= "" then
        log:print("Token endpoint locked; unlocking with the stored Bond PIN...")
        bond:patchToken(0, pin):next(function()
          readToken(true)
        end, function(err)
          log:print("PIN unlock failed (%s) - check the Bond PIN property", describeFailure(err))
        end)
        return
      end
      log:print(
        "The Bond's token endpoint is locked. Set the Bond PIN property (printed on the Bond itself) and rerun, "
          .. "power-cycle the Bond and rerun within 10 minutes, "
          .. "or paste the Local Token from the Bond Home app (Settings > Advanced > Local Token)."
      )
    end, function(err)
      log:print("Token fetch failed: %s", describeFailure(err))
    end)
  end

  readToken(false)
end

function EC.FORGET_TOKEN()
  log:trace("EC.FORGET_TOKEN()")
  persist:delete(TOKEN_PERSIST)
  stopPush()
  configureClient()
  setConnected(false, "Token forgotten - paste a Local Token to reconnect")
  log:print("Local token forgotten")
end

function EC.PRINT_INVENTORY()
  log:trace("EC.PRINT_INVENTORY()")
  if gInventory == nil then
    log:print("No inventory yet - run Sync Devices Now")
    return
  end
  log:print("Bond inventory (synced %s):", tostring(gInventory.updated_at))
  for _, device in ipairs(gInventory.devices or {}) do
    log:print(
      "  %s '%s' type=%s location='%s' functions=%s actions=%d state=%s",
      device.id,
      device.name,
      device.type,
      device.location,
      table.concat(device.functions, "+"),
      #(device.actions or {}),
      JSON:encode(device.state or {})
    )
  end
end

function EC.PRINT_DEVICE_BINDINGS()
  log:trace("EC.PRINT_DEVICE_BINDINGS()")
  log:print("Bond device bindings:")
  local count = 0
  for _, fn in ipairs(FUNCTION_ORDER) do
    for key, binding in pairs(bindings:getDynamicBindings(FUNCTION_NS[fn])) do
      count = count + 1
      local device = deviceById(key)
      local child = boundConsumerForBinding(binding.bindingId)
      log:print(
        "  [%s] %s '%s' device=%s bound=%s",
        binding.bindingId,
        fn,
        binding.displayName,
        device ~= nil and device.name or (key .. " (NOT IN INVENTORY)"),
        child ~= nil and tostring(child) or "NOTHING - bind or Auto Configure"
      )
    end
  end
  if count == 0 then
    log:print("  none - run Sync Devices Now")
  end
end

function EC.PRUNE_STALE_DEVICES()
  log:trace("EC.PRUNE_STALE_DEVICES()")
  if gInventory == nil then
    log:print("No inventory to prune against - run Sync Devices Now first")
    return
  end
  local pruned = 0
  for key, binding in pairs(staleFunctionBindings()) do
    local fn = key:match("^(%u+):")
    local deviceId = key:match(":(.+)$")
    if fn ~= nil and deviceId ~= nil then
      bindings:deleteBinding(FUNCTION_NS[fn], deviceId)
      pruned = pruned + 1
      log:print("Pruned binding '%s' (%s)", binding.displayName, key)
    end
  end
  log:print("Pruned %d stale binding(s)", pruned)
end

--- The Agent's entitlement answer.
EC.SBOS_ENTITLEMENT = function(tParams)
  license.onEntitlement(tParams)
end

--- Re-registers and re-checks with the Agent on demand.
function EC.REFRESH_LICENSE()
  license.register()
  license.check()
end

-- ─── Auto-provisioning ────────────────────────────────────────────────────────
--
-- The Protect gateway's field-measured pattern, verbatim in shape:
-- user-initiated only, strictly one AddDevice in flight (the callback
-- carries no context), renames on a short timer AFTER the batch (the
-- callback's deviceId is the protocol id, Composer shows the proxy), never
-- deletes anything.

gProvisionQueue = {}
gProvisionInFlight = nil
gProvisionRenames = {}
local gAutoRenameAfterProvision = false

local function flushProvisionRenames()
  if #gProvisionRenames == 0 then
    return
  end
  SetTimer(PROVISION_RENAME_TIMER, 2 * ONE_SECOND, function()
    for _, entry in ipairs(gProvisionRenames) do
      for _, id in ipairs(entry.ids) do
        pcall(function()
          C4:RenameDevice(id, entry.name)
        end)
      end
      log:print("Auto configure: renamed %d device id(s) to '%s'", #entry.ids, entry.name)
    end
    gProvisionRenames = {}
    if gAutoRenameAfterProvision and autoRenameBoundDrivers ~= nil then
      gAutoRenameAfterProvision = false
      autoRenameBoundDrivers()
    end
  end)
end

local function processProvisionQueue()
  if gProvisionInFlight ~= nil then
    return
  end
  gProvisionInFlight = table.remove(gProvisionQueue, 1)
  if gProvisionInFlight == nil then
    log:print("Auto configure: done")
    flushProvisionRenames()
    return
  end
  local item = gProvisionInFlight
  log:print("Auto configure: adding %s for '%s'", item.file, item.name)
  -- The SIMPLEST documented form: (file, callback). A name in the room-id
  -- slot was measured returning 0 for every device.
  local ok, err = pcall(function()
    C4:AddDevice(item.file, OnBondDeviceAdded)
  end)
  if not ok then
    log:warn("AddDevice failed for %s: %s", item.name, tostring(err))
    gProvisionInFlight = nil
    processProvisionQueue()
  end
end

function OnBondDeviceAdded(deviceId, tDeviceInfo)
  local item = gProvisionInFlight
  gProvisionInFlight = nil
  if item == nil then
    return
  end
  -- Every outcome PRINTS: dealer-initiated action, watched in the Lua
  -- window where info/warn are invisible at default settings.
  deviceId = tonumber(deviceId) or 0
  if deviceId == 0 then
    log:print(
      "Auto configure: FAILED to add '%s' - upload %s to the controller once via Driver > Add or Update Driver, then rerun",
      item.name,
      item.file
    )
  else
    log:print("Auto configure: '%s' added as device %s", item.name, deviceId)
    -- Collect EVERY id Director mentioned: protocol id plus any proxy ids
    -- nested in the info table, whatever its shape.
    local ids = { deviceId }
    local function collectIds(t)
      for k, v in pairs(t) do
        if type(v) == "number" then
          table.insert(ids, v)
        elseif type(v) == "table" then
          collectIds(v)
        end
        if type(k) == "number" and k > 100 then
          table.insert(ids, k)
        end
      end
    end
    if type(tDeviceInfo) == "table" then
      pcall(collectIds, tDeviceInfo)
    end
    table.insert(gProvisionRenames, { ids = ids, name = item.name })
    -- The child's consumer connection is always binding 1.
    local ok, err = pcall(function()
      C4:Bind(C4:GetDeviceID(), item.bindingId, deviceId, 1, item.class)
    end)
    if ok then
      log:print("Auto configure: '%s' bound", item.name)
    else
      log:print("Auto configure: bind FAILED for '%s': %s - bind it in Connections", item.name, tostring(err))
    end
  end
  processProvisionQueue()
end

--- Renames every currently bound child from its provider-connection label.
--- (Assigns the forward declaration.)
autoRenameBoundDrivers = function()
  local renamed = 0
  for _, fn in ipairs(FUNCTION_ORDER) do
    for key, binding in pairs(bindings:getDynamicBindings(FUNCTION_NS[fn])) do
      local child = boundConsumerForBinding(binding.bindingId)
      if child ~= nil then
        local name = tostring(binding.displayName or key)
        pcall(function()
          C4:RenameDevice(child, name)
        end)
        SendToDevice(child, "BOND_RENAME", { name = name })
        renamed = renamed + 1
      end
    end
  end
  log:print("Auto rename: requested names for %d bound child driver(s)", renamed)
  return renamed
end

function EC.AUTO_RENAME_BOUND_DRIVERS()
  autoRenameBoundDrivers()
end

--- Queues an instance for every (device, function) that has no bound child.
local function queueMissingBondDevices()
  if license.enforces() then
    log:print("Auto configure unavailable: %s", license.enforcementReason())
    return
  end
  if gInventory == nil then
    log:print("No inventory yet - run Sync Devices Now first")
    return
  end
  local queued = 0
  for _, device in ipairs(gInventory.devices or {}) do
    for i, fn in ipairs(device.functions) do
      local binding = bindings:getDynamicBinding(FUNCTION_NS[fn], device.id)
      if binding ~= nil and boundConsumerForBinding(binding.bindingId) == nil then
        table.insert(gProvisionQueue, {
          file = PROVISION_FILES[fn],
          name = model.childLabel(device.name, fn, i == 1),
          bindingId = binding.bindingId,
          class = model.BINDING_CLASSES[fn],
        })
        queued = queued + 1
      end
    end
  end
  if queued == 0 then
    log:print("Auto configure: every discovered device already has a bound driver")
    gAutoRenameAfterProvision = false
    autoRenameBoundDrivers()
    return
  end
  log:print("Auto configure: %d device(s) to add, bind and rename", queued)
  processProvisionQueue()
end

--- The one-button workflow: refresh first so newly-added Bond devices are
--- included, then add/bind/rename every missing child.
function EC.AUTO_CONFIGURE_DEVICES()
  log:print("Auto configure: reading the Bond...")
  syncDevices(function(ok)
    if not ok then
      log:print("Auto configure: sync failed; renaming already-bound drivers from the last-known inventory")
      autoRenameBoundDrivers()
      return
    end
    gAutoRenameAfterProvision = true
    queueMissingBondDevices()
  end)
end
