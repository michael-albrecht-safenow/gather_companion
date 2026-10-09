/// What the server says back, and the three ways it says nothing at all.
///
/// Gather's failure mode is silence. An action whose arguments do not parse is
/// rejected *before* it runs, so nothing executes, no patch arrives, and a client
/// watching only patches cannot tell that apart from a slow network. The one
/// channel that carries the verdict is `actionReturns[]`, keyed by the `txnId` the
/// client generated — and it went unread here for exactly as long as the event bus
/// did, and for the same reason: a frame carrying only an acknowledgement has an
/// empty `patches` array.
///
/// The sender-name tests below are the same shape of bug one field over. Every
/// event carries `targetUserIds`, so an event read under the wrong sender key still
/// routes to the right person and merely arrives with nobody attached to it.
library;

import 'package:gather_client/gather_client.dart';
import 'package:test/test.dart';

const _me = 'me-1';
const _them = 'them-1';

Map<String, Object?> _dump() => {
      'type': 'FullStateChunk',
      'sequenceNumber': 124,
      'fullStatePatches': [
        {
          'op': 'addmodel',
          'model': 'Connection',
          'data': {'id': 'c1', 'authUserId': 'uid-1', 'spaceUserId': _me},
        },
        {
          'op': 'addmodel',
          'model': 'SpaceUser',
          'data': {'id': _me, 'name': 'Me', 'connected': true},
        },
      ],
    };

Map<String, Object?> _ack(String txnId, {Object? value = 'ok'}) => {
      'type': 'DeltaState',
      'patches': const <Object?>[],
      'actionReturns': [
        {
          'connectionId': 'c1',
          'txnId': txnId,
          'result': {'type': 'Success', 'value': value},
        },
      ],
    };

Map<String, Object?> _refusal(String txnId, Object? error) => {
      'type': 'DeltaState',
      'patches': const <Object?>[],
      'actionReturns': [
        {
          'connectionId': 'c1',
          'txnId': txnId,
          'result': {'type': 'Error', 'error': error},
        },
      ],
    };

GameProtocolReader _reader() => GameProtocolReader()..authUserId = 'uid-1';

