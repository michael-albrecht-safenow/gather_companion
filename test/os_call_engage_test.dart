/// When the OS is told a call is running, and when it is not.
///
/// The media plane connects on proximity, but CallKit must hear about a call only
/// on deliberate engagement — unmuting, or opening the faces — or the Recents log
/// fills up as the phone drifts past conversations. These assert that seam: that
/// listening alone is silent, that the two doors report exactly one call, and that
/// the OS's own End and mute buttons come back through to the app.
library;

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gather_client/gather_client.dart';
import 'package:gather_companion/src/app_state.dart';
import 'package:gather_companion/src/media/os_call.dart';

import 'fake_call.dart';

/// An [OsCall] that records what it was told and can play the OS's side back —
/// the End and mute buttons arriving from the lock screen.
class RecordingOsCall implements OsCall {
  final List<String> started = [];
  int endedCount = 0;
  final List<bool> muted = [];

  final _end = StreamController<void>.broadcast();
  final _mute = StreamController<bool>.broadcast();

  /// Pretend the person tapped End / the mute toggle in the system call UI.
  void fireEnd() => _end.add(null);
  void fireMute(bool value) => _mute.add(value);

  @override
  Future<void> reportStarted({required String handle}) async =>
      started.add(handle);

  @override
  Future<void> reportEnded() async => endedCount++;

  @override
  Future<void> reportMuted(bool value) async => muted.add(value);

  @override
  Stream<void> get onEndRequested => _end.stream;

  @override
  Stream<bool> get onMuteRequested => _mute.stream;

  @override
  Future<void> dispose() async {
    await _end.close();
    await _mute.close();
  }
}

void main() {
  RosterRow row(String id, {String? cluster, String? account}) => RosterRow(
        id: id,
        name: id,
        clusterIdKnown: true,
        clusterId: cluster,
        userAccountId: account,
        connected: true,
      );

  ({AppState state, FakeCall call, RecordingOsCall os}) wired() {
    final call = FakeCall();
    final os = RecordingOsCall();
    final state = AppState(osCall: os)..debugAttachCall(call);
    addTearDown(state.dispose);
    return (state: state, call: call, os: os);
  }

  test('drifting into a conversation does not tell the OS there is a call', () {
    fakeAsync((clock) {
      final (:state, :call, :os) = wired();

      // The passive path: a cluster arrives and the call subscribes, with nobody
      // pressing anything.
      state.debugApplyRoster(Roster(selfId: 'me', rows: [
        row('me', cluster: 'c1', account: 'acct-me'),
        row('them', cluster: 'c1', account: 'acct-them'),
      ]));
      clock.elapse(const Duration(milliseconds: 1700));
      clock.flushMicrotasks();

      // The media plane heard about it; the OS did not.
      expect(call.told, isNotEmpty);
      expect(os.started, isEmpty);
      clock.elapse(const Duration(seconds: 5));
    });
  });

  test('unmuting reports one call, and toggling mute does not report more', () async {
    final (:state, :call, :os) = wired();

    await state.setMicOn(true);
    expect(os.started, hasLength(1));
    expect(os.muted, [false]);

    // Mute and unmute again. Still one call — a muted call is a call — and the
    // mute state is reflected each time.
    await state.setMicOn(false);
    await state.setMicOn(true);
    expect(os.started, hasLength(1));
    expect(os.muted, [false, true, false]);
  });

  test('opening the faces is the other door, and reports the same one call', () async {
    final (:state, :call, :os) = wired();

    // What openCallScreen calls.
    state.engageCall();
    expect(os.started, hasLength(1));

    // And unmuting afterwards does not report a second.
    await state.setMicOn(true);
    expect(os.started, hasLength(1));
  });

  test('opening the faces syncs the initial mute into the system call UI', () async {
    final (:state, :call, :os) = wired();

    // The faces door engages with the mic still off, so CallKit must hear the
    // call is muted — otherwise its default unmuted call lies and swallows the
    // first system mute toggle as a no-op.
    state.engageFromScreen();
    expect(os.started, hasLength(1));
    expect(os.muted, [true]);

    // Still the one call, and no second start when unmuting afterwards.
    await state.setMicOn(true);
    expect(os.started, hasLength(1));
  });

  test('leaving ends the OS call exactly once', () async {
    final (:state, :call, :os) = wired();

    await state.setMicOn(true);
    await state.leaveCall();
    expect(os.endedCount, 1);

    // Leaving again says nothing: there is no call to end.
    await state.leaveCall();
    expect(os.endedCount, 1);
  });

  test("the OS's End button tears the app call down", () async {
    final (:state, :call, :os) = wired();

    await state.setMicOn(true);
    os.fireEnd();
    await pumpEventQueue();

    expect(os.endedCount, 1);
  });

  test("the OS's mute button mutes for real and reflects it back", () async {
    final (:state, :call, :os) = wired();

    await state.setMicOn(true); // muted: [false]
    os.fireMute(true);
    await pumpEventQueue();

    // muteRequested(true) → setMicOn(false) → reportMuted(true).
    expect(os.muted, [false, true]);
  });
}
