# Logic Blocks — bench checklist

Nothing in this file has been done. Every item below is unproven on hardware.

Do not load this build on a customer system. Use a bench controller that has
been confirmed to be the bench, and get explicit go-ahead for the session before
any step that operates equipment. Install from `dist/oss/` by hand; `make
logic-blocks` does not copy it to Composer's driver folder.

For every check write down: controller model and OS, Composer Pro version, the
**Driver Version** shown, what you saw, and a screenshot where a picker or a
property sheet is the evidence. "Pass" without what was seen does not count.

Notation: `[ ]` a check; **Expect** what the code and tests predict; **If not**
what it means.

## 0. Before anything else

- [ ] Confirm the controller is the bench (name, address, project).
- [ ] Note the installed Logic Pack version and export the project.
- [ ] `shasum -a 256 dist/oss/smartbuildos-logic-pack.c4z` matches the hash in
      the handoff.

## 1. Fresh install

- [ ] Add the driver to a project that has never had it. **Expect** **Driver
      Status** `Online`, **Driver Version** populated, **Pack Status** `active`,
      **Blocks Status** `0 of 16 slots used…`, **Blocks** `none`.
- [ ] Property sheet: with no draft, the type-specific **Draft …** properties
      are hidden. **If not** `C4:SetPropertyAttribs` does not hide on this
      Composer; the sheet is long but still correct.
- [ ] **Dealer App** shows an `http://<controller>:47871/app?k=…` address, or
      says exactly why not. **App Data Relay** reads `Listening :47871 …`.
- [ ] Lua tab: no error at load. Run *Print Blocks*.

## 2. Update in place (the important one)

On a project that already runs the released Logic Pack with programming on its
classic events, counters in slots and a running `START_TIMER`:

- [ ] Note the classic programming and variable values. Update the driver with
      Driver → Add or Update Driver.
- [ ] Every classic programming line still shows its event and command names,
      not a blank or a red entry.
- [ ] Classic values survived: counters, flags, the state, `COUNTER_1…8`.
- [ ] A classic timer that was overdue fired once at start-up with
      `LAST_TIMER_LATE` `True`.
- [ ] The new events exist in Programming: `Block 01 Passed` … `Block 16
      Faulted`. **If not** `C4:AddEvent` at start-up did not add them on an
      update; a remove-and-re-add would be required, which is a release
      blocker.
- [ ] The new variables exist (`BLOCK_01_ACTIVE` …) and the new conditionals
      (*Block 01 is active* …). **If not** note which kind is missing; XML
      conditionals have no start-up registration in this driver.
- [ ] The new commands (`BLOCK_TRIGGER` …) appear with a `Block 01`…`Block 16`
      list.

## 3. Pickers at 16 slots

- [ ] Programming → Events for this driver: 139 entries. Is the list usable?
      Screenshot. How long does the picker take to open?
- [ ] Conditionals: 61 entries. Usable?
- [ ] Variables under this device: 83. Usable?
- [ ] Driver load time and Director CPU at add and at update, compared with the
      released driver. **If** any of these is unacceptable, set `Defs.SLOTS` to
      8, run `make logic-blocks-gen`, rebuild, repeat. Ids do not move.
- [ ] *Block 03 is active* (BOOL): pick `active`, then `not active`. Does the
      line do the right thing for both? **If not** the driver must read the
      conditional's parameters; record what `TestCondition` receives (Log Level
      `5 - Trace`).
- [ ] *Block 03 value* shows the six comparison operators and takes an integer.
- [ ] *Block 03 state* takes text with `=` and `!=`.
- [ ] `BLOCK_03_ACTIVE` shows as true/false in Composer's variable view when
      the driver writes `1`/`0`. **If not** it must write `true`/`false`.

## 4. Draft workflow

- [ ] *New Draft* with a name and type: **Draft** line changes, only that
      type's Draft properties are shown, stale text is cleared.
- [ ] Type a bad duration → *Validate Draft* names it. *Apply Draft* refuses.
      **Blocks** unchanged.
