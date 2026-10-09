/// Reads presence by connecting to Gather ourselves, from the phone.
///
/// A port of `bridge/lib/direct.js`. The bridge opens this connection on the Mac;
/// this opens the same one from the app, which is what lets the app stop depending
/// on the bridge being reachable at all.
///
/// ## Entering, and what it costs
///
/// `loadSpaceUser` materialises our SpaceUser and starts the state dump.
/// `enterSpace` is a *separate* action, and it is what actually puts an avatar in
/// the room. **This collector sends it**, because the app is no longer only
/// watching: a phone that publishes audio and video is a participant, and a
/// participant is present. `Connection.entered` goes true, and `reportActivity`
/// follows so we do not sit there looking idle to colleagues.
///
/// The bridge's copy of this collector (`bridge/lib/direct.js`) does **not** enter
/// and must never start. It exists to wake a sleeping phone and has no reason to
/// be in a room. That divergence is deliberate — see `AGENTS.md` — and is the one
/// place these two implementations of the same wire format are allowed to differ.
///
/// Two connections of your own do not fight: `Connection` is per-connection but
/// `SpaceUser` is per-person-per-space, so the desktop client and this one drive
/// the same avatar. Measured 2026-08-06: neither an observer connection nor an
/// entered one disturbed the desktop client's socket, `enterSpace` returned
/// `{type:'Success'}`, and our position was unchanged either side of it.
///
/// What entering costs is real and worth knowing: **`numTimesEnteredSpace`
/// increments per entering connection**, and it is a permanent counter on the
/// user's own profile. That makes reconnect frequency a thing with a price, which
/// is why `AppState.verifyLink()` does not reconnect a socket that is already
/// healthy. Do not "simplify" that into an unconditional resync.
///
/// ## No resync
///
/// The full state dump is sent once per *connection*. So there is nothing to ask
/// for: [resync] reconnects, and the dump follows immediately. On a phone this is
/// the behaviour that matters most — iOS suspends the app, the socket dies
/// unannounced, and on resume a fresh connection is both the repair and the
/// refresh.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'collector.dart';
import 'game_protocol.dart';
import 'gather_auth.dart';
import 'msgpack.dart';
import 'space_art.dart';
import 'space_map.dart';

const _gameSocket = 'wss://game-router.v2.gather.town/gather-game-v2';

/// Rosters are coalesced over this window rather than published per patch. A busy
/// space moves several people a second, and the screen wants the result, not the
/// frames.
const _publishInterval = Duration(milliseconds: 250);

/// The desktop client heartbeats roughly once a second. We are far less chatty
/// because nothing depends on our liveness being noticed quickly; an
/// unauthenticated probe survived 25s sending none at all.
const _heartbeatInterval = Duration(seconds: 10);

/// How long after the handshake we stay quiet about holding no state.
///
/// A server heartbeat usually lands before the first `FullStateChunk`, so without
/// this the collector would announce failure on every connect and immediately
/// retract it.
const _handshakeGrace = Duration(seconds: 5);

/// How long a total silence has to last before we stop believing the socket.
///
/// Nothing else notices a socket that has gone deaf. `onDone` is what drives every
/// reconnect here, and a half-open TCP connection never fires one: the peer sent no
/// FIN, so the send side keeps accepting heartbeats and the read side simply never
/// delivers anything again. That is the ordinary outcome of a device losing its
/// network without a clean teardown — a phone changing cell, wifi dropping, a laptop
/// suspending — and without this the collector reports full health and a live roster
/// for as long as the process runs while receiving nothing.
///
/// Gather's server heartbeats every 3–9s, so silence is unambiguous well before
/// this. Being wrong costs a reconnect and a fresh state dump, so it has to clear
/// the 9s ceiling with room to spare — but it used to be 45s, which meant a phone
/// that lost its network the dirty way (half-open, no FIN) went on claiming a live
/// office, and claiming *presence to others*, for most of a minute. 12s is one
/// missed server heartbeat past the 9s ceiling: long enough not to reconnect a
/// merely-slow socket, short enough that "nobody can see me" is not a 45-second
/// silence.
///
/// The bridge's `SILENCE_LIMIT_MS` in `bridge/lib/direct.js` stays at its own
/// value: it is a different runtime on a real network, not a phone changing cells,
/// and does not share this failure mode. The two are allowed to differ now.
const _silenceLimit = Duration(seconds: 12);

/// How long our own `SpaceUser` may be missing from an otherwise-healthy roster
/// before we treat it as "other people cannot see us" and begin recovery.
///
/// Distinct from [_silenceLimit]: there the socket is deaf and nothing arrives;
/// here frames flow and the roster is current, but it does not contain a present,
/// placed *us*. A few seconds of grace absorbs the ordinary gap between a
/// reconnect's first partial dump and the patch that re-places our own row, so a
/// blink of absence never raises anything — see the recovery ladder in [_flush].
const _selfAbsentLimit = Duration(seconds: 5);

/// How long a silent re-enter gets to put us back on the roster before the
/// recovery ladder stops being quiet and reconnects the socket outright.
const _reenterGrace = Duration(seconds: 4);

const _maxBackoff = Duration(seconds: 30);

/// What we tell Gather we are. Mirrors the desktop client.
const _connectionTarget = 'OfficeView';
const _clientPlatform = 'Desktop';

/// How many outstanding actions to remember for the sake of naming a refusal.
///
/// Acks are prompt and 1:1, so in practice this holds one or two entries — a
/// held-down D-pad at go-kart pace is 21 actions a second and every one of them is
/// answered within a frame or two. The cap is a backstop against a server that
/// stops acknowledging, which would otherwise grow this map for the life of the
/// connection.
const _maxAwaitingActions = 128;

