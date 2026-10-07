import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

// For `kDoubleTapTimeout` and `kDoubleTapSlop`: this file counts the double tap
// itself, and borrowing Flutter's own figures is what keeps it feeling like every
// other double tap on the phone. See [_PlanState._onTap].
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gather_client/gather_client.dart';

import '../src/app_state.dart';
import '../src/art_cache.dart';
import '../src/map_motion.dart';
import '../src/map_person.dart';
import '../theme/gather_theme.dart';
import 'call_screen.dart';
import 'dpad.dart';

/// The office, drawn — with Gather's own artwork.
///
/// This exists because the map turned out to be free. Gather never serves it over
/// REST, but every state dump carries it in full — rooms, furniture and the
/// collision shapes behind them — and this client used to discard all of it.
///
/// It used to stop there, at blocks of colour, on the reasoning that 124 tiles
/// across a phone is three pixels a tile and anything more detailed is a smudge.
/// That was right about the zoomed-out view and wrong about the screen: the map is
/// pannable, and once you are close enough to read a room name you are close enough
/// to want the desks in it. So the schematic is still here, underneath, and the real
/// art is drawn over it as it arrives.
///
/// **The art is fetched, not bundled.** Gather ships no tileset: the client resolves
/// one image per floor texture, wall piece and furniture variant, and so does
/// [SpaceArt]. On the space this was built against that is 573 images totalling
/// 222 KB, which is why "draw all of it" is a reasonable thing to do on a phone. See
/// `art_cache.dart` for the fetching and `space_art.dart` for where the URLs come
/// from.
class MapScreen extends StatefulWidget {
  const MapScreen({super.key, required this.state});

  final AppState state;

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  /// Owned by the screen rather than by [AppState]: it is decoded images, which is a
  /// rendering concern, and the disk half of it makes coming back cheap anyway.
  final _cache = ArtCache();

  SpaceArt? _art;

  @override
  void dispose() {
    _cache.dispose();
    super.dispose();
  }

  /// Ask for whatever this floor needs, once per distinct floor plan.
  ///
  /// The parent rebuilds this widget on every position tick, so the identity check
  /// matters: [SpaceArt] is rebuilt only when a map patch lands, which makes it a
  /// good proxy for "somebody moved the furniture".
  void _wantArt(SpaceArt? art) {
    if (identical(art, _art)) return;
    _art = art;
    // Asked for as the office's whole request rather than as more URLs, so that a
    // set built mid-dump — before the `CatalogItem` rows that put a `?t=` on every
    // furniture URL had landed — stops being fetched the moment the real one
    // arrives. See [ArtRequest].
    if (art != null) _cache.prefetch(art.urls, group: ArtRequest.office);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final map = widget.state.map;
    _wantArt(widget.state.art);

    // Everybody in the room, me included: "here" is a count of the office, and the
    // reader is standing in it. `peopleOnMap` deliberately excludes me, because
    // every other screen is asking about other people.
    final present = widget.state.peopleOnMap.length + (widget.state.mePerson == null ? 0 : 1);

    return Scaffold(
      backgroundColor: t.background,
      // Where the space name and the head count live: the map is the screen, and a
      // strip above it repeating what it already shows was costing the map a fifth
      // of a phone.
      //
      // In Gameboy mode the whole bar stands down: the handheld draws its own pixel
      // status strip inside the LCD (space name on the shell header, and a
      // status/mic/cam/followers/head-count HUD on the screen — see
      // `gameboy_shell.dart`), so an app-themed bar here would both double the head
      // count and waste a strip of the LCD. The follower count rides into that HUD
      // too, so the "someone is following you" signal survives the skin.
      appBar: widget.state.gameboyMode
          ? null
          : AppBar(
        backgroundColor: t.background,
        // Default title spacing, like the other two tabs: the three app bars sit
        // in one shell, and a title that shifts sideways as you change tab reads
        // as a layout bug rather than a choice.
        title: _Where(space: widget.state.spaceName),
        actions: [
          // The follower count leads and the head count anchors the corner, so
          // the pill that is always there never moves when the other arrives.
          if (widget.state.followers.isNotEmpty) ...[_Followers(count: widget.state.followers.length), const SizedBox(width: 8)],
          if (map != null) _HeadCount(present: present),
          const SizedBox(width: kGutter),
        ],
      ),
      // Deliberately not wrapped in SafeArea: the floor runs under the home
      // indicator, which is what "fullscreen" has to mean for something you pan.
      body: Stack(
        children: [
          Positioned.fill(
            child: map == null ? _Waiting(connected: widget.state.link.isLive) : _Plan(state: widget.state, map: map, art: _art, cache: _cache),
          ),
          // Over the floor rather than taking a strip off the top of it, the way the
          // dock floats over the bottom: a call starting must not rescale the office
          // under somebody's thumb.
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 240),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              transitionBuilder: (child, animation) => FadeTransition(
                opacity: animation,
                child: SlideTransition(
                  position: Tween(begin: const Offset(0, -0.25), end: Offset.zero).animate(animation),
                  child: child,
                ),
              ),
              // A call to get back to wins the slot; otherwise a dropped connection
              // claims it, because a reconnect is the one thing the office cannot
              // show on its own — the floor looks the same whether the roster is
              // live or an hour stale.
              child: widget.state.inCall
                  ? CallBanner(key: const ValueKey('call'), state: widget.state)
                  : widget.state.link.isDisrupted
                      ? _LinkBanner(key: const ValueKey('link'), offline: widget.state.link.isOffline)
                      : const SizedBox.shrink(),
            ),
          ),
        ],
      ),
    );
  }
}

/// The space's name, in the app bar.
///
/// It used to carry a second line underneath — the named area you were standing
/// in, falling back to the floor's size in tiles. Both are gone. The area name
/// changed as you walked, which put a line of type that flickers directly under
/// the one that does not, and neither answer was worth the movement: the map
/// already draws the zone names on the floor, and nobody opens the office to find
/// out how many tiles it is.
class _Where extends StatelessWidget {
  const _Where({required this.space});

  /// The space's own name, from Gather.
  final String? space;

  @override
  Widget build(BuildContext context) {
    // `titleLarge`, written out the way the other two tabs write it. This was
    // 17pt for a while — and then styleless, trusting the app bar's default to
    // be the same style, which it visibly was not — and the title shrank every
    // time you arrived on the office. Explicit is what the sibling bars do, so
    // explicit is what matches them.
    return Text(space ?? 'The office', maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.titleLarge);
  }
}

/// Shown over the floor when the connection to Gather is not carrying the roster.
///
/// Two shapes in one slot. A reconnect — a network that exists, a socket coming back —
/// gets a spinner, because something is actually happening. Being [offline] — flight
/// mode, a dead zone, no radio at all — gets a static cloud-off glyph instead: a spinner
/// there would promise progress nothing can make. Either way it lives in the same slot
/// the call banner does and is mutually exclusive with it, so it never stacks, and is
/// tinted danger because it is the state where what the map draws is not what is true —
/// the roster is frozen, proximity is stale, and a call will not start until it clears.
/// A [liveRegion] so a screen reader says it rather than leaving a blind user wondering
/// why nobody is answering.
class _LinkBanner extends StatelessWidget {
  const _LinkBanner({super.key, required this.offline});

  final bool offline;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final tint = t.danger;
    // Solid, not a tint: this is the one state where the map is lying, so the banner has
    // to read against a busy floor plan behind it — a near-transparent pill vanished
    // into it. White on danger, with a drop shadow to lift it off the map.
    const ink = Colors.white;
    final label = offline ? 'No connection' : 'Reconnecting…';
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Center(
        child: Semantics(
          liveRegion: true,
          label: offline ? 'No connection to Gather' : 'Reconnecting to Gather',
          child: ExcludeSemantics(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
              decoration: BoxDecoration(
                color: tint,
                borderRadius: BorderRadius.circular(t.radius),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.28),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: offline
                        ? const Icon(Icons.cloud_off_rounded, size: 14, color: ink)
                        : const CircularProgressIndicator(strokeWidth: 2, color: ink),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    label,
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: ink),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Who is following you, as the head count's sibling: the same pill, tinted the
/// accent instead of neutral, saying only the number.
///
/// This was a card at the top of the activity tab — the app's one saturated
/// surface — but a card of live presence pinned over a history was stale a
/// minute later and in the way of what that screen is for. The office is the
/// live screen, so the live answer lives here now. Absent rather than reading
/// "0": zero followers is the permanent normal state, and a pill saying so all
/// day is furniture.
class _Followers extends StatelessWidget {
  const _Followers({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    // The link strip's tint recipe on the head count's geometry, with the
    // lighter step of the accent so the number stays readable on dark.
    final tint = t.brandSoft;
    return Semantics(
      label: count == 1 ? 'One person is following you' : '$count people are following you',
      // The outer label is the sentence; without this a screen reader would
      // append the bare number to it.
      child: ExcludeSemantics(
        child: Tooltip(
          message: 'Following you',
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: tint.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(t.radius),
              border: Border.all(color: tint.withValues(alpha: 0.3)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(color: tint, shape: BoxShape.circle),
                ),
                const SizedBox(width: 6),
                Text(
                  '$count',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: tint),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The head count, as a pill rather than a word: it changes while you watch it.
class _HeadCount extends StatelessWidget {
  const _HeadCount({required this.present});

  final int present;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: t.muted,
        borderRadius: BorderRadius.circular(t.radius),
        border: Border.all(color: t.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: present > 0 ? t.ok : t.faint, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(
            '$present here',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: present > 0 ? t.foreground : t.mutedForeground),
          ),
        ],
      ),
    );
  }
}

class _Waiting extends StatelessWidget {
  const _Waiting({required this.connected});

  final bool connected;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.map_outlined, size: 30, color: t.faint),
            const SizedBox(height: 12),
            Text(
              connected ? 'Reading the floor plan' : 'Not connected',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: t.mutedForeground),
            ),
            const SizedBox(height: 6),
            Text(
              connected
                  // True rather than reassuring: the map is ~1700 rows inside a dump
                  // of about 5000, so it lands a moment after the roster does.
                  ? 'Gather sends the map with everything else, so it arrives a '
                        'moment after the people do.'
                  : 'The map comes from Gather, so this needs the connection back.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12.5, height: 1.5, color: t.faint),
            ),
          ],
        ),
      ),
    );
  }
}

