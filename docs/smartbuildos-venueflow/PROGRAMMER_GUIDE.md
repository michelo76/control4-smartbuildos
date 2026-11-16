# VenueFlow programmer guide

For the dealer programming a venue in Composer, and for a developer changing
the driver.

## Part 1. Programming with VenueFlow in Composer

VenueFlow does its own programming in Installer Studio (scenes, rules,
schedules). Composer programming is for joining it to the rest of the
project: a keypad button that runs a scene, a fire panel that turns
everything off, a push notification when a display does not confirm.

### Commands (Programming, Actions, the VenueFlow driver, Device Specific Command)

| Command | Parameters | What it does |
| --- | --- | --- |
| Activate the VenueFlow scene | SCENE: the scene's name or id | Runs the scene. Its own condition still applies |
| Trigger the VenueFlow event | NAME: an event name | Runs every enabled rule whose trigger is "A Control4 event" or "An external event" with that name (case does not matter) |
| Route the source | SOURCE: a source's name or id; TARGET: a display's name, a display group's name, or `All` | Routes video, with the same checks and feedback as the screens |
| Mark the venue | STATUS: Open or Closed | Sets the venue status (rules that wait for it run) |
| Turn off every VenueFlow display and audio zone | none | All Off, without the confirmation a screen asks for |

Commands from Composer run with full access: whoever programs the controller
already controls it. A command that is refused (an unknown scene, a scene
whose condition is not met, a restricted licence) writes the reason to the
**Last Error** property and the Lua tab; it never fails silently.

### Events (Programming, the VenueFlow driver's events)

| Event | Fires when | Read |
| --- | --- | --- |
| Scene Activated | a scene starts, from anywhere | variable ACTIVE_SCENE |
| Notification | a scene or rule runs a "Send notification" step | variable NOTIFICATION_TEXT |
| Alert Raised | VenueFlow raises an alert that stays until dismissed (a notification, an interrupted scene, a missed schedule) | variable ALERT_COUNT |
| Configuration Published | the installer publishes or rolls back | |
| Venue Opened, Venue Closed | the venue status changes | variable VENUE_STATUS |
| Licence Restricted, Licence Restored | the SmartBuildOS licence starts or stops restricting scenes and publishing | |

Typical wiring: on **Notification**, send NOTIFICATION_TEXT through the
project's notification driver. On a fire alarm event, run **Turn off every
VenueFlow display and audio zone**.

### Variables and conditionals

Variables (read-only): `VENUE_STATUS` (open, closed), `ACTIVE_SCENE`,
`NOTIFICATION_TEXT`, `ALERT_COUNT`.

Conditionals: *Venue is open*; *Active scene* = or != a scene name;
*VenueFlow has alerts*.

### Sending Control4 events into VenueFlow rules

A rule in Installer Studio can wait for "A Control4 event" with a name, for
example `Doorbell`. In Composer, on the doorbell's own event, add the command
**Trigger the VenueFlow event** with NAME `Doorbell`. That is the supported
way for any Control4 event, variable change or schedule to start a VenueFlow
rule. A rule can also watch a Control4 variable directly (device id and
variable name) or a display or zone state.

There is no HTTP endpoint that triggers anything: an event from outside
Control4 must arrive through a Control4 driver and Composer programming.

## Part 2. How a venue's own programming works

See DATA_MODEL.md for every field. In short:

- A **scene** is a named program a person runs (a button), optionally with a
  condition and a "confirm first" flag.
- A **rule** is a trigger, an optional condition, and a program.
- A **program** is an ordered list of steps from a fixed vocabulary (power
  displays, route video, route audio, volume, mute, zone off, lighting preset,
  shade, wait, run scene, set variable, mark venue, notify, IF/ELSE).
- Nothing an installer types is executed as code. An unknown step or
  condition is refused at validation and skipped by the runner.

Guarantees worth knowing when you design scenes:

