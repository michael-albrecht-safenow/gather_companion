/// The map screen, which exists because the floor plan turned out to be free.
///
/// Two things are worth pinning. The first is that "no map yet" and "not connected"
/// are different sentences — the map arrives a moment after the roster, so a screen
/// that said "not connected" during that gap would be lying once a second on every
/// launch. The second is that offline avatars are not drawn: their coordinates are
/// wherever somebody logged off, and a map full of people who went home is worse
/// than a map with nobody on it.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gather_client/gather_client.dart';
import 'package:gather_companion/src/app_state.dart';
import 'package:gather_companion/src/art_cache.dart';
import 'package:gather_companion/src/link_status.dart';
import 'package:gather_companion/theme/gather_theme.dart';
import 'package:gather_companion/ui/dpad.dart';
import 'package:gather_companion/ui/map_screen.dart';
import 'package:gather_events/gather_events.dart';

SpaceMap _map({
  Set<int> blocked = const {},
  List<SpaceRoom> rooms = const [],
  Set<int> inside = const {},
}) => SpaceMap(
      floorId: 'f1',
      width: 20,
      height: 10,
      blocked: blocked,
      rooms: rooms,
      // Empty means "all office" — the escape hatch for a space that names no areas
      // beyond the base one — so a test that cares about the footprint has to say
      // what it is. `rooms` alone does not: the builder derives one from the other,
      // and this constructor takes both.
      inside: inside,
    );

RosterRow _row(
  String id,
  num x,
  num y, {
  bool connected = true,
  String? name,
  String? availability,
}) =>
    RosterRow(
      id: id,
      name: name,
      x: x,
      y: y,
      floorId: 'f1',
      connected: connected,
      availability: availability,
    );

/// The floor's painter, out of a live tree.
///
/// Matched by name because `_OfficePainter` is private and there is deliberately
/// no seam for reaching it — [officePainter] exists for building one *outside* a
/// widget tree, which is the other half of the same job. The D-pad's painter is
/// the only other one down here, so the name is enough to tell them apart.
CustomPainter _officePainter(WidgetTester tester) => tester
    .widgetList<CustomPaint>(find.byType(CustomPaint))
    .map((widget) => widget.painter)
    .whereType<CustomPainter>()
    .firstWhere((painter) => painter.runtimeType.toString().contains('OfficePainter'));

/// One area covering the whole test floor.
///
/// Which tile a tap lands on depends on the viewport, the cover-the-screen factor and
/// the opening shot, and pinning all three would be a test of arithmetic rather than
/// of behaviour. An area the size of the floor means any tap inside the map is inside
/// *it*, so what is asserted is the rule — tile or room — and not the coordinate.
SpaceRoom _everywhere({required String type, String? name}) => SpaceRoom(
      id: 'area-1',
      name: name,
      type: type,
      x: 0,
      y: 0,
      width: 20,
      height: 10,
      walled: false,
    );

/// Records where a walk is aimed and reports it as sent, standing in for the collector
/// the real [AppState.goTo] needs — so a test can read back the destination the card
/// handed it instead of only seeing the offline refusal.
class _RecordingGoTo extends AppState {
  final destinations = <(int, int)>[];

  @override
  Future<String?> goTo(int x, int y) async {
    destinations.add((x, y));
    return null;
  }
}

