/// Calls one debug-drive action on a running debug build and prints the answer.
///
/// The drive (`lib/src/debug_drive/`) is a set of `ext.gc.*` VM service
/// extensions. An agent can reach them through `dart mcp-server`; this is the
/// same thing for a shell, a script, or a person, with no MCP in between:
///
/// ```sh
/// flutter run -t lib/main_harness.dart -d <udid> \
///   --vmservice-out-file=.dart_tool/vm_uri.<udid> ...
/// tool/drive.sh -d <udid> state.dump
/// tool/drive.sh -d <udid> move.goTo '{"x":12,"y":7}' --wait
/// ```
///
/// Every invocation is one short-lived connection: read the URI file, connect,
/// `getVM`, pick the isolate, call, disconnect. Nothing is cached between runs,
/// and that is deliberate. A hot restart makes a new isolate with a new id, and
/// a cached id answers `-32601 Unknown method` — the misleading failure that
/// reads as "the drive is not installed". Asking `getVM` every time costs a few
/// milliseconds and cannot be stale.
///
/// The isolate picked is the one whose `extensionRPCs` lists
/// `ext.gc.drive.list`, so a build with the drive installed is found even when
/// it is not the first isolate; without one, the first non-system isolate is
/// tried and the RPC error that comes back says what is missing.
///
/// `--wait` turns a start/poll op into one blocking call. It polls
/// `ext.gc.op.result` on the isolate that started the op, and checks on every
/// poll that the isolate still exists: after a hot restart the op is gone, and
/// the honest answer is "unavailable, re-run it" (69), not a timeout and not
/// another op's result.
///
/// The URI file carries the VM service auth code. It lives in `.dart_tool/`,
/// which is git-ignored; never paste it anywhere, and never run `flutter run`
/// with `--disable-service-auth-codes` to make this easier.
///
/// Pure parts (argument parsing, URI handling, exit codes) are in
/// `drive_cli.dart` and tested by `test/tool/drive_cli_test.dart`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

import 'drive_cli.dart';

const String _listMethod = 'ext.gc.drive.list';
const Duration _connectTimeout = Duration(seconds: 5);
const Duration _pollEvery = Duration(milliseconds: 500);
const JsonEncoder _pretty = JsonEncoder.withIndent('  ');

/// Ends the run with [code]. Thrown rather than calling `exit` inline so the
/// connection is always disposed on the way out.
class _Exit implements Exception {
  _Exit(this.code, [this.message]);

  final int code;
  final String? message;
}

Future<void> main(List<String> argv) async {
  final DriveCommand? command;
  try {
    command = parseDriveArgs(argv);
  } on DriveUsageError catch (e) {
    stderr
      ..writeln('drive: $e')
      ..writeln(usage);
    exit(exitUsage);
  }
  if (command == null) {
    stdout.writeln(usage);
    exit(exitOk);
  }

  VmService? service;
  var code = exitOk;
  try {
    service = await _connect(command.device);
    code = await _run(service, command);
  } on _Exit catch (e) {
    if (e.message != null) stderr.writeln('drive: ${e.message}');
    code = e.code;
  } catch (e) {
    // Last resort, so no path exits outside the documented codes: anything not
    // already mapped is the connection failing under a call.
    stderr.writeln('drive: unexpected failure talking to the app ($e)');
    code = exitUnavailable;
  } finally {
    await service?.dispose();
  }
  exit(code);
}

Future<VmService> _connect(String? device) async {
  final dir = Directory('.dart_tool');
  final names = dir.existsSync()
      ? [
          for (final entry in dir.listSync())
            if (entry is File) entry.uri.pathSegments.last,
        ].where((n) => n == 'vm_uri' || n.startsWith('vm_uri.'))
      : const <String>[];

  final String? fileName;
  try {
    fileName = pickUriFile(device, names);
  } on DriveUsageError catch (e) {
    throw _Exit(exitUsage, '$e');
  }
  if (fileName == null) {
    final which = device == null ? 'vm_uri' : 'vm_uri.$device';
    throw _Exit(
      exitUnavailable,
      'no .dart_tool/$which — start the app with '
      'flutter run --vmservice-out-file=.dart_tool/vm_uri${device == null ? '' : '.$device'} '
      '(run this from the repo root)',
    );
  }

  final file = File('.dart_tool/$fileName');
  final Uri ws;
  try {
    ws = toWebSocketUri(file.readAsStringSync());
  } on FormatException catch (e) {
    throw _Exit(exitUnavailable, '${file.path} does not hold a VM service URI (${e.message})');
  }

  try {
    return await vmServiceConnectUri(ws.toString()).timeout(_connectTimeout);
  } catch (e) {
    // The usual cause: `flutter run` exited and left its URI file behind.
    throw _Exit(
      exitUnavailable,
      'nothing answers at ${file.path} ($e) — is flutter run still running?',
    );
  }
}

