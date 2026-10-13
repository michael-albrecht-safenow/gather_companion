/// Recording state off the wire: whether the meeting *we are in* is being
/// recorded, and which meeting a start/stop would address.
///
/// The row/flag shapes asserted here are a best guess — the protocol capture saw
/// the recording *actions* but never a recording in flight, so `MeetingRecording`
/// and the speculative `isActivelyRecording` flag are read defensively. The one
/// signal the observed `Meeting` schema confirms is `activeRecordingId`. Recording
/// is scoped to [currentMeetingId]: a recording running in a different meeting in
/// the same space must not light the dot here. See [_noteRecording] /
/// [_recomputeRecording] in `game_protocol.dart`.
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

Map<String, Object?> _addParticipant(
  String id,
  String meetingId, {
  String? who,
  Map<String, Object?> extra = const {},
}) =>
    {
      'op': 'addmodel',
      'model': 'MeetingParticipant',
      'data': {
        'id': id,
        'spaceUserId': who ?? _me,
        'meetingId': meetingId,
        ...extra,
      },
    };

Map<String, Object?> _addRecording(String id, {String? meetingId, String? by}) =>
    {
      'op': 'addmodel',
      'model': 'MeetingRecording',
      'data': {
        'id': id,
        'meetingId': ?meetingId,
        'startedById': ?by,
      },
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

    test('a soft leave — a departure stamp written onto our row — drops it too', () {
      final reader = _reader()
        ..ingest(_dump([_addParticipant('p1', 'meet-9')]));
      expect(reader.currentMeetingId, 'meet-9');

      reader.ingest(_delta([
        {
          'op': 'replace',
          'model': 'MeetingParticipant',
          'id': 'p1',
          'path': '/intentionallyLeftAt',
          'data': '2026-10-13T12:00:00Z',
        },
      ]));
      expect(reader.currentMeetingId, isNull);
    });

    test('a bare invitation is not the meeting we are in', () {
      final reader = _reader()
        ..ingest(_dump([
          _addParticipant('p1', 'meet-invite',
              extra: {'inviteStatus': 'InvitedRequired', 'inviterId': 'ada'}),
        ]));
      expect(reader.currentMeetingId, isNull);
    });

    test('a past attendance we already left is not the meeting we are in', () {
      final reader = _reader()
        ..ingest(_dump([
          _addParticipant('p-old', 'meet-old',
              extra: {'intentionallyLeftAt': '2026-10-13T09:00:00Z'}),
          _addParticipant('p-now', 'meet-now'),
        ]));
      // Insertion order would hand back whichever row landed last; the lifecycle
      // fields pick the live one instead.
      expect(reader.currentMeetingId, 'meet-now');
    });
  });

  group('whether a recording is running', () {
    test('nothing recording to begin with', () {
      final reader = _reader()..ingest(_dump([]));
      expect(reader.isRecording, isFalse);
      expect(reader.recordingStartedBy, isNull);
    });

    test('a MeetingRecording row in our meeting turns the light on and names who',
        () {
      final reader = _reader()
        ..ingest(_dump([_addParticipant('p1', 'meet-9')]));

      final changed =
          reader.ingest(_delta([_addRecording('r1', meetingId: 'meet-9', by: 'ada')]));
      expect(changed, isTrue, reason: 'the roster must republish so the dot shows');
      expect(reader.isRecording, isTrue);
      expect(reader.recordingStartedBy, 'ada');
    });

    test('a recording in a different meeting does not light our dot', () {
      final reader = _reader()
        ..ingest(_dump([_addParticipant('p1', 'meet-9')]));

      final changed = reader
          .ingest(_delta([_addRecording('r1', meetingId: 'other-meet', by: 'ada')]));
      expect(changed, isFalse);
      expect(reader.isRecording, isFalse);
      expect(reader.recordingStartedBy, isNull);
    });

    test('the row being deleted turns it off', () {
      final reader = _reader()
        ..ingest(_dump([_addParticipant('p1', 'meet-9')]))
        ..ingest(_delta([_addRecording('r1', meetingId: 'meet-9', by: 'ada')]));
      expect(reader.isRecording, isTrue);

      reader.ingest(_delta([
        {'op': 'deletemodel', 'model': 'MeetingRecording', 'id': 'r1'},
      ]));
      expect(reader.isRecording, isFalse);
      expect(reader.recordingStartedBy, isNull);
    });

    test('an endedAt written onto the row turns it off too', () {
      final reader = _reader()
        ..ingest(_dump([_addParticipant('p1', 'meet-9')]))
        ..ingest(_delta([_addRecording('r1', meetingId: 'meet-9', by: 'ada')]));
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

    test('activeRecordingId on our Meeting row lights the dot (documented signal)',
        () {
      final reader = _reader()
        ..ingest(_dump([_addParticipant('p1', 'meet-9')]));

      reader.ingest(_delta([
        {
          'op': 'replace',
          'model': 'Meeting',
          'id': 'meet-9',
          'path': '/activeRecordingId',
          'data': 'rec-abc',
        },
      ]));
      expect(reader.isRecording, isTrue);

      reader.ingest(_delta([
        {
          'op': 'replace',
          'model': 'Meeting',
          'id': 'meet-9',
          'path': '/activeRecordingId',
          'data': null,
        },
      ]));
      expect(reader.isRecording, isFalse);
    });

    test('activeRecordingId on a different meeting does not light our dot', () {
      final reader = _reader()
        ..ingest(_dump([_addParticipant('p1', 'meet-9')]));

      final changed = reader.ingest(_delta([
        {
          'op': 'replace',
          'model': 'Meeting',
          'id': 'other-meet',
          'path': '/activeRecordingId',
          'data': 'rec-abc',
        },
      ]));
      expect(changed, isFalse);
      expect(reader.isRecording, isFalse);
    });

    test('an isActivelyRecording flag on our Meeting row is honoured as a fallback',
        () {
      final reader = _reader()
        ..ingest(_dump([_addParticipant('p1', 'meet-9')]));

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

    test('joining a meeting already recording lights the dot and republishes', () {
      // The recording is seen first, while we are in no meeting — so it stays dark.
      final reader = _reader()..ingest(_dump([]));
      reader.ingest(_delta([_addRecording('r1', meetingId: 'meet-9', by: 'ada')]));
      expect(reader.isRecording, isFalse);

      // Walking in flips it on, and the frame reports a change so the roster republishes.
      final changed = reader.ingest(_delta([_addParticipant('p1', 'meet-9')]));
      expect(changed, isTrue);
      expect(reader.isRecording, isTrue);
      expect(reader.recordingStartedBy, 'ada');
    });

    test('leaving a recording meeting clears the dot and republishes', () {
      final reader = _reader()
        ..ingest(_dump([_addParticipant('p1', 'meet-9')]))
        ..ingest(_delta([_addRecording('r1', meetingId: 'meet-9', by: 'ada')]));
      expect(reader.isRecording, isTrue);

      final changed = reader.ingest(_delta([
        {'op': 'deletemodel', 'model': 'MeetingParticipant', 'id': 'p1'},
      ]));
      expect(changed, isTrue);
      expect(reader.isRecording, isFalse);
      expect(reader.currentMeetingId, isNull);
    });
  });
}
