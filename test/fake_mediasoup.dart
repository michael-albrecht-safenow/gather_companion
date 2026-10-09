/// mediasoup, with no platform channel behind it.
///
/// `Device.load()` asks an `RTCPeerConnection` what the platform can encode, and
/// `transport.produce()` builds a real sender — neither exists under
/// `flutter test`. Everything [SfuSession] is actually *about*, though, is
/// ordinary logic: which node somebody is on, what to do when a socket comes
/// back, whether a `consume-try` means build a consumer or close one. This is
/// what lets that half be tested.
///
/// These fake the library's classes with `implements` plus [noSuchMethod] rather
/// than reimplementing them. That is deliberate: the compiler checks the members
/// we *do* override against the real signatures, so a library upgrade that
/// changes one of them breaks here rather than on a device.
library;

import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:gather_companion/src/media/mediasoup_ice.dart';
import 'package:mediasfu_mediasoup_client/mediasfu_mediasoup_client.dart' as ms;

/// A [ms.Device] that loads instantly and hands back [FakeTransport]s.
class FakeDevice implements ms.Device {
  bool _loaded = false;

  /// The capabilities we were loaded with, so a test can assert we passed on
  /// what the SFU actually said.
  ms.RtpCapabilities? loadedWith;

  final List<FakeTransport> transports = [];

  /// Hand out transports whose handler has not finished `run()` yet.
  ///
  /// The real `Transport` is constructed around a fire-and-forget
  /// `handler.run()`, so it is briefly live with no peer connection. Set this
  /// before the call under test to reproduce that window.
  bool holdNewHandlers = false;

  /// Every `createSendTransport`/`createRecvTransport` call, in order.
  final List<({String direction, String id, List<RTCIceServer> iceServers})>
      created = [];

  @override
  bool get loaded => _loaded;

  @override
  Future<void> load({required ms.RtpCapabilities routerRtpCapabilities}) async {
    loadedWith = routerRtpCapabilities;
    _loaded = true;
  }

  @override
  ms.RtpCapabilities get rtpCapabilities => ms.RtpCapabilities.fromMap(const {
        'codecs': <Map<String, dynamic>>[],
        'headerExtensions': <Map<String, dynamic>>[],
      });

  @override
  ms.Transport createSendTransport({
    required String id,
    required ms.IceParameters iceParameters,
    required List<ms.IceCandidate> iceCandidates,
    required ms.DtlsParameters dtlsParameters,
    ms.SctpParameters? sctpParameters,
    List<RTCIceServer> iceServers = const [],
    RTCIceTransportPolicy? iceTransportPolicy,
    Map<String, dynamic> additionalSettings = const {},
    Map<String, dynamic> proprietaryConstraints = const {},
    Map<String, dynamic> appData = const {},
    Function? producerCallback,
    Function? dataProducerCallback,
  }) {
    created.add((direction: 'send', id: id, iceServers: iceServers));
    final transport = FakeTransport(id: id, producerCallback: producerCallback);
    if (holdNewHandlers) transport.handler.hold();
    transports.add(transport);
    return transport;
  }

