--- Home Guide — LAN relay router (pure).
---
--- The same proven shape as Atmosphere's relay (`atmosphere.uirelay`, whose
--- request parser and HTTP renderer this module reuses): the driver listens
--- on a controller port, the page fetches plain LAN HTTP, and the token
--- rides the web_view_url query. Routes:
---
---   OPTIONS *                 -> 204 (CORS preflight, tokenless)
---   GET  /ping                -> {"ok":true,"service":"home-guide"} (tokenless)
---   GET  /app                 -> the page itself, same-origin (tokenless; no secrets in it)
---   GET  /manual?k=<token>    -> the manual document JSON
---   POST /refresh?k=<token>   -> rebuild the manual now
---
--- Everything else is 404; a wrong token is 403 before any route is looked
--- at. The manual carries device names and the dealer's contact block only,
--- so the token's job is keeping casual LAN clients from enumerating rooms.

local uirelay = require("atmosphere.uirelay")

local M = {}

M.parse = uirelay.parse
M.render = uirelay.render

local function json(status, body)
  return { status = status, contentType = "application/json", body = body }
end

--- provider = { appHtml() -> string|nil, manual() -> JSON string, refresh() -> () }
function M.route(req, token, provider)
  if req == nil or req.method == "BAD" then
    return json("400 Bad Request", '{"ok":false,"error":"malformed request"}')
  end
  if req.method == "OPTIONS" then
    return json("204 No Content", "")
  end
  if req.path == "/ping" and req.method == "GET" then
    return json("200 OK", '{"ok":true,"service":"home-guide"}')
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
  if req.path == "/manual" then
    if req.method ~= "GET" then
      return json("405 Method Not Allowed", '{"ok":false}')
    end
    local ok, body = pcall(provider.manual)
    if not ok or type(body) ~= "string" or body == "" then
      return json("503 Service Unavailable", '{"ok":false,"error":"manual unavailable"}')
    end
    return json("200 OK", body)
  end
  if req.path == "/refresh" then
    if req.method ~= "POST" then
      return json("405 Method Not Allowed", '{"ok":false}')
    end
    local ok = pcall(provider.refresh)
    return json(ok and "200 OK" or "500 Internal Server Error", ok and '{"ok":true}' or '{"ok":false}')
  end
  return json("404 Not Found", '{"ok":false}')
end

return M
