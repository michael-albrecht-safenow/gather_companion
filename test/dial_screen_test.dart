/// The Dial tab, at the widget level: that it shows the office as a directory with
/// the people who are here above the people who are not, draws a card for a
/// conversation already happening, and offers a warp only against someone it can
/// reach.
///
/// The warp *action* — the teleport, the auto-mic, the offline refusal — is
/// asserted in `directory_test.dart`, where it needs no navigator; this is about
/// what the screen puts on the glass.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gather_client/gather_client.dart';
import 'package:gather_companion/harness/fake_collector.dart';
import 'package:gather_companion/harness/harness_data.dart';
import 'package:gather_companion/src/app_state.dart';
import 'package:gather_companion/src/link_status.dart';
import 'package:gather_companion/theme/gather_theme.dart';
import 'package:gather_companion/ui/dial_screen.dart';
import 'package:gather_events/gather_events.dart';

void main() {
  RosterRow row(
    String id, {
    required String name,
    bool connected = true,
    String availability = 'Active',
    String? clusterId,
    num? x,
    num? y,
    PersonStatus? status,
  }) =>
      RosterRow(
        id: id,
        name: name,
        connected: connected,
        availability: availability,
        clusterId: clusterId,
        clusterIdKnown: clusterId != null,
        x: x,
        y: y,
        status: status,
      );

  /// A roster with a conversation in the Lounge (Ada + Bob), a lone present
  /// person (Zoe), and somebody offline (Xander).
  Roster peopledRoster() => Roster(selfId: kSelfId, spaceName: 'SafeNow', rows: [
        const RosterRow(id: kSelfId, name: 'You', x: 10, y: 7),
        row('a', name: 'Ada', clusterId: 'c1', x: 8, y: 10),
        row('b', name: 'Bob', clusterId: 'c1', x: 9, y: 11),
        row('z', name: 'Zoe', x: 15, y: 7, status: const PersonStatus(text: 'out to lunch', type: 'Custom')),
        row('x', name: 'Xander', connected: false, availability: 'Offline', x: 3, y: 3),
      ]);

  AppState peopled() => AppState()
    ..debugApplyLink(const LinkStatus(LinkState.live))
    ..debugMap = schematicOffice()
    ..debugApplyRoster(peopledRoster())
    // After the roster: its fold rebuilds the snapshot, so the name has to be set
    // last to survive to the title.
    ..debugApplySnapshot(PresenceSnapshot(
      self: const SelfState(spaceId: 'space-1', spaceName: 'SafeNow'),
      players: const [],
      health: const CollectorHealth(logTail: true, cdp: true),
      at: DateTime(2026),
    ));

  Widget wrap(AppState state) => MaterialApp(
        theme: buildGatherTheme(),
        home: ListenableBuilder(
          listenable: state,
          builder: (context, _) => DialScreen(state: state),
        ),
      );

  // The same screen stood up with explicit visibility, so a test can flip the tab
  // on and off the way the shell does.
  Widget wrapVisible(AppState state, {required bool visible}) => MaterialApp(
        theme: buildGatherTheme(),
        home: DialScreen(state: state, visible: visible),
      );

  // The codename's warp-in opacity: 0 while the flourish is held at its start,
  // climbing to 1 as it lands. The readable proxy for "the animation is running".
  double warpOpacity(WidgetTester tester) => tester
      .widget<Opacity>(find.ancestor(of: find.text('warp dial'), matching: find.byType(Opacity)))
      .opacity;

  testWidgets('shows the space name, and everyone in it including the offline', (tester) async {
    final state = peopled();
    addTearDown(state.dispose);
    await tester.pumpWidget(wrap(state));
    await tester.pump();

    expect(find.text('SafeNow'), findsOneWidget);
    expect(find.text('warp dial'), findsOneWidget, reason: 'the tab wears its codename beside the space name');
    expect(find.text('Zoe'), findsOneWidget);
    expect(find.text('Xander'), findsOneWidget, reason: 'the offline are listed, not hidden');
  });

  testWidgets('puts the people who are here above the people who are not', (tester) async {
    final state = peopled();
    addTearDown(state.dispose);
    await tester.pumpWidget(wrap(state));
    await tester.pump();

    final here = tester.getTopLeft(find.text('Zoe')).dy;
    final gone = tester.getTopLeft(find.text('Xander')).dy;
    expect(here, lessThan(gone));
  });

  testWidgets('draws a card for a conversation, named by its room', (tester) async {
    final state = peopled();
    addTearDown(state.dispose);
    await tester.pumpWidget(wrap(state));
    await tester.pump();

    expect(find.text('Lounge'), findsOneWidget);
    expect(find.text('Join'), findsOneWidget);
  });

  testWidgets('offers a warp only against the reachable', (tester) async {
    final state = peopled();
    addTearDown(state.dispose);
    await tester.pumpWidget(wrap(state));
    await tester.pump();

    // Ada, Bob and Zoe are here; Xander is not. One warp each for the present.
    expect(find.text('Warp'), findsNWidgets(3));
  });

  testWidgets('offers a wave against everyone present, and nobody offline', (tester) async {
    final state = peopled();
    addTearDown(state.dispose);
    await tester.pumpWidget(wrap(state));
    await tester.pump();

    // Ada, Bob and Zoe are here; Xander is away. A wave at an absent person would
    // land nowhere, so the button is withheld there.
    expect(find.byIcon(Icons.waving_hand_rounded), findsNWidgets(3));
  });

  testWidgets('tapping a wave sends one at that person', (tester) async {
    final collector = FakeCollector();
    final state = AppState()
      ..debugApplyLink(const LinkStatus(LinkState.live))
      ..debugAttachCollector(collector)
      ..debugApplyRoster(peopledRoster());
    addTearDown(state.dispose);

    await tester.pumpWidget(wrap(state));
    await tester.pump();

    await tester.tap(find.byIcon(Icons.waving_hand_rounded).first);
    await tester.pump();

    expect(collector.waves, hasLength(1), reason: 'the press reached the wave action');
  });

  Future<void> typeSearch(WidgetTester tester, String query) async {
    await tester.enterText(find.widgetWithText(TextField, 'Search people'), query);
    await tester.pump();
  }

  testWidgets('a name search narrows to the matching people and hides the rest', (tester) async {
    final state = peopled();
    addTearDown(state.dispose);
    await tester.pumpWidget(wrap(state));
    await tester.pump();

    await typeSearch(tester, 'ada');

    expect(find.text('Ada'), findsOneWidget);
    expect(find.text('Zoe'), findsNothing, reason: 'a non-match drops out of the list');
    expect(find.text('Xander'), findsNothing);
  });

  testWidgets('a meeting survives search when one of its members matches', (tester) async {
    final state = peopled();
    addTearDown(state.dispose);
    await tester.pumpWidget(wrap(state));
    await tester.pump();

    // Ada is in the Lounge conversation; searching her keeps the card.
    await typeSearch(tester, 'ada');
    expect(find.text('Lounge'), findsOneWidget, reason: 'the meeting matches on a member name');
  });

  testWidgets('search matches on the status line, not just the name', (tester) async {
    final state = peopled();
    addTearDown(state.dispose);
    await tester.pumpWidget(wrap(state));
    await tester.pump();

    // Zoe's name does not contain "lunch"; her status does.
    await typeSearch(tester, 'lunch');
    expect(find.text('Zoe'), findsOneWidget);
    expect(find.text('Ada'), findsNothing);
  });

  testWidgets('a query with no matches shows the empty line, and clearing restores all', (tester) async {
    final state = peopled();
    addTearDown(state.dispose);
    await tester.pumpWidget(wrap(state));
    await tester.pump();

    await typeSearch(tester, 'nobodyhere');
    expect(find.text('No one matches "nobodyhere".'), findsOneWidget);
    expect(find.text('Ada'), findsNothing);

    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pump();
    expect(find.text('Ada'), findsOneWidget, reason: 'clearing the box brings everyone back');
    expect(find.text('Zoe'), findsOneWidget);
  });

  testWidgets('a search matching only an offline person shows them under Away, not a "Nobody here" header', (tester) async {
    final state = peopled();
    addTearDown(state.dispose);
    await tester.pumpWidget(wrap(state));
    await tester.pump();

    // Xander is offline; nobody present matches. The present section drops entirely
    // rather than heading an empty slot "NOBODY HERE" — the Away section carries him.
    await typeSearch(tester, 'xander');
    expect(find.text('Xander'), findsOneWidget);
    expect(find.text('AWAY'), findsOneWidget, reason: 'the offline match lands in Away');
    expect(find.text('NOBODY HERE'), findsNothing, reason: 'an offline match is not "nobody here"');
    expect(find.text('No one matches "xander".'), findsNothing, reason: 'there is a match, just an offline one');
  });

  testWidgets('typing keeps the field focused and the keyboard up as the recents rail drops', (tester) async {
    // A recent seeds the rail — the sliver sitting above the search box that
    // vanishes the instant a query starts. That removal is what used to reconcile
    // the field against the old slot and close the keyboard after the first letter;
    // without a recent there is no rail and the regression never fires.
    final state = peopled()
      ..debugApplyActivity([WaveActivity(id: 'w1', at: DateTime.utc(2026), actorSpaceUserId: 'a')]);
    addTearDown(state.dispose);
    await tester.pumpWidget(wrap(state));
    await tester.pump();

    expect(find.text('RECENT'), findsOneWidget, reason: 'the recent raises the rail above the search box');

    final field = find.widgetWithText(TextField, 'Search people');
    await tester.showKeyboard(field);
    await tester.pump();
    final focused = tester.binding.focusManager.primaryFocus;
    expect(tester.testTextInput.isVisible, isTrue, reason: 'focusing the field raises the keyboard');

    // One keystroke flips `searching` true and drops the rail — the structural
    // change the stable sliver keys are there to survive. Sent through the open
    // input connection, not a re-tap, so a dropped focus would show up here.
    tester.testTextInput.enterText('a');
    await tester.pump();

    expect(find.text('RECENT'), findsNothing, reason: 'the rail is gone once a query starts');
    expect(tester.testTextInput.isVisible, isTrue, reason: 'the keyboard holds across the rail removal');
    expect(tester.binding.focusManager.primaryFocus, same(focused),
        reason: 'the field keeps its focus node across the rebuild');
    expect(find.text('Ada'), findsOneWidget, reason: 'the keystroke reached the query');
    expect(find.text('Zoe'), findsNothing);
  });

  testWidgets('replays the codename flourish each time the tab becomes visible', (tester) async {
    final state = peopled();
    addTearDown(state.dispose);

    // Stood up off-screen: initState withholds the flourish, so it sits at its
    // start and the codename is invisible.
    await tester.pumpWidget(wrapVisible(state, visible: false));
    await tester.pump();
    expect(warpOpacity(tester), 0.0, reason: 'a hidden tab holds the flourish at frame zero');

    // The tab comes on screen: didUpdateWidget restarts the animation from zero,
    // so mid-flight the codename is part-way faded in.
    await tester.pumpWidget(wrapVisible(state, visible: true));
    await tester.pump(const Duration(milliseconds: 325));
    final mid = warpOpacity(tester);
    expect(mid, greaterThan(0.0));
    expect(mid, lessThan(1.0));
    await tester.pumpAndSettle();
    expect(warpOpacity(tester), 1.0, reason: 'the flourish lands fully opaque');

    // Leaving and returning replays it from the start, not from where it rested.
    await tester.pumpWidget(wrapVisible(state, visible: false));
    await tester.pump();
    await tester.pumpWidget(wrapVisible(state, visible: true));
    await tester.pump(const Duration(milliseconds: 16));
    expect(warpOpacity(tester), lessThan(1.0), reason: 'a return to the tab restarts the flourish');
    await tester.pumpAndSettle();
  });
}
