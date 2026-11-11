/// The pure half of `tool/sim_plan.dart`: the rows of `docs/sim_test_plan.md`
/// and the judgement of each one, as functions of drive readouts already
/// recorded. No socket, no simulator, no clock of its own — the runner records,
/// this decides, and `test/tool/sim_plan_check_test.dart` feeds it hand-built
/// readouts to pin what PASS means.
///
/// ## Why the spotlight rows judge a series, not a reading
///
/// C1–C7 are claims about a state machine with a clock: a speaker is promoted
/// only after holding the floor for the dwell, a second voice does not steal a
/// talking target, a silent big view lingers. A single `call.spotlight`
/// reading at the right moment proves none of that — the same trap the
/// screenshots fell into. So the runner samples the readout every ~200 ms
/// after flipping to auto, and keeps the controller's own transition history.
/// The checks below then hold every promotion against the *inputs* — the
/// `speaking` set and the face on screen in the samples before it — rather
/// than against the director's `candidate` countdown, which would be the
/// machine grading itself.
///
/// Times are the app's clock: each sample's `now` is `since + sinceMs` from the
/// readout itself, so they line up with the transitions' `at` without trusting
/// the round-trip of the RPC. The one tolerance, [kSampleSlack], covers a
/// sample landing between a roster tick (250 ms in `CallScenarioDriver`) and
/// the poll that observes it.
library;

import 'dart:convert';

/// The dwell the auto spotlight gates on (`SpotlightDirector.dwell`). Read
/// back from the readout's `dwellMs` when there is one; this is the fallback.
const Duration kDefaultDwell = Duration(milliseconds: 1500);

/// How far a sample may trail the roster tick it observed: one driver tick
/// (250 ms) plus one poll interval (200 ms).
const Duration kSampleSlack = Duration(milliseconds: 450);

/// One row of the plan.
class PlanRow {
  const PlanRow({
    required this.id,
    required this.target,
    required this.scenario,
    required this.claim,
    this.watch = Duration.zero,
  });

  /// `C1`…`C7`, `A1`, `A2`.
  final String id;

  /// The harness `TARGET`: `call` or `app`.
  final String target;

  /// The harness `SCENARIO`, spelled as the enum value (`Scenario.roundRobin`,
  /// `AppScenario.office`). The harness matches it case-insensitively and
  /// silently falls back to `group`/`office` on a typo, so the runner spells it
  /// exactly and the row checks the scene it got (tile counts, seeds).
  final String scenario;

  /// The one-line claim, as the plan states it.
  final String claim;

  /// How long the runner samples after flipping to auto (call rows) or waits
  /// for the office to move (app rows).
  final Duration watch;
}

/// Every row, in plan order. The watch windows are each scenario's own cycle
/// plus the dwell, so the phase the flip lands in cannot hide a claim.
const List<PlanRow> planRows = [
  PlanRow(
    id: 'C1',
    target: 'call',
    scenario: 'solo',
    claim: 'only "You"; no big view; no crash on an empty room',
    watch: Duration(seconds: 4),
  ),
  PlanRow(
    id: 'C2',
    target: 'call',
    scenario: 'pair',
    claim: 'the speaker is promoted after the dwell and stays big through the 1 s gap',
    watch: Duration(seconds: 9),
  ),
  PlanRow(
    id: 'C3',
    target: 'call',
    scenario: 'group',
    claim: 'manual grid at rest; a pick enlarges; Everyone returns to the grid',
  ),
  PlanRow(
    id: 'C4',
    target: 'call',
    scenario: 'roundRobin',
    claim: 'one promotion per 3 s turn, face replaces face, no grid flash',
    watch: Duration(seconds: 15),
  ),
  PlanRow(
    id: 'C5',
    target: 'call',
    scenario: 'debate',
    claim: 'the talking target is sticky; the other earns it only after the dwell; no thrash',
    watch: Duration(seconds: 26),
  ),
  PlanRow(
    id: 'C6',
    target: 'call',
    scenario: 'briefNoise',
    claim: '800 ms blips never take the big view',
    watch: Duration(seconds: 6),
  ),
  PlanRow(
    id: 'C7',
    target: 'call',
    scenario: 'churn',
    claim: 'tiles track join/leave; the target is always a present tile',
    watch: Duration(seconds: 10),
  ),
  PlanRow(
    id: 'A1',
    target: 'app',
    scenario: 'office',
    claim: 'seeded + live waves with unread; the cast mills; a walk lands on its tile',
    watch: Duration(seconds: 8),
  ),
  PlanRow(
    id: 'A2',
    target: 'app',
    scenario: 'still',
    claim: 'seeded activity, no live waves; nobody moves',
    watch: Duration(seconds: 7),
  ),
];

