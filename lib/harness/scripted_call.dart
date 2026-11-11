/// A [Call] a script drives, reaching no hardware and no SFU.
///
/// The `lib/`-side sibling of `test/fake_call.dart`: same shape, but it holds a
/// mutable [CallState] a running app can push to ([emit]) and a speaking flag a
/// scenario can flip ([speak]). Every method that would touch a microphone, a
/// camera or a socket is a recorded no-op, so taps on the live call screen —
/// mute, speaker, switch camera, the spotlight's `setWatching` — resolve instead
/// of throwing.
///
/// [sampleFlow] answers a synthetic flow reading built from the current
/// [CallState] — every participant's announced tracks as consumers whose
/// counters climb with the clock, paused when their mute says so — marked
/// `source: "scripted"` so it is never mistaken for the wire. [flowFaults]
/// makes one stream look broken on purpose, and [flowScript] replaces the
/// synthesis outright, so the debug drive's `media.*` verdicts can be checked in
/// the simulator without two real endpoints.
library;

import 'dart:async';

import '../src/media/call.dart';
import '../src/media/media_flow.dart';

/// How a scripted stream misbehaves, for [ScriptedCall.flowFaults].
enum ScriptedFlowFault {
  /// Counters stop: the stream reads `stalled` once the window passes.
  stall,

  /// Packets keep coming with no energy in them (audio only): `silent`.
  silence,

  /// Expected but no consumer: `missing`.
  missing,

  /// The stats call fails: `not_measured`.
  unmeasured,
}

class ScriptedCall implements Call {
  ScriptedCall({DateTime Function()? now}) : _now = now ?? DateTime.now;

  final DateTime Function() _now;
  final _states = StreamController<CallState>.broadcast();
  final _speaking = StreamController<bool>.broadcast();

  CallState _state = const CallState();
  bool _isSpeaking = false;

  /// What the call screen's buttons asked for, kept so a harness can show it.
  final List<bool> micCalls = [];
  final List<bool> cameraCalls = [];
  final List<bool> screenCalls = [];
  final List<bool> speakerCalls = [];
  final List<({List<String> srcIds, VideoQuality quality})> watching = [];

  /// Pushes a fresh call state out to anybody listening and makes it current.
  void emit(CallState state) {
    _state = state;
    _states.add(state);
  }

  /// Drives the speaking stream — my own voice, measured nowhere here.
  void speak(bool speaking) {
    _isSpeaking = speaking;
    _speaking.add(speaking);
  }

  @override
  CallState get state => _state;

  @override
  Stream<CallState> get states => _states.stream;

  @override
  Stream<bool> get speaking => _speaking.stream;

  @override
  bool get isSpeaking => _isSpeaking;

  @override
  Future<String?> setMicOn(bool on) async {
    micCalls.add(on);
    return null;
  }

  @override
  Future<String?> setCameraOn(bool on) async {
    cameraCalls.add(on);
    return null;
  }

  @override
  Future<String?> setScreenShareOn(bool on) async {
    screenCalls.add(on);
    return null;
  }

  @override
  Future<String?> setSpeakerOn(bool on) async {
    speakerCalls.add(on);
    return null;
  }

  @override
  Future<void> switchCamera() async {}

  @override
  Future<void> setVisibleTo(Set<String> srcIds) async {}

  @override
  Future<void> setListeningTo(Set<String> srcIds) async {}

  @override
  Future<void> setConversation(String? clusterId) async {}

  @override
  Future<void> setWatching(
    List<String> srcIds, {
    required VideoQuality quality,
  }) async =>
      watching.add((srcIds: srcIds, quality: quality));

  @override
  Future<void> hangUp() async {}

  @override
  Future<void> rebuild() async {}

  @override
  Future<String?> pullSessionOver() async => null;

  /// Replaces the synthesised reading entirely when set.
  MediaFlowSample Function()? flowScript;

  /// Faults by stream key — `in:<srcId>|<tag>` or `out:<tag>`.
  final Map<String, ScriptedFlowFault> flowFaults = {};

  /// Running counters per stream key, and when they were last advanced.
  final Map<String, _Synth> _synth = {};

