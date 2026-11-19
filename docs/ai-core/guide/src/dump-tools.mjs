// Dumps the platform tool registry (read-only import) to stdout: node --experimental-strip-types dump-tools.mjs > tool-registry.json
// Built from the factories tools/index.ts exports, so a tool added or removed there shows up here.
import path from 'node:path'; import { fileURLToPath } from 'node:url';
const here = path.dirname(fileURLToPath(import.meta.url));
const base = (process.env.AI_CORE_PLATFORM || path.resolve(here, '../../../../../smartbuildos-ai-core')) + '/src/lib/ai-core/tools/';
const port = new Proxy({}, { get: (t, k) => (k === 'then' ? undefined : async () => ({})) });
const idx = await import(base + 'index.ts');
const list = [...idx.READ_TOOLS];
for (const [name, args] of [['createMemoryTools', [port]], ['createServiceTools', [port]], ['createNotificationTools', [port]], ['createActionTools', [port, {}]], ['createConciergeTools', [port]], ['createDriverTools', [{ port }]]]) {
  if (typeof idx[name] === 'function') list.push(...idx[name](...args));
}
const out = list.map((t) => ({ id: t.id, wire: t.wireName, risk: t.risk, household: t.household, feature: t.feature, verb: t.verb, audience: t.audience ?? 'everyone', description: t.description, schema: t.schema }));
console.log(JSON.stringify(out, null, 1));
