-- Companion drivers under the shim against a FAKE bridge: discovery by exact
-- filename, the export list, state → proxy notifies, confirmed-versus-
-- requested, freshness → ONLINE_CHANGED/events, control → bridge request,
-- refusal → event. Light and relay are loaded as whole drivers in turn.
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

C4 = C4 or {}
require("c4_shim")
JSON = require("JSON")

package.preload["drivers-common-public.global.timer"] = function()
  ONE_SECOND = 1000
  function SetTimer() end
  function CancelTimer() end
  function KillAllTimers() end
  return true
end
package.preload["cloud-client-byte"] = function()
  return true
end
local persisted = {}
package.preload["lib.persist"] = function()
  local P = {}
  -- Mirrors src/lib/persist.lua: a nil default becomes the library's EMPTY
  -- table, so a missing key answers `{}`, never nil (the 2026-10-20 bench
  -- crash: a fresh bridge loaded `{}` as its registry).
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
    persisted[key] = value
  end
  function P:delete(key)
    persisted[key] = nil
  end
  return P
end

local sent, notifies, fired = {}, {}, {}
function C4:GetDevices()
  return {
    [700] = { driverFileName = "smartbuildos-system-link.c4z" },
    [701] = { driverFileName = "smartbuildos-system-link-light.c4z" },
    [900] = { driverFileName = "smartbuildos.c4z" },
  }
