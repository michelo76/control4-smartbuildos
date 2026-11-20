-- sbos.aivalues: the ONE closed value list of the "AI Core" property
-- (conductor ruling 20), and the guard that the three modules painting that
-- property can write nothing else:
--   sbos.aireport (roots that report), sbos.aipresence (children; a root
--   that does not report now), sbos.agentaicore (the Agent).
-- For each module:
--   [1] its source holds no value text of its own (comments stripped): every
--       value comes from sbos.aivalues;
--   [2] every UpdateProperty in it sits inside its one `paint` function,
--       and that function refuses anything aivalues.isValue refuses;
--   [3] (runtime) driven through its states, everything it paints is a
--       closed value.
-- Run from the driver root: make test

C4 = C4 or {}
require("c4_shim")

local pass, fail = 0, 0
local function check(name, ok, detail)
  if ok then
    pass = pass + 1
    print("  ok   " .. name)
  else
    fail = fail + 1
    print("  FAIL " .. name .. (detail ~= nil and ("  -> " .. tostring(detail)) or ""))
  end
end

local values = require("sbos.aivalues")

local function read(path)
  local f = assert(io.open(path, "rb"))
  local s = f:read("*a")
  f:close()
  return s
end

local function stripComments(src)
  src = src:gsub("%-%-%[(=*)%[.-%]%1%]", "")
  return (src:gsub("%-%-[^\n]*", ""))
end

