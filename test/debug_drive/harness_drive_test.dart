/// `ext.gc.harness.*`: the simulator scene scripted through the drive.
///
/// The handler tests run the feature over a bare [FakeCollector] +
/// [ScriptedCall] + [AppScenarioDriver] (clock not started, so nothing moves
/// unless an action moves it). The last test is the plan's goal end to end on a
/// booted `AppState` built the way `lib/main_harness.dart` builds it: seat a
/// colleague two tiles away, watch the real cluster debounce build the call,
/// hold the floor on them, and read the spotlight off the mounted call screen.
library;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gather_client/gather_client.dart';
import 'package:gather_companion/harness/call_scenarios.dart';
import 'package:gather_companion/harness/demo_footage.dart';
import 'package:gather_companion/harness/fake_collector.dart';
import 'package:gather_companion/harness/harness_data.dart';
import 'package:gather_companion/harness/harness_drive.dart';
import 'package:gather_companion/harness/scripted_call.dart';
import 'package:gather_companion/src/app_state.dart';
import 'package:gather_companion/src/calendar.dart';
import 'package:gather_companion/src/calendar_store.dart';
import 'package:gather_companion/src/credentials.dart';
import 'package:gather_companion/src/debug_drive/debug_drive.dart';
import 'package:gather_companion/src/debug_drive/install.dart';
import 'package:gather_companion/src/media/media_log.dart';
import 'package:gather_companion/src/media/spotlight_controller.dart';
import 'package:gather_companion/src/notifications.dart';
import 'package:gather_companion/src/settings.dart';
import 'package:gather_companion/theme/gather_theme.dart';
import 'package:gather_companion/ui/call_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'drive_test_support.dart';

const _actions = [
  'placePerson',
  'stepPerson',
  'wave',
  'call.emit',
  'call.speak',
  'scenario',
];

class _Scene {
  _Scene({String boot = 'harness', String? testSpaceId, AppState? app, FakeCollector? fake, ScriptedCall? call})
      : app = app ?? AppState(),
        fake = fake ?? FakeCollector(participants: 3),
        call = call ?? ScriptedCall() {
    driver = AppScenarioDriver(state: this.app, collector: this.fake, call: this.call, scenario: AppScenario.still);
    drive = installDebugDrive(
      enabled: true,
      app: this.app,
      boot: boot,
      register: RecordingRegistrar().call,
      testSpaceId: testSpaceId ?? '',
      extraFeatures: [harnessFeature(collector: this.fake, call: this.call, driver: driver, boot: () => boot)],
    )!;
  }

  final AppState app;
  final FakeCollector fake;
  final ScriptedCall call;
  late final AppScenarioDriver driver;
  late final DebugDrive drive;

  Future<Map<String, Object?>> invoke(String action, [String? args]) async =>
      resultOf(await drive.invoke('ext.gc.harness.$action', args));

  Future<Map<String, Object?>> ok(String action, [String? args]) async {
    final body = await invoke(action, args);
    expect(body['ok'], isTrue, reason: '$action $args → $body');
    return (body['data']! as Map).cast<String, Object?>();
  }

  Future<int> badArgs(String action, [String? args]) async => errorOf(await drive.invoke('ext.gc.harness.$action', args)).code;
}

