-- AI Core touchscreen page: static guards (self-contained, strict CSP, the
-- PIN goes only to PIN Lock's verify_url, never stored, text only through
-- textContent) and the pure helpers run under node when present, with a
-- fake DOM that FAILS on any innerHTML write.
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
local PAGE = "drivers/smartbuildos-ai-core/www/app/index.html"
local f = io.open(PAGE, "r") or io.open("../" .. PAGE, "r")
check("the page exists", f ~= nil)
if not f then
  os.exit(1)
end
local html = f:read("*a")
f:close()

print("[1] static guards")
check("no external URL in the page", not html:find("https?://"))
check(
  "no script src, stylesheet link, image, frame or font from anywhere",
  not html:find("<script[^>]-src=")
    and not html:find("<link")
    and not html:find("<img")
    and not html:find("<iframe")
    and not html:find("@import")
    and not (html:match("<style>(.-)</style>") or ""):find("url%(")
)
local csp = html:match('http%-equiv="Content%-Security%-Policy" content="([^"]*)"')
check("a CSP: default-src 'none'", csp ~= nil and csp:find("default-src 'none'", 1, true) ~= nil, csp)
check(
  "…connect-src 'self' only (the driver adds PIN Lock's origin on this host when it serves /app)",
  csp ~= nil and csp:find("connect-src 'self';", 1, true) ~= nil,
  csp
)
check(
  "…no frames, no forms, no base",
  csp:find("base-uri 'none'", 1, true) ~= nil and csp:find("form-action 'none'", 1, true) ~= nil
)
check(
  "no innerHTML, outerHTML, insertAdjacentHTML, document.write or eval anywhere",
  not html:find("innerHTML")
    and not html:find("outerHTML")
    and not html:find("insertAdjacentHTML")
    and not html:find("document%.write")
    and not html:find("eval%(")
)
check(
  "no storage of anything (localStorage, sessionStorage, indexedDB, cookies)",
  not html:find("localStorage")
    and not html:find("sessionStorage")
    and not html:find("indexedDB")
    and not html:find("document%.cookie")
)
check("no console logging", not html:find("console%."))
check("the PIN is serialised in one place only (AIC.verifyBody)", select(2, html:gsub("pin: String%(pin%)", "")) == 1)
check(
  "…which is used once, and posted only to the prompt's verify_url",
  select(2, html:gsub("AIC%.verifyBody%(", "")) == 1 and html:find("fetch%(p%.verify_url,") ~= nil
)
check(
  "…after the page checked verify_url is PIN Lock on this host",
  html:find("AIC.validVerifyUrl(p.verify_url, location.hostname)", 1, true) ~= nil
)
check("no PIN in a URL", not html:find("pin=", 1, true) and not html:find("?pin", 1, true))
check(
  "the PIN is cleared before the request leaves",
  html:find("var body = AIC.verifyBody(p.challenge_id, pin);\n    var cid = p.challenge_id;\n    pin = '';", 1, true)
    ~= nil
)
check(
  "the pad shows dots, never digits",
  html:find("textContent = AIC.dots(pin)", 1, true) ~= nil and not html:find("textContent = pin", 1, true)
)
check("home network only, said on the page", html:find("Works only on the home network.", 1, true) ~= nil)
check(
  "touch-size targets (48 px; 68 px keypad keys)",
  html:find("min%-height: 48px") ~= nil and html:find("min%-height: 68px") ~= nil
)
check("light and dark", html:find("prefers%-color%-scheme: dark") ~= nil)
check("reduced motion respected", html:find("prefers%-reduced%-motion") ~= nil)
check(
  "keyboard: visible focus, keypad digits / Enter / Escape",
  html:find(":focus%-visible") ~= nil
    and html:find("e.key === 'Enter'", 1, true) ~= nil
    and html:find("e.key === 'Escape'", 1, true) ~= nil
)
check(
  "Lock on hide, close on pagehide",
  html:find("visibilitychange", 1, true) ~= nil
    and html:find("/chat/lock", 1, true) ~= nil
    and html:find("pagehide", 1, true) ~= nil
    and html:find("/session/close", 1, true) ~= nil
)
check(
  "suggestion buttons wrap a long (120-character) preset label inside the page",
  html:find("#suggestions button {[^}]*white%-space: normal") ~= nil
    and html:find("#suggestions button {[^}]*max%-width: 100%%") ~= nil
    and html:find("#suggestions button {[^}]*overflow%-wrap: anywhere") ~= nil
)
for _, id in ipairs({
  "status",
  "chatLocked",
  "chatOpen",
  "unlock",
  "lock",
  "question",
  "ask",
  "explain",
  "suggestions",
  "conversation",
  "review",
  "item",
  "approve",
  "decline",
  "pad",
  "padGo",
  "padCancel",
  "notice",
}) do
  check("id " .. id .. " present", html:find('id="' .. id .. '"', 1, true) ~= nil)
