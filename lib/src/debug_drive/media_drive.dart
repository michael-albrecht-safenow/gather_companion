/// `ext.gc.media.snapshot` and `ext.gc.media.watch`: is the call's media
/// actually moving, per stream, right now and over time.
///
/// The main payoff of the drive (plan "Media flow probe"). Every call bug this
/// app has had looked healthy from the signalling; the packet counters are the
/// only witness. These actions read them through `Call.sampleFlow` — the same
/// reading `media.log`'s periodic flow line uses — and judge each stream with
/// `FlowJudge` (`../media/media_flow.dart`), so "is the call healthy for 30 s"
/// becomes one assertion: every expected stream is `continuous`.
///
/// ## Why the snapshot holds the RPC for two seconds
///
/// A verdict is a *delta*, so one reading cannot give one, and `stalled` needs
/// counters flat for the whole stall window (2 s). The alternative — judge
/// against the previous snapshot — answers the first call of every session with
/// nothing, and a later one against a reading of unknown age. So a snapshot
/// takes its own short series: a reading now and one each second until
/// `windowMs` (default 2000, max 3000) has passed, and reports the last
/// interval's verdicts. That is the one bounded exception to "long actions are
/// ops"; anything longer is `media.watch`.
///
/// ## What `continuous` means
///
/// No gap longer than `maxGapMs`, where a gap is a run of `stalled`, `missing`
/// or `not_measured` intervals. `silent` counts as flowing: Opus DTX sends
/// silence whenever the room is quiet, and a summary that broke continuity on
/// every pause in a conversation would be ignored within a day — the histogram
/// still shows how much of it was silence. `not_measured` *does* break it,
/// because continuity is a claim that needs evidence. `paused` neither breaks
/// nor extends a gap: a peer's wire mute is not a fault, so it is reported on
/// its own as `pausedMs`, and it ends a gap run. A stall's gap starts where its
/// counters went flat (`flatForMs`), not where the stall window ran out.
///
/// ## `media.render`
///
/// Frames that decode are not frames on screen. `media.render` takes the same
/// short series as a snapshot and joins it with what every mounted video tile
/// reported to `RenderRegistry` (`../media/render_registry.dart`) — which
/// stream its renderer is bound to, whether a frame has come out of it — and
/// lists what does not line up (`render_check.dart` has the table): flowing
/// video with no tile, a tile on a stream that is not flowing or not there, two
/// tiles on one stream in one slot, a tile that never rendered, and (live only,
/// against `LiveCall.debugStreamOwners`) a renderer bound to someone else's
/// stream. With the call screen closed there are no tiles, and the answer says
/// `screenOpen: false` with `ok: null` rather than passing.
///
/// Everything here is read-only (`outward: false`): it calls `getStats` and
/// nothing else. No call at all is `refused('no_call')`; a call with no media
/// session answers a sample whose errors say so.
library;

import '../media/call.dart';
import '../media/live_call.dart';
import '../media/media_flow.dart';
import '../media/render_registry.dart';
import 'debug_drive.dart';
import 'drive_ops.dart';
import 'drive_result.dart';
import 'render_check.dart';

/// How a watch waits between readings. A test passes one that returns at once.
typedef DriveSleep = Future<void> Function(Duration);

Future<void> _realSleep(Duration d) => Future<void>.delayed(d);

/// `ext.gc.media.snapshot {windowMs?}`, `ext.gc.media.watch {durationMs?,
/// intervalMs?, maxGapMs?, stallAfterMs?}` (an op) and `ext.gc.media.render`.
///
/// `ext.gc.media.render {windowMs?, firstFrameWithinMs?}` takes the same short
/// series as a snapshot and cross-checks [registry]'s tiles against it
/// (`render_check.dart`). [registry] is a seam for tests; the app passes the one
/// the tiles write to.
DriveFeature mediaFeature({
  required Call? Function() call,
  required DriveOps ops,
  DriveSleep sleep = _realSleep,
  RenderRegistry? registry,
}) =>
    _mediaFeature(call: call, ops: ops, sleep: sleep, registry: registry ?? renderRegistry);

