/// Interprets Gather V2's game-server protocol.
///
/// A port of `bridge/lib/game-protocol.js`. One binary WebSocket to
/// `wss://game-router.v2.gather.town/gather-game-v2?spaceId=<uuid>&authUserId=<firebaseUid>`
/// carrying msgpack frames. [DirectCollector] opens it and authenticates as the
/// user. Reading the whole space needs only `loadSpaceUser`; the app goes on to
/// send `enterSpace` as well, because it is heading towards carrying a call, but
/// nothing in this file depends on that — every field below arrives either way.
///
/// ## Wire format
///
/// State arrives as patches against model rows, in two envelopes:
///   - `FullStateChunk.fullStatePatches[]` — the initial dump, sent once per
///     connection, ~1500 patches per chunk across ~49 models.
///   - `DeltaState.patches[]` — everything after that.
///
/// Three patch ops exist, and they are *not* JSON-Patch:
///   - `{op:'addmodel',    model, data}`            whole row; the id is inside `data`
///   - `{op:'deletemodel', model, id}`              row removed
///   - `{op:'replace',     model, id, path, data}`  one field, e.g. `/position/x`
///
/// ## The signal
///
/// **Someone is following me** — `SpaceUser.followTargetId` pointing at my own
/// row. It is an optional column, so it arrives as msgpack `undefined` rather than
/// null when nobody is being followed, and shows up as a `replace` on
/// `/followTargetId`.
///
/// ## The event bus
///
/// `DeltaState` carries a **third** array beside `patches`: `events[]`. It is news
/// rather than state:
///
///   {type:'DeltaState', patches:[], events:[
///      {payload:{eventName:'WaveEvent', senderId:'…', sentTime:'…'},
///       options:{targetUserIds:['…']}}]}
///
/// Measured 2026-08-07: `WaveEvent` and `ChatBroadcastNewMessage`, on an
/// **observer** connection — so `enterSpace` is not required to hear them. A frame
/// carrying only `events[]` has an empty `patches` array, which is exactly how the
/// bus went unread in the bridge for weeks.
///
/// ## Identity
///
/// Which row is *me* is answered by the `Connection` model, which carries both
/// halves: `{authUserId: <firebase uid>, spaceUserId: <my SpaceUser id>}`. The
/// firebase uid comes from our own ID token. `UserAccount` (`{id, firebaseAuthId}`)
/// plus `SpaceUser.userAccountId` gives a second, slower route.
library;

import 'dart:convert';

import 'avatar.dart';
import 'msgpack.dart';
import 'space_map.dart';

/// Only these models matter; a full state dump is mostly calendars and catalogs.
const _models = {
  'SpaceUser',
  'Connection',
  'UserAccount',
  'Space',
  // The floor plan. Party mode needs to know which tiles exist before it can
  // pick one, and the map screen draws them. See [SpaceMapBuilder].
  'FloorMap',
  'MapArea',
  'MapObject',
  'CatalogItemVariant',
  // `family`, which decides whether an object can be wall-snapped and so whether
  // it collides at all.
  'CatalogItem',
  // Whether a room's door is shut. `MapArea` does not carry it; it hangs off the
  // identifier row the area points at. 93 rows on the measured space.
  'MapEntityIdentifier',
  // Meetings, for the two things somebody can do *at* you that are recorded as
  // state rather than sent over the event bus. See [_MeetingWatch].
  'MeetingParticipant',
  'MeetingJoinRequest',
  // A locked meeting room admits whoever its meeting lists, so the door needs these
  // as well as the notifications do. See `SpaceMapBuilder._admitted`.
  'AreaAccessRequest',
  'Meeting',
  // What people look like. Neither model answers on its own: `hashOutfit` joins an
  // outfit's wearable ids and appends the newest `lastSyncAuthoredAt` among them,
  // so the sprite URL needs both. See `avatar.dart`.
  'SpaceUserOutfit',
  'Wearable',
  // The line under somebody's name. Kept because `SpaceUser` carries no readable
  // pointer to it — see [_noteStatus] — so this row is the only route to it.
  'SpaceUserStatus',
};

/// The map models, routed to [SpaceMapBuilder] rather than to the roster.
const _mapModels = {
  'FloorMap',
  'MapArea',
  'MapObject',
  'CatalogItemVariant',
  'CatalogItem',
  'MapEntityIdentifier',
  // Who a locked area lets in anyway. Both hang off `MapEntityIdentifier` by
  // `areaId`, which is why they are map rows rather than presence: they describe a
  // door, not a person. See `SpaceMapBuilder._admitted`.
  'AreaAccessRequest',
  'Meeting',
};

/// SpaceUser fields worth tracking, for field-level `replace` patches.
///
/// `speaking` earns its place: measured over three minutes on a 111-person space
/// it was the most frequent delta of any kind. It is live voice activity — who is
/// actually talking.
///
/// `clusterId` is the conversation. Gather's client computes proximity itself, but
/// it does not compute *this*: the server groups people who are talking together
/// and publishes the grouping, and the desktop client's own A/V pipeline reads it
/// in `connectStronglyToPlayersInSameCluster`. Sharing a non-null `clusterId` with
/// somebody is what the video bubble means. Without this entry the `replace` patch
/// on `/clusterId` is dropped and a bubble forming looks like nothing happening.
const _trackedFields = {
  'followTargetId',
  'position',
  'floorId',
  'name',
  'connected',
  'isIdle',
  'speaking',
  // Whether they are dancing, which is the one pose that is *only* knowable from
  // the wire. Sitting is derived from the tile and talking from `speaking`, but
  // nothing about a position says somebody pressed the dance key — so without this
  // field the sheet's dance cycle (frames 12–15) can never be selected and a
  // dancing colleague renders as standing perfectly still.
  'dancing',
  'clusterId',
  'userAccountId',
  // Which way somebody is facing. Only the map cares, and only since it started
  // drawing bodies rather than dots: an avatar sheet has a frame per direction and
  // without this everybody stands facing the camera while walking north.
  'direction',
  // How fast they are going — 1, 2 or 3. Also the only thing that says whether
  // somebody is in a go-kart: there is no vehicle field, the client draws one under
  // anybody whose modifier reached 3.
  'speed',
  // Whether they are actually there. `connected` alone is not that — see
  // [RosterRow.availability].
  'userSetAvailability',
  // The face. A `UserFile` id when somebody has set a picture and absent when
  // they have not — measured on a live space, 45 of 98 rows carried one. It is
  // not a URL and cannot be turned into one here: see `profile_photos.dart`.
  'profilePictureId',
  // Which desk is theirs. A `MapEntityIdentifier` id, so it matches
  // [SpaceRoom.stableId] and never `SpaceRoom.id`. Tracked because it is the only
  // way to answer "where do I belong", which is what "back to my desk" asks; it
  // also changes under you when a desk manager reassigns one, and the whole point
  // of tracking a field rather than remembering it is that the answer follows.
  'deskId',
  // Whether their hand is up in a meeting. The wire carries a *timestamp*,
  // `handRaisedAt`, not a bool — set when the hand goes up and `undefined` when it
  // comes down (see [RosterRow.handRaised]). Tracked so a lowering patch, which
  // arrives as a `replace` to `undefined`, is not dropped and a hand left stuck up.
  'handRaisedAt',
};

