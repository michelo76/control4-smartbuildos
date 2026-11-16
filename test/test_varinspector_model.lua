package.path = "src/?.lua;" .. package.path
local Model = require("varinspector.model")
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

-- ── fake Director ───────────────────────────────────────────────────────────
local clock = { t = 1000 }
local registered, regCalls, unregCalls = {}, 0, 0
local sets, emitted = {}, {}
local setResult = { true }
local devices = {
  [12] = { deviceName = "Kitchen Pendants", driverFileName = "light.c4z", roomId = 3, roomName = "Kitchen" },
  [20] = { deviceName = "Front Lock", driverFileName = "lock.c4z", roomId = 1, roomName = "Entry" },
  [30] = { deviceName = "Bare Device", driverFileName = "x.c4z", roomId = 1, roomName = "Entry" },
  [999] = { deviceName = "Inspector", driverFileName = "smartbuildos-variable-inspector.c4z" },
}
local vars = {
  [12] = {
    ["1001"] = { name = "LIGHT_LEVEL", value = "75", readonly = "false" },
    ["1002"] = { name = "LIGHT_STATE", value = "True", readonly = "false" },
    ["1003"] = { name = "SERIAL", value = "ABC", readonly = "true" },
  },
  [20] = {
    ["2001"] = { name = "LockStatus", value = "Locked" },
    ["2002"] = { name = "USER_CODE_1", value = "1234" },
  },
}
local deps = {
  now = function()
    return clock.t
  end,
  register = function(d, v)
    regCalls = regCalls + 1
    registered[d .. ":" .. v] = true
    return true
  end,
  unregister = function(d, v)
    unregCalls = unregCalls + 1
    registered[d .. ":" .. v] = nil
  end,
  readVariables = function(d)
    return vars[d]
  end,
  devices = function()
    return devices
  end,
  setVariable = function(d, v, value)
    sets[#sets + 1] = { d, v, value }
    return setResult[1], setResult[2]
  end,
  emit = function(kind, detail)
    emitted[#emitted + 1] = { kind = kind, detail = detail }
  end,
  selfDeviceId = 999,
  historySize = 30,
}

print("== masking and snapshots")
check(
  "USER_CODE masked",
  Model.isMasked("USER_CODE_1") and Model.isMasked("Wifi Password") and Model.isMasked("api_token")
)
check("ordinary names not masked", not Model.isMasked("LIGHT_LEVEL") and not Model.isMasked("LockStatus"))
local snap = Model.snapshot(vars[20])
check("snapshot sorted by name", snap[1].name == "LockStatus" and snap[2].name == "USER_CODE_1")
check(
  "masked value hidden and typed masked",
  snap[2].value == Model.MASK and snap[2].type == "masked" and snap[2].masked == true
)
snap = Model.snapshot(vars[12])
check(
  "numbers and booleans typed",
  snap[1].value == 75 and snap[1].type == "number" and snap[2].value == true and snap[2].type == "boolean"
)
check("readonly flag read", snap[3].readonly == true and snap[1].readonly == false)
check("empty snapshot", #Model.snapshot(nil) == 0)

print("== device list and filter")
local list = Model.deviceList(devices, 999)
check(
  "self excluded, sorted by room then name",
  #list == 3 and list[1].name == "Bare Device" and list[2].name == "Front Lock" and list[3].room == "Kitchen"
)
check("filter by name", #Model.filterDevices(list, "lock") == 1 and Model.filterDevices(list, "lock")[1].id == 20)
check("filter by room", #Model.filterDevices(list, "entry") == 2)
check("filter by id", #Model.filterDevices(list, "12") == 1)
check("empty filter returns all", #Model.filterDevices(list, "") == 3)

print("== open / close device")
local ins = Model.new(deps)
local s, why = ins:openDevice(12)
check("open returns snapshot", s ~= nil and #s == 3, why)
check(
  "listeners registered for the open device's variables",
  registered["12:1001"] and registered["12:1002"] and registered["12:1003"] and ins.counters.listeners == 3
)
local s2 = ins:openDevice(20)
check("opening another releases the previous", registered["12:1001"] == nil and registered["20:2001"] ~= nil)
check("masked variable gets no listener", registered["20:2002"] == nil)
check("open unknown device refused", (ins:openDevice(77)) == nil)
check("open self refused", (ins:openDevice(999)) == nil)
check("open device with nothing readable refused", (ins:openDevice(30)) == nil)
check("still open device 20 after refusals", ins.open.device_id == 20)
check("close releases all", ins:closeDevice() == true and count(registered) == 0)
check("close twice false", ins:closeDevice() == false)

print("== live update on the open device")
ins:openDevice(12)
check(
  "change on open device → true, snapshot updated",
  ins:onChange(12, 1001, "40") == true and ins:openSnapshot()[1].value == 40
)
check("change on other device → false", ins:onChange(20, 2001, "Unlocked") == false)
check("no emit for an unwatched change", #emitted == 0)

print("== watch list")
regCalls, unregCalls = 0, 0
local ok, reason = ins:watch(20, 2001)
check(
  "watch by reading the name from the device",
  ok == true and ins.watches["20:2001"].name == "LockStatus" and ins.watches["20:2001"].device_label == "Front Lock",
  reason
)
check("watch registered one listener", regCalls == 1 and registered["20:2001"])
check("watch records the current value", ins.watches["20:2001"].value == "Locked")
ok, reason = ins:watch(20, 2001)
check("duplicate refused", ok == false and reason == "already watched")
ok, reason = ins:watch(20, 2002)
check("masked refused", ok == false and reason:find("never watched") ~= nil, reason)
ok, reason = ins:watch(20, 2099)
check("unknown variable refused", ok == false and reason:find("not found") ~= nil, reason)
ok = ins:watch(12, 1001)
check("watching an open device's variable is fine", ok == true and ins:watchCount() == 2)
ins:closeDevice()
check(
  "closing the device keeps the watched listener and drops the rest",
  registered["12:1001"] and registered["12:1002"] == nil and ins.counters.listeners == 2
)

print("== history and emit")
clock.t = 1010
check("watched change → true", ins:onChange(20, 2001, "Unlocked") == true)
local wl = ins:watchList(5)
check(
  "history entry with previous",
  wl[1].history[1].value == "Unlocked" and wl[1].history[1].previous == "Locked" and wl[1].changes == 1
)
check("emit change", #emitted == 1 and emitted[1].kind == "change" and emitted[1].detail.name == "LockStatus")
check("last set", ins.last.value == "Unlocked" and ins.last.device_label == "Front Lock")
for i = 1, 40 do
  ins:onChange(20, 2001, tostring(i))
end
check(
  "history bounded to historySize (ring floor 50 wins over 30)",
  #ins:watchList(100)[1].history == 41 and ins.historySize == 50 and ins.watches["20:2001"].ring.seq == 41
)
for i = 1, 20 do
  ins:onChange(20, 2001, "x" .. i)
end
check("history capped at 50", #ins:watchList(100)[1].history == 50)
check("watchList newest n", #ins:watchList(3)[1].history == 3)
ins:clearHistory()
check("clear history", #ins:watchList(5)[1].history == 0 and ins.last == nil)

print("== unwatch")
ok, reason = ins:unwatch(20, 2001)
check("unwatch releases its listener", ok == true and registered["20:2001"] == nil and ins:watchCount() == 1)
check("unwatch unknown → false", ins:unwatch(20, 2001) == false)

print("== bounded watch list")
local small = Model.new(setmetatable({ maxWatches = 2 }, { __index = deps }))
check("two fit", small:watch(12, 1001) and small:watch(12, 1002))
ok, reason = small:watch(20, 2001)
check("third refused as full", ok == false and reason:find("full") ~= nil, reason)
check("ceiling 64", Model.new(setmetatable({ maxWatches = 500 }, { __index = deps })).maxWatches == 64)
small:stop()

print("== persistence doc")
local doc = ins:watchDoc()
check("doc lists watches", #doc == 1 and doc[1].device_id == 12 and doc[1].name == "LIGHT_LEVEL")
local again = Model.new(deps)
check("restore re-watches", again:restoreWatches(doc) == 1 and again:watchCount() == 1 and registered["12:1001"])
check("restore ignores junk", again:restoreWatches({ "x", { device_id = 1 } }) == 0)
again:stop()

print("== set (probe)")
emitted = {}
ok, reason = ins:setValue(12, 1001, 50, true)
check("set goes to Director with text value", ok == true and #sets == 1 and sets[1][3] == "50", reason)
check("detail says verify on read", reason:find("verify") ~= nil)
check("set emitted", emitted[1].kind == "set")
ok, reason = ins:setValue(12, 1001, 50, false)
check("without PIN refused", ok == false and reason:find("PIN") ~= nil)
ok, reason = ins:setValue(20, 2002, "9999", true)
check("masked refused", ok == false and reason:find("never written") ~= nil)
ok, reason = ins:setValue(12, 1003, "x", true)
check("read-only variable refused", ok == false and reason:find("read%-only on its device") ~= nil, reason)
ok, reason = ins:setValue(12, 1099, "x", true)
check("unknown variable refused", ok == false and reason:find("not found") ~= nil)
setResult = { false, "nope" }
ok, reason = ins:setValue(12, 1001, 1, true)
check("Director false → refused by name", ok == false and reason:find("nope") ~= nil, reason)
setResult = { true }
check("refusals counted and emitted", ins.counters.refused == 5 and emitted[#emitted].kind == "refused")

print("== read-only mode")
ins:setReadOnly(true)
ok, reason = ins:setValue(12, 1001, 1, true)
check("set refused when read-only", ok == false and reason:find("read%-only") ~= nil)
ok, reason = ins:watch(20, 2001)
check("watch refused when read-only", ok == false)
ok = ins:unwatch(12, 1001)
check("unwatch refused when read-only", ok == false and ins:watchCount() == 1)
check("reads still work", ins:openDevice(20) ~= nil)
ins:setReadOnly(false)

print("== stop")
ins:stop()
check("stop releases every listener", count(registered) == 0 and ins.counters.listeners == 0)
check("status shape", ins:status().watched == 1 and ins:status().read_only == false)
check(
  "formatHistory",
  Model.formatHistory("X", { t = 0, seq = 2, value = 1, previous = 0 }):find("X = 1  %(was 0%)") ~= nil
)

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
