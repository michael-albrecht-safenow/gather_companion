/// Long drive actions as start/poll: a walk, a warp that waits for the call, a
/// thirty-second media watch.
///
/// A VM service call is one request and one answer, and the tools in front of it
/// (`dart_mcp_server`, `tool/drive.sh`) time out long before a walk across the
/// office lands. So an action that takes time hands back an op id at once, and
/// `ext.gc.op.status` / `ext.gc.op.result` are polled for it.
///
/// The id is `<kind>-<n>-<nonce>`, and the nonce is the part worth explaining.
/// `n` counts up from 1 in every isolate, and a hot restart is a new isolate — so
/// without the nonce, `move-3` asked of the restarted app would quietly answer
/// with the *new* third op's result, an answer to a question nobody asked. The
/// nonce is drawn once per isolate; an id carrying another one is refused as
/// "from another isolate — re-run the action", which is the truth.
///
/// Retention is bounded at [DriveOps.capacity] (32): the oldest *finished* op is
/// evicted first, and only when every slot is pending does the oldest pending one
/// go. An evicted id is answered as evicted, not as unknown — the caller then
/// knows it polled too late rather than that it mistyped.
///
/// A failure is recorded *and* reported through `FlutterError.reportError` the
/// moment it happens, whether or not anybody ever polls. An op is usually started
/// by an agent that may give up or crash; the failure must still reach the
/// console, or the one run that went wrong leaves no trace.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';

import 'debug_drive.dart';
import 'drive_result.dart';

/// This isolate's nonce: six of `[0-9a-z]`, drawn once on first use. A
/// top-level final is initialised lazily and once per isolate, which is
/// exactly the lifetime wanted.
final String _isolateNonce = drawDriveNonce(Random());

/// Six characters of `[0-9a-z]` from [random]. Not a secret — it only has to
/// differ between one isolate and the next.
String drawDriveNonce(Random random) {
  const alphabet = '0123456789abcdefghijklmnopqrstuvwxyz';
  return String.fromCharCodes([
    for (var i = 0; i < 6; i++) alphabet.codeUnitAt(random.nextInt(alphabet.length)),
  ]);
}

enum DriveOpState { pending, done, failed }

class _Op {
  _Op(this.id, this.kind, this.startedAt);

  final String id;
  final String kind;
  final DateTime startedAt;
  DateTime? finishedAt;
  DriveOpState state = DriveOpState.pending;
  Object? result;
  String? error;
  String? type;

  Map<String, Object?> status() => {
        'id': id,
        'kind': kind,
        'state': state.name,
        'startedAt': startedAt.toUtc().toIso8601String(),
        'finishedAt': finishedAt?.toUtc().toIso8601String(),
      };
}

class DriveOps {
  DriveOps({this.capacity = 32, String? nonce, DateTime Function()? now})
      : nonce = nonce ?? _isolateNonce,
        _now = now ?? DateTime.now {
    if (capacity < 1) throw ArgumentError.value(capacity, 'capacity', 'must be >= 1');
  }

  /// How many ops are kept at once.
  final int capacity;

  /// The nonce every id this instance mints carries.
  final String nonce;

  final DateTime Function() _now;

  /// Insertion order is age order, which is what eviction walks.
  final LinkedHashMap<String, _Op> _ops = LinkedHashMap();

  /// The last `n` handed out. Counts across kinds, so `n` alone orders ops.
  int _counter = 0;

  /// How many ops are currently retained.
  int get length => _ops.length;

  /// Starts tracking [work] as an op of [kind] and returns its id at once.
  ///
  /// [work]'s value is kept as the op's result: a [DriveResult] as its JSON
  /// envelope, anything else as-is. It must be JSON-encodable; one that is not
  /// fails the op rather than the later `op.result` call.
  String start(String kind, Future<Object?> work) {
    if (!isDriveSegment(kind)) {
      throw ArgumentError.value(kind, 'kind', 'must be a lowerCamelCase segment');
    }
    if (_ops.length >= capacity) _evictOne();
    final id = '$kind-${++_counter}-$nonce';
    final op = _Op(id, kind, _now());
    _ops[id] = op;
    work.then<void>(
      (value) {
        final result = value is DriveResult ? value.toJson() : value;
        try {
          // Proved encodable now, so the failure lands on the op that made it.
          jsonEncode(result);
        } catch (error, stack) {
          _fail(op, error, stack);
          return;
        }
        op
          ..result = result
          ..state = DriveOpState.done
          ..finishedAt = _now();
      },
      onError: (Object error, StackTrace stack) => _fail(op, error, stack),
    );
    return id;
  }

  void _fail(_Op op, Object error, StackTrace stack) {
    op
      ..error = '$error'
      ..type = '${error.runtimeType}'
      ..state = DriveOpState.failed
      ..finishedAt = _now();
    // Even if evicted, even if nobody ever polls: see the file header.
    reportDriveError(error, stack, 'while running drive op ${op.id}');
  }

  void _evictOne() {
    final finished = _ops.values.where((op) => op.state != DriveOpState.pending);
    final victim = finished.isNotEmpty ? finished.first : _ops.values.first;
    _ops.remove(victim.id);
  }

  /// `{id, kind, state, startedAt, finishedAt}` for [id].
  Map<String, Object?> status(String id) => _find(id).status();

  /// [status] plus `result` once done, or `error`/`type` once failed.
  Map<String, Object?> result(String id) {
    final op = _find(id);
    return {
      ...op.status(),
      if (op.state == DriveOpState.done) 'result': op.result,
      if (op.state == DriveOpState.failed) ...{'error': op.error, 'type': op.type},
    };
  }

  _Op _find(String id) {
    final op = _ops[id];
    if (op != null) return op;
    final parts = id.split('-');
    final n = parts.length == 3 ? int.tryParse(parts[1]) : null;
    if (n == null || n < 1 || !isDriveSegment(parts[0])) {
      throw DriveInvalidParams('"$id" is not an op id (<kind>-<n>-<nonce>)');
    }
    if (parts[2] != nonce) {
      throw DriveInvalidParams(
        'op id $id is from another isolate (this one is $nonce, '
        'probably after a hot restart) — re-run the action',
      );
    }
    if (n <= _counter) {
      throw DriveInvalidParams(
        'op id $id was evicted (only the $capacity most recent ops are kept) '
        '— poll sooner or re-run the action',
      );
    }
    throw DriveInvalidParams('op id $id was never started in this isolate');
  }
}
