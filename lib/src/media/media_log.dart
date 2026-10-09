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
library;

import 'dart:io';

import 'package:flutter/foundation.dart';

/// The log file for this run, or `null` if the device would not give us one.
IOSink? _sink;
bool _tried = false;

/// Roll the live file to `.1` once it passes this. Two segments of this size is
/// the whole on-disk cost. 5 MiB is tens of thousands of lines — many runs — and
/// still trivial next to anything else the sandbox holds.
const int _maxLogBytes = 5 * 1024 * 1024;

/// Where the log is being written, for the code that wants to say so out loud.
String? mediaLogPath;

/// [debugPrint], plus a copy on disk that outlives the console.
///
/// Every failure here is swallowed. Losing the file copy of a log should never
/// be the reason a call does not connect.
void mediaLog(String line) {
  debugPrint(line);
  mediaLogToFile(line);
}

/// The file half alone, for callers that must not go back through `print`.
///
/// The zone in `main.dart` captures `print` so that libraries which report their
/// failures that way — mediasoup's `FlexQueue` swallows every exception and
/// `print`s it under `kDebugMode`, which is the only account anyone gets of why
/// a `produce` never happened — land in this file too. Routing that through
/// [mediaLog] would call `debugPrint`, which calls `print`, which re-enters the
/// zone: one library error and the app spins forever.
void mediaLogToFile(String line) {
  if (!_tried) {
    _tried = true;
    try {
      final file = File('${Directory.systemTemp.path}/media.log');
      _rotateIfLarge(file);
      // Append so a relaunch keeps the prior run's evidence; the banner fences
      // this run off from it. Opened for the whole process life, flushed by the
      // OS — the synchronous `writeln` below is what guards the last lines.
      _sink = file.openWrite(mode: FileMode.append)
        ..writeln('=== launch ${DateTime.now().toIso8601String()} ===');
      mediaLogPath = file.path;
    } on Object {
      _sink = null;
    }
  }

  final sink = _sink;
  if (sink == null) return;
  try {
    sink.writeln('${DateTime.now().toIso8601String()} $line');
  } on Object {
    _sink = null;
  }
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
