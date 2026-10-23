/// A fake Gather game server, the Dart counterpart of `bridge/test/fake-gather.js`.
///
/// A real `HttpServer` doing a real WebSocket upgrade, so [DirectCollector] runs its
/// production socket path — `WebSocket.connect`, binary frames, close codes and all.
/// Mocking the socket would leave the one part most likely to be wrong untested.
///
/// It speaks just enough of the protocol to be worth testing against: the handshake
/// is recorded verbatim so assertions can check what the collector sent, and state
/// is only dumped for a connection that actually authenticated — because Gather's
/// distinguishing behaviour is that it stays *silent* on a bad handshake rather
/// than rejecting it.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:gather_client/gather_client.dart';

/// The default dump: me, and one other person.
List<Map<String, Object?>> defaultPatches() => [
      {
        'op': 'addmodel',
        'model': 'Connection',
        'data': {
          'id': 'conn-1',
          'spaceId': 'space-1',
          'authUserId': 'uid-1',
          'spaceUserId': 'me-1',
          'entered': false,
          'target': 'OfficeView',
        },
      },
      {
        'op': 'addmodel',
        'model': 'Space',
        'data': {'id': 'space-1', 'name': 'Test Space'},
      },
      {
        'op': 'addmodel',
        'model': 'SpaceUser',
        'data': {
          'id': 'me-1',
          'name': 'Me',
          'position': {r'$type': 'Position', 'x': 10, 'y': 10},
          'floorId': 'floor-1',
          'connected': true,
          'isBot': false,
        },
      },
      {
        'op': 'addmodel',
        'model': 'SpaceUser',
        'data': {
          'id': 'them-1',
          'name': 'Neighbour',
          'position': {r'$type': 'Position', 'x': 11, 'y': 10},
          'floorId': 'floor-1',
          'connected': true,
          'isBot': false,
        },
      },
    ];

/// One `WaveEvent`, shaped exactly as captured from a live space on 2026-08-07.
///
/// The two halves live in different places on purpose, because they do in the real
/// envelope: who waved is `payload.senderId`, who they waved *at* is
/// `options.targetUserIds`.
Map<String, Object?> waveEvent({
  String senderId = 'them-1',
  String targetId = 'me-1',
  String sentTime = '2026-08-07T14:22:20.563Z',
}) =>
    {
      'payload': {'eventName': 'WaveEvent', 'senderId': senderId, 'sentTime': sentTime},
      'options': {
        'targetUserIds': [targetId],
      },
    };

class FakeConnection {
  FakeConnection(this.socket, this.url);

  final WebSocket socket;
  final String url;

  /// Every frame the client sent, decoded.
  final List<Map<String, Object?>> received = [];
  bool authenticated = false;
  bool dumped = false;

  void send(Map<String, Object?> frame) {
    if (socket.readyState == WebSocket.open) socket.add(msgpackEncode(frame));
  }

  /// Push a delta after the dump, the way the real server does.
  void delta(List<Map<String, Object?>> patches) =>
      send({'type': 'DeltaState', 'sequenceNumber': 2, 'patches': patches});

  /// Push interaction events onto Gather's event bus.
  ///
  /// A real wave arrives in a `DeltaState` whose `patches` array is **empty** —
  /// which is why the bus went unread for so long, and so exactly what a test needs.
  void bus(List<Map<String, Object?>> events) => send({
        'type': 'DeltaState',
        'sequenceNumber': 3,
        'patches': <Object?>[],
        'actionReturns': <Object?>[],
        'events': events,
      });

