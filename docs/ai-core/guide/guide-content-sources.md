# SmartBuildOS AI Core Interactive Guide — content sources

`SmartBuildOS_AI_Core_Interactive_Guide.html` is built from `src/` with `src/build.sh`:
`p1.html` (head, styles), `p2.html` (chapters 1–7), `p3.html` (chapters 8–14, Verification status)
piped through `src/inline-shots.mjs` (embeds `src/shots/*.webp` as `data:` URIs), then the reference
JSON from `src/refdata.mjs` (which reads `src/tool-registry.json`), then `p4a.js`–`p4f.js`.

* Every status callout comes from the single `STATUS` object at the top of `src/p4a.js`; the
  Verification status page lists come from `VERIFY` in the same file, and `PLATFORM_HEAD` names the
  platform commit described.
* `src/tool-registry.json` is regenerated with
  `node --experimental-strip-types src/dump-tools.mjs > src/tool-registry.json` (it builds the
  registry from the factories `tools/index.ts` exports).
* `src/shots/*.webp` are regenerated with `src/make-shots.sh` from
  `ai-core-program/screenshots/{studio-a,studio-b,portal}` (fixture mode, sample data; 960 px wide,
  WebP quality 55). Each figure caption names its source file and says it is fixture/sample data.

Repos: driver = this repo (branch `feat/ai-core`); platform = `../smartbuildos-ai-core` (branch
`codex/ai-core`, read only); program = `../ai-core-program`. Refreshed on 2026-11-18 against the
checklist as it read then and the platform's committed head (see `PLATFORM_HEAD`).

| Chapter | Written from |
| --- | --- |
| 1 Introduction | program `ARCHITECTURE.md`; `IMPLEMENTATION_CHECKLIST.md` (all phases); driver `docs/ai-core/DRIVER.md` header, §14; `KNOWN-ISSUES.md` |
| 2 Installation | driver `docs/ai-core/INSTALLATION.md` §1–§8 (prerequisites, obtaining, order, property texts per step, pairing, verifying, first sync, failures); `RELEASE.md` §1–§3; `driver.xml`; platform `supabase/migrations/20261118120100_driver_catalog_ai_core.sql` and `src/lib/ai-core/licensing.ts` (explicit-entitlement licensing) |
| 3 AI Provider Setup | platform `src/components/system-studio/intelligence/{IntelligenceOverview,AiProviderSetup}.tsx` (Provider & settings tab, texts); `docs/ai-core/DEVELOPER-API.md` §3.1–§3.2, §9; `providers/{registry,errors,pricing}.ts`; `credentials/vault.ts`; `orchestrator/turn.ts` (turn status texts), `orchestrator/answer.ts`; screenshot `studio-a/mock-desktop-02-setup.png` |
| 4 SmartBuildOS Agent Integration | `DRIVER.md` §6, §7, §9, §12; platform `docs/ai-core/DRIVER-CONTRACT.md`; `settings/{settings,driver-config}.ts`; `src/lib/control4/commands.ts` (`STAFF_REFUSED_MODULE_OPERATIONS`); `KNOWN-ISSUES.md` KI-5–KI-8, KI-24, KI-25; checklist 3.11, 10.1 |
| 5 Flight Recorder Integration | `DRIVER.md` §8–§10; `src/flightrecorder/localquery.lua`; `docs/flight-recorder/PRIVACY-RETENTION-LIMITS.md`; checklist 4.x |
| 6 Driver-to-Driver Integration | `docs/protocol/MODULE-CONTRACT-V2.md`; `DRIVER.md` §9 (configuration contract and precedence); platform `DRIVER-CONTRACT.md`; `KNOWN-ISSUES.md` KI-8 |
| 7 Household Learning | `DRIVER.md` §3, §9; platform `memory/{README,programming,portal}.ts`, `rpc/ops.ts` (`learn_preference`), `patterns/*`; portal `src/components/portal/ai-core/{LearnedPanel,model}.tsx`; `DEVELOPER-API.md` §4, §10.1; screenshot `portal/fx-1280-30-learned.png` |
| 8 Intelligent Automation | platform `authz/engine.ts`, `actions/{lifecycle,rules,service}.ts`, `programming/handoff.ts`; Studio `ActionsApprovals.tsx`, `ProgrammingHandoff.tsx`; portal `ApprovalsPanel.tsx`; `DEVELOPER-API.md` §3.8, §8, §10.1; screenshot `portal/fx-1280-22-lock-approved-second-step.png` |
| 9 Lifestyle Concierge | platform `concierge/{lifecycle,service,services,server}.ts`, `concierge/providers/{registry,sandbox}.ts`, `tools/concierge.ts`; portal `ConciergePanel.tsx`, `ReservationCard.tsx`, `CalendarPanel.tsx`, `model.ts`; `DEVELOPER-API.md` §4, §10.1; screenshots `portal/fx-1280-05-final-confirmation.png`, `fx-1280-07-simulated-confirmed-scene-offer.png` |
| 10 System Studio | platform `src/lib/system-studio/navigation.ts`; `src/components/system-studio/intelligence/*.tsx`; `DEVELOPER-API.md` §3; checklist Phase 8; screenshots `studio-a/mock-desktop-{01-overview,20-usage-overview,42-fr-incident}.png`, `studio-b/mock-desktop-{01-rec-list,47-conv-progress-final-answer,71-svc-finding-playbook-network}.png` |
| 11 Control4 Programming | `driver.xml` (every name; checked by `test/consistency.test.mjs`); `DRIVER.md` §1–§5, §11 (text cleaning, byte limits, required parameters, defaults, `AI_RECORD_EVENT` ruling, `AI_LAST_CORRELATION_ID`, `status` body); `src/aicore/commands.lua`; `KNOWN-ISSUES.md` KI-1 |
| 12 Security | `ARCHITECTURE.md` §1, §6; platform `authz/engine.ts`; `credentials/vault.ts`; `DEVELOPER-API.md` §2 (gate order), §10; `DRIVER-CONTRACT.md` (staff-refused operations); checklist 7.5–7.7 |
| 13 Troubleshooting | `INSTALLATION.md` §8; `DRIVER.md` §3, §6, §8–§12; platform `orchestrator/turn.ts`, `AiProviderSetup.tsx`, portal `model.ts`, `ConciergePanel.tsx` (quoted failure texts) |
| 14 Developer Reference | `MODULE-CONTRACT-V2.md`; `DRIVER.md` §11; platform tool registry (`src/dump-tools.mjs` → `src/tool-registry.json`); `orchestrator/{server,turn}.ts` and `concierge/server.ts` (per-persona offering); route files under `src/app/api/{monitoring,portal}/ai-core/**`; links to platform `docs/ai-core/{DEVELOPER-API,DRIVER-CONTRACT,MIGRATIONS,TEST-MATRIX,OPERATIONS}.md` |
| Verification status | `STATUS` and `VERIFY` (`src/p4a.js`), from `IMPLEMENTATION_CHECKLIST.md` (items and open owner decisions) |

