-- Tests for drivers/unifi-protect/driver.lua.
--
-- The driver is loaded against a fake `lib.http`, `lib.persist` and
-- `lib.bindings`-facing C4 stubs, so every assertion is about what the driver
-- decided to send and what state it moved to. The invariants under test:
--
--   * The API key is a LETTERBOX: pasted into the property, stored encrypted,
--     and the property wiped — the key must never survive in the project file.
--   * TLS verification is off by default (self-signed console) and the
--     ssl_verify_* options actually reach the transport; turning the property
--     On removes them.
--   * A 401/403 reports "check the API key", a transport failure reports
--     "unreachable" — the two failures send a dealer to different places, and
--     lib.http rejects for both, so conflating them is the natural bug.
--   * A sync creates ONE provider CONTROL binding per camera, is idempotent
--     across re-syncs, and NEVER deletes a binding by itself. Pruning is an
--     explicit action.
--   * A camera list the console answered with a non-list body fails the sync
--     rather than applying an empty inventory over a good one.
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

--- Every request the driver handed to lib.http, newest last:
--- { method, url, data, headers, options }.
local requests = {}

--- Route table: first match wins. Each entry:
--- { match = "...", method = "GET"|nil, ok = true, code = 200, body = <table|string> }.
--- `method` nil matches any method; order matters — put specific paths first
--- ("/rtsps-stream" before "/v1/cameras", which is its prefix).
local routes = {}

local function respond(method, url)
  for _, r in ipairs(routes) do
    if url:find(r.match, 1, true) and (r.method == nil or r.method == method) then
      return r
    end
  end
  return { ok = true, code = 200, body = {} }
end

--- Minimal Deferred: the driver chains one :next per request.
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
    get = function(_, url, headers, options)
      return fakeRequest("GET", url, nil, headers, options)
    end,
    post = function(_, url, data, headers, options)
      return fakeRequest("POST", url, data, headers, options)
    end,
    put = function(_, url, data, headers, options)
      return fakeRequest("PUT", url, data, headers, options)
    end,
    delete = function(_, url, headers, options)
      return fakeRequest("DELETE", url, nil, headers, options)
    end,
  }
end

--- The DRIVERCENTRAL branch of OnDriverInit requires this. The oss build
--- strips it at preprocess time; the raw tree under test still carries both
--- branches, so the stub stands in for the strip.
package.preload["cloud-client-byte"] = function()
  return {}
end

--- Fake websocket module: records every instance and its callbacks so tests
--- can drive frames through ProcessMessage and observe lifecycle calls. The
--- real module would hit C4:CreateNetworkConnection at :new.
--- @type table[]
local wsInstances = {}
package.preload["drivers-common-public.module.websocket"] = function()
  local FakeWs = {}
  FakeWs.__index = FakeWs
  function FakeWs:new(url, additionalHeaders)
    local ws = setmetatable({ url = url, headers = additionalHeaders or {}, started = 0, deleted = false }, FakeWs)
    table.insert(wsInstances, ws)
    return ws
  end
  function FakeWs:SetProcessMessageFunction(f)
    self.processMessage = f
    return self
  end
  function FakeWs:SetEstablishedFunction(f)
    self.established = f
    return self
  end
  function FakeWs:SetClosedByRemoteFunction(f)
    self.closedByRemote = f
    return self
  end
  function FakeWs:SetOfflineFunction(f)
    self.offline = f
    return self
  end
  function FakeWs:Start()
    self.started = self.started + 1
    return self
  end
  function FakeWs:delete()
    self.deleted = true
  end
  return FakeWs
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

--- Everything sent over a binding: { binding, command, params }.
local proxySent = {}
function C4:SendToProxy(binding, command, params, message)
  table.insert(proxySent, { binding = binding, command = command, params = params, message = message })
end

local function proxySentTo(binding, command)
  local hits = {}
  for _, s in ipairs(proxySent) do
    if s.binding == binding and s.command == command then
      table.insert(hits, s)
    end
  end
  return hits
end

--- Dynamic bindings as Director would see them: id -> {type, provider, name, class}.
local addedBindings = {}
local removedBindings = {}
function C4:AddDynamicBinding(id, bindingType, provider, name, class)
  addedBindings[id] = { type = bindingType, provider = provider, name = name, class = class }
