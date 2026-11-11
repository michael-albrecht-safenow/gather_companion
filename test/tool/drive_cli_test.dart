// The pure half of tool/drive.dart. The exit codes are the contract a calling
// script or agent switches on — "the app said no" (1) against "the drive broke"
// (2) against "there is no app" (69) — so they are pinned here, together with
// the command-line grammar and the URI-file rules, rather than left to whatever
// the socket code happens to return.
import 'package:flutter_test/flutter_test.dart';

import '../../tool/drive_cli.dart';

void main() {
  group('parseDriveArgs', () {
    test('a bare suffix gets the ext.gc. prefix and {} args', () {
      final c = parseDriveArgs(['state.dump'])!;
      expect(c.method, 'ext.gc.state.dump');
      expect(c.argsJson, '{}');
      expect(c.device, isNull);
      expect(c.wait, isFalse);
      expect(c.timeout, const Duration(seconds: 300));
    });

    test('a full method name is accepted as-is', () {
      expect(parseDriveArgs(['ext.gc.op.result'])!.method, 'ext.gc.op.result');
    });

    test('flags may come before or after the positionals', () {
      final c = parseDriveArgs(['move.goTo', '{"x": 1, "y": 2}', '--wait', '-d', 'ABC-123'])!;
      expect(c.method, 'ext.gc.move.goTo');
      expect(c.argsJson, '{"x":1,"y":2}');
      expect(c.device, 'ABC-123');
      expect(c.wait, isTrue);
    });

    test('--timeout takes seconds, fractional allowed', () {
      expect(
        parseDriveArgs(['--timeout', '1.5', 'state.dump'])!.timeout,
        const Duration(milliseconds: 1500),
      );
    });

    test('help returns null', () {
      expect(parseDriveArgs(['-h']), isNull);
      expect(parseDriveArgs(['state.dump', '--help']), isNull);
    });

    for (final (why, argv) in [
      ('no action', <String>[]),
      ('one segment only', ['state']),
      ('a segment not lowerCamelCase', ['State.dump']),
      ('an empty segment', ['state..dump']),
      ('args not JSON', ['state.dump', '{x:1}']),
      ('args a JSON array', ['state.dump', '[1]']),
      ('args a JSON string', ['state.dump', '"hi"']),
      ('three positionals', ['move.goTo', '{"x":1}', '{"y":2}']),
      ('an unknown flag', ['--verbose', 'state.dump']),
      ('-d without a value', ['state.dump', '-d']),
      ('a zero timeout', ['--timeout', '0', 'state.dump']),
      ('a non-numeric timeout', ['--timeout', 'soon', 'state.dump']),
    ]) {
      test('usage error: $why', () {
        expect(() => parseDriveArgs(argv), throwsA(isA<DriveUsageError>()));
      });
    }
  });

  group('pickUriFile', () {
    test('-d picks that device, or nothing', () {
      expect(pickUriFile('A', ['vm_uri.A', 'vm_uri.B']), 'vm_uri.A');
      expect(pickUriFile('C', ['vm_uri.A', 'vm_uri.B']), isNull);
    });

    test('without -d the bare file wins', () {
      expect(pickUriFile(null, ['vm_uri.A', 'vm_uri']), 'vm_uri');
    });

    test('without -d a single device file is used', () {
      expect(pickUriFile(null, ['vm_uri.A']), 'vm_uri.A');
    });

    test('without -d several device files is a usage error, not a guess', () {
      expect(
        () => pickUriFile(null, ['vm_uri.B', 'vm_uri.A']),
        throwsA(isA<DriveUsageError>().having((e) => e.message, 'message', contains('A, B'))),
      );
    });

    test('none at all is unavailable (null)', () {
      expect(pickUriFile(null, const []), isNull);
    });
  });

  group('toWebSocketUri', () {
    test('keeps the auth code and appends /ws', () {
      expect(
        toWebSocketUri('http://127.0.0.1:50300/AbCd12-xyz=/\n').toString(),
        'ws://127.0.0.1:50300/AbCd12-xyz=/ws',
      );
    });

    test('a path without a trailing slash still gets /ws', () {
      expect(toWebSocketUri('http://127.0.0.1:1/abc=').toString(), 'ws://127.0.0.1:1/abc=/ws');
    });

    test('a ws URI already ending in /ws is left alone', () {
      expect(toWebSocketUri('ws://127.0.0.1:1/abc=/ws').toString(), 'ws://127.0.0.1:1/abc=/ws');
    });

    test('garbage is a FormatException', () {
      expect(() => toWebSocketUri(''), throwsFormatException);
      expect(() => toWebSocketUri('ftp://h/x'), throwsFormatException);
    });
  });

  group('exit codes', () {
    test('envelopes', () {
      expect(exitCodeFor({'ok': true, 'data': null}), exitOk);
      expect(exitCodeFor({'ok': false, 'reason': 'no_call'}), exitRefused);
      expect(exitCodeFor({'data': 1}), exitRpcError);
    });

    test('the documented numbers', () {
      expect([exitOk, exitRefused, exitRpcError, exitUsage, exitUnavailable, exitTimeout],
          [0, 1, 2, 64, 69, 75]);
    });

    test('stripTransport drops what the VM adds, and only that', () {
      expect(
        stripTransport({'type': '_extensionType', 'method': 'ext.gc.x.y', 'ok': true}),
        {'ok': true},
      );
      expect(stripTransport({'ok': true, 'method': 'kept'}), {'ok': true, 'method': 'kept'});
    });

    test('opIdOf reads data.id only from an ok envelope with an op-shaped id', () {
      expect(opIdOf({'ok': true, 'data': {'id': 'move-3-k2x9qa'}}), 'move-3-k2x9qa');
      expect(opIdOf({'ok': true, 'data': {'id': 'me'}}), isNull);
      expect(opIdOf({'ok': false, 'reason': 'x', 'data': {'id': 'move-3-k2x9qa'}}), isNull);
      expect(opIdOf({'ok': true, 'data': 'move-3-k2x9qa'}), isNull);
    });

    Map<String, Object?> op(String state, [Object? result]) => {
          'ok': true,
          'data': {'id': 'w-1-abcdef', 'state': state, 'result': ?result},
        };

    test('op progress', () {
      expect(opProgressOf(op('pending')), OpProgress.pending);
      expect(opProgressOf(op('done')), OpProgress.done);
      expect(opProgressOf(op('failed')), OpProgress.failed);
      expect(() => opProgressOf({'ok': true, 'data': {}}), throwsFormatException);
    });

    test('a settled op exits by the envelope its action returned', () {
      expect(exitCodeForOp(op('done', {'ok': true, 'data': 1})), exitOk);
      expect(exitCodeForOp(op('done', {'ok': false, 'reason': 'locked'})), exitRefused);
      expect(exitCodeForOp(op('done', 42)), exitOk);
      expect(exitCodeForOp(op('failed')), exitRpcError);
    });
  });
}
