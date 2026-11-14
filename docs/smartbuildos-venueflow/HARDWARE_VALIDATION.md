# VenueFlow hardware validation

**Status: started 14 November 2026.** On the bench controller H1 passed, the
laptop part of H2 passed, and H3 passed including a driver restart (see
Results). The bench now runs build `20261114.191046`, which carries the
fixes for the three defects found. Still to do: H2 on Navigators, the H3
network drop and a restart of the controller itself, H4 to H10. Everything
so far was in Simulation: nothing has been sent to real equipment. Until H1
to H9 pass, the build is "simulation verified", not production ready.

## Before you start

- A Control4 controller on a supported OS (3.3.2 or later; the bench is 4.3.0)
  with Composer Pro, a project that has at least: two rooms each with a
  display and a video path from two shared sources (a matrix or AV-over-IP),
  one audio zone room with volume control, a T3 or T4 touch screen, and a
  phone or tablet with the Control4 app.
- The SmartBuildOS Agent in the project (optional for H1 to H9, needed for
  H10).
- **Read Composer's title bar first.** Import a development build only when
  it names the bench system. The controller address alone proves nothing.
- Build: `make venueflow`. Import `dist/oss/smartbuildos-venueflow.c4z` from
  that folder (never from Composer's own driver folder).
- The driver starts in **Simulation**. Do H1 to H3 in Simulation: they send
  nothing to the project. Switch to Live from H4 on, with nobody relying on
  the rooms.
- Keep the driver's Lua tab open with Log Mode "Print" and Log Level
  "3 - Info": every command sent to Control4 is printed as
  `VenueFlow -> <COMMAND> on <device id>`.

Record for each test: date, OS, Composer version, pass or fail, what was
seen. Add the record to this file.

## H1. Driver installation

| Step | Pass when |
| --- | --- |
| Driver, Add or Update Driver, choose the `.c4z` | No error dialog. No "Property Invalid" dialog |
| Items, Search, "VenueFlow"; add it to a room | The driver appears and adds |
| Properties | Driver Status "Online - Simulation"; Driver Version stamped; Control Mode "Simulation"; License Status painted within about 5 minutes |
| Lua tab | No Lua error at start |
| Documentation tab | The manual shows and its contents list works |
| Actions, Print Status | The status prints |

## H2. WebView loading on Navigators

| Step | Pass when |
| --- | --- |
| Properties, App Data Relay | Names the controller's real address, "confirmed" |
| From a laptop on the LAN: `http://<controller>:47861/ping` | `{"ok":true,"service":"venueflow"}` |
| Laptop browser: `http://<controller>:47861/app` | The operator page loads (several hundred kB in one reply): **this is the first test of a large `C4:ServerSend`** |
| T3 or T4: open the VenueFlow tile | The page loads, fills the screen, text is legible, touch works |
| iOS app and Android app: open the tile | Same |
| On each: tap the header four times (Navigator's console), look for errors | None |
| If the tile is blank: set App Relay Address to the controller's address, wait a minute, reopen | Note which was needed |

## H3. Installer Studio, persistence, publish (still in Simulation)

| Step | Pass when |
| --- | --- |
| Set Installer Passcode (6+ characters); read the Installer Studio property | Shows `http://<controller>:47861/studio` |
| Open it on a laptop; sign in | The Studio opens. A wrong passcode is refused; five wrong ones lock for a minute |
| Setup Wizard: load the sample sports bar; publish | Published v1; the operator page shows 24 displays with the Simulation strip |
| Layout Designer: upload a floor plan photo (a real one, a few MB) | It is reduced, stored and shown. **First test of a large value in `PersistSetValue`** |
| Operator page: route, change volume, run Game Day | Tiles go working then confirmed (simulator) |
| Lua tab during all of this | No `VenueFlow -> ...` line: Simulation sends nothing |
| Restart the controller (or the driver: Actions, Reload is NOT a restart; use Composer's driver restart) | After start: the venue, the version, the draft, the floor plan, venue status are back; staff must sign in again |
| Unplug the controller's network for a minute while a page is open | The page says it cannot reach the controller, and recovers by itself |

## H4. Discovery and mapping on the real project (Live)

Build the real venue: Setup Wizard with a template (not the sample), then:

| Step | Pass when |
| --- | --- |
| Set Control Mode to Live | Driver Status "Online" |
| Devices, Discover devices | Rooms, displays, sources and the matrix are listed. Note which categories are right and what `basis` each shows (proxy or driver file name): **this settles the unconfirmed `proxies` field of `C4:GetDevices`** |
| Map two displays to their rooms and devices by hand; map two sources; map one audio zone | Saved; the issues about unmapped devices clear |
| Query Status on a display | Shows the room's power, video device and volume as Composer shows them |

## H5. Persistence at real size

| Step | Pass when |
| --- | --- |
| Build or restore a venue of 20+ displays with a floor plan; edit for ten minutes | Every save returns to "Saved"; no slowdown on the controller; no Lua error |
| Export a backup; restore it into the draft; publish | The restored venue equals the exported one |
| Restart the controller | Everything is back |

## H6. Video routing

For each display (Lua tab open):

| Step | Pass when |
| --- | --- |
| Test Route with a source (confirm the warning) | Lua tab: `VenueFlow -> SELECT_VIDEO_DEVICE on <room id>`. **The display shows the source.** The Studio says "confirmed" |
| Operator page: select two displays, route a source | Both show it; tiles confirmed within a few seconds |
| Route a source one display cannot show (limit its source list first) | That display is reported "cannot be shown here"; the other routes |
| Unplug one display's control; route to both | One confirmed, one "not confirmed" or "offline" after about 8 seconds; never both "done" |
| Change a room's source from a Control4 remote | The tile follows within a second or two |
| Test Power Off, then On | `ROOM_OFF`, then the source reselected; the display follows; state confirmed |
| A display on a custom command route, if any | The command reaches the device; state shows "sent" |
| A video wall destination, if any | Record what works |

If a display does not react to `SELECT_VIDEO_DEVICE`: note the room's video
path in Composer; the command and its parameters are in
`src/venueflow/adapter_c4.lua`.

## H7. Audio

| Step | Pass when |
| --- | --- |
| Zone source | `SELECT_AUDIO_DEVICE` to the zone's room; the sound changes; confirmed |
| Zone volume | `SET_VOLUME_LEVEL`; the level changes; confirmed. A level over the zone's maximum is clamped |
| Zone mute and unmute | **`MUTE_ON` / `MUTE_OFF` are the least certain commands in the driver.** Pass when the room mutes and the state confirms. If nothing happens, record it: the fix is in `adapter_c4.lua` `setMute` |
| Zone off | `ROOM_OFF`; confirmed |
| Independence: route different video to several displays while a zone plays music | The zone keeps playing its own source. If it follows a display, check whether they share a Control4 room (the Studio warns "AUDIO_COUPLED") |
| Route with "listen" on | The named zone, and only it, takes the source's audio |

## H8. The Navigator bridge

Optional: the relay is the transport. This settles two unconfirmed points.

| Step | Pass when |
| --- | --- |
| On a touch screen, temporarily make the relay unreachable for the page (set App Relay Address to an unused address, reopen the tile) | The page falls back to `C4.sendCommand`. Record whether it loads state (the reply arrived through `onDataToUi`) or stays on "cannot reach the controller" (it did not) |
| Restore App Relay Address to Auto | The page works again |

## H9. Scenes, schedules, restart, long run

| Step | Pass when |
| --- | --- |
| Build a scene: power on a group, route two sources, zone source and volume | Each step ends ok; the venue matches |
| Dry Run it first | The plan lists the steps; the Lua tab shows no command |
| A lighting preset (ACTIVATE_SCENE with a real scene id on the Advanced Lighting agent's device id) and a shade, if present | They react |
| Composer programming: add "Activate the VenueFlow scene ..." to a button; press it | The scene runs; the event Scene Activated fires its own programming |
| A schedule a few minutes ahead | It fires at that minute, once |
| Leave a schedule across a real daylight-saving change, when one comes | It fires once at the right local time |
| Restart the controller mid-evening | No room command is sent by the restart; state is re-read; staff sign in again |
| Run through one full service | No Lua error; Diagnostics shows nothing unexplained |

## H10. Licensing with a real Agent

| Step | Pass when |
| --- | --- |
| Agent in the project, linked | License Status shows the company's standing |
| Agent removed or the internet unplugged | VenueFlow keeps working fully |
| A test entitlement set to denied with enforcement (staging only) | Scenes, schedules and publish stop with a clear message; routing, volume and All Off keep working; nothing switches off |

## Blocked today

| Item | Needs |
| --- | --- |
| All of the above | The owner present at the bench, and Composer confirmed on the bench system |
| H6 on a matrix, AV-over-IP, a video wall; H7 on a multi-zone amplifier | That hardware in the bench project |
| H10 denial | The `SBOS_VENUEFLOW` SKU in the platform (SMARTBUILDOS_INTEGRATION.md) |
| H9 daylight-saving | The calendar |

## Results

### 14 November 2026, bench controller, OS 4.3.0, Composer Pro 2026.10.14

Build `20261114.061304` (SHA-256 `f97adb63...db09795e`), imported from
`dist/oss`. Composer's title bar named the bench system before the import.
The driver stayed in Simulation throughout. "Laptop" below is a Mac on the
bench LAN.

**H1. Driver installation: PASS**

| Step | Result | Seen |
| --- | --- | --- |
| Add or Update Driver | Pass | No error dialog, no "Property Invalid" dialog. Composer reloaded the project |
| Search "VenueFlow", add to a room | Pass | Listed as "SmartBuildOS VenueFlow" (SmartBuildOS, others, IP); added on a double-click |
| Properties | Pass | Driver Status "Online - Simulation"; Driver Version `20261114.061304`; Configuration "Not published [SIMULATION]"; Control Mode "Simulation"; License Status "Licensing Not Yet Enforced" painted at once (Agent in the project); Last Error "none" |
| Lua tab | Pass, with a limit | No error printed after the tab was opened; Last Error "none". The tab was not open at the moment the driver started |
| Documentation tab | Pass | The manual renders with its Contents button and search box. The contents list was not clicked through |
| Actions, Print Status | Pass | Eight actions listed. Print Status printed venue status, licence line (`sku=SBOS_VENUEFLOW status=LEGACY enforcement=observe`), relay line, Studio line and the recent diagnostics. Print Operator Page Link printed the tile link |
| Log Level, Log Mode | Pass | Set to "3 - Info" and "Print" with Composer's Set button |

**H2. WebView loading: laptop part PASS, Navigators not run**

| Step | Result | Seen |
| --- | --- | --- |
| App Data Relay property | Pass | "Listening :47861 - serving http://<controller>:47861 to the app", the controller's real address |
| `/ping` from the laptop | Pass | `{"ok":true,"service":"venueflow"}`, 17 ms |
| `/app` from the laptop | Pass | 180,055 bytes in one reply, 36 ms, byte-identical to the built page. **A large `C4:ServerSend` reply arrives whole** |
| `/studio` from the laptop | Pass | 539,849 bytes in one reply, 53 ms, byte-identical to the built page |
| Response headers | Pass | `Content-Length`, `Cache-Control: no-store`, `nosniff`, `Referrer-Policy`, the Content-Security-Policy, CORS headers; `OPTIONS /api` answers 204; an unknown path answers 404 |
| Operator page in a desktop browser (Chromium), through the tile link | Pass | "This venue has not been set up yet" (nothing is published); no console message |
| Studio page in a desktop browser, no passcode set | Pass | Sign-in card with "With no passcode set, Installer Studio stays off"; no console message |
| Requests without an identity (`POST /api`) | Pass | `HELLO` and `PING` answer; `GET_STATE` and `ROUTE_VIDEO` answer `VF_NO_PUBLISHED_CONFIG`; `PUBLISH` and `STUDIO_LOGIN` answer `VF_STUDIO_DISABLED`; an unknown command `VF_UNKNOWN_COMMAND`; a body that is not JSON answers HTTP 400 `VF_BAD_REQUEST`; a picture upload without a session is refused. Each refusal appeared in the driver's diagnostics. Replies took 12 to 20 ms |
| T3 or T4 tile, iOS app, Android app, Navigator console | **Not run** | Needs someone at a touch screen and a phone |

**H3. Installer Studio, persistence, publish: PASS so far; restart and network drop not run**

The owner typed the Installer Passcode in Composer and signed in to the
Studio in a desktop browser (Chromium). Everything stayed in Simulation.

| Step | Result | Seen |
| --- | --- | --- |
| Set Installer Passcode | Pass | `HELLO` reports `studioEnabled: true`; the Studio opened on the Setup Wizard ("This driver has no configuration yet") |
| Wrong passcode | Pass | Refused with `VF_BAD_PIN`. The fifth wrong attempt and the ones after it answer `VF_LOCKED` with `retryIn: 60`. The signed-in Studio session kept working during the lock. The diagnostics log the refusals and none of the attempted values |
| Load the sample sports bar | Pass | Draft saved as revision 1 on the controller; all six wizard steps marked done except Publish |
| Publish | Pass | One warning (custom route command) had to be acknowledged; "Published v1. The venue runs on it now." |
| Operator page through the tile link | Pass | Opens as the default profile (Bartender) with its 8 displays and 1 zone, the Simulation strip on top. The full 24-display manager view was not opened (it needs the sample manager PIN) |
| Route | Pass | Sports 1 to three displays: "3 confirmed"; tiles went On with the source name |
| Scene refused by its condition | Pass | Game Day with the venue closed: "The scene's condition is not met right now." |
| Venue status from another session | Pass | Set to open from the Studio session; the operator page showed "Venue Open" by itself within its polling interval |
| Run Game Day | Pass | "Game Day started", tiles Working then On, scene chip Running then Active, the Bar zone volume confirmed at 65 |
| Volume | Pass | Bar zone to 42: reply "accepted", confirmed about 3 s later |
| Floor picture, 478 kB data URL (1600 x 1000 JPEG) | Pass, with a limit | Stored through `POST /image` in 74 ms; read back byte-identical in 150 ms; attached to the floor, published as v2 (v1 kept in the history); drawn under the operator floor plan. **A large value went into the driver's storage and came back whole.** The picture was generated in the browser: reducing a real multi-megabyte photo through the file chooser was not done on the bench |
| Draft save and publish timing | Pass | Saving the whole sample draft took 109 ms, publishing 112 ms |
| Diagnostics | Pass | 39 entries, no error-level entry |
| Lua tab while routing | Pass | Second session, build `20261114.191046`, Log Level Info, Log Mode Print: a route to two displays and a volume change were confirmed and printed no `VenueFlow -> ...` line. The only lines were three warnings for a route the profile was not allowed to make |
| Restart the driver | Pass | Second session: Driver, Add or Update Driver with build `20261114.191046` reloaded the driver. Before it: v2, draft revision 3, venue open, Game Day. After it: Driver Version `20261114.191046`, Venue "Riverside Sports Bar", Configuration "v2: 24 displays, 8 sources, 4 zones, 5 scenes [SIMULATION]", Draft "revision 3", Venue Status "open", Active Scene "Game Day", Last Error "none", the Installer Passcode kept, the tile link still valid (same token), the floor picture drawn again at the same length (477,727 characters). The Lua tab was open during the reload: two lines, "VenueFlow relay listening on port 47861" and the entitlement line, no error. The simulated displays started Off (see finding 3) |
| Restart the controller itself | **Not run** | A power cycle or reboot of the controller was not done |
| Network unplugged for a minute | **Not run** | Needs someone at the controller |

**Found on the bench**

1. A picture upload refused for want of a session answers with
   `"detail":"installer session required"`. `detail` is meant for installer
   sessions only. Harmless text, but the upload path does not strip it.
   Fixed in build `20261114.191046`; confirmed on the bench: the refusal
   carries no `detail`.
2. A wrong Installer Passcode is answered with "That PIN is not right." The
   wording should say passcode. Fixed in build `20261114.191046`: its own
   code `VF_BAD_PASSCODE`, "That passcode is not right."; confirmed on the
   bench.
3. In Simulation, publishing a new version resets the simulated devices
   (every display back to Off) while the Active Scene label stays
   ("Game Day since 11:28"). Simulation only; Live reads device state from
   Control4. Fixed in build `20261114.191046`: a rebuilt simulator inherits
   the state of the one it replaces. Covered by a test; not re-checked on
   the bench (it needs a Studio sign-in after the restart). After a driver
   restart in Simulation the simulated devices still start Off while the
   Active Scene label is restored (seen on the bench): the simulator's state
   is not stored.
4. Composer answers "Unable to update driver: Versions are equal" when a
   second build of the same day is imported, and offers to overwrite. It
   compares only the date part of `YYYYMMDD.HHMMSS`. Answering Yes updates
   the driver. The same holds for every driver in this repository.
5. A route refused because the profile may not use the display is printed
   three times in the driver log, one of them as
   `VF_NOT_CONFIRMED ... 1 failed`. The refusal itself is right
   (`VF_FORBIDDEN`, nothing sent); the summary line's code is misleading.
   Not fixed.
6. Composer lost its connection to the controller while idle between the
   two sessions and went "Not Responding" for up to a minute at a time
   while reconnecting. The driver kept answering on port 47861 throughout.
   Not a VenueFlow fault; noted so the next session allows for it.

**Second session, same day, build `20261114.191046`** (SHA-256
`f939bdc5...aeb6752f`): Composer's title bar and project tree named the
bench system again after the reconnect. Besides the rows marked "Second
session" above: a route to a display outside the Bartender profile was
refused with `VF_FORBIDDEN` on the controller, and the Studio page served by
the new build is 539,888 bytes, identical in size to the built page.
