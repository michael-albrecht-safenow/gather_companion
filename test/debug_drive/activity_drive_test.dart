/// `activity.*`: the feed read through the drive, and the tab's two levers —
/// refresh and mark-read — driven as ops over the real `AppState` methods.
///
/// The levers need a signed-in state with a feed, so most cases boot a real
/// `AppState` on a `FakeCollector` and a scripted [ActivityFeed] (no network);
/// the readout cases use `debugApplyActivity`.
library;

import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gather_client/gather_client.dart';
import 'package:gather_companion/harness/fake_collector.dart';
import 'package:gather_companion/src/app_state.dart';
import 'package:gather_companion/src/calendar.dart';
import 'package:gather_companion/src/calendar_store.dart';
import 'package:gather_companion/src/credentials.dart';
import 'package:gather_companion/src/debug_drive/activity_drive.dart';
import 'package:gather_companion/src/debug_drive/debug_drive.dart';
import 'package:gather_companion/src/debug_drive/install.dart';
import 'package:gather_companion/src/notifications.dart';
import 'package:gather_companion/src/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'drive_test_support.dart';

class _SilentNotifier extends Notifier {
  @override
  Future<void> init() async {}
}

class _Creds extends GatherCredentialStore {
  _Creds(this.space);
  final String? space;
  @override
  Future<GatherCredentials> load() async => const GatherCredentials(refreshToken: 'r', idToken: 'i', uid: 'uid-1');
  @override
  Future<String?> loadSpaceId() async => space;
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

/// A feed whose answers the test sets.
class _ScriptFeed extends ActivityFeed {
  _ScriptFeed(GatherAuth auth) : super(auth: auth);

  List<ActivityItem> items = const [];
  Object? fetchError;
  Object? markError;
  Completer<void>? gate;
  int fetches = 0;
  final marked = <List<String>>[];

  @override
  Future<ActivityFeedPage> fetch(String spaceId) async {
    fetches++;
    final g = gate;
    if (g != null) await g.future;
    final error = fetchError;
    if (error != null) throw error;
    return ActivityFeedPage(items: items, fetchedAt: DateTime.utc(2026, 11, 11));
  }

  @override
  Future<void> markRead(String spaceId, Iterable<ActivityItem> items) async {
    marked.add([for (final i in items) i.id]);
    final error = markError;
    if (error != null) throw error;
  }
}

MeetingArtifactActivity _artifact(String id, {bool read = false}) => MeetingArtifactActivity(
      id: id,
      at: DateTime.utc(2026, 11, 10, 9),
      isRead: read,
      subscriptionId: 'sub-$id',
      activityEventId: 'ev-$id',
      meetingTitle: 'Standup',
      hasMeetingMemo: true,
    );

final _wave = WaveActivity(id: 'wave-1', at: DateTime.utc(2026, 11, 10, 10), actorSpaceUserId: 'bob-0002');

const _unknown = UnknownActivity(
  id: 'odd-1',
  at: null,
  isRead: false,
  kind: 'Brand-new kind',
  payload: {'secretish': 'not echoed'},
);

FakeCollector? _lastCollector;

Future<(AppState, _ScriptFeed)> _booted({String? space = 'space-a', bool collectorSpace = true}) async {
  late _ScriptFeed feed;
  final app = AppState(
    notifier: _SilentNotifier(),
    credentials: _Creds(space),
    bridge: _NoBridge(),
    calendarStore: _EmptyCalendarStore(),
    buildCollector: (auth, spaceId) {
      final c = FakeCollector(participants: 1);
      if (!collectorSpace) c.spaceId = null;
      return _lastCollector = c;
    },
    buildActivityFeed: (auth) => feed = _ScriptFeed(auth),
    connectivityNow: () async => const [ConnectivityResult.wifi],
    connectivityChanges: const Stream<List<ConnectivityResult>>.empty(),
  );
  addTearDown(app.dispose);
  await app.boot();
  await pumpEventQueue();
  return (app, feed);
}

DebugDrive _drive(AppState app, {String boot = 'harness'}) =>
    installDebugDrive(enabled: true, app: app, boot: boot, register: RecordingRegistrar().call, testSpaceId: 'the-test-space')!;

Future<Map<String, Object?>> _call(DebugDrive drive, String action, [String? args]) async =>
    resultOf(await drive.invoke('ext.gc.activity.$action', args));

/// Polls `op.result` for [id] until it is no longer pending.
Future<Map<String, Object?>> _settle(DebugDrive drive, String id) async {
  for (var i = 0; i < 50; i++) {
    await pumpEventQueue();
    final body = resultOf(await drive.invoke('ext.gc.op.result', '{"id":"$id"}'));
    final data = (body['data']! as Map).cast<String, Object?>();
    if (data['state'] != 'pending') {
      expect(data['state'], 'done', reason: '$data');
      return (data['result']! as Map).cast<String, Object?>();
    }
  }
  fail('op $id never settled');
}

List<Map<String, Object?>> _items(Map<String, Object?> data) =>
    [for (final e in data['items']! as List) (e as Map).cast<String, Object?>()];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(debugResetDriveLog);