DriveFeature _mediaFeature({
  required Call? Function() call,
  required DriveOps ops,
  required DriveSleep sleep,
  required RenderRegistry registry,
}) =>
    DriveFeature('media', [
      DriveAction('snapshot', (args) async {
        final windowMs = args.optionalInt('windowMs', min: 500, max: 3000) ?? 2000;
        if (call() == null) return const DriveResult.refused('no_call');
        final series = await _series(call, sleep, windowMs);
        if (series == null) return const DriveResult.refused('no_call', {'detail': 'call ended during the snapshot'});
        return DriveResult.ok({
          'source': series.sample.source,
          'windowMs': series.windowMs,
          'verdicts': [for (final v in series.verdicts) v.toJson()],
          'sample': series.sample.toJson(),
        });
      }),
      DriveAction('render', (args) async {
        final windowMs = args.optionalInt('windowMs', min: 500, max: 3000) ?? 2000;
        final firstFrameWithinMs = args.optionalInt('firstFrameWithinMs', min: 0, max: 60000) ?? 3000;
        if (call() == null) return const DriveResult.refused('no_call');
        final series = await _series(call, sleep, windowMs);
        final handle = call();
        if (series == null || handle == null) {
          return const DriveResult.refused('no_call', {'detail': 'call ended during the render check'});
        }
        return DriveResult.ok({
          ...checkRender(
            tiles: registry.tiles,
            sample: series.sample,
            verdicts: series.verdicts,
            now: registry.now(),
            owners: handle is LiveCall ? handle.debugStreamOwners() : null,
            firstFrameWithin: Duration(milliseconds: firstFrameWithinMs),
          ),
          'windowMs': series.windowMs,
          'verdicts': [for (final v in series.verdicts) v.toJson()],
        });
      }),
      DriveAction('watch', (args) async {
        final durationMs = args.optionalInt('durationMs', min: 1000, max: 120000) ?? 10000;
        final intervalMs = args.optionalInt('intervalMs', min: 250, max: 10000) ?? 1000;
        final maxGapMs = args.optionalInt('maxGapMs', min: 0, max: 120000) ?? 2000;
        final stallAfterMs = args.optionalInt('stallAfterMs', min: 250, max: 60000) ?? 2000;
        if (call() == null) return const DriveResult.refused('no_call');
        final id = ops.start(
          'watch',
          _watch(
            call: call,
            sleep: sleep,
            intervals: (durationMs / intervalMs).ceil(),
            interval: Duration(milliseconds: intervalMs),
            maxGapMs: maxGapMs,
            stallAfter: Duration(milliseconds: stallAfterMs),
          ),
        );
        return DriveResult.ok({
          'id': id,
          'durationMs': durationMs,
          'intervalMs': intervalMs,
          'maxGapMs': maxGapMs,
          'stallAfterMs': stallAfterMs,
        });
      }),
    ]);

/// A reading now and one every second (or every [windowMs], if shorter) until
/// [windowMs] has passed, judged as a series; the last reading and its verdicts.
/// Null when the call ended part-way.
Future<({MediaFlowSample sample, List<StreamVerdict> verdicts, int windowMs})?> _series(
  Call? Function() call,
  DriveSleep sleep,
  int windowMs,
) async {
  final handle = call();
  if (handle == null) return null;
  final step = windowMs < 1000 ? windowMs : 1000;
  final judge = FlowJudge();
  var sample = await handle.sampleFlow();
  var verdicts = judge.judge(sample);
  final first = sample.at;
  for (var waited = 0; waited < windowMs; waited += step) {
    await sleep(Duration(milliseconds: step));
    final now = call();
    if (now == null) return null;
    sample = await now.sampleFlow();
    verdicts = judge.judge(sample);
  }
  return (sample: sample, verdicts: verdicts, windowMs: sample.at.difference(first).inMilliseconds);
}

