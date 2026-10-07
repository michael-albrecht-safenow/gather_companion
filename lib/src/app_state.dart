import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:gather_client/gather_client.dart';
import 'package:gather_events/gather_events.dart';

import 'credentials.dart';
import 'directory.dart';
import 'link_status.dart';
import 'map_person.dart';
import 'media/call.dart';
import 'notifications.dart';
import 'pairing.dart';
import 'push.dart';
import 'reactions.dart';
import 'settings.dart';
import 'ui_preferences.dart';

/// Everything the UI reads. One object, so the whole app is a single
/// `ListenableBuilder` away from being correct.
///
/// ## What changed, and why it is simpler
///
/// This used to hold a `BridgeClient` — a WebSocket to a computer on the same wifi,
/// with sequence-based catch-up, ping-driven liveness and a generation counter to
/// stop overlapping resumes from orphaning sockets. All of that existed because the
/// phone could not talk to Gather.
///
/// It can. So the socket is now to Gather itself, and the bridge is left with two
/// jobs: handing over the credential at pairing, and pushing when this app is not
/// running. Three consequences worth knowing:
///
///  * **The computer can be asleep.** Presence works on cellular, from anywhere.
///  * **Party mode is instant.** It runs here, against a socket we already hold, so
///    the optimistic-UI dance that hid a LAN round trip is gone entirely.
///  * **Nothing is remembered.** There is no 500-event ring on the bridge to
///    replay, and the phone does not keep one either: a log that can only record
///    what happened while the app was open is empty exactly when it would be worth
///    reading. Events exist to be notified about. `_onFold` hands each one to
///    [Notifier] and lets it go.
class AppState extends ChangeNotifier {
  // A named parameter cannot be a private initializing formal, so the fields are
  // assigned the long way round.
  AppState({
    Notifier? notifier,
    PushRegistrar? push,
    GatherCredentialStore? credentials,
    BridgeSettingsStore? bridge,
    // Test seam: lets a suite — or the simulator harness — drive a fake Gather
    // without a network, by handing back a [Collector] that is not a socket.
    Collector Function(GatherAuth auth, String? spaceId)? buildCollector,
    ActivityFeed Function(GatherAuth auth)? buildActivityFeed,
    // The media seam, and the reason this file does not import `flutter_webrtc`:
    // a [Call] is a microphone, a camera and an SFU, none of which a test runner
    // has. `main.dart` supplies the real one.
    Call Function(GatherAuth auth, String spaceId, String srcId)? buildCall,
    // Diagnostic sink. `main.dart` hands in `mediaLog`, which also lands on disk
    // (`tmp/media.log`) so a standalone phone build keeps a record; a test leaves
    // it null and the lines are discarded. Threaded into the collector and [Walk]
    // so the movement and socket diagnostics — refusals, snap-backs, cluster
    // changes — are actually recorded rather than written to a dead `_noop`.
    void Function(String)? log,
    // Test seams for the network-change watcher. Production uses the real plugin;
    // a suite injects a controller it can push interface changes through, and a
    // current-state probe it can answer synchronously. See [_onConnectivityChanged].
    Stream<List<ConnectivityResult>>? connectivityChanges,
    Future<List<ConnectivityResult>> Function()? connectivityNow,
    // Test seam for the resync cooldown clock. Production reads the wall clock.
    DateTime Function()? now,
    UiPreferences? uiPreferences,
  }) : _notifier = notifier ?? Notifier(),
       _connectivityChanges =
           connectivityChanges ?? Connectivity().onConnectivityChanged,
       _connectivityNow = connectivityNow ?? Connectivity().checkConnectivity,
       _now = now ?? DateTime.now,
       // ignore: prefer_initializing_formals
       _push = push,
       _credentialStore = credentials ?? GatherCredentialStore(),
       _bridgeStore = bridge ?? BridgeSettingsStore(),
       _log = log ?? _noop,
       _uiPrefs = uiPreferences ?? UiPreferences(),
       _buildCollector = buildCollector ??
           ((auth, spaceId) =>
               DirectCollector(auth: auth, spaceId: spaceId, log: log ?? _noop)),
       _buildActivityFeed = buildActivityFeed ?? _realActivityFeed,
       // ignore: prefer_initializing_formals
       _buildCall = buildCall;

  static void _noop(String _) {}

  static ActivityFeed _realActivityFeed(GatherAuth auth) => ActivityFeed(auth: auth);

  final Notifier _notifier;
  Notifier get notifier => _notifier;

  final GatherCredentialStore _credentialStore;
  final BridgeSettingsStore _bridgeStore;
  final UiPreferences _uiPrefs;
  final Collector Function(GatherAuth auth, String? spaceId) _buildCollector;
  final ActivityFeed Function(GatherAuth auth) _buildActivityFeed;
  final void Function(String) _log;
  final Stream<List<ConnectivityResult>> _connectivityChanges;
  final Future<List<ConnectivityResult>> Function() _connectivityNow;
  final DateTime Function() _now;

  /// The last interface set seen, so a change is told from a repeat. Seeded from
  /// [_connectivityNow] on attach so the first real handoff is not swallowed.
  List<ConnectivityResult>? _lastConnectivity;

  /// When the network watcher last forced a resync, to coalesce the burst of
  /// events a single handoff emits into one reconnect.
  DateTime? _lastNetResync;

  /// Null in a build with no media layer — a widget test, or a platform where
  /// there is nothing to capture. [canCall] reads false and the bar says so,
  /// rather than offering a button that throws when pressed.
  final Call Function(GatherAuth auth, String spaceId, String srcId)? _buildCall;

  /// Built lazily and never eagerly: `FirebaseMessaging.instance` throws when
  /// Firebase was not initialised, which is the normal state in widget tests and on a
  /// build without a `GoogleService-Info.plist`.
  PushRegistrar? _push;
  StreamSubscription<String>? _pushRefresh;

  PushRegistrar? _pushRegistrar() {
    try {
      return _push ??= PushRegistrar();
    } catch (_) {
      return null;
    }
  }

  // ---- the Gather connection -------------------------------------------------

  Collector? _collector;
  PartyMode? _party;
  Walk? _walk;

  /// Held from [_attach], because the call is built later — on the first tap —
  /// and needs the same credential the socket runs on.
  GatherAuth? _auth;
  Call? _call;
  final PresenceTracker _tracker = PresenceTracker();
  final _subs = <StreamSubscription<dynamic>>[];

  /// Where the bridge is, for push registration only. Nothing renders from it —
  /// [_pushReach] is what the settings card reads, because that one has been tested
  /// against the actual computer.
  BridgeSettings _settings = BridgeSettings.empty;
  PushRegistration _pushReach = PushRegistration.unknown;
  GatherCredentials _credentials = GatherCredentials.empty;
  String? _spaceId;

  PresenceSnapshot _snapshot = PresenceSnapshot.empty;
  LinkStatus _link = const LinkStatus(LinkState.idle);
  bool _loaded = false;
  String? _bridgeName;

  BridgeSettings get settings => _settings;
  PresenceSnapshot get snapshot => _snapshot;
  LinkStatus get link => _link;
  bool get isLoaded => _loaded;
  String? get bridgeName => _bridgeName;

  /// Whether this phone can read Gather on its own.
  ///
  /// The Gather credential, not the bridge token: reading presence is what the screen
  /// is for. A pairing that produced no session leaves the app here, which is correct:
  /// the fix is one command on the Mac, and pretending otherwise would show a screen
  /// that can never answer anything.
  bool get isConfigured => _credentials.isComplete;

  /// How close the bridge is to being able to wake this phone while the app is closed.
  ///
  /// Independent of [isConfigured] on purpose: presence works without it, and losing
  /// push is a degradation rather than a failure.
  ///
  /// This is the *result of the last attempt*, not an inference from what is stored.
  /// It used to be `_settings.isComplete` — "do we know a host and a token" — which
  /// meant the settings screen claimed a computer was unreachable without anything
  /// ever having tried to reach it, and claimed it was reachable forever once it had
  /// been paired. Both were wrong in the direction that hides a real fault.
  /// There is deliberately no `canBeWoken` boolean beside this. Collapsing these six
  /// answers back to one is what produced a card that sent people to check a computer
  /// that was fine; ask [PushRegistration.isArmed] if that really is the question.
  PushRegistration get pushReach => _pushReach;

  /// Who is following me — the only thing this app claims to know about anyone.
  ///
  /// Sorted by name so the chips keep their places between snapshots. Roster order is
  /// Gather's own map iteration and shuffles for reasons that have nothing to do with
  /// people, which reads as flicker.
  List<PlayerRef> get followers {
    final list = _snapshot.players.where((p) => p.isFollowingMe).toList()..sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
    return list;
  }

  // ---- the directory (Warp Dial) ---------------------------------------------
  //
  // The Dial tab is a phone-app over the roster: a contact list and the
  // conversations already happening, each a tap away from being teleported into.
  // It reads [_roster] directly for the same reason `peopleOnMap` does — the map's
  // digest drops positions and the offline, and this screen wants both: everyone
  // in the space, and somewhere to land next to the ones who are here.

  /// Everybody in the space except me, present first and then by name.
  ///
  /// Present-before-offline rather than one flat alphabet, because "who can I
  /// reach right now" is the question the screen answers and a train of greyed-out
  /// names above the people actually here would bury it. Within each group the
  /// sort is the same case-insensitive name order [followers] uses, so the list
  /// keeps its places between the four-a-second rosters instead of flickering as
  /// Gather reshuffles its map iteration.
  List<Contact> get directory {
    final roster = _roster;
    if (roster == null) return const [];
    final selfId = roster.selfId;
    final out = <Contact>[
      for (final row in roster.rows)
        if (row.id != selfId) Contact.fromRow(row),
    ];
    out.sort((a, b) {
      if (a.isPresent != b.isPresent) return a.isPresent ? -1 : 1;
      return a.label.toLowerCase().compareTo(b.label.toLowerCase());
    });
    return out;
  }

  /// Whether [warpToPerson] has somewhere to send you: the contact is here, carries
  /// a position, and is on your floor. The Dial tab offers the warp only when this
  /// holds, so a cross-floor or unplaced contact is shown but not called — the same
  /// answer [warpToPerson] gives, decided once here so the button and the action
  /// cannot disagree.
  bool canWarpTo(Contact contact) {
    if (!contact.isReachable) return false;
    final myFloor = _myRow()?.floorId;
    return myFloor == null || contact.floorId == null || contact.floorId == myFloor;
  }

  /// The conversations happening now — every cluster of two or more connected
  /// people — the one I am in first, then the largest.
  ///
  /// A cluster of only me is not here: `clusterId` is null when I stand alone, and
  /// a group whose only other members have dropped their sockets is no longer a
  /// conversation to join. [Meeting.roomName] is filled in when a majority of a
  /// cluster's members sit inside the same named area, so the card can name the
  /// room rather than only its people.
  List<Meeting> get meetings {
    final roster = _roster;
    if (roster == null) return const [];
    final selfId = roster.selfId;
    final map = this.map;

    final groups = <String, List<RosterRow>>{};
    for (final row in roster.rows) {
      final cid = row.clusterId;
      if (cid == null) continue;
      // A cluster outlives a dropped socket, and a row that is connected but has
      // gone Offline is not in the room either — its coordinates are wherever it
      // logged off. Both read as "not present", the same test the directory and map
      // use; only a present person is somebody to count. My own row always counts:
      // it is how `includesMe` knows the conversation is mine, and the roster does
      // not always carry presence for self.
      if (row.id != selfId && !row.isPresent) continue;
      (groups[cid] ??= <RosterRow>[]).add(row);
    }

    final out = <Meeting>[];
    groups.forEach((cid, rows) {
      if (rows.length < 2) return;
      final includesMe = rows.any((row) => row.id == selfId);
      final members = [
        for (final row in rows)
          if (row.id != selfId) Contact.fromRow(row),
      ];
      // Only me left once mine are excluded — nothing to join.
      if (members.isEmpty) return;
      // The floor the conversation is on, and the map whose rooms can name it. A
      // single-floor space carries no floorId at all, so an empty set means "the one
      // floor" and resolves to the map we are already looking at. One floor names it
      // off that floor's plan. Members straddling two floors are no single room and
      // nowhere a one-hop warp can land, so they stay unroomed and unplaced.
      final floors = <String>{
        for (final row in rows)
          if (row.floorId != null && row.x != null && row.y != null && row.x!.isFinite && row.y!.isFinite)
            row.floorId!,
      };
      final floorId = floors.length == 1 ? floors.first : null;
      final floorMap = floors.length > 1 ? null : (floorId == null ? map : (_collector?.mapFor(floorId) ?? map));
      out.add(Meeting(
        clusterId: cid,
        members: members,
        roomName: _roomNameFor(rows, floorMap),
        floorId: floorId,
        includesMe: includesMe,
      ));
    });

    out.sort((a, b) {
      if (a.includesMe != b.includesMe) return a.includesMe ? -1 : 1;
      return b.members.length.compareTo(a.members.length);
    });
    return out;
  }

