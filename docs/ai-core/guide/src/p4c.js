
/* ══════════════════════════════════════════════════════════════════════
   Permission engine — line-for-line transcription of
   smartbuildos-ai-core src/lib/ai-core/authz/engine.ts (authorizeToolCall,
   householdAllowedFor, ruleMatches, normalizeBasis, effectiveRiskFor),
   authz/targets.ts (targetClassOf, verbTargetClasses) and the data it
   imports (control4/commands.ts CONTROL_COMMANDS + COMMAND_REQUIRES,
   protocol.ts AI_CORE_PERMISSION_MODES). The browser test compares this
   function with the real TypeScript engine across the whole matrix.
   ══════════════════════════════════════════════════════════════════════ */
const AUTHZ = (() => {
  const CONTROL_COMMANDS = ['LOCK_DEVICE', 'GARAGE_DEVICE', 'SECURITY_PARTITION'];
  const COMMAND_REQUIRES = { REQUEST_FULL_SYNC: null, REQUEST_HEARTBEAT: null, REQUEST_DIAGNOSTICS: null, RUN_NETWORK_SCAN: 'telemetry_v1', PROBE_CAPABILITIES: 'telemetry_v1', REQUEST_CATALOGUE: 'catalogue_v1', REQUEST_UPDATE_CHECK: 'update_check_v1', SEND_NOTIFICATION: 'notify_v1', IDENTIFY_DEVICE: 'identify_v1', SET_LIGHT: 'comfort_v1', SET_THERMOSTAT: 'comfort_v1', ACTIVATE_SCENE: 'comfort_v1', LOCK_DEVICE: 'control_v1', GARAGE_DEVICE: 'control_v1', SECURITY_PARTITION: 'control_v1', CAMERA_SNAPSHOT: 'camera_v1', MODULE_COMMAND: 'modules_v1', DISCOVER_VARIABLES: 'modules_v1' };
  const MODES = ['observe', 'recommend', 'execute_low_risk'];
  const RISK_CLASSES = ['read', 'low', 'high', 'external', 'programming'];
  const RISK_RANK = { read: 0, low: 1, external: 2, high: 3 };
  const DEFAULT_FEATURE_BY_RISK = { read: 'BASE', low: 'AI_ACTIONS', high: 'AI_ACTIONS', external: 'AI_CONCIERGE', programming: 'BASE' };
  const HIGH = new Set(['lock', 'garage', 'security', 'access_control']);
  const PATTERNS = [['lock', /lock|deadbolt/i], ['garage', /garage/i], ['security', /security|alarm|partition|arm(?:ing)?_?panel|intrusion/i], ['access_control', /access|door_?station|intercom|gate|entry/i], ['thermostat', /thermostat|hvac|climate/i], ['light', /light|dimmer|lamp|switch/i], ['scene', /scene/i]];
  const has = (o, k) => Object.prototype.hasOwnProperty.call(o, k);
  function targetClassOf(t) { if (typeof t !== 'string' || t.trim() === '') return 'unknown'; for (const [c, re] of PATTERNS) if (re.test(t)) return c; return 'other'; }
  function verbTargetClasses(v) { return v === 'SET_LIGHT' ? ['light'] : v === 'SET_THERMOSTAT' ? ['thermostat'] : v === 'ACTIVATE_SCENE' ? ['scene'] : null; }
  const deny = (reason, effectiveRisk) => (effectiveRisk ? { decision: 'deny', reason, effectiveRisk } : { decision: 'deny', reason });
  const approval = (approver, reason, effectiveRisk) => ({ decision: 'require_approval', approver, reason, effectiveRisk });
  function householdAllowedFor(actor, gate, learning) {
    if (!actor || !gate || gate.wouldDeny !== false) return false;
    switch (actor.kind) {
      case 'staff': return !!actor.grants && actor.grants.monitoringView === true && actor.grants.homecontrolView === true;
      case 'homeowner': return true;
      case 'automation': return actor.householdConsent === true && !(learning && learning.paused === true);
      default: return false;
    }
  }
  function isActor(a) {
    if (!a || typeof a !== 'object') return false;
    if (a.kind === 'staff') return typeof a.grants === 'object' && a.grants !== null;
    if (a.kind === 'homeowner') return Array.isArray(a.propertyIds);
    return a.kind === 'automation';
  }
  function effectiveRiskFor(toolRisk, verb, target) {
    if (toolRisk === 'read' || toolRisk === 'programming') return { risk: toolRisk, targetClass: null };
    let risk = toolRisk;
    if (verb && CONTROL_COMMANDS.includes(verb)) risk = 'high';
    if (!target) return { risk, targetClass: null };
    const targetClass = targetClassOf(target.deviceType);
    if (HIGH.has(targetClass)) risk = 'high';
    if (risk === 'low' && verb) { const allowed = verbTargetClasses(verb); if (allowed && target.deviceId !== null && !allowed.includes(targetClass)) risk = 'high'; }
    return { risk: (RISK_RANK[risk] ?? 0) >= (RISK_RANK[toolRisk] ?? 0) ? risk : toolRisk, targetClass };
  }
  function localMinuteOfDay(timeZone, now) {
    if (typeof timeZone !== 'string' || timeZone.length === 0 || timeZone.length > 64) return null;
    try {
      const parts = new Intl.DateTimeFormat('en-US', { timeZone, hourCycle: 'h23', hour: '2-digit', minute: '2-digit' }).formatToParts(now);
      const hp = parts.find((p) => p.type === 'hour'), mp = parts.find((p) => p.type === 'minute');
      const hour = Number(hp && hp.value), minute = Number(mp && mp.value);
      if (!Number.isInteger(hour) || !Number.isInteger(minute) || hour < 0 || hour > 23 || minute < 0 || minute > 59) return null;
      return hour * 60 + minute;
    } catch (e) { return null; }
  }
  function insideWindow(w, now) {
    const valid = (m) => Number.isInteger(m) && m >= 0 && m <= 1439;
    if (!valid(w.startMinute) || !valid(w.endMinute) || w.startMinute === w.endMinute) return false;
    const at = localMinuteOfDay(w.timeZone, now);
    if (at === null) return false;
    return w.startMinute < w.endMinute ? at >= w.startMinute && at < w.endMinute : at >= w.startMinute || at < w.endMinute;
  }
  function normalizeBasis(b) { return b === 'explicit_request' || b === 'recommendation' || b === 'preapproved_rule' ? b : 'learned_pattern'; }
  function ruleMatches(rule, verb, target, now) {
    if (!verb || !target || rule.verb !== verb) return false;
    if (rule.expiresAt) { const until = Date.parse(rule.expiresAt); if (!Number.isFinite(until) || until <= now.getTime()) return false; }
    const deviceIds = rule.deviceIds || [], roomNames = rule.roomNames || [];
    if (deviceIds.length === 0 && roomNames.length === 0) return false;
    const inScope = (target.deviceId !== null && deviceIds.includes(target.deviceId)) || (target.roomName !== null && roomNames.includes(target.roomName));
    if (!inScope) return false;
    if (rule.window && !insideWindow(rule.window, now)) return false;
    for (const [key, value] of Object.entries(target.values || {})) {
      if (typeof value === 'number') {
        const bound = rule.bounds && has(rule.bounds, key) ? rule.bounds[key] : undefined;
        if (!bound || !Number.isFinite(value) || !Number.isFinite(bound.min) || !Number.isFinite(bound.max)) return false;
        if (value < bound.min || value > bound.max) return false;
      } else {
        const allowed = rule.allowedValues && has(rule.allowedValues, key) ? rule.allowedValues[key] : undefined;
        if (!allowed || !allowed.includes(value)) return false;
      }
    }
    return true;
  }
  function authorize(input) {
    const { tool, actor, gate } = input;
    if (!tool || typeof tool.id !== 'string' || typeof tool.risk !== 'string') return deny('unknown_tool');
    if (tool.risk === 'credential') return deny('credential_tool_forbidden');
    if (!RISK_CLASSES.includes(tool.risk)) return deny('unknown_risk');
    if (!input.permissionMode || !MODES.includes(input.permissionMode)) return deny('unknown_permission_mode');
    if (!gate || typeof gate.wouldDeny !== 'boolean') return deny('missing_gate');
    if (gate.wouldDeny) return deny('gate_would_deny');
    if (!isActor(actor)) return deny('unknown_actor');
    if (actor.kind === 'staff' && actor.grants.monitoringView !== true) return deny('role_not_permitted');
    if (actor.kind === 'homeowner' && (!input.propertyId || !actor.propertyIds.includes(input.propertyId))) return deny('property_not_permitted');
    if (tool.household && !householdAllowedFor(actor, gate, input.learning)) return deny('household_not_permitted');
    if (tool.risk === 'programming') return deny('programming_recommendation_only');
    const feature = tool.feature ?? DEFAULT_FEATURE_BY_RISK[tool.risk];
    if (!feature || !input.entitlementFeatures.includes(feature)) return deny('entitlement_missing');
    if (tool.verb !== undefined) {
      if (!has(COMMAND_REQUIRES, tool.verb)) return deny('unknown_verb');
      const capability = COMMAND_REQUIRES[tool.verb];
      if (capability && !input.controllerCapabilities.includes(capability)) return deny('capability_missing');
    }
    if (tool.risk === 'read') return { decision: 'allow', reason: 'read_allowed', effectiveRisk: 'read' };
    if (actor.kind === 'staff' && actor.grants.homecontrolManage !== true) return deny('role_not_permitted');
    const { risk } = effectiveRiskFor(tool.risk, tool.verb, input.target);
    const basis = normalizeBasis(input.learning && input.learning.basis);
    const learned = basis === 'learned_pattern';
    if (input.permissionMode === 'observe') return deny('observe_mode_no_actions', risk);
    if (risk === 'external') {
      if (actor.kind === 'automation') return deny('automation_external_forbidden', risk);
      if (learned) return deny('learned_behaviour_insufficient', risk);
      return approval('homeowner', 'external_needs_homeowner', risk);
    }
    if (risk === 'high') {
      if (learned) return deny('learned_behaviour_insufficient', risk);
      return approval('homeowner', 'high_risk_needs_homeowner', risk);
    }
    if (risk === 'low') {
      const approver = actor.kind === 'automation' || learned ? 'homeowner' : 'requester';
      if (input.permissionMode === 'execute_low_risk' && input.preapprovedRules.some((r) => ruleMatches(r, tool.verb, input.target, input.now))) return { decision: 'allow', reason: 'preapproved_rule_matched', effectiveRisk: risk };
      return approval(approver, 'low_risk_needs_approval', risk);
    }
    return deny('unknown_risk');
  }
  return { authorize, targetClassOf, MODES };
})();

