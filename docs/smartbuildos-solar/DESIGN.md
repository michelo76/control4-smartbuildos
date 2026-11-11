# Solar Position — design

Status: implemented on `feat/event-tracer` (driver batch of 2026-11-09),
simulator-verified; bench validation owed. SKU `SBOS_SOLAR`, combo driver,
no module pipeline (nothing to upload; everything is computed locally).

## What it adds over Director

Director exposes sunrise/sunset only as Scheduler entries (Atmosphere's
finding, `src/atmosphere/solar.lua` header). Shading and lighting rules
need the sun's position: `src/solarpos/position.lua` implements the NOAA
solar position (apparent elevation with NOAA's refraction fit, azimuth
clockwise from true north, declination, hour angle) at an exact UTC epoch,
and reuses `atmosphere.solar.solarState` for the day's sunrise, noon,
sunset and the next ones.

`src/solarpos/engine.lua` turns that into transitions a technician can trust:

| Rule | Behaviour |
| --- | --- |
| Phases | by GEOMETRIC elevation (NOAA's sunrise is geometric -0.833; civil twilight -6; golden ceiling 6); morning/evening split by the sign of the hour angle (no timezone arithmetic) |
| Events | one per boundary of the day, each once per transition: `civil_dawn` (night → dawn), `sunrise`, `golden_morning_ended` (→ day), `golden_evening`, `sunset`, `night` (twilight over). `sunrise`/`sunset` come from the horizon flag itself, not from the phase names, so a late tick still reports them. The two original names stay for existing programming: `golden_hour` (entering either golden phase) and `civil_dusk` (entering dusk) |
| Facades | lit when min ≤ APPARENT elevation ≤ max (max defaults to 90 = no ceiling) and |azimuth − heading| ≤ width/2; ONE degree of hysteresis on every edge; wrap-around arcs across north handled by `angleDiff`. A ceiling at or under the floor is refused by name. With a ceiling a facade can be lit twice a day. `shadeReason` says why a facade is in shade (`high`, `low`, `aside`) |
| Countdown | `MINUTES_TO_SUNSET` / `MINUTES_TO_SUNRISE` walk every number on the way down (a gap of up to five), so "equals N" programming cannot miss on tick drift |
| Initial state | the first tick after a location or facade change announces nothing |
| Polar day/night | `solar == nil`, phase and daylight still computed from the hour angle |

## Evidence

- NOAA identities verified in `test/test_solarpos_core.lua`: noon elevation
  = 90 − |lat − declination| within 0.15° at Greenwich, Miami and Sydney on
  the 2026 equinox and both solstices; declination ±23.44 at the solstices
  and 0 at the equinox; geometric elevation −0.833 at the computed sunrise
  and sunset; sunrise east / sunset west and mirrored about south; NOAA's
  published Boulder 2010-06-21 example (sunrise 05:31, sunset 20:32 MDT,
  noon elevation 73.4°).
- A simulated Miami June day at one-minute ticks produces the phase
  sequence night › dawn › golden_morning › day › golden_evening › dusk ›
  night with each event exactly once and east/south/west facades lit in
  order.

## Location

The project's coordinates by Atmosphere's rule: `GetProjectItems("LOCATIONS",
"LIMIT_DEVICE_DATA", "NO_ROOT_TAGS")`, tolerant tag grab of `<latitude>` and
`<longitude>` (`city_name` for the label), with a Manual Coordinates
override. Director system events 52/53/54 (zip, latitude, longitude changed)
are registered system-wide and re-resolve; an hourly re-resolve covers an OS
without them. **PROBE (shared with Atmosphere):** the exact XML shape of the
LOCATIONS root item on OS 4.3 is reported by the bench, not assumed; a miss
reads `no_location` with the reason in Last Solar Error, never a wrong sun.

## Composer surface

Variables 3000–3012, events 1–17 (13–17 added 11 Nov 2026; ids never move),
conditionals 1–7, properties as listed in
`www/documentation/index.md`. `<combo>true</combo>` so Composer lists the
driver (bench finding of 2026-11-09). Licence enforcement (definitive denial
AND enforcement on) halts the minute tick and paints `unlicensed`;
uncertainty keeps tracking.

## Not included (v1)

- Terrain or obstruction modelling beyond a per-facade minimum and maximum
  elevation. Max Elevation is a cut-off on elevation, not on the profile
  angle: with the sun off to one side an overhang shades the glass a little
  sooner than the driver reports, never later.
- Solar irradiance / cloud cover (Atmosphere owns weather).
- Scheduling helpers ("N minutes before sunset" is one line of programming
  on `MINUTES_TO_SUNSET`).

## Bench 2026-11-09 07:05–07:25 — Beta Site 2 (OS 4.3), room Smartbuildps (id 318)

Online, Solar Status `tracking`, Location painted as `<city> (project: <lat> <lon>)`, read from the project with Location Source = Control4 Project (the site's coordinates are not recorded here), Sun Now `elevation 8.6°, azimuth 113.7° (day)` at ~07:16 local, Today `sunrise 06:35, solar noon 12:04, sunset 17:34`, Facade Status `no facades configured`. Licence painted (Enterprise, company) after the `Checking…` window.
