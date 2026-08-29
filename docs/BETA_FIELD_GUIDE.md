# UniFi Protect (SBOS) — Beta Field Guide

Build under test: `20260828.193057` · Reference site: Doerr-Fort-Lauderdale
(OS 4.2.1 / Protect 7.2.105, 3 cameras) · Status: **core verified live,
advanced features awaiting field passes**

## How to run this beta

- **One change at a time.** Test a feature, note the result, move on.
  Half-observed runs cost more than untested features.
- **Evidence beats memory.** For anything odd, capture: the **Driver
  Version** property, the Lua log lines (Print/warn output), and the
  relevant *Print Diagnostics* block. Those three answer 90% of
  questions without a second visit.
- **The log is quiet by design.** Set **Log Level: 4 - Debug** and
  **Log Mode: Print** on the driver under test while testing (it
  self-reverts in 3 hours). PRINT lines always show; info/warn need this.
- **Nothing here can brick a site**: worst case is a driver saying "no"
  in a property. The one caution: siren and relay commands are real —
  warn the household before testing them.

## Scoreboard

### ✅ Verified live (the regression floor — retest after any update)

| Feature | Quick check |
| --- | --- |
| Gateway connect + inventory | Counts populate; Connection Status `Connected` |
| Live video (RTSP default) | Every camera plays in the C4 app |
| Event stream | Event Stream `Connected`; Last Event updates on motion |
| Detections → events/History | Walk-test fires Person/Motion; History logs it |
| Identity handshake + rename | Gateway Link `OK - identified…`; Rename From Camera works |
| Snapshot relay | Camera URL renders a JPEG in a LAN browser |
| Auto-provision add + bind | New device → instance appears, already bound |

### 🔶 Built + bench-tested, needs its field pass

Work through these top-down; each line is one visit-sized test.

1. **Doorbell LCD pack** — needs the Front Door to be a doorbell (its
   **Capabilities** property will list `lcd`). Set Doorbell Message
   "TEST", Duration 30 → shows on the glass, reverts. Then DND, Leave
   Package, Reset. *Record:* Last Control after each.
2. **Arm/disarm round-trip** (needs ≥1 arm profile in Protect) — arm in
   the *Protect app* → within a poll, Gateway Arm Mode updates + `Armed`
   fires. Then Composer **Disarm** → Protect shows disarmed. *Record:*
   Print Arm Profiles output once.
3. **Inbound webhook** — from a LAN machine:
   `curl "http://RELAY_IP:47800/webhook/beta?token=<Webhook Token>"` →
   `ok` + Custom Webhook Received; wrong token → `not found`.
4. **Outbound webhook** — make an Alarm Manager rule with a webhook
   trigger; run **Trigger Protect Webhook** with its ID → rule fires.
5. **Cooldown behavior** — pace in front of a camera ~15 s: History shows
   ONE motion entry; `LAST_MOTION` still updates each pass.
6. **Snapshot notification flow** — pair the *Snapshot Notification*
   event with a push carrying the Camera Snapshot attachment; run **Send
   Snapshot Notification** → phone gets message *with picture*. *This
   also answers whether notification attachments fetch from the relay.*
7. **App thumbnails** — camera LIST view in the C4 app: do tiles show
   stills now (GET_SNAPSHOT_URLS), or names only? Either answer is
   useful data.
8. **Known person** (doorbell with enrolled fingerprint/NFC) — touch →
   Known Person Detected, `LAST_PERSON` = the enrolled name; unenrolled
   finger → Unknown Person Detected.
9. **Offline camera** — pull PoE on one camera → within a poll: Camera
   Offline (child) + Device Offline (gateway) + Offline Devices lists
   it; plug back → Online pair.
10. **Sensors / lights / viewport** — when hardware exists on a site:
    the checklists in TEST_PLAN.md §Gate 3.
11. **SmartBuildOS handoff** — Reporting On → `SBOS_PROTECT_ROSTER` in
    the Connector's log. (Platform ingestion is a separate deliverable.)

### 🐞 Known issues (open)

| # | Issue | Workaround | State |
| --- | --- | --- | --- |
| B-1 | **Auto-provision doesn't rename instances.** Three fixes attempted (documented in memory/commits); Director's id handoff is still not renaming what Composer shows. | *Rename From Camera* per instance | Parked by decision 08-28; next probe = the `added as device N (…)` parenthetical, which reveals what ids Director actually returns |
| B-2 | **New Composer events may not appear after Update Driver** until Composer is fully restarted (UI cache). If a restart doesn't surface them, re-add is the fallback — report it first. | Restart Composer | Watching |
| B-3 | Relay Address auto-detect unproven on multi-interface controllers. | Set the controller IP explicitly | Watching |

### 📋 Report template (paste this back)

```
Build (Driver Version property):
Driver + instance:
What I did:
What happened:
What I expected:
Log lines (Print/Debug):
Print Diagnostics block (if relevant):
```

## Rollback

Every build is a git commit; the Driver Version property maps to it.
To roll back: check out the older commit → `make build` → Update Driver.
Instances, bindings and programming survive — only the driver code moves.

## Graduation criteria (beta → 1.0)

- [ ] Every 🔶 item verified on ≥1 real site
- [ ] B-1 fixed or formally documented as manual-step
- [ ] One full site installed start-to-finish by the 10-minute guide
      without touching documentation beyond it
- [ ] Two weeks of the reference site running with zero silent failures
      (everything that went wrong said so in a property or the log)