/// One interaction off `DeltaState.events[]`.
///
/// The two things a caller always needs sit in different halves of the envelope:
/// who did it is `payload.senderId`, and who they did it *at* is
/// `options.targetUserIds`. Normalised here so callers do not have to know that.
class BusEvent {
  const BusEvent({
    required this.name,
    required this.senderId,
    required this.sentTime,
    required this.targetUserIds,
    required this.payload,
  });

  /// `WaveEvent`, `ChatBroadcastNewMessage`, … — Gather's own `eventName`.
  final String name;
  final String? senderId;

  /// The sender's own clock, as an ISO-8601 string. Gather sends a plain string
  /// today, but `createdAt`-style fields on this protocol are msgpack ext-1
  /// DateTimes, so both are accepted and normalised.
  final String? sentTime;
  final List<String> targetUserIds;

  /// The payload untouched, so a new `eventName` is readable without a change here.
  final Map<String, Object?> payload;

  /// Whether this was aimed at [spaceUserId].
  bool isFor(String? spaceUserId) =>
      spaceUserId != null && targetUserIds.contains(spaceUserId);

  @override
  String toString() => 'BusEvent($name from $senderId -> $targetUserIds)';
}

/// The server's verdict on one action we sent, off `actionReturns[]`.
///
/// Actions are request/response over the same socket, keyed by the `txnId` the
/// client generated:
///
/// ```jsonc
/// {connectionId, txnId, result: {type: 'Success', value: '1fdcb187-…'}}
/// {connectionId, txnId, result: {type: 'Error',   error: '<prose or zod JSON>'}}
/// ```
///
/// Reading these is the only way to learn that something did not happen.
/// Validation runs before the action does, so a wrong-shaped argument executes
/// nothing and produces no patch — and a client that watches only patches cannot
/// tell that apart from a slow network. Acks are private to the socket that sent
/// the action, so every one of these is ours.
class ActionResult {
  const ActionResult({required this.txnId, required this.ok, this.error, this.value});

  final String txnId;
  final bool ok;

  /// What the server said, when it said no. Either a readable sentence
  /// (*"Cannot wave at yourself"*) or a JSON zod issue list. Left raw here;
  /// [describeActionError] turns it into something to show a person.
  final String? error;

  /// `result.value` on a success, which for most actions is the row's id.
  final Object? value;

  @override
  String toString() => 'ActionResult($txnId, ${ok ? 'Success' : 'Error: $error'})';
}

/// Turns a server refusal into one sentence.
///
/// Two flavours arrive, and the difference is worth keeping: business rules come
/// back as prose and are already the right thing to show, while schema violations
/// come back as a zod issue list — a JSON array whose entries carry `message` and
/// a `path`. The first issue is the useful one; the rest are usually the same
/// mistake seen from other angles.
String describeActionError(String? error) {
  final raw = error?.trim() ?? '';
  if (raw.isEmpty) return 'Gather refused it without saying why';
  if (!raw.startsWith('[') && !raw.startsWith('{')) return raw;

  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on Object {
    return raw;
  }
  final issues = decoded is List ? decoded : (decoded is Map ? [decoded] : const []);
  for (final issue in issues) {
    if (issue is! Map) continue;
    final message = issue['message'];
    if (message is! String || message.isEmpty) continue;
    final path = issue['path'];
    final field = path is List ? path.whereType<Object>().join('.') : '';
    return field.isEmpty ? message : '$field: $message';
  }
  return raw;
}

/// One person in the space, as far as a state dump plus deltas can tell.
class RosterRow {
  const RosterRow({
    required this.id,
    this.name,
    this.x,
    this.y,
    this.floorId,
    this.connected,
    this.speaking,
    this.dancing,
    this.followTargetKnown = false,
    this.followTargetId,
    this.clusterIdKnown = false,
    this.clusterId,
    this.userAccountId,
    this.direction,
    this.speed,
    this.availability,
    this.profilePictureId,
    this.deskId,
    this.status,
    this.handRaised = false,
  });

  final String id;
  final String? name;

  /// Kept for party mode's walkable-tile pool, not for judging adjacency.
  final num? x;
  final num? y;
  final String? floorId;
  final bool? connected;
  final bool? speaking;

  /// Whether they are dancing. Null before the field has ever arrived, which the
  /// map reads as "not dancing" — the same way it reads a missing `direction` as
  /// south.
  final bool? dancing;

  /// Whether `followTargetId` was present on the row at all.
  ///
  /// The distinction the JS carried by omitting the key entirely: without it,
  /// "nobody is following me" and "I cannot tell" look identical, and the app
  /// would render a confident empty state out of missing data.
  final bool followTargetKnown;
  final String? followTargetId;

  /// Whether `clusterId` was present on the row at all.
  ///
  /// The same absent-versus-null distinction [followTargetKnown] draws, and it
  /// matters more here because something acts on it: standing alone is
  /// `clusterId: null`, while not-yet-known is the key being missing. Treating
  /// them alike means either opening a call with nobody in it or never opening
  /// one at all.
  final bool clusterIdKnown;

  /// The conversation this person is in, if any. Two people sharing a non-null
  /// value are in the same bubble.
  final String? clusterId;

  /// Their `UserAccount.id` — **the media plane's name for them**, and not the
  /// same thing as [id], which is their `SpaceUser.id`.
  ///
  /// The two planes are keyed on different identities: the game socket talks in
  /// `SpaceUser`, the SFU talks in `UserAccount`, and `srcId` on the wire is this
  /// one. Measured 2026-08-13 — asking the router about a `SpaceUser.id` returns
  /// a stream that does not exist, silently, which is Gather's usual way of
  /// saying no. Null until the row's `userAccountId` has arrived, which is why
  /// anything joining a call has to tolerate a member it cannot yet address.
  final String? userAccountId;

  /// `Up`, `Down`, `Left` or `Right` — which way the body is facing.
  ///
  /// `direction.value`, not `direction`: the wire carries a value object,
  /// `{$type: 'Direction', value: 'Right'}`, exactly as `userSetAvailability` does.
  /// Null before it has ever been sent, which the map reads as facing south, exactly
  /// as the client does — which is why reading this field wrongly does not look like
  /// a parsing bug, it looks like an office where everybody stares at the floor.
  final String? direction;

  /// `1`, `2` or `3` — `speed.modifier`, walking, running or driving a go-kart.
  ///
  /// A third value object of the same family, and the only field of the three whose
  /// inner name is not `value`. Absent on anybody standing still, because the client
  /// sends it as the gear changes rather than continuously — so null means walking,
  /// which is what [gaitOf] does with it.
  ///
  /// This is the whole of Gather's go-kart on the wire. There is no vehicle model and
  /// no ride action: `PlayerEntityRenderer` puts a kart under anybody at 3 and takes
  /// it away again when they drop back to 1.
  final num? speed;

