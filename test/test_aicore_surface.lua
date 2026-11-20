-- AI Core: the names that cross a boundary agree everywhere they are
-- written. driver.xml (what Composer shows and programming binds to) against
-- src/aicore/vocab.lua and src/aicore/commands.lua (what the driver does),
-- against the Agent's closed tables (MODULE_COMMANDS.ai_core, SKU_FILENAMES,
-- DRIVER_FILENAMES), the contract's policy (MODULE_CLOUD_OPS,
-- MODULE_TOPIC_POLICY), envelope prefix ownership, the Flight Recorder's
-- manifest and the store publish map. A drift in any of them fails here.
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

local function read(path)
  local f = assert(io.open(path, "r"), path)
  local s = f:read("*a")
  f:close()
  return s
end

local V = require("aicore.vocab")
local Commands = require("aicore.commands")
local Collector = require("aicore.collector")
local Policy = require("sbos.modulepolicy")
local Envelope = require("sbos.envelope")

local xml = read("drivers/smartbuildos-ai-core/driver.xml")
local lua = read("drivers/smartbuildos-ai-core/driver.lua")
local agent = read("drivers/smartbuildos/driver.lua")

print("[1] driver.xml events = vocab events (ids are permanent)")
local xmlEvents = {}
for id, name in xml:gmatch("<event><id>(%d+)</id><name>(.-)</name>") do
  xmlEvents[tonumber(id)] = name
end
local same = true
for _, e in ipairs(V.EVENTS) do
  same = same and xmlEvents[e.id] == e.name
end
check("every vocab event in the XML with the same id", same)
local nXml = 0
for _ in pairs(xmlEvents) do
  nXml = nXml + 1
