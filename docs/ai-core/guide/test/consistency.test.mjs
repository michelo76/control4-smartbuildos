// Consistency test: the guide's names must match the sources exactly.
//
//  * every command (with its parameters, types and list items), action,
//    property, event, variable and conditional in drivers/smartbuildos-ai-core/driver.xml
//    is in the guide's reference data, and the guide's reference data names
//    nothing driver.xml does not define;
//  * every frame of docs/protocol/MODULE-CONTRACT-V2.md §4 and every error
//    code of §11 (with its retry flag) is in the guide, and every SBOS_* frame
//    token anywhere in the guide exists in contract v2 or protocol v1
//    (docs/flight-recorder/PROTOCOL.md);
//  * every AI_* token anywhere in the guide is a driver.xml name, a licence
//    feature, or an exported constant of the platform's protocol.ts;
//  * every error code the guide shows in frames, answers or status text is in
//    the closed vocabulary;
//  * cloud ops, restricted operations and raise_event names equal the driver's
//    src/aicore/vocab.lua;
//  * the guide's tool list equals the platform's real tool registry (when the
//    platform worktree is present; it is imported read-only).
//
// Run: node --experimental-strip-types docs/ai-core/guide/test/consistency.test.mjs

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, "../../../..");
const PLATFORM = process.env.AI_CORE_PLATFORM || path.join(path.resolve(repo, ".."), "smartbuildos-ai-core");
const read = (p) => fs.readFileSync(path.join(repo, p), "utf8");
const xml = read("drivers/smartbuildos-ai-core/driver.xml");
const v2 = read("docs/protocol/MODULE-CONTRACT-V2.md");
const v1 = read("docs/flight-recorder/PROTOCOL.md");
const vocab = read("src/aicore/vocab.lua");
const html = process.env.GUIDE_HTML ? fs.readFileSync(process.env.GUIDE_HTML, "utf8") : read("docs/ai-core/guide/SmartBuildOS_AI_Core_Interactive_Guide.html");

let assertions = 0;
const failures = [];
const ok = (c, m) => { assertions++; if (!c) failures.push(m); };
const sameSet = (a, b, what) => {
  const A = new Set(a), B = new Set(b);
  const missing = [...A].filter((x) => !B.has(x)), extra = [...B].filter((x) => !A.has(x));
  ok(missing.length === 0, `${what}: missing from the guide: ${missing.join(", ")}`);
  ok(extra.length === 0, `${what}: in the guide but not in the source: ${extra.join(", ")}`);
};
const tag = (s, t) => { const m = s.match(new RegExp(`<${t}>([\\s\\S]*?)</${t}>`)); return m ? m[1].trim() : ""; };
const blocks = (s, t) => [...s.matchAll(new RegExp(`<${t}>([\\s\\S]*?)</${t}>`, "g"))].map((m) => m[1]);

// ── driver.xml ──
const X = {
  commands: blocks(tag(xml, "commands"), "command").map((c) => ({ name: tag(c, "name"), description: tag(c, "description"), params: blocks(c, "param").map((p) => ({ name: tag(p, "name"), type: tag(p, "type"), items: blocks(p, "item") })) })),
  actions: blocks(tag(xml, "actions"), "action").map((a) => ({ name: tag(a, "name"), command: tag(a, "command") })),
  properties: blocks(tag(xml, "properties"), "property").map((p) => ({ name: tag(p, "name"), type: tag(p, "type"), default: tag(p, "default"), readonly: tag(p, "readonly") === "true", items: blocks(p, "item") })),
  events: blocks(tag(xml, "events"), "event").map((e) => ({ id: Number(tag(e, "id")), name: tag(e, "name"), description: tag(e, "description") })),
  variables: blocks(tag(xml, "variables"), "variable").map((v) => ({ id: Number(tag(v, "id")), name: tag(v, "name"), type: tag(v, "type"), default: tag(v, "default") })),
  conditionals: blocks(tag(xml, "conditionals"), "conditional").map((c) => ({ id: Number(tag(c, "id")), name: tag(c, "name"), type: tag(c, "type"), statement: tag(c, "condition_statement") })),
};
ok(X.commands.length >= 10 && X.events.length >= 10 && X.variables.length >= 10, `driver.xml parsed (${X.commands.length} commands, ${X.events.length} events, ${X.variables.length} variables)`);
ok(tag(xml, "connections") === "" && tag(xml, "proxies") === "", "driver.xml declares no connections or proxies (the guide says so)");
const ex = (s) => s.replace(/&amp;/g, "&").replace(/&lt;/g, "<").replace(/&gt;/g, ">");

