# Driver batch: bench pass of 10 November 2026

Bench project, OS 4.3, Composer Pro 2026.10.14. Every driver of the 9 November
batch, plus the Agent and the Flight Recorder, was updated in place and read
back after each build (`070950`, `215903`, `221650`). The bench ends with the
Agent on `215903` and the other ten on `221650`. This is the record of what
the bench showed and what was changed because of it. The suite stands at 89
files, all passing.

## What was exercised

For each driver: every status property read after the update, its Print and
Refresh actions run with the output read in the Lua tab, and one command run
from a throwaway programming line with **Execute**.

| Driver | Status after `221650` | Actions run | Command run |
|---|---|---|---|
| Agent | Connected; hands tier and company to every driver | Refresh Entitlements Now | – |
| Event Tracer | capturing, Agent registered | Print Capture Status, Print Coverage, Print Recent Events | `MARK_TIMELINE` → Last Event `MARK bench` |
| Flight Recorder | idle, Agent registered | – | – |
| Guest Mode | vacant, no calendars | Print Guest Status, Print Stays, Poll Calendars Now | `CHECK_IN_NOW` → occupied, open-ended (manual) |
| Notification Router | ready, Telegram target ready, **Inbound: `Telegram: listening`** | – (no send: the target is a real chat) | – |
| Logic Pack | active | Print State | `INCREMENT_COUNTER` with no key → refused, `Last Refusal: empty key` |
| Solar Position | tracking, location from the project | Recompute Now, Print Solar Status | `RECOMPUTE_SUN` |
| Usage Analytics | measuring, 4 rooms, 2 lights | Print Sources, Print Usage Report, Send Summary Now | `SEND_USAGE_SUMMARY` → Last Upload moved |
| Dealer Settings | read-only (no Dealer PIN), relay listening | Print Settings | – (the drag did not take) |
| Variable Inspector | writable with Dealer PIN, relay listening | Print Watch List, Print Variables For Inspect Device | – |
| Home Guide | serving, relay listening | Refresh Manual, Print Manual Outline | `REBUILD_MANUAL` |

Two-way messaging: the router was updated to the two-way build, **Telegram
Inbound** set to On, and **Inbound Status** read `Telegram: listening`, so
`getUpdates` is answered with the bench bot's token. No message was sent to
the bot, so receiving, keywords and Reply are still unconfirmed on a
controller.

## Defects found on the bench, and fixed

1. **A saved string was lost at the next restart (every driver).**
   `lib.persist` reads a stored value back through Base64 + JSON so a table
   can be rebuilt. A stored *string* took the same path, and one the
   controller's decoder turns into nothing came back empty. Seen as the
   Agent's company name: painted after a licence refresh, replaced by
   *Registered (name syncing)* after every driver update, and `-` in every
   dependent driver. A stored string that is not an encoded table is now
   returned as stored. Confirmed: the Agent, updated to the fixed build and
   not refreshed, handed the company name to every dependent driver.
2. **License Status stuck on "Checking..." after an update.** With the
   Agent already running, every driver updated after it stayed on
   *SmartBuildOS Agent Found - Checking...* (nine minutes and counting); one
   press of *Register With Agent Now* painted it. The ask sent during start
   got no answer and nothing asked again. `sbos.license` now repeats an
   unanswered ask after 5, 15, 30, 60 s and then every five minutes.
   Confirmed: after the fix all ten painted *Licensed / Subscribed* by
   themselves after the update.
3. **The Agent's first real reload would have stopped it starting.** A start
   was called "first" whenever the reload count was 0; an update never adds
   to the count; so an Agent that had only been updated never reached
   "reload" (bench: *Last Reload … (first)*). The reload branch reported to
   the platform through two locals declared further down the file, which is
   a call to a nil global. Found by fixing the label and letting the test
   reach the branch. Not yet seen on the bench: it needs a controller
   restart.
4. **The probe starved known events (Event Tracer).** Budget spent in
   device-id order: `1000 subscriptions on 35 of 186 devices`. Known events
   are now subscribed first. Confirmed: `1000 subscriptions on 96 of 186
   devices` with the probe still on.
5. **Home Guide listed every device twice** (a driver and its proxy share a
   name): `163 device(s)` in the 9 November record, `89 device(s)` now, one
   line each in the printed outline.
6. **Home Guide: Last Rebuilt moved every minute** (painted with the clock).
   Confirmed: it now holds the time of the rebuild.
7. **Usage Analytics: Last Daily Summary read "none" after every update.**
8. **Event Tracer: a time with no day** for an event from the day before.
9. **The Web View tiles were published at another device's address** (Home
   Guide, Dealer Settings, Variable Inspector). Found from outside: the
   three relays answer `/ping` on the controller's address and the status
   property named a different one, which belongs to another Control4 device.
   `src/lib/relayhost.lua` now publishes only an address the relay itself
   has answered on. Imported that evening as `235241` and confirmed: the
   three status lines name the controller.

## Seen, not changed

- `/app` on all three relays answers `503 app not loadable`: the driver
  cannot read `www/app/index.html` from its own c4z folder on this
  controller, so the tile uses the `controller://` page with the relay in
  the query, which is the designed fallback. The same-origin path has
  therefore not been seen working here.
- Probe Unknown Drivers is still On, which is why the tracer sits on the
  1,000 cap.
- Home Guide groups most of the bench's media-source tiles under *Other
  equipment*; the rule table knows them by driver file, and these all share
  one.
- Atmosphere and UniFi Protect still look the controller's address up the
  old way (defect 9).

## Left on the bench

The Windows VM that runs Composer stopped updating at 17:33 while a property
page was opening; the controller kept answering on the network. It was back
by 18:55 and the leftovers were cleared the same evening:

- the six throwaway programming lines on Home Guide → *Guide Restored* were
  deleted (Delete All, confirmed empty);
- Guest Mode's manual check-in was cleared (*Clear Manual Override*, back to
  `vacant`);
- the relay address fix was imported (build `235241` on the Notification
  Router, Dealer Settings, Variable Inspector and Home Guide): all three
  tiles now read `Listening … serving http://<controller>:<port>`, the
  controller's own address.

Still as it was: **Telegram Inbound is On** on the router, and *Probe Unknown
Drivers* is On on the tracer. The other six drivers and the Flight Recorder
run `221650`; the Agent runs `215903`.

## Evening: Notification Router, and manuals

- **Message pieces** (MESSAGE, VARIABLE 1, MESSAGE 2 …): the Notify command
  shows the twelve parameters in reading order, the picker fills VARIABLE 1,
  and a line built that way ran from the script. The text that went out is
  not shown by any property (Last Notification holds the title), so the
  joined text is confirmed by the suite, not on the bench.
- **`MESSAGE_RECEIVED`** appears under the router in both programming trees,
  offers *When MESSAGE_RECEIVED changes*, a *Set to Value* command and an
  *Is =* conditional. No message was sent to the bot, so the variable
  changing on a real message is unconfirmed.
- **Find Telegram Chat ID** is on the Actions tab of build `235241`; it was
  not pressed (a neighbouring action was). The later build, which also sees
  channels and groups the bot was added to, is not imported.
- **Manuals**: screenshots for the ten drivers were taken from this pass and
  redacted (company, location, controller address, chat id). The interactive
  page was checked in a browser at Composer's pane width; it has not been
  opened in Composer's own documentation viewer.
