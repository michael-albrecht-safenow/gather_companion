/// `ext.gc.plans.{list,add,update,delete,google.status}` through the registry,
/// on a real [AppState] over a mocked keychain: the levers save through
/// `addMeeting` / `updateMeeting` / `deleteMeeting` exactly as the editor's Save
/// and Delete do, refuse an unknown plan or room instead of quietly adding or
/// dropping the place, read their args strictly, and stay ungated on a live boot
/// outside the test space — a plan is this phone's — except when the
/// device-calendar mirror is on, which is the one road off it.
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gather_client/gather_client.dart' show SpaceMap, SpaceRoom;
import 'package:gather_companion/src/app_state.dart';
import 'package:gather_companion/src/calendar.dart';
import 'package:gather_companion/src/calendar_mirror.dart';
import 'package:gather_companion/src/calendar_store.dart';
import 'package:gather_companion/src/debug_drive/debug_drive.dart';
import 'package:gather_companion/src/debug_drive/install.dart';
import 'package:gather_companion/src/media/media_log.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'drive_test_support.dart';

/// A keychain that refuses every write, as a locked or full one would.
class _FailingStore extends CalendarStore {
  _FailingStore() : super(storage: const FlutterSecureStorage());

  @override
  Future<void> save(List<PlannedMeeting> meetings) async => throw StateError('keychain locked');
}

/// A device calendar that takes every write.
class _RecordingMirror implements CalendarMirror {
  final created = <PlannedMeeting>[];
  int _n = 0;

  @override
  Future<List<MirrorCalendar>> writableCalendars() async => const [MirrorCalendar(id: 'work', name: 'Work')];

  @override
  Future<String?> createOrUpdate(PlannedMeeting meeting, {required String calendarId}) async {
    created.add(meeting);
    return meeting.deviceEventId ?? 'dev-${_n++}';
  }

  @override
  Future<void> delete(String? deviceEventId, {required String calendarId}) async {}
}