/// The transform that puts [at] — a point in the child's own pixels — as near the
/// middle of the viewport as the edges of the map allow.
///
/// `M = T(centre − zoom·point) · S(zoom)` is the standard zoom-about-a-point, and
/// the clamp after it is the rule that there is never anything on screen that is not
/// map. The child is laid out to *cover* the viewport at `zoom == 1`, so
/// `viewport − child·zoom` is zero or negative and the range is always real; the
/// `math.min` only guards a degenerate size.
///
/// This is a function rather than a method because [InteractiveViewer] enforces the
/// same rule for drags and pinches (`boundaryMargin: EdgeInsets.zero`) and cannot
/// enforce it for a transform set from outside — which is every transform this
/// screen sets itself.
@visibleForTesting
Matrix4 framedOn({required Offset at, required Size viewport, required Size child, required double zoom}) {
  final scale = zoom.clamp(kMinZoom, kMaxZoom);
  final dx = (viewport.width / 2 - scale * at.dx).clamp(math.min(0.0, viewport.width - child.width * scale), 0.0).toDouble();
  final dy = (viewport.height / 2 - scale * at.dy).clamp(math.min(0.0, viewport.height - child.height * scale), 0.0).toDouble();
  return Matrix4.identity()
    ..translateByDouble(dx, dy, 0, 1)
    ..scaleByDouble(scale, scale, scale, 1);
}

/// Zoomed all the way out the map covers the screen exactly, so there is no zoom
/// below 1 that would not show something which is not office.
const double kMinZoom = 1;

/// A shade past one Gather pixel per screen pixel on a 3x display, and the point
/// where the art stops rewarding a closer look.
const double kMaxZoom = 20;

class _Plan extends StatefulWidget {
  const _Plan({required this.state, required this.map, required this.art, required this.cache});

  final AppState state;
  final SpaceMap map;
  final SpaceArt? art;
  final ArtCache cache;

  @override
  State<_Plan> createState() => _PlanState();
}

class _PlanState extends State<_Plan> with TickerProviderStateMixin {
  /// Held rather than left to [InteractiveViewer] so a double tap can drive it and
  /// so "fit the floor again" is a thing the screen can offer.
  final _view = TransformationController();

  /// The walk. Owned here because it owns a [Ticker] and needs this screen's vsync;
  /// the painter listens to it rather than the widget tree rebuilding for footsteps.
  late final MapMotion _motion = MapMotion(vsync: this);

  late final AnimationController _zoom = AnimationController(vsync: this, duration: const Duration(milliseconds: 220));
  Animation<Matrix4>? _zoomTo;

  /// Where the last double tap landed, in the viewer's own coordinates.
  Offset _tapped = Offset.zero;

  /// The tile a tap picked out, and the room it stands for when it stands for one.
  ///
  /// Held here rather than on [AppState] because it is not presence: nothing outside
  /// this screen has any use for it, and it should not survive the screen. `setState`
  /// rather than the painter's own [Listenable] — the map repaints off `Listenable`s
  /// so that a footstep never rebuilds the tree, and this is not a footstep: the pill
  /// appears and disappears with it, which is a rebuild by definition.
  ({int x, int y, SpaceRoom? room})? _selected;

  /// Which tile a point on the glass is over, or null when it is off the floor.
  ///
  /// The same inverse the double tap takes, one step further: [_onDoubleTap] wants the
  /// point in the child's pixels and this wants the tile under it.
  ({int x, int y})? _tileAt(Offset point, double base) {
    final inverse = Matrix4.tryInvert(_view.value);
    if (inverse == null) return null;
    final mapPx = MatrixUtils.transformPoint(inverse, point) / base;
    final x = (mapPx.dx / artTileSize).floor();
    final y = (mapPx.dy / artTileSize).floor();
    final map = widget.map;
    if (x < 0 || y < 0 || x >= map.width || y >= map.height) return null;
    return (x: x, y: y);
  }

  /// Where the first tap of a possible pair landed, and the window it has to close in.
  ///
  /// Only ever set between the two halves of a double tap.
  Offset? _firstTap;
  Timer? _tapWindow;

  /// A one-line "why nothing happened" shown in the Go-here pill's slot, and the timer
  /// that clears it. Set when a destination tap is refused because we are offline — it
  /// sits where the pill would have been rather than over the bottom controls.
  String? _blockedNote;
  Timer? _blockedNoteTimer;

  /// What was selected before the tap that is currently provisional.
  ///
  /// A double tap is a zoom, not a selection, so the second half of one has to undo
  /// what the first half did rather than leaving a reticle on whatever the pinch
  /// happened to centre on.
  ({int x, int y, SpaceRoom? room})? _beforeTap;

