# SmartBuildOS Flight Recorder

Records selected device and room observations, Composer programming traces and
diagnostic snapshots through the **SmartBuildOS Agent**, for investigation in
System Studio: what happened, which device or automation was involved, what
happened immediately before and after, whether an action was merely requested or
its result observed, and what evidence supports an explanation.

Requires the SmartBuildOS Agent (`smartbuildos.c4z`, a build with module
services) paired to a SmartBuildOS system. Local recording continues during an
internet outage; uploads wait in the Agent's bounded, journaled queue.

## Setup

1. Install the SmartBuildOS Agent from Composer's Agents tab and pair it.
1. Add this driver (one per project). **Agent Link** shows the Agent's device id
   and **Agent Connection** reads `ready` once registered.
1. Pick what to record in System Studio (Activity → Flight Recorder → Recorder
   settings), or choose a **Template** here and run **Apply Selected Template**
   (adds only sources that exist in this project; System Studio owns the
   configuration and shows this as a Composer revision).
1. Add the trace commands to routines (Device Specific Commands): Start Trace,
   Record Trace Step, Record Trace Decision, Record Expected Result, Complete
   Trace, Fail Trace, Record Event, Capture Snapshot, Pause/Resume Recording.
   Every trace command takes a **CHANNEL** you name (default `main`); routines
   that may overlap use different channels.

## Behaviour

- **Initial reads are not changes.** Applying a configuration reads each source
  once (`initial`); the previous value stays unknown until the first change
  afterwards.
- **Requested is not observed.** A step or expected result is what the
  programming said; an observation is what a device reported. The recorder never
  infers success, a button press or a cause from a nearby change.
- **Bounded.** Sources (64 default, 200 max), events per minute (120 default),
  per-source debounce / minimum change / coalescing, 16 active traces, a
  10-minute trace timeout, a 300-event local stage; the Agent's queue holds
  2,000 events / 512 KB. Overflow is dropped and COUNTED (Dropped Events, Buffer
  Threshold Reached) and the gap is marked in System Studio.
- **Private.** Credential-bearing variables are never recorded; programmer text
  and string variables are stored as unreviewed text and redacted for codes and
  tokens on the controller and on the platform. A snapshot is diagnostic
  evidence, not a project backup.

## Properties

Recording Status · Agent Link · Agent Connection · License Status ·
Configuration (applied / desired) · Selected Sources · Active Traces · Buffered
Events · Dropped Events · Last Upload · Last Recording Error · Last Snapshot ·
Template · Buffer Warning Threshold.

## Events and conditionals

Recording Degraded / Restored, Buffer Threshold Reached, Snapshot Completed /
Failed, Trace Completed / Failed, Agent Connected / Disconnected. Conditionals:
Recording is active; SmartBuildOS Agent link is ready.

## Hardware validation

Simulator-verified (driver test suite with a scripted Agent). Not yet exercised
on a physical controller: see the repository's
`docs/flight-recorder/VERIFICATION.md` for the bench steps and evidence owed.

<!-- #embed-changelog -->
