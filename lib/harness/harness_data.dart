/// The fake cast the simulator harness puts in a call.
///
/// The one invariant that makes the call screen light up: a person's media id
/// ([CallPerson.accountId]) is what a [CallParticipant.srcId] carries, and the
/// same string is the roster row's `userAccountId`. That is the bridge
/// `AppState.rowForSrcId` walks to put a name and a speaking ring on a tile —
/// see `lib/ui/call_screen.dart` `_tiles`. Get it wrong and every tile is
/// "Someone", mute and silent.
///
/// Everybody here, me included, shares one [kHuddleCluster]. The speaking-ring
/// notify in `AppState._noteSpeakers` only fires for rows whose `clusterId`
/// matches mine, and the big-view auto mode only follows people in my cluster,
/// so a split cluster would leave the scenario driver talking to nobody.
library;

import 'package:gather_client/gather_client.dart';

import '../src/app_state.dart';
import '../src/calendar.dart';
import '../src/google_calendar.dart';
import '../src/media/call.dart';

/// One made-up colleague.
class CallPerson {
  const CallPerson({
    required this.spaceId,
    required this.accountId,
    required this.name,
  });

  /// `SpaceUser.id` — the roster identity, and the tile's key.
  final String spaceId;

  /// `UserAccount.id` — the media identity. Doubles as the roster row's
  /// `userAccountId` so the two planes agree on who this is.
  final String accountId;

  final String name;
}

/// My own roster id. The call is drawn from my point of view.
const String kSelfId = 'me';

/// The conversation everybody in the harness call is standing in.
const String kHuddleCluster = 'huddle';

/// The bench. The driver seats the first N of them, so order is the cast list.
const List<CallPerson> kCast = [
  CallPerson(spaceId: 'space-ada', accountId: 'acc-ada', name: 'Ada'),
  CallPerson(spaceId: 'space-grace', accountId: 'acc-grace', name: 'Grace'),
  CallPerson(spaceId: 'space-kat', accountId: 'acc-kat', name: 'Katherine'),
  CallPerson(spaceId: 'space-mira', accountId: 'acc-mira', name: 'Mira'),
  CallPerson(spaceId: 'space-dot', accountId: 'acc-dot', name: 'Dorothy'),
  CallPerson(spaceId: 'space-alan', accountId: 'acc-alan', name: 'Alan'),
  CallPerson(spaceId: 'space-edsger', accountId: 'acc-edsger', name: 'Edsger'),
  CallPerson(spaceId: 'space-linus', accountId: 'acc-linus', name: 'Linus'),
];

/// The most people the cast can seat.
int get castSize => kCast.length;

/// The first [count] of the cast, clamped to what exists.
List<CallPerson> seated(int count) =>
    kCast.take(count.clamp(0, kCast.length)).toList();

/// The media-plane view of the call: who the SFU is sending us.
///
/// Audio on, video off — the harness draws avatars, not textures, so no stream
/// is ever attached (the call screen only reaches for one behind a `LiveCall`).
List<CallParticipant> participantsFor(int count) =>
    participantsForPeople(seated(count));

/// The media-plane view of a call with exactly [people] in it — the office
/// harness's equivalent of [participantsFor], keyed to the specific colleagues
/// standing beside me rather than the first N of the cast. Audio on, video off,
/// for the same reason.
List<CallParticipant> participantsForPeople(Iterable<CallPerson> people) => [
      for (final p in people) CallParticipant(srcId: p.accountId, hasAudio: true),
    ];

/// The game-plane view: the roster Gather would have sent, with the given
/// account ids marked as speaking.
///
/// Includes me, in the same cluster, so `myCluster` and the speaking notify both
/// see the group. [speakingAccountIds] is keyed by `accountId` to match what the
/// scenario driver reasons about.
Roster rosterFor(int count, {Set<String> speakingAccountIds = const {}}) {
  return Roster(
    selfId: kSelfId,
    rows: [
      const RosterRow(id: kSelfId, name: 'You', clusterId: kHuddleCluster),
      for (final p in seated(count))
        RosterRow(
          id: p.spaceId,
          name: p.name,
          clusterId: kHuddleCluster,
          userAccountId: p.accountId,
          speaking: speakingAccountIds.contains(p.accountId),
        ),
    ],
  );
}

// ---- the office -------------------------------------------------------------
//
// The whole-app harness (TARGET=app) needs more than a call roster: a floor to
// walk on and people standing somewhere on it. The real office is ~1700 patches
// of state dump resolving to 573 sprite URLs — none of which a sim without a
// network can fetch — so this is a *schematic* floor instead: a plain grid with a
// few named rooms and no art. The map screen draws floor, rooms and avatars from
// a [SpaceMap] alone; `art` being null just means no furniture sprites (see
// `map_screen.dart`, which takes `SpaceArt?`).

