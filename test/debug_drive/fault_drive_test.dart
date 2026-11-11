/// `ext.gc.fault.{silentMove, offline, collectorStatus}`: the `debug*` seams the
/// unit tests drive, handed to the drive — success over a real [AppState] (and a
/// real [LiveCall] on the SFU rig for the move), every refusal, bad args, and the
/// outward gate on `boot: "live"`.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:gather_client/gather_client.dart';
import 'package:gather_companion/harness/scripted_call.dart';
import 'package:gather_companion/src/app_state.dart';
import 'package:gather_companion/src/debug_drive/debug_drive.dart';
import 'package:gather_companion/src/debug_drive/drive_ops.dart';
import 'package:gather_companion/src/debug_drive/install.dart';
import 'package:gather_companion/src/media/live_call.dart';
import 'package:gather_companion/src/media/media_log.dart';
import 'package:gather_events/gather_events.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fake_capture_engine.dart';
import '../sfu_rig.dart';
import 'drive_test_support.dart';

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

  DebugDrive install(AppState app, {String boot = 'harness'}) => installDebugDrive(
        enabled: true,
        app: app,
        boot: boot,
        register: RecordingRegistrar().call,
        testSpaceId: 'space-test',
        ops: DriveOps(nonce: 'flt000'),
      )!;

  Map<String, Object?> data(Map<String, Object?> body) => (body['data']! as Map).cast<String, Object?>();

  group('fault.silentMove', () {
    late Rig rig;
    late LiveCall call;
    late AppState app;

    setUp(() {
      rig = Rig();
      call = LiveCall(
        auth: GatherAuth(credentials: const GatherCredentials(refreshToken: 'unused')),
        spaceId: spaceId,
        srcId: me,
        engine: FakeCaptureEngine(),
        buildSfu: () => rig.session,
      );
      app = AppState()..debugAttachCall(call);
      addTearDown(() async {
        await call.dispose();
        await rig.close();
      });
    });

    test('repoints the own node and leaves the send transport behind (an op)', () async {
      expect(await call.setMicOn(true), isNull);
      final drive = install(app);
      final started = resultOf(await drive.invoke('ext.gc.fault.silentMove', '{"addr":"$nodeB"}'));
      expect(started['ok'], isTrue);
      final id = data(started)['id']! as String;
      await pumpEventQueue();
      final op = data(resultOf(await drive.invoke('ext.gc.op.result', '{"id":"$id"}')));
      expect(op['state'], 'done', reason: '$op');
      final result = (op['result']! as Map).cast<String, Object?>();
      expect(result['ok'], isTrue);
      expect(result['data'], {'from': nodeA, 'to': nodeB, 'node': nodeB});
      final snapshot = call.debugSfuSnapshot()!;
      final send = ((snapshot['transports']! as Map)['send']! as Map).cast<String, Object?>();
      expect(send['node'], nodeA, reason: 'the cached send transport stays on the old node');
    });

    test('a live call that has not opened its session: refused', () async {
      final body = resultOf(await install(app).invoke('ext.gc.fault.silentMove', '{"addr":"$nodeB"}'));
      expect(body['reason'], 'no_sfu_session');
      expect(body['source'], 'live');
    });

    test('bad addr is invalidParams', () async {
      final drive = install(app);
      expect(errorOf(await drive.invoke('ext.gc.fault.silentMove')).detail['error'], contains('"addr" is required'));
      expect(
        errorOf(await drive.invoke('ext.gc.fault.silentMove', '{"addr":"http://x"}')).detail['error'],
        contains('ws:// or wss://'),
      );
    });
  });

  test('fault.silentMove: no call, or a scripted one, is refused', () async {
    final none = resultOf(await install(AppState()).invoke('ext.gc.fault.silentMove', '{"addr":"$nodeB"}'));
    expect(none['reason'], 'no_call');
    final scripted = AppState()..debugAttachCall(ScriptedCall());
    final body = resultOf(await install(scripted).invoke('ext.gc.fault.silentMove', '{"addr":"$nodeB"}'));
    expect(body['reason'], 'no_sfu_session');
    expect(body['source'], 'scripted');
  });

  group('fault.offline', () {
    test('on: the app\'s own offline path; off: a transport back', () async {
      final app = AppState()..debugAttachCollector(_RecordingCollector());
      final drive = install(app);
      final on = data(resultOf(await drive.invoke('ext.gc.fault.offline', '{"on":true}')));
      expect(on['offline'], isTrue);
      expect(on['noted'], ['none']);
      expect((on['link']! as Map)['state'], 'offline');

      final off = data(resultOf(await drive.invoke('ext.gc.fault.offline', '{"on":false}')));
      expect(off['noted'], ['wifi']);
      expect((off['link']! as Map)['state'], isNot('offline'));
    });

    test('bad args are invalidParams', () async {
      final drive = install(AppState());
      expect(errorOf(await drive.invoke('ext.gc.fault.offline')).detail['error'], contains('"on" is required'));
      expect(errorOf(await drive.invoke('ext.gc.fault.offline', '{"on":1}')).detail['error'], contains('boolean'));
    });
  });

  group('fault.collectorStatus', () {
    test('an unhealthy report reaches the link and the collector health', () async {
      final app = AppState();
      final drive = install(app);
      final d = data(resultOf(await drive.invoke('ext.gc.fault.collectorStatus', '{"healthy":false,"detail":"deaf for 45s"}')));
      expect(d['noted'], {'healthy': false, 'detail': 'deaf for 45s', 'needsPairing': false});
      expect(d['link'], {'state': 'retrying', 'detail': 'deaf for 45s', 'needsPairing': false});
      expect(d['collector'], {'healthy': false, 'detail': 'deaf for 45s'});
      expect(app.snapshot.health.gather, isFalse);
    });

    test('needsPairing turns into the pairing instruction', () async {
      final d = data(resultOf(await install(AppState())
          .invoke('ext.gc.fault.collectorStatus', '{"healthy":false,"needsPairing":true,"detail":"expired"}')));
      expect((d['link']! as Map)['needsPairing'], isTrue);
    });

    test('bad args are invalidParams', () async {
      final drive = install(AppState());
      expect(errorOf(await drive.invoke('ext.gc.fault.collectorStatus')).detail['error'], contains('"healthy" is required'));
      expect(
        errorOf(await drive.invoke('ext.gc.fault.collectorStatus', '{"healthy":true,"detail":3}')).detail['error'],
        contains('"detail" must be a string'),
      );
      expect(
        errorOf(await drive.invoke('ext.gc.fault.collectorStatus', '{"healthy":true,"needsPairing":"y"}')).detail['error'],
        contains('"needsPairing" must be a boolean'),
      );
    });
  });

  group('the outward gate on boot=live', () {
    const faults = {
      'silentMove': '{"addr":"$nodeB"}',
      'offline': '{"on":true}',
      'collectorStatus': '{"healthy":false}',
    };

    test('outside the test space every fault is refused, and the app is untouched', () async {
      final app = AppState()..debugApplySnapshot(_inSpace('space-office'));
      final drive = install(app, boot: 'live');
      for (final MapEntry(key: action, value: args) in faults.entries) {
        expect(
          resultOf(await drive.invoke('ext.gc.fault.$action', args)),
          {'ok': false, 'reason': 'outward_outside_test_space', 'spaceId': 'space-office'},
          reason: action,
        );
      }
      expect(app.link.state.name, isNot('offline'));
    });

    test('in the test space, or with confirm:true, it runs', () async {
      final inTest = AppState()..debugApplySnapshot(_inSpace('space-test'));
      expect(resultOf(await install(inTest, boot: 'live').invoke('ext.gc.fault.offline', '{"on":true}'))['ok'], isTrue);
      final office = AppState()..debugApplySnapshot(_inSpace('space-office'));
      final body = resultOf(await install(office, boot: 'live')
          .invoke('ext.gc.fault.collectorStatus', '{"healthy":false,"confirm":true}'));
      expect(body['ok'], isTrue);
    });
  });
}

/// The least collector `_onConnectivityChanged` needs to flip the link offline.
class _RecordingCollector extends Fake implements Collector {
  final reachable = <bool>[];

  @override
  void setReachable(bool on) => reachable.add(on);

  @override
  Future<({bool ok, String detail})> resync() async => (ok: true, detail: 'resynced');
}
