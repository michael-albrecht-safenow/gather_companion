/// `state.dump`: what the app believes, read through the drive exactly as an
/// agent would read it — and what it must never contain.
///
/// The field tests drive the real `AppState` through its `debugApply*` seams
/// and check the dump agrees with what the UI would show. The redaction test
/// boots a real `AppState` on secret-shaped credentials and asserts no token,
/// cookie or secret leaves through the dump, by value *and* by key: a dump is
/// the thing that gets pasted into an issue.
library;

import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gather_client/gather_client.dart';
import 'package:gather_companion/harness/fake_collector.dart';
import 'package:gather_companion/src/app_state.dart';
import 'package:gather_companion/src/calendar.dart';
import 'package:gather_companion/src/calendar_store.dart';
import 'package:gather_companion/src/credentials.dart';
import 'package:gather_companion/src/debug_drive/install.dart';
import 'package:gather_companion/src/debug_drive/state_feature.dart';
import 'package:gather_companion/src/link_status.dart';
import 'package:gather_companion/src/media/call.dart';
import 'package:gather_companion/src/media/media_engine.dart';
import 'package:gather_companion/src/media/media_log.dart';
import 'package:gather_companion/src/notifications.dart';
import 'package:gather_companion/src/settings.dart';
import 'package:gather_events/gather_events.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'drive_test_support.dart';

const _refresh = 'SECRET-REFRESH-7f3a9c';
const _idToken = 'SECRET-IDTOKEN-eyJhbGciOi';
const _bridgeToken = 'SECRET-BRIDGE-41d2';

class _SilentNotifier extends Notifier {
  @override
  Future<void> init() async {}
}

class _SecretCredentials extends GatherCredentialStore {
  @override
  Future<GatherCredentials> load() async =>
      const GatherCredentials(refreshToken: _refresh, idToken: _idToken, uid: 'uid-1');
  @override
  Future<String?> loadSpaceId() async => 'space-secret-test';
  @override
  Future<void> save(GatherCredentials credentials) async {}
  @override
  Future<void> saveSpaceId(String? spaceId) async {}
  @override
  Future<void> clear() async {}
}

class _SecretBridge extends BridgeSettingsStore {
  // No host, so push registration never tries the network; the token is still
  // held in memory, which is the point.
  @override
  Future<BridgeSettings> load() async => const BridgeSettings(host: '', port: 7799, token: _bridgeToken);
  @override
  Future<String?> loadName() async => 'Desk Mac';
  @override
  Future<void> save(BridgeSettings settings) async {}
  @override
  Future<void> saveName(String name) async {}
  @override
  Future<void> clear() async {}
}

class _EmptyCalendarStore extends CalendarStore {
  @override
  Future<List<PlannedMeeting>> load() async => const [];
}

class _SilentFeed extends ActivityFeed {
  _SilentFeed(GatherAuth auth) : super(auth: auth);
  @override
  Future<ActivityFeedPage> fetch(String spaceId) async => ActivityFeedPage.empty;
}

/// Every key anywhere in [value], lowercased.
Iterable<String> _keys(Object? value) sync* {
  if (value is Map) {
    for (final MapEntry(:key, :value) in value.entries) {
      yield '$key'.toLowerCase();
      yield* _keys(value);
    }
  } else if (value is List) {
    for (final v in value) {
      yield* _keys(v);
    }
  }
}

