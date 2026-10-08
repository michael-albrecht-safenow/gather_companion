/// Who the call listens to, and when it is told.
///
/// The join signal is Gather's own `clusterId` rather than a reimplementation of
/// its twelve-stage proximity pipeline — the server already computes the bubble
/// and publishes it, so this asserts the bridge between that and the media
/// plane, including the identity swap the two planes force.
library;

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gather_client/gather_client.dart';
import 'package:gather_companion/harness/fake_collector.dart';
import 'package:gather_companion/src/app_state.dart';

import 'fake_call.dart';

void main() {
  /// A fake clock, not a real one.
  ///
  /// These tests are entirely about *when* something is delivered, and the first
  /// draft spent eight seconds of wall time sleeping through the debounces. That
  /// is slow, and worse, it made the whole suite likelier to flake under parallel
  /// load — a timing test that steals a worker for eight seconds is a timing test
  /// that breaks somebody else's. `fakeAsync` moves the clock instead.
  void withClock(void Function(FakeAsync clock) body) =>
      fakeAsync((clock) {
        body(clock);
        // Drain anything still pending, so a stray timer cannot outlive the test
        // and fire into a disposed AppState.
        clock.elapse(const Duration(seconds: 5));
      });

  /// Past the join debounce.
  void settle(FakeAsync clock) {
    clock.elapse(const Duration(milliseconds: 1700));
    clock.flushMicrotasks();
  }

  RosterRow row(String id, {String? cluster, String? account}) => RosterRow(
        id: id,
        name: id,
        clusterIdKnown: true,
        clusterId: cluster,
        userAccountId: account,
        connected: true,
      );

  /// A placed row, so [Roster.nearby] can judge who is still in range — the
  /// relation that tells a transient cluster flap from a walk-away.
  RosterRow placed(String id,
          {String? cluster, String? account, num x = 0, num y = 0}) =>
      RosterRow(
        id: id,
        name: id,
        x: x,
        y: y,
        floorId: 'f1',
        clusterIdKnown: true,
        clusterId: cluster,
        userAccountId: account,
        connected: true,
      );

  /// An [AppState] with a call attached and nothing else running.
  ({AppState state, FakeCall call}) wired() {
    final call = FakeCall();
    final state = AppState()..debugAttachCall(call);
    addTearDown(state.dispose);
    return (state: state, call: call);
  }

  test('the cluster becomes the subscription, in UserAccount ids', () {
    withClock((clock) {
      final (:state, :call) = wired();

      state.debugApplyRoster(Roster(selfId: 'me', rows: [
        row('me', cluster: 'c1', account: 'acct-me'),
        row('them', cluster: 'c1', account: 'acct-them'),
        row('elsewhere', cluster: 'c2', account: 'acct-elsewhere'),
      ]));
      settle(clock);

      // Their `UserAccount.id`, not their `SpaceUser.id` — the media plane is
      // keyed on the other one, and asking the router about a SpaceUser returns
      // a stream that does not exist, silently.
      expect(call.told, [
        {'acct-them'}
      ]);
    });
  });

  test('somebody with no UserAccount id yet is skipped, not guessed at', () {
    withClock((clock) {
      final (:state, :call) = wired();

      state.debugApplyRoster(Roster(selfId: 'me', rows: [
        row('me', cluster: 'c1', account: 'acct-me'),
        row('them', cluster: 'c1'),
      ]));
      settle(clock);

      // Nothing at all, rather than an empty subscription: the desired set never
      // changed from the empty one we started with, so there is nothing to say.
      // They are picked up on whichever later roster carries their account id.
      expect(call.told, isEmpty);
    });
  });

  test('a cluster that has not changed is not re-sent', () {
    withClock((clock) {
      final (:state, :call) = wired();

      final roster = Roster(selfId: 'me', rows: [
        row('me', cluster: 'c1', account: 'acct-me'),
        row('them', cluster: 'c1', account: 'acct-them'),
      ]);
      state.debugApplyRoster(roster);
      settle(clock);
      // A second roster carrying the same conversation. Positions change four
      // times a second; the subscription must not.
      state.debugApplyRoster(roster);
      settle(clock);

      expect(call.told, hasLength(1));
    });
  });

  test('walking past a group does not open a call with them', () {
    withClock((clock) {
      final (:state, :call) = wired();

      // In and straight out again, faster than the join debounce.
      state.debugApplyRoster(Roster(selfId: 'me', rows: [
        row('me', cluster: 'c1', account: 'acct-me'),
        row('them', cluster: 'c1', account: 'acct-them'),
      ]));
      clock.elapse(const Duration(milliseconds: 200));
      state.debugApplyRoster(Roster(selfId: 'me', rows: [
        row('me', account: 'acct-me'),
        row('them', cluster: 'c1', account: 'acct-them'),
      ]));
      settle(clock);

      // One delivery, and it is the empty one. The transient membership never
      // reached the SFU, which is the whole point of the debounce.
      expect(call.told, [<String>{}]);
    });
  });

  test('leaving is delivered faster than joining', () {
    withClock((clock) {
      final (:state, :call) = wired();

      state.debugApplyRoster(Roster(selfId: 'me', rows: [
        row('me', cluster: 'c1', account: 'acct-me'),
        row('them', cluster: 'c1', account: 'acct-them'),
      ]));
      settle(clock);
      expect(call.told, hasLength(1));

      state.debugApplyRoster(Roster(selfId: 'me', rows: [
        row('me', account: 'acct-me'),
        row('them', cluster: 'c1', account: 'acct-them'),
      ]));
      // Shorter than the join debounce and longer than the leave one. Still
      // hearing a conversation you have walked away from is the worse failure,
      // so the way out is quicker than the way in.
      clock.elapse(const Duration(milliseconds: 900));
      clock.flushMicrotasks();

      expect(call.told, [
        {'acct-them'},
        <String>{},
      ]);
    });
  });

  test('everybody in range is allowed to see us, not just the conversation', () {
    withClock((clock) {
      final (:state, :call) = wired();

      state.debugApplyRoster(Roster(selfId: 'me', rows: const [
        RosterRow(
            id: 'me', x: 0, y: 0, floorId: 'f1', connected: true,
            userAccountId: 'acct-me', clusterIdKnown: true, clusterId: 'c1'),
        RosterRow(
            id: 'talking', x: 1, y: 0, floorId: 'f1', connected: true,
            userAccountId: 'acct-talking', clusterIdKnown: true, clusterId: 'c1'),
        RosterRow(
            id: 'watching', x: 5, y: 0, floorId: 'f1', connected: true,
            userAccountId: 'acct-watching', clusterIdKnown: true),
      ]));
      settle(clock);

      // The bug: `consume-allow` is what permits anybody to consume us, so
      // allowing only the conversation meant the person standing beside you
      // could never see your camera over your avatar.
      expect(call.shownTo.last, {'acct-talking', 'acct-watching'});
      // And it is still only the conversation we ask to *hear*.
      expect(call.told.last, {'acct-talking'});
    });
  });

  test('the conversation is named as soon as we are in one', () {
    withClock((clock) {
      final (:state, :call) = wired();

      state.debugApplyRoster(Roster(selfId: 'me', rows: [
        row('me', cluster: 'c1', account: 'acct-me'),
        row('them', cluster: 'c1', account: 'acct-them'),
      ]));
      clock.flushMicrotasks();

      // `set-player-conversation-metadata` is in the measured method table and
      // the desktop client sends it on every change. Undebounced: it is a name,
      // not a subscription, and nothing is negotiated by saying it.
      expect(call.conversations, ['c1']);
      // And the subscription is still waiting on its debounce.
      expect(call.told, isEmpty);
    });
  });

  test('standing alone is a conversation id worth saying too', () {
    withClock((clock) {
      final (:state, :call) = wired();

      state.debugApplyRoster(Roster(selfId: 'me', rows: [
        row('me', cluster: 'c1', account: 'acct-me'),
        row('them', cluster: 'c1', account: 'acct-them'),
      ]));
      settle(clock);
      state.debugApplyRoster(Roster(selfId: 'me', rows: [
        row('me', account: 'acct-me'),
      ]));
      settle(clock);

      // Null, not silence: leaving a conversation is a change of state the SFU
      // is entitled to hear about, and omitting it would leave us named as a
      // member of a bubble we have walked out of.
      expect(call.conversations, ['c1', null]);
    });
  });

  test('a conversation that has not changed is not re-named', () {
    withClock((clock) {
      final (:state, :call) = wired();

      final roster = Roster(selfId: 'me', rows: [
        row('me', cluster: 'c1', account: 'acct-me'),
        row('them', cluster: 'c1', account: 'acct-them'),
      ]);
      state.debugApplyRoster(roster);
      settle(clock);
      state.debugApplyRoster(roster);
      settle(clock);

      expect(call.conversations, hasLength(1));
    });
  });

  test('the allow list is sent without waiting for a debounce', () {
    withClock((clock) {
      final (:state, :call) = wired();

      state.debugApplyRoster(Roster(selfId: 'me', rows: const [
        RosterRow(
            id: 'me', x: 0, y: 0, floorId: 'f1', connected: true,
            userAccountId: 'acct-me'),
        RosterRow(
            id: 'near', x: 2, y: 0, floorId: 'f1', connected: true,
            userAccountId: 'acct-near'),
      ]));
      clock.flushMicrotasks();

      // A permission costs nothing to send and being late with it shows as an
      // empty circle over your head, so this one does not wait like the
      // subscription does.
      expect(call.shownTo, [
        {'acct-near'}
      ]);
      expect(call.told, isEmpty);
    });
  });

  // ---- issue #22: the cluster flaps to (none) while walking -------------------

  test('a transient clusterId drop does not tear the call down', () {
    withClock((clock) {
      final (:state, :call) = wired();

      // Standing together: the conversation forms and both are in range.
      state.debugApplyRoster(Roster(selfId: 'me', rows: [
        placed('me', cluster: 'c1', account: 'acct-me'),
        placed('them', cluster: 'c1', account: 'acct-them', x: 1),
      ]));
      settle(clock);
      expect(state.inHuddle, isTrue);
      expect(call.conversations, ['c1']);
      expect(call.told, [
        {'acct-them'}
      ]);

      // Our own `clusterId` flickers to null while walking, but we are still
      // standing next to them — the #22 flap. The banner, the conversation name
      // and the subscription must all ride through it.
      state.debugApplyRoster(Roster(selfId: 'me', rows: [
        placed('me', account: 'acct-me'),
        placed('them', cluster: 'c1', account: 'acct-them', x: 1),
      ]));
      settle(clock);

      expect(state.inHuddle, isTrue);
      expect(state.huddleRows.map((r) => r.id), ['them']);
      expect(call.conversations, ['c1']); // not cleared to null
      expect(call.told, [
        {'acct-them'}
      ]); // not dropped to empty
    });
  });

  test('walking away from the cluster still drops the call', () {
    withClock((clock) {
      final (:state, :call) = wired();

      state.debugApplyRoster(Roster(selfId: 'me', rows: [
        placed('me', cluster: 'c1', account: 'acct-me'),
        placed('them', cluster: 'c1', account: 'acct-them', x: 1),
      ]));
      settle(clock);
      expect(state.inHuddle, isTrue);

      // We leave: our `clusterId` is null *and* we are now far from them, so no
      // prior member is in range and the release is immediate.
      state.debugApplyRoster(Roster(selfId: 'me', rows: [
        placed('me', account: 'acct-me', x: 100),
        placed('them', cluster: 'c1', account: 'acct-them', x: 1),
      ]));
      settle(clock);

      expect(state.inHuddle, isFalse);
      expect(state.huddleRows, isEmpty);
      expect(call.conversations, ['c1', null]);
      expect(call.told, [
        {'acct-them'},
        <String>{},
      ]);
    });
  });

  test('a positioned walk-through is not held into a call', () {
    withClock((clock) {
      final (:state, :call) = wired();

      // Placed this time — close enough that `nearby` would call them in range,
      // the condition that holds a flap. In and straight out again, faster than
      // the join debounce, so the brief membership never became a subscription.
      state.debugApplyRoster(Roster(selfId: 'me', rows: [
        placed('me', cluster: 'c1', account: 'acct-me'),
        placed('them', cluster: 'c1', account: 'acct-them', x: 1),
      ]));
      clock.elapse(const Duration(milliseconds: 200));
      state.debugApplyRoster(Roster(selfId: 'me', rows: [
        placed('me', account: 'acct-me'),
        placed('them', cluster: 'c1', account: 'acct-them', x: 1),
      ]));
      settle(clock);

      // Proximity alone would hold this — they are still in range — but nothing
      // was ever applied, so there is no call to protect. Released at once, and
      // the subscription never opened: one empty delivery and no membership.
      expect(state.inHuddle, isFalse);
      expect(call.told, [<String>{}]);
    });
  });

  test('tapping Leave drops the call even while the peers are still in range',
      () {
    withClock((clock) {
      final (:state, :call) = wired();
      state.debugAttachCollector(FakeCollector());

      state.debugApplyRoster(Roster(selfId: 'me', rows: [
        placed('me', cluster: 'c1', account: 'acct-me'),
        placed('them', cluster: 'c1', account: 'acct-them', x: 1),
      ]));
      settle(clock);
      expect(state.inHuddle, isTrue);

      // We ask to leave but do not move. Gather drops us from the cluster while
      // we are still standing beside them, which to the proximity test looks
      // exactly like a #22 flap — but a Leave is a decision, not a flicker, so
      // the hold is bypassed and the release is immediate.
      state.leaveHuddle();
      clock.flushMicrotasks();
      state.debugApplyRoster(Roster(selfId: 'me', rows: [
        placed('me', account: 'acct-me'),
        placed('them', cluster: 'c1', account: 'acct-them', x: 1),
      ]));
      settle(clock);

      expect(state.inHuddle, isFalse);
      expect(call.conversations, ['c1', null]);
      expect(call.told, [
        {'acct-them'},
        <String>{},
      ]);
    });
  });

  test('a held cluster is let go after the safety cap', () {
    withClock((clock) {
      final (:state, :call) = wired();

      state.debugApplyRoster(Roster(selfId: 'me', rows: [
        placed('me', cluster: 'c1', account: 'acct-me'),
        placed('them', cluster: 'c1', account: 'acct-them', x: 1),
      ]));
      settle(clock);

      // Our `clusterId` stays null while they linger in range and the server
      // never re-forms the bubble: a hold that never resolves must not last
      // forever.
      state.debugApplyRoster(Roster(selfId: 'me', rows: [
        placed('me', account: 'acct-me'),
        placed('them', cluster: 'c1', account: 'acct-them', x: 1),
      ]));

      // Just short of the cap: still held.
      clock.elapse(const Duration(seconds: 11));
      clock.flushMicrotasks();
      expect(state.inHuddle, isTrue);

      // Past the cap: released, banner and conversation and subscription alike.
      clock.elapse(const Duration(seconds: 3));
      clock.flushMicrotasks();
      expect(state.inHuddle, isFalse);
      expect(call.conversations, ['c1', null]);
      expect(call.told, [
        {'acct-them'},
        <String>{},
      ]);
    });
  });
}