/// [ActionRefused] and [CollectorStatus] moved to `collector.dart`, beside the
/// [Collector] interface they are part of the surface of, and are re-exported
/// from there through the package barrel.
class DirectCollector implements Collector {
  DirectCollector({
    required GatherAuth auth,
    String? spaceId,
    String socketUrl = _gameSocket,
    Future<WebSocket> Function(String url)? connect,
    void Function(String)? log,
    // Injected for the same reason as `connect`: the honest test of the deaf-socket
    // watchdog is to let a connection actually fall silent, and a suite that waited
    // [_silenceLimit] to find out would add 45 seconds to every run.
    this.silenceLimit = _silenceLimit,
    // Same seam, for the presence ladder: a test proves the self-row watchdog by
    // letting a real roster arrive without us in it, and must not wait out the
    // production 5s + 4s to see the re-enter and the reconnect.
    this.selfAbsentLimit = _selfAbsentLimit,
    this.reenterGrace = _reenterGrace,
        // A named parameter cannot be a private initializing formal, so these are
        // assigned the long way round — same as `BridgeClient` and `AppState`.
        // ignore: prefer_initializing_formals
  })  : _auth = auth,
        _configuredSpaceId = spaceId,
        spaceId = spaceId,
        // ignore: prefer_initializing_formals
        _socketUrl = socketUrl,
        _connect = connect ?? WebSocket.connect,
        _log = log ?? _noop;

  static void _noop(String _) {}

  /// How long a silence has to last before the socket is torn down. See
  /// [_silenceLimit] for why this exists and why it is as long as it is.
  final Duration silenceLimit;

  /// How long our own row may be missing before the quiet re-enter. See
  /// [_selfAbsentLimit].
  final Duration selfAbsentLimit;

  /// How long a silent re-enter gets before the loud reconnect. See
  /// [_reenterGrace].
  final Duration reenterGrace;

  final GatherAuth _auth;
  final String _socketUrl;

  /// Overridable so tests can point at a fake game server instead of Gather.
  final Future<WebSocket> Function(String url) _connect;
  final void Function(String) _log;

  /// Explicitly configured space, if any; otherwise resolved per connect.
  final String? _configuredSpaceId;
  @override
  String? spaceId;

  GameProtocolReader reader = GameProtocolReader();

  WebSocket? _ws;
  Timer? _retryTimer;
  Timer? _publishTimer;
  Timer? _heartbeatTimer;
  Duration _backoff = const Duration(seconds: 1);
  bool _stopped = false;
  bool _healthy = false;
  String? _lastDetail;
  bool _dirty = false;
  int _frames = 0;
  int _connects = 0;

  /// Whether `enterSpace` has gone out on the current socket. Reset per connect.
  bool _entered = false;
  DateTime? _handshakeAt;

  /// When a frame last arrived. The watchdog's whole state — see [_silenceLimit].
  DateTime? _lastFrameAt;

  /// Whether we have been visible to others at least once on this connection. Flips
  /// an absent self row from "a dump still arriving" into "we have disappeared", so
  /// the ladder reacts to the loss at once instead of waiting out the cold-start
  /// grace. Reset per connect.
  bool _wasVisible = false;

  /// Since when our own row has been missing from an otherwise-live roster, or
  /// null while we can see ourselves. The clock behind [_selfAbsentLimit].
  DateTime? _selfDoubtSince;

  /// A silent re-enter is outstanding: we have re-sent `enterSpace` and are
  /// waiting [_reenterGrace] to see ourselves come back before reconnecting.
  bool _reentering = false;
  DateTime? _reenterAt;

  /// Whether the outstanding re-enter was raised by the walk engine rather than by a
  /// missing self row. It matters because the two have opposite repair signals: a
  /// self-absent re-enter is healed the moment [GameProtocolReader.selfVisible] turns
  /// true again, but a walk-triggered one runs *while* we are still visible — the
  /// server reports us connected and placed and simply ignores our moves. Letting
  /// `selfVisible` clear a walk re-enter would drop it on the very next flush, before
  /// any move was confirmed: the loud reconnect would never fire and each later
  /// buffer overflow would send a fresh `enterSpace`. So a walk re-enter is cleared
  /// only by a confirmed move ([noteMovesConfirmed]) or escalated after [reenterGrace].
  bool _reenterFromWalk = false;

  /// txnId -> the action it was, so an ack can be named. Cleared per connect.
  final Map<String, String> _awaiting = {};

  final _rosters = StreamController<Roster>.broadcast();
  final _interactions = StreamController<BusEvent>.broadcast();
  final _statuses = StreamController<CollectorStatus>.broadcast();
  final _refusals = StreamController<ActionRefused>.broadcast();

  /// The roster, coalesced. One event per change worth rendering.
  @override
  Stream<Roster> get rosters => _rosters.stream;

  /// Waves and the rest of Gather's event bus, published the moment they arrive.
  @override
  Stream<BusEvent> get interactions => _interactions.stream;
  @override
  Stream<CollectorStatus> get statuses => _statuses.stream;

  /// Actions the server would not run.
  ///
  /// Separate from [statuses] because it is not about the connection: the socket is
  /// perfectly healthy and one thing we asked for did not happen. Broadcast and
  /// unbuffered — a refusal is news, and nothing is owed delivery if nobody is
  /// listening.
  @override
  Stream<ActionRefused> get refusals => _refusals.stream;

  @override
  bool get healthy => _healthy;
  String? get detail => _lastDetail;

  /// Whether we hold state, as opposed to merely being connected. The distinction
  /// matters: an empty roster reported as healthy would let the app render a
  /// confident "nobody is following you" out of nothing.
  @override
  bool get hasState => reader.userCount > 0;

  /// Our own `SpaceUser` id, once the dump has told us which row is us.
  @override
  String? get selfId => reader.selfId;

  /// Our own `UserAccount` id — what the media plane keys on. See
  /// [GameProtocolReader.selfAccountId].
  @override
  String? get selfAccountId => reader.selfAccountId;

  /// The floor plan for a floor, or null until the dump has carried enough of it.
  ///
  /// Read through rather than cached: the builder rebuilds only when a map model
  /// actually changed, so asking repeatedly is cheap and asking early is correct —
  /// it starts returning a map the moment one can be built.
  @override
  SpaceMap? mapFor(String? floorId) => reader.mapBuilder.forFloor(floorId);

  /// The same floor, drawn: floor tiles, wall pieces and furniture sprites, with the
  /// URLs to fetch them from. Read through for the same reason as [mapFor].
  @override
  SpaceArt? artFor(String? floorId, {bool dark = true}) =>
      reader.mapBuilder.artFor(floorId, dark: dark);

