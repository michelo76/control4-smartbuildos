-- Tests for src/atmosphere/uirelay.lua — the LAN state relay's pure half.
--
-- Invariants:
--   * Chunk-safe parsing: a POST split across arbitrary chunk boundaries
--     assembles; incomplete requests return nil, never a wrong answer.
--   * /ping is tokenless; EVERYTHING else 403s without the exact token.
--   * Routing: state JSON round-trips, settings apply with refusals
--     reported, wrong methods 405, unknown paths 404, malformed 400.
--   * Rendered responses carry no-store + CORS and exact Content-Length.
--
-- Run from the driver root: make test

local pass, fail = 0, 0
local function check(name, ok, detail)
  if ok then
    pass = pass + 1
    print(string.format("  ok   %s", name))
  else
    fail = fail + 1
    print(string.format("  FAIL %s%s", name, detail and ("  -> " .. tostring(detail)) or ""))
  end
end

local JSON = require("JSON")
local uirelay = require("atmosphere.uirelay")

local TOKEN = "abc123token"

local appliedPatches = {}
local refreshed = 0
local simulated = {}
local provider = {
  state = function()
    return '{"v":1,"mode":"RAIN"}'
  end,
  applySettings = function(bodyText)
    local doc = JSON:decode(bodyText)
    local patch = type(doc.settings) == "table" and doc.settings or doc
    appliedPatches[#appliedPatches + 1] = patch
    if patch.bad ~= nil then
      return { { path = "bad", reason = "unknown setting" } }
    end
    return {}
  end,
  refresh = function()
    refreshed = refreshed + 1
  end,
  simulate = function(scenario)
    simulated[#simulated + 1] = scenario
    return scenario ~= "sharknado"
  end,
  encode = function(t)
    return JSON:encode(t)
  end,
  decode = function(s)
    return JSON:decode(s)
  end,
}

-- ─── parse ────────────────────────────────────────────────────────────────────

check("incomplete headers -> nil", uirelay.parse("GET /state HTTP/1.1\r\nHost: x") == nil)
local getReq = uirelay.parse("GET /state?k=abc123token&x=1 HTTP/1.1\r\nHost: c\r\n\r\n")
check("GET parses", getReq ~= nil and getReq.method == "GET" and getReq.path == "/state")
check("query parses", getReq ~= nil and getReq.query.k == TOKEN and getReq.query.x == "1")
check("percent-decoding in query", uirelay.parse("GET /a?u=http%3A%2F%2Fx HTTP/1.1\r\n\r\n").query.u == "http://x")

local postFull = 'POST /settings?k=abc123token HTTP/1.1\r\nContent-Length: 26\r\n\r\n{"settings":{"junk":true}}'
local postReq = uirelay.parse(postFull)
check("POST with body parses", postReq ~= nil and postReq.body == '{"settings":{"junk":true}}')
check("POST body short -> nil (still arriving)", uirelay.parse(postFull:sub(1, #postFull - 5)) == nil)
-- chunk reassembly across every split point of the body
local reassembled = true
for cut = #postFull - 25, #postFull - 1 do
  local a = uirelay.parse(postFull:sub(1, cut))
  if a ~= nil then
    reassembled = false
  end
  local b = uirelay.parse(postFull)
  if b == nil or b.body ~= '{"settings":{"junk":true}}' then
    reassembled = false
  end
end
check("every body split point reassembles", reassembled)
check("malformed request line -> BAD", uirelay.parse("NONSENSE\r\n\r\n").method == "BAD")

-- ─── routing: token wall ──────────────────────────────────────────────────────

local function go(raw)
  return uirelay.route(uirelay.parse(raw), TOKEN, provider)
end

check("ping needs no token", go("GET /ping HTTP/1.1\r\n\r\n").status == "200 OK")
provider.appHtml = function()
  return "<title>App</title>" .. string.rep("x", 40)
end
local appResp = go("GET /app HTTP/1.1\r\n\r\n")
check(
  "app served tokenless as html",
  appResp.status == "200 OK" and appResp.contentType:find("text/html", 1, true) ~= nil
)
provider.appHtml = function()
  return nil
end
check("app unavailable is 503", go("GET /app HTTP/1.1\r\n\r\n").status == "503 Service Unavailable")
check("preflight OPTIONS is 204 without token", go("OPTIONS /settings HTTP/1.1\r\n\r\n").status == "204 No Content")
check(
  "preflight headers rendered",
  uirelay.render(go("OPTIONS /settings HTTP/1.1\r\n\r\n")):find("Access%-Control%-Allow%-Methods: GET, POST, OPTIONS")
    ~= nil
)
check("state without token 403", go("GET /state HTTP/1.1\r\n\r\n").status == "403 Forbidden")
check("state with wrong token 403", go("GET /state?k=nope HTTP/1.1\r\n\r\n").status == "403 Forbidden")
check(
  "empty configured token refuses everything",
  uirelay.route(uirelay.parse("GET /state?k= HTTP/1.1\r\n\r\n"), "", provider).status == "403 Forbidden"
)

-- ─── routing: behavior ────────────────────────────────────────────────────────

local stateResp = go("GET /state?k=abc123token HTTP/1.1\r\n\r\n")
check("state 200 with provider JSON", stateResp.status == "200 OK" and stateResp.body:find("RAIN") ~= nil)
check(
  "state POST is 405",
  go("POST /state?k=abc123token HTTP/1.1\r\nContent-Length: 0\r\n\r\n").status == "405 Method Not Allowed"
)
check("settings GET is 405", go("GET /settings?k=abc123token HTTP/1.1\r\n\r\n").status == "405 Method Not Allowed")
check("unknown path 404", go("GET /nope?k=abc123token HTTP/1.1\r\n\r\n").status == "404 Not Found")
check("malformed 400", go("NONSENSE\r\n\r\n").status == "400 Bad Request")

local okSettings = go('POST /settings?k=abc123token HTTP/1.1\r\nContent-Length: 26\r\n\r\n{"settings":{"junk":true}}')
check("settings applied", okSettings.status == "200 OK" and #appliedPatches == 1)
local refusedSettings = go('POST /settings?k=abc123token HTTP/1.1\r\nContent-Length: 12\r\n\r\n{"bad":true}')
check("settings refusals reported", refusedSettings.body:find("unknown setting") ~= nil)
check(
  "settings garbage body 422",
  go("POST /settings?k=abc123token HTTP/1.1\r\nContent-Length: 5\r\n\r\njunk!").status == "422 Unprocessable Entity"
)

check(
  "refresh runs",
  go("POST /refresh?k=abc123token HTTP/1.1\r\nContent-Length: 0\r\n\r\n").status == "200 OK" and refreshed == 1
)
check(
  "simulate starts scenario",
  go('POST /simulate?k=abc123token HTTP/1.1\r\nContent-Length: 24\r\n\r\n{"scenario":"tornado_w"}').status == "200 OK"
    and simulated[#simulated] == "tornado_w"
)
check(
  "simulate unknown 422",
  go('POST /simulate?k=abc123token HTTP/1.1\r\nContent-Length: 24\r\n\r\n{"scenario":"sharknado"}').status
    == "422 Unprocessable Entity"
)
check(
  "simulate empty scenario stops (200)",
  go('POST /simulate?k=abc123token HTTP/1.1\r\nContent-Length: 15\r\n\r\n{"scenario":""}').status == "200 OK"
)

-- ─── render ───────────────────────────────────────────────────────────────────

local rendered = uirelay.render({ status = "200 OK", contentType = "application/json", body = '{"a":1}' })
check("render status line", rendered:find("^HTTP/1.1 200 OK\r\n") ~= nil)
check("render content-length exact", rendered:find("Content%-Length: 7\r\n") ~= nil)
check("render no-store", rendered:find("Cache%-Control: no%-store") ~= nil)
check("render CORS", rendered:find("Access%-Control%-Allow%-Origin: %*") ~= nil)
check("render body last", rendered:sub(-7) == '{"a":1}')

-- ─── result ───────────────────────────────────────────────────────────────────

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