const REASON_TEXT = {
  read_allowed: 'Read tools are allowed in every mode once the role and household gates pass.',
  preapproved_rule_matched: 'A homeowner-consented pre-approved rule covers this exact call (verb, scope, bounds), so it runs without a per-action approval.',
  low_risk_needs_approval: 'Low risk: someone must approve this proposal before it is queued.',
  high_risk_needs_homeowner: 'High risk (lock, garage, security, access control): the homeowner must approve this action explicitly.',
  external_needs_homeowner: 'External action: the homeowner must give final confirmation.',
  unknown_tool: 'There is no such tool.',
  unknown_risk: 'The risk class is not recognised.',
  credential_tool_forbidden: 'No tool may read a credential.',
  programming_recommendation_only: 'Persistent programming is never executed; it can only become a recommendation a person carries into Composer.',
  unknown_permission_mode: 'The permission mode is not recognised.',
  observe_mode_no_actions: 'In observe mode the AI may not even propose an action.',
  gate_would_deny: 'The route permission gate would deny this caller (audit mode), so the engine refuses explicitly.',
  missing_gate: 'No gate evaluation was supplied.',
  unknown_actor: 'The actor is not recognised.',
  role_not_permitted: 'This staff role lacks monitoring:view (for anything) or homecontrol:manage (for actions).',
  property_not_permitted: 'This homeowner cannot see this property.',
  household_not_permitted: 'Household data needs homecontrol:view for staff, or household consent (and learning not paused) for an automation.',
  entitlement_missing: 'The licence does not include the feature this tool needs.',
  capability_missing: 'The controller has not declared the capability this verb needs (the homeowner’s Composer Remote Control tier).',
  unknown_verb: 'The queue verb is not recognised.',
  learned_behaviour_insufficient: 'Learned behaviour alone never authorizes high-risk or external actions.',
  automation_external_forbidden: 'An automation may never take an external action.',
};

