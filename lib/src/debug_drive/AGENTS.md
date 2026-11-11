<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-11-10 | Updated: 2026-11-11 -->

# debug_drive

## Purpose

The **debug drive**: a JSON API into the running app's business logic, over the
VM service channel `flutter run` already opens, in debug builds only. Every
action is a `dart:developer` service extension named
`ext.gc.<feature>.<action>` that calls one existing public method on `AppState`
(or reads one) and answers in JSON, so an agent or `tool/drive.sh` can check
the app without tapping coordinates on a simulator or reading pixels.

The design, the research behind it and the phase plan are in
`docs/debug-drive-plan.md` (epic #102). Phase 1 is the registry, the guard and
the first readouts; Phase 2 adds the media flow probe (`media.*`) and the
SFU session readout (`sfu.debug`); the per-feature actions follow.

## Key Files

| File | Description |
|------|-------------|
| `install.dart` | `installDebugDrive({enabled, app, boot, …})` — the **only** entry point. Called from `lib/main.dart` (`boot: 'live'`) and `lib/main_harness.dart` (`boot: 'harness'`) inside `if (kDebugMode)`, the compile-time guard that strips the whole drive from a release build. `enabled` exists only so a test can pin "disabled registers nothing"; pass `kDebugMode`. A second real install in one isolate rebinds to the new `AppState` instead of registering twice. `DriveBinding` is what handlers read through. |
| `debug_drive.dart` | `DebugDrive` — the registry. `install()` validates every name of a set first and registers nothing if any is invalid or duplicated (within the set or against what is registered). `handle()` decodes the single `args` param, runs the outward gate, maps the result. `invoke(method, argsJson)` is the in-process door tests use. Also `kDriveTestSpace` (the `DRIVE_TEST_SPACE` define) and `reportDriveError`. |
| `drive_result.dart` | `DriveResult.ok(data)` / `DriveResult.refused(reason, extra)`, `DriveInvalidParams`, and the `DriveArgs` typed readers (`requireString`, `optionalInt`). |
| `drive_ops.dart` | `DriveOps` — start/poll for long actions. Ids are `<kind>-<n>-<nonce>`; the nonce is drawn once per isolate so a pre-hot-restart id is refused rather than answered with a new op's result. Keeps 32, evicting the oldest finished first. Failures are reported through `FlutterError.reportError` whether or not anyone polls. |
| `builtin_features.dart` | `drive.list` (every action, sorted, with its `outward` flag, plus `boot`) and `op.status` / `op.result`. |
| `state_feature.dart` | `state.dump` — phase, link, collector health, me (id, tile, room), space id/name, `testSpace`, roster counts, call summary, settings, `boot`. **No credentials of any kind.** `dumpState()` is the readout on its own. |
| `media_drive.dart` | `media.snapshot {windowMs?}`, `media.watch` and `media.render {windowMs?, firstFrameWithinMs?}`. The snapshot is a bounded ≤3 s series held in the RPC — a verdict needs a delta and `stalled` the whole 2 s window) and `media.watch {durationMs, intervalMs, maxGapMs, stallAfterMs}` (an op) over `Call.sampleFlow` + `FlowJudge`. `summarizeWatch` builds the per-stream summary: verdict histogram, `continuous` (no `stalled`/`missing`/`not_measured` run longer than `maxGapMs`; `silent` counts as flowing because DTX; `paused` reported as `pausedMs`, never a gap), gaps backdated to where counters went flat, avg kbps / fps / loss %. `media.render` takes the same series and runs `checkRender` over `renderRegistry`. `refused('no_call')` with no `callHandle`. Read-only. |
| `render_check.dart` | `checkRender` — the pure cross-check behind `media.render`: the tiles' reports (`../media/render_registry.dart`) against one interval's verdicts and, live only, `LiveCall.debugStreamOwners`. Findings: `flowing_without_tile`, `bound_not_present`, `bound_not_flowing`, `duplicate_tiles` (per slot — the spotlighted face big *and* in the strip is by design), `never_rendered`, `stale_binding`, `wrong_stream`, and `unverified` (counted, not a failure). `ok: null` with the call screen closed — no tiles is no evidence. |
| `sfu_drive.dart` | `sfu.debug` — `LiveCall.debugSfuSnapshot` → `SfuSession.debugSnapshot`: own node, node pool (connecting/down/grace/escalations), `peerNode`, send/recv transports (id, node, connection state, `onCurrentNode`), producers, consumers (`producerId` vs the peer's currently announced id), pending consumes/produce, subscribed/announced/allowed/denied/producer-gone/unreachable sets, heal timers. No tokens. `refused('no_call')` with no call, `refused('no_sfu_session', {source})` for a scripted call or a live one that has not opened its session. Read-only. |
| `call_drive.dart` | `call.spotlight {historyMax?}` (readout: `mode`, `view` empty/grid/spotlight, `target`, `since`/`sinceMs`, raw `decided` picks, `speaking`, `tiles`, `selfId`, director `candidate`/`lingering` countdowns, armed `timer`, `dwellMs`/`lingerMs`, `promotions`, `transitions` with cause promoted/fallback/room/mode/tap/overview), and the screen's own levers `call.spotlight.mode {mode}`, `call.spotlight.pick {id}` (`refused('no_such_tile')`, `refused('self_in_auto')`), `call.spotlight.overview` — each answers with the readout. Reads `spotlightRegistry.current`, the `SpotlightController` (`../media/spotlight_controller.dart`) the mounted `CallScreen` renders from; `refused('call_screen_closed')` without one. Not outward (the big view is local). Makes `docs/sim_test_plan.md` C1–C7 assertable without screenshots. |
| `media_check_drive.dart` | `mediaCheck.status` (`{boot, screenOpen, mode, check}` — `check` is the open check's readout: starting, failure `{problem,message,needsSettings,retryable}`, controls, camera, mic, `meter` `open`/`not_open`/`none`, hearing, route; `null` between checks), `mediaCheck.mode {mode}`, `retry`, `mic {live}`, `camera {on}`, `switchCamera`, `speaker {on}`, `playTone` over `MediaCheckController` (`../media/media_check_controller.dart`), read through `mediaCheckDebugActive` (set by `MediaCheckScreen` under `kDebugMode`). The drive never opens a check: screen closed → `refused('screen_closed')`. A control the screen hides is refused, not performed (`controls_hidden`, `no_camera`, `cannot_switch`, `not_in_device_mode`, `nothing_to_retry`, `needs_settings`, `sound_effects_off`, `no_check`); a chime the player threw on is `refused('play_failed', {error})`, never `ok`. All `outward: false` — the check talks to no server and publishes nothing. |
| `plans_drive.dart` | `plans.state {pastMax?}` — the Plans tab off `splitPlans` / `planDays` (`../plans_timeline.dart`, the functions `CalendarScreen` builds from): `googleAvailable`/`googleConnected`/`showConnect`, `counts`, `empty`, `upcoming` (each with `key`, `source` plan/google, title, times, `live`, `place`, `canGoToMeeting` for Google), `days` (one per timeline section: `date`, `free` (nothing timed *or* all-day — the timeline's "Free for the day"), `noTimed`, `allDay` keys, `bands` busy with lane-packed items / free with `minutes` + `collapsed`), `past` (≤ `pastMax`, default 20) + `pastTruncated`. Needs no screen (`screenless: true`); wall-clock now. Read-only, not outward. `plansReadout()` is the readout on its own. |
| `gameboy_drive.dart` | `gameboy.mapping` (`gameboyMode`, `shellMounted`, and with a shell `menu` {open,row,status,emote,choice} and `buttons` {a,b,select,start,dpad,dpadEnabled} from `gameboyButtons` — the table the keys are wired from; `home` {leaveHuddle,toDesk} and `wave` {ready,target} always), `gameboy.menu.toggle`, `gameboy.menu.move {direction}` (up/down/left/right, any case; `refused('menu_closed')`), `gameboy.menu.confirm` (**outward** — the lit row may set status, flip the camera or send an emote; answers `chose`). Reads `gameboyDebugActive` (`../gameboy_controls.dart`, set by `GameboyShell` under `kDebugMode`) and calls the shell's own Select/D-pad/A handlers; `refused('shell_not_mounted')` without one. |
| `drive_log.dart` | `DriveLogBuffer` (a 2000-line ring with ever-rising `seq`) and `log.tail {since?, max?}`. Fed by `mediaLogDebugSink` in `../media/media_log.dart`, which only `installDebugDrive` sets. |
| `plans_drive.dart` (levers, #108) | `plans.list` (raw records soonest-first, past included, `mirrored` per plan, `mirrorCalendarId`/`mirroring`), `plans.add {title, startsAt (ISO date-time — date and time both written, every field range-checked, no rollover), durationMinutes? 5–480 =30, roomStableId?, remindMinutesBefore? 0–1440 =5, id?}`, `plans.update {id, …same fields; roomStableId:null clears}`, `plans.delete {id}` — through `AppState.addMeeting`/`updateMeeting`/`deleteMeeting`, the record built by `composePlannedMeeting` (the editor's Save) and ids by `newPlanId()` (`../plans_timeline.dart`). Refusals: `no_such_plan` (update would otherwise silently add, delete answer success), `no_such_room` (with `mapLoaded` + the plannable rooms), `plan_exists`, `save_failed`/`delete_failed` `{message}`. `plans.google.status` (`available`, `connected`, `showConnect`, `events`, `sharedCalendars` — names only via `AppState.sharedCalendarNames`, no ids or tokens). Unknown arg keys are `invalidParams`. **Not outward**: a plan is keychain + local notification, invisible in the space; the one road off the phone is the device-calendar mirror, so with `mirrorCalendarId` set a `boot: "live"` write is `refused('calendar_mirror_on')` unless `confirm: true` (this build wires only the no-op mirror). |

## For AI Agents

### Working In This Directory

- **The call-site guard is the release guard.** `if (kDebugMode) { installDebugDrive(enabled: kDebugMode, …) }` —
  a compile-time constant, at the call site. A runtime flag anywhere on that path
  keeps every handler and every `ext.gc.` name in the release binary.
  `tool/release_artifact_check.sh` greps the release `App.framework/App` and
  `libapp.so` in CI and fails the release if one leaks. Nothing outside this
  directory may reference it except those two call sites. The hooks elsewhere
  carry no names and are written only under `kDebugMode`: `mediaLogDebugSink`
  (stays null in release) and `renderRegistry` (`../media/render_registry.dart`,
  written by the video tiles inside `if (kDebugMode)`, so release tree-shakes
  it). The readouts a handler calls on product classes
  (`SfuSession.debugSnapshot`, `LiveCall.debugSfuSnapshot`,
  `LiveCall.debugStreamOwners`) are referenced only from here, so they shake
  out of release with the drive.
- **One handler = one existing public method, or a read-only readout.** No second
  code path. If a handler needs to reach into a widget's `State`, the logic is in
  the wrong layer — move it down (plan Phase 4) rather than reaching.
- **Names:** `ext.gc.<feature>.<action>`, every segment `^[a-z][a-zA-Z0-9]*$`.
  An action name may itself have dots (`presence.map.people`). The registry
  refuses anything else before registering anything.
- **Three outcomes, kept apart.** `DriveResult.ok` for success; `refused` (a
  successful RPC with `ok:false` and a stable snake_case `reason`) for an
  expected no — no call, not in a space, a locked room; throw
  `DriveInvalidParams` for unreadable input; let anything else throw, and the
  registry turns it into an extension error (`-32000`, `{error, type}`) *and*
  `FlutterError.reportError`. Never catch-and-return an error as data.
- **Params:** one `args` param holding a JSON object **string**. Absent is `{}`.
  An MCP client that passes a raw object sends Dart `toString()` text, which is
  refused as invalid JSON — by design.
- **Long actions are ops.** Anything that waits (a walk, a warp into a call, a
  media watch) returns `{id}` from `DriveOps.start` at once; the caller polls
  `op.result`. Never hold the RPC open.
- **Outward actions.** Flag an action `outward: true` if anyone else in the space
  could see it (wave, emote, status, warp, entering a room, party mode, leaving a
  call). On `boot: "live"` it is refused with `outward_outside_test_space` unless
  the space is the `DRIVE_TEST_SPACE` define or the args carry `"confirm": true`.
  **Agent rule: only send `confirm: true` after the user has said yes to that
  action in this session.** The harness is never gated.
- **No secrets in any readout.** Tokens, cookies, the bridge token, the Gather
  credential: not read, not masked, not present. `state_dump_test.dart` boots on
  secret-shaped credentials and fails on a leak by value or by key name.
- **Readouts say why they are empty** (the repo's honesty rule): a reading that
  could be "nothing" or "not measured" must carry which.

### Testing Requirements

```sh
flutter analyze && flutter test test/debug_drive
```

Handlers are tested in-process through the registry
(`installDebugDrive(..., register: RecordingRegistrar().call)` then
`drive.invoke('ext.gc.state.dump', '{"…":…}')`), driving the real `AppState`
through its `debugApply*` seams. **A PR that adds or changes a drive action ships
a handler test.** Outward actions need a gate test; `install_test.dart` shows the
shape with a test-only outward action.

### Common Patterns

- A feature is a function returning `DriveFeature(name, [DriveAction(...)])`,
  taking getters (`AppState Function()`) rather than values so a rebind is seen.
- Handlers read args through `DriveArgs` so a bad field is `invalidParams` naming
  the field, not a `TypeError` reported as a drive failure.

## Dependencies

### Internal

`../app_state.dart` (read through public getters only), `../media/call.dart` + `../media/media_flow.dart` (the flow probe), `../media/live_call.dart` (the live-only readouts), `../media/render_registry.dart` (the tiles' reports), `../media/media_log.dart`, `../plans_timeline.dart` (the Plans day maths), `../gameboy_controls.dart` (the handheld's key table and menu)
(the sink hook).

### External

`dart:developer`, `package:flutter/foundation.dart`. No new runtime dependency;
`vm_service` is a dev dependency of `tool/drive.dart` only.

<!-- MANUAL: -->
