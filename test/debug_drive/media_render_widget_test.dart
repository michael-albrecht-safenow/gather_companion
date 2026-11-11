/// `ext.gc.media.render` end to end in a widget test: a real [CallScreen] over a
/// [ScriptedCall], its tiles built by the harness's own [demoFootageTile] (the
/// builder `debugCallTileBuilder` is set to in the simulator), reporting into
/// the real [renderRegistry] — then the drive asked, through the registry, what
/// is on screen.
///
/// The real `_VideoTile` cannot be built here (its renderer needs a platform
/// channel; see `call_screen_test.dart`), so its report path is the one thing
/// not exercised: these pin the registry, the slot, the harness reporter and
/// the cross-check together. The stream-id checks (`stale_binding`,
/// `wrong_stream`) are live-only and pinned in `render_check_test.dart`.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gather_companion/harness/demo_footage.dart';
import 'package:gather_companion/harness/scripted_call.dart';
import 'package:gather_companion/src/app_state.dart';
import 'package:gather_companion/src/debug_drive/debug_drive.dart';
import 'package:gather_companion/src/debug_drive/install.dart';
import 'package:gather_companion/src/media/call.dart';
import 'package:gather_companion/src/media/media_log.dart';
import 'package:gather_companion/src/media/render_registry.dart';
import 'package:gather_companion/theme/gather_theme.dart';
import 'package:gather_companion/ui/call_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'drive_test_support.dart';

/// A clock the drive's sleep advances, shared with the [ScriptedCall] and the
/// registry so "bound for how long" and the flow intervals agree.
class _Clock {
  DateTime now = DateTime.utc(2026, 11, 11, 9);
  Future<void> sleep(Duration d) async => now = now.add(d);
}

const _bobAndCarol = CallState(participants: [
  CallParticipant(srcId: 'bob', hasAudio: true, hasVideo: true),
  CallParticipant(srcId: 'carol', hasAudio: true),
]);