// ── guide reference data ──
const refJson = html.match(/<script type="application\/json" id="ref-data">([\s\S]*?)<\/script>/);
ok(!!refJson, "guide embeds its reference data");
const REF = JSON.parse(refJson[1]);

sameSet(X.commands.map((c) => c.name), REF.commands.map((c) => c.name), "commands");
for (const c of X.commands) {
  const g = REF.commands.find((x) => x.name === c.name); if (!g) continue;
  ok(g.description === ex(c.description), `command ${c.name}: description matches driver.xml`);
  ok(JSON.stringify(g.params.map((p) => p.name)) === JSON.stringify(c.params.map((p) => p.name)), `command ${c.name}: parameter names/order`);
  for (const p of c.params) {
    const gp = g.params.find((x) => x.name === p.name); if (!gp) continue;
    ok(gp.type === p.type, `command ${c.name}.${p.name}: type ${p.type}`);
    ok(JSON.stringify(gp.items || []) === JSON.stringify(p.items), `command ${c.name}.${p.name}: list items`);
  }
}
sameSet(X.actions.map((a) => a.name + "=" + a.command), REF.actions.map((a) => a.name + "=" + a.command), "actions (name = command)");
sameSet(X.properties.map((p) => p.name), REF.properties.map((p) => p.name), "properties");
for (const p of X.properties) {
  const g = REF.properties.find((x) => x.name === p.name); if (!g) continue;
  ok(g.default === p.default, `property ${p.name}: default "${p.default}" (guide "${g.default}")`);
  ok(g.readonly === p.readonly, `property ${p.name}: read-only flag`);
  if (p.items.length) ok(JSON.stringify(g.items) === JSON.stringify(p.items), `property ${p.name}: list items`);
}
sameSet(X.events.map((e) => e.id + ":" + e.name), REF.events.map((e) => e.id + ":" + e.name), "events (id:name)");
for (const e of X.events) { const g = REF.events.find((x) => x.id === e.id); if (g) ok(g.description === ex(e.description), `event ${e.name}: description`); }
sameSet(X.variables.map((v) => `${v.id}:${v.name}:${v.type}:${v.default}`), REF.variables.map((v) => `${v.id}:${v.name}:${v.type}:${v.default}`), "variables (id:name:type:default)");
sameSet(X.conditionals.map((c) => `${c.id}:${c.name}:${c.type}:${c.statement}`), REF.conditionals.map((c) => `${c.id}:${c.name}:${c.type}:${c.statement}`), "conditionals (id:name:type:statement)");

// Every driver.xml name also appears in the guide's prose or generated tables' data.
const prose = html.replace(/<script[\s\S]*?<\/script>/g, " ");
for (const n of [...X.commands.map((c) => c.name), ...X.actions.map((a) => a.command), ...X.variables.map((v) => v.name), ...X.conditionals.map((c) => c.name)]) ok(html.includes(n), `guide mentions ${n}`);
for (const n of ["AI_ASK", "AI_RECORD_EVENT", "AI_START_DIAGNOSTIC", "AI_LAST_RESPONSE", "AI_STATUS", "AGENT_CONNECTED", "Last Error", "AI API Credential", "SmartBuildOS Connection Status", "Flight Recorder Link"]) ok(prose.includes(n), `guide prose discusses ${n}`);

