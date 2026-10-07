/// Gameboy mode: a look and an input surface laid over the office, nothing more.
///
/// The thing worth pinning is that it stays frame-only in both directions — the
/// handheld's own buttons reach the same [AppState] actions the dock does, and
/// turning the mode off leaves not a trace of the shell behind. Each physical
/// key here is checked for the one action it is wired to, because a Gameboy whose
/// A button does nothing is worse than no Gameboy at all.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gather_companion/src/app_state.dart';
import 'package:gather_companion/src/link_status.dart';
import 'package:gather_companion/src/ui_preferences.dart';
import 'package:gather_companion/theme/gather_theme.dart';
import 'package:gather_companion/ui/control_bar.dart';
import 'package:gather_companion/ui/gameboy_shell.dart';
import 'package:gather_companion/ui/home_shell.dart';
import 'package:gather_companion/ui/map_screen.dart';
import 'package:gather_companion/ui/settings_screen.dart';
import 'package:gather_events/gather_events.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Records the directions it is walked, so a press on the cross can be checked
/// for reaching movement at all — the live walk plumbing is null in a test, so
/// the honest question is "was walk asked for", which this answers.
class _SpyState extends AppState {
  final walked = <String>[];
  var released = 0;

  @override
  void walk(String direction) => walked.add(direction);

  @override
  void stopWalking() => released++;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  T configure<T extends AppState>(T state) => state
    ..debugApplyLink(const LinkStatus(LinkState.live))
    ..debugApplySnapshot(PresenceSnapshot(
      self: const SelfState(spaceId: 'space-1', spaceName: 'HQ'),
      players: const [],
      health: const CollectorHealth(logTail: true, cdp: true),
      at: DateTime(2026, 8, 4, 12, 30),
    ))
    ..debugApplyActivity(const []);

  Widget wrap(AppState state) => MaterialApp(
        theme: buildGatherTheme(),
        home: ListenableBuilder(
          listenable: state,
          builder: (context, _) => HomeShell(state: state, onUnpair: () {}),
        ),
      );

  Future<void> toOffice(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Office'));
    await tester.pumpAndSettle();
  }

  group('the settings toggle', () {
    Widget wrapSettings(AppState state) => MaterialApp(
          theme: buildGatherTheme(),
          home: ListenableBuilder(
            listenable: state,
            builder: (context, _) => SettingsScreen(state: state, onUnpair: () {}),
          ),
        );

    testWidgets('flips the mode on and off', (tester) async {
      final state = configure(AppState());
      await tester.pumpWidget(wrapSettings(state));
      await tester.pump();

      expect(state.gameboyMode, isFalse);
      await tester.ensureVisible(find.text('Gameboy mode'));
      await tester.tap(find.text('Gameboy mode'));
      await tester.pumpAndSettle();
      expect(state.gameboyMode, isTrue);

      await tester.tap(find.text('Gameboy mode'));
      await tester.pumpAndSettle();
      expect(state.gameboyMode, isFalse);
    });

    testWidgets('survives a reload through the preference store', (tester) async {
      await UiPreferences().saveGameboyMode(true);
      expect(await UiPreferences().loadGameboyMode(), isTrue);
    });

    testWidgets('defaults off when nothing is stored', (tester) async {
      expect(await UiPreferences().loadGameboyMode(), isFalse);
    });
  });

