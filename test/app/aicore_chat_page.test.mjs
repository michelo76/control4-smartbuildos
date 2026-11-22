// Browser test of the AI Core touchscreen page (www/app/index.html).
//
// The page is served by tools/aicore-dev.py, which runs the REAL page relay
// (src/aicore/webui.lua) with a scripted cloud and a fake PIN Lock. It is a
// development host: nothing here is evidence of how a Control4 touchscreen,
// the phone app, PIN Lock or the cloud behaves.
//
// Covers, at a wall touchscreen (1280×800, 1024×600) and a phone (390×844):
// the open chat first, asking by typing and with the in-page keyboard, the
// thinking bubble and its "still working" line, a rich answer (stat, list,
// follow-ups), the owner unlock and its lock timer, Lock removing what was
// asked unlocked, the Owner PIN mode's locked page, no horizontal scroll,
// touch target sizes.
//
// Run:  node test/app/aicore_chat_page.test.mjs
// Env:  LB_PLAYWRIGHT    directory holding node_modules/playwright
//                        (default: ../smartbuildos beside this repo, read only)
//       AIC_SCREENSHOTS  directory for screenshots (none taken when unset)

import path from "node:path";
import fs from "node:fs";
import { spawn } from "node:child_process";
import { fileURLToPath, pathToFileURL } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, "../..");
const PW = process.env.LB_PLAYWRIGHT || path.resolve(repo, "../smartbuildos");
const SHOTS = process.env.AIC_SCREENSHOTS || "";
const TOKEN = "aicoredev0123456789abcdef0123456";
const PIN = "2468";

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
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

let server = null;
async function serve(access, port) {
  if (server) { server.kill(); await sleep(400); }
  server = spawn("python3", ["tools/aicore-dev.py", "--port", String(port)], {
    cwd: repo, env: { ...process.env, AIC_DEV_ACCESS: access, AIC_DEV_QUIET: "1", AIC_DEV_DELAY: "2" }, stdio: ["ignore", "pipe", "pipe"],
  });
  const base = "http://127.0.0.1:" + port;
  for (let i = 0; i < 80; i++) {
    try { const r = await fetch(base + "/ping"); if (r.ok) return base; } catch (e) { /* not up yet */ }
    await sleep(100);
  }
  throw new Error("dev server did not start on " + port);
}
const dev = (base, p, body) => fetch(base + p, { method: "POST", body: JSON.stringify(body || {}) }).then((r) => r.json());

const VIEWS = {
  wall: { width: 1280, height: 800 },
  small: { width: 1024, height: 600 },
  phone: { width: 390, height: 844 },
};
const browser = await chromium.launch();
const errors = [];
async function open(base, view) {
  const ctx = await browser.newContext({ viewport: VIEWS[view], deviceScaleFactor: view === "phone" ? 2 : 1, hasTouch: view === "phone", colorScheme: "dark" });
  const page = await ctx.newPage();
  page.on("console", (m) => { if (m.type() === "error" && !/Failed to load resource|net::ERR/.test(m.text())) errors.push(m.text()); });
  page.on("pageerror", (e) => errors.push(String(e)));
  await page.goto(base + "/app?k=" + TOKEN);
  return { ctx, page };
}
async function shot(page, name) {
  if (!SHOTS) return;
  fs.mkdirSync(SHOTS, { recursive: true });
  await page.screenshot({ path: path.join(SHOTS, name + ".png") });
}
async function noHScroll(page, label) {
  const w = await page.evaluate(() => [document.documentElement.scrollWidth, window.innerWidth]);
  check(label + ": no horizontal scroll", w[0] <= w[1], w.join(" > "));
}
async function targets(page, label) {
  const small = await page.evaluate(() => Array.from(document.querySelectorAll("button")).filter((b) => {
    if (b.closest("#kb")) return false; // keyboard keys: checked on their own
    const r = b.getBoundingClientRect();
    return r.width > 0 && r.height > 0 && (r.height < 44 || r.width < 44);
  }).map((b) => b.id || b.textContent.trim().slice(0, 20)));
  check(label + ": every visible button is at least 44 px", small.length === 0, small.join(", "));
}
async function clipped(page, label) {
  const bad = await page.evaluate(() => Array.from(document.querySelectorAll(".msg, .chip, .b-stat, .row, h1, #statusText, .hbtn")).filter((e) => {
    const r = e.getBoundingClientRect();
    return r.width > 0 && (e.scrollWidth > e.clientWidth + 1);
  }).map((e) => e.className + ":" + e.textContent.trim().slice(0, 30)));
  check(label + ": no text clipped", bad.length === 0, bad.join(" | "));
}
async function ask(page, q) {
  await page.fill("#question", q);
  await page.click("#ask");
}
async function enterPin(page) {
  await page.waitForSelector("#pad:not(.hidden)", { timeout: 8000 });
  for (const d of PIN) await page.click(`#keys button:text-is("${d}")`);
  await page.click("#padGo");
  await page.waitForSelector("#ownerBox:not(.hidden)", { timeout: 8000 });
}
const thread = (page) => page.locator("#thread").innerText();

