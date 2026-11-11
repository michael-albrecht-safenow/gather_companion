/// The device check's decisions, out of the widget that draws it (plan task
/// 4.2).
///
/// `lib/ui/media_check_screen.dart` used to hold all of this in two `State`
/// classes: which mode is on, the start sequence (list cameras → pick the front
/// one → open it → start the meter, which never holds the camera hostage), the
/// three-way failure split, what a lifecycle change does to the camera, when the
/// "we can hear you" light flips, which chime a tap plays. None of it is
/// presentation, and while it lived in `State` the only way to check it was a
/// device and a pair of eyes — a debug-drive handler that needed it would have
/// had to reach into a widget, which the drive's rules call the signal that the
/// logic is in the wrong layer. So it lives here, and the widget keeps what is
/// genuinely its own: the `RTCVideoRenderer` and its texture, the camera preview
/// it draws, and forwarding the app lifecycle.
///
/// ## Shape
///
/// [MediaCheckController] is the screen: the mode, and whichever check is open.
/// A check is one of two [MediaCheck]s (sealed, so a readout switches over them
/// exhaustively):
///
///  - [DeviceCheck] — the `camera` plugin plus `record`, the lightest path.
///  - [PipelineCheck] — the real capture engine, the WebRTC path a call uses.
///
/// Each is a `ChangeNotifier` of its own, so a toggle redraws only its half.
///
/// ## Why the checks are opened by the widgets, not by [MediaCheckController.setMode]
///
/// The whole point of two modes is that the two frameworks never hold the iOS
/// audio session at once (the screen's header has the device syslog). That
/// depends on a teardown order the widget tree already gets right: switching
/// mode unmounts the old child, whose `dispose` clears its renderer's
/// `srcObject` *before* the engine stops the tracks under it. If the controller
/// disposed the old check on [MediaCheckController.setMode] itself, the engine
/// would stop the tracks while the old renderer was still mounted and bound for
/// one more frame. So [MediaCheckController.setMode] only changes the mode; the
/// child widget opens its check in `initState` ([MediaCheckController.openDevice]
/// / [MediaCheckController.openPipeline]) and releases it in `dispose`
/// ([MediaCheckController.release]) after its own renderer has let go — the
/// same frame, the same order, as when it was all in `State`.
///
/// ## Seams
///
/// Everything that touches hardware is behind a small interface here
/// ([CheckCamera], [CheckMic], [CheckTonePlayer], the [CaptureEngine] factory,
/// the [PreviewBinding] the widget hands in), with the plugin-backed
/// implementations in `media_check_hardware.dart`. A clock and a [Random] are
/// injected too, so the voice-activity light and the chime choice are
/// deterministic under `flutter test`, on a machine with no camera.
///
/// ## The drive hook
///
/// [mediaCheckDebugActive] is the controller of the screen on display, for the
/// `mediaCheck.*` drive actions. Same shape as `renderRegistry`: a plain field
/// carrying no `ext.gc.` name, written by the screen **only inside
/// `if (kDebugMode)`**, so a release build drops the writes and nothing reads it.
library;

import 'dart:async';
import 'dart:math';

import 'package:camera/camera.dart' show CameraDescription, CameraException, CameraLensDirection;
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_webrtc/flutter_webrtc.dart' show MediaStream;

import 'capture_engine.dart';
import 'gameboy_sfx.dart';
import 'media_engine.dart';
import 'mic_level.dart';
import 'test_tone.dart';
import 'voice_activity.dart';

/// Which of the two checks is on screen.
enum MediaCheckMode { device, callPipeline }

/// What can be wrong with the camera, kept distinct because the fixes differ.
///
/// A denied permission is fixed in Settings and nowhere else; "no camera on this
/// device" cannot be fixed at all; anything else is worth a retry. Rendering all
/// three as one spinner is the bug `lib/ui/AGENTS.md` warns about.
enum MediaCheckProblem { permission, noCamera, other }

/// What [DeviceCheck.playTone] did. Three ways, not a bool, because "the Sound
/// effects switch kept it quiet" and "the player threw" are both "no sound", and
/// only the first is the user's choice — a drive that folded the second into
/// success would report a chime nobody heard.
enum ToneOutcome { silenced, played, failed }

@immutable
class MediaCheckFailure {
  const MediaCheckFailure(this.problem, this.message);

  /// From the engine's own failure, so the call-pipeline mode draws the same
  /// three-way split as the device mode off one shared type.
  factory MediaCheckFailure.fromMedia(MediaFailure failure) => MediaCheckFailure(
        failure.needsSettings ? MediaCheckProblem.permission : MediaCheckProblem.other,
        failure.message,
      );

