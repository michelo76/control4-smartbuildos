// Browser verification of SmartBuildOS_AI_Core_Interactive_Guide.html.
//
// Opens the guide from file:// in Chromium and exercises every interactive
// control. Also compares the guide's transcribed permission engine with the
// REAL platform engine (smartbuildos-ai-core src/lib/ai-core/authz/engine.ts,
// imported read-only with Node's type stripping) across the whole matrix.
//
// Run:  node --experimental-strip-types docs/ai-core/guide/test/guide.browser.test.mjs
// Env:  AI_CORE_PLATFORM   platform worktree (default ../smartbuildos-ai-core beside this repo)
//       GUIDE_SCREENSHOTS  screenshot directory (default ai-core-program/screenshots/guide)
//       GUIDE_NO_SCREENSHOTS=1 to skip screenshots
//       GUIDE_STEP_TIMEOUT_MS  bound on each action, wait, evaluate and screenshot (default 20000)
//       GUIDE_RUN_TIMEOUT_MS   watchdog for the whole run (default 12 min); a timeout fails naming the step
// Playwright is used read-only from the platform worktree's node_modules.

import path from "node:path";
import fs from "node:fs";
import { fileURLToPath, pathToFileURL } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, "../../../..");
const codex = path.resolve(repo, "..");
const PLATFORM = process.env.AI_CORE_PLATFORM || path.join(codex, "smartbuildos-ai-core");
const SHOTS = process.env.GUIDE_SCREENSHOTS || path.join(codex, "ai-core-program/screenshots/guide");
const GUIDE = path.resolve(here, "../SmartBuildOS_AI_Core_Interactive_Guide.html");
const URL0 = pathToFileURL(GUIDE).href;

const { chromium } = await import(pathToFileURL(path.join(PLATFORM, "node_modules/playwright/index.mjs")).href);
const realEngine = await import(pathToFileURL(path.join(PLATFORM, "src/lib/ai-core/authz/engine.ts")).href);
// The real tool registry, built the way the platform builds it (ports are not called).
const T = (f) => pathToFileURL(path.join(PLATFORM, "src/lib/ai-core/tools", f)).href;
// A port whose every method exists (never called here), so each factory declares all of its tools.
const port = new Proxy({}, { get: (_t, k) => (k === "then" ? undefined : async () => ({})) });
// Built from the factories tools/index.ts exports (a tool removed there disappears here too).
const toolsIndex = await import(T("index.ts"));
const FACTORIES = { memory: "createMemoryTools", service: "createServiceTools", notifications: "createNotificationTools", actions: "createActionTools", concierge: "createConciergeTools" };
const build = (name) => (typeof toolsIndex[name] === "function" ? toolsIndex[name](port, {}) : []);
// createDriverTools takes one options object; with a port that has propose it declares all three driver tools.
const realTools = [...toolsIndex.READ_TOOLS, ...Object.values(FACTORIES).flatMap(build), ...(typeof toolsIndex.createDriverTools === "function" ? toolsIndex.createDriverTools({ port }) : [])];
const registryTools = realTools.map((t) => ({ id: t.id, wire: t.wireName, risk: t.risk, household: t.household, verb: t.verb, feature: t.feature, audience: t.audience }));
// The real offeredTools and registry builder, and the source of the per-persona composition.
const realTurn = await import(pathToFileURL(path.join(PLATFORM, "src/lib/ai-core/orchestrator/turn.ts")).href);
const { createRegistry } = toolsIndex;
const serverSrc = fs.readFileSync(path.join(PLATFORM, "src/lib/ai-core/orchestrator/server.ts"), "utf8");
const conciergeServerSrc = fs.readFileSync(path.join(PLATFORM, "src/lib/ai-core/concierge/server.ts"), "utf8");

// ── tiny harness ────────────────────────────────────────────────────────────
let assertions = 0;
const failures = [];
const controls = new Set();
const ok = (cond, msg) => { assertions++; if (!cond) failures.push(msg); };
const eq = (a, b, msg) => ok(Object.is(a, b) || JSON.stringify(a) === JSON.stringify(b), `${msg}: expected ${JSON.stringify(b)}, got ${JSON.stringify(a)}`);
const ctl = (id) => controls.add(id);
// Nothing in this test may wait unbounded: every Playwright action/wait has a default
// timeout, every page.evaluate is raced against one, and a watchdog ends the whole run.
// Each failure names the step it was in.
let step = "start";
const STEP_MS = Number(process.env.GUIDE_STEP_TIMEOUT_MS || 20000);
const RUN_MS = Number(process.env.GUIDE_RUN_TIMEOUT_MS || 12 * 60 * 1000);
const bounded = (promise, ms, what) => {
  let timer;
  const limit = new Promise((_r, reject) => { timer = setTimeout(() => reject(new Error(`TIMEOUT after ${ms} ms: ${what} (step: ${step})`)), ms); });
  return Promise.race([promise, limit]).finally(() => clearTimeout(timer));
};
// On abort, close the browser (bounded) before exiting so no Chromium is left orphaned.
let browser = null;
let aborting = false;
const abort = (code, msg) => {
  if (aborting) return; // the first cause wins; later rejections are its fallout
  aborting = true;
  console.error(msg);
  const done = () => process.exit(code);
  setTimeout(done, 5000).unref();
  Promise.resolve(browser && browser.close()).catch(() => {}).finally(done);
};
const watchdog = setTimeout(() => abort(2, `\nHUNG: the run exceeded ${RUN_MS} ms; last step: ${step}`), RUN_MS);
watchdog.unref();
process.on("unhandledRejection", (e) => abort(3, `\nFAILED in step “${step}”: ${e && e.stack || e}`));
process.on("uncaughtException", (e) => abort(3, `\nFAILED in step “${step}”: ${e && e.stack || e}`));
const section = (name) => { step = name; console.log(`· ${name}`); };
const shots = [];

browser = await chromium.launch();
const external = [];
const consoleProblems = [];
async function newPage(opts = {}) {
  const context = await browser.newContext({ viewport: opts.viewport || { width: 1280, height: 900 }, colorScheme: opts.colorScheme || "light", reducedMotion: opts.reducedMotion || "no-preference" });
  await context.grantPermissions(["clipboard-read", "clipboard-write"]).catch(() => {});
  await context.route("**/*", (route) => {
    const u = route.request().url();
    if (u.startsWith("file:") && u.split("#")[0] === URL0) return route.continue();
    external.push(u);
    return route.abort();
  });
  context.setDefaultTimeout(STEP_MS);
  context.setDefaultNavigationTimeout(STEP_MS);
  const page = await context.newPage();
  for (const k of ["evaluate", "$eval", "$$eval"]) { const f = page[k].bind(page); page[k] = (...a) => bounded(f(...a), STEP_MS, `page.${k}`); }
  page.on("console", (m) => { if (m.type() === "error" || m.type() === "warning") consoleProblems.push(`${m.type()}: ${m.text()}`); });
  page.on("pageerror", (e) => consoleProblems.push(`pageerror: ${e.message}`));
  page.on("dialog", (d) => d.accept());
  await page.goto(URL0 + (opts.hash || ""));
  await page.waitForFunction(() => window.AICoreGuide && window.AICoreGuide.ready);
  return { page, context };
}
// Hash navigation is asynchronous (hashchange): wait until the guide has routed.
const settle = async (page, hash) => { await page.waitForFunction((h) => location.hash === h, hash); await page.evaluate(() => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)))); };
const go = async (page, hash) => { step = step.split(" › ")[0] + " › go " + hash; await page.evaluate((h) => { location.hash = h; }, hash); await settle(page, hash); await page.waitForTimeout(20); };
// Decodes every image of the visible chapter without scrolling. The guide's images are
// loading="lazy": decode() on a lazy image below the fold waits for a load that never
// starts (that is what hung the refresh run at #ch10-overview), so each is switched to
// eager first and each decode is bounded. Returns one entry per image.
const decodeVisible = (page) => page.evaluate(async () => {
  const out = [];
  for (const i of document.querySelectorAll(".chapter:not([hidden]) img")) {
    i.loading = "eager";
    const r = await Promise.race([i.decode().then(() => "ok", () => "error"), new Promise((res) => setTimeout(() => res("timeout"), 5000))]);
    out.push({ r, ok: r === "ok" && i.complete && i.naturalWidth > 0, w: i.naturalWidth, attr: Number(i.getAttribute("width")) });
  }
  return out;
});
const visibleChapter = (page) => page.evaluate(() => [...document.querySelectorAll(".chapter")].find((c) => !c.hidden)?.id);
const shot = async (page, name, full = false) => {
  if (process.env.GUIDE_NO_SCREENSHOTS) return;
  fs.mkdirSync(SHOTS, { recursive: true });
  const file = path.join(SHOTS, name + ".png");
  step = step.split(" › ")[0] + " › screenshot " + name;
  await bounded(page.screenshot({ path: file, fullPage: full, timeout: STEP_MS }), STEP_MS + 2000, `screenshot ${name}`);
  shots.push(file);
};
const shotEl = async (page, sel, name) => {
  if (process.env.GUIDE_NO_SCREENSHOTS) return;
  fs.mkdirSync(SHOTS, { recursive: true });
  const file = path.join(SHOTS, name + ".png");
  step = step.split(" › ")[0] + " › element screenshot " + name;
  await page.locator(sel).first().scrollIntoViewIfNeeded();
  // Element captures stitch scrolled frames; keep the sticky header out of them.
  await page.addStyleTag({ content: ".topbar, .progress { position: static !important; }" }).catch(() => {});
  await page.locator(sel).first().screenshot({ path: file });
  await page.evaluate(() => { const s = [...document.querySelectorAll("style")].pop(); if (s && s.textContent.includes("position: static !important")) s.remove(); });
  shots.push(file);
};

const CHAPTERS = ["ch1", "ch2", "ch3", "ch4", "ch5", "ch6", "ch7", "ch8", "ch9", "ch10", "ch11", "ch12", "ch13", "ch14", "verification"];

