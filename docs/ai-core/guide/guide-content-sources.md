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
  registry from the factories `tools/index.ts` exports, now including `createDriverTools`, which
  takes one options object `{ port }`; 37 tools). The 2026-11-18 evening refresh produced it this
  way: the script only imports the platform's TypeScript modules read-only and writes to this
  repo's `src/`; nothing is written in the platform worktree. The consistency and browser tests
  build the registry the same way.
* Screenshots of the pages added on 2026-11-18 (the portal's *Touchscreen permissions*, Studio's
  *Connected drivers*, the touchscreen tile) do not exist: the platform's browser spec writes them
  only when `AI_CORE_SCREENSHOT_DIR` is set and no such run left files in its output folders or in
  `ai-core-program/screenshots/`. The guide describes those pages in words and says "screenshot
  pending" (Chapters 8 and 10, Verification). No product screen is mocked up.
* `src/shots/*.webp` are regenerated with `src/make-shots.sh` from
  `ai-core-program/screenshots/{studio-a,studio-b,portal}` (fixture mode, sample data; 960 px wide,
  WebP quality 55). Each figure caption names its source file and says it is fixture/sample data.

Repos: driver = this repo (branch `feat/ai-core`); platform = `../smartbuildos-ai-core` (branch
`codex/ai-core`, read only); program = `../ai-core-program`. Refreshed on 2026-11-18 against the
checklist as it read then and the platform's committed head (see `PLATFORM_HEAD`). Refreshed again
on the evening of 2026-11-18 (brief D8b) against `docs/ai-core/program/IMPLEMENTATION_CHECKLIST.md`
(evening), `ARCHITECTURE.md`, `FINAL_IMPLEMENTATION_REPORT.md`, the conductor's facts file
`ai-core-program/STATUS-2026-11-18-evening.md` and `SPEC-webview-and-driver-reporting.md` §8, and the
platform at `dbdd9b67c`. Final totals the conductor has not yet written (`⟨conductor: …⟩`) are never
shown: the guide says they are being finalised.

