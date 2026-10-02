/// The faces. Everybody the SFU is sending us, plus your own camera.
///
/// ## Why this is a route and not a panel
///
/// Video wants the screen. The map answers "where is everyone", the control bar
/// answers "what am I doing", and neither has room for a person's face at a size
/// worth looking at. Pushing a route also means the renderers exist only while
/// somebody is looking at them, which is the whole ballgame for battery: an
/// `RTCVideoRenderer` that is off-screen still decodes.
///
/// ## The renderer lifecycle is the thing to get right
///
/// `RTCVideoRenderer` is a native texture with a manual lifecycle: `initialize()`
/// before use, `dispose()` after, and `srcObject = null` *before* the stream
/// underneath it goes away. Get the order wrong and you get a black rectangle
/// that never recovers, or a crash in the platform view when a track is stopped
/// while still attached. That is why [_VideoTile] is a `StatefulWidget` holding
/// exactly one renderer, keyed by participant, and why the key matters: a reused
/// element pointed at a different stream would show the last person's frame.
///
/// ## The test seam
///
/// `RTCVideoRenderer.initialize()` needs a `MethodChannel`, which does not exist
/// under `flutter test`. [CallScreen.buildTile] lets a widget test swap the video
/// surface for something inert and assert on layout, naming and the empty states
/// — everything except the pixels, which are the platform's job anyway.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../src/app_state.dart';
import '../src/media/call.dart';
import '../src/media/live_call.dart';
import '../src/media/sfu_session.dart';
import '../src/reactions.dart';
import '../theme/gather_theme.dart';
import 'control_bar.dart';
import 'person_avatar.dart';

/// Opens the faces. One place, because two things open them — the call banner and,
/// while nobody else is in the call, the control bar's own camera button.
///
/// Opening the faces is deliberate engagement, so this is also one of the two
/// doors that tells the OS a call is running — the other being unmuting. Drifting
/// into a conversation and listening does not, which is what keeps the Recents log
/// from filling up as the phone moves.
Future<void> openCallScreen(BuildContext context, AppState state) {
  state.engageCall();
  return Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => CallScreen(state: state)),
  );
}

/// One face to draw, resolved from call state and the roster.
class CallTile {
  const CallTile({
    required this.id,
    required this.label,
    required this.isSelf,
    required this.videoLive,
    required this.muted,
    required this.sharingScreen,
    this.stream,
    this.photoUrl,
    this.availability,
    this.speaking = false,
    this.reactions = const [],
  });

  /// `SpaceUser.id` when we could place them, otherwise the media `srcId`. Only
  /// ever used for the avatar's colour and the widget key, both of which want
  /// stability rather than meaning.
  final String id;
  final String label;
  final bool isSelf;
  final bool videoLive;
  final bool muted;
  final bool sharingScreen;
  final MediaStream? stream;
  final String? photoUrl;
  final String? availability;
  final bool speaking;

  /// Everything this person currently has in the air, oldest first.
  ///
  /// A list rather than one emoji because a reaction is an act and not a status:
  /// three taps are three of them, overlapping. See `../src/reactions.dart`.
  final List<ReactionFlight> reactions;
}

typedef CallTileBuilder = Widget Function(BuildContext context, CallTile tile);

/// The call, at the size it is being drawn.
///
/// Stateful for one reason beyond layout: **somebody has to tell the SFU that
/// anyone is looking.** A peer publishes its smallest simulcast layer until a
/// consumer asks for better, so a face filling a phone screen stays a
/// quarter-resolution thumbnail unless this screen says otherwise — and, more
/// usefully, everybody drops back to that thumbnail the moment this route is
/// popped, because the map draws no video and nothing else here wants the
/// bandwidth. That is `consume-set-spatial`, and it is the receive-side half of
/// the simulcast the publisher already implements.
class CallScreen extends StatefulWidget {
  const CallScreen({super.key, required this.state, this.buildTile});

  final AppState state;

  /// Swapped out under `flutter test`, where there is no platform view to make.
  final CallTileBuilder? buildTile;

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  List<String> _watching = const [];
  VideoQuality _quality = VideoQuality.thumbnail;

