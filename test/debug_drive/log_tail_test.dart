/// `log.tail`: `media.log`, read with a cursor while the app runs.
///
/// A cursor is only useful if it never lies about what lies between two reads.
/// So these pin that lines come back once and in order, that a cursor which
/// fell off the ring says how much it missed, that one from a previous isolate
/// says `reset` rather than returning nothing forever, and that the lines really
/// are the ones `mediaLogToFile` writes — the hook, not a parallel log.
library;

import 'dart:async';
import 'dart:developer';

import 'package:flutter_test/flutter_test.dart';
import 'package:gather_companion/src/debug_drive/debug_drive.dart';
import 'package:gather_companion/src/debug_drive/drive_log.dart';
import 'package:gather_companion/src/media/media_log.dart';

import 'drive_test_support.dart';

List<String> _texts(Map<String, Object?> page) => [
      for (final l in page['lines']! as List) (l as Map)['line'] as String,
    ];

void main() {
  group('the ring', () {
    test('with no cursor, the newest max lines, oldest first', () {
      final buffer = DriveLogBuffer();
      for (var i = 1; i <= 5; i++) {
        buffer.add('line $i');
      }
      final page = buffer.tail(max: 3);
      expect(_texts(page), ['line 3', 'line 4', 'line 5']);
      expect(page['next'], 5);
      expect(page['more'], isFalse);
    });

    test('a cursor returns only what came after it, and next continues exactly there', () {
      final buffer = DriveLogBuffer();
      for (var i = 1; i <= 5; i++) {
        buffer.add('line $i');
      }
      final first = buffer.tail(since: 1, max: 2);
      expect(_texts(first), ['line 2', 'line 3']);
      expect(first['next'], 3);
      expect(first['more'], isTrue);

      final second = buffer.tail(since: first['next']! as int, max: 10);
      expect(_texts(second), ['line 4', 'line 5']);
      expect(second['more'], isFalse);

      final idle = buffer.tail(since: second['next']! as int);
      expect(_texts(idle), isEmpty);
      expect(idle['next'], 5, reason: 'an empty page keeps the cursor where it was');
    });

    test('lines carry ever-rising seq numbers', () {
      final buffer = DriveLogBuffer();
      buffer
        ..add('a')
        ..add('b');
      expect(buffer.tail(since: 0)['lines'], [
        {'seq': 1, 'line': 'a'},
        {'seq': 2, 'line': 'b'},
      ]);
    });

    test('a cursor older than the ring says how many lines it missed', () {
      final buffer = DriveLogBuffer(capacity: 3);
      for (var i = 1; i <= 10; i++) {
        buffer.add('line $i');
      }
      final page = buffer.tail(since: 2);
      expect(_texts(page), ['line 8', 'line 9', 'line 10']);
      expect(page['dropped'], 5, reason: 'lines 3–7 are gone');
    });

    test('a cursor ahead of the ring — a restarted isolate — says reset and starts over', () {
      final buffer = DriveLogBuffer()..add('fresh');
      final page = buffer.tail(since: 500);
      expect(page['reset'], isTrue);
      expect(_texts(page), ['fresh']);
    });

    test('capacity is the ring size', () {
      final buffer = DriveLogBuffer(capacity: 2000);
      for (var i = 0; i < 2500; i++) {
        buffer.add('$i');
      }
      final page = buffer.tail(since: 0, max: 2000);
      expect((page['lines']! as List).length, 2000);
      expect(page['dropped'], 500);
    });
  });

  group('the action', () {
    late DebugDrive drive;
    late DriveLogBuffer buffer;
    setUp(() {
      buffer = DriveLogBuffer(capacity: 50);
      drive = DebugDrive(boot: () => 'harness', spaceId: () => null, inTestSpace: () => false, register: RecordingRegistrar().call)
        ..install([logFeature(buffer)]);
    });

    test('since and max are read from args', () async {
      for (var i = 1; i <= 4; i++) {
        buffer.add('l$i');
      }
      final body = resultOf(await drive.invoke('ext.gc.log.tail', '{"since":2,"max":1}'));
      expect(body['ok'], isTrue);
      expect(_texts((body['data']! as Map).cast()), ['l3']);
    });

    for (final bad in ['{"since":-1}', '{"since":"3"}', '{"max":0}', '{"max":51}', '{"max":2.5}']) {
      test('$bad is invalidParams', () async {
        expect(errorOf(await drive.invoke('ext.gc.log.tail', bad)).code, ServiceExtensionResponse.invalidParams);
      });
    }
  });

  group('the media_log hook', () {
    tearDown(() => mediaLogDebugSink = null);

    test('every line mediaLogToFile writes reaches the sink', () {
      final seen = <String>[];
      mediaLogDebugSink = seen.add;
      mediaLogToFile('sfu: consume-try for bob');
      mediaLog('collector: roster 4 rows');
      expect(seen, containsAllInOrder(['sfu: consume-try for bob', 'collector: roster 4 rows']));
    });

    test('inside a zone shaped like main.dart\'s, mediaLog reaches the sink once', () {
      // main.dart's zone files every `print` it sees. mediaLog used to echo
      // through debugPrint into that zone *and* file the line itself, so the
      // live boot saw each line twice while the harness saw it once.
      final seen = <String>[];
      mediaLogDebugSink = seen.add;
      runZoned(
        () => mediaLog('collector: once only'),
        zoneSpecification: ZoneSpecification(
          print: (self, parent, zone, line) {
            mediaLogToFile(line);
            parent.print(zone, line);
          },
        ),
      );
      expect(seen.where((l) => l == 'collector: once only'), hasLength(1));
    });

    test('a throwing sink never breaks the log call', () {
      mediaLogDebugSink = (_) => throw StateError('reader broke');
      expect(() => mediaLogToFile('still fine'), returnsNormally);
    });

    test('no sink is the default, so nothing is buffered unless the drive asked', () {
      expect(mediaLogDebugSink, isNull);
    });
  });
}
