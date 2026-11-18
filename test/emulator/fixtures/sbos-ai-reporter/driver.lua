-- TEST FIXTURE (never shipped, never packaged): a root driver that reports to
-- AI Core through the REAL helper (sbos.aireport, start mode), so the
-- Director emulator scenario test/emulator/ai_core_reports.lua can run the
-- real Agent, the real AI Core and real reporters end to end. The run script
-- assembles two copies under the file names of two reserved roots
-- (smartbuildos-atmosphere.c4z, smartbuildos-mode-composer.c4z) and sets
-- "Reporter File" to match, so the Agent's identity binding verifies them.
-- What the scenario reads: the global FIXTURE (dev.env.FIXTURE).
require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")
JSON = require("JSON")
local aireport = require("sbos.aireport")
local client = require("sbos.moduleclient")

FIXTURE = { aireport = aireport, queries = 0, actions = 0, jams = 0, level = nil, raw = {} }

function OnDriverLateInit()
  local file = Properties["Reporter File"]
  aireport.declareQuery({ id = "current_value", description = "The fixture's current value.", params = {} }, function()
    FIXTURE.queries = FIXTURE.queries + 1
    return { value = 42, file = file }
  end)
  aireport.declareAction({
    id = "set_level",
    title = "Set level",
    description = "Sets the fixture's level.",
    params = { { name = "level", type = "integer", min = 0, max = 100, required = true } },
    risk = "low",
  }, function(params)
    FIXTURE.actions = FIXTURE.actions + 1
    FIXTURE.level = params.level
    return "level set to " .. tostring(params.level)
  end)
  aireport.declareAction({ id = "jam", title = "Jam", description = "Always refuses.", params = {}, risk = "medium" }, function()
    FIXTURE.jams = FIXTURE.jams + 1
    return nil, "the fixture is jammed"
  end)
  FIXTURE.started = aireport.start({ file = file, summary = "Test fixture reporter." })
end

function OnDriverDestroyed()
  aireport.stop()
end

function EC.EMIT_EVENT(t)
  FIXTURE.lastEvent = { aireport.event("fixture.tick", tostring((t or {}).TEXT or "tick"), { n = tonumber((t or {}).N) or 0 }) }
end

function EC.EMIT_DIAGNOSTIC(t)
  FIXTURE.lastDiagnostic = { aireport.diagnostic("warning", "fixture.fault", tostring((t or {}).TEXT or "fault")) }
end

function EC.SET_STATE(t)
  FIXTURE.lastState = { aireport.state({ value = tonumber((t or {}).VALUE) or 0 }) }
end

function EC.CHANGE_DECLARATION()
  FIXTURE.changed = { aireport.describe({ summary = "Test fixture reporter, changed." }) }
end

--- A report sent around the helper's own checks (an unknown kind, an
--- oversize describe, a sender named inside): what AI Core itself refuses.
function EC.RAW_REPORT(t)
  local args = JSON:decode(tostring((t or {}).ARGS or "{}"))
  local target = aireport.target()
  client.request("ai_core", "ai_core.report", args, {
    timeout = 10,
    retries = 0,
    to_instance = target and target.instance_id or nil,
  }, function(answer)
    FIXTURE.raw[#FIXTURE.raw + 1] = answer
  end)
end
