/// `ext.gc.call.{state, setMic, setCamera, setScreen, setSpeaker, switchCamera,
/// leave, rebuild, pullSessionOver}`: the dock's buttons through the drive, over a
/// real [AppState] with a fake call attached — success, every refusal, bad args,
/// and the outward gate on `boot: "live"`.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:gather_companion/harness/fake_collector.dart';
import 'package:gather_companion/src/app_state.dart';
import 'package:gather_companion/src/debug_drive/debug_drive.dart';
import 'package:gather_companion/src/debug_drive/drive_ops.dart';
import 'package:gather_companion/src/debug_drive/install.dart';
import 'package:gather_companion/src/media/call.dart';
import 'package:gather_companion/src/media/media_engine.dart';
import 'package:gather_companion/src/media/media_log.dart';
import 'package:gather_events/gather_events.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fake_call.dart';
import 'drive_test_support.dart';

/// A [FakeCall] whose state and answers a test can set.
class _ControlledCall extends FakeCall {
  CallState current = const CallState();
  String? fails;
  final cameraCalls = <bool>[];
  int switches = 0;

  @override
  CallState get state => current;

  @override
  Future<String?> setMicOn(bool on) async {
    await super.setMicOn(on);
    if (fails == null) current = current.copyWith(media: LocalMediaState(capturing: true, audioEnabled: on));
    return fails;
  }

  @override
  Future<String?> setCameraOn(bool on) async {
    cameraCalls.add(on);
    return fails;
  }

  @override
  Future<String?> setScreenShareOn(bool on) async {
    await super.setScreenShareOn(on);
    return fails;
  }

  @override
  Future<String?> setSpeakerOn(bool on) async {
    await super.setSpeakerOn(on);
    return fails;
  }

  @override
  Future<void> switchCamera() async => switches++;

  @override
  Future<String?> pullSessionOver() async {
    await super.pullSessionOver();
    return fails;
  }
}

