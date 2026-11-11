# SmartBuildOS Mode Button

Puts one mode of SmartBuildOS Mode Composer on the Control4 touchscreens and in
the Control4 app, as a button in a room's Navigator. The button shows the
mode's icon, lights while the mode is active, and a tap asks Mode Composer to
activate it. Add one Mode Button for each mode you want on screen.

It needs **SmartBuildOS Mode Composer** in the same project and does nothing
without it. The button holds no mode settings and makes no decisions: the
devices, the countdown, the confirmation and the priorities all belong to Mode
Composer, and its manual describes them. The button has no licence settings of
its own; it is covered by Mode Composer's licence. Control4 OS 3.3.2 or newer.

## What it is for

| You want | Use |
| --- | --- |
| A mode on a touchscreen or in the app | One Mode Button with **Mode** set to that mode |
| To see at a glance whether Movie is on | The button's icon, lit while the mode is active |
| Movie on and off from one button | A tap on the active Lifestyle mode's button ends it |
| Your own programming when the button is tapped | The event *Pressed* |

## Setup

<!-- walkthrough: Put a mode on screen -->
1. Make sure SmartBuildOS Mode Composer is in the project and has the mode you
   want.
1. Add a SmartBuildOS Mode Button. **Mode Manager** reads `Found` with Mode
   Composer's device number.
1. Choose the mode in **Mode**. The list comes from Mode Composer.
   **Driver Status** now shows the mode's name, with `(active)` after it while
   the mode is active.
1. In Composer's Navigator settings for each room, show the button on the menu
   where it belongs, as for any other experience button.
1. Tap it on a screen and watch **Driver Status** and Mode Composer's
   **Presence Mode** or **Lifestyle Mode**.

## How it works with Mode Composer

The button finds Mode Composer in the project by its driver file,
`smartbuildos-mode-composer.c4z`, with no connection to make. If it is not
there yet, the button looks again every 30 seconds. Mode Composer then sends
every button the list of modes, with each one's name, icon and state, and sends
it again whenever a mode changes. The button remembers its mode by the mode's
internal id.

| The mode is | A tap |
| --- | --- |
| a Presence mode that is not active | activates it |
| a Presence mode that is already active | does nothing |
| a Lifestyle mode that is not active | activates it, on top of the Presence mode |
| the active Lifestyle mode | ends it; Mode Composer puts its `restore` devices back |
| guarded by Mode Composer's **Hold To Confirm Seconds** | the first tap only asks, and the button lights; a second tap within 10 seconds activates |
| set with a **Departure Countdown Seconds** | starts the countdown, and the button lights at once. A second tap starts the countdown again; it does not cancel |

**Icon.** The icon comes from the type the mode was created with in Mode
Composer: Home, Away, Vacation, Sleep, Movie, Party, Morning or Night. A custom
mode gets a general icon. Each has a lit and an unlit version.

**Name.** With **Rename With Mode** on `Yes`, the button takes the mode's name,
so Navigator shows "Movie" and not "Mode Button". It only renames itself while
it still has its install name or a name it gave itself. A name you typed is
never replaced.

## Examples

**Movie in the theatre.** Add a Mode Button, set **Mode** to `Movie` and show
it in the theatre's Navigator. A tap activates Movie: Mode Composer sends the
mode's devices and fires its *Movie Activated* event, and the icon lights. A
second tap ends Movie, and the lights Mode Composer was told to `restore` go
back to where they were.

**Vacation with two taps.** A Vacation mode created in Mode Composer starts
with **Hold To Confirm Seconds** at 3. The first tap on its button lights the
icon and Mode Composer asks the Control4 screens to show
`Tap Vacation again to confirm`. Tap again within 10 seconds and Vacation is
activated. Leave it, and after 10 seconds the icon goes dark and nothing has
changed.

**Programming on a tap.** *Pressed* fires on every tap, before Mode Composer is
asked, and also when the tap ends up doing nothing. Use it for something that
belongs to the tap itself. For "the house is now in Away", program Mode
Composer's own event *Away Activated* instead.

## Programming, properties and actions

The driver has one event, *Pressed*, and no commands, variables or
conditionals. The mode's state is in Mode Composer's variables.

| Property | What it shows or sets |
| --- | --- |
| **Driver Status** | See the table below |
| **Driver Version** | The installed version |
| **Mode** | The mode this button shows and activates |
| **Mode Manager** | Whether Mode Composer was found |
| **Rename With Mode** | `Yes` (default) or `No` |
| **Log Level**, **Log Mode** | Diagnostic logging |

| Action | What it does |
| --- | --- |
| *Refresh From Mode Manager* | Looks for Mode Composer again and asks it for the modes |
| *Print Diagnostics* | Version, Mode Composer's device number, the assigned mode, how many modes are known and the icon shown, in the Lua tab |

## Reading the status

| You see | Meaning | What to do |
| --- | --- | --- |
| **Mode Manager** `Searching...` | The button has not looked yet | Wait a moment |
| **Mode Manager** `Not found - add SmartBuildOS Mode Composer to the project` | No Mode Composer in the project | Add it. The button finds it within 30 seconds, or run *Refresh From Mode Manager* |
| **Mode** lists only `-` | No answer from Mode Composer yet, or it has no modes | Create a mode there, then *Refresh From Mode Manager* |
| **Driver Status** `Pick a mode in Properties` | No mode chosen | Set **Mode** |
| **Driver Status** `Assigned mode is gone - pick another` | The mode was deleted in Mode Composer | Choose another in **Mode** |
| **Driver Status** a mode's name | That mode is assigned and not active | |
| **Driver Status** the name and `(active)` | The mode is active | |
| The icon never lights | The mode is not becoming active | Mode Composer's *Print History* shows what happened to the request; then *Print Diagnostics* here |

## Limits

- One button is one mode. It cannot activate anything by itself.
- If Mode Composer is removed from the project and added again, run
  *Refresh From Mode Manager* on each button, and choose its mode again if
  **Driver Status** says the mode is gone.
- The driver file holds seven more icons (lock, shield, energy, cleaning, work,
  dinner, guest). Mode Composer has no setting to choose them in this release.
- A countdown cannot be cancelled from the button. Use a keypad, or Mode
  Composer's *Cancel Transition* action.
- This manual describes what the code does. It does not claim a bench
  confirmation.
