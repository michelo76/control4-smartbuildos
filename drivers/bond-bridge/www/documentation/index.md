# Bond Bridge Gateway

A Bond Bridge is a small hub that sends the same RF and IR signals as the
hand-held remotes of ceiling fans, fireplaces, motorized shades and similar
appliances, so they can be controlled over the network. This driver connects a
Control4 project to one Bond unit (a Bond Bridge, a Bond Bridge Pro, or a
Smart by Bond appliance, which speaks the same local API) and is the parent of
the Bond device drivers, whose manuals call it the Gateway. It owns the
connection, the local token and the list of devices, and it gives each
function of a device its own connection: a ceiling fan with a light gets a fan
connection and a light connection, each served by its own device driver, so
each is its own device in Navigator.

Add one instance per Bond unit. The controller talks to the Bond directly on
the local network, over the Bond's Local API; no cloud service is involved in
control or feedback, and nothing has to be opened to the internet. It needs
Control4 OS 3.2.0 or later.

The driver registers with the SmartBuildOS Agent (`smartbuildos.c4z`) under the
SKU `SBOS_BOND`, and **License Status** shows its standing with the Agent. The
one thing in this driver that consults the licence is *Auto Configure Bond
Devices*: it is refused only when the Agent reports that enforcement is on for
this SKU and the driver is not entitled. Connecting, syncing and device control
do not consult it. The Bond device drivers carry no licence check of their own.

## What it is for

| You want | Use |
| --- | --- |
| The Bond's fans, lights, shades, fireplaces and heaters as Control4 devices, without adding and binding each one by hand | *Auto Configure Bond Devices* |
| To find the Bond without typing an address | **Discovered Bonds** and *Discover Bonds On Network* |
| To pair without the homeowner's Bond Home app | *Fetch Token From Bond* after a power cycle, or **Bond PIN** |
| A scene the homeowner built in the Bond Home app, run from Control4 programming | `Run Bond Scene` |
| A Bond capability that no device driver has a control for | `Run Bond Action` |
| To know when the Bond stops answering | *Bond Offline*, *Bond Online*, and the conditional `BOND_CONNECTED` |
| A change made on the factory remote to show in Navigator at once | **Push Updates**; **Push Status** says whether it is working |
| To pair a new Sidekick remote with the Bond | *Learn New Sidekick* |
| To clear connections left behind by a device deleted from the Bond | *Prune Missing Device Bindings* |

## What you need

- A Bond Bridge, Bond Bridge Pro or Smart by Bond device that the controller
  can reach on the network. The driver uses version 2 of the Bond Local API
  (plain HTTP) and, for push updates, UDP port 30007 on the Bond.
- The devices already set up on the Bond. Remotes are taught to the Bond in the
  Bond Home app; this driver reads what is there.
