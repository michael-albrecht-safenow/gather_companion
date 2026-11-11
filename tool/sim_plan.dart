/// Runs `docs/sim_test_plan.md` on a simulator, through the debug drive only.
///
/// ```sh
/// tool/sim_plan.sh                      # every row, first booted simulator
/// tool/sim_plan.sh --only C4,C5         # some rows
/// tool/sim_plan.sh -d <udid> -p 4       # a given simulator, cast size
/// tool/sim_plan.sh --list               # the rows and their claims
/// ```
///
/// Each row is one `flutter run -t lib/main_harness.dart` with that row's
/// `TARGET`/`SCENARIO`/`PARTICIPANTS`, writing its VM service URI to
/// `.dart_tool/vm_uri.<udid>`; the runner waits for the drive to answer, runs
/// the row's drive actions, prints `PASS`/`FAIL` with the values it judged,
/// and quits that `flutter run` (`q` on its stdin, then a kill and a
/// `simctl terminate` if it lingers) before the next row starts. No `idb`, no
/// screenshot, no tap by coordinate: what each row claims is state, and the
/// drive reads state.
///
/// The judging is `sim_plan_check.dart`, pure and unit-tested; this file only
/// launches, records and stops. The connection is `drive_client.dart`, the same
/// code `tool/drive.sh` uses, held open for a row because the spotlight rows
/// sample `call.spotlight` every [_sampleEvery] — a process per sample would
/// be slower than the dwell being measured.
///
/// Exit: 0 every row passed, 1 a row failed or could not run, 64 usage.
/// A row's `flutter run` output goes to `.dart_tool/sim_plan/<row>.log`, and a
/// row that could not launch says so and points there.
///
/// Never launches the GatherV2 desktop app and never reaches Gather: the
/// harness has no wire.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:vm_service/vm_service.dart';

import 'drive_client.dart';
import 'sim_plan_check.dart';

const String _bundleId = 'com.jonasgrunau.gatherCompanion';
const Duration _sampleEvery = Duration(milliseconds: 200);
const Duration _launchTimeout = Duration(minutes: 6);
const Duration _sceneTimeout = Duration(seconds: 30);

const String _usage = '''
usage: tool/sim_plan.sh [-d <udid>] [-p <participants>] [--only C1,A2,...] [--list]

  -d <udid>          simulator to run on (default: the first booted one)
  -p <n>             PARTICIPANTS for every row, 2–8 (default 4)
  --only <ids>       run only these rows (comma-separated, repeatable)
  --list             print the rows and exit

exit: 0 all PASS, 1 any FAIL or a row that could not run, 64 usage''';

Future<void> main(List<String> argv) async {
  String? device;
  var participants = 4;
  final only = <String>[];
  var list = false;
  try {
    for (var i = 0; i < argv.length; i++) {
      String value() {
        if (i + 1 >= argv.length) throw FormatException('${argv[i]} needs a value');
        return argv[++i];
      }

      switch (argv[i]) {
        case '-d' || '--device':
          device = value();
        case '-p' || '--participants':
          final n = int.tryParse(value());
          if (n == null || n < 2 || n > 8) throw const FormatException('-p wants 2–8');
          participants = n;
        case '--only':
          only.addAll(value().split(','));
        case '--list':
          list = true;
        case '-h' || '--help':
          stdout.writeln(_usage);
          exit(0);
        default:
          throw FormatException('unknown argument "${argv[i]}"');
      }
    }
  } on FormatException catch (e) {
    stderr
      ..writeln('sim_plan: ${e.message}')
      ..writeln(_usage);
    exit(64);
  }

  final List<PlanRow> rows;
  try {
    rows = selectRows(only);
  } on ArgumentError catch (e) {
    stderr.writeln('sim_plan: ${e.message}');
    exit(64);
  }
  if (list) {
    for (final r in rows) {
      stdout.writeln('${r.id}  TARGET=${r.target} SCENARIO=${r.scenario}  ${r.claim}');
    }
    exit(0);
  }

  device ??= await _bootedSimulator();
  if (device == null) {
    stderr.writeln('sim_plan: no booted simulator — boot one (xcrun simctl boot <udid>) or pass -d');
    exit(64);
  }

  stdout.writeln('sim plan on $device, PARTICIPANTS=$participants, rows ${rows.map((r) => r.id).join(' ')}');
  final verdicts = <RowVerdict>[];
  for (final row in rows) {
    final verdict = await _runRow(row, device, participants);
    verdicts.add(verdict);
    stdout.writeln(verdict.format());
  }

  final failed = [for (final v in verdicts) if (!v.pass) v.id];
  stdout.writeln(failed.isEmpty
      ? 'ALL ${verdicts.length} PASS'
      : '${verdicts.length - failed.length}/${verdicts.length} PASS; FAIL: ${failed.join(' ')}');
  exit(failed.isEmpty ? 0 : 1);
}

