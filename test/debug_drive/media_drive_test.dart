/// `media.snapshot` and `media.watch`, through the registry exactly as an agent
/// would call them.
///
/// The watch runs on a fake clock: the drive's sleep seam advances a clock the
/// [ScriptedCall] reads, so a thirty-second watch is a loop of microtasks and its
/// gaps are exact. A [FakeCall] with hand-built samples pins the snapshot's
/// shape; the [ScriptedCall] pins the harness path — the one an agent uses on
/// the simulator — including a stall injected mid-watch and a missing consumer.
library;

import 'dart:developer';

import 'package:flutter_test/flutter_test.dart';
import 'package:gather_companion/harness/scripted_call.dart';
import 'package:gather_companion/src/app_state.dart';
import 'package:gather_companion/src/debug_drive/builtin_features.dart';
import 'package:gather_companion/src/debug_drive/debug_drive.dart';
import 'package:gather_companion/src/debug_drive/drive_ops.dart';
import 'package:gather_companion/src/debug_drive/install.dart';
import 'package:gather_companion/src/debug_drive/media_drive.dart';
import 'package:gather_companion/src/media/call.dart';
import 'package:gather_companion/src/media/media_engine.dart';
import 'package:gather_companion/src/media/media_flow.dart';
import 'package:gather_companion/src/media/media_log.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fake_call.dart';
import 'drive_test_support.dart';

final _t0 = DateTime.utc(2026, 11, 11, 9);

/// A clock the drive's sleep advances, and the sleeps it was asked for.
class _Clock {
  DateTime now = _t0;
  final List<Duration> slept = [];
  void Function(int n)? onSleep;

  Future<void> sleep(Duration d) async {
    slept.add(d);
    now = now.add(d);
    onSleep?.call(slept.length);
  }
}

DebugDrive _drive(AppState app, _Clock clock) => installDebugDrive(
      enabled: true,
      app: app,
      boot: 'harness',
      register: RecordingRegistrar().call,
      mediaSleep: clock.sleep,
    )!;

Future<Map<String, Object?>> _data(DebugDrive drive, String method, [String? args]) async {
  final body = resultOf(await drive.invoke(method, args));
  expect(body['ok'], isTrue, reason: '$body');
  return (body['data']! as Map).cast<String, Object?>();
}

/// Polls `op.result` until the op is no longer pending.
Future<Map<String, Object?>> _opResult(DebugDrive drive, String id) async {
  for (var i = 0; i < 1000; i++) {
    final data = await _data(drive, 'ext.gc.op.result', '{"id":"$id"}');
    if (data['state'] != 'pending') return data;
    await pumpEventQueue();
  }
  fail('op $id never finished');
}

Map<String, Object?> _stream(Map<String, Object?> result, String key) =>
    ((result['streams']! as List).cast<Map<String, Object?>>()).singleWhere((s) => s['key'] == key);

