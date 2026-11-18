
/* ══════════════════════════ Architecture Explorer ══════════════════════════ */
const ARCH = {
  layers: [
    { title: 'CONTROLLER (Control4 Director)', y: 8, h: 112 },
    { title: 'SMARTBUILDOS CLOUD PLATFORM', y: 132, h: 300 },
    { title: 'PEOPLE AND EXTERNAL SERVICES', y: 444, h: 112 },
  ],
  nodes: [
    { id: 'composer', label: 'Composer programming', sub: 'commands · events · variables', x: 14, y: 40, w: 168, layer: 0, status: null,
      resp: ['Calls AI Core commands such as AI_ASK and AI_RECORD_EVENT.', 'Reacts to AI Core events (AI Response Ready, Approval Required, Agent Disconnected …).', 'Wires events to the Notification Agent for push and email.'], src: 'driver.xml' },
    { id: 'aicore', label: 'AI Core driver', sub: 'module ai_core · no AI, no key', x: 198, y: 40, w: 172, layer: 0, status: 'driver',
      resp: ['Validates Composer commands and turns them into closed cloud ops.', 'Shows results and platform events to programming.', 'Collects only what the Flight Recorder lacks (Director system events).', 'Buffers critical events while the Agent is away; reports health.', 'Never controls equipment: every SendToDevice goes to the Agent.'], src: 'drivers/smartbuildos-ai-core, src/aicore/*.lua' },
    { id: 'agent', label: 'SmartBuildOS Agent', sub: 'hub · contract v2 · licence', x: 386, y: 40, w: 172, layer: 0, status: 'protocol',
      resp: ['Registers modules, mints tokens, stamps senders.', 'Routes requests and fans out subscriptions under closed policy tables.', 'Relays cloud ops to one fixed platform route with its pairing token.', 'Forwards configuration and restricted operations; executes the command queue.', 'Durable event queue to the cloud.'], src: 'src/sbos/module*.lua, drivers/smartbuildos/driver.lua' },
    { id: 'fr', label: 'Flight Recorder driver', sub: 'module flight_recorder', x: 574, y: 40, w: 172, layer: 0, status: 'frLocal',
      resp: ['Captures device events, variables and programming traces.', 'Serves its recent local ring: events.query, events.timeline, events.device_history, events.room_activity.', 'Publishes capture., observation., trace. topics to AI Core.'], src: 'src/flightrecorder/localquery.lua' },
    { id: 'rpc', label: 'Controller RPC route', sub: '/modules/rpc', x: 14, y: 164, w: 168, layer: 1, status: 'rpc',
      resp: ['Authenticates the Agent pairing token; derives tenant and property from it only.', 'Closed op vocabulary; unique on (system, module, idempotency key).', 'Answers HTTP 200 for every business outcome.'], src: 'src/app/api/integrations/control4/modules/rpc/route.ts' },
    { id: 'jobs', label: 'Jobs', sub: 'ai_core_jobs', x: 198, y: 164, w: 168, layer: 1, status: 'rpc',
      resp: ['Accepted ops answer {accepted, job_id} at once and are processed afterwards.', 'Results go back through deliver_result / raise_event.'], src: 'src/lib/ai-core/jobs.ts, rpc/ops.ts' },
    { id: 'orch', label: 'Orchestrator', sub: 'bounded turn loop', x: 382, y: 164, w: 168, layer: 1, status: 'orchestrator',
      resp: ['Static system prompt (no tenant data); fixed tool list per turn.', 'At most 4 rounds by default (ceiling 8); budget check before every call.', 'Structured answer with confirmed / possible / unknowns; evidence post-check.'], src: 'src/lib/ai-core/orchestrator/' },
    { id: 'prov', label: 'Provider layer', sub: 'Anthropic · OpenAI', x: 566, y: 164, w: 180, layer: 1, status: 'providers',
      resp: ['Neutral types over Messages (Anthropic) and Responses with store:false (OpenAI).', 'Model classes deep / fast; retry, timeout and fallback; versioned prices.', 'Re-validates every tool argument; redacts key material.'], src: 'src/lib/ai-core/providers/' },
    { id: 'tools', label: 'Tool registry', sub: '35 tools', x: 14, y: 254, w: 168, layer: 1, status: 'cloudTools',
      resp: ['Seven Flight Recorder read tools; device, room, usage and health reads; memory search and proposals; service findings; a notification request; six action proposals; eleven concierge tools (in development).', 'Each tool declares its risk once; closed argument schemas.'], src: 'src/lib/ai-core/tools/' },
    { id: 'authz', label: 'Permission engine', sub: 'allow · approval · deny', x: 198, y: 254, w: 168, layer: 1, status: null,
      resp: ['Pure function over actor, mode, risk, target class, capabilities, features, rules, basis and gate.', 'Fails closed on anything unrecognised.', 'Tested with 108 matrix tests (checklist 7.1).'], src: 'src/lib/ai-core/authz/engine.ts' },
    { id: 'learn', label: 'Learning', sub: 'memory · patterns · recs', x: 382, y: 254, w: 168, layer: 1, status: 'learning',
      resp: ['14 deterministic detectors with sample-size confidence.', 'Four memory categories, verified vs inferred.', 'Homeowner pause, exclusions, correction, export and erase.'], src: 'src/lib/ai-core/{memory,patterns,recommendations}/' },
    { id: 'vault', label: 'Vault · settings · budget', sub: 'keys never leave', x: 566, y: 254, w: 180, layer: 1, status: 'providers',
      resp: ['Customer keys as secret-box ciphertext, masked ••••last4.', 'Per-property settings published to the driver as a non-secret document.', 'Blocking spend and rate limits in the database.'], src: 'src/lib/ai-core/{credentials,settings,budget}/' },
    { id: 'frstore', label: 'Flight Recorder store', sub: 'flight_recorder_events', x: 14, y: 344, w: 168, layer: 1, status: 'frRetention',
      resp: ['The cloud copy of every uploaded envelope (30-day default retention, not yet scheduled).', 'Read by the history tools through the timeline library.'], src: 'flight_recorder_events' },
    { id: 'actions', label: 'Actions → queue', sub: 'control4_commands', x: 198, y: 344, w: 168, layer: 1, status: 'actions',
      resp: ['Proposal → approval → queued in the existing control4_commands queue with AI provenance.', 'Completed / failed only from the driver’s acknowledgement.', 'Programming changes become hand-offs, never executed.'], src: 'src/lib/ai-core/actions/' },
    { id: 'audit', label: 'Audit', sub: 'ai_core_audit_events', x: 382, y: 344, w: 168, layer: 1, status: null,
      resp: ['Append-only record of turns, provider calls, refusals and tool decisions.', 'A tool decision is written before its handler runs; an unrecorded action is not taken.'], src: 'src/lib/ai-core/audit/' },
    { id: 'studio', label: 'System Studio', sub: 'Intelligence pages', x: 14, y: 478, w: 230, layer: 2, status: 'studio',
      resp: ['Staff enter provider keys, settings, limits and the permission mode.', 'Overview, Household Usage, Flight Recorder Intelligence (in development).', 'Staff approve low-risk actions a person asked for.'], src: '/api/monitoring/ai-core/*' },
    { id: 'portal', label: 'Homeowner portal', sub: 'approvals · learning controls', x: 262, y: 478, w: 230, layer: 2, status: 'portalUi',
      resp: ['Approves lock, garage and security actions.', 'Consents to pre-approved rules.', 'Reviews, corrects, exports and erases what was learned.'], src: '/api/portal/ai-core/*' },
    { id: 'vendors', label: 'Anthropic · OpenAI', sub: 'customer’s own account', x: 510, y: 478, w: 236, layer: 2, status: 'providers',
      resp: ['Called only from the cloud, with the customer’s key.', 'No live call has been made yet (needs a real key).'], src: 'providers/anthropic.ts, providers/openai.ts' },
  ],
  wires: [['composer', 'aicore'], ['aicore', 'agent'], ['fr', 'agent'], ['agent', 'rpc'], ['agent', 'frstore'], ['rpc', 'jobs'], ['jobs', 'orch'], ['orch', 'prov'], ['prov', 'vendors'], ['vault', 'prov'], ['orch', 'tools'], ['tools', 'authz'], ['tools', 'frstore'], ['tools', 'learn'], ['tools', 'actions'], ['actions', 'agent'], ['orch', 'audit'], ['studio', 'vault'], ['studio', 'learn'], ['studio', 'actions'], ['portal', 'learn'], ['portal', 'actions'], ['jobs', 'agent']],
};
function initArch() {
  const H = 50;
  const nodeById = Object.fromEntries(ARCH.nodes.map((n) => [n.id, n]));
  const center = (n) => ({ x: n.x + n.w / 2, y: n.y + H / 2 });
  let svg = '<svg viewBox="0 0 760 564" role="group" aria-label="AI Core architecture: three layers of components">';
  ARCH.layers.forEach((l) => { svg += '<g class="layer"><rect class="band" x="4" y="' + l.y + '" width="752" height="' + l.h + '" rx="10"/><text class="title" x="16" y="' + (l.y + 20) + '">' + l.title + '</text></g>'; });
  ARCH.wires.forEach(([a, b]) => { const p = center(nodeById[a]), q = center(nodeById[b]); svg += '<line class="wire" data-a="' + a + '" data-b="' + b + '" x1="' + p.x + '" y1="' + p.y + '" x2="' + q.x + '" y2="' + q.y + '"/>'; });
  ARCH.nodes.forEach((n) => {
    const tone = n.status && STATUS[n.status] && STATUS[n.status].tone === 'dev' ? ' data-tone="dev"' : '';
    svg += '<g class="node" tabindex="0" role="button" aria-pressed="false" data-id="' + n.id + '"' + tone + ' aria-label="' + esc(n.label + ': ' + n.sub) + '"><rect x="' + n.x + '" y="' + n.y + '" width="' + n.w + '" height="' + H + '" rx="8"/><text x="' + (n.x + 10) + '" y="' + (n.y + 21) + '">' + esc(n.label) + '</text><text class="sub" x="' + (n.x + 10) + '" y="' + (n.y + 38) + '">' + esc(n.sub) + '</text></g>';
  });
  svg += '</svg>';
  $('#archSvgHost').innerHTML = svg + '<div class="chips" style="margin-top:10px" role="group" aria-label="Components as a list">' + ARCH.nodes.map((n) => '<button type="button" class="chip arch-chip" data-id="' + n.id + '" aria-pressed="false">' + esc(n.label) + '</button>').join('') + '</div>';
  function select(id) {
    const n = nodeById[id];
    const related = ARCH.wires.filter(([a, b]) => a === id || b === id).map(([a, b]) => (a === id ? b : a));
    $$('#archSvgHost .node').forEach((g) => { g.setAttribute('aria-pressed', g.dataset.id === id ? 'true' : 'false'); g.classList.toggle('related', related.includes(g.dataset.id)); });
    $$('#archSvgHost .arch-chip').forEach((b) => b.setAttribute('aria-pressed', b.dataset.id === id ? 'true' : 'false'));
    $$('#archSvgHost .wire').forEach((w) => w.classList.toggle('on', w.dataset.a === id || w.dataset.b === id));
    const st = n.status ? STATUS[n.status] : null;
    $('#archPanel').innerHTML = '<h4 data-node="' + id + '">' + esc(n.label) + '</h4><p><small>' + esc(n.sub) + '</small></p><ul>' + n.resp.map((r) => '<li>' + esc(r) + '</li>').join('') + '</ul><p><strong>Connects to:</strong> ' + related.map((r) => '<button type="button" class="chip arch-jump" data-id="' + r + '">' + esc(nodeById[r].label) + '</button>').join(' ') + '</p><p><small>Source: <code>' + esc(n.src) + '</code></small></p>' + (st ? '<div class="status" data-tone="' + st.tone + '" role="note">' + TONE_ICON[st.tone] + '<div><b>' + esc(st.title) + '</b></div></div>' : '');
  }
  $('#archSvgHost').addEventListener('click', (e) => { const g = e.target.closest('[data-id]'); if (g) select(g.dataset.id); });
  $('#archSvgHost').addEventListener('keydown', (e) => { const g = e.target.closest('.node'); if (g && (e.key === 'Enter' || e.key === ' ')) { e.preventDefault(); select(g.dataset.id); } });
  $('#archPanel').addEventListener('click', (e) => { const b = e.target.closest('.arch-jump'); if (b) { select(b.dataset.id); const g = $('#archSvgHost .node[data-id="' + b.dataset.id + '"]'); if (g) g.focus(); } });
}

