/// The debug drive's one entry point, and the reason it never ships.
///
/// Call it exactly like this, in `lib/main.dart` and `lib/main_harness.dart`:
///
/// ```dart
/// if (kDebugMode) {
///   installDebugDrive(enabled: kDebugMode, app: state, boot: 'live');
/// }
/// ```
///
/// The `if (kDebugMode)` at the *call site* is the release guard, and it only
/// works because `kDebugMode` is a compile-time constant: the AOT compiler sees
/// a dead branch and drops this function, every handler it would register, the
/// `ext.gc.*` names and every class they pull in. A runtime flag — a setting, an
/// environment read, a `bool` passed down — keeps all of it in the binary, and
/// then the release carries a JSON API into the app that only a check would
/// notice. `tool/release_artifact_check.sh` is that check: CI greps the release
/// `App.framework/App` and `libapp.so` for `ext.gc.` and fails on a match.
///
/// [enabled] exists for the one thing the guard cannot do under test:
/// `kDebugMode` is always true in `flutter test`, so "a disabled install
/// registers nothing" can only be pinned through a parameter. It is not a second
/// guard and must not become one; pass `kDebugMode` and nothing else.
///
/// A second install in the same isolate with the real registrar — a remounted
/// root widget, a test that pumps the app twice — *rebinds* the existing drive
/// to the new [AppState] instead of registering again. `registerExtension`
/// cannot unregister, so the only alternatives were throwing on the remount or
/// leaving the channel pointed at a disposed state. A rebind changes only the
/// [AppState] and the boot; one that asks for more — new `extraFeatures`, its
/// own `ops`, `logBuffer` or test space — throws a [StateError] rather than
/// returning the old drive as if it had honoured them. Silently dropping a
/// feature is the "half-registered looks like not present" failure the
/// registry's all-or-nothing rule exists to prevent.
///
/// The log tail starts at launch, not at install: [startDriveLog], called first
/// thing in `main()` behind the same compile-time guard, points `media.log`'s
/// debug sink at a buffer the later install picks up — so the boot lines written
/// before the first frame (Firebase, the calendar diagnostics) are in the tail as
/// they are in the file.
library;

import 'package:flutter/foundation.dart';

import '../app_state.dart';
import '../media/media_check_controller.dart';
import '../media/media_log.dart';
import 'builtin_features.dart';
import 'call_drive.dart';
import 'debug_drive.dart';
import 'drive_log.dart';
import 'drive_ops.dart';
import 'gameboy_drive.dart';
import 'media_check_drive.dart';
import 'media_drive.dart';
import 'plans_drive.dart';
import 'sfu_drive.dart';
import 'state_feature.dart';
import 'status_drive.dart';
import 'ui_drive.dart';

/// What the handlers read through, so a rebind is one assignment.
class DriveBinding {
  DriveBinding({required this.app, required this.boot, required this.testSpaceId});

  AppState app;
  String boot;
  final String testSpaceId;

  /// The space the app is in, as Gather told it.
  String? get spaceId => app.snapshot.self.spaceId;

  /// Whether that is the compiled-in test space. Never true without the define:
  /// an empty test-space id matches no space, rather than every unnamed one.
  bool get inTestSpace => testSpaceId.isNotEmpty && spaceId == testSpaceId;
}

Future<void> _sleep(Duration d) => Future<void>.delayed(d);

/// The drive this isolate registered with `dart:developer`, and its binding.
({DebugDrive drive, DriveBinding binding})? _isolateDrive;

/// The buffer [startDriveLog] began filling at launch, for the install to use.
DriveLogBuffer? _launchBuffer;