  @override
  void initState() {
    super.initState();
    widget.state.addListener(_noteWatching);
    _noteWatching();
  }

  @override
  void dispose() {
    widget.state.removeListener(_noteWatching);
    // Nobody is looking any more. Said on the way out rather than left to a
    // timeout, because until it is said every peer keeps encoding a layer for a
    // screen that has gone — their battery, spent on our behalf.
    unawaited(
      widget.state.callHandle?.setWatching(
            const [],
            quality: VideoQuality.thumbnail,
          ) ??
          Future<void>.value(),
    );
    super.dispose();
  }

  /// Who is on screen and how big, in the same terms [_Grid] lays them out in.
  void _noteWatching() {
    final call = widget.state.call;
    final ids = [for (final person in call.participants) person.srcId];
    // Ourselves included, because the self tile takes a share of the screen
    // without anybody having to send it to us.
    final tiles = ids.length + (call.media.capturing ? 1 : 0);
    final quality = switch (tiles) {
      0 || 1 => VideoQuality.full,
      2 => VideoQuality.half,
      _ => VideoQuality.thumbnail,
    };

    if (quality == _quality &&
        ids.length == _watching.length &&
        Iterable<int>.generate(ids.length).every((i) => ids[i] == _watching[i])) {
      return;
    }
    _watching = ids;
    _quality = quality;
    unawaited(
      widget.state.callHandle?.setWatching(ids, quality: quality) ??
          Future<void>.value(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Scaffold(
      backgroundColor: t.background,
      body: ListenableBuilder(
        // Reactions are merged rather than folded into `AppState`: they come up
        // and go down on their own timer, with no roster and no tap behind
        // either edge, and this is the only screen that draws them.
        listenable: Listenable.merge([widget.state, widget.state.reactions]),
        builder: (context, _) {
          final tiles = _tiles(widget.state);
          return Stack(
            children: [
              SafeArea(
                child: Padding(
                  // Clear of the island below, the way the shell's tabs clear the
                  // rail. The reaction tray is not counted — it is up for a second
                  // and may sit over the bottom of a face while it is.
                  padding: const EdgeInsets.only(bottom: kControlDockInset),
                  child: Column(
                    children: [
                      _Header(
                        state: widget.state,
                        count: tiles.where((tile) => !tile.isSelf).length,
                      ),
                      Expanded(
                        child: tiles.isEmpty
                            ? const _Nobody()
                            : _Grid(
                                tiles: tiles,
                                buildTile: widget.buildTile ?? _defaultTile,
                              ),
                      ),
                    ],
                  ),
                ),
              ),
              // The controls follow you onto the faces — muting is the thing a
              // person looking at a call most wants — and the navigation does not:
              // this is a place you go back from, not a fourth tab.
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: DockIsland(
                  children: [ControlBar(state: widget.state, onCallScreen: true)],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// A renderer only for a tile with a stream to render. Somebody audio-only, or
  /// in the conversation with nothing published, is a face and a name — and a
  /// native texture per such tile was a platform call bought for nothing. When a
  /// stream does arrive the widget type changes under the same key, so the tile
  /// gets a fresh renderer rather than a reused one.
  static Widget _defaultTile(BuildContext context, CallTile tile) =>
      tile.stream == null ? _TileFrame(tile: tile) : _VideoTile(tile: tile);
}

/// Call state plus roster, folded into what a tile needs.
///
/// Kept out of the widgets so a test can build the same list without a tree, and
/// so the two-plane identity bridge lives in one readable place rather than
/// scattered through `build`.
@visibleForTesting
List<CallTile> tilesFor(AppState state) => _tiles(state);

List<CallTile> _tiles(AppState state) {
  final call = state.call;
  final handle = state.callHandle;
  final live = handle is LiveCall ? handle : null;

  final tiles = <CallTile>[
    // Ourselves first, and only while the camera is actually open — a self tile
    // showing an avatar when nothing is captured is just a second name badge.
    if (call.media.capturing)
      CallTile(
        id: state.mePerson?.id ?? 'self',
        label: 'You',
        isSelf: true,
        videoLive: call.cameraOn,
        muted: !call.micOn,
        sharingScreen: false,
        stream: live?.localStream,
        // Measured here rather than read back off the roster: Gather agrees a
        // beat later, and a beat is visible on your own face. See
        // `AppState.amSpeaking`.
        speaking: state.amSpeaking,
        reactions: state.reactions.forPerson(state.mePerson?.id),
      ),
  ];

  for (final person in call.participants) {
    final row = state.rowForSrcId(person.srcId);
    final streams = live?.streamFor(person.srcId) ?? const {};
    tiles.add(CallTile(
      id: row?.id ?? person.srcId,
      // Somebody the roster has not placed yet is still in the call and still
      // audible, so they get a tile with an honest placeholder rather than
      // being dropped from a list they are demonstrably part of.
      label: row?.name ?? _someone,
      isSelf: false,
      videoLive: person.videoLive,
      muted: person.muted,
      sharingScreen: person.sharingScreen,
      // A screen share is the thing worth looking at when there is one.
      stream: person.sharingScreen
          ? streams[SfuTag.screen] ?? streams[SfuTag.video]
          : streams[SfuTag.video],
      photoUrl: row == null ? null : state.photoUrlFor(row.id),
      availability: row?.availability,
      speaking: row?.speaking ?? false,
      reactions: state.reactions.forPerson(row?.id),
    ));
  }

  // Everybody Gather has put in the conversation whom the media plane is not
  // sending. Two quite different people land here and both belong: somebody the
  // SFU has not negotiated yet — the cluster arrives a second or so ahead of the
  // call — and somebody with their microphone and camera both off, who publishes
  // nothing and so never becomes a participant at all, however long you talk. A
  // screen that said "Nobody else here" about either, under a banner naming them,
  // would be contradicting itself.
  final shown = {for (final tile in tiles) tile.id};
  for (final row in state.huddleRows) {
    if (!shown.add(row.id)) continue;
    tiles.add(CallTile(
      id: row.id,
      label: row.name ?? _someone,
      isSelf: false,
      videoLive: false,
      muted: false,
      sharingScreen: false,
      photoUrl: state.photoUrlFor(row.id),
      availability: row.availability,
      speaking: row.speaking ?? false,
      reactions: state.reactions.forPerson(row.id),
    ));
  }
  return tiles;
}

/// What a tile is called when the roster cannot name it yet.
const _someone = 'Someone';

class _Header extends StatelessWidget {
  const _Header({required this.state, required this.count});

  final AppState state;
  final int count;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
      child: Row(
        children: [
          // Back leaves the faces up — the call keeps running, you just stop
          // looking. Leave, on the right, is the opposite and the deliberate one:
          // it ends the call for real. The two are far apart on purpose.
          IconButton(
            onPressed: () => Navigator.of(context).maybePop(),
            icon: const Icon(Icons.arrow_back),
            color: t.foreground,
            tooltip: 'Back',
          ),
          Expanded(
            child: Text(
              switch (count) {
                0 => 'Nobody else here',
                1 => '1 other person',
                _ => '$count other people',
              },
              style: TextStyle(
                color: t.foreground,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          // Ends the call and tells the OS it ended — the same path CallKit's own
          // End button takes, so the lock screen and this screen can never
          // disagree about whether a call is up. The screen closes behind it.
          TextButton.icon(
            onPressed: () async {
              await state.leaveCall();
              if (context.mounted) await Navigator.of(context).maybePop();
            },
            icon: const Icon(Icons.call_end_rounded, size: 20),
            label: const Text('Leave'),
            style: TextButton.styleFrom(foregroundColor: t.danger),
          ),
        ],
      ),
    );
  }
}

/// One, two, or a grid.
///
/// Not a `GridView`: the counts that matter are small and each has a shape worth
/// having. One person fills the screen. Two split it, stacked, because a phone is
/// tall and two side-by-side portraits are two slivers. Three or more go to two
/// columns, which is where a grid finally earns its keep.
class _Grid extends StatelessWidget {
  const _Grid({required this.tiles, required this.buildTile});

  /// Nothing on top: the first face starts directly under the header, which
  /// already carries its own breathing room, and a second gap above the video
  /// read as an empty strip rather than as a margin.
  static const _edges = EdgeInsets.fromLTRB(8, 0, 8, 8);

  final List<CallTile> tiles;
  final CallTileBuilder buildTile;

  @override
  Widget build(BuildContext context) {
    Widget wrap(CallTile tile) => KeyedSubtree(
          key: ValueKey(tile.id),
          child: buildTile(context, tile),
        );

    if (tiles.length == 1) {
      return Padding(
        padding: _edges,
        child: wrap(tiles.single),
      );
    }
    if (tiles.length == 2) {
      return Padding(
        padding: _edges,
        child: Column(
          children: [
            Expanded(child: wrap(tiles.first)),
            const SizedBox(height: 8),
            Expanded(child: wrap(tiles.last)),
          ],
        ),
      );
    }
    return GridView.count(
      padding: _edges,
      crossAxisCount: 2,
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      childAspectRatio: 3 / 4,
      children: [for (final tile in tiles) wrap(tile)],
    );
  }
}

class _Nobody extends StatelessWidget {
  const _Nobody();

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.groups_outlined, size: 40, color: t.faint),
            const SizedBox(height: 12),
            Text(
              'Nobody is in this conversation yet.',
              textAlign: TextAlign.center,
              style: TextStyle(color: t.mutedForeground, fontSize: 14),
            ),
            const SizedBox(height: 6),
            Text(
              'Walk up to someone on the map, and they will appear here.',
              textAlign: TextAlign.center,
              style: TextStyle(color: t.faint, fontSize: 12.5),
            ),
          ],
        ),
      ),
    );
  }
}

/// One face, with its own renderer.
class _VideoTile extends StatefulWidget {
  const _VideoTile({required this.tile});

  final CallTile tile;

  @override
  State<_VideoTile> createState() => _VideoTileState();
}

class _VideoTileState extends State<_VideoTile> {
  final _renderer = RTCVideoRenderer();
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await _renderer.initialize();
    if (!mounted) {
      // Initialised into a widget that has already gone. Dispose it here or the
      // texture leaks with nobody left to free it.
      await _renderer.dispose();
      return;
    }
    setState(() => _ready = true);
    _attach();
  }

  @override
  void didUpdateWidget(_VideoTile old) {
    super.didUpdateWidget(old);
    // `videoLive` as well as the stream. Somebody turning their camera back on
    // keeps the same stream id, so comparing streams alone would leave the
    // renderer detached and show a frozen avatar over a live track.
    if (old.tile.stream?.id != widget.tile.stream?.id ||
        old.tile.videoLive != widget.tile.videoLive) {
      _attach();
    }
  }

  void _attach() {
    if (!_ready) return;
    _renderer.srcObject = widget.tile.videoLive ? widget.tile.stream : null;
  }

  @override
  void dispose() {
    // Detach before disposing. The renderer holding a stream that is being
    // stopped underneath it is the crash this ordering avoids. Only once it is
    // initialised: setting `srcObject` before that throws, which a tile closed in
    // the moment after it opened would otherwise do — `_init` disposes those.
    if (_ready) {
      _renderer.srcObject = null;
      _renderer.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tile = widget.tile;
    // Deliberately no `_attach()` here. Assigning `srcObject` is a platform call
    // with a side effect, and `build` can run for reasons that have nothing to do
    // with this tile — a theme change, a parent rebuild — so doing it here would
    // reattach the texture at arbitrary moments. `initState` and
    // `didUpdateWidget` are the two places the stream can actually have changed.
    return _TileFrame(
      tile: tile,
      video: _ready && tile.videoLive && tile.stream != null
          ? RTCVideoView(
              _renderer,
              mirror: tile.isSelf,
              objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
            )
          : null,
    );
  }
}

/// The chrome around a tile: the fallback face, the name, the mute pip.
///
/// Split from [_VideoTile] so a widget test can render the whole layout — names,
/// badges, the speaking ring — without a platform view anywhere near it.
@visibleForTesting
class TileFrame extends StatelessWidget {
  const TileFrame({super.key, required this.tile, this.video});

  final CallTile tile;
  final Widget? video;

  @override
  Widget build(BuildContext context) => _TileFrame(tile: tile, video: video);
}

class _TileFrame extends StatelessWidget {
  const _TileFrame({required this.tile, this.video});

  final CallTile tile;
  final Widget? video;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final speaking = tile.speaking;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOut,
      decoration: BoxDecoration(
        color: t.card,
        borderRadius: BorderRadius.circular(t.radius),
        // Outside the box, so it reads as a glow around the tile rather than as
        // a thicker edge. Modest on purpose: the grid's gutters are narrow and a
        // wide bloom would touch the neighbour.
        boxShadow: speaking
            ? [BoxShadow(color: t.ok.withValues(alpha: 0.5), blurRadius: 12)]
            : null,
      ),
      // **Foreground, not background.** A `DecoratedBox` paints its decoration
      // behind its child by default, and this one's child is a `ClipRRect` with
      // a `StackFit.expand` video in it — so the border was painted and then
      // covered by the frames, pixel for pixel. The ring was invisible on every
      // tile with a camera on, which is every tile of yourself whenever yours is
      // live, and the one place somebody is most likely to look for it.
      foregroundDecoration: BoxDecoration(
        borderRadius: BorderRadius.circular(t.radius),
        border: Border.all(
          // Green, and the same green as every other "live" in this app — the
          // availability dot, the call mark. It replaced `t.brand`, which is
          // #4257DA against a #262B38 border on a #171A23 card: a dark blue
          // becoming a slightly different dark blue, one point wider, on a
          // phone held at arm's length.
          color: speaking ? t.ok : t.border,
          width: speaking ? 3 : 1,
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(t.radius),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (video != null)
              video!
            else
              Center(
                child: PersonAvatar(
                  id: tile.id,
                  label: tile.label,
                  photoUrl: tile.photoUrl,
                  size: 64,
                  availability: tile.availability,
                  dotRing: t.card,
                ),
              ),
            if (tile.reactions.isNotEmpty)
              Positioned.fill(
                child: IgnorePointer(
                  child: ClipRect(child: _Reactions(flights: tile.reactions)),
                ),
              ),
            Positioned(
              left: 8,
              right: 8,
              bottom: 8,
              // One height for the row, set by the name. Each plate used to size
              // itself, so the mute pip — a 13-point glyph — sat a few points
              // shorter than the line of text beside it.
              child: IntrinsicHeight(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Flexible(child: _Plate(text: tile.label)),
                    if (tile.muted) ...[
                      const SizedBox(width: 6),
                      const _Plate(icon: Icons.mic_off, text: ''),
                    ],
                    if (tile.sharingScreen) ...[
                      const SizedBox(width: 6),
                      const _Plate(icon: Icons.screen_share_outlined, text: ''),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Everything one person has in the air, each on its own clock.
///
/// A [Stack] of independently animating children keyed on the flight id, which
/// is the whole point: a press that arrives while two emoji are already climbing
/// adds a third beside them and leaves the other two exactly where they were. A
/// single widget redrawn with a new value — which is what this was first — makes
/// every press restart the same animation, so holding the button produces one
/// stuttering emoji instead of a stream.
class _Reactions extends StatelessWidget {
  const _Reactions({required this.flights});

  final List<ReactionFlight> flights;

  @override
  Widget build(BuildContext context) => Stack(
        fit: StackFit.expand,
        children: [
          // Oldest first, so the newest — at the bottom, at full opacity — is
          // painted over the ones fading out above it.
          for (final flight in flights)
            _Flight(key: ValueKey(flight.id), flight: flight),
        ],
      );
}

/// One emoji, from the bottom of the tile to the top.
///
/// Gather's own: it appears low, rises the height of the face, drifts sideways a
/// little on the way and fades out before it reaches the top. The sideways drift
/// is not decoration — it is what keeps two presses a few hundred milliseconds
/// apart from flying up the same line, where the second would sit exactly on top
/// of the first.
///
/// The drift is derived from the flight id rather than taken from a random
/// number generator, so a rebuild — a new roster, a stream arriving, the phone
/// rotating — does not teleport an emoji mid-climb onto a different path.
class _Flight extends StatefulWidget {
  const _Flight({super.key, required this.flight});

  final ReactionFlight flight;

  @override
  State<_Flight> createState() => _FlightState();
}

class _FlightState extends State<_Flight> with SingleTickerProviderStateMixin {
  late final AnimationController _run = AnimationController(
    vsync: this,
    duration: reactionLinger,
  )..forward();

  /// Where this one sits across the tile, and which way it leans.
  ///
  /// A cheap integer hash of the id rather than `Random`: it must be stable for
  /// the life of the widget and it must differ between two flights created in
  /// the same millisecond, which a time-seeded generator cannot promise.
  late final double _lane = (((widget.flight.id * 2654435761) % 1000) / 1000) * 2 - 1;

  @override
  void dispose() {
    _run.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Up the full height of the tile, starting just inside the bottom edge.
    final rise = Tween<double>(begin: 0.86, end: -0.92).animate(
      // Decelerating: quick off the mark, drifting by the time it fades. A
      // linear climb reads as a scrolling ticker rather than as something
      // thrown.
      CurvedAnimation(parent: _run, curve: Curves.easeOutSine),
    );

    // In fast enough to catch the eye, out slowly enough not to blink.
    final fade = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 0.0, end: 1.0), weight: 12),
      TweenSequenceItem(tween: ConstantTween(1.0), weight: 58),
      TweenSequenceItem(tween: Tween(begin: 1.0, end: 0.0), weight: 30),
    ]).animate(_run);

    // A small pop on arrival, so a press registers as an *event* even when the
    // tile is busy with video behind it.
    final scale = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween(begin: 0.4, end: 1.12).chain(CurveTween(curve: Curves.easeOutBack)),
        weight: 18,
      ),
      TweenSequenceItem(tween: Tween(begin: 1.12, end: 1.0), weight: 82),
    ]).animate(_run);

    return AnimatedBuilder(
      animation: _run,
      builder: (context, child) {
        // Leans away from centre as it climbs, rather than starting off-centre:
        // everything is thrown from roughly the same place and fans out, which
        // is what makes a run of them read as one stream.
        final x = _lane * 0.5 * Curves.easeInOut.transform(_run.value);
        return Align(
          alignment: Alignment(x, rise.value),
          child: Opacity(
            opacity: fade.value.clamp(0.0, 1.0),
            child: Transform.scale(scale: scale.value, child: child),
          ),
        );
      },
      child: Text(
        widget.flight.emote,
        style: const TextStyle(
          fontSize: 30,
          // No plate behind it. One was tried and it is what made these ugly:
          // a black disc round every emoji turns a stream of them into a string
          // of beads and hides the face they are being thrown at. A shadow does
          // the same job — keeping a pale 👏 legible on a bright frame — without
          // putting anything opaque on the video.
          shadows: [
            Shadow(color: Color(0x73000000), blurRadius: 8),
            Shadow(color: Color(0x40000000), blurRadius: 2, offset: Offset(0, 1)),
          ],
        ),
      ),
    );
  }
}

class _Plate extends StatelessWidget {
  const _Plate({this.text = '', this.icon});

  final String text;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        // Its own scrim rather than a token: this sits on top of video, whose
        // brightness nothing can predict, and a themed fill would vanish against
        // half the frames it lands on.
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) Icon(icon, size: 13, color: Colors.white),
            if (icon != null && text.isNotEmpty) const SizedBox(width: 4),
            if (text.isNotEmpty)
              Flexible(
                child: Text(
                  text,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// You are in a call, floating over the top of the office, and the way to the faces.
///
/// It replaced a button in the control bar, which sat among the controls as one more
/// glyph and said nothing until pressed. A call is a state you are *in*, so it gets
/// a sentence naming who with, where the office's own chrome stops and the floor
/// begins. Only on the office: the call is something happening *in* the room, and
/// the other tabs are a record and a settings page.
///
/// The dock's own fill, border and corner, and its grey for anything secondary, so
/// the banner reads as one more piece of the same controls, which is what it is. The
/// accent stays out of it: on the dock blue means *selected* or *on*, and a blue
/// "Tap to see everyone" read as a link rather than as the banner's second line. A solid accent was tried first and shouted
/// over the office, and then the selected tab's blue wash, which made it look
/// selected. Held off the edges by the same gap it leaves under the app bar, so it
/// sits in an even margin rather than a wide one at the sides and a tight one on top.
class CallBanner extends StatelessWidget {
  const CallBanner({super.key, required this.state});

  /// Between the banner and the app bar above it, and between it and either side.
  static const _bannerGap = 8.0;

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final t = context.tokens;
        // The call screen's own list, so the banner and the screen it opens can
        // never disagree about who is in the call.
        final faces = [for (final tile in _tiles(state)) if (!tile.isSelf) tile];
        final (:title, :subtitle) = callBannerText([
          for (final face in faces) face.label == _someone ? null : face.label,
        ]);
        final fill = t.card;

        return Padding(
          padding: const EdgeInsets.fromLTRB(_bannerGap, _bannerGap, _bannerGap, 0),
          child: Semantics(
            button: true,
            label: '$title. $subtitle',
            child: ExcludeSemantics(
              child: Material(
                color: fill,
                shape: RoundedRectangleBorder(
                  // The dock island's corner, not the plates inside it.
                  borderRadius: BorderRadius.circular(t.radius + 10),
                  side: BorderSide(color: t.border),
                ),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () => openCallScreen(context, state),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 12, 10, 12),
                    child: Row(
                      children: [
                        const _CallMark(),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 14,
                                  height: 1.25,
                                  fontWeight: FontWeight.w600,
                                  color: t.foreground,
                                ),
                              ),
                              Text(
                                subtitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12,
                                  height: 1.3,
                                  color: t.mutedForeground,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Icon(Icons.chevron_right_rounded, color: t.mutedForeground),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

}

/// The banner's two lines, for everybody in the call — a name, or null for somebody
/// the roster cannot name yet.
///
/// First names, because the banner is one line on a phone and "Ada Lovelace and
/// Grace Hopper" does not fit in it. Named people lead and the unnamed are counted,
/// so a colleague whose row has not landed reads as "someone else" rather than as a
/// person called Someone.
@visibleForTesting
({String title, String subtitle}) callBannerText(List<String?> people) {
  final names = [for (final name in people) ?_firstName(name)];
  final total = people.length;
  final title = switch ((total, names)) {
    (0, _) => 'In a call',
    (1, [final one]) => 'In a call with $one',
    (1, _) => 'In a call with someone',
    (2, [final one, final two]) => 'In a call with $one and $two',
    (2, [final one]) => 'In a call with $one and someone else',
    (_, [final one, ...]) => 'In a call with $one and ${total - 1} others',
    (_, _) => 'In a call with $total people',
  };
  final subtitle = switch ((total, names)) {
    (0, _) => 'Tap to open the call',
    (1, [final one]) => 'Tap to see $one',
    (1, _) => 'Tap to see them',
    _ => 'Tap to see everyone',
  };
  return (title: title, subtitle: subtitle);
}

String? _firstName(String? name) {
  if (name == null) return null;
  final first = name.trim().split(RegExp(r'\s+')).first;
  return first.isEmpty ? null : first;
}

/// The banner's leading mark: a call glyph in a circle.
///
/// It was the faces of whoever you were talking to, overlapping. The names in the
/// title already say who; the mark only has to say *what*, and a stack of profile
/// pictures read as a list of people rather than as "a call is running". Green, in
/// the app's tint recipe, because green is already what "live" means on every dot
/// in it.
class _CallMark extends StatelessWidget {
  const _CallMark();

  static const _size = 38.0;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Container(
      width: _size,
      height: _size,
      decoration: BoxDecoration(
        color: t.ok.withValues(alpha: 0.14),
        shape: BoxShape.circle,
        border: Border.all(color: t.ok.withValues(alpha: 0.3)),
      ),
      child: Icon(Icons.call_rounded, size: 20, color: t.ok),
    );
  }
}
