
/* ══════════════════════════ Troubleshooting Assistant ══════════════════════════ */
// Node: { q, opts: [[label, nextId]] } or leaf: { leaf: true, title, check: [..], todo: [..] }.
const L = (title, check, todo) => ({ leaf: true, title, check, todo });
const TS = [
  { id: 'offline', title: 'Driver offline', start: 's', nodes: {
    s: { q: 'What does Driver Status show?', opts: [['Starting (never changes)', 'os'], ['Online', 'online']] },
    os: { q: 'Is the controller on Control4 OS 3.3.2 or later?', opts: [['No, older', 'old'], ['Yes', 'start']] },
    old: L('The controller is below the driver’s minimum', ['Composer › System Manager: controller OS version', 'driver.xml minimum_os_version 3.3.2'], ['Update the controller OS, then reload the driver.']),
    start: L('The driver has not finished starting', ['Driver Status: Starting', 'Lua output after Log Mode = Print, Log Level = 5 - Trace'], ['Set Log Mode to Print and Log Level to 5 - Trace, then use Print Diagnostics.', 'Loading on a physical controller (LuaJIT, the script tag, squished modules) is still a bench item; report what the Lua output shows.']),
    online: { q: 'What does SmartBuildOS Connection Status show?', opts: [['Connected', 'conn'], ['Anything else', 'other']] },
    conn: L('The driver is running and connected', ['AI Status', 'Last Error'], ['If AI Status is not Ready, read the refusal it names; see the topics for licensing or communication errors.']),
    other: L('The driver runs; the Agent link is the problem', ['SmartBuildOS Connection Status'], ['Open the topic “Agent unavailable”.']),
  } },
  { id: 'agent', title: 'Agent unavailable', start: 's', nodes: {
    s: { q: 'What does SmartBuildOS Connection Status show?', opts: [['No SmartBuildOS Agent in this project', 'none'], ['SmartBuildOS Agent update required (module contract v2)', 'upd'], ['Registering with the SmartBuildOS Agent', 'reg'], ['SmartBuildOS Agent not responding', 'lost'], ['SmartBuildOS Agent not paired', 'unp'], ['SmartBuildOS cloud unreachable', 'cloud']] },
    none: L('No Agent was found (AI_STATUS no_agent)', ['SmartBuildOS Connection Status: No SmartBuildOS Agent in this project', 'Agent Pairing Status: No SmartBuildOS Agent'], ['Install smartbuildos.c4z on the same controller and pair it.']),
    upd: L('The Agent only speaks protocol 1 (AI_STATUS agent_update_required)', ['SmartBuildOS Connection Status: SmartBuildOS Agent update required (module contract v2)', 'Agent Pairing Status: Agent update required'], ['Update the SmartBuildOS Agent to a build with module contract v2. Until then every v2 call ends incompatible_protocol and nothing v2 is sent.']),
    reg: { q: 'Has it shown “Registering” for more than 5 minutes?', opts: [['No', 'regwait'], ['Yes', 'regstuck']] },
    regwait: L('Registration is in progress', ['AGENT_CONNECTED is false', 'SmartBuildOS Connection Status: Registering with the SmartBuildOS Agent'], ['Wait: registration retries every 30 s, doubling to 5 minutes.']),
    regstuck: L('The Agent is not accepting the registration', ['Last Error', 'Agent Pairing Status: Unknown (not registered with the Agent yet)'], ['Run Sync Now. If a second AI Core exists in the project, remove it (ai_core is a singleton: duplicate_instance). Check the Agent is running.']),
    lost: L('Registered, but the liveness probe got no answer (AI_STATUS agent_lost)', ['SmartBuildOS Connection Status: SmartBuildOS Agent not responding', 'Event Agent Disconnected and AI_LAST_EVENT_DETAIL'], ['Check the Agent driver is running; run Sync Now. The probe repeats every 30 s while the Agent is not answering and flushes the buffer on the first answer.']),
    unp: L('The Agent is not paired (AI_STATUS agent_unpaired)', ['SmartBuildOS Connection Status: SmartBuildOS Agent not paired', 'Agent Pairing Status: Not paired'], ['Pair the Agent to SmartBuildOS; cloud requests answer agent_not_paired until then.']),
    cloud: L('The Agent cannot reach the cloud (AI_STATUS cloud_unreachable)', ['SmartBuildOS Connection Status: SmartBuildOS cloud unreachable', 'Last Error: no answer from SmartBuildOS (cloud_unreachable)'], ['Check the controller’s internet connection and the Agent’s own Connection Status. Requests are retried twice (2 s, 5 s) and then not again.']),
  } },
  { id: 'auth', title: 'AI API authentication failure', start: 's', nodes: {
    s: { q: 'Where did you see the failure?', opts: [['System Studio connectivity test', 'studio'], ['Composer: Test AI Connection', 'composer'], ['Composer event AI Provider Error', 'event']] },
    studio: { q: 'Which error kind did the test answer?', opts: [['auth', 'kauth'], ['permission', 'kperm'], ['network or timeout', 'knet'], ['rate_limited (connectivity_test_limit)', 'krate']] },
    kauth: L('The vendor rejected the key', ['System Studio › AI Core credentials: provider, ••••last4, status failed'], ['Re-enter the key in System Studio (never in Composer) and test again. Check you pasted the key for the right provider: an sk- key is refused for Anthropic and an sk-ant- key for OpenAI.']),
    kperm: L('The key’s account cannot use this API, model or region', ['Connectivity test kind: permission'], ['Check the account or project at the vendor.']),
    knet: L('The platform could not reach the vendor', ['Connectivity test kind: network / timeout'], ['Retry later; transient kinds are retried and may fall back to a configured fallback provider in real calls.']),
    krate: L('Too many connection tests', ['“Too many connection tests. Wait a minute and try again.”'], ['At most 6 tests a minute per property. Wait one minute.']),
    composer: { q: 'What does Last Test Result show?', opts: [['test accepted (job …)', 'acc'], ['refused (cloud_refused)', 'uns'], ['refused (not_permitted)', 'np'], ['no answer (cloud_unreachable / deadline_exceeded)', 'na']] },
    acc: L('The request was accepted; the result comes later', ['Event AI Response Ready', 'AI_LAST_RESPONSE'], ['Wait for AI Response Ready. If AI Provider Error fires instead, read AI_LAST_EVENT_DETAIL and test the key in System Studio.']),
    uns: L('The platform route is not deployed', ['Last Test Result: AI connection: refused (cloud_refused)', 'AI Status: — last request refused (cloud_refused)'], ['Until /api/integrations/control4/modules/rpc is deployed the Agent gets 404, which the driver sees as cloud_refused (owner: deploy the platform). Meanwhile use Test connection in System Studio › Intelligence › Provider & settings. If the route is deployed: the property may not be licensed (not_entitled reaches the module as cloud_refused).']),
    np: L('SmartBuildOS refused the request', ['Last Error: refused by SmartBuildOS: not_permitted'], ['Check the licence features and the AI Core settings for this property.']),
    na: L('The request was not delivered', ['Last Error: no answer from SmartBuildOS (<code>)'], ['See “Agent unavailable” and check the cloud connection.']),
    event: L('The platform reported a provider error to the home', ['Event AI Provider Error', 'AI_LAST_EVENT_DETAIL'], ['Read the detail, then run the System Studio connectivity test. auth / permission / quota are never retried and never fail over to the other vendor.']),
  } },
  { id: 'model', title: 'Unsupported model', start: 's', nodes: {
    s: { q: 'When does it fail?', opts: [['Saving settings in System Studio', 'save'], ['During a request (provider error not_found)', 'nf'], ['Composer AI Model shows an unexpected name', 'name']] },
    save: L('The override is not a known model of the provider in force', ['Settings refusal: models.deep "…" is not a known Anthropic model (or OpenAI)'], ['Pick a registry or priced model: claude-opus-5-5, claude-sonnet-5-5, claude-fable-5-2, claude-haiku-5-5, gpt-6.2-astra, gpt-6.2-sol, gpt-6.1-terra, gpt-6-luna; or clear the override (null) to use the default.']),
    nf: L('The vendor does not know the model id for this key', ['Provider error kind not_found (never retried)'], ['The model may be retired or unavailable to the account; choose another model or clear the override.']),
    name: L('AI Model shows what System Studio sent', ['Composer property AI Model', 'Last Synchronization'], ['Save the settings again in System Studio and run Sync Now; the driver only displays the configuration’s provider.model.']),
  } },
  { id: 'telemetry', title: 'Telemetry missing', start: 's', nodes: {
    s: { q: 'What does Learning Status show?', opts: [['Active', 'act'], ['Off (not switched on in System Studio)', 'off'], ['Paused by …', 'paused'], ['Stopped (not licensed)', 'stopped']] },
    act: { q: 'What does Telemetry Status start with?', opts: [['Through the Agent', 'thru'], ['No Agent answering', 'noagent']] },
    off: L('Learning is off, so nothing is collected (the default)', ['Learning Status: Off (not switched on in System Studio)', 'LEARNING_ACTIVE false'], ['Switch learning on in System Studio › Intelligence › Provider & settings if the homeowner agrees. Until a valid configuration says learning.active: true, no collection source is on.']),
    stopped: L('The licence definitively refuses AI Core', ['Learning Status: Stopped (not licensed)', 'License Status'], ['See “Licensing errors”.']),
    thru: { q: 'Which events are missing?', opts: [['Composer device events', 'dev'], ['Events from one room or category', 'excl'], ['Bursts are missing', 'budget']] },
    dev: L('Device events come only from the Flight Recorder', ['Flight Recorder Link'], ['Without the Flight Recorder, AI Core does not collect device events (documented gap). Install or update the recorder.']),
    excl: L('The room or category is excluded', ['System Studio › AI Core exclusions; portal learning exclusions'], ['Remove the exclusion if the homeowner agrees. Excluded rooms are never collected.']),
    budget: L('The per-minute budget dropped observations', ['Print Diagnostics counters (collector_*, events_dropped)', 'configuration collection.max_events_per_minute (1–300, default 60)'], ['Raise max_events_per_minute in System Studio or narrow the selected variables.']),
    noagent: L('Events are held on the controller', ['Telemetry Status: No Agent answering: N critical event(s) buffered, N waiting in memory, N dropped'], ['Fix the Agent link. Only warning-and-above events persist (up to 50); the rest are lost on restart and counted.']),
    paused: L('Learning is paused, so nothing is collected', ['Learning Status: Paused by System Studio… / Paused by configuration: vN refused', 'LEARNING_ACTIVE false', 'Last Error for a refused configuration'], ['A pause by the homeowner or staff: resume in the portal or System Studio if the homeowner agrees. Paused by configuration: the last document was refused — fix the field Last Error names; learning cannot be switched on over a refused document.']),
  } },
  { id: 'fr', title: 'Flight Recorder unavailable', start: 's', nodes: {
    s: { q: 'What does Flight Recorder Link show?', opts: [['Not installed: AI Core collects its minimal set itself', 'none'], ['Installed (no local history service; update the Flight Recorder)', 'old'], ['Unknown (needs Agent protocol 2)', 'unk'], ['Installed: local history served; topics subscribed', 'ok']] },
    none: L('No Flight Recorder in the project', ['Flight Recorder Link: Not installed…'], ['Add the SmartBuildOS Flight Recorder for device events and diagnostics. Diagnostics say flight_recorder_not_installed.']),
    old: L('The recorder is an older build', ['Flight Recorder Link: Installed (no local history service…)'], ['Update the Flight Recorder. Diagnostics say flight_recorder_has_no_local_history_service.']),
    unk: L('AI Core cannot discover modules', ['Flight Recorder Link: Unknown (needs Agent protocol 2)'], ['Update the Agent to module contract v2. Diagnostics say flight_recorder_unknown_agent_cannot_discover.']),
    ok: L('The link is healthy', ['Diagnostics: ai_core.diagnostic envelope'], ['If a diagnostic is empty, check its reason (request_failed with error_code) and the recorder’s own status.']),
  } },
  { id: 'comm', title: 'Driver communication errors', start: 's', nodes: {
    s: { q: 'How does Last Error begin?', opts: [['refused locally', 'local'], ['refused by SmartBuildOS', 'refused'], ['no answer from SmartBuildOS', 'noans'], ['Configuration vN refused', 'cfg']] },
    local: { q: 'Which code is in AI Status (refused locally (<code>))?', opts: [['invalid_args', 'ia'], ['rate_limited', 'rl'], ['not_permitted', 'np'], ['incompatible_protocol', 'ip']] },
    ia: L('A parameter was missing, too long or not in its list', ['Last Error / AI_LAST_ERROR, e.g. “QUESTION: longer than 500 characters”'], ['Fix the programming. Over-long text is refused, never cut.']),
    rl: L('More than 10 AI commands a minute', ['Last Error: more than 10 AI commands a minute'], ['Slow the programming down.']),
    np: L('Excluded room, learning off or paused, or licence', ['Last Error names the room (… is excluded by the AI Core configuration), the learning state, or the licence'], ['Check exclusions, Learning Status and License Status. AI_RECORD_EVENT works with learning off but still honours exclusions.']),
    ip: L('The Agent is protocol 1', ['SmartBuildOS Connection Status: SmartBuildOS Agent update required (module contract v2)'], ['Update the Agent.']),
    refused: L('The platform refused the request; it is not retried', ['Last Error: refused by SmartBuildOS: <code>', 'AI Status: — last request refused (<code>)'], ['unsupported: the platform has no handler for that op. not_permitted: permission mode, licence features or homeowner settings. invalid_args: a body key or text the platform refuses (text is cleaned before sending). cloud_refused: any other refusal, including the route not being deployed (HTTP 404) and a property not licensed (not_entitled).']),
    noans: L('The request was not delivered', ['Last Error: no answer from SmartBuildOS (<code>)'], ['cloud_unreachable / deadline_exceeded / target_unavailable / rate_limited are retried twice with the same key (2 s, 5 s). Check the Agent and internet.']),
    cfg: L('The configuration document was refused', ['Last Error: Configuration vN refused: <path>: <reason> (vM kept)'], ['Fix the named field in System Studio and save again. One bad field refuses the whole document; the last valid one stays in force.']),
  } },
  { id: 'delay', title: 'Delayed events', start: 's', nodes: {
    s: { q: 'Where are events late?', opts: [['In the cloud (System Studio)', 'cloud'], ['Locally, from the Flight Recorder topics', 'local'], ['A result after AI_ASK', 'result']] },
    cloud: L('The Agent’s queue is backing off', ['Agent heartbeat event_pipeline (backoff, consecutive_failures)', 'Telemetry Status'], ['After a failed upload the Agent backs off 30 s × 2ⁿ up to 15 minutes; it recovers by itself. Events are ordered by (boot_id, sequence), not by arrival.']),
    local: L('Local pub/sub is best-effort', ['PUBLISH dropped counts; Print Diagnostics bus counters'], ['Frames go out 1 s after the first buffered envelope; buffers drop the oldest beyond 200. The cloud queue, not pub/sub, is the record.']),
    result: L('Results are asynchronous', ['AI Status: Working: N request(s) waiting for a result'], ['A pending job is kept for 30 minutes (at most 20). If nothing arrives: the platform job may have failed (AI Provider Error fires for a provider failure), the provider may not be configured (the result says AI Core has no AI provider key for this property), or the restricted operation expired in the queue.']),
  } },
  { id: 'reco', title: 'Incorrect recommendations', start: 's', nodes: {
    s: { q: 'What is wrong?', opts: [['It is based on something we never do', 'wrong'], ['It was suggested again after dismissing', 'again'], ['It talks about people', 'people']] },
    wrong: L('Correct the memory the recommendation rests on', ['Portal › memories: the finding, its confidence band and evidence'], ['PATCH /api/portal/ai-core/memories {action: "correct"} makes a verified preference supersede the inference; DELETE stops it being re-learned. Staff can dismiss the recommendation.']),
    again: L('Re-raising a dismissed recommendation is an open owner decision', ['Recommendation status dismissed'], ['Delete the memory behind it so the same inference is not learned again.']),
    people: L('No finding has a person field', ['Room or device labels'], ['A label named after a person (“Emma’s Room”) passes through as a label; rename it in Composer if that matters.']),
  } },
  { id: 'external', title: 'Failed external actions', start: 's', nodes: {
    s: { q: 'What kind of action?', opts: [['A device action (light, thermostat, scene, lock, garage, security)', 'dev'], ['A reservation or calendar entry', 'conc']] },
    dev: { q: 'What is the action’s status?', opts: [['denied', 'denied'], ['expired', 'expired'], ['failed', 'failed']] },
    denied: L('The engine or a person denied it', ['Action reason, e.g. observe_mode_no_actions, capability_missing, learned_behaviour_insufficient'], ['capability_missing: the homeowner’s Composer Remote Control tier does not declare comfort_v1 / control_v1. observe_mode_no_actions: the permission mode is observe.']),
    expired: L('Nobody approved it in time', ['Action status expired'], ['Proposals wait 30 minutes for approval; the queue adds 1 hour after enqueue. Propose again.']),
    failed: L('The controller reported a failure', ['Event Action Failed and AI_LAST_EVENT_DETAIL', 'the linked control4_commands row'], ['Failed comes only from the driver’s real acknowledgement. Check the device; a physical change has not yet been bench-verified.']),
    conc: { q: 'What does the portal show?', opts: [['No booking service is connected for your home…', 'nobook'], ['Not booked (a failed request)', 'cfail'], ['Calendar connections aren’t available on this platform yet.', 'ccal']] },
    nobook: L('No provider can take the request', ['Portal › Concierge › Booking services'], ['The only provider with code is the SIMULATION sandbox, off unless staff enable it; no real vendor is integrated (partner agreements needed). Book with the restaurant directly.']),
    cfail: L('The (sandbox) provider refused or did not confirm', ['The request card: Not booked and its reason; recovery buttons'], ['Choose Try sending it again, Look for other options or Stop this request. The sandbox venue Full House Grill always fails at booking, by design.']),
    ccal: L('No OAuth client is configured', ['Portal › Calendar'], ['The platform needs AI_CORE_CALENDAR_GOOGLE_CLIENT_ID / _SECRET or AI_CORE_CALENDAR_MICROSOFT_CLIENT_ID / _SECRET (Chapter 9). Sandbox bookings are never added to a calendar anyway.']),
  } },
  { id: 'licence', title: 'Licensing errors', start: 's', nodes: {
    s: { q: 'What do you see?', opts: [['AI Status: Unavailable: …', 'unav'], ['Last Error: the licence does not include AI_LEARNING (or another feature)', 'feat'], ['License Status says grace or trial', 'grace']] },
    unav: L('The licence definitively denies AI Core', ['SmartBuildOS Connection Status: Connected (not licensed)', 'Learning Status: Stopped (not licensed)', 'License Status'], ['Commands, run_diagnostic and collection stop only on a definitive denial with enforcement on. Check the SBOS_AI_CORE licence for the company.']),
    feat: L('A feature is missing from an authorised licence', ['License Status', 'Last Error: the licence does not include <feature>'], ['Add the feature (AI_LEARNING, AI_ACTIONS, AI_CONCIERGE) to the licence. Today AI_LEARNING is granted only by an explicit licence row. AI_ACTIONS and AI_CONCIERGE gate nothing on the controller; the platform refuses with feature_required.']),
    grace: L('Uncertain states fail open', ['License Status'], ['Grace, trial, legacy, cloud-validation-required and no-answer states let AI Core keep working.']),
  } },
];
function initTroubleshoot() {
  let topic = null, path = [];
  $('#tsTopics').innerHTML = TS.map((t) => '<button type="button" aria-pressed="false" data-t="' + t.id + '">' + esc(t.title) + '</button>').join('');
  function render() {
    $$('#tsTopics button').forEach((b) => b.setAttribute('aria-pressed', topic && b.dataset.t === topic.id ? 'true' : 'false'));
    if (!topic) { $('#tsNode').innerHTML = '<p>Choose a topic.</p>'; $('#tsTrail').textContent = ''; $('#tsBack').disabled = true; $('#tsRestart').disabled = true; return; }
    const id = path[path.length - 1], node = topic.nodes[id];
    $('#tsTrail').textContent = topic.title + (path.length > 1 ? ' › step ' + path.length : '');
    if (node.leaf) {
      $('#tsNode').innerHTML = '<div class="leaf" data-leaf="' + id + '"><p><strong>' + esc(node.title) + '</strong></p><p>Check:</p><ul>' + node.check.map((c) => '<li>' + codeify(c) + '</li>').join('') + '</ul><p>Do:</p><ul>' + node.todo.map((c) => '<li>' + codeify(c) + '</li>').join('') + '</ul></div>';
    } else {
      $('#tsNode').innerHTML = '<p class="q">' + esc(node.q) + '</p><div class="opts">' + node.opts.map(([label, next]) => '<button type="button" data-next="' + next + '">' + esc(label) + '</button>').join('') + '</div>';
    }
    $('#tsBack').disabled = path.length <= 1; $('#tsRestart').disabled = false;
  }
  $('#tsTopics').addEventListener('click', (e) => { const b = e.target.closest('button[data-t]'); if (!b) return; topic = TS.find((t) => t.id === b.dataset.t); path = [topic.start]; render(); const f = $('#tsNode button'); if (f) f.focus(); });
  $('#tsNode').addEventListener('click', (e) => { const b = e.target.closest('button[data-next]'); if (!b) return; path.push(b.dataset.next); render(); const f = $('#tsNode button') || $('#tsBack'); if (f) f.focus(); });
  $('#tsBack').addEventListener('click', () => { if (path.length > 1) { path.pop(); render(); } });
  $('#tsRestart').addEventListener('click', () => { if (topic) { path = [topic.start]; render(); } });
  render();
  // Static summary of every tree (searchable, printable, deep-linkable).
  $('#tsStatic').innerHTML = TS.map((t) => '<h2 id="ch13-' + t.id + '">' + esc(t.title) + '</h2>' + Object.values(t.nodes).filter((n) => n.leaf).map((n) => '<details><summary>' + esc(n.title) + '</summary><div class="body"><p>Check: ' + n.check.map(codeify).join('; ') + '</p><p>Do: ' + n.todo.map(codeify).join(' ') + '</p></div></details>').join('')).join('');
  // Move generated sections to be direct children of the chapter so the router, sub-navigation and search see them.
  const host = $('#tsStatic'); const ch = host.parentElement; while (host.firstChild) ch.insertBefore(host.firstChild, host); host.remove();
}