/* Operations offered in the explorer: the registry's real tools, plus the
   three classes that have no tool (labelled as such). */
const SAMPLE_TARGET = {
  SET_LIGHT: { type: 'dimmer', values: { level: 30 } },
  SET_THERMOSTAT: { type: 'thermostat', values: { setpoint_f: 70 } },
  ACTIVATE_SCENE: { type: 'scene', values: {} },
  LOCK_DEVICE: { type: 'door_lock', values: { state: 'unlocked' } },
  GARAGE_DEVICE: { type: 'garage_door', values: { state: 'open' } },
  SECURITY_PARTITION: { type: 'security_partition', values: { state: 'disarm' } },
};
const DEVICE_TYPES = ['dimmer', 'thermostat', 'scene', 'door_lock', 'garage_door', 'security_partition', 'intercom', 'media_player', ''];
function explorerOperations() {
  const ops = REF.tools.map((t) => ({ key: t.wire, label: t.wire + ' (' + t.risk + ')', tool: { id: t.id, risk: t.risk, household: t.household, ...(t.verb ? { verb: t.verb } : {}), ...(t.feature ? { feature: t.feature } : {}) }, kind: t.verb ? 'device' : t.wire === 'notifications_send' ? 'audience' : 'none' }));
  ops.push({ key: 'class:external', label: 'external class — e.g. a reservation (no tool exists yet)', tool: { id: 'class.external', risk: 'external', household: false }, kind: 'none' });
  ops.push({ key: 'class:programming', label: 'programming class — a persistent programming change (no tool exists)', tool: { id: 'class.programming', risk: 'programming', household: false }, kind: 'none' });
  ops.push({ key: 'class:credential', label: 'credential class — reading a secret (no tool can exist)', tool: { id: 'class.credential', risk: 'credential', household: false }, kind: 'none' });
  return ops;
}
const OPS = explorerOperations();
const FEATURES = ['BASE', 'AI_LEARNING', 'AI_ACTIONS', 'AI_CONCIERGE'];
const CAPS = ['comfort_v1', 'control_v1'];
const FIXED_NOW = new Date('2026-11-18T12:00:00Z');

