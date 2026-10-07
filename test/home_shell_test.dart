/// The shell, which is the first thing in this app that is above a single screen.
///
/// Two of these tests are about navigation and the rest are about the thing that
/// made the shell worth writing carefully: the office has to be *kept* when you
/// leave it, not rebuilt when you come back. Its decoded artwork, where you have
/// panned to, and whether the opening shot has already played all live on the
/// screen's `State`, so "did the same State survive a round trip" is the honest
/// question, and the one asserted here. The rest — muted tickers, and the 4Hz
/// position feed only reaching the map while the map is what you are looking at —
/// are the two leaks that keeping it alive would otherwise open.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gather_client/gather_client.dart';
import 'package:gather_companion/src/app_state.dart';
import 'package:gather_companion/src/link_status.dart';
import 'package:gather_companion/theme/gather_theme.dart';
import 'package:gather_companion/ui/call_screen.dart';
import 'package:gather_companion/ui/control_bar.dart';
import 'package:gather_companion/ui/dial_screen.dart';
import 'package:gather_companion/ui/home_shell.dart';
import 'package:gather_companion/ui/map_screen.dart';
import 'package:gather_companion/ui/settings_screen.dart';
import 'package:gather_events/gather_events.dart';

extension<T> on T {
  T also(void Function(T) f) {
    f(this);
    return this;
  }
}

