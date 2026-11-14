--- VenueFlow: the LAN relay router (pure HTTP, no sockets).
---
--- The driver listens on one controller port; this module turns bytes into a
--- request and a request into a reply. The pattern is the repository's other
--- WebView drivers' (Daypart, PIN Lock, Commissioning): proven on a bench
--- controller, and the reason it exists is a field finding that the Navigator
--- JavaScript reply channel can deliver nothing on a touch screen.
---
---   GET  /ping              {"ok":true,"service":"venueflow"}      no identity
---   GET  /app               the operator page                       no identity (holds no secret)
---   GET  /studio            the Installer Studio page               no identity (holds no secret)
---   POST /api[?k=<tile>]    one protocol request -> one reply       identity inside the request
---   POST /image             a floor-plan picture, as raw text       installer session (X-VF-Session header)
---   OPTIONS *               CORS preflight
---
--- /image exists for one reason: the repository's JSON decoder takes time
--- quadratic in the length of a string (measured: about 10 s for 600 kB on a
--- desktop), so a picture must never travel inside a JSON request. Its body
--- is the picture's data: URL and nothing else; the reply is small JSON.
---
--- There is no other route. Every control and configuration action is a
--- protocol command, and core.lua decides who may run it. The tile token `k`
--- only says "this request comes from a Navigator tile"; it grants the
--- installer-chosen default profile and nothing more.

local Protocol = require("venueflow.protocol")

local M = {}

M.MAX_BODY = Protocol.MAX_REQUEST_BYTES
M.MAX_HEADER = 16 * 1024

local function json(status, body)
  return { status = status, contentType = "application/json", body = body }
end

--- Accumulating parser. Returns nil while the request is incomplete, or
--- { method, path, query, body } once whole; method "BAD" for a request line
--- that cannot be read and "TOO_LARGE" for a declared body over the limit.
function M.parse(buffer)
  if type(buffer) ~= "string" then
    return nil
  end
  local headerEnd = buffer:find("\r\n\r\n", 1, true)
  if headerEnd == nil then
    if #buffer > M.MAX_HEADER then
      return { method = "BAD", path = "/", query = {}, body = "" }
    end
    return nil
  end
  local head = buffer:sub(1, headerEnd - 1)
  local method, target = head:match("^(%u+)%s+(%S+)%s+HTTP/%d")
  if method == nil then
    return { method = "BAD", path = "/", query = {}, body = "" }
  end
  local contentLength = tonumber(head:match("\r\n[Cc]ontent%-[Ll]ength:%s*(%d+)") or "0") or 0
  if contentLength > M.MAX_BODY then
    return { method = "TOO_LARGE", path = "/", query = {}, body = "" }
  end
  local body = buffer:sub(headerEnd + 4)
  if #body < contentLength then
    return nil
  end
  body = body:sub(1, contentLength)
  local path, queryString = target:match("^([^%?]*)%??(.*)$")
  local query = {}
  for key, value in tostring(queryString):gmatch("([^&=]+)=([^&]*)") do
    query[key] = value:gsub("%%(%x%x)", function(hex)
      return string.char(tonumber(hex, 16))
    end)
  end
  -- The one request header the router uses.
  local session = head:match("\r\n[Xx]%-[Vv][Ff]%-[Ss]ession:%s*([%w%-_]+)")
  return { method = method, path = path, query = query, body = body, session = session }
end

--- A receiver for one connection. A large upload arrives in many chunks;
--- appending each to one growing string would copy megabytes hundreds of
--- times, so chunks are kept in a list and joined once, when the request is
--- complete.
---   local rx = Relay.receiver()
---   local req = Relay.feed(rx, chunk)   -- nil until the request is whole
function M.receiver()
  return { parts = {}, size = 0, need = nil }
end

