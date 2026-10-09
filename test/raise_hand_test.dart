/// Raising a hand, from the button to the wire and back down.
///
/// The hand is sticky state, unlike a reaction: it stays up until it is lowered,
/// and three places lower it — the button, starting to talk, and walking out of
/// the meeting. This covers the [AppState] end of all three. The wire shape is
/// `direct_collector_test.dart` and the badge on the tile is `call_screen_test.dart`;
/// this is the state in between, which is the part the two of them read.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:gather_client/gather_client.dart';
import 'package:gather_companion/src/app_state.dart';

import 'fake_call.dart';

void main() {
  RosterRow row(String id, {String? cluster}) => RosterRow(
        id: id,
        name: id,
        clusterIdKnown: true,
        clusterId: cluster,
        connected: true,
        x: 3,
        y: 4,
      );

  ({AppState state, List<bool> rebuilds}) wired() {
    final rebuilds = <bool>[];
    final state = AppState();
    state.addListener(() => rebuilds.add(state.myHandRaised));
    addTearDown(state.dispose);
    return (state: state, rebuilds: rebuilds);
  }

  test('a hand goes up the moment the button is pressed, before any echo', () async {
    final (:state, :rebuilds) = wired();
    expect(state.myHandRaised, isFalse);

    await state.setHandRaised(true);

    // Local-first, like the speaking ring: nothing on the wire has agreed yet, and
    // the one thing that should never wait for Gather is the button under the thumb.
    expect(state.myHandRaised, isTrue);
    expect(rebuilds, [true]);
  });

  test('pressing it again takes it down', () async {
    final (:state, :rebuilds) = wired();
    await state.setHandRaised(true);
    await state.toggleHandRaised();
    expect(state.myHandRaised, isFalse);
    expect(rebuilds, [true, false]);
  });

  test('asking for the state it is already in does nothing', () async {
    final (:state, :rebuilds) = wired();
    await state.setHandRaised(false);
    // No flip, so no rebuild — the roster echo and the speak-lowering both land
    // here, and neither should stutter the button by redrawing a no-op.
    expect(rebuilds, isEmpty);
  });

  test('starting to talk lowers the hand', () async {
    final (:state, :rebuilds) = wired();
    final call = FakeCall();
    state.debugAttachCall(call);

    await state.setHandRaised(true);
    expect(state.myHandRaised, isTrue);

    call.speak(true);
    await Future<void>.delayed(Duration.zero);

    // The raised hand was a request to speak, and now you are — so it comes down
    // on its own, the way Gather's own client does it.
    expect(state.myHandRaised, isFalse);
  });

  test('walking out of the meeting lowers the hand', () {
    final (:state, :rebuilds) = wired();
    state.debugHuddle = ['luca'];
    state.setHandRaised(true);
    expect(state.myHandRaised, isTrue);

    // The meeting is behind us now. The button that raises the hand is gone with
    // it, so a hand left up would have no way down and would ride into the next one.
    state.debugHuddle = [];
    state.debugApplyRoster(Roster(selfId: 'me', rows: [row('me')]));

    expect(state.myHandRaised, isFalse);
  });

  test('a hand stays up for as long as the meeting lasts', () {
    final (:state, :rebuilds) = wired();
    state.debugHuddle = ['luca'];
    state.setHandRaised(true);

    state.debugApplyRoster(Roster(selfId: 'me', rows: [
      row('me', cluster: 'c1'),
      row('luca', cluster: 'c1'),
    ]));

    // Still in the meeting, so nothing lowers it — a roster arriving is not a
    // reason to put somebody's hand down.
    expect(state.myHandRaised, isTrue);
  });
}