/* ══════════════════════════ Driver Communication Explorer ══════════════════════════ */
const LANES = [{ id: 'ai', label: 'AI Core' }, { id: 'agent', label: 'Agent' }, { id: 'fr', label: 'Flight Recorder' }, { id: 'cloud', label: 'SmartBuildOS cloud' }];
const AUTH = (m, i) => ({ module_id: m, instance_id: i, token: '<token>' });
const COMM = [
  { id: 'register', title: 'Registration (v2)', summary: 'AI Core registers with its manifest, receives its token and the last configuration, and the Agent tells other v2 modules the directory changed.', steps: [
    { f: 'ai', t: 'agent', frame: 'SBOS_MODULE_REGISTER', p: { module_id: 'ai_core', instance_id: '412', driver_version: '<built version>', protocol_min: '1', protocol_max: '2', entitlements: 'SBOS_AI_CORE', event_types: 'ai_core.', singleton: 'true', manifest: { driver: 'sbos.ai_core', protocol: 2, capabilities: [] } }, n: 'Sent on every LateInit; retried every 30 s doubling to 5 min while there is no answer.' },
    { f: 'agent', t: 'ai', frame: 'SBOS_MODULE_REGISTERED', p: { ok: 'true', token: '<32 hex characters>', protocol: '2', agent_protocol_min: '1', agent_protocol_max: '2', paired: 'true', connected: 'true' }, n: 'Sent to the claimed device id. A new token ends any earlier session. AGENT_CONNECTED becomes true.' },
    { f: 'agent', t: 'ai', frame: 'SBOS_DRIVER_CONFIG', p: { sku: 'SBOS_AI_CORE', settings: { schema: 1, permission_mode: 'recommend', learning: { active: false } }, settings_version: '7' }, n: 'The last configuration System Studio published for this SKU.' },
    { f: 'ai', t: 'agent', frame: 'SBOS_DRIVER_CONFIG_ACK', p: { sku: 'SBOS_AI_CORE', applied: 'true', refused: '0', settings_version: '7' }, n: 'The whole document was valid, so it is applied. One bad field would refuse it all.' },
    { f: 'agent', t: 'fr', frame: 'SBOS_MODULE_DIRECTORY_CHANGED', p: { ...AUTH('flight_recorder', '388'), directory_version: '15' }, n: 'Pushed to live v2 modules 5 s after the first change of a burst.' },
  ] },
  { id: 'discover', title: 'Capability discovery', summary: 'AI Core asks the Agent which modules serve what. The same frame is its liveness probe.', steps: [
    { f: 'ai', t: 'agent', frame: 'SBOS_MODULE_DISCOVER', p: { ...AUTH('ai_core', '412'), request_id: 'aic-d-0193', filter: { module_id: 'flight_recorder' } }, n: 'Counts against AI Core’s request bucket (30/min, burst 10).' },
    { f: 'agent', t: 'ai', frame: 'SBOS_MODULE_DIRECTORY', p: { ...AUTH('ai_core', '412'), request_id: 'aic-d-0193', error_code: 'ok', directory_version: '15', agent: { version: '<agent version>', protocol_min: 1, protocol_max: 2, paired: true, connected: true }, modules: [{ module_id: 'flight_recorder', instance_id: '388', driver: 'sbos.flight_recorder', protocol: 2, status: 'online', stale: false, capabilities: ['events.query', 'events.timeline', 'events.device_history', 'events.room_activity', 'events.subscribe'] }], truncated: 'false' }, n: 'Tokens are never included. Flight Recorder Link becomes "Installed: local history served; topics subscribed" once subscribed.' },
  ] },
  { id: 'pubsub', title: 'Subscribe and publish', summary: 'AI Core subscribes to the recorder’s topics; the Agent fans out envelopes it accepted from the recorder.', steps: [
    { f: 'ai', t: 'agent', frame: 'SBOS_MODULE_SUBSCRIBE', p: { ...AUTH('ai_core', '412'), subscription_id: 'fr', topics: ['capture.', 'observation.', 'trace.'] }, n: 'Each topic is checked against MODULE_TOPIC_POLICY.' },
    { f: 'agent', t: 'ai', frame: 'SBOS_MODULE_SUBSCRIBED', p: { ...AUTH('ai_core', '412'), subscription_id: 'fr', ok: 'true', reason: 'ok', granted: ['capture.', 'observation.', 'trace.'], refused: [] }, n: 'All granted.' },
    { f: 'fr', t: 'agent', frame: 'SBOS_MODULE_EVENTS', p: { ...AUTH('flight_recorder', '388'), batch_id: 'b-5521', events: [{ event_type: 'capture.event', device_id: 214, '…': '…' }] }, n: 'The recorder’s normal durable upload path.' },
    { f: 'agent', t: 'fr', frame: 'SBOS_MODULE_EVENTS_ACK', p: { batch_id: 'b-5521', accepted: '1', rejected: '0', duplicates: '0' }, n: 'Only accepted envelopes are ever published.' },
    { f: 'agent', t: 'ai', frame: 'SBOS_MODULE_PUBLISH', p: { ...AUTH('ai_core', '412'), subscription_id: 'fr', events: [{ event_type: 'capture.event', device_id: 214, '…': '…' }], dropped: '0' }, n: 'Best-effort, at-most-once; ≤ 25 envelopes per frame, sent 1 s after the first buffered one. AI Core uses it locally and does not re-upload it.' },
  ] },
  { id: 'request', title: 'Request / response', summary: 'AI Core asks the Flight Recorder for one device’s local history (as AI_START_DIAGNOSTIC does).', steps: [
    { f: 'ai', t: 'agent', frame: 'SBOS_MODULE_REQUEST', p: { ...AUTH('ai_core', '412'), request_id: 'aic-r-7f01', idempotency_key: 'aic-r-7f01', to: 'flight_recorder', capability: 'events.device_history', args: { device_id: 214, limit: 25 }, deadline: '<now + 10 s>' }, n: 'Diagnostics use a 10 s timeout and 1 retry.' },
    { f: 'agent', t: 'ai', frame: 'SBOS_MODULE_REQUEST_ACK', p: { ...AUTH('ai_core', '412'), request_id: 'aic-r-7f01', state: 'Routed', error_code: 'ok' }, n: 'Policy allows ai_core → events.device_history; flight_recorder is the sanctioned provider and is live at v2.' },
    { f: 'agent', t: 'fr', frame: 'SBOS_MODULE_REQUEST', p: { ...AUTH('flight_recorder', '388'), request_id: 'aic-r-7f01', idempotency_key: 'aic-r-7f01', from_module_id: 'ai_core', from_instance_id: '412', capability: 'events.device_history', args: { device_id: 214, limit: 25 }, deadline: '<same>' }, n: 'Rebuilt field by field; the sender is stamped by the Agent.' },
    { f: 'fr', t: 'agent', frame: 'SBOS_MODULE_RESPONSE', p: { ...AUTH('flight_recorder', '388'), request_id: 'aic-r-7f01', status: 'ok', error_code: 'ok', result: { capability: 'events.device_history', count: 25, has_more: true, order: 'desc', truncated: false, events: ['…'] }, cursor: 'h3.d.10388' }, n: 'Only the instance the request was routed to may answer.' },
    { f: 'agent', t: 'ai', frame: 'SBOS_MODULE_RESPONSE', p: { ...AUTH('ai_core', '412'), request_id: 'aic-r-7f01', status: 'ok', error_code: 'ok', result: { '…': '…' }, cursor: 'h3.d.10388', from_module_id: 'flight_recorder', from_instance_id: '388', replayed: 'false' }, n: 'AI Core records one ai_core.diagnostic envelope with these events (≤ 4 KB, oldest cut first, counted in omitted).' },
  ] },
  { id: 'cloud', title: 'Cloud relay (AI_ASK)', summary: 'A Composer AI_ASK becomes a closed cloud op; the answer comes back later as a restricted operation.', steps: [
    { f: 'ai', t: 'ai', frame: 'local: validate AI_ASK', p: { QUESTION: 'Why did the living room lights turn on at 2 AM?', ROOM: 'Living Room' }, n: 'Validated; request_id aic-<uuid> written to AI_LAST_REQUEST_ID; an ai_core.command envelope is recorded.' },
    { f: 'ai', t: 'agent', frame: 'SBOS_MODULE_CLOUD_REQUEST', p: { ...AUTH('ai_core', '412'), request_id: 'aic-3f1c', idempotency_key: 'aic-3f1c', op: 'ask', body: { command: 'AI_ASK', request_id: 'aic-3f1c', question: 'Why did the living room lights turn on at 2 AM?', room_id: 12, room_name: 'Living Room' }, deadline: '<now + 30 s>' }, n: 'op ask is in MODULE_CLOUD_OPS.ai_core.' },
    { f: 'agent', t: 'cloud', frame: 'POST /api/integrations/control4/modules/rpc', p: { module_id: 'ai_core', instance_id: '412', op: 'ask', request_id: 'aic-3f1c', idempotency_key: 'aic-3f1c', body: { '…': '…' } }, n: 'Authorization: Bearer <pairing token>. Tenant and property come from the token only.' },
    { f: 'cloud', t: 'agent', frame: 'HTTP 200', p: { ok: true, result: { accepted: true, job_id: 'job-81c2' } }, n: 'In the committed code only status is handled; this accepted answer is what the in-development job ops return.' },
    { f: 'agent', t: 'ai', frame: 'SBOS_MODULE_CLOUD_RESPONSE', p: { ...AUTH('ai_core', '412'), request_id: 'aic-3f1c', status: 'ok', http_status: '200', error_code: 'ok', result: { accepted: true, job_id: 'job-81c2' } }, n: 'AI Status: Working: 1 request(s) waiting for a result; AI_STATUS = working.' },
    { f: 'agent', t: 'ai', frame: 'SBOS_MODULE_COMMAND', p: { ...AUTH('ai_core', '412'), request_id: '<server uuid>', command: 'deliver_result', args: { response_id: 'resp-55', request_id: 'aic-3f1c', job_id: 'job-81c2', kind: 'answer', text: '…' }, expires_at: '<now + 10 min>' }, n: 'Later: the platform queues the result as a restricted operation.' },
    { f: 'ai', t: 'agent', frame: 'SBOS_MODULE_COMMAND_RESULT', p: { ...AUTH('ai_core', '412'), request_id: '<server uuid>', state: 'Completed' }, n: 'AI_LAST_RESPONSE and AI_LAST_RESPONSE_ID set; AI Response Ready fires.' },
  ] },
  { id: 'refused', title: 'Refused by policy', summary: 'A module that is not listed for an op is refused by the Agent; nothing reaches the cloud.', steps: [
    { f: 'fr', t: 'agent', frame: 'SBOS_MODULE_CLOUD_REQUEST', p: { ...AUTH('flight_recorder', '388'), request_id: 'fr-c-01', idempotency_key: 'fr-c-01', op: 'ask', body: { question: '…' }, deadline: '<now + 30 s>' }, n: 'MODULE_CLOUD_OPS lists ask only for ai_core.' },
    { f: 'agent', t: 'fr', frame: 'SBOS_MODULE_CLOUD_RESPONSE', p: { ...AUTH('flight_recorder', '388'), request_id: 'fr-c-01', status: 'error', http_status: '', error_code: 'not_permitted' }, n: 'not_permitted is final: never retried.', err: true },
    { f: 'ai', t: 'agent', frame: 'SBOS_MODULE_SUBSCRIBE', p: { ...AUTH('ai_core', '412'), subscription_id: 'x', topics: ['agent.'] }, n: 'agent. is not in MODULE_TOPIC_POLICY for ai_core.' },
    { f: 'agent', t: 'ai', frame: 'SBOS_MODULE_SUBSCRIBED', p: { ...AUTH('ai_core', '412'), subscription_id: 'x', ok: 'false', reason: 'not_permitted', granted: [], refused: ['agent.'] }, n: 'None granted → ok = false.', err: true },
  ] },
  { id: 'deadline', title: 'Deadline exceeded and retry', summary: 'The Flight Recorder does not answer in time; the client retries once with the same key, then gives up.', steps: [
    { f: 'ai', t: 'agent', frame: 'SBOS_MODULE_REQUEST', p: { ...AUTH('ai_core', '412'), request_id: 'aic-r-a1', idempotency_key: 'diag-k1', to: 'flight_recorder', capability: 'events.room_activity', args: { room_id: 12, limit: 25 }, deadline: '<now + 10 s>' }, n: '' },
    { f: 'agent', t: 'ai', frame: 'SBOS_MODULE_REQUEST_ACK', p: { request_id: 'aic-r-a1', state: 'Routed', error_code: 'ok' }, n: '' },
    { f: 'agent', t: 'fr', frame: 'SBOS_MODULE_REQUEST', p: { request_id: 'aic-r-a1', from_module_id: 'ai_core', capability: 'events.room_activity' }, n: 'No answer arrives.' },
    { f: 'ai', t: 'ai', frame: 'local timer: deadline_exceeded', p: { request_id: 'aic-r-a1', error_code: 'deadline_exceeded' }, n: 'The requester’s own timer fires at the deadline. deadline_exceeded is retryable.', err: true },
    { f: 'ai', t: 'agent', frame: 'SBOS_MODULE_REQUEST', p: { request_id: 'aic-r-a2', idempotency_key: 'diag-k1', to: 'flight_recorder', capability: 'events.room_activity', deadline: '<now + 10 s>' }, n: 'Retry after 2 s: fresh request_id, SAME idempotency key. The Agent routes it again because the old attempt passed its deadline.' },
    { f: 'ai', t: 'ai', frame: 'local timer: deadline_exceeded', p: { request_id: 'aic-r-a2', error_code: 'deadline_exceeded' }, n: 'Diagnostics allow 1 retry, so the call is final now.', err: true },
    { f: 'ai', t: 'agent', frame: 'SBOS_MODULE_EVENTS', p: { events: [{ event_type: 'ai_core.diagnostic', payload: { flight_recorder: { available: false, reason: 'request_failed', error_code: 'deadline_exceeded' } } }] }, n: 'The diagnostic envelope says why nothing is attached.' },
  ] },
  { id: 'restart', title: 'Agent restart', summary: 'The Agent restarts: tokens, routes and subscriptions are lost; AI Core re-registers and re-subscribes.', steps: [
    { f: 'ai', t: 'agent', frame: 'SBOS_MODULE_REQUEST', p: { request_id: 'aic-r-b1', idempotency_key: 'k-b1', to: 'flight_recorder', capability: 'events.query', deadline: '<now + 10 s>' }, n: 'In flight when the Agent restarts.' },
    { f: 'agent', t: 'ai', frame: 'SBOS_MODULE_AGENT_HELLO', p: { agent_version: '<agent version>' }, n: 'Sent from the Agent’s LateInit to every known instance. AGENT_CONNECTED true → false fires Agent Disconnected.' },
    { f: 'ai', t: 'agent', frame: 'SBOS_MODULE_REGISTER', p: { module_id: 'ai_core', instance_id: '412', protocol_min: '1', protocol_max: '2', manifest: { driver: 'sbos.ai_core' } }, n: 'Re-registration; frames carrying the old token are ignored from now on.' },
    { f: 'agent', t: 'ai', frame: 'SBOS_MODULE_REGISTERED', p: { ok: 'true', token: '<new token>', protocol: '2' }, n: '' },
    { f: 'ai', t: 'agent', frame: 'SBOS_MODULE_SUBSCRIBE', p: { subscription_id: 'fr', topics: ['capture.', 'observation.', 'trace.'] }, n: 'The client re-sends every subscription it holds.' },
    { f: 'ai', t: 'ai', frame: 'local timer: target_unavailable', p: { request_id: 'aic-r-b1', error_code: 'target_unavailable' }, n: 'The request in flight across the restart fails at its deadline; retryable.', err: true },
  ] },
];
function initComm() {
  const sel = $('#commScenario');
  sel.innerHTML = COMM.map((s) => '<option value="' + s.id + '">' + esc(s.title) + '</option>').join('');
  let pos = -1, timer = null;
  const laneX = (id) => 95 + LANES.findIndex((l) => l.id === id) * 190;
  function sc() { return COMM.find((s) => s.id === sel.value); }
  function draw() {
    const s = sc();
    const rowH = 38, top = 46, h = top + s.steps.length * rowH + 16;
    let svg = '<svg viewBox="0 0 760 ' + h + '" role="img" aria-label="Message sequence for ' + esc(s.title) + '">';
    LANES.forEach((l) => { const x = laneX(l.id); svg += '<text class="lane-label" x="' + x + '" y="20" text-anchor="middle">' + l.label + '</text><line class="lane" x1="' + x + '" y1="30" x2="' + x + '" y2="' + (h - 6) + '"/>'; });
    s.steps.forEach((st, i) => {
      const y = top + i * rowH + 18, x1 = laneX(st.f), x2 = laneX(st.t);
      const cls = 'msg ' + (i < pos ? 'past' : i === pos ? 'cur' : 'future') + (st.err ? ' err' : '');
      let body;
      if (st.f === st.t) body = '<path class="local" d="M' + x1 + ' ' + (y - 8) + ' h40 v16 h-40"/><text x="' + (x1 + 46) + '" y="' + (y + 4) + '">' + esc(st.frame) + '</text>';
      else { const dir = x2 > x1 ? 1 : -1; body = '<line x1="' + x1 + '" y1="' + y + '" x2="' + (x2 - dir * 6) + '" y2="' + y + '"/><path d="M' + x2 + ' ' + y + ' l' + (-dir * 8) + ' -5 v10 z" fill="currentColor"/><text x="' + ((x1 + x2) / 2) + '" y="' + (y - 6) + '" text-anchor="middle">' + esc(st.frame) + '</text>'; }
      svg += '<g class="' + cls + '" data-i="' + i + '" style="color:' + (i === pos ? 'var(--sw-orange)' : 'var(--sw-rule-strong)') + '">' + body + '</g>';
    });
    svg += '</svg>';
    $('#commSvgHost').innerHTML = svg;
    $('#commSummary').textContent = s.summary;
    $('#commPos').textContent = pos < 0 ? 'Not started · ' + s.steps.length + ' frames' : 'Frame ' + (pos + 1) + ' of ' + s.steps.length + (pos === s.steps.length - 1 ? ' · end of scenario' : '');
    $('#commPrev').disabled = pos < 0; $('#commNext').disabled = pos >= s.steps.length - 1;
    if (pos < 0) $('#commDetail').innerHTML = '<h4>Press Next to send the first frame</h4><p>' + esc(s.summary) + '</p>';
    else {
      const st = s.steps[pos];
      const from = LANES.find((l) => l.id === st.f).label, to = LANES.find((l) => l.id === st.t).label;
      $('#commDetail').innerHTML = '<h4 data-frame="' + esc(st.frame) + '">' + esc(st.frame) + '</h4><p>' + esc(from) + (st.f === st.t ? ' (local)' : ' → ' + esc(to)) + (st.err ? ' · <span class="err">error path</span>' : '') + '</p>' + (st.n ? '<p>' + esc(st.n) + '</p>' : '') + '<pre class="code" data-lang="params"><code>' + esc(JSON.stringify(st.p, null, 2)) + '</code></pre>';
      decorateCode($('#commDetail'));
    }
  }
  function stop() { clearInterval(timer); timer = null; $('#commPlay').setAttribute('aria-pressed', 'false'); $('#commPlay').textContent = 'Play'; }
  sel.addEventListener('change', () => { stop(); pos = -1; draw(); });
  $('#commNext').addEventListener('click', () => { if (pos < sc().steps.length - 1) { pos++; draw(); } });
  $('#commPrev').addEventListener('click', () => { if (pos >= 0) { pos--; draw(); } });
  $('#commReset').addEventListener('click', () => { stop(); pos = -1; draw(); });
  $('#commPlay').addEventListener('click', () => {
    if (timer) { stop(); return; }
    if (pos >= sc().steps.length - 1) pos = -1;
    $('#commPlay').setAttribute('aria-pressed', 'true'); $('#commPlay').textContent = 'Pause';
    const tick = () => { if (pos < sc().steps.length - 1) { pos++; draw(); } if (pos >= sc().steps.length - 1) stop(); };
    tick();
    if (timer === null && pos < sc().steps.length - 1) timer = setInterval(tick, reduceMotion() ? 2500 : 1400);
  });
  draw();
}

