-- System Link configuration export/import: the document carries
-- configuration only, refuses secrets, re-mints ids on import and creates
-- nothing by itself.
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

package.path = "./src/?.lua;./src/?/init.lua;./vendor/?.lua;" .. package.path
local ei = require("systemlink.exportimport")

local link = { role = "a", alias = "California", namespace = "California", peer_alias = "New York", peer_namespace = "New_York" }
local items = {
  { id = "i1", owner = "ep-ca", name = "Away", type = "BOOLEAN", group = "Arrival", order = 1, schema_rev = 2, created_at = 5, filter = { debounce_s = 5 } },
  { id = "i2", owner = "ep-ca", name = "Porch_Light_On", type = "BOOLEAN", group = "Porch_Light", order = 2, companion = { id = "x", name = "Porch_Light", kind = "light", field = "On" } },
  { id = "i3", owner = "ep-ny", name = "Occupied", type = "BOOLEAN", mirror = true, order = 3 },
  { id = "i4", owner = "ep-ca", name = "Old", type = "STRING", order = 4, deleted_at = 9 },
}

print("\n[1] export")
local doc, findings = ei.buildExport({ link = link, timezone = "America/Los_Angeles", items = items, now_iso = "2026-10-21T00:00:00Z" })
check("a clean configuration exports", doc ~= nil, findings and table.concat(findings, ","))
check("deleted items are left out, live ones in order", #doc.items == 3 and doc.items[1].definition.name == "Away" and doc.items[3].definition.name == "Occupied")
check("identity and bookkeeping are stripped", doc.items[1].definition.id == nil and doc.items[1].definition.owner == nil and doc.items[1].definition.order == nil and doc.items[1].definition.schema_rev == nil and doc.items[1].definition.created_at == nil)
check("source ids travel separately", doc.items[1].source_id == "i1")
check("owner roles follow the bridge's role and mirrors get the peer's", doc.items[1].owner_role == "a" and doc.items[3].owner_role == "b")
check("the companion is required on the OTHER role", #doc.required_companions == 1 and doc.required_companions[1].on_role == "b" and doc.required_companions[1].name == "Porch_Light")
check("groups are collected and sorted", table.concat(doc.groups, ",") == "Arrival,Porch_Light")
check("both endpoints are described without secrets", #doc.endpoints == 2 and doc.endpoints[2].namespace == "New_York" and #ei.assertNoSecrets(doc) == 0)
local dirty = { link = link, items = { { id = "i9", owner = "ep-ca", name = "X", type = "STRING", device_token = "abc" } } }
local d2, f2 = ei.buildExport(dirty)
check("a secret-looking field refuses the export and is named", d2 == nil and f2[1] == "$.items.1.definition.device_token", f2 and f2[1])

print("\n[2] import")
local draft = ei.parseImport(doc)
check("a good export parses into an applicable draft", draft.ok and #draft.errors == 0 and #draft.items == 3, draft.errors[1])
check("every item is validated and marked", draft.items[1].verdict == "ok" and draft.items[2].verdict == "ok")
check("the draft spells out what the dealer must still do", #draft.requires >= 3 and draft.requires[3]:find("companions are not imported") ~= nil)
local planA = ei.planImport(draft, "a")
local planB = ei.planImport(draft, "b")
check("planning for role a creates only a's items, without companion metadata", #planA == 2 and planA[2].companion == nil and planA[1].id == nil)
check("planning for role b creates only b's items", #planB == 1 and planB[1].name == "Occupied")
check("not an export", ei.parseImport("x").ok == false and ei.parseImport({ version = 7 }).errors[1]:find("version") ~= nil)
local bad = ei.parseImport({ version = 1, items = { { owner_role = "a", definition = { name = "9bad", type = "BOOLEAN" } }, { owner_role = "zz" } } })
check("invalid definitions get a verdict, invalid owners a warning, and the draft cannot be applied", bad.ok == false and bad.items[1].verdict ~= "ok" and #bad.warnings == 1)
local leaky = ei.parseImport({ version = 1, items = {}, controller_id = "c" })
check("a file with secret-looking fields is refused", leaky.ok == false and leaky.errors[1]:find("never imported") ~= nil)

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
