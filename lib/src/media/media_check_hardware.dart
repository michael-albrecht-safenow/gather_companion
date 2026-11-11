/// The plugin-backed halves of the device check's seams
/// (`media_check_controller.dart`): the `camera` plugin, `record`,
/// `audioplayers` and the real [WebrtcMediaEngine], wired the exact way the
/// screen wired them before the logic moved out of it.
///
/// Kept in a file of its own so the controller's decisions can be tested with
/// fakes, and so the two stances that keep the iOS audio session calm — the
/// recorder's config and the chime's audio context — sit next to the plugins
/// they configure rather than in a widget. The reasons those stances are what
/// they are are in `lib/ui/media_check_screen.dart`'s header; changing either
/// without reading it revives the category thrash that froze the screen.
library;

import 'package:audioplayers/audioplayers.dart';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:record/record.dart';

import 'media_check_controller.dart';
import 'webrtc_media_engine.dart';

/// The test sound's session in **Device** mode, pinned to the recorder's stance.
///
/// `playAndRecord` with `mixWithOthers` so the chime rides alongside the live
/// microphone capture rather than interrupting it, and `defaultToSpeaker` when the
/// speaker route is chosen so it comes out where a desk companion wants it. Here
/// `record` owns the session and there is no WebRTC to reassert a competing
/// category, so the route the toggle picks is the route that takes.
AudioContext deviceToneContext({required bool speaker}) => AudioContext(
      iOS: AudioContextIOS(
        category: AVAudioSessionCategory.playAndRecord,
        options: {
          AVAudioSessionOptions.mixWithOthers,
          AVAudioSessionOptions.allowBluetooth,
          if (speaker) AVAudioSessionOptions.defaultToSpeaker,
        },
      ),
      android: const AudioContextAndroid(
        contentType: AndroidContentType.sonification,
        usageType: AndroidUsageType.voiceCommunication,
        audioFocus: AndroidAudioFocus.gainTransientMayDuck,
      ),
    );

// Call pipeline mode has no test sound: a chime would need audioplayers to
// reconfigure the AVAudioSession the engine owns, which revives the category
// thrash that froze the screen. The speaker test lives in Device mode, where
// nothing else is holding the session.

/// How the microphone is captured for the meter: raw signed-16-bit PCM, mono, at
/// a rate that is plenty to tell speech from silence and cheap to carry. The
/// audio processing flags are off on purpose — the test should show the real
/// input, not a gated, gain-ridden version of it — and `mixWithOthers` lets the
/// test sound play without stealing the session out from under the capture.
const meterRecordConfig = RecordConfig(
  encoder: AudioEncoder.pcm16bits,
  sampleRate: 16000,
  numChannels: 1,
  autoGain: false,
  echoCancel: false,
  noiseSuppress: false,
  iosConfig: IosRecordConfig(
    categoryOptions: [
      IosAudioCategoryOption.mixWithOthers,
      IosAudioCategoryOption.allowBluetooth,
    ],
  ),
);

/// A `camera` plugin controller, opened **`enableAudio: false`** — the whole
/// point: it keeps the camera off the audio session so the microphone meter can
/// own it without a fight.
class PluginCheckCamera implements CheckCamera {
  PluginCheckCamera(CameraDescription camera)
      : controller = CameraController(camera, ResolutionPreset.medium, enableAudio: false);

  /// What the preview widget draws.
  final CameraController controller;

  @override
  Future<void> initialize() => controller.initialize();

  @override
  Future<void> pausePreview() => controller.pausePreview();

  @override
  Future<void> resumePreview() => controller.resumePreview();

  @override
  Future<void> dispose() => controller.dispose();
}

/// `record`'s [AudioRecorder], streaming [meterRecordConfig].
class RecorderCheckMic implements CheckMic {
  final _recorder = AudioRecorder();

  @override
  Future<bool> hasPermission() => _recorder.hasPermission();

  @override
  Future<Stream<Uint8List>> startStream() => _recorder.startStream(meterRecordConfig);

  @override
  Future<void> pause() => _recorder.pause();

  @override
  Future<void> resume() => _recorder.resume();

  @override
  Future<void> dispose() => _recorder.dispose();
}

/// `audioplayers`, applying the route per tap so the Speaker/Earpiece choice
/// always wins: the recorder's session may have been the last to set the
/// category, and there is no WebRTC to flap it, so one deliberate set per tap is
/// correct and cheap.
class PlayerCheckTone implements CheckTonePlayer {
  final _player = AudioPlayer();

  @override
  Future<void> configure() => _player.setReleaseMode(ReleaseMode.stop);

  @override
  Future<void> play(Uint8List wav, {required bool speaker}) async {
    await AudioPlayer.global.setAudioContext(deviceToneContext(speaker: speaker));
    await _player.play(BytesSource(wav, mimeType: 'audio/wav'));
  }

  @override
  Future<void> dispose() => _player.dispose();
}

/// The controller the screen runs on a device: real plugins in both modes.
/// [soundEffects] and [gameboyMode] are read when the chime fires.
MediaCheckController hardwareMediaCheck({
  required bool Function() soundEffects,
  required bool Function() gameboyMode,
}) =>
    MediaCheckController(
      createDevice: () => DeviceCheck(
        listCameras: availableCameras,
        openCamera: PluginCheckCamera.new,
        mic: RecorderCheckMic(),
        tone: PlayerCheckTone(),
        soundEffects: soundEffects,
        gameboyMode: gameboyMode,
      ),
      createPipeline: (preview) => PipelineCheck(
        engine: WebrtcMediaEngine(log: debugPrint),
        preview: preview,
      ),
    );
