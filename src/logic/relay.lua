--- Logic Blocks — the LAN relay routes (pure).
---
--- The transport Atmosphere proved on the bench: the driver listens on a
--- controller port and the dealer page fetches plain LAN HTTP with a token.
--- Parsing and rendering are Atmosphere's; only the routes are ours.
---
---   GET  /ping                 tokenless liveness ("logic-blocks")
---   GET  /app                  the page itself (same origin, no secrets)
---   GET  /state?k=             the read-only app document
---   GET  /activity?k=&slot=&decision=&since=&limit=
---   GET  /export?k=            the redacted diagnostics export
---   GET  /sandbox?k=           the open sandbox, if any
---   POST /sandbox/open?k=      { slot }
---   POST /sandbox/input?k=     { command, value, by, input }
---   POST /sandbox/source?k=    { index, value, unavailable }
---   POST /sandbox/advance?k=   { seconds }
---   POST /sandbox/reset?k=
---   POST /sandbox/replay?k=    { steps }   (omit to run the same steps again)
---   POST /sandbox/close?k=
---
--- THERE IS NO ROUTE THAT CHANGES A BLOCK. Composer is the only place a
--- block is created, edited, enabled or retired. Every write route above
--- acts on the sandbox, which cannot reach the live runtime (logic/sandbox).
--- The token never appears in a response.

local uirelay = require("atmosphere.uirelay")

local M = {}

M.SERVICE = "logic-blocks"
M.parse = uirelay.parse
M.render = uirelay.render

local function json(status, body)
  return { status = status, contentType = "application/json", body = body }
end

local SANDBOX_WRITES = {
  ["/sandbox/open"] = "open",
  ["/sandbox/input"] = "input",
  ["/sandbox/source"] = "source",
  ["/sandbox/advance"] = "advance",
  ["/sandbox/reset"] = "reset",
  ["/sandbox/replay"] = "replay",
  ["/sandbox/close"] = "close",
}

local READS = { ["/state"] = true, ["/activity"] = true, ["/export"] = true, ["/sandbox"] = true }

--- provider = {
---   appHtml()            -> html | nil
---   state()              -> table
---   activity(query)      -> table
---   export()             -> table
---   sandbox(op, body)    -> table { ok, ... }   (op nil = read)
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
    return json("200 OK", '{"ok":true,"service":"' .. M.SERVICE .. '"}')
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
  local function reply(status, t)
    local ok, encoded = pcall(provider.encode, t)
    if not ok or type(encoded) ~= "string" then
      return json("500 Internal Server Error", '{"ok":false,"error":"encode failed"}')
    end
    return json(status, encoded)
  end
  local function produce(fn, ...)
    local ok, result = pcall(fn, ...)
    if not ok or type(result) ~= "table" then
      return json("500 Internal Server Error", '{"ok":false,"error":"unavailable"}')
    end
    if result.ok == nil then
      result.ok = true
    end
    return reply(result.ok and "200 OK" or "422 Unprocessable Entity", result)
  end
  if req.method == "GET" then
    if req.path == "/state" then
      return produce(provider.state)
    elseif req.path == "/activity" then
      return produce(provider.activity, req.query)
    elseif req.path == "/export" then
      return produce(provider.export)
    elseif req.path == "/sandbox" then
      return produce(provider.sandbox, nil, {})
    end
    return json(SANDBOX_WRITES[req.path] and "405 Method Not Allowed" or "404 Not Found", '{"ok":false}')
  end
  if req.method ~= "POST" then
    return json("405 Method Not Allowed", '{"ok":false}')
  end
  local op = SANDBOX_WRITES[req.path]
  if op == nil then
    return json(READS[req.path] and "405 Method Not Allowed" or "404 Not Found", '{"ok":false}')
  end
  local body = {}
  if req.body ~= nil and req.body ~= "" then
    local ok, doc = pcall(provider.decode, req.body)
    if not ok or type(doc) ~= "table" then
      return json("400 Bad Request", '{"ok":false,"error":"body is not JSON"}')
    end
    body = doc
  end
  return produce(provider.sandbox, op, body)
end

return M
