-- Cross-language parity: the driver's schema rules against the fixture the
-- platform pins in smartbuildos/tests/fixtures/system-link/schema-parity.json.
-- A copy lives in this repo at test/fixtures/systemlink/schema-parity.json;
-- the two files must be byte-identical (both repos' suites load their own).
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
local JSON = require("JSON")
local schema = require("systemlink.schema")

local f = assert(io.open("test/fixtures/systemlink/schema-parity.json", "r"))
local fixture = JSON:decode(f:read("*a"))
f:close()

print("\n[1] definitions")
for _, c in ipairs(fixture.definitions) do
  local ok, err = schema.validateDefinition(c.def)
  check(c.id .. " " .. tostring(c.ok), ok == c.ok, err)
end

print("\n[2] values")
for _, c in ipairs(fixture.values) do
  local v, err = schema.coerce(c.def, c.raw)
  local ok = v ~= nil
  check(c.id .. " " .. tostring(c.ok), ok == c.ok, err)
  if c.ok and ok then
    check(c.id .. " value", v == c.value, tostring(v) .. " ~= " .. tostring(c.value))
  end
end

print("\n[3] namespaces")
for _, c in ipairs(fixture.namespaces) do
  local got = schema.namespace(c.alias)
  local want = c.expected
  if want == JSON.null or want == nil then
    want = nil
  end
  check(c.alias, got == want, tostring(got))
end

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