  final MediaCheckProblem problem;
  final String message;

  /// A refused permission is the one problem fixed in Settings rather than here.
  bool get needsSettings => problem == MediaCheckProblem.permission;

  /// What the "Try again" button would do something about: anything but a
  /// refused permission.
  bool get retryable => !needsSettings;

  Map<String, Object?> toJson() => {
        'problem': problem.name,
        'message': message,
        'needsSettings': needsSettings,
        'retryable': retryable,
      };
}

// ---------------------------------------------------------------------------
// Hardware seams.
// ---------------------------------------------------------------------------

/// One opened camera, as the device check drives it. The plugin version also
/// hands the widget the `CameraController` it draws.
abstract class CheckCamera {
  /// Throws [CameraException] when the camera will not open.
  Future<void> initialize();
  Future<void> pausePreview();
  Future<void> resumePreview();
  Future<void> dispose();
}

/// The microphone, opened for a meter and nothing else.
abstract class CheckMic {
  Future<bool> hasPermission();

  /// Raw signed-16-bit little-endian PCM, mono.
  Future<Stream<Uint8List>> startStream();
  Future<void> pause();
  Future<void> resume();
  Future<void> dispose();
}

/// The speaker test's player.
abstract class CheckTonePlayer {
  /// Stop (not loop or release) when a sound ends.
  Future<void> configure();

  /// Plays [wav] out of the loudspeaker when [speaker], else the earpiece.
  Future<void> play(Uint8List wav, {required bool speaker});
  Future<void> dispose();
}

/// What the call-pipeline widget lends its check: the renderer's one-time
/// texture setup, and where to point it once a capture is open.
class PreviewBinding {
  const PreviewBinding({required this.initialize, required this.attach});

  final Future<void> Function() initialize;
  final void Function(MediaStream? stream) attach;
}

/// The controller of the device check on display, for the drive. Written only
/// inside `if (kDebugMode)`; see the file header.
MediaCheckController? mediaCheckDebugActive;

// ---------------------------------------------------------------------------
// The screen.
// ---------------------------------------------------------------------------

/// The screen: which mode is on, and the check that is open.
class MediaCheckController extends ChangeNotifier {
  MediaCheckController({
    required this._createDevice,
    required this._createPipeline,
    this._mode = MediaCheckMode.device,
  });

  final DeviceCheck Function() _createDevice;
  final PipelineCheck Function(PreviewBinding preview) _createPipeline;

  MediaCheckMode _mode;
  MediaCheckMode get mode => _mode;

  MediaCheck? _check;

  /// The check that is open, or null between a child's release and the next
  /// one's open (and after the screen is gone).
  MediaCheck? get check => _check;

  bool _disposed = false;

  /// Picks the mode. The widget swaps its child on the notification, and the
  /// child's lifecycle opens and releases the checks (see the header).
  void setMode(MediaCheckMode mode) {
    if (_disposed) return;
    _mode = mode;
    notifyListeners();
  }

  /// Opens and starts a device check, as the current one. Called from the
  /// device child's `initState`; does not notify, since that is mid-build.
  DeviceCheck openDevice() {
    final check = _createDevice();
    _check = check;
    check.start();
    return check;
  }

  /// Opens and starts a call-pipeline check drawing into [preview], as the
  /// current one. Called from the pipeline child's `initState`.
  PipelineCheck openPipeline(PreviewBinding preview) {
    final check = _createPipeline(preview);
    _check = check;
    check.start();
    return check;
  }

  /// Tears [check] down. Called from the child's `dispose`, after its renderer
  /// has let go. A release of a check that is no longer current (the new
  /// child's `initState` runs before the old one's `dispose`) leaves the
  /// current one alone.
  void release(MediaCheck check) {
    if (identical(_check, check)) _check = null;
    check.dispose();
  }

  /// The readout `mediaCheck.status` returns.
  Map<String, Object?> status() => {
        'mode': _mode.name,
        'check': _check?.status(),
      };

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// One of the two checks.
sealed class MediaCheck extends ChangeNotifier {
  MediaCheckMode get mode;

  /// Whether the start sequence is still running.
  bool get starting;

  /// What went wrong, or null.
  MediaCheckFailure? get failure;

  /// Runs the start sequence. Called once by the controller on open.
  Future<void> start();

  /// What "Try again" does: back to starting, failure cleared, run again.
  Future<void> retry();

  Future<void> setMicLive(bool live);
  Future<void> setVideoOn(bool on);
  Future<void> switchCamera();

