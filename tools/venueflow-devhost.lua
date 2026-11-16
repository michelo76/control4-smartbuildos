#!/usr/bin/env luajit
--- VenueFlow development host: the REAL core and relay router, on the
--- simulator, driven over stdin/stdout by tools/venueflow-dev.py.
---
--- This is how the pages are developed and browser-tested without a
--- controller. It runs the same Lua the driver ships (core.lua, relay.lua and
--- everything under them); only the socket, the clock, persistence and the
--- Control4 adapter are stand-ins. It proves nothing about a real controller.
---
--- Protocol: one JSON line of metadata, then `bytes` raw bytes of body.
---   in   {"type":"tick","ms":100,"bytes":0}                    advance timers
---   in   {"type":"http","method":"POST","path":"/api","query":{...},"session":"...","client":"127.0.0.1","bytes":123}<body>
---   out  {"status":"200 OK","contentType":"...","headers":[...],"bytes":456}<body>
---
--- Environment:
---   VF_DEV_STATE    file holding the fake controller persistence (JSON); kept between runs
---   VF_DEV_SAMPLE   sports_bar | conference_center : publish that reference venue when nothing is published
---   VF_DEV_PASSCODE Installer Passcode for the dev host (default below)
---   VF_DEV_TILE     tile token (default below)

package.path = "src/?.lua;vendor/?.lua;test/?.lua;" .. package.path

local JSON = require("JSON")
local Core = require("venueflow.core")
local Relay = require("venueflow.relay")
local H = require("venueflow_harness")

local STATE_FILE = os.getenv("VF_DEV_STATE") or "build/venueflow-dev-state.json"
local SAMPLE = os.getenv("VF_DEV_SAMPLE") or ""
local PASSCODE = os.getenv("VF_DEV_PASSCODE") or "install-123"
local TILE = os.getenv("VF_DEV_TILE") or "devtile0123456789abcdef"

local function log(...)
  io.stderr:write(string.format(...) .. "\n")
  io.stderr:flush()
end

-- ── persistence: one JSON file ──────────────────────────────────────────────
local data = {}
do
  local f = io.open(STATE_FILE, "rb")
  if f then
    local text = f:read("*a")
    f:close()
    local ok, decoded = pcall(function()
      return JSON:decode(text)
    end)
    if ok and type(decoded) == "table" then
      data = decoded
    end
  end
end
local dirty = false
local kv = H.kv(data)
local rawSet, rawDelete = kv.set, kv.delete
kv.set = function(k, v)
  rawSet(k, v)
  dirty = true
end
kv.delete = function(k)
  rawDelete(k)
  dirty = true
end
local function flush()
  if not dirty then
    return
  end
  dirty = false
  local f = io.open(STATE_FILE, "wb")
  if f then
    f:write(JSON:encode(data))
    f:close()
  end
end

-- ── clock and timers (real time, advanced by ticks) ─────────────────────────
local clock = H.clock(os.time())
clock.now = function()
  return os.time()
end

local seq = 0
local mode = "simulation"
local core = Core.new({
  kv = kv,
  now = clock.now,
  localtime = function(epoch)
    return os.date("*t", epoch)
  end,
  timers = clock.api,
  json = {
    encode = function(t)
      return JSON:encode(t)
    end,
    decode = function(s)
      return JSON:decode(s)
    end,
  },
  hmac = H.hmac,
  random = function()
    seq = seq + 1
    return H.hmac("dev-random", tostring(seq) .. ":" .. tostring(os.time()) .. ":" .. tostring(os.clock()))
  end,
  liveAdapter = function()
    error("the development host has no Control4")
  end,
  mode = function()
    return mode
  end,
  license = {
    enforces = function()
      return os.getenv("VF_DEV_RESTRICT") == "1"
    end,
    label = function()
      return os.getenv("VF_DEV_RESTRICT") == "1" and "Agent Linked - Not Licensed (see SmartBuildOS)"
        or "Development host (no Agent)"
    end,
    describe = function()
      return { status = "LEGACY", source = "-", tier = "-", company = "-", agent = "development host" }
    end,
    refresh = function() end,
  },
  passcode = function()
    return PASSCODE
  end,
  fireEvent = function(key)
    log("[event] %s", tostring(key))
  end,
  record = function(name, detail)
    log("[record] %s: %s", tostring(name), tostring(detail))
  end,
  info = function()
    return { relay = "development host", port = tonumber(os.getenv("VF_DEV_PORT")) or 47861, host = "localhost" }
  end,
  version = "dev",
  queueSpacingMs = 120,
  simLatencyMs = 700,
})
core:start()

