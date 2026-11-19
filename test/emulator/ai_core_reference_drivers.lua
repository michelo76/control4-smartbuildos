-- The three AI Core REFERENCE drivers under the Director emulator (EMULATOR
-- ONLY — not a bench result; no physical controller has run any of this):
-- the REAL Agent, the REAL AI Core and the REAL Atmosphere (helper start
-- mode, remote settings through sbos.mirror), Mode Composer (start mode,
-- the declared activate_mode action) and Flight Recorder (attach mode, its
-- own module client), exchanging frames through the emulator's asynchronous
-- SendToDevice → ExecuteCommand path. The cloud is scripted: the emulator's
-- fake cloud plus /modules/rpc and api.weather.gov answered here.
-- Run: test/emulator/run-ai-core.sh (exit 1 on any failure).

local EMU = assert(os.getenv("DIRECTOR_EMULATOR"), "DIRECTOR_EMULATOR not set (use the run script)")
local OUT = assert(os.getenv("SBOS_AI_OUT"), "SBOS_AI_OUT not set (use the run script)")
package.path = EMU .. "/examples/connector/?.lua;" .. package.path
local Cloud = require("fake_cloud")

local passed, failed = 0, 0
local function check(label, ok, detail)
  if ok then
    passed = passed + 1
    print("  CHECK ok    " .. label)
  else
    failed = failed + 1
    print("  CHECK FAIL  " .. label .. (detail ~= nil and ("  -> " .. tostring(detail)) or ""))
  end
end

local d = Director.new({ cacheDir = os.getenv("DIRECTOR_CACHE") .. "-reference" })
local cloud = Cloud.new(d):install()
cloud.catalog.SBOS_AI_CORE = {
  status = "AUTHORIZED_SUBSCRIPTION",
  license_type = "SUBSCRIPTION_INCLUDED",
  features = { "BASE", "AI_LEARNING", "AI_ACTIONS" },
}

-- ── api.weather.gov, scripted ────────────────────────────────────────────────
local function isoNow(delta)
  return os.date("!%Y-%m-%dT%H:%M:%S+00:00", math.floor(d.clock:now() / 1000) + (delta or 0))
end
local alertsOn = false
local function nws(path)
  if path:find("^/points/") then
    return {
      properties = {
        gridId = "MFL",
        gridX = 110,
        gridY = 50,
        forecast = "https://api.weather.gov/gridpoints/MFL/110,50/forecast",
        forecastHourly = "https://api.weather.gov/gridpoints/MFL/110,50/forecast/hourly",
        forecastGridData = "https://api.weather.gov/gridpoints/MFL/110,50",
        observationStations = "https://api.weather.gov/gridpoints/MFL/110,50/stations",
        forecastZone = "https://api.weather.gov/zones/forecast/FLZ173",
        timeZone = "America/New_York",
        radarStation = "KAMX",
      },
    }
  elseif path:find("/stations$") then
    return { features = { { properties = { stationIdentifier = "KFLL" } } } }
  elseif path:find("/observations/latest$") then
    return {
      properties = {
        timestamp = isoNow(-300),
        textDescription = "Partly Cloudy",
        temperature = { value = 30.0, unitCode = "wmoUnit:degC" },
        windSpeed = { value = 14.8, unitCode = "wmoUnit:km_h-1" },
        relativeHumidity = { value = 70 },
        barometricPressure = { value = 101800 },
        presentWeather = {},
      },
    }
  elseif path:find("/forecast$") or path:find("/forecast/hourly$") then
    local periods = {}
    for i = 0, 5 do
      periods[#periods + 1] = {
        name = i % 2 == 0 and ("Day " .. i) or ("Night " .. i),
        startTime = isoNow(i * 43200 - 3600),
        endTime = isoNow((i + 1) * 43200 - 3600),
        isDaytime = i % 2 == 0,
        temperature = i % 2 == 0 and 92 or 78,
        temperatureUnit = "F",
        probabilityOfPrecipitation = { value = 20 },
        windSpeed = "10 mph",
        shortForecast = "Partly Sunny",
      }
    end
    return { properties = { periods = periods } }
  elseif path:find("^/gridpoints/") then
    return { properties = {} }
  elseif path:find("^/alerts/active") then
    if not alertsOn then
      return { features = {} }
    end
    return {
      features = {
        {
          properties = {
            id = "urn:oid:emu.svr.1",
            event = "Severe Thunderstorm Warning",
            headline = "Severe Thunderstorm Warning until 5PM",
            severity = "Severe",
            certainty = "Observed",
            urgency = "Immediate",
            status = "Actual",
            messageType = "Alert",
            effective = isoNow(-600),
            onset = isoNow(-600),
            expires = isoNow(7200),
            ends = isoNow(7200),
            senderName = "NWS",
            areaDesc = "Test County",
          },
        },
      },
    }
  end
  return nil
