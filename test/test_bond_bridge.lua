-- Tests for drivers/bond-bridge/driver.lua (+ src/bond/model.lua).
--
-- The driver is loaded against a fake `lib.http` and `lib.persist` plus C4
-- stubs, so every assertion is about what the driver decided to send and
-- what state it moved to. The invariants under test:
--
--   * The token is a LETTERBOX: pasted, stored encrypted, property wiped.
--   * Function derivation: a fan with a light grows a FAN binding AND a
--     LIGHT binding; a shade grows one SHADE binding; bindings are
--     idempotent across re-syncs and never deleted implicitly.
--   * The identity handshake answers over both paths (binding RFP and
--     requester EC) with JSON-encoded documents.
--   * A child action PUTs the right URL with the right body, re-reads
--     state, pushes the fresh state to the child, and reports the result.
--   * BPUP frames update state and push to children, deduped by Bond's own
--     state hash — an echo of a state already pushed stays silent.
--   * A 401 sends the dealer to the token; a transport failure sends them
--     to the network. The two must never read the same.
--
-- Run from the driver root:
--   make test

local pass, fail = 0, 0
local function check(name, ok, detail)
  if ok then
    pass = pass + 1
    print(string.format("  ok   %s", name))
  else
    fail = fail + 1
    print(string.format("  FAIL %s%s", name, detail and ("  -> " .. tostring(detail)) or ""))
  end
end

-- ─── Fakes ────────────────────────────────────────────────────────────────────

--- Every request the driver handed to lib.http, newest last.
local requests = {}

--- Route table: first match wins; order matters (specific paths first).
local routes = {}

local function respond(method, url)
  for _, r in ipairs(routes) do
    if url:find(r.match, 1, true) and (r.method == nil or r.method == method) then
      return r
    end
  end
  return { ok = true, code = 200, body = {} }
end

local function settled(isOk, value)
  return {
    next = function(_, onOk, onErr)
      if isOk then
        if onOk then
          onOk(value)
        end
      elseif onErr then
        onErr(value)
      end
    end,
  }
end

local function fakeRequest(method, url, data, headers, options)
  table.insert(requests, { method = method, url = url, data = data, headers = headers, options = options })
  local r = respond(method, url)
  if r.ok then
    return settled(true, { url = url, code = r.code or 200, headers = {}, body = r.body })
  end
  return settled(false, { url = url, code = r.code, headers = {}, body = r.body, error = r.error or "request failed" })
end

package.preload["lib.http"] = function()
  return {
    request = fakeRequest,
    get = function(_, url, headers, options)
      return fakeRequest("GET", url, nil, headers, options)
    end,
    put = function(_, url, data, headers, options)
      return fakeRequest("PUT", url, data, headers, options)
    end,
    patch = function(_, url, data, headers, options)
      return fakeRequest("PATCH", url, data, headers, options)
    end,
  }
end

package.preload["cloud-client-byte"] = function()
  return {}
end

--- Persistence that records the encrypted flag, which is half the point.
local store, storeEncrypted = {}, {}
package.preload["lib.persist"] = function()
  return {
    get = function(_, key, default)
      local value = store[key]
      if value == nil then
        return default
      end
      return value
    end,
    set = function(_, key, value, encrypted)
      store[key] = value
      storeEncrypted[key] = encrypted and true or false
    end,
    delete = function(_, key)
      store[key] = nil
      storeEncrypted[key] = nil
    end,
  }
end

C4 = C4 or {}

--- Everything sent over a binding / to a device.
local proxySent = {}
function C4:SendToProxy(binding, command, params, message)
  table.insert(proxySent, { binding = binding, command = command, params = params, message = message })
end
local deviceSent = {}
function C4:SendToDevice(deviceId, command, params)
  table.insert(deviceSent, { device = deviceId, command = command, params = params })
end

local function sentTo(list, keyName, keyValue, command)
  local hits = {}
  for _, s in ipairs(list) do
    if s[keyName] == keyValue and s.command == command then
      table.insert(hits, s)
    end
  end
  return hits
end

--- Dynamic bindings as Director would see them.
local addedBindings = {}
function C4:AddDynamicBinding(id, bindingType, provider, name, class)
  addedBindings[id] = { type = bindingType, provider = provider, name = name, class = class }
