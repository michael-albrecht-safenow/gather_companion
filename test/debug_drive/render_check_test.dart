/// `checkRender`, the wiring check behind `ext.gc.media.render` — one test per
/// row of the table in `render_check.dart`, over hand-built tile reports and
/// verdicts, so every finding is pinned without a widget or a renderer. The
/// widget path (the tiles really reporting) is `media_render_widget_test.dart`.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:gather_companion/src/debug_drive/render_check.dart';
import 'package:gather_companion/src/media/media_flow.dart';
import 'package:gather_companion/src/media/render_registry.dart';

final _t0 = DateTime.utc(2026, 11, 11, 9);

TileReport _tile(
  String key, {
  String slot = 'tile',
  String source = 'scripted',
  bool isSelf = false,
  String? srcId = 'bob',
  String? tag = 'video',
  bool showsVideo = true,
  String? tileStreamId,
  String? boundStreamId,
  bool rendered = true,
  int boundAgoMs = 5000,
}) =>
    TileReport(
      tileKey: key,
      slot: slot,
      source: source,
      isSelf: isSelf,
      srcId: isSelf ? null : srcId,
      tag: tag,
      showsVideo: showsVideo,
      tileStreamId: tileStreamId,
      boundStreamId: boundStreamId,
      boundAt: _t0.subtract(Duration(milliseconds: boundAgoMs)),
      updatedAt: _t0,
      firstFrameAt: rendered ? _t0.subtract(Duration(milliseconds: boundAgoMs - 100)) : null,
    );

InboundFlow _in(String srcId, String tag) =>
    InboundFlow(srcId: srcId, tag: tag, paused: false, rowFound: true, counters: const InboundCounters());

StreamVerdict _v(String key, FlowVerdict verdict) {
  final out = key.startsWith('out:');
  final [srcId, tag] = out ? [null, key.substring(4)] : key.substring(3).split('|');
  return StreamVerdict(key: key, direction: out ? 'outbound' : 'inbound', srcId: srcId, tag: tag!, verdict: verdict);
}

MediaFlowSample _sample({List<InboundFlow> inbound = const [], List<OutboundFlow> outbound = const []}) =>
    MediaFlowSample(at: _t0, source: 'scripted', inbound: inbound, outbound: outbound);

List<String> _problems(Map<String, Object?> result) =>
    [for (final f in (result['findings']! as List).cast<Map<String, Object?>>()) f['problem']! as String];

