/// A [Call] that records what it was told and reaches no hardware.
///
/// Shared between the tests that assert *when* the app speaks to the media plane
/// — the cluster wiring in `call_cluster_test.dart` and the quality requests in
/// `call_screen_test.dart`. Both care about the same thing: that the right thing
/// is said, once, at the right moment.
library;

import 'dart:async';

import 'package:gather_companion/src/media/call.dart';

class FakeCall implements Call {
  /// Who we asked to hear, in the order asked.
  final List<Set<String>> told = [];

  /// Who we permitted to see us.
  final List<Set<String>> shownTo = [];

  /// The conversation ids we named, nulls included.
  final List<String?> conversations = [];

  /// Who is on screen, and how big.
  final List<({List<String> srcIds, VideoQuality quality})> watching = [];

  final _states = StreamController<CallState>.broadcast();
  final _speaking = StreamController<bool>.broadcast();

  /// Drives the speaking stream, so a test can start and stop a sentence without
  /// a microphone or a stats poll anywhere near it.
  void speak(bool speaking) {
    _isSpeaking = speaking;
    _speaking.add(speaking);
  }

  bool _isSpeaking = false;

  @override
  Stream<bool> get speaking => _speaking.stream;

  @override
  bool get isSpeaking => _isSpeaking;

  @override
  Future<void> setVisibleTo(Set<String> srcIds) async => shownTo.add(srcIds);

  @override
  CallState get state => const CallState();

  @override
  Stream<CallState> get states => _states.stream;

  @override
  Future<void> setListeningTo(Set<String> srcIds) async => told.add(srcIds);

  @override
  Future<void> setConversation(String? clusterId) async =>
      conversations.add(clusterId);

  @override
  Future<void> setWatching(
    List<String> srcIds, {
    required VideoQuality quality,
  }) async =>
      watching.add((srcIds: srcIds, quality: quality));

  /// The mic toggles we were asked for, in order.
  final List<bool> micCalls = [];

  @override
  Future<String?> setMicOn(bool on) async {
    micCalls.add(on);
    return null;
  }

  @override
  Future<String?> setCameraOn(bool on) async => null;

  /// The screen-share toggles we were asked for, in order.
  final List<bool> screenCalls = [];

  @override
  Future<String?> setScreenShareOn(bool on) async {
    screenCalls.add(on);
    return null;
  }

  /// The speaker toggles we were asked for, in order.
  final List<bool> speakerCalls = [];

  @override
  Future<String?> setSpeakerOn(bool on) async {
    speakerCalls.add(on);
    return null;
  }

  @override
  Future<void> switchCamera() async {}

  @override
  Future<void> hangUp() async {}

  /// How many times a media rebuild was forced on us (issue #41 self-heal).
  int rebuilds = 0;

  @override
  Future<void> rebuild() async => rebuilds++;

  /// How many times the "Pull session over to this app" button fired (issue #67).
  int pulls = 0;

  @override
  Future<String?> pullSessionOver() async {
    pulls++;
    return null;
  }

  @override
  Future<void> dispose() async {
    await _states.close();
    await _speaking.close();
  }
}
