--[[==========================================================================
  Atmosphere — LAN state relay (pure HTTP router)

  Field finding (Doerr touchscreen, 2026-08-31): the Navigator WebView loads
  the app but the JS API reply channel delivers nothing — the driver is
  healthy, the page starves. The proven answer in this repo is the Protect
  snapshot relay: the driver listens on a controller port and the page
  fetches over plain LAN HTTP. The relay address+token travel INSIDE the
  web_view_url query string, which demonstrably reaches the page.

  This module is the pure half: request parsing (chunk-safe) and routing.
  The driver owns the socket. All mutating routes and /state require the
  minted token (?k=); /ping alone is tokenless so the page can probe
  reachability without leaking anything.

    GET  /ping                     -> {"ok":true}
    GET  /state?k=<token>          -> full UI state JSON
    POST /settings?k=<token>       -> body {"settings":{...}} -> apply
    POST /refresh?k=<token>        -> refresh all weather data
    POST /simulate?k=<token>       -> body {"scenario":"..."} ("" stops)
============================================================================]]

local M = {}

--- Accumulating parser. Returns nil while the request is incomplete (more
--- chunks coming), or { method, path, query = {}, body } once whole. A
--- request with no Content-Length is complete at end-of-headers.
function M.parse(buffer)
  if type(buffer) ~= "string" then
    return nil
  end
  local headerEnd = buffer:find("\r\n\r\n", 1, true)
  if headerEnd == nil then
    return nil
  end
  local head = buffer:sub(1, headerEnd - 1)
  local method, target = head:match("^(%u+)%s+(%S+)%s+HTTP/")
  if method == nil then
    -- Malformed request line: complete-but-bad, let the router 400 it.
    return { method = "BAD", path = "/", query = {}, body = "" }
  end
  local contentLength = tonumber(head:match("[Cc]ontent%-[Ll]ength:%s*(%d+)") or "0") or 0
  local body = buffer:sub(headerEnd + 4)
  if #body < contentLength then
    return nil -- body still arriving
  end
  body = body:sub(1, contentLength)
  local path, queryString = target:match("^([^%?]*)%??(.*)$")
  local query = {}
  for key, value in tostring(queryString):gmatch("([^&=]+)=([^&]*)") do
    query[key] = value:gsub("%%(%x%x)", function(hex)
      return string.char(tonumber(hex, 16))
    end)
  end
  return { method = method, path = path, query = query, body = body }
end

local function json(status, body)
  return { status = status, contentType = "application/json", body = body }
end

--- Routes one parsed request.
--- provider = {
---   state()                 -> JSON string of the UI document
---   applySettings(jsonText) -> refusals array (settings applied) | nil err
---   refresh()               -> ()
---   simulate(scenario)      -> boolean started ("" or nil stops -> true)
---   encode(table)           -> JSON string
--- }
function M.route(req, token, provider)
  if req.method == "BAD" then
    return json("400 Bad Request", '{"ok":false,"error":"malformed request"}')
  end
  -- CORS preflight: the page POSTs JSON cross-origin, so the browser sends
  -- OPTIONS first (measured against the stub relay). Answered before the
  -- token wall — preflights are browser-generated and carry no secrets.
  if req.method == "OPTIONS" then
    return json("204 No Content", "")
  end
  if req.path == "/ping" and req.method == "GET" then
    return json("200 OK", '{"ok":true,"service":"atmosphere"}')
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
    local known = req.path == "/settings" or req.path == "/refresh" or req.path == "/simulate"
    return json(known and "405 Method Not Allowed" or "404 Not Found", '{"ok":false}')
  end
  if req.path == "/settings" then
    local ok, refused = pcall(provider.applySettings, req.body)
    if not ok or refused == nil then
      return json("422 Unprocessable Entity", '{"ok":false,"error":"settings not applied"}')
    end
    local okEnc, encoded = pcall(provider.encode, { ok = true, refused = refused })
    return json("200 OK", okEnc and encoded or '{"ok":true}')
  end
  if req.path == "/refresh" then
    pcall(provider.refresh)
    return json("200 OK", '{"ok":true}')
  end
  if req.path == "/simulate" then
    local scenario = ""
    local okDec, doc = pcall(provider.decode, req.body)
    if okDec and type(doc) == "table" and type(doc.scenario) == "string" then
      scenario = doc.scenario
    end
    local ok, started = pcall(provider.simulate, scenario)
    if ok and started then
      return json("200 OK", '{"ok":true}')
    end
    return json("422 Unprocessable Entity", '{"ok":false,"error":"unknown scenario"}')
  end
  return json("404 Not Found", '{"ok":false}')
end

--- Renders a routed result as HTTP bytes. CORS is wide open on purpose: the
--- page's origin is Navigator's controller:// scheme and the relay serves
--- only token-gated JSON on the LAN.
function M.render(result)
  local body = result.body or ""
  return table.concat({
    "HTTP/1.1 " .. result.status,
    "Content-Type: " .. result.contentType,
    "Content-Length: " .. #body,
    "Cache-Control: no-store",
    "Access-Control-Allow-Origin: *",
    "Access-Control-Allow-Methods: GET, POST, OPTIONS",
    "Access-Control-Allow-Headers: Content-Type",
    "Access-Control-Max-Age: 600",
    "Connection: close",
    "",
    body,
  }, "\r\n")
end

return M
