# SmartBuildOS Dealer Settings

Twelve named, typed settings that Composer programming reads as variables
and that a dealer edits from a Navigator tile behind a PIN, without a
Composer Pro session. The settings you tune on every service call (motion
timeouts, dim levels, delays, modes) stop being numbers buried in programming
and become values with a name.

Requires the SmartBuildOS Agent (`smartbuildos.c4z`) paired to a SmartBuildOS
system. The Agent is the licensing authority (SKU `SBOS_DEALER_PANEL`):
**License Status** shows this driver's standing. A definitive licence denial
with enforcement on makes the panel read-only; uncertainty never does.

## Setup

1. Add this driver to a room (one per project is usual). It appears as a
   **Dealer Settings** tile in Navigator.
1. For each setting you want, fill **Setting N Name**, **Setting N Type** and
   **Setting N Options**:
   - **Number** — Options is the allowed range, `0..100` (default when
     empty).
   - **Toggle** — On or Off.
   - **Text** — free text up to 200 characters.
   - **Choice** — Options is the list, `Low, Medium, High`.
   A slot with an empty Name is unused.
1. Set a **Dealer PIN**. With no PIN the tile is read-only; nothing in a
   home can be changed without a secret.
1. Reference the variables in programming: `SETTING_N` (text form),
   `SETTING_N_NUMBER` (the number, 1/0 for a toggle) and `SETTING_N_NAME`.
   Use the conditional **Setting N value is …** for comparisons.

## One truth

The Composer properties **Setting N Value** hold the values. A write from
the tile or from the *Set Setting* command lands in that property; the
driver rebuilds from the properties; the variables, the event and the tile
follow. Composer and the tile never disagree.

## Behaviour

- A value that does not fit its type is refused with a reason (out of
  range, not one of the choices, too long) and the previous value stays.
  Nothing is clamped or truncated silently.
- Every change fires **Setting Changed**, with `CHANGED_SETTING` and
  `CHANGED_VALUE` naming it, whether it came from the tile, from
  programming or from a Composer edit.
- Five wrong PINs lock writes for one minute and fire **Panel Locked**.
  *Reset PIN Lock* clears it.
- The tile reaches the driver over the controller's LAN (port 47822,
  Atmosphere's proven path) with a per-install token in the tile URL, and
  falls back to the Navigator JavaScript API. **App Data Relay** shows the
  address in use. The driver keeps only an address its own relay has
  answered on, so another Control4 device on the network is never taken
  for the controller; set **App Relay Address** if the status says the
  address is unknown or that there was no answer on it.

## What is NOT claimed

The driver does not change other devices' properties. It holds values; your
programming applies them. Navigator does not change the URL of an open
tile: after a relay change, close and reopen the tile.

## Actions

| Action | What it does |
| --- | --- |
| Print Settings | Every configured setting, its value and any refusal |
| Reload Web View URL | Re-publish the tile URL (after an address change) |
| Reset PIN Lock | Clear a lock after wrong PINs |
| Register With Agent Now | Re-ask the Agent for the licence |
| Refresh Status | Rebuild from the properties and repaint |

## Programming

- **Set Setting** (NAME, VALUE) and **Toggle Setting** (NAME).
- Events: *Setting Changed*, *Setting Change Refused*, *Panel Locked*.
- Conditionals: *Setting N value is …* (per slot), *Dealer panel accepts
  writes*.
- Variables: `SETTING_1..12`, `SETTING_1..12_NUMBER`, `SETTING_1..12_NAME`,
  `CHANGED_SETTING`, `CHANGED_VALUE`, `SETTINGS_CONFIGURED`, `PANEL_STATUS`.

## Privacy

The Dealer PIN is a password property, never shown, logged or sent in a
response. The tile keeps an entered PIN in memory only, for that session.
Settings are plain values you named; do not store codes or personal details
in Text settings.