void main() {
  // The same pair of listenables the app opens this screen with. `state` alone is
  // not enough: walking is not a presence event, so a roster where everybody moved
  // and nothing else changed never reaches a listener of `state`.
  Widget wrap(AppState state) => MaterialApp(
        theme: buildGatherTheme(),
        home: ListenableBuilder(
          listenable: Listenable.merge([state, state.positions]),
          builder: (context, _) => MapScreen(state: state),
        ),
      );

  /// A tap on the middle of the floor, waited out.
  ///
  /// The map carries `onDoubleTap` for the one-handed zoom, so Flutter holds a single
  /// tap until the double-tap window closes before delivering it. A test that pumped
  /// one frame would see nothing and conclude the tap was ignored.
  /// One tap in the middle of the floor, and **one frame**.
  ///
  /// The single frame is the assertion. This used to have to pump 400ms, because a
  /// [GestureDetector] carrying `onDoubleTap` holds every tap until the double-tap
  /// window closes — which is a third of a second between the finger and the reticle,
  /// and is what "the tile selection is very laggy" was. Every test below that selects
  /// something now also says it happened at once.
  Future<void> tapFloor(WidgetTester tester) async {
    await tester.tapAt(const Offset(400, 300));
    await tester.pump();
  }

  testWidgets('the ghost ships in the bundle and is a real 72-frame sheet', (tester) async {
    // Gather's default avatar, copied out of the desktop client's bundle. The
    // painter reads it out of the art cache under an asset key, so this is the one
    // place the pubspec entry, the asset scheme and the file's dimensions are
    // checked together — a misnamed asset would otherwise be a silent pin.
    final cache = ArtCache();
    addTearDown(cache.dispose);
    // Everything under `runAsync`: the bundle read and the decode are real I/O,
    // which the fake-async zone a widget test runs in would otherwise hold forever.
    // Waited on the image itself rather than `settled`, which is only recounted on
    // the cache's coalescing timer.
    await tester.runAsync(() async {
      cache.prefetch([ghostAvatarUrl], group: ArtRequest.avatars);
      for (var i = 0; i < 400 && cache[ghostAvatarUrl] == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    });

    final ghost = cache[ghostAvatarUrl];
    expect(ghost, isNotNull);
    expect(ghost!.width, 72 * avatarFrameWidth);
    expect(ghost.height, avatarFrameHeight);
  });

  testWidgets('a connected app with no map yet says it is still reading one', (tester) async {
    final state = AppState()..debugApplyLink(const LinkStatus(LinkState.live));
    await tester.pumpWidget(wrap(state));
    await tester.pump();

    expect(find.textContaining('Reading the floor plan'), findsOneWidget);
    expect(find.text('Not connected'), findsNothing);
  });

  testWidgets('without a connection it says that instead', (tester) async {
    final state = AppState();
    await tester.pumpWidget(wrap(state));
    await tester.pump();

    expect(find.text('Not connected'), findsOneWidget);
  });

  testWidgets('the map draws, and counts only the people who are here', (tester) async {
    final state = AppState()
      ..debugApplyLink(const LinkStatus(LinkState.live))
      ..debugMap = _map()
      ..debugApplyRoster(Roster(selfId: 'me', rows: [
        _row('me', 5, 5),
        _row('ada', 8, 4, name: 'Ada'),
        _row('bram', 9, 6, name: 'Bram'),
        _row('gone', 2, 2, name: 'Gone home', connected: false),
      ]));

    await tester.pumpWidget(wrap(state));
    await tester.pump();

    expect(find.text('3 here'), findsOneWidget, reason: 'me and two others; the parked one does not count');
  });

  testWidgets('being followed is a counter beside the head count, and absent when nobody is',
      (tester) async {
    // The follower card moved here from the activity tab: live presence on the
    // live screen. Same pill as the head count, the accent instead of neutral,
    // and only a number — absent rather than "0", because zero is the permanent
    // normal state and a pill saying so all day is furniture.
    final state = AppState()
      ..debugApplyLink(const LinkStatus(LinkState.live))
      ..debugMap = _map()
      ..debugApplyRoster(Roster(selfId: 'me', rows: [_row('me', 5, 5)]));

    await tester.pumpWidget(wrap(state));
    await tester.pump();
    expect(find.text('1'), findsNothing, reason: 'nobody following, no badge');

    state.debugApplySnapshot(PresenceSnapshot(
      self: const SelfState(spaceId: 'space-1'),
      players: const [
        PlayerRef(id: 'a', name: 'Ada', isFollowingMe: true),
        // In the space but not following: must not count.
        PlayerRef(id: 'c', name: 'Cleo'),
      ],
      health: const CollectorHealth(logTail: true, cdp: true),
      at: DateTime(2026, 8, 4, 12, 30),
    ));
    await tester.pump();

    expect(find.text('1'), findsOneWidget);
    expect(
      tester.getSemantics(find.text('1')),
      isSemantics(label: 'One person is following you'),
    );
  });

  testWidgets('the pad appears only once there is something for it to drive',
      (tester) async {
    // Both halves are needed and neither is optional: the socket to send the step on,
    // and the tile to judge it from. A pad shown without them is a control that cannot
    // be told apart from a broken one, so it is absent instead.
    final state = AppState()
      ..debugApplyLink(const LinkStatus(LinkState.live))
      ..debugMap = _map()
      ..debugApplyRoster(Roster(selfId: 'me', rows: [_row('me', 5, 5)]));

    await tester.pumpWidget(wrap(state));
    await tester.pump();
    expect(find.byType(DPad), findsNothing, reason: 'no live Gather behind it');

    state
      ..debugCanWalk = true
      ..debugApplyRoster(Roster(selfId: 'me', rows: [_row('me', 5, 5)]));
    await tester.pump();

    if (!kShowDPad) {
      // The pad is shelved — see `kShowDPad` in dpad.dart. This branch pins the
      // shelving itself: even with everything live behind it, no pad. The layout
      // assertions below wait, live, for the flag to flip back.
      expect(find.byType(DPad), findsNothing,
          reason: 'the pad is shelved while kShowDPad is false');
      return;
    }

    expect(find.byType(DPad), findsOneWidget);
    // Centred across the bottom, so it is the same reach from either hand.
    final size = tester.getSize(find.byType(MapScreen));
    expect(
      tester.getCenter(find.byType(DPad)).dx,
      moreOrLessEquals(size.width / 2, epsilon: 0.5),
    );
    expect(tester.getCenter(find.byType(DPad)).dy, greaterThan(size.height / 2),
        reason: 'the half of the screen a thumb reaches');
  });

  testWidgets('somebody still marked connected but away is not here', (tester) async {
    // The bug this rule exists for. Measured against a real space: twelve rows said
    // `connected: true` and nine of them were people who had gone home hours before,
    // so the map drew eleven bodies into an office holding three. A socket that dies
    // without saying goodbye leaves `connected` behind it; availability is what
    // moves when somebody actually leaves.
    final state = AppState()
      ..debugApplyLink(const LinkStatus(LinkState.live))
      ..debugMap = _map()
      ..debugApplyRoster(Roster(selfId: 'me', rows: [
        _row('me', 5, 5),
        _row('ada', 8, 4, name: 'Ada', availability: 'Active'),
        _row('busy', 9, 6, name: 'Bram', availability: 'Busy'),
        _row('ghost', 2, 2, name: 'Ghost', availability: 'Offline'),
      ]));

    await tester.pumpWidget(wrap(state));
    await tester.pump();

    // Busy is still in the building; Offline is not, however connected it claims.
    expect(find.text('3 here'), findsOneWidget, reason: 'Ada, Bram and me');
  });

  testWidgets('walking redraws the map, though nothing else counts it as a change', (tester) async {
    // The bug: PresenceTracker never looks at coordinates — being near somebody says
    // nothing about whether they want you, which is this app's whole argument — so a
    // roster carrying only movement leaves `stateChanged` false. The map was the one
    // screen that needed it, and it sat frozen until somebody happened to follow you
    // or drop off.
    //
    // Asserted on the painter rather than on the app bar, which is where this used
    // to read the answer: the bar named the room you were standing in, and walking
    // between two rooms changed it. That line is gone, and the painter is the
    // honest place to ask anyway — repainting the floor *is* the behaviour, and the
    // app bar only ever stood in for it.
    final state = AppState()
      ..debugApplyLink(const LinkStatus(LinkState.live))
      ..debugMap = _map();

    await tester.pumpWidget(wrap(state));
    state.debugApplyRoster(Roster(selfId: 'me', rows: [
      _row('me', 1, 1),
      _row('ada', 8, 4, name: 'Ada'),
    ]));
    await tester.pump();
    final before = _officePainter(tester);

    // Only a position moves. Same people, same names, same connections.
    state.debugApplyRoster(Roster(selfId: 'me', rows: [
      _row('me', 5, 5),
      _row('ada', 8, 4, name: 'Ada'),
    ]));
    await tester.pump();

    expect(
      _officePainter(tester).shouldRepaint(before),
      isTrue,
      reason: 'a roster carrying only movement still has to reach the floor',
    );
  });

  group('going somewhere', () {
    /// A live-enough app to tap on: a floor, a roster, and something behind the pill.
    ///
    /// Deliberately without a row for *us*. `_centreOnMe` fires the opening shot at
    /// 3x on our own avatar as soon as there is one, which puts our own tile under
    /// the middle of the screen — so every tap in the middle would land on the one
    /// tile that means "clear the selection". The rule is worth having and worth
    /// testing; it is just not worth every other test having to know about it.
    AppState ready({
      List<SpaceRoom> rooms = const [],
      Set<int> blocked = const {},
      Set<int> inside = const {},
    }) =>
        AppState()
          ..debugApplyLink(const LinkStatus(LinkState.live))
          ..debugCanWalk = true
          ..debugMap = _map(rooms: rooms, blocked: blocked, inside: inside)
          ..debugApplyRoster(Roster(selfId: 'me', rows: [_row('ada', 8, 4, name: 'Ada')]));

    testWidgets('nothing is offered until something is tapped', (tester) async {
      await tester.pumpWidget(wrap(ready()));
      await tester.pump();

      expect(find.text('Go here'), findsNothing);
      expect(find.textContaining('Go to'), findsNothing);
    });

    testWidgets('a tap on open floor offers to go to that tile', (tester) async {
      await tester.pumpWidget(wrap(ready()));
      await tester.pump();
      await tapFloor(tester);

      expect(find.text('Go here'), findsOneWidget);
    });

    testWidgets('a tap while offline says why, and offers nothing', (tester) async {
      // Offline the Go-here pill never appears (no route to lay), so a bare tap would
      // otherwise do nothing visible. The destination tap is the one that explains it.
      final state = ready()
        ..debugApplyLink(
            const LinkStatus(LinkState.offline, 'No connection — waiting for network.'));
      await tester.pumpWidget(wrap(state));
      await tester.pump();
      await tapFloor(tester);
      await tester.pump();

      expect(find.text('Go here'), findsNothing);
      expect(find.text("Can't move — no connection."), findsOneWidget);

      // It is transient — the pill clears itself so the slot is free again.
      await tester.pump(const Duration(seconds: 3));
      expect(find.text("Can't move — no connection."), findsNothing);
    });

    testWidgets('a second tap zooms and leaves no reticle behind', (tester) async {
      // The double tap is counted by hand precisely so the first one can select at
      // once — and the price of that is the second one having to put back what the
      // first displaced. A pinch-to-zoom that left a Go-to pill on whatever happened
      // to be under the middle of the screen would be the same bug in reverse.
      await tester.pumpWidget(wrap(ready()));
      await tester.pump();

      await tapFloor(tester);
      expect(find.text('Go here'), findsOneWidget, reason: 'the first tap selects');

      await tester.tapAt(const Offset(400, 300));
      await tester.pump();
      expect(find.text('Go here'), findsNothing);
    });

    testWidgets('two taps far apart are two selections, not a zoom', (tester) async {
      // `kDoubleTapSlop` is Flutter's own figure and it is the whole difference
      // between a double tap and two taps.
      await tester.pumpWidget(wrap(ready()));
      await tester.pump();

      await tapFloor(tester);
      await tester.tapAt(const Offset(200, 150));
      await tester.pump();

      expect(find.text('Go here'), findsOneWidget);
    });

    testWidgets('a tap inside a meeting room offers the room by name', (tester) async {
      // `shouldNavigateToTile` is false for MeetingRoom, Common and Desk: you meant
      // "go to the Boardroom", not "stand on that particular square of it". And the
      // floor never writes a meeting room's name on itself, so the pill is the only
      // place the name appears.
      await tester.pumpWidget(wrap(
        ready(rooms: [_everywhere(type: 'MeetingRoom', name: 'Boardroom')]),
      ));
      await tester.pump();
      await tapFloor(tester);

      expect(find.text('Go to Boardroom'), findsOneWidget);
    });

    testWidgets('a tap on the main floor picks the tile, not the area', (tester) async {
      // The same fixture with one word changed. `Public`, `Lobby` and `Team` answer
      // true, and the measured office's main room is a single 44x34 Public area — an
      // area target there would mean "go to the office", which is where you are.
      await tester.pumpWidget(wrap(
        ready(rooms: [_everywhere(type: 'Public', name: 'Main floor')]),
      ));
      await tester.pump();
      await tapFloor(tester);

      expect(find.text('Go here'), findsOneWidget);
      expect(find.text('Go to Main floor'), findsNothing);
    });

    testWidgets('a tap on a chair still offers to go there', (tester) async {
      // Reported as "tap to walk often does not work — chairs count as unwalkable".
      // They can be: Gather's `blockedAtPosition` has no exemption for seats either.
      // What Gather does that this was not doing is relocate rather than refuse, so
      // a tap on furniture is a tap on the floor beside it.
      final chair = 4 * 20 + 7;
      await tester.pumpWidget(wrap(ready(blocked: {chair})));
      await tester.pump();
      await tapFloor(tester);

      expect(find.text('Go here'), findsOneWidget);
    });

    testWidgets('a tap in the middle of a desk cluster still offers to go there', (tester) async {
      // A single blocked tile was always survivable. Several together were not: the
      // search used to widen with the zoom and bottom out at one ring, so zoomed in
      // most of the furniture in the office selected nothing at all.
      await tester.pumpWidget(wrap(ready(blocked: {
        for (var y = 3; y <= 5; y++)
          for (var x = 6; x <= 8; x++) y * 20 + x,
      })));
      await tester.pump();
      await tapFloor(tester);

      expect(find.text('Go here'), findsOneWidget);
    });

    testWidgets('the emptiness outside the office is a destination like any other', (tester) async {
      // This screen had a rule of its own here for a while — refuse anything outside
      // the office footprint, on the grounds that a route out there cannot be walked
      // and so would end in a teleport into the void. The client has no such rule:
      // `Hh` bounds-checks against `baseArea.dimensionsInTiles`, which is the whole
      // grid, `moveSpaceUserToTile` navigates to a tile with no area at all
      // (`isNil(E) || E.shouldNavigateToTile()`), and `shouldTeleport(NoPathFound)`
      // puts you there. Being outside the building is not a trap — the way back is
      // another tap — and inventing a restriction Gather does not have is how this
      // client starts behaving differently from the one beside it.
      //
      // The office is the top-left corner; the tap lands well outside it.
      await tester.pumpWidget(wrap(ready(inside: {
        for (var y = 0; y < 4; y++)
          for (var x = 0; x < 4; x++) y * 20 + x,
      })));
      await tester.pump();
      await tapFloor(tester);

      expect(find.text('Go here'), findsOneWidget);
    });

    testWidgets('a tap on nothing but furniture selects nothing', (tester) async {
      // Not an error and not a sentence — you tapped a desk. The snap that forgives a
      // near miss only widens as far as [_maxSnap], and a floor that is furniture all
      // the way out has nothing to offer.
      await tester.pumpWidget(wrap(
        ready(blocked: {for (var tile = 0; tile < 20 * 10; tile++) tile}),
      ));
      await tester.pump();
      await tapFloor(tester);

      expect(find.text('Go here'), findsNothing);
    });

    testWidgets('the pill is absent when there is no live Gather behind it', (tester) async {
      // The D-pad's rule, and the same reason: a control that cannot do anything is
      // absent rather than dimmed.
      final state = ready()..debugCanWalk = false;
      await tester.pumpWidget(wrap(state));
      await tester.pump();
      await tapFloor(tester);

      expect(find.text('Go here'), findsNothing);
    });

    testWidgets('the cross puts the selection back', (tester) async {
      await tester.pumpWidget(wrap(ready()));
      await tester.pump();
      await tapFloor(tester);
      expect(find.text('Go here'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.close_rounded));
      await tester.pump();

      expect(find.text('Go here'), findsNothing);
    });

    testWidgets('a walk under way offers to stop instead', (tester) async {
      // One control with two states. The desktop client does the same thing with a
      // persistent toast: no confirmation before the walk, a Cancel during it.
      final state = ready()..debugOnRoute = true;
      await tester.pumpWidget(wrap(state));
      await tester.pump();

      expect(find.text('Stop'), findsOneWidget,
          reason: 'and without anything having been selected');
      expect(find.text('Go here'), findsNothing);
    });

    /// The kart, which on a phone is the only door to driving that a person opens
    /// themselves — the other one is how far away the destination is, and it needs no
    /// control at all.
    final kart = find.byIcon(Icons.sports_motorsports_rounded);

    testWidgets('the kart is offered alongside somewhere to go', (tester) async {
      final state = ready();
      await tester.pumpWidget(wrap(state));
      await tester.pump();

      expect(kart, findsNothing, reason: 'nothing to set off on yet');

      await tapFloor(tester);
      expect(kart, findsOneWidget);
      expect(state.boost, isFalse, reason: 'and off until it is pressed');
    });

    testWidgets('pressing the kart latches it', (tester) async {
      final state = ready();
      await tester.pumpWidget(wrap(state));
      await tester.pump();
      await tapFloor(tester);

      await tester.tap(kart);
      await tester.pump();
      expect(state.boost, isTrue);

      await tester.tap(kart);
      await tester.pump();
      expect(state.boost, isFalse, reason: 'and unlatches again');
    });

    testWidgets('the kart is exactly as tall as the pill beside it, and square',
        (tester) async {
      await tester.pumpWidget(wrap(ready()));
      await tester.pump();
      await tapFloor(tester);

      final plate = tester.getSize(find.ancestor(of: kart, matching: find.byType(Material)).first);
      final pill = tester.getSize(find.ancestor(of: find.text('Go here'), matching: find.byType(ClipRRect)).first);
      expect(plate.height, pill.height);
      expect(plate.width, plate.height);
    });

    testWidgets('the kart stays up for the whole walk', (tester) async {
      // Because it still does something: shift is a modifier on movement, not a
      // property of a journey, so latching it mid-route takes the kart there and then.
      final state = ready()..debugOnRoute = true;
      await tester.pumpWidget(wrap(state));
      await tester.pump();

      expect(find.text('Stop'), findsOneWidget);
      expect(kart, findsOneWidget);
    });

    testWidgets('a tap the app cannot act on says so', (tester) async {
      // Every action answers. There is no collector behind this state, so going
      // anywhere is refused — and the refusal is a sentence, not silence.
      await tester.pumpWidget(wrap(ready()));
      await tester.pump();
      await tapFloor(tester);

      await tester.tap(find.text('Go here'));
      await tester.pump();

      expect(find.text('Not connected to Gather.'), findsOneWidget);
    });

    testWidgets('a locked room is refused, and says why', (tester) async {
      // The one refusal here that is about a person rather than about the floor, so
      // the one that earns a sentence. `isLocked` lives on `MapEntityIdentifier`
      // rather than on the area. The server enforces it too — `isPermittedToMoveTo`,
      // the second gate inside `setPosition` — but silently, by not moving you and
      // publishing an event no patch accompanies, so refusing here is what turns it
      // into something a person can read.
      await tester.pumpWidget(wrap(ready(rooms: [
        SpaceRoom(
          id: 'area-1',
          name: 'Boardroom',
          type: 'MeetingRoom',
          x: 0,
          y: 0,
          width: 20,
          height: 10,
          walled: true,
          locked: true,
        ),
      ])));
      await tester.pump();
      await tapFloor(tester);

      expect(find.text('Go to Boardroom'), findsNothing);
      expect(find.text('Boardroom is locked.'), findsOneWidget);
    });

    testWidgets('tapping where you are already standing clears the selection', (tester) async {
      // The opening shot centres on our own avatar at 3x, so the middle of the screen
      // is us — which makes this both the rule and the reason every other test here
      // is built without a row for us.
      final state = AppState()
        ..debugApplyLink(const LinkStatus(LinkState.live))
        ..debugCanWalk = true
        ..debugMap = _map()
        ..debugApplyRoster(Roster(selfId: 'me', rows: [_row('me', 5, 5)]));
      await tester.pumpWidget(wrap(state));
      await tester.pumpAndSettle();

      await tapFloor(tester);

      expect(find.text('Go here'), findsNothing,
          reason: 'there is nowhere to go to from where you are');
    });

    testWidgets('the painter is told what is selected, and repaints for it', (tester) async {
      await tester.pumpWidget(wrap(ready()));
      await tester.pump();
      final before = _officePainter(tester);

      await tapFloor(tester);

      expect(_officePainter(tester).shouldRepaint(before), isTrue,
          reason: 'the reticle has to be drawn');
    });
  });

  group('walking to a person', () {
    // A body and me on the same tile, so the centre tap that lands on my own tile
    // falls on them instead — peopleOnMap leaves me out, so the only person under the
    // tap is the other one. It saves pinning a pixel to a body (see [_everywhere]) and
    // is the one deterministic way to raise the person card in a test.
    AppState withPersonUnderCentre() => AppState()
      ..debugApplyLink(const LinkStatus(LinkState.live))
      ..debugCanWalk = true
      ..debugMap = _map()
      ..debugApplyRoster(Roster(selfId: 'me', rows: [
        _row('me', 5, 5),
        _row('ada', 5, 5, name: 'Ada'),
      ]));

    testWidgets('the card offers a walk as well as a wave', (tester) async {
      // The whole of this change: you can go to somebody, not only hail them.
      await tester.pumpWidget(wrap(withPersonUnderCentre()));
      await tester.pumpAndSettle();

      await tapFloor(tester);

      expect(find.text('Ada'), findsOneWidget, reason: 'the body under the tap is picked');
      expect(find.text('Go here'), findsOneWidget);
      expect(find.text('Wave'), findsOneWidget);
    });

    testWidgets("Go here sends that person's tile and takes the card down", (tester) async {
      // A recording state so the walk succeeds and its destination can be read back:
      // the refusal path alone would pass even if this forwarded the wrong person's
      // position, because goTo bails before it ever looks at a coordinate.
      final state = _RecordingGoTo()
        ..debugApplyLink(const LinkStatus(LinkState.live))
        ..debugCanWalk = true
        ..debugMap = _map()
        ..debugApplyRoster(Roster(selfId: 'me', rows: [
          _row('me', 5, 5),
          _row('ada', 5, 5, name: 'Ada'),
        ]));
      await tester.pumpWidget(wrap(state));
      await tester.pumpAndSettle();
      await tapFloor(tester);

      await tester.tap(find.text('Go here'));
      await tester.pump();

      expect(state.destinations, [(5, 5)], reason: "Ada's tile is where the walk is sent");
      expect(find.text('Ada'), findsNothing, reason: 'the card is dropped the moment it is acted on');
    });

    testWidgets('a refused Go here still takes the card down and says why', (tester) async {
      // No collector behind this state, so the walk is refused — the card comes down
      // either way, and the refusal is shown rather than swallowed.
      await tester.pumpWidget(wrap(withPersonUnderCentre()));
      await tester.pumpAndSettle();
      await tapFloor(tester);

      await tester.tap(find.text('Go here'));
      await tester.pump();

      expect(find.text('Ada'), findsNothing, reason: 'the card is dropped the moment it is acted on');
      expect(find.text('Not connected to Gather.'), findsOneWidget);
    });

    testWidgets('both actions fit a narrow phone at a large text scale', (tester) async {
      // 375 points wide at 2x text: the avatar, both pills and the close button are all
      // fixed-width, so one Row would run past the edge and clip. The Wrap drops the
      // actions onto a second line rather than overflowing — proven by the absence of a
      // RenderFlex exception with both pills still on screen.
      tester.view.physicalSize = const Size(375, 780);
      tester.view.devicePixelRatio = 1.0;
      tester.platformDispatcher.textScaleFactorTestValue = 2.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

      await tester.pumpWidget(wrap(withPersonUnderCentre()));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(187, 390));
      await tester.pump();

      expect(tester.takeException(), isNull, reason: 'no RenderFlex overflow at 2x text');
      expect(find.text('Go here'), findsOneWidget);
      expect(find.text('Wave'), findsOneWidget);
    });
  });

  group('framing', () {
    // A phone, and the office as it is laid out on one: 124×82 tiles covering the
    // height exactly and overflowing sideways.
    const viewport = Size(390, 780);
    const child = Size(1178.78, 780);

    test('there is never anything on screen that is not map', () {
      // Aiming past the right-hand edge stops with the edge on the edge, rather than
      // centring the point and letting the background in beside it.
      final past = framedOn(
        at: const Offset(1178.78, 400),
        viewport: viewport,
        child: child,
        zoom: 1,
      );
      expect(past.getTranslation().x, closeTo(viewport.width - child.width, 0.01));
      expect(past.getTranslation().y, closeTo(0, 0.01));

      // And the other corner, which clamps the other way.
      final origin = framedOn(at: Offset.zero, viewport: viewport, child: child, zoom: 1);
      expect(origin.getTranslation().x, closeTo(0, 0.01));
      expect(origin.getTranslation().y, closeTo(0, 0.01));
    });

    test('a point with room around it is simply centred', () {
      final centred = framedOn(
        at: const Offset(400, 300),
        viewport: viewport,
        child: child,
        zoom: 3,
      );
      expect(centred.getMaxScaleOnAxis(), 3);
      expect(centred.getTranslation().x, closeTo(390 / 2 - 3 * 400, 0.01));
      expect(centred.getTranslation().y, closeTo(780 / 2 - 3 * 300, 0.01));
    });

    test('and the zoom itself cannot go below covering the screen', () {
      final out = framedOn(at: const Offset(400, 300), viewport: viewport, child: child, zoom: 0.2);
      expect(out.getMaxScaleOnAxis(), kMinZoom);
    });
  });

  testWidgets('the app bar names the space and nothing else', (tester) async {
    // It used to carry a second line: the room you were standing in, falling back
    // to the floor's size in tiles. Both are gone — the area name changed as you
    // walked, which put a flickering line directly under one that does not move,
    // and the map already writes the zone names on the floor.
    final state = AppState()
      ..debugApplyLink(const LinkStatus(LinkState.live))
      ..debugMap = _map(rooms: const [
        SpaceRoom(
          id: 'r1',
          name: 'Green Park',
          type: 'Common',
          x: 4,
          y: 4,
          width: 4,
          height: 4,
          walled: false,
        ),
      ])
      ..debugApplyRoster(Roster(
        selfId: 'me',
        rows: [_row('me', 5, 5)],
        spaceName: 'Test Space',
      ));

    await tester.pumpWidget(wrap(state));
    await tester.pump();

    expect(find.text('Test Space'), findsOneWidget);
    expect(find.text('Green Park'), findsNothing, reason: 'standing in it is not news');
    expect(find.text('20×10 tiles'), findsNothing);
  });

  testWidgets('a teleport is drawn from both ends at once', (tester) async {
    // Two bodies of the same person on the map for a moment — one dissolving where
    // they were, one arriving where they went — plus a name plate faded through its
    // own layer. Nothing here has a widget to find, so what this pins is the paint
    // itself: a ghost sorted into the depth list at the wrong end, or a `saveLayer`
    // without its `restore`, throws rather than merely looking wrong.
    final state = AppState()
      ..debugApplyLink(const LinkStatus(LinkState.live))
      ..debugMap = _map()
      ..debugApplyRoster(Roster(selfId: 'me', rows: [_row('me', 1, 1, name: 'Me')]));

    await tester.pumpWidget(wrap(state));
    await tester.pump();

    state.debugTeleport('me', 18, 8);
    await tester.pump();

    // The rosters that follow a hop still name the tile it left, for up to the 250ms
    // the collector coalesces over. The map must not walk anybody back to it.
    state.debugApplyRoster(Roster(selfId: 'me', rows: [_row('me', 1, 1, name: 'Me')]));
    await tester.pump(const Duration(milliseconds: 60));
    await tester.pump(const Duration(milliseconds: 60));

    // Then Gather catches up and says the same thing we did.
    state.debugApplyRoster(Roster(selfId: 'me', rows: [_row('me', 18, 8, name: 'Me')]));
    await tester.pump(const Duration(milliseconds: 120));
    await tester.pump(const Duration(milliseconds: 200));

    expect(tester.takeException(), isNull);
    expect(find.text('1 here'), findsOneWidget, reason: 'one person, however many bodies');
  });

  /// Reported as "sometimes only the floor, the walls and the users render", and
  /// then it fixes itself after half a minute. It is not a fetch that failed: the
  /// dump is four chunks, and the 93 `MapArea` rows that make the floor drawable
  /// land well before the 477 `CatalogItemVariant` rows that say what the 1140
  /// pieces of furniture look like. So the office paints in full colour with no
  /// desks in it — and because the cache has fetched every picture that office
  /// asked for, it was *settled*, the legend hid itself, and nothing on screen
  /// said the office was still arriving.
  group('an office that is still arriving', () {
    SpaceArt art({required int awaiting}) => SpaceArt(
          width: 20 * artTileSize.toDouble(),
          height: 10 * artTileSize.toDouble(),
          ground: const [],
          props: const [],
          awaiting: awaiting,
        );

    testWidgets('says so, even though there is nothing left to fetch', (tester) async {
      final state = AppState()
        ..debugApplyLink(const LinkStatus(LinkState.live))
        ..debugMap = _map()
        ..debugArt = art(awaiting: 12);

      await tester.pumpWidget(wrap(state));
      await tester.pump();

      expect(find.textContaining('furniture is still arriving'), findsOneWidget);
      expect(find.textContaining('12'), findsOneWidget);
    });

    testWidgets('and goes quiet once the catalog has landed', (tester) async {
      final state = AppState()
        ..debugApplyLink(const LinkStatus(LinkState.live))
        ..debugMap = _map()
        ..debugArt = art(awaiting: 0);

      await tester.pumpWidget(wrap(state));
      await tester.pump();

      expect(find.textContaining('still arriving'), findsNothing);
      expect(find.textContaining('Drawing the office'), findsNothing);
    });
  });

  group('shut doors', () {
    // `canBeEnteredBy`, which is the rule behind `isPermittedToMoveTo`. Three of its
    // five clauses are answerable from a roster and a floor plan; these are those.
    SpaceRoom door({
      String type = 'MeetingRoom',
      bool locked = true,
      String? stableId,
    }) =>
        SpaceRoom(
          id: 'area-1',
          name: 'Boardroom',
          type: type,
          x: 0,
          y: 0,
          width: 20,
          height: 10,
          walled: true,
          locked: locked,
          stableId: stableId,
        );

    AppState standing(SpaceRoom room, {String? deskId, num x = 4, num y = 4}) =>
        AppState()
          ..debugApplyLink(const LinkStatus(LinkState.live))
          ..debugMap = _map(rooms: [room])
          ..debugApplyRoster(Roster(selfId: 'me', rows: [
            RosterRow(id: 'me', x: x, y: y, floorId: 'f1', connected: true, deskId: deskId),
          ]));

    test('an unlocked room is open to anybody', () {
      final room = door(locked: false);
      expect(standing(room).canEnter(room), isTrue);
    });

    test('a locked one is not', () {
      // No desk of ours, and standing outside it — the floor is 20x10 and the room
      // covers all of it, so "outside" has to be off the map.
      final room = door(stableId: 'boardroom');
      expect(standing(room, x: -5, y: -5).canEnter(room), isFalse);
    });

    test('my own locked desk is still mine to walk into', () {
      // Clause 2. `deskId` is a `MapEntityIdentifier` id, so it matches `stableId`
      // and never `id` — matching the wrong one finds nothing and locks you out of
      // your own desk, which is the bug this pins.
      final desk = door(type: 'Desk', stableId: 'desk-1');
      expect(standing(desk, deskId: 'desk-1').canEnter(desk), isTrue);
      // From outside it, since standing inside is a clause of its own.
      expect(standing(desk, deskId: 'someone-elses', x: -5, y: -5).canEnter(desk), isFalse);
    });

    test('and so is the room I am already inside', () {
      // Clause 5. The client logs this case as "should never happen" and then allows
      // it, because the alternative is being unable to move within a room somebody
      // locked around you.
      final room = door(stableId: 'boardroom');
      expect(standing(room).canEnter(room), isTrue);
    });

    SpaceRoom boardroom({Set<String> admits = const {}}) => SpaceRoom(
          id: 'area-1',
          name: 'Boardroom',
          type: 'MeetingRoom',
          x: 0,
          y: 0,
          width: 20,
          height: 10,
          walled: true,
          locked: true,
          stableId: 'boardroom',
          admits: admits,
        );

    test('a room I was let into is mine to walk to', () {
      // Clause 4, end to end. This is the case the local rule used to get wrong: an
      // accepted access request is exactly "somebody let me in", and refusing it was
      // a door the phone could not open even though Gather would have.
      final room = boardroom(admits: const {'me'});
      expect(standing(room, x: -5, y: -5).canEnter(room), isTrue);
    });

    test('but not one somebody else was let into', () {
      final room = boardroom(admits: const {'ada'});
      expect(standing(room, x: -5, y: -5).canEnter(room), isFalse);
    });

    test('a refusal from Gather stops the walk and names the room', () async {
      final room = door(stableId: 'boardroom');
      final state = standing(room, x: -5, y: -5)..debugOnRoute = true;
      final said = <String>[];
      final sub = state.notices.listen(said.add);
      addTearDown(sub.cancel);

      state.debugNoteEvent(BusEvent(
        name: 'UserIsNotPermittedToEnterLockedArea',
        senderId: null,
        sentTime: null,
        targetUserIds: const ['me'],
        payload: const {'spaceUserId': 'me', 'areaId': 'boardroom'},
      ));
      await Future<void>.delayed(Duration.zero);

      expect(said, ['Boardroom is locked.']);
    });

    test('a refusal aimed at somebody else is not ours to report', () async {
      final room = door(stableId: 'boardroom');
      final state = standing(room, x: -5, y: -5);
      final said = <String>[];
      final sub = state.notices.listen(said.add);
      addTearDown(sub.cancel);

      state.debugNoteEvent(BusEvent(
        name: 'UserIsNotPermittedToEnterLockedArea',
        senderId: null,
        sentTime: null,
        targetUserIds: const ['ada'],
        payload: const {'spaceUserId': 'ada', 'areaId': 'boardroom'},
      ));
      await Future<void>.delayed(Duration.zero);

      expect(said, isEmpty);
    });

    test('a meeting refuses in its own words', () async {
      final room = door(stableId: 'boardroom');
      final state = standing(room, x: -5, y: -5);
      final said = <String>[];
      final sub = state.notices.listen(said.add);
      addTearDown(sub.cancel);

      state.debugNoteEvent(BusEvent(
        name: 'UserIsNotPermittedToEnterMeetingArea',
        senderId: null,
        sentTime: null,
        targetUserIds: const ['me'],
        payload: const {'spaceUserId': 'me', 'meetingId': 'meeting-1'},
      ));
      await Future<void>.delayed(Duration.zero);

      expect(said, ['That meeting is private.']);
    });

    testWidgets('and the sentence reaches the screen', (tester) async {
      final room = door(stableId: 'boardroom');
      final state = standing(room, x: -5, y: -5);
      await tester.pumpWidget(wrap(state));
      await tester.pump();

      state.debugNoteEvent(BusEvent(
        name: 'UserIsNotPermittedToEnterLockedArea',
        senderId: null,
        sentTime: null,
        targetUserIds: const ['me'],
        payload: const {'spaceUserId': 'me', 'areaId': 'boardroom'},
      ));
      await tester.pump();
      await tester.pump();

      expect(find.text('Boardroom is locked.'), findsOneWidget);
    });
  });

  group('dancing', () {
    /// The one pose that cannot be derived from anything else on the screen.
    ///
    /// Sitting comes from the tile under the body and talking from `speaking`, but
    /// no coordinate says somebody pressed the dance key. The field was on the wire
    /// and the sheet has had the cycle (frames 12–15 at 7fps) all along; what was
    /// missing was the six inches of pipe between them, so a dancing colleague
    /// rendered as standing perfectly still.
    AppState danced({required bool me, required bool them}) {
      final state = AppState();
      state.debugApplyRoster(Roster(selfId: 'me', rows: [
        RosterRow(
            id: 'me',
            name: 'Me',
            x: 1,
            y: 1,
            floorId: 'f1',
            connected: true,
            availability: 'Active',
            dancing: me),
        RosterRow(
            id: 'ada',
            name: 'Ada',
            x: 2,
            y: 1,
            floorId: 'f1',
            connected: true,
            availability: 'Active',
            dancing: them),
      ]));
      return state;
    }

    test('reaches the map for somebody else', () {
      final state = danced(me: false, them: true);
      addTearDown(state.dispose);
      expect(state.peopleOnMap.single.dancing, isTrue);
    });

    test('and for me', () {
      final state = danced(me: true, them: false);
      addTearDown(state.dispose);
      expect(state.mePerson?.dancing, isTrue);
      expect(state.peopleOnMap.single.dancing, isFalse);
    });

    test('is false, not null, for a row that has never carried the field', () {
      final state = AppState();
      addTearDown(state.dispose);
      state.debugApplyRoster(const Roster(selfId: 'me', rows: [
        RosterRow(id: 'me', name: 'Me', x: 1, y: 1, floorId: 'f1', connected: true),
        RosterRow(
            id: 'ada', name: 'Ada', x: 2, y: 1, floorId: 'f1', connected: true,
            availability: 'Active'),
      ]));

      expect(state.mePerson?.dancing, isFalse);
      expect(state.peopleOnMap.single.dancing, isFalse);
    });
  });

  group('an action Gather would not run', () {
    /// The other half of the same silence.
    ///
    /// `UserIsNotPermittedToEnter…` above is the permission gate *inside* the move —
    /// the action ran, returned `Success`, and refused to write a position. This is
    /// the layer above it, where the action never ran at all: arguments are
    /// validated first, so a bad one executes nothing, produces no patch, and
    /// publishes no event. The only evidence is `actionReturns`, and until it was
    /// read the app went on telling people their status had been set.
    test('is said out loud, in terms of the thing that did not happen', () async {
      final state = AppState();
      addTearDown(state.dispose);
      final said = <String>[];
      final sub = state.notices.listen(said.add);
      addTearDown(sub.cancel);

      state.debugNoteRefusal(const ActionRefused(
        action: 'setCustomStatus',
        message: 'text: String must contain at most 80 character(s)',
      ));
      await Future<void>.delayed(Duration.zero);

      expect(said, [
        'Gather would not change your status: '
            'text: String must contain at most 80 character(s)',
      ]);
    });

    test('an action nobody has written a phrase for still gets through', () async {
      // Naming it badly beats swallowing it. The action id is at least searchable.
      final state = AppState();
      addTearDown(state.dispose);
      final said = <String>[];
      final sub = state.notices.listen(said.add);
      addTearDown(sub.cancel);

      state.debugNoteRefusal(const ActionRefused(action: 'claimDesk', message: 'Taken'));
      await Future<void>.delayed(Duration.zero);

      expect(said, ['Gather refused claimDesk: Taken']);
    });

    test('a burst of the same refusal is one sentence, not two hundred', () async {
      // The actions most likely to be refused are the ones sent in bursts: a held
      // D-pad is seven steps a second and a go-kart twenty-one. If the server starts
      // refusing `move`, the first one is the news.
      final state = AppState();
      addTearDown(state.dispose);
      final said = <String>[];
      final sub = state.notices.listen(said.add);
      addTearDown(sub.cancel);

      for (var i = 0; i < 20; i++) {
        state.debugNoteRefusal(const ActionRefused(action: 'move', message: 'nope'));
      }
      await Future<void>.delayed(Duration.zero);

      expect(said, ['Gather would not move you: nope']);
    });

    test('but a different refusal is different news', () async {
      final state = AppState();
      addTearDown(state.dispose);
      final said = <String>[];
      final sub = state.notices.listen(said.add);
      addTearDown(sub.cancel);

      state.debugNoteRefusal(const ActionRefused(action: 'move', message: 'nope'));
      state.debugNoteRefusal(const ActionRefused(action: 'move', message: 'still nope'));
      state.debugNoteRefusal(const ActionRefused(action: 'broadcastEmote', message: 'nope'));
      await Future<void>.delayed(Duration.zero);

      expect(said, hasLength(3));
    });
  });

  // The handheld's camera, mounted. The sibling signal tests in gameboy_mode_test
  // pin that a D-pad walk fires [AppState.recentre]; these pin what the map then
  // does with it — the `_locked` ticker that keeps the avatar dead-centre, eases to
  // the fixed walking zoom, clamps at the office edge, lets a finger-pan break the
  // lock and re-grabs it on the next walk. Asserted against [framedOn] on a fixed
  // viewport, so a regression in the state machine fails here rather than sailing
  // through green.
  group('the Gameboy handheld camera', () {
    // A phone-shaped LCD, sized so the floor overflows it in both axes at the
    // walking zoom — which is what makes the edge clamp something to test.
    const viewport = Size(390, 780);

    /// The office, in Gameboy mode, with me standing on the given tile.
    AppState handheld({required num x, required num y}) => AppState()
      ..debugApplyLink(const LinkStatus(LinkState.live))
      ..debugCanWalk = true
      ..debugMap = _map()
      ..setGameboyMode(true)
      ..debugApplyRoster(Roster(selfId: 'me', rows: [_row('me', x, y, name: 'Me')]));

    /// The live transform the screen is holding — the InteractiveViewer's own.
    Matrix4 cameraOf(WidgetTester tester) => tester
        .widget<InteractiveViewer>(find.byType(InteractiveViewer))
        .transformationController!
        .value;

    /// The same frame the locked ticker is aiming for: me centred, edge-clamped,
    /// at the fixed walking zoom. `_covered` is zero here (the test view carries no
    /// bottom padding), so the ticker's centre and this one line up.
    Matrix4 centredOn(num x, num y) {
      final base = math.max(
        viewport.height / (10 * artTileSize),
        viewport.width / (20 * artTileSize),
      );
      final child = Size(20 * artTileSize * base, 10 * artTileSize * base);
      return framedOn(
        at: Offset((x + 0.5) * artTileSize * base, (y + 0.5) * artTileSize * base),
        viewport: viewport,
        child: child,
        zoom: 3,
      );
    }

    Future<void> mount(WidgetTester tester, AppState state) async {
      tester.view.physicalSize = viewport;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(wrap(state));
      await tester.pump(); // layout, _centreOnMe engages the lock, the ticker starts
      await tester.pump(const Duration(seconds: 1)); // the zoom eases home
    }

    testWidgets('locks the avatar to the centre at the fixed walking zoom', (tester) async {
      final state = handheld(x: 10, y: 5);
      await mount(tester, state);

      final cam = cameraOf(tester);
      final want = centredOn(10, 5);
      expect(cam.getMaxScaleOnAxis(), closeTo(3, 0.02), reason: 'eased to the walking zoom');
      expect(cam.getTranslation().x, closeTo(want.getTranslation().x, 0.5),
          reason: 'the avatar sits in the middle of the LCD');
      expect(cam.getTranslation().y, closeTo(want.getTranslation().y, 0.5));
    });

    testWidgets('clamps at the office edge rather than showing the void', (tester) async {
      // Top-left corner: centring it dead-centre would pull the map's edge off the
      // viewport's, so [framedOn] clamps and the corner sits in the corner.
      final state = handheld(x: 0, y: 0);
      await mount(tester, state);

      final cam = cameraOf(tester);
      expect(cam.getMaxScaleOnAxis(), closeTo(3, 0.02));
      expect(cam.getTranslation().x, closeTo(0, 0.5), reason: 'no void left of the office');
      expect(cam.getTranslation().y, closeTo(0, 0.5), reason: 'no void above it');
    });

    testWidgets('a finger-pan breaks the lock and the view stays where it is dragged', (tester) async {
      final state = handheld(x: 10, y: 5);
      await mount(tester, state);
      final locked = cameraOf(tester);

      // A drag on the floor takes the camera back: [_stopFollowing] drops the lock
      // and stops the ticker, so the dragged-to transform is left in place.
      await tester.drag(find.byType(InteractiveViewer), const Offset(-60, -60));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1)); // a still-locked ticker would yank it back

      final panned = cameraOf(tester);
      final moved = (panned.getTranslation().x - locked.getTranslation().x).abs() +
          (panned.getTranslation().y - locked.getTranslation().y).abs();
      expect(moved, greaterThan(20),
          reason: 'the pan stuck — the camera was not pinned back to centre');
    });

    testWidgets('a D-pad walk re-grabs the lock after a pan let it go', (tester) async {
      final state = handheld(x: 10, y: 5);
      await mount(tester, state);

      await tester.drag(find.byType(InteractiveViewer), const Offset(-60, -60));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      // The D-pad fires [AppState.recentre] in Gameboy mode; the map re-engages the
      // centred lock. The walk plumbing is null in a test, so the avatar does not
      // actually step — the camera comes home to where it already stood.
      state.walk('Up');
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      final cam = cameraOf(tester);
      final want = centredOn(10, 5);
      expect(cam.getMaxScaleOnAxis(), closeTo(3, 0.02), reason: 're-grabbed and re-settled');
      expect(cam.getTranslation().x, closeTo(want.getTranslation().x, 0.5),
          reason: 'back to centre after the re-grab');
      expect(cam.getTranslation().y, closeTo(want.getTranslation().y, 0.5));
    });
  });
}
