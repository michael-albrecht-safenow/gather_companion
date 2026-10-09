/// Driving your own avatar from the phone, one tile at a time.
///
/// The `move` action is the whole of Gather's movement API — `{direction}`, one tile
/// per call — and its body on the model is three lines with no check in it:
///
/// ```js
/// const e = new Direction(A.direction).toPositionDelta();
/// const g = new Position({x: this.x + e.x, y: this.y + e.y});
/// this.direction = new Direction(A.direction);
/// this.setPosition(g, {map: ..., prevPosition: this.position})
/// ```
///
/// So everything that makes movement feel like movement lives on the client, and this
/// is that half of it. Two problems, and they are the whole file.
///
/// ## Knowing where you are
///
/// Whether a step is legal depends on the tile you are standing on, and this cannot
/// read that off the roster: positions arrive coalesced over 250ms while a walk runs
/// at seven tiles a second, so by the time Gather confirms the tile you are on, you
/// asked to leave it two steps ago. Checking collision against a stale tile means
/// walking into the first wall you meet.
///
/// So the tile is tracked here, and the roster corrects it rather than supplying it —
/// the same optimism the client applies (`optimistic: true` on the action itself).
/// [noteRoster] keeps every tile stepped onto and not yet seen confirmed, and treats
/// an arriving position three ways:
///
///  * **it is one we claimed** — the steps up to it have landed; drop them and keep
///    believing the rest, which are still in flight.
///  * **it is the one we are standing on** — the same case; the list empties.
///  * **it is somewhere we never claimed to be** — a step was dropped, or the desktop
///    client moved, or party mode hopped. Gather is right and this is wrong.
///
/// That last branch is what makes a phone D-pad safe to share an avatar with a laptop.
///
/// ## Not walking through the office
///
/// [SpaceMap.canStep] is the rule and it is transcribed rather than invented; see
/// `space_map.dart`. This applies it before every step and simply declines the ones
/// that fail. A refused step is not an error worth showing — it is a wall — so it
/// stops the avatar and nothing else.
///
/// **No map, no walking.** A step sent without one is a step nobody checked, and the
/// consequence is not a glitch: the office footprint is 96×52 of a 124×82 grid, and
/// the emptiness around it is walkable as far as the game server is concerned.
library;

import 'dart:async';

import 'collector.dart';
import 'game_protocol.dart';
import 'space_map.dart';

/// How long one tile takes, and so how fast a held button repeats.
///
/// `MOVEMENT_DURATION = 1e3/7` — the walk the client animates between two tiles.
/// Stepping faster than this outruns the animation, and the avatar skates.
const walkStep = Duration(microseconds: 142857);

/// How long you spend climbing into the go-kart, and back out of it.
///
/// `const Z = 1e3/7*2` — two walking steps — parked in `pauseMovingMsRemaining` by
/// `resetInOutGoKartPauseTimer` the moment the gait becomes [Gait.driving]. Every tick
/// subtracts the interval currently in force and returns early while any is left, so
/// what it buys is a beat of standing still where the kart appears underneath you.
/// Without it the avatar is simply teleported into third gear.
const kartPause = Duration(microseconds: 285714);

/// `Speed.TILE_PATH_LENGTH_REMAINDER_TO_WALK` — walk the last six tiles of anything.
const _walkWithin = 6;

/// `Speed.TILE_PATH_LENGTH_REMAINDER_TO_RUN` — and run the ten before those.
const _runWithin = 16;

/// The tiles `calculateSpeedModifierForPathStarting` sets aside for slowing down.
///
/// Unnamed in the client — a bare `const e = 7` — but it is the only reason the
/// thresholds below do not read as their own numbers: a route is chosen on the
/// distance it will *cruise*, not on its length, and every route spends its last
/// [_walkWithin] tiles walking whatever it started as.
const _headStart = 7;