  /// The client's most recent [action] frame, once it has actually arrived.
  ///
  /// [received] is filled from a real socket, so "the client called the method"
  /// and "this server has the bytes" are two different moments and no amount of
  /// draining microtasks closes the gap — `pumpEventQueue` does not wait for a
  /// localhost round trip. A 5 kB `setCustomStatus` frame lost that race on a
  /// loaded CI runner while the small frames on either side of it did not, which
  /// is the shape of flake that only ever fails where nobody is looking.
  ///
  /// Polled rather than slept on. A fixed delay is the same bug with a wider
  /// margin: it is still a guess about somebody else's scheduler, and it costs
  /// that guess on every green run. This returns the moment the frame lands.
  ///
  /// [key] is `type` for the frames that have no `action` — the heartbeat.
  ///
  /// [where] narrows past a name that is sent more than once. `reportActivity`
  /// is sent twice — `isActive: true` on enter, then whatever `setActive` asks —
  /// and the two land in a socket race the backward scan would otherwise resolve
  /// to the enter frame, returning the wrong one the moment it arrives.
  Future<Map<String, Object?>> waitFor(
    String action, {
    String key = 'action',
    bool Function(Map<String, Object?>)? where,
  }) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (true) {
      for (var i = received.length - 1; i >= 0; i--) {
        if (received[i][key] == action && (where == null || where(received[i]))) {
          return received[i];
        }
      }
      if (DateTime.now().isAfter(deadline)) {
        throw StateError('the client never sent $action');
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  /// Refuse the last action of [action], the way the real gateway does.
  ///
  /// The refusal is addressed by `txnId`, so the transaction has to be looked up in
  /// what the client actually sent — which is the point: pairing an answer back to
  /// the question is the whole job of the code under test. Answers arrive with an
  /// **empty** `patches` array, because a refused action changes nothing.
  Future<void> refuse(String action, Object? error) async {
    final sent = await waitFor(action);
    send({
      'type': 'DeltaState',
      'sequenceNumber': 4,
      'patches': <Object?>[],
      'actionReturns': [
        {
          'connectionId': 'conn-1',
          'txnId': sent['txnId'],
          'result': {'type': 'Error', 'error': error},
        },
      ],
    });
  }
}

class FakeGatherServer {
  FakeGatherServer._(this._server, this.url);

  final HttpServer _server;

  /// `ws://127.0.0.1:<port>` — pass straight to [DirectCollector.socketUrl].
  final String url;

  final List<FakeConnection> connections = [];
  final _connected = StreamController<FakeConnection>.broadcast();

  /// Fires as each client finishes its handshake and gets its dump.
  Stream<FakeConnection> get onDumped => _connected.stream;

  FakeConnection? get latest => connections.isEmpty ? null : connections.last;

  /// When true, the server upgrades the socket and then says nothing at all — no
  /// heartbeat, no dump. This is the dead-zone case the backoff exists for: a connect
  /// that succeeds onto an immediately-deaf pipe (issue #8). A test can still push
  /// frames by hand through [latest] to prove a frame resets the backoff.
  static Future<FakeGatherServer> start({
    bool requireAuth = true,
    bool silent = false,
    List<Map<String, Object?>> Function()? patches,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fake = FakeGatherServer._(server, 'ws://127.0.0.1:${server.port}');

    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      final conn = FakeConnection(socket, request.uri.toString());
      fake.connections.add(conn);

      // The real server heartbeats before the first state chunk, which is what makes
      // a premature "handshake rejected" verdict so tempting. A silent server skips
      // it on purpose, so the socket is deaf from the first byte.
      if (!silent) conn.send({'type': 'Heartbeat', 'timestamp': 1, 'origin': 'Server'});

      socket.listen((data) {
        if (data is! List<int>) return;
        final Object? decoded;
        try {
          decoded = msgpackDecode(Uint8List.fromList(data));
        } on Object {
          return;
        }
        if (decoded is! Map<String, Object?>) return;
        conn.received.add(decoded);

        if (decoded['type'] == 'Authenticate') {
          final credential = decoded['credential'];
          conn.authenticated = credential is Map &&
              credential['type'] == 'JWT' &&
              (credential['jwt'] as String?)?.isNotEmpty == true;
        }
        if (decoded['action'] == 'loadSpaceUser') {
          // A silent server never dumps — the pipe stays deaf no matter what we send.
          if (silent) return;
          // Stay silent when unauthenticated, as Gather does.
          if (requireAuth && !conn.authenticated) return;
          conn.send({'type': 'SpaceStatus', 'warmInGatewayServer': true});
          conn.send({
            'type': 'FullStateChunk',
            'sequenceNumber': 1,
            'fullStatePatches': (patches ?? defaultPatches)(),
          });
          conn.dumped = true;
          if (!fake._connected.isClosed) fake._connected.add(conn);
        }
      }, onError: (Object _) {});
    });

    return fake;
  }

  Future<void> close() async {
    for (final c in connections) {
      try {
        await c.socket.close();
      } on Object {
        /* gone */
      }
    }
    await _connected.close();
    await _server.close(force: true);
  }
}

/// A syntactically valid JWT carrying a chosen uid.
///
/// The collector reads the uid straight out of the token, so this also keeps tests
/// from depending on whatever session the developer happens to have paired.
String fakeJwt({String uid = 'uid-1', Duration validFor = const Duration(hours: 1)}) {
  final exp = DateTime.now().add(validFor).millisecondsSinceEpoch ~/ 1000;
  final claims = _b64({'user_id': uid, 'exp': exp});
  return 'eyJhbGciOiJub25lIn0.$claims.sig';
}

String _b64(Map<String, Object?> claims) {
  final json = claims.entries
      .map((e) => '"${e.key}":${e.value is String ? '"${e.value}"' : e.value}')
      .join(',');
  return base64UrlNoPad('{$json}');
}

String base64UrlNoPad(String text) {
  const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
  final bytes = text.codeUnits;
  final out = StringBuffer();
  for (var i = 0; i < bytes.length; i += 3) {
    final b0 = bytes[i];
    final b1 = i + 1 < bytes.length ? bytes[i + 1] : null;
    final b2 = i + 2 < bytes.length ? bytes[i + 2] : null;
    out.write(chars[b0 >> 2]);
    out.write(chars[((b0 & 0x03) << 4) | ((b1 ?? 0) >> 4)]);
    if (b1 != null) out.write(chars[((b1 & 0x0f) << 2) | ((b2 ?? 0) >> 6)]);
    if (b2 != null) out.write(chars[b2 & 0x3f]);
  }
  return out.toString();
}

/// A [GatherHttp] that never touches the network.
///
/// A suite that reached Google would be slow, flaky, and would burn the developer's
/// real session.
class FakeGatherHttp implements GatherHttp {
  FakeGatherHttp({
    this.idToken,
    this.status = 200,
    this.errorCode,
    this.spaces = const {},
  });