  /// `Active`, `Busy` or `Offline` — `userSetAvailability.value`, and the only field
  /// that answers "are they actually there".
  ///
  /// **`connected` does not.** Measured 2026-08-13 against a 98-row space: twelve
  /// rows carried `connected: true` and nine of those were `Offline`, some of them
  /// for a day. A socket that goes away without saying goodbye leaves `connected`
  /// true behind it, so a client trusting that field alone draws bodies where the
  /// desktop app shows nobody and reports eleven people in an office holding three.
  /// Neither field is sufficient on its own — availability alone counted 31, because
  /// people leave it on `Active` when they close the app — so presence is the pair:
  /// connected *and* not `Offline`.
  final String? availability;

  /// The `UserFile` id of their profile picture, or null if they have not set
  /// one. Resolve it with `ProfilePhotos`; it is not itself fetchable.
  final String? profilePictureId;

  /// The desk assigned to them, as a `MapEntityIdentifier` id, or null if they
  /// have not claimed one. Matches [SpaceRoom.stableId], never `SpaceRoom.id`.
  final String? deskId;

  /// The line under their name, if it has not expired.
  final PersonStatus? status;

  /// Whether their hand is up in a meeting.
  ///
  /// The wire carries no bool: a raised hand is a `handRaisedAt` *timestamp*, and
  /// a lowered one is that field as msgpack `undefined` — the ext-4 sentinel this
  /// protocol maps to [msgpackUndefined], **not** null and **not** absent. So "up"
  /// is "the field arrived and holds something other than undefined", which is what
  /// [DeltaState] distils this bool down to; a client reading `handRaisedAt != null`
  /// would see every lowered hand as still up. Defaults false — nobody starts with
  /// a hand up, and a row that has never carried the field reads as down.
  final bool handRaised;

  /// Connected, and not away. See [availability].
  bool get isPresent => connected == true && availability != 'Offline';
}

/// The three a person can choose, in the order Gather's own picker offers them.
///
/// `Offline` is missing on purpose, and so are `Focused` and `FocusedCoworking`:
/// the first is written by the server when a connection goes away, and the other
/// two are set by entering a focus area rather than by picking them. All of them
/// can arrive on [RosterRow.availability]; only these three can be sent.
const settableAvailabilities = ['Active', 'Busy', 'Away'];

/// A whole roster, as [PresenceTracker] consumes it.
class Roster {
  const Roster({required this.selfId, required this.rows, this.spaceName});

  final String? selfId;
  final List<RosterRow> rows;
  final String? spaceName;

  /// The conversation we are in, by Gather's own id, or null when standing alone.
  ///
  /// The media plane wants this as well as the membership: the desktop client
  /// sends `set-player-conversation-metadata {meetingId, clusterId}` so the SFU
  /// knows which bubble a publisher belongs to. Null and absent are the same
  /// answer here — both mean "no conversation to name".
  String? get myClusterId {
    final me = selfId;
    if (me == null) return null;
    for (final row in rows) {
      if (row.id == me) return row.clusterId;
    }
    return null;
  }

  /// The people in the same conversation as us, excluding ourselves.
  ///
  /// Empty when we are standing alone, when we do not yet know who we are, or
  /// when the dump has not carried our `clusterId` — all three are honestly "no
  /// call", and none of them is worth distinguishing to a caller deciding whether
  /// to open one.
  ///
  /// Disconnected rows are dropped: a cluster outlives the moment somebody's
  /// socket dies, so without this a call would keep a tile for someone who has
  /// already gone.
  List<RosterRow> get myCluster {
    final me = selfId;
    if (me == null) return const [];
    String? mine;
    for (final row in rows) {
      if (row.id == me) {
        mine = row.clusterId;
        break;
      }
    }
    if (mine == null) return const [];
    return [
      for (final row in rows)
        if (row.id != me && row.clusterId == mine && row.connected != false) row,
    ];
  }

  /// Everybody close enough to see and hear you — Gather's own `inRange`.
  ///
  /// Transcribed from the client: same floor, and squared euclidean distance
  /// under `DIST_THRESHOLD * DIST_THRESHOLD` with `DIST_THRESHOLD = 12`. It is
  /// the input to `playerMediaMags`, and the set the desktop client keys its
  /// **allow list** on.
  ///
  /// This is a wider circle than [myCluster] and the difference is the whole
  /// point. A cluster is a conversation you have joined; being *in range* is
  /// merely being near enough that Gather draws your camera in a little circle
  /// over your head. Allowing only your cluster means nobody standing beside you
  /// may consume your video, so that circle never appears — which is exactly how
  /// this was first reported.
  ///
  /// Positions can be absent on a row that has not moved since the dump; those
  /// are excluded rather than treated as origin, because (0,0) is a real tile and
  /// would put strangers in the top-left corner permanently in range.
  List<RosterRow> get nearby {
    final me = selfId;
    if (me == null) return const [];

    RosterRow? mine;
    for (final row in rows) {
      if (row.id == me) {
        mine = row;
        break;
      }
    }
    final x = mine?.x;
    final y = mine?.y;
    if (mine == null || x == null || y == null) return const [];

    const threshold = 12 * 12;
    return [
      for (final row in rows)
        if (row.id != me && row.connected != false && row.floorId == mine.floorId)
          if (row.x case final rx?)
            if (row.y case final ry?)
              if ((rx - x) * (rx - x) + (ry - y) * (ry - y) < threshold) row,
    ];
  }
}

/// Mutable accumulator for one SpaceUser as patches arrive.
class _Row {
  _Row(this.id);

  final String id;
  String? name;
  num? x;
  num? y;
  String? floorId;
  bool? connected;
  bool? isIdle;
  bool? speaking;
  bool? dancing;
  bool? isBot;
  String? kind;
  String? userAccountId;
  bool followTargetKnown = false;
  String? followTargetId;
  bool clusterIdKnown = false;
  String? clusterId;
  String? direction;
  num? speed;
  String? availability;
  String? profilePictureId;
  String? deskId;
  bool handRaised = false;
  bool gone = false;
}

/// The line under somebody's name: "Lunch 🥗", "Heads down 🎧".
///
/// Two kinds arrive on the same model and both are worth showing. [type] `Custom`
/// is one a person typed; `CalendarInferred` is one Gather wrote from their
/// calendar, which is why half a busy office has a status nobody set by hand.
class PersonStatus {
  const PersonStatus({
    required this.text,
    this.emoji,
    required this.type,
    this.clearAt,
  });

  final String text;
  final String? emoji;

  /// `Custom` or `CalendarInferred`.
  final String type;

  /// When Gather drops it by itself, if it said.
  final DateTime? clearAt;

  bool get isCustom => type == 'Custom';

  /// Whether this has outlived its own expiry.
  ///
  /// It has to be asked rather than assumed, because **the row outlives the
  /// status**: an expired one is still in the state dump, unchanged, with a
  /// `clearAt` in the past. Measured — a status set at 16:33 to clear at 17:03
  /// was still on the wire at 20:20. Gather's own client evidently filters on
  /// read, so a client that does not shows people at lunch all evening.
  bool expiredAt(DateTime now) => clearAt != null && !clearAt!.isAfter(now);

