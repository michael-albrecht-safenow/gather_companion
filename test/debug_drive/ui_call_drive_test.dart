/// `ext.gc.ui.openCall` / `closeCall`: the drive's way onto the call screen, so
/// `call.spotlight` has a screen to read without an agent tapping the banner by
/// coordinate. The handler tests pin the refusals against a stand-in door; the
/// widget tests pin that the door the real `HomeShell` lends is the banner's own
/// push — the real `CallScreen` opens, and closes back to the office.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gather_client/gather_client.dart';
import 'package:gather_companion/src/app_state.dart';
import 'package:gather_companion/src/call_screen_debug.dart';
import 'package:gather_companion/src/debug_drive/debug_drive.dart';
import 'package:gather_companion/src/debug_drive/install.dart';
import 'package:gather_companion/src/link_status.dart';
import 'package:gather_companion/src/media/media_log.dart';
import 'package:gather_companion/src/media/spotlight_controller.dart';
import 'package:gather_companion/theme/gather_theme.dart';
import 'package:gather_companion/ui/call_screen.dart';
import 'package:gather_companion/ui/home_shell.dart';
import 'package:gather_events/gather_events.dart';

import 'drive_test_support.dart';

void main() {
  tearDown(() {
    callScreenDebugActive = null;
    spotlightRegistry.debugReset();
    mediaLogDebugSink = null;
    debugResetDriveLog();
  });

  /// Connected, and — with [talkingWith] — in a conversation the way the roster
  /// says so, which is what puts the banner up.
  AppState connected({List<String> talkingWith = const []}) {
    final state = AppState()..debugApplyLink(const LinkStatus(LinkState.live));
    if (talkingWith.isNotEmpty) {
      state.debugApplyRoster(Roster(selfId: 'me', rows: [
        const RosterRow(id: 'me', name: 'Jonas', clusterId: 'c1'),
        for (final name in talkingWith) RosterRow(id: name, name: name, clusterId: 'c1'),
      ]));
    }
    state
      ..debugApplySnapshot(PresenceSnapshot(
        self: const SelfState(spaceId: 'space-1', spaceName: 'HQ'),
        players: const [],
        health: const CollectorHealth(logTail: true, cdp: true),
        at: DateTime(2026, 8, 4, 12, 30),
      ))
      ..debugApplyActivity(const []);
    return state;
  }

  DebugDrive install(AppState app) =>
      installDebugDrive(enabled: true, app: app, boot: 'harness', register: RecordingRegistrar().call)!;

  Future<Map<String, Object?>> call(DebugDrive drive, String method) async =>
      resultOf(await drive.invoke('ext.gc.$method', '{}'));

  group('handlers', () {
    var opens = 0;
    var closes = 0;
    setUp(() {
      opens = 0;
      closes = 0;
    });
    CallScreenDebug door() => CallScreenDebug(
          open: () => opens++,
          close: () {
            closes++;
            return true;
          },
        );

    test('without a mounted shell both are app_not_mounted', () async {
      final drive = install(connected(talkingWith: ['Ada']));
      expect(await call(drive, 'ui.openCall'), {'ok': false, 'reason': 'app_not_mounted', 'boot': 'harness'});
      expect(await call(drive, 'ui.closeCall'), {'ok': false, 'reason': 'app_not_mounted', 'boot': 'harness'});
    });

    test('with no call there is no banner to tap: no_call, nothing pushed', () async {
      callScreenDebugActive = door();
      final body = await call(install(connected()), 'ui.openCall');
      expect(body['ok'], isFalse);
      expect(body['reason'], 'no_call');
      expect(body['inCall'], isFalse);
      expect(opens, 0);
    });

    test('in a call it opens through the door and says pending', () async {
      callScreenDebugActive = door();
      final body = await call(install(connected(talkingWith: ['Ada'])), 'ui.openCall');
      expect(body['ok'], isTrue, reason: '$body');
      final data = (body['data']! as Map).cast<String, Object?>();
      expect(data['inCall'], isTrue);
      expect(data['pending'], isTrue);
      expect(data['screens'], 0, reason: 'the route lands on the next frame');
      expect(opens, 1);
    });

    test('closeCall with no call screen mounted is not_open, and pops nothing', () async {
      callScreenDebugActive = door();
      final body = await call(install(connected(talkingWith: ['Ada'])), 'ui.closeCall');
      expect(body['reason'], 'not_open');
      expect(closes, 0);
    });

    test('neither is outward', () async {
      final list = await call(install(connected()), 'drive.list');
      final actions = (list['data']! as Map)['actions']! as List;
      for (final name in ['ext.gc.ui.openCall', 'ext.gc.ui.closeCall']) {
        final entry = actions.cast<Map>().singleWhere((a) => a['name'] == name);
        expect(entry['outward'], isFalse, reason: name);
      }
    });
  });

  group('the real shell', () {
    Widget wrap(AppState state) => MaterialApp(
          theme: buildGatherTheme(),
          home: ListenableBuilder(
            listenable: state,
            builder: (context, _) => HomeShell(state: state, onUnpair: () {}),
          ),
        );

    testWidgets('openCall opens the real CallScreen, closeCall goes back', (tester) async {
      final state = connected(talkingWith: ['Ada']);
      final drive = install(state);
      await tester.pumpWidget(wrap(state));
      expect(callScreenDebugActive, isNotNull, reason: 'HomeShell lends the door on mount');
      expect(find.byType(CallScreen), findsNothing);

      final opened = await call(drive, 'ui.openCall');
      expect(opened['ok'], isTrue, reason: '$opened');
      await tester.pumpAndSettle();
      expect(find.byType(CallScreen), findsOneWidget);
      expect(spotlightRegistry.count, 1);

      final spotlight = await call(drive, 'call.spotlight');
      expect(spotlight['reason'], isNot('call_screen_closed'), reason: 'the gap this closes');

      expect((await call(drive, 'ui.openCall'))['reason'], 'already_open');
      await tester.pumpAndSettle();
      expect(find.byType(CallScreen), findsOneWidget, reason: 'not pushed twice');

      final closed = await call(drive, 'ui.closeCall');
      expect(closed['ok'], isTrue, reason: '$closed');
      await tester.pumpAndSettle();
      expect(find.byType(CallScreen), findsNothing);
      expect(find.byType(HomeShell), findsOneWidget, reason: 'back to the office, not past it');
      expect((await call(drive, 'ui.closeCall'))['reason'], 'not_open');
    });

    testWidgets('the door goes with the shell', (tester) async {
      final state = connected(talkingWith: ['Ada']);
      final drive = install(state);
      await tester.pumpWidget(wrap(state));
      expect(callScreenDebugActive, isNotNull);
      await tester.pumpWidget(const SizedBox());
      expect(callScreenDebugActive, isNull);
      expect((await call(drive, 'ui.openCall'))['reason'], 'app_not_mounted');
    });
  });
}