  /// The named area a conversation is in, or null.
  ///
  /// Each member is placed in the *innermost* named, non-desk area at their feet —
  /// the smallest rectangle containing them, so a meeting room wins over the public
  /// zone it sits inside. The cluster takes a room's name only when a strict majority
  /// of *all* its members sit in it; a conversation spilling across a doorway has no
  /// one room and is better named by its people. The denominator is every member,
  /// not only the placed ones: a member the roster has not located is no evidence
  /// that a majority is inside, so a cluster that is mostly unplaced stays unnamed.
  String? _roomNameFor(List<RosterRow> rows, SpaceMap? map) {
    if (map == null) return null;
    final counts = <String, int>{};
    for (final row in rows) {
      final x = row.x, y = row.y;
      if (x == null || y == null || !x.isFinite || !y.isFinite) continue;
      final name = _innermostNamedRoomAt(map, x.round(), y.round())?.name;
      if (name != null) counts[name] = (counts[name] ?? 0) + 1;
    }
    if (counts.isEmpty) return null;
    String? best;
    var bestCount = 0;
    counts.forEach((name, count) {
      if (count > bestCount) {
        bestCount = count;
        best = name;
      }
    });
    // A strict majority of everyone in the cluster: a conversation split across a
    // doorway, or mostly made of members the roster has not placed, has no one room
    // and is better named by its people.
    return bestCount * 2 > rows.length ? best : null;
  }

  /// The smallest named, non-desk room containing the tile — the one a person in
  /// it would say they are in.
  SpaceRoom? _innermostNamedRoomAt(SpaceMap map, int x, int y) {
    SpaceRoom? best;
    for (final room in map.rooms) {
      if (room.name == null || room.type == 'Desk') continue;
      if (!room.contains(x, y)) continue;
      if (best == null || room.width * room.height < best.width * best.height) {
        best = room;
      }
    }
    return best;
  }

  // ---- the map ---------------------------------------------------------------

  /// The last roster, kept whole.
  ///
  /// [PresenceSnapshot] deliberately drops positions — knowing who is *near* you
  /// says nothing about whether they want you, which is the mistake this app was
  /// built to stop making. The map screen is the one place where a coordinate is
  /// the point rather than a proxy for something else, so it reads the roster
  /// directly instead of widening `PlayerRef` for everybody.
  Roster? _roster;

  /// Ticks whenever a roster lands, which is up to four times a second.
  ///
  /// Separate from [notifyListeners] on purpose. Movement is not a presence event:
  /// [PresenceTracker] does not look at coordinates at all, so a roster where
  /// everybody walked leaves `stateChanged` false and never reaches the UI — which
  /// is right for every screen except the one that draws positions, where it meant
  /// the map froze until somebody happened to follow you or disconnect.
  ///
  /// Waking the whole tree at 4Hz to fix that would be the other mistake: the feed
  /// would rebuild on a stranger's footstep. So this is its own [Listenable] and
  /// only the map listens. With the map closed it has no listeners and a tick costs
  /// nothing.
  Listenable get positions => _positions;
  final _positions = _Ticker();

  /// Ticks when the directory's shape changes — somebody arriving or leaving, a
  /// conversation forming or breaking up, an availability dot turning.
  ///
  /// Its own [Listenable] for the same reason as [positions], and the mirror image of
  /// it: the Dial tab must wake for these presence folds the shell's own
  /// [notifyListeners] misses (availability and `clusterId` are not part of the
  /// presence fold), but it must *not* wake for the footsteps [positions] carries
  /// four times a second. This is the projection in between — the fields the
  /// directory sorts and groups on — and nothing else. See [_noteDirectory].
  Listenable get directoryChanges => _directoryChanges;
  final _directoryChanges = _Ticker();
  String? _lastDirectoryDigest;

  /// The last hop party mode fired, for the map to draw as a teleport.
  ///
  /// The map cannot tell a teleport from a walk by looking at the roster. Positions
  /// arrive component-wise and coalesced over 250ms, so one hop can reach the screen
  /// as two short moves that are indistinguishable from somebody walking — which is
  /// how a teleport ends up being drawn as a slow glide across the office. This is
  /// the fact instead: we fired it, so we know.
  ///
  /// [seq] is what makes it safe to read from `build`. A rebuild happens for all
  /// sorts of reasons and must not replay the same hop; the map remembers the last
  /// sequence it drew and ignores anything it has already seen.
  ({String id, double x, double y, int seq})? get lastTeleport => _lastTeleport;
  ({String id, double x, double y, int seq})? _lastTeleport;
  int _teleportSeq = 0;

  /// The space's own name, as Gather has it — "SafeNow", not "The office".
  ///
  /// From the single `Space` row in the state dump, carried through the snapshot.
  String? get spaceName => _snapshot.self.spaceName;

  /// The floor plan, or null until enough of it has arrived.
  SpaceMap? get map => debugMap ?? _collector?.mapFor(_myRow()?.floorId);

  /// The same floor's artwork — what to draw, and the images to fetch for it.
  ///
  /// Dark, because the app is: the client keeps a second set of files for its dark
  /// appearance and picking the light ones would put a white office inside a black
  /// phone.
  SpaceArt? get art => debugArt ?? _collector?.artFor(_myRow()?.floorId, dark: true);

  /// Test seam, as [debugMap].
  @visibleForTesting
  SpaceArt? debugArt;

  /// Test seam. The real map is assembled from ~1700 patches inside a live state
  /// dump, which is not a thing a widget test can arrange.
  @visibleForTesting
  SpaceMap? debugMap;

  RosterRow? _myRow() {
    final roster = _roster;
    if (roster == null) return null;
    for (final row in roster.rows) {
      if (row.id == roster.selfId) return row;
    }
    return null;
  }

  /// Where I am, in tiles, or null before the first roster. Rounded, because its
  /// callers ask questions about tiles — which room am I in — rather than drawing.
  ({int x, int y})? get myTile {
    final me = _myRow();
    final x = me?.x, y = me?.y;
    if (x == null || y == null || !x.isFinite || !y.isFinite) return null;
    return (x: x.round(), y: y.round());
  }

  /// Me, in the same shape as everybody else, for the map to draw.
  ///
  /// Separate from [peopleOnMap], which deliberately excludes me: every other screen
  /// wants "other people", and only this one wants the whole room including myself.
  MapPerson? get mePerson {
    final me = _myRow();
    final x = me?.x, y = me?.y;
    if (me == null || x == null || y == null || !x.isFinite || !y.isFinite) return null;
    return MapPerson(
      id: me.id,
      label: me.name ?? 'You',
      x: x.toDouble(),
      y: y.toDouble(),
      isFollowingMe: false,
      // Ours, not the roster's. See [amSpeaking] — the roster agrees a beat
      // later, and a beat is visible on your own avatar.
      speaking: _amSpeaking,
      dancing: me.dancing == true,
      avatarUrl: _collector?.avatarUrlFor(me.id),
      direction: me.direction,
      // Mine off [Walk] and not off the row. The gait changes twice inside a single
      // route and the roster is coalesced to a quarter of a second, so reading my own
      // back off the wire would show me climbing into the kart two tiles after the
      // avatar started driving, and still in it after I stopped.
      gait: gait,
      availability: me.availability,
      isMe: true,
    );
  }

  /// Everyone else who is actually here, with somewhere to draw them.
  ///
  /// Offline rows are excluded: their coordinates are wherever somebody logged off,
  /// so drawing them would populate the map with people who are not in the building.
  /// That test is [RosterRow.isPresent] and not `connected`, because `connected`
  /// goes stale — measured against a real space, eleven of the twelve rows claiming
  /// it were people who had gone home, and the map drew all of them.
  List<MapPerson> get peopleOnMap {
    final roster = _roster;
    if (roster == null) return const [];
    final floorId = _myRow()?.floorId;
    final followers = {
      for (final p in _snapshot.players)
        if (p.isFollowingMe) p.id,
    };
    final out = <MapPerson>[];
    for (final row in roster.rows) {
      if (row.id == roster.selfId) continue;
      if (!row.isPresent) continue;
      final x = row.x, y = row.y;
      if (x == null || y == null || !x.isFinite || !y.isFinite) continue;
      if (row.floorId != null && floorId != null && row.floorId != floorId) continue;
      out.add(
        MapPerson(
          id: row.id,
          label: row.name ?? row.id.substring(0, row.id.length.clamp(0, 6)),
          x: x.toDouble(),
          y: y.toDouble(),
          isFollowingMe: followers.contains(row.id),
          // Off the roster row, not off the presence snapshot. The snapshot is
          // only rebuilt when the fold reports a state change, and the tracker
          // deliberately does *not* report one for `speaking` unless that person
          // is following you — a guard written when followers were the only
          // people this app drew. It now draws the whole floor, so reading
          // `speaking` from there left everybody permanently silent. The map
          // repaints on `positions` every roster anyway, so this costs nothing.
          speaking: row.speaking == true,
          dancing: row.dancing == true,
          avatarUrl: _collector?.avatarUrlFor(row.id),
          direction: row.direction,
          gait: gaitOf(row.speed),
          availability: row.availability,
        ),
      );
    }
    // Roster order is Gather's own map iteration and shuffles between snapshots.
    // The painter decides whether to repaint by comparing this list position by
    // position, so a stable order is what makes that comparison mean anything.
    out.sort((a, b) => a.id.compareTo(b.id));
    return out;
  }

  PartyState get party => _snapshot.party;

  /// Party mode runs in this process now, so what it says is what is true — no
  /// optimistic override, and nothing to reconcile against a later snapshot.
  bool get partyMode => _snapshot.party.active;
  bool get partyPending => false;

  /// Whether the office tab wears the retro handheld shell. A pure look-and-input
  /// preference — every underlying action is the same one the normal controls
  /// call — so it lives next to [partyMode] as one more switch the app owns, read
  /// back from [UiPreferences] at [boot] and persisted the moment it flips.
  bool _gameboyMode = false;
  bool get gameboyMode => _gameboyMode;

  Future<void> setGameboyMode(bool on) async {
    if (_gameboyMode == on) return;
    _gameboyMode = on;
    notifyListeners();
    await _uiPrefs.saveGameboyMode(on);
  }

  /// Development shortcut past the scanner:
  /// `--dart-define=GATHER_PAIR=host:port:token:refreshToken`.
  ///
  /// The simulator has no camera, so without this there is no way to reach the main
  /// screen while working on it. Empty in any normal build.
  static const _devPair = String.fromEnvironment('GATHER_PAIR');

  Future<void> boot() async {
    _settings = await _bridgeStore.load();
    _bridgeName = await _bridgeStore.loadName();
    _credentials = await _credentialStore.load();
    _spaceId = await _credentialStore.loadSpaceId();
    _gameboyMode = await _uiPrefs.loadGameboyMode();

    if (!_credentials.isComplete && _devPair.isNotEmpty) {
      final parts = _devPair.split(':');
      if (parts.length >= 4) {
        _settings = BridgeSettings(host: parts[0], port: int.tryParse(parts[1]) ?? BridgeSettings.defaultPort, token: parts[2]);
        _credentials = GatherCredentials(refreshToken: parts[3]);
        _bridgeName = 'dev · ${parts[0]}';
      }
    }

    _loaded = true;
    await _notifier.init();
    notifyListeners();

    if (_credentials.isComplete) _attach();
  }

  /// Trades a scanned or typed pairing code for both credentials.
  ///
  /// Returns null when it took, or a sentence to put in front of the user.
  Future<String?> pair({required String host, required int port, required String code}) async {
    final result = await claimPairing(host: host, port: port, code: code);
    switch (result) {
      case PairFailure(:final message):
        return message;
      case PairSuccess(:final settings, :final name, :final gather, :final spaceId):
        _settings = settings;
        _bridgeName = name;
        await _bridgeStore.save(settings);
        await _bridgeStore.saveName(name);

        if (!gather.isComplete) {
          // Pairing worked; the bridge simply has no Gather session to give. Say so
          // rather than landing on a feed that can never fill.
          notifyListeners();
          return 'Paired with $name, but it has no Gather session to give. '
              'Sign in to Gather on the computer, then pair again — pairing is '
              'what reads the session across.';
        }

        _credentials = gather;
        _spaceId = spaceId;
        await _credentialStore.save(gather);
        await _credentialStore.saveSpaceId(spaceId);

        await _notifier.requestPermission();
        _snapshot = PresenceSnapshot.empty;
        notifyListeners();
        _attach();
        return null;
    }
  }

