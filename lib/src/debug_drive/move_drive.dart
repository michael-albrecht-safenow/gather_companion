/// `ext.gc.move.*`: walking, hopping and warping, through the exact [AppState]
/// methods the map, the Dial tab and the desk button call (plan Phase 5).
///
/// | Action | Calls | Shape |
/// |---|---|---|
/// | `goTo {x, y, timeoutMs?}` | [AppState.goTo] | op |
/// | `warpToTile {x, y}` | [AppState.warpToTile] | immediate |
/// | `warpToPerson {id \| name, timeoutMs?}` | [AppState.warpToPerson] | op |
/// | `goToRoom {id \| stableId \| name, timeoutMs?}` | [AppState.goToRoom] | op |
/// | `goToMyDesk {timeoutMs?}` | [AppState.goToMyDesk] | op |
/// | `stop` | [AppState.stopWalking] | immediate |
///
/// ## Which of these are outward, and why nearly all of them are
///
/// The plan's feature table marks only `warpToPerson` and `goToRoom` **(O)**. That
/// undercounts. Your avatar is on every colleague's map, and every one of them
/// watches it walk: a step is a `move` on the shared `SpaceUser`, a hop is a
/// `teleport` everybody sees dissolve and reappear, and whoever you stop next to is
/// in a conversation with you whether either of you meant it. The plan's own rule —
/// "Test space and outward actions": anything anyone else in the space could see is
/// outward — therefore covers every action here that moves you: `goTo`,
/// `warpToTile`, `warpToPerson` (which also opens your microphone), `goToRoom` and
/// `goToMyDesk`. Each is refused on `boot: "live"` outside `DRIVE_TEST_SPACE`
/// without `confirm: true`.
///
/// `stop` is the one exception, deliberately. It starts nothing: it ends a walk
/// that is already under way — one the user, or an outward action they confirmed,
/// set off — and leaves you on the tile you had reached. Gating it would mean an
/// agent that confirmed a walk across a real office could not call it off without
/// asking again, and the gate exists to stop the drive *doing* visible things, not
/// to make it harder to stop doing one.
///
/// ## Walks are ops, and what "settled" means
///
/// A walk across the office takes seconds; a warp may build the call before it
/// answers. So `goTo`, `goToRoom`, `goToMyDesk` and `warpToPerson` hand back
/// `{id}` from [DriveOps.start] at once, and `op.result` carries one of two things:
///
///  * **a refusal** — the [AppState] method's own sentence, as `message`, with a
///    stable `reason` (`no_map`, `not_connected`, `link_disrupted`,
///    `position_unknown`, `nowhere_to_stand`, `no_desk`, `person_absent`,
///    `person_unplaced`, `other_floor`, `room_full`, `declined` for anything else).
///    The method decides; the drive only names its answer.
///  * **the settled readout** — `settled` is `instant` (no route ran: a hop, the
///    teleport fallback `goTo` uses when there is no path, or already standing
///    there), `route_ended` (a route ran and stopped by itself — normally arrival,
///    but a wall or a roster that moved us ends one too, so read `at`), `stopped`
///    (`move.stop` was called during it), `superseded` (another `move.*` walk or hop
///    started before this one ended — without it the first op would sit pending
///    until the *second* route ended and then claim it as its own arrival) or
///    `timeout` (still walking after `timeoutMs`, default 60 s; the walk is *not*
///    cancelled). With `at`, `requested` and `atRequested`, because `goTo` relocates
///    a blocked or occupied tile to the nearest free one — "it ended somewhere else"
///    is often correct. A walk the user cancels on the map's own Stop pill is not
///    seen as a stop here; it reads `route_ended`, short of the goal.
///
/// ## Hops, and why `at` is not enough after one
///
/// After a walk `at` is [AppState.myTile], the walk's own tile. After a hop it is
/// not: the hop releases the walk, so `myTile` falls through to the roster, and on
/// a live socket the roster that carries the new tile arrives up to a quarter of a
/// second *after* the method returns. Reading `at` alone would answer the old tile
/// and `atRequested: false` for a warp that worked. So when the method hopped, the
/// readout also carries `hop` — the tile the teleport was sent to, from
/// [AppState.lastTeleport], i.e. what was asked of Gather, not what it confirmed —
/// and `atRequested` is judged on `hop`. `hopConfirmed` says whether `at` has caught
/// up yet. In the harness the fake confirms synchronously, so the two agree there.
///
/// ## Resolving a name to a thing
///
/// `warpToPerson` takes a contact from [AppState.directory] by `id` (the
/// `SpaceUser` id) or by `name` (their label, case-insensitive; an exact match wins
/// over a prefix, and two matches are `refused('ambiguous_name', {candidates})`
/// rather than a guess). `goToRoom` takes a room from the live map by `id`,
/// `stableId` or `name` the same way. A locked room the user may not enter is
/// `refused('room_locked')` *before* walking — the map screen's own rule
/// ([AppState.canEnter] at the tap), not a new one: Gather refuses that walk by
/// silently stalling it.
library;