  /// A tap picks somewhere to go, or picks nothing.
  ///
  /// The desktop client does this on *hover*, which is a thing a phone does not have,
  /// and moves on the double click. Splitting it into a tap and a button is the touch
  /// version of the same two beats: the reticle says what you are pointing at before
  /// anything happens to your avatar.
  ///
  /// ## Why the double tap is counted here
  ///
  /// Flutter's arena cannot give both an instant single tap and a double tap on the
  /// same detector, because deciding that a tap was *single* means waiting to see
  /// whether a second one arrives. The way out is that the two gestures here do not
  /// actually conflict: selecting is free, instant and reversible, so the first tap
  /// can simply do it and the second can take it back on its way to zooming. That is
  /// not true of the desktop client, where the double click *moves you* and guessing
  /// wrong would walk somebody across the office — which is exactly why it waits and
  /// this does not.
  void _onTap(Offset point, double base, Size viewport, Size child) {
    final second = _firstTap;
    _tapWindow?.cancel();
    _firstTap = null;
    if (second != null && (point - second).distance <= kDoubleTapSlop) {
      _tapped = point;
      // Put back whatever the first of the pair displaced. Usually null, and either
      // way not the tile somebody was aiming a pinch at.
      setState(() => _selected = _beforeTap);
      _onDoubleTap(viewport, child);
      return;
    }
    // A [Timer] rather than a clock, so a widget test that pumps past the window
    // actually closes it — `tester.pump` moves fake time and leaves `DateTime.now`
    // exactly where it was.
    _firstTap = point;
    _tapWindow = Timer(kDoubleTapTimeout, () => _firstTap = null);
    _beforeTap = _selected;

    final map = widget.map;
    final at = _tileAt(point, base);
    if (at == null) {
      setState(() => _selected = null);
      return;
    }

    final target = _target(map, at, base);
    if (target == null) {
      // A tap on a desk, a wall, or the void outside the office. Not an error and not
      // worth a sentence — you tapped some furniture.
      setState(() => _selected = null);
      return;
    }
    // A shut door is worth a sentence, because it is the one refusal here that is
    // about somebody else rather than about the floor. Gather refuses this too, in
    // the same place — `onLeftDoubleClick` publishes `AttemptToMoveToLockedArea` when
    // `area.isLocked && !area.canBeEnteredBy(me)` and opens a modal offering to ask
    // for access.
    //
    // The test is `canEnter` and not `room.locked`, and the difference is a bug this
    // used to have: your own locked desk is yours to walk into, and so is the room
    // you are already standing in. The server enforces the same rule from the other
    // side — see `AppState.notices` — which is what covers the two clauses of
    // `canBeEnteredBy` this app cannot evaluate.
    final room = target.room;
    if (room != null && !widget.state.canEnter(room)) {
      setState(() => _selected = null);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text('${room.name ?? 'That room'} is locked.'),
        ));
      return;
    }
    if (target.x == widget.state.myTile?.x && target.y == widget.state.myTile?.y &&
        target.room == null) {
      setState(() => _selected = null);
      return;
    }

    // A real destination, but we are offline or mid-reconnect, so there is no route to
    // lay and the Go-here pill never appears. Rather than swallow the tap in silence,
    // say why nothing happened — this is the one tap where the floor would otherwise
    // have moved you.
    if (widget.state.link.isDisrupted) {
      final note = widget.state.link.isOffline
          ? "Can't move — no connection."
          : "Can't move — reconnecting…";
      _blockedNoteTimer?.cancel();
      _blockedNoteTimer = Timer(const Duration(seconds: 3), () {
        if (mounted) setState(() => _blockedNote = null);
      });
      setState(() {
        _selected = null;
        _blockedNote = note;
      });
      return;
    }

    HapticFeedback.selectionClick();
    setState(() => _selected = target);
  }

  /// What a tap on [at] actually means, or null when it means nothing.
  ///
  /// `shouldNavigateToTile` decides the first half: the main floor, the lobby and a
  /// team's corner are places you point at a *tile* in, and a meeting room, a desk or a
  /// coworking area is a place you point at as a whole. `isSelectableViaMap` is why a
  /// `Public` area never becomes a room target however large it is.
  ({int x, int y, SpaceRoom? room})? _target(
    SpaceMap map,
    ({int x, int y}) at,
    double base,
  ) {
    final area = map.areaAt(at.x, at.y);
    if (area != null && !navigatesToTile(area) && area.name != null) {
      return (x: at.x, y: at.y, room: area);
    }
    final tile = _walkableNear(map, at, base);
    return tile == null ? null : (x: tile.x, y: tile.y, room: null);
  }

  /// The tile that was aimed at, which at a distance is not the one that was hit.
  ///
  /// Zoomed all the way out a tile is about three logical pixels on a 124-tile floor,
  /// so the raw answer is noise. The search widens with the zoom on the same reasoning
  /// the labels use — what matters is the size of the thing on the *glass*, not on the
  /// map — and collapses to nothing once a tile is bigger than a fingertip.
  ({int x, int y})? _walkableNear(SpaceMap map, ({int x, int y}) at, double base) {
    if (map.isWalkable(at.x, at.y)) return at;
    // Gather's own floor, not a zoom-derived one. `getNearestFreeTile` searches a box
    // of 2 by default and `startPathMoveOnCurrentFloor` widens it to 4 — a chair in
    // the middle of a desk cluster is more than one tile from open floor, and a
    // one-ring search zoomed in was refusing to select most of the furniture in the
    // office. The zoom only ever widens this; it may not narrow it.
    final onGlass = artTileSize * base * _view.value.getMaxScaleOnAxis();
    final radius = (_thumb / onGlass).ceil().clamp(_minSnap, _maxSnap);
    return map.nearestFree(at.x, at.y, radius: radius);
  }

  /// Set off, or call off the walk that is already running.
  ///
  /// The selection is dropped the moment it is acted on: the reticle is a thing you
  /// are pointing at, not a thing you have. Leaving it up through a fourteen-second
  /// walk would leave a bracket sitting on a tile the avatar is already halfway to.
  Future<String?> _go() async {
    final state = widget.state;
    if (state.onRoute) {
      state.stopWalking();
      return null;
    }
    final target = _selected;
    if (target == null) return null;

    setState(() => _selected = null);
    final room = target.room;
    return room == null
        ? state.goTo(target.x, target.y)
        : state.goToRoom(room, toward: (x: target.x, y: target.y));
  }

  /// Roughly a fingertip, in logical pixels. Half of the 44pt Apple asks for, because
  /// this is a radius and that is a diameter.
  static const _thumb = 22.0;

  /// `getNearestFreeTile`'s own default box. However far *in* the map is zoomed, a
  /// tap on a desk still means the floor beside it.
  static const _minSnap = 2;

  /// `startPathMoveOnCurrentFloor`'s widened box, and the ceiling here too: however
  /// far out the map is, a tap does not mean a tile in the next room.
  static const _maxSnap = 4;

  @override
  void initState() {
    super.initState();
    _zoom.addListener(() {
      final to = _zoomTo;
      if (to != null) _view.value = to.value;
    });
    // A refusal from Gather arrives with no control waiting on it — see
    // [AppState.notices]. Heard here because this is the screen walking happens on,
    // and because a sentence about a door needs somewhere to be shown.
    _notices = widget.state.notices.listen((notice) {
      if (!mounted) return;
      setState(() => _selected = null);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(notice)));
    });
    _followRequests = widget.state.followMe.listen((_) {
      // Claimed, so the latch below does not ride the same walk a second time
      // when this screen is rebuilt.
      widget.state.takeFollowRequest();
      _startFollowing();
    });
    // A desk walk asked for while this screen did not exist — from the call
    // screen, whose dock carries the same button, or from another tab. Deferred
    // one frame because following needs a layout that has not happened yet:
    // [_followFrame] gives up on an empty child, so starting it here would start
    // and immediately stop.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.state.takeFollowRequest()) _startFollowing();
    });
  }

  // ---- riding along ----------------------------------------------------------

  StreamSubscription<void>? _followRequests;

  /// Keeps the camera on my own avatar for the length of a walk — see
  /// [AppState.followMe] for which walks ask for it.
  ///
  /// Its own ticker rather than a listener on [MapMotion]: the motion clock stops
  /// the moment nobody is moving, which would strand the camera partway through
  /// catching up with somebody who has already sat down.
  late final _follow = createTicker(_followFrame);
  Duration _followLast = Duration.zero;
  double _followZoom = _openingZoom;

  /// The last layout, for a ticker that runs between builds.
  Size _viewport = Size.zero;
  Size _child = Size.zero;
  double _base = 1;

  /// How much of the bottom of the floor is under the dock, so "centred on me"
  /// means the middle of the office you can see and not the middle of the glass.
  double _covered = 0;

  void _startFollowing() {
    if (!mounted) return;
    _zoom.stop();
    // Close enough to see yourself walking. Somebody already zoomed further in
    // keeps their zoom; somebody looking at the whole floor is brought in to
    // where a walk is something you can watch.
    _followZoom = math.max(_view.value.getMaxScaleOnAxis(), _openingZoom);
    _followLast = Duration.zero;
    _follow
      ..stop()
      ..start();
  }

  void _stopFollowing() {
    if (_follow.isActive) _follow.stop();
  }

  /// Eases the view towards me, and lets go once I have arrived and it has caught up.
  ///
  /// Eased rather than pinned: the avatar is usually off screen when the desk button
  /// is pressed, and snapping the view to it would be a cut, not a camera. The
  /// easing is exponential in real time, so a dropped frame does not change where
  /// the view ends up — only how many frames it takes to get there.
  void _followFrame(Duration elapsed) {
    final me = widget.state.mePerson;
    if (me == null || _child.isEmpty) return _stopFollowing();
    final now = _motion.now;
    final at = _motion.positionOf(me, now);
    final target = framedOn(
      at: Offset((at.dx + 0.5) * artTileSize * _base, (at.dy + 0.5) * artTileSize * _base + _covered / 2 / _followZoom),
      viewport: _viewport,
      child: _child,
      zoom: _followZoom,
    );

    final dt = (elapsed - _followLast).inMicroseconds / Duration.microsecondsPerSecond;
    _followLast = elapsed;
    final k = 1 - math.exp(-dt / 0.12);

    // Scale and translation eased separately. Both ends satisfy [framedOn]'s clamp,
    // and that clamp is linear in the scale, so every point between them does too.
    final from = _view.value;
    final fromScale = from.getMaxScaleOnAxis();
    final toScale = target.getMaxScaleOnAxis();
    final fromT = from.getTranslation();
    final toT = target.getTranslation();
    final scale = fromScale + (toScale - fromScale) * k;
    final dx = fromT.x + (toT.x - fromT.x) * k;
    final dy = fromT.y + (toT.y - fromT.y) * k;
    _view.value = Matrix4.identity()
      ..translateByDouble(dx, dy, 0, 1)
      ..scaleByDouble(scale, scale, scale, 1);

    // Not in the first moments: the request lands before the roster has moved me,
    // and a walk that has not started looks exactly like one that has finished.
    if (elapsed < const Duration(milliseconds: 600)) return;
    final arrived = !widget.state.onRoute && !_motion.walking(me, now);
    final caughtUp = (toT.x - dx).abs() < 0.5 && (toT.y - dy).abs() < 0.5 && (toScale - scale).abs() < 0.005;
    if (arrived && caughtUp) _stopFollowing();
  }

  StreamSubscription<String>? _notices;

  @override
  void dispose() {
    unawaited(_notices?.cancel());
    unawaited(_followRequests?.cancel());
    _follow.dispose();
    _tapWindow?.cancel();
    _blockedNoteTimer?.cancel();
    _motion.dispose();
    _zoom.dispose();
    _view.dispose();
    super.dispose();
  }

  /// Whether the opening shot has been framed yet.
  bool _placed = false;

  /// Open on yourself, close enough to see who is around you.
  ///
  /// The whole floor is 124 tiles across; arriving at that and hunting for your own
  /// body is the wrong first second. This waits for a position — it is scheduled
  /// after the frame that has one, and only fires once — and leaves the map alone
  /// from then on, because after that the viewer belongs to whoever is dragging it.
  void _centreOnMe(Size viewport, Size child, double base, List<MapPerson> people) {
    if (_placed) return;
    final me = people.where((p) => p.isMe).firstOrNull;
    if (me == null) return;
    _placed = true;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _view.value = framedOn(at: Offset((me.x + 0.5) * artTileSize * base, (me.y + 0.5) * artTileSize * base), viewport: viewport, child: child, zoom: _openingZoom);
    });
  }

  /// Close enough that a desk is a desk, far enough to see the room it is in.
  static const _openingZoom = 3.0;

  /// Double tap zooms in on what was tapped, or back out again if already close.
  ///
  /// Pinch is [InteractiveViewer]'s own and needs nothing from us; this is the
  /// one-handed version of it, which on a map you are holding in one hand while
  /// walking to a meeting is the one that gets used. It is also the only one of the
  /// two the iOS Simulator can do without holding a modifier key down.
  void _onDoubleTap(Size viewport, Size child) {
    _stopFollowing();
    final current = _view.value.getMaxScaleOnAxis();
    final target = framedOn(
      // The tap is in viewport coordinates; the point under it is wherever the
      // current transform says it is.
      at: MatrixUtils.transformPoint(Matrix4.tryInvert(_view.value) ?? Matrix4.identity(), _tapped),
      viewport: viewport,
      child: child,
      zoom: current > 2.5 ? 1 : 4,
    );
    _zoomTo = Matrix4Tween(begin: _view.value, end: target).animate(CurvedAnimation(parent: _zoom, curve: Curves.easeOutCubic));
    _zoom.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final map = widget.map;
    final art = widget.art;
    final cache = widget.cache;
    final t = context.tokens;
    final people = [...state.peopleOnMap, ?state.mePerson];

    // Avatars are fetched exactly like the furniture is, through the same cache, so
    // asking for them is a set difference on every build and a no-op once they land.
    // Their own request, so that superseding the office's does not disturb them and
    // somebody walking off the floor stops being fetched.
    // The kart rides along in the same request, and only once somebody is actually in
    // one: it is a single 512×32 sheet shared by the whole office, so fetching it is
    // cheap, but fetching it in a space where nobody ever drives is a request for
    // nothing. Once landed it stays, and the second kart of the session is instant.
    // The ghost rides along the same way, once somebody without an outfit is on the
    // floor: it comes out of the app bundle rather than the network, so asking for
    // it costs a decode and nothing else.
    cache.prefetch([
      for (final person in people) ?person.avatarUrl,
      if (people.any((person) => person.avatarUrl == null)) ghostAvatarUrl,
      if (people.any((person) => person.gait == Gait.driving)) goKartUrl,
    ], group: ArtRequest.avatars);

    // Somebody who has asked the system to stop moving things gets the tiles the
    // wire reports, with no walk between them — which is what the desktop client
    // does with the same preference, rather than a degraded version of it.
    _motion.enabled = !MediaQuery.disableAnimationsOf(context);
    // Before the roster, not after: a hop we fired ourselves is the better answer for
    // the next few hundred milliseconds, and it has to be in place before the tiles
    // that follow it are applied. Replaying is not a risk — the hop carries a
    // sequence number and `noteTeleport` ignores one it has already drawn.
    _motion.noteTeleport(state.lastTeleport);
    _motion.update(people);
    _covered = MediaQuery.paddingOf(context).bottom;

    return Stack(
      children: [
        Positioned.fill(
          child: LayoutBuilder(
            builder: (context, box) {
              final viewport = box.biggest;
              // Zoomed all the way out the floor *covers* the screen rather than
              // fitting inside it: whichever way it has to overflow, it does, and the
              // other dimension is exact. Letterboxing would waste the dimension a
              // phone has least of, and — with the boundary below — a map smaller than
              // the screen in either direction is a map you can drag the void into.
              final base = math.max(viewport.height / (map.height * artTileSize), viewport.width / (map.width * artTileSize));
              final child = Size(map.width * artTileSize * base, map.height * artTileSize * base);
              _viewport = viewport;
              _child = child;
              _base = base;
              _centreOnMe(viewport, child, base, people);

              // The whole floor at once, pinchable and pannable. A map you cannot get
              // closer to is decoration, so the ceiling is 20x.
              return GestureDetector(
                // Deliberately *only* a tap recognizer. A [GestureDetector] carrying
                // `onDoubleTap` as well holds every single tap until the double-tap
                // window closes, which put a third of a second between the finger and
                // the reticle and read as the map being slow. The double tap is
                // counted by hand in [_onTap] instead — see there for why that is
                // sound rather than a reimplementation of the arena.
                onTapUp: (details) => _onTap(details.localPosition, base, viewport, child),
                child: InteractiveViewer(
                  transformationController: _view,
                  // A finger on the floor takes the camera back.
                  onInteractionStart: (_) => _stopFollowing(),
                  // Sized here, so the viewer must not stretch it back to the
                  // viewport and undo the cover-the-screen decision above.
                  constrained: false,
                  minScale: kMinZoom,
                  maxScale: kMaxZoom,
                  // The child exactly, with no slack: pan stops at the edge of the
                  // office instead of dragging the background in beside it. The
                  // viewer applies this to drags and pinches; [framedOn] applies the
                  // same rule to the transforms this screen sets itself.
                  boundaryMargin: EdgeInsets.zero,
                  child: SizedBox.fromSize(
                    size: child,
                    child: RepaintBoundary(
                      child: CustomPaint(
                        painter: _OfficePainter(
                          map: map,
                          art: art,
                          cache: cache,
                          people: people,
                          partyActive: state.party.active,
                          tokens: t,
                          view: _view,
                          viewport: viewport,
                          motion: _motion,
                          selection: _selected,
                        ),
                        child: const SizedBox.expand(),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        // Floating over the map rather than taking a strip from it, and only while
        // it has something to say.
        Positioned(
          left: kGutter,
          right: kGutter,
          bottom: 12,
          child: SafeArea(
            top: false,
            child: _Legend(cache: cache, art: art),
          ),
        ),
        // Centred across the bottom, so it is the same reach from either hand. High
        // enough off the edge to sit above the home indicator rather than fight it for
        // the same gesture, and above the legend rather than over it.
        if (kShowDPad && state.canWalk)
          Positioned(
            left: 0,
            right: 0,
            bottom: 64,
            child: SafeArea(
              top: false,
              child: Center(
                // The pad is where the shift key actually belongs — driving a held
                // direction is the gesture Gather binds it to — and it needs nothing
                // here to get it: the latch lives on [Walk] and a press reads it.
                child: DPad(onPress: state.walk, onRelease: state.stopWalking),
              ),
            ),
          ),
        // Present only when there is somewhere to go or a walk to call off — a
        // control that cannot do anything is absent, not dimmed.
        //
        // Closer to the dock than the D-pad's 64: the pad needed room underneath it
        // because a thumb rolls around a disc and would have caught the rail, and a
        // pill is tapped once. Sitting just above the island reads as the same
        // control surface rather than as something adrift over the floor.
        if (state.onRoute || (_selected != null && state.canWalk))
          Positioned(
            left: 0,
            right: 0,
            bottom: kGutter,
            child: SafeArea(
              top: false,
              child: Center(
                // The pill sets the height and the kart takes it, square. The two
                // were each sized by their own padding and came out two points
                // apart — the pill's line of text is taller than the kart's glyph —
                // which is exactly the kind of near-miss that reads as a mistake.
                child: IntrinsicHeight(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Up for the whole walk as well as before it. Shift is a
                      // modifier on movement rather than a property of a journey, so
                      // pressing it mid-route takes the kart there and then — see
                      // [Walk.boost].
                      AspectRatio(
                        aspectRatio: 1,
                        child: _Kart(on: state.boost, onChanged: (on) => state.boost = on),
                      ),
                      const SizedBox(width: 8),
                      _GoTo(
                        room: _selected?.room,
                        walking: state.onRoute,
                        onGo: _go,
                        onClear: () => setState(() => _selected = null),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        // The same slot as the Go-here pill, never both at once: offline there is no pill
        // to go here, so a refused destination tap borrows its place to say why — above
        // the dock, not a toast flung over it.
        if (_blockedNote != null)
          Positioned(
            left: 0,
            right: 0,
            bottom: kGutter,
            child: SafeArea(
              top: false,
              child: Center(child: _BlockedNote(text: _blockedNote!)),
            ),
          ),
      ],
    );
  }
}

/// A transient "why that tap did nothing" pill, shown where the Go-here pill sits when a
/// move is refused for being offline. Danger-tinted and shadowed like [_LinkBanner] so
/// the two read as the same voice.
class _BlockedNote extends StatelessWidget {
  const _BlockedNote({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    const ink = Colors.white;
    return Semantics(
      liveRegion: true,
      label: text,
      child: ExcludeSemantics(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          decoration: BoxDecoration(
            color: t.danger,
            borderRadius: BorderRadius.circular(t.radius),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.28),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off_rounded, size: 14, color: ink),
              const SizedBox(width: 8),
              Text(
                text,
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: ink),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Somewhere to go, and the way to call it off again.
///
/// The go-kart, as a phone can reach it.
///
/// On the desktop there are two entirely separate doors to driving and this is the
/// second one. The first — how far away the destination is — needs no control at all
/// and already works: [Walk.follow] takes the kart for anything past 23 tiles, on
/// Gather's own numbers, whether or not this is lit. The other is the shift key held
/// down while the arrow keys walk you, and a phone has no shift key and, with the
/// D-pad shelved, nothing to hold it against.
///
/// So it latches rather than being held. That is the only liberty taken — what it
/// *means* is the desktop's meaning exactly: while it is on you drive, whatever the
/// distance and whichever room you are crossing. It was briefly a ceiling on the
/// automatic gait instead, which sounds like the same thing and is not: the
/// deceleration then took the kart away again after about a fifth of a second, which
/// is a feature that looks broken.
class _Kart extends StatelessWidget {
  const _Kart({required this.on, required this.onChanged});

  final bool on;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Semantics(
      toggled: on,
      button: true,
      label: 'Take the go-kart',
      // The shape belongs to the [Material] and not to a clip inside it. Ink is
      // painted by the nearest Material ancestor, in that Material's own box, so a
      // `ClipRRect` *below* it never sees the splash: the tap ripple spread past the
      // corners and out over the floor. Giving the Material the colour, the radius
      // and a `clipBehavior` puts the ripple inside the button it belongs to.
      child: Material(
        color: on ? t.brand : t.card,
        borderRadius: BorderRadius.circular(t.radius + 4),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () {
            HapticFeedback.selectionClick();
            onChanged(!on);
          },
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Icon(
              Icons.sports_motorsports_rounded,
              size: 18,
              color: on ? t.primaryForeground : t.mutedForeground,
            ),
          ),
        ),
      ),
    );
  }
}

/// One control with two states rather than two controls: while a walk is running the
/// only thing anybody wants from this corner of the screen is to stop it, and the
/// desktop client says the same thing the same way — no confirmation before the walk,
/// a persistent toast with a Cancel on it during.
///
/// The words are Gather's own. `areaActionGotoProperties` labels the button over an
/// area "Go to", and a bare tile is the same verb with nowhere to name.
class _GoTo extends StatefulWidget {
  const _GoTo({
    required this.room,
    required this.walking,
    required this.onGo,
    required this.onClear,
  });

  /// The room being pointed at, or null when the target is a bare tile.
  final SpaceRoom? room;
  final bool walking;
  final Future<String?> Function() onGo;
  final VoidCallback onClear;

  @override
  State<_GoTo> createState() => _GoToState();
}

class _GoToState extends State<_GoTo> {
  /// The control bar's helper, because a tap that silently does nothing is the one
  /// outcome this app does not allow.
  Future<void> _run() async {
    final failed = await widget.onGo();
    if (!mounted || failed == null) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(failed)));
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final walking = widget.walking;
    final name = widget.room?.name;
    final label = walking ? 'Stop' : (name == null ? 'Go here' : 'Go to $name');

    return Material(
      color: Colors.transparent,
      // Concentric with the dock below it, the same way the control bar's own
      // buttons are.
      child: ClipRRect(
        borderRadius: BorderRadius.circular(t.radius + 4),
        child: Container(
          color: walking ? t.card : t.brand,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
                  InkWell(
                    onTap: _run,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            walking ? Icons.close_rounded : Icons.turn_right_rounded,
                            size: 18,
                            color: walking ? t.foreground : t.primaryForeground,
                          ),
                          const SizedBox(width: 8),
                          // A room name can be long and the floor is only so wide.
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 200),
                            child: Text(
                              label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: walking ? t.foreground : t.primaryForeground,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  // Only while there is a selection to drop. Mid-walk the whole pill
                  // is already the way out, and a second dismiss beside it would be
                  // two buttons for one thought.
                  if (!walking) ...[
                    SizedBox(
                      height: 24,
                      child: VerticalDivider(
                        width: 1,
                        thickness: 1,
                        color: t.primaryForeground.withValues(alpha: 0.24),
                      ),
                    ),
                    InkWell(
                      onTap: widget.onClear,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                        child: Semantics(
                          label: 'Clear the selection',
                          child: Icon(
                            Icons.close_rounded,
                            size: 18,
                            color: t.primaryForeground,
                          ),
                        ),
                      ),
                    ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// The key, or the loading line while there is still art in flight.
class _Legend extends StatelessWidget {
  const _Legend({required this.cache, required this.art});

  final ArtCache cache;
  final SpaceArt? art;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return AnimatedBuilder(
      animation: cache,
      builder: (context, _) {
        final art = this.art;
        // Once the art is down there is nothing left worth covering the floor with:
        // the bodies are avatars now, and a key explaining that a person is a person
        // was answering a question the map stopped asking.
        if (art == null || (art.awaiting == 0 && cache.settled)) {
          return const SizedBox.shrink();
        }
        // Two different waits, and saying "drawing" for both of them was the bug
        // this screen was reported for. An office whose catalog rows have not landed
        // has fetched every picture it knows about, so the cache is *settled* and
        // the line used to disappear — leaving a fully drawn, fully furnished-looking
        // office with no furniture in it, and nothing to say it was still arriving.
        final waiting = art.awaiting > 0
            ? 'The furniture is still arriving — ${art.awaiting} '
                  '${art.awaiting == 1 ? 'piece' : 'pieces'}'
            : 'Drawing the office — ${cache.loaded} of ${cache.wanted}';
        // Centred, so it shares an axis with the D-pad above it rather than
        // hanging off one corner while the controls sit in the middle.
        return Align(
          alignment: Alignment.bottomCenter,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: t.card.withValues(alpha: 0.92),
              borderRadius: BorderRadius.circular(t.radius),
              border: Border.all(color: t.border),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(width: 11, height: 11, child: CircularProgressIndicator(strokeWidth: 1.6, color: t.faint)),
                const SizedBox(width: 8),
                Text(waiting, style: TextStyle(fontSize: 11.5, color: t.mutedForeground)),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// The painter, for tests that want to draw without standing up a whole app.
///
/// Worth a seam because what this file does that can go wrong is *painting* — the
/// widgets around it are an app bar and an [InteractiveViewer], and no widget finder
/// can tell a floor drawn over a room from one drawn under it.
@visibleForTesting
CustomPainter officePainter({
  required SpaceMap map,
  required SpaceArt? art,
  required ArtCache cache,
  required List<MapPerson> people,
  required bool partyActive,
  required GatherTokens tokens,
  TransformationController? view,
  Size? viewport,
  MapMotion? motion,
  ({int x, int y, SpaceRoom? room})? selection,
}) => _OfficePainter(map: map, art: art, cache: cache, people: people, partyActive: partyActive, tokens: tokens, view: view, viewport: viewport, motion: motion, selection: selection);

class _OfficePainter extends CustomPainter {
  _OfficePainter({
    required this.map,
    required this.art,
    required this.cache,
    required this.people,
    required this.partyActive,
    required this.tokens,
    this.view,
    this.viewport,
    this.motion,
    this.selection,
  }) : super(repaint: Listenable.merge([cache, ?view, ?motion]));

  final SpaceMap map;
  final SpaceArt? art;
  final ArtCache cache;

  /// Everybody on this floor, me included — the map is the one screen where I am
  /// just another body to draw.
  final List<MapPerson> people;
  final bool partyActive;

  /// The viewer's own transform, read at paint time rather than passed as a number.
  ///
  /// It has to come from here: this painter sits under a [RepaintBoundary], so its
  /// canvas is a fresh recording whose clip is the whole map however far out the
  /// viewer is. `getLocalClipBounds()` therefore always answered "all of it", which
  /// silently disabled both the culling and the labels that depend on the zoom.
  /// Null means "no viewer": the map is drawn whole, at whatever size it is given.
  final TransformationController? view;

  /// What the viewer is showing it through, in logical pixels. Defaults to the
  /// painted size, which is the same thing when there is no viewer.
  final Size? viewport;
  final GatherTokens tokens;

  /// The walk between the tiles the wire reports. Null means "draw them on their
  /// tiles, standing still", which is what a still test render wants.
  final MapMotion? motion;

  /// Where the reticle is, or null when nothing has been tapped.
  final ({int x, int y, SpaceRoom? room})? selection;

  /// Pixels per tile in Gather's own coordinates. Everything in [SpaceArt] is in
  /// these, and the canvas is scaled once to fit them on screen.
  static const _tile = artTileSize;

  @override
  void paint(Canvas canvas, Size size) {
    // Child pixels per map pixel: the canvas scale this painter applies. The viewer
    // then multiplies it by its own zoom to reach the glass.
    final base = size.width / (map.width * _tile);
    final matrix = view?.value ?? Matrix4.identity();
    final zoom = matrix.getMaxScaleOnAxis();

    // What is genuinely on screen, in map pixels. Inside an InteractiveViewer the
    // whole map is laid out and only a slice is visible; at two thousand draws a
    // frame that slice is worth knowing about.
    final inverse = Matrix4.tryInvert(matrix);
    final shown = inverse == null ? Offset.zero & size : MatrixUtils.transformRect(inverse, Offset.zero & (viewport ?? size));
    final visible = Rect.fromLTWH(shown.left / base, shown.top / base, shown.width / base, shown.height / base).inflate(_tile.toDouble() * 2);

    // One clock reading for the whole frame, and one position per body taken from
    // it. Sampling the walk twice inside a single paint would let a body's name plate
    // disagree with its feet by however long the paint took.
    final now = motion?.now ?? Duration.zero;
    final where = {for (final person in people) person.id: motion?.positionOf(person, now) ?? Offset(person.x, person.y)};

    canvas.save();
    canvas.scale(base);

    final paint = Paint()
      // Pixel art: no smoothing, or every 32×32 tile turns to mush at close zoom.
      ..isAntiAlias = false
      ..filterQuality = FilterQuality.none;

    _paintSchematic(canvas);
    final art = this.art;
    if (art != null) _paintGround(canvas, art, paint, visible);
    _paintProps(canvas, art, paint, visible, where, now);
    // Names and room labels last: they are the one thing that must never end up
    // behind a pot plant.
    // Over the floor and the furniture, under the name plates: the reticle marks a
    // place, and a place is a thing people stand in front of.
    _paintSelection(canvas, base * zoom);
    _paintLabels(canvas, visible, base * zoom, where, now);

    canvas.restore();
  }

  /// The floor plan as it was before there were pictures: blocks of colour for the
  /// rooms, one rect per blocked tile for the furniture.
  ///
  /// Still drawn, underneath everything, and not only as a placeholder — it is what
  /// the screen falls back to when the art cannot be fetched at all, and it is
  /// legible at the zoom where the sprites are three pixels wide.
  void _paintSchematic(Canvas canvas) {
    final width = map.width * _tile.toDouble();
    final height = map.height * _tile.toDouble();
    canvas.drawRect(Rect.fromLTWH(0, 0, width, height), Paint()..color = tokens.card);

    final rooms = [...map.rooms.where((r) => r.name != null)]..sort((a, b) => (b.width * b.height).compareTo(a.width * a.height));
    for (final room in rooms) {
      canvas.drawRect(
        Rect.fromLTWH(room.x * _tile.toDouble(), room.y * _tile.toDouble(), room.width * _tile.toDouble(), room.height * _tile.toDouble()),
        Paint()..color = tokens.brand.withValues(alpha: room.walled ? 0.10 : 0.05),
      );
    }

    // Only worth drawing while the floor above it is still missing: over the real
    // art these blocks would be a grey haze on top of the furniture they stand for.
    if (art == null || cache.loaded == 0) {
      final blocked = Path();
      for (var y = 0; y < map.height; y++) {
        for (var x = 0; x < map.width; x++) {
          if (map.isWalkable(x, y)) continue;
          blocked.addRect(Rect.fromLTWH(x * _tile.toDouble(), y * _tile.toDouble(), _tile.toDouble(), _tile.toDouble()));
        }
      }
      canvas.drawPath(blocked, Paint()..color = tokens.border);
    }
  }

  /// Floors and walls, in the order [SpaceArt.ground] hands them over.
  ///
  /// That order is the client's three ground layers — base area, `Public` zones,
  /// then rooms and desks — and it is a lookup rather than a coordinate. Sorting it
  /// by position instead paints the base area, the tallest rectangle on the map,
  /// over every room inside it.
  void _paintGround(Canvas canvas, SpaceArt art, Paint paint, Rect visible) {
    for (final item in art.ground) {
      final image = cache[item.url];
      if (image == null) continue;
      final rect = Rect.fromLTWH(item.left, item.top, item.width, item.height);
      if (!rect.overlaps(visible)) continue;

      switch (item) {
        case ArtFloor():
          // A floor is one 32×32 tile repeated, so it is a shader rather than a
          // loop — the base area alone is 124×82 of them.
          canvas.drawRect(
            rect,
            Paint()
              ..isAntiAlias = false
              ..filterQuality = FilterQuality.none
              ..shader = ui.ImageShader(
                image,
                TileMode.repeated,
                TileMode.repeated,
                (Matrix4.identity()..setTranslationRaw(item.left, item.top, 0)).storage,
                filterQuality: FilterQuality.none,
              ),
          );
        case ArtWall():
          canvas.drawImageRect(image, Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()), rect, paint);
      }
    }
  }

  void _paintProp(Canvas canvas, ArtSprite prop, Paint paint, Rect visible) {
    final image = cache[prop.url];
    if (image == null) return;
    final width = image.width.toDouble();
    final height = image.height.toDouble();
    final rect = Rect.fromLTWH(prop.left, prop.top, width, height);
    if (!rect.overlaps(visible)) return;
    canvas.drawImageRect(image, Rect.fromLTWH(0, 0, width, height), rect, paint);
  }

  /// Furniture and people in one pass, sorted together, then the parts of the
  /// furniture that stand in front of everybody.
  ///
  /// Gather sorts players into the same depth list as the props, which is what puts
  /// somebody *behind* the desk they are sitting at rather than on it. A body's
  /// depth is the line it stands on — the bottom of its tile — the same measure
  /// `updateDepth` uses for a sprite's fold. The near half of an object is a separate
  /// `foregroundRenderable` for exactly this reason, and goes on last.
  void _paintProps(Canvas canvas, SpaceArt? art, Paint paint, Rect visible, Map<String, Offset> where, Duration now) {
    // A body's depth is the line it stands on: the bottom of its own tile — and the
    // tile it is drawn on rather than the one the wire last named, or somebody walking
    // out from behind a desk pops in front of it a quarter of a second early.
    //
    // Somebody mid-teleport is two entries rather than one. The body they left is at a
    // different place on the floor and has to sort by *that* line, or a ghost left
    // behind a desk is drawn standing on it.
    final bodies = <({MapPerson person, Offset at, double alpha, double scale})>[];
    for (final person in people) {
      final flash = motion?.flashOf(person, now);
      bodies.add((person: person, at: where[person.id]!, alpha: flash?.alpha ?? 1, scale: flash?.scale ?? 1));
      if (flash != null) {
        bodies.add((person: person, at: flash.ghostAt, alpha: flash.ghostAlpha, scale: 1));
      }
    }
    bodies.sort((a, b) => a.at.dy.compareTo(b.at.dy));

    // A merge, not a concatenation: `props` is already sorted and the bodies now are
    // too, so this walks both once.
    final props = art?.props ?? const <ArtSprite>[];
    var next = 0;
    void body(int i) => _paintPerson(canvas, bodies[i].person, paint, bodies[i].at, now, alpha: bodies[i].alpha, scale: bodies[i].scale);

    for (final prop in props) {
      if (prop.foreground) continue;
      while (next < bodies.length && (bodies[next].at.dy + 1) * _tile <= prop.depth) {
        body(next);
        next++;
      }
      _paintProp(canvas, prop, paint, visible);
    }
    while (next < bodies.length) {
      body(next);
      next++;
    }

    for (final prop in props) {
      if (prop.foreground) _paintProp(canvas, prop, paint, visible);
    }
  }

  /// Somebody, as their own avatar when we have one and as Gather's ghost when we
  /// do not.
  ///
  /// The sheet is 72 frames of 32×64 in a row and the frame is chosen the way the
  /// client chooses it — `idle-s` is frame 0, `idle-n` 18, `idle-w` 9, `idle-e` 23 —
  /// so people face the way they are actually facing. Sprites hang a tile above
  /// their own tile, which is `defaultAvatarOffsetY = -32` in the client and is what
  /// puts the feet on the floor rather than the head.
  ///
  /// Somebody with no outfit — a guest, typically — is not a special case here. The
  /// client draws them on its default sheet, the grey ghost, and never swaps it out;
  /// this does the same with [ghostAvatarUrl], which is that sheet, so a ghost
  /// faces, walks, sits and dances exactly as a dressed body does. The coloured pin
  /// only remains for the frame or two before the ghost has decoded.
  ///
  /// Nothing is drawn around a body — no ring, no shadow. Gather draws people as
  /// people, and "which one is me" is answered by the name plate above the head
  /// rather than by a halo on the floor.
  /// [alpha] and [scale] are the teleport, and are 1 for everybody standing still.
  /// A body arriving fades and grows into place; the one it left behind dissolves at
  /// full size. See `../src/map_motion.dart`.
  void _paintPerson(Canvas canvas, MapPerson person, Paint paint, Offset at, Duration now, {double alpha = 1, double scale = 1}) {
    final sheet = cache[person.avatarUrl ?? ghostAvatarUrl];

    if (sheet == null) {
      // The fallback, for a sheet that has not landed yet. Not a ring around a body
      // — a stand-in for one.
      final middle = Offset((at.dx + 0.5) * _tile, (at.dy + 0.5) * _tile);
      final colour = person.isMe
          ? tokens.brand
          : person.isFollowingMe
          ? tokens.ok
          : tokens.mutedForeground;
      final radius = _tile * 0.42 * scale;
      canvas.drawCircle(middle, radius + 3, Paint()..color = tokens.background.withValues(alpha: 0.55 * alpha));
      canvas.drawCircle(middle, radius, Paint()..color = colour.withValues(alpha: alpha));
      return;
    }

    final posture = _posture(person, now);
    final frame = avatarAnimation(facing: posture.facing, pose: posture.pose).frameAt(motion?.phaseOf(person, now) ?? Duration.zero);

    // Grown about the feet rather than the middle: a sprite scaled around its centre
    // sinks into the floor on the way in, and the tile somebody stands on is the one
    // thing about a body that must not move.
    final width = avatarFrameWidth * scale;
    final height = avatarFrameHeight * scale;
    final floor = at.dy * _tile + avatarOffsetY + avatarFrameHeight;
    canvas.drawImageRect(
      sheet,
      Rect.fromLTWH((frame * avatarFrameWidth).toDouble(), 0, avatarFrameWidth.toDouble(), avatarFrameHeight.toDouble()),
      Rect.fromLTWH(at.dx * _tile + (avatarFrameWidth - width) / 2, floor - height, width, height),
      // The shared paint carries the pixel-art settings and is reused for everybody
      // at full opacity; a fading body needs its own, since the alpha that fades it
      // is the paint's own colour.
      alpha >= 1
          ? paint
          : (Paint()
              ..isAntiAlias = false
              ..filterQuality = FilterQuality.none
              ..color = const Color(0xFFFFFFFF).withValues(alpha: alpha.clamp(0.0, 1.0))),
    );

    if (person.gait == Gait.driving) {
      _paintKart(canvas, person, posture, paint, at, now, alpha: alpha, scale: scale);
    }
  }

  /// The go-kart, over the body rather than under it.
  ///
  /// `bringToTop(this.vehicleImage)` — a kart is drawn in front of the legs it hides,
  /// which is the whole trick that makes a 32×32 sprite read as something being sat
  /// in. It sits on the body's *own* tile:
  ///
  /// ```js
  /// this.vehicleImage.x = this.avatar.x;
  /// this.vehicleImage.y = this.avatar.y - this.defaultAvatarOffsetY;   // +32
  /// ```
  ///
  /// which is the avatar's origin undone — the sprite hangs a tile high, the kart
  /// does not.
  ///
  /// Nothing is drawn when the sheet has not landed yet. It is one 512×32 image for
  /// the whole office, fetched the first time anybody drives, so the gap is a frame
  /// or two on the first kart of the session and never again — and a missing kart is
  /// a person running, which is what they are.
  void _paintKart(
    Canvas canvas,
    MapPerson person,
    ({Pose pose, Facing facing}) posture,
    Paint paint,
    Offset at,
    Duration now, {
    double alpha = 1,
    double scale = 1,
  }) {
    final sheet = cache[goKartUrl];
    if (sheet == null) return;

    final moving = motion?.walking(person, now) ?? false;
    final frame = goKartAnimation(facing: posture.facing, moving: moving)
        .frameAt(motion?.phaseOf(person, now) ?? Duration.zero);

    // Grown about its own feet, as the body is: the kart's bottom edge is the bottom
    // of the tile, so a kart appearing does not shunt the avatar off the floor.
    final size = goKartFrameSize * scale;
    final floor = at.dy * _tile + avatarOffsetY + avatarFrameHeight;
    canvas.drawImageRect(
      sheet,
      Rect.fromLTWH((frame * goKartFrameSize).toDouble(), 0, goKartFrameSize.toDouble(), goKartFrameSize.toDouble()),
      Rect.fromLTWH(at.dx * _tile + (goKartFrameSize - size) / 2, floor - size, size, size),
      alpha >= 1
          ? paint
          : (Paint()
              ..isAntiAlias = false
              ..filterQuality = FilterQuality.none
              ..color = const Color(0xFFFFFFFF).withValues(alpha: alpha.clamp(0.0, 1.0))),
    );
  }

  /// What somebody is doing and which way they are pointing.
  ///
  /// `updateMoveStateVisuals` asks moving-then-sitting-then-idle, and speaking is
  /// layered over the idles by `handleAnimationEnds`. Sitting is not on the wire —
  /// `playerState` is the client's own and never sent — so it is worked out the way
  /// Gather works it out: you are sitting when you are standing on a chair's
  /// `sittable` tile. The tile asked about is the one the wire named rather than the
  /// one the body is sliding across, or somebody walking over a chair sits down for a
  /// frame on their way past.
  ///
  /// A sitter faces their chair rather than the way they walked in. The client turns
  /// them in `applySittingDirection` and publishes the turn, but it does so as a
  /// patch of its own, arriving separately from the position — so a roster can carry
  /// somebody sat down and still facing the corridor. `seatFacing` is the same answer
  /// without the race; somebody's own direction is the fallback for a chair that
  /// names no orientation.
  ({Pose pose, Facing facing}) _posture(MapPerson person, Duration now) {
    final facing = Facing.of(person.direction);
    if (motion?.walking(person, now) ?? false) {
      // `(getSpeedModifier() > 1 ? "run-" : "walk-")`, and note there is no third
      // cycle: somebody driving runs, and the kart drawn over them is what says so.
      return (pose: person.gait == Gait.walking ? Pose.walking : Pose.running, facing: facing);
    }
    // Below moving and above everything else, which is the client's own order:
    // `updateMoveStateVisuals` asks moving first, and dancing replaces the idle it
    // would otherwise fall through to rather than layering over it the way speaking
    // does. Nobody dances sitting down.
    if (person.dancing) return (pose: Pose.dancing, facing: facing);
    final x = person.x.round();
    final y = person.y.round();
    if (map.isSeat(x, y)) {
      final chair = map.seatFacing(x, y);
      return (pose: person.speaking ? Pose.talkingSitting : Pose.sitting, facing: chair == null ? facing : Facing.of(chair));
    }
    return (pose: person.speaking ? Pose.talking : Pose.standing, facing: facing);
  }

  /// The reticle: four corner brackets around whatever a tap picked out.
  ///
  /// Gather's own shape — `immersive-tile-highlighter-tl.png` and its three mirrors,
  /// drawn on a `TileHighlight` layer of their own — and its own rule about areas:
  /// hovering one snaps the highlighter to the whole bounding box with five pixels of
  /// padding rather than to the tile under the pointer.
  ///
  /// Brackets rather than a filled square because the tile you are pointing at is
  /// usually the interesting one: a chair, a desk, somebody's avatar. A fill would
  /// hide the thing that made you tap there.
  ///
  /// **Deliberately static.** The client's reticle lerps between tiles and fades
  /// itself out after three seconds, and neither is copied: `MapMotion`'s ticker stops
  /// itself when nobody is moving and an office standing still has to cost no frames,
  /// and a selection that faded out from under the button still waiting on it would be
  /// incoherent. Gather's is a hover affordance. This one is a pending action.
  void _paintSelection(Canvas canvas, double onGlass) {
    final selection = this.selection;
    if (selection == null) return;

    // Map pixels per screen pixel — everything below is a size on the *glass*, undone
    // into map space, the same way the labels are laid out.
    final scale = 1 / onGlass;
    final room = selection.room;

    final rect = room == null
        ? Rect.fromLTWH(
            selection.x * _tile.toDouble(),
            selection.y * _tile.toDouble(),
            _tile.toDouble(),
            _tile.toDouble(),
          )
        : Rect.fromLTWH(
            room.x * _tile.toDouble(),
            room.y * _tile.toDouble(),
            room.width * _tile.toDouble(),
            room.height * _tile.toDouble(),
          ).inflate(_areaPadding);

    // **The mark is the tile, at every zoom.** An earlier version held the reticle to
    // a minimum size on the glass, on the theory that a tile zoomed all the way out
    // is too small to carry a bracket. Measured on a real phone it is 8 to 10 points
    // rather than the three that theory assumed — perfectly drawable — and the floor
    // was inflating it to 2.1x the tile on an iPhone 15 and 2.7x on an SE, so the
    // crosshair visibly came unstuck from the square it was marking. Everything below
    // is a proportion of [rect] instead, and the only things pinned to the glass are
    // pinned as *ceilings*.
    final shorter = math.min(rect.width, rect.height);

    // Two points on the glass, unless that is heavy against the tile itself: on an
    // 8-point tile a 2-point line is a quarter of the square.
    final width = math.min(_reticleStroke * scale, shorter / 8);

    // A stroke is centred on its path, so a path laid along the tile's edge puts half
    // its width on the neighbour. Zoomed in that is a pixel nobody notices; zoomed out
    // the stroke is a fifth of the tile and it lands squarely on the square next door.
    final inner = rect.deflate(width / 2);

    // A quarter of the shorter side, so a bracket never grows past the corner it
    // belongs to; at nine points on the glass it stops growing with the zoom. Zoomed
    // right out the four brackets nearly meet and the mark reads as a small square,
    // which is the right thing for it to degrade into.
    final arm = math.min(_reticleArm * scale, math.min(inner.width, inner.height) / 4);

    // Its own Paint: the shared one runs with antialiasing off for the pixel art, and
    // a diagonal-free shape still needs it for the stroke's ends and corners.
    //
    // Black rather than the brand blue. The office's own artwork is saturated and
    // full of blue — the rugs, the sofas, half the desks — and a brand-coloured mark
    // on top of it reads as one more piece of furniture. Black is the one colour
    // Gather's floor never uses, so it reads as an annotation instead of as part of
    // the room. `background` rather than a literal, because colours come from tokens.
    final stroke = Paint()
      ..isAntiAlias = true
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = width
      ..color = tokens.background;

    final path = Path();
    for (final (corner, dx, dy) in [
      (inner.topLeft, 1.0, 1.0),
      (inner.topRight, -1.0, 1.0),
      (inner.bottomRight, -1.0, -1.0),
      (inner.bottomLeft, 1.0, -1.0),
    ]) {
      path
        ..moveTo(corner.dx + dx * arm, corner.dy)
        ..lineTo(corner.dx, corner.dy)
        ..lineTo(corner.dx, corner.dy + dy * arm);
    }

    canvas.drawPath(path, stroke);

    // The floor names the ten team zones and deliberately never names the fourteen
    // meeting rooms, on the grounds that the one you are standing in is already in the
    // app bar. The one you are pointing at is not, and naming it is the whole point of
    // having selected it.
    final name = room?.name;
    if (name != null) {
      // The zone labels' recipe, opaque rather than at 0.62: those are ambient and
      // this one is the thing being pointed at. Matches the brackets, so the name and
      // the mark read as one annotation rather than two.
      final label = _text(name, tokens.foreground);
      _plate(
        canvas,
        Offset(rect.center.dx, rect.top - (_plateHeight(label) / 2 + _zoneGap) * scale),
        label,
        scale,
        fill: tokens.background,
      );
    }
  }

  /// The five pixels the client pads an area's bounding box by, in map pixels.
  static const _areaPadding = 5.0;

  /// Bracket thickness and arm length, in logical pixels on the glass. Ceilings
  /// rather than sizes: a small tile gets a proportionate mark instead of this one.
  static const _reticleStroke = 2.0;
  static const _reticleArm = 9.0;

  /// Team-area names and name plates, laid out on the glass and scaled into the map.
  ///
  /// Everything here is measured in screen pixels at a fixed type size and the canvas
  /// is scaled to put it down on the map, rather than the type being sized in map
  /// pixels against the zoom. That buys two things. A label is exactly the same size
  /// on the glass at every zoom, which is what a label is for; and because the font
  /// size never changes, a name's [TextPainter] is laid out once and kept, instead of
  /// every person on the map being re-laid-out on every frame of a pinch.
  void _paintLabels(Canvas canvas, Rect visible, double onGlass, Map<String, Offset> where, Duration now) {
    // Map pixels per screen pixel — the factor that undoes the zoom.
    final scale = 1 / onGlass;

    // Only the team areas. The floor also names fourteen meeting rooms, three commons
    // and a lobby, and writing all of them across it turned the office into a contents
    // page — the zones people sit in are what you navigate by, and the room you are
    // standing in is already in the app bar. On the measured space this is ten labels
    // instead of twenty-eight.
    //
    // Unlike a name, a zone label is gated on there being room to read it: at 124
    // tiles across a phone "Frontend" is wider than the desks it names.
    if (onGlass * _tile >= _zonesAbove) {
      for (final area in map.rooms) {
        final name = area.name;
        if (name == null || area.type != _sectionType) continue;
        final rect = Rect.fromLTWH(area.x * _tile.toDouble(), area.y * _tile.toDouble(), area.width * _tile.toDouble(), area.height * _tile.toDouble());
        if (!rect.overlaps(visible)) continue;
        // White, and only two-thirds of it: a zone name is a thing you read when you
        // are looking for it, not a thing that should compete with the people.
        final label = _text(name, tokens.primaryForeground.withValues(alpha: 0.66));
        if (_plateWidth(label) * scale > rect.width) continue;
        // Floating above the zone rather than lying on it: a team area is full of the
        // desks it exists to group, and a label inside it covers one of them.
        _plate(canvas, Offset(rect.center.dx, rect.top - (_plateHeight(label) / 2 + _zoneGap) * scale), label, scale, fill: tokens.background.withValues(alpha: 0.62));
      }
    }

    // Names last, and at every zoom. They are drawn after the zones deliberately: a
    // person standing at the top edge of their team area puts the two plates in the
    // same place, and the one naming somebody who is actually there wins.
    for (final person in people) {
      if (person.label.isEmpty) continue;
      final label = _text(person.label, person.isMe ? tokens.primaryForeground : tokens.foreground);
      // Above the head, which is half a tile above the body's own tile: an avatar
      // frame is 64 tall and hung 32 above its tile, and across the sheets sampled the
      // highest hat still starts 14 pixels below that tile's top edge.
      final body = where[person.id] ?? Offset(person.x, person.y);
      final at = Offset((body.dx + 0.5) * _tile, body.dy * _tile - _tile * 0.5 - _plateHeight(label) / 2 * scale);
      if (!visible.contains(at)) continue;
      // A plate arrives with the body it names. Faded through a layer rather than by
      // tinting the text: a colour is part of a [TextPainter]'s cache key, so fading
      // one that way would lay a name out afresh on every frame of the effect.
      final arriving = motion?.flashOf(person, now)?.alpha ?? 1;
      if (arriving < 1) {
        canvas.saveLayer(
          Rect.fromCenter(center: at, width: (_plateWidth(label, dot: true) + 2) * scale, height: (_plateHeight(label) + 2) * scale),
          Paint()..color = const Color(0xFFFFFFFF).withValues(alpha: arriving.clamp(0.0, 1.0)),
        );
      }
      _plate(
        canvas,
        at,
        label,
        scale,
        // Mine in the brand colour, everybody else's on the app's own ground — the
        // same two-tier distinction Gather draws, and the same one the follower cards
        // make, so "which one is me" is answered without a ring around anybody.
        // Opaque, so a plate that lands on a zone label covers it rather than mixing
        // two names into one smudge.
        fill: person.isMe ? tokens.brand : tokens.background,
        dot: availabilityColor(tokens, person.availability),
      );
      if (arriving < 1) canvas.restore();
    }
  }

  /// The `mapAreaType` of the zones people mean when they say where they sit.
  static const _sectionType = 'Team';

  /// Screen pixels per tile below which the zone names come off. Names have no such
  /// floor: "where is everybody" is the question this screen exists to answer, and it
  /// is worth answering from across the office.
  static const _zonesAbove = 9;

  // The plate, in screen pixels. The proportions are Gather's, read off its own.
  static const _size = 11.0;
  static const _padX = _size * 0.62;
  static const _padY = _size * 0.34;
  static const _dotRadius = _size * 0.30;
  static const _dotGap = _size * 0.34;

  /// The gap between a zone's top edge and the bottom of its label.
  static const _zoneGap = _size * 0.5;

  double _plateWidth(TextPainter label, {bool dot = false}) => label.width + _padX * 2 + (dot ? _dotRadius * 2 + _dotGap : 0);

  double _plateHeight(TextPainter label) => label.height + _padY * 2;

  /// Gather's own label: text on a dark lozenge, rounded to a capsule, with an
  /// availability dot in front of it when there is somebody to be available.
  ///
  /// [centre] is the middle of the plate in *map* pixels, so callers position it by
  /// whichever edge they actually care about; [scale] is map pixels per screen pixel,
  /// and everything inside is drawn on the glass.
  void _plate(Canvas canvas, Offset centre, TextPainter label, double scale, {required Color fill, Color? dot}) {
    canvas.save();
    canvas.translate(centre.dx, centre.dy);
    canvas.scale(scale);

    final lead = dot == null ? 0.0 : _dotRadius * 2 + _dotGap;
    final box = Rect.fromCenter(
      center: Offset.zero,
      width: _plateWidth(label, dot: dot != null),
      height: _plateHeight(label),
    );
    canvas.drawRRect(RRect.fromRectAndRadius(box, Radius.circular(box.height / 2)), Paint()..color = fill);
    if (dot != null) {
      canvas.drawCircle(Offset(box.left + _padX + _dotRadius, 0), _dotRadius, Paint()..color = dot);
    }
    label.paint(canvas, Offset(box.left + _padX + lead, -label.height / 2));

    canvas.restore();
  }

  /// Laid-out text, kept between frames.
  ///
  /// A [TextPainter] lays out on construction and the map has ninety-odd rooms and a
  /// hundred people; re-laying all of that out sixty times a second is real work for
  /// a string that has not changed. It only works because the type size is fixed —
  /// while labels were sized in map pixels the key changed on every frame of a pinch
  /// and the cache was a cache of one frame.
  static final Map<String, TextPainter> _labels = {};

  TextPainter _text(String value, Color colour) {
    final key = '$value/${colour.toARGB32()}';
    final cached = _labels[key];
    if (cached != null) return cached;
    // Bounded: a space can churn through names, and this must not become a leak.
    if (_labels.length > 400) _labels.clear();
    final painter = TextPainter(
      text: TextSpan(
        text: value,
        style: TextStyle(fontSize: _size, height: 1.1, color: colour, fontWeight: FontWeight.w600),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout();
    return _labels[key] = painter;
  }

  @override
  bool shouldRepaint(_OfficePainter old) =>
      old.map != map ||
      old.art != art ||
      old.partyActive != partyActive ||
      old.selection != selection ||
      old.people.length != people.length ||
      // Positions change without the count changing, which is most of the time.
      !_samePlaces(old.people, people);

  static bool _samePlaces(List<MapPerson> a, List<MapPerson> b) {
    for (var i = 0; i < a.length; i++) {
      if (a[i].x != b[i].x ||
          a[i].y != b[i].y ||
          a[i].speaking != b[i].speaking ||
          // The dot on the name plate: going busy moves nothing and still changes
          // what the map says about you.
          a[i].availability != b[i].availability) {
        return false;
      }
    }
    return true;
  }
}
