-- VenueFlow LAN relay (pure HTTP router) and protocol validation: request
-- parsing across chunks, every route, malformed and oversize input, invalid
-- command payloads, the absence of any unauthenticated control or
-- configuration endpoint, state delivery, and the security headers of the
-- pages.
--
-- Run from the driver root: make test

local H = require("venueflow_harness")
local Relay = require("venueflow.relay")
local Protocol = require("venueflow.protocol")
local Errors = require("venueflow.errors")
local CoreModule = require("venueflow.core")
local T = H.checker()
local check, eq = T.check, T.eq
local JSON = H.JSON

local env = H.new()
env.publishSample("sports_bar")
local TILE_TOKEN = "tiletoken0123456789abcdef"

local function deps(client)
  return {
    tileToken = TILE_TOKEN,
    handle = function(request, transport)
      return env.core:handle(request, transport)
    end,
    encode = function(t)
      return JSON:encode(t)
    end,
    decode = function(s)
      return JSON:decode(s)
    end,
    upload = function(session, dataUrl, transport)
      return env.core:upload(session, dataUrl, transport)
    end,
    page = function(name)
      return "<!doctype html><title>" .. name .. "</title>"
    end,
    client = client or "10.0.0.60",
  }
end

local function http(method, target, body)
  body = body or ""
  local raw = string.format(
    "%s %s HTTP/1.1\r\nHost: c4\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\r\n%s",
    method,
    target,
    #body,
    body
  )
  return Relay.route(Relay.parse(raw), deps())
end

local seq = 0
local function api(command, payload, opts)
  opts = opts or {}
  seq = seq + 1
  local res = http(
    "POST",
    "/api" .. (opts.k and ("?k=" .. opts.k) or ""),
    JSON:encode({
      requestId = "h" .. seq,
      command = command,
      payload = payload or {},
      session = opts.session,
      since = opts.since,
    })
  )
  return res, JSON:decode(res.body)
end

-- ── parsing ─────────────────────────────────────────────────────────────────
print("request parsing")
eq("incomplete headers: wait", Relay.parse("POST /api HTTP/1.1\r\nContent-Le"), nil)
eq("incomplete body: wait", Relay.parse("POST /api HTTP/1.1\r\nContent-Length: 10\r\n\r\n12345"), nil)
local req = Relay.parse("POST /api?k=abc&x=a%20b HTTP/1.1\r\nContent-Length: 4\r\n\r\n{}  trailing")
eq("method", req.method, "POST")
eq("path", req.path, "/api")
eq("query", req.query.k, "abc")
eq("percent decoding", req.query.x, "a b")
eq("body cut at Content-Length", req.body, "{}  ")
eq("garbage is BAD", Relay.parse("\0\1\2\r\n\r\n").method, "BAD")
eq("a huge header block is BAD", Relay.parse(string.rep("x", 17 * 1024)).method, "BAD")
eq(
  "a declared body over the limit is refused before it is read",
  Relay.parse("POST /api HTTP/1.1\r\nContent-Length: 99999999\r\n\r\n").method,
  "TOO_LARGE"
)
-- chunked arrival: the driver appends and re-parses
local whole = "POST /api HTTP/1.1\r\nContent-Length: 2\r\n\r\n{}"
local buffer, parsed = "", nil
for i = 1, #whole do
  buffer = buffer .. whole:sub(i, i)
  parsed = Relay.parse(buffer)
  if i < #whole then
    check("byte " .. i .. ": still waiting", parsed == nil)
  end
end
eq("complete after the last byte", parsed.body, "{}")

-- the driver's receiver: chunks are kept apart and joined once
print("chunked receive")
local rx = Relay.receiver()
local bodyText = string.rep("x", 300000)
local big = "POST /api HTTP/1.1\r\nContent-Length: " .. #bodyText .. "\r\n\r\n" .. bodyText
local got, fed = nil, 0
for i = 1, #big, 8192 do
  got = Relay.feed(rx, big:sub(i, i + 8191))
  fed = fed + 1
  if i + 8192 <= #big then
    check("chunk " .. fed .. " of a large upload: still waiting", got == nil)
  end
