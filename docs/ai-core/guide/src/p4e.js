
/* ══════════════════════════ Installation Wizard (simulation) ══════════════════════════ */
const CONN_TEXT = { no_agent: 'No SmartBuildOS Agent in this project', agent_update_required: 'SmartBuildOS Agent update required (module contract v2)', agent_unpaired: 'SmartBuildOS Agent not paired', ready: 'Connected' };
const FR_LINK = { v2: 'Installed: local history served; topics subscribed', v1: 'Installed (no local history service; update the Flight Recorder)', none: 'Not installed: AI Core collects its minimal set itself' };
/** validateApiKey from platform credentials/vault.ts (shape only). */
function validateApiKey(provider, input) {
  if (typeof input !== 'string') return { ok: false, error: 'api_key must be a string.' };
  const key = input.trim();
  if (!/^[\x21-\x7e]{20,512}$/.test(key)) return { ok: false, error: 'api_key must be 20–512 printable characters with no spaces.' };
  if (provider === 'anthropic' && key.startsWith('sk-') && !key.startsWith('sk-ant-')) return { ok: false, error: 'That looks like an OpenAI key, not an Anthropic key.' };
  if (provider === 'openai' && key.startsWith('sk-ant-')) return { ok: false, error: 'That looks like an Anthropic key, not an OpenAI key.' };
  return { ok: true, key };
}
function osAtLeast(v, min) {
  const m = /^(\d+)\.(\d+)\.(\d+)(?:\.\d+)?$/.exec(v.trim()); if (!m) return null;
  const a = m.slice(1, 4).map(Number), b = min.split('.').map(Number);
  for (let i = 0; i < 3; i++) { if (a[i] > b[i]) return true; if (a[i] < b[i]) return false; }
  return true;
}
const WIZ = { os: '', instances: '0', agent: 'yes', proto: '2', paired: 'yes', fr: 'v2', provider: 'anthropic', key: '', mode: 'observe', learning: false, testAgent: false, testAi: false };
const WIZ_STEPS = ['Controller', 'Agent', 'Flight Recorder', 'System Studio', 'Verify', 'Summary'];
let wizPos = 0;
function wizDisplayState() {
  const code = WIZ.agent !== 'yes' ? 'no_agent' : WIZ.proto !== '2' ? 'agent_update_required' : WIZ.paired !== 'yes' ? 'agent_unpaired' : 'ready';
  return { code, conn: CONN_TEXT[code] };
}
function wizRender() {
  $('#wizSteps').innerHTML = WIZ_STEPS.map((s, i) => '<li' + (i === wizPos ? ' aria-current="step"' : '') + (i < wizPos ? ' data-done="true"' : '') + '>' + (i + 1) + '. ' + s + (i < wizPos ? '<span class="sr-only"> (done)</span>' : '') + '</li>').join('');
  $('#wizError').textContent = '';
  const b = $('#wizBody');
  const radio = (name, val, label) => '<label class="radio"><input type="radio" name="' + name + '" value="' + val + '"' + (WIZ[name] === val ? ' checked' : '') + '> ' + label + '</label>';
  if (wizPos === 0) b.innerHTML = '<div class="field"><label for="wzOs">Controller OS version</label><input id="wzOs" type="text" value="' + esc(WIZ.os) + '" placeholder="e.g. 3.3.2" aria-describedby="wzOsHelp"><small id="wzOsHelp">AI Core declares a minimum of 3.3.2.</small></div><fieldset><legend>SmartBuildOS AI Core drivers already in this project</legend>' + radio('instances', '0', 'None') + radio('instances', '1', 'One already') + '</fieldset>';
  if (wizPos === 1) b.innerHTML = '<fieldset><legend>Is the SmartBuildOS Agent (smartbuildos.c4z) in the project?</legend>' + radio('agent', 'yes', 'Yes') + radio('agent', 'no', 'No') + '</fieldset><fieldset><legend>Agent protocol</legend>' + radio('proto', '2', '2 — module contract v2') + radio('proto', '1', '1 — older Agent build') + '</fieldset><fieldset><legend>Is the Agent paired to SmartBuildOS?</legend>' + radio('paired', 'yes', 'Paired') + radio('paired', 'no', 'Not paired') + '</fieldset>';
  if (wizPos === 2) b.innerHTML = '<fieldset><legend>SmartBuildOS Flight Recorder</legend>' + radio('fr', 'v2', 'Installed, current (serves local history over contract v2)') + radio('fr', 'v1', 'Installed, older build') + radio('fr', 'none', 'Not installed') + '</fieldset><p>Flight Recorder Link would read: <strong id="wzFrText">' + esc(FR_LINK[WIZ.fr]) + '</strong></p><p><small>Optional. Without it AI Core does not see Composer device events at all.</small></p>';
  if (wizPos === 3) b.innerHTML = '<p class="note" style="margin-top:0"><strong>Use a made-up key.</strong> This simulation never stores or sends what you type; in real life the key is entered in System Studio only, never in Composer or in a document.</p><div class="field"><label for="wzProvider">AI provider</label><select id="wzProvider"><option value="anthropic"' + (WIZ.provider === 'anthropic' ? ' selected' : '') + '>Anthropic</option><option value="openai"' + (WIZ.provider === 'openai' ? ' selected' : '') + '>OpenAI</option></select></div><div class="field"><label for="wzKey">API key (sample)</label><input id="wzKey" type="password" autocomplete="off" spellcheck="false" value="' + esc(WIZ.key) + '" aria-describedby="wzKeyHelp"><small id="wzKeyHelp">Checked with the vault’s shape rule: 20–512 printable characters, no spaces, matching the provider.</small></div><div class="btn-row"><button type="button" class="btn" id="wzSample">Fill a sample key</button></div><div class="field"><label for="wzMode">Permission mode</label><select id="wzMode">' + ['observe', 'recommend', 'execute_low_risk'].map((m) => '<option' + (WIZ.mode === m ? ' selected' : '') + '>' + m + '</option>').join('') + '</select><small>Default observe: the AI may not propose any action.</small></div><label class="radio"><input type="checkbox" id="wzLearning"' + (WIZ.learning ? ' checked' : '') + '> Turn learning on (off by default; agree it with the homeowner)</label><p><small>In real life these are set in System Studio › Intelligence › Provider &amp; settings.</small></p>';
  if (wizPos === 4) {
    const last4 = WIZ.key.trim().slice(-4);
    const name = WIZ.provider === 'anthropic' ? 'Anthropic' : 'OpenAI';
    const model = WIZ.provider === 'anthropic' ? 'claude-opus-5-5' : 'gpt-6.2-astra';
    b.innerHTML = '<p>Composer properties after the configuration arrives <span class="label-sim">simulated</span></p><dl class="kv sim-props">' +
      [['Driver Status', 'Online'], ['SmartBuildOS Connection Status', CONN_TEXT.ready], ['Agent Pairing Status', 'Paired'], ['AI Provider', name], ['AI Model', model + ' (sample; System Studio sends the display name)'], ['AI API Credential', 'Configured in System Studio · ' + name + ' ••••' + last4], ['Permission Mode', WIZ.mode + ' (set in System Studio)'], ['Property ID', 'Not delivered yet (System Studio)'], ['Learning Status', WIZ.learning ? 'Active' : 'Off (not switched on in System Studio)'], ['Flight Recorder Link', FR_LINK[WIZ.fr]], ['AI Status', 'Ready'], ['Last Test Result', '<span id="wzLast">none</span>']].map(([k, v]) => '<dt>' + k + '</dt><dd>' + (k === 'Last Test Result' ? v : esc(v)) + '</dd>').join('') + '</dl>' +
      '<div class="btn-row"><button type="button" class="btn" id="wzTestAgent">Run Test Agent Link</button><button type="button" class="btn" id="wzTestAi">Run Test AI Connection</button></div><ul id="wzTests"></ul>';
    renderTests();
  }
  if (wizPos === 5) {
    b.innerHTML = '<p><strong>Simulation complete.</strong> In a real project you would now program the events you need (Chapter 11) and tick the Installation Checklist.</p><dl class="kv"><dt>OS</dt><dd>' + esc(WIZ.os) + '</dd><dt>Agent</dt><dd>protocol ' + WIZ.proto + ', ' + (WIZ.paired === 'yes' ? 'paired' : 'not paired') + '</dd><dt>Flight Recorder</dt><dd>' + esc(FR_LINK[WIZ.fr]) + '</dd><dt>Provider</dt><dd>' + (WIZ.provider === 'anthropic' ? 'Anthropic' : 'OpenAI') + ' (key ••••' + esc(WIZ.key.trim().slice(-4)) + ', not stored)</dd><dt>Permission mode</dt><dd>' + WIZ.mode + '</dd><dt>Learning</dt><dd>' + (WIZ.learning ? 'on' : 'off') + '</dd><dt>Tests</dt><dd>Test Agent Link and Test AI Connection run</dd></dl>';
  }
  $('#wizBack').disabled = wizPos === 0;
  $('#wizNext').textContent = wizPos === WIZ_STEPS.length - 1 ? 'Finish' : wizPos === WIZ_STEPS.length - 2 ? 'See summary' : 'Next';
  $('#wizNext').disabled = wizPos === WIZ_STEPS.length - 1;
  bindWizInputs();
}
function renderTests() {
  const ul = $('#wzTests'); if (!ul) return;
  const items = [];
  if (WIZ.testAgent) items.push('<li><strong>Test Agent Link:</strong> Last Test Result shows the Agent’s version, protocol range 1–2, paired, cloud connected and the module count (sample).</li>');
  if (WIZ.testAi) items.push('<li><strong>Test AI Connection:</strong> cloud op <code>test_provider</code>. With the platform deployed: <em>AI connection: test accepted (job …); result follows as AI Response Ready</em>. Until the platform route is deployed: <em>AI connection: refused (cloud_refused)</em>.</li>');
  ul.innerHTML = items.join('');
  const last = $('#wzLast'); if (last) last.textContent = WIZ.testAi ? 'AI connection: test accepted (job job-81c2); result follows as AI Response Ready (sample)' : WIZ.testAgent ? 'Test Agent Link: Agent answered (sample)' : 'none';
}
function bindWizInputs() {
  $$('#wizBody input[type=radio]').forEach((r) => r.addEventListener('change', () => { WIZ[r.name] = r.value; if (r.name === 'fr') $('#wzFrText').textContent = FR_LINK[WIZ.fr]; }));
  const os = $('#wzOs'); if (os) os.addEventListener('input', () => { WIZ.os = os.value; os.removeAttribute('aria-invalid'); });
  const pv = $('#wzProvider'); if (pv) pv.addEventListener('change', () => { WIZ.provider = pv.value; });
  const key = $('#wzKey'); if (key) key.addEventListener('input', () => { WIZ.key = key.value; key.removeAttribute('aria-invalid'); });
  const sample = $('#wzSample'); if (sample) sample.addEventListener('click', () => { WIZ.key = (WIZ.provider === 'anthropic' ? 'sk-ant-' : 'sk-') + 'EXAMPLE-not-a-real-key-abcd'; key.value = WIZ.key; announce('Sample key filled'); });
  const md = $('#wzMode'); if (md) md.addEventListener('change', () => { WIZ.mode = md.value; });
  const lr = $('#wzLearning'); if (lr) lr.addEventListener('change', () => { WIZ.learning = lr.checked; });
  const ta = $('#wzTestAgent'); if (ta) ta.addEventListener('click', () => { WIZ.testAgent = true; renderTests(); announce('Test Agent Link run'); });
  const tai = $('#wzTestAi'); if (tai) tai.addEventListener('click', () => { WIZ.testAi = true; renderTests(); announce('Test AI Connection run'); });
}
function wizValidate() {
  if (wizPos === 0) {
    const ok = osAtLeast(WIZ.os, '3.3.2');
    if (ok === null) { $('#wzOs').setAttribute('aria-invalid', 'true'); return 'Enter the OS version as numbers, for example 3.3.2.'; }
    if (!ok) { $('#wzOs').setAttribute('aria-invalid', 'true'); return 'OS ' + WIZ.os.trim() + ' is below the driver’s minimum_os_version 3.3.2. Update the controller first.'; }
    if (WIZ.instances !== '0') return 'Only one AI Core can be live per controller (module ai_core is a singleton). Use the existing driver.';
  }
  if (wizPos === 1) { const s = wizDisplayState(); if (s.code !== 'ready') return 'SmartBuildOS Connection Status would read “' + s.conn + '” (AI_STATUS ' + s.code + '). ' + (s.code === 'no_agent' ? 'Install and pair smartbuildos.c4z.' : s.code === 'agent_update_required' ? 'Update the Agent to a build with module contract v2.' : 'Pair the Agent to SmartBuildOS.'); }
  if (wizPos === 3) { const v = validateApiKey(WIZ.provider, WIZ.key); if (!v.ok) { $('#wzKey').setAttribute('aria-invalid', 'true'); return v.error; } }
  if (wizPos === 4 && !(WIZ.testAgent && WIZ.testAi)) return 'Run both Test Agent Link and Test AI Connection before continuing.';
  return '';
}
function initWizard() {
  $('#wizNext').addEventListener('click', () => { const err = wizValidate(); if (err) { $('#wizError').textContent = err; return; } if (wizPos < WIZ_STEPS.length - 1) { wizPos++; wizRender(); const f = $('#wizBody input, #wizBody select, #wizBody button'); if (f) f.focus(); } });
  $('#wizBack').addEventListener('click', () => { if (wizPos > 0) { wizPos--; wizRender(); } });
  $('#wizRestart').addEventListener('click', () => { Object.assign(WIZ, { os: '', instances: '0', agent: 'yes', proto: '2', paired: 'yes', fr: 'v2', provider: 'anthropic', key: '', mode: 'observe', learning: false, testAgent: false, testAi: false }); wizPos = 0; wizRender(); announce('Wizard restarted'); });
  wizRender();
}

