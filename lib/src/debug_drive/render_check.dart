/// The wiring check behind `ext.gc.media.render`: do the tiles on screen show
/// the streams that are flowing, each exactly once, and has every one of them
/// actually put a frame up.
///
/// Decoded frames (`media.snapshot`) prove the SFU → decoder path. They do not
/// prove the right rectangle shows them — see `../media/render_registry.dart`
/// for the bugs that looked "flowing" from every counter. This joins the two
/// readings: the tiles' own reports of what their renderers are bound to, and
/// the flow verdicts for the same interval, plus (live only) the call's own
/// books of which `MediaStream` belongs to whom.
///
/// ## The findings, and what each one means
///
/// | `problem` | Rule |
/// |---|---|
/// | `flowing_without_tile` | A peer's video (or, while they share, their screen) — or your own camera — is `flowing`, the call screen is open, and no tile shows it. The frames decode into nothing. |
/// | `bound_not_present` | A tile shows a stream the sample has no consumer/producer for at all. It is drawing a dead texture or the wrong person. |
/// | `bound_not_flowing` | A tile shows a stream whose verdict is `stalled`, `paused` or `missing`: a frozen frame presented as live. |
/// | `unverified` | A tile's stream was `not_measured` (or had no verdict yet). Not a fault — said so rather than counted as fine. |
/// | `duplicate_tiles` | Two tiles in the same slot (`tile` or `big`) show one stream. The spotlighted face being both `big` and in the strip is by design and not flagged. |
/// | `never_rendered` | A tile has shown a stream for at least `firstFrameWithinMs` and its renderer has not produced a first frame since it was bound: the black-rectangle bug. |
/// | `stale_binding` | *Live only.* The renderer's `srcObject` is not the stream the tile was handed (or is bound while the tile shows no video): a renderer that missed a re-attach. |
/// | `wrong_stream` | *Live only.* The bound stream belongs, by the call's books, to a different `srcId|tag` than the tile claims — or to nobody the call holds. |
///
/// Pure over its inputs, so every row is table-tested without a widget.
library;

import '../media/media_flow.dart';
import '../media/render_registry.dart';

/// The verdicts a tile showing a stream may not have.
const _notFlowing = {FlowVerdict.stalled, FlowVerdict.paused, FlowVerdict.missing};

/// Cross-checks [tiles] against one interval's [verdicts] over [sample].
///
/// [owners] is the call's stream-id → keys map (`LiveCall.debugStreamOwners`),
/// or null when there is none to check against (the harness, a fake): the
/// `wrong_stream` row is then skipped, and the result says so.
Map<String, Object?> checkRender({
  required List<TileReport> tiles,
  required MediaFlowSample sample,
  required List<StreamVerdict> verdicts,
  required DateTime now,
  Map<String, Set<String>>? owners,
  Duration firstFrameWithin = const Duration(seconds: 3),
}) {
  final verdictOf = {for (final v in verdicts) v.key: v};
  final present = {
    for (final i in sample.inbound) i.key,
    for (final o in sample.outbound) o.key,
  };
  final findings = <Map<String, Object?>>[];
  void find(String problem, Map<String, Object?> detail) => findings.add({'problem': problem, ...detail});

  final showing = [
    for (final t in tiles)
      if (t.showsVideo && t.streamKey != null) t,
  ];

  // Two tiles in one slot on one stream.
  final bySlot = <(String, String), List<String>>{};
  for (final t in showing) {
    bySlot.putIfAbsent((t.streamKey!, t.slot), () => []).add(t.tileKey);
  }
  for (final MapEntry(key: (key, slot), value: keys) in bySlot.entries) {
    if (keys.length > 1) find('duplicate_tiles', {'key': key, 'slot': slot, 'tileKeys': keys});
  }

  for (final t in tiles) {
    final key = t.streamKey;
    if (t.showsVideo && key != null) {
      final v = verdictOf[key];
      if (!present.contains(key)) {
        find('bound_not_present', {'tileKey': t.tileKey, 'key': key});
      } else if (v == null || v.verdict == FlowVerdict.notMeasured) {
        find('unverified', {'tileKey': t.tileKey, 'key': key, 'verdict': v?.verdict.wire, 'detail': ?v?.detail});
      } else if (_notFlowing.contains(v.verdict)) {
        find('bound_not_flowing', {'tileKey': t.tileKey, 'key': key, 'verdict': v.verdict.wire});
      }
      final boundFor = now.difference(t.boundAt);
      if (!t.firstFrameRendered && boundFor >= firstFrameWithin) {
        find('never_rendered', {'tileKey': t.tileKey, 'key': key, 'boundForMs': boundFor.inMilliseconds});
      }
    }

    if (t.source != 'live') continue;
    // What the renderer should be bound to: the tile's stream while it shows
    // video, nothing while it shows the avatar.
    final expectedBound = t.showsVideo ? t.tileStreamId : null;
    if (t.boundStreamId != expectedBound) {
      find('stale_binding', {
        'tileKey': t.tileKey,
        'key': ?key,
        'tileStreamId': ?t.tileStreamId,
        'boundStreamId': ?t.boundStreamId,
        'showsVideo': t.showsVideo,
      });
    }
    final bound = t.boundStreamId;
    if (owners != null && bound != null && key != null) {
      final ownedBy = owners[bound];
      if (ownedBy == null || !ownedBy.contains(key)) {
        find('wrong_stream', {
          'tileKey': t.tileKey,
          'key': key,
          'boundStreamId': bound,
          'ownedBy': ownedBy == null ? null : (ownedBy.toList()..sort()),
        });
      }
    }
  }

  // Flowing video with nowhere to go. Only judged with the call screen open:
  // with no tiles at all nobody is looking, and the SFU sending a thumbnail
  // regardless is normal.
  final screenOpen = tiles.isNotEmpty;
  if (screenOpen) {
    final shown = {for (final t in showing) t.streamKey!};
    bool flowing(String key) => verdictOf[key]?.verdict == FlowVerdict.flowing;
    final wanted = <String>{
      if (flowing('out:video')) 'out:video',
      for (final i in sample.inbound)
        if (i.tag != 'audio' && flowing(i.key))
          // The screen wins while it flows — the tile shows it instead of the
          // camera, so the camera having no tile of its own then is by design.
          flowing('in:${i.srcId}|screen') ? 'in:${i.srcId}|screen' : 'in:${i.srcId}|video',
    };
    for (final key in wanted.toList()..sort()) {
      if (!shown.contains(key)) find('flowing_without_tile', {'key': key});
    }
  }

  return {
    'source': sample.source,
    'screenOpen': screenOpen,
    // Null, not true, with nothing on screen: no evidence is not a pass.
    // `unverified` is not a fault, so it does not fail `ok` — but it is counted,
    // so "ok with three streams unmeasured" never reads as a clean pass.
    'ok': screenOpen ? findings.where((f) => f['problem'] != 'unverified').isEmpty : null,
    'unverified': findings.where((f) => f['problem'] == 'unverified').length,
    if (!screenOpen) 'detail': 'call_screen_not_open',
    'ownersChecked': owners != null,
    'firstFrameWithinMs': firstFrameWithin.inMilliseconds,
    'findings': findings,
    'tiles': [for (final t in tiles) t.toJson()],
  };
}