  bool get micLive;
  bool get videoOn;
  bool get frontCamera;
  bool get canSwitch;

  /// Whether the mic/camera controls are on screen at all.
  bool get showControls;

  Map<String, Object?> status();
}

// ---------------------------------------------------------------------------
// Device mode: camera plugin + record. No WebRTC, no audio-session fight.
// ---------------------------------------------------------------------------

/// The camera plugin for the preview, `record` for a live "we can hear you"
/// light, and a chime out of the chosen route.
final class DeviceCheck extends MediaCheck {
  DeviceCheck({
    required this._listCameras,
    required CheckCamera Function(CameraDescription camera) openCamera,
    required this._mic,
    required this._tone,
    required this._soundEffects,
    required this._gameboyMode,
    DateTime Function()? now,
    Random? random,
    void Function(String line)? log,
  })  : _cameraFactory = openCamera,
        _now = now ?? DateTime.now,
        _rng = random ?? Random(),
        _log = log ?? debugPrint;

  final Future<List<CameraDescription>> Function() _listCameras;
  final CheckCamera Function(CameraDescription camera) _cameraFactory;
  final CheckMic _mic;
  final CheckTonePlayer _tone;
  final bool Function() _soundEffects;
  final bool Function() _gameboyMode;
  final DateTime Function() _now;
  final Random _rng;
  final void Function(String line) _log;

  List<CameraDescription> _cameras = const [];
  CheckCamera? _camera;
  int _cameraIndex = 0;

  StreamSubscription<Uint8List>? _micSub;
  final _voice = VoiceActivity();

  bool _micLive = true;
  bool _speaker = true;
  bool _videoOn = true;
  bool _hearing = false;

  bool _starting = true;
  MediaCheckFailure? _failure;

  bool _disposed = false;
  int _tonesPlayed = 0;

  @override
  MediaCheckMode get mode => MediaCheckMode.device;

  /// The opened camera, for the widget to draw; null while none is open.
  CheckCamera? get camera => _camera;

  List<CameraDescription> get cameras => _cameras;

  @override
  bool get starting => _starting;

  @override
  MediaCheckFailure? get failure => _failure;

  @override
  bool get micLive => _micLive;

  /// The meter's answer: live and hearing you.
  bool get hearing => _hearing;

  /// Which way the test sound goes: the loudspeaker, or the earpiece.
  bool get speaker => _speaker;

  @override
  bool get videoOn => _videoOn;

  /// Whether the microphone stream for the meter opened. False after a refused
  /// permission or a busy device — the light then stays dark for a reason that
  /// is not "you are quiet", and the readout says which.
  bool get meterOpen => _micSub != null;

  @override
  bool get frontCamera =>
      _cameras.isNotEmpty && _cameras[_cameraIndex].lensDirection == CameraLensDirection.front;

  @override
  bool get canSwitch => _cameras.length > 1;

  @override
  bool get showControls => !_starting && _failure?.problem != MediaCheckProblem.permission;

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  @override
  Future<void> start() async {
    try {
      _cameras = await _listCameras();
    } on CameraException {
      _cameras = const [];
    }
    try {
      await _tone.configure();
    } on Object catch (error) {
      _log('media-check: could not configure the test-sound player: $error');
    }

    if (_cameras.isEmpty) {
      // No camera is not an error that should hold the mic test hostage.
      if (!_disposed) {
        _starting = false;
        _failure = const MediaCheckFailure(MediaCheckProblem.noCamera, 'No camera on this device.');
        _changed();
      }
      unawaited(_startMeter());
      return;
    }

    _cameraIndex = _cameras.indexWhere((c) => c.lensDirection == CameraLensDirection.front);
    if (_cameraIndex < 0) _cameraIndex = 0;

    await _openCamera();
    if (!_disposed) {
      _starting = false;
      _changed();
    }
    unawaited(_startMeter());
  }

  @override
  Future<void> retry() {
    _starting = true;
    _failure = null;
    _changed();
    return start();
  }

  /// Opens the camera at [_cameraIndex].
  Future<void> _openCamera() async {
    if (_cameras.isEmpty) return;
    final controller = _cameraFactory(_cameras[_cameraIndex]);
    try {
      await controller.initialize();
      if (_disposed) {
        await controller.dispose();
        return;
      }
      _camera = controller;
      _failure = null;
      _changed();
    } on CameraException catch (error) {
      await controller.dispose();
      if (!_disposed) {
        _failure = _mapCameraError(error);
        _changed();
      }
    }
  }