/// [planRows] narrowed to [only] (row ids, any case). Throws [ArgumentError]
/// naming an id that is not a row, rather than running nothing.
List<PlanRow> selectRows(Iterable<String> only) {
  final wanted = {for (final o in only) o.trim().toUpperCase()}..remove('');
  if (wanted.isEmpty) return planRows;
  final known = {for (final r in planRows) r.id};
  final unknown = wanted.difference(known);
  if (unknown.isNotEmpty) {
    throw ArgumentError('no such row: ${(unknown.toList()..sort()).join(', ')} '
        '(rows: ${known.join(', ')})');
  }
  return [for (final r in planRows) if (wanted.contains(r.id)) r];
}

/// A row's outcome: [failures] empty is a PASS. [evidence] is the values the
/// verdict rests on, printed either way so a PASS can be read too.
class RowVerdict {
  RowVerdict(this.id, {Map<String, Object?>? evidence, List<String>? failures})
      : evidence = evidence ?? {},
        failures = failures ?? [];

  final String id;
  final Map<String, Object?> evidence;
  final List<String> failures;

  bool get pass => failures.isEmpty;

  void check(bool ok, String failure) {
    if (!ok) failures.add(failure);
  }

  /// `C4 PASS  promotions=5 …` plus one indented line per failure.
  String format() {
    final b = StringBuffer('$id ${pass ? 'PASS' : 'FAIL'}');
    evidence.forEach((k, v) => b.write('  $k=${v is String ? v : jsonEncode(v)}'));
    for (final f in failures) {
      b.write('\n    - $f');
    }
    return b.toString();
  }
}

// ---- the spotlight readout --------------------------------------------------

/// One `call.spotlight` reading, reduced to what the checks read.
class SpotSample {
  const SpotSample({
    required this.at,
    required this.mode,
    required this.view,
    required this.target,
    required this.speaking,
    required this.tiles,
    required this.selfId,
    required this.promotions,
    this.dwell = kDefaultDwell,
    this.transitions = const [],
  });

  /// From a `call.spotlight` envelope's `data` (or the envelope itself).
  factory SpotSample.fromReadout(Map<String, Object?> readout) {
    final data = (readout['data'] is Map ? readout['data'] : readout) as Map;
    final since = DateTime.parse(data['since'] as String);
    return SpotSample(
      at: since.add(Duration(milliseconds: (data['sinceMs'] as num).toInt())),
      mode: data['mode'] as String,
      view: data['view'] as String,
      target: data['target'] as String?,
      speaking: [for (final s in data['speaking'] as List) s as String],
      tiles: [for (final t in data['tiles'] as List) t as String],
      selfId: data['selfId'] as String?,
      promotions: (data['promotions'] as num).toInt(),
      dwell: Duration(milliseconds: ((data['dwellMs'] as num?) ?? kDefaultDwell.inMilliseconds).toInt()),
      transitions: [
        for (final t in (data['transitions'] as List? ?? const []))
          SpotTransition.fromJson((t as Map).cast<String, Object?>()),
      ],
    );
  }

  /// The app's clock at the reading.
  final DateTime at;
  final String mode;

  /// `empty`, `grid` or `spotlight`.
  final String view;
  final String? target;

  /// Who is talking, self excluded (the director's input).
  final List<String> speaking;
  final List<String> tiles;
  final String? selfId;
  final int promotions;
  final Duration dwell;
  final List<SpotTransition> transitions;

  List<String> get others => [for (final t in tiles) if (t != selfId) t];
}