/// My own `UserAccount` id, for [FakeCollector.selfAccountId]. The map keys on
/// [kSelfId]; this is the media-plane identity, the self equivalent of
/// [CallPerson.accountId].
const String kSelfAccountId = 'acc-me';

/// The schematic floor's id, width and height, in tiles.
const String kFloorId = 'floor';
const int kOfficeWidth = 20;
const int kOfficeHeight = 15;

/// The schematic office the simulator draws instead of a real Gather floor.
///
/// No blocked tiles — the whole grid is walkable, so the D-pad never dead-ends
/// against furniture that is not drawn. The rooms are decoration the map labels;
/// they carry no collisions here.
SpaceMap schematicOffice() => SpaceMap(
      floorId: kFloorId,
      width: kOfficeWidth,
      height: kOfficeHeight,
      blocked: const <int>{},
      rooms: const [
        SpaceRoom(id: 'room-huddle', name: 'Huddle', type: 'room', x: 2, y: 2, width: 5, height: 4, walled: true),
        SpaceRoom(id: 'room-focus', name: 'Focus', type: 'room', x: 13, y: 2, width: 5, height: 4, walled: true),
        SpaceRoom(id: 'room-lounge', name: 'Lounge', type: 'room', x: 6, y: 9, width: 8, height: 4, walled: true),
      ],
    );

/// Where I start standing on [schematicOffice] — the middle of the floor.
const ({int x, int y}) kSelfStartTile = (x: 10, y: 7);

/// Where the cast start, keyed by `spaceId`. The driver walks them from here.
const Map<String, ({int x, int y})> kCastStartTiles = {
  'space-ada': (x: 4, y: 3),
  'space-grace': (x: 15, y: 3),
  'space-kat': (x: 9, y: 10),
  'space-mira': (x: 11, y: 11),
  'space-dot': (x: 3, y: 12),
  'space-alan': (x: 17, y: 11),
  'space-edsger': (x: 6, y: 6),
  'space-linus': (x: 14, y: 8),
};

/// My own map-plane row: present, here, drawable. `clusterId` is null on an
/// empty floor — the office is not a huddle — but the whole-app harness passes
/// [kHuddleCluster] the instant somebody is close enough to be in a call, which
/// is what lights `AppState.inHuddle` and the "In a call" banner. The speaking
/// ring on the map still reads the row's own `speaking` flag (see
/// `AppState.peopleOnMap`).
RosterRow selfOfficeRow(({int x, int y}) at, {String direction = 'Down', bool speaking = false, String? clusterId, String floorId = kFloorId, bool handRaised = false}) => RosterRow(
      id: kSelfId,
      name: 'You',
      connected: true,
      availability: 'Active',
      clusterId: clusterId,
      floorId: floorId,
      x: at.x,
      y: at.y,
      direction: direction,
      speaking: speaking,
      handRaised: handRaised,
    );

/// One colleague's map-plane row, standing at [at]. `isPresent` needs
/// `connected == true` and a non-`Offline` availability, or `peopleOnMap` drops
/// them — the one invariant that keeps a mocked floor from being empty.
///
/// [clusterId] is [kHuddleCluster] only while this person is within call range of
/// me, so `Roster.myCluster` carries exactly the people the office call driver is
/// animating — the bridge between standing-next-to and being-in-a-call-with.
RosterRow officeRow(CallPerson p, ({int x, int y}) at, {String direction = 'Down', bool speaking = false, String? clusterId, bool handRaised = false}) => RosterRow(
      id: p.spaceId,
      name: p.name,
      userAccountId: p.accountId,
      connected: true,
      availability: 'Active',
      clusterId: clusterId,
      x: at.x,
      y: at.y,
      direction: direction,
      speaking: speaking,
      handRaised: handRaised,
    );

// ---- the Plans tab ----------------------------------------------------------
//
// The app harness boots with an empty keychain, so the Plans tab would read
// "No plans yet" and the timeline redesign could not be eyeballed on a bare sim.
// This seeds a demo day that exercises every branch of the timeline at once:
// side-by-side double-bookings, a long gap that collapses to a faded band, a
// leading "Free till HH:MM" the morning after, and a clear day that reads "Free
// for the day". Local plans only — the app harness carries no Google client, so
// all-day banners and the colleague sheet still need a real `--dart-define` build.

