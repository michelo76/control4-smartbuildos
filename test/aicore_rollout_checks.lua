-- Shared checks for the AI Core rollout tests (brief D7a): every root driver
-- wired to sbos.aireport after the three reference drivers has a
-- test/test_<driver>_aicore.lua that sets its own driver up under the shim
-- (copied from that driver's existing test) and then runs these checks on
-- test/aicore_reporter_harness.lua (the REAL Agent registry and bus, a fake
-- AI Core answering through AI Core's REAL validator). Not a test file
-- itself (no test_ prefix).
--
-- What every driver proves here:
--   * driver.xml declares the read-only `AI Core` property, exact default;
--   * AI Core absent: registered under its reserved module id with its own
--     instance id, verified, no error, ZERO report frames, `Not installed`,
--     the driver's normal work unchanged and still silent;
--   * AI Core appears: a describe and a state AI Core's validator accepts
--     (and aicore.reports.validate accepts the describe directly), the
--     driver's own summary / controls / vocabulary, no declared action,
--     `Found — reporting`; nothing on the driver's forbidden list in any
--     report;
--   * AI Core goes away (`Not installed`, silent) and comes back
--     (`Found — reporting`); only closed values ever painted;
--   * multi-instance roots: a second instance of the same module id is
--     accepted alongside (nothing assumes a singleton);
--   * OnDriverDestroyed: start mode unregisters; attach mode leaves it to
--     the driver's own client (which unregisters once).

local R = {}

R.pass, R.fail = 0, 0
function R.check(name, ok, detail)
  if ok then
    R.pass = R.pass + 1
    print("  ok   " .. name)
  else
    R.fail = R.fail + 1
    print("  FAIL " .. name .. (detail ~= nil and ("  -> " .. tostring(detail)) or ""))
  end
end

function R.finish()
  print(string.format("\n%d passed, %d failed", R.pass, R.fail))
  if R.fail > 0 then
    os.exit(1)
  end
end

R.XML =
  "<property><name>AI Core</name><type>STRING</type><default>Searching…</default><readonly>true</readonly></property>"

--- Reads the driver's driver.xml property defaults into the global
--- Properties table (adding, never removing) and checks the AI Core
--- property is declared exactly as the guide says.
function R.loadProperties(dir)
  local f = assert(io.open("drivers/" .. dir .. "/driver.xml"))
  local xml = f:read("*a")
  f:close()
  Properties = Properties or {}
  local found
  for block in xml:gmatch("<property>(.-)</property>") do
    local name = block:match("<name>%s*(.-)%s*</name>")
    if name then
      Properties[name] = block:match("<default>(.-)</default>") or ""
      if name == "AI Core" then
        found = block
      end
    end
  end
  local compact = found and ("<property>" .. found .. "</property>"):gsub("%s+<", "<"):gsub(">%s+", ">")
  R.check("driver.xml declares the read-only AI Core property (exact XML)", compact == R.XML, compact)
  return xml
end

--- Records every value painted into AI Core. Call after the test defined
--- its own C4.UpdateProperty (this wraps it, or sets Properties).
R.painted = {}
function R.watchPaints()
  local inner = C4.UpdateProperty
  C4.UpdateProperty = function(self, name, value, ...)
    if name == "AI Core" then
      R.painted[#R.painted + 1] = tostring(value)
    end
    if inner then
      inner(self, name, value, ...)
    end
    Properties[name] = value
  end
end

local function lastOf(H, kind)
  local list = H.reports(kind)
  return list[#list] and list[#list].args or nil
end

--- o = {
---   H, moduleId, file, sku, mode = "start"|"attach",
---   start = fn()            -- OnDriverInit + OnDriverLateInit (default)
---   activity = fn()         -- the driver's own work, while AI Core is absent
---   describe = fn(d, check) -- driver-specific describe checks
---   state = fn(facts, check)-- driver-specific state checks (nil: none sent beyond the baseline)
---   forbid = { "text", … }  -- must appear in no report (names, codes, addresses…)
---   multiInstance = bool
---   destroy = bool (default true)
--- }
function R.lifecycle(o)
  local check, H = R.check, o.H
  local aireport = require("sbos.aireport")
  local Reports = require("aicore.reports")

  print("[1] AI Core absent")
  local okStart, startErr = pcall(o.start or function()
    OnDriverInit()
    OnDriverLateInit()
  end)
  check("the driver starts with no error", okStart, startErr)
  check(
    "helper in " .. o.mode .. " mode for " .. o.file,
    aireport.mode() == o.mode and aireport._state().file == o.file,
    aireport.mode()
  )
  local row = H.registry:find(o.moduleId, tostring(H.selfId))
  check(
    "registered as " .. o.moduleId .. " with its own instance id, verified",
    row ~= nil and row.instance_id == tostring(H.selfId) and row.verified == true,
    row and (tostring(row.instance_id) .. ":" .. tostring(row.verified)) or "no row"
  )
  check(
    "no ai.action advertised",
    (function()
      for _, c in ipairs(row and row.manifest and row.manifest.capabilities or {}) do
        if c.id == "ai.action" then
          return false
        end
      end
      return true
    end)()
  )
  check("zero report frames while AI Core is absent", H.reportFrames() == 0, H.reportFrames())
  check("property: Not installed", Properties["AI Core"] == "Not installed", Properties["AI Core"])
  if o.activity then
    local okA, errA = pcall(o.activity)
    check("the driver's own work runs unchanged", okA, errA)
    check("…and still zero report frames", H.reportFrames() == 0, H.reportFrames())
  end

  print("[2] AI Core appears")
  H.aiRegister()
  H.pushDirectory()
  local d = lastOf(H, "describe")
  check("a describe arrived and AI Core accepted every report", d ~= nil and H.allValid(), select(2, H.allValid()))
  d = d or { driver = {}, controls = {}, vocabulary = {}, queries = {}, actions = {} }
  local item, why, field = Reports.validate(o.moduleId, tostring(H.selfId), d)
  check("aicore.reports.validate accepts the describe", item ~= nil, tostring(why) .. ":" .. tostring(field))
  check(
    "describe: file and sku",
    d.driver.file == o.file and d.driver.sku == o.sku,
    tostring(d.driver.file) .. " " .. tostring(d.driver.sku)
  )
  check(
    "describe: a hand-written summary (not the built-in default)",
    type(d.summary) == "string" and d.summary ~= aireport.SUMMARIES[o.file] and #d.summary > 40,
    d.summary
  )
  check("describe: controls and homeowner words", #(d.controls or {}) >= 1 and #(d.vocabulary or {}) >= 3)
  check("describe: no action declared", #(d.actions or {}) == 0)
  if o.describe then
    o.describe(d, check)
  end
  check(
    "property: Found — reporting",
    Properties["AI Core"] == "Found — reporting (v20261118.2)",
    Properties["AI Core"]
  )
  local facts = (lastOf(H, "state") or {}).facts or {}
  check(
    "state: the helper's baseline (driver status, licence)",
    facts.driver_status ~= nil and facts.license ~= nil,
    JSON:encode(facts)
  )
  if o.state then
    o.state(facts, check)
  end
  local everything = JSON:encode(H.reports())
  for _, word in ipairs(o.forbid or {}) do
    check("nothing personal or secret in any report: " .. word, everything:find(word, 1, true) == nil)
  end

  if o.multiInstance then
    print("[2b] a second instance of the same driver")
    local second = tostring(H.selfId + 1)
    H.c4i[o.file][H.selfId + 1] = {}
    local okR, reply = H.registry:register({
      module_id = o.moduleId,
      instance_id = second,
      requester = second,
      driver_version = "1",
      protocol_min = "1",
      protocol_max = "2",
      -- registers exactly as this instance did (a singleton row would make
      -- the Agent refuse it as duplicate_instance)
      singleton = tostring(row ~= nil and row.singleton == true),
      status = "ready",
      manifest = "",
    })
    check(
      "a second instance registers under the same module id alongside this one",
      okR == true
        and H.registry:find(o.moduleId, second) ~= nil
        and H.registry:find(o.moduleId, tostring(H.selfId)) ~= nil,
      reply and reply.reason
    )
    check(
      "this instance registered non-singleton",
      row ~= nil and row.singleton == false,
      row and tostring(row.singleton)
    )
    H.registry:remove(o.moduleId, second)
    H.c4i[o.file][H.selfId + 1] = nil
  end

  print("[3] AI Core goes away and comes back")
  H.aiRemove()
  H.pushDirectory()
  check("property: Not installed", Properties["AI Core"] == "Not installed", Properties["AI Core"])
  local frames = H.reportFrames()
  if o.activity then
    pcall(o.activity)
  end
  check("no report frame while it is gone", H.reportFrames() == frames)
  H.aiRegister()
  H.pushDirectory()
  check(
    "back: Found — reporting",
    Properties["AI Core"] == "Found — reporting (v20261118.2)",
    Properties["AI Core"]
  )
  check("every report valid for AI Core", H.allValid(), select(2, H.allValid()))
  local outside = {}
  for _, v in ipairs(R.painted) do
    if not aireport.isValue(v) then
      outside[#outside + 1] = v
    end
  end
  check("only closed values were painted", #R.painted > 0 and #outside == 0, table.concat(outside, " | "))

  if o.destroy ~= false then
    print("[4] OnDriverDestroyed")
    local okD, errD = pcall(OnDriverDestroyed)
    check("OnDriverDestroyed runs", okD, errD)
    check(
      "unregistered from the Agent exactly once",
      H.count("SBOS_MODULE_UNREGISTER") == 1 and H.registry:find(o.moduleId, tostring(H.selfId)) == nil,
      H.count("SBOS_MODULE_UNREGISTER")
    )
  end
end

return R
