/// Stand-in "video" for the simulator, where there is no camera and so no real
/// WebRTC stream to render.
///
/// The iOS simulator has no capture device, so `getUserMedia` fails and every
/// harness tile would otherwise fall through to the avatar placeholder — leaving
/// nothing to judge how the call layout *cuts* a frame (cover vs contain) or how
/// it zooms. This paints a moving test card into each tile instead — a grid with
/// edge labels and a bouncing dot, so the crop is obvious (the edges a cover-fit
/// eats are the labelled ones) and the pinch-zoom has something to bite on. Each
/// person's card is a different aspect (16:9, 9:16, 4:3, 3:4, 1:1; see [_aspects]),
/// so the layout is seen cutting portrait and square sources, not just landscape.
///
/// It is wired in only by `main_harness.dart` via [CallScreen.buildTile]; the real
/// app never builds this, and the production tile path is untouched.
///
/// ## The render report
///
/// Each footage tile also reports itself to the debug render registry
/// (`../src/media/render_registry.dart`) as `source: "scripted"`, the way the
/// real `_VideoTile` reports `live`, so `ext.gc.media.render` and its wiring
/// cross-check run in the simulator. The report describes the **stream the tile
/// stands in for**, not the test card: the card is painted over everyone for the
/// eye, but a peer the scripted call has no video for is reported as showing
/// none, so the cross-check is judged against what `ScriptedCall.sampleFlow`
/// says is on the wire rather than flagging every audio-only stand-in. There is
/// no `MediaStream` in the harness, so the stale/wrong-stream checks (which
/// compare stream ids) are live-only; the duplicate, presence, flowing-without-
/// tile and first-frame checks all run here. Written only inside
/// `if (kDebugMode)`, like the real tile's.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../src/media/render_registry.dart';
import '../ui/call_screen.dart';

/// A [CallTileBuilder] that renders [DemoFootage] for every tile that would carry
/// video — everyone but a self tile with its camera off, which stays an avatar so
/// "you, camera off" still reads honestly.
Widget demoFootageTile(BuildContext context, CallTile tile) {
  final showVideo = !tile.isSelf || tile.videoLive;
  final frame = TileFrame(
    tile: tile,
    video: showVideo
        ? DemoFootage(seed: tile.id, mirror: tile.isSelf, label: tile.label)
        : null,
  );
  if (!kDebugMode) return frame;
  return ScriptedTileReporter(tile: tile, child: frame);
}

/// Reports one harness tile to [renderRegistry] for as long as it is mounted.
///
/// Public so a widget test can wrap its own inert tile in the same reporter the
/// harness uses, and assert on what `media.render` makes of it.
class ScriptedTileReporter extends StatefulWidget {
  const ScriptedTileReporter({
    super.key,
    required this.tile,
    required this.child,
    this.streamTag,
    this.firstFrame = true,
  });

  final CallTile tile;
  final Widget child;

  /// Overrides the tag the report claims, for a test that wants a tile bound
  /// to the wrong stream. Null derives it from [tile].
  final String? streamTag;

  /// Whether a first frame is reported after the first paint. A test sets false
  /// for a tile that never renders.
  final bool firstFrame;

  @override
  State<ScriptedTileReporter> createState() => _ScriptedTileReporterState();
}

class _ScriptedTileReporterState extends State<ScriptedTileReporter> {
  String? _key;

  /// Whether the stream this tile stands in for carries video on the scripted
  /// wire: the self tile with its camera on, a peer with live video or a share.
  bool get _showsVideo => widget.tile.videoLive || (!widget.tile.isSelf && widget.tile.sharingScreen);

