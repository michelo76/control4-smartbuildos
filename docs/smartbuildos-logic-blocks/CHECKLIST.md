# Logic Blocks — implementation checklist

Branch `feat/logic-blocks`, worktree `control4-smartbuildos-logic-blocks`, cut
from `origin/main` (`4a9bca4`). Nothing here is pushed, published or installed.

Decisions taken before building (evidence in `DESIGN.md`):

- Evolve `smartbuildos-logic-pack.c4z` / `SBOS_LOGIC_PACK`; every legacy
  command, event, variable, conditional and the `lp_state_v1` document stay.
- Blocks run on a second, private instance of `src/logic/engine.lua`, so a
  block can never collide with or adopt a legacy free-form key.
- 16 slots, stable per-slot ids generated into `driver.xml`
  (`tools/logic-blocks-xml.lua`), capacity is one constant.
- Block pickers in commands are a static `LIST` (`Block 01`…`Block 16`):
  the only picker type already proven in this repo for command parameters.
- One dealer interface: the page shipped in the c4z, served by the driver's
  LAN relay (the Atmosphere transport). No Navigator tile, so nothing is
  homeowner-readable. No platform change in this release: the platform has no
  company-scoped reader for `driver_state_mirror` today.
- Composer is the only configuration authority. The page never writes
  configuration; its only writes are to the in-memory sandbox.

Build order:

- [x] Additive engine changes (per-call window cap, debounce cancel, forgets)
- [x] `logic/blockdefs.lua` — types, settings schema, validation, wording
- [x] `logic/blocks.lua` — slots, identities, runtime, sources, history,
      loop isolation, persistence v1 + migration, recovery report
- [x] `logic/blockdraft.lua` — draft, validate, atomic apply, templates,
      explicit legacy adoption
- [x] `logic/sandbox.lua` — isolated simulation runtime
- [x] `logic/appstate.lua` — read-only app document, redacted export
- [x] `logic/relay.lua` — LAN routes (read + sandbox only)
- [x] `driver.xml` surface + generator; `driver.lua` adapter
- [x] `www/app/index.html` — seven dealer screens
- [x] Tests: engine, compatibility, driver, relay, sandbox isolation, page
- [x] Scoped build target, dealer guide, design doc, bench checklist

Result: see `DESIGN.md` (what was built and why), `BENCH.md` (what a controller
still has to prove) and `REGISTRY.md` (what was found and left unapplied).