function M.feed(rx, chunk)
  chunk = tostring(chunk or "")
  rx.parts[#rx.parts + 1] = chunk
  rx.size = rx.size + #chunk
  if rx.need == nil then
    -- Headers still arriving: they are small, so joining here is cheap.
    local buffer = table.concat(rx.parts)
    rx.parts = { buffer }
    local headerEnd = buffer:find("\r\n\r\n", 1, true)
    if headerEnd == nil then
      if rx.size > M.MAX_HEADER then
        return { method = "BAD", path = "/", query = {}, body = "" }
      end
      return nil
    end
    local head = buffer:sub(1, headerEnd - 1)
    if head:match("^(%u+)%s+(%S+)%s+HTTP/%d") == nil then
      return { method = "BAD", path = "/", query = {}, body = "" }
    end
    local contentLength = tonumber(head:match("\r\n[Cc]ontent%-[Ll]ength:%s*(%d+)") or "0") or 0
    if contentLength > M.MAX_BODY then
      return { method = "TOO_LARGE", path = "/", query = {}, body = "" }
    end
    rx.need = headerEnd + 3 + contentLength
  end
  if rx.size < rx.need then
    return nil
  end
  return M.parse(table.concat(rx.parts))
end

local PAGE_HEADERS = {
  "X-Content-Type-Options: nosniff",
  "Referrer-Policy: no-referrer",
  -- One self-contained file: inline script and style, pictures as data: URLs,
  -- requests only back to the relay. Nothing is loaded from anywhere else.
  "Content-Security-Policy: default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; "
    .. "img-src data: blob:; connect-src 'self'; base-uri 'none'; form-action 'none'",
}

--- deps = {
---   tileToken              the token the driver put in the web view URL
---   handle(request, transport) -> reply      core:handle
---   encode(table) -> string, decode(string) -> table
---   upload(session, dataUrl, transport) -> reply   core:upload (a floor-plan picture)
---   page(name) -> html | nil                 "app" | "studio"
---   client                 the remote address, when the socket layer knows it
--- }
function M.route(req, deps)
  if req == nil or req.method == "BAD" then
    return json("400 Bad Request", '{"ok":false,"errorCode":"VF_BAD_REQUEST"}')
  end
  if req.method == "TOO_LARGE" then
    return json("413 Payload Too Large", '{"ok":false,"errorCode":"VF_TOO_LARGE"}')
  end
  if req.method == "OPTIONS" then
    return json("204 No Content", "")
  end
  if req.path == "/ping" then
    if req.method ~= "GET" then
      return json("405 Method Not Allowed", '{"ok":false}')
    end
    return json("200 OK", '{"ok":true,"service":"venueflow"}')
  end
  if req.path == "/app" or req.path == "/studio" then
    if req.method ~= "GET" then
      return json("405 Method Not Allowed", '{"ok":false}')
    end
    local ok, html = pcall(deps.page, req.path:sub(2))
    if not ok or type(html) ~= "string" or html == "" then
      return json("503 Service Unavailable", '{"ok":false,"error":"page not loadable"}')
    end
    return { status = "200 OK", contentType = "text/html; charset=utf-8", body = html, headers = PAGE_HEADERS }
  end
  if req.path == "/image" then
    if req.method ~= "POST" then
      return json("405 Method Not Allowed", '{"ok":false}')
    end
    local okUp, reply = pcall(deps.upload, req.session, req.body, { client = deps.client, via = "relay" })
    if not okUp or type(reply) ~= "table" then
      return json("500 Internal Server Error", '{"ok":false,"errorCode":"VF_INTERNAL"}')
    end
    local okEnc, encoded = pcall(deps.encode, reply)
    return json("200 OK", okEnc and encoded or '{"ok":false,"errorCode":"VF_INTERNAL"}')
  end
  if req.path ~= "/api" then
    return json("404 Not Found", '{"ok":false}')
  end
  if req.method ~= "POST" then
    return json("405 Method Not Allowed", '{"ok":false}')
  end
  local okDec, request = pcall(deps.decode, req.body)
  if not okDec or type(request) ~= "table" then
    return json(
      "400 Bad Request",
      '{"ok":false,"errorCode":"VF_BAD_REQUEST","message":"The request body must be JSON."}'
    )
  end
  local tile = type(deps.tileToken) == "string" and #deps.tileToken >= 16 and req.query.k == deps.tileToken
  local okHandle, reply = pcall(deps.handle, request, { tile = tile, client = deps.client, via = "relay" })
  if not okHandle or type(reply) ~= "table" then
    return json("500 Internal Server Error", '{"ok":false,"errorCode":"VF_INTERNAL"}')
  end
  local okEnc, encoded = pcall(deps.encode, reply)
  if not okEnc or type(encoded) ~= "string" then
    return json("500 Internal Server Error", '{"ok":false,"errorCode":"VF_INTERNAL"}')
  end
  return json("200 OK", encoded)
end

--- Renders a routed result as HTTP bytes. CORS is open on purpose: a page
--- loaded through Navigator's controller:// scheme is another origin, no
--- cookie is ever used, and every command carries its own token.
function M.render(result)
  local body = result.body or ""
  local lines = {
    "HTTP/1.1 " .. result.status,
    "Content-Type: " .. result.contentType,
    "Content-Length: " .. #body,
    "Cache-Control: no-store",
    "Access-Control-Allow-Origin: *",
    "Access-Control-Allow-Methods: GET, POST, OPTIONS",
    "Access-Control-Allow-Headers: Content-Type, X-VF-Session",
    "Access-Control-Max-Age: 600",
    "Connection: close",
  }
  for _, h in ipairs(result.headers or {}) do
    lines[#lines + 1] = h
  end
  return table.concat(lines, "\r\n") .. "\r\n\r\n" .. body
end

return M