  Future<void> unpair() async {
    await _bridgeStore.clear();
    await _credentialStore.clear();
    _settings = BridgeSettings.empty;
    _credentials = GatherCredentials.empty;
    _spaceId = null;
    _bridgeName = null;
    _pushReach = PushRegistration.unknown;
    _snapshot = PresenceSnapshot.empty;
    await _detach();
    _link = const LinkStatus(LinkState.idle);
    notifyListeners();
  }

  /// Starts or stops teleporting my avatar around the map.
  ///
  /// Synchronous in everything but signature: party mode runs in this process against
  /// a socket already open, so there is nothing to wait for and nothing to be
  /// optimistic about. The `Future` stays so the call sites do not have to change.
  Future<String?> setPartyMode(bool on) async {
    final party = _party;
    if (party == null) return 'Not connected to Gather.';

    if (!on) {
      _onPartyChanged(party.stop());
      return null;
    }
    final result = party.start();
    _onPartyChanged(result.state);
    return result.ok ? null : (result.state.detail ?? 'Party mode could not start.');
  }

  // ---- being a person in the room ---------------------------------------------
  //
  // Everything here addresses our own `SpaceUser` row, which is the same row the
  // desktop client drives. There is no second body: setting yourself Busy on the
  // phone is the same act as setting it on the Mac, and it lands in one place.

  /// My availability as Gather has it — `Active`, `Busy`, `Away`, and the two
  /// `Focused` states a focus area sets. Null before the first roster.
  ///
  /// Read back off the roster rather than remembered, so the desktop client
  /// changing it is reflected here without this app being told.
  String? get myAvailability => _myRow()?.availability;

  /// Who I am in a conversation with — Gather's `clusterId`, which is how it
  /// remembers who is talking to whom.
  ///
  /// What makes "leave the conversation" a control that is only offered when
  /// there is one to leave, the same rule the D-pad follows: a button that cannot
  /// do anything is indistinguishable from a broken one.
  List<String> get huddle => debugHuddle ?? [for (final row in _roster?.myCluster ?? const []) row.name ?? 'Someone'];

  bool get inHuddle => huddle.isNotEmpty;

  /// The rows behind [huddle], for a screen that needs to put a face to a name and
  /// match it against the media plane rather than only print it.
  List<RosterRow> get huddleRows => _roster?.myCluster ?? const [];

  /// My availability and status line as the tree last heard about them.
  ({String? availability, String? text, String? emoji})? _mine;

  /// Wakes the tree when my own availability or status line changes.
  ///
  /// The presence tracker judges everybody else's rows and deliberately not mine, so
  /// a roster confirming "you are Busy now" folded to no change at all. Nothing
  /// listening to this notifier heard it: the status sheet lit the new chip only when
  /// a second tap happened to redraw it, and the dot on the dock's avatar waited for
  /// some unrelated socket frame. Compared by value rather than by row, because the
  /// row is a new object on every roster.
  void _noteMine() {
    final row = _myRow();
    final status = row?.status;
    final mine = (availability: row?.availability, text: status?.text, emoji: status?.emoji);
    if (mine == _mine) return;
    _mine = mine;
    notifyListeners();
  }

  /// Wakes [directoryChanges] when the roster's directory-relevant projection moves
  /// — presence, availability, and conversation membership, the fields the Dial tab
  /// sorts and groups on. Deliberately not positions: a stranger's step must not
  /// repaint a contact list. Cheap — a sorted fold of a handful of fields per row,
  /// compared to the last — so it is fine to run on every roster.
  void _noteDirectory(Roster roster) {
    final parts = <String>[
      for (final row in roster.rows) _directoryDigestPart(row),
    ]..sort();
    final digest = parts.join('|');
    if (digest == _lastDirectoryDigest) return;
    _lastDirectoryDigest = digest;
    _directoryChanges.tick();
  }

  /// One row's contribution to the directory digest: every projected field the Dial
  /// tab draws off it, and nothing a footstep moves.
  ///
  /// Presence, availability and `clusterId` are the sort and the dots. The rest is
  /// what [directory] and [meetings] *derive* and render: whether there is a finite
  /// position to warp to ([Contact.isReachable]), the floor that decides a warp is
  /// reachable, the status line under the name, and — for a row in a cluster — the
  /// *named room* its tile falls in, the input to [Meeting.roomName]. The room, not
  /// the raw tile, on purpose: a step inside one room leaves the name unchanged and
  /// the tab asleep, which is the whole point of this being its own listenable.
  String _directoryDigestPart(RosterRow row) {
    final x = row.x, y = row.y;
    final placed = x != null && y != null && x.isFinite && y.isFinite;
    // The room label is a meeting's, so only a clustered member can move it; resolving
    // it for everyone would walk the room list on every roster for no rendered change.
    var room = '';
    if (placed && row.clusterId != null) {
      final map = debugMap ?? _collector?.mapFor(row.floorId);
      if (map != null) {
        room = _innermostNamedRoomAt(map, x.round(), y.round())?.name ?? '';
      }
    }
    final status = row.status;
    return '${row.id}:${row.isPresent ? 1 : 0}:${row.availability ?? ''}:${row.clusterId ?? ''}'
        ':${placed ? 1 : 0}:${row.floorId ?? ''}:$room:${status?.text ?? ''}';
  }

  /// Whether I am in a call: a conversation Gather has put me in, or anybody the
  /// media plane is actually sending me. Either alone is enough — the cluster
  /// lands before the SFU has negotiated anyone, and a peer can still be heard for
  /// the half second after the cluster lets go.
  bool get inCall => inHuddle || call.hasCompany;

  /// Test seam, as [debugCanWalk]: a huddle takes two people standing close
  /// enough for Gather to have decided they are talking.
  @visibleForTesting
  List<String>? debugHuddle;

  /// The line under my name, as Gather holds it.
  ///
  /// Read back off the roster rather than remembered, so it survives a restart
  /// and reflects the desktop client setting or clearing it. `SpaceUserStatus`
  /// used to be one of the models the reader discarded, which is why this was an
  /// echo of what this phone last sent; it is tracked now, and the join runs from
  /// the status row's own `spaceUserId` because the two pointer fields on
  /// `SpaceUser` are never set.
  ///
  /// Includes the ones Gather writes from a calendar, not only typed ones — a
  /// status is a status to whoever is reading it.
  PersonStatus? get customStatus => _myRow()?.status;

  // ---- faces -------------------------------------------------------------------

  ProfilePhotos? _photos;

  /// Somebody's profile picture, if we already have a URL for it.
  ///
  /// Synchronous and self-healing, which is the shape the widget tree wants: it
  /// answers null the first time, starts the lookup, and calls listeners when the
  /// URL lands so the same `build` runs again and gets it. A `FutureBuilder` per
  /// face would flash a placeholder on every rebuild, and the map rebuilds four
  /// times a second.
  ///
  /// Null for the roughly half of a space who have not set a picture — on the
  /// reference space, 45 of 98 had one — which is a fallback avatar, not a
  /// failure.
  String? photoUrlFor(String spaceUserId) {
    final photos = _photos;
    final spaceId = _spaceIdForCall;
    final fileId = _rowFor(spaceUserId)?.profilePictureId;
    if (photos == null || spaceId == null || fileId == null) return null;

    final known = photos.cached(fileId);
    if (known != null || photos.isResolved(fileId)) return known;

    // Not yet asked. The `then` lands after this frame, so notifying from it is
    // safe, and `isResolved` above is what stops the rebuild asking again.
    unawaited(
      photos.urlFor(spaceId: spaceId, fileId: fileId).then((url) {
        if (url != null && _photos == photos) _announceFaces();
      }),
    );
    return null;
  }

  /// The picture URLs known so far for [spaceUserIds].
  ///
  /// Same lazy contract as [photoUrlFor] — asking is what starts the lookups —
  /// but for a screenful at once, which is what a list wants when it is about
  /// to warm an image cache. Ids still being looked up are simply absent; their
  /// answers arrive as a change on this object, and the next call includes
  /// them.
  ///
  /// A set on the way out, because the same person on four rows is one picture,
  /// and the caller is going to hand these to a cache that would rather be told
  /// once.
  List<String> photosFor(Iterable<String> spaceUserIds) {
    if (_photos == null) return const [];

    final urls = <String>{};
    for (final id in spaceUserIds.toSet()) {
      final url = photoUrlFor(id);
      if (url != null) urls.add(url);
    }
    return urls.toList(growable: false);
  }

  Timer? _faceNotice;

  /// Announces resolved faces at most once a frame.
  ///
  /// A screenful of people is a screenful of REST answers landing within
  /// milliseconds of each other, and one `notifyListeners` each would rebuild
  /// the whole tree once per face — on the map, which is fed by this too, forty
  /// times over. They are all wanted in the same frame anyway.
  void _announceFaces() {
    _faceNotice ??= Timer(const Duration(milliseconds: 16), () {
      _faceNotice = null;
      notifyListeners();
    });
  }

  RosterRow? _rowFor(String id) {
    for (final row in _roster?.rows ?? const <RosterRow>[]) {
      if (row.id == id) return row;
    }
    return null;
  }

  /// Turns a collector answer into the sentence-or-null contract the UI expects.
  String? _sent(({bool ok, String? detail}) result, String whatFailed) {
    if (result.ok) return null;
    final detail = result.detail;
    return detail == null ? whatFailed : '$whatFailed ($detail)';
  }

  /// Active, Busy or Away.
  ///
  /// Optimistic in neither direction: the roster patch that follows is what moves
  /// the dot, so a refusal leaves the picker showing what is actually true rather
  /// than what was asked for.
  Future<String?> setAvailability(String availability) async {
    final collector = _collector;
    if (collector == null) return 'Not connected to Gather.';
    return _sent(collector.setAvailability(availability), 'Could not set your status.');
  }

  /// Sets the line of text under my name.
  Future<String?> setCustomStatus({required String text, String? emoji, DateTime? clearAt}) async {
    final collector = _collector;
    if (collector == null) return 'Not connected to Gather.';

    final trimmed = text.trim();
    if (trimmed.isEmpty) return clearCustomStatus();

    // No optimistic echo. The status row comes back on the socket as an
    // `addmodel` within a beat, and [customStatus] reads it from there — so
    // holding a local copy would only create a second answer to disagree with.
    return _sent(collector.setCustomStatus(text: trimmed, emoji: emoji, clearAt: clearAt), 'Could not set your status.');
  }

  Future<String?> clearCustomStatus() async {
    final collector = _collector;
    if (collector == null) return 'Not connected to Gather.';
    return _sent(collector.clearCustomStatus(), 'Could not clear your status.');
  }

  /// Throws an emoji over the room.
  Future<String?> sendEmote(String emote) async {
    final collector = _collector;
    if (collector == null) return 'Not connected to Gather.';
    return _sent(collector.broadcastEmote(emote), 'Could not send that.');
  }

  /// Who is reacting right now, and with what.
  ///
  /// A [Listenable] of its own rather than folded into this one. Reactions
  /// expire on a timer, so the notification that takes one down arrives with no
  /// roster and no tap behind it — and a screen that does not draw them has no
  /// reason to rebuild for it. The call screen merges this in; nothing else
  /// listens.
  final Reactions reactions = Reactions();

  /// Throws an emoji over the room, and shows it here at once.
  ///
  /// The echo does come back — `EmoteEvent` names the sender in its own
  /// `targetUserIds` — but it comes back over the network, and the one reaction
  /// on screen that should never be waited for is your own.
  Future<String?> sendEmoteLocalFirst(String emote) async {
    final me = _collector?.selfId;
    if (me != null) reactions.note(me, emote);
    return sendEmote(emote);
  }

  /// Who in the conversation is talking, so their ring can be redrawn.
  ///
  /// The call screen rebuilds on [notifyListeners] and on nothing else — unlike
  /// the map, which rides the `positions` ticker four times a second. And an
  /// ordinary roster does not notify: the presence fold only does so when
  /// something it considers a state change happened, and voice activity
  /// deliberately is not one. That guard is right in general — a measured space
  /// held 111 rows and `speaking` was the single most frequent patch of any kind,
  /// so rebuilding the tree for a stranger three rooms away clearing their throat
  /// is exactly the wrong trade — but it left every face in the call ringed at
  /// whatever it happened to be when something else last woke the screen.
  ///
  /// So the question is asked narrowly: only people in the conversation we are
  /// in, which is the set the call draws and is bounded by the size of a huddle
  /// rather than by the size of the space.
  void _noteSpeakers(Roster roster) {
    final mine = _myRow()?.clusterId;
    final speakers = <String>{
      if (mine != null)
        for (final row in roster.rows)
          if (row.id != roster.selfId && row.clusterId == mine && row.speaking == true)
            row.id,
    };
    if (setEquals(speakers, _speakers)) return;
    _speakers = speakers;
    notifyListeners();
  }

  Set<String> _speakers = const {};

