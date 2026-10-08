/// The office blanking to black on a reconnect, and the [AppState] hold that stops it.
///
/// `DirectCollector` swaps in a fresh empty reader on every reconnect, so `map` went
/// null for the second or two until the next dump repopulated it — the screen flashed
/// the black "Not connected" placeholder in between. [AppState] now holds the last
/// office and falls back to it while we are still in the same space. The move gates
/// stay keyed on the raw link state, because you still cannot walk into a reconnecting
/// socket.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:gather_client/gather_client.dart';
import 'package:gather_companion/harness/fake_collector.dart';
import 'package:gather_companion/harness/harness_data.dart';
import 'package:gather_companion/src/app_state.dart';
import 'package:gather_companion/src/link_status.dart';
import 'package:gather_events/gather_events.dart';

/// A snapshot whose self sits in [spaceId], so the current-space key the held map
/// is pinned to can be moved under it.
PresenceSnapshot _inSpace(String spaceId) => PresenceSnapshot(
      self: SelfState(spaceId: spaceId),
      players: const [],
      health: const CollectorHealth(),
      at: DateTime.fromMillisecondsSinceEpoch(0),
    );

void main() {
  group('the office is held across a reconnect', () {
    test('a null live map falls back to the last office while the space is unchanged', () {
      final collector = FakeCollector();
      final state = AppState()..debugAttachCollector(collector);
      addTearDown(state.dispose);

      // We are in space s1, and a roster has landed — so the office is now held.
      collector.spaceId = 's1';
      state.debugApplySnapshot(_inSpace('s1'));
      state.debugApplyRoster(Roster(selfId: kSelfId, rows: [selfOfficeRow(kSelfStartTile)]));
      expect(state.map, isNotNull, reason: 'the live reader has the office');

      // The reconnect swaps in a fresh empty reader: the live lookup is null, but no
      // roster has arrived to refresh the held copy, so the office must stay.
      collector.hasMap = false;
      expect(state.map, isNotNull, reason: 'the held office carries the gap');
    });

    test('a space change drops the held office rather than flashing the old floor', () {
      final collector = FakeCollector();
      final state = AppState()..debugAttachCollector(collector);
      addTearDown(state.dispose);

      collector.spaceId = 's1';
      state.debugApplySnapshot(_inSpace('s1'));
      state.debugApplyRoster(Roster(selfId: kSelfId, rows: [selfOfficeRow(kSelfStartTile)]));

      // The reader empties *and* the collector has resolved a different space: the
      // held office belongs to s1 and must not be served under s2.
      collector.hasMap = false;
      collector.spaceId = 's2';
      expect(state.map, isNull, reason: 'the held office is stale once the space changed');
    });

    test('a move to another floor drops the held office rather than drawing the old floor', () {
      final collector = FakeCollector();
      final state = AppState()..debugAttachCollector(collector);
      addTearDown(state.dispose);

      // Held on the ground floor, which is the only floor the collector has a plan for.
      collector.mapFloorId = kFloorId;
      state.debugApplySnapshot(_inSpace('s1'));
      state.debugApplyRoster(Roster(selfId: kSelfId, rows: [selfOfficeRow(kSelfStartTile)]));
      expect(state.map, isNotNull, reason: 'the live reader has the ground floor');

      // Self steps onto a floor whose plan has not arrived: the live lookup is null,
      // but the held office belongs to the ground floor and must not stand in for it —
      // its geometry would be wrong under the new floor's occupants.
      state.debugApplyRoster(
        Roster(selfId: kSelfId, rows: [selfOfficeRow(kSelfStartTile, floorId: 'upstairs')]),
      );
      expect(state.map, isNull, reason: 'the held office is the wrong floor now');
    });

    test('an unknown space identity refuses to serve the held office', () {
      final collector = FakeCollector();
      final state = AppState()..debugAttachCollector(collector);
      addTearDown(state.dispose);

      // The collector has not resolved a space yet, and no dump has named one: the
      // current-space key is null. A null key is not proof that we are still in the
      // office the hold was taken in, so `null == null` must not open the fallback.
      collector.spaceId = null;
      state.debugApplySnapshot(PresenceSnapshot(
        self: const SelfState(spaceId: null),
        players: const [],
        health: const CollectorHealth(),
        at: DateTime.fromMillisecondsSinceEpoch(0),
      ));
      state.debugApplyRoster(Roster(selfId: kSelfId, rows: [selfOfficeRow(kSelfStartTile)]));

      collector.hasMap = false;
      expect(state.map, isNull, reason: 'an unknown space identity cannot vouch for the hold');
    });

    test('a map that finishes after the last roster is still held across a reconnect', () {
      final collector = FakeCollector();
      final state = AppState()..debugAttachCollector(collector);
      addTearDown(state.dispose);

      // The roster lands before the floor plan has finished building: a map-only patch
      // publishes no roster, so the roster-time refresh stashes nothing.
      state.debugApplySnapshot(_inSpace('s1'));
      collector.hasMap = false;
      state.debugApplyRoster(Roster(selfId: kSelfId, rows: [selfOfficeRow(kSelfStartTile)]));

      // The plan arrives and the getter serves — and stashes — it.
      collector.hasMap = true;
      expect(state.map, isNotNull, reason: 'the live plan is there now');

      // The next reconnect empties the reader: the late map must still be held.
      collector.hasMap = false;
      expect(state.map, isNotNull, reason: 'the late office carries the gap');
    });
  });

  test('a move stays blocked while the link is disrupted', () {
    final state = AppState();
    addTearDown(state.dispose);

    state.debugApplyLink(const LinkStatus(LinkState.retrying, 'reconnecting'));

    // The office is held and the banner shows, but the socket is disrupted: `canWalk`
    // reads `link.isDisrupted`, so the move gate holds rather than opening onto a
    // reconnecting socket.
    expect(state.link.isDisrupted, isTrue, reason: 'the gate still sees a disrupted socket');
    expect(state.canWalk, isFalse, reason: 'you cannot walk into a reconnecting socket');
  });
}
