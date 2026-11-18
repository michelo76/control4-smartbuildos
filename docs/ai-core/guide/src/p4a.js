'use strict';
/* ══════════════════════════════════════════════════════════════════════
   STATUS — the single place every status callout in this guide comes from.
   A later pass updates statuses here only. tone: sim | dev | block | ok.
   Sources: ai-core-program/IMPLEMENTATION_CHECKLIST.md (2026-11-18),
   docs/ai-core/DRIVER.md §13–14, platform git state on 2026-11-18.
   ══════════════════════════════════════════════════════════════════════ */
const STATUS = {
  driver: { area: 'AI Core driver (Composer surface, collection, buffer, operations)', tone: 'sim',
    title: 'Built and simulator-tested; not yet run on a physical controller',
    text: 'Checklist 3.1–3.10 are Completed in simulation (the conductor reran the driver suite: 149 test files, 10,175 checks, 0 failed; emulator 77/77; a .c4z was built). Licence states (3.11) are Tested, with end-to-end licensing still In progress. 3.12 (the driver runs in Composer on a real controller) is Blocked: no controller.',
    source: 'DRIVER.md §13–14; checklist Phase 3' },
  protocol: { area: 'Module contract v2 and the Agent bus', tone: 'sim',
    title: 'Built and emulator-verified; not yet run on a physical controller',
    text: 'Completed in simulation (checklist 2.2–2.10; the conductor reran 137 test files, 9,516 checks, 0 failed, emulator 23/23). Measuring frame sizes, ordering and restart on a real controller is Blocked (2.17).',
    source: 'MODULE-CONTRACT-V2.md §16–17; checklist Phase 2' },
  frLocal: { area: 'Flight Recorder local history over contract v2', tone: 'sim',
    title: 'Built and emulator-tested; not yet run on a physical controller',
    text: 'The Flight Recorder serves its local ring over contract v2, and AI Core discovers it, subscribes and degrades when it is absent: checklist 4.1–4.2 Completed in simulation. Emulator only.',
    source: 'DRIVER.md §8; checklist 4.1–4.2' },
  cloudTools: { area: 'Cloud Flight Recorder tools and evidence post-check', tone: 'sim',
    title: 'Built and tested with fakes; no real database',
    text: 'Completed in simulation (checklist 4.3–4.6): the conductor reran 171 tools/authz/evidence tests, fakes only.',
    source: 'checklist 4.3–4.6' },
  frRetention: { area: 'Flight Recorder retention', tone: 'block',
    title: 'Owner decision — retention is not scheduled',
    text: 'The retention function exists but its schedule is commented out. Enabling it deletes Flight Recorder events older than 30 days once applied, so it waits for the owner (checklist 4.7).',
    source: 'PRIVACY-RETENTION-LIMITS.md; checklist 4.7' },
  providers: { area: 'AI provider adapters, key vault, settings, budgets', tone: 'sim',
    title: 'Built and tested with mocked HTTP; no live provider call',
    text: 'Completed in simulation (checklist 5.1–5.9: 103 provider tests and 41 vault/settings/budget/audit tests). Real calls to Anthropic and OpenAI are Blocked until a customer API key is supplied (5.11, 5.12).',
    source: 'providers/README.md; checklist Phase 5' },
  rpc: { area: 'Controller RPC route and cloud ops', tone: 'sim',
    title: 'Built and tested in simulation; the route is not deployed',
    text: 'Checklist 2.12 is Completed in simulation: business outcomes are HTTP 200 `{ok}`, a bad token 401, an outage 5xx. ask, analyze_room, analyze_system, suggest_scene, generate_report, start_diagnostic and test_provider answer with a job; set_context and send_notification complete at once; learn_preference completes when the memory library is wired, else answers `unsupported`. The route is not deployed: until it is, the Agent gets 404 and the driver sees `cloud_refused`.',
    source: 'rpc/ops.ts; DRIVER.md §3; MODULE-CONTRACT-V2.md §16; checklist 2.12' },
  learning: { area: 'Household learning (memory, detectors, recommendations, homeowner controls)', tone: 'sim',
    title: 'Built and tested in simulation; analysis is not scheduled',
    text: 'Completed in simulation (checklist 6.1–6.6; 60 learning tests; the migration ran only on a throwaway local Postgres). Analysis runs on demand; scheduling it is an owner decision (6.7). Today only an explicit licence row grants AI_LEARNING (open owner decision 7).',
    source: 'memory/README.md; checklist Phase 6' },
  portalUi: { area: 'Homeowner portal screens', tone: 'dev',
    title: 'In development — portal screens not built',
    text: 'The portal API routes for learning, memories, actions and rules are committed. The portal screens for the concierge conversation, approvals and learned-preference review are Not started (9.4); a homeowner approval screen for recommendations is an open owner decision.',
    source: 'checklist 9.4; open owner decision 8' },
  orchestrator: { area: 'Orchestrator (conversation loop)', tone: 'sim',
    title: 'Built and tested in simulation; no live model call',
    text: 'The bounded turn loop (static prompts, fixed tool list, budget before every call, structured answer, evidence post-check) is Completed in simulation (checklist 5.10: 81 orchestrator/conversation/RPC/job tests; injection fixtures pass). No call has been made to a real model (5.11, 5.12 blocked on a key).',
    source: 'orchestrator/turn.ts; checklist 5.10' },
  actions: { area: 'Actions, approvals, pre-approved rules, programming hand-offs', tone: 'sim',
    title: 'Built and tested in simulation; no device has been changed',
    text: 'Checklist 7.1–7.8 are Completed in simulation (the conductor reran 1,139 action/rule/programming/authz tests; the migration ran on a local Postgres, worker-reported). An approved action physically changing a device is Blocked: no controller (7.9).',
    source: 'actions/*.ts; checklist Phase 7' },
  studio: { area: 'System Studio Intelligence pages', tone: 'dev',
    title: 'In development — not in this release',
    text: 'Navigation, AI Overview, Household Usage, Flight Recorder Intelligence and the provider/credential UI are In progress (8.1–8.4, 8.8, 8.9); Recommendations, Service Intelligence and Conversations pages are Not started in the checklist (8.5–8.7), although their API routes and some page components already exist on the platform branch or in uncommitted work.',
    source: 'checklist Phase 8; platform working tree' },
  ninth: { area: 'Ninth Studio destination', tone: 'block',
    title: 'Owner sign-off pending',
    text: 'Intelligence as a ninth top-level System Studio destination contradicts the eight destinations of REBUILD-SPEC §6 and waits for owner sign-off (8.10). Nesting it is a one-field change.',
    source: 'ARCHITECTURE D13; checklist 8.10' },
  conversations: { area: 'AI Conversations', tone: 'dev',
    title: 'In development — not in this release',
    text: 'Staff and homeowner conversation routes (with a Server-Sent Events progress stream) are on the platform branch; the Studio page is Not started (8.7) and the homeowner portal screen is Not started (9.4).',
    source: 'conversations routes; checklist 8.7, 9.4' },
  concierge: { area: 'Lifestyle concierge', tone: 'dev',
    title: 'In development — not in this release',
    text: 'The reservation provider interface and booking state machine (9.1), the labelled sandbox provider (9.2), the Google and Microsoft calendar adapters (9.3) and failed-booking recovery (9.5) are In progress; the portal concierge screens are Not started (9.4). Only the SIMULATED sandbox provider can complete a booking, and only as simulated_confirmed.',
    source: 'checklist Phase 9' },
  vendor: { area: 'Restaurant booking', tone: 'block',
    title: 'Requires a vendor partner agreement — not available',
    text: 'Real booking is Blocked (9.6): OpenTable, Yelp Reservations and SevenRooms need a partner agreement each; Resy and Tock have no sanctioned API.',
    source: 'ARCHITECTURE §8; analysis 05 Part 6; checklist 9.6' },
  calendar: { area: 'Calendar read/write', tone: 'block',
    title: 'Requires OAuth client credentials — not available',
    text: 'Real calendar read/write is Blocked (9.7) on OAuth client credentials for Google Calendar and Microsoft Graph; Google also needs sensitive-scope verification before production.',
    source: 'ARCHITECTURE §8; checklist 9.7' },
  licensing: { area: 'Licensing end to end', tone: 'dev',
    title: 'In development — not in this release',
    text: 'Driver licence states, grace and features are Tested (3.11). Licence activation, controller binding, grace, renewal, transfer and updates end to end are In progress (10.1). Catalogue price and plan inclusion are owner decisions.',
    source: 'checklist 3.11, 10.1' },
  packaging: { area: 'Packaging and store publication', tone: 'block',
    title: 'Not released or published',
    text: 'A .c4z has been built from the worktree in simulation runs, but packaging for release is In progress (10.8). Store publication is Blocked on the owner (10.12).',
    source: 'checklist 10.8, 10.12' },
  migrations: { area: 'Database migrations', tone: 'block',
    title: 'Not applied to production',
    text: 'AI Core migrations were run only on throwaway local databases. Applying them to production is the owner’s step (10.11).',
    source: 'checklist 2.16, 10.11' },
};