  /// Whether *we* are talking, measured from our own microphone.
  ///
  /// Read here rather than off the roster, even though the roster carries it
  /// back within a beat. The round trip is Gather's, and watching your own ring
  /// light up a moment after you start a sentence is the kind of lag that reads
  /// as the app being slow rather than as the network being a network. Everybody
  /// else's speaking still comes from the roster, because for them it is the only
  /// source there is.
  bool get amSpeaking => _amSpeaking;
  bool _amSpeaking = false;

  /// Puts the voice-activity detector's answer on the game socket.
  ///
  /// This is the whole of the speaking ring. `SpaceUser.speaking` is set by these
  /// two actions and by nothing else — publishing audio to the SFU does not touch
  /// it — so before this existed the phone was audible in the room and drawn as
  /// silent on every screen in it.
  void _noteSpeaking(bool speaking) {
    if (speaking == _amSpeaking) return;
    _amSpeaking = speaking;
    // Locally first. The ring on this phone should not wait for Gather to agree.
    notifyListeners();
    _collector?.setSpeaking(speaking);
  }

  /// Steps out of the conversation without walking away from it.
  Future<String?> leaveHuddle() async {
    final collector = _collector;
    if (collector == null) return 'Not connected to Gather.';
    return _sent(collector.leaveCluster(), 'Could not leave the conversation.');
  }

  // ---- the call ---------------------------------------------------------------

  /// What our microphone and camera are doing, and whether the room is receiving
  /// them. Everything off, and no hardware held, until the first tap.
  CallState get call => debugCall ?? _call?.state ?? const CallState();

  /// Whether there is enough identity to open one at all.
  ///
  /// The media plane keys on `UserAccount` while the game plane keys on
  /// `SpaceUser`, so this needs a *different* id from everything else here — and
  /// it arrives with the state dump rather than at connect.
  bool get canCall => debugCanCall ?? (_buildCall != null && _collector?.selfAccountId != null && _spaceIdForCall != null);

  /// Test seam, as [debugCanWalk].
  @visibleForTesting
  bool? debugCanCall;

  /// Test seam: installs a call without going through [_callOrNull], which wants
  /// a credential, a space and an account id that a suite has no way to produce.
  ///
  /// Subscribes to the same streams the real path does. A seam that attached the
  /// object without its wiring would let every one of these tests pass against a
  /// call nothing was listening to.
  @visibleForTesting
  void debugAttachCall(Call call) {
    _call = call;
    _subs.add(call.speaking.listen(_noteSpeaking));
  }

  /// Test seam: stand a collector in without the whole [_attach] handshake, so the
  /// network-change watcher has something to resync.
  @visibleForTesting
  void debugAttachCollector(Collector collector) => _collector = collector;

  /// Test seam: drive [_onConnectivityChanged] without a plugin behind it.
  @visibleForTesting
  void debugNoteConnectivity(List<ConnectivityResult> now) => _onConnectivityChanged(now);

  /// Test seam: drive [_onCollectorStatus] without the collector's stream wired, so a
  /// test can land a deaf-timer report while offline and check which word wins.
  @visibleForTesting
  void debugNoteCollectorStatus(CollectorStatus status) => _onCollectorStatus(status);

  /// Test seam: the call state a screen renders, with no media layer behind it.
  ///
  /// Overrides [call] when set. A widget test cannot build a real [Call] — it
  /// would want a microphone and a socket — but the screens that draw one still
  /// need every shape it can take, including the ones a device rarely produces.
  @visibleForTesting
  CallState? debugCall;

  String? get _spaceIdForCall => _snapshot.self.spaceId ?? _spaceId;

  Future<String?> setMicOn(bool on) async {
    final call = _callOrNull();
    if (call == null) return 'Not connected to Gather.';
    final failed = await call.setMicOn(on);
    notifyListeners();
    return failed;
  }

  Future<String?> setCameraOn(bool on) async {
    final call = _callOrNull();
    if (call == null) return 'Not connected to Gather.';
    final failed = await call.setCameraOn(on);
    notifyListeners();
    return failed;
  }

  Future<void> switchCamera() async {
    await _call?.switchCamera();
    notifyListeners();
  }

  Future<String?> setSpeakerOn(bool on) async {
    final call = _callOrNull();
    if (call == null) return 'Not connected to Gather.';
    final failed = await call.setSpeakerOn(on);
    notifyListeners();
    return failed;
  }

  /// The call itself, for the one screen that draws video.
  ///
  /// Typed as [Call], so nothing here has heard of `MediaStream` and this file
  /// stays free of the WebRTC plugin. The screen that needs the native streams
  /// checks for `LiveCall` and asks it directly — the same split
  /// `WebrtcMediaEngine.localStream` makes one level down.
  Call? get callHandle => _call;

  /// The person behind a media-plane `srcId`, or null if no row claims it.
  ///
  /// The two planes are keyed differently — `srcId` is a `UserAccount.id` and the
  /// roster is `SpaceUser.id` — so a tile has no name until this bridges them.
  /// Null is normal and temporary: a row that has not yet carried its
  /// `userAccountId` cannot be matched, and the next roster usually fixes it.
  RosterRow? rowForSrcId(String srcId) {
    for (final row in _roster?.rows ?? const <RosterRow>[]) {
      if (row.userAccountId == srcId) return row;
    }
    return null;
  }

  /// Builds the call on first use, or null while we do not yet know who we are.
  ///
  /// Lazy on purpose: opening a router socket for somebody who never presses
  /// either button is a connection and a battery spent on nothing.
  Call? _callOrNull() {
    final existing = _call;
    if (existing != null) return existing;

    final build = _buildCall;
    final auth = _auth;
    final srcId = _collector?.selfAccountId;
    final spaceId = _spaceIdForCall;
    if (build == null || auth == null || srcId == null || spaceId == null) return null;

    final call = _call = build(auth, spaceId, srcId);
    _subs.add(call.states.listen((_) => notifyListeners()));
    _subs.add(call.speaking.listen(_noteSpeaking));

    // Hand it the room as it stands. The call is built on the first tap, long
    // after the rosters that worked out who is nearby, and without this it would
    // publish to an empty allow list until somebody happened to move — so the
    // first thing you do after opening the app is the one time nobody can see
    // you.
    unawaited(call.setVisibleTo(_visibleTo));
    unawaited(call.setConversation(_conversation));
    unawaited(call.setListeningTo(_clusterWanted));
    return call;
  }

  /// Who the call should be listening to, kept in step with Gather's own idea of
  /// the conversation.
  ///
  /// **`clusterId`, not distance.** Gather computes the bubble server-side and
  /// publishes it in state, so this is the same relation the desktop client draws
  /// a ring around — no reimplementation of the twelve-stage proximity pipeline,
  /// and no risk of the phone disagreeing with the Mac about who is in the room.
  ///
  /// Debounced. `clusterId` flickers as somebody walks past a group, and a call
  /// that subscribed on every roster would spend its life negotiating transports
  /// for people who kept walking. The delay is deliberately longer on the way in
  /// than on the way out: joining late is a moment of missing the start of a
  /// sentence, while leaving late means still hearing a conversation you have
  /// walked away from, which is the worse of the two.
  void _noteCluster(Roster roster) {
    _noteNeighbours(roster);
    _noteConversation(roster);
    // Their `UserAccount.id`, which is what the media plane is keyed on — see
    // `RosterRow.userAccountId`. Somebody whose row has not carried it yet is
    // skipped rather than guessed at, and picked up on a later roster.
    final wanted = <String>{
      for (final row in roster.myCluster) ?row.userAccountId,
    };

    if (wanted.length == _clusterWanted.length &&
        _clusterWanted.containsAll(wanted)) {
      return;
    }
    _clusterWanted = wanted;
    // The one line that says whether Gather ever formed a conversation for us. An
    // empty set after walking up to somebody is the fingerprint of the desk-desync
    // bug: the server never counted us as adjacent, so there is nobody to listen to
    // and no call to start. See [_noteConversation] for the id that pairs with it.
    _log('cluster: members -> ${wanted.length}'
        '${wanted.isEmpty ? '' : ' (${wanted.join(',')})'}');

    _clusterDebounce?.cancel();
    _clusterDebounce = Timer(
      wanted.length >= _lastAppliedCluster.length
          ? const Duration(milliseconds: 1500)
          : const Duration(milliseconds: 600),
      () {
        _lastAppliedCluster = _clusterWanted;
        // A conversation is reason enough to build the call, where merely being
        // near somebody is not. Waiting for a tap instead meant the phone could
        // not hear anyone until it started talking — the `Call` was built by
        // [setMicOn], so until then there was nothing to hand a cluster to.
        // Building one opens no hardware: the engine holds nothing until
        // `startCapture`, and the permission prompts still belong to the buttons.
        final call = _clusterWanted.isEmpty ? _call : _callOrNull();
        unawaited(call?.setListeningTo(_clusterWanted) ?? Future<void>.value());
      },
    );
  }

  Set<String> _clusterWanted = const {};
  Set<String> _lastAppliedCluster = const {};
  Timer? _clusterDebounce;

  /// Tell the media plane which conversation we are in, by Gather's own id.
  ///
  /// `set-player-conversation-metadata` is in the measured method table and the
  /// desktop client sends it on every change, so this does too. Undebounced and
  /// separate from the membership on purpose: it is a name, not a subscription,
  /// and naming the room you are in late is the one part of this that costs
  /// nothing to get right immediately.
  void _noteConversation(Roster roster) {
    final id = roster.myClusterId;
    if (id == _conversation) return;
    _conversation = id;
    _log('cluster: conversation id -> ${id ?? '(none)'}');
    unawaited(_call?.setConversation(id) ?? Future<void>.value());
  }

  String? _conversation;

  /// Who may see and hear us — everybody Gather counts as *in range*.
  ///
  /// A wider circle than the cluster, and undebounced. Both differences are
  /// deliberate and both are copied from the desktop client:
  ///
  ///  * **Wider**, because `consume-allow` is what permits anybody to consume us
  ///    at all, and the camera in a circle over your avatar is something people
  ///    merely standing near you can see. Allowing only your conversation means
  ///    that circle never appears for anyone else — which is exactly how this was
  ///    reported.
  ///  * **Undebounced**, because a permission is cheap and being late with it is
  ///    not. Somebody walking up sees an empty circle until it arrives, and the
  ///    thing a debounce protects against — negotiating transports for passers-by
  ///    — does not apply: nothing is negotiated by allowing someone.
  void _noteNeighbours(Roster roster) {
    final wanted = <String>{
      for (final row in roster.nearby) ?row.userAccountId,
      // The conversation, unconditionally, on top of whoever is geometrically
      // in range.
      //
      // `nearby` needs coordinates and a floor on *both* rows to say yes;
      // `myCluster` needs only a shared `clusterId`. So a roster that has told
      // us who we are talking to but not yet where anybody is standing produces
      // an empty allow list — and an empty allow list means `consume-allow` is
      // never sent, which means the SFU answers every colleague with
      // `consume-not-allowed` and nobody hears us however well we publish. That
      // is not hypothetical: it is what the phone did on 2026-09-17, publishing
      // audio into a void while the cluster was perfectly well known.
      //
      // Being in somebody's conversation is a strictly stronger claim than
      // standing near them, so this can only ever widen the set, and widening it
      // is cheap — allowing somebody negotiates nothing.
      for (final row in roster.myCluster) ?row.userAccountId,
    };
    if (wanted.length == _visibleTo.length && _visibleTo.containsAll(wanted)) {
      return;
    }
    _visibleTo = wanted;
    unawaited(_call?.setVisibleTo(wanted) ?? Future<void>.value());
  }

  Set<String> _visibleTo = const {};

  // ---- walking ---------------------------------------------------------------

  /// Whether there is anything for a D-pad to drive.
  ///
  /// Both halves are needed and neither is optional: the socket to send the step on,
  /// and the tile to judge it from. A pad shown without them is a control that cannot
  /// be told apart from a broken one.
  bool get canWalk => debugCanWalk ?? (_walk?.at != null && _collector != null && !_link.isDisrupted);

  /// Test seam, as [debugMap]: knowing where you are takes a live roster.
  @visibleForTesting
  bool? debugCanWalk;

  /// Start walking, or turn a walk already under way.
  ///
  /// Held rather than tapped: the pad calls this for as long as a thumb is down, and
  /// [Walk] repeats the step at Gather's own walking pace until [stopWalking].
  void walk(String direction) => _walk?.press(direction);

  /// How fast we are going, and so whether to draw a go-kart under our own avatar.
  ///
  /// Ours only. Everybody else's comes off the roster, where `speed.modifier` is a
  /// synced field — see [Person.gait]. This one cannot: the wire is a quarter of a
  /// second behind a walk that changes gait twice in it.
  Gait get gait => debugGait ?? (_walk?.gait ?? Gait.walking);

  /// Test seam, as [debugCanWalk].
  @visibleForTesting
  Gait? debugGait;

