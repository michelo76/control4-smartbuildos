# VenueFlow architecture

VenueFlow is one Control4 DriverWorks driver (`smartbuildos-venueflow.c4z`).
It adds no service, no server and no cloud dependency to a project: the
driver holds the configuration, serves both pages, and asks Control4 to do
the work.

```
 Navigator tile (T3/T4, phone, tablet)        Installer's laptop or tablet
        operator page  /app                          Installer Studio  /studio
              |  POST /api (+ tile token)                  |  POST /api (+ session)
              +------------------+  +----------------------+
                                 v  v
                 LAN relay  (C4:CreateServer, port 47861)      relay.lua (pure router)
                                 |
                                 v
        core.lua  handle(request, transport)   <- the only door
          identity (auth.lua)  ->  permission (access.lua)  ->  handler
                                 |
     +-----------+-----------+---+--------+-------------+-----------+
     v           v           v            v             v           v
 routing.lua  audio.lua   rules.lua   scheduler.lua  store.lua   diag.lua
 (video,      (zones,     (scenes,    (schedules)    (draft,     (bounded
  power)      lighting,    rules,                    published,   log)
              shades)      dry run)                  versions)
     |           |           |
     +-----+-----+           |  (a program runs through the same engines)
           v                 |
      tracker.lua  <---------+     one operation per request, one outcome per device
      queue.lua                    commands leave one at a time, newest wins
      state.lua                    one cell per fact: confirmed / pending / commanded / unknown / failed
           |
           v
   adapter  ---- Live: adapter_c4.lua  -> C4:SendToDevice, room variables, listeners
            \--- Simulation: sim.lua   -> rooms and devices in memory, fault injection
```

## House conventions reused

VenueFlow is built the way this repository's other WebView drivers are
(Daypart Scheduler, PIN Lock, Commissioning Matrix), so nothing about its
Control4 surface is new:

| Convention | Where it comes from |
| --- | --- |
| UI Button proxy (binding 5001) with `web_view_url` and `mobile_web_view_enabled` | every WebView driver here |
| A LAN relay opened with `C4:CreateServer`, the page loaded from it, a minted token in the web view URL | Daypart (bench, 13 Nov 2026) |
| The controller's own address found by asking candidates `GET /ping` | `src/lib/relayhost.lua` |
| Pages compiled into the driver as Lua modules | `tools/embed-pages.lua` (OS 4.3 refuses a driver its own c4z files) |
| Licensing through the SmartBuildOS Agent | `src/sbos/license.lua` |
| Markers in the project's common history | Flight Recorder `RECORD_EVENT` |
| Named timers, handler tables, logging, persistence | `drivers-common-public`, `src/lib` |
| Pure modules under `src/<driver>`, tested with `test/c4_shim.lua` | whole repository |
| Every `require` at module scope (the build discovers modules by loading `driver.lua`) | `test_driver_require_guard.lua` |

What is new is everything above the adapter, and it is pure Lua with injected
dependencies, so it runs unchanged in the driver, under test and in the
development host.

## Installer Studio hosting

The brief asked for the smallest reliable supported architecture, without
assuming a controller can run arbitrary background services. Three options:

| Option | Verdict |
| --- | --- |
| 1. A configuration page bundled with the driver, served by the driver's own relay | **Chosen.** One mechanism (`C4:CreateServer`), already proven on the bench for three drivers, no extra component to install, works with no internet and no SmartBuildOS subscription. The installer opens `http://<controller>:47861/studio` from any browser on the venue LAN. |
| 2. A separate local service (a small computer or container on site) | Rejected. A second thing to install, power, update and secure, and the driver would then depend on it for configuration. Nothing VenueFlow does needs it. |
| 3. SmartBuildOS Edge or cloud hosting the Studio | Rejected as the primary path: it would make configuration depend on a subscription and a connection. It remains the right place for multi-venue features (see SMARTBUILDOS_INTEGRATION.md). |