/// One entry of the readout's `transitions`.
class SpotTransition {
  const SpotTransition({required this.at, required this.mode, required this.cause, this.from, this.to});

  factory SpotTransition.fromJson(Map<String, Object?> json) => SpotTransition(
        at: DateTime.parse(json['at'] as String),
        mode: json['mode'] as String,
        cause: json['cause'] as String,
        from: json['from'] as String?,
        to: json['to'] as String?,
      );

  final DateTime at;
  final String mode;
  final String cause;
  final String? from;
  final String? to;
}

/// What the runner recorded for an auto row: the readout the flip answered
/// with, the samples after it, and the last reading (whose transitions are the
/// whole history).
class SpotRun {
  const SpotRun({required this.flip, required this.samples, required this.last});

  final SpotSample flip;
  final List<SpotSample> samples;
  final SpotSample last;

  /// The face changes since the flip, the flip's own `mode` entry excluded.
  List<SpotTransition> get transitions => [
        for (final t in last.transitions)
          if (!t.at.isBefore(flip.at) && t.cause != 'mode') t,
      ];

  List<SpotTransition> get promotions => [for (final t in transitions) if (t.cause == 'promoted') t];

  int get promotionCount => last.promotions - flip.promotions;
}

/// The dwell rule, judged from the inputs: every promotion to X at t must have
/// been preceded, for the whole `(t - dwell + slack, t)`, by samples in which X
/// was talking and the face then on screen was not — the "held the floor for
/// the dwell" and "a talking target is sticky" halves together. Returns the
/// failures; [judged] receives how many samples each promotion rested on.
List<String> dwellViolations(SpotRun run, {List<int>? judged}) {
  final out = <String>[];
  final window = run.flip.dwell - kSampleSlack;
  for (final p in run.promotions) {
    final to = p.to;
    if (to == null) continue;
    final from = p.at.subtract(window);
    final inWindow = [
      for (final s in run.samples)
        if (s.at.isAfter(from) && s.at.isBefore(p.at)) s,
    ];
    judged?.add(inWindow.length);
    if (inWindow.isEmpty) {
      out.add('promotion to $to at ${_t(run, p.at)} has no samples in the dwell before it to judge');
      continue;
    }
    if (p.at.difference(run.flip.at) < window) {
      out.add('promotion to $to at ${_t(run, p.at)} came sooner than the dwell after the flip');
    }
    for (final s in inWindow) {
      if (!s.speaking.contains(to)) {
        out.add('promoted $to at ${_t(run, p.at)}, but $to was not talking at ${_t(run, s.at)} '
            '(speaking ${s.speaking}) — less than the dwell');
        break;
      }
      final shown = s.target;
      if (shown != null && shown != to && s.speaking.contains(shown)) {
        out.add('promoted $to at ${_t(run, p.at)} while the target $shown was still talking '
            'at ${_t(run, s.at)} — not sticky');
        break;
      }
    }
  }
  return out;
}

/// Milliseconds after the flip, for messages.
String _t(SpotRun run, DateTime at) => '+${at.difference(run.flip.at).inMilliseconds}ms';

List<int> _intervals(List<SpotTransition> ts) => [
      for (var i = 1; i < ts.length; i++) ts[i].at.difference(ts[i - 1].at).inMilliseconds,
    ];

/// Face changes to the grid after the first promotion — the "grid flash"
/// between two speakers, or a big view dropped inside its linger.
List<SpotTransition> _toGridAfterFirstPromotion(SpotRun run) {
  final first = run.promotions.firstOrNull;
  if (first == null) return const [];
  return [for (final t in run.transitions) if (t.at.isAfter(first.at) && t.to == null) t];
}

void _commonAuto(RowVerdict v, SpotRun run) {
  v.evidence['samples'] = run.samples.length;
  v.check(run.flip.mode == 'auto', 'the flip answered mode ${run.flip.mode}, not auto');
  v.check(run.samples.isNotEmpty, 'no samples recorded after the flip');
  final notAuto = run.samples.where((s) => s.mode != 'auto').length;
  v.check(notAuto == 0, '$notAuto samples were not in auto');
}

