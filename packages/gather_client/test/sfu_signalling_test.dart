/// [SfuSignalling] against a real Socket.IO server.
///
/// This is where the reverse-engineered risk lives. The media plane was read off
/// a capture rather than from documentation, and Gather's signature failure mode
/// is silence — a wrong-shaped call is not rejected, it simply never answers. So
/// the assertions here are mostly about *shape*: the envelope, the exemptions,
/// and the auth payload, pinned so a future edit cannot quietly change them.
library;

import 'dart:async';

import 'package:gather_client/gather_client.dart';
import 'package:test/test.dart';

import 'fake_gather.dart' show FakeGatherHttp;
import 'fake_sfu.dart';

Future<T> firstWhere<T>(
  Stream<T> stream,
  bool Function(T) test, {
  Duration timeout = const Duration(seconds: 5),
  String? reason,
}) =>
    stream.firstWhere(test).timeout(
          timeout,
          onTimeout: () => throw StateError('timed out waiting for ${reason ?? T}'),
        );

void main() {
  late FakeSfuServer sfu;
  late FakeGatherHttp http;
  SfuSignalling? signalling;

  setUp(() async {
    sfu = await FakeSfuServer.start();
    http = FakeGatherHttp();
  });

  tearDown(() async {
    await signalling?.dispose();
    signalling = null;
    await sfu.close();
  });

  SfuSignalling build({
    String spaceId = 'space-1',
    String? sessionId,
    String? url,
  }) {
    final auth = GatherAuth(
      credentials: const GatherCredentials(refreshToken: 'refresh-1'),
      http: http,
    );
    return signalling = SfuSignalling(
      auth: auth,
      url: url ?? sfu.url,
      spaceId: spaceId,
      sessionId: sessionId,
    );
  }

  /// A signalling client addressed the way the **router** addresses a node.
  SfuSignalling buildNode({String? sessionId}) =>
      build(sessionId: sessionId, url: sfu.nodeUrl);

  /// Connects and hands back the server's view of that connection.
  ///
  /// Waits for *both* ends. The server seeing CONNECT is not enough: its reply
  /// still has to travel back before the client will send anything, and a test
  /// that raced that would fail intermittently rather than honestly.
  Future<FakeSfuConnection> connected(SfuSignalling s) async {
    final serverSaw = firstWhere(sfu.onConnected, (_) => true, reason: 'a CONNECT');
    final clientReady =
        firstWhere(s.statuses, (st) => st.healthy, reason: 'a healthy status');
    await s.start();
    final conn = await serverSaw;
    await clientReady;
    return conn;
  }

  group('the handshake', () {
    test('authenticates in the CONNECT packet, not a header or a query', () async {
      final conn = await connected(build());

      // The finding this whole file rests on: the credential rides in the
      // Socket.IO CONNECT payload.
      expect(conn.auth, isNotNull);
      expect(conn.auth!['spaceId'], 'space-1');
      expect(conn.auth!['token'], isA<String>());
      expect((conn.auth!['token'] as String).isNotEmpty, isTrue);
    });

    test('carries a sessionId in the url query', () async {
      await connected(buildNode(sessionId: 'session-abc'));
      expect(sfu.connections.single.uri.queryParameters['sessionId'], 'session-abc');
    });

    test('mints its own sessionId when not given one', () async {
      // It is a client-generated nonce: it appears in no inbound frame, and two
      // captured connections produced two unrelated UUIDs.
      await connected(buildNode());
      final minted = sfu.connections.single.uri.queryParameters['sessionId'];
      expect(minted, isNotNull);
      expect(minted, matches(RegExp(r'^[0-9a-f-]{36}$')));
    });

    test("the node's /ip- segment is a path prefix, not a namespace", () async {
      // The bug this guards cost a whole evening. Handed the router's address
      // whole, `socket_io_client` reads `/ip-…` as the Socket.IO *namespace* and
      // requests `/socket.io/` at the root — which the node answers with plain
      // HTTP, so the upgrade never happens and the failure reads "was not
      // upgraded to websocket". Measured against the desktop client: it connects
      // to `/ip-10-206-193-211/socket.io/`.
      await connected(buildNode());
      expect(sfu.connections.single.uri.path, '/ip-127-0-0-1/socket.io/');
    });

    test('the router gets no sessionId, because the real one does not', () async {
      // `wss://router.v2.gather.town/socket.io/?EIO=4&transport=websocket` —
      // that is the whole query in the capture. Only the media nodes carry a
      // session.
      await connected(build());
      expect(sfu.connections.single.uri.path, '/socket.io/');
      expect(sfu.connections.single.uri.queryParameters['sessionId'], isNull);
    });

    test('start() does not resolve until the socket can carry traffic', () async {
      // The regression. `_open()` ends at `socket.connect()`, which only starts
      // the handshake, so `start()` used to resolve a round trip early and the
      // caller's first question came back `not connected` — followed, a beat
      // later, by the connection succeeding. Awaiting `start()` alone must be
      // enough; no listening to `statuses` first.
      final s = build();
      await s.start();
      expect(s.connected, isTrue);
    });

    test('a question asked the instant start() returns reaches the server',
        () async {
      // The same bug from the caller's side, which is how it was reported:
      // `publishing audio failed: not connected` immediately followed by
      // `sfu: connected`.
      final s = build();
      await s.start();

      final pending = s.sendWithResponse('get-rtp-capabilities');
      final conn = sfu.connections.single;
      final frames = await conn.waitForFrames(1);
      conn.ack(frames.single.ackId!, {'routerRtpCapabilities': <String, Object?>{}});

      expect(await pending, containsPair('routerRtpCapabilities', anything));
    });

    test('start() gives up rather than resolving on a socket that never answers',
        () async {
      // Half-open: the TCP connection succeeds and the server then says nothing.
      // Resolving here would be worse than throwing — the caller would publish
      // into a void and report success.
      sfu.stallConnect = true;
      final s = build();

      await expectLater(
        s.start(timeout: const Duration(milliseconds: 200)),
        throwsA(isA<SfuException>()),
      );
      expect(s.connected, isFalse);
    });

    test('two starts at once join one attempt rather than racing', () async {
      // Both callers must be told the truth. The failure this guards is subtle:
      // a second `start()` replacing the first attempt's completer leaves the
      // first caller waiting on something nothing completes any more, so it
      // times out while the connection it asked for succeeds around it.
      final s = build();
      await Future.wait([s.start(), s.start()]);

      expect(s.connected, isTrue);
      expect(sfu.connections, hasLength(1));
    });

    test('reports healthy only once connected', () async {
      final s = build();
      expect(s.connected, isFalse);
      // `connected` itself waits for the healthy status, so reaching here is the
      // assertion; waiting again would block on an event already consumed.
      await connected(s);
      expect(s.connected, isTrue);
    });
  });

  group('a bad-auth connect refusal (#84)', () {
    /// Polls [test] until it holds or the deadline passes. The token invalidation
    /// is fire-and-forget off `onConnectError`, so the extra refresh lands a
    /// microtask or two after `start()` throws — awaiting a count rather than a
    /// fixed delay keeps the test honest on a loaded runner.
    Future<void> eventually(bool Function() test,
        {Duration timeout = const Duration(seconds: 5), String? reason}) async {
      final deadline = DateTime.now().add(timeout);
      while (!test()) {
        if (DateTime.now().isAfter(deadline)) {
          throw StateError('condition never held: ${reason ?? ''}');
        }
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }

    const badAuth = '{message: bad auth, data: {reason: TokenVerificationFailed}}';

    test('forces a fresh token before the retry', () async {
      // The whole point of #84. The server refuses the credential; the held token
      // is not clock-expired, so without the invalidation the retry would present
      // the *same* refused token forever. A bad-auth refusal must drop the cache
      // so the next `_open` mints a new one.
      sfu.refuseWith = badAuth;
      final s = build();

      await expectLater(s.start(), throwsA(isA<SfuException>()));

      // One mint for the initial `_open`, a second forced by the refusal.
      await eventually(() => http.refreshes >= 2,
          reason: 'the bad-auth refusal did not force a token refresh');
    });

    test('a non-auth refusal does not force a refresh', () async {
      // The invalidation is for stale credentials only. A plain transient refusal
      // ("node draining", a 5xx) must not drop the token and hammer Google — the
      // ordinary backoff retry re-presents the same still-valid token.
      sfu.refuseWith = 'sfu node is draining';
      final s = build();

      await expectLater(s.start(), throwsA(isA<SfuException>()));

      // Give any stray invalidation a window to land, then prove it did not.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(http.refreshes, 1,
          reason: 'only the initial mint — a transient refusal keeps the token');
    });

    test('recovers on the retry once the token is fresh', () async {
      // End to end: refuse bad-auth, which forces a refresh, then accept. The
      // background backoff retry must reconnect with the new token rather than
      // leaving the call dead until a restart.
      sfu.refuseWith = badAuth;
      final s = build();
      await expectLater(s.start(), throwsA(isA<SfuException>()));

      // The next attempt is allowed through, and the backoff timer fires it.
      sfu.refuseWith = null;
      await firstWhere(s.statuses, (st) => st.healthy,
          reason: 'a healthy status after the token refreshed');
      expect(s.connected, isTrue);
      expect(http.refreshes, greaterThanOrEqualTo(2));
    });
  });

  group('the address the router hands out', () {
    // Pinned against the capture, verbatim. These two strings are the whole bug:
    // the left is what `addrs` carries, the right is what the desktop client
    // actually opens.
    test('splits into an origin socket_io_client understands, and a path', () {
      final split = splitSfuAddress(
        'wss://sfu-v2.eu-central-1-a.prod.aws.gather.town:443/ip-10-206-193-211',
      );

      // `https`, not `wss`: the library fills in a default port for http/https
      // and does not recognise the websocket schemes, which is how an explicit
      // `:443` became `:0` in the field.
      expect(split.origin,
          'https://sfu-v2.eu-central-1-a.prod.aws.gather.town');
      expect(split.path, '/ip-10-206-193-211/socket.io/');
    });

    test('leaves the router alone, which is why this went unnoticed', () {
      final split = splitSfuAddress('wss://router.v2.gather.town');
      expect(split.origin, 'https://router.v2.gather.town');
      expect(split.path, '/socket.io/');
    });

    test('keeps a port that is not the default, so a fake server is reachable',
        () {
      final split = splitSfuAddress('ws://127.0.0.1:8080/ip-127-0-0-1');
      expect(split.origin, 'http://127.0.0.1:8080');
      expect(split.path, '/ip-127-0-0-1/socket.io/');
    });
  });

  group('the envelope', () {
    test('wraps a normal call and numbers it', () async {
      final s = build();
      final conn = await connected(s);

      s.sendWithResponse('produce', {'tag': 'audio'}).ignore();
      await conn.waitForFrames(1);

      final sent = conn.received.single;
      expect(sent.name, 'produce');
      expect(sent.data, {
        'wsSequenceNumber': 1,
        'zodData': {'tag': 'audio'},
      });
    });

    test('the sequence number increments per call', () async {
      final s = build();
      final conn = await connected(s);

      s.sendWithResponse('produce', {'tag': 'audio'}).ignore();
      s.sendWithResponse('produce', {'tag': 'video'}).ignore();
      await conn.waitForFrames(2);

      final numbers = conn.received
          .map((f) => (f.data as Map)['wsSequenceNumber'])
          .toList();
      expect(numbers, [1, 2]);
    });

    test('get-addr and unsubscribe are sent bare', () async {
      // Measured: these went out as plain {srcId, srcStreamId} while everything
      // else on the same socket was wrapped. Wrapping them is the kind of mistake
      // Gather answers with silence.
      final s = build();
      final conn = await connected(s);

      s.sendWithResponse('get-addr', {'srcId': 'a', 'srcStreamId': 'b'}).ignore();
      s.emit('unsubscribe', {'srcId': 'a', 'srcStreamId': 'b'});
      await conn.waitForFrames(2);

      for (final frame in conn.received) {
        expect(
          frame.data,
          {'srcId': 'a', 'srcStreamId': 'b'},
          reason: '${frame.name} must not be wrapped',
        );
      }
    });

    test('a bare call does not consume a sequence number', () async {
      final s = build();
      final conn = await connected(s);

      s.sendWithResponse('get-addr', {'srcId': 'a'}).ignore();
      s.sendWithResponse('produce', {'tag': 'audio'}).ignore();
      await conn.waitForFrames(2);

      final produce = conn.received.firstWhere((f) => f.name == 'produce');
      expect((produce.data as Map)['wsSequenceNumber'], 1);
    });
  });

  group('request and response', () {
    test('an ack answers the call that asked for it', () async {
      final s = build();
      final conn = await connected(s);

      final pending = s.sendWithResponse('consume', {'tag': 'audio'});
      await conn.waitForFrames(1);
      conn.ack(conn.received.single.ackId!, {'id': 'consumer-1', 'producerPaused': true});

      expect(await pending, {'id': 'consumer-1', 'producerPaused': true});
    });

    test('interleaved replies go to the right callers', () async {
      // The whole point of the ack id. Answered out of order on purpose.
      final s = build();
      final conn = await connected(s);

      final first = s.sendWithResponse('consume', {'tag': 'audio'});
      final second = s.sendWithResponse('consume', {'tag': 'video'});
      await conn.waitForFrames(2);

      conn.ack(conn.received[1].ackId!, {'id': 'video-consumer'});
      conn.ack(conn.received[0].ackId!, {'id': 'audio-consumer'});

      expect((await first)['id'], 'audio-consumer');
      expect((await second)['id'], 'video-consumer');
    });

    test('an empty ack is success, not failure', () async {
      // consume-resume and friends answer `[]`.
      final s = build();
      final conn = await connected(s);

      final pending = s.sendWithResponse('consume-resume', {'tag': 'audio'});
      await conn.waitForFrames(1);
      conn.send('43${conn.received.single.ackId}[]');

      expect(await pending, isEmpty);
    });

    test('an ack carrying an error is a refusal, with the reason kept', () async {
      // Captured 2026-09-17: `consume-pause` on a consumer the server had
      // already closed was acked `[{"error":"no such consumer",
      // "clientShouldRecover":true}]`. Returned as a reply, the caller would
      // fail one step later on a missing id and never see the reason.
      final s = build();
      final conn = await connected(s);

      final pending = s.sendWithResponse('consume-pause', {'tag': 'audio'});
      await conn.waitForFrames(1);
      conn.ack(conn.received.single.ackId!,
          {'error': 'no such consumer', 'clientShouldRecover': true});

      await expectLater(
        pending,
        throwsA(isA<SfuException>()
            .having((e) => e.toString(), 'message', contains('no such consumer'))),
      );
    });

    test('a call that is never answered fails instead of hanging', () async {
      // Gather goes silent rather than erroring, so a caller that cannot tell
      // "no" from "nothing" would hold a call open forever.
      final s = build();
      await connected(s);

      await expectLater(
        s.sendWithResponse('consume', const {}, const Duration(milliseconds: 200)),
        throwsA(isA<SfuException>()),
      );
    });

    test('calling before connecting refuses rather than queueing', () async {
      final s = build();
      await expectLater(
        s.sendWithResponse('produce', const {}),
        throwsA(isA<SfuException>()),
      );
    });
  });

  group('notifications', () {
    test('consume-try arrives with the whole producer map', () async {
      // It is a full-state announcement, not a delta: callers reconcile against
      // it rather than treating it as an event.
      final s = build();
      final conn = await connected(s);

      final waiting = firstWhere(
        s.notifications,
        (n) => n.name == 'consume-try',
        reason: 'consume-try',
      );
      conn.push('consume-try', {
        'srcId': 'them',
        'srcStreamId': 'space-1',
        'producerIdMap': {'audio': 'p1', 'video': 'p2'},
      });

      final note = await waiting;
      expect(note.data['srcId'], 'them');
      expect(note.data['producerIdMap'], {'audio': 'p1', 'video': 'p2'});
    });

    test('an unwrapped array payload is unwrapped', () async {
      final s = build();
      final conn = await connected(s);

      final waiting =
          firstWhere(s.notifications, (n) => n.name == 'producer-paused');
      conn.push('producer-paused', [
        {'srcId': 'them', 'tag': 'audio'},
      ]);

      expect((await waiting).data['tag'], 'audio');
    });

    test('an unrecognised event still surfaces rather than vanishing', () async {
      // A protocol change should show up, not quietly stop working.
      final s = build();
      final conn = await connected(s);

      final waiting = firstWhere(s.notifications, (n) => n.name == 'something-new');
      conn.push('something-new', {'x': 1});
      expect((await waiting).name, 'something-new');

      // And it is counted, which is the half that was missing: the field existed
      // and its comment promised a number going up, but nothing ever incremented
      // it — so the one alarm this client has for a protocol change was wired to
      // nothing.
      expect(s.unknownEvents, 1);
      expect(s.unknownEventNames, {'something-new'});
    });

    test('a known event is not counted as a protocol change', () async {
      final s = build();
      final conn = await connected(s);

      // Everything the server is measured to say, plus the router's own. If this
      // list drifts from `docs/gather-api.md` the counter cries wolf on every
      // call and stops meaning anything.
      final waiting = firstWhere(s.notifications, (n) => n.name == 'server-info');
      conn
        ..push('consume-try', {'srcId': 'them', 'producerIdMap': <String, String>{}})
        ..push('producer-paused', {'srcId': 'them', 'tag': 'audio'})
        ..push('set-max-spatial-layer', {'kind': 'video', 'layer': 1})
        ..push('double-connected', <String, Object?>{})
        ..push('cordon-sfu', {'sfuAddr': 'wss://elsewhere'})
        ..push('server-info', <String, Object?>{});
      await waiting;

      expect(s.unknownEvents, 0);
    });
  });

  test('a refused credential is reported, not retried into silence', () async {
    sfu.refuseWith = 'bad token';
    final s = build();
    final unhealthy = firstWhere(
      s.statuses,
      (st) => !st.healthy && (st.detail ?? '').contains('refused'),
      reason: 'a refusal',
    );

    // Both halves matter. The status is how the app learns; the throw is how the
    // *caller* learns, and it has to be prompt — a refusal is the server saying
    // no, not the server being slow, so waiting out the connect timeout to
    // deliver the same news would leave a tapped button dead for ten seconds.
    await expectLater(s.start(), throwsA(isA<SfuException>()));
    expect((await unhealthy).healthy, isFalse);
  });
}
