# Bond Keypad

One instance per Bond **Sidekick** remote (SKN-386, Mate Pro and friends). Add
it with the Gateway's **Auto Configure Bond Devices** action, or bind its **Bond
Keypad** connection to the Bond Bridge Gateway manually. To pair a brand-new
Sidekick with the Bond first, run the Gateway's **Learn New Sidekick** action
and press any key on it.

Key presses arrive over the Bond's push protocol — that is the only way the Bond
reports them — so keypad response is push response. If the Gateway's **Push
Status** is not "Delivering", Sidekick keys cannot reach Control4.

## What a press does

Each key (up to 8) gives you three surfaces:

- **Events** — `Button N - Tap / Double Tap / Hold Start / Hold End` for
  Composer programming.
- **Button Links** (Connections) — per key: a **Tap Link** and **Double Tap
  Link** that click on press, and a **Hold Link** that pushes on hold-start and
  releases on hold-end, so a held Sidekick key can **ramp a bound Control4
  dimmer** exactly like a real keypad button.
- **Variables** — `LAST_BUTTON`, `LAST_EVENT`, `LAST_HOLD_MS`, for handling any
  key in one piece of programming.

## Battery

The Bond reports Sidekick battery in coarse bands. The **Battery** property
shows it, and the **Battery OK / Low / Critical** events fire on transitions —
put a notification on Battery Low and the service call never happens.

## Notes

- The Sidekick keeps doing its own Bond-side job (its channel links to shades
  etc.) regardless of Control4 — this driver adds Control4 to the audience, it
  does not take the keypad over.
- Sidekicks are RF remotes: there are no LEDs to track and no way to press a key
  from software.