/// C1 `solo`: only the self tile, and auto never enlarges anything.
RowVerdict checkSolo(SpotRun run) {
  final v = RowVerdict('C1');
  _commonAuto(v, run);
  final tileCounts = {for (final s in run.samples) s.tiles.length};
  final views = {for (final s in run.samples) s.view};
  v.evidence
    ..['tiles'] = run.last.tiles
    ..['views'] = views.toList()
    ..['promotions'] = run.promotionCount;
  v.check(
    run.samples.every((s) => s.tiles.length == 1 && s.tiles.single == s.selfId),
    'expected only the self tile, saw tile counts $tileCounts',
  );
  v.check(!views.contains('spotlight'), 'the big view appeared with nobody to follow');
  v.check(run.samples.every((s) => s.target == null), 'a target was set in an empty room');
  v.check(run.promotionCount == 0, '${run.promotionCount} promotions in an empty room');
  return v;
}

/// C2 `pair`: the one other is promoted after the dwell, and the big view
/// holds through the 1 s silences (linger 5 s).
RowVerdict checkPair(SpotRun run) {
  final v = RowVerdict('C2');
  _commonAuto(v, run);
  final promos = run.promotions;
  final first = promos.firstOrNull;
  final after = first == null ? const <SpotSample>[] : [for (final s in run.samples) if (s.at.isAfter(first.at)) s];
  final gapSamples = after.where((s) => s.speaking.isEmpty).length;
  final dropped = _toGridAfterFirstPromotion(run);
  final judged = <int>[];
  v.evidence
    ..['others'] = run.last.others
    ..['promotions'] = run.promotionCount
    ..['firstPromotionMs'] = first?.at.difference(run.flip.at).inMilliseconds
    ..['silentSamplesWhileBig'] = gapSamples
    ..['dropsToGrid'] = dropped.length;
  v.check(run.last.others.length == 1, 'expected one other in the call, saw ${run.last.others}');
  v.check(first != null, 'nobody was promoted in ${run.samples.length} samples');
  if (first != null) {
    v.check(first.to != null && first.to != run.last.selfId, 'promoted ${first.to}, not the other');
    v.check(after.every((s) => s.view == 'spotlight'),
        'the big view did not hold after the first promotion (views ${{for (final s in after) s.view}})');
    v.check(gapSamples > 0, 'no silent gap observed after the promotion — the linger claim went untested');
  }
  v.check(dropped.isEmpty, 'dropped to the grid ${dropped.length}× inside the linger');
  v.failures.addAll(dwellViolations(run, judged: judged));
  v.evidence['dwellSamples'] = judged;
  return v;
}

/// C3 `group` in manual: the resting grid, then a pick, then the overview.
RowVerdict checkGroupManual({
  required int participants,
  required SpotSample rest,
  required String pickedId,
  required SpotSample picked,
  required SpotSample overview,
}) {
  final v = RowVerdict('C3');
  v.evidence
    ..['restMode'] = rest.mode
    ..['restView'] = rest.view
    ..['tiles'] = rest.tiles.length
    ..['speaking'] = rest.speaking
    ..['picked'] = pickedId
    ..['pickedView'] = picked.view
    ..['pickedTarget'] = picked.target
    ..['overviewView'] = overview.view;
  v.check(rest.mode == 'manual', 'opened in ${rest.mode}, not manual');
  v.check(rest.view == 'grid' && rest.target == null, 'at rest the view was ${rest.view} on ${rest.target}');
  v.check(rest.others.length == participants,
      'expected $participants other tiles, saw ${rest.others.length} (${rest.others})');
  v.check(rest.speaking.isEmpty, 'speaking rings lit at rest: ${rest.speaking}');
  v.check(picked.view == 'spotlight' && picked.target == pickedId,
      'picking $pickedId gave ${picked.view} on ${picked.target}');
  v.check(overview.view == 'grid' && overview.target == null,
      'Everyone gave ${overview.view} on ${overview.target}');
  v.check(overview.mode == 'manual', 'Everyone left manual for ${overview.mode}');
  return v;
}