  @override
  String toString() => 'PersonStatus(${emoji ?? ''}$text, $type)';
}

class GameProtocolReader {
  GameProtocolReader({void Function(String)? log}) : _log = log ?? _noop;

  /// The floor plan, accumulated from the same patch stream as everything else and
  /// rebuilt only when one of its models actually moves.
  final SpaceMapBuilder mapBuilder = SpaceMapBuilder();

  static void _noop(String _) {}

  final void Function(String) _log;

  /// SpaceUser id -> row we have assembled.
  final Map<String, _Row> _users = {};

  /// My own SpaceUser id, once identified.
  String? selfId;

  /// Firebase uid, from our own ID token.
  String? authUserId;
  String? spaceId;

  /// The space's display name, from the single `Space` row in the dump.
  String? spaceName;

  /// UserAccount id belonging to me, the slower route to [selfId].
  String? _myUserAccountId;

  /// Status rows, by their own id. See [_noteStatus] for why not by person.
  final Map<String, ({String owner, PersonStatus status})> _statuses = {};

  /// My `UserAccount` id, which is a different identity from [selfId].
  ///
  /// The game plane keys on `SpaceUser` and the media plane on `UserAccount`, so
  /// this is what the SFU router wants as `srcId`. Handing it [selfId] instead
  /// returns a stream that does not exist — silently, which is Gather's usual way
  /// of refusing something.
  String? get selfAccountId => _myUserAccountId;

  /// Meetings, for the two things somebody can do at you that are state, not bus.
  final _MeetingWatch _meetings = _MeetingWatch();

  /// Interaction events waiting to be drained.
  ///
  /// Queued rather than delivered inline, so [ingest]'s "did the roster change"
  /// answer keeps its meaning — a wave changes no state at all.
  final List<BusEvent> _pending = [];

  /// Action verdicts waiting to be drained, oldest first.
  final List<ActionResult> _results = [];

  /// The highest `sequenceNumber` the server has sent us.
  ///
  /// Strictly increasing across a connection, and what the client's own outgoing
  /// heartbeat reports back: measured 2026-08-14, the desktop client's
  /// `Heartbeat.sequenceNumber` ran 121 → 178 while the server's ran 124 → 178, so
  /// it is echoing the last sequence it has seen rather than counting its own
  /// sends. Null until the first `FullStateChunk` or `DeltaState` arrives.
  int? lastSequence;

  final Map<String, int> _frameTypes = {};
  int _unknownFrames = 0;
  int _patchCount = 0;
  int _busEvents = 0;
  int _actionErrors = 0;

  int get userCount => _users.length;

  /// Hands over the queued interaction events and forgets them.
  List<BusEvent> takePending() {
    if (_pending.isEmpty) return const [];
    final out = List<BusEvent>.of(_pending);
    _pending.clear();
    return out;
  }

  /// Hands over the queued action verdicts and forgets them.
  List<ActionResult> takeResults() {
    if (_results.isEmpty) return const [];
    final out = List<ActionResult>.of(_results);
    _results.clear();
    return out;
  }

  /// Learns identity hints from the WebSocket URL we opened.
  void noteSocketUrl(String url) {
    final parsed = Uri.tryParse(url);
    if (parsed == null) return;
    authUserId = parsed.queryParameters['authUserId'] ?? authUserId;
    spaceId = parsed.queryParameters['spaceId'] ?? spaceId;
  }

  Map<String, Object?> stats() => {
        'users': _users.length,
        'selfId': selfId,
        'spaceId': spaceId,
        'patches': _patchCount,
        'busEvents': _busEvents,
        'actionErrors': _actionErrors,
        'sequence': lastSequence,
        'unknownFrames': _unknownFrames,
        'frameTypes': (_frameTypes.entries.toList()
              ..sort((a, b) => b.value.compareTo(a.value)))
            .take(12)
            .map((e) => '${e.key}:${e.value}')
            .toList(),
      };

  /// Feed one decoded frame. Returns true when the roster changed in a way worth
  /// republishing.
  bool ingest(Object? frame) {
    if (frame is! Map<String, Object?>) return false;

    final type = frame['type'] is String ? frame['type'] as String : '(untyped)';
    _frameTypes[type] = (_frameTypes[type] ?? 0) + 1;

    // Heartbeats are the bulk of the traffic and carry nothing. Their own
    // `sequenceNumber` is absent — only the state envelopes carry it — so this
    // returns before the sequence is read, deliberately.
    if (type == 'Heartbeat') return false;

    // The server's own counter, strictly increasing, which our heartbeat reports
    // back. Read from every state envelope rather than only the dump.
    final sequence = frame['sequenceNumber'];
    if (sequence is int && (lastSequence == null || sequence > lastSequence!)) {
      lastSequence = sequence;
    }

    // Before the patches, because a wave arrives in a frame whose `patches` array
    // is empty — which is exactly how it went unnoticed for so long.
    final bus = _collectBusEvents(frame);
    for (final event in bus) {
      _pending.add(event);
      _busEvents++;
    }

    // The same trap one field over: an action that was *refused* produces no patch
    // at all, so a frame can carry nothing but `actionReturns` and would otherwise
    // fall through to `_unknownFrames` exactly as the event bus used to.
    final acks = _collectActionResults(frame);
    for (final result in acks) {
      _results.add(result);
      if (!result.ok) _actionErrors++;
    }

    // The dump and the deltas are read separately, because for anything
    // event-shaped the difference is the whole signal. `MeetingParticipant` rows
    // arrive in both: 56 of them in the measured space, four naming us. Treating a
    // dump row as news would announce every meeting we have ever been invited to,
    // on every reconnect — and this collector reconnects whenever the phone wakes.
    final dump = _patchesIn(frame['fullStatePatches']);
    final deltas = _patchesIn(frame['patches']);
    final patches = [...dump, ...deltas];
    if (patches.isEmpty) {
      // Frames that legitimately carry no model state (Authenticate, Subscribe,
      // SpaceStatus, …) — but a frame we *did* understand as an interaction or as
      // the answer to something we sent is not unrecognised.
      if (bus.isEmpty && acks.isEmpty) _unknownFrames++;
      return false;
    }

    var changed = false;
    for (final patch in dump) {
      if (_applyPatch(patch, isNews: false)) changed = true;
    }
    for (final patch in deltas) {
      if (_applyPatch(patch, isNews: true)) changed = true;
    }
    if (changed || selfId == null) _identifySelf();

    // Identity can arrive after the rows that depend on it — the `Connection` row
    // is one patch among ~1500 — so anything we could not judge at the time is
    // reconsidered once we know who we are.
    if (selfId != null) _meetings.resolvePending(selfId!, _pending);
    return changed;
  }

