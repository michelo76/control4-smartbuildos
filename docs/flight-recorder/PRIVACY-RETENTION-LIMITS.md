# Flight Recorder — privacy, retention, resource limits

## What is recorded

Only configured sources: selected device/room variables (by name, resolved
to ids on the controller), selected SmartBuildOS events, and what Composer
programming explicitly records through the driver's commands. Nothing else.
Initial reads are labelled `initial`; the previous value of a source is
unknown until its first change after that read.

## What is never recorded

- Variables whose name contains USERCODE, ACCESSCODE, PINCODE, PASSCODE,
  PASSWORD, PASSWD, TOKEN, SECRET, APIKEY, DISARMCODE, ARMCODE, KEYCODE,
  LOCKCODE, CREDENTIAL (fixed list, not overridable; refused at configuration
  time on both sides).
- Variables matching the configuration's exclusion patterns (`SCENE_*`).
- The driver's own variables (self is never a source).
- String variable values when `privacy.string_values = exclude`.

## Redaction

On the controller (`sbos.envelope.redact`): sensitive keys (pin, code, key,
auth, sig, password, token, secret, …code, …key, cookie, bearer) → `[redacted]`;
JWT-shaped, long-hex and long-base64 values → `[redacted]`; strings cut at 512
characters; depth ≤ 4, ≤ 40 keys (cuts mark `quality = partial`). On the
platform: the same rules again (`validateEnvelope`), plus the Studio telemetry
redaction boundary on every read and on snapshots. Programmer-supplied text
and string variables carry `quality = unreviewed_text` so Studio flags them.

Composer programming text is a service record: do not put codes or personal
details into trace messages.

## Access

Studio: `monitoring:view` reads; `monitoring:manage` configures, pauses,
resumes and requests snapshots; `monitoring:edit` writes notes;
`monitoring:export` downloads snapshots and exports CSV/JSON (audited:
`control4.flight_recorder_exported`, `control4.flight_recorder_snapshot_downloaded`).
Homeowner (portal) access is NOT granted: no portal route reads these tables.

## Retention (defaults, platform)

| Data | Default | Where |
| --- | --- | --- |
| Events | 30 days from receipt | `flight_recorder_retention(events_days)` |
| Traces and steps | 90 days | `traces_days` |
| Snapshots | 30 days (`expires_at`) | `snapshots_days`; objects removed by `scripts/flight-recorder-retention.mjs` |
| Bookmarks | with their event | same function |
| Gaps | with events | same function |

The function is not scheduled by the migration; the owner adds the pg_cron
line (commented in the migration) and runs the object-removal script.

Storage: one event row ≈ 0.5–1.5 KB. A house with 64 sources at the default
120 events/min ceiling could write ~170k rows/day at the ceiling; realistic
lighting/contact selections produce a few hundred to a few thousand a day.
Indexes: (system, observed_at), (system, correlation_id), (system, device_id,
observed_at), (system, room_id, observed_at), (system, event_type,
observed_at), received_at. No payload index.

## Controller limits

| Limit | Default | Ceiling | Where |
| --- | --- | --- | --- |
| Sources | 64 | 200 | config `budgets.max_sources` |
| Events / minute | 120 | 600 | config `budgets.events_per_minute`; beyond it observations are DROPPED and counted, one `recorder.budget_exceeded` per minute |
| Debounce / coalesce | 0 | 60 s | per source |
| Module stage | 300 events | — | `moduleclient.MAX_STAGED` |
| Agent queue | 2,000 events / 512 KB | — | `eventqueue` (platform may lower) |
| Upload batch | 100 | — | |
| Trace message | 400 chars | — | |
| Active traces | 16 | — | trace timeout 10 min |
| Snapshot document | 64 KB (driver) / 256 KB (Agent, platform) | — | 200 observations, 100 recent events |
| Timers | ≤ 2 per debounced/coalesced source + a fixed handful | — | bounded by max_sources |

Coalescing: after an event, further changes within `coalesce_ms` are gathered
into ONE event (`coalesced = n`, previous = the value before the window,
value = the latest). Debounce: the timer restarts on each change; the last
value wins. `min_change` compares against the last EMITTED value.
