/// [Walk] is what stands between a thumb and the office wall.
///
/// The `move` action does not check anything — its whole body is
/// `position += direction.toPositionDelta()` — so every rule about where an avatar
/// may go is enforced here or nowhere. Two of them are load-bearing:
///
///  1. **Never step into somewhere a body does not fit**, which is the same rule the
///     desktop client applies before it sends the same action.
///  2. **Know which tile you are on**, which the roster cannot answer on its own: it
///     is coalesced at 250ms while a walk runs at seven tiles a second, so it is
///     always describing a tile you left two steps ago.
library;

import 'package:gather_client/gather_client.dart';
import 'package:test/test.dart';

/// An open floor with nothing on it.
SpaceMap _open({int width = 20, int height = 20}) => SpaceMap(
      floorId: 'f1',
      width: width,
      height: height,
      blocked: const {},
      rooms: const [],
    );

/// A floor with a desk at (5,5) and a wall between (8,y) and (9,y) for every y.
///
/// Both kinds of obstacle in one fixture, because the interesting thing about them is
/// that they are enforced by different rules: the desk is a blocked *tile* and the
/// wall is a blocked *line*.
SpaceMap _obstructed() => SpaceMap(
      floorId: 'f1',
      width: 20,
      height: 20,
      blocked: {5 * 20 + 5},
      // The line on the west side of column 9, which is `(tile * 2) + 1`.
      edges: {for (var y = 0; y < 20; y++) ((y * 20 + 9) * 2) + 1},
      rooms: const [],
    );

/// A collector that records steps instead of sending them.
class _FakeCollector implements DirectCollector {
  final List<String> steps = [];

  /// Every gear change, in order. Gather hears about these separately from the steps
  /// and they are the only thing that puts a kart under the avatar on anybody else's
  /// screen, so "did we send it" is worth asserting on its own.
  final List<Gait> gaits = [];
  bool refuse = false;

  @override
  String? get selfId => 'me-1';

  @override
  ({bool ok, String? detail}) move({required String direction}) {
    if (refuse) return (ok: false, detail: 'not connected to Gather');
    steps.add(direction);
    return (ok: true, detail: null);
  }

  @override
  ({bool ok, String? detail}) setGait(Gait gait) {
    // A socket that refuses steps refuses gear changes too, which is the whole of the
    // "left parked in a go-kart" case: `drive` landed, and then the `walk` did not.
    if (refuse) return (ok: false, detail: 'not connected to Gather');
    gaits.add(gait);
    return (ok: true, detail: null);
  }

