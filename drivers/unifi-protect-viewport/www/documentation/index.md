# UniFi Protect Viewport

Lets Control4 programming choose what a UniFi Protect Viewport shows: set a
live view, step through the views, or show one for a few seconds and then put
back whatever was up.

One instance per Protect Viewport, bound to the UniFi Protect Gateway (SBOS).
The Gateway owns the console connection; this driver holds no credentials.
Available views are discovered from the console.

## What it is for

| You want | Use |
| --- | --- |
| The front door on the kitchen screen when the bell rings, then back to what was showing | `Show View Temporarily` |
| A fixed view with a scene: the perimeter at night, all cameras by day | `Set Live View` |
| A button that steps through the views | `Next Live View`, `Previous Live View` |
| To know what the screen shows | `CURRENT_LIVE_VIEW`, *View Changed* |
| To know the Viewport dropped off | *Viewport Offline*, or the conditional *Viewport online status* |

## Setup

<!-- walkthrough: Add a Viewport -->
1. Install the UniFi Protect Gateway (SBOS) first and confirm it shows
   Connected.
1. Run the Gateway's *Auto Provision Protect Devices* action, which adds and
   binds one instance per Viewport. Or add one instance by hand and, in
   Connections, bind its **Protect Viewport** connection to the Gateway
   connection named after the Viewport.
1. Check the Properties tab. **Gateway Link** reads `OK - identified as`
   followed by the Viewport's name, **Viewport** shows that name, **Viewport
   State** reads `CONNECTED`, and the device is renamed after the Viewport.
1. Read **Available Views**. It lists the live views that exist in Protect,
   by name. Make the ones you need in Protect; they appear after the
   Gateway's next sync.
1. On the Actions tab press *Next Live View*. **Last Control** reads
   `viewer_liveview: ok` with the time, and the screen should change.

## What programming gets

| Command | Parameters | What it does |
| --- | --- | --- |
| `Set Live View` | `View` | Shows that live view. `View` is a name from **Available Views** (capitals do not matter) or the view's id |
| `Next Live View`, `Previous Live View` | none | Steps one view along the **Available Views** list from the current one, wrapping round at the ends |
| `Show View Temporarily` | `View`, `Seconds` | Shows `View`, then after `Seconds` (20 if left empty) puts back the view that was showing |

Commands go to the console through the Gateway, once each. **Last Control**
shows the newest one: `sent`, then `ok`, or `FAILED` with the reason.

| Event | Fires when |
| --- | --- |
| *View Changed* | A Gateway sync reports a different view from the last one |
| *Viewport Online* | A Gateway sync sees the Viewport connected again |
| *Viewport Offline* | A Gateway sync sees it in any other state |

- Conditional: *Viewport online status* is Online or Offline
  (`VIEWPORT_ONLINE`).
- Variable: `CURRENT_LIVE_VIEW`, the name of the view the console reports.

**Current View**, `CURRENT_LIVE_VIEW` and *View Changed* are read at each
Gateway sync (its **Device Poll Interval**, 1 minute by default), so they
follow a command by up to that long.

### Show View Temporarily, exactly

- The view to go back to is taken once, when the first temporary show starts.
- A second `Show View Temporarily` before the time is up shows the new view,
  starts the clock again, and still goes back to the **original** view.
- `Set Live View`, `Next Live View` and `Previous Live View` cancel a pending
  return: the view you chose stays.

## Worked example

### The doorbell on the screen for 20 seconds

<!-- walkthrough: Show the front door when the bell rings -->
1. In Protect, make a live view named Front Door. After the Gateway's next
   sync, **Available Views** lists it.
1. In Programming, pick the UniFi Protect Camera driver's event *Doorbell
   Ring* on the doorbell.
1. Add this driver's command `Show View Temporarily`. Type `Front Door` in
   `View` and `20` in `Seconds`.
1. Ring the bell. A Viewport showing All Cameras switches to Front Door and,
   20 seconds later, back to All Cameras.
1. Ring twice. A second ring inside the 20 seconds starts the 20 seconds
   again, and the screen still returns to All Cameras.

## Properties and actions

| Property | What it is |
| --- | --- |
| **Viewport**, **Viewport State** | Which Protect Viewport this is, and `CONNECTED`, `CONNECTING`, `DISCONNECTED` or `UNKNOWN` |
| **Gateway Link** | `Asked gateway at … - waiting for a reply` until the Gateway answers, then `OK - identified as …`. If it never changes, the connection is not bound or the Gateway is missing |
| **Current View**, **Available Views** | What the console says is showing, and the views it has, as of the last sync |
| **Last Control** | The newest command and its outcome |

| Action | What it does |
| --- | --- |
| Print Diagnostics To Log | Gateway found or not, identity, state, current view, each view with its id |
| Next Live View, Previous Live View | The same as the commands |
| Refresh Viewport Info | Asks the Gateway again which Viewport this is, and picks up a new name |
| Forget Viewport | Clears the identity, the view list and any pending return, then asks again |

The driver names itself after the Viewport while the device still has its
install name or the name the driver gave it. A name you typed is kept.

## What is not claimed

- **Nothing in Navigator.** The Viewport is programming only.
- The driver does not create or edit live views. That is done in Protect.
- The view to go back to is the one the Gateway last reported, which can be
  up to one Gateway poll old. A view set just before a temporary show may
  not be the one that comes back, and a new temporary show soon after a
  return can take the temporary view itself as the one to go back to.
- The pending return lives in memory. A driver or controller restart during
  the wait drops it, and the temporary view stays.
- If the driver has not yet learned the current view, a temporary show has
  nothing to go back to and the view stays.
- A `View` the console does not have is sent as typed, and **Last Control**
  shows the console's answer.
- Viewports and live views need a Protect version that has them on its
  official API. On an older console the Gateway finds none.
- A rename in Protect is picked up at the next *Refresh Viewport Info* or
  driver restart, not by itself.