  group('activity.list', () {
    test('reads the feed with kinds, unread and no raw payload', () async {
      final app = AppState()..debugApplyActivity([_wave, _artifact('a1'), _artifact('a2', read: true), _unknown]);
      final body = await _call(_drive(app), 'list');
      expect(body['ok'], isTrue);
      final data = (body['data']! as Map).cast<String, Object?>();
      expect(data['boot'], 'harness');
      expect(data['count'], 4);
      expect(data['unread'], 2);
      expect(data['fetched'], isFalse, reason: 'debugApplyActivity with no space is not fetched for one');
      expect(data['loading'], isFalse);
      expect(data.containsKey('empty'), isFalse);
      final items = _items(data);
      expect([for (final i in items) i['kind']], ['wave', 'meetingArtifact', 'meetingArtifact', 'unknown']);
      expect(items[0]['actorId'], 'bob-0002');
      expect(items[0]['actorName'], 'bob-0002'.substring(0, 8));
      expect(items[1]['meetingTitle'], 'Standup');
      expect(items[1]['canMarkRead'], isTrue);
      expect(items[3]['unknownKind'], 'Brand-new kind');
      expect('$data', isNot(contains('not echoed')));
    });

    test('unread is explained: live waves count though isRead is true', () async {
      // The field defect: `unread: 6` over items that all said `isRead: true`,
      // because live waves count toward the badge whatever their flag says.
      final (app, _) = await _booted();
      app.debugApplyActivity([_artifact('a1'), _artifact('a2', read: true)]);
      _lastCollector!
        ..injectWave('space-ada')
        ..injectWave('space-bob');
      await pumpEventQueue();
      expect(app.unreadActivityCount, 3, reason: 'two live waves + a1');

      final data = (await _call(_drive(app), 'list'))['data']! as Map<String, Object?>;
      expect(data['unread'], 3);
      expect(data['unreadBreakdown'], {'live': 2, 'fetchedUnread': 1});
      final items = _items(data);
      expect([for (final i in items) i['kind']], ['wave', 'wave', 'meetingArtifact', 'meetingArtifact']);
      expect([for (final i in items) i['isRead']], [true, true, false, true]);
      expect([for (final i in items) i['countsAsUnread']], [true, true, true, false]);
      expect(items.where((i) => i['countsAsUnread'] == true).length, data['unread'],
          reason: 'the per-item flags add up to the badge');
    });

    test('a fetched wave is read and does not count', () async {
      final app = AppState()..debugApplyActivity([_wave]);
      final data = (await _call(_drive(app), 'list'))['data']! as Map<String, Object?>;
      expect(data['unread'], 0);
      expect(data['unreadBreakdown'], {'live': 0, 'fetchedUnread': 0});
      expect(_items(data).single['countsAsUnread'], isFalse);
    });

    test('max truncates and says so', () async {
      final app = AppState()..debugApplyActivity([_wave, _artifact('a1')]);
      final data = (await _call(_drive(app), 'list', '{"max":1}'))['data']! as Map;
      expect(data['items'], hasLength(1));
      expect(data['truncated'], isTrue);
      expect(errorOf(await _drive(app).invoke('ext.gc.activity.list', '{"max":"x"}')).code, -32602);
    });

    test('an empty feed says why: not signed in, nothing yet, fetch failed', () async {
      final fresh = (await _call(_drive(AppState()), 'list'))['data']! as Map;
      expect(fresh['empty'], 'not_signed_in');
      expect(fresh['unavailable'], 'not_signed_in');

      final (app, feed) = await _booted();
      expect(feed.fetches, 1, reason: 'the boot auto-load');
      final empty = (await _call(_drive(app), 'list'))['data']! as Map;
      expect(empty['empty'], 'nothing_yet');
      expect(empty['unavailable'], isNull);

      app.debugApplyActivity(const [], error: const ActivityFeedException('refused', status: 500));
      final failed = (await _call(_drive(app), 'list'))['data']! as Map;
      expect(failed['empty'], 'fetch_failed');
      expect(failed['error'], contains('500'));
    });
  });

