/// A [Call] a script drives, reaching no hardware and no SFU.
///
/// The `lib/`-side sibling of `test/fake_call.dart`: same shape, but it holds a
/// mutable [CallState] a running app can push to ([emit]) and a speaking flag a
/// scenario can flip ([speak]). Every method that would touch a microphone, a
/// camera or a socket is a recorded no-op, so taps on the live call screen —
/// mute, speaker, switch camera, the spotlight's `setWatching` — resolve instead
/// of throwing.
library;

import 'dart:async';

import '../src/media/call.dart';

class ScriptedCall implements Call {
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

  @override
  Future<void> dispose() async {
    await _states.close();
    await _speaking.close();
  }
}
