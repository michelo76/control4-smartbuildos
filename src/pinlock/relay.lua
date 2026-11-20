--- PIN Lock -- LAN relay router (pure).
---
--- Same transport as the other WebView drivers: the driver listens on a
--- controller port, the page fetches plain LAN HTTP, the token rides the
--- web_view_url query. Parsing and rendering are Atmosphere's.
---
---   GET  /ping                       tokenless liveness
---   GET  /app                        the page (same-origin)
---   GET  /config?k=                  guarded action names, setup/lock state
---   POST /unlock?k=   {action, pin}  fire a guarded action
---   POST /admin/setup?k=  {name, pin}   first owner code (only while none exists)
---   POST /admin/login?k=  {pin}         owner PIN -> session
---   POST /admin/state?k=  {session}     codes (no secrets), recent, locks
---   POST /admin/save?k=   {session, id?, ...}
---   POST /admin/enable|disable|revoke?k= {session, id}
---   POST /admin/clear?k=  {session}     clear lockouts
---   POST /admin/logout?k= {session}
---   POST /verify      {challenge_id, pin}   AI Core verification (no `k`:
---                                           authenticated by the challenge)
---
--- A PIN travels only in a POST body, never in the URL, and is never echoed.
--- Every POST is answered by a provider function `provider[name](body)` that
--- returns (httpStatus, table); the router adds nothing to a reply and never
--- logs.
---
--- /verify is the one route without the page token: the AI Core touchscreen
--- page (another driver's page, on another port) posts an owner PIN here
--- against a 60-second single-use challenge that AI Core obtained over the
--- module bus. Its body has exactly two keys, and its reply is REBUILT here
--- from a closed set -- {ok}, {ok:false} or {ok:false, locked, retry_in} --
--- whatever the provider returned, so no code name, role, reason or echo of
--- the body can leave through it.

local uirelay = require("atmosphere.uirelay")

local M = {}

M.parse = uirelay.parse
M.render = uirelay.render

M.POST_ROUTES = {
  ["/unlock"] = "unlock",
  ["/admin/setup"] = "setup",
  ["/admin/login"] = "login",
  ["/admin/state"] = "state",
  ["/admin/save"] = "save",
  ["/admin/enable"] = "enable",
  ["/admin/disable"] = "disable",
  ["/admin/revoke"] = "revoke",
  ["/admin/clear"] = "clear",
  ["/admin/logout"] = "logout",
}

local STATUS_TEXT = {
  [200] = "200 OK",
  [400] = "400 Bad Request",
  [401] = "401 Unauthorized",
  [403] = "403 Forbidden",
  [404] = "404 Not Found",
  [422] = "422 Unprocessable Entity",
  [429] = "429 Too Many Requests",
  [500] = "500 Internal Server Error",
}

local function json(status, body)
  return { status = status, contentType = "application/json", body = body }
end

M.VERIFY_PATH = "/verify"
M.VERIFY_KEYS = { challenge_id = true, pin = true }

--- The only three answers /verify can give (status, body). Built from
--- constants and one integer: nothing the provider returned is copied.
local function verifyReply(doc)
  if type(doc) == "table" and doc.ok == true then
    return json("200 OK", '{"ok":true}')
  end
  if type(doc) == "table" and doc.locked == true then
    local left = math.max(0, math.floor(tonumber(doc.retry_in) or 0))
    return json("429 Too Many Requests", string.format('{"ok":false,"locked":true,"retry_in":%d}', left))
  end
  return json("401 Unauthorized", '{"ok":false}')
end
M.verifyReply = verifyReply

--- POST /verify {challenge_id, pin}: closed keys, both strings; the
--- provider's `verify(challengeId, pin)` decides.
function M.verify(req, provider)
  if req.method ~= "POST" then
    return json("405 Method Not Allowed", '{"ok":false}')
  end
  if type(provider.verify) ~= "function" then
    return json("404 Not Found", '{"ok":false}')
  end
  local okDec, body = pcall(provider.decode, req.body)
  if not okDec or type(body) ~= "table" then
    return json("400 Bad Request", '{"ok":false}')
  end
  for k, v in pairs(body) do
    if not M.VERIFY_KEYS[k] or type(v) ~= "string" then
      return json("400 Bad Request", '{"ok":false}')
    end
  end
  if body.challenge_id == nil or body.pin == nil then
    return json("400 Bad Request", '{"ok":false}')
  end
  local ok, doc = pcall(provider.verify, body.challenge_id, body.pin)
  if not ok then
    return json("500 Internal Server Error", '{"ok":false}')
  end
  return verifyReply(doc)
end

--- The 503 for a page that cannot be read says why (paths tried, no secrets),
--- so a controller can be asked instead of guessed at.
local function appFailure(provider, ok, html)
  local why = ""
  if not ok then
    why = tostring(html)
  elseif type(provider.appWhy) == "function" then
    local good, w = pcall(provider.appWhy)
    why = good and tostring(w or "") or ""
  end
  why = why:gsub('[%c"\\]', " "):sub(1, 700)
  return json("503 Service Unavailable", '{"ok":false,"error":"app not loadable","why":"' .. why .. '"}')
end

--- provider = {
---   appHtml() -> html|nil,
---   config() -> table,
---   unlock(body)/setup/login/state/save/enable/disable/revoke/clear/logout -> status, table,
---   encode(table) / decode(text)
--- }
function M.route(req, token, provider)
  if req.method == "BAD" then
    return json("400 Bad Request", '{"ok":false,"error":"malformed request"}')
  end
  if req.method == "OPTIONS" then
    return json("204 No Content", "")
  end
  if req.path == "/ping" and req.method == "GET" then
    return json("200 OK", '{"ok":true,"service":"pin-lock"}')
  end
  if req.path == "/app" and req.method == "GET" then
    local ok, html = pcall(provider.appHtml)
    if not ok or type(html) ~= "string" or html == "" then
      return appFailure(provider, ok, html)
    end
    return { status = "200 OK", contentType = "text/html; charset=utf-8", body = html }
  end
  if req.path == M.VERIFY_PATH then
    return M.verify(req, provider)
  end
  if token == nil or token == "" or req.query.k ~= token then
    return json("403 Forbidden", '{"ok":false,"error":"bad token"}')
  end
  local function reply(status, t)
    local ok, encoded = pcall(provider.encode, t)
    return json(STATUS_TEXT[status] or "500 Internal Server Error", ok and encoded or '{"ok":false}')
  end
  if req.method == "GET" then
    if req.path == "/config" then
      local ok, cfg = pcall(provider.config)
      if not ok or type(cfg) ~= "table" then
        return json("500 Internal Server Error", '{"ok":false,"error":"config unavailable"}')
      end
      cfg.ok = true
      return reply(200, cfg)
    end
    return json(M.POST_ROUTES[req.path] and "405 Method Not Allowed" or "404 Not Found", '{"ok":false}')
  end
  if req.method ~= "POST" then
    return json("405 Method Not Allowed", '{"ok":false}')
  end
  local name = M.POST_ROUTES[req.path]
  if name == nil or type(provider[name]) ~= "function" then
    return json("404 Not Found", '{"ok":false}')
  end
  local okDec, body = pcall(provider.decode, req.body)
  if not okDec or type(body) ~= "table" then
    return json("400 Bad Request", '{"ok":false,"error":"body must be JSON"}')
  end
  local ok, status, doc = pcall(provider[name], body)
  if not ok or type(doc) ~= "table" then
    return json("500 Internal Server Error", '{"ok":false,"error":"request failed"}')
  end
  return reply(tonumber(status) or 500, doc)
end

return M
