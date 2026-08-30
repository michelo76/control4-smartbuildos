--- Bond Local API client (Olibra Bond Bridge / Smart by Bond).
---
--- Speaks the documented Local HTTP API (docs-local.appbond.com, spec pinned
--- at docs/bond-openapi-v3.0.0.json):
---
---     http://<bond>/v2/...
---     header: BOND-Token (read from the Bond Home app under
---     Device → Settings → Advanced → Local Token, or served by
---     GET /v2/token for 10 minutes after a power cycle)
---
--- Deliberately plain HTTP: the Bond does not serve TLS at all — the vendor's
--- documented position is that the Wi-Fi password is the perimeter. There is
--- no https fallback to try; a pasted https:// address is a typo.
---
--- One client instance fronts ONE Bond unit. A Bond Bridge fronts many
--- devices; a Smart by Bond appliance is its own host with (usually) a single
--- device. Both look identical from here, which is the point of the module.
---
--- Every request returns the Deferred that `lib.http` produces. Its contract:
--- it REJECTS on any non-2xx as well as on transport failure, so a rejection
--- with a numeric `code` is the Bond SPEAKING (401 = missing/wrong token,
--- 404 = stale device id) and only a rejection without one is the Bond
--- unreachable. Callers that collapse the two report a bad token as a network
--- outage and send the dealer to the wrong place.
---
--- This module also carries the BPUP (Bond Push UDP Protocol) FRAME PARSER —
--- a pure function, so the push pipeline is testable without sockets. The
--- socket itself lives in the gateway driver: transport is DriverWorks'
--- business, interpreting datagrams is the API's.

local http = require("lib.http")
local log = require("lib.logging")

JSON = JSON or require("JSON")

--- @class Bond
--- @field baseUrl string Normalized `http://host[:port]`, no trailing slash.
--- @field token string The BOND-Token value ("" until configured).
local Bond = {}
Bond.__index = Bond

