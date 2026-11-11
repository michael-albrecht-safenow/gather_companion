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
/// The socket code is `drive_client.dart` (shared with `sim_plan.dart`). Pure
/// parts (argument parsing, URI handling, exit codes) are in
/// `drive_cli.dart` and tested by `test/tool/drive_cli_test.dart`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'drive_cli.dart';
import 'drive_client.dart';

const JsonEncoder _pretty = JsonEncoder.withIndent('  ');

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

  DriveClient? client;
  var code = exitOk;
  try {
    client = await DriveClient.connect(command.device);
    code = await _run(client, command);
  } on DriveClientError catch (e) {
    // An RPC error is printed as JSON, exactly as the drive sent it; a timed
    // out or unreadable op prints the last op.result it got.
    final printed = e.rpcError;
    if (printed != null) {
      stdout.writeln(_pretty.convert(printed.containsKey('last') ? printed['last'] : printed));
    }
    if (e.message != null) stderr.writeln('drive: ${e.message}');
    code = e.code;
  } catch (e) {
    // Last resort, so no path exits outside the documented codes: anything not
    // already mapped is the connection failing under a call.
    stderr.writeln('drive: unexpected failure talking to the app ($e)');
    code = exitUnavailable;
  } finally {
    await client?.dispose();
  }
  exit(code);
}

Future<int> _run(DriveClient client, DriveCommand command) async {
  final isolate = await client.pickIsolate();
  final envelope = await client.callOn(isolate, command.method, command.argsJson);
  if (!command.wait) {
    stdout.writeln(_pretty.convert(envelope));
    return exitCodeFor(envelope);
  }

  final opId = opIdOf(envelope);
  if (opId == null) {
    stdout.writeln(_pretty.convert(envelope));
    if (envelope['ok'] == false) return exitRefused; // refused before an op began
    throw DriveClientError(exitUsage, '--wait: ${command.method} did not return an op id in data.id');
  }
  final done = await client.waitOp(isolate, opId, command.timeout);
  stdout.writeln(_pretty.convert(done));
  return exitCodeForOp(done);
}