// ═════════ 1. Navigation, deep links, chapter nav, overflow at three widths ═════════
section("navigation and deep links");
{
  const { page, context } = await newPage();
  for (const ch of CHAPTERS) {
    await page.click(`#chapterList a[data-ch="${ch}"]`);
    await settle(page, "#" + ch);
    ctl(`nav:${ch}`);
    eq(await visibleChapter(page), ch, `sidebar link ${ch} shows its chapter`);
    eq(await page.getAttribute(`#chapterList a[data-ch="${ch}"]`, "aria-current"), "page", `sidebar ${ch} aria-current`);
    // sub-navigation links
    const subs = await page.$$eval("#chapterList .subnav a", (as) => as.map((a) => a.getAttribute("href")));
    for (const h of subs) {
      await page.click(`#chapterList .subnav a[href="${h}"]`);
      await settle(page, h);
      ctl(`subnav:${h}`);
      const top = await page.evaluate((id) => document.getElementById(id).getBoundingClientRect().top, h.slice(1));
      ok(top >= 0 && top < 900, `subnav ${h} scrolls its heading into view (top ${top})`);
    }
    // previous/next chapter links
    const nextHref = await page.$eval(`#${ch} .chapter-nav a[rel="next"]`, (a) => a.getAttribute("href")).catch(() => null);
    if (nextHref) {
      await page.click(`#${ch} .chapter-nav a[rel="next"]`);
      await settle(page, nextHref);
      ctl(`chapter-next:${ch}`);
      eq(await visibleChapter(page), nextHref.slice(1), `next link from ${ch}`);
      await page.click(`#${nextHref.slice(1)} .chapter-nav a[rel="prev"]`);
      await settle(page, "#" + ch);
      ctl(`chapter-prev:${nextHref.slice(1)}`);
      eq(await visibleChapter(page), ch, `prev link back to ${ch}`);
    }
  }
  await page.click(".topbar .brand"); await settle(page, "#ch1"); ctl("nav:brand");
  eq(await visibleChapter(page), "ch1", "brand link opens chapter 1");
  await page.goto(URL0 + "#ch1"); await page.reload(); await page.waitForFunction(() => window.AICoreGuide && window.AICoreGuide.ready);
  await page.keyboard.press("Tab");
  eq(await page.evaluate(() => document.activeElement.className), "skip", "first Tab reaches the skip link");
  await page.keyboard.press("Enter"); await settle(page, "#main"); ctl("nav:skip");
  eq(await page.evaluate(() => document.activeElement.id), "main", "skip link moves focus to the content");
  // Every in-page link points at an existing id.
  const broken = await page.evaluate(() => [...document.querySelectorAll('a[href^="#"]')].map((a) => a.getAttribute("href")).filter((h) => h.length > 1 && !document.getElementById(decodeURIComponent(h.slice(1)))));
  eq(broken, [], "every in-page link has a target");
  // Deep links for every section id survive a reload.
  const ids = await page.evaluate(() => [...document.querySelectorAll(".chapter h2[id], .chapter section[id], .feature[id]")].map((e) => e.id));
  for (const id of ids) {
    await page.goto(URL0 + "#" + id);
    await page.reload();
    await page.waitForFunction(() => window.AICoreGuide && window.AICoreGuide.ready);
    await page.waitForTimeout(30);
    ctl(`deeplink:${id}`);
    const r = await page.evaluate((i) => { const el = document.getElementById(i); const ch = el.closest(".chapter"); const b = el.getBoundingClientRect(); return { visible: !ch.hidden, top: b.top }; }, id);
    ok(r.visible && r.top > -5 && r.top < 900, `deep link #${id} after reload (visible ${r.visible}, top ${Math.round(r.top)})`);
  }
  // Last chapter is remembered when there is no hash.
  await page.goto(URL0 + "#ch7");
  await page.goto(URL0);
  await page.waitForFunction(() => window.AICoreGuide && window.AICoreGuide.ready);
  eq(await visibleChapter(page), "ch7", "last chapter restored without a hash");
  // Progress indicators.
  const states = await page.$$eval("#chapterList .dot", (ds) => ds.map((d) => d.dataset.state || "none"));
  ok(states.every((s) => s === "visited" || s === "done"), "every opened chapter shows a progress state");
  await go(page, "#ch9");
  await page.evaluate(() => window.scrollTo(0, document.documentElement.scrollHeight));
  await page.waitForTimeout(80);
  eq(await page.$eval('#chapterList a[data-ch="ch9"] .dot', (d) => d.dataset.state), "done", "chapter read to the end is marked done");
  const pct = await page.$eval("#readProgress", (b) => Number(b.getAttribute("aria-valuenow")));
  ok(pct >= 97, `reading progress reaches the end (${pct})`);
  ctl("reading-progress");
  await context.close();
}

// ═════════ 2. Overflow at 360 / 768 / 1280, mobile drawer ═════════
section("responsive layout");
for (const width of [360, 768, 1280]) {
  const { page, context } = await newPage({ viewport: { width, height: 800 } });
  for (const ch of CHAPTERS) {
    await go(page, "#" + ch);
    await page.evaluate(() => document.querySelectorAll(".chapter:not([hidden]) details").forEach((d) => { d.open = true; }));
    const o = await page.evaluate(() => ({ sw: document.documentElement.scrollWidth, bw: document.body.scrollWidth, iw: window.innerWidth }));
    ok(o.sw <= o.iw && o.bw <= o.iw, `no horizontal overflow on ${ch} at ${width}px (scrollWidth ${o.sw}/${o.bw}, viewport ${o.iw})`);
  }
  if (width === 360) {
    eq(await page.isVisible("#menuBtn"), true, "menu button visible on mobile");
    await page.click("#menuBtn"); ctl("drawer:open");
    eq(await page.getAttribute("#menuBtn", "aria-expanded"), "true", "drawer opens");
    ok(await page.evaluate(() => document.body.classList.contains("nav-open")), "drawer class set");
    await page.keyboard.press("Escape"); ctl("drawer:escape");
    eq(await page.getAttribute("#menuBtn", "aria-expanded"), "false", "Escape closes the drawer");
    await page.click("#menuBtn");
    await page.click('#chapterList a[data-ch="ch3"]'); await settle(page, "#ch3"); ctl("drawer:link");
    eq(await visibleChapter(page), "ch3", "drawer link navigates");
    ok(!(await page.evaluate(() => document.body.classList.contains("nav-open"))), "drawer closes after navigating");
    await page.click("#menuBtn");
    await page.mouse.click(350, 400); ctl("drawer:scrim");
    ok(!(await page.evaluate(() => document.body.classList.contains("nav-open"))), "scrim click closes the drawer");
  } else {
    eq(await page.isVisible("#menuBtn"), width < 900, `menu button ${width < 900 ? "shown" : "hidden"} at ${width}px (drawer below 900px)`);
  }
  await context.close();
}

// ═════════ 3. Search ═════════
section("search");
{
  const { page, context } = await newPage();
  await page.fill("#searchInput", "AI_ASK"); ctl("search:hit");
  await page.waitForSelector("#searchResults:not([hidden]) li a");
  const n = await page.$$eval("#searchResults li a", (as) => as.length);
  ok(n >= 3, `search AI_ASK returns several sections (${n})`);
  ok(await page.$eval("#searchResults", (r) => r.querySelectorAll("mark").length > 0), "result snippets are highlighted");
  const href = await page.$eval("#searchResults li a", (a) => a.getAttribute("href"));
  await page.click("#searchResults li a"); ctl("search:jump");
  await page.waitForTimeout(150);
  const target = await page.evaluate((h) => { const el = document.getElementById(h.slice(1)); return { visible: !el.closest(".chapter").hidden, marks: document.querySelectorAll("mark[data-hit]").length }; }, href);
  ok(target.visible && target.marks > 0, `jump to ${href} highlights matches (${target.marks})`);
  // keyboard: Enter on the input opens the first result
  await page.fill("#searchInput", "deadline_exceeded");
  await page.waitForSelector("#searchResults:not([hidden]) li a");
  await page.focus("#searchInput"); await page.keyboard.press("ArrowDown"); ctl("search:arrow");
  ok(await page.evaluate(() => document.activeElement.closest("#searchResults") !== null), "ArrowDown moves into the results");
  await page.keyboard.press("Escape"); ctl("search:escape");
  ok(await page.$eval("#searchResults", (r) => r.hidden), "Escape closes the results");
  await page.fill("#searchInput", "zzqqxxyy"); ctl("search:nohit");
  await page.waitForSelector("#searchNone");
  ok((await page.textContent("#searchNone")).includes("No results"), "no-hit message shown");
  await page.click("#searchClear"); ctl("search:clear");
  eq(await page.inputValue("#searchInput"), "", "clear empties the input");
  ok(await page.$eval("#searchResults", (r) => r.hidden), "clear hides the results");
  eq(await page.evaluate(() => document.querySelectorAll("mark[data-hit]").length), 0, "clear removes highlights");
  // every chapter is searchable by its title
  for (const ch of CHAPTERS) {
    const title = await page.$eval("#" + ch, (c) => c.dataset.title);
    await page.fill("#searchInput", title);
    await page.waitForFunction((q) => document.querySelector("#searchResults").dataset.q === q && !document.querySelector("#searchResults").hidden, title);
    ok(await page.$$eval("#searchResults li a", (as, c) => as.some((a) => document.getElementById(a.getAttribute("href").slice(1))?.closest(".chapter")?.id === c), ch), `search finds chapter "${title}"`);
  }
  await context.close();
}

