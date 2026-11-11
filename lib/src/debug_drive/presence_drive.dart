/// `ext.gc.presence.*`: who the app believes is here, in the three shapes the
/// screens draw them (plan Phase 5, #108).
///
/// The app keeps three views of one roster and each screen reads a different
/// one, so "is Bob here" has three answers that are supposed to agree and the
/// bugs live where they do not:
///
///  * `roster` — the presence digest ([AppState.snapshot]`.players`): who the
///    tracker has folded out of the wire, with following and speaking. It is what
///    notifications and the follower card reason from, and it carries the
///    collector's health, because an unhealthy collector's empty list means "I
///    cannot tell", not "nobody".
///  * `followers` — [AppState.followers], the chips on the home screen and the
///    one thing this app claims to know about anyone.
///  * `directory` — [AppState.directory], the Dial tab: everybody in the space
///    except me, offline included, present first.
///  * `map.people` — [AppState.peopleOnMap] plus [AppState.mePerson]: who the
///    office draws and where, after the present-only and same-floor filters.
///
/// ## Empty is never just `[]`
///
/// Each readout says why it is empty (the repo's honesty rule): `not_loaded`
/// before the first snapshot, `collector_unhealthy` while connected but
/// stateless, `no_roster` before Gather has sent one ([AppState.hasRoster]),
/// `no_position` when I have no tile on the map, and `nobody_else` only when the
/// roster really did arrive with nobody else in it. `followers.known` is false
/// whenever the empty list could be "I cannot tell".
///
/// ## What is left out
///
/// Avatar URLs are signed links and calendar addresses are other people's email;
/// neither is needed to check presence, so the readouts carry `hasAvatar` /
/// `hasCalendar` instead. Statuses are the line Gather already shows under the
/// name. No credential is touched. All four are read-only and not outward.
///
/// Every list takes `max` (default 200, at most 1000) and says `truncated`.
library;

import '../app_state.dart';
import '../directory.dart';
import '../map_person.dart';
import 'debug_drive.dart';
import 'drive_result.dart';

const _defaultMax = 200;

/// `ext.gc.presence.{roster, followers, directory, map.people}`.
DriveFeature presenceFeature({
  required AppState Function() app,
  required String Function() boot,
}) {
  int max(Map<String, Object?> args) => args.optionalInt('max', min: 0, max: 1000) ?? _defaultMax;

  return DriveFeature('presence', [
    DriveAction('roster', (args) async => DriveResult.ok(rosterReadout(app(), boot: boot(), max: max(args)))),
    DriveAction('followers', (args) async => DriveResult.ok(followersReadout(app(), boot: boot(), max: max(args)))),
    DriveAction('directory', (args) async => DriveResult.ok(directoryReadout(app(), boot: boot(), max: max(args)))),
    DriveAction('map.people', (args) async => DriveResult.ok(mapPeopleReadout(app(), boot: boot(), max: max(args)))),
  ]);
}

/// Why a presence list could be empty for a reason other than an empty office,
/// or null when it is a real answer.
String? _blind(AppState state) {
  if (!state.isLoaded) return 'not_loaded';
  if (!state.snapshot.health.gather) return 'collector_unhealthy';
  return null;
}

Map<String, Object?> _context(AppState state, String boot) {
  final health = state.snapshot.health;
  return {
    'boot': boot,
    'loaded': state.isLoaded,
    'healthy': health.gather,
    'healthDetail': health.detail,
    'rosterReceived': state.hasRoster,
    'selfId': state.meId,
    'spaceId': state.snapshot.self.spaceId,
  };
}