end

print("[2] pure helpers (node)")
local has_node = os.execute("node --version >/dev/null 2>&1")
if has_node == true or has_node == 0 then
  local js = html:match('<script id="aicore%-pure">(.-)</script>')
  check("pure helper block present", js ~= nil)
  local tmp = os.tmpname() .. ".js"
  local out = io.open(tmp, "w")
  out:write(
    js,
    [[
var assert = require('assert');
// A fake DOM: textContent is recorded; ANY innerHTML write throws.
var htmlWrites = 0;
function El(tag) { this.tag = tag; this.children = []; this.attrs = {}; this._text = ''; this.className = ''; }
Object.defineProperty(El.prototype, 'innerHTML', { set: function () { htmlWrites++; throw new Error('innerHTML used'); }, get: function () { return ''; } });
Object.defineProperty(El.prototype, 'textContent', { set: function (v) { this._text = String(v); this.children = []; }, get: function () { return this._text + this.children.map(function (c) { return c.textContent; }).join(''); } });
Object.defineProperty(El.prototype, 'firstChild', { get: function () { return this.children[0] || null; } });
El.prototype.appendChild = function (c) { this.children.push(c); return c; };
El.prototype.removeChild = function (c) { this.children.splice(this.children.indexOf(c), 1); return c; };
El.prototype.setAttribute = function (k, v) { this.attrs[k] = v; };
El.prototype.addEventListener = function (ev, fn) { this.on = fn; };
var doc = { createElement: function (t) { return new El(t); } };

var evil = '<img src=x onerror="alert(1)"><b>bold</b>';
var root = new El('div');
AIC.renderConversation(doc, root, [
  { q: evil, a: evil + ' answer', state: 'answered' },
  { q: 'Pending?', state: 'pending' },
  { q: 'Refused?', state: 'refused', message: 'Too many requests.' }
]);
assert.strictEqual(htmlWrites, 0, 'no innerHTML');
assert.strictEqual(root.children.length, 3);
assert.strictEqual(root.children[2].children[0].textContent, evil, 'the question is text, verbatim');
assert.strictEqual(root.children[2].children[1].textContent, evil + ' answer', 'the answer is text, verbatim');
assert.strictEqual(root.children[1].children[1].textContent, 'Waiting for the answer…');
assert.strictEqual(root.children[0].children[1].textContent, 'Too many requests.');
AIC.renderConversation(doc, root, []);
assert.strictEqual(root.children.length, 0, 'cleared without innerHTML');
var ul = new El('ul');
AIC.renderLines(doc, ul, ['Online', evil, '', null]);
assert.strictEqual(ul.children.length, 2);
assert.strictEqual(ul.children[1].textContent, evil);
var sug = new El('div'); var picked = null;
AIC.renderSuggestions(doc, sug, [{ id: 'today', label: evil }], function (id) { picked = id; });
assert.strictEqual(sug.children[0].textContent, evil); sug.children[0].on(); assert.strictEqual(picked, 'today');
// The dealer's presets arrive as suggestions (round two): text verbatim, the
// id passed back untouched, a 120-character label whole.
var longLabel = new Array(13).join('Is it warm?') + '<script>x</script>';
AIC.renderSuggestions(doc, sug, [{ id: 'p1-1800000001', label: longLabel }, { id: 'p2-1800000001', label: evil }, { id: 'working', label: 'Is everything in the house working?' }], function (id) { picked = id; });
assert.strictEqual(sug.children.length, 3);
assert.strictEqual(sug.children[0].textContent, longLabel, 'a long preset label is text, whole');
assert.strictEqual(sug.children[1].textContent, evil, 'a preset label is never markup');
sug.children[1].on(); assert.strictEqual(picked, 'p2-1800000001');
assert.strictEqual(htmlWrites, 0);
assert.deepStrictEqual(AIC.statusLines({ status: { text: { online: 'Online', licensed: 'Licensed', provider: 'P', learning: 'L' } }, pin: { message: 'M' } }), ['Online', 'Licensed', 'P', 'L', 'M']);

// verify_url: PIN Lock's port on THIS host only
assert.ok(AIC.validVerifyUrl('http://192.168.1.20:47831/verify', '192.168.1.20'));
assert.ok(!AIC.validVerifyUrl('http://192.168.1.21:47831/verify', '192.168.1.20'));
assert.ok(!AIC.validVerifyUrl('http://192.168.1.20:47871/verify', '192.168.1.20'));
assert.ok(!AIC.validVerifyUrl('https://192.168.1.20:47831/verify', '192.168.1.20'));
assert.ok(!AIC.validVerifyUrl('http://192.168.1.20:47831/verify?x=1', '192.168.1.20'));
assert.ok(!AIC.validVerifyUrl('http://evil.example@192.168.1.20:47831/verify', '192.168.1.20'));
assert.ok(!AIC.validVerifyUrl(undefined, '192.168.1.20'));
// the PIN body: exactly two keys
assert.deepStrictEqual(JSON.parse(AIC.verifyBody('ab', '1234')), { challenge_id: 'ab', pin: '1234' });
// the pad
var p = ''; '123456789'.split('').forEach(function (d) { p = AIC.padAdd(p, d); });
assert.strictEqual(p, '12345678', 'at most 8 digits');
assert.strictEqual(AIC.padAdd('12', 'x'), '12'); assert.strictEqual(AIC.padBack('123'), '12');
assert.strictEqual(AIC.dots('1234'), '••••'); assert.ok(!/[0-9]/.test(AIC.dots('1234')));
// texts and timing
assert.strictEqual(AIC.lockText(30), 'PIN entry is locked for 30 s'); assert.strictEqual(AIC.lockText(299), 'PIN entry is locked for 5 min');
assert.strictEqual(AIC.leftText(300), 'Locks again after 5 min without use'); assert.strictEqual(AIC.leftText(20), 'Locks again in 20 s');
assert.strictEqual(AIC.riskText('medium'), 'Risk: medium'); assert.strictEqual(AIC.riskText('high'), '');
assert.strictEqual(AIC.pollDelay({ ok: true, chat: {} }), 30000);
assert.strictEqual(AIC.pollDelay({ ok: true, prompt: {} }), 3000);
assert.strictEqual(AIC.pollDelay({ ok: true, chat: { conversation: [{ state: 'pending' }] } }), 3000);
assert.strictEqual(AIC.pollDelay(null), 10000);
assert.deepStrictEqual(AIC.parseQuery('?k=abc&s=1%202'), { k: 'abc', s: '1 2' });
]]
  )
  out:close()
  local ok = os.execute("node " .. tmp)
  os.remove(tmp)
  check("pure helpers pass under node (fake DOM refuses innerHTML)", ok == true or ok == 0)
else
  print("  SKIP node not available; helper cases not run")
end
print(string.format("%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