/// How fast to set off down a route [tiles] long, counting the tile being stood on.
///
/// `calculateSpeedModifierForPathStarting`, whole:
///
/// ```js
/// calculateSpeedModifierForPathStarting(A) {
///   const e = 7;
///   if (A - e <= Speed.TILE_PATH_LENGTH_REMAINDER_TO_WALK) return SpeedModifier.WALKING;
///   if (A - e <= Speed.TILE_PATH_LENGTH_REMAINDER_TO_RUN) return SpeedModifier.RUNNING;
///   return SpeedModifier.DRIVING;
/// }
/// ```
///
/// Which lands on: walk anything up to 13 tiles, run 14 to 23, and take the kart from
/// 24. This is the ceiling for the whole route and it is fixed at the off —
/// `basePathSpeedModifier` — so a walk never speeds up partway, it only ever slows.
Gait gaitToSetOff(int tiles) {
  if (tiles - _headStart <= _walkWithin) return Gait.walking;
  if (tiles - _headStart <= _runWithin) return Gait.running;
  return Gait.driving;
}

/// How fast to be with [tiles] still to go, when [fastest] is this route's ceiling.
///
/// `calculateSpeedModifierForPathRemaining`, minus the area check that needs a map —
/// [Walk] applies that half, because it is the one that needs to know where you are:
///
/// ```js
/// calculateSpeedModifierForPathRemaining(A, e) {
///   const g = currentSpaceUser.currentMapAreaOrThrow;
///   if (g && !g.isPublicWalkway) return SpeedModifier.WALKING;
///   let t = SpeedModifier.DRIVING;
///   if (A <= Speed.TILE_PATH_LENGTH_REMAINDER_TO_WALK) { t = SpeedModifier.WALKING }
///   else if (A <= Speed.TILE_PATH_LENGTH_REMAINDER_TO_RUN) { t = SpeedModifier.RUNNING }
///   return Math.min(e, t);
/// }
/// ```
///
/// The `Math.min` is the whole of the deceleration: run out the middle of a long
/// route, walk the last six tiles of every route however it began, and never exceed
/// the ceiling. Recomputed on every step, because the number that matters is how much
/// is *left*.
Gait gaitFor(int tiles, Gait fastest) {
  final want = tiles <= _walkWithin
      ? Gait.walking
      : tiles <= _runWithin
          ? Gait.running
          : Gait.driving;
  return want.modifier <= fastest.modifier ? want : fastest;
}

/// How long a single hold may last before it is dropped.
///
/// A finger cannot get lost, but an app can: backgrounded mid-press, or a pointer
/// cancelled by a system gesture that never sends the up event. Thirty seconds is 210
/// tiles, well past any real hold, and it is the difference between a control and a
/// key stuck down in somebody's workspace.
const maxHold = Duration(seconds: 30);

/// How many unconfirmed steps to remember, **at a walk**.
///
/// Two seconds of walking. Past that the roster has had six chances to say something
/// and the oldest entries are no longer evidence of anything.
///
/// The units matter and getting them wrong is a bug that only appears in a go-kart:
/// this is a *count* and what it wants to be is a *duration*, so left as a flat 16 it
/// buys 2.3 seconds of tolerance at a walk and 0.76 of a second while driving — three
/// roster ticks. One late roster past that and the tile it names has already fallen
/// off the front of the list, which reads as a correction from nowhere and ends the
/// walk. See [Walk._pendingLimit], which scales it by the gait so the window is the
/// same stretch of *time* however fast the legs are going.
const _maxPending = 16;

/// How many times one journey may re-plan before giving up.
///
/// A bound on work rather than a real limit: each re-plan either finds a way from
/// where we actually are or does not, and the counter resets on every step that
/// lands, so this only ever catches a route thrashing in one spot.
const _maxReplans = 4;

