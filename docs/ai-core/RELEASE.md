# SmartBuildOS AI Core — release and deployment

What this repo does **today** to build, version, tag and publish a driver,
read from `Makefile`, `.github/workflows/*.yml`, `CONTRIBUTING.md`,
`src/lib/{github,sbos}-updater.lua` and the repo's release history; then the
ordered AI Core release across the driver repo and the platform, with a
rollback for each step. Steps marked **owner action** are not an engineer's
to take (tags, releases, store publication, production migrations,
deploys). Nothing here has been done for AI Core: no tag, no release, no
store package, no production migration.

## 1. How a build is made

`make init` once (Python venv from `requirements.txt`; clones Control4's
driverpackager into `dist/driverpackager`). Then:

```
make build = check-deps clean-build fmt embed-pages preprocess gen-squishy
             update-xml docs package zip install-local
```

| Step | What it does | Trap |
| --- | --- | --- |
| `fmt` | stylua over `drivers/ src/ test/ tools/ vendor/`, black over `tools/*.py`, mdformat `--wrap 80` over the root `*.md`, `documentation/*.md` and every `drivers/*/www/documentation/*.md` | **Rewrites tracked files.** CI's Build job fails on a dirty tree after `make build`, so run it on a clean checkout and commit what it changed. `docs/ai-core/*.md` is not formatted. |
| `preprocess` | copies into `build/oss/`, resolving `#ifdef` (distribution `oss`) | |
| `gen-squishy` | loads each `driver.lua` under the shim and writes a squish manifest of exactly the modules it required | A `require` inside a function is never seen and is left out of the `.c4z` (guarded by `test/test_driver_require_guard.lua`) |
| `update-xml` | stamps `<version>` with `date -u +'%Y%m%d.%H%M%S'` (UTC, seconds) and `<modified>` | One stamp for every driver of that build. `<version>` must be empty in source (`test/test_driver_xml_guard.lua`) |
| `docs` | README from the Agent manual, each manual → HTML (inside the `.c4z`) and PDF (`dist/oss/<Name> Documentation.pdf`) | needs weasyprint |
| `package` | driverpackager per `driver.c4zproj` → `dist/oss/<driver>.c4z` (squished Lua, not encrypted) | |
| `zip` | `dist/oss/<repo-folder-name>.zip` of every `.c4z` and PDF | the zip is named after the checkout folder |
| `install-local` | **copies every `.c4z` into `~/Documents/Control4/Drivers`** (creates it if missing) | overwrites what Composer loads; override with `COMPOSER_DRIVERS=<dir>` |

`make lint` (luacheck) is not part of `make build` and CI does not run it.

