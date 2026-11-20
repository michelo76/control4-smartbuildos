# `device_poll.digest` — test vectors (contract item 1, `device_poll_v1`)

Use these to check the platform's digest against the Agent's. The expected hex
values were computed with `shasum -a 256` and with Python's `hashlib`, outside
this repo's code. The repo tests check them three times: against the system
`shasum` (`test/test_agent_studio.lua`), against the Director emulator's own
SHA-256 (`test/emulator/agent_studio_g1.lua`), and against the Agent's real
`C4:Hash` path under the emulator.

## The rule (from AGENT-CONTRACT-G1.md §1)

- Write one line per device row in the devices payload: `<key>:<state>`.
  - `<key>` is the row's `key` field, unchanged (for example `c4:123`, `ping:<host>`, `discovered:<ip>`).
  - `<state>` is `1` when `online` is `true`, `0` when it is `false`, and `u` when it is `null` or absent.
- Removed rows (`removed: true`) are not lines.
- Sort the lines ascending by **`<key>`**, comparing the keys as **byte strings**.
- Join the lines with `\n`. Do not add a trailing newline. Encode as UTF-8.
- Zero devices hashes the empty string.
- The digest is the SHA-256 of that string, as 64 lowercase hex characters.

### Two traps

1. **Sort by key, not by whole line.** Take `c4:1` and `c4:10`.
   - By key, `c4:1` comes before `c4:10`, because it is a prefix.
   - By whole line, `c4:10:0` comes before `c4:1:1`, because `0` (0x30) is lower than `:` (0x3A).
   - Vector A pins this case. Its wrong-order digest is listed below so the mistake is easy to recognise.
2. **Compare bytes, not locale order.** On stock Lua 5.1, string `<` uses `strcoll`, so the order depends on the controller's locale.
   - The Agent therefore sorts with an explicit byte comparison (`AgentStudio.byteLess`).
   - On the server, sort by UTF-16 code unit (the JavaScript default) or by `Buffer`. Never use `localeCompare`.
   - Keys are ASCII today, so UTF-16 code-unit order and byte order agree.

## Vector A — mixed sources and states (7 devices)

| key | `online` on the wire | why | line |
|---|---|---|---|
| `c4:1` | `true` | addressed, binding `online` | `c4:1:1` |
| `c4:10` | `false` | addressed, binding `offline` | `c4:10:0` |
| `c4:2` | `null` | binding address `NOT_SET` | `c4:2:u` |
| `c4:99` | `null` | no network binding (IR); `connection_type: null` | `c4:99:u` |
| `discovered:192.168.1.60` | `true` | SSDP-discovered | `discovered:192.168.1.60:1` |
| `ping:192.168.1.99` | `false` | ping target, no answer | `ping:192.168.1.99:0` |
| `ping:nas.local` | `true` | ping target | `ping:nas.local:1` |

Input: 92 bytes, shown with `\n` written out.

```
c4:1:1\nc4:10:0\nc4:2:u\nc4:99:u\ndiscovered:192.168.1.60:1\nping:192.168.1.99:0\nping:nas.local:1
```

The same input, one line per row:

```
c4:1:1
c4:10:0
c4:2:u
c4:99:u
discovered:192.168.1.60:1
ping:192.168.1.99:0
ping:nas.local:1
```

**Expected digest:** `0ef1484482b04ba81a3cdf97804ac0d95aca5d66834ea78ae1f5a9aadb0a911d`

Block counts: `devices: 7`, `offline: 2`, `unknown: 2`.

**Wrong-order digest:** `7cc8fa04c54bd3012d53d3876c0b60fceeb66ca518c2403fed5cc5ae7ea94fba`. An implementation that sorts by whole line instead of by key produces this value. It must NOT match.

## Vector B — zero devices

Input: the empty string.

**Expected digest:** `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`

## Vector C — one device

Input: `c4:42:1` (no newline).

**Expected digest:** `6302f52fab81bcdc4c8757fcbd369a064c11fd12e8ddadbc7f6d3a51b59b95e6`

## Reproduce

```sh
printf 'c4:1:1\nc4:10:0\nc4:2:u\nc4:99:u\ndiscovered:192.168.1.60:1\nping:192.168.1.99:0\nping:nas.local:1' | shasum -a 256
printf '' | shasum -a 256
printf 'c4:42:1' | shasum -a 256
```

```js
// Node — the platform side
const crypto = require("crypto");
const rows = [["c4:1", true], ["c4:10", false], ["c4:2", null], ["c4:99", null],
  ["discovered:192.168.1.60", true], ["ping:192.168.1.99", false], ["ping:nas.local", true]];
const input = rows
  .map(([k, o]) => [k, o === true ? "1" : o === false ? "0" : "u"])
  .sort(([a], [b]) => Buffer.compare(Buffer.from(a), Buffer.from(b)))
  .map(([k, s]) => `${k}:${s}`)
  .join("\n");
crypto.createHash("sha256").update(input, "utf8").digest("hex");
// → 0ef1484482b04ba81a3cdf97804ac0d95aca5d66834ea78ae1f5a9aadb0a911d
```

## Which rows the Agent hashes

- The Agent hashes the rows its last completed poll saw, after the 2,000-row ceiling has been applied. These are the same rows a snapshot sent at that moment would carry. Network-bound rows are kept first; the rest are kept in key byte order.
- The block rides the first delivered heartbeat after the poll.
- When the poll sent a delta, the block waits until that delta has been answered, whether it was delivered or failed. So the platform never compares the digest against rows it has not written yet.
- When `C4:Hash` does not answer, the Agent sends the block without `digest`. Treat that as "no match", never as a match.