end
function C4:SendToDevice(id, command, params)
  sent[#sent + 1] = { id = id, command = command, params = params }
end
function C4:SendToProxy(binding, command, params, kind)
  notifies[#notifies + 1] = { binding = binding, command = command, params = params, kind = kind }
end
function C4:FireEventByID(id)
  fired[#fired + 1] = id
end
function C4:GetDeviceID()
  return 701
end
function C4:GetDriverConfigInfo(tag)
  if tag == "minimum_os_version" then
    return "3.3.2"
  end
  return "20261018.1"
end
function C4:GetVersionInfo()
  return { version = "3.3.2.1" }
end
function C4:UpdatePropertyList(name, list)
  Properties[name .. "__list"] = list
end
function C4:UpdateProperty(name, value)
  Properties[name] = tostring(value)
end

local function lastSent(command)
  for i = #sent, 1, -1 do
    if sent[i].command == command then
      return sent[i]
    end
  end
end
local function lastNotify(command)
  for i = #notifies, 1, -1 do
    if notifies[i].command == command then
      return notifies[i]
    end
  end
end
local function countFired(id)
  local n = 0
  for _, e in ipairs(fired) do
    if e == id then
      n = n + 1
    end
  end
  return n
end

Properties = { ["Log Level"] = "1 - Error", ["Log Mode"] = "Print", ["Linked Export"] = "-" }
for _, p in ipairs({
  "Bridge Link",
  "Remote System State",
  "Freshness",
  "Control",
  "Confirmed State",
  "Requested State",
  "Last Result",
  "Driver Status",
  "Driver Version",
  "Control Window",
}) do
  Properties[p] = ""
end

print("\n[1] light companion: discovery and export list")
dofile("drivers/smartbuildos-system-link-light/driver.lua")
OnDriverInit()
OnDriverLateInit()
check("online", Properties["Driver Status"] == "Online")
local hello = lastSent("SBOS_LINK_COMPANION_HELLO")
check(
  "hello went to the bridge (700) with kind light",
  hello and hello.id == 700 and hello.params.kind == "light",
  hello and hello.id
)
EC.SBOS_LINK_COMPANION_EXPORTS({
  exports = JSON:encode({
    { id = "x1", name = "Porch_Light", kind = "light", control = true, ops = { "on", "off", "set_level" } },
  }),
})
check(
  "Linked Export list painted from the bridge",
  Properties["Linked Export__list"] == "-,Porch_Light",
  Properties["Linked Export__list"]
)

print("\n[2] assignment, state → proxy, confirmed vs requested")
EC.SBOS_LINK_COMPANION_ASSIGN({ export = "Porch_Light" })
check("assignment selects and persists the export", persisted["sl_companion_export"] == "Porch_Light")
EC.SBOS_LINK_COMPANION_STATE({
  export = "Other",
  fields = JSON:encode({ On = true, Level = 10 }),
  fresh = "current",
  state = "Ready",
  control = "true",
})
check("state for another export is ignored", lastNotify("LIGHT_BRIGHTNESS_CHANGED") == nil)
EC.SBOS_LINK_COMPANION_STATE({
  export = "Porch_Light",
  fields = JSON:encode({ On = true, Level = 40 }),
  fresh = "current",
  state = "Ready",
  control = "true",
})
local n = lastNotify("LIGHT_BRIGHTNESS_CHANGED")
check(
  "confirmed level shown on the proxy",
  n and n.params.LIGHT_BRIGHTNESS_CURRENT == 40 and lastNotify("ONLINE_CHANGED").params.STATE == "TRUE",
  n and n.params.LIGHT_BRIGHTNESS_CURRENT
)
check("Confirmed State property", Properties["Confirmed State"] == "On 40%", Properties["Confirmed State"])
check("conditional REMOTE_CURRENT true", TC.REMOTE_CURRENT() == true)
RFP.SET_BRIGHTNESS_TARGET(5001, nil, { LIGHT_BRIGHTNESS_TARGET = "75", RATE = "500" })
local ctl = lastSent("SBOS_LINK_COMPANION_CONTROL")
check(
  "slider → control request to the bridge, not a proxy notify",
  ctl
    and ctl.params.op == "set_level"
    and JSON:decode(ctl.params.params).level == 75
    and lastNotify("LIGHT_BRIGHTNESS_CHANGED").params.LIGHT_BRIGHTNESS_CURRENT == 40
)
check(
  "Requested State separate from Confirmed",
  Properties["Requested State"]:match("^75%%") and Properties["Confirmed State"] == "On 40%"
)
EC.SBOS_LINK_COMPANION_RESULT({ export = "Porch_Light", op = "set_level", status = "accepted", reason = "" })
check("Last Result accepted", Properties["Last Result"] == "accepted")

print("\n[1b] the owner's control window is shown and enforced locally")
EC.SBOS_LINK_COMPANION_STATE({
  export = "Porch_Light",
  fields = JSON:encode({ On = true, Level = 40, Window = false }),
  fresh = "current",
  state = "Ready",
  control = "true",
  window = "Mon–Fri 07:00–22:00 (America/New_York)",
})
check(
  "Control Window shows the schedule and that it is closed",
  Properties["Control Window"] == "Mon–Fri 07:00–22:00 (America/New_York) — closed now",
  Properties["Control Window"]
)
sent = {}
local refusedBefore = countFired(3)
RFP.ON(5001)
check(
  "a command while the window is closed is refused here, with the window named, and nothing is sent",
  lastSent("SBOS_LINK_COMPANION_CONTROL") == nil
    and Properties["Last Result"]:find("outside the control window %(Mon–Fri") ~= nil
    and countFired(3) == refusedBefore + 1,
  Properties["Last Result"]
)
table.remove(fired) -- keep the later refusal count unaffected
EC.SBOS_LINK_COMPANION_STATE({
  export = "Porch_Light",
  fields = JSON:encode({ On = true, Level = 40, Window = true }),
  fresh = "current",
  state = "Ready",
  control = "true",
  window = "Mon–Fri 07:00–22:00 (America/New_York)",
})
check("open now", Properties["Control Window"]:find("open now") ~= nil, Properties["Control Window"])
RFP.ON(5001)
check(
  "the command goes through once the window is open",
  lastSent("SBOS_LINK_COMPANION_CONTROL") ~= nil and lastSent("SBOS_LINK_COMPANION_CONTROL").params.op == "on"
)
EC.SBOS_LINK_COMPANION_STATE({
  export = "Porch_Light",
  fields = JSON:encode({ On = true, Level = 40 }),
  fresh = "current",
  state = "Ready",
  control = "true",
})
check("no schedule: none", Properties["Control Window"] == "none", Properties["Control Window"])
EC.SBOS_LINK_COMPANION_STATE({
  export = "Porch_Light",
  fields = JSON:encode({ On = true, Level = 75 }),
  fresh = "current",
  state = "Ready",
  control = "true",
})
check(
  "feedback confirms 75",
  lastNotify("LIGHT_BRIGHTNESS_CHANGED").params.LIGHT_BRIGHTNESS_CURRENT == 75
    and Properties["Confirmed State"] == "On 75%"
)
EC.SBOS_LINK_COMPANION_STATE({
  export = "Porch_Light",
  fields = JSON:encode({ On = false, Level = 0 }),
  fresh = "current",
  state = "Ready",
  control = "true",
})
check("Remote Light Off event", countFired(5) == 1)
RFP.OFF(5001)
check("OFF → control off", lastSent("SBOS_LINK_COMPANION_CONTROL").params.op == "off")

print("\n[3] freshness and refusal")
EC.SBOS_LINK_COMPANION_STATE({
  export = "Porch_Light",
  fields = JSON:encode({ On = false, Level = 0 }),
  fresh = "stale",
  state = "Offline",
  control = "false",
})
check(
  "stale → ONLINE_CHANGED FALSE and Remote Value Stale event",
  lastNotify("ONLINE_CHANGED").params.STATE == "FALSE" and countFired(2) == 1 and TC.REMOTE_CURRENT() == false
)
EC.SBOS_LINK_COMPANION_STATE({
  export = "Porch_Light",
  fields = JSON:encode({ On = JSON.null, Level = JSON.null }),
  fresh = "current",
  state = "Ready",
  control = "true",
})
check("null fields render unavailable, never a fabricated level", Properties["Confirmed State"] == "unavailable")
EC.SBOS_LINK_COMPANION_RESULT({
  export = "Porch_Light",
  op = "on",
  status = "failed",
  reason = "outside the permitted schedule",
})
check(
  "refusal fires Control Refused with the owner's reason",
  countFired(3) == 1 and Properties["Last Result"]:match("schedule")
)

print("\n[4] relay companion: pulse is one request; relay state only from feedback")
sent, notifies, fired = {}, {}, {}
Properties["Linked Export"] = "-"
persisted = {}
package.loaded["systemlink.companiondriver"] = nil
package.loaded["systemlink.companion"] = nil
dofile("drivers/smartbuildos-system-link-relay/driver.lua")
OnDriverInit()
OnDriverLateInit()
EC.SBOS_LINK_COMPANION_ASSIGN({ export = "Gate_Relay" })
RFP.GET_STATE(200)
check("no state notify before any feedback", lastNotify("STATE_CLOSED") == nil and lastNotify("STATE_OPENED") == nil)
RFP.TRIGGER(200)
local t = lastSent("SBOS_LINK_COMPANION_CONTROL")
check("TRIGGER → one trigger request", t and t.params.op == "trigger")
check(
  "no second message to release the pulse",
  (function()
    local n = 0
    for _, m in ipairs(sent) do
      if m.command == "SBOS_LINK_COMPANION_CONTROL" then
        n = n + 1
      end
    end
    return n == 1
  end)()
)
EC.SBOS_LINK_COMPANION_STATE({
  export = "Gate_Relay",
  fields = JSON:encode({ Closed = true }),
  fresh = "current",
  state = "Ready",
  control = "true",
})
check("feedback CLOSED notifies the RELAY binding", lastNotify("CLOSED") ~= nil and TC.RELAY_CLOSED() == true)
RFP.GET_STATE(200)
check("GET_STATE answers STATE_CLOSED from confirmed state", lastNotify("STATE_CLOSED") ~= nil)

print("\n[6] media room companion: variables, events, no control")
sent, notifies, fired = {}, {}, {}
Properties["Linked Export"] = "-"
persisted = {}
package.loaded["systemlink.companiondriver"] = nil
package.loaded["systemlink.companion"] = nil
local mediaVars = {}
local savedAddVar, savedSetVar = C4.AddVariable, C4.SetVariable
function C4:AddVariable(name, default, vtype, readOnly)
  mediaVars[name] = { value = default, readOnly = readOnly }
end
function C4:SetVariable(name, value)
  if mediaVars[name] then
    mediaVars[name].value = value
  end
end
dofile("drivers/smartbuildos-system-link-media/driver.lua")
OnDriverInit()
OnDriverLateInit()
check(
  "read-only variables exist for programming",
  mediaVars.Powered
    and mediaVars.Powered.readOnly == true
    and mediaVars.Source ~= nil
    and mediaVars.Volume ~= nil
    and mediaVars.Media ~= nil
)
EC.SBOS_LINK_COMPANION_ASSIGN({ export = "Kitchen_Room" })
EC.SBOS_LINK_COMPANION_STATE({
  export = "Kitchen_Room",
  fields = JSON:encode({ Powered = true, Source = "Kitchen TV", Volume = 32, Media = JSON.null }),
  fresh = "current",
  state = "Ready",
  control = "false",
})
check(
  "confirmed state reads on · source · volume",
  Properties["Confirmed State"] == "On · Kitchen TV · volume 32",
  Properties["Confirmed State"]
)
check(
  "variables follow the fields",
  mediaVars.Powered.value == "1"
    and mediaVars.Source.value == "Kitchen TV"
    and mediaVars.Volume.value == "32"
    and TC.ROOM_ON() == true
)
EC.SBOS_LINK_COMPANION_STATE({
  export = "Kitchen_Room",
  fields = JSON:encode({ Powered = false, Source = "", Volume = 0, Media = JSON.null }),
  fresh = "current",
  state = "Ready",
  control = "false",
})
check(
  "a live power change fires Remote Room Off and the state reads Off",
  countFired(5) == 1 and Properties["Confirmed State"] == "Off" and TC.ROOM_ON() == false
)
check(
  "no control verb: nothing was ever sent to the bridge as a command",
  lastSent("SBOS_LINK_COMPANION_CONTROL") == nil
)
C4.AddVariable, C4.SetVariable = savedAddVar, savedSetVar

print("\n[7] lock, gate and fan companions: status, events, gated Test actions")
for _, c in ipairs({
  {
    kind = "lock",
    field = "Locked",
    onText = "Locked",
    offText = "Unlocked",
    cond = "LOCK_LOCKED",
    test = "TEST_LOCK",
    op = "lock",
  },
  {
    kind = "gate",
    field = "Open",
    onText = "Open",
    offText = "Closed",
    cond = "GATE_OPEN",
    test = "TEST_TRIGGER",
    op = "trigger",
  },
  {
    kind = "fan",
    field = "Speed",
    onText = "Speed 5",
    offText = "Off",
    cond = "FAN_ON",
    test = "TEST_SPEED_5",
    op = "set_speed",
  },
}) do
  sent, notifies, fired = {}, {}, {}
  Properties["Linked Export"] = "-"
  persisted = {}
  package.loaded["systemlink.companiondriver"] = nil
  package.loaded["systemlink.companion"] = nil
  local vars = {}
  local sAdd, sSet = C4.AddVariable, C4.SetVariable
  function C4:AddVariable(name, default, vtype, readOnly)
    vars[name] = { value = default, readOnly = readOnly }
  end
  function C4:SetVariable(name, value)
    if vars[name] then
      vars[name].value = value
    end
  end
  dofile("drivers/smartbuildos-system-link-" .. c.kind .. "/driver.lua")
  OnDriverInit()
  OnDriverLateInit()
  EC.SBOS_LINK_COMPANION_ASSIGN({ export = "X_" .. c.kind })
  local onValue = c.kind == "fan" and 5 or true
  local offValue = c.kind == "fan" and 0 or false
  EC.SBOS_LINK_COMPANION_STATE({
    export = "X_" .. c.kind,
    fields = JSON:encode({ [c.field] = onValue }),
    fresh = "current",
    state = "Ready",
    control = "true",
  })
  check(
    c.kind .. ": on state reads " .. c.onText .. " and the conditional holds",
    Properties["Confirmed State"] == c.onText and TC[c.cond]() == true and vars[c.field] ~= nil,
    Properties["Confirmed State"]
  )
  EC.SBOS_LINK_COMPANION_STATE({
    export = "X_" .. c.kind,
    fields = JSON:encode({ [c.field] = offValue }),
    fresh = "current",
    state = "Ready",
    control = "true",
  })
  check(
    c.kind .. ": a live change fires the off event and reads " .. c.offText,
    countFired(5) == 1 and Properties["Confirmed State"] == c.offText and TC[c.cond]() == false,
    Properties["Confirmed State"]
  )
  EC[c.test]()
  local ctl = lastSent("SBOS_LINK_COMPANION_CONTROL")
  check(
    c.kind .. ": the Test action sends the op to the bridge (the owner decides, by licence)",
    ctl ~= nil and ctl.params.op == c.op,
    ctl and ctl.params.op
  )
  C4.AddVariable, C4.SetVariable = sAdd, sSet
end

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
