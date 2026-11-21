# Logic Blocks — SKU and registry

Nothing in this file has been applied. It records what was found and holds the
change ready, because applying it changes what ships to customer controllers.

## What exists today (read at `origin/main`)

| Registry                                                        | `SBOS_LOGIC_PACK` / `smartbuildos-logic-pack.c4z`                                              |
| --------------------------------------------------------------- | ---------------------------------------------------------------------------------------------- |
| Platform `driver_catalog` (`20261109120000_dealer_tooling_drivers.sql`) | **Present.** `SmartBuildOS Logic Pack`, category Utility, channel `BETA`, tier Professional, included with subscription, OS 3.3.2 |
| Platform `src/lib/control4/dealer-tooling/catalog.ts`           | **Present.**                                                                                   |
| `.github/workflows/publish-to-store.yml` `sku_for()`            | **Absent.** A release prints `skip smartbuildos-logic-pack.c4z (no catalog SKU)`               |
| Agent `DRIVER_FILENAMES` (`drivers/smartbuildos/driver.lua`)    | **Absent.** The Agent never updates this driver                                                |
| Agent `SKU_FILENAMES`                                           | **Absent, and not needed.** It delivers remote settings; this release takes none               |

The same two are absent for all eight drivers of the 9 November batch, so this
looks like a decision (or an omission) about the batch, not about this driver.

## Not changed, deliberately

- **SKU, file name, driver name, model:** unchanged. Licences, the catalogue
  row and any installed copy keep matching.
- **Catalogue text.** The row's description still describes the classic
  primitives. "Logic Blocks" is used in the driver's documentation and the app
  only. Changing store metadata is the owner's call and a platform migration;
  none was written.
- **The two absent registry entries.** Adding them means the next published
  release uploads the Logic Pack to the store and every Agent that has it
  installed updates it in place. That should follow the bench session in
  `BENCH.md`, section 2 in particular (update in place), not precede it.

## The change, ready to apply

`registry.patch` in this folder adds one line to each:

```sh
git apply --check docs/smartbuildos-logic-blocks/registry.patch   # verified clean on this branch
git apply docs/smartbuildos-logic-blocks/registry.patch
```

After applying, `test/test_aicore_surface.lua` and `test/test_aicore_updates.lua`
read the Agent's `DRIVER_FILENAMES`; run `make test`.

## If the catalogue text is to change later

A platform migration updating `driver_catalog.description` and the matching
entry in `dealer-tooling/catalog.ts` (the `dealer-tooling-contract` test keeps
the two identical). Suggested wording: "Named automation blocks and programming
primitives for Composer: cooldowns, quiet periods, restartable timers, once per
day, flags, counters, conditions, thresholds with a deadband, stable-state
filters and state selectors. Persisted across restarts."
