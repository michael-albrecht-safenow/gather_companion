/// `installDebugDrive`: what one install puts on the channel, and the case the
/// compile-time guard cannot be tested for.
///
/// `kDebugMode` is always true under `flutter test`, so the release guard
/// itself is pinned by `tool/release_artifact_check.sh` against a real release
/// binary. What *can* be pinned here is the parameter that stands in for it —
/// `enabled: false` registers nothing and sets no log sink — and that the set an
/// enabled install registers is exactly the built-in set (Phase 1 plus the
/// Phase 2 media probe, plus the Phase 4 device check), all valid, with the
/// outward gate wired to the binding's space.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:gather_companion/src/app_state.dart';
import 'package:gather_companion/src/debug_drive/debug_drive.dart';
import 'package:gather_companion/src/debug_drive/drive_log.dart';
import 'package:gather_companion/src/debug_drive/drive_ops.dart';
import 'package:gather_companion/src/debug_drive/drive_result.dart';
import 'package:gather_companion/src/debug_drive/install.dart';
import 'package:gather_companion/src/media/media_log.dart';
import 'package:gather_events/gather_events.dart';

import 'drive_test_support.dart';

PresenceSnapshot _inSpace(String id) => PresenceSnapshot(
      self: SelfState(spaceId: id),
      players: const [],
      health: const CollectorHealth(),
      at: DateTime(2026, 11, 10),
    );

/// A test-only outward action, since Phase 1 ships none of its own.
DriveFeature _testWave(List<String> calls) => DriveFeature('test', [
      DriveAction('wave', (args) async {
        calls.add('wave');
        return const DriveResult.ok('waved');
      }, outward: true),
    ]);