  /// Somebody's avatar spritesheet, or null when their outfit is not known.
  @override
  String? avatarUrlFor(String spaceUserId) => reader.avatarUrlFor(spaceUserId);

  Map<String, Object?> stats() => {
        ...reader.stats(),
        'frames': _frames,
        'connects': _connects,
        'spaceId': spaceId,
        'authUserId': reader.authUserId,
        'entered': _entered,
      };

  @override
  void start() {
    _stopped = false;
    _connectNow();
  }

  Future<void> stop() async {
    _stopped = true;
    _clearTimers();
    await _closeSocket();
  }

  @override
  Future<void> dispose() async {
    await stop();
    await _rosters.close();
    await _interactions.close();
    await _statuses.close();
    await _refusals.close();
  }

  /// Reconnects, which is all a resync is here: the server replays the full state
  /// dump on every new connection.
  @override
  Future<({bool ok, String detail})> resync() async {
    if (_stopped) return (ok: false, detail: 'collector stopped');
    _log('direct: reconnecting to force a fresh state dump');
    _clearTimers();
    await _closeSocket();
    _backoff = const Duration(seconds: 1);
    _connectNow();
    return (ok: true, detail: 'reconnecting; a full state dump follows immediately');
  }

  /// Takes one step. What the D-pad sends.
  ///
  /// `move` is the action Gather's own client sends for a keypress, and its whole body
  /// is a delta and a turn:
  ///
  /// ```js
  /// fn: () => A => {
  ///   const e = new Direction(A.direction).toPositionDelta();
  ///   const g = new Position({x: this.x + e.x, y: this.y + e.y});
  ///   this.direction = new Direction(A.direction);
  ///   this.setPosition(g, {map: ..., prevPosition: this.position})
  /// }
  /// ```
  ///
  /// **There is no collision check in it.** Whether the step is legal is decided
  /// entirely on the client, before this is sent — see [SpaceMap.canStep], which is
  /// the rule, and `walk.dart`, which is the caller that applies it. Sending this
  /// blind walks the user's avatar through the office wall and out into the void.
  ///
  /// One tile per call, and it turns whether or not it moves: [direction] is written
  /// to `SpaceUser.direction` before the position is touched.
  ///
  /// Fire-and-forget for the same reason [teleport] is.
  @override
  ({bool ok, String? detail}) move({required String direction}) {
    if (!moveDirections.contains(direction)) {
      return (ok: false, detail: '$direction is not a direction');
    }
    return _act('move', {'direction': direction});
  }

  /// Says how fast we are going, which is what puts a go-kart under the avatar.
  ///
  /// Three actions, one per [Gait], and each body is a single assignment:
  ///
  /// ```js
  /// w(this, "drive", MethodAction({
  ///   target: this, id: "drive",
  ///   requiredPermission: SpaceUserPermission.Move,
  ///   optimistic: true,
  ///   fn: () => () => { this.speed = new Speed(Speed.DRIVING) }}))
  /// ```
  ///
  /// No arguments — the action *is* the argument — so this goes out as the same
  /// two-element `args` tuple `clearCustomStatus` uses.
  ///
  /// **Nothing about position depends on this.** The pace is entirely in how often
  /// [move] is sent, and the server neither reads `speed` back nor checks it. What it
  /// buys is that `speed.modifier` is a synced field on `SpaceUser`, so this is the
  /// only thing every other client in the space reads to pick the run cycle and to
  /// draw the kart. Stepping fast without sending it is an avatar skating across the
  /// office in an idle pose on everybody else's screen.
  ///
  /// Fire-and-forget for the same reason [move] is.
  @override
  ({bool ok, String? detail}) setGait(Gait gait) => _act(gait.action);

  /// Moves our avatar to a tile. The one thing this collector writes.
  ///
  /// `SpaceUser` is per-person-per-space rather than per-connection, so this moves
  /// the *same* avatar the desktop client is driving — there is no second body to
  /// fight with. Verified 2026-08-07 that it works from an observer connection:
  /// `teleport` returns `{type:'Success'}` without `enterSpace` having been sent.
  ///
  /// Fire-and-forget by design. Replies come back asynchronously in
  /// `DeltaState.actionReturns[]` keyed by `txnId`, and the only failures a caller
  /// could act on are already answerable here. The authoritative confirmation is
  /// the position patch that follows, through the normal roster path.
  ///
  /// The server does **not** validate walkability: every tile on the grid is
  /// accepted, walls and void included. Picking somewhere sensible is the caller's
  /// job.
  @override
  ({bool ok, String? detail}) teleport({
    required num x,
    required num y,
    String direction = 'Down',
  }) {
    if (!x.isFinite || !y.isFinite) {
      return (ok: false, detail: 'teleport needs finite coordinates');
    }
    // Checked here rather than left to the gateway, for the reason [_act] gives: the
    // schema is `nativeEnum(MoveDirection)` and a zod failure executes *nothing*, so an
    // unrecognised direction would not be a teleport that landed facing oddly — it
    // would be a teleport that silently did not happen.
    if (!moveDirections.contains(direction)) {
      return (ok: false, detail: '$direction is not a direction');
    }
    // Flat x/y — `{position:{x,y}}` is rejected — and `direction` is required even
    // though teleporting does not pass through any tiles.
    return _act('teleport', {'x': x, 'y': y, 'direction': direction});
  }

  // ---- being a person in the room ---------------------------------------------
  //
  // Everything below was read off a live capture rather than guessed: a probe run
  // on 2026-08-13 switched each setting in the desktop client and recorded what
  // went out. That matters because the arg shapes are not uniform and the server
  // rejects a wrong one wholesale — see [_act].

  /// Active, Busy or Away. What the dot on everybody's name plate is reading.
  ///
  /// The field this lands on is `SpaceUser.userSetAvailability`, which is a value
  /// object on the way back (`{$type, value}`) but a bare string on the way out.
  /// `Offline` is deliberately not offered: it is what the *server* writes when a
  /// connection goes away, and setting it by hand while holding an open socket
  /// claims something contradicted by the socket carrying it.
  @override
  ({bool ok, String? detail}) setAvailability(String availability) {
    if (!settableAvailabilities.contains(availability)) {
      return (ok: false, detail: '$availability is not an availability');
    }
    return _act('setAvailability', {'availability': availability});
  }