if SAMPLE ~= "" and core.config == nil then
  local function send(command, payload, session)
    return core:handle(
      { requestId = "boot", command = command, payload = payload, session = session },
      { tile = false, client = "boot", via = "relay" }
    )
  end
  local login = send("STUDIO_LOGIN", { passcode = PASSCODE })
  local t = send("TEMPLATE_APPLY", { venueType = SAMPLE, sample = true, confirm = true }, login.data.session)
  if t.ok then
    local acks = {}
    for _, i in ipairs(t.data.draft.issues) do
      acks[#acks + 1] = i.id
    end
    local p = send("PUBLISH", { acknowledged = acks, note = "development sample" }, login.data.session)
    log("[boot] published sample %s: %s", SAMPLE, tostring(p.ok))
  else
    log("[boot] sample failed: %s %s", tostring(t.errorCode), tostring(t.detail))
  end
  send("LOGOUT", {}, login.data.session)
end

local function readPage(name)
  local f = io.open("drivers/smartbuildos-venueflow/www/" .. name .. "/index.html", "rb")
  if f == nil then
    return nil
  end
  local html = f:read("*a")
  f:close()
  return html
end

log("[devhost] ready; state in %s", STATE_FILE)

-- Framing: one JSON line of metadata, then exactly `bytes` raw bytes of body
-- (both ways). The body is never put inside JSON here either: this host must
-- treat a large upload the way the driver's socket does.
local function reply(out)
  local body = out.body or ""
  out.body = nil
  out.bytes = #body
  io.stdout:write(JSON:encode(out) .. "\n")
  if #body > 0 then
    io.stdout:write(body)
  end
  io.stdout:flush()
end

while true do
  local line = io.read("*l")
  if line == nil then
    break
  end
  local ok, msg = pcall(function()
    return JSON:decode(line)
  end)
  local body = ""
  if ok and type(msg) == "table" and (tonumber(msg.bytes) or 0) > 0 then
    body = io.read(tonumber(msg.bytes)) or ""
  end
  local out
  if not ok or type(msg) ~= "table" then
    out = { status = "400 Bad Request", contentType = "application/json", body = '{"ok":false}' }
  elseif msg.type == "tick" then
    local okTick, err = pcall(clock.advance, tonumber(msg.ms) or 100)
    if not okTick then
      log("[devhost] timer error: %s", tostring(err))
    end
    flush()
    out = { tick = true }
  else
    local okRoute, result = pcall(Relay.route, {
      method = msg.method,
      path = msg.path,
      query = type(msg.query) == "table" and msg.query or {},
      body = body,
      session = msg.session,
    }, {
      tileToken = TILE,
      handle = function(request, transport)
        return core:handle(request, transport)
      end,
      upload = function(session, dataUrl, transport)
        return core:upload(session, dataUrl, transport)
      end,
      encode = function(t)
        return JSON:encode(t)
      end,
      decode = function(text)
        return JSON:decode(text)
      end,
      page = readPage,
      client = msg.client or "127.0.0.1",
    })
    if okRoute then
      out = result
    else
      log("[devhost] route error: %s", tostring(result))
      out = { status = "500 Internal Server Error", contentType = "application/json", body = '{"ok":false}' }
    end
    flush()
  end
  reply(out)
end
