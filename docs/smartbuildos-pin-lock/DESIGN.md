# PIN Lock — design

Status: implemented on `feat/dealer-tools`; simulator-verified
(`test_pinlock_engine.lua`, `test_pinlock_relay.lua`, `test_pinlock_driver.lua`);
nothing run on a controller yet. SKU `SBOS_PIN_LOCK`, module id `pin_lock`
(reserved in the Agent and bound to `smartbuildos-pin-lock.c4z`; the driver
joins the module bus for AI Core verification only, see "AI Core
verification" below). Marketing name: "PIN-gated actions and keypad
sequences".

## What it is, and what it is not

A gate in front of actions that pass THROUGH the driver. A guarded action is a
named slot (1..12); a valid code asking for it fires a Composer event and may
command one lock/relay target. A Control4 driver cannot hide a room or a
device in the native Navigator, so a lock that is also visible there is not
protected; the manual says so first and tells the dealer to remove the lock
from the Navigator. No wording in the driver, page or docs refers to what is
being locked up beyond neutral examples (wine cellar, garage service door,
alarm zone).

Pure engine `src/pinlock/engine.lua` (injected clock, HMAC, calendar);
`src/pinlock/relay.lua` is the pure HTTP router; `src/pinlock/challenge.lua`
is the AI Core challenge store; `driver.lua` maps engine events to Composer,
the target device and the Flight Recorder, and serves the module bus.

## Rules (all tested)

| Topic | Rule |
| --- | --- |
| Codes | name ≤ 40 (unique, case/space-blind), role owner/staff/vendor/guest, ≤ 60 codes |
| PIN | 4..8 digits, accepted by `guestmode.pin.isAcceptable` (no repeat, run, alternation); never shared by two codes |
| Sequence | exactly `seqLength` (3..8) button tokens of 1..4 alphanumerics, joined `-`; never shared |
| Action rights | owner: every action; others: the ticked set. A sequence names one action (`keypad_action`) |
| Hours | optional weekdays + `HH:MM`..`HH:MM` (end exclusive, overnight allowed, belongs to the day it starts) on the controller's local time |
| Dates / uses | optional start, expiry (end of day), max uses; use counted on grant only |
| Temporary | guest role, `hours` 0..8760, same-name temporary code is replaced (a failed replacement keeps the old one), pruned 24 h after expiry |
| Last owner | cannot be disabled, revoked or demoted |
| Lockout | per entry point `page` / `keypad` / `admin` (AI Core verification, entry `ai_core`, counts in `page`: one bucket); `maxFails` (3..10) → locked `lockSeconds`; every denial counts (a valid PIN outside its hours too, so there is no oracle); a success does NOT reset the count (else one valid PIN allows endless guessing); failures decay after 10 quiet minutes; locks persisted with absolute expiry |
| Locked attempts | refused without evaluating; recorded at most once per 30 s per entry point; *Access Denied* is not re-fired |
| Keypad | per-keypad buffer (≤ 8); the whole sequence must finish within `seqWindow` of its first press; a complete buffer = exactly one attempt; partial timeouts are not attempts; no sequence code defined → presses are ignored (no attempts, no buffers) |
| Admin | owner PIN → in-memory session (32 hex, 10 min sliding, ≤ 4), attempts count against `admin`; first owner can be created only while none exists |

## Secrets

* **Storage.** Salted, iterated HMAC-SHA256 digests (`C4:HMAC`, 100 rounds,
  per-code salt, the secret mixed into every round, `it` stored per
  credential so it can be raised later). Persisted under one key in the
  controller's ENCRYPTED persist store; plaintext PINs and sequences exist
  only in the call stack of the attempt. There is no weaker fallback if
  `C4:HMAC` fails: the attempt errors.
* **Limits stated plainly.** A 4..8 digit PIN is brute-forceable offline by
  anyone who can read the store; the digest and encryption only stop casual
  reading. The defence is the lockout and the encrypted store.
* **Compare.** Walks the full length without an early exit; every code is
  always tried so the time does not say which code matched.
* **Never logged.** The engine returns reasons and code names only. The
  driver never passes a secret to `log:*`, `UpdateProperty`, `SetVariable`,
  a command to another device, a relay reply or a recorder marker; PIN-bearing
  commands are on `EC.suppressDebug` (`ADD_TEMPORARY_CODE`, `KEYPAD_PRESS`).
  `test_pinlock_driver.lua` runs the whole story at Trace with handler debug
  on and scans every channel for the PINs, the sequence, and every stored hash
  and salt. Mutating the suppress list makes it fail.
* **Known weakness that remains.** Guest Mode puts PINs in Trace-level logs;
  that is not copied here. But a PIN typed into a Composer programming line
  (`ADD_TEMPORARY_CODE`) lives in the project file in clear text, which the
  driver cannot prevent (documented in the manual). The page sends PINs in
  POST bodies over plain LAN HTTP, behind a per-install token carried in the
  web view URL. The first-owner bootstrap is open to anyone who can load the
  page until an owner exists.
* **No secret properties.** The driver has no PIN property at all, so no
  `PASSWORD` property type is needed.

## Licence behaviour (decision)

`license.enforces()` (definitive denial AND server enforcement on) puts the
gate in a RESTRICTED state, not a halt:

* owner-role codes keep firing every action and keep signing in to admin, so
  the owner is never locked out of their own gates;
* every other code is refused with reason `licence`;
* nothing that adds access: add, temporary, edit of a non-owner, enabling a
  non-owner is refused; removing access (disable, revoke, clear lockouts,
  remove all) always works;
* events *Licence Restricted* / *Licence Restored* fire on the edges.

Anything uncertain (no Agent, unanswered, cloud unreachable) is not
enforced: it fails open, as everywhere else. Tested in engine and driver.

## Composer surface

Events: 1 Access Granted, 2 Access Denied, 3 Entry Point Locked Out,
4 Licence Restricted, 5 Licence Restored, 11..22 Guarded 1..12 Granted.
Commands: `ENABLE_CODE`, `DISABLE_CODE`, `REVOKE_CODE`, `ADD_TEMPORARY_CODE`,
`KEYPAD_PRESS`, `CLEAR_LOCKOUTS`. Conditionals: `CODE_ACTIVE`,
`ENTRY_LOCKED` (STRING, `=` / `!=`; the logic pack's pattern, because a
conditional gets one value). Variables 3000..3007. Properties for AI Core: `AI Core` (read-only, painted
by `sbos.aireport`), `AI Core Approvals` (read-only, plain words: whether AI
Core may use PIN verification now, and why not) and `AI Core PIN
Verification` (dealer switch, see below). Actions tab: Print State,
Clear Lockouts, Refresh Device Lists, Republish App URL, Remove All Codes,
Register With Agent Now, Refresh Status.

Targets: `Guarded N Target` is a `DYNAMIC_LIST` filled by
`C4:UpdatePropertyList` with `Name (Room) · id`, narrowed by a word filter
(default `lock,relay,gate,door,garage,strike`; `*` = all). `Guarded N Target
Action` maps to `UNLOCK/LOCK/OPEN/CLOSE/TOGGLE/TRIGGER` (the same names the
System Link export commands use). `Re-lock After Seconds` follows an `Unlock`.
No `DEVICE_SELECTOR` or `PASSWORD` property type is used.

The driver is a proxy driver (`uibutton` proxy, Web View on binding 5001, like
the Variable Inspector), so it carries no `<combo>` element; the
proxy-less-driver rule does not apply.

## Transport

Atmosphere's LAN relay on port 47831 (taken after 47815, 47821..47823); address
resolution through `lib.relayhost`. Routes are in `src/pinlock/relay.lua`.
Replies to the keypad user are generic (`Done` / `not allowed` / `locked`,
with `retry_in`); reasons go to variables and the recorder only.

## AI Core verification (owner PIN on the AI Core touchscreen)

AI Core (brief D5) may ask for an owner PIN before it shows an approval or
unlocks its touchscreen chat. **AI Core never sees the PIN and no module-bus
frame carries it**: the AI Core page posts the PIN to THIS driver's relay
against a challenge, and AI Core learns only the outcome. Unit, bus-level
and emulator tests only; nothing here has run on a controller.

**Module bus.** The driver registers as `pin_lock` (`sbos.moduleclient`,
`singleton = true`, protocol 2 only, `claim_driver_config = false`) and
attaches `sbos.aireport` to that client, which paints the `AI Core` property
and sends the baseline describe/state reports. `aireport.start` is not used
because it cannot advertise a driver's own capabilities; `attach` is the
documented mode for a driver that runs its own client. Manifest:
`pinlock.availability`, `pinlock.challenge`, `pinlock.redeem` (v1, kind
`request`). The Agent's policy routes them from `ai_core` only; the driver
refuses `not_permitted` as well unless the requester is the `ai_core`
instance its own directory view lists as **verified** (identity binding).

| Capability | args (closed keys) | ok result | errors |
| --- | --- | --- | --- |
| `pinlock.availability` | `{}` | `{ready, reason, retry_in?}`; reason `ready \| starting \| off \| unlicensed \| no_owner_pin \| relay_unavailable \| locked` | `invalid_args`, `not_permitted` |
| `pinlock.challenge` | `{purpose: "approval" \| "chat_view", subject, nonce}`; subject = the proposal uuid (approval) or a 32-hex page session id (chat_view); nonce = 32 lowercase hex, minted by AI Core | `{challenge_id (32 hex), expires_in: 60, verify_url: "http://<controller>:47831/verify"}` | `invalid_args`; `unsupported` + `{reason}` (not ready, reasons as above); `rate_limited` + `{reason: "busy"}` (8 open); `not_permitted` |
| `pinlock.redeem` | `{challenge_id, nonce, purpose, subject}` | `{verified: true, verified_at (whole epoch seconds), role: "owner"}` or `{verified: false, reason: not_verified \| expired \| locked \| wrong_subject \| unknown}` | `invalid_args`, `not_permitted` |

A verified redeem carries exactly these three keys (spec rulings 21 and 22).
There is no `slot`: a code's position in the list shifts when a code is
revoked, so it identifies nothing reliably, and the cloud records only
"approved at the touchscreen with an owner PIN". `verified_at` is the moment
`/verify` accepted the PIN, as whole epoch seconds from the controller's
clock (every timestamp on the AI Core wire is epoch seconds; the controller's
clock may be skewed, which the cloud tolerates within a bounded window).
**Nothing that identifies which owner code was typed leaves PIN Lock on this
path, and the code name is never returned, recorded for this path or sent
anywhere** (owner ruling): no field of any answer, no recent-list entry, no
event, no recorder marker carries it. The challenge store keeps only the
role from the engine's result; the engine's local slot is not copied.

**De-duplication is per sender.** The bus client remembers its answers keyed
by the Agent-stamped sender (`from_module_id` + `from_instance_id`) together
with `request_id`. A frame from any other sender that reuses the request id
of a stored "verified" redeem is a new request: it reaches the requester
check (`not_permitted`), never the stored answer.

**`POST /verify`** `{challenge_id, pin}` (exactly these two string keys; no
page token: the challenge authenticates it). Answers, rebuilt by the router
from constants whatever the driver returned:

| HTTP | Body |
| --- | --- |
| 200 | `{"ok":true}` |
| 401 | `{"ok":false}` (wrong PIN, not an owner code, unknown / expired / already-attempted challenge, feature off) |
| 429 | `{"ok":false,"locked":true,"retry_in":N}` (the page bucket is locked; the PIN Lock page already shows `retry_in`) |
| 400 / 405 / 500 | `{"ok":false}` |

Never the code name, the role, which digit was wrong or why.

**Challenges** (`challenge.lua`, in memory only): at most 8 open; the 9th is
**refused** (`busy`), never evicting one a person may be typing against;
valid 60 s from issue for `/verify` and for redeem alike; one `/verify`
attempt each (a second post answers `{ok:false}` without checking a PIN);
consumed by the first redeem whatever its answer; bound to purpose +
subject + nonce + the requesting AI Core instance. A redeem naming another
purpose, subject or nonce answers `wrong_subject` and consumes it, so an
approval grant can never unlock the chat and a chat unlock can never approve.
A restart, the dealer switch going Off, or Remove All Codes forgets every
challenge. The id is 32 hex from `C4:HMAC` over the controller's random UUID
(when Director offers one), the clock, a counter and `math.random`; there is
no weaker fallback.

**Who may verify: owner-role codes only** (`Engine:verifyOwnerPin`). Staff,
vendor and guest codes are refused whatever guarded actions the dealer gave
them; there is no setting that widens this. Validity still applies (a
disabled, not-yet-started, expired or used-up owner code, or one outside its
hours, is refused). A verification fires no guarded action and no *Access
Granted* event (programming attached to that event unlocks things); a
refusal fires *Access Denied* like any other denial.

**One lockout.** Entry `ai_core` counts in the `page` bucket
(`Engine.LOCK_BUCKET`): AI attempts lock the page and page attempts lock AI
verification, with the same `Max Wrong Attempts` / `Lockout Minutes`, the
same persistence, and a success does not reset the count. *Clear Lockouts*
clears it.

**Availability and the dealer switch.** `AI Core PIN Verification` (LIST,
default `On when an owner PIN exists`, or `Off`). The spec does not set a
PIN Lock-side default, so verification is offered only while an active owner
code with a PIN exists, and the dealer can switch it off here. This is not
the homeowner's opt-in: touchscreen approvals stay off until the homeowner
turns them on in the portal (cloud side). AI verification also needs the
licence (a licence-restricted PIN Lock answers `unlicensed`, although owner
codes keep working on its own page) and a listening relay. `AI Core
Approvals` shows the result in plain words.

**How the AI Core page reaches `/verify`.** It does not guess: the
`verify_url` comes back from `pinlock.challenge` (the address PIN Lock's
`lib.relayhost` resolved, port 47831). The relay answers `OPTIONS` and sends
`Access-Control-Allow-Origin: *`, `Allow-Methods: GET, POST, OPTIONS`,
`Allow-Headers: Content-Type`. **Unverified:** that Navigator's web view
lets a page served from AI Core's relay (another port, so another origin)
`fetch` PIN Lock's port, preflight included; and the page's CSP must list
PIN Lock's origin in `connect-src`. Over plain LAN HTTP the PIN is as
exposed on the wire as it already is on PIN Lock's own page.

## Flight Recorder

Device lookup: the lowest-id device whose `driverFileName` is
`smartbuildos-flight-recorder.c4z`, cached 5 minutes. Command
`RECORD_EVENT` with `NAME` (≤ 120) and `DETAIL` (≤ 400), the recorder's
documented parameters (`CHANNEL` left unset). Markers: `PIN Lock granted:
<action>` (`code=<name> entry=<entry>`), `PIN Lock denied: <action|entry>`
(`reason=… code=… entry=…`), `PIN Lock locked out: <entry>`, `PIN Lock admin
sign-in`, `PIN Lock AI Core verification` (`role=owner entry=ai_core`, no
code name). Silent when no recorder exists. Code names are personal data that
then follows the recorder's retention and upload settings; the manual says so.
The in-memory recent list (20) is for the admin page only and is not persisted.

## Not included (v1)

* Hiding a device or room in the Navigator (impossible from a driver).
* Remote issue / revoke / audit through the cloud (contract below).
* Per-keypad lockouts (one `keypad` entry point covers all keypads).
* Pairing a keypad's own physical lock code with this store.
* A code per target device that is its own lock-code push (the lock drivers'
  user-code commands are not in the documentation we hold).
* The page never shows existing PINs, and cannot: they are not stored.

## Agent contract needed

Not implemented. The driver's only Agent traffic is the licence handshake
and the module-bus registration for AI Core verification (above). `src/sbos/envelope.lua` and the web repo are NOT edited by this
change. To let Studio see and manage codes, the Agent would need:

**1. Outbound audit (optional; the Flight Recorder already carries markers).**
If direct records are wanted instead, reserve a prefix in
`envelope.lua` `M.PREFIXES`: `pin_lock = { "pinlock." }`, module id `pin_lock`,
with event types `pinlock.attempt`, `pinlock.code_changed`, `pinlock.lockout`.
Payloads (≤ 4 KiB, strings ≤ 512 chars):

```json
{ "result": "granted|denied|locked", "code_name": "Marta", "code_id": "c1234",
  "action": "Unlock wine cellar", "entry": "page|keypad|admin",
  "reason": "outside_window" }
```
```json
{ "op": "added|updated|enabled|disabled|revoked|reset", "code_name": "Marta", "code_id": "c1234",
  "role": "staff", "actions": [1, 2], "expires": "2027-02-03T23:59:59",
  "has_pin": true, "has_seq": false }
```
`evidence_source`: `requested` for grants (a command was sent; the device
did not confirm), `observed` for denials and lockouts. `quality`:
`unreviewed_text` for names. Never a PIN, a sequence, a digest or a salt.

**2. Inbound code management.** A new Agent → driver command, same carrier as
`SBOS_COMMISSIONING_RESULT`'s sibling commands (`SendToDevice`):

`SBOS_PINLOCK_APPLY { request_id, op, json }` with `op` one of
`disable | enable | revoke | issue | update_window`, and `json` a document:

```json
{ "code_name": "Courier", "role": "guest", "actions": [2],
  "days": [3], "from": "09:00", "to": "12:00",
  "starts": "2027-01-06", "expires": "2027-01-07", "max_uses": 1,
  "credential": { "alg": "hmac-sha256-x100", "salt": "…", "hash": "…" } }
```
The driver would reply `SBOS_PINLOCK_RESULT { request_id, ok, reason }`.
`disable`, `enable`, `revoke` and the window fields need no secret at all and
can be built first. Under a licence restriction the driver applies
`disable` and `revoke` and refuses the rest, as locally.

**3. Only hashes may leave the controller; plaintext PINs never do.** The
driver never serialises a PIN, and `credential` above travels INTO the
controller. A PIN set remotely needs a delivery design; options, none built:

* *(A) Controller-issued challenge, digest computed in the dealer's
  browser — recommended.* Studio asks the Agent for a challenge; the driver
  answers `{ request_id, salt, iterations }` (single use, 5 minutes). The
  browser computes the same salted, iterated HMAC with WebCrypto, so the
  server and the Agent only ever handle `hash`. The dealer tells the guest
  the PIN out of band. The server never sees the PIN. Requires the digest
  algorithm in this document to be the stable wire contract (rounds, domain
  string `pinlock:`, `h = HMAC(salt, h .. ":" .. secret)`), and a duplicate-PIN
  check on the controller (it can say "already in use" without revealing
  whose).
* *(B) Server hashes with a controller salt.* Same message flow, but the PIN
  passes through the server for an instant. Simpler, weaker: a compromised
  server sees PINs. Not recommended.
* *(C) Encrypted one-time delivery of a PIN generated on the controller.* The
  driver generates a PIN and encrypts it to a public key supplied by the
  requester so only the dealer's browser can read it. Needs public-key crypto
  that the DriverWorks API is not known to offer (`C4:Encrypt` is symmetric
  with a key the cloud would also hold), so it is not available as designed.
* *Rejected:* sending the PIN in clear through Notification Router or SMS
  from the controller; it would put plaintext PINs into message history.

**4. Licensing.** Register SKU `SBOS_PIN_LOCK` in the entitlement catalogue
(the driver already registers through `sbos.license`).

## Bench checks owed

See the manual's "Unverified on a controller": `C4:HMAC` availability, the Web
View on a panel and phone, target command names against real lock and relay
drivers, Director's own logging of command parameters, keypad `KEYPAD_PRESS`
latency, large target lists, twelve event names in Composer, a real reboot with
a lockout running, and the recorder markers' appearance.