/* ══════════════════════════ Installation Checklist ══════════════════════════ */
const CHECKLIST = [
  ['Before you start', [
    ['os', 'Controller runs Control4 OS 3.3.2 or later', 'driver.xml minimum_os_version'],
    ['agent', 'SmartBuildOS Agent with module contract v2 is installed and paired', 'Agent Pairing Status will read Paired'],
    ['licence', 'The project is licensed for SBOS_AI_CORE (and the features you plan to use)', 'License Status, Subscription Tier'],
    ['key', 'The customer has an Anthropic or OpenAI API key and will enter it in System Studio', 'never in Composer'],
    ['fr', 'Optional: SmartBuildOS Flight Recorder installed', 'needed for device events and diagnostics'],
  ]],
  ['In Composer', [
    ['add', 'Add SmartBuildOS AI Core once (any room)', 'one instance per controller'],
    ['conn', 'SmartBuildOS Connection Status reads Connected', 'otherwise see Troubleshooting'],
    ['ready', 'AI Status reads Ready', 'AI_STATUS = ready'],
    ['frlink', 'Flight Recorder Link reads the expected state', 'Installed: local history served; topics subscribed'],
    ['testagent', 'Run Test Agent Link and read Last Test Result', 'Agent version, protocol, pairing, cloud state'],
  ]],
  ['In System Studio', [
    ['provider', 'Intelligence › Provider & settings: choose the provider, enter the key, run Test connection', 'answers ok or an error kind; the key is write-only'],
    ['mode', 'Choose the permission mode deliberately (default observe)', 'raising it needs homecontrol:manage'],
    ['learning', 'Agree learning with the homeowner (off by default); switch it on in Studio and set room and category exclusions', 'Learning Status reads Active; a change reaches the controller at once'],
    ['limits', 'Review usage limits (requests per hour/day, tokens per day, monthly spend)', 'defaults 60 / 500 / 500,000 / none'],
    ['delivered', 'AI Provider, AI Model, AI API Credential and Permission Mode fill in Composer', 'Property ID and Controller ID keep reading Not delivered yet (not sent today)'],
  ]],
  ['Verify and hand over', [
    ['testai', 'Run Test AI Connection', 'result arrives as AI Response Ready'],
    ['lasterror', 'Last Error reads none', 'AI_LAST_ERROR is empty'],
    ['telemetry', 'Telemetry Status shows events going Through the Agent', 'no growing drop counts'],
    ['events', 'Program Approval Required, Agent Disconnected and AI Provider Error to the Notification Agent', 'Chapter 11 examples'],
    ['handover', 'Show the homeowner Your home assistant in the portal: approvals and what my home has learned', 'pause, exclusions, export, erase; locks ask twice'],
  ]],
];
function initChecklist() {
  let state = store.get('checklist', {});
  const all = CHECKLIST.flatMap(([, items]) => items.map((i) => i[0]));
  $('#clList').innerHTML = CHECKLIST.map(([group, items]) => '<h4>' + esc(group) + '</h4><ol>' + items.map(([id, label, hint]) => '<li><label><input type="checkbox" data-id="' + id + '"' + (state[id] ? ' checked' : '') + '><span>' + esc(label) + '<small>' + esc(hint) + '</small></span></label></li>').join('') + '</ol>').join('');
  function paint() {
    const n = all.filter((id) => state[id]).length, pct = Math.round((n / all.length) * 100);
    $('#clCount').textContent = n + ' of ' + all.length;
    $('#clBar span').style.width = pct + '%';
    $('#clBar').setAttribute('aria-valuenow', String(pct));
  }
  $('#clList').addEventListener('change', (e) => { const c = e.target.closest('input[data-id]'); if (!c) return; state[c.dataset.id] = c.checked; store.set('checklist', state); paint(); $('#clStatus').textContent = (c.checked ? 'Checked: ' : 'Unchecked: ') + c.parentElement.textContent.trim().split('\n')[0]; });
  $('#clReset').addEventListener('click', () => { if (!window.confirm('Clear every tick in the installation checklist?')) return; state = {}; store.del('checklist'); $$('#clList input').forEach((c) => { c.checked = false; }); paint(); announce('Checklist reset'); });
  $('#clPrint').addEventListener('click', () => { document.body.classList.add('print-checklist'); const done = () => { document.body.classList.remove('print-checklist'); window.removeEventListener('afterprint', done); }; window.addEventListener('afterprint', done); window.print(); setTimeout(done, 1000); });
  paint();
}

