/// Which video tile on screen is bound to which stream, as the tiles themselves
/// report it — the render-side half of the debug drive's media probe
/// (`media.render`, plan task 2.5).
///
/// ## Why the packet counters are not enough
///
/// `media.snapshot` can prove that a peer's frames arrive *and decode*. It cannot
/// prove they reach the right rectangle. The call screen has had exactly that
/// class of bug: an element reused under the wrong key kept the last person's
/// renderer, so Bob's tile showed Alice; a renderer attached before
/// `initialize()` finished stayed black for the life of the tile. Every counter
/// said "flowing". The only witness is the tile, so each one reports here what
/// its renderer is actually bound to and whether a frame ever came out of it,
/// and the drive cross-checks that against the flow verdicts.
///
/// ## Why it is a sink in `media/`, not part of the drive
///
/// The tiles live in `lib/ui/call_screen.dart` (and the harness's stand-in
/// footage), and nothing outside `debug_drive/` may reference the drive. So
/// this is the same shape as `mediaLogDebugSink`: a plain record carrying no
/// `ext.gc.` name, written **only inside `if (kDebugMode)`** at every call site.
/// That guard is a compile-time constant, so a release build drops the writes
/// and then tree-shakes this whole file — there is no runtime flag to forget.
/// The registry fills whether or not a drive is installed; it is a few map
/// writes per tile bind, and nobody reads it but `media.render`.
///
/// Pure Dart (foundation only, no `flutter_webrtc`), so the cross-check that
/// reads it is unit-testable.
library;

import 'package:flutter/foundation.dart';

/// One tile's report of what it is drawing.
///
/// Two stream ids, kept apart on purpose: [tileStreamId] is what the call
/// screen *told* the tile to draw, [boundStreamId] is what the renderer's
/// `srcObject` actually is. They differ for exactly one reason — the tile was
/// handed a new stream and never re-attached — which is the stale-renderer bug,
/// and a report that merged them would hide it.
@immutable
class TileReport {
  const TileReport({
    required this.tileKey,
    required this.slot,
    required this.source,
    required this.isSelf,
    required this.showsVideo,
    required this.boundAt,
    required this.updatedAt,
    this.tileId,
    this.srcId,
    this.tag,
    this.tileStreamId,
    this.boundStreamId,
    this.videoWidth,
    this.videoHeight,
    this.firstFrameAt,
  });

  /// Unique per tile instance for its lifetime — a fresh renderer is a fresh
  /// key, so a swap reads as an unbind and a bind, never as one tile mutating.
  final String tileKey;

  /// `big` for the spotlight's enlarged face, `tile` for the grid and the strip.
  /// The spotlighted person appears in both, legitimately; the duplicate check
  /// counts per slot.
  final String slot;

  /// `live` from the real `RTCVideoView` tile, `scripted` from the harness's
  /// stand-in footage — never confused, the same rule as a flow sample.
  final String source;

  /// The call tile's own id (`SpaceUser.id`, or the srcId when unplaced).
  final String? tileId;
  final bool isSelf;

  /// The media-plane id the tile is for; null for the self tile.
  final String? srcId;

  /// The `SfuTag` wire name of the stream it shows (`video`, `screen`).
  final String? tag;

  /// Whether the tile is drawing a frame rather than the avatar.
  final bool showsVideo;

  /// What the tile was told to draw, and what its renderer is bound to.
  final String? tileStreamId;
  final String? boundStreamId;

  /// The size the renderer reports, once it knows.
  final int? videoWidth;
  final int? videoHeight;

  /// When the renderer was last bound (or re-bound), and when its first frame
  /// since then came out. A re-bind clears the first frame: the native renderer
  /// resets its own first-frame flag on every track change.
  final DateTime boundAt;
  final DateTime? firstFrameAt;
  final DateTime updatedAt;

  bool get firstFrameRendered => firstFrameAt != null;

  /// The flow-probe key this tile claims to show: `out:video` for yourself,
  /// `in:<srcId>|<tag>` for a peer, null when it cannot say.
  String? get streamKey {
    if (tag == null) return null;
    if (isSelf) return 'out:$tag';
    if (srcId == null) return null;
    return 'in:$srcId|$tag';
  }

  TileReport copyWith({
    String? tileId,
    String? srcId,
    String? tag,
    bool? showsVideo,
    String? tileStreamId,
    String? boundStreamId,
    int? videoWidth,
    int? videoHeight,
    DateTime? boundAt,
    DateTime? firstFrameAt,
    bool clearFirstFrame = false,
    required DateTime updatedAt,
  }) =>
      TileReport(
        tileKey: tileKey,
        slot: slot,
        source: source,
        isSelf: isSelf,
        tileId: tileId ?? this.tileId,
        srcId: srcId ?? this.srcId,
        tag: tag ?? this.tag,
        showsVideo: showsVideo ?? this.showsVideo,
        tileStreamId: tileStreamId ?? this.tileStreamId,
        boundStreamId: boundStreamId ?? this.boundStreamId,
        videoWidth: videoWidth ?? this.videoWidth,
        videoHeight: videoHeight ?? this.videoHeight,
        boundAt: boundAt ?? this.boundAt,
        firstFrameAt: clearFirstFrame ? null : firstFrameAt ?? this.firstFrameAt,
        updatedAt: updatedAt,
      );