/// One step's worth of state, held so the D-pad can be a dumb button.
class Walk {
  Walk({
    required Collector? Function() collector,
    required SpaceMap? Function() map,
    void Function(String)? log,
    /// Called when a route stops running, for whatever reason. See [release].
    void Function()? onRouteEnded,
    /// Called when the gait changes. See [gait].
    void Function()? onGaitChanged,
    /// Called when steps keep being sent that no roster ever confirms — the signal
    /// that the server is not applying our moves, i.e. we may have gone invisible
    /// to others. Fire-and-forget; the collector debounces its own recovery.
    void Function()? onMovesUnconfirmed,
    /// Called when a roster confirms a step after [onMovesUnconfirmed] had fired —
    /// the server is applying our moves again. The counterpart signal: it is what
    /// lets a collector tell a walk-triggered recovery that actually took from one
    /// that only looks healthy because we are still reported connected. Fires once
    /// per doubt episode, not per confirmed step.
    void Function()? onMovesConfirmed,
    /// Called after each step that reaches the socket, so the screen can repaint
    /// the optimistic move the instant it happens rather than waiting for the
    /// roster that confirms it. See [leadTile].
    void Function()? onStepped,
    this.interval = walkStep,
    this.holdLimit = maxHold,
    // Test seam. Production uses the wall clock.
    DateTime Function()? now,
        // Assigned the long way round because a named parameter cannot be a private
        // initializing formal.
        // ignore: prefer_initializing_formals
  })  : _collector = collector,
        // ignore: prefer_initializing_formals
        _map = map,
        _log = log ?? _noop,
        // ignore: prefer_initializing_formals
        _onRouteEnded = onRouteEnded,
        // ignore: prefer_initializing_formals
        _onGaitChanged = onGaitChanged,
        // ignore: prefer_initializing_formals
        _onMovesUnconfirmed = onMovesUnconfirmed,
        // ignore: prefer_initializing_formals
        _onMovesConfirmed = onMovesConfirmed,
        // ignore: prefer_initializing_formals
        _onStepped = onStepped,
        _now = now ?? DateTime.now;

  static void _noop(String _) {}

  /// Looked up per step rather than held: both are replaced whenever the app
  /// reconnects, and a stale collector is a step into a dead socket.
  final Collector? Function() _collector;
  final SpaceMap? Function() _map;
  final void Function(String) _log;
  final void Function()? _onRouteEnded;
  final void Function()? _onGaitChanged;
  final void Function()? _onMovesUnconfirmed;
  final void Function()? _onMovesConfirmed;
  final void Function()? _onStepped;
  final Duration interval;
  final Duration holdLimit;
  final DateTime Function() _now;

  Timer? _timer;
  String? _direction;
  DateTime? _startedAt;

  /// Where we believe we are standing.
  int? _x;
  int? _y;

  /// Tiles stepped onto and not yet confirmed by a roster, oldest first. The last is
  /// always where we believe we are.
  final _pending = <({int x, int y})>[];

  /// Whether a buffer overflow has fired [_onMovesUnconfirmed] without a roster
  /// confirming a step since. Latched so the recovery is signalled once per episode:
  /// set when the buffer overflows, cleared by the next confirmation (which then
  /// fires [_onMovesConfirmed]) or by an [_adopt] that starts the buffer fresh.
  bool _doubtRaised = false;

  /// The tiles left to walk through, nearest first, or empty when nothing is routed.
  ///
  /// Held as tiles rather than as directions on purpose. The roster is allowed to
  /// correct us mid-route — that is the whole point of [noteRoster] — and a list of
  /// directions applied from a tile we turned out not to be standing on walks the
  /// rest of the route somewhere nobody asked for. Tiles re-derive the direction
  /// from wherever we actually are, and can tell when the answer is nonsense.
  final _route = <({int x, int y})>[];

  /// Where the route was aimed, kept for [_replan]. Null when nothing is routed.
  ({int x, int y})? _goal;

  /// Re-plans since the last step that actually landed. See [_maxReplans].
  int _replans = 0;

  /// Which way the finger is pushing, or null when nothing is held.
  String? get direction => _direction;

  bool get walking => _timer != null;

  /// Whether a tapped destination is being walked to, as opposed to a held D-pad.
  ///
  /// Its own flag rather than `_route.isNotEmpty`: the last step of a route empties
  /// the list and *then* stops the walk, so the list is already empty by the time
  /// anything gets to ask why.
  bool get onRoute => _routing;
  bool _routing = false;

  /// How fast we are going, and so whether there is a go-kart under the avatar.
  ///
  /// `cachedGameSpeed` on the client, and held for the same reason: it is the thing
  /// [_setGait] compares against, so that a gait which did not actually change neither
  /// restarts the interval nor sends a second `drive` down the wire.
  Gait get gait => _gait;
  Gait _gait = Gait.walking;

  /// The fastest this route will ever go, fixed the moment it starts.
  ///
  /// `basePathSpeedModifier`. [gaitFor] never exceeds it, which is what makes a route
  /// something that only ever decelerates: the far end of a long walk is a walk.
  Gait _fastest = Gait.walking;