  /// The line of text under your name, with an emoji beside it.
  ///
  /// [clearAt] is when Gather should drop it by itself. Null means it stands until
  /// [clearCustomStatus] — the capture only ever carried the `DateTime` condition,
  /// so the no-expiry case omits `clearCondition` rather than inventing a shape
  /// for it.
  @override
  ({bool ok, String? detail}) setCustomStatus({
    required String text,
    String? emoji,
    DateTime? clearAt,
  }) =>
      _act('setCustomStatus', {
        'text': text,
        // Omitted rather than sent as null when there is no emoji — an absent
        // optional field and one explicitly nulled are different things here.
        'emoji': ?emoji,
        if (clearAt != null)
          'clearCondition': {'type': 'DateTime', 'clearAt': clearAt.toUtc()},
      });

  /// Takes the status line down. Two args, not three.
  @override
  ({bool ok, String? detail}) clearCustomStatus() => _act('clearCustomStatus');

  /// Throws an emoji over the room.
  ///
  /// It comes back on the event bus as `EmoteEvent` — including our own, whose
  /// `targetUserIds` names the sender as well as the recipients.
  ///
  /// [count] was `1` on every send in the capture. The field name suggests Gather's
  /// own client bundles a held press into one frame, but a larger value has never
  /// been seen accepted, so the default is the observed one.
  @override
  ({bool ok, String? detail}) broadcastEmote(String emote, {int count = 1}) {
    if (emote.isEmpty) return (ok: false, detail: 'no emote to send');
    return _act('broadcastEmote', {
      'emote': emote,
      'count': count,
      // Empty on every observed send, including from a client that was in a call
      // at the time — the server evidently works the fan-out out for itself.
      'ambientlyConnectedUserIds': <String>[],
    });
  }

  /// Waves at one person.
  ///
  /// The action is `sendWave` (SpaceUser), confirmed from the action surface in
  /// `docs/protocol/client-action-surface.md`; the first guess, `wave`, drew
  /// `Method wave not found on model SpaceUser`. Unlike every other action here,
  /// it is **not** addressed to our own avatar: the recipient is the model `id`
  /// (`args[1]`), and there is **no** third argument at all. The rest-args after
  /// `[model, id]` are validated as an array that must be empty — both a
  /// `{targetUserIds:[id]}` object and a `[]` payload drew `Array must contain at
  /// most 0 element(s)`, so the frame is the bare two-element `[model, id]`, like
  /// the no-arg actions. The server fans it back as the `WaveEvent` naming us.
  @override
  ({bool ok, String? detail}) wave(String targetSpaceUserId) {
    if (targetSpaceUserId.isEmpty) return (ok: false, detail: 'no target to wave at');
    return _send('sendWave', model: 'SpaceUser', id: targetSpaceUserId);
  }

  /// Puts a hand up, or takes it down. A bare bool, not a map.
  ({bool ok, String? detail}) setHandRaised(bool raised) =>
      _act('setHandRaised', raised);

  /// Says whether we are talking. This is the speaking ring.
  ///
  /// Two actions rather than one flag, and neither takes an argument —
  /// `startSpeaking` and `stopSpeaking` both declare an empty schema, so they are
  /// two-element `args` like [leaveCluster] and not `setSpeaking(true)`. They
  /// write `SpaceUser.speaking`, which is the field every other client already
  /// reads to draw the border round a talking person and to pick the talking
  /// animation for their avatar.
  ///
  /// **Nothing else sets it.** Publishing audio to the SFU does not: the media
  /// plane and the game socket are separate, and the server does not join them
  /// up. A client that never sends these is perfectly audible and permanently
  /// drawn as silent — which is what this one did until the voice-activity
  /// detector in the app started calling it.
  ///
  /// Sent on every change rather than on a timer, so the cost is the number of
  /// times somebody starts and stops talking. The rate limiting that matters
  /// belongs upstream, in the detector's hold, and not here.
  @override
  ({bool ok, String? detail}) setSpeaking(bool speaking) =>
      _act(speaking ? 'startSpeaking' : 'stopSpeaking');

  /// Steps out of the huddle without walking away from it.
  ///
  /// Gather forms conversations by proximity and remembers them in `clusterId`, so
  /// leaving one and staying where you are is a thing only this action can express.
  /// Two args, not three.
  @override
  ({bool ok, String? detail}) leaveCluster() => _act('leaveCluster');

  /// Turns on the spot, without taking the step [move] would.
  ({bool ok, String? detail}) faceDirection(String direction) {
    if (!moveDirections.contains(direction)) {
      return (ok: false, detail: '$direction is not a direction');
    }
    // A bare string third argument, unlike `move`, which wraps the same value.
    return _act('faceDirection', direction);
  }

  /// "No third argument was passed", which `null` cannot say because `null` is
  /// itself a legitimate one. Compared with [identical], so it can only ever match
  /// the default.
  static const _nothing = Object();

  /// Says whether the person is actually at the phone.
  ///
  /// `reportActivity` is the only action here addressed to `Connection` rather than
  /// to `SpaceUser`, and it takes a `null` id — the gateway knows which connection
  /// is asking. Gather's own client sends it on every idle and focus change; this
  /// one sends it when the app goes to the background and comes back, which is the
  /// same question a phone can answer.
  ///
  /// Without the `false` half, `Connection.isActive` stays true for as long as the
  /// socket does, and a phone in a pocket goes on claiming somebody is at their
  /// desk.
  @override
  ({bool ok, String? detail}) setActive(bool active) =>
      _send('reportActivity', model: 'Connection', id: null, args: {'isActive': active});

  @override
  void notePresenceDoubt() {
    // Stronger evidence than an absent row — the walk engine watched move after
    // move go unapplied — so skip the [_selfAbsentLimit] wait and begin the quiet
    // re-enter at once. From there the ladder in [_checkSelfPresence] is the same.
    if (_entered) {
      _beginRecovery('the walk engine saw moves the server never applied', fromWalk: true);
    }
  }

