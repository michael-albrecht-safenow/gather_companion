/// The settings tab, which is mostly a screen that reads state back to you.
///
/// Worth pinning because it is the one place the app explains itself, and the
/// four connection states have to stay four different sentences. A revoked
/// credential asking you to wait, or a healthy connection that will not say
/// which space it is in, are both the kind of wrong that nobody notices until
/// they are trying to work out why nothing is arriving.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gather_companion/src/app_state.dart';
import 'package:gather_companion/src/link_status.dart';
import 'package:gather_companion/src/push.dart';
import 'package:gather_companion/theme/gather_theme.dart';
import 'package:gather_companion/ui/settings_screen.dart';
import 'package:gather_events/gather_events.dart';

void main() {
  AppState withLink(LinkStatus link, {String? space}) => AppState()
    ..debugApplyLink(link)
    ..debugApplySnapshot(PresenceSnapshot(
      self: SelfState(spaceId: 'space-1', spaceName: space),
      players: const [],
      health: const CollectorHealth(logTail: true, cdp: true),
      at: DateTime(2026, 8, 4, 12, 30),
    ));

  Widget wrap(AppState state, {VoidCallback? onUnpair}) => MaterialApp(
        theme: buildGatherTheme(),
        home: ListenableBuilder(
          listenable: state,
          builder: (context, _) => SettingsScreen(state: state, onUnpair: onUnpair ?? () {}),
        ),
      );

  testWidgets('a live connection names the space it is in', (tester) async {
    await tester.pumpWidget(wrap(withLink(const LinkStatus(LinkState.live), space: 'HQ')));
    await tester.pump();

    expect(find.text('Connected'), findsOneWidget);
    expect(find.text('To HQ.'), findsOneWidget);
  });

  testWidgets('a live connection without a space name still says it is connected', (tester) async {
    // The space name arrives a moment after the socket does. Saying nothing in
    // that gap is fine; saying "not connected" would not be.
    await tester.pumpWidget(wrap(withLink(const LinkStatus(LinkState.live))));
    await tester.pump();

    expect(find.text('Connected'), findsOneWidget);
    expect(find.text('Talking to Gather.'), findsOneWidget);
  });

  testWidgets('a dead credential asks you to act rather than to wait', (tester) async {
    // Kept apart from `retrying` for the reason the link strip keeps them apart:
    // one of these is fixed by waiting and the other never is.
    await tester.pumpWidget(wrap(withLink(const LinkStatus(LinkState.retrying, null, true))));
    await tester.pump();

    expect(find.text('Signed out'), findsOneWidget);
    expect(find.textContaining('Pair again'), findsOneWidget);
    expect(find.text('Reconnecting'), findsNothing);
  });

  testWidgets('a dropped connection says what dropped it when it knows', (tester) async {
    await tester.pumpWidget(wrap(withLink(const LinkStatus(LinkState.retrying, 'the socket closed'))));
    await tester.pump();

    expect(find.text('Reconnecting'), findsOneWidget);
    expect(find.text('the socket closed'), findsOneWidget);
  });

  group('the computer that wakes this phone', () {
    // This card used to render `_settings.isComplete` — "is a host and token
    // stored" — under the word "Unreachable". So it called a sleeping Mac
    // reachable forever, and called a phone that had never been given a bridge
    // address at all unreachable, which sent you to check a computer that was
    // fine. It now renders the result of the last actual attempt. Each of these
    // is a different repair in a different place, which is why they are separate
    // sentences and not one boolean.
    Future<void> pumpReach(WidgetTester tester, PushReach reach, {String? name}) async {
      final state = withLink(const LinkStatus(LinkState.live))
        ..debugApplyPushReach(PushRegistration(reach), bridgeName: name);
      await tester.pumpWidget(wrap(state));
      await tester.pump();
    }

    testWidgets('a bridge that answered says it can wake the app', (tester) async {
      await pumpReach(tester, PushReach.armed, name: 'jonas-mac');

      expect(find.text('jonas-mac'), findsOneWidget);
      expect(find.text('Can wake this app when something happens.'), findsOneWidget);
    });

    testWidgets('no bridge stored is not the same claim as unreachable', (tester) async {
      // The regression that started this: an app reinstall wipes the bridge
      // address but leaves the Gather session, and the old copy blamed the Mac.
      await pumpReach(tester, PushReach.unpaired);

      expect(find.text('No computer paired'), findsOneWidget);
      expect(find.textContaining('Pair again'), findsWidgets);
      expect(find.textContaining("Can't reach it"), findsNothing);
    });

    testWidgets('a Mac that did not answer says notifications wait', (tester) async {
      await pumpReach(tester, PushReach.unreachable, name: 'jonas-mac');

      expect(find.textContaining("Can't reach it right now"), findsOneWidget);
      expect(find.text('No computer paired'), findsNothing);
    });

    testWidgets('a reachable Mac with no FCM credential names its own fix', (tester) async {
      // Reachable and useless is a different problem from unreachable, and the
      // command that fixes it is not one anybody guesses.
      await pumpReach(tester, PushReach.noCredential, name: 'jonas-mac');

      expect(find.textContaining('push setup'), findsOneWidget);
    });

    testWidgets('a phone iOS never gave a token says so', (tester) async {
      // A simulator, or a build without the entitlement. Blaming the computer
      // here is how an afternoon disappears.
      await pumpReach(tester, PushReach.noToken, name: 'jonas-mac');

      expect(find.textContaining('has not issued a push token'), findsOneWidget);
    });

    testWidgets('permission the person refused is not reported as a fault', (tester) async {
      await pumpReach(tester, PushReach.denied, name: 'jonas-mac');

      expect(find.textContaining('turned off for this app'), findsOneWidget);
    });

    testWidgets('before the first attempt it claims nothing either way', (tester) async {
      // Held apart from `unpaired` because boot takes a moment, and "no computer
      // paired" flashing on a phone that is about to register fine is still a lie.
      await pumpReach(tester, PushReach.pending, name: 'jonas-mac');

      expect(find.textContaining('Checking whether'), findsOneWidget);
      expect(find.text('No computer paired'), findsNothing);
    });
  });

  testWidgets('the device check is a place you go, not a switch you flip', (tester) async {
    // It opens the camera in `initState` and holds it until it is disposed, so
    // it has to be pushed and left rather than parked behind another tab.
    await tester.pumpWidget(wrap(withLink(const LinkStatus(LinkState.live))));
    await tester.pump();

    expect(find.text('Mic, camera & sound'), findsOneWidget);
    // Exactly one chevron on the screen, and it is this row's. Reconnect and
    // "Forget this computer" are tappable but go nowhere, and a chevron next to
    // either would be promising a screen that does not exist.
    expect(find.byIcon(Icons.chevron_right_rounded), findsOneWidget);
  });

  testWidgets('the party switch reads the bridge, not its own memory', (tester) async {
    // The bridge stops party mode by itself — on its 15-minute timer, when it
    // loses Gather, when the daemon exits. A switch holding local state would
    // keep glowing through all three, so it renders the snapshot and nothing
    // else. It lived on the activity tab as a gradient card once; the rule
    // moved here with it.
    final state = withLink(const LinkStatus(LinkState.live));
    await tester.pumpWidget(wrap(state));
    await tester.pump();

    expect(find.text('Party mode'), findsOneWidget);
    expect(find.text('Teleport around the map!'), findsOneWidget);

    state.debugApplySnapshot(PresenceSnapshot(
      self: const SelfState(spaceId: 'space-1'),
      players: const [],
      health: const CollectorHealth(logTail: true, cdp: true),
      at: DateTime(2026, 8, 4, 12, 30),
      party: const PartyState(active: true, hops: 12, safeTiles: 40),
    ));
    await tester.pump();

    expect(find.text('Hopping four times a second — 12 hops'), findsOneWidget);

    // Standing still because there is nowhere safe is not a fault, and saying
    // so beats a row that claims to be hopping while nothing moves.
    state.debugApplySnapshot(PresenceSnapshot(
      self: const SelfState(spaceId: 'space-1'),
      players: const [],
      health: const CollectorHealth(logTail: true, cdp: true),
      at: DateTime(2026, 8, 4, 12, 30),
      party: const PartyState(active: true, detail: 'everywhere known is within 8 tiles of someone'),
    ));
    await tester.pump();

    expect(find.text('everywhere known is within 8 tiles of someone'), findsOneWidget);
  });

  testWidgets('forgetting the computer calls through exactly once', (tester) async {
    var forgotten = 0;
    await tester.pumpWidget(wrap(
      withLink(const LinkStatus(LinkState.live)),
      onUnpair: () => forgotten++,
    ));
    await tester.pump();

    // Bottom of the list now that it has a section of its own — off the edge of
    // the test viewport, and past the lazy list's built range, until scrolled to.
    await tester.scrollUntilVisible(find.text('Forget this computer'), 120);
    await tester.tap(find.text('Forget this computer'));
    await tester.pump();

    expect(forgotten, 1);
  });
}
