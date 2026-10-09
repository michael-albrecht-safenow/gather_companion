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
import 'package:gather_client/gather_client.dart';
import 'package:gather_companion/harness/fake_collector.dart';
import 'package:gather_companion/src/app_state.dart';
import 'package:gather_companion/src/link_status.dart';
import 'package:gather_companion/src/media/call.dart';
import 'package:gather_companion/src/media/media_engine.dart';
import 'package:gather_companion/src/ui_preferences.dart';
import 'package:gather_companion/theme/gather_theme.dart';
import 'package:gather_companion/ui/call_screen.dart';
import 'package:gather_companion/ui/control_bar.dart';
import 'package:gather_companion/ui/dial_screen.dart';
import 'package:gather_companion/ui/gameboy_shell.dart';
import 'package:gather_companion/ui/gameboy_theme.dart';
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

  // Gameboy mode opens on the office: the handheld wraps it, so there is no
  // floating Office dock to tap — the shell is already here. Just settle and
  // confirm the office is on screen before the test acts on it.
  Future<void> toOffice(WidgetTester tester) async {
    await tester.pumpAndSettle();
    expect(find.byType(GameboyShell), findsOneWidget,
        reason: 'Gameboy mode opens on the office');
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

  // The sound-effects switch gates every blip, so — like Gameboy mode — a silent
  // restore or a dropped default must not quietly turn sounds back on. Pinned at
  // the same three seams the mode is: the UI flip, the persistence round-trip, and
  // the stored-value default, plus the off-state surviving a reboot.
  group('the sound-effects toggle', () {
    Widget wrapSettings(AppState state) => MaterialApp(
          theme: buildGatherTheme(),
          home: ListenableBuilder(
            listenable: state,
            builder: (context, _) => SettingsScreen(state: state, onUnpair: () {}),
          ),
        );

    testWidgets('flips the setting on and off', (tester) async {
      final state = configure(AppState());
      await tester.pumpWidget(wrapSettings(state));
      await tester.pump();

      expect(state.soundEffects, isTrue, reason: 'on by default');
      await tester.ensureVisible(find.text('Sound effects'));
      await tester.tap(find.text('Sound effects'));
      await tester.pumpAndSettle();
      expect(state.soundEffects, isFalse);

      await tester.tap(find.text('Sound effects'));
      await tester.pumpAndSettle();
      expect(state.soundEffects, isTrue);
    });

    testWidgets('survives a reload through the preference store', (tester) async {
      await UiPreferences().saveSoundEffects(false);
      expect(await UiPreferences().loadSoundEffects(), isFalse);
    });

    testWidgets('defaults on when nothing is stored', (tester) async {
      expect(await UiPreferences().loadSoundEffects(), isTrue);
    });

    testWidgets('an off setting is what a reboot reads back', (tester) async {
      // Flip it off through AppState, then read the store the way boot() does
      // (`loadSoundEffects`): it must come back off, so nothing it gates can
      // silently re-sound on the next launch.
      await configure(AppState()).setSoundEffects(false);
      expect(await UiPreferences().loadSoundEffects(), isFalse,
          reason: 'boot() reads this value, so the off state survives a relaunch');
    });
  });

  // The hardware theme is a pure look choice, so it is pinned at the same seams as
  // the mode and the sound switch: the persistence round-trip, the stored-value
  // default, the boot read-back, and the UI that swaps the shell's skin — plus the
  // one rule the picker adds, that it is offered only while the handheld is on.
  group('the hardware theme', () {
    Widget wrapSettings(AppState state) => MaterialApp(
          theme: buildGatherTheme(),
          home: ListenableBuilder(
            listenable: state,
            builder: (context, _) => SettingsScreen(state: state, onUnpair: () {}),
          ),
        );

    testWidgets('survives a reload through the preference store', (tester) async {
      await UiPreferences().saveGameboyThemeId('safenow');
      expect(await UiPreferences().loadGameboyThemeId(), 'safenow');
    });

    testWidgets('defaults to purple when nothing is stored', (tester) async {
      expect(await UiPreferences().loadGameboyThemeId(), 'purple');
      expect(GameboyThemeId.fromId(null), GameboyThemeId.purple);
    });

    testWidgets('the picked theme is what a reboot reads back', (tester) async {
      final state = configure(AppState());
      expect(state.gameboyTheme, GameboyThemeId.purple, reason: 'purple by default');

      await state.setGameboyTheme(GameboyThemeId.safeNow);
      expect(state.gameboyTheme, GameboyThemeId.safeNow);
      expect(await UiPreferences().loadGameboyThemeId(), 'safenow',
          reason: 'boot() reads this value, so the pick survives a relaunch');
    });

    testWidgets('the picker is offered only while the handheld is on', (tester) async {
      final state = configure(AppState());
      await tester.pumpWidget(wrapSettings(state));
      await tester.pump();

      // Off: no theme row at all — nothing to skin when the office wears its normal
      // interface.
      expect(find.text('Theme'), findsNothing);

      await tester.ensureVisible(find.text('Gameboy mode'));
      await tester.tap(find.text('Gameboy mode'));
      await tester.pumpAndSettle();

      expect(find.text('Theme'), findsOneWidget, reason: 'the picker appears with the mode');
      expect(find.text('The handheld in Purple.'), findsOneWidget);
    });

    testWidgets('picking SafeNow prints its brand below the LCD; purple prints none', (tester) async {
      final state = configure(AppState())..setGameboyMode(true);
      await tester.pumpWidget(wrap(state));
      await tester.pumpAndSettle();

      // Purple ships a bare band — no brandmark printed on the plastic.
      expect(find.byKey(kSafeNowBrandmarkKey), findsNothing);

      await state.setGameboyTheme(GameboyThemeId.safeNow);
      await tester.pumpAndSettle();

      // The SafeNow mark (the pixel-art logo image) is now printed in the band.
      expect(
        find.descendant(
          of: find.byType(GameboyShell),
          matching: find.byKey(kSafeNowBrandmarkKey),
        ),
        findsOneWidget,
        reason: 'the brand is baked into the SafeNow theme, below the screen',
      );
    });

    testWidgets('the body repaints in the theme colour', (tester) async {
      final state = configure(AppState())..setGameboyMode(true);
      await tester.pumpWidget(wrap(state));
      await tester.pumpAndSettle();

      // The root body gradient reads the active hardware ramp; swapping the theme
      // must change the colour it paints. Probe the scope the shell provides.
      GbHardware hardwareInShell() =>
          tester.widget<GameboyThemeScope>(find.byType(GameboyThemeScope)).hardware;

      expect(hardwareInShell().hw700, kPurpleHardware.hw700);

      await state.setGameboyTheme(GameboyThemeId.safeNow);
      await tester.pumpAndSettle();

      expect(hardwareInShell().hw700, kSafeNowHardware.hw700,
          reason: 'the SafeNow body is the brand blue, not purple');
      expect(kSafeNowHardware.hw700, const Color(0xFF0022FF));
    });
  });

  group('the startup tab', () {
    testWidgets('Gameboy mode opens on the office', (tester) async {
      final state = configure(AppState())..setGameboyMode(true);
      await tester.pumpWidget(wrap(state));
      await tester.pumpAndSettle();

      expect(find.byType(GameboyShell), findsOneWidget, reason: 'the handheld wraps the office');
      expect(find.byType(DialScreen), findsNothing, reason: 'Dial is not the Gameboy home');
    });

    testWidgets('normal mode opens on Dial', (tester) async {
      final state = configure(AppState());
      await tester.pumpWidget(wrap(state));
      await tester.pumpAndSettle();

      expect(find.byType(DialScreen), findsOneWidget);
      expect(find.byType(GameboyShell), findsNothing, reason: 'no handheld without Gameboy mode');
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

    // The whole point of the hold: the LCD must keep drawing the office when the
    // reconnect swaps in a fresh empty reader, instead of flashing the black "Not
    // connected" placeholder the user actually saw. The handheld embeds `MapScreen`
    // as its screen body, whose `map == null ? _Waiting : _Plan` branch reads the
    // `map` getter — which now returns the held office — so this proves the fix
    // reaches the pixels inside the shell, not just `state.map` in isolation.
    testWidgets('the LCD keeps the office on a reconnect rather than going black', (tester) async {
      final collector = FakeCollector();
      final state = configure(AppState())
        ..setGameboyMode(true)
        ..debugAttachCollector(collector)
        // A roster lands with a whole reader behind it: the office is drawn, and
        // held against the next reconnect.
        ..debugApplyRoster(const Roster(selfId: 'me', rows: [
          RosterRow(id: 'me', name: 'You', x: 5, y: 5, floorId: 'f1', connected: true),
        ]));
      await tester.pumpWidget(wrap(state));
      await tester.pump();
      await tester.pump();

      expect(find.byType(GameboyShell), findsOneWidget);
      expect(find.byType(MapScreen), findsOneWidget);
      expect(find.text('Not connected'), findsNothing,
          reason: 'the office is up, so no black placeholder');
      expect(state.map, isNotNull);

      // The reconnect: `DirectCollector` swaps in a fresh empty reader, so the live
      // lookup goes null. No roster flows mid-reconnect, so the held office stands.
      collector.hasMap = false;
      state.debugApplyLink(const LinkStatus(LinkState.retrying, 'Network changed — reconnecting.'));
      await tester.pump();

      expect(state.map, isNotNull, reason: 'the held office carries the gap');
      expect(find.text('Not connected'), findsNothing,
          reason: 'the LCD must not blank to the black placeholder on a reconnect');
      expect(find.textContaining('The map comes from Gather'), findsNothing,
          reason: 'nor show the waiting copy under it');
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

    // A roster that puts me in a cluster with Ada — Gather's "in call distance", the
    // one condition the handheld's wave prompt shows under.
    Roster withAdaInCallDistance() => const Roster(selfId: 'me', rows: [
          RosterRow(id: 'me', name: 'You', clusterId: 'c1', clusterIdKnown: true, x: 10, y: 7),
          RosterRow(id: 'a', name: 'Ada', clusterId: 'c1', clusterIdKnown: true, x: 10, y: 8),
        ]);

    testWidgets('a wave prompt appears when someone is in call distance', (tester) async {
      final state = configure(AppState())
        ..setGameboyMode(true)
        ..debugApplyRoster(withAdaInCallDistance());
      await tester.pumpWidget(wrap(state));
      await tester.pump();
      await toOffice(tester);

      expect(find.text('Wave at Ada'), findsOneWidget);
    });

    testWidgets('no wave prompt while standing alone', (tester) async {
      final state = configure(AppState())
        ..setGameboyMode(true)
        ..debugApplyRoster(const Roster(selfId: 'me', rows: [
          RosterRow(id: 'me', name: 'You', x: 10, y: 7),
        ]));
      await tester.pumpWidget(wrap(state));
      await tester.pump();
      await toOffice(tester);

      expect(find.textContaining('Wave at'), findsNothing);
    });

    testWidgets('tapping the wave prompt sends a wave', (tester) async {
      final collector = FakeCollector();
      final state = configure(AppState())
        ..setGameboyMode(true)
        ..debugAttachCollector(collector)
        ..debugApplyRoster(withAdaInCallDistance());
      await tester.pumpWidget(wrap(state));
      // A live collector keeps the tree ticking, so `pumpAndSettle` would never
      // return — a couple of plain pumps are enough to lay the prompt out.
      await tester.pump();
      await tester.pump();
      expect(find.byType(GameboyShell), findsOneWidget);

      await tester.tap(find.text('Wave at Ada'));
      await tester.pump();
      await tester.pump();

      expect(collector.waves, ['a'], reason: 'the prompt waves at the person in call distance');
      // The confirmation lands inside the LCD, not on a Scaffold snackbar below the
      // plastic.
      expect(
        find.descendant(of: find.byType(GameboyShell), matching: find.text('👋 Waved at Ada')),
        findsOneWidget,
      );
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('double-tapping B sends a wave', (tester) async {
      final collector = FakeCollector();
      final state = configure(AppState())
        ..setGameboyMode(true)
        ..debugAttachCollector(collector)
        ..debugApplyRoster(withAdaInCallDistance());
      await tester.pumpWidget(wrap(state));
      await tester.pump();
      await tester.pump();

      // Two B presses inside the double-tap window — the window is wall-clock, and
      // two taps land microseconds apart, so no timer advance is needed.
      await tester.tap(find.text('B'));
      await tester.pump();
      await tester.tap(find.text('B'));
      await tester.pump();
      await tester.pump();

      expect(collector.waves, ['a'],
          reason: 'a double-tap of B waves at the person in call distance');
      expect(
        find.descendant(of: find.byType(GameboyShell), matching: find.text('👋 Waved at Ada')),
        findsOneWidget,
      );
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('double-tapping B waves even after the first tap has muted', (tester) async {
      // Regression: the first B tap mutes *asynchronously*, so by the second tap the
      // call can already report mic-off. The wave must still fire — the pending mute
      // tap is the witness of intent, not the live mic flag. Branching on the flag
      // first would route this second tap into the mic-off path and schedule an
      // unmute instead of waving.
      final collector = FakeCollector();
      final state = configure(AppState())
        ..setGameboyMode(true)
        ..debugAttachCollector(collector)
        ..debugApplyRoster(withAdaInCallDistance())
        ..debugCall = const CallState(
          media: LocalMediaState(capturing: true, audioEnabled: true),
        );
      await tester.pumpWidget(wrap(state));
      await tester.pump();
      await tester.pump();

      // First tap while live records the mute intent.
      await tester.tap(find.text('B'));
      await tester.pump();

      // The mute lands: the call now reads mic-off, exactly what a real `setMicOn`
      // would emit between the two taps.
      state.debugCall = const CallState();
      await tester.pump();

      // Second tap, now observing mic-off, must still wave.
      await tester.tap(find.text('B'));
      await tester.pump();
      await tester.pump();

      expect(collector.waves, ['a'],
          reason: 'the pending mute tap, not the live mic flag, decides the second tap');
    });

    testWidgets('a single B tap does not wave', (tester) async {
      final collector = FakeCollector();
      final state = configure(AppState())
        ..setGameboyMode(true)
        ..debugAttachCollector(collector)
        ..debugApplyRoster(withAdaInCallDistance());
      await tester.pumpWidget(wrap(state));
      await tester.pump();
      await tester.pump();

      // One tap is a mute; past the window it must not have turned into a wave.
      await tester.tap(find.text('B'));
      await tester.pump(const Duration(milliseconds: 400));

      expect(collector.waves, isEmpty, reason: 'one B tap mutes; it does not wave');
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

      expect(find.text('Dial'), findsOneWidget);
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

    testWidgets('the Dial row leaves the office for the dialer', (tester) async {
      final state = configure(AppState())..setGameboyMode(true);
      await tester.pumpWidget(wrap(state));
      await tester.pump();
      await toOffice(tester);

      await tester.tap(find.text('SELECT'));
      await tester.pumpAndSettle();
      // The menu scrolls inside the LCD, so the Dial row can sit below the fold on
      // a short screen — bring it up before choosing it.
      await tester.ensureVisible(find.text('Dial'));
      await tester.tap(find.text('Dial'));
      await tester.pumpAndSettle();

      expect(find.byType(DialScreen), findsOneWidget);
      expect(find.byType(GameboyShell), findsNothing, reason: 'left the office for the dialer');
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

    testWidgets('carries the follower count onto the LCD, not off with the app bar', (tester) async {
      final state = configure(AppState())..setGameboyMode(true);
      // Someone is following you — the app's whole reason. In Gameboy mode the map
      // app bar that used to carry this is gone, so the HUD has to.
      state.debugApplySnapshot(PresenceSnapshot(
        self: const SelfState(spaceId: 'space-1', spaceName: 'HQ'),
        players: const [PlayerRef(id: 'p1', name: 'Mara', isFollowingMe: true)],
        health: const CollectorHealth(logTail: true, cdp: true),
        at: DateTime(2026, 8, 4, 12, 30),
      ));
      await tester.pumpWidget(wrap(state));
      await tester.pump();
      await toOffice(tester);

      // The eye glyph and the count, spoken as the same sentence the app bar used.
      expect(inShell(find.byIcon(Icons.visibility)), findsOneWidget);
      expect(inShell(find.bySemanticsLabel('One person is following you')), findsOneWidget);
    });

    testWidgets('shows no follower chip when nobody is following', (tester) async {
      final state = configure(AppState())..setGameboyMode(true);
      await tester.pumpWidget(wrap(state));
      await tester.pump();
      await toOffice(tester);

      // The default snapshot has an empty roster, so the chip stays away — it leads
      // only when there is a follower, the way the app bar's pill did.
      expect(inShell(find.byIcon(Icons.visibility)), findsNothing);
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

    testWidgets('a D-pad walk down scrolls the lit row into the LCD so A cannot fire a hidden one', (tester) async {
      // Settings sits below the fold of the LCD menu at the default test size —
      // the sibling 'Start closes the menu' path reaches it only via the tester's
      // own ensureVisible. Here the app has to do the scrolling itself.
      final state = configure(AppState())..setGameboyMode(true);
      await tester.pumpWidget(wrap(state));
      await tester.pump();
      await toOffice(tester);

      await tester.tap(find.text('SELECT'));
      await tester.pumpAndSettle();

      // Walk the cursor down to the last row (Settings). Pressing the bottom of the
      // cross is a Down; from the status row it is five of them past Camera, Emotes,
      // Dial and Activity onto Settings.
      final pad = tester.getRect(find.byKey(const Key('gb-dpad')));
      final down = Offset(pad.center.dx, pad.top + pad.height * 0.88);
      for (var i = 0; i < 5; i++) {
        final g = await tester.startGesture(down);
        await tester.pump();
        await g.up();
        await tester.pumpAndSettle();
      }

      // Confirm with A, not a direct tap on 'Settings': the row is the cursor's now,
      // and the app had to scroll it into the well for A to land on the real action
      // rather than firing an off-screen one.
      await tester.tap(find.text('A'));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsScreen), findsOneWidget, reason: 'the scrolled-in row was the real, hittable one');
    });
  });

  group('the call banner on the LCD', () {
    /// A live call, the way the roster says so: self and [name] in one cluster.
    void startCall(AppState state, String name) => state.debugApplyRoster(
          Roster(selfId: 'me', rows: [
            const RosterRow(id: 'me', name: 'Jonas', clusterId: 'c1'),
            RosterRow(id: name, name: name, clusterId: 'c1'),
          ]),
        );

    testWidgets('a live call lights the LCD, with the way back on it', (tester) async {
      final state = configure(AppState())..setGameboyMode(true);
      await tester.pumpWidget(wrap(state));
      await tester.pump();
      await toOffice(tester);

      startCall(state, 'Ada');
      await tester.pumpAndSettle();

      expect(find.text('In a call with Ada'), findsOneWidget);
      expect(find.text('Press A or tap'), findsOneWidget);
      // The office's own app-themed banner is held off the LCD — only the pixel
      // one is drawn, never both.
      expect(find.byType(CallBanner), findsNothing);
    });

    testWidgets('A opens the call while one is live', (tester) async {
      final state = configure(AppState())..setGameboyMode(true);
      await tester.pumpWidget(wrap(state));
      await tester.pump();
      await toOffice(tester);

      startCall(state, 'Ada');
      await tester.pumpAndSettle();

      await tester.tap(find.text('A'));
      await tester.pumpAndSettle();
      expect(find.byType(CallScreen), findsOneWidget);
    });

    testWidgets('tapping the LCD banner opens the call', (tester) async {
      final state = configure(AppState())..setGameboyMode(true);
      await tester.pumpWidget(wrap(state));
      await tester.pump();
      await toOffice(tester);

      startCall(state, 'Ada');
      await tester.pumpAndSettle();

      await tester.tap(find.text('Press A or tap'));
      await tester.pumpAndSettle();
      expect(find.byType(CallScreen), findsOneWidget);
    });

    testWidgets('no call, no banner', (tester) async {
      final state = configure(AppState())..setGameboyMode(true);
      await tester.pumpWidget(wrap(state));
      await tester.pump();
      await toOffice(tester);

      expect(find.text('Press A or tap'), findsNothing);
    });

    testWidgets('names the media-only peer, not a bare "In a call"', (tester) async {
      // The half second at the end of a conversation: the roster cluster has let
      // go, so there is no huddle, but the SFU is still sending Ada. The LCD and
      // the office banner both read this off the call's own tiles, so the handheld
      // names her here rather than falling back to the anonymous title.
      final state = configure(AppState())
        ..setGameboyMode(true)
        ..debugCall = const CallState(
          participants: [CallParticipant(srcId: 'acc-ada', hasAudio: true)],
        )
        ..debugApplyRoster(const Roster(selfId: 'me', rows: [
          RosterRow(id: 'me', name: 'Jonas'),
          // No clusterId — the huddle is empty; only the media plane says Ada is here.
          RosterRow(id: 'ada', name: 'Ada', userAccountId: 'acc-ada'),
        ]));
      await tester.pumpWidget(wrap(state));
      await tester.pump();
      await toOffice(tester);
      await tester.pumpAndSettle();

      expect(state.inHuddle, isFalse, reason: 'no cluster, so no huddle');
      expect(state.inCall, isTrue, reason: 'but the media plane still has company');
      expect(find.text('In a call with Ada'), findsOneWidget);
    });
  });

  group('the D-pad release', () {
    testWidgets('always stops walking, even once the Select menu has taken the pad', (tester) async {
      // Opening the menu with the pad still held once left the walk timer running:
      // the menu swapped the release to a no-op, so lifting never called
      // stopWalking and the avatar walked on. Release must always stop walking.
      final state = configure(_SpyState())
        ..setGameboyMode(true)
        ..debugCanWalk = true;
      await tester.pumpWidget(wrap(state));
      await tester.pump();
      await toOffice(tester);

      await tester.tap(find.text('SELECT'));
      await tester.pumpAndSettle();

      final pad = tester.getRect(find.byKey(const Key('gb-dpad')));
      final gesture = await tester.startGesture(Offset(pad.center.dx, pad.top + pad.height * 0.12));
      await tester.pump();
      await gesture.up();
      await tester.pump();

      expect(state.released, greaterThan(0), reason: 'lifting the pad stopped the walk');
    });
  });

  group('the camera re-grab signal', () {
    // The handheld keeps the avatar centred on the LCD; a pan breaks that lock and a
    // D-pad walk re-grabs it over [AppState.recentre]. Pinned on the real [walk], not
    // the spy, because the spy overrides [walk] away. The live walk plumbing is null in
    // a test, so no step is taken — the signal fires regardless, which is the point.
    test('a walk in Gameboy mode asks the map to re-centre', () async {
      final state = configure(AppState())..setGameboyMode(true);
      final seen = <void>[];
      final sub = state.recentre.listen(seen.add);
      state.walk('Up');
      await Future<void>.delayed(Duration.zero);
      expect(seen, hasLength(1), reason: 'the D-pad re-grabs the centred lock');
      await sub.cancel();
    });

    test('a walk in normal mode says nothing', () async {
      final state = configure(AppState());
      expect(state.gameboyMode, isFalse);
      final seen = <void>[];
      final sub = state.recentre.listen(seen.add);
      state.walk('Up');
      await Future<void>.delayed(Duration.zero);
      expect(seen, isEmpty, reason: 'the normal map owns its own camera');
      await sub.cancel();
    });
  });
}
