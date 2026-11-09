# SmartBuildOS Variable Inspector

Composer Pro's variable view on a phone or touch screen, without a Pro
session: every device in the project, the variables of the one you tap (live
while it is open), a watch list that keeps a short history per variable and
raises a Composer event on change, and a Dealer-PIN-guarded **Set**.

Requires the SmartBuildOS Agent (`smartbuildos.c4z`) paired to a SmartBuildOS
system; it is the licensing authority (SKU `SBOS_VARIABLE_INSPECTOR`).
**License Status** shows this driver's standing. Reading never depends on the
licence; a definitive denial with enforcement on makes the inspector read-only.

## Setup

1. Install and pair the SmartBuildOS Agent (Composer → Agents).
1. Add this driver (one per project). It adds a **Variable Inspector** tile to
   Navigator (hide it from rooms the customer uses; it is a dealer tool).
1. Set a **Dealer PIN**. Without one the page is read-only.
1. **App Data Relay** should read `Listening :47823`. If the page cannot load
   data, set **App Relay Address** to the controller's LAN address and run
   **Re-publish App URL**, then close and reopen the tile (Navigator does not
   change the URL of an open web view).

## Behaviour

- **One open device.** Opening a device registers listeners for its variables
  and releases the previous device's. Watched variables stay registered
  whatever is open.
- **Watch list.** Up to 64 variables, persisted across restarts; each keeps
  the newest **History Size** changes (50–200) in memory and raises *Watched
  Variable Changed* with `LAST_CHANGE_*` variables set.
- **Masking.** Variables whose name carries a credential fragment (USER CODE,
  PIN CODE, PASSWORD, TOKEN, SECRET, API KEY, …) are shown masked and can
  neither be watched nor written. Not overridable.
- **Set.** Sends the value to Director with `C4:SetDeviceVariable` and says
  so; it never claims the value took. The page reads the device back right
  after. Refusals are named: PIN missing, read-only mode, read-only variable,
  credential-named, unknown variable, Director error. Each fires *Set Refused*.
- **Read-only mode** when the licence is enforced against the driver or no
  Dealer PIN is set: watch, unwatch and set are refused; reading works.

## What is NOT claimed

Setting another device's variable is documented in DriverWorks but has not
been measured on a bench by this driver yet; the result message says "sent",
and the read-back is the proof. Some drivers re-assert their variables and
will overwrite a set value at once.

## Actions

| Action | What it does |
| --- | --- |
| Print Variables For Inspect Device | Every variable of the device in **Inspect Device ID** to the Lua output |
| Print Watch List | The watch list with the recent history of each |
| Clear History | Empty every history ring |
| Re-publish App URL | Push the web-view URL to Navigator again |
| Register With Agent Now / Refresh Status | Licence and status refresh |

## Programming

- Commands: **Watch Variable** (DEVICE, VARIABLE name), **Unwatch Variable**.
- Events: *Watched Variable Changed*, *Value Set From Page*, *Set Refused*.
- Conditional: *Inspector is read-only*.
- Variables: `WATCHED_COUNT`, `LAST_CHANGE`, `LAST_CHANGE_DEVICE`,
  `LAST_CHANGE_VARIABLE`, `LAST_CHANGE_VALUE`, `RELAY_STATUS`.

## Privacy

The relay serves JSON only to a page that carries the minted token, on the
LAN. The Dealer PIN travels only in the body of a Set request and is never
echoed or stored anywhere but the Composer property. Credential-named
variables are masked everywhere, including the Lua output.