/* Glossary for contextual definitions (hover, focus or tap a dotted term). */
const GLOSSARY = {
  evidence: ['Evidence', 'Stored Flight Recorder event ids that a tool returned in the same conversation turn. A post-check drops any citation that was not returned in this turn.'],
  contract: ['Module contract v2', 'The driver-to-driver protocol between SmartBuildOS drivers and the Agent: discovery, pub/sub, requests and a cloud relay, on top of v1 registration and events.'],
  entitlement: ['Entitlement', 'A Driver Store licence grant for a SKU (here SBOS_AI_CORE) plus feature flags (BASE, AI_LEARNING, AI_ACTIONS, AI_CONCIERGE). The Agent answers licence questions on the controller.'],
  module: ['Module', 'A SmartBuildOS driver that registers with the Agent under a module_id (AI Core is ai_core; the Flight Recorder is flight_recorder) and receives a per-registration token.'],
  envelope: ['Envelope', 'The event format every module emits (envelope v1): event_id, event_type with an owned prefix, observed_at, severity, evidence_source, quality, payload and more.'],
  capability: ['Capability', 'A named service a module advertises in its manifest, either a request (e.g. events.query) or a topic (events.subscribe over prefixes). Consumers discover capabilities; they never assume them.'],
  manifest: ['Capability manifest', 'Optional JSON sent with SBOS_MODULE_REGISTER (≤ 2 KB, ≤ 24 capabilities) listing what a module can serve.'],
  cloudop: ['Cloud op', 'One of the closed operations AI Core may ask the Agent to relay to the platform route (ask, analyze_room, …, test_provider). Anything else is not_permitted.'],
  restricted: ['Restricted operation', 'One of six closed operations the platform may send to AI Core through the Agent (apply_config, refresh_status, deliver_result, raise_event, set_learning, run_diagnostic). None controls equipment.'],
  topic: ['Topic', 'An event-type prefix such as capture. or observation. that a module subscribes to. The Agent grants only prefixes listed for the subscriber in its topic policy.'],
  idempotency: ['Idempotency key', 'A key kept the same across retries of one request, so the Agent replays the stored answer instead of routing the request twice.'],
  risk: ['Risk class', 'Declared once per tool in the registry: read, low, high, external or programming. The permission engine reads it from the registry, never from the model.'],
  mode: ['Permission mode', 'Per-property setting in System Studio: observe (default; no actions at all), recommend (actions need approval), execute_low_risk (low-risk actions may run under a homeowner-consented rule).'],
};

