/// `ext.gc.plans.state` and `ext.gc.gameboy.*` through the registry: the Plans
/// readout is the day sections the timeline draws (free days, clipped entries,
/// lanes), and the gameboy actions read and press the mounted shell's own menu —
/// refused with no shell, refused on a closed menu, and `menu.confirm` held by the
/// outward gate on a live boot outside the test space.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gather_companion/src/app_state.dart';
import 'package:gather_companion/src/calendar.dart';
import 'package:gather_companion/src/debug_drive/debug_drive.dart';
import 'package:gather_companion/src/debug_drive/install.dart';
import 'package:gather_companion/src/debug_drive/plans_drive.dart';
import 'package:gather_companion/src/gameboy_controls.dart';
import 'package:gather_companion/src/google_calendar.dart';
import 'package:gather_companion/src/media/media_log.dart';
import 'package:gather_companion/theme/gather_theme.dart';
import 'package:gather_companion/ui/gameboy_shell.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'drive_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() {
    gameboyDebugActive = null;
    mediaLogDebugSink = null;
    debugResetDriveLog();
  });

  DebugDrive install(AppState app, {String boot = 'harness'}) =>
      installDebugDrive(enabled: true, app: app, boot: boot, register: RecordingRegistrar().call)!;

  Future<Map<String, Object?>> call(DebugDrive drive, String method, [String args = '{}']) async =>
      resultOf(await drive.invoke('ext.gc.$method', args));

  Map<String, Object?> dataOf(Map<String, Object?> body) => (body['data']! as Map).cast<String, Object?>();

  group('plans.state', () {
    final now = DateTime(2025, 6, 17, 9, 0);

    test('nothing planned says empty, with no day sections and Google not offered', () {
      final body = plansReadout(AppState(), now: now, boot: 'harness');
      expect(body['empty'], isTrue);
      expect(body['days'], isEmpty);
      expect(body['googleAvailable'], isFalse);
      expect(body['showConnect'], isFalse);
      expect(body['screenless'], isTrue);
    });

    test('reads the days the timeline draws: busy, free, clipped, and the past list', () {
      final state = AppState()
        ..debugPlannedMeetings = [
          PlannedMeeting(
            id: 'm1',
            title: 'Standup',
            startsAt: DateTime(2025, 6, 17, 9, 0),
            endsAt: DateTime(2025, 6, 17, 9, 30),
            roomStableId: 's',
            roomName: 'Lounge',
          ),
          PlannedMeeting(
            id: 'late',
            title: 'Deploy',
            startsAt: DateTime(2025, 6, 17, 23, 0),
            endsAt: DateTime(2025, 6, 18, 1, 0),
          ),
          PlannedMeeting(
            id: 'old',
            title: 'Retro',
            startsAt: DateTime(2025, 6, 16, 15, 0),
            endsAt: DateTime(2025, 6, 16, 16, 0),
          ),
        ];
      final body = plansReadout(state, now: now, boot: 'live');
      expect(body['boot'], 'live');
      expect(body['counts'], {'plans': 3, 'googleEvents': 0, 'upcoming': 2, 'past': 1});

      final upcoming = (body['upcoming']! as List).cast<Map<String, Object?>>();
      expect(upcoming.map((e) => e['id']), ['m1', 'late']);
      expect(upcoming.first, containsPair('live', true));
      expect(upcoming.first, containsPair('place', 'Lounge'));
      expect(upcoming.first, containsPair('key', 0));

      final days = (body['days']! as List).cast<Map<String, Object?>>();
      expect(days.first['date'], '2025-06-17');
      expect(days[2]['free'], isTrue, reason: 'the 19th has nothing on it');
      final today = (days.first['bands']! as List).cast<Map<String, Object?>>();
      expect(today.map((b) => b['kind']), containsAll(['busy', 'free']));
      // The deploy crosses midnight: it is on the 18th too, clipped to its start.
      final tomorrowBusy =
          (days[1]['bands']! as List).cast<Map<String, Object?>>().firstWhere((b) => b['kind'] == 'busy');
      final item = (tomorrowBusy['items']! as List).cast<Map<String, Object?>>().single;
      expect(item['key'], 1);
      expect(item['start'], DateTime(2025, 6, 18).toIso8601String());

      final past = (body['past']! as List).cast<Map<String, Object?>>();
      expect(past.single['id'], 'old');
      expect(body['pastTruncated'], isFalse);
    });

    test('a day with only an all-day entry is not free: the banner is drawn, not "Free for the day"', () {
      final state = AppState()
        ..debugGoogleEvents = [
          GoogleEvent(
            id: 'ooo',
            title: 'Out of office',
            startsAt: DateTime(2025, 6, 18),
            endsAt: DateTime(2025, 6, 19),
            allDay: true,
          ),
        ];
      final body = plansReadout(state, now: now, boot: 'harness');
      final days = (body['days']! as List).cast<Map<String, Object?>>();
      final ooo = days.singleWhere((d) => d['date'] == '2025-06-18');
      expect(ooo['allDay'], [0]);
      expect(ooo['bands'], isEmpty);
      expect(ooo['noTimed'], isTrue);
      expect(ooo['free'], isFalse, reason: 'DayTimeline shows the OOO banner, not "Free for the day"');
    });

    test('through the registry, with pastMax bounding the past list', () async {
      final state = AppState()
        ..debugPlannedMeetings = [
          for (var i = 1; i <= 3; i++)
            PlannedMeeting(
              id: 'p$i',
              title: 'Past $i',
              startsAt: DateTime(2020, 1, i, 10),
              endsAt: DateTime(2020, 1, i, 11),
            ),
        ];
      final drive = install(state);
      final data = dataOf(await call(drive, 'plans.state', '{"pastMax":1}'));
      expect((data['past']! as List).single, containsPair('id', 'p3'));
      expect(data['pastTruncated'], isTrue);
      expect(errorOf(await drive.invoke('ext.gc.plans.state', '{"pastMax":-1}')).code, isNonZero);
    });
  });

  group('gameboy', () {
    test('no shell: mapping says so, every menu action is refused', () async {
      final drive = install(AppState());
      final data = dataOf(await call(drive, 'gameboy.mapping'));
      expect(data['shellMounted'], isFalse);
      expect(data.containsKey('buttons'), isFalse, reason: 'no keys, no meanings');
      expect(data['wave'], {'ready': false, 'target': null});
      for (final (action, args) in [
        ('menu.toggle', '{}'),
        ('menu.move', '{"direction":"down"}'),
        ('menu.confirm', '{}'),
      ]) {
        final body = await call(drive, 'gameboy.$action', args);
        expect(body['reason'], 'shell_not_mounted', reason: action);
      }
    });

    Future<({AppState state, List<String> opened})> mountShell(WidgetTester tester) async {
      final state = AppState();
      final opened = <String>[];
      await tester.pumpWidget(MaterialApp(
        theme: buildGatherTheme(),
        home: Scaffold(
          body: GameboyShell(
            state: state,
            onOpenSettings: () => opened.add('settings'),
            onOpenActivity: () => opened.add('activity'),
            onOpenPlans: () => opened.add('plans'),
            onOpenDial: () => opened.add('dial'),
            child: const SizedBox.expand(),
          ),
        ),
      ));
      await tester.pump();
      return (state: state, opened: opened);
    }

    testWidgets('mapping reads the shell the keys are wired from, and a toggle opens the LCD menu',
        (tester) async {
      final (:state, :opened) = await mountShell(tester);
      final drive = install(state);

      var data = dataOf(await call(drive, 'gameboy.mapping'));
      expect(data['shellMounted'], isTrue);
      expect(data['buttons'], containsPair('a', 'boost'));
      expect(data['buttons'], containsPair('b', 'toggleMic'));
      expect((data['menu']! as Map)['open'], isFalse);

      expect((await call(drive, 'gameboy.menu.move', '{"direction":"down"}'))['reason'], 'menu_closed');

      data = dataOf(await call(drive, 'gameboy.menu.toggle'));
      await tester.pumpAndSettle();
      expect((data['menu']! as Map)['open'], isTrue);
      expect(data['buttons'], containsPair('a', 'confirm'));
      expect(data['buttons'], containsPair('start', 'closeMenu'));
      expect(find.text('Activity'), findsOneWidget, reason: 'the drive opened the real menu');

      // Down three rows to Dial, then A: the shell's own dispatch runs.
      for (var i = 0; i < 3; i++) {
        await call(drive, 'gameboy.menu.move', '{"direction":"Down"}');
      }
      await tester.pumpAndSettle();
      final confirmed = dataOf(await call(drive, 'gameboy.menu.confirm'));
      await tester.pumpAndSettle();
      expect(confirmed['chose'], {'kind': 'tab', 'tab': 'dial'});
      expect(opened, ['dial']);
      expect(find.text('Activity'), findsNothing, reason: 'the menu closed behind the choice');
      expect(tester.takeException(), isNull);
    });

    testWidgets('a tap on the real Select key is what the drive reads back', (tester) async {
      final (:state, opened: _) = await mountShell(tester);
      final drive = install(state);
      await tester.tap(find.text('SELECT'));
      await tester.pumpAndSettle();
      final data = dataOf(await call(drive, 'gameboy.mapping'));
      expect((data['menu']! as Map)['open'], isTrue);
      expect((data['menu']! as Map)['row'], 'status');
    });

    testWidgets('menu.confirm is outward: held on a live boot outside the test space', (tester) async {
      final (:state, :opened) = await mountShell(tester);
      final drive = install(state, boot: 'live');
      await call(drive, 'gameboy.menu.toggle');
      await tester.pumpAndSettle();
      final body = await call(drive, 'gameboy.menu.confirm');
      expect(body['ok'], isFalse);
      expect(body['reason'], 'outward_outside_test_space');
      expect(gameboyDebugActive!.menu.isOpen, isTrue, reason: 'nothing was pressed');
      expect(opened, isEmpty);
    });

    testWidgets('a shell kept alive behind another tab is not on screen', (tester) async {
      // HomeShell's IndexedStack mutes hidden tabs with TickerMode but never
      // disposes them, so the hook stays registered while Settings is showing.
      final state = AppState();
      await tester.pumpWidget(MaterialApp(
        theme: buildGatherTheme(),
        home: Scaffold(
          body: TickerMode(
            enabled: false,
            child: GameboyShell(
              state: state,
              onOpenSettings: () {},
              onOpenActivity: () {},
              onOpenPlans: () {},
              onOpenDial: () {},
              child: const SizedBox.expand(),
            ),
          ),
        ),
      ));
      await tester.pump();
      expect(gameboyDebugActive, isNotNull, reason: 'still mounted');
      final drive = install(state);
      final data = dataOf(await call(drive, 'gameboy.mapping'));
      expect(data['shellMounted'], isFalse);
      expect(data.containsKey('menu'), isFalse);
      final body = await call(drive, 'gameboy.menu.toggle');
      expect(body['reason'], 'shell_not_mounted');
      expect(gameboyDebugActive!.menu.isOpen, isFalse, reason: 'nothing was pressed');
    });

    testWidgets('the hook clears when the shell goes', (tester) async {
      await mountShell(tester);
      expect(gameboyDebugActive, isNotNull);
      await tester.pumpWidget(const SizedBox());
      expect(gameboyDebugActive, isNull);
    });
  });
}