/* ══════════════════════════ Confidence calculator ══════════════════════════ */
function initConfidence() {
  const calc = () => {
    const n = Number($('#confN').value), T = Number($('#confT').value), c = Number($('#confC').value);
    const out = $('#confOut');
    if (!Number.isInteger(n) || n < 0 || !Number.isInteger(T) || T < 1 || !Number.isFinite(c) || c < 0 || c > 1) { out.innerHTML = '<span class="err">Enter whole numbers for n (≥ 0) and T (≥ 1), and c between 0 and 1.</span>'; return; }
    if (n < T) { out.innerHTML = '<strong>No finding.</strong> n = ' + n + ' is below the threshold T = ' + T + '; the detector never rounds up.'; return; }
    const conf = c * n / (n + T), band = n < 2 * T ? 'low' : n < 4 * T ? 'medium' : 'high';
    out.innerHTML = 'Confidence <strong data-conf="' + conf.toFixed(3) + '">' + conf.toFixed(3) + '</strong>, band <strong data-band="' + band + '">' + band + '</strong> (from sample size alone).';
  };
  ['#confN', '#confT', '#confC'].forEach((s) => $(s).addEventListener('input', calc));
  calc();
}

/* ══════════════════════════ Composer Programming Examples ══════════════════════════ */
const EX_CATS = ['Asking and results', 'Recording and context', 'Approvals and actions', 'Agent and health', 'Learning', 'Reports and diagnostics', 'Notifications'];
const EXAMPLES = [
  ['Asking and results', 'Ask from a keypad button', 'A homeowner presses a keypad button to ask whether anything is offline.', 'WHEN  Kitchen Keypad › Button 3 › Pressed            (example device)\nIF    SmartBuildOS AI Core › AI_READY is true\nTHEN  SmartBuildOS AI Core › AI_ASK\n        QUESTION = "Is anything offline right now?"\n        ROOM     = "Kitchen"'],
  ['Asking and results', 'React when the answer arrives', 'Results arrive later. AI_LAST_RESPONSE holds up to 1024 bytes; AI_LAST_RESPONSE_ID identifies it.', 'WHEN  SmartBuildOS AI Core › Event › AI Response Ready\nTHEN  Notification Agent › Send "AI answer ready"     (configure the message in the Notification Agent)\n      (the text is in variable AI_LAST_RESPONSE)'],
  ['Asking and results', 'Only ask when AI Core is ready', 'Guard a request with the AI_READY conditional and tell the user otherwise.', 'WHEN  Theater Keypad › Button 1 › Pressed            (example device)\nIF    SmartBuildOS AI Core › AI_READY is true\nTHEN  SmartBuildOS AI Core › AI_ANALYZE_ROOM\n        ROOM = "Theater"\nELSE  Notification Agent › Send "AI Core is not ready"  (check SmartBuildOS Connection Status)'],
  ['Asking and results', 'Scene suggestion for an occasion', 'A suggestion only: nothing in the home changes.', 'WHEN  Patio Keypad › Button 4 › Pressed              (example device)\nTHEN  SmartBuildOS AI Core › AI_SUGGEST_SCENE\n        ROOM     = "Patio"\n        OCCASION = "Dinner party"'],
  ['Recording and context', 'Mark when a Goodnight scene starts', 'Control4 cannot tell a driver that programming ran; record it yourself. Recorded with learning off too; an excluded room or category refuses it.', 'WHEN  Main Bedroom Keypad › Goodnight › Pressed       (example device)\nTHEN  SmartBuildOS AI Core › AI_RECORD_EVENT\n        NAME     = "Goodnight started"\n        CATEGORY = Lighting\n        ROOM     = "Main Bedroom"'],
  ['Recording and context', 'Record a safety reminder', 'Security and Safety categories are recorded with severity warning.', 'WHEN  Garage Door › Left open 10 minutes             (example programming)\nTHEN  SmartBuildOS AI Core › AI_RECORD_EVENT\n        NAME     = "Garage left open reminder"\n        DETAIL   = "Reminder fired after 10 minutes"\n        CATEGORY = Safety'],
  ['Recording and context', 'Tell AI Core the home is on vacation', 'Context keys are a closed list.', 'WHEN  Custom Button › "Away for vacation" › Pressed   (example device)\nTHEN  SmartBuildOS AI Core › AI_SET_CONTEXT\n        KEY   = Vacation\n        VALUE = "until 2026-12-02"'],
  ['Recording and context', 'Guests are present', '', 'WHEN  Custom Button › "Guests" › Pressed               (example device)\nTHEN  SmartBuildOS AI Core › AI_SET_CONTEXT\n        KEY   = Guests Present\n        VALUE = "2 guests until Sunday"'],
  ['Approvals and actions', 'Tell the homeowner an approval is waiting', 'The platform raises Approval Required and sets AI_PENDING_APPROVALS.', 'WHEN  SmartBuildOS AI Core › Event › Approval Required\nIF    SmartBuildOS AI Core › APPROVALS_PENDING is true\nTHEN  Notification Agent › Send "An AI action is waiting for your approval"'],
  ['Approvals and actions', 'Report a failed action', 'Completed and failed come only from the driver’s real acknowledgement.', 'WHEN  SmartBuildOS AI Core › Event › Action Failed\nTHEN  Notification Agent › Send "An approved AI action failed"\n      (details in variable AI_LAST_EVENT_DETAIL)'],
  ['Approvals and actions', 'Confirm a completed action', '', 'WHEN  SmartBuildOS AI Core › Event › Action Completed\nTHEN  Notification Agent › Send "AI action completed"'],
  ['Approvals and actions', 'New recommendations for the integrator', 'Recommendations are reviewed in System Studio; nothing runs from them.', 'WHEN  SmartBuildOS AI Core › Event › Recommendation Available\nIF    SmartBuildOS AI Core › RECOMMENDATIONS_AVAILABLE is true\nTHEN  Notification Agent › Send "AI Core has recommendations"   (to the integrator)'],
  ['Agent and health', 'Alert the integrator when the Agent is lost', 'Fired only by the driver when AGENT_CONNECTED goes true → false.', 'WHEN  SmartBuildOS AI Core › Event › Agent Disconnected\nTHEN  Notification Agent › Send "AI Core lost the SmartBuildOS Agent"   (to the integrator)\n      (the reason is in variable AI_LAST_EVENT_DETAIL)'],
  ['Agent and health', 'Alert on an AI provider error', '', 'WHEN  SmartBuildOS AI Core › Event › AI Provider Error\nTHEN  Notification Agent › Send "AI provider error — check System Studio"   (to the integrator)'],
  ['Agent and health', 'Pattern and conflict alerts', '', 'WHEN  SmartBuildOS AI Core › Event › Automation Conflict Detected\nTHEN  Notification Agent › Send "Programming conflict found"   (to the integrator)\n\nWHEN  SmartBuildOS AI Core › Event › Device Failure Pattern Detected\nTHEN  Notification Agent › Send "A device keeps failing"       (to the integrator)\n\nWHEN  SmartBuildOS AI Core › Event › Pattern Detected\nTHEN  (optional) record or notify; detail in AI_LAST_EVENT_DETAIL'],
  ['Learning', 'Teach a preference only while learning is on', 'AI_LEARN_PREFERENCE needs AI_LEARNING and is refused while learning is off (the default) or paused. The platform records it as a verified preference (source programming) and answers completed at once: AI Response Ready does not fire for it.', 'WHEN  Living Room Keypad › Button 6 › Pressed          (example device)\nIF    SmartBuildOS AI Core › LEARNING_ACTIVE is true\nTHEN  SmartBuildOS AI Core › AI_LEARN_PREFERENCE\n        STATEMENT = "We like the living room at 30% for movies"\n        ROOM      = "Living Room"'],
  ['Reports and diagnostics', 'Weekly system health report', '', 'WHEN  Scheduler › Every Sunday 09:00                     (example schedule)\nTHEN  SmartBuildOS AI Core › AI_GENERATE_REPORT\n        TYPE   = System Health\n        PERIOD = Last 7 Days'],
  ['Reports and diagnostics', 'Diagnose one device from a service button', 'Exactly one of DEVICE or ROOM. Attaches up to 25 recent local Flight Recorder events.', 'WHEN  Rack Keypad › Button 1 › Pressed                 (example device)\nTHEN  SmartBuildOS AI Core › AI_START_DIAGNOSTIC\n        DEVICE = <select the device>'],
  ['Reports and diagnostics', 'Analyse the whole system', '', 'WHEN  Custom Button › "System check" › Pressed          (example device)\nTHEN  SmartBuildOS AI Core › AI_ANALYZE_SYSTEM'],
  ['Notifications', 'Send a notice through SmartBuildOS', 'Recipients are decided by SmartBuildOS from the property’s own people.', 'WHEN  Water Sensor › Wet                               (example device)\nTHEN  SmartBuildOS AI Core › AI_SEND_NOTIFICATION\n        TITLE    = "Water detected"\n        MESSAGE  = "The laundry water sensor reports wet."\n        AUDIENCE = All'],
];
function initExamples() {
  const active = new Set(EX_CATS);
  $('#exCats').innerHTML = EX_CATS.map((c) => '<button type="button" class="chip" aria-pressed="true" data-c="' + esc(c) + '">' + esc(c) + '</button>').join('');
  $('#exList').innerHTML = EXAMPLES.map(([cat, title, desc, code], i) => '<article class="ex" data-cat="' + esc(cat) + '" data-i="' + i + '"><h4>' + esc(title) + '</h4><p><span class="type">' + esc(cat) + '</span> ' + esc(desc) + '</p><pre class="code" data-lang="composer"><code>' + esc(code) + '</code></pre></article>').join('');
  decorateCode($('#exList'));
  function apply() {
    const q = $('#exSearch').value.trim().toLowerCase();
    let n = 0;
    $$('#exList .ex').forEach((a) => { const show = active.has(a.dataset.cat) && (!q || a.textContent.toLowerCase().includes(q)); a.hidden = !show; if (show) n++; });
    $('#exCount').textContent = n + ' of ' + EXAMPLES.length + ' examples' + (n === 0 ? ' — no example matches.' : '');
  }
  $('#exCats').addEventListener('click', (e) => { const b = e.target.closest('.chip'); if (!b) return; const on = b.getAttribute('aria-pressed') !== 'true'; b.setAttribute('aria-pressed', String(on)); if (on) active.add(b.dataset.c); else active.delete(b.dataset.c); apply(); });
  $('#exSearch').addEventListener('input', apply);
  apply();
}