end
function C4:RemoveDynamicBinding(id)
  addedBindings[id] = nil
end

--- Consumer map: bindingId -> { [childDeviceId] = true }.
local boundMap = {}
function C4:GetBoundConsumerDevices(_, bindingId)
  return boundMap[bindingId]
end

--- Net-connection surface for BPUP.
local netCalls = {}
local netBindingAddresses = {}
function C4:GetBindingAddress(id)
  return netBindingAddresses[id]
end
function C4:CreateNetworkConnection(id, host, protocol)
  netBindingAddresses[id] = host
  table.insert(netCalls, { call = "create", id = id, host = host, protocol = protocol })
end
function C4:NetPortOptions(id, port, protocol, options)
  table.insert(netCalls, { call = "portoptions", id = id, port = port, protocol = protocol, options = options })
end
function C4:NetConnect(id, port, protocol)
  table.insert(netCalls, { call = "connect", id = id, port = port, protocol = protocol })
end
function C4:NetDisconnect(id, port)
  table.insert(netCalls, { call = "disconnect", id = id, port = port })
end
local netSent = {}
function C4:SendToNetwork(id, port, data)
  table.insert(netSent, { id = id, port = port, data = data })
end

local firedEvents = {}
function C4:FireEvent(name)
  table.insert(firedEvents, name)
end
function C4:AddEvent() end
function C4:SetConditionalState() end
function C4:Bind() end
function C4:RenameDevice() end

--- Property values as the driver published them.
local props = {}

require("c4_shim")

function C4:UpdateProperty(name, value)
  props[name] = value
  if Properties[name] ~= nil then
    Properties[name] = value
  end
end

function C4:GetDriverConfigInfo(key)
  return ({ model = "Bond Bridge Gateway", version = "1.0.0", minimum_os_version = "3.2.0" })[key]
end

-- The shim reports OS version "test", which fails CheckMinimumVersion and
-- disables the driver before anything under test runs.
function C4:GetVersionInfo()
  return { version = "4.0.0" }
end

Properties = {
  ["Bond Address"] = "",
  ["Local Token"] = "",
  ["Device Poll Interval"] = "1m",
  ["Push Updates"] = "On",
  ["Driver Status"] = "Starting",
  ["Connection Status"] = "",
  ["Bond ID"] = "-",
  ["Model"] = "-",
  ["Firmware"] = "-",
  ["Devices"] = "-",
  ["Scenes"] = "-",
  ["Bond PIN"] = "",
  ["Discovered Bonds"] = "-",
  ["Push Status"] = "Off",
  ["Last Sync"] = "Never",
  ["License Status"] = "-",
  ["License Source"] = "-",
  ["Log Level"] = "3 - Info",
  ["Log Mode"] = "Off",
}

package.path = "./drivers/bond-bridge/?.lua;../drivers/bond-bridge/?.lua;" .. package.path
local loaded = pcall(dofile, "drivers/bond-bridge/driver.lua")
if not loaded then
  loaded = pcall(dofile, "../drivers/bond-bridge/driver.lua")
end
assert(loaded, "driver.lua failed to load")

-- ─── Bond fixture ─────────────────────────────────────────────────────────────
--
-- One fan-with-light (two functions) and one positional shade.

local FAN_ACTIONS = {
  "TurnOn",
  "TurnOff",
  "TogglePower",
  "SetSpeed",
  "IncreaseSpeed",
  "DecreaseSpeed",
  "SetDirection",
  "TurnLightOn",
  "TurnLightOff",
  "ToggleLight",
}
local SHADE_ACTIONS = { "Open", "Close", "ToggleOpen", "SetPosition", "Hold", "Preset" }

local fanState = { ["_"] = "s-fan-1", power = 1, speed = 3, light = 0, direction = 1 }
local shadeState = { ["_"] = "s-shade-1", open = 1, position = 0 }