  /// Take the go-kart, whatever the distance.
  ///
  /// The phone's shift key. On the desktop, driving has two entirely separate doors:
  /// hold shift while the arrow keys walk you, or let the route pick a gait for you on
  /// distance. A phone has the second and no way at all to hold the first, so this
  /// latches — and, as on the desktop, it means *drive*, not "drive if it is far
  /// enough": see [Walk.boost]. It applies to a walk already running, which is why it
  /// is forwarded rather than read at the off.
  /// Held here rather than read back off [Walk], because the latch outlives a
  /// reconnect and the walk does not: `_walk` is rebuilt with the collector every time
  /// the socket comes back, and a preference that quietly reset itself under a lit
  /// button would be worse than no latch at all. [_attach] hands it to each new one.
  bool get boost => _boost;
  bool _boost = false;

  set boost(bool value) {
    if (_boost == value) return;
    _boost = value;
    _walk?.boost = value;
    notifyListeners();
  }

  void stopWalking() {
    _walk?.release();
    notifyListeners();
  }

  /// Whether a tapped destination is being walked to right now.
  ///
  /// Notified rather than polled, which is why [stopWalking] and [goTo] both wake the
  /// tree: the map's *Go to* pill turns into a *Stop* while this is true, and a pill
  /// that only changed on the next roster would sit there saying the wrong word for
  /// up to a quarter of a second at each end of the walk.
  bool get onRoute => debugOnRoute ?? (_walk?.onRoute ?? false);

  /// Test seam, as [debugCanWalk].
  @visibleForTesting
  bool? debugOnRoute;

  /// Walk to a tile, the way a double-click on the floor does on the desktop.
  ///
  /// Answers the way everything else the user can press answers — null when it worked,
  /// a sentence when it did not — because the alternative is a tap that silently does
  /// nothing. Not a `Future` in substance: the route is planned and the first step is
  /// on the wire before this returns. It is one so the map can hand it to the same
  /// `_run` helper the control bar uses.
  Future<String?> goTo(int x, int y) async {
    final walk = _walk;
    final map = this.map;
    if (map == null) return 'Still reading the floor plan.';
    if (walk == null || _collector == null) return 'Not connected to Gather.';
    // The socket can be open but deaf (offline) or mid-reconnect: a walk started now
    // only moves the avatar on this phone, into a floor the server is not updating.
    if (_link.isDisrupted) return 'No connection — waiting for network.';

    final at = walk.at;
    if (at == null) return 'Still working out where you are.';

    final occupied = _occupied();
    final taken = {for (final tile in occupied) tile.y * map.width + tile.x};

    // A destination that cannot be stood on is *moved*, not refused — the client's
    // own rule, and the reason tapping a chair works there. `blockedAtPosition` has
    // no exemption for seats, so a chair is as impassable as a wall and
    // `startPathMoveOnCurrentFloor` relocates to the nearest free tile regardless.
    // A tile somebody is standing on gets the same treatment.
    var goal = (x: x, y: y);
    if (!map.isWalkable(x, y) || taken.contains(y * map.width + x)) {
      final free = map.nearestFree(x, y, occupied: taken);
      if (free == null) return 'There is nowhere to stand there.';
      goal = free;
    }

    return _travelTo(map, walk, at, goal, occupied);
  }

  /// Walk if there is a way to walk, and otherwise arrive anyway.
  ///
  /// The fallback is not a shortcut around the decision to walk — it is what walking
  /// *is* on the desktop. `setPathMoveTo` runs the search and then:
  ///
  /// ```js
  /// if (opts?.forceTeleport || this.shouldTeleport(reason)) { this.teleport(goal, true) }
  /// // shouldTeleport(reason) → reason === NoPathFound || reason === MaxDepthReached
  /// ```
  ///
  /// So the client never tells anybody a destination is unreachable; it walks when it
  /// can and blinks when it cannot. That matters more here than it does there, because
  /// [SpaceMap.routeTo] refuses to cross anybody else's desk or coworking area — which
  /// is correct, and which makes "no route" an ordinary answer in a real office rather
  /// than a rare one. Refusing on it was the bug.
  String? _travelTo(
    SpaceMap map,
    Walk walk,
    ({int x, int y}) at,
    ({int x, int y}) goal,
    List<({int x, int y})> occupied,
  ) {
    final route = map.routeTo(
      fromX: at.x,
      fromY: at.y,
      toX: goal.x,
      toY: goal.y,
      avoid: occupied,
    );
    if (route != null) {
      walk.follow(route);
      notifyListeners();
      return null;
    }

    // Any route still running was aimed somewhere else.
    walk.release();

    final collector = _collector;
    if (collector == null) return 'Not connected to Gather.';
    final sent = collector.teleport(
      x: goal.x,
      y: goal.y,
      direction: headingTo(fromX: at.x, fromY: at.y, toX: goal.x, toY: goal.y),
    );
    if (!sent.ok) return sent.detail ?? 'Gather refused that.';

    _noteTeleport(goal.x.toDouble(), goal.y.toDouble());
    return null;
  }

  /// Tell the map we hopped, now rather than when the roster catches up.
  ///
  /// [_positions] and not [notifyListeners], for the reason [_onPartyHop] gives: this
  /// is movement, and movement must not wake the whole tree. Without it the body
  /// stands on the old tile for up to a quarter of a second and the arrival is drawn
  /// as a very fast walk instead of as a teleport.
  void _noteTeleport(double x, double y) {
    final id = _collector?.selfId;
    if (id == null) return;
    _lastTeleport = (id: id, x: x, y: y, seq: ++_teleportSeq);
    _positions.tick();
  }

  // ---- warping (Warp Dial) ----------------------------------------------------
  //
  // The commuting surface moves you without you watching the map. Where [goTo]
  // walks when it can — because on the office screen the walk *is* the point — a
  // warp always hops: the Dial tab is for arriving, not travelling, and a thumb on
  // a train has no patience for a camera gliding across the floor.

  /// Teleport to a free tile at or beside ([x], [y]) — always a hop.
  ///
  /// The landing rule is [goTo]'s: a tile that cannot be stood on, or one somebody
  /// is on, is relocated to the nearest free one rather than refused — which is
  /// what makes "warp to a person" land you *next* to them, since their own tile is
  /// taken. Unlike [goTo] there is no route search: this is the teleport branch of
  /// [_travelTo] on its own.
  Future<String?> warpToTile(int x, int y) async {
    final map = this.map;
    final collector = _collector;
    if (map == null) return 'Still reading the floor plan.';
    if (collector == null) return 'Not connected to Gather.';
    // The socket can be open but deaf (offline) or mid-reconnect: a hop started now
    // only moves the avatar on this phone, into a floor the server is not updating.
    if (_link.isDisrupted) return 'No connection — waiting for network.';

    final occupied = _occupied();
    final taken = {for (final tile in occupied) tile.y * map.width + tile.x};

    var goal = (x: x, y: y);
    if (!map.isWalkable(x, y) || taken.contains(y * map.width + x)) {
      final free = map.nearestFree(x, y, occupied: taken);
      if (free == null) return 'There is nowhere to stand there.';
      goal = free;
    }

    // Any route still running was aimed somewhere else — stop it before the hop,
    // the same order [_travelTo] uses.
    _walk?.release();

    final me = myTile;
    final sent = collector.teleport(
      x: goal.x,
      y: goal.y,
      direction: me == null
          ? 'Down'
          : headingTo(fromX: me.x, fromY: me.y, toX: goal.x, toY: goal.y),
    );
    if (!sent.ok) return sent.detail ?? 'Gather refused that.';

    _noteTeleport(goal.x.toDouble(), goal.y.toDouble());
    notifyListeners();
    return null;
  }

  /// Warp next to a person and open your microphone — Warp Dial's "call".
  ///
  /// Aimed at their own tile so [warpToTile]'s relocation lands you adjacent;
  /// proximity is then Gather's to notice, and the roster that follows drives
  /// [_noteCluster], which wires the audio. The mic is turned on here because a
  /// phone call connects the microphone rather than merely placing you in earshot —
  /// but it is best-effort: a denied permission is news on [notices], not a reason
  /// to report the warp itself as having failed (which would stop the UI opening
  /// the call).
  Future<String?> warpToPerson(Contact contact) async {
    if (!contact.isPresent) return '${contact.label} is not in the office right now.';
    final x = contact.x, y = contact.y;
    if (x == null || y == null || !x.isFinite || !y.isFinite) {
      return "Can't tell where ${contact.label} is yet.";
    }
    // A warp is a hop on *this* floor: it teleports to a coordinate on the map the
    // phone is showing. Applied to someone on another floor it would land on the
    // same coordinates here — nowhere near them — and falsely report success. There
    // is no one-hop floor change, so a cross-floor contact is out of reach.
    final myFloor = _myRow()?.floorId;
    if (myFloor != null && contact.floorId != null && contact.floorId != myFloor) {
      return '${contact.label} is on another floor.';
    }

    final failed = await warpToTile(x.round(), y.round());
    if (failed != null) return failed;

    final micFailed = await setMicOn(true);
    if (micFailed != null) _notices.add(micFailed);
    return null;
  }

  /// Join a conversation already happening, and open your microphone.
  ///
  /// A conversation I am already in needs no travel. Otherwise, when the cluster
  /// sits in a named room I can resolve, I *walk in* with [goToRoom] — which lands
  /// on a seat and respects a shut door the way entering a meeting should — and
  /// fall back to warping beside a member when there is no room to name. Mic is
  /// handled as in [warpToPerson].
  Future<String?> warpToMeeting(Meeting meeting) async {
    if (meeting.includesMe) return null;

    // On another floor there is no room on this map to walk into and no tile a hop
    // could reach — the same ceiling [warpToPerson] hits. Refuse rather than walk
    // into a room that merely shares a name or coordinates on the wrong floor.
    final myFloor = _myRow()?.floorId;
    if (myFloor != null && meeting.floorId != null && meeting.floorId != myFloor) {
      return 'That conversation is on another floor.';
    }

    final map = this.map;
    final roomName = meeting.roomName;
    if (map != null && roomName != null) {
      for (final room in map.rooms) {
        if (room.name != roomName) continue;
        final failed = await goToRoom(
          room,
          toward: (x: room.x + room.width ~/ 2, y: room.y + room.height ~/ 2),
        );
        if (failed != null) return failed;
        final micFailed = await setMicOn(true);
        if (micFailed != null) _notices.add(micFailed);
        return null;
      }
    }

    for (final member in meeting.members) {
      final x = member.x, y = member.y;
      if (x == null || y == null || !x.isFinite || !y.isFinite) continue;
      // Only hop beside a member this hop can actually reach: one on our own floor.
      if (myFloor != null && member.floorId != null && member.floorId != myFloor) continue;
      final failed = await warpToTile(x.round(), y.round());
      if (failed != null) return failed;
      final micFailed = await setMicOn(true);
      if (micFailed != null) _notices.add(micFailed);
      return null;
    }

    return 'Could not work out where that conversation is.';
  }

  /// Walk into a room, landing on a seat if it has a free one.
  ///
  /// [toward] is the tile that was actually tapped; it only breaks ties between
  /// equally good landing tiles. `getAbsoluteTilesClosestToPrioritizedBySeats` hands
  /// back every tile in the room, best first, and the client keeps the also-rans as
  /// `altMoveGoals` so a seat taken while you were walking falls through to the next
  /// one. [SpaceMap.routeTo] is cheap enough to do that by simply trying them in turn.
  Future<String?> goToRoom(SpaceRoom room, {required ({int x, int y}) toward}) async {
    final walk = _walk;
    final map = this.map;
    if (map == null) return 'Still reading the floor plan.';
    if (walk == null || _collector == null) return 'Not connected to Gather.';
    // The socket can be open but deaf (offline) or mid-reconnect: a walk started now
    // only moves the avatar on this phone, into a floor the server is not updating.
    if (_link.isDisrupted) return 'No connection — waiting for network.';

    final at = walk.at;
    if (at == null) return 'Still working out where you are.';

    final occupied = _occupied();
    final taken = {for (final tile in occupied) tile.y * map.width + tile.x};

    final wanted = [
      for (final tile in map.tilesClosestTo(room, toward).take(_landingTries))
        if (!taken.contains(tile.y * map.width + tile.x)) tile,
    ];
    if (wanted.isEmpty) return 'There is nowhere free in ${room.name ?? 'there'}.';

    // Every seat and standing tile in turn — the client's `altMoveGoals`, which exist
    // so a seat somebody took while you were walking falls through to the next one.
    for (final tile in wanted) {
      final route = map.routeTo(fromX: at.x, fromY: at.y, toX: tile.x, toY: tile.y, avoid: occupied);
      if (route == null) continue;
      walk.follow(route);
      notifyListeners();
      return null;
    }
    // None of them can be walked to — a sealed room, or one whose only door is
    // through somebody else's desk. Arrive at the best of them anyway, the way
    // `shouldTeleport` does.
    return _travelTo(map, walk, at, wanted.first, occupied);
  }