// ── AI_* tokens: nothing invented ──
const protocolTs = fs.existsSync(path.join(PLATFORM, "src/lib/ai-core/protocol.ts")) ? fs.readFileSync(path.join(PLATFORM, "src/lib/ai-core/protocol.ts"), "utf8") : "";
const protocolConsts = [...protocolTs.matchAll(/export const (AI_[A-Z_]+)/g)].map((m) => m[1]);
// Platform environment variable names the concierge reads (concierge/**/*.ts string literals).
const envNames = [];
const conciergeDir = path.join(PLATFORM, "src/lib/ai-core/concierge");
if (fs.existsSync(conciergeDir)) { const walk = (d) => { for (const e of fs.readdirSync(d, { withFileTypes: true })) { const f = path.join(d, e.name); if (e.isDirectory()) walk(f); else if (f.endsWith(".ts")) for (const m of fs.readFileSync(f, "utf8").matchAll(/\b(AI_CORE_[A-Z_]+)\b/g)) envNames.push(m[1]); } }; walk(conciergeDir); }
const allowedAi = new Set([...X.commands.map((c) => c.name), ...X.variables.map((v) => v.name), ...X.conditionals.map((c) => c.name), "AI_LEARNING", "AI_ACTIONS", "AI_CONCIERGE", ...protocolConsts, ...envNames]);
const aiTokens = [...new Set(html.match(/\bAI_[A-Z][A-Z_]*\b/g))];
for (const t of aiTokens) ok(allowedAi.has(t), `AI_* token ${t} exists in driver.xml, the licence features or protocol.ts`);

// ── contract v2 frames and error codes ──
const sec = (md, n) => { const i = md.indexOf(`\n## ${n}.`); const j = md.indexOf("\n## ", i + 5); return md.slice(i, j < 0 ? undefined : j); };
const v2Frames = [...new Set([...sec(v2, 4).matchAll(/^\|\s*[MA]→[MA]\s*\|\s*`(SBOS_[A-Z_]+)`/gm)].map((m) => m[1]))];
ok(v2Frames.length >= 12, `contract v2 §4 parsed (${v2Frames.length} frames)`);
const v1Frames = [...new Set([...v1.matchAll(/`(SBOS_[A-Z_]+)`/g)].map((m) => m[1]))];
const guideFrames = REF.frames.map((f) => f.name);
for (const f of v2Frames) ok(guideFrames.includes(f), `guide frame table lists ${f}`);
for (const f of guideFrames) ok(v2Frames.includes(f) || v1Frames.includes(f), `guide frame ${f} exists in contract v2 or protocol v1`);
const sbosTokens = [...new Set(html.match(/\bSBOS_[A-Z][A-Z_]*\b/g))];
const allowedSbos = new Set([...v2Frames, ...v1Frames, "SBOS_AI_CORE", "SBOS_FLIGHT_RECORDER"]);
for (const t of sbosTokens) ok(allowedSbos.has(t), `SBOS_* token ${t} exists in the protocol documents`);

const codeRows = [...sec(v2, 11).matchAll(/^\|\s*`([a-z_]+)`\s*\|\s*([^|]+)\|\s*([^|]+)\|/gm)].map((m) => ({ code: m[1], retry: m[3].includes("yes") ? "yes" : m[3].trim() === "—" ? "—" : "no" }));
ok(codeRows.length === 17, `contract v2 §11 parsed (${codeRows.length} codes)`);
sameSet(codeRows.map((c) => c.code), REF.errorCodes.map((c) => c.code), "error codes");
for (const c of codeRows) { const g = REF.errorCodes.find((x) => x.code === c.code); if (g) ok(g.retry === c.retry, `error code ${c.code}: retry flag ${c.retry}`); }
const vocabCodes = new Set(codeRows.map((c) => c.code));
const shown = new Set();
for (const m of html.matchAll(/error_code['"]?\s*[:=]\s*['"]([a-z_]+)['"]/g)) shown.add(m[1]);
for (const m of html.matchAll(/refused locally \(([a-z_]+)\)|last request refused \(([a-z_]+)\)|refused by SmartBuildOS: ([a-z_]+)|no answer from SmartBuildOS \(([a-z_]+)\)|refused \(([a-z_]+)\)/g)) { const c = m.slice(1).find(Boolean); if (c && c !== "code") shown.add(c); }
for (const m of html.matchAll(/\(([a-z_]+)\)/g)) if (vocabCodes.has(m[1])) shown.add(m[1]);
for (const c of shown) ok(vocabCodes.has(c), `error code "${c}" shown in the guide is in the closed vocabulary`);
for (const c of vocabCodes) ok(html.includes(c), `error code ${c} appears in the guide`);

