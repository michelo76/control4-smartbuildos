# Guest Mode — design

Status: implemented on `feat/event-tracer` (driver batch 2026-11-09);
simulator-verified (`make test`); **no bench validation yet**. SKU
`SBOS_GUEST_MODE`, combo driver, no Agent module (nothing is uploaded).

## What it does

A short-let host already publishes every booking as an iCal feed (Airbnb,
Booking.com, VRBO). The driver polls up to three feeds, turns bookings into
stays with the listing's check-in / check-out times, and keeps one small
state (`vacant`, `arriving_today`, `occupied`, `departing_today`,
`turnover`) that Composer programming reads through events, variables and
conditionals. A per-stay PIN and a guest Wi-Fi password are exposed as
variables for the dealer's own lock and welcome-screen programming.

## Modules

| Path | Role | Tests |
| --- | --- | --- |
| `src/guestmode/ical.lua` | RFC 5545 parser: unfolding, DATE / DATE-TIME (Z, floating, TZID recorded), DURATION, STATUS:CANCELLED, block detection, guest name | `test_guestmode_ical.lua` (32) |
| `src/guestmode/stays.lua` | stays from events (all-day → check-in/out times, exclusive DTEND, Z offset), the state engine (transitions by comparing previous and new state, manual check-in/out, early check-out as a cutoff, prune, persist) | `test_guestmode_stays.lua` (40) |
| `src/guestmode/pin.lua` | per-stay PIN with injected randomness (no repeats, runs, alternations, never the previous) | `test_guestmode_pin.lua` (13) |
| `drivers/smartbuildos-guest-mode/driver.lua` | properties → options, polling through `lib.http`, tick every minute, events, licensing, persistence | `test_guestmode_driver.lua` (54) |

## Rules a host relies on

- Initial state after a restart is the persisted one: a reload replays
  nothing (the engine fires only on a change between previous and new state).
- Overlapping or back-to-back stays never double check-in; a uid change while
  occupied is a check-out followed by a check-in in the same tick.
- A failed poll keeps the last good feed in force; *Calendar Unreachable*
  fires once when every feed fails, *Calendar Recovered* once on the next
  success.
- Early check-out ends the stay at that instant (a cutoff), so the stay
  cannot re-check-in and the turnover follows as after any check-out.
- Licence enforcement (definitive denial AND enforce) stops polling and
  ignores commands; uncertainty never does (charter).

## Evidence classes and PROBES

| Item | Class | Note |
| --- | --- | --- |
| `C4:url` through `lib.http` | MEASURED (Atmosphere, Agent) | GET with Accept text/calendar, 20 s timeout, 2 MB cap |
| `os.time` / `os.date` local conversion of all-day bookings | VERIFIED_BY_EXAMPLE (Atmosphere uses the controller's local clock) | DST on a check-in day shifts the instant by the controller's own rule, which is what a host expects |
| `Z` DATE-TIME conversion via local offset | VERIFIED_BY_DOCS (Lua) | offset computed from `os.date("*t")` vs `os.date("!*t")` |
| `TZID` interpretation | NOT IMPLEMENTED | taken as controller-local; documented; platform feeds use VALUE=DATE |
| Lock user-code programming | NOT DONE BY DESIGN | the lock proxy's user-code commands are not in the docs we hold (only `can_edit_user_pin` capability flags); the driver exposes `GUEST_PIN` + events and the dealer wires the lock's own programming |
| Encrypted persist for PIN / Wi-Fi | VERIFIED_BY_DOCS (`PersistSetValue(key, value, true)`) | the Agent's field caveat applies: encrypted persist has lost data across updates; a lost PIN is regenerated at the next check-in |
| Private feed URLs on a controller with no TLS verification issues | PROBE | Airbnb/Booking feeds are HTTPS; bench must confirm `C4:url` fetches them (Atmosphere fetches api.weather.gov, so the path works) |

## Bench plan

1. Paste a real Airbnb feed; `Print Stays` matches the hosting calendar
   (check-in/out instants in local time).
2. Set Check-in Time to a few minutes ahead with a stay starting today; watch
   *Guest Arriving Today* then *Guest Checked In* + *Guest PIN Changed*.
3. Pull the controller's uplink for one poll interval: *Calendar Unreachable*
   once, stays unchanged; restore: *Calendar Recovered*.
4. Update the driver in place mid-stay: still `occupied`, PIN unchanged, no
   events replayed.
5. Wire *Guest PIN Changed* to the lock's own user-code action on the bench
   lock and confirm the code opens the door; *Guest PIN Cleared* removes it.

## Not included in v1

- Multiple units per driver (add one driver per unit).
- Platform APIs (messaging the guest, pricing); a guest-facing web view.
- Cleaner notifications: route *Turnover Due* through the Notification
  Router driver.

## Bench 2026-11-09 07:05–07:25 — Beta Site 2 (OS 4.3), room Smartbuildps (id 318)

Online, Guest Status `vacant`, Stays In 30 Days 0, Calendars `none configured`, Last Poll 07:14:21, Last Error none. License Status `Licensing Not Yet Enforced`, tier `Enterprise`, company painted.