  /// The desk Gather has given me, or null if it has given me none.
  ///
  /// `SpaceUser.deskId` is a one-to-one at `MapEntityIdentifier`, so the match is
  /// against [SpaceRoom.stableId] and never against `SpaceRoom.id` — the two are
  /// different ids for the same rectangle and matching the wrong one finds nothing
  /// at all. Read off the roster rather than remembered, so a desk manager moving
  /// me arrives here the same way it arrives in the desktop client.
  SpaceRoom? get myDesk {
    final deskId = _myRow()?.deskId;
    if (deskId == null) return null;
    for (final room in map?.rooms ?? const <SpaceRoom>[]) {
      if (room.stableId == deskId) return room;
    }
    // A desk on another floor, or a floor plan that has not arrived yet. Both are
    // "not something to walk to from here", which is the only question asked.
    return null;
  }

  /// Whether that room's door is open to me. See [canEnterRoom] for the rule and for
  /// the two clauses of it this app cannot answer.
  bool canEnter(SpaceRoom room) {
    final map = this.map;
    final at = myTile;
    return canEnterRoom(
      room,
      myDeskId: _myRow()?.deskId,
      standingIn: map == null || at == null ? null : map.privateAreaAt(at.x, at.y),
      meId: _collector?.selfId ?? _roster?.selfId,
    );
  }

  /// Whether I am standing on my own desk.
  ///
  /// The client's own test, transcribed:
  ///
  /// ```js
  /// get isAtOwnDesk() {
  ///   return this.currentMapArea?.stableId_USE_THIS_INSTEAD_OF_ID === this.deskId
  /// }
  /// ```
  ///
  /// `currentMapArea` is the *innermost* area at your feet and a desk is the
  /// innermost thing there is, so "the current area is my desk" and "my desk's
  /// rectangle contains me" are the same claim, and the second needs no area
  /// hierarchy to answer.
  ///
  /// Position comes from [Walk] first, which is the live tile, and from the roster
  /// only before a walk exists. Reading the roster alone would leave the button
  /// still offering to walk you somewhere you have already arrived for as long as a
  /// quarter of a second — the same lag [mePerson] avoids for the same reason.
  bool get atMyDesk {
    final desk = myDesk;
    if (desk == null) return false;
    final at = _walk?.at;
    if (at != null) return desk.contains(at.x, at.y);
    final me = _myRow();
    final x = me?.x, y = me?.y;
    if (x == null || y == null || !x.isFinite || !y.isFinite) return false;
    return desk.contains(x.round(), y.round());
  }

  /// Walk back to my own desk.
  ///
  /// `moveSpaceUserToDesk`, which is a *walk* and not a hop:
  ///
  /// ```js
  /// const desk = currentSpaceUser.desk
  /// if (!desk) { toast("You don't have a desk yet"); return }
  /// const goal = desk.spawn.availablePosition(currentSpaceUser.coreRole)
  /// this.setPathMoveTo(goal, { altMoveGoals: Seats.availableStandingTilesOf(desk), … })
  /// currentSpaceUser.turnOffAVS()
  /// ```
  ///
  /// [goToRoom] is that, already: a best-first list of the room's tiles with seats
  /// ahead of standing room, tried in turn so a chair taken on the way falls through
  /// to the next one, and [_travelTo]'s hop as the last resort the desktop's own
  /// `shouldTeleport` provides. The desk's middle is the tie-breaker because a desk
  /// is one or two tiles across and every part of it is equally "there".
  ///
  /// The one line deliberately not copied is `turnOffAVS()`. Gather cuts your
  /// microphone and camera when you sit back down, which is defensible on a desktop
  /// where the walk is a keystroke — and on a phone it would be a button that
  /// silently hangs up the call you are holding, which is a second action nobody
  /// asked this one to take.
  Future<String?> goToMyDesk() async {
    final desk = myDesk;
    if (desk == null) return 'Gather has not given you a desk.';
    final failed = await goToRoom(
      desk,
      toward: (x: desk.x + desk.width ~/ 2, y: desk.y + desk.height ~/ 2),
    );
    if (failed == null) {
      // Both: the stream for a map that is already up, the latch for one that is
      // about to be. See [takeFollowRequest].
      _followWanted = DateTime.now();
      if (!_followMe.isClosed) _followMe.add(null);
    }
    return failed;
  }

  /// How many of a room's tiles to try before giving up on it.
  ///
  /// A room is up to a few dozen tiles and each attempt is a fresh search, so this is
  /// a bound on the work rather than a real limit: the tiles are sorted best-first, so
  /// anything past the eighth is a tile nobody would have wanted anyway.
  static const _landingTries = 8;

  /// Tiles other people are standing on, for a route to go round.
  ///
  /// The client's own `GoalBlocked` is narrower than it first reads —
  /// `usersAtPosition(goal)` filtered by `position.manhattanDistance(start) <= 1`, so
  /// it fires only when the goal is occupied *and* next to you — and it never comes up
  /// in either client, because `moveSpaceUserToTile` has already relocated an occupied
  /// goal by then. [goTo] relocates for the same reason, so this list is only ever
  /// used to route *around* people.
  ///
  /// Read off [peopleOnMap] rather than the roster directly, so "somebody is standing
  /// there" means the same thing here as it does on the screen: present rather than
  /// merely connected, on this floor, and never me.
  List<({int x, int y})> _occupied() => [for (final person in peopleOnMap) (x: person.x.round(), y: person.y.round())];

  /// Confirms the connection is really up, and reconnects only if it is not.
  ///
  /// What iOS resume calls. A suspended app's socket dies without an error, so the
  /// held connection may be a corpse — but tearing down a healthy one on every resume
  /// would mean a fresh state dump every time the user glances at their phone.
  Future<void> verifyLink() async {
    final collector = _collector;
    if (collector == null) return;
    if (collector.healthy && collector.hasState) return;
    await collector.resync();
  }

  /// Re-checks whether the computer can still wake this phone.
  ///
  /// Also what iOS resume calls, and separate from [verifyLink] because the two
  /// answers have nothing to do with each other: the Gather socket works on cellular
  /// with the Mac shut, and the Mac can be sitting there ready while Gather is down.
  ///
  /// This *is* the probe. `POST /push/register` is idempotent by design and its reply
  /// says whether the bridge can send, so re-posting it beats pinging `/health` and
  /// inferring the rest — and it refreshes our entry on the bridge while it is at it.
  Future<void> refreshPushReach() => _registerForPush();

  /// Reconnects, and resolves only once there is something to show for it.
  ///
  /// The floor is what makes pull-to-refresh feel like an action rather than a
  /// twitch: a reconnect can complete in well under a frame, and an indicator that
  /// appears and vanishes inside two frames reads as a rendering fault.
  Future<void> reconnect() async {
    final floor = Future<void>.delayed(const Duration(milliseconds: 450));
    final collector = _collector;
    if (collector == null) return floor;
    await Future.wait([collector.resync(), floor]);
  }

  // ---- the activity feed -----------------------------------------------------

  /// Gather's own activity feed, which is a different thing from the log this app
  /// deleted.
  ///
  /// The class doc above explains why nothing is remembered: a history the phone
  /// builds itself can only cover the minutes it was awake. This one is not built
  /// here. It is Gather's, recorded server-side, and it is the same list the
  /// desktop client shows — so it is full when you open it after a weekend, which
  /// is exactly when the local one was empty.
  ActivityFeed? _activityFeed;

  /// What the last fetch returned, newest first.
  List<ActivityItem> _fetched = const [];

  /// Waves seen on the socket since that fetch.
  ///
  /// Provisional, and cleared by the next refresh rather than merged into it: the
  /// REST list is authoritative and already contains them by then, so replacing
  /// wholesale is what keeps one wave from appearing twice. The alternative —
  /// matching a live event to a row whose id we never saw — would have to guess.
  List<ActivityItem> _live = const [];

  bool _loadingActivity = false;
  Object? _activityError;

  /// The feed as the screen reads it: live waves on top, then the last fetch.
  List<ActivityItem> get activity => [..._live, ..._fetched];

  /// What a badge shows. Live waves are unread by definition — they arrived while
  /// you were looking elsewhere.
  int get unreadActivityCount => _live.length + _fetched.where((item) => !item.isRead).length;

  bool get isLoadingActivity => _loadingActivity;

  /// The last failure, or null. Kept so the screen can say what went wrong instead
  /// of showing an empty list, which would read as "nothing ever happened".
  Object? get activityError => _activityError;

  /// Whether the feed has been read for the space we are in. False across the
  /// whole launch window — before Gather has even named a space, and while the
  /// first fetch is in flight — which is when the screen shows a skeleton
  /// rather than claiming "nothing yet". An empty *answer* counts as fetched:
  /// that claim has been checked.
  bool get activityFetched => _fetchedFor != null && _fetchedFor == _activitySpaceId;

  /// The space the feed belongs to, once Gather has told us which one that is.
  String? get _activitySpaceId => _snapshot.self.spaceId ?? _spaceId;

  /// Which space [_fetched] was fetched for, so a reconnect into a different space
  /// does not leave the previous one's history on screen.
  String? _fetchedFor;

  Future<void> refreshActivity() async {
    final feed = _activityFeed;
    final spaceId = _activitySpaceId;
    if (feed == null || spaceId == null || _loadingActivity) return;

    _loadingActivity = true;
    notifyListeners();
    try {
      final page = await feed.fetch(spaceId);
      _fetched = page.items;
      _fetchedFor = spaceId;
      _live = const [];
      _activityError = null;
    } catch (error) {
      _activityError = error;
    } finally {
      _loadingActivity = false;
      notifyListeners();
    }
  }

  /// Marks items read in Gather, so the desktop client's badge clears too.
  ///
  /// Optimistic: the rows flip here first and are put back if Gather refuses.
  /// Waiting on a round trip to un-bold a line the user has already read is the
  /// kind of latency that makes an app feel like a web page.
  Future<void> markActivityRead(Iterable<ActivityItem> items) async {
    final feed = _activityFeed;
    final spaceId = _activitySpaceId;
    final markable = items.where((item) => item.canMarkRead && !item.isRead).toList();
    if (feed == null || spaceId == null || markable.isEmpty) return;

    final before = _fetched;
    final ids = markable.map((item) => item.id).toSet();
    _fetched = [for (final item in _fetched) ids.contains(item.id) ? item.markedRead() : item];
    notifyListeners();

    try {
      await feed.markRead(spaceId, markable);
    } catch (error) {
      _fetched = before;
      _activityError = error;
      notifyListeners();
    }
  }

  /// Sentences that arrive rather than being asked for.
  ///
  /// Everything else the user can trigger answers `Future<String?>` and the control
  /// that triggered it puts the answer on screen. A refusal from the server has no
  /// such control waiting on it — it lands seconds after the tap, halfway across the
  /// office — so it needs a channel of its own. Broadcast, because it is news and not
  /// a queue: nothing is owed delivery if no screen is listening.
  Stream<String> get notices => _notices.stream;
  final _notices = StreamController<String>.broadcast();

  /// A walk the office should keep the camera on until it arrives.
  ///
  /// The desk button lives in the dock and sends you somewhere that is usually off
  /// screen, so the map is asked to ride along rather than leaving you to hunt for
  /// yourself. A tapped tile needs none of this — it was on screen to be tapped.
  /// Broadcast, like [notices]: a walk nobody is watching is owed nothing.
  Stream<void> get followMe => _followMe.stream;
  final _followMe = StreamController<void>.broadcast();

  /// The same request, latched, for a map that was not there to hear it.
  ///
  /// The dock is on the call screen too, and the office is not built while that
  /// route is up — so "a walk nobody is watching is owed nothing" quietly became
  /// "the desk walk you start from the faces is never followed". It is the case
  /// that most wants following, because it is the one where you are not looking
  /// at the map when you ask.
  ///
  /// A timestamp rather than a flag: a request is only worth honouring while the
  /// walk it belongs to is still happening. Opening the map ten minutes later
  /// should show you the office, not jerk the camera onto your own desk for a
  /// journey that finished long ago.
  DateTime? _followWanted;

  /// Claims a pending follow, if there is one and it is still fresh.
  ///
  /// Taking it rather than reading it: two maps must not both ride the same
  /// walk, and a request left lying around is one that fires on the next mount.
  bool takeFollowRequest() {
    final at = _followWanted;
    _followWanted = null;
    return at != null && DateTime.now().difference(at) < const Duration(seconds: 10);
  }

  /// Test seam: raises the latch without the walk stack a real desk trip needs.
  @visibleForTesting
  void debugRequestFollow({Duration ago = Duration.zero}) =>
      _followWanted = DateTime.now().subtract(ago);

