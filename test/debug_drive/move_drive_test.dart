/// `ext.gc.move.*` through the registry, over a booted [AppState] whose collector
/// is the harness's [FakeCollector] — so `Walk` is the real one, each step is a
/// real `move` the fake confirms with a roster, and a walk op settles when the
/// route actually ends. Covers every action's success, each refusal it names, bad
/// args, a hop whose roster has not caught up, a walk superseded by another, and
/// the outward gate on a live boot (with `stop` the one action it lets through).
///
/// Every test runs on a fake clock ([_vtest]). The walk steps on a periodic timer,
/// ops time out on a timer and the poll waits between reads; on the wall clock that
/// is a suite whose "100 ms timeout" case is a race a loaded CI box can lose.
library;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gather_client/gather_client.dart';
import 'package:gather_companion/harness/fake_collector.dart';
import 'package:gather_companion/harness/harness_data.dart';
import 'package:gather_companion/src/app_state.dart';
import 'package:gather_companion/src/calendar.dart';
import 'package:gather_companion/src/calendar_store.dart';
import 'package:gather_companion/src/credentials.dart';
import 'package:gather_companion/src/debug_drive/debug_drive.dart';
import 'package:gather_companion/src/debug_drive/install.dart';
import 'package:gather_companion/src/media/media_log.dart';
import 'package:gather_companion/src/notifications.dart';
import 'package:gather_companion/src/settings.dart';
import 'package:gather_events/gather_events.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'drive_test_support.dart';

class _SilentNotifier extends Notifier {
  @override
  Future<void> init() async {}
}

class _Credentials extends GatherCredentialStore {
  @override
  Future<GatherCredentials> load() async =>
      const GatherCredentials(refreshToken: 'r', idToken: 'i', uid: 'uid-1');
  @override
  Future<String?> loadSpaceId() async => 'space';
  @override
  Future<void> save(GatherCredentials credentials) async {}
  @override
  Future<void> saveSpaceId(String? spaceId) async {}
  @override
  Future<void> clear() async {}
}

class _NoBridge extends BridgeSettingsStore {
  @override
  Future<BridgeSettings> load() async => const BridgeSettings(host: '', port: 7799, token: '');
  @override
  Future<String?> loadName() async => null;
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

/// A collector whose teleports reach "the server" but whose roster never says so —
/// the live socket's quarter-second lag, held open.
class _LaggingFake extends FakeCollector {
  @override
  ({bool ok, String? detail}) teleport({required num x, required num y, String direction = 'Down'}) {
    teleports.add((x: x, y: y));
    return (ok: true, detail: null);
  }
}

/// [test], with [body] on a fake clock that is advanced until it finishes.
void _vtest(String name, Future<void> Function() body) => test(name, () {
      fakeAsync((async) {
        Object? error;
        StackTrace? stack;
        var done = false;
        body().then((_) => done = true, onError: (Object e, StackTrace s) {
          error = e;
          stack = s;
          done = true;
        });
        for (var i = 0; !done && i < 60000; i++) {
          async.elapse(const Duration(milliseconds: 10));
        }
        if (error != null) Error.throwWithStackTrace(error!, stack!);
        if (!done) fail('did not finish in ten virtual minutes');
      });
    });

PresenceSnapshot _inSpace(String id) => PresenceSnapshot(
      self: SelfState(spaceId: id),
      players: const [],
      health: const CollectorHealth(),
      at: DateTime(2026, 11, 10),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() {
    mediaLogDebugSink = null;
    debugResetDriveLog();
  });

  /// A booted app on the schematic office, me at (10, 7), the cast where
  /// `kCastStartTiles` puts them.
  Future<({AppState app, FakeCollector fake})> booted({int participants = 4, FakeCollector? collector}) async {
    final fake = collector ?? FakeCollector(participants: participants);
    final app = AppState(
      notifier: _SilentNotifier(),
      credentials: _Credentials(),
      bridge: _NoBridge(),
      calendarStore: _EmptyCalendarStore(),
      buildCollector: (auth, spaceId) => fake,
      buildActivityFeed: _SilentFeed.new,
      connectivityNow: () async => const [ConnectivityResult.wifi],
      connectivityChanges: const Stream<List<ConnectivityResult>>.empty(),
    );
    addTearDown(app.dispose);
    await app.boot();
    await pumpEventQueue();
    expect(app.myTile, (x: 10, y: 7), reason: 'the walk knows where I stand');
    return (app: app, fake: fake);
  }

  DebugDrive install(AppState app, {String boot = 'harness', String testSpaceId = ''}) => installDebugDrive(
        enabled: true,
        app: app,
        boot: boot,
        register: RecordingRegistrar().call,
        testSpaceId: testSpaceId,
      )!;