/* ══════════════════════════ init ══════════════════════════ */
renderStatuses();
renderReferenceTables();
// Phone layout of wide step tables: each cell carries its column name.
$$('table.steps-table').forEach((t) => { const heads = $$('thead th', t).map((h) => h.textContent); $$('tbody tr', t).forEach((tr) => $$('td', tr).forEach((td, i) => td.setAttribute('data-label', heads[i] || ''))); });
initTroubleshoot();
buildChapterNav();
decorateCode(document);
initArch(); initWizard(); initChecklist(); initComm(); initWorkflow(); initTelemetry(); initConfidence(); initExamples(); initReference(); initPermissions();
paintDots();
buildSearchIndex();
route({ focus: false });
window.AICoreGuide = Object.assign(window.AICoreGuide || {}, { STATUS, TS: TS.map((t) => ({ id: t.id, nodes: Object.fromEntries(Object.entries(t.nodes).map(([k, n]) => [k, n.leaf ? { leaf: true } : { opts: n.opts.map((o) => o[1]) }])) })), COMM: COMM.map((c) => ({ id: c.id, n: c.steps.length })), WF: WF_EXAMPLES.map((e) => e.id), ARCH: ARCH.nodes.map((n) => n.id), EXAMPLES: EXAMPLES.length, ready: true });
