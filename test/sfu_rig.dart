/// The fakes wired together the way a call actually runs.
///
/// One rig serves both `sfu_session_test.dart` and `live_call_test.dart`: the
/// session test drives it directly, the call test drives it through [LiveCall].
/// Sharing it is deliberate — two hand-built scripts of the same protocol would
/// drift, and the one that drifted would be the one still passing.
library;

import 'dart:async';

import 'package:gather_client/gather_client.dart';
import 'package:gather_companion/src/media/sfu_session.dart';

import 'fake_mediasoup.dart';
import 'fake_signalling.dart';

const spaceId = 'space-1';
const me = 'acct-me';
const them = 'acct-them';
const routerUrl = 'wss://router.test';
const nodeA = 'wss://sfu-v2.test:443/ip-10-0-0-1';
const nodeB = 'wss://sfu-v2.test:443/ip-10-0-0-2';

/// A session with fakes underneath and the scripts they answer with.
class Rig {
  Rig() {
    session = SfuSession(
      auth: GatherAuth(
        credentials: const GatherCredentials(refreshToken: 'unused'),
      ),
      spaceId: spaceId,
      srcId: me,
      routerUrl: routerUrl,
      openSignalling: (url, _) => open(url),
      buildDevice: () => device,
      // Short enough that a test does not wait out the real five seconds, long
      // enough that an ordinary `settle()` round trip does not trip it (issue #83).
      nodeDownGrace: const Duration(milliseconds: 20),
    );
    session.needsRepublish.listen((_) => republishes++);
  }

  late final SfuSession session;
  final FakeDevice device = FakeDevice();

  /// Where the router says each person's media lives. A missing entry is
  /// `addrFound: false` — the normal answer for somebody not yet placed.
  final Map<String, String?> addresses = {me: nodeA, them: nodeA};

  /// Sockets by url, replaced when one is dropped and opened again.
  final Map<String, FakeSignalling> sockets = {};

  /// Node-socket methods this rig should refuse with a specific server message,
  /// applied to every media node as it opens. How a test makes a fresh session
  /// carry a stale token: seed `{'produce': '...TokenVerificationFailed...'}`.
  final Map<String, String> nodeRefusals = {};

  /// Node urls whose `start()` should hang until [releaseConnect] is called, so a
  /// test can keep a node connecting while a second caller races to reuse it.
  final Set<String> slowToConnect = {};
  final Map<String, Completer<void>> _connectGates = {};

  /// Let a node held by [slowToConnect] finish connecting.
  void releaseConnect(String url) => _connectGates[url]?.complete();

  int republishes = 0;
  bool _closed = false;

  /// Idempotent, because the one test that drives a virtual clock has to close
  /// the session *inside* that clock — a future created in a `fakeAsync` zone
  /// never completes once the zone is gone, so a second close from `tearDown`
  /// would hang the runner rather than fail anything.
  Future<void> close() {
    if (_closed) return Future<void>.value();
    _closed = true;
    return session.dispose();
  }

  /// The microphone producer the session actually built, for a test that wants
  /// to make it loud.
  FakeProducer? get micProducer {
    for (final transport in device.transports) {
      for (final producer in transport.producers) {
        if (producer.tag == 'audio') return producer;
      }
    }
    return null;
  }

  FakeSignalling get router => sockets[routerUrl]!;
  FakeSignalling node([String url = nodeA]) => sockets[url]!;

  FakeSignalling open(String url) {
    final socket = sockets[url] = FakeSignalling(url);
    if (url == routerUrl) {
      socket.answer('get-addr', (args) {
        final srcId = args['srcId'] as String;
        final addr = addresses[srcId];
        if (addr == null) return {'addrFound': false};
        // The address arrives as a *separate* event, not in the ack, which is
        // the shape the real router uses and the reason the listener has to be
        // registered before the question goes out.
        scheduleMicrotask(
            () => socket.push('addrs', {'srcId': srcId, 'sfuAddr': addr}));
        return {'addrFound': true};
      });
      return socket;
    }

    socket
      ..answer('get-rtp-capabilities', (_) => {
            'routerRtpCapabilities': {
              'codecs': <Map<String, Object?>>[],
              'headerExtensions': <Map<String, Object?>>[],
            },
          })
      ..answer('transport-create', (args) => transport(args['direction']))
      ..answer('produce', (args) => {'id': 'server-${args['tag']}'})
      ..answer(
          'consume',
          (args) => {
                'id': 'consumer-${args['srcId']}-${args['tag']}',
                'producerId': producerIds['${args['srcId']}|${args['tag']}'],
                'producerPaused': false,
                'rtpParameters': rtpParameters,
              })
      ..answer('restart-ice', (_) => {
            'iceParameters': iceParameters,
            'iceServers': [
              {'urls': 'turn:cf.turn.gather.town', 'username': 'u', 'credential': 'c'},
            ],
          });
    socket.failingWith.addAll(nodeRefusals);
    if (slowToConnect.contains(url)) {
      socket.startGate = (_connectGates[url] = Completer<void>()).future;
    }
    return socket;
  }

  /// What `consume` should claim each `(srcId|tag)` producer is, set by whatever
  /// `consume-try` the test pushed.
  final Map<String, String> producerIds = {};

  /// Announce a peer's producers, the way the server does — full state, always.
  void announce(String srcId, Map<String, String> producers, {String url = nodeA}) {
    for (final entry in producers.entries) {
      producerIds['$srcId|${entry.key}'] = entry.value;
    }
    sockets[url]!.push('consume-try', {
      'srcId': srcId,
      'srcStreamId': spaceId,
      'producerIdMap': producers,
    });
  }

  Map<String, Object?> transport(Object? direction) => {
        'id': 'transport-$direction',
        'iceParameters': iceParameters,
        'iceCandidates': <Map<String, Object?>>[],
        'dtlsParameters': {'role': 'auto', 'fingerprints': <Map<String, Object?>>[]},
        'iceServers': [
          {'urls': 'turn:cf.turn.gather.town', 'username': 'u', 'credential': 'c'},
        ],
      };

  static const iceParameters = {
    'usernameFragment': 'ufrag',
    'password': 'pass',
    'iceLite': false,
  };

  /// Shaped like Gather's, which means **`rtcp` carries only a `cname`**.
  ///
  /// This used to also say `mux` and `reducedSize`, and that politeness is what
  /// hid a bug that broke every call: `RtcpParameters.fromMap` feeds
  /// `map['reducedSize']` into a non-nullable `bool`, so the real server's
  /// `{"cname": "…"}` threw a `TypeError` and no remote track was ever built,
  /// while the suite stayed green against a fake that answered more fully than
  /// the thing it stood for. A fake may be smaller than the real server. It may
  /// not be more generous than it.
  ///
  /// Measured against the live SFU on 2026-09-17; see
  /// `docs/protocol/observed-wire-protocol.md`.
  static const rtpParameters = {
    'codecs': <Map<String, Object?>>[],
    'headerExtensions': <Map<String, Object?>>[],
    'encodings': <Map<String, Object?>>[],
    'rtcp': {'cname': 'fake'},
  };
}

