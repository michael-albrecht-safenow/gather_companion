/// The network-change watcher: a wifi<->cellular handoff leaves the game and SFU
/// sockets half-open — healthy-looking, carrying nothing — and the deaf-timer takes
/// 45s to notice, which is 45s of no roster and so no call. [AppState] turns the
/// handoff itself into the reconnect trigger. These assert that bridge: the right
/// changes force a resync and raise the reconnecting badge, and the wrong ones do
/// not churn the socket.
library;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gather_client/gather_client.dart';
import 'package:gather_companion/harness/fake_collector.dart';
import 'package:gather_companion/src/app_state.dart';

import 'fake_call.dart';

void main() {
  /// An [AppState] with a fake collector attached and a clock a test can turn, so
  /// the resync cooldown is deterministic rather than wall-time.
  ({AppState state, FakeCollector collector, void Function(Duration) tick}) wired() {
    var clock = DateTime(2026);
    final collector = FakeCollector();
    final state = AppState(now: () => clock)..debugAttachCollector(collector);
    addTearDown(state.dispose);
    return (state: state, collector: collector, tick: (d) => clock = clock.add(d));
  }

  /// The same, with a call attached — for asserting the media session is rebuilt
  /// (its token re-minted) on a transport change, not just the game socket resynced.
  ({AppState state, FakeCollector collector, FakeCall call, void Function(Duration) tick})
      wiredInCall() {
    var clock = DateTime(2026);
    final collector = FakeCollector();
    final call = FakeCall();
    final state = AppState(now: () => clock)
      ..debugAttachCollector(collector)
      ..debugAttachCall(call);
    addTearDown(state.dispose);
    return (
      state: state,
      collector: collector,
      call: call,
      tick: (d) => clock = clock.add(d),
    );
  }

  test('a transport change forces a resync and raises the reconnecting badge', () {
    final (:state, :collector, :tick) = wired();

    // The first network sighting establishes the baseline.
    state.debugNoteConnectivity([ConnectivityResult.wifi]);
    tick(const Duration(seconds: 6)); // past the coalescing cooldown
    final base = collector.resyncs;

    state.debugNoteConnectivity([ConnectivityResult.mobile]);
    expect(collector.resyncs, base + 1, reason: 'the handoff should reconnect');
    expect(state.link.isReconnecting, isTrue, reason: 'the badge should show at once');
  });

  test('a transport change rebuilds the media session, to re-mint the SFU token',
      () {
    // The SFU socket sleeps through the handoff on a connection it still believes
    // is alive, so its token goes stale and republishes are refused bad-auth until
    // a restart (#57). The handoff must rebuild the media plane, not only resync
    // the game socket.
    final (:state, :collector, :call, :tick) = wiredInCall();

    state.debugNoteConnectivity([ConnectivityResult.wifi]);
    tick(const Duration(seconds: 6));
    final base = call.rebuilds;

    state.debugNoteConnectivity([ConnectivityResult.mobile]);
    expect(call.rebuilds, base + 1,
        reason: 'the handoff must rebuild the media session for a fresh token');
  });

  test('an unchanged transport and going offline never rebuild the session', () {
    final (:state, :collector, :call, :tick) = wiredInCall();

    state.debugNoteConnectivity([ConnectivityResult.mobile]);
    tick(const Duration(seconds: 6));
    final base = call.rebuilds;

    state.debugNoteConnectivity([ConnectivityResult.mobile]); // unchanged
    expect(call.rebuilds, base, reason: 'no change, no rebuild');

    state.debugNoteConnectivity(const []); // flight mode
    expect(call.rebuilds, base,
        reason: 'offline is a dead end — nothing to rebuild onto yet');
  });

  test('the same transport does not reconnect, and offline flags at once', () {
    final (:state, :collector, :tick) = wired();

    state.debugNoteConnectivity([ConnectivityResult.mobile]);
    tick(const Duration(seconds: 6));
    final base = collector.resyncs;

    state.debugNoteConnectivity([ConnectivityResult.mobile]); // unchanged
    expect(collector.resyncs, base, reason: 'no change, no reconnect');

    state.debugNoteConnectivity(const []); // lost the network entirely
    expect(collector.resyncs, base, reason: 'nothing to reconnect to yet');
    expect(state.link.isOffline, isTrue,
        reason: 'offline must show at once, not wait for the 45s deaf-timer');
    expect(state.link.isReconnecting, isFalse,
        reason: 'offline is its own word — no spinner when there is no network');
  });

  test('offline wins over a stale collector report until a transport returns', () {
    final (:state, :collector, :tick) = wired();

    state.debugNoteConnectivity([ConnectivityResult.wifi]);
    tick(const Duration(seconds: 6));
    state.debugNoteConnectivity(const []); // flight mode
    expect(state.link.isOffline, isTrue);

    // The deaf-timer finally trips ~45s later and the collector reports unhealthy — the
    // word stays "offline", not "reconnecting": there is still no network.
    state.debugNoteCollectorStatus(const CollectorStatus(healthy: false, detail: 'deaf'));
    expect(state.link.isOffline, isTrue, reason: 'still no transport');

    // A stale "healthy" off the open-but-deaf socket must not flip the badge to live.
    state.debugNoteCollectorStatus(const CollectorStatus(healthy: true, detail: 'stale'));
    expect(state.link.isOffline, isTrue, reason: 'the socket is deaf; the radio is down');

    // A transport returns: reconnect now, and a healthy report lands us back live.
    state.debugNoteConnectivity([ConnectivityResult.wifi]);
    expect(state.link.isReconnecting, isTrue, reason: 'network back — now a real reconnect');
    state.debugNoteCollectorStatus(const CollectorStatus(healthy: true, detail: 'ok'));
    expect(state.link.isLive, isTrue);
  });

  test('a radio that flaps offline within the cooldown still reconnects on return', () {
    final (:state, :collector, :tick) = wired();

    state.debugNoteConnectivity([ConnectivityResult.wifi]);
    tick(const Duration(seconds: 6));

    // A transport change resyncs and arms the 5s cooldown.
    state.debugNoteConnectivity([ConnectivityResult.mobile]);
    final afterChange = collector.resyncs;

    // The radio drops entirely and comes back inside that 5s window.
    tick(const Duration(seconds: 2));
    state.debugNoteConnectivity(const []);
    tick(const Duration(seconds: 2));
    state.debugNoteConnectivity([ConnectivityResult.wifi]);

    expect(collector.resyncs, afterChange + 1,
        reason: 'the comeback must reconnect now, not wait out the deaf-timer');
    expect(state.link.isReconnecting, isTrue);
  });

  test('the burst of events from one handoff coalesces into a single resync', () {
    final (:state, :collector, :tick) = wired();

    state.debugNoteConnectivity([ConnectivityResult.wifi]);
    tick(const Duration(seconds: 6));
    final base = collector.resyncs;

    // connectivity_plus emits several events as an interface settles.
    state.debugNoteConnectivity([ConnectivityResult.mobile]);
    state.debugNoteConnectivity([ConnectivityResult.wifi]);
    state.debugNoteConnectivity([ConnectivityResult.mobile]);
    expect(collector.resyncs, base + 1, reason: 'only the first in the window counts');

    // Once the window passes, a fresh change reconnects again.
    tick(const Duration(seconds: 6));
    state.debugNoteConnectivity([ConnectivityResult.wifi]);
    expect(collector.resyncs, base + 2);
  });

  test('offline suspends the collector and a returning transport resumes it', () {
    // Issue #8: the fix is not just raising the badge — it is telling the collector
    // to stop trying. Offline, the collector must be suspended so it makes no
    // reconnect attempts into the void; a returning transport resumes it.
    final (:state, :collector, :tick) = wired();

    state.debugNoteConnectivity([ConnectivityResult.wifi]);
    tick(const Duration(seconds: 6));
    collector.reachablesSet.clear(); // drop the baseline online signal

    state.debugNoteConnectivity(const []); // flight mode
    expect(collector.reachablesSet, [false],
        reason: 'offline must suspend the collector, not just flag the badge');

    state.debugNoteConnectivity([ConnectivityResult.wifi]); // transport back
    expect(collector.reachablesSet, [false, true],
        reason: 'a returning transport resumes reconnect attempts');
  });
}