  String get _tag =>
      widget.streamTag ?? widget.tile.streamTag ?? (!widget.tile.isSelf && widget.tile.sharingScreen ? 'screen' : 'video');

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Here rather than in initState: the slot is read from an inherited widget.
    if (kDebugMode && _key == null) _bind();
  }

  @override
  void didUpdateWidget(ScriptedTileReporter old) {
    super.didUpdateWidget(old);
    if (!kDebugMode) return;
    // A stand-in has no renderer to re-attach, so any change of what it shows
    // is a re-bind.
    if (old.tile.srcId != widget.tile.srcId ||
        old.tile.id != widget.tile.id ||
        old.streamTag != widget.streamTag ||
        old.tile.videoLive != widget.tile.videoLive ||
        old.tile.sharingScreen != widget.tile.sharingScreen) {
      _bind();
    }
  }

  void _bind() {
    final slot = CallTileSlot.of(context);
    final key = _key ??= renderRegistry.nextKey('$slot:${widget.tile.id}');
    final shows = _showsVideo;
    final size = shows ? DemoFootage.shapeFor(widget.tile.id) : null;
    renderRegistry.bind(
      tileKey: key,
      slot: slot,
      source: 'scripted',
      isSelf: widget.tile.isSelf,
      tileId: widget.tile.id,
      srcId: widget.tile.srcId,
      tag: shows ? _tag : null,
      showsVideo: shows,
      videoWidth: size?.width.round(),
      videoHeight: size?.height.round(),
    );
    if (shows && widget.firstFrame) {
      // The test card paints on the next frame; that is its "first frame".
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _key != null) renderRegistry.firstFrame(_key!);
      });
    }
  }

  @override
  void dispose() {
    if (kDebugMode && _key != null) renderRegistry.unbind(_key!);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// A moving test card, fit to cover its tile and wrapped for pinch-zoom — the
/// same cover-and-zoom treatment a real spotlight tile gives an `RTCVideoView`, so
/// what you see cut and scaled here is what the layout does to a face.
class DemoFootage extends StatefulWidget {
  const DemoFootage({
    super.key,
    required this.seed,
    this.mirror = false,
    this.label = '',
  });

  /// Drives the card's colour, so each person's tile is a different hue and the
  /// grid of them reads as distinct feeds rather than one repeated pattern.
  final String seed;

  /// Mirrors the card, matching the self-view's mirrored camera.
  final bool mirror;

  /// Drawn large across the card, so a tile is identifiable even cropped hard.
  final String label;

  /// The card's source size for [seed] — also what the render report gives as
  /// the stand-in's video size.
  static Size shapeFor(String seed) =>
      _DemoFootageState._aspects[seed.hashCode.abs() % _DemoFootageState._aspects.length];

  @override
  State<DemoFootage> createState() => _DemoFootageState();
}

class _DemoFootageState extends State<DemoFootage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _t = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 4),
  )..repeat();

  @override
  void dispose() {
    _t.dispose();
    super.dispose();
  }

  /// The camera shapes a real room mixes — a widescreen laptop, a phone held
  /// upright, an old 4:3 webcam, a square crop. Picked by [seed] so each person
  /// keeps one, and the layout is seen cutting every aspect, not just 16:9.
  static const _aspects = <Size>[
    Size(1600, 900), // 16:9 widescreen
    Size(900, 1600), // 9:16 phone upright
    Size(1200, 900), // 4:3 webcam
    Size(900, 1200), // 3:4 phone-ish
    Size(1080, 1080), // 1:1 square
  ];

  /// Cover (crop the long edge) vs contain (letterbox, bars on the short edge).
  /// The app's own Fit/Fill button only shows over a real video stream, which the
  /// simulator cannot make — so the toggle lives here, on a double-tap, to make
  /// the letterbox behaviour reachable on a bare sim.
  bool _contain = false;

  @override
  Widget build(BuildContext context) {
    // A source card in this person's camera shape, scaled to cover or letterbox
    // the tile and made zoomable — the behaviours the user wants to eyeball,
    // across a mix of aspects.
    final shape = DemoFootage.shapeFor(widget.seed);
    final card = SizedBox(
      width: shape.width,
      height: shape.height,
      child: AnimatedBuilder(
        animation: _t,
        builder: (context, _) => CustomPaint(
          painter: _TestCardPainter(
            phase: _t.value,
            hue: (widget.seed.hashCode % 360).toDouble().abs(),
            label: widget.label,
          ),
        ),
      ),
    );
    final fitted = ColoredBox(
      // The letterbox bars: black shows through wherever a contained frame does
      // not reach, top-and-bottom or side, exactly as a real video would bar.
      color: Colors.black,
      child: ClipRect(
        child: SizedBox.expand(
          child: FittedBox(
            fit: _contain ? BoxFit.contain : BoxFit.cover,
            clipBehavior: Clip.hardEdge,
            child: card,
          ),
        ),
      ),
    );
    final zoomable =
        InteractiveViewer(minScale: 1, maxScale: 5, child: fitted);
    final mirrored = widget.mirror
        ? Transform(
            alignment: Alignment.center,
            transform: Matrix4.identity()..scaleByDouble(-1.0, 1.0, 1.0, 1.0),
            child: zoomable,
          )
        : zoomable;
    // Double-tap toggles cover/letterbox. Behaviour.opaque so the whole tile is
    // the target; InteractiveViewer keeps the drag/pinch, which it does not use
    // double-tap for.
    final tappable = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onDoubleTap: _toggleFit,
      child: mirrored,
    );
    // The Fit/Fill button, top-right, standing in for the app's own — which only
    // shows over a real video stream the simulator cannot make. Only on a big
    // tile (the grid thumbnails are too small for it, and the app puts it on the
    // spotlight alone), gated by width so a thumbnail stays clean.
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 220) return tappable;
        return Stack(
          children: [
            Positioned.fill(child: tappable),
            Positioned(top: 8, right: 8, child: _fitButton()),
          ],
        );
      },
    );
  }

  void _toggleFit() => setState(() => _contain = !_contain);

  /// Names the result of the tap, like the app's: "Fit" while cropped offers the
  /// whole frame; "Fill" while letterboxed offers the crop back.
  Widget _fitButton() {
    return Material(
      color: Colors.black.withValues(alpha: 0.55),
      borderRadius: BorderRadius.circular(8),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: _toggleFit,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(_contain ? Icons.crop_free : Icons.fit_screen,
                    size: 15, color: Colors.white),
                const SizedBox(width: 6),
                Text(
                  _contain ? 'Fill' : 'Fit',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TestCardPainter extends CustomPainter {
  _TestCardPainter({
    required this.phase,
    required this.hue,
    required this.label,
  });

  /// 0..1 loop, drives the bouncing dot.
  final double phase;
  final double hue;
  final String label;

  @override
  void paint(Canvas canvas, Size size) {
    final bg = HSVColor.fromAHSV(1, hue, 0.55, 0.30).toColor();
    final line = HSVColor.fromAHSV(1, hue, 0.35, 0.75).toColor();
    canvas.drawRect(Offset.zero & size, Paint()..color = bg);

    // A grid, so a crop or a zoom is measurable by eye.
    final grid = Paint()
      ..color = line.withValues(alpha: 0.4)
      ..strokeWidth = 2;
    for (var i = 1; i < 8; i++) {
      final x = size.width * i / 8;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
    }
    for (var i = 1; i < 5; i++) {
      final y = size.height * i / 5;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }

    // Edge labels: a cover-fit eats the top and bottom of a tall tile and the
    // sides of a wide one, so naming the edges makes the crop legible.
    _edge(canvas, 'TOP', Offset(size.width / 2, 36), line);
    _edge(canvas, 'BOTTOM', Offset(size.width / 2, size.height - 36), line);
    _edge(canvas, 'LEFT', Offset(70, size.height / 2), line);
    _edge(canvas, 'RIGHT', Offset(size.width - 70, size.height / 2), line);

    // A bright band sweeping left→right, so the motion reads at a glance even on
    // a thumbnail — bigger and faster than the dot alone.
    final sweepX = size.width * ((phase * 1.0) % 1);
    canvas.drawRect(
      Rect.fromLTWH(sweepX - size.width * 0.04, 0, size.width * 0.08, size.height),
      Paint()..color = Colors.white.withValues(alpha: 0.12),
    );

    // A bouncing dot, so the feed is unmistakably moving rather than a still.
    final dx = size.width * (0.1 + 0.8 * _tri(phase));
    final dy = size.height * (0.15 + 0.7 * _tri((phase + 0.33) % 1));
    canvas.drawCircle(
      Offset(dx, dy),
      28,
      Paint()..color = HSVColor.fromAHSV(1, (hue + 180) % 360, 0.7, 0.95).toColor(),
    );

    // The name, big, dead centre.
    _text(canvas, label, size.center(Offset.zero), line.withValues(alpha: 0.9),
        64, FontWeight.w700);

    // A running frame counter, bottom-left, so "live" is unambiguous — a still
    // would freeze it.
    final frame = (phase * 120).floor().toString().padLeft(3, '0');
    _text(canvas, '#$frame', Offset(70, size.height - 80),
        line.withValues(alpha: 0.9), 28, FontWeight.w700);
  }

  /// Triangle wave 0..1..0, for a bounce that turns around rather than jumping.
  double _tri(double t) => t < 0.5 ? t * 2 : 2 - t * 2;

  void _edge(Canvas canvas, String s, Offset at, Color c) =>
      _text(canvas, s, at, c, 30, FontWeight.w600);

  void _text(Canvas canvas, String s, Offset at, Color c, double size,
      FontWeight weight) {
    if (s.isEmpty) return;
    final tp = TextPainter(
      text: TextSpan(
        text: s,
        style: TextStyle(color: c, fontSize: size, fontWeight: weight),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, at - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  bool shouldRepaint(_TestCardPainter old) =>
      old.phase != phase || old.hue != hue || old.label != label;
}