  /// The shift key, held down.
  ///
  /// Gather's manual go-kart is not a faster *route*, it is a modifier on movement
  /// itself, and its entire implementation is one line with nothing else in it:
  ///
  /// ```js
  /// onArrowKeyDown(A, e = false) {
  ///   …
  ///   this.setSpeedModifier(e ? SpeedModifier.DRIVING : SpeedModifier.WALKING)
  /// ```
  ///
  /// No distance test, no deceleration, no area test — hold it and you are driving
  /// until you let go. So this outranks all three, and it is a live field rather than
  /// an argument to [follow] because shift can be pressed and released *during* a
  /// walk and has to take effect on the next step, not the next journey.
  ///
  /// Treating it as a ceiling instead was a real bug and worth remembering: raising
  /// the ceiling on a twenty-tile route bought four steps of driving before
  /// [gaitFor]'s deceleration took the kart away again, which is a fifth of a second
  /// and reads exactly like a broken feature.
  bool get boost => _boost;
  bool _boost = false;

  set boost(bool value) {
    if (_boost == value) return;
    _boost = value;
    if (_routing) {
      _setGait(_routeGait(_route.length + 1));
    } else if (_direction != null) {
      _fastest = value ? Gait.driving : Gait.walking;
      _setGait(_fastest);
    }
  }

  /// The gait Gather has been told about, as far as this knows.
  ///
  /// Not the same thing as [_gait], and the gap between the two is the point. The
  /// send is fire-and-forget over a socket that can be down, and the one message that
  /// really has to land is the one getting us *out* of the kart: `speed.modifier` is a
  /// synced field, so a `drive` that arrived followed by a `walk` that did not leaves
  /// this avatar sitting in a go-kart on every other screen in the space. It stays
  /// there, too — [_setGait] only speaks when the gait changes, and a walk rebuilt on a
  /// reconnect starts out believing it is walking, so nothing ever says otherwise.
  ///
  /// So the last thing successfully said is remembered and [noteRoster] says it again
  /// until it lands. Starting at [Gait.walking] rather than at null is the conservative
  /// half: a fresh walk has told Gather nothing and assumes nothing needs saying, which
  /// keeps it from announcing a gait at somebody whose desktop client is legitimately
  /// driving the same avatar.
  Gait _announced = Gait.walking;

  /// Put [gait] on the wire, and remember whether it got there.
  void _tell(Gait gait) {
    final sent = _collector()?.setGait(gait);
    if (sent != null && sent.ok) _announced = gait;
  }

  /// What is left of the beat spent climbing into the kart, in microseconds.
  ///
  /// `pauseMovingMsRemaining`. Counted in the same currency the client uses — it
  /// subtracts the interval in force rather than reading a clock — so a test that
  /// drives [step] by hand pays exactly the same number of steps for it as a phone
  /// does at seven, fourteen or twenty-one tiles a second.
  int _pause = 0;

  /// One step at the gait currently in force.
  ///
  /// `getMoveInterval(A) { return P.N4 * (1 / A) }` — [interval] divided by the
  /// modifier, so [Gait.driving] is three steps in the time a walk takes one.
  Duration get _tick => Duration(microseconds: interval.inMicroseconds ~/ _gait.modifier);

  /// How long the step currently being taken lasts. [interval] at a walk, half of it
  /// at a run, a third of it in a go-kart.
  Duration get pace => _tick;

  /// [_maxPending] measured in time rather than in steps.
  ///
  /// Three times as many entries in a go-kart, because they arrive three times as
  /// fast and the roster they are being reconciled against did not speed up.
  int get _pendingLimit => _maxPending * _gait.modifier;

  /// Change gait, tell Gather, and re-time the walk. True when it actually changed.
  ///
  /// `setSpeedModifier` answers the same way and the client leans on the answer twice:
  /// an unchanged gait must not restart the interval, and must not make you climb out
  /// of the kart and back into it every single step.
  bool _setGait(Gait want) {
    if (want == _gait) return false;
    _gait = want;
    // Only ever announced, never asked. A socket that is not there yet is not a reason
    // to walk at the wrong speed — the pace is local.
    _tell(want);
    // Entering only. The name says "InOut" but the client calls it from exactly two
    // places and both test `=== DRIVING` first, so climbing out is free.
    if (want == Gait.driving) _pause = kartPause.inMicroseconds;
    if (_timer != null) {
      _timer!.cancel();
      _timer = Timer.periodic(_tick, (_) => step());
    }
    _onGaitChanged?.call();
    return true;
  }