  Future<Map<String, Object?>> call(DebugDrive drive, String method, [String args = '{}']) async =>
      resultOf(await drive.invoke('ext.gc.move.$method', args));

  Map<String, Object?> dataOf(Map<String, Object?> body) {
    expect(body['ok'], isTrue, reason: '$body');
    return (body['data']! as Map).cast<String, Object?>();
  }

  /// Polls `op.result` until the op leaves `pending`, and answers its result.
  Future<Map<String, Object?>> settled(DebugDrive drive, Map<String, Object?> started) async {
    final id = dataOf(started)['id']! as String;
    expect(id, startsWith('move-'));
    for (var i = 0; i < 500; i++) {
      final body = dataOf(resultOf(await drive.invoke('ext.gc.op.result', '{"id":"$id"}')));
      if (body['state'] != 'pending') {
        expect(body['state'], 'done', reason: '$body');
        return (body['result']! as Map).cast<String, Object?>();
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    fail('op $id never settled');
  }

  group('move.goTo', () {
    _vtest('walks a real route and settles on arrival, at the requested tile', () async {
      final (:app, :fake) = await booted();
      final drive = install(app);
      final started = await call(drive, 'goTo', '{"x":12,"y":7}');
      expect(dataOf(started)['requested'], {'x': 12, 'y': 7});
      expect(dataOf(started)['boot'], 'harness');

      final result = dataOf(await settled(drive, started));
      expect(result['settled'], 'route_ended');
      expect(result['at'], {'x': 12, 'y': 7});
      expect(result['atRequested'], isTrue);
      expect(result['onRoute'], isFalse);
      expect(result['boot'], 'harness');
      expect(fake.moves, isNotEmpty, reason: 'it walked, step by step');
      expect(fake.teleports, isEmpty, reason: 'and did not hop');
    });

    _vtest('move.stop during the walk settles it as stopped, short of the goal', () async {
      final (:app, :fake) = await booted();
      final drive = install(app);
      final started = await call(drive, 'goTo', '{"x":19,"y":14}');
      expect(app.onRoute, isTrue);
      final stop = dataOf(await call(drive, 'stop'));
      expect(stop['wasOnRoute'], isTrue);
      expect(stop['onRoute'], isFalse);

      final result = dataOf(await settled(drive, started));
      expect(result['settled'], 'stopped');
      expect(result['atRequested'], isFalse);
    });

    _vtest('a second walk supersedes the first op instead of lending it its arrival', () async {
      final (:app, :fake) = await booted();
      final drive = install(app);
      final first = await call(drive, 'goTo', '{"x":19,"y":14}');
      final second = await call(drive, 'goTo', '{"x":15,"y":12}');
      expect(dataOf(await settled(drive, first))['settled'], 'superseded');
      final result = dataOf(await settled(drive, second));
      expect(result['settled'], 'route_ended');
      expect(result['at'], {'x': 15, 'y': 12});
    });

    _vtest('a hop during the walk supersedes it too', () async {
      final (:app, :fake) = await booted();
      final drive = install(app);
      final walk = await call(drive, 'goTo', '{"x":19,"y":14}');
      expect(dataOf(await call(drive, 'warpToTile', '{"x":15,"y":12}'))['at'], {'x': 15, 'y': 12});
      expect(dataOf(await settled(drive, walk))['settled'], 'superseded');
    });

    _vtest('a walk still going after timeoutMs answers timeout and is left running', () async {
      final (:app, :fake) = await booted();
      final drive = install(app);
      final result = dataOf(await settled(drive, await call(drive, 'goTo', '{"x":0,"y":0,"timeoutMs":100}')));
      expect(result['settled'], 'timeout');
      expect(result['onRoute'], isTrue, reason: 'a timeout is a report, not a cancel');
      app.stopWalking();
    });

    _vtest("the AppState's own refusals settle the op as refusals with a stable reason", () async {
      final bare = install(AppState());
      final noMap = await settled(bare, await call(bare, 'goTo', '{"x":1,"y":1}'));
      expect(noMap['ok'], isFalse);
      expect(noMap['reason'], 'no_map');
      expect(noMap['message'], 'Still reading the floor plan.');

      final mapOnly = AppState()..debugMap = schematicOffice();
      final mapDrive = install(mapOnly);
      final notConnected = await settled(mapDrive, await call(mapDrive, 'goTo', '{"x":1,"y":1}'));
      expect(notConnected['reason'], 'not_connected');
    });

    _vtest('bad coordinates are invalidParams, not refusals', () async {
      final drive = install(AppState());
      for (final args in ['{}', '{"x":1}', '{"x":"a","y":1}', '{"x":1.5,"y":1}', '{"x":-1,"y":1}', '{"x":1,"y":1,"timeoutMs":5}']) {
        expect(errorOf(await drive.invoke('ext.gc.move.goTo', args)).code, -32602, reason: args);
      }
    });
  });

  group('move.warpToTile', () {
    _vtest('hops at once, with no op, to the tile asked', () async {
      final (:app, :fake) = await booted();
      final data = dataOf(await call(install(app), 'warpToTile', '{"x":15,"y":12}'));
      expect(data['at'], {'x': 15, 'y': 12});
      expect(data['atRequested'], isTrue);
      expect(data['hop'], {'x': 15, 'y': 12});
      expect(data['hopConfirmed'], isTrue, reason: 'the fake confirms at once');
      expect(data.containsKey('id'), isFalse);
      expect(fake.teleports.single, (x: 15, y: 12));
      expect(fake.moves, isEmpty);
    });

    _vtest('before the roster confirms the hop: at is still the old tile, and says so', () async {
      final (:app, :fake) = await booted(collector: _LaggingFake());
      final data = dataOf(await call(install(app), 'warpToTile', '{"x":15,"y":12}'));
      expect(data['at'], {'x': 10, 'y': 7}, reason: 'the roster has not moved me yet');
      expect(data['hop'], {'x': 15, 'y': 12});
      expect(data['hopConfirmed'], isFalse);
      expect(data['atRequested'], isTrue, reason: 'judged on the hop sent, not a lagging roster');
    });

    _vtest('refuses with the method’s reason, and reads its args strictly', () async {
      final drive = install(AppState());
      final body = await call(drive, 'warpToTile', '{"x":1,"y":1}');
      expect(body['ok'], isFalse);
      expect(body['reason'], 'no_map');
      expect(errorOf(await drive.invoke('ext.gc.move.warpToTile', '{"y":1}')).code, -32602);
    });
  });

  group('move.warpToPerson', () {
    _vtest('by name, case-insensitive: lands beside them, as an op', () async {
      final (:app, :fake) = await booted();
      final drive = install(app);
      final started = await call(drive, 'warpToPerson', '{"name":"ada"}');
      expect(dataOf(started)['target'], {'id': 'space-ada', 'name': 'Ada'});
      final result = dataOf(await settled(drive, started));
      expect(result['settled'], 'instant', reason: 'a warp is a hop');
      expect(result['target'], {'id': 'space-ada', 'name': 'Ada'});
      final hop = fake.teleports.single;
      expect((hop.x - 4).abs() <= 1 && (hop.y - 3).abs() <= 1, isTrue, reason: 'next to Ada at (4,3): $hop');
    });

    _vtest('by id', () async {
      final (:app, :fake) = await booted();
      final drive = install(app);
      final result = dataOf(await settled(drive, await call(drive, 'warpToPerson', '{"id":"space-grace"}')));
      expect(result['target'], {'id': 'space-grace', 'name': 'Grace'});
      expect(fake.teleports, hasLength(1));
    });

    _vtest('an unknown person, an ambiguous name, and an absent one are refused', () async {
      final (:app, :fake) = await booted(participants: 8);
      final drive = install(app);
      expect((await call(drive, 'warpToPerson', '{"id":"nobody"}'))['reason'], 'no_such_person');
      expect((await call(drive, 'warpToPerson', '{"name":"zed"}'))['reason'], 'no_such_person');
      final ambiguous = await call(drive, 'warpToPerson', '{"name":"a"}');
      expect(ambiguous['reason'], 'ambiguous_name');
      expect([for (final c in ambiguous['candidates']! as List) (c as Map)['name']], containsAll(['Ada', 'Alan']));
      expect(fake.teleports, isEmpty);

      final away = AppState()
        ..debugApplyRoster(const Roster(selfId: 'me', rows: [
          RosterRow(id: 'me', name: 'Me', x: 1, y: 1, connected: true),
          RosterRow(id: 'bob', name: 'Bob', connected: false),
        ]));
      final awayDrive = install(away);
      final result = await settled(awayDrive, await call(awayDrive, 'warpToPerson', '{"name":"Bob"}'));
      expect(result['reason'], 'person_absent');
      expect(result['message'], 'Bob is not in the office right now.');
    });

    _vtest('neither id nor name is invalidParams', () async {
      expect(errorOf(await install(AppState()).invoke('ext.gc.move.warpToPerson', '{}')).code, -32602);
      expect(errorOf(await install(AppState()).invoke('ext.gc.move.warpToPerson', '{"name":""}')).code, -32602);
    });
  });

  group('move.goToRoom', () {
    _vtest('by name walks in and settles inside the room', () async {
      final (:app, :fake) = await booted();
      final drive = install(app);
      final started = await call(drive, 'goToRoom', '{"name":"lounge"}');
      expect((dataOf(started)['room']! as Map)['id'], 'room-lounge');
      final result = dataOf(await settled(drive, started));
      expect(result['settled'], 'route_ended');
      expect(result['room'], 'Lounge', reason: 'the readout names the room I ended in');
      expect(fake.moves, isNotEmpty);
    });

    _vtest('no floor plan, an unknown room and a locked one are refused before walking', () async {
      expect((await call(install(AppState()), 'goToRoom', '{"name":"Lounge"}'))['reason'], 'no_map');

      final (:app, :fake) = await booted();
      expect((await call(install(app), 'goToRoom', '{"id":"room-nope"}'))['reason'], 'no_such_room');

      final locked = AppState()
        ..debugMap = SpaceMap(
          floorId: 'f1',
          width: 20,
          height: 10,
          blocked: const {},
          rooms: const [
            SpaceRoom(id: 'r1', stableId: 's1', name: 'Vault', type: 'room', x: 2, y: 2, width: 3, height: 3, walled: true, locked: true),
          ],
          inside: const {},
        )
        ..debugApplyRoster(const Roster(selfId: 'me', rows: [
          RosterRow(id: 'me', name: 'Me', x: 10, y: 8, floorId: 'f1', connected: true),
        ]));
      final body = await call(install(locked), 'goToRoom', '{"stableId":"s1"}');
      expect(body['reason'], 'room_locked');
      expect(body['room'], {'id': 'r1', 'stableId': 's1', 'name': 'Vault'});
    });

    _vtest('no selector is invalidParams', () async {
      expect(errorOf(await install(AppState()).invoke('ext.gc.move.goToRoom', '{}')).code, -32602);
    });
  });

  group('move.goToMyDesk', () {
    _vtest('with no desk the op settles as no_desk', () async {
      final (:app, :fake) = await booted();
      final drive = install(app);
      final result = await settled(drive, await call(drive, 'goToMyDesk'));
      expect(result['reason'], 'no_desk');
      expect(fake.moves, isEmpty);
    });

    _vtest('with a desk it walks there', () async {
      final (:app, :fake) = await booted();
      // The schematic office has no desks: give it one two tiles east of me, and
      // give me that desk on the roster. Walk keeps its own tile from the fake.
      app
        ..debugMap = SpaceMap(
          floorId: 'f1',
          width: 20,
          height: 15,
          blocked: const {},
          rooms: const [
            SpaceRoom(id: 'd1', stableId: 'desk-1', name: null, type: 'desk', x: 12, y: 7, width: 1, height: 1, walled: false),
          ],
          inside: const {},
        )
        ..debugApplyRoster(const Roster(selfId: 'me', rows: [
          RosterRow(id: 'me', name: 'You', x: 10, y: 7, connected: true, availability: 'Active', deskId: 'desk-1'),
        ]));
      final drive = install(app);
      final result = dataOf(await settled(drive, await call(drive, 'goToMyDesk')));
      expect(result['settled'], 'route_ended');
      expect(result['at'], {'x': 12, 'y': 7});
      expect(fake.moves, isNotEmpty);
    });
  });

  _vtest('move.stop with nothing running is a harmless ok', () async {
    final data = dataOf(await call(install(AppState()), 'stop'));
    expect(data['wasOnRoute'], isFalse);
    expect(data['at'], isNull);
  });

  group('outward gate on boot=live', () {
    const outward = {
      'goTo': '{"x":1,"y":1}',
      'warpToTile': '{"x":1,"y":1}',
      'warpToPerson': '{"name":"Ada"}',
      'goToRoom': '{"name":"Lounge"}',
      'goToMyDesk': '{}',
    };

    _vtest('every movement is refused outside the test space; stop is not', () async {
      final (:app, :fake) = await booted();
      final drive = install(app, boot: 'live', testSpaceId: 'the-test-space');
      for (final MapEntry(key: action, value: args) in outward.entries) {
        final body = await call(drive, action, args);
        expect(body['reason'], 'outward_outside_test_space', reason: action);
      }
      expect(fake.moves, isEmpty);
      expect(fake.teleports, isEmpty);
      expect((await call(drive, 'stop'))['ok'], isTrue, reason: 'calling off a walk is never gated');
    });

    _vtest('confirm:true, or being in the test space, lets them through', () async {
      final (:app, :fake) = await booted();
      final confirmed = install(app, boot: 'live', testSpaceId: 'the-test-space');
      final hop = await call(confirmed, 'warpToTile', '{"x":15,"y":12,"confirm":true}');
      expect(dataOf(hop)['boot'], 'live');
      expect(fake.teleports, hasLength(1));

      final inTest = AppState()..debugApplySnapshot(_inSpace('t'));
      final drive = install(inTest, boot: 'live', testSpaceId: 't');
      for (final MapEntry(key: action, value: args) in outward.entries) {
        final body = await call(drive, action, args);
        expect(body['reason'], isNot('outward_outside_test_space'), reason: action);
      }
    });
  });
}