/// Starts keeping `media.log` lines for `log.tail` from this moment, before the
/// drive itself is installed. Does nothing when ![enabled], and nothing on a
/// second call. Same call-site rule as [installDebugDrive]:
///
/// ```dart
/// if (kDebugMode) {
///   startDriveLog(enabled: kDebugMode);
/// }
/// ```
void startDriveLog({required bool enabled}) {
  if (!enabled || _launchBuffer != null) return;
  final buffer = DriveLogBuffer();
  _launchBuffer = buffer;
  mediaLogDebugSink = buffer.add;
}

/// Forgets the launch buffer, so one test's [startDriveLog] does not leak into
/// the next.
@visibleForTesting
void debugResetDriveLog() {
  _launchBuffer = null;
  mediaLogDebugSink = null;
}

/// Installs the debug drive for [app], or does nothing when ![enabled].
///
/// [boot] is `"harness"` or `"live"`. [register], [ops], [logBuffer] and
/// [testSpaceId] are seams for tests; [extraFeatures] lets a test (or, later,
/// the harness) add its own actions to the same all-or-nothing install.
///
/// [mediaSleep] is how `media.snapshot` / `media.watch` wait between readings —
/// a seam so a test can run a watch on a fake clock.
///
/// Returns the drive, or null when not enabled.
DebugDrive? installDebugDrive({
  required bool enabled,
  required AppState app,
  required String boot,
  DriveRegistrar? register,
  String testSpaceId = kDriveTestSpace,
  DriveOps? ops,
  DriveLogBuffer? logBuffer,
  List<DriveFeature> extraFeatures = const [],
  DriveSleep? mediaSleep,
}) {
  if (!enabled) return null;
  if (boot != 'harness' && boot != 'live') {
    throw ArgumentError.value(boot, 'boot', 'must be "harness" or "live"');
  }

  final existing = _isolateDrive;
  if (register == null && existing != null) {
    if (extraFeatures.isNotEmpty ||
        ops != null ||
        mediaSleep != null ||
        logBuffer != null ||
        testSpaceId != existing.binding.testSpaceId) {
      throw StateError(
        'debug drive already installed in this isolate: a rebind changes only the '
        'AppState and boot — extraFeatures, ops, logBuffer and testSpaceId cannot '
        'be re-registered (registerExtension cannot unregister)',
      );
    }
    existing.binding
      ..app = app
      ..boot = boot;
    return existing.drive;
  }

  final binding = DriveBinding(app: app, boot: boot, testSpaceId: testSpaceId);
  final drive = DebugDrive(
    boot: () => binding.boot,
    spaceId: () => binding.spaceId,
    inTestSpace: () => binding.inTestSpace,
    register: register,
  );
  final buffer = logBuffer ?? _launchBuffer ?? DriveLogBuffer();
  // One op table for every feature, so `op.result` answers a `media.watch` id.
  final driveOps = ops ?? DriveOps();
  drive.install([
    driveFeature(drive),
    opFeature(driveOps),
    stateFeature(
      app: () => binding.app,
      boot: () => binding.boot,
      inTestSpace: () => binding.inTestSpace,
    ),
    logFeature(buffer),
    mediaFeature(call: () => binding.app.callHandle, ops: driveOps, sleep: mediaSleep ?? _sleep),
    sfuFeature(call: () => binding.app.callHandle),
    mediaCheckFeature(controller: () => mediaCheckDebugActive, boot: () => binding.boot),
    callFeature(call: () => binding.app.callHandle, boot: () => binding.boot),
    plansFeature(app: () => binding.app, boot: () => binding.boot),
    gameboyFeature(app: () => binding.app, boot: () => binding.boot),
    statusFeature(app: () => binding.app, boot: () => binding.boot), uiFeature(app: () => binding.app, boot: () => binding.boot),
    ...extraFeatures,
  ]);
  // After the install succeeded, so a refused install leaves no sink behind.
  mediaLogDebugSink = buffer.add;
  if (register == null) _isolateDrive = (drive: drive, binding: binding);
  debugPrint('debug drive: ${drive.actions.length} actions on the VM service (boot=$boot)');
  return drive;
}