/* ── small helpers ────────────────────────────────────────────────────── */
const $ = (s, r = document) => r.querySelector(s);
const $$ = (s, r = document) => Array.from(r.querySelectorAll(s));
const esc = (s) => String(s == null ? '' : s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const codeify = (s) => esc(s).replace(/`([^`]+)`/g, '<code>$1</code>');
const store = {
  get(k, d) { try { const v = window.localStorage.getItem('sbos-guide:' + k); return v === null ? d : JSON.parse(v); } catch (e) { return d; } },
  set(k, v) { try { window.localStorage.setItem('sbos-guide:' + k, JSON.stringify(v)); } catch (e) { /* storage unavailable: ignore */ } },
  del(k) { try { window.localStorage.removeItem('sbos-guide:' + k); } catch (e) { /* ignore */ } },
};
const announce = (msg) => { const l = $('#liveMsg'); if (l) { l.textContent = ''; setTimeout(() => { l.textContent = msg; }, 30); } };
const REF = JSON.parse(document.getElementById('ref-data').textContent);
const reduceMotion = () => window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;

function table(cols, rows, cls) {
  const head = '<thead><tr>' + cols.map((c) => '<th scope="col">' + c + '</th>').join('') + '</tr></thead>';
  const body = '<tbody>' + rows.map((r) => '<tr>' + r.map((c) => '<td>' + c + '</td>').join('') + '</tr>').join('') + '</tbody>';
  return '<div class="table-wrap"><table' + (cls ? ' class="' + cls + '"' : '') + '>' + head + body + '</table></div>';
}

/* ── status callouts ──────────────────────────────────────────────────── */
const TONE_ICON = {
  sim: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true"><path d="M9 3h6M10 3v6L5 19a2 2 0 0 0 1.8 3h10.4A2 2 0 0 0 19 19l-5-10V3"/></svg>',
  dev: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true"><circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 3"/></svg>',
  block: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true"><circle cx="12" cy="12" r="9"/><path d="M5.6 5.6l12.8 12.8"/></svg>',
  ok: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true"><path d="M5 12l5 5L20 7"/></svg>',
};
const TONE_WORD = { sim: 'Simulated only', dev: 'In development', block: 'Blocked', ok: 'Verified' };
function renderStatuses() {
  $$('[data-status]').forEach((el) => {
    const s = STATUS[el.dataset.status];
    if (!s) { el.textContent = 'Unknown status key ' + el.dataset.status; return; }
    el.dataset.tone = s.tone;
    el.setAttribute('role', 'note');
    el.innerHTML = TONE_ICON[s.tone] + '<div><b><span class="sr-only">' + TONE_WORD[s.tone] + ': </span>' + esc(s.title) + '</b><p>' + codeify(s.text) + '</p><small>Source: ' + esc(s.source) + '</small></div>';
  });
  const used = {};
  $$('.chapter [data-status]').forEach((el) => {
    const ch = el.closest('.chapter');
    (used[el.dataset.status] = used[el.dataset.status] || new Set()).add(ch.id);
  });
  $('#statusRows').innerHTML = Object.entries(STATUS).map(([k, s]) => {
    const where = [...(used[k] || [])].map((id) => '<a href="#' + id + '">' + esc($('#' + id).dataset.title) + '</a>').join(', ') || '—';
    return '<tr data-key="' + k + '"><td>' + esc(s.area) + '</td><td><span class="status" data-tone="' + s.tone + '" style="display:inline-block;margin:0;padding:2px 8px">' + esc(TONE_WORD[s.tone]) + '</span><br><b>' + esc(s.title) + '</b></td><td>' + codeify(s.text) + '<br><small>Source: ' + esc(s.source) + '</small></td><td>' + where + '</td></tr>';
  }).join('');
}

/* ── generated reference tables (Chapter 11, 14) ──────────────────────── */
function renderReferenceTables() {
  $('#tblCommands').innerHTML = REF.commands.map((c) => {
    const params = c.params.length ? table(['Parameter', 'Type', 'Rule', 'Values'], c.params.map((p) => ['<code>' + esc(p.name) + '</code>', esc(p.type), esc(p.rule), p.items ? p.items.map(esc).join(', ') : '—'])) : '<p>No parameters.</p>';
    return '<details class="cmd" id="cmd-' + c.name + '"><summary><code>' + esc(c.name) + '</code> <span class="type" data-t="command">command</span></summary><div class="body"><p>' + esc(c.description) + '</p><dl class="kv"><dt>Cloud op</dt><dd>' + (c.op ? '<code>' + esc(c.op) + '</code>' : 'none') + '</dd><dt>Licence feature</dt><dd><code>' + esc(c.feature) + '</code></dd></dl>' + params + (c.note ? '<p>' + codeify(c.note) + '</p>' : '') + '</div></details>';
  }).join('');
  $('#tblActions').innerHTML = table(['Action', 'Command', 'Does'], REF.actions.map((a) => ['<strong>' + esc(a.name) + '</strong>', '<code>' + esc(a.command) + '</code>', esc(a.does)]));
  $('#tblProperties').innerHTML = table(['Property', 'Default', 'Shows'], REF.properties.map((p) => ['<strong>' + esc(p.name) + '</strong>' + (p.readonly ? '' : ' <span class="type">editable</span>'), esc(p.default || '(empty)'), esc(p.items ? 'List: ' + p.items.join(', ') : p.shows)]));
  $('#tblEvents').innerHTML = table(['Id', 'Event', 'Fired when', 'Description'], REF.events.map((e) => [String(e.id), '<strong>' + esc(e.name) + '</strong>', codeify(e.fired), esc(e.description)]));
  $('#tblVariables').innerHTML = table(['Id', 'Variable', 'Type', 'Value'], REF.variables.map((v) => [String(v.id), '<code>' + esc(v.name) + '</code>', esc(v.type), esc(v.value)]));
  $('#tblConditionals').innerHTML = table(['Id', 'Conditional', 'Type', 'Statement', 'True when'], REF.conditionals.map((c) => [String(c.id), '<code>' + esc(c.name) + '</code>', esc(c.type), esc(c.statement), esc(c.meaning)]));
  $('#tblFrames').innerHTML = table(['Direction', 'Frame', 'Params', 'Answer', 'Since'], REF.frames.map((f) => [esc(f.dir), '<code>' + esc(f.name) + '</code>', esc(f.params), esc(f.answer), 'v' + f.ver]));
  $('#tblErrors').innerHTML = table(['Code', 'Meaning', 'Retry'], REF.errorCodes.map((e) => ['<code>' + esc(e.code) + '</code>', esc(e.meaning), e.retry === 'yes' ? '<strong>yes</strong>' : esc(e.retry)]), 'errors');
  $('#tblRoutes').innerHTML = table(['Method', 'Route', 'Gate', 'Does', 'State'], REF.routes.map((r) => [esc(r.method), '<code>' + esc(r.path) + '</code>', esc(r.gate), esc(r.does), esc(r.state)]));
  $('#envelopeRows').innerHTML = REF.envelope.map((f) => '<tr><td><code>' + esc(f.field) + '</code></td><td>' + esc(f.rule) + '</td></tr>').join('');
  $('#tblTools').innerHTML = REF.tools.map((t) => '<details class="tool" id="tool-' + t.wire + '"><summary><code>' + esc(t.wire) + '</code> <span class="type">' + esc(t.risk) + '</span>' + (t.household ? ' <span class="type">household</span>' : '') + '</summary><div class="body"><p>' + esc(t.description) + '</p><dl class="kv"><dt>Registry id</dt><dd><code>' + esc(t.id) + '</code></dd><dt>Risk</dt><dd><code>' + esc(t.risk) + '</code></dd><dt>Household data</dt><dd>' + (t.household ? 'yes (needs the household grant)' : 'no') + '</dd><dt>Feature</dt><dd>' + (t.feature ? '<code>' + esc(t.feature) + '</code>' : 'default for the risk class (' + (t.risk === 'read' ? 'BASE' : 'AI_ACTIONS') + ')') + '</dd>' + (t.verb ? '<dt>Queue verb</dt><dd><code>' + esc(t.verb) + '</code></dd>' : '') + '<dt>Required</dt><dd>' + (t.required.length ? t.required.map((r) => '<code>' + esc(r) + '</code>').join(', ') : 'none') + '</dd></dl>' + (t.props.length ? table(['Argument', 'Type', 'Rule'], t.props.map((p) => ['<code>' + esc(p.name) + '</code>', esc(p.type), esc(p.rule || '—')])) : '<p>No arguments.</p>') + '</div></details>').join('');
}