CI (`.github/workflows/build.yml`) runs on pushes to `main`, on `v*` tags and
on pull requests: `make init`, `make test`, `make build`, a PDF check, the
dirty-tree check, and uploads `dist/oss/*` as the artifact `oss`. A CI build
stamps its own version (the runner's clock), so its `.c4z` versions differ
from any local build of the same commit.

**Building without touching the worktree** (what was done for AI Core):
copy the tree to a scratch folder and run the targets there with
`COMPOSER_DRIVERS` pointed inside the scratch folder; diff the formatted
files back to see what `fmt` would change.

## 2. Versions and tags

* The version a controller runs is the `<version>` inside the `.c4z`
  (`YYYYMMDD.HHMMSS`, UTC, minted at build). `Driver Version` shows it.
* Recent tags are the bare build stamp (`20261116.035552`), with prefixes for
  pre-releases (`beta-20261116.035552`, `system-link-beta-20261109.044817`);
  older ones were `v20260901.1`.
* `release.yml` runs **only on `v*` tags** (waits for that commit's Build,
  downloads its artifact, creates the release). The November releases carry
  bare tags, so it did not run for them: they were created by hand
  (`gh release create`) with the locally built `dist/oss/*.c4z`, the PDFs and
  the zip as assets (the latest, `20261116.035552`, has 42 `.c4z`, 42 PDFs and `control4-smartbuildos-release.zip`).
* `publish-to-store.yml` runs when a release is **published** (a hand-made
  release triggers it; a release created by another workflow's token does
  not) or by hand (`workflow_dispatch` with a tag). It downloads the
  release's `.c4z`, maps each file to a catalogue SKU with `sku_for()`, reads
  the `<version>` **inside** each `.c4z`, and POSTs it to `STORE_UPLOAD_URL`
  (channel `BETA` for a pre-release, `STABLE` otherwise; only `STABLE`
  advances the catalogue's current version). Unmapped files print `skip …
  (no catalog SKU)`. It is dormant until the two store secrets are set.
* `sku_for()` maps `smartbuildos-ai-core.c4z` → `SBOS_AI_CORE`.
  **`smartbuildos-flight-recorder.c4z` is not mapped**: CI never uploads the
  Flight Recorder to the store.

### The two updaters (on the Agent)

| | GitHub updater (`lib.github-updater`, colon calls) | SmartBuildOS updater (`lib.sbos-updater`, dot calls) |
| --- | --- | --- |
| Compares | the release **tag**, parsed by `vendor/version.lua`, with the installed version | each package's `version` = the `<version>` inside the uploaded `.c4z` |
| Picks | the first non-draft release in GitHub's order (pre-releases only on the Prerelease channel) | newer than installed only: never a downgrade, never a driver not already in the project |
| Files | the Agent's `DRIVER_FILENAMES` (includes `smartbuildos-ai-core.c4z`, **not** the Flight Recorder) | `DRIVER_FILENAMES` plus filenames the platform's authenticated manifest lists |

So: a tag must parse as a version greater than what is installed, and should
**be** the build stamp inside the `.c4z` — a CI build triggered by a `v*` tag
restamps the version, so the tag and the files then disagree.

## 3. Ordered release of AI Core

Each step depends on the one before it. A later step must not ship while an
earlier one is undone.

| # | Step | Who | Done means | Rollback |
| --- | --- | --- | --- | --- |
| 1 | Review and apply the platform's AI Core migrations (`supabase/migrations/20261118*_ai_core_*.sql`, `…_driver_catalog_ai_core.sql`; each names its rollback script in its header) to production | **owner action** | the `ai_core_*` tables, the `control4_commands` provenance columns and the `SBOS_AI_CORE` catalogue row exist | run each migration's rollback script, newest first (owner); the driver side is unaffected (AI Core is not released yet) |
| 2 | Deploy the platform so `/api/integrations/control4/modules/rpc`, the entitlement refresh with `SBOS_AI_CORE`, configuration delivery and the Intelligence pages are live | **owner action** (deploy) | `POST …/modules/rpc` answers an authenticated Agent (not 404) | redeploy the previous build; installed AI Cores then get `cloud_refused` on every request (visible in `Last Error`), nothing else breaks |
| 3 | Release the **Agent with module contract v2** (protocol 1..2) — before anything that needs it | build: engineer; tag, release, store: **owner action** | a release whose `smartbuildos.c4z` registers modules at protocol 2; paired Agents updated (store or GitHub updater) | the updater never downgrades: reinstall the previous `smartbuildos.c4z` in Composer by hand. v1 modules (Flight Recorder, Usage Analytics, VenueFlow, MQTT Broker) keep working on either Agent; AI Core on a v1 Agent shows `Agent update required` |
| 4 | Release the **Flight Recorder** with the v2 local-history service | same build as 3 | recorder registers with a manifest advertising `events.*` | reinstall the previous recorder by hand; AI Core's diagnostics then say `flight_recorder_has_no_local_history_service`. **Store:** not mapped in `sku_for()` and not in the Agent's `DRIVER_FILENAMES` — store delivery needs a workflow change or a manual upload (**owner decision**) |
| 5 | Release **AI Core** | same build as 3 and 4 | `smartbuildos-ai-core.c4z` attached to the release; first installs are added in Composer by the integrator (`INSTALLATION.md`) | remove the driver from the project (its persisted state goes with it) or reinstall an older `.c4z` by hand; nothing else depends on it |
| 6 | Store catalogue entry for `SBOS_AI_CORE` (`release_channel` BETA in the draft row; price, tier and category are open owner decisions) and the upload of `smartbuildos-ai-core.c4z` | **owner action** (secrets, publication) | the store lists AI Core at the build's version | delete or supersede the package in the store; installed drivers keep running |

Recommended shape: steps 3–5 are **one build** (one version stamp, one
release) published first as a **pre-release** (store `BETA`), bench-validated
(§5), then promoted.

## 4. Pre-release checklist

- [ ] `make test` green (count recorded), `make lint` 0 warnings / 0 errors.
- [ ] `SBOS_PLATFORM_REPO=<platform checkout at the commit being deployed> make test`:
      the parity test runs (not skipped) and passes; its NOTE lines reviewed
      (today: `raise_event` with `correlation_id` from the actions service is
      refused by the driver — must be resolved before step 2 ships approvals).
- [ ] Both emulator scenarios green (`test/emulator/run-ai-core.sh`,
      `test/emulator/run-module-contract-v2.sh`).
- [ ] `make build` on a clean checkout; the formatter's changes committed;
      `git status` clean afterwards.
- [ ] `AICORE_C4Z=dist/oss/smartbuildos-ai-core.c4z` → `test/test_aicore_package.lua`
      passes against the built file.
- [ ] Agent, Flight Recorder and AI Core `.c4z` carry the same `<version>`.
- [ ] The release tag is that version (and parses: `vendor/version.lua`).
- [ ] `CHANGELOG.md` `## Unreleased` turned into the release's section.
- [ ] Platform steps 1–2 done and verified by the owner.
- [ ] The hardware procedures in §5 passed on a bench and recorded.

## 5. Bench validation before a public release

Everything above is simulation. Before a `STABLE` (non-pre-release)
publication, the hardware validation plan in
[`TEST-MATRIX.md`](TEST-MATRIX.md#hardware-validation-plan) must be run on a
physical controller — at minimum procedures 1 (load on 3.3.2 and 4.x), 2
(Agent paired while running), 3 (registration at protocol 2), 8 (Flight
Recorder frames under load), 10–11 (reboot and power cut), 12 (Agent
update), 15–16 (the platform route and events to programming), 17 (licence
on real HMAC), 18 (store update) and 20 (no token in Trace output) — with the
OS version, controller model and the three driver versions recorded.
Until then the manual's *What is not claimed* stays as written.