void main() {
  tearDown(debugResetDriveLog);

  test('enabled:false registers nothing, sets no log sink, and returns null', () {
    final reg = RecordingRegistrar();
    final drive = installDebugDrive(enabled: false, app: AppState(), boot: 'live', register: reg.call);
    expect(drive, isNull);
    expect(reg.methods, isEmpty);
    expect(mediaLogDebugSink, isNull);
  });

  test('an enabled install registers the built-in set, every name valid', () {
    final reg = RecordingRegistrar();
    installDebugDrive(enabled: true, app: AppState(), boot: 'harness', register: reg.call);
    expect(reg.methods.toSet(), {
      'ext.gc.drive.list',
      'ext.gc.op.status',
      'ext.gc.op.result',
      'ext.gc.state.dump',
      'ext.gc.log.tail',
      'ext.gc.media.render',
      'ext.gc.media.snapshot',
      'ext.gc.media.watch',
      'ext.gc.mediaCheck.camera',
      'ext.gc.mediaCheck.mic',
      'ext.gc.mediaCheck.mode',
      'ext.gc.mediaCheck.playTone',
      'ext.gc.mediaCheck.retry',
      'ext.gc.mediaCheck.speaker',
      'ext.gc.mediaCheck.status',
      'ext.gc.mediaCheck.switchCamera',
      'ext.gc.sfu.debug',
      'ext.gc.call.spotlight',
      'ext.gc.call.spotlight.mode',
      'ext.gc.call.spotlight.overview',
      'ext.gc.call.spotlight.pick',
      'ext.gc.plans.state',
      'ext.gc.gameboy.mapping',
      'ext.gc.gameboy.menu.confirm',
      'ext.gc.gameboy.menu.move',
      'ext.gc.gameboy.menu.toggle',
      'ext.gc.call.state',
      'ext.gc.call.setMic',
      'ext.gc.call.setCamera',
      'ext.gc.call.setScreen',
      'ext.gc.call.setSpeaker',
      'ext.gc.call.switchCamera',
      'ext.gc.call.leave',
      'ext.gc.call.rebuild',
      'ext.gc.call.pullSessionOver',
      'ext.gc.fault.silentMove',
      'ext.gc.fault.offline',
      'ext.gc.fault.collectorStatus',
    });
    expect(reg.methods.every(DebugDrive.isValidMethod), isTrue);
  });

  test('boot must be harness or live', () {
    expect(
      () => installDebugDrive(enabled: true, app: AppState(), boot: 'sim', register: RecordingRegistrar().call),
      throwsArgumentError,
    );
  });

  test('drive.list reports every action sorted, its outward flag, and the boot', () async {
    final drive = installDebugDrive(
      enabled: true,
      app: AppState(),
      boot: 'live',
      register: RecordingRegistrar().call,
      extraFeatures: [_testWave([])],
    )!;
    final body = resultOf(await drive.invoke('ext.gc.drive.list'));
    expect(body, {
      'ok': true,
      'data': {
        'actions': [
          {'name': 'ext.gc.call.leave', 'outward': true},
          {'name': 'ext.gc.call.pullSessionOver', 'outward': true},
          {'name': 'ext.gc.call.rebuild', 'outward': true},
          {'name': 'ext.gc.call.setCamera', 'outward': true},
          {'name': 'ext.gc.call.setMic', 'outward': true},
          {'name': 'ext.gc.call.setScreen', 'outward': true},
          {'name': 'ext.gc.call.setSpeaker', 'outward': false},
          {'name': 'ext.gc.call.spotlight', 'outward': false},
          {'name': 'ext.gc.call.spotlight.mode', 'outward': false},
          {'name': 'ext.gc.call.spotlight.overview', 'outward': false},
          {'name': 'ext.gc.call.spotlight.pick', 'outward': false},
          {'name': 'ext.gc.call.state', 'outward': false},
          {'name': 'ext.gc.call.switchCamera', 'outward': true},
          {'name': 'ext.gc.drive.list', 'outward': false},
          {'name': 'ext.gc.fault.collectorStatus', 'outward': true},
          {'name': 'ext.gc.fault.offline', 'outward': true},
          {'name': 'ext.gc.fault.silentMove', 'outward': true},
          {'name': 'ext.gc.gameboy.mapping', 'outward': false},
          {'name': 'ext.gc.gameboy.menu.confirm', 'outward': true},
          {'name': 'ext.gc.gameboy.menu.move', 'outward': false},
          {'name': 'ext.gc.gameboy.menu.toggle', 'outward': false},
          {'name': 'ext.gc.log.tail', 'outward': false},
          {'name': 'ext.gc.media.render', 'outward': false},
          {'name': 'ext.gc.media.snapshot', 'outward': false},
          {'name': 'ext.gc.media.watch', 'outward': false},
          {'name': 'ext.gc.mediaCheck.camera', 'outward': false},
          {'name': 'ext.gc.mediaCheck.mic', 'outward': false},
          {'name': 'ext.gc.mediaCheck.mode', 'outward': false},
          {'name': 'ext.gc.mediaCheck.playTone', 'outward': false},
          {'name': 'ext.gc.mediaCheck.retry', 'outward': false},
          {'name': 'ext.gc.mediaCheck.speaker', 'outward': false},
          {'name': 'ext.gc.mediaCheck.status', 'outward': false},
          {'name': 'ext.gc.mediaCheck.switchCamera', 'outward': false},
          {'name': 'ext.gc.op.result', 'outward': false},
          {'name': 'ext.gc.op.status', 'outward': false},
          {'name': 'ext.gc.plans.state', 'outward': false},
          {'name': 'ext.gc.sfu.debug', 'outward': false},
          {'name': 'ext.gc.state.dump', 'outward': false},
          {'name': 'ext.gc.test.wave', 'outward': true},
        ],
        'boot': 'live',
      },
    });
  });

  test('an extra feature that collides with a built-in installs nothing at all', () {
    final reg = RecordingRegistrar();
    expect(
      () => installDebugDrive(
        enabled: true,
        app: AppState(),
        boot: 'harness',
        register: reg.call,
        extraFeatures: [
          DriveFeature('state', [DriveAction('dump', (_) async => const DriveResult.ok())]),
        ],
      ),
      throwsArgumentError,
    );
    expect(reg.methods, isEmpty);
    expect(mediaLogDebugSink, isNull, reason: 'a refused install leaves no sink behind');
  });

  test('the install feeds media.log lines into log.tail', () async {
    final buffer = DriveLogBuffer();
    final drive = installDebugDrive(
      enabled: true,
      app: AppState(),
      boot: 'harness',
      register: RecordingRegistrar().call,
      logBuffer: buffer,
    )!;
    mediaLogToFile('walk: refused, tile blocked');
    final body = resultOf(await drive.invoke('ext.gc.log.tail', '{"since":0}'));
    final lines = [for (final l in (body['data']! as Map)['lines'] as List) (l as Map)['line']];
    expect(lines, contains('walk: refused, tile blocked'));
  });

  test('startDriveLog keeps lines from launch, and the later install tails them', () async {
    startDriveLog(enabled: true);
    mediaLogToFile('gcal: no GOOGLE_CLIENT_ID compiled in — feature disabled');
    final drive = installDebugDrive(
      enabled: true,
      app: AppState(),
      boot: 'live',
      register: RecordingRegistrar().call,
    )!;
    final body = resultOf(await drive.invoke('ext.gc.log.tail', '{"since":0}'));
    final lines = [for (final l in (body['data']! as Map)['lines'] as List) (l as Map)['line']];
    expect(lines, contains('gcal: no GOOGLE_CLIENT_ID compiled in — feature disabled'));
  });

  test('startDriveLog with enabled:false keeps nothing', () {
    startDriveLog(enabled: false);
    expect(mediaLogDebugSink, isNull);
  });

  test('ops started on the injected DriveOps are polled through op.result', () async {
    final ops = DriveOps(nonce: 'inst00');
    final drive = installDebugDrive(enabled: true, app: AppState(), boot: 'harness', register: RecordingRegistrar().call, ops: ops)!;
    final id = ops.start('probe', Future.value({'v': 1}));
    await pumpEventQueue();
    final body = resultOf(await drive.invoke('ext.gc.op.result', '{"id":"$id"}'));
    expect((body['data']! as Map)['result'], {'v': 1});
  });

  group('the outward gate, wired to the app', () {
    Future<Map<String, Object?>> wave(AppState app, {required String boot, String testSpaceId = 'space-test', String? args}) async {
      final drive = installDebugDrive(
        enabled: true,
        app: app,
        boot: boot,
        register: RecordingRegistrar().call,
        testSpaceId: testSpaceId,
        extraFeatures: [_testWave([])],
      )!;
      return resultOf(await drive.invoke('ext.gc.test.wave', args));
    }

    test('live, in another space: refused, naming the space', () async {
      final body = await wave(AppState()..debugApplySnapshot(_inSpace('space-office')), boot: 'live');
      expect(body, {'ok': false, 'reason': 'outward_outside_test_space', 'spaceId': 'space-office'});
    });

    test('live, in the test space: runs', () async {
      expect((await wave(AppState()..debugApplySnapshot(_inSpace('space-test')), boot: 'live'))['ok'], isTrue);
    });

    test('live, another space, confirm:true: runs', () async {
      final app = AppState()..debugApplySnapshot(_inSpace('space-office'));
      expect((await wave(app, boot: 'live', args: '{"confirm":true}'))['ok'], isTrue);
    });

    test('live, no test space compiled in: every space is outside it', () async {
      final app = AppState()..debugApplySnapshot(_inSpace('space-office'));
      expect((await wave(app, boot: 'live', testSpaceId: ''))['reason'], 'outward_outside_test_space');
    });

    test('harness: never gated', () async {
      final app = AppState()..debugApplySnapshot(_inSpace('space-office'));
      expect((await wave(app, boot: 'harness'))['ok'], isTrue);
    });
  });

  test('a second real install in the isolate rebinds instead of registering twice', () async {
    // The real dart:developer registrar: this is the one test that leaves
    // methods on its isolate, and the second call is the point — registering
    // again would throw from registerExtension.
    final first = AppState()..debugApplySnapshot(_inSpace('space-a'));
    final second = AppState()..debugApplySnapshot(_inSpace('space-b'));
    final a = installDebugDrive(enabled: true, app: first, boot: 'harness')!;
    final b = installDebugDrive(enabled: true, app: second, boot: 'live')!;
    expect(identical(a, b), isTrue);

    final dump = resultOf(await b.invoke('ext.gc.state.dump'));
    expect((dump['data']! as Map)['spaceId'], 'space-b');
    expect((dump['data']! as Map)['boot'], 'live');
  });

  test('a rebind that asks for new features throws instead of dropping them', () {
    // Real registrar, like the test above: the first call installs or rebinds,
    // whichever this isolate needs; the second is the one under test.
    installDebugDrive(enabled: true, app: AppState(), boot: 'harness');
    expect(
      () => installDebugDrive(
        enabled: true,
        app: AppState(),
        boot: 'harness',
        extraFeatures: [_testWave([])],
      ),
      throwsStateError,
    );
    expect(
      () => installDebugDrive(enabled: true, app: AppState(), boot: 'harness', ops: DriveOps()),
      throwsStateError,
    );
  });
}