void main() {
  AppState connected({Roster? roster}) => AppState()
    ..debugApplyLink(const LinkStatus(LinkState.live))
    // Before the snapshot: folding a roster replaces it, and the activity tab would
    // lose the space it was fetched for and sit breathing its skeleton forever.
    ..also((state) {
      if (roster != null) state.debugApplyRoster(roster);
    })
    ..debugApplySnapshot(PresenceSnapshot(
      self: const SelfState(spaceId: 'space-1', spaceName: 'HQ'),
      players: const [],
      health: const CollectorHealth(logTail: true, cdp: true),
      at: DateTime(2026, 8, 4, 12, 30),
    ))
    // Fetched-and-empty, so the activity tab shows its empty-state sentence —
    // the marker these tests key on — rather than the first-read skeleton.
    ..debugApplyActivity(const []);

  Widget wrap(AppState state, {VoidCallback? onUnpair}) => MaterialApp(
        theme: buildGatherTheme(),
        home: ListenableBuilder(
          listenable: state,
          builder: (context, _) => HomeShell(state: state, onUnpair: onUnpair ?? () {}),
        ),
      );

  group('in a call', () {
    /// In a conversation with [names], the way the roster says so.
    AppState talkingWith(List<String> names) => connected(
          roster: Roster(selfId: 'me', rows: [
            const RosterRow(id: 'me', name: 'Jonas', clusterId: 'c1'),
            for (final name in names) RosterRow(id: name, name: name, clusterId: 'c1'),
          ]),
        );

    Future<void> toOffice(WidgetTester tester, AppState state) async {
      await tester.pumpWidget(wrap(state));
      await tester.tap(find.byTooltip('Office'));
      await tester.pumpAndSettle();
    }

    testWidgets('a banner says so on the office, and only there', (tester) async {
      final state = talkingWith(['Ada Lovelace', 'Grace Hopper']);
      await tester.pumpWidget(wrap(state));
      await tester.pumpAndSettle();
      expect(find.byType(CallBanner), findsNothing, reason: 'not over the activity tab');

      await tester.tap(find.byTooltip('Office'));
      await tester.pumpAndSettle();
      expect(find.text('In a call with Ada and Grace'), findsOneWidget);
      expect(find.text('Tap to see everyone'), findsOneWidget);

      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      expect(find.byType(CallBanner), findsNothing, reason: 'nor over settings');
    });

    testWidgets('it sits under the title bar, over the floor, in an even margin', (tester) async {
      await toOffice(tester, talkingWith(['Ada']));

      final bar = tester.getRect(find.byType(AppBar));
      final plate = tester.getRect(find.descendant(of: find.byType(CallBanner), matching: find.byType(Material)).first);
      final screen = tester.getRect(find.byType(HomeShell));
      final top = plate.top - bar.bottom;
      expect(top, greaterThan(0));
      expect(plate.left - screen.left, top, reason: 'the same gap at the side as on top');
      expect(screen.right - plate.right, top);
    });

    testWidgets('it is the dock\'s colour, not a blue of its own', (tester) async {
      await toOffice(tester, talkingWith(['Ada']));

      final plate = tester.widget<Material>(find.descendant(of: find.byType(CallBanner), matching: find.byType(Material)).first);
      expect(plate.color, tester.element(find.byType(CallBanner)).tokens.card);
    });

    testWidgets('it arrives with a conversation and leaves with it', (tester) async {
      final state = connected();
      await toOffice(tester, state);
      expect(find.byType(CallBanner), findsNothing);

      state.debugApplyRoster(Roster(selfId: 'me', rows: const [
        RosterRow(id: 'me', name: 'Jonas', clusterId: 'c1'),
        RosterRow(id: 'ada', name: 'Ada', clusterId: 'c1'),
      ]));
      await tester.pumpAndSettle();
      expect(find.text('In a call with Ada'), findsOneWidget);

      state.debugApplyRoster(Roster(selfId: 'me', rows: const [
        RosterRow(id: 'me', name: 'Jonas', clusterId: 'c1'),
        RosterRow(id: 'ada', name: 'Ada', clusterId: 'c2'),
      ]));
      await tester.pumpAndSettle();
      expect(find.byType(CallBanner), findsNothing);
    });

    testWidgets('there is no banner without one', (tester) async {
      await toOffice(tester, connected());
      expect(find.byType(CallBanner), findsNothing);
    });

    testWidgets('names one person, and counts past two', (tester) async {
      await toOffice(tester, talkingWith(['Ada Lovelace']));
      expect(find.text('In a call with Ada'), findsOneWidget);
      expect(find.text('Tap to see Ada'), findsOneWidget);

      await toOffice(tester, talkingWith(['Ada', 'Grace', 'Katherine', 'Dorothy']));
      expect(find.text('In a call with Ada and 3 others'), findsOneWidget);
    });

    testWidgets('the banner opens the faces, which carry the controls and no tabs',
        (tester) async {
      await toOffice(tester, talkingWith(['Ada']));

      await tester.tap(find.byType(CallBanner));
      await tester.pumpAndSettle();

      expect(find.byType(CallScreen), findsOneWidget);
      expect(find.byTooltip('Unmute'), findsOneWidget);
      expect(find.byTooltip('Activity'), findsNothing);
      expect(find.byTooltip('Office'), findsNothing);
      expect(find.byTooltip('Settings'), findsNothing);
    });
  });

  testWidgets('dial is what the app opens on', (tester) async {
    await tester.pumpWidget(wrap(connected()));
    await tester.pump();

    expect(find.textContaining("Nobody's in the office right now."), findsOneWidget);
    // The others are in the tree but not on screen, which is the whole point.
    expect(find.textContaining('Waves and meeting notes'), findsNothing);
    expect(find.textContaining('Reading the floor plan'), findsNothing);
    expect(find.byType(MapScreen, skipOffstage: false), findsOneWidget);
  });

  testWidgets('the controls belong to the office and travel with it', (tester) async {
    // They are one dock rather than two floating bars, so this is a section of
    // the same island appearing and disappearing — the navigation underneath is
    // there throughout.
    final state = connected();
    await tester.pumpWidget(wrap(state));
    await tester.pump();

    expect(find.byType(ControlBar), findsNothing, reason: 'not on the dial tab');

    await tester.tap(find.byTooltip('Office'));
    await tester.pumpAndSettle();
    expect(find.byType(ControlBar), findsOneWidget);
    expect(find.byTooltip('Your status'), findsOneWidget);

    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    expect(find.byType(ControlBar), findsNothing);
    // And the rail is still there, which is the difference between a section
    // closing up and the whole dock leaving.
    expect(find.byTooltip('Office'), findsOneWidget);
  });

  testWidgets('every destination on the rail goes somewhere', (tester) async {
    // Also the only thing pinning rail order to `IndexedStack` order. They were
    // parallel hand-written lists once, and reordering `_Tab` without reordering
    // the children swapped two tabs' bodies — the rail said Activity and the
    // office appeared.
    await tester.pumpWidget(wrap(connected()));
    await tester.pump();

    await tester.tap(find.byTooltip('Office'));
    await tester.pump();
    expect(find.textContaining('Reading the floor plan'), findsOneWidget);
    expect(find.textContaining('Waves and meeting notes'), findsNothing);

    await tester.tap(find.byTooltip('Settings'));
    await tester.pump();
    await tester.scrollUntilVisible(find.text('Forget this computer'), 120);
    expect(find.text('Forget this computer'), findsOneWidget);
    expect(find.textContaining('Reading the floor plan'), findsNothing);

    await tester.tap(find.byTooltip('Activity'));
    await tester.pump();
    expect(find.textContaining('Waves and meeting notes'), findsOneWidget);
  });

  testWidgets('leaving the office and coming back returns to it rather than rebuilding it', (tester) async {
    // The guarantee behind the `IndexedStack`. `_MapScreenState` owns the art
    // cache — 573 decoded images on the reference space — and `_PlanState` owns
    // where you have panned to and whether the opening shot has played. A new
    // State means all three are gone, which is the difference between coming
    // back to the office and reloading it.
    await tester.pumpWidget(wrap(connected()));
    await tester.pump();

    await tester.tap(find.byTooltip('Office'));
    await tester.pump();
    final before = tester.state(find.byType(MapScreen));

    await tester.tap(find.byTooltip('Settings'));
    await tester.pump();
    // Still in the tree while it is not on screen.
    expect(find.byType(MapScreen), findsNothing);
    expect(find.byType(MapScreen, skipOffstage: false), findsOneWidget);

    await tester.tap(find.byTooltip('Office'));
    await tester.pump();

    expect(identical(tester.state(find.byType(MapScreen, skipOffstage: false)), before), isTrue);
  });

  testWidgets('a tab you are not looking at has its clocks stopped', (tester) async {
    // Kept alive is not the same as kept running. `MapMotion` walks people at
    // 60fps and the party card's gradient turns on a five-second loop, and
    // neither of them can tell that it is behind another tab.
    await tester.pumpWidget(wrap(connected()));
    await tester.pump();

    expect(TickerMode.valuesOf(tester.element(find.byType(DialScreen, skipOffstage: false))).enabled, isTrue);
    expect(TickerMode.valuesOf(tester.element(find.byType(MapScreen, skipOffstage: false))).enabled, isFalse);

    await tester.tap(find.byTooltip('Office'));
    await tester.pump();

    expect(TickerMode.valuesOf(tester.element(find.byType(DialScreen, skipOffstage: false))).enabled, isFalse);
    expect(TickerMode.valuesOf(tester.element(find.byType(MapScreen, skipOffstage: false))).enabled, isTrue);
  });

  testWidgets('footsteps only reach the map while the map is the tab you are on', (tester) async {
    // `AppState.positions` exists so that walking repaints the office without
    // waking the rest of the tree. Merging it in unconditionally would undo
    // that from the other side: four rebuilds a second behind the settings list.
    final state = connected();
    await tester.pumpWidget(wrap(state));
    await tester.pump();

    Listenable feeding() => tester
        .widget<ListenableBuilder>(
          find
              .ancestor(
                of: find.byType(MapScreen, skipOffstage: false),
                matching: find.byType(ListenableBuilder),
              )
              .first,
        )
        .listenable;

    // Opening on Dial, so the map is behind another tab: presence only.
    expect(identical(feeding(), state), isTrue,
        reason: 'off the map tab, only presence should rebuild it');

    await tester.tap(find.byTooltip('Office'));
    await tester.pump();

    expect(identical(feeding(), state), isFalse,
        reason: 'on the map tab it should be fed positions too');
  });

  testWidgets('the rail says which destination you are on', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(wrap(connected()));
    await tester.pump();

    expect(tester.getSemantics(find.byTooltip('Dial')), isSemantics(isButton: true, isSelected: true));
    expect(tester.getSemantics(find.byTooltip('Settings')), isSemantics(isButton: true, isSelected: false));

    await tester.tap(find.byTooltip('Settings'));
    await tester.pump();

    expect(tester.getSemantics(find.byTooltip('Dial')), isSemantics(isSelected: false));
    expect(tester.getSemantics(find.byTooltip('Settings')), isSemantics(isSelected: true));

    handle.dispose();
  });

  testWidgets('forgetting the computer is reachable, and only from settings', (tester) async {
    var forgotten = 0;
    await tester.pumpWidget(wrap(connected(), onUnpair: () => forgotten++));
    await tester.pump();

    await tester.tap(find.byTooltip('Settings'));
    await tester.pump();
    expect(find.byType(SettingsScreen), findsOneWidget);

    // Bottom of the settings list now that it has a section of its own — off
    // the edge of the test viewport, and past the lazy list's built range, until
    // scrolled to.
    await tester.scrollUntilVisible(find.text('Forget this computer'), 120);
    // Fully into view before tapping: with the Appearance section above it the
    // row can stop at the very bottom edge, where its centre is off-screen and the
    // tap misses.
    await tester.ensureVisible(find.text('Forget this computer'));
    await tester.pump();
    await tester.tap(find.text('Forget this computer'));
    await tester.pump();

    expect(forgotten, 1);
  });
}