  @override
  void noteMovesConfirmed() {
    // A roster finally landed us on a tile we had stepped onto: the server is
    // applying our moves again, which is the one unambiguous proof that a
    // walk-triggered re-enter took. Nothing else can clear it — [selfVisible] was
    // true the whole time — so without this the re-enter would hang until the grace
    // escalated it into a needless reconnect.
    if (_reentering && _reenterFromWalk) {
      _log('direct: a move was confirmed — walk-triggered recovery took');
      _notePresenceOk();
    }
  }

  /// One action against our own `SpaceUser` row, on the socket we already hold.
  ///
  /// [args] is the third element of the `args` tuple, and it is deliberately
  /// `Object?` rather than a map: the captured vocabulary is not uniform. `move`
  /// and `setAvailability` pass a map, `setHandRaised` passes a bare `true`,
  /// `faceDirection` a bare `"Down"`, and `clearCustomStatus` and `leaveCluster`
  /// pass nothing at all — their `args` is two elements long, not three. Sending a
  /// map where the server wants a bool is a schema failure, so the shape is the
  /// caller's to state.
  ///
  /// The socket is checked before the identity, and the order is the point rather
  /// than an accident: with neither, "not connected to Gather" is the fact worth
  /// telling somebody, and "do not know which avatar is ours yet" is a detail about
  /// a connection that does not exist. [_send] repeats the first check for the
  /// callers that skip this one.
  ({bool ok, String? detail}) _act(String action, [Object? args = _nothing]) {
    final ws = _ws;
    if (ws == null || ws.readyState != WebSocket.open) {
      return (ok: false, detail: 'not connected to Gather');
    }
    final self = reader.selfId;
    if (self == null) {
      return (ok: false, detail: 'do not know which avatar is ours yet');
    }
    return _send(action, model: 'SpaceUser', id: self, args: args);
  }

  /// One action on any model, on the socket we already hold.
  ///
  /// Still fire-and-forget in the sense that nothing here waits: the answer arrives
  /// on `actionReturns` and comes out on [refusals] if it was a refusal. What the
  /// `ok` below reports is only whether the bytes went out, which is why the two
  /// channels both exist — a `true` here means "asked", not "done".
  ({bool ok, String? detail}) _send(
    String action, {
    required String model,
    required String? id,
    Object? args = _nothing,
  }) {
    final ws = _ws;
    if (ws == null || ws.readyState != WebSocket.open) {
      return (ok: false, detail: 'not connected to Gather');
    }

    try {
      ws.add(msgpackEncode(_actionFrame(action, model: model, id: id, args: args)));
      return (ok: true, detail: null);
    } on Object catch (error) {
      return (ok: false, detail: '$error');
    }
  }

  /// An `Action` frame, with its transaction remembered so the ack can be named.
  Map<String, Object?> _actionFrame(
    String action, {
    required String model,
    required String? id,
    Object? args = _nothing,
  }) {
    final txnId = _txnId();
    // Bounded: a server that stops acknowledging must not turn this into a leak.
    // Insertion-ordered, so the oldest unanswered transaction is the one to drop.
    if (_awaiting.length >= _maxAwaitingActions) {
      _awaiting.remove(_awaiting.keys.first);
    }
    _awaiting[txnId] = action;
    return {
      'type': 'Action',
      'txnId': txnId,
      'action': action,
      // `null` is a legitimate third argument, so absence is its own sentinel
      // rather than null — a two-element tuple is what the server was observed
      // to receive for these, and padding it with null is a different frame.
      'args': [model, id, if (!identical(args, _nothing)) args],
    };
  }

  /// Pairs each verdict with the action it answers, and reports the refusals.
  void _drainResults() {
    for (final result in reader.takeResults()) {
      final action = _awaiting.remove(result.txnId);
      if (result.ok) continue;
      final message = describeActionError(result.error);
      _log('direct: Gather refused ${action ?? 'an action'} — $message');
      if (_refusals.isClosed) continue;
      _refusals.add(ActionRefused(action: action ?? 'that', message: message));
    }
  }

  void _clearTimers() {
    _retryTimer?.cancel();
    _publishTimer?.cancel();
    _heartbeatTimer?.cancel();
    _retryTimer = null;
    _publishTimer = null;
    _heartbeatTimer = null;
  }

  Future<void> _closeSocket() async {
    final ws = _ws;
    _ws = null;
    if (ws == null) return;
    try {
      await ws.close();
    } on Object {
      /* already gone */
    }
  }

  void _setHealth(bool healthy, String? detail, {bool needsPairing = false}) {
    final changed = healthy != _healthy || detail != _lastDetail;
    _healthy = healthy;
    _lastDetail = detail;
    if (!changed) return;
    if (_statuses.isClosed) return;
    _statuses.add(
      CollectorStatus(healthy: healthy, detail: detail, needsPairing: needsPairing),
    );
  }

  void _scheduleRetry() {
    if (_stopped || _retryTimer != null) return;
    final wait = _backoff;
    final next = _backoff * 2;
    _backoff = next > _maxBackoff ? _maxBackoff : next;
    _retryTimer = Timer(wait, () {
      _retryTimer = null;
      _connectNow();
    });
  }

  /// Which space to join, and who we are in it.
  ///
  /// Prefers configuration — the id handed over at pairing — then asks the API.
  /// The bridge can also read the space the desktop client last opened off disk;
  /// the phone has no such shortcut, so the REST call is the fallback rather than
  /// the last resort.
  ///
  /// `/users/me/recent-spaces` hands over `spaceUserId` as well, which is what
  /// `enterSpace` addresses. Getting it here means entering in the same breath as
  /// the rest of the handshake rather than waiting for the `Connection` row to
  /// come back and name us. A configured space id carries no such hint, so that
  /// path enters late instead — see [_maybeEnter].
  Future<({String id, String? spaceUserId})?> _resolveSpace() async {
    if (_configuredSpaceId != null && _configuredSpaceId.isNotEmpty) {
      return (id: _configuredSpaceId, spaceUserId: null);
    }
    final spaces = await _auth.recentSpaces();
    if (spaces.isEmpty) return null;
    return (id: spaces.first.id, spaceUserId: spaces.first.spaceUserId);
  }

