# The SmartBuildOS driver platform — what a new driver gets for free

Written 2026-08-31 for whoever starts driver #12 in this repo. It is the paved
road: what to reuse, in what order, and which traps have already been paid for
by a field failure. Everything here is grounded in code that ships — file paths
are cited so you can read the original rather than trust this page. Where
something is a judgment call or unproven on hardware, it says so.

Repo doctrine, unchanged: **docs are a hypothesis, hardware is the answer.**
Nothing marked unverified may become a design dependency.

______________________________________________________________________

## 1. What you get for free

A driver in this repo is not just a `.c4z`. It can opt into a platform that
already exists, one `require` at a time. Every capability below is fail-open — a
driver that never opts in is not worse off, and a driver that opts in and gets
no answer keeps working.

| Capability                                                     | Opt in with                                                                    | Cost                                    | Section                                              |
| -------------------------------------------------------------- | ------------------------------------------------------------------------------ | --------------------------------------- | ---------------------------------------------------- |
| Licensing / entitlements (status, features, tier, company)     | `require("sbos.license")`                                                      | ~5 lines + 4 XML properties             | [§3](#3-licensing-in-five-lines)                     |
| Cloud state mirror (your UI state readable off-LAN)            | `require("sbos.mirror")`                                                       | ~5 lines + a LAN JSON route             | [§4](#4-cloud-mirror--remote-settings-in-five-lines) |
| Remote settings pushed from SmartBuildOS                       | `mirror.onConfig(apply)`                                                       | one `apply(patch) -> refusals` function | [§4](#4-cloud-mirror--remote-settings-in-five-lines) |
| Self-update from the platform store (or GitHub)                | one line in the Agent                                                          | none in your driver                     | [§5](#5-registering-the-sku)                         |
| Driver store publishing (STABLE/BETA channels)                 | one `sku_for()` case in CI                                                     | none                                    | [§5](#5-registering-the-sku) · [§7](#7-shipping)     |
| Fleet health / incidents (`driver_events`)                     | `SendToDevice(agent, "SEND_EVENT", …)`                                         | 4 lines                                 | below                                                |
| Structured telemetry (state/measurement/counter/fault/service) | `SendToDevice(agent, "REPORT_*", …)`                                           | 1 line per event                        | below                                                |
| Device roster → platform devices surface                       | Agent-side, per-SKU today                                                      | see the caveat below                    | below                                                |
| HTTP with promises + redaction, persistence, logging, timers   | `lib.http`, `lib.persist`, `lib.logging`, `drivers-common-public.global.timer` | require, don't rewrite                  | [§2](#2-day-one-the-skeleton)                        |
| Test harness that runs a whole driver with no controller       | `test/c4_shim.lua` + `make test`                                               | one test file                           | [§6](#6-testing)                                     |

The organising idea, from `docs/driver-cloud-charter.md`: **the Agent
(`smartbuildos.c4z`) is the only driver that holds account credentials and talks
to the platform.** Your driver never holds a token, never calls SmartBuildOS,
and never needs to know the API URL. It talks to the Agent over the bindingless
device path — exact-filename discovery plus `SendToDevice` into the Agent's
`EC.*` handlers — and the Agent does the rest.

### Health events and telemetry, without an SDK

There is no SDK wrapper for reporting; the Agent's handlers are generic and you
call them directly. The reference is Atmosphere's health forwarder
(`drivers/smartbuildos-atmosphere/driver.lua:854-879`):

```lua
local function findAgentId()
  for rawId, device in pairs(C4:GetDevices({}) or {}) do
    local file = tostring((type(device) == "table" and device.driverFileName) or "")
    -- Exact match, never substring (smartbuildos-insights.c4z is the near-miss).
    if file == "smartbuildos.c4z" or file == "smartbuildos.c4i" then
      return tonumber(rawId)
    end
  end
  return nil
end

C4:SendToDevice(agentId, "SEND_EVENT", { NAME = "Atmosphere: " .. name, DETAIL = detail })
```

The Agent handlers you can address this way (`drivers/smartbuildos/driver.lua`):

| Command                | Params                            | Behaviour                                                                 |
| ---------------------- | --------------------------------- | ------------------------------------------------------------------------- |
| `SEND_EVENT`           | `NAME`, `DETAIL`                  | Sent immediately as a platform event (line 6017).                         |
| `REPORT_STATE`         | `NAME`, `VALUE`                   | Queued as `CUSTOM` telemetry (line 5970).                                 |
| `REPORT_MEASUREMENT`   | `NAME`, `VALUE` (numeric), `UNIT` | Non-numeric `VALUE` is refused loudly, never shipped as text (line 5977). |
| `REPORT_COUNTER`       | `NAME`                            | Queued, value 1 (line 5996).                                              |
| `REPORT_FAULT`         | `NAME`, `DETAIL`                  | Queued (line 6003).                                                       |
| `REPORT_SERVICE_EVENT` | `NAME`, `DETAIL`                  | Queued (line 6010).                                                       |

The `REPORT_*` family **queues** and batches; `SEND_EVENT` sends at once. All
`REPORT_*` events land as category `CUSTOM` with privacy `INTEGRATOR_ONLY` — the
driver does not get to decide privacy class. Everything is a no-op when no Agent
is installed, which is the correct behaviour: reporting is never the reason a
home stops working.

⚠ **Device rosters are not yet generic.** The Agent forwards a device roster to
the platform's `devices` surface, but the entry point is
`EC.SBOS_PROTECT_ROSTER` and the SKU is hardcoded (`forwardDeviceRoster`,
`drivers/smartbuildos/driver.lua:6683-6734`:
`local sku = source == "unifi-protect" and "SBOS_UNIFI_PROTECT" or ""`). A new
driver that wants its devices in the fleet view needs that generalised first — a
`sku` param on the command and the map removed. Treat it as work, not as a
capability you can call today.

______________________________________________________________________

## 2. Day one: the skeleton

Four files. `test/test_driver_xml_guard.lua` walks every `drivers/*/` and fails
the suite if the first two are wrong, so you find out at `make test` rather than
in a project.

```
drivers/<your-driver>/
  driver.xml          the manifest Director reads
  driver.lua          the code Director runs — ONLY if driver.xml says so
  driver.c4zproj      the package manifest
  www/documentation/index.md   dealer docs (built to HTML + PDF)
  www/icons/device_sm.png, device_lg.png
```

### driver.xml — the shape that actually loads

```xml
<devicedata>
  <name>Your Driver</name>
  <version/>                       <!-- EMPTY in source; the build stamps it -->
  <manufacturer>SmartBuildOS</manufacturer>
  <model>Your Driver</model>
  <creator>SmartBuildOS</creator>
  <control>lua_gen</control>
  <controlmethod>ip</controlmethod>
  <driver>DriverWorks</driver>
  <copyright>Copyright 2026 SmartBuildOS. All rights reserved.</copyright>
  <created>08/31/2026 12:00:00 PM</created>
  <modified/>
  <combo>true</combo>              <!-- see the combo/proxy decision below -->
  <minimum_os_version>3.2.0</minimum_os_version>
  <composer_categories><category>Others</category></composer_categories>
  <events> … </events>
  <config>
    <script file="driver.lua" jit="1"/>   <!-- ⚠ WITHOUT THIS, NO LUA RUNS -->
    <documentation file="www/documentation/index.html">Documentation</documentation>
    <actions> … </actions>
    <properties> … </properties>
  </config>
</devicedata>
```

⚠⚠ **`<script file="driver.lua" jit="1"/>` is the element that has already cost
a field install.** Three Bond drivers shipped without it on 2026-08-30: Director
rendered their properties perfectly from the XML and never loaded a line of Lua.
Driver Status stuck on its "Starting" default, no version, no license
registration — and *every Lua test passed*, because Lua tests load the source
directly and only the XML knows whether a controller ever will.
`test/test_driver_xml_guard.lua:59` pins it, along with a `driver.lua` existing
next to the XML and `<version/>` being empty in source.

⚠ **`<version/>` must stay empty in source.** `make update-xml-version` stamps
it from the `VERSION` file at build time. A hardcoded version makes Composer
skip updates silently — pinned by the same guard (line 67).

### combo vs proxies — a decision with a field cost on both sides

| Your driver                                            | Element                                                            | Consequence                                                                                                                                                                                                                                                                                |
| ------------------------------------------------------ | ------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Has no Navigator UI (gateway, agent, manager)          | `<combo>true</combo>`                                              | Director gives it a self-proxy; no Navigator device is created. `smartbuildos.c4z`, `bond-bridge`, `smartbuildos-mode-composer` are all combo.                                                                                                                                             |
| Has a Navigator UI (`camera`, `uibutton`, light, fan…) | **omit `<combo>`**, declare `<proxies>` + matching `<connections>` | `drivers/unifi-protect-camera/driver.xml:13-17` records why in a comment: combo tells Director the driver "does not use a proxy" and no Navigator UI is provided — with it, the camera proxy device is never created, the room's camera list stays empty, "cost a field install to learn". |

Atmosphere is the middle case: a proxy driver with one `uibutton` (binding 5001)
carrying a WebView, plus provider `TEMPERATURE_VALUE`/`HUMIDITY_VALUE`
connections (`drivers/smartbuildos-atmosphere/driver.xml:385-440`).

⚠ Also measured (2026-08-29): a third-party DriverWorks `<agent>true</agent>`
did **not** surface in Composer's Agents panel. The Agent itself is a normal
project driver for this reason — see the comment at the top of
`drivers/smartbuildos/driver.xml`.

### The house property block

Every driver in this repo carries the same four properties. Copy them:

```xml
<property><name>Driver Status</name><type>STRING</type><readonly>true</readonly>
  <default>Starting</default></property>
<property><name>Driver Version</name><type>STRING</type><readonly>true</readonly>
  <default>unknown</default></property>
<property><name>Log Level</name><type>LIST</type>
  <items><item>0 - Fatal</item>…<item>6 - Ultra</item></items>
  <default>3 - Info</default></property>
<property><name>Log Mode</name><type>LIST</type>
  <items><item>Off</item><item>Print</item><item>Log</item><item>Print and Log</item></items>
  <default>Off</default></property>
```

Wired in `OnDriverInit` / `OnDriverLateInit` exactly as Atmosphere does
(`drivers/smartbuildos-atmosphere/driver.lua:1668-1690, 1780-1788`):
`log:setLogLevel(Properties["Log Level"])`, `OPC.Log_Level` / `OPC.Log_Mode`
handlers, `CheckMinimumVersion("Driver Status")` as the first line of
`OnDriverLateInit`, then `UpdateProperty("Driver Status", "Online")` and
`UpdateProperty("Driver Version", C4:GetDriverConfigInfo("version"))`. Driver
Version exists for one reason: a stale cached `.c4z` has twice been mistaken for
code that did not work.

Use `LABEL`-type properties as section headers (`Status`, `Licensing`,
`Logging`) — that is how the Composer property sheet gets structure.

### driver.c4zproj

```xml
<Driver type="c4z" name="<your-driver>" squishLua="true">
  <Items>
    <Item type="dir" c4zDir="www" name="www" recurse="true" exclude="false"/>
    <Item type="file" name="driver.lua"/>
    <Item type="file" name="driver.xml"/>
  </Items>
</Driver>
```

`squishLua="true"` matters: `make gen-squishy` loads your `driver.lua` under the
shim, reads `package.loaded`, and generates a squishy manifest containing only
the modules you actually require (`tools/gen-squishy.lua`). You never
hand-maintain a module list — but a module you require conditionally at runtime,
and never at load time, will not be bundled.

### www/documentation/index.md

One markdown file per driver; `make docs` renders HTML into the `.c4z` and a PDF
into `dist/`. Follow the Atmosphere shape: what it is, Requirements (including
"Optional: the SmartBuildOS Agent driver for licensing…"), Setup as a numbered
list starting with "Add `<file>.c4z` via Driver > Add or Update Driver" and
"Confirm the **Driver Version** property populates". `make fmt-md` formats these
at `--wrap 80`.

### The require block that must not lose a line

```lua
require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")
-- REQUIRED, even though nothing here names it: `lib.http` calls the GLOBAL
-- `urlDo`, which this module defines.
require("drivers-common-public.global.url")
```

⚠ Dropping the `url` require means every HTTP request throws
`attempt to call a nil value (global 'urlDo')` **inside the handler's xpcall,
which prints and swallows it** — the driver just sits on whatever status it last
set. This shipped once in the connector with every test green. Each driver has a
`test_*_globals.lua` that loads it with *nothing* faked and fails if the line is
dropped (`test/test_bond_bridge_globals.lua`,
`test/test_unifi_protect_globals.lua`).

______________________________________________________________________

## 3. Licensing in five lines

`src/sbos/license.lua` is the whole client. From a real driver
(`drivers/bond-bridge/driver.lua:61, 1146, 1440-1448`):

```lua
local license = require("sbos.license")

-- in OnDriverLateInit
license.setup({ sku = "SBOS_BOND" })

-- the Agent's reply
EC.SBOS_ENTITLEMENT = function(tParams)
  license.onEntitlement(tParams)
end

-- a dealer-facing Action, for support calls
function EC.REFRESH_LICENSE()
  license.register()
  license.check()
end
```

`setup()` paints the status property and registers with the Agent. Atmosphere
also calls `license.register(); license.check()` right after setup
(`drivers/smartbuildos-atmosphere/driver.lua:1776-1778`) — harmless, since the
Agent's inventory is keyed by `sku` + device id.

### The status vocabulary (fixed — `license.lua:27-39`)

`AUTHORIZED_SUBSCRIPTION`, `AUTHORIZED_PERPETUAL`, `AUTHORIZED_GRACE`, `TRIAL`,
`NOT_ENTITLED`, `AGENT_UNAUTHENTICATED`, `ACCOUNT_SUSPENDED`,
`ENTITLEMENT_EXPIRED`, `CONTROLLER_MISMATCH`, `CLOUD_VALIDATION_REQUIRED`,
`LEGACY`. An unknown status degrades to `CLOUD_VALIDATION_REQUIRED`, never to a
crash. The default before any answer is `LEGACY`, and under `LEGACY`
`hasFeature()` grants everything — enforcement cannot precede issuance.

### `license.enforces()` is the ONLY refusal gate

```lua
if license.enforces() then
  reply({ ok = "false", reason = license.enforcementReason() })
  return
end
```

Three independent conditions must all hold before it returns true
(`license.lua:302-304`): the **server** set `enforcement = "enforce"` for this
SKU, **and** the status is one of the four definitive denials (`NOT_ENTITLED`,
`ENTITLEMENT_EXPIRED`, `ACCOUNT_SUSPENDED`, `CONTROLLER_MISMATCH`), **and**
nothing else. `CLOUD_VALIDATION_REQUIRED` and `AGENT_UNAUTHENTICATED` are
deliberately absent from the deny set: **uncertainty fails open.** A
SmartBuildOS outage must never dark a home. A malformed `enforcement` value
degrades to observe, never to surprise-enforce
(`test/test_sbos_license.lua:122-160` pins all of it).

`isOperational()` is a softer signal (true under authorized/grace/trial/legacy)
suitable for display and diagnostics. Do **not** use it as a refusal gate.

**Where to put the gate matters more than the gate.** Each adopter chose one
choke point and documented why:

| Driver                                              | Gated                                                                               | Never gated                          |
| --------------------------------------------------- | ----------------------------------------------------------------------------------- | ------------------------------------ |
| `unifi-protect` (`driver.lua:2510-2526`)            | `executeControl` — the one function every child's control routes through            | live video, detections, status reads |
| `smartbuildos-mode-composer` (`driver.lua:205-215`) | config writes                                                                       | mode activations (operational)       |
| `bond-bridge` (`driver.lua:1583-1587`)              | auto-provisioning new devices                                                       | everything already installed         |
| `smartbuildos-atmosphere`                           | nothing yet — enforcement ships `observe`; weather safety logic is exempt by design | all of it                            |

### driver.xml side

Four optional read-only properties, painted by the SDK if you declare them
(`license.lua:183-193`; `drivers/smartbuildos-atmosphere/driver.xml:294-322`):
`License Status` (default `No SmartBuildOS Agent Found`), `License Source`,
`Subscription Tier`, `SmartBuildOS Company` (each defaulting to `-`). A driver
that omits any of them is a silent no-op — `setDisplay` is `pcall`ed. Add an
Action or two (`Refresh License`, `Test SmartBuildOS Licensing`) so a dealer has
something to click.

`License Status` reads as the driver's **relationship with the Agent** first and
its license state second: `No SmartBuildOS Agent Found` →
`SmartBuildOS Agent Found - Not Linked` →
`SmartBuildOS Agent Found - Checking...` → `Licensed / Subscribed` etc. Under
live enforcement it appends `(read-only)`.

______________________________________________________________________

## 4. Cloud mirror + remote settings in five lines

`src/sbos/mirror.lua` is the companion SDK, same conventions, same fail-open
posture. It exists because of a measured fact (recorded at `mirror.lua:11-18`):
a driver-hosted Navigator page can reach its driver over the LAN, but a phone
off the home network cannot, and the Navigator JS API delivered nothing on real
hardware. So the driver hands its state to the Agent, the Agent posts it to
SmartBuildOS, and the page reads it back from a capability URL. The mirror also
feeds fleet dashboards and sampled history — useful even for a driver with no
web view.

```lua
local mirror = require("sbos.mirror")

mirror.setup({
  sku = "SBOS_X",
  port = MY_LAN_PORT,
  path = "/state",
  onView = function(url, handle)
    persist:set(P_CLOUD_VIEW, { url = url, handle = handle })
    publishWebViewUrl("cloud-ready")
  end,
})
EC.SBOS_DRIVER_STATE_ACK = mirror.onAck
EC.SBOS_DRIVER_CONFIG = mirror.onConfig(function(patch)
  return applySettingsPatch(patch, "smartbuildos")
end)

mirror.setToken(myToken)   -- tokens are usually minted lazily with the server
mirror.setRelayHost(controllerLanAddress) -- 127.0.0.1 hangs on measured OS 4.2 hardware
mirror.publish()           -- steady state, throttled to 60 s
mirror.publish(true)       -- something a remote viewer cares about changed
```

Atmosphere's wiring is at `drivers/smartbuildos-atmosphere/driver.lua:1343-1351`
(publish), `1382-1392` (acks), `1469-1479` (config), `1752-1770` (setup +
`restoreView` from persist so a restart advertises the URL immediately).

### What the driver must provide: a LAN JSON state route

The Agent fetches your state from **your own server at the controller's private
LAN address** — same controller, and inter-driver message size limits never
apply (`drivers/smartbuildos/driver.lua:1955-2019`). OS 4.2 hardware proved that
an Agent request to another driver's `CreateServer` listener through
`127.0.0.1` hangs without a callback; current drivers must pass their resolved
relay address with `mirror.setRelayHost()`. You therefore
need a `C4:CreateServer` listener with a `GET /state?k=<token>` route.

`src/atmosphere/uirelay.lua` is the reference router and is worth copying
wholesale — it is pure (no `C4`), chunk-safe, and tested:

- `M.parse(buffer)` returns `nil` while a request is incomplete, so
  `OnServerDataIn` can accumulate chunks; a malformed request line comes back as
  `method = "BAD"` for the router to 400.
- `M.route(req, token, provider)` — `/ping` is tokenless (reachability probe,
  leaks nothing), `/app` serves the page same-origin and tokenless (it ships in
  every `.c4z` and contains no secrets), **everything else requires `?k=`**.
  `OPTIONS` is answered 204 *before* the token wall, because CORS preflights are
  browser-generated and carry no secrets.
- `M.render(result)` emits the bytes, `Connection: close`,
  `Cache-Control: no-store`.

The driver owns the socket and caps the accumulation buffer at 64 KB
(`driver.lua:1245-1270`) so a flood cannot grow memory.

### The `onConfig` contract

`apply(patch)` receives the decoded settings table and returns an **array of
refusals** — empty when everything applied. That is exactly the shape a
versioned settings store already produces, which is why
`src/atmosphere/settingsstore.lua` drops straight in:

- `M.validate(patch)` returns `(clean, refused)` where each refusal is
  `{ path, reason }`. Field-by-field, never all-or-nothing: "a typo in one field
  must not discard nine good ones".
- `M.merge(doc, clean)` deep-merges and stamps `M.VERSION`.
- `M.load(stored)` migrates forward through `M.MIGRATIONS[n]`, fills gaps from
  defaults, and drops fields a *future* document carries that this schema does
  not understand.
- Unknown top-level keys are refused loudly; a **retired** key is
  accepted-and-ignored instead, so an older stored document never triggers a
  spurious warning (`settingsstore.lua:151-155` is the worked example).

The SDK does the rest: guards the SKU, decodes, `pcall`s your apply, and sends
`SBOS_DRIVER_CONFIG_ACK` back to the requester with `applied`, `refused` (a
count) and the echoed `settings_version`. An undecodable payload sends **no**
ack; a throwing apply sends no ack and does not propagate
(`test/test_sbos_mirror.lua:151-193`).

### What the platform gives back

`onAck` stores a **capability URL** and handle. Guards worth knowing:
non-`https://` URLs are refused (the URL ends up in a page and must never be a
downgrade), acks for another SKU are ignored (several SmartBuildOS drivers share
one controller and one Agent), and an identical ack does not re-fire `onView`.
`restoreView` applies the same https check and survives garbage.

Atmosphere puts the URL into the page by rebuilding the web view URL —
`?cloud=<url>&cid=<handle>&k=<token>` — and re-publishing `URL_CHANGED`
(`driver.lua:1304-1336`).

> ### ⚠ Three compat rules, each an invisible failure if missed
>
> These are not theoretical; each was a real deploy-order problem in the
> 2026-08-31 generalisation.
>
> 1. **New Agent, old platform → the generic route 404s.** The Agent retries the
>    legacy per-driver route rather than going dark, on a **404 only** — a 503
>    is an outage, not a routing problem, and must not retry
>    (`drivers/smartbuildos/driver.lua:2023-2045`). Deploy order between the
>    driver repo and the server is not controllable: a dealer updates drivers
>    whenever, and a rollback can move the server backwards.
> 1. **Old driver, new Agent → dual ack names.** A driver released before the
>    generic protocol listens for `SBOS_ATMOSPHERE_STATE_ACK`. When asked via
>    the legacy command the Agent sends **both** ack names
>    (`driver.lua:2010-2017`); without that the driver mirrors successfully and
>    never learns its capability URL. If you ever ship a per-driver command
>    name, you own this alias forever.
> 1. **`&d=<sku>` on the public read must stay OPTIONAL.** The shipped app
>    builds `<view_url>?c=<cid>&k=<token>` and cannot append it
>    (`drivers/smartbuildos-atmosphere/www/app/index.html:800-807`). The token
>    is per-install so the hash already picks one row; `d` only narrows.
>    Capability URLs are already baked into `web_view_url`s in the field — that
>    URL shape is frozen.

______________________________________________________________________

## 5. Registering the SKU

A driver is not real until four separate places know its SKU. Nothing errors if
you skip one — the capability simply never happens.

| #   | Where                                                                   | What                                                                                                                                                                               | Consequence if missed                                                                                                           |
| --- | ----------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------- |
| 1   | Platform repo migration                                                 | a `driver_catalog` row seeding the SKU (display name, description, category, tier, `subscription_included`, `perpetual_price_cents`, `supported_os_min`, `on conflict do nothing`) | entitlements, packages, events, installations all key off this row — without it the driver is invisible to Driver Cloud         |
| 2   | `.github/workflows/publish-to-store.yml`                                | a `sku_for()` case mapping every `.c4z` filename in your suite to the SKU                                                                                                          | CI prints `skip <file> (no catalog SKU)` and your build never reaches the store                                                 |
| 3   | `drivers/smartbuildos/driver.lua:7-12` — the Agent's `DRIVER_FILENAMES` | your `.c4z` filename                                                                                                                                                               | the Agent never auto-updates your driver; dealers update by hand forever                                                        |
| 4   | `drivers/smartbuildos/driver.lua:1824-1836` — `SKU_FILENAMES`           | `SBOS_X = { "your.c4z", "your-child.c4z", … }`                                                                                                                                     | remote settings are addressed by SKU on the platform and delivered to *devices* here; an unmapped SKU is simply not deliverable |

Suite children map to the **parent** SKU in both #2 and #4 — the Protect suite's
seven files all resolve to `SBOS_UNIFI_PROTECT`, the Mode Composer's two to
`SBOS_MODE_COMPOSER`. Deliberate: children inherit their entitlement through the
gateway.

⚠ **The Agent's `SKU_FILENAMES` mapping intentionally does not guess.** An
unknown SKU is not deliverable rather than pattern-matched — "an Agent that
predates a driver must never guess at filenames".

> **Contradiction worth knowing about (measured 2026-08-31, working tree):**
> `SBOS_BOND` and `SBOS_SONOS` exist in `drivers/*/driver.lua` and are absent
> from **all four** registries. `unifi-protect.c4z`,
> `smartbuildos-mode-composer.c4z` and every suite child are absent from the
> Agent's `DRIVER_FILENAMES`, which currently lists only `smartbuildos.c4z` and
> `smartbuildos-atmosphere.c4z` — so today those drivers do **not** auto-update
> even though they publish to the store. Also: `unifi-protect`, `bond-bridge`
> and the other suite parents each declare their own `DRIVER_FILENAMES` global,
> and **nothing reads it** — `grep` across `src/`, `vendor/`, `tools/` finds no
> consumer, and only `drivers/smartbuildos/driver.lua:4690,4703` passes a list
> to an updater, always its own. Those per-driver globals are inert in the OSS
> build (they belong to the DriverCentral branch). Do not assume declaring them
> in your driver buys you anything.

______________________________________________________________________

## 6. Testing

The whole suite is standalone LuaJIT scripts — no framework. Each file defines
its own `check(name, ok, detail)` counter, prints `ok`/`FAIL` lines, and exits
non-zero on failure. Copy the header from `test/test_sbos_mirror.lua`: a comment
block naming *the invariants a second adopter must be able to trust*, then the
fakes, then sections.

```sh
make test          # every test/test_*.lua, preloading the shim, first failure aborts
```

`make test` sets `LUA_PATH` to
`test/?.lua;src/?.lua;src/?/init.lua;vendor/?.lua; vendor/?/init.lua` and runs
`luajit -e "require('c4_shim')" <file>`. A test that defines its own `C4` still
wins, because it assigns after the preload (`Makefile:236-250`).
`test/run_test.sh` is a leftover from the upstream template — ignore it.

### Faking the world

```lua
-- BEFORE loading the driver.
package.preload["lib.http"] = function()
  return {
    get = function(_, url, headers, opts) … end,
    post = function(_, url, data, headers, opts) … end,
  }
end
package.preload["lib.persist"] = function()
  local store = {}
  return {
    get = function(_, k, default) if store[k] ~= nil then return store[k] end return default end,
    set = function(_, k, v) store[k] = v end,
    delete = function(_, k) store[k] = nil end,
  }
end
```

`lib.http` returns a Deferred; the drivers only ever call `:next(onOk, onErr)`
once and never chain, so resolving **synchronously** is faithful enough and
keeps the tests free of an event loop
(`test/test_smartbuildos_connector.lua:68-80`).

### The four harness traps

1. **`cloud-client-byte` preload stub.** Raw source carries *both*
   `--#ifdef DRIVERCENTRAL` branches — the preprocessor strips one only at build
   time — so `OnDriverInit` requires the DriverCentral cloud client that does
   not exist in the repo. Every driver test needs:

   ```lua
   package.preload["cloud-client-byte"] = function() return {} end
   ```

   Nine test files carry it. Omit it and the driver fails to init with a
   confusing require error.

1. **The shim's `UpdateProperty` silently no-ops for unknown properties.** The
   global `UpdateProperty` in
   `vendor/drivers-common-public/global/handlers.lua:487` returns early when
   `Properties[name] == nil`, and `c4_shim.lua`'s `C4:UpdateProperty` is itself
   a no-op. So: seed a `Properties` fixture containing **every** property your
   `driver.xml` declares, and override `C4:UpdateProperty` to write back into it
   —

   ```lua
   function C4:UpdateProperty(name, value) Properties[name] = tostring(value) end
   ```

   Otherwise every status assertion reads a stale default and the test looks
   like a code bug (`test/test_atmosphere_driver.lua:97-145`).

1. **GETs and POSTs land in separate request tables.** In the connector harness
   `getRequests` collects GETs and `requests` collects POSTs
   (`test/test_smartbuildos_connector.lua:82-126`). Asserting on the wrong one
   gives you a confident, wrong "no request was made".

1. **The shim is not the controller.** `C4:GetVersionInfo()` returns `"test"`,
   which fails `CheckMinimumVersion` and disables the driver before anything
   under test runs — override it to a real version. `C4:GetDriverConfigInfo`
   returns nil for every key, and `url.lua` concatenates `model`/`version` into
   a User-Agent, so stub it too. Neither `C4:urlPost` nor its siblings exist in
   the shim.

### What to pin

Look at what the SDK tests chose to assert — they are the contract:
exact-filename Agent discovery with the near-misses present in the fixture,
another SKU's messages being ignored, throttle vs urgent, https-only URLs,
garbage payloads surviving. Add a `test_<driver>_globals.lua` that loads your
driver with **nothing** faked, so the `drivers-common-public.global.url` require
can never be dropped.

______________________________________________________________________

## 7. Shipping

```sh
make bump-version   # VERSION -> MMDDYYYY, or advance today's .N
make build          # check-deps clean-build fmt preprocess gen-squishy
                    # update-xml docs package zip install-local
```

`build` ends with `install-local`, which copies every built `.c4z` into
`~/Documents/Control4/Drivers` — removing the step where a driver is built,
handed over, and the *old* one is loaded because nobody moved the file, "which
looks exactly like a code change that did not work".

⚠ **`make fmt-lua` passes explicit stylua flags**
(`--indent-type Spaces --column-width 120 --line-endings Unix --indent-width 2 --quote-style AutoPreferDouble`,
`Makefile:90-97`). A bare `stylua` picks up different defaults and **will retab
files across the repo** — which, in a repo where several sessions hold
uncommitted work, is a diff nobody wants. Always go through `make fmt-lua` /
`make fmt`. Note that `make build` runs `fmt` as its third step, so a build is
never a read-only operation on someone else's files.

### Release → store

1. `git tag vX && git push --tags` fires `.github/workflows/release.yml`, which
   waits for the Build workflow, downloads its `oss` artifacts, and creates the
   GitHub release with the `.c4z`/`.pdf`/`.zip` attached.

1. ⚠ **That release does NOT trigger `publish-to-store.yml`.** A release created
   by another workflow's `GITHUB_TOKEN` does not cascade events — by GitHub's
   design, and called out in the workflow's own header comment. Every automated
   release therefore needs a manual dispatch:

   ```sh
   gh workflow run publish-to-store.yml -f tag=<tag>
   ```

   (A release created by hand with `gh release create` *does* fire it.)

1. The workflow reads each `.c4z`'s **internal** `<version>` from its
   `driver.xml` — not the tag — maps the filename through `sku_for()`, and
   uploads base64 to the store. A prerelease publishes to `BETA`; a normal
   release to `STABLE`, and only `STABLE` advances the catalog's advertised
   `current_version`. It is dormant until `STORE_UPLOAD_URL` and
   `STORE_UPLOAD_SECRET` are set.

### ⚠ Field-test from RELEASE downloads, not bench builds

`make build` stamps whatever is in `VERSION` (`MMDDYYYY` or `MMDDYYYY.N`) and
never bumps it implicitly — deliberately, so rebuilding the same source is
reproducible. The consequence: **a local bench build and the official release
can carry the identical version string.** Nothing on the controller can tell
them apart, so "which build is this?" stops being answerable exactly when it
matters. For any field pass, install the `.c4z` downloaded from the GitHub
release (or delivered by the Agent's updater), not the one `install-local`
dropped in your Drivers folder.

Related: `src/lib/driver-version.lua` compares across schemes so returning to
dates from the older `YYYYMMDD.HHMMSS` timestamps can never read as a downgrade.
⚠ The date scheme is **cross-repo** — the platform string-compares uploaded
versions, so a change to the format has to land in both repos together.

______________________________________________________________________

## 8. Traps already paid for

Each of these cost a release, a field visit, or a debugging session. One line
each; the citation is where the full story lives.

| Trap                                                                                                               | Consequence                                                                                                                                                                                                                                                                                                          | Where                                                                             |
| ------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------- |
| Agent discovery must be **exact filename** (`smartbuildos.c4z` / `.c4i`)                                           | a substring also matches `smartbuildos-atmosphere.c4z` and `smartbuildos-insights.c4z`, so licensing talks to the wrong driver                                                                                                                                                                                       | `license.lua:129-148`, pinned in both SDK tests                                   |
| Missing `<script file="driver.lua" jit="1"/>`                                                                      | properties render, **no Lua ever loads**; every Lua test still passes                                                                                                                                                                                                                                                | `test/test_driver_xml_guard.lua`                                                  |
| `C4:AddVariable` order is **frozen**                                                                               | Composer binds computed ids by add order — reordering silently re-points existing programming. Append only, add them in `OnDriverInit`                                                                                                                                                                               | `drivers/smartbuildos-atmosphere/driver.lua:92-93`                                |
| XML `<events>` register only when an instance is first added                                                       | always re-`C4:AddEvent(id, name, desc)` at init, inside `pcall`; **event ids are permanent**                                                                                                                                                                                                                         | `drivers/bond-bridge/driver.xml:30-32`, `atmosphere/driver.lua:1692-1696`         |
| `persist:get(key)` with **no default** returns a shared EMPTY **table**, not nil                                   | a `type(x) == "table"` check passes on nothing, and adopting the read table directly shares one object across keys — copy element-wise into a fresh table                                                                                                                                                            | `src/lib/persist.lua:100-122`, worked around at `atmosphere/driver.lua:1707-1722` |
| `C4:AddDevice` — use the simplest documented form `(file, callback)`                                               | the three-argument form with a name where the **room id** belongs is undocumented and measured returning 0 for every device; the callback carries no context, so queue strictly one add in flight and rename on a short timer *after* the batch (the callback's id is the protocol device, Composer shows the proxy) | `drivers/unifi-protect/driver.lua:2681-2760`                                      |
| Navigator **will not change the URL of an open web view**                                                          | a `URL_CHANGED` push only lands on the next open; tell dealers to close and reopen the tile                                                                                                                                                                                                                          | `docs/atmosphere/WEBVIEW.md:37-38`, `docs/atmosphere/TROUBLESHOOTING.md`          |
| A notify sent **before the project finishes starting is silently lost**                                            | the driver republishes the web view URL 60 s after startup for exactly this; a blank tile after a reboot is this, not your page                                                                                                                                                                                      | `atmosphere/driver.lua:90, 1816-1821`                                             |
| `env(safe-area-inset-bottom)` in the C4 mobile app **already includes** the app's own bottom bar (~78 px)          | `inset + 84px` doubles the clearance and pushes your nav off-screen; the pill sits at `inset + 10px`, field-verified                                                                                                                                                                                                 | `www/app/index.html:373-387`, `docs/atmosphere/WEBVIEW.md:210-220`                |
| `GetBindingsByDevice` returns bindings **nested under a `bindings` array**, not the flat shape the reference shows | indexing the top level rejects every device while pairing/heartbeat/ping all work; deep-walk it (depth-bounded, cycle-guarded) and try `GetNetworkBindingsByDevice` too                                                                                                                                              | `atmosphere/driver.lua:1117-1169`                                                 |
| `Http:request` rejects on **any** non-2xx                                                                          | a handler that reads rejection as "unreachable" reports a revoked token (401) as a network outage; branch on `err.code`                                                                                                                                                                                              | connector, `test_smartbuildos_connector.lua` header                               |
| `<combo>true</combo>` on a driver that needs a Navigator UI                                                        | Director never creates the proxy device; the room's camera/UI list stays empty                                                                                                                                                                                                                                       | `drivers/unifi-protect-camera/driver.xml:13-17`                                   |
| A bare `stylua` instead of `make fmt-lua`                                                                          | different config, retabs files across the repo                                                                                                                                                                                                                                                                       | `Makefile:90-97`                                                                  |
| A workflow-created GitHub release                                                                                  | does not cascade to `publish-to-store.yml`; dispatch it by hand                                                                                                                                                                                                                                                      | `.github/workflows/publish-to-store.yml:10-11`                                    |

______________________________________________________________________

## Reading order for driver #12

1. `docs/driver-cloud-charter.md` — why the Agent owns credentials.
1. `src/sbos/license.lua` and `src/sbos/mirror.lua` — both are short and both
   are commented as specifications, not as code.
1. `test/test_sbos_license.lua` + `test/test_sbos_mirror.lua` — the invariants
   your adoption must not break.
1. `drivers/smartbuildos-atmosphere/` — the reference adopter: licensing,
   mirror, LAN relay, versioned settings, web view, all in one driver.
1. `docs/control4-capabilities.md` — what the Control4 SDK will and will not do,
   each claim tagged VERIFIED_BY_DOCS / VERIFIED_BY_EXAMPLE / UNCONFIRMED.
1. `docs/atmosphere-architecture.md` §2 — the reuse audit, in table form.