// ── driver vocabularies ──
const luaList = (name) => { const m = vocab.match(new RegExp(`M\\.${name} = \\{([\\s\\S]*?)\\n\\}`)); return m ? [...m[1].matchAll(/"([a-z_]+)"|([a-z_]+) = true/g)].map((x) => x[1] || x[2]) : []; };
sameSet(luaList("CLOUD_OPS"), REF.cloudOps, "cloud ops (vocab.lua CLOUD_OPS)");
sameSet(luaList("OPERATIONS"), REF.restrictedOps, "restricted operations (vocab.lua OPERATIONS)");
const raisable = luaList("RAISABLE");
sameSet(raisable, REF.events.filter((e) => e.id !== 9).map((e) => e.key), "raise_event names (vocab.lua RAISABLE)");
for (const r of raisable) ok(prose.includes(r), `guide prose lists raise_event ${r}`);

// ── platform tool registry ──
let registryWires = null;
if (fs.existsSync(path.join(PLATFORM, "src/lib/ai-core/tools/registry.ts"))) {
  const T = (f) => pathToFileURL(path.join(PLATFORM, "src/lib/ai-core/tools", f)).href;
  const port = new Proxy({}, { get: (_t, k) => (k === "then" ? undefined : async () => ({})) });
  // Built from the factories tools/index.ts exports, so a tool added or removed on the platform is caught.
  const idx = await import(T("index.ts"));
  const tools = [...idx.READ_TOOLS];
  for (const [name, args] of [["createMemoryTools", [port]], ["createServiceTools", [port]], ["createNotificationTools", [port]], ["createActionTools", [port, {}]], ["createConciergeTools", [port]]]) if (typeof idx[name] === "function") tools.push(...idx[name](...args));
  const key = (t) => [t.id, t.wireName ?? t.wire, t.risk, t.household, t.verb ?? null, t.feature ?? null, t.audience ?? "everyone", (t.schema ? t.schema.required ?? [] : t.required).join(",")].join("|");
  sameSet(tools.map(key), REF.tools.map(key), "tools (id|wire|risk|household|verb|feature|audience|required) vs the platform registry");
  for (const t of tools) ok(prose.includes(t.wireName) || html.includes(t.wireName), `guide documents tool ${t.wireName}`);
  registryWires = new Set(tools.map((t) => t.wireName));
  const count = html.match(/<span data-tool-count>(\d+)<\/span>/);
  ok(count && Number(count[1]) === tools.length, `the guide's stated tool count equals the registry (${count && count[1]} vs ${tools.length})`);
} else {
  console.log("  (platform worktree not found: tool registry comparison skipped)");
}

// ── tool names in prose: nothing invented or removed ──
if (registryWires) {
  const NOT_TOOLS = new Set(["service_maintenance", "service_role", "service_role_only", "memory_id", "memory_key", "memory_search", "memory_propose", "actions_set_light"]);
  const wireLike = /^(flight_recorder|devices|rooms|usage|health|memory|service|notifications|actions|concierge)_[a-z_]+$/;
  const codeTokens = [...new Set([...prose.matchAll(/<code>([a-z_]+)<\/code>/g)].map((m) => m[1]))].filter((t) => wireLike.test(t));
  const known = new Set([...registryWires, "service_maintenance", "service_role", "memory_id", "memory_key", "flight_recorder_events", "flight_recorder_available", "flight_recorder_not_installed", "flight_recorder_has_no_local_history_service", "flight_recorder_unknown_agent_cannot_discover", "flight_recorder_topics", "health_scores", "usage_events"]);
  for (const t of codeTokens) ok(known.has(t), `tool-like name <code>${t}</code> in the guide is a real tool (or a known non-tool identifier)`);
  void NOT_TOOLS;
}