import 'dart:async';

import 'package:gather_client/gather_client.dart' show SpaceRoom;

import '../app_state.dart';
import '../directory.dart';
import 'debug_drive.dart';
import 'drive_ops.dart';
import 'drive_result.dart';

/// Default wait before an op answers `settled: "timeout"`.
const _defaultTimeoutMs = 60000;

/// `ext.gc.move.{goTo, warpToTile, warpToPerson, goToRoom, goToMyDesk, stop}`.
DriveFeature moveFeature({
  required AppState Function() app,
  required String Function() boot,
  required DriveOps ops,
}) {
  // Bumped by `move.stop`, so a walk op can tell "stopped" from "ended".
  var stops = 0;
  // Bumped by every walk or hop this feature starts, so an op whose route was
  // replaced by a later one settles as "superseded" rather than inheriting its end.
  var moves = 0;
  // The pending walk ops' checks, re-run after every movement this feature makes:
  // a hop on `goTo`'s no-route branch only ticks positions and need not notify
  // AppState's listeners, so a listener alone could miss being superseded.
  final waiting = <void Function()>{};

  // Movements under way through this feature. A later movement releases the
  // running route *inside* its AppState call, before it has answered: while one is
  // in flight a pending op cannot yet tell "superseded" from "ended", so it waits.
  var inFlight = 0;

  void recheck() {
    for (final check in [...waiting]) {
      check();
    }
  }

  /// Runs an AppState movement; on success bumps [moves]. Answers the method's
  /// refusal (or null) and the movement's generation.
  Future<({String? failed, int mine})> begin(Future<String?> Function() start) async {
    inFlight++;
    String? failed;
    try {
      failed = await start();
    } finally {
      inFlight--;
    }
    if (failed == null) moves++;
    recheck();
    return (failed: failed, mine: moves);
  }

  /// The hop a movement sent, if it sent one since [seqBefore].
  ({int x, int y})? hopSince(int? seqBefore) {
    final hop = app().lastTeleport;
    if (hop == null || hop.seq == seqBefore) return null;
    return (x: hop.x.round(), y: hop.y.round());
  }

  /// `at` / `hop` / `atRequested` / `hopConfirmed`, per "Hops" above.
  Map<String, Object?> arrival(({int x, int y})? requested, ({int x, int y})? hop) {
    final at = app().myTile;
    final landed = hop ?? at;
    return {
      if (hop != null) 'hop': _tile(hop),
      if (hop != null) 'hopConfirmed': at != null && at.x == hop.x && at.y == hop.y,
      if (requested != null) 'requested': _tile(requested),
      if (requested != null)
        'atRequested': landed != null && landed.x == requested.x && landed.y == requested.y,
    };
  }

  Map<String, Object?> where() {
    final state = app();
    final at = state.myTile;
    return {
      'boot': boot(),
      'at': _tile(at),
      'room': at == null ? null : state.map?.roomAt(at.x, at.y)?.name,
      'onRoute': state.onRoute,
      'canWalk': state.canWalk,
      'atMyDesk': state.atMyDesk,
    };
  }

  /// Runs [start] (an AppState movement), then waits for the route it began to end.
  Future<DriveResult> settle(
    Future<String?> Function() start, {
    required int timeoutMs,
    ({int x, int y})? requested,
    Map<String, Object?> extra = const {},
  }) async {
    final state = app();
    final stopsBefore = stops;
    final seqBefore = state.lastTeleport?.seq;
    final (:failed, :mine) = await begin(start);
    if (failed != null) return _refusal(failed, {'boot': boot(), ...extra});
    final hop = hopSince(seqBefore);

    String settled;
    if (!state.onRoute) {
      settled = 'instant';
    } else {
      final done = Completer<String>();
      void check() {
        if (done.isCompleted || inFlight > 0) return;
        if (moves != mine) {
          done.complete('superseded');
        } else if (!state.onRoute) {
          done.complete(stops != stopsBefore ? 'stopped' : 'route_ended');
        }
      }

      state.addListener(check);
      waiting.add(check);
      final timer = Timer(Duration(milliseconds: timeoutMs), () {
        if (!done.isCompleted) done.complete('timeout');
      });
      try {
        settled = await done.future;
      } finally {
        timer.cancel();
        state.removeListener(check);
        waiting.remove(check);
      }
    }

    return DriveResult.ok({
      'settled': settled,
      ...extra,
      ...arrival(requested, hop),
      ...where(),
    });
  }

  /// Starts [work] as a `move` op and answers its id plus what was asked.
  DriveResult asOp(Future<DriveResult> work, Map<String, Object?> asked) =>
      DriveResult.ok({'id': ops.start('move', work), ...asked, 'boot': boot()});

  return DriveFeature('move', [
    DriveAction(
      'goTo',
      (args) async {
        final x = _requireInt(args, 'x');
        final y = _requireInt(args, 'y');
        final timeoutMs = _timeout(args);
        return asOp(
          settle(() => app().goTo(x, y), timeoutMs: timeoutMs, requested: (x: x, y: y)),
          {'requested': {'x': x, 'y': y}, 'timeoutMs': timeoutMs},
        );
      },
      outward: true,
    ),
    DriveAction(
      'warpToTile',
      (args) async {
        final x = _requireInt(args, 'x');
        final y = _requireInt(args, 'y');
        final seqBefore = app().lastTeleport?.seq;
        final (:failed, mine: _) = await begin(() => app().warpToTile(x, y));
        if (failed != null) return _refusal(failed, {'boot': boot()});
        return DriveResult.ok({...arrival((x: x, y: y), hopSince(seqBefore)), ...where()});
      },
      outward: true,
    ),
    DriveAction(
      'warpToPerson',
      (args) async {
        final timeoutMs = _timeout(args);
        final pick = _pickPerson(app().directory, args);
        if (pick is DriveRefused) return pick;
        final contact = (pick as DriveOk).data! as Contact;
        final target = {'id': contact.id, 'name': contact.label};
        return asOp(
          settle(() => app().warpToPerson(contact), timeoutMs: timeoutMs, extra: {'target': target}),
          {'target': target, 'timeoutMs': timeoutMs},
        );
      },
      outward: true,
    ),
    DriveAction(
      'goToRoom',
      (args) async {
        final timeoutMs = _timeout(args);
        _requireSelector(args, const ['id', 'stableId']);
        final state = app();
        final map = state.map;
        if (map == null) return DriveResult.refused('no_map', {'boot': boot()});
        final pick = _pickRoom(map.rooms, args);
        if (pick is DriveRefused) return pick;
        final room = (pick as DriveOk).data! as SpaceRoom;
        final target = {'id': room.id, 'stableId': room.stableId, 'name': room.name};
        if (room.locked && !state.canEnter(room)) {
          return DriveResult.refused('room_locked', {'room': target, 'boot': boot()});
        }
        final toward = (x: room.x + room.width ~/ 2, y: room.y + room.height ~/ 2);
        return asOp(
          settle(() => app().goToRoom(room, toward: toward), timeoutMs: timeoutMs, extra: {'room': target}),
          {'room': target, 'timeoutMs': timeoutMs},
        );
      },
      outward: true,
    ),
    DriveAction(
      'goToMyDesk',
      (args) async {
        final timeoutMs = _timeout(args);
        return asOp(settle(() => app().goToMyDesk(), timeoutMs: timeoutMs), {'timeoutMs': timeoutMs});
      },
      outward: true,
    ),
    DriveAction('stop', (args) async {
      final wasOnRoute = app().onRoute;
      stops++;
      app().stopWalking();
      return DriveResult.ok({'wasOnRoute': wasOnRoute, ...where()});
    }),
  ]);
}

