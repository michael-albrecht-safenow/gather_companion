/// [SpotlightController] — the call screen's spotlight state and its one timer,
/// moved out of the widget so `docs/sim_test_plan.md` C1–C7 are assertions here
/// rather than screenshots on a simulator.
///
/// Each C-case plays the harness's own scenario script (`scenarioFrame`, the
/// same pure function `CallScenarioDriver` pushes into the screen every 250 ms)
/// into a controller with the real 1.5 s dwell and 5 s linger, on a fake clock.
/// The timer is the controller's own `Timer`, faked by `fake_async`, so a
/// promotion that only the dwell deadline can fire is fired by the deadline.
library;

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gather_companion/harness/call_scenarios.dart';
import 'package:gather_companion/harness/harness_data.dart';
import 'package:gather_companion/src/media/spotlight_controller.dart';

const _self = 'me';
String _acc(int i) => kCast[i].accountId;

/// A room the test sets by hand, read by the controller through its callback.
class _Room {
  List<SpotlightTile> tiles = const [(id: _self, isSelf: true, speaking: false)];

  void set(int count, Set<String> speaking, {bool selfSpeaking = false}) => tiles = [
        (id: _self, isSelf: true, speaking: selfSpeaking),
        for (var i = 0; i < count; i++) (id: _acc(i), isSelf: false, speaking: speaking.contains(_acc(i))),
      ];
}