// ═════════ 4. Theme toggle, persistence, contrast, reduced motion ═════════
section("theme");
{
  const { page, context } = await newPage({ colorScheme: "dark" });
  const bg0 = await page.evaluate(() => getComputedStyle(document.body).backgroundColor);
  eq(await page.getAttribute("#themeBtn", "aria-label"), "Switch to light theme", "default follows the OS (dark)");
  await page.click("#themeBtn"); ctl("theme:toggle");
  eq(await page.evaluate(() => document.documentElement.dataset.theme), "light", "toggle switches to light");
  const bg1 = await page.evaluate(() => getComputedStyle(document.body).backgroundColor);
  ok(bg0 !== bg1, "background changes with the theme");
  await page.reload(); await page.waitForFunction(() => window.AICoreGuide && window.AICoreGuide.ready);
  eq(await page.evaluate(() => document.documentElement.dataset.theme), "light", "theme persists across reload");
  await page.click("#themeBtn");
  eq(await page.evaluate(() => document.documentElement.dataset.theme), "dark", "toggle back to dark");
  // contrast of text tokens in both themes
  for (const theme of ["light", "dark"]) {
    await page.evaluate((t) => { document.documentElement.dataset.theme = t; }, theme);
    await go(page, "#ch1");
    const pairs = await page.evaluate(() => {
      const lum = (c) => { const m = c.match(/\d+(\.\d+)?/g).map(Number); const f = (v) => { v /= 255; return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4; }; return 0.2126 * f(m[0]) + 0.7152 * f(m[1]) + 0.0722 * f(m[2]); };
      const ratio = (a, b) => { const x = lum(a), y = lum(b); return (Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05); };
      const root = getComputedStyle(document.documentElement);
      const v = (n) => { const d = document.createElement("div"); d.style.color = root.getPropertyValue(n); document.body.appendChild(d); const c = getComputedStyle(d).color; d.remove(); return c; };
      const out = {};
      for (const [fg, bg] of [["--sw-ink", "--sw-canvas"], ["--sw-ink-2", "--sw-surface"], ["--sw-muted", "--sw-surface"], ["--sw-muted", "--sw-canvas"], ["--sw-orange-ink", "--sw-surface"], ["--tone-sim-ink", "--tone-sim-bg"], ["--tone-dev-ink", "--tone-dev-bg"], ["--tone-block-ink", "--tone-block-bg"], ["--tone-ok-ink", "--tone-ok-bg"], ["--sw-red", "--sw-surface"], ["--sw-green", "--sw-surface"], ["--code-ink", "--code-bg"]]) out[fg + " on " + bg] = ratio(v(fg), v(bg));
      return out;
    });
    for (const [k, r] of Object.entries(pairs)) ok(r >= 4.5, `${theme} contrast ${k} = ${r.toFixed(2)} (≥ 4.5)`);
  }
  await context.close();
  const rm = await newPage({ reducedMotion: "reduce", viewport: { width: 360, height: 780 } });
  const d = await rm.page.$eval(".sidebar", (s) => parseFloat(getComputedStyle(s).transitionDuration));
  ok(d < 0.01, `reduced motion removes transitions (${d}s)`);
  ctl("reduced-motion");
  await rm.context.close();
}

// ═════════ 5. Expandables, copy buttons, glossary terms ═════════
section("expandables, copy, glossary");
{
  const { page, context } = await newPage();
  let details = 0, copies = 0, terms = 0;
  for (const ch of CHAPTERS) {
    await go(page, "#" + ch);
    const dCount = await page.locator(`#${ch} details:visible`).count();
    for (let i = 0; i < dCount; i++) {
      const d = page.locator(`#${ch} details:visible`).nth(i);
      const s = d.locator(":scope > summary");
      const before = await d.evaluate((e) => e.open);
      await s.click(); const mid = await d.evaluate((e) => e.open);
      await s.click(); const after = await d.evaluate((e) => e.open);
      ok(mid === !before && after === before, `${ch} details #${i} toggles`);
      ctl(`details:${ch}:${i}`); details++;
    }
    const cCount = await page.locator(`#${ch} pre.code .copy:visible`).count();
    for (let i = 0; i < cCount; i++) {
      const b = page.locator(`#${ch} pre.code .copy:visible`).nth(i);
      await b.scrollIntoViewIfNeeded();
      const code = await b.evaluate((x) => x.parentElement.querySelector("code").textContent);
      await b.click(); await page.waitForTimeout(60);
      const st = await b.getAttribute("data-state");
      ok(st === "ok" || st === "manual", `${ch} copy #${i} reports a result (${st})`);
      if (st === "ok") { const clip = await page.evaluate(() => navigator.clipboard.readText().catch(() => null)); ok(clip === null || clip === code, `${ch} copy #${i} copies the exact code`); }
      if (st === "manual") eq(await page.evaluate(() => String(window.getSelection())), code, `${ch} copy #${i} selects the code for manual copy`);
      ctl(`copy:${ch}:${i}`); copies++;
    }
    const tCount = await page.locator(`#${ch} .term:visible`).count();
    for (let i = 0; i < tCount; i++) {
      const t = page.locator(`#${ch} .term:visible`).nth(i);
      await t.scrollIntoViewIfNeeded();
      await t.hover();
      ok(await page.isVisible("#tip"), `${ch} term #${i} shows its definition on hover`);
      await page.mouse.move(2, 600);
      await t.focus();
      ok(await page.isVisible("#tip") && (await t.getAttribute("aria-describedby")) === "tip", `${ch} term #${i} shows on focus and is described`);
      await page.keyboard.press("Escape");
      ok(!(await page.isVisible("#tip")), `${ch} term #${i} hides on Escape`);
      await t.click(); ok(await page.isVisible("#tip"), `${ch} term #${i} pins on tap`); await t.click();
      ctl(`term:${ch}:${i}`); terms++;
    }
  }
  ok(details > 20, `details exercised: ${details}`);
  ok(copies > 20, `copy buttons exercised: ${copies}`);
  ok(terms >= 10, `glossary terms exercised: ${terms}`);
  await context.close();
}

// ═════════ 6. Installation wizard, every path ═════════
section("installation wizard");
{
  const { page, context } = await newPage({ hash: "#ch2-wizard" });
  const next = () => page.click("#wizNext");
  const err = () => page.textContent("#wizError");
  const step = () => page.$eval('#wizSteps li[aria-current="step"]', (l) => l.textContent);
  ctl("wizard:next"); ctl("wizard:back"); ctl("wizard:restart");
  await next(); ok((await err()).includes("as numbers"), "wizard: empty OS refused");
  await page.fill("#wzOs", "abc"); await next(); ok((await err()).includes("as numbers"), "wizard: malformed OS refused");
  await page.fill("#wzOs", "3.2.9"); await next(); ok((await err()).includes("below the driver"), "wizard: OS below 3.3.2 refused");
  await page.fill("#wzOs", "3.3.2"); await page.check('input[name="instances"][value="1"]'); await next(); ok((await err()).includes("singleton"), "wizard: second instance refused");
  await page.check('input[name="instances"][value="0"]'); await next(); ok((await step()).includes("Agent"), "wizard: OS 3.3.2 accepted");
  await page.check('input[name="agent"][value="no"]'); await next(); ok((await err()).includes("No SmartBuildOS Agent in this project"), "wizard: no Agent shows the real status text");
  await page.check('input[name="agent"][value="yes"]'); await page.check('input[name="proto"][value="1"]'); await next(); ok((await err()).includes("SmartBuildOS Agent update required (module contract v2)"), "wizard: protocol 1 shows update required");
  await page.check('input[name="proto"][value="2"]'); await page.check('input[name="paired"][value="no"]'); await next(); ok((await err()).includes("SmartBuildOS Agent not paired"), "wizard: unpaired shows not paired");
  await page.check('input[name="paired"][value="yes"]'); await next(); ok((await step()).includes("Flight Recorder"), "wizard: Agent step passes");
  for (const [v, text] of [["v1", "Installed (no local history service; update the Flight Recorder)"], ["none", "Not installed: AI Core collects its minimal set itself"], ["v2", "Installed: local history served; topics subscribed"]]) {
    await page.check(`input[name="fr"][value="${v}"]`); eq(await page.textContent("#wzFrText"), text, `wizard: Flight Recorder ${v} link text`); ctl(`wizard:fr:${v}`);
  }
  await page.click("#wizBack"); ok((await step()).includes("Agent"), "wizard: back returns to the Agent step");
  await next(); await next();
  ok((await step()).includes("System Studio"), "wizard: reaches System Studio step");
  await next(); ok((await err()).includes("20–512"), "wizard: empty key refused");
  await page.fill("#wzKey", "short"); await next(); ok((await err()).includes("20–512"), "wizard: short key refused");
  await page.fill("#wzKey", "sk-proj-AAAAAAAAAAAAAAAAAAAAAAAA"); await next(); ok((await err()).includes("looks like an OpenAI key"), "wizard: OpenAI-shaped key refused for Anthropic");
  await page.selectOption("#wzProvider", "openai"); await page.fill("#wzKey", "sk-ant-AAAAAAAAAAAAAAAAAAAAAAAA"); await next(); ok((await err()).includes("looks like an Anthropic key"), "wizard: Anthropic key refused for OpenAI");
  await page.fill("#wzKey", "has spaces in it which are not allowed"); await next(); ok((await err()).includes("no spaces"), "wizard: key with spaces refused");
  await page.selectOption("#wzProvider", "anthropic"); await page.click("#wzSample"); ctl("wizard:sample-key");
  await page.selectOption("#wzMode", "recommend"); await page.check("#wzLearning"); ctl("wizard:mode"); ctl("wizard:learning");
  await next(); ok((await step()).includes("Verify"), "wizard: sample key accepted");
  ok((await page.textContent("#wizBody")).includes("Configured in System Studio · Anthropic ••••abcd"), "wizard: credential status text uses the last four characters");
  await next(); ok((await err()).includes("Run both"), "wizard: tests required");
  await page.click("#wzTestAgent"); await next(); ok((await err()).includes("Run both"), "wizard: both tests required");
  await page.click("#wzTestAi"); ctl("wizard:test-agent"); ctl("wizard:test-ai");
  ok((await page.textContent("#wzTests")).includes("refused (cloud_refused)") && (await page.textContent("#wzTests")).includes("test accepted"), "wizard: AI test states the accepted answer and today's cloud_refused until deployment");
  await next(); ok((await step()).includes("Summary"), "wizard: summary reached");
  ok((await page.textContent("#wizBody")).includes("recommend"), "wizard: summary reflects choices");
  eq(await page.isDisabled("#wizNext"), true, "wizard: Next disabled on summary");
  await page.click("#wizRestart");
  ok((await step()).includes("Controller"), "wizard: restart returns to step 1");
  eq(await page.inputValue("#wzOs"), "", "wizard: restart clears inputs");
  await shotEl(page, "#wizard", "feature-wizard-light");
  await context.close();
}