Map<String, int>? _tile(({int x, int y})? t) => t == null ? null : {'x': t.x, 'y': t.y};

int _requireInt(Map<String, Object?> args, String key) =>
    args.optionalInt(key, min: 0, max: 100000) ?? (throw DriveInvalidParams('"$key" is required'));

int _timeout(Map<String, Object?> args) =>
    args.optionalInt('timeoutMs', min: 100, max: 600000) ?? _defaultTimeoutMs;

/// The AppState sentence → a stable reason. Matched on the method's own words,
/// which are its contract with the screens; anything unrecognised is `declined`
/// and still carries the sentence, so a reworded message degrades, not breaks.
DriveResult _refusal(String message, Map<String, Object?> extra) {
  String reason;
  if (message == 'Still reading the floor plan.') {
    reason = 'no_map';
  } else if (message == 'Not connected to Gather.') {
    reason = 'not_connected';
  } else if (message.startsWith('No connection')) {
    reason = 'link_disrupted';
  } else if (message == 'Still working out where you are.') {
    reason = 'position_unknown';
  } else if (message == 'There is nowhere to stand there.') {
    reason = 'nowhere_to_stand';
  } else if (message == 'Gather has not given you a desk.') {
    reason = 'no_desk';
  } else if (message.endsWith('is not in the office right now.')) {
    reason = 'person_absent';
  } else if (message.startsWith("Can't tell where")) {
    reason = 'person_unplaced';
  } else if (message.endsWith('is on another floor.')) {
    reason = 'other_floor';
  } else if (message.startsWith('There is nowhere free in')) {
    reason = 'room_full';
  } else {
    reason = 'declined';
  }
  return DriveResult.refused(reason, {...extra, 'message': message});
}

