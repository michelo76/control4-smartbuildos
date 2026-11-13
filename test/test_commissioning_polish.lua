-- Bench findings of 13 Nov 2026: empty readbacks must not appear as `[]`.
local Engine = require("commissioning.engine")
local pass, fail = 0, 0
local function check(name, ok)
  if ok then pass = pass + 1; print("  ok   " .. name) else fail = fail + 1; print("  FAIL " .. name) end
end
check("an all-empty readback is dropped", Engine.compactReadback({ act = {}, restore = {} }) == nil)
check("nil stays nil", Engine.compactReadback(nil) == nil)
local rb = Engine.compactReadback({ act = { level = 100 }, restore = {} })
check("only the filled half is kept", rb ~= nil and rb.act.level == 100 and rb.restore == nil)
print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