end

local rpc = {}
local pending = { commands = {} }
d.http = function(req, dev)
  local url = tostring(req.url)
  local host, path = url:match("^https?://([^/]+)(/[^?]*)")
  if host == "api.weather.gov" then
    local body = nws(url:match("^https?://[^/]+(/.*)$") or path)
    if body == nil then
      return { code = 404, headers = {}, body = "{}" }
    end
    return { code = 200, headers = { ["Content-Type"] = "application/geo+json" }, body = json.encode(body) }
  end
  if path == "/api/integrations/control4/modules/rpc" then
    local body = type(req.body) == "string" and json.decode(req.body) or req.body
    rpc[#rpc + 1] = { op = body.op, body = body.body, module_id = body.module_id, t = d.clock:now() }
    return {
      code = 200,
      headers = { ["Content-Type"] = "application/json" },
      body = json.encode({ ok = true, result = { accepted = true } }),
    }
  end
  local resp = cloud:handle(req, dev)
  if resp and resp.code == 200 and path == "/api/integrations/control4/heartbeat" and #pending.commands > 0 then
    local b = json.decode(resp.body)
    b.commands = pending.commands
    pending.commands = {}
    resp.body = json.encode(b)
  end
  return resp
end

local function ops(op, since)
  local out = {}
  for i = (since or 0) + 1, #rpc do
    if rpc[i].op == op then
      out[#out + 1] = rpc[i]
    end
  end
  return out
end
local function items(since, pred)
  local out = {}
  for _, c in ipairs(ops("driver_reports", since)) do
    for _, it in ipairs(c.body.reports or {}) do
      if pred == nil or pred(it) then
        out[#out + 1] = it
      end
    end
  end
  return out
end

-- ── the project ──────────────────────────────────────────────────────────────
local room = d:addRoom("Equipment")
local agent = assert(d:addDevice(OUT .. "/smartbuildos", { roomId = room, name = "SmartBuildOS" }))
d:setProperty(agent, "Automatic Updates", "Off")
d:advance(1000)
d:setProperty(agent, "Pairing Code", "ABCD-2345")
d:advance(5000)
d:setProperty(agent, "Remote Control", "Comfort") -- driver-declared actions need Comfort

local cmdSeq = 0
local function moduleCommand(command, args)
  cmdSeq = cmdSeq + 1
  local requestId = "emu-ref-" .. cmdSeq
  pending.commands[#pending.commands + 1] = {
    id = "cmd-ref-" .. cmdSeq,
    command = "MODULE_COMMAND",
    payload = { module_id = "ai_core", command = command, request_id = requestId, args = args or {} },
  }
  d:executeCommand(agent, "SEND_HEARTBEAT", {})
  d:advance(3000)
  local rec = agent.env.gModuleCommands and agent.env.gModuleCommands[requestId]
  return rec and rec.state, rec and rec.detail
end
local uuidN = 0
local function uuid()
  uuidN = uuidN + 1
  return string.format("%08x-6c2d-4d9e-8f11-%012x", uuidN, uuidN)
end

local reporterIds = {}
local reportFrames = 0
local realSend = d.sendToDevice
d.sendToDevice = function(self, from, id, command, params)
  if from ~= nil and reporterIds[from.id] and command == "SBOS_MODULE_REQUEST" and params and params.capability == "ai_core.report" then
    reportFrames = reportFrames + 1
  end
  return realSend(self, from, id, command, params)
end

print("[1] the three reference drivers, AI Core absent")
local atmo = assert(d:addDevice(OUT .. "/ref/smartbuildos-atmosphere", { roomId = room, name = "Atmosphere" }))
d:setProperty(atmo, "Location Source", "Manual Coordinates")
d:setProperty(atmo, "Latitude", "26.1224")
d:setProperty(atmo, "Longitude", "-80.1373")
local mc = assert(d:addDevice(OUT .. "/ref/smartbuildos-mode-composer", { roomId = room, name = "Mode Composer" }))
local fr = assert(d:addDevice(OUT .. "/ref/smartbuildos-flight-recorder", { roomId = room, name = "Flight Recorder" }))
reporterIds[atmo.id], reporterIds[mc.id], reporterIds[fr.id] = true, true, true
d:executeCommand(atmo, "REDISCOVER_LOCATION", {})
d:advance(60000)
-- Two modes, through Composer's own commands.
d:setProperty(mc, "New Mode Type", "Home")
d:executeCommand(mc, "CREATE_MODE", {})
d:setProperty(mc, "New Mode Type", "Away")
d:executeCommand(mc, "CREATE_MODE", {})
d:advance(2000)
local function row(module, dev)
  for _, e in ipairs(agent.env.gModules:instances(module)) do
    if tostring(e.instance_id) == tostring(dev.id) then
      return e
    end
  end
end
check("Atmosphere registered (start mode), verified", row("atmosphere", atmo) ~= nil and row("atmosphere", atmo).verified == true)
check("Mode Composer registered (start mode, file given), verified", row("mode_composer", mc) ~= nil and row("mode_composer", mc).verified == true)
check("Flight Recorder registered once (its own client), verified", row("flight_recorder", fr) ~= nil and row("flight_recorder", fr).verified == true)
check("weather is flowing", tostring(atmo.Properties["Weather Status"]):find("86", 1, true) ~= nil, atmo.Properties["Weather Status"])
check("AI Core absent: no report frame from any of the three", reportFrames == 0, reportFrames)
for _, dev in ipairs({ atmo, mc, fr }) do
  check(dev.name .. ": AI Core = Not installed", dev.Properties["AI Core"] == "Not installed", dev.Properties["AI Core"])
end
check("no runtime error so far", #atmo.errors + #mc.errors + #fr.errors + #agent.errors == 0, atmo.errors[1] or mc.errors[1] or fr.errors[1] or agent.errors[1])

-- Atmosphere's remote settings (sbos.mirror) survive the helper's client.
d:executeCommand(atmo, "SBOS_DRIVER_CONFIG", {
  sku = "SBOS_ATMOSPHERE",
  settings = json.encode({ display = { default_screen = "forecast" } }),
  settings_version = "3",
})
d:advance(2000)
check("Atmosphere's remote settings still apply (sbos.mirror)", atmo.env.gSettings.display.default_screen == "forecast")

print("[2] AI Core appears")
local aic = assert(d:addDevice(OUT .. "/reports/smartbuildos-ai-core", { roomId = room, name = "AI Core" }))
d:advance(90000)
local ver = "20261118.000001" -- stamped by the run script
for _, dev in ipairs({ atmo, mc, fr }) do
  check(dev.name .. ": Found — reporting (v" .. ver .. ")", dev.Properties["AI Core"] == "Found — reporting (v" .. ver .. ")", dev.Properties["AI Core"])
end
local function from(mod, dev, kind)
  return function(it)
    return it.from_module_id == mod and it.from_instance_id == tostring(dev.id) and (kind == nil or it.kind == kind)
  end
end
local function lastItem(mod, dev, kind)
  local list = items(0, from(mod, dev, kind))
  return list[#list]
end
local da, dm, df = lastItem("atmosphere", atmo, "describe"), lastItem("mode_composer", mc, "describe"), lastItem("flight_recorder", fr, "describe")
check("Atmosphere's describe reached the cloud (2 queries, no action)", da and #da.queries == 2 and #da.actions == 0, da and json.encode(da.queries))
check(
  "Mode Composer's describe reached the cloud (2 queries, activate_mode HIGH)",
  dm and #dm.queries == 2 and #dm.actions == 1 and dm.actions[1].id == "activate_mode" and dm.actions[1].risk == "high",
  dm and json.encode(dm.actions)
)
check("Flight Recorder's describe reached the cloud (2 queries, no action)", df and #df.queries == 2 and #df.actions == 0)
local sa, sm, sf = lastItem("atmosphere", atmo, "state"), lastItem("mode_composer", mc, "state"), lastItem("flight_recorder", fr, "state")
check("Atmosphere's state: weather facts", sa and sa.facts.condition == "Partly Cloudy" and sa.facts.temperature_f == 86, sa and json.encode(sa.facts))
check("Mode Composer's state: mode counts", sm and sm.facts.presence_modes == 2, sm and json.encode(sm.facts))
check("Flight Recorder's state: recording facts", sf and type(sf.facts.recording_status) == "string", sf and json.encode(sf.facts))

print("[3] events flow")
local mark = #rpc
alertsOn = true
d:executeCommand(atmo, "REFRESH_ALERTS", {})
d:executeCommand(mc, "Activate_Mode", { NAME = "Home" })
d:executeCommand(fr, "START_TRACE", { CHANNEL = "garage", NAME = "Garage check" })
d:executeCommand(fr, "FAIL_TRACE", { CHANNEL = "garage", REASON = "door still open" })
d:advance(60000)
local function hasEvent(mod, dev, typ)
  for _, it in ipairs(items(mark, from(mod, dev, "event"))) do
    if it.type == typ then
      return it
    end
  end
end
check("Atmosphere: weather.new_weather_warning", hasEvent("atmosphere", atmo, "weather.new_weather_warning") ~= nil)
local mcEv = hasEvent("mode_composer", mc, "mode.changed")
check("Mode Composer: mode.changed", mcEv ~= nil and mcEv.text == "The presence mode is now Home", mcEv and mcEv.text)
check("Flight Recorder: routine.not_completed", hasEvent("flight_recorder", fr, "routine.not_completed") ~= nil)

print("[4] a query round trip for each")
local function query(module, dev, queryId, params)
  local ref = uuid()
  moduleCommand("run_driver_query", {
    query_ref = ref,
    module_id = module,
    instance_id = tostring(dev.id),
    query_id = queryId,
    params = params or {},
  })
  d:advance(5000)
  for _, c in ipairs(ops("driver_query_result")) do
    if c.body.query_ref == ref then
      return c.body
    end
  end
end
local q = query("atmosphere", atmo, "weather_source")
check("Atmosphere weather_source: completed, station and office", q and q.status == "completed" and q.data.observation_station == "KFLL" and q.data.forecast_office == "MFL", q and json.encode(q))
q = query("mode_composer", mc, "current_modes")
check("Mode Composer current_modes: completed, Home active", q and q.status == "completed" and q.data.presence_mode == "Home" and #q.data.modes == 2, q and json.encode(q))
q = query("flight_recorder", fr, "history_coverage")
check("Flight Recorder history_coverage: completed", q and q.status == "completed" and type(q.data.entries_held) == "number" and q.data.capacity == 500, q and json.encode(q))

print("[5] the Mode Composer action round trip")
local function actionResult(id)
  for _, c in ipairs(ops("driver_action_result")) do
    if c.body.ai_action_id == id then
      return c.body
    end
  end
end
-- The declaration hash the platform holds: the describe it received.
local hash = lastItem("mode_composer", mc, "describe").hash
local aid = uuid()
moduleCommand("invoke_driver_action", {
  ai_action_id = aid,
  module_id = "mode_composer",
  instance_id = tostring(mc.id),
  action_id = "activate_mode",
  params = { mode = "Away" },
  declaration_hash = hash,
})
d:advance(10000)
local ar = actionResult(aid)
check("activate_mode Away: completed, with the driver's real outcome", ar and ar.status == "completed" and ar.result_text == "Away is active", ar and json.encode(ar))
check("…the house really is in Away", mc.Properties["Presence Mode"] == "Away", mc.Properties["Presence Mode"])
aid = uuid()
moduleCommand("invoke_driver_action", {
  ai_action_id = aid,
  module_id = "mode_composer",
  instance_id = tostring(mc.id),
  action_id = "activate_mode",
  params = { mode = "Garage" },
  declaration_hash = hash,
})
d:advance(10000)
ar = actionResult(aid)
check("an unknown mode: failed, the driver's words (never completed)", ar and ar.status == "failed" and ar.result_text == "No mode is named Garage", ar and json.encode(ar))
check("…nothing changed", mc.Properties["Presence Mode"] == "Away")
aid = uuid()
moduleCommand("invoke_driver_action", {
  ai_action_id = aid,
  module_id = "mode_composer",
  instance_id = tostring(mc.id),
  action_id = "activate_mode",
  params = { mode = "Home" },
  declaration_hash = "0000000000000000",
})
d:advance(10000)
ar = actionResult(aid)
check("a stale declaration hash: failed declaration_changed", ar and ar.status == "failed" and ar.result_text == "declaration_changed", ar and json.encode(ar))
check("…nothing changed", mc.Properties["Presence Mode"] == "Away")

print("[6] AI Core goes away and comes back")
d:removeDevice(aic)
d:advance(30000)
for _, dev in ipairs({ atmo, mc, fr }) do
  check(dev.name .. ": Not installed", dev.Properties["AI Core"] == "Not installed", dev.Properties["AI Core"])
end
local before = reportFrames
d:executeCommand(mc, "Activate_Mode", { NAME = "Home" })
d:executeCommand(atmo, "REFRESH_ALL", {})
d:advance(30000)
check("no report frame while AI Core is gone", reportFrames == before, reportFrames - before)
aic = assert(d:addDevice(OUT .. "/reports/smartbuildos-ai-core", { roomId = room, name = "AI Core" }))
d:advance(90000)
for _, dev in ipairs({ atmo, mc, fr }) do
  check(dev.name .. ": Found — reporting again", dev.Properties["AI Core"] == "Found — reporting (v" .. ver .. ")", dev.Properties["AI Core"])
end
check(
  "no runtime errors (Agent, AI Core, the three drivers)",
  #agent.errors + #aic.errors + #atmo.errors + #mc.errors + #fr.errors == 0,
  agent.errors[1] or aic.errors[1] or atmo.errors[1] or mc.errors[1] or fr.errors[1]
)

print(string.format("\nEMULATOR ONLY: %d passed, %d failed", passed, failed))
if failed > 0 then
  os.exit(1)
end