  bool _applyPatch(Map<String, Object?> patch, {required bool isNews}) {
    final model = patch['model'];
    if (model is! String || !_models.contains(model)) return false;
    _patchCount++;

    if (model == 'SpaceUserOutfit' || model == 'Wearable') {
      _applyAvatarModel(model, patch);
      // Never "the roster changed": what somebody is wearing does not move them, and
      // the map reads outfits through [avatarUrlFor] when it paints. 66 outfits and
      // 157 wearables arrive in the dump, which would otherwise be 223 republished
      // rosters for a screen that has not opened yet.
      return false;
    }

    if (_mapModels.contains(model)) {
      // Never "the roster changed": a map edit is not somebody moving, and
      // republishing an 80-row roster because a plant was dragged is exactly the
      // traffic the coalescing window exists to prevent. The map is read from
      // `mapBuilder` when it is wanted.
      mapBuilder.apply(model, patch);
      return false;
    }

    if (model == 'MeetingParticipant' || model == 'MeetingJoinRequest') {
      // The floor plan wants the participant rows too — a locked room admits the
      // people its meeting lists — and it must be told here rather than by adding the
      // model to [_mapModels], because that branch returns before this one and the
      // invite notifications would stop arriving.
      mapBuilder.apply(model, patch);
      _meetings.apply(model, patch, isNews: isNews, selfId: selfId, out: _pending);
      // Never "the roster changed": meetings are not people standing in a room, and
      // republishing a 79-row snapshot because a calendar row moved is exactly the
      // traffic the coalescing window exists to prevent.
      return false;
    }

    switch (patch['op']) {
      case 'addmodel':
        return _addModel(model, patch['data']);
      case 'deletemodel':
        return _deleteModel(model, patch['id']);
      case 'replace':
        return _replaceField(model, patch);
      default:
        return false;
    }
  }

  /// SpaceUser id -> the wearable ids they have on.
  final Map<String, Map<String, Object?>> _outfits = {};

  /// Wearable id -> when it was last authored, which is half of the sprite URL.
  final Map<String, DateTime> _wearableAuthoredAt = {};

  /// The avatar spritesheet for somebody, or null if we cannot name their outfit.
  ///
  /// Null is normal rather than exceptional: only 66 of 111 people in the measured
  /// dump had a `SpaceUserOutfit` row at all, and somebody with no outfit has no
  /// sprite to ask for. The map draws them as the ghost, as the client does.
  String? avatarUrlFor(String spaceUserId) {
    final outfit = _outfits[spaceUserId];
    if (outfit == null) return null;
    final hash = hashOutfit(outfit, (id) => _wearableAuthoredAt[id]);
    return hash == null ? null : avatarSpriteUrl(hash);
  }

  void _applyAvatarModel(String model, Map<String, Object?> patch) {
    final data = patch['data'];
    switch (patch['op']) {
      case 'addmodel':
        if (data is! Map<String, Object?>) return;
        if (model == 'Wearable') {
          final id = data['id'];
          final at = data['lastSyncAuthoredAt'];
          if (id is String && at is DateTime) _wearableAuthoredAt[id] = at;
          return;
        }
        final spaceUserId = data['spaceUserId'];
        if (spaceUserId is String) _outfits[spaceUserId] = {...data};
      case 'replace':
        // A changed hat arrives as `/hat`, not as a fresh row.
        if (model != 'SpaceUserOutfit') return;
        final id = patch['id'];
        if (id is! String) return;
        final field =
            (patch['path'] as String? ?? '').split('/').where((s) => s.isNotEmpty).firstOrNull;
        if (field == null) return;
        for (final outfit in _outfits.values) {
          if (outfit['id'] != id) continue;
          outfit[field] = data;
          return;
        }
      case 'deletemodel':
        if (model != 'SpaceUserOutfit') return;
        _outfits.removeWhere((_, outfit) => outfit['id'] == patch['id']);
    }
  }

  bool _addModel(String model, Object? raw) {
    if (raw is! Map<String, Object?>) return false;
    final id = raw['id'];
    if (id is! String) return false;

    if (model == 'SpaceUser') return _merge(_row(id), raw);

    // The status line, which joins the *other* way round from everything else
    // here. `SpaceUser` carries `activeCustomStatusId` and
    // `activeUserGeneratedStatusId`, and on a live 98-row space **neither was
    // ever set** — both were absent on every row, including rows whose status
    // was on screen at the time. The row carries `spaceUserId` instead, so the
    // link is read from this side.
    if (model == 'SpaceUserStatus') return _noteStatus(id, raw);

    if (model == 'Connection') {
      // The direct answer to "which SpaceUser am I".
      final spaceUserId = raw['spaceUserId'];
      if (authUserId != null && raw['authUserId'] == authUserId && spaceUserId is String) {
        if (selfId != spaceUserId) {
          selfId = spaceUserId;
          _log('game protocol: own space user $spaceUserId (via Connection)');
          return true;
        }
      }
      return false;
    }

    if (model == 'UserAccount') {
      if (authUserId != null && raw['firebaseAuthId'] == authUserId) {
        _myUserAccountId = id;
        return true;
      }
      return false;
    }

    if (model == 'Space') {
      // Exactly one row, and it is the space we asked for.
      final name = raw['name'];
      if (name is String && name != spaceName) {
        spaceName = name;
        return true;
      }
      return false;
    }

    return false;
  }

  bool _deleteModel(String model, Object? id) {
    if (id is! String) return false;
    // Clearing a status deletes its row, which is the only signal that it is
    // gone — the `SpaceUser` side carries no pointer to drop.
    if (model == 'SpaceUserStatus') return _statuses.remove(id) != null;
    if (model != 'SpaceUser') return false;
    final row = _users[id];
    if (row == null) return false;
    row.connected = false;
    row.gone = true;
    return true;
  }

  bool _replaceField(String model, Map<String, Object?> patch) {
    // A status being edited in place rather than replaced — the text changing, or
    // `clearAt` being pushed back. The row is small, so it is re-read whole
    // instead of patched field by field.
    if (model == 'SpaceUserStatus') {
      final id = patch['id'];
      final existing = id is String ? _statuses[id] : null;
      if (existing == null || id is! String) return false;
      final field = (patch['path'] as String? ?? '').split('/').where((s) => s.isNotEmpty);
      if (field.isEmpty) return false;
      return _noteStatus(id, {
        'spaceUserId': existing.owner,
        'text': existing.status.text,
        'emoji': existing.status.emoji,
        'type': existing.status.type,
        'clearAt': existing.status.clearAt,
        field.first: patch['data'],
      });
    }
    if (model != 'SpaceUser') return false;

    final id = patch['id'];
    if (id is! String) return false;
    final segments =
        (patch['path'] as String? ?? '').split('/').where((s) => s.isNotEmpty).toList();
    if (segments.isEmpty) return false;

    // Paths are addressed to the row, so the field is the first segment. Position
    // mutates component-wise, giving `/position/x` — reading only the last segment
    // would silently drop every walking patch.
    final field = segments.first;
    if (!_trackedFields.contains(field)) return false;

    final row = _row(id);
    final sub = segments.skip(1).toList();

    if (sub.isEmpty) return _merge(row, {field: patch['data']});

    if (field == 'position' && (sub.first == 'x' || sub.first == 'y')) {
      final value = patch['data'];
      if (value is! num) return false;
      return _merge(row, {'position__${sub.first}': value});
    }

    // Going away is a patch on the value object's own field, and dropping it would
    // leave somebody who has gone home standing in the office until they reconnect.
    if (field == 'userSetAvailability' && sub.first == 'value') {
      return _merge(row, {'userSetAvailability__value': patch['data']});
    }

    // Turning around is the same shape, and it arrives on its own: you can face a new
    // way without moving, and every step sends it before the position.
    if (field == 'direction' && sub.first == 'value') {
      return _merge(row, {'direction__value': patch['data']});
    }

    // Changing gear. Sent on its own, ahead of the run of positions it explains, and
    // twice per route — once into the kart and once back out of it.
    if (field == 'speed' && sub.first == 'modifier') {
      return _merge(row, {'speed__modifier': patch['data']});
    }

    return false;
  }