/// C4 `roundRobin`: every 3 s turn is one promotion, to the new speaker,
/// replacing the last face directly.
RowVerdict checkRoundRobin(SpotRun run, {required int participants, required Duration watch}) {
  final v = RowVerdict('C4');
  _commonAuto(v, run);
  const turn = Duration(seconds: 3);
  final promos = run.promotions;
  final intervals = _intervals(promos);
  final judged = <int>[];
  final dropped = _toGridAfterFirstPromotion(run);
  final minPromos = watch.inMilliseconds ~/ turn.inMilliseconds - 1;
  final maxPromos = (watch.inMilliseconds / turn.inMilliseconds).ceil() + 1;
  v.evidence
    ..['others'] = run.last.others.length
    ..['promotions'] = run.promotionCount
    ..['targets'] = [for (final p in promos) p.to]
    ..['intervalsMs'] = intervals
    ..['dropsToGrid'] = dropped.length;
  v.check(run.last.others.length == participants,
      'expected $participants others, saw ${run.last.others.length}');
  v.check(promos.length >= minPromos && promos.length <= maxPromos,
      '${promos.length} promotions in ${watch.inSeconds}s, expected $minPromos–$maxPromos (one per turn)');
  // The first promotion is anchored to the flip (the director restarts its
  // count there), not to a turn boundary, so the gap after it may be anything
  // down to the dwell; every later gap is boundary to boundary.
  final short = intervals.skip(1).where((ms) => ms < turn.inMilliseconds - 500).toList();
  v.check(short.isEmpty, 'promotions closer than a turn apart (${short}ms) — a jump mid-turn');
  for (var i = 1; i < promos.length; i++) {
    if (promos[i].to == promos[i - 1].to) {
      v.failures.add('promoted ${promos[i].to} twice in a row');
    }
    if (promos[i].from == null) {
      v.failures.add('promotion to ${promos[i].to} came from the grid, not from a face');
    }
  }
  v.check(dropped.isEmpty, 'the grid flashed ${dropped.length}× between turns');
  v.failures.addAll(dwellViolations(run, judged: judged));
  v.evidence['dwellSamples'] = judged;
  return v;
}

/// C5 `debate`: A holds, B talks over without stealing, then B earns it after
/// the dwell. "Sticky" is judged from the overlap samples: the one who was
/// talking alone before an overlap stays on screen through it.
RowVerdict checkDebate(SpotRun run, {required Duration watch}) {
  final v = RowVerdict('C5');
  _commonAuto(v, run);
  final promos = run.promotions;
  final judged = <int>[];
  var overlapSamples = 0;
  var heldThroughOverlap = 0;
  final stolen = <String>[];
  String? soloBefore;
  for (final s in run.samples) {
    if (s.speaking.length == 1) soloBefore = s.speaking.single;
    if (s.speaking.length >= 2 && soloBefore != null && s.target == soloBefore) {
      overlapSamples++;
      heldThroughOverlap++;
    } else if (s.speaking.length >= 2 && soloBefore != null && s.target != null) {
      overlapSamples++;
      if (s.target != soloBefore && s.speaking.contains(s.target)) {
        stolen.add('${s.target} over $soloBefore at ${_t(run, s.at)}');
      }
    }
  }
  final cycles = (watch.inMilliseconds / 12000).ceil();
  final maxPromos = cycles * 2 + 1;
  final dropped = _toGridAfterFirstPromotion(run);
  final promoted = {for (final p in promos) p.to};
  v.evidence
    ..['promotions'] = run.promotionCount
    ..['targets'] = [for (final p in promos) p.to]
    ..['atMs'] = [for (final p in promos) p.at.difference(run.flip.at).inMilliseconds]
    ..['overlapSamples'] = overlapSamples
    ..['heldThroughOverlap'] = heldThroughOverlap
    ..['dropsToGrid'] = dropped.length;
  v.check(heldThroughOverlap > 0, 'no overlap with a big view was observed — the sticky claim went untested');
  v.check(stolen.isEmpty, 'the talking target lost the view to a voice over it: $stolen');
  v.check(promoted.length >= 2, 'expected both speakers to earn the view in turn, saw $promoted');
  v.check(promos.length <= maxPromos, '${promos.length} promotions in ${watch.inSeconds}s — thrash (≤ $maxPromos)');
  v.check(dropped.isEmpty, 'dropped to the grid ${dropped.length}× between speakers');
  v.failures.addAll(dwellViolations(run, judged: judged));
  v.evidence['dwellSamples'] = judged;
  return v;
}

