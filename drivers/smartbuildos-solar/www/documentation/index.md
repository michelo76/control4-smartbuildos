# SmartBuildOS Solar Position

Control4 knows when the sun rises and sets. It does not know where the sun is:
how high, from which direction, and whether it is on the west glass right now.
This driver computes that every minute from the project's coordinates, offline,
and hands it to programming as variables, events and conditionals: elevation,
azimuth, the day phase, the next sunrise and sunset, and up to four building
facades with "sun hits" and "sun leaves" events for shading and lighting.

Requires the SmartBuildOS Agent (`smartbuildos.c4z`) paired to a SmartBuildOS
system. The Agent is the licensing authority (SKU `SBOS_SOLAR`): **License
Status** shows this driver's standing. No internet is used for the sun maths.

## Setup

1. Install and pair the SmartBuildOS Agent.
1. Add this driver (one per project). **Location** shows the coordinates it
   found in the project. If the project has none, set **Location Source** to
   Manual Coordinates and fill in **Latitude** and **Longitude**.
1. Name the facades you care about (`Facade N Name`), give each its compass
   heading (`Azimuth`, 0 = north, 90 = east, 180 = south, 270 = west), the
   width of sky it sees (`Width`, default 90 degrees) and the lowest sun that
   counts (`Min Elevation`, default 5 degrees so trees and neighbours do not
   count). **Facade Status** shows sun or shade for each.

## What it computes

Every minute: **Sun Now** (apparent elevation and azimuth, and the phase) and
**Today** (sunrise, solar noon, sunset, next sunrise and sunset). Phases, by the
sun's geometric elevation, the way NOAA defines sunrise and twilight:

| Phase | Sun |
| --- | --- |
| night | below -6 degrees |
| dawn / dusk | -6 to -0.833 (civil twilight) |
| golden_morning / golden_evening | -0.833 to 6 |
| day | above 6 |

A facade is lit when the sun's elevation is at least its minimum and the
azimuth is within half its width of its heading. One degree of hysteresis on
both edges: once lit, it stays lit until the sun is a full degree below the
minimum or past the edge, so a sun grazing an edge never flaps the shades.

## Programming

- Events: *Golden Hour Started*, *Civil Dawn*, *Civil Dusk*, *Sun Hits Facade
  1..4*, *Sun Leaves Facade 1..4*, *Location Changed*.
- Conditionals: *The sun is up*, *It is golden hour*, *The sun is on facade
  1..4*.
- Variables: `SUN_ELEVATION`, `SUN_AZIMUTH` (whole degrees), `IS_DAYLIGHT`,
  `DAY_PHASE`, `NEXT_SUNRISE`, `NEXT_SUNSET` (local HH:MM),
  `MINUTES_TO_SUNSET`, `MINUTES_TO_SUNRISE`, `SUN_ON_FACADE_1..4`,
  `LOCATION_SOURCE`.
- Command: *Recompute Sun* (also runs every minute).

## Actions

| Action | What it does |
| --- | --- |
| Print Solar Status | Location, sun, today's times, each facade's settings and state |
| Recompute Now | Runs the minute tick now |
| Rediscover Location | Re-reads the project (or manual) coordinates |
| Register With Agent Now / Refresh Status | Licensing and property refresh |

## What is not claimed

Accuracy is the NOAA algorithm's: about a minute on sunrise and sunset, tenths
of a degree on position. Terrain, buildings and weather are not modelled: the
minimum elevation per facade is how you account for a tree line. Polar day and
night are reported as a phase without sunrise and sunset times. A controller
whose OS lacks system events still follows a changed project location within
the hour.
