package.path = "src/?.lua;" .. package.path
local Sources = require("usage.sources")
local Catalog = require("tracer.catalog")
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
local function count(t)
  local n = 0
  for _ in pairs(t) do
    n = n + 1
  end
  return n
end

print("== press event names")
check(
  "Pushed/Pressed/Clicked/Tapped count",
  Sources.isPressEvent("Top Button Pushed")
    and Sources.isPressEvent("Pressed")
    and Sources.isPressEvent("Single Click")
    and Sources.isPressEvent("Double Tap")
)
check("Released does not", Sources.isPressEvent("Top Button Released") == false)
check("other events do not", Sources.isPressEvent("Online") == false and Sources.isPressEvent(nil) == false)

local devices = {
  [12] = { deviceName = "Kitchen Pendants", driverFileName = "light_v2.c4i", roomId = 3, roomName = "Kitchen" },
  [13] = { deviceName = "Office Lamp", driverFileName = "light_v2.c4i", roomId = 4, roomName = "Office" },
  [20] = { deviceName = "Garage Door", driverFileName = "contact.c4i", roomId = 7, roomName = "Garage" },
  [40] = { deviceName = "Hall Keypad", driverFileName = "keypad.c4z", roomId = 3, roomName = "Kitchen" },
  [41] = { deviceName = "Dimmer Keypad", driverFileName = "dimmer_keypad.c4z", roomId = 4, roomName = "Office" },
  [50] = { deviceName = "SmartBuildOS Agent", driverFileName = "smartbuildos.c4z" },
  [999] = {
    deviceName = "Usage Analytics",
    driverFileName = "smartbuildos-usage-analytics.c4z",
    roomId = 3,
    roomName = "Kitchen",
  },
}
local variables = {
  [3] = {
    ["1000"] = { name = "CURRENT_SELECTED_DEVICE", value = "0" },
    ["1005"] = { name = "POWER_STATE", value = "False" },
    ["1006"] = { name = "CURRENT_VOLUME", value = "10" },
  },
  [4] = {
    ["1000"] = { name = "CURRENT_SELECTED_DEVICE", value = "0" },
    ["1005"] = { name = "POWER_STATE", value = "True" },
  },
  [7] = { ["1009"] = { name = "ROOM_NAME", value = "Garage" } }, -- no media variables
  [12] = { ["1001"] = { name = "LIGHT_LEVEL", value = "0" }, ["1002"] = { name = "LIGHT_STATE", value = "False" } },
  [13] = { ["1001"] = { name = "Brightness Percent", value = "50" } },
  [20] = { ["2001"] = { name = "ContactState", value = "Closed" } },
  [41] = { ["1002"] = { name = "LIGHT_STATE", value = "True" } },
}
local catalog = Catalog.new({
  builtin = {
    ["keypad.c4z"] = { [1] = "Top Button Pushed", [2] = "Bottom Button Pushed", [3] = "Top Button Released" },
    ["dimmer_keypad.c4z"] = { [1] = "Click", [2] = "Double Click" },
    ["contact.c4i"] = { [1] = "Opened", [2] = "Closed" },
    ["smartbuildos.c4z"] = { [1] = "Connected" },
  },
})
local deps = {
  devices = devices,
  readVariables = function(id)
    return variables[id]
  end,
  catalog = catalog,
  selfDeviceId = 999,
}

print("== plan")
local plan = Sources.plan(deps)
check("rooms with media variables: Kitchen and Office", count(plan.rooms) == 2 and plan.rooms[3] and plan.rooms[4])
check(
  "Garage without media variables counted, not planned",
  plan.rooms[7] == nil and plan.summary.rooms_without_vars == 1
)
check(
  "room vars: only POWER_STATE and CURRENT_SELECTED_DEVICE",
  count(plan.rooms[3].vars) == 2 and plan.rooms[3].vars[1005] == "POWER_STATE"
)
check(
  "lights by signature: 12, 13 and the dimmer keypad 41",
  count(plan.lights) == 3 and plan.lights[12] and plan.lights[13] and plan.lights[41]
)
check("light labels and rooms", plan.lights[13].label == "Office Lamp" and plan.lights[13].room == "Office")
check("keypads by press events: 40 and 41", count(plan.keypads) == 2 and plan.keypads[40] and plan.keypads[41])
check("Released not subscribed", plan.keypads[40].events[3] == nil and count(plan.keypads[40].events) == 2)
check("contact and Agent are not keypads", plan.keypads[20] == nil and plan.keypads[50] == nil)
check("self never planned", plan.lights[999] == nil)
check(
  "summary counts",
  plan.summary.rooms == 2
    and plan.summary.lights == 3
    and plan.summary.keypads == 2
    and plan.summary.listeners == 4 + 4
    and plan.summary.subscriptions == 4,
  plan.summary.listeners
)
check(
  "describe line",
  Sources.describe(plan.summary):find("2 room%(s%), 3 light%(s%), 2 keypad%(s%)") ~= nil,
  Sources.describe(plan.summary)
)

print("== exclusions and caps")
local p2 = Sources.plan({
  devices = devices,
  readVariables = deps.readVariables,
  catalog = catalog,
  selfDeviceId = 999,
  excluded = { [12] = true, [3] = true },
})
check("excluded light and room dropped", p2.lights[12] == nil and p2.rooms[3] == nil and p2.summary.excluded == 2)
local many = {}
local manyVars = {}
for i = 1, 250 do
  many[1000 + i] = { deviceName = "L" .. i, driverFileName = "light_v2.c4i", roomId = 1, roomName = "Hall" }
  manyVars[1000 + i] = { ["1002"] = { name = "LIGHT_STATE", value = "False" } }
end
manyVars[1] = { ["1005"] = { name = "POWER_STATE", value = "False" } }
local p3 = Sources.plan({
  devices = many,
  readVariables = function(id)
    return manyVars[id]
  end,
  catalog = catalog,
})
check(
  "light cap honoured in id order",
  p3.summary.lights == Sources.LIMITS.lights and p3.lights[1001] ~= nil and p3.lights[1250] == nil
)
check("over-cap counted", p3.summary.over_cap == 50, p3.summary.over_cap)
check(
  "no catalog → no keypads, no crash",
  (function()
    local p = Sources.plan({ devices = devices, readVariables = deps.readVariables })
    return count(p.keypads) == 0 and count(p.lights) == 3
  end)()
)
check("describe with nil", Sources.describe(nil) == "not planned yet")

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
