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

--- PATCH against the Integration API.
--- @param path string Path under the API prefix.
--- @param body table JSON body.
--- @return Deferred response
function Protect:patch(path, body)
  log:trace("Protect:patch(%s)", path)
  return http:patch(self.baseUrl .. API_PREFIX .. path, body, self:_headers(), self:_options())
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

--- A snapshot JPEG from a camera. Resolves with the raw image bytes in
--- `body` (url.lua leaves non-JSON bodies as strings). This request carries
--- the X-API-KEY header, which is exactly why a Navigator can never make it
--- itself — the Gateway's snapshot relay exists to stand in the middle.
--- @param cameraId string The camera's id.
--- @param highQuality boolean|nil True forces 1080p or better.
function Protect:getSnapshot(cameraId, highQuality)
  local query = highQuality and "?highQuality=true" or ""
  return self:get("/v1/cameras/" .. cameraId .. "/snapshot" .. query)
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

-- ─── Device settings (PATCH) ──────────────────────────────────────────────────
--
-- Every control this suite offers goes through PATCH bodies documented in
-- docs/v7-shapes-reference.txt. One method per intent, so call sites read as
-- intents and the JSON shapes live in exactly one place.

--- Doorbell LCD message. messageType: CUSTOM_MESSAGE | DO_NOT_DISTURB |
--- LEAVE_PACKAGE_AT_DOOR. resetAtMs nil = no scheduled reset; a unix-ms
--- timestamp restores the default afterwards.
function Protect:setLcdMessage(cameraId, messageType, text, resetAtMs)
  local body = { lcdMessage = { type = messageType } }
  if text ~= nil then
    body.lcdMessage.text = text
  end
  if resetAtMs ~= nil then
    body.lcdMessage.resetAt = resetAtMs
  end
  return self:patch("/v1/cameras/" .. cameraId, body)
end

--- Resets the doorbell display to its default.
function Protect:resetLcdMessage(cameraId)
  return self:patch("/v1/cameras/" .. cameraId, { lcdMessage = { resetAt = 0, type = "CUSTOM_MESSAGE", text = "" } })
end

function Protect:setCameraLed(cameraId, enabled)
  return self:patch("/v1/cameras/" .. cameraId, { ledSettings = { isEnabled = enabled and true or false } })
end

function Protect:setMicVolume(cameraId, volume)
  return self:patch("/v1/cameras/" .. cameraId, { micVolume = volume })
end

function Protect:setHdrType(cameraId, hdrType)
  return self:patch("/v1/cameras/" .. cameraId, { hdrType = hdrType })
end

function Protect:setVideoMode(cameraId, videoMode)
  return self:patch("/v1/cameras/" .. cameraId, { videoMode = videoMode })
end

-- ─── Lights ───────────────────────────────────────────────────────────────────

--- Forces the floodlight's main LED on or off.
function Protect:setLightForce(lightId, on)
  return self:patch("/v1/lights/" .. lightId, { isLightForceEnabled = on and true or false })
end

--- Sets the floodlight's activation mode: always | motion | off, optionally
--- with enableAt fulltime | dark.
function Protect:setLightMode(lightId, mode, enableAt)
  local settings = { mode = mode }
  if enableAt ~= nil then
    settings.enableAt = enableAt
  end
  return self:patch("/v1/lights/" .. lightId, { lightModeSettings = settings })
end

-- ─── Viewers / live views ─────────────────────────────────────────────────────

function Protect:getViewers()
  return self:get("/v1/viewers")
end

function Protect:getLiveviews()
  return self:get("/v1/liveviews")
end

--- Points a viewer (Viewport) at a live view.
function Protect:setViewerLiveview(viewerId, liveviewId)
  return self:patch("/v1/viewers/" .. viewerId, { liveview = liveviewId })
end

-- ─── Alarm (arm profiles) ─────────────────────────────────────────────────────
--
-- The Protect alarm STATE is read from /v1/nvrs: armMode, armProfileId,
-- armedAt, breachDetectedAt, breachEventCount, willBeArmedAt.

function Protect:getArmProfiles()
  return self:get("/v1/arm-profiles")
end

--- Selects the current arm profile (does not arm by itself).
function Protect:setArmProfile(armProfileId)
  return self:patch("/v1/arm-profiles/settings", { armProfileId = armProfileId })
end

--- Arms using the currently selected profile.
function Protect:enableArm()
  return self:post("/v1/arm-profiles/enable")
end

function Protect:disableArm()
  return self:post("/v1/arm-profiles/disable")
end

-- ─── Sirens / relays / alarm hubs ─────────────────────────────────────────────
--
-- SECURITY ACTIONS: callers must never retry these on timeout — a lost
-- response is not a lost command, and a siren fired twice is an incident.

function Protect:getSirens()
  return self:get("/v1/sirens")
end

--- Sounds a siren. Duration must be one of the console's accepted steps
--- (5/10/20/30 s); snapping an arbitrary value to a step is the caller's job.
function Protect:playSiren(sirenId, durationSeconds)
  local body = nil
  if durationSeconds ~= nil then
    body = { duration = durationSeconds }
  end
  return self:post("/v1/sirens/" .. sirenId .. "/play", body)
end

function Protect:stopSiren(sirenId)
  return self:post("/v1/sirens/" .. sirenId .. "/stop")
end

function Protect:testSiren(sirenId, volume)
  local body = nil
  if volume ~= nil then
    body = { volume = volume }
  end
  return self:post("/v1/sirens/" .. sirenId .. "/test-sound", body)
end

function Protect:getRelays()
  return self:get("/v1/relays")
end

--- Activates a relay output. state "on"|"off"; nil toggles. pulseMs > 0
--- auto-offs after that many milliseconds (only meaningful with "on").
function Protect:activateRelayOutput(relayId, outputId, state, pulseMs)
  local body = {}
  if state ~= nil then
    body.state = state
  end
  if pulseMs ~= nil then
    body.pulseDuration = pulseMs
  end
  if next(body) == nil then
    body = nil
  end
  return self:post("/v1/relays/" .. relayId .. "/outputs/" .. outputId .. "/activate", body)
end

function Protect:getAlarmHubs()
  return self:get("/v1/alarm-hubs")
end

--- Triggers an alarm-hub output. enable true/false; nil toggles.
function Protect:triggerAlarmHubOutput(hubId, outputId, enable, delayMs, durationMs)
  local body = {}
  if enable ~= nil then
    body.enable = enable and true or false
  end
  if delayMs ~= nil then
    body.delay = delayMs
  end
  if durationMs ~= nil then
    body.duration = durationMs
  end
  if next(body) == nil then
    body = nil
  end
  return self:post("/v1/alarm-hubs/" .. hubId .. "/outputs/" .. outputId .. "/trigger", body)
end

-- ─── Identity (ULP users) ─────────────────────────────────────────────────────

--- The identity store behind fingerprint/NFC events: id → first/last/full
--- name + ACTIVE/DEACTIVATED status.
function Protect:getUlpUsers()
  return self:get("/v1/ulp-users")
end

-- ─── Alarm Manager ────────────────────────────────────────────────────────────

--- Fires a Protect Alarm Manager webhook trigger — Control4 programming
--- driving Protect-side automations.
function Protect:triggerAlarmWebhook(triggerId)
  return self:post("/v1/alarm-manager/webhook/" .. triggerId)
end

return Protect
