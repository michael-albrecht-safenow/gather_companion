/// `ext.gc.mediaCheck.*` through the registry: the readout with the screen
/// closed and open, each control refused exactly where the screen hides it, and
/// — with the real `MediaCheckScreen` mounted over fake hardware — the drive
/// and the buttons moving the same controller, the hook cleared when the
/// screen goes, and a mode switch tearing the device check down for the
/// pipeline one.
library;

import 'package:camera/camera.dart' show CameraException;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gather_companion/src/app_state.dart';
import 'package:gather_companion/src/debug_drive/debug_drive.dart';
import 'package:gather_companion/src/debug_drive/install.dart';
import 'package:gather_companion/src/media/media_check_controller.dart';
import 'package:gather_companion/src/media/media_engine.dart';
import 'package:gather_companion/src/media/media_log.dart';
import 'package:gather_companion/theme/gather_theme.dart';
import 'package:gather_companion/ui/media_check_screen.dart';

import '../fake_media_check.dart';
import 'drive_test_support.dart';

Future<void> settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() {
    mediaCheckDebugActive = null;
    mediaLogDebugSink = null;
    debugResetDriveLog();
  });

  DebugDrive install({String boot = 'harness'}) =>
      installDebugDrive(enabled: true, app: AppState(), boot: boot, register: RecordingRegistrar().call)!;

  Future<Map<String, Object?>> call(DebugDrive drive, String action, [String args = '{}']) async =>
      resultOf(await drive.invoke('ext.gc.mediaCheck.$action', args));

  Map<String, Object?> checkOf(Map<String, Object?> body) =>
      ((body['data']! as Map)['check']! as Map).cast<String, Object?>();

  group('screen closed', () {
    test('status says so, with the boot', () async {
      final drive = install(boot: 'live');
      final body = await call(drive, 'status');
      expect(body['ok'], isTrue);
      expect(body['data'], containsPair('screenOpen', false));
      expect(body['data'], containsPair('boot', 'live'));
    });

    test('every control is refused screen_closed', () async {
      final drive = install();
      for (final (action, args) in [
        ('mode', '{"mode":"device"}'),
        ('retry', '{}'),
        ('mic', '{"live":false}'),
        ('camera', '{"on":false}'),
        ('switchCamera', '{}'),
        ('speaker', '{"on":false}'),
        ('playTone', '{}'),
      ]) {
        final body = await call(drive, action, args);
        expect(body, containsPair('ok', false), reason: action);
        expect(body, containsPair('reason', 'screen_closed'), reason: action);
      }
    });

    test('nothing here is outward', () async {
      final drive = install();
      final mediaCheck = drive.actions.where((a) => a.name.startsWith('ext.gc.mediaCheck.'));
      expect(mediaCheck, hasLength(8));
      expect(mediaCheck.every((a) => !a.outward), isTrue);
    });
  });

  group('device check open', () {
    late DebugDrive drive;
    late FakeMediaCheck m;

    Future<void> openDevice({DeviceRig? rig}) async {
      m = fakeMediaCheck(device: rig);
      mediaCheckDebugActive = m.controller;
      m.controller.openDevice();
      await settle();
    }

    setUp(() => drive = install());
    tearDown(() {
      final c = m.controller.check;
      if (c != null) m.controller.release(c);
    });

    test('status reads the check', () async {
      await openDevice();
      final body = await call(drive, 'status');
      final data = (body['data']! as Map).cast<String, Object?>();
      expect(data['screenOpen'], isTrue);
      expect(data['boot'], 'harness');
      expect(data['mode'], 'device');
      expect(data['check'], {
        'mode': 'device',
        'starting': false,
        'failure': null,
        'showControls': true,
        'cameraCount': 2,
        'cameraOpen': true,
        'frontCamera': true,
        'canSwitch': true,
        'videoOn': true,
        'micLive': true,
        'meter': 'open',
        'hearing': false,
        'speaker': true,
        'tonesPlayed': 0,
      });
    });

    test('mic, camera, switch, speaker and playTone are the controller calls', () async {
      await openDevice();
      expect(checkOf(await call(drive, 'mic', '{"live":false}'))['micLive'], isFalse);
      expect(m.device.mic.calls.last, 'pause');
      expect(checkOf(await call(drive, 'camera', '{"on":false}'))['videoOn'], isFalse);
      expect(m.device.opened.single.paused, isTrue);
      expect(checkOf(await call(drive, 'switchCamera'))['frontCamera'], isFalse);
      expect(checkOf(await call(drive, 'speaker', '{"on":false}'))['speaker'], isFalse);
      expect(checkOf(await call(drive, 'playTone'))['tonesPlayed'], 1);
      expect(m.device.tone.played.single.speaker, isFalse);
    });

    test('playTone with Sound effects off is refused, and plays nothing', () async {
      await openDevice(rig: DeviceRig()..soundEffects = false);
      final body = await call(drive, 'playTone');
      expect(body, containsPair('reason', 'sound_effects_off'));
      expect(m.device.tone.played, isEmpty);
    });

    test('playTone whose player throws is refused play_failed, with the error', () async {
      await openDevice();
      m.device.tone.failNext = StateError('audio session busy');
      final body = await call(drive, 'playTone');
      expect(body, containsPair('ok', false));
      expect(body, containsPair('reason', 'play_failed'));
      expect(body.toString(), contains('audio session busy'));
      expect(checkOf(await call(drive, 'status'))['tonesPlayed'], 0);
    });

    test('one camera cannot switch', () async {
      await openDevice(rig: DeviceRig(cameras: [frontCam]));
      expect(await call(drive, 'switchCamera'), containsPair('reason', 'cannot_switch'));
    });

    test('no camera: the camera toggle is refused, the mic still works', () async {
      await openDevice(rig: DeviceRig(cameras: []));
      expect(await call(drive, 'camera', '{"on":false}'), containsPair('reason', 'no_camera'));
      expect(checkOf(await call(drive, 'mic', '{"live":false}'))['micLive'], isFalse);
    });

    test('retry: refused with nothing to retry, performed after a retryable failure', () async {
      await openDevice();
      expect(await call(drive, 'retry'), containsPair('reason', 'nothing_to_retry'));
      // Let go of the first check before the second replaces `m`, so the group
      // tearDown (which releases only the current one) leaves nothing open.
      m.controller.release(m.controller.check!);

      await openDevice(rig: DeviceRig()..failNext.add(CameraException('Busy', 'in use')));
      expect(checkOf(await call(drive, 'retry'))['failure'], isNull);
      expect(m.device.opened, hasLength(2));
    });

    test('a refused permission: controls hidden, retry needs Settings', () async {
      await openDevice(rig: DeviceRig()..failNext.add(CameraException('CameraAccessDenied', null)));
      final mic = await call(drive, 'mic', '{"live":false}');
      expect(mic, containsPair('reason', 'controls_hidden'));
      expect((mic['failure']! as Map)['problem'], 'permission');
      final retry = await call(drive, 'retry');
      expect(retry, containsPair('reason', 'needs_settings'));
      expect(m.device.opened, hasLength(1));
    });

    test('bad args are invalidParams naming the field', () async {
      await openDevice();
      for (final (action, args, field) in [
        ('mic', '{}', 'live'),
        ('mic', '{"live":"yes"}', 'live'),
        ('camera', '{"on":1}', 'on'),
        ('mode', '{"mode":"pipeline"}', 'mode'),
        ('mode', '{}', 'mode'),
      ]) {
        final err = errorOf(await drive.invoke('ext.gc.mediaCheck.$action', args));
        expect(err.code, -32602, reason: '$action $args');
        expect(err.detail.toString(), contains('"$field"'), reason: '$action $args');
      }
    });

    test('mode answers at once; between checks status says check: null and controls say no_check', () async {
      await openDevice();
      final body = await call(drive, 'mode', '{"mode":"callPipeline"}');
      expect(body['data'], {'mode': 'callPipeline', 'from': 'device', 'changed': true});
      // No widget here to swap the child, so release by hand as its dispose would.
      m.controller.release(m.controller.check!);
      final status = (await call(drive, 'status'))['data']! as Map;
      expect(status['mode'], 'callPipeline');
      expect(status['check'], isNull);
      expect(await call(drive, 'mic', '{"live":true}'), containsPair('reason', 'no_check'));
    });
  });

  group('pipeline check open', () {
    test('speaker and playTone are refused; mic and camera reach the engine', () async {
      final drive = install();
      final m = fakeMediaCheck();
      mediaCheckDebugActive = m.controller;
      final check = m.controller.openPipeline(PreviewBinding(initialize: () async {}, attach: (_) {}));
      await settle();

      expect(await call(drive, 'speaker', '{"on":true}'), containsPair('reason', 'not_in_device_mode'));
      expect(await call(drive, 'playTone'), containsPair('reason', 'not_in_device_mode'));
      expect(checkOf(await call(drive, 'mic', '{"live":false}'))['micLive'], isFalse);
      expect(checkOf(await call(drive, 'camera', '{"on":false}'))['videoOn'], isFalse);
      expect(await call(drive, 'switchCamera'), containsPair('reason', 'cannot_switch'),
          reason: 'with the camera off there is no live video to switch');
      expect(m.engines.single.calls, containsAllInOrder(['setAudioEnabled(false)', 'setVideoEnabled(false)']));
      m.controller.release(check);
    });

    test('a refused capture permission: controls hidden, retry needs Settings', () async {
      final drive = install();
      final m = fakeMediaCheck();
      mediaCheckDebugActive = m.controller;
      final check = m.controller.openPipeline(PreviewBinding(initialize: () async {}, attach: (_) {}));
      m.engines.single.failWith = const MediaFailure(MediaFailureKind.permissionDenied, 'no');
      await settle();
      expect(await call(drive, 'mic', '{"live":true}'), containsPair('reason', 'controls_hidden'));
      expect(await call(drive, 'retry'), containsPair('reason', 'needs_settings'));
      m.controller.release(check);
    });
  });

  group('with the screen mounted', () {
    const channel = MethodChannel('FlutterWebRTC.Method');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    late List<String> rendererCalls;

    setUp(() {
      rendererCalls = [];
      var texture = 1;
      messenger.setMockMethodCallHandler(channel, (c) async {
        rendererCalls.add(c.method);
        return c.method == 'createVideoRenderer' ? {'textureId': texture++} : null;
      });
    });
    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    Widget screen(MediaCheckController controller) => MaterialApp(
          theme: buildGatherTheme(),
          home: MediaCheckScreen(state: AppState(), controller: controller),
        );

    testWidgets('the drive and the buttons move the same controller', (tester) async {
      final drive = install();
      final m = fakeMediaCheck();
      await tester.pumpWidget(screen(m.controller));
      await tester.pump();
      expect(mediaCheckDebugActive, same(m.controller));
      expect(find.text('Say something — the light comes on when it hears you'), findsOneWidget);

      m.device.mic.push(0.5);
      await tester.pump();
      await tester.pump();
      expect(find.text('We can hear you'), findsOneWidget);
      expect((await call(drive, 'status'))['data'], containsPair('check', containsPair('hearing', true)));

      await call(drive, 'mic', '{"live":false}');
      await tester.pump();
      expect(find.text('Microphone muted'), findsOneWidget);

      await tester.tap(find.text('Muted'));
      await tester.pump();
      expect(checkOf(await call(drive, 'status'))['micLive'], isTrue);
    });

    testWidgets('a mode switch through the drive tears the device check down for the pipeline', (tester) async {
      final drive = install();
      final m = fakeMediaCheck(widgetPreview: true);
      await tester.pumpWidget(screen(m.controller));
      await tester.pump();
      final device = m.controller.check;
      expect(device, isA<DeviceCheck>());

      await call(drive, 'mode', '{"mode":"callPipeline"}');
      await tester.pump();
      await tester.pump();
      expect(m.device.mic.calls.last, 'dispose', reason: 'the device check let go of the microphone');
      expect(m.device.opened.single.disposed, isTrue);
      final pipeline = m.controller.check;
      expect(pipeline, isA<PipelineCheck>());
      expect(rendererCalls, contains('createVideoRenderer'));
      expect(m.previews.single.attached.single, isNotNull);
      expect(find.text('The WebRTC capture path — camera and mute.'), findsOneWidget);

      // Back to device: the renderer detaches and the engine is disposed.
      await call(drive, 'mode', '{"mode":"device"}');
      await tester.pump();
      await tester.pump();
      expect(m.engines.single.calls.last, 'dispose');
      // The renderer was detached: the dispose's `srcObject = null` is the only
      // set it saw (the fake attach does not reach it). Its own native dispose
      // waits on an event channel this test does not mock.
      expect(rendererCalls.where((c) => c == 'videoRendererSetSrcObject'), hasLength(1));
      expect(m.controller.check, isA<DeviceCheck>());

      await tester.pumpWidget(const SizedBox());
      expect(mediaCheckDebugActive, isNull, reason: 'the hook goes with the screen');
      expect((await call(drive, 'status'))['data'], containsPair('screenOpen', false));
    });
  });
}
