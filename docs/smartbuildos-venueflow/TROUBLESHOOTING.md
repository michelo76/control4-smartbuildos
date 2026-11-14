# VenueFlow troubleshooting

Start with three places:

1. **Installer Studio, Diagnostics**: the driver's own log, with a code on
   every problem.
2. **The driver's properties** in Composer: Driver Status, Configuration, App
   Data Relay, Installer Studio, Last Error, License Status.
3. **The driver's Lua tab** with Log Mode "Print" and Log Level "3 - Info":
   one line per command sent to Control4 (`VenueFlow -> COMMAND on <id>`).
   Actions, **Print Status** prints a summary and the latest warnings.

## The tile or a page does not load

| Symptom | Cause and fix |
| --- | --- |
| The tile is blank or says it cannot reach the controller | App Data Relay shows which address the driver published. If it says the address is unknown or not confirmed, set **App Relay Address** to the controller's LAN address, wait a minute, reopen the tile |
| App Data Relay says "Not listening - port 47861 unavailable" | Another driver holds the port. Remove the conflict and restart the driver |
| `http://<controller>:47861/ping` answers from a laptop but the page stays blank | The page is large; a Navigator on a weak wireless link may time out. Try a wired touch screen. Record it (hardware validation H2) |
| The page loads on a laptop but not in the Control4 app away from the venue | The relay is LAN only. Remote use needs the venue network (VPN) |
| "This venue has not been set up yet" | Nothing is published. Open Installer Studio and publish |
| The page says the venue is not set up, and Configuration reads "Sample venue - not run in Live mode" | A reference venue is published and Control Mode is Live. Build the real venue, or return to Simulation |
| A screen asks for a PIN when it should open directly | No profile is chosen under Staff Profiles, "A tile opens as", or that profile has a PIN |

## Installer Studio

| Symptom | Cause and fix |
| --- | --- |
| "Installer Studio is off until an Installer Passcode is set" | Set the **Installer Passcode** property (6 or more characters) |
| "Too many wrong attempts" | Wait a minute, or run the action **Reset Sign-in Locks** |
| Signed out while working | A Studio session ends after 30 idle minutes, after 8 hours, when the passcode changes, and when the driver restarts. Changes saved before that are in the draft |
| "Draft changed elsewhere" | The Studio is open in two windows. Reload the draft in this one |
| Publish is disabled | Errors must be fixed and every warning ticked. Each issue links to its section |
| "This feature needs a SmartBuildOS licence" on Publish | See Licensing below |
| A floor plan is refused as too large | The picture is over 600 kB after the Studio reduced it. Use a simpler image |
| A sample venue cannot be loaded | Samples load only in Simulation |

## Devices and routing

| What the screen says | Meaning | What to check |
| --- | --- | --- |
| Working (a pulsing mark) | The command was sent; Control4 has not reported the change yet | Wait up to 8 seconds |
| Not confirmed (amber) | Control4 did not report the requested value in time, or reported another | The display's power and input, the source, the room's video path in Composer. Then **Resolve** (Manager Overview) or Devices, Query Status |
| Sent | The device gives no feedback (a custom route, device power, lighting, shades). VenueFlow cannot confirm it | Look at the device |
| Unknown | Never read, or sent and nothing could be read back | Devices, Query Status |
| Offline | Control4 reports the display's network link down | Power, network |
| "That source cannot be shown here" | The source is not in the display's supported list | Devices, the display's sources |
| "That source cannot reach this display" | The display's route strategy is "none" | Devices, the display's route |
| "This device is not connected to Control4 yet" | The display, source or zone has no Control4 room or device | Devices, Sources, Audio Zones |
| "Choose a source to turn this display on" | A room powers its display by selecting a source; there is no last or default source | Give the display a default source |
| "Your profile is not allowed to do that" | The staff profile lacks the permission or the area | Staff Profiles |
| "A newer request replaced this one" | Someone asked for something else on the same display first | Nothing to fix |

Things that surprise people:

- **A display's "room"** is its Control4 room, the one Control4 routes video
  to. Two displays in one Control4 room can never show different sources;
  the Studio refuses that mapping.
- **The sound follows the picture** in a room that is both a display's room
  and an audio zone's room. The Studio warns "AUDIO_COUPLED". Give the audio
  zone its own Control4 room if they must be independent, and check that the
  installation's audio hardware can do it.
- **Fewer Lua tab lines than expected?** Commands leave about 120 ms apart,
  and a newer request for the same display replaces a waiting older one.
- **Nothing reaches Control4 at all?** Control Mode is Simulation. The pages
  show a "Simulation" strip.

## Scenes, rules, schedules

| Symptom | Cause and fix |
| --- | --- |
| "The scene's condition is not met right now" | The scene's IF is false (often: the venue is marked closed) |
| A scene ends "partial" | A device did not confirm. The run names the step and the display (Visual Programming, Execution log; Diagnostics, category "scene") |
| A step says "Not set up yet" | A template step with no source, zone or display chosen, or one whose subject was deleted |
| "This scene runs itself in a loop" | Scenes that run each other in a circle; also a rule triggered by a scene that runs that scene |
| A scene stopped half way, with an alert "... was interrupted" | Another scene or rule that changes the same devices started. That is deliberate |
| A schedule did not run | It was missed while the controller or driver was off (an alert says so: missed schedules are never run late); or the rule is disabled; or the licence is restricted; or the day is not ticked |
| A schedule ran at the wrong hour | Schedules use the controller's clock. Check the project's time zone in Composer |
| Dry Run says "Publish the draft first" | A dry run uses the published configuration, and the program names something that is only in the draft |
| A Composer command did nothing | The **Last Error** property says why |

## Licensing

| License Status | Effect on VenueFlow |
| --- | --- |
| No SmartBuildOS Agent Found | Works fully. Add the Agent (`smartbuildos.c4z`) to license it |
| Agent Found, Checking / Not Linked / Not Authenticated | Works fully |
| Licensed (Subscribed, Permanent, Grace, Trial) | Works fully |
| Not Licensed, Expired, Suspended, Controller Mismatch, **and** the platform enforcing | Scenes, rules, schedules, publishing and rollback stop. Routing, power, audio, lighting, shades, All Off, venue status and backup export keep working. Nothing is switched off |

To re-check now: the action **Register With Agent Now**, or Installer Studio,
Licensing, Check again.

## Sign-in

| Symptom | Fix |
| --- | --- |
| "That PIN is not right" after a publish | The profile's PIN was changed in that version |
| Locked for a minute | Five wrong PINs from that device. Wait, or the action **Reset Sign-in Locks** |
| Everyone was signed out | The driver restarted, or someone ran **End Staff Sessions**, or the version was rolled back |

## Starting again

- **Reload Configuration** (action): re-reads the published version and
  Control4's state. Sends no command.
- **Roll back** (Studio, Publish and Rollback): returns to a previous version.
- **Discard draft changes**: returns the draft to what is published.
- **Restore a backup**: fills the draft; publish to use it.

## Reporting a problem

Include: the driver version (property), OS and Composer versions, Control
Mode, what was pressed, the Diagnostics entries around it (they carry
operation ids), and the Lua tab lines. Remove site names and addresses
before sharing: Diagnostics never holds PINs, the passcode or tokens.
