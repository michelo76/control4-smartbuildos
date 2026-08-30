# SmartBuildOS Mode Button

One Navigator Experience button per mode, driven entirely by the SmartBuildOS
Mode Composer manager in the same project.

## Setup

1. Make sure **SmartBuildOS Mode Composer** is in the project and has modes
   configured.
1. Add one **SmartBuildOS Mode Button** instance per mode you want on screen.
1. In the button's properties, pick the mode from the **Mode** list (the list is
   fetched from the manager automatically).
1. In Composer's room Navigator settings, place the button on the desired
   experience menu (Comfort / Security / Listen / Watch / Service).

The button renders the mode's icon, lights up while the mode is active or
counting down, and renames itself to the mode's name (turn **Rename With Mode**
off to keep your own name — dealer renames are never overwritten).

Tapping the button asks the manager to activate the mode. Modes guarded by
hold-to-confirm ask for a second tap within 10 seconds. Tapping the active
Lifestyle mode's button exits it and restores what it captured.

## Troubleshooting

- **Mode list is "-"** — the manager wasn't found. Add SmartBuildOS Mode
  Composer, then run *Refresh From Mode Manager*.
- **Icon never lights** — check the mode is actually activating (manager's Print
  History), then *Print Diagnostics* here.
- No license configuration exists on this driver: Mode Buttons inherit the
  manager's SmartBuildOS entitlement.
