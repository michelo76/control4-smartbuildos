# VenueFlow hardware validation

**Status: started 14 November 2026; nothing run since.** On the bench
controller H1 passed, the laptop part of H2 passed, and H3 passed including a
driver restart (see Results). The bench still runs build `20261114.191046`,
which carries the fixes for the three defects found on the bench. Build
`20261114.233926` (the Venue Studio for the client, the channel label,
source controls, Remote Management) and everything since (the six review
fixes of 15 November 2026 and the review and audit fixes of 18 November
2026, RELEASE_NOTES.md) **have not been on a controller**: see "Not yet run"
below, and "Order of the remaining runs". Still to do: H2 on Navigators, the
H3 network drop and a restart of the controller itself, H4 to H10.
Everything so far was in Simulation: nothing has been sent to real
equipment. Until H1 to H9 pass, VenueFlow is "simulation verified", not
production ready.

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

The pages ran in three desktop browser engines on 19 November 2026
(TEST_RESULTS.md, Browser tests): that does not replace H2. A desktop
engine is not a touch screen's Firefox 96 nor the iOS or Android app.

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
| H10 denial, and *Trigger the VenueFlow event* and *Mark the venue* under a restricted licence | The owner applying the catalogue-row migration for `SBOS_VENUEFLOW` on smartbuildos.io (it exists, merged 15 November 2026, and is not applied), then a test entitlement set to denied with enforcement (SMARTBUILDOS_INTEGRATION.md) |
| Everything in "Not yet run" | A VenueFlow build from current source imported on the bench (the bench runs `20261114.191046`) |
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

## Not yet run

Everything in this section is simulation verified only (desktop browser,
the simulator and the test shim). None of it has run on a controller. The
first rows came with build `20261114.233926`, the next with the review fixes
of 15 November 2026, the last with the review and audit fixes of 18 November
2026. The order to run them in is under "Order of the remaining runs".