PresenceSnapshot _inSpace(String id) => PresenceSnapshot(
      self: SelfState(spaceId: id),
      players: const [],
      health: const CollectorHealth(),
      at: DateTime(2026, 11, 11),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() => mediaLogDebugSink = null);

  late AppState app;
  late _ControlledCall call;
  late DebugDrive drive;

  DebugDrive install(AppState a, {String boot = 'harness'}) => installDebugDrive(
        enabled: true,
        app: a,
        boot: boot,
        register: RecordingRegistrar().call,
        testSpaceId: 'space-test',
        ops: DriveOps(nonce: 'call00'),
      )!;

  setUp(() {
    call = _ControlledCall();
    app = AppState()..debugAttachCall(call);
    drive = install(app);
  });

  Future<Map<String, Object?>> run(String action, [String? args]) async =>
      resultOf(await drive.invoke('ext.gc.call.$action', args));

  Map<String, Object?> data(Map<String, Object?> body) => (body['data']! as Map).cast<String, Object?>();

  /// Starts an op action and answers its finished result.
  Future<Map<String, Object?>> runOp(String action, [String? args]) async {
    final started = await run(action, args);
    expect(started['ok'], isTrue, reason: '$started');
    final id = data(started)['id']! as String;
    expect(id, startsWith('$action-'));
    await pumpEventQueue();
    final polled = resultOf(await drive.invoke('ext.gc.op.result', '{"id":"$id"}'));
    final op = data(polled);
    expect(op['state'], 'done', reason: '$op');
    return (op['result']! as Map).cast<String, Object?>();
  }

  group('call.state', () {
    test('with a call: what it publishes, the route and who is there', () async {
      call.current = const CallState(
        media: LocalMediaState(capturing: true, audioEnabled: true, audioOutput: AudioOutput.speaker),
        publishingAudio: true,
        participants: [CallParticipant(srcId: 'acct-bob', hasAudio: true)],
        connecting: {'acct-zed', 'acct-amy'},
      );
      final body = await run('state');
      expect(body['ok'], isTrue);
      final d = data(body);
      expect(d['boot'], 'harness');
      expect(d['hasCall'], isTrue);
      expect(d['source'], 'scripted');
      expect(d['micOn'], isTrue);
      expect(d['cameraOn'], isFalse);
      expect(d['publishingAudio'], isTrue);
      expect(d['audioOutput'], 'speaker');
      expect(d['connecting'], ['acct-amy', 'acct-zed']);
      expect((d['participants']! as List).single, containsPair('srcId', 'acct-bob'));
    });

    test('with no call it says so rather than reading as everything off', () async {
      drive = install(AppState());
      final d = data(await run('state'));
      expect(d['hasCall'], isFalse);
      expect(d['source'], 'none');
      expect(d['canCall'], isFalse);
    });
  });

  group('setMic / setCamera / setScreen (ops)', () {
    test('setMic runs AppState.setMicOn and answers the readout', () async {
      final result = await runOp('setMic', '{"on":true}');
      expect(call.micCalls, [true]);
      expect(result['ok'], isTrue);
      expect((result['data']! as Map)['micOn'], isTrue);
    });

    test('setCamera and setScreen reach the call', () async {
      expect((await runOp('setCamera', '{"on":true}'))['ok'], isTrue);
      expect((await runOp('setScreen', '{"on":false}'))['ok'], isTrue);
      expect(call.cameraCalls, [true]);
      expect(call.screenCalls, [false]);
    });

    test('a sentence back is refused failed, never ok', () async {
      call.fails = 'Microphone permission denied.';
      final result = await runOp('setMic', '{"on":true}');
      expect(result['ok'], isFalse);
      expect(result['reason'], 'failed');
      expect(result['detail'], 'Microphone permission denied.');
    });

    test('no call and not enough identity to open one: cannot_call', () async {
      drive = install(AppState());
      for (final action in ['setMic', 'setCamera', 'setScreen', 'setSpeaker']) {
        expect((await run(action, '{"on":true}'))['reason'], 'cannot_call', reason: action);
      }
    });

    test('bad args are invalidParams', () async {
      for (final action in ['setMic', 'setCamera', 'setScreen', 'setSpeaker']) {
        expect(errorOf(await drive.invoke('ext.gc.call.$action')).detail['error'], contains('"on" is required'));
        expect(
          errorOf(await drive.invoke('ext.gc.call.$action', '{"on":"yes"}')).detail['error'],
          contains('"on" must be a boolean'),
        );
      }
    });
  });

  test('setSpeaker answers at once with the readout, and a failure as failed', () async {
    expect((await run('setSpeaker', '{"on":true}'))['ok'], isTrue);
    expect(call.speakerCalls, [true]);
    call.fails = 'No speaker.';
    final body = await run('setSpeaker', '{"on":false}');
    expect(body['reason'], 'failed');
    expect(body['detail'], 'No speaker.');
  });

  group('switchCamera', () {
    test('flips a running camera', () async {
      call.current = const CallState(media: LocalMediaState(capturing: true, videoEnabled: true, videoTrackId: 'v1'));
      expect((await run('switchCamera'))['ok'], isTrue);
      expect(call.switches, 1);
    });

    test('camera off: refused, not an ok for a no-op', () async {
      expect((await run('switchCamera'))['reason'], 'camera_off');
      expect(call.switches, 0);
    });

    test('no call: refused', () async {
      drive = install(AppState());
      expect((await run('switchCamera'))['reason'], 'no_call');
    });
  });

  group('leave', () {
    test('in a huddle: AppState.leaveHuddle', () async {
      app
        ..debugHuddle = ['Bob']
        ..debugAttachCollector(FakeCollector());
      final body = await run('leave');
      expect(body['ok'], isTrue);
    });

    test('a sentence back is refused failed', () async {
      app.debugHuddle = ['Bob']; // no collector: "Not connected to Gather."
      final body = await run('leave');
      expect(body['reason'], 'failed');
      expect(body['detail'], 'Not connected to Gather.');
    });

    test('no huddle: refused', () async {
      expect((await run('leave'))['reason'], 'not_in_huddle');
    });
  });

  group('rebuild', () {
    test('an op over Call.rebuild', () async {
      expect((await runOp('rebuild'))['ok'], isTrue);
      expect(call.rebuilds, 1);
    });

    test('no call: refused', () async {
      drive = install(AppState());
      expect((await run('rebuild'))['reason'], 'no_call');
    });
  });

  group('pullSessionOver', () {
    test('with needsHandoff: an op over AppState.pullSessionOver', () async {
      call.current = const CallState(needsHandoff: true);
      expect((await runOp('pullSessionOver'))['ok'], isTrue);
      expect(call.pulls, 1);
    });

    test('a failed reclaim is refused failed', () async {
      call
        ..current = const CallState(needsHandoff: true)
        ..fails = 'Could not reconnect to the room. Tap to try again.';
      final result = await runOp('pullSessionOver');
      expect(result['reason'], 'failed');
    });

    test('the button is hidden without needsHandoff: refused', () async {
      expect((await run('pullSessionOver'))['reason'], 'no_handoff_needed');
      expect(call.pulls, 0);
    });

    test('no call: refused', () async {
      drive = install(AppState());
      expect((await run('pullSessionOver'))['reason'], 'no_call');
    });
  });

  group('the outward gate on boot=live', () {
    const outward = {
      'setMic': '{"on":true}',
      'setCamera': '{"on":true}',
      'setScreen': '{"on":true}',
      'switchCamera': '{}',
      'leave': '{}',
      'pullSessionOver': '{}',
      'rebuild': '{}',
    };

    test('outside the test space: every outward control is refused, and nothing reached the call', () async {
      app.debugApplySnapshot(_inSpace('space-office'));
      drive = install(app, boot: 'live');
      for (final MapEntry(key: action, value: args) in outward.entries) {
        final body = await run(action, args);
        expect(body, {'ok': false, 'reason': 'outward_outside_test_space', 'spaceId': 'space-office'}, reason: action);
      }
      expect(call.micCalls, isEmpty);
      expect(call.cameraCalls, isEmpty);
      expect(call.screenCalls, isEmpty);
      expect(call.switches, 0);
      expect(call.pulls, 0);
      expect(call.rebuilds, 0);
    });

    test('confirm:true lets it through', () async {
      app.debugApplySnapshot(_inSpace('space-office'));
      drive = install(app, boot: 'live');
      expect((await run('setMic', '{"on":true,"confirm":true}'))['ok'], isTrue);
    });

    test('in the test space: runs', () async {
      app.debugApplySnapshot(_inSpace('space-test'));
      drive = install(app, boot: 'live');
      expect((await runOp('setMic', '{"on":true}'))['ok'], isTrue);
      expect(call.micCalls, [true]);
    });

    test('state and setSpeaker are not gated', () async {
      app.debugApplySnapshot(_inSpace('space-office'));
      drive = install(app, boot: 'live');
      expect((await run('state'))['ok'], isTrue);
      expect((await run('setSpeaker', '{"on":true}'))['ok'], isTrue);
    });
  });
}