end
function C4:RemoveDynamicBinding(id)
  addedBindings[id] = nil
  table.insert(removedBindings, id)
end

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
  return ({ model = "UniFi Protect Gateway", version = "1.0.0", minimum_os_version = "3.3.2" })[key]
end

-- The shim reports OS version "test", which fails CheckMinimumVersion and
-- disables the driver before anything under test runs.
function C4:GetVersionInfo()
  return { version = "4.0.0" }
end

Properties = {
  ["Console Address"] = "https://192.168.4.1",
  ["API Key"] = "",
  ["Verify TLS Certificate"] = "Off",
  ["Device Poll Interval"] = "1m",
  ["Driver Status"] = "Starting",
  ["Connection Status"] = "",
  ["Protect Version"] = "-",
  ["NVR Name"] = "-",
  ["Cameras"] = "-",
  ["Lights"] = "-",
  ["Sensors"] = "-",
  ["Chimes"] = "-",
  ["Last Sync"] = "Never",
  ["Event Stream"] = "Off",
  ["Log Level"] = "3 - Info",
  ["Log Mode"] = "Off",
}

package.path = "./drivers/unifi-protect/?.lua;../drivers/unifi-protect/?.lua;" .. package.path
local loaded = pcall(dofile, "drivers/unifi-protect/driver.lua")
if not loaded then
  loaded = pcall(dofile, "../drivers/unifi-protect/driver.lua")
end
assert(loaded, "driver.lua failed to load")

-- ─── Console fixture ──────────────────────────────────────────────────────────

local CAMERAS = {
  { id = "cam-front", name = "Front Door", mac = "60223263A4D0", state = "CONNECTED" },
  { id = "cam-drive", name = "Driveway", mac = "60223263A4D1", state = "DISCONNECTED" },
}

local function routeHappyConsole()
  routes = {
    { match = "/v1/meta/info", ok = true, code = 200, body = { applicationVersion = "6.2.83" } },
    { match = "/v1/nvrs", ok = true, code = 200, body = { id = "nvr-1", modelKey = "nvr", name = "Dream Machine" } },
    { match = "/v1/cameras", ok = true, code = 200, body = CAMERAS },
    { match = "/v1/lights", ok = true, code = 200, body = {} },
    { match = "/v1/sensors", ok = true, code = 200, body = { { id = "sen-1", name = "Garage", state = "CONNECTED" } } },
    { match = "/v1/chimes", ok = true, code = 200, body = {} },
  }
end

-- ─── [1] Startup with nothing configured ─────────────────────────────────────

print("\n[1] Unconfigured startup is quiet and says so")

OnDriverInit()
OnDriverLateInit()

