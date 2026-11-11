# SmartBuildOS Agent

The SmartBuildOS Agent connects a Control4 project to
[SmartBuildOS](https://app.smartbuildos.io). It does three jobs. It is the
licence desk for every other SmartBuildOS driver in the project: each one asks
the Agent whether it is licensed, and the Agent answers from what SmartBuildOS
issued. It reports the health of the system: which devices are up, which are
down, when the controller restarted. And it brings SmartBuildOS notices back
into Control4 programming, so they can reach the homeowner's phone.

Add one Agent per project, from Composer's Agents view. It needs Control4 OS
**3.3.1** or later; on an older controller it disables itself and says so in
**Driver Status**. It talks outbound over HTTPS only: nothing needs to be
opened on the client's firewall. The Agent is the licensing authority, so it
has no **License Status** of its own. Every other SmartBuildOS driver has one,
and this manual is where it is explained.

## What it is for

| You want | Use |
| --- | --- |
| Every SmartBuildOS driver in the project licensed | One paired Agent. Read **Licensed Drivers** here and **License Status** on each driver |
| To know the site is reporting | **Connection Status**, **Last Successful Sync**, the events *Connected* and *Disconnected*, the conditional *SmartBuildOS connection status* |
| To know when a device drops off the network | *Device Went Offline* and *Device Came Online*, **Devices Offline**, **Last Device Change** |
| A switch, access point or NAS with no Control4 driver watched as well | **Non Control4 Devices** |
| To tell SmartBuildOS something only programming can see (a rack door, a UPS on battery) | `SEND_EVENT`, `REPORT_STATE`, `REPORT_MEASUREMENT`, `REPORT_COUNTER`, `REPORT_FAULT`, `REPORT_SERVICE_EVENT` |
| A SmartBuildOS notice on the homeowner's phone | *Service Update*, *Issue Detected*, *Issue Updated*, *Issue Resolved*, wired to a push notification |
| To notice a controller that keeps restarting | *Director Reloaded*, `DIRECTOR_RELOADS`, **System Startups Today**, *Startup Threshold Reached* |
| Restart notices held back while you work on site | *Enter Service Mode* |
| To decide what SmartBuildOS may operate in this home | **Remote Control** |
| A read-only status page on a touchscreen | *Generate Touchpanel URL* |
| The SmartBuildOS drivers kept current | *Update Drivers*, **Automatic Updates** |
| A note on the service record from Composer | `RECORD_SERVICE_NOTE` |

## Setup

<!-- walkthrough: Install and pair the Agent -->
1. In Composer Pro choose Driver, then Add or Update Driver or Agent, and pick
   `smartbuildos.c4z`.
1. Open the Agents view, click Add and choose SmartBuildOS Agent. Keep one per
   project. **Driver Status** reads `Online` and **Connection Status** reads
   `Not paired`.
1. In SmartBuildOS, open the property and generate a pairing code. The code
   is single-use and short-lived.
1. Paste it into **Pairing Code**. **Connection Status** reads `Pairing...`
   and then `Connected`, and the field clears itself.
1. Read the result: **Paired Property** names the site, and
   **License Cloud** starts with `OK` once the licences have been fetched.
1. Add the other SmartBuildOS drivers. Each one registers with the Agent by
   itself and shows its **License Status**. **Licensed Drivers** on the Agent
   counts them.
1. Set **Remote Control** to what the homeowner agreed to; it starts at
   `Identify only`. List anything without a Control4 driver under
   **Non Control4 Devices**.

On pairing, the Agent redeems the code for a long-lived device token, fires
*Paired*, sends a full device snapshot and a heartbeat, and fetches the
licences. The token is what grants access. It is stored encrypted on the
controller and copied into the masked, read-only **Pairing Backup** property so
that the pairing survives a driver update. That property is kept with the
project, so treat a project backup as carrying the pairing. The token, the
codes and the backup are kept out of the log.

### Pair by account number

<!-- walkthrough: Pair by account number -->
1. Type the client's account number into **Account Number**.
   **Connection Status** says a code was emailed if the account matches. The
   answer is the same whether or not the account exists.
1. SmartBuildOS emails a single-use code to the address already on the
   account, so the account number alone is not enough to pair.
1. Type that code into **Verification Code**. The Agent pairs as it does with
   a pairing code, and the field clears itself.

SmartBuildOS decides which system the controller lands in: one it has seen
before pairs back into its existing system, and a new one gets a new system
under the account, which a dealer links to a property from the console.

### Updating and unpairing

> **Updating an existing install:** use Driver, Add or Update Driver or Agent
> and load the new `smartbuildos.c4z`; it refreshes the instance in place. If
> the stored token did not survive the update, the Agent restores the pairing
> from **Pairing Backup** with no new code. An older install that sits under
> System Design has to be removed there and added again from the Agents view;
> pair it again if **Connection Status** then reads `Not paired`.

*Unpair* tells SmartBuildOS, then forgets the token, the backup, the cached
licences and the touchpanel URL, and stops reporting. It does so even when
SmartBuildOS cannot be reached, so an Agent is never stuck in a pairing it
cannot leave. The other drivers keep running and show
*SmartBuildOS Agent Found - Not Linked* at their next check.

## Licensing

### How a licence reaches a driver

Each SmartBuildOS driver finds the Agent by its file name, registers its SKU
and version, and gets its answer straight back. There is no binding to make
and the driver holds no account credentials. The Agent answers from licences
that SmartBuildOS issued for this controller, signed with a secret the
controller received when it paired, and kept encrypted on the controller.

The Agent fetches licences when it pairs, when a driver it has no record for
registers, and on *Refresh Entitlements Now*. Otherwise it looks once an hour
and fetches again when the last fetch is more than 24 hours old; SmartBuildOS
can change that period. After each fetch it tells every registered driver
where it stands, and each hour it tells any driver whose standing has changed.

### What the Agent shows

| Property | Reads |
| --- | --- |
| **SmartBuildOS Company** | `Not registered - pair to a company` until paired, then the company name. `Registered (name syncing)` means paired, name not received yet |
| **Subscription Tier** | `Not paired`, `Syncing...`, or the plan name as SmartBuildOS sends it, with `(grace)` added while the subscription is in its grace window |
| **Licensed Drivers** | `No SmartBuildOS drivers installed`, or for example `3 licensed / 4 installed`: of the SKUs registered with this Agent, how many hold a licence now |
| **License Cloud** | The state of the licence cache. See [Troubleshooting](#troubleshooting) |
| **Support ID** | The reference SmartBuildOS support uses to find this controller |

A company name or tier that SmartBuildOS could not confirm is not overwritten:
the last known value stays until a confirmed one replaces it.

### What each driver shows: License Status

Every licensed driver has a **License Status** line. Beside it are the tier,
the company and where the licence comes from: `Included with subscription`,
`Purchased outright`, `Trial` or `Grace period`.

| License Status | Meaning | What to do |
| --- | --- | --- |
| *No SmartBuildOS Agent Found* | There is no Agent in this project | Install and pair the Agent |
| *SmartBuildOS Agent Found - Not Linked* | The Agent answered, and it is not paired | Pair the Agent |
| *SmartBuildOS Agent Found - Checking...* | The driver asked and has no answer yet. It asks again after 5, 15, 30 and 60 seconds, then every five minutes | Wait, or run *Register With Agent Now* on drivers that have it |
| *Licensed / Subscribed* | Covered by the company's plan | Nothing |
| *Licensed / Permanent* | Bought outright | Nothing |
| *Licensed / Trial* | A trial licence | Nothing |
| *Licensed / Grace (until date)* | Licensed, with an end date: SmartBuildOS issued a grace licence, or the Agent has not reached SmartBuildOS for a week | Restore the Agent's connection, or settle the account |
| *Licensing Not Yet Enforced* | The Agent is paired and holds nothing from SmartBuildOS for this driver's SKU | Run *Refresh Entitlements Now*; then ask SmartBuildOS |
| *Cloud Validation Required* | The Agent cannot vouch for the licence: more than ten days without contact, or a cached licence that no longer verifies | Restore the connection, then *Refresh Entitlements Now* |
| *SmartBuildOS Agent Not Authenticated* | A status SmartBuildOS can issue when it cannot authenticate the Agent | *Refresh Entitlements Now*; pair again if it stays |
| *Agent Linked - Not Licensed (see SmartBuildOS)* | The account has no licence for this driver | Buy or assign one in SmartBuildOS |
| *License Expired (see SmartBuildOS)* | The licence ran out | Renew it |
| *Account Suspended (see SmartBuildOS)* | The account is suspended | Contact SmartBuildOS |
| *License Registered To Another Controller* | The licence belongs to a different controller | Transfer it in SmartBuildOS |

### Agent missing, offline, or the subscription has lapsed

A driver is only ever restricted on a definite "no" from SmartBuildOS.
Anything uncertain leaves the home working.

| Situation | License Status on the drivers | Do the drivers keep working |
| --- | --- | --- |
| No Agent in the project | *No SmartBuildOS Agent Found* | Yes |
| Agent installed, not paired (or unpaired) | *SmartBuildOS Agent Found - Not Linked* | Yes |
| Agent cannot reach SmartBuildOS, up to 7 days after the last fetch | Unchanged | Yes |
| 7 to 10 days after the last fetch | *Licensed / Grace*, with the date grace ends | Yes |
| More than 10 days | *Cloud Validation Required* | Yes. It clears at the next successful fetch |
| SmartBuildOS says the subscription lapsed, the licence expired, the account is suspended or the licence is on another controller | The matching line from the table above | Yes, unless enforcement is on for that driver |

The 7 days are a default SmartBuildOS can change; the 10 days are fixed in the
Agent. Only a licensed status ages this way: a refusal stays a refusal however
old the cache is. A wrong controller clock does not lock anything; if it has
moved back over an hour since the last fetch, the Agent fetches again.

**Enforcement.** SmartBuildOS switches enforcement on per driver SKU. It is
off unless SmartBuildOS says otherwise. With it on, a driver acts only on four
statuses: *Agent Linked - Not Licensed*, *License Expired*,
*Account Suspended* and *License Registered To Another Controller*. Its
**License Status** then ends with `(read-only)` and the driver stops its
licensed work; each driver's own manual says what that is.
*Cloud Validation Required*, an Agent that is not authenticated, a missing
Agent and an unpaired Agent are never enforced.

## What it monitors

Three sources, because no single one sees everything:

| Source | Covers | How |
| --- | --- | --- |
| **Director** | Every device in the project that has a network binding, Control4 or not: a television over IP, a receiver, a switch, keypads, dimmers | The project's device list and each device's network binding: online state, address, MAC where the binding carries one, room, driver file |
| **Ping** | Anything else with an IP address: core switches, access points, NAS, cameras, printers | ICMP against the hosts you list in **Non Control4 Devices** |
| **Programming** | Anything neither of the above can see: a rack door contact, a UPS on battery | The `SEND_EVENT` and `REPORT_...` commands |

Director reports IP, Zigbee, Z-Wave, SSL and hostname bindings. A binding's
status is the authority: anything other than `online` is treated as down, so
an unexpected value fails visibly. A driver that was added and never pointed
at hardware has no address and is not counted in **Devices Offline**.

**What Director cannot tell you:** devices with no network binding at all
(IR-controlled sources, serial-only gear, dumb loads) never appear, so they
have no online state to report. Put anything you care about in that gap behind
a `SEND_EVENT` in programming, or give it an IP address and list it under
**Non Control4 Devices**.

The Agent reads Director and pings the listed hosts on every
**Device Poll Interval**, and reports only what changed. A device that stays
down is reported once when it drops and once when it recovers. The first read
after the driver loads is a baseline: it fires no device events, so a
controller restart does not look like every device coming online at once.

**Non Control4 Devices** is a comma-separated list. Each entry is `Label=host`
or a bare host, which is labelled with itself:

```
Core Switch=192.0.2.2, Rack UPS=192.0.2.3, NAS=192.0.2.10, 192.0.2.50
```

Each host is pinged up to three times per poll, five seconds apart, so an
unreachable host is reported about fifteen seconds into the poll. Editing the
list polls at once.

**Discover Network Devices** is off by default. When on, the Agent listens for
devices announcing themselves over SSDP and reports each one it hears, which
is how equipment that is not in the Control4 project shows up: speakers a
dealer never added, for example. These arrive with an address and whatever
name, maker and model the device announces: no device id, no room, no control
state. A device that is in the project keeps the entry from its binding; an
announcement never replaces it.

**Network Scan** is off by default. When set to an interval, or on
*Scan Network Now*, the Agent pings every address on the subnets its known
devices are on, at most 512 addresses. **Last Network Scan** shows the time
and how many answered. SmartBuildOS is sent the addresses that answered and
are neither in the project nor listed. This is an inventory, not monitoring:
nothing found is watched until you list it, and devices that ignore ping are
missed.

## What it sends, and what it does not

Every request is made by the Agent, outbound, to the address in **API URL**.
SmartBuildOS never connects to the controller: its settings and its commands
come back on the answers to requests the Agent already makes.

| Payload | When | Contents |
| --- | --- | --- |
| Pairing | When you enter a code | The code, the controller model, OS and driver versions, the Agent's and Director's device ids and names, the controller's MAC |
| Snapshot | On pairing, at start, on **Full Sync Interval**, on *Send Full Sync* | Every monitored device and its current state |
| Delta | On **Device Poll Interval**, when something changed | Only the devices that came up, went down, appeared or were removed |
| Heartbeat | On **Heartbeat Interval** | Proof of life, device totals, failure count, what this build can do, queue depth, reload count and last reload, clock offset, programming counts, the Agent's memory use, startup counters, registered modules |
| Event | On `SEND_EVENT` and `RECORD_SERVICE_NOTE`, and for the Agent's own notices (a failed sync, a reload, a scan result) | A name and free text |
| Telemetry | Every 45 seconds while anything is queued | Device online and offline transitions with their original time, `REPORT_...` entries, clock drift |
| Licence refresh | See [Licensing](#licensing) | The SKU, version and device id of each registered SmartBuildOS driver, and of the Agent |
| Startup observation | After a start, once **Stabilization Delay** has passed | How the start was classified, and the startup counters |

Each report also names the system: the paired system or property, the
controller model, OS and driver versions, the Agent's and Director's device
ids and names, and where the controller gives them, the Composer project
name, the controller's address, its MAC and its uptime.

**Sent only when someone chooses it:**

- **Home activity.** What is selected and playing in each room (with cover
  art), viewing and listening sessions, thermostat readings, the state of
  locks, security, contacts, motion and leak sensors and their batteries,
  light levels, and keypad presses. This is off until SmartBuildOS turns
  monitoring on for this system; nothing in Composer starts it. With it comes
  a catalogue: the name and a sample value of each room and device variable.
  SmartBuildOS can also ask for the catalogue alone, and reading it starts
  keypad-press reporting.
- **Discovery and scans.** Only with **Discover Network Devices** or
  **Network Scan** on, *Scan Network Now*, or a scan SmartBuildOS asks for.
- **Diagnostics.** *Report Diagnostics*, *Report Telemetry Survey* and
  *Probe Capabilities* send samples of real project data: device names,
  variable names and values, bindings, one line of programming text. They run
  when you press them; SmartBuildOS can also ask for diagnostics or a probe.
- **Camera snapshots.** Only with **Remote Control** at `Comfort` or above.
- **Other drivers' data.** A SmartBuildOS driver may hand the Agent its
  device list or its events to forward. That driver's manual says what.

**Not sent, and not done:**

- Programming text. The heartbeat carries counts only.
- The Agent's token and signing secret are never given to another driver. A
  driver that uploads directly gets a credential limited to its own SKU on
  this controller.
- A security code that arrives with an arm or disarm request is passed to the
  security driver and is not repeated in the answer.
- The Agent sends no email. **Alert Email** and the four switches below it are
  passed to SmartBuildOS, which sends the mail. In this build they travel only
  with the Director reload report.

## Remote Control: what SmartBuildOS may operate

**Remote Control** is the limit on what SmartBuildOS can command in this home.
It is checked on the controller for every such command, so nothing outside the
home can raise it. Each tier includes the ones above it.

| Tier | Allows |
| --- | --- |
| `Off` | No commands that act on the home |
| `Identify only` (default) | Flashing a keypad's LEDs red for 1 to 30 seconds (5 unless told otherwise) to find it, then restoring its colours. Keypads only |
| `Comfort` | Also: a light on, off or to a level; thermostat setpoints, held to 60–85°F and never a mode change or off; activating a scene; one camera snapshot at a time |
| `Full control` | Also: locking and unlocking, garage open and close, arming and disarming security. Disarming needs a user code. SmartBuildOS requires the homeowner to approve each of these on their phone before it is sent |

Requests to report (a full sync, a heartbeat, diagnostics, a capability probe,
the catalogue, a network scan), notices, and a fixed list of operations on
SmartBuildOS module drivers (pause, resume, apply settings) are not limited by
this property: they do not operate equipment. A command the Agent does not
know is refused by name. Commands arrive on the next check-in, so
**Heartbeat Interval** is also how long a command can wait. Lowering the tier
takes effect at once.

## Notices, restarts and service mode

**Notices.** When SmartBuildOS sends a notice, the Agent fires one of four
events and sets variables, so one piece of programming can carry every notice:

| Notice | Event | Variables |
| --- | --- | --- |
| A routine notice | *Service Update* | `NOTICE_TEXT` gets the text |
| A problem | *Issue Detected* | `ISSUE_TEXT` gets the text, `ISSUE_SEVERITY` becomes `Info`, `Warning` or `Critical` (`Warning` unless SmartBuildOS says otherwise) |
| News on that problem | *Issue Updated* | As for *Issue Detected* |
| The problem is over | *Issue Resolved* | `ISSUE_TEXT` empties, `ISSUE_SEVERITY` returns to `None` |

`NOTICE_TYPE` always holds the name of the last event. The text is the title,
a dash, then the detail. The issue variables are the state of the home, not a
log: resolved clears them. The notice is also written to Control4's History
when the History agent is installed.

**Restarts.** The Agent counts its own starts and says what each was.
**Last Reload** shows the time and `first`, `update` or `reload`. Only a
reload, where Director came back under an unchanged driver, adds to
**Director Reloads** and fires *Director Reloaded*; a driver update does not.
Separately, **System Startups Today** and
**Controller Reboots Observed Today** count Director startups and changes of
the controller's boot identity, and the start fires one of
*System Startup Observed*, *Controller Reboot Observed* or
*Startup Threshold Reached* (when today's count reaches
**Startup Threshold**). Adding or updating the driver is never counted. The
counters and any startup report not yet delivered survive a driver restart.

**Service mode.** *Enter Service Mode* marks the system as being worked on for
**Service Mode Duration**. A startup seen in that time is still recorded and
sent, marked so that SmartBuildOS holds back its notification. It ends by
itself at **Service Mode Expires At**, or with *Exit Service Mode*.

## Worked examples

### A SmartBuildOS issue on the homeowner's phone

<!-- walkthrough: Push SmartBuildOS notices to a phone -->
1. Make sure the project has Control4's Push Notification agent, with a
   notification written for this purpose.
1. In Programming, select the Agent and the event *Issue Detected*. Add the
   command that sends that push notification.
1. Do the same for *Issue Resolved*, and for *Issue Updated* and
   *Service Update* if the homeowner wants those too.
1. To send only serious ones, put the command inside a conditional on the
   Agent's variable `ISSUE_SEVERITY` equal to `Critical`.
1. Test the routine-notice wiring: on the Agent's Actions tab press
   *Send Test Notification*. It fires *Service Update* and sets `NOTICE_TEXT`
   to a test text. It does not fire the issue events.

### Rack equipment only programming can see

- A generator's fault contact closes: `REPORT_FAULT` with NAME `Generator`
  and DETAIL `Low battery`.
- A battery reading held in a variable: `REPORT_MEASUREMENT` with NAME
  `UPS Battery`, VALUE `37`, UNIT `%`. VALUE must be a number: `37%` is
  refused, and the Lua output says so.
- Each time the garage door runs: `REPORT_COUNTER` with NAME
  `Garage Door Cycles`. Each call adds one.
- A rack door opens: `REPORT_STATE` with NAME `Rack Door` and VALUE `OPEN`.

These are queued and sent together within about 45 seconds. `SEND_EVENT` is
sent at once instead, and is not kept if the connection is down.

## Programming reference

### Events

| Event | Fires when |
| --- | --- |
| *Connected*, *Disconnected* | Deliveries to SmartBuildOS start succeeding, or start failing. On the change only, so a long outage is one event. *Cloud Connection Changed* fires with either |
| *Sync Failed* | Each time a delivery fails |
| *Paired* | A pairing completes |
| *Device Went Offline*, *Device Came Online* | A poll finds that a monitored device changed state. **Last Device Change** names it |
| *Director Reloaded* | At start, when Director came back under an unchanged driver |
| *Unexpected Restart* | With *Director Reloaded*, when no shutdown or OS-update notice was recorded before it |
| *Service Update*, *Issue Detected*, *Issue Updated*, *Issue Resolved* | SmartBuildOS sends a notice |
| *System Startup Observed*, *Controller Reboot Observed*, *Startup Threshold Reached* | At start, one of the three, when **Startup Monitoring** is `On` |
| *Notification Failed* | SmartBuildOS reports it could not notify about a startup, or *Send Test Notification* fails |
| *License Status Changed* | The text of **License Cloud** changes |
| *Clock Drift Detected* | The controller clock is 120 seconds or more from SmartBuildOS's. Once, until it has come back within 60 |
| *Project Changed*, *Programming Changed*, *OS Update Started* | On Director's own notices. Not in this build: see [What is not claimed](#what-is-not-claimed) |
| *Report Ready*, *Report Failed*, *Controller Mismatch* | Nothing in this build fires them |

### Conditionals and variables

Two conditionals: *SmartBuildOS connection status*
(`SMARTBUILDOS_CONNECTED`), Connected or Disconnected by the last delivery,
and *SmartBuildOS pairing status* (`SMARTBUILDOS_PAIRED`), Paired or Not
paired. The variables are all read-only:

| Variable | Holds |
| --- | --- |
| `DIRECTOR_RELOADS`, `LAST_RELOAD` | The number in **Director Reloads**, and the time of the last start in UTC |
| `NOTICE_TYPE`, `NOTICE_TEXT`, `ISSUE_TEXT`, `ISSUE_SEVERITY` | The last notice. See [Notices](#notices-restarts-and-service-mode) |
| `SYSTEM_STARTUPS_TODAY`, `CONTROLLER_REBOOTS_OBSERVED_TODAY` | The two daily counters |
| `SERVICE_MODE_ACTIVE`, `CLOUD_CONNECTED` | True while service mode is on; true while deliveries succeed |
| `LICENSE_STATE` | The text of **License Cloud** |
| `REPORT_STATUS` | `not-requested`, `generation-requested`, `send-requested` or `request-recorded` |
| `CLOCK_OFFSET_SECONDS` | Controller clock minus SmartBuildOS's, in seconds |
| `PROGRAMMING_DISABLED_LINES` | Disabled programming lines at the last count |
| `LAST_PROJECT_CHANGE` | The text of **Last Project Change** |

### Commands

| Command | Parameters | What it does |
| --- | --- | --- |
| `SEND_EVENT` | `NAME`, `DETAIL` | Sends a named event to SmartBuildOS at once. Ignored without a NAME |
| `REPORT_STATE` | `NAME`, `VALUE` | Queues a named state, such as Rack Door = OPEN |
| `REPORT_MEASUREMENT` | `NAME`, `VALUE`, `UNIT` | Queues a number with its unit. Refused if VALUE is not a number |
| `REPORT_COUNTER` | `NAME` | Queues one count for that name |
| `REPORT_FAULT` | `NAME`, `DETAIL` | Queues a fault |
| `REPORT_SERVICE_EVENT` | `NAME`, `DETAIL` | Queues a service event, such as Filter replaced |
| `RECORD_SERVICE_NOTE` | `NOTE` | Sends a note of up to 1,000 characters to the service record |

## Properties

| Property | Description |
| --- | --- |
| **Automatic Updates**, **Update Channel**, **Update Source** | Every 30 minutes the Agent decides whether to update the installed SmartBuildOS drivers. **Automatic Updates** (`On` by default) decides until a settings document from SmartBuildOS is in force; after that **Auto-update Preference** does, and only `automatic` updates. Channel `Production` or `Prerelease`. Source `Auto` (SmartBuildOS when paired, falling back to GitHub), `SmartBuildOS` only, or `GitHub` only |
| **API URL** | Read-only. The SmartBuildOS address the Agent reports to |
| **Pairing Code**, **Account Number**, **Verification Code** | The two ways to pair. See [Setup](#setup) |
| **Pairing Backup** | Masked and read-only. Written by the Agent; cleared by *Unpair* |
| **Remote Control** | `Off`, `Identify only` (default), `Comfort`, `Full control` |
| **Paired Property**, **Connection Status**, **Last Successful Sync** | Read-only. The site, the state of the link, the last accepted payload |
| **License Cloud**, **Support ID**, **SmartBuildOS Company**, **Subscription Tier**, **Licensed Drivers** | Read-only. See [Licensing](#licensing) |
| **Touchpanel Name**, **Touchpanel URL** | The label for the next panel, and the address *Generate Touchpanel URL* returned |
| **Device Poll Interval** | `1m`, `5m` (default), `15m`, `30m` |
| **Discover Network Devices**, **Network Scan**, **Last Network Scan** | Both off by default. Scan intervals `1h`, `6h`, `12h`, `24h` |
| **Non Control4 Devices** | Hosts to ping |
| **Devices Offline**, **Last Device Change** | Read-only. How many monitored devices are down, and the last one to change |
| **Director Reloads**, **Last Reload** | Read-only. The reload count, and the last start with its kind |
| **Agent Contract**, **Agent Configuration Version**, **Monitoring State**, **Agent Version**, **Pairing State**, **Cloud Connection State**, **Agent License State** | Read-only summary. **Agent License State** repeats **License Cloud** |
| **System Startups Today**, **System Startups Lifetime**, **Controller Reboots Observed Today**, **Controller Reboots Observed Lifetime**, **Last Startup Classification**, **Last Startup Confidence** | Read-only. The startup counters, and how the last start was read |
| **Last Report Status**, **Last Report At**, **Service Mode Expires At** | Read-only. The last report request; `Inactive`, or when service mode ends |
| **Execution Controller Identity**, **Primary Controller Identity**, **Effective Service Profile ID**, **Effective Service Profile Version** | Read-only. The controller the Agent runs on. The other three read `Not reported` or `Not assigned` in this build |
| **Startup Monitoring**, **Notification Policy**, **Startup Count Basis**, **Startup Threshold**, **Stabilization Delay**, **Service Mode Duration**, **Report Schedule**, **Recipient Profile**, **Auto-update Preference** | Read-only. Set in SmartBuildOS. The Agent accepts a settings document only whole: an unknown or out-of-range field refuses all of it, and an older version never replaces a newer one; **Agent Configuration Version** shows the version in force, or a refusal. Defaults: `On`, `default-escalation`, `system-startups`, `3`, `120 seconds`, `60 minutes`, `Not scheduled`, `Not configured`, `notify` |
| **Alert Email**, **Email on Director Reload**, **Email on Device Offline**, **Email on Low Battery**, **Email on Sync Failure** | The address and the four switches (all `Off` by default) passed to SmartBuildOS |
| **Last Project Change**, **Zigbee Events** | Read-only. Filled from Director's own notices; see [What is not claimed](#what-is-not-claimed) |
| **Programming**, **Clock Offset** | Read-only. Event attachments, programming lines and disabled lines, counted daily; the controller clock against SmartBuildOS's, measured on every answer |
| **Heartbeat Interval** | `30s` to `6h`, default `1m`. SmartBuildOS can set the check-in time itself (30 seconds to 1 hour), which then replaces this |
| **Full Sync Interval** | `6h`, `12h`, `24h` (default) |
| **Driver Status**, **Driver Version**, **Log Level**, **Log Mode** | Status and version are read-only. Logging is `3 - Info` and `Off` by default |

## Actions

| Action | What it does |
| --- | --- |
| Print SmartBuildOS Drivers | Lists the drivers registered with this Agent in the Lua output: SKU, version, device, last seen |
| Refresh Entitlements Now | Fetches the licences now. The move after a purchase or a transfer |
| Print Entitlements | Prints the Support ID, when licences were fetched, and each SKU's status |
| Test Connection | Sends a one-off test payload; **Connection Status** shows the result |
| Poll Devices Now, Scan Network Now | Poll device state, or run a network scan, outside the timer |
| Send Full Sync, Refresh Inventory | Send a complete snapshot now |
| Send Heartbeat Now, Refresh Status | Send a heartbeat now |
| Report Diagnostics | Prints what Director returns for this project, and sends it. Run it when the device list looks wrong |
| Report Telemetry Survey | Surveys rooms, room and device variables and programming. Considerably more work than a poll; never run on a timer |
| Probe Capabilities, Camera Read-Only Probe | Run the capability probe and send it. It needs a paired Agent to upload |
| Generate Touchpanel URL | Makes a read-only status page (what is playing, temperatures, system health) for the panel named in **Touchpanel Name**, for example `Kitchen T4`. Paste **Touchpanel URL** into a Web View driver. Each run makes a new address and leaves earlier panels working |
| Generate System Report, Send System Report | Record a report request with SmartBuildOS. **Last Report Status** ends at `request-recorded` |
| Send Test Notification | Fires *Service Update* with a test text |
| Enter Service Mode, Exit Service Mode | Start and end service mode |
| Update Drivers, Check for Updates | Update the installed SmartBuildOS drivers now, even with automatic updates off, from the chosen **Update Source** and **Update Channel**. Only drivers on the Agent's built-in list that are already in the project are touched |
| Unpair | Forgets the pairing. See [Setup](#updating-and-unpairing) |

## Troubleshooting

Set **Log Mode** to `Print` and **Log Level** to `4 - Debug` to see each
request in the Lua output. **Log Mode** returns to `Off` by itself after three
hours.

| Connection Status | Meaning |
| --- | --- |
| `Not paired` | No code has been redeemed, or the Agent was unpaired |
| `Unreachable` | No answer: DNS, TLS or routing. Check the controller's internet access |
| `HTTP 401` | The device token was revoked. Unpair and pair again |
| `HTTP 404` | The property no longer resolves. Confirm it in SmartBuildOS |
| `HTTP` and another number | SmartBuildOS refused the payload. Turn logging on to read its reason |
| `Pairing failed - code is invalid or expired` | Generate a fresh code in SmartBuildOS |
| `Pairing failed -` and a reason or an HTTP number | SmartBuildOS refused the enrolment. Act on the reason it gives |
| `Pairing failed - unexpected response` | SmartBuildOS accepted the code but returned no token. A server-side problem |
| `Pairing failed - SmartBuildOS unreachable` | No answer. Check internet access and enter the code again |
| `Pairing pending - enter the code again in a minute` | SmartBuildOS is still processing this enrolment |
| `Could not request a code -` ... | The account-number request failed: an HTTP number, or unreachable. `Enter your account number first` means a verification code was typed with no account number |

| License Cloud | Meaning |
| --- | --- |
| `Not paired - drivers run in legacy mode` | Pair the Agent. Drivers run and show *Not Linked* |
| `Not yet validated - drivers run in legacy mode` | Paired, no licences fetched yet. Run *Refresh Entitlements Now* |
| `OK -` a count and a time | Licences fetched and current |
| `Offline - riding grace until` a date | No fetch for over a week. Drivers show *Licensed / Grace* |
| `Offline too long - cloud validation required` | No fetch for over ten days. Restore the connection |
| ... `(unsigned cache - re-pair to enable signing)` | This pairing predates signed licences. It works; pairing again adds signing |

**Driver Status** reads `Online` after a normal start. `DRIVER DISABLED` means
the controller's OS is older than 3.3.1.
`Pairing backup unusable - re-pair needed` means the backup could not be read
after an update: pair again. `Full sync failed:` means reading the project
failed before anything was sent: run *Report Diagnostics*.

If a driver stays on *Checking...*, run *Print SmartBuildOS Drivers* on the
Agent: a driver that is not listed has not reached it. *Print Entitlements*
shows what SmartBuildOS issued per SKU.

## What is not claimed

- **Director's own notices.** The Agent has code to act within seconds on
  Director's device, project, programming, Zigbee, shutdown and OS-update
  notices. In this build it does not register for them at start. So device
  changes are found by the poll, at **Device Poll Interval**;
  *Project Changed*, *Programming Changed* and *OS Update Started* do not
  fire; **Last Project Change** and **Zigbee Events** keep their starting
  values; and no shutdown is recorded, so every reload reads as `unexpected`
  and fires *Unexpected Restart*.
- **The reload path.** *Director Reloaded*, *Unexpected Restart* and the
  reload report need a controller restart, and have not been seen on a
  controller with this build.
- **Reports.** *Generate System Report* and *Send System Report* record a
  request. The Agent does not say a report was generated or sent.
- **Primary controller.** A changed boot identity is reported as a reboot of
  the controller the Agent runs on, never of the primary controller: the
  Agent has no verified primary to compare with.
- **Remote commands** to keypads, lights, thermostats, scenes, locks, garage
  doors and security panels follow Control4's published protocols and have
  not been confirmed on hardware. Scene activation is the least certain.
- **Enforcement** is off unless SmartBuildOS turns it on for a driver.
- **Controller load and memory** are sent only where the controller lets a
  driver read them.
- **On the bench** (OS 4.3, 10 November 2026) the Agent was updated in place,
  read `Connected`, handed tier and company to every driver, and
  *Refresh Entitlements Now* was run. Its commands were not exercised there.
