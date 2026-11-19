# VenueFlow pages: how they are built

Two pages, each ONE self-contained HTML file served by the driver:

| Page | Template | Built to | Served at |
| --- | --- | --- | --- |
| Operator (four interfaces) | `ui/venueflow/operator/index.html` | `drivers/smartbuildos-venueflow/www/app/index.html` | `/app` |
| Installer Studio | `ui/venueflow/studio/index.html` | `drivers/smartbuildos-venueflow/www/studio/index.html` | `/studio` |

`python3 tools/venueflow-ui.py build` stitches the files named by the
`@include` markers of a template into the page. Each JavaScript file becomes
its own inline `<script>` block.

## Running the pages without a controller

```bash
python3 tools/venueflow-dev.py --port 47861
```

This runs the REAL Lua core and relay (`src/venueflow`) on the simulator with
the 24-display sports bar published (`VF_DEV_SAMPLE=conference_center` for the
conference centre). The pages are rebuilt on every page load.

- Operator: `http://localhost:<port>/app?k=devtile0123456789abcdef`
  (opens as the tile's default profile; the sample Manager PIN is `2580`)
- Operator with full access: sign in to the Studio first, then
  `http://localhost:<port>/app?as=studio` in the same tab
- Studio: `http://localhost:<port>/studio`, passcode `install-123`
- State is kept in `build/venueflow-dev-state-<port>.json`; delete the file to
  start again from the sample.

It is a simulator. Nothing seen here is evidence of controller behaviour.

## Rules for page code

1. **Plain script, ES2020, no modules, no framework, no build step.** The
   engine floor is Gecko 96 (Control4 T3/T4 touch screens) and current mobile
   web views. `?.`, `??`, arrow functions, `async`/`await`, template strings,
   `Object.entries`, CSS grid and flex `gap` are fine. No `structuredClone`
   dependence without a fallback (use `VF.clone`).
   `test/test_venueflow_engine_floor.lua` scans the sources and the built
   pages for features Gecko 96 lacks (and for secure-context-only APIs: the
   pages are served over plain HTTP) and names the file, line and feature.
   It is a static scan, not a run on a touch screen.
2. **No external resource of any kind.** The relay sends a Content Security
   Policy of `default-src 'none'` with inline script and style, `data:` and
   `blob:` images, and `connect-src 'self'`. No CDN, web font, remote image,
   `eval`, `new Function`, or inline `on...=""` attribute strings.
3. **Never the text `</script` inside a `.js` file** (it would end the inline
   block; the build refuses it).
4. **Build DOM with `VF.h`**, never `innerHTML` with data. Names come from the
   installer and are untrusted text.
5. **Read every collection through `VF.asList` / `VF.asMap`.** The
   controller's JSON encoder writes an empty table as `[]` whether it was a
   list or a map.
6. **The driver is the authority.** A page stores nothing but its session
   token (`VF.session`, sessionStorage). No `localStorage`. A small view
   preference (last tab) may live in memory or sessionStorage.
7. **Never claim success the driver did not report.** A reply with
   `status: "accepted"` means "sent"; the outcome is in the state document's
   cells and `operations`. A `partial` reply names what failed. Use
   `VF.toastReply`, `VF.statusChip`, `VF.outcomeChip`, `VF.outcomeList`.
8. **Hide what a profile cannot do, and still handle `VF_FORBIDDEN`.**
   Permissions are enforced in the driver; the page only avoids offering what
   will be refused.
9. **Touch first.** Targets at least 44 px (`--touch` is 48 px; `.btn.sm` is
   36 px and is kept for secondary actions). No hover-only affordance.
   Screen sizes measured (November 2026, against the simulator, both
   sample venues, with touch emulation; desktop engines, NOT a T3, a T4 or
   a phone): every control of the operator page can be reached, by
   scrolling where needed, and is not covered by another element, at
   1024x600 (T3 7"), 1280x800 (T3 10", T4 8"), 1920x1200 (T4 10"),
   1180x820 and 820x1180 (tablets), 390x844 and 844x390 (phones), in all
   four interfaces and with a display selected, all displays selected, the
   source picker, a remote, a zone sheet, the All Off preview, the profile
   menu, the offline banner and the sign-in PIN pad open. The Venue Studio
   (a client session) passes the same check at 390x844, 820x1180, 1024x600
   and 1280x800; the Installer Studio at 1024x600, 1024x768, 1280x800 and
   1920x1200 (it is not meant for phones). First measured in desktop
   Chromium; on 19 November 2026 the same measurement ran in Chromium 159,
   WebKit 27.2 and Firefox 159 (Playwright 1.65) with the same result in
   all three: nothing unreachable or covered, no sideways scroll, the same
   clipped-text findings, touch-target sizes within 1 px of each other.
   Firefox 159 is the engine family of the touch screens, not their
   version: a pass there is evidence about Gecko layout and events, not
   proof for Firefox 96 (the static guard above covers the features).
   WebKit with the iPhone 15 and iPad (gen 7) descriptors is the nearest
   thing here to the iOS app; it does not show Safari's toolbars, so the
   pages size the shell with `height: 100%` and the dialogs from their
   backdrop, never from `100vh`. Re-check any layout change at 1024x600
   first.
   **Engines.** On 19 November 2026 every operator flow (sign-in on the PIN
   pad, the four interfaces, selecting on the plan, routing, power, volume,
   mute, scenes, open and close, the source remote, "Which display?", the
   profile menu, the offline banner with the simulator paused and stopped),
   every Installer Studio section and flow (source edit and autosave, a
   Layout Designer drag with pointer capture, a floor picture through the
   file input, a scene step, dry run, publish, rollback, the two-tab stale
   draft) and the Venue Studio flows ran in Chromium 159, WebKit 27.2
   (desktop, iPhone and iPad descriptors) and Firefox 159, with no page
   error and no console error. What a desktop engine cannot show: a real
   finger. Playwright drives touch TAPS in all three engines but a touch
   DRAG only in Chromium, so the volume slider and the Layout Designer were
   dragged with the mouse in WebKit and Firefox; native colour and time
   pickers were not opened (their values were set and saved);
   double-tap zoom and long-press selection cannot be produced (every
   button has `touch-action: manipulation` and `user-select: none` so
   that neither gets in the way).
   **Floor plan targets.** The plan keeps the venue's real proportions, so on
   a 7-inch screen a display is drawn smaller than a fingertip (about 26 px
   at 1024x600 for the 24-display sample). The target is larger than the
   drawing: a tap near a display, not on it, goes to the nearest display
   within reach (at least 12 px beyond its edge, more for a small shape, so a
   lone display is about 44 px across); a tap as near two displays as one
   (within 4 px) opens "Which display?" with both. At short heights (680 px
   or less) the "No scene active" line is hidden and paddings are smaller so
   the plan is drawn larger, and the Floor Plan side panel shows a fade at
   its bottom edge whenever it scrolls. WebKit and Chromium move the click
   of a touch onto a control near the finger by themselves; Firefox does
   not. Before 19 November that made WebKit select a display other than
   the nearest, or a whole area through its name, for a tap beside a
   display. The plan now decides from where the finger went down (the
   touch's pointerdown), so the rule above is the same in every engine.
   Measured 19 November 2026 after that change (Chromium 159, WebKit 27.2,
   Firefox 159, touch emulation, simulator; NOT on a T3, a T4 or a phone):
   a touch tap at the centre of every display selects exactly that display
   at 1024x600, 390x844, 844x390 and 1280x800 in both samples, in all three
   engines; a touch tap in the gap between two close displays opens "Which
   display?" in all three; the smallest effective target for a touch tap,
   swept 1 px at a time, is 46 px or more in the conference centre at every
   size, but 27 to 28 px (1024x600) and 33 px (390x844) high for the sports
   bar's columns of displays 5 px apart, where a tap in the gap asks which
   display was meant. Whether a T3 or T4 adjusts taps itself is not known;
   with this change it does not matter for the plan.
10. **Look.** Dark midnight navy, teal primary accent, amber for attention,
    green for confirmed. Use the tokens and components in
    `shared/base.css` (`.panel`, `.card`, `.btn`, `.seg`, `.chip`, `.field`,
    `.toggle`, `.slider`, `.item`, `.banner`, `.tbl`); add page-specific CSS in
    your own file, prefixed with your section's class. Speed and clarity over
    decoration: no animation that delays an action.
11. **Words.** Plain operator language. "Not confirmed", never "error 504".
    No em dashes in UI text.

## Shared client (`shared/vf.js`)

`VF.h`, `VF.icon(name, cls)`, `VF.api(command, payload) -> Promise(reply)`
(never rejects), `VF.session`, `VF.state` (`doc`, `version`, `cell(kind, id,
field)`), `VF.poll.start(ms)`, `VF.on('state' | 'online' | 'signedout', fn)`,
`VF.toast`, `VF.toastReply`, `VF.modal`, `VF.confirm`, `VF.prompt`,
`VF.pinPad`, `VF.statusChip`, `VF.outcomeChip`, `VF.outcomeList`,
`VF.slider`, `VF.asList`, `VF.asMap`, `VF.byId`, `VF.clone`, `VF.freshId`,
`VF.debounce`, `VF.fmtTime`, `VF.ago`.

The protocol and the documents a page receives are in
`docs/smartbuildos-venueflow/PROTOCOL.md` and `DATA_MODEL.md`.

## Installer Studio sections (`studio/shell.js`)

A section file calls `Studio.register({ id, title, icon, group, order,
render(container, params), dispose?, onIssues?, badge? })`. The shell owns
sign-in, navigation, the draft working copy and autosave:

- `Studio.config()` the working copy (read it; change it only through
  `Studio.update`)
- `Studio.update(label, fn(config), { silent?, immediate? })` apply a change,
  re-render the section (unless `silent`), save soon
- `Studio.replace(label, config)`, `Studio.flush()`, `Studio.reload()`
- `Studio.serverEdit(command, payload)` for commands that change the draft on
  the driver (`PROFILE_PIN_SET`, `TEMPLATE_APPLY`, `BACKUP_RESTORE`,
  `DRAFT_DISCARD`): flushes, runs, reloads
- `Studio.issues()`, `Studio.issuesFor(kind, id)`, `Studio.issueChip`,
  `Studio.issueList`
- `Studio.list(field)`, `Studio.find(field, id)`, `Studio.nameOf(field, id)`,
  `Studio.freshId(field, baseName)`, `Studio.entityOptions(field)`
- `Studio.references(kind, id)`, `Studio.confirmRemove(kind, id, noun)`
  (asks, lists what else changes, removes the entity and every reference)
- form helpers returning DOM: `Studio.text`, `Studio.number`, `Studio.select`,
  `Studio.toggle`, `Studio.check`, `Studio.idPicker`, `Studio.sectionHead`,
  `Studio.emptyDraft(container)`
- `Studio.on('config' | 'saved' | 'issues' | 'boot', fn)`: the working copy
  changed, a save was acknowledged, the driver's issues changed, the
  bootstrap data was reloaded
- `Studio.go(sectionId, params)`, `Studio.refresh()`, `Studio.boot`
  (the `STUDIO_BOOTSTRAP` data), `Studio.published`, `Studio.history`

Deleting anything in the Studio edits the VenueFlow draft only. No page ever
deletes or changes a Control4 device, room or connection.