## Interactive features and their data

| Feature | Data source |
| --- | --- |
| Installation Wizard | `INSTALLATION.md` §4, §7 (state texts), `vault.ts` `validateApiKey` (key shape rule) |
| Architecture Explorer | `ARCHITECTURE.md` §4–§6; platform directory layout. Below 640 px it is shown as stacked layers of buttons (the SVG is hidden) |
| Driver Communication Explorer | `MODULE-CONTRACT-V2.md` §4–§13; `DRIVER.md` §3, §8, §9. Below 640 px the sequence is a vertical step list with from → to and the frame name |
| AI Workflow Simulator | per-persona registries transcribed from `orchestrator/server.ts` `aiCoreRegistry` and `concierge/server.ts` `portalConversationDeps`, filtered as `orchestrator/turn.ts` `offeredTools` does; decisions from the transcribed engine; the concierge example follows `concierge/lifecycle.ts`, `service.ts` (`submitBooking` → `not_confirmed`) and `providers/sandbox.ts`, every step labelled SIMULATION |
| Telemetry Explorer | `PROTOCOL.md` §3 (envelope fields); event types from `DRIVER.md` §11 (sample values invented and labelled) |
| Composer Programming Examples | `driver.xml` names only |
| Troubleshooting Assistant | as Chapter 13 |
| Permissions Explorer | transcription of platform `authz/engine.ts`, `authz/targets.ts`, `control4/commands.ts`; tested against the real engine |
| Command Reference | `driver.xml` (via `src/refdata.mjs`) |
| Installation Checklist | `INSTALLATION.md`; `DRIVER.md`; `rpc/status.ts` defaults |

## Tests

`test/consistency.test.mjs` — names vs `driver.xml`; contract v2 frames and error codes; `vocab.lua`;
the live platform tool registry and the stated tool count; tool-like names in prose; the route index vs
the platform's `route.ts` files (and every route named in prose); stated facts (learning off by default,
`exclusions.rooms` ≤ 500, `set_learning` `config_version`, `apply_config` superseded, `set_context`
body key, `learn_preference` not unsupported, real booking never "available"); `KI-n` references vs
`KNOWN-ISSUES.md`; checklist statuses (a sentence calling items Completed names only Completed items;
a Blocked item is never called available; the Verification page's lists and owner decisions match the
checklist).

`test/guide.browser.test.mjs` — every control in Chromium from `file://`; the Permissions Explorer vs the
real engine; the Workflow Simulator's per-persona tool lists vs the real `offeredTools` over the real
registry (and the registry composition vs `orchestrator/server.ts` / `concierge/server.ts`); the booking
example end to end in every mode; the phone layouts of both diagrams at 360 px (minimum font size, no
clipped text); embedded images (`data:` only, decode, captions); zero network requests; zero console
errors; no horizontal overflow at 360 / 768 / 1280. Screenshots go to
`../ai-core-program/screenshots/guide/`. Run both with `test/run.sh`.