/// A spread of planned meetings, anchored to [now], that lights up the timeline.
///
/// Today's cluster is pinned relative to [now] (not a wall-clock hour) so it is
/// always in the future and always renders, whatever time the sim is launched;
/// the later days use fixed clock hours to show a leading free band and an empty
/// day deterministically.
List<PlannedMeeting> demoPlannedMeetings(DateTime now) {
  // The top of the hour after next: today's first block sits on an hour line, so
  // the grid's labels line up with a block edge, and nothing is already past.
  final base = DateTime(now.year, now.month, now.day, now.hour)
      .add(const Duration(hours: 1));
  final today = DateTime(now.year, now.month, now.day);
  DateTime day(int offset, int h, [int m = 0]) =>
      today.add(Duration(days: offset, hours: h, minutes: m));

  PlannedMeeting mk(String id, String title, DateTime s, DateTime e,
          {String? room, String? stable}) =>
      PlannedMeeting(
          id: id, title: title, startsAt: s, endsAt: e, roomStableId: stable, roomName: room);

  return [
    // Today: a short standup, then an overlapping pair (double-booking → two
    // lanes), then a >90min gap (collapses to a faded "Nh free") before a wrap-up.
    mk('demo-standup', 'Standup', base, base.add(const Duration(minutes: 15)),
        room: 'Huddle', stable: 'room-huddle'),
    mk('demo-review', 'Design review', base.add(const Duration(hours: 1)),
        base.add(const Duration(hours: 3)),
        room: 'Focus', stable: 'room-focus'),
    mk('demo-1on1', '1:1 with Ada', base.add(const Duration(hours: 1, minutes: 30)),
        base.add(const Duration(hours: 2)),
        room: 'Lounge', stable: 'room-lounge'),
    mk('demo-wrap', 'Wrap-up', base.add(const Duration(hours: 5)),
        base.add(const Duration(hours: 5, minutes: 45)),
        room: 'Lounge', stable: 'room-lounge'),
    // Tomorrow: one afternoon slot on the hour, so the morning reads "Free till 14:00".
    // (The leading free band is day-top → first event now, so it shows whatever the
    // hour — an on-the-hour start used to swallow it.)
    mk('demo-sync', 'Team sync', day(1, 14), day(1, 15),
        room: 'Huddle', stable: 'room-huddle'),
    // Day after tomorrow has nothing — but an event on day+3 keeps it in the
    // rendered range, so it shows as a "Free for the day" marker between the two.
    mk('demo-roadmap', 'Roadmap planning', day(3, 10), day(3, 11, 30),
        room: 'Focus', stable: 'room-focus'),
  ];
}

/// Canned colleague calendars for the person-peek sheet, keyed by the cast's names, so
/// tapping someone on the map or Dial opens their timeline on a bare sim — the app
/// harness has no OAuth account, so the live path would say "no calendar" for everyone.
///
/// Spreads the shapes the sheet has to tell apart: a busy morning that frees up, a free
/// run before a late start, a double-booking under an all-day banner, plus the two
/// non-event outcomes (nothing shared, and a calendar that would not load).
Map<String, PersonCalendar> demoPeopleCalendars(DateTime now) {
  final today = DateTime(now.year, now.month, now.day);
  DateTime day(int offset, int h, [int m = 0]) =>
      today.add(Duration(days: offset, hours: h, minutes: m));
  GoogleEvent ev(String id, String title, DateTime s, DateTime e,
          {String? location, bool allDay = false}) =>
      GoogleEvent(id: id, title: title, startsAt: s, endsAt: e, location: location, allDay: allDay);

  return {
    // Busy morning, then open after lunch — the "when do they free up" case.
    'Ada': PersonCalendar.ok([
      ev('ada-1', 'Sprint planning', day(0, 9), day(0, 10, 30), location: 'Focus'),
      ev('ada-2', 'Interview', day(0, 11), day(0, 11, 45)),
      ev('ada-3', 'Design crit', day(1, 13), day(1, 14)),
    ]),
    // Nothing until mid-afternoon — a long leading "Free till" band.
    'Grace': PersonCalendar.ok([
      ev('grace-1', 'Customer call', day(0, 15, 30), day(0, 16, 30), location: 'Lounge'),
    ]),
    // An all-day banner over a double-booked afternoon.
    'Katherine': PersonCalendar.ok([
      ev('kat-all', 'Offsite', day(0, 0), day(1, 0), allDay: true),
      ev('kat-1', 'Workshop', day(0, 13), day(0, 15), location: 'Huddle'),
      ev('kat-2', '1:1', day(0, 14), day(0, 14, 30)),
    ]),
    // Shared nothing — the honest "no calendar" state, not an empty one.
    'Mira': PersonCalendar.noCalendar,
    // A calendar that is there but would not read right now.
    'Dorothy': PersonCalendar.unavailable,
  };
}