try {
  // ── open chat (the default) ──────────────────────────────────────────────
  let base = await serve("open", 47881);
  for (const view of ["wall", "small", "phone"]) {
    console.log(`[open] ${view}`);
    await dev(base, "/__dev/advance", { seconds: 61 }); // the 4-a-minute ask limit is the real one
    const { ctx, page } = await open(base, view);
    await page.waitForSelector("#composer:not(.hidden)", { timeout: 8000 });
    check(view + ": the first thing is the chat with its input bar, not a lock", await page.isVisible("#question") && !(await page.isVisible("#unlock")));
    check(view + ": empty state offers questions", /Try asking/.test(await thread(page)) && (await page.locator(".empty .chip").count()) >= 4);
    check(view + ": Explain is not offered without the owner PIN", !/Explain what just happened/.test(await thread(page)));
    check(view + ": Unlock for more is in the header", await page.isVisible("#elevate"));
    await noHScroll(page, view + " empty"); await targets(page, view + " empty"); await clipped(page, view + " empty");
    await shot(page, `open-empty-${view}`);

    // a text answer
    await ask(page, "What happened today?");
    await page.waitForSelector(".thinking", { timeout: 4000 });
    check(view + ": thinking bubble with seconds", /Thinking… \d+ s/.test(await thread(page)));
    await page.waitForSelector(".msg.a:not(.thinking)", { timeout: 8000 });
    check(view + ": the text answer arrives", /Today was quiet/.test(await thread(page)));
    await shot(page, `open-conversation-${view}`);

    // a rich answer, typed on the in-page keyboard
    await page.click("#kbBtn");
    check(view + ": the in-page keyboard opens", await page.isVisible("#kb"));
    check(view + ": the input does not summon the system keyboard while it is open", await page.evaluate(() => document.getElementById("question").readOnly && document.getElementById("question").getAttribute("inputmode") === "none"));
    for (const k of ["shift", ..."how warm is it"]) {
      if (k === "shift") continue;
      const sel = `#kb button[data-key="${k === " " ? "space" : k}"]`;
      await page.click(sel);
    }
    check(view + ": the keyboard typed the right text (capital first letter)", (await page.inputValue("#question")) === "How warm is it", await page.inputValue("#question"));
    await page.click('#kb button[data-key="?"]');
    const kbBox = await page.locator("#kb").boundingBox();
    const lastMsg = await page.locator("#thread .msg").last().boundingBox();
    check(view + ": the keyboard is not on top of the latest answer", lastMsg.y + lastMsg.height <= kbBox.y + 1, JSON.stringify([lastMsg, kbBox]));
    const kbKey = await page.locator('#kb button[data-key="q"]').boundingBox();
    check(view + ": keyboard keys at least 44 px tall", kbKey.height >= 44, kbKey.height);
    await noHScroll(page, view + " keyboard");
    await shot(page, `keyboard-${view}`);
    await page.click("#kb button.go");
    await page.waitForSelector(".b-stat", { timeout: 8000 });
    await page.click("#kbBtn");
    const t = await thread(page);
    check(view + ": stat cards, a list with values, follow-up chips", /13\.2/.test(t) && /Basement gym/.test(t) && (await page.locator(".chip.follow").count()) === 3);
    await noHScroll(page, view + " rich"); await clipped(page, view + " rich");
    await shot(page, `rich-answer-${view}`);

    // a follow-up chip asks it
    await page.locator(".chip.follow").first().click();
    await page.waitForFunction(() => /Why is the gym cooler\?/.test(document.getElementById("thread").innerText));
    check(view + ": a follow-up chip asks its question", true);

    // the thinking state, 50 s in
    await dev(base, "/__dev/advance", { seconds: 61 });
    await dev(base, "/__dev/hold", { on: true });
    await ask(page, "Is everything in the house working?");
    await page.waitForSelector(".thinking");
    await dev(base, "/__dev/advance", { seconds: 50 });
    await page.waitForFunction(() => /Still working on it/.test(document.getElementById("thread").innerText) && document.querySelector(".still:not(.hidden)"), null, { timeout: 5000 });
    check(view + ": after 45 s one calm line says it is still working", true);
    await shot(page, `thinking-${view}`);
    await dev(base, "/__dev/hold", { on: false });
    await page.waitForSelector(".b-note", { timeout: 8000 });

    // the owner unlock
    await page.click("#elevate");
    await enterPin(page);
    check(view + ": unlocked: the lock timer and Lock in the header", /^\d+ min$/.test(await page.locator("#lockIn").innerText()));
    check(view + ": a new conversation is marked", /Owner unlocked/.test(await thread(page)));
    check(view + ": Explain is offered once unlocked", /Explain what just happened/.test(await page.locator("#strip").innerText()));
    await dev(base, "/__dev/advance", { seconds: 61 });
    await ask(page, "Who came home today?");
    await page.waitForFunction(() => /Who came home today/.test(document.getElementById("thread").innerText));
    await page.waitForSelector(".thinking", { state: "detached", timeout: 8000 });
    await noHScroll(page, view + " elevated"); await targets(page, view + " elevated");
    await shot(page, `elevated-${view}`);
    await page.click("#lock");
    await page.waitForSelector("#ownerBox.hidden", { state: "attached" });
    await page.waitForFunction(() => !/Who came home today/.test(document.getElementById("thread").innerText));
    check(view + ": Lock removes what was asked unlocked", true);
    await ctx.close();
  }

  // chat actions: one tap while owner-unlocked
  for (const view of ["wall", "small", "phone"]) {
    console.log(`[actions] ${view}`);
    await dev(base, "/__dev/advance", { seconds: 61 });
    const { ctx, page } = await open(base, view);
    await page.waitForSelector("#composer:not(.hidden)", { timeout: 8000 });
    await ask(page, "Turn off the patio lights");
    await page.waitForSelector(".msg.a:not(.thinking)", { timeout: 8000 });
    check(view + ": not unlocked: no action card", (await page.locator(".b-action").count()) === 0);
    await page.click("#elevate");
    await enterPin(page);
    await dev(base, "/__dev/advance", { seconds: 61 });
    await ask(page, "Turn off the patio lights");
    await page.waitForSelector(".b-action", { timeout: 8000 });
    const card = page.locator(".b-action").last();
    check(view + ": the card: title, detail, countdown, Confirm and Cancel", /Turn off the patio lights/.test(await card.innerText()) && /Expires in \d+:\d\d/.test(await card.innerText()) && (await card.locator("button").count()) === 2);
    const bb = await card.locator("button").first().boundingBox();
    check(view + ": Confirm at least 44 px", bb.height >= 44 && bb.width >= 44, JSON.stringify(bb));
    await noHScroll(page, view + " action"); await clipped(page, view + " action");
    await shot(page, `action-card-${view}`);
    await card.locator('button[data-act="approve"]').click();
    check(view + ": after the tap both buttons are disabled at once", await card.locator("button").first().isDisabled().catch(() => true));
    await page.waitForFunction(() => /Sent…/.test(document.getElementById("thread").innerText), null, { timeout: 5000 });
    check(view + ": Sent… (not Done) until the controller reports", !/Done/.test(await page.locator(".b-action").last().innerText()));
    await shot(page, `action-sent-${view}`);
    await dev(base, "/__dev/advance", { seconds: 6 });
    await page.waitForFunction(() => /Done/.test(Array.from(document.querySelectorAll(".b-action")).pop().innerText), null, { timeout: 8000 });
    check(view + ": Done from the reported execution", true);
    await shot(page, `action-done-${view}`);
    await dev(base, "/__dev/advance", { seconds: 61 });
    await ask(page, "Set the den to 21");
    await page.waitForFunction(() => /Set the den/.test(Array.from(document.querySelectorAll(".b-action")).pop()?.innerText || ""), null, { timeout: 8000 });
    await page.locator(".b-action").last().locator('button[data-act="approve"]').click();
    await page.waitForFunction(() => /Sent…/.test(Array.from(document.querySelectorAll(".b-action")).pop().innerText), null, { timeout: 5000 });
    await dev(base, "/__dev/advance", { seconds: 6 });
    await page.waitForFunction(() => /Failed: The den thermostat did not accept the change\./.test(Array.from(document.querySelectorAll(".b-action")).pop().innerText), null, { timeout: 8000 });
    check(view + ": Failed with the platform's sentence", true);
    await shot(page, `action-failed-${view}`);
    await dev(base, "/__dev/advance", { seconds: 61 });
    await ask(page, "Start the movie scene");
    await page.waitForFunction(() => /Start Movie Night/.test(Array.from(document.querySelectorAll(".b-action")).pop()?.innerText || ""), null, { timeout: 8000 });
    await page.locator(".b-action").last().locator('button[data-act="approve"]').click();
    await page.waitForFunction(() => /Use PIN/.test(Array.from(document.querySelectorAll(".b-action")).pop().innerText), null, { timeout: 5000 });
    const pinCard = page.locator(".b-action").last();
    check(view + ": a refusal that needs a PIN: its sentence and Use PIN, enabled", /needs the owner PIN/.test(await pinCard.innerText()) && !(await pinCard.locator('button[data-act="pin"]').isDisabled()));
    await shot(page, `action-needs-pin-${view}`);
    await page.click("#lock");
    await page.waitForSelector("#ownerBox.hidden", { state: "attached" });
    await page.waitForFunction(() => document.querySelectorAll(".b-action").length === 0);
    check(view + ": Lock removes every card", true);
    await ctx.close();
  }

  // a refusal is a sentence in the thread (the 4-a-minute limit)
  {
    await dev(base, "/__dev/advance", { seconds: 61 });
    const { ctx, page } = await open(base, "wall");
    await page.waitForSelector("#composer:not(.hidden)");
    for (let i = 0; i < 5; i++) { await ask(page, "Question " + i); await sleep(150); }
    await page.waitForSelector(".sys", { timeout: 4000 });
    check("the fifth question in a minute: a sentence in the thread", /Too many requests/.test(await thread(page)));
    check("…and the text comes back to the input", (await page.inputValue("#question")) === "Question 4");
    await ctx.close();
  }

  // ── Owner PIN mode ───────────────────────────────────────────────────────
  base = await serve("owner_pin", 47882);
  for (const view of ["wall", "small", "phone"]) {
    console.log(`[owner pin] ${view}`);
    const { ctx, page } = await open(base, view);
    await page.waitForSelector("#chatLocked:not(.hidden)", { timeout: 8000 });
    check(view + ": locked: the unlock card, no input bar", await page.isVisible("#unlock") && !(await page.isVisible("#question")));
    await noHScroll(page, view + " locked"); await targets(page, view + " locked");
    await shot(page, `locked-${view}`);
    await page.click("#unlock");
    await enterPin(page);
    await page.waitForSelector("#composer:not(.hidden)");
    check(view + ": unlocked: the empty state with Explain", /Explain what just happened/.test(await thread(page)));
    await shot(page, `unlocked-empty-${view}`);
    await ctx.close();
  }
  check("no page errors", errors.length === 0, errors.join(" | "));
} finally {
  await browser.close();
  if (server) server.kill();
}
console.log(`${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