MediaFlowSample _sample(int ms, int packets, {double energy = 0}) => MediaFlowSample(
      at: _t0.add(Duration(milliseconds: ms)),
      source: 'scripted',
      inbound: [
        InboundFlow(
          srcId: 'bob',
          tag: 'audio',
          paused: false,
          consumerId: 'c1',
          rowFound: true,
          counters: InboundCounters(packetsReceived: packets, bytesReceived: packets * 80, totalAudioEnergy: energy, packetsLost: 0),
        ),
      ],
      expected: const [ExpectedStream('bob', 'audio')],
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() => mediaLogDebugSink = null);

  group('with no call', () {
    test('snapshot and watch are refused no_call — an answer, not an error', () async {
      final drive = _drive(AppState(), _Clock());
      for (final method in ['ext.gc.media.snapshot', 'ext.gc.media.watch']) {
        final body = resultOf(await drive.invoke(method));
        expect(body, {'ok': false, 'reason': 'no_call'}, reason: method);
      }
    });

    test('both are listed, and neither is outward', () async {
      final drive = _drive(AppState(), _Clock());
      final actions = (await _data(drive, 'ext.gc.drive.list'))['actions']! as List;
      for (final name in ['ext.gc.media.snapshot', 'ext.gc.media.watch']) {
        expect(actions, contains(equals({'name': name, 'outward': false})));
      }
    });
  });

  group('snapshot', () {
    test('takes its own two-second series and reports the last interval', () async {
      final clock = _Clock();
      final app = AppState();
      final call = FakeCall()
        ..flowSamples.addAll([
          _sample(0, 0),
          _sample(1000, 50, energy: 0.1),
          _sample(2000, 100, energy: 0.1), // DTX: packets, no energy
        ]);
      app.debugAttachCall(call);
      final data = await _data(_drive(app, clock), 'ext.gc.media.snapshot');

      expect(call.flowSampled, 3);
      expect(clock.slept, [const Duration(seconds: 1), const Duration(seconds: 1)]);
      expect(data['source'], 'scripted');
      expect(data['windowMs'], 2000);
      final verdict = (data['verdicts']! as List).single as Map;
      expect(verdict['key'], 'in:bob|audio');
      expect(verdict['verdict'], 'silent');
      final sample = data['sample']! as Map;
      expect((sample['inbound']! as List).single, containsPair('srcId', 'bob'));
      expect(sample['expected'], [
        {'srcId': 'bob', 'tag': 'audio'},
      ]);
    });

    test('a call that ends during the series is refused no_call, with the detail', () async {
      final clock = _Clock();
      Call? current = FakeCall()..flowSamples.addAll([_sample(0, 0), _sample(1000, 50, energy: 0.1)]);
      final ops = DriveOps(nonce: 'n00000');
      final drive = DebugDrive(boot: () => 'harness', spaceId: () => null, inTestSpace: () => false, register: RecordingRegistrar().call)
        ..install([opFeature(ops), mediaFeature(call: () => current, ops: ops, sleep: clock.sleep)]);
      clock.onSleep = (_) => current = null;
      expect(resultOf(await drive.invoke('ext.gc.media.snapshot')), {
        'ok': false,
        'reason': 'no_call',
        'detail': 'call ended during the snapshot',
      });
    });

    test('a window outside 500..3000 is invalidParams', () async {
      final app = AppState()..debugAttachCall(FakeCall());
      final drive = _drive(app, _Clock());
      final e = errorOf(await drive.invoke('ext.gc.media.snapshot', '{"windowMs":10000}'));
      expect(e.code, ServiceExtensionResponse.invalidParams);
      expect(e.detail['error'], '"windowMs" must be <= 3000');
    });

    test('a call with nothing to read answers an empty sample that says why', () async {
      final app = AppState()..debugAttachCall(FakeCall());
      final data = await _data(_drive(app, _Clock()), 'ext.gc.media.snapshot', '{"windowMs":500}');
      expect(data['verdicts'], isEmpty);
      expect((data['sample']! as Map)['errors'], [
        {'scope': 'call', 'error': 'not_scripted'},
      ]);
    });
  });

  group('watch', () {
    test('params are bounded: intervalMs >= 250, durationMs <= 120000', () async {
      final app = AppState()..debugAttachCall(FakeCall());
      final drive = _drive(app, _Clock());
      expect(errorOf(await drive.invoke('ext.gc.media.watch', '{"intervalMs":100}')).detail['error'], '"intervalMs" must be >= 250');
      expect(errorOf(await drive.invoke('ext.gc.media.watch', '{"durationMs":200000}')).detail['error'], '"durationMs" must be <= 120000');
    });

    test('a healthy scripted call: every stream continuous, with rates', () async {
      final clock = _Clock();
      final app = AppState();
      final call = ScriptedCall(now: () => clock.now)
        ..emit(const CallState(
          publishingAudio: true,
          media: _micOn,
          participants: [CallParticipant(srcId: 'bob', hasAudio: true, hasVideo: true)],
        ));
      app.debugAttachCall(call);
      final drive = _drive(app, clock);

      final started = await _data(drive, 'ext.gc.media.watch', '{"durationMs":5000}');
      expect(started, containsPair('durationMs', 5000));
      expect(started['intervalMs'], 1000);
      expect(started['maxGapMs'], 2000);
      final op = await _opResult(drive, started['id']! as String);
      expect(op['state'], 'done');
      final result = (op['result']! as Map).cast<String, Object?>();

      expect(result['source'], 'scripted');
      expect(result['samples'], 6, reason: 'a baseline plus one per interval');
      expect(result['durationMs'], 5000);
      expect(result['allContinuous'], isTrue);
      expect(result['endedEarly'], isNull);
      expect((result['timeline']! as List), hasLength(6));

      final audio = _stream(result, 'in:bob|audio');
      expect(audio['verdicts'], {'flowing': 5});
      expect(audio['continuous'], isTrue);
      expect(audio['gaps'], isEmpty);
      expect(audio['avgBitrateKbps'], 32.0);
      expect(audio['lossPct'], 0.0);

      final video = _stream(result, 'in:bob|video');
      expect(video['avgFps'], 24.0);
      expect(video['avgBitrateKbps'], 500.0);

      final mic = _stream(result, 'out:audio');
      expect(mic['direction'], 'outbound');
      expect(mic['verdicts'], {'flowing': 5});
      expect(mic.containsKey('lossPct'), isFalse);
    });

    test('a stall injected mid-watch is one gap, backdated to where the counters went flat', () async {
      final clock = _Clock();
      final app = AppState();
      final call = ScriptedCall(now: () => clock.now)
        ..emit(const CallState(participants: [
          CallParticipant(srcId: 'bob', hasAudio: true),
          CallParticipant(srcId: 'carol', hasAudio: true),
        ]));
      app.debugAttachCall(call);
      // Carol's audio stops after the 3rd interval and comes back after the 7th:
      // flat from t=3s to t=7s, a four-second gap.
      clock.onSleep = (n) {
        if (n == 4) call.flowFaults['in:carol|audio'] = ScriptedFlowFault.stall;
        if (n == 8) call.flowFaults.remove('in:carol|audio');
      };
      final drive = _drive(app, clock);
      final started = await _data(drive, 'ext.gc.media.watch', '{"durationMs":10000}');
      final result = ((await _opResult(drive, started['id']! as String))['result']! as Map).cast<String, Object?>();

      expect(_stream(result, 'in:bob|audio')['continuous'], isTrue);
      final carol = _stream(result, 'in:carol|audio');
      expect(carol['continuous'], isFalse);
      // Interval 4 (3s→4s) is the grace second, still reported flowing; 5–7
      // are the stall; 8 is the recovery.
      expect(carol['verdicts'], {'flowing': 7, 'stalled': 3});
      expect(carol['gaps'], [
        {'from': '2026-11-11T09:00:03.000Z', 'to': '2026-11-11T09:00:07.000Z', 'ms': 4000, 'verdict': 'stalled'},
      ]);
      expect(carol['longestGapMs'], 4000);
      expect(result['allContinuous'], isFalse);
    });

    test('a missing consumer is not continuous; a peer\'s mute is paused, not a gap', () async {
      final clock = _Clock();
      final app = AppState();
      final call = ScriptedCall(now: () => clock.now)
        ..emit(const CallState(participants: [
          CallParticipant(srcId: 'bob', hasAudio: true, hasVideo: true),
          CallParticipant(srcId: 'dana', hasAudio: true, audioPaused: true),
        ]))
        ..flowFaults['in:bob|video'] = ScriptedFlowFault.missing;
      app.debugAttachCall(call);
      final drive = _drive(app, clock);
      final started = await _data(drive, 'ext.gc.media.watch', '{"durationMs":3000,"intervalMs":500}');
      final result = ((await _opResult(drive, started['id']! as String))['result']! as Map).cast<String, Object?>();

      final video = _stream(result, 'in:bob|video');
      expect(video['verdicts'], {'missing': 6});
      expect(video['continuous'], isFalse);
      expect(video['everFlowing'], isFalse);
      expect(result['expected'], containsAll(['in:bob|video', 'in:bob|audio', 'in:dana|audio']));

      final dana = _stream(result, 'in:dana|audio');
      expect(dana['verdicts'], {'paused': 6});
      expect(dana['continuous'], isTrue);
      expect(dana['pausedMs'], 3000);
      expect(dana['gaps'], isEmpty);
    });

    test('silence is continuous; an unmeasured stretch is not', () async {
      final clock = _Clock();
      final app = AppState();
      final call = ScriptedCall(now: () => clock.now)
        ..emit(const CallState(participants: [
          CallParticipant(srcId: 'bob', hasAudio: true),
          CallParticipant(srcId: 'eve', hasAudio: true),
        ]))
        ..flowFaults['in:bob|audio'] = ScriptedFlowFault.silence
        ..flowFaults['in:eve|audio'] = ScriptedFlowFault.unmeasured;
      app.debugAttachCall(call);
      final drive = _drive(app, clock);
      final started = await _data(drive, 'ext.gc.media.watch', '{"durationMs":4000}');
      final result = ((await _opResult(drive, started['id']! as String))['result']! as Map).cast<String, Object?>();

      final bob = _stream(result, 'in:bob|audio');
      expect(bob['verdicts'], {'silent': 4});
      expect(bob['continuous'], isTrue);

      final eve = _stream(result, 'in:eve|audio');
      expect(eve['verdicts'], {'not_measured': 4});
      expect(eve['continuous'], isFalse);
      final timeline = (result['timeline']! as List).cast<Map>();
      expect(timeline.first['errors'], [
        {'scope': 'in:eve|audio', 'error': 'getStats timed out (scripted)'},
      ]);
    });

    test('a call that ends mid-watch stops the watch and says so', () async {
      final clock = _Clock();
      Call? current = ScriptedCall(now: () => clock.now)
        ..emit(const CallState(participants: [CallParticipant(srcId: 'bob', hasAudio: true)]));
      final ops = DriveOps(nonce: 'n00000');
      final drive = DebugDrive(boot: () => 'harness', spaceId: () => null, inTestSpace: () => false, register: RecordingRegistrar().call)
        ..install([opFeature(ops), mediaFeature(call: () => current, ops: ops, sleep: clock.sleep)]);
      clock.onSleep = (n) {
        if (n == 2) current = null;
      };
      final started = await _data(drive, 'ext.gc.media.watch', '{"durationMs":10000}');
      final result = ((await _opResult(drive, started['id']! as String))['result']! as Map).cast<String, Object?>();
      expect(result['endedEarly'], 'call_ended');
      expect(result['samples'], 2);
      expect(_stream(result, 'in:bob|audio')['verdicts'], {'flowing': 1});
    });
  });

  group('watch, when a Call breaks its never-throws promise', () {
    test('ends early with the error and keeps the summary of what it gathered', () async {
      final clock = _Clock();
      final call = _ThrowingCall(throwOn: 3)..flowSamples.addAll([_sample(0, 0), _sample(1000, 50, energy: 0.1), _sample(2000, 100, energy: 0.2)]);
      final ops = DriveOps(nonce: 'n00000');
      final drive = DebugDrive(boot: () => 'harness', spaceId: () => null, inTestSpace: () => false, register: RecordingRegistrar().call)
        ..install([opFeature(ops), mediaFeature(call: () => call, ops: ops, sleep: clock.sleep)]);
      final started = await _data(drive, 'ext.gc.media.watch', '{"durationMs":10000}');
      final op = await _opResult(drive, started['id']! as String);
      expect(op['state'], 'done', reason: '$op');
      final result = (op['result']! as Map).cast<String, Object?>();
      expect(result['endedEarly'], 'sample_failed');
      expect(result['error'], contains('stats thread on fire'));
      expect(result['samples'], 2);
      expect(_stream(result, 'in:bob|audio')['verdicts'], {'flowing': 1});
    });
  });

  group('summarizeWatch', () {
    test('nothing judged is not "healthy": allContinuous is null', () {
      expect(summarizeWatch(const [], maxGapMs: 2000)['allContinuous'], isNull);
    });
  });
}

const _micOn = LocalMediaState(capturing: true, audioEnabled: true);

/// A [FakeCall] whose [sampleFlow] throws on the [throwOn]th reading.
class _ThrowingCall extends FakeCall {
  _ThrowingCall({required this.throwOn});

  final int throwOn;

  @override
  Future<MediaFlowSample> sampleFlow() async {
    if (flowSampled + 1 == throwOn) {
      flowSampled++;
      throw StateError('stats thread on fire');
    }
    return super.sampleFlow();
  }
}