Future<Map<String, Object?>> _watch({
  required Call? Function() call,
  required DriveSleep sleep,
  required int intervals,
  required Duration interval,
  required int maxGapMs,
  required Duration stallAfter,
}) async {
  final judge = FlowJudge(stallAfter: stallAfter);
  final readings = <FlowReading>[];
  String? endedEarly;
  String? failure;
  final first = call();
  if (first == null) {
    endedEarly = 'call_ended';
  } else {
    // `sampleFlow` promises never to throw, but a watch is up to two minutes of
    // evidence: one Call that breaks the promise must end the watch with what
    // was gathered so far and the error, not fail the op and lose all of it.
    try {
      final s = await first.sampleFlow();
      readings.add((sample: s, verdicts: judge.judge(s)));
      for (var i = 0; i < intervals; i++) {
        await sleep(interval);
        final handle = call();
        if (handle == null) {
          endedEarly = 'call_ended';
          break;
        }
        final next = await handle.sampleFlow();
        readings.add((sample: next, verdicts: judge.judge(next)));
      }
    } on Object catch (error) {
      endedEarly = 'sample_failed';
      failure = '$error';
    }
  }
  return {
    ...summarizeWatch(readings, maxGapMs: maxGapMs),
    'intervalMs': interval.inMilliseconds,
    'stallAfterMs': stallAfter.inMilliseconds,
    'endedEarly': endedEarly,
    'error': ?failure,
  };
}

/// One reading of a watch: the sample, and the verdicts against the one before.
typedef FlowReading = ({MediaFlowSample sample, List<StreamVerdict> verdicts});

/// Verdicts that break continuity. `silent` and `paused` do not — see the file
/// header.
const _gapVerdicts = {FlowVerdict.stalled, FlowVerdict.missing, FlowVerdict.notMeasured};

/// The per-stream summary and the compact timeline of a watch. The first
/// reading is the baseline: its verdicts (all `no_baseline`, or `missing`) are
/// in the timeline but not in any histogram, since they judge no interval.
Map<String, Object?> summarizeWatch(List<FlowReading> readings, {required int maxGapMs}) {
  final streams = <String, _StreamSummary>{};
  for (var i = 1; i < readings.length; i++) {
    final from = readings[i - 1].sample.at;
    final to = readings[i].sample.at;
    for (final v in readings[i].verdicts) {
      streams.putIfAbsent(v.key, () => _StreamSummary(v)).add(v, from, to);
    }
  }
  final summaries = [for (final s in streams.values) s.toJson(maxGapMs)];
  final expectedKeys = {
    for (final r in readings)
      for (final e in r.sample.expected) e.key,
  };
  return {
    'source': readings.isEmpty ? null : readings.last.sample.source,
    'startedAt': readings.isEmpty ? null : readings.first.sample.at.toUtc().toIso8601String(),
    'endedAt': readings.isEmpty ? null : readings.last.sample.at.toUtc().toIso8601String(),
    'durationMs': readings.length < 2 ? 0 : readings.last.sample.at.difference(readings.first.sample.at).inMilliseconds,
    'maxGapMs': maxGapMs,
    'samples': readings.length,
    // Every stream the app expected at any point, and every one present, held
    // up without a gap. Null with nothing judged: no evidence is not "healthy".
    'allContinuous': summaries.isEmpty ? null : summaries.every((s) => s['continuous'] == true),
    'expected': expectedKeys.toList(),
    'streams': summaries,
    'timeline': [
      for (final r in readings)
        {
          'at': r.sample.at.toUtc().toIso8601String(),
          'v': {for (final v in r.verdicts) v.key: v.verdict.wire},
          if (r.sample.errors.isNotEmpty) 'errors': [for (final e in r.sample.errors) e.toJson()],
        },
    ],
  };
}

class _StreamSummary {
  _StreamSummary(StreamVerdict first)
      : key = first.key,
        direction = first.direction,
        srcId = first.srcId,
        tag = first.tag;

  final String key;
  final String direction;
  final String? srcId;
  final String tag;

