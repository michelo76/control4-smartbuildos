-- Daypart Scheduler page: static guards (self-contained, no CDN, touch
-- friendly) and the page's pure JavaScript helpers, run with node when node is
-- available. Without node the JS cases are SKIPPED and say so; this file never
-- claims a render it did not do.
--
-- Run from the driver root: make test

local pass, fail, skipped = 0, 0, 0
local function check(name, ok, detail)
  if ok then
    pass = pass + 1
    print(string.format("  ok   %s", name))
  else
    fail = fail + 1
    print(string.format("  FAIL %s%s", name, detail and ("  -> " .. tostring(detail)) or ""))
  end
end

local PAGE = "drivers/smartbuildos-daypart/www/app/index.html"
local f = io.open(PAGE, "r") or io.open("../" .. PAGE, "r")
check("the page exists", f ~= nil)
if f == nil then
  os.exit(1)
end
local html = f:read("*a")
f:close()

print("[1] static guards")
check(
  "no external script or stylesheet",
  not html:find("<script[^>]-src=") and not html:find("<link[^>]-rel=[\"']stylesheet")
)
check("no absolute URLs to anywhere", not html:find("https?://[%w%-%.]+%.[a-z][a-z]"))
check("viewport meta for phones", html:find('name="viewport"', 1, true) ~= nil)
check("light and dark colours", html:find("prefers-color-scheme: dark", 1, true) ~= nil)
check("buttons are at least 48px tall", html:find("min%-height: 48px") ~= nil)
check(
  "dialogs for the block and the PIN",
  html:find('id="blockDlg"', 1, true) ~= nil and html:find('id="pinDlg"', 1, true) ~= nil
)
check(
  "the PIN field is a password field",
  html:find('id="pin"', 1, true) ~= nil and html:find('type="password"', 1, true) ~= nil
)
check("the pure helpers are in their own script", html:find('<script id="daypart-pure">', 1, true) ~= nil)
check("the page never puts the PIN in a URL", not html:find("pin=", 1, true))

print("[2] pure JavaScript helpers (node)")
local node = io.popen("command -v node 2>/dev/null")
local nodePath = node and node:read("*l") or nil
if node then
  node:close()
end
if nodePath == nil or nodePath == "" then
  skipped = 1
  print("  SKIP node is not installed: the page's JavaScript helpers were NOT exercised")
else
  local script = os.tmpname()
  local out = io.open(script, "w")
  out:write([[
const fs = require('fs');
const html = fs.readFileSync(process.argv[2], 'utf8');
const m = /<script id="daypart-pure">([\s\S]*?)<\/script>/.exec(html);
const DP = new Function(m[1] + '; return DP;')();
const results = [];
function t(name, ok) { results.push((ok ? 'ok   ' : 'FAIL ') + name); }
t('parseTime', DP.parseTime('07:05') === 425 && DP.parseTime('7:05') === 425 && DP.parseTime('24:00') === null && DP.parseTime('24:00', true) === 1440 && DP.parseTime('09:75') === null && DP.parseTime('') === null);
t('fmtTime', DP.fmtTime(425) === '07:05' && DP.fmtTime(1440) === '24:00');
t('clamp', DP.clamp(90, 10, 50) === 50 && DP.clamp(-3, 10, 50) === 10 && DP.clamp('x', 10, 50) === 10 && DP.clamp(30.4, 10, 50) === 30);
t('describeDays', DP.describeDays([1,2,3,4,5]) === 'Mon-Fri' && DP.describeDays([6,7]) === 'Sat, Sun' && DP.describeDays([1,3,5]) === 'Mon, Wed, Fri' && DP.describeDays([1,2,3,4,5,6,7]) === 'every day' && DP.describeDays([]) === '');
t('arr tolerates an empty JSON object', DP.arr({}).length === 0 && DP.arr(null).length === 0 && DP.arr([1]).length === 1);
const plain = DP.weekSegments([{ name: 'M', days: [1,2], from: '07:00', to: '11:00' }]);
t('weekSegments plain block', plain.length === 2 && plain[0].from === 420 && plain[0].to === 660 && !plain[0].spill);
const cross = DP.weekSegments([{ name: 'L', days: [5, 7], from: '22:00', to: '02:00' }]);
t('weekSegments midnight crossing draws the start day to 24:00 and the spill on the next day', cross.length === 4 && cross[0].day === 5 && cross[0].to === 1440 && cross[1].day === 6 && cross[1].from === 0 && cross[1].to === 120 && cross[1].spill);
t('Sunday spills onto Monday', cross[3].day === 1 && cross[3].spill);
const toMidnight = DP.weekSegments([{ name: 'E', days: [3], from: '18:00', to: '24:00' }]);
t('a block to 24:00 has no spill', toMidnight.length === 1 && toMidnight[0].to === 1440);
t('weekSegments skips unreadable times', DP.weekSegments([{ name: 'x', days: [1], from: 'zz', to: '10:00' }]).length === 0);
t('crossing', DP.crossing('22:00', '02:00') === true && DP.crossing('07:00', '11:00') === false && DP.crossing('18:00', '24:00') === false);
const zone = { sources: [{ id: 200, label: 'Digital Music' }], week: [{id:'b1'}], holiday: [{id:'h1'}], today: { blocks: [{id:'t1'}] } };
t('sourceLabel', DP.sourceLabel(zone, 200) === 'Digital Music' && DP.sourceLabel(zone, 'off') === 'Music off' && DP.sourceLabel(zone, null) === 'Source unchanged' && DP.sourceLabel(zone, 999) === 'Source no longer offered');
t('blockSummary', DP.blockSummary(zone, { source: 200, volume: 30, displays: 'on' }) === 'Digital Music, volume 30, displays on' && DP.blockSummary(zone, { source: 'off', volume: 5 }) === 'Music off');
t('scopeBlocks', DP.scopeBlocks(zone, 'week')[0].id === 'b1' && DP.scopeBlocks(zone, 'holiday')[0].id === 'h1' && DP.scopeBlocks(zone, 'today')[0].id === 't1' && DP.scopeBlocks(null, 'week').length === 0);
t('colorIndex', DP.colorIndex(zone, 200) === 0 && DP.colorIndex(zone, 'off') === 'off' && DP.colorIndex(zone, null) === 'none' && DP.colorIndex(zone, 999) === 'none' && DP.colorIndex({ sources: [1,2,3,4,5,6,7].map(function (i) { return { id: i }; }) }, 7) === 0);
t('progress', DP.progress(540, '08:00', '10:00') === 0.5 && DP.progress(600, '08:00', '10:00') === null && DP.progress(60, '22:00', '02:00') === 0.75 && DP.progress(1380, '22:00', '02:00') === 0.25 && DP.progress(1200, '22:00', '02:00') === null && DP.progress('x', '08:00', '10:00') === null);
console.log(results.join('\n'));
]])
  out:close()
  local p = io.popen(nodePath .. " " .. script .. " " .. PAGE .. " 2>&1")
  local text = p:read("*a")
  p:close()
  os.remove(script)
  local any = false
  for line in text:gmatch("[^\n]+") do
    if line:match("^ok   ") then
      any = true
      check(line:sub(6), true)
    elseif line:match("^FAIL ") then
      any = true
      check(line:sub(6), false)
    else
      check("node output: " .. line, false)
    end
  end
  check("node ran the helpers", any)
end

print(string.format("\n%d passed, %d failed%s", pass, fail, skipped > 0 and ", JS helpers skipped" or ""))
if fail > 0 then
  os.exit(1)
end
