<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-11-10 | Updated: 2026-11-10 -->

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
the first readouts; the media flow probe and the per-feature actions follow.

## Key Files

| File | Description |
|------|-------------|
| `install.dart` | `installDebugDrive({enabled, app, boot, …})` — the **only** entry point. Called from `lib/main.dart` (`boot: 'live'`) and `lib/main_harness.dart` (`boot: 'harness'`) inside `if (kDebugMode)`, the compile-time guard that strips the whole drive from a release build. `enabled` exists only so a test can pin "disabled registers nothing"; pass `kDebugMode`. A second real install in one isolate rebinds to the new `AppState` instead of registering twice. `DriveBinding` is what handlers read through. |
| `debug_drive.dart` | `DebugDrive` — the registry. `install()` validates every name of a set first and registers nothing if any is invalid or duplicated (within the set or against what is registered). `handle()` decodes the single `args` param, runs the outward gate, maps the result. `invoke(method, argsJson)` is the in-process door tests use. Also `kDriveTestSpace` (the `DRIVE_TEST_SPACE` define) and `reportDriveError`. |
| `drive_result.dart` | `DriveResult.ok(data)` / `DriveResult.refused(reason, extra)`, `DriveInvalidParams`, and the `DriveArgs` typed readers (`requireString`, `optionalInt`). |
| `drive_ops.dart` | `DriveOps` — start/poll for long actions. Ids are `<kind>-<n>-<nonce>`; the nonce is drawn once per isolate so a pre-hot-restart id is refused rather than answered with a new op's result. Keeps 32, evicting the oldest finished first. Failures are reported through `FlutterError.reportError` whether or not anyone polls. |
| `builtin_features.dart` | `drive.list` (every action, sorted, with its `outward` flag, plus `boot`) and `op.status` / `op.result`. |
| `state_feature.dart` | `state.dump` — phase, link, collector health, me (id, tile, room), space id/name, `testSpace`, roster counts, call summary, settings, `boot`. **No credentials of any kind.** `dumpState()` is the readout on its own. |
| `drive_log.dart` | `DriveLogBuffer` (a 2000-line ring with ever-rising `seq`) and `log.tail {since?, max?}`. Fed by `mediaLogDebugSink` in `../media/media_log.dart`, which only `installDebugDrive` sets. |

## For AI Agents

### Working In This Directory

- **The call-site guard is the release guard.** `if (kDebugMode) { installDebugDrive(enabled: kDebugMode, …) }` —
  a compile-time constant, at the call site. A runtime flag anywhere on that path
  keeps every handler and every `ext.gc.` name in the release binary.
  `tool/release_artifact_check.sh` greps the release `App.framework/App` and
  `libapp.so` in CI and fails the release if one leaks. Nothing outside this
  directory may reference it except those two call sites; the one hook elsewhere
  (`mediaLogDebugSink`) carries no names and stays null in release.
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

`../app_state.dart` (read through public getters only), `../media/media_log.dart`
(the sink hook).

### External

`dart:developer`, `package:flutter/foundation.dart`. No new runtime dependency;
`vm_service` is a dev dependency of `tool/drive.dart` only.

<!-- MANUAL: -->