| Behaviour | Detail |
| --- | --- |
| Order | Steps run in order. Device commands leave about 120 ms apart |
| Confirmation | A step is "ok" only when its devices confirmed (or cannot give feedback). One display that does not confirm makes the step and the run "partial", and names the display |
| Waits | 1 to 600 seconds. A wait holds one timer, not a busy loop |
| Nesting | IF inside IF four deep; a scene may run another scene four deep; a scene that would run itself is refused at publish and stopped at run time |
| Overlap | A run that changes a device another running program also changes stops that older run, logs it and raises an alert. A rule started by a scene's own step does not stop that scene |
| Conditions | A fact that cannot be read is false |
| Dry run | Validates and plans against the published configuration; sends nothing |
| Schedules | Controller local time; once per day and time; see the Scheduling section in the Studio for the daylight-saving rules |

## Part 3. Changing the driver

### Layout

| Path | What |
| --- | --- |
| `drivers/smartbuildos-venueflow/driver.lua`, `driver.xml` | the Control4 edge: lifecycle, socket, properties, Composer surface, licensing |
| `src/venueflow/*.lua` | every rule, pure Lua with injected dependencies (ARCHITECTURE.md has the map) |
| `src/venueflow/adapter_c4.lua` | the only module that commands or reads Control4 devices |
| `ui/venueflow/` | page sources (see its README) |
| `test/test_venueflow_*.lua`, `test/venueflow_harness.lua` | suites and their harness |
| `tools/venueflow-ui.py`, `venueflow-dev.py`, `venueflow-devhost.lua` | page assembly and the development host |
| `docs/smartbuildos-venueflow/` | this documentation |

### Commands

```bash
make venueflow-test
```

Runs the VenueFlow suites (simulator and shim).

```bash
make test
```

Runs the whole repository's suites, including the guards every driver must
pass.

```bash
make venueflow-dev
```

Serves both pages on the simulator at `http://localhost:47861`.

```bash
make venueflow-ui
```

Reassembles the pages from `ui/venueflow` and re-embeds them in the driver.
Run it after any page change: the test suite refuses a stale page.

```bash
make venueflow
```

Builds only `dist/oss/smartbuildos-venueflow.c4z`. It does not copy anything
into Composer's driver folder. (`make build` builds every driver and does
copy them there: do not run it casually.)

### Adding a command to the protocol

1. `src/venueflow/protocol.lua`: add it to `COMMANDS` with its scope and
   fields. Unknown fields are refused, so name every one.
2. `src/venueflow/core.lua`: add the handler `H.NAME(core, payload, ctx,
   request)`. It returns `{ ok, status, data?, results?, errorCode? }`. Use
   `ctx.access` for every permission question; never read identity from the
   payload.
3. `docs/smartbuildos-venueflow/PROTOCOL.md`: document it.
4. A test. `test_venueflow_relay.lua` already checks that every command has a
   handler and is closed to an unauthenticated caller.

### Adding a step or a condition

`src/venueflow/rules.lua`: add the type to `STEP_TYPES` (or `CONDITION_OPS`),
its validation in `validateSteps` (or `validateCondition`), its wording in
`describeStep`, its execution in `_runStep` through an `ops` function, and
that function in `core.lua` `_ops()`. The op must honour `opts.dry` by
planning without touching the adapter. Then the editor in
`ui/venueflow/studio/sec-programming.js`, and a test with a dry-run check.

### Changing how Control4 is commanded

Only `src/venueflow/adapter_c4.lua`. Keep `sim.lua` offering the same
functions, so everything above stays testable. If a room command name proves
different on hardware (see SDK_RESEARCH.md section 4), this is the one place
to change, and HARDWARE_VALIDATION.md is where to record it.

### Changing the configuration schema

Bump `Schema.SCHEMA_VERSION`, add `Schema.MIGRATIONS[oldVersion]` (a function
that returns the document in the new shape), update `normalize`, `validate`
and DATA_MODEL.md, and add a migration test. A stored configuration is
migrated on load; a backup from an older version restores; one from a newer
version is refused.

### Rules of the house that apply here

- Every `require` at module scope in `driver.lua`.
- No function, userdata or sparse array in anything persisted.
- A secret never reaches a log: put the property or command on
  `OPC.suppressDebug` / `EC.suppressDebug`, and name the field so
  `diag.redact` hides it.
- The repository is public: no site name, address, coordinate or customer in
  code, tests or documentation.