print("[0] the list")
do
  local SPEC = {
    "Searching…",
    "SmartBuildOS Agent not found",
    "SmartBuildOS Agent update required",
    "Not registered — Agent module list full",
    "Not installed",
    "Found — not responding",
    "Found — AI Core update required (v%s)",
    "Found — not licensed (v%s)",
    "Found — SmartBuildOS Agent not paired (v%s)",
    "Found — reporting, cloud offline (v%s)",
    "Found — reporting (v%s)",
    "Installed — reports through %s",
    "Installed — this driver does not report",
    "Found — registered (v%s)",
    "Found — not verified (v%s)",
  }
  local same = #values.VALUES == #SPEC
  for i, v in ipairs(SPEC) do
    same = same and values.VALUES[i] == v
  end
  check("VALUES is spec §3.6, ruling 20's one value, then the Agent's two, in order (15)", same, #values.VALUES)
  local n = 0
  for _ in pairs(values.V) do
    n = n + 1
  end
  check("V names exactly the 15 values", n == 15, n)
  check("the new value is closed", values.isValue("Installed — this driver does not report"))
  check(
    "the child template takes a known root label only",
    values.isValue("Installed — reports through SmartBuildOS System Link")
      and not values.isValue("Installed — reports through Someone Else")
  )
  check(
    "the Agent's two values take a bounded version",
    values.isValue("Found — registered (v20261118.1)")
      and values.isValue("Found — not verified (v20261118.1)")
      and not values.isValue("Found — registered (vnot a version!)")
  )
  check("anything else is refused", not values.isValue("Installed") and not values.isValue("Connected"))
end

-- Fragments that only a value carries; none may appear in a module's code.
local FRAGMENTS = {
  "Searching",
  "Agent not found",
  "update required",
  "Not registered",
  "Not installed",
  "Found —",
  "Installed —",
  "not responding",
  "not licensed",
  "not paired",
  "cloud offline",
  "reports through",
  "does not report",
}

local MODULES = {
  { name = "sbos.aireport", path = "src/sbos/aireport.lua" },
  { name = "sbos.aipresence", path = "src/sbos/aipresence.lua" },
  { name = "sbos.agentaicore", path = "src/sbos/agentaicore.lua" },
}

print("[1] no module carries a value of its own")
for _, m in ipairs(MODULES) do
  local code = stripComments(read(m.path))
  local hits = {}
  for _, frag in ipairs(FRAGMENTS) do
    if code:find(frag, 1, true) then
      hits[#hits + 1] = frag
    end
  end
  check(m.name .. ": no value text outside comments (all from sbos.aivalues)", #hits == 0, table.concat(hits, " | "))
  check(m.name .. ": requires sbos.aivalues", code:find('require%("sbos%.aivalues"%)') ~= nil)
end

print("[1b] the Agent's two values are the Agent's only")
for _, m in ipairs(MODULES) do
  local code = stripComments(read(m.path))
  local uses = code:find("V%.registered") ~= nil or code:find("V%.unverified") ~= nil
  if m.name == "sbos.agentaicore" then
    check(
      m.name .. ": paints V.registered and V.unverified",
      code:find("V%.registered") ~= nil and code:find("V%.unverified") ~= nil
    )
  else
    check(m.name .. ": never paints V.registered / V.unverified", not uses)
  end
end

print("[2] one writer per module, behind isValue")
for _, m in ipairs(MODULES) do
  local code = stripComments(read(m.path))
  local a = code:find("local function paint%(text%)")
  local b = a and code:find("\nend\n", a, true)
  check(m.name .. ": has a local paint(text)", a ~= nil and b ~= nil)
  if a and b then
    local body = code:sub(a, b)
    check(m.name .. ": paint() checks isValue first", body:find("isValue%(text%)") ~= nil)
    local outside = 0
    local pos = 1
    while true do
      local s = code:find("UpdateProperty", pos, true)
      if s == nil then
        break
      end
      if s < a or s > b then
        outside = outside + 1
      end
      pos = s + 1
    end
    check(m.name .. ": every UpdateProperty is inside paint()", outside == 0, outside)
  end
end

-- ── runtime ─────────────────────────────────────────────────────────────────
local painted = {}
Properties = { ["AI Core"] = "Searching…" }
function UpdateProperty(name, value)
  if name == "AI Core" then
    painted[#painted + 1] = value
  end
  Properties[name] = value
end
local c4i = {}
function C4:GetDevicesByC4iName(file)
  return c4i[file]
end
function C4:RegisterSystemEvent() end
local timers = {}
function SetTimer(id, _, fn)
  timers[id] = fn
end
function CancelTimer(id)
  timers[id] = nil
end
OSE = {}

print("[3] runtime: everything painted is closed")
do
  local aipresence = require("sbos.aipresence")
  local agentaicore = require("sbos.agentaicore")
  local aireport = require("sbos.aireport")

  -- refusals
  check("aipresence paint refuses an outside value", aipresence._paint("Connected") == false)
  check("agentaicore paint refuses an outside value", agentaicore._paint("Connected") == false)
  check("aireport paint refuses an outside value", aireport._paint("Connected") == false)
  check("…and none of them wrote it", #painted == 0, #painted)

  -- aipresence through its states, for every child
  for file in pairs(aipresence.CHILDREN) do
    aipresence._reset()
    c4i["smartbuildos-ai-core.c4z"] = nil
    aipresence.start({ file = file })
    c4i["smartbuildos-ai-core.c4z"] = { [700] = {} }
    aipresence._soon()
    timers[aipresence.TIMER]()
  end
  aipresence._reset()
  aipresence.start({ file = "smartbuildos-venueflow.c4z", silent = true })

  -- agentaicore through its states
  local Modules = require("sbos.modules")
  local now = 1000
  local reg = Modules.Registry.new({
    now = function()
      return now
    end,
    newToken = function()
      return "t"
    end,
  })
  agentaicore.refresh(nil)
  agentaicore.refresh(reg)
  reg.entries[1] = {
    module_id = "ai_core",
    instance_id = "700",
    driver_version = "20261118.1",
    protocol = 2,
    last_seen = now,
    status = "",
    manifest = { capabilities = { { id = "ai_core.report", version = 1, kind = "request" } } },
  }
  agentaicore.refresh(reg)
  check(
    "live, unverified ai_core -> Found — not verified (v20261118.1)",
    agentaicore.value() == "Found — not verified (v20261118.1)",
    agentaicore.value()
  )
  reg.entries[1].verified = true
  agentaicore.refresh(reg)
  check(
    "live, verified ai_core -> Found — registered (v20261118.1)",
    agentaicore.value() == "Found — registered (v20261118.1)",
    agentaicore.value()
  )
  reg.entries[1].status = "unlicensed"
  agentaicore.refresh(reg)
  reg.entries[1].manifest = {}
  agentaicore.refresh(reg)
  now = now + 3600
  agentaicore.refresh(reg)

  local outside = {}
  for _, v in ipairs(painted) do
    if not values.isValue(v) then
      outside[#outside + 1] = v
    end
  end
  check("every painted value is closed (" .. #painted .. " paints)", #outside == 0, table.concat(outside, " | "))
end

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