  /// The gait for a route with [tiles] left in it, the tile underfoot included.
  ///
  /// The area rule comes first because it outranks the distance: however far there is
  /// still to go, you do not drive through somebody's meeting room. It is the one half
  /// of `calculateSpeedModifierForPathRemaining` that needs a map, which is why it is
  /// here rather than beside the rest of it.
  Gait _routeGait(int tiles) {
    // Before everything, because that is what the shift key does.
    if (_boost) return Gait.driving;
    final map = _map();
    final x = _x, y = _y;
    if (map != null && x != null && y != null) {
      final here = map.areaAt(x, y);
      if (here != null && !isPublicWalkway(here)) return Gait.walking;
    }
    return gaitFor(tiles, _fastest);
  }

  /// The tile this believes the avatar is on, which during a walk is ahead of the
  /// roster. Null until a roster has said once.
  ({int x, int y})? get at => _x == null ? null : (x: _x!, y: _y!);

  /// Where the avatar should be *drawn* while steps are still unconfirmed by a
  /// roster — the optimistic tile that leads the wire, so a press moves the body
  /// at once instead of after a round-trip. Null once the roster has caught up
  /// ([_pending] empty), so at rest the drawing falls back to the roster and this
  /// introduces no divergence [noteRoster] does not already own.
  ({int x, int y})? get leadTile => _pending.isEmpty ? null : at;

  /// The way we are facing right now, ahead of the roster, or null when no
  /// direction is being driven. Lets the avatar turn the instant the pad is held
  /// rather than a coalescing window later.
  String? get facing => _direction;

  /// Start walking, or turn a walk that is already running.
  ///
  /// The first step goes immediately: waiting out a tick before anything moves reads
  /// as the button having missed the press.
  /// [boost] decides the gait, and nothing else does — this is
  /// `onArrowKeyDown(new Direction(e), A.shiftKey)`, whose whole effect on speed is
  /// `setSpeedModifier(e ? DRIVING : WALKING)`. No distance test, and no area test
  /// either: a held direction with shift down drives at full speed through a meeting
  /// room, because this path never consults an area at all.
  void press(String direction) {
    if (!moveDirections.contains(direction)) return;
    // A held direction outranks a route, always. Somebody reaching for the pad while
    // their avatar is walking itself somewhere has changed their mind, and two things
    // stepping one avatar would fight — which is the same reason party mode lives on
    // the phone rather than on the bridge.
    if (_routing) {
      _routing = false;
      _route.clear();
      _onRouteEnded?.call();
    }
    // Before the early return below, and before the timer: a hold that is already
    // running still has to pick up the current state of the latch, which is exactly
    // the case that early return covers. [_setGait] re-times it.
    _fastest = _boost ? Gait.driving : Gait.walking;
    _setGait(_fastest);
    if (_direction == direction && _timer != null) return;

    _direction = direction;
    _startedAt ??= _now();
    _timer?.cancel();
    _timer = Timer.periodic(_tick, (_) => step());
    step();
  }

  /// Walk a route to its end, the way a double-click on the floor does on the desktop.
  ///
  /// [route] is what [SpaceMap.routeTo] returns — every tile including the one being
  /// stood on now. Replaces whatever was being walked before, because tapping a second
  /// destination means the second one.
  ///
  /// The desktop client re-runs its pathfinder on every tick and takes `moveRoute[1]`,
  /// which is how it copes with the floor changing underneath a walk. This walks the
  /// route it was given and **re-plans when that route stops making sense** — see
  /// [_replan]. Not every tick, which would be a full search at up to twenty-one
  /// searches a second; only when the next tile turns out not to be next to us.
  ///
  /// How fast depends on how far, and that is [gaitToSetOff]'s whole job: a trip
  /// across the office takes the go-kart and one to the next desk does not. [boost]
  /// overrides the lot — see there.
  void follow(List<({int x, int y})> route) {
    _route
      ..clear()
      ..addAll(route);
    // Where we were actually asked to go, kept so a walk that loses its way can find
    // it again rather than simply stopping in the middle of the office.
    _goal = route.isEmpty ? null : route.last;
    _replans = 0;
    // The tile we are already on is not a step.
    if (_route.isNotEmpty && _route.first.x == _x && _route.first.y == _y) {
      _route.removeAt(0);
    }
    if (_route.isEmpty) return;

    _routing = true;
    _direction = null;
    _startedAt = _now();
    // The route as handed over, current tile included — `moveRoute.length` on the
    // client, which is what both of these are measured in.
    _fastest = gaitToSetOff(route.length);
    _setGait(_routeGait(route.length));
    _timer?.cancel();
    _timer = Timer.periodic(_tick, (_) => step());
    step();
  }