  group('activity.refresh', () {
    test('is an op over refreshActivity that answers the new list', () async {
      final (app, feed) = await _booted();
      feed.items = [_artifact('a1'), _artifact('a2')];
      final drive = _drive(app);
      final started = await _call(drive, 'refresh');
      expect(started['ok'], isTrue);
      final id = (started['data']! as Map)['id'] as String;
      expect(id, startsWith('activityRefresh-'));
      final result = await _settle(drive, id);
      expect(result['ok'], isTrue);
      expect((result['data']! as Map)['count'], 2);
      expect(feed.fetches, 2);
      expect(app.activity, hasLength(2));
    });

    test('a fetch Gather refuses is refused fetch_failed, not ok', () async {
      final (app, feed) = await _booted();
      feed.fetchError = const ActivityFeedException('activity feed refused', status: 403);
      final drive = _drive(app);
      final id = ((await _call(drive, 'refresh'))['data']! as Map)['id'] as String;
      final result = await _settle(drive, id);
      expect(result['ok'], isFalse);
      expect(result['reason'], 'fetch_failed');
      expect(result['error'], contains('403'));
    });

    test('refuses not_signed_in without a feed', () async {
      final body = await _call(_drive(AppState()), 'refresh');
      expect(body, {'ok': false, 'reason': 'not_signed_in'});
    });

    test('refuses no_space when Gather has named none', () async {
      final (app, feed) = await _booted(space: null, collectorSpace: false);
      expect(app.activityUnavailable, 'no_space');
      expect(await _call(_drive(app), 'refresh'), {'ok': false, 'reason': 'no_space'});
      expect(feed.fetches, 0);
    });

    test('refuses already_loading while a fetch is in flight', () async {
      final (app, feed) = await _booted();
      final drive = _drive(app);
      feed.gate = Completer<void>();
      final id = ((await _call(drive, 'refresh'))['data']! as Map)['id'] as String;
      await pumpEventQueue();
      expect(app.isLoadingActivity, isTrue);
      expect(await _call(drive, 'refresh'), {'ok': false, 'reason': 'already_loading'});
      feed.gate!.complete();
      expect((await _settle(drive, id))['ok'], isTrue);
    });
  });