Future<Map<String, Object?>> _dumpOver(AppState app, {String boot = 'harness', String testSpaceId = ''}) async {
  final drive = installDebugDrive(
    enabled: true,
    app: app,
    boot: boot,
    register: RecordingRegistrar().call,
    testSpaceId: testSpaceId,
  )!;
  final body = resultOf(await drive.invoke('ext.gc.state.dump'));
  expect(body['ok'], isTrue);
  return (body['data']! as Map).cast<String, Object?>();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() => mediaLogDebugSink = null);

  test('a fresh state reads as booting, unconfigured, idle, with nothing invented', () async {
    final dump = await _dumpOver(AppState());
    expect(dump['boot'], 'harness');
    expect(dump['phase'], 'booting');
    expect(dump['loaded'], isFalse);
    expect(dump['configured'], isFalse);
    expect(dump['link'], {'state': 'idle', 'detail': null, 'needsPairing': false});
    expect(dump['me'], {
      'id': null,
      'tile': null,
      'room': null,
      'availability': null,
      'handRaised': false,
      'atMyDesk': false,
    });
    expect(dump['spaceId'], isNull);
    expect(dump['testSpace'], isFalse);
    expect(dump['roster'], {'peopleOnMap': 0, 'followers': 0});
    expect((dump['call']! as Map)['participants'], 0);
    expect(dump['settings'], {'gameboyMode': false, 'soundEffects': true, 'partyMode': false});
  });

  test('the dump agrees with what the screens read: space, me, room, roster, call', () async {
    final app = AppState()
      ..debugApplyLink(const LinkStatus(LinkState.live, 'connected'))
      ..debugMap = SpaceMap(
        floorId: 'f1',
        width: 20,
        height: 10,
        blocked: const {},
        rooms: const [
          SpaceRoom(id: 'r1', name: 'Kitchen', type: 'room', x: 2, y: 3, width: 4, height: 4, walled: true),
        ],
        inside: const {},
      )
      ..debugApplyRoster(const Roster(selfId: 'me', rows: [
        RosterRow(id: 'me', name: 'Me', x: 3, y: 4, floorId: 'f1', connected: true, availability: 'Active'),
        RosterRow(id: 'bob', name: 'Bob', x: 5, y: 5, floorId: 'f1', connected: true),
        RosterRow(id: 'cy', name: 'Cy', x: 9, y: 9, floorId: 'f1', connected: false),
      ]))
      // After the roster: a roster folds into a fresh snapshot, so the presence
      // digest the UI reads (space, followers, health) is placed last.
      ..debugApplySnapshot(PresenceSnapshot(
        self: const SelfState(spaceId: 'space-1', spaceName: 'HQ'),
        players: const [
          PlayerRef(id: 'bob', name: 'Bob', isFollowingMe: true),
          PlayerRef(id: 'cy', name: 'Cy'),
        ],
        health: const CollectorHealth(gather: true, detail: 'live'),
        at: DateTime(2026, 11, 10, 9),
      ))
      ..debugHuddle = ['Bob']
      ..debugCall = const CallState(
        media: LocalMediaState(capturing: true, audioEnabled: true, videoEnabled: false, screenCapturing: true),
        publishingAudio: true,
        participants: [CallParticipant(srcId: 'bob', hasAudio: true)],
        connecting: {'dee'},
        detail: 'Camera is off',
      );

    final dump = await _dumpOver(app, testSpaceId: 'space-1');
    expect(dump['phase'], 'pairing', reason: 'loaded by the snapshot seam, no credential');
    expect(dump['link'], {'state': 'live', 'detail': 'connected', 'needsPairing': false});
    expect((dump['collector']! as Map)['healthy'], isTrue);
    expect((dump['collector']! as Map)['detail'], 'live');
    expect(dump['me'], {
      'id': 'me',
      'tile': {'x': 3, 'y': 4},
      'room': 'Kitchen',
      'availability': 'Active',
      'handRaised': false,
      'atMyDesk': false,
    });
    expect(dump['spaceId'], 'space-1');
    expect(dump['spaceName'], 'HQ');
    expect(dump['testSpace'], isTrue);
    expect(dump['roster'], {'peopleOnMap': 1, 'followers': 1}, reason: 'Cy is offline and not drawn');
    expect(dump['call'], {
      'micOn': true,
      'cameraOn': false,
      'screenOn': true,
      'publishingAudio': true,
      'publishingVideo': false,
      'participants': 1,
      'connecting': 1,
      'unreachable': 0,
      'detail': 'Camera is off',
      'inHuddle': true,
      'inCall': true,
    });
  });

  group('testSpace', () {
    PresenceSnapshot inSpace(String? id) => PresenceSnapshot(
          self: SelfState(spaceId: id),
          players: const [],
          health: const CollectorHealth(),
          at: DateTime(2026, 11, 10),
        );

    test('is true only for the compiled-in space', () async {
      expect((await _dumpOver(AppState()..debugApplySnapshot(inSpace('t')), testSpaceId: 't'))['testSpace'], isTrue);
      expect((await _dumpOver(AppState()..debugApplySnapshot(inSpace('real')), testSpaceId: 't'))['testSpace'], isFalse);
    });

    test('an empty define matches no space — not even an empty or missing id', () async {
      expect((await _dumpOver(AppState()..debugApplySnapshot(inSpace('')), testSpaceId: ''))['testSpace'], isFalse);
      expect((await _dumpOver(AppState()..debugApplySnapshot(inSpace(null)), testSpaceId: ''))['testSpace'], isFalse);
    });
  });

  test('a booted state on real-shaped credentials leaks no token, by value or by key', () async {
    final app = AppState(
      notifier: _SilentNotifier(),
      credentials: _SecretCredentials(),
      bridge: _SecretBridge(),
      calendarStore: _EmptyCalendarStore(),
      buildCollector: (auth, spaceId) => FakeCollector(participants: 2),
      buildActivityFeed: _SilentFeed.new,
      connectivityNow: () async => const [ConnectivityResult.wifi],
      connectivityChanges: const Stream<List<ConnectivityResult>>.empty(),
    );
    addTearDown(app.dispose);
    await app.boot();
    await pumpEventQueue();

    final dump = await _dumpOver(app, boot: 'live');
    final text = jsonEncode(dump);
    expect(dump['phase'], 'home', reason: 'the credential is real enough to be held');
    expect(dump['configured'], isTrue);
    for (final secret in [_refresh, _idToken, _bridgeToken, 'SECRET']) {
      expect(text, isNot(contains(secret)));
    }
    for (final key in _keys(dump)) {
      for (final word in ['token', 'cookie', 'secret', 'password', 'credential', 'auth']) {
        expect(key, isNot(contains(word)), reason: 'key "$key" names a secret');
      }
    }
  });

  test('dumpState is the same readout the action sends', () async {
    final app = AppState()..debugApplyLink(const LinkStatus(LinkState.retrying, 'socket dropped'));
    final direct = dumpState(app, boot: 'live', testSpace: false);
    final viaDrive = await _dumpOver(app, boot: 'live');
    expect(jsonDecode(jsonEncode(direct)), viaDrive);
  });
}