// ── routes: the route index equals the platform's route files ──
const ROUTE_ROOTS = ["src/app/api/monitoring/ai-core", "src/app/api/portal/ai-core", "src/app/api/integrations/control4/modules/rpc"];
if (fs.existsSync(path.join(PLATFORM, ROUTE_ROOTS[0]))) {
  const files = [];
  const walk = (d) => { for (const e of fs.readdirSync(d, { withFileTypes: true })) { const f = path.join(d, e.name); if (e.isDirectory()) walk(f); else if (e.name === "route.ts") files.push("/" + path.relative(path.join(PLATFORM, "src/app"), path.dirname(f))); } };
  for (const r of ROUTE_ROOTS) walk(path.join(PLATFORM, r));
  const guideRoutes = [];
  for (const r of REF.routes) {
    const m = r.path.match(/^(\S+)(?: \(\+ (.+)\))?$/);
    guideRoutes.push(m[1]);
    if (m[2]) for (const extra of m[2].split(",").map((x) => x.trim())) guideRoutes.push(m[1] + "/" + extra);
  }
  sameSet(files, guideRoutes, "route index vs the platform's route.ts files");
  const routeTokens = [...new Set([...prose.matchAll(/\/api\/(?:monitoring|portal)\/ai-core\/[a-z\-/\[\]]+/g)].map((m) => m[0].replace(/\/$/, "")))];
  for (const t of routeTokens) ok(files.includes(t), `route ${t} named in the guide exists on the platform`);
}

