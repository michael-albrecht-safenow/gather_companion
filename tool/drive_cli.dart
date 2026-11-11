/// The pure half of `tool/drive.dart`: reading the command line, finding the
/// VM service URI file, turning that URI into a WebSocket address, and mapping
/// an answer to an exit code.
///
/// Split out so it can be tested without a running app. Everything that needs a
/// socket lives in `drive.dart`; everything here is a function of its inputs,
/// and the exit codes in particular are the contract a calling script switches
/// on, so they are pinned by `test/tool/drive_cli_test.dart` rather than left to
/// whatever the I/O code happened to return.
///
/// The codes are sysexits-style, because the caller is usually a shell loop or
/// an agent and both need "the app said no" (1) kept apart from "the drive
/// broke or was asked something malformed" (2) and from "there is no app to ask"
/// (69). Folding those together is how an agent ends up debugging the app when
/// `flutter run` had simply exited.
library;

import 'dart:convert';

/// The action answered `{"ok":true}` (or an op finished with one).
const int exitOk = 0;

/// The app declined: `{"ok":false,"reason":…}`. Nothing is broken; read the
/// reason and change the request.
const int exitRefused = 1;

/// An RPC error — invalid params, a handler that threw, an unknown method — or
/// an op that failed. The drive broke or was asked something it cannot read.
const int exitRpcError = 2;

/// EX_USAGE: this script was called wrong.
const int exitUsage = 64;

/// EX_UNAVAILABLE: no URI file, nothing listening at it, or the isolate went
/// away (a hot restart) while `--wait` was polling.
const int exitUnavailable = 69;

/// EX_TEMPFAIL: `--wait` gave up before the op finished. The op may still
/// finish; poll `op.result` again.
const int exitTimeout = 75;

const String drivePrefix = 'ext.gc.';

const String usage = '''
usage: tool/drive.sh [-d <device-id>] [--wait] [--timeout <s>] <action> ['<json args>']

  <action>       method suffix, e.g. state.dump (or the full ext.gc.state.dump)
  <json args>    one JSON object, sent as the "args" param; default {}
  -d <device-id> read .dart_tool/vm_uri.<device-id>, written by
                   flutter run --vmservice-out-file=.dart_tool/vm_uri.<device-id>
                 without -d: .dart_tool/vm_uri, else the only vm_uri.* there is
  --wait         the action returned an op id in data.id: poll ext.gc.op.result
                 until it is done or failed, and print that instead
  --timeout <s>  give up waiting after <s> seconds (default 300)

exit: 0 ok, 1 refused (ok:false), 2 RPC error or failed op,
      64 usage (or --wait on an action that returned no op id),
      69 unavailable (no URI, no app, isolate gone), 75 wait timed out''';

/// A command line that did not parse. [message] says why; the caller prints it
/// with [usage] and exits [exitUsage].
class DriveUsageError implements Exception {
  const DriveUsageError(this.message);

  final String message;

  @override
  String toString() => message;
}

/// One parsed invocation.
class DriveCommand {
  const DriveCommand({
    required this.method,
    required this.argsJson,
    this.device,
    this.wait = false,
    this.timeout = const Duration(seconds: 300),
  });

  /// The full method name, `ext.gc.` included.
  final String method;

  /// The `args` param exactly as it will be sent: a JSON object's text.
  final String argsJson;

  /// The `-d` device id, or null for "work it out".
  final String? device;

  final bool wait;
  final Duration timeout;
}

final RegExp _segment = RegExp(r'^[a-z][a-zA-Z0-9]*$');

/// Parses [argv]. Returns null for `-h`/`--help`; throws [DriveUsageError] for
/// anything it cannot read.
///
/// The JSON is checked here rather than left to the app, because the app would
/// answer bad JSON with `invalidParams` (exit 2), and a quoting mistake in the
/// caller's shell is a usage error, not the drive breaking.
DriveCommand? parseDriveArgs(List<String> argv) {
  String? device;
  var wait = false;
  var timeout = const Duration(seconds: 300);
  final positional = <String>[];

  for (var i = 0; i < argv.length; i++) {
    final arg = argv[i];
    String value() {
      if (i + 1 >= argv.length) throw DriveUsageError('$arg needs a value');
      return argv[++i];
    }

    switch (arg) {
      case '-h' || '--help':
        return null;
      case '-d' || '--device':
        device = value();
        if (device.isEmpty) throw const DriveUsageError('-d needs a device id');
      case '--wait':
        wait = true;
      case '--timeout':
        final raw = value();
        final seconds = num.tryParse(raw);
        if (seconds == null || seconds <= 0) {
          throw DriveUsageError('--timeout wants a positive number of seconds, not "$raw"');
        }
        timeout = Duration(milliseconds: (seconds * 1000).round());
      default:
        // A JSON object starts with "{", never "-", so anything dashed here is
        // a flag this script does not know rather than an argument.
        if (arg.startsWith('-') && arg.length > 1) {
          throw DriveUsageError('unknown flag "$arg"');
        }
        positional.add(arg);
    }
  }

  if (positional.isEmpty) throw const DriveUsageError('missing <action>');
  if (positional.length > 2) {
    throw DriveUsageError(
      'too many arguments (${positional.length}); quote the JSON as one argument',
    );
  }

  final method = normaliseMethod(positional[0]);
  final argsJson = positional.length == 2 ? normaliseArgs(positional[1]) : '{}';
  return DriveCommand(
    method: method,
    argsJson: argsJson,
    device: device,
    wait: wait,
    timeout: timeout,
  );
}