  Map<String, Object?> toJson() => {
        'tileKey': tileKey,
        'slot': slot,
        'source': source,
        'tileId': ?tileId,
        'isSelf': isSelf,
        'srcId': ?srcId,
        'tag': ?tag,
        'key': ?streamKey,
        'showsVideo': showsVideo,
        'tileStreamId': ?tileStreamId,
        'boundStreamId': ?boundStreamId,
        'videoWidth': ?videoWidth,
        'videoHeight': ?videoHeight,
        'firstFrameRendered': firstFrameRendered,
        'boundAt': boundAt.toUtc().toIso8601String(),
        if (firstFrameAt case final at?) 'firstFrameAt': at.toUtc().toIso8601String(),
      };
}

/// Every tile currently mounted, by [TileReport.tileKey].
class RenderRegistry {
  RenderRegistry({DateTime Function()? now}) : _now = now ?? DateTime.now;

  DateTime Function() _now;
  final Map<String, TileReport> _tiles = {};
  int _next = 0;

  /// The registry's clock — what [TileReport.boundAt] was stamped with, so a
  /// reader measuring "bound for how long" uses the same one.
  DateTime now() => _now();

  /// A key no other tile instance in this isolate has had.
  String nextKey(String hint) => '$hint#${++_next}';

  /// The tiles mounted now, oldest bind first.
  List<TileReport> get tiles => _tiles.values.toList()..sort((a, b) => a.boundAt.compareTo(b.boundAt));

  /// A tile bound (or re-bound) its renderer. Resets the first-frame flag.
  void bind({
    required String tileKey,
    required String slot,
    required String source,
    required bool isSelf,
    required bool showsVideo,
    String? tileId,
    String? srcId,
    String? tag,
    String? tileStreamId,
    String? boundStreamId,
    int? videoWidth,
    int? videoHeight,
  }) {
    final now = _now();
    _tiles[tileKey] = TileReport(
      tileKey: tileKey,
      slot: slot,
      source: source,
      isSelf: isSelf,
      tileId: tileId,
      srcId: srcId,
      tag: tag,
      showsVideo: showsVideo,
      tileStreamId: tileStreamId,
      boundStreamId: boundStreamId,
      videoWidth: videoWidth,
      videoHeight: videoHeight,
      boundAt: now,
      updatedAt: now,
    );
  }

  /// The tile was rebuilt with new data but did not re-bind: what it claims
  /// (srcId, tag, the stream it was handed) may move while [TileReport.boundStreamId]
  /// stays — which is the point. Ignored for a key that never bound.
  void claim(
    String tileKey, {
    String? tileId,
    String? srcId,
    String? tag,
    required bool showsVideo,
    String? tileStreamId,
  }) {
    final t = _tiles[tileKey];
    if (t == null) return;
    // Built field by field rather than through copyWith: a claim that moves to
    // "no stream" must be able to null these out.
    _tiles[tileKey] = TileReport(
      tileKey: t.tileKey,
      slot: t.slot,
      source: t.source,
      isSelf: t.isSelf,
      tileId: tileId,
      srcId: srcId,
      tag: tag,
      showsVideo: showsVideo,
      tileStreamId: tileStreamId,
      boundStreamId: t.boundStreamId,
      videoWidth: t.videoWidth,
      videoHeight: t.videoHeight,
      boundAt: t.boundAt,
      firstFrameAt: t.firstFrameAt,
      updatedAt: _now(),
    );
  }

  /// The renderer produced its first frame since the last bind.
  void firstFrame(String tileKey) {
    final t = _tiles[tileKey];
    if (t == null || t.firstFrameAt != null) return;
    final now = _now();
    _tiles[tileKey] = t.copyWith(firstFrameAt: now, updatedAt: now);
  }

  /// The renderer learned the frame size.
  void resize(String tileKey, {required int width, required int height}) {
    final t = _tiles[tileKey];
    if (t == null) return;
    _tiles[tileKey] = t.copyWith(videoWidth: width, videoHeight: height, updatedAt: _now());
  }

  /// The tile is gone.
  void unbind(String tileKey) => _tiles.remove(tileKey);

  /// Forget every tile, and optionally swap the clock — for tests.
  @visibleForTesting
  void debugReset({DateTime Function()? now}) {
    _tiles.clear();
    if (now != null) _now = now;
  }
}

/// The one registry the tiles write to. Only ever touched inside
/// `if (kDebugMode)`; see the file header.
final RenderRegistry renderRegistry = RenderRegistry();
