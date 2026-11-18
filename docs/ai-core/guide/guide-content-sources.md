# SmartBuildOS AI Core Interactive Guide — content sources

`SmartBuildOS_AI_Core_Interactive_Guide.html` is built from `src/` with `src/build.sh`.
Every status callout comes from the single `STATUS` object at the top of `src/p4a.js`.
Repos: driver = this repo (branch `feat/ai-core`); platform = `../smartbuildos-ai-core`
(branch `codex/ai-core`, read only); program = `../ai-core-program`. Sources read on 2026-11-18.

| Chapter | Written from |
| --- | --- |
| 1 Introduction | program `ARCHITECTURE.md` §1–§3, §7, §8; `IMPLEMENTATION_CHECKLIST.md` (all phases); driver `docs/ai-core/DRIVER.md` (header, §14); `drivers/smartbuildos-ai-core/driver.xml` (`minimum_os_version`); `www/documentation/index.md` |
| 2 Installation | `DRIVER.md` §1–§2, §6, §13; `driver.xml` (`<connections>`, `<proxies>`, actions); `www/documentation/index.md` (Setup); `docs/flight-recorder/PROTOCOL.md` §2 (registration); checklist 3.x, 10.8, 10.12 |
| 3 AI Provider Setup | platform `src/lib/ai-core/providers/README.md`, `providers/registry.ts`, `providers/errors.ts`, `providers/pricing.ts`; `credentials/vault.ts`; `src/app/api/monitoring/ai-core/credentials/route.ts`, `credentials/test/route.ts`; `rpc/status.ts` (settings defaults); `settings/settings.ts` (limits, model validation); `budget/budget.ts`; program `analysis/05-ai-and-concierge-apis.md` Parts 1–2; checklist Phase 5, owner decision 6 |
| 4 SmartBuildOS Agent Integration | `DRIVER.md` §6, §7, §9, §12; `docs/protocol/MODULE-CONTRACT-V2.md` §1–§2; `PROTOCOL.md` §2, §5, §6; `src/aicore/state.lua`, `src/aicore/commands.lua`, `drivers/smartbuildos-ai-core/driver.lua` (licence wording) |
| 5 Flight Recorder Integration | `DRIVER.md` §8, §10; `src/flightrecorder/localquery.lua` (via DRIVER.md §8); `src/aicore/diagnostic.lua` (reason keys); `docs/flight-recorder/PRIVACY-RETENTION-LIMITS.md`; platform `tools/flight-recorder.ts`; `PROTOCOL.md` §3 (envelope); checklist 4.x |
| 6 Driver-to-Driver Integration | `MODULE-CONTRACT-V2.md` (all sections); `PROTOCOL.md` §3.1 (prefix ownership); platform `src/lib/ai-core/protocol.ts` (policy mirror) |
| 7 Household Learning | platform `src/lib/ai-core/memory/README.md`; `patterns/types.ts`, `patterns/detectors.ts`; `memory/types.ts`; `tools/memory.ts` (memory_search, memory_propose); `rpc/ops.ts` (learn_preference); routes `monitoring/ai-core/{memories,patterns,recommendations}`, `portal/ai-core/{learning,memories}`; checklist Phase 6 |
| 8 Intelligent Automation | platform `authz/engine.ts`, `authz/targets.ts`; `actions/lifecycle.ts`, `actions/verbs.ts`; `tools/actions.ts`; `recommendations/lifecycle.ts`; routes `monitoring/ai-core/{actions,rules,programming}`, `portal/ai-core/{actions,rules}`; `src/lib/control4/commands.ts`; checklist Phase 7, owner decision 9 |
| 9 Lifestyle Concierge | platform `concierge/lifecycle.ts`, `concierge/providers/registry.ts`, `tools/concierge.ts`; routes `portal/ai-core/{concierge,calendar}`, `monitoring/ai-core/concierge`; `ARCHITECTURE.md` D12, §8; `analysis/05` Part 6; checklist Phase 9 |
| 10 System Studio | platform `src/lib/system-studio/navigation.ts` (working tree); routes `monitoring/ai-core/{overview,household-usage,flight-recorder,settings,usage,service/*,conversations}`; `tools/service.ts`; checklist Phase 8; `ARCHITECTURE.md` D13 |
| 11 Control4 Programming | `driver.xml` (every name; checked by `test/consistency.test.mjs`); `DRIVER.md` §1–§5; `src/aicore/commands.lua` (required params, refusal wording); `www/documentation/index.md` |
| 12 Security | `ARCHITECTURE.md` §1, §6, D2, D14; platform `authz/engine.ts`, `authz/types.ts`; `credentials/vault.ts`; `orchestrator/turn.ts`, `orchestrator/answer.ts`; `providers/README.md`; `memory/README.md`; checklist 7.5–7.7, 10.11 |
| 13 Troubleshooting | `DRIVER.md` §3, §6, §8–§12; `www/documentation/index.md` (Troubleshooting); `src/aicore/commands.lua`, `driver.lua`; platform `settings/settings.ts`, `budget/budget.ts`, `providers/errors.ts`, `actions/lifecycle.ts` |
| 14 Developer Reference | `MODULE-CONTRACT-V2.md` §3, §4, §9–§13, §15; `PROTOCOL.md` §2–§3; `DRIVER.md` §11, §14; platform tool registry (dumped by `src/dump-tools.mjs` into `src/tool-registry.json`); `src/app/api/**/ai-core/**/route.ts` header comments; `analysis/04-driverworks-sdk.md` §J |
| Verification status | `STATUS` object (`src/p4a.js`), from `IMPLEMENTATION_CHECKLIST.md` |

## Interactive features and their data

| Feature | Data source |
| --- | --- |
| Installation Wizard | `DRIVER.md` §6 (state texts), `vault.ts` `validateApiKey` (key shape rule) |
| Architecture Explorer | `ARCHITECTURE.md` §4–§6; platform directory layout |
| Driver Communication Explorer | `MODULE-CONTRACT-V2.md` §4–§13; `PROTOCOL.md` §2; `DRIVER.md` §3, §8 |
| AI Workflow Simulator | `orchestrator/turn.ts`, `orchestrator/answer.ts`; tool registry; decisions from the transcribed engine |
| Telemetry Explorer | `PROTOCOL.md` §3 (envelope fields); event types from `DRIVER.md` §11 and `PRIVACY-RETENTION-LIMITS.md` (sample values invented and labelled) |
| Composer Programming Examples | `driver.xml` names only |
| Troubleshooting Assistant | as Chapter 13 |
| Permissions Explorer | transcription of platform `authz/engine.ts`, `authz/targets.ts`, `control4/commands.ts`; tested against the real engine |
| Command Reference | `driver.xml` (via `src/refdata.mjs`) |
| Installation Checklist | `www/documentation/index.md` Setup; `DRIVER.md`; `rpc/status.ts` defaults |

## Tests

`test/consistency.test.mjs` (names vs `driver.xml`, contract v2 frames and error codes, `vocab.lua`, the platform registry) and
`test/guide.browser.test.mjs` (every control in Chromium from `file://`; screenshots to `../ai-core-program/screenshots/guide/`). Run both with `test/run.sh`.
