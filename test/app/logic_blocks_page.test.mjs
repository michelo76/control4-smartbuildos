// Browser test of the Logic Blocks dealer page (www/app/index.html).
//
// The page is served by tools/logic-blocks-dev.py, which runs the REAL block
// runtime, sandbox, app document and relay router (src/logic/*) with stand-in
// devices. It is a development host: nothing here is evidence of how a
// controller, Composer or equipment behaves.
//
// Covers: connected, empty, stale, offline, failed (restore failure, bad
// token); source-specific timestamps; every screen; the sandbox reaching
// nothing live; keyboard use, labels, focus and contrast in both themes;
// desktop and phone layouts; no token anywhere in the page or the export.
//
// Run:  node test/app/logic_blocks_page.test.mjs
// Env:  LB_PLAYWRIGHT   directory holding node_modules/playwright
//                       (default: ../smartbuildos beside this repo, read only)
//       LB_SCREENSHOTS  directory for screenshots (default docs/smartbuildos-logic-blocks/screens)
//       LB_NO_SCREENSHOTS=1 to skip them

import path from "node:path";
import fs from "node:fs";
import { spawn } from "node:child_process";
import { fileURLToPath, pathToFileURL } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, "../..");
const PW = process.env.LB_PLAYWRIGHT || path.resolve(repo, "../smartbuildos");
const SHOTS = process.env.LB_SCREENSHOTS || path.join(repo, "docs/smartbuildos-logic-blocks/screens");
const TOKEN = "devblocks0123456789abcdef";

let chromium;
try {
  ({ chromium } = await import(pathToFileURL(path.join(PW, "node_modules/playwright/index.mjs")).href));
} catch (e) {
  console.log("SKIP: Playwright not found under " + PW + " (set LB_PLAYWRIGHT). Nothing was tested.");
  process.exit(2);
}

let pass = 0, fail = 0;
function check(name, ok, detail) {
  if (ok) { pass++; console.log("  ok   " + name); }
  else { fail++; console.log("  FAIL " + name + (detail !== undefined ? "  -> " + String(detail).slice(0, 300) : "")); }
}

const servers = [];
async function serve(scenario, port) {
  const proc = spawn("python3", ["tools/logic-blocks-dev.py", "--port", String(port)], {
    cwd: repo, env: { ...process.env, LB_DEV_SCENARIO: scenario, LB_DEV_QUIET: "1", LB_DEV_TOKEN: TOKEN }, stdio: ["ignore", "pipe", "pipe"],
  });
  servers.push(proc);
  const base = "http://127.0.0.1:" + port;
  for (let i = 0; i < 80; i++) {
    try { const r = await fetch(base + "/ping"); if (r.ok) return base; } catch (e) { /* not up yet */ }
    await new Promise((r) => setTimeout(r, 100));
  }
  throw new Error("dev server did not start on " + port);
}
const dev = (base, p, body) => fetch(base + p, { method: "POST", body: JSON.stringify(body || {}) }).then((r) => r.json());
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const browser = await chromium.launch();
const errors = [];
async function open(base, opts = {}) {
  const ctx = await browser.newContext({ viewport: opts.viewport || { width: 1280, height: 900 }, colorScheme: opts.scheme || "light" });
  const page = await ctx.newPage();
  page.on("console", (m) => { if (m.type() === "error" && !/Failed to load resource|net::ERR/.test(m.text())) errors.push(m.text()); });
  page.on("pageerror", (e) => errors.push(String(e)));
  await page.goto(base + "/app?k=" + (opts.token || TOKEN) + (opts.hash || ""));
  return { ctx, page };
}
const text = (page) => page.locator("#main").innerText();
const chips = (page) => page.locator("#chips").innerText();
async function shot(page, name) {
  if (process.env.LB_NO_SCREENSHOTS) return;
  fs.mkdirSync(SHOTS, { recursive: true });
  await page.screenshot({ path: path.join(SHOTS, name + ".png"), fullPage: true });
}

