// The pure half of tool/sim_plan.dart: what PASS means for each row of
// docs/sim_test_plan.md, fed recorded readouts instead of a simulator.
//
// The spotlight runs are not hand-typed tables. `_simulate` plays a speaking
// schedule through the real `SpotlightDirector` on a 50 ms clock and records
// what `call.spotlight` would have answered — the same JSON shape, sampled
// every 200 ms like the runner — so a PASS here is "the shipped director, read
// the way the runner reads it, satisfies the check". The FAIL cases then break
// one thing in that recording (a promotion too early, a stolen floor, a grid
// flash) and expect the check to name it.
import 'package:flutter_test/flutter_test.dart';
import 'package:gather_companion/src/media/spotlight_director.dart';

import '../../tool/sim_plan_check.dart';

final DateTime _t0 = DateTime.utc(2026, 11, 11, 9);

/// One `call.spotlight` readout as the drive sends it.
Map<String, Object?> _readout({
  required int atMs,
  int sinceAtMs = 0,
  String mode = 'auto',
  String? target,
  List<String> speaking = const [],
  required List<String> tiles,
  int promotions = 0,
  List<Map<String, Object?>> transitions = const [],
  int dwellMs = 1500,
  int lingerMs = 5000,
}) =>
    {
      'ok': true,
      'data': {
        'mode': mode,
        'view': tiles.isEmpty ? 'empty' : (target == null ? 'grid' : 'spotlight'),
        'target': target,
        'since': _t0.add(Duration(milliseconds: sinceAtMs)).toIso8601String(),
        'sinceMs': atMs - sinceAtMs,
        'speaking': speaking,
        'tiles': tiles,
        'selfId': 'me',
        'promotions': promotions,
        'dwellMs': dwellMs,
        'lingerMs': lingerMs,
        'transitions': transitions,
      },
    };

Map<String, Object?> _transition(int atMs, String cause, String? from, String? to, {String mode = 'auto'}) => {
      'at': _t0.add(Duration(milliseconds: atMs)).toIso8601String(),
      'mode': mode,
      'cause': cause,
      'from': from,
      'to': to,
    };

/// Plays [speakingAt] (ms since t0 → who is talking) through the real
/// director, flipping to auto at [flipMs], and records the run the way the
/// runner does. [tilesAt] defaults to [others] for the whole run. [dwell]
/// builds a broken director whose readout still claims the plan's 1500 ms.
SpotRun _simulate({
  required List<String> others,
  required Set<String> Function(int ms) speakingAt,
  List<String> Function(int ms)? tilesAt,
  int flipMs = 0,
  int watchMs = 10000,
  Duration? dwell,
  int reportedDwellMs = 1500,
}) {
  final director = dwell == null ? SpotlightDirector() : SpotlightDirector(dwell: dwell);
  final transitions = <Map<String, Object?>>[];
  var promotions = 0;
  String? shown;
  var sinceAt = flipMs;
  final samples = <SpotSample>[];

  List<String> tiles(int ms) => ['me', ...(tilesAt?.call(ms) ?? others)];
  Set<String> speaking(int ms) => {for (final id in speakingAt(ms)) if (tiles(ms).contains(id)) id};
  String? effective(int ms) {
    final t = director.target;
    return t != null && tiles(ms).contains(t) ? t : null;
  }

  Map<String, Object?> read(int ms) => _readout(
        atMs: ms,
        sinceAtMs: sinceAt,
        target: effective(ms),
        speaking: speaking(ms).toList()..sort(),
        tiles: tiles(ms),
        promotions: promotions,
        transitions: List.of(transitions),
        dwellMs: reportedDwellMs,
      );

  final flip = SpotSample.fromReadout(read(flipMs));
  for (var ms = flipMs; ms <= flipMs + watchMs; ms += 50) {
    final before = shown;
    final r = director.update(speaking(ms), _t0.add(Duration(milliseconds: ms)));
    if (r.promoted) promotions++;
    final now = effective(ms);
    if (now != before) {
      final cause = r.promoted ? 'promoted' : (before != null && now == null ? 'fallback' : 'room');
      transitions.add(_transition(ms, cause, before, now));
      shown = now;
      sinceAt = ms;
    }
    if ((ms - flipMs) % 200 == 0 && ms > flipMs) samples.add(SpotSample.fromReadout(read(ms)));
  }
  return SpotRun(flip: flip, samples: samples, last: SpotSample.fromReadout(read(flipMs + watchMs)));
}

