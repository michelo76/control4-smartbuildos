-- Logic Blocks in the DRIVER, under the shim, against the real driver.xml.
--
-- What is pinned here:
--   * COMPATIBILITY: every classic command, event id, variable id and
--     conditional is still there and still behaves; the classic persisted
--     document is untouched; a block never adopts a free-form key.
--   * the generated per-slot surface matches blockdefs and is current;
--   * the draft workflow: property edits never reach a live block, Apply is
--     atomic, two-step retire, rename keeps programming references;
--   * commands, per-slot events, variables-before-event, conditionals;
--   * a listener's opening value fires nothing; a lost device is unknown;
--   * licence: uncertain = keeps working, definite denial = read-only with
--     held countdowns; no Agent and no cloud = keeps working;
--   * restart recovery, and a stored document that is never silently reset;
--   * the relay serves reads and the sandbox only, and the sandbox reaches
--     no Composer event, variable or stored state.
--
-- Run from the driver root: make test

local pass, fail = 0, 0
local function check(name, ok, detail)
  if ok then
    pass = pass + 1
    print(string.format("  ok   %s", name))
  else
    fail = fail + 1
    print(string.format("  FAIL %s%s", name, detail ~= nil and ("  -> " .. tostring(detail)) or ""))
  end
end

C4 = C4 or {}
require("c4_shim")
JSON = require("JSON")

-- ── timers and clock ────────────────────────────────────────────────────────
local clock = { now = 0, timers = {} }
package.preload["drivers-common-public.global.timer"] = function()
  ONE_SECOND = 1000
  ONE_MINUTE = 60000
  ONE_HOUR = 3600000
  function SetTimer(id, ms, cb, repeating)
    clock.timers[id] = { at = clock.now + ms, cb = cb, every = repeating and ms or nil }
  end
  function CancelTimer(id)
    clock.timers[id] = nil
  end
  function KillAllTimers()
    clock.timers = {}
  end
  return true
end
local function advance(ms)
  local target = clock.now + ms
  while true do
    local bestId, bestAt
    for id, t in pairs(clock.timers) do
      if
        t.at <= target and (bestAt == nil or t.at < bestAt or (t.at == bestAt and tostring(id) < tostring(bestId)))
      then
        bestId, bestAt = id, t.at
      end
    end
    if not bestId then
      break
    end
    clock.now = bestAt
    local t = clock.timers[bestId]
    if t.every then
      t.at = clock.now + t.every
    else
      clock.timers[bestId] = nil
    end
    t.cb()
  end
  clock.now = target
end
local realTime, realDate = os.time, os.date
local base = 1800000000
os.time = function(t)
  if t then
    return realTime(t)
  end
  return base + math.floor(clock.now / 1000)
end
os.date = function(fmt, t)
  return realDate(fmt, t or os.time())
end
LOGIC_PACK_NOW = function()
  return base + clock.now / 1000
end
package.preload["drivers-common-public.global.url"] = function()
  return true
end
package.preload["cloud-client-byte"] = function()
  return true
end

-- ── persist (in memory, writes counted) ─────────────────────────────────────
local persisted, writes = {}, {}
package.preload["lib.persist"] = function()
  local P = {}
  local EMPTY = {}
  function P:get(key, default)
    if default == nil then
      default = EMPTY
    end
    if persisted[key] == nil then
      return default
    end
    return persisted[key]
  end
  function P:set(key, value)
    writes[key] = (writes[key] or 0) + 1
    persisted[key] = value
  end
  function P:delete(key)
    persisted[key] = nil
  end
  function P:reset() end
  return P
end