| Check | What to do | Status |
| --- | --- | --- |
| Venue Studio on a touch screen | On a T4, sign in as a profile that holds the Venue Studio permission, open the profile menu, choose Venue Studio. It must open in the same view with no second sign-in, be usable by touch, and "Back to control" must return | Not run |
| Venue Studio in the Control4 app | The same on a phone and a tablet | Not run |
| Client limits on the controller | Signed in as the client, change a scene and publish; confirm the version records the profile. From a laptop, send a hand-made `DRAFT_SAVE` that changes a display: it must be refused | Not run |
| Source controls reach a cable or satellite box | **Live mode, one real box.** Give a profile "Use source controls", open the source's remote and press CH +, CH -, each digit, Enter and Last. Watch the screen. Then a favourite ("206"): all digits must land, in order. If a digit is dropped, the 350 ms spacing is too short for that box | Not run. **The least certain item in this build**: sending these commands from another driver to the source's device is not documented |
| Source controls, other kinds | The same for a streaming box (arrows, OK, play, pause) and a media player | Not run |
| One box, many screens | Route one box to three displays, press CH +: all three change. The remote says how many screens are showing it | Not run |
| Remote Management, registration | With a build from current source and the bench Agent (built from `main` on 18 November 2026), set the property to Draft only. Remote Management Status must reach "On - draft only" once the Agent answers, and the module must appear for the system in System Studio. Then set it to Off and back | Not run. The Agent allows the `venueflow` module; a VenueFlow registration with it has never been watched |
| Remote Management, end to end | From smartbuildos.io (System Studio, Drivers & Licenses, VenueFlow): Refresh from controller; the module's row must show the one-line summary and the live version (`config_version`, the published version id, or `none`). Change a channel label, Send as draft, check the draft on the local Studio (a client signed in there must now be told the installer has unfinished changes), Publish, Roll back: after each, the live version shown must be the new one. Time each step. Then edit the draft on site and send a remote draft made from the older copy: it must be refused as stale | Not run. The platform side is deployed; it has never been run with a controller |
| Remote Management, a large venue | Send a draft near the size limit (about 170 kB of JSON) and watch the controller: Agent check-in time, driver responsiveness | Not run |
| Remote Management, a mapping change refused (19 November) | From smartbuildos.io (Whole configuration), change a display's Control4 room and send it as a draft. The operation must end Failed, System Studio must show the sentence ("Remote Management cannot change device mapping or device commands: Display '...' room. Change these on site in Installer Studio."), the controller's draft revision (Draft property) must be unchanged, and Diagnostics must log the refusal | Not run |
| Remote Management, an on-site remap not published (same) | On site, change a display's room in Installer Studio and leave it unpublished. From the platform, publish: refused with `VF_ONSITE_ONLY` ("cannot put device mapping or device commands live"); the live mapping (Configuration property, Query Status) is unchanged. Then save another edit remotely on top of it: accepted | Not run |
| Remote Management, a long refusal (same) | Send a remote draft that changes the mapping of many displays with long names: the detail must arrive whole on the platform (the code, then at most 380 bytes, ending "... and N more. Change these on site in Installer Studio.") | Not run. The Agent's 400-byte limit for a result's detail is from its code, not seen end to end |
| Two rules on one Control4 variable (review fixes of 15 November) | **Live.** Two enabled rules triggered by the same device variable, each doing something visible; change the variable in Composer. Both must run. Then one rule on a mapped room's `POWER_STATE`: switch that room from a Control4 remote; the rule runs AND the display's state on the tile follows | Not run. Simulated Director only (`test_venueflow_adapter.lua`); whether Director calls a listener at once when it is set, and what a rule does with that first call after a publish, is unobserved |
| Stopping a scene mid-queue (same) | **Live, a scene routing to at least eight displays.** Activate it and press Stop in Executions within a second. Count the displays that changed: no more should change after the stop. Repeat with All Off instead of Stop: no display comes back on | Not run |
| A sample draft in Live (same) | In Simulation load a sample without publishing, switch Control Mode to Live, open a display's inspector and press Test Power Off and Query Status. Both must answer "simulation only" and the Lua tab must show no command | Not run |
| A schedule right after a publish (same) | Publish a schedule due in the next minute, about ten seconds before that minute starts. It must fire | Not run |
| A client refused on the default profile (18 November) | Signed in as the client in the Venue Studio, change the permissions of the profile a tile opens with, then of a station's profile, and try to set or clear the PIN of each. Every one must be refused as installer-only ("the profile a screen or station opens with"). Changing another staff profile must still work | Not run |
| A client refused while the installer has saved work (same) | In the installer's Studio, change a schedule and let it save; do not publish. Signed in as the client, try Publish and Discard: both refused, and the client's Studio shows "Your installer has unfinished changes". Publish as the installer: the client can publish again. Repeat with the installer setting a staff PIN | Not run |
| Revisions after a backup restore (same) | Note the draft revision, export a backup, discard the draft, restore the backup: the restored draft's revision must be higher than any revision seen before | Not run |
| *Configuration Published* on a rollback (same) | In Composer, program the VenueFlow event *Configuration Published* to do something visible (or watch the Flight Recorder). Publish, then roll back in Publish and Rollback: the event must fire both times, and the rollback's marker must name the new live version and the version it restored | Not run |
| *Venue is open* in Composer programming, both senses (same) | Program two lines: IF *Venue is open* is open, and IF *Venue is open* is closed, each doing something visible. Mark the venue open and closed and run each line. Then the same for *VenueFlow has alerts* (showing alerts, and clear). Each line must run only in its own case | Not run. **The test shim cannot tell how Composer passes the choice**: the driver reads it from `VALUE` as the DriverWorks sample does; that is what this check settles |
| *Alert Raised* when a display stops confirming (same) | Program *Alert Raised* to do something visible and watch ALERT_COUNT and the Alerts property. In Simulation, give a display the simulator fault "silent" and route to it; in Live, unplug a display's control and route to it. After about 8 seconds the event must fire once, and ALERT_COUNT and Alerts must both go up by one. Resolve once the cause is gone: both go back down. The event fires again only when the alert comes back | Not run |
| *Trigger the VenueFlow event* under a restricted licence (same) | With the denial of H10 in place, run *Trigger the VenueFlow event* for a name a rule waits for. No rule runs, and Last Error reads `TRIGGER_EVENT refused: licence restricted: 1 rule(s) not run` | Not run. Blocked: see "Blocked today" |
| *Mark the venue* under a restricted licence (same) | With the denial of H10 in place and a rule waiting for the venue to open, run *Mark the venue* Open from Composer. Venue Status must read open, Venue Opened must fire, the rule must not run, and Last Error must read `SET_VENUE_STATUS: status set; 1 rule(s) not run: licence restricted`. Then close and open the venue from the Manager screen: the screen must say "Venue marked open. 1 automation set to run at this moment did not run: the SmartBuildOS licence is restricted." | Not run. Blocked: see "Blocked today" |
| Alerts a profile is shown (same) | In Simulation, let a scene stop another one (two scenes on the same displays), so an "interrupted" alert is stored. Sign in as a profile that cannot see one of those displays: the alert must not be listed, and Dismiss by its id must answer as not found. A manager who sees everything sees it and dismisses it; ALERT_COUNT goes down at once | Not run |
| Floor plan by touch on a 7-inch T3 (page changes of 19 November) | **T3 7", 1024 x 600.** On the sample sports bar's Floor Plan, tap each of several adjacent small displays in turn (the column of TVs 05 to 08): each tap must select exactly that display. Tap between two of them: "Which display?" must open with both. With nothing selected, Power On and Power Off must be visible; with displays selected, scroll the side panel to reach them (a fade with an arrow marks that there is more). Repeat on a T4 and a phone | Not run. Measured with touch emulation in three desktop engines, Chromium 159, WebKit 27.2 and Firefox 159, the same within 1 px (smallest effective target 27 to 28 px for those columns at 1024 x 600); the plan now judges a tap from where the finger went down, so whether the touch screen's browser moves taps should not matter, but that is unseen |
| Long names and touch sizes on real screens (same) | On a T3, a T4 and a phone, open each operator screen with a long display or zone name ("Boardroom A Main"), the Venue Studio, and the Installer Studio on a tablet: names take two lines, switches and icon buttons can be pressed, the Studio header and its Sections drawer work on the phone | Not run. Desktop engines only (Chromium 159, WebKit 27.2 and Firefox 159 (desktop engines)), at the sizes in `ui/venueflow/README.md` |
| The floor plan by touch in the iOS app and on a T4 (19 November, browser engines) | In the Control4 app on an iPhone and on a T4, on the sample sports bar's Floor Plan, tap each of several adjacent small displays (TVs 05 to 08), then between two: each tap selects the display it was nearest, a tap between two opens "Which display?" | Not run. Measured in WebKit 27.2 with an iPhone descriptor and Firefox 159 on the desktop, the same as Chromium; whether the real browsers move taps is unknown |
| A notice does not block the slider (same) | On a phone, power a display on from the Floor Plan and at once drag the zone volume slider under the "sent" notice: the slider must move at once | Not run. Desktop engines only |
| A dialog's footer with the toolbars showing (same) | In the Control4 app on an iPhone, with the browser's toolbars or the keyboard showing, open the All Off preview and the PIN pad: the dialog's buttons must be visible and pressable | Not run. WebKit desktop shows no Safari toolbars |
| An exact level with the slider on a 7-inch T3 (same) | On a T3 7" (1024 x 600), set a zone to an exact level (say 40) with the Floor Plan bar's slider and with a Command Center zone card's: record how close a finger gets. The sliders are 110 px and 94 px wide, about one pixel per volume step | Not run. Known limitation (RELEASE_NOTES.md, limitation 20) |
| Publish and Discard from two windows (same) | On a laptop, open the Studio in two windows. Save a change in one, then press Publish (and, another time, Discard) in the other: nothing is published or discarded, the page says the draft changed since it loaded it and reloads it. Repeat signed in as the client | Not run on a controller |
| The client's reason and read-only screen profiles (same) | As the client, with the installer's saved change pending: the header, Home and Publish and Rollback say "Your installer saved changes that are not live yet" and Publish and Discard are disabled. In Staff Profiles, the tile's profile (and a station's, if the venue has stations) is read-only. Then with a remote draft from the dealer: the wording names the dealer | Not run. The dealer wording was seen only with the page's state set by hand; the station case not at all |
| A scene that tunes a box (19 November) | **Live, one real box.** A scene with a route of that box to a display, then a "Tune a channel" step to a favourite. Run it: the box must land on the channel, and Diagnostics (debug level) must show each key, in order, with no other source's key between them | Not run. That `C4:SendToDevice(sourceDevice, "NUMBER_2")` from another driver reaches a real box has never been seen |
| The pause after a cut-off number (same) | **Live, one real box.** Run a scene that tunes a four-digit number and press Stop after the first or second digit. Then at once press a favourite on the remote: after about 3 seconds its digits must land as that channel, not joined to the unfinished ones. Try a shorter wait if the box drops digits sooner; record what the box needs. While the box pauses, press a key for another source: it must act at once | Not run. The 3 seconds are an assumption |
| A box that dials without Enter (same) | Switch "Press Enter after the digits" off for a box that tunes by itself, and run a scene with two tune steps to two channels: both must land, as two channels | Not run |
| A channel dialled across a publish (same) | **Live, one real box.** Press a favourite with three or four digits and publish a change from the Studio at once: every digit must land and Diagnostics must show no stop. Then press it again and change the source's Control4 device (or Control Mode) at once: the rest of the digits stop, and Diagnostics says so (`VF_CANCELLED`) | Not run |

