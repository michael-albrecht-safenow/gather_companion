/// The socket half of the drive's shell door, as a library: find the URI file,
/// connect, pick the isolate that carries the drive, call one action, poll an
/// op. `tool/drive.dart` is one call of it per process; `tool/sim_plan.dart`
/// holds one [DriveClient] open for a whole row, because the spotlight rows
/// sample the readout every couple of hundred milliseconds and a fresh
/// `dart run` per sample would be slower than the dwell it is trying to see.
///
/// Holding a connection does not bring back the stale-isolate trap
/// `drive.dart`'s header warns about: [DriveClient.call] asks `getVM` for the
/// isolate every time ([DriveClient.pickIsolate] is not cached), so a hot
/// restart under a long-lived client is found the same way it is found by a
/// one-shot one.
///
/// Failures are [DriveClientError]s carrying the exit code `drive_cli.dart`
/// defines, so the one-shot CLI maps them straight to its exit status and the
/// runner can tell "the app went away" (69) from "the drive broke" (2).
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

/// A drive call that could not produce an envelope. [code] is one of the exit
/// codes in `drive_cli.dart`; [rpcError] is the JSON-RPC error as the CLI
/// prints it, when there was one.
class DriveClientError implements Exception {
  DriveClientError(this.code, [this.message, this.rpcError]);

  final int code;
  final String? message;
  final Map<String, Object?>? rpcError;

  @override
  String toString() => message ?? 'drive error (exit $code)';
}

/// One open VM service connection to a debug build with the drive installed.
class DriveClient {
  DriveClient._(this.service, this.uriFile);

  final VmService service;

  /// The `.dart_tool/vm_uri*` file the connection was read from.
  final String uriFile;

  /// Connects through the URI file for [device] in [dartTool] (the repo's
  /// `.dart_tool/`), by the rules of [pickUriFile].
  static Future<DriveClient> connect(String? device, {String dartTool = '.dart_tool'}) async {
    final dir = Directory(dartTool);
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
      throw DriveClientError(exitUsage, '$e');
    }
    if (fileName == null) {
      final which = device == null ? 'vm_uri' : 'vm_uri.$device';
      throw DriveClientError(
        exitUnavailable,
        'no $dartTool/$which — start the app with '
        'flutter run --vmservice-out-file=.dart_tool/vm_uri${device == null ? '' : '.$device'} '
        '(run this from the repo root)',
      );
    }

    final file = File('$dartTool/$fileName');
    final Uri ws;
    try {
      ws = toWebSocketUri(file.readAsStringSync());
    } on FormatException catch (e) {
      throw DriveClientError(exitUnavailable, '${file.path} does not hold a VM service URI (${e.message})');
    }

