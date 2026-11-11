/// `presence.*`: the three views of the roster read through the drive, each
/// saying why it is empty rather than returning a bare `[]`.
///
/// Driven through the real `AppState` and its `debugApplyRoster` /
/// `debugApplySnapshot` seams, so the readouts are what the screens would draw.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:gather_client/gather_client.dart';
import 'package:gather_companion/src/app_state.dart';
import 'package:gather_companion/src/debug_drive/debug_drive.dart';
import 'package:gather_companion/src/debug_drive/install.dart';
import 'package:gather_companion/src/debug_drive/presence_drive.dart';
import 'package:gather_events/gather_events.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'drive_test_support.dart';

const _me = 'me-0001';

Roster _roster() => Roster(selfId: _me, spaceName: 'Test', rows: [
      const RosterRow(id: _me, name: 'Me', x: 5, y: 5, floorId: 'f1', connected: true, availability: 'Active'),
      const RosterRow(
        id: 'bob-0002',
        name: 'Bob',
        x: 7,
        y: 5,
        floorId: 'f1',
        connected: true,
        availability: 'Busy',
        speaking: true,
        calendarEmail: 'bob@example.com',
        status: PersonStatus(text: 'heads down', type: 'Custom'),
      ),
      const RosterRow(id: 'amy-0003', name: 'amy', x: 9, y: 9, floorId: 'f1', connected: true, availability: 'Active'),
      // Present, but on another floor: in the directory, not on my map.
      const RosterRow(id: 'cat-0004', name: 'Cat', x: 1, y: 1, floorId: 'f2', connected: true, availability: 'Active'),
      // Gone home: in the directory (last), never on the map.
      const RosterRow(id: 'dan-0005', name: 'Dan', x: 3, y: 3, floorId: 'f1', connected: true, availability: 'Offline'),
    ]);

PresenceSnapshot _snap({bool healthy = true, List<PlayerRef> players = const []}) => PresenceSnapshot(
      self: const SelfState(spaceId: 'space-1'),
      players: players,
      health: CollectorHealth(gather: healthy, detail: healthy ? null : 'connected, no state yet'),
      at: DateTime(2026, 11, 11),
    );

const _players = [
  PlayerRef(id: 'bob-0002', name: 'Bob', isFollowingMe: true, speaking: true),
  PlayerRef(id: 'amy-0003', name: 'amy'),
];

AppState _populated() => AppState()
  ..debugApplyRoster(_roster())
  ..debugApplySnapshot(_snap(players: _players));

Future<Map<String, Object?>> _ok(AppState app, String action, {String? args, String boot = 'harness'}) async {
  final drive = _drive(app, boot: boot);
  final body = resultOf(await drive.invoke('ext.gc.presence.$action', args));
  expect(body['ok'], isTrue, reason: '$body');
  return (body['data']! as Map).cast<String, Object?>();
}

DebugDrive _drive(AppState app, {String boot = 'harness'}) =>
    installDebugDrive(enabled: true, app: app, boot: boot, register: RecordingRegistrar().call, testSpaceId: 'the-test-space')!;