Cost of option 1, stated plainly: the Studio is reachable only on the venue
LAN (remote configuration needs the dealer's own VPN or remote access), it is
plain HTTP on that LAN, and the page is a large reply for the driver's socket
(a hardware validation item).

## Trust

- **The only door is `core:handle(request, transport)`.** The relay has five
  routes; one of them (`POST /api`) carries commands, and every command goes
  through `handle`.
- **Identity is something the driver minted.** A session token from a PIN or
  the Installer Passcode, or the tile token the driver wrote into the web
  view URL. A page never states its profile; unknown fields in a request are
  refused by the protocol, so a "role" a page adds is an error, not a claim.
- **Permission is checked where the work happens.** `access.lua` builds an
  Access object from the session's profile; `routing.lua` and `audio.lua`
  ask it per request and per device. A page hides what a profile cannot do
  only to be polite.
- **A profile sees only its part of the venue.** The configuration and state
  sent to a page are filtered (`Access:view`, `core:operatorState`), and carry
  no Control4 id, program or PIN material.
- **Configuration is not a profile permission.** It needs an Installer Studio
  session; no profile, not even "Installer", can read or change the draft.
- **Secrets.** PINs are stored as salted HMACs and are never sent to a
  browser. The Installer Passcode is a hidden driver property, never logged,
  never in a backup. Tokens live in the driver's memory and end with a
  restart, an expiry, an idle period, or a changed PIN or passcode.

## Truth about devices

The brief's hardest requirement is that a failed action must never look
successful. Three mechanisms carry it:

1. **Cells** (`state.lua`). Every fact has a status. `confirmed` is set only
   when Control4 reports the requested value.
2. **Operations** (`tracker.lua`). One request becomes one operation with one
   target per device, and every target ends in exactly one of confirmed,
   commanded (no feedback exists), failed, unknown, superseded. The reply to
   the request says `accepted` or `partial`, never "done".
3. **Programs** (`rules.lua`). A step stays `sent` until its operation
   settles; a run is `ok` only when every step's devices confirmed. The
   "last successful run" is advanced by nothing less.

## Control modes

`Control Mode` is a driver property, and it starts as **Simulation**. In
Simulation the adapter is `sim.lua`: nothing is sent to Control4, the pages
show a "Simulation" strip, and the two reference venues can be loaded. In
**Live** the adapter is `adapter_c4.lua`. Switching mode clears everything
known about device state, and a reference venue (whose Control4 ids are
invented) is refused in Live.

## Licensing

SKU `SBOS_VENUEFLOW`, through the Agent, with the standard four properties.
The driver consults only `license.enforces()`, which is true only for a
definitive denial with server enforcement.

| Always works | Needs a licence |
| --- | --- |
| Every manual command (route, power, volume, mute, lighting, shades, All Off, venue status), reading state, Composer's Route and All Off, editing and backing up the draft, dry runs | Scenes, rules, schedules, publishing, rollback, live program tests |

No licence change sends a command or switches anything off; a run already in
progress finishes. No Agent, an unreachable cloud, an unauthenticated Agent
and the grace period restrict nothing (`test_venueflow_license.lua`).

## Persistence

Through `lib.persist` (the controller's `PersistSetValue`):

| Key | Content |
| --- | --- |
| `vf_draft_v1` | the draft configuration, its revision |
| `vf_published_v1` | the published version |
| `vf_history_v1` | up to five previous versions |
| `vf_images_v1`, `vf_img_<key>` | floor-plan pictures, by content key |
| `vf_runtime_v1` | venue status, internal variables, what each schedule last fired, last runs |
| `vf_relay_token_v1`, `vf_seed_v1` (encrypted) | the tile token and the random seed; both are regenerated if lost |

Device state is not persisted: it is read from Control4 at start.

## Module map

| Module | Role |
| --- | --- |
| `core.lua` | wiring, identity, command handlers, alerts, Composer commands |
| `protocol.lua` | request validation, reply envelope |
| `relay.lua` | HTTP parsing and the five routes |
| `auth.lua` | PIN and passcode checks, lockout, sessions |
| `access.lua` | what a profile may see and do |
| `schema.lua` | the configuration: defaults, validation, migration |
| `templates.lua` | business types, scene and profile templates, the two reference venues |
| `store.lua` | draft, published, history, pictures, backup |
| `state.lua`, `tracker.lua`, `queue.lua` | cells, operations, command serialisation |
| `routing.lua` | video routes and display power |
| `audio.lua` | audio zones, lighting presets, shades |
| `rules.lua` | program validation, conditions, the runner, dry run |
| `scheduler.lua` | schedules |
| `discovery.lua` | device enumeration and classification |
| `diag.lua` | bounded, redacted log |
| `adapter_c4.lua` | the only module that commands or reads Control4 devices |
| `sim.lua` | the simulated project |
| `errors.lua`, `util.lua` | error catalogue, helpers |
| `page_app.lua`, `page_studio.lua` | generated: the two pages |

Pages: `ui/venueflow` (see its README). Tools: `tools/venueflow-ui.py`
(assemble pages), `tools/venueflow-dev.py` and `tools/venueflow-devhost.lua`
(the development host).

## Decisions worth knowing

- **A display is a Control4 room.** Control4 routes video per room; the
  project's AV bindings choose the path through a matrix or an AV-over-IP
  system. VenueFlow therefore selects a source in the display's room and lets
  Control4 route, instead of driving a matrix itself. A display Control4
  cannot route gets a custom command, declared as unverifiable.
- **Polling, not push.** Pages ask for state about every 1.5 seconds and get a
  few hundred bytes back when nothing changed. Push through `C4:SendDataToUI`
  was left out: its delivery is unconfirmed, and polling over the relay is
  enough.
- **Schedules use the controller's clock.** No time-zone database is shipped.
  The venue's zone is the project's zone in Composer.
- **One timer per concern, not per device.** Confirmations are swept by one
  timer; the simulator runs on one timer.
- **Samples are fenced.** Reference venues load only in Simulation and are
  refused in Live.