/* ══════════════════════════ Telemetry Explorer ══════════════════════════ */
const FIELD_HELP = Object.fromEntries(REF.envelope.map((f) => [f.field, f.rule]));
const TELE_SAMPLE = [
  ['ai_core:412:c2:2190', 'ai_core.status', 'info', 'derived', 'confirmed', null, null, '2026-11-17T01:00:03Z', 'AI Core ready', { state: 'ready', previous_state: 'registering' }],
  ['flight_recorder:388:b7:10398', 'observation.system', 'notice', 'system', 'confirmed', null, null, '2026-11-17T01:58:40Z', 'director_reloaded', { name: 'director_reloaded' }],
  ['flight_recorder:388:b7:10432', 'observation.programmed', 'info', 'instrumented', 'unreviewed_text', null, 15, '2026-11-17T02:03:09Z', 'Hallway night path', { message: 'Hallway night path' }, 'tr-88'],
  ['flight_recorder:388:b7:10433', 'capture.event', 'info', 'observed', 'confirmed', 214, 12, '2026-11-17T02:03:11Z', 'Living Room Dimmer — level changed', { device_event_id: 1 }, 'tr-88'],
  ['flight_recorder:388:b7:10434', 'observation.change', 'info', 'observed', 'confirmed', 214, 12, '2026-11-17T02:03:11Z', 'LIGHT_LEVEL 0 → 40', { variable: 'LIGHT_LEVEL', value: 40, previous: 0 }],
  ['ai_core:412:c2:2201', 'ai_core.observation.system', 'critical', 'system', 'unreviewed_text', 41, null, '2026-11-17T03:12:05Z', 'OnDeviceOffline', { name: 'OnDeviceOffline', id: 49 }],
  ['ai_core:412:c2:2209', 'ai_core.observation.system', 'info', 'system', 'unreviewed_text', 41, null, '2026-11-17T03:19:40Z', 'OnDeviceOnline', { name: 'OnDeviceOnline', id: 48 }],
  ['ai_core:412:c2:2215', 'ai_core.command', 'info', 'requested', 'confirmed', null, 12, '2026-11-17T07:30:00Z', 'AI_ASK', { command: 'AI_ASK', op: 'ask', request_id: 'aic-3f1c', args: { question: 'Why did the living room lights turn on at 2 AM?', room_id: 12 } }, 'aic-3f1c'],
  ['ai_core:412:c2:2216', 'ai_core.record', 'info', 'instrumented', 'unreviewed_text', null, 15, '2026-11-17T22:00:00Z', 'Goodnight started', { name: 'Goodnight started', category: 'lighting' }],
  ['ai_core:412:c2:2217', 'ai_core.record', 'warning', 'instrumented', 'unreviewed_text', null, 3, '2026-11-17T22:05:00Z', 'Garage left open reminder', { name: 'Garage left open reminder', category: 'safety' }],
  ['ai_core:412:c2:2220', 'ai_core.diagnostic', 'info', 'derived', 'partial', 214, 12, '2026-11-18T08:10:00Z', 'Diagnostic: Living Room Dimmer', { request_id: 'aic-9a', flight_recorder: { available: true, capability: 'events.device_history', truncated: false, omitted: 3 }, note: 'local Flight Recorder history only; causes are not inferred on the controller' }],
  ['flight_recorder:388:b7:10500', 'observation.initial', 'debug', 'initial', 'confirmed', 31, 4, '2026-11-18T08:11:00Z', 'Kitchen Pendants initial read', { variable: 'LIGHT_LEVEL', value: 0 }],
  ['flight_recorder:388:b7:10501', 'recorder.budget_exceeded', 'warning', 'derived', 'confirmed', null, null, '2026-11-18T08:12:00Z', 'Event budget exceeded this minute', { dropped: 14 }],
  ['agent:1:a9:5512', 'agent.command_state', 'info', 'system', 'confirmed', null, null, '2026-11-18T08:15:00Z', 'deliver_result Completed', { state: 'Completed', command: 'deliver_result' }, 'srv-1a2b'],
  ['ai_core:412:c2:2231', 'ai_core.observation.agent', 'notice', 'system', 'confirmed', null, null, '2026-11-18T08:20:00Z', 'cloud_disconnected', { name: 'cloud_disconnected' }],
  ['ai_core:412:c2:2232', 'ai_core.status', 'warning', 'derived', 'confirmed', null, null, '2026-11-18T08:20:01Z', 'AI Core: cloud unreachable', { state: 'cloud_unreachable', previous_state: 'ready' }],
].map(([event_id, event_type, severity, evidence_source, quality, device_id, room_id, observed_at, label, payload, correlation_id]) => {
  const [module_id, inst, boot, seq] = event_id.split(':');
  const e = { event_id, schema_version: 1, event_type, module_id, source_driver_instance_id: inst, installation_id: 'sys-7c41', observed_at, boot_id: boot, sequence: Number(seq), severity, evidence_source, quality, label, payload };
  if (device_id !== null) e.device_id = device_id; if (room_id !== null) e.room_id = room_id; if (correlation_id) e.correlation_id = correlation_id;
  return e;
});
function initTelemetry() {
  const prefixes = ['ai_core.', 'capture.', 'observation.', 'recorder.', 'agent.'];
  $('#teleType').innerHTML = '<option value="">All prefixes</option>' + prefixes.map((p) => '<option>' + p + '</option>').join('');
  $('#teleSev').innerHTML = '<option value="">All severities</option>' + ['debug', 'info', 'notice', 'warning', 'error', 'critical'].map((s) => '<option>' + s + '</option>').join('');
  $('#teleEv').innerHTML = '<option value="">All sources</option>' + ['observed', 'initial', 'requested', 'instrumented', 'derived', 'system'].map((s) => '<option>' + s + '</option>').join('');
  let selected = null;
  function apply() {
    const tp = $('#teleType').value, sv = $('#teleSev').value, ev = $('#teleEv').value, tx = $('#teleText').value.trim().toLowerCase();
    const list = TELE_SAMPLE.filter((e) => (!tp || e.event_type.startsWith(tp)) && (!sv || e.severity === sv) && (!ev || e.evidence_source === ev) && (!tx || JSON.stringify(e).toLowerCase().includes(tx)));
    $('#teleCount').textContent = list.length + ' of ' + TELE_SAMPLE.length + ' sample events';
    $('#teleList').innerHTML = list.length ? list.map((e) => '<li><button type="button" data-id="' + esc(e.event_id) + '" aria-pressed="' + (selected === e.event_id ? 'true' : 'false') + '"><code>' + esc(e.event_type) + '</code><span>' + esc(e.label) + '</span><small>' + esc(e.observed_at) + ' · <span class="sev" data-s="' + e.severity + '">' + e.severity + '</span> · ' + e.evidence_source + '</small></button></li>').join('') : '<li style="padding:10px 12px">No sample events match these filters.</li>';
  }
  function show(id) {
    selected = id;
    const e = TELE_SAMPLE.find((x) => x.event_id === id);
    $$('#teleList button').forEach((b) => b.setAttribute('aria-pressed', b.dataset.id === id ? 'true' : 'false'));
    $('#teleDetail').innerHTML = '<h4>' + esc(e.label) + ' <span class="label-sim">sample</span></h4><dl class="kv">' + Object.keys(e).map((k) => '<dt><code>' + k + '</code></dt><dd>' + (typeof e[k] === 'object' ? '<code>' + esc(JSON.stringify(e[k])) + '</code>' : esc(String(e[k]))) + '<br><small>' + esc(FIELD_HELP[k] || '') + '</small></dd>').join('') + '</dl>';
  }
  ['#teleType', '#teleSev', '#teleEv'].forEach((s) => $(s).addEventListener('change', apply));
  $('#teleText').addEventListener('input', apply);
  $('#teleReset').addEventListener('click', () => { $('#teleType').value = ''; $('#teleSev').value = ''; $('#teleEv').value = ''; $('#teleText').value = ''; apply(); });
  $('#teleList').addEventListener('click', (e) => { const b = e.target.closest('button[data-id]'); if (b) show(b.dataset.id); });
  apply();
}
