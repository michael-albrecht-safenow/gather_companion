/// `media.log`, readable over the drive while the app runs.
///
/// Most call bugs so far were found in `media.log` — after `devicectl` had
/// copied it off the phone, after the call had already gone wrong. With the
/// drive attached, an agent can read the same lines as they are written, with a
/// cursor, so "warp, then show me what the media plane said" is one poll instead
/// of a cable and a file copy.
///
/// The lines come from the one path that writes the file: `mediaLogToFile` in
/// `media/media_log.dart` calls a nullable sink that only the drive sets —
/// `startDriveLog` at the top of `main()` in the live boot, so the tail begins
/// at launch with the file's own boot lines, and `installDebugDrive` otherwise
/// (the harness), where it begins at install. In a release build nothing sets it, so the buffer below is never built
/// and nothing is kept in memory — the file is the only record, as before. What
/// the tail shows is therefore exactly what the file got, including library
/// output the zone in `main.dart` captures. The harness hands `AppState` no log
/// sink, so on the harness the tail is honestly empty for app diagnostics.
///
/// A ring of [DriveLogBuffer.capacity] lines, each with a sequence number that
/// only ever counts up. A cursor older than the ring says how many lines it
/// missed (`dropped`) rather than pretending the oldest retained line followed
/// it; a cursor *ahead* of the ring — the isolate restarted and the count began
/// again — says `reset` instead of returning nothing forever.
library;

import 'dart:collection';

import 'debug_drive.dart';
import 'drive_result.dart';

class DriveLogBuffer {
  DriveLogBuffer({this.capacity = 2000}) {
    if (capacity < 1) throw ArgumentError.value(capacity, 'capacity', 'must be >= 1');
  }

  final int capacity;
  final Queue<({int seq, String line})> _lines = Queue();
  int _seq = 0;

  /// The sequence number of the newest line, 0 before any.
  int get lastSeq => _seq;

  /// Appends [line]. The signature `mediaLogDebugSink` wants.
  void add(String line) {
    _lines.addLast((seq: ++_seq, line: line));
    if (_lines.length > capacity) _lines.removeFirst();
  }

  /// Lines after [since], oldest first, at most [max]. With no [since], the
  /// newest [max] lines — a tail. [next] is the cursor to pass back.
  Map<String, Object?> tail({int? since, int max = 200}) {
    var cursor = since;
    var reset = false;
    if (cursor != null && cursor > _seq) {
      cursor = 0;
      reset = true;
    }
    final Iterable<({int seq, String line})> picked;
    var dropped = 0;
    if (cursor == null) {
      final all = _lines.toList();
      picked = all.sublist(all.length > max ? all.length - max : 0);
    } else {
      final firstKept = _lines.isEmpty ? _seq + 1 : _lines.first.seq;
      if (cursor + 1 < firstKept) dropped = firstKept - cursor - 1;
      final after = cursor;
      picked = _lines.where((l) => l.seq > after).take(max);
    }
    final out = [
      for (final l in picked) {'seq': l.seq, 'line': l.line},
    ];
    final next = out.isEmpty ? (cursor ?? _seq) : out.last['seq']! as int;
    return {
      'lines': out,
      'next': next,
      'more': next < _seq,
      if (dropped > 0) 'dropped': dropped,
      if (reset) 'reset': true,
    };
  }
}

/// `ext.gc.log.tail {since?, max?}`.
DriveFeature logFeature(DriveLogBuffer buffer) => DriveFeature('log', [
      DriveAction('tail', (args) async {
        final since = args.optionalInt('since', min: 0);
        final max = args.optionalInt('max', min: 1, max: buffer.capacity) ?? 200;
        return DriveResult.ok(buffer.tail(since: since, max: max));
      }),
    ]);
