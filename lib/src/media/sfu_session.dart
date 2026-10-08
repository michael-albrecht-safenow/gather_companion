/// Publishing to Gather's SFU.
///
/// [SfuSignalling] knows how to say things to the media plane; this knows *what*
/// to say and in what order. The sequence is fixed and each step depends on the
/// last, which is why it reads as a script rather than a state machine:
///
///   1. connect the **router** (`wss://router.v2.gather.town`)
///   2. `get-addr` for our own `srcId` → `addrs {sfuAddr}`
///   3. connect that **node**
///   4. `get-rtp-capabilities` → `Device.load()`
///   5. `transport-create {direction:'send'}` → a mediasoup send transport
///   6. `produce` per track
///
/// Steps 1–4 happen at space join in the desktop client, before any call — they
/// are not call setup, they are being ready for one. Only 5 and 6 wait for
/// somebody to talk to.
///
/// ## `srcId` is the UserAccount id
///
/// Not the `SpaceUser` id. The game plane keys on `SpaceUser`, the media plane on
/// `UserAccount`, and asking the router about the wrong one returns a stream that
/// does not exist — silently, because that is Gather's failure mode. Measured
/// 2026-08-13; see `docs/gather-api.md`.
library;

import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:gather_client/gather_client.dart';
import 'package:mediasfu_mediasoup_client/mediasfu_mediasoup_client.dart' as ms;
// The ICE types, from our own shim rather than from the package: they are not
// exported, and `mediasoup_ice.dart` explains why reaching past the barrel is
// the only way to pass Gather's TURN servers at all.
import 'mediasoup_ice.dart';

/// What Gather calls a stream on a person. `kind` is the codec's idea of the
/// track; `tag` is Gather's idea of what it is *for*, and they differ for screen
/// share, which is `{tag: 'screen', kind: 'video'}`.
enum SfuTag {
  audio,
  video,
  screen;

  String get wire => name;
}

/// Somebody else's media, as this client currently holds it.
///
/// [paused] is *their* mute, not ours: the track is still there and still
/// subscribed, and it will start again without renegotiating. A UI that drew a
/// paused person as absent would make every mute look like a disconnection.
class RemoteMedia {
  const RemoteMedia({
    required this.srcId,
    required this.streams,
    required this.paused,
  });

  /// Their `UserAccount.id` — the media plane's identity, not `SpaceUser.id`.
  final String srcId;
  final Map<SfuTag, MediaStream> streams;
  final Set<SfuTag> paused;

  MediaStream? get audio => streams[SfuTag.audio];
  MediaStream? get video => streams[SfuTag.video];
  MediaStream? get screen => streams[SfuTag.screen];

  bool get hasVideo => video != null && !paused.contains(SfuTag.video);
}

/// Gather's tag word, or null if it is one we do not model.
///
/// Null rather than a default: a tag we have never seen is a protocol change,
/// and quietly filing it under `audio` would play somebody's screen share into
/// the earpiece.
SfuTag? _tagOf(Object? wire) => switch (wire) {
      'audio' => SfuTag.audio,
      'video' => SfuTag.video,
      'screen' => SfuTag.screen,
      _ => null,
    };

class SfuSession {
  SfuSession({
    required GatherAuth auth,
    required String spaceId,
    required String srcId,
    String routerUrl = gatherSfuRouter,
    SfuSignalling Function(String url, String? sessionId)? openSignalling,
    ms.Device Function()? buildDevice,
    void Function(String)? log,
    // Assigned the long way round because a named parameter cannot be a private
    // initializing formal — same as `DirectCollector` and `SfuSignalling`.
  })  :
        // ignore: prefer_initializing_formals
        _auth = auth,
        // ignore: prefer_initializing_formals
        _spaceId = spaceId,
        // ignore: prefer_initializing_formals
        _srcId = srcId,
        // ignore: prefer_initializing_formals
        _routerUrl = routerUrl,
        // ignore: prefer_initializing_formals
        _openSignalling = openSignalling,
        _buildDevice = buildDevice ?? _realDevice,
        _log = log ?? _noop;

  static void _noop(String _) {}

  /// The mediasoup half, and the only part of this file a test cannot run.
  ///
  /// `Device.load()` reaches for an `RTCPeerConnection` to ask the platform what
  /// it can encode, so it needs a device — while everything this class is
  /// *about* (assignment, the node pool, reconciliation, recovery) is ordinary
  /// logic that should not. Same seam as `MediaEngine`, one layer down: the
  /// native part is injected, so the reverse-engineered part can be tested.
  static ms.Device _realDevice() => ms.Device();

  final GatherAuth _auth;
  final String _spaceId;
  final String _srcId;
  final String _routerUrl;
  final void Function(String) _log;

  /// Test seam: lets a suite hand back a signalling client pointed at a fake.
  final SfuSignalling Function(String url, String? sessionId)? _openSignalling;

  final ms.Device Function() _buildDevice;

  SfuSignalling? _router;
  SfuSignalling? _node;
  ms.Device? _device;
  ms.Transport? _sendTransport;
  final Map<SfuTag, ms.Producer> _producers = {};

  String? _sfuAddr;

  /// Every node we hold a socket to, keyed by url — **including** our own.
  ///
  /// A pool rather than a connection, because peers are spread across nodes:
  /// `get-addr` is asked per *person*, not once at startup, and two colleagues in
  /// the same conversation can easily answer with two different hosts. Modelling
  /// this as one media connection would work in a small space and quietly lose
  /// half the room in a large one.
  final Map<String, SfuSignalling> _nodes = {};

  /// Which node each peer's media is on, learned from the router.
  final Map<String, String> _peerNode = {};

  /// One receive transport per node, built on first use.
  final Map<String, ms.Transport> _recvTransports = {};

  /// Live consumers, keyed `srcId|tag`.
  final Map<String, ms.Consumer> _consumers = {};

  /// What the server says each peer is publishing — the desired state that
  /// [_reconcile] steers towards. Replaced wholesale per `consume-try`, never
  /// merged: the announcement is full-state, and merging would leave a track
  /// alive after somebody stopped sending it.
  final Map<String, Map<SfuTag, String>> _announced = {};

  /// Peers we have asked the server to send us.
  final Set<String> _subscribed = {};

  /// Peers the SFU has refused to let us consume since the last successful one.
  ///
  /// The discriminator the receive-path watchdog keys on. A room where everyone
  /// is legitimately silent also builds no consumers, but it produces no
  /// denials either, so this stays empty and the watchdog never fires — it is
  /// only the deaf join, where every `consume-request` comes back
  /// `consume-not-allowed`, that fills this.
  final Set<String> _consumeDenied = {};

  /// Peers we want but the router could not place yet. See [_addressFor].
  final Set<String> _awaitingAddr = {};
  Timer? _addrRetry;

  /// Nodes whose socket is currently down, so a later `healthy` reads as a
  /// reconnection rather than as the first connect.
  final Set<String> _nodeDown = {};

  final Map<String, StreamSubscription<SfuStatus>> _nodeHealth = {};

  final _remotes = StreamController<List<RemoteMedia>>.broadcast();
  final _notifications = StreamController<SfuNotification>.broadcast();
  final _republish = StreamController<void>.broadcast();
  final Map<String, StreamSubscription<SfuNotification>> _nodeSubscriptions = {};

  /// Fires when our producers are gone and only the owner of the tracks can
  /// bring them back.
  ///
  /// A dropped socket or a drained node takes the send transport and every
  /// producer with it, server-side. This session cannot republish by itself —
  /// it never held the camera, [MediaEngine] did — so the honest thing is to say
  /// so and let [LiveCall] put the same tracks back. Without this, a call
  /// survives a lift as a socket that looks connected and carries nothing.
  Stream<void> get needsRepublish => _republish.stream;

  /// Everybody we are currently receiving, most recently changed last.
  List<RemoteMedia> get remotes => _remoteList();

  /// Fires whenever [remotes] changes — a track arriving, going, or being paused.
  Stream<List<RemoteMedia>> get remoteChanges => _remotes.stream;

  /// Whether we are ready to publish. False until [start] has run through.
  bool get ready => _device?.loaded == true && _node != null;

  String? get sfuAddr => _sfuAddr;

  /// Everything every node says unprompted, merged.
  ///
  /// Merged rather than per-node because the caller cares that a colleague's
  /// camera came on, not which host told us.
  Stream<SfuNotification> get notifications => _notifications.stream;

  /// Steps 1–4: assigned, connected, and capable.
  Future<void> start() async {
    _stopped = false;
    final router = _open(_routerUrl, null);
    _router = router;

    // The router talks back, and for a while nothing was listening to it.
    // `cordon-sfu` — the notice that a node is being drained — is **router**
    // vocabulary (`docs/gather-api.md`, "Two sockets, then a pool"), so a session
    // that watched only its media nodes could never hear the one message that
    // says everything it has built is about to stop working.
    _routerSub = router.notifications.listen(_onNotification);
    await router.start();

    await _assign();

    // Gather's own constants: credentials last 86400s and it refreshes every
    // 14400. A phone call rarely runs four hours, so this is insurance rather
    // than routine — but the failure it insures against is a relay silently
    // expiring mid-call, which looks exactly like the other person going quiet.
    _turnTimer?.cancel();
    _turnTimer = Timer.periodic(
      const Duration(seconds: 14400),
      (_) => unawaited(refreshTurn()),
    );
  }