/** Builds the engine input from a plain state object (also used by the test). */
function buildAuthzInput(st) {
  const op = OPS.find((o) => o.key === st.op);
  let actor;
  if (st.actor === 'staff') actor = { kind: 'staff', userId: 'u1', grants: { monitoringView: !!st.mv, homecontrolView: !!st.hv, homecontrolManage: !!st.hm } };
  else if (st.actor === 'homeowner') actor = { kind: 'homeowner', userId: 'h1', clientId: 'c1', propertyIds: st.own ? ['p1'] : ['p2'] };
  else actor = { kind: 'automation', jobId: 'j1', householdConsent: !!st.consent };
  let target = null;
  if (op && op.kind === 'device') { const s = SAMPLE_TARGET[op.tool.verb]; target = { deviceId: 214, roomName: 'Living Room', deviceType: st.target, values: { ...s.values } }; }
  if (op && op.kind === 'audience') target = { deviceId: null, roomName: null, deviceType: null, values: { audience: 'homeowner' } };
  const rules = [];
  if (st.rule && op && op.tool.verb && target) {
    const bounds = {}, allowedValues = {};
    for (const [k, v] of Object.entries(target.values)) { if (typeof v === 'number') bounds[k] = { min: v, max: v }; else allowedValues[k] = [v]; }
    rules.push({ id: 'r1', verb: op.tool.verb, deviceIds: [214], bounds, allowedValues, expiresAt: '2027-01-01T00:00:00Z', window: null });
  }
  return { actor, permissionMode: st.mode, tool: op ? op.tool : null, target, propertyId: 'p1', controllerCapabilities: st.caps.slice(), entitlementFeatures: st.features.slice(), preapprovedRules: rules, learning: { basis: st.basis, paused: !!st.paused }, gate: { wouldDeny: !!st.gate }, now: FIXED_NOW };
}
function decide(st) { return AUTHZ.authorize(buildAuthzInput(st)); }