void main() {
  final t0 = DateTime.utc(2026, 11, 11, 9);

  /// Runs [body] on a fake clock with a controller over a [_Room].
  void run(void Function(FakeAsync async, SpotlightController c, _Room room) body) {
    fakeAsync((async) {
      final room = _Room();
      final c = SpotlightController(
        tiles: () => room.tiles,
        now: () => t0.add(async.elapsed),
      );
      body(async, c, room);
      c.dispose();
    });
  }

  /// Plays [scenario] for [duration] the way `CallScenarioDriver` does: a frame
  /// every 250 ms, each followed by the screen's `roomChanged`. Returns the
  /// effective target sampled at every tick, for "never a grid flash" checks.
  List<String?> play(
    FakeAsync async,
    SpotlightController c,
    _Room room,
    Scenario scenario,
    Duration duration, {
    int participants = 4,
  }) {
    const period = Duration(milliseconds: 250);
    final seen = <String?>[];
    for (var t = Duration.zero; t <= duration; t += period) {
      if (t > Duration.zero) async.elapse(period);
      final frame = scenarioFrame(scenario, async.elapsed, participants);
      room.set(frame.count, frame.speaking, selfSpeaking: frame.ownSpeaking);
      c.roomChanged();
      seen.add(c.effective);
    }
    return seen;
  }

  List<SpotlightTransition> promotions(SpotlightController c) =>
      c.history.where((t) => t.cause == 'promoted').toList();

  test('C1 solo: only yourself, auto never enlarges anything', () {
    run((async, c, room) {
      c.setMode(SpotlightMode.auto);
      final seen = play(async, c, room, Scenario.solo, const Duration(seconds: 6));
      expect(seen, everyElement(isNull));
      expect(c.history, isEmpty);
      final s = c.debugSnapshot();
      expect(s['view'], 'grid');
      expect(s['tiles'], [_self]);
      expect(s['candidate'], isNull);
    });
  });

  test('C1 yourself talking alone is still not enlarged', () {
    run((async, c, room) {
      c.setMode(SpotlightMode.auto);
      room.set(0, const {}, selfSpeaking: true);
      c.roomChanged();
      async.elapse(const Duration(seconds: 3));
      expect(c.effective, isNull);
      expect(c.debugSnapshot()['speaking'], isEmpty);
    });
  });

  test('C2 pair: promoted after the dwell, held through the 1 s gaps', () {
    run((async, c, room) {
      c.setMode(SpotlightMode.auto);
      final seen = play(async, c, room, Scenario.pair, const Duration(milliseconds: 7000));
      // Talking from 0: not before 1500, promoted at 1500.
      expect(seen.sublist(0, 6), everyElement(isNull), reason: '0..1250 ms is under the dwell');
      expect(seen[6], _acc(0), reason: 'promoted at 1500 ms');
      // From the promotion on, never back to the grid — the 1 s silences are
      // shorter than the 5 s linger.
      expect(seen.sublist(6), everyElement(_acc(0)));
      expect(promotions(c), hasLength(1));
      expect(promotions(c).single.at, t0.add(const Duration(milliseconds: 1500)));
    });
  });

  test('C2 the dwell timer promotes on its own, with no further room change', () {
    run((async, c, room) {
      c.setMode(SpotlightMode.auto);
      room.set(1, {_acc(0)});
      c.roomChanged();
      expect(c.debugSnapshot()['timer'], {'dueInMs': 1500});
      var notified = 0;
      c.addListener(() => notified++);
      async.elapse(const Duration(milliseconds: 1499));
      expect(c.effective, isNull);
      async.elapse(const Duration(milliseconds: 1));
      expect(c.effective, _acc(0));
      expect(notified, 1);
      expect(c.history.single.cause, 'promoted');
    });
  });

  test('C2 a real lull drops to the grid when the linger deadline lands', () {
    run((async, c, room) {
      c.setMode(SpotlightMode.auto);
      room.set(1, {_acc(0)});
      c.roomChanged();
      async.elapse(const Duration(milliseconds: 1500));
      room.set(1, const {});
      c.roomChanged();
      async.elapse(const Duration(milliseconds: 4999));
      expect(c.effective, _acc(0));
      async.elapse(const Duration(milliseconds: 1));
      expect(c.effective, isNull);
      expect(c.history.last.cause, 'fallback');
    });
  });

  test('C3 group, manual: tap enlarges, overview returns, nothing moves on its own', () {
    run((async, c, room) {
      play(async, c, room, Scenario.group, const Duration(seconds: 3));
      expect(c.mode, SpotlightMode.manual);
      expect(c.effective, isNull);
      expect(c.debugSnapshot()['speaking'], isEmpty);

      expect(c.tap(_acc(2), isSelf: false), isTrue);
      expect(c.effective, _acc(2));
      play(async, c, room, Scenario.group, const Duration(seconds: 3));
      expect(c.effective, _acc(2), reason: 'manual holds');

      c.returnToOverview();
      expect(c.effective, isNull);
      expect([for (final t in c.history) t.cause], ['tap', 'overview']);
    });
  });

  test('C4 roundRobin: one promotion per turn, never mid-turn, never a grid flash', () {
    run((async, c, room) {
      c.setMode(SpotlightMode.auto);
      // 4 people × 3 s, twice round.
      final seen = play(async, c, room, Scenario.roundRobin, const Duration(seconds: 24));
      final p = promotions(c);
      expect(p, hasLength(8), reason: 'one per 3 s turn');
      for (var i = 0; i < p.length; i++) {
        expect(p[i].to, _acc(i % 4));
        // Each turn starts at i*3 s; promotion lands one dwell into it.
        expect(p[i].at, t0.add(Duration(milliseconds: i * 3000 + 1500)));
      }
      // Once the first face is up, the view never drops to the grid between turns.
      final first = seen.indexWhere((s) => s != null);
      expect(seen.sublist(first), everyElement(isNotNull));
      expect(c.history.every((t) => t.cause == 'promoted'), isTrue);
    });
  });

  test('C5 debate: A sticky through the talk-over, B earns it only after the dwell', () {
    run((async, c, room) {
      c.setMode(SpotlightMode.auto);
      final seen = play(async, c, room, Scenario.debate, const Duration(seconds: 12));
      final p = promotions(c);
      expect(p.map((t) => t.to), [_acc(0), _acc(1)], reason: 'two promotions, no thrash');
      expect(p[0].at, t0.add(const Duration(milliseconds: 1500)));
      // B talks over A 5–7 s and does not steal it; B starts alone at 7 s and is
      // promoted one dwell later.
      expect(p[1].at, t0.add(const Duration(milliseconds: 8500)));
      // Ticks 6 (1.5 s) .. 34 (8.5 s - 1 tick) are all A.
      expect(seen.sublist(6, 34), everyElement(_acc(0)));
      expect(seen.sublist(34), everyElement(_acc(1)));
    });
  });

  test('C6 briefNoise: 800 ms blips never take the big view', () {
    run((async, c, room) {
      c.setMode(SpotlightMode.auto);
      final seen = play(async, c, room, Scenario.briefNoise, const Duration(seconds: 12));
      expect(seen, everyElement(isNull));
      expect(c.history, isEmpty);
      expect(c.promotions, 0);
      expect(c.debugSnapshot()['view'], 'grid');
    });
  });

  /// The history as `(ms since t0, cause, from, to)`, for pinning a whole run.
  List<(int, String, String?, String?)> trace(SpotlightController c) => [
        for (final t in c.history) (t.at.difference(t0).inMilliseconds, t.cause, t.from, t.to),
      ];

  /// Plays churn for [seconds] with [participants], checking at every tick that
  /// the face on screen is somebody present and never yourself.
  void playChurn(FakeAsync async, SpotlightController c, _Room room, int participants, int seconds) {
    const period = Duration(milliseconds: 250);
    for (var t = Duration.zero; t <= Duration(seconds: seconds); t += period) {
      if (t > Duration.zero) async.elapse(period);
      final frame = scenarioFrame(Scenario.churn, async.elapsed, participants);
      room.set(frame.count, frame.speaking);
      c.roomChanged();
      final target = c.effective;
      if (target != null) {
        expect(room.tiles.map((t) => t.id), contains(target), reason: 'no stale tile at $t');
        expect(target, isNot(_self));
      }
    }
  }

  test('C7 churn, 4 seated: the floor moves through joins and leaves, one promotion per turn', () {
    // With four seated, every 24 s holder is still present for the whole of its
    // turn — only a candidate (acc3, at 10 s) leaves — so this pins that the
    // churn alone never knocks the view off a present face or adds a stray
    // transition. The holder-leaves case is the 3-seated run below.
    run((async, c, room) {
      c.setMode(SpotlightMode.auto);
      playChurn(async, c, room, 4, 24);
      expect(trace(c), [
        (1500, 'promoted', null, _acc(0)),
        (4500, 'promoted', _acc(0), _acc(1)),
        (7500, 'promoted', _acc(1), _acc(2)),
        (11500, 'promoted', _acc(2), _acc(0)),
        (17500, 'promoted', _acc(0), _acc(1)),
        (19500, 'promoted', _acc(1), _acc(0)),
        (22500, 'promoted', _acc(0), _acc(1)),
      ]);
      expect(c.promotions, 7);
    });
  });

  test('C7 churn, 3 seated: a holder who leaves drops the view to the grid, and the next speaker re-floors it', () {
    run((async, c, room) {
      c.setMode(SpotlightMode.auto);
      playChurn(async, c, room, 3, 24);
      expect(trace(c), [
        (1500, 'promoted', null, _acc(0)),
        (11500, 'promoted', _acc(0), _acc(1)),
        // 12 s: the room drops to one; acc1 leaves while holding the view.
        (12000, 'room', _acc(1), null),
        (13500, 'promoted', null, _acc(0)),
        (17500, 'promoted', _acc(0), _acc(2)),
        // 18 s: acc2 leaves while holding it, the same way.
        (18000, 'room', _acc(2), null),
        (19500, 'promoted', null, _acc(0)),
        (23500, 'promoted', _acc(0), _acc(1)),
      ]);
      // Every leave is followed by a fresh promotion, never by the leaver's stale
      // director target coming back.
      final h = c.history;
      for (var i = 0; i < h.length; i++) {
        if (h[i].cause != 'room') continue;
        expect(h[i].from, isNotNull);
        expect(h[i].to, isNull);
        expect(h[i + 1].cause, 'promoted');
        expect(h[i + 1].to, isNot(h[i].from));
      }
    });
  });

  test('C7 a holder who leaves falls back to the grid at once, cause room', () {
    run((async, c, room) {
      c.setMode(SpotlightMode.auto);
      room.set(3, {_acc(2)});
      c.roomChanged();
      async.elapse(const Duration(milliseconds: 1500));
      expect(c.effective, _acc(2));
      room.set(2, const {});
      c.roomChanged();
      expect(c.effective, isNull);
      expect(c.history.last.cause, 'room');
      expect((c.debugSnapshot()['decided']! as Map)['directorTarget'], _acc(2),
          reason: 'the director still holds them; the live tile list refused it');
    });
  });

  group('mode toggle (unchanged from the widget)', () {
    test('manual → auto carries the manual face across as a pin until a promotion', () {
      run((async, c, room) {
        room.set(3, const {});
        c.tap(_acc(1), isSelf: false);
        c.setMode(SpotlightMode.auto);
        expect(c.autoPinned, _acc(1));
        expect(c.effective, _acc(1));
        room.set(3, {_acc(2)});
        c.roomChanged();
        async.elapse(const Duration(milliseconds: 1500));
        expect(c.effective, _acc(2));
        expect(c.autoPinned, isNull);
      });
    });

    test('auto → manual freezes the big view and disarms the timer', () {
      run((async, c, room) {
        c.setMode(SpotlightMode.auto);
        room.set(2, {_acc(0)});
        c.roomChanged();
        async.elapse(const Duration(milliseconds: 1500));
        room.set(2, {_acc(1)});
        c.roomChanged();
        expect(c.debugSnapshot()['timer'], isNotNull);
        c.setMode(SpotlightMode.manual);
        expect(c.manualId, _acc(0));
        expect(c.debugSnapshot()['timer'], isNull);
        async.elapse(const Duration(seconds: 10));
        expect(c.effective, _acc(0));
      });
    });

    test('a tap on yourself in auto is a no-op and does not notify', () {
      run((async, c, room) {
        c.setMode(SpotlightMode.auto);
        var notified = 0;
        c.addListener(() => notified++);
        expect(c.tap(_self, isSelf: true), isFalse);
        expect(c.mode, SpotlightMode.auto);
        expect(notified, 0);
      });
    });

    test('a tap in auto switches to manual on that face', () {
      run((async, c, room) {
        room.set(2, const {});
        c.setMode(SpotlightMode.auto);
        c.tap(_acc(1), isSelf: false);
        expect(c.mode, SpotlightMode.manual);
        expect(c.effective, _acc(1));
      });
    });

    test('roomChanged in manual does not notify; each lever notifies exactly once', () {
      run((async, c, room) {
        var notified = 0;
        c.addListener(() => notified++);
        c.roomChanged();
        expect(notified, 0);
        c.setMode(SpotlightMode.auto);
        expect(notified, 1);
        c.roomChanged();
        expect(notified, 2);
        c.returnToOverview();
        expect(notified, 3);
        c.setMode(SpotlightMode.auto);
        expect(notified, 3, reason: 'same mode is a no-op');
      });
    });

    test('dispose cancels a pending deadline', () {
      fakeAsync((async) {
        final room = _Room()..set(1, {_acc(0)});
        final c = SpotlightController(tiles: () => room.tiles, now: () => t0.add(async.elapsed))
          ..setMode(SpotlightMode.auto);
        expect(async.pendingTimers, hasLength(1));
        c.dispose();
        expect(async.pendingTimers, isEmpty);
      });
    });
  });

  test('history is bounded and the readout honours historyMax', () {
    run((async, c, room) {
      room.set(2, const {});
      for (var i = 0; i < kSpotlightHistory + 10; i++) {
        c.tap(_acc(i % 2), isSelf: false);
      }
      expect(c.history, hasLength(kSpotlightHistory));
      final s = c.debugSnapshot(historyMax: 3);
      expect(s['transitions'], hasLength(3));
      expect(s['transitionsDropped'], kSpotlightHistory - 3);
    });
  });
}
