-- A page the relay cannot read answers 503 AND says why, in all three page relays.
local pass, fail = 0, 0
local function check(name, ok, detail)
  if ok then
    pass = pass + 1
    print("  ok   " .. name)
  else
    fail = fail + 1
    print("  FAIL " .. name .. (detail and ("  -> " .. tostring(detail)) or ""))
  end
end
for _, mod in ipairs({ "commissioning.relay", "daypart.relay", "pinlock.relay" }) do
  local r = require(mod)
  local res = r.route({ method = "GET", path = "/app", query = {} }, "tok", {
    appHtml = function()
      return nil
    end,
    appWhy = function()
      return 'tried "C4Z_ROOT + www/app/index.html" -> not found'
    end,
  })
  check(mod .. ": 503", res.status:find("503", 1, true) ~= nil)
  check(mod .. ": reason included, quotes made safe", res.body:find('"why":"tried  C4Z_ROOT', 1, true) ~= nil, res.body)
  local res2 = r.route({ method = "GET", path = "/app", query = {} }, "tok", {
    appHtml = function()
      error("boom")
    end,
  })
  check(mod .. ": a thrown error is reported", res2.body:find("boom", 1, true) ~= nil)
  local res3 = r.route({ method = "GET", path = "/app", query = {} }, "tok", {
    appHtml = function()
      return "<html>" .. string.rep("x", 600)
    end,
  })
  check(mod .. ": a readable page is served", res3.status == "200 OK")
end
print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
