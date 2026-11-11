/// Fake hardware for `MediaCheckController`: a camera that opens (or throws the
/// plugin's own `CameraException`), a microphone whose PCM a test pushes, and a
/// player that records what it was asked to play. With these the check's whole
/// sequence runs under `flutter test`, on a machine with no camera.
library;

import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:camera/camera.dart' show CameraDescription, CameraException, CameraLensDirection;
import 'package:gather_companion/src/media/media_check_controller.dart';

import 'fake_capture_engine.dart';

const frontCam = CameraDescription(name: 'front', lensDirection: CameraLensDirection.front, sensorOrientation: 270);
const backCam = CameraDescription(name: 'back', lensDirection: CameraLensDirection.back, sensorOrientation: 90);

class FakeCheckCamera implements CheckCamera {
  FakeCheckCamera(this.description, this.log, {this.fail, this.gate});

  final CameraDescription description;
  final List<String> log;
  final CameraException? fail;

  /// When set, [initialize] waits on it — for "the screen closed mid-open".
  final Completer<void>? gate;

  bool disposed = false;
  bool paused = false;

  @override
  Future<void> initialize() async {
    log.add('init:${description.name}');
    if (gate != null) await gate!.future;
    final f = fail;
    if (f != null) throw f;
  }

  @override
  Future<void> pausePreview() async {
    log.add('pause:${description.name}');
    paused = true;
  }

  @override
  Future<void> resumePreview() async {
    log.add('resume:${description.name}');
    paused = false;
  }

  @override
  Future<void> dispose() async {
    log.add('dispose:${description.name}');
    disposed = true;
  }
}

class FakeCheckMic implements CheckMic {
  bool permission = true;
  final calls = <String>[];
  final _pcm = StreamController<Uint8List>.broadcast();

  @override
  Future<bool> hasPermission() async {
    calls.add('hasPermission');
    return permission;
  }

  @override
  Future<Stream<Uint8List>> startStream() async {
    calls.add('startStream');
    return _pcm.stream;
  }

  @override
  Future<void> pause() async => calls.add('pause');

  @override
  Future<void> resume() async => calls.add('resume');

  @override
  Future<void> dispose() async => calls.add('dispose');

  /// One chunk of constant-amplitude PCM: [amplitude] of full scale.
  void push(double amplitude, {int samples = 160}) {
    final data = ByteData(samples * 2);
    final v = (amplitude * 32767).round();
    for (var i = 0; i < samples; i++) {
      data.setInt16(i * 2, v, Endian.little);
    }
    _pcm.add(data.buffer.asUint8List());
  }
}

class FakeCheckTone implements CheckTonePlayer {
  final calls = <String>[];
  final played = <({Uint8List wav, bool speaker})>[];

  @override
  Future<void> configure() async => calls.add('configure');

  /// Thrown by the next [play], as a real player or audio session can.
  Object? failNext;

  @override
  Future<void> play(Uint8List wav, {required bool speaker}) async {
    calls.add('play(speaker: $speaker)');
    final fail = failNext;
    if (fail != null) {
      failNext = null;
      throw fail;
    }
    played.add((wav: wav, speaker: speaker));
  }

  @override
  Future<void> dispose() async => calls.add('dispose');
}

/// A [Random] whose `nextInt` always answers [value] (wrapped into range).
class FixedRandom implements Random {
  FixedRandom(this.value);
  final int value;
  @override
  int nextInt(int max) => value % max;
  @override
  double nextDouble() => 0;
  @override
  bool nextBool() => false;
}

/// Everything a test needs to build a [DeviceCheck] and look at its hardware.
class DeviceRig {
  DeviceRig({List<CameraDescription> cameras = const [frontCam, backCam]}) : cameras = [...cameras];

  List<CameraDescription> cameras;
  Object? listError;
  final log = <String>[];
  final opened = <FakeCheckCamera>[];
  final failNext = <CameraException>[];
  Completer<void>? gateNext;
  final mic = FakeCheckMic();
  final tone = FakeCheckTone();
  bool soundEffects = true;
  bool gameboy = false;
  DateTime clock = DateTime(2026, 11, 11, 10);
  int random = 0;

  DeviceCheck build() => DeviceCheck(
        listCameras: () async {
          final e = listError;
          if (e != null) throw e;
          return cameras;
        },
        openCamera: (d) {
          final cam = FakeCheckCamera(
            d,
            log,
            fail: failNext.isEmpty ? null : failNext.removeAt(0),
            gate: gateNext,
          );
          gateNext = null;
          opened.add(cam);
          return cam;
        },
        mic: mic,
        tone: tone,
        soundEffects: () => soundEffects,
        gameboyMode: () => gameboy,
        now: () => clock,
        random: FixedRandom(random),
        log: (_) {},
      );
}

/// The preview a call-pipeline check is handed, recording what it was told.
///
/// With [inner] (the widget's own binding, over a renderer whose channel the
/// test mocks) the texture setup passes through, so the widget's renderer
/// lifetime — initialise, detach, dispose — runs for real. The attach does not:
/// a fake stream is not one a real renderer can take.
class FakePreview {
  FakePreview([this.inner]);

  final PreviewBinding? inner;
  int initialized = 0;
  final attached = <Object?>[];

  PreviewBinding get binding => PreviewBinding(
        initialize: () async {
          initialized++;
          await inner?.initialize();
        },
        attach: (stream) {
          attached.add(stream);
        },
      );
}

/// A controller with fakes behind it, and the fakes.
typedef FakeMediaCheck = ({
  MediaCheckController controller,
  DeviceRig device,
  List<FakeCaptureEngine> engines,
  List<FakePreview> previews,
});

/// A controller over [DeviceRig] and a [FakeCaptureEngine]-backed pipeline.
FakeMediaCheck fakeMediaCheck({DeviceRig? device, bool widgetPreview = false}) {
  final rig = device ?? DeviceRig();
  final engines = <FakeCaptureEngine>[];
  final previews = <FakePreview>[];
  final controller = MediaCheckController(
    createDevice: rig.build,
    createPipeline: (preview) {
      final engine = FakeCaptureEngine();
      engines.add(engine);
      // The widget's binding drives a real renderer, which needs a platform
      // texture: a test with no mocked channel records in its place.
      final fake = FakePreview(widgetPreview ? preview : null);
      previews.add(fake);
      return PipelineCheck(engine: engine, preview: fake.binding);
    },
  );
  return (controller: controller, device: rig, engines: engines, previews: previews);
}