end
check("and nothing else (10)", nXml == #V.EVENTS and nXml == 10, nXml)
for _, name in ipairs({
  "AI Response Ready",
  "Pattern Detected",
  "Recommendation Available",
  "Automation Conflict Detected",
  "Device Failure Pattern Detected",
  "Approval Required",
  "Action Completed",
  "Action Failed",
  "Agent Disconnected",
  "AI Provider Error",
}) do
  local found = false
  for _, n in pairs(xmlEvents) do
    found = found or n == name
  end
  check("event '" .. name .. "'", found)
end

print("[2] variables: the brief's names, ids 4000.., same order in XML and driver")
local wanted = {
  "AI_STATUS",
  "AI_LAST_RESPONSE",
  "AI_LAST_RESPONSE_ID",
  "AI_LAST_REQUEST_ID",
  "AI_LAST_EVENT_DETAIL",
  "AI_PENDING_APPROVALS",
  "AI_RECOMMENDATION_COUNT",
  "AGENT_CONNECTED",
  "LEARNING_ACTIVE",
  "AI_LAST_ERROR",
  -- Added after the brief's ten: the raise_event correlation_id (DRIVER.md §5).
  "AI_LAST_CORRELATION_ID",
}
local xmlVars = {}
for id, name in xml:gmatch("<variable><id>(%d+)</id><name>(.-)</name>") do
  xmlVars[#xmlVars + 1] = { id = tonumber(id), name = name }
end
local luaVars = {}
local block = lua:match("local VARIABLES = {(.-)\n}")
for name in tostring(block):gmatch('{ "([A-Z_]+)"') do
  luaVars[#luaVars + 1] = name
end
local okOrder = #xmlVars == #wanted and #luaVars == #wanted
for i, name in ipairs(wanted) do
  okOrder = okOrder and xmlVars[i].name == name and xmlVars[i].id == 3999 + i and luaVars[i] == name
end
check("11 variables, ids 4000..4010, same order (AddVariable order is frozen)", okOrder)

print("[3] commands and their typed parameters")
local xmlCommands = {}
for body in xml:match("<commands>(.-)</commands>"):gmatch("<command>(.-)</command>") do
  local name = body:match("<name>(.-)</name>")
  local params = {}
  for p in body:gmatch("<param>(.-)</param>") do
    local pname = p:match("<name>(.-)</name>")
    local items = {}
    for it in p:gmatch("<item>(.-)</item>") do
      items[#items + 1] = it
    end
    params[pname] = { type = p:match("<type>(.-)</type>"), items = items }
  end
  xmlCommands[name] = params
end
for _, name in ipairs(Commands.NAMES) do
  local spec = Commands.SPECS[name]
  local params = xmlCommands[name]
  check(name .. " declared in the XML", params ~= nil)
  if params then
    local same2 = true
    local n = 0
    for pname, p in pairs(params) do
      n = n + 1
      local sp = spec.params[pname]
      same2 = same2 and sp ~= nil
      if sp and sp.kind == "enum" then
        same2 = same2 and p.type == "LIST"
        for _, it in ipairs(p.items) do
          if not sp.list[Commands.normaliseEnum(it)] then
            same2 = false
            print("      LIST item not in the closed list: " .. name .. "." .. pname .. " " .. it)
          end
        end
      elseif sp and sp.kind == "device" then
        same2 = same2 and p.type == "DEVICE_SELECTOR"
      elseif sp then
        same2 = same2 and p.type == "STRING"
      end
    end
    for _ in pairs(spec.params) do
      n = n - 1
    end
    check(name .. ": XML params = spec params, types match, LIST items in the closed list", same2 and n == 0)
  end
end
local nCmd = 0
for _ in pairs(xmlCommands) do
  nCmd = nCmd + 1
end
check("no XML command without a handler spec", nCmd == #Commands.NAMES)
for _, name in ipairs(Commands.NAMES) do
  local op = Commands.SPECS[name].op
  check(name .. ": its op is in MODULE_CLOUD_OPS.ai_core (or none)", op == nil or Policy.CLOUD_OPS.ai_core[op] == true)
end
local opsSame = true
for op in pairs(V.CLOUD_OPS) do
  opsSame = opsSame and Policy.CLOUD_OPS.ai_core[op] == true
end
for op in pairs(Policy.CLOUD_OPS.ai_core) do
  opsSame = opsSame and V.CLOUD_OPS[op] == true
end
check("vocab CLOUD_OPS = the Agent policy's MODULE_CLOUD_OPS.ai_core", opsSame)

print("[4] properties and actions")
for _, name in ipairs({
  "SmartBuildOS Connection Status",
  "Agent Pairing Status",
  "Property ID",
  "Controller ID",
  "AI Provider",
  "AI Model",
  "AI API Credential",
  "AI Status",
  "Telemetry Status",
  "Learning Status",
  "Permission Mode",
  "Log Level",
  "License Status",
  "Last Synchronization",
  "Last Error",
}) do
  local blockP = xml:match("<property><name>" .. name:gsub("%p", "%%%0") .. "</name>(.-)</property>")
  check("property '" .. name .. "'", blockP ~= nil)
  if blockP and name ~= "Log Level" then
    check("  read-only", blockP:find("<readonly>true</readonly>") ~= nil)
  end
end
local credential = xml:match("<property><name>AI API Credential</name>(.-)</property>")
check(
  "AI API Credential is not an input (no password, read-only STRING)",
  credential:find("<password>") == nil and credential:find("<type>STRING</type>") ~= nil
)
check("Log Level editable", xml:match("<property><name>Log Level</name>(.-)</property>"):find("readonly") == nil)
for cmd, label in pairs({
  TEST_AGENT_LINK = "Test Agent Link",
  TEST_AI_CONNECTION = "Test AI Connection",
  SYNC_NOW = "Sync Now",
  PRINT_DIAGNOSTICS = "Print Diagnostics",
}) do
  check(
    "action " .. label,
    xml:find("<action><name>" .. label .. "</name><command>" .. cmd .. "</command></action>", 1, true) ~= nil
  )
  check("  handled (EC." .. cmd .. ")", lua:find("function EC%." .. cmd .. "%(") ~= nil)
end
for name in xml:gmatch("<conditional>.-<name>(.-)</name>") do
  check("conditional " .. name .. " has TC." .. name, lua:find("function TC%." .. name .. "%(") ~= nil)
end

print("[5] the Agent's closed tables")
local mc = agent:match("ai_core = {(.-)}")
local agentOps = {}
-- `= true`, or `= <rank>` for a verb that needs a Remote Control tier.
for op in tostring(mc):gmatch("([%w_]+) = [%w]+,") do
  agentOps[op] = true
end
local opsOk = true
for _, op in ipairs(V.OPERATIONS) do
  opsOk = opsOk and agentOps[op]
end
local nOps = 0
for _ in pairs(agentOps) do
  nOps = nOps + 1
end
check(
  "MODULE_COMMANDS.ai_core = the driver's restricted operations, exactly (vocab.OPERATIONS)",
  opsOk and nOps == #V.OPERATIONS,
  nOps
)
check(
  "SKU_FILENAMES maps SBOS_AI_CORE → smartbuildos-ai-core.c4z",
  agent:find('SBOS_AI_CORE = { "smartbuildos%-ai%-core%.c4z" }') ~= nil
)
local df = agent:match("DRIVER_FILENAMES%s*=%s*{(.-)}")
check("DRIVER_FILENAMES lists smartbuildos-ai-core.c4z", tostring(df):find('"smartbuildos%-ai%-core%.c4z"') ~= nil)
check(
  "store publish map: smartbuildos-ai-core.c4z → SBOS_AI_CORE",
  read(".github/workflows/publish-to-store.yml"):find("smartbuildos%-ai%-core%.c4z%) echo SBOS_AI_CORE") ~= nil
)
check("the driver's own DRIVER_FILENAMES", lua:find('DRIVER_FILENAMES = { "smartbuildos%-ai%-core%.c4z" }') ~= nil)

print("[6] contract policy and prefixes")
check(
  "Envelope.PREFIXES.ai_core = { ai_core. }",
  #Envelope.PREFIXES.ai_core == 1 and Envelope.PREFIXES.ai_core[1] == "ai_core."
)
for _, t in ipairs(Collector.FR_TOPICS) do
  check("MODULE_TOPIC_POLICY grants " .. t .. " to ai_core", Policy.topicAllowed(Policy.TOPIC_POLICY, "ai_core", t))
end
for _, cap in ipairs({ "events.device_history", "events.room_activity" }) do
  local p = Policy.REQUEST_POLICY[cap]
  check(
    cap .. ": provider flight_recorder, ai_core may ask",
    p and p.provider == "flight_recorder" and p.requesters.ai_core
  )
end
local fr = read("drivers/smartbuildos-flight-recorder/driver.lua")
local topicLine = fr:match('id = "events%.subscribe".-topics = {(.-)}')
for _, t in ipairs(Collector.FR_TOPICS) do
  check("the Flight Recorder manifest offers " .. t, tostring(topicLine):find('"' .. t:gsub("%.", "%%.") .. '"') ~= nil)
end

print("[7] in-driver documentation names every surface item")
local docf = io.open("drivers/smartbuildos-ai-core/www/documentation/index.md", "r")
local doc = docf and docf:read("*a") or ""
if docf then
  docf:close()
end
local missingDoc = {}
local function needs(text)
  if not doc:find(text, 1, true) then
    missingDoc[#missingDoc + 1] = text
  end
end
for _, e in ipairs(V.EVENTS) do
  needs(e.name)
end
for _, name in ipairs(wanted) do
  needs(name)
end
for _, name in ipairs(Commands.NAMES) do
  needs(name)
  for p in pairs(Commands.SPECS[name].params) do
    needs(p)
  end
end
for name in xml:gmatch("<property><name>(.-)</name>") do
  needs(name)
end
for name in xml:gmatch("<action><name>(.-)</name>") do
  needs(name)
end
for name in xml:gmatch("<conditional>.-<name>(.-)</name>") do
  needs(name)
end
for _, op in ipairs(V.OPERATIONS) do
  needs(op)
end
check(
  "index.md mentions every property, action, command, parameter, event, variable, conditional, operation",
  #missingDoc == 0,
  table.concat(missingDoc, ", ")
)
local ref = io.open("docs/ai-core/DRIVER.md", "r")
local refText = ref and ref:read("*a") or ""
if ref then
  ref:close()
end
local refMissing = {}
for _, text in
  ipairs((function()
    local all = {}
    for _, e in ipairs(V.EVENTS) do
      all[#all + 1] = e.name
    end
    for _, n in ipairs(wanted) do
      all[#all + 1] = n
    end
    for _, n in ipairs(Commands.NAMES) do
      all[#all + 1] = n
    end
    for n in xml:gmatch("<property><name>(.-)</name>") do
      all[#all + 1] = n
    end
    for _, op in ipairs(V.OPERATIONS) do
      all[#all + 1] = op
    end
    return all
  end)())
do
  if not refText:find(text, 1, true) then
    refMissing[#refMissing + 1] = text
  end
end
check("docs/ai-core/DRIVER.md names every one of them too", #refMissing == 0, table.concat(refMissing, ", "))
check(
  "both say no physical controller has run it",
  doc:find("No physical controller") ~= nil and refText:find("No physical controller") ~= nil
)

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
