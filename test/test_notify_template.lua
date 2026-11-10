-- Notification Router message variables (src/notify/template.lua), pure:
-- which `${…}` are tokens, picked variables (${1}..${4}) and variables
-- written out the Control4 way (${Room->Device::VARIABLE}), lookup by name
-- and by id, on/off wording, rounding, a picked variable that is not written
-- into the text being added at the end, what happens when a value cannot be
-- read, credentials never sent, one pass only.
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

local T = require("notify.template")

-- A small project: C4:GetDevices and C4:GetDeviceVariables shapes.
local DEVICES = {
  [231] = { deviceName = "Garage Door", roomName = "Garage" },
  [240] = { deviceName = "Thermostat", roomName = "Living" },
  [241] = { deviceName = "Thermostat", roomName = "Master" },
  [300] = { deviceName = "Front: Lock", roomName = "Entry" },
}
local VARIABLES = {
  [231] = { ["1000"] = { name = "STATE", value = "1" }, ["1001"] = { name = "Last Opened By", value = "Remote" } },
  [240] = {
    ["1100"] = { name = "TEMPERATURE_F", value = "72.46" },
    ["1101"] = { name = "HVAC_MODE", value = "Cool" },
    ["1102"] = { name = "HOLD", value = "False" },
  },
  [241] = { ["1100"] = { name = "TEMPERATURE_F", value = "68" } },
  [300] = {
    ["1"] = { name = "LOCK_STATUS", value = "locked" },
    ["2"] = { name = "LAST_USER_CODE", value = "4321" },
    ["3"] = { name = "BATTERY", value = "0" },
  },
  [100001] = {
    ["7"] = { name = "Vacation Mode", value = "0" },
    ["8"] = { name = "Pool Temp", value = "81.5" },
    ["9"] = { name = "Echo", value = "${1} and ${Garage Door::STATE}" },
    ["10"] = { name = "Multi Line", value = "first\nsecond\tthird" },
  },
}
local reads = {}
local picks = {}
local function picked(n)
  return picks[n]