  /// Stop. Idempotent, because a pointer can be cancelled twice.
  void release() {
    // A route ends by itself — on arrival, on a wall, on a roster that moved us — and
    // the screen has a control whose whole label depends on whether one is running.
    // Without this it would keep saying "Stop" until the next roster happened to wake
    // the tree, which is up to a quarter of a second of a button that lies.
    final wasOnRoute = _routing;
    _routing = false;
    _route.clear();
    _goal = null;
    _replans = 0;
    _timer?.cancel();
    _timer = null;
    _direction = null;
    _startedAt = null;
    // Standing still is walking. `tryToStopPathMovement` ends on
    // `setSpeedModifier(calculateSpeedModifierForPathRemaining(0, WALKING))`, which is
    // WALKING however the route began, and `stopArrowKeyMovement` says it outright.
    // Getting out of the kart matters more than getting in: an avatar left parked in
    // one is what everybody else in the space keeps seeing.
    _fastest = Gait.walking;
    _pause = 0;
    _setGait(Gait.walking);
    if (wasOnRoute) _onRouteEnded?.call();
  }

  Future<void> dispose() async => release();

  /// One step, or why there was not one.
  ///
  /// Public because it is the unit of work and the timer does nothing but call it,
  /// which is what lets a test walk somebody across a room without waiting out a
  /// real second per seven tiles.
  ({bool ok, String? detail}) step() {
    final held = _direction;
    if (held == null && _route.isEmpty) return (ok: false, detail: 'nothing is held');

    // First thing every tick on the client, on both the route path and the arrow-key
    // one: `pauseMovingMsRemaining -= this.moveIntervalMs; if (isMovementPaused()) return`.
    // Subtracting the interval rather than reading a clock is what makes the beat cost
    // the same six steps at any gait.
    _pause -= _tick.inMicroseconds;
    if (_pause > 0) return (ok: false, detail: 'getting into the go-kart');

    final startedAt = _startedAt;
    // Only a held direction can be held too long. A route is a finite list that ends
    // itself, and the longest one this floor can produce is within a tile or two of
    // the limit — dropping it at 30 seconds would abandon the walk almost home.
    if (held != null && startedAt != null && _now().difference(startedAt) >= holdLimit) {
      _log('walk: dropped a hold that lasted ${holdLimit.inSeconds}s');
      release();
      return (ok: false, detail: 'held too long');
    }

    final collector = _collector();
    if (collector == null) return (ok: false, detail: 'not connected to Gather');

    final x = _x, y = _y;
    if (x == null || y == null) {
      return (ok: false, detail: 'still working out where you are');
    }

    final map = _map();
    if (map == null) return (ok: false, detail: 'still reading the floor plan');

    var direction = held ?? _towards(x, y);

    // The route no longer starts where we are standing, or the tile it wants is not
    // one we can step onto: a roster corrected us onto a tile it does not pass
    // through, the desktop client moved this same avatar, or somebody put a chair in
    // the way. Everything after this point would be walked from the wrong place — so
    // find the way again from where we actually are.
    //
    // Which is what the client does, and it is not a nicety. `updatePathMove` re-runs
    // the whole pathfinder on *every* tick and takes `moveRoute[1]`, so a desktop
    // route is immune to drift by construction. Walking a fixed list instead is
    // cheaper and was fine at seven tiles a second; at twenty-one it is three times as
    // many chances for one late roster to end the walk halfway across the office,
    // which is what "the go-kart sometimes just stops" turned out to be.
    if (held == null && (direction == null || !map.canStep(x, y, direction))) {
      final again = _replan(map, x, y);
      if (again.arrived) {
        release();
        return (ok: false, detail: 'already there');
      }
      direction = again.direction;
    }

    if (direction == null) {
      if (held == null) release();
      return (ok: false, detail: 'lost the way there');
    }

    // Re-read the gait before the step, not after, and from what is *left* — which is
    // where the deceleration comes from. `updatePathMove` does it in this same slot,
    // between choosing the next tile and sending the move, and takes the step either
    // way: a gait change costs the interval it re-times, not a tick.
    //
    // `_route.length` counts what is still to walk and the client's counts the tile
    // underfoot as well, so the two agree at `+ 1`.
    if (held == null) _setGait(_routeGait(_route.length + 1));

    if (!map.canStep(x, y, direction)) {
      // A wall. Only a held direction reaches here now — a route has already had its
      // go at finding another way round.
      if (held == null) {
        release();
        return (ok: false, detail: 'blocked');
      }
      // Sent anyway, which is Gather's own behaviour and not a shortcut. `gameMove` is
      // `currentSpaceUser.move({direction})` with no collision test in front of it —
      // the client sends every held-key step and lets the model arbitrate — and the
      // model assigns `direction` *before* it consults `setPosition`. So a step into a
      // wall turns you to face the wall and moves nobody, which is what leaning on the
      // furniture looks like on the desktop.
      //
      // The tile is deliberately not advanced. `setPosition` refuses the position
      // (`isBlockedBy(map, prevPosition)`, and it returns false rather than clamping),
      // so believing it would put this walk a tile ahead of an avatar that never left.
      //
      // **Except off the grid**, which is the one refusal not to hand over. Gather
      // arbitrates with `blockedAtPosition`, which consults the object map and nothing
      // else, so the emptiness outside the building is not blocked — it is unoccupied.
      // A move over the edge would very likely be *accepted*, and the position it
      // writes is one no client has any art for. That refusal stays here.
      final step = stepOf(direction)!;
      final tx = x + step.dx;
      final ty = y + step.dy;
      if (tx >= 0 && ty >= 0 && tx < map.width && ty < map.height) {
        collector.move(direction: direction);
      }
      return (ok: false, detail: 'blocked');
    }

    final sent = collector.move(direction: direction);
    if (!sent.ok) {
      _log('walk: move $direction from ($x,$y) not sent — ${sent.detail}');
      if (held == null) release();
      return sent;
    }

    // Believed only once it is actually on the wire, so a socket that refused it does
    // not leave this walking on ahead of an avatar that never moved.
    final delta = stepOf(direction)!;
    _x = x + delta.dx;
    _y = y + delta.dy;
    // Ground truth for what the phone *tried*. `move` is fire-and-forget, so `sent.ok`
    // means "handed to the socket", not "accepted" — the real answer is whether a
    // matching position patch follows, which [noteRoster] logs when it does not.
    _log('walk: move $direction -> ($_x,$_y) gait=${_gait.name} inflight=${_pending.length + 1}');
    _pending.add((x: _x!, y: _y!));
    if (_pending.length > _pendingLimit) {
      _pending.removeAt(0);
      // The buffer is full of steps the roster never confirmed: we sent the moves
      // and the server never put us on any of those tiles. That is the direct
      // answer to "did the move reach the backend" — it did not take effect, which
      // on a phone almost always means the socket is half-open after a network
      // change. The optimistic walk is now a full buffer ahead of a stationary
      // avatar.
      _log('walk: $_pendingLimit moves sent, none confirmed by a roster — '
          'server is not applying our moves (socket likely half-open)');
      // The one unambiguous rung: a full buffer of unconfirmed steps is the server
      // ignoring us, not a late roster. Hand it to the collector, which decides
      // whether to re-enter or reconnect; this only reports, and only on overflow,
      // so a normal correction never raises it.
      _doubtRaised = true;
      _onMovesUnconfirmed?.call();
    }
    // A step that landed is the evidence that re-planning worked.
    _replans = 0;
    // Wake the screen now, on the optimistic tile, rather than on the roster that
    // confirms it up to a round-trip later — this is what makes the pad feel direct.
    _onStepped?.call();

    if (held == null) {
      _route.removeAt(0);
      if (_route.isEmpty) release();
    }
    return (ok: true, detail: null);
  }