/* ══════════════════════════ Command Reference ══════════════════════════ */
function refItems() {
  const items = [];
  REF.commands.forEach((c) => items.push({ name: c.name, type: 'command', summary: c.description, detail: '<dl class="kv"><dt>Cloud op</dt><dd>' + (c.op ? '<code>' + c.op + '</code>' : 'none') + '</dd><dt>Feature</dt><dd><code>' + c.feature + '</code></dd><dt>Parameters</dt><dd>' + (c.params.length ? c.params.map((p) => '<code>' + p.name + '</code> ' + esc(p.type) + ' — ' + esc(p.rule) + (p.items ? ' (' + p.items.map(esc).join(', ') + ')' : '')).join('<br>') : 'none') + '</dd></dl>' }));
  REF.actions.forEach((a) => items.push({ name: a.name, type: 'action', summary: a.does, detail: '<p>Command <code>' + a.command + '</code></p>' }));
  REF.properties.forEach((p) => items.push({ name: p.name, type: 'property', summary: p.items ? 'Editable list: ' + p.items.join(', ') : p.shows, detail: '<p>Default: ' + esc(p.default || '(empty)') + '. ' + (p.readonly ? 'Read-only.' : 'Editable.') + '</p>' }));
  REF.events.forEach((e) => items.push({ name: e.name, type: 'event', summary: e.description, detail: '<p>Event id ' + e.id + '. Fired: ' + esc(e.fired) + '. raise_event key: <code>' + e.key + '</code>' + (e.id === 9 ? ' (not raisable)' : '') + '</p>' }));
  REF.variables.forEach((v) => items.push({ name: v.name, type: 'variable', summary: v.value, detail: '<p>Variable id ' + v.id + ', ' + v.type + ', default “' + esc(v.default) + '”.</p>' }));
  REF.conditionals.forEach((c) => items.push({ name: c.name, type: 'conditional', summary: c.statement + ' — true when ' + c.meaning, detail: '<p>Conditional id ' + c.id + ', ' + c.type + '.</p>' }));
  return items;
}
function initReference() {
  const items = refItems();
  const types = ['command', 'action', 'property', 'event', 'variable', 'conditional'];
  const on = new Set(types);
  $('#refTypes').innerHTML = types.map((t) => '<button type="button" class="chip" aria-pressed="true" data-t="' + t + '">' + t + 's (' + items.filter((i) => i.type === t).length + ')</button>').join('');
  const tbody = $('#refTable tbody');
  tbody.innerHTML = items.map((it, i) => '<tr data-i="' + i + '" data-type="' + it.type + '"><td><code>' + esc(it.name) + '</code></td><td><span class="type" data-t="' + it.type + '">' + it.type + '</span></td><td>' + esc(it.summary) + '</td><td><button type="button" class="rowbtn" aria-expanded="false" aria-controls="refd-' + i + '">Details<span class="sr-only"> for ' + esc(it.name) + '</span></button></td></tr><tr class="detail" id="refd-' + i + '" data-for="' + i + '" hidden><td colspan="4">' + it.detail + '</td></tr>').join('');
  function apply() {
    const q = $('#refSearch').value.trim().toLowerCase();
    let n = 0;
    items.forEach((it, i) => {
      const row = tbody.querySelector('tr[data-i="' + i + '"]'), det = tbody.querySelector('tr[data-for="' + i + '"]');
      const show = on.has(it.type) && (!q || (it.name + ' ' + it.summary + ' ' + det.textContent).toLowerCase().includes(q));
      row.hidden = !show; if (!show) det.hidden = true; else det.hidden = row.querySelector('.rowbtn').getAttribute('aria-expanded') !== 'true';
      if (show) n++;
    });
    $('#refCount').textContent = n + ' of ' + items.length + ' entries' + (n === 0 ? ' — nothing matches.' : '');
  }
  $('#refTypes').addEventListener('click', (e) => { const b = e.target.closest('.chip'); if (!b) return; const v = b.getAttribute('aria-pressed') !== 'true'; b.setAttribute('aria-pressed', String(v)); if (v) on.add(b.dataset.t); else on.delete(b.dataset.t); apply(); });
  $('#refSearch').addEventListener('input', apply);
  tbody.addEventListener('click', (e) => { const b = e.target.closest('.rowbtn'); if (!b) return; const open = b.getAttribute('aria-expanded') !== 'true'; b.setAttribute('aria-expanded', String(open)); $('#' + b.getAttribute('aria-controls')).hidden = !open; });
  apply();
}