List<Map<String, Object?>> _list(Map<String, Object?> data, String key) =>
    [for (final e in data[key]! as List) (e as Map).cast<String, Object?>()];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(debugResetDriveLog);

  group('presence.roster', () {
    test('reads the digest with the counts of every view', () async {
      final data = await _ok(_populated(), 'roster');
      expect(data['boot'], 'harness');
      expect(data['loaded'], isTrue);
      expect(data['healthy'], isTrue);
      expect(data['rosterReceived'], isTrue);
      expect(data['selfId'], _me);
      expect(data['spaceId'], 'space-1');
      expect(data['counts'], {'players': 2, 'followers': 1, 'directory': 4, 'present': 3, 'onMap': 2});
      final players = _list(data, 'players');
      expect(players.first, containsPair('isFollowingMe', true));
      expect(players.first, containsPair('speaking', true));
      expect(data['truncated'], isFalse);
      expect(data.containsKey('empty'), isFalse);
    });

    test('empty says not_loaded before the first snapshot', () async {
      final data = await _ok(AppState(), 'roster');
      expect(data['players'], isEmpty);
      expect(data['empty'], 'not_loaded');
      expect(data['rosterReceived'], isFalse);
    });

    test('empty says collector_unhealthy while connected but stateless', () async {
      final data = await _ok(AppState()..debugApplySnapshot(_snap(healthy: false)), 'roster');
      expect(data['empty'], 'collector_unhealthy');
      expect(data['healthDetail'], 'connected, no state yet');
    });

    test('max truncates and says so', () async {
      final data = await _ok(_populated(), 'roster', args: '{"max":1}');
      expect(_list(data, 'players'), hasLength(1));
      expect(data['truncated'], isTrue);
    });
  });

  group('presence.followers', () {
    test('lists who is following me, known', () async {
      final data = await _ok(_populated(), 'followers');
      expect(data['known'], isTrue);
      expect(data['count'], 1);
      expect(_list(data, 'followers').single, containsPair('id', 'bob-0002'));
    });

    test('nobody following on a healthy collector is a known empty', () async {
      final app = AppState()
        ..debugApplyRoster(_roster())
        ..debugApplySnapshot(_snap(players: const [PlayerRef(id: 'amy-0003', name: 'amy')]));
      final data = await _ok(app, 'followers');
      expect(data['known'], isTrue);
      expect(data['empty'], 'nobody_following');
    });

    test('an unhealthy collector does not claim nobody is following', () async {
      final data = await _ok(AppState()..debugApplySnapshot(_snap(healthy: false)), 'followers');
      expect(data['known'], isFalse);
      expect(data['empty'], 'collector_unhealthy');
    });
  });

  group('presence.directory', () {
    test('is the Dial order — present first, by name — without emails', () async {
      final data = await _ok(_populated(), 'directory');
      final contacts = _list(data, 'contacts');
      expect([for (final c in contacts) c['label']], ['amy', 'Bob', 'Cat', 'Dan']);
      expect(data['count'], 4);
      expect(data['present'], 3);
      expect(data['reachable'], 3);
      final bob = contacts[1];
      expect(bob['availability'], 'Busy');
      expect(bob['tile'], {'x': 7, 'y': 5});
      expect((bob['status']! as Map)['text'], 'heads down');
      expect(bob['hasCalendar'], isTrue);
      expect(contacts.last['isPresent'], isFalse);
      expect('$data', isNot(contains('bob@example.com')));
    });

    test('says no_roster before Gather sent one, nobody_else after an empty one', () async {
      final before = await _ok(AppState()..debugApplySnapshot(_snap()), 'directory');
      expect(before['empty'], 'no_roster');
      final alone = AppState()
        ..debugApplyRoster(Roster(selfId: _me, rows: const [RosterRow(id: _me, x: 1, y: 1, connected: true)]))
        ..debugApplySnapshot(_snap());
      expect((await _ok(alone, 'directory'))['empty'], 'nobody_else');
    });
  });

  group('presence.map.people', () {
    test('draws the present on my floor, me separately', () async {
      final data = await _ok(_populated(), 'map.people');
      final people = _list(data, 'people');
      expect([for (final p in people) p['id']], ['amy-0003', 'bob-0002']);
      final bob = people[1];
      expect(bob['x'], 7);
      expect(bob['speaking'], isTrue);
      expect(bob['isFollowingMe'], isTrue);
      expect(bob['gait'], 'walking');
      expect(bob['hasCalendar'], isTrue);
      final me = (data['me']! as Map).cast<String, Object?>();
      expect(me['id'], _me);
      expect(me['isMe'], isTrue);
      expect(data.containsKey('meMissing'), isFalse);
    });

    test('says not_loaded, then no_roster once loaded without a roster', () async {
      final data = await _ok(AppState(), 'map.people');
      expect(data['people'], isEmpty);
      expect(data['me'], isNull);
      expect(data['empty'], 'not_loaded');
      final loaded = await _ok(AppState()..debugApplySnapshot(_snap()), 'map.people');
      expect(loaded['empty'], 'no_roster');
    });

    test('flags a missing own position', () async {
      final app = AppState()
        ..debugApplyRoster(Roster(selfId: _me, rows: const [
          RosterRow(id: _me, connected: true),
          RosterRow(id: 'amy-0003', name: 'amy', x: 9, y: 9, connected: true, availability: 'Active'),
        ]))
        ..debugApplySnapshot(_snap());
      final data = await _ok(app, 'map.people');
      expect(data['me'], isNull);
      expect(data['meMissing'], 'no_position');
      expect(_list(data, 'people'), hasLength(1));
    });

    test('the readout is the action', () async {
      final app = _populated();
      expect(await _ok(app, 'map.people'), mapPeopleReadout(app, boot: 'harness'));
    });
  });

  group('bad args', () {
    for (final action in ['roster', 'followers', 'directory', 'map.people']) {
      test('$action refuses a non-integer or out-of-range max as invalidParams', () async {
        final drive = _drive(_populated());
        for (final args in ['{"max":"ten"}', '{"max":-1}', '{"max":1001}', '{"max":1.5}']) {
          final err = errorOf(await drive.invoke('ext.gc.presence.$action', args));
          expect(err.code, -32602, reason: args);
        }
      });
    }
  });

  group('outward gate', () {
    test('every presence action is read-only: answered on boot=live outside the test space', () async {
      final app = _populated(); // space-1, not the-test-space
      final drive = _drive(app, boot: 'live');
      final list = resultOf(await drive.invoke('ext.gc.drive.list'));
      final actions = [
        for (final a in (list['data']! as Map)['actions'] as List)
          if (('${(a as Map)['name']}').startsWith('ext.gc.presence.')) a,
      ];
      expect(actions, hasLength(4));
      expect(actions.every((a) => a['outward'] == false), isTrue);
      for (final action in ['roster', 'followers', 'directory', 'map.people']) {
        final body = resultOf(await drive.invoke('ext.gc.presence.$action'));
        expect(body['ok'], isTrue, reason: action);
        expect((body['data']! as Map)['boot'], 'live');
      }
    });
  });
}