  _Row _row(String id) => _users.putIfAbsent(id, () => _Row(id));

  bool _merge(_Row row, Map<String, Object?> data) {
    var changed = false;

    void setIf(bool condition, void Function() apply) {
      if (condition) apply();
    }

    void set<T>(T current, T next, void Function(T) assign) {
      if (current == next) return;
      assign(next);
      changed = true;
    }

    if (data.containsKey('name')) {
      set(row.name, _nullableString(data['name']), (v) => row.name = v);
    }
    if (data.containsKey('userAccountId')) {
      set(row.userAccountId, _nullableString(data['userAccountId']),
          (v) => row.userAccountId = v);
    }
    if (data.containsKey('floorId')) {
      set(row.floorId, _nullableString(data['floorId']), (v) => row.floorId = v);
    }
    if (data.containsKey('profilePictureId')) {
      set(row.profilePictureId, _nullableString(data['profilePictureId']),
          (v) => row.profilePictureId = v);
    }

    // Read the same way, and nullable for the same reason: plenty of people in a
    // space have never claimed a desk, and losing one is a `null` patch rather
    // than a missing key.
    if (data.containsKey('deskId')) {
      set(row.deskId, _nullableString(data['deskId']), (v) => row.deskId = v);
    }
    if (data.containsKey('connected')) {
      set(row.connected, _asBool(data['connected']), (v) => row.connected = v);
    }
    if (data.containsKey('isIdle')) {
      set(row.isIdle, _asBool(data['isIdle']), (v) => row.isIdle = v);
    }
    if (data.containsKey('speaking')) {
      set(row.speaking, _asBool(data['speaking']), (v) => row.speaking = v);
    }
    if (data.containsKey('dancing')) {
      set(row.dancing, _asBool(data['dancing']), (v) => row.dancing = v);
    }
    // A timestamp, not a bool: present and holding something means the hand is up,
    // `undefined` (the ext-4 sentinel, not null) means it just came down. Reading
    // it as `!= null` would leave every lowered hand stuck up. See
    // [RosterRow.handRaised].
    if (data.containsKey('handRaisedAt')) {
      final value = data['handRaisedAt'];
      final up = value != null && !identical(value, msgpackUndefined);
      set(row.handRaised, up, (v) => row.handRaised = v);
    }
    if (data.containsKey('isBot')) {
      set(row.isBot, _asBool(data['isBot']), (v) => row.isBot = v);
    }
    if (data.containsKey('type')) {
      set(row.kind, _nullableString(data['type']), (v) => row.kind = v);
    }
    // A value object, like [availability] below and not like a plain string. Read as
    // one, every row's direction came back null and the whole office faced south:
    // `Facing.of(null)` is south, so the bug looked like a rendering default rather
    // than like a field that was never parsed.
    if (data.containsKey('direction')) {
      final value = data['direction'];
      set(
        row.direction,
        value is Map<String, Object?> ? _nullableString(value['value']) : _nullableString(value),
        (v) => row.direction = v,
      );
    }
    if (data.containsKey('direction__value')) {
      set(row.direction, _nullableString(data['direction__value']),
          (v) => row.direction = v);
    }

    // The third value object of the same shape — `{$type: 'Speed', modifier: 1}` — and
    // the field inside it is `modifier`, not `value`. Patches arrive on
    // `/speed/modifier`, flattened to `speed__modifier` by [_replaceField].
    if (data.containsKey('speed')) {
      final value = data['speed'];
      set(
        row.speed,
        value is Map<String, Object?> ? _asNum(value['modifier']) : _asNum(value),
        (v) => row.speed = v,
      );
    }
    if (data.containsKey('speed__modifier')) {
      set(row.speed, _asNum(data['speed__modifier']), (v) => row.speed = v);
    }

    // A value object: ext-0 decodes to `{$type: 'SpaceUserAvailability', value: …}`,
    // and a field patch on it arrives as `/userSetAvailability/value`, flattened by
    // [_replaceField] the way a position is.
    if (data.containsKey('userSetAvailability')) {
      final value = data['userSetAvailability'];
      set(
        row.availability,
        value is Map<String, Object?> ? _nullableString(value['value']) : null,
        (v) => row.availability = v,
      );
    }
    if (data.containsKey('userSetAvailability__value')) {
      set(row.availability, _nullableString(data['userSetAvailability__value']),
          (v) => row.availability = v);
    }

    // An optional column: only touch it when the key is actually present, and
    // remember that it *was* present. `PresenceTracker` tells absent from null to
    // decide whether following is answerable at all.
    if (data.containsKey('followTargetId')) {
      setIf(!row.followTargetKnown, () {
        row.followTargetKnown = true;
        changed = true;
      });
      set(row.followTargetId, _nullableString(data['followTargetId']),
          (v) => row.followTargetId = v);
    }

    // The other optional column, read the same way and for the same reason.
    if (data.containsKey('clusterId')) {
      setIf(!row.clusterIdKnown, () {
        row.clusterIdKnown = true;
        changed = true;
      });
      set(row.clusterId, _nullableString(data['clusterId']), (v) => row.clusterId = v);
    }

    // Position arrives as a value object: {'$type': 'Position', 'x': …, 'y': …}.
    final position = data['position'];
    if (position is Map<String, Object?>) {
      final px = position['x'];
      final py = position['y'];
      if (px is num) set(row.x, px, (v) => row.x = v);
      if (py is num) set(row.y, py, (v) => row.y = v);
    }
    final flatX = data['position__x'];
    final flatY = data['position__y'];
    if (flatX is num) set(row.x, flatX, (v) => row.x = v);
    if (flatY is num) set(row.y, flatY, (v) => row.y = v);

    return changed;
  }