void main() {
  late _Clock clock;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    clock = _Clock();
    renderRegistry.debugReset(now: () => clock.now);
  });
  tearDown(() {
    renderRegistry.debugReset(now: DateTime.now);
    mediaLogDebugSink = null;
  });

  Future<({DebugDrive drive, ScriptedCall call})> show(
    WidgetTester tester, {
    CallState state = _bobAndCarol,
    CallTileBuilder buildTile = demoFootageTile,
  }) async {
    final app = AppState();
    final call = ScriptedCall(now: () => clock.now)..emit(state);
    app.debugAttachCall(call);
    final drive = installDebugDrive(
      enabled: true,
      app: app,
      boot: 'harness',
      register: RecordingRegistrar().call,
      mediaSleep: clock.sleep,
    )!;
    await tester.pumpWidget(MaterialApp(
      theme: buildGatherTheme(),
      home: CallScreen(state: app, buildTile: buildTile),
    ));
    await tester.pump();
    return (drive: drive, call: call);
  }

  Future<Map<String, Object?>> render(DebugDrive drive, [String? args]) async {
    final body = resultOf(await drive.invoke('ext.gc.media.render', args));
    expect(body['ok'], isTrue, reason: '$body');
    return (body['data']! as Map).cast<String, Object?>();
  }

  List<Map<String, Object?>> tiles(Map<String, Object?> data) => (data['tiles']! as List).cast<Map<String, Object?>>();
  List<String> problems(Map<String, Object?> data) =>
      [for (final f in (data['findings']! as List).cast<Map<String, Object?>>()) f['problem']! as String];

  testWidgets('no call: refused no_call', (tester) async {
    final drive = installDebugDrive(enabled: true, app: AppState(), boot: 'harness', register: RecordingRegistrar().call)!;
    expect(resultOf(await drive.invoke('ext.gc.media.render')), {'ok': false, 'reason': 'no_call'});
  });

  testWidgets('the harness tiles report themselves, bound and with a first frame, and line up', (tester) async {
    final (:drive, call: _) = await show(tester);
    final data = await render(drive);

    expect(data['source'], 'scripted');
    expect(data['screenOpen'], isTrue);
    expect(data['ownersChecked'], isFalse, reason: 'no MediaStreams in the harness');
    expect(problems(data), isEmpty);
    expect(data['ok'], isTrue);

    final bob = tiles(data).singleWhere((t) => t['srcId'] == 'bob');
    expect(bob, containsPair('key', 'in:bob|video'));
    expect(bob, containsPair('source', 'scripted'));
    expect(bob, containsPair('slot', 'tile'));
    expect(bob['showsVideo'], isTrue);
    expect(bob['firstFrameRendered'], isTrue);
    expect(bob['videoWidth'], isA<int>());

    // Carol sends no video: the stand-in card is painted for the eye, but the
    // report says what the wire carries — no video — so it is not "bound".
    final carol = tiles(data).singleWhere((t) => t['srcId'] == 'carol');
    expect(carol['showsVideo'], isFalse);
    expect(carol.containsKey('key'), isFalse);

    // Yourself, camera off: an avatar, reported as such.
    final self = tiles(data).singleWhere((t) => t['isSelf'] == true);
    expect(self['showsVideo'], isFalse);
  });

  testWidgets('tiles unbind when the screen goes', (tester) async {
    await show(tester);
    expect(renderRegistry.tiles, isNotEmpty);
    await tester.pumpWidget(const SizedBox());
    expect(renderRegistry.tiles, isEmpty);
  });

  testWidgets('a tile bound to the wrong stream is caught, and so is the stream left unshown', (tester) async {
    // Bob's tile claims his screen — a stream he is not sending — the shape of a
    // tile keyed to the wrong srcId|tag.
    Widget miswired(BuildContext context, CallTile tile) {
      final frame = demoFootageTile(context, tile);
      if (tile.srcId != 'bob') return frame;
      return ScriptedTileReporter(tile: tile, streamTag: 'screen', child: TileFrame(tile: tile));
    }

    final (:drive, call: _) = await show(tester, buildTile: miswired);
    final data = await render(drive);
    expect(problems(data), unorderedEquals(['bound_not_present', 'flowing_without_tile']));
    expect(data['ok'], isFalse);
    final findings = (data['findings']! as List).cast<Map<String, Object?>>();
    expect(findings.singleWhere((f) => f['problem'] == 'bound_not_present'), containsPair('key', 'in:bob|screen'));
    expect(findings.singleWhere((f) => f['problem'] == 'flowing_without_tile'), containsPair('key', 'in:bob|video'));
  });

  testWidgets('a tile that never puts up a frame is flagged once the grace has run', (tester) async {
    Widget black(BuildContext context, CallTile tile) => tile.srcId == 'bob'
        ? ScriptedTileReporter(tile: tile, firstFrame: false, child: TileFrame(tile: tile))
        : demoFootageTile(context, tile);

    final (:drive, call: _) = await show(tester, buildTile: black);
    // The snapshot window (2 s on the shared clock) is inside a 3 s grace...
    expect(problems(await render(drive)), isEmpty);
    // ...and the next check, 2 s later still, is past it.
    final data = await render(drive);
    expect(problems(data), ['never_rendered']);
    expect((data['findings']! as List).single, containsPair('key', 'in:bob|video'));
    expect(tiles(data).singleWhere((t) => t['srcId'] == 'bob')['firstFrameRendered'], isFalse);
  });

  testWidgets('a stalled stream under a live-looking tile is a frozen frame', (tester) async {
    final (:drive, :call) = await show(tester);
    call.flowFaults['in:bob|video'] = ScriptedFlowFault.stall;
    final data = await render(drive, '{"windowMs":3000}');
    expect(problems(data), ['bound_not_flowing']);
    expect((data['findings']! as List).single, containsPair('verdict', 'stalled'));
  });

  testWidgets('the spotlight shows a face twice, big and in the strip, and that is no duplicate', (tester) async {
    final (:drive, call: _) = await show(tester);
    // Tap Bob's tile to enlarge him — found by its key (no roster row, so his
    // tile id is his srcId), and tapped near its top edge: in the 800×600 test
    // surface the lower part of a grid tile sits behind the dock.
    await tester.tapAt(tester.getTopLeft(find.byKey(const ValueKey('bob'))) + const Offset(20, 20));
    // The footage's own double-tap (fit toggle) holds the single tap in the
    // gesture arena until the double-tap window has passed.
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(find.byKey(const ValueKey('big-bob')), findsOneWidget);

    final data = await render(drive);
    final bobs = tiles(data).where((t) => t['srcId'] == 'bob').toList();
    expect(bobs.map((t) => t['slot']), unorderedEquals(['big', 'tile']));
    expect(problems(data), isEmpty);
  });
}