local function routeHappyBond()
  routes = {
    {
      match = "/v2/sys/version",
      ok = true,
      body = { bondid = "ZZBL12345", make = "Olibra", model = "BD-1000", fw_ver = "v3.5.0" },
    },
    { match = "/v2/devices/fan1/state", ok = true, body = fanState },
    { match = "/v2/devices/fan1/properties", ok = true, body = { ["_"] = "p-fan", max_speed = 6 } },
    { match = "/v2/devices/fan1/actions/", ok = true, body = {} },
    {
      match = "/v2/devices/fan1",
      ok = true,
      body = { name = "Master Fan", type = "CF", location = "Master Bedroom", actions = FAN_ACTIONS },
    },
    { match = "/v2/devices/shade1/state", ok = true, body = shadeState },
    { match = "/v2/devices/shade1/properties", ok = true, body = { ["_"] = "p-shade", open_raises = true } },
    { match = "/v2/devices/shade1/actions/", ok = true, body = {} },
    {
      match = "/v2/devices/shade1",
      ok = true,
      body = { name = "Patio Shade", type = "MS", subtype = "ROLLER", location = "Patio", actions = SHADE_ACTIONS },
    },
    { match = "/v2/scenes/scene1/run", ok = true, body = {} },
    { match = "/v2/scenes/scene1", ok = true, body = { name = "Goodnight" } },
    { match = "/v2/scenes", ok = true, body = { ["_"] = "sc-1", scene1 = { ["_"] = "s1" } } },
    {
      match = "/v2/sidekicks/sk1",
      ok = true,
      body = { name = "Bedroom Sidekick", location = "Bedroom", keys = 3, battery = 90, signal = 97, model = "SKN-386" },
    },
    {
      match = "/v2/sidekicks/ws1/state",
      ok = true,
      body = {
        status = "idle",
        data_temperature_dc = 212,
        data_humidity_percent = 65,
        data_wind_speed_dms = 32,
        data_rain_mmh = 0,
        data_sun_level = 6,
        is_raining = false,
        battery = 80,
        battery_2 = 77,
      },
    },
    {
      match = "/v2/sidekicks/ws1",
      ok = true,
      body = { name = "Patio Breeze", location = "Patio", type = "weather_sensor", model = "BWS-1000" },
    },
    {
      match = "/v2/sidekicks",
      ok = true,
      body = { ["_"] = "sk-root", sk1 = { ["_"] = "k1" }, ws1 = { ["_"] = "w1" } },
    },
    {
      match = "/v2/devices",
      ok = true,
      body = { ["_"] = "root-1", fan1 = { ["_"] = "d1" }, shade1 = { ["_"] = "d2" } },
    },
  }
end

local function bindingIdByName(name)
  for id, b in pairs(addedBindings) do
    if b.name == name then
      return id
    end
  end
  return nil
end

-- ─── [1] Unconfigured startup ────────────────────────────────────────────────

print("\n[1] Unconfigured startup is quiet and says so")

OnDriverInit()
OnDriverLateInit()

