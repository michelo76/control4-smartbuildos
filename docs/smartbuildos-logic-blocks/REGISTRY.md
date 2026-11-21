# Logic Blocks — SKU and registry

The two registry entries below were added on this branch on 21 Nov 2026, on the
owner's instruction. Nothing has been pushed or published. Read "What merging
this now does" before the branch is merged.

## What existed before (read at `origin/main`)

| Registry                                                        | `SBOS_LOGIC_PACK` / `smartbuildos-logic-pack.c4z`                                              |
| --------------------------------------------------------------- | ---------------------------------------------------------------------------------------------- |
| Platform `driver_catalog` (`20261109120000_dealer_tooling_drivers.sql`) | **Present.** `SmartBuildOS Logic Pack`, category Utility, channel `BETA`, tier Professional, included with subscription, OS 3.3.2 |
| Platform `src/lib/control4/dealer-tooling/catalog.ts`           | **Present.**                                                                                   |
| `.github/workflows/publish-to-store.yml` `sku_for()`            | Was absent (a release printed `skip … (no catalog SKU)`). **Added on this branch.**            |
| Agent `DRIVER_FILENAMES` (`drivers/smartbuildos/driver.lua`)    | Was absent (the Agent never updated this driver). **Added on this branch.**                    |
| Agent `SKU_FILENAMES`                                           | **Absent, and not needed.** It delivers remote settings; this release takes none               |

The same two are still absent for the rest of the 9 November batch; only the
Logic Pack was added.

## Not changed, deliberately

- **SKU, file name, driver name, model:** unchanged. Licences, the catalogue
  row and any installed copy keep matching.
- **Catalogue text.** The row's description still describes the classic
  primitives. "Logic Blocks" is used in the driver's documentation and the app
  only. Changing store metadata is the owner's call and a platform migration;
  none was written.

## What merging this now does

Once this branch is on `main` and a release is published:

- the release workflow uploads `smartbuildos-logic-pack.c4z` to the store under
  `SBOS_LOGIC_PACK` instead of skipping it;
- every Agent built from that release checks for and installs Logic Pack
  updates, so an installed Logic Pack is updated in place to the Logic Blocks
  build.

Update in place is exactly what `BENCH.md` section 2 has not yet proven on a
controller (whether the new events, variables and conditionals appear on an
existing installation). Do that check before the first release that contains
this branch.

## What was changed

- `.github/workflows/publish-to-store.yml`: one `sku_for()` case mapping
  `smartbuildos-logic-pack.c4z` to `SBOS_LOGIC_PACK`.
- `drivers/smartbuildos/driver.lua`: `smartbuildos-logic-pack.c4z` added to
  `DRIVER_FILENAMES`.
- `test/test_sbos_updater.lua`: the Logic Pack removed from `KNOWN_UNLISTED`
  (that suite fails when a listed driver is still named there).

`make test` passes with these in place (201 test files). To undo, revert the
commit that made them.

## If the catalogue text is to change later

A platform migration updating `driver_catalog.description` and the matching
entry in `dealer-tooling/catalog.ts` (the `dealer-tooling-contract` test keeps
the two identical). Suggested wording: "Named automation blocks and programming
primitives for Composer: cooldowns, quiet periods, restartable timers, once per
day, flags, counters, conditions, thresholds with a deadband, stable-state
filters and state selectors. Persisted across restarts."