  String? idToken;
  int status;
  String? errorCode;
  Map<String, Object?> spaces;

  int refreshes = 0;

  @override
  Future<({int status, Map<String, Object?> body})> postForm(
    Uri uri,
    Map<String, String> fields,
  ) async {
    refreshes++;
    if (status != 200) {
      return (
        status: status,
        body: {
          'error': {'message': errorCode ?? 'SOMETHING_ELSE'},
        },
      );
    }
    return (
      status: 200,
      body: {
        'id_token': idToken ?? fakeJwt(),
        'refresh_token': fields['refresh_token'],
        'user_id': 'uid-1',
      },
    );
  }

  @override
  Future<({int status, Object? body})> getJson(Uri uri, String bearer) async =>
      (status: 200, body: spaces);

  /// Msgpack bodies, keyed by the last path segment of the URI they answer.
  Map<String, List<int>> bytes = const {};

  /// The status [getBytes] and [postBytes] answer with. Separate from [status],
  /// which belongs to the token endpoint — a suite needs to fail one without
  /// failing the other.
  int byteStatus = 200;

  /// Every [postJson] call, in order, so a test can assert what was sent.
  final List<({Uri uri, Object? body})> posts = [];

  @override
  Future<({int status, List<int> body})> getBytes(Uri uri, String bearer) async => (
        status: byteStatus,
        body: bytes[uri.pathSegments.last] ?? const <int>[],
      );

  @override
  Future<({int status, List<int> body})> postJson(
    Uri uri,
    String bearer,
    Object? body,
  ) async {
    posts.add((uri: uri, body: body));
    return (status: byteStatus, body: const <int>[]);
  }
}