  /// Gather refusing to let us in somewhere, which arrives as an event and no patch.
  ///
  /// `isPermittedToMoveTo` is the second gate in `setPosition` and it refuses `move`
  /// and `teleport` alike. What it does *not* do is fail the action: the refusal is
  /// published to us alone, `{targetUserIds: new Set([this.id])}`, while the action
  /// itself returns `Success` and the position patch simply never comes. So a client
  /// that only applies patches sees a walk that stops making progress and no reason
  /// for it — which is what this app did until the rule was found.
  ///
  /// Stopping the walk first is the client's own order of business:
  ///
  /// ```js
  /// addEventListener(GameEvents.UserIsNotPermittedToEnterLockedArea, async ({spaceUserId, areaId}) => {
  ///   if (currentSpaceUser.id !== spaceUserId) return;
  ///   MoveController.stopPathMovement(false, true);
  ///   await currentSpaceUser.unfollow();
  ///   … openAreaRequestModal(area)
  /// })
  /// ```
  ///
  /// The modal at the end is Gather asking whether to knock. This app has nowhere to
  /// put that yet, so it says what happened and stops — [Walk] would otherwise
  /// re-plan into the same shut door four times over.
  void _noteRefusal(BusEvent event) {
    const locked = 'UserIsNotPermittedToEnterLockedArea';
    const meeting = 'UserIsNotPermittedToEnterMeetingArea';
    if (event.name != locked && event.name != meeting) return;

    // Addressed twice over — the envelope names us in `targetUserIds` and the payload
    // repeats it in `spaceUserId`, which is the half the client actually checks.
    // Either is enough, and requiring both would drop the event if Gather ever
    // widened the envelope.
    // Either source will do, and having both is the point: the collector resolves
    // self from the `Connection` row and the roster carries the same answer, so an
    // event that lands in the gap before one of them is ready is still ours to read.
    final me = _collector?.selfId ?? _roster?.selfId;
    if (me == null) return;
    if (!event.isFor(me) && event.payload['spaceUserId'] != me) return;

    // A prime suspect for "I walked up but no call": Gather refused the steps into a
    // locked or meeting area, published this to us alone, and let the action return
    // Success with no position patch — so the phone walked on optimistically while
    // the server kept us put. Recorded so the log says so instead of us guessing.
    _log('move: refused entry — ${event.name} area=${event.payload['areaId'] ?? '?'}');
    _walk?.release();
    notifyListeners();
    _notices.add(_refusalText(event, meeting: event.name == meeting));
  }

  /// What to say about a refusal, naming the room when the floor plan knows it.
  ///
  /// `areaId` is the area's `stableId_USE_THIS_INSTEAD_OF_ID`, which is the id
  /// [SpaceRoom.stableId] carries — matching it against [SpaceRoom.id] finds nothing.
  String _refusalText(BusEvent event, {required bool meeting}) {
    if (meeting) return 'That meeting is private.';
    final areaId = event.payload['areaId'];
    for (final room in map?.rooms ?? const <SpaceRoom>[]) {
      final name = room.name;
      if (room.stableId == areaId && name != null) return '$name is locked.';
    }
    return 'That room is locked.';
  }

  /// Test seam: the event bus without a socket to deliver it.
  ///
  /// The same handlers the live subscription runs, in the same order, minus the
  /// fold — which needs a tracker that has seen a roster. See [_noteReaction] and
  /// [_noteRefusal].
  @visibleForTesting
  void debugNoteEvent(BusEvent event) {
    _noteReaction(event);
    _noteRefusal(event);
  }

  /// Gather declining to *run* something, as opposed to declining to let us in.
  ///
  /// The other half of the same silence. `_noteRefusal` handles the permission gate
  /// inside `setPosition`, which publishes an event; this handles the layer above
  /// it, where an action never ran at all — a bad enum, a status past its length
  /// limit, a permission the account does not hold. Validation happens *before* the
  /// action, so nothing executes and no patch arrives: the only evidence is
  /// `actionReturns`, and without reading it the app would go on telling somebody
  /// their status was set.
  ///
  /// Deduplicated, because the actions most likely to be refused are the ones sent
  /// in bursts. A held D-pad is seven steps a second and a go-kart twenty-one; if
  /// the server starts refusing `move`, one sentence is the news and the next two
  /// hundred are noise.
  void _noteActionRefused(ActionRefused refusal) {
    final key = '${refusal.action}:${refusal.message}';
    final now = DateTime.now();
    final last = _refusedAt[key];
    if (last != null && now.difference(last) < _refusalCooldown) return;
    _refusedAt[key] = now;
    // Cheap to bound: without this, a long session refusing many different things
    // would keep every one of them forever.
    if (_refusedAt.length > 32) _refusedAt.remove(_refusedAt.keys.first);

    _notices.add('${_refusalSubject(refusal.action)}: ${refusal.message}');
  }

  final Map<String, DateTime> _refusedAt = {};
  static const _refusalCooldown = Duration(seconds: 10);

  /// What to call the thing that did not happen, in the user's terms.
  ///
  /// Falls back to the action's own id, which is not lovely but is honest and
  /// searchable — better than swallowing a refusal for an action nobody has written
  /// a phrase for yet.
  static String _refusalSubject(String action) => switch (action) {
        'setAvailability' => 'Gather would not change your availability',
        'setCustomStatus' || 'clearCustomStatus' => 'Gather would not change your status',
        'broadcastEmote' => 'Gather would not send that',
        'startSpeaking' || 'stopSpeaking' => 'Gather would not show that you are talking',
        'leaveCluster' => 'Gather would not leave the conversation',
        'teleport' || 'move' => 'Gather would not move you',
        'walk' || 'run' || 'drive' => 'Gather would not change your pace',
        'enterSpace' => 'Gather would not let you into the space',
        'loadSpaceUser' => 'Gather would not load your avatar',
        'reportActivity' => 'Gather would not record your activity',
        _ => 'Gather refused $action',
      };

  /// Test seam: the action-refusal path without a socket to produce one.
  @visibleForTesting
  void debugNoteRefusal(ActionRefused refusal) => _noteActionRefused(refusal);

  /// Tells Gather whether the person is actually at their phone.
  ///
  /// `reportActivity` used to be sent exactly once, at the handshake, saying
  /// `true` — so `Connection.isActive` stayed true for the life of the socket and a
  /// backgrounded phone went on claiming somebody was there. The desktop client
  /// reports on every idle and focus change; the phone's equivalent is the
  /// lifecycle, which is where this is called from.
  Future<void> setActive(bool active) async {
    _collector?.setActive(active);
  }

  /// Somebody threw an emoji. Ours included.
  ///
  /// `EmoteEvent` addresses itself to everyone in range **and to the sender**, so
  /// no special case is needed to see our own — [sendEmoteLocalFirst] draws it
  /// early rather than differently, and this refreshes it when the echo lands.
  ///
  /// The emoji is read under two names. Gather's own action sends `emote`, which
  /// is what has been observed coming back; `emoji` is what the *status* actions
  /// on the same socket call the same kind of value, and accepting both costs a
  /// line and removes a way for this to go silently blank.
  void _noteReaction(BusEvent event) {
    if (event.name != 'EmoteEvent') return;
    final who = event.senderId;
    if (who == null) return;
    final payload = event.payload;
    final emote = payload['emote'] ?? payload['emoji'];
    if (emote is! String || emote.isEmpty) return;
    reactions.note(who, emote);
  }

  /// A wave off the socket, shown before the next fetch confirms it.
  void _noteActivity(BusEvent event) {
    if (event.name != 'WaveEvent') return;
    if (!event.isFor(_collector?.selfId)) return;
    _live = [
      WaveActivity(
        id: 'wave:live:${event.sentTime ?? ''}:${event.senderId ?? ''}',
        at: DateTime.tryParse(event.sentTime ?? '')?.toUtc() ?? DateTime.now().toUtc(),
        actorSpaceUserId: event.senderId,
      ),
      ..._live,
    ];
  }

  /// Best available name for a player id, falling back to a short id.
  String nameFor(String id) {
    for (final player in _snapshot.players) {
      if (player.id == id) return player.label;
    }
    return id.length <= 8 ? id : id.substring(0, 8);
  }

  // ---- wiring ----------------------------------------------------------------

  void _attach() {
    unawaited(_detach());

    final auth = _auth = GatherAuth(
      credentials: _credentials,
      // Google may rotate the refresh token. Persisting the new one immediately is
      // what keeps a phone working across the rotation instead of silently holding a
      // credential that has been superseded.
      onRotated: (next) async {
        _credentials = next;
        await _credentialStore.save(next);
      },
    );

    // Same credential as the socket, different transport: the feed is REST, and
    // the phone mints its own ID tokens for both. So are the faces.
    _activityFeed = _buildActivityFeed(auth);
    _photos = ProfilePhotos(auth: auth);

    final collector = _collector = _buildCollector(auth, _spaceId);
    final party = _party = PartyMode(collector: () => _collector);
    final walk = _walk = Walk(
      collector: () => _collector,
      map: () => map,
      // A route ends by itself, and the map's *Go to* pill is a `Stop` for as long as
      // one is running. Waking the tree here rather than waiting for the roster that
      // follows: the two are up to a quarter of a second apart, which is a quarter of
      // a second of a button offering to cancel a walk that already finished.
      onRouteEnded: notifyListeners,
      // Same reasoning: the kart appearing and disappearing is a thing the screen
      // shows, and it happens mid-walk rather than on a roster boundary.
      onGaitChanged: notifyListeners,
      log: _log,
    )..boost = _boost;

    _subs
      ..add(
        collector.rosters.listen((roster) {
          // Party mode first, so a hop fired from this same roster is judged against the
          // freshest positions we hold rather than the previous ones.
          party.noteRoster(roster);
          _roster = roster;
          // After `_roster`, so the floor plan `walk` looks up per step is the one for
          // the floor this roster puts us on — `map` reads `_myRow()` to find it.
          walk.noteRoster(roster);
          // The collector already coalesces and only publishes when something in the
          // state actually moved, so this is "the map changed", not a clock.
          _positions.tick();
          _noteDirectory(roster);
          _noteCluster(roster);
          _noteSpeakers(roster);
          final out = _tracker.applyRoster(roster);
          _onFold(out);
          _noteMine();
        }),
      )
      ..add(
        collector.interactions.listen((event) {
          // Before the fold, so a wave is on the list by the time the notification
          // it produces wakes the screen that shows it.
          _noteActivity(event);
          _noteReaction(event);
          _noteRefusal(event);
          _onFold(_tracker.applyInteraction(event));
        }),
      )
      ..add(collector.refusals.listen(_noteActionRefused))
      ..add(collector.statuses.listen(_onCollectorStatus))
      ..add(party.changes.listen(_onPartyChanged))
      ..add(party.progress.listen(_onPartyProgress))
      ..add(party.hops.listen(_onPartyHop))
      // The network-change watcher. A wifi<->cellular handoff leaves both sockets
      // half-open — healthy-looking, carrying nothing — and the deaf-timer takes
      // 45s to notice, which is 45s of no roster and so no call. This turns the
      // handoff itself into the trigger. Seeded first so the first change counts.
      ..add(_connectivityChanges.listen(_onConnectivityChanged));

    unawaited(_seedConnectivity());
    collector.start();
    unawaited(_registerForPush());
  }

  /// Record the current interface set, so [_onConnectivityChanged] can tell a real
  /// handoff from a repeat and does not fire a resync on the connection we just
  /// opened. Best-effort: a probe that throws leaves the baseline null, which only
  /// costs one extra (harmless) resync on the first change.
  Future<void> _seedConnectivity() async {
    try {
      // Check after the await, not with `??=`: `??=` tests null *before* evaluating
      // the probe, so a real change that lands mid-await would still be overwritten
      // by the now-stale baseline. Only adopt the probe if nothing arrived first.
      final seen = await _connectivityNow();
      _lastConnectivity ??= seen;
    } on Object {
      // The watcher degrades to the deaf-timer, which is where we started.
    }
  }

  /// A network interface came or went. Force a reconnect when the usable transport
  /// changed, rather than waiting out the deaf-timer.
  ///
  /// Going *offline* is left alone: there is nothing to reconnect to, the socket
  /// will drop on its own, and a resync into no network is just churn. It is the
  /// arrival of a *different* transport — cellular taking over from dropped wifi,
  /// or the reverse — that strands a half-open socket, and that is what this acts
  /// on. Coalesced on a short cooldown because one handoff emits several events.
  /// True once connectivity has been seen and the last sighting was no transport at all.
  /// Null (not yet seeded) reads as not-offline, so startup does not flash the banner.
  bool _isOffline() {
    final now = _lastConnectivity;
    return now != null && !now.any((r) => r != ConnectivityResult.none);
  }