  /// Find the way to [_goal] again from ([x], [y]), and say which way to go now.
  ///
  /// `arrived` is the case worth separating: a correction can land us *on* the goal,
  /// and re-planning from there answers a route of one tile. That is a walk that
  /// finished, not a walk that failed, and reporting it as "lost the way there" would
  /// put a sentence on screen about a journey that went fine.
  ///
  /// Deliberately without the `avoid` set [SpaceMap.routeTo] accepts. The caller
  /// passes the tiles people are standing on when the journey starts, and this has no
  /// roster of its own to ask — so a re-plan may route through somebody where the
  /// original would have gone round. That is the right trade: the client relocates
  /// off an occupied tile on arrival anyway, and a re-plan that refuses is a walk that
  /// stops dead.
  ({String? direction, bool arrived}) _replan(SpaceMap map, int x, int y) {
    final goal = _goal;
    if (goal == null || _replans >= _maxReplans) return (direction: null, arrived: false);
    _replans++;

    if (goal.x == x && goal.y == y) return (direction: null, arrived: true);

    final route = map.routeTo(fromX: x, fromY: y, toX: goal.x, toY: goal.y);
    if (route == null) return (direction: null, arrived: false);

    _route
      ..clear()
      ..addAll(route);
    if (_route.isNotEmpty && _route.first.x == x && _route.first.y == y) {
      _route.removeAt(0);
    }
    if (_route.isEmpty) return (direction: null, arrived: true);
    return (direction: _towards(x, y), arrived: false);
  }