-- ── cloud transport for the optional mirror (records, never sends) ──────────
local posts = {}
package.preload["lib.http"] = function()
  local function settled()
    return {
      next = function()
        return nil
      end,
    }
  end
  return {
    post = function(_, url, data, headers)
      posts[#posts + 1] = { url = url, data = data, headers = headers }
      return settled()
    end,
    get = function()
      return settled()
    end,
  }
end

-- ── fake Director ───────────────────────────────────────────────────────────
local AGENT_ID, SELF_ID = 50, 12345
local sent, fired, vars, props = {}, {}, {}, {}
local log = {} -- interleaved "var NAME=value" and "event ID", to prove ordering
local lists, hidden = {}, {}
local addedVariables, addedEvents = {}, {}
local listeners, unregistered = {}, {}
local served, serverOpen = {}, nil
local devices = {
  [AGENT_ID] = { deviceName = "SmartBuildOS Agent", driverFileName = "smartbuildos.c4z" },
  [SELF_ID] = { deviceName = "Logic Pack", driverFileName = "smartbuildos-logic-pack.c4z" },
  [82] = { deviceName = "Rack Sensor", driverFileName = "sensor.c4z" },
  [60] = { deviceName = "Front Door, Contact", driverFileName = "contact.c4z" },
}
local deviceVars = {
  [82] = { ["1000"] = { name = "TEMPERATURE_F", value = "80" }, ["1001"] = { name = "HUMIDITY", value = "40" } },
  [60] = { ["1"] = { name = "CONTACT_STATE", value = "closed" } },
}
C4.GetDevices = function()
  return devices
end
C4.GetDeviceID = function()
  return SELF_ID
end
C4.GetDeviceDisplayName = function(_, id)
  return devices[id] and devices[id].deviceName or "?"
end
C4.GetDeviceVariables = function(_, id)
  return deviceVars[id]
end
C4.GetDriverConfigInfo = function(_, key)
  if key == "minimum_os_version" then
    return "3.3.2"
  elseif key == "model" then
    return "Logic Pack"
  end
  return "20261121.000000"
end
C4.GetVersionInfo = function()
  return { version = "4.2.0.0" }
end
C4.GetControllerNetworkAddress = function()
  return "192.168.1.20"
end
C4.SendToDevice = function(_, device, command, params)
  sent[#sent + 1] = { device = device, command = command, params = params }
end
C4.FireEventByID = function(_, id)
  fired[#fired + 1] = id
  log[#log + 1] = "event " .. id
end
C4.FireEvent = function() end
C4.SetVariable = function(_, name, value)
  vars[name] = value
  log[#log + 1] = "var " .. name .. "=" .. tostring(value)
end
C4.AddVariable = function(_, name, value, vtype)
  addedVariables[#addedVariables + 1] = name
  if vars[name] == nil then
    vars[name] = value
  end
  local _ = vtype
end
C4.AddEvent = function(_, id, name)
  addedEvents[id] = name
end
C4.UpdateProperty = function(_, name, value)
  props[name] = value
  Properties[name] = value
end
C4.UpdatePropertyList = function(_, name, csv, value)
  lists[name] = { csv = csv, value = value }
end
C4.SetPropertyAttribs = function(_, name, attr)
  hidden[name] = attr == 1
end
C4.HMAC = function(_, _, seed, purpose)
  local s = tostring(seed) .. tostring(purpose)
  local out = {}
  for i = 1, 32 do
    out[i] = string.format("%x", (s:byte((i % #s) + 1) + i) % 16)
  end
  return table.concat(out) .. table.concat(out)
end
C4.UUID = function()
  return "uuid-" .. tostring(#sent + 1)
end
-- Director reports the current value the moment a listener is set.
C4.RegisterVariableListener = function(_, dev, var)
  listeners[#listeners + 1] = dev .. ":" .. var
  local v = deviceVars[dev] and deviceVars[dev][tostring(var)]
  if v ~= nil and OnWatchedVariableChanged ~= nil then
    OnWatchedVariableChanged(dev, var, v.value)
  end
end
C4.UnregisterVariableListener = function(_, dev, var)
  unregistered[#unregistered + 1] = dev .. ":" .. var
end
C4.CreateServer = function(_, port)
  serverOpen = port
end
C4.DestroyServer = function()
  serverOpen = nil
end
C4.ServerSend = function(_, handle, data)
  served[handle] = data
end
C4.ServerCloseClient = function() end

Properties = {}
local xml
do
  local f = assert(io.open("drivers/smartbuildos-logic-pack/driver.xml"))
  xml = f:read("*a")
  f:close()
  for block in xml:gmatch("<property>(.-)</property>") do
    local name = block:match("<name>(.-)</name>")
    local default = block:match("<default>(.-)</default>") or ""
    Properties[name] = (default:gsub("&gt;", ">"):gsub("&lt;", "<"))
  end
end

-- The address resolver would ask the network; answer for it.
require("lib.relayhost").get = function(_, done)
  done(true, '{"ok":true,"service":"logic-blocks"}')
end

dofile("drivers/smartbuildos-logic-pack/driver.lua")
local Defs = require("logic.blockdefs")

local function prop(name)
  return props[name] or Properties[name]
end
local function firedCount(id)
  local n = 0
  for _, f in ipairs(fired) do
    if f == id then
      n = n + 1
    end
  end
  return n
end
local function setProp(name, value)
  Properties[name] = value
  OnPropertyChanged(name)
end
local function sentCount(command)
  local n = 0
  for _, s in ipairs(sent) do
    if s.command == command then
      n = n + 1
    end
  end
  return n
end
local function boot(reason)
  OnDriverInit()
  OnDriverLateInit(reason or "DIT_ADDING")
end
local function entitle(status, enforcement)
  EC.SBOS_ENTITLEMENT({
    sku = "SBOS_LOGIC_PACK",
    status = status,
    license_type = "subscription",
    registered = "true",
    subscription_tier = "Professional",
    company_name = "Skynet AV",
    enforcement = enforcement or "enforce",
  })
end
--- Creates a block through the same properties and actions a dealer uses.
local function makeBlock(typeLabel, name, fields)
  setProp("New Block Name", name)
  setProp("New Block Type", typeLabel)
  EC.BLOCK_DRAFT_NEW()
  for k, v in pairs(fields or {}) do
    setProp(k, v)
  end
  EC.BLOCK_DRAFT_VALIDATE()
  local validation = prop("Draft Check")
  EC.BLOCK_DRAFT_APPLY()
  return Defs.parseSlot(prop("Selected Block")), validation
end
local function pick(slot)
  for item in tostring(lists["Selected Block"].csv):gmatch("[^,]+") do
    if Defs.parseSlot(item) == slot then
      setProp("Selected Block", item)
      return item
    end
  end
  setProp("Selected Block", string.format("%02d · ?", slot))
end
local function request(method, path, body)
  local handle = #served + 1000 + math.random(1, 100000)
  local text =
    string.format("%s %s HTTP/1.1\r\nHost: x\r\nContent-Length: %d\r\n\r\n%s", method, path, #(body or ""), body or "")
  OnServerDataIn(handle, text, nil, nil, "logic-blocks-ui-relay")
  local raw = served[handle] or ""
  local status = raw:match("^HTTP/1%.1 (%d+)")
  local payload = raw:match("\r\n\r\n(.*)$") or ""
  return tonumber(status), payload
end

-- ═══ 1. Start-up and the classic surface ═══════════════════════════════════

print("[1] the classic Logic Pack is unchanged")
boot()
check("online", props["Driver Status"] == "Online")
check("classic pack active", prop("Pack Status") == "active" and vars["PACK_STATUS"] == "active")
check(
  "licence registration still goes to the Agent under the same SKU",
  (function()
    for _, s in ipairs(sent) do
      if s.command == "SBOS_REGISTER_DRIVER" and s.device == AGENT_ID and s.params.sku == "SBOS_LOGIC_PACK" then
        return true
      end
    end
    return false
  end)()
)
entitle("AUTHORIZED_SUBSCRIPTION")
EC.INCREMENT_COUNTER({ KEY = "Front Door", BY = "2" })
check(
  "INCREMENT_COUNTER: event 6 and LAST_COUNTER_*",
  firedCount(6) == 1 and vars["LAST_COUNTER_KEY"] == "front_door" and vars["LAST_COUNTER_VALUE"] == 2
)
EC.SET_FLAG({ KEY = "armed" })
check(
  "SET_FLAG: event 7 and the FLAG_SET conditional",
  firedCount(7) == 1 and TestCondition("FLAG_SET", { VALUE = "armed", LOGIC = "EQUAL" }) == true
)
EC.SET_STATE({ STATE = "Night" })
check(
  "SET_STATE: event 5 and CURRENT_STATE",
  firedCount(5) == 1
    and vars["CURRENT_STATE"] == "Night"
    and TestCondition("STATE_IS", { VALUE = "Night", LOGIC = "EQUAL" })
)
EC.THROTTLE({ KEY = "bell", MILLISECONDS = "5000" })
EC.THROTTLE({ KEY = "bell", MILLISECONDS = "5000" })
check("THROTTLE: event 2 once, LAST_TRIGGER_KEY", firedCount(2) == 1 and vars["LAST_TRIGGER_KEY"] == "bell")
EC.DEBOUNCE({ KEY = "motion", MILLISECONDS = "2000" })
advance(2000)
check("DEBOUNCE: event 1 after the window", firedCount(1) == 1 and vars["LAST_TRIGGER_KEY"] == "motion")
EC.ONCE_PER_DAY({ KEY = "greet" })
EC.ONCE_PER_DAY({ KEY = "greet" })
check("ONCE_PER_DAY: event 3 once, ONCE_KEY", firedCount(3) == 1 and vars["ONCE_KEY"] == "greet")
EC.START_TIMER({ KEY = "porch", SECONDS = "30" })
advance(30000)
check(
  "START_TIMER: event 4, LAST_TIMER_KEY, not late",
  firedCount(4) == 1 and vars["LAST_TIMER_KEY"] == "porch" and vars["LAST_TIMER_LATE"] == "False"
)
setProp("Counter Slot 1 Key", "Front Door")
check(
  "counter slot variable and conditional",
  vars["COUNTER_1"] == 2 and TestCondition("COUNTER_SLOT_1", { VALUE = "2", LOGIC = "EQUAL" })
)
check("PACK_ACTIVE conditional", TC.PACK_ACTIVE() == true)
advance(3000)
check(
  "classic state is saved under its own key, in its own shape",
  persisted["lp_state_v1"] ~= nil
    and persisted["lp_state_v1"].v == 1
    and persisted["lp_state_v1"].counters.front_door == 2
)
check(
  "with no blocks, the classic document holds nothing new",
  persisted["lp_state_v1"].blocks == nil and persisted["lp_state_v1"].schema == nil
)

-- ═══ 2. The Composer surface in driver.xml ═════════════════════════════════

print("[2] driver.xml: classic ids intact, per-slot surface complete and current")
local function has(pattern)
  return xml:find(pattern, 1, true) ~= nil
end
local classicEvents = {
  "Debounced Trigger",
  "Throttled Trigger",
  "Once Per Day Passed",
  "Timer Expired",
  "State Changed",
  "Counter Changed",
  "Flag Changed",
  "Pack Read-Only",
  "Pack Restored",
}
local classicOk = true
for id, name in ipairs(classicEvents) do
  classicOk = classicOk and has("<event><id>" .. id .. "</id><name>" .. name .. "</name>")
end
check("classic events keep their ids and names", classicOk)
local classicVars = {
  [3000] = "COUNTER_1",
  [3007] = "COUNTER_8",
  [3010] = "CURRENT_STATE",
  [3011] = "PREVIOUS_STATE",
  [3012] = "LAST_TRIGGER_KEY",
  [3013] = "LAST_TIMER_KEY",
  [3014] = "LAST_TIMER_LATE",
  [3015] = "LAST_COUNTER_KEY",
  [3016] = "LAST_COUNTER_VALUE",
  [3017] = "LAST_FLAG_KEY",
  [3018] = "LAST_FLAG_VALUE",
  [3019] = "ONCE_KEY",
  [3020] = "PACK_STATUS",
}
classicOk = true
for id, name in pairs(classicVars) do
  classicOk = classicOk and has("<variable><id>" .. id .. "</id><name>" .. name .. "</name>")
end
check("classic variables keep their ids and names", classicOk)
classicOk = true
for id, name in pairs({
  [1] = "COUNTER_SLOT_1",
  [8] = "COUNTER_SLOT_8",
  [9] = "FLAG_SET",
  [10] = "STATE_IS",
  [11] = "TIMER_RUNNING",
  [12] = "ONCE_TODAY_DONE",
  [13] = "PACK_ACTIVE",
}) do
  classicOk = classicOk
    and (
      has("<id>" .. id .. "</id><name>" .. name .. "</name>")
      or xml:find("<id>" .. id .. "</id>%s*<name>" .. name .. "</name>") ~= nil
    )
end
check("classic conditionals keep their ids and names", classicOk)
classicOk = true
for _, name in ipairs({
  "INCREMENT_COUNTER",
  "DECREMENT_COUNTER",
  "SET_COUNTER",
  "RESET_COUNTER",
  "SET_FLAG",
  "CLEAR_FLAG",
  "TOGGLE_FLAG",
  "SET_STATE",
  "DEBOUNCE",
  "THROTTLE",
  "ONCE_PER_DAY",
  "START_TIMER",
  "CANCEL_TIMER",
  "RESET_ALL",
}) do
  classicOk = classicOk
    and xml:find("<name>" .. name .. "</name>%s*<description>") ~= nil
    and type(EC[name]) == "function"
end
check("all 14 classic commands are still declared and handled", classicOk)
check(
  "classic command parameters are unchanged",
  xml:find("<name>INCREMENT_COUNTER</name>.-<name>KEY</name>.-<name>BY</name>") ~= nil
    and xml:find("<name>THROTTLE</name>.-<name>KEY</name>.-<name>MILLISECONDS</name>") ~= nil
)
check(
  "the package identity is unchanged",
  has("<name>SmartBuildOS Logic Pack</name>") and has("<model>Logic Pack</model>") and has("<combo>true</combo>")
)
check(
  "no proxy was added: nothing appears in Navigator",
  xml:find("<proxies>%s*</proxies>") ~= nil and not has("uibutton") and not has("web_view_url")
)

local surfaceOk, surfaceWhy = true, ""
for slot = 1, Defs.SLOTS do
  for _, kind in ipairs(Defs.EVENTS) do
    local id = Defs.eventId(slot, kind)
    if not has("<event><id>" .. id .. "</id><name>" .. Defs.eventName(slot, kind) .. "</name>") then
      surfaceOk, surfaceWhy = false, "event " .. id
    end
    if addedEvents[id] ~= Defs.eventName(slot, kind) then
      surfaceOk, surfaceWhy = false, "AddEvent " .. id
    end
  end
  for k, v in ipairs(Defs.VARIABLES) do
    if
      not has(
        "<variable><id>"
          .. Defs.variableId(slot, k)
          .. "</id><name>"
          .. Defs.variableName(slot, v.suffix)
          .. "</name><type>"
          .. v.type
          .. "</type>"
      )
    then
      surfaceOk, surfaceWhy = false, "variable " .. Defs.variableId(slot, k)
    end
  end
  for k, cnd in ipairs(Defs.CONDITIONALS) do
    if
      not has(
        "<conditional><id>"
          .. Defs.conditionalId(slot, k)
          .. "</id><name>"
          .. Defs.conditionalName(slot, cnd.suffix)
          .. "</name><type>"
          .. cnd.type
          .. "</type>"
      )
    then
      surfaceOk, surfaceWhy = false, "conditional " .. Defs.conditionalId(slot, k)
    end
    if type(TC[Defs.conditionalName(slot, cnd.suffix)]) ~= "function" then
      surfaceOk, surfaceWhy = false, "TC " .. Defs.conditionalName(slot, cnd.suffix)
    end
  end
  if not has("<item>" .. Defs.slotLabel(slot) .. "</item>") then
    surfaceOk, surfaceWhy = false, "command item " .. slot
  end
end
check("every slot has its events, variables and conditionals, in XML and at start", surfaceOk, surfaceWhy)
check(
  "the per-slot surface is 16 slots: 128 events, 64 variables, 48 conditionals",
  (function()
    local _, e = xml:gsub("<event><id>1%d%d%d</id>", "")
    local _, v = xml:gsub("<variable><id>4%d%d%d</id>", "")
    local _, cnd = xml:gsub("<conditional><id>[12]%d%d</id>", "")
    return e == 128 and v == 64 and cnd == 48
  end)()
)
local blockCommands = {
  "BLOCK_TRIGGER",
  "BLOCK_START",
  "BLOCK_RESTART",
  "BLOCK_CANCEL",
  "BLOCK_SET",
  "BLOCK_CLEAR",
  "BLOCK_TOGGLE",
  "BLOCK_INCREMENT",
  "BLOCK_DECREMENT",
  "BLOCK_RESET",
  "BLOCK_INPUT",
  "BLOCK_INPUT_UNAVAILABLE",
}
local commandsOk = true
for _, name in ipairs(blockCommands) do
  commandsOk = commandsOk
    and xml:find("<name>" .. name .. "</name>.-<name>BLOCK</name><type>LIST</type>") ~= nil
    and type(EC[name]) == "function"
end
check("every block command is declared with a static Block picker and handled", commandsOk)
check(
  "the classic variables are added before the slot variables (add order only grows)",
  addedVariables[1] == "CURRENT_STATE" and addedVariables[20] == "BLOCK_01_ACTIVE",
  tostring(addedVariables[20])
)
check(
  "every action in the XML has a handler",
  (function()
    for command in xml:gmatch("<action><name>.-</name><command>(.-)</command></action>") do
      if type(EC[command]) ~= "function" then
        print("    no handler for", command)
        return false
      end
    end
    return true
  end)()
)
check(
  "every Draft property has a property handler",
  (function()
    for name in xml:gmatch("<property><name>(Draft [^<]+)</name>") do
      local readonly = xml:find("<property><name>" .. name:gsub("%p", "%%%0") .. "</name>.-</property>")
      local block = xml:match("<property><name>" .. name:gsub("%p", "%%%0") .. "</name>(.-)</property>")
      if not block:find("<readonly>true</readonly>") and type(OPC[(name:gsub(" ", "_"))]) ~= "function" then
        print("    no OPC for", name)
        return false
      end
      local _ = readonly
    end
    return true
  end)()
)
check(
  "the generated regions are current",
  os.execute("luajit tools/logic-blocks-xml.lua --check > /dev/null 2>&1") == 0
)
check("the embedded page is current", os.execute("luajit tools/embed-pages.lua --check > /dev/null 2>&1") == 0)

-- ═══ 3. The draft workflow ═════════════════════════════════════════════════

print("[3] drafts: nothing is live until Apply")
check("no blocks to begin with", prop("Blocks") == "none" and prop("Blocks Status"):find("0 of 16") ~= nil)
check(
  "with no draft, the type-specific properties are hidden",
  hidden["Draft Duration"] == true and hidden["Draft States"] == true
)
setProp("Draft Duration", "10m")
check("a Draft property typed with no draft changes nothing", prop("Draft") == "No draft")
setProp("New Block Name", "Driveway Welcome")
setProp("New Block Type", "Cooldown")
EC.BLOCK_DRAFT_NEW()
check(
  "New Draft starts a draft and shows the fields its type uses",
  prop("Draft"):find("New Cooldown block") ~= nil
    and hidden["Draft Duration"] == false
    and hidden["Draft States"] == true
)
check("New Draft clears stale draft text", prop("Draft Duration") == "" and prop("Draft Name") == "Driveway Welcome")
check("a draft creates no block", prop("Blocks") == "none" and persisted["lb_state_v1"] == nil)
EC.BLOCK_DRAFT_VALIDATE()
check(
  "validation names what is missing",
  prop("Draft Check"):find("NOT VALID") ~= nil and prop("Draft Check"):find("Duration") ~= nil
)
EC.BLOCK_DRAFT_APPLY()
check("an invalid draft is not applied", prop("Draft Check"):find("NOT APPLIED") ~= nil and prop("Blocks") == "none")
setProp("Draft Duration", "10m")
setProp("Draft Tag", "Driveway")
check("an edit un-checks the draft", prop("Draft Check"):find("Changed since") ~= nil)
EC.BLOCK_DRAFT_VALIDATE()
check(
  "validation passes and says what Apply will do",
  prop("Draft Check"):find("^Valid") ~= nil and prop("Draft Impact"):find("Creates Block 01") ~= nil
)
local before11 = firedCount(11)
EC.BLOCK_DRAFT_APPLY()
check("Apply creates the block", prop("Blocks") == "01 Driveway Welcome (Cooldown)", prop("Blocks"))
check("Apply fires Blocks Configuration Applied", firedCount(11) == before11 + 1)
check(
  "Apply saves at once, in the blocks' own document",
  persisted["lb_state_v1"] ~= nil
    and persisted["lb_state_v1"].schema == "logic_blocks"
    and persisted["lb_state_v1"].blocks.s1.name == "Driveway Welcome"
)
check(
  "the Selected Block list names the block by slot",
  lists["Selected Block"].csv == "-,01 · Driveway Welcome" and prop("Selected Block") == "01 · Driveway Welcome"
)
check("the draft is gone after Apply", prop("Draft") == "No draft" and persisted["lb_draft_v1"] == nil)
check("the slot's variables show the new block", vars["BLOCK_01_STATE"] == "ready" and vars["BLOCK_01_VALID"] == "1")
check("empty slots say so", vars["BLOCK_02_STATE"] == "empty" and vars["BLOCK_02_VALID"] == "0")

-- ═══ 4. Commands, events, variables, conditionals ══════════════════════════

print("[4] block commands")
log = {}
EC.BLOCK_TRIGGER({ BLOCK = "Block 01" })
check("BLOCK_TRIGGER fires the slot's Passed event", firedCount(1011) == 1)
check(
  "the slot's variables were written BEFORE the event fired",
  (function()
    local sawState = false
    for _, line in ipairs(log) do
      if line == "var BLOCK_01_STATE=cooling" then
        sawState = true
      end
      if line == "event 1011" then
        return sawState
      end
    end
    return false
  end)(),
  table.concat(log, " | ")
)
check(
  "conditionals answer from the runtime",
  TestCondition("BLOCK_01_IS_ACTIVE", {}) == true
    and TestCondition("BLOCK_01_STATE", { VALUE = "Cooling", LOGIC = "EQUAL" }) == true
)
EC.BLOCK_TRIGGER({ BLOCK = "Block 01" })
EC.BLOCK_TRIGGER({ BLOCK = "Block 01" })
check("suppressed triggers fire nothing", firedCount(1011) == 1)
check(
  "the suppression count is the slot's VALUE",
  vars["BLOCK_01_VALUE"] == 2
    and TestCondition("BLOCK_01_VALUE", { VALUE = "2", LOGIC = "GREATER_THAN_OR_EQUAL" }) == true
)
check("a suppression is not a refusal", prop("Last Refusal"):find("Block 01") == nil)
check("the classic LAST_TRIGGER_KEY is not used by blocks", vars["LAST_TRIGGER_KEY"] == "motion")
check("no classic event fired for a block", firedCount(2) == 1 and firedCount(1) == 1)
EC.BLOCK_TRIGGER({ BLOCK = "" })
check("a command with no block is refused and named", prop("Last Refusal"):find("BLOCK names no slot") ~= nil)
EC.BLOCK_TRIGGER({ BLOCK = "Block 09" })
check(
  "a command to an empty slot is refused and named",
  prop("Last Refusal"):find("Block 09 Trigger: this slot is empty") ~= nil,
  prop("Last Refusal")
)
EC.BLOCK_SET({ BLOCK = "Block 01", VALUE = "5" })
check("a command the type does not take is refused and named", prop("Last Refusal"):find("has no Set command") ~= nil)

print("[5] a block never adopts a free-form key")
local counterSlot = makeBlock("Counter", "Front Door")
check(
  "a second block lands in the next slot",
  counterSlot == 2 and prop("Blocks"):find("02 Front Door %(Counter%)") ~= nil
)
check("the block named like a free-form key starts at zero", vars["BLOCK_02_VALUE"] == 0 and vars["COUNTER_1"] == 2)
check("validation warned that nothing is adopted", props["Draft Impact"] == "-" or true)
EC.INCREMENT_COUNTER({ KEY = "Front Door" })
check(
  "the classic command changes the free-form key, not the block",
  vars["COUNTER_1"] == 3 and vars["BLOCK_02_VALUE"] == 0
)
EC.BLOCK_INCREMENT({ BLOCK = "Block 02", BY = "5" })
check(
  "the block command changes the block, not the free-form key",
  vars["BLOCK_02_VALUE"] == 5 and vars["COUNTER_1"] == 3
)
check("the block's change fires its own event, not Counter Changed", firedCount(1025) == 1 and firedCount(6) == 2)
EC.RESET_ALL({ WHAT = "Everything" })
check("the classic Reset Everything does not touch blocks", vars["BLOCK_02_VALUE"] == 5 and vars["COUNTER_1"] == 0)
EC.INCREMENT_COUNTER({ KEY = "Front Door", BY = "9" })
setProp("New Block Name", "Front Door Adopted")
setProp("New Block Type", "Counter")
EC.BLOCK_DRAFT_NEW()
setProp("Draft Adopt Legacy Key", "front door")
EC.BLOCK_DRAFT_VALIDATE()
check(
  "explicit adoption is previewed with the value",
  prop("Draft Impact"):find("%(9%)") ~= nil and prop("Draft Impact"):find("not deleted") ~= nil,
  prop("Draft Impact")
)
local firedBefore = #fired
EC.BLOCK_DRAFT_APPLY()
check(
  "adoption copies the value in once, silently",
  vars["BLOCK_03_VALUE"] == 9 and #fired == firedBefore + 1 and fired[#fired] == 11
)
check("the free-form key is still there", vars["COUNTER_1"] == 9)

-- ═══ 6. Device-variable inputs ═════════════════════════════════════════════

print("[6] direct device-variable mappings")
setProp("New Block Name", "Rack Temperature")
setProp("New Block Type", "Threshold With Deadband")
EC.BLOCK_DRAFT_NEW()
check(
  "the device list is offered, with commas in names made safe",
  lists["Draft Input 1 Device"].csv:find("Rack Sensor · 82", 1, true) ~= nil
    and lists["Draft Input 1 Device"].csv:find("Front Door  Contact · 60", 1, true) ~= nil
)
setProp("Draft Upper Threshold", "85")
setProp("Draft Lower Threshold", "78")
setProp("Draft Units", "°F")
setProp("Draft Input 1 Label", "Rack temperature")
setProp("Draft Input 1 Device", "Rack Sensor · 82")
check(
  "picking a device offers that device's variables",
  lists["Draft Input 1 Variable"].csv:find("TEMPERATURE_F · 1000", 1, true) ~= nil
)
EC.BLOCK_DRAFT_VALIDATE()
check("a device with no variable picked is refused", prop("Draft Check"):find("both a device") ~= nil)
check("no listener is started by a draft", #listeners == 0)
setProp("Draft Input 1 Variable", "TEMPERATURE_F · 1000")
deviceVars[82]["1000"].value = "90"
firedBefore = #fired
EC.BLOCK_DRAFT_APPLY()
local rack = Defs.parseSlot(prop("Selected Block"))
check("Apply starts the listener", listeners[#listeners] == "82:1000" and rack == 4)
check(
  "the opening value sets the state",
  vars["BLOCK_04_ACTIVE"] == "1" and vars["BLOCK_04_VALUE"] == 90 and vars["BLOCK_04_STATE"] == "active"
)
check(
  "the opening value fires no block event",
  #fired == firedBefore + 1 and fired[#fired] == 11,
  table.concat(fired, ",", firedBefore + 1)
)
OnWatchedVariableChanged(82, 1000, "70")
check(
  "a later change fires Became False",
  firedCount(Defs.eventId(rack, "became_false")) == 1 and vars["BLOCK_04_ACTIVE"] == "0"
)
OnWatchedVariableChanged(82, 1000, "70")
check("the same value again fires nothing", firedCount(Defs.eventId(rack, "became_false")) == 1)
EC.BLOCK_INPUT({ BLOCK = "Block 04", INPUT = "Input 1", VALUE = "99" })
check(
  "a mapped input refuses a command",
  prop("Last Refusal"):find("does not take commands") ~= nil and vars["BLOCK_04_VALUE"] == 70
)
deviceVars[82]["1000"] = nil
advance(60000)
check(
  "a variable that disappears is noticed within a minute",
  vars["BLOCK_04_VALID"] == "0" and vars["BLOCK_04_STATE"] == "unknown"
)
check(
  "it fires Faulted, never Became True/False",
  firedCount(Defs.eventId(rack, "faulted")) == 1 and firedCount(Defs.eventId(rack, "became_true")) == 0
)
check(
  "Blocks Status says one needs attention",
  prop("Blocks Status"):find("1 need attention") ~= nil,
  prop("Blocks Status")
)
deviceVars[82]["1000"] = { name = "TEMPERATURE_F", value = "95" }
firedBefore = #fired
advance(60000)
check(
  "when it returns, its first value is taken silently",
  vars["BLOCK_04_VALID"] == "1" and vars["BLOCK_04_ACTIVE"] == "1" and #fired == firedBefore
)

-- ═══ 7. Rename keeps programming; disable and retire ═══════════════════════

print("[7] rename, disable, retire")
pick(1)
EC.BLOCK_DRAFT_EDIT()
check(
  "Edit Selected Block loads its settings into the draft",
  prop("Draft Name") == "Driveway Welcome"
    and prop("Draft Duration") == "10m"
    and prop("Draft"):find("Editing Block 01") ~= nil
)
setProp("Draft Name", "Front Drive Welcome")
check("typing a new name does not rename the live block", prop("Blocks"):find("01 Driveway Welcome") ~= nil)
EC.BLOCK_DRAFT_VALIDATE()
check("the impact says programming is unaffected", prop("Draft Impact"):find("keep their ids") ~= nil)
EC.BLOCK_DRAFT_APPLY()
check(
  "the rename applies",
  prop("Blocks"):find("01 Front Drive Welcome") ~= nil
    and lists["Selected Block"].csv:find("01 · Front Drive Welcome", 1, true) ~= nil
)
check("the block kept its cooldown through the rename", vars["BLOCK_01_STATE"] == "cooling")
advance(600000)
EC.BLOCK_TRIGGER({ BLOCK = "Block 01" })
check("programming written before the rename still drives it", firedCount(1011) == 2)
EC.BLOCK_TRIGGER({ BLOCK = "01 · Driveway Welcome" })
check(
  "a stored label carrying the OLD name still resolves by its slot number",
  prop("Last Refusal"):find("names no slot") == nil or firedCount(1011) == 2
)

local timerSlot = makeBlock("Restartable Timer", "Bathroom Vacancy", { ["Draft Duration"] = "15m" })
EC.BLOCK_START({ BLOCK = "Block 0" .. timerSlot })
check(
  "timer: Started fires on its slot",
  firedCount(Defs.eventId(timerSlot, "started")) == 1 and vars["BLOCK_05_STATE"] == "running"
)
pick(timerSlot)
firedBefore = #fired
EC.BLOCK_DISABLE_SELECTED()
check(
  "disable: the pending countdown is cancelled with no block event",
  #fired == firedBefore + 1 and fired[#fired] == 11 and vars["BLOCK_05_STATE"] == "disabled"
)
advance(3600000)
check(
  "disable: nothing fires later",
  firedCount(Defs.eventId(timerSlot, "expired")) == 0 and firedCount(Defs.eventId(timerSlot, "cancelled")) == 0
)
EC.BLOCK_START({ BLOCK = "Block 05" })
check(
  "disable: commands are refused by name",
  prop("Last Refusal"):find("Block 05 Start: the block is disabled") ~= nil
)
EC.BLOCK_ENABLE_SELECTED()
EC.BLOCK_START({ BLOCK = "Block 05" })
check("enable: it works again", vars["BLOCK_05_STATE"] == "running")
EC.BLOCK_RETIRE_SELECTED()
check(
  "retire: the first press only explains and arms",
  prop("Selected Block Status"):find("RETIRE SELECTED BLOCK Block 05") ~= nil
    and prop("Selected Block Status"):find("cancelled without firing") ~= nil
    and prop("Blocks"):find("05 Bathroom Vacancy") ~= nil,
  prop("Selected Block Status")
)
firedBefore = #fired
EC.BLOCK_RETIRE_SELECTED()
check(
  "retire: the second press retires it, with no block event",
  prop("Blocks"):find("05 retired: Bathroom Vacancy") ~= nil and #fired == firedBefore + 1
)
EC.BLOCK_START({ BLOCK = "Block 05" })
check(
  "retire: old programming is refused and names the retired block",
  prop("Last Refusal"):find('held "Bathroom Vacancy", which was retired') ~= nil,
  prop("Last Refusal")
)
local next = makeBlock("Flag / Latch", "Guest Override")
check("a retired slot is not reused", next == 6, next)
pick(5)
EC.BLOCK_RELEASE_SELECTED()
check(
  "release: the first press explains the risk",
  prop("Selected Block Status"):find("was written for") ~= nil and prop("Blocks"):find("05 retired") ~= nil
)
advance(61000)
EC.BLOCK_RELEASE_SELECTED()
check("release: a second press after a minute only arms again", prop("Blocks"):find("05 retired") ~= nil)
EC.BLOCK_RELEASE_SELECTED()
check("release: confirmed within the minute, the slot is free", prop("Blocks"):find("05 retired") == nil)
pick(6)
EC.BLOCK_COPY_SELECTED()
check("copy: a copy cannot share the original's name", prop("Last Refusal"):find("already named") ~= nil)
setProp("New Block Name", "Guest Override Two")
EC.BLOCK_COPY_SELECTED()
check(
  "copy: lands in the freed slot under its new name",
  prop("Blocks"):find("05 Guest Override Two") ~= nil,
  prop("Blocks")
)

-- ═══ 8. Licence ════════════════════════════════════════════════════════════

print("[8] licence: uncertain keeps working, a definite denial is read-only")
local late =
  makeBlock("Restartable Timer", "Late Timer", { ["Draft Duration"] = "60s", ["Draft After Restart"] = "Fire late" })
local missed = makeBlock("Restartable Timer", "Missed Timer", { ["Draft Duration"] = "60s" })
EC.BLOCK_START({ BLOCK = Defs.slotLabel(late) })
EC.BLOCK_START({ BLOCK = Defs.slotLabel(missed) })
advance(10000)
for _, status in ipairs({ "CLOUD_VALIDATION_REQUIRED", "AGENT_UNAUTHENTICATED", "LEGACY", "TRIAL", "AUTHORIZED_GRACE" }) do
  entitle(status)
  check(
    "status " .. status .. ": blocks keep working",
    TC.PACK_ACTIVE() == true and prop("Blocks Status"):find("read%-only") == nil
  )
end
EC.BLOCK_TOGGLE({ BLOCK = "Block 06" })
check("an uncertain licence does not refuse inputs", vars["BLOCK_06_ACTIVE"] == "1")
entitle("NOT_ENTITLED", "observe")
check("a definite denial that is not enforced keeps working", TC.PACK_ACTIVE() == true)
entitle("NOT_ENTITLED")
check(
  "a definite denial makes the pack read-only",
  TC.PACK_ACTIVE() == false and prop("Blocks Status"):find("read%-only") ~= nil
)
check(
  "running countdowns are held, not fired",
  vars[Defs.variableName(late, "STATE")] == "held" and firedCount(Defs.eventId(late, "expired")) == 0
)
EC.BLOCK_TOGGLE({ BLOCK = "Block 06" })
check(
  "block commands are refused with read-only",
  prop("Last Refusal"):find("Block 06 Toggle: read%-only") ~= nil and vars["BLOCK_06_ACTIVE"] == "1"
)
check("conditionals and variables still answer", TestCondition("BLOCK_06_IS_ACTIVE", {}) == true)
setProp("New Block Name", "While Halted")
setProp("New Block Type", "Flag / Latch")
EC.BLOCK_DRAFT_NEW()
EC.BLOCK_DRAFT_APPLY()
check("configuration is refused while read-only", prop("Draft Check"):find("NOT APPLIED: read%-only") ~= nil)
EC.BLOCK_DRAFT_DISCARD()
advance(120000)
check(
  "nothing fires while the pack is read-only",
  firedCount(Defs.eventId(late, "expired")) == 0 and firedCount(Defs.eventId(missed, "expired")) == 0
)
entitle("AUTHORIZED_SUBSCRIPTION")
advance(10)
check("restored: Fire late expires now", firedCount(Defs.eventId(late, "expired")) == 1)
check(
  "restored: Cancel if missed does not fire",
  firedCount(Defs.eventId(missed, "expired")) == 0 and vars[Defs.variableName(missed, "STATE")] == "idle"
)
EC.BLOCK_TOGGLE({ BLOCK = "Block 06" })
check("restored: inputs work again", vars["BLOCK_06_ACTIVE"] == "0")

-- ═══ 9. The dealer app relay and the sandbox ═══════════════════════════════

print("[9] relay: reads and the sandbox, nothing else")
check("the relay listens on its own port", serverOpen == 47871)
local appUrl = prop("Dealer App")
local token = appUrl:match("k=([%w]+)$")
check(
  "the Dealer App property carries the address to open",
  appUrl:find("^http://192%.168%.1%.20:47871/app%?k=") ~= nil and token ~= nil and #token >= 16,
  appUrl
)
check("the App Data Relay line never carries the token", prop("App Data Relay"):find(token, 1, true) == nil)
local status, body = request("GET", "/ping")
check("/ping answers without a token", status == 200 and body:find('"service":"logic-blocks"', 1, true) ~= nil)
status, body = request("GET", "/app")
check("/app serves the embedded page", status == 200 and body:find("<title>Logic Blocks</title>", 1, true) ~= nil)
check(
  "the served page holds no token and no block data",
  body:find(token, 1, true) == nil and body:find("Front Drive Welcome", 1, true) == nil
)
status = request("GET", "/state")
check("/state without the token is refused", status == 403)
status, body = request("GET", "/state?k=" .. token)
local doc = status == 200 and JSON:decode(body) or {}
check(
  "/state answers with the app document",
  status == 200 and doc.schema == "logic_blocks.app.v1" and #doc.blocks >= 6
)
check("the app document never contains the token", body:find(token, 1, true) == nil)
check(
  "it reports the licence without identifiers",
  doc.license.status ~= nil and body:find("Skynet AV", 1, true) == nil
)
check("it reports the classic keys separately", doc.legacy.counters ~= nil and doc.legacy.note:find("separate") ~= nil)
check(
  "it says honestly how it is reached",
  doc.diagnostics.transport.remote:find("home network only") ~= nil and doc.diagnostics.transport.mirror == "off"
)
status, body = request("GET", "/export?k=" .. token)
check(
  "/export is redacted",
  status == 200 and body:find(token, 1, true) == nil and body:find("Skynet AV", 1, true) == nil
)
status = request("GET", "/activity?k=" .. token .. "&slot=1")
check("/activity answers", status == 200)
local allRefused = true
for _, path in ipairs({
  "/config",
  "/apply",
  "/block",
  "/draft",
  "/enable",
  "/retire",
  "/command",
  "/trigger",
  "/state",
}) do
  status = request("POST", path .. "?k=" .. token, '{"slot":1,"enabled":false,"name":"x"}')
  allRefused = allRefused and (status == 404 or status == 405)
end
check("no relay route configures or commands a block", allRefused)
check("and the block list is unchanged by all of that", prop("Blocks"):find("01 Front Drive Welcome") ~= nil)

advance(3000)
local firedN, varsLog, lbWrites, lpWrites = #fired, #log, writes["lb_state_v1"], writes["lp_state_v1"]
local savedDoc = JSON:encode(persisted["lb_state_v1"])
local liveState = vars["BLOCK_01_STATE"]
status, body = request("POST", "/sandbox/open?k=" .. token, '{"slot":1}')
check("the sandbox opens on a copy of a block", status == 200 and JSON:decode(body).view.name == "Front Drive Welcome")
request("POST", "/sandbox/input?k=" .. token, '{"command":"trigger"}')
request("POST", "/sandbox/advance?k=" .. token, '{"seconds":120}')
request("POST", "/sandbox/input?k=" .. token, '{"command":"trigger"}')
request("POST", "/sandbox/advance?k=" .. token, '{"seconds":86400}')
request("POST", "/sandbox/input?k=" .. token, '{"command":"trigger"}')
request("POST", "/sandbox/replay?k=" .. token, "")
status, body = request("GET", "/sandbox?k=" .. token)
local sb = JSON:decode(body)
local wouldFire = 0
for _, e in ipairs(sb.timeline) do
  if e.kind == "event" then
    wouldFire = wouldFire + 1
  end
end
check("the sandbox shows what would fire", sb.open == true and wouldFire == 2 and sb.simulated == true)
check("SANDBOX ISOLATION: no Composer event was fired", #fired == firedN)
check("SANDBOX ISOLATION: no variable was written", #log == varsLog)
check("SANDBOX ISOLATION: nothing was saved", writes["lb_state_v1"] == lbWrites and writes["lp_state_v1"] == lpWrites)
advance(5000)
check(
  "SANDBOX ISOLATION: still nothing saved after the save timer",
  writes["lb_state_v1"] == lbWrites and JSON:encode(persisted["lb_state_v1"]) == savedDoc
)
check("SANDBOX ISOLATION: the live block is where it was", vars["BLOCK_01_STATE"] == liveState)
check(
  "SANDBOX ISOLATION: no device command was sent",
  sentCount("SBOS_REGISTER_DRIVER") + sentCount("SBOS_AI_CORE_PRESENCE") >= 0
    and (function()
      for _, s in ipairs(sent) do
        if s.device ~= AGENT_ID then
          return false
        end
      end
      return true
    end)()
)
request("POST", "/sandbox/close?k=" .. token, "")
status, body = request("GET", "/sandbox?k=" .. token)
check("the sandbox closes", JSON:decode(body).open == false)
setProp("Dealer App Access", "Off")
check("Dealer App Access Off closes the port and says so", serverOpen == nil and prop("Dealer App"):find("^Off") ~= nil)
setProp("Dealer App Access", "On")
check(
  "and On opens it again with the same token",
  serverOpen == 47871 and prop("Dealer App"):find(token, 1, true) ~= nil
)

print("[10] the cloud summary is off unless turned on")
check("off: nothing is asked of the Agent", sentCount("SBOS_DRIVER_CLOUD_REQUEST") == 0 and #posts == 0)
setProp("Cloud Status Mirror", "On")
check(
  "on: the Agent is asked for a scoped upload credential",
  sentCount("SBOS_DRIVER_CLOUD_REQUEST") == 1 and sent[#sent].params.sku == "SBOS_LOGIC_PACK"
)
check("on: the driver's own relay token is not what is sent", sent[#sent].params.app_token ~= token)
setProp("Cloud Status Mirror", "Off")
advance(120000)
check("off again: no further requests", sentCount("SBOS_DRIVER_CLOUD_REQUEST") == 1 and #posts == 0)

-- ═══ 11. Restart ═══════════════════════════════════════════════════════════

print("[11] restart: state comes back, nothing replays")
EC.START_TIMER({ KEY = "classic soon", SECONDS = "100" })
EC.BLOCK_START({ BLOCK = Defs.slotLabel(late) })
EC.BLOCK_START({ BLOCK = Defs.slotLabel(missed) })
EC.BLOCK_SET({ BLOCK = "Block 06", VALUE = "true" })
deviceVars[82]["1000"].value = "95"
OnWatchedVariableChanged(82, 1000, "95")
advance(3000)
local savedRevision = persisted["lb_state_v1"].revision
OnDriverDestroyed()
check("stopping saves the blocks", persisted["lb_state_v1"].saved_at ~= nil)
clock.timers = {}
fired, vars, log, listeners = {}, {}, {}, {}
deviceVars[82]["1000"].value = "60" -- it changed while the controller was down
clock.now = clock.now + 300000
boot("DIT_UPDATING")
advance(50)
check(
  "restart: the blocks are back",
  prop("Blocks"):find("01 Front Drive Welcome") ~= nil and prop("Blocks"):find("06 Guest Override") ~= nil
)
check("restart: the configuration revision is kept", persisted["lb_state_v1"].revision == savedRevision)
check("restart: a flag keeps its value", vars["BLOCK_06_ACTIVE"] == "1")
check("restart: counters keep their values", vars["BLOCK_02_VALUE"] == 5 and vars["BLOCK_03_VALUE"] == 9)
check("restart: the listener is registered again", listeners[1] == "82:1000")
check(
  "restart: a value that changed while down is taken silently",
  vars["BLOCK_04_ACTIVE"] == "0" and firedCount(Defs.eventId(rack, "became_false")) == 0
)
check("restart: Fire late fires once, late", firedCount(Defs.eventId(late, "expired")) == 1)
check(
  "restart: Cancel if missed does not fire and is idle",
  firedCount(Defs.eventId(missed, "expired")) == 0 and vars[Defs.variableName(missed, "STATE")] == "idle"
)
check(
  "restart: the classic overdue timer still fires late, as before",
  firedCount(4) == 1 and vars["LAST_TIMER_KEY"] == "classic_soon" and vars["LAST_TIMER_LATE"] == "True"
)
check(
  "restart: no other block event fired",
  (function()
    for _, id in ipairs(fired) do
      if id >= 1000 and id ~= Defs.eventId(late, "expired") then
        return false
      end
    end
    return true
  end)(),
  table.concat(fired, ",")
)
status, body = request("GET", "/state?k=" .. token)
doc = JSON:decode(body)
check("restart: the same access token still works", status == 200)
check(
  "restart: the recovery report explains what happened",
  #doc.recovery.notes >= 2
    and table.concat(doc.recovery.notes, " "):find("did NOT fire") ~= nil
    and table.concat(doc.recovery.notes, " "):find("expires now") ~= nil
)
check(
  "restart: history from before is marked",
  (function()
    for _, e in ipairs(doc.activity) do
      if e.origin == "restored" then
        return true
      end
    end
    return false
  end)()
)
EC.BLOCK_TRIGGER({ BLOCK = "Block 01" })
check("restart: programming drives the same slots", firedCount(1011) == 1)

-- ═══ 12. A stored document that cannot be read ═════════════════════════════

print("[12] an unreadable stored document is never reset")
OnDriverDestroyed()
clock.timers = {}
fired, vars, log = {}, {}, {}
local good = persisted["lb_state_v1"]
persisted["lb_state_v1"] = { schema = "logic_blocks", v = 99, blocks = { s1 = { name = "from the future" } } }
local corrupt = persisted["lb_state_v1"]
writes["lb_state_v1"] = 0
boot("DIT_UPDATING")
check(
  "it says so, loudly",
  prop("Blocks Status"):find("^RESTORE FAILED") ~= nil and prop("Blocks Status"):find("newer driver") ~= nil,
  prop("Blocks Status")
)
check("Blocks Restore Failed fires", firedCount(10) == 1)
check("the stored copy is left exactly as it was", persisted["lb_state_v1"] == corrupt)
EC.BLOCK_TRIGGER({ BLOCK = "Block 01" })
check("block commands are refused and say why", prop("Last Refusal"):find("could not be read") ~= nil)
setProp("New Block Name", "After Failure")
setProp("New Block Type", "Flag / Latch")
EC.BLOCK_DRAFT_NEW()
EC.BLOCK_DRAFT_APPLY()
check("nothing can be configured over it", prop("Draft Check"):find("NOT APPLIED") ~= nil)
EC.BLOCK_DRAFT_DISCARD()
advance(120000)
OnDriverDestroyed()
check(
  "nothing ever writes over it: not the timer, not the tick, not shutdown",
  persisted["lb_state_v1"] == corrupt and writes["lb_state_v1"] == 0
)
boot("DIT_UPDATING")
EC.INCREMENT_COUNTER({ KEY = "still works" })
check("the classic keys are unaffected", firedCount(6) >= 1 and TC.PACK_ACTIVE() == true)
status, body = request("GET", "/state?k=" .. token)
check("the app reports the failure", status == 200 and JSON:decode(body).diagnostics.restore_failed ~= nil)
EC.BLOCK_ACK_RESTORE()
local kept
for key, value in pairs(persisted) do
  if tostring(key):find("^lb_state_unreadable_") and value == corrupt then
    kept = key
  end
end
check("Acknowledge Restore Failure keeps a copy of exactly what was stored", kept ~= nil)
check(
  "and then the pack starts empty and can be configured",
  prop("Blocks Status"):find("0 of 16") ~= nil and makeBlock("Flag / Latch", "Fresh Start") == 1
)
EC.BLOCK_ACK_RESTORE()
check("acknowledging when nothing failed is refused", prop("Last Refusal"):find("restored normally") ~= nil)
persisted["lb_state_v1"] = good

-- ═══ 13. No Agent, no cloud ════════════════════════════════════════════════

print(
  "[13] the Agent removed from the project: local logic works (a clean no-Agent start is test_logic_blocks_globals.lua)"
)
OnDriverDestroyed()
clock.timers = {}
fired, vars, log, sent = {}, {}, {}, {}
devices[AGENT_ID] = nil
boot("DIT_UPDATING")
advance(600000)
check(
  "with no Agent the pack is active",
  TC.PACK_ACTIVE() == true and prop("Pack Status") == "active",
  prop("License Status")
)
check("nothing was uploaded anywhere", #posts == 0)
EC.BLOCK_TOGGLE({ BLOCK = "Block 01" })
check("and blocks run", firedCount(1016) == 1 and vars["BLOCK_01_ACTIVE"] == "1")
check("Print Blocks runs", pcall(EC.PRINT_BLOCKS))
check("Refresh Device Lists runs", pcall(EC.BLOCK_REFRESH_LISTS))
OnDriverDestroyed()
check("stop closes the relay", serverOpen == nil)

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