  /// Stand down the steps that need the game socket: party mode, a held D-pad, and a
  /// live call's publish. Called both when the collector reports unhealthy and the
  /// instant the network drops, so the mic does not stay open on a room we left and the
  /// walker does not keep stepping into a socket that refuses every move. Everything
  /// else — the map, settings, navigation — stays usable; this gates only the online bits.
  void _suspendOnlineActivity(String detail) {
    _party?.stop(detail);
    _walk?.release();
    unawaited(_call?.hangUp() ?? Future<void>.value());
  }

  void _onConnectivityChanged(List<ConnectivityResult> now) {
    final before = _lastConnectivity;
    _lastConnectivity = now;

    final online = now.any((r) => r != ConnectivityResult.none);
    if (!online) {
      _log('net: went offline — waiting for a transport');
      // Say so at once, and stand the online-only steps down now rather than at the
      // 45s deaf-timer. The socket stays open-but-deaf after the radio drops (flight
      // mode, a dead zone), so until the timer trips the screen would otherwise keep
      // claiming we are live while moves fall into the void. There is nothing to
      // resync to yet — raise the flag and suspend the things that need the network.
      // Clear the resync cooldown: the next event is a transport *returning*, and
      // that recovery must reconnect immediately. Without this, a radio that flaps
      // offline within 5s of a prior resync would have its comeback swallowed by the
      // cooldown and fall back to the 45s deaf-timer — the very wait this watcher exists to avoid.
      _lastNetResync = null;
      final collector = _collector;
      if (collector != null && !_link.isOffline) {
        _link = const LinkStatus(LinkState.offline, 'No connection — waiting for network.');
        _suspendOnlineActivity('no network');
        notifyListeners();
      }
      return;
    }
    if (before != null &&
        before.length == now.length &&
        before.toSet().containsAll(now)) {
      return; // The same interfaces; nothing to reconnect for.
    }

    final at = _now();
    final last = _lastNetResync;
    if (last != null && at.difference(last) < const Duration(seconds: 5)) return;
    _lastNetResync = at;

    final collector = _collector;
    if (collector == null) return;

    _log('net: transport changed to ${now.map((r) => r.name).join('+')} — forcing resync');
    // Flip the badge now rather than waiting for the reconnect to report in, so the
    // screen says "Reconnecting" the instant the network moves under it.
    _link = const LinkStatus(LinkState.retrying, 'Network changed — reconnecting.');
    notifyListeners();
    unawaited(collector.resync());
  }

  Future<void> _detach() async {
    final subs = List.of(_subs);
    final collector = _collector;
    final party = _party;
    final walk = _walk;
    final call = _call;
    // Before the collector goes, and that ordering is the whole of it: [Walk] reaches
    // its collector through a closure over the field below, so a release after this
    // line has nothing to send on even though the socket is still open until the end of
    // this method. What it needs to send is the `walk` that gets us out of the go-kart.
    // `speed.modifier` is a synced field and the only thing every other client reads, so
    // unpairing mid-drive without saying otherwise parks this avatar in a kart on every
    // screen in the space.
    walk?.release();
    _subs.clear();
    _collector = null;
    _party = null;
    _walk = null;
    _call = null;
    _auth = null;
    // Faces are signed per space and per person. Pairing again as somebody else
    // must not serve them the previous account's cache.
    _photos?.clear();
    _photos = null;
    // The feed belongs to a credential and a space. Unpairing and pairing again as
    // somebody else must not leave the previous person's waves on the screen.
    _activityFeed = null;
    _fetched = const [];
    _live = const [];
    _fetchedFor = null;
    _activityError = null;
    // A hop belongs to the connection that made it. Kept across a reconnect it would
    // teleport a body on the first frame after the map came back.
    _lastTeleport = null;
    // The room's reactions belong to the room, and so does whether we were in
    // the middle of a sentence when the socket went. Both would otherwise be
    // inherited by whoever pairs this phone next.
    reactions.clear();
    _amSpeaking = false;

    for (final sub in subs) {
      await sub.cancel();
    }
    await party?.dispose();
    await walk?.dispose();
    // Before the collector: the call holds a microphone and a camera, and the one
    // failure worth avoiding here is leaving either running after the socket that
    // justified them has gone.
    await call?.dispose();
    await collector?.dispose();
  }

  /// Hands this phone's push token to the bridge, and records whether it landed.
  ///
  /// The only thing that still needs the computer at all. FCM tokens rotate — a
  /// reinstall, a restore from backup, Firebase's own schedule — so registering once
  /// at pairing would let push die silently months later. Registering on every attach
  /// and every resume is idempotent and costs one request.
  ///
  /// A failure is still not *complained* about — the phone is frequently on a
  /// different network from the computer, and that is a normal state, not a fault —
  /// but it is no longer thrown away. [pushReach] is the difference between "we never
  /// looked" and "we looked and it is fine", which is what the settings card needs to
  /// stop guessing.
  Future<void> _registerForPush() async {
    if (!_settings.isComplete) return _setPushReach(const PushRegistration(PushReach.unpaired));
    final registrar = _pushRegistrar();
    // No registrar means no Firebase in this build, so nothing can wake the app.
    if (registrar == null) return _setPushReach(const PushRegistration(PushReach.noToken));

    _setPushReach(await registrar.register(_settings, installId: await _bridgeStore.installId()));
    _pushRefresh ??= registrar.tokenRefreshes.listen((_) {
      registrar.forgetToken();
      unawaited(_registerForPush());
    });
  }

  void _setPushReach(PushRegistration next) {
    if (next == _pushReach) return;
    _pushReach = next;
    notifyListeners();
  }

  void _onFold(FoldResult out) {
    // Events are no longer kept — the screen has nowhere to put them. They exist to
    // be notified about, and nothing else, so this is the only thing left to do with
    // one. Fire and forget: a failed notification must never break the fold.
    for (final event in out.emit) {
      _notifier.consider(event, nameFor);
    }
    if (out.emit.isNotEmpty || out.stateChanged) {
      _snapshot = _tracker.snapshot();
      _maybeLoadActivity();
      notifyListeners();
    }
  }

  /// Fetches the feed once the space is known, and again if it changes.
  ///
  /// Which space we are in arrives with the state dump, not at attach — so this is
  /// checked wherever the snapshot is replaced rather than fired from [_attach],
  /// where the answer would still be null.
  void _maybeLoadActivity() {
    final spaceId = _activitySpaceId;
    if (spaceId == null || spaceId == _fetchedFor || _loadingActivity) return;
    unawaited(refreshActivity());
  }

  void _onCollectorStatus(CollectorStatus status) {
    _tracker.setHealth(
      CollectorHealth(
        gather: status.healthy,
        // `cdp` is a compatibility alias, not a second collector: `hasRichData` reads
        // `gather || cdp`, and mirroring keeps a build that predates the rename honest.
        cdp: status.healthy,
        detail: status.detail,
      ),
    );

    // While the radio is down the collector's own health is stale — the socket is open
    // but deaf, so it may still claim "healthy" for ~45s and would otherwise flip the
    // badge back to live. Offline wins until a transport returns, and says the truer word.
    final offline = _isOffline();
    _link = switch (status) {
      CollectorStatus(needsPairing: true) => LinkStatus(LinkState.idle, status.detail, true),
      _ when offline => const LinkStatus(LinkState.offline, 'No connection — waiting for network.'),
      CollectorStatus(healthy: true) => LinkStatus(LinkState.live, status.detail),
      _ => LinkStatus(LinkState.retrying, status.detail),
    };

    if (!status.healthy || offline) {
      _suspendOnlineActivity(status.detail ?? 'lost the connection to Gather');
    }

    _snapshot = _tracker.snapshot();
    _maybeLoadActivity();
    notifyListeners();
  }

  void _onPartyChanged(PartyState party) {
    _tracker.setParty(party);
    _snapshot = _tracker.snapshot();
    notifyListeners();
  }

  /// Party mode's counter, without the roster around it.
  ///
  /// Deliberately no `_invalidateFeed()`: nothing here can relabel an event, and
  /// reclassifying the whole log once a second is exactly the cost this exists to
  /// avoid.
  void _onPartyProgress(PartyState party) {
    _tracker.setParty(party);
    _snapshot = _snapshot.withParty(party);
    notifyListeners();
  }

  /// A hop went out. Tell the map where the body landed, now rather than later.
  ///
  /// [_positions] and not [notifyListeners]: this is movement, and waking the whole
  /// tree four times a second is the cost that [positions] exists to avoid. Ticking
  /// it at all — rather than waiting for the roster that follows — is what keeps the
  /// body from standing on the old tile for up to a quarter of a second before it
  /// vanishes from it.
  void _onPartyHop(PartyTile tile) =>
      _noteTeleport(tile.x.toDouble(), tile.y.toDouble());

  // ---- test seams ------------------------------------------------------------

  /// Feeds a roster in as though Gather had sent it, for the screens that draw
  /// positions rather than the presence digest.
  ///
  /// Deliberately the same path as the live subscription, including *not* calling
  /// [notifyListeners] for a roster the tracker finds nothing in. A seam that woke
  /// the whole tree unconditionally would make a screen wired to the wrong
  /// [Listenable] look live in tests and freeze in the office, which is exactly the
  /// bug this shape exists to prevent.
  @visibleForTesting
  void debugApplyRoster(Roster roster) {
    _roster = roster;
    _positions.tick();
    // Same order as the real listener, and not a shortened version of it: a seam
    // that skips a step is a seam that passes while the app does the wrong thing.
    _noteDirectory(roster);
    _noteCluster(roster);
    _noteSpeakers(roster);
    _onFold(_tracker.applyRoster(roster));
    _noteMine();
  }

  /// Feeds a feed in as though Gather had answered, so the activity screen can be
  /// exercised without a network.
  ///
  /// Sets [_fetchedFor] as a real fetch would, so the auto-load does not then fire
  /// over the top of what a test just placed.
  @visibleForTesting
  void debugApplyActivity(List<ActivityItem> items, {Object? error}) {
    _fetched = items;
    _fetchedFor = _activitySpaceId ?? 'test-space';
    _activityError = error;
    notifyListeners();
  }

  /// Feeds a hop in as though party mode had fired one, for the map to draw.
  ///
  /// The live path reads our own id off the collector, which a widget test does not
  /// have — so it is given here instead. Everything downstream of that is the same
  /// path, including the tick that gets it to the screen.
  @visibleForTesting
  void debugTeleport(String id, double x, double y) {
    _lastTeleport = (id: id, x: x, y: y, seq: ++_teleportSeq);
    _positions.tick();
  }

  /// Feeds a snapshot in as though Gather had sent it, so the screens can be
  /// exercised without a connection.
  @visibleForTesting
  void debugApplySnapshot(PresenceSnapshot snapshot) {
    _loaded = true;
    _snapshot = snapshot;
    notifyListeners();
  }

  /// Test seam for a single event. Notifications no-op until [Notifier.init].
  @visibleForTesting
  void debugApplyEvent(GatherEvent event) => _onFold(FoldResult(emit: [event], stateChanged: false));

  /// Test seam for the link state, which changes what an empty feed means: with no
  /// connection the screen says so rather than claiming all is quiet.
  @visibleForTesting
  void debugApplyLink(LinkStatus status) {
    _link = status;
    notifyListeners();
  }

  /// Test seam for push reachability, which is otherwise only reachable by having a
  /// real bridge on the LAN answer a real POST — the reason this state went wrong
  /// unnoticed in the first place.
  @visibleForTesting
  void debugApplyPushReach(PushRegistration reach, {String? bridgeName}) {
    _pushReach = reach;
    if (bridgeName != null) _bridgeName = bridgeName;
    notifyListeners();
  }

  @override
  void dispose() {
    _positions.dispose();
    _directoryChanges.dispose();
    unawaited(_notices.close());
    unawaited(_followMe.close());
    // A face resolved a millisecond before the app closed would otherwise
    // notify a disposed notifier, which throws.
    _faceNotice?.cancel();
    _faceNotice = null;
    // Same reasoning: a cluster change half a second before the app closed would
    // otherwise fire into a call that has already been torn down.
    _clusterDebounce?.cancel();
    _clusterDebounce = null;
    unawaited(_detach());
    // After `_detach`, which clears it: a `ChangeNotifier` notified after it has
    // been disposed throws, and `_detach` reaches that line before its first
    // await.
    reactions.dispose();
    // Outside `_detach` on purpose: token rotation is about this device, not about any
    // one connection, so it must survive a reconnect and only end with the app.
    _pushRefresh?.cancel();
    _pushRefresh = null;
    super.dispose();
  }
}

/// A [Listenable] with nothing in it, for changes whose value is read from
/// somewhere else.
///
/// The disposed guard is not defensive programming: `_detach` cancels the roster
/// subscription asynchronously, so a roster already in flight can land after
/// `dispose`, and a [ChangeNotifier] used after disposal throws.
class _Ticker extends ChangeNotifier {
  bool _disposed = false;

  void tick() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