Map<String, Object?> _person(Map<String, Object?> readout, String id) =>
    (readout['people']! as List).cast<Map<String, Object?>>().firstWhere((p) => p['id'] == id);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    spotlightRegistry.debugReset();
  });
  tearDown(() {
    spotlightRegistry.debugReset();
    mediaLogDebugSink = null;
  });

  test('every action is listed, none outward — they move fakes nobody else can see', () {
    final s = _Scene();
    final listed = {for (final a in s.drive.actions) a.name: a.outward};
    for (final a in _actions) {
      expect(listed['ext.gc.harness.$a'], isFalse, reason: a);
    }
  });

  test('a default install — what lib/main.dart makes — carries no harness action', () {
    final drive = installDebugDrive(enabled: true, app: AppState(), boot: 'live', register: RecordingRegistrar().call)!;
    expect([for (final a in drive.actions) a.name].where((n) => n.startsWith('ext.gc.harness.')), isEmpty);
  });

  group('placePerson', () {
    test('dx/dy seats a colleague relative to me and puts them in call range', () async {
      final s = _Scene();
      final r = await s.ok('placePerson', '{"id":"ada","dx":2}');
      final ada = _person(r, 'space-ada');
      expect(ada['x'], kSelfStartTile.x + 2);
      expect(ada['y'], kSelfStartTile.y);
      expect(ada['distance'], 2.0);
      expect(ada['inCallRange'], isTrue);
      expect(r['callmates'], ['space-ada']);
      expect(r['boot'], 'harness');
      expect(r['scenario'], 'still');
      expect(r['me'], {'id': kSelfId, 'x': kSelfStartTile.x, 'y': kSelfStartTile.y, 'speaking': false});
      // settle() pushed the call state for the person now beside me.
      expect((r['call']! as Map)['participants'], [
        {'srcId': 'acc-ada', 'audio': true, 'video': false, 'audioPaused': false, 'videoPaused': false, 'screen': false},
      ]);
    });

    test('x/y is an absolute tile; name, spaceId and accountId all resolve; direction is any case', () async {
      final s = _Scene();
      var r = await s.ok('placePerson', '{"id":"Grace","x":0,"y":0,"direction":"left"}');
      expect(_person(r, 'space-grace'), containsPair('x', 0));
      expect(_person(r, 'space-grace'), containsPair('direction', 'Left'));
      expect(_person(r, 'space-grace')['inCallRange'], isFalse);
      r = await s.ok('placePerson', '{"id":"acc-grace","x":19}');
      expect(_person(r, 'space-grace'), allOf(containsPair('x', 19), containsPair('y', 0)));
      r = await s.ok('placePerson', '{"id":"space-grace","y":14}');
      expect(_person(r, 'space-grace'), allOf(containsPair('x', 19), containsPair('y', 14)));
    });

    test('refuses someone not seated, and an offset that leaves the floor', () async {
      final s = _Scene();
      expect(await s.invoke('placePerson', '{"id":"linus","dx":1}'), {
        'ok': false,
        'reason': 'no_such_person',
        'id': 'linus',
        'people': ['space-ada', 'space-grace', 'space-kat'],
      });
      expect(await s.invoke('placePerson', '{"id":"ada","dx":50}'), {
        'ok': false,
        'reason': 'off_floor',
        'x': kSelfStartTile.x + 50,
        'y': kSelfStartTile.y,
        'width': kOfficeWidth,
        'height': kOfficeHeight,
      });
    });

    test('bad args are invalidParams', () async {
      final s = _Scene();
      expect(await s.badArgs('placePerson'), -32602);
      expect(await s.badArgs('placePerson', '{"id":"ada"}'), -32602, reason: 'no tile, no offset');
      expect(await s.badArgs('placePerson', '{"id":"ada","x":1,"dx":1}'), -32602, reason: 'both');
      expect(await s.badArgs('placePerson', '{"id":"ada","x":20}'), -32602, reason: 'off the floor');
      expect(await s.badArgs('placePerson', '{"id":"ada","dx":1.5}'), -32602);
      expect(await s.badArgs('placePerson', '{"id":"ada","dx":1,"direction":"north"}'), -32602);
    });
  });

  group('stepPerson', () {
    test('walks a colleague n tiles, clamped to the floor', () async {
      final s = _Scene();
      final start = kCastStartTiles['space-ada']!;
      var r = await s.ok('stepPerson', '{"id":"ada","direction":"Right","steps":3}');
      expect(_person(r, 'space-ada'), allOf(containsPair('x', start.x + 3), containsPair('direction', 'Right')));
      r = await s.ok('stepPerson', '{"id":"ada","direction":"up","steps":30}');
      expect(_person(r, 'space-ada')['y'], 0, reason: 'clamped');
      r = await s.ok('stepPerson', '{"id":"ada","direction":"down"}');
      expect(_person(r, 'space-ada')['y'], 1, reason: 'one step by default');
    });

    test('refusal and bad args', () async {
      final s = _Scene();
      expect((await s.invoke('stepPerson', '{"id":"nobody","direction":"up"}'))['reason'], 'no_such_person');
      expect(await s.badArgs('stepPerson', '{"id":"ada"}'), -32602);
      expect(await s.badArgs('stepPerson', '{"id":"ada","direction":"up","steps":0}'), -32602);
    });
  });

  group('wave', () {
    test('from a seated colleague: an incoming WaveEvent aimed at me', () async {
      final s = _Scene();
      final events = <BusEvent>[];
      s.fake.interactions.listen(events.add);
      final r = await s.ok('wave', '{"from":"katherine"}');
      await pumpEventQueue();
      expect(r['waved'], {'from': 'space-kat', 'to': kSelfId});
      expect(events.single.name, 'WaveEvent');
      expect(events.single.senderId, 'space-kat');
      expect(events.single.isFor(kSelfId), isTrue);
      expect(s.fake.waves, isEmpty, reason: 'nothing was *sent*: the outgoing Collector.wave is untouched');
    });

    test('refusal and bad args', () async {
      final s = _Scene();
      expect((await s.invoke('wave', '{"from":"kat"}'))['reason'], 'no_such_person');
      expect(await s.badArgs('wave'), -32602);
    });
  });

  group('call.emit', () {
    test('holds a call shape across ticks, until released', () async {
      final s = _Scene();
      final r = await s.ok('call.emit',
          '{"participants":[{"id":"ada","video":true},{"id":"grace","audioPaused":true,"screen":true}],"publishingAudio":false}');
      expect(r['heldCall'], isTrue);
      expect((r['call']! as Map)['publishingAudio'], isFalse);
      expect((r['call']! as Map)['participants'], [
        {'srcId': 'acc-ada', 'audio': true, 'video': true, 'audioPaused': false, 'videoPaused': false, 'screen': false},
        {'srcId': 'acc-grace', 'audio': true, 'video': false, 'audioPaused': true, 'videoPaused': false, 'screen': true},
      ]);
      // Nobody is near me, yet the scenario's next beat keeps the held shape.
      s.driver.settle();
      expect(s.call.state.participants.map((p) => p.srcId), ['acc-ada', 'acc-grace']);

      final released = await s.ok('call.emit', '{"release":true}');
      expect(released['heldCall'], isFalse);
      expect(s.call.state.participants, isEmpty, reason: 'nobody near → the scenario empties the call');
    });

    test('refusal and bad args', () async {
      final s = _Scene();
      expect((await s.invoke('call.emit', '{"participants":[{"id":"linus"}]}'))['reason'], 'no_such_person');
      expect(s.driver.heldCall, isNull, reason: 'a refused emit holds nothing');
      expect(await s.badArgs('call.emit'), -32602);
      expect(await s.badArgs('call.emit', '{"participants":"ada"}'), -32602);
      expect(await s.badArgs('call.emit', '{"participants":[{}]}'), -32602);
      expect(await s.badArgs('call.emit', '{"participants":[{"id":"ada","video":"yes"}]}'), -32602);
      expect(await s.badArgs('call.emit', '{"participants":[],"release":true}'), -32602);
    });
  });

  group('call.speak', () {
    test('holds the floor on one person over the rotation, adds and drops voices, releases', () async {
      final s = _Scene();
      await s.ok('placePerson', '{"id":"ada","dx":1}');
      await s.ok('placePerson', '{"id":"grace","dx":-1}');
      // Whoever the rotation lit, the first hold takes the whole floor.
      s.fake.placePerson('space-ada', speaking: true);
      var r = await s.ok('call.speak', '{"id":"grace"}');
      expect(r['heldSpeakers'], ['space-grace']);
      expect(_person(r, 'space-grace')['speaking'], isTrue);
      expect(_person(r, 'space-ada')['speaking'], isFalse);
      // The scenario's next beat would rotate the floor; the hold keeps it.
      for (var i = 0; i < 6; i++) {
        s.driver.settle();
      }
      expect(s.fake.standing('space-grace')!.speaking, isTrue);
      expect(s.fake.standing('space-ada')!.speaking, isFalse);

      r = await s.ok('call.speak', '{"id":"me"}');
      expect(r['heldSpeakers'], unorderedEquals(['space-grace', kSelfId]));
      expect((r['me']! as Map)['speaking'], isTrue);
      expect(s.call.isSpeaking, isTrue);

      r = await s.ok('call.speak', '{"id":"grace","speaking":false}');
      expect(r['heldSpeakers'], [kSelfId]);
      expect(_person(r, 'space-grace')['speaking'], isFalse);

      r = await s.ok('call.speak', '{"release":true}');
      expect(r['heldSpeakers'], isNull);
    });

    test('refusal and bad args', () async {
      final s = _Scene();
      expect((await s.invoke('call.speak', '{"id":"bob"}'))['reason'], 'no_such_person');
      expect(s.driver.heldSpeakers, isNull);
      expect(await s.badArgs('call.speak'), -32602);
      expect(await s.badArgs('call.speak', '{"id":"ada","release":true}'), -32602);
      expect(await s.badArgs('call.speak', '{"id":"ada","speaking":1}'), -32602);
    });
  });

  group('scenario', () {
    test('switches the running office, any case', () async {
      final s = _Scene();
      expect((await s.ok('scenario', '{"name":"OFFICE"}'))['scenario'], 'office');
      expect(s.driver.scenario, AppScenario.office);
      expect((await s.ok('scenario', '{"name":"still"}'))['scenario'], 'still');
    });

    test('an unknown name is invalidParams, not a silent fallback to office', () async {
      final s = _Scene();
      expect(await s.badArgs('scenario', '{"name":"party"}'), -32602);
      expect(await s.badArgs('scenario'), -32602);
      expect(s.driver.scenario, AppScenario.still);
    });
  });

  group('boot=live', () {
    // Not registered by lib/main.dart at all (above). If somebody does wire it to a
    // live-booted drive, the outward gate does not apply — none is outward — so
    // every action must refuse on its own rather than script a fake on a real map.
    for (final (action, args) in [
      ('placePerson', '{"id":"ada","dx":1}'),
      ('stepPerson', '{"id":"ada","direction":"up"}'),
      ('wave', '{"from":"ada"}'),
      ('call.emit', '{"participants":[{"id":"ada"}]}'),
      ('call.speak', '{"id":"ada"}'),
      ('scenario', '{"name":"office"}'),
    ]) {
      test('$action refuses not_harness — with or without confirm', () async {
        {
          final s = _Scene(boot: 'live');
          final before = s.fake.standing('space-ada')!;
          expect(await s.invoke(action, args), {'ok': false, 'reason': 'not_harness', 'boot': 'live'});
          final confirmed = args.replaceFirst('{', '{"confirm":true,');
          expect(await s.invoke(action, confirmed), {'ok': false, 'reason': 'not_harness', 'boot': 'live'});
          final after = s.fake.standing('space-ada')!;
          expect((after.x, after.y), (before.x, before.y), reason: 'nothing moved');
          expect(s.driver.heldSpeakers, isNull);
          expect(s.driver.heldCall, isNull);
          expect(s.driver.scenario, AppScenario.still);
        }
      });
    }
  });

  testWidgets('the plan\'s goal: seat Ada 2 tiles away → the call forms → call.speak ada → call.spotlight reports Ada',
      (tester) async {
    var now = DateTime.utc(2026, 11, 11, 9);
    final fake = FakeCollector(participants: 3);
    final call = ScriptedCall();
    // Built the way lib/main_harness.dart builds TARGET=app.
    final app = AppState(
      notifier: _SilentNotifier(),
      credentials: _HarnessCredentials(),
      bridge: _EmptyBridge(),
      calendarStore: _EmptyCalendarStore(),
      buildCollector: (auth, spaceId) => fake,
      buildCall: (auth, spaceId, srcId) => call,
      buildActivityFeed: _SilentFeed.new,
      connectivityNow: () async => const [ConnectivityResult.wifi],
      connectivityChanges: const Stream<List<ConnectivityResult>>.empty(),
    );
    final s = _Scene(app: app, fake: fake, call: call);
    await app.boot();
    await tester.pump();
    s.driver.start();
    expect(app.callHandle, isNull, reason: 'standing alone: no call yet');

    Future<Map<String, Object?>> drive(String method, [String? args]) async {
      final body = resultOf(await s.drive.invoke(method, args));
      expect(body['ok'], isTrue, reason: '$method → $body');
      return (body['data']! as Map).cast<String, Object?>();
    }

    // 1. Seat Ada two tiles from me.
    final placed = await drive('ext.gc.harness.placePerson', '{"id":"ada","dx":2}');
    expect(placed['callmates'], ['space-ada']);

    // 2. The real cluster debounce (1.5 s on the way in) builds the call.
    await tester.pump(const Duration(milliseconds: 1600));
    expect(app.inHuddle, isTrue);
    expect(app.callHandle, same(call));
    final dump = await drive('ext.gc.state.dump');
    expect(dump['boot'], 'harness');

    // The call screen, as the "In a call" banner's tap would open it.
    await tester.pumpWidget(MaterialApp(
      theme: buildGatherTheme(),
      home: CallScreen(state: app, buildTile: demoFootageTile, now: () => now),
    ));
    await tester.pump();
    await drive('ext.gc.call.spotlight.mode', '{"mode":"auto"}');

    // 3. Hold the floor on Ada — and only Ada — across the scenario's ticks.
    final spoke = await drive('ext.gc.harness.call.speak', '{"id":"ada"}');
    expect(spoke['heldSpeakers'], ['space-ada']);
    await tester.pump();

    // 4. After the dwell, the spotlight is on Ada.
    for (var t = 0; t < 4; t++) {
      now = now.add(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 600));
    }
    final spot = await drive('ext.gc.call.spotlight');
    expect(spot['view'], 'spotlight');
    expect(spot['target'], 'space-ada');
    expect(spot['promotions'], 1);

    s.driver.stop();
    await tester.pumpWidget(const SizedBox());
    app.dispose();
    await tester.pump(const Duration(seconds: 15));
  });
}

class _SilentNotifier extends Notifier {
  @override
  Future<void> init() async {}
}

class _HarnessCredentials extends GatherCredentialStore {
  @override
  Future<GatherCredentials> load() async => const GatherCredentials(refreshToken: 'sim-harness');
  @override
  Future<String?> loadSpaceId() async => 'sim-harness-space';
  @override
  Future<void> save(GatherCredentials credentials) async {}
  @override
  Future<void> saveSpaceId(String? spaceId) async {}
  @override
  Future<void> clear() async {}
}

class _EmptyBridge extends BridgeSettingsStore {
  @override
  Future<BridgeSettings> load() async => BridgeSettings.empty;
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
