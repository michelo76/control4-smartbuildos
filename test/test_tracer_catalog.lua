package.path = "src/?.lua;" .. package.path
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

print("== parseDriverXml")
local xml = [==[
<devicedata>
  <name>Thing</name>
  <events>
    <event><id>1</id><name>Top Button Pushed</name><description>x</description></event>
    <event><id>2</id><name><![CDATA[Door &amp; Window Opened]]></name></event>
    <event><id>7</id><name>  Spaced   out  </name></event>
    <event><id>9</id></event>
  </events>
  <proxies><proxy><events><event><id>99</id><name>Proxy Only</name></event></events></proxy></proxies>
</devicedata>]==]
local ev = Catalog.parseDriverXml(xml)
check("three named events parsed", count(ev) == 3, count(ev))
check("plain name", ev[1] == "Top Button Pushed", ev[1])
check("CDATA and entity unescaped", ev[2] == "Door & Window Opened", ev[2])
check("whitespace collapsed", ev[7] == "Spaced out", ev[7])
check("event without a name skipped", ev[9] == nil)
check("proxy sub-document events not taken as the device's", ev[99] == nil)
check("no events block → empty", count(Catalog.parseDriverXml("<devicedata/>")) == 0)
check("non-string → empty", count(Catalog.parseDriverXml(nil)) == 0)

print("== parseProjectItems")
local project = [[
<item majorversion="4"><id>1</id><name>Project</name><type>1</type><itemdata><scale>F</scale></itemdata><subitems>
  <item><id>16</id><name>Kitchen</name><type>8</type><itemdata><config_data_file>roomdevice.c4i</config_data_file></itemdata><subitems>
    <item><id>101</id><name>Pendants</name><type>7</type><itemdata><driver>light_v2.c4i</driver><events><event><id>1</id><name>Top Button Pushed</name></event><event><id>2</id><name>Bottom Button Pushed</name></event></events></itemdata></item>
    <item><id>102</id><name>Limited</name><type>7</type><itemdata><driver>x.c4i</driver><state/></itemdata></item>
  </subitems></item>
</subitems></item>]]
local byDevice, n = Catalog.parseProjectItems(project)
check("one device carried events", n == 1, n)
check("device 101 → 2 events", byDevice[101] ~= nil and count(byDevice[101]) == 2)
check("device 101 names", byDevice[101] and byDevice[101][2] == "Bottom Button Pushed")
check("device without events absent", byDevice[102] == nil)
check("room item absent", byDevice[16] == nil)
local _, n0 = Catalog.parseProjectItems("<item><id>1</id><itemdata><driver>a</driver></itemdata></item>")
check("LIMIT_DEVICE_DATA shape → 0 (the probe failing quietly)", n0 == 0)
local selfClosing = Catalog.parseProjectItems(
  "<item><id>1</id><itemdata/><subitems><item><id>30</id><itemdata><events><event><id>3</id><name>Boom</name></event></events></itemdata></item></subitems></item>"
)
check("a self-closing root itemdata does not steal the id", selfClosing[30] ~= nil and selfClosing[1] == nil)
local _, nnil = Catalog.parseProjectItems(nil)
check("nil → 0", nnil == 0)

print("== tiers")
local builtin = {
  ["bond-keypad.c4z"] = { [1] = "Button 1", [2] = "Button 2" },
  ["lock.c4z"] = { [5] = "Locked", [6] = "Unlocked" },
}
local cat = Catalog.new({ builtin = builtin, learned = { ["lock.c4z"] = { 6, 40 }, ["mystery.c4z"] = { 3 } } })
local events, tier = cat:eventsFor(10, "bond-keypad.c4z")
check("builtin tier", tier == "builtin" and count(events) == 2)
check("builtin names known", events[1].name == "Button 1" and events[1].known == true)
events, tier = cat:eventsFor(11, "lock.c4z")
check("learned ids merged into builtin", tier == "builtin" and count(events) == 3, count(events))
check("learned id that builtin already names keeps the name", events[6].name == "Unlocked" and events[6].known)
check("learned-only id is unnamed", events[40].name == "Event 40" and events[40].known == false)
events, tier = cat:eventsFor(12, "mystery.c4z")
check("learned-only driver → learned tier", tier == "learned" and count(events) == 1)
events, tier = cat:eventsFor(13, "unknown.c4z")
check("unknown driver → nothing", tier == nil and count(events) == 0)
events, tier = cat:eventsFor(14, nil)
check("nil driver → nothing", tier == nil and count(events) == 0)

print("== project tier wins")
cat:loadProjectXml(project)
events, tier = cat:eventsFor(101, "bond-keypad.c4z")
check("project tier chosen for a device the XML described", tier == "project" and events[1].name == "Top Button Pushed")
events, tier = cat:eventsFor(10, "bond-keypad.c4z")
check("other devices still use builtin", tier == "builtin")
check(
  "counts",
  cat:counts().project_devices == 1 and cat:counts().builtin_drivers == 2 and cat:counts().learned_events == 3
)
cat:loadProjectXml(nil)
events, tier = cat:eventsFor(101, "bond-keypad.c4z")
check("clearing the project tier falls back", tier == "builtin")

print("== learn")
check("learning a new id → true", cat:learn("unknown.c4z", 4) == true)
check("learning it again → false", cat:learn("unknown.c4z", 4) == false)
check("learning with no driver → false", cat:learn(nil, 4) == false and cat:learn("", 4) == false)
check("learning a non-number → false", cat:learn("unknown.c4z", "x") == false)
events, tier = cat:eventsFor(13, "unknown.c4z")
check("learned id now listed unnamed", tier == "learned" and events[4] and events[4].known == false)
local name, known = cat:name(13, "unknown.c4z", 4)
check("name() for learned", name == "Event 4" and known == false)
name, known = cat:name(10, "bond-keypad.c4z", 2)
check("name() for builtin", name == "Button 2" and known == true)
name, known = cat:name(10, "bond-keypad.c4z", 77)
check("name() for an id nobody knows", name == "Event 77" and known == false)
local doc = cat:learnedDoc()
check("learnedDoc sorted arrays", doc["lock.c4z"][1] == 6 and doc["lock.c4z"][2] == 40 and doc["unknown.c4z"][1] == 4)
local again = Catalog.new({ builtin = builtin, learned = doc })
check("learnedDoc round-trips", again:counts().learned_events == 4)

print("== generated catalogue")
local okData, data = pcall(require, "tracer.catalog_data")
check("catalog_data loads", okData and type(data) == "table")
if okData then
  local drivers, total = 0, 0
  for _, evs in pairs(data) do
    drivers = drivers + 1
    for id, nm in pairs(evs) do
      total = total + 1
      if type(id) ~= "number" or type(nm) ~= "string" or nm == "" then
        total = -1e9
      end
    end
  end
  check("catalog_data: every entry is id→name", total > 0, total)
  check("catalog_data: a healthy number of drivers", drivers >= 100, drivers)
  check("catalog_data: the Agent's own events are catalogued", data["smartbuildos.c4z"] ~= nil)
end

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
