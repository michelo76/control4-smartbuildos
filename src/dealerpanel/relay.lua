--- Dealer Settings — LAN relay router and PIN gate (pure).
---
--- Same posture as Atmosphere's relay (whose parser and renderer this
--- reuses): the driver listens on a controller port, the page fetches plain
--- LAN HTTP, the minted token rides the web_view_url query. On top of the
--- token, WRITES need the Dealer PIN:
---
---   • No Dealer PIN configured → the panel is READ-ONLY (every write is
---     refused with `pin_not_configured`). A page that can change a home's
---     settings with no secret at all is not shipped.
---   • A wrong PIN is counted; after `max_attempts` wrong PINs the gate
---     LOCKS for `lock_seconds` (every write refused `locked`, a Composer
---     event fires once). A correct PIN resets the count.
---   • The PIN is never echoed, logged or placed in a response.
---
---     GET  /ping                  -> {"ok":true}
---     GET  /app                   -> the page (tokenless; it ships in the c4z)
---     GET  /state?k=<token>       -> settings document
---     POST /verify?k=<token>      -> {"pin":"…"} -> {"ok":true|false,…}
---     POST /set?k=<token>         -> {"name"|"slot", "value", "pin"} -> result

local uirelay = require("atmosphere.uirelay")

local M = {}

M.parse = uirelay.parse
M.render = uirelay.render

M.DEFAULTS = { max_attempts = 5, lock_seconds = 60 }

local Gate = {}
Gate.__index = Gate

--- @param opts table { now = fun():number, max_attempts?, lock_seconds? }
function M.newGate(opts)
  opts = opts or {}
  local self = setmetatable({}, Gate)
  self.now = opts.now or os.time
  self.maxAttempts = opts.max_attempts or M.DEFAULTS.max_attempts
  self.lockSeconds = opts.lock_seconds or M.DEFAULTS.lock_seconds
  self.failures = 0
  self.lockedUntil = nil
  self.onLocked = opts.onLocked
  return self
end

function Gate:isLocked()
  if self.lockedUntil ~= nil and self.now() < self.lockedUntil then
    return true
  end
  if self.lockedUntil ~= nil then
    -- Lock expired: a fresh start.
    self.lockedUntil = nil
    self.failures = 0
  end
  return false
end

function Gate:secondsLeft()
  if self.lockedUntil == nil then
    return 0
  end
  return math.max(0, math.ceil(self.lockedUntil - self.now()))
end

function Gate:reset()
  self.failures = 0
  self.lockedUntil = nil
end

--- Checks a PIN against the configured one. Returns ok, reason.
--- reason ∈ pin_not_configured | locked | wrong_pin
function Gate:check(configuredPin, offeredPin)
  configuredPin = tostring(configuredPin or "")
  if configuredPin == "" then
    return false, "pin_not_configured"
  end
  if self:isLocked() then
    return false, "locked"
  end
  if tostring(offeredPin or "") ~= configuredPin then
    self.failures = self.failures + 1
    if self.failures >= self.maxAttempts then
      self.lockedUntil = self.now() + self.lockSeconds
      self.failures = 0
      if self.onLocked then
        pcall(self.onLocked)
      end
      return false, "locked"
    end
    return false, "wrong_pin"
  end
  self.failures = 0
  return true
end

local function json(status, body)
  return { status = status, contentType = "application/json", body = body }
end

--- Routes one parsed request.
--- provider = {
---   appHtml()                    -> html string
---   state()                      -> JSON string of the settings document
---   verify(pin)                  -> ok, reason
---   set(nameOrSlot, value, pin)  -> result table { ok, reason?, setting? }
---   encode(table)                -> JSON string
---   decode(string)               -> table
--- }
function M.route(req, token, provider)
  if req.method == "BAD" then
    return json("400 Bad Request", '{"ok":false,"error":"malformed request"}')
  end
  if req.method == "OPTIONS" then
    return json("204 No Content", "")
  end
  if req.path == "/ping" and req.method == "GET" then
    return json("200 OK", '{"ok":true,"service":"dealer-panel"}')
  end
  if req.path == "/app" and req.method == "GET" then
    local ok, html = pcall(provider.appHtml)
    if not ok or type(html) ~= "string" or html == "" then
      return json("503 Service Unavailable", '{"ok":false,"error":"app not loadable"}')
    end
    return { status = "200 OK", contentType = "text/html; charset=utf-8", body = html }
  end
  if token == nil or token == "" or req.query.k ~= token then
    return json("403 Forbidden", '{"ok":false,"error":"bad token"}')
  end
  if req.path == "/state" then
    if req.method ~= "GET" then
      return json("405 Method Not Allowed", '{"ok":false}')
    end
    local ok, body = pcall(provider.state)
    if not ok or type(body) ~= "string" then
      return json("500 Internal Server Error", '{"ok":false,"error":"state unavailable"}')
    end
    return json("200 OK", body)
  end
  if req.method ~= "POST" then
    local known = req.path == "/set" or req.path == "/verify"
    return json(known and "405 Method Not Allowed" or "404 Not Found", '{"ok":false}')
  end
  local okDec, doc = pcall(provider.decode, req.body)
  if not okDec or type(doc) ~= "table" then
    return json("400 Bad Request", '{"ok":false,"error":"body must be JSON"}')
  end
  if req.path == "/verify" then
    local ok, reason = provider.verify(doc.pin)
    local okEnc, encoded = pcall(provider.encode, { ok = ok == true, reason = reason })
    return json(ok and "200 OK" or "403 Forbidden", okEnc and encoded or '{"ok":false}')
  end
  if req.path == "/set" then
    local okSet, result = pcall(provider.set, doc.name or doc.slot, doc.value, doc.pin)
    if not okSet or type(result) ~= "table" then
      return json("500 Internal Server Error", '{"ok":false,"error":"set failed"}')
    end
    local okEnc, encoded = pcall(provider.encode, result)
    local status = "200 OK"
    if not result.ok then
      status = (
        result.reason == "pin_not_configured"
        or result.reason == "locked"
        or result.reason == "wrong_pin"
        or result.reason == "unlicensed"
      )
          and "403 Forbidden"
        or "422 Unprocessable Entity"
    end
    return json(status, okEnc and encoded or '{"ok":false}')
  end
  return json("404 Not Found", '{"ok":false}')
end

return M