end
eq("a large upload is complete after its last chunk", got and #got.body, #bodyText)
check("...and was not re-joined on every chunk", #rx.parts > 20, #rx.parts)
eq(
  "a byte-at-a-time header still parses",
  (function()
    local r2, out = Relay.receiver(), nil
    local text = "GET /ping HTTP/1.1\r\nHost: x\r\n\r\n"
    for i = 1, #text do
      out = Relay.feed(r2, text:sub(i, i))
    end
    return out and out.path
  end)(),
  "/ping"
)
eq(
  "an oversize declaration is refused at the header, before the body arrives",
  Relay.feed(Relay.receiver(), "POST /api HTTP/1.1\r\nContent-Length: 99999999\r\n\r\n").method,
  "TOO_LARGE"
)
eq(
  "an endless header is refused",
  (function()
    local r3, out = Relay.receiver(), nil
    for _ = 1, 40 do
      out = out or Relay.feed(r3, string.rep("h", 512))
    end
    return out and out.method
  end)(),
  "BAD"
)
eq("the request limit is the protocol's", Relay.MAX_BODY, Protocol.MAX_REQUEST_BYTES)

-- ── routes ──────────────────────────────────────────────────────────────────
print("routes")
eq("GET /ping", http("GET", "/ping").status, "200 OK")
eq("ping body", http("GET", "/ping").body, '{"ok":true,"service":"venueflow"}')
eq("POST /ping", http("POST", "/ping").status, "405 Method Not Allowed")
local page = http("GET", "/app")
eq("GET /app", page.status, "200 OK")
check("the page is HTML", page.contentType:find("text/html", 1, true) ~= nil)
check("the app page is the operator page", page.body:find("<title>app</title>", 1, true) ~= nil)
check("the studio page is the Studio", http("GET", "/studio").body:find("<title>studio</title>", 1, true) ~= nil)
local rendered = Relay.render(page)
check("pages carry a Content-Security-Policy", rendered:find("Content%-Security%-Policy: default%-src 'none'") ~= nil)
check("the policy lets pages talk only to the relay", rendered:find("connect%-src 'self'") ~= nil)
check("pages are not sniffed", rendered:find("X-Content-Type-Options: nosniff", 1, true) ~= nil)
check("nothing is cached", rendered:find("Cache-Control: no-store", 1, true) ~= nil)
check("the length is exact", rendered:find("Content%-Length: " .. #page.body .. "\r\n") ~= nil)
eq("OPTIONS preflight", http("OPTIONS", "/api").status, "204 No Content")
eq("unknown path", http("GET", "/config").status, "404 Not Found")
eq("no state route outside the protocol", http("GET", "/state").status, "404 Not Found")
eq("no edit route outside the protocol", http("POST", "/edit", "{}").status, "404 Not Found")
eq("no file route", http("GET", "/../driver.lua").status, "404 Not Found")
eq("GET /api", http("GET", "/api").status, "405 Method Not Allowed")
eq("a body that is not JSON", http("POST", "/api", "sourceId=sports-1").status, "400 Bad Request")
eq("a JSON body that is not an object", http("POST", "/api", '"hello"').status, "400 Bad Request")
eq(
  "a page that fails to load is a 503, not a crash",
  Relay.route(Relay.parse("GET /app HTTP/1.1\r\n\r\n"), {
    page = function()
      error("no page")
    end,
  }).status,
  "503 Service Unavailable"
)
eq(
  "a handler that throws is a 500, not a crash",
  (function()
    local d = deps()
    d.handle = function()
      error("boom")
    end
    return Relay.route(Relay.parse("POST /api HTTP/1.1\r\nContent-Length: 2\r\n\r\n{}"), d).status
  end)(),
  "500 Internal Server Error"
)
eq("oversize reaches the client as 413", Relay.route({ method = "TOO_LARGE" }, {}).status, "413 Payload Too Large")

-- ── identity over HTTP ──────────────────────────────────────────────────────
print("identity")
local res, body = api("HELLO", {})
eq("HELLO without a token: sign-in needed", body.data.needsSignIn, true)
res, body = api("HELLO", {}, { k = TILE_TOKEN })
eq("HELLO with the tile token: the default profile", body.data.profile.id, "bartender")
res, body = api("HELLO", {}, { k = "wrongtoken0123456789abcd" })
eq("a wrong tile token is no identity", body.data.needsSignIn, true)
res, body = api("HELLO", {}, { k = "" })
eq("an empty tile token is no identity", body.data.needsSignIn, true)
eq(
  "a short configured token never matches",
  (function()
    local d = deps()
    d.tileToken = "short"
    local out = Relay.route(
      Relay.parse(
        'POST /api?k=short HTTP/1.1\r\nContent-Length: 44\r\n\r\n{"requestId":"x1","command":"HELLO","payload":{}}'
      ),
      d
    )
    return out.status
  end)(),
  "400 Bad Request"
) -- (the body above is deliberately truncated by Content-Length)
res, body = api("ROUTE_VIDEO", { sourceId = "sports-1", displayIds = { "tv-01" } })
eq("control without identity", body.errorCode, "VF_UNAUTHENTICATED")
res, body = api("ROUTE_VIDEO", { sourceId = "sports-1", displayIds = { "tv-01" } }, { k = TILE_TOKEN })
eq("control with the tile token", body.status, "accepted")
eq("HTTP status of a protocol reply is 200 either way", res.status, "200 OK")
res, body = api("DRAFT_GET", {}, { k = TILE_TOKEN })
eq("the tile token opens no configuration", body.errorCode, "VF_UNAUTHENTICATED")
res, body = api("STUDIO_LOGIN", { passcode = env.passcode })
local studio = body.data.session
res, body = api("DRAFT_GET", {}, { session = studio })
eq("a studio session over HTTP", body.ok, true)
env.settle(1500)

-- Every command of the protocol, with no identity, over the wire.
for name, spec in pairs(Protocol.COMMANDS) do
  if spec.scope ~= "public" then
    res, body = api(name, {})
    check(name .. " is closed to an unauthenticated caller", body.ok == false, body.errorCode)
  end
end
check(
  "every protocol command has a handler",
  (function()
    for name in pairs(Protocol.COMMANDS) do
      if type(CoreModule.HANDLERS[name]) ~= "function" then
        return false
      end
    end
    return true
  end)()
)
check(
  "every handler is a protocol command",
  (function()
    for name in pairs(CoreModule.HANDLERS) do
      if Protocol.COMMANDS[name] == nil then
        return false
      end
    end
    return true
  end)()
)

-- ── the raw picture upload route ────────────────────────────────────────────
print("picture upload")
local function upload(session, body, method)
  local raw = string.format(
    "%s /image HTTP/1.1\r\nHost: c4\r\nContent-Type: text/plain\r\n%sContent-Length: %d\r\n\r\n%s",
    method or "POST",
    session and ("X-VF-Session: " .. session .. "\r\n") or "",
    #body,
    body
  )
  local out = Relay.route(Relay.parse(raw), deps())
  return JSON:decode(out.body), out
end
local picture = "data:image/jpeg;base64," .. string.rep("/9j/4AAQSkZJRg", 20000) -- about 280 kB
local started = os.clock()
local up = upload(studio, picture)
check("a picture is stored from a raw body", up.ok and type(up.data.key) == "string", up.errorCode)
check("...without going through the JSON decoder (fast)", os.clock() - started < 1.5, os.clock() - started)
eq(
  "the session header is read from the request",
  Relay.parse("POST /image HTTP/1.1\r\nX-VF-Session: abc-123_x\r\nContent-Length: 0\r\n\r\n").session,
  "abc-123_x"
)
eq("no session: refused", upload(nil, picture).errorCode, "VF_UNAUTHENTICATED")
eq("...with no installer detail in the reply", upload(nil, picture).detail, nil)
eq("...nor for a staff session", upload(env.login("manager", "2580"), picture).detail, nil)
check("an installer does get the detail", type(upload(studio, "").detail) == "string")
eq("a made-up session: refused", upload(string.rep("f", 64), picture).errorCode, "VF_UNAUTHENTICATED")
eq("a staff session cannot upload", upload(env.login("manager", "2580"), picture).errorCode, "VF_UNAUTHENTICATED")
eq("the tile token is not a session", upload(TILE_TOKEN, picture).errorCode, "VF_UNAUTHENTICATED")
eq("not a picture", upload(studio, "<html>hello</html>").errorCode, "VF_INVALID_PAYLOAD")
eq("an SVG is refused", upload(studio, "data:image/svg+xml;base64,PHN2Zz4=").errorCode, "VF_INVALID_PAYLOAD")
eq("an empty body", upload(studio, "").errorCode, "VF_INVALID_PAYLOAD")
eq("too large", upload(studio, "data:image/png;base64," .. string.rep("A", 700 * 1024)).errorCode, "VF_TOO_LARGE")
eq("GET /image is not a route", select(2, upload(studio, "", "GET")).status, "405 Method Not Allowed")
check("an upload reply carries no installer detail it should not", up.detail == nil)
check(
  "the stored picture can be read back",
  env.send("IMAGE_GET", { key = up.data.key }, { session = studio }).data.dataUrl == picture
)
check(
  "CORS lets the page send the session header",
  Relay.render({ status = "204 No Content", contentType = "application/json", body = "" })
    :find("Access-Control-Allow-Headers: Content-Type, X-VF-Session", 1, true) ~= nil
)

-- ── invalid command payloads ────────────────────────────────────────────────
print("invalid payloads")
local function refused(request)
  local reply = env.core:handle(request, { tile = true })
  return reply.errorCode, reply
end
eq("not an object", refused("ROUTE_VIDEO"), "VF_BAD_REQUEST")
eq("no requestId", refused({ command = "PING" }), "VF_BAD_REQUEST")
eq("a requestId with odd characters", refused({ requestId = "a b<c>", command = "PING" }), "VF_BAD_REQUEST")
eq("an overlong requestId", refused({ requestId = string.rep("r", 65), command = "PING" }), "VF_BAD_REQUEST")
eq("no command", refused({ requestId = "x" }), "VF_BAD_REQUEST")
eq("unknown command", refused({ requestId = "x", command = "FORMAT_CONTROLLER" }), "VF_UNKNOWN_COMMAND")
eq("payload not an object", refused({ requestId = "x", command = "PING", payload = "p" }), "VF_INVALID_PAYLOAD")
eq(
  "missing field",
  refused({ requestId = "x", command = "ROUTE_VIDEO", payload = { sourceId = "sports-1" } }),
  "VF_INVALID_PAYLOAD"
)
eq(
  "wrong type",
  refused({ requestId = "x", command = "AUDIO_VOLUME", payload = { zoneId = "zone-bar", level = "loud" } }),
  "VF_INVALID_PAYLOAD"
)
eq(
  "not a finite number",
  refused({ requestId = "x", command = "AUDIO_VOLUME", payload = { zoneId = "zone-bar", level = 0 / 0 } }),
  "VF_INVALID_PAYLOAD"
)
eq(
  "a map where a list is expected",
  refused({ requestId = "x", command = "ROUTE_VIDEO", payload = { sourceId = "s", displayIds = { a = "tv-01" } } }),
  "VF_INVALID_PAYLOAD"
)
eq(
  "a list of non-ids",
  refused({ requestId = "x", command = "ROUTE_VIDEO", payload = { sourceId = "s", displayIds = { 1, 2 } } }),
  "VF_INVALID_PAYLOAD"
)
eq(
  "an unexpected field",
  refused({ requestId = "x", command = "AUDIO_MUTE", payload = { zoneId = "zone-bar", muted = true, force = true } }),
  "VF_INVALID_PAYLOAD"
)
eq(
  "a value outside the allowed set",
  refused({ requestId = "x", command = "VENUE_STATUS", payload = { status = "party" } }),
  "VF_INVALID_PAYLOAD"
)
eq(
  "PUBLISH may acknowledge many warnings (a large unmapped venue)",
  (function()
    local many = {}
    for i = 1, 600 do
      many[i] = "DISPLAY_UNMAPPED:displays[" .. i .. "].c4RoomId"
    end
    local reply = env.core:handle(
      { requestId = "x", command = "PUBLISH", payload = { acknowledged = many } },
      { tile = true }
    )
    return reply.errorCode
  end)(),
  "VF_UNAUTHENTICATED"
) -- past validation: refused for identity, not for size
eq(
  "a list that is too long",
  (function()
    local many = {}
    for i = 1, 300 do
      many[i] = "tv-" .. i
    end
    return refused({
      requestId = "x",
      command = "ROUTE_VIDEO",
      payload = { sourceId = "sports-1", displayIds = many },
    })
  end)(),
  "VF_INVALID_PAYLOAD"
)
eq(
  "an overlong string",
  refused({ requestId = "x", command = "AUDIO_SOURCE", payload = { zoneId = string.rep("z", 5000), sourceId = "s" } }),
  "VF_TOO_LARGE"
)
eq("ts must be a number", refused({ requestId = "x", command = "PING", ts = "now" }), "VF_BAD_REQUEST")
local _, reply = refused({ requestId = "keep-me", command = "NOPE" })
eq("a refusal echoes the request id", reply.requestId, "keep-me")
check("a refusal has an operator sentence", type(reply.message) == "string" and #reply.message > 5)
check("a refusal carries no internal detail for a page", reply.detail == nil)
check(
  "refused requests are in diagnostics",
  (function()
    for _, e in ipairs(env.core.diag:list({ limit = 60, category = "webview" })) do
      if e.code == "VF_UNKNOWN_COMMAND" then
        return true
      end
    end
    return false
  end)()
)
for code, entry in pairs(Errors.CODES) do
  check(
    code .. " has an operator sentence and a status",
    type(entry.operator) == "string" and type(entry.http) == "number"
  )
end
eq(
  "an unknown code is reported as internal, never passed through",
  Errors.fail("VF_MADE_UP", "x").errorCode,
  "VF_INTERNAL"
)

-- ── state delivery ──────────────────────────────────────────────────────────
print("state delivery")
res, body = api("GET_STATE", {}, { k = TILE_TOKEN })
local version = body.data.state.version
eq("the reply names the state version", body.stateVersion, version)
res, body = api("GET_STATE", {}, { k = TILE_TOKEN, since = version })
eq("nothing changed: a small reply", body.data.unchanged, true)
check("...of a few hundred bytes at most", #res.body < 400, #res.body)
res, body = api("AUDIO_VOLUME", { zoneId = "zone-bar", level = 41 }, { k = TILE_TOKEN, since = version })
check(
  "a command reply carries the new state when the page is behind",
  body.state ~= nil and body.state.version > version
)
eq("...with the pending cell in it", body.state.zones["zone-bar"].volume.status, "pending")
env.settle(1500)
res, body = api("GET_STATE", {}, { k = TILE_TOKEN, since = version })
eq("after feedback the cell is confirmed", body.data.state.zones["zone-bar"].volume.status, "confirmed")
check(
  "recent operations are in the state",
  #body.data.state.operations >= 1 and body.data.state.operations[1].done == true
)

T.done()