--- Normalizes what a dealer pastes into the Bond Address property.
---
--- Accepts a bare host (`192.168.1.50`), a scheme-carrying origin, or a full
--- URL copied from a browser. Anything after the origin is cut. A pasted
--- https:// is downgraded to http:// — the Bond serves no TLS, and leaving
--- the scheme would produce a connection failure indistinguishable from a
--- wrong address.
--- @param address string|nil The raw property value.
--- @return string baseUrl `http://host[:port]`, or "" when there is nothing usable.
function Bond.normalizeAddress(address)
  local s = tostring(address or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if s == "" then
    return ""
  end
  if not s:find("^https?://") then
    s = "http://" .. s
  end
  local origin = s:match("^(https?://[^/]+)")
  if origin == nil then
    return ""
  end
  origin = origin:gsub("^https://", "http://")
  return origin
end

--- Decodes a response body that may or may not already be a table.
---
--- `drivers-common-public.global.url` JSON-decodes the body itself when the
--- response carries `Content-Type: application/json` — but only then. Handle
--- both shapes rather than trusting the header.
--- @param body string|table|nil The response body.
--- @return table|nil decoded The decoded table, or nil if the body is not JSON.
function Bond.decodeBody(body)
  if type(body) == "table" then
    return body
  end
  if type(body) ~= "string" or body == "" then
    return nil
  end
  local ok, decoded = pcall(function()
    return JSON:decode(body)
  end)
  if ok and type(decoded) == "table" then
    return decoded
  end
  return nil
end

--- Extracts child ids from a Bond enumeration document (`/v2/devices`,
--- `/v2/groups`, …). Every branch of the Bond's hash tree carries reserved
--- bookkeeping keys — `"_"` (the subtree hash), `"__"` variants and
--- `"__modified"` timestamps — alongside the actual child ids, so "list the
--- devices" is "every key that is not reserved". Reserved keys all start
--- with an underscore; real ids are hex strings and never do.
--- @param tree table|nil The decoded enumeration body.
--- @return string[] ids Sorted child ids (sorted so re-syncs are deterministic).
function Bond.idsFromTree(tree)
  local ids = {}
  if type(tree) ~= "table" then
    return ids
  end
  for key in pairs(tree) do
    if type(key) == "string" and key:sub(1, 1) ~= "_" then
      table.insert(ids, key)
    end
  end
  table.sort(ids)
  return ids
end

--- Parses one BPUP datagram (everything up to the terminating newline).
---
--- Returns nil for anything that is not a JSON object — BPUP is a Beta
--- protocol and the gateway treats an unparseable datagram as noise, never
--- as an error worth surfacing.
---
--- Shapes returned, checked in this order:
---   { error = { id, msg }, bondId }        — client-specific error frame
---   { ack = true, bondId }                 — keep-alive acknowledgement
---   { bondId, deviceId, state, status }    — a devices/<id>/state update
---   { bondId, topic, body, status }        — any other topic
--- @param datagram string|nil One newline-terminated (or bare) JSON line.
--- @return table|nil frame
function Bond.parseBpup(datagram)
  if type(datagram) ~= "string" then
    return nil
  end
  local line = datagram:match("^[^\n]*")
  if line == nil or line == "" then
    return nil
  end
  local ok, decoded = pcall(function()
    return JSON:decode(line)
  end)
  if not ok or type(decoded) ~= "table" then
    return nil
  end
  if decoded.err_id ~= nil then
    return {
      error = { id = decoded.err_id, msg = decoded.err_msg },
      bondId = decoded.B,
    }
  end
  if decoded.t == nil then
    -- The subscription ack is just {"B":"<bondid>"}.
    if decoded.B ~= nil then
      return { ack = true, bondId = decoded.B }
    end
    return nil
  end
  local deviceId = tostring(decoded.t):match("^devices/([^/]+)/state$")
  if deviceId ~= nil then
    return {
      bondId = decoded.B,
      deviceId = deviceId,
      state = decoded.b,
      status = decoded.s,
    }
  end
  return {
    bondId = decoded.B,
    topic = decoded.t,
    body = decoded.b,
    status = decoded.s,
  }
end

--- Creates an unconfigured client. `configure` must be called before use.
--- @return Bond bond A new instance.
function Bond:new()
  local instance = setmetatable({}, self)
  instance.baseUrl = ""
  instance.token = ""
  return instance
end

--- (Re)configures the client. Cheap and idempotent — the drivers call this on
--- every relevant property change rather than tracking staleness.
--- @param address string|nil The Bond address as typed by the dealer.
--- @param token string|nil The local token.
function Bond:configure(address, token)
  self.baseUrl = Bond.normalizeAddress(address)
  self.token = tostring(token or "")
end

--- Whether the client has everything an authenticated request needs.
--- @return boolean configured
function Bond:isConfigured()
  return self.baseUrl ~= "" and self.token ~= ""
end

--- Whether the client at least knows where the Bond is (version probe and
--- token retrieval work without a token).
--- @return boolean addressed
function Bond:hasAddress()
  return self.baseUrl ~= ""
end

--- Request headers. The token header is included only when a token is set:
--- `/sys/version` and `/token` are the two unauthenticated endpoints, and
--- sending an empty BOND-Token there costs nothing but sending one anywhere
--- else would turn "no token yet" into a confusing 401 body difference.
--- @private
--- @return table<string, string> headers
function Bond:_headers()
  local headers = {
    ["Accept"] = "application/json",
  }
  if self.token ~= "" then
    headers["BOND-Token"] = self.token
  end
  return headers
end

--- Request options. Bond actions block up to 7 seconds by contract while the
--- RF transmission runs; 10 gives headroom without letting a dead host hang
--- a sync for the lib default of 30.
--- @private
--- @return table<string, any> options
function Bond:_options()
  return { timeout = 10 }
end

--- GET against the Bond.
--- @param path string Path including the /v2 prefix, e.g. "/v2/devices".
--- @return Deferred response
function Bond:get(path)
  log:trace("Bond:get(%s)", path)
  return http:get(self.baseUrl .. path, self:_headers(), self:_options())
end

--- PUT against the Bond.
--- @param path string Path including the /v2 prefix.
--- @param body table|string|nil Table = JSON-encoded by url.lua; string sent as-is.
--- @return Deferred response
function Bond:put(path, body)
  log:trace("Bond:put(%s)", path)
  local headers = self:_headers()
  if type(body) == "string" then
    -- url.lua only sets Content-Type when IT does the encoding.
    headers["Content-Type"] = "application/json"
  end
  return http:put(self.baseUrl .. path, body, headers, self:_options())
end

--- PATCH against the Bond.
--- @param path string Path including the /v2 prefix.
--- @param body table JSON body.
--- @return Deferred response
function Bond:patch(path, body)
  log:trace("Bond:patch(%s)", path)
  return http:patch(self.baseUrl .. path, body, self:_headers(), self:_options())
end

-- ─── System ───────────────────────────────────────────────────────────────────

--- Version/identity probe: `{ bondid, target, fw_ver, make, model, … }`.
--- Works WITHOUT a token, which makes it the address-validation call — a
--- reply proves the host is a Bond before the dealer goes hunting for the
--- token, and `bondid` anchors BPUP frame filtering later.
function Bond:getVersion()
  return self:get("/v2/sys/version")
end

--- Token endpoint. Normally answers `{"locked": 1}`; answers
--- `{"token": "…"}` for 10 minutes after a power cycle (or after the user
--- unlocks it from the app). The gateway polls this as a convenience path so
--- a dealer can pair by power-cycling the Bond instead of typing the token.
function Bond:getToken()
  return self:get("/v2/token")
end

--- Unlocks (or re-locks) the token endpoint with the Bond's PIN — the
--- "PIN on the back of the bridge" pairing path, for dealers without the
--- homeowner's app. Flow: PATCH {locked=0, pin} → GET /v2/token → PATCH
--- {locked=1}.
--- @param locked number 0 to unlock, 1 to re-lock.
--- @param pin string|nil The Bond's PIN (required to unlock on PIN-bearing units).
function Bond:patchToken(locked, pin)
  local body = { locked = locked }
  if pin ~= nil and pin ~= "" then
    body.pin = tostring(pin)
  end
  return self:patch("/v2/token", body)
end

-- ─── Scenes ───────────────────────────────────────────────────────────────────

--- The scene enumeration, same hash-tree shape as /v2/devices.
function Bond:getScenes()
  return self:get("/v2/scenes")
end

--- One scene: `{ name, types, locations, actors, … }`.
--- @param sceneId string The scene's id.
function Bond:getScene(sceneId)
  return self:get("/v2/scenes/" .. sceneId)
end

--- Runs a scene (the app's scenes, executed on the Bond itself).
--- @param sceneId string The scene's id.
function Bond:runScene(sceneId)
  log:trace("Bond:runScene(%s)", sceneId)
  return self:put("/v2/scenes/" .. sceneId .. "/run", "{}")
end

-- ─── Sidekicks ────────────────────────────────────────────────────────────────
--
-- The /v2/sidekicks enumeration hosts TWO kinds of hardware: Sidekick
-- keypads (entries with a `keys` count; presses arrive push-only over BPUP
-- on `sidekicks/<id>/keystream`) and Breeze weather sensors (entries with a
-- state document of measurements). Callers tell them apart by shape.

--- The sidekick enumeration, same hash-tree shape as /v2/devices.
--- Older firmware without Sidekick support 404s — treat as "none".
function Bond:getSidekicks()
  return self:get("/v2/sidekicks")
end

--- One sidekick: `{ name, location, keys, chans, battery, signal, model, … }`.
--- @param sidekickId string The sidekick's id.
function Bond:getSidekick(sidekickId)
  return self:get("/v2/sidekicks/" .. sidekickId)
end

--- Opens the learn window so a new Sidekick can be paired by pressing a
--- key on it near the Bond.
--- @param windowMs number|nil Window length in ms (60s when nil — the spec's example).
function Bond:openSidekickLearn(windowMs)
  return self:patch("/v2/sidekicks/_learn", { learn_window_ms = windowMs or 60000 })
end

-- ─── Devices ──────────────────────────────────────────────────────────────────

--- The device enumeration: `{ "_": "<hash>", "<id>": { "_": "<hash>" }, … }`.
--- The root `"_"` changes when ANY device's anything changes — the cheapest
--- possible "did the world move" poll.
function Bond:getDevices()
  return self:get("/v2/devices")
end

--- One device's identity: `{ name, type, subtype?, location, actions[],
--- state = {_}, properties = {_}, … }`. Functionality decisions belong to
--- `actions[]`; `type` is cosmetic by the vendor's own guidance.
--- @param deviceId string The device's id.
function Bond:getDevice(deviceId)
  return self:get("/v2/devices/" .. deviceId)
end

--- One device's state document (power/speed/light/position/… per feature).
--- @param deviceId string The device's id.
function Bond:getDeviceState(deviceId)
  return self:get("/v2/devices/" .. deviceId .. "/state")
end

--- One device's properties document (max_speed/open_raises/feature toggles…).
--- @param deviceId string The device's id.
function Bond:getDeviceProperties(deviceId)
  return self:get("/v2/devices/" .. deviceId .. "/properties")
end

--- Executes a device action.
---
--- `argument` may be nil (TurnOn), a number (SetSpeed), or a table (SetBreeze
--- takes `[mode, mean, var]`, SetHSV takes `{h, s, v}`). The no-argument case
--- sends a literal `"{}"` — an empty Lua table would leave url.lua's encoder
--- free to emit `[]`, and the spec's examples all send an object.
---
--- The Bond blocks until the RF transmission ran (≤7s by contract), and the
--- 200 means "transmitted", not "the appliance obeyed" — RF is one-way for
--- most devices, so state is the Bond's ASSUMPTION either way. Callers should
--- re-read state (or wait for the BPUP echo) rather than trusting silence.
--- @param deviceId string The device's id.
--- @param action string Action name exactly as listed in the device's `actions[]`.
--- @param argument any|nil The action argument, if the action takes one.
--- @return Deferred response
function Bond:action(deviceId, action, argument)
  log:trace("Bond:action(%s, %s)", deviceId, action)
  local body
  if argument == nil then
    body = "{}"
  else
    body = { argument = argument }
  end
  return self:put("/v2/devices/" .. deviceId .. "/actions/" .. action, body)
end

return Bond
