/// Warp Dial's data layer: the directory, the conversations, and the warp.
///
/// These assert the three things the Dial tab is built on, all off a crafted
/// roster fed through [AppState.debugApplyRoster] — the same path the live socket
/// drives: that the contact list sorts the people who are here above the people who
/// are not, that a cluster of two or more becomes a joinable meeting (and a
/// singleton does not), that a conversation sitting in a named room is named by it,
/// and that warping to a person hops the avatar and leaves the offline unreachable.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:gather_client/gather_client.dart';
import 'package:gather_companion/harness/fake_collector.dart';
import 'package:gather_companion/harness/harness_data.dart';
import 'package:gather_companion/src/app_state.dart';
import 'package:gather_companion/src/link_status.dart';

import 'fake_call.dart';

void main() {
  RosterRow row(
    String id, {
    String? name,
    bool connected = true,
    String availability = 'Active',
    String? clusterId,
    String? floorId,
    num? x,
    num? y,
    PersonStatus? status,
  }) =>
      RosterRow(
        id: id,
        name: name ?? id,
        connected: connected,
        availability: availability,
        clusterId: clusterId,
        clusterIdKnown: clusterId != null,
        floorId: floorId,
        x: x,
        y: y,
        status: status,
      );

  Roster rosterOf(List<RosterRow> rows) => Roster(selfId: kSelfId, rows: rows);

  group('directory', () {
    test('lists everyone but me, present first and then by name', () {
      final state = AppState()
        ..debugApplyRoster(rosterOf([
          const RosterRow(id: kSelfId, name: 'You'),
          row('charlie', name: 'Charlie'),
          row('alice', name: 'alice'),
          row('bob', name: 'Bob', connected: false, availability: 'Offline'),
        ]));
      addTearDown(state.dispose);

      final labels = state.directory.map((c) => c.label).toList();
      // Present pair alphabetised (case-insensitive), then the offline one.
      expect(labels, ['alice', 'Charlie', 'Bob']);
      expect(state.directory.map((c) => c.isPresent), [true, true, false]);
      // Never me.
      expect(state.directory.any((c) => c.id == kSelfId), isFalse);
    });

    test('an empty roster is an empty directory, not a crash', () {
      final state = AppState();
      addTearDown(state.dispose);
      expect(state.directory, isEmpty);
      expect(state.meetings, isEmpty);
    });
  });

  group('meetings', () {
    test('a cluster of two or more is one meeting; a singleton is none', () {
      final state = AppState()
        ..debugApplyRoster(rosterOf([
          const RosterRow(id: kSelfId, name: 'You'),
          row('a', name: 'Ada', clusterId: 'c1', x: 1, y: 1),
          row('b', name: 'Bob', clusterId: 'c1', x: 2, y: 1),
          row('c', name: 'Cal', clusterId: 'c2', x: 8, y: 8), // alone in c2
        ]));
      addTearDown(state.dispose);

      expect(state.meetings, hasLength(1));
      final meeting = state.meetings.single;
      expect(meeting.clusterId, 'c1');
      expect(meeting.members.map((m) => m.label), containsAll(['Ada', 'Bob']));
      expect(meeting.includesMe, isFalse);
    });

    test('the conversation I am in comes first and is flagged', () {
      final state = AppState()
        ..debugApplyRoster(rosterOf([
          const RosterRow(id: kSelfId, name: 'You', clusterId: 'mine', clusterIdKnown: true),
          row('a', name: 'Ada', clusterId: 'mine', x: 1, y: 1),
          row('b', name: 'Bob', clusterId: 'big', x: 2, y: 1),
          row('c', name: 'Cal', clusterId: 'big', x: 3, y: 1),
          row('d', name: 'Dot', clusterId: 'big', x: 4, y: 1),
        ]));
      addTearDown(state.dispose);

      expect(state.meetings.first.includesMe, isTrue);
      expect(state.meetings.first.clusterId, 'mine');
      // My own row is not listed as a member of my meeting.
      expect(state.meetings.first.members.map((m) => m.id), isNot(contains(kSelfId)));
    });

    test('drops a cluster whose only live member is a dropped socket', () {
      final state = AppState()
        ..debugApplyRoster(rosterOf([
          const RosterRow(id: kSelfId, name: 'You'),
          row('a', name: 'Ada', clusterId: 'c1', connected: false, availability: 'Offline', x: 1, y: 1),
          row('b', name: 'Bob', clusterId: 'c1', connected: false, availability: 'Offline', x: 2, y: 1),
        ]));
      addTearDown(state.dispose);
      expect(state.meetings, isEmpty);
    });

    test('names a conversation by the room its members sit in', () {
      // Lounge is x6..13, y9..12 on the schematic office.
      final state = AppState()
        ..debugMap = schematicOffice()
        ..debugApplyRoster(rosterOf([
          const RosterRow(id: kSelfId, name: 'You'),
          row('a', name: 'Ada', clusterId: 'c1', x: 8, y: 10),
          row('b', name: 'Bob', clusterId: 'c1', x: 9, y: 11),
        ]));
      addTearDown(state.dispose);
      expect(state.meetings.single.roomName, 'Lounge');
    });

    test('leaves a conversation unroomed when its members are scattered', () {
      final state = AppState()
        ..debugMap = schematicOffice()
        ..debugApplyRoster(rosterOf([
          const RosterRow(id: kSelfId, name: 'You'),
          row('a', name: 'Ada', clusterId: 'c1', x: 8, y: 10), // Lounge
          row('b', name: 'Bob', clusterId: 'c1', x: 0, y: 0), // open floor
        ]));
      addTearDown(state.dispose);
      expect(state.meetings.single.roomName, isNull);
    });

    test('an unplaced member is no evidence a majority is in the room', () {
      // One of three sits in the Lounge; the other two have no position. A majority
      // of *all* members is not inside, so the room must not name the meeting.
      final state = AppState()
        ..debugMap = schematicOffice()
        ..debugApplyRoster(rosterOf([
          const RosterRow(id: kSelfId, name: 'You'),
          row('a', name: 'Ada', clusterId: 'c1', x: 8, y: 10), // Lounge
          row('b', name: 'Bob', clusterId: 'c1'), // unplaced
          row('c', name: 'Cal', clusterId: 'c1'), // unplaced
        ]));
      addTearDown(state.dispose);
      expect(state.meetings.single.roomName, isNull);
    });

    test('a connected row gone Offline is not counted as being in the room', () {
      // Its socket is still open but its coordinates are wherever it logged off, so
      // it is not present and leaves a one-person cluster — no meeting to join.
      final state = AppState()
        ..debugApplyRoster(rosterOf([
          const RosterRow(id: kSelfId, name: 'You'),
          row('a', name: 'Ada', clusterId: 'c1', x: 1, y: 1),
          row('b', name: 'Bob', clusterId: 'c1', availability: 'Offline', x: 2, y: 1),
        ]));
      addTearDown(state.dispose);
      expect(state.meetings, isEmpty);
    });
  });

  group('directoryChanges', () {
    // The tab listens to this ticker, not to every roster, so it must fire for the
    // fields Dial renders off a row — and stay silent on the footsteps it does not.
    int ticksOf(void Function(AppState) drive) {
      final state = AppState()..debugMap = schematicOffice();
      addTearDown(state.dispose);
      var ticks = 0;
      state.directoryChanges.addListener(() => ticks++);
      drive(state);
      return ticks;
    }

    PersonStatus status(String text) => PersonStatus(text: text, type: 'Custom');

    test('wakes when a status line changes, presence unmoved', () {
      final ticks = ticksOf((state) {
        state.debugApplyRoster(rosterOf([
          const RosterRow(id: kSelfId, name: 'You'),
          row('a', name: 'Ada', x: 1, y: 1, status: status('Heads down')),
        ]));
        state.debugApplyRoster(rosterOf([
          const RosterRow(id: kSelfId, name: 'You'),
          row('a', name: 'Ada', x: 1, y: 1, status: status('Back at 3')),
        ]));
      });
      expect(ticks, 2, reason: 'first roster, then the status edit');
    });

    test('wakes when a row gains a position to warp to', () {
      final ticks = ticksOf((state) {
        state.debugApplyRoster(rosterOf([
          const RosterRow(id: kSelfId, name: 'You'),
          row('a', name: 'Ada'), // unplaced — not reachable
        ]));
        state.debugApplyRoster(rosterOf([
          const RosterRow(id: kSelfId, name: 'You'),
          row('a', name: 'Ada', x: 1, y: 1), // now placed
        ]));
      });
      expect(ticks, 2, reason: 'reachability flipped, so the Warp button must repaint');
    });

    test('wakes when a clustered member crosses into another room', () {
      // Lounge is x6..13, y9..12 on the schematic office.
      final ticks = ticksOf((state) {
        state.debugApplyRoster(rosterOf([
          const RosterRow(id: kSelfId, name: 'You'),
          row('a', name: 'Ada', clusterId: 'c1', x: 0, y: 0), // open floor
          row('b', name: 'Bob', clusterId: 'c1', x: 1, y: 0),
        ]));
        state.debugApplyRoster(rosterOf([
          const RosterRow(id: kSelfId, name: 'You'),
          row('a', name: 'Ada', clusterId: 'c1', x: 8, y: 10), // into the Lounge
          row('b', name: 'Bob', clusterId: 'c1', x: 9, y: 11),
        ]));
      });
      expect(ticks, 2, reason: 'the meeting is now named by a room, so its card changes');
    });

    test('sleeps through a footstep that moves nothing it renders', () {
      final ticks = ticksOf((state) {
        state.debugApplyRoster(rosterOf([
          const RosterRow(id: kSelfId, name: 'You'),
          row('a', name: 'Ada', x: 1, y: 1),
        ]));
        // Same person, a step over — no cluster, same room-less open floor.
        state.debugApplyRoster(rosterOf([
          const RosterRow(id: kSelfId, name: 'You'),
          row('a', name: 'Ada', x: 2, y: 1),
        ]));
      });
      expect(ticks, 1, reason: 'only the first roster; the footstep must not repaint the tab');
    });
  });

  group('warpToPerson', () {
    ({AppState state, FakeCollector collector}) wired(List<RosterRow> rows) {
      final collector = FakeCollector();
      final state = AppState()
        ..debugAttachCollector(collector)
        ..debugApplyRoster(rosterOf(rows));
      addTearDown(state.dispose);
      return (state: state, collector: collector);
    }

    test('hops the avatar next to a present person', () async {
      final (:state, :collector) = wired([
        const RosterRow(id: kSelfId, name: 'You', x: 9, y: 8),
        row('a', name: 'Ada', x: 11, y: 8),
      ]);

      final before = collector.teleports.length;
      final ada = state.directory.firstWhere((c) => c.id == 'a');
      final failed = await state.warpToPerson(ada);

      expect(failed, isNull);
      expect(collector.teleports.length, before + 1, reason: 'a warp is a teleport');
    });

    test('refuses an offline person and sends nothing', () async {
      final (:state, :collector) = wired([
        const RosterRow(id: kSelfId, name: 'You', x: 9, y: 8),
        row('a', name: 'Ada', connected: false, availability: 'Offline', x: 11, y: 8),
      ]);

      final ada = state.directory.firstWhere((c) => c.id == 'a');
      final failed = await state.warpToPerson(ada);

      expect(failed, contains('not in the office'));
      expect(collector.teleports, isEmpty);
    });

    test('refuses when the connection is disrupted', () async {
      final (:state, :collector) = wired([
        const RosterRow(id: kSelfId, name: 'You', x: 9, y: 8),
        row('a', name: 'Ada', x: 11, y: 8),
      ]);
      state.debugApplyLink(const LinkStatus(LinkState.offline));

      final ada = state.directory.firstWhere((c) => c.id == 'a');
      final failed = await state.warpToPerson(ada);

      expect(failed, contains('No connection'));
      expect(collector.teleports, isEmpty);
    });

    test('refuses someone on another floor and sends nothing', () async {
      final (:state, :collector) = wired([
        const RosterRow(id: kSelfId, name: 'You', floorId: 'ground', x: 9, y: 8),
        row('a', name: 'Ada', floorId: 'first', x: 11, y: 8),
      ]);

      final ada = state.directory.firstWhere((c) => c.id == 'a');
      final failed = await state.warpToPerson(ada);

      expect(failed, contains('another floor'));
      expect(collector.teleports, isEmpty);
      expect(state.canWarpTo(ada), isFalse, reason: 'the button is withheld too');
    });

    test('opens the microphone once after a successful warp', () async {
      final (:state, :collector) = wired([
        const RosterRow(id: kSelfId, name: 'You', x: 9, y: 8),
        row('a', name: 'Ada', x: 11, y: 8),
      ]);
      final call = FakeCall();
      state.debugAttachCall(call);
      addTearDown(call.dispose);

      final ada = state.directory.firstWhere((c) => c.id == 'a');
      final failed = await state.warpToPerson(ada);

      expect(failed, isNull);
      expect(call.micCalls, [true], reason: 'a call connects the microphone, once');
    });

    test('leaves the microphone alone when the warp is refused', () async {
      final (:state, :collector) = wired([
        const RosterRow(id: kSelfId, name: 'You', x: 9, y: 8),
        row('a', name: 'Ada', connected: false, availability: 'Offline', x: 11, y: 8),
      ]);
      final call = FakeCall();
      state.debugAttachCall(call);
      addTearDown(call.dispose);

      final ada = state.directory.firstWhere((c) => c.id == 'a');
      final failed = await state.warpToPerson(ada);

      expect(failed, contains('not in the office'));
      expect(call.micCalls, isEmpty);
    });
  });
}
