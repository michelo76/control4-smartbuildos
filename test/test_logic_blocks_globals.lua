-- The Logic Pack loaded with NOTHING faked, in a project with NO Agent and
-- no network: the real timer, persist, http and url modules.
--
-- Two things only this file proves:
--   * every global the driver's libraries call exists. `lib.http` (under
--     sbos.mirror) calls the GLOBAL `urlDo`, which only
--     `drivers-common-public.global.url` defines and only the driver's own
--     require list pulls in. If that require is dropped, this fails.
--   * local logic does not depend on the Agent or the cloud: with neither,
--     the driver comes online, a block is created the dealer's way, runs,
--     and nothing is sent to any device or any URL.
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
package.preload["cloud-client-byte"] = function()
  return {}
end
require("c4_shim")

function C4:GetDriverConfigInfo(key)
  return ({ model = "Logic Pack", version = "20261121.000000", minimum_os_version = "3.3.2" })[key]
end
function C4:GetVersionInfo()
  return { version = "4.2.0" }
end

local sent, fired, vars, dispatched = {}, {}, {}, 0
function C4:GetDevices()
  return { [12345] = { deviceName = "Logic Pack", driverFileName = "smartbuildos-logic-pack.c4z" } }
end
function C4:GetDeviceID()
  return 12345
end
function C4:SendToDevice(device, command)
  sent[#sent + 1] = tostring(device) .. " " .. tostring(command)
end
function C4:FireEventByID(id)
  fired[#fired + 1] = id
end
function C4:SetVariable(name, value)
  vars[name] = value
end
function C4:UpdateProperty(name, value)
  Properties[name] = tostring(value)
end
function C4:url()
  dispatched = dispatched + 1
  local t = {}
  function t:SetOptions()
    return self
  end
  function t:OnDone()
    return self
  end
  function t:Get()
    return self
  end
  function t:Post()
    return self
  end
  return t
end

Properties = {}
do
  local f = assert(io.open("drivers/smartbuildos-logic-pack/driver.xml"))
  local xml = f:read("*a")
  f:close()
  for block in xml:gmatch("<property>(.-)</property>") do
    Properties[block:match("<name>(.-)</name>")] = (block:match("<default>(.-)</default>") or ""):gsub("&gt;", ">")
  end
end

local loaded, err = pcall(dofile, "drivers/smartbuildos-logic-pack/driver.lua")
check("the driver loads with nothing faked", loaded, err)
check("urlDo is defined (drivers-common-public.global.url is required)", type(urlDo) == "function")
check("the shared timer helpers are defined", type(SetTimer) == "function" and type(CancelTimer) == "function")
check(
  "the shared variable-listener helpers are defined",
  type(RegisterVariableListener) == "function" and type(OnWatchedVariableChanged) == "function"
)
check("JSON is a global, as the relay and the mirror expect", type(JSON) == "table")

local started, startErr = pcall(function()
  OnDriverInit()
  OnDriverLateInit("DIT_ADDING")
end)
check("it starts with no Agent and no network", started, startErr)
check("online", Properties["Driver Status"] == "Online", Properties["Driver Status"])
check(
  "the licence line says there is no Agent",
  tostring(Properties["License Status"]):find("No SmartBuildOS Agent") ~= nil,
  Properties["License Status"]
)
check("the pack is active without an Agent", TC.PACK_ACTIVE() == true)
check(
  "the blocks start empty and say so",
  tostring(Properties["Blocks Status"]):find("0 of 16") ~= nil,
  Properties["Blocks Status"]
)

local function setProp(name, value)
  Properties[name] = value
  OnPropertyChanged(name)
end
setProp("New Block Name", "Guest Override")
setProp("New Block Type", "Flag / Latch")
EC.BLOCK_DRAFT_NEW()
EC.BLOCK_DRAFT_VALIDATE()
check("a draft validates", tostring(Properties["Draft Check"]):find("^Valid") ~= nil, Properties["Draft Check"])
EC.BLOCK_DRAFT_APPLY()
check(
  "a block is created the dealer's way",
  tostring(Properties["Blocks"]):find("01 Guest Override") ~= nil,
  Properties["Blocks"]
)
EC.BLOCK_TOGGLE({ BLOCK = "Block 01" })
check(
  "it runs: the slot's event fires and its variables are written",
  fired[#fired] == 1016 and vars["BLOCK_01_ACTIVE"] == "1"
)
EC.INCREMENT_COUNTER({ KEY = "classic" })
check("the classic commands run too", vars["LAST_COUNTER_KEY"] == "classic")
check("nothing was sent to any device", #sent == 0, table.concat(sent, "; "))
check("the cloud summary is off, so nothing asked for the network", Properties["Cloud Status Mirror"] == "Off")
check("stopping does not throw", pcall(OnDriverDestroyed))

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