/// C6 `briefNoise`: blips under the dwell never promote anybody.
RowVerdict checkBriefNoise(SpotRun run) {
  final v = RowVerdict('C6');
  _commonAuto(v, run);
  final blipSamples = run.samples.where((s) => s.speaking.isNotEmpty).length;
  final views = {for (final s in run.samples) s.view};
  final blippers = {for (final s in run.samples) ...s.speaking}.toList()..sort();
  v.evidence
    ..['promotions'] = run.promotionCount
    ..['views'] = views.toList()
    ..['blipSamples'] = blipSamples
    ..['blippers'] = blippers;
  v.check(run.promotionCount == 0, '${run.promotionCount} promotions off blips shorter than the dwell');
  v.check(views.length == 1 && views.single == 'grid', 'the view left the grid: $views');
  v.check(blipSamples > 0, 'no blip observed — the rejection claim went untested');
  return v;
}

/// C7 `churn`: the tiles follow people leaving and rejoining, and the face on
/// screen is always one of them.
RowVerdict checkChurn(SpotRun run, {required int participants}) {
  final v = RowVerdict('C7');
  _commonAuto(v, run);
  final counts = [for (final s in run.samples) s.others.length];
  final distinct = counts.toSet().toList()..sort();
  final stale = <String>[];
  final ghosts = <String>[];
  var refloors = 0;
  String? prevTarget;
  List<String> prevTiles = const [];
  for (final s in run.samples) {
    final t = s.target;
    if (t != null && !s.tiles.contains(t)) stale.add('$t at ${_t(run, s.at)}');
    final notHere = s.speaking.where((id) => !s.tiles.contains(id));
    if (notHere.isNotEmpty) ghosts.add('$notHere at ${_t(run, s.at)}');
    if (prevTarget != null && prevTiles.contains(prevTarget) && !s.tiles.contains(prevTarget)) refloors++;
    prevTarget = t;
    prevTiles = s.tiles;
  }
  final base = participants < 2 ? 2 : participants;
  final expectMin = (base - 2).clamp(1, base);
  v.evidence
    ..['otherCounts'] = distinct
    ..['holderLeft'] = refloors
    ..['promotions'] = run.promotionCount
    ..['staleTargets'] = stale.length;
  v.check(distinct.isNotEmpty && distinct.first <= expectMin && distinct.last >= base,
      'tiles did not track the churn: saw other-counts $distinct, expected $expectMin…$base');
  v.check(stale.isEmpty, 'the target was not a present tile: $stale');
  v.check(ghosts.isEmpty, 'speaking ids with no tile: $ghosts');
  return v;
}

// ---- the app target ---------------------------------------------------------

/// The ids of `activity.list` items.
List<String> activityIds(Map<String, Object?> data) => [
      for (final i in (data['items'] as List? ?? const [])) (i as Map)['id'] as String,
    ];

/// Person id → tile, from a `presence.map.people` readout's `people`.
Map<String, (num, num)> mapTiles(Map<String, Object?> data) => {
      for (final p in (data['people'] as List? ?? const []))
        (p as Map)['id'] as String: (p['x'] as num, p['y'] as num),
    };

/// How many seeded waves `AppScenarioDriver._seedActivity` lays down.
int expectedSeeds(int participants) => participants < 4 ? participants : 4;