function initPermissions() {
  const sel = $('#pmTool');
  sel.innerHTML = OPS.map((o) => '<option value="' + esc(o.key) + '">' + esc(o.label) + '</option>').join('');
  sel.value = 'actions_set_light';
  $('#pmTarget').innerHTML = DEVICE_TYPES.map((t) => '<option value="' + esc(t) + '">' + (t ? esc(t) : '(not in the registry)') + ' → class ' + AUTHZ.targetClassOf(t) + '</option>').join('');
  $('#pmTarget').value = 'dimmer';
  const chipGroup = (host, list, on) => { host.innerHTML = list.map((f) => '<button type="button" class="chip" data-v="' + f + '" aria-pressed="' + (on.includes(f) ? 'true' : 'false') + '">' + f + '</button>').join(''); host.addEventListener('click', (e) => { const b = e.target.closest('.chip'); if (!b) return; b.setAttribute('aria-pressed', b.getAttribute('aria-pressed') === 'true' ? 'false' : 'true'); update(); }); };
  chipGroup($('#pmFeatures'), FEATURES, ['BASE', 'AI_LEARNING', 'AI_ACTIONS', 'AI_CONCIERGE']);
  chipGroup($('#pmCaps'), CAPS, ['comfort_v1']);
  const state = () => ({
    actor: $('#pmActor').value, mv: $('#pmMonView').checked, hv: $('#pmHcView').checked, hm: $('#pmHcManage').checked,
    own: $('#pmOwnProperty').checked, consent: $('#pmConsent').checked, mode: $('#pmMode').value, op: $('#pmTool').value,
    target: $('#pmTarget').value, basis: $('#pmBasis').value,
    features: $$('#pmFeatures .chip[aria-pressed="true"]').map((b) => b.dataset.v), caps: $$('#pmCaps .chip[aria-pressed="true"]').map((b) => b.dataset.v),
    rule: $('#pmRule').checked, paused: $('#pmPaused').checked, gate: $('#pmGate').checked,
  });
  function update() {
    const st = state();
    $('#pmStaffGrants').hidden = st.actor !== 'staff';
    $('#pmOwnWrap').hidden = st.actor !== 'homeowner';
    $('#pmConsentWrap').hidden = st.actor !== 'automation';
    const op = OPS.find((o) => o.key === st.op);
    $('#pmTargetWrap').hidden = !op || op.kind !== 'device';
    const r = decide(st);
    const word = { allow: 'Allow', require_approval: 'Requires approval', deny: 'Deny' }[r.decision];
    const v = $('#pmVerdict');
    v.dataset.d = r.decision;
    v.innerHTML = '<p class="big" data-decision="' + r.decision + '">' + word + (r.approver ? ' — by the ' + (r.approver === 'homeowner' ? 'homeowner' : 'requester') : '') + '</p>' +
      '<p>Reason: <code data-reason="' + r.reason + '">' + r.reason + '</code></p><p>' + esc(REASON_TEXT[r.reason] || '') + '</p>' +
      (r.effectiveRisk ? '<p>Decided on risk: <code>' + r.effectiveRisk + '</code>' + (op && op.kind === 'device' ? ' (target class <code>' + AUTHZ.targetClassOf(st.target) + '</code>)' : '') + '</p>' : '') +
      '<p><small>Engine: authz/engine.ts authorizeToolCall (transcribed).</small></p>';
    // matrix
    const modes = AUTHZ.MODES;
    const rows = OPS.map((o) => {
      const cells = modes.map((m) => { const s2 = { ...st, mode: m, op: o.key, target: o.kind === 'device' ? SAMPLE_TARGET[o.tool.verb].type : st.target }; const d = decide(s2); return '<td data-d="' + d.decision + '" title="' + d.reason + '">' + ({ allow: 'allow', require_approval: 'approval' + (d.approver ? ' (' + d.approver + ')' : ''), deny: 'deny' }[d.decision]) + '<br><small>' + d.reason + '</small></td>'; }).join('');
      return '<tr><th scope="row"><code>' + esc(o.key) + '</code></th>' + cells + '</tr>';
    }).join('');
    $('#pmMatrix').innerHTML = '<caption class="sr-only">Decision for every operation and mode</caption><thead><tr><th scope="col">Operation</th>' + modes.map((m) => '<th scope="col">' + m + '</th>').join('') + '</tr></thead><tbody>' + rows + '</tbody>';
  }
  $('#pmTool').addEventListener('change', () => { const op = OPS.find((o) => o.key === $('#pmTool').value); if (op && op.kind === 'device') $('#pmTarget').value = SAMPLE_TARGET[op.tool.verb].type; update(); });
  $('#permForm').addEventListener('change', update);
  update();
  window.AICoreGuide = Object.assign(window.AICoreGuide || {}, { authorize: AUTHZ.authorize, buildAuthzInput, decide, OPS: OPS.map((o) => ({ key: o.key, kind: o.kind, verb: o.tool.verb || null })), DEVICE_TYPES, FEATURES, CAPS, SAMPLE_TARGET });
}