- [ ] Fix it → *Validate Draft* `Valid`, **Draft Impact** `Creates Block 01…`.
      *Apply Draft* → **Blocks** lists it, *Blocks Configuration Applied* fires.
- [ ] **Selected Block** list shows `01 · <name>`. Does a `DYNAMIC_LIST` value
      set by the driver stay selected after a Composer refresh?
- [ ] **Draft Input 1 Device** lists the project's devices; picking one fills
      **Draft Input 1 Variable**. With a large project, is the device list
      usable and how long does it take? (It is capped at 500 entries.)
- [ ] Restart the driver with a draft open: the draft is still there and still
      not applied.

## 5. Recipes on real triggers

Use a bench light or a relay with an indicator as the "equipment".

- [ ] **Driveway cooldown.** Motion → `BLOCK_TRIGGER (Block 01)`; *Block 01
      Passed* → scene. Trigger three times in a minute. **Expect** the scene
      runs once; `BLOCK_01_VALUE` reads 2; the app explains each suppression and
      when it is eligible. Wait out the cooldown: nothing runs by itself; the
      next trigger runs it.
- [ ] **Bathroom vacancy.** Motion → `BLOCK_START`; *Expired* → off. Walk in
      and out repeatedly. **Expect** *Started* once, *Expired* once, measured
      from the last motion. Then `BLOCK_CANCEL` mid-countdown → *Cancelled*,
      never *Expired*.
- [ ] **Guest override.** Toggle on, restart the controller. **Expect** still
      on, and no *Became True* at start-up.
- [ ] **Daily gate.** Trigger before midnight (passes), again (suppressed),
      leave it over midnight, trigger after 00:00 (passes). Note the
      controller's time zone and the day shown in Diagnostics.
- [ ] **Threshold.** Map a real temperature (or a Number variable in the
      Variables agent). Cross above the upper limit → *Became True* once. Move
      inside the band → nothing. Cross below the lower limit → *Became False*.
      Sit exactly on a limit → nothing.
- [ ] **Unavailable source.** Delete the mapped variable or remove the device.
      **Expect** within a minute: *Faulted* once, `VALID` false, `STATE`
      `unknown`, listed under missing mappings, never *Became False*. Put it
      back: valid again within a minute, nothing fires.
- [ ] **Opening value.** Add a block mapped to a variable that is already above
      the limit. **Expect** it shows active and no event fires. This confirms
      Director sends the value when the listener is set.

## 6. Ordering and loops

- [ ] **Back-to-back.** Two programming lines increment two different counter
      blocks in the same script; each block's event sets a different light.
      **Expect** both lights correct, each event reading its own
      `BLOCK_nn_VALUE`.
- [ ] **Variables before events.** On *Block 02 Value Changed*, copy
      `BLOCK_02_VALUE` to a Number variable. Increment three times quickly.
      **Expect** 1, 2, 3 seen in order, never a stale value.
- [ ] **Reentrant.** On *Block 02 Value Changed*, send `BLOCK_SET` to another
      block. **Expect** it is handled after the first, both fire.
- [ ] **Loop.** On *Block 02 Value Changed*, send `BLOCK_INCREMENT (Block 02)`.
      **Expect** Director stays responsive; the block is isolated, *Faulted*
      fires once, **Selected Block Status** says why; other blocks work;
      *Resume Selected Block* restores it. Record how many increments happened
      and how long Director was busy. **If** Director stalls, the limits in
      `blocks.lua` are too high for a real controller.

## 7. Disable, retire, rename

- [ ] Start a timer, *Disable Selected Block*. **Expect** no *Expired* and no
      *Cancelled*, ever.
- [ ] Rename a block that programming uses. **Expect** programming unchanged
      and still working; **Blocks** shows the new name on the same slot.
- [ ] Retire a block that programming uses (two presses). **Expect** its
      commands are refused under **Last Refusal** naming the retired block;
      a new block does not land in that slot.
- [ ] Change a running timer's duration. **Expect** **Draft Impact** warned
      that the countdown is cancelled; after *Apply Draft* nothing fires.

## 8. Restart

For each, start the timer, then restart Director (or power-cycle), and note the
down time.