/// `state.dump` → `ext.gc.state.dump`; a full name is accepted as-is. Each
/// segment must be lowerCamelCase, the same rule the app's registry enforces,
/// so a typo is caught before a connection is spent on it.
String normaliseMethod(String raw) {
  final method = raw.startsWith(drivePrefix) ? raw : '$drivePrefix$raw';
  final segments = method.substring(drivePrefix.length).split('.');
  if (segments.length < 2 || !segments.every(_segment.hasMatch)) {
    throw DriveUsageError(
      '"$raw" is not <feature>.<action> in lowerCamelCase segments (e.g. state.dump)',
    );
  }
  return method;
}

/// Checks [raw] is one JSON object and returns it re-encoded compactly.
String normaliseArgs(String raw) {
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException catch (e) {
    throw DriveUsageError('args is not valid JSON: ${e.message}');
  }
  if (decoded is! Map) {
    throw const DriveUsageError('args must be a JSON object, e.g. \'{"id":"move-1-abc123"}\'');
  }
  return jsonEncode(decoded);
}

/// Which URI file to read, given the `-d` [device] and the names of the files
/// in `.dart_tool/` that start with `vm_uri`.
///
/// Without `-d`: the bare `vm_uri` if it exists, else the only `vm_uri.<id>`.
/// Two or more device files and no `-d` is a usage error naming them — guessing
/// would drive the wrong phone. None at all is [exitUnavailable], signalled by
/// returning null, because then there is simply no app to talk to.
String? pickUriFile(String? device, Iterable<String> names) {
  final present = names.toSet();
  if (device != null) {
    final name = 'vm_uri.$device';
    return present.contains(name) ? name : null;
  }
  if (present.contains('vm_uri')) return 'vm_uri';
  final perDevice = present.where((n) => n.startsWith('vm_uri.')).toList()..sort();
  if (perDevice.length == 1) return perDevice.single;
  if (perDevice.length > 1) {
    final ids = perDevice.map((n) => n.substring('vm_uri.'.length)).join(', ');
    throw DriveUsageError('several apps are running ($ids); pick one with -d');
  }
  return null;
}

/// The WebSocket address for a VM service URI as `flutter run` writes it.
///
/// `--vmservice-out-file` holds the DDS *HTTP* URI, auth code in the path:
/// `http://127.0.0.1:50300/AbCdEf=/`. The service protocol is spoken on
/// `ws://…/AbCdEf=/ws`. Dropping the auth code segment gets a 403 that looks
/// like nothing is running, so the path is kept whole and only `ws` appended.
Uri toWebSocketUri(String raw) {
  final trimmed = raw.trim();
  final uri = Uri.tryParse(trimmed);
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
    throw FormatException('not a VM service URI', trimmed);
  }
  final scheme = switch (uri.scheme) {
    'http' || 'ws' => 'ws',
    'https' || 'wss' => 'wss',
    _ => throw FormatException('unexpected scheme "${uri.scheme}"', trimmed),
  };
  var path = uri.path;
  if (!path.endsWith('/ws')) {
    path = path.endsWith('/') ? '${path}ws' : '$path/ws';
  }
  return uri.replace(scheme: scheme, path: path);
}

/// The drive envelope out of a service-extension response's JSON. The VM adds
/// `type: "_extensionType"` and `method` to whatever the extension returned;
/// those are transport, not answer, and are dropped so the printed JSON is
/// exactly what the handler sent.
Map<String, Object?> stripTransport(Map<String, Object?> json) {
  if (json['type'] != '_extensionType') return json;
  return Map.of(json)
    ..remove('type')
    ..remove('method');
}

/// The exit code for a drive envelope: `ok:true` → 0, `ok:false` → 1, and
/// anything that is not an envelope at all → 2, because then something
/// between the handler and here is broken.
int exitCodeFor(Map<String, Object?> envelope) => switch (envelope['ok']) {
      true => exitOk,
      false => exitRefused,
      _ => exitRpcError,
    };

/// The op id an action handed back in `data.id`, or null when the answer is
/// not an op start (a refusal, or a plain readout).
String? opIdOf(Map<String, Object?> envelope) {
  if (envelope['ok'] != true) return null;
  final data = envelope['data'];
  if (data is! Map) return null;
  final id = data['id'];
  return id is String && RegExp(r'^[a-z][a-zA-Z0-9]*-\d+-[0-9a-z]{6}$').hasMatch(id)
      ? id
      : null;
}

/// Where a polled op stands, from an `op.result` envelope.
enum OpProgress { pending, done, failed }

/// Reads `data.state` of an `op.result` envelope. Anything unrecognised
/// throws: a poll loop that guessed "pending" would spin until the timeout.
OpProgress opProgressOf(Map<String, Object?> envelope) {
  final data = envelope['data'];
  final state = data is Map ? data['state'] : null;
  return switch (state) {
    'pending' => OpProgress.pending,
    'done' => OpProgress.done,
    'failed' => OpProgress.failed,
    _ => throw FormatException('op.result without a known data.state', jsonEncode(envelope)),
  };
}

/// The exit code once a waited-for op settles: a failed op is the drive
/// breaking (2); a done op exits by the envelope its action returned, so a
/// walk that ended in a refusal still exits 1.
int exitCodeForOp(Map<String, Object?> envelope) {
  if (opProgressOf(envelope) == OpProgress.failed) return exitRpcError;
  final data = envelope['data'] as Map;
  final result = data['result'];
  if (result is Map && result.containsKey('ok')) {
    return exitCodeFor(result.cast<String, Object?>());
  }
  // An op whose work returned a plain value rather than a DriveResult.
  return exitOk;
}