  group('activity.markRead', () {
    Future<(AppState, _ScriptFeed, DebugDrive)> withItems() async {
      final (app, feed) = await _booted();
      app.debugApplyActivity([_wave, _artifact('a1'), _artifact('a2'), _artifact('a3', read: true)]);
      return (app, feed, _drive(app));
    }

    test('ids: marks those, through markActivityRead, and answers the list', () async {
      final (app, feed, drive) = await withItems();
      final started = await _call(drive, 'markRead', '{"ids":["a1","wave-1"]}');
      expect(started['ok'], isTrue);
      final data = (started['data']! as Map).cast<String, Object?>();
      expect(data['marking'], ['a1']);
      expect(data['skipped'], [
        {'id': 'wave-1', 'why': 'cannot_mark'},
      ]);
      final result = await _settle(drive, data['id']! as String);
      expect(result['ok'], isTrue);
      expect((result['data']! as Map)['marked'], ['a1']);
      expect(feed.marked, [
        ['a1'],
      ]);
      expect(app.unreadActivityCount, 1, reason: 'a2 is still unread');
    });

    test('all:true marks every markable unread item, like the button', () async {
      final (app, feed, drive) = await withItems();
      final data = (await _call(drive, 'markRead', '{"all":true}'))['data']! as Map;
      expect(data['marking'], ['a1', 'a2']);
      expect([for (final s in data['skipped'] as List) (s as Map)['why']], ['cannot_mark', 'already_read']);
      final result = await _settle(drive, data['id'] as String);
      expect(result['ok'], isTrue);
      expect(app.unreadActivityCount, 0);
    });

    test('refuses no_such_item naming the missing ids', () async {
      final (_, feed, drive) = await withItems();
      expect(await _call(drive, 'markRead', '{"ids":["a1","nope"]}'), {
        'missing': ['nope'],
        'ok': false,
        'reason': 'no_such_item',
      });
      expect(feed.marked, isEmpty);
    });

    test('refuses nothing_to_mark when every pick is skipped', () async {
      final (_, feed, drive) = await withItems();
      final body = await _call(drive, 'markRead', '{"ids":["a3","wave-1"]}');
      expect(body['ok'], isFalse);
      expect(body['reason'], 'nothing_to_mark');
      expect(body['skipped'], hasLength(2));
      expect(feed.marked, isEmpty);
    });

    test('a Gather refusal puts the rows back and answers mark_failed', () async {
      final (app, feed, drive) = await withItems();
      feed.markError = const ActivityFeedException('toggle refused', status: 500);
      final id = ((await _call(drive, 'markRead', '{"ids":["a1"]}'))['data']! as Map)['id'] as String;
      final result = await _settle(drive, id);
      expect(result['ok'], isFalse);
      expect(result['reason'], 'mark_failed');
      expect(result['error'], contains('toggle refused'));
      expect(app.unreadActivityCount, 2, reason: 'the optimistic flip was undone');
    });

    test('refuses not_signed_in without a feed', () async {
      final app = AppState()..debugApplyActivity([_artifact('a1')]);
      expect(await _call(_drive(app), 'markRead', '{"all":true}'), {'ok': false, 'reason': 'not_signed_in'});
    });

    test('bad args are invalidParams', () async {
      final (_, feed, drive) = await withItems();
      for (final args in [
        '{}',
        '{"ids":[]}',
        '{"ids":"a1"}',
        '{"ids":[1]}',
        '{"ids":[""]}',
        '{"all":"yes"}',
        '{"all":true,"ids":["a1"]}',
        '{"all":false}',
      ]) {
        expect(errorOf(await drive.invoke('ext.gc.activity.markRead', args)).code, -32602, reason: args);
      }
      expect(feed.marked, isEmpty);
    });
  });

  group('outward gate', () {
    test('no activity action is outward: all answered on boot=live outside the test space', () async {
      final (app, feed) = await _booted(); // space-a, not the-test-space
      app.debugApplyActivity([_artifact('a1')]);
      final drive = _drive(app, boot: 'live');
      final list = resultOf(await drive.invoke('ext.gc.drive.list'));
      final actions = [
        for (final a in (list['data']! as Map)['actions'] as List)
          if (('${(a as Map)['name']}').startsWith('ext.gc.activity.')) a,
      ];
      expect(actions, hasLength(3));
      expect(actions.every((a) => a['outward'] == false), isTrue);

      final listed = await _call(drive, 'list');
      expect(listed['ok'], isTrue);
      expect((listed['data']! as Map)['boot'], 'live');
      final refresh = await _call(drive, 'refresh');
      expect(refresh['ok'], isTrue, reason: '$refresh');
      await _settle(drive, (refresh['data']! as Map)['id'] as String);
      app.debugApplyActivity([_artifact('a1')]);
      final mark = await _call(drive, 'markRead', '{"all":true}');
      expect(mark['ok'], isTrue, reason: '$mark');
      await _settle(drive, (mark['data']! as Map)['id'] as String);
      expect(feed.marked, [
        ['a1'],
      ]);
    });
  });

  test('activityReadout is the readout the action sends', () async {
    final app = AppState()..debugApplyActivity([_artifact('a1')]);
    final via = (await _call(_drive(app), 'list'))['data'];
    expect(via, activityReadout(app, boot: 'harness'));
  });
}