check("no requests were made", #requests == 0, #requests)
check(
  "Connection Status says not configured",
  tostring(props["Connection Status"]):find("Not configured") ~= nil,
  props["Connection Status"]
)
check("connected conditional is false", TC.BOND_CONNECTED() == false)

-- ─── [2] Address without token probes but does not sync ──────────────────────

print("\n[2] An address alone probes the Bond and asks for the token")

routeHappyBond()
requests = {}
Properties["Bond Address"] = "192.168.1.50"
OnPropertyChanged("Bond Address")

check("version probe went out", #requests >= 1 and requests[1].url:find("/v2/sys/version", 1, true) ~= nil)
check("no authenticated sync yet", #requests == 1, #requests)
check("Bond ID published", props["Bond ID"] == "ZZBL12345", props["Bond ID"])
check("Model published", tostring(props["Model"]):find("BD%-1000") ~= nil, props["Model"])
check(
  "status asks for the token",
  tostring(props["Connection Status"]):find("[Tt]oken") ~= nil,
  props["Connection Status"]
)

-- ─── [3] Token letterbox + first sync ────────────────────────────────────────

print("\n[3] Pasting the token stores it encrypted, wipes the property, syncs")

requests = {}
Properties["Local Token"] = "  deadbeef01  "
OnPropertyChanged("Local Token")

check("token stored", store["bond_token"] == "deadbeef01", store["bond_token"])
check("token stored ENCRYPTED", storeEncrypted["bond_token"] == true)
check("property wiped", props["Local Token"] == "")
check("connected", TC.BOND_CONNECTED() == true)
check("Bond Online fired", firedEvents[#firedEvents] == "Bond Online")
check("Devices count published (incl. sidekicks)", props["Devices"] == "4", props["Devices"])

local authed = 0
for _, r in ipairs(requests) do
  if r.headers ~= nil and r.headers["BOND-Token"] == "deadbeef01" then
    authed = authed + 1
  end
end
check("authenticated requests carried the token", authed >= 7, authed)

check("fan binding exists", bindingIdByName("Master Fan") ~= nil)
check("fan LIGHT binding exists", bindingIdByName("Master Fan Light") ~= nil)
check("shade binding exists", bindingIdByName("Patio Shade") ~= nil)
check("keypad binding exists", bindingIdByName("Bedroom Sidekick") ~= nil)
check("keypad binding class", addedBindings[bindingIdByName("Bedroom Sidekick")].class == "SBOS_BOND_KEYPAD")
check("weather binding exists", bindingIdByName("Patio Breeze") ~= nil)
check("weather binding class", addedBindings[bindingIdByName("Patio Breeze")].class == "SBOS_BOND_WEATHER")
check("fan binding class", addedBindings[bindingIdByName("Master Fan")].class == "SBOS_BOND_FAN")
check("light binding class", addedBindings[bindingIdByName("Master Fan Light")].class == "SBOS_BOND_LIGHT")
check("shade binding class", addedBindings[bindingIdByName("Patio Shade")].class == "SBOS_BOND_SHADE")

local bindingCount = 0
for _ in pairs(addedBindings) do
  bindingCount = bindingCount + 1
end
check("exactly five bindings", bindingCount == 5, bindingCount)

EC.SYNC_DEVICES()
local bindingCountAfter = 0
for _ in pairs(addedBindings) do
  bindingCountAfter = bindingCountAfter + 1
end
check("re-sync is idempotent", bindingCountAfter == 5, bindingCountAfter)

-- ─── [3b] Scenes ─────────────────────────────────────────────────────────────

print("\n[3b] Bond scenes sync and run from programming")

check("scene count published", props["Scenes"] == "1", tostring(props["Scenes"]))

requests = {}
EC.RUN_BOND_SCENE({ Scene = "goodnight" })
local sceneRun
for _, r in ipairs(requests) do
  if r.url:find("/run", 1, true) then
    sceneRun = r
  end
end
check("scene resolved by NAME, case-insensitive", sceneRun ~= nil)
check(
  "scene run is a PUT to the scene id",
  sceneRun ~= nil and sceneRun.method == "PUT" and sceneRun.url:find("/v2/scenes/scene1/run", 1, true) ~= nil
)

requests = {}
EC.RUN_BOND_SCENE({ Scene = "no-such-scene" })
check("unknown scene sends nothing", #requests == 0, #requests)

-- ─── [3c] PIN-unlock token fetch ─────────────────────────────────────────────

print("\n[3c] Fetch Token uses the stored Bond PIN to unlock")

Properties["Bond PIN"] = "  4321  "
OnPropertyChanged("Bond PIN")
check("PIN stored encrypted", store["bond_pin"] == "4321" and storeEncrypted["bond_pin"] == true)
check("PIN property wiped", props["Bond PIN"] == "")

routes = {
  { match = "/v2/token", method = "GET", ok = true, body = { locked = 1 } },
  { match = "/v2/token", method = "PATCH", ok = true, body = {} },
}
requests = {}
EC.FETCH_TOKEN()
local unlockPatch
for _, r in ipairs(requests) do
  if r.method == "PATCH" and r.url:find("/v2/token", 1, true) then
    unlockPatch = r
  end
end
check("locked endpoint triggers a PIN unlock PATCH", unlockPatch ~= nil)
check(
  "unlock carries locked=0 and the stored PIN",
  unlockPatch ~= nil
    and type(unlockPatch.data) == "table"
    and unlockPatch.data.locked == 0
    and unlockPatch.data.pin == "4321"
)
routeHappyBond()

-- ─── [4] Identity handshake ──────────────────────────────────────────────────

print("\n[4] Identity answers over both paths, documents as JSON")

local fanBinding = bindingIdByName("Master Fan")
proxySent = {}
RFP.BOND_GET_DEVICE(fanBinding)
local answers = sentTo(proxySent, "binding", fanBinding, "BOND_DEVICE")
check("RFP path answered", #answers == 1, #answers)
local params = (answers[1] or {}).params or {}
check("identity id", params.id == "fan1")
check("identity fn", params.fn == "FAN")
check("identity name", params.name == "Master Fan")
local decodedActions = JSON:decode(params.actions_json or "")
check("actions ride as JSON", type(decodedActions) == "table" and #decodedActions == #FAN_ACTIONS)
local decodedState = JSON:decode(params.state_json or "")
check("state rides as JSON", type(decodedState) == "table" and decodedState.speed == 3)
local decodedProps = JSON:decode(params.props_json or "")
check("props ride as JSON", type(decodedProps) == "table" and decodedProps.max_speed == 6)

-- Bind a child device 301 to the fan binding; the EC path resolves it.
boundMap[fanBinding] = { [301] = true }
deviceSent = {}
EC.BOND_GET_DEVICE({ requester = "301" })
local deviceAnswers = sentTo(deviceSent, "device", 301, "BOND_DEVICE")
check("EC path answered to the requester", #deviceAnswers == 1, #deviceAnswers)
check("EC path same device", (deviceAnswers[1] or {}).params.id == "fan1")

-- ─── [5] Child action ────────────────────────────────────────────────────────

print("\n[5] A child action PUTs, re-reads state, pushes, reports")

requests = {}
deviceSent = {}
-- The re-read returns a moved state so the push is observable.
fanState = { ["_"] = "s-fan-2", power = 1, speed = 5, light = 0, direction = 1 }
routeHappyBond()

EC.BOND_ACTION({ requester = "301", action = "SetSpeed", argument = "5" })

local actionRequest
for _, r in ipairs(requests) do
  if r.url:find("/actions/", 1, true) then
    actionRequest = r
  end
end
check("action PUT went out", actionRequest ~= nil)
check(
  "action URL",
  actionRequest ~= nil and actionRequest.url:find("/v2/devices/fan1/actions/SetSpeed", 1, true) ~= nil
)
check(
  "argument decoded to number",
  actionRequest ~= nil and type(actionRequest.data) == "table" and actionRequest.data.argument == 5
)

local results = sentTo(deviceSent, "device", 301, "BOND_ACTION_RESULT")
check("result reported to the child", #results == 1, #results)
check("result ok", (results[1] or {}).params.ok == "true")

local statePushes = sentTo(deviceSent, "device", 301, "BOND_STATE")
check("fresh state pushed to the child", #statePushes >= 1, #statePushes)
local pushedState = JSON:decode((statePushes[#statePushes] or {}).params.state_json or "")
check("pushed state is the re-read one", type(pushedState) == "table" and pushedState.speed == 5)

-- ─── [6] BPUP push ───────────────────────────────────────────────────────────

print("\n[6] BPUP frames update state, push to children, dedupe by hash")

check("BPUP socket was opened", #netCalls >= 3)
local udpOk = false
for _, call in ipairs(netCalls) do
  if call.call == "portoptions" and call.port == 30007 and call.protocol == "UDP" then
    udpOk = true
  end
end
check("BPUP port options are UDP 30007", udpOk)

local bpupBinding
for _, call in ipairs(netCalls) do
  if call.call == "create" then
    bpupBinding = call.id
  end
end
check("BPUP handler registered", bpupBinding ~= nil and RFN[bpupBinding] ~= nil)

deviceSent = {}
RFN[bpupBinding](
  bpupBinding,
  30007,
  '{"B":"ZZBL12345","t":"devices/fan1/state","s":200,"m":0,"b":{"_":"s-fan-3","power":0,"speed":5,"light":0,"direction":1}}\n'
)
statePushes = sentTo(deviceSent, "device", 301, "BOND_STATE")
check("push update reached the child", #statePushes == 1, #statePushes)
pushedState = JSON:decode((statePushes[1] or {}).params.state_json or "")
check("pushed state is the BPUP one", type(pushedState) == "table" and pushedState.power == 0)
check("Push Status is Delivering", props["Push Status"] == "Delivering", props["Push Status"])

-- The identical frame again: same hash, no re-push.
deviceSent = {}
RFN[bpupBinding](
  bpupBinding,
  30007,
  '{"B":"ZZBL12345","t":"devices/fan1/state","s":200,"m":0,"b":{"_":"s-fan-3","power":0,"speed":5,"light":0,"direction":1}}\n'
)
statePushes = sentTo(deviceSent, "device", 301, "BOND_STATE")
check("hash-identical echo stays silent", #statePushes == 0, #statePushes)

-- ─── [6b] Sidekick keystream routing ─────────────────────────────────────────

print("\n[6b] Keystream pushes route to the bound keypad child")

local keypadBinding = bindingIdByName("Bedroom Sidekick")
boundMap[keypadBinding] = { [401] = true }
deviceSent = {}
RFN[bpupBinding](
  bpupBinding,
  30007,
  '{"B":"ZZBL12345","t":"sidekicks/sk1/keystream","s":200,"m":0,"b":{"seq":42,"event":"TAP","key":2}}\n'
)
local keyPushes = sentTo(deviceSent, "device", 401, "BOND_KEYSTREAM")
check("keystream reached the keypad child", #keyPushes == 1, #keyPushes)
check(
  "event and key carried",
  #keyPushes == 1 and keyPushes[1].params.event == "TAP" and keyPushes[1].params.key == "2"
)

deviceSent = {}
RFN[bpupBinding](
  bpupBinding,
  30007,
  '{"B":"ZZBL12345","t":"sidekicks/unknown/keystream","s":200,"m":0,"b":{"event":"TAP","key":1}}\n'
)
check("unknown sidekick keystream is quietly dropped", #deviceSent == 0, #deviceSent)

-- ─── [6c] Weather state pushes ───────────────────────────────────────────────

print("\n[6c] Weather sensor state pushes route through the device pipeline")

local weatherBinding = bindingIdByName("Patio Breeze")
boundMap[weatherBinding] = { [402] = true }
deviceSent = {}
RFN[bpupBinding](
  bpupBinding,
  30007,
  '{"B":"ZZBL12345","t":"sidekicks/ws1/state","s":200,"m":0,"b":{"status":"triggered_rain","data_temperature_dc":185,"is_raining":true,"data_rain_mmh":4}}\n'
)
local weatherPushes = sentTo(deviceSent, "device", 402, "BOND_STATE")
check("weather push reached the child", #weatherPushes == 1, #weatherPushes)
local pushedWeather = JSON:decode((weatherPushes[1] or {}).params.state_json or "")
check(
  "pushed measurements intact",
  type(pushedWeather) == "table" and pushedWeather.data_temperature_dc == 185 and pushedWeather.is_raining == true
)

-- ─── [7] Failure vocabulary ──────────────────────────────────────────────────

print("\n[7] 401 talks about the token; transport failure talks about the network")

routes = {
  { match = "/v2/devices", ok = false, code = 401, body = {} },
}
EC.SYNC_DEVICES()
check(
  "401 sends the dealer to the token",
  tostring(props["Connection Status"]):find("[Tt]oken") ~= nil,
  props["Connection Status"]
)

routes = {
  { match = "/v2/devices", ok = false, body = {} },
}
EC.SYNC_DEVICES()
check(
  "transport failure says unreachable",
  tostring(props["Connection Status"]):find("unreachable") ~= nil,
  props["Connection Status"]
)
check("disconnected", TC.BOND_CONNECTED() == false)
check("Bond Offline fired", firedEvents[#firedEvents] == "Bond Offline")

-- ─── [8] Stale bindings survive until pruned ─────────────────────────────────

print("\n[8] A device removed from the Bond leaves its binding until pruned")

routes = {
  { match = "/v2/devices/fan1/state", ok = true, body = fanState },
  { match = "/v2/devices/fan1/properties", ok = true, body = { ["_"] = "p-fan", max_speed = 6 } },
  {
    match = "/v2/devices/fan1",
    ok = true,
    body = { name = "Master Fan", type = "CF", location = "Master Bedroom", actions = FAN_ACTIONS },
  },
  { match = "/v2/devices", ok = true, body = { ["_"] = "root-2", fan1 = { ["_"] = "d1" } } },
}
EC.SYNC_DEVICES()

check("shade binding survives the sync", bindingIdByName("Patio Shade") ~= nil)

EC.PRUNE_STALE_DEVICES()
check("prune removes the shade binding", bindingIdByName("Patio Shade") == nil)
check(
  "fan bindings survive the prune",
  bindingIdByName("Master Fan") ~= nil and bindingIdByName("Master Fan Light") ~= nil
)

-- ─── [9] Forget Token ────────────────────────────────────────────────────────

print("\n[9] Forget Token wipes the secret and says so")

EC.FORGET_TOKEN()
check("token gone from persist", store["bond_token"] == nil)
check(
  "status says token forgotten",
  tostring(props["Connection Status"]):find("forgotten") ~= nil,
  props["Connection Status"]
)

-- ─── [10] mDNS discovery ─────────────────────────────────────────────────────

print("\n[10] Discovery fills the property; only a default address auto-fills")

--- A full (uncompressed) mDNS answer for one Bond: PTR + SRV + A.
local function mdnsAnswer(bondid, a, b, c, d)
  local function num16(n)
    return string.char(math.floor(n / 256), n % 256)
  end
  local function num32(n)
    return num16(math.floor(n / 65536)) .. num16(n % 65536)
  end
  local function dnsName(name)
    local out = {}
    for lab in name:gmatch("[^%.]+") do
      table.insert(out, string.char(#lab) .. lab)
    end
    return table.concat(out) .. "\0"
  end
  local instance = dnsName(bondid .. "._bond._tcp.local")
  local host = dnsName(bondid .. ".local")
  local srvData = num16(0) .. num16(0) .. num16(80) .. host
  return table.concat({
    num16(0),
    num16(0x8400),
    num16(0),
    num16(3),
    num16(0),
    num16(0),
    dnsName("_bond._tcp.local"),
    num16(12),
    num16(1),
    num32(120),
    num16(#instance),
    instance,
    instance,
    num16(33),
    num16(1),
    num32(120),
    num16(#srvData),
    srvData,
    host,
    num16(1),
    num16(1),
    num32(120),
    num16(4),
    string.char(a, b, c, d),
  })
end

-- The startup pass already opened the resolver socket; find its binding.
local discBinding
for _, call in ipairs(netCalls) do
  if call.call == "create" and call.host == "224.0.0.251" then
    discBinding = call.id
  end
end
check("discovery socket opened at startup", discBinding ~= nil and RFN[discBinding] ~= nil)

-- Address is the install default and the token is forgotten → auto-fill.
routeHappyBond()
requests = {}
EC.DISCOVER_BONDS()
check("action says searching", props["Discovered Bonds"] == "searching...")

RFN[discBinding](discBinding, 5353, mdnsAnswer("ZZBL54321", 10, 0, 0, 9))
check(
  "discovered Bond listed",
  tostring(props["Discovered Bonds"]):find("ZZBL54321 @ 10.0.0.9", 1, true) ~= nil,
  props["Discovered Bonds"]
)
check("default address auto-filled", props["Bond Address"] == "10.0.0.9", props["Bond Address"])
local probed = false
for _, r in ipairs(requests) do
  if r.url == "http://10.0.0.9/v2/sys/version" then
    probed = true
  end
end
check("auto-fill probed the discovered Bond", probed)

-- Reconnect (token pasted) and hear a DIFFERENT Bond: never re-pointed.
Properties["Local Token"] = "deadbeef01"
OnPropertyChanged("Local Token")
check("reconnected to the discovered Bond", TC.BOND_CONNECTED() == true)

RFN[discBinding](discBinding, 5353, mdnsAnswer("ZZBL99999", 10, 0, 0, 42))
check(
  "second Bond listed too",
  tostring(props["Discovered Bonds"]):find("ZZBL99999 @ 10.0.0.42", 1, true) ~= nil,
  props["Discovered Bonds"]
)
check("a connected gateway is never re-pointed", props["Bond Address"] == "10.0.0.9", props["Bond Address"])

-- ─── Summary ──────────────────────────────────────────────────────────────────

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
