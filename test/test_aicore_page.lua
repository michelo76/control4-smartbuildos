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
-- Pressing "Unlock with owner PIN" must always visibly do something.
check(
  "the unlock button starts hidden: shown only once the controller says the chat can be unlocked",
  html:find('<div id="chatLocked" class="hidden">', 1, true) ~= nil
)
check(
  "…and a page that cannot connect says why and hides it (the built-in copy, an old address, no answer)",
  html:find("offline('copy')", 1, true) ~= nil
    and html:find("refused('address')", 1, true) ~= nil
    and html:find("show('chatLocked', false);", 1, true) ~= nil
)
check(
  "a press clears the last line first, so a repeated outcome is seen to arrive",
  html:find("$('unlock').addEventListener('click', function () { press('/chat/unlock'); });", 1, true) ~= nil
    and html:find("function press(path, body) { notice(''); act(path, body); }", 1, true) ~= nil
)
check(
  "a session the controller forgot is opened again and the action sent once more (not dropped)",
  html:find("j.reason === 'session' && !retried", 1, true) ~= nil
)
check("a refusal without a message still shows something", html:find("notice(j.message || ", 1, true) ~= nil)
check(
  "the chat card shows PIN progress and the button waits while it runs",
  html:find("var progress = AIC.pinProgress(st);", 1, true) ~= nil
    and html:find("$('unlock').disabled = !!progress;", 1, true) ~= nil
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
// A PIN entry in progress (PIN Lock asked, or checking the PIN) polls every
// second, so the outcome appears when it lands instead of 30 s later.
assert.strictEqual(AIC.pollDelay({ ok: true, checking: true, chat: {} }), 1000);
assert.strictEqual(AIC.pollDelay({ ok: true, prompt: { waiting: true } }), 1000);
assert.strictEqual(AIC.pollDelay({ ok: true, prompt: { waiting: false, challenge_id: 'ab' } }), 3000);
assert.strictEqual(AIC.pinProgress({ ok: true, checking: true }), 'Checking the PIN with PIN Lock…');
assert.strictEqual(AIC.pinProgress({ ok: true, prompt: { waiting: true } }), 'Asking PIN Lock for a PIN entry…');
assert.strictEqual(AIC.pinProgress({ ok: true, prompt: { waiting: false } }), null);
assert.strictEqual(AIC.pinProgress({ ok: true }), null);
var whys = ['copy', 'address', 'starting', 'nofetch', 'relay'];
var texts = whys.map(AIC.offlineText);
texts.forEach(function (t) { assert.ok(t && t.length > 20); assert.ok(!/https?:/.test(t)); });
assert.strictEqual(new Set(texts).size, whys.length, 'each reason reads differently');
assert.ok(/Close the AI Core tile and open it again/.test(AIC.offlineText('copy')));
assert.ok(/Republish App URL/.test(AIC.offlineText('address')));
assert.deepStrictEqual(AIC.parseQuery('?k=abc&s=1%202'), { k: 'abc', s: '1 2' });
]]
  )
  out:close()
  local ok = os.execute("node " .. tmp)
  os.remove(tmp)
  check("pure helpers pass under node (fake DOM refuses innerHTML)", ok == true or ok == 0)

  print("[3] the whole page under node: pressing Unlock always shows something")
  local scripts = {}
  for body in html:gmatch("<script[^>]*>(.-)</script>") do
    scripts[#scripts + 1] = body
  end
  check("two scripts (helpers, page)", #scripts == 2)
  -- The ids the markup starts hidden, read from the page itself.
  local hidden = {}
  for id, cls in html:gmatch('<%w+ id="(%w+)" class="([^"]*)"') do
    if (" " .. cls .. " "):find(" hidden ", 1, true) then
      hidden[#hidden + 1] = string.format("%q", id)
    end
  end
  local tmp2 = os.tmpname() .. ".js"
  local out2 = io.open(tmp2, "w")
  out2:write(
    "var PAGE = ",
    string.format("%q", scripts[1] .. "\n" .. scripts[2]):gsub("\\\n", "\\n"),
    ";\nvar HIDDEN = [",
    table.concat(hidden, ","),
    "];\n",
    [[
var vm = require('vm');
var assert = require('assert');
// A page in a fake web view: elements by id, a scripted fetch, timers held.
function boot(loc, routes) {
  var els = {};
  function El(id) {
    this.id = id; this.children = []; this._text = ''; this.disabled = false; this.value = ''; this.on = {};
    var cls = {}; this.classList = { toggle: function (c, on) { cls[c] = !!on; }, contains: function (c) { return !!cls[c]; } };
  }
  Object.defineProperty(El.prototype, 'textContent', { set: function (v) { this._text = String(v); this.children = []; }, get: function () { return this._text; } });
  Object.defineProperty(El.prototype, 'firstChild', { get: function () { return this.children[0] || null; } });
  El.prototype.appendChild = function (c) { this.children.push(c); return c; };
  El.prototype.removeChild = function (c) { this.children.splice(this.children.indexOf(c), 1); return c; };
  El.prototype.setAttribute = function () {};
  El.prototype.focus = function () {};
  El.prototype.click = function () { if (this.on.click) { this.on.click({}); } };
  El.prototype.addEventListener = function (ev, fn) { this.on[ev] = fn; };
  // The page's markup: hidden where index.html says so.
  HIDDEN.forEach(function (id) { els[id] = new El(id); els[id].classList.toggle('hidden', true); });
  var doc = {
    getElementById: function (id) { return els[id] || (els[id] = new El(id)); },
    createElement: function (t) { return new El(t); },
    addEventListener: function () {}, hidden: false
  };
  var calls = [], timers = [];
  function fetch(url, opts) {
    var method = (opts && opts.method) || 'GET';
    calls.push({ method: method, url: url, body: opts && opts.body });
    var path = url.split('?')[0];
    var r = routes(method, path, url, calls);
    return Promise.resolve({ status: r[0], json: function () { return Promise.resolve(r[1]); } });
  }
  var ctx = { document: doc, location: loc, fetch: fetch, Date: Date, JSON: JSON, Promise: Promise, Error: Error,
    encodeURIComponent: encodeURIComponent, decodeURIComponent: decodeURIComponent, Number: Number, String: String, Math: Math,
    setTimeout: function (fn, ms) { timers.push(ms); return timers.length; }, clearTimeout: function () {},
    window: { addEventListener: function () {} } };
  vm.createContext(ctx);
  vm.runInContext(PAGE, ctx);
  return { els: els, calls: calls, timers: timers, hidden: function (id) { return els[id].classList.contains('hidden'); } };
}
function settle() { return new Promise(function (r) { setTimeout(r, 20); }); }
var LOCKED = { ok: true, status: { text: {} }, pin: { message: 'PIN Lock is ready for this screen.' }, approvals: {},
  chat: { available: true, locked: true, message: 'The chat is locked. Enter an owner PIN to open it.' } };

(async function () {
  // A: the tile opened the driver's built-in copy (no relay, no token).
  var a = boot({ search: '', protocol: 'controller:', hostname: '' }, function () { throw new Error('no fetch expected'); });
  await settle();
  assert.ok(a.hidden('chatLocked'), 'A: no Unlock button on a page that cannot connect');
  assert.ok(!a.hidden('notice') && /built-in copy/.test(a.els.notice.textContent), 'A: says it is the built-in copy');
  assert.strictEqual(a.calls.length, 0);

  // B: Unlock on a session the controller forgot (the page slept): the
  // press is not lost, it is sent again on a new session.
  var sessions = 0, unlocks = 0;
  var b = boot({ search: '?k=' + 'a'.repeat(32), protocol: 'http:', hostname: 'controller.test' }, function (m, path, url) {
    if (path === '/session') { sessions++; return [200, { ok: true, s: 's' + sessions }]; }
    if (path === '/state') { return [200, unlocks > 0 && /s=s2/.test(url) ? Object.assign({}, LOCKED, { prompt: { 'for': 'chat', waiting: true } }) : LOCKED]; }
    if (path === '/chat/unlock') { unlocks++; return /s=s1/.test(url) ? [401, { ok: false, reason: 'session' }] : [200, { ok: true, waiting: true }]; }
    return [404, { ok: false }];
  });
  await settle();
  assert.ok(!b.hidden('chatLocked'), 'B: Unlock shown once the controller says so');
  b.els.unlock.click();
  await settle();
  assert.strictEqual(unlocks, 2, 'B: the unlock was sent again after the session was reopened');
  assert.strictEqual(sessions, 2);
  assert.strictEqual(b.els.chatMsg.textContent, 'Asking PIN Lock for a PIN entry…', 'B: progress is shown');
  assert.ok(b.els.unlock.disabled, 'B: the button waits');
  assert.strictEqual(b.timers[b.timers.length - 1], 1000, 'B: polls every second while PIN Lock is asked');

  // C: a refusal without a message, and the same refusal twice: always shown.
  var c = boot({ search: '?k=' + 'a'.repeat(32), protocol: 'http:', hostname: 'controller.test' }, function (m, path) {
    if (path === '/session') { return [200, { ok: true, s: 's1' }]; }
    if (path === '/state') { return [200, LOCKED]; }
    if (path === '/chat/unlock') { return [200, { ok: false, reason: 'whatever' }]; }
    return [404, { ok: false }];
  });
  await settle();
  c.els.unlock.click();
  assert.ok(c.hidden('notice'), 'C: the press clears the last line at once');
  await settle();
  assert.ok(!c.hidden('notice') && c.els.notice.textContent.length > 10, 'C: a refusal without a message still shows');

  // D: the install token changed (an old tile address): said, not silent.
  var d = boot({ search: '?k=' + 'b'.repeat(32), protocol: 'http:', hostname: 'controller.test' }, function () { return [403, { ok: false, error: 'bad token' }]; });
  await settle();
  assert.ok(d.hidden('chatLocked') && /out-of-date/.test(d.els.notice.textContent), 'D: an old address is said');
})().catch(function (e) { console.error(e); process.exit(1); });
]]
  )
  out2:close()
  local ok2 = os.execute("node " .. tmp2)
  os.remove(tmp2)
  check(
    "the page under node: built-in copy, a forgotten session, a bare refusal, an old address",
    ok2 == true or ok2 == 0
  )
else
  print("  SKIP node not available; helper cases not run")
end
print(string.format("%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