- The Bond's local token, or a way to get it. See
  [The local token](#the-local-token-three-ways-to-get-it).
- The Bond device drivers loaded on the controller, so *Auto Configure Bond
  Devices* can add them. See [The device drivers](#the-device-drivers).

## Setup

<!-- walkthrough: Connect a Bond and add its devices -->
1. Add this driver to the project, one instance per Bond unit. **Driver
   Status** reads `Online`.
1. Find the Bond. At every start the driver searches the network for six
   seconds and lists each Bond it hears in **Discovered Bonds** as
   `id @ address`. On a new instance the first Bond heard is written into
   **Bond Address** for you. If nothing is heard, or there are several Bonds,
   type the right address into **Bond Address** yourself: an IP address such as
   `192.0.2.50` or a host name. Anything pasted after the host is ignored.
1. Give it the token. Paste the Bond's local token into **Local Token**. The
   field empties itself: that means the token was accepted and stored
   encrypted on the controller. If you do not have the token, use one of the
   other two ways in the next section.
1. Read **Connection Status**. `Connected` means the Bond answered and
   accepted the token. **Bond ID**, **Model** and **Firmware** show what
   answered; **Devices** and **Scenes** show how many it has.
1. On the Actions tab run *Auto Configure Bond Devices* and watch the Lua tab.
   The driver adds the right device driver for every device function that has
   none, binds it and names it after the Bond device.
1. Run *Print Device Bindings To Log*. Every line should end with the id of the
   device driver bound to it. On each device driver, **Gateway Link** reads
   `OK - identified as` followed by the device's name.

### The local token: three ways to get it

The token is the Bond's own key for local control. However it arrives, the
driver stores it encrypted on the controller and never leaves it in a property,
so it is not in a project file that is handed around.

| Way | Steps |
| --- | --- |
| From the app | In the Bond Home app select the Bond, then Settings (the gear), Advanced, Local Token. Paste it into **Local Token**. |
| Power cycle | Unplug the Bond and plug it back in, then run *Fetch Token From Bond* within 10 minutes. The Bond hands out its token in that window. |
| The Bond's PIN | Type the PIN printed on the Bond into **Bond PIN** (the field empties itself), then run *Fetch Token From Bond*. The driver unlocks the Bond with the PIN, reads the token, locks the Bond again and deletes the stored PIN. |

*Fetch Token From Bond* needs **Bond Address** set first. It prints what
happened in the Lua tab: `Token received from the Bond and stored`, or, when
the Bond is locked and no PIN works, the three ways above. *Forget Token*
wipes the stored token and stops push updates.

### What Auto Configure does

*Auto Configure Bond Devices* first reads the Bond again, so devices added
since the last sync are included. Then, for each connection with no device
driver bound to it, it adds one driver at a time, binds it, and two seconds
after the last one renames the new devices. Unless every add failed, it
finishes by renaming every bound device driver to the name of its connection.

- It never deletes anything.
- Run it again after adding devices in the Bond Home app: only the missing
  ones are added.
- If a device driver's file is not on the controller, the Lua tab prints
  `FAILED to add` with the file name to load once through Composer's Driver
  menu; then run the action again.
- If the Bond cannot be read, it only renames the device drivers already
  bound, from the last list it has.
- The final rename applies to every bound device driver, including one you
  renamed by hand. *Auto Rename Bound Drivers* does the same rename on its
  own.

You can also do it by hand: add a device driver, and in Connections bind its
Bond connection (Bond Fan, for example) to that device's connection on this
driver (Master Fan, for example).

## How Bond devices become Control4 devices

The Bond lists, for each device, the actions it accepts. The driver decides
from that list which functions the device has, and creates one connection per
function. A device can match more than one row.

| The Bond lists | Function | Connection class | Device driver |
| --- | --- | --- | --- |
| `SetSpeed` or `IncreaseSpeed`; or a ceiling fan (type `CF`) with `TurnOn` or `TogglePower` | Fan | `SBOS_BOND_FAN` | Bond Fan |
| `Open`, `Close`, `ToggleOpen` or `SetPosition` | Shade | `SBOS_BOND_SHADE` | Bond Shade |
| `SetFlame` or `IncreaseFlame`; or a fireplace (type `FP`) with `TurnOn` or `TogglePower` | Fireplace | `SBOS_BOND_FIREPLACE` | Bond Fireplace |
| `SetHSV` | Color light | `SBOS_BOND_COLOR_LIGHT` | Bond Color Light |
| `TurnLightOn` or `ToggleLight`, and no `SetHSV` | Light | `SBOS_BOND_LIGHT` | Bond Light |
| `SetHeat` or `IncreaseHeat` | Heater | `SBOS_BOND_HEATER` | Bond Heater |
| None of the above, but `TurnOn` or `TogglePower` | Switch | `SBOS_BOND_GENERIC` | Bond Switch |
| A Sidekick remote (reports a number of keys) | Keypad | `SBOS_BOND_KEYPAD` | Bond Keypad |
| A weather sensor (type `weather_sensor`) | Weather | `SBOS_BOND_WEATHER` | Bond Weather |

The first function of a device keeps the device's name; any other gets a
suffix. A fan named Master Fan that also has a light gives two connections,
`Master Fan` and `Master Fan Light`. A device that matches no row gets no
connection; *Print Inventory To Log* still lists it.

Connections are created at sync and are never removed on their own. When a
device is deleted from the Bond, the log warns that its connection has no
device behind it, and *Prune Missing Device Bindings* removes such connections.
It removes the connection, not the device driver that was bound to it.

### The device drivers

| Driver | File | Controls | In Navigator |
| --- | --- | --- | --- |
| Bond Fan | `bond-fan.c4z` | A ceiling fan: power, speed, direction, breeze, timer | A fan with speeds |
| Bond Light | `bond-light.c4z` | The light of a fan or fireplace, or a Bond light on its own | A light; dims where the Bond lists `SetBrightness` |
| Bond Color Light | `bond-color-light.c4z` | A full-color light: level, color, white color temperature | A color light (needs OS 3.3.0) |
| Bond Shade | `bond-shade.c4z` | A motorized shade, awning or screen | A shade; a slider where the Bond lists `SetPosition` |
| Bond Fireplace | `bond-fireplace.c4z` | A fireplace: power, flame level, its own fan | Five tiles |
| Bond Heater | `bond-heater.c4z` | A heater with a heat level and a timer | A heat-only thermostat dial, 0 to 100 |
| Bond Switch | `bond-generic.c4z` | Anything that is only on and off | One tile, plus a relay connection |
| Bond Keypad | `bond-keypad.c4z` | A Sidekick remote's key presses and battery | Nothing: events and button links |
| Bond Weather | `bond-weather.c4z` | A weather sensor's readings and triggers | Nothing: variables, events, outdoor temperature and humidity connections |

Each has its own manual.

## How state is kept up to date

Two paths run side by side, and both are on by default.

- **Push.** With **Push Updates** `On`, the driver subscribes to the Bond's
  push protocol (BPUP, UDP port 30007) and renews the subscription every 50
  seconds. The Bond then sends each state change as it happens, so a fan speed
  changed on the factory remote shows in Navigator without waiting. Sidekick
  key presses arrive only this way.
- **Polling.** Every **Device Poll Interval** (default `1m`) the driver asks
  the Bond whether anything changed: one short request for the devices, and
  one more for Sidekicks and weather sensors when the Bond has them. Only when
  the answer is yes does it read everything again. `Off` stops polling; *Test
  Connection* and *Sync Devices Now* still work.

After every command a device driver sends, the Gateway reads that device's
state back from the Bond and passes it on, rather than assuming the command
worked. A state the device driver already holds is not sent twice.

After a controller restart the last device list is restored from the
controller, and **Last Sync** shows its time followed by `(cached)` until the
first fresh sync.

## Worked examples

### A Bond scene on a keypad button

<!-- walkthrough: Run a Bond scene from Control4 -->
1. Build the scene in the Bond Home app, for example Goodnight.
1. Run *Sync Devices Now*. **Scenes** shows the count.
1. Run *Print Scenes To Log* and read the scene's name in the Lua tab.
1. In Programming, pick the keypad button's event. From this driver's
   commands add `Run Bond Scene` and type the name into `Scene`. Upper and
   lower case do not matter; the scene's id works too.
1. Press the button. The Lua tab prints `Run Bond Scene: 'Goodnight' ran`.

An unknown name sends nothing and prints a line saying so.

### A message when the Bond drops off the network

On this driver's event *Bond Offline*, send your notification. On *Bond
Online*, send the all-clear. Both fire once per change, not on every failed
request. To hold back programming that needs the Bond, wrap it in the
conditional `BOND_CONNECTED`.

### A capability no device driver has a control for

Some fans have separate up and down lights. The Bond Light driver has no
separate control for them. To switch only the up light from programming, use
`Run Bond Action` with `Device` Master Fan, `Action` `TurnUpLightOn`, and
`Argument` left empty.

An action that takes a value gets it in `Argument`, as a number or as JSON.
The Bond's own example for a fan's breeze mode is `Action` `SetBreeze` with
`Argument` `[1, 20, 90]`. The Lua tab prints the result, `ok` or `FAILED`
with the reason.

## Programming reference

- Events: *Bond Online* (the Bond started answering again), *Bond Offline*
  (the Bond stopped answering).
- Conditional: `BOND_CONNECTED`, shown as Bond connection status, `Connected`
  or `Disconnected`.
- Commands:

| Command | Parameters | What it does |
| --- | --- | --- |
| `Run Bond Scene` | `Scene`: the scene's name or id | Runs a scene built in the Bond Home app. Scenes are read at each sync. |
| `Run Bond Action` | `Device`: the Bond device's name or id. `Action`: the action exactly as the Bond spells it. `Argument`: empty, a number, or JSON | Sends one raw action to one device. If the action is not in the device's list, a warning is logged and it is sent anyway. |

This driver has no variables. The device drivers carry the variables and
events for each device.

## Properties

| Property | What it is |
| --- | --- |
| **Bond Address** | IP address or host name of the Bond. Changing it reconnects to the new address. |
| **Local Token** | Where you paste the token. Empties itself once stored. |
| **Bond PIN** | The PIN printed on the Bond, for *Fetch Token From Bond*. Empties itself once stored. |
| **Discovered Bonds** | Bonds heard on the network, as `id @ address`. |
| **Device Poll Interval** | `Off`, `30s`, `1m`, `2m`, `5m` or `15m`. Default `1m`. |
| **Push Updates** | `On` or `Off`. Default `On`. |
| **Driver Status**, **Driver Version** | `Online` once started, and the build that is running. |
| **Connection Status** | See [Reading the status](#reading-the-status). |
| **Bond ID**, **Model**, **Firmware** | What the Bond reported about itself. |
| **Devices**, **Scenes** | How many the last sync found. **Devices** counts Sidekicks and weather sensors too. |
| **Push Status** | See [Reading the status](#reading-the-status). |
| **Last Sync** | When the device list was last read; `Never` before the first. |
| **License Status**, **License Source**, **Subscription Tier**, **SmartBuildOS Company** | What the SmartBuildOS Agent reports for this driver. |
| **Log Level**, **Log Mode** | Logging. **Log Mode** is `Off` by default. |

## Actions

| Action | What it does |
| --- | --- |
| *Test Connection* | Asks the Bond who it is, fills **Bond ID**, **Model** and **Firmware**, and, if a token is stored, syncs to prove the token. |
| *Discover Bonds On Network* | Clears **Discovered Bonds** and searches again for six seconds. |
| *Sync Devices Now* | Reads devices, scenes, Sidekicks and weather sensors now. |
| *Fetch Token From Bond* | Reads the token from the Bond after a power cycle or with the stored PIN. |
| *Auto Configure Bond Devices* | Adds, binds and names a device driver for every connection that has none. |
| *Learn New Sidekick* | Opens the Bond's learn window for 60 seconds. Press any key on the new Sidekick near the Bond, then run *Sync Devices Now* and *Auto Configure Bond Devices*. |
| *Auto Rename Bound Drivers* | Renames every bound device driver to the name of its connection. |
| *Print Inventory To Log* | Each device with its id, type, location, functions and state. |
| *Print Scenes To Log* | Each scene with its id and name. |
| *Print Device Bindings To Log* | Each connection, its device, and what is bound to it. |
| *Prune Missing Device Bindings* | Removes connections whose device is gone from the Bond. Never runs on its own. |
| *Refresh License* | Registers and checks again with the SmartBuildOS Agent. |
| *Forget Token* | Wipes the stored token. |

## Reading the status

**Connection Status**

| It reads | Meaning | What to do |
| --- | --- | --- |
| `Not configured - set the Bond Address and Local Token` | No address or no token yet | Follow [Setup](#setup) |
| `Bond found - paste the Local Token to connect` | The address answers and is a Bond; no token is stored | Give it the token |
| `Connected` | The last exchange with the Bond worked | Nothing |
| `Token rejected - re-paste the Local Token (...)` | The Bond refused the token | Paste the token again, or fetch it again |
| `Bond unreachable - check the Bond Address and that it is on this network` | No answer at all | Check the address, the Bond's power and the network |
| `Bond answered HTTP` and a number | The Bond answered with an error other than a refused token | Run *Sync Devices Now* to read the Bond again |
| `Device list unreadable` | The Bond answered, but not with a device list | Run *Test Connection* |
| `Token forgotten - paste a Local Token to reconnect` | *Forget Token* was run | Give it a token |

A new instance holds a placeholder in **Bond Address**, so **Connection
Status** can read `Bond unreachable` until the search fills in the address or
you type one.

**Push Status**

| It reads | Meaning |
| --- | --- |
| `Off` | **Push Updates** is `Off`, or there is no address and token yet |
| `Waiting` | Subscribed; nothing heard from the Bond yet |
| `Delivering` | The Bond is answering on the push connection |
| `Waiting - no push traffic; polling covers` | Nothing heard from the Bond for more than 130 seconds, or nothing at all since subscribing |
| `Unavailable - polling covers` | The push connection could not be opened |

Polling keeps device state right whatever **Push Status** reads, only slower.
The exception is Sidekick key presses, which need `Delivering`.

**Discovered Bonds**

| It reads | Meaning |
| --- | --- |
| `searching...` | A search is running |
| `id @ address`, one or more | Bonds heard. The driver adds `(setup mode)` when a Bond's announcement carries that flag |
| `none heard - check that the controller and Bond share a network` | The six seconds passed with no answer. Type the address instead |
| `unavailable - no free network binding` | The search could not open its connection. Type the address instead |

The search writes into **Bond Address** only while that still holds the
install placeholder (or is empty) and the driver is not connected. A Gateway
that is configured is never pointed somewhere else by the search.

## Troubleshooting

| You see | Likely cause | Do this |
| --- | --- | --- |
| A device driver's **Gateway Link** stays on `waiting for a reply` | Its connection is not bound, or the Gateway has no device list yet | Run *Sync Devices Now* here, check *Print Device Bindings To Log*, then *Refresh From Gateway* on the device driver |
| *Auto Configure Bond Devices* prints `FAILED to add` | That device driver's file is not on the controller | Load the file named in the message once, then run the action again |
| *Auto Configure Bond Devices* prints `Auto configure unavailable` | The SmartBuildOS Agent reports this driver as not entitled, with enforcement on | Read **License Status** |
| A new device in the Bond Home app is missing | Not synced yet | *Sync Devices Now*, then *Auto Configure Bond Devices* |
| The log warns that a connection has no Bond device behind it | The device was deleted from the Bond | *Prune Missing Device Bindings* |
| Sidekick keys do nothing in Control4 | Push is not delivering | Check **Push Updates** is `On` and **Push Status** reads `Delivering` |
| `Run Bond Scene` prints `no scene` | The name does not match, or scenes were not read yet | *Sync Devices Now*, then *Print Scenes To Log* |
| Behaviour does not match this manual after an update | The controller is running an older copy | Compare **Driver Version** with the build you loaded |

## What is not claimed

- **State is the Bond's own tracking.** Most Bond devices are one-way RF: the
  state shown is what the Bond last transmitted, not a sensor reading. A wall
  switch or remote the Bond does not know about will leave the state wrong
  until the next command. That is a property of the RF system, not of the
  driver. A successful command means the Bond transmitted, not that the
  appliance obeyed.
- **Bond groups and schedules** are not surfaced. Control4 scenes and the
  Scheduler do those jobs. Groups, schedules, remote learning and weather
  sensor thresholds stay in the Bond Home app.
- **No controls** in the device drivers for top-down bottom-up rails, shade
  tilt, or separate up and down lights. `Run Bond Action` can still send those
  actions.
- **Not yet verified on hardware.** The suite is written from Bond's published
  Local API (version 3.0.0 of the specification) and is covered by unit tests;
  the repository holds no bench record for it. In particular the code marks
  the UDP path used for push updates and for the network search as unverified
  on a controller. If push does not deliver, polling carries device state; if
  the search hears nothing, type the address.
- **Plain HTTP.** The Bond's local API does not offer encryption, so the driver
  uses plain HTTP on the local network. A pasted `https://` address is treated
  as `http://`.
- **One Gateway per project** is what the device drivers are written for.
  Each finds the Gateway by its driver file and sends its commands to the
  first one it finds. With two Gateways in one project, commands from devices
  bound to the other one are not carried out.
- **Connection names are fixed** when a connection is first created. Renaming
  a device later in the Bond Home app does not rename its connection or the
  device driver bound to it.
- **Separate from other Bond drivers.** This suite's connections use their own
  classes (the `SBOS_BOND_` names above), so Composer does not offer to bind
  these device drivers to another Bond driver suite's gateway, or the reverse.