// ═════════ 7. Architecture explorer ═════════
section("architecture explorer");
{
  const { page, context } = await newPage({ hash: "#ch1-architecture" });
  const ids = await page.evaluate(() => window.AICoreGuide.ARCH);
  for (const id of ids) {
    await page.locator(`#archSvgHost .node[data-id="${id}"]`).click();
    eq(await page.getAttribute("#archPanel h4", "data-node"), id, `arch node ${id} selected by click`);
    ok((await page.$$eval("#archPanel li", (l) => l.length)) > 0, `arch node ${id} lists responsibilities`);
    ok((await page.$$eval("#archPanel .arch-jump", (l) => l.length)) > 0, `arch node ${id} lists connections`);
    eq(await page.getAttribute(`#archSvgHost .node[data-id="${id}"]`, "aria-pressed"), "true", `arch node ${id} pressed state`);
    ctl(`arch:${id}`);
    await page.locator(`#archSvgHost .arch-chip[data-id="${id}"]`).click();
    eq(await page.getAttribute("#archPanel h4", "data-node"), id, `arch list button ${id}`);
    ctl(`arch-chip:${id}`);
  }
  await page.focus('#archSvgHost .node[data-id="orch"]'); await page.keyboard.press("Enter");
  eq(await page.getAttribute("#archPanel h4", "data-node"), "orch", "arch node selected by keyboard");
  const jump = await page.getAttribute("#archPanel .arch-jump", "data-id");
  await page.click("#archPanel .arch-jump"); ctl("arch:jump");
  eq(await page.getAttribute("#archPanel h4", "data-node"), jump, "arch connection jump");
  await shotEl(page, "#archExplorer", "feature-architecture-light");
  await context.close();
}

// ═════════ 8. Driver communication explorer ═════════
section("communication explorer");
{
  const { page, context } = await newPage({ hash: "#ch6-explorer" });
  const scenarios = await page.evaluate(() => window.AICoreGuide.COMM);
  for (const s of scenarios) {
    await page.selectOption("#commScenario", s.id);
    for (let i = 0; i < s.n; i++) await page.click("#commNext");
    ok((await page.textContent("#commPos")).includes(`Frame ${s.n} of ${s.n}`) && (await page.textContent("#commPos")).includes("end of scenario"), `scenario ${s.id} reaches its end`);
    eq(await page.isDisabled("#commNext"), true, `scenario ${s.id}: Next disabled at the end`);
    ok((await page.$$eval("#commSvgHost .msg.cur", (m) => m.length)) === 1, `scenario ${s.id}: current frame highlighted`);
    ok((await page.textContent("#commDetail pre code")).length > 2, `scenario ${s.id}: frame params shown`);
    await page.click("#commPrev");
    ok((await page.textContent("#commPos")).includes(`Frame ${s.n - 1} of`), `scenario ${s.id}: Previous steps back`);
    await page.click("#commReset");
    ok((await page.textContent("#commPos")).includes("Not started"), `scenario ${s.id}: Reset`);
    ctl(`comm:${s.id}`);
  }
  await page.selectOption("#commScenario", "discover");
  await page.click("#commPlay"); ctl("comm:play");
  await page.waitForFunction(() => document.querySelector("#commPos").textContent.includes("end of scenario"), null, { timeout: 6000 });
  eq(await page.getAttribute("#commPlay", "aria-pressed"), "false", "Play stops at the end");
  const errFrames = await page.evaluate(() => [...document.querySelectorAll("#commScenario option")].length);
  eq(errFrames, scenarios.length, "every scenario listed");
  await page.selectOption("#commScenario", "request");
  await page.click("#commNext"); await page.click("#commNext");
  await shotEl(page, "#commExplorer", "feature-communication-light");
  await context.close();
}