Future<String?> _bootedSimulator() async {
  final r = await Process.run('xcrun', ['simctl', 'list', 'devices', 'booted', '-j']);
  if (r.exitCode != 0) return null;
  final devices = (jsonDecode(r.stdout as String) as Map)['devices'] as Map;
  for (final runtime in devices.values) {
    for (final d in runtime as List) {
      if ((d as Map)['state'] == 'Booted') return d['udid'] as String;
    }
  }
  return null;
}

// ---- one row ----------------------------------------------------------------

Future<RowVerdict> _runRow(PlanRow row, String device, int participants) async {
  final logDir = Directory('.dart_tool/sim_plan')..createSync(recursive: true);
  final logPath = '${logDir.path}/${row.id}.log';
  var run = await _FlutterRun.start(row, device, participants, logPath);
  DriveClient? client;
  try {
    try {
      client = await run.waitForDrive();
    } on _BuildFailed {
      // One retry for a build that died before the app started: Xcode's
      // package resolution ("Missing package product 'FlutterFramework'")
      // fails transiently when another flutter command touches the same
      // checkout's ephemeral package. A second failure is the row's answer.
      await run.stop();
      run = await _FlutterRun.start(row, device, participants, logPath, attempt: 2);
      client = await run.waitForDrive();
    }
    return await switch (row.id) {
      'C1' || 'C2' || 'C4' || 'C5' || 'C6' || 'C7' => _autoRow(client, row, participants),
      'C3' => _manualRow(client, participants),
      'A1' => _officeRow(client, row, participants),
      'A2' => _stillRow(client, row, participants),
      _ => throw StateError('no runner for ${row.id}'),
    };
  } catch (e) {
    return RowVerdict(row.id, evidence: {'log': logPath}, failures: ['could not run: $e']);
  } finally {
    await client?.dispose();
    await run.stop();
  }
}

/// A connection to the row's app, with the isolate pinned for the row: one
/// `flutter run` per row and no hot restart inside it.
class _Drive {
  _Drive(this.client, this.isolate);

  final DriveClient client;
  final IsolateRef isolate;

  Future<Map<String, Object?>> call(String action, [Map<String, Object?> args = const {}]) =>
      client.callOn(isolate, 'ext.gc.$action', jsonEncode(args));

  /// `data` of an ok answer; anything else is a failure of the row's setup.
  Future<Map<String, Object?>> data(String action, [Map<String, Object?> args = const {}]) async {
    final env = await call(action, args);
    if (env['ok'] != true) throw StateError('$action answered ${jsonEncode(env)}');
    return (env['data'] as Map).cast<String, Object?>();
  }

  Future<Map<String, Object?>> wait(String action, Map<String, Object?> args) async {
    final start = await call(action, args);
    final data = start['data'];
    final id = start['ok'] == true && data is Map ? data['id'] as String? : null;
    if (id == null) return start;
    return client.waitOp(isolate, id, const Duration(seconds: 60));
  }