| Chapter | Written from |
| --- | --- |
| 1 Introduction | program `ARCHITECTURE.md`; `IMPLEMENTATION_CHECKLIST.md` (all phases, incl. 11 and 12); driver `docs/ai-core/DRIVER.md` header, §7a, §7b, §14; `INSTALLATION.md` §10 (PIN Lock requirement); `KNOWN-ISSUES.md` |
| 2 Installation | driver `docs/ai-core/INSTALLATION.md` §1–§8 (prerequisites, obtaining, order, property texts per step, pairing, verifying, first sync, failures) and §10 (the tile, PIN Lock, the homeowner's switches, home network only); `RELEASE.md` §1–§3; `driver.xml` (the `uibutton` proxy on binding 5001, its connection and web view — checked by the consistency test); `DRIVER.md` §1, §2, §7b; platform `supabase/migrations/20261118120100_driver_catalog_ai_core.sql` and `src/lib/ai-core/licensing.ts` (explicit-entitlement licensing); price and purchase rules from checklist 2.15, 10.13 and the facts file (decision 2; rulings: purchase feature set, not buyable until a release is published, MSRP only on public surfaces); the only build from checklist 10.8 |
| 3 AI Provider Setup | the household analysis schedule control: platform `AiProviderSetup.tsx` (*Household analysis schedule*); platform `src/components/system-studio/intelligence/{IntelligenceOverview,AiProviderSetup}.tsx` (Provider & settings tab, texts); `docs/ai-core/DEVELOPER-API.md` §3.1–§3.2, §9; `providers/{registry,errors,pricing}.ts`; `credentials/vault.ts`; `orchestrator/turn.ts` (turn status texts), `orchestrator/answer.ts`; screenshot `studio-a/mock-desktop-02-setup.png` |
| 4 SmartBuildOS Agent Integration | `DRIVER.md` §6, §7 (eight restricted operations incl. `run_driver_query`, `invoke_driver_action`), §9, §12; platform `src/lib/control4/commands.ts` (six staff-refused operations); platform `docs/ai-core/DRIVER-CONTRACT.md`; `settings/{settings,driver-config}.ts`; `src/lib/control4/commands.ts` (`STAFF_REFUSED_MODULE_OPERATIONS`); `KNOWN-ISSUES.md` KI-5–KI-8, KI-24, KI-25; checklist 3.11, 10.1 |
| 5 Flight Recorder Integration | `DRIVER.md` §8–§10; `src/flightrecorder/localquery.lua`; `docs/flight-recorder/PRIVACY-RETENTION-LIMITS.md`; checklist 4.x |
| 6 Driver-to-Driver Integration | `docs/protocol/MODULE-CONTRACT-V2.md` (incl. §3 identity binding); `DRIVER.md` §7a (report hub, queries, actions), §9 (configuration contract and precedence); `docs/DRIVER_PLATFORM_GUIDE.md` §9 (the helper, the passive module, the four report kinds, declared queries and actions, the `AI Core` property and its 15 values — transcribed from `src/sbos/aivalues.lua`; the "For the dealer" column restates each value's "When" as the action it implies); platform `DRIVER-CONTRACT.md`, `tools/drivers.ts` (the three driver tools); checklist 12.1–12.20; facts file (rollout counts, ruling: limits 64 / 2,000 / 30 days); `KNOWN-ISSUES.md` KI-8, KI-42, KI-45, KI-46, KI-49 |
| 7 Household Learning | `DRIVER.md` §3 (*Run Household Analysis*), §9; `INSTALLATION.md` §9; platform `AiProviderSetup.tsx` (schedule texts), `patterns/entry.ts`; checklist 6.7; facts file (no budget gate, one analysis at a time); `KNOWN-ISSUES.md` KI-40; platform `memory/{README,programming,portal}.ts`, `rpc/ops.ts` (`learn_preference`), `patterns/*`; portal `src/components/portal/ai-core/{LearnedPanel,model}.tsx`; `DEVELOPER-API.md` §4, §10.1; screenshot `portal/fx-1280-30-learned.png` |
| 8 Intelligent Automation | touchscreen sections: `DRIVER.md` §7b (routes, chat lock, conversation bounds, approvals, fail closed), `www/app/index.html` and `src/aicore/webui.lua` (button texts, `SUGGESTIONS`), `INSTALLATION.md` §10, platform `actions/touchscreen-text.ts` (switch texts), portal `ApprovalsPanel.tsx` `TouchscreenSection`, routes `src/app/api/{portal,monitoring}/ai-core/touchscreen/route.ts`, checklist 11.1–11.12, owner decisions 16–20, `KNOWN-ISSUES.md` KI-58; the medium risk class from `authz/engine.ts`; platform `authz/engine.ts`, `actions/{lifecycle,rules,service}.ts`, `programming/handoff.ts`; Studio `ActionsApprovals.tsx`, `ProgrammingHandoff.tsx`; portal `ApprovalsPanel.tsx`; `DEVELOPER-API.md` §3.8, §8, §10.1; screenshot `portal/fx-1280-22-lock-approved-second-step.png` |
| 9 Lifestyle Concierge | platform `concierge/{lifecycle,service,services,server}.ts`, `concierge/providers/{registry,sandbox}.ts`, `tools/concierge.ts`; portal `ConciergePanel.tsx`, `ReservationCard.tsx`, `CalendarPanel.tsx`, `model.ts`; `DEVELOPER-API.md` §4, §10.1; screenshots `portal/fx-1280-05-final-confirmation.png`, `fx-1280-07-simulated-confirmed-scene-offer.png` |
| 10 System Studio | Connected drivers: platform `ConnectedDrivers.tsx` (quoted texts), `src/app/api/monitoring/ai-core/drivers/route.ts`, checklist 12.12 (no screenshot: "screenshot pending"); platform `src/lib/system-studio/navigation.ts`; `src/components/system-studio/intelligence/*.tsx`; `DEVELOPER-API.md` §3; checklist Phase 8; screenshots `studio-a/mock-desktop-{01-overview,20-usage-overview,42-fr-incident}.png`, `studio-b/mock-desktop-{01-rec-list,47-conv-progress-final-answer,71-svc-finding-playbook-network}.png` |
| 11 Control4 Programming | `driver.xml` (every name; checked by `test/consistency.test.mjs`); `DRIVER.md` §1–§5, §11 (text cleaning, byte limits, required parameters, defaults, `AI_RECORD_EVENT` ruling, `AI_LAST_CORRELATION_ID`, `status` body); `src/aicore/commands.lua`; `KNOWN-ISSUES.md` KI-1 |
| 12 Security | platform `src/lib/control4/commands.ts` `STAFF_REFUSED_MODULE_OPERATIONS` (six); `ARCHITECTURE.md` §1, §6; platform `authz/engine.ts`; `credentials/vault.ts`; `DEVELOPER-API.md` §2 (gate order), §10; `DRIVER-CONTRACT.md` (staff-refused operations); checklist 7.5–7.7 |
| 13 Troubleshooting | `INSTALLATION.md` §8; `DRIVER.md` §3, §6, §8–§12; platform `orchestrator/turn.ts`, `AiProviderSetup.tsx`, portal `model.ts`, `ConciergePanel.tsx` (quoted failure texts) |
| 14 Developer Reference | `MODULE-CONTRACT-V2.md`; `DRIVER.md` §11; platform tool registry (`src/dump-tools.mjs` → `src/tool-registry.json`); `orchestrator/{server,turn}.ts` and `concierge/server.ts` (per-persona offering); route files under `src/app/api/{monitoring,portal}/ai-core/**`; links to platform `docs/ai-core/{DEVELOPER-API,DRIVER-CONTRACT,MIGRATIONS,TEST-MATRIX,OPERATIONS}.md` |
| Verification status | `STATUS` and `VERIFY` (`src/p4a.js`), from `IMPLEMENTATION_CHECKLIST.md` (items and open owner decisions 3, 5–7, 9–23; decided 1, 2, 4): `simulated` = Completed rows the conductor reran, `reported` = Tested rows (or worker-reported database runs), `never`, `decided`, `owner`, `unreleased`; the migration review from checklist 10.14 and the facts file (`migrations-review/REVIEW.md` verdict and fix list) |

## Interactive features and their data

| Feature | Data source |
| --- | --- |
| Installation Wizard | `INSTALLATION.md` §4, §7 (state texts), `vault.ts` `validateApiKey` (key shape rule) |
| Architecture Explorer | `ARCHITECTURE.md` §4–§6; platform directory layout. Below 640 px it is shown as stacked layers of buttons (the SVG is hidden) |
| Driver Communication Explorer | `MODULE-CONTRACT-V2.md` §4–§13; `DRIVER.md` §3, §8, §9. Below 640 px the sequence is a vertical step list with from → to and the frame name |
| AI Workflow Simulator | per-persona registries transcribed from `orchestrator/server.ts` `aiCoreRegistry` (incl. `createDriverTools`: list and query for every turn, propose only in a person's conversation) and `concierge/server.ts` `portalConversationDeps`, filtered as `orchestrator/turn.ts` `offeredTools` does; decisions from the transcribed engine; the concierge example follows `concierge/lifecycle.ts`, `service.ts` (`submitBooking` → `not_confirmed`) and `providers/sandbox.ts`, every step labelled SIMULATION |
| Telemetry Explorer | `PROTOCOL.md` §3 (envelope fields); event types from `DRIVER.md` §11 (sample values invented and labelled) |
| Composer Programming Examples | `driver.xml` names only |
| Troubleshooting Assistant | as Chapter 13 |
| Permissions Explorer | transcription of platform `authz/engine.ts` (incl. the `medium` risk class), `authz/targets.ts`, `control4/commands.ts`; tested against the real engine |
| Command Reference | `driver.xml` (via `src/refdata.mjs`) |
| Installation Checklist | `INSTALLATION.md`; `DRIVER.md`; `rpc/status.ts` defaults |

## Tests

`test/consistency.test.mjs` — names vs `driver.xml`; contract v2 frames and error codes; `vocab.lua`;
the live platform tool registry and the stated tool count; tool-like names in prose; the route index vs
the platform's `route.ts` files (and every route named in prose); stated facts (learning off by default,
`exclusions.rooms` ≤ 500, `set_learning` `config_version`, the one `uibutton` proxy on binding 5001 and its connection and web view, `apply_config` superseded, `set_context`
body key, `learn_preference` not unsupported, real booking never "available"); `KI-n` references vs
`KNOWN-ISSUES.md`; checklist statuses (a sentence calling items Completed names only Completed items;
a Blocked item is never called available; the Verification page's lists and owner decisions match the
checklist: the conductor-reran list cites only Completed rows, the worker-reported list only Completed or
Tested rows).

`test/guide.browser.test.mjs` — every control in Chromium from `file://`; the Permissions Explorer vs the
real engine; the Workflow Simulator's per-persona tool lists vs the real `offeredTools` over the real
registry (and the registry composition vs `orchestrator/server.ts` / `concierge/server.ts`); the booking
example end to end in every mode; the phone layouts of both diagrams at 360 px (minimum font size, no
clipped text); embedded images (`data:` only, decode, captions); zero network requests; zero console
errors; no horizontal overflow at 360 / 768 / 1280. Screenshots go to
`../ai-core-program/screenshots/guide/`. Run both with `test/run.sh`.