/// [s] with its view/target replaced.
SpotSample _withTarget(SpotSample s, String? target) => SpotSample(
      at: s.at,
      mode: s.mode,
      view: target == null ? 'grid' : 'spotlight',
      target: target,
      speaking: s.speaking,
      tiles: s.tiles,
      selfId: s.selfId,
      promotions: s.promotions,
    );

/// [run] with its transitions (and the last reading's) replaced.
SpotRun _withTransitions(SpotRun run, List<SpotTransition> transitions) => SpotRun(
      flip: run.flip,
      samples: run.samples,
      last: SpotSample(
        at: run.last.at,
        mode: run.last.mode,
        view: run.last.view,
        target: run.last.target,
        speaking: run.last.speaking,
        tiles: run.last.tiles,
        selfId: run.last.selfId,
        promotions: run.last.promotions,
        transitions: transitions,
      ),
    );

const _four = ['acc-a', 'acc-b', 'acc-c', 'acc-d'];

Set<String> _roundRobin(int ms) => {_four[(ms ~/ 3000) % 4]};

Set<String> _debate(int ms) {
  final t = ms % 12000;
  if (t < 5000) return {'acc-a'};
  if (t < 7000) return {'acc-a', 'acc-b'};
  return {'acc-b'};
}

void main() {
  group('rows', () {
    test('every plan row is listed once, in plan order, with the scenario spelled as the enum', () {
      expect([for (final r in planRows) r.id], ['C1', 'C2', 'C3', 'C4', 'C5', 'C6', 'C7', 'A1', 'A2']);
      expect([for (final r in planRows) r.scenario],
          ['solo', 'pair', 'group', 'roundRobin', 'debate', 'briefNoise', 'churn', 'office', 'still']);
    });

    test('--only picks rows in plan order, any case; an unknown id is refused, not skipped', () {
      expect([for (final r in selectRows(['a2', 'C4'])) r.id], ['C4', 'A2']);
      expect(selectRows(const []), planRows);
      expect(() => selectRows(['C9']), throwsArgumentError);
    });
  });

  group('SpotSample', () {
    test("reads the app's clock as since + sinceMs and parses the history", () {
      final s = SpotSample.fromReadout(_readout(
        atMs: 2300,
        sinceAtMs: 1500,
        target: 'acc-a',
        tiles: const ['me', 'acc-a'],
        transitions: [_transition(1500, 'promoted', null, 'acc-a')],
      ));
      expect(s.at, _t0.add(const Duration(milliseconds: 2300)));
      expect(s.view, 'spotlight');
      expect(s.others, ['acc-a']);
      expect(s.transitions.single.cause, 'promoted');
      expect(s.dwell, const Duration(milliseconds: 1500));
    });
  });

  group('C1 solo', () {
    test('only the self tile, never a big view: PASS', () {
      final run = _simulate(others: const [], speakingAt: (_) => const {}, watchMs: 4000);
      final v = checkSolo(run);
      expect(v.failures, isEmpty);
      expect(v.evidence['promotions'], 0);
    });

    test('a second tile in a solo room fails', () {
      final run = _simulate(others: const ['acc-a'], speakingAt: (_) => const {}, watchMs: 2000);
      expect(checkSolo(run).failures, contains(startsWith('expected only the self tile')));
    });
  });

  group('C2 pair', () {
    // 2.5 s on, 1 s off, flipped mid-burst.
    Set<String> pair(int ms) => ms % 3500 < 2500 ? {'acc-a'} : const {};

    test('promoted after the dwell, held through the gaps: PASS', () {
      final v = checkPair(_simulate(others: const ['acc-a'], speakingAt: pair, flipMs: 300, watchMs: 9000));
      expect(v.failures, isEmpty);
      expect(v.evidence['promotions'], 1);
      expect(v.evidence['silentSamplesWhileBig'] as int, greaterThan(0));
    });

    test('a drop to the grid inside the linger fails', () {
      final run = _simulate(others: const ['acc-a'], speakingAt: pair, flipMs: 300, watchMs: 9000);
      final p = run.promotions.first;
      final broken = _withTransitions(run, [
        ...run.transitions,
        SpotTransition(at: p.at.add(const Duration(seconds: 3)), mode: 'auto', cause: 'fallback', from: 'acc-a'),
      ]);
      expect(checkPair(broken).failures, contains(startsWith('dropped to the grid 1×')));
    });

    test('one grid sample after the promotion fails, whatever the history says', () {
      final run = _simulate(others: const ['acc-a'], speakingAt: pair, flipMs: 300, watchMs: 9000);
      final firstAt = run.promotions.first.at;
      final i = run.samples.lastIndexWhere((s) => s.at.isAfter(firstAt));
      final broken = SpotRun(
        flip: run.flip,
        samples: [...run.samples]..[i] = _withTarget(run.samples[i], null),
        last: run.last,
      );
      expect(checkPair(broken).failures, contains(startsWith('the big view did not hold')));
    });

    test('a speaker who never pauses leaves the linger untested, and that fails', () {
      final v = checkPair(_simulate(others: const ['acc-a'], speakingAt: (_) => {'acc-a'}, watchMs: 9000));
      expect(v.failures, [contains('linger claim went untested')]);
    });
  });

  group('the dwell rule', () {
    test('a promotion half a second into a turn is caught', () {
      final run = _simulate(others: _four, speakingAt: _roundRobin, watchMs: 12000);
      final real = run.promotions[1];
      final early = SpotTransition(
        at: real.at.subtract(const Duration(milliseconds: 1000)),
        mode: 'auto',
        cause: 'promoted',
        from: real.from,
        to: real.to,
      );
      final broken = _withTransitions(run, [for (final t in run.transitions) t == real ? early : t]);
      expect(dwellViolations(broken), contains(contains('less than the dwell')));
    });

    test('a promotion while the target is still talking is caught as not sticky', () {
      final run = _simulate(others: const ['acc-a', 'acc-b'], speakingAt: _debate, watchMs: 14000);
      // Hand B the view a second into the overlap, while A is talking.
      final steal = SpotTransition(
        at: _t0.add(const Duration(milliseconds: 6200)),
        mode: 'auto',
        cause: 'promoted',
        from: 'acc-a',
        to: 'acc-b',
      );
      final broken = _withTransitions(run, [...run.transitions, steal]..sort((x, y) => x.at.compareTo(y.at)));
      expect(dwellViolations(broken), contains(contains('not sticky')));
    });

    test('a director with a shortened dwell is caught at the flip, though its readout claims 1500 ms', () {
      // 1.2 s: every later promotion still has the speaker lit through the
      // slack-trimmed window, so only the flip anchor can see it.
      final run = _simulate(
        others: _four,
        speakingAt: _roundRobin,
        dwell: const Duration(milliseconds: 1200),
        watchMs: 15000,
      );
      expect(dwellViolations(run), contains(contains('sooner than the dwell after the flip')));
    });

    test("a readout whose own dwell is not the plan's fails the row instead of grading itself", () {
      final run = _simulate(
        others: _four,
        speakingAt: _roundRobin,
        dwell: const Duration(milliseconds: 1000),
        reportedDwellMs: 1000,
        watchMs: 15000,
      );
      final v = checkRoundRobin(run, participants: 4, watch: const Duration(seconds: 15));
      expect(v.failures, contains(startsWith('the director gates on dwell 1000 ms')));
      expect(v.failures, contains(contains('sooner than the dwell after the flip')));
    });
  });

  group('C3 group (manual)', () {
    final tiles = ['me', ..._four];
    SpotSample s({String? target, String mode = 'manual', List<String> speaking = const []}) =>
        SpotSample.fromReadout(_readout(atMs: 0, mode: mode, target: target, speaking: speaking, tiles: tiles));

    test('grid at rest, the pick enlarges, Everyone returns: PASS', () {
      final v = checkGroupManual(
        participants: 4,
        rest: s(),
        pickedId: 'acc-a',
        picked: s(target: 'acc-a'),
        overview: s(),
      );
      expect(v.failures, isEmpty);
    });

    test('a lit ring at rest and an overview that keeps the face both fail', () {
      final v = checkGroupManual(
        participants: 4,
        rest: s(speaking: const ['acc-b']),
        pickedId: 'acc-a',
        picked: s(target: 'acc-a'),
        overview: s(target: 'acc-a'),
      );
      expect(v.failures, hasLength(2));
    });
  });

  group('C4 roundRobin', () {
    test('one promotion per turn, face to face, wherever the flip lands: PASS', () {
      for (final flip in [0, 900, 1600, 2400]) {
        final v = checkRoundRobin(
          _simulate(others: _four, speakingAt: _roundRobin, flipMs: flip, watchMs: 15000),
          participants: 4,
          watch: const Duration(seconds: 15),
        );
        expect(v.failures, isEmpty, reason: 'flip at $flip ms');
      }
    });

    test('a grid flash between turns fails', () {
      final run = _simulate(others: _four, speakingAt: _roundRobin, watchMs: 15000);
      final p = run.promotions[2];
      final flash = [
        for (final t in run.transitions)
          if (t == p) ...[
            SpotTransition(at: t.at.subtract(const Duration(milliseconds: 100)), mode: 'auto', cause: 'room', from: t.from),
            SpotTransition(at: t.at, mode: 'auto', cause: 'promoted', to: t.to),
          ] else
            t,
      ];
      final v = checkRoundRobin(_withTransitions(run, flash), participants: 4, watch: const Duration(seconds: 15));
      expect(v.failures, contains(startsWith('the grid flashed')));
      expect(v.failures, contains(contains('came from the grid')));
    });

    test('too few promotions for the watch fail, and so does the same face twice running', () {
      final run = _simulate(others: _four, speakingAt: _roundRobin, watchMs: 15000);
      final ps = run.promotions;
      final kept = [for (final t in run.transitions) if (t != ps[1] && t != ps[2]) t];
      expect(
        checkRoundRobin(_withTransitions(run, kept), participants: 4, watch: const Duration(seconds: 15)).failures,
        contains(contains('promotions in 15s, expected 4–6')),
      );
      final twice = [
        for (final t in run.transitions)
          t == ps[2] ? SpotTransition(at: t.at, mode: t.mode, cause: t.cause, from: t.from, to: ps[1].to) : t,
      ];
      expect(
        checkRoundRobin(_withTransitions(run, twice), participants: 4, watch: const Duration(seconds: 15)).failures,
        contains(contains('twice in a row')),
      );
    });

    test('a promotion mid-turn (under 2.5 s after the last) fails as a jump', () {
      final run = _simulate(others: _four, speakingAt: _roundRobin, watchMs: 15000);
      final ps = run.promotions;
      final jump = [
        for (final t in run.transitions)
          t == ps[3]
              ? SpotTransition(at: ps[2].at.add(const Duration(seconds: 2)), mode: t.mode, cause: t.cause, from: t.from, to: t.to)
              : t,
      ];
      expect(
        checkRoundRobin(_withTransitions(run, jump), participants: 4, watch: const Duration(seconds: 15)).failures,
        contains(contains('a jump mid-turn')),
      );
    });
  });

  group('C5 debate', () {
    test('sticky through the overlap, B earns it after the dwell, no thrash: PASS', () {
      final v = checkDebate(
        _simulate(others: const ['acc-a', 'acc-b'], speakingAt: _debate, flipMs: 1000, watchMs: 26000),
        watch: const Duration(seconds: 26),
      );
      expect(v.failures, isEmpty);
      expect(v.evidence['heldThroughOverlap'] as int, greaterThan(0));
      expect(v.evidence['targets'], containsAllInOrder(['acc-a', 'acc-b', 'acc-a']));
    });

    test('a watch that never sees an overlap does not pass vacuously', () {
      final v = checkDebate(
        _simulate(others: const ['acc-a', 'acc-b'], speakingAt: (_) => {'acc-a'}, watchMs: 5000),
        watch: const Duration(seconds: 5),
      );
      expect(v.failures, contains(contains('sticky claim went untested')));
    });

    test('B on screen in an overlap sample while A talks is a stolen floor', () {
      final run = _simulate(others: const ['acc-a', 'acc-b'], speakingAt: _debate, flipMs: 1000, watchMs: 26000);
      final i = run.samples.indexWhere((s) => s.speaking.length == 2 && s.target == 'acc-a');
      final broken = SpotRun(
        flip: run.flip,
        samples: [...run.samples]..[i] = _withTarget(run.samples[i], 'acc-b'),
        last: run.last,
      );
      expect(checkDebate(broken, watch: const Duration(seconds: 26)).failures,
          contains(startsWith('the talking target lost the view')));
    });

    test('a sixth promotion in 26 s is thrash (two whole cycles allow five)', () {
      final run = _simulate(others: const ['acc-a', 'acc-b'], speakingAt: _debate, flipMs: 1000, watchMs: 26000);
      expect(run.promotions, hasLength(5));
      final p = run.promotions[1];
      final extra = [
        ...run.transitions,
        SpotTransition(at: p.at.add(const Duration(seconds: 2)), mode: 'auto', cause: 'promoted', from: 'acc-b', to: 'acc-a'),
      ]..sort((x, y) => x.at.compareTo(y.at));
      expect(
        checkDebate(_withTransitions(run, extra), watch: const Duration(seconds: 26)).failures,
        contains(contains('thrash (≤ 5)')),
      );
    });
  });

  group('C6 briefNoise', () {
    Set<String> blips(int ms) => ms % 1500 < 800 ? {_four[(ms ~/ 1500) % 4]} : const {};

    test('800 ms blips never promote: PASS', () {
      final v = checkBriefNoise(_simulate(others: _four, speakingAt: blips, watchMs: 6000));
      expect(v.failures, isEmpty);
      expect(v.evidence['blipSamples'] as int, greaterThan(0));
    });

    test('a held voice is promoted, and that fails the row', () {
      final v = checkBriefNoise(_simulate(others: _four, speakingAt: (_) => {'acc-a'}, watchMs: 6000));
      expect(v.failures, contains(contains('promotions off blips')));
    });

    test('a grid held for too short a watch does not prove "never"', () {
      final v = checkBriefNoise(_simulate(others: _four, speakingAt: blips, watchMs: 3000));
      expect(v.failures, [startsWith('watched only 3000 ms')]);
    });

    test('a watch that saw no blip does not pass vacuously', () {
      final v = checkBriefNoise(_simulate(others: _four, speakingAt: (_) => const {}, watchMs: 6000));
      expect(v.failures, [contains('rejection claim went untested')]);
    });
  });

  group('C7 churn', () {
    List<String> present(int ms) => _four.take(4 - const [0, 1, 2, 1][(ms ~/ 2000) % 4]).toList();
    Set<String> talker(int ms) {
      final here = present(ms);
      return {here[(ms ~/ 3000) % here.length]};
    }

    test('tiles track the churn and the target is always present: PASS', () {
      final v = checkChurn(
        _simulate(others: _four, tilesAt: present, speakingAt: talker, watchMs: 10000),
        participants: 4,
      );
      expect(v.failures, isEmpty);
      expect(v.evidence['otherCounts'], [2, 3, 4]);
    });

    test('a target that is not a tile is a stale tile', () {
      final run = _simulate(others: _four, tilesAt: present, speakingAt: talker, watchMs: 10000);
      final s = run.samples[10];
      final stale = SpotSample(
        at: s.at,
        mode: s.mode,
        view: 'spotlight',
        target: 'acc-gone',
        speaking: s.speaking,
        tiles: s.tiles,
        selfId: s.selfId,
        promotions: s.promotions,
      );
      final broken = SpotRun(flip: run.flip, samples: [...run.samples]..[10] = stale, last: run.last);
      expect(checkChurn(broken, participants: 4).failures, contains(startsWith('the target was not a present tile')));
    });

    test('tiles that never change do not track the churn', () {
      final v = checkChurn(_simulate(others: _four, speakingAt: talker, watchMs: 10000), participants: 4);
      expect(v.failures, [startsWith('tiles did not track the churn')]);
    });
  });

  group('A1 office / A2 still', () {
    Map<String, Object?> activity(List<String> ids, {int unread = 0}) => {
          'unread': unread,
          'items': [for (final id in ids) {'id': id}],
        };
    Map<String, Object?> people(Map<String, (int, int)> at) => {
          'me': {'x': 10.0, 'y': 7.0},
          'people': [
            for (final e in at.entries) {'id': e.key, 'x': e.value.$1.toDouble(), 'y': e.value.$2.toDouble()},
          ],
        };
    const seeds = ['seed-wave-0', 'seed-wave-1', 'seed-wave-2', 'seed-wave-3'];
    final p0 = people({'a': (4, 3), 'b': (15, 3), 'c': (9, 10), 'd': (11, 11)});
    final p1 = people({'a': (5, 3), 'b': (15, 3), 'c': (9, 10), 'd': (11, 11)});
    Map<String, Object?> walk({required bool landed}) => {
          'ok': true,
          'data': {
            'state': 'done',
            'result': {
              'ok': true,
              'data': {
                'settled': 'route_ended',
                'requested': {'x': 18, 'y': 7},
                'at': landed ? {'x': 18, 'y': 7} : {'x': 16, 'y': 7},
                'atRequested': landed,
              },
            },
          },
        };
    Map<String, Object?> me(int x, int y) => {
          'me': {
            'tile': {'x': x, 'y': y},
          },
        };

    test('office: seeds, a live wave with unread, milling, a walk that lands: PASS', () {
      final v = checkOffice(
        participants: 4,
        activityBefore: activity(seeds),
        activityAfter: activity(['wave:live:1', ...seeds], unread: 1),
        peopleBefore: p0,
        peopleAfter: p1,
        walk: walk(landed: true),
        stateAfterWalk: me(18, 7),
      );
      expect(v.failures, isEmpty);
      expect(v.evidence['moved'], 1);
    });

    test('office: no live wave, nobody moving and a short walk each fail', () {
      final v = checkOffice(
        participants: 4,
        activityBefore: activity(seeds),
        activityAfter: activity(seeds),
        peopleBefore: p0,
        peopleAfter: p0,
        walk: walk(landed: false),
        stateAfterWalk: me(16, 7),
      );
      expect(v.failures, hasLength(5));
    });

    test('office: a refused walk is reported, not crashed on', () {
      final v = checkOffice(
        participants: 4,
        activityBefore: activity(seeds),
        activityAfter: activity(['wave:live:1', ...seeds], unread: 1),
        peopleBefore: p0,
        peopleAfter: p1,
        walk: {'ok': false, 'reason': 'not_connected'},
        stateAfterWalk: me(10, 7),
      );
      expect(v.failures, [startsWith('the walk did not settle')]);
    });

    test('still: seeds and a frozen floor PASS; one step or one live wave fails', () {
      expect(
        checkStill(
          participants: 4,
          activityBefore: activity(seeds),
          activityAfter: activity(seeds),
          peopleBefore: p0,
          peopleAfter: p0,
        ).failures,
        isEmpty,
      );
      expect(
        checkStill(
          participants: 4,
          activityBefore: activity(seeds),
          activityAfter: activity(['wave:live:1', ...seeds]),
          peopleBefore: p0,
          peopleAfter: p1,
        ).failures,
        hasLength(2),
      );
    });

    test('the walk target skips tiles somebody (or I) stand on', () {
      final taken = people({'a': (18, 7)});
      expect(emptyTile(taken, const [(x: 18, y: 7), (x: 10, y: 7), (x: 1, y: 7)]), (x: 1, y: 7));
    });
  });

  test('a verdict prints its evidence on the PASS/FAIL line and each failure under it', () {
    final v = RowVerdict('C6', evidence: {'promotions': 1, 'views': ['grid', 'spotlight']})
      ..check(false, 'the view left the grid');
    expect(v.format(), 'C6 FAIL  promotions=1  views=["grid","spotlight"]\n    - the view left the grid');
  });
}
