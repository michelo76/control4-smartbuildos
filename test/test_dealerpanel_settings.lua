package.path = "src/?.lua;" .. package.path
local S = require("dealerpanel.settings")
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

print("== parseOptions")
local r = S.parseOptions("Number", "")
check("Number empty → 0..100", r.min == 0 and r.max == 100)
check("Number a..b", S.parseOptions("Number", "10..90").min == 10 and S.parseOptions("Number", "10..90").max == 90)
check("Number a-b", S.parseOptions("Number", "5 - 15").max == 15)
check("Number a,b with decimals and negatives", S.parseOptions("Number", "-2.5, 2.5").min == -2.5)
check("Number reversed range is swapped", S.parseOptions("Number", "100..0").min == 0)
local bad, why = S.parseOptions("Number", "lots")
check("Number garbage refused", bad == nil and why:find("range") ~= nil)
local c = S.parseOptions("Choice", " Low, Medium ;High|High ")
check("Choice list parsed, trimmed, deduped", #c.choices == 3 and c.choices[2] == "Medium")
local badC = S.parseOptions("Choice", "")
check("Choice empty refused", badC == nil)
check(
  "Toggle/Text ignore options",
  next(S.parseOptions("Toggle", "x")) == nil and next(S.parseOptions("Text", "x")) == nil
)

print("== define")
local d = S.define(1, "  Hall timeout ", "Number", "0..600")
check("named, typed, ranged", d.enabled and d.type == "Number" and d.options.max == 600 and d.name == "Hall timeout")
check("empty name → unused", S.define(2, "", "Number", "").enabled == false)
check("bad type → refusal", S.define(3, "X", "Colour", "").refusal ~= nil)
check("bad options → refusal", S.define(4, "X", "Choice", "").refusal ~= nil)
check("name truncated to 40", #S.define(5, string.rep("a", 60), "Text", "").name == 40)

print("== coerce")
local num = S.define(1, "Level", "Number", "0..100")
check("number in range", S.coerce(num, " 50 ") == 50)
check("number out of range refused", select(2, S.coerce(num, "150")):find("outside") ~= nil)
check("not a number refused", select(2, S.coerce(num, "abc")) == "not a number")
local tog = S.define(2, "Night", "Toggle", "")
check("toggle on forms", S.coerce(tog, "On") == true and S.coerce(tog, "yes") == true and S.coerce(tog, "1") == true)
check("toggle off forms incl. empty", S.coerce(tog, "Off") == false and S.coerce(tog, "") == false)
check("toggle garbage refused", S.coerce(tog, "maybe") == nil)
local txt = S.define(3, "Note", "Text", "")
check("text trimmed", S.coerce(txt, "  hi  ") == "hi")
check("text too long refused", S.coerce(txt, string.rep("x", 201)) == nil)
local ch = S.define(4, "Mode", "Choice", "Low,Medium,High")
check("choice canonical case", S.coerce(ch, "medium") == "Medium")
check("choice unknown refused", select(2, S.coerce(ch, "Max")):find("not one of") ~= nil)

print("== defaults / text / numeric")
check("number default 0 within range", S.default(num) == 0)
check("number default min when 0 outside range", S.default(S.define(1, "L", "Number", "10..20")) == 10)
check("toggle default Off", S.default(tog) == false)
check("choice default first", S.default(ch) == "Low")
check("text forms", S.text(tog, true) == "On" and S.text(num, 50) == "50" and S.text(num, 2.5) == "2.5")
check(
  "numeric forms",
  S.numeric(num, 7) == 7 and S.numeric(tog, true) == 1 and S.numeric(txt, "12") == 12 and S.numeric(ch, "Low") == 0
)

print("== build from properties")
local props = {
  ["Setting 1 Name"] = "Hall timeout",
  ["Setting 1 Type"] = "Number",
  ["Setting 1 Value"] = "120",
  ["Setting 1 Options"] = "0..600",
  ["Setting 2 Name"] = "Night mode",
  ["Setting 2 Type"] = "Toggle",
  ["Setting 2 Value"] = "On",
  ["Setting 3 Name"] = "Scene",
  ["Setting 3 Type"] = "Choice",
  ["Setting 3 Value"] = "bright",
  ["Setting 3 Options"] = "Dim, Bright",
  ["Setting 4 Name"] = "Broken",
  ["Setting 4 Type"] = "Number",
  ["Setting 4 Value"] = "900",
  ["Setting 4 Options"] = "0..100",
  ["Setting 5 Name"] = "No options",
  ["Setting 5 Type"] = "Choice",
  ["Setting 5 Options"] = "",
  ["Setting 6 Name"] = "Fresh",
  ["Setting 6 Type"] = "Number",
  ["Setting 6 Value"] = "",
  ["Setting 6 Options"] = "",
}
local m = S.build(props)
check("12 slots always present", #m.slots == 12)
check("configured counts usable slots only", m.configured == 5, m.configured)
check("number value", m.slots[1].value == 120)
check("toggle value", m.slots[2].value == true)
check("choice canonicalised", m.slots[3].value == "Bright")
check(
  "out-of-range value → default in force with refusal",
  m.slots[4].value == 0 and m.slots[4].refusal:find("outside") ~= nil
)
check("unusable slot has no value", m.slots[5].value == nil and m.slots[5].def.refusal ~= nil)
check("empty value → default", m.slots[6].value == 0)
check("refusals listed with slot and name", #m.refusals == 2 and m.refusals[1].slot == 4)
check("empty properties table → nothing configured", S.build(nil).configured == 0)

print("== find / propose / same / equalsText")
check("find by name case-insensitive", S.find(m, " hall TIMEOUT ").def.slot == 1)
check("find by slot number", S.find(m, "2").def.slot == 2 and S.find(m, 3).def.slot == 3)
check("find unusable slot → nil", S.find(m, 5) == nil and S.find(m, "nope") == nil and S.find(m, "") == nil)
local e, v, why2, changed = S.propose(m, "Hall timeout", "200")
check("propose accepts and flags change", e ~= nil and v == 200 and why2 == nil and changed == true)
e, v, why2, changed = S.propose(m, "Hall timeout", "120.0")
check("propose same number → no change", changed == false)
local eN, vN, whyN = S.propose(m, "Hall timeout", "999")
check("propose out of range refused", eN == nil and whyN:find("outside") ~= nil)
local eU, vU, whyU = S.propose(m, "Unknown", "1")
check("propose unknown name refused", eU == nil and whyU:find("no setting") ~= nil)
check("same: choice case-insensitive", S.same(m.slots[3].def, "Bright", "bright") == true)
check(
  "equalsText number numerically",
  S.equalsText(m.slots[1], "120.0") == true and S.equalsText(m.slots[1], "121") == false
)
check("equalsText toggle", S.equalsText(m.slots[2], "on") == true and S.equalsText(m.slots[2], "off") == false)
check("equalsText choice", S.equalsText(m.slots[3], "BRIGHT") == true)
check("equalsText unusable → false", S.equalsText(m.slots[5], "x") == false)

print("== snapshot")
local snap = S.snapshot(m, { writable = false })
check(
  "snapshot lists named slots incl. refused ones",
  #snap.settings == 6 and snap.configured == 5 and snap.writable == false
)
check("snapshot carries range and choices", snap.settings[1].max == 600 and snap.settings[3].choices[2] == "Bright")
check("snapshot carries the refusal text", snap.settings[4].refusal ~= nil and snap.settings[5].refusal ~= nil)

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
