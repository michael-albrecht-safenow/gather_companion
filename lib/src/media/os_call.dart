/// The line between "there is a call" and "the OS knows there is a call".
///
/// A [Call] is Gather's own idea of being audible in a room — a microphone, a
/// camera and an SFU. This is the *other* party's idea of it: CallKit on iOS,
/// and one day a `ConnectionService` / `CallStyle` notification on Android. Tell
/// the OS a call has started and three things come for free — the lock screen
/// keeps the app alive and audible, the system draws its own call UI, and the
/// call lands in the phone's Recents — none of which Gather can do from Dart.
///
/// ## Why this is a seam of its own
///
/// The same discipline as [MediaEngine] and [Call], one layer out: nothing above
/// this interface imports a platform channel or `dart:io`, so `AppState` stays
/// testable on a machine with no telephony stack. Production injects a real
/// implementation; tests inject [NoopOsCall] and assert on what it was told.
///
/// ## Why "engagement", not "proximity"
///
/// This is a presence app: the media plane connects the moment you drift into a
/// conversation (`Call.setListeningTo` with a non-empty set), with nobody
/// pressing anything. Reporting *that* to CallKit would spam the Recents log as
/// the phone moved in a pocket. So an OS call is reported only on deliberate
/// engagement — unmuting, or opening the faces — and never from passive
/// listening. `AppState` owns that decision; this interface only carries it.
library;

import 'dart:io';

import 'os_call_callkit.dart';

/// The OS's handle on the call.
///
/// Every method is safe to call in any order and more than once: `AppState`
/// reports a start on the first of two doors and an end on teardown, and the
/// guarding lives here rather than being the caller's problem to get exactly
/// right.
abstract class OsCall {
  /// Tells the OS a call has started, creating the system call and its Recents
  /// entry. Idempotent — reporting again while one is already live is a no-op,
  /// so the two ways to engage (unmute, open the faces) report one call, not two.
  ///
  /// [handle] is the name the system UI shows — the people in the conversation.
  Future<void> reportStarted({required String handle});

  /// Tells the OS the call has ended. A no-op when nothing was reported.
  Future<void> reportEnded();

  /// Reflects our mute state into the system call UI, so the lock-screen mute
  /// button shows the truth. A no-op when no call is live.
  Future<void> reportMuted(bool muted);

  /// Fires when the OS asks us to end the call — the End button on the lock
  /// screen or the system call sheet. The app must then tear the call down, the
  /// same way an in-app Leave does.
  Stream<void> get onEndRequested;

  /// Fires when the OS asks us to toggle mute from its own UI, carrying the
  /// muted state it wants. The app answers by muting or unmuting for real.
  Stream<bool> get onMuteRequested;

  Future<void> dispose();
}

/// The real thing for this platform, or [NoopOsCall] where there is nothing to
/// talk to.
///
/// iOS gets CallKit. Android gets the no-op for now — the `ConnectionService` /
/// foreground-service path is a follow-up, and the no-op keeps the app building
/// and the engage/disengage logic exercised until it lands. A test build gets
/// the no-op too, by injecting one directly.
OsCall defaultOsCall({void Function(String)? log}) =>
    Platform.isIOS ? IosCallKit(log: log) : NoopOsCall();

/// Says yes to everything and reports nothing. The Android and test
/// implementation, and the shape every method of [OsCall] degrades to when there
/// is no OS call to keep.
class NoopOsCall implements OsCall {
  @override
  Future<void> reportStarted({required String handle}) async {}

  @override
  Future<void> reportEnded() async {}

  @override
  Future<void> reportMuted(bool muted) async {}

  @override
  Stream<void> get onEndRequested => const Stream<void>.empty();

  @override
  Stream<bool> get onMuteRequested => const Stream<bool>.empty();

  @override
  Future<void> dispose() async {}
}
