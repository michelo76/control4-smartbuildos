--- UniFi Protect Integration API client.
---
--- Speaks the OFFICIAL Protect Integration API (Protect 5.3+):
---
---     https://<console>/proxy/protect/integration/v1/...
---     header: X-API-KEY (created in UniFi OS → Settings → Control Plane →
---     Integrations, by an administrator)
---
--- and nothing else. The unofficial `/proxy/protect/api/` surface (cookie
--- auth, bootstrap, binary-framed websocket) is deliberately not here: it is
--- re-broken by Protect releases, and everything the drivers need so far is on
--- the documented surface. If a gap ever forces the unofficial API in, it goes
--- in a separate module behind its own property, not in this one.
---
--- Shared between the gateway (parent) driver and the per-camera child driver,
--- which is why it is a module and not a block of functions in driver.lua.
---
--- Every request returns the Deferred that `lib.http` produces. Remember its
--- contract: it REJECTS on any non-2xx as well as on transport failure, so a
--- rejection with a numeric `code` is the console SPEAKING (401 = bad key),
--- and only a rejection without one is the console unreachable. Callers that
--- collapse the two report a revoked key as a network outage.

local http = require("lib.http")
local log = require("lib.logging")

JSON = JSON or require("JSON")

--- Path prefix UniFi OS mounts the Protect Integration API under. The OpenAPI
--- spec's own `servers` entry is `/integration`; the `/proxy/protect` part is
--- UniFi OS routing to the Protect application.
--- @type string
local API_PREFIX = "/proxy/protect/integration"

--- Stream quality labels the rtsps-stream endpoints accept.
--- @type string[]
local QUALITIES = { "high", "medium", "low", "package" }

--- @class Protect
--- @field baseUrl string Normalized `https://host[:port]` of the console, no trailing slash.
--- @field apiKey string The X-API-KEY value.
--- @field verifyTls boolean Whether to verify the console's TLS certificate.
local Protect = {}
Protect.__index = Protect

