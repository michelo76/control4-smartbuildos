#!/usr/bin/env luajit
--- AI Core touchscreen page development host: the REAL page relay
--- (src/aicore/webui.lua) and the real page, driven over stdin/stdout by
--- tools/aicore-dev.py.
---
--- Everything around the relay is a stand-in: a scripted cloud that accepts
--- every ask and answers a few seconds later (some answers with chat v2
--- blocks and follow-up questions), a fake PIN Lock that checks a dev PIN
--- itself (the PIN never reaches the relay, as on a controller), fixed facts.
--- It is NOT evidence of controller, PIN Lock or cloud behaviour.
---
--- Protocol: one JSON object per line, in and out.
---   in   {"type":"tick","now":…}
---   in   {"type":"http","now":…,"method":"GET","path":"/state","query":{…},"body":"","host":"127.0.0.1"}
---   in   {"type":"verify","now":…,"body":"{\"challenge_id\":…,\"pin\":…}"}   (PIN Lock's /verify)
---   out  {"status":"200 OK","contentType":"application/json","body":"…"}
---
--- Environment:
---   AIC_DEV_TOKEN    the install token in the page URL (default below)
---   AIC_DEV_ACCESS   open (default) | owner_pin
---   AIC_DEV_DETAIL   standard (default) | household | basic
---   AIC_DEV_PINLOCK  ready (default) | missing
---   AIC_DEV_PIN      the owner PIN the fake PIN Lock accepts (default 2468)
---   AIC_DEV_DELAY    seconds before an answer arrives (default 3)
---
--- Dev-only routes (never in the driver), under /__dev:
---   POST /__dev/hold     {on}        hold every answer (the thinking state)
---   POST /__dev/advance  {seconds}   move the clock forward
---   POST /__dev/presets  {list}      the dealer's preset questions

package.path = "src/?.lua;vendor/?.lua;test/?.lua;" .. package.path
C4 = C4 or {}
require("c4_shim")
require("drivers-common-public.global.lib")

JSON = require("JSON")
local Webui = require("aicore.webui")
local PAGE = "drivers/smartbuildos-ai-core/www/app/index.html"

local TOKEN = os.getenv("AIC_DEV_TOKEN") or "aicoredev0123456789abcdef0123456"
local ACCESS = os.getenv("AIC_DEV_ACCESS") or "open"
local DETAIL = os.getenv("AIC_DEV_DETAIL") or "standard"
local PINLOCK = os.getenv("AIC_DEV_PINLOCK") or "ready"
local DEV_PIN = os.getenv("AIC_DEV_PIN") or "2468"
local DELAY = tonumber(os.getenv("AIC_DEV_DELAY") or "3") or 3

local clock, offset = 0, 0
local seq = 0
local host = "127.0.0.1"
local hold = false
local presets = { "Is the wine cellar at the right temperature?" }
local due = {} -- answers waiting to be delivered: { at, job, text, extra }
local challenges = {} -- [challenge_id] = { verified }

-- Chat actions (stand-ins for the platform's proposals): one per scenario.
local ACT = {
  lights = "aaaaaaaa-1111-4111-8111-111111111111", -- Confirm → Sent → Done
  den = "bbbbbbbb-2222-4222-8222-222222222222", -- Confirm → Sent → Failed
  scene = "cccccccc-3333-4333-8333-333333333333", -- tap_in 0: Use PIN from the start
}
local decided = {} -- [ref] = clock when approved

local function newHex()
  seq = seq + 1
  return string.format("%08x%08x%08x%08x", seq, math.random(0, 0x7fffffff), math.random(0, 0x7fffffff), seq * 7919)
end

--- The scripted answers: chosen by the question's words.
local function answerFor(q, ownerProof)
  q = q:lower()
  -- Actions are proposed only to an owner-unlocked ask (owner_proof), as on
  -- the platform.
  local function action(ref, title, detail, tapIn)
    if ownerProof == nil then
      return nil
    end
    return { { ref = ref, title = title, detail = detail, expires_in = 600, tap_in = tapIn or 300 } }
  end
  if q:find("patio") then
    return ownerProof and "I can turn off the 4 patio lights. Confirm below."
      or "Unlock with the owner PIN to change the lights from here.",
      { actions = action(ACT.lights, "Turn off the patio lights", "Patio string lights and the 3 wall lanterns") }
  end
  if q:find("den") then
    return "I can set the den thermostat to 21 °C. Confirm below.",
      { actions = action(ACT.den, "Set the den to 21 °C", "Den thermostat, heat set point") }
  end
  if q:find("movie") then
    return "I can start the Movie Night scene in the media room. Scenes need your PIN.",
      -- a scene: the PIN flow from the start (tap_in 0)
      { actions = action(ACT.scene, "Start Movie Night", "Media room: lights down, screen and projector on", 0) }
  end
  if q:find("temperat") or q:find("warm") or q:find("cellar") or q:find("climate") then
    return "The house is comfortable. The cellar is right on target and every room is within a degree of its set point.",
      {
        display = {
          { t = "stat", label = "Wine cellar", value = "13.2", unit = "°C", tone = "ok" },
          { t = "stat", label = "Outside", value = "4", unit = "°C", tone = "info" },
          {
            t = "list",
            title = "Rooms",
            items = {
              { label = "Living room", value = "21.5 °C", tone = "ok" },
              { label = "Kitchen", value = "22.0 °C", tone = "ok" },
              { label = "Primary bedroom", value = "19.0 °C", tone = "ok" },
              { label = "Basement gym", value = "17.5 °C", tone = "warn" },
            },
          },
        },
        suggestions = { "Why is the gym cooler?", "What is the cellar humidity?", "Is the gym heating working?" },
      }
  end
  if q:find("working") or q:find("attention") or q:find("door") or q:find("lock") then
    return "Almost everything is working. One thing needs a look: the garage door has been open since 4:12 pm.",
      {
        display = {
          {
            t = "list",
            title = "Doors and locks",
            items = {
              { label = "Front door", value = "Locked", tone = "ok" },
              { label = "Back door", value = "Locked", tone = "ok" },
              { label = "Garage door", value = "Open 2 h", tone = "warn" },
              { label = "Side gate", value = "No signal", tone = "bad" },
            },
          },
          {
            t = "note",
            text = "The side gate sensor has not reported since this morning; its battery may be low.",
            tone = "warn",
          },
        },
        suggestions = { "When did the garage open?", "Is the side gate battery low?" },
      }
  end
  return "Today was quiet. The lights followed their usual schedule, the house was set to Away from 9:05 am to 5:40 pm, and nothing reported a fault.",
    nil
end

local ui = Webui.new({
  now = function()
    return clock
  end,
  newHex = newHex,
  newRequestId = function()
    seq = seq + 1
    return "dev-" .. seq
  end,
  facts = function()
    return { licensed = true, provider_configured = true, online = true, learning_active = true }
  end,
  detail = function()
    return DETAIL
  end,
  access = function()
    return ACCESS
  end,
  relayHost = function()
    return host
  end,
  pinAvailability = function(cb)
    if PINLOCK == "ready" then
      cb({ available = true, reason = "ready" })
    else
      cb({ available = false, reason = "pin_not_installed" })
    end
  end,
  pinRequest = function(capability, args, cb)
    if capability == "pinlock.challenge" then
      local id = newHex()
      challenges[id] = { verified = false }
      cb({
        status = "ok",
        result = { challenge_id = id, expires_in = 60, verify_url = "http://" .. host .. ":47831/verify" },
      })
    else
      local c = challenges[args.challenge_id]
      challenges[args.challenge_id] = nil
      if c and c.verified then
        cb({ status = "ok", result = { verified = true, role = "owner", verified_at = math.floor(clock) } })
      else
        cb({ status = "ok", result = { verified = false, reason = "not_verified" } })
      end
    end
  end,
  cloud = function(op, body, cb)
    if op == "approval_detail" then
      local r = { ref = body.ref, title = "Proposal", risk = "low", args_hash = string.rep("ab", 32) }
      local at = decided[body.ref]
      if at ~= nil and body.verification and body.verification.method == "pin_lock_session" then
        if clock - at < 5 then
          r.execution = { state = "pending" }
        elseif body.ref == ACT.den then
          r.execution = {
            state = "failed",
            reason = "controller_failed",
            message = "The den thermostat did not accept the change.",
          }
        else
          r.execution = { state = "completed" }
        end
      end
      cb({ status = "ok", result = r })
      return
    end
    if op == "approval_decide" then
      if body.ref == ACT.scene and body.decision == "approve" and body.verification.method == "pin_lock_session" then
        cb({ status = "error", error_code = "not_permitted", result = { reason = "session_needs_pin" } })
        return
      end
      if body.decision == "approve" then
        decided[body.ref] = clock
      end
      cb({ status = "ok", result = { ref = body.ref, status = body.decision == "approve" and "queued" or "denied" } })
      return
    end
    if op ~= "ask" then
      cb({ status = "ok", result = { enabled = true, count = 2, eligible = {}, portal_only_count = 2 } })
      return
    end
    seq = seq + 1
    local job = "job-" .. seq
    local text, extra = answerFor(body.question or "", body.owner_proof)
    due[#due + 1] = { at = clock + DELAY, job = job, text = text, extra = extra }
    cb({ status = "ok", result = { accepted = true, job_id = job } })
  end,
  take = function()
    return true
  end,
  appHtml = function()
    local f = assert(io.open(PAGE, "rb"))
    local html = f:read("*a")
    f:close()
    local origin = string.format("http://%s:%d", host, Webui.PINLOCK_PORT)
    return (html:gsub("connect%-src 'self';", "connect-src 'self' " .. origin .. ";", 1))
  end,
  presets = function()
    return presets
  end,
})

local function tick()
  if hold then
    return
  end
  for i = #due, 1, -1 do
    local d = due[i]
    if clock >= d.at then
      table.remove(due, i)
      ui:deliver(nil, d.text, d.job, d.extra)
    end
  end
  ui:sweep()
end

local function dev(path, body)
  local ok, b = pcall(function()
    return JSON:decode(body ~= "" and body or "{}")
  end)
  b = ok and type(b) == "table" and b or {}
  if path == "/__dev/hold" then
    hold = b.on == true
  elseif path == "/__dev/advance" then
    offset = offset + (tonumber(b.seconds) or 0)
  elseif path == "/__dev/presets" then
    presets = type(b.list) == "table" and b.list or {}
  else
    return { status = "404 Not Found", contentType = "application/json", body = '{"ok":false}' }
  end
  return { status = "200 OK", contentType = "application/json", body = '{"ok":true}' }
end

io.stdout:setvbuf("line")
for line in io.lines() do
  local ok, msg = pcall(function()
    return JSON:decode(line)
  end)
  local out
  if not ok or type(msg) ~= "table" then
    out = { status = "400 Bad Request", contentType = "application/json", body = '{"ok":false}' }
  else
    clock = (tonumber(msg.now) or clock) + offset
    if msg.type == "tick" then
      tick()
      out = { ok = true }
    elseif msg.type == "verify" then
      -- The fake PIN Lock's /verify: the PIN is checked HERE, never by the relay.
      local okB, b = pcall(function()
        return JSON:decode(msg.body or "")
      end)
      local c = okB and type(b) == "table" and challenges[b.challenge_id] or nil
      local good = c ~= nil and b.pin == DEV_PIN
      if good then
        c.verified = true
      end
      out = { status = "200 OK", contentType = "application/json", body = JSON:encode({ ok = good }) }
    elseif type(msg.path) == "string" and msg.path:find("^/__dev/") then
      out = dev(msg.path, msg.body or "")
    else
      if type(msg.host) == "string" and msg.host:match("^[%w%.%-]+$") then
        host = msg.host
      end
      tick()
      out = ui:route({ method = msg.method, path = msg.path, query = msg.query or {}, body = msg.body or "" }, TOKEN)
    end
  end
  io.stdout:write(JSON:encode(out), "\n")
  io.stdout:flush()
end
