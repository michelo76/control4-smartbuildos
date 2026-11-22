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
check("a dark theme, declared", html:find('<meta name="color-scheme" content="dark">', 1, true) ~= nil)
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
  "question chips wrap a long (120-character) preset label inside the page",
  html:find("%.chip {[^}]*white%-space: normal") ~= nil
    and html:find("%.chip {[^}]*max%-width: 100%%") ~= nil
    and html:find("%.chip {[^}]*overflow%-wrap: anywhere") ~= nil
)
check(
  "the in-page keyboard sits in the page's flow (never fixed over the thread)",
  html:find("#kb {[^}]*flex: none") ~= nil and not html:find("#kb {[^}]*position: fixed")
)
check(
  "…and while it is open the input cannot summon the system keyboard",
  html:find("input.readOnly = kbOpen;", 1, true) ~= nil
    and html:find("input.setAttribute('inputmode', 'none')", 1, true) ~= nil
)
check(
  "the page polls every second while an answer is pending",
  html:find("if (A.pending(st)) { return 1000; }", 1, true) ~= nil
)
check("no 'no follow-ups' sentence any more", not html:find("there are no follow-ups", 1, true))
check(
  "hiding the page tells the controller (open chat starts over, the owner unlock ends)",
  html:find("call('/chat/lock', { hidden: true })", 1, true) ~= nil
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
  "thread",
  "strip",
  "composer",
  "kb",
  "kbBtn",
  "counter",
  "elevate",
  "ownerBox",
  "lockIn",
  "apprBtn",
  "apprBadge",
  "apprSheet",
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
El.prototype.querySelector = function () { return null; };
function texts(e) { return [e.textContent].concat(e.children.map(texts)).join(' '); }
function all(e, cls) { var out = []; (function walk(x) { if ((' ' + x.className + ' ').indexOf(' ' + cls + ' ') >= 0) { out.push(x); } x.children.forEach(walk); })(e); return out; }
var root = new El('div');
var picked = [];
var th = AIC.renderConversation(doc, root, { conv: 1, conversation: [
  { id: 'a1', q: evil, a: evil + ' answer', state: 'answered', conv: 1 },
  { id: 'a2', q: 'Pending?', state: 'pending', age: 7, conv: 1 },
  { id: 'a3', q: 'Refused?', state: 'refused', message: 'Too many requests.', conv: 1 }
] }, function (x) { picked.push(x); });
assert.strictEqual(htmlWrites, 0, 'no innerHTML');
var q = all(root, 'q'), ans = all(root, 'a');
assert.strictEqual(q[0].textContent, evil, 'the question is text, verbatim');
assert.strictEqual(ans[0].textContent, evil + ' answer', 'the answer is text, verbatim');
assert.ok(th.a2 && th.a2.text.textContent === 'Thinking… 7 s', 'a thinking bubble with its seconds');
assert.ok(/hidden/.test(th.a2.still.className), 'no "still working" line before 45 s');
assert.strictEqual(all(root, 'problem')[0].textContent, 'Too many requests.');
AIC.renderConversation(doc, root, { conversation: [{ id: 'x', q: 'Q', state: 'pending', age: 46 }] }, function () {});
assert.ok(!/hidden/.test(all(root, 'still')[0].className), 'the calm line after 45 s');

// rich answers: every block type as cards, text only, invalid ones dropped
var odd = 'Gate "B" & Co\'s 13.2 \u00b0C';
var display = [
  { t: 'stat', label: 'Cellar', value: '13.2', unit: '°C', tone: 'ok' },
  { t: 'list', title: 'Doors', items: [{ label: 'Front', value: 'Locked', tone: 'ok' }, { label: odd, value: odd, tone: 'warn' }, { label: 'Gate' }] },
  { t: 'note', text: odd, tone: 'bad' },
  { t: 'note', text: evil },
  { t: 'note', text: 'See https\u003a//example.org' },
  { t: 'note', text: 'Visit example.com' },
  { t: 'note', text: ' padded' },
  { t: 'note', text: 'bidi\u202eevil' },
  { t: 'note', text: 'zero\u200bwidth' },
  { t: 'note', text: 'tag\udb40\udc01char' },
  { t: 'note', text: '\uff21' },
  { t: 'note', text: new Array(302).join('\ud83c\udfe0') },
  { t: 'stat', label: 'Power', value: 1250 },
  { t: 'html', text: '<b>x</b>' },
  { t: 'note', text: 'x', onclick: 'alert(1)' },
  { t: 'note', text: 'x', tone: 'red' },
  { t: 'stat', label: new Array(122).join('a'), value: '1' },
  { t: 'list', items: [] },
  { t: 'note', text: 'bell\u0007' }
];
var clean = AIC.cleanBlocks(display);
assert.deepStrictEqual(clean.map(function (b) { return b.t; }), ['stat', 'list', 'note'], 'only the three valid blocks survive');
root = new El('div');
AIC.renderConversation(doc, root, { conversation: [{ id: 'r', q: 'Q', a: 'Answer', state: 'answered', display: display, suggestions: ['Follow 1?', evil, 'Follow 1?', 'No question', 'Four?', 'Five?', 'Six?'] }] }, function (x) { picked.push(x); });
assert.strictEqual(htmlWrites, 0);
var stat = all(root, 'b-stat')[0];
assert.ok(stat && /tone-ok/.test(stat.className), 'a stat card with its tone');
assert.strictEqual(all(stat, 'l')[0].textContent, 'Cellar');
assert.ok(/^13\.2/.test(texts(all(stat, 'v')[0]).trim()) && all(stat, 'u')[0].textContent === '°C', 'a large value with its unit');
var rows = all(root, 'row');
assert.strictEqual(rows.length, 3, 'a list: one row per item');
assert.ok(/tone-warn/.test(rows[1].children[0].className), 'a row starts with a tone dot');
assert.strictEqual(rows[1].children[1].textContent, odd, 'a row label is text, verbatim');
assert.strictEqual(rows[1].children[2].className, 'rv', 'a right-aligned value');
assert.strictEqual(rows[2].children.length, 2, 'a row without a value has none');
assert.ok(/tone-bad/.test(all(root, 'b-note')[0].className) && all(root, 'b-note')[0].textContent === odd, 'a tinted note, text');
assert.strictEqual(all(root, 'b-note').length, 1, 'markup, a URL, a bare domain, padding, bidi, zero-width, tag, full-width, 301 emoji, a number: all dropped');
assert.ok(AIC.plain(new Array(121).join('\ud83c\udfe0'), 120), '120 emoji: 120 code points, kept');
assert.strictEqual(AIC.plain(new Array(122).join('\u00e9'), 120), null, '121 accented letters: dropped');
assert.strictEqual(all(root, 'cards').length, 1);
var follow = all(root, 'follow');
assert.deepStrictEqual(follow.map(function (b) { return b.textContent; }), ['Follow 1?', 'Four?', 'Five?'], 'at most three follow-ups, once each, questions only, markup dropped');
follow[1].on(); assert.deepStrictEqual(picked[picked.length - 1], { question: 'Four?' }, 'a follow-up asks its own text');
assert.strictEqual(AIC.renderBlocks(doc, null), null, 'no display: text only');
assert.strictEqual(AIC.renderBlocks(doc, 'garbage'), null);
// follow-ups only under the LAST answer
root = new El('div');
AIC.renderConversation(doc, root, { conversation: [{ id: 'a', q: 'Q', a: 'A', state: 'answered', suggestions: ['S?'] }, { id: 'b', q: 'Q2', state: 'pending' }] }, function () {});
assert.strictEqual(all(root, 'follow').length, 0);
// dividers where a new conversation starts
root = new El('div');
AIC.renderConversation(doc, root, { conv: 3, elevated: true, conversation: [{ id: 'a', q: 'Q', a: 'A', state: 'answered', conv: 1 }, { id: 'b', q: 'Q2', a: 'A2', state: 'answered', conv: 2, elevated: true }] }, function () {});
var divs = all(root, 'divider').map(texts);
assert.strictEqual(divs.length, 2);
assert.ok(/Owner unlocked/.test(divs[0]) && /Owner unlocked/.test(divs[1]));
root = new El('div');
AIC.renderConversation(doc, root, { conv: 2, elevated: false, conversation: [{ id: 'a', q: 'Q', a: 'A', state: 'answered', conv: 1 }] }, function () {});
assert.ok(/earlier messages are not remembered/.test(texts(all(root, 'divider')[0])), 'a fresh start after lock or timeout is said');

// chips: Explain only when offered, then presets, then built-ins
var chips = AIC.questionChips({ explain: true, suggestions: [{ id: 'p1-9', label: evil }, { id: 'working', label: 'W?' }] });
assert.deepStrictEqual(chips.map(function (c) { return c.send; }), [{ explain: true }, { suggestion_id: 'p1-9' }, { suggestion_id: 'working' }]);
assert.strictEqual(AIC.questionChips({ explain: false, suggestions: [] }).length, 0);
var sug = new El('div');
AIC.renderChips(doc, sug, chips, function (x) { picked.push(x); });
assert.strictEqual(sug.children[1].textContent, evil, 'a preset label is never markup');
sug.children[1].on(); assert.deepStrictEqual(picked[picked.length - 1], { suggestion_id: 'p1-9' });
var longLabel = new Array(13).join('Is it warm?');
AIC.renderChips(doc, sug, [{ label: longLabel, send: {} }], function () {});
assert.strictEqual(sug.children[0].textContent, longLabel, 'a long preset label is text, whole');
var ul = new El('ul');
AIC.renderLines(doc, ul, ['Online', evil, '', null]);
assert.strictEqual(ul.children.length, 2);
assert.strictEqual(ul.children[1].textContent, evil);
assert.strictEqual(htmlWrites, 0);
assert.deepStrictEqual(AIC.statusLines({ status: { text: { online: 'Online', licensed: 'Licensed', provider: 'P', learning: 'L' } }, pin: { message: 'M' } }), ['Online', 'Licensed', 'P', 'L', 'M']);

// the modes
assert.strictEqual(AIC.chatMode({ ok: true, chat: { available: false } }), 'off');
assert.strictEqual(AIC.chatMode({ ok: true, chat: { available: true, locked: true } }), 'locked');
assert.strictEqual(AIC.chatMode({ ok: true, chat: { available: true, locked: false } }), 'open');
assert.strictEqual(AIC.chatMode({ ok: true, chat: { available: true, locked: false, elevated: true } }), 'elevated');
assert.strictEqual(AIC.chatMode(null), 'off');

// the keyboard: the right text
var kb = { value: '', shift: true, layer: 'abc' };
function type(keys) { keys.forEach(function (k) { kb = AIC.kbPress(kb, k); }); return kb.value; }
assert.strictEqual(type(['h', 'i', 'space', 'y', 'o', 'u', '?']), 'Hi you?', 'a capital first letter, then lower case');
assert.strictEqual(type(['space']), 'Hi you? ');
assert.ok(kb.shift, 'shift again after the end of a sentence');
assert.strictEqual(type(['o', 'k']), 'Hi you? Ok');
assert.strictEqual(type(['back', 'back']), 'Hi you? ');
assert.strictEqual(type(['layer', '2', '0', '°']), 'Hi you? 20°', 'numbers and symbols on their own layer');
assert.strictEqual(kb.layer, 'sym');
type(['layer']); assert.strictEqual(kb.layer, 'abc');
assert.strictEqual(type(['shift', 'a']), 'Hi you? 20°A', 'shift is one-shot');
assert.strictEqual(type(['a']), 'Hi you? 20°Aa');
kb = AIC.kbPress(kb, 'send'); assert.ok(kb.send, 'Send sends');
kb = { value: new Array(501).join('x'), shift: false, layer: 'abc' };
assert.strictEqual(AIC.kbPress(kb, 'y').value.length, 500, 'never past 500 characters');
kb = { value: 'é', shift: false, layer: 'abc' };
assert.strictEqual(AIC.kbPress(kb, 'back').value, '', 'backspace removes a whole character');
assert.strictEqual(AIC.kbLabel('a', { layer: 'abc', shift: true }), 'A');
assert.strictEqual(AIC.kbLabel('layer', { layer: 'abc' }), '123');
['abc', 'sym'].forEach(function (l) { AIC.KB[l].forEach(function (row) { assert.ok(row.length <= 10, 'at most 10 keys a row'); }); });
// the counter, near the limit only
assert.strictEqual(AIC.counterText(399), '');
assert.strictEqual(AIC.counterText(432), '432 / 500');
assert.strictEqual(AIC.minutesLeft(240), '4 min');

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
assert.strictEqual(AIC.pollDelay({ ok: true, chat: { conversation: [{ state: 'pending' }] } }), 1000, 'every second while an answer is pending');
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
  check(
    "pure helpers pass under node (fake DOM refuses innerHTML): blocks, invalid blocks dropped, chips, keyboard, modes",
    ok == true or ok == 0
  )

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
  El.prototype.setAttribute = function (k, v) { this.attrs = this.attrs || {}; this.attrs[k] = v; };
  El.prototype.removeAttribute = function (k) { if (this.attrs) { delete this.attrs[k]; } };
  El.prototype.getAttribute = function (k) { return this.attrs ? this.attrs[k] : undefined; };
  El.prototype.focus = function () {};
  El.prototype.blur = function () {};
  El.prototype.click = function () { if (this.on.click) { this.on.click({}); } };
  El.prototype.addEventListener = function (ev, fn) { this.on[ev] = fn; };
  // The page's markup: hidden where index.html says so.
  HIDDEN.forEach(function (id) { els[id] = new El(id); els[id].classList.toggle('hidden', true); });
  var doc = {
    getElementById: function (id) { return els[id] || (els[id] = new El(id)); },
    querySelector: function (sel) { return els[sel] || (els[sel] = new El(sel)); },
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
  return { els: els, calls: calls, timers: timers, hidden: function (id) { return els[id].classList.contains('hidden'); },
    text: function (id) { return (function t(e) { return e._text + e.children.map(t).join(' '); })(els[id]); } };
}
function settle() { return new Promise(function (r) { setTimeout(r, 20); }); }
var LOCKED = { ok: true, status: { text: {} }, pin: { message: 'PIN Lock is ready for this screen.' }, approvals: {},
  chat: { available: true, locked: true, message: 'The chat is locked. Enter an owner PIN to open it.' } };

(async function () {
  // A: the tile opened the driver's built-in copy (no relay, no token).
  var a = boot({ search: '', protocol: 'controller:', hostname: '' }, function () { throw new Error('no fetch expected'); });
  await settle();
  assert.ok(a.hidden('chatLocked'), 'A: no Unlock button on a page that cannot connect');
  assert.ok(!a.hidden('notice') && /built-in copy/.test(a.els.noticeText.textContent), 'A: says it is the built-in copy');
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
  assert.ok(!c.hidden('notice') && c.els.noticeText.textContent.length > 10, 'C: a refusal without a message still shows');

  // D: the install token changed (an old tile address): said, not silent.
  var d = boot({ search: '?k=' + 'b'.repeat(32), protocol: 'http:', hostname: 'controller.test' }, function () { return [403, { ok: false, error: 'bad token' }]; });
  await settle();
  assert.ok(d.hidden('chatLocked') && /out-of-date/.test(d.els.noticeText.textContent), 'D: an old address is said');

  // E: open chat: the chat and its input bar first, no lock; Explain not offered.
  var OPEN = { ok: true, status: { licensed: true, online: true, provider_configured: true, text: { online: 'Online' } }, approvals: { count: 2, text: '2 items await approval' },
    chat: { available: true, locked: false, mode: 'open', elevated: false, can_elevate: true, conv: 1, followups: true, explain: false,
      suggestions: [{ id: 'working', label: 'Is everything working?' }], conversation: [] } };
  var asked = [];
  var e = boot({ search: '?k=' + 'a'.repeat(32), protocol: 'http:', hostname: 'controller.test' }, function (m, path, url, calls) {
    if (path === '/session') { return [200, { ok: true, s: 's1' }]; }
    if (path === '/state') { return [200, OPEN]; }
    if (path === '/ask') { asked.push(JSON.parse(calls[calls.length - 1].body)); return [200, { ok: false, reason: 'rate_limited', message: 'Too many requests. Wait a minute and try again.' }]; }
    return [200, { ok: true }];
  });
  await settle();
  assert.ok(!e.hidden('composer') && !e.hidden('chatOpen'), 'E: the chat and its input bar');
  assert.ok(e.hidden('chatLocked') && e.hidden('gate'), 'E: no lock');
  assert.ok(!e.hidden('elevate') && e.hidden('lock') && e.hidden('ownerBox'), 'E: Unlock for more, no Lock');
  assert.ok(/Try asking/.test(e.text('thread')) && !/Explain/.test(e.text('thread')), 'E: the empty state, no Explain');
  assert.strictEqual(e.els.apprBadge.textContent, '2', 'E: approvals reachable from the header with their count');
  // a refusal is a sentence in the thread, the typed text comes back
  e.els.question.value = 'Is the gate shut?';
  e.els.ask.click();
  await settle();
  assert.deepStrictEqual(asked[0], { question: 'Is the gate shut?' });
  assert.ok(/Too many requests/.test(e.text('thread')), 'E: the refusal is in the thread');
  assert.ok(e.hidden('notice'), 'E: …not only a banner');
  assert.strictEqual(e.els.question.value, 'Is the gate shut?', 'E: the text comes back');
  // the in-page keyboard
  e.els.question.value = '';
  e.els.kbBtn.click();
  assert.ok(!e.hidden('kb') && e.els.question.readOnly === true, 'E: the keyboard opens; the system one cannot');
  var keys = []; (function walk(x) { if (x.attrs && x.attrs['data-key']) { keys.push(x); } x.children.forEach(walk); })(e.els.kbRows);
  function key(k) { var b = null; (function walk(x) { if (x.attrs && x.attrs['data-key'] === k) { b = x; } x.children.forEach(walk); })(e.els.kbRows); b.on.click(); }
  ['o', 'k', '?'].forEach(key);
  assert.strictEqual(e.els.question.value, 'Ok?', 'E: the keyboard typed it');
  e.els.kbBtn.click();
  assert.ok(e.hidden('kb') && e.els.question.readOnly === false, 'E: closed: the system keyboard may come back');

  // F: Basic: the chat is off with its sentence; approvals still reachable.
  var BASIC = Object.assign({}, OPEN, { chat: { available: false, locked: true, message: 'The chat is switched off on this screen. Use the SmartBuildOS portal.' } });
  var f = boot({ search: '?k=' + 'a'.repeat(32), protocol: 'http:', hostname: 'controller.test' }, function (m, path) {
    if (path === '/session') { return [200, { ok: true, s: 's1' }]; }
    return [200, BASIC];
  });
  await settle();
  assert.ok(!f.hidden('gate') && f.hidden('composer') && f.hidden('chatLocked'), 'F: the gate, no input bar, no unlock');
  assert.ok(/switched off/.test(f.els.chatMsg.textContent), 'F: says why');

  // G: elevated: the lock timer and Lock; Explain offered.
  var ELEV = Object.assign({}, OPEN, { chat: Object.assign({}, OPEN.chat, { elevated: true, can_elevate: false, locks_in: 240, explain: true }) });
  var g = boot({ search: '?k=' + 'a'.repeat(32), protocol: 'http:', hostname: 'controller.test' }, function (m, path) {
    if (path === '/session') { return [200, { ok: true, s: 's1' }]; }
    return [200, ELEV];
  });
  await settle();
  assert.ok(!g.hidden('lock') && !g.hidden('ownerBox') && g.hidden('elevate'), 'G: Lock and the owner badge');
  assert.strictEqual(g.els.lockIn.textContent, '4 min', 'G: the lock timer');
  assert.ok(/Explain what just happened/.test(g.text('thread')), 'G: Explain offered');
})().catch(function (e) { console.error(e); process.exit(1); });
]]
  )
  out2:close()
  local ok2 = os.execute("node " .. tmp2)
  os.remove(tmp2)
  check(
    "the page under node: built-in copy, a forgotten session, a bare refusal, an old address, "
      .. "open chat, a refusal in the thread, the keyboard, Basic, the owner unlock",
    ok2 == true or ok2 == 0
  )
else
  print("  SKIP node not available; helper cases not run")
end
print(string.format("%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