  @override
  Object? noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Roster _at(num x, num y) => Roster(
      selfId: 'me-1',
      rows: [RosterRow(id: 'me-1', x: x, y: y, floorId: 'f1', connected: true)],
    );

void main() {
  late _FakeCollector collector;
  late SpaceMap map;
  Walk? walk;

  setUp(() {
    collector = _FakeCollector();
    map = _open();
  });
  tearDown(() async {
    await walk?.dispose();
    walk = null;
  });

  /// Built with a very long interval so nothing repeats on its own: every test that
  /// wants a second step asks for one. Timers in a test are a source of flakes, and
  /// [Walk.step] is public precisely so they are not needed.
  Walk build() => walk = Walk(
        collector: () => collector,
        map: () => map,
        interval: const Duration(hours: 1),
      );

  group('before it knows anything', () {
    test('a press with no position sends nothing', () {
      // The first thing a step needs is the tile to judge it from. Guessing would be
      // guessing about somebody's real avatar in a real workspace.
      final w = build();
      w.press('Right');

      expect(collector.steps, isEmpty);
      expect(w.at, isNull);
    });

    test('a press with no floor plan sends nothing', () {
      // Without the map there is no collision rule to apply, and the office footprint
      // is 96x52 of a 124x82 grid — the emptiness around it is walkable as far as the
      // game server is concerned, so an unchecked step walks out of the building.
      final w = walk = Walk(
        collector: () => collector,
        map: () => null,
        interval: const Duration(hours: 1),
      )..noteRoster(_at(4, 4));
      w.press('Right');

      expect(w.step().detail, 'still reading the floor plan');
      expect(collector.steps, isEmpty);
      expect(w.at, (x: 4, y: 4), reason: 'where the roster left it');
    });
  });

  group('stepping', () {
    test('a press steps at once rather than waiting out a tick', () {
      // A quarter-second of nothing after a press reads as the button having missed
      // it, which on a control is worse than a slow walk.
      final w = build()..noteRoster(_at(4, 4));
      w.press('Right');

      expect(collector.steps, ['Right']);
      expect(w.at, (x: 5, y: 4));
      expect(w.direction, 'Right');
      expect(w.walking, isTrue);
    });

    test('each direction moves the way Gather means it', () {
      // `toPositionDelta`, and the one worth stating: y grows downwards, so Up is
      // towards the top of the map.
      for (final (direction, expected) in [
        ('Up', (x: 4, y: 3)),
        ('Down', (x: 4, y: 5)),
        ('Left', (x: 3, y: 4)),
        ('Right', (x: 5, y: 4)),
      ]) {
        final w = Walk(collector: () => collector, map: () => map)
          ..noteRoster(_at(4, 4));
        addTearDown(w.dispose);
        w.press(direction);
        expect(w.at, expected, reason: direction);
        w.release();
      }
    });

    test('holding walks tile after tile', () {
      final w = build()..noteRoster(_at(4, 4));
      w.press('Right');
      w.step();
      w.step();

      expect(collector.steps, ['Right', 'Right', 'Right']);
      expect(w.at, (x: 7, y: 4));
    });

    test('a release stops it, and stepping after one does nothing', () {
      final w = build()..noteRoster(_at(4, 4));
      w.press('Right');
      w.release();

      expect(w.walking, isFalse);
      expect(w.direction, isNull);
      expect(w.step().detail, 'nothing is held');
      expect(collector.steps, hasLength(1));
    });

    test('sliding a thumb to another arrow turns without stopping', () {
      // The reason the pad is one pointer rather than four buttons: going round a
      // corner should not need the thumb lifted.
      final w = build()..noteRoster(_at(4, 4));
      w.press('Right');
      w.press('Down');

      expect(collector.steps, ['Right', 'Down']);
      expect(w.at, (x: 5, y: 5));
    });

    test('pressing the arrow already held is not a second step', () {
      // The pad calls `press` on every pointer move, which is many times a frame.
      // Taking each one would walk at the rate the finger jitters.
      final w = build()..noteRoster(_at(4, 4));
      w.press('Right');
      w.press('Right');
      w.press('Right');

      expect(collector.steps, ['Right']);
    });

    test('a direction Gather has no word for is refused', () {
      final w = build()..noteRoster(_at(4, 4));
      w.press('North');

      expect(collector.steps, isEmpty);
      expect(w.walking, isFalse);
    });

    test('a step the socket refuses is not believed', () {
      // Otherwise this walks on ahead of an avatar that never moved, and every
      // collision check after it is measured from a tile nobody is standing on.
      final w = build()..noteRoster(_at(4, 4));
      collector.refuse = true;
      w.press('Right');

      expect(w.at, (x: 4, y: 4));
    });
  });

  group('not walking through the office', () {
    // What "not walking through" means on the wire is worth being precise about. The
    // step is still *sent* — `gameMove` has no collision test in front of it and the
    // model writes `direction` before it consults `setPosition`, so the desktop client
    // turns you to face what stopped you. What must not happen is believing the tile.
    test('into furniture', () {
      map = _obstructed();
      final w = build()..noteRoster(_at(4, 5));
      w.press('Right');

      expect(collector.steps, ['Right'], reason: 'turning to face the desk at (5,5)');
      expect(w.at, (x: 4, y: 5), reason: 'and going nowhere');

      // Only that tile, and only in that direction: a desk beside you is not a reason
      // to be unable to walk past it.
      w.press('Down');
      expect(collector.steps, ['Right', 'Down']);
      expect(w.at, (x: 4, y: 6));
    });

    test('through a wall', () {
      map = _obstructed();
      final w = build()..noteRoster(_at(8, 2));
      w.press('Right');

      expect(collector.steps, ['Right']);
      expect(w.at, (x: 8, y: 2), reason: 'the wall on the west side of column 9');
    });

    test('off the edge of the grid, which is not even sent', () {
      // The one refusal not handed to Gather. `blockedAtPosition` consults the object
      // map and nothing else, so the void outside the building is unoccupied rather
      // than blocked and a move over the edge would likely be *accepted* — a position
      // no client has any art for. Unlike a wall, this one is ours to refuse.
      final w = build()..noteRoster(_at(0, 0));
      w.press('Left');

      expect(collector.steps, isEmpty);
      expect(w.at, (x: 0, y: 0));
      w.press('Right');
      expect(collector.steps, ['Right'], reason: 'and inwards is fine');
    });

    test('a blocked press still counts as held, so the walk resumes on the way out',
        () {
      // Holding Right against a wall and rolling the thumb to Down should walk. A
      // refused step that also cleared the held direction would need the thumb lifted
      // and pressed again.
      map = _obstructed();
      final w = build()..noteRoster(_at(8, 2));
      w.press('Right');
      expect(w.walking, isTrue);

      w.press('Down');
      expect(collector.steps, ['Right', 'Down']);
      expect(w.at, (x: 8, y: 3), reason: 'and only the one that was not a wall landed');
    });
  });

  group('knowing where it is', () {
    test('the first roster is simply believed', () {
      final w = build()..noteRoster(_at(7, 3));
      expect(w.at, (x: 7, y: 3));
    });

    test('a roster describing a tile already left does not drag the walk back', () {
      // The whole reason this class holds a position. Three steps go out inside one
      // 250ms roster window, so the roster that lands next is two tiles stale — and
      // adopting it would rubber-band the avatar backwards and check collision
      // against the wrong tile.
      final w = build()..noteRoster(_at(4, 4));
      w.press('Right');
      w.step();
      w.step();
      expect(w.at, (x: 7, y: 4));

      w.noteRoster(_at(5, 4));
      expect(w.at, (x: 7, y: 4), reason: 'still two steps ahead of the wire');
    });

    test('a roster nobody claimed is the truth, and wins', () {
      // The desktop client drives the same avatar, party mode hops it across the
      // office, and a step can simply be lost. Any of those puts Gather somewhere this
      // never said it was going, and Gather is right.
      final w = build()..noteRoster(_at(4, 4));
      w.press('Right');
      expect(w.at, (x: 5, y: 4));

      w.noteRoster(_at(30, 12));
      expect(w.at, (x: 30, y: 12));
    });

    test('at rest every roster is adopted', () {
      final w = build()..noteRoster(_at(4, 4));
      w.noteRoster(_at(4, 5));
      w.noteRoster(_at(4, 6));

      expect(w.at, (x: 4, y: 6));
    });

    test('a roster with no position for us changes nothing', () {
      final w = build()..noteRoster(_at(4, 4));
      w.noteRoster(const Roster(selfId: 'me-1', rows: []));

      expect(w.at, (x: 4, y: 4));
    });
  });

  group('safety', () {
    test('a hold that outlasts the limit is dropped', () {
      // A finger cannot get lost but an app can: backgrounded mid-press, or a pointer
      // cancelled by a system gesture that never sends the up event. The failure this
      // prevents is a key stuck down in somebody's real workspace.
      var now = DateTime(2026, 8, 13, 9);
      final w = walk = Walk(
        collector: () => collector,
        map: () => map,
        interval: const Duration(hours: 1),
        holdLimit: const Duration(seconds: 30),
        now: () => now,
      )..noteRoster(_at(4, 4));

      w.press('Right');
      now = now.add(const Duration(seconds: 29));
      expect(w.step().ok, isTrue);

      now = now.add(const Duration(seconds: 2));
      expect(w.step().ok, isFalse);
      expect(w.walking, isFalse, reason: 'and it let go rather than just refusing');
    });

    test('the limit is measured from the press, not from the last turn', () {
      // Otherwise sliding a thumb around the pad renews the lease indefinitely, which
      // is exactly what a pocket does to a touchscreen.
      var now = DateTime(2026, 8, 13, 9);
      final w = walk = Walk(
        collector: () => collector,
        map: () => map,
        interval: const Duration(hours: 1),
        holdLimit: const Duration(seconds: 30),
        now: () => now,
      )..noteRoster(_at(4, 4));

      w.press('Right');
      now = now.add(const Duration(seconds: 20));
      w.press('Down');
      now = now.add(const Duration(seconds: 20));

      expect(w.step().ok, isFalse);
      expect(w.walking, isFalse);
    });
  });

  group('walking a route', () {
    /// The route [SpaceMap.routeTo] would hand back for a straight line east.
    List<({int x, int y})> east(int fromX, int y, int toX) =>
        [for (var x = fromX; x <= toX; x++) (x: x, y: y)];

    test('a route steps itself to the end and then stops', () {
      final w = build()..noteRoster(_at(4, 4));
      w.follow(east(4, 4, 7));

      // The first step goes immediately, like a press: the pill was already the
      // confirmation, so waiting out a tick reads as the tap having missed.
      expect(collector.steps, ['Right']);
      expect(w.onRoute, isTrue);

      w.step();
      w.step();
      expect(collector.steps, ['Right', 'Right', 'Right']);
      expect(w.at, (x: 7, y: 4));
      expect(w.onRoute, isFalse, reason: 'arrived');
      expect(w.walking, isFalse, reason: 'and stopped its own timer');

      // Nothing further, however often it is asked.
      expect(w.step().ok, isFalse);
      expect(collector.steps.length, 3);
    });

    test('the direction is derived from the tiles, not carried alongside them', () {
      final w = build()..noteRoster(_at(4, 4));
      w.follow([(x: 4, y: 4), (x: 4, y: 3), (x: 5, y: 3), (x: 5, y: 4)]);
      w.step();
      w.step();

      expect(collector.steps, ['Up', 'Right', 'Down']);
    });

    test('a tap while already walking replaces the old route', () {
      final w = build()..noteRoster(_at(4, 4));
      w.follow(east(4, 4, 9));
      w.follow([(x: 5, y: 4), (x: 5, y: 5)]);

      // One step east from the first route, then the second route takes over — and
      // it is walked from where that step left us rather than from the tile the tap
      // was made on.
      expect(collector.steps, ['Right', 'Down']);
      expect(w.at, (x: 5, y: 5));
      expect(w.onRoute, isFalse);
    });

    test('reaching for the D-pad cancels the route', () {
      // Manual input beats autopilot. Two things stepping one avatar would fight,
      // and the person holding the phone is the one who changed their mind.
      final w = build()..noteRoster(_at(4, 4));
      w.follow(east(4, 4, 9));
      expect(w.onRoute, isTrue);

      w.press('Up');
      expect(w.onRoute, isFalse);
      expect(collector.steps, ['Right', 'Up']);

      w.step();
      expect(collector.steps, ['Right', 'Up', 'Up'], reason: 'the pad has it now');
    });

    test('a chair moved into the route abandons the rest of it', () {
      // The desktop client re-runs its pathfinder every tick and would walk around.
      // This stops instead, because a route walked from a floor plan that has since
      // changed is a route to somewhere nobody asked for. Tapping again re-plans.
      final w = build()..noteRoster(_at(4, 4));
      w.follow(east(4, 4, 8));
      expect(collector.steps, ['Right']);

      map = _obstructed(); // a wall now stands on the west side of column 9
      w.noteRoster(_at(8, 4));

      expect(w.step().ok, isFalse);
      expect(w.onRoute, isFalse);
      expect(w.walking, isFalse);
      expect(collector.steps, ['Right'], reason: 'nothing more went out');
    });

    test('a roster that puts us off the route finds the way again', () {
      // The desktop client moved this same avatar, or a step was dropped. The
      // remaining tiles are now relative to a tile we are not standing on — but the
      // *destination* has not changed, and neither has what somebody asked for. The
      // client re-runs its whole pathfinder every single tick for this reason; this
      // does it when the route stops making sense, which is the same recovery with
      // less arithmetic.
      final w = build()..noteRoster(_at(4, 4));
      w.follow(east(4, 4, 9));
      expect(collector.steps, ['Right']);

      w.noteRoster(_at(12, 17));
      expect(w.step().ok, isTrue);
      expect(w.onRoute, isTrue, reason: 'the walk carries on from where we really are');
      // (12,17) to the goal at (9,4) is up and to the left, so the new route is not
      // the old one continued.
      expect(collector.steps.last, anyOf('Up', 'Left'));
    });

    test('a correction that lands on the goal is an arrival, not a failure', () {
      // Re-planning from the goal answers a route of one tile, and calling that
      // "lost the way there" would put a sentence on screen about a walk that went
      // perfectly well.
      final w = build()..noteRoster(_at(4, 4));
      w.follow(east(4, 4, 9));

      w.noteRoster(_at(9, 4));
      expect(w.step(), (ok: false, detail: 'already there'));
      expect(w.onRoute, isFalse);
    });

    test('a route that cannot be re-planned does give up', () {
      // Sealed in. There is nowhere to re-plan *to*, so the walk ends rather than
      // spending a search per tick forever.
      map = SpaceMap(
        floorId: 'f1',
        width: 20,
        height: 20,
        // A ring of furniture around (12,17), so a route out of it does not exist.
        blocked: {
          for (var dx = -1; dx <= 1; dx++)
            for (var dy = -1; dy <= 1; dy++)
              if (dx != 0 || dy != 0) (17 + dy) * 20 + (12 + dx),
        },
        rooms: const [],
      );
      final w = build()..noteRoster(_at(4, 4));
      w.follow(east(4, 4, 9));

      w.noteRoster(_at(12, 17));
      expect(w.step(), (ok: false, detail: 'lost the way there'));
      expect(w.onRoute, isFalse);
    });

    test('a roster that has merely not caught up does not stop the walk', () {
      // The ordinary case, and the one the previous test must not swallow: the
      // roster is coalesced at 250ms and a route runs at seven tiles a second, so it
      // is always describing a tile we left. `_pending` already knows that.
      final w = build()..noteRoster(_at(4, 4));
      w.follow(east(4, 4, 8));
      w.step();
      w.step();
      expect(w.at, (x: 7, y: 4));

      w.noteRoster(_at(5, 4)); // two steps behind
      expect(w.at, (x: 7, y: 4), reason: 'a tile we claimed is not a correction');
      expect(w.step().ok, isTrue);
      expect(collector.steps, ['Right', 'Right', 'Right', 'Right']);
      expect(w.onRoute, isFalse);
    });

    test('a route is not dropped for outlasting the hold limit', () {
      // A finite list ends itself. The limit is there for a pointer that never
      // lifted, and the longest route this floor can produce is within a tile or two
      // of thirty seconds' walking.
      var now = DateTime(2026, 8, 13, 9);
      final w = walk = Walk(
        collector: () => collector,
        map: () => map,
        interval: const Duration(hours: 1),
        holdLimit: const Duration(seconds: 30),
        now: () => now,
      )..noteRoster(_at(4, 4));

      w.follow(east(4, 4, 7));
      now = now.add(const Duration(minutes: 5));

      expect(w.step().ok, isTrue);
      expect(w.onRoute, isTrue);
    });

    test('the end of a route is announced, so a screen can stop saying "Stop"', () {
      // The roster that follows the last step is up to a quarter of a second behind
      // it, and the map's pill offers to cancel the walk for exactly as long as one
      // is running.
      var ended = 0;
      final w = walk = Walk(
        collector: () => collector,
        map: () => map,
        interval: const Duration(hours: 1),
        onRouteEnded: () => ended++,
      )..noteRoster(_at(4, 4));

      w.follow(east(4, 4, 6));
      expect(ended, 0, reason: 'still walking');

      w.step();
      expect(w.onRoute, isFalse);
      expect(ended, 1, reason: 'arrived');

      // Not on a held direction being let go — nothing was routed.
      w.press('Up');
      w.release();
      expect(ended, 1);
    });

    test('a route that only names the tile we are on is not a walk', () {
      final w = build()..noteRoster(_at(4, 4));
      w.follow([(x: 4, y: 4)]);

      expect(collector.steps, isEmpty);
      expect(w.onRoute, isFalse);
      expect(w.walking, isFalse);
    });

    test('a step the socket refuses ends the route rather than walking on', () {
      final w = build()..noteRoster(_at(4, 4));
      collector.refuse = true;
      w.follow(east(4, 4, 8));

      expect(collector.steps, isEmpty);
      expect(w.onRoute, isFalse);
      expect(w.at, (x: 4, y: 4), reason: 'and nothing was believed');
    });
  });

  group('how fast', () {
    // Wide enough to actually walk a driving-length route to its end. The default
    // twenty-tile floor runs out at the far wall, which stops the route early and
    // takes the deceleration with it.
    setUp(() => map = _open(width: 60));

    /// The route [SpaceMap.routeTo] hands back for a straight line east, [tiles] long
    /// counting the one being stood on — which is what both of the gait rules measure.
    List<({int x, int y})> route(int tiles) =>
        [for (var x = 0; x < tiles; x++) (x: 4 + x, y: 4)];

    group('picking a gear', () {
      // `calculateSpeedModifierForPathStarting`: the seven it subtracts is the tail
      // every route spends slowing down, so the thresholds are cruising distance and
      // the boundaries land at 13 and 23 rather than at 6 and 16.
      test('a walk to the next desk is a walk', () {
        expect(gaitToSetOff(1), Gait.walking);
        expect(gaitToSetOff(13), Gait.walking);
      });

      test('across the room is a run', () {
        expect(gaitToSetOff(14), Gait.running);
        expect(gaitToSetOff(23), Gait.running);
      });

      test('across the office is worth the go-kart', () {
        expect(gaitToSetOff(24), Gait.driving);
        expect(gaitToSetOff(90), Gait.driving);
      });
    });

    group('slowing down', () {
      // `calculateSpeedModifierForPathRemaining`, whose `Math.min` is the whole of it.
      test('the last six tiles of anything are walked', () {
        expect(gaitFor(6, Gait.driving), Gait.walking);
        expect(gaitFor(1, Gait.driving), Gait.walking);
      });

      test('the ten before those are run', () {
        expect(gaitFor(7, Gait.driving), Gait.running);
        expect(gaitFor(16, Gait.driving), Gait.running);
      });

      test('anything further off is driven', () {
        expect(gaitFor(17, Gait.driving), Gait.driving);
      });

      test('a route never goes faster than it set off', () {
        // The ceiling is fixed at the off, so a long walk that began as a walk stays
        // one — this is what stops a route accelerating in its own middle.
        expect(gaitFor(40, Gait.walking), Gait.walking);
        expect(gaitFor(40, Gait.running), Gait.running);
      });
    });

    test('a long route sets off in the kart and tells Gather so', () {
      final w = build()..noteRoster(_at(4, 4));
      w.follow(route(30));

      expect(w.gait, Gait.driving);
      expect(collector.gaits, [Gait.driving]);
    });

    test('a short one neither speeds up nor says anything', () {
      final w = build()..noteRoster(_at(4, 4));
      w.follow(route(8));

      expect(w.gait, Gait.walking);
      // Nothing changed, so nothing is sent. `setSpeedModifier` returns false on an
      // unchanged gait for exactly this reason.
      expect(collector.gaits, isEmpty);
    });

    test('a route slows into its destination and announces each gear', () {
      // Long enough to start driving, and stepped all the way to the end so both
      // downshifts happen.
      final w = build()..noteRoster(_at(4, 4));
      w.follow(route(30));
      while (w.onRoute) {
        w.step();
      }

      expect(collector.gaits, [Gait.driving, Gait.running, Gait.walking]);
      expect(collector.steps.length, 29, reason: 'thirty tiles is twenty-nine steps');
    });

    test('a gear change shortens the step it is announced on', () {
      final w = build()..noteRoster(_at(4, 4));
      expect(w.pace, const Duration(hours: 1));

      w.follow(route(30));
      expect(w.pace, const Duration(minutes: 20), reason: 'an hour divided by three');
    });

    test('climbing into the kart costs a beat of standing still', () {
      // At the real pace, because the pause is an absolute 285.714ms and only means
      // anything measured against a real interval. Six decrements of a 47.619ms
      // driving step clear it — six rather than two precisely because the interval
      // divides with the gait, so this is the timing rule tested without a clock.
      final w = walk = Walk(
        collector: () => collector,
        map: () => map,
        interval: walkStep,
      )..noteRoster(_at(4, 4));

      w.follow(route(30));
      expect(collector.steps, isEmpty, reason: 'the first step is swallowed by the kart');

      var refused = 1;
      while (collector.steps.isEmpty) {
        final out = w.step();
        if (out.ok) break;
        expect(out.detail, 'getting into the go-kart');
        refused++;
        expect(refused, lessThan(10), reason: 'and it does end');
      }
      expect(refused, 5);
      expect(w.gait, Gait.driving, reason: 'and then it drives');
    });

    test('stopping gets out of the kart', () {
      final w = build()..noteRoster(_at(4, 4));
      w.follow(route(30));
      collector.gaits.clear();

      w.release();

      expect(w.gait, Gait.walking);
      expect(collector.gaits, [Gait.walking],
          reason: 'an avatar left parked in one is what everybody else keeps seeing');
    });

    test('a room is walked through however far there is left to go', () {
      // The area rule outranks the distance, and it is the current tile that decides:
      // `if (area && !area.isPublicWalkway) return WALKING`.
      map = SpaceMap(
        floorId: 'f1',
        width: 20,
        height: 20,
        blocked: const {},
        rooms: const [
          SpaceRoom(id: 'r1', name: 'Green Park', type: 'MeetingRoom', x: 3, y: 3, width: 4, height: 4, walled: true),
        ],
      );
      final w = build()..noteRoster(_at(4, 4));
      w.follow(route(30));

      expect(w.gait, Gait.walking);
      expect(collector.gaits, isEmpty);
    });

    test('a public walkway is driven across', () {
      map = SpaceMap(
        floorId: 'f1',
        width: 20,
        height: 20,
        blocked: const {},
        rooms: const [
          SpaceRoom(id: 'r1', name: 'The floor', type: 'Public', x: 0, y: 0, width: 20, height: 20, walled: false),
        ],
      );
      final w = build()..noteRoster(_at(4, 4));
      w.follow(route(30));

      expect(w.gait, Gait.driving);
    });

    test('shift on the pad drives without asking how far', () {
      // `setSpeedModifier(shift ? DRIVING : WALKING)` — no distance test and no area
      // test either, which is the whole difference between this path and a route.
      final w = build()
        ..noteRoster(_at(4, 4))
        ..boost = true;
      w.press('Right');

      expect(w.gait, Gait.driving);
      expect(collector.gaits, [Gait.driving]);
    });

    test('a held direction without shift walks', () {
      final w = build()..noteRoster(_at(4, 4));
      w.press('Right');

      expect(w.gait, Gait.walking);
      expect(collector.gaits, isEmpty);
    });

    test('letting go of shift slows a hold that is already running', () {
      final w = build()
        ..noteRoster(_at(4, 4))
        ..boost = true;
      w.press('Right');
      w.boost = false;

      expect(w.gait, Gait.walking);
      expect(collector.gaits, [Gait.driving, Gait.walking]);
      expect(w.walking, isTrue, reason: 'and the thumb is still down');
    });

    test('the kart is taken for the whole route, not just its long middle', () {
      // The bug this replaces, and it was mine rather than Gather's: `boost` used to
      // raise `basePathSpeedModifier` and leave the deceleration alone, so latching
      // the kart on a twenty-tile walk bought four driving steps — a fifth of a
      // second — before `gaitFor` took it away again. On the desktop, shift is not a
      // ceiling. It is `setSpeedModifier(DRIVING)` and it holds until you let go.
      final w = build()
        ..noteRoster(_at(4, 4))
        ..boost = true;
      w.follow(route(20));

      expect(w.gait, Gait.driving);
      while (w.onRoute) {
        expect(w.gait, Gait.driving, reason: 'and it does not fade out at the end');
        w.step();
      }
      expect(collector.steps.length, 19);
      // Once in, once out at the end, and nothing in between.
      expect(collector.gaits, [Gait.driving, Gait.walking]);
    });

    test('a boost makes even a short walk a drive', () {
      final w = build()
        ..noteRoster(_at(4, 4))
        ..boost = true;
      w.follow(route(5));

      expect(w.gait, Gait.driving);
    });

    test('a boost drives through a room the automatic gait would walk', () {
      // Faithfully: the arrow-key path never consults an area, and shift-driving into
      // a meeting room on the desktop drives you in.
      map = SpaceMap(
        floorId: 'f1',
        width: 60,
        height: 20,
        blocked: const {},
        rooms: const [
          SpaceRoom(id: 'r1', name: 'Green Park', type: 'MeetingRoom', x: 3, y: 3, width: 4, height: 4, walled: true),
        ],
      );
      final w = build()
        ..noteRoster(_at(4, 4))
        ..boost = true;
      w.follow(route(30));

      expect(w.gait, Gait.driving);
    });

    test('latching mid-walk takes the kart there and then', () {
      // Which is the point of it being a live field rather than an argument: the pill
      // is on screen for the whole walk, so pressing it has to mean something.
      final w = build()..noteRoster(_at(4, 4));
      w.follow(route(8));
      expect(w.gait, Gait.walking);

      w.boost = true;
      expect(w.gait, Gait.driving);
      expect(collector.gaits, [Gait.driving]);
    });

    test('a buffer of unconfirmed steps reports the server is not applying our moves',
        () {
      // The walking half of "invisible to others": step after step goes out and no
      // roster ever puts us on any of those tiles, so the server is not relaying us.
      // Overflowing the unconfirmed buffer is the one unambiguous moment, and it is
      // handed to the collector rather than only logged.
      var reports = 0;
      // A held direction, not a route: a long route upgrades to the go-kart gait,
      // whose buffer is three times deeper and would not overflow in twenty steps.
      // A wide floor so all twenty actually land past the 16-step walk limit.
      final wide = _open(width: 60);
      final w = walk = Walk(
        collector: () => collector,
        map: () => wide,
        interval: const Duration(hours: 1),
        onMovesUnconfirmed: () => reports++,
      )..noteRoster(_at(4, 4));
      w.press('Right');
      for (var i = 0; i < 20; i++) {
        w.step(); // held, walking, and never confirmed by a roster
      }
      expect(collector.steps.length, greaterThan(16),
          reason: 'the buffer must actually overflow for the signal to fire');

      expect(reports, greaterThan(0),
          reason: 'past _maxPending with nothing confirmed must raise the signal');
    });

    test('a kart remembers three times as far back as a walk does', () {
      // The bug behind "it still fails sometimes when the go-kart is on", and it was
      // a units mistake rather than a logic one. `_maxPending` is a *count* of steps
      // and what it wants to be is a stretch of *time*: left flat at 16 it buys 2.3
      // seconds of unconfirmed walking and only 0.76 of a second of driving — three
      // roster ticks. One late roster past that and the tile it names has already
      // fallen off the front of the list, so a roster that was merely behind reads as
      // a correction from nowhere, and the walk ends halfway across the office.
      //
      // Twenty steps of driving, then a roster reporting the *first* of them. At a
      // walk that would already be out of the window; in a kart it must not be.
      final w = build()
        ..noteRoster(_at(4, 4))
        ..boost = true;
      w.follow(route(40));
      for (var i = 0; i < 20; i++) {
        w.step();
      }
      expect(w.at, (x: 4 + collector.steps.length, y: 4));
      final reached = w.at!;

      w.noteRoster(_at(5, 4));

      expect(w.at, reached, reason: 'a tile we claimed is still not a correction');
      expect(w.onRoute, isTrue);
    });

    test('stopping gets out of the kart even with the latch still down', () {
      // `stopArrowKeyMovement` sets WALKING whether or not shift is still held —
      // standing still is walking, and an avatar parked in a kart is what everybody
      // else in the space would keep seeing.
      final w = build()
        ..noteRoster(_at(4, 4))
        ..boost = true;
      w.follow(route(30));
      w.release();

      expect(w.gait, Gait.walking);
      expect(w.boost, isTrue, reason: 'but the latch itself survives');
    });

    test('a gear change the socket dropped is said again', () {
      // The one that matters, and the only one that cannot fix itself: `drive` lands,
      // the connection goes, and the `walk` on the way out is sent into nothing. Since
      // a gait is only ever announced when it *changes*, nothing would say it again —
      // and `speed.modifier` is a synced field, so the avatar sits in a go-kart on
      // every other screen in the space until somebody happens to take a long walk.
      final w = build()..noteRoster(_at(4, 4));
      w.follow(route(30));
      expect(collector.gaits, [Gait.driving]);

      collector.refuse = true;
      w.release();
      expect(collector.gaits, [Gait.driving], reason: 'the way out never left');
      expect(w.gait, Gait.walking, reason: 'though the legs are local and know better');

      collector.refuse = false;
      w.noteRoster(_at(4, 4));
      expect(collector.gaits, [Gait.driving, Gait.walking]);

      w.noteRoster(_at(4, 4));
      expect(collector.gaits, [Gait.driving, Gait.walking],
          reason: 'and once it has landed it is not repeated');
    });

    test('a walk nobody ever contradicted says nothing on a roster', () {
      // The conservative half of the same mechanism. A fresh walk has told Gather
      // nothing, so it assumes nothing needs saying — announcing a gait at an avatar
      // whose desktop client is legitimately driving it would be the phone making
      // something up.
      build()
        ..noteRoster(_at(4, 4))
        ..noteRoster(_at(4, 5));

      expect(collector.gaits, isEmpty);
    });
  });

  group('walking into things', () {
    test('a held direction into a wall still turns the avatar', () {
      // `gameMove` is `currentSpaceUser.move({direction})` with no collision test in
      // front of it: the desktop client sends every held-key step and lets the model
      // arbitrate. The model assigns `direction` before it consults `setPosition`, so
      // the step turns you and moves nobody.
      final w = Walk(
        collector: () => collector,
        map: () => _obstructed(),
        now: () => DateTime(2026),
      )..noteRoster(_at(8, 4));

      w.press('Right');
      expect(w.direction, 'Right', reason: 'and the thumb is still down');
      expect(collector.steps, ['Right'], reason: 'sent, so Gather turns us');
      expect(w.at, (x: 8, y: 4), reason: 'and not believed, because it did not land');
      expect(w.step().detail, 'blocked');
      expect(collector.steps, ['Right', 'Right'], reason: 'leaning on it keeps sending');
      w.release();
    });

    test('a route that meets a wall does not send the step', () {
      // The other path, and deliberately not the same: a route has a pathfinder behind
      // it, so a blocked next tile is a route to re-plan rather than a wall to lean on.
      final w = Walk(
        collector: () => collector,
        map: () => _obstructed(),
        now: () => DateTime(2026),
      )..noteRoster(_at(8, 4));

      w.follow(const [(x: 8, y: 4), (x: 9, y: 4)]);

      expect(collector.steps, isEmpty);
      expect(w.onRoute, isFalse);
      w.release();
    });
  });
}
