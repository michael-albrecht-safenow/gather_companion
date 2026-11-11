/// Somewhere the media log survives long enough to be read off the device.
///
/// `debugPrint` is the obvious sink and it is not enough here. In a profile or
/// release build Flutter routes `print` through the engine's logging callback
/// into `os_log`, not the process's stdout — so `devicectl … --console`, which
/// bridges stdout and stderr, shows every `NSLog` the WebRTC plugin makes and
/// not one line of Dart. That was not a detail: it cost a whole debugging round
/// on 2026-09-17, where the only evidence of a call was the camera's native
/// format line and the app's own account of what it did was invisible.
///
/// So every line also goes to a file. `Directory.systemTemp` on iOS is the app
/// sandbox's `tmp/`, which means no `path_provider` dependency and a path that
/// `devicectl` can reach:
///
/// ```sh
/// xcrun devicectl device copy from --device <udid> \
///   --domain-type appDataContainer --domain-identifier com.jonasgrunau.gatherCompanion \
///   --source tmp/media.log --destination ./media.log
/// # …and tmp/media.log.1 for the prior rotated segment.
/// ```
///
/// Appended across launches, not truncated, because the incident worth reading
/// is usually on the run *before* the one that noticed it: a socket that quietly
/// stopped being present, a reconnect that never landed. Truncating on launch
/// wiped exactly that evidence every time the app was relaunched to "try again".
/// Each run is fenced by a `=== launch … ===` banner so the eye finds its start.
///
/// Growth is bounded by rotation, not by forgetting: when the live file passes
/// [_maxLogBytes] it is rolled to `media.log.1` (the previous `.1` dropped), so
/// at most two segments survive — the current run and roughly one run before it.
/// Nothing here is durable: iOS may purge `tmp/` under storage pressure and wipes
/// it on uninstall.
///
/// It is opened lazily and written synchronously: this is a diagnostic, and a
/// diagnostic that loses the last few lines to a buffer is worthless precisely
/// when it matters — the lines just before a hang are the ones being looked for.
/// A buffered [IOSink] would not give that: its `writeln` returns before the
/// bytes reach the OS and an abrupt kill drops whatever is still queued, so the
/// tail — the part being hunted — is the first thing lost. A [RandomAccessFile]
/// with `flushSync` after every line is what makes the tail survive.
library;

import 'dart:async';
import 'dart:io';

/// The log file for this run, or `null` if the device would not give us one.
RandomAccessFile? _raf;
bool _tried = false;

/// Roll the live file to `.1` once it passes this. Two segments of this size is
/// the whole on-disk cost. 5 MiB is tens of thousands of lines — many runs — and
/// still trivial next to anything else the sandbox holds.
const int _maxLogBytes = 5 * 1024 * 1024;

/// Where the log is being written, for the code that wants to say so out loud.
String? mediaLogPath;

/// A second reader of every line the file gets, for the debug drive's
/// `log.tail` (`lib/src/debug_drive/drive_log.dart`).
///
/// Null unless the drive set it (`startDriveLog` or `installDebugDrive`), and
/// both are only ever called behind a compile-time `kDebugMode` guard — so a release build never sets it and keeps
/// no lines in memory; the file stays the only record. Called before the file is
/// opened, so a device that will not give us a file still feeds the drive.
/// Swallowed like the file write: a broken reader must not break a call.
void Function(String line)? mediaLogDebugSink;

/// The console, plus a copy on disk that outlives it.
///
/// The console copy goes through [Zone.root]'s `print`, not `debugPrint`, and
/// that is load-bearing: the zone in `main.dart` captures `print` and files every
/// line it sees, so `debugPrint` here made the live boot write each line twice —
/// once through the zone, once below — while the harness, which has no capturing
/// zone, wrote it once. The file had carried that doubling unnoticed; the debug
/// drive's `log.tail` made it the API's answer, halving its `max` accounting and
/// letting a throttled `debugPrint` deliver the echo late and out of order. The
/// root zone's print reaches the same console and never re-enters ours, so the
/// file and the drive get exactly one copy in either boot.
///
/// Every failure here is swallowed. Losing the file copy of a log should never
/// be the reason a call does not connect.
void mediaLog(String line) {
  Zone.root.print(line);
  mediaLogToFile(line);
}

/// The file half alone, for callers that must not go back through `print`.
///
/// The zone in `main.dart` captures `print` so that libraries which report their
/// failures that way — mediasoup's `FlexQueue` swallows every exception and
/// `print`s it under `kDebugMode`, which is the only account anyone gets of why
/// a `produce` never happened — land in this file too. That handler already
/// forwards the line to the console itself, so it wants the file half only;
/// anything that went back through the zone's `print` from inside it would
/// re-enter the zone, and one library error would spin the app forever.
void mediaLogToFile(String line) {
  final sink = mediaLogDebugSink;
  if (sink != null) {
    try {
      sink(line);
    } on Object {
      // A debug reader failing is not worth losing the file copy over.
    }
  }
  if (!_tried) {
    _tried = true;
    try {
      final file = File('${Directory.systemTemp.path}/media.log');
      _rotateIfLarge(file);
      // Append so a relaunch keeps the prior run's evidence; the banner fences
      // this run off from it. Held open for the whole process life and written
      // synchronously below so the tail survives an abrupt kill.
      final raf = file.openSync(mode: FileMode.writeOnlyAppend);
      _raf = raf;
      _writeLine(raf, '=== launch ${DateTime.now().toIso8601String()} ===');
      mediaLogPath = file.path;
    } on Object {
      _raf = null;
    }
  }

  final raf = _raf;
  if (raf == null) return;
  try {
    _writeLine(raf, '${DateTime.now().toIso8601String()} $line');
  } on Object {
    _raf = null;
  }
}

/// Writes [line] and flushes it to the OS before returning, so a kill right
/// after cannot drop it. This is what the "written synchronously" promise rests
/// on — [RandomAccessFile.writeStringSync] alone only fills Dart's buffer.
void _writeLine(RandomAccessFile raf, String line) {
  raf
    ..writeStringSync('$line\n')
    ..flushSync();
}

/// Rolls [file] to `<file>.1` when it has outgrown [_maxLogBytes], so the live
/// file reopened in append mode starts near empty.
///
/// Runs once per launch, before the sink opens — rotating a file an `IOSink`
/// holds open would be a race. The previous `.1` is overwritten: two segments is
/// the whole budget, and the live file is always the more interesting half.
/// Every step is best-effort; a log that cannot rotate is still worth appending
/// to, so failure is swallowed rather than allowed to block the sink.
void _rotateIfLarge(File file) {
  try {
    if (!file.existsSync() || file.lengthSync() < _maxLogBytes) return;
    final prior = File('${file.path}.1');
    if (prior.existsSync()) prior.deleteSync();
    file.renameSync(prior.path);
  } on Object {
    // Leave the file as it is; append still works, it just grows one run longer.
  }
}