// ── stated facts ──
const visible = (prose + " " + html.slice(html.indexOf("const STATUS"), html.indexOf("const VERIFY"))).replace(/<\/(td|th|li|p|h[1-4]|tr|dd|dt|figcaption|summary)>/g, " ¶ ").replace(/<[^>]+>/g, " ").replace(/', /g, " ¶ ").replace(/' \},?/g, " ¶ ").replace(/\b(source|area|title|text|tone): '/g, " ¶ $1: ").replace(/\s+/g, " ");
ok(!/learning (?:is |stays )?(?:on|enabled|active) by default/i.test(visible), "the guide never says learning is on by default");
ok(/Learning is off by default/i.test(visible) && visible.includes("Off (not switched on in System Studio)"), "the guide says learning is off by default, with the driver's exact text");
ok(REF.variables.find((v) => v.name === "LEARNING_ACTIVE").default === "false", "LEARNING_ACTIVE defaults to false");
ok(!/(?:real|live) (?:restaurant )?bookings? (?:is|are) (?:now )?available/i.test(visible), "the guide never calls real booking available");
ok(!/\bunsupported\b[^.]{0,40}learn_preference|learn_preference[^.]{0,60}answers? (?:this op )?`?unsupported/i.test(visible.replace(/Absent → learn_preference answers `unsupported`/, "")), "learn_preference is not described as unsupported");
ok(!/exclusions\.rooms<\/code> ≤ 256|≤ 256 ids/.test(html), "exclusions.rooms bound is 500, not 256");
ok(html.includes("<code>exclusions.rooms</code> ≤ 500"), "exclusions.rooms ≤ 500 stated");
ok(/set_learning<\/code><\/td><td><code>active<\/code>, <code>reason<\/code> \(≤ 120\), <code>config_version<\/code>/.test(html), "set_learning carries config_version");
ok(/<code>superseded<\/code>/.test(html), "apply_config superseded by a newer document is stated");
ok(visible.includes("the context key is sent as key") || /sent as <code>key<\/code> in the <code>set_context<\/code> cloud body/.test(html), "set_context body key is key");

// KNOWN-ISSUES references exist.
const ki = read("docs/ai-core/KNOWN-ISSUES.md");
for (const m of new Set([...prose.matchAll(/\bKI-(\d+)\b/g)].map((x) => x[1]))) ok(new RegExp(`\\bKI-${m}\\b`).test(ki), `KI-${m} exists in KNOWN-ISSUES.md`);

// ── checklist: statuses the guide claims ──
const CHECKLIST = process.env.AI_CORE_CHECKLIST || path.join(path.resolve(repo, ".."), "ai-core-program/IMPLEMENTATION_CHECKLIST.md");
if (fs.existsSync(CHECKLIST)) {
  const cl = fs.readFileSync(CHECKLIST, "utf8");
  const items = {};
  for (const m of cl.matchAll(/^\|\s*(\d+\.\d+)\s*\|[^|]*\|(?:[^|]*\|)?\s*(Completed|Tested|In progress|Not started|Blocked|Implemented)/gm)) items[m[1]] = m[2];
  ok(Object.keys(items).length > 80, `checklist parsed (${Object.keys(items).length} items)`);
  const expand = (a, b) => { const [ma, na] = a.split(".").map(Number), [, nb] = b.split(".").map(Number); const out = []; for (let n = na; n <= nb; n++) out.push(ma + "." + n); return out; };
  const refsIn = (t) => { const out = []; for (const m of t.matchAll(/\b(\d{1,2}\.\d{1,2})(?:\s*[–-]\s*(\d{1,2}\.\d{1,2}))?\b/g)) { if (m[2]) out.push(...expand(m[1], m[2])); else out.push(m[1]); } return out.filter((r) => items[r]); };
  // (a) A sentence that calls items Completed (and names no other status) names only Completed items;
  //     a sentence naming a Blocked / In progress / Not started item never calls it available or done.
  const routeStates = REF.routes.map((r) => " ¶ " + r.state).join("");
  const sentences = (visible + routeStates).split(/¶|;|(?<=\.)\s+(?=[A-Z(“"])/).map((x) => x.trim()).filter((x) => x && !/^source:/.test(x) && !/^(?:checklist )?[\d.,–\s-]+$/.test(x) && !/^checklist [\d.,–\s-]+$/.test(x));
  for (const sen of sentences) {
    const refs = [...new Set(refsIn(sen))];
    if (!refs.length) continue;
    const saysCompleted = /\bCompleted\b/.test(sen), namesOther = /\b(Tested|Blocked|blocked|In progress|in progress|Not started|not started|pending|In development)\b/.test(sen);
    if (saysCompleted && !namesOther) for (const r of refs) ok(items[r] === "Completed", `the guide calls checklist ${r} Completed, but the checklist says ${items[r]}: “${sen.slice(0, 120)}”`);
    for (const r of refs) if (items[r] !== "Completed" && items[r] !== "Tested") ok(!/\b(?:is|are|now) available\b/.test(sen) || /\bnot available\b/.test(sen), `the guide calls checklist ${r} (${items[r]}) available: “${sen.slice(0, 120)}”`);
    for (const r of refs) if (items[r] === "Blocked") ok(/\b(Blocked|blocked|owner|never|not|no|needs|wait|waits|until)\b/.test(sen), `checklist ${r} is Blocked, but the sentence naming it does not say so: “${sen.slice(0, 120)}”`);
  }
  // (b) The Verification page lists match the checklist.
  const verifyBlock = html.slice(html.indexOf("const VERIFY"), html.indexOf("/* Glossary"));
  const listOf = (name) => { const i = verifyBlock.indexOf(name + ": ["); const j = verifyBlock.indexOf("\n  ],", i); return verifyBlock.slice(i, j); };
  for (const r of refsIn(listOf("never"))) ok(items[r] === "Blocked", `Verification “never run” cites ${r}, which the checklist marks ${items[r]} (must be Blocked)`);
  for (const r of refsIn(listOf("unreleased"))) ok(items[r] === "Blocked", `Verification “not released” cites ${r}, which the checklist marks ${items[r]} (must be Blocked)`);
  for (const r of refsIn(listOf("simulated"))) ok(items[r] === "Completed" || items[r] === "Tested", `Verification “verified in simulation” cites ${r}, which the checklist marks ${items[r]}`);
  const decisions = [...cl.slice(cl.indexOf("## Open owner decisions")).matchAll(/^(\d+)\. (.*)$/gm)].filter((m) => !/^\(Resolved/.test(m[2])).map((m) => Number(m[1])).filter((n) => n > 0);
  const listedDecisions = [...listOf("owner").matchAll(/'decision (\d+)/g)].map((m) => Number(m[1]));
  sameSet(decisions.map(String), listedDecisions.map(String), "open owner decisions on the Verification page vs the checklist");
  // (d) Every STATUS callout's label agrees with the checklist items it cites
  //     (its title, text and source). The tone is the visible label ("Simulated
  //     only", "In development", "Blocked", "Verified"); a title may not call an
  //     area Completed / Verified / Done unless every item it cites is done.
  const statusSrc = html.slice(html.indexOf("const STATUS = {"), html.indexOf("const VERIFY"));
  const STATUS = Function('"use strict"; return (' + statusSrc.slice(statusSrc.indexOf("{"), statusSrc.lastIndexOf("};") + 1) + ");")();
  const DONE = new Set(["Completed", "Tested"]), OPEN = new Set(["In progress", "Implemented", "Not started"]);
  const phaseRefs = (t) => [...t.matchAll(/\bchecklist Phase (\d+)\b/g)].flatMap((m) => Object.keys(items).filter((r) => r.split(".")[0] === m[1]));
  let statusChecked = 0;
  for (const [key, s] of Object.entries(STATUS)) {
    const refs = [...new Set([...refsIn(s.title + " " + s.text + " " + s.source), ...phaseRefs(s.source + " " + s.text)])];
    if (!refs.length) continue;
    statusChecked++;
    const st = refs.map((r) => items[r]);
    const has = (set) => st.some((x) => set.has(x));
    const list = refs.map((r) => r + " " + items[r]).join(", ");
    ok(["sim", "dev", "block", "ok"].includes(s.tone), `STATUS ${key}: tone ${s.tone} is one of sim, dev, block, ok`);
    if (s.tone === "block") ok(st.includes("Blocked"), `STATUS ${key} is labelled Blocked, but none of the items it cites is Blocked (${list})`);
    if (s.tone === "dev") ok(has(OPEN), `STATUS ${key} is labelled In development, but every item it cites is finished or blocked (${list})`);
    if (s.tone === "sim") ok(has(DONE) && !has(OPEN), `STATUS ${key} is labelled Simulated only, which needs a Completed/Tested item and none In progress / Implemented / Not started (${list})`);
    if (s.tone === "ok") ok(st.every((x) => x === "Completed"), `STATUS ${key} is labelled Verified, but not every item it cites is Completed (${list})`);
    const claimsDone = /\b(Completed|Verified|Done|Finished|Released|Shipped)\b/.test(s.title) && !/\b(not|never|no)\s+(yet\s+)?(Completed|Verified|Done|Finished|Released|Shipped)\b/i.test(s.title);
    if (claimsDone) ok(st.every((x) => DONE.has(x)) && s.tone !== "dev" && s.tone !== "block", `STATUS ${key}: the title “${s.title}” claims it is done, but the items it cites are ${list} and its label is ${s.tone}`);
    if (has(OPEN)) ok(s.tone === "dev" || s.tone === "block", `STATUS ${key} cites unfinished items (${list}) but is labelled ${s.tone}`);
  }
  ok(statusChecked === Object.keys(STATUS).length, `STATUS callouts checked against the checklist: ${statusChecked} of ${Object.keys(STATUS).length} (each must cite its checklist items)`);
  for (const r of refsIn(listOf("browser"))) ok(items[r] === "Completed" || items[r] === "Tested", `Verification “browser-verified” cites ${r}, which the checklist marks ${items[r]}`);
  // (c) Every Blocked LIVE/HW item is somewhere on the Verification page or in a STATUS entry.
  for (const [r, st] of Object.entries(items)) if (st === "Blocked") ok(new RegExp(`\\b${r.replace(".", "\\.")}\\b`).test(verifyBlock + html.slice(html.indexOf("const STATUS"), html.indexOf("const VERIFY"))), `blocked checklist item ${r} appears on the Verification page or in STATUS`);
} else console.log("  (checklist not found: status checks skipped)");

console.log(`Consistency assertions: ${assertions}`);
console.log(`Failures: ${failures.length}`);
for (const f of failures) console.log("  ✗ " + f);
process.exit(failures.length ? 1 : 0);
