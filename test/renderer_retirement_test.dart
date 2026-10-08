/// The renderer-retirement lifecycle, guarded against a regression to the
/// synchronous disposal that crashed the app on tile swaps (#21).
///
/// The full [CallScreen] tests swap the real video tile for an inert stand-in
/// (`call_screen_test.dart`) because `RTCVideoRenderer.initialize()` needs a
/// `MethodChannel` that does not exist under `flutter test`. That means nothing
/// there exercises either disposal path, so a revert to inline `dispose()` would
/// pass every one of those tests. These tests mock the `FlutterWebRTC.Method`
/// channel and drive [retireRenderer] directly, which is where the detach /
/// drain / dispose ordering lives.
///
/// This guards the Dart lifecycle only; that the half-second delay actually
/// outruns the native frame backlog still needs device validation.
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:gather_companion/ui/call_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('FlutterWebRTC.Method');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  // Every `createVideoRenderer` hands back a fresh texture id, so a test with
  // several renderers can tell their dispose calls apart.
  var nextTextureId = 1;

  // The texture ids passed to each `videoRendererDispose`, in order, so a test
  // can assert how many times — and for which renderer — the native dispose ran.
  late List<int> disposed;

  // Every method name the channel saw since the last `clearCalls`, so a test can
  // assert that detachment happened and that disposal had not yet.
  late List<String> calls;

  void clearCalls() => calls.clear();

  setUp(() {
    nextTextureId = 1;
    disposed = [];
    calls = [];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'createVideoRenderer':
          return {'textureId': nextTextureId++};
        case 'videoRendererDispose':
          final args = call.arguments as Map;
          disposed.add(args['textureId'] as int);
          return null;
        default:
          return null;
      }
    });
  });

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  Future<RTCVideoRenderer> initRenderer() async {
    final renderer = RTCVideoRenderer();
    await renderer.initialize();
    return renderer;
  }

  test('detaches the stream at once but holds disposal past the drain delay',
      () async {
    final renderer = await initRenderer();
    clearCalls();

    final retired = retireRenderer(renderer);
    // `srcObject = null` is a synchronous setter that fires its platform call on
    // the next microtask — detachment is immediate, not deferred with disposal.
    await Future<void>.value();
    expect(calls, contains('videoRendererSetSrcObject'),
        reason: 'the stream is detached the moment the tile goes');
    expect(calls, isNot(contains('videoRendererDispose')),
        reason: 'the texture must outlive the native frame backlog');

    // Well short of the 500ms drain: still alive.
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(disposed, isEmpty,
        reason: 'disposing this early is the crash the delay exists to avoid');

    await retired;
    expect(disposed, hasLength(1), reason: 'and then freed, exactly once');
  });

  test('frees every swapped-out renderer exactly once', () async {
    // Stands in for a run of spotlight swaps and a route teardown: several tiles
    // retired, some overlapping. Each renderer must be disposed once and no more.
    final renderers = [
      await initRenderer(),
      await initRenderer(),
      await initRenderer(),
    ];
    final ids = renderers.map((r) => r.textureId).toList();
    clearCalls();

    await Future.wait(renderers.map(retireRenderer));

    for (final id in ids) {
      expect(disposed.where((d) => d == id), hasLength(1),
          reason: 'renderer $id disposed exactly once');
    }
  });
}
