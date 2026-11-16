--- Variable Inspector — LAN relay router (pure).
---
--- The same transport Atmosphere proved on the bench: the driver listens
--- on a controller port, the page fetches plain LAN HTTP, the token rides
--- the web_view_url query. Parsing and rendering are Atmosphere's
--- (`atmosphere.uirelay.parse` / `render`); only the routes are ours.
---
---   GET  /ping                              tokenless liveness
---   GET  /app                               the page itself (same-origin)
---   GET  /devices?k=&q=                     device list (filtered)
---   GET  /device?k=&id=                     open a device → its live variables
---   GET  /state?k=                          open snapshot + watch list + status
---   POST /close?k=                          release the open device
---   POST /watch?k=    {device_id, variable_id}
---   POST /unwatch?k=  {device_id, variable_id}
---   POST /set?k=      {device_id, variable_id, value, pin}
---   POST /clear?k=                          clear history
---
--- The Dealer PIN never travels in the URL: it is in the POST body of /set
--- only, compared by the provider, and the relay never echoes it.

local uirelay = require("atmosphere.uirelay")

local M = {}

M.parse = uirelay.parse
M.render = uirelay.render

local function json(status, body)
  return { status = status, contentType = "application/json", body = body }
end

local function decode(provider, text)
  local ok, doc = pcall(provider.decode, text)
  if ok and type(doc) == "table" then
    return doc
  end
  return {}
end

--- provider = {
---   appHtml()                                  -> html|nil
---   devices(filter)                            -> list
---   openDevice(id)                             -> snapshot|nil, reason
---   closeDevice()                              -> boolean
---   state()                                    -> table
---   watch(deviceId, varId)                     -> ok, reason
---   unwatch(deviceId, varId)                   -> ok, reason
---   set(deviceId, varId, value, pin)           -> ok, detail
---   clear()                                    -> ()
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
    return json("200 OK", '{"ok":true,"service":"variable-inspector"}')
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
  local function reply(t)
    local ok, encoded = pcall(provider.encode, t)
    return json("200 OK", ok and encoded or '{"ok":false,"error":"encode failed"}')
  end
  if req.method == "GET" then
    if req.path == "/devices" then
      local ok, list = pcall(provider.devices, req.query.q)
      return reply({ ok = ok, devices = ok and list or {} })
    elseif req.path == "/device" then
      local ok, snap, why = pcall(provider.openDevice, tonumber(req.query.id))
      if not ok then
        return json("500 Internal Server Error", '{"ok":false,"error":"device read failed"}')
      end
      if snap == nil then
        local okE, body = pcall(provider.encode, { ok = false, error = tostring(why or "not found") })
        return json("404 Not Found", okE and body or '{"ok":false}')
      end
      return reply({ ok = true, device_id = tonumber(req.query.id), variables = snap })
    elseif req.path == "/state" then
      local ok, state = pcall(provider.state)
      if not ok or type(state) ~= "table" then
        return json("500 Internal Server Error", '{"ok":false,"error":"state unavailable"}')
      end
      state.ok = true
      return reply(state)
    end
    local known = req.path == "/close"
      or req.path == "/watch"
      or req.path == "/unwatch"
      or req.path == "/set"
      or req.path == "/clear"
    return json(known and "405 Method Not Allowed" or "404 Not Found", '{"ok":false}')
  end
  if req.method ~= "POST" then
    return json("405 Method Not Allowed", '{"ok":false}')
  end
  if req.path == "/close" then
    pcall(provider.closeDevice)
    return json("200 OK", '{"ok":true}')
  elseif req.path == "/watch" or req.path == "/unwatch" then
    local body = decode(provider, req.body)
    local fn = req.path == "/watch" and provider.watch or provider.unwatch
    local ok, accepted, why = pcall(fn, tonumber(body.device_id), tonumber(body.variable_id))
    if not ok then
      return json("500 Internal Server Error", '{"ok":false,"error":"watch failed"}')
    end
    local okE, encoded = pcall(provider.encode, { ok = accepted == true, reason = tostring(why or "") })
    return json(accepted and "200 OK" or "422 Unprocessable Entity", okE and encoded or '{"ok":false}')
  elseif req.path == "/set" then
    local body = decode(provider, req.body)
    local ok, accepted, detail =
      pcall(provider.set, tonumber(body.device_id), tonumber(body.variable_id), body.value, body.pin)
    if not ok then
      return json("500 Internal Server Error", '{"ok":false,"error":"set failed"}')
    end
    local okE, encoded = pcall(provider.encode, { ok = accepted == true, detail = tostring(detail or "") })
    return json(accepted and "200 OK" or "422 Unprocessable Entity", okE and encoded or '{"ok":false}')
  elseif req.path == "/clear" then
    pcall(provider.clear)
    return json("200 OK", '{"ok":true}')
  end
  return json("404 Not Found", '{"ok":false}')
end

return M