/// The isolate carrying the drive, or the first non-system one.
Future<IsolateRef> _pickIsolate(VmService service) async {
  final vm = await _getVM(service);
  final isolates = vm.isolates ?? const <IsolateRef>[];
  if (isolates.isEmpty) throw _Exit(exitUnavailable, 'the VM has no isolates');
  for (final ref in isolates) {
    try {
      final isolate = await service.getIsolate(ref.id!);
      if (isolate.extensionRPCs?.contains(_listMethod) ?? false) return ref;
    } on SentinelException {
      // Exited between getVM and getIsolate; the next one may be the app.
    } on RPCError catch (e) {
      throw _Exit(exitRpcError, 'getIsolate ${ref.id} failed: ${e.message} (code ${e.code})');
    } catch (e) {
      // The socket closed under us: the app went away mid-call.
      throw _Exit(exitUnavailable, 'connection lost asking getIsolate ($e)');
    }
  }
  return isolates.first;
}

Future<int> _run(VmService service, DriveCommand command) async {
  final isolate = await _pickIsolate(service);
  final envelope = await _call(service, isolate, command.method, command.argsJson);
  if (!command.wait) {
    stdout.writeln(_pretty.convert(envelope));
    return exitCodeFor(envelope);
  }

  final opId = opIdOf(envelope);
  if (opId == null) {
    stdout.writeln(_pretty.convert(envelope));
    if (envelope['ok'] == false) return exitRefused; // refused before an op began
    throw _Exit(exitUsage, '--wait: ${command.method} did not return an op id in data.id');
  }
  return _wait(service, isolate, opId, command.timeout);
}

Future<int> _wait(VmService service, IsolateRef isolate, String opId, Duration timeout) async {
  final deadline = DateTime.now().add(timeout);
  Map<String, Object?>? last;
  while (true) {
    final vm = await _getVM(service);
    final alive = (vm.isolates ?? const <IsolateRef>[]).any((i) => i.id == isolate.id);
    if (!alive) {
      throw _Exit(
        exitUnavailable,
        'isolate ${isolate.id} is gone (hot restart?) — op $opId went with it; re-run the action',
      );
    }

    last = await _call(service, isolate, 'ext.gc.op.result', jsonEncode({'id': opId}));
    final OpProgress progress;
    try {
      progress = opProgressOf(last);
    } on FormatException catch (e) {
      stdout.writeln(_pretty.convert(last));
      throw _Exit(exitRpcError, e.message);
    }
    if (progress != OpProgress.pending) {
      stdout.writeln(_pretty.convert(last));
      return exitCodeForOp(last);
    }

    if (DateTime.now().isAfter(deadline)) {
      stdout.writeln(_pretty.convert(last));
      throw _Exit(
        exitTimeout,
        'op $opId still pending after ${timeout.inSeconds}s — poll op.result again',
      );
    }
    await Future<void>.delayed(_pollEvery);
  }
}

/// `getVM`, with a dropped connection reported as the app going away rather
/// than as an unhandled exception.
Future<VM> _getVM(VmService service) async {
  try {
    return await service.getVM();
  } catch (e) {
    throw _Exit(exitUnavailable, 'connection lost asking getVM ($e)');
  }
}

/// One extension call; RPC errors are printed as JSON and become exit codes.
Future<Map<String, Object?>> _call(
  VmService service,
  IsolateRef isolate,
  String method,
  String argsJson,
) async {
  try {
    final response = await service.callServiceExtension(
      method,
      isolateId: isolate.id,
      args: {'args': argsJson},
    );
    return stripTransport((response.json ?? const {}).cast<String, Object?>());
  } on SentinelException catch (e) {
    throw _Exit(exitUnavailable, 'isolate ${isolate.id} is gone ($e) — re-run the action');
  } on RPCError catch (e) {
    final details = _decodeDetails(e.details);
    stdout.writeln(_pretty.convert({
      'error': {'code': e.code, 'message': e.message, 'details': ?details},
    }));
    // An op started in an isolate that has since been replaced: the honest
    // answer is "gone", the same as the isolate check in [_wait].
    if (details is Map && '${details['error']}'.contains('from another isolate')) {
      throw _Exit(exitUnavailable, 'op is from another isolate — re-run the action');
    }
    if (e.code == RPCErrorKind.kMethodNotFound.code) {
      throw _Exit(
        exitRpcError,
        '$method is not on isolate ${isolate.name ?? isolate.id} — is this a debug build '
        'with the drive installed? Ask drive.list',
      );
    }
    throw _Exit(exitRpcError);
  } on _Exit {
    rethrow;
  } catch (e) {
    // The socket closed under us: the app went away mid-call.
    throw _Exit(exitUnavailable, 'connection lost during $method ($e)');
  }
}

/// The drive puts a JSON object in an error's details; show it as one.
Object? _decodeDetails(String? details) {
  if (details == null) return null;
  try {
    return jsonDecode(details);
  } on FormatException {
    return details;
  }
}