## Order of the remaining runs

Each step needs only what the steps before it needed, plus what is named.
Import a build from current source first (`make venueflow`, then import
`dist/oss/smartbuildos-venueflow.c4z`, after reading Composer's title bar).

1. **Bench controller in Simulation, Composer Pro and a laptop on the bench
   LAN; no AV equipment.** Re-run H1 and H3 on the new build, then: a client
   refused on the default profile, a client refused while the installer has
   saved work, revisions after a backup restore, *Configuration Published*
   on a rollback, *Venue is open* both senses, *Alert Raised* with the
   simulator fault, alerts a profile is shown, Publish and Discard from two
   windows, the client's reason and read-only screen profiles, client limits on the controller, a sample draft in Live
   (switching to Live with a sample sends nothing), a schedule right after a
   publish.
2. **The same, plus the SmartBuildOS Agent in the project and a dealer
   account on smartbuildos.io that holds the bench system.** Remote
   Management registration, then end to end, then a large venue, then
   a mapping change refused, an on-site remap not published and a long
   refusal.
3. **The same, plus a T3 or T4 touch screen and a phone and a tablet with
   the Control4 app.** H2 on Navigators, the Venue Studio on a touch screen
   and in the app, the floor plan by touch on a 7-inch T3, long names and
   touch sizes on real screens, the floor plan by touch in the iOS app and
   on a T4, a notice over the slider, a dialog's footer with the toolbars
   showing, an exact level with the slider on a 7-inch T3, H8.
4. **Live, with the AV part of the bench project** (two display rooms with a
   video path from two shared sources through a matrix or AV-over-IP, one
   audio zone room with volume control). H4 to H7, *Alert Raised* with an
   unplugged display, stopping a scene mid-queue, two rules on one Control4
   variable, H5.
5. **Live, plus one real cable or satellite box** (and a streaming box and a
   media player, when available). Source controls, other kinds, one box on
   many screens, a channel dialled across a publish, a scene that tunes a
   box, the pause after a cut-off number, a box that dials without Enter.
6. **Someone at the controller for a service evening.** H9 including a
   restart of the controller itself, and the H3 network drop.
7. **After the owner applies the `SBOS_VENUEFLOW` catalogue-row migration,
   with a test entitlement set to denied.** H10, *Trigger the VenueFlow
   event* and *Mark the venue* under a restricted licence.
8. **When the calendar allows.** The daylight-saving row of H9.