  void _connectNow() {
    unawaited(_openConnection());
  }

  Future<void> _openConnection() async {
    if (_stopped) return;
    _clearTimers();
    await _closeSocket();
    if (_stopped) return;

    final String token;
    final ({String id, String? spaceUserId})? resolved;
    try {
      token = await _auth.idToken();
      resolved = await _resolveSpace();
    } on GatherAuthException catch (error) {
      // The one failure the user has to act on, kept distinct from every other:
      // a dead refresh token cannot be retried into working.
      _setHealth(false, 'Gather sign-in failed: ${error.message}',
          needsPairing: error.permanent);
      if (!error.permanent) _scheduleRetry();
      return;
    } on Object catch (error) {
      _setHealth(false, 'Gather sign-in failed: $error');
      _scheduleRetry();
      return;
    }
    if (_stopped) return;

    if (resolved == null) {
      _setHealth(false, 'no space to join — open a space in Gather once');
      _scheduleRetry();
      return;
    }
    final resolvedSpace = resolved.id;
    spaceId = resolvedSpace;

    // The token is the identity; a stored uid is only a cache of it. Reading the
    // token first means stale config cannot silently point us at the wrong
    // account — which would leave `selfId` unresolved and make "following me"
    // unanswerable.
    final authUserId = uidFromIdToken(token) ?? _auth.uid;

    // A fresh reader per connection: the dump we are about to receive is complete,
    // so carrying rows over would only keep ghosts of people who have since left.
    reader = GameProtocolReader(log: _log)..authUserId = authUserId;
    _frames = 0;
    _lastFrameAt = null;
    // Transactions belong to a socket. Carrying them over would pair a new
    // connection's ack with an old connection's action name.
    _awaiting.clear();

    final url = '$_socketUrl?spaceId=${Uri.encodeQueryComponent(resolvedSpace)}'
        '&authUserId=${Uri.encodeQueryComponent(authUserId ?? '')}';
    reader.noteSocketUrl(url);

    final WebSocket ws;
    try {
      ws = await _connect(url);
    } on Object catch (error) {
      _setHealth(false, 'game socket connect failed: $error');
      _scheduleRetry();
      return;
    }
    if (_stopped) {
      await ws.close();
      return;
    }

    _ws = ws;
    _connects++;
    _backoff = const Duration(seconds: 1);
    _entered = false;
    // A fresh socket owes its own presence proof; last connection's doubt or
    // outstanding re-enter must not carry over and reconnect a healthy new one.
    _wasVisible = false;
    _selfDoubtSince = null;
    _reentering = false;
    _reenterAt = null;
    _log('direct: connected to space $resolvedSpace');

    try {
      for (final frame in _handshake(token, resolvedSpace, resolved.spaceUserId)) {
        ws.add(msgpackEncode(frame));
      }
      if (resolved.spaceUserId != null) _entered = true;
    } on Object catch (error) {
      // The encoder refuses rather than sending something Gather would ignore.
      _setHealth(false, 'handshake encode failed: $error');
      await _closeSocket();
      _scheduleRetry();
      return;
    }

    _handshakeAt = DateTime.now();
    // The clock starts at the handshake, not at the first frame: a server that
    // accepts the socket and then says nothing at all is exactly the case worth
    // reconnecting out of, and leaving this null until something arrived would make
    // that the one case the watchdog could not see.
    _lastFrameAt = _handshakeAt;
    _setHealth(false, 'handshake sent; waiting for state');

    _publishTimer = Timer.periodic(_publishInterval, (_) => _flush());
    _heartbeatTimer = Timer.periodic(_heartbeatInterval, (_) => _heartbeat());

    ws.listen(
      (data) {
        if (_ws != ws) return;
        _onFrame(data);
      },
      onError: (Object _) {
        // Deliberately silent. This used to log `direct: game socket error` and
        // nothing else. On the bridge, whose copy of this logged the same line, that
        // produced 387 identical entries over six days carrying no information at
        // all — the close code, the only diagnostic fact available, went to
        // `_setHealth` and never reached the log. `onDone` always follows an error
        // and carries the code, so it is the only place worth logging from.
      },
      onDone: () {
        if (_ws != ws) return;
        _clearTimers();
        _ws = null;
        final code = ws.closeCode ?? 0;
        // 4031 is the duplicate-connection code the gateway was long believed to
        // use. Neither an observer connection nor an entered one triggers it —
        // both were measured — so seeing it here would mean Gather's rules
        // changed and is worth saying out loud.
        final suffix = code == 4031 ? ' — duplicate connection rejected' : '';
        _setHealth(false, 'game socket closed ($code)$suffix');
        _log('direct: ${describeClose(code, ws.closeReason)}; reconnecting');
        _scheduleRetry();
      },
      cancelOnError: false,
    );
  }

  /// The frames that get us subscribed, and then into the room.
  ///
  /// The first four are the subscription. `enterSpace` is the fifth and is what
  /// makes us present; it needs our own `SpaceUser` id, so it is only included
  /// when [spaceUserId] is already known. Otherwise [_maybeEnter] sends it once
  /// the `Connection` row names us.
  ///
  /// A wrong-shaped `Authenticate` is the trap: Gather does not reject it, it simply
  /// never replies and keeps heartbeating, so the failure looks like a network
  /// problem rather than an auth one. These shapes were captured off the desktop
  /// client's own outbound frames, and `msgpack_test.dart` pins the bytes.
  List<Map<String, Object?>> _handshake(
    String token,
    String space,
    String? spaceUserId,
  ) =>
      [
        {
          'type': 'Authenticate',
          'credential': {'type': 'JWT', 'jwt': token},
        },
        {'type': 'ConnectToSpace', 'spaceId': space},
        {'type': 'Subscribe'},
        _actionFrame(
          'loadSpaceUser',
          model: 'SpaceUser',
          id: null,
          args: {'connectionTarget': _connectionTarget, 'clientPlatform': _clientPlatform},
        ),
        if (spaceUserId != null) ..._enterFrames(spaceUserId),
      ];