  static MediaCheckFailure _mapCameraError(CameraException error) {
    const denied = {
      'CameraAccessDenied',
      'CameraAccessDeniedWithoutPrompt',
      'CameraAccessRestricted',
    };
    if (denied.contains(error.code)) {
      return const MediaCheckFailure(MediaCheckProblem.permission, 'Camera permission denied.');
    }
    return MediaCheckFailure(MediaCheckProblem.other, error.description ?? 'The camera could not start.');
  }

  /// Opens the microphone for the meter and starts feeding [_voice].
  ///
  /// Best-effort: a denied permission or a busy device leaves the light dark and
  /// the rest of the screen working, rather than throwing into the camera path.
  Future<void> _startMeter() async {
    // Idempotent: `start` runs again on a camera retry, and a second stream on
    // the same recorder would leave the first dangling and the light double-fed.
    if (_micSub != null) return;
    try {
      if (!await _mic.hasPermission()) return;
      final stream = await _mic.startStream();
      _micSub = stream.listen(_onSamples, onError: (Object e) {
        _log('media-check: microphone stream error: $e');
      });
    } on Object catch (error) {
      _log('media-check: could not open the microphone meter: $error');
    }
  }

  /// One chunk of PCM: reduce to a level, let [_voice] decide, redraw only when
  /// the "we can hear you" answer actually flips.
  void _onSamples(Uint8List samples) {
    if (!_micLive) return;
    final flipped = _voice.note(micLevel(samples), _now());
    if (flipped && !_disposed) {
      _hearing = _voice.speaking;
      _changed();
    }
  }

  @override
  Future<void> setMicLive(bool live) async {
    _micLive = live;
    if (!live) {
      _voice.silence();
      _hearing = false;
    }
    _changed();
    try {
      if (live) {
        await _mic.resume();
      } else {
        await _mic.pause();
      }
    } on Object catch (error) {
      _log('media-check: could not ${live ? 'resume' : 'pause'} the microphone: $error');
    }
  }

  @override
  Future<void> setVideoOn(bool on) async {
    _videoOn = on;
    _changed();
    final camera = _camera;
    if (camera == null) return;
    try {
      if (on) {
        await camera.resumePreview();
      } else {
        await camera.pausePreview();
      }
    } on Object catch (error) {
      _log('media-check: could not ${on ? 'resume' : 'pause'} the camera: $error');
    }
  }

  @override
  Future<void> switchCamera() async {
    if (_cameras.length < 2) return;
    final old = _camera;
    _camera = null;
    _changed();
    await old?.dispose();
    _cameraIndex = (_cameraIndex + 1) % _cameras.length;
    await _openCamera();
    if (!_videoOn) await _camera?.pausePreview();
  }

  void setSpeaker(bool speaker) {
    _speaker = speaker;
    _changed();
  }

  /// Plays the test chime out of the current route, and says what became of it:
  /// [ToneOutcome.silenced] when the Sound effects switch kept it quiet,
  /// [ToneOutcome.failed] when the player or the audio session threw (logged; the
  /// screen's button has nothing to show for it, but a drive must not answer `ok`
  /// for a sound nobody heard), [ToneOutcome.played] when the player took it.
  Future<ToneOutcome> playTone() async {
    // The chime is a sound effect; the Sound effects switch silences it too.
    if (!_soundEffects()) return ToneOutcome.silenced;
    try {
      // In Gameboy mode the speaker test speaks the handheld's square-wave voice;
      // otherwise the plain sine chime, picked fresh so taps do not repeat.
      final bytes = _gameboyMode() ? gbSoundWav(GbSound.chime) : chimeWav(variant: _rng.nextInt(variantCount));
      await _tone.play(bytes, speaker: _speaker);
      _tonesPlayed++;
      return ToneOutcome.played;
    } on Object catch (error) {
      _log('media-check: could not play the test sound: $error');
      _lastToneError = '$error';
      return ToneOutcome.failed;
    }
  }

  /// What the player threw the last time [playTone] answered
  /// [ToneOutcome.failed]; null until then.
  String? get lastToneError => _lastToneError;
  String? _lastToneError;

  /// iOS takes the camera back when the app leaves the foreground; let go first
  /// so it does not come back a black, throwing preview, and reopen on return.
  void appLifecycleChanged(AppLifecycleState state) {
    final camera = _camera;
    if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused) {
      if (camera != null) {
        _camera = null;
        _changed();
        camera.dispose();
      }
    } else if (state == AppLifecycleState.resumed) {
      if (_camera == null && _cameras.isNotEmpty && _failure == null) {
        _openCamera().then((_) async {
          if (!_videoOn) await _camera?.pausePreview();
        });
      }
    }
  }

