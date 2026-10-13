/// Recording state off the wire: whether a meeting is being recorded, and which
/// meeting a start/stop would address.
///
/// The shape asserted here is a best guess — the protocol capture saw the
/// recording *actions* but never a recording in flight, so the `MeetingRecording`
/// row and the `isActivelyRecording` flag are both read defensively until a live
/// session confirms which one the server actually sends. See [_noteRecording] in
/// `game_protocol.dart`.
library;

import 'package:gather_client/gather_client.dart';
import 'package:test/test.dart';

const _me = 'me-1';

/// A dump that establishes identity, plus whatever rows a test asks for.
Map<String, Object?> _dump(List<Map<String, Object?>> patches) => {
      'type': 'FullStateChunk',
      'fullStatePatches': [
        {
          'op': 'addmodel',
          'model': 'Connection',
          'data': {'id': 'c1', 'authUserId': 'uid-1', 'spaceUserId': _me},
        },
        ...patches,
      ],
    };

Map<String, Object?> _delta(List<Map<String, Object?>> patches) =>
    {'type': 'DeltaState', 'patches': patches};

Map<String, Object?> _addParticipant(String id, String meetingId, {String? who}) =>
    {
      'op': 'addmodel',
      'model': 'MeetingParticipant',
      'data': {'id': id, 'spaceUserId': who ?? _me, 'meetingId': meetingId},
    };

Map<String, Object?> _addRecording(String id, {String? by}) => {
      'op': 'addmodel',
      'model': 'MeetingRecording',
      'data': {'id': id, if (by != null) 'startedById': by},
    };

GameProtocolReader _reader() => GameProtocolReader()..authUserId = 'uid-1';

void main() {
  group('which meeting we are in', () {
    test('a participant row for us names the meeting to record', () {
      final reader = _reader()
        ..ingest(_dump([_addParticipant('p1', 'meet-9')]));
      expect(reader.currentMeetingId, 'meet-9');
    });

    test('a participant row for somebody else is not ours to record', () {
      final reader = _reader()
        ..ingest(_dump([_addParticipant('p2', 'meet-9', who: 'ada')]));
      expect(reader.currentMeetingId, isNull);
    });

    test('leaving the meeting — our row deleted — drops the target again', () {
      final reader = _reader()
        ..ingest(_dump([_addParticipant('p1', 'meet-9')]));
      expect(reader.currentMeetingId, 'meet-9');

      reader.ingest(_delta([
        {'op': 'deletemodel', 'model': 'MeetingParticipant', 'id': 'p1'},
      ]));
      expect(reader.currentMeetingId, isNull);
    });
  });

  group('whether a recording is running', () {
    test('nothing recording to begin with', () {
      final reader = _reader()..ingest(_dump([]));
      expect(reader.isRecording, isFalse);
      expect(reader.recordingStartedBy, isNull);
    });

    test('a MeetingRecording row turns the light on and names who started it', () {
      final reader = _reader()..ingest(_dump([]));

      final changed = reader.ingest(_delta([_addRecording('r1', by: 'ada')]));
      expect(changed, isTrue, reason: 'the roster must republish so the dot shows');
      expect(reader.isRecording, isTrue);
      expect(reader.recordingStartedBy, 'ada');
    });

    test('the row being deleted turns it off', () {
      final reader = _reader()
        ..ingest(_dump([]))
        ..ingest(_delta([_addRecording('r1', by: 'ada')]));
      expect(reader.isRecording, isTrue);

      reader.ingest(_delta([
        {'op': 'deletemodel', 'model': 'MeetingRecording', 'id': 'r1'},
      ]));
      expect(reader.isRecording, isFalse);
      expect(reader.recordingStartedBy, isNull);
    });

    test('an endedAt written onto the row turns it off too', () {
      final reader = _reader()
        ..ingest(_dump([]))
        ..ingest(_delta([_addRecording('r1', by: 'ada')]));
      expect(reader.isRecording, isTrue);

      reader.ingest(_delta([
        {
          'op': 'replace',
          'model': 'MeetingRecording',
          'id': 'r1',
          'path': '/endedAt',
          'data': '2026-10-13T12:00:00Z',
        },
      ]));
      expect(reader.isRecording, isFalse);
    });

    test('an isActivelyRecording flag on the Meeting row is honoured as a fallback',
        () {
      final reader = _reader()..ingest(_dump([]));

      reader.ingest(_delta([
        {
          'op': 'replace',
          'model': 'Meeting',
          'id': 'meet-9',
          'path': '/isActivelyRecording',
          'data': true,
        },
      ]));
      expect(reader.isRecording, isTrue);

      reader.ingest(_delta([
        {
          'op': 'replace',
          'model': 'Meeting',
          'id': 'meet-9',
          'path': '/isActivelyRecording',
          'data': false,
        },
      ]));
      expect(reader.isRecording, isFalse);
    });
  });
}