--- Normalizes what a dealer pastes into a Console Address property.
---
--- Accepts a bare host (`192.168.1.1`), a scheme-carrying origin, or a full
--- URL copied out of a browser's address bar mid-session
--- (`https://192.168.1.1/protect/dashboard`) — the last one being what a
--- paste-from-the-browser actually looks like. Anything after the origin is
--- the browser's business, not the API's, so it is cut.
--- @param address string|nil The raw property value.
--- @return string baseUrl `https://host[:port]`, or "" when there is nothing usable.
function Protect.normalizeAddress(address)
  local s = tostring(address or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if s == "" then
    return ""
  end
  if not s:find("^https?://") then
    s = "https://" .. s
  end
  -- Keep scheme://host[:port], drop any path, query or trailing slash.
  local origin = s:match("^(https?://[^/]+)")
  if origin == nil then
    return ""
  end
  -- The console only serves the API over TLS; a pasted http:// is a typo for
  -- https://, not a request for cleartext.
  origin = origin:gsub("^http://", "https://")
  return origin
end

--- Decodes a response body that may or may not already be a table.
---
--- `drivers-common-public.global.url` JSON-decodes the body itself when the
--- response carries `Content-Type: application/json` — but only then. A proxy
--- or an error page can hand back JSON without the header (or non-JSON with
--- it), so the body arrives as EITHER a table or a string depending on the
--- console's mood. Handle both rather than trusting the header.
--- @param body string|table|nil The response body.
--- @return table|nil decoded The decoded table, or nil if the body is not JSON.
function Protect.decodeBody(body)
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

--- Creates an unconfigured client. `configure` must be called before use.
--- @return Protect protect A new instance.
function Protect:new()
  local instance = setmetatable({}, self)
  instance.baseUrl = ""
  instance.apiKey = ""
  instance.verifyTls = false
  return instance
end

--- (Re)configures the client. Cheap and idempotent — the drivers call this on
--- every relevant property change rather than tracking staleness.
--- @param address string|nil The console address as typed by the dealer.
--- @param apiKey string|nil The API key.
--- @param verifyTls boolean|nil Whether to verify the console's TLS certificate.
function Protect:configure(address, apiKey, verifyTls)
  self.baseUrl = Protect.normalizeAddress(address)
  self.apiKey = tostring(apiKey or "")
  self.verifyTls = verifyTls and true or false
end

--- Whether the client has everything a request needs.
--- @return boolean configured
function Protect:isConfigured()
  return self.baseUrl ~= "" and self.apiKey ~= ""
end

--- Request headers.
--- @private
--- @return table<string, string> headers
function Protect:_headers()
  return {
    ["X-API-KEY"] = self.apiKey,
    ["Accept"] = "application/json",
  }
end

--- Request options.
---
--- A console fresh out of the box presents a self-signed certificate, so
--- verification is OFF unless the dealer turned the Verify TLS property on
--- (which they should, once the console has a proper cert — UniFi remote
--- access hostnames carry valid ones).
--- @private
--- @return table<string, any> options
function Protect:_options()
  local options = { timeout = 15 }
  if not self.verifyTls then
    options.ssl_verify_host = false
    options.ssl_verify_peer = false
  end
  return options
end

--- GET against the Integration API.
--- @param path string Path under the API prefix, e.g. "/v1/cameras".
--- @return Deferred response
function Protect:get(path)
  log:trace("Protect:get(%s)", path)
  return http:get(self.baseUrl .. API_PREFIX .. path, self:_headers(), self:_options())
end

--- POST against the Integration API.
--- @param path string Path under the API prefix.
--- @param body table|nil JSON body. `lib.http` → url.lua encodes a table and sets Content-Type.
--- @return Deferred response
function Protect:post(path, body)
  log:trace("Protect:post(%s)", path)
  return http:post(self.baseUrl .. API_PREFIX .. path, body, self:_headers(), self:_options())
end

--- DELETE against the Integration API.
--- @param path string Path under the API prefix.
--- @return Deferred response
function Protect:delete(path)
  log:trace("Protect:delete(%s)", path)
  return http:delete(self.baseUrl .. API_PREFIX .. path, self:_headers(), self:_options())
end

-- ─── Info ─────────────────────────────────────────────────────────────────────

--- Application info: `{ applicationVersion }`. The cheapest authenticated call
--- there is, which makes it the connection test.
function Protect:getInfo()
  return self:get("/v1/meta/info")
end

--- NVR details: `{ id, modelKey, name, doorbellSettings }`.
function Protect:getNvr()
  return self:get("/v1/nvrs")
end

-- ─── Inventory ────────────────────────────────────────────────────────────────
--
-- What the camera list does and does NOT carry (measured from the published
-- OpenAPI spec, not assumed): each item has id, modelKey, state
-- (CONNECTED/CONNECTING/DISCONNECTED), name, mac, mic/OSD/LED/LCD settings,
-- videoMode, hdrType, featureFlags{hasMic, hasSpeaker, hasLedStatus, hasHdr,
-- smartDetectTypes, ...} and smartDetectSettings. There is NO model name, NO
-- resolution list, NO channel list, NO PTZ flag, NO doorbell flag, and NO
-- stream URLs — streams are one extra call per camera.

function Protect:getCameras()
  return self:get("/v1/cameras")
end

function Protect:getLights()
  return self:get("/v1/lights")
end

function Protect:getSensors()
  return self:get("/v1/sensors")
end

function Protect:getChimes()
  return self:get("/v1/chimes")
end

-- ─── Streams ──────────────────────────────────────────────────────────────────

--- RTSPS stream URLs that already exist for a camera.
--- Resolves with up to `{ high, medium, low, package }`, each a
--- `rtsps://<console>:7441/<token>?enableSrtp` URL or null.
--- @param cameraId string The camera's id.
function Protect:getRtspsStreams(cameraId)
  return self:get("/v1/cameras/" .. cameraId .. "/rtsps-stream")
end

--- Creates (enables) RTSPS streams for the given qualities. This is the call
--- that spares the dealer clicking through Protect per camera.
--- @param cameraId string The camera's id.
--- @param qualities string[]|nil Quality labels; defaults to every quality.
function Protect:createRtspsStreams(cameraId, qualities)
  return self:post("/v1/cameras/" .. cameraId .. "/rtsps-stream", {
    qualities = qualities or QUALITIES,
  })
end

--- Revokes a camera's RTSPS streams.
--- @param cameraId string The camera's id.
function Protect:deleteRtspsStreams(cameraId)
  return self:delete("/v1/cameras/" .. cameraId .. "/rtsps-stream")
end

-- ─── PTZ ──────────────────────────────────────────────────────────────────────
--
-- The official API does presets and patrols ONLY — there is no continuous
-- pan/tilt/zoom on this surface.

--- Moves a PTZ camera to a preset slot.
--- @param cameraId string The camera's id.
--- @param slot number|string The preset slot.
function Protect:gotoPtzPreset(cameraId, slot)
  return self:post("/v1/cameras/" .. cameraId .. "/ptz/goto/" .. tostring(slot))
end

--- Starts a PTZ patrol.
--- @param cameraId string The camera's id.
--- @param slot number|string The patrol slot.
function Protect:startPtzPatrol(cameraId, slot)
  return self:post("/v1/cameras/" .. cameraId .. "/ptz/patrol/start/" .. tostring(slot))
end

--- Stops the active PTZ patrol.
--- @param cameraId string The camera's id.
function Protect:stopPtzPatrol(cameraId)
  return self:post("/v1/cameras/" .. cameraId .. "/ptz/patrol/stop")
end

return Protect