  /// Files one `SpaceUserStatus` row against the person it belongs to.
  ///
  /// Keyed by the status row's own id, because that is what `deletemodel` names
  /// when a status is cleared — indexing by `spaceUserId` would leave no way to
  /// remove the right one.
  bool _noteStatus(String id, Map<String, Object?> raw) {
    final owner = _nullableString(raw['spaceUserId']);
    final text = _nullableString(raw['text']);
    if (owner == null || text == null || text.isEmpty) {
      return _statuses.remove(id) != null;
    }

    final next = (
      owner: owner,
      status: PersonStatus(
        text: text,
        emoji: _nullableString(raw['emoji']),
        // Absent on nothing seen so far, but a status with no type is still a
        // status and should not vanish because of a missing label.
        type: _nullableString(raw['type']) ?? 'Custom',
        clearAt: raw['clearAt'] is DateTime ? raw['clearAt'] as DateTime : null,
      ),
    );

    final before = _statuses[id];
    if (before != null &&
        before.owner == next.owner &&
        before.status.text == next.status.text &&
        before.status.emoji == next.status.emoji &&
        before.status.clearAt == next.status.clearAt) {
      return false;
    }
    _statuses[id] = next;
    return true;
  }

  /// The one worth showing for a person, or null.
  ///
  /// A person can hold both kinds at once — one they typed and one their calendar
  /// wrote — and the typed one wins, because it is the one they chose. Expired
  /// rows are skipped rather than deleted: the server leaves them on the wire and
  /// may well revive one by patching `clearAt`.
  PersonStatus? _statusFor(String spaceUserId, DateTime now) {
    PersonStatus? best;
    for (final entry in _statuses.values) {
      if (entry.owner != spaceUserId) continue;
      if (entry.status.expiredAt(now)) continue;
      if (best == null || (entry.status.isCustom && !best.isCustom)) {
        best = entry.status;
      }
    }
    return best;
  }

  /// Fallback route to identity when no Connection row named us.
  void _identifySelf() {
    if (selfId != null || _myUserAccountId == null) return;
    for (final row in _users.values) {
      if (row.userAccountId != null && row.userAccountId == _myUserAccountId) {
        selfId = row.id;
        _log('game protocol: own space user ${row.id} (via UserAccount)');
        return;
      }
    }
  }

  /// Whether the server is reflecting *us* back as present — the one thing the
  /// inbound roster can say about whether other people can see us.
  ///
  /// `Connection.entered` and `Connection.isActive` are the fields that would
  /// answer it directly, but both are write-only: we send them and never read
  /// them back. What *is* reflected is our own `SpaceUser` row, and the same
  /// placement a peer's client keys their rendering on. So when our own row is
  /// absent, marked gone, `connected != true`, or has no tile, that is also how we
  /// have gone missing from everyone else's office — the readable shadow of the
  /// unreadable `entered`. A half-open socket ends exactly here: the server's own
  /// heartbeat eventually times us out and flips `connected` to false (or drops
  /// the row), which is what others see as us leaving.
  ///
  /// Deliberately *not* the full `isPresent` test: `availability == 'Offline'` is
  /// left out because it is a state a person chooses or drifts into and keeps for
  /// hours — measured, nine of twelve `connected` rows were Offline, some for a
  /// day (see [RosterRow.isPresent]). Treating that as a fault would reconnect the
  /// socket and re-enter under someone who meant to appear away, fighting their
  /// own choice. The connection-level signals above carry no such ambiguity, and
  /// the walk engine's unapplied-moves signal covers a server that fails to relay
  /// us while still calling us connected.
  ///
  /// Null [selfId] reads as not-visible: until the `Connection` row has named us
  /// we cannot claim to be present. Callers must gate this on having entered and
  /// holding state, or a first connect still assembling its dump looks like a
  /// disappearance.
  bool get selfVisible {
    final me = selfId;
    if (me == null) return false;
    final row = _users[me];
    if (row == null || row.gone || row.connected != true) return false;
    return row.x != null && row.y != null;
  }

  /// The roster in the shape [PresenceTracker] consumes.
  Roster roster() {
    final rows = <RosterRow>[];
    // Sampled once for the whole roster rather than per person, so two people
    // whose statuses expire in the same second cannot disagree about the time.
    final now = DateTime.now().toUtc();
    for (final row in _users.values) {
      // Recording clients and bots are not people who can follow you.
      if (row.isBot == true || row.kind == 'RecordingClient') continue;
      rows.add(RosterRow(
        id: row.id,
        name: row.name,
        x: row.x,
        y: row.y,
        floorId: row.floorId,
        connected: row.gone ? false : row.connected,
        speaking: row.speaking,
        dancing: row.dancing,
        followTargetKnown: row.followTargetKnown,
        followTargetId: row.followTargetId,
        clusterIdKnown: row.clusterIdKnown,
        clusterId: row.clusterId,
        userAccountId: row.userAccountId,
        direction: row.direction,
        speed: row.speed,
        availability: row.availability,
        profilePictureId: row.profilePictureId,
        deskId: row.deskId,
        status: _statusFor(row.id, now),
        handRaised: row.handRaised,
      ));
    }
    return Roster(selfId: selfId, rows: rows, spaceName: spaceName);
  }
}

/// One patch array out of a frame.
///
/// `FullStateChunk` uses `fullStatePatches`, `DeltaState` uses `patches`. They are
/// read separately rather than merged, because for anything event-shaped the
/// difference between "this is how the world already was" and "this just happened"
/// is the entire signal.
List<Map<String, Object?>> _patchesIn(Object? list) {
  if (list is! List) return const [];
  final out = <Map<String, Object?>>[];
  for (final patch in list) {
    if (patch is Map<String, Object?> && patch['op'] is String) out.add(patch);
  }
  return out;
}

/// Watches the meeting models for the two things somebody can do *at* you that
/// Gather records as state rather than sending over the event bus.
///
///  - **An invite.** `MeetingParticipant{spaceUserId: <you>, inviterId: <them>}`,
///    with `inviteStatus: 'InvitedRequired'`. Observed on a live space.
///  - **A knock.** `MeetingJoinRequest{spaceUserId: <them>, meetingId}` with no
///    `respondedAt` — somebody asking to be let in and waiting on an answer. This
///    model is not even in the documented table; it turned up in the census.
///
/// Both are surfaced as [BusEvent]s so they travel the same path as a wave, and
/// neither is emitted for a row that arrived in the state dump — see [apply].
class _MeetingWatch {
  /// Meetings we are a participant of, so a knock on somebody else's meeting in the
  /// same space is not mistaken for one aimed at us.
  final Set<String> _myMeetings = {};

  /// Participant rows seen in the dump, so the same row arriving again as a delta
  /// (an `updatedAt` touch, a response recorded) is not read as a fresh invite.
  final Set<String> _known = {};

  /// Rows that arrived before we knew which SpaceUser we are.
  ///
  /// Identity comes from one `Connection` patch among ~1500, and there is no
  /// guarantee it lands first. Without this, an invite delivered in the same frame
  /// as the dump would be judged against a null `selfId` and silently dropped.
  final List<Map<String, Object?>> _undecided = [];