  /// Polls [read] until [ready] holds, or fails the row after [_sceneTimeout].
  Future<T> until<T>(Future<T> Function() read, bool Function(T) ready, String what) async {
    final deadline = DateTime.now().add(_sceneTimeout);
    while (true) {
      final value = await read();
      if (ready(value)) return value;
      if (DateTime.now().isAfter(deadline)) {
        throw StateError('timed out waiting for $what (last: ${jsonEncode(value)})');
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  }
}

Future<_Drive> _pin(DriveClient client) async => _Drive(client, await client.pickIsolate());

/// The call screen is mounted and the scenario has seated its cast.
Future<SpotSample> _callReady(_Drive d) => d.until<SpotSample?>(
      () async {
        final env = await d.call('call.spotlight', {'historyMax': 0});
        return env['ok'] == true ? SpotSample.fromReadout(env) : null;
      },
      (s) => s != null && s.tiles.isNotEmpty,
      'the call screen',
    ).then((s) => s!);

Future<RowVerdict> _autoRow(DriveClient client, PlanRow row, int participants) async {
  final d = await _pin(client);
  await _callReady(d);
  final flip = SpotSample.fromReadout(await d.data('call.spotlight.mode', {'mode': 'auto'}));
  final samples = <SpotSample>[];
  final end = DateTime.now().add(row.watch);
  while (DateTime.now().isBefore(end)) {
    samples.add(SpotSample.fromReadout(await d.data('call.spotlight', {'historyMax': 0})));
    await Future<void>.delayed(_sampleEvery);
  }
  final last = SpotSample.fromReadout(await d.data('call.spotlight'));
  final run = SpotRun(flip: flip, samples: samples, last: last);
  final verdict = switch (row.id) {
    'C1' => checkSolo(run),
    'C2' => checkPair(run),
    'C4' => checkRoundRobin(run, participants: participants, watch: row.watch),
    'C5' => checkDebate(run, watch: row.watch),
    'C6' => checkBriefNoise(run),
    'C7' => checkChurn(run, participants: participants),
    _ => throw StateError('${row.id} is not an auto row'),
  };
  // "No crash": the app still answers after the watch.
  final alive = await d.call('state.dump');
  verdict.check(alive['ok'] == true, 'state.dump after the watch answered ${jsonEncode(alive)}');
  return verdict;
}

Future<RowVerdict> _manualRow(DriveClient client, int participants) async {
  final d = await _pin(client);
  final rest = await d.until<SpotSample>(
    () => _callReady(d),
    (s) => s.others.length == participants,
    'the group to be seated',
  );
  final pickId = rest.others.isEmpty ? '' : rest.others.first;
  final picked = SpotSample.fromReadout(await d.data('call.spotlight.pick', {'id': pickId}));
  final overview = SpotSample.fromReadout(await d.data('call.spotlight.overview'));
  return checkGroupManual(
    participants: participants,
    rest: rest,
    pickedId: pickId,
    picked: picked,
    overview: overview,
  );
}

/// The office is home, the roster is in, the cast is placed and the activity
/// seeds have landed.
Future<void> _officeReady(_Drive d, int participants) async {
  await d.until<Map<String, Object?>>(
    () => d.data('state.dump'),
    (s) => s['phase'] == 'home' && (s['roster'] as Map?)?['peopleOnMap'] == participants,
    'the office to load',
  );
  await d.until<Map<String, Object?>>(
    () => d.data('activity.list', {'max': 50}),
    (a) => activityIds(a).where((id) => id.startsWith('seed-wave-')).length >= expectedSeeds(participants),
    'the seeded activity',
  );
}

Future<RowVerdict> _officeRow(DriveClient client, PlanRow row, int participants) async {
  final d = await _pin(client);
  await _officeReady(d, participants);
  final activityBefore = await d.data('activity.list', {'max': 50});
  final peopleBefore = await d.data('presence.map.people', {'max': 50});
  await Future<void>.delayed(const Duration(seconds: 2));
  final peopleAfter = await d.data('presence.map.people', {'max': 50});
  // The rest of the watch for a live wave (one every ~4.8 s).
  await Future<void>.delayed(row.watch - const Duration(seconds: 2));
  final activityAfter = await d.data('activity.list', {'max': 50});
  // Tap-to-walk, minus the tap: the same AppState.goTo the "Go here" button
  // calls, to a tile nobody stands on.
  final tile = emptyTile(peopleAfter, const [(x: 18, y: 7), (x: 1, y: 7), (x: 10, y: 1), (x: 10, y: 13)]);
  final walk = await d.wait('move.goTo', {'x': tile.x, 'y': tile.y, 'timeoutMs': 30000});
  final stateAfter = await d.data('state.dump');
  return checkOffice(
    participants: participants,
    activityBefore: activityBefore,
    activityAfter: activityAfter,
    peopleBefore: peopleBefore,
    peopleAfter: peopleAfter,
    walk: walk,
    stateAfterWalk: stateAfter,
  );
}

Future<RowVerdict> _stillRow(DriveClient client, PlanRow row, int participants) async {
  final d = await _pin(client);
  await _officeReady(d, participants);
  final activityBefore = await d.data('activity.list', {'max': 50});
  final peopleBefore = await d.data('presence.map.people', {'max': 50});
  await Future<void>.delayed(row.watch);
  final activityAfter = await d.data('activity.list', {'max': 50});
  final peopleAfter = await d.data('presence.map.people', {'max': 50});
  return checkStill(
    participants: participants,
    activityBefore: activityBefore,
    activityAfter: activityAfter,
    peopleBefore: peopleBefore,
    peopleAfter: peopleAfter,
  );
}

// ---- flutter run ------------------------------------------------------------

/// `flutter run` exited before the app came up — a build failure, retried once.
class _BuildFailed implements Exception {
  _BuildFailed(this.message);

  final String message;

  @override
  String toString() => message;
}

/// One `flutter run` of the harness, its output teed to a log file.
class _FlutterRun {
  _FlutterRun._(this.process, this.device, this.uriFile, this.log, this.logPath);

  final Process process;
  final String device;
  final File uriFile;
  final IOSink log;
  final String logPath;
  int? _exitCode;

  static Future<_FlutterRun> start(PlanRow row, String device, int participants, String logPath,
      {int attempt = 1}) async {
    final uriFile = File('.dart_tool/vm_uri.$device');
    // A file left by an earlier run would point the drive at a dead service.
    if (uriFile.existsSync()) uriFile.deleteSync();
    final log = File(logPath).openWrite(mode: attempt == 1 ? FileMode.write : FileMode.append);
    if (attempt > 1) log.writeln('\n--- attempt $attempt ---');
    final args = [
      'run',
      '-t',
      'lib/main_harness.dart',
      '-d',
      device,
      '--vmservice-out-file=${uriFile.path}',
      '--dart-define=TARGET=${row.target}',
      '--dart-define=SCENARIO=${row.scenario}',
      '--dart-define=PARTICIPANTS=$participants',
    ];
    log.writeln('> flutter ${args.join(' ')}');
    final process = await Process.start('flutter', args);
    final run = _FlutterRun._(process, device, uriFile, log, logPath);
    process.stdout.listen(log.add);
    process.stderr.listen(log.add);
    unawaited(process.exitCode.then((c) => run._exitCode = c));
    return run;
  }

  /// Waits for the URI file, then for `drive.list` to answer.
  Future<DriveClient> waitForDrive() async {
    final deadline = DateTime.now().add(_launchTimeout);
    while (!uriFile.existsSync() || uriFile.lengthSync() == 0) {
      if (_exitCode != null) throw _BuildFailed('flutter run exited $_exitCode before the app started (see $logPath)');
      if (DateTime.now().isAfter(deadline)) throw StateError('no VM service after ${_launchTimeout.inMinutes} min (see $logPath)');
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    while (true) {
      try {
        final client = await DriveClient.connect(device);
        final env = await client.call('ext.gc.drive.list');
        if (env['ok'] == true) return client;
        await client.dispose();
      } on DriveClientError {
        // The isolate is still coming up.
      }
      if (_exitCode != null) throw StateError('flutter run exited $_exitCode (see $logPath)');
      if (DateTime.now().isAfter(deadline)) throw StateError('the drive never answered (see $logPath)');
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
  }

  /// `q`, then a kill, then the app itself — every launch is stopped.
  Future<void> stop() async {
    if (_exitCode == null) {
      try {
        process.stdin.write('q');
        await process.stdin.flush();
      } catch (_) {
        // stdin already closed: the process is on its way out.
      }
      final exited = await process.exitCode.timeout(const Duration(seconds: 20), onTimeout: () => -1);
      if (exited == -1) {
        process.kill();
        await process.exitCode.timeout(const Duration(seconds: 10), onTimeout: () {
          process.kill(ProcessSignal.sigkill);
          return -9;
        });
      }
    }
    await Process.run('xcrun', ['simctl', 'terminate', device, _bundleId]);
    if (uriFile.existsSync()) uriFile.deleteSync();
    await log.flush();
    await log.close();
  }
}
