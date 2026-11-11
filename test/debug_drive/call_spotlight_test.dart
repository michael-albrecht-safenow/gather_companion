/// `ext.gc.call.spotlight*` end to end: a real [CallScreen] over a
/// [ScriptedCall], fed by the harness's own [CallScenarioDriver] frames, and the
/// drive asked — through the registry — what the screen is enlarging and why.
///
/// The screen's clock is injected and advanced alongside `tester.pump`, so the
/// controller's real 1.5 s dwell timer fires a real promotion; the C-cases
/// themselves are pinned against the controller in `spotlight_controller_test.dart`.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gather_companion/harness/call_scenarios.dart';
import 'package:gather_companion/harness/demo_footage.dart';
import 'package:gather_companion/harness/harness_data.dart';
import 'package:gather_companion/harness/scripted_call.dart';
import 'package:gather_companion/src/app_state.dart';
import 'package:gather_companion/src/debug_drive/debug_drive.dart';
import 'package:gather_companion/src/debug_drive/install.dart';
import 'package:gather_companion/src/media/media_log.dart';
import 'package:gather_companion/src/media/spotlight_controller.dart';
import 'package:gather_companion/theme/gather_theme.dart';
import 'package:gather_companion/ui/call_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'drive_test_support.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    spotlightRegistry.debugReset();
  });
  tearDown(() {
    spotlightRegistry.debugReset();
    mediaLogDebugSink = null;
  });

  DebugDrive install(AppState app, {String boot = 'harness'}) =>
      installDebugDrive(enabled: true, app: app, boot: boot, register: RecordingRegistrar().call)!;

  Future<Map<String, Object?>> ok(DebugDrive drive, String method, [String? args]) async {
    final body = resultOf(await drive.invoke(method, args));
    expect(body['ok'], isTrue, reason: '$body');
    return (body['data']! as Map).cast<String, Object?>();
  }

  /// A call screen over a scripted [scenario], its clock at [clock].
  Future<({DebugDrive drive, CallScenarioDriver driver, AppState app})> show(
    WidgetTester tester,
    Scenario scenario,
    DateTime Function() clock,
  ) async {
    final app = AppState();
    addTearDown(app.dispose);
    final call = ScriptedCall();
    app.debugAttachCall(call);
    final drive = install(app);
    final driver = CallScenarioDriver(state: app, call: call, scenario: scenario, participants: 3)
      ..applyAt(Duration.zero);
    await tester.pumpWidget(MaterialApp(
      theme: buildGatherTheme(),
      home: CallScreen(state: app, buildTile: demoFootageTile, now: clock),
    ));
    await tester.pump();
    return (drive: drive, driver: driver, app: app);
  }

  testWidgets('every action is listed, none outward', (tester) async {
    final drive = install(AppState());
    final listed = {for (final a in drive.actions) a.name: a.outward};
    for (final name in ['spotlight', 'spotlight.mode', 'spotlight.pick', 'spotlight.overview']) {
      expect(listed['ext.gc.call.$name'], isFalse, reason: name);
    }
  });

  testWidgets('no call screen: every action refuses call_screen_closed, with boot', (tester) async {
    final drive = install(AppState(), boot: 'live');
    for (final (method, args) in [
      ('ext.gc.call.spotlight', null),
      ('ext.gc.call.spotlight.mode', '{"mode":"auto"}'),
      ('ext.gc.call.spotlight.pick', '{"id":"x"}'),
      ('ext.gc.call.spotlight.overview', null),
    ]) {
      expect(resultOf(await drive.invoke(method, args)), {'ok': false, 'reason': 'call_screen_closed', 'boot': 'live'},
          reason: method);
    }
  });

  testWidgets('bad args are invalidParams, not failures', (tester) async {
    final drive = install(AppState());
    expect(errorOf(await drive.invoke('ext.gc.call.spotlight.mode', '{"mode":"sideways"}')).code, -32602);
    expect(errorOf(await drive.invoke('ext.gc.call.spotlight.mode')).code, -32602);
    expect(errorOf(await drive.invoke('ext.gc.call.spotlight.pick', '{}')).code, -32602);
    expect(errorOf(await drive.invoke('ext.gc.call.spotlight', '{"historyMax":-1}')).code, -32602);
  });

  testWidgets('readout of a resting screen: manual, grid, nobody counting', (tester) async {
    final now = DateTime.utc(2026, 11, 11, 9);
    final (:drive, driver: _, app: _) = await show(tester, Scenario.group, () => now);
    final s = await ok(drive, 'ext.gc.call.spotlight');
    expect(s['boot'], 'harness');
    expect(s['inCall'], isTrue);
    expect(s['screens'], 1);
    expect(s['mode'], 'manual');
    expect(s['view'], 'grid');
    expect(s['target'], isNull);
    expect(s['since'], isA<String>());
    expect(s['speaking'], isEmpty);
    expect(s['tiles'], hasLength(4), reason: 'you and three');
    expect(s['candidate'], isNull);
    expect(s['timer'], isNull);
    expect(s['dwellMs'], 1500);
    expect(s['lingerMs'], 5000);
    expect(s['transitions'], isEmpty);
    await tester.pump(const Duration(seconds: 2)); // flush the cluster debounce
  });

  testWidgets('mode auto → the dwell timer promotes, and the screen draws it big', (tester) async {
    var now = DateTime.utc(2026, 11, 11, 9);
    final (:drive, :driver, app: _) = await show(tester, Scenario.roundRobin, () => now);

    var s = await ok(drive, 'ext.gc.call.spotlight.mode', '{"mode":"auto"}');
    await tester.pump();
    expect(s['mode'], 'auto');
    expect(s['view'], 'grid');
    final first = kCast[0].name;
    final candidate = (s['candidate']! as Map).cast<String, Object?>();
    expect(candidate['promoteInMs'], 1500);
    expect(s['timer'], {'dueInMs': 1500});
    expect(find.text('Everyone'), findsNothing);

    now = now.add(const Duration(milliseconds: 1500));
    await tester.pump(const Duration(milliseconds: 1500));
    s = await ok(drive, 'ext.gc.call.spotlight');
    expect(s['view'], 'spotlight');
    expect(s['target'], isNotNull);
    expect(s['promotions'], 1);
    final t = (s['transitions']! as List).cast<Map<String, Object?>>().single;
    expect(t['cause'], 'promoted');
    expect(t['from'], isNull);
    expect(t['to'], s['target']);
    expect(s['sinceMs'], 0);
    // And the widget agrees: the spotlight layout is up on that face.
    expect(find.text('Everyone'), findsOneWidget);
    expect(find.text(first), findsNWidgets(2), reason: 'big and in the strip');
    driver.stop();
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('churn on the screen: tiles track joins and leaves, a leaving holder drops the big view', (tester) async {
    final t0 = DateTime.utc(2026, 11, 11, 9);
    var now = t0;
    final (:drive, :driver, app: _) = await show(tester, Scenario.churn, () => now);
    await ok(drive, 'ext.gc.call.spotlight.mode', '{"mode":"auto"}');
    await tester.pump();

    const period = Duration(milliseconds: 250);
    final counts = <int>{};
    for (var t = period; t <= const Duration(seconds: 13); t += period) {
      now = t0.add(t);
      await tester.pump(period);
      driver.applyAt(t);
      await tester.pump();
      final frame = scenarioFrame(Scenario.churn, t, 3);
      final s = await ok(drive, 'ext.gc.call.spotlight');
      // The screen's own tile list: yourself plus whoever the frame seats.
      expect((s['tiles']! as List), hasLength(frame.count + 1), reason: 'at $t');
      counts.add(frame.count);
      if (t == const Duration(seconds: 12)) {
        // acc1 held the view from 11.5 s and leaves at 12 s: back to the grid at once.
        final last = (s['transitions']! as List).cast<Map<String, Object?>>().last;
        expect(last['cause'], 'room');
        expect(last['from'], kCast[1].spaceId, reason: 'tiles are keyed by the roster row');
        expect(last['to'], isNull);
        expect(s['view'], 'grid');
        expect(find.text('Everyone'), findsNothing, reason: 'the widget drew the grid too');
      }
    }
    expect(counts, containsAll([1, 3]), reason: 'the run both emptied and refilled the room');
    driver.stop();
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('pick enlarges a face (and leaves auto); overview returns; self in auto refused', (tester) async {
    final now = DateTime.utc(2026, 11, 11, 9);
    final (:drive, driver: _, app: _) = await show(tester, Scenario.group, () => now);
    final tiles = ((await ok(drive, 'ext.gc.call.spotlight'))['tiles']! as List).cast<String>();
    final selfId = (await ok(drive, 'ext.gc.call.spotlight'))['selfId']! as String;
    final other = tiles.firstWhere((id) => id != selfId);

    expect(resultOf(await drive.invoke('ext.gc.call.spotlight.pick', '{"id":"nobody"}')),
        {'ok': false, 'reason': 'no_such_tile', 'id': 'nobody', 'tiles': tiles});

    await ok(drive, 'ext.gc.call.spotlight.mode', '{"mode":"auto"}');
    expect(resultOf(await drive.invoke('ext.gc.call.spotlight.pick', '{"id":"$selfId"}')),
        {'ok': false, 'reason': 'self_in_auto', 'id': selfId, 'mode': 'auto'});

    var s = await ok(drive, 'ext.gc.call.spotlight.pick', '{"id":"$other"}');
    await tester.pump();
    expect(s['mode'], 'manual', reason: 'a tap in auto leaves auto');
    expect(s['target'], other);
    expect(find.text('Everyone'), findsOneWidget);

    s = await ok(drive, 'ext.gc.call.spotlight.overview');
    await tester.pump();
    expect(s['view'], 'grid');
    expect(find.text('Everyone'), findsNothing);
    expect([for (final t in (s['transitions']! as List).cast<Map<String, Object?>>()) t['cause']], ['tap', 'overview']);
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('the controller leaves the registry with the screen', (tester) async {
    final (:drive, driver: _, app: _) = await show(tester, Scenario.group, DateTime.now);
    expect(spotlightRegistry.count, 1);
    await tester.pumpWidget(const SizedBox());
    expect(spotlightRegistry.count, 0);
    expect((resultOf(await drive.invoke('ext.gc.call.spotlight')))['reason'], 'call_screen_closed');
    await tester.pump(const Duration(seconds: 2));
  });
}