    try {
      final service = await vmServiceConnectUri(ws.toString()).timeout(_connectTimeout);
      return DriveClient._(service, file.path);
    } catch (e) {
      // The usual cause: `flutter run` exited and left its URI file behind.
      throw DriveClientError(
        exitUnavailable,
        'nothing answers at ${file.path} ($e) — is flutter run still running?',
      );
    }
  }

  Future<void> dispose() => service.dispose();

  /// The isolate carrying the drive, or the first non-system one. Asked fresh
  /// on every call.
  Future<IsolateRef> pickIsolate() async {
    final vm = await _getVM();
    final isolates = vm.isolates ?? const <IsolateRef>[];
    if (isolates.isEmpty) throw DriveClientError(exitUnavailable, 'the VM has no isolates');
    for (final ref in isolates) {
      try {
        final isolate = await service.getIsolate(ref.id!);
        if (isolate.extensionRPCs?.contains(_listMethod) ?? false) return ref;
      } on SentinelException {
        // Exited between getVM and getIsolate; the next one may be the app.
      } on RPCError catch (e) {
        throw DriveClientError(exitRpcError, 'getIsolate ${ref.id} failed: ${e.message} (code ${e.code})');
      } catch (e) {
        throw DriveClientError(exitUnavailable, 'connection lost asking getIsolate ($e)');
      }
    }
    return isolates.first;
  }

  /// Whether [isolate] still exists (a hot restart replaces it).
  Future<bool> isAlive(IsolateRef isolate) async {
    final vm = await _getVM();
    return (vm.isolates ?? const <IsolateRef>[]).any((i) => i.id == isolate.id);
  }

  /// Calls [method] (full `ext.gc.` name) with [args] on the drive's isolate
  /// and returns the envelope. Convenience over [callOn] for callers that do
  /// not need to pin the isolate.
  Future<Map<String, Object?>> call(String method, [Map<String, Object?> args = const {}]) async {
    final isolate = await pickIsolate();
    return callOn(isolate, method, jsonEncode(args));
  }

  /// One extension call on [isolate]; an RPC error becomes a
  /// [DriveClientError] with [DriveClientError.rpcError] set.
  Future<Map<String, Object?>> callOn(IsolateRef isolate, String method, String argsJson) async {
    try {
      final response = await service.callServiceExtension(
        method,
        isolateId: isolate.id,
        args: {'args': argsJson},
      );
      return stripTransport((response.json ?? const {}).cast<String, Object?>());
    } on SentinelException catch (e) {
      throw DriveClientError(exitUnavailable, 'isolate ${isolate.id} is gone ($e) — re-run the action');
    } on RPCError catch (e) {
      final details = _decodeDetails(e.details);
      final printed = <String, Object?>{
        'error': {'code': e.code, 'message': e.message, 'details': ?details},
      };
      // An op started in an isolate that has since been replaced: the honest
      // answer is "gone", the same as the isolate check in [waitOp].
      if (details is Map && '${details['error']}'.contains('from another isolate')) {
        throw DriveClientError(exitUnavailable, 'op is from another isolate — re-run the action', printed);
      }
      if (e.code == RPCErrorKind.kMethodNotFound.code) {
        throw DriveClientError(
          exitRpcError,
          '$method is not on isolate ${isolate.name ?? isolate.id} — is this a debug build '
          'with the drive installed? Ask drive.list',
          printed,
        );
      }
      throw DriveClientError(exitRpcError, null, printed);
    } on DriveClientError {
      rethrow;
    } catch (e) {
      throw DriveClientError(exitUnavailable, 'connection lost during $method ($e)');
    }
  }

  /// Polls `op.result` for [opId] on [isolate] until it is done or failed and
  /// returns that envelope. Throws [DriveClientError] with [exitTimeout] (and
  /// the last pending envelope in [DriveClientError.rpcError]'s place, under
  /// `last`) when [timeout] runs out, or [exitUnavailable] if the isolate goes.
  Future<Map<String, Object?>> waitOp(IsolateRef isolate, String opId, Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      if (!await isAlive(isolate)) {
        throw DriveClientError(
          exitUnavailable,
          'isolate ${isolate.id} is gone (hot restart?) — op $opId went with it; re-run the action',
        );
      }
      final last = await callOn(isolate, 'ext.gc.op.result', jsonEncode({'id': opId}));
      final OpProgress progress;
      try {
        progress = opProgressOf(last);
      } on FormatException catch (e) {
        throw DriveClientError(exitRpcError, e.message, {'last': last});
      }
      if (progress != OpProgress.pending) return last;
      if (DateTime.now().isAfter(deadline)) {
        throw DriveClientError(
          exitTimeout,
          'op $opId still pending after ${timeout.inSeconds}s — poll op.result again',
          {'last': last},
        );
      }
      await Future<void>.delayed(_pollEvery);
    }
  }

  /// Starts an op-returning [method] and waits for it: the `op.result`
  /// envelope, or the start envelope itself when it was refused before an op
  /// began.
  Future<Map<String, Object?>> callAndWait(
    String method, [
    Map<String, Object?> args = const {},
    Duration timeout = const Duration(seconds: 60),
  ]) async {
    final isolate = await pickIsolate();
    final start = await callOn(isolate, method, jsonEncode(args));
    final id = opIdOf(start);
    if (id == null) return start;
    return waitOp(isolate, id, timeout);
  }

  Future<VM> _getVM() async {
    try {
      return await service.getVM();
    } catch (e) {
      throw DriveClientError(exitUnavailable, 'connection lost asking getVM ($e)');
    }
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