  /// Find our node, connect to it, and become able to publish on it.
  ///
  /// Separate from [start] because it happens **twice**: once at the beginning,
  /// and again whenever the node we were assigned is drained and the router hands
  /// us a different one. Everything here is safe to run a second time.
  Future<void> _assign() async {
    final router = _router;
    if (router == null) throw const SfuException('the router is not connected');

    final addr = await _addressFor(_srcId, attempts: 4);
    if (addr == null) {
      throw const SfuException('the router has not assigned us an SFU node yet');
    }
    _sfuAddr = addr;
    _log('sfu: assigned $addr');

    final node = await _nodeAt(addr);
    _node = node;

    final caps = await node.sendWithResponse('get-rtp-capabilities');
    final routerCaps = caps['routerRtpCapabilities'];
    if (routerCaps is! Map) {
      throw const SfuException('the SFU returned no routerRtpCapabilities');
    }

    final device = _buildDevice();
    await device.load(
      routerRtpCapabilities:
          ms.RtpCapabilities.fromMap(Map<String, dynamic>.from(routerCaps)),
    );
    _device = device;
    _log('sfu: device loaded');

    _replayAllow(node);
    _sendConversation();
  }

  /// Re-send the allow list to [node].
  ///
  /// The client does exactly this in `playerConnectedSFU` —
  /// `Object.keys(this.allowed).forEach(e => r.allow(e))` — because the list
  /// lives on the *node*. A list built before this socket existed, or one built
  /// before the socket dropped and came back, means nothing to it.
  void _replayAllow(SfuSignalling node) {
    for (final dstId in _allowed) {
      node.emit('consume-allow', {'dstId': dstId, 'allowed': true});
    }
  }

  Timer? _turnTimer;
  StreamSubscription<SfuNotification>? _routerSub;

  /// A connected socket to [url], reused if we already hold one.
  ///
  /// Every node is watched the same way, so a `consume-try` about a colleague on
  /// a far node reaches the same reconciliation as one about a colleague on ours.
  Future<SfuSignalling> _nodeAt(String url) async {
    final existing = _nodes[url];
    if (existing != null) return existing;

    final node = _open(url, null);
    _nodes[url] = node;
    _nodeSubscriptions[url] = node.notifications.listen(_onNotification);
    try {
      await node.start();
    } on Object {
      // Do not leave a half-open node in the pool: the next caller would reuse it
      // and get `not connected` rather than a fresh attempt.
      _nodes.remove(url);
      await _nodeSubscriptions.remove(url)?.cancel();
      await node.dispose();
      rethrow;
    }

    // Subscribed *after* the first connect, so the `healthy` event that start()
    // just consumed does not read as a reconnection.
    _nodeHealth[url] = node.statuses.listen((status) {
      if (!status.healthy) {
        _nodeDown.add(url);
        return;
      }
      if (_nodeDown.remove(url)) unawaited(_onNodeReconnected(url));
    });
    return node;
  }

  /// The router's answer to "where is this person's media?".
  ///
  /// Cached per peer. `cordon-sfu` and `reassign` are what invalidate it.
  Future<String?> _nodeUrlFor(String srcId) async {
    final cached = _peerNode[srcId];
    if (cached != null) return cached;
    final addr = await _addressFor(srcId);
    if (addr == null) return null;
    return _peerNode[srcId] = addr;
  }

