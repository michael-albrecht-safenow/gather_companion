/// `ext.gc.mediaCheck.*`: the "Mic, camera & sound" screen, driven the way a
/// person drives it (plan task 4.2).
///
/// The check answers "is it me or is it them" before a call, and until its
/// logic moved into `MediaCheckController` (`../media/media_check_controller.dart`)
/// the only way to ask it anything was to look at the phone. Now `status` reads
/// what the screen shows — mode, starting, the three-way failure, the mic light
/// and whether a meter is behind it, the camera, the route — and the other
/// actions are the screen's own controls, each one call on the controller the
/// buttons call.
///
/// ## The screen has to be open
///
/// The checks own hardware (the camera, the microphone, a capture engine) for
/// exactly as long as the screen is mounted, and that lifetime is the point —
/// it is what keeps the two frameworks off the audio session at once. So the
/// drive never opens a check by itself; it reads the controller of the screen
/// on display through `mediaCheckDebugActive`, which the screen sets only under
/// `kDebugMode`. With the screen closed, `status` says `screenOpen: false` and
/// every control is `refused('screen_closed')`. Open it in the UI first (Settings
/// → "Mic, camera & sound").
///
/// ## A control the screen hides is refused, not performed
///
/// One handler, one method, and no second path: an action does only what the
/// visible control would. Mic, camera and switch need the controls on screen
/// (`controls_hidden` while starting or after a refused permission); the switch
/// needs a second camera (`cannot_switch`), the camera toggle a camera
/// (`no_camera`); the route and the test sound exist only in Device mode
/// (`not_in_device_mode`); "Try again" only under a retryable failure
/// (`nothing_to_retry`, or `needs_settings` — the fix for that one is in iOS
/// Settings, not here). A mode switch takes effect on the next frame, when the
/// widget swaps its child and that child opens the new check: `mode` answers at
/// once and `status` shows the new check once it is up (`check: null` in
/// between).
///
/// ## Not outward
///
/// Nothing here talks to Gather. The call-pipeline check is a standalone
/// capture with no SFU transport, so nothing is published and nobody in the
/// space can see or hear any of it; the test sound is heard in the room the
/// phone is in, not in the space. Every action is `outward: false`. Each control
/// answers with the check's status after it ran.
library;

import '../media/media_check_controller.dart';
import 'debug_drive.dart';
import 'drive_result.dart';

/// `ext.gc.mediaCheck.{status, mode, retry, mic, camera, switchCamera, speaker,
/// playTone}`.
///
/// [controller] is the controller of the screen on display (the app passes
/// `() => mediaCheckDebugActive`; a test passes its own); [boot] is what
/// `status` reports as `boot`.
DriveFeature mediaCheckFeature({
  required MediaCheckController? Function() controller,
  required String Function() boot,
}) {
  DriveResult closed() => const DriveResult.refused('screen_closed', {
        'detail': 'open Settings → "Mic, camera & sound" first; the check owns hardware only while it is on screen',
      });

  /// The open check, or the refusal that says why there is none.
  ({MediaCheck? check, DriveResult? refusal}) open() {
    final c = controller();
    if (c == null) return (check: null, refusal: closed());
    final check = c.check;
    if (check == null) {
      return (
        check: null,
        refusal: DriveResult.refused('no_check', {
          'mode': c.mode.name,
          'detail': 'the screen is between checks (a mode switch lands on the next frame)',
        }),
      );
    }
    return (check: check, refusal: null);
  }

  DriveResult after(MediaCheck check) => DriveResult.ok({'check': check.status()});

  return DriveFeature('mediaCheck', [
    DriveAction('status', (args) async {
      final c = controller();
      if (c == null) {
        return DriveResult.ok({
          'boot': boot(),
          'screenOpen': false,
          'detail': 'the Mic, camera & sound screen is not open',
        });
      }
      return DriveResult.ok({'boot': boot(), 'screenOpen': true, ...c.status()});
    }),
    DriveAction('mode', (args) async {
      final wanted = _requireMode(args);
      final c = controller();
      if (c == null) return closed();
      final from = c.mode;
      if (from != wanted) c.setMode(wanted);
      return DriveResult.ok({'mode': wanted.name, 'from': from.name, 'changed': from != wanted});
    }),
    DriveAction('retry', (args) async {
      final (:check, :refusal) = open();
      if (check == null) return refusal!;
      final failure = check.failure;
      if (failure == null) return const DriveResult.refused('nothing_to_retry');
      if (!failure.retryable) return DriveResult.refused('needs_settings', {'failure': failure.toJson()});
      await check.retry();
      return after(check);
    }),
    DriveAction('mic', (args) async {
      final live = _requireBool(args, 'live');
      final (:check, :refusal) = open();
      if (check == null) return refusal!;
      if (!check.showControls) return _hidden(check);
      await check.setMicLive(live);
      return after(check);
    }),
    DriveAction('camera', (args) async {
      final on = _requireBool(args, 'on');
      final (:check, :refusal) = open();
      if (check == null) return refusal!;
      if (!check.showControls) return _hidden(check);
      if (check is DeviceCheck && check.camera == null) return const DriveResult.refused('no_camera');
      await check.setVideoOn(on);
      return after(check);
    }),
    DriveAction('switchCamera', (args) async {
      final (:check, :refusal) = open();
      if (check == null) return refusal!;
      if (!check.showControls) return _hidden(check);
      if (!check.canSwitch) return const DriveResult.refused('cannot_switch');
      await check.switchCamera();
      return after(check);
    }),
    DriveAction('speaker', (args) async {
      final on = _requireBool(args, 'on');
      final (:check, :refusal) = open();
      if (check == null) return refusal!;
      if (check is! DeviceCheck) return _notDevice(check);
      if (!check.showControls) return _hidden(check);
      check.setSpeaker(on);
      return after(check);
    }),
    DriveAction('playTone', (args) async {
      final (:check, :refusal) = open();
      if (check == null) return refusal!;
      if (check is! DeviceCheck) return _notDevice(check);
      if (!check.showControls) return _hidden(check);
      switch (await check.playTone()) {
        case ToneOutcome.silenced:
          return const DriveResult.refused('sound_effects_off');
        case ToneOutcome.failed:
          return DriveResult.refused('play_failed', {'error': check.lastToneError});
        case ToneOutcome.played:
          return after(check);
      }
    }),
  ]);
}

DriveResult _hidden(MediaCheck check) => DriveResult.refused('controls_hidden', {
      'starting': check.starting,
      'failure': check.failure?.toJson(),
    });

DriveResult _notDevice(MediaCheck check) => DriveResult.refused('not_in_device_mode', {
      'mode': check.mode.name,
      'detail': 'the call pipeline forces no route and plays no sound',
    });

MediaCheckMode _requireMode(Map<String, Object?> args) {
  final name = args.requireString('mode');
  for (final m in MediaCheckMode.values) {
    if (m.name == name) return m;
  }
  throw DriveInvalidParams('"mode" must be one of ${MediaCheckMode.values.map((m) => m.name).join(', ')}');
}

bool _requireBool(Map<String, Object?> args, String key) {
  final value = args[key];
  if (value is bool) return value;
  throw DriveInvalidParams(value == null ? '"$key" is required' : '"$key" must be a boolean');
}
