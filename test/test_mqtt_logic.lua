-- MQTT pure logic: topic filters (+ and #), JSON path extraction, value
-- maps, percentage scaling, templates, availability payloads, the router
-- (entities, seen-topics cap, health) and the reconnect backoff.
--
-- Run from the driver root: make test

package.path = "src/?.lua;vendor/?.lua;" .. package.path
JSON = JSON or require("JSON")
local Topics = require("mqtt.topics")
local Payload = require("mqtt.payload")
local Router = require("mqtt.router")
local Backoff = require("mqtt.backoff")

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

print("[1] topic filters")
local M = Topics.matches
check("exact", M("a/b/c", "a/b/c"))
check("exact mismatch", not M("a/b/c", "a/b/d"))
check("longer topic does not match", not M("a/b", "a/b/c"))
check("shorter topic does not match", not M("a/b/c", "a/b"))
check("+ matches one level", M("a/+/c", "a/b/c"))
check("+ does not match two levels", not M("a/+/c", "a/b/x/c"))
check("+ matches an empty level", M("a/+/c", "a//c"))
check("trailing + needs a level", not M("a/+", "a"))
check("leading +", M("+/b", "a/b"))
check("# matches everything below", M("a/#", "a/b/c/d"))
check("# matches the parent level", M("a/#", "a"))
check("lone # matches anything", M("#", "x/y"))
check("# does not match a sibling", not M("a/#", "b/c"))
check("+/+ matches two levels only", M("+/+", "a/b") and not M("+/+", "a/b/c"))
check("$SYS not matched by a leading #", not M("#", "$SYS/broker/load"))
check("$SYS not matched by a leading +", not M("+/broker/load", "$SYS/broker/load"))
check("$SYS matched by an explicit filter", M("$SYS/#", "$SYS/broker/load"))
check("case matters", not M("A/b", "a/b"))
check(
  "real shape",
  M("zigbee2mqtt/+", "zigbee2mqtt/sink_leak") and not M("zigbee2mqtt/+", "zigbee2mqtt/sink_leak/availability")
)
check("empty inputs never match", not M("", "a") and not M("a", "") and not M(nil, "a"))
check(
  "valid filters",
  Topics.validFilter("a/+/b") and Topics.validFilter("#") and Topics.validFilter("a/#") and Topics.validFilter("+")
)
check("# in the middle refused", not Topics.validFilter("a/#/b"))
check("a# refused", not Topics.validFilter("a#"))
check("a+ refused", not Topics.validFilter("a+/b"))
check("empty filter refused", not Topics.validFilter(""))
check("valid topic name", Topics.validName("a/b/c"))
check("wildcard in a name refused", not Topics.validName("a/+") and not Topics.validName("a/#"))
check("empty name refused", not Topics.validName(""))
check("split keeps empty levels", #Topics.split("a//b/") == 4)

print("[2] JSON paths")
local doc = JSON:decode(
  '{"water_leak":true,"battery":87,"linkquality":120,"a":{"b":{"c":"deep"}},"list":[10,20,{"x":"third"}],"n":null,"o":{"1":"keyed"}}'
)
check("top level", Payload.get(doc, "battery") == 87)
check("dotted", Payload.get(doc, "a.b.c") == "deep")
check("array item by 0-based index", Payload.get(doc, "list.0") == 10 and Payload.get(doc, "list.1") == 20)
check("array item with brackets", Payload.get(doc, "list[1]") == 20)
check("object inside array", Payload.get(doc, "list[2].x") == "third")
check("numeric key in an object wins", Payload.get(doc, "o.1") == "keyed")
check("missing path", Payload.get(doc, "a.zz.c") == nil)
check("null is no value", Payload.get(doc, "n") == nil)
check("path through a scalar", Payload.get(doc, "battery.x") == nil)
check("spaces around a path tolerated", Payload.get(doc, "  a.b.c ") == "deep")
check("empty path is the whole value", Payload.get(doc, "") == doc)
check("extract field", Payload.extract('{"water_leak":true}', "water_leak") == true)
check("extract dotted", Payload.extract('{"a":{"b":"x"}}', "a.b") == "x")
check("extract from non-JSON with a field is nothing", Payload.extract("ON", "state") == nil)
check("plain text payload, empty field", Payload.extract("ON", "") == "ON")
check("plain text trimmed", Payload.extract("  OFF\n", "") == "OFF")
check("JSON scalar payload", Payload.extract("true", "") == true and Payload.extract("23.5", "") == 23.5)
check("quoted JSON string", Payload.extract('"detected"', "") == "detected")
check("object without a field is nothing", Payload.extract('{"a":1}', "") == nil)
check("field that is an object is nothing", Payload.extract('{"a":{"b":1}}', "a") == nil)
check("empty payload", Payload.extract("", "") == nil and Payload.extract("", "x") == nil)
check("broken JSON never raises", Payload.extract("{not json", "a") == nil)
check("null payload", Payload.extract("null", "") == nil)

print("[3] value maps")
local A = Payload.toActive
check("booleans", A(true) == true and A(false) == false)
check("ON/OFF any case", A("ON") == true and A("off") == false and A("On") == true)
check("detected / clear", A("detected") == true and A("clear") == false)
check("open / closed words", A("open") == true and A("CLOSED") == false)
check("numbers", A(1) == true and A(0) == false and A(5) == true)
check("numeric text", A("1") == true and A("0") == false)
check("water words", A("wet") == true and A("dry") == false)
check("unknown word is unknown", A("banana") == nil)
check("nil and table are unknown", A(nil) == nil and A({}) == nil)
check("invert", A(true, { invert = true }) == false and A("OFF", { invert = true }) == true)
check("invert leaves unknown unknown", A("banana", { invert = true }) == nil)
local custom = { active = Payload.parseValueList("Alarm, 2"), inactive = Payload.parseValueList("ok") }
check(
  "custom lists replace the built-ins",
  A("alarm", custom) == true and A(2, custom) == true and A("ok", custom) == false and A("on", custom) == nil
)
check("active-only list: everything else inactive", A("x", { active = Payload.parseValueList("pressed") }) == false)
check("parseValueList empty is nil", Payload.parseValueList("  , ") == nil)

print("[4] percentages")
check(
  "0..254 range",
  Payload.toPercent(254, 0, 254) == 100 and Payload.toPercent(0, 0, 254) == 0 and Payload.toPercent(127, 0, 254) == 50
)
check("rounds", Payload.toPercent(1, 0, 254) == 0 and Payload.toPercent(2, 0, 254) == 1)
check("clamped", Payload.toPercent(300, 0, 254) == 100 and Payload.toPercent(-5, 0, 254) == 0)
check("text number", Payload.toPercent("50", 0, 100) == 50)
check(
  "not a number",
  Payload.toPercent("x", 0, 100) == nil
    and Payload.toPercent(true, 0, 100) == nil
    and Payload.toPercent(nil, 0, 100) == nil
)
check("invert", Payload.toPercent(0, 0, 100, true) == 100 and Payload.toPercent(30, 0, 100, true) == 70)
check("degenerate range", Payload.toPercent(5, 10, 10) == nil)
check(
  "fromPercent",
  Payload.fromPercent(100, 0, 254) == 254
    and Payload.fromPercent(50, 0, 254) == 127
    and Payload.fromPercent(0, 0, 254) == 0
)
check("fromPercent invert", Payload.fromPercent(30, 0, 100, true) == 70)
check("fromPercent clamps", Payload.fromPercent(150, 0, 100) == 100 and Payload.fromPercent(-1, 0, 100) == 0)

print("[5] templates and availability")
check("render", Payload.render('{"brightness":{level}}', { level = 127 }) == '{"brightness":127}')
check("render several", Payload.render("{a}-{b}-{a}", { a = 1, b = "x" }) == "1-x-1")
check("unknown placeholders stay visible", Payload.render('{"p":{nope}}', {}) == '{"p":{nope}}')
check("braces that are JSON are left alone", Payload.render('{"state":"ON"}', { level = 5 }) == '{"state":"ON"}')
check("availability text", Payload.availability("online") == true and Payload.availability("offline") == false)
check(
  "availability JSON",
  Payload.availability('{"state":"online"}') == true and Payload.availability('{"state":"offline"}') == false
)
check("availability custom field", Payload.availability('{"s":"online"}', "s") == true)
check("availability unknown", Payload.availability("sideways") == nil and Payload.availability("") == nil)

print("[6] router: entities and routing")
local clock = { t = 1000 }
local function now()
  return clock.t
end
local R = Router.new({ now = now, seen_cap = 3 })
local e = R:setEntity(
  11,
  {
    kind = "sensor",
    name = "Sink leak",
    filters = { "zigbee2mqtt/sink_leak" },
    availability = "zigbee2mqtt/sink_leak/availability",
  }
)
check("entity registered", e ~= nil and R:entityCount() == 1)
R:setEntity(12, { kind = "light", name = "Lamp", filters = { "zigbee2mqtt/lamp" } })
R:setEntity(13, { kind = "sensor", name = "Wild", filters = { "zigbee2mqtt/+/set_ack" } })
local f = R:filters()
check(
  "filters are the sorted union",
  #f == 4 and f[1] == "zigbee2mqtt/+/set_ack" and f[3] == "zigbee2mqtt/sink_leak",
  table.concat(f, ",")
)
local hit = R:route("zigbee2mqtt/sink_leak")
check("routes to the exact entity only", #hit == 1 and hit[1].id == "11")
hit = R:route("zigbee2mqtt/sink_leak/availability")
check(
  "availability topic routes to its entity with the availability role",
  #hit == 1
    and hit[1].id == "11"
    and hit[1].role == "availability"
    and hit[1].filter == "zigbee2mqtt/sink_leak/availability"
)
check("a state topic has the state role", R:route("zigbee2mqtt/sink_leak")[1].role == "state")
do
  local T = Router.new({ now = now })
  T:setEntity(1, { filters = { "same" }, availability = "same" })
  check("one topic used for both is a state topic", T:route("same")[1].role == "state")
end
hit = R:route("zigbee2mqtt/lamp/set_ack")
check("wildcard entity", #hit == 1 and hit[1].id == "13")
check("no entity for an unknown topic", #R:route("other/topic") == 0)
R:setEntity(14, { kind = "sensor", name = "Twin", filters = { "zigbee2mqtt/lamp" } })
hit = R:route("zigbee2mqtt/lamp")
check("two entities on one topic both get it, in id order", #hit == 2 and hit[1].id == "12" and hit[2].id == "14")
local _, rejected = R:setEntity(15, { filters = { "a/#/b", "ok/topic", "" } })
check("invalid filters are rejected and reported", #rejected == 2 and #R:entity(15).filters == 1)
R:removeEntity(15)
R:removeEntity(14)
check("removal", R:entity(15) == nil and R:entityCount() == 3)
R:setEntity(12, { filters = { "zigbee2mqtt/lamp2" } })
check(
  "re-registering replaces the filters and keeps the name",
  R:entity(12).name == "Lamp" and #R:route("zigbee2mqtt/lamp") == 0 and #R:route("zigbee2mqtt/lamp2") == 1
)
do
  local many = Router.new({ now = now })
  local last
  for i = 1, 128 do
    last = many:setEntity(i, { filters = { "t/" .. i } })
  end
  local over, why = many:setEntity(129, { filters = { "t/129" } })
  check("entity cap", over == nil and why[1].why:find("128"))
  check("an existing entity can still be updated at the cap", many:setEntity(5, { filters = { "t/new" } }) ~= nil)
end

print("[7] router: seen topics (capped, no payloads)")
R:clearSeen()
clock.t = 2000
R:noteTopic("a")
clock.t = 2001
R:noteTopic("b")
clock.t = 2002
R:noteTopic("c")
clock.t = 2003
R:noteTopic("a")
local seen = R:seenList()
check("most recent first", seen[1].topic == "a" and seen[2].topic == "c" and seen[3].topic == "b")
check("counts", seen[1].count == 2 and seen[2].count == 1)
clock.t = 2004
R:noteTopic("d")
seen = R:seenList()
check("cap evicts the least recently seen", #seen == 3 and R.dropped == 1 and not (function()
  for _, s in ipairs(seen) do
    if s.topic == "b" then
      return true
    end
  end
end)())
check("limit", #R:seenList(2) == 2)
check("seen entries carry no payload field", seen[1].payload == nil)
R:clearSeen()
check("clear", #R:seenList() == 0 and R.dropped == 0)

print("[8] router: health")
clock.t = 5000
local H = Router.new({ now = now })
H:setEntity(1, { kind = "sensor", name = "Door", filters = { "d" } })
H:setEntity(2, { kind = "light", name = "Lamp", filters = { "l" } })
H:setEntity(3, { kind = "sensor", name = "Leak", filters = { "w" }, availability = "w/availability" })
clock.t = 5010
H:route("d")
H:route("l")
clock.t = 5100
H:route("l")
H:route("w")
H:route("w/availability")
H:setAvailable(3, false)
clock.t = 5200
local h = H:health(120)
check("health counts", h.count == 3 and h.stale == 2, h.stale)
local byId = {}
for _, entry in ipairs(h.entries) do
  byId[entry.id] = entry
end
check("an availability message does not refresh last_seen", H:entity(3).last_seen == 5100)
check("door: 190 s old and stale after 120", byId["1"].age == 190 and byId["1"].state == "stale")
check("lamp: 100 s old and fine", byId["2"].age == 100 and byId["2"].state == "ok")
check("leak: reported offline by its availability topic", byId["3"].state == "offline")
H:setEntity(4, { kind = "sensor", name = "New", filters = { "n" } })
check(
  "never heard = silent, not stale",
  H:health(120).entries[4].state == "silent" and H:health(120).entries[4].age == nil
)
check("stale threshold 0 disables staleness", H:health(0).entries[1].state == "ok")

print("[9] backoff")
local rnd = 0
local B = Backoff.new({
  base = 2,
  max = 60,
  jitter = 0,
  rand = function()
    return rnd
  end,
})
local seq = {}
for i = 1, 8 do
  seq[i] = B:next()
end
check("doubles and caps", table.concat(seq, ",") == "2,4,8,16,32,60,60,60", table.concat(seq, ","))
B:reset()
check("reset starts over", B:next() == 2)
check(
  "permanent failures go straight to the ceiling",
  Backoff.new({ base = 2, max = 120, jitter = 0 }):next(true) == 120
)
local J = Backoff.new({
  base = 10,
  max = 100,
  jitter = 0.2,
  rand = function()
    return 1
  end,
})
check("jitter adds up to 20 percent", J:next() == 12)
J = Backoff.new({
  base = 10,
  max = 100,
  jitter = 0.2,
  rand = function()
    return 0
  end,
})
check("jitter low end", J:next() == 10)

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