  /// Entering, and saying we are awake while we are here.
  ///
  /// `reportActivity` earns its place only now: an observer had no business
  /// claiming to be active, but a participant that never reports goes idle and
  /// stops looking present to the people it is talking to.
  List<Map<String, Object?>> _enterFrames(String spaceUserId) => [
        _actionFrame('enterSpace', model: 'SpaceUser', id: spaceUserId),
        _actionFrame(
          'reportActivity',
          model: 'Connection',
          id: null,
          args: {'isActive': true},
        ),
      ];

  /// Enters late, when the handshake could not.
  ///
  /// A configured space id carries no `spaceUserId`, so on that path the first
  /// thing that can tell us who we are is the `Connection` row inside the state
  /// dump. Sent once per connection — `_entered` is reset on every connect, and
  /// entering twice on one socket would increment `numTimesEnteredSpace` twice
  /// for no benefit.
  void _maybeEnter() {
    if (_entered) return;
    final self = reader.selfId;
    if (self == null) return;
    final ws = _ws;
    if (ws == null || ws.readyState != WebSocket.open) return;

    _entered = true;
    try {
      for (final frame in _enterFrames(self)) {
        ws.add(msgpackEncode(frame));
      }
      _log('direct: entered space as $self');
    } on Object catch (error) {
      // Not fatal: we are subscribed and reading either way, and the next
      // connection gets another go.
      _entered = false;
      _log('direct: could not enter the space: $error');
    }
  }

  /// Tears the socket down if nothing has arrived for [silenceLimit].
  ///
  /// Returns true when it acted. The teardown is explicit rather than left to
  /// `onDone`, because [_closeSocket] nulls `_ws` first and the `onDone` handler
  /// guards on identity — so a forced close never reaches [_scheduleRetry] by itself.
  bool _isSilent() {
    final last = _lastFrameAt;
    if (last == null) return false;
    final since = DateTime.now().difference(last);
    if (since < silenceLimit) return false;

    final secs = since.inSeconds;
    _clearTimers();
    unawaited(_closeSocket());
    _setHealth(false, 'no frames for ${secs}s — the socket went deaf; reconnecting');
    _log('direct: nothing from Gather for ${secs}s — the socket went deaf; reconnecting');
    _scheduleRetry();
    return true;
  }

  /// The client's heartbeat, in the desktop client's own shape.
  ///
  /// Two things about it read backwards and both were measured rather than
  /// reasoned about (2026-08-14, two live clients):
  ///
  ///  - **`origin` is not the sender.** The frame the client *sends* carries
  ///    `origin: 'Server'`, and the frame it receives carries `origin: 'Client'`.
  ///    Whatever the field denotes, it is not direction — take that from the frame.
  ///  - **`sequenceNumber` is not our own count.** It echoes the highest sequence
  ///    the *server* has sent us: the desktop's ran 121 → 178 while the server's ran
  ///    124 → 178. It is the resync anchor, so reporting our own send count would be
  ///    telling Gather something untrue about what we have seen.
  ///
  /// Omitted before the first state envelope arrives, because there is genuinely no
  /// sequence to report yet and zero is a claim rather than an absence.
  void _heartbeat() {
    final ws = _ws;
    if (ws == null || ws.readyState != WebSocket.open) return;
    try {
      ws.add(msgpackEncode({
        'type': 'Heartbeat',
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'sequenceNumber': ?reader.lastSequence,
        'origin': 'Server',
      }));
    } on Object {
      // A failed heartbeat means the socket is going; `onDone` handles it.
    }
  }

  /// Sends one heartbeat immediately.
  ///
  /// Public only so a test can assert the frame's shape without waiting out
  /// [_heartbeatInterval] — the timer set up in [_openConnection] is the sole
  /// production caller, and nothing in the app has any reason to beat by hand.
  void sendHeartbeatNow() => _heartbeat();

  void _onFrame(Object? data) {
    if (data is! List<int>) return; // Text on this socket would not be ours.
    Object? frame;
    try {
      frame = msgpackDecode(data is Uint8List ? data : Uint8List.fromList(data));
    } on Object {
      // Not msgpack. Should not happen here, but never throw in a message handler.
      return;
    }
    if (frame is! Map<String, Object?>) return;
    _frames++;
    // Every frame counts as liveness, heartbeats included — the question the
    // watchdog asks is whether the socket still carries anything at all, not whether
    // anything interesting happened.
    _lastFrameAt = DateTime.now();
    if (reader.ingest(frame)) _dirty = true;

    // The state dump is what names us, so this is the first moment the late path
    // can enter. Cheap to ask: it returns immediately once done.
    _maybeEnter();

    // What the server made of what we asked for. Before the interactions, so a
    // refusal is on its way out ahead of any state that arrived with it.
    _drainResults();

    // Interactions go out at once rather than waiting for the publish window.
    // Coalescing exists because nobody needs every intermediate position; a wave is
    // a single deliberate act and there is nothing to coalesce it with.
    if (_interactions.isClosed) return;
    for (final event in reader.takePending()) {
      _interactions.add(event);
    }
  }

  void _flush() {
    // First, because the block below is what was lying. `_frames` is cumulative and
    // reset only on connect, so once it had ever been above zero this reported full
    // health on every tick for as long as the process ran — whether or not a single
    // frame had arrived since. Asking here rather than on the heartbeat also means
    // the answer is never more than one publish interval stale.
    if (_isSilent()) return;

    if (_frames > 0) {
      if (hasState) {
        // Deliberately *not* the frame count. A status whose detail changes four
        // times a second would fill the UI's own history with noise; the user count
        // changes rarely and means something.
        _setHealth(true, '${reader.userCount} space users');
      } else if (_handshakeAt != null &&
          DateTime.now().difference(_handshakeAt!) >= _handshakeGrace) {
        // Frames arriving but still no state means the handshake was not accepted —
        // Gather stays silent rather than rejecting, so say so.
        _setHealth(
          false,
          'connected but holding no state ($_frames frames, heartbeats only) — '
          'the handshake was not accepted',
        );
      }
      // Inside the grace window we leave the status alone: a server heartbeat
      // routinely arrives before the first FullStateChunk.
    }

    // A live socket carrying a roster that does not contain a present us. Checked
    // every tick, not only when the roster changed: going missing is the roster
    // *losing* our row, which is a change like any other, but a roster that then
    // sits still must not let the doubt expire unseen.
    _checkSelfPresence();

    if (!_dirty) return;
    _dirty = false;
    if (!_rosters.isClosed) _rosters.add(reader.roster());
  }