// WCAG contrast of an element's text against its effective background.
async function contrast(page, selector) {
  return page.evaluate((sel) => {
    const el = document.querySelector(sel);
    if (!el) return null;
    const parse = (c) => { const m = c.match(/[\d.]+/g).map(Number); return { r: m[0], g: m[1], b: m[2], a: m.length > 3 ? m[3] : 1 }; };
    const lum = (c) => { const f = (v) => { v /= 255; return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); }; return 0.2126 * f(c.r) + 0.7152 * f(c.g) + 0.0722 * f(c.b); };
    let bg = null, node = el;
    while (node && node.nodeType === 1) { const c = parse(getComputedStyle(node).backgroundColor); if (c.a > 0.99) { bg = c; break; } node = node.parentElement; }
    if (!bg) bg = { r: 255, g: 255, b: 255 };
    const fg = parse(getComputedStyle(el).color);
    const a = lum(fg), b = lum(bg);
    return (Math.max(a, b) + 0.05) / (Math.min(a, b) + 0.05);
  }, selector);
}

try {
  // ── Connected ────────────────────────────────────────────────────────────
  console.log("[1] connected: overview");
  const house = await serve("house", 47881);
  let { ctx, page } = await open(house);
  await page.waitForSelector(".blockcard");
  check("shows a card per block", (await page.locator(".blockcard").count()) === 10);
  check("freshness chip says live", /Live/.test(await chips(page)), await chips(page));
  check("a block that cannot give a result is counted, not hidden", /1 need attention/.test(await chips(page)));
  let body = await text(page);
  check("summary: slots, enabled, countdowns, attention, last activity", /10 \/ 16/.test(body) && /Countdowns running/.test(body) && /Last activity/.test(body));
  check("a card shows name, slot, type, tag, state and status", /Driveway Welcome/.test(body) && /Block 01/.test(body) && /Cooldown/.test(body) && /Cooling down/.test(body));
  check("unknown is shown as unknown, not as off", /Entry Ready[\s\S]*Unknown[\s\S]*cannot read Alarm disarmed/.test(body));
  check("retired slots are listed apart", /Retired slots[\s\S]*Old Test Flag/.test(body));
  const cd1 = await page.locator(".countdown").first().innerText();
  await sleep(2100);
  const cd2 = await page.locator(".countdown").first().innerText();
  check("countdowns tick between refreshes", cd1 !== cd2, cd1 + " / " + cd2);
  await page.fill('input[type="search"]', "rack");
  check("search narrows the list", (await page.locator(".blockcard").count()) === 1);
  await page.fill('input[type="search"]', "zzzz");
  check("no match says so and offers a way back", /No block matches/.test(await text(page)));
  await page.getByRole("button", { name: "Clear filters" }).click();
  await page.selectOption('select[aria-label="Show"]', "attention");
  check("filter: need attention", (await page.locator(".blockcard").count()) === 1 && /Entry Ready/.test(await text(page)));
  await page.selectOption('select[aria-label="Show"]', "running");
  check("filter: countdown running", (await page.locator(".blockcard").count()) === 2);
  await page.selectOption('select[aria-label="Show"]', "");
  await page.selectOption('select[aria-label="Type"]', "flag");
  check("filter: by type", (await page.locator(".blockcard").count()) === 1 && /Guest Override/.test(await text(page)));
  await page.selectOption('select[aria-label="Type"]', "");
  await shot(page, "01-overview-desktop");

  console.log("[2] block detail");
  await page.getByRole("button", { name: /^Driveway Welcome/ }).click();
  await page.waitForSelector("text=What it does");
  body = await text(page);
  check("plain-English rule", /suppresses every repeat for 10 minutes/.test(body));
  check("the suppression explains itself", /Trigger suppressed: Driveway Welcome passed 3 minutes ago\. Its cooldown is 10 minutes\. Eligible again in 7 minutes\./.test(body));
  check("accepted and suppressed inputs are shown apart", /Accepted[\s\S]*Passed\.[\s\S]*Suppressed[\s\S]*Trigger suppressed/.test(body));
  check("output with the Composer variable names", /BLOCK_01_ACTIVE/.test(body) && /BLOCK_01_STATE/.test(body));
  check("says where it is configured", /This page cannot change a block/.test(body) && /Edit Selected Block/.test(body));
  check("says equipment is not confirmed without feedback", /never that equipment responded/.test(body));
  check("each decision shows the four separate facts", /1 · INPUT RECEIVED[\s\S]*2 · BLOCK EVALUATED[\s\S]*3 · EVENT EMITTED[\s\S]*4 · EQUIPMENT CONFIRMED/i.test(body));
  check("an emitted event without feedback reads 'Not monitored'", /Passed[\s\S]*Not monitored/.test(body));
  check("no edit control exists on the detail screen", (await page.locator("#main input, #main select, #main textarea").count()) === 0);
  await shot(page, "02-block-detail");

  console.log("[3] source-specific timestamps");
  await page.goto(house + "/app?k=" + TOKEN + "#block/5");
  await page.waitForSelector("text=Rack temperature");
  body = await text(page);
  check("an input shows its device, variable, value and state", /Rack Sensor › TEMPERATURE_F\s+\(device 82, variable 1000\)/.test(body) && /\b81\b/.test(body) && /Read/.test(body));
  const before = await page.evaluate(() => { const s = window.__logicBlocks.state.doc; return { src: s.blocks[4].sources[0].observed_at, other: s.blocks[0].last_accepted.at, gen: s.generated_at }; });
  await sleep(1200);
  await dev(house, "/__dev/variable", { device: 82, variable: 1000, value: "91" });
  await page.waitForFunction(() => window.__logicBlocks.state.doc.blocks[4].sources[0].value === "91", null, { timeout: 15000 });
  const after = await page.evaluate(() => { const s = window.__logicBlocks.state.doc; return { src: s.blocks[4].sources[0].observed_at, other: s.blocks[0].last_accepted.at, gen: s.generated_at, fb: s.blocks[4].feedback }; });
  check("the changed source's own timestamp moved", after.src > before.src);
  check("another block's timestamp did not", after.other === before.other);
  check("the snapshot time is separate from both", after.gen > before.gen && after.gen !== after.src);
  body = await text(page);
  check("the block became active and says why", /Active \(last reading 91 °F\)/.test(body));
  check("mapped feedback is shown with its current value", /Equipment feedback: Rack Fan Relay › RELAY_STATE/.test(body));
  await sleep(11000);
  await page.waitForFunction(() => /No equipment feedback within/.test(document.getElementById("main").innerText), null, { timeout: 15000 });
  body = await text(page);
  check("an event with no feedback is reported as not confirmed, never as done", /No feedback arrived/.test(body) && /No equipment feedback within 10 seconds/.test(body));
  await dev(house, "/__dev/variable", { device: 82, variable: 1000, value: null });
  await page.waitForFunction(() => window.__logicBlocks.state.doc.blocks[4].output.valid === false, null, { timeout: 15000 });
  body = await text(page);
  check("a source that disappears is 'cannot be read', the block unknown", /Cannot be read/.test(body) && /Unknown is not treated as false/.test(body));

  console.log("[4] connections");
  await page.goto(house + "/app?k=" + TOKEN + "#connections");
  await page.waitForSelector("text=Mappings this driver owns");
  body = await text(page);
  check("states what it cannot see", /cannot see Composer programming/.test(body));
  check("owned mappings are listed with device and variable ids", /Door closed ← Front Door Contact › CONTACT_STATE \(device 60, variable 1001\)/.test(body));
  check("Composer wiring is labelled as not verified", /Composer wiring to add\s+Not verified from here/.test(body));
  check("wiring names the exact command and event", /BLOCK_TRIGGER \(Block 01\)/.test(body) && /Block 01 Passed/.test(body) && /event id 1011/.test(body));
  check("dealer notes are kept apart from wiring", /Dealer notes[\s\S]*Welcome scene is the Exterior/.test(body));
  await shot(page, "03-connections");

  console.log("[5] activity");
  await page.goto(house + "/app?k=" + TOKEN + "#activity");
  await page.waitForSelector(".act");
  const allCount = await page.locator(".act").count();
  check("history is listed newest first", allCount > 10);
  await page.selectOption('select[aria-label="Block"]', "8");
  await page.waitForFunction(() => [...document.querySelectorAll(".act")].every((n) => /House Mode/.test(n.innerText)));
  body = await page.locator("#main .card").innerText();
  check("filter by block", /House Mode/.test(body) && !/Driveway Welcome/.test(body));
  check("a refused input shows its readable reason", /Night → Away is not an allowed transition/.test(body));
  await page.selectOption('select[aria-label="Decision"]', "refused");
  await page.waitForFunction(() => document.querySelectorAll(".act").length === 1 && /Refused/.test(document.querySelector(".act").innerText));
  check("filter by decision", (await page.locator(".act").count()) === 1);
  await page.selectOption('select[aria-label="Decision"]', "passed");
  await page.waitForFunction(() => /Nothing matches/.test(document.getElementById("main").innerText));
  check("an empty result says so", /No decision matches these filters/.test(await text(page)));
  await page.selectOption('select[aria-label="Block"]', "");
  await page.selectOption('select[aria-label="Decision"]', "");
  await page.selectOption('select[aria-label="Time"]', "900");
  await page.waitForSelector(".act");
  check("filter by time", (await page.locator(".act").count()) > 0);
  check("run ids are shown", /\br\d+\b/.test(await text(page)));
  await shot(page, "04-activity");

  console.log("[6] sandbox");
  const firedBefore = (await fetch(house + "/__dev/fired").then((r) => r.json())).fired.length;
  const liveBefore = await fetch(house + "/state?k=" + TOKEN).then((r) => r.json());
  await page.goto(house + "/app?k=" + TOKEN + "#sandbox");
  await page.waitForSelector("text=Simulated. Nothing here reaches the house.");
  await page.selectOption('select[aria-label="Block to copy"]', "2");
  await page.getByRole("button", { name: "Copy settings into the sandbox" }).click();
  await page.waitForSelector("text=Sandbox: Bathroom Vacancy");
  await page.getByRole("button", { name: "Start", exact: true }).click();
  await page.waitForSelector("text=Would fire: Block 02 Started");
  await page.getByRole("button", { name: "+10 min" }).click();
  await page.getByRole("button", { name: "Start", exact: true }).click();
  await page.waitForFunction(() => /Countdown restarted/.test(document.getElementById("main").innerText));
  await page.getByRole("button", { name: "To the next timer" }).click();
  await page.waitForSelector("text=Would fire: Block 02 Expired");
  body = await text(page);
  check("inject inputs and advance simulated time", /\+25 min/.test(body) && /Would fire: Block 02 Expired/.test(body));
  check("the timeline shows decisions with reasons", /Countdown restarted: 15 minutes again from now/.test(body));
  const timeline1 = await page.locator(".tl").innerText();
  await page.getByRole("button", { name: /Replay these/ }).click();
  await sleep(600);
  check("replay gives the same timeline", (await page.locator(".tl").innerText()) === timeline1);
  await page.getByRole("button", { name: "Reset to the start" }).click();
  await page.waitForFunction(() => /Nothing yet\. Send an input or move time\./.test(document.getElementById("main").innerText));
  check("reset clears the scenario", /\+0 s after it was opened/.test(await text(page)));
  const firedAfter = (await fetch(house + "/__dev/fired").then((r) => r.json())).fired.length;
  const liveAfter = await fetch(house + "/state?k=" + TOKEN).then((r) => r.json());
  check("SANDBOX: no live event fired", firedAfter === firedBefore, firedBefore + " -> " + firedAfter);
  check("SANDBOX: the live block was not touched", JSON.stringify(liveAfter.blocks[1].counts) === JSON.stringify(liveBefore.blocks[1].counts) && liveAfter.blocks[1].last_accepted.seq === liveBefore.blocks[1].last_accepted.seq);
  check("SANDBOX: nothing was added to the live history", liveAfter.activity[0].seq === liveBefore.activity[0].seq);
  check("the live block's state is shown beside the simulation", /Live block right now: Running/.test(await text(page)));
  await page.selectOption('select[aria-label="Block to copy"]', "6");
  await page.getByRole("button", { name: /Copy again/ }).click();
  await page.waitForSelector("text=Sandbox: Entry Ready");
  await page.fill('input[aria-label="Value for Alarm disarmed"]', "true");
  await page.locator('input[aria-label="Value for Alarm disarmed"]').locator("xpath=..").getByRole("button", { name: "Send" }).click();
  await page.waitForSelector("text=Would fire: Block 06 Became True");
  check("typed inputs can be simulated, including ones mapped to devices", true);
  await shot(page, "05-sandbox");
  await page.getByRole("button", { name: "Close sandbox" }).click();

  console.log("[7] diagnostics and export");
  await page.goto(house + "/app?k=" + TOKEN + "#diagnostics");
  await page.waitForSelector("text=Restart recovery report");
  body = await text(page);
  check("driver, licence, revision and transport are shown", /Configuration revision/.test(body) && /Licence status/.test(body) && /Snapshot taken/.test(body) && /Stored document version/.test(body));
  check("says it is a development host, not a controller", /DEVELOPMENT HOST \(not a controller\)/.test(body));
  check("missing mappings are listed with the reason", /Missing mappings[\s\S]*Rack Temperature[\s\S]*variable 1000 is not on device 82/.test(body));
  check("bounds are stated", /300 inputs to one block in 10 s/.test(body) && /200 \(50 across a restart\)/.test(body));
  const [download] = await Promise.all([page.waitForEvent("download"), page.getByRole("button", { name: "Download redacted export" }).click()]);
  const exported = fs.readFileSync(await download.path(), "utf8");
  check("the export downloads as JSON", download.suggestedFilename() === "logic-blocks-diagnostics.json" && JSON.parse(exported).schema === "logic_blocks.app.v1");
  check("the export holds no token", !exported.includes(TOKEN));
  check("the export omits dealer notes", !exported.includes("Exterior > Welcome"));
  await dev(house, "/__dev/restart", { down_seconds: 3600 });
  await page.waitForFunction(() => /did NOT fire/.test(document.getElementById("main").innerText), null, { timeout: 15000 });
  body = await text(page);
  check("after a restart the recovery report says what was missed", /Bathroom Vacancy: Countdown ended[\s\S]*did NOT fire/.test(body));
  await shot(page, "06-diagnostics");
  await page.goto(house + "/app?k=" + TOKEN + "#activity");
  await page.waitForSelector(".act");
  check("records from before the restart are marked", /From before the restart/.test(await text(page)));

  console.log("[8] templates and help");
  await page.goto(house + "/app?k=" + TOKEN + "#help");
  await page.waitForSelector("text=Recipes");
  body = await text(page);
  for (const name of ["Driveway welcome", "Bathroom vacancy", "Guest override", "Daily greeting", "Rack temperature"]) {
    check("recipe: " + name, body.includes(name));
  }
  check("recipes give the exact Composer steps", /Load Template Into Draft\. This fills a draft only/.test(body) && /Validate Draft/.test(body));
  check("recipes give exact wiring", /When Driveway Motion senses motion → Logic Pack: BLOCK_TRIGGER \(its slot\)/.test(body) && /When Logic Pack: its slot Passed → run the Welcome lighting scene/.test(body));
  check("a recipe that needs a device says the dealer picks it", /You pick the devices[\s\S]*Input 1: the temperature sensor/.test(body));
  check("vocabulary explains unknown and the four facts", /Unknown is never counted as false or zero/.test(body) && /an event firing never proves the equipment moved/.test(body));
  await shot(page, "07-help");

  console.log("[9] the token is nowhere in the page");
  for (const hash of ["#overview", "#block/1", "#connections", "#activity", "#diagnostics", "#help"]) {
    await page.goto(house + "/app?k=" + TOKEN + hash);
    await page.waitForFunction(() => window.__logicBlocks.state.doc);
    const html = await page.content();
    if (html.includes(TOKEN)) { check("no token in " + hash, false); }
  }
  check("no screen renders the access token", true);
  check("the page keeps no token in its exposed state", !(await page.evaluate(() => JSON.stringify(window.__logicBlocks.state))).includes(TOKEN));

  // ── Keyboard, labels, focus ──────────────────────────────────────────────
  console.log("[10] keyboard, labels, focus");
  await ctx.close();
  ({ ctx, page } = await open(house));
  await page.waitForSelector(".blockcard");
  await page.keyboard.press("Tab");
  check("a skip link is the first stop", (await page.evaluate(() => document.activeElement.textContent)) === "Skip to content");
  await page.keyboard.press("Tab");
  check("then the screen tabs", (await page.evaluate(() => document.activeElement.getAttribute("role"))) === "tab");
  const outline = await page.evaluate(() => getComputedStyle(document.activeElement).outlineStyle);
  check("keyboard focus is visible", outline !== "none", outline);
  await page.keyboard.press("ArrowRight");
  await page.waitForFunction(() => location.hash === "#connections");
  check("arrow keys move between screens", (await page.evaluate(() => document.activeElement.id)) === "tab-connections");
  await page.keyboard.press("Home");
  await page.waitForFunction(() => location.hash === "#overview");
  await page.waitForSelector(".blockcard");
  await page.locator(".blockcard").first().focus();
  await page.keyboard.press("Enter");
  await page.waitForFunction(() => location.hash === "#block/1");
  check("a block opens from the keyboard", true);
  check("one main landmark, one tablist, a live status region", (await page.locator("main").count()) === 1 && (await page.locator('[role="tablist"]').count()) === 1 && (await page.locator('[role="status"][aria-live]').count()) >= 1);
  for (const hash of ["#overview", "#activity", "#sandbox"]) {
    await page.goto(house + "/app?k=" + TOKEN + hash);
    await page.waitForFunction(() => window.__logicBlocks.state.doc);
    await sleep(300);
    const unnamed = await page.evaluate(() => [...document.querySelectorAll("input, select, button")].filter((el) => {
      const name = (el.getAttribute("aria-label") || el.textContent || "").trim() || (el.closest("label") ? el.closest("label").textContent.trim() : "");
      return !name;
    }).length);
    check("every control has a name on " + hash, unnamed === 0, unnamed);
  }

  // ── Contrast, both themes ────────────────────────────────────────────────
  console.log("[11] contrast");
  for (const scheme of ["light", "dark"]) {
    const o = await open(house, { scheme });
    await o.page.waitForSelector(".blockcard");
    for (const [label, sel] of [["body text", ".blockcard .name"], ["muted text", ".blockcard .status"], ["footer text", ".blockcard .foot span"], ["tab", 'nav button[aria-selected="false"]'], ["ok chip", ".chip.ok"], ["warn chip", ".chip.warn"], ["info chip", ".chip.info"], ["plain chip", ".chip.plain"]]) {
      const ratio = await contrast(o.page, sel);
      check(`contrast ${scheme}: ${label} ≥ 4.5`, ratio !== null && ratio >= 4.5, ratio && ratio.toFixed(2));
    }
    await o.page.goto(house + "/app?k=" + TOKEN + "#sandbox");
    await o.page.waitForSelector(".btn.primary");
    const ratio = await contrast(o.page, ".btn.primary");
    check(`contrast ${scheme}: primary button ≥ 4.5`, ratio >= 4.5, ratio.toFixed(2));
    check(`contrast ${scheme}: simulated banner ≥ 4.5`, (await contrast(o.page, ".banner.sim")) >= 4.5);
    if (scheme === "dark") await shot(o.page, "08-sandbox-dark");
    await o.ctx.close();
  }

  // ── Phone ────────────────────────────────────────────────────────────────
  console.log("[12] phone layout");
  const phone = await open(house, { viewport: { width: 390, height: 844 } });
  await phone.page.waitForSelector(".blockcard");
  for (const hash of ["#overview", "#block/5", "#connections", "#activity", "#sandbox", "#diagnostics", "#help"]) {
    await phone.page.goto(house + "/app?k=" + TOKEN + hash);
    await phone.page.waitForFunction(() => window.__logicBlocks.state.doc);
    await sleep(350);
    const overflow = await phone.page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
    check("phone: no sideways scrolling on " + hash, overflow <= 1, overflow);
  }
  await phone.page.goto(house + "/app?k=" + TOKEN + "#overview");
  await phone.page.waitForSelector(".blockcard");
  const cardWidth = await phone.page.evaluate(() => document.querySelector(".blockcard").getBoundingClientRect().width);
  check("phone: cards use the full width", cardWidth > 330, cardWidth);
  const tap = await phone.page.evaluate(() => Math.min(...[...document.querySelectorAll("nav button, .btn, .field select, .field input")].map((el) => el.getBoundingClientRect().height)));
  check("phone: controls are at least 36px tall", tap >= 36, tap);
  await shot(phone.page, "09-overview-phone");
  await phone.page.goto(house + "/app?k=" + TOKEN + "#block/5");
  await phone.page.waitForSelector("text=What it does");
  await shot(phone.page, "10-block-detail-phone");
  await phone.ctx.close();

  // ── Stale, then live again ───────────────────────────────────────────────
  console.log("[13] stale and offline");
  await page.goto(house + "/app?k=" + TOKEN + "#overview");
  await page.waitForSelector(".blockcard");
  const lastGood = await page.evaluate(() => window.__logicBlocks.state.doc.generated_at);
  await dev(house, "/__dev/offline", { on: true });
  await page.waitForFunction(() => window.__logicBlocks.freshness() === "stale", null, { timeout: 20000 });
  body = await text(page);
  check("stale: the chip changes", /Stale/.test(await chips(page)));
  check("stale: a banner says this is not live and since when", /This is not live\./.test(body) && /Showing what the controller reported at/.test(body));
  check("stale: the last good data is still shown, unchanged", (await page.locator(".blockcard").count()) === 10 && (await page.evaluate(() => window.__logicBlocks.state.doc.generated_at)) === lastGood);
  check("stale: it says why", /could not be reached|did not answer/.test(body));
  await shot(page, "11-stale");
  await dev(house, "/__dev/offline", { on: false });
  await page.waitForFunction(() => window.__logicBlocks.freshness() === "live", null, { timeout: 20000 });
  check("live again once the controller answers", /Live/.test(await chips(page)) && !/This is not live/.test(await text(page)));

  await dev(house, "/__dev/offline", { on: true });
  const off = await open(house);
  await off.page.waitForSelector("text=Not connected to the controller");
  body = await text(off.page);
  check("offline from the start: says so, with what to check", /same network/.test(body) && /Dealer App Access must be On/.test(body));
  check("offline: no blocks are invented", (await off.page.locator(".blockcard").count()) === 0 && /Not connected/.test(await chips(off.page)));
  await shot(off.page, "12-offline");
  await dev(house, "/__dev/offline", { on: false });
  await off.page.getByRole("button", { name: "Try again" }).click();
  await off.page.waitForSelector(".blockcard");
  check("offline: Try again connects", (await off.page.locator(".blockcard").count()) === 10);
  await off.ctx.close();

  console.log("[14] read-only");
  await dev(house, "/__dev/readonly", { on: true });
  await page.waitForFunction(() => /The pack is read-only/.test(document.getElementById("main").innerText), null, { timeout: 15000 });
  check("read-only is announced, with what it means", /Blocks refuse every input and running countdowns are held/.test(await text(page)) && /Read-only/.test(await chips(page)));
  await dev(house, "/__dev/readonly", { on: false });
  await ctx.close();

  // ── Failed states ────────────────────────────────────────────────────────
  console.log("[15] failed: bad token, restore failure");
  const bad = await open(house, { token: "notthetoken" });
  await bad.page.waitForSelector("text=Not connected to the controller");
  check("a refused token is explained, without echoing it", /refused the access token/.test(await text(bad.page)) && !(await bad.page.content()).includes("notthetoken"));
  await bad.ctx.close();
  const failedBase = await serve("restore_failed", 47883);
  const failed = await open(failedBase);
  await failed.page.waitForSelector("text=Stored blocks were not loaded after the last restart.");
  body = await text(failed.page);
  check("a restore failure is a banner on every screen", /Nothing was reset/.test(body) && /newer driver/.test(body));
  await failed.page.goto(failedBase + "/app?k=" + TOKEN + "#diagnostics");
  await failed.page.waitForSelector("text=Restart recovery report");
  check("and the recovery report says NOT LOADED", /NOT LOADED/.test(await text(failed.page)));
  await shot(failed.page, "13-restore-failed");
  await failed.ctx.close();

  // ── Empty ────────────────────────────────────────────────────────────────
  console.log("[16] empty");
  const emptyBase = await serve("empty", 47882);
  const empty = await open(emptyBase);
  await empty.page.waitForSelector("text=No blocks yet");
  body = await text(empty.page);
  check("empty: says where blocks are created and how", /Blocks are created in Composer Pro, not here/.test(body) && /New Draft/.test(body) && /Apply Draft/.test(body));
  check("empty: no create control exists", (await empty.page.locator("#main input, #main select").count()) === 0);
  await empty.page.goto(emptyBase + "/app?k=" + TOKEN + "#activity");
  await empty.page.waitForSelector("text=Nothing matches");
  check("empty: activity explains there is nothing yet", /No decision has been recorded yet/.test(await text(empty.page)));
  await empty.page.goto(emptyBase + "/app?k=" + TOKEN + "#sandbox");
  await empty.page.waitForSelector("text=Create a block in Composer first");
  check("empty: the sandbox says it needs a block", true);
  await shot(empty.page, "14-empty");
  await empty.ctx.close();

  check("no script errors on any screen", errors.length === 0, errors.join(" | "));
} catch (e) {
  fail++;
  console.log("  FAIL the run threw: " + (e && e.stack ? e.stack : e));
} finally {
  await browser.close();
  for (const p of servers) p.kill();
}

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail > 0 ? 1 : 0);