check("no requests were made", #requests == 0, #requests)
check(
  "Connection Status says not configured",
  tostring(props["Connection Status"]):find("Not configured") ~= nil,
  props["Connection Status"]
)
check("connected conditional is false", TC.UNIFI_PROTECT_CONNECTED() == false)

-- ─── [2] The API key letterbox ────────────────────────────────────────────────

print("\n[2] Pasting an API key stores it encrypted and wipes the property")

routeHappyConsole()
Properties["API Key"] = "  secret-key-123  "
OnPropertyChanged("API Key")

check("key stored", store["protect_api_key"] == "secret-key-123", store["protect_api_key"])
check("key stored ENCRYPTED", storeEncrypted["protect_api_key"] == true)
check("property wiped", props["API Key"] == "", props["API Key"])

check("a request went out", #requests > 0, #requests)
local first = requests[1]
check(
  "to the Integration API meta/info",
  first.url == "https://192.168.4.1/proxy/protect/integration/v1/meta/info",
  first.url
)
check("with the X-API-KEY header", (first.headers or {})["X-API-KEY"] == "secret-key-123")
check("ssl_verify_host off by default", (first.options or {}).ssl_verify_host == false)
check("ssl_verify_peer off by default", (first.options or {}).ssl_verify_peer == false)

print("\n[3] A successful test reads version, NVR and inventory")

check("Protect Version published", props["Protect Version"] == "6.2.83", props["Protect Version"])
check("NVR Name published", props["NVR Name"] == "Dream Machine", props["NVR Name"])
check("Cameras count with online split", props["Cameras"] == "2 (1 online)", props["Cameras"])
check("Sensors count", props["Sensors"] == "1 (1 online)", props["Sensors"])
check("Lights count", props["Lights"] == "0 (0 online)", props["Lights"])
check("Connection Status is Connected", props["Connection Status"] == "Connected", props["Connection Status"])
check("connected conditional is true", TC.UNIFI_PROTECT_CONNECTED() == true)
check("inventory persisted", type(store["protect_inventory"]) == "table")

-- ─── [4] Bindings ─────────────────────────────────────────────────────────────

print("\n[4] One provider CONTROL binding per camera, idempotent")

local function countBindings()
  local n = 0
  for _ in pairs(addedBindings) do
    n = n + 1
  end
  return n
end

check("two bindings created", countBindings() == 2, countBindings())
local sawFront, sawClass, sawProvider = false, true, true
for _, b in pairs(addedBindings) do
  if b.name == "Front Door" then
    sawFront = true
  end
  if b.class ~= "UNIFI_PROTECT_CAMERA" then
    sawClass = false
  end
  if b.type ~= "CONTROL" or b.provider ~= true then
    sawProvider = false
  end
end
check("binding carries the camera name", sawFront)
check("class is UNIFI_PROTECT_CAMERA", sawClass)
check("provider CONTROL bindings", sawProvider)

requests = {}
EC.SYNC_DEVICES()
check("re-sync creates no duplicate bindings", countBindings() == 2, countBindings())
check("re-sync polled the console", #requests == 4, #requests)

-- ─── [5] A vanished camera does not lose its binding ─────────────────────────

print("\n[5] A camera vanishing never deletes a binding by itself")

CAMERAS[2] = nil -- Driveway gone
EC.SYNC_DEVICES()
check("binding survives the vanish", countBindings() == 2, countBindings())
check(
  "status flags the stale binding",
  tostring(props["Connection Status"]):find("stale") ~= nil,
  props["Connection Status"]
)

EC.PRUNE_STALE_CAMERAS()
check("prune removes exactly the stale one", countBindings() == 1, countBindings())
check("one removal recorded", #removedBindings == 1, #removedBindings)

-- ─── [6] Failure modes name themselves ───────────────────────────────────────

print("\n[6] 401 blames the key; transport failure blames the network")

routes = { { match = "/v1/", ok = false, code = 401, body = "" } }
EC.TEST_CONNECTION()
check(
  "401 says check the API key",
  tostring(props["Connection Status"]):find("check the API key") ~= nil,
  props["Connection Status"]
)
check("connected conditional dropped", TC.UNIFI_PROTECT_CONNECTED() == false)

routes = { { match = "/v1/", ok = false, code = nil, error = "timeout" } }
EC.TEST_CONNECTION()
check(
  "transport failure says unreachable",
  tostring(props["Connection Status"]):find("unreachable") ~= nil,
  props["Connection Status"]
)

print("\n[7] A non-list camera body fails the sync instead of emptying it")

local before = props["Cameras"]
routes = {
  { match = "/v1/cameras", ok = true, code = 200, body = "<html>login</html>" },
  { match = "/v1/", ok = true, code = 200, body = {} },
}
EC.SYNC_DEVICES()
check("camera count untouched", props["Cameras"] == before, props["Cameras"])
check("sync reported failure", props["Connection Status"] ~= "Connected", props["Connection Status"])

-- ─── [8] TLS verification property is honored ────────────────────────────────

print("\n[8] Verify TLS On stops disabling verification")

routeHappyConsole()
Properties["Verify TLS Certificate"] = "On"
requests = {}
OnPropertyChanged("Verify TLS Certificate")
check("requests went out", #requests > 0, #requests)
check("ssl_verify_host not disabled", (requests[1].options or {}).ssl_verify_host == nil)
check("ssl_verify_peer not disabled", (requests[1].options or {}).ssl_verify_peer == nil)
Properties["Verify TLS Certificate"] = "Off"
OnPropertyChanged("Verify TLS Certificate")

-- ─── [9] Forgetting the key ──────────────────────────────────────────────────

print("\n[9] Forget API Key clears the credential and stops claiming health")

EC.FORGET_API_KEY()
check("key gone from persist", store["protect_api_key"] == nil)
check(
  "status back to not configured",
  tostring(props["Connection Status"]):find("Not configured") ~= nil,
  props["Connection Status"]
)
check("connected conditional false", TC.UNIFI_PROTECT_CONNECTED() == false)
check("bindings NOT touched by forget", countBindings() == 1, countBindings())

requests = {}
EC.SYNC_DEVICES()
check("sync without a key makes no requests", #requests == 0, #requests)

-- ─── [10] Address normalization survives dealer paste ────────────────────────

print("\n[10] Console Address accepts what dealers actually paste")

local Protect = require("unifi.protect")
check("bare IP", Protect.normalizeAddress("192.168.1.1") == "https://192.168.1.1")
check(
  "browser paste with path",
  Protect.normalizeAddress("https://192.168.1.1/protect/dashboard") == "https://192.168.1.1",
  Protect.normalizeAddress("https://192.168.1.1/protect/dashboard")
)
check("http upgraded to https", Protect.normalizeAddress("http://10.0.0.2") == "https://10.0.0.2")
check("whitespace trimmed", Protect.normalizeAddress("  udm.local  ") == "https://udm.local")
check("port preserved", Protect.normalizeAddress("udm.local:8443") == "https://udm.local:8443")
check("empty is empty", Protect.normalizeAddress("") == "")

-- ─── [11] Binding protocol: camera identity ──────────────────────────────────

print("\n[11] A child asking PROTECT_GET_CAMERA gets its camera back")

-- Reconfigure after [9]'s forget, and restore both cameras.
CAMERAS[2] = { id = "cam-drive", name = "Driveway", mac = "60223263A4D1", state = "DISCONNECTED" }
routeHappyConsole()
Properties["API Key"] = "secret-key-123"
OnPropertyChanged("API Key")
check("reconnected", props["Connection Status"] == "Connected", props["Connection Status"])
check("both bindings back", countBindings() == 2, countBindings())

-- Find cam-front's binding id from the captured AddDynamicBinding calls.
local frontBinding
for id, b in pairs(addedBindings) do
  if b.name == "Front Door" then
    frontBinding = id
  end
end
check("cam-front has a binding", frontBinding ~= nil)

proxySent = {}
ReceivedFromProxy(frontBinding, "PROTECT_GET_CAMERA", {})
local camReplies = proxySentTo(frontBinding, "PROTECT_CAMERA")
check("PROTECT_CAMERA reply on the same binding", #camReplies == 1, #camReplies)
local cam = (camReplies[1] or {}).params or {}
check("with the camera id", cam.id == "cam-front", cam.id)
check("its name", cam.name == "Front Door", cam.name)
check("its MAC", cam.mac == "60223263A4D0", cam.mac)
check("and the console host, port stripped", cam.console_host == "192.168.4.1", cam.console_host)

print("\n[12] PROTECT_GET_STREAMS reads what exists and enables what is missing")

routes = {
  -- Specific before generic: "/v1/cameras" is a prefix of this path.
  {
    match = "/v1/cameras/cam-front/rtsps-stream",
    method = "GET",
    ok = true,
    code = 200,
    body = { high = "rtsps://192.168.4.1:7441/HIGHTOKEN?enableSrtp" },
  },
  {
    match = "/v1/cameras/cam-front/rtsps-stream",
    method = "POST",
    ok = true,
    code = 200,
    body = {
      medium = "rtsps://192.168.4.1:7441/MEDTOKEN?enableSrtp",
      low = "rtsps://192.168.4.1:7441/LOWTOKEN?enableSrtp",
    },
  },
  { match = "/v1/cameras", ok = true, code = 200, body = CAMERAS },
}

requests = {}
proxySent = {}
ReceivedFromProxy(frontBinding, "PROTECT_GET_STREAMS", { KEY = "42" })

check("a GET then a POST went to the console", #requests == 2, #requests)
check("GET first", requests[1].method == "GET", requests[1].method)
check("POST second", requests[2].method == "POST", requests[2].method)
local posted = requests[2].data or {}
local askedQualities = table.concat(posted.qualities or {}, ",")
check("POST asks ONLY for the missing qualities", askedQualities == "medium,low", askedQualities)

local streamReplies = proxySentTo(frontBinding, "PROTECT_STREAMS")
check("PROTECT_STREAMS reply sent", #streamReplies == 1, #streamReplies)
local streams = (streamReplies[1] or {}).params or {}
check("echoing the key", streams.KEY == "42", streams.KEY)
check("union carries high from the GET", tostring(streams.high):find("HIGHTOKEN", 1, true) ~= nil, streams.high)
check("and medium from the POST", tostring(streams.medium):find("MEDTOKEN", 1, true) ~= nil, streams.medium)
check("and low from the POST", tostring(streams.low):find("LOWTOKEN", 1, true) ~= nil, streams.low)

print("\n[13] Failures over the binding name themselves too")

routes = { { match = "/rtsps-stream", ok = false, code = 401, body = "" } }
proxySent = {}
ReceivedFromProxy(frontBinding, "PROTECT_GET_STREAMS", { KEY = "43" })
local errors = proxySentTo(frontBinding, "PROTECT_STREAMS_ERROR")
check("PROTECT_STREAMS_ERROR sent", #errors == 1, #errors)
check("echoing the key", ((errors[1] or {}).params or {}).KEY == "43")
check(
  "with the key-shaped reason",
  tostring(((errors[1] or {}).params or {}).reason):find("API key", 1, true) ~= nil,
  ((errors[1] or {}).params or {}).reason
)

print("\n[14] Every sync pushes state to bound children")

routeHappyConsole()
CAMERAS[1].state = "DISCONNECTED" -- Front Door just went dark
proxySent = {}
EC.SYNC_DEVICES()
local statePushes = proxySentTo(frontBinding, "PROTECT_STATE")
check("PROTECT_STATE pushed to cam-front's binding", #statePushes == 1, #statePushes)
check(
  "carrying the new state",
  ((statePushes[1] or {}).params or {}).state == "DISCONNECTED",
  ((statePushes[1] or {}).params or {}).state
)
CAMERAS[1].state = "CONNECTED"

-- ─── [15] Live events socket ─────────────────────────────────────────────────

print("\n[15] The events socket routes camera events to bound children")

local ws = wsInstances[#wsInstances]
check("a socket exists after configuration", ws ~= nil)
check(
  "dialing the Integration events path over wss",
  tostring((ws or {}).url) == "wss://192.168.4.1/proxy/protect/integration/v1/subscribe/events",
  (ws or {}).url
)
local hasKeyHeader = false
for _, h in ipairs((ws or {}).headers or {}) do
  if h == "X-API-KEY: secret-key-123" then
    hasKeyHeader = true
  end
end
check("with the X-API-KEY header", hasKeyHeader)
check("and Start() called", ((ws or {}).started or 0) >= 1, (ws or {}).started)

proxySent = {}
ws.processMessage(
  ws,
  '{"type":"add","item":{"id":"e1","modelKey":"event","type":"motion","start":1000,"device":"cam-front"}}'
)
local motion = proxySentTo(frontBinding, "PROTECT_EVENT")
check("motion add forwarded to cam-front's binding", #motion == 1, #motion)
check("as kind=motion", ((motion[1] or {}).params or {}).kind == "motion")
check("phase=start", ((motion[1] or {}).params or {}).phase == "start")

proxySent = {}
ws.processMessage(
  ws,
  '{"type":"update","item":{"id":"e1","modelKey":"event","type":"motion","start":1000,"end":2000,"device":"cam-front"}}'
)
motion = proxySentTo(frontBinding, "PROTECT_EVENT")
check("the closing update forwards phase=end", ((motion[1] or {}).params or {}).phase == "end")

proxySent = {}
ws.processMessage(
  ws,
  '{"type":"add","item":{"id":"e2","modelKey":"event","type":"smartDetectZone","start":3000,"device":"cam-front","smartDetectTypes":["person","vehicle"]}}'
)
local smart = proxySentTo(frontBinding, "PROTECT_EVENT")
check("smart detection forwarded", #smart == 1, #smart)
check("kind=smart", ((smart[1] or {}).params or {}).kind == "smart")
check("types joined", ((smart[1] or {}).params or {}).types == "person,vehicle", ((smart[1] or {}).params or {}).types)

proxySent = {}
ws.processMessage(
  ws,
  '{"type":"add","item":{"id":"e3","modelKey":"event","type":"ring","start":4000,"device":"cam-front"}}'
)
check("ring forwarded as kind=ring", (proxySentTo(frontBinding, "PROTECT_EVENT")[1].params or {}).kind == "ring")

proxySent = {}
ws.processMessage(
  ws,
  '{"type":"add","item":{"id":"e4","modelKey":"event","type":"motion","start":5000,"device":"cam-unknown"}}'
)
check("an event for an unbound camera goes nowhere", #proxySent == 0, #proxySent)

local okFrame = pcall(function()
  ws.processMessage(ws, "not json at all {{{")
end)
check("a malformed frame does not throw", okFrame)

print("\n[16] Forgetting the key tears the socket down")

EC.FORGET_API_KEY()
check("socket deleted", ws.deleted == true)

-- ─── [17] The device path: SendToDevice twins ────────────────────────────────

print("\n[17] Requests over SendToDevice answer over SendToDevice")

-- Reconfigure, and teach Director that device 777 is bound to cam-front's
-- binding. From here on the parent PREFERS the device path.
routeHappyConsole()
Properties["API Key"] = "secret-key-123"
OnPropertyChanged("API Key")

local deviceSent = {}
function C4:SendToDevice(deviceId, command, params)
  table.insert(deviceSent, { device = deviceId, command = command, params = params })
end
local function deviceSentTo(deviceId, command)
  local hits = {}
  for _, s in ipairs(deviceSent) do
    if s.device == deviceId and s.command == command then
      table.insert(hits, s)
    end
  end
  return hits
end
function C4:GetBoundConsumerDevices(_, bindingId)
  if bindingId == frontBinding then
    return { [777] = "UniFi Protect Camera" }
  end
  return nil
end

EC.PROTECT_GET_CAMERA({ requester = "777" })
local devCam = deviceSentTo(777, "PROTECT_CAMERA")
check("identity answered over SendToDevice", #devCam == 1, #devCam)
check("with the right camera", ((devCam[1] or {}).params or {}).id == "cam-front", ((devCam[1] or {}).params or {}).id)

EC.PROTECT_GET_CAMERA({ requester = "888" })
check("an unbound requester gets no reply", #deviceSentTo(888, "PROTECT_CAMERA") == 0)

routes = {
  {
    match = "/v1/cameras/cam-front/rtsps-stream",
    method = "GET",
    ok = true,
    code = 200,
    body = { high = "rtsps://192.168.4.1:7441/HIGHTOKEN?enableSrtp" },
  },
  { match = "/v1/cameras", ok = true, code = 200, body = CAMERAS },
}
EC.PROTECT_GET_STREAMS({ requester = "777", KEY = "9" })
local devStreams = deviceSentTo(777, "PROTECT_STREAMS")
check("streams answered over SendToDevice", #devStreams == 1, #devStreams)
check("echoing the key", ((devStreams[1] or {}).params or {}).KEY == "9")

print("\n[18] Pushes prefer the device path once a child is known")

routeHappyConsole()
proxySent = {}
deviceSent = {}
EC.SYNC_DEVICES()
check("PROTECT_STATE went to device 777", #deviceSentTo(777, "PROTECT_STATE") == 1, #deviceSentTo(777, "PROTECT_STATE"))
check(
  "and NOT over cam-front's binding (no double delivery)",
  #proxySentTo(frontBinding, "PROTECT_STATE") == 0,
  #proxySentTo(frontBinding, "PROTECT_STATE")
)

local ws2 = wsInstances[#wsInstances]
deviceSent = {}
proxySent = {}
ws2.processMessage(
  ws2,
  '{"type":"add","item":{"id":"e9","modelKey":"event","type":"motion","start":9000,"device":"cam-front"}}'
)
check(
  "events prefer the device path too",
  #deviceSentTo(777, "PROTECT_EVENT") == 1,
  #deviceSentTo(777, "PROTECT_EVENT")
)
check("without a binding duplicate", #proxySentTo(frontBinding, "PROTECT_EVENT") == 0)

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