- [ ] `Cancel if missed`, restart shorter than the remaining time → the timer
      carries on and expires at its original deadline.
- [ ] `Cancel if missed`, restart longer than the remaining time → no
      *Expired*; the recovery report in the app says so.
- [ ] `Fire late`, restart longer than the remaining time → *Expired* once at
      start-up.
- [ ] `Resume remaining` → it expires after the time it had left, to within a
      minute.
- [ ] A quiet-period countdown pending at restart → never passes.
- [ ] Pull power (no clean shutdown) with a counter block changed in the last
      two seconds. How much is lost? (State is written two seconds after a
      change.)
- [ ] After each restart: no block event fires merely because listeners were
      registered again.

## 9. Licence

- [ ] Agent present and licensed → **License Status** `Licensed / …`.
- [ ] Agent removed from the project → blocks keep working; **License Status**
      `No SmartBuildOS Agent Found`.
- [ ] Agent paired but the controller's internet unplugged for an hour → blocks
      keep working, timers expire, the app still loads on the LAN.
- [ ] A definitive denial with enforcement on (needs SmartBuildOS to issue it
      for the bench controller) → **Pack Status** read-only; a running timer
      does not expire; block commands refused with `read-only`; conditionals
      still answer. Restore the licence → each held timer follows its After
      Restart rule.

## 10. The dealer app on real networks

- [ ] Open the **Dealer App** address from a laptop on the same LAN. Loads,
      shows the blocks, chip reads `Live`.
- [ ] From a phone on the same Wi-Fi.
- [ ] Largest answer: with all 16 slots used and a full history the app
      document is about 80 KB. Does `C4:ServerSend` deliver it whole? **If
      not** the document must be split or trimmed.
- [ ] **App Relay Address** `auto` picked the right address on a controller
      with more than one interface. If not, set it by hand and confirm.
- [ ] Stop the driver → within 10 seconds the app says `Stale` and since when;
      restart → `Live`.
- [ ] From a different VLAN or off-site → it does not load. That is expected:
      the app is LAN-only.
- [ ] **Dealer App Access** `Off` → the port is closed (confirm with a port
      scan from the laptop).
- [ ] The token: confirm it is not in the Lua log at Log Level `5 - Trace`.
- [ ] Sandbox: open one on a block that programming uses, run triggers and
      advance time. **Expect** no programming runs, no light moves, the live
      block's counts do not change.
- [ ] Navigator: confirm nothing new appears for the homeowner (no tile, no
      device).

## 11. Equipment feedback versus an event

- [ ] Map **Draft Feedback Device/Variable** to the bench light's state with
      **Draft Feedback Expect** `1` (or what the light reports) and `10s`.
- [ ] Trigger with the programming wired → Activity shows `Confirmed by
      feedback`.
- [ ] Remove the programming line and trigger again → the event still fires and
      Activity shows `No feedback arrived`. This is the point of the check: an
      event is not a result.
- [ ] Trigger with the light already on → `Already in that state (not
      attributable)`.

## 12. Cloud Status Mirror (optional, separate session)

- [ ] `On` with a paired Agent → does the Agent provision an upload credential
      for `SBOS_LOGIC_PACK`? Watch the Agent's log.
- [ ] Does a row appear in SmartBuildOS for this controller and SKU?
- [ ] `Off` → nothing further is sent.

## Emulator evidence (separate, already gathered)

The built `.c4z` was loaded in `control4-director-emulator` on 21 Nov 2026
(`luajit bin/director.lua load dist/oss/smartbuildos-logic-pack.c4z`, with
`DIRECTOR_CACHE` pointed at a scratch folder so the emulator checkout was not
written to). Result: `OK`, 16 callbacks defined, 20 distinct API calls, 0
warnings; `AddEvent` ×139, `AddVariable` ×83, `CreateServer` ×1.

That says the package unpacks, its squished Lua loads under LuaJIT, and start-up
uses only API the emulator knows from the public documentation, with nothing
the documented safe-usage table forbids during init. It says nothing about
Composer, a real Director, timing, the network or equipment. No block scenario
was scripted in the emulator; block behaviour is covered by the shim suites.