  @override
  Map<String, Object?> status() => {
        'mode': mode.name,
        'starting': _starting,
        'failure': _failure?.toJson(),
        'showControls': showControls,
        'cameraCount': _cameras.length,
        'cameraOpen': _camera != null,
        'frontCamera': frontCamera,
        'canSwitch': canSwitch,
        'videoOn': _videoOn,
        'micLive': _micLive,
        // The light's answer only means something with a meter behind it.
        'meter': meterOpen ? 'open' : 'not_open',
        'hearing': _hearing,
        'speaker': _speaker,
        'tonesPlayed': _tonesPlayed,
      };

  @override
  void dispose() {
    _disposed = true;
    unawaited(_micSub?.cancel());
    unawaited(_mic.dispose());
    unawaited(_tone.dispose());
    unawaited(_camera?.dispose());
    super.dispose();
  }
}

// ---------------------------------------------------------------------------
// Call-pipeline mode: the pre-branch WebRTC check — plain capture, mic/camera/
// switch, no route forcing (that forcing is what lagged the screen).
// ---------------------------------------------------------------------------

/// The real capture engine, opened plainly: no `prepareAudioSession`, no route,
/// no test sound (the screen's header says why).
final class PipelineCheck extends MediaCheck {
  PipelineCheck({required this._engine, required this._preview}) {
    _sub = _engine.states.listen((s) {
      if (_disposed) return;
      _state = s;
      notifyListeners();
    });
  }

  final CaptureEngine _engine;
  final PreviewBinding _preview;

  StreamSubscription<LocalMediaState>? _sub;
  LocalMediaState _state = const LocalMediaState();
  bool _starting = true;
  bool _previewReady = false;
  bool _previewBound = false;
  bool _disposed = false;

  @override
  MediaCheckMode get mode => MediaCheckMode.callPipeline;

  /// The engine's state as last reported.
  LocalMediaState get state => _state;

  @override
  bool get starting => _starting;

  @override
  MediaCheckFailure? get failure {
    final f = _state.failure;
    return f == null ? null : MediaCheckFailure.fromMedia(f);
  }

  @override
  bool get micLive => _state.audioEnabled;

  @override
  bool get videoOn => _state.videoEnabled;

  @override
  bool get frontCamera => _state.frontCamera;

  @override
  bool get canSwitch => _state.hasVideo;

  @override
  bool get showControls => _state.capturing;

  @override
  Future<void> start() async {
    // Once only: `start` runs again on retry, and re-initialising a live renderer
    // throws. The engine's own restart handles a second `startCapture`.
    if (!_previewReady) {
      await _preview.initialize();
      _previewReady = true;
    }
    try {
      // Plain capture, like the pre-branch check: no `prepareAudioSession` and
      // no `setSpeakerOn`. Route forcing on a standalone capture with no SFU
      // transport connected drives the voice-processing reconfiguration loop
      // that lagged the screen. A real call tolerates those calls because its
      // transport is live; a test harness does not.
      await _engine.startCapture();
      final stream = _engine.localStream;
      _preview.attach(stream);
      _previewBound = stream != null;
    } on MediaFailure {
      // Already on `_state` through the stream; the screen renders it.
    } finally {
      if (!_disposed) {
        _starting = false;
        notifyListeners();
      }
    }
  }

  @override
  Future<void> retry() {
    if (!_disposed) {
      _starting = true;
      notifyListeners();
    }
    return start();
  }

  @override
  Future<void> setMicLive(bool live) => _engine.setAudioEnabled(live);

  @override
  Future<void> setVideoOn(bool on) => _engine.setVideoEnabled(on);

  @override
  Future<void> switchCamera() => _engine.switchCamera();

  @override
  Map<String, Object?> status() => {
        'mode': mode.name,
        'starting': _starting,
        'failure': failure?.toJson(),
        'showControls': showControls,
        'capturing': _state.capturing,
        'micLive': _state.audioEnabled,
        'videoOn': _state.videoEnabled,
        'hasVideo': _state.hasVideo,
        'frontCamera': _state.frontCamera,
        'canSwitch': canSwitch,
        // WebRTC gives no local level without a connection, so there is no
        // meter here: the light is live/muted only, and the readout says so
        // rather than reporting a `hearing` nobody measured.
        'meter': 'none',
        'previewReady': _previewReady,
        'previewBound': _previewBound,
      };

  @override
  void dispose() {
    _disposed = true;
    unawaited(_sub?.cancel());
    _engine.dispose();
    super.dispose();
  }
}