/// `presence.roster`: the presence digest, with the counts of the other views.
Map<String, Object?> rosterReadout(AppState state, {required String boot, int max = _defaultMax}) {
  final players = state.snapshot.players;
  final directory = state.directory;
  return {
    ..._context(state, boot),
    'counts': {
      'players': players.length,
      'followers': state.followers.length,
      'directory': directory.length,
      'present': directory.where((c) => c.isPresent).length,
      'onMap': state.peopleOnMap.length,
    },
    'players': [
      for (final p in players.take(max))
        {
          'id': p.id,
          'name': p.name,
          'label': p.label,
          'inSpace': p.inSpace,
          'isFollowingMe': p.isFollowingMe,
          'speaking': p.speaking,
          'followingMeSince': p.followingMeSince?.toUtc().toIso8601String(),
        },
    ],
    'truncated': players.length > max,
    if (players.isEmpty) 'empty': _blind(state) ?? 'nobody_else',
  };
}

/// `presence.followers`: [AppState.followers], and whether its empty is known.
Map<String, Object?> followersReadout(AppState state, {required String boot, int max = _defaultMax}) {
  final followers = state.followers;
  final blind = _blind(state);
  return {
    ..._context(state, boot),
    // A non-empty list is evidence whatever the health says; an empty one is only
    // "nobody is following you" when the collector could have seen otherwise.
    'known': followers.isNotEmpty || blind == null,
    'count': followers.length,
    'followers': [
      for (final p in followers.take(max))
        {
          'id': p.id,
          'name': p.name,
          'label': p.label,
          'speaking': p.speaking,
          'followingMeSince': p.followingMeSince?.toUtc().toIso8601String(),
        },
    ],
    'truncated': followers.length > max,
    if (followers.isEmpty) 'empty': blind ?? 'nobody_following',
  };
}

/// `presence.directory`: the Dial tab's contact list, in its order.
Map<String, Object?> directoryReadout(AppState state, {required String boot, int max = _defaultMax}) {
  final contacts = state.directory;
  return {
    ..._context(state, boot),
    'count': contacts.length,
    'present': contacts.where((c) => c.isPresent).length,
    'reachable': contacts.where((c) => c.isReachable).length,
    'contacts': [for (final c in contacts.take(max)) _contact(c)],
    'truncated': contacts.length > max,
    if (contacts.isEmpty) 'empty': state.hasRoster ? 'nobody_else' : (_blind(state) ?? 'no_roster'),
  };
}

Map<String, Object?> _contact(Contact c) => {
      'id': c.id,
      'label': c.label,
      'isPresent': c.isPresent,
      'isReachable': c.isReachable,
      'availability': c.availability,
      'clusterId': c.clusterId,
      'floorId': c.floorId,
      'tile': c.x == null || c.y == null ? null : {'x': c.x, 'y': c.y},
      'status': c.status == null
          ? null
          : {
              'text': c.status!.text,
              'emoji': c.status!.emoji,
              'type': c.status!.type,
              'clearAt': c.status!.clearAt?.toUtc().toIso8601String(),
            },
      'hasCalendar': c.calendarEmail != null,
    };

/// `presence.map.people`: who the office draws and where, me included.
Map<String, Object?> mapPeopleReadout(AppState state, {required String boot, int max = _defaultMax}) {
  final people = state.peopleOnMap;
  final me = state.mePerson;
  return {
    ..._context(state, boot),
    'me': me == null ? null : _person(me),
    'count': people.length,
    'people': [for (final p in people.take(max)) _person(p)],
    'truncated': people.length > max,
    if (people.isEmpty)
      'empty': state.hasRoster
          // With no tile of my own the floor filter cannot run, but the list is
          // still everyone present elsewhere — so an empty one is still nobody.
          ? 'nobody_else'
          : (_blind(state) ?? 'no_roster'),
    if (me == null && state.hasRoster) 'meMissing': 'no_position',
  };
}

Map<String, Object?> _person(MapPerson p) => {
      'id': p.id,
      'label': p.label,
      'x': p.x,
      'y': p.y,
      'isMe': p.isMe,
      'isFollowingMe': p.isFollowingMe,
      'speaking': p.speaking,
      'dancing': p.dancing,
      'direction': p.direction,
      'gait': p.gait.name,
      'availability': p.availability,
      'hasAvatar': p.avatarUrl != null,
      'hasCalendar': p.calendarEmail != null,
    };