/// A1 `office`.
RowVerdict checkOffice({
  required int participants,
  required Map<String, Object?> activityBefore,
  required Map<String, Object?> activityAfter,
  required Map<String, Object?> peopleBefore,
  required Map<String, Object?> peopleAfter,
  required Map<String, Object?> walk,
  required Map<String, Object?> stateAfterWalk,
}) {
  final v = RowVerdict('A1');
  final before = activityIds(activityBefore);
  final after = activityIds(activityAfter);
  final seeds = before.where((id) => id.startsWith('seed-wave-')).length;
  final arrived = after.where((id) => !before.contains(id)).toList();
  final t0 = mapTiles(peopleBefore);
  final t1 = mapTiles(peopleAfter);
  final moved = [for (final id in t0.keys) if (t1.containsKey(id) && t1[id] != t0[id]) id];

  final walkData = _opData(walk);
  final requested = walkData?['requested'] as Map?;
  final me = (stateAfterWalk['me'] as Map?)?['tile'] as Map?;

  v.evidence
    ..['seeds'] = seeds
    ..['liveArrived'] = arrived.length
    ..['unread'] = activityAfter['unread']
    ..['onMap'] = t0.length
    ..['moved'] = moved.length
    ..['walk'] = walkData == null ? walk : {'settled': walkData['settled'], 'atRequested': walkData['atRequested']}
    ..['meTile'] = me;
  v.check(seeds == expectedSeeds(participants), 'expected ${expectedSeeds(participants)} seeded waves, saw $seeds');
  v.check(arrived.isNotEmpty, 'no live wave arrived in the watch window');
  v.check(((activityAfter['unread'] as num?) ?? 0) > 0, 'no unread badge (unread ${activityAfter['unread']})');
  v.check(t0.length == participants, 'expected $participants people on the map, saw ${t0.length}');
  v.check(moved.isNotEmpty, 'nobody milled: no tile changed between two readings');
  if (walkData == null) {
    v.failures.add('the walk did not settle: $walk');
  } else {
    v.check(walkData['atRequested'] == true && walkData['settled'] != 'timeout',
        'the walk settled ${walkData['settled']} at ${walkData['at']}, not on $requested');
    v.check(me != null && requested != null && me['x'] == requested['x'] && me['y'] == requested['y'],
        'state.dump has me at $me after walking to $requested');
  }
  return v;
}

/// A2 `still`.
RowVerdict checkStill({
  required int participants,
  required Map<String, Object?> activityBefore,
  required Map<String, Object?> activityAfter,
  required Map<String, Object?> peopleBefore,
  required Map<String, Object?> peopleAfter,
}) {
  final v = RowVerdict('A2');
  final before = activityIds(activityBefore);
  final after = activityIds(activityAfter);
  final seeds = before.where((id) => id.startsWith('seed-wave-')).length;
  final arrived = after.where((id) => !before.contains(id)).toList();
  final t0 = mapTiles(peopleBefore);
  final t1 = mapTiles(peopleAfter);
  final moved = [for (final id in t0.keys) if (t1[id] != t0[id]) id];
  v.evidence
    ..['seeds'] = seeds
    ..['liveArrived'] = arrived.length
    ..['onMap'] = t0.length
    ..['moved'] = moved;
  v.check(seeds == expectedSeeds(participants), 'expected ${expectedSeeds(participants)} seeded waves, saw $seeds');
  v.check(arrived.isEmpty, 'live churn on a still office: $arrived');
  v.check(t0.length == participants, 'expected $participants people on the map, saw ${t0.length}');
  v.check(moved.isEmpty, 'people moved on a still office: $moved');
  return v;
}

/// The settled readout of a waited move op (`op.result` envelope), or null
/// when it was refused, failed or never settled.
Map<String, Object?>? _opData(Map<String, Object?> envelope) {
  final data = envelope['data'];
  if (data is! Map || data['state'] != 'done') return null;
  final result = data['result'];
  if (result is! Map || result['ok'] != true) return null;
  return (result['data'] as Map?)?.cast<String, Object?>();
}

/// The first of [candidates] nobody in a `presence.map.people` readout stands
/// on, and not where I am — the "empty tile" A1 walks to.
({int x, int y}) emptyTile(Map<String, Object?> people, List<({int x, int y})> candidates) {
  final taken = {
    for (final (x, y) in mapTiles(people).values) (x.round(), y.round()),
  };
  final me = people['me'] as Map?;
  if (me != null) taken.add(((me['x'] as num).round(), (me['y'] as num).round()));
  return candidates.firstWhere((c) => !taken.contains((c.x, c.y)), orElse: () => candidates.first);
}