SpaceMap _floor() => SpaceMap(
      floorId: 'floor-1',
      width: 20,
      height: 15,
      blocked: const <int>{},
      rooms: const [
        SpaceRoom(id: 'r1', name: 'Lounge', type: 'room', x: 6, y: 9, width: 8, height: 4, walled: true, stableId: 'stable-lounge'),
        SpaceRoom(id: 'r2', name: 'Focus', type: 'room', x: 13, y: 2, width: 5, height: 4, walled: true, stableId: 'stable-focus'),
      ],
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(() {
    mediaLogDebugSink = null;
    debugResetDriveLog();
  });

  DebugDrive install(AppState app, {String boot = 'harness'}) =>
      installDebugDrive(enabled: true, app: app, boot: boot, register: RecordingRegistrar().call)!;

  Future<Map<String, Object?>> call(DebugDrive drive, String action, [String args = '{}']) async =>
      resultOf(await drive.invoke('ext.gc.plans.$action', args));

  Future<String> invalid(DebugDrive drive, String action, String args) async {
    final e = errorOf(await drive.invoke('ext.gc.plans.$action', args));
    expect(e.code, -32602, reason: 'bad args are invalidParams');
    return '${e.detail}';
  }

  Map<String, Object?> dataOf(Map<String, Object?> body) {
    expect(body['ok'], isTrue, reason: '$body');
    return (body['data']! as Map).cast<String, Object?>();
  }

  final start = DateTime.now().add(const Duration(days: 1));
  final startIso = start.toIso8601String();

  PlannedMeeting plan({String id = 'p1', String title = 'Standup', int minutes = 30, String? room}) => PlannedMeeting(
        id: id,
        title: title,
        startsAt: start,
        endsAt: start.add(Duration(minutes: minutes)),
        roomStableId: room,
        roomName: room == null ? null : 'Saved $room',
        floorId: room == null ? null : 'floor-old',
      );

  group('plans.add', () {
    test('saves through addMeeting with the room resolved off the live map, and lists it', () async {
      final state = AppState()..debugMap = _floor();
      final drive = install(state);
      final data = dataOf(await call(drive, 'add',
          '{"title":"  Planning  ","startsAt":"$startIso","durationMinutes":45,"roomStableId":"stable-lounge","remindMinutesBefore":10,"id":"plan-a"}'));
      expect(data['boot'], 'harness');
      expect(data['count'], 1);
      final p = (data['plan']! as Map).cast<String, Object?>();
      expect(p['id'], 'plan-a');
      expect(p['title'], 'Planning', reason: 'trimmed, as the editor trims');
      expect(p['durationMinutes'], 45);
      expect(p['roomName'], 'Lounge');
      expect(p['floorId'], 'floor-1');
      expect(p['remindMinutesBefore'], 10);
      expect(p['mirrored'], isFalse);

      final stored = state.plannedMeetings.single;
      expect(stored.id, 'plan-a');
      expect(stored.endsAt.difference(stored.startsAt), const Duration(minutes: 45));
      // Really in the keychain, not just in memory.
      expect((await CalendarStore().load()).map((m) => m.id), ['plan-a']);

      final list = dataOf(await call(drive, 'list'));
      expect(list['count'], 1);
      expect(list['mirroring'], isFalse);
      expect(list['mirrorCalendarId'], isNull);
      expect(((list['plans']! as List).single as Map)['id'], 'plan-a');
    });

    test('defaults: a generated id, 30 minutes, five-minute reminder, no place', () async {
      final state = AppState();
      final data = dataOf(await call(install(state), 'add', '{"title":"Retro","startsAt":"$startIso"}'));
      final p = (data['plan']! as Map).cast<String, Object?>();
      expect(p['id'], isA<String>());
      expect((p['id']! as String), isNotEmpty);
      expect(p['durationMinutes'], 30);
      expect(p['remindMinutesBefore'], 5);
      expect(p['roomStableId'], isNull);
    });

    test('refuses a room the map cannot resolve, saying whether a map is there', () async {
      final state = AppState()..debugMap = _floor();
      final body = await call(install(state), 'add', '{"title":"X","startsAt":"$startIso","roomStableId":"nope"}');
      expect(body['ok'], isFalse);
      expect(body['reason'], 'no_such_room');
      expect(body['mapLoaded'], isTrue);
      expect((body['rooms']! as List).map((r) => (r as Map)['stableId']), containsAll(['stable-lounge', 'stable-focus']));
      expect(state.plannedMeetings, isEmpty);

      final noMap = await call(install(AppState()), 'add', '{"title":"X","startsAt":"$startIso","roomStableId":"stable-lounge"}');
      expect(noMap['reason'], 'no_such_room');
      expect(noMap['mapLoaded'], isFalse);
    });

    test('refuses an id already taken', () async {
      final state = AppState()..debugPlannedMeetings = [plan()];
      final body = await call(install(state), 'add', '{"id":"p1","title":"X","startsAt":"$startIso"}');
      expect(body, containsPair('reason', 'plan_exists'));
      expect(state.plannedMeetings.single.title, 'Standup');
    });

    test('a keychain that will not take the write is refused save_failed, and nothing is kept', () async {
      final state = AppState(calendarStore: _FailingStore());
      final body = await call(install(state), 'add', '{"title":"X","startsAt":"$startIso"}');
      expect(body['reason'], 'save_failed');
      expect(body['message'], 'Could not save that meeting.');
      expect(state.plannedMeetings, isEmpty);
    });

    test('bad args are invalidParams, naming the field', () async {
      final state = AppState();
      final drive = install(state);
      expect(await invalid(drive, 'add', '{"startsAt":"$startIso"}'), contains('"title" is required'));
      expect(await invalid(drive, 'add', '{"title":"   ","startsAt":"$startIso"}'), contains('title'));
      expect(await invalid(drive, 'add', '{"title":7,"startsAt":"$startIso"}'), contains('title'));
      expect(await invalid(drive, 'add', '{"title":"X"}'), contains('"startsAt" is required'));
      expect(await invalid(drive, 'add', '{"title":"X","startsAt":"tomorrow"}'), contains('ISO-8601'));
      expect(await invalid(drive, 'add', '{"title":"X","startsAt":12}'), contains('startsAt'));
      // DateTime.tryParse would roll these over (Mar 2nd, 1 am next day, Jan 2027)
      // or read midnight; each would save a plan at a moment nobody named.
      for (final bad in ['2026-02-30T10:00', '2026-11-12T25:00', '2026-13-01T10:00', '2026-11-12T10:60']) {
        expect(await invalid(drive, 'add', '{"title":"X","startsAt":"$bad"}'), contains('out of range'), reason: bad);
      }
      expect(await invalid(drive, 'add', '{"title":"X","startsAt":"2026-11-12"}'), contains('ISO-8601'));
      expect(await invalid(drive, 'update', '{"id":"p1","startsAt":"2026-02-30T10:00"}'), contains('out of range'));
      // Offsets and Z are still read as the instant they name.
      final utc = dataOf(await call(drive, 'add', '{"title":"Z","startsAt":"2030-01-02T03:04:00Z"}'));
      expect(DateTime.parse((utc['plan']! as Map)['startsAt']! as String).toUtc(), DateTime.utc(2030, 1, 2, 3, 4));
      final off = dataOf(await call(drive, 'add', '{"title":"O","startsAt":"2030-01-02T05:04:00+02:00"}'));
      expect(DateTime.parse((off['plan']! as Map)['startsAt']! as String).toUtc(), DateTime.utc(2030, 1, 2, 3, 4));
      expect(state.plannedMeetings, hasLength(2), reason: 'only the two well-formed instants were saved');
      expect(await invalid(drive, 'add', '{"title":"X","startsAt":"$startIso","durationMinutes":2}'), contains('>= 5'));
      expect(await invalid(drive, 'add', '{"title":"X","startsAt":"$startIso","durationMinutes":481}'), contains('<= 480'));
      expect(await invalid(drive, 'add', '{"title":"X","startsAt":"$startIso","durationMinutes":1.5}'), contains('integer'));
      expect(await invalid(drive, 'add', '{"title":"X","startsAt":"$startIso","remindMinutesBefore":-1}'), contains('>= 0'));
      expect(await invalid(drive, 'add', '{"title":"X","startsAt":"$startIso","roomStableId":""}'), contains('roomStableId'));
      expect(await invalid(drive, 'add', '{"title":"X","startsAt":"$startIso","id":3}'), contains('"id"'));
      expect(await invalid(drive, 'add', '{"title":"X","startAt":"$startIso"}'), contains('"startAt"'));
    });
  });

  group('plans.update', () {
    test('replaces only the given fields, keeping id, length and a saved room the map cannot resolve', () async {
      final state = AppState()..debugPlannedMeetings = [plan(minutes: 600, room: 'stable-gone')];
      final data = dataOf(await call(install(state), 'update', '{"id":"p1","title":"Retro"}'));
      final p = (data['plan']! as Map).cast<String, Object?>();
      expect(p['id'], 'p1');
      expect(p['title'], 'Retro');
      expect(p['durationMinutes'], 600, reason: 'an edit that did not touch the length keeps it, unclamped');
      expect(p['roomStableId'], 'stable-gone');
      expect(p['roomName'], 'Saved stable-gone');
      expect(p['floorId'], 'floor-old');
      expect(state.plannedMeetings.single.title, 'Retro');
    });

    test('moves the time and the room, resolving the new room off the map', () async {
      final state = AppState()
        ..debugMap = _floor()
        ..debugPlannedMeetings = [plan()];
      final later = start.add(const Duration(hours: 3));
      final data = dataOf(await call(install(state), 'update',
          '{"id":"p1","startsAt":"${later.toIso8601String()}","durationMinutes":60,"roomStableId":"stable-focus","remindMinutesBefore":0}'));
      final p = (data['plan']! as Map).cast<String, Object?>();
      expect(DateTime.parse(p['startsAt']! as String), later);
      expect(p['durationMinutes'], 60);
      expect(p['roomName'], 'Focus');
      expect(p['floorId'], 'floor-1');
      expect(p['remindMinutesBefore'], 0);
    });

    test('roomStableId:null clears the place, as "No place" does', () async {
      final state = AppState()..debugPlannedMeetings = [plan(room: 'stable-gone')];
      final p = (dataOf(await call(install(state), 'update', '{"id":"p1","roomStableId":null}'))['plan']! as Map);
      expect(p['roomStableId'], isNull);
      expect(p['roomName'], isNull);
      expect(state.plannedMeetings.single.roomStableId, isNull);
    });

    test('an unknown id is refused, not quietly added', () async {
      final state = AppState();
      final body = await call(install(state), 'update', '{"id":"ghost","title":"X"}');
      expect(body, containsPair('reason', 'no_such_plan'));
      expect(body, containsPair('id', 'ghost'));
      expect(state.plannedMeetings, isEmpty);
    });

    test('a new room that does not resolve is refused', () async {
      final state = AppState()
        ..debugMap = _floor()
        ..debugPlannedMeetings = [plan()];
      final body = await call(install(state), 'update', '{"id":"p1","roomStableId":"nope"}');
      expect(body['reason'], 'no_such_room');
      expect(state.plannedMeetings.single.roomStableId, isNull);
    });

    test('a failed write is refused save_failed and the old plan stays', () async {
      final state = AppState(calendarStore: _FailingStore())..debugPlannedMeetings = [plan()];
      final body = await call(install(state), 'update', '{"id":"p1","title":"X"}');
      expect(body['reason'], 'save_failed');
      expect(body['message'], 'Could not save that change.');
      expect(state.plannedMeetings.single.title, 'Standup');
    });

    test('bad args are invalidParams', () async {
      final drive = install(AppState()..debugPlannedMeetings = [plan()]);
      expect(await invalid(drive, 'update', '{"title":"X"}'), contains('"id" is required'));
      expect(await invalid(drive, 'update', '{"id":""}'), contains('"id"'));
      expect(await invalid(drive, 'update', '{"id":"p1","title":""}'), contains('title'));
      expect(await invalid(drive, 'update', '{"id":"p1","title":null}'), contains('title'));
      expect(await invalid(drive, 'update', '{"id":"p1","startsAt":"soon"}'), contains('ISO-8601'));
      expect(await invalid(drive, 'update', '{"id":"p1","durationMinutes":"30"}'), contains('integer'));
      expect(await invalid(drive, 'update', '{"id":"p1","roomStableId":5}'), contains('roomStableId'));
      expect(await invalid(drive, 'update', '{"id":"p1","colour":"red"}'), contains('"colour"'));
    });
  });

  group('plans.delete', () {
    test('removes it through deleteMeeting, from the list and the keychain', () async {
      final state = AppState();
      final drive = install(state);
      dataOf(await call(drive, 'add', '{"id":"p1","title":"X","startsAt":"$startIso"}'));
      final data = dataOf(await call(drive, 'delete', '{"id":"p1"}'));
      expect(data, {'boot': 'harness', 'deleted': 'p1', 'count': 0});
      expect(state.plannedMeetings, isEmpty);
      expect(await CalendarStore().load(), isEmpty);
    });

    test('an unknown id is refused, not answered as a success', () async {
      final body = await call(install(AppState()), 'delete', '{"id":"ghost"}');
      expect(body, containsPair('reason', 'no_such_plan'));
    });

    test('a failed write is refused delete_failed and the plan is put back', () async {
      final state = AppState(calendarStore: _FailingStore())..debugPlannedMeetings = [plan()];
      final body = await call(install(state), 'delete', '{"id":"p1"}');
      expect(body['reason'], 'delete_failed');
      expect(state.plannedMeetings.single.id, 'p1');
    });

    test('bad args are invalidParams', () async {
      final drive = install(AppState());
      expect(await invalid(drive, 'delete', '{}'), contains('"id" is required'));
      expect(await invalid(drive, 'delete', '{"id":1}'), contains('"id"'));
      expect(await invalid(drive, 'delete', '{"id":"p1","all":true}'), contains('"all"'));
    });
  });

  group('plans.google.status', () {
    test('a build with no Google client says so, with nothing to connect', () async {
      final data = dataOf(await call(install(AppState(), boot: 'live'), 'google.status'));
      expect(data, {
        'boot': 'live',
        'available': false,
        'connected': false,
        'showConnect': false,
        'events': 0,
        'sharedCalendars': <String>[],
      });
    });

    test('a connected account reports the shared calendar names, and no ids', () async {
      final state = AppState()..debugSeedCalendarIndex({'jaime': 'jaime@cal.example', 'ana': 'ana-id'});
      final data = dataOf(await call(install(state), 'google.status'));
      expect(data['connected'], isTrue);
      expect(data['sharedCalendars'], ['ana', 'jaime']);
      expect('$data', isNot(contains('jaime@cal.example')));
    });

    test('takes no args', () async {
      expect(await invalid(install(AppState()), 'google.status', '{"x":1}'), contains('"x"'));
      expect(await invalid(install(AppState()), 'list', '{"x":1}'), contains('"x"'));
    });
  });

  group('the gate: a plan is this phone\'s, unless it is mirrored', () {
    test('none is outward, and on a live boot outside the test space they all run', () async {
      final state = AppState();
      final drive = install(state, boot: 'live');
      final listed = {
        for (final a in drive.actions)
          if (a.name.startsWith('ext.gc.plans.')) a.name: a.outward,
      };
      expect(listed, {
        'ext.gc.plans.state': false,
        'ext.gc.plans.list': false,
        'ext.gc.plans.add': false,
        'ext.gc.plans.update': false,
        'ext.gc.plans.delete': false,
        'ext.gc.plans.google.status': false,
      });
      expect(state.snapshot.self.spaceId, isNull, reason: 'not in the test space');
      dataOf(await call(drive, 'add', '{"id":"p1","title":"X","startsAt":"$startIso"}'));
      dataOf(await call(drive, 'update', '{"id":"p1","title":"Y"}'));
      dataOf(await call(drive, 'delete', '{"id":"p1"}'));
    });

    test('with the device-calendar mirror on, a live write needs confirm', () async {
      final mirror = _RecordingMirror();
      final state = AppState(calendarMirror: mirror);
      await state.setMirrorCalendar('work');
      final drive = install(state, boot: 'live');

      final refused = await call(drive, 'add', '{"id":"p1","title":"X","startsAt":"$startIso"}');
      expect(refused, {'mirrorCalendarId': 'work', 'ok': false, 'reason': 'calendar_mirror_on'});
      expect(mirror.created, isEmpty);
      expect(state.plannedMeetings, isEmpty);

      final added = dataOf(await call(drive, 'add', '{"id":"p1","title":"X","startsAt":"$startIso","confirm":true}'));
      expect((added['plan']! as Map)['mirrored'], isTrue);
      expect(mirror.created, hasLength(1));

      expect((await call(drive, 'update', '{"id":"p1","title":"Y"}'))['reason'], 'calendar_mirror_on');
      expect((await call(drive, 'delete', '{"id":"p1"}'))['reason'], 'calendar_mirror_on');
      expect(state.plannedMeetings.single.title, 'X');
      dataOf(await call(drive, 'update', '{"id":"p1","title":"Y","confirm":true}'));
      dataOf(await call(drive, 'delete', '{"id":"p1","confirm":true}'));
      expect(state.plannedMeetings, isEmpty);
    });

    test('the harness is never held, mirror or not', () async {
      final state = AppState(calendarMirror: _RecordingMirror());
      await state.setMirrorCalendar('work');
      dataOf(await call(install(state), 'add', '{"title":"X","startsAt":"$startIso"}'));
    });
  });
}
