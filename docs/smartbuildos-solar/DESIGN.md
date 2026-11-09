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
| Events | `civil_dawn` (night → dawn), `golden_hour` (entering either golden phase), `civil_dusk` (entering dusk); each fires once per transition |
| Facades | lit when APPARENT elevation ≥ min and |azimuth − heading| ≤ width/2; ONE degree of hysteresis on both edges; wrap-around arcs across north handled by `angleDiff` |
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

Variables 3000–3012, events 1–12, conditionals 1–6, properties as listed in
`www/documentation/index.md`. `<combo>true</combo>` so Composer lists the
driver (bench finding of 2026-11-09). Licence enforcement (definitive denial
AND enforcement on) halts the minute tick and paints `unlicensed`;
uncertainty keeps tracking.

## Not included (v1)

- Terrain or obstruction modelling beyond a per-facade minimum elevation.
- Solar irradiance / cloud cover (Atmosphere owns weather).
- Scheduling helpers ("N minutes before sunset" is one line of programming
  on `MINUTES_TO_SUNSET`).

## Bench 2026-11-09 07:05–07:25 — Beta Site 2 (OS 4.3), room Smartbuildps (id 318)

Online, Solar Status `tracking`, Location painted as `<city> (project: <lat> <lon>)`, read from the project with Location Source = Control4 Project (the site's coordinates are not recorded here), Sun Now `elevation 8.6°, azimuth 113.7° (day)` at ~07:16 local, Today `sunrise 06:35, solar noon 12:04, sunset 17:34`, Facade Status `no facades configured`. Licence painted (Enterprise, company) after the `Checking…` window.