// ═════════ 9. AI workflow simulator ═════════
section("workflow simulator");
{
  const { page, context } = await newPage({ hash: "#ch8-workflow" });
  const expectAction = {
    kitchen: { observe: ["deny", "observe_mode_no_actions"], recommend: ["require_approval", "low_risk_needs_approval"], execute_low_risk: ["allow", "preapproved_rule_matched"] },
    unlock: { observe: ["deny", "observe_mode_no_actions"], recommend: ["require_approval", "high_risk_needs_homeowner"], execute_low_risk: ["require_approval", "high_risk_needs_homeowner"] },
  };
  for (const id of await page.evaluate(() => window.AICoreGuide.WF)) {
    for (const mode of ["observe", "recommend", "execute_low_risk"]) {
      await page.selectOption("#wfExample", id); await page.selectOption("#wfMode", mode);
      const total = await page.$$eval("#wfSteps > li", (l) => l.length);
      for (let i = 1; i < total; i++) await page.click("#wfNext");
      eq(await page.$$eval("#wfSteps > li.future", (l) => l.length), 0, `workflow ${id}/${mode}: Next reveals every step`);
      eq(await page.isDisabled("#wfNext"), true, `workflow ${id}/${mode}: Next disabled at the end`);
      const decisions = await page.$$eval("#wfSteps .decision", (d) => d.map((x) => x.dataset.d + " " + x.nextElementSibling.textContent));
      if (expectAction[id]) { const [d, r] = expectAction[id][mode]; ok(decisions.length > 0 && decisions[decisions.length - 1] === d + " " + r, `workflow ${id}/${mode}: action decision ${d} ${r} (got ${decisions[decisions.length - 1]})`); }
      if (id === "lights2am" || id === "offline") ok(decisions.every((x) => x.startsWith("allow read_allowed")), `workflow ${id}/${mode}: reads allowed in every mode`);
      if (id === "lights2am") { const verified = await page.$eval("#wfSteps > li:last-child", (l) => l.textContent); ok(!verified.includes("99999") && verified.includes("tr-88"), "workflow: evidence post-check dropped the uncited claim"); }
      if (id === "booking") {
        const texts = await page.$$eval("#wfSteps > li", (l) => l.map((x) => x.textContent));
        ok(texts.length >= 12 && texts.every((t) => t.includes("SIMULATION")), `workflow booking/${mode}: every step (${texts.length}) is labelled SIMULATION`);
        const states = await page.$$eval("#wfSteps [data-state]", (c) => c.map((x) => x.dataset.state));
        eq(states, ["suggested", "search_approved", "options_presented", "details_presented", "submitted", "simulated_confirmed"], `workflow booking/${mode}: suggest → approve search → options → select → final confirmation → simulated confirmation`);
        ok(!states.includes("confirmed"), `workflow booking/${mode}: never reaches confirmed`);
        const early = texts.find((t) => t.includes("before the homeowner’s final confirmation")) || "";
        if (mode === "observe") ok(early.includes("deny") && early.includes("observe_mode_no_actions") && !early.includes("not_confirmed"), "workflow booking/observe: the early submit is refused by the engine");
        else ok(early.includes("require_approval") && early.includes("external_needs_homeowner") && (await page.$$eval('#wfSteps [data-refusal="not_confirmed"]', (c) => c.length)) === 1, `workflow booking/${mode}: the early submit is refused not_confirmed`);
        ok(texts[texts.length - 1].includes("no table is reserved at a real restaurant"), `workflow booking/${mode}: the answer says nothing real was booked`);
      }
      await page.click("#wfPrev"); eq(await page.$$eval("#wfSteps > li.future", (l) => l.length), 1, `workflow ${id}/${mode}: Previous hides a step`);
      await page.click("#wfReset"); eq(await page.$$eval("#wfSteps > li:not(.future)", (l) => l.length), 1, `workflow ${id}/${mode}: Reset`);
      await page.click("#wfAll"); eq(await page.$$eval("#wfSteps > li.future", (l) => l.length), 0, `workflow ${id}/${mode}: Show all`);
      ctl(`workflow:${id}:${mode}`);
    }
  }
  // Tools offered per persona = the real offeredTools over the real per-persona registry.
  const body = (src, fn) => { const i = src.indexOf("export function " + fn); const j = src.indexOf("\n}\n", i); return src.slice(i, j); };
  const reg = body(serverSrc, "aiCoreRegistry");
  ok(reg.length > 100, "found aiCoreRegistry in orchestrator/server.ts");
  const fams = { read: /\.\.\.READ_TOOLS/.test(reg), memory_search: /createMemoryTools\(/.test(reg), memory_propose: /\.\.\.\(actions \? \{ propose:/.test(reg), service: /createServiceTools\(/.test(reg), notifications: /createNotificationTools\(/.test(reg), actions: /\.\.\.\(actions \? createActionTools\(/.test(reg), drivers_read: /\.\.\.createDriverTools\(/.test(reg), drivers_propose: /createDriverTools\(\{\s*port: driverToolPort\(admin, Boolean\(actions\)\)/.test(reg) };
  const homeownerAddsConcierge = /createRegistry\(\[\.\.\.aiCoreRegistry\(db, [^\n]*conversationId \}\)\.tools, \.\.\.tools\]\)/.test(conciergeServerSrc) && /createConciergeTools\(/.test(body(conciergeServerSrc, "portalConversationDeps"));
  const person = Object.keys(fams).filter((k) => fams[k]);
  const controllerFams = person.filter((k) => k !== "memory_propose" && k !== "actions" && k !== "drivers_propose");
  const G = await page.evaluate(() => ({ P: window.AICoreGuide.PERSONA_REGISTRY, CTX: window.AICoreGuide.WF_CTX }));
  eq(G.P.staff.slice().sort(), person.slice().sort(), "simulator: staff registry families = orchestrator/server.ts aiCoreRegistry (person's conversation)");
  eq(G.P.homeowner.slice().sort(), [...person, ...(homeownerAddsConcierge ? ["concierge"] : [])].sort(), "simulator: homeowner registry = aiCoreRegistry + concierge (concierge/server.ts portalConversationDeps)");
  eq(G.P.controller.slice().sort(), controllerFams.slice().sort(), "simulator: controller registry = aiCoreRegistry without a conversation (no propose, no actions)");
  const famOf = (id) => id === "memory.search" ? "memory_search" : id === "memory.propose" ? "memory_propose" : id === "drivers.propose_action" ? "drivers_propose" : id.startsWith("drivers.") ? "drivers_read" : ["flight_recorder", "devices", "rooms", "usage", "health"].includes(id.split(".")[0]) ? "read" : id.split(".")[0];
  let offeredCompared = 0;
  for (const ex of G.CTX) for (const mode of ["observe", "recommend", "execute_low_risk"]) {
    const famList = G.P[ex.actor];
    const registry = createRegistry(realTools.filter((t) => famList.includes(famOf(t.id))));
    const actor = ex.actor === "staff" ? { kind: "staff", userId: "u", grants: { monitoringView: true, homecontrolView: !!ex.grants.hv, homecontrolManage: !!ex.grants.hm } } : ex.actor === "homeowner" ? { kind: "homeowner", userId: "h", clientId: "c", propertyIds: ["p1"] } : { kind: "controller", controllerId: "c1", jobId: "j1" };
    const learningOn = !!(ex.learning && ex.learning.on), paused = !!(ex.learning && ex.learning.paused);
    const want = realTurn.offeredTools(registry, { actor, propertyId: "p1", permissionMode: mode, entitlementFeatures: ex.features, controllerCapabilities: ex.caps, gate: { wouldDeny: false }, householdConsent: learningOn && !paused, learningPaused: paused, now: new Date("2026-11-18T12:00:00Z") }).map((t) => t.wireName);
    const got = await page.evaluate(({ id, mode }) => window.AICoreGuide.offeredFor(id, mode), { id: ex.id, mode });
    eq(got, want, `simulator ${ex.id}/${mode}: tools offered = real offeredTools`);
    offeredCompared++;
    // and the page shows exactly that list
    await page.selectOption("#wfExample", ex.id); await page.selectOption("#wfMode", mode); await page.click("#wfAll");
    eq((await page.getAttribute("#wfSteps [data-offered]", "data-offered")).split(" ").filter(Boolean), want, `simulator ${ex.id}/${mode}: the Tools offered step lists them`);
    if (ex.actor === "homeowner") ok(!want.some((w) => w.startsWith("actions_") && mode === "observe"), `simulator ${ex.id}/observe: no action tool offered to a homeowner in observe`);
    if (ex.actor === "controller") ok(want.every((w) => registryTools.find((t) => t.wire === w).risk === "read"), `simulator ${ex.id}/${mode}: a controller job is offered read tools only`);
    if (ex.actor !== "homeowner") ok(!want.some((w) => w.startsWith("concierge_")), `simulator ${ex.id}/${mode}: concierge tools only for a homeowner`);
    // Least privilege: a staff-only tool is never offered to a homeowner or a controller, in the page or by the real engine.
    const staffOnly = registryTools.filter((t) => t.audience === "staff").map((t) => t.wire);
    ok(staffOnly.length > 0, "the real registry declares staff-only tools (the check is not passing against nothing)");
    if (ex.actor !== "staff") ok(!want.some((w) => staffOnly.includes(w)) && !got.some((w) => staffOnly.includes(w)), `simulator ${ex.id}/${mode}: no staff-only tool offered to a ${ex.actor}`);
    if (ex.actor === "staff" && ex.features.includes("BASE")) ok(staffOnly.every((w) => want.includes(w)), `simulator ${ex.id}/${mode}: staff are offered every staff-only tool`);
  }
  console.log(`  persona tool lists compared: ${offeredCompared}`);
  ctl("workflow:offered");
  await page.selectOption("#wfExample", "booking"); await page.selectOption("#wfMode", "recommend"); await page.click("#wfAll");
  await shotEl(page, "#workflow", "feature-workflow-persona-homeowner-light");
  await page.selectOption("#wfExample", "offline"); await page.selectOption("#wfMode", "recommend"); await page.click("#wfAll");
  await shotEl(page, "#workflow", "feature-workflow-persona-technician-light");
  await page.selectOption("#wfExample", "lights2am"); await page.selectOption("#wfMode", "recommend"); await page.click("#wfAll");
  await shotEl(page, "#workflow", "feature-workflow-persona-controller-light");
  await context.close();
}

// ═════════ 10. Telemetry explorer ═════════
section("telemetry explorer");
{
  const { page, context } = await newPage({ hash: "#ch5-telemetry" });
  const all = await page.$$eval("#teleList button", (b) => b.length);
  ok(all >= 12, `telemetry sample has events (${all})`);
  for (const sel of ["#teleType", "#teleSev", "#teleEv"]) {
    const opts = await page.$$eval(`${sel} option`, (o) => o.map((x) => x.value).filter(Boolean));
    for (const v of opts) {
      await page.selectOption(sel, v);
      const rows = await page.$$eval("#teleList button", (b) => b.map((x) => x.textContent));
      const count = await page.textContent("#teleCount");
      ok(count.startsWith(rows.length + " of "), `telemetry ${sel}=${v}: count matches list (${count})`);
      if (sel === "#teleType") ok(rows.every((t) => t.startsWith(v)), `telemetry prefix ${v} filters by event type`);
      if (sel === "#teleSev") ok(rows.every((t) => t.includes(v)), `telemetry severity ${v}`);
      ctl(`telemetry:${sel}:${v}`);
    }
    await page.selectOption(sel, "");
  }
  await page.fill("#teleText", "Dimmer"); ctl("telemetry:text");
  ok((await page.$$eval("#teleList button", (b) => b.length)) >= 1, "telemetry text filter finds the dimmer");
  await page.fill("#teleText", "no-such-event-text");
  ok((await page.textContent("#teleList")).includes("No sample events match"), "telemetry no-match message");
  await page.click("#teleReset"); ctl("telemetry:reset");
  eq(await page.$$eval("#teleList button", (b) => b.length), all, "telemetry reset restores all events");
  for (let i = 0; i < all; i++) {
    await page.locator("#teleList button").nth(i).click();
    const fields = await page.$$eval("#teleDetail dt", (d) => d.map((x) => x.textContent));
    for (const f of ["event_id", "schema_version", "event_type", "module_id", "observed_at", "severity", "evidence_source", "quality", "payload"]) ok(fields.includes(f), `telemetry event ${i} shows ${f}`);
    ok(await page.$$eval("#teleDetail dd small", (s) => s.every((x) => x.textContent.trim().length > 0)), `telemetry event ${i}: every field explained`);
    ctl(`telemetry:event:${i}`);
  }
  await shotEl(page, "#telemetry", "feature-telemetry-light");
  await context.close();
}

// ═════════ 11. Confidence, examples, reference ═════════
section("confidence, examples, reference");
{
  const { page, context } = await newPage({ hash: "#ch7-confidence" });
  ok((await page.textContent("#confOut")).includes("0.565") && (await page.textContent("#confOut")).includes("medium"), "confidence 24/10/0.8 = 0.565 medium");
  await page.fill("#confN", "5"); ok((await page.textContent("#confOut")).includes("No finding"), "confidence below threshold");
  await page.fill("#confN", "40"); ok((await page.textContent("#confOut")).includes("high"), "confidence band high at 4T");
  await page.fill("#confC", "2"); ok((await page.textContent("#confOut")).includes("between 0 and 1"), "confidence invalid input");
  await page.fill("#confC", "0.8"); await page.fill("#confT", "10"); ctl("confidence:n"); ctl("confidence:t"); ctl("confidence:c");
  await go(page, "#ch11-examples");
  const total = await page.evaluate(() => window.AICoreGuide.EXAMPLES);
  ok((await page.textContent("#exCount")).startsWith(`${total} of ${total}`), "examples: all shown");
  await page.fill("#exSearch", "Agent Disconnected"); ctl("examples:search");
  const shown = await page.$$eval("#exList .ex:not([hidden])", (e) => e.length);
  ok(shown >= 1 && shown < total, `examples search narrows (${shown})`);
  await page.fill("#exSearch", "nothing-like-this"); ok((await page.textContent("#exCount")).includes("no example matches"), "examples no-match");
  await page.fill("#exSearch", "");
  const cats = await page.$$eval("#exCats .chip", (c) => c.map((x) => x.dataset.c));
  for (const c of cats) { await page.click(`#exCats .chip[data-c="${c}"]`); ok(await page.$$eval(`#exList .ex[data-cat="${c}"]`, (e) => e.every((x) => x.hidden)), `examples category ${c} toggles off`); ctl(`examples:cat:${c}`); }
  ok((await page.textContent("#exCount")).startsWith("0 of"), "examples: all categories off shows none");
  for (const c of cats) await page.click(`#exCats .chip[data-c="${c}"]`);
  await shotEl(page, "#examples", "feature-examples-light");
  // Command reference
  await go(page, "#ch11-reference");
  const rows = await page.$$eval("#refTable tbody tr[data-i]", (r) => r.length);
  eq(rows, 69, "reference lists 11 commands + 5 actions + 27 properties + 10 events + 11 variables + 5 conditionals");
  const types = await page.$$eval("#refTypes .chip", (c) => c.map((x) => x.dataset.t));
  for (const t of types) {
    await page.click(`#refTypes .chip[data-t="${t}"]`);
    ok(await page.$$eval(`#refTable tbody tr[data-type="${t}"]`, (r) => r.every((x) => x.hidden)), `reference type ${t} hides`);
    await page.click(`#refTypes .chip[data-t="${t}"]`);
    ok(await page.$$eval(`#refTable tbody tr[data-type="${t}"]`, (r) => r.every((x) => !x.hidden)), `reference type ${t} shows`);
    ctl(`reference:type:${t}`);
  }
  await page.fill("#refSearch", "4005"); ctl("reference:search");
  ok(await page.$$eval("#refTable tbody tr[data-i]:not([hidden])", (r) => r.some((x) => x.textContent.includes("AI_PENDING_APPROVALS"))), "reference search by variable id");
  await page.fill("#refSearch", "zzqq"); ok((await page.textContent("#refCount")).includes("nothing matches"), "reference no-match");
  await page.fill("#refSearch", "");
  for (let i = 0; i < rows; i++) {
    const b = page.locator("#refTable .rowbtn").nth(i);
    await b.click(); eq(await b.getAttribute("aria-expanded"), "true", `reference row ${i} expands`);
    ok(!(await page.$eval(`#refd-${i}`, (d) => d.hidden)), `reference row ${i} detail visible`);
    await b.click(); ok(await page.$eval(`#refd-${i}`, (d) => d.hidden), `reference row ${i} collapses`);
    ctl(`reference:row:${i}`);
  }
  await shotEl(page, "#reference", "feature-reference-light");
  await context.close();
}

// ═════════ 12. Troubleshooting assistant: every tree to every leaf ═════════
section("troubleshooting assistant");
{
  const { page, context } = await newPage({ hash: "#ch13" });
  const trees = await page.evaluate(() => window.AICoreGuide.TS);
  let leaves = 0;
  for (const t of trees) {
    const paths = [];
    const walk = (id, p) => { const n = t.nodes[id]; if (n.leaf) { paths.push(p); return; } n.opts.forEach((nx, i) => walk(nx, [...p, i])); };
    walk(Object.keys(t.nodes)[0], []);
    for (const p of paths) {
      await page.click(`#tsTopics button[data-t="${t.id}"]`);
      for (const i of p) await page.locator("#tsNode .opts button").nth(i).click();
      const leaf = await page.$("#tsNode .leaf");
      ok(!!leaf, `troubleshooting ${t.id} path ${p.join(".")} ends on a result`);
      if (leaf) ok((await page.$$eval("#tsNode .leaf li", (l) => l.length)) >= 2, `troubleshooting ${t.id} leaf names what to check and do`);
      if (p.length) { await page.click("#tsBack"); ok(!(await page.$("#tsNode .leaf")), `troubleshooting ${t.id}: Back leaves the result`); }
      await page.click("#tsRestart"); ok(!!(await page.$("#tsNode .opts")), `troubleshooting ${t.id}: Restart`);
      leaves++; ctl(`ts:${t.id}:${p.join(".")}`);
    }
  }
  ok(leaves >= 40, `troubleshooting leaves reached: ${leaves}`);
  await page.click('#tsTopics button[data-t="agent"]'); await page.locator("#tsNode .opts button").nth(3).click();
  await shotEl(page, "#troubleshoot", "feature-troubleshooting-light");
  await context.close();
}

// ═════════ 12b. Phone layouts of the two diagrams; embedded images ═════════
section("diagram phone layouts and images");
for (const scheme of ["light", "dark"]) {
  const { page, context } = await newPage({ viewport: { width: 360, height: 780 }, colorScheme: scheme, hash: "#ch6-explorer" });
  eq(await page.$eval("#commSvgHost .seq-svg", (e) => getComputedStyle(e).display), "none", `360px ${scheme}: the sequence SVG is replaced`);
  for (const s of await page.evaluate(() => window.AICoreGuide.COMM)) {
    await page.selectOption("#commScenario", s.id);
    for (let i = 0; i < s.n; i++) await page.click("#commNext");
    const r = await page.evaluate(() => {
      const list = document.querySelector("#commSvgHost .seq-list");
      const items = [...list.querySelectorAll("li")];
      const fonts = [...list.querySelectorAll(".hop, .frame")].map((e) => parseFloat(getComputedStyle(e).fontSize));
      const clipped = [...list.querySelectorAll("li, .hop, .frame")].filter((e) => e.scrollWidth > e.clientWidth + 1 || e.getBoundingClientRect().right > window.innerWidth).length;
      return { visible: getComputedStyle(list).display !== "none" && list.getBoundingClientRect().height > 0, n: items.length, minFont: Math.min(...fonts), clipped, cur: items.filter((li) => li.classList.contains("cur")).length, names: items.every((li) => li.querySelector(".frame").textContent.length > 0 && /→|local/.test(li.querySelector(".hop").textContent)) };
    });
    ok(r.visible && r.n === s.n, `360px ${scheme} ${s.id}: vertical step list shows all ${s.n} frames (${r.n})`);
    ok(r.minFont >= 12, `360px ${scheme} ${s.id}: step-list text at least 12 px (min ${r.minFont})`);
    eq(r.clipped, 0, `360px ${scheme} ${s.id}: no clipped step-list text`);
    eq(r.cur, 1, `360px ${scheme} ${s.id}: the current frame is marked`);
    ok(r.names, `360px ${scheme} ${s.id}: every step shows from → to and the frame name`);
    ctl(`comm-mobile:${s.id}`);
  }
  await page.selectOption("#commScenario", "cloud"); await page.click("#commNext"); await page.click("#commNext"); await page.click("#commNext");
  await shotEl(page, "#commExplorer", `mobile-feature-communication-steps-${scheme}`);
  await go(page, "#ch1-architecture");
  eq(await page.$eval("#archSvgHost .arch-svg", (e) => getComputedStyle(e).display), "none", `360px ${scheme}: the architecture SVG is replaced`);
  const a = await page.evaluate(() => {
    const list = document.querySelector("#archSvgHost .arch-list");
    const fonts = [...list.querySelectorAll("h4, .lbl, .sub")].map((e) => parseFloat(getComputedStyle(e).fontSize));
    const clipped = [...list.querySelectorAll(".arch-chip, .lbl, .sub")].filter((e) => e.scrollWidth > e.clientWidth + 1 || e.getBoundingClientRect().right > window.innerWidth).length;
    return { layers: list.querySelectorAll(".arch-layer").length, chips: list.querySelectorAll(".arch-chip").length, subsShown: [...list.querySelectorAll(".sub")].every((e) => getComputedStyle(e).display !== "none"), minFont: Math.min(...fonts), clipped };
  });
  eq(a.layers, 3, `360px ${scheme}: architecture shown as three stacked layers`);
  eq(a.chips, (await page.evaluate(() => window.AICoreGuide.ARCH)).length, `360px ${scheme}: every component listed`);
  ok(a.subsShown && a.minFont >= 12, `360px ${scheme}: architecture list text at least 12 px with sub-labels (min ${a.minFont})`);
  eq(a.clipped, 0, `360px ${scheme}: no clipped architecture text`);
  await page.locator('#archSvgHost .arch-chip[data-id="authz"]').click();
  eq(await page.getAttribute("#archPanel h4", "data-node"), "authz", `360px ${scheme}: a layer button selects its component`);
  ctl(`arch-mobile:${scheme}`);
  await shotEl(page, "#archExplorer", `mobile-feature-architecture-layers-${scheme}`);
  await context.close();
}
{
  // Desktop keeps the diagrams.
  const { page, context } = await newPage({ hash: "#ch6-explorer" });
  ok(await page.$eval("#commSvgHost .seq-svg", (e) => getComputedStyle(e).display !== "none") && await page.$eval("#commSvgHost .seq-list", (e) => getComputedStyle(e).display === "none"), "1280px: the sequence diagram is shown, the step list hidden");
  await go(page, "#ch1-architecture");
  ok(await page.$eval("#archSvgHost .arch-svg", (e) => getComputedStyle(e).display !== "none"), "1280px: the architecture diagram is shown");
  // Embedded screenshots: data: URIs only, every one decodes, every caption says what it is.
  const imgs = await page.evaluate(() => [...document.querySelectorAll("img")].map((i) => ({ src: i.getAttribute("src").slice(0, 23), cap: (i.closest("figure")?.querySelector("figcaption")?.textContent) || "", alt: i.alt })));
  ok(imgs.length >= 8, `guide embeds screenshots (${imgs.length})`);
  for (const im of imgs) {
    ok(im.src.startsWith("data:image/webp;base64,"), `image is a data: URI (${im.src})`);
    ok(/fixture/i.test(im.cap) && /sample data/i.test(im.cap), `caption says fixture and sample data: “${im.cap.slice(0, 60)}”`);
    ok(im.alt.length > 20, "image has a descriptive alt text");
  }
  for (const ch of CHAPTERS) {
    await go(page, "#" + ch);
    const res = await decodeVisible(page);
    for (const r of res) { ok(r.ok, `${ch}: embedded image decodes (${r.r})`); eq(r.w, r.attr, `${ch}: image width attribute is its real width`); }
    ctl(`images:${ch}`);
  }
  const size = fs.statSync(GUIDE).size;
  ok(size < 3 * 1024 * 1024, `guide file under 3 MB (${size} bytes)`);
  await context.close();
}

// ═════════ 13. Permissions explorer vs the real engine ═════════
section("permissions explorer");
const OPS_INFO = { };
{
  const { page, context } = await newPage({ hash: "#ch12-permissions" });
  const G = await page.evaluate(() => ({ OPS: window.AICoreGuide.OPS, DEVICE_TYPES: window.AICoreGuide.DEVICE_TYPES, FEATURES: window.AICoreGuide.FEATURES, CAPS: window.AICoreGuide.CAPS, SAMPLE_TARGET: window.AICoreGuide.SAMPLE_TARGET }));
  // The test builds the engine input itself from the live registry (independent of the page's builder).
  eq(G.OPS.filter((o) => !o.key.startsWith("class:")).map((o) => o.key).sort(), registryTools.map((t) => t.wire).sort(), "explorer operations = the real tool registry");
  const toolFor = (key) => {
    if (key === "class:external") return { id: "class.external", risk: "external", household: false };
    if (key === "class:programming") return { id: "class.programming", risk: "programming", household: false };
    if (key === "class:credential") return { id: "class.credential", risk: "credential", household: false };
    const t = registryTools.find((x) => x.wire === key);
    return { id: t.id, risk: t.risk, household: t.household, ...(t.verb ? { verb: t.verb } : {}), ...(t.feature ? { feature: t.feature } : {}), ...(t.audience ? { audience: t.audience } : {}) };
  };
  const values = { SET_LIGHT: { level: 30 }, SET_THERMOSTAT: { setpoint_f: 70 }, ACTIVATE_SCENE: {}, LOCK_DEVICE: { state: "unlocked" }, GARAGE_DEVICE: { state: "open" }, SECURITY_PARTITION: { state: "disarm" } };
  const now = new Date("2026-11-18T12:00:00Z");
  const expected = (st) => {
    const tool = toolFor(st.op);
    const actor = st.actor === "staff" ? { kind: "staff", userId: "u", grants: { monitoringView: st.mv, homecontrolView: st.hv, homecontrolManage: st.hm } } : st.actor === "homeowner" ? { kind: "homeowner", userId: "h", clientId: "c", propertyIds: st.own ? ["p1"] : ["p2"] } : { kind: "automation", jobId: "j", householdConsent: st.consent };
    let target = null;
    if (tool.verb) target = { deviceId: 214, roomName: "Living Room", deviceType: st.target, values: { ...values[tool.verb] } };
    else if (st.op === "notifications_send") target = { deviceId: null, roomName: null, deviceType: null, values: { audience: "homeowner" } };
    const rules = [];
    if (st.rule && tool.verb) { const bounds = {}, allowedValues = {}; for (const [k, v] of Object.entries(target.values)) { if (typeof v === "number") bounds[k] = { min: v, max: v }; else allowedValues[k] = [v]; } rules.push({ id: "r", verb: tool.verb, deviceIds: [214], bounds, allowedValues, expiresAt: "2027-01-01T00:00:00Z", window: null }); }
    return realEngine.authorizeToolCall({ actor, permissionMode: st.mode, tool, target, propertyId: "p1", controllerCapabilities: st.caps, entitlementFeatures: st.features, preapprovedRules: rules, learning: { basis: st.basis, paused: st.paused }, gate: { wouldDeny: st.gate }, now });
  };
  // (a) Full matrix, computed in the page by the guide's engine, compared with the real engine.
  const actors = [];
  for (const mv of [true, false]) for (const hv of [true, false]) for (const hm of [true, false]) actors.push({ actor: "staff", mv, hv, hm, own: true, consent: true });
  for (const own of [true, false]) actors.push({ actor: "homeowner", mv: true, hv: true, hm: true, own, consent: true });
  for (const consent of [true, false]) actors.push({ actor: "automation", mv: true, hv: true, hm: true, own: true, consent });
  const D = {
    featureSets: [G.FEATURES, [], ...G.FEATURES.map((f) => G.FEATURES.filter((x) => x !== f))],
    capSets: [[], ["comfort_v1"], ["control_v1"], ["comfort_v1", "control_v1"]],
    bases: ["explicit_request", "recommendation", "preapproved_rule", "learned_pattern"],
    ops: G.OPS, types: G.DEVICE_TYPES,
  };
  // The same nested loops run in the page (guide engine) and here (real engine), one actor × mode per chunk.
  const loop = (D, a, mode, fn) => { for (const op of D.ops) for (const target of op.kind === "device" ? D.types : [""]) for (const basis of D.bases) for (const features of D.featureSets) for (const caps of D.capSets) for (const rule of [false, true]) for (const paused of [false, true]) for (const gate of [false, true]) fn({ ...a, mode, op: op.key, target, basis, features, caps, rule, paused, gate }); };
  let mismatches = 0, compared = 0;
  const firstMismatch = [];
  for (const a of actors) for (const mode of ["observe", "recommend", "execute_low_risk"]) {
    const got = await page.evaluate(({ D, a, mode }) => {
      const out = [];
      for (const op of D.ops) for (const target of op.kind === "device" ? D.types : [""]) for (const basis of D.bases) for (const features of D.featureSets) for (const caps of D.capSets) for (const rule of [false, true]) for (const paused of [false, true]) for (const gate of [false, true]) {
        const r = window.AICoreGuide.decide({ ...a, mode, op: op.key, target, basis, features, caps, rule, paused, gate });
        out.push(r.decision + "|" + r.reason + "|" + (r.approver || "") + "|" + (r.effectiveRisk || ""));
      }
      return out.join("\n");
    }, { D, a, mode });
    const gotRows = got.split("\n");
    let j = 0;
    loop(D, a, mode, (s) => { const r = expected(s); const want = r.decision + "|" + r.reason + "|" + (r.approver || "") + "|" + (r.effectiveRisk || ""); compared++; if (want !== gotRows[j]) { mismatches++; if (firstMismatch.length < 5) firstMismatch.push({ s, want, got: gotRows[j] }); } j++; });
    eq(j, gotRows.length, `permissions matrix chunk ${a.actor}/${mode} sizes agree`);
  }
  assertions += compared - 1;
  ok(mismatches === 0, `permissions matrix: ${compared} combinations, ${mismatches} differ from the real engine ${JSON.stringify(firstMismatch)}`);
  console.log(`  permissions matrix compared: ${compared}`);
  // (b) The UI shows the engine's answer: every operation × mode × actor through the real controls.
  const setUi = async (st) => {
    await page.selectOption("#pmActor", st.actor);
    for (const [id, v] of [["#pmMonView", st.mv], ["#pmHcView", st.hv], ["#pmHcManage", st.hm], ["#pmOwnProperty", st.own], ["#pmConsent", st.consent], ["#pmRule", st.rule], ["#pmPaused", st.paused], ["#pmGate", st.gate]]) { if (await page.isVisible(id)) await page.setChecked(id, v); else await page.$eval(id, (e, val) => { e.checked = val; e.dispatchEvent(new Event("change", { bubbles: true })); }, v); }
    await page.selectOption("#pmMode", st.mode);
    await page.selectOption("#pmTool", st.op);
    if (G.OPS.find((o) => o.key === st.op).kind === "device") await page.selectOption("#pmTarget", st.target);
    await page.selectOption("#pmBasis", st.basis);
    for (const f of G.FEATURES) { const on = (await page.getAttribute(`#pmFeatures .chip[data-v="${f}"]`, "aria-pressed")) === "true"; if (on !== st.features.includes(f)) await page.click(`#pmFeatures .chip[data-v="${f}"]`); }
    for (const c of G.CAPS) { const on = (await page.getAttribute(`#pmCaps .chip[data-v="${c}"]`, "aria-pressed")) === "true"; if (on !== st.caps.includes(c)) await page.click(`#pmCaps .chip[data-v="${c}"]`); }
  };
  const uiActors = [{ actor: "staff", mv: true, hv: true, hm: true, own: true, consent: true }, { actor: "staff", mv: true, hv: true, hm: false, own: true, consent: true }, { actor: "homeowner", mv: true, hv: true, hm: true, own: true, consent: true }, { actor: "automation", mv: true, hv: true, hm: true, own: true, consent: true }];
  let uiChecks = 0;
  for (const a of uiActors) for (const op of G.OPS) for (const mode of ["observe", "recommend", "execute_low_risk"]) {
    const st = { ...a, mode, op: op.key, target: op.kind === "device" ? G.SAMPLE_TARGET[op.verb].type : "", basis: a.actor === "automation" ? "learned_pattern" : "explicit_request", features: G.FEATURES, caps: ["comfort_v1", "control_v1"], rule: mode === "execute_low_risk", paused: false, gate: false };
    await setUi(st);
    const shownD = await page.getAttribute("#pmVerdict .big", "data-decision");
    const shownR = await page.getAttribute("#pmVerdict code[data-reason]", "data-reason");
    const r = expected(st);
    ok(shownD === r.decision && shownR === r.reason, `permissions UI ${a.actor}/${op.key}/${mode}: shows ${shownD} ${shownR}, engine says ${r.decision} ${r.reason}`);
    uiChecks++;
  }
  // protected classes through the UI
  for (const t of ["door_lock", "garage_door", "security_partition", "intercom"]) {
    const st = { actor: "homeowner", mv: true, hv: true, hm: true, own: true, consent: true, mode: "execute_low_risk", op: "actions_set_light", target: t, basis: "explicit_request", features: G.FEATURES, caps: ["comfort_v1", "control_v1"], rule: true, paused: false, gate: false };
    await setUi(st);
    eq(await page.getAttribute("#pmVerdict .big", "data-decision"), "require_approval", `protected class ${t}: a light verb on it escalates to homeowner approval`);
    uiChecks++;
  }
  ctl("permissions:actor"); ctl("permissions:mode"); ctl("permissions:tool"); ctl("permissions:target"); ctl("permissions:basis"); ctl("permissions:features"); ctl("permissions:caps"); ctl("permissions:rule"); ctl("permissions:paused"); ctl("permissions:gate"); ctl("permissions:grants"); ctl("permissions:own"); ctl("permissions:consent");
  console.log(`  permissions UI checks: ${uiChecks}`);
  await page.click("#pmMatrixWrap > summary"); ctl("permissions:matrix");
  eq(await page.$$eval("#pmMatrix tbody td[data-d]", (c) => c.length), G.OPS.length * 3, "permissions matrix table has every operation × mode");
  await shotEl(page, "#permissions", "feature-permissions-light");
  await context.close();
}

// ═════════ 14. Checklist persistence, reset, print ═════════
section("installation checklist");
{
  const { page, context } = await newPage({ hash: "#ch2-checklist" });
  const boxes = await page.$$eval("#clList input", (b) => b.length);
  eq(boxes, 20, "checklist has 20 items");
  for (let i = 0; i < boxes; i++) { await page.locator("#clList input").nth(i).check(); ctl(`checklist:${i}`); }
  eq(await page.textContent("#clCount"), `${boxes} of ${boxes}`, "checklist counts every tick");
  eq(await page.getAttribute("#clBar", "aria-valuenow"), "100", "checklist progress 100");
  await page.locator("#clList input").nth(0).uncheck();
  await page.reload(); await page.waitForFunction(() => window.AICoreGuide && window.AICoreGuide.ready);
  eq(await page.textContent("#clCount"), `${boxes - 1} of ${boxes}`, "checklist persists across reload");
  eq(await page.locator("#clList input").nth(0).isChecked(), false, "unticked item stays unticked");
  await page.evaluate(() => { window.__printed = 0; window.print = () => { window.__printed++; window.__printClass = document.body.classList.contains("print-checklist"); }; });
  await page.click("#clPrint"); ctl("checklist:print");
  eq(await page.evaluate(() => [window.__printed, window.__printClass]), [1, true], "print button prints the checklist only");
  await page.click("#clReset"); ctl("checklist:reset");
  eq(await page.textContent("#clCount"), `0 of ${boxes}`, "reset clears the checklist");
  await page.reload(); await page.waitForFunction(() => window.AICoreGuide && window.AICoreGuide.ready);
  eq(await page.textContent("#clCount"), `0 of ${boxes}`, "reset persists");
  // storage blocked: the guide still works
  const ctx2 = await browser.newContext();
  await ctx2.addInitScript(() => { Object.defineProperty(window, "localStorage", { get() { throw new Error("blocked"); } }); });
  await ctx2.route("**/*", (r) => (r.request().url().split("#")[0] === URL0 ? r.continue() : (external.push(r.request().url()), r.abort())));
  const p2 = await ctx2.newPage(); const errs2 = []; p2.on("pageerror", (e) => errs2.push(e.message));
  await p2.goto(URL0 + "#ch2-checklist"); await p2.waitForFunction(() => window.AICoreGuide && window.AICoreGuide.ready);
  await p2.locator("#clList input").nth(0).check(); await p2.click("#themeBtn");
  eq(errs2, [], "guide works with storage blocked");
  ctl("storage-blocked");
  await ctx2.close();
  await shotEl(page, "#checklist", "feature-checklist-light");
  await context.close();
}

// ═════════ 15. Keyboard reachability and visible focus ═════════
section("keyboard reachability");
{
  const { page, context } = await newPage();
  for (const ch of CHAPTERS) {
    await go(page, "#" + ch);
    await page.evaluate(() => {
      document.querySelectorAll("[data-kb]").forEach((e) => e.removeAttribute("data-kb"));
      const sel = 'a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea, summary, [tabindex="0"]';
      const vis = (e) => { if (e.closest("[hidden]") || e.closest("details:not([open]) > .body")) return false; const r = e.getBoundingClientRect(); const s = getComputedStyle(e); return r.width > 0 && r.height > 0 && s.visibility !== "hidden" && s.display !== "none"; };
      let i = 0;
      // A radio group is one Tab stop (arrow keys move inside it): count only its checked (or first) radio.
      const radioStop = (e) => { if (e.type !== "radio") return true; const group = [...document.querySelectorAll(`input[type=radio][name="${e.name}"]`)]; const checked = group.find((r) => r.checked); return checked ? checked === e : group[0] === e; };
      document.querySelectorAll(sel).forEach((e) => { if (vis(e) && !e.closest("#tip") && radioStop(e)) e.setAttribute("data-kb", String(i++)); });
    });
    const expected = await page.$$eval("[data-kb]", (e) => e.length);
    await page.evaluate(() => { document.activeElement && document.activeElement.blur(); window.scrollTo(0, 0); });
    await page.focus("body").catch(() => {});
    const seen = new Set();
    let noOutline = [];
    for (let k = 0; k < expected + 40; k++) {
      await page.keyboard.press("Tab");
      const info = await page.evaluate(() => { const a = document.activeElement; if (!a || a === document.body) return null; const s = getComputedStyle(a); const svgNode = a.matches(".node"); const rectW = svgNode ? getComputedStyle(a.querySelector("rect")).strokeWidth : null; return { kb: a.getAttribute("data-kb"), outline: s.outlineStyle !== "none" && parseFloat(s.outlineWidth) > 0, svgNode, rectW, tag: a.tagName + (a.id ? "#" + a.id : "") }; });
      if (!info) continue;
      if (info.kb !== null) seen.add(info.kb);
      if (!(info.outline || (info.svgNode && parseFloat(info.rectW) >= 3))) noOutline.push(info.tag);
      if (seen.size >= expected) break;
    }
    ok(seen.size === expected, `${ch}: ${seen.size} of ${expected} visible controls reachable with Tab`);
    noOutline = [...new Set(noOutline)];
    eq(noOutline, [], `${ch}: every focused control shows a visible focus indicator`);
    ctl(`keyboard:${ch}`);
  }
  await context.close();
}

// ═════════ 16. Screenshots: light + dark, desktop + mobile ═════════
section("screenshots");
if (!process.env.GUIDE_NO_SCREENSHOTS) {
  for (const scheme of ["light", "dark"]) {
    const d = await newPage({ colorScheme: scheme, viewport: { width: 1280, height: 860 } });
    for (const ch of CHAPTERS) { await go(d.page, "#" + ch); await shot(d.page, `desktop-${scheme}-${ch}`); }
    for (const [hash, sel, name] of [["#ch1-architecture", "#archExplorer", "architecture"], ["#ch2-wizard", "#wizard", "wizard"], ["#ch6-explorer", "#commExplorer", "communication"], ["#ch8-workflow", "#workflow", "workflow"], ["#ch5-telemetry", "#telemetry", "telemetry"], ["#ch11-examples", "#examples", "examples"], ["#ch13", "#troubleshoot", "troubleshooting"], ["#ch12-permissions", "#permissions", "permissions"], ["#ch11-reference", "#reference", "reference"], ["#ch2-checklist", "#checklist", "checklist"]]) {
      await go(d.page, hash);
      if (name === "architecture") await d.page.click('#archSvgHost .node[data-id="authz"]');
      if (name === "communication") { await d.page.selectOption("#commScenario", "request"); await d.page.click("#commNext"); await d.page.click("#commNext"); await d.page.click("#commNext"); }
      if (name === "workflow") { await d.page.selectOption("#wfExample", "booking"); await d.page.click("#wfAll"); }
      if (name === "telemetry") await d.page.locator("#teleList button").nth(3).click();
      if (name === "troubleshooting") { await d.page.click('#tsTopics button[data-t="comm"]'); await d.page.locator("#tsNode .opts button").nth(1).click(); }
      if (name === "reference") await d.page.locator("#refTable .rowbtn").first().click();
      await shotEl(d.page, sel, `feature-${name}-${scheme}`);
    }
    for (const [hash, name] of [["#ch3-studio", "ch3-studio"], ["#ch7-portal", "ch7-portal"], ["#ch9-sandbox", "ch9-sandbox"], ["#ch10-overview", "ch10-overview"], ["#verification", "verification-full"]]) { await go(d.page, hash); for (const r of await decodeVisible(d.page)) ok(r.ok, `${hash}: image decodes before its screenshot (${r.r})`); await shot(d.page, `desktop-${scheme}-${name}`, name === "verification-full"); }
    await go(d.page, "#ch1"); await d.page.fill("#searchInput", "Approval Required"); await d.page.waitForSelector("#searchResults:not([hidden])"); await shot(d.page, `desktop-${scheme}-search`);
    await d.page.fill("#searchInput", ""); await go(d.page, "#ch1"); await d.page.locator(".term").first().hover(); await shot(d.page, `desktop-${scheme}-glossary`);
    await d.context.close();
    const m = await newPage({ colorScheme: scheme, viewport: { width: 360, height: 780 } });
    for (const ch of CHAPTERS) { await go(m.page, "#" + ch); await shot(m.page, `mobile-${scheme}-${ch}`); }
    for (const [hash, name] of [["#ch7-portal", "ch7-portal"], ["#ch9-sandbox", "ch9-sandbox"], ["#ch2-read", "ch2-read"]]) { await go(m.page, hash); for (const r of await decodeVisible(m.page)) ok(r.ok, `${hash}: image decodes before its mobile screenshot (${r.r})`); await shot(m.page, `mobile-${scheme}-${name}`); }
    await m.page.click("#menuBtn"); await m.page.waitForTimeout(350); await shot(m.page, `mobile-${scheme}-drawer`); await m.page.keyboard.press("Escape");
    for (const [hash, sel, name] of [["#ch1-architecture", "#archExplorer", "architecture"], ["#ch2-wizard", "#wizard", "wizard"], ["#ch6-explorer", "#commExplorer", "communication"], ["#ch8-workflow", "#workflow", "workflow"], ["#ch5-telemetry", "#telemetry", "telemetry"], ["#ch12-permissions", "#permissions", "permissions"], ["#ch13", "#troubleshoot", "troubleshooting"], ["#ch11-reference", "#reference", "reference"], ["#ch11-examples", "#examples", "examples"], ["#ch2-checklist", "#checklist", "checklist"]]) {
      await go(m.page, hash);
      if (name === "communication") { await m.page.selectOption("#commScenario", "request"); await m.page.click("#commNext"); await m.page.click("#commNext"); }
      if (name === "workflow") { await m.page.selectOption("#wfExample", "booking"); await m.page.click("#wfAll"); }
      await shotEl(m.page, sel, `mobile-feature-${name}-${scheme}`);
    }
    await m.context.close();
  }
}

// ═════════ Final assertions ═════════
eq(external, [], "zero network requests (every non-guide request is recorded and aborted)");
eq(consoleProblems, [], "zero console errors or warnings");
await browser.close();

console.log(`\nControls exercised: ${controls.size}`);
console.log(`Assertions: ${assertions}`);
console.log(`Failures: ${failures.length}`);
console.log(`Screenshots: ${shots.length} in ${SHOTS}`);
for (const f of failures.slice(0, 60)) console.log("  ✗ " + f);
process.exit(failures.length ? 1 : 0);