void main() {
  final bobVideo = _sample(inbound: [_in('bob', 'audio'), _in('bob', 'video')]);
  final flowing = [_v('in:bob|audio', FlowVerdict.flowing), _v('in:bob|video', FlowVerdict.flowing)];

  test('one tile on a flowing stream that rendered: ok, no findings', () {
    final r = checkRender(tiles: [_tile('t1')], sample: bobVideo, verdicts: flowing, now: _t0);
    expect(r['ok'], isTrue);
    expect(r['screenOpen'], isTrue);
    expect(r['findings'], isEmpty);
    expect(r['ownersChecked'], isFalse);
  });

  test('no tiles at all: screen closed, ok is null, nothing flagged as unshown', () {
    final r = checkRender(tiles: const [], sample: bobVideo, verdicts: flowing, now: _t0);
    expect(r['screenOpen'], isFalse);
    expect(r['ok'], isNull);
    expect(r['detail'], 'call_screen_not_open');
    expect(r['findings'], isEmpty);
  });

  test('flowing video with no tile showing it', () {
    // The only tile on screen is somebody else's avatar.
    final r = checkRender(
      tiles: [_tile('t0', srcId: 'carol', showsVideo: false, tag: null)],
      sample: bobVideo,
      verdicts: flowing,
      now: _t0,
    );
    expect(_problems(r), ['flowing_without_tile']);
    expect((r['findings']! as List).single, containsPair('key', 'in:bob|video'));
    expect(r['ok'], isFalse);
  });

  test('a peer sharing their screen: the screen wants the tile, the camera does not', () {
    final sample = _sample(inbound: [_in('bob', 'video'), _in('bob', 'screen')]);
    final verdicts = [_v('in:bob|video', FlowVerdict.flowing), _v('in:bob|screen', FlowVerdict.flowing)];
    expect(
      _problems(checkRender(tiles: [_tile('t1', tag: 'screen')], sample: sample, verdicts: verdicts, now: _t0)),
      isEmpty,
    );
    expect(
      _problems(checkRender(tiles: [_tile('t1', tag: 'video')], sample: sample, verdicts: verdicts, now: _t0)),
      ['flowing_without_tile'],
      reason: 'showing the camera while the screen flows leaves the screen unshown',
    );
  });

  test('your own camera flowing out with no self tile showing it', () {
    final sample = _sample(outbound: [const OutboundFlow(tag: 'video', paused: false, rowFound: true)]);
    final verdicts = [_v('out:video', FlowVerdict.flowing)];
    expect(
      _problems(checkRender(tiles: [_tile('self', isSelf: true)], sample: sample, verdicts: verdicts, now: _t0)),
      isEmpty,
    );
    expect(
      _problems(checkRender(
        tiles: [_tile('self', isSelf: true, showsVideo: false, tag: null)],
        sample: sample,
        verdicts: verdicts,
        now: _t0,
      )),
      ['flowing_without_tile'],
    );
  });

  test('a tile on a stream the sample has no consumer for', () {
    final r = checkRender(tiles: [_tile('t1', srcId: 'dave')], sample: bobVideo, verdicts: flowing, now: _t0);
    expect(_problems(r), containsAll(['bound_not_present', 'flowing_without_tile']));
  });

  test('a tile on a stalled, paused or missing stream: a frozen frame shown as live', () {
    for (final verdict in [FlowVerdict.stalled, FlowVerdict.paused, FlowVerdict.missing]) {
      final r = checkRender(
        tiles: [_tile('t1')],
        sample: bobVideo,
        verdicts: [_v('in:bob|video', verdict)],
        now: _t0,
      );
      expect(_problems(r), ['bound_not_flowing'], reason: verdict.wire);
      expect((r['findings']! as List).single, containsPair('verdict', verdict.wire));
    }
  });

  test('a tile on an unmeasured stream is unverified — counted, but not a failure', () {
    final r = checkRender(
      tiles: [_tile('t1')],
      sample: bobVideo,
      verdicts: [_v('in:bob|video', FlowVerdict.notMeasured)],
      now: _t0,
    );
    expect(_problems(r), ['unverified']);
    expect(r['ok'], isTrue);
    expect(r['unverified'], 1);
  });

  test('two tiles in one slot on one stream; big plus strip is by design', () {
    expect(
      _problems(checkRender(tiles: [_tile('a'), _tile('b')], sample: bobVideo, verdicts: flowing, now: _t0)),
      ['duplicate_tiles'],
    );
    expect(
      _problems(checkRender(tiles: [_tile('a'), _tile('b', slot: 'big')], sample: bobVideo, verdicts: flowing, now: _t0)),
      isEmpty,
    );
  });

  test('a tile that never rendered a frame, once the grace has passed', () {
    final young = _tile('t1', rendered: false, boundAgoMs: 1000);
    final old = _tile('t1', rendered: false, boundAgoMs: 4000);
    expect(_problems(checkRender(tiles: [young], sample: bobVideo, verdicts: flowing, now: _t0)), isEmpty);
    final r = checkRender(tiles: [old], sample: bobVideo, verdicts: flowing, now: _t0);
    expect(_problems(r), ['never_rendered']);
    expect((r['findings']! as List).single, containsPair('boundForMs', 4000));
  });

  group('live tiles', () {
    test('a renderer that missed its re-attach is a stale binding', () {
      final stale = _tile('t1', source: 'live', tileStreamId: 's-bob', boundStreamId: 's-alice');
      final r = checkRender(tiles: [stale], sample: bobVideo, verdicts: flowing, now: _t0);
      expect(_problems(r), ['stale_binding']);
    });

    test('an avatar tile still holding a stream is a stale binding; one holding none is fine', () {
      final holding = _tile('t1', source: 'live', showsVideo: false, tileStreamId: 's-bob', boundStreamId: 's-bob');
      final released = _tile('t1', source: 'live', showsVideo: false, tileStreamId: 's-bob');
      final quiet = [_v('in:bob|video', FlowVerdict.paused)];
      expect(_problems(checkRender(tiles: [holding], sample: bobVideo, verdicts: quiet, now: _t0)), ['stale_binding']);
      expect(_problems(checkRender(tiles: [released], sample: bobVideo, verdicts: quiet, now: _t0)), isEmpty);
    });

    test("bound to a stream the call's books give to someone else is a wrong stream", () {
      final owners = {
        's-bob': {'in:bob|video'},
        's-alice': {'in:alice|video'},
      };
      final right = _tile('t1', source: 'live', tileStreamId: 's-bob', boundStreamId: 's-bob');
      final wrong = _tile('t1', source: 'live', tileStreamId: 's-alice', boundStreamId: 's-alice');
      final unknown = _tile('t1', source: 'live', tileStreamId: 's-ghost', boundStreamId: 's-ghost');

      final ok = checkRender(tiles: [right], sample: bobVideo, verdicts: flowing, now: _t0, owners: owners);
      expect(_problems(ok), isEmpty);
      expect(ok['ownersChecked'], isTrue);

      final r = checkRender(tiles: [wrong], sample: bobVideo, verdicts: flowing, now: _t0, owners: owners);
      expect(_problems(r), ['wrong_stream']);
      expect((r['findings']! as List).single, containsPair('ownedBy', ['in:alice|video']));

      final u = checkRender(tiles: [unknown], sample: bobVideo, verdicts: flowing, now: _t0, owners: owners);
      expect(_problems(u), ['wrong_stream']);
      expect((u['findings']! as List).single, containsPair('ownedBy', isNull));
    });

    test('scripted tiles are never judged on stream ids', () {
      final scripted = _tile('t1', tileStreamId: 'x', boundStreamId: 'y');
      expect(
        _problems(checkRender(tiles: [scripted], sample: bobVideo, verdicts: flowing, now: _t0, owners: const {})),
        isEmpty,
      );
    });
  });

  group('RenderRegistry', () {
    test('bind, claim, first frame, resize, unbind', () {
      var now = _t0;
      final reg = RenderRegistry(now: () => now);
      final key = reg.nextKey('tile:bob');
      expect(reg.nextKey('tile:bob'), isNot(key), reason: 'keys are never reused');

      reg.bind(tileKey: key, slot: 'tile', source: 'live', isSelf: false, showsVideo: true, srcId: 'bob', tag: 'video', tileStreamId: 's1', boundStreamId: 's1');
      expect(reg.tiles.single.firstFrameRendered, isFalse);
      expect(reg.tiles.single.streamKey, 'in:bob|video');

      now = now.add(const Duration(milliseconds: 300));
      reg
        ..firstFrame(key)
        ..resize(key, width: 640, height: 360);
      final t = reg.tiles.single;
      expect(t.firstFrameAt, now);
      expect((t.videoWidth, t.videoHeight), (640, 360));

      // A claim moves what the tile was told, never what it is bound to.
      reg.claim(key, srcId: 'bob', tag: 'video', showsVideo: true, tileStreamId: 's2');
      expect(reg.tiles.single.tileStreamId, 's2');
      expect(reg.tiles.single.boundStreamId, 's1');
      expect(reg.tiles.single.firstFrameRendered, isTrue);

      // A re-bind resets the first frame, as the native renderer does.
      reg.bind(tileKey: key, slot: 'tile', source: 'live', isSelf: false, showsVideo: true, srcId: 'bob', tag: 'video', tileStreamId: 's2', boundStreamId: 's2');
      expect(reg.tiles.single.firstFrameRendered, isFalse);

      reg.unbind(key);
      expect(reg.tiles, isEmpty);
      reg.firstFrame(key); // a late callback after the tile went: ignored
      expect(reg.tiles, isEmpty);
    });
  });
}