  final Map<String, int> histogram = {};
  final List<({DateTime from, DateTime to, Map<String, int> verdicts})> gaps = [];
  bool _inGap = false;
  int pausedMs = 0;
  int bytes = 0, bytesMs = 0;
  int frames = 0, framesMs = 0;
  int packets = 0, lost = 0;
  bool _lossKnown = false;

  void add(StreamVerdict v, DateTime from, DateTime to) {
    histogram.update(v.verdict.wire, (n) => n + 1, ifAbsent: () => 1);
    final ms = v.intervalMs ?? to.difference(from).inMilliseconds;
    if (v.bytes != null) {
      bytes += v.bytes!;
      bytesMs += ms;
    }
    if (v.frames != null) {
      frames += v.frames!;
      framesMs += ms;
    }
    if (v.packets != null && v.packetsLost != null) {
      packets += v.packets!;
      lost += v.packetsLost!;
      _lossKnown = true;
    }

    if (v.verdict == FlowVerdict.paused) pausedMs += ms;
    if (!_gapVerdicts.contains(v.verdict)) {
      _inGap = false;
      return;
    }
    // A stall began when the counters went flat, which may be before this
    // interval: the grace intervals before it were reported as their last good
    // verdict, but nothing moved in them.
    final start = v.flatForMs == null ? from : _earlier(from, to.subtract(Duration(milliseconds: v.flatForMs!)));
    if (_inGap) {
      final last = gaps.removeLast();
      last.verdicts.update(v.verdict.wire, (n) => n + 1, ifAbsent: () => 1);
      gaps.add((from: _earlier(last.from, start), to: to, verdicts: last.verdicts));
    } else {
      final previous = gaps.isEmpty ? null : gaps.last;
      if (previous != null && !start.isAfter(previous.to)) {
        // A backdated stall reaching into the gap before it is the same gap.
        gaps.removeLast();
        previous.verdicts.update(v.verdict.wire, (n) => n + 1, ifAbsent: () => 1);
        gaps.add((from: previous.from, to: to, verdicts: previous.verdicts));
      } else {
        gaps.add((from: start, to: to, verdicts: {v.verdict.wire: 1}));
      }
      _inGap = true;
    }
  }

  static DateTime _earlier(DateTime a, DateTime b) => a.isBefore(b) ? a : b;

  Map<String, Object?> toJson(int maxGapMs) {
    final gapJson = [
      for (final g in gaps)
        {
          'from': g.from.toUtc().toIso8601String(),
          'to': g.to.toUtc().toIso8601String(),
          'ms': g.to.difference(g.from).inMilliseconds,
          // The verdict that filled most of the gap; ties go to the worse.
          'verdict': (g.verdicts.entries.toList()
                ..sort((a, b) => b.value != a.value ? b.value - a.value : _rank(b.key) - _rank(a.key)))
              .first
              .key,
        },
    ];
    final longest = gapJson.fold<int>(0, (m, g) => (g['ms']! as int) > m ? g['ms']! as int : m);
    final video = tag != 'audio';
    return {
      'key': key,
      'direction': direction,
      'srcId': ?srcId,
      'tag': tag,
      'verdicts': histogram,
      'continuous': longest <= maxGapMs,
      'everFlowing': (histogram['flowing'] ?? 0) + (histogram['silent'] ?? 0) > 0,
      'gaps': gapJson,
      'longestGapMs': longest,
      'pausedMs': pausedMs,
      'avgBitrateKbps': bytesMs == 0 ? null : _round(bytes * 8 / bytesMs),
      if (video) 'avgFps': framesMs == 0 ? null : _round(frames * 1000 / framesMs),
      if (direction == 'inbound') 'lossPct': !_lossKnown || packets + lost == 0 ? null : _round(lost * 100 / (packets + lost)),
    };
  }

  static int _rank(String verdict) => switch (verdict) {
        'missing' => 3,
        'stalled' => 2,
        _ => 1,
      };

  static double _round(num v) => (v * 10).round() / 10;
}