  void apply(
    String model,
    Map<String, Object?> patch, {
    required bool isNews,
    required String? selfId,
    required List<BusEvent> out,
  }) {
    final data = patch['data'];
    if (patch['op'] != 'addmodel' || data is! Map<String, Object?>) {
      // Updates and deletions carry nothing we report. A response being recorded on
      // an invite is the *answer*, not a new question.
      return;
    }
    final id = data['id'];
    if (id is! String) return;

    final firstSighting = _known.add(id);

    if (model == 'MeetingParticipant') {
      // Learn which meetings are ours regardless of where the row came from: the
      // dump is exactly how we know which meetings we were already in.
      if (selfId != null && data['spaceUserId'] == selfId) {
        final meetingId = data['meetingId'];
        if (meetingId is String) _myMeetings.add(meetingId);
      }
    }

    if (!isNews || !firstSighting) return;

    if (selfId == null) {
      _undecided.add({'model': model, 'data': data});
      return;
    }
    final event = _judge(model, data, selfId);
    if (event != null) out.add(event);
  }

  /// Re-reads what arrived before we knew who we were.
  void resolvePending(String selfId, List<BusEvent> out) {
    if (_undecided.isEmpty) return;
    final pending = List<Map<String, Object?>>.of(_undecided);
    _undecided.clear();
    for (final row in pending) {
      final data = row['data'] as Map<String, Object?>;
      if (data['spaceUserId'] == selfId) {
        final meetingId = data['meetingId'];
        if (meetingId is String) _myMeetings.add(meetingId);
      }
      final event = _judge(row['model'] as String, data, selfId);
      if (event != null) out.add(event);
    }
  }

  BusEvent? _judge(String model, Map<String, Object?> data, String selfId) {
    if (model == 'MeetingParticipant') {
      // Ours, and somebody put us there — a row we created by walking into a room
      // has no `inviterId`, and is not an invitation.
      if (data['spaceUserId'] != selfId) return null;
      final inviter = data['inviterId'];
      if (inviter is! String || inviter.isEmpty) return null;
      return BusEvent(
        name: 'MeetingInvite',
        senderId: inviter,
        sentTime: _isoOf(data['createdAt']),
        targetUserIds: [selfId],
        payload: data,
      );
    }

    // A knock: somebody asking to join, before anyone has answered.
    final asker = data['spaceUserId'];
    if (asker is! String || asker == selfId) return null;
    // Asked positively, because "absent" on this protocol is msgpack `undefined`
    // rather than null — a `!= null` test would read every unanswered knock as
    // already answered and report nothing at all.
    if (_isoOf(data['respondedAt']) != null) return null;
    final meetingId = data['meetingId'];
    if (meetingId is! String || !_myMeetings.contains(meetingId)) return null;
    return BusEvent(
      name: 'MeetingJoinRequest',
      senderId: asker,
      sentTime: _isoOf(data['createdAt']),
      targetUserIds: [selfId],
      payload: data,
    );
  }
}

String? _isoOf(Object? value) {
  if (value is DateTime) return value.toIso8601String();
  if (value is String && value.isNotEmpty) return value;
  return null;
}

/// Pulls interaction events out of `DeltaState.events[]`.
List<BusEvent> _collectBusEvents(Map<String, Object?> frame) {
  final list = frame['events'];
  if (list is! List) return const [];

  final out = <BusEvent>[];
  for (final entry in list) {
    if (entry is! Map<String, Object?>) continue;
    final payload = entry['payload'];
    if (payload is! Map<String, Object?>) continue;
    final name = payload['eventName'];
    if (name is! String) continue;

    final options = entry['options'];
    final targets = options is Map<String, Object?> ? options['targetUserIds'] : null;

    out.add(BusEvent(
      name: name,
      senderId: _senderOf(payload),
      sentTime: _asIsoString(payload['sentTime']),
      // `targetUserIds` is a JS `Set`, which is msgpack ext-2 and decodes to a
      // list. Absent means the event was not addressed to anybody in particular —
      // the schemas type it `union([undefined(), set(zodUuid)])` — so an empty list
      // here reads as "not aimed at me", which is the safe way round for anything
      // that would otherwise notify the whole space.
      targetUserIds: targets is List ? targets.whereType<String>().toList() : const [],
      payload: payload,
    ));
  }
  return out;
}

/// Who sent an event, under whichever of three names this one uses.
///
/// The field is not stable across event types and the inconsistency is silent,
/// because every one of them also carries `targetUserIds` — so an event keyed on
/// the wrong name still routes to the right person and merely arrives with nobody
/// attached to it. Observed: `WaveEvent` says `senderId`, `EmoteEvent` says
/// `senderUserId`, `ConfettiThrown` says `senderSpaceUserId`. All three hold a
/// `SpaceUser` id.
String? _senderOf(Map<String, Object?> payload) =>
    _nullableString(payload['senderId']) ??
    _nullableString(payload['senderUserId']) ??
    _nullableString(payload['senderSpaceUserId']);

/// Pulls our own actions' verdicts out of `actionReturns[]`.
///
/// Acknowledgements are strictly private to the socket that sent the action —
/// measured across two clients, 52 acks and 7 acks, with no cross-contamination in
/// either direction — so everything in this array is an answer to something we
/// sent, and there is no need to filter by `connectionId`.
List<ActionResult> _collectActionResults(Map<String, Object?> frame) {
  final list = frame['actionReturns'];
  if (list is! List) return const [];

  final out = <ActionResult>[];
  for (final entry in list) {
    if (entry is! Map<String, Object?>) continue;
    final txnId = _nullableString(entry['txnId']);
    if (txnId == null) continue;
    final result = entry['result'];
    final type = result is Map<String, Object?> ? result['type'] : null;
    // Asked positively. An unrecognised `type` is not a success, and treating it as
    // one is how a refusal would go back to being invisible.
    final ok = type == 'Success';
    out.add(ActionResult(
      txnId: txnId,
      ok: ok,
      error: ok || result is! Map<String, Object?>
          ? null
          : _errorText(result['error']) ?? _errorText(result['message']),
      value: ok && result is Map<String, Object?> ? result['value'] : null,
    ));
  }
  return out;
}

/// The error field as a string, however it arrived.
///
/// Observed as a string — prose, or a JSON zod list already serialised into one —
/// but a server that ever sends the issue list as a real array should not come out
/// as an empty refusal, so a structure is re-encoded rather than dropped.
/// [describeActionError] parses either back.
String? _errorText(Object? value) {
  if (value is String) return value.trim().isEmpty ? null : value;
  if (value is List || value is Map) {
    try {
      return jsonEncode(value);
    } on Object {
      return '$value';
    }
  }
  return null;
}

String? _asIsoString(Object? value) {
  if (value is DateTime) return value.toIso8601String();
  if (value is String && value.isNotEmpty) return value;
  if (value is int) {
    return DateTime.fromMillisecondsSinceEpoch(value, isUtc: true).toIso8601String();
  }
  return null;
}

String? _nullableString(Object? value) =>
    value is String && value.isNotEmpty ? value : null;

bool? _asBool(Object? value) => value is bool ? value : null;

num? _asNum(Object? value) => value is num ? value : null;