  /// Ask the router which node carries [srcId], retrying while it says nobody.
  ///
  /// **`addrFound: false` is a normal answer, not an error** — measured, and
  /// stated as such in `docs/protocol/observed-wire-protocol.md`. It means the
  /// router has not assigned that person a node *yet*, which is a race a client
  /// runs into constantly: at join, and again every time somebody walks up
  /// before their own client has finished connecting. Treating it as fatal is
  /// what made a first tap fail permanently and a colleague stay silent forever.
  ///
  /// The answer arrives in two pieces — `{addrFound}` in the ack and the address
  /// itself in a separate `addrs` event — so listening has to start *before* the
  /// question goes out, or a fast answer lands while nobody is at the door.
  Future<String?> _addressFor(String srcId, {int attempts = 1}) async {
    final router = _router;
    if (router == null) return null;

    var wait = const Duration(milliseconds: 400);
    for (var attempt = 0; attempt < attempts; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(wait);
        wait *= 2;
      }

      final addrs = _firstNotification(
        router,
        'addrs',
        where: (n) => n.data['srcId'] == srcId,
        timeout: const Duration(seconds: 6),
      );
      final ack = await router.sendWithResponse(
        'get-addr',
        {'srcId': srcId, 'srcStreamId': _spaceId},
      );

      if (ack['addrFound'] == false) {
        // No `addrs` is coming for this one. Left to settle null on its own
        // timeout rather than awaited — waiting six seconds for a reply the
        // server has already declined to send is the whole cost this avoids.
        unawaited(addrs);
        continue;
      }

      final addr = (await addrs)?.data['sfuAddr'];
      if (addr is String && addr.isNotEmpty) return addr;
    }
    return null;
  }

  /// The next notification matching [name], or **null** if it never comes.
  ///
  /// Null rather than an error, deliberately. This future is created *before* the
  /// request that provokes the reply — it has to be, or a fast answer lands before
  /// anyone is listening — which means there is a window where it exists and
  /// nothing is awaiting it yet. A future that completes with an error inside that
  /// window is reported as an unhandled exception and takes the isolate's error
  /// handler with it, which is exactly what happened here: `Stream.firstWhere` on
  /// a socket that closed threw `Bad state: No element` out of a microtask, from
  /// code whose own `try` had already moved on. Completing with null cannot do
  /// that, and it puts the decision about what the absence *means* at the call
  /// site, where the wording of the error belongs.
  Future<SfuNotification?> _firstNotification(
    SfuSignalling signalling,
    String name, {
    bool Function(SfuNotification)? where,
    Duration timeout = const Duration(seconds: 10),
  }) {
    final completer = Completer<SfuNotification?>();
    late final StreamSubscription<SfuNotification> subscription;

    void settle(SfuNotification? value) {
      if (completer.isCompleted) return;
      completer.complete(value);
      subscription.cancel();
    }

    final timer = Timer(timeout, () => settle(null));
    subscription = signalling.notifications.listen(
      (n) {
        if (n.name == name && (where == null || where(n))) settle(n);
      },
      // The socket dying is an answer too, and a faster one than the timeout.
      onDone: () => settle(null),
      onError: (Object _) => settle(null),
    );

    return completer.future.whenComplete(timer.cancel);
  }

  /// Step 5, on demand: the transport everything we publish rides on.
  ///
  /// Created lazily and once. The desktop client does the same — a transport is
  /// ICE and DTLS, and negotiating it before anyone is listening spends battery
  /// on a conversation that may never happen.
  Future<ms.Transport> _sendTransportOrCreate() async {
    final existing = _sendTransport;
    if (existing != null) return existing;

    final node = _node;
    final device = _device;
    if (node == null || device == null) {
      throw const SfuException('publish before start');
    }

    final reply = await node.sendWithResponse(
      'transport-create',
      {'direction': 'send', 'iceTransportRequestOptions': _iceTransportOptions},
    );
    _checkTransportReply(reply, 'send');

    // NOT `createSendTransportFromMap`: that helper hardcodes `iceServers: []`,
    // which would drop Gather's TURN servers on the floor. The failure mode is
    // the worst kind — fine on a permissive network, silently no media behind a
    // symmetric NAT, and no error either way.
    final transport = device.createSendTransport(
      id: reply['id'] as String,
      iceParameters:
          ms.IceParameters.fromMap(_map(reply['iceParameters'])),
      iceCandidates: [
        for (final c in (reply['iceCandidates'] as List? ?? const []))
          ms.IceCandidate.fromMap(_map(c)),
      ],
      dtlsParameters:
          ms.DtlsParameters.fromMap(_map(reply['dtlsParameters'])),
      iceServers: _iceServers(reply['iceServers']),
      iceTransportPolicy: reply['iceTransportPolicy'] == 'relay'
          ? RTCIceTransportPolicy.relay
          : RTCIceTransportPolicy.all,
      appData: _map(reply['appData']),
      // The transport hands its Producer back here rather than from `produce()`,
      // which returns void.
      producerCallback: _onProducer,
    );

    // mediasoup hands the DTLS handshake back to us: it produces the parameters,
    // we deliver them, and nothing proceeds until `callback()` is called.
    transport.on('connect', (Map data) async {
      try {
        await node.sendWithResponse('transport-connect', {
          'transportId': transport.id,
          'dtlsParameters': (data['dtlsParameters'] as ms.DtlsParameters).toMap(),
        });
        data['callback']();
      } on Object catch (error) {
        _log('sfu: transport-connect failed: $error');
        data['errback'](error);
        _failPendingProducer(error);
      }
    });

    // Fired once per `produce()`. The listener's job is to tell the server and
    // hand back the id the server chose — the local Producer is not created until
    // it does.
    transport.on('produce', (Map data) async {
      try {
        final reply = await node.sendWithResponse('produce', {
          'transportId': transport.id,
          'tag': (data['appData'] as Map?)?['tag'] ?? data['kind'],
          'kind': data['kind'],
          'rtpParameters': (data['rtpParameters'] as ms.RtpParameters).toMap(),
        });
        final id = reply['id'];
        if (id is! String) throw const SfuException('produce returned no id');
        data['callback'](id);
      } on Object catch (error) {
        _log('sfu: produce failed: $error');
        data['errback'](error);
        // And tell whoever is waiting, which `errback` alone does not.
        //
        // mediasoup treats a failed `produce` as a failed *task*: the producer
        // is never built, so `producerCallback` never fires, so [publish] waits
        // out its own twenty-second timeout before saying anything. Twenty
        // seconds of a dead unmute button, for a refusal the server sent
        // immediately.
        _failPendingProducer(error);
      }
    });

    // Whether media is actually flowing, which nothing else in this file can
    // tell you.
    //
    // A producer the server has accepted and left unpaused still carries no
    // sound if ICE never completed: the signalling all succeeds, the colleague's
    // client draws you as unmuted, and the room hears silence. That is a
    // genuinely different failure from anything on the socket, and without this
    // line it is invisible from the logs.
    transport.on('connectionstatechange', (Map data) {
      _log('sfu: send transport is ${data['connectionState']}');
    });

    // Nothing may produce on this until the handler has built its peer
    // connection.
    //
    // `Transport`'s constructor starts `handler.run()` and does not wait for it:
    // it is declared `void ... async`, so `createSendTransport` returns while the
    // RTCPeerConnection is still null. The first `produce()` then reaches
    // `_pc!.addTransceiver` a millisecond later and throws a null check, which
    // `FlexQueue` swallows whole — no log, nothing on the wire, and [publish]
    // waiting out its own twenty seconds before saying "timed out". The second
    // produce always worked, because by then `run()` had finished. That is the
    // bug that made the microphone look dead while the camera looked merely slow
    // (measured 2026-09-17, `build/call-capture/media8.log`).
    await transport.handler.ready;

    _sendTransport = transport;
    return transport;
  }

  /// Measured at last, 2026-09-17: a `probe-sfu.mjs reload` during a live call
  /// caught `transport-create` in both directions. The request is
  /// `{direction, iceTransportRequestOptions}` and the reply is the standard
  /// mediasoup `{id, iceParameters, iceCandidates, dtlsParameters}` plus
  /// Gather's `iceServers` (Cloudflare STUN/TURN with per-session credentials),
  /// `iceTransportPolicy` and `appData` — exactly what this checks for. See
  /// `docs/protocol/observed-wire-protocol.md`, "Publishing".
  ///
  /// The check stays, because a shape change is still where a future Gather
  /// release would break this app first. The alternative was a bare
  /// `reply['id'] as String`, which fails as a cast error naming neither the
  /// message nor the assumption, three frames deep in a callback, and reads on
  /// a device log like a bug in the WebRTC plugin.
  void _checkTransportReply(Map<String, Object?> reply, String direction) {
    const required = ['id', 'iceParameters', 'iceCandidates', 'dtlsParameters'];
    final missing = [
      for (final key in required)
        if (reply[key] == null) key,
    ];
    if (missing.isEmpty && reply['id'] is String) return;
    throw SfuException(
      'transport-create ($direction) answered in a shape this client does not '
      'know: missing ${missing.join(', ')}, got ${reply.keys.join(', ')}. The '
      'standard mediasoup reply is the one assumption in this file that no '
      'capture has confirmed.',
    );
  }

  /// Where the transport delivers a finished Producer.
  ///
  /// `produce()` returns void and the object arrives here instead, so [publish]
  /// waits on this rather than on a return value.
  Completer<ms.Producer>? _pendingProducer;

  void _onProducer(ms.Producer producer) {
    final pending = _pendingProducer;
    if (pending != null && !pending.isCompleted) pending.complete(producer);
  }

  void _failPendingProducer(Object error) {
    final pending = _pendingProducer;
    if (pending != null && !pending.isCompleted) pending.completeError(error);
  }

  /// Step 6: put a track on the wire.
  ///
  /// [stream] is the capture the track came from; mediasoup needs it to build the
  /// sender, not just the track.
  Future<void> publish(
    MediaStreamTrack track,
    MediaStream stream, {
    required SfuTag tag,
  }) async {
    if (_producers.containsKey(tag)) return;
    // Standing down means standing down. Without this the claim that [displaced]
    // is sticky was only a comment: the next tap would publish again and restart
    // the fight with the desktop that stopping was meant to end.
    if (_displaced) {
      throw const SfuException(
          'another client of yours is holding this call — quit Gather there');
    }
    final transport = await _sendTransportOrCreate();

    // One at a time. The callback is per-transport rather than per-produce, so
    // two overlapping publishes could not be told apart.
    while (_pendingProducer != null) {
      await _pendingProducer!.future.catchError((_) => throw const SfuException('busy'));
    }
    final completer = Completer<ms.Producer>();
    _pendingProducer = completer;

    try {
      transport.produce(
        track: track,
        stream: stream,
        source: tag == SfuTag.screen
            ? 'screen'
            : (tag == SfuTag.audio ? 'mic' : 'webcam'),
        appData: {'tag': tag.wire},
        // Video only, and that is a hard constraint rather than a preference.
        // See [_videoEncodings]; a microphone must be given *nothing* here.
        encodings: tag == SfuTag.audio
            ? const <ms.RtpEncodingParameters>[]
            : _videoEncodings,
        // Opus with in-band FEC and DTX, matching what the desktop client
        // negotiates — DTX is why a live-but-silent microphone costs almost
        // nothing on the wire.
        codecOptions: tag == SfuTag.audio
            ? ms.ProducerCodecOptions(opusStereo: 0, opusDtx: 1, opusFec: 1)
            : null,
      );

      final producer = await completer.future.timeout(
        const Duration(seconds: 20),
        onTimeout: () => throw SfuException('producing ${tag.wire} timed out'),
      );
      _producers[tag] = producer;
      _log('sfu: publishing ${tag.wire} as ${producer.id}');
      _reportOutboundRtp(tag, producer);
    } finally {
      _pendingProducer = null;
    }
  }

  /// Says out loud, once, what the microphone and the sender are actually doing.
  ///
  /// The signalling can be perfect — producer accepted, never paused, the
  /// colleague's client drawing you unmuted — while the room hears silence,
  /// because "the server knows about this track" and "this microphone can hear
  /// anything" are different claims and neither appears on the socket.
  ///
  /// **Each report is named.** `getStats()` on a producer returns stats for the
  /// whole peer connection, so the `candidate-pair` and `transport` rows carry
  /// the *combined* byte counts of every track on it. Reading those as if they
  /// were this producer's is how a silent microphone came to look like healthy
  /// speech on 2026-09-17: the number being admired was the camera's.
  ///
  /// `audioLevel` on the `media-source` row is the one that settles it. It is
  /// the signal coming off the microphone, before any of this: zero there means
  /// the device is handing us silence and nothing further down can fix it.
  void _reportOutboundRtp(SfuTag tag, ms.Producer producer) {
    Future<void>.delayed(const Duration(seconds: 5), () async {
      if (_producers[tag] != producer) return;
      try {
        final stats = await producer.getStats();
        for (final report in (stats as List? ?? const [])) {
          final type = '${(report as dynamic).type}';
          final values = _map((report as dynamic).values);
          if (type == 'media-source' && values['kind'] == 'audio') {
            _log('sfu: the microphone is at level ${values['audioLevel']} '
                '(energy ${values['totalAudioEnergy']})');
          }
          if (type == 'outbound-rtp' && values['kind'] == tag.wire) {
            _log('sfu: ${tag.wire} outbound-rtp — ${values['packetsSent']} '
                'packets, ${values['bytesSent']} bytes');
          }
        }
      } on Object catch (error) {
        _log('sfu: could not read ${tag.wire} stats: $error');
      }
    });
  }

  /// How loud the microphone is right now, 0 to 1, or null if it cannot say.
  ///
  /// The `media-source` row, which is the signal coming *off the device* —
  /// before encoding, before the producer, before the wire. That is the right
  /// one for voice activity: `outbound-rtp` goes quiet under Opus DTX whether
  /// the room is silent or the network is, and an `inbound-rtp` audio level is
  /// somebody else's voice.
  ///
  /// Null rather than zero when there is no producer or the platform refuses the
  /// call, because "not measured" and "silent" lead somewhere different: the
  /// voice-activity detector holds its answer across a missing sample and would
  /// drop it on a zero.
  Future<double?> microphoneLevel() async {
    final producer = _producers[SfuTag.audio];
    if (producer == null) return null;
    try {
      final stats = await producer.getStats();
      for (final report in (stats as List? ?? const [])) {
        if ('${(report as dynamic).type}' != 'media-source') continue;
        final values = _map((report as dynamic).values);
        if (values['kind'] != 'audio') continue;
        final level = values['audioLevel'];
        if (level is num) return level.toDouble();
      }
    } on Object {
      // Polled several times a second; a platform that will not answer must not
      // fill the log with one line per attempt. The caller reads null as "no
      // sample", which is what this is.
      return null;
    }
    return null;
  }

  /// Whether we currently have a producer for [tag].
  bool publishing(SfuTag tag) => _producers.containsKey(tag);

  /// Mute, as the wire understands it.
  ///
  /// Muting at the device stops the *sound*; this stops the *stream*, and it is
  /// what makes a colleague's client draw the crossed-out microphone next to your
  /// name. Both are wanted: the device mute is what makes iOS drop its recording
  /// indicator, and this is what makes the mute visible to anyone else.
  ///
  /// The producer is kept rather than closed, so unmuting is a resume rather than
  /// a fresh negotiation. `produce-pause` takes only a tag — the SFU knows which
  /// producer is ours.
  void pause(SfuTag tag) {
    if (!_producers.containsKey(tag)) return;
    _producers[tag]?.pause();
    _node?.emit('produce-pause', {'tag': tag.wire});
  }

  void resume(SfuTag tag) {
    if (!_producers.containsKey(tag)) return;
    _producers[tag]?.resume();
    _node?.emit('produce-resume', {'tag': tag.wire});
  }

  /// Stops publishing one track, telling the server rather than just going quiet.
  Future<void> unpublish(SfuTag tag) async {
    final producer = _producers.remove(tag);
    if (producer == null) return;
    producer.close();
    _node?.emit('produce-close', {'tag': tag.wire});
  }

  /// Who may consume our streams — **the gate on anybody seeing us at all.**
  ///
  /// This is not a nicety. In the desktop client `PeerManager.allow(player)`
  /// keys on `userAccountId`, and its counterpart `_disallowImpl` stops
  /// producing entirely once nobody is allowed:
  ///
  /// ```js
  /// allow(A){ const e = A.userAccountId; … this.currentStrategy.allow(e);
  ///           if (wasProducingUnnecessary) { /* start producing */ } }
  /// ```
  ///
  /// So a client that publishes video without allowing anybody is publishing
  /// into a void: colleagues get `consume-not-allowed` and the little circle
  /// never appears over your head.
  ///
  /// The allow list is **wider than the cluster** — the client drives it from
  /// `inRangeSpaceUserIds`, everyone within twelve tiles on the same floor. Being
  /// in range is what makes your camera visible over your avatar; being in a
  /// cluster is having joined the conversation. Confusing the two means your
  /// video only ever reaches people you are already talking to, which is not what
  /// anybody standing next to you sees in Gather.
  final Set<String> _allowed = {};

  /// Everybody currently permitted to consume us.
  Set<String> get allowed => Set.unmodifiable(_allowed);

  /// Reconcile the whole allow list, as the client does — diffed, not re-sent.
  void setAllowed(Set<String> srcIds) {
    final wanted = srcIds.where((id) => id != _srcId).toSet();
    for (final gone in _allowed.difference(wanted).toList()) {
      allow(gone, allowed: false);
    }
    for (final added in wanted.difference(_allowed).toList()) {
      allow(added, allowed: true);
    }
  }

  void allow(String dstId, {required bool allowed}) {
    if (dstId == _srcId) return;
    if (allowed ? !_allowed.add(dstId) : !_allowed.remove(dstId)) return;
    _node?.emit('consume-allow', {'dstId': dstId, 'allowed': allowed});
  }

  /// Which conversation we are publishing into, as the SFU understands it.
  ///
  /// `set-player-conversation-metadata {meetingId, clusterId}` is in the measured
  /// method table and the desktop client sends it whenever the bubble changes —
  /// captured 2026-09-17: on joining, *before* the first `produce`, and again
  /// with `clusterId: ""` on leaving. What the server *does* with it is not
  /// measured — grouping for recording and for the meeting views are both
  /// plausible — so this is sent because the real client sends it, and its
  /// failure is logged rather than raised.
  ///
  /// **Both fields are strings, never null.** The desktop sends `""` for a
  /// missing value, and the schema probe of 2026-09-17 showed why: a `null` in
  /// either field gets no ack at all — zod rejects it and the server says
  /// nothing — so every earlier build of this app was timing out here and
  /// leaving the SFU with no idea which conversation the phone was in.
  void setConversation({String? clusterId, String? meetingId}) {
    if (clusterId == _clusterId && meetingId == _meetingId) return;
    _clusterId = clusterId;
    _meetingId = meetingId;
    _sendConversation();
  }

  String? _clusterId;
  String? _meetingId;

  void _sendConversation() {
    final node = _node;
    if (node == null) return;
    unawaited(
      node.sendWithResponse('set-player-conversation-metadata', {
        'meetingId': _meetingId ?? '',
        'clusterId': _clusterId ?? '',
      }).then(
        (_) {},
        onError: (Object error) =>
            _log('sfu: the conversation metadata was refused: $error'),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Receiving
  // ---------------------------------------------------------------------------

  /// Who is on screen, most important first, and how much of the screen they get.
  ///
  /// This is the receive-side half of simulcast, and skipping it is not free: a
  /// peer sends the bottom layer until somebody asks for better, so without this
  /// a face filling a phone screen stays a quarter-resolution thumbnail no matter
  /// how much bandwidth is going spare. The reverse matters more — when the call
  /// screen is closed, nobody is watching anything, and asking for layer 0
  /// everywhere hands back both their uplink and our download.
  ///
  /// Only the camera tag is steered. A screen share is text more often than not,
  /// and a downscaled one is unreadable rather than merely soft.
  void setWatching(List<String> srcIds, {required int layer}) {
    final wanted = layer.clamp(0, 2);
    for (final srcId in _subscribed) {
      final want = srcIds.contains(srcId) ? wanted : 0;
      final had = _spatial[srcId];
      if (had == want) continue;
      // Layer 0 is where a consumer starts, so saying so before we have ever
      // said anything else is a frame that changes nothing.
      if (had == null && want == 0) continue;
      _spatial[srcId] = want;
      _setRemoteSpatial(srcId, want);
    }

    if (_priority.length != srcIds.length ||
        !Iterable<int>.generate(srcIds.length)
            .every((i) => _priority[i] == srcIds[i])) {
      _priority = List.unmodifiable(srcIds);
      _sendPriority();
    }
  }

  /// The layer we have asked for from each peer, so a reconnect can ask again.
  final Map<String, int> _spatial = {};
  List<String> _priority = const [];

  void _setRemoteSpatial(String srcId, int layer) {
    final url = _peerNode[srcId];
    if (url == null) return;
    _nodes[url]?.emit('consume-set-spatial', {
      'srcId': srcId,
      'srcStreamId': _spaceId,
      'tag': SfuTag.video.wire,
      'spatialLayer': layer,
    });
  }

  /// Rank the peers for the SFU, one message per node.
  ///
  /// The message names no node of its own, and the people in one conversation
  /// can be spread over several, so each node is told about the peers it
  /// actually carries — in the order they matter.
  void _sendPriority() {
    final byNode = <String, List<String>>{};
    for (final srcId in _priority) {
      final url = _peerNode[srcId];
      if (url == null) continue;
      (byNode[url] ??= []).add(srcId);
    }
    for (final entry in byNode.entries) {
      _nodes[entry.key]?.emit('consume-set-priority', {
        'srcStreamId': _spaceId,
        'tag': SfuTag.video.wire,
        'srcIds': entry.value,
      });
    }
  }

  /// Ask the server to start sending us [srcId]'s media.
  ///
  /// This does not itself create a consumer. It puts us on the list, and the
  /// server answers with `consume-try` carrying everything they publish — now and
  /// on every later change. [_reconcile] does the rest.
  Future<void> subscribe(String srcId) async {
    if (srcId == _srcId || _subscribed.contains(srcId)) return;
    _subscribed.add(srcId);

    // Grant before asking. Consumption is reciprocal, and a colleague whose
    // client is already asking for us should not have to wait for a second
    // round trip because we granted them late.
    allow(srcId, allowed: true);

    await _requestPeer(srcId);
  }

  /// Tell whichever node carries [srcId] that we want their media.
  ///
  /// The one place that resolves a peer's node and asks for them, so recovery
  /// after a reconnect or a drained node is the same code path as the first
  /// subscription rather than a second, less-tested one.
  Future<void> _requestPeer(String srcId) async {
    if (!_subscribed.contains(srcId)) return;

    // Nothing in here may throw. It is called from a retry timer and from two
    // server pushes, none of which has a caller to catch anything — an escaping
    // error there is an unhandled asynchronous exception, which in this app
    // means a crash report for a colleague who has not finished connecting.
    try {
      final url = await _nodeUrlFor(srcId);
      if (url == null) {
        // Kept, not dropped. Forgetting them here is what left a colleague
        // silent until the cluster happened to change — `setSubscriptions`
        // diffs against the desired set, so a peer quietly removed from it is
        // never asked for again.
        _log('sfu: the router cannot place $srcId yet; will ask again');
        _awaitingAddr.add(srcId);
        _scheduleAddrRetry();
        return;
      }

      final node = await _nodeAt(url);
      await node.sendWithResponse('consume-request', {
        'srcId': srcId,
        'srcStreamId': _spaceId,
        'requested': true,
      });
      _awaitingAddr.remove(srcId);
      _log('sfu: subscribed to $srcId on $url');

      // The quality we asked for lives on the node too, so a peer we have just
      // (re)placed has to be told again.
      final layer = _spatial[srcId];
      if (layer != null && layer != 0) _setRemoteSpatial(srcId, layer);
      if (_priority.contains(srcId)) _sendPriority();
    } on Object catch (error) {
      _log('sfu: asking for $srcId failed: $error');
      _awaitingAddr.add(srcId);
      _scheduleAddrRetry();
    }
  }

  /// Keep asking the router about people it could not place.
  ///
  /// Ten seconds is slow enough to be free — one small frame per unplaced peer —
  /// and quick enough that somebody who walks up while their own client is still
  /// connecting is heard within a breath rather than never.
  void _scheduleAddrRetry() {
    if (_addrRetry != null || _stopped) return;
    _addrRetry = Timer.periodic(const Duration(seconds: 10), (timer) {
      _awaitingAddr.removeWhere((srcId) => !_subscribed.contains(srcId));
      if (_awaitingAddr.isEmpty || _stopped) {
        timer.cancel();
        _addrRetry = null;
        return;
      }
      for (final srcId in _awaitingAddr.toList()) {
        unawaited(_requestPeer(srcId));
      }
    });
  }

  Timer? _recvHealTimer;

  /// How long the watchdog waits before each heal attempt.
  ///
  /// Five seconds to start, doubling to a thirty-second cap. The first delay is
  /// a grace window: a single transient denial during normal churn is healed by
  /// the ordinary retry paths long before this fires, so only a cascade that is
  /// still silent after the grace triggers a rebuild.
  Duration _recvHealBackoff = const Duration(seconds: 5);

  /// Set while [_rebuildReceive] runs, so overlapping fires do not stack.
  bool _healing = false;

  /// Arm the watchdog that heals a receive path which never came up.
  ///
  /// Shaped like [_scheduleAddrRetry]: a self-cancelling one-shot with a
  /// reentrancy guard and a `_stopped` check. The lazy recv transport is only
  /// built on the first successful consume, so a join where the SFU denies every
  /// consume builds no transport and stays deaf for the whole call. This notices
  /// the "subscribed to peers but holding no consumers, and denials are why"
  /// state and rebuilds the receive path, retrying with growing backoff until a
  /// consumer finally lands (which cancels it from the success hook).
  void _scheduleRecvHeal() {
    if (_recvHealTimer != null || _stopped) return;
    _recvHealTimer = Timer(_recvHealBackoff, () async {
      _recvHealTimer = null;

      // Drop denials from peers we no longer subscribe to. unsubscribe() leaves
      // the denial behind, so without this a stale denial from a departed peer
      // reads as evidence that the current cluster is deaf, and could rebuild a
      // healthy in-flight receive path for the peer that replaced it.
      _consumeDenied.removeWhere((srcId) => !_subscribed.contains(srcId));

      // Re-evaluate against current state, not the state that armed us. If a
      // consumer has since been built, or we are no longer subscribed to
      // anyone, or the denials have cleared, there is nothing to heal — reset
      // the backoff and stand down.
      if (_stopped ||
          _subscribed.isEmpty ||
          _consumers.isNotEmpty ||
          _consumeDenied.isEmpty) {
        _recvHealBackoff = const Duration(seconds: 5);
        return;
      }

      await _rebuildReceive();

      // Grow the backoff and re-arm. The rebuild re-issues consumes but does not
      // guarantee one succeeds, so the watchdog keeps trying for the life of the
      // call; a successful consume is the only thing that cancels it.
      final next = _recvHealBackoff.inSeconds * 2;
      _recvHealBackoff = Duration(seconds: next > 30 ? 30 : next);
      _scheduleRecvHeal();
    });
  }

  /// Tear down and rebuild the receive path for every subscribed peer.
  ///
  /// The receive half of [_onNodeReconnected], applied across all peers rather
  /// than one node's, and deliberately touching nothing on the send side: the
  /// send transport and our producers are left alone, so a heal never interrupts
  /// outbound audio. Re-requesting each peer drives a fresh `consume-try`, which
  /// is what finally builds the recv transport that the deaf join never got.
  Future<void> _rebuildReceive() async {
    if (_healing) return;
    _healing = true;
    try {
      _log('sfu: no inbound media on a non-empty cluster; '
          'rebuilding the receive path');

      final peers = _subscribed.toList();

      // Forget the receive state for every peer, the same clears a reconnect
      // does for one node's peers.
      for (final srcId in peers) {
        _peerNode.remove(srcId);
        _announced.remove(srcId);
        for (final tag in SfuTag.values) {
          _closeConsumer(srcId, tag);
        }
      }

      // Close every recv transport. In the pure deaf case there are none, so
      // this is a no-op there; it also covers a recv transport that came up
      // poisoned and is itself the reason nothing flows.
      for (final transport in _recvTransports.values) {
        transport.close();
      }
      _recvTransports.clear();

      // Fail any consume still in flight rather than let it sit out its
      // twenty-second timeout — the transport it was waiting on is gone.
      for (final pending in _pendingConsumers.values) {
        if (!pending.isCompleted) {
          pending.completeError(const SfuException('receive path rebuilt'));
        }
      }

      // Re-assert the standing the SFU authorises consumes against before
      // asking again — cheap insurance that mirrors reconnect recovery.
      final node = _node;
      if (node != null) _replayAllow(node);
      _sendConversation();

      for (final srcId in peers) {
        unawaited(_requestPeer(srcId));
      }

      // Next watchdog fire re-evaluates against denials that arrive after the
      // rebuild, not the ones that triggered it.
      _consumeDenied.clear();
    } finally {
      _healing = false;
    }
  }

  /// Set by [stop], so timers and retries do not outlive the session.
  bool _stopped = false;

  /// Stop receiving [srcId], and stop the server sending.
  ///
  /// Both halves matter: closing the consumers alone leaves the SFU forwarding
  /// packets we drop on the floor, which is somebody's battery.
  Future<void> unsubscribe(String srcId) async {
    if (!_subscribed.remove(srcId)) return;
    _awaitingAddr.remove(srcId);
    _spatial.remove(srcId);

    final url = _peerNode.remove(srcId);
    final node = url == null ? null : _nodes[url];
    node?.emit('consume-request', {
      'srcId': srcId,
      'srcStreamId': _spaceId,
      'requested': false,
    });
    _router?.emit('unsubscribe', {'srcId': srcId, 'srcStreamId': _spaceId});
    allow(srcId, allowed: false);

    _announced.remove(srcId);
    for (final tag in SfuTag.values) {
      _closeConsumer(srcId, tag);
    }
    _publishRemotes();
  }

  /// The set of people we want to hear, reconciled in one call.
  ///
  /// Callers hand over the whole desired membership rather than deltas — the
  /// cluster arrives that way, and diffing here is the only place that can be
  /// sure a peer who vanished between two rosters is actually let go.
  Future<void> setSubscriptions(Set<String> srcIds) async {
    final wanted = srcIds.where((id) => id != _srcId).toSet();
    for (final gone in _subscribed.difference(wanted).toList()) {
      await unsubscribe(gone);
    }
    for (final added in wanted.difference(_subscribed).toList()) {
      await subscribe(added);
    }
  }

  void _onNotification(SfuNotification n) {
    if (!_notifications.isClosed) _notifications.add(n);

    switch (n.name) {
      // The full-state announcement of one peer's producers. Not a delta: an
      // empty map means they publish nothing, and treating it as "no news" is
      // what would leave a muted colleague apparently still talking.
      case 'consume-try':
        final srcId = n.data['srcId'];
        if (srcId is! String) return;
        final map = _map(n.data['producerIdMap']);
        _announced[srcId] = {
          for (final entry in map.entries)
            if (_tagOf(entry.key) case final tag?)
              if (entry.value is String) tag: entry.value as String,
        };
        unawaited(_reconcile(srcId));

      case 'consume-close':
        final srcId = n.data['srcId'];
        final tag = _tagOf(n.data['tag']);
        if (srcId is! String || tag == null) return;
        _announced[srcId]?.remove(tag);
        if (_closeConsumer(srcId, tag)) _publishRemotes();

      // Somebody muted. The consumer stays — this is a pause, not a departure —
      // and the UI needs to know so it can draw the crossed-out microphone
      // rather than a person who has simply gone silent.
      case 'producer-paused':
      case 'producer-resumed':
        final srcId = n.data['srcId'];
        final tag = _tagOf(n.data['tag']);
        if (srcId is! String || tag == null) return;
        final consumer = _consumers['$srcId|${tag.wire}'];
        if (consumer == null) return;
        if (n.name == 'producer-paused') {
          consumer.pause();
        } else {
          consumer.resume();
          // The server-side consumer is a separate switch from the producer,
          // and it was built paused. A `consume` answered `producerPaused: true`
          // — somebody who joined muted — never had `consume-resume` sent for
          // it, so flipping only our end here would leave the SFU holding the
          // packets: the colleague unmutes and stays silent on this phone.
          // Captured 2026-09-17: the desktop sends `consume-resume` at exactly
          // this point, and the ack for one already flowing is a harmless `[]`.
          final url = _peerNode[srcId];
          final node = url == null ? null : _nodes[url];
          node?.emit('consume-resume', {
            'srcId': srcId,
            'srcStreamId': _spaceId,
            'tag': tag.wire,
            'consumerId': consumer.id,
          });
        }
        _publishRemotes();

      // The server steering our *sending* quality. This is the other half of
      // declaring three encodings and activating one: without it we would encode
      // the bottom layer forever and a colleague looking at us full-screen would
      // never get more than a quarter-resolution picture.
      //
      // Transcribed from the client, which does exactly this and no more —
      // `_onProducerSpatialLayer({kind, layer})` → `setMaxSpatialLayer(layer)`,
      // debounced, errors logged rather than raised. mediasoup flips `active`
      // itself; there is no manual encoding surgery to do.
      case 'set-max-spatial-layer':
        if (n.data['kind'] != 'video') return;
        final layer = n.data['layer'];
        if (layer is! num) return;
        _wantedSpatialLayer = layer.toInt();
        // Debounced, as the client's own handler is. The server steers by
        // consumer demand, so this arrives in bursts when somebody opens a
        // full-screen tile — and every one of them is a renegotiation of what
        // the encoder is doing.
        _spatialDebounce?.cancel();
        _spatialDebounce = Timer(const Duration(milliseconds: 300), () {
          final wanted = _wantedSpatialLayer;
          if (wanted != null) unawaited(_setMaxSpatialLayer(wanted));
        });

      // The SFU has noticed two connections claiming to be us — this phone and
      // the desktop client, which share one `UserAccount` and therefore one
      // `srcId`.
      //
      // **The phone keeps the call.** That is a product decision: you picked up
      // your phone, so the phone is where you are. It is also the only half of
      // this we control — there is no "drop my other client" anywhere in the
      // measured method set, so the desktop stopping is something the *server*
      // does, not something we can ask for.
      //
      // Gather's own client answers `double-connected` with `reload()`, which
      // re-runs `_reconcileProducedTracks` and republishes. Two clients both
      // doing that would take turns knocking each other off forever, so this
      // deliberately does **not** reload: it holds what it has, and counts. If
      // the notice keeps arriving, the two ends are flapping, and at that point
      // the honest move is to stop and say so rather than keep fighting a fight
      // nobody can win from here.
      case 'double-connected':
        _doubleConnected++;
        _log('sfu: another client of ours is on this call '
            '(notice $_doubleConnected)');
        if (_doubleConnected >= _flappingAfter) {
          _log('sfu: standing down — the two clients are fighting');
          unawaited(_standDown());
        }

      // The node is being drained. Everything on it has to move, and the router
      // is the only thing that knows where to.
      case 'cordon-sfu':
      case 'reassign':
        unawaited(_reassign(n.data['sfuAddr']));

      // Declared in the bundle, never yet caught on the wire, so their payloads
      // are unknown. Logged rather than acted on: guessing at what `move-off`
      // means and reconnecting on it would risk a loop over a message we have
      // never seen, and the notification is passed on regardless for anyone
      // upstream who does know what to do with it.
      case 'move-off':
      case 'disable-video':
        _log('sfu: ${n.name} ${n.data}');

      // The SFU has refused a consume. On its own this is merely logged, but a
      // refusal is also the one signal that distinguishes a deaf join — where
      // every request comes back this way and no recv transport is ever built —
      // from a legitimately quiet room. Record who was refused and arm the
      // receive-path watchdog; it leaves normal churn alone and only rebuilds a
      // cluster that is still silent after the grace window.
      case 'consume-not-allowed':
        _log('sfu: ${n.name} ${n.data}');
        final srcId = n.data['srcId'];
        if (srcId is String) _consumeDenied.add(srcId);
        _scheduleRecvHeal();
    }
  }

  Timer? _spatialDebounce;
  int? _wantedSpatialLayer;

  /// How many `double-connected` notices we have taken before giving up.
  ///
  /// Three, because one is the expected cost of taking the call over — the
  /// desktop was here first and the server says so — and a third means the two
  /// ends are swapping it back and forth rather than settling.
  static const _flappingAfter = 3;

  int _doubleConnected = 0;

  /// How many times the SFU has told us another client of ours is here.
  ///
  /// Nonzero is normal during a takeover. [displaced] is the state that matters.
  int get doubleConnectedNotices => _doubleConnected;

  /// Whether we stopped publishing because the two clients could not settle.
  ///
  /// Sticky for the session. Retrying would restart the fight this exists to
  /// end, so the way back is a deliberate new session — the person quitting
  /// Gather on their Mac and tapping unmute again.
  bool get displaced => _displaced;
  bool _displaced = false;

  /// Give up publishing, keep receiving.
  ///
  /// Half a call is much better than none here: the desktop is carrying our
  /// microphone and camera, so the useful thing this phone can still do is show
  /// us the room. Tearing the whole session down would take that away too.
  Future<void> _standDown() async {
    if (_displaced) return;
    _displaced = true;
    for (final tag in _producers.keys.toList()) {
      await unpublish(tag);
    }
    _publishRemotes();
  }

  /// Fresh TURN credentials, and an ICE restart to use them.
  ///
  /// Transcribed from the client: `restart-ice` answers with `{iceParameters,
  /// iceServers}`, the servers go in first and only when non-empty, then the
  /// restart. There is no REST endpoint for this — rotation happens here or not
  /// at all, and when it does not, a call that outlives the credential loses its
  /// relay and goes silent for exactly the people who needed the relay.
  Future<void> refreshTurn() async {
    final node = _node;
    if (node == null) return;
    for (final transport in <ms.Transport>{
      ?_sendTransport,
      ..._recvTransports.values,
    }) {
      try {
        final reply = await node.sendWithResponse('restart-ice', {
          'transportId': transport.id,
          'iceTransportRequestOptions': <String, Object?>{},
        });
        final servers = _iceServers(reply['iceServers']);
        if (servers.isNotEmpty) transport.updateIceServers(servers);
        final ice = reply['iceParameters'];
        if (ice is Map) {
          transport.restartIce(ms.IceParameters.fromMap(_map(ice)));
        }
      } on Object catch (error) {
        _log('sfu: refreshing TURN on ${transport.id} failed: $error');
      }
    }
  }

  Future<void> _setMaxSpatialLayer(int layer) async {
    final producer = _producers[SfuTag.video];
    if (producer == null) return;
    try {
      await producer.setMaxSpatialLayer(layer);
      _log('sfu: sending video up to layer $layer');
    } on Object catch (error) {
      // Logged, not raised. A failed quality change is a worse picture; letting
      // it escape would take the call down over it.
      _log('sfu: could not set the max spatial layer: $error');
    }
  }

  /// One reconciliation per peer at a time.
  ///
  /// `consume-try` arrives whenever anything about a peer changes, and two of
  /// them in quick succession — muting and unmuting, or a camera coming on right
  /// after a join — would otherwise run two reconciliations concurrently. Both
  /// would look at the same empty slot, both would decide to consume, and the
  /// peer would end up with two consumers on one tag: doubled audio, and only one
  /// of them reachable to close. Serialising per peer keeps the check and the
  /// creation in the same turn.
  final Map<String, Future<void>> _reconciling = {};

  Future<void> _reconcile(String srcId) {
    final queued = (_reconciling[srcId] ?? Future<void>.value())
        .then((_) => _reconcileNow(srcId));
    _reconciling[srcId] = queued.then((_) {}, onError: (_) {});
    return queued;
  }

  /// Bring the consumers for one peer in line with what the server announced.
  ///
  /// Reconciliation rather than event handling, because `consume-try` is
  /// full-state: whatever is in the map should exist, whatever is not should not,
  /// and arriving at that from any starting point is the only behaviour that
  /// survives a missed message or a reconnect.
  Future<void> _reconcileNow(String srcId) async {
    final announced = _announced[srcId] ?? const <SfuTag, String>{};
    var changed = false;

    for (final tag in SfuTag.values) {
      final key = '$srcId|${tag.wire}';
      final want = announced[tag];
      final have = _consumers[key];

      if (want == null) {
        if (_closeConsumer(srcId, tag)) changed = true;
        continue;
      }
      // A producer id that changed under us is a *new* stream on the same tag —
      // they turned the camera off and on. The old consumer is pointed at
      // something that no longer exists.
      if (have != null && have.producerId != want) {
        _closeConsumer(srcId, tag);
        changed = true;
      } else if (have != null) {
        continue;
      }

      try {
        await _consume(srcId, tag);
        changed = true;
      } on Object catch (error) {
        _log('sfu: consuming ${tag.wire} from $srcId failed: $error');
      }
    }

    if (changed) _publishRemotes();
  }

  Future<void> _consume(String srcId, SfuTag tag) async {
    final device = _device;
    if (device == null) throw const SfuException('consume before start');

    final url = await _nodeUrlFor(srcId);
    if (url == null) throw SfuException('no node known for $srcId');
    final node = await _nodeAt(url);
    final transport = await _recvTransportOn(url);

    final reply = await node.sendWithResponse('consume', {
      'transportId': transport.id,
      'srcId': srcId,
      'srcStreamId': _spaceId,
      'tag': tag.wire,
      'rtpCapabilities': device.rtpCapabilities.toMap(),
    });

    final id = reply['id'];
    final producerId = reply['producerId'];
    if (id is! String || producerId is! String) {
      throw const SfuException('consume returned no consumer');
    }

    final key = '$srcId|${tag.wire}';
    final completer = Completer<ms.Consumer>();
    _pendingConsumers[key] = completer;

    try {
      transport.consume(
        id: id,
        producerId: producerId,
        peerId: srcId,
        kind: tag == SfuTag.audio
            ? RTCRtpMediaType.RTCRtpMediaTypeAudio
            : RTCRtpMediaType.RTCRtpMediaTypeVideo,
        rtpParameters: ms.RtpParameters.fromMap(
          _withRtcpDefaults(_map(reply['rtpParameters'])),
        ),
        appData: {'srcId': srcId, 'tag': tag.wire},
        accept: () {},
      );

      final consumer = await completer.future.timeout(
        const Duration(seconds: 20),
        onTimeout: () =>
            throw SfuException('consuming ${tag.wire} from $srcId timed out'),
      );
      _consumers[key] = consumer;

      // One consumer proves the receive path works, so the fault signal and the
      // watchdog it arms are stale now: clear the denials, cancel any pending
      // heal, and reset the backoff so a later cascade starts from the full
      // grace window rather than mid-climb.
      _consumeDenied.clear();
      _recvHealTimer?.cancel();
      _recvHealTimer = null;
      _recvHealBackoff = const Duration(seconds: 5);

      // Unusual, and easy to miss: the SFU wants telling that the consumer was
      // actually built. Measured going *back* to the server after its own ack.
      node.emit('consume-created', {
        'srcId': srcId,
        'srcStreamId': _spaceId,
        'tag': tag.wire,
        'consumerId': consumer.id,
      });

      // Consumers arrive paused. Nothing flows until this.
      if (reply['producerPaused'] != true) {
        node.emit('consume-resume', {
          'srcId': srcId,
          'srcStreamId': _spaceId,
          'tag': tag.wire,
          'consumerId': consumer.id,
        });
        consumer.resume();
      } else {
        // They are muted. Say so locally, so the tile draws the crossed-out
        // microphone from the first frame rather than after their next toggle;
        // the server side is left alone until `producer-resumed`, which is
        // where the desktop sends its `consume-resume` (captured 2026-09-17).
        consumer.pause();
      }
      _log('sfu: consuming ${tag.wire} from $srcId');
    } finally {
      _pendingConsumers.remove(key);
    }
  }

  final Map<String, Completer<ms.Consumer>> _pendingConsumers = {};

  /// Where the transport delivers a finished Consumer, matched by the `appData`
  /// we sent into `consume` — several can be in flight at once, so unlike the
  /// send side this cannot use a single slot.
  void _onConsumer(ms.Consumer consumer, [Object? accept]) {
    final srcId = consumer.appData['srcId'];
    final tag = consumer.appData['tag'];
    final pending = _pendingConsumers['$srcId|$tag'];
    if (pending != null && !pending.isCompleted) pending.complete(consumer);
    if (accept is Function) accept();
  }

  Future<ms.Transport> _recvTransportOn(String url) async {
    final existing = _recvTransports[url];
    if (existing != null) return existing;

    final device = _device;
    final node = await _nodeAt(url);
    if (device == null) throw const SfuException('consume before start');

    final reply = await node.sendWithResponse(
      'transport-create',
      {'direction': 'recv', 'iceTransportRequestOptions': _iceTransportOptions},
    );
    _checkTransportReply(reply, 'recv');

    final transport = device.createRecvTransport(
      id: reply['id'] as String,
      iceParameters: ms.IceParameters.fromMap(_map(reply['iceParameters'])),
      iceCandidates: [
        for (final c in (reply['iceCandidates'] as List? ?? const []))
          ms.IceCandidate.fromMap(_map(c)),
      ],
      dtlsParameters: ms.DtlsParameters.fromMap(_map(reply['dtlsParameters'])),
      iceServers: _iceServers(reply['iceServers']),
      iceTransportPolicy: reply['iceTransportPolicy'] == 'relay'
          ? RTCIceTransportPolicy.relay
          : RTCIceTransportPolicy.all,
      appData: _map(reply['appData']),
      consumerCallback: _onConsumer,
    );

    transport.on('connect', (Map data) async {
      try {
        await node.sendWithResponse('transport-connect', {
          'transportId': transport.id,
          'dtlsParameters': (data['dtlsParameters'] as ms.DtlsParameters).toMap(),
        });
        data['callback']();
      } on Object catch (error) {
        _log('sfu: recv transport-connect failed: $error');
        data['errback'](error);
        for (final pending in _pendingConsumers.values) {
          if (!pending.isCompleted) pending.completeError(error);
        }
      }
    });

    transport.on('connectionstatechange', (Map data) {
      _log('sfu: recv transport is ${data['connectionState']}');
    });

    // The same race as the send transport, and only luck has been hiding it:
    // `_consume` asks the server for the consumer first, and that round trip has
    // so far given `run()` enough time to finish. A faster node, or a reply
    // already in flight, and `consume()` would reach `_pc!` just as `produce()`
    // did — with the same silent twenty-second hang.
    await transport.handler.ready;

    return _recvTransports[url] = transport;
  }

  bool _closeConsumer(String srcId, SfuTag tag) {
    final consumer = _consumers.remove('$srcId|${tag.wire}');
    if (consumer == null) return false;
    consumer.close();
    return true;
  }

  /// The node we were on is being drained; find out where we go instead.
  Future<void> _reassign(Object? sfuAddr) async {
    final leaving =
        sfuAddr is String && sfuAddr.isNotEmpty ? sfuAddr : _sfuAddr;
    if (leaving == null) return;
    _log('sfu: $leaving is being drained');

    final moved = _forgetPeersOn(leaving);

    if (leaving == _sfuAddr) {
      await _moveOwnNode();
    } else {
      await _dropNode(leaving);
    }

    // Ask the router where each of them went. The answers can be several
    // different nodes, which the pool already models.
    for (final srcId in moved) {
      unawaited(_requestPeer(srcId));
    }
  }

  /// A node's socket dropped and came back. Everything it held died with it.
  ///
  /// Transports, producers and consumers all live on the far side of that
  /// socket, so a reconnection is a fresh, empty session wearing the same URL.
  /// Nothing here is optional: without the allow-list replay nobody may consume
  /// us, and without the republish we hold a connected socket that carries no
  /// media at all — the failure that reads as "it worked until I walked into a
  /// lift".
  Future<void> _onNodeReconnected(String url) async {
    if (_stopped) return;
    final node = _nodes[url];
    if (node == null) return;
    _log('sfu: $url came back; rebuilding what was on it');

    final moved = _forgetPeersOn(url);

    if (url == _sfuAddr) {
      _dropProducers();
      _sendTransport?.close();
      _sendTransport = null;
      _replayAllow(node);
      _sendConversation();
      _announceRepublish();
    }

    for (final srcId in moved) {
      unawaited(_requestPeer(srcId));
    }
  }

  /// Our own node is going away. Get another one and rebuild on it.
  Future<void> _moveOwnNode() async {
    if (_moving || _stopped) return;
    _moving = true;
    try {
      final old = _sfuAddr;
      _dropProducers();
      _sendTransport?.close();
      _sendTransport = null;
      _node = null;
      _sfuAddr = null;
      if (old != null) await _dropNode(old);

      await _assign();
      if (_stopped) {
        // Stopped while we were moving. The node `_assign` just opened is not in
        // the pool `stop()` emptied, so drop it here or it outlives the session.
        final orphan = _sfuAddr;
        if (orphan != null) await _dropNode(orphan);
        return;
      }
      _log('sfu: moved to $_sfuAddr');
      _announceRepublish();
    } on Object catch (error) {
      // Logged rather than thrown: this runs from a server push, so there is no
      // caller to catch it, and a session that cannot move is still a session
      // that can receive.
      _log('sfu: could not move to another node: $error');
    } finally {
      _moving = false;
    }
  }

  bool _moving = false;

  /// Forget everything we knew about the peers on [url], returning who they were.
  ///
  /// Their consumers point at a node that is going away, and their announced
  /// `producerIdMap` describes producers that will not exist on the next one. The
  /// fresh `consume-try` that follows re-requesting is what rebuilds both, which
  /// is why this clears rather than tries to carry anything across.
  List<String> _forgetPeersOn(String url) {
    final moved = [
      for (final entry in _peerNode.entries)
        if (entry.value == url) entry.key,
    ];
    for (final srcId in moved) {
      _peerNode.remove(srcId);
      _announced.remove(srcId);
      for (final tag in SfuTag.values) {
        _closeConsumer(srcId, tag);
      }
    }
    _recvTransports.remove(url)?.close();
    if (moved.isNotEmpty) _publishRemotes();
    return moved;
  }

  Future<void> _dropNode(String url) async {
    await _nodeSubscriptions.remove(url)?.cancel();
    await _nodeHealth.remove(url)?.cancel();
    _nodeDown.remove(url);
    _recvTransports.remove(url)?.close();
    final node = _nodes.remove(url);
    await node?.dispose();
  }

  /// Close our producers locally, without telling the server.
  ///
  /// For when the server has already lost them. `produce-close` would either be
  /// addressed to a session that no longer exists or — worse, on a socket that
  /// has just come back — be a claim about a producer we are one moment away
  /// from creating.
  void _dropProducers() {
    for (final producer in _producers.values) {
      producer.close();
    }
    _producers.clear();
  }

  void _announceRepublish() {
    if (!_republish.isClosed) _republish.add(null);
  }

  List<RemoteMedia> _remoteList() {
    final byPeer = <String, Map<SfuTag, ms.Consumer>>{};
    for (final entry in _consumers.entries) {
      final parts = entry.key.split('|');
      final tag = _tagOf(parts.last);
      if (tag == null) continue;
      (byPeer[parts.first] ??= {})[tag] = entry.value;
    }
    return [
      for (final entry in byPeer.entries)
        RemoteMedia(
          srcId: entry.key,
          streams: {
            for (final t in entry.value.entries) t.key: t.value.stream,
          },
          paused: {
            for (final t in entry.value.entries)
              if (t.value.paused) t.key,
          },
        ),
    ];
  }

  void _publishRemotes() {
    if (!_remotes.isClosed) _remotes.add(_remoteList());
  }

  Future<void> stop() async {
    _stopped = true;
    _turnTimer?.cancel();
    _turnTimer = null;
    _addrRetry?.cancel();
    _addrRetry = null;
    _recvHealTimer?.cancel();
    _recvHealTimer = null;
    _consumeDenied.clear();
    _recvHealBackoff = const Duration(seconds: 5);
    _healing = false;
    _spatialDebounce?.cancel();
    _spatialDebounce = null;
    _awaitingAddr.clear();
    _spatial.clear();
    _priority = const [];
    for (final tag in _producers.keys.toList()) {
      await unpublish(tag);
    }
    for (final consumer in _consumers.values) {
      consumer.close();
    }
    _consumers.clear();
    _pendingConsumers.clear();
    _reconciling.clear();
    _announced.clear();
    _subscribed.clear();
    _peerNode.clear();

    _sendTransport?.close();
    _sendTransport = null;
    for (final transport in _recvTransports.values) {
      transport.close();
    }
    _recvTransports.clear();
    _device = null;

    // Cancel before disposing, or a node's closing notifications arrive at a
    // handler that reaches for state we have just cleared — and its status
    // stream would read the close as a reconnection and start rebuilding.
    for (final subscription in _nodeSubscriptions.values) {
      await subscription.cancel();
    }
    _nodeSubscriptions.clear();
    for (final subscription in _nodeHealth.values) {
      await subscription.cancel();
    }
    _nodeHealth.clear();
    _nodeDown.clear();
    for (final node in _nodes.values.toList()) {
      await node.dispose();
    }
    _nodes.clear();
    await _routerSub?.cancel();
    _routerSub = null;
    await _router?.dispose();
    _node = null;
    _router = null;
    _sfuAddr = null;
    _publishRemotes();
  }

  /// Closes everything and releases the streams. The session cannot be restarted.
  Future<void> dispose() async {
    await stop();
    await _remotes.close();
    await _notifications.close();
    await _republish.close();
  }

  SfuSignalling _open(String url, String? sessionId) =>
      _openSignalling?.call(url, sessionId) ??
      SfuSignalling(
        auth: _auth,
        url: url,
        spaceId: _spaceId,
        sessionId: sessionId,
        log: _log,
      );
}

/// The three simulcast layers, transcribed from Gather's own client.
///
/// **Only `r0` is active**, and that is the point. The plan's worry — that three
/// concurrent software VP8 encodes would cook a phone, VP8 having no hardware
/// encoder on Apple silicon — was aimed at the wrong thing: declaring a layer
/// costs nothing, *encoding* one costs, and Gather encodes one at a time. The
/// server flips the others on through `set-max-spatial-layer` when a consumer
/// actually asks for more resolution, and on a phone it mostly never does.
///
/// Declaring all three anyway is what lets somebody on a desktop, looking at you
/// full-screen, get a better picture without a renegotiation. Declaring one would
/// have capped every viewer at a quarter-resolution thumbnail forever.
/// What the desktop asks for when it creates a transport, captured 2026-09-17.
///
/// The schema probe the same day showed the server accepts `{}` and a missing
/// field just as happily, so this is not what stood between the phone and a
/// call. It is sent anyway because `trafficAccelerator` names the ICE path the
/// reply is built for — the reply's `appData` echoes it — and a phone on a
/// mobile network wants the same candidates the desktop gets, not a variant
/// nobody has tested.
const _iceTransportOptions = <String, Object?>{
  'forceTurn': false,
  'trafficAccelerator': 'GlobalAccelerator',
};

/// One encoding for the microphone, as the desktop declares it: DTX on and a
/// 24 kbit/s ceiling. `codecOptions` sets the same DTX in the SDP; this is the
/// half that reaches the `produce` request's `encodings`, which the desktop's
/// carries and an empty list would leave to the plugin's defaults.
/// **A microphone gets no encodings at all, and that is not an oversight.**
///
/// `flutter_webrtc`'s `mapToEncoding` builds every `RTCRtpEncodingParameters`
/// with `scaleResolutionDownBy = 1.0` and `numTemporalLayers = 1` already set,
/// unconditionally, whatever the track's kind is. libwebrtc rejects both of
/// those on an *audio* transceiver, so handing `produce()` any non-empty
/// `encodings` for a microphone makes `addTransceiver` throw — and mediasoup's
/// `FlexQueue` swallows that exception, printing it under `kDebugMode` only and
/// calling an error callback `produce()` never passes. Nothing reaches the wire,
/// nothing reaches the log, and [publish] times out twenty seconds later with no
/// cause attached. The mute button simply never worked.
///
/// This was measured, not reasoned about: with an audio encoding present the
/// trace shows `transport-create` acked and then silence — no `transport-connect`
/// and no `produce` — because the throw lands before `_setupTransport`
/// (`build/call-capture/media2.log`, 2026-09-17).
///
/// Opus DTX and in-band FEC are not lost by this. They are negotiated through
/// `codecOptions` at the [publish] call site, which is where they belong: they
/// are `fmtp` parameters in the SDP, not properties of a sender encoding.
///
/// The desktop's own audio `produce` does carry `{ssrc, active, dtx, maxBitrate}`,
/// but those are what the *browser* reports from a sender it already built. They
/// are not an input Gather requires, and copying them into a request was the
/// mistake this comment exists to prevent repeating.
///
/// Video is different and must keep its encodings: simulcast is the whole point
/// there, and `scaleResolutionDownBy` is legal on a video transceiver. Note the
/// `scalabilityMode` on every entry below is also load-bearing —
/// `UnifiedPlanHandler.send` reads `encodings.first.scalabilityMode!`, a bare
/// null assertion, for any non-empty list.
final _videoEncodings = [
  ms.RtpEncodingParameters(
    rid: 'r0',
    active: true,
    scaleResolutionDownBy: 4,
    maxBitrate: 120000,
    maxFramerate: 18,
    scalabilityMode: 'L1T2',
  ),
  ms.RtpEncodingParameters(
    rid: 'r1',
    active: false,
    scaleResolutionDownBy: 2,
    maxBitrate: 350000,
    maxFramerate: 24,
    scalabilityMode: 'L1T2',
  ),
  ms.RtpEncodingParameters(
    rid: 'r2',
    active: false,
    scaleResolutionDownBy: 1,
    maxBitrate: 1500000,
    maxFramerate: 24,
    scalabilityMode: 'L1T2',
  ),
];

Map<String, dynamic> _map(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};

/// Fills in the RTCP fields Gather leaves out, because the client cannot survive
/// their absence.
///
/// `RtcpParameters.fromMap` passes `map['reducedSize']` straight into a
/// **non-nullable** `bool` parameter — one that already declares a default of
/// `true`. So a missing key is not defaulted, it is a `TypeError`:
/// `type 'Null' is not a subtype of type 'bool'`. Gather answers `consume` with
/// `rtcp: {"cname": "…"}` and nothing else, so every single consume threw before
/// a track was ever built. That is the whole reason nobody could be heard or
/// seen on the phone, and it looked like a media bug rather than a parsing one
/// because the failure arrived as a type error from inside a library
/// (captured 2026-09-17, `build/call-capture/media.log`).
///
/// The values are not a guess. mediasoup's own comment on the field is
/// "mediasoup assumes reducedSize to always be true", and RTCP-mux is what the
/// SFU negotiates for every transport it hands out. These are the values the
/// library would have used had it honoured its own defaults.
Map<String, dynamic> _withRtcpDefaults(Map<String, dynamic> rtpParameters) {
  final rtcp = _map(rtpParameters['rtcp']);
  rtcp['reducedSize'] ??= true;
  rtcp['mux'] ??= true;
  return {...rtpParameters, 'rtcp': rtcp};
}

/// Gather sends TURN credentials with the transport, and refreshes them through
/// `restart-ice` rather than through any REST route.
///
/// `urls` is a string or a list of them per the WebRTC spec, and Gather has been
/// seen sending both shapes, so both are accepted rather than assumed.
List<RTCIceServer> _iceServers(Object? value) {
  if (value is! List) return const [];
  final out = <RTCIceServer>[];
  for (final raw in value) {
    final server = _map(raw);
    final urls = server['urls'];
    out.add(RTCIceServer(
      urls: switch (urls) {
        String s => [s],
        List l => l.whereType<String>().toList(),
        _ => const <String>[],
      },
      username: server['username'] as String? ?? '',
      credential: server['credential'],
      credentialType: RTCIceCredentialType.password,
    ));
  }
  return out;
}