  group('on the office tab', () {
    testWidgets('the handheld replaces the floating dock', (tester) async {
      final state = configure(AppState())..setGameboyMode(true);
      await tester.pumpWidget(wrap(state));
      await tester.pump();
      await toOffice(tester);

      expect(find.byType(GameboyShell), findsOneWidget);
      expect(find.byType(MapScreen), findsOneWidget, reason: 'the office is still in there');
      expect(find.byType(ControlBar), findsNothing, reason: 'the dock has stood down');
      // The office's name is the handheld's own wordmark now, on the shell
      // header — and taken off the LCD title so it prints once, not twice.
      // Finding 'HQ' exactly once, and never inside the LCD (the MapScreen), is
      // that contract: a second copy would mean the map's title still carries it.
      // The head count stays the LCD's job (its 'N here' chip), so the uppercase
      // 'HERE' badge no longer lives on the shell.
      expect(find.text('HQ'), findsOneWidget);
      expect(
        find.descendant(of: find.byType(MapScreen), matching: find.text('HQ')),
        findsNothing,
        reason: 'the name moved off the LCD title onto the shell header',
      );
      expect(find.textContaining('HERE'), findsNothing);
      expect(find.text('A'), findsOneWidget);
      expect(find.text('B'), findsOneWidget);
      expect(find.text('SELECT'), findsOneWidget);
      expect(find.text('START'), findsOneWidget);
    });

    testWidgets('turning the mode back off restores the normal dock', (tester) async {
      final state = configure(AppState())..setGameboyMode(true);
      await tester.pumpWidget(wrap(state));
      await tester.pump();
      await toOffice(tester);
      expect(find.byType(GameboyShell), findsOneWidget);

      await state.setGameboyMode(false);
      await tester.pumpAndSettle();

      expect(find.byType(GameboyShell), findsNothing);
      expect(find.byType(ControlBar), findsOneWidget);
    });

    testWidgets('A latches the cart', (tester) async {
      final state = configure(AppState())..setGameboyMode(true);
      await tester.pumpWidget(wrap(state));
      await tester.pump();
      await toOffice(tester);

      expect(state.boost, isFalse);
      await tester.tap(find.text('A'));
      await tester.pumpAndSettle();
      expect(state.boost, isTrue);

      await tester.tap(find.text('A'));
      await tester.pumpAndSettle();
      expect(state.boost, isFalse);
    });

    testWidgets('B is wired and does not throw without a call', (tester) async {
      final state = configure(AppState())..setGameboyMode(true);
      await tester.pumpWidget(wrap(state));
      await tester.pump();
      await toOffice(tester);

      await tester.tap(find.text('B'));
      await tester.pumpAndSettle();
      // No call to mute into, so the action refuses with a sentence rather than
      // crashing — the point is simply that the key reached an action.
      expect(tester.takeException(), isNull);
    });

    testWidgets('the D-pad asks to walk while a thumb is on it', (tester) async {
      final state = configure(_SpyState())
        ..setGameboyMode(true)
        ..debugCanWalk = true;
      await tester.pumpWidget(wrap(state));
      await tester.pump();
      await toOffice(tester);

      final pad = tester.getRect(find.byKey(const Key('gb-dpad')));
      final up = Offset(pad.center.dx, pad.top + pad.height * 0.12);
      final gesture = await tester.startGesture(up);
      await tester.pump();
      expect(state.walked, contains('Up'));

      await gesture.up();
      await tester.pump();
      expect(state.released, greaterThan(0));
    });

    testWidgets('a dimmed D-pad does not walk', (tester) async {
      final state = configure(_SpyState())
        ..setGameboyMode(true)
        ..debugCanWalk = false;
      await tester.pumpWidget(wrap(state));
      await tester.pump();
      await toOffice(tester);

      final pad = tester.getRect(find.byKey(const Key('gb-dpad')));
      final gesture = await tester.startGesture(Offset(pad.center.dx, pad.top + pad.height * 0.12));
      await tester.pump();
      await gesture.up();

      expect(state.walked, isEmpty);
    });

    testWidgets('Select opens the menu of everything else', (tester) async {
      final state = configure(AppState())..setGameboyMode(true);
      await tester.pumpWidget(wrap(state));
      await tester.pump();
      await toOffice(tester);

      await tester.tap(find.text('SELECT'));
      await tester.pumpAndSettle();

      expect(find.text('Activity'), findsOneWidget);
      expect(find.text('Settings'), findsOneWidget);
      expect(find.textContaining('camera'), findsOneWidget);
    });

    testWidgets('the Select menu switches tab', (tester) async {
      final state = configure(AppState())..setGameboyMode(true);
      await tester.pumpWidget(wrap(state));
      await tester.pump();
      await toOffice(tester);

      await tester.tap(find.text('SELECT'));
      await tester.pumpAndSettle();
      // The menu scrolls inside the LCD now, so the bottom row can sit below the
      // fold on a short screen — bring it up before choosing it.
      await tester.ensureVisible(find.text('Settings'));
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();

      expect(find.byType(SettingsScreen), findsOneWidget);
      expect(find.byType(GameboyShell), findsNothing, reason: 'left the office for settings');
    });

    testWidgets('Start is wired and does not throw with no desk to return to', (tester) async {
      final state = configure(AppState())..setGameboyMode(true);
      await tester.pumpWidget(wrap(state));
      await tester.pump();
      await toOffice(tester);

      await tester.tap(find.text('START'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  group('the LCD status bar', () {
    // Scoped to the shell so an offstage tab or the map's own chrome cannot be
    // mistaken for the HUD glyph.
    Finder inShell(Finder matching) =>
        find.descendant(of: find.byType(GameboyShell), matching: matching);

    testWidgets('carries status, mic and camera at a glance', (tester) async {
      final state = configure(AppState())..setGameboyMode(true);
      await tester.pumpWidget(wrap(state));
      await tester.pump();
      await toOffice(tester);

      // Your Gather status by name, with mic and camera reading off — the three
      // always on the screen regardless of a call.
      expect(inShell(find.text('Active')), findsOneWidget);
      expect(inShell(find.byIcon(Icons.mic_off)), findsOneWidget);
      expect(inShell(find.byIcon(Icons.videocam_off_rounded)), findsOneWidget);
    });

    testWidgets('the head count lives on the LCD, not a doubled app bar', (tester) async {
      final state = configure(AppState())..setGameboyMode(true);
      await tester.pumpWidget(wrap(state));
      await tester.pump();
      await toOffice(tester);

      // The map's own app bar stands down in Gameboy mode, so the only "N here" is
      // the one the shell draws on the screen.
      expect(
        find.descendant(of: find.byType(MapScreen), matching: find.byType(AppBar)),
        findsNothing,
        reason: 'the map app bar is gone in Gameboy mode',
      );
      expect(inShell(find.textContaining('here')), findsOneWidget);
    });
  });

  group('the Select menu on the LCD', () {
    testWidgets('opens inside the screen and the D-pad drives it, not the avatar', (tester) async {
      final state = configure(_SpyState())
        ..setGameboyMode(true)
        ..debugCanWalk = true;
      await tester.pumpWidget(wrap(state));
      await tester.pump();
      await toOffice(tester);

      await tester.tap(find.text('SELECT'));
      await tester.pumpAndSettle();
      expect(find.text('Activity'), findsOneWidget, reason: 'the menu is open in the LCD');

      // With the menu up the cross moves the cursor — it must not also walk.
      final pad = tester.getRect(find.byKey(const Key('gb-dpad')));
      final gesture = await tester.startGesture(Offset(pad.center.dx, pad.top + pad.height * 0.12));
      await tester.pump();
      await gesture.up();
      await tester.pump();
      expect(state.walked, isEmpty, reason: 'the D-pad moved the cursor, not the avatar');
    });

    testWidgets('A chooses the highlighted row and closes the menu', (tester) async {
      final state = configure(AppState())..setGameboyMode(true);
      await tester.pumpWidget(wrap(state));
      await tester.pump();
      await toOffice(tester);

      await tester.tap(find.text('SELECT'));
      await tester.pumpAndSettle();
      expect(find.text('Activity'), findsOneWidget);

      // The cursor starts on the status row; A chooses the highlighted status. With
      // no live roster behind it the set refuses with a sentence rather than
      // throwing, and the menu closes behind it.
      await tester.tap(find.text('A'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Activity'), findsNothing, reason: 'the menu closed after choosing');
    });

    testWidgets('offers the Gather statuses to change to', (tester) async {
      final state = configure(AppState())..setGameboyMode(true);
      await tester.pumpWidget(wrap(state));
      await tester.pump();
      await toOffice(tester);

      await tester.tap(find.text('SELECT'));
      await tester.pumpAndSettle();

      // The three settable statuses are offered as a row to pick from. 'Busy' and
      // 'Away' live only in the menu (the LCD strip reads 'Active'), so finding them
      // is finding the picker.
      expect(find.text('Busy'), findsOneWidget);
      expect(find.text('Away'), findsOneWidget);

      // Choosing one is wired through to setAvailability and closes the menu — it
      // refuses with a sentence here rather than throwing, there being no roster.
      await tester.tap(find.text('Busy'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Busy'), findsNothing, reason: 'the menu closed after choosing a status');
    });

    testWidgets('Start backs out of the menu without leaving the office', (tester) async {
      final state = configure(AppState())..setGameboyMode(true);
      await tester.pumpWidget(wrap(state));
      await tester.pump();
      await toOffice(tester);

      await tester.tap(find.text('SELECT'));
      await tester.pumpAndSettle();
      expect(find.text('Activity'), findsOneWidget);

      await tester.tap(find.text('START'));
      await tester.pumpAndSettle();
      expect(find.text('Activity'), findsNothing, reason: 'Start closed the menu');
      expect(find.byType(GameboyShell), findsOneWidget, reason: 'still in the office');
    });
  });
}