/// Throws [DriveInvalidParams] unless one of [idKeys] or `name` is given — read
/// before any state is, so a malformed call is never answered as a refusal.
void _requireSelector(Map<String, Object?> args, List<String> idKeys) {
  final keys = [...idKeys, 'name'];
  if (keys.every((k) => args[k] == null)) {
    throw DriveInvalidParams('one of ${keys.map((k) => '"$k"').join(', ')} is required');
  }
}

/// One of [candidates] by `id` field [idKeys] or by `name`, or a refusal.
DriveResult _pick<T>(
  List<T> candidates,
  Map<String, Object?> args, {
  required List<String> idKeys,
  required Map<String, Object?> Function(T) describe,
  required String? Function(T) nameOf,
  required String? Function(T, String key) idOf,
  required String noun,
}) {
  for (final key in idKeys) {
    if (args[key] == null) continue;
    final want = args.requireString(key);
    for (final c in candidates) {
      if (idOf(c, key) == want) return DriveResult.ok(c);
    }
    return DriveResult.refused('no_such_$noun', {key: want});
  }
  _requireSelector(args, idKeys);
  final want = args.requireString('name').toLowerCase();
  final exact = [for (final c in candidates) if (nameOf(c)?.toLowerCase() == want) c];
  final matches = exact.isNotEmpty
      ? exact
      : [for (final c in candidates) if (nameOf(c)?.toLowerCase().startsWith(want) ?? false) c];
  if (matches.isEmpty) return DriveResult.refused('no_such_$noun', {'name': args['name']});
  if (matches.length > 1) {
    return DriveResult.refused('ambiguous_name', {
      'name': args['name'],
      'candidates': [for (final c in matches) describe(c)],
    });
  }
  return DriveResult.ok(matches.single);
}

DriveResult _pickPerson(List<Contact> directory, Map<String, Object?> args) => _pick<Contact>(
      directory,
      args,
      idKeys: const ['id'],
      describe: (c) => {'id': c.id, 'name': c.label, 'present': c.isPresent},
      nameOf: (c) => c.label,
      idOf: (c, _) => c.id,
      noun: 'person',
    );

DriveResult _pickRoom(List<SpaceRoom> rooms, Map<String, Object?> args) => _pick<SpaceRoom>(
      rooms,
      args,
      idKeys: const ['id', 'stableId'],
      describe: (r) => {'id': r.id, 'stableId': r.stableId, 'name': r.name},
      nameOf: (r) => r.name,
      idOf: (r, key) => key == 'id' ? r.id : r.stableId,
      noun: 'room',
    );
