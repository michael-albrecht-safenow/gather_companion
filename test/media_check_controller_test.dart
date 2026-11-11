/// `MediaCheckController` and its two checks, on fake hardware: the start
/// sequence (front camera first, the meter never held hostage by the camera),
/// the three-way failure split, the mic light, the camera's lifecycle, the
/// chime, and the call-pipeline check's once-only renderer setup — the logic
/// that used to be reachable only through a device and a pair of eyes.
library;

import 'dart:async';

import 'package:camera/camera.dart' show CameraException;
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:gather_companion/src/media/gameboy_sfx.dart';
import 'package:gather_companion/src/media/media_check_controller.dart';
import 'package:gather_companion/src/media/media_engine.dart';
import 'package:gather_companion/src/media/test_tone.dart';

import 'fake_media_check.dart';

Future<void> settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  group('DeviceCheck start', () {
    test('opens the front camera, then the meter, and shows the controls', () async {
      final rig = DeviceRig(cameras: [backCam, frontCam]);
      final check = rig.build();
      expect(check.starting, isTrue);
      expect(check.showControls, isFalse, reason: 'nothing to control while starting');

      await check.start();
      await settle();

      expect(rig.log, ['init:front']);
      expect(rig.tone.calls, ['configure']);
      expect(check.starting, isFalse);
      expect(check.failure, isNull);
      expect(check.camera, same(rig.opened.single));
      expect(check.frontCamera, isTrue);
      expect(check.canSwitch, isTrue);
      expect(check.meterOpen, isTrue);
      expect(rig.mic.calls, ['hasPermission', 'startStream']);
      expect(check.showControls, isTrue);
      check.dispose();
    });

    test('no camera at all is its own failure, and the mic test still runs', () async {
      final rig = DeviceRig(cameras: []);
      final check = rig.build();
      await check.start();
      await settle();

      expect(check.failure?.problem, MediaCheckProblem.noCamera);
      expect(check.failure?.retryable, isTrue);
      expect(check.showControls, isTrue, reason: 'a missing camera must not hide the mic');
      expect(check.meterOpen, isTrue);
      expect(rig.opened, isEmpty);
      check.dispose();
    });

    test('a CameraException listing cameras reads as no camera', () async {
      final rig = DeviceRig()..listError = CameraException('busy', 'nope');
      final check = rig.build();
      await check.start();
      expect(check.failure?.problem, MediaCheckProblem.noCamera);
      check.dispose();
    });

    test('a refused permission is the Settings failure, hides the controls, and frees the camera', () async {
      final rig = DeviceRig()..failNext.add(CameraException('CameraAccessDenied', 'denied'));
      final check = rig.build();
      await check.start();
      await settle();

      expect(check.failure?.problem, MediaCheckProblem.permission);
      expect(check.failure?.needsSettings, isTrue);
      expect(check.failure?.message, 'Camera permission denied.');
      expect(check.showControls, isFalse);
      expect(check.camera, isNull);
      expect(rig.opened.single.disposed, isTrue);
      check.dispose();
    });

    test('any other camera error carries its description and retries cleanly', () async {
      final rig = DeviceRig()..failNext.add(CameraException('Busy', 'In use by another app'));
      final check = rig.build();
      await check.start();
      await settle();
      expect(check.failure?.problem, MediaCheckProblem.other);
      expect(check.failure?.message, 'In use by another app');

      final notes = <bool>[];
      check.addListener(() => notes.add(check.starting));
      final retry = check.retry();
      expect(check.starting, isTrue);
      expect(check.failure, isNull);
      await retry;
      await settle();

      expect(check.failure, isNull);
      expect(check.camera, same(rig.opened.last));
      expect(notes.first, isTrue, reason: 'retry redraws as starting first');
      expect(rig.mic.calls.where((c) => c == 'startStream'), hasLength(1),
          reason: 'the meter is idempotent across retries');
      check.dispose();
    });

    test('a camera that finishes opening after the screen closed is disposed, not kept', () async {
      final rig = DeviceRig()..gateNext = Completer<void>();
      final gate = rig.gateNext!;
      final check = rig.build();
      final started = check.start();
      await settle();
      check.dispose();
      gate.complete();
      await started;

      expect(rig.opened.single.disposed, isTrue);
      expect(check.camera, isNull);
    });

    test('a refused mic permission leaves the meter not open, and says so', () async {
      final rig = DeviceRig()..mic.permission = false;
      final check = rig.build();
      await check.start();
      await settle();
      expect(check.meterOpen, isFalse);
      expect(check.status()['meter'], 'not_open');
      check.dispose();
    });
  });

  group('DeviceCheck mic light', () {
    test('lights on speech, goes dark after the hold, and ignores input while muted', () async {
      final rig = DeviceRig();
      final check = rig.build();
      await check.start();
      await settle();

      rig.mic.push(0.5);
      await settle();
      expect(check.hearing, isTrue);

      rig.mic.push(0);
      await settle();
      expect(check.hearing, isTrue, reason: 'one quiet chunk is inside the hold');
      rig.clock = rig.clock.add(const Duration(seconds: 1));
      rig.mic.push(0);
      await settle();
      expect(check.hearing, isFalse);

      rig.mic.push(0.5);
      await settle();
      expect(check.hearing, isTrue);
      await check.setMicLive(false);
      expect(check.hearing, isFalse, reason: 'muting darkens the light at once');
      expect(rig.mic.calls.last, 'pause');
      rig.mic.push(0.5);
      await settle();
      expect(check.hearing, isFalse, reason: 'a muted mic feeds nothing');

      await check.setMicLive(true);
      expect(rig.mic.calls.last, 'resume');
      check.dispose();
    });
  });

  group('DeviceCheck camera', () {
    test('video off pauses the preview; on resumes it', () async {
      final rig = DeviceRig();
      final check = rig.build();
      await check.start();
      await check.setVideoOn(false);
      expect(check.videoOn, isFalse);
      expect(rig.opened.single.paused, isTrue);
      await check.setVideoOn(true);
      expect(rig.opened.single.paused, isFalse);
      check.dispose();
    });

    test('switching disposes the old camera, opens the next, and keeps video off off', () async {
      final rig = DeviceRig();
      final check = rig.build();
      await check.start();
      await check.setVideoOn(false);
      await check.switchCamera();

      expect(rig.log, ['init:front', 'pause:front', 'dispose:front', 'init:back', 'pause:back']);
      expect(check.frontCamera, isFalse);
      expect(check.camera, same(rig.opened.last));
      check.dispose();
    });

    test('one camera cannot switch', () async {
      final rig = DeviceRig(cameras: [frontCam]);
      final check = rig.build();
      await check.start();
      expect(check.canSwitch, isFalse);
      await check.switchCamera();
      expect(rig.opened, hasLength(1));
      check.dispose();
    });

    test('backgrounding drops the camera; returning reopens it, paused if video was off', () async {
      final rig = DeviceRig();
      final check = rig.build();
      await check.start();
      await check.setVideoOn(false);

      check.appLifecycleChanged(AppLifecycleState.paused);
      expect(check.camera, isNull);
      expect(rig.opened.single.disposed, isTrue);
      check.appLifecycleChanged(AppLifecycleState.inactive);
      expect(rig.log.where((l) => l.startsWith('dispose')), hasLength(1));

      check.appLifecycleChanged(AppLifecycleState.resumed);
      await settle();
      expect(check.camera, same(rig.opened.last));
      expect(rig.opened, hasLength(2));
      expect(rig.opened.last.paused, isTrue);
      check.dispose();
    });

    test('returning does not reopen a camera that failed', () async {
      final rig = DeviceRig()..failNext.add(CameraException('CameraAccessDenied', null));
      final check = rig.build();
      await check.start();
      check.appLifecycleChanged(AppLifecycleState.resumed);
      await settle();
      expect(rig.opened, hasLength(1));
      check.dispose();
    });
  });

  group('DeviceCheck test sound', () {
    test('the sine chime picked by the random variant, out of the chosen route', () async {
      final rig = DeviceRig()..random = 2;
      final check = rig.build();
      await check.start();
      expect(await check.playTone(), ToneOutcome.played);
      check.setSpeaker(false);
      expect(await check.playTone(), ToneOutcome.played);

      expect(rig.tone.played.map((p) => p.speaker), [true, false]);
      expect(rig.tone.played.first.wav, chimeWav(variant: 2 % variantCount));
      expect(check.status()['tonesPlayed'], 2);
      check.dispose();
    });

    test('Gameboy mode plays the square-wave chime', () async {
      final rig = DeviceRig()..gameboy = true;
      final check = rig.build();
      await check.playTone();
      expect(rig.tone.played.single.wav, gbSoundWav(GbSound.chime));
      check.dispose();
    });

    test('a player that throws is a failure, not a chime', () async {
      final rig = DeviceRig();
      final check = rig.build();
      rig.tone.failNext = StateError('audio session busy');
      expect(await check.playTone(), ToneOutcome.failed);
      expect(check.lastToneError, contains('audio session busy'));
      expect(check.status()['tonesPlayed'], 0);
      expect(await check.playTone(), ToneOutcome.played);
      expect(check.status()['tonesPlayed'], 1);
      check.dispose();
    });

    test('the Sound effects switch silences it', () async {
      final rig = DeviceRig()..soundEffects = false;
      final check = rig.build();
      expect(await check.playTone(), ToneOutcome.silenced);
      expect(rig.tone.played, isEmpty);
      check.dispose();
    });
  });

  test('DeviceCheck dispose lets go of the mic, the player and the camera', () async {
    final rig = DeviceRig();
    final check = rig.build();
    await check.start();
    await settle();
    check.dispose();
    await settle();
    expect(rig.mic.calls.last, 'dispose');
    expect(rig.tone.calls.last, 'dispose');
    expect(rig.opened.single.disposed, isTrue);
  });

  group('PipelineCheck', () {
    test('initialises the preview once, captures, and binds the stream', () async {
      final m = fakeMediaCheck();
      final check = m.controller.openPipeline(const PreviewBinding(initialize: _never, attach: _ignore));
      await settle();

      final engine = m.engines.single;
      expect(engine.calls, ['startCapture(audio: true, video: true)']);
      expect(m.previews.single.initialized, 1);
      expect(m.previews.single.attached.single, isNotNull);
      expect(check.starting, isFalse);
      expect(check.showControls, isTrue);
      expect(check.micLive, isTrue);
      expect(check.canSwitch, isTrue);
      expect(check.status(), containsPair('previewBound', true));
      expect(check.status(), containsPair('meter', 'none'));

      await check.retry();
      expect(m.previews.single.initialized, 1, reason: 're-initialising a live renderer throws');
      m.controller.release(check);
    });

    test('a refused permission comes through as the Settings failure', () async {
      final m = fakeMediaCheck();
      final check = m.controller.openPipeline(const PreviewBinding(initialize: _never, attach: _ignore));
      m.engines.single.failWith = const MediaFailure(MediaFailureKind.permissionDenied, 'no');
      await settle();

      expect(check.starting, isFalse);
      expect(check.failure?.problem, MediaCheckProblem.permission);
      expect(check.showControls, isFalse);
      expect(m.previews.single.attached, isEmpty);
      m.controller.release(check);
    });

    test('the controls are the engine calls; release disposes the engine', () async {
      final m = fakeMediaCheck();
      final check = m.controller.openPipeline(const PreviewBinding(initialize: _never, attach: _ignore));
      await settle();
      final engine = m.engines.single;

      await check.setMicLive(false);
      await check.setVideoOn(false);
      await settle();
      expect(check.micLive, isFalse);
      expect(check.videoOn, isFalse);
      expect(check.canSwitch, isFalse, reason: 'no live video, nothing to switch');
      await check.switchCamera();

      m.controller.release(check);
      expect(engine.calls, [
        'startCapture(audio: true, video: true)',
        'setAudioEnabled(false)',
        'setVideoEnabled(false)',
        'switchCamera',
        'dispose',
      ]);
      expect(m.controller.check, isNull);
    });
  });

  group('MediaCheckController', () {
    test('setMode notifies and changes only the mode; the children open and release', () async {
      final m = fakeMediaCheck();
      var notes = 0;
      m.controller.addListener(() => notes++);

      final device = m.controller.openDevice();
      expect(m.controller.check, same(device));
      m.controller.setMode(MediaCheckMode.callPipeline);
      expect(notes, 1);
      expect(m.controller.mode, MediaCheckMode.callPipeline);
      expect(m.controller.check, same(device), reason: 'the old child lets go, not the controller');

      // The new child mounts before the old one disposes.
      final pipeline = m.controller.openPipeline(const PreviewBinding(initialize: _never, attach: _ignore));
      m.controller.release(device);
      expect(m.controller.check, same(pipeline), reason: 'a late release leaves the new check alone');
      await settle();

      final status = m.controller.status();
      expect(status['mode'], 'callPipeline');
      expect((status['check']! as Map)['mode'], 'callPipeline');

      m.controller.release(pipeline);
      expect(m.controller.status(), {'mode': 'callPipeline', 'check': null});
      m.controller.dispose();
    });
  });
}

Future<void> _never() async {}
void _ignore(Object? _) {}
