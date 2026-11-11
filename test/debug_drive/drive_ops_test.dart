/// Start/poll ops: their ids, their retention, and the two ways an old id is
/// answered honestly instead of with somebody else's result.
///
/// The nonce is the part that would fail quietly. Without it, `move-3-…` asked
/// of an app that was hot-restarted answers with the restarted app's third op —
/// a plausible result to the wrong question. These pin that a foreign nonce is
/// refused, that an evicted id says it was evicted, and that a failure is
/// reported even when nobody ever polls for it.
library;

import 'dart:async';
import 'dart:developer';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:gather_companion/src/debug_drive/builtin_features.dart';
import 'package:gather_companion/src/debug_drive/debug_drive.dart';
import 'package:gather_companion/src/debug_drive/drive_ops.dart';
import 'package:gather_companion/src/debug_drive/drive_result.dart';

import 'drive_test_support.dart';

final _t0 = DateTime.utc(2026, 11, 10, 9);

void main() {
  group('ids', () {
    test('are <kind>-<n>-<nonce>, with n counting across kinds', () {
      final ops = DriveOps(nonce: 'abc123');
      expect(ops.start('move', Completer<void>().future), 'move-1-abc123');
      expect(ops.start('watch', Completer<void>().future), 'watch-2-abc123');
      expect(ops.start('move', Completer<void>().future), 'move-3-abc123');
    });

    test('the default nonce is six of [0-9a-z], and the same for every DriveOps in the isolate', () {
      final a = DriveOps(), b = DriveOps();
      expect(a.nonce, matches(RegExp(r'^[0-9a-z]{6}$')));
      expect(b.nonce, a.nonce, reason: 'drawn once per isolate, not per instance');
    });

    test('drawDriveNonce stays in the alphabet', () {
      final random = Random(7);
      for (var i = 0; i < 200; i++) {
        expect(drawDriveNonce(random), matches(RegExp(r'^[0-9a-z]{6}$')));
      }
    });

    test('a kind that is not a name segment is refused before anything starts', () {
      final ops = DriveOps(nonce: 'n00000');
      expect(() => ops.start('move-to', Future.value()), throwsArgumentError);
      expect(() => ops.start('Move', Future.value()), throwsArgumentError);
      expect(ops.length, 0);
    });
  });

  group('status and result', () {
    test('a pending op reports pending with no result; a done one carries it', () async {
      var now = _t0;
      final ops = DriveOps(nonce: 'n00000', now: () => now);
      final work = Completer<Object?>();
      final id = ops.start('move', work.future);

      expect(ops.status(id), {
        'id': id,
        'kind': 'move',
        'state': 'pending',
        'startedAt': '2026-11-10T09:00:00.000Z',
        'finishedAt': null,
      });
      expect(ops.result(id).containsKey('result'), isFalse);

      now = _t0.add(const Duration(seconds: 2));
      work.complete({'arrived': true});
      await pumpEventQueue();

      expect(ops.result(id), {
        'id': id,
        'kind': 'move',
        'state': 'done',
        'startedAt': '2026-11-10T09:00:00.000Z',
        'finishedAt': '2026-11-10T09:00:02.000Z',
        'result': {'arrived': true},
      });
    });

    test('a DriveResult value is kept as its envelope, so a refusal inside an op stays a refusal', () async {
      final ops = DriveOps(nonce: 'n00000');
      final id = ops.start('move', Future.value(const DriveResult.refused('blocked', {'at': 3})));
      await pumpEventQueue();
      expect(ops.result(id)['result'], {'ok': false, 'reason': 'blocked', 'at': 3});
      expect(ops.result(id)['state'], 'done');
    });

    test('a failure is recorded with error and type, and reported though nobody polled', () async {
      final reported = captureFlutterErrors();
      final ops = DriveOps(nonce: 'n00000');
      final id = ops.start('watch', Future<void>.error(TimeoutException('no frames')));
      await pumpEventQueue();

      expect(reported, hasLength(1), reason: 'reported at failure time, before any poll');
      expect(reported.single.exception, isA<TimeoutException>());
      expect('${reported.single.context}', contains(id));

      final result = ops.result(id);
      expect(result['state'], 'failed');
      expect(result['type'], 'TimeoutException');
      expect(result['error'], contains('no frames'));
      expect(result.containsKey('result'), isFalse);
    });

    test('a result that cannot be encoded fails the op, not the later poll', () async {
      final reported = captureFlutterErrors();
      final ops = DriveOps(nonce: 'n00000');
      final id = ops.start('move', Future.value(Object()));
      await pumpEventQueue();
      expect(ops.result(id)['state'], 'failed');
      expect(ops.result(id)['type'], contains('JsonUnsupportedObjectError'));
      expect(reported, hasLength(1));
    });
  });

  group('retention', () {
    test('the oldest finished op is evicted first, even past older pending ones', () async {
      final ops = DriveOps(capacity: 3, nonce: 'n00000');
      final pending = ops.start('a', Completer<void>().future); // a-1, never finishes
      final finished = ops.start('b', Future.value(1)); // b-2
      ops.start('c', Completer<void>().future); // c-3
      await pumpEventQueue();

      ops.start('d', Completer<void>().future); // evicts b-2, not a-1
      expect(ops.length, 3);
      expect(ops.status(pending)['state'], 'pending');
      expect(
        () => ops.status(finished),
        throwsA(isA<DriveInvalidParams>().having((e) => e.message, 'message', allOf(contains('was evicted'), contains(finished)))),
      );
    });

    test('when every slot is pending, the oldest pending op goes', () {
      final ops = DriveOps(capacity: 2, nonce: 'n00000');
      final first = ops.start('a', Completer<void>().future);
      final second = ops.start('a', Completer<void>().future);
      final third = ops.start('a', Completer<void>().future);
      expect(() => ops.status(first), throwsA(isA<DriveInvalidParams>()));
      expect(ops.status(second)['state'], 'pending');
      expect(ops.status(third)['state'], 'pending');
    });

    test('32 are kept by default', () async {
      final ops = DriveOps(nonce: 'n00000');
      final ids = [for (var i = 0; i < 33; i++) ops.start('k', Future.value(i))];
      await pumpEventQueue();
      expect(ops.length, 32);
      expect(() => ops.status(ids.first), throwsA(isA<DriveInvalidParams>()));
      expect(ops.result(ids.last)['result'], 32);
    });

    test('an evicted op that later fails is still reported', () async {
      final reported = captureFlutterErrors();
      final ops = DriveOps(capacity: 1, nonce: 'n00000');
      final work = Completer<void>();
      ops.start('a', work.future);
      ops.start('b', Completer<void>().future); // evicts a-1 while pending
      work.completeError(StateError('late'));
      await pumpEventQueue();
      expect(reported, hasLength(1));
    });
  });

  group('ids that are not ours', () {
    final ops = DriveOps(nonce: 'here00');

    test('another isolate\'s nonce is refused with the instruction to re-run', () {
      expect(
        () => ops.status('move-1-gone00'),
        throwsA(isA<DriveInvalidParams>().having(
          (e) => e.message,
          'message',
          allOf(contains('op id move-1-gone00 is from another isolate'), contains('here00'), contains('re-run the action')),
        )),
      );
    });

    test('a number this isolate never reached is "never started", not "evicted"', () {
      expect(
        () => ops.result('move-99-here00'),
        throwsA(isA<DriveInvalidParams>().having((e) => e.message, 'message', contains('never started'))),
      );
    });

    for (final junk in ['', 'move', 'move-1', 'move-x-here00', 'Move-1-here00', 'move-0-here00', 'a-1-b-c']) {
      test('"$junk" is not an op id', () {
        expect(
          () => ops.status(junk),
          throwsA(isA<DriveInvalidParams>().having((e) => e.message, 'message', contains('not an op id'))),
        );
      });
    }
  });

  group('through the registry', () {
    test('op.status and op.result answer over the drive; a bad id is invalidParams', () async {
      final ops = DriveOps(nonce: 'n00000');
      final drive = DebugDrive(boot: () => 'harness', spaceId: () => null, inTestSpace: () => false, register: RecordingRegistrar().call)
        ..install([opFeature(ops)]);
      final id = ops.start('move', Future.value('there'));
      await pumpEventQueue();

      final status = resultOf(await drive.invoke('ext.gc.op.status', '{"id":"$id"}'));
      expect((status['data']! as Map)['state'], 'done');
      final result = resultOf(await drive.invoke('ext.gc.op.result', '{"id":"$id"}'));
      expect((result['data']! as Map)['result'], 'there');

      final foreign = errorOf(await drive.invoke('ext.gc.op.result', '{"id":"move-1-zzzzzz"}'));
      expect(foreign.code, ServiceExtensionResponse.invalidParams);
      expect(foreign.detail['error'], contains('another isolate'));

      final missing = errorOf(await drive.invoke('ext.gc.op.status'));
      expect(missing.code, ServiceExtensionResponse.invalidParams);
      expect(missing.detail['error'], '"id" is required');
    });
  });
}
