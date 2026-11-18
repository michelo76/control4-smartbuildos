-- TEST FIXTURE (never shipped, never packaged): a minimal module driver that
-- speaks contract v2 through the real sbos.moduleclient, so the Director
-- emulator scenario (test/emulator/module_contract_v2.lua) can run the real
-- Agent and real module code end to end. Property "Role":
--   provider → registers as flight_recorder, serves events.query, emits capture.*
--   consumer → registers as ai_core, drives discover / subscribe / request / cloud
-- Results are kept in the global PROBE for the scenario to read (dev.env.PROBE).
require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")
JSON = require("JSON")
local client = require("sbos.moduleclient")

PROBE = { answers = {}, events = {}, served = 0, changes = 0, states = {}, subscribed = nil, directory = nil }

function OnDriverLateInit()
  local provider = Properties["Role"] == "provider"
  client.setup({
    module_id = provider and "flight_recorder" or "ai_core",
    driver_version = "probe",
    entitlements = {},
    event_types = provider and { "capture." } or { "ai_core." },
    singleton = true,
    require_protocol = 2,
    manifest = provider and {
      driver = "sbos.probe_provider",
      capabilities = {
        { id = "events.query", version = 1, kind = "request" },
        { id = "events.subscribe", version = 1, kind = "topic", topics = { "capture." } },
      },
    } or { driver = "sbos.probe_consumer", capabilities = {} },
    status = function()
      return "running", "", {}
    end,
    onAgentState = function(_, why)
      PROBE.states[#PROBE.states + 1] = why
    end,
    onDirectoryChanged = function()
      PROBE.changes = PROBE.changes + 1
    end,
  })
  if provider then
    client.onRequest("events.query", function(req, respond)
      PROBE.served = PROBE.served + 1
      respond("ok", { events = { { n = 1 } }, asked_by = req.from_module_id })
    end)
  end
  client.register()
end

function OnDriverDestroyed()
  client.stop()
end

local function record(tag)
  return function(answer)
    PROBE.answers[tag] = answer
  end
end

function EC.PROBE_DISCOVER()
  client.discover(nil, function(dir, code)
    PROBE.directory = dir
    PROBE.directory_code = code
  end)
end

function EC.PROBE_SUBSCRIBE(p)
  client.subscribe(p.ID or "probe", { p.TOPIC or "capture." }, function(events, dropped)
    for _, e in ipairs(events) do
      PROBE.events[#PROBE.events + 1] = e
    end
    PROBE.dropped = (PROBE.dropped or 0) + dropped
  end, function(ok, reason)
    PROBE.subscribed = ok and "ok" or reason
  end)
end

function EC.PROBE_REQUEST(p)
  client.request(p.TO or "flight_recorder", p.CAPABILITY or "events.query", { limit = 1 }, {
    timeout = tonumber(p.TIMEOUT) or 10,
    idempotency_key = p.KEY,
  }, record(p.TAG or "request"))
end

function EC.PROBE_CLOUD(p)
  client.cloudRequest(p.OP or "ask", { question = "probe" }, { idempotency_key = p.KEY }, record(p.TAG or "cloud"))
end

function EC.PROBE_INFO()
  PROBE.protocol = client.protocol()
  PROBE.display = client.displayStatus()
  PROBE.registered = client.isRegistered()
end

function EC.PROBE_EMIT(p)
  local env = client.event({
    event_type = p.TYPE or "capture.device",
    evidence_source = "observed",
    payload = { n = tonumber(p.N) or 0 },
  })
  client.sendEvents({ env })
  client.flush()
end