/* ══════════════════════════ AI Workflow Simulator ══════════════════════════ */
const WF_EXAMPLES = [
  { id: 'lights2am', title: 'Homeowner: "Why did the living room lights turn on at 2 AM?"', actor: 'homeowner', features: ['BASE', 'AI_ACTIONS'], caps: ['comfort_v1'],
    question: 'Why did the living room lights turn on at 2 AM?',
    calls: [
      { op: 'flight_recorder_search_events', args: { from: '2026-11-17T01:30:00Z', to: '2026-11-17T02:30:00Z', room_id: 12, limit: 50 },
        result: { events: [
          { event_id: 'flight_recorder:388:b7:10432', event_type: 'observation.programmed', observed_at: '2026-11-17T02:03:09Z', label: 'Hallway night path', correlation_id: 'tr-88' },
          { event_id: 'flight_recorder:388:b7:10433', event_type: 'capture.event', observed_at: '2026-11-17T02:03:11Z', label: 'Living Room Dimmer — level changed', device_id: 214, correlation_id: 'tr-88' },
          { event_id: 'flight_recorder:388:b7:10398', event_type: 'observation.system', observed_at: '2026-11-17T01:58:40Z', label: 'director_reloaded' } ], gaps: [] } },
      { op: 'flight_recorder_analyze_incident', args: { event_id: 'flight_recorder:388:b7:10433', before_minutes: 30, after_minutes: 5 },
        result: { hypotheses: [
          { status: 'confirmed', summary: 'shares trace tr-88 with the programming marker "Hallway night path"', event_ids: ['flight_recorder:388:b7:10432'] },
          { status: 'possible', summary: 'Director reloaded 4 minutes earlier (time proximity only)', event_ids: ['flight_recorder:388:b7:10398'] } ] } },
    ],
    answer: { answer: 'The living room dimmer came on at 2:03 AM as part of the "Hallway night path" programming, which was recorded two seconds earlier under the same trace.',
      confirmed: [{ claim: 'The dimmer change at 02:03:11 shares trace tr-88 with the "Hallway night path" marker at 02:03:09.', event_ids: ['flight_recorder:388:b7:10432', 'flight_recorder:388:b7:10433'] }],
      possible: [{ claim: 'The Director reloaded at 01:58; this is time proximity only.', event_ids: ['flight_recorder:388:b7:10398'] }, { claim: 'A motion sensor started the night path.', event_ids: ['flight_recorder:388:b7:99999'] }],
      unknowns: ['Control4 does not tell drivers which person or keypad triggered programming.'], suggested_next_steps: ['Ask your integrator whether the night path should include the living room.'] },
    dropped: 'flight_recorder:388:b7:99999' },
  { id: 'offline', title: 'Technician: "Which devices went offline last night, and was it one cause?"', actor: 'staff', features: ['BASE'], caps: [],
    question: 'Which devices went offline last night, and was it one cause?',
    calls: [
      { op: 'health_incidents', args: { days: 1 }, result: { incidents: [{ started_at: '2026-11-17T03:12:05Z', devices: [41, 42, 57, 58], probable_cause_device_id: 41, note: 'first device down — evidence, not proof' }] } },
      { op: 'flight_recorder_get_device_history', args: { device_id: 41, from: '2026-11-17T02:00:00Z', to: '2026-11-17T05:00:00Z' },
        result: { events: [{ event_id: 'ai_core:412:c2:2201', event_type: 'ai_core.observation.system', observed_at: '2026-11-17T03:12:05Z', label: 'OnDeviceOffline' }, { event_id: 'ai_core:412:c2:2209', event_type: 'ai_core.observation.system', observed_at: '2026-11-17T03:19:40Z', label: 'OnDeviceOnline' }], gaps: [] } },
    ],
    answer: { answer: 'Four devices dropped within 60 seconds at 03:12 and the first one down was device 41 (rack switch). That makes it the probable starting point, not a proven cause: there is no network topology in the data.',
      confirmed: [{ claim: 'Device 41 reported offline at 03:12:05 and online again at 03:19:40.', event_ids: ['ai_core:412:c2:2201', 'ai_core:412:c2:2209'] }],
      possible: [{ claim: 'Devices 42, 57 and 58 went offline because device 41 did.', event_ids: ['ai_core:412:c2:2201'] }],
      unknowns: ['Which devices sit behind device 41 is not recorded.'], suggested_next_steps: ['Check device 41’s power and uplink; run AI_START_DIAGNOSTIC on it.'] } },
  { id: 'kitchen', title: 'Homeowner: "Set the kitchen lights to 30 %."', actor: 'homeowner', features: ['BASE', 'AI_ACTIONS'], caps: ['comfort_v1'],
    rule: true, ruleNote: 'Sample consented rule: SET_LIGHT on device 31 (Kitchen Pendants), level 0–60, no window.',
    question: 'Set the kitchen lights to 30 %.',
    calls: [
      { op: 'devices_list', args: { room_name: 'Kitchen' }, result: { devices: [{ id: 31, name: 'Kitchen Pendants', type: 'dimmer' }] } },
      { op: 'actions_set_light', args: { device_id: 31, level: 30 }, device: { id: 31, type: 'dimmer', values: { level: 30 } } },
    ] },
  { id: 'unlock', title: 'Homeowner: "Unlock the front door for the cleaner."', actor: 'homeowner', features: ['BASE', 'AI_ACTIONS'], caps: ['comfort_v1', 'control_v1'],
    question: 'Unlock the front door for the cleaner.',
    calls: [
      { op: 'devices_list', args: { room_name: 'Entry' }, result: { devices: [{ id: 7, name: 'Front Door', type: 'door_lock' }] } },
      { op: 'actions_lock', args: { device_id: 7, state: 'unlocked' }, device: { id: 7, type: 'door_lock', values: { state: 'unlocked' } } },
    ] },
  { id: 'learned', title: 'Automation: learned pattern "kitchen at 30 % at 7 PM"', actor: 'automation', basis: 'learned_pattern', features: ['BASE', 'AI_ACTIONS', 'AI_LEARNING'], caps: ['comfort_v1'],
    question: '(No person asked. The analysis job found a daily routine and an automation proposes acting on it.)',
    calls: [
      { op: 'actions_set_light', args: { device_id: 31, level: 30 }, device: { id: 31, type: 'dimmer', values: { level: 30 } } },
    ] },
  { id: 'booking', title: 'Homeowner: "Book a table for two on Friday at 8." (concierge in development)', actor: 'homeowner', features: ['BASE', 'AI_ACTIONS', 'AI_CONCIERGE'], caps: ['comfort_v1'],
    question: 'Book a table for two on Friday at 8.',
    calls: [
      { op: 'concierge_list_providers', args: {}, result: { providers: [{ name: 'SIMULATION — SmartBuildOS sandbox restaurants', usable: true, reason: 'enabled by staff for this property (simulated)' }, { name: 'OpenTable', usable: false, reason: 'needs a partner agreement' }] } },
      { op: 'concierge_suggest_reservation', args: { basis: 'explicit_request', criteria: { party_size: 2, date: '2026-11-20', time_from: '19:30', time_to: '20:30', time_zone: 'America/New_York' } }, result: { request_id: '<uuid>', status: 'suggested' } },
    ],
    answer: { answer: 'I’ve recorded a reservation suggestion. Nothing is searched or booked until you approve the search in your portal, and the only service available today is a simulation, so no real table can be reserved.', confirmed: [], possible: [], unknowns: [], suggested_next_steps: ['Approve the search in the portal, or book directly with the restaurant.'] }, historical: false },
];
const ACTOR_LABEL = { homeowner: 'homeowner (portal)', staff: 'staff technician (monitoring:view + homecontrol:view)', automation: 'automation (server job, household consent on)' };
function wfState(ex, mode, op, device, ruleOn) {
  return { actor: ex.actor, mv: true, hv: true, hm: false, own: true, consent: true, mode, op, target: device ? device.type : '', basis: ex.basis || 'explicit_request', features: ex.features, caps: ex.caps, rule: !!ruleOn, paused: false, gate: false };
}
function wfDecide(ex, mode, call) {
  const st = wfState(ex, mode, call.op, call.device, ex.rule && call.device);
  const input = buildAuthzInput(st);
  if (call.device) { input.target = { deviceId: call.device.id, roomName: null, deviceType: call.device.type, values: { ...call.device.values } }; if (ex.rule) input.preapprovedRules = [{ id: 'rule-kitchen', verb: 'SET_LIGHT', deviceIds: [31], bounds: { level: { min: 0, max: 60 } }, allowedValues: {}, expiresAt: '2027-01-01T00:00:00Z', window: null }]; }
  return AUTHZ.authorize(input);
}
function wfSteps(ex, mode) {
  const steps = [];
  steps.push({ kind: 'Question', html: '<p><strong>' + esc(ex.question) + '</strong></p><p><small>Actor: ' + esc(ACTOR_LABEL[ex.actor]) + '. Licence features: ' + ex.features.map((f) => '<code>' + f + '</code>').join(', ') + '. Controller capabilities: ' + (ex.caps.length ? ex.caps.map((c) => '<code>' + c + '</code>').join(', ') : 'none') + '.' + (ex.ruleNote ? ' ' + esc(ex.ruleNote) : '') + '</small></p>' });
  const offered = OPS.filter((o) => !o.key.startsWith('class:')).filter((o) => { const st = wfState(ex, mode, o.key, o.kind === 'device' ? { type: SAMPLE_TARGET[o.tool.verb].type } : null, false); return AUTHZ.authorize(buildAuthzInput(st)).decision !== 'deny'; });
  steps.push({ kind: 'Tools offered', html: '<p>Before the first round the orchestrator offers only the tools the engine would not refuse for this actor, mode and licence (' + offered.length + ' of ' + REF.tools.length + '): ' + offered.map((o) => '<code>' + o.key + '</code>').join(', ') + '. The concierge tools are in development.</p>' });
  let blocked = false;
  const lastActionDecision = [];
  ex.calls.forEach((c) => {
    const d = wfDecide(ex, mode, c);
    steps.push({ kind: 'Tool call', html: '<p>The model requests <code>' + c.op + '</code> with</p><pre class="code" data-lang="json"><code>' + esc(JSON.stringify(c.args, null, 2)) + '</code></pre><p>Permission engine: <span class="decision" data-d="' + d.decision + '">' + d.decision + '</span> <code>' + d.reason + '</code>' + (d.approver ? ' — approver: ' + d.approver : '') + '</p><p><small>' + esc(REASON_TEXT[d.reason]) + '</small></p>' });
    if (c.result && d.decision === 'allow') steps.push({ kind: 'Tool result (untrusted, sample data)', html: '<pre class="code" data-lang="json"><code>' + esc(JSON.stringify({ untrusted: true, source: c.op, data: c.result }, null, 2)) + '</code></pre>' });
    if (c.device) lastActionDecision.push(d);
    if (!c.device && d.decision === 'deny') blocked = true;
  });
  if (lastActionDecision.length) {
    const d = lastActionDecision[lastActionDecision.length - 1];
    let html;
    if (d.decision === 'deny') html = '<p>Nothing is proposed or queued. The model is told the call was refused (<code>' + d.reason + '</code>) and says so.</p>';
    else if (d.decision === 'allow') html = '<p>The action is recorded as <code>approved</code> and enqueued in <code>control4_commands</code> (status <code>queued</code>). It reaches <code>completed</code> or <code>failed</code> only from the driver’s real acknowledgement. Composer can be told through <strong>Action Completed</strong> / <strong>Action Failed</strong>.</p>';
    else if (d.approver === 'homeowner') html = '<p>The action becomes <code>pending_approval</code> for 30 minutes. The homeowner sees it in the portal (<code>POST /api/portal/ai-core/actions</code>, with the <code>args_hash</code> of what they saw). The platform can fire <strong>Approval Required</strong> and set <code>AI_PENDING_APPROVALS</code>.' + (/LOCK|GARAGE|SECURITY/.test(String(ex.calls.slice(-1)[0].op).toUpperCase()) || d.effectiveRisk === 'high' ? ' Approving sends it on to the queue’s own Control4 approval, a second, separate confirmation; AI Core never takes a code.' : '') + '</p>';
    else html = '<p>The action becomes <code>pending_approval</code>; the person who asked confirms the proposal (30-minute expiry). Only then is it queued.</p>';
    steps.push({ kind: 'Approval', html });
    const final = d.decision === 'deny' ? 'I can’t do that here: ' + (REASON_TEXT[d.reason] || d.reason) : d.decision === 'allow' ? 'Done: I queued the change under your pre-approved rule. I’ll report when the controller confirms it.' : 'I’ve proposed it. It needs ' + (d.approver === 'homeowner' ? 'the homeowner’s' : 'your') + ' approval before anything changes.';
    steps.push({ kind: 'Answer', html: '<p>' + esc(final) + '</p><p><small>Action tools only propose; the model is told to report the returned status exactly.</small></p>' });
  } else if (ex.answer) {
    const a = ex.answer;
    if (ex.dropped) steps.push({ kind: 'Evidence post-check', html: '<p>The model cited <code>' + ex.dropped + '</code>, which no tool returned in this turn. The post-check drops that citation; the claim that rested only on it is removed and counted. A confirmed claim never stays confirmed with demoted ids.</p>' });
    const kept = (list) => list.filter((c) => !ex.dropped || !c.event_ids.includes(ex.dropped));
    const claims = (list) => list.length ? '<ul>' + list.map((c) => '<li>' + esc(c.claim) + '<br><small>' + c.event_ids.map((i) => '<code>' + esc(i) + '</code>').join(' ') + '</small></li>').join('') + '</ul>' : '<p>none</p>';
    steps.push({ kind: 'Verified answer', html: '<p><strong>' + esc(a.answer) + '</strong></p><h4>Confirmed</h4>' + claims(kept(a.confirmed)) + '<h4>Possible</h4>' + claims(kept(a.possible)) + (a.unknowns.length ? '<h4>Unknown</h4><ul>' + a.unknowns.map((u) => '<li>' + esc(u) + '</li>').join('') + '</ul>' : '') + (a.suggested_next_steps.length ? '<h4>Suggested next steps</h4><ul>' + a.suggested_next_steps.map((u) => '<li>' + esc(u) + '</li>').join('') + '</ul>' : '') + (blocked ? '<p class="err">A read tool was refused, so the answer above could not be produced in this mode/licence; the real answer would be the refusal.</p>' : '') });
  }
  return steps;
}
function initWorkflow() {
  const sel = $('#wfExample');
  sel.innerHTML = WF_EXAMPLES.map((e) => '<option value="' + e.id + '">' + esc(e.title) + '</option>').join('');
  let pos = 0, steps = [];
  function render() {
    const ex = WF_EXAMPLES.find((e) => e.id === sel.value);
    steps = wfSteps(ex, $('#wfMode').value);
    $('#wfSteps').innerHTML = steps.map((s, i) => '<li data-i="' + i + '" class="' + (i > pos ? 'future' : '') + '"><span class="kind">' + (i + 1) + '. ' + esc(s.kind) + '</span>' + s.html + '</li>').join('');
    decorateCode($('#wfSteps'));
    $('#wfPos').textContent = 'Step ' + (pos + 1) + ' of ' + steps.length;
    $('#wfPrev').disabled = pos === 0; $('#wfNext').disabled = pos >= steps.length - 1;
  }
  sel.addEventListener('change', () => { pos = 0; render(); });
  $('#wfMode').addEventListener('change', () => { pos = 0; render(); });
  $('#wfNext').addEventListener('click', () => { if (pos < steps.length - 1) { pos++; render(); const li = $('#wfSteps li[data-i="' + pos + '"]'); if (li) li.scrollIntoView({ block: 'nearest' }); } });
  $('#wfPrev').addEventListener('click', () => { if (pos > 0) { pos--; render(); } });
  $('#wfAll').addEventListener('click', () => { pos = steps.length - 1; render(); });
  $('#wfReset').addEventListener('click', () => { pos = 0; render(); });
  render();
}