  @override
  ms.Transport createRecvTransport({
    required String id,
    required ms.IceParameters iceParameters,
    required List<ms.IceCandidate> iceCandidates,
    required ms.DtlsParameters dtlsParameters,
    ms.SctpParameters? sctpParameters,
    List<RTCIceServer> iceServers = const [],
    RTCIceTransportPolicy? iceTransportPolicy,
    Map<String, dynamic> additionalSettings = const {},
    Map<String, dynamic> proprietaryConstraints = const {},
    Map<String, dynamic> appData = const {},
    Function? consumerCallback,
    Function? dataConsumerCallback,
  }) {
    created.add((direction: 'recv', id: id, iceServers: iceServers));
    final transport = FakeTransport(id: id, consumerCallback: consumerCallback);
    transports.add(transport);
    return transport;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// A handler that can be caught mid-`run()`.
///
/// `HandlerInterface.ready` exists because the real one is built by a
/// fire-and-forget `void ... async run()`: the transport is handed out before
/// its `RTCPeerConnection` exists. [hold] reproduces exactly that window, so a
/// test can assert that nothing is produced inside it.
class FakeHandler implements ms.HandlerInterface {
  Completer<void>? _held;

  /// Withholds readiness until [release] is called.
  void hold() => _held ??= Completer<void>();

  void release() {
    final held = _held;
    _held = null;
    if (held != null && !held.isCompleted) held.complete();
  }

  @override
  Future<void> get ready => _held?.future ?? Future<void>.value();

  @override
  void markReady() => release();

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class FakeTransport implements ms.Transport {
  FakeTransport({required this.id, this.producerCallback, this.consumerCallback});

  @override
  final String id;

  @override
  final Function? producerCallback;

  @override
  final Function? consumerCallback;

  @override
  bool closed = false;
  int iceRestarts = 0;
  List<RTCIceServer> lastIceServers = const [];

  /// The handler, and specifically whether it admits to being ready.
  ///
  /// The real `Transport` starts `handler.run()` without waiting for it, so for
  /// a moment it exists with no peer connection behind it and anything that
  /// produces throws a null check nobody sees. A fake that is *always* ready
  /// cannot catch that, so this one can be told to wait — see
  /// [FakeHandler.hold].
  @override
  final FakeHandler handler = FakeHandler();

  /// The handlers [SfuSession] registered, so a test can fire `connect` and
  /// `produce` the way a real transport would.
  final Map<String, Function> handlers = {};

  final List<FakeProducer> producers = [];
  final List<FakeConsumer> consumers = [];

  /// What was asked for, per tag, so a test can assert on the encodings.
  ///
  /// The real handler reads `encodings.first.scalabilityMode!` whenever the list
  /// is non-empty, so "which encodings did we hand it" is a question with a
  /// twenty-second hang behind it. Recording them is what lets that be a test
  /// rather than a device.
  final Map<String, List<ms.RtpEncodingParameters>> encodingsByTag = {};

  @override
  void on(String event, Function handler) => handlers[event] = handler;

  @override
  void produce({
    required MediaStreamTrack track,
    required MediaStream stream,
    List<ms.RtpEncodingParameters> encodings = const [],
    ms.ProducerCodecOptions? codecOptions,
    ms.RtpCodecCapability? codec,
    bool stopTracks = true,
    bool disableTrackOnPause = true,
    bool zeroRtpOnPause = false,
    Map<String, dynamic> appData = const {},
    required String source,
  }) {
    // The real transport asks the server for an id before it builds anything,
    // through the `produce` handler, and only then calls the callback. Doing the
    // same here is what makes the session's `produce` message get sent at all.
    final handler = handlers['produce'];
    final tag = (appData['tag'] as String?) ?? source;
    encodingsByTag[tag] = encodings;
    Future<void>(() async {
      var id = 'producer-$tag';
      if (handler != null) {
        final completer = _Completer();
        await handler({
          'kind': track.kind,
          'rtpParameters': ms.RtpParameters.fromMap(const {
            'codecs': <Map<String, dynamic>>[],
            'headerExtensions': <Map<String, dynamic>>[],
            'encodings': <Map<String, dynamic>>[],
            'rtcp': {'cname': 'fake', 'mux': true, 'reducedSize': true},
          }),
          'appData': appData,
          'callback': completer.callback,
          'errback': completer.errback,
        });
        // The real transport awaits this and lets the error out of the task —
        // no producer is built and the callback never fires. Anything friendlier
        // here would hide the twenty-second hang that behaviour used to cause.
        final Object? chosen;
        try {
          chosen = await completer.future;
        } on Object {
          return;
        }
        if (chosen is String) id = chosen;
      }
      final producer = FakeProducer(id: id, tag: tag, encodings: encodings);
      producers.add(producer);
      producerCallback?.call(producer);
    });
  }

  @override
  void consume({
    required String id,
    required String producerId,
    required String peerId,
    required RTCRtpMediaType kind,
    required ms.RtpParameters rtpParameters,
    Map<String, dynamic> appData = const {},
    Function? accept,
  }) {
    final consumer = FakeConsumer(
      id: id,
      producerId: producerId,
      appData: appData,
    );
    consumers.add(consumer);
    consumerCallback?.call(consumer, accept);
  }

  @override
  void updateIceServers(List<RTCIceServer> iceServers) =>
      lastIceServers = iceServers;

  @override
  void restartIce(ms.IceParameters iceParameters) => iceRestarts++;

  @override
  Future<void> close() async => closed = true;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class FakeProducer implements ms.Producer {
  FakeProducer({required this.id, required this.tag, this.encodings = const []});

  @override
  final String id;

  final String tag;
  final List<ms.RtpEncodingParameters> encodings;

  /// What the microphone is doing, for the voice-activity poll to read.
  ///
  /// Null means the stats carry no `media-source` row at all, which is what a
  /// platform that will not answer looks like from [SfuSession.microphoneLevel].
  double? level;

  /// Shaped like the real thing rather than like what the caller wants: a whole
  /// peer connection's worth of rows, of which exactly one is the microphone.
  /// Reading the wrong row here is how a silent microphone once looked healthy —
  /// see `SfuSession._reportOutboundRtp` — so the decoys are the point.
  @override
  Future<List<StatsReport>> getStats() async => [
        StatsReport('t', 'transport', 0, {'bytesSent': 99999}),
        StatsReport('o', 'outbound-rtp', 0, {'kind': 'video', 'bytesSent': 4242}),
        StatsReport('v', 'media-source', 0, {'kind': 'video', 'framesPerSecond': 24}),
        if (level != null)
          StatsReport('a', 'media-source', 0, {'kind': 'audio', 'audioLevel': level}),
      ];

  @override
  bool closed = false;
  bool isPaused = false;

  /// Reproduce the `createOffer: Error (null)` a producer on a never-connected
  /// send transport throws when closed — the real mediasoup `@close` runs
  /// `createOffer` on a peer connection that never finished negotiating. Set by
  /// a test to prove the session's guarded close swallows it.
  bool throwOnClose = false;

  /// Every layer the server steered us to, so the debounce can be asserted on.
  final List<int> maxSpatialLayers = [];

  @override
  void pause() => isPaused = true;

  @override
  void resume() => isPaused = false;

  @override
  void close() {
    if (throwOnClose) {
      throw StateError('Unable to RTCPeerConnection::createOffer: Error (null)');
    }
    closed = true;
  }

  @override
  Future<void> setMaxSpatialLayer(int spatialLayer) async =>
      maxSpatialLayers.add(spatialLayer);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class FakeConsumer implements ms.Consumer {
  FakeConsumer({
    required this.id,
    required this.producerId,
    required this.appData,
  });

  @override
  final String id;

  @override
  final String producerId;

  @override
  final Map<String, dynamic> appData;

  @override
  final MediaStream stream = FakeStream();

  @override
  bool closed = false;

  bool _paused = false;

  @override
  bool get paused => _paused;

  @override
  void pause() => _paused = true;

  @override
  void resume() => _paused = false;

  @override
  Future<void> close() async => closed = true;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// A stream with one track of each kind and nothing native underneath.
class FakeStream implements MediaStream {
  FakeStream({this.audio = true, this.video = true});

  final bool audio;
  final bool video;

  @override
  String get id => 'fake-stream';

  @override
  List<MediaStreamTrack> getAudioTracks() =>
      audio ? [FakeTrack('audio')] : const [];

  @override
  List<MediaStreamTrack> getVideoTracks() =>
      video ? [FakeTrack('video')] : const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class FakeTrack implements MediaStreamTrack {
  FakeTrack(this.kind);

  @override
  final String kind;

  @override
  String get id => 'fake-$kind';

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// The `callback`/`errback` pair mediasoup hands its listeners.
class _Completer {
  final _completer = Completer<Object?>();

  Future<Object?> get future => _completer.future;

  void callback([Object? value]) {
    if (!_completer.isCompleted) _completer.complete(value);
  }

  void errback([Object? error]) {
    if (!_completer.isCompleted) {
      _completer.completeError(error ?? StateError('produce refused'));
    }
  }
}
