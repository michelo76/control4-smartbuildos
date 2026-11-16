-- PIN Lock keypad/admin page: static guards (self-contained, touch friendly,
-- never echoes or logs a PIN) and the pure helpers, run with node when present.
local pass, fail = 0, 0
local function check(name, ok, detail)
  if ok then pass = pass + 1; print("  ok   " .. name)
  else fail = fail + 1; print("  FAIL " .. name .. (detail and ("  -> " .. tostring(detail)) or "")) end
end
local PAGE = "drivers/smartbuildos-pin-lock/www/app/index.html"
local f = io.open(PAGE, "r") or io.open("../" .. PAGE, "r")
check("the page exists", f ~= nil)
if not f then os.exit(1) end
local html = f:read("*a"); f:close()

check("no external URL in the page (CSP meta carries no scheme separator)", not html:find("https?://"))
check("no script src or stylesheet link", not html:find("<script[^>]-src=") and not html:find("<link[^>]-rel=\"stylesheet\""))
check("literal min-height: 48px on buttons", html:find("min%-height: 48px", 1) ~= nil)
check("big keypad keys (68px)", html:find("min%-height: 68px", 1) ~= nil)
check("light and dark scheme", html:find("prefers%-color%-scheme: dark", 1) ~= nil)
check("reduced motion respected", html:find("prefers%-reduced%-motion", 1) ~= nil)
for _, id in ipairs({ "tabKeypad", "tabAdmin", "mode", "viewKeypad", "viewAdmin", "actions", "admin",
  "padModal", "padTitle", "padDots", "pad", "padCancel", "padGo", "toast" }) do
  check("id " .. id .. " kept", html:find('id="' .. id .. '"', 1, true) ~= nil)
end
check("no console logging", not html:find("console%."))
check("no PIN in a URL", not html:find("pin=", 1, true) and not html:find("?pin", 1, true))
check("PIN sent in a POST body", html:find("{ action: padAction.n, pin: typed }", 1, true) ~= nil)
check("pad display holds no digits", not html:find("textContent = pin", 1, true) and not html:find("innerHTML = pin", 1, true))

print("[2] pure helpers (node)")
local has_node = os.execute("node --version >/dev/null 2>&1")
if has_node == true or has_node == 0 then
  local js = html:match('<script id="pinlock%-pure">(.-)</script>')
  check("pure helper block present", js ~= nil)
  local tmp = os.tmpname()
  local out = io.open(tmp, "w")
  out:write(js, [[
var assert = require('assert');
assert.strictEqual(PL.clock(75), '1:15'); assert.strictEqual(PL.clock(-3), '0:00');
assert.strictEqual(PL.lockText(30), 'Locked for 30 s'); assert.strictEqual(PL.lockText(61), 'Locked for 2 min');
assert.strictEqual(PL.dotCount(0), 4); assert.strictEqual(PL.dotCount(6), 6); assert.strictEqual(PL.dotCount(20), 8);
assert.strictEqual(PL.stateLabel('not_started'), 'Not started'); assert.strictEqual(PL.stateKind('active'), 'ok');
assert.strictEqual(PL.scheduleText({ days: [], from: '', to: '' }), 'Every day · all day');
assert.strictEqual(PL.scheduleText({ days: [2, 3, 4], from: '08:00', to: '17:00' }), 'Mon, Tue, Wed · 08:00–17:00');
assert.strictEqual(PL.expiryText(0, 0), ''); assert.ok(/^Expired /.test(PL.expiryText(1000, Date.now())));
assert.strictEqual(PL.roleClass('hacker'), 'guest'); assert.strictEqual(PL.roleClass('vendor'), 'vendor');
]])
  out:close()
  local ok = os.execute("node " .. tmp)
  os.remove(tmp)
  check("pure helpers pass under node", ok == true or ok == 0)
else
  print("  SKIP node not available; helper cases not run")
end
print(string.format("%d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
