/// What the app talks to for presence: the game-socket side of Gather, named as
/// an interface so something other than a live WebSocket can stand in its place.
///
/// This exists for the same reason [Call] does. The presence plane is a socket a
/// test runner — or a simulator with no network — has no way to reach, and the
/// whole app reads off it: the roster, the map, the activity bus, who is talking,
/// where everyone is standing. `AppState` holds one of these, and `Walk` and
/// `PartyMode` reach the same object through a closure, so a fake that implements
/// this interface makes the office walkable, party mode runnable and the feed
/// alive with no server behind any of it — see `lib/harness/fake_collector.dart`.
///
/// [DirectCollector] is the real one, a WebSocket to Gather's game router. Every
/// member here is one the app already calls on it; this is that surface, named,
/// not a new capability. The compiler keeps the two in step —
/// `DirectCollector implements Collector`.
library;

import 'dart:async';

import 'game_protocol.dart';
import 'space_art.dart';
import 'space_map.dart';

/// An action the server refused, named.
///
/// The whole reason this type exists: a refused action produces **no patch**, and
/// validation runs before the action does — so a wrong argument executes nothing,
/// changes nothing, and says nothing on any channel a patch-watching client reads.
/// The only evidence is `actionReturns`, and it names the transaction rather than
/// the action, so the two have to be paired up on this side.
class ActionRefused {
  const ActionRefused({required this.action, required this.message});

  /// The action's own id — `setCustomStatus`, `teleport`, `enterSpace`.
  final String action;

  /// One sentence, already unwrapped from a zod issue list where it was one.
  final String message;

  @override
  String toString() => 'ActionRefused($action: $message)';
}

/// Whether the collector is holding state, and what to say if not.
class CollectorStatus {
  const CollectorStatus({required this.healthy, this.detail, this.needsPairing = false});

  final bool healthy;
  final String? detail;

  /// The credential is dead and only re-pairing will fix it. The one status the UI
  /// must turn into an instruction rather than a spinner.
  final bool needsPairing;

  @override
  String toString() => 'CollectorStatus($healthy, $detail)';
}

/// The presence plane, as the app uses it.
///
/// The actions all return `({bool ok, String? detail})` — fire-and-forget on the
/// wire, with the authoritative answer arriving later on [rosters] — except
/// [resync], which awaits a reconnect.
abstract interface class Collector {
  // ---- what the app listens to ----------------------------------------------

  /// The roster, coalesced. One event per change worth rendering.
  Stream<Roster> get rosters;

  /// Waves and the rest of Gather's event bus, published the moment they arrive.
  Stream<BusEvent> get interactions;

  /// Whether the collector is holding state, and what to say if not.
  Stream<CollectorStatus> get statuses;

  /// Actions the server would not run.
  Stream<ActionRefused> get refusals;

  // ---- what the app reads ----------------------------------------------------

  /// The space this collector resolved and connected to, once it has one.
  ///
  /// The ground truth of which office the live reader is populated for — unlike the
  /// roster-derived snapshot, it does not go blank between dumps, so a held map can
  /// pin itself to it and know when a reconnect lands in a different space.
  String? get spaceId;

  /// Our own `SpaceUser` id, once the dump has told us which row is us.
  String? get selfId;

  /// Our own `UserAccount` id — what the media plane keys on.
  String? get selfAccountId;

  /// Whether the socket is believed live.
  bool get healthy;

  /// Whether we hold state, as opposed to merely being connected.
  bool get hasState;

  /// The floor plan for a floor, or null until enough of it has arrived.
  SpaceMap? mapFor(String? floorId);

  /// The same floor, drawn, or null — floor tiles, walls and furniture sprites.
  SpaceArt? artFor(String? floorId, {bool dark = true});

  /// Somebody's avatar spritesheet, or null when their outfit is not known.
  String? avatarUrlFor(String spaceUserId);

  // ---- lifecycle -------------------------------------------------------------

  void start();
  Future<void> dispose();

  // ---- what the app writes ---------------------------------------------------

  /// Takes one step. What the D-pad sends.
  ({bool ok, String? detail}) move({required String direction});

  /// Says how fast we are going, which is what puts a go-kart under the avatar.
  ({bool ok, String? detail}) setGait(Gait gait);

  /// Moves our avatar to a tile.
  ({bool ok, String? detail}) teleport({required num x, required num y, String direction});

  /// Active, Busy or Away.
  ({bool ok, String? detail}) setAvailability(String availability);

  /// The line of text under your name, with an emoji beside it.
  ({bool ok, String? detail}) setCustomStatus({required String text, String? emoji, DateTime? clearAt});

  /// Takes the status line down.
  ({bool ok, String? detail}) clearCustomStatus();

  /// Throws an emoji over the room.
  ({bool ok, String? detail}) broadcastEmote(String emote, {int count});

  /// Waves at one person. Fire-and-forget; the server replays it on [interactions]
  /// as a `WaveEvent` naming the recipient — but, unlike an emote, not back to us.
  ({bool ok, String? detail}) wave(String targetSpaceUserId);

  /// Says whether we are talking. This is the speaking ring.
  ({bool ok, String? detail}) setSpeaking(bool speaking);

  /// Steps out of the huddle without walking away from it.
  ({bool ok, String? detail}) leaveCluster();

  /// Says whether the person is actually at the phone.
  ({bool ok, String? detail}) setActive(bool active);

  /// Reconnects, which is all a resync is here: the server replays the full state
  /// dump on every new connection.
  Future<({bool ok, String detail})> resync();
}