void main() {
  group('action verdicts', () {
    test('a success is paired with the transaction that asked for it', () {
      final reader = _reader()..ingest(_dump());
      reader.ingest(_ack('txn-1', value: 'row-9'));

      final result = reader.takeResults().single;
      expect(result.txnId, 'txn-1');
      expect(result.ok, isTrue);
      expect(result.value, 'row-9');
      expect(result.error, isNull);
    });

    test('a refusal carries what the server said', () {
      final reader = _reader()..ingest(_dump());
      reader.ingest(_refusal('txn-2', 'Cannot wave at yourself'));

      final result = reader.takeResults().single;
      expect(result.ok, isFalse);
      expect(result.error, 'Cannot wave at yourself');
    });

    test('anything that is not Success is a refusal', () {
      // Asked positively on purpose. An unrecognised `type` treated as a success is
      // how a refusal goes back to being invisible.
      final reader = _reader()..ingest(_dump());
      reader.ingest({
        'type': 'DeltaState',
        'patches': const <Object?>[],
        'actionReturns': [
          {
            'txnId': 'txn-3',
            'result': {'type': 'SomethingNew'},
          },
        ],
      });

      expect(reader.takeResults().single.ok, isFalse);
    });

    test('draining hands them over once', () {
      final reader = _reader()..ingest(_dump());
      reader.ingest(_ack('txn-4'));

      expect(reader.takeResults(), hasLength(1));
      expect(reader.takeResults(), isEmpty);
    });

    test('a frame carrying only an acknowledgement is not an unknown frame', () {
      // The whole reason this went unnoticed: a refused action produces no patch, so
      // its answer arrives in a frame that looks empty. The event bus was missed for
      // years on the strength of exactly this.
      final reader = _reader()..ingest(_dump());
      final before = reader.stats()['unknownFrames'] as int;
      reader.ingest(_refusal('txn-5', 'no'));

      expect(reader.stats()['unknownFrames'], before);
      expect(reader.stats()['actionErrors'], 1);
    });
  });

  group('describing a refusal', () {
    test('a business rule is already a sentence', () {
      expect(describeActionError('Cannot wave at yourself'), 'Cannot wave at yourself');
    });

    test('a zod issue list is unwrapped down to the field that was wrong', () {
      // The shape the server sends for a schema violation. It enumerates the valid
      // domain too, which is how the `MoveDirection` enum was recovered without
      // reading any source — but the first issue's message is what a person needs.
      const issues = '[{"received":"Sideways","code":"invalid_enum_value",'
          '"options":["Up","Down","Left","Right"],"path":["direction"],'
          '"message":"Invalid enum value"}]';
      expect(describeActionError(issues), 'direction: Invalid enum value');
    });

    test('an issue with no path keeps just the message', () {
      expect(
        describeActionError('[{"path":[],"message":"Required"}]'),
        'Required',
      );
    });

    test('something that only looks like JSON is passed through whole', () {
      expect(describeActionError('{not json'), '{not json');
    });

    test('an empty refusal still says something', () {
      expect(describeActionError(null), isNotEmpty);
      expect(describeActionError('  '), isNotEmpty);
    });
  });

  group('the sequence anchor', () {
    test('the highest sequence the server sent is what we hold', () {
      final reader = _reader()..ingest(_dump());
      expect(reader.lastSequence, 124);

      reader.ingest({'type': 'DeltaState', 'patches': const <Object?>[], 'sequenceNumber': 142});
      expect(reader.lastSequence, 142);
    });

    test('it never goes backwards', () {
      // Strictly increasing on the wire, but a client that took the last value it
      // saw rather than the highest would report a stale one after any reordering.
      final reader = _reader()..ingest(_dump());
      reader.ingest({'type': 'DeltaState', 'patches': const <Object?>[], 'sequenceNumber': 200});
      reader.ingest({'type': 'DeltaState', 'patches': const <Object?>[], 'sequenceNumber': 3});

      expect(reader.lastSequence, 200);
    });

    test('a heartbeat carries none, and does not clear the one we have', () {
      final reader = _reader()..ingest(_dump());
      reader.ingest({'type': 'Heartbeat', 'timestamp': 1, 'origin': 'Client'});

      expect(reader.lastSequence, 124);
    });
  });

  group('who sent an event', () {
    /// Every event names its sender under a different key, and none of them fails
    /// loudly: `targetUserIds` still routes it, so the only symptom is a wave from
    /// nobody.
    BusEvent? first(Map<String, Object?> payload) {
      final reader = _reader()..ingest(_dump());
      reader.ingest({
        'type': 'DeltaState',
        'patches': const <Object?>[],
        'events': [
          {
            'payload': payload,
            'options': {
              'targetUserIds': [_me],
            },
          },
        ],
      });
      final pending = reader.takePending();
      return pending.isEmpty ? null : pending.first;
    }

    test('WaveEvent says senderId', () {
      expect(first({'eventName': 'WaveEvent', 'senderId': _them})?.senderId, _them);
    });

    test('EmoteEvent says senderUserId', () {
      expect(first({'eventName': 'EmoteEvent', 'senderUserId': _them})?.senderId, _them);
    });

    test('ConfettiThrown says senderSpaceUserId', () {
      expect(
        first({'eventName': 'ConfettiThrown', 'senderSpaceUserId': _them, 'x': 35, 'y': 29})
            ?.senderId,
        _them,
      );
    });

    test('an event naming nobody is still delivered', () {
      final event = first({'eventName': 'NewMemberJoined'});
      expect(event?.name, 'NewMemberJoined');
      expect(event?.senderId, isNull);
    });
  });

  group('dancing', () {
    test('is carried onto the roster, because no coordinate implies it', () {
      final reader = _reader()..ingest(_dump());
      reader.ingest({
        'type': 'DeltaState',
        'patches': [
          {'op': 'replace', 'model': 'SpaceUser', 'id': _me, 'path': '/dancing', 'data': true},
        ],
      });

      expect(reader.roster().rows.single.dancing, isTrue);
    });

    test('stopping arrives the same way', () {
      final reader = _reader()..ingest(_dump());
      reader.ingest({
        'type': 'DeltaState',
        'patches': [
          {'op': 'replace', 'model': 'SpaceUser', 'id': _me, 'path': '/dancing', 'data': true},
        ],
      });
      reader.ingest({
        'type': 'DeltaState',
        'patches': [
          {'op': 'replace', 'model': 'SpaceUser', 'id': _me, 'path': '/dancing', 'data': false},
        ],
      });

      expect(reader.roster().rows.single.dancing, isFalse);
    });

    test('is null rather than false before it has ever arrived', () {
      final reader = _reader()..ingest(_dump());
      expect(reader.roster().rows.single.dancing, isNull);
    });
  });

  group('a raised hand', () {
    test('goes up when a handRaisedAt timestamp arrives', () {
      final reader = _reader()..ingest(_dump());
      reader.ingest({
        'type': 'DeltaState',
        'patches': [
          // A timestamp, not a bool — the wire's way of saying the hand is up.
          {'op': 'replace', 'model': 'SpaceUser', 'id': _me, 'path': '/handRaisedAt', 'data': 1700000000000},
        ],
      });

      expect(reader.roster().rows.single.handRaised, isTrue);
    });

    test('comes down when the field goes to undefined', () {
      final reader = _reader()..ingest(_dump());
      reader.ingest({
        'type': 'DeltaState',
        'patches': [
          {'op': 'replace', 'model': 'SpaceUser', 'id': _me, 'path': '/handRaisedAt', 'data': 1700000000000},
        ],
      });
      reader.ingest({
        'type': 'DeltaState',
        'patches': [
          // Lowering is the timestamp blanked to the ext-4 undefined sentinel, not
          // null and not an absent key — the trap that would leave the hand stuck up.
          {'op': 'replace', 'model': 'SpaceUser', 'id': _me, 'path': '/handRaisedAt', 'data': msgpackUndefined},
        ],
      });

      expect(reader.roster().rows.single.handRaised, isFalse);
    });

    test('is false rather than null before it has ever arrived', () {
      final reader = _reader()..ingest(_dump());
      expect(reader.roster().rows.single.handRaised, isFalse);
    });
  });
}