end
local function newResolver()
  return T.resolver({
    picked = picked,
    devices = function()
      return DEVICES
    end,
    readVariables = function(id)
      reads[#reads + 1] = id
      return VARIABLES[id]
    end,
  })
end
local function render(text)
  return T.render(text, newResolver())
end
local function fill(title, body)
  return T.fill(title, body, newResolver(), picked)
end

print("[1] which ${…} are tokens")
check("a picked variable", T.parseToken("1").kind == "pick" and T.parseToken(" 4 ").pick == 4)
check(
  "a variable written out the Control4 way",
  (function()
    local r = T.parseToken("Living->Apple TV 2::AUTOPLAY_STATE")
    return r.kind == "named" and r.device == "Living->Apple TV 2" and r.variable == "AUTOPLAY_STATE"
  end)()
)
check(
  "options after the bar, empty ones kept",
  (function()
    local r = T.parseToken("1|Open|")
    return #r.options == 2 and r.options[1] == "Open" and r.options[2] == ""
  end)()
)
check("plain words are not a token", T.parseToken("hello") == nil and T.parseToken("") == nil)
check("two digits are not a pick", T.parseToken("12") == nil)
check("a half reference is not a token", T.parseToken("Garage::") == nil and T.parseToken("::STATE") == nil)
check(
  "what a VARIABLE parameter carries",
  select(2, T.parsePick("82,5015")) == 5015 and T.parsePick(" 82 , 5015 ") == 82
)
check("nothing picked", T.parsePick("") == nil and T.parsePick(nil) == nil and T.parsePick("82") == nil)

print("[2] picked variables: ${1}..${4}")
picks = { [1] = "231,1000", [2] = "240,1100", [3] = "100001,8", [4] = "" }
local text, problems, used = render("Garage ${1}, living ${2}, pool ${3}")
check("values only, no names", text == "Garage 1, living 72.46, pool 81.5", text)
check(
  "nothing to report; the picks written in the text are known",
  #problems == 0 and used[1] and used[2] and used[3] and not used[4]
)
text, problems = render("a ${4} b ${5} c ${0}")
check("unfilled tokens become ? and the text is kept", text == "a ? b ? c ?", text)
check(
  "each one says why",
  #problems == 3
    and problems[1].token == "${4}"
    and problems[1].reason:find("nothing picked in VARIABLE 4", 1, true)
    and problems[2].reason:find("run from 1 to 4", 1, true)
    and problems[3].reason:find("run from 1 to 4", 1, true),
  problems[1] and problems[1].reason
)
picks = { [1] = "999,1", [2] = "231,7777" }
text, problems = render("${1} ${2}")
check(
  "a device or a variable that is gone",
  text == "? ?"
    and problems[1].reason:find("device 999 has no readable variables", 1, true)
    and problems[2].reason:find("device 231 has no variable '7777'", 1, true),
  problems[2] and problems[2].reason
)

print("[3] variables written out")
picks = {}
check(
  "Room->Device::VARIABLE, as the Push agent writes it",
  render("Door is ${Garage->Garage Door::STATE}") == "Door is 1"
)
check("the device alone when its name is unique", render("${Garage Door::STATE}") == "1")
check("names ignore case, spaces and underscores", render("${garage door::Last_Opened_By}") == "Remote")
check("the room settles a repeated name", render("${Master->Thermostat::TEMPERATURE_F}") == "68")
check("by device id; the variable by name or id", render("${240::HVAC_MODE} ${240::1101}") == "Cool Cool")
check("a device name with a colon", render("${Front: Lock::LOCK_STATUS}") == "locked")
check("project variables", render("${Variables::Pool Temp} ${project::vacation mode}") == "81.5 0")
text, problems = render("${Nowhere::STATE} ${Garage Door::NOPE} ${Thermostat::HVAC_MODE}")
check(
  "unknown device, unknown variable, ambiguous device",
  text == "? ? ?"
    and problems[1].reason == "no device called 'Nowhere'"
    and problems[2].reason:find("no variable 'NOPE'", 1, true)
    and problems[3].reason:find("write Room->Device or the device id", 1, true),
  problems[3] and problems[3].reason
)

print("[4] what is not a token is left alone")
check("plain braces", render("{1} {hello} {Garage Door:STATE} { }") == "{1} {hello} {Garage Door:STATE} { }")
check("JSON", render('{"a": 1} ${"a"}') == '{"a": 1} ${"a"}')
check("a dollar amount", render("costs $5 and ${hello}") == "costs $5 and ${hello}")
check("text without tokens", render("Door left open") == "Door left open")
check("nil and numbers", render(nil) == "" and render(42) == "42")
check("an unclosed token", render("a ${1 b") == "a ${1 b")
check("a token across lines", render("${1\n}") == "${1\n}")

print("[5] on/off wording")
picks = { [1] = "231,1000", [2] = "240,1100" }
check("1 → first text", render("${1|Open|Closed}") == "Open")
check("0 → second text", render("${Variables::Vacation Mode|On|Off}") == "Off")
check("False → second text", render("${240::HOLD|held|following schedule}") == "following schedule")
check("a non-zero number → first text", render("${2|heating|idle}") == "heating")
check("other text is sent as it is", render("${240::HVAC_MODE|On|Off}") == "Cool")
check("an empty second text", render("Lock${300::BATTERY| battery ok|}.") == "Lock.")
check(
  "truth table",
  T.truth("YES") == true
    and T.truth(" off ") == false
    and T.truth("") == false
    and T.truth("-3") == true
    and T.truth("0.0") == false
    and T.truth("Cool") == nil
)

print("[6] rounding")
check("one decimal", render("${2|.1}") == "72.5")
check("no decimals", render("${2|.0}°F") == "72°F")
check("rounding text is left alone", render("${240::HVAC_MODE|.1}") == "Cool")
check("never a negative zero", T.format("-0.04", { ".1" }) == "0.0")
check("an unknown option changes nothing", render("${2|loud}") == "72.46")

print("[7] credentials are never sent")
picks = { [1] = "300,2" }
text, problems = render("Code ${300::LAST_USER_CODE} used, ${1}")
check("the value is replaced, picked or written out", text == "Code [hidden] used, [hidden]", text)
check("and it is reported", #problems == 2 and problems[1].reason:find("never sent", 1, true))
check(
  "isHidden follows the fixed list",
  T.isHidden("Wifi Password") and T.isHidden("PIN_CODE") and not T.isHidden("STATE")
)

print("[8] one pass, one line, bounded")
picks = { [1] = "231,1000" }
check("a value holding tokens is not expanded again", render("${Variables::Echo}") == "${1} and ${Garage Door::STATE}")
check("control characters become spaces", render("${Variables::Multi Line}") == "first second third")
check("clean: bounded", #T.clean(string.rep("x", 500)) == T.LIMITS.value)
check("clean: booleans and nil", T.clean(true) == "1" and T.clean(false) == "0" and T.clean(nil) == "")
do
  local out, probs = render(string.rep("${1} ", T.LIMITS.tokens + 2))
  check("tokens beyond the limit are ?", #probs == 2 and out:sub(-4) == "? ? ", out:sub(-8))
  reads = {}
  render("${1} ${1} ${Garage Door::STATE} ${231::1001} ${240::HOLD}")
  check("each device is read once per text", #reads == 2, #reads)
end

print("[9] a notification: title, message, and picked variables not written out")
picks = { [1] = "231,1000", [2] = "240,1100" }
local title, body
title, body, problems = fill("Garage ${1|open|closed}", "Living is ${2|.0}°F")
check("both texts filled", title == "Garage open" and body == "Living is 72°F" and #problems == 0, body)
title, body = fill("Garage", "Door state:")
check(
  "picked but not written → added at the end of the message, in order",
  title == "Garage" and body == "Door state: 1 72.46",
  body
)
title, body = fill("Garage ${1|open|closed}", "Temperature")
check("only the ones not written anywhere are added", title == "Garage open" and body == "Temperature 72.46", body)
title, body = fill("Garage", "")
check("an empty message becomes the picked values", body == "1 72.46", body)
picks = { [1] = "", [2] = "" }
title, body, problems = fill("Garage", "Door left open")
check("nothing picked, nothing added", body == "Door left open" and #problems == 0)
picks = { [1] = "999,1" }
title, body, problems = fill("Garage", "Door")
check("a picked variable that cannot be read is added as ? and reported", body == "Door ?" and #problems == 1, body)
do
  reads = {}
  picks = { [1] = "231,1000", [2] = "231,1001" }
  fill("${1}", "${Garage Door::STATE} ${2}")
  check("each device is read once per notification", #reads == 1, #reads)
end

print("[10] lookup and devices")
check("by name", T.lookup(VARIABLES[240], "hvac mode").value == "Cool")
check("by id", T.lookup(VARIABLES[240], "1100").name == "TEMPERATURE_F")
check(
  "missing",
  T.lookup(VARIABLES[240], "NOPE") == nil and T.lookup(nil, "X") == nil and T.lookup(VARIABLES[240], "") == nil
)
check(
  "two variables with one name: the lower id",
  T.lookup({ ["20"] = { name = "STATE", value = "b" }, ["10"] = { name = "STATE", value = "a" } }, "STATE").value == "a"
)
check("numeric keys work as well as string keys", T.lookup({ [5] = { name = "X", value = "v" } }, "5").value == "v")
check("a device id", T.findDevice(DEVICES, "231") == 231 and T.findDevice({}, " 77 ") == 77)
check("a device name", T.findDevice(DEVICES, "garage door") == 231)
check("Room->Device", T.findDevice(DEVICES, "Living->Thermostat") == 240)
check("unknown", T.findDevice(DEVICES, "Nope") == nil and T.findDevice(DEVICES, "") == nil)
check("Variables is the project's custom variables", T.findDevice(DEVICES, "Variables") == T.PROJECT_VARIABLES_DEVICE)
check("a real device called Variables wins", T.findDevice({ [9] = { deviceName = "Variables" } }, "variables") == 9)
check("the name field works too", T.findDevice({ ["5"] = { name = "Old Style" } }, "old style") == 5)

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