  /// The way to the next tile on the route, or null when it is not next to us.
  String? _towards(int x, int y) {
    final next = _route.first;
    for (final direction in moveDirections) {
      final step = stepOf(direction)!;
      if (x + step.dx == next.x && y + step.dy == next.y) return direction;
    }
    return null;
  }

  /// What Gather says about where we are. See the library doc.
  void noteRoster(Roster roster) {
    // A gait that never reached Gather, said again now that a roster proves the socket
    // is carrying traffic. Before the position work below and outside all of its early
    // returns: this has to happen whether or not the roster happens to name us, and the
    // case it exists for is a connection that dropped mid-drive, where nothing else is
    // going to run again — the timer is cancelled and no step will ever be taken.
    if (_announced != _gait) _tell(_gait);

    RosterRow? me;
    for (final row in roster.rows) {
      if (row.id == roster.selfId) {
        me = row;
        break;
      }
    }
    final rx = me?.x, ry = me?.y;
    if (rx == null || ry == null || !rx.isFinite || !ry.isFinite) {
      // No self position in this roster means nothing corrects the optimistic walk —
      // it runs free, which is exactly how the phone can show you somewhere the
      // server does not. Logged only while we have steps riding on a correction that
      // is not coming, so a parked avatar does not spam the file every roster.
      if (_pending.isNotEmpty) {
        _log('walk: roster has no self position '
            '(self=${me == null ? 'unmatched' : 'no-coords'}) — '
            '${_pending.length} steps unconfirmed, not reconciling');
      }
      return;
    }

    final x = rx.round();
    final y = ry.round();
    if (_x == null) {
      _adopt(x, y);
      return;
    }

    // The most recent time we claimed this tile, not the first: a walk that doubled
    // back is on its second visit, and believing the first would throw away steps that
    // have not landed yet.
    final seen = _pending.lastIndexWhere((p) => p.x == x && p.y == y);
    if (seen >= 0) {
      _pending.removeRange(0, seen + 1);
      // A step we claimed is now confirmed by the server: the moves are flowing
      // again. If a buffer overflow had raised doubt, tell the collector so a
      // walk-triggered recovery that took is not left to time out into a reconnect.
      if (_doubtRaised) {
        _doubtRaised = false;
        _onMovesConfirmed?.call();
      }
      return;
    }
    // Gather put us on a tile we never claimed — a dropped step, a refused move, or
    // the desktop moving the same avatar. This is the snap-back, and when it happens
    // with steps in flight it is the signature of the desk-desync: the server never
    // took the walk the phone thought it was taking.
    if (_pending.isNotEmpty) {
      _log('walk: server says ($x,$y), we believed (${_x!},${_y!}) '
          'with ${_pending.length} steps in flight — snapping back');
    }
    _adopt(x, y);
  }

  void _adopt(int x, int y) {
    _x = x;
    _y = y;
    _pending.clear();
    // A snap-back is not a confirmation of our moves, but it does start the buffer
    // over, so any outstanding doubt no longer refers to steps that still exist.
    // Drop the latch silently; a walk-triggered recovery then escalates on its own
    // grace, which is the right answer when the server put us somewhere we never
    // walked.
    _doubtRaised = false;
  }
}
