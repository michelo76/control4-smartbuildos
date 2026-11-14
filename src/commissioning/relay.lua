--[[==========================================================================
  Commissioning Matrix - LAN relay router for the technician's phone page.

  Same posture as the Dealer Panel relay (whose parser and renderer this
  reuses): the driver listens on a controller port, the page is plain LAN
  HTTP, the minted token rides the page URL query.

    GET  /ping                  -> {"ok":true,"service":"commissioning"}
    GET  /app                   -> the page (tokenless; it ships in the c4z)
    GET  /state?k=<token>       -> rooms, items, run state, counts
    GET  /result?k=<token>      -> the as-built record (JSON)
    POST /run?k=<token>         -> {"scope"?, "technician"?}
    POST /room?k=<token>        -> {"room"}
    POST /test?k=<token>        -> {"key"}
    POST /mark?k=<token>        -> {"key","verdict","note"?}
    POST /signoff?k=<token>     -> {"name"}
    POST /abort?k=<token>
============================================================================]]

local uirelay = require("atmosphere.uirelay")

local M = {}

M.parse = uirelay.parse
M.render = uirelay.render

local function json(status, body)
  return { status = status, contentType = "application/json", body = body }
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

local POSTS = { run = true, room = true, test = true, mark = true, signoff = true, abort = true }

--- provider = {
---   appHtml() -> string
---   state() -> JSON string
---   result() -> JSON string|nil
---   act(name, doc) -> table { ok, reason? }   -- name in POSTS
---   encode(table) -> string, decode(string) -> table
--- }
function M.route(req, token, provider)
  if req.method == "BAD" then
    return json("400 Bad Request", '{"ok":false,"error":"malformed request"}')
  end
  if req.method == "OPTIONS" then
    return json("204 No Content", "")
  end
  if req.path == "/ping" and req.method == "GET" then
    return json("200 OK", '{"ok":true,"service":"commissioning"}')
  end
  if req.path == "/app" and req.method == "GET" then
    local ok, html = pcall(provider.appHtml)
    if not ok or type(html) ~= "string" or html == "" then
      return appFailure(provider, ok, html)
    end
    return { status = "200 OK", contentType = "text/html; charset=utf-8", body = html }
  end
  if token == nil or token == "" or req.query.k ~= token then
    return json("403 Forbidden", '{"ok":false,"error":"bad token"}')
  end
  if req.path == "/state" or req.path == "/result" then
    if req.method ~= "GET" then
      return json("405 Method Not Allowed", '{"ok":false}')
    end
    local ok, body = pcall(req.path == "/state" and provider.state or provider.result)
    if not ok then
      return json("500 Internal Server Error", '{"ok":false,"error":"unavailable"}')
    end
    if type(body) ~= "string" then
      return json("404 Not Found", '{"ok":false,"error":"no run yet"}')
    end
    return json("200 OK", body)
  end
  local name = req.path:match("^/(%a+)$")
  if name == nil or not POSTS[name] then
    return json("404 Not Found", '{"ok":false}')
  end
  if req.method ~= "POST" then
    return json("405 Method Not Allowed", '{"ok":false}')
  end
  local doc = {}
  if req.body ~= nil and req.body ~= "" then
    local okDec, decoded = pcall(provider.decode, req.body)
    if not okDec or type(decoded) ~= "table" then
      return json("400 Bad Request", '{"ok":false,"error":"body must be JSON"}')
    end
    doc = decoded
  end
  local ok, result = pcall(provider.act, name, doc)
  if not ok or type(result) ~= "table" then
    return json("500 Internal Server Error", '{"ok":false,"error":"action failed"}')
  end
  local okEnc, encoded = pcall(provider.encode, result)
  local status = result.ok and "200 OK" or "409 Conflict"
  return json(status, okEnc and encoded or '{"ok":false}')
end

return M
