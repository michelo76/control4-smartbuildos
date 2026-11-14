--- Daypart Scheduler: LAN relay router (pure).
---
--- Same posture as Dealer Settings (whose request parser, renderer and PIN
--- gate this reuses): the driver listens on a controller port, the schedule
--- page fetches plain LAN HTTP, the minted token rides the web view URL.
--- Anyone who opens the tile can READ the schedule. Every change needs the
--- Manager PIN; with no Manager PIN set the page is read-only.
---
---     GET  /ping                  -> {"ok":true,"service":"daypart"}
---     GET  /app                   -> the page (tokenless; it ships in the c4z)
---     GET  /state?k=<token>       -> schedule document
---     POST /verify?k=<token>      -> {"pin":"..."} -> {"ok":true|false,"reason"?}
---     POST /edit?k=<token>        -> {"pin":"...","op":"...",...} -> result

local panel = require("dealerpanel.relay")

local M = {}

M.parse = panel.parse
M.render = panel.render
M.newGate = panel.newGate

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

local GATE_REASONS = { pin_not_configured = true, locked = true, wrong_pin = true, unlicensed = true }

--- provider = {
---   appHtml()      -> html string
---   state()        -> JSON string of the schedule document
---   verify(pin)    -> ok, reason
---   edit(doc)      -> result table { ok, error?, reason?, warnings?, ... }
---   encode(table) / decode(string)
--- }
function M.route(req, token, provider)
  if req == nil or req.method == "BAD" then
    return json("400 Bad Request", '{"ok":false,"error":"malformed request"}')
  end
  if req.method == "OPTIONS" then
    return json("204 No Content", "")
  end
  if req.path == "/ping" and req.method == "GET" then
    return json("200 OK", '{"ok":true,"service":"daypart"}')
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
  if req.path ~= "/verify" and req.path ~= "/edit" then
    return json("404 Not Found", '{"ok":false}')
  end
  if req.method ~= "POST" then
    return json("405 Method Not Allowed", '{"ok":false}')
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
  local okEdit, result = pcall(provider.edit, doc)
  if not okEdit or type(result) ~= "table" then
    return json("500 Internal Server Error", '{"ok":false,"error":"edit failed"}')
  end
  local okEnc, encoded = pcall(provider.encode, result)
  local status = "200 OK"
  if not result.ok then
    status = GATE_REASONS[result.reason] and "403 Forbidden" or "422 Unprocessable Entity"
  end
  return json(status, okEnc and encoded or '{"ok":false}')
end

return M