  @override
  Future<MediaFlowSample> sampleFlow() async {
    final script = flowScript;
    if (script != null) return script();
    final at = _now();
    final inbound = <InboundFlow>[];
    final outbound = <OutboundFlow>[];
    final expected = <ExpectedStream>[];
    final errors = <FlowError>[];
    final live = <String>{};

    for (final p in _state.participants) {
      final tags = {
        if (p.hasAudio) 'audio': p.audioPaused,
        if (p.hasVideo) 'video': p.videoPaused,
        if (p.sharingScreen) 'screen': false,
      };
      for (final MapEntry(key: tag, value: paused) in tags.entries) {
        final key = 'in:${p.srcId}|$tag';
        expected.add(ExpectedStream(p.srcId, tag));
        final fault = flowFaults[key];
        if (fault == ScriptedFlowFault.missing) continue;
        live.add(key);
        final synth = _advance(key, tag, at, flowing: !paused && fault != ScriptedFlowFault.stall, energy: fault != ScriptedFlowFault.silence);
        if (fault == ScriptedFlowFault.unmeasured) errors.add(FlowError(key, 'getStats timed out (scripted)'));
        inbound.add(InboundFlow(
          srcId: p.srcId,
          tag: tag,
          paused: paused,
          consumerId: 'scripted-$key',
          producerId: 'scripted-producer-$key',
          rowFound: true,
          counters: fault == ScriptedFlowFault.unmeasured
              ? null
              : tag == 'audio'
                  ? InboundCounters(
                      packetsReceived: synth.packets.round(),
                      bytesReceived: synth.bytes.round(),
                      packetsLost: 0,
                      jitter: 0.004,
                      totalAudioEnergy: synth.energy,
                      concealedSamples: 0,
                      totalSamplesReceived: (synth.packets * 960).round(),
                    )
                  : InboundCounters(
                      packetsReceived: synth.packets.round(),
                      bytesReceived: synth.bytes.round(),
                      packetsLost: 0,
                      framesReceived: synth.frames.round(),
                      framesDecoded: synth.frames.round(),
                      framesDropped: 0,
                      frameWidth: 640,
                      frameHeight: 360,
                      framesPerSecond: synth.flowing ? 24 : 0,
                      freezeCount: 0,
                      totalFreezesDuration: 0,
                    ),
        ));
      }
    }

    final mine = {
      if (_state.publishingAudio) 'audio': !_state.micOn,
      if (_state.publishingVideo) 'video': !_state.cameraOn,
      if (_state.publishingScreen) 'screen': false,
    };
    for (final MapEntry(key: tag, value: paused) in mine.entries) {
      final key = 'out:$tag';
      live.add(key);
      final fault = flowFaults[key];
      final synth = _advance(key, tag, at, flowing: !paused && fault != ScriptedFlowFault.stall, energy: fault != ScriptedFlowFault.silence);
      if (fault == ScriptedFlowFault.unmeasured) errors.add(FlowError(key, 'getStats timed out (scripted)'));
      outbound.add(OutboundFlow(
        tag: tag,
        paused: paused,
        producerId: 'scripted-$key',
        rowFound: true,
        counters: fault == ScriptedFlowFault.unmeasured
            ? null
            : OutboundCounters(
                packetsSent: synth.packets.round(),
                bytesSent: synth.bytes.round(),
                audioLevel: tag == 'audio' ? (synth.flowing && fault != ScriptedFlowFault.silence ? 0.2 : 0) : null,
                totalAudioEnergy: tag == 'audio' ? synth.energy : null,
                framesEncoded: tag == 'audio' ? null : synth.frames.round(),
                frameWidth: tag == 'audio' ? null : 640,
                frameHeight: tag == 'audio' ? null : 360,
                qualityLimitationReason: tag == 'audio' ? null : 'none',
              ),
      ));
    }
    _synth.removeWhere((key, _) => !live.contains(key));

    return MediaFlowSample(
      at: at,
      source: 'scripted',
      inbound: inbound,
      outbound: outbound,
      transports: [
        if (outbound.isNotEmpty)
          const TransportFlow(direction: 'send', id: 'scripted-send', node: 'scripted', connectionState: 'connected', iceState: 'connected', dtlsState: 'connected', selectedPairState: 'succeeded', currentRoundTripTime: 0.02),
        if (inbound.isNotEmpty)
          const TransportFlow(direction: 'recv', id: 'scripted-recv', node: 'scripted', connectionState: 'connected', iceState: 'connected', dtlsState: 'connected', selectedPairState: 'succeeded', currentRoundTripTime: 0.02),
      ],
      expected: expected,
      errors: errors,
    );
  }

  _Synth _advance(String key, String tag, DateTime at, {required bool flowing, required bool energy}) {
    final synth = _synth.putIfAbsent(key, () => _Synth(at));
    final seconds = at.difference(synth.at).inMicroseconds / 1e6;
    synth
      ..at = at
      ..flowing = flowing;
    if (flowing && seconds > 0) {
      final audio = tag == 'audio';
      // Roughly Opus at 32 kbps and VP8 at 500 kbps, 24 fps.
      synth
        ..packets += seconds * (audio ? 50 : 90)
        ..bytes += seconds * (audio ? 4000 : 62500)
        ..frames += audio ? 0 : seconds * 24
        ..energy += (audio && energy) ? seconds * 0.01 : 0;
    }
    return synth;
  }

  @override
  Future<void> dispose() async {
    await _states.close();
    await _speaking.close();
  }
}

/// One scripted stream's running counters.
class _Synth {
  _Synth(this.at);

  DateTime at;
  bool flowing = true;
  double packets = 0;
  double bytes = 0;
  double frames = 0;
  double energy = 0;
}
