// Dumps the platform tool registry (read-only import) to stdout: node --experimental-strip-types dump-tools.mjs > tool-registry.json
import path from 'node:path'; import { fileURLToPath } from 'node:url';
const here = path.dirname(fileURLToPath(import.meta.url));
const base = (process.env.AI_CORE_PLATFORM || path.resolve(here, '../../../../../smartbuildos-ai-core')) + '/src/lib/ai-core/tools/';
const port = new Proxy({}, { get: (t, k) => (k === 'then' ? undefined : async () => ({})) });
const out = [];
const add = (list) => { for (const t of list) out.push({ id: t.id, wire: t.wireName, risk: t.risk, household: t.household, feature: t.feature, verb: t.verb, description: t.description, schema: t.schema }); };
add((await import(base + 'flight-recorder.ts')).FLIGHT_RECORDER_TOOLS);
add((await import(base + 'context.ts')).CONTEXT_TOOLS);
for (const [f, fn, args] of [['memory.ts','createMemoryTools',[port]],['service.ts','createServiceTools',[port]],['notifications.ts','createNotificationTools',[port]],['actions.ts','createActionTools',[port,{}]],['concierge.ts','createConciergeTools',[port]]]) {
  try { add((await import(base + f))[fn](...args)); } catch (e) { console.error(f, e.message); }
}
console.log(JSON.stringify(out, null, 1));
