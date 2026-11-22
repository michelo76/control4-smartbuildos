# SmartBuildOS AI Core — installation

For the integrator adding AI Core to a Control4 project. **No physical
controller has run AI Core yet**: every step and every text below comes from
the driver source and from simulation (unit tests and the Director emulator,
see `TEST-MATRIX.md`). Where hardware may behave differently, the
[hardware validation plan](TEST-MATRIX.md#hardware-validation-plan) says how
to check.

**Round two** (the live device read, battery and sensor health, the
dealer's preset questions: §10 items 6–8) exists only on the unpushed branch
`feat/ai-core-round2` and the platform's `codex/ai-core-round2`; a build from
`feat/ai-core` (pull request #49) has none of it. Round two also needs the
platform's round-two migration `20261119120000` (`RELEASE.md` §3), which is
not applied anywhere.

Property and variable texts are quoted exactly as the driver writes them
(`drivers/smartbuildos-ai-core/driver.lua`, `src/aicore/state.lua`,
`src/sbos/license.lua`). The full reference is `DRIVER.md`.

## 1. Prerequisites

| Need | Detail |
| --- | --- |
| Control4 OS | **3.3.2 or later** (`<minimum_os_version>` of AI Core and of the Flight Recorder; the Agent itself needs 3.3.1). Below that the driver stops at start and `Driver Status` says so (`CheckMinimumVersion`). |
| SmartBuildOS Agent | `smartbuildos.c4z`, installed from Composer's **Agents** panel and **paired** to the property, from a build that speaks **module contract v2** (protocol range 1..2). The first Agent with v2 is built from branch `feat/ai-core` of this repo; **no released Agent carries it yet** (the latest release, `20261116.035552`, is protocol 1 only). With a v1 Agent AI Core registers but shows `SmartBuildOS Agent update required (module contract v2)` and sends no AI request. |
| SmartBuildOS Flight Recorder | Optional, recommended, same build as AI Core. With it AI Core consumes its events (no double capture) and attaches its local history to diagnostics. An older recorder without the v2 local-history service still works for collection; diagnostics then say so. |
| SmartBuildOS platform | The property exists in System Studio; the AI Core migrations are applied and the platform is deployed so `/api/integrations/control4/modules/rpc` answers (until then every AI request is refused `cloud_refused`); the AI provider key (OpenAI or Anthropic) is entered **in System Studio** — never in Composer. |
| Licence | SKU `SBOS_AI_CORE` in the platform's driver catalogue. Price (owner decision of 2026-11-18): **$150 dealer**, one-time, per controller, and **$250 MSRP** (public surfaces show only the MSRP). **No subscription plan includes it** (plan inclusion is still an owner decision). A purchase grants `BASE`, `AI_LEARNING` and `AI_ACTIONS`, never `AI_CONCIERGE`. It **cannot be bought until a release is published**, so today it is licensed only by an **explicit entitlement** for the controller, whose features come from that entitlement. The price is set by the platform's last migration, applied to no database yet. `AI_LEARNING` is needed for learning. |
| Composer | Composer Pro with the project open, able to add a local driver. |

## 2. Obtaining the `.c4z`

The file is `smartbuildos-ai-core.c4z`. Today it exists only as a local
build: no GitHub release and no store package of AI Core has been published
(both are owner actions, see `RELEASE.md`).

* **Local build**: `make build` in this repo writes it to `dist/oss/` and
  copies it into `~/Documents/Control4/Drivers` (see `RELEASE.md` §1 for
  what else `make build` changes).
* **Later, a release**: download it from the release's assets.
* **Updates after the first install** come through the Agent's updater (the
  SmartBuildOS store or GitHub, the Agent's `Update Source`), which only
  updates drivers already in the project — it never adds AI Core by itself.

Use the Agent, Flight Recorder and AI Core from the **same build**.

## 3. Adding it in Composer

1. Copy `smartbuildos-ai-core.c4z` (and `smartbuildos-flight-recorder.c4z`)
   into the Composer drivers folder (`Documents/Control4/Drivers`).
2. Make sure the Agent is installed (Agents panel) and paired: its
   `Connection Status` should read connected and its pairing shown.
3. Optional: add **SmartBuildOS Flight Recorder** to any room.
4. Items → Search → **SmartBuildOS AI Core** → add it to any room (it is a
   combo driver with no Navigator UI). One per project: a second instance is
   refused by the Agent's singleton rule.

## 4. What each property should read, step by step

Read the AI Core driver's **Properties** tab. `Driver Status` reads `Online`
in every row once started; `Driver Version` the build's `<version>`.

| Step | SmartBuildOS Connection Status | Agent Pairing Status | AI Status | License Status | Flight Recorder Link |
| --- | --- | --- | --- | --- | --- |
| Added, no Agent in the project | `No SmartBuildOS Agent in this project` | `No SmartBuildOS Agent` | `Degraded: No SmartBuildOS Agent in this project` | `No SmartBuildOS Agent Found` | `Unknown (needs Agent protocol 2)` |
| Agent found, registration not answered yet | `Registering with the SmartBuildOS Agent` | `Unknown (not registered with the Agent yet)` | `Degraded: Registering with the SmartBuildOS Agent` | `SmartBuildOS Agent Found - Checking...` | `Unknown (needs Agent protocol 2)` |
| Agent is protocol 1 only | `SmartBuildOS Agent update required (module contract v2)` | `Agent update required` | `Degraded: SmartBuildOS Agent update required (module contract v2)` | as the Agent answers | `Unknown (needs Agent protocol 2)` |
| v2 Agent, not paired | `SmartBuildOS Agent not paired` | `Not paired` | `Degraded: SmartBuildOS Agent not paired` | `SmartBuildOS Agent Found - Not Linked` | as discovered |
| Paired, Agent has no cloud | `SmartBuildOS cloud unreachable` | `Paired` | `Degraded: SmartBuildOS cloud unreachable` | last answer | as discovered |
| Ready | `Connected` | `Paired` | `Ready` (`Working: N request(s) waiting for a result` while results are pending) | `Licensed / Subscribed` (or `/ Permanent`, `/ Trial`, `/ Grace (until …)`; `Licensing Not Yet Enforced` before the platform issues an AI Core licence) | `Installed: local history served; topics subscribed`, or `Not installed: AI Core collects its minimal set itself` |
| Licence definitively refused with enforcement on | `Connected (not licensed)` | `Paired` | `Unavailable: <licence line>` | e.g. `License Expired (see SmartBuildOS) (read-only)` | unchanged |

Until System Studio delivers the configuration: `AI Provider` and `AI Model`
read `Not configured (System Studio)`, `AI API Credential` reads `Not
configured`, `Permission Mode` reads `Not delivered yet (System Studio owns
it)`, `Property ID` / `Controller ID` read `Not delivered yet (System
Studio)`, `Learning Status` reads `Off (not switched on in System Studio)`
and `LEARNING_ACTIVE` is false: learning, and every collection source, is off
until a valid configuration switches it on (`DRIVER.md` §9, defaults). `Telemetry Status` reads `No Agent answering: …` until the
Agent registers AI Core, then `Through the Agent: N sent, N acknowledged, N
dropped; buffer N, buffer drops N`.

Variables: `AI_STATUS` carries the state code (`no_agent`, `registering`,
`agent_update_required`, `agent_unpaired`, `cloud_unreachable`,
`agent_lost`, `unlicensed`, `ready`, `working`), `AGENT_CONNECTED` turns
`true` once registered and answering.

## 5. Pairing

AI Core does not pair itself: the **Agent** is paired (Pairing Code or the
account-number flow on the Agent). AI Core follows the Agent:

* Pair the Agent before or after adding AI Core — both work. AI Core
  re-reads the Agent's state on every registration and on the Agent's state
  updates; no reload of AI Core is needed.
* An Agent from this branch also registers for Director system events at
  the moment it is paired (older Agents did so only after a reload).

## 6. Verifying

1. **Test Agent Link** (Actions). `Last Test Result` should read `Agent link:
   OK at <time> — Agent <version>, protocol 1..2, paired, cloud connected; N
   module(s)`. `registered at protocol 1; this driver needs an Agent update
   (protocol 2)` means the Agent is too old.
2. **Print Diagnostics** writes the state, licence, configuration, Flight
   Recorder link, collection plan and every counter to the Lua output.
3. In the Agent, **Refresh Entitlements Now**, then check AI Core's `License
   Status`.

## 7. First sync

1. In System Studio, open the property's Intelligence pages, choose the AI
   provider, enter its key, and set learning, exclusions and the permission
   mode. System Studio sends the configuration with the Agent's next
   heartbeat (the Agent's `Heartbeat Interval`).
2. When it arrives: `AI Provider`, `AI Model`, `AI API Credential` (a
   status such as `Configured in System Studio · Anthropic ••••abcd`, never a
   key), `Permission Mode` (`observe`, `recommend` or `execute_low_risk` +
   ` (set in System Studio)`), `Property ID`, `Controller ID` fill in, and
   `Last Synchronization` shows the time.
3. Press **Sync Now** to re-register if needed, flush buffered events, re-read
   the directory and ask the platform's `status` op.
4. Press **Test AI Connection**. Expected: `AI connection: test accepted (job
   …); result follows as AI Response Ready`, then the **AI Response Ready**
   event and `AI_LAST_RESPONSE`.

## 8. Common first-run failures

| What you see | Cause | Do |
| --- | --- | --- |
| `No SmartBuildOS Agent in this project` | No `smartbuildos.c4z`, or it was renamed | Install the Agent from the Agents panel |
| `SmartBuildOS Agent update required (module contract v2)` | The Agent is protocol 1 (every release up to `20261116.035552`) | Install an Agent built with module contract v2 |
| Stays on `Registering with the SmartBuildOS Agent` | The Agent is not answering module frames | Check the Agent's Lua output; **Sync Now**; the driver retries every 30 s, doubling to 5 min |
| `SmartBuildOS Agent not responding` (`agent_lost`) | Registered, then the 5-minute directory probe got no answer | Check the Agent is running; it recovers on the next answer (probed every 30 s meanwhile) |
| `SmartBuildOS Agent not paired` | The Agent is not paired | Pair the Agent |
| `SmartBuildOS cloud unreachable` | The Agent has no internet, or the last request could not reach SmartBuildOS after 2 retries | Check the uplink; the next accepted request clears it |
| `Last Test Result`: `AI connection: refused (cloud_refused)` | The platform route `/api/integrations/control4/modules/rpc` is not deployed (404 → `cloud_refused`) | Owner: deploy the platform |
| `Last Test Result`: `AI connection: refused (not licensed for this controller)`; `Last Error`: `… refused by SmartBuildOS: not licensed for this controller (not_entitled)` | SmartBuildOS has no AI Core licence for this controller. **AI Status** can still read Ready: the driver stops itself only when SmartBuildOS enforces licences for AI Core | Add an AI Core licence for this controller in SmartBuildOS |
| `refused (unsupported)` | The platform deployed is older than this driver and does not know that op | Owner: deploy a platform built from the same AI Core release |
| `refused (not_permitted)` | The platform refused: permission mode, licence features, homeowner settings | Check System Studio |
| `License Status` stays `SmartBuildOS Agent Found - Checking...` | The Agent has not answered the licence question | Agent → **Refresh Entitlements Now** |
| `Licensing Not Yet Enforced` | The Agent holds no AI Core assertion (not issued yet, or one failed verification and was dropped) | Refresh entitlements; check the Agent's Lua output for `failed verification` |
| `... (read-only)` on `License Status`, `AI_STATUS` `unlicensed` | A definitive licence refusal with enforcement on | Licence AI Core for this controller in SmartBuildOS |
| `Last Error`: `AI_LEARN_PREFERENCE refused: the licence does not include AI_LEARNING` | The licence lacks `AI_LEARNING` (enforced) | Add the feature, or do not use learning |
| `Last Error`: `Configuration vN refused: <path>: <reason> (vM kept)` | System Studio sent a document AI Core rejects whole (unknown key, a key-shaped value, a bad bound) | Fix it in System Studio; the previous version stays in force, except learning, which is off until a valid document switches it on |
| `Flight Recorder Link`: `Installed (no local history service; update the Flight Recorder)` | An older Flight Recorder | Update it to the same build |
| `Learning Status`: `Off (not switched on in System Studio)` / `Paused by System Studio…` / `Paused by configuration: vN refused` / `Stopped (not licensed)` | Learning not switched on yet (the default), turned off, the last document refused, or the licence is refused | System Studio / licence |
| `AI_LAST_ERROR`: `AI provider error: …` | The provider (OpenAI / Anthropic) failed for the platform | Check the key and the provider's limits in System Studio |
| `Last Error`: `AI_RUN_HOUSEHOLD_ANALYSIS refused: the licence does not include AI_LEARNING` | The licence lacks `AI_LEARNING` (enforced); nothing was sent | Add the feature |
| `AI Status`: `… last request refused locally (rate_limited)` after **Run Household Analysis** | One accepted run an hour from this controller, or a request is still waiting; `Last Error` says which, and when the next is allowed | Wait; check the programming does not fire it repeatedly |
| `AI Status`: `… last request refused (learning_not_allowed)` | Learning is off or paused for this home in System Studio | Switch learning on in System Studio |
| `Last Error`: `AI_RUN_HOUSEHOLD_ANALYSIS: the SmartBuildOS Agent refused it (not_permitted): update the SmartBuildOS Agent …` | The Agent is older than this command and does not relay it | Update the SmartBuildOS Agent to the same build as AI Core |

## 9. Running the household analysis from programming

The household analysis is the learning step that turns this home's recorded
activity into patterns and recommendations in System Studio. SmartBuildOS
can run it on a schedule chosen in System Studio; to run it from Control4
programming as well (for example every night after the house goes to Sleep,
or from a dealer-only button), add the command **`AI_RUN_HOUSEHOLD_ANALYSIS`**
— its description reads *Run Household Analysis* — to the programming:

1. Composer Pro → **Programming**. In the left pane pick the event that
   should start it (a scheduler event, a mode change, a keypad button).
2. In the right pane select the **SmartBuildOS AI Core** device, choose
   **Device Specific Command**, pick `AI_RUN_HOUSEHOLD_ANALYSIS` (it takes no
   parameters) and drag it into the script. These Composer steps are the
   usual ones for any driver command; they have not been walked through on a
   real Composer with this driver (`TEST-MATRIX.md` procedure 21).
3. Requirements: the AI Core licence includes **`AI_LEARNING`**, learning is
   switched on for the home in System Studio, and the Agent is the build
   that ships with this AI Core.

What to expect:

* Normally `Print Diagnostics` shows `last_cloud_result =
  AI_RUN_HOUSEHOLD_ANALYSIS: accepted (queued)`, `AI Status` stays `Ready`
  and `Last Error` shows no SmartBuildOS refusal. *Queued* means SmartBuildOS
  took the request and runs the analysis afterwards; **the driver is never
  told when it finishes**. The findings appear in System Studio (Intelligence
  pages), not on the controller, and **AI Response Ready does not fire** for
  this command.
* At most one accepted run an hour from the controller, and one request
  waiting at a time. A second press inside that sends nothing and shows
  `refused locally (rate_limited)`. A refusal, a lost connection or a timeout
  does not use up the hour. SmartBuildOS keeps its own limit of one accepted
  run an hour for the home and answers `refused (rate_limited)` with the
  time to wait.
* Other refusals name their reason in `AI Status` and `Last Error`:
  `learning_not_allowed`, `not_licensed`, `already_running`, `not_permitted`,
  `invalid_args` (table in §8).

## 10. The AI Core tile (touchscreen and phone app)

AI Core adds a Navigator tile (a `uibutton` proxy with a web view, like PIN
Lock and Atmosphere). **It has not been opened on a real touch screen or
phone yet** (`KNOWN-ISSUES.md` KI-53 to KI-60).

1. **Add the tile.** After adding AI Core, its **AI Core** tile appears in the
   room the driver was added to; move or hide it in Composer like any other
   tile. **Webview Address** shows `http://<controller>:47871/app (home
   network only)`. If it says the controller address is unknown, set **App
   Relay Address** to the controller's LAN address — and the **same** value
   on PIN Lock. After changing it, run *Republish App URL* and close and
   reopen the tile (Navigator does not change the address of an open page).
2. **Add PIN Lock (required for the chat and approvals).** Install
   **SmartBuildOS PIN Lock** in the same project, licence it, and create an
   **owner** code with a PIN on its own page. Leave its *AI Core PIN
   Verification* property on. Only owner PINs work on the AI Core tile; staff,
   vendor and guest codes never do. Wrong PINs count against PIN Lock's own
   lockout (*Clear Lockouts* on PIN Lock clears it). Without PIN Lock the tile
   still shows the status and the number of items awaiting approval, and says
   to use the SmartBuildOS portal for the rest. **Touchscreen Approvals**
   says in plain words what is missing.
3. **The homeowner's two switches (SmartBuildOS portal).** Nothing here turns
   them on: the homeowner does, in the portal. *Approvals at the touchscreen*
   (off by default) lets an owner PIN approve or decline low- and medium-risk
   action proposals on the tile; everything else stays portal only.
   *Household answers at the touchscreen* (off by default) lets the chat use
   household activity. For activity, **Touchscreen Detail** can only lower
   this: *Basic* switches the chat off, *Standard* never asks for household
   activity, *Household* asks for it but the cloud answers with it only when
   the homeowner's switch is on. At *Household* an owner PIN also lets the
   chat answer about the current state of devices (item 7), whatever that
   switch says; choose *Standard* to keep device answers to equipment status.
4. **What works only on the home network.** The whole page: a touch screen or
   a phone on the home Wi-Fi reaches the controller; a phone away from home
   does not (the page says *Available on the home network only*). There is
   no cloud fallback.
5. **Check it.** Open the tile: the status shows *Online* and *PIN Lock is
   ready for this screen*. Press *Unlock with owner PIN*, enter the owner
   PIN, ask a question; the answer appears on that page only. The chat locks
   again after 5 minutes without use, when the tile is closed, and on *Lock*.
6. **Preset questions (optional; round two).** In System Studio, the AI Core settings
   take up to **6** preset questions for the touchscreen chat (3–120
   characters each, plain text, no links). They reach the controller with
   the AI Core configuration, and only once the controller runs the AI Core
   driver of this release (an older driver is not sent them). They appear on
   the tile **only after an owner PIN unlocks the chat**, as buttons before
   the three built-in questions; a locked tile shows none. Pressing one asks
   exactly that question. Changing the list in System Studio replaces the
   buttons at the next page refresh; a button from the old list is refused
   (*That suggestion is not available*), never answered as another question.
   Homeowners cannot edit them. How a long question wraps on a real
   touchscreen has not been checked. A preset may contain a word such as
   *desk-lamp*; text shaped like a key (`sk-` at the start or after any
   character that is not an ASCII letter or digit, then 8 or more letters,
   digits, `_` or `-`) is refused.
7. **What the tile can tell about devices (round two).** With the
   homeowner's *Household answers at the touchscreen* switch **off** (the
   default), the chat can tell a device's temperature, humidity, battery,
   signal quality, online status and temperature scale; it refuses locks,
   security, doors, motion, contacts, relays, lights and cameras before
   anything is read out. **With Touchscreen Detail at *Household*, an owner
   PIN changes that**: the chat can then tell the current state of doors,
   garage, gates, locks, the alarm, motion and contact sensors, relays and
   lights, and other short plain values a device exposes, and those values
   go to SmartBuildOS and the AI provider — whatever the homeowner's switch
   says (it still decides activity patterns). The chat locks 30 minutes after
   the PIN. At *Standard* a PIN changes nothing here. With the switch on, the
   homeowner's usual household rules decide. Cameras are always refused. There is no energy data, and the chat says so rather than
   guess. A live read needs the round-two Agent **and** the round-two AI Core
   on the controller; until both run, the platform answers that the
   controller cannot do it yet.
8. **Battery and sensor health: switch on System Studio monitoring (round
   two).** Battery levels, low-battery flags, signal quality and offline
   sensors come from the samples the SmartBuildOS Agent uploads every 5
   minutes **only while monitoring is switched on for this system in System
   Studio**. It is **off by default**, and nothing switches it on for you;
   with it off, the AI says plainly that nothing is known. The Agent samples
   at most 200 sensors, and a battery is called low only when the device
   itself says so.