  /// Watches an otherwise-healthy roster for the loss of *us*, and heals it.
  ///
  /// Two rungs, quiet then loud (see [_beginRecovery] and [_forceReconnect]).
  /// Gated on having entered and on the dump having had [_handshakeGrace] to place
  /// us, because before that an absent self row is a connect in progress rather
  /// than a disappearance. The whole point is the case [healthy] cannot see: the
  /// inbound light is green — frames arrive, the roster is current — and yet other
  /// people's offices do not have us in them.
  void _checkSelfPresence() {
    if (!_entered || !hasState) return;

    if (reader.selfVisible) {
      _wasVisible = true;
      // A walk-triggered re-enter cannot be judged by visibility: it was raised
      // precisely because we are visible yet the server ignores our moves. Leave it
      // latched for a confirmed move ([noteMovesConfirmed]) to clear, and only
      // escalate when the grace runs out — the same loud rung as a self-absent
      // re-enter that never took. Any other state is genuinely well: clear it.
      if (_reentering && _reenterFromWalk) {
        final at = _reenterAt;
        if (at != null && DateTime.now().difference(at) > reenterGrace) {
          _forceReconnect('a re-enter did not get our moves flowing again');
        }
        return;
      }
      _notePresenceOk();
      return;
    }

    // Not a present, placed us. Once we have been visible this connection, that is
    // a disappearance and the clock starts at once. Before we have ever been
    // visible it is more likely a dump still assembling, so hold off until the
    // handshake has had [_handshakeGrace] to place us — which also covers the
    // enter that never took at all, just more slowly.
    final now = DateTime.now();
    if (!_wasVisible) {
      final handshakeAt = _handshakeAt;
      if (handshakeAt == null || now.difference(handshakeAt) < _handshakeGrace) return;
    }

    if (_reentering) {
      final at = _reenterAt;
      if (at != null && now.difference(at) > reenterGrace) {
        _forceReconnect('a re-enter did not bring our own row back');
      }
      return;
    }
    final since = _selfDoubtSince ??= now;
    if (now.difference(since) > selfAbsentLimit) {
      _beginRecovery('our own row has been missing for '
          '${now.difference(since).inMilliseconds}ms');
    }
  }

  /// We can see ourselves again: drop every bit of recovery state so the next
  /// disappearance starts its clock from scratch.
  void _notePresenceOk() {
    _selfDoubtSince = null;
    _reentering = false;
    _reenterAt = null;
    _reenterFromWalk = false;
  }

  /// The quiet first rung: re-send `enterSpace` on the socket we already hold and
  /// give it [_reenterGrace] to take, without a word to the user. Most presence
  /// blips are a dropped enter, and this fixes them before anyone notices.
  ///
  /// A no-op while a re-enter is already outstanding, while stopped, or while a
  /// reconnect is already scheduled — the ladder owns one attempt at a time, and
  /// the deaf watchdog ([_isSilent]) owns the socket once it has decided to retry.
  void _beginRecovery(String why, {bool fromWalk = false}) {
    final ws = _ws;
    if (_reentering || _stopped || _retryTimer != null) return;
    if (ws == null || ws.readyState != WebSocket.open) return;
    _log('direct: presence doubt — $why; re-entering');
    _entered = false;
    _maybeEnter();
    _reentering = true;
    _reenterAt = DateTime.now();
    _reenterFromWalk = fromWalk;
  }

  /// The loud second rung: the re-enter did not bring us back, so stop believing
  /// the socket and reconnect from scratch — which replays the whole dump and
  /// enters again. This is where the banner finally appears; everything before it
  /// was silent on purpose, so a working app stays a working app through a blink.
  void _forceReconnect(String why) {
    _log('direct: $why — reconnecting');
    _notePresenceOk();
    _clearTimers();
    unawaited(_closeSocket());
    _setHealth(false, 'reconnecting — restoring your presence');
    _scheduleRetry();
  }
}

final _random = Random();

/// A v4-shaped transaction id.
///
/// Only has to be unique within one connection — Gather keys `actionReturns` by it
/// and we never read them back — so `Random` is plenty and avoids a dependency.
String _txnId() {
  final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}'
      '-${hex.substring(16, 20)}-${hex.substring(20)}';
}

/// What a close code means, in words, for the log.
///
/// Exported because it is the whole point of the change that produced it: the
/// bridge's copy of this collector logged 387 undifferentiated `game socket error`
/// lines over six days, and every one of them was one of the first two cases below —
/// Gather recycling the connection, or a device losing its network. Neither is a
/// fault. Saying which is what makes the third case, an actual fault, visible.
///
/// Mirrors `describeClose` in `bridge/lib/direct.js`; the two must not drift.
String describeClose(int code, [String? reason]) {
  final said = (reason == null || reason.isEmpty) ? '' : ' — "$reason"';
  return switch (code) {
    // RFC 6455 1012. Gather's gateway closing us on purpose as it recycles or
    // redeploys. Routine, frequent, and nothing to act on.
    1012 => 'Gather recycled the connection (1012)$said',
    // 1006 is synthesised by the client when the peer vanished without a close
    // frame: a suspended laptop, a phone changing cell, a NAT rebinding.
    1006 => 'the connection dropped without a close frame (1006)$said',
    1001 => 'Gather is going away (1001)$said',
    1000 => 'Gather closed the connection normally (1000)$said',
    // Long believed to be the duplicate-connection code. Neither an observer nor an
    // entered connection has ever triggered it, so this means Gather's rules changed.
    4031 => 'duplicate connection rejected (4031)$said',
    _ => 'the game socket closed ($code)$said',
  };
}
