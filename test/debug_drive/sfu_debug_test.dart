/// `ext.gc.sfu.debug` and the `SfuSession.debugSnapshot` behind it, over the
/// shared SFU rig (`../sfu_rig.dart`): the session's own picture of its node,
/// peer-node cache, transports, producers and consumers — and no credential
/// anywhere in it.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gather_client/gather_client.dart';
import 'package:gather_companion/harness/scripted_call.dart';
import 'package:gather_companion/src/app_state.dart';
import 'package:gather_companion/src/debug_drive/install.dart';
import 'package:gather_companion/src/media/live_call.dart';
import 'package:gather_companion/src/media/media_log.dart';
import 'package:gather_companion/src/media/sfu_session.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fake_capture_engine.dart';
import '../fake_mediasoup.dart';
import '../sfu_rig.dart';
import 'drive_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() => mediaLogDebugSink = null);
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  group('SfuSession.debugSnapshot', () {
    late Rig rig;
    setUp(() => rig = Rig());
    tearDown(() => rig.close());

    test('node, peer cache, transports, producers, consumers, subscriptions', () async {
      await rig.session.start();
      await rig.session.publish(FakeTrack('audio'), FakeStream(), tag: SfuTag.audio);
      await rig.session.subscribe(them);
      rig.announce(them, {'audio': 'p-a', 'video': 'p-v'});
      await settle();
      await settle();

      final s = rig.session.debugSnapshot();
      expect(s['srcId'], me);
      expect(s['node'], nodeA);
      expect(s['peerNode'], {them: nodeA});
      expect(s['subscribed'], [them]);
      expect(s['announced'], {
        them: {'audio': 'p-a', 'video': 'p-v'},
      });

      final nodes = (s['nodes']! as List).cast<Map<String, Object?>>();
      expect(nodes.single, containsPair('url', nodeA));
      expect(nodes.single['own'], isTrue);
      expect(nodes.single['down'], isFalse);

      final transports = s['transports']! as Map;
      final send = (transports['send']! as Map).cast<String, Object?>();
      expect(send['id'], 'transport-send');
      expect(send['node'], nodeA);
      expect(send['onCurrentNode'], isTrue);
      final recv = (transports['recv']! as List).cast<Map<String, Object?>>();
      expect(recv.single, containsPair('node', nodeA));
      expect(recv.single, containsPair('id', 'transport-recv'));

      final producers = (s['producers']! as List).cast<Map<String, Object?>>();
      expect(producers.single, containsPair('tag', 'audio'));
      expect(producers.single['id'], isNotNull);
      // The fake has no `paused` getter of its own: the snapshot reads null for
      // that one field and keeps the rest, rather than throwing.
      expect(producers.single.containsKey('paused'), isTrue);

      final consumers = (s['consumers']! as List).cast<Map<String, Object?>>();
      expect(consumers.map((c) => c['key']), ['$them|audio', '$them|video']);
      final audio = consumers.first;
      expect(audio['producerId'], 'p-a');
      expect(audio['announcedProducerId'], 'p-a');
      expect(audio['producerCurrent'], isTrue);
      expect(audio['paused'], isFalse);
      expect(s['pendingConsumes'], isEmpty);
    });

    test('a tag refused "no such producer": announced, no consumer, listed as gone', () async {
      await rig.session.start();
      await rig.session.subscribe(them);
      rig.announce(them, {'audio': 'p-a'});
      await settle();
      await settle();
      // The peer adds video, but its producer id is already stale on the SFU —
      // the #61 shape: `media.snapshot` would say `missing`, and this says why.
      rig.node().failingWith['consume'] = 'consume failed: no such producer';
      rig.announce(them, {'audio': 'p-a', 'video': 'p-v'});
      await settle();
      await settle();

      final s = rig.session.debugSnapshot();
      expect((s['announced']! as Map)[them], {'audio': 'p-a', 'video': 'p-v'});
      final consumers = (s['consumers']! as List).cast<Map<String, Object?>>();
      expect(consumers.map((c) => c['key']), ['$them|audio']);
      expect(consumers.single['producerCurrent'], isTrue);
      expect(s['producerGone'], ['$them|video']);
    });

    test('carries no credential, by key or by value', () async {
      await rig.session.start();
      final text = jsonEncode(rig.session.debugSnapshot()).toLowerCase();
      for (final secret in ['token', 'cookie', 'credential', 'password', 'unused']) {
        expect(text, isNot(contains(secret)), reason: secret);
      }
    });
  });

  group('ext.gc.sfu.debug', () {
    test('no call: refused no_call', () async {
      final drive = installDebugDrive(enabled: true, app: AppState(), boot: 'harness', register: RecordingRegistrar().call)!;
      expect(resultOf(await drive.invoke('ext.gc.sfu.debug')), {'ok': false, 'reason': 'no_call'});
    });

    test('a scripted call: refused no_sfu_session, saying it is scripted', () async {
      final app = AppState()..debugAttachCall(ScriptedCall());
      final drive = installDebugDrive(enabled: true, app: app, boot: 'harness', register: RecordingRegistrar().call)!;
      final body = resultOf(await drive.invoke('ext.gc.sfu.debug'));
      expect(body['ok'], isFalse);
      expect(body['reason'], 'no_sfu_session');
      expect(body['source'], 'scripted');
    });

    test('a live call: refused before the session opens, the snapshot after', () async {
      final rig = Rig();
      final call = LiveCall(
        auth: GatherAuth(credentials: const GatherCredentials(refreshToken: 'unused')),
        spaceId: spaceId,
        srcId: me,
        engine: FakeCaptureEngine(),
        buildSfu: () => rig.session,
      );
      addTearDown(() async {
        await call.dispose();
        await rig.close();
      });
      final app = AppState()..debugAttachCall(call);
      final drive = installDebugDrive(enabled: true, app: app, boot: 'live', register: RecordingRegistrar().call)!;

      final before = resultOf(await drive.invoke('ext.gc.sfu.debug'));
      expect(before['ok'], isFalse);
      expect(before['reason'], 'no_sfu_session');
      expect(before['source'], 'live');

      expect(await call.setMicOn(true), isNull);
      final after = resultOf(await drive.invoke('ext.gc.sfu.debug'));
      expect(after['ok'], isTrue);
      final data = (after['data']! as Map).cast<String, Object?>();
      expect(data['source'], 'live');
      expect(data['node'], nodeA);
      expect((data['producers']! as List).cast<Map<String, Object?>>().single, containsPair('tag', 'audio'));
    });
  });

  test('SfuTag wire names are what the snapshot keys by', () {
    expect(SfuTag.values.map((t) => t.wire), ['audio', 'video', 'screen']);
  });
}
